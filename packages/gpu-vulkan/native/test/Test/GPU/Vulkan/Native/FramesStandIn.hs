-- | A stand-in native layer for the frames: every call recorded in order, any
-- step made to fail, a hook run inside every call so an example can observe
-- the model at that instant or aim a cancellation at it, and a small model of
-- what Vulkan itself would hold the application to.
--
-- That model is the point of the stand-in. It tracks each fence — unsignalled,
-- pending on a submission, or signalled — and each binary semaphore —
-- unsignalled, owed a signal, or waited on by a pending submission — and each
-- swapchain image the application owns, and it records a violation, instead of
-- failing, whenever a call breaks a rule: asking a fence no submission made
-- pending whether it signalled, resetting or destroying a pending fence,
-- acquiring into or signalling a semaphore that is not unsignalled, waiting on
-- one nothing will signal, destroying one a submission still uses, or
-- releasing an image whose acquisition signal was never waited on to
-- completion. Every example ends by requiring there were none.
--
-- A fence signals only when an example says its submission completed
-- ('completeFence', 'completeAll'), which is the injected completion a native
-- run gets from the device.
module Test.GPU.Vulkan.Native.FramesStandIn
  ( FramesStandIn (..)
  , newFramesStandIn
  , framesStandInOps
  , FrameCall (..)
  , frameCalls
  , FrameStep (..)
  , failFrameStep
  , clearFrameStep
  , duringFrameCall
  , scriptAcquire
  , completeFence
  , completeAll
  , pendingFences
  , violations
  , FrameStepFailed (..)
  , imagesOwned
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (Exception, fromException, throwIO)
import Control.Monad (unless, when)
import Data.Foldable (for_)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word64)

import Hetoimasia.GPU.Vulkan.Native.Frames (AcquireResult (..), FrameOps (..), SubmitBatch (..), WaitStage)

-- | One native call the frames made, in the order it made it. A command buffer
-- is its number, as the recording's stand-in makes it.
data FrameCall
  = CreatedSemaphore !Word64
  | DestroyedSemaphore !Word64
  | CreatedFence !Word64
  | DestroyedFence !Word64
  | ResetFence !Word64
  | QueriedFence !Word64
  | Acquired !Word64 !Word64 !AcquireResult
    -- ^ The swapchain, the semaphore, and what the call answered.
  | Submitted ![([Word64], WaitStage, [Word64], [Word64])] !Word64
    -- ^ Each batch's waits, their stage, its command buffers and its signals;
    -- and the fence.
  | Released !Word64 ![Word32]
  deriving (Eq, Show)

-- | A step the stand-in can be made to fail at.
data FrameStep
  = AtCreateSemaphore
  | AtCreateFence
  | AtResetFence
  | AtQueryFence
  | AtAcquire
  | AtSubmit
    -- ^ Fail with an effect the frames cannot know.
  | AtSubmitNoEffect
    -- ^ Fail as out of memory does: the specified no-effect result, which
    -- 'opsNoEffect' recognizes.
  | AtCleanupSubmit
    -- ^ Fail only a submission that runs no command.
  | AtRelease
  | AtDestroy
  deriving (Eq, Ord, Show)

-- | What a failing step raises, after recording the call.
newtype FrameStepFailed = FrameStepFailed FrameStep
  deriving (Eq, Show)

instance Exception FrameStepFailed

data FenceState = Unsignalled | Pending | Signalled
  deriving (Eq, Show)

data SemaphoreState = Idle | SignalOwed | WaitedBy !Word64
  deriving (Eq, Show)

data FramesStandIn = FramesStandIn
  { standJournal ∷ !(TVar [FrameCall])
    -- ^ Newest first.
  , standFailing ∷ !(TVar (Set FrameStep))
  , standHandles ∷ !(TVar Word64)
  , standFences ∷ !(TVar (Map Word64 FenceState))
  , standSemaphores ∷ !(TVar (Map Word64 SemaphoreState))
  , standPending ∷ !(TVar (Map Word64 [Word64]))
    -- ^ Each pending fence, and the semaphores its submission waits on.
  , standOwned ∷ !(TVar (Map (Word64, Word32) Word64))
    -- ^ Each image the application owns, and the semaphore its acquisition
    -- signals.
  , standScript ∷ !(TVar [AcquireResult])
    -- ^ Answers for the next acquisitions, before the default.
  , standImages ∷ !Word32
    -- ^ How many images each swapchain has.
  , standViolations ∷ !(TVar [Text])
  , standDuring ∷ !(TVar (FrameCall → IO ()))
  }

newFramesStandIn ∷ IO FramesStandIn
newFramesStandIn =
  FramesStandIn
    <$> newTVarIO []
    <*> newTVarIO Set.empty
    <*> newTVarIO 9000
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO []
    <*> pure 3
    <*> newTVarIO []
    <*> newTVarIO (\_ → pure ())

-- | Every call so far, oldest first.
frameCalls ∷ FramesStandIn → IO [FrameCall]
frameCalls standIn = reverse <$> readTVarIO (standJournal standIn)

failFrameStep ∷ FramesStandIn → FrameStep → IO ()
failFrameStep standIn at = atomically (modifyTVar' (standFailing standIn) (Set.insert at))

clearFrameStep ∷ FramesStandIn → FrameStep → IO ()
clearFrameStep standIn at = atomically (modifyTVar' (standFailing standIn) (Set.delete at))

-- | Run this inside every call, after its effect and before it returns.
duringFrameCall ∷ FramesStandIn → (FrameCall → IO ()) → IO ()
duringFrameCall standIn action = atomically (writeTVar (standDuring standIn) action)

-- | Answer the next acquisitions with these, in order.
scriptAcquire ∷ FramesStandIn → [AcquireResult] → IO ()
scriptAcquire standIn answers = atomically (modifyTVar' (standScript standIn) (<> answers))

-- | The submission pending on this fence completed: the fence signals, and
-- every semaphore it waited on is unsignalled again.
completeFence ∷ FramesStandIn → Word64 → IO ()
completeFence standIn fence = atomically (complete standIn fence)

-- | Every pending submission completed.
completeAll ∷ FramesStandIn → IO ()
completeAll standIn = atomically $ readTVar (standPending standIn) >>= mapM_ (complete standIn) . Map.keys

complete ∷ FramesStandIn → Word64 → STM ()
complete standIn fence = do
  waited ← Map.findWithDefault [] fence <$> readTVar (standPending standIn)
  modifyTVar' (standPending standIn) (Map.delete fence)
  modifyTVar' (standFences standIn) (Map.insert fence Signalled)
  for_ waited $ \semaphore → modifyTVar' (standSemaphores standIn) (Map.insert semaphore Idle)

pendingFences ∷ FramesStandIn → IO [Word64]
pendingFences standIn = Map.keys <$> readTVarIO (standPending standIn)

-- | Every rule a call broke, oldest first.
violations ∷ FramesStandIn → IO [Text]
violations standIn = reverse <$> readTVarIO (standViolations standIn)

-- | The images the application owns now, by swapchain and index.
imagesOwned ∷ FramesStandIn → IO [(Word64, Word32)]
imagesOwned standIn = Map.keys <$> readTVarIO (standOwned standIn)

violate ∷ FramesStandIn → Text → STM ()
violate standIn complaint = modifyTVar' (standViolations standIn) (complaint :)

-- | Record the call, run the hook, then fail if the step is scripted to.
step ∷ FramesStandIn → [FrameStep] → FrameCall → IO ()
step standIn at call = do
  atomically (modifyTVar' (standJournal standIn) (call :))
  action ← readTVarIO (standDuring standIn)
  action call
  failing ← readTVarIO (standFailing standIn)
  for_ at $ \each → when (Set.member each failing) (throwIO (FrameStepFailed each))

fresh ∷ FramesStandIn → IO Word64
fresh standIn = atomically $ do
  next ← readTVar (standHandles standIn)
  writeTVar (standHandles standIn) (next + 1)
  pure next

shown ∷ Show a ⇒ a → Text
shown = Text.pack . show

-- | The stand-in's frames layer. The device is whatever the roots hold; a
-- command buffer is a number.
framesStandInOps ∷ FramesStandIn → FrameOps Int Word64
framesStandInOps standIn =
  FrameOps
    { opsCreateSemaphore = \_ → do
        handle ← fresh standIn
        step standIn [AtCreateSemaphore] (CreatedSemaphore handle)
        atomically (modifyTVar' (standSemaphores standIn) (Map.insert handle Idle))
        pure handle
    , opsDestroySemaphore = \_ handle → do
        atomically $ do
          state ← Map.lookup handle <$> readTVar (standSemaphores standIn)
          unless (state == Just Idle) $ violate standIn ("destroyed semaphore " <> shown handle <> " while " <> shown state)
          modifyTVar' (standSemaphores standIn) (Map.delete handle)
        step standIn [AtDestroy] (DestroyedSemaphore handle)
    , opsCreateFence = \_ → do
        handle ← fresh standIn
        step standIn [AtCreateFence] (CreatedFence handle)
        atomically (modifyTVar' (standFences standIn) (Map.insert handle Unsignalled))
        pure handle
    , opsDestroyFence = \_ handle → do
        atomically $ do
          state ← Map.lookup handle <$> readTVar (standFences standIn)
          when (state == Just Pending) $ violate standIn ("destroyed pending fence " <> shown handle)
          modifyTVar' (standFences standIn) (Map.delete handle)
        step standIn [AtDestroy] (DestroyedFence handle)
    , opsResetFence = \_ handle → do
        step standIn [AtResetFence] (ResetFence handle)
        atomically $ do
          state ← Map.lookup handle <$> readTVar (standFences standIn)
          when (state == Just Pending) $ violate standIn ("reset pending fence " <> shown handle)
          modifyTVar' (standFences standIn) (Map.insert handle Unsignalled)
    , opsFenceSignalled = \_ handle → do
        step standIn [AtQueryFence] (QueriedFence handle)
        atomically $
          (Map.lookup handle <$> readTVar (standFences standIn)) >>= \case
            Just Pending → pure False
            Just Signalled → pure True
            other → do
              violate standIn ("asked fence " <> shown handle <> ", which no submission made pending: " <> shown other)
              pure False
    , opsAcquireImage = \_ swapchain semaphore → do
        answer ← atomically $ do
          script ← readTVar (standScript standIn)
          owned ← readTVar (standOwned standIn)
          case script of
            next : rest → do
              writeTVar (standScript standIn) rest
              pure next
            [] → pure $ case [index | index ← [0 .. standImages standIn - 1], not (Map.member (swapchain, index) owned)] of
              index : _ → AcquiredIndex index
              [] → AcquiringNotReady
        step standIn [AtAcquire] (Acquired swapchain semaphore answer)
        let acquired index = atomically $ do
              state ← Map.lookup semaphore <$> readTVar (standSemaphores standIn)
              unless (state == Just Idle) $ violate standIn ("acquired into semaphore " <> shown semaphore <> " while " <> shown state)
              modifyTVar' (standSemaphores standIn) (Map.insert semaphore SignalOwed)
              owned ← Map.member (swapchain, index) <$> readTVar (standOwned standIn)
              when owned $ violate standIn ("acquired image " <> shown index <> ", which the application already owns")
              modifyTVar' (standOwned standIn) (Map.insert (swapchain, index) semaphore)
        case answer of
          AcquiredIndex index → acquired index
          AcquiredSuboptimalIndex index → acquired index
          _ → pure ()
        pure answer
    , opsSubmit = \_ _ batches fence → do
        let cleanup = all (null . submitCommands) batches
        step
          standIn
          ([AtSubmit, AtSubmitNoEffect] <> [AtCleanupSubmit | cleanup])
          (Submitted [(submitWaits batch, submitWaitStage batch, submitCommands batch, submitSignals batch) | batch ← batches] fence)
        atomically $ do
          fenceState ← Map.lookup fence <$> readTVar (standFences standIn)
          unless (fenceState == Just Unsignalled) $ violate standIn ("submitted with fence " <> shown fence <> " while " <> shown fenceState)
          let waits = concatMap submitWaits batches
              signals = concatMap submitSignals batches
          for_ waits $ \semaphore → do
            state ← Map.lookup semaphore <$> readTVar (standSemaphores standIn)
            unless (state == Just SignalOwed) $ violate standIn ("waited on semaphore " <> shown semaphore <> " while " <> shown state)
            modifyTVar' (standSemaphores standIn) (Map.insert semaphore (WaitedBy fence))
          for_ signals $ \semaphore → do
            state ← Map.lookup semaphore <$> readTVar (standSemaphores standIn)
            unless (state == Just Idle) $ violate standIn ("signalled semaphore " <> shown semaphore <> " while " <> shown state)
            modifyTVar' (standSemaphores standIn) (Map.insert semaphore SignalOwed)
          modifyTVar' (standFences standIn) (Map.insert fence Pending)
          modifyTVar' (standPending standIn) (Map.insert fence waits)
    , opsNoEffect = \failure → fromException failure == Just (FrameStepFailed AtSubmitNoEffect)
    , opsReleaseImages = \_ swapchain indices → do
        step standIn [AtRelease] (Released swapchain indices)
        atomically $ for_ indices $ \index →
          (Map.lookup (swapchain, index) <$> readTVar (standOwned standIn)) >>= \case
            Nothing → violate standIn ("released image " <> shown index <> ", which the application does not own")
            Just semaphore → do
              state ← Map.lookup semaphore <$> readTVar (standSemaphores standIn)
              -- The acquisition's signal must have been waited on, and that
              -- wait completed: the semaphore is idle again.
              unless (state == Just Idle) $ violate standIn ("released image " <> shown index <> " while its acquisition semaphore is " <> shown state)
              modifyTVar' (standOwned standIn) (Map.delete (swapchain, index))
    }
