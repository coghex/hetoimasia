-- | Two confined helpers at once, and what neither can reach of the other.
--
-- Coordination is by handshake and by observed exit throughout. Nothing here
-- sleeps for a duration and then assumes something happened.
module Test.MacOS.Isolation (spec) where

import Control.Exception (bracket)
import Test.Hspec

import Hetoimasia.Scripting.Lua.Internal.MacOS.Confine
  ( probeOwnEndpoint
  , probePeerEndpoint
  , probePeerSentinel
  )
import Hetoimasia.Scripting.Lua.Internal.MacOS.Launch
  ( Exit (..)
  , Launched (..)
  , awaitExitWithin
  , awaitReady
  , awaitReport
  , collectReports
  , processGone
  )
import Hetoimasia.Scripting.Lua.Internal.MacOS.Report (Origin (..), Outcome (..), Report (..))

import Test.MacOS.Driver

spec ∷ SpecWith Fixture
spec = describe "two-instance isolation" $
  it "gives two simultaneous helpers distinct processes and storage, neither reaching the other, each endable alone" $ \fixture →
    withPair fixture $ \(first, second) → do
      -- Both are admitted and have their mod source resident before anything
      -- is asserted about either.
      readyFirst ← awaitReady first guardMicroseconds
      readySecond ← awaitReady second guardMicroseconds
      (readyFirst, readySecond) `shouldBe` (True, True)
      loadedFirst ← awaitReport first guardMicroseconds isFootprint
      loadedSecond ← awaitReport second guardMicroseconds isFootprint
      (isJustFootprint loadedFirst, isJustFootprint loadedSecond) `shouldBe` (True, True)

      launchedPid first `shouldNotBe` launchedPid second
      instancePrivate (fixtureFirst fixture) `shouldNotBe` instancePrivate (fixtureSecond fixture)
      instanceEndpoint (fixtureFirst fixture) `shouldNotBe` instanceEndpoint (fixtureSecond fixture)

      firstReports ← collectReports first
      secondReports ← collectReports second
      -- Neither helper may hold a descriptor for the other's endpoint: a
      -- refused connect() is about a path, and an inherited handle is not.
      inheritedSockets firstReports `shouldBe` Just 0
      inheritedSockets secondReports `shouldBe` Just 0
      let firstNative = accessesFrom OriginNative firstReports
          secondNative = accessesFrom OriginNative secondReports
      outcomeOf probePeerSentinel firstNative `shouldBe` Just Denied
      outcomeOf probePeerSentinel secondNative `shouldBe` Just Denied
      outcomeOf probePeerEndpoint firstNative `shouldBe` Just Denied
      outcomeOf probePeerEndpoint secondNative `shouldBe` Just Denied
      outcomeOf probeOwnEndpoint firstNative `shouldBe` Just Allowed
      outcomeOf probeOwnEndpoint secondNative `shouldBe` Just Allowed

      -- One is ended; the other is untouched, still running, and still its own
      -- process afterwards.
      ending ← endWithEscalation first
      gone ← processGone (launchedPid first)
      gone `shouldBe` True
      survivor ← awaitExitWithin second 200000
      survivor `shouldBe` Nothing
      survivorGone ← processGone (launchedPid second)
      survivorGone `shouldBe` False

      putStrLn
        ( "      proved: pids "
            <> show (launchedPid first)
            <> " and "
            <> show (launchedPid second)
            <> " with separate private directories; each refused the other's sentinel and endpoint"
            <> " while reaching its own; ending the first ("
            <> describeExit (endingExit ending)
            <> ") left the second running"
        )
 where
  withPair fixture =
    bracket
      ( do
          first ← launchHelper fixture (fixtureFirst fixture) (fixtureSecond fixture) "hold" 0
          second ← launchHelper fixture (fixtureSecond fixture) (fixtureFirst fixture) "hold" 0
          pure (first, second)
      )
      (\(first, second) → mapM_ endQuietly [first, second])

  isFootprint = \case
    Footprint _ _ → True
    _ → False

  isJustFootprint = \case
    Just (Footprint _ _) → True
    _ → False

-- | How many sockets a helper reported holding above stderr.
inheritedSockets ∷ [Report] → Maybe Int
inheritedSockets reports = case [sockets | Descriptors _ sockets _ ← reports] of
  (sockets : _) → Just sockets
  [] → Nothing

describeExit ∷ Exit → String
describeExit = \case
  ExitedWith code → "exit " <> show code
  Signalled signal → "signal " <> show signal
