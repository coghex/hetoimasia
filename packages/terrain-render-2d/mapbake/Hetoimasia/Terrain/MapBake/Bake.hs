-- | The offline bake of one catalog shape's cutout and unit-normal map (TRA-14).
--
-- Every map is a full @96 × 64@ canvas of RGBA8 texels, top row first. The
-- canvas is the native whole-cell sprite: a unit cell point @(x, y, z)@ (X east,
-- Y south, Z up) lands at
--
-- > u = 48 + 48 (x - y)        v = 16 + 24 (x + y) - 16 z
--
-- which is "Hetoimasia.Terrain.Render2D.Projection"'s @isoProject@ for a cell
-- whose origin sits at @(48, 16)@ on the canvas. Points on the line
-- @p + t (1, 1, 3)@ share one canvas position, and a larger @t@ is nearer the
-- camera, so the frontmost surface at a texel is the contact of that line with
-- the solid that has the largest @t@.
--
-- = What one texel holds
--
-- The ray through a texel centre @(i + 1/2, j + 1/2)@ is cast, in exact
-- 'Rational' arithmetic, at the shared canonical 'Solid' of
-- "Hetoimasia.Terrain.Geometry": this module defines no second shape. A miss is
-- the transparent texel @(0, 0, 0, 0)@. A contact is an opaque texel (alpha 255)
-- whose RGB is the unit outward normal of the facet it meets, encoded as the
-- @unit-normal-rgb-v1@ profile: @round (128 + 127 n)@ per component. Hard
-- creases stay hard: a texel carries one facet's normal and nothing is averaged
-- or antialiased.
--
-- = The tie rule
--
-- The solid is closed, so a ray that only touches it (a silhouette edge or a
-- vertex) is covered. A point shared by several facets belongs to the first,
-- in 'Hetoimasia.Terrain.Geometry.castRay's canonical order, of those that face
-- the camera (outward normal against @(1, 1, 3)@ positive): the top facets in
-- the order of the shape's set bits N, E, S, W, then the walls North, East,
-- South, West. A ray that touches without entering takes the first facet
-- containing the contact, in the same order. No tolerance is involved. By
-- construction no texel centre lies on any projected facet, ridge, wall or
-- silhouette edge (every vertex of every solid projects to a whole canvas
-- point and every edge has slope @0@, @±1/2@, @±1/6@ or @±5/6@ through one, so
-- a centre's offset never has fractional part @1/2@), so the rule decides no
-- baked texel; the tests evaluate it at exact rational boundary points.
--
-- = The mixed-knowledge parts
--
-- A cell whose solid is known but whose empty component above it is not yet
-- discovered is shown as the solid plus opaque presentation cover filling the
-- void, up to the cell's own top. The union of the two is the unit cube, so the
-- frontmost surface of the union is the cube's: its top @z = 1@ and the walls
-- @x = 1@ and @y = 1@. A texel there belongs to the known solid when the
-- frontmost point lies in the closed solid and to the cover otherwise; the known
-- map holds the first and the fog map the second, each with the outward normal
-- of the cube facet it shows (the cover's own normal over the void, never the
-- hidden ramp's). Their coverage is disjoint and their union is the full cell
-- cover, which is identity 0's ordinary map. Along @(1, 1, 3)@ the quantity
-- @z - h(x, y)@ grows by @3 - (h_x + h_y)@, which is 2, 3 or 4 for every
-- catalog facet, so a ray cannot pass from void into nearer solid inside the
-- cell. A part may be empty, and an empty part invents no texel.
--
-- State, ownership and lifetime: none. Every value is immutable and every
-- function pure; the baked maps are lazily shared constants.
module Hetoimasia.Terrain.MapBake.Bake
  ( -- * The canvas
    canvasWidth
  , canvasHeight
  , localToCanvas
  , canvasRay
  , viewTowardCamera

    -- * The frontmost facet
  , Facet (..)
  , Texel (..)
  , MixedTexel (..)
  , ordinaryAt
  , mixedAt

    -- * The normal profile
  , normalProfile
  , encodeNormal
  , facetBytes
  , decodeNormal
  , opaqueNormalValid

    -- * Baked maps
  , RgbaBytes
  , ordinaryBytes
  , knownBytes
  , fogBytes
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Word (Word8)
import Hetoimasia.Terrain.Geometry
  ( Face (..)
  , FaceKind
  , Plane (..)
  , PointClass (..)
  , RayHit (..)
  , V3 (..)
  , castRay
  , classifyPoint
  , mkRay
  , shapeSolid
  )
import qualified Hetoimasia.Terrain.Geometry as Geometry
import Hetoimasia.Terrain.Shape (ShapeId, allShapeIds, shapeFromSides, shapeIdValue)

-- | The canvas width in texels.
canvasWidth ∷ Int
canvasWidth = 96

-- | The canvas height in texels.
canvasHeight ∷ Int
canvasHeight = 64

-- | The direction, in the cell frame, along which canvas positions coincide and
-- a larger multiple is nearer the camera.
viewTowardCamera ∷ V3
viewTowardCamera = V3 1 1 3

-- | A cell-local point on the canvas.
localToCanvas ∷ V3 → (Rational, Rational)
localToCanvas (V3 x y z) = (48 + 48 * (x - y), 16 + 24 * (x + y) - 16 * z)

-- | The cell-frame ray through a canvas position, starting beyond the cell's top
-- (at the point of that line three units up) and running away from the camera.
-- It is 'Nothing' only if the exact ray could not be built, which it always can.
canvasRay ∷ (Rational, Rational) → Maybe Geometry.Ray
canvasRay (u, v) =
  either (const Nothing) Just (mkRay origin (V3 (-1) (-1) (-3)))
  where
    across = (u - 48) / 48
    along = (v - 16) / 24
    -- The line's point at z = 0, moved one step along (1, 1, 3) to z = 3.
    origin = V3 ((along + across) / 2 + 1) ((along - across) / 2 + 1) 3

-- | A facet of a solid as a texel names it: the kind of face and its outward
-- plane normal (not normalized).
data Facet = Facet
  { facetKind ∷ !FaceKind
  , facetNormal ∷ !V3
  }
  deriving stock (Eq, Show)

facetOf ∷ Face → Facet
facetOf face = Facet (faceKind face) (planeNormal (facePlane face))

-- | What an ordinary map holds at a canvas position.
data Texel = Clear | Surface !Facet
  deriving stock (Eq, Show)

-- | What a mixed pair holds at a canvas position: nothing, the visible known
-- solid, or the visible cover.
data MixedTexel = MixedClear | MixedKnown !Facet | MixedFog !Facet
  deriving stock (Eq, Show)

-- | The frontmost facet of a shape's closed solid at a canvas position.
ordinaryAt ∷ ShapeId → (Rational, Rational) → Texel
ordinaryAt shape point = case canvasRay point >>= castRay (shapeSolid shape) of
  Just RayHit {hitFace = Just face} → Surface (facetOf face)
  _ → Clear

-- | The part of the frontmost surface of the shape's solid-plus-cover cube at a
-- canvas position.
mixedAt ∷ ShapeId → (Rational, Rational) → MixedTexel
mixedAt shape point = case canvasRay point >>= castRay (shapeSolid flat) of
  Just RayHit {hitPoint = at, hitFace = Just face}
    | classifyPoint (shapeSolid shape) at /= Exterior → MixedKnown (facetOf face)
    | otherwise → MixedFog (facetOf face)
  _ → MixedClear
  where
    flat = shapeFromSides []

-- | The profile every normal map declares.
normalProfile ∷ String
normalProfile = "unit-normal-rgb-v1"

-- | A unit vector as profile bytes: @round (128 + 127 n)@ per component.
encodeNormal ∷ (Double, Double, Double) → (Word8, Word8, Word8)
encodeNormal (x, y, z) = (byte x, byte y, byte z)
  where
    byte component = fromIntegral (max 0 (min 255 (round (128 + 127 * component) ∷ Int)))

-- | The profile bytes of a facet's outward unit normal.
facetBytes ∷ Facet → (Word8, Word8, Word8)
facetBytes facet = encodeNormal (a / len, b / len, c / len)
  where
    V3 ra rb rc = facetNormal facet
    a = fromRational ra ∷ Double
    b = fromRational rb
    c = fromRational rc
    len = sqrt (a * a + b * b + c * c)

-- | The unit vector profile bytes stand for: the bytes less 128, normalized, or
-- 'Nothing' for the zero vector.
decodeNormal ∷ (Word8, Word8, Word8) → Maybe (Double, Double, Double)
decodeNormal (r, g, b)
  | len == 0 = Nothing
  | otherwise = Just (x / len, y / len, z / len)
  where
    x = fromIntegral r - 128 ∷ Double
    y = fromIntegral g - 128
    z = fromIntegral b - 128
    len = sqrt (x * x + y * y + z * z)

-- | Whether an opaque texel's RGB is a valid profile normal: every channel in
-- @1..255@ and a nonzero decoded vector.
opaqueNormalValid ∷ (Word8, Word8, Word8) → Bool
opaqueNormalValid rgb@(r, g, b) = all (>= 1) [r, g, b] && decodeNormal rgb /= Nothing

-- | A whole canvas, 'canvasWidth' × 'canvasHeight' RGBA8 texels, top row first.
type RgbaBytes = ByteString

bake ∷ ((Rational, Rational) → Maybe Facet) → RgbaBytes
bake texelAt =
  ByteString.pack
    [ byte
    | j ← [0 .. canvasHeight - 1]
    , i ← [0 .. canvasWidth - 1]
    , byte ← texel (texelAt (fromIntegral i + 1 / 2, fromIntegral j + 1 / 2))
    ]
  where
    texel Nothing = [0, 0, 0, 0]
    texel (Just facet) = let (r, g, b) = facetBytes facet in [r, g, b, 255]

-- | The ordinary map of a shape. The sixteen are baked once.
ordinaryBytes ∷ ShapeId → RgbaBytes
ordinaryBytes shape = ordinaryTable !! shapeIdValue shape

ordinaryTable ∷ [RgbaBytes]
ordinaryTable = [bake (surfaceOf . ordinaryAt shape) | shape ← allShapeIds]
  where
    surfaceOf (Surface facet) = Just facet
    surfaceOf Clear = Nothing

-- | The known-solid map of a shape's mixed pair.
knownBytes ∷ ShapeId → RgbaBytes
knownBytes shape = knownTable !! shapeIdValue shape

-- | The cover map of a shape's mixed pair.
fogBytes ∷ ShapeId → RgbaBytes
fogBytes shape = fogTable !! shapeIdValue shape

knownTable ∷ [RgbaBytes]
knownTable = [bake (known . mixedAt shape) | shape ← allShapeIds]
  where
    known (MixedKnown facet) = Just facet
    known _ = Nothing

fogTable ∷ [RgbaBytes]
fogTable = [bake (fog . mixedAt shape) | shape ← allShapeIds]
  where
    fog (MixedFog facet) = Just facet
    fog _ = Nothing
