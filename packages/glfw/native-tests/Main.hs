-- | The native GLFW suite.
--
-- The process main thread is the fixture's owner: it enters the shared
-- production session when the first example needs it, and serves the
-- operations examples dispatch to it until the Hspec run — on a worker thread
-- — has finished. The Hspec tree is built, listed, and filtered before any
-- example runs, so a dry run or a selection that never reaches a native
-- operation acquires nothing, and a selection matching no example fails.
--
-- No native operation runs without consent. The run's environment is read
-- once, before anything else ("Test.GLFW.Native.Consent"): a run with no
-- consent still builds, lists, and filters the tree, and still runs every
-- example that needs no session, but each example that uses the shared
-- session or starts a private-session child is refused before its body runs,
-- the session is never acquired, and the run ends with one line on stderr
-- naming what was missing and a non-zero exit. A run's opt-in to the local
-- desktop is @HETOIMASIA_NATIVE_SESSION=desktop@ on that command;
-- @tools/display/x11.sh@ supplies its own consent for the isolated X11
-- display it starts.
--
-- After the run this prints how many times the shared session was acquired,
-- what the owner served, and every native thread check, and fails if Hspec
-- failed, the owner failed, the session was acquired more than once, any
-- thread check did not hold, or any operation was refused.
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
import System.IO (BufferMode (LineBuffering), hFlush, hPutStrLn, hSetBuffering, stderr, stdout)
import Test.GLFW.Native.Consent (Consent, Refusal, readConsent, refusalMessage)
import Test.GLFW.Native.Fixture (OwnerReport (..), runOwned)
import qualified Test.GLFW.Native.Private as Private
import qualified Test.GLFW.Native.Spec as Native
import Test.GLFW.Native.Support
  ( Shared (..)
  , ThreadCheck (..)
  , ThreadFacts
  , newGate
  , newThreadEvidence
  , onOwnerThread
  , refusals
  , sharedSessionOwner
  , threadChecks
  )
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWithResult, isSuccess)

main ∷ IO ()
main = do
  -- A native run's own output is its evidence, and this process enters a real
  -- GLFW session on the thread that would take the whole program down with it.
  -- Piped into a runner, stdout would otherwise be block-buffered and flushed
  -- only at exit, so a session that ended the process took every example line
  -- and the closing report with it — exactly the run whose output is wanted.
  -- Line buffering costs a run nothing and makes what happened legible.
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  consent ← readConsent
  getArgs >>= \case
    [flag, scenario] | flag == Private.privateSessionFlag → Private.runScenario consent scenario
    _ → runSuite consent

runSuite ∷ Either Refusal Consent → IO ()
runSuite consent = do
  evidence ← newThreadEvidence
  gate ← newGate consent
  (outcome, report) ←
    runOwned (sharedSessionOwner evidence gate) $ \fixture →
      hspecWithResult defaultConfig {configFailOnEmpty = True} (Native.spec (Shared fixture evidence gate))
  checks ← threadChecks evidence
  refused ← refusals gate
  putStrLn (summary report checks)
  let problems = ownerProblems report checks <> refusalProblems consent refused
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

-- | The one line a refused run ends with: how many native examples the gate
-- refused before their bodies, and the refusal itself, which names the missing
-- consent and the isolated alternative. A run that refused nothing — a dry
-- run, a listing, or a selection outside the native examples — reports
-- nothing here.
refusalProblems ∷ Either Refusal Consent → Int → [String]
refusalProblems consent refused =
  [ show refused <> " native example(s) refused before any native operation or child, so this is not a native pass: " <> refusalMessage refusal
  | Left refusal ← [consent]
  , refused > 0
  ]
