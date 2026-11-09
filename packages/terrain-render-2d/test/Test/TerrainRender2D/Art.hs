-- | The committed artwork as the tests find and read it: files found above the working directory,
-- their digests and a manifest reader for the provenance record.
module Test.TerrainRender2D.Art
  ( loadFile
  , sha256Hex
  , Json (..)
  , parseJson
  , field
  , texturesDirectory
  , findUpwards
  ) where

import Crypto.Hash.SHA256 (hash)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import Data.Char (isDigit, isSpace)
import Numeric (showHex)
import System.Directory (doesPathExist, getCurrentDirectory)
import System.FilePath (takeDirectory, (</>))

-- | The directory the approved artwork is committed in, relative to the repository root.
texturesDirectory ∷ FilePath
texturesDirectory = "samples/ecce-homo/content/textures"

-- | A path found under the working directory or one of its parents: the suite runs
-- from a package directory (@cabal test@) or from the repository root.
findUpwards ∷ FilePath → IO FilePath
findUpwards relative = getCurrentDirectory >>= go
  where
    go directory = do
      found ← doesPathExist (directory </> relative)
      if found
        then pure (directory </> relative)
        else
          let parent = takeDirectory directory
           in if parent == directory then ioError (userError ("not found above the working directory: " <> relative)) else go parent

-- | The bytes of a file of the repository, by path from its root.
loadFile ∷ FilePath → IO ByteString.ByteString
loadFile relative = findUpwards relative >>= ByteString.readFile

sha256Hex ∷ ByteString.ByteString → String
sha256Hex = concatMap two . ByteString.unpack . hash
  where
    two byte = (if byte < 16 then "0" else "") <> showHex byte ""

-- ---------------------------------------------------------------------------
-- A small JSON reader for the provenance manifest

data Json
  = JObject [(String, Json)]
  | JArray [Json]
  | JString String
  | JNumber Integer
  deriving stock (Eq, Show)

field ∷ String → Json → Maybe Json
field name (JObject fields) = lookup name fields
field _ _ = Nothing

-- | The whole of a document, or why it is not one.
parseJson ∷ ByteString.ByteString → Either String Json
parseJson bytes = case value (dropWhile isSpace (Char8.unpack bytes)) of
  Right (json, rest) | all isSpace rest → Right json
  Right (_, rest) → Left ("trailing text: " <> take 20 rest)
  Left why → Left why
  where
    value text = case text of
      '{' : rest → object (dropWhile isSpace rest) []
      '[' : rest → array (dropWhile isSpace rest) []
      '"' : rest → fmap (\(s, more) → (JString s, more)) (string rest "")
      c : _ | isDigit c || c == '-' →
        let (digits, more) = span (\d → isDigit d || d == '-') text
         in Right (JNumber (read digits), more)
      _ → Left ("unexpected text: " <> take 20 text)
    object text acc = case text of
      '}' : rest → Right (JObject (reverse acc), rest)
      ',' : rest → object (dropWhile isSpace rest) acc
      '"' : rest → do
        (key, afterKey) ← string rest ""
        case dropWhile isSpace afterKey of
          ':' : afterColon → do
            (json, more) ← value (dropWhile isSpace afterColon)
            object (dropWhile isSpace more) ((key, json) : acc)
          other → Left ("expected a colon: " <> take 20 other)
      other → Left ("expected a key: " <> take 20 other)
    array text acc = case text of
      ']' : rest → Right (JArray (reverse acc), rest)
      ',' : rest → array (dropWhile isSpace rest) acc
      _ → do
        (json, more) ← value text
        array (dropWhile isSpace more) (json : acc)
    string text acc = case text of
      '"' : rest → Right (reverse acc, rest)
      '\\' : c : rest → string rest (c : acc)
      c : rest → string rest (c : acc)
      [] → Left "an unterminated string"
