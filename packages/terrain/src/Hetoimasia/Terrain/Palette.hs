-- | The arena-local material palette and the 17-bit packed cell value.
--
-- A packed cell is 17 bits. Bit 16 is the family tag: clear for a side key and
-- set for a corner key. Bits 4 to 15 are a palette index and bits 0 to 3 the
-- value within the family: a side identity (@0 .. 15@) or a nonzero corner mask
-- (@1 .. 15@). Index 0 is air and is encoded canonically as the all-zero value;
-- indices @1 .. 4095@ map to stable authored 'MaterialId's. A valid historic
-- 16-bit word is a side key with a clear tag, so it zero-extends to itself.
-- Every key survives packing: a solid with side 0 is a different value from
-- air, and side 0, side 15 and corner 15 stay distinct. A value that would
-- truncate or alias is refused with a 'PaletteError': a full palette, a
-- material the palette does not hold, an index it has not assigned, bits above
-- the tag, an air index carrying any other bit, or a corner value of zero.
--
-- 'unpackCell' decodes a side value to 'Solid' and a corner value to
-- 'CornerSolid'; 'unpackKey' decodes either family to its material and key. A
-- @'CornerSolid' _ 0@ is air and has no packed form, so 'packCell' refuses it
-- with 'PackedCornerZero'. The legacy 16-bit word ('packedWord') exists only
-- for a side value; a corner value has no such word, and 'packedBits' is the
-- full 17-bit value.
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
  , packedBits
  , packedWord
  , mkPackedCell
  , mkPackedBits
  , packedIndex
  , packedShape
  , packedIsCorner

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
  , packKey
  , internKey
  , packCorner
  , internCorner
  , packIndexed
  , unpackKey
  ) where

import Data.Bits (shiftL, shiftR, testBit, (.&.), (.|.))
import qualified Data.IntMap.Strict as IntMap
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word (Word16, Word32)
import Hetoimasia.Terrain.Cell
import Hetoimasia.Terrain.Internal.Packed (PackedCell (..))
import Hetoimasia.Terrain.Internal.Shape (CornerMask (..), ShapeId (..), ShapeKey (..))
import Hetoimasia.Terrain.Source (Source, sourceMaterials)
import Hetoimasia.Terrain.Shape

-- | Air, canonically the zero value.
packedAir ∷ PackedCell
packedAir = PackedCell 0

-- | The full 17-bit value, for payload accounting and encoding: the tag at bit
-- 16 over the 16-bit legacy word.
packedBits ∷ PackedCell → Word32
packedBits (PackedCell w) = w

-- | The historic 16-bit word, for a side value or air. A corner value has no
-- such word and yields 'Nothing', so no caller truncates one.
packedWord ∷ PackedCell → Maybe Word16
packedWord packed@(PackedCell w)
  | packedIsCorner packed = Nothing
  | otherwise = Just (fromIntegral w)

-- | The palette index, @0 .. 4095@.
packedIndex ∷ PackedCell → Word16
packedIndex (PackedCell w) = fromIntegral ((w .&. 0xFFFF) `shiftR` 4)

-- | The value within the family, @0 .. 15@: a side identity, or a corner mask
-- when 'packedIsCorner'.
packedShape ∷ PackedCell → Word16
packedShape (PackedCell w) = fromIntegral (w .&. 15)

-- | Whether the family tag marks a corner key.
packedIsCorner ∷ PackedCell → Bool
packedIsCorner (PackedCell w) = testBit w cornerBit

cornerBit ∷ Int
cornerBit = 16

-- | Why a palette or packing operation was refused.
data PaletteError
  = -- | Interning one more material would exceed 'maxPaletteEntries'.
    PaletteFull
  | -- | A cell names a material the palette has not assigned an index.
    MaterialNotInPalette MaterialId
  | -- | A packed value names an index the palette has not assigned.
    UnassignedIndex !Word16
  | -- | An air index carrying any other bit: not a canonical value.
    NonCanonicalAir !Word32
  | -- | A value with a bit set above the family tag.
    UnknownTagBits !Word32
  | -- | A corner value of zero, which is air and has no packed form.
    PackedCornerZero
  deriving stock (Eq, Show)

-- | The most materials a palette holds: the non-air indices of 12 bits.
maxPaletteEntries ∷ Int
maxPaletteEntries = maxAuthoredMaterials

-- | Check a historic 16-bit word for structural validity: an air index must
-- carry shape zero. The value is a side key and zero-extends. Whether a non-air
-- index is assigned is the palette's concern.
mkPackedCell ∷ Word16 → Either PaletteError PackedCell
mkPackedCell = mkPackedBits . fromIntegral

-- | Check a raw 17-bit value for structural validity: no bit above the tag, an
-- air index carrying no other bit, and no corner value of zero. Whether a
-- non-air index is assigned is the palette's concern.
mkPackedBits ∷ Word32 → Either PaletteError PackedCell
mkPackedBits w
  | w `shiftR` (cornerBit + 1) /= 0 = Left (UnknownTagBits w)
  | (w .&. 0xFFFF) `shiftR` 4 == 0 && w /= 0 = Left (NonCanonicalAir w)
  | testBit w cornerBit && w .&. 15 == 0 = Left PackedCornerZero
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
packCell palette (Solid material shape) = packKey palette material (sideKey shape)
packCell palette (CornerSolid material mask) = packCorner palette material mask

-- | Pack a cell, interning its material first.
internCell ∷ Cell → Palette → Either PaletteError (PackedCell, Palette)
internCell Air palette = Right (packedAir, palette)
internCell (Solid material shape) palette = internKey material (sideKey shape) palette
internCell (CornerSolid material mask) palette = internCorner material mask palette

-- | Pack a material and a shape key of either family against a palette that
-- already holds the material.
packKey ∷ Palette → MaterialId → ShapeKey → Either PaletteError PackedCell
packKey palette material key = case paletteIndex palette material of
  Nothing → Left (MaterialNotInPalette material)
  Just index → Right (pack index key)

-- | Pack a material and a shape key, interning the material first.
internKey ∷ MaterialId → ShapeKey → Palette → Either PaletteError (PackedCell, Palette)
internKey material key palette = do
  (index, palette') ← internMaterial material palette
  pure (pack index key, palette')

-- | Pack a material and a corner mask against a palette that already holds the
-- material. Mask zero is air and is refused.
packCorner ∷ Palette → MaterialId → CornerMask → Either PaletteError PackedCell
packCorner palette material mask = case resolveCorner mask of
  Nothing → Left PackedCornerZero
  Just key → packKey palette material key

-- | Pack a material and a corner mask, interning the material first. Mask zero
-- is refused before the palette is touched.
internCorner ∷ MaterialId → CornerMask → Palette → Either PaletteError (PackedCell, Palette)
internCorner material mask palette = case resolveCorner mask of
  Nothing → Left PackedCornerZero
  Just key → internKey material key palette

-- | Pack an assigned palette index and a shape key. An index the palette has not
-- assigned, including 0, is refused.
packIndexed ∷ Palette → Word16 → ShapeKey → Either PaletteError PackedCell
packIndexed palette index key = case paletteMaterial palette index of
  Nothing → Left (UnassignedIndex index)
  Just _ → Right (pack index key)

pack ∷ Word16 → ShapeKey → PackedCell
pack index (SideKey (ShapeId shape)) = PackedCell (indexBits index .|. fromIntegral shape)
pack index (CornerKey mask) = PackedCell ((1 `shiftL` cornerBit) .|. indexBits index .|. fromIntegral (cornerMaskValue mask))

indexBits ∷ Word16 → Word32
indexBits index = fromIntegral index `shiftL` 4

-- | Decode a packed value against a palette to its material and shape key, or
-- 'Nothing' for air. An index the palette has not assigned and a noncanonical
-- encoding are refused.
unpackKey ∷ Palette → PackedCell → Either PaletteError (Maybe (MaterialId, ShapeKey))
unpackKey palette packed@(PackedCell w)
  | packedIndex packed == 0 = if w == 0 then Right Nothing else Left (NonCanonicalAir w)
  | packedIsCorner packed && packedShape packed == 0 = Left PackedCornerZero
  | otherwise = case paletteMaterial palette (packedIndex packed) of
      Nothing → Left (UnassignedIndex (packedIndex packed))
      Just material → Right (Just (material, key))
  where
    value = fromIntegral (packedShape packed)
    key
      | packedIsCorner packed = CornerKey (CornerMask value)
      | otherwise = SideKey (ShapeId value)

-- | Decode a packed value against a palette to its 'Cell': a side value to
-- 'Solid' and a corner value to 'CornerSolid'. An index the palette has not
-- assigned and a noncanonical encoding are refused.
unpackCell ∷ Palette → PackedCell → Either PaletteError Cell
unpackCell palette packed = do
  decoded ← unpackKey palette packed
  case decoded of
    Nothing → Right Air
    Just (material, SideKey shape) → Right (Solid material shape)
    Just (material, CornerKey mask) → Right (CornerSolid material mask)
