-- | The scheduler's state and every transition over it, as pure functions.
--
-- One 'SchedState' holds the protocol model's session (tasks, the admission
-- queue, reserved result storage, ordinals) and what scheduling adds around
-- it: the class pass, logical time and its grants, the two kinds of waiter, the
-- queue of control requests, the phase, and the counters. The facade keeps it in
-- one variable, so each function here is one transaction's worth and an
-- invariant is a property of a single step rather than of an interleaving.
--
-- Nothing here reads a clock or a source of randomness, performs IO or chooses
-- anything but through the policy it is handed: the same inputs in the same
-- order give the same states. The instants it uses are arguments.
module Hetoimasia.Scripting.Lua.Scheduler.State
  ( -- * State
    SchedState (..)
  , Pass (..)
  , Phase (..)
  , TaskInfo (..)
  , WaitRecord (..)
  , Grant (..)
  , LogicalCadence (..)
  , ElapsedCadence (..)
  , Slot (..)
  , PendingControl (..)
  , initialState
  , maxOverrunSites

    -- * Reading
  , readyCandidates
  , workPending
  , phaseOf
  , diagnosticsOf
  , outstandingGrants
  , earliestDeadline
  , elapsedDemand
  , liveTarget
  , liveCount

    -- * Admission
  , admitIn
  , activateQueued

    -- * Choosing and running
  , Selection (..)
  , selectNext
  , beginSegment
  , Event (..)
  , applyReport
  , siteOf
  , recordOverrunAt
  , resetPassIfIdle
  , closeObligations
  , closedObligation
  , retainEvidence
  , deliverEvidence
  , acknowledgeEvidence

    -- * Time
  , settleGrants
  , wakeDueElapsed
  , grantIn

    -- * Cadences
  , cadenceStartLogical
  , cadenceStartElapsed
  , cadenceArmLogical
  , cadenceArmElapsed
  , cadenceDisarm
  , cadenceStop
  , cadenceTake
  , cadenceRelease
  , cadenceAccruedOf
  , cadenceResetAccrued
  , cadenceHeldBy

    -- * Control
  , pauseIn
  , resumeIn
  , cancelIn
  , stoppableTasks
  ) where

import Control.Concurrent.STM (TVar)
import Control.Exception (SomeException)
import Data.Foldable (toList)
import Data.List (sortOn)
import Data.Maybe (isJust)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Sequence (Seq, ViewL (EmptyL, (:<)), (|>))
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Foundation.Time
  ( Duration
  , Instant
  , addDuration
  , addDurations
  , deadlineReached
  , elapsedBetween
  , zeroDuration
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Failure
  ( ReasonCode (ValidationFault)
  , RecoverySafety (RecoverySafe)
  , failureReason
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity (TaskId)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Limits
  ( Limits (maxActiveTasks)
  , ServiceClass (..)
  , limitQuanta
  , limitsOf
  , quantumFor
  , quantumSegments
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session
  ( AdmissionRequest (..)
  , Authority (Mutating)
  , Session (sessionKey, sessionLimits, sessionQueued, sessionTasks)
  , SessionRejection (AdmissionIsClosed, CapReached, SessionAlreadyStopped)
  , TerminalResult (ResultFailed)
  , activateNext
  , applyOutcome
  , cancelTaskIn
  , pauseTaskIn
  , requestAdmission
  , resumeTaskIn
  , startSegment
  , wakeTaskIn
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Revocation (retire)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Step (queuedHere, transition)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Task
  ( Readiness (Readiness)
  , SegmentOutcome (SegmentCompleted, SegmentWaiting, SegmentYielded)
  , Task (..)
  , TaskFailure (TaskFailure)
  , TaskState (Paused, Ready, Running, Waiting)
  , WaitCause (WaitingUntil)
  , failTask
  , isTerminal
  , terminalOutcome
  )
import Hetoimasia.Scripting.Lua.Scheduler.Types

-- State ------------------------------------------------------------------------

-- | Where the class pass stands: the class being served and how many of its
-- quantum it has used. It persists across turns, which is what keeps a budget's
-- cutoff from restarting the pass or replenishing a quantum.
data Pass = Pass
  { passClass ∷ !ServiceClass
  , passServed ∷ !Int
  }
  deriving (Eq, Show)

-- | Whether the scheduler admits work.
data Phase
  = Open
  | -- | A stop has begun: admission is closed and continuations are closing.
    Closing
  | Closed !StopReport

-- | What waiting is on, with the order it began in.
data WaitRecord
  = LogicalWait
      { waitSequence ∷ !Word64
      , waitTarget ∷ !Word64
      , waitGranted ∷ !Duration
      }
  | ElapsedWait
      { waitSequence ∷ !Word64
      , waitStart ∷ !Instant
      , waitDeadline ∷ !Instant
      }

-- | What the scheduler adds to a task's model record.
data TaskInfo = TaskInfo
  { infoKind ∷ !TaskKind
  , infoEntry ∷ !Text
  , infoName ∷ !(Maybe Text)
  , infoWait ∷ !(Maybe WaitRecord)
  , infoHeld ∷ !Bool
    -- ^ Paused while waiting. The model pauses only a ready task, so the wait
    -- and its continuation are kept as they are and the task is not woken.
  , infoEarned ∷ !(Maybe Resume)
    -- ^ A wake the wait earned while the task was held, kept until it resumes.
  , infoResume ∷ !(Maybe Resume)
    -- ^ What the next segment is handed.
  , infoDue ∷ !(Maybe GrantId)
    -- ^ The grant whose wake made the task ready and has not yet seen it finish.
  }

-- | A logical cadence an owner registered: the tick it is next due at, the logical
-- duration granted since its accrual began, whether it is accruing, and the grant it
-- holds while its point is being served.
data LogicalCadence = LogicalCadence
  { lcTarget ∷ !(Maybe Word64)
  , lcAccrued ∷ !Duration
  , lcAccruing ∷ !Bool
    -- ^ Whether the grants applied are added to what it has accrued: not while the
    -- owner has disarmed it.
  , lcHold ∷ !(Maybe GrantId)
  }

-- | An elapsed cadence an owner registered: the deadline it is next due at.
newtype ElapsedCadence = ElapsedCadence {ecDeadline ∷ Maybe Instant}

-- | One accepted grant, until its work has finished.
data Grant = Grant
  { grantDuration ∷ !Duration
  , grantApplied ∷ !Bool
  , grantDue ∷ !Int
    -- ^ Tasks it woke that are still ready or running.
  }

-- | The place an accepted control request's settlement is written, once.
data Slot = Slot
  { slotSettlement ∷ !(TVar (Maybe ControlSettlement))
  , slotReleased ∷ !(TVar Bool)
  , slotForgotten ∷ !(TVar Bool)
  }

-- | An accepted control request, until it is applied.
data PendingControl = PendingControl
  { pendingTask ∷ !TaskId
  , pendingRequest ∷ !ControlRequest
  , pendingSlot ∷ !Slot
  }

-- | Everything one scheduler holds.
data SchedState v = SchedState
  { ssLabel ∷ !Text
  , ssSession ∷ !(Session v)
  , ssInfo ∷ !(Map TaskId TaskInfo)
  , ssPass ∷ !Pass
  , ssTick ∷ !Word64
  , ssGrants ∷ !(Seq Grant)
  , ssNextGrant ∷ !Word64
  , ssLogical ∷ !(Map Word64 TaskId)
  , ssElapsed ∷ !(Map (Instant, Word64) TaskId)
  , ssNextWait ∷ !Word64
  , ssCadenceLogical ∷ !(Map CadenceKey LogicalCadence)
  , ssCadenceElapsed ∷ !(Map CadenceKey ElapsedCadence)
  , ssFirings ∷ !(Seq (CadenceKey, CadenceFiring))
    -- ^ The cadence points reached and not yet taken, in the order they were reached.
  , ssControl ∷ !(Seq PendingControl)
  , ssReserved ∷ !Int
  , ssPhase ∷ !Phase
  , ssCounts ∷ !Diagnostics
  , ssSites ∷ !(Map (TaskKind, Text) Int)
  , ssEvidence ∷ !(Seq (TaskId, SomeException))
    -- ^ Failures of closes that have been made and not yet reported: kept here,
    -- not in a turn's local accumulator, so an exception that ends the turn cannot
    -- lose them. A turn's report takes them, and so does the scheduler's stop.
  , ssDelivered ∷ !(Seq (TaskId, SomeException))
    -- ^ The failures the last turn report carried, until the next turn starts. A
    -- report can be lost to an exception on its way out, so the stop reports these
    -- too: evidence is never dropped, and at worst it is reported twice.
  , ssToClose ∷ !(Set TaskId)
    -- ^ Tasks that ended while their continuation was suspended and whose
    -- continuation has not yet been closed: a refused wait, a wait that could not
    -- be applied. The obligation stays until the close has been made.
  }

-- | The most overrun sites one scheduler attributes. A site is a kind of work
-- and an entry point; an overrun of a site that finds the table full is counted
-- but not attributed, so the table is bounded whatever work is admitted.
maxOverrunSites ∷ Int
maxOverrunSites = 32

startOfPass ∷ Pass
startOfPass = Pass ControlClass 0

-- | A scheduler with nothing admitted, over a session.
initialState ∷ Text → Session v → SchedState v
initialState label session =
  SchedState
    { ssLabel = label
    , ssSession = session
    , ssInfo = Map.empty
    , ssPass = startOfPass
    , ssTick = 0
    , ssGrants = Seq.empty
    , ssNextGrant = 0
    , ssLogical = Map.empty
    , ssElapsed = Map.empty
    , ssNextWait = 0
    , ssCadenceLogical = Map.empty
    , ssCadenceElapsed = Map.empty
    , ssFirings = Seq.empty
    , ssControl = Seq.empty
    , ssReserved = 0
    , ssPhase = Open
    , ssCounts =
        Diagnostics
          { diagOwner = label
          , diagAdmitted = 0
          , diagRejected = 0
          , diagQueued = 0
          , diagQueueHighWater = 0
          , diagActive = 0
          , diagActiveHighWater = 0
          , diagCompleted = 0
          , diagYielded = 0
          , diagWaiting = 0
          , diagFailed = 0
          , diagCancelled = 0
          , diagDiscarded = 0
          , diagSegmentsByClass = [(serviceClass, 0) | serviceClass ← [minBound .. maxBound]]
          , diagOverruns = 0
          , diagOverrunSites = []
          , diagOverrunsUnattributed = 0
          , diagRefusedChoices = 0
          , diagRefusedWaits = 0
          , diagControlAccepted = 0
          , diagControlRefused = 0
          , diagGrantsAccepted = 0
          , diagGrantsRefused = 0
          , diagTick = 0
          }
    , ssSites = Map.empty
    , ssEvidence = Seq.empty
    , ssDelivered = Seq.empty
    , ssToClose = Set.empty
    }

-- | Count one more, never past the largest number.
bump ∷ Int → Int
bump count
  | count == maxBound = count
  | otherwise = count + 1

counting ∷ (Diagnostics → Diagnostics) → SchedState v → SchedState v
counting change state = state {ssCounts = change (ssCounts state)}

-- Reading ----------------------------------------------------------------------

-- | The tasks that are not finished and have left the queue.
liveCount ∷ SchedState v → Int
liveCount state = Map.size (Map.filter (not . isTerminal . taskState) (sessionTasks (ssSession state)))

-- | Every ready task, in ascending 'Ordinal' order.
readyCandidates ∷ SchedState v → [Candidate]
readyCandidates state =
  sortOn
    candidateOrdinal
    [ Candidate (taskIdentity task) (taskService task) (infoKind info) (taskOrdinal task) (taskSegments task)
    | (identity, task) ← Map.toList (sessionTasks (ssSession state))
    , taskState task == Ready
    , Just info ← [Map.lookup identity (ssInfo state)]
    ]

-- | Whether a turn would have anything to do: a ready task, an admission that
-- an active slot is free for, a control request, or a grant to apply.
workPending ∷ SchedState v → Bool
workPending state =
  any ((== Ready) . taskState) (Map.elems (sessionTasks (ssSession state)))
    || (not (Seq.null (sessionQueued (ssSession state))) && slotFree state)
    || not (Seq.null (ssControl state))
    || grantWaiting
  where
    grantWaiting = case Seq.viewl (ssGrants state) of
      grant :< _ → not (grantApplied grant)
      EmptyL → False

slotFree ∷ SchedState v → Bool
slotFree state =
  Map.size (sessionTasks session) < maxActiveTasks (limitsOf (sessionLimits session))
  where
    session = ssSession state

-- | Where a task is.
phaseOf ∷ TaskId → SchedState v → Maybe TaskPhase
phaseOf identity state = case Map.lookup identity (sessionTasks (ssSession state)) of
  Just task → Just $ case taskState task of
    Ready → PhaseReady
    Running → PhaseRunning
    Paused → PhasePaused
    Waiting _
      | held → PhasePaused
      | otherwise → PhaseWaiting
    terminal → maybe PhaseReady PhaseEnded (terminalOutcome terminal)
  Nothing
    | queuedHere identity (ssSession state) → Just PhaseQueued
    | otherwise → Nothing
  where
    held = maybe False infoHeld (Map.lookup identity (ssInfo state))

-- | The snapshot: the counters, and the gauges read off the state.
diagnosticsOf ∷ SchedState v → Diagnostics
diagnosticsOf state =
  (ssCounts state)
    { diagQueued = Seq.length (sessionQueued (ssSession state))
    , diagActive = liveCount state
    , diagOverrunSites =
        [ Overrun (ssLabel state) kind entry count
        | ((kind, entry), count) ← Map.toAscList (ssSites state)
        ]
    , diagTick = ssTick state
    }

-- | Grants accepted and not yet finished.
outstandingGrants ∷ SchedState v → Int
outstandingGrants = Seq.length . ssGrants

-- | The earliest deadline an elapsed waiter or an elapsed cadence holds.
earliestDeadline ∷ SchedState v → Maybe Instant
earliestDeadline state = case (waiter, cadence) of
  (Just a, Just b) → Just (min a b)
  (a, Nothing) → a
  (Nothing, b) → b
  where
    waiter = fst . fst <$> Map.lookupMin (ssElapsed state)
    cadence = case [deadline | ElapsedCadence (Just deadline) ← Map.elems (ssCadenceElapsed state)] of
      [] → Nothing
      deadlines → Just (minimum deadlines)

-- | Whether anything holds an elapsed deadline: a waiter, or a cadence armed.
elapsedDemand ∷ SchedState v → Bool
elapsedDemand state = not (Map.null (ssElapsed state)) || any (isJust . ecDeadline) (Map.elems (ssCadenceElapsed state))

-- | Whether the identity names a task that is live: issued here, activated, and
-- not finished.
liveTarget ∷ TaskId → SchedState v → Bool
liveTarget identity state =
  maybe False (not . isTerminal . taskState) (Map.lookup identity (sessionTasks (ssSession state)))

-- | The continuations a stop closes, in identity order: those of live tasks that
-- are not inside a segment, and those still owed a close.
stoppableTasks ∷ SchedState v → [TaskId]
stoppableTasks state =
  Set.toAscList . Set.union (ssToClose state) . Set.fromList $
    [ identity
    | (identity, task) ← Map.toAscList (sessionTasks (ssSession state))
    , not (isTerminal (taskState task))
    , taskState task /= Running
    ]

-- | The continuations that still have to be closed because their task ended while
-- suspended, in identity order.
closeObligations ∷ SchedState v → [TaskId]
closeObligations = Set.toAscList . ssToClose

-- | Keep the failures of closes that were made, in order, until they are reported.
retainEvidence ∷ [(TaskId, SomeException)] → SchedState v → SchedState v
retainEvidence failures state = state {ssEvidence = foldl' (|>) (ssEvidence state) failures}

-- | Hand the failures kept to a report, oldest first. They stay in the state,
-- as delivered, until the next turn starts and so shows the report arrived.
deliverEvidence ∷ SchedState v → ([(TaskId, SomeException)], SchedState v)
deliverEvidence state =
  (toList (ssEvidence state), state {ssEvidence = Seq.empty, ssDelivered = ssEvidence state})

-- | A new turn has started, so the last report was received.
acknowledgeEvidence ∷ SchedState v → SchedState v
acknowledgeEvidence state = state {ssDelivered = Seq.empty}

-- | Take a close obligation off, once the close has been made.
closedObligation ∷ TaskId → SchedState v → SchedState v
closedObligation identity state = state {ssToClose = Set.delete identity (ssToClose state)}

-- Admission --------------------------------------------------------------------

-- | The longest an application's own entry point or name is kept, in characters.
-- The same bound the host library puts on an identity, restated here so the
-- scheduler names nothing of the VM.
maxLabelLength ∷ Int
maxLabelLength = 128

-- | A label as the scheduler keeps it: bounded, and copied out of whatever array
-- it was a slice of, so what is retained is a function of the bound and not of
-- what the application happened to pass.
compact ∷ Text → Text
compact = Text.copy . Text.take maxLabelLength

-- | Admit a task, or refuse. A refusal changes nothing but a counter.
--
-- An admission an active slot is free for is activated at once, so the identity
-- it answers is a live task; one that is not waits in the queue and is activated
-- in admission order as slots free.
admitIn ∷ Bool → TaskSpec v → SchedState v → (SchedState v, AdmitAnswer)
admitIn open spec state
  | not open = (rejected, AdmitRefused AdmitClosed)
  | otherwise = case requestAdmission request (ssSession state) of
      (_, Left rejection) → (rejected, AdmitRefused (refusal rejection))
      (session, Right identity) →
        let info =
              TaskInfo
                { infoKind = specKind spec
                , infoEntry = compact (specEntry spec)
                , infoName = compact <$> specName spec
                , infoWait = Nothing
                , infoHeld = False
                , infoEarned = Nothing
                , infoResume = Nothing
                , infoDue = Nothing
                }
            admitted =
              state
                { ssSession = session
                , ssInfo = Map.insert identity info (ssInfo state)
                }
         in (highWater (counting (\counts → counts {diagAdmitted = bump (diagAdmitted counts)}) (activateQueued admitted)), Admitted identity)
  where
    rejected = counting (\counts → counts {diagRejected = bump (diagRejected counts)}) state
    request =
      AdmissionRequest
        { admitBehavior = specBehavior spec
        , admitService = specClass spec
        , admitAuthority = Mutating
        , admitCursor = specCursor spec
        , admitReadiness = Nothing
        }
    refusal = \case
      CapReached name bound → AdmitFull name bound
      AdmissionIsClosed _ → AdmitClosed
      SessionAlreadyStopped → AdmitClosed
      -- Nothing else is a reason an admission is refused.
      _ → AdmitClosed

-- | Activate queued admissions, oldest first, while an active slot is free.
activateQueued ∷ SchedState v → SchedState v
activateQueued state = case activateNext (ssSession state) of
  (session, Right _) → activateQueued state {ssSession = session}
  (_, Left _) → highWater state

highWater ∷ SchedState v → SchedState v
highWater state =
  counting
    ( \counts →
        counts
          { diagQueueHighWater = max (diagQueueHighWater counts) (Seq.length (sessionQueued (ssSession state)))
          , diagActiveHighWater = max (diagActiveHighWater counts) (liveCount state)
          }
    )
    state

-- Choosing and running ---------------------------------------------------------

-- | What choosing the next segment came to.
data Selection
  = -- | Run this task: it is ready and belongs to the class being served.
    Selected !TaskId
  | -- | The pass over the classes is complete. The next one starts afresh.
    PassEnded
  | -- | Nothing is ready in any class.
    NothingReady

-- | Choose the next segment: the class the pass has reached, if it has a ready
-- task and quantum left, else the next class, and within the class the task the
-- policy names.
--
-- The policy is asked only for a ready task of the class being served, so
-- whatever it chooses it cannot make another class wait: when a class has used
-- its quantum, or has nothing ready, the pass moves on. A choice that is not a
-- ready task of that class is refused and counted, and the oldest ready task of
-- the class runs instead, so a policy that cannot choose cannot stall the owner.
selectNext ∷ Policy → SchedState v → (SchedState v, Selection)
selectNext policy state = case NonEmpty.nonEmpty (readyCandidates state) of
  Nothing → (state {ssPass = startOfPass}, NothingReady)
  Just ready → serveFrom ready (ssPass state)
  where
    quanta = limitQuanta (limitsOf (sessionLimits (ssSession state)))
    quantum serviceClass = quantumSegments (quantumFor serviceClass quanta)

    serveFrom ready (Pass serviceClass served) =
      case servable view of
        oldest : _
          | served < quantum serviceClass →
              let wanted = policyChoose policy view
                  allowed = any ((== wanted) . candidateTask) (servable view)
                  chosen = if allowed then wanted else candidateTask oldest
                  advanced = state {ssPass = Pass serviceClass (served + 1)}
                  noted
                    | allowed = advanced
                    | otherwise = counting (\counts → counts {diagRefusedChoices = bump (diagRefusedChoices counts)}) advanced
               in (noted, Selected chosen)
        _ → case nextClass serviceClass of
          Nothing → (state {ssPass = startOfPass}, PassEnded)
          Just following → serveFrom ready (Pass following 0)
      where
        view = PolicyView serviceClass ready

    nextClass serviceClass
      | serviceClass == maxBound = Nothing
      | otherwise = Just (succ serviceClass)

-- | Begin the chosen task's segment, and say what the host is to run.
beginSegment ∷ TaskId → SchedState v → Maybe (SchedState v, TaskRun v)
beginSegment identity state = do
  task ← Map.lookup identity (sessionTasks (ssSession state))
  info ← Map.lookup identity (ssInfo state)
  case startSegment identity (ssSession state) of
    (session, Right ()) →
      Just
        ( counting
            ( \counts →
                counts {diagSegmentsByClass = [(c, if c == taskService task then bump n else n) | (c, n) ← diagSegmentsByClass counts]}
            )
            state
              { ssSession = session
              , ssInfo = Map.insert identity info {infoResume = Nothing} (ssInfo state)
              }
        , TaskRun
            { runTask = identity
            , runBehavior = taskBehavior task
            , runEntry = infoEntry info
            , runName = infoName info
            , runClass = taskService task
            , runKind = infoKind info
            , runCursor = taskCursor task
            , runResume = infoResume info
            , runSegmentNumber = taskSegments task
            }
        )
    (_, Left _) → Nothing

-- | A task failure the turn report names.
data Event
  = Failed !TaskId !TaskFailure
  | WaitRefused !TaskId !WaitRefusal

-- | Apply what a segment reported to the running task.
--
-- The reading is the owner's clock at the moment the segment returned. It is
-- present whenever the report is an elapsed wait, which is the one report that
-- needs it; an elapsed wait without one cannot be placed and is refused.
applyReport ∷ TaskId → Maybe Instant → SegmentReport v → SchedState v → (SchedState v, [Event])
applyReport identity reading report state = case report of
  ReportCompleted value → completed value
  ReportYielded value → applied (SegmentYielded value) $ counting (\counts → counts {diagYielded = bump (diagYielded counts)})
  ReportWaitTicks value ticks
    | ticks == 0 → refuse WaitTicksNotPositive
    | ssTick state > maxBound - ticks → refuse WaitTicksOverflow
    | otherwise →
        placeWait value (LogicalWait sequenceNumber (ssTick state + ticks) zeroDuration) $
          \placed → placed {ssLogical = Map.insert sequenceNumber identity (ssLogical placed)}
  ReportWaitElapsed value duration
    | duration == zeroDuration → refuse WaitDurationNotPositive
    | otherwise → case reading of
        Nothing → refuse WaitDeadlineOverflow
        Just now → case addDuration now duration of
          Left _ → refuse WaitDeadlineOverflow
          Right deadline →
            placeWait value (ElapsedWait sequenceNumber now deadline) $
              \placed → placed {ssElapsed = Map.insert (deadline, sequenceNumber) identity (ssElapsed placed)}
  ReportFailed failure → (failTaskIn False identity failure state, [Failed identity failure])
  where
    sequenceNumber = ssNextWait state

    completed value = case applyOutcome identity (SegmentCompleted value) (ssSession state) of
      (session, Right ()) →
        ( counting
            (\counts → counts {diagCompleted = bump (diagCompleted counts)})
            (forget identity state {ssSession = session})
        , []
        )
      (_, Left _) → (state, [])

    applied outcome note = case applyOutcome identity outcome (ssSession state) of
      (session, Right ()) → (note state {ssSession = session}, [])
      (_, Left _) → (state, [])

    placeWait value record register =
      case applyOutcome identity (SegmentWaiting value (WaitingUntil (Readiness sequenceNumber))) (ssSession state) of
        (session, Right ()) →
          ( counting (\counts → counts {diagWaiting = bump (diagWaiting counts)}) $
              releaseDue identity $
                register
                  state
                    { ssSession = session
                    , ssNextWait = sequenceNumber + 1
                    , ssInfo = Map.adjust (\info → info {infoWait = Just record, infoHeld = False, infoEarned = Nothing}) identity (ssInfo state)
                    }
          , []
          )
        (_, Left _) → (state, [])

    refuse why =
      let failure = TaskFailure (failureReason ValidationFault ("wait refused: " <> refusalText why)) RecoverySafe
       in ( counting (\counts → counts {diagRefusedWaits = bump (diagRefusedWaits counts)}) (failTaskIn True identity failure state)
          , [WaitRefused identity why, Failed identity failure]
          )

refusalText ∷ WaitRefusal → Text
refusalText = \case
  WaitTicksNotPositive → "a wait for no ticks"
  WaitTicksOverflow → "the tick it would end at is not representable"
  WaitDurationNotPositive → "an elapsed wait of no time"
  WaitDeadlineOverflow → "the deadline is not representable"

-- | Fail a live task, ending it with the failure as its result. A task failed
-- while its continuation was suspended (a wait that was refused, a wait that
-- could not be applied) still owes that continuation a close; one that failed in
-- its own segment does not, since its continuation is dead.
failTaskIn ∷ Bool → TaskId → TaskFailure → SchedState v → SchedState v
failTaskIn suspended identity failure state = case transition identity (failTask key failure) (ssSession state) of
  (session, Right _) →
    counting
      (\counts → counts {diagFailed = bump (diagFailed counts)})
      ( owed
          (forget identity state {ssSession = retire identity (ResultFailed failure) session})
      )
  (_, Left _) → state
  where
    key = sessionKey (ssSession state)
    owed ended
      | suspended = ended {ssToClose = Set.insert identity (ssToClose ended)}
      | otherwise = ended

-- | Take a task that has just ended out of every structure that tracks a live
-- one. The order matters: what a task held is read from its record, which goes
-- last.
forget ∷ TaskId → SchedState v → SchedState v
forget identity state =
  state'
    {ssInfo = Map.delete identity (ssInfo state')}
  where
    state' = removeWaiter identity (releaseDue identity state)

-- | Take a task out of the waiter tables.
removeWaiter ∷ TaskId → SchedState v → SchedState v
removeWaiter identity state = case Map.lookup identity (ssInfo state) >>= infoWait of
  Just LogicalWait {waitSequence = sequenceNumber} →
    state {ssLogical = Map.delete sequenceNumber (ssLogical state)}
  Just ElapsedWait {waitSequence = sequenceNumber, waitDeadline = deadline} →
    state {ssElapsed = Map.delete (deadline, sequenceNumber) (ssElapsed state)}
  Nothing → state

-- | The site an overrun of this task would be attributed to: its kind and entry
-- point. Read before a report is applied, since a task that ends takes its record
-- with it.
siteOf ∷ TaskId → SchedState v → Maybe (TaskKind, Text)
siteOf identity state = (\info → (infoKind info, infoEntry info)) <$> Map.lookup identity (ssInfo state)

-- | Count a segment that ran past the budget against its site.
recordOverrunAt ∷ Maybe (TaskKind, Text) → SchedState v → SchedState v
recordOverrunAt Nothing state = counted state
recordOverrunAt (Just site) state
  | Map.member site (ssSites state) || Map.size (ssSites state) < maxOverrunSites =
      (counted state) {ssSites = Map.insertWith (\_ count → bump count) site 1 (ssSites state)}
  | otherwise = counting (\counts → counts {diagOverrunsUnattributed = bump (diagOverrunsUnattributed counts)}) (counted state)

counted ∷ SchedState v → SchedState v
counted = counting (\counts → counts {diagOverruns = bump (diagOverruns counts)})

-- | Start the pass afresh if nothing at all is ready, as choosing the next
-- segment does. A turn that ends before it chooses, at a budget or a stop
-- request, calls this so that where it was cut cannot change what the pass does
-- next.
resetPassIfIdle ∷ SchedState v → SchedState v
resetPassIfIdle state
  | null (readyCandidates state) = state {ssPass = startOfPass}
  | otherwise = state

-- Time -------------------------------------------------------------------------

-- | The position of the first grant that has not finished.
firstOpen ∷ SchedState v → Word64
firstOpen state = ssNextGrant state - fromIntegral (Seq.length (ssGrants state))

-- | Accept a grant of a logical step.
grantIn ∷ Bool → Int → Duration → SchedState v → (SchedState v, GrantAnswer)
grantIn open bound duration state
  | not open = (refused, GrantClosed)
  | duration == zeroDuration = (refused, GrantNotPositive)
  | Seq.length (ssGrants state) >= bound = (refused, GrantFull)
  | otherwise =
      ( counting
          (\counts → counts {diagGrantsAccepted = bump (diagGrantsAccepted counts)})
          state
            { ssGrants = ssGrants state |> Grant duration False 0
            , ssNextGrant = ssNextGrant state + 1
            }
      , GrantAccepted (GrantId (ssNextGrant state))
      )
  where
    refused = counting (\counts → counts {diagGrantsRefused = bump (diagGrantsRefused counts)}) state

-- | Give back one task's claim on the grant that woke it, as it stops being
-- ready or running.
releaseDue ∷ TaskId → SchedState v → SchedState v
releaseDue identity state = case Map.lookup identity (ssInfo state) >>= infoDue of
  Nothing → state
  Just (GrantId number) →
    state
      { ssInfo = Map.adjust (\info → info {infoDue = Nothing}) identity (ssInfo state)
      , ssGrants = Seq.adjust' (\grant → grant {grantDue = grantDue grant - 1}) (fromIntegral (number - firstOpen state)) (ssGrants state)
      }

-- | Apply every grant that can be applied, in the order they were accepted, and
-- finish those whose work is done.
--
-- A grant is applied only once every earlier one has finished, so the logical
-- timeline is strictly sequential and what runs depends on the grants and not on
-- when they arrived. Applying one advances the tick by one, adds its duration to
-- every logical waiter, and wakes the waiters it reaches, in the order their
-- waits began. A grant finishes when everything it woke has stopped being ready
-- or running, and then its slot is free. Applying a grant is one step: a waiter
-- whose accumulated duration cannot be represented fails with a typed failure
-- and the rest of the step stands, so nothing wraps and nothing is left half
-- applied.
settleGrants ∷ SchedState v → (SchedState v, [Event])
settleGrants state = case Seq.viewl (ssGrants state) of
  EmptyL → (state, [])
  grant :< rest
    | not (grantApplied grant) →
        let (applied, events) = applyHead grant state
            (settled, more) = settleGrants applied
         in (settled, events <> more)
    | grantDue grant == 0 → settleGrants state {ssGrants = rest}
    | otherwise → (state, [])

applyHead ∷ Grant → SchedState v → (SchedState v, [Event])
applyHead grant state = (advanceCadences grant identityOfGrant tick woken, wakeEvents)
  where
    (woken, wakeEvents) = foldl' advance (opened, []) (Map.toAscList (ssLogical state))
    tick = ssTick state + 1
    identityOfGrant = GrantId (firstOpen state)
    opened =
      state
        { ssTick = tick
        , ssGrants = Seq.update 0 grant {grantApplied = True} (ssGrants state)
        }
    advance (current, events) (_, identity) = case Map.lookup identity (ssInfo current) of
      Just info@TaskInfo {infoWait = Just wait@LogicalWait {}} → case addDurations (waitGranted wait) (grantDuration grant) of
        Left _ →
          let failure = TaskFailure (failureReason ValidationFault "logical wait: the granted duration is not representable") RecoverySafe
           in (failTaskIn True identity failure current, events <> [Failed identity failure])
        Right granted
          | tick >= waitTarget wait →
              (wake identity (ResumedLogical tick granted) (Just identityOfGrant) current, events)
          | otherwise →
              ( current {ssInfo = Map.insert identity info {infoWait = Just wait {waitGranted = granted}} (ssInfo current)}
              , events
              )
      _ → (current, events)

-- | Wake the elapsed waiters whose deadlines the reading has reached, in
-- deadline order and, for equal deadlines, in the order their waits began, and
-- reach the elapsed cadence points the reading has passed.
wakeDueElapsed ∷ Instant → SchedState v → SchedState v
wakeDueElapsed now state = reachElapsedCadences now (foldl' wakeOne state due)
  where
    due = takeWhile (\((deadline, _), _) → deadlineReached now deadline) (Map.toAscList (ssElapsed state))
    wakeOne current (_, identity) = case Map.lookup identity (ssInfo current) >>= infoWait of
      Just ElapsedWait {waitStart = started} →
        wake identity (ResumedElapsed (elapsedBetween started now)) Nothing current
      _ → current

-- | A satisfied wait. The task rejoins the tail of the ready set with what the
-- wait earned, unless it was paused while it waited, in which case the wake is
-- kept for when it resumes and nothing runs.
wake ∷ TaskId → Resume → Maybe GrantId → SchedState v → SchedState v
wake identity earned cause state = case Map.lookup identity (ssInfo state) of
  Nothing → state
  Just info
    | infoHeld info →
        cleared
          { ssInfo = Map.insert identity info {infoWait = Nothing, infoEarned = Just earned} (ssInfo cleared)
          }
    | otherwise → case wakeTaskIn identity (ssSession cleared) of
        (session, Right ()) →
          dueTo
            cleared
              { ssSession = session
              , ssInfo = Map.insert identity info {infoWait = Nothing, infoResume = Just earned, infoDue = cause} (ssInfo cleared)
              }
        (_, Left _) → cleared
  where
    cleared = removeWaiter identity state
    dueTo woken = case cause of
      Nothing → woken
      Just (GrantId number) →
        woken {ssGrants = Seq.adjust' (\grant → grant {grantDue = grantDue grant + 1}) (fromIntegral (number - firstOpen woken)) (ssGrants woken)}

-- Cadences ---------------------------------------------------------------------

-- | A grant has been applied: add its duration to every logical cadence's accrual,
-- and reach the points it is due at. A reached point holds the grant, as a task it
-- woke would, so the grant is not finished until the owner has served the point and
-- released the hold. An accrual that cannot be represented fails the cadence, on the
-- grant, and nothing wraps.
advanceCadences ∷ Grant → GrantId → Word64 → SchedState v → SchedState v
advanceCadences grant held tick state = foldl' one state (Map.toAscList (ssCadenceLogical state))
  where
    one current (key, cadence)
      | not (lcAccruing cadence) = current
      | otherwise = accruing current key cadence
    accruing current key cadence = case addDurations (lcAccrued cadence) (grantDuration grant) of
      Left _ → reach current key cadence {lcTarget = Nothing} (FiredFault CadenceAccrualOverflow)
      Right accrued → case lcTarget cadence of
        Just target | tick >= target → reach current key cadence {lcAccrued = accrued, lcTarget = Nothing} (FiredLogical tick)
        _ → current {ssCadenceLogical = Map.insert key cadence {lcAccrued = accrued} (ssCadenceLogical current)}
    reach current key cadence firing =
      current
        { ssCadenceLogical = Map.insert key cadence {lcHold = Just held} (ssCadenceLogical current)
        , ssGrants = Seq.adjust' (\open -> open {grantDue = grantDue open + 1}) 0 (ssGrants current)
        , ssFirings = ssFirings current |> (key, firing)
        }

-- | The elapsed cadence points a reading has reached, in deadline order and, for equal
-- deadlines, in the order of their keys. A reached cadence has no deadline until its
-- owner arms it again.
reachElapsedCadences ∷ Instant → SchedState v → SchedState v
reachElapsedCadences now state = foldl' reach state due
  where
    due = sortOn (\(key, deadline) → (deadline, key)) [(key, deadline) | (key, ElapsedCadence (Just deadline)) ← Map.toList (ssCadenceElapsed state), deadlineReached now deadline]
    reach current (key, deadline) =
      current
        { ssCadenceElapsed = Map.insert key (ElapsedCadence Nothing) (ssCadenceElapsed current)
        , ssFirings = ssFirings current |> (key, FiredElapsed deadline now)
        }

-- | Register a logical cadence due at a tick, with nothing accrued. Refused, answering
-- 'Nothing', for a key already registered.
cadenceStartLogical ∷ CadenceKey → Word64 → SchedState v → Maybe (SchedState v)
cadenceStartLogical key target state
  | registered key state = Nothing
  | otherwise = Just state {ssCadenceLogical = Map.insert key (LogicalCadence (Just target) zeroDuration True Nothing) (ssCadenceLogical state)}

-- | Register an elapsed cadence due at a deadline. Refused for a key already registered.
cadenceStartElapsed ∷ CadenceKey → Instant → SchedState v → Maybe (SchedState v)
cadenceStartElapsed key deadline state
  | registered key state = Nothing
  | otherwise = Just state {ssCadenceElapsed = Map.insert key (ElapsedCadence (Just deadline)) (ssCadenceElapsed state)}

registered ∷ CadenceKey → SchedState v → Bool
registered key state = Map.member key (ssCadenceLogical state) || Map.member key (ssCadenceElapsed state)

-- | Arm a registered logical cadence for a tick, keeping what it has accrued, and
-- accruing again from the grants applied after this.
cadenceArmLogical ∷ CadenceKey → Word64 → SchedState v → SchedState v
cadenceArmLogical key target state = state {ssCadenceLogical = Map.adjust (\cadence → cadence {lcTarget = Just target, lcAccruing = True}) key (ssCadenceLogical state)}

-- | Arm a registered elapsed cadence for a deadline.
cadenceArmElapsed ∷ CadenceKey → Instant → SchedState v → SchedState v
cadenceArmElapsed key deadline state = state {ssCadenceElapsed = Map.adjust (const (ElapsedCadence (Just deadline))) key (ssCadenceElapsed state)}

-- | Disarm a cadence: it is due at nothing, and keeps what it has accrued. A logical
-- one accrues nothing from the grants applied until it is armed again. An elapsed point
-- reached and not yet taken is dropped, since the deadline it was reached at is no
-- longer the cadence's: a pause and a resume that follow it before it is served must not
-- find it still there. A logical point reached holds a grant, which its owner releases
-- when it serves the point, so it stays to be served.
cadenceDisarm ∷ CadenceKey → SchedState v → SchedState v
cadenceDisarm key state =
  state
    { ssCadenceLogical = Map.adjust (\cadence → cadence {lcTarget = Nothing, lcAccruing = False}) key (ssCadenceLogical state)
    , ssCadenceElapsed = Map.adjust (const (ElapsedCadence Nothing)) key (ssCadenceElapsed state)
    , ssFirings = Seq.filter (not . staleElapsed) (ssFirings state)
    }
  where
    staleElapsed (firedKey, firing) = firedKey == key && case firing of
      FiredElapsed _ _ → True
      _ → False

-- | Take a cadence away: its demand is cancelled, a point it reached and nobody took
-- is dropped, and a grant it held is released.
cadenceStop ∷ CadenceKey → SchedState v → SchedState v
cadenceStop key state =
  released
    { ssCadenceLogical = Map.delete key (ssCadenceLogical released)
    , ssCadenceElapsed = Map.delete key (ssCadenceElapsed released)
    , ssFirings = Seq.filter ((/= key) . fst) (ssFirings released)
    }
  where
    released = cadenceRelease key state

-- | The points reached since they were last taken, in the order they were reached.
cadenceTake ∷ SchedState v → ([(CadenceKey, CadenceFiring)], SchedState v)
cadenceTake state = (toList (ssFirings state), state {ssFirings = Seq.empty})

-- | Give back the grant a cadence holds, so that it can finish once its other work has.
cadenceRelease ∷ CadenceKey → SchedState v → SchedState v
cadenceRelease key state = case Map.lookup key (ssCadenceLogical state) of
  Just cadence@LogicalCadence {lcHold = Just (GrantId number)} →
    state
      { ssCadenceLogical = Map.insert key cadence {lcHold = Nothing} (ssCadenceLogical state)
      , ssGrants = Seq.adjust' (\open → open {grantDue = max 0 (grantDue open - 1)}) (fromIntegral (number - firstOpen state)) (ssGrants state)
      }
  _ → state

-- | What a logical cadence has accrued.
cadenceAccruedOf ∷ CadenceKey → SchedState v → Maybe Duration
cadenceAccruedOf key state = lcAccrued <$> Map.lookup key (ssCadenceLogical state)

-- | Begin a logical cadence's accrual again from nothing.
cadenceResetAccrued ∷ CadenceKey → SchedState v → SchedState v
cadenceResetAccrued key state = state {ssCadenceLogical = Map.adjust (\cadence → cadence {lcAccrued = zeroDuration}) key (ssCadenceLogical state)}

-- | Whether a logical cadence holds a grant.
cadenceHeldBy ∷ CadenceKey → SchedState v → Bool
cadenceHeldBy key state = maybe False (isJust . lcHold) (Map.lookup key (ssCadenceLogical state))

-- Control -----------------------------------------------------------------------

-- | Pause a task at a safe boundary.
pauseIn ∷ TaskId → SchedState v → (SchedState v, ControlResult)
pauseIn identity state = case Map.lookup identity (sessionTasks (ssSession state)) of
  Just task → case taskState task of
    Ready → case pauseTaskIn identity (ssSession state) of
      (session, Right ()) → (releaseDue identity state {ssSession = session}, ControlApplied)
      (_, Left _) → (state, ControlNoLongerApplicable)
    Paused → (state, ControlAlreadyInState)
    Waiting _
      | held → (state, ControlAlreadyInState)
      | otherwise → (state {ssInfo = Map.adjust (\info → info {infoHeld = True}) identity (ssInfo state)}, ControlApplied)
    _ → (state, ControlNoLongerApplicable)
  Nothing → (state, ControlNoLongerApplicable)
  where
    held = maybe False infoHeld (Map.lookup identity (ssInfo state))

-- | Resume a task at a safe boundary.
--
-- A paused ready task rejoins the tail of its class with a fresh ordinal. A task
-- paused while it waited does not skip the wait: if the wait was satisfied while
-- it was held it is woken now, to the tail, with what the wait earned, and if
-- not it goes on waiting.
resumeIn ∷ TaskId → SchedState v → (SchedState v, ControlResult)
resumeIn identity state = case Map.lookup identity (sessionTasks (ssSession state)) of
  Just task → case taskState task of
    Paused → case resumeTaskIn identity (ssSession state) of
      (session, Right ()) → (state {ssSession = session}, ControlApplied)
      (_, Left _) → (state, ControlNoLongerApplicable)
    Waiting _
      | Just info ← Map.lookup identity (ssInfo state), infoHeld info → case infoEarned info of
          Nothing → (state {ssInfo = Map.insert identity info {infoHeld = False} (ssInfo state)}, ControlApplied)
          Just earned → case wakeTaskIn identity (ssSession state) of
            (session, Right ()) →
              ( state
                  { ssSession = session
                  , ssInfo = Map.insert identity info {infoHeld = False, infoEarned = Nothing, infoResume = Just earned} (ssInfo state)
                  }
              , ControlApplied
              )
            (_, Left _) → (state, ControlNoLongerApplicable)
      | otherwise → (state, ControlAlreadyInState)
    Ready → (state, ControlAlreadyInState)
    _ → (state, ControlNoLongerApplicable)
  Nothing → (state, ControlNoLongerApplicable)

-- | Cancel a live task, once its continuation has been closed.
cancelIn ∷ TaskId → SchedState v → (SchedState v, ControlResult)
cancelIn identity state = case cancelTaskIn identity (ssSession state) of
  (session, Right ()) →
    ( counting
        (\counts → counts {diagCancelled = bump (diagCancelled counts)})
        (forget identity state {ssSession = session})
    , ControlApplied
    )
  (_, Left _) → (state, ControlNoLongerApplicable)
