-- | A terrain view's style (TRA-9): the two atlas parents of the owning instance, their shared coverage planes and
-- the checked region mapping, acquired as the view's own interests.
--
-- = What a style is
--
-- The colour atlas (loam, granite, blank and any other material colour) and the normal atlas (the catalog's 46
-- maps), each one texture the owning instance loaded through its own pipeline and holds by lease, with the region
-- manifest (#659) that names every 96 x 64 logical region and the materials' colour regions. The style holds no
-- shader source, sampler, filter, tint or callback: the material, its region-local nearest sampling and its binary
-- cutout are fixed by @terrain-render-2d-vulkan@.
--
-- = Authority
--
-- Each parent is retained through the owning instance's own lease collection ('retainTexture'), so a parent the
-- instance does not hold (released, ended, another instance's, or never a texture) is refused there, and an authored
-- identifier or a raw handle is never accepted. A retained parent pairs the registration's identity, its
-- dimensions, its one coverage plane and its checked profile from one loaded version, so a recycled slot or a
-- reused generation can never bind an old plane to a new texture. The CPU interest so taken lasts until the view
-- closes, whatever happens to the instance's lease afterwards. The continuing GPU interest is taken separately, in
-- the attachment's commit transaction ("Hetoimasia.LuaEngine.Graphics.TerrainView.Service").
--
-- = Refusals
--
-- Every refusal here is a 'StyleRefusal', distinct from busy: a parent the lease refuses, a parent of the wrong kind
-- or profile, a coverage plane the version no longer holds, an incomplete or invalid manifest mapping, a parent the
-- manifest's extent does not match, a material without a colour region, or parents whose bytes exceed the owning
-- instance's texture byte limit. A refusal leaves nothing retained: whatever was retained before it is released
-- before it is answered.
module Hetoimasia.LuaEngine.Graphics.TerrainView.Style
  ( -- * The request
    StyleRequest (..)
  , ParentRole (..)

    -- * Refusals
  , StyleRefusal (..)
  , describeStyleRefusal

    -- * The acquired style
  , AcquiredStyle
  , styleAssets
  , styleTextures
  , styleIdentities
  , styleColourHandle
  , styleNormalHandle
  , styleNominalBytes
  , styleMappedMaterials
  , acquireStyle
  , releaseStyle

    -- * The pure check
  , StyleParent (..)
  , checkStyle
  , parentNominalBytes
  ) where

import Control.Concurrent.STM (atomically)
import Control.Exception (mask, onException)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word64)
import Hetoimasia.Asset.Image.DataMap (CoveragePlane, NormalEncoding (UnitNormalRgbV1))
import Hetoimasia.LuaEngine.Graphics.Texture (textureHandleOf)
import Hetoimasia.LuaEngine.Texture
  ( RetainedTexture
  , TextureKind (..)
  , TextureRequirement (..)
  , TextureView (..)
  , releaseRetained
  , retainTexture
  , retainedCoverage
  , retainedKind
  , retainedNormal
  , retainedVersion
  , retainedView
  )
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Scripting.Lua.Lease (Leases)
import Hetoimasia.Terrain.Atlas.Manifest (AtlasManifest)
import Hetoimasia.Terrain.Cell (MaterialId)
import Hetoimasia.Terrain.Render2D.Assets (AssetSnapshot)
import Hetoimasia.Terrain.Render2D.AtlasAssets (AtlasAssetError, ParentAtlas (..), ParentKind (..), atlasAssetSnapshot, describeAtlasAssetError)
import Hetoimasia.Terrain.Render2D.Material (AtlasTextures, BindRefusal, bindColourParent, bindDataParent, packedTextures)

-- | What an attachment names as its style: the owning instance's lease collection and its leases of the two
-- parents, the region manifest and the materials' colour regions.
data StyleRequest = StyleRequest
  { styleLeases ∷ !Leases
  , styleColourLease ∷ !Word64
  , styleNormalLease ∷ !Word64
  , styleManifest ∷ !AtlasManifest
  , styleMaterials ∷ ![(MaterialId, String)]
  , styleInstanceTextureBytes ∷ !Word64
    -- ^ The owning instance's texture byte limit (the profile's per-instance allowance): a style whose parents'
    -- charged bytes exceed it is refused, however they came to be held.
  }

-- | Which parent a refusal is about.
data ParentRole = ColourRole | NormalRole
  deriving (Eq, Show)

-- | Why a style was refused. Never busy: asking again with the same style changes nothing.
data StyleRefusal
  = -- | The owning instance's lease refused the parent: released, ended, another instance's or not a texture.
    ParentRefused !ParentRole !Text
  | -- | The parent's version lacks what its role needs (the lease's requirement text).
    ParentUnsuitable !ParentRole !Text
  | -- | The parent's version no longer holds its coverage plane.
    ParentCoverageGone !ParentRole
  | -- | The parent cannot be bound to its role (kind, levels or profile).
    ParentNotBindable !ParentRole !BindRefusal
  | -- | The manifest, a parent's extent or profile, or the materials' regions do not make a complete mapping.
    StyleMapping !AtlasAssetError
  | -- | The parents' charged bytes exceed the owning instance's texture byte limit: what they need, and the limit.
    StyleExceedsTextureBytes !Word64 !Word64
  | -- | The mapping names no region for these materials of the arena's palette: the planner could never draw them.
    StyleMissingMaterials ![MaterialId]
  deriving (Eq, Show)

-- | A refusal as bounded text: fixed words and numbers.
describeStyleRefusal ∷ StyleRefusal → Text
describeStyleRefusal = \case
  ParentRefused role why → roleName role <> " parent refused: " <> why
  ParentUnsuitable role why → roleName role <> " parent unsuitable: " <> why
  ParentCoverageGone role → roleName role <> " parent holds no coverage"
  ParentNotBindable role why → roleName role <> " parent cannot be bound: " <> Text.pack (show why)
  StyleMapping why → "the style's mapping is incomplete: " <> Text.pack (describeAtlasAssetError why)
  StyleExceedsTextureBytes need limit → "the style's parents need " <> number need <> " texture bytes of " <> number limit
  StyleMissingMaterials missing → "the style's mapping has no region for the arena's materials " <> Text.intercalate ", " (map (Text.pack . show) missing)
  where
    number = Text.pack . show
    roleName ColourRole = "the colour"
    roleName NormalRole = "the normal"

-- | One parent as the pure check reads it: the registration's identity, extent, coverage, profile and kind, the
-- loaded version, and how many levels it holds.
data StyleParent = StyleParent
  { parentIdentity ∷ !Word64
  , parentVersion ∷ !Word64
  , parentWidth ∷ !Word32
  , parentHeight ∷ !Word32
  , parentPlane ∷ !CoveragePlane
  , parentEncoding ∷ !(Maybe NormalEncoding)
  , parentIsData ∷ !Bool
  , parentLevelCount ∷ !Int
  }

-- | The bytes a parent is charged in the texture byte banks: four a texel, at least 4 KiB (#672).
parentNominalBytes ∷ StyleParent → Word64
parentNominalBytes parent = max 4096 (fromIntegral (parentWidth parent) * fromIntegral (parentHeight parent) * 4)

-- | The whole style check, pure: the asset snapshot over the two parents' shared planes and the bound textures,
-- or the first refusal. The asset snapshot's version folds in both parents' versions.
checkStyle ∷ Word64 → AtlasManifest → [(MaterialId, String)] → StyleParent → StyleParent → Either StyleRefusal (AssetSnapshot, AtlasTextures)
checkStyle limit manifest materials colour normal = do
  let need = parentNominalBytes colour + parentNominalBytes normal
  if need > limit then Left (StyleExceedsTextureBytes need limit) else Right ()
  -- each parent's kind is its own; the role's binding refuses a parent of the other kind
  let colourAtlas = atlasOf colour
      normalAtlas = atlasOf normal
  assets ← either (Left . StyleMapping) Right (atlasAssetSnapshot (parentVersion colour * 65536 + parentVersion normal) manifest colourAtlas normalAtlas materials)
  colourTexture ← either (Left . ParentNotBindable ColourRole) Right (bindColourParent colourAtlas (textureHandleOf (parentIdentity colour)))
  normalTexture ← either (Left . ParentNotBindable NormalRole) Right (bindDataParent normalAtlas (textureHandleOf (parentIdentity normal)))
  pure (assets, packedTextures colourTexture normalTexture)
  where
    atlasOf parent =
      ParentAtlas
        { parentTextureVersion = parentVersion parent
        , parentCoverageVersion = parentVersion parent
        , parentCoverage = parentPlane parent
        , parentProfile = parentEncoding parent
        , parentKind = if parentIsData parent then DataParent else ColourParent
        , -- A loaded version is issued once by the pipeline and names exactly one decode: it is the image's identity.
          parentContent = parentVersion parent
        , parentLevels = parentLevelCount parent
        }

-- | A style the view holds: both parents' CPU interests, the checked asset snapshot and the bound textures.
data AcquiredStyle = AcquiredStyle
  { acqColour ∷ !RetainedTexture
  , acqNormal ∷ !RetainedTexture
  , acqAssets ∷ !AssetSnapshot
  , acqTextures ∷ !AtlasTextures
  , acqNominal ∷ !Word64
  , acqMaterials ∷ !(Set MaterialId)
    -- ^ The materials the mapping gives a region: the arena's palette must be among them.
  }

-- | The materials the style's mapping gives a region.
styleMappedMaterials ∷ AcquiredStyle → Set MaterialId
styleMappedMaterials = acqMaterials

styleAssets ∷ AcquiredStyle → AssetSnapshot
styleAssets = acqAssets

styleTextures ∷ AcquiredStyle → AtlasTextures
styleTextures = acqTextures

-- | The two parents' complete registration identities, which the view's GPU interests and its scenes name.
styleIdentities ∷ AcquiredStyle → Set Word64
styleIdentities style = Set.fromList [viewIdentity (retainedView (acqColour style)), viewIdentity (retainedView (acqNormal style))]

styleColourHandle, styleNormalHandle ∷ AcquiredStyle → TextureHandle
styleColourHandle = textureHandleOf . viewIdentity . retainedView . acqColour
styleNormalHandle = textureHandleOf . viewIdentity . retainedView . acqNormal

-- | The parents' charged texture bytes, as the existing banks hold them (not charged again here).
styleNominalBytes ∷ AcquiredStyle → Word64
styleNominalBytes = acqNominal

-- | Retain both parents through the owning instance's leases and check the style. On a refusal, or an exception,
-- nothing stays retained.
acquireStyle ∷ StyleRequest → IO (Either StyleRefusal AcquiredStyle)
acquireStyle request = mask $ \restore →
  retainTexture (styleLeases request) (styleColourLease request) (TextureRequirement (Just ColourKind) True Nothing) >>= \case
    Left why → pure (Left (ParentRefused ColourRole why))
    Right colour →
      ( retainTexture (styleLeases request) (styleNormalLease request) (TextureRequirement (Just DataKind) True (Just UnitNormalRgbV1)) >>= \case
          Left why → releaseRetained colour >> pure (Left (ParentRefused NormalRole why))
          Right normal →
            ( restore (checked colour normal) >>= \case
                Left refusal → releaseRetained normal >> releaseRetained colour >> pure (Left refusal)
                Right style → pure (Right style)
            )
              `onException` releaseRetained normal
      )
        `onException` releaseRetained colour
  where
    checked colour normal = do
      colourPlane ← atomically (retainedCoverage colour)
      normalPlane ← atomically (retainedCoverage normal)
      pure $ case (colourPlane, normalPlane) of
        (Nothing, _) → Left (ParentCoverageGone ColourRole)
        (_, Nothing) → Left (ParentCoverageGone NormalRole)
        (Just cp, Just np) → do
          let colourParent = parentOf colour cp
              normalParent = parentOf normal np
          (assets, textures) ← checkStyle (styleInstanceTextureBytes request) (styleManifest request) (styleMaterials request) colourParent normalParent
          pure (AcquiredStyle colour normal assets textures (parentNominalBytes colourParent + parentNominalBytes normalParent) (Set.fromList (map fst (styleMaterials request))))
    parentOf retained plane =
      let view = retainedView retained
       in StyleParent
            { parentIdentity = viewIdentity view
            , parentVersion = retainedVersion retained
            , parentWidth = viewWidth view
            , parentHeight = viewHeight view
            , parentPlane = plane
            , parentEncoding = retainedNormal retained
            , parentIsData = retainedKind retained == DataKind
            , -- The pipeline uploads exactly one level of every load (no mip generation).
              parentLevelCount = 1
            }

-- | Release both parents' CPU interests. Idempotent, as each retained value's release is.
releaseStyle ∷ AcquiredStyle → IO ()
releaseStyle style = releaseRetained (acqNormal style) >> releaseRetained (acqColour style)
