-- | The pure discovery state machine: paired removal staging, bounded
-- discovery batches, knowledge queries and replay.
--
-- See "Hetoimasia.Terrain.Discovery" for the contract. This module holds the
-- mechanism; its types are re-exported there with their constructors withheld.
--
-- == The model in one paragraph
--
-- The compiled source gives every empty space a canonical 'Node' and the set of
-- initially exterior (known) components. A removal makes a full-air cell: its
-- run of removed levels is one node, and the six faces of the cell plus its old
-- void are the connections the removal introduces. Those connections are an
-- /obligation/ staged together with the removal. A discovery batch inspects them
-- one connection at a time (a /structural update/): the neighbour's component is
-- found by exact portal overlap, and the two classes are joined in a union-find
-- forest whose roots carry whether the class is known. Knowledge therefore
-- belongs to a connected class, and joining a known class to an unknown one makes
-- the whole of the unknown class known in one record, however many source
-- components, ranges or removed runs it holds. Nothing here floods sky, visits a
-- boundary tile or instantiates an empty cell.
--
-- State, ownership and lifetime: none. Every value is immutable; every function
-- is pure. The later owner holds the 'Retained' value (or the store that
-- replaces it), supplies the arena and revision authority, and publishes a
-- 'Candidate' by applying it.
module Hetoimasia.Terrain.Internal.Discovery.Core
  ( -- * Environment
    Env
  , mkEnv
  , envLimits
  , envSharedBytes

    -- * Failures
  , Integrity (..)
  , Capacity (..)
  , Refusal (..)
  , Unresolved (..)
  , Observed (..)

    -- * Candidates
  , Candidate
  , candidateBase
  , candidateNext
  , candidateWrites
  , candidateTerrain
  , candidateKnowledge
  , candidateFrontierOnly
  , candidateReport
  , Report (..)

    -- * Staging
  , StageOutcome (..)
  , stageRemoval
  , Halt (..)
  , Step (..)
  , stepDiscovery

    -- * Retained state
  , Retained
  , newRetained
  , retainedHeader
  , retainedRecords
  , retainedProvider
  , retainedBytes
  , retainedRemovals
  , retainedFromRecords
  , ApplyError (..)
  , applyCandidate
  , recordProvider

    -- * Knowledge
  , VoidKnowledge (..)
  , SolidKnowledge (..)
  , CellKnowledge (..)
  , Presentation (..)
  , presentation
  , queryCell
  , queryRemoved
  , queryComponentKnown
  , queryKnownBoundary
  , queryNodeClass
  , ObligationState (..)
  , queryObligation
  ) where

import Control.Monad (ap)
import Data.Int (Int64)
import Data.List (nub)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe (mapMaybe)
import Data.Word (Word64)
import Hetoimasia.Terrain.Cell (Cell (..), Column (..), ZRange, mkZRange)
import Hetoimasia.Terrain.Internal.Cell (bottomLevel, topExclusive)
import Hetoimasia.Terrain.Changes (emptyChanges)
import Hetoimasia.Terrain.Coordinate (TileCoord (..), axisValue)
import Hetoimasia.Terrain.Internal.Connectivity.Index
  ( BoundaryFace
  , ComponentKey
  , Connectivity (..)
  , Stats (..)
  , VoidLookup (..)
  , componentBoundary
  , isExterior
  , lookupVoid
  )
import Hetoimasia.Terrain.Internal.Discovery.Limits
import Hetoimasia.Terrain.Internal.Discovery.Records
import Hetoimasia.Terrain.Internal.Source (Source)
import Hetoimasia.Terrain.Geometry (FaceKind (..))
import Hetoimasia.Terrain.Opening
  ( CellOpenings
  , airOpenings
  , cellComponents
  , cellFaces
  , componentIndex
  , componentPortals
  , connectCells
  , connectionArea
  , connectionTo
  , componentRefIndex
  , neighbourTile
  , openingArea
  , oppositeFace
  , portalFace
  , portalOpening
  , portalsOn
  , shapeOpenings
  )
import Hetoimasia.Terrain.Query (cellAt)
import Hetoimasia.Terrain.Residency (ArenaId, Revision (..))

-- ---------------------------------------------------------------------------
-- Environment

-- | The immutable inputs of every operation: the validated source, the
-- connectivity compiled from that same source, and the validated limits. The
-- later owner pairs a source with its own compilation; this slice cannot check
-- that, so the pairing is the caller's contract.
data Env = Env
  { envSource ∷ !Source
  , envConn ∷ !Connectivity
  , envLimitsField ∷ !DiscoveryLimits
  }

-- | Pair a source with its compiled connectivity and validated limits.
mkEnv ∷ DiscoveryLimits → Source → Connectivity → Env
mkEnv limits source conn = Env source conn limits

-- | The environment's limits.
envLimits ∷ Env → DiscoveryLimits
envLimits = envLimitsField

-- | The accounted bytes of the shared immutable source metadata the model reads:
-- the compiled connectivity, charged once per arena by the owner and never to a
-- candidate.
envSharedBytes ∷ Env → Integer
envSharedBytes = statResultBytes . cStats . envConn

-- ---------------------------------------------------------------------------
-- Failures

-- | A retained record or a provider answer that cannot be a legitimate state.
-- The operation refuses and the prior value stands.
data Integrity
  = -- | A forest chain longer than 'maxLinkChain'.
    ChainTooLong !Node
  | -- | A node naming a component the compiled source does not have.
    UnknownComponent !ComponentKey
  | -- | A record of the wrong kind or a malformed value under a key.
    MalformedRecord !RecordKey
  | -- | The header names an obligation the records do not hold.
    MissingObligation !Word64
  | -- | An obligation whose cell is not removed.
    ObligationNotRemoved !TileCoord
  | -- | Portals that connect where the compiled source has no component.
    ConnectionWithoutComponent !TileCoord
  | -- | The provider answered with a run that does not satisfy the floor query.
    BadFloor !Column !Int64
  | -- | A byte or size total that does not match the records.
    BadAccounting
  deriving stock (Eq, Show)

-- | The resource an operation could not fit.
data Capacity
  = CapacityReads
  | CapacityWrites
  | CapacityDeltaBytes
  | CapacityScratchBytes
  | CapacityRetainedBytes
  | CapacityObligations
  deriving stock (Eq, Ord, Show)

-- | Why an operation produced nothing. The previous value is unchanged and any
-- retained obligation is intact.
data Refusal
  = -- | A resource was too small: the resource, the figure needed and the figure
    -- available. Nothing was done and the work stays pending.
    CapacityBlocked !Capacity !Int !Int
  | -- | A revision or sequence would overflow; none wraps or is reused.
    AuthorityOverflow
  | -- | The records are not a legitimate state.
    Corrupt !Integrity
  deriving stock (Eq, Show)

-- | Why a query could not answer. A record the provider has not supplied is
-- pending data, never confirmed unknown.
data Unresolved
  = MissingRecord !RecordKey
  | Inconsistent !Integrity
  | ReadLimit !Int
  deriving stock (Eq, Show)

-- | A query answer and the records it read from the provider.
data Observed a = Observed
  { observedValue ∷ !(Either Unresolved a)
  , observedReads ∷ !Int
  }
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- The step monad

data Stop
  = StopMissing !RecordKey
  | StopCorrupt !Integrity
  | StopCapacity !Capacity
  | -- | A sequence or revision that would wrap.
    StopOverflow

-- | A stop and the records the provider had been asked for when it happened, so
-- an attempt that is rejected still shows what it cost.
data Failure = Failure !Stop !Int

-- | The resources one operation may use, each already the smaller of the
-- validated limit and the caller's allowance. Every figure is checked before the
-- read or the staged write it pays for.
data Caps = Caps
  { capReads ∷ !Int
  , capWrites ∷ !Int
  , capDelta ∷ !Int
  , capScratch ∷ !Int
  , capRetained ∷ !Int
  , capBase ∷ !Int
  -- ^ The accounted bytes retained before the operation, header included.
  }

-- | Scratch state of one operation: the staged writes, the records read (so a
-- repeated read costs nothing), the floor answers, the read count and the
-- running accounted cost of the staged writes.
data S = S
  { sOverlay ∷ !(Map RecordKey (Maybe Record))
  , sCache ∷ !(Map RecordKey (Maybe Record))
  , sFloor ∷ !(Map (Column, Int64) (Maybe (Int64, Int64)))
  , sReads ∷ !Int
  , sCost ∷ !Int
  , sCaps ∷ !Caps
  }

emptyS ∷ Caps → S
emptyS = S Map.empty Map.empty Map.empty 0 0

-- | The accounted scratch: every provider read is charged the largest record
-- before it is made, and every staged write its entry.
scratchNow ∷ S → Int
scratchNow s = sReads s * maxRecordBytes + sCost s

-- | The accounted candidate payload so far: the header and the staged entries.
payloadNow ∷ S → Int
payloadNow s = headerBytes + sCost s

-- | The first resource the staged state overflows, if any.
overCap ∷ S → Maybe Capacity
overCap s
  | Map.size (sOverlay s) > capWrites caps = Just CapacityWrites
  | payloadNow s > capDelta caps = Just CapacityDeltaBytes
  | scratchNow s > capScratch caps = Just CapacityScratchBytes
  | capBase caps + snd (settleWrites s) > capRetained caps = Just CapacityRetainedBytes
  | otherwise = Nothing
  where
    caps = sCaps s

overlayCost ∷ RecordKey → Maybe Record → Int
overlayCost k = maybe (tombstoneBytes k) (entryBytes k)

newtype M a = M (Env → Provider → S → Either Failure (a, S))

instance Functor M where
  fmap f (M g) = M (\e p s → case g e p s of Left x → Left x; Right (a, s') → Right (f a, s'))

instance Applicative M where
  pure a = M (\_ _ s → Right (a, s))
  (<*>) = ap

instance Monad M where
  M g >>= k = M (\e p s → case g e p s of Left x → Left x; Right (a, s') → let M h = k a in h e p s')

runM ∷ M a → Env → Provider → S → Either Failure (a, S)
runM (M f) = f

askEnv ∷ M Env
askEnv = M (\e _ s → Right (e, s))

stopWith ∷ Stop → M a
stopWith x = M (\_ _ s → Left (Failure x (sReads s)))

corrupt ∷ Integrity → M a
corrupt = stopWith . StopCorrupt

-- | Refuse a read before it is made when it would overflow the read count or
-- the scratch.
beforeRead ∷ S → Either Failure ()
beforeRead s
  | sReads s + 1 > capReads caps = Left (Failure (StopCapacity CapacityReads) (sReads s))
  | scratchNow s + maxRecordBytes > capScratch caps = Left (Failure (StopCapacity CapacityScratchBytes) (sReads s))
  | otherwise = Right ()
  where
    caps = sCaps s

-- | Read a retained record: the staged writes first, then what was already
-- read, then the provider. Each distinct provider read counts once against the
-- read limit and is checked before the provider is asked.
getRec ∷ RecordKey → M (Maybe Record)
getRec key = M $ \_ p s → case Map.lookup key (sOverlay s) of
  Just r → Right (r, s)
  Nothing → case Map.lookup key (sCache s) of
    Just r → Right (r, s)
    Nothing → do
      beforeRead s
      case fetchRecord p key of
        Found r → Right (Just r, s {sCache = Map.insert key (Just r) (sCache s), sReads = sReads s + 1})
        Absent → Right (Nothing, s {sCache = Map.insert key Nothing (sCache s), sReads = sReads s + 1})
        Unavailable k → Left (Failure (StopMissing k) (sReads s + 1))

-- | The removed run of a column with the greatest lower end at or below a level.
-- Floor answers ignore staged writes: no operation stages a run before it has
-- read every run it depends on.
floorRun ∷ Column → Int64 → M (Maybe (Int64, Int64))
floorRun col z = M $ \_ p s → case Map.lookup (col, z) (sFloor s) of
  Just r → Right (r, s)
  Nothing → do
    beforeRead s
    case fetchFloorRun p col z of
      Found run@(lo, hi)
        | lo <= z && lo < hi →
            Right
              ( Just run
              , s
                  { sFloor = Map.insert (col, z) (Just run) (sFloor s)
                  , sCache = Map.insert (KeyRun col lo) (Just (RecRun hi)) (sCache s)
                  , sReads = sReads s + 1
                  }
              )
        | otherwise → Left (Failure (StopCorrupt (BadFloor col z)) (sReads s + 1))
      Absent → Right (Nothing, s {sFloor = Map.insert (col, z) Nothing (sFloor s), sReads = sReads s + 1})
      Unavailable k → Left (Failure (StopMissing k) (sReads s + 1))

-- | Stage a write (or a deletion), refusing it before it is staged when the
-- result would overflow a resource.
stage ∷ RecordKey → Maybe Record → M ()
stage key value = M $ \_ _ s →
  let old = Map.lookup key (sOverlay s)
      cost = sCost s - maybe 0 (overlayCost key) old + overlayCost key value
      s' = s {sOverlay = Map.insert key value (sOverlay s), sCost = cost}
   in case overCap s' of
        Just cap → Left (Failure (StopCapacity cap) (sReads s))
        Nothing → Right ((), s')

putRec ∷ RecordKey → Record → M ()
putRec key r = stage key (Just r)

delRec ∷ RecordKey → M ()
delRec key = stage key Nothing

-- ---------------------------------------------------------------------------
-- The forest

-- | The implicit root of a node with no record: a source component is known
-- exactly when the compiled source calls it exterior; a run is unknown (a run
-- reaching the top boundary is made known by its own obligation).
implicitRoot ∷ Node → M Root
implicitRoot node = case node of
  SrcNode key → do
    env ← askEnv
    case isExterior (envConn env) key of
      Nothing → corrupt (UnknownComponent key)
      Just ext → pure (Root 1 ext)
  RunNode _ _ → pure (Root 1 False)

-- | The root of a node's class and the root's value. Reads at most
-- 'findReadsBound' records.
findRoot ∷ Node → M (Node, Root)
findRoot start = go start (0 ∷ Int)
  where
    go node depth
      | depth > maxLinkChain = corrupt (ChainTooLong start)
      | otherwise = do
          r ← getRec (KeyLink node)
          case r of
            Nothing → (,) node <$> implicitRoot node
            Just (RecRoot root) → pure (node, root)
            Just (RecChild parent) → go parent (depth + 1)
            Just _ → corrupt (MalformedRecord (KeyLink node))

-- | The result of joining two classes.
data Joined = AlreadyJoined | Joined [Node]

-- | Join the classes of two nodes by size, the smaller beneath the larger and a
-- tie broken by node order, so the result depends on the nodes alone. The new
-- root is known when either was. The nodes of a class that became known are
-- returned.
unionNodes ∷ Node → Node → M Joined
unionNodes a b = do
  (ra, roa) <- findRoot a
  (rb, rob) <- findRoot b
  if ra == rb
    then pure AlreadyJoined
    else do
      let aWins = rootSize roa > rootSize rob || (rootSize roa == rootSize rob && ra < rb)
          (win, wr, lose, lr) = if aWins then (ra, roa, rb, rob) else (rb, rob, ra, roa)
          known = rootKnown wr || rootKnown lr
      size ← if rootSize wr > maxBound - rootSize lr then stopWith (StopCorrupt BadAccounting) else pure (rootSize wr + rootSize lr)
      putRec (KeyLink lose) (RecChild win)
      putRec (KeyLink win) (RecRoot (Root size known))
      pure (Joined ([lose | known, not (rootKnown lr)] <> [win | known, not (rootKnown wr)]))

-- | Make a node's class known (the removal reached the upper boundary).
markKnown ∷ Node → M [Node]
markKnown node = do
  (root, ro) <- findRoot node
  if rootKnown ro
    then pure []
    else do
      putRec (KeyLink root) (RecRoot ro {rootKnown = True})
      pure [root]

-- ---------------------------------------------------------------------------
-- Cells now

-- | What a tile holds now: a removed run (named by its lower level) or its
-- source cell.
data CellNow = NowRemoved !Int64 | NowSource !Cell

cellNow ∷ TileCoord → M CellNow
cellNow tile@(TileCoord x y z) = do
  env ← askEnv
  r ← floorRun (Column x y) (axisValue z)
  pure $ case r of
    Just (lo, hi) | axisValue z < hi → NowRemoved lo
    _ → NowSource (cellAt (envSource env) emptyChanges tile)

openingsOf ∷ CellNow → CellOpenings
openingsOf (NowRemoved _) = airOpenings
openingsOf (NowSource Air) = airOpenings
openingsOf (NowSource (Solid _ shape)) = shapeOpenings shape

-- | The node of one void of a tile's current content.
nodeOf ∷ Env → TileCoord → CellNow → Int → Maybe Node
nodeOf _ (TileCoord x y _) (NowRemoved lo) _ = Just (RunNode (Column x y) lo)
nodeOf env tile (NowSource _) index = case lookupVoid (envConn env) tile index of
  InComponent key → Just (SrcNode key)
  _ → Nothing

-- ---------------------------------------------------------------------------
-- The connections of a removal

-- | The node of the run holding a removed cell.
runNodeOf ∷ TileCoord → M Node
runNodeOf tile@(TileCoord x y z) = do
  r ← floorRun (Column x y) (axisValue z)
  case r of
    Just (lo, hi) | axisValue z < hi → pure (RunNode (Column x y) lo)
    _ → corrupt (ObligationNotRemoved tile)

-- | What inspecting one connection did.
data EdgeEffect = EdgeNone | EdgeAlready | EdgeJoined | EdgeMarked

data EdgeResult = EdgeResult
  { edgeEffect ∷ !EdgeEffect
  , edgeNewlyKnown ∷ [Node]
  }

-- | Inspect connection @slot@ (1 to 6, in 'cellFaces' order) of a removal. A
-- face joins the cell's run to every component of the neighbour whose portal
-- overlaps the full face over positive area, or marks the class known when the
-- face is the upper boundary of the world. The X and Y limits and the lower
-- boundary open nothing. Slot 0, the cell's own old void, is joined when the
-- removal is staged.
inspectEdge ∷ TileCoord → Int → M EdgeResult
inspectEdge tile slot = do
  env ← askEnv
  me ← runNodeOf tile
  let face = cellFaces !! (slot - 1)
  case neighbourTile face tile of
    Left _
      | face == TopFace → do
          newly ← markKnown me
          pure (EdgeResult (if null newly then EdgeAlready else EdgeMarked) newly)
      | otherwise → pure (EdgeResult EdgeNone [])
    Right nb → do
      now ← cellNow nb
      let connections = connectCells tile airOpenings nb (openingsOf now)
          indices = nub [componentRefIndex (connectionTo c) | c ← connections]
          nodes = mapMaybe (nodeOf env nb now) indices
      if length nodes /= length indices
        then corrupt (ConnectionWithoutComponent nb)
        else do
          results ← mapM (unionNodes me) nodes
          let flips = concat [ns | Joined ns ← results]
              joined = not (null [() | Joined _ ← results])
          pure $
            if null nodes
              then EdgeResult EdgeNone []
              else if joined then EdgeResult EdgeJoined flips else EdgeResult EdgeAlready []

-- ---------------------------------------------------------------------------
-- Candidates

-- | The accounting of one candidate.
data Report = Report
  { reportUpdates ∷ !Int
  -- ^ Structural updates: connections inspected.
  , reportJoins ∷ !Int
  -- ^ Classes joined by those updates (or by merging two runs).
  , reportRetired ∷ !Int
  -- ^ Obligations finished.
  , reportReads ∷ !Int
  -- ^ Distinct records read from the provider for the updates in the candidate.
  , reportAttemptedReads ∷ !Int
  -- ^ Every provider read made, including those of an inspection that was then
  -- rejected for capacity or a missing record. Never above the read limit.
  , reportWrites ∷ !Int
  -- ^ Records written or deleted.
  , reportDeltaBytes ∷ !Int
  -- ^ Accounted bytes of the delta, header included.
  , reportScratchBytes ∷ !Int
  -- ^ Accounted scratch bytes at the peak.
  , reportNewlyKnown ∷ [Node]
  -- ^ Roots of the classes that became known.
  , reportPendingAfter ∷ !Word64
  -- ^ Unfinished obligations once applied.
  }
  deriving stock (Eq, Show)

-- | A complete bounded delta: the writes, the next header and what changed. The
-- constructor is private; the only candidates are those the model stages. A
-- candidate is bound to the exact authority it read, so it applies to that
-- value only.
data Candidate = Candidate
  { cBase ∷ !Authority
  , cNext ∷ !Header
  , cWrites ∷ [(RecordKey, Maybe Record)]
  , cTerrain ∷ !Bool
  , cKnowledge ∷ !Bool
  , cReport ∷ !Report
  }
  deriving stock (Eq, Show)

-- | The authority the candidate was prepared against.
candidateBase ∷ Candidate → Authority
candidateBase = cBase

-- | The header once applied.
candidateNext ∷ Candidate → Header
candidateNext = cNext

-- | The record writes in key order; 'Nothing' deletes.
candidateWrites ∷ Candidate → [(RecordKey, Maybe Record)]
candidateWrites = cWrites

-- | Whether the candidate changes terrain (the content revision advances).
candidateTerrain ∷ Candidate → Bool
candidateTerrain = cTerrain

-- | Whether the candidate changes knowledge (the knowledge revision advances).
candidateKnowledge ∷ Candidate → Bool
candidateKnowledge = cKnowledge

-- | Whether the candidate changes neither terrain nor knowledge: frontier or
-- union maintenance that advances only the store revision.
candidateFrontierOnly ∷ Candidate → Bool
candidateFrontierOnly c = not (cTerrain c) && not (cKnowledge c)

-- | The candidate's accounting.
candidateReport ∷ Candidate → Report
candidateReport = cReport

bump ∷ Revision → Either Refusal Revision
bump (Revision n)
  | n == maxBound = Left AuthorityOverflow
  | otherwise = Right (Revision (n + 1))

-- | The writes of a staged overlay, dropping any that restore what was read, and
-- the change in retained bytes.
settleWrites ∷ S → ([(RecordKey, Maybe Record)], Int)
settleWrites s = (writes, added - removed)
  where
    writes = [(k, v) | (k, v) ← Map.toAscList (sOverlay s), Map.findWithDefault Nothing k (sCache s) /= v]
    old k = Map.findWithDefault Nothing k (sCache s)
    added = sum [entryBytes k r | (k, Just r) ← writes]
    removed = sum [entryBytes k r | (k, _) ← writes, Just r ← [old k]]

-- | The accounted bytes of a deletion: charged as the largest record of its
-- kind, so a candidate's size never shrinks as more updates are staged (a
-- finished obligation costs what its last progress record did).
tombstoneBytes ∷ RecordKey → Int
tombstoneBytes k = keyBytes k + entryOverheadBytes + case k of
  KeyTodo _ → 40
  _ → 8

-- | The resources an operation may use: the smaller of each validated limit and
-- the caller's allowance.
capsOf ∷ DiscoveryLimits → Allowance → Header → Caps
capsOf limits allow hdr =
  Caps
    { capReads = min (limitInspectedRecords limits) (allowReads allow)
    , capWrites = min (limitDeltaRecords limits) (allowWrites allow)
    , capDelta = min (limitDeltaBytes limits) (allowDeltaBytes allow)
    , capScratch = min (limitScratchBytes limits) (allowScratchBytes allow)
    , capRetained = limitRetainedBytes limits
    , capBase = headerBytes + hBytes hdr
    }

-- | The figure a resource needs for one minimal step (an edit or one update) and
-- the figure available, for a typed refusal.
capacityFigures ∷ Bool → DiscoveryLimits → Caps → Capacity → (Int, Int)
capacityFigures forEdit limits caps cap = case cap of
  CapacityReads → (if forEdit then worstEditReads else worstEdgeReads, capReads caps)
  CapacityWrites → (if forEdit then worstEditWrites else worstEdgeWrites, capWrites caps)
  CapacityDeltaBytes → (if forEdit then minimumDeltaBytes else headerBytes + worstEdgeBytes, capDelta caps)
  CapacityScratchBytes → (if forEdit then worstEditScratch else worstEdgeScratch, capScratch caps)
  CapacityRetainedBytes → (minimumRetainedBytes, capRetained caps)
  CapacityObligations → (1, limitPendingObligations limits)

-- ---------------------------------------------------------------------------
-- Staging a removal

-- | The result of staging a removal.
data StageOutcome
  = -- | The cell is air or already removed: nothing to record, no revision.
    NoChange
  | -- | The complete paired delta: the canonical removal and the continuation
    -- that inspects every connection it introduces. Neither half applies alone.
    Staged !Candidate
  | -- | A required record has not been supplied. Nothing was staged and the
    -- previous value stands.
    EditSuspended !RecordKey
  deriving stock (Eq, Show)

-- | Stage the removal of one whole cell, ramp included, together with its
-- connection obligation. Removing air or a cell already removed is
-- 'NoChange'. Merging with the runs above and below keeps every earlier alias
-- valid: a run that loses its key is joined to the run that takes its place, in
-- the same candidate. Every read and every staged write is checked against the
-- limits and the allowance before it is made.
stageRemoval ∷ Env → Header → Provider → Allowance → TileCoord → Either Refusal StageOutcome
stageRemoval env hdr prov allow tile@(TileCoord ax ay az) =
  case runM editM env prov (emptyS caps) of
    Left (Failure (StopCapacity cap) _) → Left (uncurry (CapacityBlocked cap) (editFigures cap))
    Left (Failure (StopMissing k) _) → Right (EditSuspended k)
    Left (Failure (StopCorrupt i) _) → Left (Corrupt i)
    Left (Failure StopOverflow _) → Left AuthorityOverflow
    Right (Nothing, _) → Right NoChange
    Right (Just (flips, joins), s) → finish s flips joins
  where
    limits = envLimitsField env
    caps = capsOf limits allow hdr
    -- The frontier needs one more obligation than it holds.
    editFigures CapacityObligations = (fromIntegral (pendingObligations hdr) + 1, limitPendingObligations limits)
    editFigures cap = capacityFigures True limits caps cap
    col = Column ax ay
    z = axisValue az
    tailSeq = hTail hdr
    editM ∷ M (Maybe ([Node], Int))
    editM = do
      here ← floorRun col z
      case here of
        Just (_, hi) | hi > z → pure Nothing
        _ → case cellAt (envSource env) emptyChanges tile of
          Air → pure Nothing
          Solid {} → do
            -- A real change: the frontier must have room and the sequence must
            -- not wrap, before anything is read or staged for it.
            if pendingObligations hdr >= fromIntegral (limitPendingObligations limits)
              then stopWith (StopCapacity CapacityObligations)
              else pure ()
            if tailSeq == maxBound then stopWith StopOverflow else pure ()
            above ← if z + 1 < topExclusive then floorRun col (z + 1) else pure Nothing
            let below = case here of
                  Just (lo, hi) | hi == z → Just lo
                  _ → Nothing
                up = case above of
                  Just (lo, hi) | lo == z + 1 → Just hi
                  _ → Nothing
            (runKey, merged) ← case (below, up) of
              (Nothing, Nothing) → do
                putRec (KeyRun col z) (RecRun (z + 1))
                pure (z, ([], 0))
              (Just lo, Nothing) → do
                putRec (KeyRun col lo) (RecRun (z + 1))
                -- The cell joins an existing run. When that run's class is
                -- known the cell is new known space, a knowledge change even
                -- though no class flips.
                (root, ro) ← findRoot (RunNode col lo)
                pure (lo, ([root | rootKnown ro], 0))
              (Nothing, Just hi) → do
                delRec (KeyRun col (z + 1))
                putRec (KeyRun col z) (RecRun hi)
                joined ← unionNodes (RunNode col z) (RunNode col (z + 1))
                pure (z, joinFlips joined)
              (Just lo, Just hi) → do
                putRec (KeyRun col lo) (RecRun hi)
                delRec (KeyRun col (z + 1))
                joined ← unionNodes (RunNode col lo) (RunNode col (z + 1))
                pure (lo, joinFlips joined)
            -- The new full-air cell contains the cell's old void, so the two
            -- are one space from the start: a cell that was known stays known.
            (voidFlips, voidJoins) ← case lookupVoid (envConn env) tile 0 of
              InComponent key → joinFlips <$> unionNodes (RunNode col runKey) (SrcNode key)
              _ → pure ([], 0)
            putRec (KeyTodo tailSeq) (RecTodo (Todo tile 1))
            pure (Just (fst merged <> voidFlips, snd merged + voidJoins))
    joinFlips AlreadyJoined = ([], 0)
    joinFlips (Joined ns) = (ns, 1)
    finish s flips joins = do
      content ← bump (authContent (hAuthority hdr))
      store ← bump (authStore (hAuthority hdr))
      knowledge ← if null flips then Right (authKnowledge (hAuthority hdr)) else bump (authKnowledge (hAuthority hdr))
      let (writes, grown) = settleWrites s
          next =
            hdr
              { hAuthority = (hAuthority hdr) {authContent = content, authKnowledge = knowledge, authStore = store}
              , hTail = tailSeq + 1
              , hBytes = hBytes hdr + grown
              }
          report =
            Report
              { reportUpdates = 1
              , reportJoins = joins
              , reportRetired = 0
              , reportReads = sReads s
              , reportAttemptedReads = sReads s
              , reportWrites = Map.size (sOverlay s)
              , reportDeltaBytes = payloadNow s
              , reportScratchBytes = scratchNow s
              , reportNewlyKnown = flips
              , reportPendingAfter = pendingObligations next
              }
      pure (Staged (Candidate (hAuthority hdr) next writes True (not (null flips)) report))

-- ---------------------------------------------------------------------------
-- Discovery batches

-- | Why a batch stopped.
data Halt
  = -- | It performed the batch limit of structural updates; more may remain.
    HaltBatchFull
  | -- | No unfinished obligation remains.
    HaltDrained
  | -- | The next inspection needs a record the provider has not supplied.
    HaltSuspended !RecordKey
  | -- | The next inspection would overflow the resource; the work stays pending.
    HaltCapacity !Capacity
  deriving stock (Eq, Show)

-- | The result of a discovery batch.
data Step
  = -- | There is no unfinished obligation.
    Idle
  | -- | At least one structural update, with why the batch stopped.
    Progress !Candidate !Halt
  | -- | Not even one update could be made: the first inspection needs a record
    -- the provider has not supplied. The obligation is intact.
    Stalled !RecordKey
  deriving stock (Eq, Show)

data Acc = Acc
  { accS ∷ !S
  , accHeader ∷ !Header
  , accUpdates ∷ !Int
  , accJoins ∷ !Int
  , accRetired ∷ !Int
  , accKnown ∷ [Node]
  , accAttempted ∷ !Int
  -- ^ Provider reads made, including those of an inspection that was then
  -- rejected.
  }

-- | Run one discovery batch: at most the validated batch limit of structural
-- updates, each the inspection of one connection of the oldest unfinished
-- obligation. Every read and staged write is checked before it is made, so the
-- batch stops early, with the work intact, when the allowance is tighter or a
-- record is missing; a batch that cannot make even one update because of
-- capacity is refused with the resource. Every connection is inspected exactly
-- once; the obligation record carries the progress.
stepDiscovery ∷ Env → Header → Provider → Allowance → Either Refusal Step
stepDiscovery env hdr0 prov allow
  | pendingObligations hdr0 == 0 = Right Idle
  | otherwise = loop (Acc (emptyS caps) hdr0 0 0 0 [] 0)
  where
    limits = envLimitsField env
    caps = capsOf limits allow hdr0
    batch = limitBatchUpdates limits
    loop acc
      | accUpdates acc >= batch = conclude acc HaltBatchFull
      | pendingObligations (accHeader acc) == 0 = conclude acc HaltDrained
      | otherwise = case runM (inspectHead (accHeader acc)) env prov (accS acc) of
          Left (Failure (StopMissing k) n) → conclude (attempt n acc) (HaltSuspended k)
          Left (Failure (StopCapacity cap) n) → conclude (attempt n acc) (HaltCapacity cap)
          Left (Failure (StopCorrupt i) _) → Left (Corrupt i)
          Left (Failure StopOverflow _) → Left AuthorityOverflow
          Right ((nextHeader, retired, result), s') →
            loop
              acc
                { accS = s'
                , accHeader = nextHeader
                , accUpdates = accUpdates acc + 1
                , accJoins = accJoins acc + (case edgeEffect result of EdgeJoined → 1; _ → 0)
                , accRetired = accRetired acc + (if retired then 1 else 0)
                , accKnown = accKnown acc <> edgeNewlyKnown result
                , accAttempted = sReads s'
                }
    attempt n acc = acc {accAttempted = max n (accAttempted acc)}
    conclude acc halt
      | accUpdates acc == 0 = case halt of
          HaltSuspended k → Right (Stalled k)
          HaltCapacity cap → Left (uncurry (CapacityBlocked cap) (capacityFigures False limits caps cap))
          _ → Right Idle
      | otherwise = build acc halt
    build acc halt = do
      let s = accS acc
          (writes, grown) = settleWrites s
          knowledgeChanged = not (null (accKnown acc))
          base = hAuthority hdr0
      store ← bump (authStore base)
      knowledge ← if knowledgeChanged then bump (authKnowledge base) else Right (authKnowledge base)
      let next =
            (accHeader acc)
              { hAuthority = base {authKnowledge = knowledge, authStore = store}
              , hBytes = hBytes hdr0 + grown
              }
          report =
            Report
              { reportUpdates = accUpdates acc
              , reportJoins = accJoins acc
              , reportRetired = accRetired acc
              , reportReads = sReads s
              , reportAttemptedReads = max (sReads s) (accAttempted acc)
              , reportWrites = Map.size (sOverlay s)
              , reportDeltaBytes = payloadNow s
              , reportScratchBytes = scratchNow s
              , reportNewlyKnown = accKnown acc
              , reportPendingAfter = pendingObligations next
              }
      Right (Progress (Candidate base next writes False knowledgeChanged report) halt)

-- | Inspect the next connection of the oldest obligation and advance or retire
-- it. Returns the header once that update is staged.
inspectHead ∷ Header → M (Header, Bool, EdgeResult)
inspectHead hdr = do
  let seqNo = hHead hdr
  r ← getRec (KeyTodo seqNo)
  case r of
    Just (RecTodo (Todo tile done)) | done >= 1 && done < edgeCount → do
      result ← inspectEdge tile (fromIntegral done)
      if done + 1 == edgeCount
        then do
          delRec (KeyTodo seqNo)
          pure (hdr {hHead = seqNo + 1}, True, result)
        else do
          putRec (KeyTodo seqNo) (RecTodo (Todo tile (done + 1)))
          pure (hdr, False, result)
    Nothing → corrupt (MissingObligation seqNo)
    Just _ → corrupt (MalformedRecord (KeyTodo seqNo))

-- ---------------------------------------------------------------------------
-- Retained state

-- | The header and every retained record, as a complete logical value. It is the
-- full-history reference the tests replay; a later store replaces the map with
-- pages and serves the same 'Provider'. The constructor is private.
data Retained = Retained
  { rHeader ∷ !Header
  , rRecords ∷ !(Map RecordKey Record)
  }
  deriving stock (Eq, Show)

-- | A fresh arena incarnation: no removal, no union, no obligation, revisions
-- zero.
newRetained ∷ ArenaId → Retained
newRetained arena =
  Retained (Header (Authority arena (Revision 0) (Revision 0) (Revision 0)) 0 0 0) Map.empty

-- | The control header.
retainedHeader ∷ Retained → Header
retainedHeader = rHeader

-- | Every retained record in key order.
retainedRecords ∷ Retained → [(RecordKey, Record)]
retainedRecords = Map.toAscList . rRecords

-- | The provider that serves every retained record.
retainedProvider ∷ Retained → Provider
retainedProvider = recordProvider . rRecords

-- | The accounted bytes of the header and the records.
retainedBytes ∷ Retained → Int
retainedBytes r = headerBytes + hBytes (rHeader r)

-- | A provider over a map of records: exact lookups and a floor lookup over
-- the runs of a column.
recordProvider ∷ Map RecordKey Record → Provider
recordProvider m =
  Provider
    { fetchRecord = \k → maybe Absent Found (Map.lookup k m)
    , fetchFloorRun = \col z → case Map.lookupLE (KeyRun col z) m of
        Just (KeyRun c lo, RecRun hi) | c == col → Found (lo, hi)
        _ → Absent
    }

-- | The retained removed runs as validated intervals, for the existing
-- removal-based consumers ('Hetoimasia.Terrain.Changes.changesFromIntervals').
retainedRemovals ∷ Retained → [(Column, ZRange)]
retainedRemovals r =
  [ (col, range)
  | (KeyRun col lo, RecRun hi) ← Map.toAscList (rRecords r)
  , Right range ← [mkZRange (toInteger lo) (toInteger hi)]
  ]

-- | Why a candidate was not applied. The retained value is unchanged.
data ApplyError
  = -- | The candidate was prepared for another arena incarnation.
    WrongArena !ArenaId !ArenaId
  | -- | The candidate was prepared against a different authority than the
    -- retained value now has: it is stale.
    StaleBase !Authority !Authority
  deriving stock (Eq, Show)

-- | Apply a candidate if and only if it was prepared against exactly the
-- retained value's incarnation and revisions. A rejected candidate leaks
-- nothing. Applying one candidate stales every other candidate prepared from the
-- same base, including a frontier-only one.
applyCandidate ∷ Candidate → Retained → Either ApplyError Retained
applyCandidate c (Retained h records)
  | authArena (cBase c) /= authArena (hAuthority h) = Left (WrongArena (authArena (cBase c)) (authArena (hAuthority h)))
  | cBase c /= hAuthority h = Left (StaleBase (cBase c) (hAuthority h))
  | otherwise = Right (Retained (cNext c) (foldl' write records (cWrites c)))
  where
    write m (k, Just v) = Map.insert k v m
    write m (k, Nothing) = Map.delete k m

-- | Rebuild a retained value from a header and records, checking that they are
-- a legitimate state: kinds match their keys, runs are disjoint and not
-- adjacent, forest chains are short and end at a stored root, obligations are
-- exactly the sequences the header names and the byte total matches.
retainedFromRecords ∷ Header → [(RecordKey, Record)] → Either Integrity Retained
retainedFromRecords h entries = do
  let m = Map.fromList entries
  mapM_ kindOk (Map.toList m)
  runsOk m
  mapM_ (chainOk m) [k | (KeyLink k, RecChild _) ← Map.toList m]
  todosOk m
  if hBytes h /= sum [entryBytes k r | (k, r) ← Map.toList m] then Left BadAccounting else pure ()
  pure (Retained h m)
  where
    kindOk (k, r) = case (k, r) of
      (KeyRun _ lo, RecRun hi) | lo >= bottomLevel && lo < hi && hi <= topExclusive → Right ()
      (KeyLink _, RecRoot (Root size _)) | size >= 1 → Right ()
      (KeyLink node, RecChild parent) | parent /= node → Right ()
      (KeyTodo _, RecTodo (Todo _ done)) | done >= 1 && done < edgeCount → Right ()
      _ → Left (MalformedRecord k)
    runsOk m =
      let runs = [(col, lo, hi) | (KeyRun col lo, RecRun hi) ← Map.toAscList m]
          bad = [KeyRun c2 l2 | ((c1, _, h1), (c2, l2, _)) ← zip runs (drop 1 runs), c1 == c2, l2 <= h1]
       in case bad of
            (k : _) → Left (MalformedRecord k)
            [] → Right ()
    chainOk m node = go node (0 ∷ Int)
      where
        go cur depth
          | depth > maxLinkChain = Left (ChainTooLong node)
          | otherwise = case Map.lookup (KeyLink cur) m of
              Just (RecRoot _) → Right ()
              Just (RecChild parent) → go parent (depth + 1)
              _ → Left (MalformedRecord (KeyLink cur))
    todosOk m =
      let present = [s | (KeyTodo s, _) ← Map.toAscList m]
          expected = if hTail h == hHead h then [] else [hHead h .. hTail h - 1]
       in if hTail h < hHead h || present /= expected
            then Left (MissingObligation (hHead h))
            else Right ()

-- ---------------------------------------------------------------------------
-- Queries

runQuery ∷ Env → Provider → M a → Observed a
runQuery env prov m = case runM m env prov (emptyS caps) of
  Right (a, s) → Observed (Right a) (sReads s)
  Left (Failure (StopMissing k) n) → Observed (Left (MissingRecord k)) n
  Left (Failure (StopCorrupt i) n) → Observed (Left (Inconsistent i)) n
  Left (Failure (StopCapacity _) n) → Observed (Left (ReadLimit (capReads caps))) n
  Left (Failure StopOverflow n) → Observed (Left (Inconsistent BadAccounting)) n
  where
    limits = envLimitsField env
    caps =
      Caps
        { capReads = limitInspectedRecords limits
        , capWrites = 0
        , capDelta = 0
        , capScratch = limitScratchBytes limits
        , capRetained = limitRetainedBytes limits
        , capBase = 0
        }

-- | Whether a node's class is known.
nodeKnown ∷ Node → M Bool
nodeKnown node = rootKnown . snd <$> findRoot node

-- | The root of a node's class, for comparing classes.
queryNodeClass ∷ Env → Provider → Node → Observed Node
queryNodeClass env prov node = runQuery env prov (fst <$> findRoot node)

-- | Whether a tile is currently removed.
queryRemoved ∷ Env → Provider → TileCoord → Observed Bool
queryRemoved env prov tile = runQuery env prov $ do
  now ← cellNow tile
  pure $ case now of NowRemoved _ → True; _ → False

-- | Whether a source component's class is known. A component of the compiled
-- source is known exactly when its class holds an exterior component or has
-- been joined to known space.
queryComponentKnown ∷ Env → Provider → ComponentKey → Observed Bool
queryComponentKnown env prov key = runQuery env prov (nodeKnown (SrcNode key))

-- | The compressed exposed boundary of a source component, when the component
-- is known: the faces of its class's boxes, each a rectangle of cells with what
-- lies across, never an enumeration of exposed tiles. It describes the
-- immutable source; a removal's effect on it is read cell by cell with
-- 'queryCell'.
queryKnownBoundary ∷ Env → Provider → ComponentKey → Observed (Maybe [BoundaryFace])
queryKnownBoundary env prov key = runQuery env prov $ do
  known ← nodeKnown (SrcNode key)
  pure (if known then componentBoundary (envConn env) key else Nothing)

-- | What is known of the empty space of a tile.
data VoidKnowledge
  = -- | The tile has no empty space (a full block).
    NoVoidHere
  | VoidKnown
  | VoidUnknown
  deriving stock (Eq, Show)

-- | What is known of the solid of a tile.
data SolidKnowledge
  = -- | The tile holds no solid (air or removed).
    NoSolid
  | SolidKnown
  | SolidUnknown
  deriving stock (Eq, Show)

-- | The two separate facts about a tile. Known solid and known void never imply
-- each other across components: a ramp seen from the side is a known solid over
-- an unknown void.
data CellKnowledge = CellKnowledge
  { cellSolid ∷ !SolidKnowledge
  , cellVoid ∷ !VoidKnowledge
  }
  deriving stock (Eq, Show)

-- | How a tile is presented, as a function of what is known.
data Presentation
  = -- | Neither the solid nor the void is known (generic fog).
    FullyUnknown
  | -- | The solid is known and the void is not (a visible ramp over an unknown
    -- void).
    KnownSolidUnknownVoid
  | -- | Everything the tile holds is known.
    Ordinary
  deriving stock (Eq, Show)

-- | The presentation of a tile's knowledge.
presentation ∷ CellKnowledge → Presentation
presentation (CellKnowledge solid void) = case (solid, void) of
  (SolidKnown, VoidUnknown) → KnownSolidUnknownVoid
  (SolidUnknown, VoidUnknown) → FullyUnknown
  (SolidUnknown, NoVoidHere) → FullyUnknown
  (NoSolid, VoidUnknown) → FullyUnknown
  _ → Ordinary

-- | What is known of a tile, from the source, the retained removals and the
-- retained knowledge alone. Residency, materialization and camera motion are
-- not inputs. A required record the provider has not supplied is
-- 'MissingRecord', never unknown.
queryCell ∷ Env → Provider → TileCoord → Observed CellKnowledge
queryCell env prov tile = runQuery env prov $ do
  now ← cellNow tile
  voidKnown ← knownVoid env tile now
  case now of
    NowRemoved _ → pure (CellKnowledge NoSolid voidKnown)
    NowSource Air → pure (CellKnowledge NoSolid voidKnown)
    NowSource (Solid {}) → do
      solid ← solidKnown env tile now (voidKnown == VoidKnown)
      pure (CellKnowledge (if solid then SolidKnown else SolidUnknown) voidKnown)

knownVoid ∷ Env → TileCoord → CellNow → M VoidKnowledge
knownVoid env tile now = case nodeOf env tile now 0 of
  Nothing → pure NoVoidHere
  Just node → (\k → if k then VoidKnown else VoidUnknown) <$> nodeKnown node

-- | Whether a solid tile is exposed, over positive area, to known empty space:
-- its own void when that is known (the surface of a ramp faces it), a known
-- neighbour whose portal lies over the tile's solid face section, or the sky
-- above the top level.
solidKnown ∷ Env → TileCoord → CellNow → Bool → M Bool
solidKnown env tile now ownKnown
  | ownKnown = pure True
  | otherwise = anyM exposedOn cellFaces
  where
    ours = openingsOf now
    exposedOn face = case neighbourTile face tile of
      Left _
        | face == TopFace → pure (sum [openingArea (portalOpening p) | p ← portalsOn TopFace ours] < 1)
        | otherwise → pure False
      Right nb → do
        other ← cellNow nb
        let theirs = openingsOf other
            connections = connectCells tile ours nb theirs
        anyM
          ( \comp → do
              let index = componentIndex comp
                  total = sum [openingArea (portalOpening p) | p ← componentPortals comp, portalFace p == oppositeFace face]
                  joined = sum [connectionArea c | c ← connections, componentRefIndex (connectionTo c) == index]
              if total - joined > 0
                then case nodeOf env nb other index of
                  Just node → nodeKnown node
                  Nothing → pure False
                else pure False
          )
          (cellComponents theirs)

anyM ∷ (a → M Bool) → [a] → M Bool
anyM _ [] = pure False
anyM f (x : xs) = do
  r ← f x
  if r then pure True else anyM f xs

-- | The state of one removal's obligation, separate from whether any class it
-- touches is known.
data ObligationState
  = -- | Allocated, with no connection inspected yet.
    Unseen
  | -- | Partly inspected; the remaining connections stay queued.
    Pending
  | -- | Every connection inspected and the record retired.
    Expanded
  deriving stock (Eq, Show)

-- | The state of the obligation with a sequence number, or 'Nothing' for one
-- not yet allocated. A sequence below the header's oldest unfinished one is
-- expanded; one inside the window is read from its record.
queryObligation ∷ Env → Header → Provider → Word64 → Observed (Maybe ObligationState)
queryObligation env hdr prov seqNo
  | seqNo < hHead hdr = Observed (Right (Just Expanded)) 0
  | seqNo >= hTail hdr = Observed (Right Nothing) 0
  | otherwise = runQuery env prov $ do
      r ← getRec (KeyTodo seqNo)
      case r of
        Just (RecTodo (Todo _ done))
          | done == 1 → pure (Just Unseen)
          | otherwise → pure (Just Pending)
        Nothing → corrupt (MissingObligation seqNo)
        Just _ → corrupt (MalformedRecord (KeyTodo seqNo))
