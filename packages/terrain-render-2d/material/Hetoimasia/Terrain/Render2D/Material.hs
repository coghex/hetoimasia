-- | The terrain material's pure half (TRA-17): the record a whole-cell quad carries, the
-- adaptation of a cell plan into render-2d instances, and the model of the material's fragment
-- function that the 2D oracle judges the device by.
--
-- The Vulkan-linked declaration of the material (its GLSL, registration and push block) is
-- "Hetoimasia.Terrain.Render2D.Vulkan.Material" in @hetoimasia-terrain-render-2d-vulkan@; this
-- component has no Vulkan, window, Lua or game dependency, so the CPU suites and the device
-- evidence share one definition of the layout, the packing and the model.
--
-- == What a quad is drawn as
--
-- A planned quad ("Hetoimasia.Terrain.Render2D.Cells") is a whole 96 x 64 canvas with UV
-- @[0, 1]@, drawn through a colour region and a normal-data region of two atlases. The material
-- samples both itself, at the texel the rule below selects, lights the result and applies the
-- depth effects, and returns premultiplied linear colour; the engine's wrapper applies the
-- cutout threshold at one half, so a texel the colour or the map leaves transparent writes
-- neither colour nor depth.
--
-- > record = two handles and 'recordWordCount' words:
-- >   handle 0   the colour atlas (the instance's primary texture, repeated)
-- >   handle 1   the normal atlas
-- >   w0..w5     colour region: origin x, origin y, width, height, atlas width, atlas height
-- >   w6..w11    normal region: the same six
-- >   w12        the cell's depth below the cut, bounded to 0 .. 250
--
-- == Sampling
--
-- For each region separately, with @(w, h)@ its own extent (96 x 64) and @(u, v)@ the
-- interpolated UV, @i = min (w - 1) (floor (clamp u 0 1 * w + texelBias))@ and @j@ likewise, and the sample
-- is at @(origin + (i + 1/2, j + 1/2)) / atlasExtent@, nearest, level zero. The origin is added
-- after the local texel is chosen, so a region never reads a neighbour; each atlas has one level.
-- Both samples are unconditional, as the implicit derivatives require.
--
-- @texelBias@ is @1/10000@ of a texel, the owner's 2026-11-09 Q-13 decision, and 'texelIndex' of
-- "Hetoimasia.Asset.Image.Region" is the rule's one definition: the shader's colour and normal
-- samples (its literal is made from the constant), CPU coverage and picking and the independent
-- expected model all use it, so an interior texel boundary selects the higher texel even though
-- float32 interpolation lands a hair below it on the device. A coordinate more than the bias
-- below a boundary still selects the lower texel.
--
-- == The colour
--
-- With @T@ the sampled premultiplied linear colour, @m@ the map's alpha, @n@ the unit normal
-- decoded as @normalize (round (255 x sampled rgb) - 128)@, @B@ the lighting factor and @D@ and
-- @H@ the depth effects of "Hetoimasia.Terrain.Render2D.Presentation":
--
-- > p     = clamp (dot n sunView) 0 1
-- > B     = ambient + (1 - ambient) * S * p
-- > t     = clamp (d / range) 0 1
-- > D     = 1 - darkening * t         H = haze * t * t
-- > alpha = T.a * m
-- > rgb   = (1 - H) * T.rgb * m * B * D + H * F * alpha
--
-- A transparent map sample contributes zero and its colour bytes are never normalized.
--
-- == Records are shared
--
-- The record depends on the quad's regions and depth, not on where the cell is: the adapter gives
-- equal records one table entry, bounded by 'maxRecords', so the table is the distinct
-- region-and-depth combinations the plan draws, never a record per cell.
--
-- State, ownership and lifetime: none. Every value is immutable and every function pure.
module Hetoimasia.Terrain.Render2D.Material
  ( -- * The textures
    AtlasTextures (..)
  , ParentTexture (..)
  , BindRefusal (..)
  , bindColourParent
  , bindDataParent
  , packedTextures
  , atlasColourHandles
  , withColourHandle

    -- * The record
  , recordLayout
  , recordHandleCount
  , recordWordCount
  , maxRecords
  , quadRecord

    -- * Adapting a plan
  , MaterialRefusal (..)
  , describeMaterialRefusal
  , AdaptedQuad (..)
  , Adapted (..)
  , adaptCells
  , adaptCellsWith
  , adaptedInstance
  , adaptedMaterialData
  , terrainView

    -- * The model
  , terrainModel
  , terrainModelInsetControl
  , terrainModelUnbiasedControl
  ) where

import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map
import Data.Word (Word32, Word64)
import Hetoimasia.Asset.Image.DataMap (NormalEncoding (..), coverageHeight, coverageWidth)
import Hetoimasia.Asset.Image.Region
  ( RegionView
  , texelBias
  , regionHeight
  , regionOriginX
  , regionOriginY
  , regionViewParentExtent
  , regionViewContent
  , regionViewParentVersion
  , regionViewRegion
  , regionWidth
  )
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.TwoD.Material (MaterialData (..), MaterialRecord (..), MaterialRef, RecordLayout (..))
import Hetoimasia.Render.TwoD.Oracle.Material (Colour (..), MaterialInput (..), MaterialModel (..), pushFloat)
import Hetoimasia.Render.TwoD.Snapshot (Camera (..), Instance (..), Layer, Sampler (..), View (..))
import Hetoimasia.Terrain.Coordinate (axisValue)
import Hetoimasia.Terrain.MapBake.Catalog (MapKey)
import Hetoimasia.Terrain.Render2D.AtlasAssets (ParentAtlas (..), ParentKind (..))
import Hetoimasia.Terrain.Render2D.Assets (AssetSnapshot, ColourRef, assetIdentity, colourCoverage, mapCoverage)
import Hetoimasia.Terrain.Render2D.Cells
import Hetoimasia.Terrain.Render2D.Presentation
import Hetoimasia.Terrain.Render2D.Projection (ViewSetup (..), rationalToFloat, rvCentre, rvSetup, rvZoom)

-- | One registered parent texture, bound to the validated parent image it was uploaded from: the
-- handle and the identity (coverage version and extent) of the 'ParentAtlas' that supplied its
-- coverage. Only 'bindColourParent' and 'bindDataParent' make one, so a binding cannot claim a
-- parent that was not decoded as the right kind, with one level and the checked profile.
data ParentTexture = ParentTexture
  { ptHandle ∷ !TextureHandle
  , ptVersion ∷ !Word64
  , ptExtent ∷ !(Word32, Word32)
  , ptContent ∷ !Word64
  -- ^ The parent's content digest: the identity that tells two different images of one version and
  -- extent apart.
  , ptKind ∷ !ParentKind
  }
  deriving stock (Eq, Show)

-- | Why a parent could not be bound to a texture.
data BindRefusal
  = BindWrongKind !ParentKind
  | BindLevels !Int
  | BindWrongProfile !(Maybe NormalEncoding)
  deriving stock (Eq, Show)

-- | Bind a parent decoded as colour, with one level, to its registered texture.
bindColourParent ∷ ParentAtlas → TextureHandle → Either BindRefusal ParentTexture
bindColourParent parent handle
  | parentKind parent /= ColourParent = Left (BindWrongKind (parentKind parent))
  | parentLevels parent /= 1 = Left (BindLevels (parentLevels parent))
  | parentProfile parent /= Nothing = Left (BindWrongProfile (parentProfile parent))
  | otherwise = Right (bound parent handle)

-- | Bind a parent decoded as data, with one level and the checked normal profile, to its texture.
bindDataParent ∷ ParentAtlas → TextureHandle → Either BindRefusal ParentTexture
bindDataParent parent handle
  | parentKind parent /= DataParent = Left (BindWrongKind (parentKind parent))
  | parentLevels parent /= 1 = Left (BindLevels (parentLevels parent))
  | parentProfile parent /= Just UnitNormalRgbV1 = Left (BindWrongProfile (parentProfile parent))
  | otherwise = Right (bound parent handle)

bound ∷ ParentAtlas → TextureHandle → ParentTexture
bound parent handle = ParentTexture handle (parentCoverageVersion parent) (coverageWidth plane, coverageHeight plane) (parentContent parent) (parentKind parent)
  where
    plane = parentCoverage parent

-- | The registered parent textures a style's regions live in: the colour parents and the data
-- parents. A packed style has one of each; a style of single images has one per image. Each
-- region of a plan is resolved to the texture of /its own/ parent by identity, so two regions of
-- different parents never share a handle, and a region whose parent has no binding is refused.
data AtlasTextures = AtlasTextures
  { atlasColour ∷ ![ParentTexture]
  , atlasNormal ∷ ![ParentTexture]
  }
  deriving stock (Eq, Show)

-- | A packed style's two textures.
packedTextures ∷ ParentTexture → ParentTexture → AtlasTextures
packedTextures colour normal = AtlasTextures [colour] [normal]

-- | The colour textures' handles (the instances' primary textures, whose marks route the quads).
atlasColourHandles ∷ AtlasTextures → [TextureHandle]
atlasColourHandles = map ptHandle . atlasColour

-- | The same textures with every colour parent drawn through another handle (a second
-- registration of the same image), for the evidence's ordered-wrapper route.
withColourHandle ∷ TextureHandle → AtlasTextures → AtlasTextures
withColourHandle handle textures = textures {atlasColour = [t {ptHandle = handle} | t ← atlasColour textures]}

-- | Two handles (colour, normal) and the words above.
recordHandleCount ∷ Int
recordHandleCount = 2

-- | The words of a record: six per region and the depth.
recordWordCount ∷ Int
recordWordCount = 13

-- | The most distinct records one adaptation may hold.
maxRecords ∷ Int
maxRecords = 4096

-- | The record layout the material declares.
recordLayout ∷ RecordLayout
recordLayout = RecordLayout (fromIntegral recordHandleCount) (fromIntegral recordWordCount)

-- | Why a plan could not be adapted. Nothing is approximated and nothing is adapted in part.
data MaterialRefusal
  = -- | The plan's assets hold no colour region for a quad.
    NoColourRegion !ColourRef
  | -- | The plan's assets hold no map region for a quad.
    NoMapRegion !MapKey
  | -- | A region is not a 96 x 64 canvas.
    RegionNotCanvas !Word32 !Word32
  | -- | More than 'maxRecords' distinct records: the whole plan is refused.
    TooManyRecords !Int
  | -- | No texture is bound to the parent a region lives in: the kind of parent, its coverage
    -- version and its extent.
    NoTextureForParent !String !Word64 !(Word32, Word32)
  | -- | More than one binding matches the parent of a region: the kind of parent and its version.
    AmbiguousTexture !String !Word64
  | -- | The assets are not the ones the plan was made against.
    StaleAssets
  | -- | The camera is not representable in 32 bits.
    UnrepresentableView
  | -- | The adaptation was made for another plan than the one it is paired with.
    StaleAdaptation
  deriving stock (Eq, Show)

describeMaterialRefusal ∷ MaterialRefusal → String
describeMaterialRefusal = \case
  NoColourRegion ref → "the assets hold no colour region for " <> show ref
  NoMapRegion key → "the assets hold no map region for " <> show key
  RegionNotCanvas w h → "a region is " <> show w <> " x " <> show h <> ", not a 96 x 64 canvas"
  TooManyRecords n → "the plan needs more than " <> show n <> " distinct material records"
  AmbiguousTexture kind version → "more than one " <> kind <> " texture is bound to the parent of version " <> show version
  NoTextureForParent kind version extent → "no " <> kind <> " texture is bound to the parent of version " <> show version <> " and extent " <> show extent
  StaleAssets → "the assets are not the ones the plan was made against"
  UnrepresentableView → "the camera is not representable in 32 bits"
  StaleAdaptation → "the adaptation is for another plan"

-- | The six words of a region: origin, extent and the parent's extent.
regionWords ∷ RegionView → Either MaterialRefusal [Word32]
regionWords view
  | regionWidth region /= 96 || regionHeight region /= 64 = Left (RegionNotCanvas (regionWidth region) (regionHeight region))
  | otherwise = Right [regionOriginX region, regionOriginY region, regionWidth region, regionHeight region, pw, ph]
  where
    region = regionViewRegion view
    (pw, ph) = regionViewParentExtent view

-- | The record that draws a quad: both handles, both regions and the bounded depth below the cut.
quadRecord ∷ AtlasTextures → Word32 → RegionView → RegionView → Either MaterialRefusal MaterialRecord
quadRecord textures depth colour normal = do
  colourWords ← regionWords colour
  normalWords ← regionWords normal
  colourTexture ← resolveParent "colour" (atlasColour textures) colour
  normalTexture ← resolveParent "normal" (atlasNormal textures) normal
  pure (MaterialRecord [ptHandle colourTexture, ptHandle normalTexture] (colourWords <> normalWords <> [depth]))

-- The texture bound to the parent a region lives in, by the parent's identity.
resolveParent ∷ String → [ParentTexture] → RegionView → Either MaterialRefusal ParentTexture
resolveParent kind bindings view =
  case [ t
       | t ← bindings
       , ptVersion t == regionViewParentVersion view
       , ptExtent t == regionViewParentExtent view
       , ptContent t == regionViewContent view
       , ptKind t == (if kind == "colour" then ColourParent else DataParent)
       ] of
    [t] → Right t
    [] → Left (NoTextureForParent kind (regionViewParentVersion view) (regionViewParentExtent view))
    _ → Left (AmbiguousTexture kind (regionViewParentVersion view))

-- | A planned quad with the table entry that draws it.
data AdaptedQuad = AdaptedQuad
  { adaptedQuad ∷ !CellQuad
  , adaptedColourHandle ∷ !TextureHandle
  -- ^ The colour parent's texture: the instance's primary texture, whose mark routes the quad.
  , adaptedParameter ∷ !Word32
  -- ^ The index of its record in 'adaptedRecords'.
  }
  deriving stock (Eq, Show)

-- | A plan's quads with the table of the distinct records they need and the push block of the
-- presentation snapshot, all made together from one plan so none can be stale against another.
data Adapted = Adapted
  { adaptedQuads ∷ ![AdaptedQuad]
  -- ^ In the plan's order.
  , adaptedRecords ∷ ![MaterialRecord]
  -- ^ The table the parameter words index, in the order records first appear.
  , adaptedPush ∷ !ByteString
  -- ^ The 48-byte push block of the plan's facing and the settings.
  , adaptedIdentity ∷ !CellIdentity
  -- ^ The plan this was made for.
  , adaptedSettings ∷ !LightSettings
  , adaptedTextures ∷ !AtlasTextures
  }
  deriving stock (Eq, Show)

-- | Give every quad the record that draws it and the plan's push block, sharing a record between
-- quads that need an equal one. A quad whose region is absent or is not a canvas refuses the whole
-- plan, so a mixed cell's parts are adapted together or not at all.
adaptCells ∷ AtlasTextures → LightSettings → AssetSnapshot → CellPlan → Either MaterialRefusal Adapted
adaptCells = adaptCellsWith maxRecords

-- | 'adaptCells' under a stated bound on the distinct records, which the caller may only lower.
adaptCellsWith ∷ Int → AtlasTextures → LightSettings → AssetSnapshot → CellPlan → Either MaterialRefusal Adapted
adaptCellsWith limit textures settings assets plan = do
  if assetIdentity assets == cellIdentityAssets identity then pure () else Left StaleAssets
  (reversedQuads, _, reversedRecords) ← foldl' step (Right ([], Map.empty, [])) (cellPlanQuads plan)
  pure
    Adapted
      { adaptedQuads = reverse reversedQuads
      , adaptedRecords = reverse reversedRecords
      , adaptedPush = pushBytes (cellIdentityFacing identity) settings
      , adaptedIdentity = identity
      , adaptedSettings = settings
      , adaptedTextures = textures
      }
  where
    identity = cellPlanIdentity plan
    cut = axisValue (cellIdentityCut identity)
    step acc quad = do
      (done, known, records) ← acc
      colour ← maybe (Left (NoColourRegion (quadColour quad))) Right (colourCoverage assets (quadColour quad))
      normal ← maybe (Left (NoMapRegion (quadMap quad))) Right (mapCoverage assets (quadMap quad))
      let CellKey _ z _ _ _ = quadKey quad
          depth = depthWord (toInteger cut) z
      record ← quadRecord textures depth colour normal
      colourHandle ← case record of
        MaterialRecord (h : _) _ → Right h
        _ → Left (NoTextureForParent "colour" 0 (0, 0))
      case Map.lookup record known of
        Just index → pure (AdaptedQuad quad colourHandle index : done, known, records)
        Nothing
          | Map.size known >= min limit maxRecords → Left (TooManyRecords (min limit maxRecords))
          | otherwise →
              let index = fromIntegral (Map.size known)
               in pure (AdaptedQuad quad colourHandle index : done, Map.insert record index known, record : records)

-- | The render-2d instance that draws an adapted quad with the registered material: the quad's
-- transform and depth key, the colour atlas as the instance's texture (so its cutout mark routes
-- the quad), the whole unit square as its texture rectangle, nearest sampling, opaque white tint
-- and the quad's record as its parameter word.
adaptedInstance ∷ MaterialRef → Adapted → AdaptedQuad → Instance
adaptedInstance material _adapted quad =
  (cellQuadInstance (adaptedColourHandle quad) (adaptedQuad quad))
    { instanceMaterial = material
    , instanceParameter = adaptedParameter quad
    , instanceSampler = SamplerNearest
    }

-- | What a view holds for the material: the table and the presentation snapshot's push block.
adaptedMaterialData ∷ Adapted → MaterialData
adaptedMaterialData adapted = MaterialData (adaptedRecords adapted) (adaptedPush adapted)

-- | The render-2d view that draws a plan's quads: the camera, viewport and settings the plan's own
-- view maps, so that drawing and picking share one mapping, holding the material data for these
-- materials and these layers. Refused when the adaptation is not for this plan or the camera is not
-- representable in 32 bits.
terrainView ∷ CellPlan → Adapted → [(MaterialRef, MaterialData)] → [Layer] → Either MaterialRefusal View
terrainView plan adapted held layers
  | adaptedIdentity adapted /= cellPlanIdentity plan = Left StaleAdaptation
  | otherwise = case (rationalToFloat cx, rationalToFloat cy) of
      (Just px, Just py) →
        Right
          ( ViewWith
              (Camera (V2 px py) (rvZoom view) Nothing)
              (setupViewport setup)
              (setupSettings setup)
              []
              (Map.fromList held)
              []
              0
              layers
          )
      _ → Left UnrepresentableView
  where
    view = cellPlanView plan
    (cx, cy) = rvCentre view
    setup = rvSetup view

-- ---------------------------------------------------------------------------
-- The model

clamp01 ∷ Double → Double
clamp01 = max 0 . min 1

-- | The terrain material's fragment function as the oracle takes it, in 'Double' arithmetic over
-- the same 32-bit values the record and the push block hold. A record of another layout holds
-- nothing and draws nothing.
terrainModel ∷ MaterialModel
terrainModel = modelWith (centreWith (fromRational texelBias))

-- | The model of the unbiased-index negative control (never a terrain rule): the texel index
-- without the bias, the rule the Q-13 counterexample was measured under. The evidence gives the
-- oracle this model for the control's own material so the oracle agrees with the device, and the
-- independent judge, which states the specified rule, rejects it.
terrainModelUnbiasedControl ∷ MaterialModel
terrainModelUnbiasedControl = modelWith (centreWith 0)

-- | The texel the local index selects, at its centre, in the atlas, with this bias in texels: the
-- origin is added after.
centreWith ∷ Double → Word32 → Word32 → Word32 → Double → Double
centreWith bias origin extent atlas coordinate = (fromIntegral origin + local + 0.5) / fromIntegral atlas
  where
    local = fromIntegral (min (extent - 1) (floor (clamp01 coordinate * fromIntegral extent + bias) ∷ Word32)) ∷ Double

-- | The model of the negative control's rule (never a terrain rule): the region coordinate
-- interpolated between the half-texel-inset endpoints, @(origin + 1/2 + u (w - 1)) / atlasExtent@,
-- which shifts the interior texel boundaries. The evidence gives the oracle this model for the
-- control's own material so the oracle agrees with the device, and the independent judge, which
-- holds the specified rule, rejects the draw.
terrainModelInsetControl ∷ MaterialModel
terrainModelInsetControl = modelWith inset
  where
    inset origin extent atlas coordinate = (fromIntegral origin + 0.5 + clamp01 coordinate * (fromIntegral extent - 1)) / fromIntegral atlas

-- The shared body of both models, over the rule that maps a region's origin, extent and parent
-- extent and a coordinate to the sampled coordinate.
modelWith ∷ (Word32 → Word32 → Word32 → Double → Double) → MaterialModel
modelWith centre = MaterialModel $ \input → case materialRecord input of
  MaterialRecord [colourHandle, normalHandle] ws
    | [cx, cy, cw, ch, caw, cah, nx, ny, nw, nh, naw, nah, depth] ← ws
    , all (> 0) [cw, ch, caw, cah, nw, nh, naw, nah] → do
        let (u, v) = materialUv input
            colourAt = (centre cx cw caw u, centre cy ch cah v)
            normalAt = (centre nx nw naw u, centre ny nh nah v)
        Colour tr tg tb ta ← materialSample input colourHandle colourAt
        Colour nr ng nb m ← materialSample input normalHandle normalAt
        let push = pushFloat (materialPush input)
            sun = (push 0, push 4, push 8)
            ambient = push 12
            strength = push 16
            darkening = push 20
            haze = push 24
            reciprocalRange = push 28
            hazeLight = (push 32, push 36, push 40)
            byte c = fromIntegral (round (c * 255) ∷ Int) - 128 ∷ Double
            (bx, by, bz) = (byte nr, byte ng, byte nb)
            norm = sqrt (bx * bx + by * by + bz * bz)
            (nxu, nyu, nzu) = if norm > 0 then (bx / norm, by / norm, bz / norm) else (0, 0, 1)
            (sx, sy, sz) = sun
            diffuse = clamp01 (nxu * sx + nyu * sy + nzu * sz)
            brightness = ambient + (1 - ambient) * strength * diffuse
            t = clamp01 (fromIntegral depth * reciprocalRange)
            darken = 1 - darkening * t
            blend = haze * t * t
            (fr, fg, fb) = hazeLight
            alpha = ta * m
            channel texel light = (1 - blend) * texel * m * brightness * darken + blend * light * alpha
        pure (Colour (channel tr fr) (channel tg fg) (channel tb fb) alpha)
  _ → Right (Colour 0 0 0 0)
