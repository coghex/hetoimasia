{-# LANGUAGE OverloadedStrings #-}

-- | The session's pure model: the state machine every gate, phase and failure goes through, the failure
-- schema's bounds and the pacing arithmetic. No VM, no thread and no clock: the transitions are applied
-- to values, in every order the events can arrive, and the invariants the coordinator relies on are
-- checked after every step of every sequence.
module Test.LuaEngine.Session.Model (spec) where

import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, listToMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Foundation.Time (Duration, DurationRequirement (AllowZero, RequirePositive), Instant, durationFromNanoseconds, scriptedInstant)
import Hetoimasia.LuaEngine.Manifest (Role (..))
import Hetoimasia.LuaEngine.Profile (ByteLimit (RoleFailureRecordBytes), fixedM1Profile)
import Hetoimasia.LuaEngine.Session.Failure
import Hetoimasia.LuaEngine.Session.Pacing
import Hetoimasia.LuaEngine.Session.State
import Test.Hspec
import Test.LuaEngine.Request.Profiles (bytesOf)

spec ∷ Spec
spec = describe "model" $ do
  gates
  startGate
  policy
  ranking
  admission
  invariants
  failures
  report
  pacing

-- Fixtures ---------------------------------------------------------------------------------------------

limits ∷ FailureLimits
limits = failureLimitsOf fixedM1Profile

both ∷ SessionState
both = newSessionState limits [(Gameplay, 1), (Presentation, 1)]

gameplayOnly ∷ SessionState
gameplayOnly = newSessionState limits [(Gameplay, 1)]

presentationOnly ∷ SessionState
presentationOnly = newSessionState limits [(Presentation, 1)]

g0, p0 ∷ InstanceKey
g0 = InstanceKey Gameplay 0
p0 = InstanceKey Presentation 0

-- | Apply events in order, keeping every effect reported and every answer.
runAll ∷ [Event] → SessionState → (SessionState, [Answer], [Effect])
runAll events initial = foldl' go (initial, [], []) events
  where
    go (state, answers, effects) event =
      let (next, answer, reported) = step event state
       in (next, answers <> [answer], effects <> reported)

applied ∷ [Event] → SessionState → SessionState
applied events initial = let (state, _, _) = runAll events initial in state

effectsOf ∷ [Event] → SessionState → [Effect]
effectsOf events initial = let (_, _, effects) = runAll events initial in effects

answersOf ∷ [Event] → SessionState → [Answer]
answersOf events initial = let (_, answers, _) = runAll events initial in answers

failure ∷ Role → FailureStage → Text → RoleFailure
failure role stage = newRoleFailure LuaError stage role

validated ∷ [Event]
validated = [Validated g0, Validated p0, AdmissionComplete]

phaseOfRole ∷ Role → SessionState → Maybe Phase
phaseOfRole role state = rsPhase <$> Map.lookup role (stRoles state)

-- The dispatch gate -----------------------------------------------------------------------------------

gates ∷ Spec
gates = describe "the dispatch gate" $ do
  it "opens only when every first instance is validated and admission is complete, in any order" $
    mapM_
      ( \events → do
          let state = applied events both
          dispatchDecision state `shouldBe` Just True
      )
      (permutations' validated)

  it "stays closed while any first instance is unvalidated or admission is incomplete" $ do
    dispatchDecision (applied [Validated g0, AdmissionComplete] both) `shouldBe` Nothing
    dispatchDecision (applied [Validated g0, Validated p0] both) `shouldBe` Nothing
    dispatchDecision (applied [AdmissionComplete] both) `shouldBe` Nothing

  it "ignores the validation of a second instance, which it does not wait for" $
    dispatchDecision (applied [Validated (InstanceKey Gameplay 1), Validated g0, AdmissionComplete] (newSessionState limits [(Gameplay, 2)])) `shouldBe` Just True

  it "is aborted for good by a stop or a failure, and a late validation cannot open it" $ do
    let stopped = applied [Validated g0, Stop StopQuit] both
    dispatchDecision stopped `shouldBe` Just False
    dispatchDecision (applied [Validated p0, AdmissionComplete] stopped) `shouldBe` Just False
    let failed = applied [LatchFailure Gameplay (failure Gameplay OnModule "bad cadence") []] both
    dispatchDecision failed `shouldBe` Just False
    dispatchDecision (applied validated failed) `shouldBe` Just False

  it "needs only the one role's first instance in a one-role session" $ do
    dispatchDecision (applied [Validated g0, AdmissionComplete] gameplayOnly) `shouldBe` Just True
    dispatchDecision (applied [Validated p0, AdmissionComplete] presentationOnly) `shouldBe` Just True

-- The start gate -----------------------------------------------------------------------------------------

startGate ∷ Spec
startGate = describe "the start gate and the phases" $ do
  let opened = validated

  it "starts presentation on its own success and gameplay waiting, ready, for the joint gate" $ do
    let state = applied (opened <> [InitSucceeded p0]) both
    phasesOf' state `shouldBe` (Just Starting, Just Running)
    stStart state `shouldBe` StartClosed
    let ready = applied (opened <> [InitSucceeded g0]) both
    phasesOf' ready `shouldBe` (Just Ready, Just Starting)

  it "opens, once, in the transaction of the last success, whichever order they come in" $ do
    mapM_
      ( \events → do
          let (state, answers, _) = runAll (opened <> events) both
          stStart state `shouldBe` StartOpen
          phasesOf' state `shouldBe` (Just Running, Just Running)
          length (filter (== Opened) answers) `shouldBe` 1
      )
      (permutations' [InitSucceeded g0, InitSucceeded p0])

  it "needs only its own init in a one-role session" $ do
    let (state, answers, _) = runAll (opened' gameplayOnly <> [InitSucceeded g0]) gameplayOnly
    stStart state `shouldBe` StartOpen
    answers `shouldSatisfy` elem Opened
    phasesOf' state `shouldBe` (Just Running, Nothing)
    let (state', answers', _) = runAll (opened' presentationOnly <> [InitSucceeded p0]) presentationOnly
    stStart state' `shouldBe` StartOpen
    answers' `shouldSatisfy` elem Opened
    phasesOf' state' `shouldBe` (Nothing, Just Running)

  it "does not open for a late success once the gate is shut, but remembers the success" $ do
    let state = applied (opened <> [InitSucceeded p0, Stop StopQuit, InitSucceeded g0]) both
    stStart state `shouldBe` StartShut
    phasesOf' state `shouldBe` (Just Stopping, Just Stopping)
    roleInitializedOf Gameplay state `shouldBe` Just True
    roleInitializedOf Presentation state `shouldBe` Just True

  it "counts a role initialized only once every instance of it has succeeded" $ do
    let two = newSessionState limits [(Gameplay, 2)]
        state = applied [InitSucceeded g0] two
    roleInitializedOf Gameplay state `shouldBe` Just False
    stStart state `shouldBe` StartClosed
    let done = applied [Validated g0, AdmissionComplete, InitSucceeded g0, InitSucceeded (InstanceKey Gameplay 1)] two
    roleInitializedOf Gameplay done `shouldBe` Just True
    stStart done `shouldBe` StartOpen
  where
    opened' state = [Validated k | k ← Set.toList (stExpected state)] <> [AdmissionComplete]

phasesOf' ∷ SessionState → (Maybe Phase, Maybe Phase)
phasesOf' state = (phaseOfRole Gameplay state, phaseOfRole Presentation state)

roleInitializedOf ∷ Role → SessionState → Maybe Bool
roleInitializedOf role state = case role of
  Gameplay → roleInitialized <$> statusGameplay (statusOf state)
  Presentation → roleInitialized <$> statusPresentation (statusOf state)

-- The failure policy ---------------------------------------------------------------------------------------

policy ∷ Spec
policy = describe "the failure policy" $ do
  let ready = validated <> [InitSucceeded g0, InitSucceeded p0]

  it "makes a failure before the start gate opens a boot failure that stops both roles at once" $ do
    let events = validated <> [InitSucceeded p0, LatchFailure Gameplay (failure Gameplay OnInit "init failed") []]
        (state, answers, effects) = runAll events both
    stStopping state `shouldBe` True
    stStart state `shouldBe` StartShut
    last answers `shouldBe` Latched True
    effects `shouldBe` [StopRoles [Gameplay, Presentation]]
    phasesOf' state `shouldBe` (Just Stopping, Just Stopping)

  it "closes admission in the transition that reports the owners to stop" $ do
    let (state, _, effects) = runAll [LatchFailure Presentation (failure Presentation OnInit "x") []] both
    effects `shouldBe` [StopRoles [Gameplay, Presentation]]
    mapM_ (\r → rsAdmit r `shouldBe` AdmitStopping) (Map.elems (stRoles state))

  it "stops the logical role alone for a logical failure after boot, leaving a healthy presentation role running" $ do
    let (state, answers, effects) = runAll (ready <> [LatchFailure Gameplay (failure Gameplay OnUpdate "boom") []]) both
    stStopping state `shouldBe` False
    last answers `shouldBe` Latched True
    effects `shouldBe` [StopRoles [Gameplay]]
    phasesOf' state `shouldBe` (Just Stopping, Just Running)
    roleAdmit Gameplay state `shouldBe` AdmitStopping
    roleAdmit Presentation state `shouldBe` AdmitOpen
    statusStopping (statusOf state) `shouldBe` False

  it "ends the whole session for a presentation failure, whenever it comes" $ do
    let (state, _, effects) = runAll (ready <> [LatchFailure Presentation (failure Presentation OnUpdate "ui") []]) both
    stStopping state `shouldBe` True
    effects `shouldBe` [StopRoles [Gameplay, Presentation]]

  it "ends the whole session for the failure of a session's only role" $ do
    let events = [Validated g0, AdmissionComplete, InitSucceeded g0, LatchFailure Gameplay (failure Gameplay OnUpdate "boom") []]
    stStopping (applied events gameplayOnly) `shouldBe` True
    stStopping (applied [Validated p0, AdmissionComplete, InitSucceeded p0, LatchFailure Presentation (failure Presentation OnUpdate "ui") []] presentationOnly) `shouldBe` True

  it "ends a previously healthy presentation role when the logical role's cleanup then fails" $ do
    let (state, _, effects) =
          runAll
            ( ready
                <> [ LatchFailure Gameplay (failure Gameplay OnUpdate "boom") []
                   , EngineFault (Just Gameplay) (engineEntry CleanupFailure (Just Gameplay) OnCleanup "release failed")
                   ]
            )
            both
    stStopping state `shouldBe` True
    -- the logical role was reported once; the second report names only the role not yet stopping
    effects `shouldBe` [StopRoles [Gameplay], StopRoles [Presentation]]
    phaseOfRole Presentation state `shouldBe` Just Stopping

  it "never returns a failed role to ready or running, and keeps its first failure through every later event" $ do
    let first = failure Gameplay OnInit "first"
        state =
          applied
            ( validated
                <> [ LatchFailure Gameplay first []
                   , InitSucceeded g0
                   , InitSucceeded p0
                   , LatchFailure Gameplay (failure Gameplay OnShutdown "second") []
                   , Stop StopInterrupt
                   ]
            )
            both
    roleFailure' Gameplay state `shouldBe` Just first
    phaseOfRole Gameplay state `shouldBe` Just Stopping
    phaseOfRole Presentation state `shouldBe` Just Stopping

  it "answers whether a failure was the first of its role" $
    answersOf
      [ LatchFailure Gameplay (failure Gameplay OnInit "a") []
      , LatchFailure Gameplay (failure Gameplay OnShutdown "b") []
      ]
      both
      `shouldBe` [Latched True, Latched False]

  it "accounts the failure and what else failed as it ended in the engine report, the first failure as its primary" $ do
    let entry = engineEntry CleanupFailure (Just Gameplay) OnShutdown "shutdown failed"
        state = applied [LatchFailure Gameplay (failure Gameplay OnUpdate "boom") [entry, entry]] both
    reportAccounted (stEngine state) `shouldBe` 3
    erPrimary (stEngine state) `shouldBe` Just (engineEntry LuaError (Just Gameplay) OnUpdate "boom")
    erSecondary (stEngine state) `shouldBe` [entry, entry]

  it "accounts a later failure of another role as a secondary, never replacing the primary" $ do
    let state = applied [LatchFailure Gameplay (failure Gameplay OnInit "first") [], LatchFailure Presentation (failure Presentation OnInit "second") []] both
    erPrimary (stEngine state) `shouldBe` Just (engineEntry LuaError (Just Gameplay) OnInit "first")
    map eeMessage (erSecondary (stEngine state)) `shouldBe` ["second"]

  it "accounts what else failed as an instance ended in the report without latching a second failure" $ do
    let entry = engineEntry CleanupFailure (Just Gameplay) OnShutdown "shutdown failed"
        state = applied [LatchFailure Gameplay (failure Gameplay OnUpdate "boom") [], EndingAccounted Gameplay [entry]] both
    answersOf [LatchFailure Gameplay (failure Gameplay OnUpdate "boom") [], EndingAccounted Gameplay [entry]] both `shouldBe` [Latched True, Done]
    erSecondary (stEngine state) `shouldBe` [entry]
    reportAccounted (stEngine state) `shouldBe` 2
    roleFailure' Gameplay state `shouldBe` Just (failure Gameplay OnUpdate "boom")

  it "accounts every engine fault, keeping the first as the primary, sixteen summaries and the count of the rest" $ do
    let faults = [EngineFault (Just Gameplay) (engineEntry CleanupFailure (Just Gameplay) OnCleanup (Text.pack ("cleanup " <> show n))) | n ← [1 .. 40 ∷ Int]]
        state = applied faults both
        report' = stEngine state
    fmap eeMessage (erPrimary report') `shouldBe` Just "cleanup 1"
    length (erSecondary report') `shouldBe` 16
    erOmitted report' `shouldBe` 23
    reportAccounted report' `shouldBe` 40
    stStopping state `shouldBe` True

roleFailure' ∷ Role → SessionState → Maybe RoleFailure
roleFailure' role state = rsFailure =<< Map.lookup role (stRoles state)

-- The ranking of outcomes ----------------------------------------------------------------------------

ranking ∷ Spec
ranking = describe "the outcome" $ do
  it "ranks failure over interruption over a normal quit over success, whatever the order" $ do
    outVerdict (outcomeOf both) `shouldBe` VerdictSuccess
    outVerdict (outcomeOf (applied [Stop StopQuit] both)) `shouldBe` VerdictSuccess
    outVerdict (outcomeOf (applied [Stop StopInterrupt] both)) `shouldBe` VerdictInterrupted
    outVerdict (outcomeOf (applied [Stop StopQuit, Stop StopInterrupt] both)) `shouldBe` VerdictInterrupted
    outVerdict (outcomeOf (applied [Stop StopInterrupt, Stop StopQuit] both)) `shouldBe` VerdictInterrupted
    let failed = LatchFailure Gameplay (failure Gameplay OnInit "x") []
    outVerdict (outcomeOf (applied [failed, Stop StopQuit] both)) `shouldBe` VerdictFailure
    outVerdict (outcomeOf (applied [Stop StopQuit, failed] both)) `shouldBe` VerdictFailure
    outVerdict (outcomeOf (applied [Stop StopInterrupt, failed, Stop StopQuit] both)) `shouldBe` VerdictFailure

  it "treats an engine failure and the terminal failure as failures that a later stop cannot erase" $ do
    let engine = EngineFault Nothing (engineEntry HostFailure Nothing OnEngine "a provider failed")
    outVerdict (outcomeOf (applied [engine, Stop StopQuit] both)) `shouldBe` VerdictFailure
    let terminal = Terminal (newRoleFailure StateUnavailable OnUpdate Presentation "state is unavailable")
    outVerdict (outcomeOf (applied [Stop StopInterrupt, terminal] both)) `shouldBe` VerdictFailure

  it "latches the terminal failure once, stops the whole session and is not an ordinary role failure" $ do
    let terminal = Terminal (newRoleFailure StateUnavailable OnUpdate Presentation "state is unavailable")
        (state, answers, effects) = runAll [terminal, terminal] both
    answers `shouldBe` [Latched True, Latched False]
    effects `shouldBe` [StopRoles [Gameplay, Presentation]]
    stStopping state `shouldBe` True
    outFailures (outcomeOf state) `shouldBe` []
    outTerminal (outcomeOf state) `shouldSatisfy` isJust

  it "lists each failed role's first failure in the order they latched, the primary first" $ do
    let g = failure Gameplay OnInit "g"
        p = failure Presentation OnInit "p"
    outFailures (outcomeOf (applied [LatchFailure Presentation p [], LatchFailure Gameplay g []] both)) `shouldBe` [p, g]

  it "is idempotent: a second stop reports no owner again" $ do
    effectsOf [Stop StopQuit, Stop StopQuit, Stop StopInterrupt] both `shouldBe` [StopRoles [Gameplay, Presentation]]

  it "is not retired until every role has been reported retired, and each only by its own event" $ do
    let stopped = applied [Stop StopQuit] both
    outRetired (outcomeOf stopped) `shouldBe` False
    outRetired (outcomeOf (applied [RoleRetired Gameplay] stopped)) `shouldBe` False
    let done = applied [RoleRetired Gameplay, RoleRetired Presentation] stopped
    outRetired (outcomeOf done) `shouldBe` True
    phasesOf' done `shouldBe` (Just Retired, Just Retired)
    roleAdmit Gameplay done `shouldBe` AdmitClosed

  it "unwinds a composition without recording a quit or a failure" $ do
    let (state, _, effects) = runAll [Unwind] both
    effects `shouldBe` [StopRoles [Gameplay, Presentation]]
    stQuit state `shouldBe` False
    stInterrupt state `shouldBe` False
    outVerdict (outcomeOf state) `shouldBe` VerdictSuccess
    dispatchDecision state `shouldBe` Just False

  it "publishes an absent role as absent, and failure beside stopping as separate facts" $ do
    let status = statusOf gameplayOnly
    statusPresentation status `shouldBe` Nothing
    fmap rolePhase (statusGameplay status) `shouldBe` Just Starting
    let failedOne = statusOf (applied (validated <> [InitSucceeded g0, InitSucceeded p0, LatchFailure Gameplay (failure Gameplay OnUpdate "x") []]) both)
    statusStopping failedOne `shouldBe` False
    fmap roleFailed (statusGameplay failedOne) `shouldBe` Just True
    fmap roleFailed (statusPresentation failedOne) `shouldBe` Just False

-- Admission accounting -----------------------------------------------------------------------------------------

admission ∷ Spec
admission = describe "admission" $ do
  it "takes an intent for a role that takes work, and gives it back when tracked or abandoned" $ do
    let (state, answers, _) = runAll [Intend Gameplay, Intend Gameplay, Tracked Gameplay, Abandoned Gameplay] both
    answers `shouldBe` [Done, Done, Done, Done]
    (rsIntents <$> Map.lookup Gameplay (stRoles state)) `shouldBe` Just 0

  it "refuses an intent from a role that has stopped taking work, and from a stopped session" $ do
    answersOf [Stop StopQuit, Intend Gameplay] both `shouldBe` [Done, Refused]
    answersOf [LatchFailure Gameplay (failure Gameplay OnUpdate "x") [], Intend Gameplay, Intend Presentation] (applied (validated <> [InitSucceeded g0, InitSucceeded p0]) both)
      `shouldBe` [Latched True, Refused, Done]

  it "never lets the count of intents go below zero" $ do
    let state = applied [Tracked Gameplay, Abandoned Gameplay] both
    (rsIntents <$> Map.lookup Gameplay (stRoles state)) `shouldBe` Just 0

-- Every order ------------------------------------------------------------------------------------------------------

invariants ∷ Spec
invariants = describe "every order of events" $ do
  it "keeps the gates, the phases, the first failure and the ranking, after every step of every sequence of five events" $
    [(events, broken) | events ← sequencesOf menu 5, let broken = violations events, not (null broken)] `shouldBe` []
  it "reports each owner to be stopped at most once, whatever happens" $
    mapM_
      ( \events → do
          let (_, _, effects) = runAll events both
              reported = concat [roles | StopRoles roles ← effects]
          reported `shouldBe` Set.toList (Set.fromList reported)
      )
      (sequencesOf menu 5)
  where
    menu =
      [ Validated g0
      , Validated p0
      , AdmissionComplete
      , InitSucceeded g0
      , InitSucceeded p0
      , LatchFailure Gameplay (failure Gameplay OnUpdate "g") []
      , LatchFailure Presentation (failure Presentation OnUpdate "p") []
      , Stop StopQuit
      , Stop StopInterrupt
      ]

-- | Every sequence of up to this many events from a menu.
sequencesOf ∷ [a] → Int → [[a]]
sequencesOf menu n = concat [sequencesLength menu k | k ← [0 .. n]]
  where
    sequencesLength _ 0 = [[]]
    sequencesLength items k = [item : rest | item ← items, rest ← sequencesLength items (k - 1)]

-- | The invariants broken anywhere along one sequence: empty when it keeps them all.
violations ∷ [Event] → [String]
violations = go both
  where
    go _ [] = []
    go state (event : rest) =
      let (next, _, _) = step event state
       in [show event <> ": " <> why | why ← check state next] <> go next rest
    check prior afterwards =
      concat
        [ -- each gate is decided once
          [ "the dispatch gate changed after it was decided" | stDispatch prior /= DispatchClosed, stDispatch afterwards /= stDispatch prior ]
        , [ "the start gate changed after it was decided" | stStart prior /= StartClosed, stStart afterwards /= stStart prior ]
        , -- a stopping session has a decided start gate and takes no work
          [ "a stopping session left the start gate closed" | stStopping afterwards, stStart afterwards == StartClosed ]
        , [ "a stopping session still takes work" | stStopping afterwards, any ((== AdmitOpen) . rsAdmit) (Map.elems (stRoles afterwards)) ]
        , -- the start gate opens only for a session with nothing failed or stopped, and only after dispatch
          [ "the start gate opened after a stop" | opening, stStopping prior ]
        , [ "the start gate opened after a failure" | opening, any (isJust . rsFailure) (Map.elems (stRoles prior)) ]
        , [ "the start gate opened prior the dispatch gate" | opening, stDispatch afterwards /= DispatchOpen ]
        , -- a failed role is never ready or running, and keeps its first failure
          [ "a failed role is ready or running" | found ← Map.elems (stRoles afterwards), isJust (rsFailure found), rsPhase found `elem` [Ready, Running] ]
        , [ "a role's first failure changed" | role ← [Gameplay, Presentation], Just first ← [Map.lookup role (stRoles prior) >>= rsFailure], (Map.lookup role (stRoles afterwards) >>= rsFailure) /= Just first ]
        , -- the ranking never goes down
          [ "the verdict went down" | outVerdict (outcomeOf afterwards) < outVerdict (outcomeOf prior) ]
        , -- a failure prior the start gate opened ends the whole session
          [ "a failure prior the start gate opened did not stop the session" | any (isJust . rsFailure) (Map.elems (stRoles afterwards)), stStart afterwards /= StartOpen, not (stStopping afterwards) ]
        ]
      where
        opening = stStart afterwards == StartOpen && stStart prior /= StartOpen

-- The failure schema ---------------------------------------------------------------------------------------------------

failures ∷ Spec
failures = describe "the failure schema" $ do
  it "cuts text at a code point, ends a cut in a visible marker, and never exceeds the bound" $ do
    truncateText 10 "short" `shouldBe` "short"
    truncateText 10 (Text.replicate 20 "a") `shouldBe` "aaaaaaa..."
    -- a three-byte code point is kept while it fits before the marker, and cut whole when it does not
    truncateText 8 "ab\x20AC\x20AC\x20AC" `shouldBe` "ab\x20AC..."
    truncateText 7 "ab\x20AC\x20AC\x20AC" `shouldBe` "ab..."
    utf8Bytes (truncateText 8 "ab\x20AC\x20AC\x20AC") `shouldSatisfy` (<= 8)
    truncateText 3 "abcdef" `shouldBe` "..."
    truncateText 2 "abcdef" `shouldBe` "ab"
    truncateText 0 "abcdef" `shouldBe` ""

  it "keeps every multibyte text within its bound at every length, never splitting a code point" $
    mapM_
      ( \bound → do
          let cut = truncateText bound (Text.pack (concat (replicate 40 "a\x00E9\x20AC\x1F600")))
          utf8Bytes cut `shouldSatisfy` (<= bound)
          Text.unpack cut `shouldSatisfy` all (/= '\xFFFD')
      )
      [0 .. 64]

  it "holds a whole record to the record bound by shortening the traceback, then the message, then the path" $ do
    let big = Text.replicate 30000 "x"
        record =
          (newRoleFailure LuaError OnUpdate Gameplay big)
            { rfContent = Just "game"
            , rfInstance = Just (Text.replicate 400 "i")
            , rfPath = Just (Text.replicate 4000 "p")
            , rfTraceback = Just big
            }
        -- a record bound that holds the message and the traceback and nothing beside them, so the identity,
        -- the path and the words must take their room from the traceback
        tight = failureLimitsOf (bytesOf [(RoleFailureRecordBytes, 10240)])
        bounded = boundFailure tight record
    recordBytes (boundFailure limits record) `shouldSatisfy` (<= limitRecord limits)
    recordBytes bounded `shouldSatisfy` (<= limitRecord tight)
    utf8Bytes (rfMessage bounded) `shouldBe` limitMessage tight
    maybe 0 utf8Bytes (rfTraceback bounded) `shouldSatisfy` (< limitTraceback tight)
    maybe 0 utf8Bytes (rfInstance bounded) `shouldSatisfy` (<= limitInstance tight)
    rfCode bounded `shouldBe` LuaError
    rfRole bounded `shouldBe` Gameplay
    rfStage bounded `shouldBe` OnUpdate
    rfContent bounded `shouldBe` Just "game"
    Text.isSuffixOf "..." (rfMessage bounded) `shouldBe` True

  it "spells the schema's codes, stages and roles as approved" $ do
    map codeWord [minBound .. maxBound]
      `shouldBe` ["lua_error", "module_error", "required_request", "host_failure", "cleanup_failure", "state_unavailable"]
    map stageWord [minBound .. maxBound]
      `shouldBe` ["module", "init", "update", "shutdown", "request", "cleanup", "engine"]
    map roleWord [Gameplay, Presentation] `shouldBe` ["gameplay", "presentation"]

-- The engine report ---------------------------------------------------------------------------------------------------------

report ∷ Spec
report = describe "the engine report" $ do
  it "keeps the first failure as primary, at most sixteen secondary summaries, and counts the rest" $ do
    let entries = [engineEntry CleanupFailure (Just Gameplay) OnCleanup (Text.pack ("cleanup " <> show n)) | n ← [1 .. 40 ∷ Int]]
        built = foldl' (flip (noteEngine limits)) emptyReport entries
    erPrimary built `shouldBe` listToMaybe entries
    length (erSecondary built) `shouldBe` 16
    erOmitted built `shouldBe` 23
    reportAccounted built `shouldBe` 40
    map eeMessage (erSecondary built) `shouldBe` map eeMessage (take 16 (drop 1 entries))

  it "cuts a secondary summary to its bound and the primary so that the report stays within its own" $ do
    let long = Text.replicate 10000 "z"
        built = foldl' (flip (noteEngine limits)) emptyReport [engineEntry HostFailure Nothing OnEngine long | _ ← [1 .. 17 ∷ Int]]
        total = maybe 0 (utf8Bytes . eeMessage) (erPrimary built) + sum (map (utf8Bytes . eeMessage) (erSecondary built))
    total `shouldSatisfy` (<= limitReport limits)
    mapM_ (\entry → utf8Bytes (eeMessage entry) `shouldSatisfy` (<= limitSummary limits)) (erSecondary built)
    reportAccounted built `shouldBe` 17

-- Pacing ---------------------------------------------------------------------------------------------------------------------

pacing ∷ Spec
pacing = describe "pacing" $ do
  it "schedules tick n n tick durations after the origin, exactly, with no drift" $ do
    let start = scheduleAt 0 1000 250
        dues = take 5 (iterate' start)
    map (scDue) dues `shouldBe` map instant [1250, 1500, 1750, 2000, 2250]
    map scGranted dues `shouldBe` [0 .. 4]

  it "numbers the ticks from one, and refuses the tick past the largest a Lua integer holds" $ do
    nextTickNumber (scheduleAt 0 0 1) `shouldBe` Right 1
    let nearly = scheduleAt (luaTickCeiling - 1) 0 1
    nextTickNumber nearly `shouldBe` Right luaTickCeiling
    (afterGrant nearly >>= nextTickNumber) `shouldBe` Left TickCeiling
    nextTickNumber (scheduleAt luaTickCeiling 0 1) `shouldBe` Left TickCeiling

  it "refuses a due time the clock cannot count, before and after the schedule starts, without wrapping" $ do
    initialDeadline (instant (top - 5)) (duration 5) `shouldBe` Right (instant top)
    initialDeadline (instant (top - 4)) (duration 5) `shouldBe` Left DeadlineOverflow
    startSchedule 0 (instant (top - 4)) (duration 5) `shouldBe` Left DeadlineOverflow
    let start = scheduleAt 0 (top - 9) 5
    scDue start `shouldBe` instant (top - 4)
    (afterGrant start >>= afterGrant) `shouldBe` Left DeadlineOverflow
  where
    iterate' schedule = schedule : either (const []) iterate' (afterGrant schedule)

duration ∷ Integer → Duration
duration n = either (error . show) id (durationFromNanoseconds RequirePositive n)

instant ∷ Integer → Instant
instant n = scriptedInstant (either (error . show) id (durationFromNanoseconds AllowZero n))

-- | The largest instant the clock counts.
top ∷ Integer
top = toInteger (maxBound ∷ Word64)

-- | A schedule that starts at this origin (nanoseconds) with this tick, from this base.
scheduleAt ∷ Word64 → Integer → Integer → Schedule
scheduleAt base origin tick = either (error . show) id (startSchedule base (instant origin) (duration tick))

-- | A permutation of a short list, for the order-independence examples.
permutations' ∷ [a] → [[a]]
permutations' [] = [[]]
permutations' xs = [x : rest | (x, others) ← picks xs, rest ← permutations' others]
  where
    picks [] = []
    picks (y : ys) = (y, ys) : [(z, y : zs) | (z, zs) ← picks ys]
