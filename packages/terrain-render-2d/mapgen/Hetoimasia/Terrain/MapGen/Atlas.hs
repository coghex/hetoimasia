-- | Generating, writing and checking the committed terrain atlases (TRA-17).
--
-- 'generateAtlases' is a pure function of the baked maps and the verified colour inputs: one
-- colour atlas (loam, granite, blank), one numeric normal atlas (the 46 catalog maps) and the
-- region manifest that places every logical identity, with no timestamp, absolute path or random
-- seed in any byte. The derivatives are the deliverable; the original whole-canvas maps and
-- colour art stay the authored sources, byte for byte, and are never read from or changed here.
--
-- 'writeAtlases' puts exactly those files into an explicit directory. 'checkAtlases'
-- regenerates into temporary storage and compares with a committed directory, naming every
-- missing, changed and unexpected file and, for the manifest, the first differing line; it never
-- writes there. Neither touches the facemap catalog directory.
--
-- State, ownership and lifetime: none beyond a temporary directory that 'checkAtlases' creates
-- and removes inside one bracket.
module Hetoimasia.Terrain.MapGen.Atlas
  ( atlasRecipeVersion
  , atlasDirectoryRelative
  , atlasManifestName
  , colourAtlasFile
  , normalAtlasFile
  , generateAtlases
  , atlasManifestOf
  , checkAtlases
  ) where

import Data.ByteString (ByteString)
import Data.Word (Word32)
import qualified Data.Map.Strict as Map
import Hetoimasia.Terrain.Atlas.Manifest
import Hetoimasia.Terrain.Atlas.Pack
import Hetoimasia.Terrain.MapBake.Catalog (catalogKeys, mapBytes, mapFileName, mapIdentifier)
import Hetoimasia.Terrain.MapGen.Generate (Discrepancy, compareCatalog, generate, readDirectory, writeCatalog)
import Hetoimasia.Terrain.MapGen.Inputs (ColourArt (..), Inputs (..), sha256Hex, textureDirectory)
import Hetoimasia.Terrain.MapGen.Json (Json (..), renderJson)
import Hetoimasia.Terrain.MapGen.Png (encodeRgba)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

-- | The atlas recipe: any change to the layout, the packing or the manifest's text raises it.
atlasRecipeVersion ∷ String
atlasRecipeVersion = "terrain-mapgen/atlas-1"

-- | The committed atlas directory under the sample directory, beside the facemap catalog.
atlasDirectoryRelative ∷ FilePath
atlasDirectoryRelative = textureDirectory </> "terrain-atlas"

atlasManifestName, colourAtlasFile, normalAtlasFile ∷ FilePath
atlasManifestName = "manifest.json"
colourAtlasFile = "colour.png"
normalAtlasFile = "normal.png"

repositoryTextures ∷ String
repositoryTextures = "samples/ecce-homo/content/textures/"

-- | Every generated file, by name relative to the atlas directory: the two PNGs, then the
-- manifest. Fails only if the inputs cannot be packed (a canvas of the wrong size).
generateAtlases ∷ Inputs → Either String [(FilePath, ByteString)]
generateAtlases inputs = do
  (_, files) ← atlasManifestOf inputs
  pure files

-- | The manifest and the files it describes.
atlasManifestOf ∷ Inputs → Either String (AtlasManifest, [(FilePath, ByteString)])
atlasManifestOf inputs = do
  colourPacked ← either (Left . describePackError) Right (packGrid colourColumns colourCanvases)
  normalPacked ← either (Left . describePackError) Right (packGrid normalColumns normalCanvases)
  let colourPng = png colourPacked
      normalPng = png normalPacked
      colourEntry = entry colourAtlasName colourAtlasFile colourKind colourProfile colourPng colourPacked colourSources
      normalEntry = entry normalAtlasName normalAtlasFile dataKind normalProfile normalPng normalPacked normalSources
      atlases = [colourEntry, normalEntry]
      manifest = AtlasManifest atlasRecipeVersion (layoutIdentity atlases) atlases
  pure (manifest, [(colourAtlasFile, colourPng), (normalAtlasFile, normalPng), (atlasManifestName, renderJson (manifestJson manifest))])
  where
    colourCanvases = [Canvas (colourRegionId (artName art)) texels | (art, _, texels) ← inputColour inputs]
    colourSources = Map.fromList [(colourRegionId (artName art), (repositoryTextures <> artFile art, artSha256 art)) | (art, _, _) ← inputColour inputs]
    normalCanvases = [Canvas (mapIdentifier key) (mapBytes key) | key ← catalogKeys]
    facemapPngs = Map.fromList (generate inputs)
    normalSources =
      Map.fromList
        [ (mapIdentifier key, (repositoryTextures <> "facemap/" <> mapFileName key, maybe "" sha256Hex (Map.lookup (mapFileName key) facemapPngs)))
        | key ← catalogKeys
        ]
    png packed = encodeRgba (fromIntegral (packedWidth packed)) (fromIntegral (packedHeight packed)) (packedTexels packed)
    entry name file kind profile bytes packed sources =
      AtlasEntry
        { atlasName = name
        , atlasFile = file
        , atlasWidth = packedWidth packed
        , atlasHeight = packedHeight packed
        , atlasKind = kind
        , atlasProfile = profile
        , atlasSha256 = sha256Hex bytes
        , atlasRegions =
            [ RegionEntry (placedId p) (placedX p) (placedY p) logicalWidth logicalHeight path sha
            | p ← packedPlacements packed
            , let (path, sha) = Map.findWithDefault ("", "") (placedId p) sources
            ]
        }

manifestJson ∷ AtlasManifest → Json
manifestJson manifest =
  JObject
    [ ("schema", JString manifestSchema)
    , ("recipe", JString (manifestRecipe manifest))
    , ("logical", JObject [("width", num logicalWidth), ("height", num logicalHeight)])
    , ("layoutIdentity", JString (layoutIdentityHex (manifestLayout manifest)))
    , ("atlases", JArray (map atlasJson (manifestAtlases manifest)))
    ]
  where
    num ∷ Word32 → Json
    num = JNumber . toInteger
    atlasJson a =
      JObject
        [ ("name", JString (atlasName a))
        , ("file", JString (atlasFile a))
        , ("width", num (atlasWidth a))
        , ("height", num (atlasHeight a))
        , ("kind", JString (atlasKind a))
        , ("profile", JString (atlasProfile a))
        , ("coverage", JString "binary")
        , ("sha256", JString (atlasSha256 a))
        , ("regions", JArray (map regionJson (atlasRegions a)))
        ]
    regionJson r =
      JObject
        [ ("id", JString (regionId r))
        , ("x", num (regionX r))
        , ("y", num (regionY r))
        , ("width", num (regionW r))
        , ("height", num (regionH r))
        , ("sourcePath", JString (regionSourcePath r))
        , ("sourceSha256", JString (regionSourceSha256 r))
        ]

-- | Regenerate into temporary storage and compare with a committed atlas directory, which is
-- only read. A generation failure is reported as a single changed manifest entry would be: the
-- text is returned as the problem.
checkAtlases ∷ Inputs → FilePath → IO (Either String [Discrepancy])
checkAtlases inputs committed = case generateAtlases inputs of
  Left why → pure (Left why)
  Right files → withSystemTempDirectory "terrain-mapgen-atlas-check" $ \scratch → do
    writeCatalog scratch files
    regenerated ← readDirectory scratch
    actual ← readDirectory committed
    pure (Right (compareCatalog regenerated actual))
