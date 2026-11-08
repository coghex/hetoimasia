-- | The supplied asset facts a cell-quad plan and picker read (TRA-16): the
-- matching immutable coverage of the colour artwork and the face maps.
--
-- == What this is
--
-- A plan names the artwork each quad is drawn with by identity only
-- ('ColourRef', 'Hetoimasia.Terrain.MapBake.Catalog.MapKey'); which GPU
-- texture that is belongs to the later material slice. What a plan and a pick
-- /need/ from the assets is their binary coverage, one bit per texel of a
-- 96 x 64 canvas (TRA-15's 'CoveragePlane'), shared by every cell that uses
-- the asset and never copied per cell. An 'AssetSnapshot' holds, for one
-- adopted style, the coverage of each material's colour artwork, of the
-- generic blank (fog) colour and of the catalog's maps, each with the texture
-- version and the coverage version it was built from.
--
-- == Checks that make a snapshot usable
--
-- 'mkAssetSnapshot' refuses, with the asset it names:
--
-- * a plane that is not 96 x 64;
-- * a texture whose version differs from its coverage's, so a recycled
--   registration or a reused handle generation cannot pair an old plane with
--   a new texture;
-- * a map without the checked normal profile 'UnitNormalRgbV1' (the plane is
--   binary by construction, but a map whose numeric profile was not verified is
--   not a catalog map);
-- * a catalog that does not hold every authored map (the 46 maps of
--   "Hetoimasia.Terrain.MapBake.Catalog"), or holds one twice.
--
-- A plan additionally refuses a material whose colour is absent. Nothing is
-- thresholded, resized or substituted.
--
-- == Opacity facts
--
-- A quad may be omitted as hidden only with a valid coverage proof. The
-- snapshot therefore derives, once and from the planes themselves, whether an
-- asset covers every texel the full-block map covers: a colour whose coverage
-- contains the full hexagon, and the maps that equal it. These facts are the
-- only occlusion premise a plan uses; a colour with a hole in the hexagon
-- proves nothing and its cell is never treated as covering what lies behind.
--
-- The full-block map is itself supplied, so it is checked too: translated to
-- the three cells that can hide one (east, south and above) it must cover
-- itself, and every catalog map must lie inside it. A snapshot whose full-block
-- plane fails either test is still accepted, but then no asset is a covering
-- proof and no cell is omitted as hidden: the planner draws what it cannot
-- prove covered.
--
-- State, ownership and lifetime: none. The planes are immutable values the
-- texture pipeline owns; a snapshot only names them. Its identity
-- ('assetIdentity') changes when any version does.
module Hetoimasia.Terrain.Render2D.Assets
  ( -- * Names
    ColourRef (..)
  , AssetKey (..)
  , canvasWidth
  , canvasHeight
  , maxAssetMaterials
  , maxAssetMaps

    -- * Assets
  , ColourAsset
  , MapAsset
  , AssetError (..)
  , mkColourAsset
  , mkMapAsset

    -- * The snapshot
  , AssetSnapshot
  , mkAssetSnapshot
  , AssetIdentity
  , assetIdentity
  , assetVersion
  , colourCoverage
  , mapCoverage
  , colourCoversHexagon
  , mapCoversHexagon
  , assetMaterials
  ) where

import Data.Bits (rotateL, xor)
import Data.Char (ord)
import Control.Monad (when)
import Data.Maybe (isNothing)
import qualified Data.Map.Strict as Map
import Data.Word (Word32, Word64)
import Hetoimasia.Asset.Image.DataMap
  ( CoveragePlane
  , NormalEncoding (..)
  , coverageAt
  , coverageHeight
  , coverageWidth
  )
import Hetoimasia.Terrain.Cell (MaterialId)
import Hetoimasia.Terrain.MapBake.Catalog (MapKey (..), MapRole (..), catalogKeys)
import Hetoimasia.Terrain.Shape (allShapeIds)

-- | The width, in texels, of every colour and map canvas.
canvasWidth ∷ Word32
canvasWidth = 96

-- | The height, in texels, of every colour and map canvas.
canvasHeight ∷ Word32
canvasHeight = 64

-- | The most material colours one snapshot may hold. A snapshot is checked once,
-- when it is built, with this stated bound; no step of a plan walks it again.
maxAssetMaterials ∷ Int
maxAssetMaterials = 4096

-- | The most maps one snapshot may hold: the catalog's, with room for a later
-- extension of it.
maxAssetMaps ∷ Int
maxAssetMaps = 4096

-- | Which colour artwork a quad is drawn with.
data ColourRef
  = -- | The generic blank (fog) colour.
    ColourBlank
  | -- | A material's artwork.
    ColourMaterial !MaterialId
  deriving stock (Eq, Ord, Show)

-- | An asset a snapshot holds.
data AssetKey
  = AssetColour !ColourRef
  | AssetMap !MapKey
  deriving stock (Eq, Ord, Show)

-- | Why an asset or a snapshot was refused.
data AssetError
  = -- | The plane is not 96 x 64.
    AssetBadExtent !AssetKey !Word32 !Word32
  | -- | The texture's version and its coverage's version differ.
    AssetVersionMismatch !AssetKey !Word64 !Word64
  | -- | A map was declared without the checked unit-normal profile.
    AssetMissingProfile !MapKey
  | -- | The catalog lacks an authored map.
    AssetMissingMap !MapKey
  | -- | The same asset was listed twice.
    AssetDuplicate !AssetKey
  | -- | More materials than 'maxAssetMaterials' were listed; the field is the limit.
    AssetTooManyMaterials !Int
  | -- | More maps than 'maxAssetMaps' were listed; the field is the limit.
    AssetTooManyMaps !Int
  deriving stock (Eq, Show)

-- | One colour artwork's coverage and the versions it was built from.
data ColourAsset = ColourAsset
  { caTexture ∷ !Word64
  , caCoverage ∷ !Word64
  , caPlane ∷ !CoveragePlane
  }
  deriving stock (Eq, Show)

-- | One face map's coverage, versions and checked profile.
data MapAsset = MapAsset
  { maTexture ∷ !Word64
  , maCoverage ∷ !Word64
  , maPlane ∷ !CoveragePlane
  , maProfile ∷ !(Maybe NormalEncoding)
  }
  deriving stock (Eq, Show)

-- | A colour artwork from its texture version, its coverage version and its
-- plane. The key is only for the refusal's text.
mkColourAsset ∷ ColourRef → Word64 → Word64 → CoveragePlane → Either AssetError ColourAsset
mkColourAsset ref texture coverage plane = do
  checkPlane (AssetColour ref) texture coverage plane
  pure ColourAsset {caTexture = texture, caCoverage = coverage, caPlane = plane}

-- | A face map from its texture version, its coverage version, the normal
-- profile its texels were checked against and its plane.
mkMapAsset ∷ MapKey → Word64 → Word64 → Maybe NormalEncoding → CoveragePlane → Either AssetError MapAsset
mkMapAsset key texture coverage profile plane = do
  checkPlane (AssetMap key) texture coverage plane
  case profile of
    Nothing → Left (AssetMissingProfile key)
    Just UnitNormalRgbV1 → pure MapAsset {maTexture = texture, maCoverage = coverage, maPlane = plane, maProfile = profile}

checkPlane ∷ AssetKey → Word64 → Word64 → CoveragePlane → Either AssetError ()
checkPlane key texture coverage plane
  | coverageWidth plane /= canvasWidth || coverageHeight plane /= canvasHeight =
      Left (AssetBadExtent key (coverageWidth plane) (coverageHeight plane))
  | texture /= coverage = Left (AssetVersionMismatch key texture coverage)
  | otherwise = Right ()

-- | The coverage of one adopted style, checked. The constructor is private.
data AssetSnapshot = AssetSnapshot
  { snVersion ∷ !Word64
  , snColours ∷ !(Map.Map ColourRef ColourAsset)
  , snMaps ∷ !(Map.Map MapKey MapAsset)
  , snHexagonColours ∷ !(Map.Map ColourRef Bool)
  , snHexagonMaps ∷ !(Map.Map MapKey Bool)
  , snIdentity ∷ !AssetIdentity
  -- ^ Taken once, when the snapshot is built: a plan compares it in constant time.
  , snSound ∷ !Bool
  -- ^ Whether the full-block plane proves what an omission needs; see
  -- 'occlusionSound'. When it does not, no asset is a covering proof.
  }
  deriving stock (Eq, Show)

-- | A snapshot of one style: its own version, the blank colour, the material
-- colours and every authored map.
mkAssetSnapshot ∷ Word64 → ColourAsset → [(MaterialId, ColourAsset)] → [(MapKey, MapAsset)] → Either AssetError AssetSnapshot
mkAssetSnapshot version blank materials maps = do
  -- The bounds are checked before anything is walked: looking past a bound by
  -- one element is all it takes to refuse.
  when (not (null (drop maxAssetMaterials materials))) (Left (AssetTooManyMaterials maxAssetMaterials))
  when (not (null (drop maxAssetMaps maps))) (Left (AssetTooManyMaps maxAssetMaps))
  colours ← unique AssetColour (\(ref, _) → ref) ((ColourBlank, blank) : [(ColourMaterial m, a) | (m, a) ← materials])
  mapTable ← unique AssetMap fst maps
  case [key | key ← catalogKeys, isNothing (Map.lookup key mapTable)] of
    key : _ → Left (AssetMissingMap key)
    [] → pure ()
  let hexagon = hexagonOf mapTable
  pure
    AssetSnapshot
      { snVersion = version
      , snColours = Map.map snd colours
      , snMaps = Map.map snd mapTable
      , snHexagonColours = Map.map (\(_, a) → covers (caPlane a) hexagon) colours
      , snHexagonMaps = Map.map (\(_, a) → maPlane a == hexagon) mapTable
      , snIdentity = identityOf version (Map.map snd colours) (Map.map snd mapTable)
      , snSound = occlusionSound hexagon [maPlane a | (_, a) ← Map.elems mapTable]
      }
  where
    unique wrap key = go Map.empty
      where
        go acc [] = Right acc
        go acc (x : xs)
          | Map.member (key x) acc = Left (AssetDuplicate (wrap (key x)))
          | otherwise = go (Map.insert (key x) x acc) xs

-- The plane of the full-block map: the hexagon the identity-0 ordinary map
-- covers. The catalog check has already shown it exists.
hexagonOf ∷ Map.Map MapKey (MapKey, MapAsset) → CoveragePlane
hexagonOf maps = case [maPlane a | (MapKey Ordinary shape, (_, a)) ← Map.toList maps, shape == head' allShapeIds] of
  plane : _ → plane
  [] → error "Hetoimasia.Terrain.Render2D.Assets: the catalog check guarantees the full-block map"
  where
    head' (x : _) = x
    head' [] = error "Hetoimasia.Terrain.Render2D.Assets: no shape identities"

-- Whether the supplied full-block plane can serve as an occlusion proof, checked
-- from the planes themselves and not from a geometric ideal. A cell is omitted
-- when the cells that would be drawn over it (the next one east, the next one
-- south and the one above it) cover everything it could draw, so two things
-- must hold of the actual coverage:
--
-- * every texel the full block covers is covered by that block translated to
--   one of the three occluders (canvas offsets @(48, 24)@, @(-48, 24)@ and
--   @(0, -16)@); a hole in the supplied block fails this at once, where
--   comparing the block with itself could not;
-- * every catalog map lies inside the full block, so what the omitted cell
--   would have drawn is among the texels just proved covered.
occlusionSound ∷ CoveragePlane → [CoveragePlane] → Bool
occlusionSound block maps = selfCovering && all (\m → covers block m) maps
  where
    set plane x y = x >= 0 && y >= 0 && coverageAt plane (fromInteger x) (fromInteger y) == Just True
    selfCovering =
      and
        [ any (\(a, b) → set block a b) [(x - 48, y - 24), (x + 48, y - 24), (x, y + 16)]
        | y ← [0 .. toInteger canvasHeight - 1]
        , x ← [0 .. toInteger canvasWidth - 1]
        , set block x y
        ]

-- Whether every texel the hexagon covers is covered by the plane.
covers ∷ CoveragePlane → CoveragePlane → Bool
covers plane hexagon =
  and
    [ coverageAt plane x y == Just True
    | y ← [0 .. canvasHeight - 1]
    , x ← [0 .. canvasWidth - 1]
    , coverageAt hexagon x y == Just True
    ]

-- | The snapshot's own version.
assetVersion ∷ AssetSnapshot → Word64
assetVersion = snVersion

-- | The versions of every asset a snapshot holds, with the snapshot's own, as a
-- fixed-size digest: equal exactly when the same texture and coverage versions
-- are adopted (up to the collision of two independent 64-bit digests, which is
-- not a security boundary here: a stale plan is a wrong answer, not an attack).
-- It is taken once when the snapshot is built, so comparing two is constant time
-- however many materials the snapshot holds.
data AssetIdentity = AssetIdentity !Word64 !Int !Word64 !Word64
  deriving stock (Eq, Show)

assetIdentity ∷ AssetSnapshot → AssetIdentity
assetIdentity = snIdentity

identityOf ∷ Word64 → Map.Map ColourRef ColourAsset → Map.Map MapKey MapAsset → AssetIdentity
identityOf version colours maps =
  AssetIdentity version (Map.size colours + Map.size maps) (digest 14695981039346656037 fnv) (digest 7809847782465536322 mix)
  where
    entries =
      [(show (AssetColour ref), caTexture a, caCoverage a) | (ref, a) ← Map.toAscList colours]
        <> [(show (AssetMap key), maTexture a, maCoverage a) | (key, a) ← Map.toAscList maps]
    wordsOf (name, texture, coverage) = map (fromIntegral . ord) name <> [0xFF, texture, coverage]
    digest seed step = foldl' step (step seed version) (concatMap wordsOf entries)
    fnv h w = (h `xor` w) * 1099511628211
    mix h w = rotateL (h `xor` w) 23 * 0x9E3779B97F4A7C15 + w

-- | The coverage plane of a colour artwork, if the snapshot holds it.
colourCoverage ∷ AssetSnapshot → ColourRef → Maybe CoveragePlane
colourCoverage snapshot ref = caPlane <$> Map.lookup ref (snColours snapshot)

-- | The coverage plane of a map, if the snapshot holds it.
mapCoverage ∷ AssetSnapshot → MapKey → Maybe CoveragePlane
mapCoverage snapshot key = maPlane <$> Map.lookup key (snMaps snapshot)

-- | Whether the colour covers the full hexagon (a valid occlusion premise).
colourCoversHexagon ∷ AssetSnapshot → ColourRef → Bool
colourCoversHexagon snapshot ref = snSound snapshot && Map.findWithDefault False ref (snHexagonColours snapshot)

-- | Whether the map equals the full-block map (it is itself a full hexagon).
mapCoversHexagon ∷ AssetSnapshot → MapKey → Bool
mapCoversHexagon snapshot key = snSound snapshot && Map.findWithDefault False key (snHexagonMaps snapshot)

-- | The materials whose colour the snapshot holds.
assetMaterials ∷ AssetSnapshot → [MaterialId]
assetMaterials snapshot = [m | ColourMaterial m ← Map.keys (snColours snapshot)]
