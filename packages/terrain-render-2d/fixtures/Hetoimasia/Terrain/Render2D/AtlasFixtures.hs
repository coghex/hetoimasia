-- | The committed packed atlases as the evidence and the CPU suites load them (TRA-17).
--
-- One call finds the sample directory above the working directory, parses the region manifest,
-- decodes each parent image once through the bounded PNG decoder (the colour parent as colour, the
-- normal parent as data), and builds, from that one decode, everything the callers need:
-- the shared coverage plane of each parent (through the generic data-map functions, with the
-- normal parent's opaque texels checked against @unit-normal-rgb-v1@), the style's
-- 'AssetSnapshot' and the independently decoded source canvases the hand model reads. The
-- decoded atlas texels are returned too, so the device evidence uploads the same bytes the
-- coverage was built from. It starts no thread and holds no resource; a caller owns what it
-- uploads.
--
-- State, ownership and lifetime: none. A load reads files and returns values.
module Hetoimasia.Terrain.Render2D.AtlasFixtures
  ( AtlasStyle (..)
  , loadAtlasStyle
  , findSampleDirectory
  , materialIdOf
  ) where

import Control.Monad (forM)
import qualified Data.ByteString as ByteString
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import qualified Data.Text as Text
import Hetoimasia.Asset (Asset (..), AssetId (..), Provenance (..))
import Hetoimasia.Asset.Image (DecodedImage (..))
import Hetoimasia.Asset.Image.DataMap (NormalEncoding (..), buildBinaryCoverage, checkNormalEncoding)
import Hetoimasia.Asset.Image.PngDecode (DecodePolicy (..), PayloadAccount (..), decodeBoundedWith, m1WorkspaceBytes)
import Hetoimasia.Asset.Image.PngPreflight (m1PngLimits, preflightPng)
import Hetoimasia.Terrain.Atlas.Manifest
import Hetoimasia.Terrain.Cell (MaterialId, mkMaterialId)
import Hetoimasia.Terrain.MapGen.Png (decodeRgba)
import Hetoimasia.Terrain.Render2D.Assets (AssetSnapshot)
import Hetoimasia.Terrain.Render2D.AtlasAssets (ParentAtlas (..), atlasAssetSnapshot)
import Hetoimasia.Terrain.Render2D.Evidence (ArtSource (..))
import System.Directory (doesDirectoryExist, getCurrentDirectory)
import System.FilePath (takeDirectory, (</>))

-- | A loaded style of the committed atlases.
data AtlasStyle = AtlasStyle
  { styleManifest ∷ !AtlasManifest
  , styleColour ∷ !ParentAtlas
  , styleNormal ∷ !ParentAtlas
  , styleColourImage ∷ !DecodedImage
  -- ^ The colour parent as the bounded decoder produced it (premultiplied sRGB colour).
  , styleNormalImage ∷ !DecodedImage
  -- ^ The normal parent as decoded data (raw linear bytes).
  , styleNormalAsColour ∷ !DecodedImage
  -- ^ The same file decoded wrongly, as colour (sRGB, premultiplied): the negative control's
  -- wrong colour-versus-data treatment. Never the style's own texture.
  , styleAssets ∷ !AssetSnapshot
  , styleArt ∷ !ArtSource
  -- ^ The source canvases, decoded independently of the atlases.
  }

-- | The nearest @samples/ecce-homo@ at or above the working directory.
findSampleDirectory ∷ IO FilePath
findSampleDirectory = getCurrentDirectory >>= go
  where
    go directory = do
      let candidate = directory </> "samples" </> "ecce-homo"
      found ← doesDirectoryExist candidate
      if found
        then pure candidate
        else
          let parent = takeDirectory directory
           in if parent == directory then ioError (userError "no samples/ecce-homo above the working directory") else go parent

-- | The material identity of an authored name.
materialIdOf ∷ String → IO MaterialId
materialIdOf name = either (\e → ioError (userError (show e))) pure (mkMaterialId name)

-- | Load the committed atlases at one parent version, with the listed materials drawn with the
-- listed colour regions (an authored name and a colour identity such as @colour.loam@).
loadAtlasStyle ∷ Word64 → [(String, String)] → IO AtlasStyle
loadAtlasStyle version materials = do
  sample ← findSampleDirectory
  let atlasDirectory = sample </> "content" </> "textures" </> "terrain-atlas"
      repositoryRoot = takeDirectory (takeDirectory sample)
      failWith what why = ioError (userError (what <> ": " <> why))
  manifestBytes ← ByteString.readFile (atlasDirectory </> "manifest.json")
  manifest ← either (failWith "the atlas manifest" . unlines) pure (parseManifest manifestBytes)
  let account = PayloadAccount (\_ n → pure (n <= m1WorkspaceBytes)) (\_ _ → pure ())
      parent file policy profile = do
        let path = atlasDirectory </> file
        bytes ← ByteString.readFile path
        preflighted ← either (failWith file . show) pure (preflightPng m1PngLimits (Asset (AssetId (Text.pack file)) (FromFile path)) bytes)
        image ← decodeBoundedWith policy account preflighted >>= either (failWith file . show) pure
        level ← case decodedLevels image of
          first : _ → pure first
          [] → failWith file "the decode holds no level"
        let (w, h) = (decodedWidth image, decodedHeight image)
        case profile of
          Just encoding → either (failWith file . show) pure (checkNormalEncoding encoding w h level)
          Nothing → pure ()
        plane ← either (failWith file . show) pure (buildBinaryCoverage w h level)
        pure (ParentAtlas version version plane profile, image)
  (colour, colourImage) ← parent "colour.png" DecodeColour Nothing
  (normal, normalImage) ← parent "normal.png" DecodeData (Just UnitNormalRgbV1)
  (_, normalAsColour) ← parent "normal.png" DecodeColour Nothing
  ids ← forM materials $ \(name, regionName) → (\identity → (identity, regionName)) <$> materialIdOf name
  assets ← either (failWith "the atlas assets" . show) pure (atlasAssetSnapshot version manifest colour normal ids)
  -- The source canvases, from the paths the manifest records, decoded on their own.
  let sources = [(regionId r, regionSourcePath r) | a ← manifestAtlases manifest, r ← atlasRegions a]
  canvases ← forM sources $ \(identity, path) → do
    bytes ← ByteString.readFile (repositoryRoot </> path)
    (_, _, texels) ← either (failWith path) pure (decodeRgba bytes)
    pure (identity, texels)
  let table = Map.fromList canvases
      colourNames = [("loam", "colour.loam"), ("granite", "colour.granite"), ("blanktexture", "colour.blanktexture")]
      colourTable = Map.fromList [(name, Map.findWithDefault ByteString.empty identity table) | (name, identity) ← colourNames]
      texelOf canvasTable name x y = case Map.lookup name canvasTable of
        Nothing → (0, 0, 0, 0)
        Just bytes →
          let base = 4 * (y * 96 + x)
              at i = ByteString.index bytes (base + i)
           in (at 0, at 1, at 2, at 3)
  pure
    AtlasStyle
      { styleManifest = manifest
      , styleColour = colour
      , styleNormal = normal
      , styleColourImage = colourImage
      , styleNormalImage = normalImage
      , styleNormalAsColour = normalAsColour
      , styleAssets = assets
      , styleArt = ArtSource {artColour = texelOf colourTable, artMap = texelOf table}
      }
