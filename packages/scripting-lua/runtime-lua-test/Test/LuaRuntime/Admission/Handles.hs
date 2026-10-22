-- | Whose a handle is: opaque, owned by the instance that asked, refused as an ordinary Lua error
-- before any work when it is another instance's, spent, mistyped or of another kind, and never
-- waited on where waiting is not allowed; and ending one instance leaves another's requests alone.
module Test.LuaRuntime.Admission.Handles (spec) where

import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Owner (ModuleSource)
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Admission.Support
import Test.LuaRuntime.Instance.Support (awaitPhase, awaitSettled, expectControl)
import Test.LuaRuntime.Request.Support (answerResult, awaitCancelled, awaitDiagnostic, diagnostics, finishWork, submissions)
import Test.LuaRuntime.Support (bounded, requiredPolicy, withBoundary)

-- | An owner of these modules on elapsed time.
arrival ∷ AFix → [ModuleSource] → LuaRuntime → Text → IO ScheduledOwner
arrival fixture modules runtime label =
  startAdmitting fixture runtime label modules aConfig (admissionGrant fixture 8 SettleOnArrival) requiredPolicy

spec ∷ Spec
spec = describe "handles" $ do
  it "belong to the instance that asked: another instance of the same VM is refused before any work, and its refusal is an ordinary error" $ bounded $ do
    fixture ← newAFix 4
    withBoundary $ \_ runtime → settleAll fixture $ do
      owner ← arrival fixture [admitter] runtime "foreign"
      admitAdmitter fixture owner "i" "admitter"
      admitAdmitter fixture owner "j" "admitter"
      acommand fixture owner "i" "start" "a"
      awaitNote fixture "cmd start a started"
      acommand fixture owner "i" "stash" "a"
      awaitNote fixture "cmd stash a stashed"
      acommand fixture owner "j" "pother" "x"
      line ← lineStarting fixture "cmd pother x "
      (line `shouldSatisfy` Text.isInfixOf "error ad.take: ") >> (line `shouldSatisfy` Text.isInfixOf "ended")
      acommand fixture owner "j" "pwait_other" "x"
      waited ← lineStarting fixture "cmd pwait_other x "
      waited `shouldSatisfy` Text.isInfixOf "error ad.wait: "
      -- The refusal did nothing: j goes on, and i still holds its request.
      acommand fixture owner "i" "ready" "a"
      awaitNote fixture "cmd ready a false"
      awaitPhase (afBase fixture) owner "j" Active
      submissions (afFake fixture) >>= (`shouldBe` 1)

  it "are spent by the take of the terminal result: the handle names nothing afterwards" $ bounded $ do
    fixture ← newAFix 4
    withBoundary $ \_ runtime → settleAll fixture $ do
      owner ← arrival fixture [admitter] runtime "spent"
      admitAdmitter fixture owner "i" "admitter"
      acommand fixture owner "i" "start" "a"
      awaitNote fixture "cmd start a started"
      -- A pending take consumes nothing, a terminal one exactly once.
      acommand fixture owner "i" "take" "a"
      awaitNote fixture "cmd take a {status=pending}"
      acommand fixture owner "i" "ready" "a"
      awaitNote fixture "cmd ready a false"
      _ ← answerResult (afFake fixture) 0 8
      acommand fixture owner "i" "ready" "a"
      awaitNote fixture "cmd ready a true"
      acommand fixture owner "i" "take" "a"
      awaitNote fixture "cmd take a {status=success,value={v=8}}"
      acommand fixture owner "i" "ptake" "a"
      line ← lineStarting fixture "cmd ptake a "
      line `shouldSatisfy` Text.isInfixOf "error ad.take: "
      acommand fixture owner "i" "pready" "a"
      ready ← lineStarting fixture "cmd pready a "
      ready `shouldSatisfy` Text.isInfixOf "error ad.ready: "
      acommand fixture owner "i" "pcancel" "a"
      cancelled ← lineStarting fixture "cmd pcancel a "
      cancelled `shouldSatisfy` Text.isInfixOf "error ad.cancel: "

  it "refuse the wrong number, type and kind of argument as ordinary errors that cost nothing" $ bounded $ do
    fixture ← newAFix 4
    withBoundary $ \_ runtime → settleAll fixture $ do
      owner ← arrival fixture [admitter] runtime "shapes"
      admitAdmitter fixture owner "i" "admitter"
      acommand fixture owner "i" "start" "a"
      awaitNote fixture "cmd start a started"
      acommand fixture owner "i" "pbad" "a"
      line ← lineStarting fixture "cmd pbad a "
      let parts = Text.splitOn " | " (Text.drop (Text.length "cmd pbad a ") line)
      length parts `shouldBe` 3
      parts `shouldSatisfy` all (Text.isInfixOf "ad.")
      submissions (afFake fixture) >>= (`shouldBe` 1)
      d ← diagnostics owner
      (rdRefused d, rdBusy d, rdHeld d) `shouldBe` (0, 0, 1)

  it "cannot be waited on in init or shutdown, where the refusal comes before any waiting" $ bounded $ do
    fixture ← newAFix 4
    withBoundary $ \_ runtime → settleAll fixture $ do
      owner ← arrival fixture [initWaiter, shutdownStarter] runtime "phases"
      admitAdmitter fixture owner "w" "initwaiter"
      line ← lineStarting fixture "init wait "
      line `shouldSatisfy` Text.isInfixOf "false ad.wait: wait is not available in init"
      admitAdmitter fixture owner "s" "shutdownstarter"
      _ ← expectControl (afBase fixture) owner "s" InstanceStop
      stopped ← lineStarting fixture "shutdown start "
      stopped `shouldSatisfy` Text.isInfixOf "false ad.start: request refused: the owner is no longer taking requests"
      _ ← expectControl (afBase fixture) owner "w" InstanceStop
      waited ← lineStarting fixture "shutdown wait "
      waited `shouldSatisfy` Text.isInfixOf "false ad.wait: wait is not available in shutdown"
      finishWork (afFake fixture) 0

  it "of an instance that ended leave another instance's requests alone" $ bounded $ do
    fixture ← newAFix 4
    withBoundary $ \_ runtime → settleAll fixture $ do
      owner ← arrival fixture [admitter] runtime "peers"
      admitAdmitter fixture owner "i" "admitter"
      admitAdmitter fixture owner "j" "admitter"
      acommand fixture owner "i" "start" "a"
      awaitStarts fixture 1
      acommand fixture owner "j" "start" "a"
      awaitStarts fixture 2
      _ ← expectControl (afBase fixture) owner "i" InstanceStop
      awaitCancelled (afFake fixture) 1
      finishWork (afFake fixture) 0
      _ ← awaitSettled (afBase fixture) "i"
      awaitDiagnostic owner ((== 1) . rdHeld)
      -- j's request is as it was: pending, then answered, then taken.
      acommand fixture owner "j" "ready" "a"
      awaitNote fixture "cmd ready a false"
      _ ← answerResult (afFake fixture) 1 3
      acommand fixture owner "j" "take" "a"
      awaitNote fixture "cmd take a {status=success,value={v=3}}"
