-- | The executable's record, replay and digest options (#500 requirement 7), run as a bounded child process in the same way the
-- rest of the suite runs it: through the suite's @build-tool-depends@ and nothing else. The commands here are the ones the
-- sample's README gives for each acceptance signal.
--
-- A replay needs an existing, readable, valid log; a recording may create a new file and never overwrites one, and an output
-- error never claims a recording that did not happen. The final digest is that of the final published snapshot, so a failure
-- or a stop after the last commit changes it without touching the trace, and a matching expected digest never turns a failure
-- into a success.
module Test.Domains.Options (spec) where

import Control.Exception (finally)
import Control.Monad (forM_)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as Lazy
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.List (isInfixOf, isPrefixOf)
import System.Directory (createDirectory, createFileLink, doesDirectoryExist, doesFileExist, doesPathExist, findExecutable, getTemporaryDirectory, listDirectory, removeDirectoryRecursive)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.IO.Unsafe (unsafePerformIO)
import System.Process (getCurrentPid, proc, readCreateProcessWithExitCode)
import Hetoimasia.Sample.LuaDomains.InputLog (InputLog, renderLog)
import Test.Domains.FixedLog (generateLog)
import Test.Domains.Support (generous)
import Test.Hspec

-- | The executable's exit status, stdout and stderr.
runExe ∷ [String] → IO (ExitCode, String, String)
runExe arguments = do
  executable ← findExecutable "hetoimasia-lua-domains" >>= maybe (fail "the executable is not on this test's search path") pure
  generous (readCreateProcessWithExitCode (proc executable arguments) "")

counter ∷ IORef Int
counter = unsafePerformIO (newIORef 0)
{-# NOINLINE counter #-}

-- | A directory of the example's own, removed however the example ends.
withTempDirectory ∷ (FilePath → IO a) → IO a
withTempDirectory body = do
  base ← getTemporaryDirectory
  pid ← getCurrentPid
  number ← atomicModifyIORef' counter (\held → (held + 1, held))
  let directory = base </> ("lua-domains-options-" <> show pid <> "-" <> show number)
  createDirectory directory
  body directory `finally` removeDirectoryRecursive directory

-- | The lines of a report or a trace that start with this word.
linesWith ∷ String → String → [String]
linesWith prefix = filter (prefix `isPrefixOf`) . lines

-- | The 64 hexadecimal digits after @final digest: @ in a report.
finalDigest ∷ String → String
finalDigest out = case linesWith "final digest: " out of
  line : _ → take 64 (drop (length ("final digest: " ∷ String)) line)
  [] → ""

-- | One bounded usage line on stderr, nothing on stdout, and exit status 2.
usageRefusal ∷ (ExitCode, String, String) → String → Expectation
usageRefusal (status, out, err) reason = do
  status `shouldBe` ExitFailure 2
  out `shouldBe` ""
  length (lines err) `shouldBe` 1
  err `shouldSatisfy` ("hetoimasia-lua-domains: " `isPrefixOf`)
  err `shouldSatisfy` (reason `isInfixOf`)
  length err `shouldSatisfy` (< 600)

-- | A log of the hand-driven session of twelve ticks, with the pause and resume controls or without, written to a file.
writeFixed ∷ FilePath → Bool → IO InputLog
writeFixed path withControls = do
  log' ← generateLog 1 12 withControls
  Lazy.writeFile path (renderLog log')
  pure log'

spec ∷ Spec
spec = describe "the executable's record, replay and digest options" $ do
  it "prints the same digest lines for a recorded run and for the replay of its log, and the replay says it is complete" $
    withTempDirectory $ \directory → do
      let logPath = directory </> "log.txt"
      (recordedStatus, recordedOut, recordedErr) ← runExe ["--scenario", "normal", "--ticks", "50", "--seed", "1", "--record", logPath, "--digests"]
      recordedStatus `shouldBe` ExitSuccess
      recordedErr `shouldBe` ""
      length (linesWith "record: wrote " recordedOut) `shouldBe` 1
      (replayedStatus, replayedOut, replayedErr) ← runExe ["--replay", logPath, "--ticks", "50", "--seed", "1", "--digests"]
      replayedStatus `shouldBe` ExitSuccess
      replayedErr `shouldBe` ""
      -- The digest trace: tick 0 and then each of the fifty ticks, in order.
      length (linesWith "digest " recordedOut) `shouldBe` 51
      [takeWhile (/= ' ') (drop 7 line) | line ← linesWith "digest " recordedOut] `shouldBe` map show [0 ∷ Int .. 50]
      linesWith "digest " replayedOut `shouldBe` linesWith "digest " recordedOut
      finalDigest replayedOut `shouldBe` finalDigest recordedOut
      length (finalDigest recordedOut) `shouldBe` 64
      -- Every record the log holds was released, so the replay is complete.
      let records = [takeWhile (/= ' ') (drop (length ("record: wrote " ∷ String)) line) | line ← linesWith "record: wrote " recordedOut]
      case records of
        [count] → linesWith "replay: " replayedOut `shouldBe` ["replay: fed " <> count <> " of " <> count <> " records, complete"]
        _ → expectationFailure "expected one record line"

  it "writes a log it recorded and replayed to the same bytes, controls included, when every record was released" $
    withTempDirectory $ \directory → do
      let fixedPath = directory </> "fixed.txt"
          copyPath = directory </> "copy.txt"
      _ ← writeFixed fixedPath True
      (status, out, err) ← runExe ["--replay", fixedPath, "--record", copyPath, "--ticks", "12", "--seed", "1"]
      status `shouldBe` ExitSuccess
      err `shouldBe` ""
      linesWith "replay: " out `shouldSatisfy` all (" complete" `isInfixOf`)
      original ← ByteString.readFile fixedPath
      copied ← ByteString.readFile copyPath
      copied `shouldBe` original
      ByteString.isInfixOf "control tick=5 place=0 target=gameplay op=pause" original `shouldBe` True

  it "prints the trace of the ticks it ran and nothing for the ticks it did not: a failed session's trace ends where its committed ticks end" $ do
    (status, out, _) ← runExe ["--scenario", "failure", "--digests"]
    status `shouldBe` ExitFailure 1
    length (linesWith "digest " out) `shouldBe` 6

  describe "--replay, which needs an existing, readable, valid log it can replay" $ do
    it "refuses a missing file" $
      withTempDirectory $ \directory →
        (runExe ["--replay", directory </> "missing.txt"] >>= \found → usageRefusal found "no such file")

    it "refuses a path that cannot be read as a file" $
      withTempDirectory $ \directory →
        (runExe ["--replay", directory] >>= \found → usageRefusal found "cannot be opened for reading")

    it "refuses a malformed file, naming the line, and a file that is no log at all" $
      withTempDirectory $ \directory → do
        let badPath = directory </> "bad.txt"
            cutPath = directory </> "cut.txt"
        writeFile badPath "not a log\n"
        runExe ["--replay", badPath] >>= \found → usageRefusal found "line 1: not a hetoimasia-lua-domains input log"
        log' ← writeFixed (directory </> "whole.txt") True
        -- The same log without its last line, cut at a record boundary: truncated, never a shorter log.
        let text = Lazy.toStrict (renderLog log')
            kept = take (length (ByteString.split 10 text) - 3) (ByteString.split 10 text)
        ByteString.writeFile cutPath (ByteString.intercalate "\n" kept <> "\n")
        runExe ["--replay", cutPath] >>= \found → usageRefusal found "the log ends without its trailer"

    it "refuses a log that cannot be replayed in the session asked for, before it starts" $
      withTempDirectory $ \directory → do
        let logPath = directory </> "log.txt"
        _ ← writeFixed logPath True
        runExe ["--replay", logPath, "--ticks", "3"] >>= \found → usageRefusal found "cannot be replayed in this session: a record for tick 4, after the session's last tick 3"
        runExe ["--replay", logPath, "--ticks", "12", "--scenario", "stop"] >>= \found → usageRefusal found "after the tick 8 the scenario stops the session at"

  describe "--record, which creates a new file and never overwrites one" $ do
    it "refuses an existing path, of any kind, and leaves it exactly as it was" $
      withTempDirectory $ \directory → do
        let existing = directory </> "existing.txt"
        writeFile existing "precious\n"
        runExe ["--record", existing] >>= \found → usageRefusal found "the path exists"
        ByteString.readFile existing `shouldReturn` "precious\n"
        runExe ["--record", directory] >>= \found → usageRefusal found "the path exists"
        doesDirectoryExist directory `shouldReturn` True

    it "refuses a path in a directory that does not exist, and creates nothing" $
      withTempDirectory $ \directory → do
        let path = directory </> "missing" </> "log.txt"
        runExe ["--record", path] >>= \found → usageRefusal found "the directory the path is in does not exist"
        doesPathExist (directory </> "missing") `shouldReturn` False

    it "writes only the path it was given" $
      withTempDirectory $ \directory → do
        let path = directory </> "log.txt"
        (status, _, _) ← runExe ["--record", path, "--ticks", "5"]
        status `shouldBe` ExitSuccess
        doesFileExist path `shouldReturn` True
        listDirectory directory `shouldReturn` ["log.txt"]

    it "reports an output error and never claims a recording that did not happen: no success line, no file, exit status 1" $
      withTempDirectory $ \directory → do
        -- A path that looks free and cannot be written: a link to a file in a directory that is not there.
        let link = directory </> "dangling.txt"
        createFileLink (directory </> "nowhere" </> "target.txt") link
        (status, out, err) ← runExe ["--record", link, "--ticks", "5"]
        status `shouldBe` ExitFailure 1
        linesWith "record: wrote " out `shouldBe` []
        length (linesWith "record: FAILED, nothing was recorded to " out) `shouldBe` 1
        doesPathExist (directory </> "nowhere") `shouldReturn` False
        err `shouldBe` ""
        -- The session itself ran, and the report still says how it ended.
        linesWith "ticks committed: 5" out `shouldBe` ["ticks committed: 5"]

  describe "--expect-digest, which compares the final digest" $ do
    it "exits 0 for a digest that matches and names both digests on a mismatch, exiting 1" $
      withTempDirectory $ \directory → do
        let logPath = directory </> "log.txt"
        _ ← writeFixed logPath True
        (_, out, _) ← runExe ["--replay", logPath, "--ticks", "12", "--seed", "1"]
        let actual = finalDigest out
        runExe ["--replay", logPath, "--ticks", "12", "--seed", "1", "--expect-digest", actual] >>= \(status, _, err) → (status, err) `shouldBe` (ExitSuccess, "")
        let wrong = replicate 64 '0'
        (status, _, err) ← runExe ["--replay", logPath, "--ticks", "12", "--seed", "1", "--expect-digest", wrong]
        status `shouldBe` ExitFailure 1
        lines err `shouldBe` ["hetoimasia-lua-domains: digest mismatch: expected " <> wrong <> ", final " <> actual]
        -- A different seed is a different state, and the digest says so.
        (otherStatus, otherOut, _) ← runExe ["--replay", logPath, "--ticks", "12", "--seed", "2", "--expect-digest", actual]
        otherStatus `shouldBe` ExitFailure 1
        finalDigest otherOut `shouldNotBe` actual

    it "never overrides a failure's exit status: a failed session whose digest matches still exits 1, and the report says it failed" $
      withTempDirectory $ \directory → do
        -- The log holds no pause: a gameplay behavior that is paused in tick six never reaches the update that raises there.
        let logPath = directory </> "log.txt"
        _ ← writeFixed logPath False
        (failed, out, _) ← runExe ["--replay", logPath, "--ticks", "12", "--seed", "1", "--scenario", "failure"]
        failed `shouldBe` ExitFailure 1
        let actual = finalDigest out
        length actual `shouldBe` 64
        linesWith "status: failed at tick 6" out `shouldSatisfy` ((== 1) . length)
        (status, againOut, err) ← runExe ["--replay", logPath, "--ticks", "12", "--seed", "1", "--scenario", "failure", "--expect-digest", actual]
        -- The digest is the same (the replay is deterministic) and matches, and the failure is still the exit status.
        finalDigest againOut `shouldBe` actual
        err `shouldBe` ""
        status `shouldBe` ExitFailure 1
        -- It is not a complete replay, and the report says so.
        linesWith "replay: " out `shouldSatisfy` \found → case found of
          [line] → "incomplete (session failed at tick 6)" `isInfixOf` line
          _ → False

    it "ends a failed session's trace where its committed ticks end, and gives the final digest of the failure's snapshot" $
      withTempDirectory $ \directory → do
        let logPath = directory </> "log.txt"
        _ ← writeFixed logPath False
        (_, out, _) ← runExe ["--replay", logPath, "--ticks", "12", "--seed", "1", "--scenario", "failure", "--digests"]
        let traced = linesWith "digest " out
        length traced `shouldBe` 6
        -- Five ticks committed; the failure published one more snapshot and added no entry.
        map (take 64 . drop 9) traced `shouldNotContain` [finalDigest out]

  describe "the report" $
    it "names the final digest in the eleventh line and says nothing of a replay or a recording when there is none" $ do
      (status, out, _) ← runExe ["--ticks", "3"]
      status `shouldBe` ExitSuccess
      length (lines out) `shouldBe` 11
      forM_ ["replay: ", "record: ", "digest "] $ \prefix → linesWith prefix out `shouldBe` []
      lines out !! 10 `shouldSatisfy` ("final digest: " `isPrefixOf`)
