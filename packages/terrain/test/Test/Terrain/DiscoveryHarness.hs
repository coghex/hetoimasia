-- | The explicit independent model and the driver of the discovery specs.
--
-- /The oracle/ shares no code with the production overlay. It reads a
-- 'SourceSpec' and a list of removed cells as plain data (the naive scan of
-- "Test.Terrain.Model"), decides which neighbouring cells connect by the
-- sampled exact-rational rule of "Test.Terrain.ConnectivityOracle", floods an
-- explicit finite window cell by cell, and derives what a player knows from
-- first principles: the void cells of a flood component are known when one of
-- them is above the authored sky level (or is a top-level cell open to the
-- upper boundary), or was known before; a solid cell is known when it, over a
-- sampled part of a face, lies against a known void cell's open region, or its
-- own void is known. Its expected knowledge is never read from the production
-- overlay or its query answers.
--
-- /The driver/ stages a removal, applies the candidate, runs discovery batches
-- and checks, after every accepted, refused, suspended and resumed step, the
-- invariants of the retained state and the sandwich the oracle gives: the
-- production knowledge lies between the oracle's knowledge after the removals
-- whose obligations are finished and the oracle's knowledge after every removal,
-- and equals the latter when the obligations are drained.
--
-- It is a domain fixture of this suite, built through the package's public API.
module Test.Terrain.DiscoveryHarness
  ( -- * Scenes
    Scene (..)
  , groundScene
  , cellsOfWindow
  , patchColumn
  , caveRow

    -- * The driver
  , Delay (..)
  , noDelay
  , delayedProvider
  , Rig (..)
  , newRig
  , rigProvider
  , EditKind (..)
  , editRig
  , Batch (..)
  , batchRig
  , drainRig
  , drainWith
  , pendingOf

    -- * The oracle
  , Removed
  , contentWith
  , oracleSequence
  , oracleKnownVoid
  , oracleKnownSolid
  , modelKnowledge

    -- * Checks
  , invariants
  , compareKnowledge
  , compareDrained
  ) where

import qualified Data.Map.Lazy as Lazy
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Set (Set)
import qualified Data.Set as Set
import Hetoimasia.Terrain.Cell (Column (..), zRangeHi, zRangeLo)
import Hetoimasia.Terrain.Connectivity (ConnectivityLimits, defaultConnectivityLimits)
import Hetoimasia.Terrain.Coordinate (axisValue)
import Hetoimasia.Terrain.Discovery
import Hetoimasia.Terrain.Geometry (FaceKind (..))
import Hetoimasia.Terrain.Residency (ArenaId (..))
import Hetoimasia.Terrain.Shape (Side (..))
import Hetoimasia.Terrain.Source (CellSpec (..), LayerSpec (..), PatchSpec (..), SourceSpec (..))
import Test.Terrain.ConnectivityFixtures (mustCompile)
import Test.Terrain.ConnectivityOracle
  ( Cell3
  , Content (..)
  , Window (..)
  , contentOf
  , flood
  , hasVoid
  , inWindow
  , openOn
  , samples
  , topOpens
  , windowCells
  )
import Test.Terrain.Model (modelCell, mustSource, mustTile, topEnd)

-- ---------------------------------------------------------------------------
-- Scenes

-- | A small authored world: the source, the window the oracle floods, and the
-- first level of unobstructed sky above the ground (everything at or above it
-- is air to the upper limit).
data Scene = Scene
  { sceneName ∷ String
  , sceneSpec ∷ SourceSpec
  , sceneWindow ∷ Window
  , sceneSky ∷ Maybe Integer
  }

-- | Stone from the lowest level to @sky@, then air, with the given patches. The
-- window is @[x0, x1) × [y0, y1)@ from @sky - depth@ to @sky + 3@.
groundScene ∷ String → Integer → (Integer, Integer) → (Integer, Integer) → Integer → [PatchSpec] → Scene
groundScene name sky (x0, x1) (y0, y1) depth patches =
  Scene
    { sceneName = name
    , sceneSpec = SourceSpec ["stone", "slab"] [LayerSpec Nothing (Just sky) "stone" 0] patches
    , sceneWindow = Window (x0, x1) (y0, y1) (sky - depth, sky + 3)
    , sceneSky = Just sky
    }

-- | The cells of the oracle window.
cellsOfWindow ∷ Scene → [Cell3]
cellsOfWindow = windowCells . sceneWindow

-- | A vertical column of one content from @lo@ to @hi@ (exclusive).
patchColumn ∷ Integer → Integer → Integer → Integer → CellSpec → PatchSpec
patchColumn x y lo hi = PatchSpec x y lo hi

-- | A row of air along X at fixed @y@ and level, from @x0@ to @x1@ inclusive.
caveRow ∷ Integer → Integer → Integer → Integer → [PatchSpec]
caveRow y z x0 x1 = [PatchSpec x y z (z + 1) SpecAir | x ← [x0 .. x1]]

-- ---------------------------------------------------------------------------
-- The oracle

-- | A removed cell.
type Removed = Cell3

-- | What a cell holds once the removals are applied, in the oracle's reading.
contentWith ∷ Scene → [Removed] → Cell3 → Maybe Content
contentWith scene removed cell@(_, _, z)
  | z < negate topEnd || z >= topEnd = Nothing
  | otherwise = Just (contentOf (modelCell (sceneSpec scene) [(rx, ry, rz, rz + 1) | (rx, ry, rz) ← removed] cell))

-- | The void cells known after the removals, given the void cells known before.
oracleKnownVoid ∷ Scene → [Removed] → Set Cell3 → Set Cell3
oracleKnownVoid scene removed previous = Set.fromList [c | (c, comp) ← Map.toList components, Set.member comp knownComponents]
  where
    content = contentWith scene removed
    components = flood content (sceneWindow scene)
    isSeed c@(_, _, z) =
      Set.member c previous
        || maybe False (z >=) (sceneSky scene)
        || (z == topEnd - 1 && maybe False topOpens (content c))
    knownComponents = Set.fromList [comp | (c, comp) ← Map.toList components, isSeed c]

-- | The oracle's known void cells after each prefix of a removal sequence: the
-- first element is before any removal.
oracleSequence ∷ Scene → [Removed] → [Set Cell3]
oracleSequence scene removals = scanl step (oracleKnownVoid scene [] Set.empty) [1 .. length removals]
  where
    step previous n = oracleKnownVoid scene (take n removals) previous

-- | The solid cells known given the known void cells: a solid cell is known
-- when its own void is known or, over a sampled point of a shared face, it lies
-- against the open region of a known void cell; the top level also lies against
-- the sky.
oracleKnownSolid ∷ Scene → [Removed] → Set Cell3 → Set Cell3
oracleKnownSolid scene removed known = Set.fromList [c | c ← Set.toList candidates, solidKnown c]
  where
    window = sceneWindow scene
    content = contentWith scene removed
    candidates =
      Set.filter (inWindow window) (Set.union known (Set.fromList [n | c ← Set.toList known, (_, _, _, step) ← directions, let n = step c]))
        `Set.union` Set.fromList [c | c@(_, _, z) ← cellsOfWindow scene, z == topEnd - 1]
    solidKnown c = case content c of
      Nothing → False
      Just CAir → False
      Just cc
        | hasVoid cc && Set.member c known → True
        | otherwise → any (exposedTo c cc) directions
    exposedTo c@(_, _, z) cc (index, mine, _, step) =
      let n = step c
       in if inWindow window n && isJust (content n)
            then Set.member n known && maybe False (\nc → exposedTable Lazy.! (index, contentIndex cc, contentIndex nc)) (content n)
            else mine == TopFace && z == topEnd - 1 && exposedTable Lazy.! (6, contentIndex cc, 0)

-- | The six directions: table index, my face, their face and the neighbour.
directions ∷ [(Int, FaceKind, FaceKind, Cell3 → Cell3)]
directions =
  [ (0, WallFace East, WallFace West, \(x, y, z) → (x + 1, y, z))
  , (1, WallFace West, WallFace East, \(x, y, z) → (x - 1, y, z))
  , (2, WallFace South, WallFace North, \(x, y, z) → (x, y + 1, z))
  , (3, WallFace North, WallFace South, \(x, y, z) → (x, y - 1, z))
  , (4, TopFace, BottomFace, \(x, y, z) → (x, y, z + 1))
  , (5, BottomFace, TopFace, \(x, y, z) → (x, y, z - 1))
  ]

contentIndex ∷ Content → Int
contentIndex CAir = 0
contentIndex CBlock = 1
contentIndex (CShape s) = 1 + s

fromContentIndex ∷ Int → Content
fromContentIndex 0 = CAir
fromContentIndex 1 = CBlock
fromContentIndex n = CShape (n - 1)

-- | Whether, over some sampled point of the shared face, the neighbour is open
-- and the cell is not. Index 6 is the sky above: always open.
exposedTable ∷ Lazy.Map (Int, Int, Int) Bool
exposedTable =
  Lazy.fromList
    ( [ ((i, a, b), any (\p → openOn (fromContentIndex b) theirs p && not (openOn (fromContentIndex a) mine p)) samples)
      | (i, mine, theirs, _) ← directions
      , a ← [0 .. 16]
      , b ← [0 .. 16]
      ]
        <> [((6, a, 0), any (\p → not (openOn (fromContentIndex a) TopFace p)) samples) | a ← [0 .. 16]]
    )

-- | What the production queries say of a cell: void known, solid known.
modelKnowledge ∷ Env → Provider → Cell3 → Either String (Bool, Bool)
modelKnowledge env provider cell = case observedValue (queryCell env provider (mustTile3 cell)) of
  Left u → Left (show u)
  Right ck → Right (cellVoid ck == VoidKnown, cellSolid ck == SolidKnown)
  where
    mustTile3 (x, y, z) = mustTile x y z

-- ---------------------------------------------------------------------------
-- The driver

-- | Records the provider withholds: every lookup in a delayed column, and
-- exact records by key.
data Delay = Delay
  { delayColumns ∷ Set Column
  , delayKeys ∷ Set RecordKey
  }

noDelay ∷ Delay
noDelay = Delay Set.empty Set.empty

-- | A provider that withholds the delayed records and serves the rest.
delayedProvider ∷ Delay → Provider → Provider
delayedProvider d p =
  Provider
    { fetchRecord = \k → if Set.member k (delayKeys d) then Unavailable k else fetchRecord p k
    , fetchFloorRun = \c z →
        if Set.member c (delayColumns d)
          then Unavailable (KeyRun c z)
          else case fetchFloorRun p c z of
            Found (lo, _) | Set.member (KeyRun c lo) (delayKeys d) → Unavailable (KeyRun c lo)
            other → other
    }

-- | A scene's running state.
data Rig = Rig
  { rigScene ∷ Scene
  , rigEnv ∷ Env
  , rigRetained ∷ Retained
  , rigRemovals ∷ [Removed]
  -- ^ The removals whose edit candidates were applied, in order.
  , rigDelay ∷ Delay
  , rigReports ∷ [Report]
  -- ^ Every applied candidate's report, newest first.
  , rigLog ∷ [String]
  -- ^ Violations noticed while driving, newest first.
  , rigOracle ∷ [Set Cell3]
  -- ^ The oracle's known void cells before any removal and after each applied
  -- removal, in order.
  }

-- | A fresh rig for a scene under the limits.
newRig ∷ DiscoveryLimits → Scene → Rig
newRig limits scene =
  Rig
    { rigScene = scene
    , rigEnv = mkEnv limits (mustSource (sceneSpec scene)) (fst (mustCompile defaultConnectivityLimits' (sceneSpec scene)))
    , rigRetained = newRetained (ArenaId 1)
    , rigRemovals = []
    , rigDelay = noDelay
    , rigReports = []
    , rigLog = []
    , rigOracle = [oracleKnownVoid scene [] Set.empty]
    }

defaultConnectivityLimits' ∷ ConnectivityLimits
defaultConnectivityLimits' = defaultConnectivityLimits

-- | The provider a step reads through: the retained records minus the delayed.
rigProvider ∷ Rig → Provider
rigProvider rig = delayedProvider (rigDelay rig) (retainedProvider (rigRetained rig))

-- | What staging and applying a removal did.
data EditKind
  = EditApplied Report
  | EditNoOp
  | EditSuspendedOn RecordKey
  | EditRefused Refusal
  deriving stock (Eq, Show)

-- | Stage and apply the removal of a cell.
editRig ∷ Allowance → Cell3 → Rig → (Rig, EditKind)
editRig allow cell rig =
  case stageRemoval (rigEnv rig) (retainedHeader (rigRetained rig)) (rigProvider rig) allow (mustTile3 cell) of
    Left refusal → (rig, EditRefused refusal)
    Right NoChange → (rig, EditNoOp)
    Right (EditSuspended k) → (rig, EditSuspendedOn k)
    Right (Staged c) → case applyCandidate c (rigRetained rig) of
      Left e → (rig {rigLog = ("apply refused " <> show e) : rigLog rig}, EditNoOp)
      Right retained' →
        let removals' = rigRemovals rig <> [cell]
         in ( rig
            { rigRetained = retained'
            , rigRemovals = removals'
            , rigOracle = rigOracle rig <> [oracleKnownVoid (rigScene rig) removals' (last (rigOracle rig))]
            , rigReports = candidateReport c : rigReports rig
            }
        , EditApplied (candidateReport c)
        )
  where
    mustTile3 (x, y, z) = mustTile x y z

-- | What a discovery batch did.
data Batch
  = BatchIdle
  | BatchProgress Report Halt
  | BatchStalled RecordKey
  | BatchRefused Refusal
  deriving stock (Eq, Show)

-- | Run one discovery batch and apply its candidate.
batchRig ∷ Allowance → Rig → (Rig, Batch)
batchRig allow rig = case stepDiscovery (rigEnv rig) (retainedHeader (rigRetained rig)) (rigProvider rig) allow of
  Left refusal → (rig, BatchRefused refusal)
  Right Idle → (rig, BatchIdle)
  Right (Stalled k) → (rig, BatchStalled k)
  Right (Progress c halt) → case applyCandidate c (rigRetained rig) of
    Left e → (rig {rigLog = ("apply refused " <> show e) : rigLog rig}, BatchIdle)
    Right retained' → (rig {rigRetained = retained', rigReports = candidateReport c : rigReports rig}, BatchProgress (candidateReport c) halt)

-- | Run batches until the obligations are drained, at most a bounded number.
drainRig ∷ Allowance → Rig → Rig
drainRig = drainWith (const id)

-- | Drain, calling a hook after every batch.
drainWith ∷ (Batch → Rig → Rig) → Allowance → Rig → Rig
drainWith hook allow = go (100000 ∷ Int)
  where
    go 0 rig = rig {rigLog = "drain did not finish" : rigLog rig}
    go n rig = case batchRig allow rig of
      (rig', BatchProgress r h) → go (n - 1) (hook (BatchProgress r h) rig')
      (rig', other) → hook other rig'

-- | The unfinished obligations.
pendingOf ∷ Rig → Integer
pendingOf = toInteger . pendingObligations . retainedHeader . rigRetained

-- ---------------------------------------------------------------------------
-- Checks

-- | The structural invariants of the retained state: it rebuilds from its own
-- records, the removed runs are exactly the removals applied, the header names
-- exactly the obligations held and no violation was logged.
invariants ∷ Rig → [String]
invariants rig =
  rigLog rig
    <> case retainedFromRecords (retainedHeader retained) (retainedRecords retained) of
      Left e → ["retained state is not legitimate: " <> show e]
      Right _ → []
    <> [ "removed runs differ from the applied removals"
       | expandedRuns /= Set.fromList (rigRemovals rig)
       ]
  where
    retained = rigRetained rig
    expandedRuns =
      Set.fromList
        [ (toInteger (axisValue x), toInteger (axisValue y), z)
        | (Column x y, range) ← retainedRemovals retained
        , z ← [zRangeLo range .. zRangeHi range - 1]
        ]

-- | Compare production knowledge with the oracle's sandwich over the window's
-- inner cells: between the knowledge after the removals whose obligations are
-- finished and the knowledge after every removal.
compareKnowledge ∷ Rig → [String]
compareKnowledge rig = concatMap check inner
  where
    scene = rigScene rig
    sequenceK = rigOracle rig
    finished = fromIntegral (hHead (retainedHeader (rigRetained rig)))
    lowerVoid = sequenceK !! min finished (length sequenceK - 1)
    upperVoid = last sequenceK
    lowerSolid = oracleKnownSolid scene (take finished (rigRemovals rig)) lowerVoid
    upperSolid = oracleKnownSolid scene (rigRemovals rig) upperVoid
    Window (x0, x1) (y0, y1) (z0, z1) = sceneWindow scene
    inner = [c | c@(x, y, z) ← cellsOfWindow scene, x > x0, x < x1 - 1, y > y0, y < y1 - 1, z > z0, z < z1 - 1]
    provider = retainedProvider (rigRetained rig)
    check c = case modelKnowledge (rigEnv rig) provider c of
      Left e → [show c <> ": query unresolved " <> e]
      Right (v, s) →
        [show c <> ": void known " <> show v <> " outside oracle bounds" | v /= Set.member c upperVoid && (v || Set.member c lowerVoid)]
          <> [show c <> ": solid known " <> show s <> " outside oracle bounds" | s /= Set.member c upperSolid && (s || Set.member c lowerSolid)]

-- | Compare production knowledge with the oracle exactly; use it when the
-- obligations are drained.
compareDrained ∷ Rig → [String]
compareDrained rig =
  [ "obligations remain: " <> show (pendingOf rig) | pendingOf rig /= 0 ]
    <> concatMap check inner
  where
    scene = rigScene rig
    knownV = last (rigOracle rig)
    knownS = oracleKnownSolid scene (rigRemovals rig) knownV
    Window (x0, x1) (y0, y1) (z0, z1) = sceneWindow scene
    inner = [c | c@(x, y, z) ← cellsOfWindow scene, x > x0, x < x1 - 1, y > y0, y < y1 - 1, z > z0, z < z1 - 1]
    provider = retainedProvider (rigRetained rig)
    check c = case modelKnowledge (rigEnv rig) provider c of
      Left e → [show c <> ": query unresolved " <> e]
      Right (v, s) →
        [show c <> ": void known " <> show v <> ", oracle " <> show (Set.member c knownV) | v /= Set.member c knownV]
          <> [show c <> ": solid known " <> show s <> ", oracle " <> show (Set.member c knownS) | s /= Set.member c knownS]
