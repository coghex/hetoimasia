-- | The files the executable's @--replay@ and @--record@ name: reading an input log with a bound on its size, and writing
-- one without ever overwriting a file or leaving half of one behind (#500 requirement 7).
--
-- = Reading
--
-- A log is read only from an existing file that can be opened, whose size is no more than 'maxLogBytes' (a log's
-- greatest size), and whose bytes the parser of "Hetoimasia.Sample.LuaDomains.InputLog" accepts whole. Nothing is read
-- from a file that is larger, so a path to an enormous file costs nothing.
--
-- = Writing
--
-- An output path must not exist. The executable asks before the session starts ('checkOutputPath': the path is free and
-- its directory exists, so a session that cannot be recorded is not run for nothing) and writes after it has ended
-- ('writeLog'): the file is created at the path it was given and nowhere else, written whole and closed, and a write that
-- fails at any point removes the file it created and says so, so a file at that path is a complete log or is not ours. An
-- existing path of any kind is refused, and is never opened for writing.
module Hetoimasia.Sample.LuaDomains.Files
  ( loadLog
  , checkOutputPath
  , writeLog
  , FileProblem (..)
  , fileProblemText
  ) where

import Control.Exception (IOException, onException, try)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as Lazy
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Sample.LuaDomains.InputLog (InputLog, LogRefusal, maxLogBytes, parseLog, refusalText, renderLog)
import System.Directory (doesDirectoryExist, doesPathExist, removeFile)
import System.FilePath (takeDirectory)
import System.IO (IOMode (ReadMode, ReadWriteMode), hClose, hFileSize, hFlush, openBinaryFile)

-- | Why a file could not be read or written.
data FileProblem
  = -- | There is nothing at the path.
    FileMissing
  | -- | The path cannot be opened for reading.
    FileUnreadable
  | -- | The file is larger than any log can be.
    FileTooLarge
  | -- | The file is not a valid log: the refusal.
    FileMalformed !LogRefusal
  | -- | The path to write exists already.
    PathExists
  | -- | The directory the path is in does not exist.
    DirectoryMissing
  | -- | The file could not be created or written, and what was created has been removed.
    WriteFailed
  deriving (Eq, Show)

-- | A problem as fixed words, and for a malformed log the line's refusal, which names fixed words and numbers.
fileProblemText ∷ FileProblem → Text
fileProblemText = \case
  FileMissing → "no such file"
  FileUnreadable → "the file cannot be opened for reading"
  FileTooLarge → "the file is larger than the " <> Text.pack (show maxLogBytes) <> " bytes any log has"
  FileMalformed refusal → refusalText refusal
  PathExists → "the path exists, and a recording never overwrites"
  DirectoryMissing → "the directory the path is in does not exist"
  WriteFailed → "the file could not be written, so none was left"

-- | Read and parse a log from an existing file.
loadLog ∷ FilePath → IO (Either FileProblem InputLog)
loadLog path = do
  exists ← doesPathExist path
  if not exists
    then pure (Left FileMissing)
    else do
      read' ← try @IOException $ do
        handle ← openBinaryFile path ReadMode
        (do
            size ← hFileSize handle
            if size > fromIntegral maxLogBytes
              then pure (Left FileTooLarge)
              else Right <$> ByteString.hGet handle (fromInteger size))
          `onException` hClose handle
          <* hClose handle
      pure $ case read' of
        Left _ → Left FileUnreadable
        Right (Left problem) → Left problem
        Right (Right bytes) → either (Left . FileMalformed) Right (parseLog bytes)

-- | Whether a log can be written at this path: it does not exist, and its directory does.
checkOutputPath ∷ FilePath → IO (Either FileProblem ())
checkOutputPath path = do
  exists ← doesPathExist path
  directory ← doesDirectoryExist (takeDirectory path)
  pure $
    if exists
      then Left PathExists
      else if directory then Right () else Left DirectoryMissing

-- | Write a log to a path that does not exist, whole. A failure at any point removes the file this created.
writeLog ∷ FilePath → InputLog → IO (Either FileProblem ())
writeLog path log' = do
  exists ← doesPathExist path
  if exists
    then pure (Left PathExists)
    else do
      written ← try @IOException $ do
        handle ← openBinaryFile path ReadWriteMode
        size ← hFileSize handle `onException` hClose handle
        -- Something appeared between the check and the open: it is not ours, so it is left alone.
        if size /= 0
          then Left PathExists <$ hClose handle
          else do
            (Lazy.hPut handle (renderLog log') >> hFlush handle >> hClose handle) `onException` hClose handle
            pure (Right ())
      case written of
        Right outcome → pure outcome
        Left _ → do
          -- What this created is removed; if even that fails, the failure to write is still what is reported.
          _ ← try @IOException (removeFile path)
          pure (Left WriteFailed)
