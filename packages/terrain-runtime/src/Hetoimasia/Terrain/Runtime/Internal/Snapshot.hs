-- | Immutable CPU snapshots of held regions.
--
-- A snapshot is a value: the resident detail of exactly the regions it holds
-- (restricted when it is taken, so what it keeps alive is what its hold
-- charges), the palette that decodes it, and the incarnation, content revision
-- and residency generation it was taken at. It is coherent through later edits,
-- eviction and the arena's closure for as long as it is borrowed, and it grants
-- no authority: it cannot be used to make a request or to publish.
module Hetoimasia.Terrain.Runtime.Internal.Snapshot
  ( Snapshot (..)
  , SnapshotCell (..)
  , snapshotCell
  ) where

import Data.Word (Word64)
import Hetoimasia.Terrain.Cell (Cell)
import Hetoimasia.Terrain.Coordinate (RegionCoord, TileCoord, decomposeTile)
import Hetoimasia.Terrain.Palette (Palette)
import Hetoimasia.Terrain.Residency (ArenaId, Revision)
import Hetoimasia.Terrain.Resident (Resident, residentCell)

-- | A held, immutable view of some regions. The constructor is private.
data Snapshot = Snapshot
  { snapshotIncarnation ∷ !ArenaId
  , snapshotRevision ∷ !Revision
  , snapshotGeneration ∷ !Word64
  , snapshotRegions ∷ ![RegionCoord]
  , snapshotPalette ∷ !Palette
  , snapshotResident ∷ !Resident
  }

-- | What a snapshot says about a cell. Unknown detail is distinct from air.
data SnapshotCell
  = -- | The cell is in a region this snapshot does not hold.
    NotHeld
  | -- | The cell is in a held region but its detail was not loaded.
    Unloaded
  | -- | The loaded cell, air included.
    Known !Cell
  deriving stock (Eq, Show)

-- | The cell at a tile as of the snapshot.
snapshotCell ∷ Snapshot → TileCoord → SnapshotCell
snapshotCell snapshot tile
  | region `notElem` snapshotRegions snapshot = NotHeld
  | otherwise = case residentCell (snapshotPalette snapshot) (snapshotResident snapshot) tile of
      Right (Just cell) → Known cell
      _ → Unloaded
  where
    (region, _) = decomposeTile tile
