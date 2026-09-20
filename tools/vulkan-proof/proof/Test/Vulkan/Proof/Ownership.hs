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
  , occupied
  , Disposal (..)
  , releaseAll
  , UnreleasedHandle (..)

    -- * The ledger
  , Ledger
  , newLedger
  , observe
  , observations

    -- * The cleanup stack
  , Cleanups
  , Cleanup (..)
  , newCleanups
  , onExit
  , onExitHolding
  , onExitRecallable
  , owning
  , runCleanups
  ) where

import Control.Exception (Exception, SomeException, displayException, mask_, throwIO, try)
import Control.Monad (filterM, forM)
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
  , boundaryRequired
  , describeHandle
  , describeObservation
  , dispositionOf
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
--
-- It carries the name of what it holds so that a release can report the object
-- it actually destroyed. A cleanup entry can own several children and reach
-- teardown holding some of them, and a record that named the whole entry would
-- claim destructions that never happened.
data Held a = Held Text (IORef (Contents a))

-- | What a place holds.
--
-- Three states rather than two, because "there is nothing here" and "the
-- object that was here was not released" are opposite facts and a teardown
-- that confused them would destroy a parent over a live child. A release is
-- attempted exactly once: it takes the object out before destroying it, and if
-- that destroy fails or never completes the place keeps the reason instead of
-- the object, so a later release reports the failure rather than retrying it.
data Contents a
  = Empty
  | Holding a
  | Unreleased Text

-- | A release that was attempted, did not complete, and must not be retried.
--
-- The cleanup executor turns this into the entry's recorded failure, which is
-- what withholds the parents that must outlive whatever may have survived.
newtype UnreleasedHandle = UnreleasedHandle Text

instance Show UnreleasedHandle where
  show (UnreleasedHandle reason) = Text.unpack reason

instance Exception UnreleasedHandle

newHeld ∷ Text → IO (Held a)
newHeld name = Held name <$> newIORef Empty

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
holding (Held _ ref) acquire = mask_ $ do
  value ← acquire
  writeIORef ref (Holding value)
  pure value

-- | Destroy whatever the place holds, exactly once, and name what was
-- destroyed.
--
-- The object is taken out first, so a release that throws is not retried by a
-- later release of the same place and a place that was never filled destroys
-- nothing. A place that held nothing reports nothing, which is what keeps a
-- record of a stopped run from claiming a destruction that did not happen. The
-- failure itself is not swallowed: it escapes to the cleanup executor, which
-- records it beside whatever primary failure stopped the run.
-- Everything from the take to the mark is masked, for the same reason the
-- handoff is: a cancellation between a destroy that succeeded and the write
-- that records it would leave the place claiming a failure that did not
-- happen, and one between the take and the destroy would lose the object
-- outright. No native destroy blocks, so nothing is withheld from a caller
-- that wants to stop.
releasing ∷ Held a → (a → IO ()) → IO [Text]
releasing (Held name ref) release = mask_ $ do
  taken ← atomicModifyIORef' ref $ \contents → case contents of
    -- Marked before the destroy, not after it: a destroy that never returns a
    -- result must leave the place saying so.
    Holding value → (Unreleased (name <> " was taken out to be destroyed and the destroy did not complete"), Just (Right value))
    Unreleased reason → (Unreleased reason, Just (Left reason))
    Empty → (Empty, Nothing)
  case taken of
    Nothing → pure []
    Just (Left reason) → throwIO (UnreleasedHandle reason)
    Just (Right value) → do
      outcome ← try @SomeException (release value)
      case outcome of
        Right () → do
          writeIORef ref Empty
          pure [name]
        Left failure → do
          writeIORef ref (Unreleased (name <> ": " <> Text.pack (displayException failure)))
          throwIO failure

-- | What the place holds, for a caller that needs to look without taking.
heldValue ∷ Held a → IO (Maybe a)
heldValue (Held _ ref) =
  readIORef ref >>= \case
    Holding value → pure (Just value)
    _ → pure Nothing

-- | Whether the place still stands between teardown and a native object.
--
-- A place whose release failed counts: its object may be alive, so the entry
-- must stay in the plan and say so rather than vanish from the record.
occupied ∷ Held a → IO Bool
occupied (Held _ ref) =
  readIORef ref >>= \case
    Empty → pure False
    _ → pure True

-- | What one registered release did: every object it destroyed, and every
-- failure it had.
--
-- Both lists, and all of both. One cleanup entry can own several children — a
-- slot's command pool, its rendering fence and its acquisition semaphore are
-- one entry — so reporting only the first failure would drop the later ones
-- from the record, and reporting no destructions because one child failed
-- would deny the ones that went.
data Disposal = Disposal
  { disposalDestroyed ∷ [Text]
  , disposalFailures ∷ [Text]
  }

-- | Run every release, and report all of them.
--
-- A failure destroying one child must not leave its siblings alive, so none of
-- these is allowed to stop the others; and none is swallowed, because the
-- executor above turns each into a recorded failure that withholds the parents
-- which must outlive whatever may have survived.
releaseAll ∷ [IO [Text]] → IO Disposal
releaseAll actions = do
  outcomes ← forM actions (try @SomeException)
  pure
    Disposal
      { disposalDestroyed = concat [names | Right names ← outcomes]
      , disposalFailures = [Text.pack (displayException failure) | Left failure ← outcomes]
      }

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

-- | One registered release: whether it still holds a native object, and what
-- releasing it does.
--
-- Both halves matter to a run that stopped. A place-backed entry whose
-- construction never reached it holds nothing, and teardown must neither
-- report it as a destruction nor retain it — a retention would hold every
-- parent above it for a handle that does not exist. The release reports the
-- objects it actually destroyed, by name, so the record of a partial
-- construction says what went rather than what the entry is called.
data Cleanup = Cleanup
  { cleanupHolds ∷ IO Bool
  , cleanupRelease ∷ IO Disposal
  }

-- | Teardown actions, newest first, each naming the handle it releases and
-- carrying the ticket that can take it back again.
--
-- The handle is what "Test.Vulkan.Proof.Retention" decides over; the entry
-- name the record reports is derived from it.
data Cleanups = Cleanups
  { cleanupNextTicket ∷ IORef Int
  , cleanupRegistered ∷ IORef [(Int, Handle, Cleanup)]
  }

newCleanups ∷ IO Cleanups
newCleanups = Cleanups <$> newIORef 0 <*> newIORef []

-- | Register the release of a handle that certainly exists, because its
-- registration followed a successful create. There is nothing for teardown to
-- discover about whether it is there, and the object it destroys is the one
-- the handle is named for.
onExit ∷ Cleanups → Handle → IO () → IO ()
onExit cleanups handle action =
  onExitHolding
    cleanups
    handle
    (Cleanup (pure True) (releaseAll [action >> pure [describeHandle handle]]))

-- | Register a release whose presence is a question: a composite's entry,
-- which holds whichever of its children the construction reached.
onExitHolding ∷ Cleanups → Handle → Cleanup → IO ()
onExitHolding cleanups handle cleanup = () <$ onExitRecallable cleanups handle cleanup

-- | Register a release and hand back the action that takes the registration
-- away again.
--
-- The capture path is the caller that needs this. It owns its buffer and its
-- memory from the instant each exists, and on the path where it reaches the
-- end it frees both itself, exactly once, as it always did — so it then
-- recalls both registrations and teardown arrives at the ten entries it would
-- have arrived at if the capture had never registered anything. A run that
-- stopped inside the capture recalls neither, and teardown finds them.
onExitRecallable ∷ Cleanups → Handle → Cleanup → IO (IO ())
onExitRecallable cleanups handle cleanup = do
  ticket ← atomicModifyIORef' cleanups.cleanupNextTicket (\next → (next + 1, next))
  modifyIORef' cleanups.cleanupRegistered ((ticket, handle, cleanup) :)
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

-- | What became of one registered release.
data Release
  = Ran Disposal
    -- ^ It ran: what it destroyed, and what failed. The teardown boundary runs
    -- and destroys nothing, which is this with both lists empty.
  | Retained Text

-- | Whether the entry may be reported as released. An entry that had any
-- failure may not, however many of its children went.
released ∷ Release → Bool
released = \case
  Ran disposal → null disposal.disposalFailures
  Retained _ → False

-- | Tear down: the boundary first, then every release the recorded evidence
-- permits, in reverse registration order.
--
-- The boundary runs before any decision is taken because it is what produces
-- the evidence the decisions rest on — the device-idle result, and a bounded
-- wait on every present fence still owed. After it, the same pure
-- 'dispositionOf' the headless examples exercise says what may go and what
-- must stay.
--
-- It is asked one handle at a time rather than for the whole plan at once,
-- because the walk learns something no advance decision can know: whether a
-- release that already ran succeeded. A child whose release threw may still be
-- alive, so every parent that must outlive it is withheld exactly as a
-- retained child's parents are — destroying a device over a command pool whose
-- destruction failed is the same invalid teardown as destroying it over one
-- never registered. Releases that do not depend on it still run.
--
-- A registration that holds nothing is not in the plan at all. Its
-- construction stopped before it created anything, so there is nothing to
-- destroy, nothing to retain, and nothing its absence should hold up.
--
-- A release that fails is recorded and never allowed to hide the ones after
-- it; a release that is withheld is recorded with the condition that was
-- unmet. Neither is narrated separately from the values the verdict reads.
runCleanups ∷ Journal → Ledger → Cleanups → IO TeardownFacts
runCleanups journal ledger cleanups = do
  registered ← readIORef cleanups.cleanupRegistered
  writeIORef cleanups.cleanupRegistered []
  occupiedEntries ← filterM (\(_, _, cleanup) → cleanup.cleanupHolds) registered
  let entries = [(handle, cleanup.cleanupRelease) | (_, handle, cleanup) ← occupiedEntries]
  boundary ← forM [entry | entry@(TheTeardownBoundary, _) ← entries] (attempt journal)
  recorded ← observations ledger
  let plan = map fst entries
      standing = standingFrom recorded
      required = boundaryRequired plan
      walk _ [] = pure []
      walk withheld (entry@(handle, _) : rest) =
        case dispositionOf standing required withheld handle of
          Retain reason → do
            note journal ("teardown retained " <> describeHandle handle <> ": " <> reason)
            ((handle, Retained reason) :) <$> walk (withheld <> [(handle, "is retained")]) rest
          Destroy → do
            outcome ← attempt journal entry
            let withheld' = case outcome of
                  (_, Ran disposal)
                    | not (null disposal.disposalFailures) →
                        withheld <> [(handle, "was not released, because its own release failed")]
                  _ → withheld
            (outcome :) <$> walk withheld' rest
  later ← walk [] [entry | entry@(handle, _) ← entries, handle /= TheTeardownBoundary]
  settled ← observations ledger
  pure (teardownFactsFrom settled (boundary <> later))

attempt ∷ Journal → (Handle, IO Disposal) → IO (Handle, Release)
attempt journal (handle, action) = do
  outcome ← try @SomeException action
  -- A release that escaped its own aggregate is this entry's failure too,
  -- rather than one the record loses.
  let disposal = case outcome of
        Right ran → ran
        Left escaped → Disposal {disposalDestroyed = [], disposalFailures = [Text.pack (displayException escaped)]}
      named = [describeHandle handle <> ": " <> reason | reason ← disposal.disposalFailures]
  for_ named $ \reason → note journal ("teardown of " <> reason)
  pure (handle, Ran disposal {disposalFailures = named})

teardownFactsFrom ∷ [Observation] → [(Handle, Release)] → TeardownFacts
teardownFactsFrom recorded outcomes =
  TeardownFacts
    { teardownReleases = releasedEntries [(handle, released outcome) | (handle, outcome) ← outcomes]
    , teardownFailures = concat [disposal.disposalFailures | (_, Ran disposal) ← outcomes]
    , -- Exactly what was destroyed, named by the places the releases emptied.
      -- The boundary ran, and it is in 'teardownReleases' and in the
      -- observations it produced, but it destroyed nothing: it is the
      -- device-idle wait the rest rest on. This line is what a reader consults
      -- to learn which native objects were freed, so neither a wait nor a
      -- child a stopped construction never created belongs in it.
      teardownDestroyed =
        concat [disposal.disposalDestroyed | (handle, Ran disposal) ← outcomes, isDestruction handle]
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
