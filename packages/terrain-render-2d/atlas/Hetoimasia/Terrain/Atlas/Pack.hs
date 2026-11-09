-- | The deterministic offline packer of terrain atlases (TRA-17).
--
-- A parent atlas is a grid of logical 96 x 64 canvases, @columns@ wide, filled row by row in the
-- order given. A canvas is copied byte for byte: it is never rotated, trimmed, scaled or altered,
-- and no gutter is added, because sampling snaps to a texel centre inside its own region and
-- never reads outside it. The cells of the grid the canvases do not fill are zero, so unused
-- pixels have zero alpha and carry no colour or normal.
--
-- The function is pure and total over its checked inputs: the same canvases in the same order
-- give the same bytes and rectangles, with no clock, path or random value. It is bounded: the
-- number of canvases, the extent and the number of texels are checked before any byte is built.
--
-- State, ownership and lifetime: none. Offline asset preparation only; runtime packs nothing.
module Hetoimasia.Terrain.Atlas.Pack
  ( Canvas (..)
  , Placed (..)
  , PackedAtlas (..)
  , PackError (..)
  , describePackError
  , packGrid
  , colourColumns
  , normalColumns
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.List (sort)
import Data.Word (Word32)
import Hetoimasia.Terrain.Atlas.Manifest
  ( logicalHeight
  , logicalWidth
  , maxAtlasAxis
  , maxAtlasTexels
  , maxRegionsPerAtlas
  )

-- | A logical image to place: its identity and its 96 x 64 RGBA8 texels, top row first.
data Canvas = Canvas
  { canvasId ∷ !String
  , canvasTexels ∷ !ByteString
  }
  deriving stock (Eq, Show)

-- | Where a canvas landed.
data Placed = Placed
  { placedId ∷ !String
  , placedX ∷ !Word32
  , placedY ∷ !Word32
  }
  deriving stock (Eq, Show)

-- | A packed parent image: its extent, its RGBA8 texels and where each canvas is.
data PackedAtlas = PackedAtlas
  { packedWidth ∷ !Word32
  , packedHeight ∷ !Word32
  , packedTexels ∷ !ByteString
  , packedPlacements ∷ ![Placed]
  }
  deriving stock (Eq, Show)

data PackError
  = PackNoCanvases
  | PackBadColumns !Int
  | PackTooManyCanvases !Int
  | -- | The identity and the length of its texels, which is not 96 x 64 x 4.
    PackBadCanvas !String !Int
  | PackDuplicate !String
  | PackTooLarge !Integer !Integer
  deriving stock (Eq, Show)

describePackError ∷ PackError → String
describePackError = \case
  PackNoCanvases → "no canvases to pack"
  PackBadColumns n → show n <> " columns is not a usable grid"
  PackTooManyCanvases n → show n <> " canvases exceed the limit of " <> show maxRegionsPerAtlas
  PackBadCanvas i n → "canvas " <> i <> " has " <> show n <> " bytes, not a 96 x 64 RGBA8 canvas"
  PackDuplicate i → "canvas " <> i <> " is listed twice"
  PackTooLarge w h → "a " <> show w <> " x " <> show h <> " atlas exceeds the bounded image limits"

-- | The columns of the colour atlas (loam, granite, blank in one row) and of the normal atlas
-- (the 46 catalog maps, eight to a row over six rows). Fixed here so the layout is a decision
-- of the recipe, not of an input.
colourColumns, normalColumns ∷ Int
colourColumns = 3
normalColumns = 8

-- | Pack the canvases into a grid of this many columns.
packGrid ∷ Int → [Canvas] → Either PackError PackedAtlas
packGrid columns canvases
  | columns < 1 = Left (PackBadColumns columns)
  | null canvases = Left PackNoCanvases
  | count > maxRegionsPerAtlas = Left (PackTooManyCanvases count)
  | (bad : _) ← [c | c ← canvases, ByteString.length (canvasTexels c) /= canvasBytes] = Left (PackBadCanvas (canvasId bad) (ByteString.length (canvasTexels bad)))
  | (dup : _) ← duplicates = Left (PackDuplicate dup)
  | width > toInteger maxAtlasAxis || height > toInteger maxAtlasAxis || width * height > maxAtlasTexels = Left (PackTooLarge width height)
  | otherwise =
      Right
        PackedAtlas
          { packedWidth = fromInteger width
          , packedHeight = fromInteger height
          , packedTexels = ByteString.concat [row y | y ← [0 .. fromInteger height - 1]]
          , packedPlacements =
              [ Placed (canvasId c) (fromIntegral (col * cw)) (fromIntegral (r * ch))
              | (index, c) ← zip [0 ..] canvases
              , let (r, col) = index `quotRem` columns
              ]
          }
  where
    count = length canvases
    cw = fromIntegral logicalWidth ∷ Int
    ch = fromIntegral logicalHeight ∷ Int
    canvasBytes = 4 * cw * ch
    usedColumns = min columns count
    -- Wide arithmetic: an extreme column count must not overflow before the bounds are checked.
    rows = (toInteger count + toInteger columns - 1) `div` toInteger columns
    width = toInteger usedColumns * toInteger cw
    height = rows * toInteger ch
    sorted = sort (map canvasId canvases)
    duplicates = [a | (a, b) ← zip sorted (drop 1 sorted), a == b]
    blank = ByteString.replicate (4 * cw) 0
    -- One atlas row: for each grid column, the canvas line, or zeros where the grid is unfilled.
    row ∷ Int → ByteString
    row y =
      let (r, line) = y `quotRem` ch
       in ByteString.concat
            [ case drop (r * columns + col) canvases of
                c : _ → ByteString.take (4 * cw) (ByteString.drop (4 * cw * line) (canvasTexels c))
                [] → blank
            | col ← [0 .. usedColumns - 1]
            ]
