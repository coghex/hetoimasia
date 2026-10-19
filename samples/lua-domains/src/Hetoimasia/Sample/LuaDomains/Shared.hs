-- | The state the two owners' bindings borrow, built before either owner and outliving both.
--
-- = Ownership
--
-- Every field is one of the sample's own values, never a Lua value and never a handle into a VM.
-- It is created by 'newShared' on the application thread before any owner starts, is borrowed by
-- the bindings the owners are registered with, and is dropped with the session. Who writes what:
--
-- * 'sharedCommitted' and 'sharedTick': the driver, on the application thread, once per tick —
--   it makes the tick's candidate before granting the tick and replaces the committed world when
--   the tick has completed. Between the two the gameplay owner's bindings, which run on the owner's
--   callback thread, are the candidate's only writers.
-- * 'sharedView': the UI owner's thread, at the start of each of its segments. The UI's bindings
--   read it, on a thread of the owner's own, one segment at a time.
-- * 'sharedQueue', 'sharedCounts': any thread, through the transactions of "Hetoimasia.Sample.LuaDomains.Queue"
--   and this module.
-- * 'sharedInput': the UI owner's bindings only.
-- * 'sharedUpdates': the UI owner's bindings only.
--
-- The UI never reads 'sharedCommitted' or 'sharedTick'; gameplay never reads 'sharedView' or the
-- snapshot. Each owner's namespaces are the only way its VM reaches any of this
-- ("Hetoimasia.Sample.LuaDomains.Registration").
module Hetoimasia.Sample.LuaDomains.Shared
  ( Shared (..)
  , newShared
  , AdmissionDefect (..)
    -- * The UI's operations
  , captureView
  , currentView
  , submit
  , noteMalformed
  , ScriptedInput (..)
  , scriptedInputs
  , pollInput
  , noteUpdate
    -- * Gameplay's operations
  , StageAnswer (..)
  , gameplayWorld
  , gameplayStage
  , gameplayDraw
  , gameplayFinish
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, throwSTM, writeTVar)
import Control.Exception (Exception)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.Foundation.Messaging.Payload (prepare, preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot
  ( SnapshotPublisher
  , newSnapshot
  , observedValue
  , readSnapshot
  , snapshotReader
  )
import Hetoimasia.Sample.LuaDomains.Bounds (Bounds)
import Hetoimasia.Sample.LuaDomains.Candidate (Candidate (..), Move, StagingRefusal, draw, finish, stage)
import Hetoimasia.Sample.LuaDomains.Intention (Answer (..), Submitted, validate)
import Hetoimasia.Sample.LuaDomains.Queue (AdmitAt (..), Queue, admitNext, newQueue)
import Hetoimasia.Sample.LuaDomains.Snapshot (GameSnapshot, initialSnapshot)
import Hetoimasia.Sample.LuaDomains.Tally (Counts, countAnswer, noCounts)
import Hetoimasia.Sample.LuaDomains.World (World, initialWorld)

-- | The sample's shared state, owned as the module header says.
data Shared = Shared
  { sharedBounds ∷ !Bounds
  , sharedQueue ∷ !Queue
  , sharedCommitted ∷ !(TVar World)
  , sharedTick ∷ !(TVar (Maybe Candidate))
  , sharedCounts ∷ !(TVar Counts)
  , sharedPublisher ∷ !(SnapshotPublisher GameSnapshot)
  , sharedView ∷ !(TVar GameSnapshot)
  , sharedInput ∷ !(TVar [ScriptedInput])
  , sharedUpdates ∷ !(TVar Int)
  }

-- | A session's state: the world at its seed, the snapshot holding it as revision zero, an empty
-- queue (of a finite session's ticks, if it is finite), and this fake input.
newShared ∷ Bounds → Word64 → Word64 → Maybe Word64 → [ScriptedInput] → IO Shared
newShared bounds session seed final input = do
  let world = initialWorld bounds session seed
      first = initialSnapshot world
  publisher ← newSnapshot =<< prepare first
  Shared bounds
    <$> newQueue bounds final
    <*> newTVarIO world
    <*> newTVarIO Nothing
    <*> newTVarIO noCounts
    <*> pure publisher
    <*> newTVarIO first
    <*> newTVarIO input
    <*> newTVarIO 0

-- | The admission seam answered something the UI's path cannot: a late tick or a duplicate place.
-- It is a defect of the sample, raised as a failure of the host and never counted away.
newtype AdmissionDefect = AdmissionDefect Text
  deriving (Eq, Show)

instance Exception AdmissionDefect

-- The UI -----------------------------------------------------------------------

-- | Capture the latest committed snapshot as the view of the UI segment about to begin. The UI
-- owner calls it, on its own thread, as each segment is about to run; every query the segment
-- makes answers from this one capture.
captureView ∷ Shared → IO ()
captureView shared = atomically $ do
  observation ← readSnapshot (snapshotReader (sharedPublisher shared))
  writeTVar (sharedView shared) (preparedValue (observedValue observation))

-- | The capture the running UI segment answers from.
currentView ∷ Shared → IO GameSnapshot
currentView shared = atomically (readTVar (sharedView shared))

-- | Submit an intention, as the UI's binding does: apply the application's bounds, then ask the
-- queue for the next tick that has not started, and count the answer, all in one transaction. It
-- never waits, and the answer is the one the script is told.
submit ∷ Shared → Submitted → IO Answer
submit shared submitted = atomically $ do
  answer ← case validate (sharedBounds shared) submitted of
    Left refusal → pure (Refused refusal)
    Right intention →
      admitNext (sharedQueue shared) intention >>= \case
        AdmittedAt place → pure (Accepted place)
        AtFull → pure Full
        AtClosed → pure Closed
        AtLate → throwSTM (AdmissionDefect "the UI's path was answered late")
        AtDuplicate → throwSTM (AdmissionDefect "the UI's path was answered a duplicate place")
  modifyTVar' (sharedCounts shared) (countAnswer (Just answer))
  pure answer

-- | Count a call the facade refused for its arity or types, which never reached 'submit'.
noteMalformed ∷ Shared → IO ()
noteMalformed shared = atomically (modifyTVar' (sharedCounts shared) (countAnswer Nothing))

-- | One entry of the fixed fake input: which entity the user nudged, and by how much.
data ScriptedInput = ScriptedInput
  { inputEntity ∷ !Int64
  , inputDx ∷ !Int64
  , inputDy ∷ !Int64
  }
  deriving (Eq, Show)

-- | The fake input source's list, the same on every run: forty entries cycling through the first
-- eight entities, with deltas from two short tables.
scriptedInputs ∷ [ScriptedInput]
scriptedInputs =
  [ ScriptedInput (fromIntegral ((index * 3) `mod` 8)) (dxs !! (index `mod` 8)) (dys !! ((index + 3) `mod` 8))
  | index ← [0 .. 39 ∷ Int]
  ]
  where
    dxs = [1, -1, 2, 0, -2, 1, 0, 3]
    dys = [0, 1, -1, 2, 0, -2, 1, -1]

-- | The next scripted input, taking it from the source.
pollInput ∷ Shared → IO (Maybe ScriptedInput)
pollInput shared = atomically $
  readTVar (sharedInput shared) >>= \case
    [] → pure Nothing
    next : rest → Just next <$ writeTVar (sharedInput shared) rest

-- | A UI update finished.
noteUpdate ∷ Shared → IO ()
noteUpdate shared = atomically (modifyTVar' (sharedUpdates shared) (+ 1))

-- Gameplay ---------------------------------------------------------------------

-- | What staging a move answered.
data StageAnswer
  = Staged
  | StageRefused !StagingRefusal
  | -- | No tick is in progress, so there is no batch.
    NoTickInProgress
  deriving (Eq, Show)

-- | Read the world gameplay sees: the tick's candidate, which has the tick's applied intentions in
-- it, and outside a tick the committed world.
gameplayWorld ∷ Shared → IO (World, Maybe Word64)
gameplayWorld shared = atomically $ do
  candidate ← readTVar (sharedTick shared)
  case candidate of
    Just working → pure (candidateWorld working, Just (candidateTick working))
    Nothing → (\world → (world, Nothing)) <$> readTVar (sharedCommitted shared)

-- | Stage a move into the tick's batch.
gameplayStage ∷ Shared → Move → IO StageAnswer
gameplayStage shared move = atomically (withCandidate shared NoTickInProgress $ \candidate →
  case stage (sharedBounds shared) move candidate of
    Left refusal → (StageRefused refusal, candidate)
    Right staged → (Staged, staged))

-- | Draw from the candidate's stream: a value in @[0, n)@, or 'Nothing' for a bound the stream
-- does not accept or when no tick is in progress. A draw advances the candidate's stream only.
gameplayDraw ∷ Shared → Int64 → IO (Maybe Int64)
gameplayDraw shared bound = atomically (withCandidate shared Nothing $ \candidate →
  case draw bound candidate of
    Nothing → (Nothing, candidate)
    Just (value, next) → (Just value, next))

-- | Say gameplay's work for the tick is done. Answers whether there was a tick to finish.
gameplayFinish ∷ Shared → IO Bool
gameplayFinish shared = atomically (withCandidate shared False (\candidate → (True, finish candidate)))

-- | Run a pure step over the tick's candidate, or answer this when none is in progress.
withCandidate ∷ Shared → a → (Candidate → (a, Candidate)) → STM a
withCandidate shared none step = do
  candidate ← readTVar (sharedTick shared)
  case candidate of
    Nothing → pure none
    Just working → do
      let (answer, next) = step working
      next `seq` writeTVar (sharedTick shared) (Just next)
      pure answer
