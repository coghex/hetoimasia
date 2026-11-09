-- | The style's asset snapshot from the loaded terrain atlases (TRA-17).
--
-- The generator ("terrain-mapgen --atlas-output") writes one colour atlas and one normal atlas
-- and a region manifest. At run time each parent image is decoded through the bounded decoder
-- with binary coverage requested, and the normal parent's opaque texels are validated against
-- @unit-normal-rgb-v1@; this module takes the results, a 'ParentAtlas' each, and builds the
-- 'AssetSnapshot' a plan and a picker read: a checked 'RegionView' per logical identity over
-- the parent's /one/ shared coverage plane, with no plane copied per region, quad or cell.
--
-- == Checks
--
-- Nothing usable is made unless every one holds, and the refusal names the first that does not:
-- the manifest is valid ('validateManifest'); each parent's coverage plane has the extent the
-- manifest states for its atlas; the colour parent carries no numeric profile and the normal
-- parent was checked against @unit-normal-rgb-v1@; every rectangle lies inside its parent
-- (checked by 'mkRegionView'); the parent's texture and coverage versions agree
-- ('mkColourAsset', 'mkMapAsset'); every catalog map and the blank colour has its region; and
-- every material names a colour region the manifest holds. A region's layout identity is the
-- manifest's, so a rectangle change on the same parent changes the snapshot's identity.
--
-- State, ownership and lifetime: none. Pure; the planes are the texture pipeline's immutable
-- values and this only names them.
module Hetoimasia.Terrain.Render2D.AtlasAssets
  ( ParentAtlas (..)
  , ParentKind (..)
  , AtlasAssetError (..)
  , describeAtlasAssetError
  , parentContentDigest
  , blankColourRegion
  , atlasAssetSnapshot
  ) where

import Data.Bits (shiftR, xor)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Word (Word32, Word64, Word8)
import Hetoimasia.Asset.Image.DataMap (CoveragePlane, NormalEncoding (..), coverageHeight, coverageWidth)
import Hetoimasia.Asset.Image.Region (RegionRefusal, mkRegionViewWith, regionRefusalText)
import Hetoimasia.Terrain.Atlas.Manifest
import Hetoimasia.Terrain.Cell (MaterialId)
import Hetoimasia.Terrain.MapBake.Catalog (catalogKeys, mapIdentifier)
import Hetoimasia.Terrain.Render2D.Assets

-- | What a parent image was decoded as: colour (premultiplied sRGB) or raw linear data.
data ParentKind = ColourParent | DataParent
  deriving stock (Eq, Show)

-- | One decoded parent image: the texture's version, the version of the coverage built from the
-- same decode, that coverage (one bit per texel of the whole image) and the numeric profile its
-- opaque texels were checked against, if it is a data atlas.
data ParentAtlas = ParentAtlas
  { parentTextureVersion ∷ !Word64
  , parentCoverageVersion ∷ !Word64
  , parentCoverage ∷ !CoveragePlane
  , parentProfile ∷ !(Maybe NormalEncoding)
  , parentKind ∷ !ParentKind
  , parentContent ∷ !Word64
  -- ^ A digest of the decoded image (kind, extent and every byte of level zero): the parent's
  -- identity, so two different images of one version and extent are never conflated.
  , parentLevels ∷ !Int
  -- ^ The mip levels the decode holds: sampling at texel centres at level zero is specified only
  -- for a single-level parent, so any other count is refused.
  }
  deriving stock (Eq, Show)

-- | Why a snapshot was not made.
data AtlasAssetError
  = AtlasManifestInvalid ![ManifestProblem]
  | -- | The atlas the manifest names is not in it.
    AtlasMissing !String
  | -- | The parent's extent is not the manifest's: the atlas, the parent's width and height, the
    -- manifest's width and height.
    AtlasParentExtent !String !Word32 !Word32 !Word32 !Word32
  | -- | The parent carries the wrong numeric profile for its atlas.
    AtlasParentProfile !String !(Maybe NormalEncoding)
  | -- | The parent was decoded as another kind than its atlas needs.
    AtlasParentKind !String !ParentKind
  | -- | The parent holds more or fewer than one level.
    AtlasParentLevels !String !Int
  | AtlasRegionRefused !String !RegionRefusal
  | -- | A material names a colour region the manifest does not hold.
    AtlasUnknownColour !String
  | AtlasAsset !AssetError
  deriving stock (Eq, Show)

describeAtlasAssetError ∷ AtlasAssetError → String
describeAtlasAssetError = \case
  AtlasManifestInvalid problems → "the atlas manifest is invalid: " <> unwords (map describeProblem problems)
  AtlasMissing name → "atlas " <> name <> " is not in the manifest"
  AtlasParentExtent name pw ph mw mh → "the loaded " <> name <> " atlas is " <> show pw <> " x " <> show ph <> ", the manifest says " <> show mw <> " x " <> show mh
  AtlasParentProfile name found → "the loaded " <> name <> " atlas was checked as " <> show found
  AtlasParentKind name found → "the loaded " <> name <> " atlas was decoded as " <> show found
  AtlasParentLevels name n → "the loaded " <> name <> " atlas holds " <> show n <> " levels, not one"
  AtlasRegionRefused identity why → "region " <> identity <> ": " <> regionRefusalText why
  AtlasUnknownColour identity → "no colour region " <> identity
  AtlasAsset why → "asset refused: " <> show why

-- | The digest of a decoded parent: FNV-1a over its kind, extent and every byte of level zero. It
-- identifies the image, so two different images of one version and extent differ; it is not a
-- security boundary (a stale or mismatched binding is a wrong answer, not an attack).
parentContentDigest ∷ ParentKind → (Word32, Word32) → ByteString → Word64
parentContentDigest kind (w, h) bytes = ByteString.foldl' step (foldl' step 14695981039346656037 header) bytes
  where
    header ∷ [Word8]
    header = [case kind of ColourParent → 1; DataParent → 2] <> concat [[fromIntegral (v `shiftR` (8 * k)) | k ← [0 .. 3]] | v ← [w, h]]
    step acc byte = (acc `xor` fromIntegral byte) * 1099511628211

-- | The colour region of the generic blank (fog) artwork.
blankColourRegion ∷ String
blankColourRegion = colourRegionId "blanktexture"

-- | The snapshot of one style from the manifest, the two loaded parents and the colour region
-- each material is drawn with.
atlasAssetSnapshot ∷ Word64 → AtlasManifest → ParentAtlas → ParentAtlas → [(MaterialId, String)] → Either AtlasAssetError AssetSnapshot
atlasAssetSnapshot version manifest colourParent normalParent materials = do
  case validateManifest manifest of
    [] → Right ()
    problems → Left (AtlasManifestInvalid problems)
  colourEntry ← entryOf colourAtlasName
  normalEntry ← entryOf normalAtlasName
  checkParent colourAtlasName colourEntry colourParent Nothing
  checkParent normalAtlasName normalEntry normalParent (Just UnitNormalRgbV1)
  let colourView = viewOf colourEntry colourParent
      normalView = viewOf normalEntry normalParent
  blankView ← colourView blankColourRegion
  blank ← first AtlasAsset (mkColourAsset ColourBlank (parentTextureVersion colourParent) (parentCoverageVersion colourParent) blankView)
  colours ← mapM (materialAsset colourView) materials
  maps ← mapM (mapAsset normalView) catalogKeys
  first AtlasAsset (mkAssetSnapshot version blank colours maps)
  where
    first f = either (Left . f) Right
    entryOf name = maybe (Left (AtlasMissing name)) Right (lookupAtlas name)
    lookupAtlas name = case [a | a ← manifestAtlases manifest, atlasName a == name] of
      a : _ → Just a
      [] → Nothing
    checkParent name entry parent expected
      | parentLevels parent /= 1 = Left (AtlasParentLevels name (parentLevels parent))
      | parentKind parent /= (if parentProfile' expected then DataParent else ColourParent) = Left (AtlasParentKind name (parentKind parent))
      | (coverageWidth plane, coverageHeight plane) /= (atlasWidth entry, atlasHeight entry) =
          Left (AtlasParentExtent name (coverageWidth plane) (coverageHeight plane) (atlasWidth entry) (atlasHeight entry))
      | parentProfile parent /= expected = Left (AtlasParentProfile name (parentProfile parent))
      | otherwise = Right ()
      where
        plane = parentCoverage parent
        parentProfile' = (/= Nothing)
    viewOf entry parent identity = case [r | r ← atlasRegions entry, regionId r == identity] of
      [] → Left (AtlasUnknownColour identity)
      r : _ → do
        rectangle ← first (AtlasRegionRefused identity) (regionRectangle r)
        first (AtlasRegionRefused identity) (mkRegionViewWith (parentContent parent) (parentCoverageVersion parent) (manifestLayout manifest) (parentCoverage parent) rectangle)
    materialAsset colourView (material, identity) = do
      view ← colourView identity
      asset ← first AtlasAsset (mkColourAsset (ColourMaterial material) (parentTextureVersion colourParent) (parentCoverageVersion colourParent) view)
      pure (material, asset)
    mapAsset normalView key = do
      view ← normalView (mapIdentifier key)
      asset ← first AtlasAsset (mkMapAsset key (parentTextureVersion normalParent) (parentCoverageVersion normalParent) (parentProfile normalParent) view)
      pure (key, asset)
