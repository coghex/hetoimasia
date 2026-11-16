-- | A terrain view's planning inputs from borrowed regional copies (TRA-9): the terrain facts and the discovery
-- knowledge the cell-quad planner reads, made from the runtime's immutable regional snapshots and nothing else.
--
-- = Coherence
--
-- One plan reads one committed version. Several regional copies (each at most the runtime's per-hold region
-- bound) form one version only when they agree on the arena incarnation, the content revision and the knowledge
-- revision ('combineCopies'); copies of different versions are never mixed, and the caller asks again. A copy holds
-- no residency, so the residency generations of agreeing copies may differ; the plan is labelled with the newest of
-- them, which names no data the copies do not hold.
--
-- = What is known, and what is pending
--
-- * Terrain: a region whose terrain part is ready contributes its removed intervals and is available over its 32
--   levels; one whose part is unavailable, or a region no copy holds, is unavailable, which the planner keeps apart
--   from air and solid.
-- * Knowledge: each cell of a region whose knowledge part is ready is what discovery knows of it
--   (@FullyUnknown@ is undiscovered fog, @KnownSolidUnknownVoid@ a known solid over an unknown void, @Ordinary@ known
--   whole); everything else is 'CellPending', the planner's default here, so retained knowledge not yet read is
--   never fog and never air. A uniform region is one summary; other regions are exact column runs.
--
-- Nothing here does IO, keeps state or reads a cell outside a copy: the work is proportional to the copies' runs.
module Hetoimasia.LuaEngine.Graphics.TerrainView.Inputs
  ( CopySet
  , copyArena
  , copyContent
  , copyKnowledge
  , copyGeneration
  , copyRegions
  , copySnapshots
  , generationIdentity
  , combineCopies
  , Incoherent (..)
  , InputsError (..)
  , planInputs
  , plannerKnowledge
  , knowledgeState
  ) where

import Data.Bits (setBit, shiftR, xor, (.&.))
import Data.Int (Int64)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Word (Word64)
import Hetoimasia.Terrain.Cell (Column (..), ZRange, mkZRange)
import Hetoimasia.Terrain.Changes (ChangeError, ChangeLimits, changesFromIntervals)
import Hetoimasia.Terrain.Coordinate (RegionCoord (..), axisFromInteger)
import qualified Hetoimasia.Terrain.Discovery as D
import Hetoimasia.Terrain.Render2D.Facts (Availability, ChunkKey (..), TerrainFacts (..), Versions (..), mkAvailability)
import Hetoimasia.Terrain.Render2D.Knowledge (CellKnowledge (..), Knowledge, KnowledgeError, KnowledgeSpec (..), mkKnowledge)
import Hetoimasia.Terrain.Residency (ArenaId (..), Revision (..))
import Hetoimasia.Terrain.Runtime
  ( RegionPart (..)
  , RegionSnapshot
  , regionKnowledge
  , regionSnapshotContentRevision
  , regionSnapshotGeneration
  , regionSnapshotIncarnation
  , regionSnapshotKnowledgeRevision
  , regionSnapshotRegions
  , regionSnapshotSource
  , regionTerrain
  )
import Hetoimasia.Terrain.Source (Source)

-- | Regional copies of one committed version.
data CopySet = CopySet
  { copyArena ∷ !ArenaId
  , copyContent ∷ !Revision
  , copyKnowledge ∷ !Revision
  , copyGeneration ∷ !Word64
    -- ^ The copies' residency identity: their one generation, or a digest naming every one of them.
  , copySource ∷ !Source
  , copySnapshots ∷ ![RegionSnapshot]
  , copyRegions ∷ !(Set RegionCoord)
  }

-- | Why copies were not combined: the identities of the first copy and of the first that disagrees with it.
data Incoherent
  = NoCopies
  | CopiesDisagree !(ArenaId, Revision, Revision) !(ArenaId, Revision, Revision)
  deriving (Eq, Show)

-- | Combine copies of one version; refuse copies of more than one.
combineCopies ∷ [RegionSnapshot] → Either Incoherent CopySet
combineCopies [] = Left NoCopies
combineCopies copies@(first : rest) =
  case [identityOf other | other ← rest, identityOf other /= identityOf first] of
    disagreeing : _ → Left (CopiesDisagree (identityOf first) disagreeing)
    [] →
      Right
        CopySet
          { copyArena = regionSnapshotIncarnation first
          , copyContent = regionSnapshotContentRevision first
          , copyKnowledge = regionSnapshotKnowledgeRevision first
          , copyGeneration = generationIdentity (map regionSnapshotGeneration copies)
          , copySource = regionSnapshotSource first
          , copySnapshots = copies
          , copyRegions = Set.fromList (concatMap regionSnapshotRegions copies)
          }
  where
    identityOf snapshot = (regionSnapshotIncarnation snapshot, regionSnapshotContentRevision snapshot, regionSnapshotKnowledgeRevision snapshot)

-- | The residency identity of copies with these generations: the generation itself when they agree; otherwise an FNV-1a
-- digest of the distinct generations in ascending order, with the top bit set.
generationIdentity ∷ [Word64] → Word64
generationIdentity generations = case Set.toAscList (Set.fromList generations) of
  [one] → one
  distinct → setBit (foldl' (\acc g → foldl' (\h byte → (h `xor` byte) * 1099511628211) acc (bytesOf g)) 14695981039346656037 distinct) 63
  where
    bytesOf g = [(g `shiftR` (8 * k)) .&. 255 | k ← [0 .. 7]]

-- | Why the inputs could not be made from coherent copies: a defect of the copies or of the bounds, never a
-- pending region.
data InputsError
  = -- | The removed intervals exceed the caller's bound on retained removals.
    InputsChanges !ChangeError
  | -- | The knowledge does not check.
    InputsKnowledge !KnowledgeError
  | -- | A region's level range is not representable.
    InputsRegionRange !RegionCoord
  deriving (Eq, Show)

-- | The facts and the knowledge of a coherent copy set.
planInputs ∷ ChangeLimits → CopySet → Either InputsError (TerrainFacts, Knowledge)
planInputs limits copies = do
  let readyTerrain = [(region, intervals) | snapshot ← copySnapshots copies, region ← regionSnapshotRegions snapshot, PartReady intervals ← [regionTerrain snapshot region]]
  changes ← either (Left . InputsChanges) Right (changesFromIntervals limits (concatMap snd readyTerrain))
  available ← traverse (\(region, _) → (,) (chunkOf region) . pure <$> levelRange region) readyTerrain
  knowledge ← plannerKnowledge copies
  pure
    ( TerrainFacts
        { factsVersions = versionsOf copies
        , factsSource = copySource copies
        , factsChanges = changes
        , factsAvailability = availabilityOf available
        }
    , knowledge
    )
  where
    availabilityOf ∷ [(ChunkKey, [ZRange])] → Availability
    availabilityOf = mkAvailability

versionsOf ∷ CopySet → Versions
versionsOf copies =
  let ArenaId arena = copyArena copies
      Revision content = copyContent copies
   in Versions arena content (copyGeneration copies)

-- | The planner's knowledge of a coherent copy set: pending by default; each ready region's discovery answers.
plannerKnowledge ∷ CopySet → Either InputsError Knowledge
plannerKnowledge copies =
  either (Left . InputsKnowledge) Right $
    mkKnowledge
      KnowledgeSpec
        { specRevision = let Revision knowledge = copyKnowledge copies in knowledge
        , specDefault = CellPending
        , specRegions = [(chunkOf region, toInteger (regionZ region), knowledgeState state) | (region, Left state) ← ready]
        , specColumns = Map.toList (Map.map (sortOn (\(lo, _, _) → lo)) (Map.fromListWith (<>) (concat [columns | (_, Right columns) ← ready])))
        }
  where
    ready =
      [ (region, summarised region known)
      | snapshot ← copySnapshots copies
      , region ← regionSnapshotRegions snapshot
      , PartReady known ← [regionKnowledge snapshot region]
      ]
    summarised region known = case D.regionKnowledgeClasses known of
      [[(_, _, only)]] → Left only
      _ →
        Right
          [ (column, [(toInteger lo, toInteger hi, knowledgeState state) | (lo, hi, state) ← runs])
          | column ← regionColumns region
          , Just runs ← [D.regionKnowledgeColumn known column]
          ]

-- | The planner's state of what discovery knows of a cell.
knowledgeState ∷ D.CellKnowledge → CellKnowledge
knowledgeState known = case D.presentation known of
  D.FullyUnknown → CellUndiscovered
  D.KnownSolidUnknownVoid → CellSolidKnown
  D.Ordinary → CellDiscovered

-- A region's horizontal chunk: the region's X and Y index the same 16 x 16 columns.
chunkOf ∷ RegionCoord → ChunkKey
chunkOf region = ChunkKey (regionX region) (regionY region)

-- A region's 32 levels.
levelRange ∷ RegionCoord → Either InputsError ZRange
levelRange region =
  let lo = toInteger (regionZ region) * 32
   in either (const (Left (InputsRegionRange region))) Right (mkZRange lo (lo + 32))

-- A region's 256 columns.
regionColumns ∷ RegionCoord → [Column]
regionColumns region =
  [ Column x y
  | dy ← [0 .. 15 ∷ Int64]
  , dx ← [0 .. 15 ∷ Int64]
  , Right x ← [axisFromInteger (toInteger (regionX region) * 16 + toInteger dx)]
  , Right y ← [axisFromInteger (toInteger (regionY region) * 16 + toInteger dy)]
  ]
