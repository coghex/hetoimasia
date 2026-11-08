{-# LANGUAGE BangPatterns #-}

-- | Bounded, resumable preparation of a source's connectivity.
--
-- = The counted primitive
--
-- The compilation is written as a coroutine ('Co'): straight-line code that
-- pauses at every counted /step/. One step is one of
--
-- * forcing one entry of the connection table (one exact portal comparison),
-- * adding one authored layer, patch column or patch interval to the cuts,
-- * classifying one lattice box (a handful of ordered-map lookups),
-- * testing one node against one forward neighbour, and recording the relation
--   if they connect (at most three union-find operations of at most
--   @log2 nodes@ hops each),
-- * folding one collapse mark, or one node, into the canonical result, or
-- * assembling the result.
--
-- Each step does a constant number of operations on containers whose size the
-- limits already bound (cuts, nodes, relations), so no step scans a coordinate
-- extent, an unbounded container or an arbitrary recipe: the work is the number
-- of authored boundaries, lattice boxes and relations, whatever the span of any
-- interval. Exact arithmetic is on 'Int64' coordinates inside @[-2^62, 2^62]@ or
-- on 'Integer', and every sum that could leave a limit is formed in 'Integer'
-- and compared before the work or allocation it pays for.
--
-- = Accounting
--
-- Bytes are conservative /admission/ figures (the constants below), not
-- measurements of heap or RSS. They are charged before the corresponding
-- allocation or work. The /result/ bytes are what the finished index retains;
-- the /peak/ adds the temporaries that exist at the same moment (union-find
-- state, the collapse marks) and is released when canonicalization ends. The
-- shared immutable input (the validated source) is not charged: it is only read,
-- and its own size stays governed by the independent source limits. The
-- connection table is a constant shared by the process and is charged as work,
-- not as bytes.
--
-- State, ownership and lifetime: none. A 'Preparation' is an immutable
-- continuation; dropping it discards every pending result, and resuming it
-- twice yields the same outcome twice. Nothing is published before 'Complete'.
module Hetoimasia.Terrain.Internal.Connectivity.Prepare
  ( -- * Outcome
    Resource (..)
  , Refusal (..)
  , PrepareError (..)
  , PrepareStats (..)
  , Progress (..)
  , ResumeError (..)

    -- * Preparing
  , Preparation
  , startPreparation
  , resumePreparation
  , preparationStats
  , prepareConnectivity

    -- * Accounting constants
  , headerResultBytes
  , cutResultBytes
  , nodeResultBytes
  , memberResultBytes
  , classResultBytes
  , relationResultBytes
  , nodeTempBytes
  ) where

import Control.Monad (foldM, when)
import Data.Bits (testBit, (.|.))
import Data.Int (Int64)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet
import qualified Data.Map.Strict as Map
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Word (Word8)
import Hetoimasia.Terrain.Internal.Cell (Cell, Column (..), bottomLevel, topExclusive)
import Hetoimasia.Terrain.Internal.Connectivity.Index
import Hetoimasia.Terrain.Internal.Connectivity.Kind
import Hetoimasia.Terrain.Internal.Connectivity.Limits
import Hetoimasia.Terrain.Internal.Coordinate (AxisCoord (..))
import Hetoimasia.Terrain.Internal.Source (Source (..))

-- ---------------------------------------------------------------------------
-- Outcome

-- | The resource a compilation exhausted. A refusal for any of these is the
-- expected @source_complexity@ outcome of a valid source whose connectivity is
-- larger than the configured limits.
data Resource
  = ResultBytes
  | PeakBytes
  | StructuralNodes
  | PortalRelations
  | WorkSteps
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | An exhausted resource with the figure the compilation needed to continue
-- and the limit that stopped it. The needed figure is the total the charge
-- would have reached (for the lattice, a lower bound of the work it implies).
data Refusal = Refusal
  { refusedResource ∷ !Resource
  , refusedNeeded ∷ !Integer
  , refusedLimit ∷ !Integer
  }
  deriving stock (Eq, Show)

-- | Why a compilation stopped without a result.
data PrepareError
  = -- | A limit was exhausted: the expected @source_complexity@ outcome.
    Complexity !Refusal
  | -- | A catalog kind has more than one empty component per cell, which the
    -- compiler does not address yet. The current catalog has none.
    Unsupported !Kind
  | -- | The compiler's own consistency check failed. This is a defect, never an
    -- outcome of a valid source.
    Inconsistent !String
  deriving stock (Eq, Show)

-- | The figures of a compilation so far, or in total once it ended.
data PrepareStats = PrepareStats
  { workSteps ∷ !Integer
  , workMaxQuantum ∷ !Integer
  -- ^ The most steps any one resume took.
  , workLatticeCells ∷ !Integer
  , workNodes ∷ !Integer
  , workRelations ∷ !Integer
  , workResultBytes ∷ !Integer
  , workPeakBytes ∷ !Integer
  }
  deriving stock (Eq, Show)

-- | A refused resume request.
data ResumeError
  = -- | A quantum of zero or fewer steps.
    QuantumNotPositive !Int
  | -- | A quantum above the configured per-resume maximum: the request and the
    -- maximum.
    QuantumAboveLimit !Int !Int
  deriving stock (Eq, Show)

-- | The state after a resume.
data Progress
  = -- | More to do. The continuation holds every pending piece.
    Pending !Preparation
  | -- | The complete index and the totals.
    Complete !Connectivity !PrepareStats
  | -- | The compilation stopped; nothing partial escapes.
    Refused !PrepareError !PrepareStats

-- ---------------------------------------------------------------------------
-- Accounting constants

-- | The fixed record of the result.
headerResultBytes ∷ Int
headerResultBytes = 512

-- | One cut of one axis: a set element and its tree overhead.
cutResultBytes ∷ Int
cutResultBytes = 48

-- | One node: its record, its map entry and its lattice index entry.
nodeResultBytes ∷ Int
nodeResultBytes = 160

-- | One node's membership in its class list.
memberResultBytes ∷ Int
memberResultBytes = 40

-- | One class: its member entry and its exterior slot.
classResultBytes ∷ Int
classResultBytes = 96

-- | One relation record.
relationResultBytes ∷ Int
relationResultBytes = 64

-- | The temporaries one node needs until canonicalization ends: its entries in
-- the node and dimension union-find maps and its collapse marks.
nodeTempBytes ∷ Int
nodeTempBytes = 512

-- ---------------------------------------------------------------------------
-- The coroutine

data Acct = Acct
  { aLimits ∷ !ConnectivityLimits
  , aSteps ∷ !Int
  , aNodes ∷ !Int
  , aRelations ∷ !Int
  , aResult ∷ !Int
  , aTemp ∷ !Int
  , aPeak ∷ !Int
  , aLattice ∷ !Integer
  }

data Out a
  = Fin !Acct a
  | Yield !Acct (Co a)
  | Stop !PrepareError !Acct

newtype Co a = Co {runCo ∷ Acct → Out a}

instance Functor Co where
  fmap f (Co m) = Co $ \acct → case m acct of
    Fin a' x → Fin a' (f x)
    Yield a' k → Yield a' (fmap f k)
    Stop e a' → Stop e a'

instance Applicative Co where
  pure x = Co (\acct → Fin acct x)
  Co mf <*> Co mx = Co $ \acct → case mf acct of
    Fin a' f → case mx a' of
      Fin a'' x → Fin a'' (f x)
      Yield a'' k → Yield a'' (fmap f k)
      Stop e a'' → Stop e a''
    Yield a' k → Yield a' (k <*> Co mx)
    Stop e a' → Stop e a'

instance Monad Co where
  Co m >>= f = Co $ \acct → case m acct of
    Fin a' x → runCo (f x) a'
    Yield a' k → Yield a' (k >>= f)
    Stop e a' → Stop e a'

getAcct ∷ Co Acct
getAcct = Co (\acct → Fin acct acct)

putAcct ∷ Acct → Co ()
putAcct acct = Co (\_ → Fin acct ())

failWith ∷ PrepareError → Co a
failWith e = Co (Stop e)

exhausted ∷ Resource → Integer → Int → Co a
exhausted resource needed limit = failWith (Complexity (Refusal resource needed (toInteger limit)))

-- | Count one step, pausing. The limit is checked before the step is taken.
tick ∷ Co ()
tick = Co $ \acct →
  let steps = aSteps acct + 1
      limit = limitWorkSteps (aLimits acct)
   in if steps > limit
        then Stop (Complexity (Refusal WorkSteps (toInteger steps) (toInteger limit))) acct
        else Yield acct {aSteps = steps} (pure ())

-- | Charge retained result bytes before the allocation they pay for.
chargeResult ∷ Int → Co ()
chargeResult bytes = do
  acct ← getAcct
  let result = toInteger (aResult acct) + toInteger bytes
      peak = result + toInteger (aTemp acct)
      limits = aLimits acct
  when (result > toInteger (limitResultBytes limits)) $ exhausted ResultBytes result (limitResultBytes limits)
  when (peak > toInteger (limitPeakBytes limits)) $ exhausted PeakBytes peak (limitPeakBytes limits)
  putAcct acct {aResult = fromInteger result, aPeak = max (aPeak acct) (fromInteger peak)}

-- | Charge temporary bytes before the allocation they pay for.
chargeTemp ∷ Int → Co ()
chargeTemp bytes = do
  acct ← getAcct
  let temp = toInteger (aTemp acct) + toInteger bytes
      peak = toInteger (aResult acct) + temp
      limits = aLimits acct
  when (peak > toInteger (limitPeakBytes limits)) $ exhausted PeakBytes peak (limitPeakBytes limits)
  putAcct acct {aTemp = fromInteger temp, aPeak = max (aPeak acct) (fromInteger peak)}

-- | Release temporaries that no longer exist.
releaseTemp ∷ Int → Co ()
releaseTemp bytes = do
  acct ← getAcct
  putAcct acct {aTemp = max 0 (aTemp acct - bytes)}

chargeNode ∷ Co ()
chargeNode = do
  acct ← getAcct
  let nodes = toInteger (aNodes acct) + 1
      limit = limitNodes (aLimits acct)
  when (nodes > toInteger limit) $ exhausted StructuralNodes nodes limit
  putAcct acct {aNodes = fromInteger nodes}

chargeRelation ∷ Co ()
chargeRelation = do
  acct ← getAcct
  let relations = toInteger (aRelations acct) + 1
      limit = limitRelations (aLimits acct)
  when (relations > toInteger limit) $ exhausted PortalRelations relations limit
  putAcct acct {aRelations = fromInteger relations}

-- ---------------------------------------------------------------------------
-- Driving

-- | A suspended compilation.
data Preparation = Preparation (Co Connectivity) !Acct !Integer

-- | Begin compiling a validated source under validated limits. Nothing runs
-- until the first resume.
startPreparation ∷ ConnectivityLimits → Source → Preparation
startPreparation limits source =
  Preparation
    (compile source)
    Acct
      { aLimits = limits
      , aSteps = 0
      , aNodes = 0
      , aRelations = 0
      , aResult = 0
      , aTemp = 0
      , aPeak = 0
      , aLattice = 0
      }
    0

-- | The totals so far.
preparationStats ∷ Preparation → PrepareStats
preparationStats (Preparation _ acct maxQuantum) = statsOf acct maxQuantum

statsOf ∷ Acct → Integer → PrepareStats
statsOf acct maxQuantum =
  PrepareStats
    { workSteps = toInteger (aSteps acct)
    , workMaxQuantum = maxQuantum
    , workLatticeCells = aLattice acct
    , workNodes = toInteger (aNodes acct)
    , workRelations = toInteger (aRelations acct)
    , workResultBytes = toInteger (aResult acct)
    , workPeakBytes = toInteger (aPeak acct)
    }

-- | Run at most @quantum@ steps. A request for zero or fewer steps, or for more
-- than the configured maximum, is refused rather than clamped.
resumePreparation ∷ Int → Preparation → Either ResumeError Progress
resumePreparation quantum (Preparation co acct maxQuantum)
  | quantum <= 0 = Left (QuantumNotPositive quantum)
  | quantum > limitQuantumSteps (aLimits acct) = Left (QuantumAboveLimit quantum (limitQuantumSteps (aLimits acct)))
  | otherwise = Right (go 0 co acct)
  where
    go ∷ Int → Co Connectivity → Acct → Progress
    go !used k a = case runCo k a of
      Fin a' result → Complete result (statsOf a' (max maxQuantum (toInteger used)))
      Stop e a' → Refused e (statsOf a' (max maxQuantum (toInteger used)))
      Yield a' k'
        | used + 1 >= quantum → Pending (Preparation k' a' (max maxQuantum (toInteger (used + 1))))
        | otherwise → go (used + 1) k' a'

-- | Compile in one call, in quanta of the configured maximum.
prepareConnectivity ∷ ConnectivityLimits → Source → Either PrepareError (Connectivity, PrepareStats)
prepareConnectivity limits source = loop (startPreparation limits source)
  where
    quantum = limitQuantumSteps limits
    loop preparation = case resumePreparation quantum preparation of
      Left _ → Left (Inconsistent "the configured quantum was refused")
      Right (Pending next) → loop next
      Right (Complete result stats) → Right (result, stats)
      Right (Refused e _) → Left e

-- ---------------------------------------------------------------------------
-- Union-find over small integer keys

data UF = UF !(IntMap Int) !(IntMap Int)

emptyUF ∷ UF
emptyUF = UF IntMap.empty IntMap.empty

-- | The root of an element. No path compression: the depth is at most
-- @log2@ of the elements by union by size.
find ∷ UF → Int → Int
find uf@(UF parent _) x = case IntMap.lookup x parent of
  Just p | p /= x → find uf p
  _ → x

union ∷ UF → Int → Int → UF
union uf@(UF parent size) a b
  | ra == rb = uf
  | sa < sb || (sa == sb && ra > rb) = UF (IntMap.insert ra rb parent) (IntMap.insert rb (sa + sb) size)
  | otherwise = UF (IntMap.insert rb ra parent) (IntMap.insert ra (sa + sb) size)
  where
    ra = find uf a
    rb = find uf b
    sa = IntMap.findWithDefault 1 ra size
    sb = IntMap.findWithDefault 1 rb size

-- ---------------------------------------------------------------------------
-- The compilation

compile ∷ Source → Co Connectivity
compile source = do
  chargeResult headerResultBytes
  initialise
  cuts ← gatherCuts source
  (nodeAt, nodes) ← buildLattice source cuts
  related ← buildRelations cuts nodeAt nodes
  canonical cuts nodeAt nodes related

-- Initialisation: force every entry of the connection table, one step each, and
-- refuse a catalog the compiler cannot address.
initialise ∷ Co ()
initialise = do
  mapM_ (\kind → tick >> when (unsupportedKind kind) (failWith (Unsupported kind))) [0 .. kindCount - 1]
  mapM_ (\index → tick >> forced (tableProbe index)) [0 .. tableSize - 1]
  where
    forced ∷ Bool → Co ()
    forced b = b `seq` pure ()

data Cuts = Cuts !(Set Int64) !(Set Int64) !(Set Int64)

addCut ∷ Int → Int64 → Cuts → Co Cuts
addCut axis v cuts@(Cuts xs ys zs)
  | v < bottomLevel || v > topExclusive = pure cuts
  | Set.member v current = pure cuts
  | otherwise = do
      chargeResult cutResultBytes
      pure $! case axis of
        0 → Cuts (Set.insert v xs) ys zs
        1 → Cuts xs (Set.insert v ys) zs
        _ → Cuts xs ys (Set.insert v zs)
  where
    current = case axis of
      0 → xs
      1 → ys
      _ → zs

-- Cut a Z boundary and the cell just below it.
addBoundary ∷ Int64 → Cuts → Co Cuts
addBoundary b cuts = addCut 2 b cuts >>= addCut 2 (b - 1)

gatherCuts ∷ Source → Co Cuts
gatherCuts source = do
  let empty = Cuts Set.empty Set.empty Set.empty
  c0 ← addCut 0 bottomLevel empty >>= addCut 0 topExclusive
  c1 ← addCut 1 bottomLevel c0 >>= addCut 1 topExclusive
  c2 ← addBoundary bottomLevel c1 >>= addBoundary topExclusive
  c3 ← foldM layerStep c2 (Map.toAscList (sourceLayerMap source))
  foldM columnStep c3 (Map.toAscList (sourcePatchMap source))
  where
    layerStep cuts (lo, (hi, _)) = tick >> addBoundary lo cuts >>= addBoundary hi
    columnStep cuts (Column (AxisCoord x) (AxisCoord y), intervals) = do
      tick
      c1 ← foldM (\c d → addCut 0 (x + d) c) cuts [-1, 0, 1, 2]
      c2 ← foldM (\c d → addCut 1 (y + d) c) c1 [-1, 0, 1, 2]
      foldM intervalStep c2 (Map.toAscList intervals)
    intervalStep cuts (lo, (hi, _)) = tick >> addBoundary lo cuts >>= addBoundary hi

-- The kind of content in a box. A box of one column holding a patch takes the
-- patch's content where the patch covers the box's lowest level; every other
-- box takes the layer's, or air. Cuts at every boundary make the content
-- constant across the box.
contentKind ∷ Source → Int64 → Int64 → Int64 → Int64 → Int64 → Kind
contentKind source x0 x1 y0 y1 z0
  | x1 == x0 + 1
  , y1 == y0 + 1
  , Just column ← Map.lookup (Column (AxisCoord x0) (AxisCoord y0)) (sourcePatchMap source)
  , Just cell ← coverAt column z0 =
      kindOfCell cell
  | Just cell ← coverAt (sourceLayerMap source) z0 = kindOfCell cell
  | otherwise = kindAir

coverAt ∷ Map.Map Int64 (Int64, Cell) → Int64 → Maybe Cell
coverAt intervals z = case Map.lookupLE z intervals of
  Just (_, (hi, cell)) | z < hi → Just cell
  _ → Nothing

consecutive ∷ [a] → [(a, a)]
consecutive xs = zip xs (drop 1 xs)

buildLattice ∷ Source → Cuts → Co (IntMap Int, IntMap Node)
buildLattice source (Cuts xs ys zs) = do
  let nx = Set.size xs - 1
      ny = Set.size ys - 1
      nz = Set.size zs - 1
      cells = toInteger nx * toInteger ny * toInteger nz
  acct ← getAcct
  -- Every lattice box takes at least one step, so a lattice larger than the
  -- remaining work cannot complete: refuse before taking any of it.
  let needed = toInteger (aSteps acct) + cells
      limit = limitWorkSteps (aLimits acct)
  when (needed > toInteger limit) $ exhausted WorkSteps needed limit
  putAcct acct {aLattice = cells}
  let xIntervals = consecutive (Set.toAscList xs)
      yIntervals = consecutive (Set.toAscList ys)
      zIntervals = consecutive (Set.toAscList zs)
      boxes =
        [ (i + nx * (j + ny * k), x0, x1, y0, y1, z0, z1)
        | (k, (z0, z1)) ← zip [0 ..] zIntervals
        , (j, (y0, y1)) ← zip [0 ..] yIntervals
        , (i, (x0, x1)) ← zip [0 ..] xIntervals
        ]
  (_, nodeAt, nodes) ← foldM step (0 ∷ Int, IntMap.empty, IntMap.empty) boxes
  pure (nodeAt, nodes)
  where
    step (!next, !nodeAt, !nodes) (index, x0, x1, y0, y1, z0, z1) = do
      tick
      let kind = contentKind source x0 x1 y0 y1 z0
      if not (kindHasVoid kind)
        then pure (next, nodeAt, nodes)
        else do
          chargeNode
          chargeResult nodeResultBytes
          chargeTemp nodeTempBytes
          -- More than one cell wide: the comparison avoids a subtraction that would
          -- overflow a world-spanning interval.
          let retain axis lo hi = if hi > lo + 1 && not (joinedAlong axis kind) then axisBit axis else 0
              mask = retain 0 x0 x1 .|. retain 1 y0 y1 .|. retain 2 z0 z1
              node = Node {nodeLattice = index, nodeKind = kind, nodeClass = next, nodeRetain = mask, nodeAxes = mask}
          pure (next + 1, IntMap.insert index next nodeAt, IntMap.insert next node nodes)

data Related = Related
  { relNodes ∷ !UF
  , relDims ∷ !UF
  , relMarks ∷ !IntSet
  , relList ∷ !(Seq Relation)
  }

buildRelations ∷ Cuts → IntMap Int → IntMap Node → Co Related
buildRelations (Cuts xs ys zs) nodeAt nodes = foldM visit (Related emptyUF emptyUF IntSet.empty Seq.empty) (IntMap.toAscList nodes)
  where
    size@(nx, ny, nz) = (Set.size xs - 1, Set.size ys - 1, Set.size zs - 1)
    (sx, sy, sz) = strides size
    visit related (nid, node) = foldM (axisStep nid node) related [0, 1, 2]
    axisStep nid node related axis = do
      tick
      let (i, j, k) = decodeLattice size (nodeLattice node)
          (position, limit, step) = case axis of
            0 → (i, nx, sx)
            1 → (j, ny, sy)
            _ → (k, nz, sz)
      case (position + 1 < limit, IntMap.lookup (nodeLattice node + step) nodeAt) of
        (True, Just other) | Just otherNode ← IntMap.lookup other nodes, joined axis (nodeKind node) (nodeKind otherNode) → relate related nid node other otherNode axis
        _ → pure related

    relate related nid node other otherNode axis = do
      chargeRelation
      chargeResult relationResultBytes
      tick
      -- A relation joins whole faces. A node that keeps the relation's own axis
      -- as a parameter would join only its end layer: the cuts rule that out.
      when (testBit (nodeRetain node) axis || testBit (nodeRetain otherNode) axis) $
        failWith (Inconsistent ("a relation joins a partial face on axis " <> show axis))
      let nodesUF = union (relNodes related) nid other
          step (!dimUF, !markSet) b
            | b == axis = (dimUF, markSet)
            | otherwise =
                let ra = testBit (nodeRetain node) b
                    rb = testBit (nodeRetain otherNode) b
                 in case (ra, rb) of
                      (True, True) → (union dimUF (3 * nid + b) (3 * other + b), markSet)
                      (True, False) → (dimUF, IntSet.insert (3 * nid + b) markSet)
                      (False, True) → (dimUF, IntSet.insert (3 * other + b) markSet)
                      (False, False) → (dimUF, markSet)
          (dimsUF, marksOut) = foldl step (relDims related, relMarks related) [0, 1, 2]
      pure
        Related
          { relNodes = nodesUF
          , relDims = dimsUF
          , relMarks = marksOut
          , relList = relList related |> Relation nid other axis
          }

data Canon = Canon
  { canRep ∷ !(IntMap Int)
  , canNodes ∷ !(IntMap Node)
  , canMembers ∷ !(IntMap [Int])
  , canAxes ∷ !(IntMap Word8)
  , canExterior ∷ !IntSet
  }

canonical ∷ Cuts → IntMap Int → IntMap Node → Related → Co Connectivity
canonical (Cuts xs ys zs) nodeAt nodes related = do
  collapsed ← foldM (\roots m → tick >> pure (IntSet.insert (find (relDims related) m) roots)) IntSet.empty (IntSet.toAscList (relMarks related))
  let size = (Set.size xs - 1, Set.size ys - 1, Set.size zs - 1)
      (_, _, nz) = size
      top = nz - 1
  canon ← foldM (visit collapsed size top) (Canon IntMap.empty IntMap.empty IntMap.empty IntMap.empty IntSet.empty) (IntMap.toAscList nodes)
  releaseTemp (IntMap.size nodes * nodeTempBytes)
  tick
  acct ← getAcct
  let cells = aLattice acct
      stats =
        Stats
          { statLatticeCells = cells
          , statNodes = toInteger (aNodes acct)
          , statRelations = toInteger (aRelations acct)
          , statClasses = toInteger (IntMap.size (canAxes canon))
          , statResultBytes = toInteger (aResult acct)
          }
  pure
    Connectivity
      { cXCuts = xs
      , cYCuts = ys
      , cZCuts = zs
      , cNodeAt = nodeAt
      , cNodes = canNodes canon
      , cMembers = canMembers canon
      , cExterior = canExterior canon
      , cRelations = relList related
      , cStats = stats
      }
  where
    visit collapsed size top canon (nid, node) = do
      tick
      let root = find (relNodes related) nid
          known = IntMap.lookup root (canRep canon)
          rep = maybe nid id known
          axes = foldl (\m b → if testBit (nodeRetain node) b && not (IntSet.member (find (relDims related) (3 * nid + b)) collapsed) then m .|. axisBit b else m) (0 ∷ Word8) [0, 1, 2]
          (_, _, k) = decodeLattice size (nodeLattice node)
          exterior = k == top && kindTopOpens (nodeKind node)
      case known of
        Nothing → chargeResult classResultBytes
        Just _ → pure ()
      chargeResult memberResultBytes
      when (rep /= nid) $
        case IntMap.lookup rep (canAxes canon) of
          Just repAxes
            | repAxes == axes → pure ()
          _ → failWith (Inconsistent "the nodes of one class keep different parameters")
      pure
        Canon
          { canRep = IntMap.insert root rep (canRep canon)
          , canNodes = IntMap.insert nid node {nodeClass = rep, nodeAxes = axes} (canNodes canon)
          , canMembers = IntMap.insertWith (++) rep [nid] (canMembers canon)
          , canAxes = if rep == nid then IntMap.insert nid axes (canAxes canon) else canAxes canon
          , canExterior = if exterior then IntSet.insert rep (canExterior canon) else canExterior canon
          }
