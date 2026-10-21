-- | The files the executable's @--replay@ and @--record@ name: reading an input log with a bound on its size, and writing
-- one without ever overwriting anything or leaving half of one behind (#500 requirement 7).
--
-- = Reading
--
-- A log is read only from an existing file that can be opened, whose size is no more than 'maxLogBytes' (a log's
-- greatest size), and whose bytes the parser of "Hetoimasia.Sample.LuaDomains.InputLog" accepts whole. Nothing is read
-- from a file that is larger, so a path to an enormous file costs nothing.
--
-- = Writing
--
-- An output path must not name anything. The executable asks before the session starts ('checkOutputPath': no directory
-- entry of any kind is there, a dangling symbolic link included, and the directory exists, so a session that cannot be
-- recorded is not run for nothing) and writes after it has ended ('writeLog').
--
-- Writing /creates/ the file exclusively (@O_CREAT | O_EXCL@, which refuses any existing entry, a dangling symbolic link
-- included, and never follows one), so a file this call has is a file this call made, whatever happened since the check:
-- ownership is established by the creation itself. The file is a resource of the call's own scope
-- ('Hetoimasia.Foundation.Resource.withResource'): its release closes the handle and, unless the log was written whole and
-- closed, removes the file, on every way out: a failed write, a failed close, and an asynchronous exception (an interrupt, a
-- cancellation) alike, which then propagates as itself. A failed creation runs no release, so a path this call did not
-- create is never touched. A file at the path is therefore a complete log, or is not this call's; an existing path is never
-- opened for writing.
module Hetoimasia.Sample.LuaDomains.Files
  ( loadLog
  , checkOutputPath
  , writeLog
  , writeLogWith
  , FileProblem (..)
  , fileProblemText
  ) where

import Control.Exception (IOException, onException, throwIO, try)
import Control.Monad (void, when)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as Lazy
import Data.Either (isLeft)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Resource (withResource)
import Hetoimasia.Sample.LuaDomains.InputLog (InputLog, LogRefusal, maxLogBytes, parseLog, refusalText, renderLog)
import System.Directory (doesDirectoryExist, doesPathExist, pathIsSymbolicLink, removeFile)
import System.FilePath (takeDirectory)
import System.IO (Handle, IOMode (ReadMode), hClose, hFileSize, hFlush, openBinaryFile)
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import System.Posix.IO (OpenFileFlags (creat, exclusive), OpenMode (WriteOnly), closeFd, defaultFileFlags, fdToHandle, openFd)

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
  | -- | The path to write names something already, a dangling symbolic link included.
    PathExists
  | -- | The directory the path is in does not exist.
    DirectoryMissing
  | -- | The file could not be created or written, and what was created has been removed.
    WriteFailed
  | -- | The file could not be written and the partial file this call created could not be removed: it is left, and is not a
    -- log.
    WriteLeftPartial
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
  WriteFailed → "the file could not be written, and the file created for it has been removed"
  WriteLeftPartial → "the file could not be written, and the partial file created for it could not be removed"

-- | Read and parse a log from an existing file.
loadLog ∷ FilePath → IO (Either FileProblem InputLog)
loadLog path = do
  exists ← doesPathExist path
  if not exists
    then pure (Left FileMissing)
    else do
      read' ← try @IOException $
        withResource (openBinaryFile path ReadMode) hClose $ \handle → do
          size ← hFileSize handle
          if size > fromIntegral maxLogBytes
            then pure (Left FileTooLarge)
            else Right <$> ByteString.hGet handle (fromInteger size)
      pure $ case read' of
        Left _ → Left FileUnreadable
        Right (Left problem) → Left problem
        Right (Right bytes) → either (Left . FileMalformed) Right (parseLog bytes)

-- | Whether the path names anything at all: a file, a directory, or a symbolic link, dangling or not.
entryExists ∷ FilePath → IO Bool
entryExists path = do
  exists ← doesPathExist path
  if exists then pure True else either (const False) id <$> try @IOException (pathIsSymbolicLink path)

-- | Whether a log can be written at this path: nothing is there, and its directory is.
checkOutputPath ∷ FilePath → IO (Either FileProblem ())
checkOutputPath path = do
  exists ← entryExists path
  directory ← doesDirectoryExist (takeDirectory path)
  pure $
    if exists
      then Left PathExists
      else if directory then Right () else Left DirectoryMissing

-- | Write a log to a path that names nothing, whole, as the module header describes.
writeLog ∷ FilePath → InputLog → IO (Either FileProblem ())
writeLog path log' = writeLogWith (\handle → Lazy.hPut handle (renderLog log')) path

-- | 'writeLog' with the writing itself given: what it puts in the file it created. An example gives one that fails, or that
-- waits to be interrupted, part-way, to show what is left; what 'writeLog' writes is the log.
writeLogWith ∷ (Handle → IO ()) → FilePath → IO (Either FileProblem ())
writeLogWith write path = do
  completed ← newIORef False
  couldNotRemove ← newIORef False
  written ← try @IOException $
    withResource (createExclusive path) (release completed couldNotRemove) $ \handle → do
      write handle
      hFlush handle
      writeIORef completed True
  stuck ← readIORef couldNotRemove
  pure $ case written of
    Right () → Right ()
    Left failure
      | isAlreadyExistsError failure → Left PathExists
      | stuck → Left WriteLeftPartial
      | otherwise → Left WriteFailed
  where
    -- Closing a handle this call owns and removing a file it created are bounded. The file is kept only if the log was
    -- written whole and closed; a close that fails is a failure of the write, and the file goes with it.
    release completed couldNotRemove handle = do
      closed ← try @IOException (hClose handle)
      done ← readIORef completed
      when (not done || isLeft closed) (removeOwned couldNotRemove)
      either throwIO pure closed
    removeOwned couldNotRemove = do
      removed ← try @IOException (removeFile path)
      -- A file that is not there is removed.
      case removed of
        Left failure | not (isDoesNotExistError failure) → writeIORef couldNotRemove True
        _ → pure ()

-- | Create the file, which must not exist, and answer its handle. The creation, which refuses any existing entry and never
-- follows a link, is the only thing that makes the file this call's; a failure after it removes what it made.
createExclusive ∷ FilePath → IO Handle
createExclusive path = do
  fd ← openFd path WriteOnly defaultFileFlags {creat = Just 0o644, exclusive = True}
  fdToHandle fd `onException` (closeFd fd >> removeQuietly)
  where
    removeQuietly = void (try @IOException (removeFile path))
