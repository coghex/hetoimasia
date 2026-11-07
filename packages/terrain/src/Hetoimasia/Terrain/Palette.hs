-- | The arena-local material palette and the 16-bit packed cell value.
--
-- A packed cell is 16 bits: the high 12 bits are a palette index and the low
-- four bits a shape identity. Index 0 is air and is encoded canonically as the
-- all-zero value; indices @1 .. 4095@ map to stable authored 'MaterialId's.
-- Every shape identity survives packing: a solid with shape 0 is a different
-- value from air, and shapes 0 and 15 stay distinct. A value that would
-- truncate or alias is refused with a 'PaletteError': a full palette, a
-- material the palette does not hold, an index it has not assigned, or an air
-- index carrying a nonzero shape.
--
-- This packing is internal to terrain storage. It is not a Lua numeric
-- identifier, a save-file format or a promise of compatibility with another
-- engine's numbering.
--
-- State, ownership and lifetime: a 'Palette' is an immutable value. The arena
-- that interns materials owns the palette it keeps; interning returns a new
-- value and leaves the old one valid, so a failure preserves the previous
-- palette. Indices are stable: an assigned index is never reassigned or reused.
module Hetoimasia.Terrain.Palette
  ( -- * Packed values
    PackedCell
  , packedAir
  , packedWord
  , mkPackedCell
  , packedIndex
  , packedShape

    -- * Palette
  , Palette
  , PaletteError (..)
  , maxPaletteEntries
  , emptyPalette
  , paletteSize
  , paletteMaterials
  , paletteIndex
  , paletteMaterial
  , internMaterial
  , internSourceMaterials

    -- * Packing
  , packCell
  , internCell
  , unpackCell
  ) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import qualified Data.IntMap.Strict as IntMap
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word (Word16)
import Hetoimasia.Terrain.Cell
import Hetoimasia.Terrain.Internal.Packed (PackedCell (..))
import Hetoimasia.Terrain.Source (Source, sourceMaterials)
import Hetoimasia.Terrain.Shape

-- | Air, canonically the zero value.
packedAir ∷ PackedCell
packedAir = PackedCell 0

-- | The 16-bit value, for payload accounting and encoding.
packedWord ∷ PackedCell → Word16
packedWord (PackedCell w) = w

-- | The palette index, @0 .. 4095@.
packedIndex ∷ PackedCell → Word16
packedIndex (PackedCell w) = w `shiftR` 4

-- | The shape identity bits, @0 .. 15@.
packedShape ∷ PackedCell → Word16
packedShape (PackedCell w) = w .&. 15

-- | Why a palette or packing operation was refused.
data PaletteError
  = -- | Interning one more material would exceed 'maxPaletteEntries'.
    PaletteFull
  | -- | A cell names a material the palette has not assigned an index.
    MaterialNotInPalette MaterialId
  | -- | A packed value names an index the palette has not assigned.
    UnassignedIndex !Word16
  | -- | An air index carrying a nonzero shape: not a canonical value.
    NonCanonicalAir !Word16
  deriving stock (Eq, Show)

-- | The most materials a palette holds: the non-air indices of 12 bits.
maxPaletteEntries ∷ Int
maxPaletteEntries = maxAuthoredMaterials

-- | Check a raw 16-bit value for structural validity: an air index must carry
-- shape zero. Whether a non-air index is assigned is the palette's concern.
mkPackedCell ∷ Word16 → Either PaletteError PackedCell
mkPackedCell w
  | w `shiftR` 4 == 0 && w /= 0 = Left (NonCanonicalAir w)
  | otherwise = Right (PackedCell w)

-- | Material identifiers and the indices assigned to them.
data Palette = Palette
  { paletteByMaterial ∷ !(Map MaterialId Word16)
  , paletteByIndex ∷ !(IntMap.IntMap MaterialId)
  }
  deriving stock (Eq, Show)

-- | A palette holding no material.
emptyPalette ∷ Palette
emptyPalette = Palette Map.empty IntMap.empty

-- | The number of materials assigned.
paletteSize ∷ Palette → Int
paletteSize = Map.size . paletteByMaterial

-- | The materials in index order, index 1 first.
paletteMaterials ∷ Palette → [MaterialId]
paletteMaterials = IntMap.elems . paletteByIndex

-- | A material's index, if assigned.
paletteIndex ∷ Palette → MaterialId → Maybe Word16
paletteIndex palette material = Map.lookup material (paletteByMaterial palette)

-- | The material an index names, if assigned. Index 0 is air and names none.
paletteMaterial ∷ Palette → Word16 → Maybe MaterialId
paletteMaterial palette index = IntMap.lookup (fromIntegral index) (paletteByIndex palette)

-- | Assign the next index to a material, or return its existing one.
internMaterial ∷ MaterialId → Palette → Either PaletteError (Word16, Palette)
internMaterial material palette = case paletteIndex palette material of
  Just index → Right (index, palette)
  Nothing
    | paletteSize palette >= maxPaletteEntries → Left PaletteFull
    | otherwise →
        let index = fromIntegral (paletteSize palette + 1)
         in Right
              ( index
              , Palette
                  (Map.insert material index (paletteByMaterial palette))
                  (IntMap.insert (fromIntegral index) material (paletteByIndex palette))
              )

-- | Intern every material a source declares, in authored order, so a fresh
-- arena palette starts from the source's own numbering.
internSourceMaterials ∷ Source → Palette → Either PaletteError Palette
internSourceMaterials source palette0 = go palette0 (sourceMaterials source)
  where
    go palette [] = Right palette
    go palette (m : ms) = internMaterial m palette >>= go' ms
    go' ms (_, palette) = go palette ms

-- | Pack a cell against a palette that already holds its material.
packCell ∷ Palette → Cell → Either PaletteError PackedCell
packCell _ Air = Right packedAir
packCell palette (Solid material shape) = case paletteIndex palette material of
  Nothing → Left (MaterialNotInPalette material)
  Just index → Right (pack index shape)

-- | Pack a cell, interning its material first.
internCell ∷ Cell → Palette → Either PaletteError (PackedCell, Palette)
internCell Air palette = Right (packedAir, palette)
internCell (Solid material shape) palette = do
  (index, palette') ← internMaterial material palette
  pure (pack index shape, palette')

pack ∷ Word16 → ShapeId → PackedCell
pack index shape = PackedCell ((index `shiftL` 4) .|. fromIntegral (shapeIdValue shape))

-- | Decode a packed value against a palette, refusing an index the palette has
-- not assigned and a noncanonical air.
unpackCell ∷ Palette → PackedCell → Either PaletteError Cell
unpackCell palette packed@(PackedCell w)
  | packedIndex packed == 0 = if w == 0 then Right Air else Left (NonCanonicalAir w)
  | otherwise = case paletteMaterial palette (packedIndex packed) of
      Nothing → Left (UnassignedIndex (packedIndex packed))
      Just material → Right (Solid material (allShapeIds !! fromIntegral (packedShape packed)))
