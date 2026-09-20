{-# LANGUAGE OverloadedRecordDot #-}

-- | Who owns a native handle between the call that created it and the teardown
-- that releases it, and nothing about what any particular handle is.
--
-- The rule this module exists to make true is one line: every native object
-- the proof creates has a cleanup owner before the next fallible step runs. A
-- composite built from several fallible native calls — a frame slot, the
-- capture buffer and its memory — breaks that rule the moment it registers its
-- cleanup at the end of the construction instead of at the beginning, because
-- an ordinary allocation error partway leaves the children already created
-- with no owner at all, and the device release registered earlier then runs
-- @vkDestroyDevice@ over them, which @VUID-vkDestroyDevice-device-05137@
-- forbids.
--
-- So a composite registers its releases before it creates anything, against
-- 'Held' places that are empty until each child exists. 'holding' is the
-- handoff: the create and the write into the place are one step that no
-- synchronous failure and no cancellation can land between. 'releasing' is the
-- other end: it takes the object out of the place before destroying it, so a
-- handle that was never created is never destroyed and no handle is ever
-- destroyed twice.
--
-- Nothing here waits, and nothing here wraps a native destroy in a timeout or
-- makes one preemptible. 'mask_' covers a handoff, which is a write to an
-- 'IORef' next to a native call that does not block; it never covers a wait.
-- What may be released at all is not decided here either — that is
-- "Test.Vulkan.Proof.Retention", which 'runCleanups' consults and obeys.
module Test.Vulkan.Proof.Ownership
  ( -- * Owning one handle from the instant it exists
    Held
  , newHeld
  , holding
  , releasing
  , heldValue
  , releaseAll

    -- * The ledger
  , Ledger
  , newLedger
  , observe
  , observations

    -- * The cleanup stack
  , Cleanups
  , newCleanups
  , onExit
  , onExitRecallable
  , owning
  , runCleanups
  ) where

import Control.Exception (SomeException, displayException, mask_, throwIO, try)
import Control.Monad (forM)
import Data.Foldable (for_)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text

import Test.Vulkan.Proof.Findings (TeardownFacts (..))
import Test.Vulkan.Proof.Journal (Journal, note)
import Test.Vulkan.Proof.Retention
  ( BoundaryStanding (..)
  , Disposition (..)
  , Handle (..)
  , Observation
  , Route (..)
  , Standing (..)
  , decide
  , describeHandle
  , describeObservation
  , isDestruction
  , releasedEntries
  , standingFrom
  )

-- --------------------------------------------------------------------------
-- Owning one handle

-- | The single place one native object lives between the call that created it
-- and the release that destroys it.
--
-- It is empty until that call returns and empty again from the moment the
-- release takes the object out, which is what makes "never destroyed twice"
-- and "never destroyed if it was never created" the same mechanism rather than
-- two conventions a reader has to check.
newtype Held a = Held (IORef (Maybe a))

newHeld ∷ IO (Held a)
newHeld = Held <$> newIORef Nothing

-- | Create one object and put it in its place before anything else can run.
--
-- The mask is requirement 5 and is not decoration: without it a cancellation
-- delivered between a successful create and the write that hands it over
-- orphans the object exactly as a synchronous failure there would, and the
-- release registered against this place would find nothing. Neither the native
-- create nor the write blocks, so masking here withholds nothing from a
-- caller that wants to stop the run — it only moves the point at which the
-- stop is taken to one where the object is already owned.
holding ∷ Held a → IO a → IO a
holding (Held ref) acquire = mask_ $ do
  value ← acquire
  writeIORef ref (Just value)
  pure value

-- | Destroy whatever the place holds, exactly once.
--
-- The object is taken out first, so a release that throws is not retried by a
-- later release of the same place and a place that was never filled destroys
-- nothing. The failure itself is not swallowed: it escapes to the cleanup
-- executor, which records it beside whatever primary failure stopped the run.
releasing ∷ Held a → (a → IO ()) → IO ()
releasing (Held ref) release = do
  taken ← mask_ (atomicModifyIORef' ref (\held → (Nothing, held)))
  for_ taken release

-- | What the place holds, for a caller that needs to look without taking.
heldValue ∷ Held a → IO (Maybe a)
heldValue (Held ref) = readIORef ref

-- | Run every release, then re-raise the first failure.
--
-- One cleanup entry can own several children — a slot's command pool, its
-- rendering fence and its acquisition semaphore are one entry — and a failure
-- destroying the first of them must not quietly leave the other two alive. The
-- failure still escapes, so the executor above still records it.
releaseAll ∷ [IO ()] → IO ()
releaseAll actions = do
  outcomes ← forM actions (try @SomeException)
  case [failure | Left failure ← outcomes] of
    (failure : _) → throwIO failure
    [] → pure ()

-- --------------------------------------------------------------------------
-- The ledger

-- | The run's own record of the native effects and results the release
-- decision is a function of, in the order they happened.
--
-- It is appended to at the moment a call returns or throws, before anything
-- that could itself fail runs: an obligation lost between a present and the
-- line that would have recorded it is a handle that looks free and is not.
newtype Ledger = Ledger (IORef [Observation])

newLedger ∷ IO Ledger
newLedger = Ledger <$> newIORef []

observe ∷ Ledger → Observation → IO ()
observe (Ledger ref) observation = modifyIORef' ref (<> [observation])

observations ∷ Ledger → IO [Observation]
observations (Ledger ref) = readIORef ref

-- --------------------------------------------------------------------------
-- Cleanup

-- | Teardown actions, newest first, each naming the handle it releases and
-- carrying the ticket that can take it back again.
--
-- The handle is what "Test.Vulkan.Proof.Retention" decides over; the entry
-- name the record reports is derived from it.
data Cleanups = Cleanups
  { cleanupNextTicket ∷ IORef Int
  , cleanupRegistered ∷ IORef [(Int, Handle, IO ())]
  }

newCleanups ∷ IO Cleanups
newCleanups = Cleanups <$> newIORef 0 <*> newIORef []

onExit ∷ Cleanups → Handle → IO () → IO ()
onExit cleanups handle action = () <$ onExitRecallable cleanups handle action

-- | Register a release and hand back the action that takes the registration
-- away again.
--
-- The capture path is the caller that needs this. It owns its buffer and its
-- memory from the instant each exists, and on the path where it reaches the
-- end it frees both itself, exactly once, as it always did — so it then
-- recalls both registrations and teardown arrives at the ten entries it would
-- have arrived at if the capture had never registered anything. A run that
-- stopped inside the capture recalls neither, and teardown finds them.
onExitRecallable ∷ Cleanups → Handle → IO () → IO (IO ())
onExitRecallable cleanups handle action = do
  ticket ← atomicModifyIORef' cleanups.cleanupNextTicket (\next → (next + 1, next))
  modifyIORef' cleanups.cleanupRegistered ((ticket, handle, action) :)
  pure (modifyIORef' cleanups.cleanupRegistered (filter (\(held, _, _) → held /= ticket)))

-- | Create one object and register its release before anything else can run.
--
-- The single-object form of 'holding': a handle whose whole construction is
-- one call needs no place to be held in, but it does need the same protection
-- at the handoff, because a cancellation between the create and the
-- registration orphans it just as surely.
owning ∷ Cleanups → Handle → IO a → (a → IO ()) → IO a
owning cleanups handle acquire release = mask_ $ do
  value ← acquire
  onExit cleanups handle (release value)
  pure value

-- | What became of one release.
data Release
  = Released
  | Failed Text
  | Retained Text

released ∷ Release → Bool
released = \case
  Released → True
  _ → False

-- | Tear down: the boundary first, then every release the recorded evidence
-- permits, in reverse registration order.
--
-- The boundary runs before any decision is taken because it is what produces
-- the evidence the decisions rest on — the device-idle result, and a bounded
-- wait on every present fence still owed. After it, one call to the same pure
-- 'decide' the headless examples exercise says what may go and what must stay.
--
-- A release that fails is recorded and never allowed to hide the ones after
-- it; a release that is withheld is recorded with the condition that was
-- unmet. Neither is narrated separately from the values the verdict reads.
runCleanups ∷ Journal → Ledger → Cleanups → IO TeardownFacts
runCleanups journal ledger cleanups = do
  registered ← readIORef cleanups.cleanupRegistered
  writeIORef cleanups.cleanupRegistered []
  let entries = [(handle, action) | (_, handle, action) ← registered]
  boundary ← forM [entry | entry@(TheTeardownBoundary, _) ← entries] (attempt journal)
  recorded ← observations ledger
  let plan = map fst entries
      decisions = decide plan recorded
  later ← forM [entry | entry@(handle, _) ← entries, handle /= TheTeardownBoundary] $ \entry@(handle, _) →
    case lookup handle decisions of
      Just (Retain reason) → do
        note journal ("teardown retained " <> describeHandle handle <> ": " <> reason)
        pure (handle, Retained reason)
      _ → attempt journal entry
  settled ← observations ledger
  pure (teardownFactsFrom settled (boundary <> later))

attempt ∷ Journal → (Handle, IO ()) → IO (Handle, Release)
attempt journal (handle, action) = do
  outcome ← try @SomeException action
  case outcome of
    Right () → pure (handle, Released)
    Left failure → do
      let reason = describeHandle handle <> ": " <> Text.pack (displayException failure)
      note journal ("teardown of " <> reason)
      pure (handle, Failed reason)

teardownFactsFrom ∷ [Observation] → [(Handle, Release)] → TeardownFacts
teardownFactsFrom recorded outcomes =
  TeardownFacts
    { teardownReleases = releasedEntries [(handle, released outcome) | (handle, outcome) ← outcomes]
    , teardownFailures = [reason | (_, Failed reason) ← outcomes]
    , -- The boundary ran, and it is in 'teardownReleases' and in the
      -- observations it produced, but it destroyed nothing: it is the
      -- device-idle wait the rest rest on. This line is what a reader consults
      -- to learn which native objects were freed, so a wait does not belong in
      -- it.
      teardownDestroyed = [describeHandle handle | (handle, Released) ← outcomes, isDestruction handle]
    , teardownRetained = [(describeHandle handle, reason) | (handle, Retained reason) ← outcomes]
    , teardownRoute = describeRoute (standingFrom recorded)
    , teardownObservations = map describeObservation recorded
    }

-- | Which destruction rules teardown operated under, and why. A timeout is
-- never reported here as device loss: it is the case where completion is still
-- owed, and saying otherwise would turn a retained handle into a destroyed one.
describeRoute ∷ Standing → Text
describeRoute standing = case standing.standingRoute of
  DeviceLossRoute →
    "the specification's device-loss rule, which permits destroying a lost device's objects without waiting for work that may never complete"
  OrdinaryRoute → case standing.standingBoundary of
    BoundaryHeld →
      "ordinary: each release needed its own completion evidence, and the device-idle boundary held"
    BoundaryNotReached →
      "ordinary: each release needed its own completion evidence, and the device-idle boundary was never reached"
    BoundaryBroken detail →
      "ordinary: each release needed its own completion evidence, and the device-idle boundary failed with " <> detail
