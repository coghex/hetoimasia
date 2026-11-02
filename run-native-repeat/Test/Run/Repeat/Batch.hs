-- | One bounded run of a command, and a batch of them: the machinery of the repeated-run probe (#586).
--
-- A /trial/ is one run of the complete native profile (or, in this probe's own examples, a stub standing for it). It
-- is judged by what it did, never by its absence of failure: a trial that ran the whole profile and passed every
-- example is 'Passed'; one that exceeded its bound, or that the initialization deadline ended (its diagnostic is in
-- the output even when the enclosing suite reports only a generic failure), is 'Hung'; anything else is 'Failed'. A
-- hang is never a pass, so the batch proves the prevention and not the backstop.
--
-- /Ownership./ Every process a trial starts is this module's: the trial's own process, and the @sample@ it takes of a
-- hung one. A trial that exceeds its bound is sampled once (each sample is itself bounded, and an unsuccessful sample
-- is recorded), then every process in the tree under the trial's root is stopped by pid, with the signal escalated
-- only after a grace; the root is reaped; and the trial answers whether anything it started is still alive. The same
-- stop runs if the trial is cancelled. Output goes to files kept with the batch, so nothing is read back through a
-- pipe that a stuck process could hold open.
module Test.Run.Repeat.Batch
  ( Trial (..)
  , Verdict (..)
  , Outcome (..)
  , Counts (..)
  , confidenceAt
  , runTrial
  , judge
  , tally
  , descendantsOf
  , isAlive
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, mask, onException, try)
import Control.Monad (filterM, forM, unless, void)
import Data.List (isInfixOf)
import GHC.Clock (getMonotonicTime)
import System.Directory (doesFileExist)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), openBinaryFile)
import System.Posix.Signals (Signal, nullSignal, sigKILL, sigTERM, signalProcess)
import System.Posix.Types (CPid)
import System.Process
  ( CreateProcess (..)
  , ProcessHandle
  , StdStream (UseHandle)
  , createProcess
  , getPid
  , proc
  , readCreateProcessWithExitCode
  , waitForProcess
  )
import System.Timeout (timeout)
import Text.Printf (printf)
import Text.Read (readMaybe)

-- | What to run, where, for how long, and how to take a sample of it.
data Trial = Trial
  { trialCommand ∷ [String]
  , trialDirectory ∷ FilePath
  , trialBoundSeconds ∷ Int
    -- ^ How long a trial may run before it is a hang. A normal complete profile takes 8 to 13 seconds.
  , trialSample ∷ CPid → FilePath → [String]
    -- ^ The command that samples a process, given its pid and the file to write.
  , trialExpectedExamples ∷ Int
    -- ^ How many examples the whole profile has: a run that ran fewer is not a pass.
  , trialSampleBoundSeconds ∷ Int
  , trialStopGraceSeconds ∷ Int
  }

data Verdict = Passed | Hung String | Failed String
  deriving (Eq, Show)

data Outcome = Outcome
  { outcomeVerdict ∷ Verdict
  , outcomeStatus ∷ Maybe ExitCode
    -- ^ How the root ended, or 'Nothing' when it had to be stopped.
  , outcomeSeconds ∷ Double
  , outcomeSamples ∷ [String]
    -- ^ One line for each process of a trial stopped at its bound: its sample file, or why none could be taken.
  , outcomeReclaimed ∷ Bool
    -- ^ Nothing the trial started is alive.
  }
  deriving (Show)

data Counts = Counts {passed ∷ Int, hung ∷ Int, failed ∷ Int}
  deriving (Eq, Show)

tally ∷ [Outcome] → Counts
tally outcomes =
  Counts
    { passed = length [() | Outcome {outcomeVerdict = Passed} ← outcomes]
    , hung = length [() | Outcome {outcomeVerdict = Hung _} ← outcomes]
    , failed = length [() | Outcome {outcomeVerdict = Failed _} ← outcomes]
    }

-- | The probability that a batch of @n@ independent runs shows at least one failure when each fails with probability
-- @p@. This is detection power under that assumption, not proof about the program under test.
confidenceAt ∷ Double → Int → Double
confidenceAt p n = 1 - (1 - p) ^ n

-- | The diagnostic the initialization deadline writes (@run/Hetoimasia/Run/Graphics.hs@), whichever process wrote it.
watchdogMarker ∷ String
watchdogMarker = "native initialization exceeded its bound"

-- | Judge a trial that ended on its own, from its exit status and the output it left. Expected is the number of
-- examples the whole profile has.
judge ∷ Int → ExitCode → String → String → Verdict
judge expected status out err
  | watchdogMarker `isInfixOf` out || watchdogMarker `isInfixOf` err =
      Hung "the initialization deadline ended a process (its diagnostic is in the run's output; no live sample was possible)"
  | status == ExitFailure 75 = Hung "the process ended with the initialization deadline's status, 75"
  | status /= ExitSuccess = Failed ("exit status " <> show status)
  | otherwise = case lastSummary of
      Just (count, 0) | count == expected → Passed
      Just (count, failures) → Failed (printf "%d examples, %d failures; the profile has %d" count failures expected)
      Nothing → Failed "no examples summary in the output"
  where
    lastSummary = case [found | line ← lines out, Just found ← [summary (words line)]] of
      [] → Nothing
      found → Just (last found)
    summary ∷ [String] → Maybe (Int, Int)
    summary (n : "examples," : f : "failures" : _) = (,) <$> readMaybe n <*> readMaybe f
    summary (n : "examples," : f : "failures," : _) = (,) <$> readMaybe n <*> readMaybe f
    summary _ = Nothing

-- | Run one trial, writing @run-NNN.out@, @run-NNN.err@ and the samples under the directory, and answer its outcome.
runTrial ∷ Trial → FilePath → Int → IO Outcome
runTrial trial directory index = do
  let stem = directory </> printf "run-%03d" index
      outFile = stem <> ".out"
      errFile = stem <> ".err"
  started ← getMonotonicTime
  handleOut ← openBinaryFile outFile WriteMode
  handleErr ← openBinaryFile errFile WriteMode
  (command, arguments) ← case trialCommand trial of
    [] → ioError (userError "a trial needs a command")
    first : rest → pure (first, rest)
  mask $ \restore → do
    -- The handles are closed by createProcess, in the parent, once the child holds them.
    (_, _, _, handle) ←
      createProcess
        (proc command arguments)
          { cwd = Just (trialDirectory trial)
          , std_out = UseHandle handleOut
          , std_err = UseHandle handleErr
          , create_group = True
          }
    root ← getPid handle >>= maybe (ioError (userError "the trial ended before its pid was read")) pure
    let stop = stopTree (trialStopGraceSeconds trial) root handle
    -- Cancellation anywhere below stops what this trial started.
    outcome ← restore (timeout (trialBoundSeconds trial * 1_000_000) (waitForProcess handle)) `onException` stop
    (status, samples, reclaimed) ← case outcome of
      Just code → pure (Just code, [], True)
      Nothing → do
        pids ← (root :) <$> descendantsOf root
        samples ← restore (forM pids (takeSample trial stem)) `onException` stop
        reclaimed ← stop
        pure (Nothing, samples, reclaimed)
    finished ← getMonotonicTime
    out ← readFileOrEmpty outFile
    err ← readFileOrEmpty errFile
    let verdict = case status of
          Nothing → Hung (printf "no end within %d seconds" (trialBoundSeconds trial))
          Just code → judge (trialExpectedExamples trial) code out err
    pure
      Outcome
        { outcomeVerdict = verdict
        , outcomeStatus = status
        , outcomeSeconds = finished - started
        , outcomeSamples = samples
        , outcomeReclaimed = reclaimed
        }

readFileOrEmpty ∷ FilePath → IO String
readFileOrEmpty path = do
  present ← doesFileExist path
  if present
    then do
      contents ← readFile path
      length contents `seq` pure contents
    else pure ""

-- | One bounded @sample@ of a process: the file it wrote, or the reason there is none. The sampling process is
-- stopped by the process library if the bound abandons it.
takeSample ∷ Trial → FilePath → CPid → IO String
takeSample trial stem pid = do
  let file = stem <> "." <> show pid <> ".sample.txt"
  case trialSample trial pid file of
    [] → pure (show pid <> ": no sampler")
    command : arguments → do
      attempt ←
        try @SomeException . timeout (trialSampleBoundSeconds trial * 1_000_000) $
          readCreateProcessWithExitCode (proc command arguments) ""
      pure $ case attempt of
        Left failure → show pid <> ": sampling failed: " <> show failure
        Right Nothing → show pid <> ": sampling exceeded its bound of " <> show (trialSampleBoundSeconds trial) <> " seconds"
        Right (Just (ExitSuccess, _, _)) → show pid <> ": " <> file
        Right (Just (code, _, err)) → show pid <> ": sampling exited " <> show code <> ": " <> take 200 err

-- | The pids below a root, from the process table, children before their parents.
descendantsOf ∷ CPid → IO [CPid]
descendantsOf root = do
  (_, table, _) ← readCreateProcessWithExitCode (proc "ps" ["-axo", "pid=,ppid="]) ""
  let pairs = [(child, up) | line ← lines table, [a, b] ← [words line], Just child ← [readMaybe a], Just up ← [readMaybe b]]
      below parent = concat [below child <> [child] | (child, up) ← pairs, up == parent]
  pure (below root)

isAlive ∷ CPid → IO Bool
isAlive pid = either (const False) (const True) <$> try @SomeException (signalProcess nullSignal pid)

-- | Stop the tree under the root by pid. The set of pids is taken once, before any signal, from the process table:
-- the root and everything below it, which are the processes this trial started. TERM goes to each that is alive; the
-- root is reaped within the grace and the rest are polled (they are not this process's children, so there is nothing
-- to wait on) for the same grace; KILL then goes to whatever is still alive. Answers whether all of them are gone.
stopTree ∷ Int → CPid → ProcessHandle → IO Bool
stopTree grace root handle = do
  below ← descendantsOf root
  let owned = below <> [root]
  signalAll sigTERM owned
  _ ← timeout (grace * 1_000_000) (waitForProcess handle)
  goneWithin owned
  survivors ← filterM isAlive owned
  unless (null survivors) $ do
    signalAll sigKILL survivors
    _ ← timeout (grace * 1_000_000) (waitForProcess handle)
    goneWithin survivors
  not . or <$> forM owned isAlive
  where
    signalAll ∷ Signal → [CPid] → IO ()
    signalAll signal = mapM_ (\pid → try @SomeException (signalProcess signal pid))
    -- A bounded poll: the processes below the root are not children of this one.
    goneWithin pids = void . timeout (grace * 1_000_000) $ do
      let loop = do
            living ← filterM isAlive pids
            unless (null living) (threadDelay 20_000 >> loop)
      loop
