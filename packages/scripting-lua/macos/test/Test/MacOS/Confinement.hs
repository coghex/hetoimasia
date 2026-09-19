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
  , LaunchRequest (..)
  , launch
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

  it "inherits no descriptor across the spawn, so no peer endpoint bypasses the policy" $ \fixture → do
    let census = [(extra, sockets, detail) | Descriptors extra sockets detail ← fixtureSweep fixture]
    case census of
      [] → expectationFailure "the helper reported no descriptor census"
      ((extra, sockets, detail) : _) → do
        -- The path rules are only the whole answer if the helper holds no live
        -- handle the kernel would never consult them about. The parent binds
        -- both endpoints before this helper is spawned, so an inherited socket
        -- here would be the peer's.
        let (parentExtra, parentSockets, parentCensus) = fixtureParentCensus fixture
        -- The control: the parent really was holding both listening endpoints
        -- when it spawned. Without it a child with no sockets would prove only
        -- that there were none to inherit.
        parentSockets `shouldSatisfy` (>= 2)
        sockets `shouldBe` 0
        -- The count alone cannot separate what the runtime opened for itself
        -- after exec from what the parent leaked into the child, so the census
        -- is checked by name: nothing the helper holds may live under the
        -- fixture root, which is where both endpoints and the peer's private
        -- directory are.
        let leaked =
              [ entry
              | entry ← Text.splitOn "," detail
              , Text.pack (fixtureRoot fixture) `Text.isInfixOf` entry
              ]
        leaked `shouldBe` []
        announce
          ( "proved: above stderr the confined helper holds "
              <> show extra
              <> " descriptors and "
              <> show sockets
              <> " sockets, none of them under the fixture root, while the parent"
              <> " held "
              <> show parentSockets
              <> " sockets of its own among "
              <> show parentExtra
              <> " descriptors — parent census "
              <> Text.unpack parentCensus
              <> "; helper census "
              <> Text.unpack detail
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
    (reports, status) ← observeExit launched
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
