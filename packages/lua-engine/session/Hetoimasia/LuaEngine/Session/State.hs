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
-- the claim that an owner's completion was accounted ('stAccounted') and the historical facts the event proves
-- (an @init@ that succeeded). It also appends to 'stOwed', in the same step, the effects the event owes: the stop
-- of an owner whose admission it closed ('OweStop') and the diagnostics it means ('OweSay'). Nothing the event
-- means is left to a step after it, so there is no window in which half of it has happened.
--
-- The owed effects are performed by whoever runs the queue (the committer, the driver, every teardown path), one
-- at a time, each recorded as done only after it was performed. An effect that raises is recorded as a failure of
-- the engine and the queue goes on; an effect whose performer was cancelled stays owed (a stop) or is put back (a
-- diagnostic) for the next one. A stop is idempotent, so a stop done twice is a stop done once.
--
-- = The phases
--
-- A role is @starting@ until its own @init@ has succeeded (every admitted instance of it), then
-- @ready@ (gameplay, waiting for the start gate) or @running@ (presentation at once, gameplay when the
-- start gate opens); @stopping@ from the moment a stop or a failure closes its admission; and
-- @retired@ only when the coordinator has seen the role's owner end and everything it borrowed given
-- back. A failed role never returns to @ready@ or @running@. The first failure of a role stays.
module Hetoimasia.LuaEngine.Session.State
  ( -- * Keys
    InstanceKey (..)

    -- * Vocabulary
  , Phase (..)
  , Admit (..)
  , StopKind (..)
  , DispatchGate (..)
  , StartGate (..)

    -- * The state
  , RoleState (..)
  , SessionState (..)
  , newSessionState
  , roleAdmit
  , dispatchDecision
  , allRolesRetired
  , rolesInitialized

    -- * Transitions
  , Event (..)
  , Answer (..)
  , Say (..)
  , SayLevel (..)
  , Owed (..)
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
  ) where

import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import qualified Data.Sequence as Seq
import Data.Sequence (Seq)
import qualified Data.Set as Set
import Data.Set (Set)
import Data.Foldable (toList)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Time (Instant)
import Hetoimasia.LuaEngine.Manifest (Role (..))
import Hetoimasia.LuaEngine.Session.Harness (InstanceKey (..))
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

-- The state -----------------------------------------------------------------------------------------

-- | One role's facts.
data RoleState = RoleState
  { rsInstances ∷ !Int
  -- ^ How many instances the composition admits for the role.
  , rsInited ∷ !(Set Int)
  -- ^ The slots whose @init@ has succeeded. Historical: it only grows.
  , rsPhase ∷ !Phase
  , rsAdmit ∷ !Admit
  , rsFailure ∷ !(Maybe RoleFailure)
  -- ^ The first failure, latched. Never replaced.
  , rsIntents ∷ !Int
  -- ^ Admissions begun and neither tracked nor abandoned yet.
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
  , stOwed ∷ !(Seq Owed)
  -- ^ The effects the transitions so far owe and nobody has performed: the stops, in the order the admissions
  -- closed, and the diagnostics, in the order they were meant.
  , stAccounted ∷ !(Set Role)
  -- ^ The roles whose owner's completion has been accounted, once each.
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
    { stRoles = Map.fromList [(role, RoleState n Set.empty Starting AdmitOpen Nothing 0) | (role, n) ← roles]
    , stDispatch = DispatchClosed
    , stExpected = Set.fromList [InstanceKey role slot | (role, n) ← roles, slot ← [0 .. n - 1]]
    , stValidated = Set.empty
    , stAdmitted = False
    , stStart = StartClosed
    , stOrigin = Nothing
    , stOwed = Seq.empty
    , stAccounted = Set.empty
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

-- | Whether a role's own @init@ has succeeded, every instance of it.
isInitialized ∷ RoleState → Bool
isInitialized role = rsInstances role > 0 && Set.size (rsInited role) >= rsInstances role

-- | Whether every selected role's own @init@ has succeeded.
rolesInitialized ∷ SessionState → Bool
rolesInitialized = all isInitialized . Map.elems . stRoles

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
  | -- | A role's owner has ended. In one step: the claim that its completion is accounted (once, whichever path
    -- found it first), every failure and retained cleanup it ended with, and the @init@s the settlements of its
    -- instances prove, which the session records as historical facts.
    OwnerFinalized !Role ![EngineEntry] ![InstanceKey]
  | -- | An effect owed was performed, or given up: a stop, or a diagnostic already claimed.
    Settled !Owed
  | -- | A diagnostic that was claimed and whose performer was cancelled goes back to the front of the queue.
    Requeued !Owed
  | -- | The composition failed: the primary failure and every cleanup failure attached to it, as one event, so the
    -- evidence is committed whole before any effect runs.
    CompositionFailed ![EngineEntry]
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
  | -- | A role's owner has ended and everything it borrowed has been given back.
    RoleRetired !Role
  | -- | The composition is being torn down on a path that no stop or failure began (an exception in its
    -- construction): every gate closes for good and every owner is reported to be stopped, so that
    -- nothing parked at a gate keeps an owner from ending. It records neither a quit nor a failure.
    Unwind
  deriving (Eq, Show)

-- | What a transition answers the one who asked.
data Answer
  = -- | Nothing to report.
    Done
  | -- | An intent was refused: the role takes no more work.
    Refused
  | -- | The start gate opened in this transition.
    Opened
  | -- | A failure or a terminal failure was latched; whether it was the first of its kind.
    Latched !Bool
  deriving (Eq, Show)

-- | The effects a transition owes, performed after it has committed by whoever runs the queue.
data Owed
  = -- | The owner of this role is to be asked to stop. Idempotent.
    OweStop !Role
  | -- | A diagnostic to write.
    OweSay !Say
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
owedStops state = [role | OweStop role ← toList (stOwed state)]

-- | Apply one event: the one function that changes a 'SessionState'.
--
-- Every stop and every failure closes admission /in this transition/, and records the stop owed in the same
-- step, so nothing is asked to stop before the session says it takes no more work and no stop can be lost between
-- the two. The diagnostics the event means are appended after the stops it owes.
step ∷ Event → SessionState → (SessionState, Answer)
step event state =
  let (next, answer, _) = transition event state
      said = diagnostics event state next answer
   in (next {stOwed = stOwed next <> Seq.fromList (map OweSay said)}, answer)

-- | What an event means, as the diagnostics it owes. Pure: it reads the state before and after.
diagnostics ∷ Event → SessionState → SessionState → Answer → [Say]
diagnostics event before after answer =
  firstly <> [Say SayInfo "session stopping" [("quit", flag (stQuit after)), ("interrupt", flag (stInterrupt after))] | stopped]
  where
    stopped = stStopping after && not (stStopping before)
    flag = Text.toLower . Text.pack . show
    firstly = case (event, answer) of
      (LatchFailure role failure _, Latched True) → [failed (Just role) failure]
      (InstanceFailing _ role failure _, Latched True) → [failed (Just role) failure]
      (InstanceEscalated _ role failure _, Latched True) → [failed (Just role) failure]
      (Terminal failure, Latched True) → [failed (Just (rfRole failure)) failure]
      (EngineFault role entry, Latched True) → [engineFailure role entry]
      (OwnerFinalized role (entry : _) _, _) | erPrimary (stEngine before) == Nothing → [engineFailure (Just role) entry]
      (CompositionFailed (entry : _), _) | erPrimary (stEngine before) == Nothing → [engineFailure Nothing entry]
      (_, Opened) → [Say SayInfo "start gate opened" []]
      _ → []
    failed role failure =
      Say
        SayError
        "role failed"
        [ ("role", maybe "-" roleWord role)
        , ("code", codeWord (rfCode failure))
        , ("stage", stageWord (rfStage failure))
        , ("instance", fromMaybe "-" (rfInstance failure))
        ]
    engineFailure role entry =
      Say
        SayError
        "session engine failure"
        [ ("code", codeWord (eeCode entry))
        , ("stage", stageWord (eeStage entry))
        , ("role", maybe (maybe "-" roleWord (eeRole entry)) roleWord role)
        ]

-- | The transition itself. Its third component is the stops it owes, which 'step' has already recorded in the state.
transition ∷ Event → SessionState → (SessionState, Answer, [Role])
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
          (state {stRoles = Map.insert role found {rsIntents = rsIntents found + 1} (stRoles state)}, Done, [])
    _ → (state, Refused, [])
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
  OwnerFinalized role entries inits ->
    let accounted
          | Set.member role (stAccounted state) = state
          | otherwise = foldl' (\s entry → let (n, _, _) = engineFault (Just role) entry s in n) state {stAccounted = Set.insert role (stAccounted state)} entries
        proven = foldl' (\s key → let (n, _, _) = initSucceeded key Nothing s in n) accounted inits
     in quiet proven
  Settled owed → quiet state {stOwed = settleOne owed (stOwed state)}
  Requeued owed → quiet state {stOwed = owed Seq.<| stOwed state}
  CompositionFailed entries ->
    let folded = foldl' (\s entry -> let (n, _, _) = engineFault Nothing entry s in n) state entries
        first = erPrimary (stEngine state) == Nothing && not (null entries)
     in (folded, if null entries then Done else Latched first, [])
  DiagnosticFailed entry → engineFault Nothing entry state
  EngineFault role entry → engineFault role entry state
  Stop kind →
    let marked = case kind of
          StopQuit → state {stQuit = True}
          StopInterrupt → state {stInterrupt = True}
     in wholeStop marked Done
  Terminal failure → case stTerminal state of
    Just _ → (state, Latched False, [])
    Nothing →
      let latched = state {stTerminal = Just failure, stEngine = noteEngine (stLimits state) (roleFailureEntry failure) (stEngine state)}
       in wholeStop latched (Latched True)
  RoleRetired role →
    quiet (adjustRole role (\found → found {rsPhase = Retired, rsAdmit = AdmitClosed}) state {stOwed = Seq.filter (/= OweStop role) (stOwed state)})
  Unwind -> wholeStop state Done
  where
    quiet next = (next, Done, [])

-- | Take an effect off the queue: a stop leaves it altogether (it is queued once), a diagnostic leaves once, so two
-- identical lines meant twice are written twice.
settleOne ∷ Owed → Seq Owed → Seq Owed
settleOne owed queue = case owed of
  OweStop _ → Seq.filter (/= owed) queue
  OweSay _ → maybe queue (`Seq.deleteAt` queue) (Seq.elemIndexL owed queue)

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
  OwnerFinalized {} → "OwnerFinalized"
  Settled _ → "Settled"
  Requeued _ → "Requeued"
  CompositionFailed _ → "CompositionFailed"
  DiagnosticFailed _ → "DiagnosticFailed"
  EngineFault _ _ → "EngineFault"
  Stop _ → "Stop"
  Terminal _ → "Terminal"
  RoleRetired _ → "RoleRetired"
  Unwind → "Unwind"

-- | Open the dispatch gate if every instance it waits for has been validated and admission is complete.
openDispatch ∷ SessionState → SessionState
openDispatch state
  | stDispatch state == DispatchClosed && stAdmitted state && stExpected state `Set.isSubsetOf` stValidated state =
      state {stDispatch = DispatchOpen}
  | otherwise = state

-- | Record that these roles' owners are owed a stop.
owing ∷ [Role] → SessionState → SessionState
owing roles state = state {stOwed = foldl' record (stOwed state) roles}
  where
    record queue role
      | OweStop role `elem` toList queue = queue
      | otherwise = queue Seq.|> OweStop role

adjustRole ∷ Role → (RoleState → RoleState) → SessionState → SessionState
adjustRole role change state = state {stRoles = Map.adjust change role (stRoles state)}

-- | An instance's @init@ succeeded. The fact is recorded whatever else has happened; the role moves to
-- @ready@ or @running@ and the start gate opens only if nothing has failed or stopped.
initSucceeded ∷ InstanceKey → Maybe Instant → SessionState → (SessionState, Answer, [Role])
initSucceeded key now state = case Map.lookup (ikRole key) (stRoles state) of
  Nothing → (state, Done, [])
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
                 in (started, Opened, [])
          _ → (state1, Done, [])

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
latchFailure ∷ Role → RoleFailure → [EngineEntry] → SessionState → (SessionState, Answer, [Role])
latchFailure role failure secondary state = case Map.lookup role (stRoles state) of
  Nothing → (state, Done, [])
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
          then
            let (next, _, effects) = wholeStop state1 Done
             in (next, Latched first, effects)
          else
            let (next, effects) = closeRole role state1
             in (next, Latched first, effects)

-- | Close one role's admission now, reporting its owner to be stopped if it was taking work.
closeRole ∷ Role → SessionState → (SessionState, [Role])
closeRole role state = case Map.lookup role (stRoles state) of
  Just found
    | rsAdmit found == AdmitOpen →
        ( owing [role] state {stRoles = Map.insert role found {rsAdmit = AdmitStopping, rsPhase = stopped found} (stRoles state)}
        , [role]
        )
    | otherwise → (state {stRoles = Map.insert role found {rsPhase = stopped found} (stRoles state)}, [])
  Nothing → (state, [])
  where
    stopped found = if rsPhase found == Retired then Retired else Stopping

-- | End the whole session: every role's admission closes, both gates close for good, and every role
-- that was taking work is reported to be stopped. Idempotent in its effects: a role already stopping is
-- not reported again.
wholeStop ∷ SessionState → Answer → (SessionState, Answer, [Role])
wholeStop state answer =
  ( owing reported closed {stStopping = True}
  , answer
  , reported
  )
  where
    roles = Map.toList (stRoles state)
    reported = [role | (role, found) ← roles, rsAdmit found == AdmitOpen]
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
engineFault ∷ Maybe Role → EngineEntry → SessionState → (SessionState, Answer, [Role])
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
