-- | The exit status of @hetoimasia run@ as a pure function of what the run came to: each status, and the ranking
-- of failure over interruption over a normal end however they combine.
module Test.Engine.Run.Status (spec) where

import Control.Monad (forM_)
import Hetoimasia.LuaEngine.Session (DiagEvidence (..), EngineReport (..), SessionOutcome (..), Verdict (..))
import Hetoimasia.Run.Status (RunResult (..), bootFailed, exitStatus, resultFailed)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import Test.Hspec (Spec, describe, it, shouldBe)

-- | An outcome of the session with these facts and nothing else.
outcome ∷ Verdict → Bool → Bool → Bool → SessionOutcome
outcome verdict quit interrupted retired =
  SessionOutcome
    { outVerdict = verdict
    , outFailures = []
    , outEngine = EngineReport {erPrimary = Nothing, erSecondary = [], erOmitted = 0}
    , outTerminal = Nothing
    , outDiagnostics = DiagEvidence {deSinkFailures = 0, deSinkFirst = [], deUndelivered = 0, deUndeliveredFirst = [], deCause = Nothing}
    , outQuit = quit
    , outInterrupted = interrupted
    , outRetired = retired
    }

ran ∷ SessionOutcome → RunResult
ran found = RunResult (Just found) Nothing [] False

spec ∷ Spec
spec = describe "Status" $ do
  it "is 0 for a normal quit and for an orderly end" $ do
    exitStatus (ran (outcome VerdictSuccess True False True)) `shouldBe` ExitSuccess
    exitStatus (ran (outcome VerdictSuccess False False True)) `shouldBe` ExitSuccess

  it "is 130 for an orderly interruption that failed nothing, whether the session or the launcher saw the signal" $ do
    exitStatus (ran (outcome VerdictInterrupted False True True)) `shouldBe` ExitFailure 130
    exitStatus (RunResult (Just (outcome VerdictSuccess False False True)) Nothing [] True) `shouldBe` ExitFailure 130
    exitStatus (RunResult Nothing Nothing [] True) `shouldBe` ExitFailure 130

  it "is 1 for a failed session, and for a session whose roles did not all retire" $ do
    exitStatus (ran (outcome VerdictFailure False False True)) `shouldBe` ExitFailure 1
    exitStatus (ran (outcome VerdictSuccess True False False)) `shouldBe` ExitFailure 1

  it "is 1 for a boot failure and for any failure of what surrounds the session" $ do
    exitStatus (bootFailed "no manifest" False) `shouldBe` ExitFailure 1
    exitStatus (RunResult (Just (outcome VerdictSuccess True False True)) Nothing ["pool close failed"] False) `shouldBe` ExitFailure 1

  it "lets a failure outrank an interruption outrank a normal quit, in every combination" $
    forM_ [(v, q, i, h, s) | v ← [VerdictSuccess, VerdictInterrupted, VerdictFailure], q ← [False, True], i ← [False, True], h ← [[], ["late"]], s ← [False, True]] $
      \(verdict, quit, interrupted, host, signalled) → do
        let result = RunResult (Just (outcome verdict quit interrupted True)) Nothing host signalled
            expected
              | verdict == VerdictFailure || not (null host) = ExitFailure 1
              | verdict == VerdictInterrupted || signalled = ExitFailure 130
              | otherwise = ExitSuccess
        (verdict, quit, interrupted, host, signalled, exitStatus result) `shouldBe` (verdict, quit, interrupted, host, signalled, expected)
        resultFailed result `shouldBe` (verdict == VerdictFailure || not (null host))

  it "never reports a boot failure as an interruption, even after a signal" $
    exitStatus (bootFailed "malformed" True) `shouldBe` ExitFailure 1
