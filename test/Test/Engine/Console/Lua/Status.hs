-- | The exit status of a @lua@ run as a pure function of what the runner answered, and the exit
-- statuses the console names.
module Test.Engine.Console.Lua.Status (spec) where

import Control.Monad (forM_)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Hetoimasia.Console.Exit (cancellationExitCode, failureExitCode, usageExitCode)
import Hetoimasia.Console.Lua.Status (outcomeStatus, refusalLines, statusExit)
import Hetoimasia.Scripting.Lua.Runner
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import Test.Hspec (Spec, describe, it, shouldBe)

report ∷ RunEnding → RunStatus → RunReport
report ending status = RunReport ending [] Nothing status 0 noTally

spec ∷ Spec
spec = describe "the lua exit status" $ do
  it "names the statuses: 1 for failure, 2 for usage, 130 for a cancellation" $ do
    failureExitCode `shouldBe` ExitFailure 1
    usageExitCode `shouldBe` ExitFailure 2
    cancellationExitCode `shouldBe` ExitFailure 130
  it "maps the status value: failure 1, interrupted 130, success 0" $ do
    statusExit StatusFailure `shouldBe` ExitFailure 1
    statusExit StatusInterrupted `shouldBe` ExitFailure 130
    statusExit StatusSuccess `shouldBe` ExitSuccess
  it "maps a refusal to 2, whatever it names" $
    forM_ [TickDurationNotPositive, NoScripts, LimitNotPositive] $ \reason →
      outcomeStatus (Refused (UsageRefusal (UsageViolation Nothing reason :| []))) `shouldBe` ExitFailure 2
  it "maps a report by its status, and by nothing else about how the run ended" $
    forM_
      [ (EndedAllInstances, StatusSuccess, ExitSuccess)
      , (EndedLimit, StatusSuccess, ExitSuccess)
      , (EndedTickLimit, StatusSuccess, ExitSuccess)
      , (EndedStopRequest, StatusInterrupted, ExitFailure 130)
      , (EndedStopRequest, StatusFailure, ExitFailure 1)
      , (EndedAllInstances, StatusFailure, ExitFailure 1)
      , (EndedStartupFailure, StatusFailure, ExitFailure 1)
      ] $ \(ending, status, code) →
        outcomeStatus (Ran (report ending status)) `shouldBe` code
  it "ranks 1 over 130 over 0 through the runner's own status value" $ do
    -- A run that was stopped and in which an instance failed is a failure: the runner's status is.
    runStatusOf True EndedStopRequest `shouldBe` StatusFailure
    runStatusOf False EndedStopRequest `shouldBe` StatusInterrupted
    runStatusOf False EndedAllInstances `shouldBe` StatusSuccess
    statusExit (runStatusOf True EndedStopRequest) `shouldBe` ExitFailure 1
    statusExit (runStatusOf False EndedStopRequest) `shouldBe` ExitFailure 130
  it "gives a refusal's reasons one line each, in the runner's order" $ do
    let refusal = UsageRefusal (UsageViolation (Just "a.lua") ModuleDefinesRunAndUpdate :| [UsageViolation Nothing NoScripts])
    length (refusalLines refusal) `shouldBe` 2
