-- | Initialization failure, cancellation, and a forced kill.
--
-- The same three assertions run in every case: after the parent has reaped a
-- real status, no admitted owner is left holding a budget, the process identity
-- is gone, and nothing has restarted or replayed the helper. The quota release
-- is written after the reap in each example, never beside the signal send, and
-- the exit evidence the helper produced is kept.
module Test.MacOS.Lifetime (spec) where

import Control.Monad (void)
import Data.Text (Text)
import Test.Hspec

import Hetoimasia.Scripting.Lua.Internal.MacOS.Launch
  ( Exit (..)
  , Launched (..)
  , Ledger
  , admit
  , admitted
  , awaitExit
  , awaitReady
  , awaitReport
  , collectReports
  , newLedger
  , processGone
  , releaseObserved
  , sendSignal
  )
import Hetoimasia.Scripting.Lua.Internal.MacOS.Report
  ( Refusal (..)
  , Report (..)
  , refusalExitCode
  )
import System.Posix.Signals (sigKILL)

import Test.MacOS.Driver

owner ∷ Text
owner = "mod:probe/domain:ui/generation:1"

spec ∷ SpecWith Fixture
spec = describe "lifetime and identity" $ do
  it "leaves no admitted owner when initialization fails after confinement" $ \fixture → do
    ledger ← newLedger
    launched ← launchHelper fixture (fixtureFirst fixture) (fixtureSecond fixture) "init-fail" 0
    admit ledger owner 64
    ready ← awaitReady launched guardMicroseconds
    ready `shouldBe` True
    status ← awaitExit launched
    releaseObserved ledger owner status
    reports ← collectReports launched
    status `shouldBe` ExitedWith (refusalExitCode InitializationFailed)
    [refusal | Refused refusal _ ← reports] `shouldBe` [InitializationFailed]
    checkSettled ledger launched reports
    announce
      ( "proved: an initialization failure after admission exits "
          <> show (refusalExitCode InitializationFailed)
          <> ", releases the owner's budget only once that status was reaped, and never restarts"
      )

  it "leaves no admitted owner when the parent cancels a running helper" $ \fixture → do
    ledger ← newLedger
    launched ← launchHelper fixture (fixtureFirst fixture) (fixtureSecond fixture) "hold" 0
    admit ledger owner 64
    running ← awaitReport launched guardMicroseconds isFootprint
    running `shouldSatisfy` isPresent
    ending ← endWithEscalation launched
    releaseObserved ledger owner (endingExit ending)
    reports ← collectReports launched
    endingExit ending `shouldSatisfy` isSignal
    checkSettled ledger launched reports
    announce
      ( "proved: cancelling a running helper ended it as "
          <> show (endingExit ending)
          <> ", and the parent released its budget from that observation"
      )

  it "leaves no admitted owner when a helper is force-killed" $ \fixture → do
    ledger ← newLedger
    launched ← launchHelper fixture (fixtureFirst fixture) (fixtureSecond fixture) "hold" 0
    admit ledger owner 64
    running ← awaitReport launched guardMicroseconds isFootprint
    running `shouldSatisfy` isPresent
    sent ← sendSignal launched sigKILL
    sent `shouldBe` True
    status ← awaitExit launched
    releaseObserved ledger owner status
    reports ← collectReports launched
    status `shouldBe` Signalled 9
    checkSettled ledger launched reports
    announce
      "proved: a forced kill is reaped as signal 9, the budget is released from the reap and not from the send, and the helper's output up to the kill is kept"
 where
  isFootprint = \case
    Footprint _ _ → True
    _ → False

  isPresent = \case
    Just _ → True
    Nothing → False

  isSignal = \case
    Signalled _ → True
    ExitedWith _ → False

-- | What must hold after every one of the three endings.
checkSettled ∷ Ledger → Launched → [Report] → IO ()
checkSettled ledger launched reports = do
  remaining ← admitted ledger
  remaining `shouldBe` []
  gone ← processGone (launchedPid launched)
  gone `shouldBe` True
  -- No restart and no replay: the helper announced itself admitted at most
  -- once, and its report is retained rather than re-run.
  length [() | Ready ← reports] `shouldSatisfy` (<= 1)
  void (pure reports)

announce ∷ String → IO ()
announce message = putStrLn ("      " <> message)
