-- | Bounded, record-only evidence of when an owner turn's native event pump
-- ran, when a window callback was delivered, and how far the turn got.
--
-- This is measurement storage, not a second logger and not a diagnostic path.
-- A session always owns one ('Hetoimasia.GLFW.Internal.Session.sessionTrace'),
-- and it is stopped until something starts it, so an ordinary run reads one
-- 'IORef' per recording point and does nothing else. Only an explicitly
-- activated probe starts one; nothing in the runtime, the host, or the window
-- model ever does.
--
-- = What it is for
--
-- GLFW documents that on some platforms a window move, a window resize, or a
-- menu interaction runs a platform modal loop /inside/ @glfwPollEvents@ or
-- @glfwWaitEventsTimeout@, and that it may deliver callbacks from in there. An
-- owner turn does its reconciliation, command dispatch, and update opportunity
-- only after that call returns
-- ("Hetoimasia.Runtime.GLFW.Internal.runOwnerLoop"), so whether such a loop
-- exists on a platform is the difference between a turn that keeps progressing
-- during the interaction and one that does not. Answering that needs one
-- ordered, timestamped record of the pump's own entry and exit, of every
-- callback delivered between them, and of the turn work and update hook that
-- follow — which is what this holds.
--
-- = One time domain
--
-- Every record is stamped from the one 'MonotonicSource' 'startTrace' was
-- given, so pump entries and exits, callback deliveries, turn beginnings, and
-- update-hook progress are all comparable with each other and with nothing
-- else. Instants are monotonic readings, not wall-clock times.
--
-- = Bounded, and honest when it overflows
--
-- A running trace keeps the first 'recordingCapacity' records it is given and
-- counts every later one in 'evidenceLost'. Sequence numbers are issued to lost
-- records too, so a gap in 'recordSequence' is visible rather than silent. A
-- recording that could not read the clock or could not store its record is
-- counted in 'evidenceFaults' and never raised, because a recording point may
-- be inside a C callback frame. Evidence with either count above zero is
-- incomplete ('evidenceComplete'): missing records are then no proof that a
-- turn made no progress or that no callback arrived.
--
-- = What it costs where it is recorded
--
-- Recording is one clock reading and one non-blocking 'atomicModifyIORef'',
-- under 'uninterruptibleMask_', with no sink, no lock, no wait, and no output.
-- Reading the evidence out is a separate step a caller takes between
-- measurement intervals ('takeTrace'), so formatting and printing never happen
-- inside one.
module Hetoimasia.GLFW.Internal.Trace
  ( -- * The trace
    Trace
  , newTrace
  , startTrace
  , stopTrace
  , takeTrace
  , traceRunning
  , defaultTraceCapacity

    -- * What a record says
  , PumpMode (..)
  , TraceEvent (..)
  , TraceRecord (..)
  , TraceEvidence (..)
  , noEvidence
  , evidenceComplete

    -- * Recording
  , recordTrace
  , recordingPump
  ) where

import Control.Exception (SomeException, onException, try, uninterruptibleMask_)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Hetoimasia.Foundation.Time (Instant, MonotonicSource, readInstant)
import Numeric.Natural (Natural)

-- | Which native event call an owner turn made.
data PumpMode
  = PolledEvents
    -- ^ @glfwPollEvents@: process what is pending and return.
  | WaitedForEvents !Double
    -- ^ @glfwWaitEventsTimeout@ with the seconds the turn asked for. The
    -- seconds are the /requested/ bound, never a promise about the call's
    -- duration.
  deriving (Eq, Show)

-- | One thing worth knowing the time of.
data TraceEvent
  = TurnBegan !Natural
    -- ^ An owner turn is about to make its native event step, with the turn
    -- number the loop gave it.
  | PumpEntered !PumpMode
    -- ^ The native event call is about to run.
  | PumpLeft !PumpMode
    -- ^ The native event call returned, or raised. Recorded either way.
  | CallbackDelivered !Text !Text
    -- ^ A window callback was entered, named by the window's local identity
    -- and the callback's own name. Recorded before the callback records
    -- anything into its window's capture latch, so a delivery whose latching
    -- then faults still appears here.
  | UpdateHookEntered !Natural
    -- ^ The application's update opportunity for that turn began.
  | UpdateHookLeft !Natural
    -- ^ It returned.
  | Marked !Text
    -- ^ Whatever the measuring caller wanted placed in the order: the
    -- beginning and end of an interaction it asked a person to perform, for
    -- instance. This is how a human interaction is associated with the trace.
  deriving (Eq, Show)

-- | One record: when it happened, what happened, and where it sits in the
-- order.
data TraceRecord = TraceRecord
  { recordSequence ∷ !Natural
    -- ^ Issued in order from one, to kept and lost records alike, so a gap
    -- names how many records are missing and where.
  , recordInstant ∷ !Instant
    -- ^ From the trace's own monotonic source.
  , recordEvent ∷ !TraceEvent
  }
  deriving (Eq, Show)

-- | What a trace held when it was read.
data TraceEvidence = TraceEvidence
  { evidenceRecords ∷ ![TraceRecord]
    -- ^ Oldest first.
  , evidenceLost ∷ !Natural
    -- ^ Records the bound refused after the buffer was full.
  , evidenceFaults ∷ !Natural
    -- ^ Recordings that could not read the clock or could not be stored.
  }
  deriving (Eq, Show)

-- | Nothing recorded, nothing lost, nothing faulted.
noEvidence ∷ TraceEvidence
noEvidence = TraceEvidence [] 0 0

-- | Whether the evidence is every record the run produced.
--
-- False means the buffer overflowed or a recording faulted, so an absence in
-- 'evidenceRecords' proves nothing.
evidenceComplete ∷ TraceEvidence → Bool
evidenceComplete evidence = evidenceLost evidence == 0 && evidenceFaults evidence == 0

-- | How many records a trace keeps when the caller states no other bound.
--
-- Large enough for a several-minute interactive run at ordinary owner-turn and
-- callback rates, and small enough to be an ordinary allocation.
defaultTraceCapacity ∷ Int
defaultTraceCapacity = 32768

-- | The measurement storage of one session. Its representation is private.
newtype Trace = Trace (IORef (Maybe Recording))

-- | A running trace's storage: newest first, under its bound.
data Recording = Recording
  { recordingClock ∷ !MonotonicSource
  , recordingCapacity ∷ !Int
  , recordingNext ∷ !Natural
  , recordingKept ∷ !Int
  , recordingNewest ∷ ![TraceRecord]
  , recordingLost ∷ !Natural
  , recordingFaults ∷ !Natural
  }

-- | A stopped trace, which records nothing until 'startTrace'.
newTrace ∷ IO Trace
newTrace = Trace <$> newIORef Nothing

-- | Start recording against a clock, keeping at most that many records.
--
-- A negative capacity keeps none and counts everything lost. Starting a trace
-- that is already running discards what it held and begins again, so a caller
-- never inherits an earlier measurement's records by accident.
startTrace ∷ Trace → MonotonicSource → Int → IO ()
startTrace (Trace state) clock capacity =
  atomicModifyIORef' state (\_ → (Just (fresh clock (max 0 capacity)), ()))

fresh ∷ MonotonicSource → Int → Recording
fresh clock capacity =
  Recording
    { recordingClock = clock
    , recordingCapacity = capacity
    , recordingNext = 1
    , recordingKept = 0
    , recordingNewest = []
    , recordingLost = 0
    , recordingFaults = 0
    }

-- | Stop recording and answer everything the trace held. A trace that was not
-- running answers 'noEvidence'.
stopTrace ∷ Trace → IO TraceEvidence
stopTrace (Trace state) =
  atomicModifyIORef' state (\current → (Nothing, maybe noEvidence evidenceOf current))

-- | Answer everything the trace holds and keep recording, with an empty buffer
-- and both counts cleared.
--
-- Sequence numbers continue across the take, so records lost before it stay
-- distinguishable from records kept after it. A trace that is not running
-- answers 'noEvidence' and stays stopped.
takeTrace ∷ Trace → IO TraceEvidence
takeTrace (Trace state) =
  atomicModifyIORef' state $ \case
    Nothing → (Nothing, noEvidence)
    Just recording →
      ( Just recording {recordingKept = 0, recordingNewest = [], recordingLost = 0, recordingFaults = 0}
      , evidenceOf recording
      )

-- | Whether the trace is recording.
traceRunning ∷ Trace → IO Bool
traceRunning (Trace state) = maybe False (const True) <$> readIORef state

-- | Record one event, now.
--
-- Does nothing at all when the trace is stopped. Never raises: a clock reading
-- or a store that fails is counted in 'evidenceFaults', because callers include
-- window callbacks, which must not unwind into C.
recordTrace ∷ Trace → TraceEvent → IO ()
recordTrace trace@(Trace state) event =
  readIORef state >>= \case
    Nothing → pure ()
    Just recording → uninterruptibleMask_ $
      try (readInstant (recordingClock recording)) >>= \case
        Left (_ ∷ SomeException) → fault trace
        Right instant →
          try (store trace instant event) >>= \case
            Left (_ ∷ SomeException) → fault trace
            Right () → pure ()

-- | Record the native event call's entry, run it, and record its exit, whether
-- it returns or raises.
recordingPump ∷ Trace → PumpMode → IO a → IO a
recordingPump trace mode pump = do
  recordTrace trace (PumpEntered mode)
  result ← pump `onException` recordTrace trace (PumpLeft mode)
  recordTrace trace (PumpLeft mode)
  pure result

store ∷ Trace → Instant → TraceEvent → IO ()
store (Trace state) instant event =
  atomicModifyIORef' state $ \case
    Nothing → (Nothing, ())
    Just recording
      | recordingKept recording < recordingCapacity recording →
          let !record = TraceRecord (recordingNext recording) instant event
           in ( Just
                  recording
                    { recordingNext = recordingNext recording + 1
                    , recordingKept = recordingKept recording + 1
                    , recordingNewest = record : recordingNewest recording
                    }
              , ()
              )
      | otherwise →
          ( Just
              recording
                { recordingNext = recordingNext recording + 1
                , recordingLost = recordingLost recording + 1
                }
          , ()
          )

fault ∷ Trace → IO ()
fault (Trace state) =
  atomicModifyIORef' state $ \case
    Nothing → (Nothing, ())
    Just recording → (Just recording {recordingFaults = recordingFaults recording + 1}, ())

evidenceOf ∷ Recording → TraceEvidence
evidenceOf recording =
  TraceEvidence (reverse (recordingNewest recording)) (recordingLost recording) (recordingFaults recording)
