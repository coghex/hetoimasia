-- | Reading the scripts' files, and the identity each one is loaded under.
--
-- The host reads nothing from disk; the runner does, once for each distinct path, and hands the
-- host the bytes as a module. A read is bounded by the host's source limit: at most one byte past
-- it is read, and a file over it is refused.
module Hetoimasia.Scripting.Lua.Runner.Source
  ( ReadProblem (..)
  , readSources
  , distinctPaths
  , moduleRefFor
  , defaultName
  ) where

import Control.Exception (IOException, try)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.Scripting.Lua.Owner (ModuleRef (ModuleRef), maxIdentityLength, maxSourceBytes)
import System.IO (IOMode (ReadMode), hSetBinaryMode, withBinaryFile)
import System.IO.Error (ioeGetErrorString, isDoesNotExistError)

-- | Why a file was not read.
data ReadProblem
  = -- | It does not exist.
    ReadMissing
  | -- | It could not be opened or read: why, as the system said it.
    ReadUnreadable !Text
  | -- | It is larger than 'maxSourceBytes'.
    ReadTooLarge
  deriving (Eq, Show)

-- | The distinct paths of the scripts, in the order they first appear. A path is distinct by its
-- text: nothing is resolved or normalized, so two spellings of one file are two paths.
distinctPaths ∷ [FilePath] → [FilePath]
distinctPaths = nub

-- | Read the paths in order, each once, stopping at the first that cannot be read: the files
-- read before it, in order, and the problem.
readSources ∷ [FilePath] → IO ([(FilePath, ByteString)], Maybe (FilePath, ReadProblem))
readSources = go []
  where
    go done [] = pure (reverse done, Nothing)
    go done (path : rest) =
      readSource path >>= \case
        Right bytes → go ((path, bytes) : done) rest
        Left problem → pure (reverse done, Just (path, problem))

-- | One file. Only a failure to open or read is a problem; anything else, an asynchronous
-- exception included, is not the file's and propagates.
readSource ∷ FilePath → IO (Either ReadProblem ByteString)
readSource path = do
  read' ← try @IOException . withBinaryFile path ReadMode $ \handle → do
    hSetBinaryMode handle True
    -- At most one byte past the limit is asked for, so an enormous file costs no more to refuse
    -- than one just over it.
    ByteString.hGet handle (maxSourceBytes + 1)
  pure $ case read' of
    Left failure
      | isDoesNotExistError failure → Left ReadMissing
      | otherwise → Left (ReadUnreadable (Text.pack (ioeGetErrorString failure)))
    Right bytes
      | ByteString.length bytes > maxSourceBytes → Left ReadTooLarge
      | otherwise → Right bytes

-- | The identity a distinct path is loaded under: its place among the distinct paths of the run, a
-- colon, and the end of the path, with control characters replaced. Two distinct paths have distinct
-- places, so they never share an identity, whatever their file names; the identity is a function of
-- the run's scripts and nothing else, so it is the same for the same scripts every time; it fits the
-- host's rules, at most 'maxIdentityLength' bytes with no control character.
moduleRefFor ∷ Int → FilePath → ModuleRef
moduleRefFor place path = ModuleRef (prefix <> tailOf (maxIdentityLength - Text.length prefix) (Text.map tame (Text.pack path))) "1"
  where
    prefix = Text.pack (show place) <> ":"
    tame character
      | character < ' ' || character == '\DEL' = '.'
      | otherwise = character

-- | The last characters of a text that fit this many bytes of UTF-8.
tailOf ∷ Int → Text → Text
tailOf limit text = Text.pack (reverse (fit 0 (reverse (Text.unpack text))))
  where
    fit _ [] = []
    fit used (character : rest)
      | used + width character > limit = []
      | otherwise = character : fit (used + width character) rest
    width character = ByteString.length (Text.encodeUtf8 (Text.singleton character))

-- | The name an instance has when its script gave none: the last component of the path, or the whole
-- path when it ends in a separator.
defaultName ∷ FilePath → Text
defaultName path = case filter (not . Text.null) (reverse (Text.splitOn "/" (Text.pack path))) of
  component : _ → component
  [] → Text.pack path
