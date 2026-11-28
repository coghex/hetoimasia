-- | Building a regional snapshot (#690) from ONE pinned committed version of an arena's store, through
-- the storage backend, as a resumable state machine of bounded steps.
--
-- 'startBuild' pins the version; the build then takes each region in turn:
--
-- 1. the removed runs of its 256 columns over its levels and one beyond each end ('D.regionReadLevels'),
--    which give its terrain part;
-- 2. the runs of the 64 columns beside it over the same levels, which its knowledge depends on;
-- 3. its knowledge plan ('D.planRegionKnowledge', pure), then 'D.queryCell' at each of the plan's tiles,
--    one tile a read, then the assembled, compressed answer ('D.assembleRegionKnowledge').
--
-- Every read runs on the same pin, through a window carried from read to read within a region, started
-- afresh for each region and whenever a read would need more than a reader may pin, so the build retains
-- ONE root identity however many windows it uses, and nothing it reads can come from another version. The
-- window has ONE owner at a time: the read in progress, or the evaluation step waiting to start the next
-- read; a read that starts afresh drops the window it replaced, so a build never holds more than one
-- window. Only the requested regions are copied; the columns beside them are read as dependencies and
-- kept only while their region is built. A finished region is evaluated in full at its end ('settledCopy'):
-- nothing of its reads, plan or answers survives it, so what a build retains between regions is its
-- packed copies alone.
--
-- == Failures
--
-- A page that does not arrive keeps the build waiting ('BBlocked'), never answered from the source or as
-- air. A page that fails, or reads back invalid, makes unavailable the parts that needed it (a failure in
-- the region's own columns both of its parts; beside them, or in a knowledge read, its knowledge) and is
-- handed to the owner to record as any failed read is ('BNoted'); the page is remembered, so any later
-- read of the build that needs it fails the same way without reading it again: a failed shared dependency
-- makes every dependent part unavailable, and parts established independently stay usable. Temporary
-- pressure keeps the build and starts the interrupted read again once it has changed ('BPressed'). A
-- closure or a defect ends it ('BFailed').
--
-- == State, owner, thread, lifetime
--
-- A 'Build' and the pin it holds are the terrain owner's, on its one thread, like a gather
-- ("Hetoimasia.Terrain.Runtime.Backed.Gather"): the pin lives from 'startBuild' to 'endBuild', which is
-- called on every exit once no read of the build is in flight ('BDone', 'BFailed' or 'BDrained'). What it
-- has copied so far is charged to its request's reservation; the copy it delivers holds no pin, page or
-- reader.
module Hetoimasia.Terrain.Runtime.Backed.Regional
  ( Build
  , startBuild
  , startBuildWith
  , stepBuild
  , cancelBuild
  , endBuild
  , buildDraining
  , buildVersion
  , buildRegionsDone
  , buildCopies
  , settledCopy
  , BProgress (..)
  ) where

import Control.Concurrent.STM (STM)
import Control.Exception (evaluate)
import Data.ByteString.Short (ShortByteString)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Terrain.Cell (Column)
import Hetoimasia.Terrain.Changes (Replacement (..), replacementRunsMeetingLevels)
import Hetoimasia.Terrain.Coordinate (RegionCoord, TileCoord)
import qualified Hetoimasia.Terrain.Discovery as D
import Hetoimasia.Terrain.Runtime.Backed.Backend (Closing, Handling (..))
import Hetoimasia.Terrain.Runtime.Backed.Gather (GProgress (..), Gather, GatherRefusal (..), GatherRun, cancelGather, gatherFetching, gatherOnPin, gatherPinLimit, gatherWindow, stepGather)
import Hetoimasia.Terrain.Runtime.Backed.Query (QProgress (..), Query, cancelQuery, queryFetching, queryOnPin, queryWindow, stepQuery)
import Hetoimasia.Terrain.Runtime.Backed.RegionCopy (RegionCopy (..), RegionWork (..), packKnowledge, packTerrain)
import Hetoimasia.Terrain.Runtime.Backed.Txn (Io)
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types (BusyReason)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageNo)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model (Condition (..), ReaderToken, Store, acquireReader, readerVersion, readerWindow, releaseReader)
import Hetoimasia.Terrain.Runtime.Store.Internal.Tree (Window)

-- | A regional build's continuation.
data Build = Build
  { bToken ∷ !ReaderToken
  , bVersion ∷ !Word64
  , bEnv ∷ !D.Env
  , bTodo ∷ ![RegionCoord]
  , bUnit ∷ !Unit
  , bDone ∷ ![(RegionCoord, RegionCopy)]
  -- ^ The regions copied so far, newest first, each evaluated in full ('settledCopy').
  , bRefused ∷ !(Map PageNo Condition)
  -- ^ Pages this build failed to read, with their cause.
  , bDraining ∷ !Bool
  , bPin ∷ !Int
  -- ^ The pages one read of the build may pin: 'gatherPinLimit' in production.
  }

-- | The read a build is in. The window the build reads through is held in exactly one place: the read in
-- progress, or ('Idle') the evaluation step about to start the next read; 'Between' holds none.
data Unit
  = Between
  | -- | A region's own columns.
    OwnRuns !RegionCoord !Gather
  | -- | The columns beside a region, with its own columns' runs.
    HaloRuns !RegionCoord ![GatherRun] !Gather
  | -- | A region's knowledge: its packed terrain, its plan, the tiles still to evaluate, the answers so
    -- far (newest first) and the evaluation in progress or the window the next one starts from.
    Evaluate !RegionCoord !ShortByteString !Int !Int !D.KnowledgePlan ![TileCoord] ![D.CellKnowledge] !Step

-- | Where a region's evaluation is: between two evaluations (holding the window the next starts from), or
-- in one (whose query owns the window).
data Step
  = Idle !Window
  | Running !(Query D.CellKnowledge)

-- | Where a step left the build.
data BProgress
  = -- | Step again (after serving whatever else the owner has to do).
    BMore
  | -- | A page failed: the parts that needed it are unavailable. The owner records the failure as it
    -- records any failed read's, and steps again.
    BNoted !Handling
  | -- | Wait for this (one read job), then step again.
    BBlocked !(STM ())
  | -- | Temporary pressure: the interrupted read starts again once the storage service or the edit bank
    -- has changed.
    BPressed !BusyReason
  | -- | Every region, ascending. The pin is still held: 'endBuild'.
    BDone ![(RegionCoord, RegionCopy)]
  | -- | A closure or a defect. The pin is still held: 'endBuild'.
    BFailed !Handling
  | -- | Cancelled and drained: nothing of the backend is held for it. The pin is still held: 'endBuild'.
    BDrained

-- | Pin the committed version and begin building the regions.
startBuild ∷ Store → D.Env → [RegionCoord] → Either GatherRefusal (Store, Build)
startBuild = startBuildWith gatherPinLimit

-- | The same with the pages one read may pin given: a build on a small store, or one whose reads must start afresh, can be
-- made with fewer than the reader's credit. The production bound is 'gatherPinLimit'.
startBuildWith ∷ Int → Store → D.Env → [RegionCoord] → Either GatherRefusal (Store, Build)
startBuildWith pin store env regions = case acquireReader store of
  Left refusal → Left (NoPin refusal)
  Right (token, pinned) → case (readerWindow pinned token, readerVersion pinned token) of
    (Right _, Right version) → Right (pinned, Build token version env regions Between [] Map.empty False pin)
    _ → Left PinRefused

-- | Release the build's pin (releasing twice changes nothing). Called once no read of it is in flight.
endBuild ∷ Store → Build → Store
endBuild store b = snd (releaseReader (bToken b) store)

buildDraining ∷ Build → Bool
buildDraining = bDraining

-- | The committed version the build pinned.
buildVersion ∷ Build → Word64
buildVersion = bVersion

-- | How many regions the build has finished.
buildRegionsDone ∷ Build → Int
buildRegionsDone = length . bDone

-- | The regions the build has finished, newest first (for verification: each is evaluated in full).
buildCopies ∷ Build → [(RegionCoord, RegionCopy)]
buildCopies = bDone

-- | A copy evaluated in full: its packed parts and its work counters, so it keeps nothing of the build that
-- made it (a part left unevaluated would keep its region's reads, plan and answers).
settledCopy ∷ RegionCopy → RegionCopy
settledCopy c@(RegionCopy terrain knowledge work) = part terrain `seq` part knowledge `seq` work `seq` c
  where
    part = maybe () (`seq` ())

-- | The most steps that need no wait one call of 'stepBuild' takes: a quantum is bounded by this many
-- ranged reads or evaluations, and ends early at any wait.
stepsPerQuantum ∷ Int
stepsPerQuantum = 16

-- | Take one bounded quantum of the build: at most 'stepsPerQuantum' steps, ending at any wait and when a
-- region is finished (a quantum never spans two regions). The owner calls it masked.
stepBuild ∷ Io → Closing → Store → Build → IO (Build, BProgress)
stepBuild io closing store = go stepsPerQuantum
  where
    go n b = do
      (b', p) ← stepOnce io closing store b
      case p of
        BMore | n > 1, length (bDone b') == length (bDone b) → go (n - 1) b'
        _ → pure (b', p)

-- | One step: one ranged read, one evaluation, or a transition between them.
stepOnce ∷ Io → Closing → Store → Build → IO (Build, BProgress)
stepOnce io closing store b = case bUnit b of
  Between → case bTodo b of
    [] → pure (b, BDone (reverse (bDone b)))
    -- EACH REGION STARTS FROM A FRESH WINDOW ON THE SAME PIN: what one region kept is dropped, so the
    -- window never holds more than one reader may pin whatever the build spans, and every window reads
    -- the one version the build pinned
    region : rest → case readerWindow store (bToken b) of
      Right fresh → region `seq` pure (b {bTodo = rest, bUnit = OwnRuns region (ownGatherOf b fresh region)}, BMore)
      Left why → pure (b, BFailed (HandleDefect (Text.pack ("a build's own pin was refused: " <> show why))))
  OwnRuns region g → do
    (g', p) ← stepGather io closing store g
    case p of
      GMore → pure (b {bUnit = OwnRuns region g'}, BMore)
      GBlocked wait → pure (b {bUnit = OwnRuns region g'}, BBlocked wait)
      -- the gather's window passes to the next read; the gather is dropped with its runs
      GDone own → pure (b {bUnit = HaloRuns region own (haloGather (gatherWindow g') region)}, BMore)
      GFailed handling → failed handling (gatherFetching g) (gatherWindow g') (RegionCopy Nothing Nothing (RegionWork 256 0 0 0 0 0)) region (\w → OwnRuns region (ownGatherOf b w region))
      GDrained → pure (b {bUnit = Between}, BDrained)
  HaloRuns region own g → do
    (g', p) ← stepGather io closing store g
    case p of
      GMore → pure (b {bUnit = HaloRuns region own g'}, BMore)
      GBlocked wait → pure (b {bUnit = HaloRuns region own g'}, BBlocked wait)
      GDone halo →
        let plan = D.planRegionKnowledge (bEnv b) region (runsByColumn (own <> halo))
            columns = 256 + length (D.regionHaloColumns region)
            terrain = packTerrain region own
         in terrain `seq`
              pure
                ( b {bUnit = Evaluate region terrain columns (length own + length halo) plan (D.planTiles plan) [] (Idle (gatherWindow g'))}
                , BMore
                )
      GFailed handling → failed handling (gatherFetching g) (gatherWindow g') (RegionCopy (Just (packTerrain region own)) Nothing (RegionWork (256 + length (D.regionHaloColumns region)) (length own) 0 0 0 0)) region (\w → HaloRuns region own (haloGather w region))
      GDrained → pure (b {bUnit = Between}, BDrained)
  Evaluate region terrain columns runs plan tiles answers step → case step of
    Idle window → case tiles of
      [] → case D.assembleRegionKnowledge plan (reverse answers) of
        Nothing → pure (b, BFailed (HandleDefect "a region's answers did not match its plan"))
        -- THE REGION'S END: its copy is evaluated in full before it is kept, and the window, the plan and
        -- the answers are dropped with the unit
        Just rk → do
          copy ← evaluate (settledCopy (RegionCopy (Just terrain) (Just (packKnowledge rk)) (workOf columns runs plan)))
          pure (b {bUnit = Between, bDone = (region, copy) : bDone b}, BMore)
      tile : _ → pure (b {bUnit = Evaluate region terrain columns runs plan tiles answers (Running (evaluation window tile))}, BMore)
    Running q → do
      (q', p) ← stepQuery io closing store q
      let continue = Evaluate region terrain columns runs plan tiles answers
      case p of
        QMore → pure (b {bUnit = continue (Running q')}, BMore)
        QBlocked wait → pure (b {bUnit = continue (Running q')}, BBlocked wait)
        QDone known → pure (b {bUnit = Evaluate region terrain columns runs plan (drop 1 tiles) (known : answers) (Idle (queryWindow q'))}, BMore)
        QFailed handling →
          let restart w = continue (maybe (Idle w) (Running . evaluation w) (take1 tiles))
           in failed handling (queryFetching q) (queryWindow q') (RegionCopy (Just terrain) Nothing (workOf columns runs plan)) region restart
        QDrained → pure (b {bUnit = Between}, BDrained)
  where
    -- what a read of these columns can keep: the runs the region's levels and one beyond each end hold
    keep columns = columns * replacementRunsMeetingLevels (34 ∷ Int)
    haloGather window region = let cols = ranged region (D.regionHaloColumns region) in gatherOnPin (bPin b) (bToken b) (bVersion b) window (bRefused b) (keep (length cols)) cols
    ranged region columns = let (lo, hi) = D.regionReadLevels region in [(c, lo, hi) | c ← columns]
    evaluation window tile = queryOnPin (bPin b) (bToken b) (bVersion b) window (bRefused b) (\provider → D.queryCell (bEnv b) provider tile)
    take1 = \case
      t : _ → Just t
      [] → Nothing
    workOf columns runs plan = RegionWork columns runs (D.planClasses plan) (D.planPieces plan) (length (D.planTiles plan)) (D.planPerLevelTiles plan)
    -- A read of the region failed: unavailable parts and the page remembered; pressure keeps the read to
    -- start again from the failed read's window; anything else ends the build. The failed read is dropped
    -- either way, so only the restarted read holds a window.
    failed handling page window copy region restart = case handling of
      HandleRetryLater busy → pure (b {bUnit = restart window}, BPressed busy)
      HandlePause cause _ → unavailable cause
      HandlePausedFor cause → unavailable cause
      HandleDomain _ → unavailable CondIo
      other → pure (b, BFailed other)
      where
        unavailable cause = do
          settled ← evaluate (settledCopy copy)
          pure
            ( b
                { bUnit = Between
                , bDone = (region, settled) : bDone b
                , bRefused = maybe (bRefused b) (\p → Map.insert p cause (bRefused b)) page
                }
            , BNoted handling
            )

-- | The owner no longer wants the build (its request ended, its arena closed): a read in flight is
-- withdrawn if queued and stopped at its next safe point if running; nothing is released until it has
-- returned. Called masked, then again until 'BDrained'.
cancelBuild ∷ Io → Build → IO (Build, BProgress)
cancelBuild io b = case bUnit b of
  OwnRuns region g → onGather (OwnRuns region) =<< cancelGather io g
  HaloRuns region own g → onGather (HaloRuns region own) =<< cancelGather io g
  Evaluate region terrain columns runs plan tiles answers (Running q) → cancelQuery io q >>= \(q', p) → case p of
    QDrained → pure (b {bDraining = True, bUnit = Between}, BDrained)
    QBlocked wait → pure (b {bDraining = True, bUnit = Evaluate region terrain columns runs plan tiles answers (Running q')}, BBlocked wait)
    QFailed handling → pure (b {bDraining = True, bUnit = Between}, BFailed handling)
    _ → pure (b {bDraining = True, bUnit = Between}, BDrained)
  _ → pure (b {bDraining = True, bUnit = Between}, BDrained)
  where
    onGather unit (g', p) = case p of
      GDrained → pure (b {bDraining = True, bUnit = Between}, BDrained)
      GBlocked wait → pure (b {bDraining = True, bUnit = unit g'}, BBlocked wait)
      GFailed handling → pure (b {bDraining = True, bUnit = Between}, BFailed handling)
      _ → pure (b {bDraining = True, bUnit = Between}, BDrained)

-- | The read of a region's own columns, on the build's pin and from this window.
ownGatherOf ∷ Build → Window → RegionCoord → Gather
ownGatherOf b window region =
  let (lo, hi) = D.regionReadLevels region
      cols = [(c, lo, hi) | c ← D.regionColumns region]
   in gatherOnPin (bPin b) (bToken b) (bVersion b) window (bRefused b) (length cols * replacementRunsMeetingLevels (34 ∷ Int)) cols

-- | The runs of each column, air or mask, for a plan.
runsByColumn ∷ [GatherRun] → Map Column [(Int64, Int64, Replacement)]
runsByColumn runs = Map.map reverse (Map.fromListWith (<>) [(c, [(lo, hi, tag)]) | (c, lo, hi, tag) ← runs])
