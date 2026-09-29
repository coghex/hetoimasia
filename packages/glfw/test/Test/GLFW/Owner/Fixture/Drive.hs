-- | What the graphics-owner examples of more than one spec module do to a
-- running owner, and how they wait for what it settles: turning the main
-- thread's owner loop, handing the host's one window over, publishing an
-- observation, waiting for the owner's rounds and its per-target records,
-- absorbing a cancellation, and naming an answer an example did not expect.
--
-- A helper one spec module alone uses stays beside its scenarios there.
module Test.GLFW.Owner.Fixture.Drive
  ( pumpUntil
  , pumpUntilRetired
  , theWindow
  , handedOver
  , sampledObservation
  , observed
  , accountedFor
  , awaitTerminal
  , awaitStanding
  , awaitConstructed
  , awaitRound
  , awaitIdle
  , awaitDiagnostic
  , absorbing
  , raisedBy
  , describeHandover
  , describeStart
  ) where

import Control.Concurrent (yield)
import Control.Concurrent.STM
  ( TVar
  , atomically
  , check
  , modifyTVar'
  , readTVar
  , retry
  )
import Control.Exception
  ( SomeAsyncException
  , SomeException
  , fromException
  , throwIO
  , try
  )
import Control.Monad (unless)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.GLFW.Window (WindowId, WindowObservation, WindowResult (..))
import Hetoimasia.Runtime.GLFW
import Hetoimasia.Runtime.Supervision (RuntimeControl, SupervisedStart (..))
import Numeric.Natural (Natural)
import Test.GLFW.Owner.Fixture.Journal (Note (..), Scene)
import Test.GLFW.Owner.Fixture.Rig (Rig (..))
import Test.GLFW.Support (SinkTrace, current, quietLogger, traced, unexpected)

-- | Run owner turns on the main thread until the condition holds.
--
-- An attachment retires on an owner turn, because that is when the main thread
-- folds the notices the owner published and offers each registration its
-- bounded opportunity. An example that waits for a retirement without turning
-- would be waiting for something nothing does.
pumpUntil ∷ WindowHost → RuntimeControl → String → IO Bool → IO ()
pumpUntil host control what ready =
  runOwnerLoop
    host
    control
    LoopHooks
      { loopLogger = quietLogger
      , loopEvent = noApplicationEvents
      , loopUpdate = \turn → do
          done ← ready
          if done
            then pure (Finish ())
            else
              if turnNumber turn > 2000
                then unexpected ("the loop never reached " <> what)
                else pure Continue
      }

-- | Turn until the host holds no pending attachment at all.
pumpUntilRetired ∷ WindowHost → RuntimeControl → IO ()
pumpUntilRetired host control =
  pumpUntil host control "an empty attachment set" (null <$> atomically (hostPendingAttachments host))

-- | The window the host configured, which every example attaches to.
theWindow ∷ WindowHost → IO WindowId
theWindow host =
  atomically (hostWindowIdentities host) >>= \case
    identity : _ → pure identity
    [] → unexpected "the host created no window"

-- | Hand the host's one window over, failing the example if it was not taken.
handedOver ∷ WindowHost → GraphicsOwner Scene → WindowId → IO GraphicsService
handedOver host owner window =
  handOverGraphicsTarget host owner window >>= \case
    TargetHandedOver service → pure service
    other → unexpected ("the target was not handed over: " <> show other)

sampledObservation ∷ WindowHost → WindowId → IO WindowObservation
sampledObservation host window =
  withHostWindow host window current >>= \case
    WindowAvailable seen → pure seen
    other → unexpected ("the window was not available: " <> show other)

-- | Publish one observation for a target, at the revision given.
observed ∷ GraphicsOwner Scene → GraphicsService → Natural → WindowObservation → IO ObservationPublication
observed owner service revision observation =
  publishGraphicsObservation owner service revision observation RenderEligible Nothing

-- | Every fact one terminal record established, published or still owed.
--
-- A record is written before its facts are offered to the transport, so which
-- side of the split a fact is on at the instant an example reads it is a
-- race. That they are all on one side or the other is not: it is exactly what
-- the record retaining them means.
accountedFor ∷ TerminalRecord → [RetirementFact]
accountedFor record = terminalPublished record <> terminalOwed record

-- | Wait until the owner has recorded a terminal record for this target.
awaitTerminal ∷ GraphicsOwner Scene → GraphicsService → IO TerminalRecord
awaitTerminal owner service = atomically $ do
  records ← readTargetTerminalsNow owner
  maybe retry pure (Map.lookup (graphicsAttachment service) records)

-- | Wait until the owner's own construction of this target has settled, and
-- answer what it settled as.
awaitStanding ∷ GraphicsOwner Scene → GraphicsService → IO TargetStanding
awaitStanding owner service = atomically $ do
  standing ← readTargetStanding owner (graphicsAttachment service)
  case standing of
    Just TargetConstructing → retry
    Just settled → pure settled
    Nothing → retry

-- | Wait until the owner's own construction of this target has settled, which
-- an example sees as the backend having been called for it.
awaitConstructed ∷ Rig → Text → IO ()
awaitConstructed rig name = atomically $ do
  notes ← readTVar (rigJournal rig)
  check (Constructed name `elem` notes)

-- | Wait until the owner has taken a round beyond the one given.
awaitRound ∷ GraphicsOwner Scene → Natural → IO OwnerStatus
awaitRound owner seen = atomically (awaitOwnerRound owner seen)

-- | Wait until the owner has settled into a round it will not leave by itself.
--
-- It is the owner's own idleness the example needs, not a count: the round
-- number is read once the owner has stopped advancing it, so the wait the
-- example then makes can only be ended by the publication it makes.
awaitIdle ∷ GraphicsOwner Scene → IO OwnerStatus
awaitIdle owner = do
  status ← atomically (awaitOwnerRound owner 0)
  settled ← atomically (readOwnerStatusNow owner)
  if statusRounds settled == statusRounds status then pure settled else awaitIdle owner

-- | Wait until the graphics owner's own component has written its one
-- diagnostic, which the exit writes before it settles into retaining.
-- The sink's record is an ordinary cell rather than a transaction, so this
-- polls it; 'yield' between polls is a scheduler hint, not a wait for a
-- timing outcome, and it keeps the poll from starving the thread it is
-- waiting for.
awaitDiagnostic ∷ SinkTrace → IO ()
awaitDiagnostic trace = do
  components ← traced trace
  unless (Text.pack "glfw.graphics-owner" `elem` components) (yield >> awaitDiagnostic trace)

-- | Absorb every asynchronous exception delivered while an action finishes.
absorbing ∷ TVar Int → IO () → IO ()
absorbing counter action = go
  where
    go =
      try action >>= \case
        Right () → pure ()
        Left caught
          | isJust (fromException caught ∷ Maybe SomeAsyncException) → do
              atomically (modifyTVar' counter (+ 1))
              go
          | otherwise → throwIO (caught ∷ SomeException)

-- | The failure a caught run raised, failing the example if it returned.
raisedBy ∷ Either SomeException a → IO SomeException
raisedBy = either pure (\_ → unexpected "the run returned instead of failing")

describeHandover ∷ GraphicsHandover → String
describeHandover = \case
  TargetHandedOver _ → "handed over"
  HandoverRefused _ → "refused"
  HandoverPortFull → "port full"
  HandoverOwnerClosed → "owner closed"
  HandoverSuperseded _ → "superseded"
  HandoverRolledBack _ → "rolled back"

describeStart ∷ SupervisedStart () → String
describeStart = \case
  WorkerStarted _ → "started"
  WorkerStartUnavailable _ _ → "unavailable"
  WorkerStartRejected → "rejected"
