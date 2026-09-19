-- | Installation, verification, refusal, and the denied accesses themselves.
--
-- Every example here reads one confined helper's report, collected once by the
-- fixture, and every one of them prints what it proved.
module Test.MacOS.Confinement (spec) where

import Data.List (isInfixOf)
import qualified Data.Text as Text
import Test.Hspec

import Hetoimasia.Scripting.Lua.Internal.MacOS.Confine
  ( Attempt (..)
  , probeExecuteProgram
  , probeHomeSentinel
  , probeNativeModule
  , probeOwnEndpoint
  , probePeerEndpoint
  , probePeerSentinel
  )
import Hetoimasia.Scripting.Lua.Internal.MacOS.Launch
  ( Exit (..)
  , awaitExit
  , collectReports
  , launch
  , LaunchRequest (..)
  )
import Hetoimasia.Scripting.Lua.Internal.MacOS.Report
  ( Origin (..)
  , Outcome (..)
  , Refusal (..)
  , Report (..)
  , refusalExitCode
  )

import Test.MacOS.Driver

spec ∷ SpecWith Fixture
spec = describe "confinement" $ do
  it "reaches every fixture the denials use before anything is confined" $ \fixture → do
    let unreachable =
          [ (name, attemptMechanism attempt)
          | (name, attempt) ← fixtureControls fixture
          , attemptOutcome attempt /= Allowed
          ]
    unreachable `shouldBe` []
    announce
      ( "proved: unconfined, this process reached all "
          <> show (length (fixtureControls fixture))
          <> " fixtures, so a denial below is confinement and not an absent target"
      )

  it "installs and verifies confinement before any Lua source is loaded" $ \fixture → do
    let reports = fixtureSweep fixture
        nativeBefore = [index | (index, Access OriginNative _ _ _) ← indexed reports]
        readyAt = [index | (index, Ready) ← indexed reports]
        luaAt = [index | (index, Access OriginLua _ _ _) ← indexed reports]
    nativeBefore `shouldSatisfy` (not . null)
    readyAt `shouldSatisfy` (not . null)
    luaAt `shouldSatisfy` (not . null)
    maximum nativeBefore `shouldSatisfy` (< minimum readyAt)
    maximum readyAt `shouldSatisfy` (< minimum luaAt)
    announce
      "proved: every native denial and the admitted handshake precede the first line the mod source printed"

  it "refuses with a typed refusal when the profile is withheld, and loads nothing" $ \fixture → do
    let arguments =
          replaceProfile "/nonexistent/hetoimasia-macos-probe.sb" $
            helperArguments fixture (fixtureFirst fixture) (fixtureSecond fixture) "report"
    launched ←
      either (fail . show) pure
        =<< launch
          LaunchRequest
            { requestExecutable = fixtureHelper fixture
            , requestArguments = arguments
            , requestMemoryLimitMiB = 0
            }
    status ← awaitExit launched
    reports ← collectReports launched
    let refusals = [(refusal, detail) | Refused refusal detail ← reports]
    map fst refusals `shouldBe` [ConfinementUnavailable]
    status `shouldBe` ExitedWith (refusalExitCode ConfinementUnavailable)
    [() | Access OriginLua _ _ _ ← reports] `shouldBe` []
    [() | Ready ← reports] `shouldBe` []
    announce
      ( "proved: a withheld prerequisite refuses as "
          <> show ConfinementUnavailable
          <> " with exit "
          <> show (refusalExitCode ConfinementUnavailable)
          <> ", never admitted, and never reached mod source"
      )

  denial "a file in the user's home directory" probeHomeSentinel OriginNative "errno=1/"
  denial "a network socket" probePeerEndpoint OriginNative "errno=1/"
  denial "another program" probeExecuteProgram OriginNative "errno=1/"
  denial "a native module" probeNativeModule OriginNative "blocked by sandbox"

  it "keeps the confined helper's own endpoint reachable" $ \fixture → do
    let native = accessesFrom OriginNative (fixtureSweep fixture)
    outcomeOf probeOwnEndpoint native `shouldBe` Just Allowed
    announce
      "proved: the profile's parameters resolved, so the denials beside this are the policy and not a broken profile"

  describe "from the loaded mod source" $ do
    luaDenial "a file in the user's home directory" probeHomeSentinel
    luaDenial "another instance's sentinel" probePeerSentinel
    luaDenial "another program" probeExecuteProgram
    luaDenial "a native module" probeNativeModule

    it "attempts the socket natively once source is resident, because Lua has no socket API" $ \fixture → do
      let resident = accessesFrom OriginNativePostLoad (fixtureSweep fixture)
      outcomeOf probePeerEndpoint resident `shouldBe` Just Denied
      announce
        ( "proved: after the mod source loaded, a native connect to a peer endpoint is still refused with "
            <> maybe "?" Text.unpack (mechanismOf probePeerEndpoint resident)
        )
 where
  denial label name origin expected =
    it ("denies " <> label <> " from native helper code before any source loads") $ \fixture → do
      let entries = accessesFrom origin (fixtureSweep fixture)
      outcomeOf name entries `shouldBe` Just Denied
      let mechanism = maybe "" Text.unpack (mechanismOf name entries)
      mechanism `shouldSatisfy` (expected `isInfixOf`)
      announce ("proved: " <> Text.unpack name <> " denied, mechanism " <> mechanism)

  luaDenial label name =
    it ("denies " <> label <> " from Lua, with io, os, and package deliberately open") $ \fixture → do
      let entries = accessesFrom OriginLua (fixtureSweep fixture)
      outcomeOf name entries `shouldBe` Just Denied
      let mechanism = maybe "" Text.unpack (mechanismOf name entries)
      mechanism `shouldSatisfy` (not . null)
      mechanism `shouldSatisfy` (not . ("attempt to index" `isInfixOf`))
      announce ("proved: " <> Text.unpack name <> " denied in Lua, mechanism " <> mechanism)

indexed ∷ [a] → [(Int, a)]
indexed = zip [0 ..]

replaceProfile ∷ FilePath → [String] → [String]
replaceProfile path = go
 where
  go ("--profile" : _ : rest) = "--profile" : path : rest
  go (entry : rest) = entry : go rest
  go [] = []

-- | Each example says what it proved, on its own line under Hspec's output.
announce ∷ String → IO ()
announce message = putStrLn ("      " <> message)
