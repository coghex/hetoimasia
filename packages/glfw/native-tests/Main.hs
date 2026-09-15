-- | The native GLFW suite.
--
-- The process main thread is the fixture's owner: it enters the shared
-- production session when the first example needs it, and serves the
-- operations examples dispatch to it until the Hspec run — on a worker thread
-- — has finished. The Hspec tree is built, listed, and filtered before any
-- example runs, so a dry run or a selection that never reaches a native
-- operation acquires nothing, and a selection matching no example fails.
--
-- After the run this prints how many times the shared session was acquired,
-- what the owner served, and every native thread check, and fails if Hspec
-- failed, the owner failed, the session was acquired more than once, or any
-- thread check did not hold.
--
-- Given @--private-session SCENARIO@ it is instead a private-session child;
-- see "Test.GLFW.Native.Private".
module Main (main) where

import Control.Exception (displayException, fromException)
import Control.Monad (unless)
import Data.List (intercalate)
import Data.Maybe (isNothing)
import System.Environment (getArgs)
import System.Exit (ExitCode, exitFailure, exitWith)
import System.IO (hFlush, hPutStrLn, stderr, stdout)
import Test.GLFW.Native.Fixture (OwnerReport (..), runOwned)
import qualified Test.GLFW.Native.Private as Private
import qualified Test.GLFW.Native.Spec as Native
import Test.GLFW.Native.Support
  ( Shared (..)
  , ThreadCheck (..)
  , ThreadFacts
  , newThreadEvidence
  , onOwnerThread
  , sharedSessionOwner
  , threadChecks
  )
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWithResult, isSuccess)

main ∷ IO ()
main =
  getArgs >>= \case
    [flag, scenario] | flag == Private.privateSessionFlag → Private.runScenario scenario
    _ → runSuite

runSuite ∷ IO ()
runSuite = do
  evidence ← newThreadEvidence
  (outcome, report) ←
    runOwned (sharedSessionOwner evidence) $ \fixture →
      hspecWithResult defaultConfig {configFailOnEmpty = True} (Native.spec (Shared fixture evidence))
  checks ← threadChecks evidence
  putStrLn (summary report checks)
  let problems = ownerProblems report checks
  mapM_ (hPutStrLn stderr . ("glfw-native-tests: " <>)) problems
  hFlush stdout
  unless (null problems) exitFailure
  case outcome of
    Left failure
      | Just code ← fromException failure → exitWith (code ∷ ExitCode)
      | otherwise → do
          hPutStrLn stderr ("glfw-native-tests: the Hspec run failed: " <> displayException failure)
          exitFailure
    Right result → unless (isSuccess result) exitFailure

summary ∷ OwnerReport → [(ThreadCheck, ThreadFacts)] → String
summary report checks =
  "glfw-native-tests: shared session acquired "
    <> show (reportAcquisitions report)
    <> " time(s); owner served "
    <> show (reportServed report)
    <> " operation(s) and declined "
    <> show (reportDeclined report)
    <> "; native thread checks: "
    <> if null checks then "none" else intercalate ", " (map describe allChecks)
  where
    allChecks = [SetupCheck, OperationCheck, BeforeReleaseCheck, AfterReleaseCheck]
    describe check =
      let made = [facts | (made', facts) ← checks, made' == check]
          held = length (filter onOwnerThread made)
       in show check <> " " <> show held <> "/" <> show (length made) <> " on the process main thread"

ownerProblems ∷ OwnerReport → [(ThreadCheck, ThreadFacts)] → [String]
ownerProblems report checks =
  [ "the shared session was acquired " <> show acquired <> " times; compatible examples share exactly one"
  | acquired > 1
  ]
    <> [ "the shared session's owner failed: " <> displayException failure
       | Just failure ← [reportFailure report]
       ]
    <> [ "native thread identity did not hold at " <> show check <> ": " <> show facts
       | (check, facts) ← checks
       , not (onOwnerThread facts)
       ]
    <> [ "the shared session was used without a native thread check at " <> show check
       | acquired == 1
       , isNothing (reportFailure report)
       , check ← [SetupCheck, BeforeReleaseCheck, AfterReleaseCheck]
       , check `notElem` map fst checks
       ]
  where
    acquired = reportAcquisitions report
