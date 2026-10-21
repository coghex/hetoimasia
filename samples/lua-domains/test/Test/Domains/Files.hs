-- | The files the executable's @--replay@ and @--record@ name (#500 requirement 7): reading a log with a bound on its size,
-- and writing one that is never an overwrite and never half of a log. Ownership of a recording is established by creating
-- it exclusively, so an entry that was there, a dangling symbolic link included, or that appears between the check and the
-- write, is never opened for writing; and the file this call created is removed on every way out of the write that is not the
-- log written whole, an interruption included.
module Test.Domains.Files (spec) where

import Control.Concurrent (killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), ErrorCall (ErrorCall), SomeException, fromException, throwIO, try)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as Lazy
import Hetoimasia.Sample.LuaDomains
  ( DomainsConfig (configTicks)
  , SessionReport
  , runSession
  )
import Hetoimasia.Sample.LuaDomains.Files
import Hetoimasia.Sample.LuaDomains.InputLog
import Hetoimasia.Sample.LuaDomains.Intention (Placement (..))
import Hetoimasia.Sample.LuaDomains.Report (RecordOutcome (..), finalExit, renderRecordLine)
import System.Directory (createDirectory, createFileLink, doesPathExist, removeFile)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.IO (IOMode (ReadWriteMode), hFlush, hPutStr, hSetFileSize, withBinaryFile)
import Test.Domains.Support
import Test.Hspec
import Test.Support.Bounded (bounded)
import qualified Data.Text as Text

sampleLog ∷ InputLog
sampleLog =
  logOf
    [ RecordControl 4 0 TargetGameplay OpPause
    , RecordIntention (Placement 5 0) ActsCurrent 4 3 0 1 (-2)
    , RecordIntention (Placement 5 1) ActsForeign 4 3 1 (-8) 8
    ]

-- | A short session's report, to say what the executable's exit status and report make of a recording.
shortReport ∷ IO SessionReport
shortReport = withSample (\config → config {configTicks = Just 3}) $ \_ _ domains → generous (runSession domains)

spec ∷ Spec
spec = describe "the files of the record and replay options" $ do
  describe "reading a log" $ do
    it "reads what a recording wrote, and nothing else of the file" $
      withTempDirectory $ \directory → do
        let path = directory </> "log.txt"
        writeLog path sampleLog `shouldReturn` Right ()
        loadLog path `shouldReturn` Right sampleLog

    it "refuses a path with nothing at it, a path that is not a file, a file that is no log, and a file larger than any log" $
      withTempDirectory $ \directory → do
        loadLog (directory </> "missing.txt") `shouldReturn` Left FileMissing
        loadLog directory `shouldReturn` Left FileUnreadable
        let bad = directory </> "bad.txt"
        ByteString.writeFile bad "not a log\n"
        malformed ← loadLog bad
        malformed `shouldSatisfy` \found → case found of
          Left (FileMalformed (LogRefusal 1 NotALog)) → True
          _ → False
        -- A file one byte over the most a log can be is refused without being read: it is a sparse file.
        let huge = directory </> "huge.txt"
        withBinaryFile huge ReadWriteMode (\handle → hSetFileSize handle (fromIntegral maxLogBytes + 1))
        loadLog huge `shouldReturn` Left FileTooLarge

  describe "the path a recording may be made at" $ do
    it "is one that names nothing, in a directory that is there" $
      withTempDirectory $ \directory → do
        checkOutputPath (directory </> "new.txt") `shouldReturn` Right ()
        checkOutputPath (directory </> "missing" </> "new.txt") `shouldReturn` Left DirectoryMissing

    it "is refused when anything is there already: a file, an empty file, a directory, and a symbolic link, dangling or not" $
      withTempDirectory $ \directory → do
        let file = directory </> "file.txt"
            empty = directory </> "empty.txt"
            dangling = directory </> "dangling.txt"
            live = directory </> "live.txt"
        ByteString.writeFile file "content"
        ByteString.writeFile empty ""
        createFileLink (directory </> "nowhere.txt") dangling
        createFileLink file live
        mapM_ (\path → checkOutputPath path `shouldReturn` Left PathExists) [file, empty, directory, dangling, live]

  describe "writing a recording" $ do
    it "writes a log whole, and a file that is there afterwards is the log" $
      withTempDirectory $ \directory → do
        let path = directory </> "log.txt"
        writeLog path sampleLog `shouldReturn` Right ()
        ByteString.readFile path `shouldReturn` Lazy.toStrict (renderLog sampleLog)

    it "never opens an existing entry for writing: a file, an empty file, a directory and a dangling link are left as they were" $
      withTempDirectory $ \directory → do
        let file = directory </> "file.txt"
            empty = directory </> "empty.txt"
            dangling = directory </> "dangling.txt"
            behind = directory </> "behind.txt"
        ByteString.writeFile file "precious"
        ByteString.writeFile empty ""
        createFileLink behind dangling
        mapM_ (\path → writeLog path sampleLog `shouldReturn` Left PathExists) [file, empty, directory, dangling]
        ByteString.readFile file `shouldReturn` "precious"
        ByteString.readFile empty `shouldReturn` ""
        -- The link was not followed: nothing was created where it points.
        doesPathExist behind `shouldReturn` False

    it "does not overwrite what appeared between the check and the write, and leaves it as it was" $
      withTempDirectory $ \directory → do
        let path = directory </> "log.txt"
        checkOutputPath path `shouldReturn` Right ()
        -- Someone else made the file after the check: the exclusive creation refuses, and what is there is not ours to remove.
        ByteString.writeFile path "someone else's"
        writeLog path sampleLog `shouldReturn` Left PathExists
        ByteString.readFile path `shouldReturn` "someone else's"
        -- The same for an empty file that appeared in that interval, which an open that creates when absent would have used.
        removeFile path
        ByteString.writeFile path ""
        writeLog path sampleLog `shouldReturn` Left PathExists
        ByteString.readFile path `shouldReturn` ""

    it "refuses a path in a directory that is not there, and creates nothing" $
      withTempDirectory $ \directory → do
        writeLog (directory </> "missing" </> "log.txt") sampleLog `shouldReturn` Left WriteFailed
        doesPathExist (directory </> "missing") `shouldReturn` False

    it "removes the file it created when the writing fails part-way, and says so" $
      withTempDirectory $ \directory → do
        let path = directory </> "log.txt"
        writeLogWith (\handle → hPutStr handle "half a log" >> hFlush handle >> ioError (userError "the disk filled")) path `shouldReturn` Left WriteFailed
        doesPathExist path `shouldReturn` False

    it "removes the file it created and lets a failure that is not an I/O failure propagate as itself" $
      withTempDirectory $ \directory → do
        let path = directory </> "log.txt"
        raised ← try @ErrorCall (writeLogWith (\handle → hPutStr handle "half" >> throwIO (ErrorCall "an example's own failure")) path)
        raised `shouldSatisfy` \found → case found of
          Left (ErrorCall "an example's own failure") → True
          _ → False
        doesPathExist path `shouldReturn` False

    it "removes the file it created when the writing is interrupted, and the interruption propagates as itself" $
      withTempDirectory $ \directory → do
        let path = directory </> "log.txt"
        wrote ← newEmptyMVar
        outcome ← newEmptyMVar
        never ← newEmptyMVar
        thread ←
          forkRegistered $ do
            result ← try @SomeException (writeLogWith (\handle → hPutStr handle "half a log" >> hFlush handle >> putMVar wrote () >> takeMVar never) path)
            putMVar outcome (either Just (const Nothing) result)
        -- The thread has created the file and written part of it, and waits where only an interruption can end it.
        bounded (takeMVar wrote)
        doesPathExist path `shouldReturn` True
        killThread thread
        interruption ← bounded (takeMVar outcome)
        (interruption >>= fromException) `shouldBe` Just ThreadKilled
        doesPathExist path `shouldReturn` False
        putMVar never ()

    it "says the partial file is left when the file it created cannot be removed, and never says it removed it" $
      withTempDirectory $ \directory → do
        let path = directory </> "log.txt"
        -- The writing replaces the file with a directory, which cannot be removed as a file.
        let replace handle = do
              hPutStr handle "x" >> hFlush handle
              removeFile path
              createDirectory path
              ioError (userError "failed")
        writeLogWith replace path `shouldReturn` Left WriteLeftPartial
        doesPathExist path `shouldReturn` True

    it "says a file that the writing itself removed is removed, not left" $
      withTempDirectory $ \directory → do
        let path = directory </> "log.txt"
        writeLogWith (\handle → hPutStr handle "x" >> hFlush handle >> removeFile path >> ioError (userError "failed")) path `shouldReturn` Left WriteFailed

  describe "what the report and the exit status say of a recording" $ do
    it "names a recording that was made, and exits as the session did" $ do
      report ← shortReport
      renderRecordLine (Recorded 3 "log.txt") `shouldBe` ["record: wrote 3 records to 'log.txt'"]
      finalExit report Nothing (Recorded 3 "log.txt") `shouldBe` ExitSuccess

    it "never claims a recording that was not made: it says it failed, and the session exits 1 for it" $ do
      report ← shortReport
      let failed = RecordFailed "log.txt" (fileProblemText WriteFailed)
      renderRecordLine failed `shouldSatisfy` \found → case found of
        [line] → "record: FAILED, nothing was recorded to 'log.txt'" `Text.isPrefixOf` line && not ("wrote" `Text.isInfixOf` line)
        _ → False
      finalExit report Nothing failed `shouldBe` ExitFailure 1
      renderRecordLine NotRecording `shouldBe` []

