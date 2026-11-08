-- | The approved artwork and the diagnostic sheet as the tests read them: the
-- committed PNGs found above the working directory, decoded by the production
-- decoder as colour art, and a manifest reader for the provenance record.
module Test.TerrainRender2D.Art
  ( Approved (..)
  , loadApproved
  , loadFile
  , sha256Hex
  , artPixelsOf
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
import Data.Text (pack)
import Hetoimasia.Asset (Asset (..), AssetId (..), Provenance (..))
import Hetoimasia.Asset.Image (DecodedImage (..), ImageKind (..))
import Hetoimasia.Asset.Image.Png (decodePng)
import Hetoimasia.Terrain.Render2D.Evidence (ArtPixels (..))
import Numeric (showHex)
import System.Directory (doesPathExist, getCurrentDirectory)
import System.FilePath (takeDirectory, (</>))

-- | An approved sheet: its bytes as committed, and as decoded.
data Approved = Approved
  { approvedName ∷ !String
  , approvedPath ∷ !FilePath
  , approvedBytes ∷ !ByteString.ByteString
  , approvedDecoded ∷ !DecodedImage
  }

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

-- | An approved sheet by its authored name, decoded as colour art.
loadApproved ∷ String → IO Approved
loadApproved name = do
  let relative = texturesDirectory </> (name <> ".png")
  path ← findUpwards relative
  bytes ← ByteString.readFile path
  case decodePng ColourImage (Asset (AssetId (pack name)) (FromFile path)) bytes of
    Left refusal → ioError (userError ("the approved " <> name <> " sheet was refused: " <> show refusal))
    Right decoded → pure (Approved name relative bytes decoded)

sha256Hex ∷ ByteString.ByteString → String
sha256Hex = concatMap two . ByteString.unpack . hash
  where
    two byte = (if byte < 16 then "0" else "") <> showHex byte ""

-- | A decoded sheet's level-0 texels (premultiplied sRGB) as 'ArtPixels'.
artPixelsOf ∷ DecodedImage → ArtPixels
artPixelsOf decoded =
  ArtPixels
    { artWidth = w
    , artHeight = h
    , artTexel = \x y →
        let base = 4 * (y * w + x)
         in (at base, at (base + 1), at (base + 2), at (base + 3))
    }
  where
    w = fromIntegral (decodedWidth decoded)
    h = fromIntegral (decodedHeight decoded)
    level = case decodedLevels decoded of
      first : _ → first
      [] → ByteString.empty
    at i = ByteString.index level i

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
