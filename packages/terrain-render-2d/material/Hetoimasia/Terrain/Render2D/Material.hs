-- | The terrain material's pure half (TRA-8): the caller's art, the record a face
-- carries, the adaptation of a plan's faces into render-2d instances, and the
-- model of the material's fragment function the 2D oracle judges the device by.
--
-- The Vulkan-linked declaration of the material (its GLSL, registration and
-- push block) is "Hetoimasia.Terrain.Render2D.Vulkan.Material" in
-- @hetoimasia-terrain-render-2d-vulkan@; this component has no Vulkan, window,
-- Lua or game dependency, so the CPU suites and the device evidence share one
-- definition of the layout, the packing and the model without importing a spec.
--
-- == What a face is drawn as
--
-- A planned face is a quad (the instance transform of the unit square) and a
-- coverage mask (a convex polygon in that unit square), both from the shared
-- terrain solids (TRA-7). The material draws the quad and gives a fragment
-- colour only where the mask covers it:
--
-- > record = one handle (the art sheet) and 'recordWordCount' words:
-- >   w0..w2   a, b, c   art u = a·u + b·v + c     (32-bit floats, bit for bit)
-- >   w3..w5   d, e, f   art v = d·u + e·v + f
-- >   w6       n         the mask's vertex count, 3 .. 'maxMaskVertices'
-- >   w7..w22  x0 y0 x1 y1 …   the mask's vertices, unused ones zero
--
-- The art sheet is one picture of a whole cell: the hexagon the cell's unit cube
-- projects to, 96 × 64 pixels at native scale (a 96 × 48 top diamond over 16
-- pixels of side), placed so that its top-left corner is at the sheet's offset
-- from the projection of the cell's own origin ('faceCellOrigin'). A face
-- shows the part of that picture its own projection covers, so a top, an East
-- wall, a South wall, a ramp and a cap of the same material show the same
-- artwork, and two faces of different cells show the same texel at the same
-- place in their sheets. The affine map above takes the face's unit-square
-- coordinates to sheet coordinates in @[0, 1]@; it is computed exactly and
-- rounded once to 32 bits.
--
-- The coverage is the mask polygon's closed interior: a fragment whose
-- unit-square position is within the convex polygon (no two of its edge
-- functions of opposite sign) is the sampled art texel, and every other
-- fragment is transparent black. The sheet is sampled with the instance's
-- sampler choice, which the adapter sets to nearest, so the output alpha is
-- binary wherever the art's is: the material is cutout-capable and a texel
-- the art leaves transparent writes neither colour nor depth.
--
-- == Records are shared
--
-- The record depends on the face's shape in its view frame, its index among
-- that shape's faces and the art, and not on where the cell is: the adapter
-- gives equal records one entry of the table and every face of that kind the
-- same parameter word, so a view's table is a few dozen records however many
-- faces it draws.
--
-- == The model
--
-- 'terrainModel' is the fragment function in the oracle's terms, over the same
-- inputs, in 'Double' arithmetic over the 32-bit values the record holds. A
-- fragment within 'boundaryTolerance' of a mask edge, where the device's 32-bit
-- evaluation and the model's may fall on either side, is given the alpha the
-- cutout threshold sits at, which the oracle reports as indeterminate rather
-- than as a pass or a failure. A material model cannot be indeterminate in the
-- ordered path, so a scene drawn there must keep its pixel centres off the mask
-- edges, which the fixtures check.
--
-- State, ownership and lifetime: none. Every value is immutable and every
-- function pure.
module Hetoimasia.Terrain.Render2D.Material
  ( -- * The art
    ArtSheet (..)
  , isoSheet
  , TerrainStyle (..)
  , styleFromList
  , styleSheet

    -- * The record
  , recordLayout
  , maxMaskVertices
  , recordWordCount
  , faceRecord

    -- * Adapting a plan
  , MaterialRefusal (..)
  , terrainView
  , AdaptedFace (..)
  , Adapted (..)
  , adaptFaces
  , adaptedInstance
  , adaptedMaterialData

    -- * The model
  , terrainModel
  , Coverage (..)
  , maskCoverage
  , boundaryTolerance
  ) where

import qualified Data.ByteString as ByteString
import qualified Data.Map.Strict as Map
import Data.Word (Word32)
import GHC.Float (castFloatToWord32, castWord32ToFloat)
import Hetoimasia.Math.Affine2 (columns)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.TwoD.Material
  ( MaterialData (..)
  , MaterialRecord (..)
  , MaterialRef
  , RecordLayout (..)
  )
import Hetoimasia.Render.TwoD.Oracle.Material
  ( Colour (..)
  , MaterialInput (..)
  , MaterialModel (..)
  )
import Hetoimasia.Render.TwoD.Snapshot (Camera (..), Instance (..), Layer, Sampler (..), View (..))
import Hetoimasia.Terrain.Cell (MaterialId)
import Hetoimasia.Terrain.Render2D.Plan
  ( Plan
  , PlannedFace (..)
  , faceInstance
  , planView
  )
import Hetoimasia.Terrain.Render2D.Projection (ViewSetup (..), rationalToFloat, rvCentre, rvSetup, rvZoom)

-- ---------------------------------------------------------------------------
-- The art

-- | One picture of a whole cell, from the caller's texture data.
data ArtSheet = ArtSheet
  { sheetTexture ∷ !TextureHandle
  -- ^ The registered texture: a single level, whose alpha is what the caller
  -- registered its cutout mark for.
  , sheetWidth ∷ !Int
  -- ^ Pixels at native scale.
  , sheetHeight ∷ !Int
  , sheetOffset ∷ !(Rational, Rational)
  -- ^ Where the sheet's top-left corner is, in render-world pixels, from the
  -- projection of the cell's own origin.
  }
  deriving stock (Eq, Ord, Show)

-- | A sheet laid out as the 96 × 64 hexagon of a unit cell's projection: its
-- top-left corner is 48 pixels left of the cell's origin and 16 above it (the
-- height of the top diamond's corner over the origin at the cell's top plane).
isoSheet ∷ TextureHandle → ArtSheet
isoSheet texture = ArtSheet texture 96 64 (-48, -16)

-- | The caller's materials: the art each authored material is drawn with.
newtype TerrainStyle = TerrainStyle (Map.Map MaterialId ArtSheet)
  deriving stock (Eq, Show)

styleFromList ∷ [(MaterialId, ArtSheet)] → TerrainStyle
styleFromList = TerrainStyle . Map.fromList

-- | The art a material is drawn with; no sheet is invented for a material the
-- caller did not name.
styleSheet ∷ TerrainStyle → MaterialId → Maybe ArtSheet
styleSheet (TerrainStyle sheets) material = Map.lookup material sheets

-- ---------------------------------------------------------------------------
-- The record

-- | Most vertices of a face's mask the record holds. A face of the shared solids
-- has at most six.
maxMaskVertices ∷ Int
maxMaskVertices = 8

-- | The words of a record: six of the art's affine map, the vertex count and the
-- vertices' coordinates.
recordWordCount ∷ Int
recordWordCount = 7 + 2 * maxMaskVertices

-- | The record layout the material declares: the art sheet's handle and the
-- words above.
recordLayout ∷ RecordLayout
recordLayout = RecordLayout 1 (fromIntegral recordWordCount)

-- | Why a face could not be adapted. Nothing is approximated.
data MaterialRefusal
  = -- | The style names no art for this authored material.
    NoArt !MaterialId
  | -- | The mask has fewer than three or more than 'maxMaskVertices' vertices.
    MaskVertexCount !Int
  | -- | A coefficient or coordinate is not representable in 32 bits.
    UnrepresentableRecord !String
  | -- | The sheet has a zero extent.
    EmptySheet !MaterialId
  deriving stock (Eq, Show)

-- | The record of a face on an art sheet.
faceRecord ∷ ArtSheet → PlannedFace → Either MaterialRefusal MaterialRecord
faceRecord sheet face = do
  let count = length (faceMask face)
  if count < 3 || count > maxMaskVertices then Left (MaskVertexCount count) else pure ()
  if sheetWidth sheet <= 0 || sheetHeight sheet <= 0 then Left (UnrepresentableRecord "a sheet of zero extent") else pure ()
  let (V2 qa qb, V2 qc qd, V2 qx qy) = columns (faceQuad face)
      (ox, oy) = faceCellOrigin face
      (sx, sy) = sheetOffset sheet
      w = fromIntegral (sheetWidth sheet) ∷ Rational
      h = fromIntegral (sheetHeight sheet) ∷ Rational
      -- Sheet pixel = quad (u, v) − (cell origin + sheet offset); sheet coordinate = pixel / extent.
      affine =
        [ toRational qa / w
        , toRational qc / w
        , (toRational qx - ox - sx) / w
        , toRational qb / h
        , toRational qd / h
        , (toRational qy - oy - sy) / h
        ]
      vertices = concat [[x, y] | (x, y) ← faceMask face]
  floats ← maybe (Left (UnrepresentableRecord "a record coefficient")) Right (traverse rationalToFloat (affine <> vertices))
  let (affineWords, vertexWords) = splitAt 6 (map castFloatToWord32 floats)
      padding = replicate (2 * maxMaskVertices - 2 * count) 0
  pure (MaterialRecord [sheetTexture sheet] (affineWords <> [fromIntegral count] <> vertexWords <> padding))

-- ---------------------------------------------------------------------------
-- Adapting a plan

-- | A planned face with the table entry that draws it.
data AdaptedFace = AdaptedFace
  { adaptedFace ∷ !PlannedFace
  , adaptedSheet ∷ !ArtSheet
  , adaptedParameter ∷ !Word32
  -- ^ The index of its record in 'adaptedRecords'.
  }
  deriving stock (Eq, Show)

-- | A plan's faces with the table of the distinct records they need.
data Adapted = Adapted
  { adaptedFaces ∷ ![AdaptedFace]
  -- ^ In the plan's order.
  , adaptedRecords ∷ ![MaterialRecord]
  -- ^ The table the parameter words index, in the order records first appear.
  }
  deriving stock (Eq, Show)

-- | Give every face the record that draws it on its material's art, sharing a
-- record between faces that need an equal one.
adaptFaces ∷ TerrainStyle → [PlannedFace] → Either MaterialRefusal Adapted
adaptFaces style faces = do
  (reversedFaces, _, reversedRecords) ← foldl' step (Right ([], Map.empty, [])) faces
  pure (Adapted (reverse reversedFaces) (reverse reversedRecords))
  where
    step acc face = do
      (done, known, records) ← acc
      sheet ← maybe (Left (NoArt (faceMaterial face))) Right (styleSheet style (faceMaterial face))
      record ← faceRecord sheet face
      case Map.lookup record known of
        Just index → pure (AdaptedFace face sheet index : done, known, records)
        Nothing →
          let index = fromIntegral (Map.size known)
           in pure (AdaptedFace face sheet index : done, Map.insert record index known, record : records)

-- | The render-2d instance that draws an adapted face with the registered
-- material: the face's quad and depth key, the art as the instance's texture
-- (so its cutout mark routes the face), the whole unit square as its texture
-- rectangle, nearest sampling, and the face's record as its parameter word.
adaptedInstance ∷ MaterialRef → AdaptedFace → Instance
adaptedInstance material adapted =
  (faceInstance (sheetTexture (adaptedSheet adapted)) (adaptedFace adapted))
    { instanceMaterial = material
    , instanceParameter = adaptedParameter adapted
    , instanceSampler = SamplerNearest
    }

-- | The render-2d view that draws a plan's faces: the camera, viewport and
-- settings the plan's own view maps, so that drawing and picking share one
-- mapping, holding the adapted table for each of these materials and these
-- layers. 'Nothing' when the camera is not representable in 32 bits, which a
-- plan's view never is.
terrainView ∷ Plan → [(MaterialRef, MaterialData)] → [Layer] → Maybe View
terrainView plan held layers = do
  let view = planView plan
      (cx, cy) = rvCentre view
      setup = rvSetup view
  px ← rationalToFloat cx
  py ← rationalToFloat cy
  pure
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

-- | What a view holds for the material: the table, and no push block (the
-- material has none).
adaptedMaterialData ∷ Adapted → MaterialData
adaptedMaterialData adapted = MaterialData (adaptedRecords adapted) ByteString.empty

-- ---------------------------------------------------------------------------
-- The model

-- | Where a point is against a mask.
data Coverage = Inside | Outside | Boundary
  deriving stock (Eq, Show)

-- | How far from an edge's line, in unit-square units (the face's own side is
-- one), a point must be to be decided. A pixel is about a hundredth of a face's
-- side at native scale, so this is a few thousandths of a pixel; a 32-bit
-- evaluation is within a few millionths.
boundaryTolerance ∷ Double
boundaryTolerance = 1.0e-4

-- | Whether a point is inside the polygon, taken as convex: inside when no two
-- of its edges' signed distances have opposite signs, outside when two differ
-- by more than the tolerance, and 'Boundary' when the point is within the
-- tolerance of an edge's line without being clearly outside.
maskCoverage ∷ [(Double, Double)] → (Double, Double) → Coverage
maskCoverage polygon (px, py)
  | clearlyOutside = Outside
  | any ((<= boundaryTolerance) . abs) distances = Boundary
  | otherwise = Inside
  where
    edges = zip polygon (drop 1 polygon <> take 1 polygon)
    distances =
      [ ((bx - ax) * (py - ay) - (by - ay) * (px - ax)) / sqrt (max 1.0e-30 ((bx - ax) ^ (2 ∷ Int) + (by - ay) ^ (2 ∷ Int)))
      | ((ax, ay), (bx, by)) ← edges
      ]
    clearlyOutside = any (> boundaryTolerance) distances && any (< negate boundaryTolerance) distances

-- | The 32-bit value of a record word.
wordFloat ∷ Word32 → Double
wordFloat = realToFrac . castWord32ToFloat

-- | The terrain material's fragment function, as the oracle takes it: the art
-- texel at the face's own place in the sheet where the mask covers the
-- fragment, transparent black where it does not, and an alpha on the cutout
-- threshold within the tolerance of a mask edge, which the oracle reports as
-- indeterminate. A record of another layout holds nothing and draws nothing.
terrainModel ∷ MaterialModel
terrainModel = MaterialModel $ \input → case materialRecord input of
  MaterialRecord [handle] ws
    | length ws == recordWordCount
    , (affineWords, countWord : rest) ← splitAt 6 ws
    , [a, b, c, d, e, f] ← map wordFloat affineWords
    , n ← fromIntegral countWord
    , n >= 3 && n <= maxMaskVertices →
        let vertices = pairs (take (2 * n) (map wordFloat rest))
            (u, v) = materialUv input
         in case maskCoverage vertices (u, v) of
              Outside → Right (Colour 0 0 0 0)
              Boundary → Right (Colour 0 0 0 0.5)
              Inside → materialSample input handle (a * u + b * v + c, d * u + e * v + f)
  _ → Right (Colour 0 0 0 0)
  where
    pairs = \case
      x : y : more → (x, y) : pairs more
      _ → []
