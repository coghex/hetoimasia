{-# LANGUAGE OverloadedStrings #-}

-- | The session's state machine: every gate, phase, admission and failure fact the coordinator
-- publishes, as one pure value and one pure transition function.
--
-- = Why pure
--
-- The coordinator is concurrent: owners' threads (a hook entering, an instance failing), the
-- application's thread (admission, the driver, a stop) and a signal's thread all change what the
-- session says. Every change is one 'Event' applied to one 'SessionState' in one STM transaction by
-- "Hetoimasia.LuaEngine.Session.Run", so each invariant below is a property of a transaction and not
-- of an interleaving, and every transition can be tested without a VM.
--
-- = Who owns the state
--
-- One 'SessionState' lives in one variable, made with the session and living as long as it. The
-- writers are the owners' threads (through the hook that gates an @init@ and the escalation that
-- reports an instance's failure), the application's thread (admission, the driver, the stop
-- endpoint) and any thread that asks for a stop; the readers are those and whoever polls the status.
-- Nothing is reset: a session is made once, runs once and ends.
--
-- = The gates
--
-- * The /dispatch gate/ stands between validation and the roots' @init@s. It is closed until the first
--   instance admitted, of every selected role, has been constructed and validated (the host holds each
--   one there and tells the session) and admission is complete; it then opens, once, and the held
--   instances are released, so both @init@s run without either waiting for the other to finish. It is
--   aborted, for good, by a stop or a failure, and an aborted gate never opens: a held instance is never
--   released and ends with its owner, its @init@ never having run.
-- * The /start gate/ stands between the @init@s and the first logical tick. It opens, once, in the
--   transaction that records the last selected @init@'s success, if no role has failed and no stop has
--   been asked; a one-role session needs only its own. It is shut, for good, by a stop or a failure
--   that arrives first. A late success cannot reopen a shut gate.
--
-- = The one commit, and the effects it owes
--
-- Every change to the session is one 'Event' applied by 'step' in one STM transaction, and 'step' is the only
-- function that changes a 'SessionState'. A transition changes /everything/ its event means in that one step:
-- the failure latch, the phase, the gates, the marker that an instance's failure was already told ('stEarly'),
-- the evidence it accounts and the identities that evidence already carried ('stEvidence'), the historical facts the
-- event proves (an @init@ that succeeded, how an instance's shutdown ended) and the facts a role's retirement
-- needs (its owner accounted, its coordinator drained, its local releases attempted). It also appends, in the same
-- step, the effects the event owes: the stop of an owner whose admission it closed ('stStops') and the diagnostics it
-- means ('stDiags'). Nothing the event means is left to a step after it, so there is no window in which half of it
-- has happened, and a claim never precedes its payload.
--
-- The effects owed are kept in the state, not in a thread: a stop is owed until its handoff has succeeded or the
-- owner's completion has made it unnecessary, coalesced by role; a diagnostic has a stable identity and is
-- pending, in flight or interrupted until it has finished. Both queues are bounded by the fixed set of roles and
-- transitions. A recovery or a cancellation path only commits, and never performs either kind of effect.
--
-- = The phases
--
-- A role is @starting@ until its own @init@ has succeeded (every admitted instance of it), then
-- @ready@ (gameplay, waiting for the start gate) or @running@ (presentation at once, gameplay when the
-- start gate opens); @stopping@ from the moment a stop or a failure closes its admission; and
-- @retired@ only when retirement is proven: no admission intent outstanding, its owner's completion and
-- every instance settlement accounted, its coordinator drained of every read it started, and every local release
-- it registered attempted without failing ('retirable'). A stopped worker, a stop request or an exited scope
-- is none of those. A failed role never returns to @ready@ or @running@. The first failure of a role stays.
module Hetoimasia.LuaEngine.Session.State
  ( -- * Keys
    InstanceKey (..)
  , BuildStep (..)

    -- * Vocabulary
  , Phase (..)
  , Admit (..)
  , StopKind (..)
  , DispatchGate (..)
  , StartGate (..)

    -- * Evidence and history
  , EvidenceKey (..)
  , Evidence (..)
  , evidenceOf
  , EndKind (..)
  , ShutdownFact (..)
  , InstanceFact (..)

    -- * The state
  , RoleState (..)
  , SessionState (..)
  , newSessionState
  , roleAdmit
  , dispatchDecision
  , allRolesRetired
  , rolesFinished
  , rolesInitialized
  , retirable
  , DiagState (..)
  , Diag (..)
  , pendingDiagnostics
  , quiet

    -- * Transitions
  , Event (..)
  , Answer (..)
  , Say (..)
  , SayLevel (..)
  , owedStops
  , eventName
  , step

    -- * What it publishes
  , RoleStatus (..)
  , SessionStatus (..)
  , statusOf
  , Verdict (..)
  , SessionOutcome (..)
  , outcomeOf
  , History (..)
  , historyOf
  ) where

import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import qualified Data.Sequence as Seq
import Data.Sequence (Seq)
import qualified Data.Set as Set
import Data.Set (Set)
import Data.Foldable (toList)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Resource (CleanupFailureId)
import Hetoimasia.Foundation.Time (Instant)
import Hetoimasia.LuaEngine.Manifest (Role (..))
import Hetoimasia.LuaEngine.Session.Harness (BuildStep (..), InstanceKey (..))
import Hetoimasia.LuaEngine.Session.Failure

-- Vocabulary ----------------------------------------------------------------------------------------

-- | Where a role is, as the status record says it.
data Phase = Starting | Ready | Running | Stopping | Retired
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Whether a role takes new work.
data Admit = AdmitOpen | AdmitStopping | AdmitClosed
  deriving (Eq, Ord, Show)

-- | The two orderly ways a session is asked to end. A failure outranks both, and an interruption
-- outranks a normal quit, whatever order they were asked in.
data StopKind
  = -- | An explicit quit: exit status 0 if nothing failed.
    StopQuit
  | -- | An interruption (a first signal): exit status 130 if nothing failed.
    StopInterrupt
  deriving (Eq, Show)

-- | Whether the roots' @init@s may begin.
data DispatchGate = DispatchClosed | DispatchOpen | DispatchAborted
  deriving (Eq, Show)

-- | Whether logical ticks may begin.
data StartGate = StartClosed | StartOpen | StartShut
  deriving (Eq, Show)

-- Evidence and history --------------------------------------------------------------------------------

-- | The identity a piece of evidence already has, so that the same cleanup failure seen on a worker's completion,
-- on a scope's context and on an exception that carried it is one entry. A distinct failure that renders the same
-- way is a distinct identity; no exception is ever compared by its text.
newtype EvidenceKey = EvidenceCleanup CleanupFailureId
  deriving (Eq, Ord, Show)

-- | One failure to account: an engine entry and, when it already had an identity, that identity.
data Evidence = Evidence
  { evKey ∷ !(Maybe EvidenceKey)
  , evEntry ∷ !EngineEntry
  }
  deriving (Eq, Show)

-- | Evidence with no identity of its own, so that it always counts.
evidenceOf ∷ EngineEntry → Evidence
evidenceOf = Evidence Nothing

-- | How an instance ended.
data EndKind = EndedCompleted | EndedStopped | EndedFailed | EndedDiscarded
  deriving (Eq, Show)

-- | What became of an instance's @shutdown@ hook.
data ShutdownFact
  = FactShutdownRan
  | FactShutdownRaised
  | FactShutdownAbsent
  | -- | The @init@ never succeeded, so no hook ran.
    FactShutdownSkippedNoInit
  | -- | The owner ended by a failure or a cancellation: Lua was not safe to enter.
    FactShutdownSkippedUnsafe
  deriving (Eq, Show)

-- | What the host's settlement of an instance proved, kept once.
data InstanceFact = InstanceFact
  { ifInitialized ∷ !Bool
  -- ^ Its @init@ succeeded, whatever the instance went on to do.
  , ifShutdown ∷ !ShutdownFact
  , ifEnded ∷ !EndKind
  }
  deriving (Eq, Show)

-- The state -----------------------------------------------------------------------------------------

-- | One role's facts.
data RoleState = RoleState
  { rsInstances ∷ !Int
  -- ^ How many instances the composition admits for the role.
  , rsInited ∷ !(Set Int)
  -- ^ The slots whose @init@ has succeeded. Historical: it only grows.
  , rsFacts ∷ !(Map Int InstanceFact)
  -- ^ How each instance's settlement ended, kept once and never rewritten.
  , rsPhase ∷ !Phase
  , rsAdmit ∷ !Admit
  , rsFailure ∷ !(Maybe RoleFailure)
  -- ^ The first failure, latched. Never replaced.
  , rsIntents ∷ !Int
  -- ^ Admissions begun and neither tracked nor abandoned yet.
  , rsAcquired ∷ !(Set BuildStep)
  -- ^ The components the session registered for this role, in the same transaction as the acquisition.
  , rsOwnerEnded ∷ !Bool
  -- ^ The owner's raw completion and the settlements of its instances are accounted.
  , rsDrained ∷ !Bool
  -- ^ The role's coordinator has given back every slot and byte its reads held.
  , rsReleased ∷ !Bool
  -- ^ The role's registered local releases have all been attempted.
  , rsReleaseFailed ∷ !Bool
  -- ^ One of them threw: retirement is not proven.
  , rsStopHanded ∷ !Bool
  -- ^ The owner was asked to stop: the handoff succeeded. Monotone; a stop is not owed again.
  }
  deriving (Eq, Show)

-- | Where a diagnostic is.
data DiagState = DiagPending | DiagInFlight | DiagInterrupted
  deriving (Eq, Show)

-- | A diagnostic with a stable identity and its state, kept until it has finished.
data Diag = Diag
  { dgId ∷ !Int
  , dgSay ∷ !Say
  , dgState ∷ !DiagState
  }
  deriving (Eq, Show)

-- | The whole session's facts.
data SessionState = SessionState
  { stRoles ∷ !(Map Role RoleState)
  , stDispatch ∷ !DispatchGate
  , stExpected ∷ !(Set InstanceKey)
  -- ^ The instances whose validation the dispatch gate waits for: every instance of every role.
  , stValidated ∷ !(Set InstanceKey)
  , stAdmitted ∷ !Bool
  -- ^ Admission is complete: every instance the composition asked for has been accepted.
  , stStart ∷ !StartGate
  , stOrigin ∷ !(Maybe Instant)
  -- ^ The clock's reading taken just before the transition that opened the start gate: the pacing origin.
  , stStops ∷ !(Seq Role)
  -- ^ The owners that are owed a stop, coalesced, in the order their admissions closed. A stop stays owed until its
  -- handoff succeeded or the owner's completion made it unnecessary.
  , stStopDefects ∷ !(Set Role)
  -- ^ The owners whose stop primitive raised, once each.
  , stDiags ∷ !(Seq Diag)
  -- ^ The diagnostics meant and not finished, in the order they were meant.
  , stNextDiag ∷ !Int
  , stEvidence ∷ !(Set EvidenceKey)
  -- ^ The identities of the evidence already accounted.
  , stEarly ∷ !(Set Text)
  -- ^ The instances whose failure the owner told the session of as the ending began, so that the settlement tells
  -- it nothing new.
  , stStopping ∷ !Bool
  -- ^ Whole-session stopping.
  , stQuit ∷ !Bool
  , stInterrupt ∷ !Bool
  , stFailureOrder ∷ ![Role]
  -- ^ The roles that failed, in the order their failures latched. The head is the primary.
  , stEngine ∷ !EngineReport
  , stTerminal ∷ !(Maybe RoleFailure)
  -- ^ The terminal failure the unavailable-state guard latches.
  , stLimits ∷ !FailureLimits
  }
  deriving (Eq, Show)

-- | A session about to begin: these roles, with this many instances each, all starting, taking
-- work, with both gates closed.
newSessionState ∷ FailureLimits → [(Role, Int)] → SessionState
newSessionState limits roles =
  SessionState
    { stRoles = Map.fromList [(role, RoleState n Set.empty Map.empty Starting AdmitOpen Nothing 0 Set.empty False False False False False) | (role, n) ← roles]
    , stDispatch = DispatchClosed
    , stExpected = Set.fromList [InstanceKey role slot | (role, n) ← roles, slot ← [0 .. n - 1]]
    , stValidated = Set.empty
    , stAdmitted = False
    , stStart = StartClosed
    , stOrigin = Nothing
    , stStops = Seq.empty
    , stStopDefects = Set.empty
    , stDiags = Seq.empty
    , stNextDiag = 0
    , stEvidence = Set.empty
    , stEarly = Set.empty
    , stStopping = False
    , stQuit = False
    , stInterrupt = False
    , stFailureOrder = []
    , stEngine = emptyReport
    , stTerminal = Nothing
    , stLimits = limits
    }

-- | What a role's admission is: a role the session does not have takes nothing.
roleAdmit ∷ Role → SessionState → Admit
roleAdmit role state = maybe AdmitClosed rsAdmit (Map.lookup role (stRoles state))

-- | How the dispatch gate stands: 'Nothing' while it is closed, 'Just True' when it has opened and
-- 'Just False' when it was aborted.
dispatchDecision ∷ SessionState → Maybe Bool
dispatchDecision state = case stDispatch state of
  DispatchClosed → Nothing
  DispatchOpen → Just True
  DispatchAborted → Just False

-- | Whether every role the session has is retired.
allRolesRetired ∷ SessionState → Bool
allRolesRetired = all ((== Retired) . rsPhase) . Map.elems . stRoles

-- | Whether every role's retirement protocol has run to its end: retired, or its releases attempted and one of them
-- failed, which leaves retirement unproven and the role stopping for good.
rolesFinished ∷ SessionState → Bool
rolesFinished = all finished . Map.elems . stRoles
  where
    finished found = rsPhase found == Retired || (rsReleased found && rsReleaseFailed found)

-- | Whether a role's own @init@ has succeeded, every instance of it.
isInitialized ∷ RoleState → Bool
isInitialized role = rsInstances role > 0 && Set.size (rsInited role) >= rsInstances role

-- | Whether every selected role's own @init@ has succeeded.
rolesInitialized ∷ SessionState → Bool
rolesInitialized = all isInitialized . Map.elems . stRoles

-- | Whether retirement of this role is proven: nothing outstanding, and every component it acquired accounted
-- for. A role that acquired nothing holds nothing. Nothing else makes a role retired.
retirable ∷ Role → SessionState → Bool
retirable role state = case Map.lookup role (stRoles state) of
  Nothing → False
  Just found →
    rsAdmit found /= AdmitOpen
      && rsIntents found == 0
      && (BuildOwner `Set.notMember` rsAcquired found || rsOwnerEnded found)
      && (BuildCoordinator `Set.notMember` rsAcquired found || rsDrained found)
      && (Set.null (rsAcquired found) || (rsReleased found && not (rsReleaseFailed found)))

-- | The diagnostics that are waiting to be written.
pendingDiagnostics ∷ SessionState → [Diag]
pendingDiagnostics state = [diag | diag ← toList (stDiags state), dgState diag == DiagPending]

-- Transitions ---------------------------------------------------------------------------------------

-- | What happened.
data Event
  = -- | An instance has been constructed and validated and its @init@ is about to begin.
    Validated !InstanceKey
  | -- | Every instance the composition asked for has been accepted.
    AdmissionComplete
  | -- | A role is about to admit an instance: it will be tracked, or abandoned.
    Intend !Role
  | -- | The admission the intent stood for was accepted, and is now tracked.
    Tracked !Role
  | -- | The admission the intent stood for was not accepted.
    Abandoned !Role
  | -- | An instance's @init@ has succeeded. The clock's reading taken just before is the pacing origin if this
    -- success opens the start gate; a success proved by an instance's settlement after the gate can no longer
    -- open (a stopped session) carries none, and opens nothing.
    InitSucceeded !InstanceKey !(Maybe Instant)
  | -- | A role failed (its entry module, or an instance of it that is not known to the host): its bounded record,
    -- and what else failed as it ended.
    LatchFailure !Role !RoleFailure ![EngineEntry]
  | -- | The host told the session, as an instance's ending began, that the instance failed: the failure is latched,
    -- and the instance marked as told in the same step, so that its settlement adds only what else failed.
    InstanceFailing !Text !Role !RoleFailure ![EngineEntry]
  | -- | The host told the session, when an instance settled, of its failure: if it was told as the ending began,
    -- what else failed is accounted and nothing more; otherwise it is latched, and the instance marked, as if it
    -- had been told then.
    InstanceEscalated !Text !Role !RoleFailure ![EngineEntry]
  | -- | A component of the role was acquired and registered, in the same transaction as its registration.
    Acquired !Role !BuildStep
  | -- | A role's owner has ended. In one step: the claim that its completion is accounted, every failure and retained
    -- cleanup it ended with (each by the identity it already had), and what the settlements of its instances prove,
    -- which the session records as historical facts. Settles the stop owed to the owner: its completion makes the
    -- stop unnecessary.
    OwnerFinalized !Role ![Evidence] ![(InstanceKey, InstanceFact)]
  | -- | A role's coordinator has given back every slot and byte its reads held.
    Drained !Role
  | -- | A role's registered local releases have all been attempted, and these failed.
    ReleasesDone !Role ![Evidence]
  | -- | A stop was handed to its owner.
    StopHanded !Role
  | -- | A stop primitive raised: recorded once, and the stop stays owed.
    StopDefect !Role !EngineEntry
  | -- | A diagnostic was taken to be written: it must be pending.
    DiagClaim !Int
  | -- | A diagnostic was written, or given up.
    DiagDone !Int
  | -- | The thread writing a diagnostic was interrupted: its data stays, marked unfinished.
    DiagInterrupt !Int
  | -- | Failures were caught and are accounted whole: the primary of a failure of the composition, if there was one,
    -- and every cleanup failure attached to it or to a cancellation, each by the identity it had. Which of them
    -- are new is decided in the step.
    Account ![Evidence]
  | -- | A diagnostic could not be written. It is a failure of the engine, recorded without a diagnostic of its own, so
    -- a sink that always raises cannot make the session say more and more about it.
    DiagnosticFailed !EngineEntry
  | -- | The engine, the host, a provider, a sink or cleanup failed, concerning this role's owner when
    -- one is known.
    EngineFault !(Maybe Role) !EngineEntry
  | -- | A normal quit or an interruption was asked for.
    Stop !StopKind
  | -- | The unavailable-state guard latches its terminal failure.
    Terminal !RoleFailure
  | -- | A role's retirement is proven: committed only if 'retirable' says so.
    RoleRetired !Role
  | -- | A diagnostic the session means to say, queued under a stable identity.
    Note !Say
  | -- | The composition is being torn down on a path that no stop or failure began (an exception in its
    -- construction): every gate closes for good and every owner is owed a stop, so that
    -- nothing parked at a gate keeps an owner from ending. It records neither a quit nor a failure.
    Unwind
  deriving (Eq, Show)

-- | What a transition answers the one who asked.
data Answer
  = -- | Nothing to report.
    Done
  | -- | An intent, a claim or a retirement was refused.
    Refused
  | -- | The start gate opened in this transition.
    Opened
  | -- | A failure or a terminal failure was latched; whether it was the first of its kind.
    Latched !Bool
  deriving (Eq, Show)

-- | A diagnostic, as data: what the session means to say, written by the logger it was given.
data Say = Say
  { sayLevel ∷ !SayLevel
  , sayMessage ∷ !Text
  , sayFields ∷ ![(Text, Text)]
  }
  deriving (Eq, Show)

data SayLevel = SayInfo | SayError
  deriving (Eq, Show)

-- | The roles whose stop is still owed, in the order they were recorded.
owedStops ∷ SessionState → [Role]
owedStops = toList . stStops

-- | Apply one event: the one function that changes a 'SessionState'.
--
-- Every stop and every failure closes admission /in this transition/, and records the stop owed in the same
-- step, so nothing is asked to stop before the session says it takes no more work and no stop can be lost between
-- the two. The diagnostics the event means are appended after.
step ∷ Event → SessionState → (SessionState, Answer)
step event state =
  let (next, answer) = transition event state
      said = diagnostics event state next answer
   in (enqueue said next, answer)

-- | Append diagnostics to the queue under stable identities.
enqueue ∷ [Say] → SessionState → SessionState
enqueue said state = foldl' add state said
  where
    add current say =
      current
        { stDiags = stDiags current Seq.|> Diag (stNextDiag current) say DiagPending
        , stNextDiag = stNextDiag current + 1
        }

-- | What an event means, as the diagnostics it owes. Pure: it reads the state before and after.
diagnostics ∷ Event → SessionState → SessionState → Answer → [Say]
diagnostics event before after answer =
  firstly <> engine <> [Say SayInfo "session stopping" [("quit", flag (stQuit after)), ("interrupt", flag (stInterrupt after))] | stopped]
  where
    stopped = stStopping after && not (stStopping before)
    flag = Text.toLower . Text.pack . show
    firstly = case (event, answer) of
      (LatchFailure role failure _, Latched True) → [failed (Just role) failure]
      (InstanceFailing _ role failure _, Latched True) → [failed (Just role) failure]
      (InstanceEscalated _ role failure _, Latched True) → [failed (Just role) failure]
      (Terminal failure, Latched True) → [failed (Just (rfRole failure)) failure]
      (Note say, _) → [say]
      (_, Opened) → [Say SayInfo "start gate opened" []]
      _ → []
    -- the first failure of the engine that no role's failure already announced
    engine = case (erPrimary (stEngine before), erPrimary (stEngine after)) of
      (Nothing, Just entry) | not (announced event) → [engineFailure entry]
      _ → []
    announced = \case
      LatchFailure {} → True
      InstanceFailing {} → True
      InstanceEscalated {} → True
      Terminal _ → True
      DiagnosticFailed _ → True
      _ → False
    failed role failure =
      Say
        SayError
        "role failed"
        [ ("role", maybe "-" roleWord role)
        , ("code", codeWord (rfCode failure))
        , ("stage", stageWord (rfStage failure))
        , ("instance", fromMaybe "-" (rfInstance failure))
        ]
    engineFailure entry =
      Say
        SayError
        "session engine failure"
        [ ("code", codeWord (eeCode entry))
        , ("stage", stageWord (eeStage entry))
        , ("role", maybe "-" roleWord (eeRole entry))
        ]

-- | The transition itself.
transition ∷ Event → SessionState → (SessionState, Answer)
transition event state = case event of
  Validated key
    | stDispatch state /= DispatchClosed → quiet state
    | otherwise → quiet (openDispatch state {stValidated = Set.insert key (stValidated state)})
  AdmissionComplete
    | stDispatch state /= DispatchClosed → quiet state {stAdmitted = True}
    | otherwise → quiet (openDispatch state {stAdmitted = True})
  Intend role → case Map.lookup role (stRoles state) of
    Just found
      | rsAdmit found == AdmitOpen && not (stStopping state) →
          (state {stRoles = Map.insert role found {rsIntents = rsIntents found + 1} (stRoles state)}, Done)
    _ → (state, Refused)
  Tracked role → quiet (adjustRole role (\found → found {rsIntents = max 0 (rsIntents found - 1)}) state)
  Abandoned role → quiet (adjustRole role (\found → found {rsIntents = max 0 (rsIntents found - 1)}) state)
  InitSucceeded key now → initSucceeded key now state
  LatchFailure role failure secondary → latchFailure role failure secondary state
  InstanceFailing host role failure secondary
    | Set.member host (stEarly state) → quiet state
    | otherwise → latchFailure role failure secondary state {stEarly = Set.insert host (stEarly state)}
  InstanceEscalated host role failure secondary
    | Set.member host (stEarly state) → quiet state {stEngine = foldl' (flip (noteEngine (stLimits state))) (stEngine state) secondary}
    | otherwise → latchFailure role failure secondary state {stEarly = Set.insert host (stEarly state)}
  Acquired role built
    -- a role that retired acquires nothing more
    | maybe False ((== Retired) . rsPhase) (Map.lookup role (stRoles state)) → quiet state
    | otherwise → quiet (adjustRole role (\found → found {rsAcquired = Set.insert built (rsAcquired found)}) state)
  OwnerFinalized role evidence facts →
    -- an owner that ended while its admission was open was not asked to by the session: that is an external stop,
    -- and the whole session closes
    -- A second submission of the same end adds nothing: the marker claims the completion's own entries, and what has an
    -- identity is deduplicated by it, so only evidence found newly can count.
    let askedBy = maybe False ((/= AdmitOpen) . rsAdmit) (Map.lookup role (stRoles state))
        already = maybe False rsOwnerEnded (Map.lookup role (stRoles state))
        relevant = if already then [item | item ← evidence, isJust (evKey item)] else evidence
        settled = state {stStops = Seq.filter (/= role) (stStops state)}
        accounted = adjustRole role (\found → found {rsOwnerEnded = True}) settled
        withFacts = foldl' recordFact accounted facts
        (next, _) = accountEvidence (Just role) relevant withFacts
     in if askedBy then quiet next else wholeStop next Done
  Drained role → quiet (adjustRole role (\found → found {rsDrained = True}) state)
  ReleasesDone role evidence →
    -- the attempts are claimed once: a second submission of them adds nothing, and cannot undo a retirement
    let already = maybe False rsReleased (Map.lookup role (stRoles state))
        relevant = if already then [item | item ← evidence, isJust (evKey item)] else evidence
        marked
          | already = state
          | otherwise = adjustRole role (\found → found {rsReleased = True, rsReleaseFailed = rsReleaseFailed found || not (null evidence)}) state
        (next, _) = accountEvidence (Just role) relevant marked
     in quiet next
  StopHanded role →
    quiet (adjustRole role (\found → found {rsStopHanded = True}) state {stStops = Seq.filter (/= role) (stStops state)})
  StopDefect role entry
    | Set.member role (stStopDefects state) → quiet state
    | otherwise → engineFault (Just role) entry state {stStopDefects = Set.insert role (stStopDefects state)}
  DiagClaim identity → case findDiag identity state of
    Just diag | dgState diag == DiagPending → quiet (setDiag identity DiagInFlight state)
    _ → (state, Refused)
  DiagDone identity → quiet state {stDiags = Seq.filter ((/= identity) . dgId) (stDiags state)}
  DiagInterrupt identity → case findDiag identity state of
    Just diag | dgState diag == DiagInFlight → quiet (setDiag identity DiagInterrupted state)
    _ → quiet state
  Account evidence → quiet (fst (accountEvidence Nothing evidence state))
  DiagnosticFailed entry → engineFault Nothing entry state
  EngineFault role entry → engineFault role entry state
  Stop kind →
    let marked = case kind of
          StopQuit → state {stQuit = True}
          StopInterrupt → state {stInterrupt = True}
     in wholeStop marked Done
  Terminal failure → case stTerminal state of
    Just _ → (state, Latched False)
    Nothing →
      let latched = state {stTerminal = Just failure, stEngine = noteEngine (stLimits state) (roleFailureEntry failure) (stEngine state)}
       in wholeStop latched (Latched True)
  RoleRetired role
    | retirable role state →
        quiet
          ( adjustRole
              role
              (\found → found {rsPhase = Retired, rsAdmit = AdmitClosed})
              state {stStops = Seq.filter (/= role) (stStops state)}
          )
    | otherwise → (state, Refused)
  Note _ → quiet state
  Unwind -> wholeStop state Done

-- | A transition that only changes the state.
quiet ∷ SessionState → (SessionState, Answer)
quiet next = (next, Done)

findDiag ∷ Int → SessionState → Maybe Diag
findDiag identity state = case [diag | diag ← toList (stDiags state), dgId diag == identity] of
  found : _ → Just found
  [] → Nothing

setDiag ∷ Int → DiagState → SessionState → SessionState
setDiag identity new state =
  state {stDiags = fmap (\diag → if dgId diag == identity then diag {dgState = new} else diag) (stDiags state)}

-- | Record what a settlement proved about one instance, once: the first fact stands, and a proven @init@ is
-- historical whatever the instance did afterwards. It opens nothing and reads no clock.
recordFact ∷ SessionState → (InstanceKey, InstanceFact) → SessionState
recordFact state (key, fact) = case Map.lookup (ikRole key) (stRoles state) of
  Nothing → state
  Just found →
    let facts = Map.insertWith (\_ old → old) (ikSlot key) fact (rsFacts found)
        recorded = state {stRoles = Map.insert (ikRole key) found {rsFacts = facts} (stRoles state)}
     in if ifInitialized fact then let (next, _) = initSucceeded key Nothing recorded in next else recorded

-- | Account evidence once: an entry whose identity was seen before is the same failure and adds nothing; the rest
-- are noted in the engine report, the first of them attributed to the role when there is one and it has no failure
-- yet. Answers whether anything was new.
accountEvidence ∷ Maybe Role → [Evidence] → SessionState → (SessionState, Bool)
accountEvidence role evidence state = foldl' one (state, False) evidence
  where
    one (current, new) (Evidence key entry)
      | Just seen ← key, Set.member seen (stEvidence current) = (current, new)
      | otherwise =
          let marked = case key of
                Just found → current {stEvidence = Set.insert found (stEvidence current)}
                Nothing → current
              (next, _) = engineFault role entry marked
           in (next, True)

-- | Open the dispatch gate if every instance it waits for has been validated and admission is complete.
openDispatch ∷ SessionState → SessionState
openDispatch state
  | stDispatch state == DispatchClosed && stAdmitted state && stExpected state `Set.isSubsetOf` stValidated state =
      state {stDispatch = DispatchOpen}
  | otherwise = state

-- | Record that these roles' owners are owed a stop, once each: not one already handed a stop, and not one whose
-- completion is accounted, which has no use for it.
owing ∷ [Role] → SessionState → SessionState
owing roles state = state {stStops = foldl' record (stStops state) roles}
  where
    record queue role
      | role `elem` toList queue = queue
      | Just found ← Map.lookup role (stRoles state), rsStopHanded found || rsOwnerEnded found = queue
      | otherwise = queue Seq.|> role

adjustRole ∷ Role → (RoleState → RoleState) → SessionState → SessionState
adjustRole role change state = state {stRoles = Map.adjust change role (stRoles state)}

-- | An instance's @init@ succeeded. The fact is recorded whatever else has happened; the role moves to
-- @ready@ or @running@ and the start gate opens only if nothing has failed or stopped.
initSucceeded ∷ InstanceKey → Maybe Instant → SessionState → (SessionState, Answer)
initSucceeded key now state = case Map.lookup (ikRole key) (stRoles state) of
  Nothing → (state, Done)
  Just found →
    let recorded = found {rsInited = Set.insert (ikSlot key) (rsInited found)}
        live = rsFailure recorded == Nothing && not (stStopping state) && rsAdmit recorded == AdmitOpen
        advanced
          | isInitialized recorded && live && rsPhase recorded == Starting =
              recorded {rsPhase = case ikRole key of Presentation → Running; Gameplay → Ready}
          | otherwise = recorded
        state1 = state {stRoles = Map.insert (ikRole key) advanced (stRoles state)}
     in case now of
          Just origin
            | startable state1 →
                let opened = state1 {stStart = StartOpen, stOrigin = Just origin}
                    started = opened {stRoles = Map.adjust (\r → if rsPhase r == Ready then r {rsPhase = Running} else r) Gameplay (stRoles opened)}
                 in (started, Opened)
          _ → (state1, Done)

-- | Whether the start gate may open now: closed, nothing stopped or failed, the dispatch gate
-- open and every selected role's own @init@ done.
startable ∷ SessionState → Bool
startable state =
  stStart state == StartClosed
    && stDispatch state == DispatchOpen
    && not (stStopping state)
    && rolesInitialized state
    && all (\r → rsFailure r == Nothing && rsAdmit r == AdmitOpen) (Map.elems (stRoles state))

-- | A role's instance failed.
--
-- The failure latches (the first of a role stays) and the role stops taking work. It is a boot
-- failure if the start gate has not opened, which ends the whole session; after that a presentation
-- failure, or the failure of a session's only role, ends the whole session too, and a logical failure
-- beside a healthy presentation role stops the logical role alone.
latchFailure ∷ Role → RoleFailure → [EngineEntry] → SessionState → (SessionState, Answer)
latchFailure role failure secondary state = case Map.lookup role (stRoles state) of
  Nothing → (state, Done)
  Just found →
    let first = rsFailure found == Nothing
        latched =
          found
            { rsFailure = maybe (Just failure) Just (rsFailure found)
            , rsPhase = if rsPhase found == Retired then Retired else Stopping
            }
        order = if first then stFailureOrder state <> [role] else stFailureOrder state
        report = foldl' (flip (noteEngine (stLimits state))) (stEngine state) (roleFailureEntry failure : secondary)
        state1 = state {stRoles = Map.insert role latched (stRoles state), stFailureOrder = order, stEngine = report}
        bootFailure = stStart state /= StartOpen
        wholeSession = stStopping state || bootFailure || role == Presentation || Map.size (stRoles state) == 1
     in if wholeSession
          then wholeStop state1 (Latched first)
          else (closeRole role state1, Latched first)

-- | Close one role's admission now, owing its owner a stop if it was taking work.
closeRole ∷ Role → SessionState → SessionState
closeRole role state = case Map.lookup role (stRoles state) of
  Just found
    | rsAdmit found == AdmitOpen →
        owing [role] state {stRoles = Map.insert role found {rsAdmit = AdmitStopping, rsPhase = stopped found} (stRoles state)}
    | otherwise → state {stRoles = Map.insert role found {rsPhase = stopped found} (stRoles state)}
  Nothing → state
  where
    stopped found = if rsPhase found == Retired then Retired else Stopping

-- | End the whole session: every role's admission closes, both gates close for good, and every role not yet retired
-- is owed a stop, whether or not its admission was open, because an owner that has not been asked to stop is the one
-- thing nothing else will end. Idempotent: an owner already owed is not owed again.
wholeStop ∷ SessionState → Answer → (SessionState, Answer)
wholeStop state answer =
  ( owing owed closed {stStopping = True}
  , answer
  )
  where
    roles = Map.toList (stRoles state)
    owed = [role | (role, found) ← roles, rsPhase found /= Retired]
    closed =
      state
        { stRoles = Map.map closeOne (stRoles state)
        , stDispatch = if stDispatch state == DispatchClosed then DispatchAborted else stDispatch state
        , stStart = if stStart state == StartClosed then StartShut else stStart state
        }
    closeOne found = case rsPhase found of
      Retired → found
      _ → found {rsAdmit = if rsAdmit found == AdmitClosed then AdmitClosed else AdmitStopping, rsPhase = Stopping}

-- | An engine, host, provider, sink or cleanup failure ends the whole session. It is accounted in the
-- engine report, and, when it concerns a role's owner, it is that role's failure if the role has none.
engineFault ∷ Maybe Role → EngineEntry → SessionState → (SessionState, Answer)
engineFault role entry state =
  let report = noteEngine (stLimits state) entry (stEngine state)
      state1 = state {stEngine = report}
      withRole = case role >>= \r → (,) r <$> Map.lookup r (stRoles state1) of
        Just (r, found)
          | rsFailure found == Nothing →
              state1
                { stRoles = Map.insert r found {rsFailure = Just (boundFailure (stLimits state) (engineRoleFailure r entry))} (stRoles state1)
                , stFailureOrder = stFailureOrder state1 <> [r]
                }
        _ → state1
      first = erPrimary (stEngine state) == Nothing
   in wholeStop withRole (Latched first)

-- | The name of an event, for the harness's points and for logs.
eventName ∷ Event → Text
eventName = \case
  Validated _ → "Validated"
  AdmissionComplete → "AdmissionComplete"
  Intend _ → "Intend"
  Tracked _ → "Tracked"
  Abandoned _ → "Abandoned"
  InitSucceeded _ _ → "InitSucceeded"
  LatchFailure {} → "LatchFailure"
  InstanceFailing {} → "InstanceFailing"
  InstanceEscalated {} → "InstanceEscalated"
  Acquired _ _ → "Acquired"
  OwnerFinalized {} → "OwnerFinalized"
  Drained _ → "Drained"
  ReleasesDone _ _ → "ReleasesDone"
  StopHanded _ → "StopHanded"
  StopDefect _ _ → "StopDefect"
  DiagClaim _ → "DiagClaim"
  DiagDone _ → "DiagDone"
  DiagInterrupt _ → "DiagInterrupt"
  Account _ → "Account"
  DiagnosticFailed _ → "DiagnosticFailed"
  EngineFault _ _ → "EngineFault"
  Stop _ → "Stop"
  Terminal _ → "Terminal"
  RoleRetired _ → "RoleRetired"
  Note _ → "Note"
  Unwind → "Unwind"

-- What it publishes ---------------------------------------------------------------------------------

-- | One role's status, as the status record shows it.
data RoleStatus = RoleStatus
  { roleInitialized ∷ !Bool
  -- ^ The role's own @init@ has succeeded (every instance of it). Historical.
  , rolePhase ∷ !Phase
  , roleFailed ∷ !Bool
  , roleFailure ∷ !(Maybe RoleFailure)
  }
  deriving (Eq, Show)

-- | The session's status. An absent role is 'Nothing'; failure and stopping are separate facts.
data SessionStatus = SessionStatus
  { statusStopping ∷ !Bool
  , statusGameplay ∷ !(Maybe RoleStatus)
  , statusPresentation ∷ !(Maybe RoleStatus)
  , statusTerminalFailed ∷ !Bool
  }
  deriving (Eq, Show)

-- | The status the state publishes.
statusOf ∷ SessionState → SessionStatus
statusOf state =
  SessionStatus
    { statusStopping = stStopping state
    , statusGameplay = roleStatus <$> Map.lookup Gameplay (stRoles state)
    , statusPresentation = roleStatus <$> Map.lookup Presentation (stRoles state)
    , statusTerminalFailed = stTerminal state /= Nothing
    }
  where
    roleStatus found =
      RoleStatus
        { roleInitialized = isInitialized found
        , rolePhase = rsPhase found
        , roleFailed = rsFailure found /= Nothing
        , roleFailure = rsFailure found
        }

-- | How a session came out, ranked: a failure outranks an interruption, which outranks a normal
-- quit or a normal end, whatever order they were asked or found in.
data Verdict = VerdictSuccess | VerdictInterrupted | VerdictFailure
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The internal outcome data the launcher will map to an exit status.
data SessionOutcome = SessionOutcome
  { outVerdict ∷ !Verdict
  , outFailures ∷ ![RoleFailure]
  -- ^ Each failed role's first failure, in the order they latched; the head is the primary.
  , outEngine ∷ !EngineReport
  , outTerminal ∷ !(Maybe RoleFailure)
  , outQuit ∷ !Bool
  , outInterrupted ∷ !Bool
  , outRetired ∷ !Bool
  -- ^ Every role has actually retired.
  }
  deriving (Eq, Show)

-- | The outcome the state holds now.
outcomeOf ∷ SessionState → SessionOutcome
outcomeOf state =
  SessionOutcome
    { outVerdict = verdict
    , outFailures = [failure | role ← stFailureOrder state, Just found ← [Map.lookup role (stRoles state)], Just failure ← [rsFailure found]]
    , outEngine = stEngine state
    , outTerminal = stTerminal state
    , outQuit = stQuit state
    , outInterrupted = stInterrupt state
    , outRetired = allRolesRetired state
    }
  where
    failed = not (null (stFailureOrder state)) || erPrimary (stEngine state) /= Nothing || stTerminal state /= Nothing
    verdict
      | failed = VerdictFailure
      | stInterrupt state = VerdictInterrupted
      | otherwise = VerdictSuccess

-- | The historical facts the session holds, bounded by the fixed set of roles and instances: what each settlement
-- proved, kept once, and which owners have been handed the request to stop (the receipts of the barrier). A read of
-- them is an internal endpoint, not a status field.
data History = History
  { historyFacts ∷ !(Map InstanceKey InstanceFact)
  , historyStopped ∷ ![Role]
  -- ^ The roles whose owner was asked to stop, in role order.
  , historyDiagnostics ∷ ![(Text, DiagState)]
  -- ^ The diagnostics meant and not finished, by message and state, in the order they were meant.
  }
  deriving (Eq, Show)

-- | The history the state holds now.
historyOf ∷ SessionState → History
historyOf state =
  History
    (Map.fromList [(InstanceKey role slot, fact) | (role, found) ← Map.toList (stRoles state), (slot, fact) ← Map.toList (rsFacts found)])
    [role | (role, found) ← Map.toList (stRoles state), rsStopHanded found]
    [(sayMessage (dgSay diag), dgState diag) | diag ← toList (stDiags state)]
