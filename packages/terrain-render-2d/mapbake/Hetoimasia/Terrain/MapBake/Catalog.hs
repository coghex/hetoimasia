-- | The bounded shared catalog of baked maps and its rotated lookup (TRA-14).
--
-- The catalog is the sixteen ordinary shape maps plus two complementary
-- mixed-knowledge parts, known solid and cover, for each of the fifteen
-- nonflat shapes: 46 authored maps, never a map per world cell. Generic
-- full-cell fog is identity 0's ordinary map, not a map of its own. Every
-- authored identity is kept even when two maps happen to share their bytes (the
-- cover of a shape whose east and south walls are lowered to the base is the
-- full cover), so a lookup never depends on deduplication.
--
-- World shape identities never change when the view turns; only the catalog
-- entry a view selects does. A view at a facing selects the entry of the shape
-- turned by 'facingTurns' (South 0, West 3, North 2, East 1 positive quarter
-- turns, North to East to South to West), which is
-- "Hetoimasia.Terrain.Shape".'viewShape': each facing is a permutation of the
-- sixteen identities, four turns restore the starting identity, and no
-- independent shape is baked per camera.
--
-- State, ownership and lifetime: none. Pure, immutable values.
module Hetoimasia.Terrain.MapBake.Catalog
  ( -- * Maps
    MapRole (..)
  , MapKey (..)
  , catalogKeys
  , catalogBound
  , mapIdentifier
  , mapFileName
  , mapBytes
  , roleName

    -- * Rotated lookup
  , Lookup (..)
  , lookupFor
  , allLookups
  , facingName
  ) where

import Data.Char (toLower)
import Hetoimasia.Terrain.MapBake.Bake (RgbaBytes, fogBytes, knownBytes, ordinaryBytes)
import Hetoimasia.Terrain.Shape
  ( ShapeId
  , ViewFacing (..)
  , allShapeIds
  , allViewFacings
  , shapeIdValue
  , shapeName
  , viewShape
  )

-- | What a catalog map shows.
data MapRole
  = -- | A whole shape's frontmost surface.
    Ordinary
  | -- | The visible known solid of a cell whose empty component is undiscovered.
    MixedKnown
  | -- | The visible cover over such a cell's undiscovered empty component.
    MixedFog
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | A catalog map: its role and the catalog shape it belongs to.
data MapKey = MapKey
  { mapRole ∷ !MapRole
  , mapShape ∷ !ShapeId
  }
  deriving stock (Eq, Ord, Show)

-- | The most maps the catalog may hold before any deduplication.
catalogBound ∷ Int
catalogBound = 16 + 2 * 15

-- | Every authored map in catalog order: the sixteen ordinary maps, then each
-- nonflat shape's known and cover parts.
catalogKeys ∷ [MapKey]
catalogKeys =
  [MapKey Ordinary shape | shape ← allShapeIds]
    <> concat [[MapKey MixedKnown shape, MapKey MixedFog shape] | shape ← allShapeIds, shapeIdValue shape /= 0]

-- | The role as the manifest spells it.
roleName ∷ MapRole → String
roleName Ordinary = "ordinary"
roleName MixedKnown = "mixed-known"
roleName MixedFog = "mixed-fog"

two ∷ Int → String
two n = (if n < 10 then "0" else "") <> show n

-- | The stable identifier of a map, e.g. @shape.15@ or @mixed.03.fog@.
mapIdentifier ∷ MapKey → String
mapIdentifier (MapKey role shape) = case role of
  Ordinary → "shape." <> two (shapeIdValue shape)
  MixedKnown → "mixed." <> two (shapeIdValue shape) <> ".known"
  MixedFog → "mixed." <> two (shapeIdValue shape) <> ".fog"

-- | The map's file name, e.g. @shape_15_nesw.png@ or @mixed_03_ne_fog.png@.
mapFileName ∷ MapKey → FilePath
mapFileName (MapKey role shape) =
  prefix <> "_" <> two (shapeIdValue shape) <> "_" <> map toLower (shapeName shape) <> suffix <> ".png"
  where
    (prefix, suffix) = case role of
      Ordinary → ("shape", "")
      MixedKnown → ("mixed", "_known")
      MixedFog → ("mixed", "_fog")

-- | The baked RGBA8 canvas of a map.
mapBytes ∷ MapKey → RgbaBytes
mapBytes (MapKey role shape) = case role of
  Ordinary → ordinaryBytes shape
  MixedKnown → knownBytes shape
  MixedFog → fogBytes shape

-- | The catalog entries a world shape selects at one view facing.
data Lookup = Lookup
  { lookupFacing ∷ !ViewFacing
  , lookupWorld ∷ !ShapeId
  , lookupView ∷ !ShapeId
  -- ^ The catalog shape the facing selects: the world shape turned.
  , lookupOrdinary ∷ !MapKey
  , lookupMixed ∷ !(Maybe (MapKey, MapKey))
  -- ^ The known and cover parts; 'Nothing' for identity 0, which has no void.
  , lookupFullFog ∷ !MapKey
  -- ^ Generic full-cell fog: identity 0's ordinary map for every shape.
  }
  deriving stock (Eq, Show)

-- | The entries a world shape selects at a facing.
lookupFor ∷ ViewFacing → ShapeId → Lookup
lookupFor facing world =
  Lookup
    { lookupFacing = facing
    , lookupWorld = world
    , lookupView = view
    , lookupOrdinary = MapKey Ordinary view
    , lookupMixed
    , lookupFullFog = case allShapeIds of
        flat : _ → MapKey Ordinary flat
        [] → MapKey Ordinary view
    }
  where
    view = viewShape facing world
    lookupMixed
      | shapeIdValue view == 0 = Nothing
      | otherwise = Just (MapKey MixedKnown view, MapKey MixedFog view)

-- | Every world shape at every facing, facing-major.
allLookups ∷ [Lookup]
allLookups = [lookupFor facing world | facing ← allViewFacings, world ← allShapeIds]

-- | The facing as the manifest spells it.
facingName ∷ ViewFacing → String
facingName FaceSouth = "south"
facingName FaceWest = "west"
facingName FaceNorth = "north"
facingName FaceEast = "east"
