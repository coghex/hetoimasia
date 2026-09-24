-- | Fixtures the diagnostics examples share: loggers over observable sinks, a
-- sink that blocks until released, and waits that coordinate with the drain
-- worker explicitly rather than by sleeping.
module Test.GPU.Vulkan.Diagnostics.Support
  ( -- * Loggers
    Recorded
  , recordedEntries
  , recordingLogger
  , everythingFilter
  , Gate
  , newGate
  , openGate
  , awaitEntered
  , gatedLogger
  , failingLogger
  , SinkFailure (..)

    -- * Configuration
  , smallConfig
  , quietConfig
  , capturing

    -- * Waits
  , awaitDelivered
  , awaitInSink
  , awaitPhase
  , bounded

    -- * Offering
  , offerTo
  ) where

import Control.Concurrent.STM
  ( TVar
  , atomically
  , check
  , modifyTVar'
  , newTVarIO
  , readTVar
  , readTVarIO
  , writeTVar
  )
import Control.Exception (Exception, throwIO)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)

import Hetoimasia.Foundation.Log
  ( DebugSelection (DebugAll)
  , LogEntry
  , LogFilter (..)
  , Logger
  , LogLevel (Info)
  , MetadataProviders (..)
  , callbackSink
  , mkLoggerWith
  )
import Hetoimasia.GPU.Vulkan.Diagnostics
  ( CaptureConfig (..)
  , CapturePhase
  , DiagnosticCapture
  , DiagnosticVerdict
  , captureUserData
  , capturePhase
  , defaultCaptureConfig
  , deliveredCount
  , requestDrain
  , withDiagnosticCapture
  )
import Hetoimasia.GPU.Vulkan.Diagnostics.Internal.Capture (Offer, offer)
import Test.Support.Bounded (bounded)

import Data.Time.Clock (UTCTime (UTCTime))
import Data.Time.Calendar (fromGregorian)

-- | Everything a recording logger's sink was handed, oldest first.
newtype Recorded = Recorded (TVar [LogEntry])

recordedEntries ∷ Recorded → IO [LogEntry]
recordedEntries (Recorded entries) = reverse <$> readTVarIO entries

-- | Emits everything, 'Debug' included, with fixed metadata.
everythingFilter ∷ LogFilter
everythingFilter =
  LogFilter
    { filterEnabled = True
    , filterGlobalLevel = Info
    , filterComponentLevels = Map.empty
    , filterDebug = DebugAll
    , filterSource = False
    }

fixedMetadata ∷ MetadataProviders
fixedMetadata =
  MetadataProviders
    { metadataClock = pure (UTCTime (fromGregorian 2026 9 24) 0)
    , metadataThread = pure "test"
    }

recordingLogger ∷ LogFilter → IO (Logger, Recorded)
recordingLogger configuration = do
  entries ← newTVarIO []
  let sink = callbackSink (\entry → atomically (modifyTVar' entries (entry :)))
  pure (mkLoggerWith configuration fixedMetadata sink, Recorded entries)

-- | A sink that blocks every write until the gate opens, and says when a write
-- has entered it.
data Gate = Gate
  { gateOpen ∷ TVar Bool
  , gateEntered ∷ TVar Int
  }

newGate ∷ IO Gate
newGate = Gate <$> newTVarIO False <*> newTVarIO 0

openGate ∷ Gate → IO ()
openGate gate = atomically (writeTVar (gateOpen gate) True)

-- | Wait until at least this many writes have entered the sink.
awaitEntered ∷ Gate → Int → IO ()
awaitEntered gate count = bounded (atomically (readTVar (gateEntered gate) >>= check . (>= count)))

-- | A recording logger whose sink waits at the gate before recording.
gatedLogger ∷ Gate → IO (Logger, Recorded)
gatedLogger gate = do
  entries ← newTVarIO []
  let sink = callbackSink $ \entry → do
        atomically (modifyTVar' (gateEntered gate) (+ 1))
        atomically (readTVar (gateOpen gate) >>= check)
        atomically (modifyTVar' entries (entry :))
  pure (mkLoggerWith everythingFilter fixedMetadata sink, Recorded entries)

-- | What a failing sink throws.
data SinkFailure = SinkFailure
  deriving (Eq, Show)

instance Exception SinkFailure

-- | A logger whose sink fails every write, counting the attempts.
failingLogger ∷ IO (Logger, TVar Int)
failingLogger = do
  attempts ← newTVarIO 0
  let sink = callbackSink $ \_ → do
        atomically (modifyTVar' attempts (+ 1))
        throwIO SinkFailure
  pure (mkLoggerWith everythingFilter fixedMetadata sink, attempts)

-- | A four-record queue, a 64-byte budget and two objects.
smallConfig ∷ CaptureConfig
smallConfig =
  defaultCaptureConfig
    { captureQueueCapacity = 4
    , captureTextBudget = 64
    , captureObjectLimit = 2
    }

-- | A poll interval no example will ever reach, so every delivery an example
-- observes came from an explicit wake-up or the final drain.
quietConfig ∷ CaptureConfig → CaptureConfig
quietConfig config = config {capturePollInterval = 1000000000}

-- | A lifetime over 'smallConfig' with the quiet poll, bounded so a lifetime
-- that never finishes fails its example instead of hanging the suite.
capturing ∷ Logger → (DiagnosticCapture → IO a) → IO (a, DiagnosticVerdict)
capturing logger body = bounded (withDiagnosticCapture (quietConfig smallConfig) logger body)

-- | Wake the worker and wait until it has delivered at least this many records.
awaitDelivered ∷ DiagnosticCapture → Word64 → IO ()
awaitDelivered capture count = do
  requestDrain capture
  bounded (atomically (deliveredCount capture >>= check . (>= count)))

-- | Wake the worker and wait until it is inside the gated sink.
awaitInSink ∷ DiagnosticCapture → Gate → IO ()
awaitInSink capture gate = requestDrain capture >> awaitEntered gate 1

awaitPhase ∷ DiagnosticCapture → CapturePhase → IO ()
awaitPhase capture phase = bounded (atomically (capturePhase capture >>= check . (>= phase)))

-- | Offer a record through the package-local producer entry, with this
-- capture's user data.
offerTo ∷ DiagnosticCapture → Offer → IO ()
offerTo capture = offer (captureUserData capture)
