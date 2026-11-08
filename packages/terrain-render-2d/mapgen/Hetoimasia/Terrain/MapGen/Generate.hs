-- | Generating, writing and checking the committed map catalog (TRA-14).
--
-- 'generate' is a pure function of the baked maps and the verified inputs: the
-- 46 PNG canvases and one machine-readable @manifest.json@, with no timestamp,
-- absolute path or random seed in any byte. 'writeCatalog' puts exactly those
-- files into an explicit directory. 'checkCatalog' regenerates into temporary
-- storage and compares it with a committed directory, reporting by identity and
-- path every missing, changed and unexpected file; it never writes there.
--
-- State, ownership and lifetime: none beyond a temporary directory that
-- 'checkCatalog' creates and removes inside one bracket.
module Hetoimasia.Terrain.MapGen.Generate
  ( recipeVersion
  , manifestName
  , generate
  , writeCatalog
  , Discrepancy (..)
  , describeDiscrepancy
  , compareCatalog
  , checkCatalog
  , inventory
  ) where

import Control.Monad (forM, forM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import Data.List (sort, sortOn)
import qualified Data.Map.Strict as Map
import Hetoimasia.Terrain.MapBake.Bake (canvasHeight, canvasWidth, normalProfile)
import Hetoimasia.Terrain.MapBake.Catalog
  ( Lookup (..)
  , MapKey (..)
  , allLookups
  , catalogBound
  , catalogKeys
  , facingName
  , mapBytes
  , mapFileName
  , mapIdentifier
  , roleName
  )
import Hetoimasia.Terrain.MapGen.Inputs (ColourArt (..), Inputs (..), sha256Hex, sourceRevision)
import Hetoimasia.Terrain.MapGen.Json (Json (..), renderJson)
import Hetoimasia.Terrain.MapGen.Png (encodeRgba)
import Hetoimasia.Terrain.Shape (shapeIdValue, shapeName)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

-- | The generator recipe: any change to the bake, the encoding or the layout of
-- the generated files raises it.
recipeVersion ∷ String
recipeVersion = "terrain-mapgen/1"

-- | The manifest's file name in the catalog directory.
manifestName ∷ FilePath
manifestName = "manifest.json"

-- | Every generated file, by name relative to the catalog directory: the PNG of
-- each authored map in catalog order, then the manifest.
generate ∷ Inputs → [(FilePath, ByteString)]
generate inputs = pngs <> [(manifestName, renderJson (manifest inputs pngs))]
  where
    pngs = [(mapFileName key, encodeRgba canvasWidth canvasHeight (mapBytes key)) | key ← catalogKeys]

opaqueTexels ∷ ByteString → Integer
opaqueTexels bytes = toInteger (length (filter (== 255) [ByteString.index bytes i | i ← [3, 7 .. ByteString.length bytes - 1]]))

manifest ∷ Inputs → [(FilePath, ByteString)] → Json
manifest inputs pngs =
  JObject
    [ ("schema", JString "hetoimasia.facemap-manifest/1")
    , ("recipe", JString recipeVersion)
    , ("profile", JString normalProfile)
    , ("kind", JString "data")
    , ("coverage", JString "binary")
    , ("encoding", JString "round(128 + 127 n) per component of the unit outward facet normal; decode by normalizing c - 128")
    , ("consumers", JString "load as kind data, coverage binary, normal_encoding unit-normal-rgb-v1: raw linear bytes, no gamma, no premultiplication")
    , ("canvas", JObject [("width", JNumber (toInteger canvasWidth)), ("height", JNumber (toInteger canvasHeight))])
    , ("projection", JString "u = 48 + 48 (x - y); v = 16 + 24 (x + y) - 16 z; X east, Y south, Z up; frontmost along (1, 1, 3)")
    , ("sampling", JString "texel centres (i + 1/2, j + 1/2); closed solid; ties to the first camera-facing facet in canonical order")
    , ("bound", JNumber (toInteger catalogBound))
    , ("maps", JArray (map mapEntry catalogKeys))
    , ("sharedBytes", JArray [JObject [("sha256", JString digest), ("maps", JArray (map JString ids))] | (digest, ids) ← shared])
    , ("lookup", JArray (map lookupEntry allLookups))
    , ("colourArt", JArray [colourEntry art bytes | (art, bytes, _) ← inputColour inputs])
    , ("provenance", JString "samples/ecce-homo/content/textures/provenance.json")
    ]
  where
    fileBytes = Map.fromList pngs
    digestOf key = maybe "" sha256Hex (Map.lookup (mapFileName key) fileBytes)
    mapEntry key@(MapKey role shape) =
      JObject
        [ ("id", JString (mapIdentifier key))
        , ("role", JString (roleName role))
        , ("shape", JNumber (toInteger (shapeIdValue shape)))
        , ("name", JString (shapeName shape))
        , ("path", JString (mapFileName key))
        , ("width", JNumber (toInteger canvasWidth))
        , ("height", JNumber (toInteger canvasHeight))
        , ("opaqueTexels", JNumber (opaqueTexels (mapBytes key)))
        , ("sha256", JString (digestOf key))
        ]
    shared =
      [ (digest, ids)
      | (digest, ids) ← Map.toAscList (Map.fromListWith (flip (<>)) [(digestOf key, [mapIdentifier key]) | key ← catalogKeys])
      , length ids > 1
      ]
    lookupEntry entry =
      JObject $
        [ ("facing", JString (facingName (lookupFacing entry)))
        , ("world", JNumber (toInteger (shapeIdValue (lookupWorld entry))))
        , ("view", JNumber (toInteger (shapeIdValue (lookupView entry))))
        , ("ordinary", JString (mapIdentifier (lookupOrdinary entry)))
        ]
          <> maybe [] (\(known, fog) → [("known", JString (mapIdentifier known)), ("fog", JString (mapIdentifier fog))]) (lookupMixed entry)
          <> [("fullFog", JString (mapIdentifier (lookupFullFog entry)))]
    colourEntry art bytes =
      JObject
        [ ("name", JString (artName art))
        , ("path", JString ("samples/ecce-homo/content/textures/" <> artFile art))
        , ("width", JNumber (toInteger canvasWidth))
        , ("height", JNumber (toInteger canvasHeight))
        , ("sha256", JString (sha256Hex bytes))
        , ("sourcePath", JString (artSourcePath art))
        , ("sourceRevision", JString sourceRevision)
        , ("treatment", JString "colour art, sRGB, binary alpha; imported byte for byte, never normal data")
        ]

-- | Write the generated files into a directory, creating it if needed. Files
-- of other names already there are left alone.
writeCatalog ∷ FilePath → [(FilePath, ByteString)] → IO ()
writeCatalog directory files = do
  createDirectoryIfMissing True directory
  forM_ files $ \(name, bytes) → ByteString.writeFile (directory </> name) bytes

-- | The inventory of a file set, one @sha256  name@ line each, sorted by name.
inventory ∷ [(FilePath, ByteString)] → [String]
inventory files = [sha256Hex bytes <> "  " <> name | (name, bytes) ← sortOn fst files]

-- | How a committed catalog differs from the regenerated one.
data Discrepancy
  = -- | A generated file the committed directory does not have.
    Missing FilePath
  | -- | A committed file that differs; for text, the first differing line.
    Changed FilePath String
  | -- | A committed file the generator does not produce.
    Unexpected FilePath
  deriving stock (Eq, Show)

describeDiscrepancy ∷ Discrepancy → String
describeDiscrepancy (Missing path) = "missing: " <> path
describeDiscrepancy (Changed path why) = "changed: " <> path <> " (" <> why <> ")"
describeDiscrepancy (Unexpected path) = "unexpected: " <> path

-- | The discrepancies between what a directory holds (name and bytes) and the
-- generated files, in path order.
compareCatalog ∷ [(FilePath, ByteString)] → [(FilePath, ByteString)] → [Discrepancy]
compareCatalog generated committed =
  sort' $
    [Missing name | (name, _) ← generated, Map.notMember name committedMap]
      <> [ Changed name (why name bytes committedBytes)
         | (name, bytes) ← generated
         , Just committedBytes ← [Map.lookup name committedMap]
         , committedBytes /= bytes
         ]
      <> [Unexpected name | (name, _) ← committed, Map.notMember name generatedMap]
  where
    generatedMap = Map.fromList generated
    committedMap = Map.fromList committed
    sort' = sortOn key
    key (Missing p) = (p, 0 ∷ Int)
    key (Changed p _) = (p, 1)
    key (Unexpected p) = (p, 2)
    why name expected actual
      | takeExtension' name == ".json" = firstLineDifference expected actual
      | otherwise = "SHA-256 " <> sha256Hex actual <> ", expected " <> sha256Hex expected
    takeExtension' name = dropWhile (/= '.') name

firstLineDifference ∷ ByteString → ByteString → String
firstLineDifference expected actual =
  case [(n, e, a) | (n, e, a) ← zip3 [1 ∷ Int ..] (padded expectedLines) (padded actualLines), e /= a] of
    (n, e, a) : _ → "line " <> show n <> ": found " <> show (Char8.unpack a) <> ", expected " <> show (Char8.unpack e)
    [] → "differs"
  where
    expectedLines = Char8.lines expected
    actualLines = Char8.lines actual
    longest = max (length expectedLines) (length actualLines)
    padded ls = ls <> replicate (longest - length ls) (Char8.pack "<absent>")

-- | The generated files regular files of a directory, by name; subdirectories
-- count as unexpected names too.
readDirectory ∷ FilePath → IO [(FilePath, ByteString)]
readDirectory directory = do
  present ← doesDirectoryExist directory
  if not present
    then pure []
    else do
      names ← sort <$> listDirectory directory
      fmap concat . forM names $ \name → do
        isFile ← doesFileExist (directory </> name)
        if isFile then (\bytes → [(name, bytes)]) <$> ByteString.readFile (directory </> name) else pure [(name <> "/", ByteString.empty)]

-- | Regenerate into temporary storage and compare it with a committed
-- directory. The committed directory is only read.
checkCatalog ∷ Inputs → FilePath → IO [Discrepancy]
checkCatalog inputs committed = withSystemTempDirectory "terrain-mapgen-check" $ \scratch → do
  writeCatalog scratch (generate inputs)
  regenerated ← readDirectory scratch
  actual ← readDirectory committed
  pure (compareCatalog regenerated actual)
