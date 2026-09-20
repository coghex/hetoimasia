{-# LANGUAGE OverloadedRecordDot #-}

-- | Which of teardown's releases the run's own evidence permits.
--
-- @VK_EXT_swapchain_maintenance1@ permits destroying a presentation semaphore
-- only after its present fence signals, and a swapchain only after the fences
-- of all past presents signal. Device idle is not that evidence: a present is
-- work for the presentation engine, not for a queue, so @vkDeviceWaitIdle@ can
-- return @VK_SUCCESS@ with a present still outstanding. A teardown that ran
-- every release anyway would be the device-idle fallback
-- @docs/vulkan_backend_design.md@ P-12 and Q-2 forbid.
--
-- So teardown asks this module instead, and this module is pure: it decides
-- from the native effects and results the run recorded and from nothing else.
-- That is what lets the same decision the native cleanup executor obeys be
-- exercised headlessly, by examples that open no window and make no native
-- call — see "Test.Vulkan.Proof.RetentionSpec".
--
-- Three dispositions, and no fourth:
--
-- * every applicable condition holds, and the handle is destroyed;
-- * a condition is unmet, and the handle is retained with the reason. The
--   escape for a session that never resolves is retention plus process exit,
--   never a preemptible native call or a destroy wrapped in a timeout;
-- * the device is lost, and the specification's own device-loss rule permits
--   destruction without waiting for work that may never complete.
--
-- A timeout is never promoted to device loss. It is the case where completion
-- is still owed, which is precisely the case retention exists for.
module Test.Vulkan.Proof.Retention
  ( -- * Native results, classified
    NativeResult (..)
  , classifyResult
  , classifyThrown
  , describeResult
  , presentEnqueuesOperations

    -- * What the run recorded
  , SlotName
  , Observation (..)
  , describeObservation

    -- * What teardown can release
  , Handle (..)
  , describeHandle
  , handleEntry
  , teardownPlan
  , teardownEntries

    -- * The decision
  , Route (..)
  , BoundaryStanding (..)
  , Standing (..)
  , standingFrom
  , Disposition (..)
  , wasDestroyed
  , decide
  , releasedEntries
  , retainedHandles
  ) where

import Control.Exception (SomeException, displayException, fromException)
import Data.Text (Text)
import qualified Data.Text as Text

import Vulkan.Core10.Enums.Result (Result (..))
import Vulkan.Exception (VulkanException (..))

-- --------------------------------------------------------------------------
-- Native results

-- | A result a native call reported, reduced to what the release decision
-- turns on.
--
-- The binding throws a 'VulkanException' for an error code rather than
-- returning it, so a thrown error and a returned one classify the same way.
-- An exception that is not one classifies as 'NotAResult': it establishes
-- neither completion nor device loss, and the decision below treats it as
-- evidence of nothing rather than as either.
data NativeResult
  = Succeeded
  | Suboptimal
  | TimedOut
  | OutOfDate
  | SurfaceLost
  | DeviceLost
  | OutOfHostMemory
  | OutOfDeviceMemory
  | OtherResult Text
  | NotAResult Text
  deriving (Eq, Show)

classifyResult ∷ Result → NativeResult
classifyResult result
  | result == SUCCESS = Succeeded
  | result == SUBOPTIMAL_KHR = Suboptimal
  | result == TIMEOUT = TimedOut
  | result == ERROR_OUT_OF_DATE_KHR = OutOfDate
  | result == ERROR_SURFACE_LOST_KHR = SurfaceLost
  | result == ERROR_DEVICE_LOST = DeviceLost
  | result == ERROR_OUT_OF_HOST_MEMORY = OutOfHostMemory
  | result == ERROR_OUT_OF_DEVICE_MEMORY = OutOfDeviceMemory
  | otherwise = OtherResult (Text.pack (show result))

-- | What an escaping exception says about the call it escaped from. A
-- 'VulkanException' carries the result code the call would otherwise have
-- returned, and is classified as that code; anything else carries no result at
-- all, which is what 'NotAResult' records.
classifyThrown ∷ SomeException → NativeResult
classifyThrown escaped = case fromException escaped of
  Just (VulkanException result) → classifyResult result
  Nothing → NotAResult (Text.pack (displayException escaped))

describeResult ∷ NativeResult → Text
describeResult = \case
  Succeeded → "VK_SUCCESS"
  Suboptimal → "VK_SUBOPTIMAL_KHR"
  TimedOut → "VK_TIMEOUT"
  OutOfDate → "VK_ERROR_OUT_OF_DATE_KHR"
  SurfaceLost → "VK_ERROR_SURFACE_LOST_KHR"
  DeviceLost → "VK_ERROR_DEVICE_LOST"
  OutOfHostMemory → "VK_ERROR_OUT_OF_HOST_MEMORY"
  OutOfDeviceMemory → "VK_ERROR_OUT_OF_DEVICE_MEMORY"
  OtherResult name → name
  NotAResult detail → "an exception carrying no result (" <> detail <> ")"

-- | Whether a @vkQueuePresentKHR@ that reported this result left its semaphore
-- waits enqueued and its present fence pending.
--
-- Out-of-date and surface-lost do: the presentation contract preserves the
-- operations a present enqueued, so the error result alone releases nothing.
-- The two out-of-memory results are the specified no-effect case, where no
-- present fence was enqueued to wait on. Anything this module cannot place —
-- an unexpected code, or an exception that is not the binding's — is counted
-- as having enqueued, because an obligation wrongly assumed costs a retained
-- handle while one wrongly discharged costs a use-after-free.
presentEnqueuesOperations ∷ NativeResult → Bool
presentEnqueuesOperations = \case
  OutOfHostMemory → False
  OutOfDeviceMemory → False
  _ → True

-- --------------------------------------------------------------------------
-- What the run recorded

-- | A frame slot, by the name the run gives it.
type SlotName = Text

-- | One native effect or result the run observed, in the order it observed it.
--
-- Order is what makes a recycled slot safe: a slot's earlier completion is
-- recorded before its next present, so the later 'PresentAttempted' reopens
-- the obligation that the earlier 'PresentFenceWaited' closed, and nothing
-- carries the old completion forward onto the new present.
data Observation
  = PresentAttempted SlotName NativeResult
    -- ^ A @vkQueuePresentKHR@ chaining that slot's present fence. Recorded as
    -- soon as the call returns or throws, before any status query, event poll,
    -- or wait that could itself fail and lose the obligation.
  | PresentFenceWaited SlotName NativeResult
    -- ^ A wait on that slot's present fence. Only @VK_SUCCESS@ discharges the
    -- obligation; a timeout leaves it exactly where it was.
  | TeardownBoundaryReached NativeResult
    -- ^ What @vkDeviceWaitIdle@ reported at the teardown boundary.
  deriving (Eq, Show)

describeObservation ∷ Observation → Text
describeObservation = \case
  PresentAttempted slot result →
    "vkQueuePresentKHR for " <> slot <> " returned " <> describeResult result
  PresentFenceWaited slot result →
    "a wait on the present fence of " <> slot <> " returned " <> describeResult result
  TeardownBoundaryReached result →
    "the teardown boundary's vkDeviceWaitIdle returned " <> describeResult result

-- --------------------------------------------------------------------------
-- What teardown can release

-- | One thing teardown destroys, finer-grained than the cleanup entry that
-- owns it.
--
-- The entries are what the record has always listed and what requirement 7
-- keeps unchanged; a slot's own objects have to be separable from them,
-- because a fence-timeout retains two of a slot's five handles and releases
-- the other three.
data Handle
  = TheTeardownBoundary
    -- ^ Not a destruction: the device-idle wait the releases below it rest on.
  | SlotWorkObjects SlotName
    -- ^ A slot's command pool, rendering fence, and acquisition semaphore —
    -- everything whose completion the device-idle boundary does establish.
  | SlotPresentFence SlotName
  | SlotPresentSemaphore SlotName
  | TheSwapchain
  | TheLogicalDevice
  | TheWindowSurface
  | TheProofWindow
  | TheExplicitMessenger
  | TheVulkanInstance
  | TheCallbackTrampoline
  | GlfwTermination
  deriving (Eq, Show)

describeHandle ∷ Handle → Text
describeHandle = \case
  TheTeardownBoundary → "the teardown boundary"
  SlotWorkObjects slot → "the command pool, rendering fence and acquisition semaphore of " <> slot
  SlotPresentFence slot → "the present fence of " <> slot
  SlotPresentSemaphore slot → "the presentation semaphore of " <> slot
  TheSwapchain → "the swapchain"
  TheLogicalDevice → "the logical device"
  TheWindowSurface → "the window surface"
  TheProofWindow → "the proof window"
  TheExplicitMessenger → "the explicit debug messenger"
  TheVulkanInstance → "the Vulkan instance"
  TheCallbackTrampoline → "the callback trampoline"
  GlfwTermination → "GLFW"

-- | The top-level cleanup entry a handle belongs to. These are the names the
-- record's "released, in order" line has always carried.
handleEntry ∷ Handle → Text
handleEntry = \case
  TheTeardownBoundary → "the teardown boundary"
  SlotWorkObjects _ → "the frame slots"
  SlotPresentFence _ → "the frame slots"
  SlotPresentSemaphore _ → "the frame slots"
  TheSwapchain → "the swapchain"
  TheLogicalDevice → "the logical device"
  TheWindowSurface → "the window surface"
  TheProofWindow → "the proof window"
  TheExplicitMessenger → "the explicit debug messenger"
  TheVulkanInstance → "the Vulkan instance"
  TheCallbackTrampoline → "the callback trampoline"
  GlfwTermination → "GLFW"

-- | Every handle a whole run registers, in the order teardown reaches them:
-- the reverse of the order the procedure registered their cleanups.
--
-- A run that stopped early registered a prefix of this, so the executor builds
-- its plan from what was actually registered. This is the whole of it, which
-- is what the examples and 'teardownEntries' are written against.
teardownPlan ∷ [SlotName] → [Handle]
teardownPlan slots =
  [TheTeardownBoundary]
    <> concat
      [ [SlotWorkObjects slot, SlotPresentFence slot, SlotPresentSemaphore slot]
      | slot ← slots
      ]
    <> [ TheSwapchain
       , TheLogicalDevice
       , TheWindowSurface
       , TheProofWindow
       , TheExplicitMessenger
       , TheVulkanInstance
       , TheCallbackTrampoline
       , GlfwTermination
       ]

-- | The ten cleanup entries a whole teardown releases, in order. Requirement 7
-- fixes this list and this order for the successful path; the finer handles
-- above exist so the failure path can say which parts of an entry it withheld
-- without disturbing it.
teardownEntries ∷ [Text]
teardownEntries =
  [ "the teardown boundary"
  , "the frame slots"
  , "the swapchain"
  , "the logical device"
  , "the window surface"
  , "the proof window"
  , "the explicit debug messenger"
  , "the Vulkan instance"
  , "the callback trampoline"
  , "GLFW"
  ]

-- --------------------------------------------------------------------------
-- The standing the observations establish

-- | Which set of destruction rules teardown is operating under.
data Route
  = OrdinaryRoute
    -- ^ Every release needs its own completion evidence.
  | DeviceLossRoute
    -- ^ The device is lost. The specification permits destroying its objects
    -- without waiting for work that may never complete — which authorizes
    -- destruction, and asserts nothing about what finished.
  deriving (Eq, Show)

data BoundaryStanding
  = BoundaryNotReached
  | BoundaryHeld
  | BoundaryBroken Text
  deriving (Eq, Show)

data Standing = Standing
  { standingRoute ∷ Route
  , standingBoundary ∷ BoundaryStanding
  , standingPending ∷ [(SlotName, Text)]
    -- ^ Slots whose last present has not been retired, each with why, in the
    -- order they first became outstanding.
  }
  deriving (Eq, Show)

standingFrom ∷ [Observation] → Standing
standingFrom = foldl absorb initial
  where
    initial =
      Standing
        { standingRoute = OrdinaryRoute
        , standingBoundary = BoundaryNotReached
        , standingPending = []
        }

    absorb standing = \case
      PresentAttempted slot result →
        let owed
              | presentEnqueuesOperations result =
                  owe
                    slot
                    ( "its presentation was enqueued and reported "
                        <> describeResult result
                        <> ", and its present fence has not signalled since"
                    )
                    standing
              -- The specified no-effect case: nothing was enqueued, so this
              -- present created no obligation. It also discharges none, which
              -- is why an earlier slot's outstanding present survives here.
              | otherwise = standing
         in if result == DeviceLost then lose owed else owed
      PresentFenceWaited slot result
        | result == Succeeded → standing {standingPending = filter ((/= slot) . fst) standing.standingPending}
        | result == DeviceLost → lose (reword slot standing)
        | otherwise → reword slot standing
        where
          reword name current =
            current
              { standingPending =
                  [ if name == held
                      then (held, why <> ", and a wait on it returned " <> describeResult result)
                      else (held, why)
                  | (held, why) ← current.standingPending
                  ]
              }
      TeardownBoundaryReached result
        | result == Succeeded → standing {standingBoundary = BoundaryHeld}
        | result == DeviceLost →
            lose standing {standingBoundary = BoundaryBroken (describeResult result)}
        | otherwise → standing {standingBoundary = BoundaryBroken (describeResult result)}

    owe slot why standing =
      standing
        { standingPending =
            [entry | entry@(held, _) ← standing.standingPending, held /= slot] <> [(slot, why)]
        }

    lose standing = standing {standingRoute = DeviceLossRoute}

-- --------------------------------------------------------------------------
-- The decision

data Disposition
  = Destroy
  | Retain Text
  deriving (Eq, Show)

wasDestroyed ∷ Disposition → Bool
wasDestroyed = \case
  Destroy → True
  Retain _ → False

-- | The disposition of every handle in a plan, in teardown order.
--
-- Retention propagates upward: a handle whose child is withheld is withheld
-- too, so the plan's own child-before-parent order is what carries a retained
-- present fence all the way up to the window and to @glfwTerminate@.
decide ∷ [Handle] → [Observation] → [(Handle, Disposition)]
decide plan observations = walk [] plan
  where
    standing = standingFrom observations

    -- Whether anything in this plan is owed what a device-idle boundary
    -- supplies. A plan without one is a run that stopped before the procedure
    -- registered it, and the procedure registers it immediately after the
    -- frame slots and submits nothing until afterwards — so such a plan holds
    -- no object with queue work outstanding, and the absence withholds
    -- nothing. A plan that does hold one has already run it, because it is
    -- first in teardown order; a plan that holds one and reached no result for
    -- it is a teardown that lost its own evidence, and withholding is the only
    -- safe answer to that.
    required = TheTeardownBoundary `elem` plan

    walk _ [] = []
    walk withheld (handle : rest) =
      let disposition = dispositionOf standing required withheld handle
          withheld' = case disposition of
            Retain _ → withheld <> [handle]
            Destroy → withheld
       in (handle, disposition) : walk withheld' rest

dispositionOf ∷ Standing → Bool → [Handle] → Handle → Disposition
dispositionOf standing required withheld handle
  -- The boundary is a wait, not a destruction. It is what produces the
  -- evidence the releases below it are judged against, so it always runs.
  | handle == TheTeardownBoundary = Destroy
  | standing.standingRoute == DeviceLossRoute = Destroy
  | otherwise = case boundaryReasons <> presentReasons <> dependencyReasons of
      [] → Destroy
      reasons → Retain (Text.intercalate "; " reasons)
  where
    boundaryReasons
      | not (required && restsOnBoundary handle) = []
      | otherwise = case standing.standingBoundary of
          BoundaryHeld → []
          BoundaryNotReached →
            ["the teardown boundary was never reached, so nothing established that the device had finished with it"]
          BoundaryBroken detail →
            [ "the teardown boundary failed with "
                <> detail
                <> ", so it established none of the completion this release was to rest on"
            ]

    presentReasons = case handle of
      SlotPresentFence slot → pendingOf slot
      SlotPresentSemaphore slot → pendingOf slot
      -- Every past present, not only this slot's: the swapchain outlives all
      -- of them.
      TheSwapchain → [slot <> " has an unretired present: " <> why | (slot, why) ← standing.standingPending]
      _ → []

    pendingOf slot = [why | (held, why) ← standing.standingPending, held == slot]

    dependencyReasons =
      [ describeHandle child <> " is retained, and " <> describeHandle handle <> " must outlive it"
      | child ← withheld
      , child `mustPrecede` handle
      ]

-- | Whether a handle's destruction is one the device-idle boundary was there
-- to make safe. Everything above the device reaches retention through its
-- children instead.
restsOnBoundary ∷ Handle → Bool
restsOnBoundary = \case
  SlotWorkObjects _ → True
  SlotPresentFence _ → True
  SlotPresentSemaphore _ → True
  TheSwapchain → True
  TheLogicalDevice → True
  _ → False

-- | Whether the first handle must be gone before the second may be destroyed:
-- the second is its parent, or is otherwise required to outlive it.
--
-- The messenger is in here because a messenger torn down before the objects it
-- watches would leave their destruction diagnostics, including a device's leak
-- reports, with nowhere to go. The trampoline is, because a callback arriving
-- inside @vkDestroyInstance@ must still find it callable. @glfwTerminate@ is,
-- because it destroys every remaining window, which is exactly the retained
-- one.
mustPrecede ∷ Handle → Handle → Bool
mustPrecede child parent = case parent of
  TheLogicalDevice → deviceChild child
  TheWindowSurface → child == TheSwapchain
  TheProofWindow → child == TheWindowSurface
  TheExplicitMessenger →
    deviceChild child || child `elem` [TheLogicalDevice, TheWindowSurface, TheProofWindow]
  TheVulkanInstance →
    deviceChild child
      || child `elem` [TheLogicalDevice, TheWindowSurface, TheProofWindow, TheExplicitMessenger]
  TheCallbackTrampoline → child == TheVulkanInstance
  GlfwTermination → child `elem` [TheWindowSurface, TheProofWindow]
  _ → False
  where
    deviceChild = \case
      SlotWorkObjects _ → True
      SlotPresentFence _ → True
      SlotPresentSemaphore _ → True
      TheSwapchain → True
      _ → False

-- | The cleanup entries every one of whose handles was released, in teardown
-- order and without repetition. This is the record's "released, in order"
-- line: on a teardown that retains nothing and fails nothing it is exactly
-- 'teardownEntries'.
--
-- The flag is whether the handle's release actually ran and succeeded, so a
-- release that threw keeps its entry off this list as surely as a retained one
-- does.
releasedEntries ∷ [(Handle, Bool)] → [Text]
releasedEntries outcomes = [entry | entry ← ordered, all (`elem` released) (handlesOf entry)]
  where
    ordered = distinct (map (handleEntry . fst) outcomes)
    handlesOf entry = [handle | (handle, _) ← outcomes, handleEntry handle == entry]
    released = [handle | (handle, True) ← outcomes]
    distinct = foldl (\seen name → if name `elem` seen then seen else seen <> [name]) []

-- | Every handle teardown withheld, with the reason, in teardown order.
retainedHandles ∷ [(Handle, Disposition)] → [(Text, Text)]
retainedHandles decisions = [(describeHandle handle, reason) | (handle, Retain reason) ← decisions]
