{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

-- | The value gameplay publishes once per completed tick, and once more to end the session (#498
-- requirement 5, extended by #499 requirements 3, 8 and 12).
--
-- It carries the session's identity, the completed tick, the whole committed world, the dispositions
-- of the intentions the tick settled, a session status and the identity of the gameplay behavior
-- instance, which the UI needs to ask for its control. It is published with the foundation's
-- latest-value snapshot, one revision per publication, in the transaction that commits the tick, so a
-- reader sees a world with its own tick, dispositions and status and never a mixture of two ticks.
--
-- A session ends with at most one more publication, never two: the /failure/ snapshot, the last good
-- world and committed tick beside a 'Failed' status with its evidence and the intentions the failure
-- invalidated; or, for a stop of a session that has not failed, the /final/ snapshot with status
-- 'Stopped' and the intentions the stop discarded. Nothing published ever shows an effect of a tick that
-- did not commit, and no snapshot after the last good one shows a greater committed tick.
--
-- The UI reads it through the capture its owner takes at the start of each segment
-- ("Hetoimasia.Sample.LuaDomains.Shared.captureView"); nothing else reads it in production.
module Hetoimasia.Sample.LuaDomains.Snapshot
  ( GameSnapshot (..)
  , SessionStatus (..)
  , statusWord
  , SessionFailure (..)
  , FailureEvidence (..)
  , failureMessageLimit
  , initialSnapshot
  ) where

import Control.DeepSeq (NFData)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Word (Word64)
import GHC.Generics (Generic)
import Hetoimasia.Sample.LuaDomains.Intention (Dispositions, noDispositions)
import Hetoimasia.Sample.LuaDomains.World (World (worldSession))

-- | The most characters of an error's message the evidence keeps.
failureMessageLimit ∷ Int
failureMessageLimit = 512

-- | What failed, and where: one gameplay script failure, as the evidence names it.
data SessionFailure = SessionFailure
  { failWho ∷ !Text
    -- ^ The failing instance or task, by the name it was admitted under.
  , failPhase ∷ !Text
    -- ^ The phase the instance was in, or @task@ for a task.
  , failStage ∷ !Text
    -- ^ The hook or invocation: @init@, @update@, @run@, @shutdown@, an event's source, or @task@.
  , failTick ∷ !Word64
    -- ^ The tick it failed at: the tick in progress, or the last committed one when none was.
  , failKind ∷ !Text
    -- ^ The kind of error: a script fault, a refused wait, a delivery failure, a missing entry point.
  , failMessage ∷ !Text
    -- ^ The message, at most 'failureMessageLimit' characters.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | The bounded evidence of a failed session: the first failure, which is the session's, and how many
-- later ones were known when the snapshot was published.
data FailureEvidence = FailureEvidence
  { evidencePrimary ∷ !SessionFailure
  , evidenceLater ∷ !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | How the session is.
data SessionStatus
  = Running
  | -- | The gameplay behavior instance is paused, as the engine's own inspection of it says. Ticks
    -- are still granted and committed, and accepted intentions are still applied.
    Paused
  | -- | The session failed, with this evidence. Terminal; nothing is retried or restarted.
    Failed !FailureEvidence
  | -- | A stop ended the session. Terminal.
    Stopped
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | The status as one word: what the UI is told and the report prints.
statusWord ∷ SessionStatus → Text
statusWord = \case
  Running → "running"
  Paused → "paused"
  Failed _ → "failed"
  Stopped → "stopped"

-- | One published tick, or the end of the session.
data GameSnapshot = GameSnapshot
  { snapSession ∷ !Word64
  , snapTick ∷ !Word64
    -- ^ The completed tick; zero before the first. Unchanged by a failure or a stop.
  , snapWorld ∷ !World
  , snapDispositions ∷ !Dispositions
    -- ^ What the publication settled: a tick's applied places and stale rejections, or what the
    -- end of the session invalidated or discarded.
  , snapStatus ∷ !SessionStatus
  , snapGameplay ∷ !(Maybe (Int64, Int64, Int64))
    -- ^ The gameplay behavior instance's identity as a script holds it: runtime, owner and number.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | The snapshot before the first tick, which the snapshot holds as its initial value.
initialSnapshot ∷ World → Maybe (Int64, Int64, Int64) → GameSnapshot
initialSnapshot world identity =
  GameSnapshot
    { snapSession = worldSession world
    , snapTick = 0
    , snapWorld = world
    , snapDispositions = noDispositions
    , snapStatus = Running
    , snapGameplay = identity
    }
