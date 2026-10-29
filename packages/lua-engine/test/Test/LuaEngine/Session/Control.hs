{-# LANGUAGE OverloadedStrings #-}

-- | What the coordinator hands a facade (LFE-26), checked without a VM: the conversion of the session's own
-- status and failure records into the status record a script is shown, and the failure the unavailable-state
-- guard latches. A record the running Lua may never get to read (a fatal engine failure, a module's, a final
-- phase) is converted and checked here, and the examples of "Test.LuaEngine.Session.Api" check what a script
-- does read.
--
-- Every expectation is written independently of the conversion it checks: the words of the schema are
-- spelled out, the record is built field by field, and the bounds are the profile's own numbers.
module Test.LuaEngine.Session.Control (spec) where

import qualified Data.ByteString as ByteString
import Data.Maybe (catMaybes)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.LuaEngine.Facade
  ( FailureSample (..)
  , RoleSample (..)
  , TerminalContext (..)
  , TerminalStage (..)
  , failureValue
  , stateUnavailableMessage
  , statusValue
  )
import Hetoimasia.LuaEngine.Manifest (Role (..))
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.LuaEngine.Session.Control
import Hetoimasia.LuaEngine.Session.Failure
import Hetoimasia.LuaEngine.Session.State
import Hetoimasia.Scripting.Lua.Value (Value (VBoolean, VRecord, VText))
import Test.Hspec

spec ∷ Spec
spec = describe "what the coordinator hands a facade" $ do
  vocabulary
  statuses
  failures
  bounds
  terminal

-- The schema's words ---------------------------------------------------------------------------------------------

vocabulary ∷ Spec
vocabulary = describe "the words of the schema" $ do
  it "spells the five phases, the six codes, the seven stages and the two roles exactly as the accepted schema does" $ do
    map phaseWord [minBound .. maxBound] `shouldBe` ["starting", "ready", "running", "stopping", "retired"]
    map codeWord [minBound .. maxBound] `shouldBe` ["lua_error", "module_error", "required_request", "host_failure", "cleanup_failure", "state_unavailable"]
    map stageWord [minBound .. maxBound] `shouldBe` ["module", "init", "update", "shutdown", "request", "cleanup", "engine"]
    map roleWord [Gameplay, Presentation] `shouldBe` ["gameplay", "presentation"]

-- Statuses -----------------------------------------------------------------------------------------------------------

-- | Every role the coordinator can publish: absent, or present with a historical fact and a phase; a failed role
-- is stopping or retired, never ready or running.
roles ∷ [Maybe RoleStatus]
roles =
  Nothing
    : [ Just (RoleStatus initialized phase (failure /= Nothing) failure)
      | initialized ← [False, True]
      , phase ← [minBound .. maxBound]
      , failure ← [Nothing, Just failureA]
      , failure == Nothing || phase `elem` [Stopping, Retired]
      ]

failureA ∷ RoleFailure
failureA = (newRoleFailure LuaError OnUpdate Gameplay "boom") {rfContent = Just "modules-test", rfInstance = Just "inst-1", rfTraceback = Just "stack traceback"}

-- | What a script must be shown for a role, written out field by field.
expectedRole ∷ Maybe RoleStatus → Value
expectedRole = \case
  Nothing → VRecord [("present", VBoolean False)]
  Just role →
    VRecord $
      [ ("present", VBoolean True)
      , ("initialized", VBoolean (roleInitialized role))
      , ("phase", VText (spelled (rolePhase role)))
      , ("failed", VBoolean (roleFailed role))
      ]
        <> [ ( "failure"
             , VRecord $
                 [ ("code", VText "lua_error")
                 , ("message", VText "boom")
                 , ("role", VText "gameplay")
                 , ("stage", VText "update")
                 , ("content_id", VText "modules-test")
                 , ("instance_id", VText "inst-1")
                 , ("traceback", VText "stack traceback")
                 ]
             )
           | Just _ ← [roleFailure role]
           ]
  where
    spelled = \case
      Starting → "starting"
      Ready → "ready"
      Running → "running"
      Stopping → "stopping"
      Retired → "retired"

statuses ∷ Spec
statuses = describe "a status" $ do
  it "converts every combination of the whole-session flag and each role's presence, history, phase and failure, with nothing added and nothing left out" $ do
    let combinations = [SessionStatus stopping gameplay presentation False | stopping ← [False, True], gameplay ← roles, presentation ← roles]
    length combinations `shouldBe` (2 * length roles * length roles)
    mapM_
      ( \status →
          statusValue (statusSample status)
            `shouldBe` VRecord
              [ ("stopping", VBoolean (statusStopping status))
              , ("gameplay", expectedRole (statusGameplay status))
              , ("presentation", expectedRole (statusPresentation status))
              ]
      )
      combinations
  it "does not show that the guard has latched a terminal failure: it is not a field of the schema, and the whole-session flag carries the stop" $
    statusValue (statusSample (SessionStatus True Nothing Nothing True))
      `shouldBe` VRecord [("stopping", VBoolean True), ("gameplay", VRecord [("present", VBoolean False)]), ("presentation", VRecord [("present", VBoolean False)])]
  it "keeps a retired role's failure and history as they were when it was stopping" $ do
    let failed phase = RoleStatus True phase True (Just failureA)
    roleSample (failed Retired) `shouldBe` (roleSample (failed Stopping)) {samplePhase = "retired"}

-- Failures -------------------------------------------------------------------------------------------------------------

-- | Every code at every stage, with what an instance, a module and the engine itself each know.
failures ∷ Spec
failures = describe "a failure" $ do
  it "keeps the code, message, role and stage in the schema's words, and shows each optional field only when it is known" $ do
    let known = (newRoleFailure RequiredRequest OnRequest Presentation "no") {rfContent = Just "game", rfInstance = Just "inst-9", rfPath = Just "lua/a.lua", rfTraceback = Just "tb"}
    failureSample known
      `shouldBe` FailureSample "required_request" "no" "presentation" "request" (Just "game") (Just "inst-9") (Just "lua/a.lua") (Just "tb")
    failureValue (failureSample known)
      `shouldBe` VRecord
        [ ("code", VText "required_request")
        , ("message", VText "no")
        , ("role", VText "presentation")
        , ("stage", VText "request")
        , ("content_id", VText "game")
        , ("instance_id", VText "inst-9")
        , ("path", VText "lua/a.lua")
        , ("traceback", VText "tb")
        ]
  it "shows a module's failure with its content and path and no instance, and a fatal engine failure with nothing but its four fields: no instance is invented" $ do
    let moduleOnly = (newRoleFailure ModuleError OnModule Gameplay "does not evaluate") {rfContent = Just "game", rfPath = Just "lua/main.lua", rfTraceback = Just "module traceback"}
        fatal = newRoleFailure HostFailure OnEngine Presentation "a provider failed"
    failureValue (failureSample moduleOnly)
      `shouldBe` VRecord
        [ ("code", VText "module_error")
        , ("message", VText "does not evaluate")
        , ("role", VText "gameplay")
        , ("stage", VText "module")
        , ("content_id", VText "game")
        , ("path", VText "lua/main.lua")
        , ("traceback", VText "module traceback")
        ]
    failureValue (failureSample fatal)
      `shouldBe` VRecord [("code", VText "host_failure"), ("message", VText "a provider failed"), ("role", VText "presentation"), ("stage", VText "engine")]
    -- a role whose first failure was fatal is shown failed, with that failure, though no hook may ever run to read it
    statusValue (statusSample (SessionStatus True Nothing (Just (RoleStatus False Stopping True (Just fatal))) False))
      `shouldBe` VRecord
        [ ("stopping", VBoolean True)
        , ("gameplay", VRecord [("present", VBoolean False)])
        ,
          ( "presentation"
          , VRecord
              [ ("present", VBoolean True)
              , ("initialized", VBoolean False)
              , ("phase", VText "stopping")
              , ("failed", VBoolean True)
              , ("failure", VRecord [("code", VText "host_failure"), ("message", VText "a provider failed"), ("role", VText "presentation"), ("stage", VText "engine")])
              ]
          )
        ]
  it "spells every code and every stage, with the role, in the schema's words" $
    mapM_
      ( \(code, stage, role) → do
          let sample = failureSample (newRoleFailure code stage role "m")
          (sfCode sample, sfStage sample, sfRole sample) `shouldBe` (codeWord code, stageWord stage, roleWord role)
      )
      [(code, stage, role) | code ← [minBound .. maxBound], stage ← [minBound .. maxBound], role ← [Gameplay, Presentation]]

-- Bounds -----------------------------------------------------------------------------------------------------------------

bounds ∷ Spec
bounds = describe "the bounds of a failure the coordinator publishes" $ do
  let limits = failureLimitsOf fixedM1Profile
      oversized =
        (newRoleFailure LuaError OnUpdate Gameplay (Text.replicate 5000 "\233"))
          { rfContent = Just (Text.replicate 300 "c")
          , rfInstance = Just (Text.replicate 500 "\8364")
          , rfPath = Just (Text.replicate 9000 "p")
          , rfTraceback = Just (Text.replicate 20000 "\128512")
          }
      bounded = boundFailure limits oversized
      sampled = failureSample bounded
      bytes = ByteString.length . Text.encodeUtf8
  it "shows the bounded record the state took in, every text within its own bound and the whole within 16 KiB, cut visibly at a character" $ do
    bytes (sfMessage sampled) `shouldSatisfy` (<= 2048)
    maybe 0 bytes (sfTraceback sampled) `shouldSatisfy` (<= 8192)
    maybe 0 bytes (sfInstanceId sampled) `shouldSatisfy` (<= 128)
    maybe 0 bytes (sfContentId sampled) `shouldSatisfy` (<= 64)
    recordBytes bounded `shouldSatisfy` (<= 16384)
    -- the message is a whole number of two-byte characters and the three-byte marker
    sfMessage sampled `shouldSatisfy` Text.isSuffixOf "..."
    Text.dropEnd 3 (sfMessage sampled) `shouldSatisfy` (`Text.isPrefixOf` oversizedMessage)
    Text.all (== '\233') (Text.dropEnd 3 (sfMessage sampled)) `shouldBe` True
  it "keeps the identity and the schema's words whole while the record is shortened, and drops no field it knew" $ do
    (sfCode sampled, sfRole sampled, sfStage sampled) `shouldBe` ("lua_error", "gameplay", "update")
    sfInstanceId sampled `shouldSatisfy` (/= Nothing)
    sfContentId sampled `shouldSatisfy` (/= Nothing)
    case failureValue sampled of
      VRecord fields → do
        map fst fields `shouldSatisfy` all (`elem` ["code", "message", "role", "stage", "content_id", "instance_id", "path", "traceback"])
        map fst fields `shouldSatisfy` (\names → all (`elem` names) ["code", "message", "role", "stage"])
      other → expectationFailure ("expected a record, found " <> show other)
  it "is held within the copied-value ceilings: one level below the role, three deep and a few dozen elements" $ do
    let status = statusValue (statusSample (SessionStatus True (Just (RoleStatus True Retired True (Just bounded))) (Just (RoleStatus True Retired True (Just bounded))) False))
    depth status `shouldSatisfy` (<= 8)
    elements status `shouldSatisfy` (<= 65536)
  where
    oversizedMessage = Text.replicate 5000 "\233"
    depth = \case
      VRecord fields → 1 + maximum (0 : map (depth . snd) fields)
      _ → 0 ∷ Int
    elements = \case
      VRecord fields → length fields + sum (map (elements . snd) fields)
      _ → 0 ∷ Int

-- The guard's failure ----------------------------------------------------------------------------------------------

terminal ∷ Spec
terminal = describe "the failure the unavailable-state guard latches" $ do
  it "carries code state_unavailable, the fixed message, the executing role and stage, and names a content and an instance only when an instance was running" $ do
    terminalFailure (TerminalContext Presentation TerminalInit (Just "game") (Just "inst-2") Nothing)
      `shouldBe` (newRoleFailure StateUnavailable OnInit Presentation stateUnavailableMessage) {rfContent = Just "game", rfInstance = Just "inst-2"}
    terminalFailure (TerminalContext Gameplay TerminalUpdate (Just "game") (Just "inst-1") Nothing)
      `shouldBe` (newRoleFailure StateUnavailable OnUpdate Gameplay stateUnavailableMessage) {rfContent = Just "game", rfInstance = Just "inst-1"}
    terminalFailure (TerminalContext Gameplay TerminalShutdown (Just "game") (Just "inst-1") Nothing)
      `shouldBe` (newRoleFailure StateUnavailable OnShutdown Gameplay stateUnavailableMessage) {rfContent = Just "game", rfInstance = Just "inst-1"}
  it "invents no instance for module-only work, names the module's content and path when the loader knows them, and attributes nothing a facade did not know" $ do
    terminalFailure (TerminalContext Gameplay TerminalModule (Just "game") Nothing (Just "lua/dep.lua"))
      `shouldBe` (newRoleFailure StateUnavailable OnModule Gameplay stateUnavailableMessage) {rfContent = Just "game", rfPath = Just "lua/dep.lua"}
    terminalFailure (TerminalContext Presentation TerminalModule Nothing Nothing Nothing)
      `shouldBe` newRoleFailure StateUnavailable OnModule Presentation stateUnavailableMessage
  it "is the fixed phrase, once spelled, and within every bound the state applies" $ do
    stateUnavailableMessage `shouldBe` "state service not available in this milestone"
    let failure = terminalFailure (TerminalContext Presentation TerminalInit (Just "game") (Just "inst-2") Nothing)
    boundFailure (failureLimitsOf fixedM1Profile) failure `shouldBe` failure
    catMaybes [rfTraceback failure, rfPath failure] `shouldBe` []
