-- | One bounded run of a command, and a batch of them: the machinery of the repeated-run probe (#586).
--
-- A /trial/ is one run of the complete native profile (or, in this probe's own examples, a stub standing for it). It
-- is judged by what it did, never by its absence of failure: a trial that ran the whole profile and passed every
-- example is 'Passed'; one that exceeded its bound, or that the initialization deadline ended (its diagnostic is in
-- the output even when the enclosing suite reports only a generic failure), is 'Hung'; anything else is 'Failed'. A
-- hang is never a pass, so the batch proves the prevention and not the backstop.
--
-- /Ownership./ Every process this module starts (a trial, the sample it takes of a hung one, a preparation) runs through
-- 'runOwned', which starts it in a process group of its own and owns everything that group, or the tree under its root,
-- contains: while the root lives, after it has ended on its own (a run that passed and left a child behind) and after
-- the bound passed. A process that outlives its root is found by its group, not by its parent. On every exit, including
-- cancellation, the owned set is taken once, before any signal, stopped by pid (TERM, a grace, then KILL, each only to
-- a pid still alive), and the answer says whether everything is gone. Output goes to files kept with the batch, so
-- nothing is read back through a pipe that a stuck process could hold open.
--
-- /Persistence./ 'runBatch' writes the batch report after every trial and again when a trial is cancelled, with the
-- interrupted attempt recorded as a failure, so a batch that is cut short leaves its partial result.
module Test.Run.Repeat.Batch
  ( Trial (..)
  , Verdict (..)
  , Outcome (..)
  , Counts (..)
  , confidenceAt
  , runTrial
  , runBatch
  , continues
  , runPreparation
  , judge
  , tally
  , ownedProcesses
  , isAlive
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, mask, onException, try)
import Control.Monad (filterM, forM, unless, void)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf, nub)
import GHC.Clock (getMonotonicTime)
import System.Directory (doesFileExist)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.IO (Handle, IOMode (WriteMode), openBinaryFile)
import System.Posix.Signals (Signal, nullSignal, sigKILL, sigTERM, signalProcess)
import System.Posix.Types (CPid)
import System.Process
  ( CreateProcess (..)
  , ProcessHandle
  , StdStream (NoStream, UseHandle)
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
    -- ^ Nothing the trial started (the run, its samplers) is alive.
  , outcomeOrphans ∷ Int
    -- ^ How many processes were still alive in the trial's group after its root had ended on its own, and were stopped.
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

-- | How a command run by 'runOwned' ended: its root's status, 'Nothing' when it had to be stopped, whether everything it
-- started is gone, and how many processes were still alive in its group after the root had ended on its own.
data Ended = Ended {endedStatus ∷ Maybe ExitCode, endedReclaimed ∷ Bool, endedOrphans ∷ Int}

-- | Run a command to completion or to its bound, with its output written to the handles (which the process library
-- closes in this process once the child holds them). When the bound passes, the owned processes are handed to
-- @atBound@, one at a time (to be sampled), before they are stopped; its answers are returned. A cancellation anywhere stops the owned
-- processes before it propagates.
runOwned ∷ [String] → FilePath → Handle → Handle → Int → Int → (CPid → IO a) → IO (Ended, [a])
runOwned command directory handleOut handleErr boundSeconds graceSeconds atBound = do
  (program, arguments) ← case command of
    [] → ioError (userError "a command is needed")
    first : rest → pure (first, rest)
  mask $ \restore → do
    (_, _, _, handle) ←
      createProcess
        (proc program arguments)
          { cwd = Just directory
          , std_in = NoStream
          , std_out = UseHandle handleOut
          , std_err = UseHandle handleErr
          , create_group = True
          }
    root ← getPid handle >>= maybe (ioError (userError "the command ended before its pid was read")) pure
    let stop = stopOwned graceSeconds root handle
    outcome ← restore (timeout (boundSeconds * 1_000_000) (waitForProcess handle)) `onException` stop
    case outcome of
      Just code → do
        -- The root ended on its own. Whatever it left in its group is still this command's.
        left ← filter (/= root) <$> ownedProcesses root
        reclaimed ← if null left then pure True else stop
        pure (Ended (Just code) reclaimed (length left), [])
      Nothing → do
        pids ← (<> [root]) <$> ownedProcesses root
        answers ← restore (forM pids atBound) `onException` stop
        reclaimed ← stop
        pure (Ended Nothing reclaimed 0, answers)

-- | Run one trial, writing @run-NNN.out@, @run-NNN.err@ and the samples under the directory, and answer its outcome.
runTrial ∷ Trial → FilePath → Int → IO Outcome
runTrial trial directory index = do
  let stem = directory </> printf "run-%03d" index
      outFile = stem <> ".out"
      errFile = stem <> ".err"
  started ← getMonotonicTime
  handleOut ← openBinaryFile outFile WriteMode
  handleErr ← openBinaryFile errFile WriteMode
  (ended, sampled) ←
    runOwned (trialCommand trial) (trialDirectory trial) handleOut handleErr (trialBoundSeconds trial) (trialStopGraceSeconds trial) (takeSample trial stem)
  finished ← getMonotonicTime
  out ← readFileOrEmpty outFile
  err ← readFileOrEmpty errFile
  let samples = concat sampled
      verdict = case endedStatus ended of
        Nothing → Hung (printf "no end within %d seconds" (trialBoundSeconds trial))
        Just code → judge (trialExpectedExamples trial) code out err
  pure
    Outcome
      { outcomeVerdict = verdict
      , outcomeStatus = endedStatus ended
      , outcomeSeconds = finished - started
      , outcomeSamples = map fst samples
      , outcomeReclaimed = endedReclaimed ended && all snd samples
      , outcomeOrphans = endedOrphans ended
      }

-- | Run a preparation command to completion under a bound, its output kept in a file. A preparation that exceeds the
-- bound, or is cancelled, is stopped by pid with everything it started, exactly as a trial is. Answers how it ended:
-- 'Nothing' when it had to be stopped.
runPreparation ∷ [String] → FilePath → FilePath → Int → Int → IO (Maybe ExitCode)
runPreparation command directory outFile boundSeconds graceSeconds = do
  handleOut ← openBinaryFile outFile WriteMode
  (ended, _) ← runOwned command directory handleOut handleOut boundSeconds graceSeconds (const (pure ()))
  pure (endedStatus ended)

readFileOrEmpty ∷ FilePath → IO String
readFileOrEmpty path = do
  present ← doesFileExist path
  if present
    then do
      contents ← readFile path
      length contents `seq` pure contents
    else pure ""

-- | One bounded @sample@ of a process: the line that says what came of it, and whether the sampler (and anything it
-- started) is gone. The sampler is owned like any other process: when its bound passes it is stopped by pid, escalated after
-- the grace, and reaped before the trial goes on.
takeSample ∷ Trial → FilePath → CPid → IO [(String, Bool)]
takeSample trial stem pid = do
  let file = stem <> "." <> show pid <> ".sample.txt"
  case trialSample trial pid file of
    [] → pure [(show pid <> ": no sampler", True)]
    command → do
      handleOut ← openBinaryFile (file <> ".log") WriteMode
      handleErr ← openBinaryFile (file <> ".err") WriteMode
      attempt ←
        try @SomeException $
          runOwned command (trialDirectory trial) handleOut handleErr (trialSampleBoundSeconds trial) (trialStopGraceSeconds trial) (const (pure ()))
      pure . pure $ case attempt of
        Left failure → (show pid <> ": sampling failed: " <> show failure, False)
        Right (ended, _) → case endedStatus ended of
          Nothing → (show pid <> ": sampling exceeded its bound of " <> show (trialSampleBoundSeconds trial) <> " seconds and the sampler was stopped", endedReclaimed ended)
          Just ExitSuccess → (show pid <> ": " <> file, endedReclaimed ended)
          Just code → (show pid <> ": sampling exited " <> show code <> " (see " <> file <> ".err)", endedReclaimed ended)

-- | The pids a root owns: everything below it by parentage, and everything in its process group (the root started the
-- group, so a process that outlived its parent is still found). Children before their parents, no pid twice, the root
-- itself not included.
ownedProcesses ∷ CPid → IO [CPid]
ownedProcesses root = do
  (_, table, _) ← readCreateProcessWithExitCode (proc "ps" ["-axo", "pid=,ppid=,pgid="]) ""
  let rows = [(pid, up, group) | line ← lines table, [a, b, c] ← [words line], Just pid ← [readMaybe a], Just up ← [readMaybe b], Just group ← [readMaybe c]]
      below parent = concat [below child <> [child] | (child, up, _) ← rows, up == parent]
      grouped = [pid | (pid, _, group) ← rows, group == root]
  pure (filter (/= root) (nub (below root <> grouped)))

isAlive ∷ CPid → IO Bool
isAlive pid = either (const False) (const True) <$> try @SomeException (signalProcess nullSignal pid)

-- | Stop what a root owns, by pid. The set is taken once, before any signal: the root and its owned processes. TERM goes to
-- each that is alive; the root is reaped within the grace and the rest are polled (they are not this process's children,
-- so there is nothing to wait on) for the same grace; KILL then goes to whatever is still alive. Answers whether all of
-- them are gone.
stopOwned ∷ Int → CPid → ProcessHandle → IO Bool
stopOwned grace root handle = do
  below ← ownedProcesses root
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
    signalAll signal pids = mapM_ (\pid → try @SomeException (signalProcess signal pid)) pids
    -- A bounded poll: the processes below the root are not children of this one.
    goneWithin pids = void . timeout (grace * 1_000_000) $ do
      let loop = do
            living ← filterM isAlive pids
            unless (null living) (threadDelay 20_000 >> loop)
      loop

-- | Whether a batch goes on after an outcome: not past its size, not after the first hang when it stops at one, and not
-- after a trial whose processes could not all be stopped (another trial would start beside them).
continues ∷ Int → Int → Bool → Outcome → Bool
continues runs index untilHang outcome =
  index < runs
    && outcomeReclaimed outcome
    && not (untilHang && isHung (outcomeVerdict outcome))
  where
    isHung (Hung _) = True
    isHung _ = False

-- | Run a batch of up to @runs@ trials, one at a time, writing @report.md@ under the directory (rendered from the
-- outcomes so far) after every trial. A trial that is cancelled is recorded as an interrupted failure, the partial report
-- is written, and the cancellation propagates. Answers every outcome, in order.
runBatch ∷ Trial → FilePath → Int → Bool → ([Outcome] → String) → (Int → Outcome → IO ()) → IO [Outcome]
runBatch trial directory runs untilHang render announce = do
  seen ← newIORef []
  let write = readIORef seen >>= \outcomes → writeFile (directory </> "report.md") (render (reverse outcomes))
      go index = do
        started ← getMonotonicTime
        outcome ←
          runTrial trial directory index `onException` do
            now ← getMonotonicTime
            modifyIORef' seen (interrupted (now - started) :)
            write
        modifyIORef' seen (outcome :)
        write
        announce index outcome
        if continues runs index untilHang outcome then go (index + 1) else pure ()
  go 1
  reverse <$> readIORef seen
  where
    interrupted seconds =
      Outcome
        { outcomeVerdict = Failed "interrupted: the attempt was cancelled before it ended"
        , outcomeStatus = Nothing
        , outcomeSeconds = seconds
        , outcomeSamples = []
        , outcomeReclaimed = True
        , outcomeOrphans = 0
        }
