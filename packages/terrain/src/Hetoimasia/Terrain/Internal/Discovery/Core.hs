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
-- run of air levels is one node. A narrowing limits a cell to a corner mask of
-- its own material: the cell's void is a node of its own, named by its level, so
-- equal adjacent masks share a storage run and keep separate voids. The six faces
-- of the edited cell plus its old void are the connections the edit introduces.
-- Those connections are an /obligation/ staged together with the edit. A discovery batch inspects them
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
  , envConnectivity

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
  , stageRemovalTraced
  , NarrowOutcome (..)
  , stageNarrowing
  , stageNarrowingTraced
  , Halt (..)
  , Step (..)
  , stepDiscovery
  , stepDiscoveryTraced
  , ReadSet (..)

    -- * Retained state
  , Retained
  , newRetained
  , retainedHeader
  , retainedRecords
  , retainedProvider
  , retainedBytes
  , retainedRemovals
  , retainedReplacements
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
  , BoundaryPage (..)
  , queryKnownBoundary
  , queryNodeClass
  , ObligationState (..)
  , queryObligation
  ) where

import Control.Monad (ap)
import Data.Int (Int64)
import Data.IntMap.Strict (IntMap)
import Data.IntSet (IntSet)
import Data.List (nub)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe (isJust)
import Data.Word (Word64)
import Control.Monad (forM_, unless)
import Data.List (sortOn)
import Hetoimasia.Terrain.Cell (Cell (..), Column (..), ZRange, cellOccupant, cellShapeKey, cornerCell, mkZRange)
import Hetoimasia.Terrain.Changes (Replacement (..), narrowedCell)
import Hetoimasia.Terrain.Internal.Cell (bottomLevel, topExclusive)
import Hetoimasia.Terrain.Changes (emptyChanges)
import Hetoimasia.Terrain.Internal.Shape (CornerMask, cornerMaskValue, resolveCorner)
import Hetoimasia.Terrain.Coordinate (TileCoord (..), axisValue)
import Hetoimasia.Terrain.Internal.Connectivity.Index
  ( BoundaryFace
  , ComponentKey
  , Connectivity (..)
  , Stats (..)
  , VoidLookup (..)
  , componentBoundaryPage
  , memberIndex
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
  , connectionFrom
  , portalComponent
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
  , keyOpenings
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
  , envMembers ∷ !(IntMap IntSet)
  -- ^ The ordered members of every class, built once with the environment.
  }

-- | Pair a source with its compiled connectivity and validated limits.
mkEnv ∷ DiscoveryLimits → Source → Connectivity → Env
mkEnv limits source conn = Env source conn limits (memberIndex conn)

-- | The compiled connectivity the environment pairs with its source (for the package's own
-- region-level queries).
envConnectivity ∷ Env → Connectivity
envConnectivity = envConn

-- | The environment's limits.
envLimits ∷ Env → DiscoveryLimits
envLimits = envLimitsField

-- | The accounted bytes of the shared immutable source metadata the model reads:
-- the compiled connectivity and the ordered member index built from it (32 bytes
-- a node), charged once per arena by the owner and never to a candidate.
envSharedBytes ∷ Env → Integer
envSharedBytes env = statResultBytes (cStats (envConn env)) + 32 * statNodes (cStats (envConn env))

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
  | -- | An obligation whose cell holds no edit.
    ObligationNotEdited !TileCoord
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
  | -- | A query's output or traversal state would overflow this resource.
    QueryCapacity !Capacity
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

-- | A stop with what the attempt had cost when it happened: the records the
-- provider had been asked for and the peak accounted scratch. Both are read from
-- the one charging function ('charge'), so a rejected or suspended attempt shows
-- exactly what it had been charged.
data Failure = Failure !Stop !Int !Int !ReadSet

-- | What the provider ANSWERED an operation, from the records it was asked for: the records and the floor-run answers, exactly as
-- the provider gave them and never a value the operation staged (a staged write lives in the overlay, a different map). A caller
-- that keeps the provider's answers between runs of the same operation (the page-resident store, when it must drop the pages it
-- fetched) can answer a later run from them: the operation reads the same records in the same order and gets the same values.
data ReadSet = ReadSet
  { readRecords ∷ ![(RecordKey, Maybe Record)]
  , readFloors ∷ ![((Column, Int64), Maybe (Int64, Int64, Replacement))]
  }
  deriving stock (Eq, Show)

-- | The answers an operation's state has read from the provider.
readSetOf ∷ S → ReadSet
readSetOf s = ReadSet (Map.toAscList (sCache s)) (Map.toAscList (sFloor s))

noReads ∷ ReadSet
noReads = ReadSet [] []

-- | The resources one operation may use, each already the smaller of the
-- validated limit and the caller's allowance.
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
-- repeated read costs nothing), the floor answers and the accounted resources.
-- Every figure that is a resource changes through 'charge' alone.
data S = S
  { sOverlay ∷ !(Map RecordKey (Maybe Record))
  , sCache ∷ !(Map RecordKey (Maybe Record))
  , sFloor ∷ !(Map (Column, Int64) (Maybe (Int64, Int64, Replacement)))
  , sReads ∷ !Int
  , sCost ∷ !Int
  -- ^ The accounted cost of the staged writes.
  , sScratch ∷ !Int
  -- ^ The accounted scratch now: reads, staged writes and query output.
  , sPeak ∷ !Int
  -- ^ The peak of 'sScratch'. It only rises, and only inside 'charge'.
  , sCaps ∷ !Caps
  }

emptyS ∷ Caps → S
emptyS = S Map.empty Map.empty Map.empty 0 0 0 0

-- | The accounted candidate payload so far: the header and the staged entries.
payloadNow ∷ S → Int
payloadNow s = headerBytes + sCost s

-- | The first resource the staged state overflows, if any.
overCap ∷ S → Maybe Capacity
overCap s
  | sReads s > capReads caps = Just CapacityReads
  | Map.size (sOverlay s) > capWrites caps = Just CapacityWrites
  | payloadNow s > capDelta caps = Just CapacityDeltaBytes
  | sScratch s > capScratch caps = Just CapacityScratchBytes
  | capBase caps + snd (settleWrites s) > capRetained caps = Just CapacityRetainedBytes
  | otherwise = Nothing
  where
    caps = sCaps s

overlayCost ∷ RecordKey → Maybe Record → Int
overlayCost k = maybe (tombstoneBytes k) (entryBytes k)

-- | Everything an operation can spend. This is the one place a resource is
-- charged: a provider read, a staged write or the output and traversal state of
-- a query each become a 'Charge', are checked against every cap before they
-- happen, and raise the peak.
data Charge
  = -- | One provider read: one read and the largest record of scratch.
    ChargeRead
  | -- | A staged write or deletion of a key.
    ChargeWrite !RecordKey !(Maybe Record)
  | -- | Bytes of query output or traversal state.
    ChargeOutput !Int

-- | Apply a charge, or name the resource it would overflow. The state is
-- returned unchanged on refusal, and the peak includes only charges made.
charge ∷ Charge → S → Either Capacity S
charge what s = case what of
  ChargeRead → settle s {sReads = sReads s + 1, sScratch = sScratch s + maxRecordBytes}
  ChargeOutput n → settle s {sScratch = sScratch s + n}
  ChargeWrite key value →
    let old = Map.lookup key (sOverlay s)
        before = maybe 0 (overlayCost key) old
        after = overlayCost key value
     in settle
          s
            { sOverlay = Map.insert key value (sOverlay s)
            , sCost = sCost s - before + after
            , sScratch = sScratch s - before + after
            }
  where
    settle s' = case overCap s' of
      Just cap → Left cap
      Nothing → Right s' {sPeak = max (sPeak s') (sScratch s')}

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
stopWith x = M (\_ _ s → Left (failure x s))

failure ∷ Stop → S → Failure
failure x s = Failure x (sReads s) (sPeak s) (readSetOf s)

corrupt ∷ Integrity → M a
corrupt = stopWith . StopCorrupt

-- | Charge, as a step of the monad.
spend ∷ Charge → M ()
spend what = M $ \_ _ s → case charge what s of
  Left cap → Left (failure (StopCapacity cap) s)
  Right s' → Right ((), s')

-- | Read a retained record: the staged writes first, then what was already
-- read, then the provider. A distinct read is charged before the provider is
-- asked.
getRec ∷ RecordKey → M (Maybe Record)
getRec key = M $ \_ p s → case Map.lookup key (sOverlay s) of
  Just r → Right (r, s)
  Nothing → case Map.lookup key (sCache s) of
    Just r → Right (r, s)
    Nothing → case charge ChargeRead s of
      Left cap → Left (failure (StopCapacity cap) s)
      Right s1 → case fetchRecord p key of
        Found r → Right (Just r, s1 {sCache = Map.insert key (Just r) (sCache s1)})
        Absent → Right (Nothing, s1 {sCache = Map.insert key Nothing (sCache s1)})
        Unavailable k → Left (failure (StopMissing k) s1)

-- | The run of a column with the greatest lower end at or below a level: its
-- two ends and what it does to its levels. Floor answers ignore staged writes:
-- no operation stages a run before it has read every run it depends on.
floorRun ∷ Column → Int64 → M (Maybe (Int64, Int64, Replacement))
floorRun col z = M $ \_ p s → case Map.lookup (col, z) (sFloor s) of
  Just r → Right (r, s)
  Nothing → case charge ChargeRead s of
    Left cap → Left (failure (StopCapacity cap) s)
    Right s1 → case fetchFloorRun p col z of
      Found run@(lo, hi, payload)
        | lo <= z && lo < hi →
            Right
              ( Just run
              , s1
                  { sFloor = Map.insert (col, z) (Just run) (sFloor s1)
                  , sCache = Map.insert (KeyRun col lo) (Just (runRecord hi payload)) (sCache s1)
                  }
              )
        | otherwise → Left (failure (StopCorrupt (BadFloor col z)) s1)
      Absent → Right (Nothing, s1 {sFloor = Map.insert (col, z) Nothing (sFloor s1)})
      Unavailable k → Left (failure (StopMissing k) s1)

-- | Stage a write (or a deletion), refusing it before it is staged when the
-- result would overflow a resource.
stage ∷ RecordKey → Maybe Record → M ()
stage key value = spend (ChargeWrite key value)

putRec ∷ RecordKey → Record → M ()
putRec key r = stage key (Just r)

delRec ∷ RecordKey → M ()
delRec key = stage key Nothing

-- ---------------------------------------------------------------------------
-- The forest

-- | The implicit root of a node with no record: a source component is known
-- exactly when the compiled source calls it exterior; an air run and a narrowed
-- cell's void are unknown (one reaching the top boundary is made known by its
-- own obligation).
implicitRoot ∷ Node → M Root
implicitRoot node = case node of
  SrcNode key → do
    env ← askEnv
    case isExterior (envConn env) key of
      Nothing → corrupt (UnknownComponent key)
      Just ext → pure (Root 1 ext)
  RunNode _ _ → pure (Root 1 False)
  CellNode _ _ → pure (Root 1 False)

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

-- | What a tile holds now: an air run (named by its lower level), a cell limited
-- to a corner mask of its source material (the cell as it now reads), or its
-- source cell. A mask over a level whose source cell is air reads as the source
-- cell, as it does in "Hetoimasia.Terrain.Changes".
data CellNow = NowRemoved !Int64 | NowNarrowed !Cell | NowSource !Cell

cellNow ∷ TileCoord → M CellNow
cellNow tile@(TileCoord x y z) = do
  env ← askEnv
  r ← floorRun (Column x y) (axisValue z)
  let source = cellAt (envSource env) emptyChanges tile
  pure $ case r of
    Just (lo, hi, payload) | axisValue z < hi → case payload of
      ReplaceAir → NowRemoved lo
      ReplaceMask mask → maybe (NowSource source) (\(material, _) → NowNarrowed (cornerCell material mask)) (cellOccupant source)
    _ → NowSource source

-- | The openings of a cell as the geometry sees it.
cellOpenings ∷ Cell → CellOpenings
cellOpenings = maybe airOpenings keyOpenings . cellShapeKey

openingsOf ∷ CellNow → CellOpenings
openingsOf (NowRemoved _) = airOpenings
openingsOf (NowNarrowed cell) = cellOpenings cell
openingsOf (NowSource cell) = cellOpenings cell

-- | Whether a tile holds solid now.
occupiedNow ∷ CellNow → Bool
occupiedNow (NowRemoved _) = False
occupiedNow (NowNarrowed _) = True
occupiedNow (NowSource cell) = isJust (cellShapeKey cell)

-- | The node of one void of a tile's current content. A narrowed cell has at
-- most one void, so it has the one node named by its own level.
nodeOf ∷ Env → TileCoord → CellNow → Int → Maybe Node
nodeOf _ (TileCoord x y _) (NowRemoved lo) _ = Just (RunNode (Column x y) lo)
nodeOf _ (TileCoord x y z) now@(NowNarrowed _) index
  | index == 0 && not (null (cellComponents (openingsOf now))) = Just (CellNode (Column x y) (axisValue z))
  | otherwise = Nothing
nodeOf env tile (NowSource _) index = case lookupVoid (envConn env) tile index of
  InComponent key → Just (SrcNode key)
  _ → Nothing

-- ---------------------------------------------------------------------------
-- The connections of an edit

-- | What inspecting one connection did.
data EdgeEffect = EdgeNone | EdgeAlready | EdgeJoined | EdgeMarked

data EdgeResult = EdgeResult
  { edgeEffect ∷ !EdgeEffect
  , edgeNewlyKnown ∷ [Node]
  }

-- | Inspect connection @slot@ (1 to 6, in 'cellFaces' order) of an edit. A face
-- joins the edited cell's void to every component of the neighbour whose portal
-- overlaps one of the cell's own portals over positive area, both read from what
-- the two cells hold now, or marks the class known when the face is the upper
-- boundary of the world and the cell is open there. An edge or point contact, the
-- X and Y limits and the lower boundary open nothing. Slot 0, the cell's own old
-- void, is joined when the edit is staged.
inspectEdge ∷ TileCoord → Int → M EdgeResult
inspectEdge tile slot = do
  env ← askEnv
  me ← cellNow tile
  case me of
    NowSource _ → corrupt (ObligationNotEdited tile)
    _ → pure ()
  let ours = openingsOf me
      face = cellFaces !! (slot - 1)
  case neighbourTile face tile of
    Left _
      | face == TopFace → case [portalComponent p | p ← portalsOn TopFace ours, openingArea (portalOpening p) > 0] of
          index : _ → case nodeOf env tile me index of
            Nothing → corrupt (ConnectionWithoutComponent tile)
            Just node → do
              newly ← markKnown node
              pure (EdgeResult (if null newly then EdgeAlready else EdgeMarked) newly)
          [] → pure (EdgeResult EdgeNone [])
      | otherwise → pure (EdgeResult EdgeNone [])
    Right nb → do
      now ← cellNow nb
      let connections = connectCells tile ours nb (openingsOf now)
          pairs = nub [(componentRefIndex (connectionFrom c), componentRefIndex (connectionTo c)) | c ← connections]
          nodes = [(a, b) | (i, j) ← pairs, Just a ← [nodeOf env tile me i], Just b ← [nodeOf env nb now j]]
      if length nodes /= length pairs
        then corrupt (ConnectionWithoutComponent nb)
        else do
          results ← mapM (uncurry unionNodes) nodes
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
  -- ^ Accounted scratch bytes at the peak, the request that was then rejected
  -- or suspended included.
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

-- | THE revision rule, stated once; every candidate takes its next authority
-- from 'nextAuthority' and nowhere else.
--
-- * __Content__ advances exactly when the candidate changes terrain: a removal
--   that changed a cell. A discovery batch never changes it.
-- * __Knowledge__ advances exactly when the candidate makes known space that was
--   not known: a class becomes known, or a cell joins a class that is known
--   (an extended or bridged run, a known old void). Retained knowledge never
--   decreases, so it advances in one direction only.
-- * __Store__ advances on every candidate: it counts frontier and maintenance
--   commits (obligation progress, unions that change no knowledge).
-- * __Invalidation.__ A reader that keyed a derived result by the knowledge
--   revision it read (a fog plan, a picked cell) is stale as soon as the retained
--   knowledge revision differs; one keyed by content is stale when terrain
--   changed. Neither can see a candidate that is not applied.
-- * __A stale holder__ of a candidate, or of an older header, is refused by
--   'applyCandidate' against the whole authority (arena and all three
--   revisions); a stale reader of knowledge gets the old, immutable value, which
--   remains correct for the authority it names and never mixes in newer state.
-- * Revision arithmetic is checked: an advance that would wrap is refused.
-- | Whether newly known space was reported.
gainsKnowledge ∷ [Node] → Bool
gainsKnowledge = not . null

nextAuthority ∷ Authority → Bool → [Node] → Either Refusal Authority
nextAuthority base terrain gained = do
  content ← if terrain then bump (authContent base) else Right (authContent base)
  knowledge ← if gainsKnowledge gained then bump (authKnowledge base) else Right (authKnowledge base)
  store ← bump (authStore base)
  pure base {authContent = content, authKnowledge = knowledge, authStore = store}

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

-- | The operation a capacity figure is for.
data Work = WorkRemoval | WorkNarrowing | WorkEdge

-- | The figure a resource needs for one minimal step (a removal, a narrowing or
-- one update) and the figure available, for a typed refusal. A removal's figures
-- are those of a history without narrowed cells; one that holds them needs at
-- most the narrowing's.
capacityFigures ∷ Work → DiscoveryLimits → Caps → Capacity → (Int, Int)
capacityFigures work limits caps cap = case cap of
  CapacityReads → (figure worstEditReads worstNarrowReads worstEdgeReads, capReads caps)
  CapacityWrites → (figure worstEditWrites worstNarrowWrites worstEdgeWrites, capWrites caps)
  CapacityDeltaBytes → (figure (worstEditBytes + headerBytes) minimumDeltaBytes (headerBytes + worstEdgeBytes), capDelta caps)
  CapacityScratchBytes → (figure worstEditScratch worstNarrowScratch worstEdgeScratch, capScratch caps)
  CapacityRetainedBytes → (minimumRetainedBytes, capRetained caps)
  CapacityObligations → (1, limitPendingObligations limits)
  where
    figure removal narrowing edge = case work of
      WorkRemoval → removal
      WorkNarrowing → narrowing
      WorkEdge → edge

-- ---------------------------------------------------------------------------
-- Staging an edit

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

-- | The result of staging a narrowing.
data NarrowOutcome
  = -- | The cell the model resolves from its own records and the target are not a
    -- narrowing: the cell is air, a side identity other than 0, a corner solid
    -- with mask 0, or the target equals its corners or sets one it does not have.
    -- Nothing was staged: no record, obligation or revision, and not a
    -- suspension.
    NarrowRefused
  | -- | The complete paired delta, as for a removal.
    NarrowStaged !Candidate
  | -- | A required record has not been supplied. Nothing was staged.
    NarrowSuspended !RecordKey
  deriving stock (Eq, Show)

-- | The shared result of staging an edit.
data EditOutcome = EditNothing | EditStaged !Candidate | EditWaits !RecordKey

-- | Stage the removal of one whole cell, ramp or narrowed cell included, together
-- with its connection obligation. Removing air or a cell already removed is
-- 'NoChange'. Merging with the air runs above and below keeps every earlier alias
-- valid: a run that loses its key is joined to the run that takes its place, in
-- the same candidate, and a narrowed cell's void is joined to the air that
-- replaces it. Every read and every staged write is checked against the limits
-- and the allowance before it is made.
stageRemoval ∷ Env → Header → Provider → Allowance → TileCoord → Either Refusal StageOutcome
stageRemoval env hdr prov allow tile = fst (stageRemovalTraced env hdr prov allow tile)

-- | 'stageRemoval' and the records the provider answered it, whatever the outcome (a suspension included: the records it
-- resolved before the one it waits for). The outcome is exactly 'stageRemoval''s.
stageRemovalTraced ∷ Env → Header → Provider → Allowance → TileCoord → (Either Refusal StageOutcome, ReadSet)
stageRemovalTraced env hdr prov allow tile = case stageEdit WorkRemoval removal env hdr prov allow tile of
  (Left refusal, rs) → (Left refusal, rs)
  (Right outcome, rs) →
    ( Right $ case outcome of
        EditNothing → NoChange
        EditStaged c → Staged c
        EditWaits k → EditSuspended k
    , rs
    )
  where
    removal cell = ReplaceAir <$ cellShapeKey cell

-- | Stage the narrowing of one cell to a corner mask, together with its
-- connection obligation. Whether the pair is a narrowing is decided by
-- 'narrowedCell' on the cell the model resolves for the tile from the source and
-- its own records, never on a cell the caller supplies. A target of mask 0 makes
-- air, and then the retained runs, joins, obligation and knowledge are those of
-- the removal of the cell.
stageNarrowing ∷ Env → Header → Provider → Allowance → TileCoord → CornerMask → Either Refusal NarrowOutcome
stageNarrowing env hdr prov allow tile target = fst (stageNarrowingTraced env hdr prov allow tile target)

-- | 'stageNarrowing' and the records the provider answered it, whatever the outcome.
stageNarrowingTraced ∷ Env → Header → Provider → Allowance → TileCoord → CornerMask → (Either Refusal NarrowOutcome, ReadSet)
stageNarrowingTraced env hdr prov allow tile target = case stageEdit WorkNarrowing narrowing env hdr prov allow tile of
  (Left refusal, rs) → (Left refusal, rs)
  (Right outcome, rs) →
    ( Right $ case outcome of
        EditNothing → NarrowRefused
        EditStaged c → NarrowStaged c
        EditWaits k → NarrowSuspended k
    , rs
    )
  where
    narrowing cell = do
      _ ← narrowedCell cell target
      pure (maybe ReplaceAir (const (ReplaceMask target)) (resolveCorner target))

-- | The record of a run.
runRecord ∷ Int64 → Replacement → Record
runRecord hi ReplaceAir = RecRun hi
runRecord hi (ReplaceMask mask) = RecMaskRun hi mask

-- | The one edit worker. @decide@ is given the cell the tile holds now and
-- returns what the level becomes, or 'Nothing' when the edit changes nothing.
-- The level's run is rewritten from the runs it meets, so a split, a coalescing
-- and a join of the runs on either side are one computation; an air run that
-- loses its key is joined to the run that takes its place, the new cell's void is
-- joined to the void the cell held, and the frontier gains the obligation to
-- inspect the cell's faces.
stageEdit ∷ Work → (Cell → Maybe Replacement) → Env → Header → Provider → Allowance → TileCoord → (Either Refusal EditOutcome, ReadSet)
stageEdit work decide env hdr prov allow tile@(TileCoord ax ay az) =
  case runM editM env prov (emptyS caps) of
    Left (Failure (StopCapacity cap) _ _ rs) → (Left (uncurry (CapacityBlocked cap) (editFigures cap)), rs)
    Left (Failure (StopMissing k) _ _ rs) → (Right (EditWaits k), rs)
    Left (Failure (StopCorrupt i) _ _ rs) → (Left (Corrupt i), rs)
    Left (Failure StopOverflow _ _ rs) → (Left AuthorityOverflow, rs)
    Right (Nothing, s) → (Right EditNothing, readSetOf s)
    Right (Just (flips, joins), s) → (finish s flips joins, readSetOf s)
  where
    limits = envLimitsField env
    caps = capsOf limits allow hdr
    -- The frontier needs one more obligation than it holds.
    editFigures CapacityObligations = (fromIntegral (pendingObligations hdr) + 1, limitPendingObligations limits)
    editFigures cap = capacityFigures work limits caps cap
    col = Column ax ay
    z = axisValue az
    tailSeq = hTail hdr
    editM ∷ M (Maybe ([Node], Int))
    editM = do
      here ← floorRun col z
      let cover = case here of
            Just run@(_, hi, _) | hi > z → Just run
            _ → Nothing
          source = cellAt (envSource env) emptyChanges tile
          effective = case cover of
            Nothing → source
            Just (_, _, ReplaceAir) → Air
            Just (_, _, ReplaceMask mask) → maybe Air (\(material, _) → cornerCell material mask) (cellOccupant source)
      case decide effective of
        Nothing → pure Nothing
        Just payload → do
          -- A real change: the frontier must have room and the sequence must
          -- not wrap, before anything is read or staged for it.
          if pendingObligations hdr >= fromIntegral (limitPendingObligations limits)
            then stopWith (StopCapacity CapacityObligations)
            else pure ()
          if tailSeq == maxBound then stopWith StopOverflow else pure ()
          above ← if z + 1 < topExclusive then floorRun col (z + 1) else pure Nothing
          -- The run that ends at the level: the floor answer when the level is
          -- free, and one more lookup below a cell that starts its run.
          below ← case cover of
            Nothing → pure here
            Just (lo, _, _) | lo == z && z > bottomLevel → floorRun col (z - 1)
            _ → pure Nothing
          let belowRun = [run | Just run@(_, hi, _) ← [below], hi == z]
              aboveRun = [run | Just run@(lo, _, _) ← [above], lo == z + 1]
              olds = belowRun <> maybe [] pure cover <> aboveRun
              pieces =
                sortOn
                  (\(lo, _, _) → lo)
                  ( [(lo, min hi z, q) | (lo, hi, q) ← olds, lo < z]
                      <> [(z, z + 1, payload)]
                      <> [(z + 1, hi, q) | (_, hi, q) ← olds, hi > z + 1]
                  )
              news = coalescePieces pieces
              newLos = [lo | (lo, _, _) ← news]
              runKey = case [lo | (lo, hi, _) ← news, lo <= z, z < hi] of lo : _ → lo; [] → z
          forM_ olds $ \(lo, _, _) → unless (lo `elem` newLos) (delRec (KeyRun col lo))
          forM_ news $ \run@(lo, hi, q) → unless (run `elem` olds) (putRec (KeyRun col lo) (runRecord hi q))
          putRec (KeyTodo tailSeq) (RecTodo (Todo tile 1))
          let newCell = case payload of
                ReplaceAir → Air
                ReplaceMask mask → maybe Air (\(material, _) → cornerCell material mask) (cellOccupant effective)
              hasVoid = payload == ReplaceAir || not (null (cellComponents (cellOpenings newCell)))
              target = case payload of
                ReplaceAir → RunNode col runKey
                ReplaceMask _ → CellNode col z
              absorbed = [lo | (lo, _, ReplaceAir) ← olds, lo `notElem` newLos]
          -- An air run that lost its key joins the run that took its place.
          merged ←
            if payload == ReplaceAir
              then mapM (\lo → joinFlips <$> unionNodes (RunNode col runKey) (RunNode col lo)) absorbed
              else pure []
          -- The new cell contains the void the cell held, so the two are one
          -- space from the start: a cell that was known stays known. A cell that
          -- was never edited held its source void; a narrowed one holds a void of
          -- its own, which an air replacement now contains.
          held ←
            if not hasVoid
              then pure []
              else case cover of
                Nothing → case lookupVoid (envConn env) tile 0 of
                  InComponent key → (: []) . joinFlips <$> unionNodes target (SrcNode key)
                  _ → pure []
                Just _
                  | payload == ReplaceAir → (: []) . joinFlips <$> unionNodes target (CellNode col z)
                  | otherwise → pure []
          let flips = concatMap fst (merged <> held)
              joins = sum (map snd (merged <> held))
          -- The cell is now empty space of its class. When that class is known
          -- the cell is new known space (and exposes new walls): a knowledge
          -- change even when no class flips, whether the cell extended a known
          -- run, bridged runs already in one known class, joined a known old void
          -- or widened a known narrowed cell's void.
          gained ←
            if not hasVoid
              then pure []
              else do
                (root, ro) ← findRoot target
                pure [root | rootKnown ro, root `notElem` flips]
          pure (Just (flips <> gained, joins))
    joinFlips AlreadyJoined = ([], 0)
    joinFlips (Joined ns) = (ns, 1)
    finish s flips joins = do
      authority ← nextAuthority (hAuthority hdr) True flips
      let (writes, grown) = settleWrites s
          next =
            hdr
              { hAuthority = authority
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
              , reportScratchBytes = sPeak s
              , reportNewlyKnown = flips
              , reportPendingAfter = pendingObligations next
              }
      pure (EditStaged (Candidate (hAuthority hdr) next writes True (gainsKnowledge flips) report))

-- | Merge each run with the next when they touch and carry the same payload. The
-- input is ascending and disjoint.
coalescePieces ∷ [(Int64, Int64, Replacement)] → [(Int64, Int64, Replacement)]
coalescePieces ((a, b, p) : (c, d, q) : rest)
  | b == c && p == q = coalescePieces ((a, d, p) : rest)
coalescePieces (piece : rest) = piece : coalescePieces rest
coalescePieces [] = []

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
  , accPeak ∷ !Int
  -- ^ Peak accounted scratch, including that of a rejected inspection.
  }

-- | Run one discovery batch: at most the validated batch limit of structural
-- updates, each the inspection of one connection of the oldest unfinished
-- obligation. Every read and staged write is checked before it is made, so the
-- batch stops early, with the work intact, when the allowance is tighter or a
-- record is missing; a batch that cannot make even one update because of
-- capacity is refused with the resource. Every connection is inspected exactly
-- once; the obligation record carries the progress.
stepDiscovery ∷ Env → Header → Provider → Allowance → Either Refusal Step
stepDiscovery env hdr prov allow = fst (stepDiscoveryTraced env hdr prov allow)

-- | 'stepDiscovery' and the records the provider answered it. For 'Progress', the records of the inspections the batch
-- completed (what its candidate was computed from); for 'Stalled', those the first inspection resolved before the one it waits
-- for; empty otherwise. The outcome is exactly 'stepDiscovery''s.
stepDiscoveryTraced ∷ Env → Header → Provider → Allowance → (Either Refusal Step, ReadSet)
stepDiscoveryTraced env hdr0 prov allow
  | pendingObligations hdr0 == 0 = (Right Idle, noReads)
  | otherwise = loop (Acc (emptyS caps) hdr0 0 0 0 [] 0 0)
  where
    limits = envLimitsField env
    caps = capsOf limits allow hdr0
    batch = limitBatchUpdates limits
    loop acc
      | accUpdates acc >= batch = conclude acc HaltBatchFull noReads
      | pendingObligations (accHeader acc) == 0 = conclude acc HaltDrained noReads
      | otherwise = case runM (inspectHead (accHeader acc)) env prov (accS acc) of
          Left (Failure (StopMissing k) n peak rs) → conclude (attempt n peak acc) (HaltSuspended k) rs
          Left (Failure (StopCapacity cap) n peak _) → conclude (attempt n peak acc) (HaltCapacity cap) noReads
          Left (Failure (StopCorrupt i) _ _ _) → (Left (Corrupt i), noReads)
          Left (Failure StopOverflow _ _ _) → (Left AuthorityOverflow, noReads)
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
                , accPeak = max (accPeak acc) (sPeak s')
                }
    attempt n peak acc = acc {accAttempted = max n (accAttempted acc), accPeak = max peak (accPeak acc)}
    conclude acc halt failed
      | accUpdates acc == 0 = case halt of
          HaltSuspended k → (Right (Stalled k), failed)
          HaltCapacity cap → (Left (uncurry (CapacityBlocked cap) (capacityFigures WorkEdge limits caps cap)), noReads)
          _ → (Right Idle, noReads)
      | otherwise = (build acc halt, readSetOf (accS acc))
    build acc halt = do
      let s = accS acc
          (writes, grown) = settleWrites s
          knowledgeChanged = gainsKnowledge (accKnown acc)
          base = hAuthority hdr0
      authority ← nextAuthority base False (accKnown acc)
      let next =
            (accHeader acc)
              { hAuthority = authority
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
              , reportScratchBytes = max (sPeak s) (accPeak acc)
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

-- | The end and payload of a run record.
runPayload ∷ Record → Maybe (Int64, Replacement)
runPayload (RecRun hi) = Just (hi, ReplaceAir)
runPayload (RecMaskRun hi mask) = Just (hi, ReplaceMask mask)
runPayload _ = Nothing

-- | A provider over a map of records: exact lookups and a floor lookup over
-- the runs of a column.
recordProvider ∷ Map RecordKey Record → Provider
recordProvider m =
  Provider
    { fetchRecord = \k → maybe Absent Found (Map.lookup k m)
    , fetchFloorRun = \col z → case Map.lookupLE (KeyRun col z) m of
        Just (KeyRun c lo, record) | c == col, Just (hi, payload) ← runPayload record → Found (lo, hi, payload)
        _ → Absent
    }

-- | The retained air runs as validated intervals, for the existing removal-based
-- consumers ('Hetoimasia.Terrain.Changes.changesFromIntervals'). A run that
-- limits its levels to a corner mask is not removed and is in none of them: a
-- consumer reading these intervals reads every one as air.
retainedRemovals ∷ Retained → [(Column, ZRange)]
retainedRemovals r =
  [ (col, range)
  | (KeyRun col lo, RecRun hi) ← Map.toAscList (rRecords r)
  , Right range ← [mkZRange (toInteger lo) (toInteger hi)]
  ]

-- | Every retained run, air or mask, in ascending order of column and level: the
-- tagged form of "Hetoimasia.Terrain.Changes".
retainedReplacements ∷ Retained → [(Column, ZRange, Replacement)]
retainedReplacements r =
  [ (col, range, payload)
  | (KeyRun col lo, record) ← Map.toAscList (rRecords r)
  , Just (hi, payload) ← [runPayload record]
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
-- a legitimate state: kinds match their keys, runs are disjoint and no two that
-- touch carry the same payload, forest chains are short and end at a stored root, obligations are
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
      (KeyRun _ lo, RecMaskRun hi mask) | lo >= bottomLevel && lo < hi && hi <= topExclusive && cornerMaskValue mask /= 0 → Right ()
      (KeyLink _, RecRoot (Root size _)) | size >= 1 → Right ()
      (KeyLink node, RecChild parent) | parent /= node → Right ()
      (KeyTodo _, RecTodo (Todo _ done)) | done >= 1 && done < edgeCount → Right ()
      _ → Left (MalformedRecord k)
    runsOk m =
      let runs = [(col, lo, hi, payload) | (KeyRun col lo, record) ← Map.toAscList m, Just (hi, payload) ← [runPayload record]]
          bad = [KeyRun c2 l2 | ((c1, _, h1, p1), (c2, l2, _, p2)) ← zip runs (drop 1 runs), c1 == c2, l2 < h1 || (l2 == h1 && p1 == p2)]
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
  Left (Failure (StopMissing k) n _ _) → Observed (Left (MissingRecord k)) n
  Left (Failure (StopCorrupt i) n _ _) → Observed (Left (Inconsistent i)) n
  Left (Failure (StopCapacity CapacityReads) n _ _) → Observed (Left (ReadLimit (capReads caps))) n
  Left (Failure (StopCapacity cap) n _ _) → Observed (Left (QueryCapacity cap)) n
  Left (Failure StopOverflow n _ _) → Observed (Left (Inconsistent BadAccounting)) n
  where
    limits = envLimitsField env
    caps =
      Caps
        { capReads = limitInspectedRecords limits
        , capWrites = limitDeltaRecords limits
        , capDelta = limitDeltaBytes limits
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

-- | Whether a tile is currently air by removal. A narrowed cell still holds solid
-- and is not removed.
queryRemoved ∷ Env → Provider → TileCoord → Observed Bool
queryRemoved env prov tile = runQuery env prov $ do
  now ← cellNow tile
  pure $ case now of NowRemoved _ → True; _ → False

-- | Whether a source component's class is known. A component of the compiled
-- source is known exactly when its class holds an exterior component or has
-- been joined to known space.
queryComponentKnown ∷ Env → Provider → ComponentKey → Observed Bool
queryComponentKnown env prov key = runQuery env prov (nodeKnown (SrcNode key))

-- | One page of a known component's compressed boundary. The description is
-- paged so that neither the traversal nor the output is unbounded: a page holds
-- whole boxes of the component's class: at most 'limitBoundaryFaces' boxes are
-- scanned and as many faces returned (a page may hold fewer, or none, when the
-- boxes it scans lie inside the class), and 'pageNext' is where the next page
-- begins.
data BoundaryPage = BoundaryPage
  { pageFaces ∷ [BoundaryFace]
  , pageNext ∷ !(Maybe Int)
  -- ^ The identity of the box the next page resumes at.
  , pageVisited ∷ !Int
  -- ^ The member entries this page visited. Never above the limit: resuming
  -- seeks in an ordered set and walks nothing before the page.
  }
  deriving stock (Eq, Show)

-- | The compressed exposed boundary of a source component, when the component is
-- known, one bounded page at a time from a box identity (start at 0; each page names
-- where the next resumes): at most six
-- faces per box of the class, each a rectangle of cells with what lies across,
-- never an enumeration of exposed tiles. The page's accounted bytes are charged
-- through the same function as every read and write, before the page is built; a
-- limit too small for a page is refused ('QueryCapacity'). It describes the
-- immutable source; a removal's effect on a boundary is read cell by cell with
-- 'queryCell'. The whole description is the pages in order.
queryKnownBoundary ∷ Env → Provider → ComponentKey → Int → Observed (Maybe BoundaryPage)
queryKnownBoundary env prov key from = runQuery env prov $ do
  known ← nodeKnown (SrcNode key)
  if not known
    then pure Nothing
    else do
      let limit = limitBoundaryFaces (envLimitsField env)
      spend (ChargeOutput (boundaryPageBytes limit))
      case componentBoundaryPage (envConn env) (envMembers env) key (max 0 from) limit of
        Nothing → corrupt (UnknownComponent key)
        Just (faces, next, visited) → pure (Just (BoundaryPage faces next visited))

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

-- | What is known of a tile, from the source, the retained replacements and the
-- retained knowledge alone. Residency, materialization and camera motion are
-- not inputs. A required record the provider has not supplied is
-- 'MissingRecord', never unknown.
queryCell ∷ Env → Provider → TileCoord → Observed CellKnowledge
queryCell env prov tile = runQuery env prov $ do
  now ← cellNow tile
  voidKnown ← knownVoid env tile now
  if occupiedNow now
    then do
      solid ← solidKnown env tile now (voidKnown == VoidKnown)
      pure (CellKnowledge (if solid then SolidKnown else SolidUnknown) voidKnown)
    else pure (CellKnowledge NoSolid voidKnown)

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
