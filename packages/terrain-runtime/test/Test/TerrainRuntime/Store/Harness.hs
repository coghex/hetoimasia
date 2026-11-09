-- | The driver of the store specs: a store, the disk its pages are written to, and
-- the loops an owner and its workers would run, with every measurement the evidence
-- reports.
--
-- Planning is the loop the contract describes: plan through a window; on a pending
-- page fetch it from the disk and plan again from the same window. A transaction is
-- then admitted, every page dispatched and completed (or failed, per the test) and,
-- when eligible, published.
module Test.TerrainRuntime.Store.Harness
  ( -- * The harness
    H (..)
  , Maxes (..)
  , newH
  , specOf
  , smallSpec
  , identOf
  , ident0
  , uncheckedWindow

    -- * Planning
  , fillPlan
  , fillWith
  , deltaFor
  , Outcome (..)
  , commitDelta
  , commitPlan
  , runPlanned
  , reclaimAll
  , reclaimAllWithin
  , checkH

    -- * Records
  , readAll
  , allRecords
  , storeRecords
  , compareRecords

    -- * Keys
  , runKey
  , runRec
  , linkKey
  , childRec
  , rootRec
  , todoKey
  , todoRec
  , tileAt
  , columnAt
  , srcNode
  ) where

import Control.Monad (foldM)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Word (Word64, Word8)
import Hetoimasia.Terrain.Cell (Column, mkColumn)
import Hetoimasia.Terrain.Connectivity (mkComponentKey)
import Hetoimasia.Terrain.Coordinate (TileCoord, tileCoord)
import Hetoimasia.Terrain.Discovery
  ( Authority (..)
  , Header (..)
  , Node (..)
  , Record (..)
  , RecordKey (..)
  , Root (..)
  , Todo (..)
  )
import Hetoimasia.Terrain.Residency (ArenaId (..), Revision (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.State
import Hetoimasia.Terrain.Runtime.Store.Internal.Tree
import Test.TerrainRuntime.Store.Reference

-- | The bounds observed over a run: the evidence the specs report.
data Maxes = Maxes
  { mxPages ∷ !Int
  , mxRam ∷ !Int
  , mxSteps ∷ !Int
  , mxWindow ∷ !Int
  , mxClaim ∷ !Int
  , mxPlans ∷ !Int
  , mxWrites ∷ !Int
  , mxFreed ∷ !Int
  }
  deriving stock (Eq, Show)

-- | A store and its disk.
data H = H
  { hStore ∷ !Store
  , hDisk ∷ !Disk
  , hCfg ∷ !StoreConfig
  , hIdent ∷ !StoreIdentity
  , hMaxes ∷ !Maxes
  }

ident0 ∷ StoreIdentity
ident0 = identOf 1 7

identOf ∷ Word64 → Word64 → StoreIdentity
identOf a s = StoreIdentity (ArenaId a) s

-- | The default 64 MiB specification with a given overhead, so a test reaches a
-- small usable page space through a checked configuration.
specOf ∷ Integer → Maybe Integer → StoreSpec
specOf bytes overhead = StoreSpec bytes overhead (toInteger defaultOffsetLimit)

-- | The smallest allowance, 64 MiB, with the default overhead.
smallSpec ∷ StoreSpec
smallSpec = specOf (64 * 1024 * 1024) Nothing

newH ∷ StoreSpec → StoreIdentity → H
newH spec ident = case mkStoreConfig spec of
  Left e → error ("store configuration refused: " <> show e)
  Right cfg → H (newStore cfg ident) emptyDisk cfg ident (Maxes 0 0 0 0 0 0 0 0)

-- | Plan through a window filled from the disk, fetching each pending page. It
-- returns the outcome, the window and the pages fetched.
fillWith ∷ H → (Window → Planned) → Either String (Planned, Window, Int)
fillWith h f = go (storeWindow (hStore h)) 0
  where
    total = cfgUsablePages (hCfg h)
    go w n
      | n > 1500 = Left "planning did not settle: too many pending pages"
      | otherwise = case f w of
      Pending p → case diskRead (hDisk h) p of
        Nothing → Left ("pending page not on disk: " <> show p)
        Just bs → case windowInsert total p bs w of
          Left e → Left ("page " <> show p <> " refused: " <> show e)
          Right w' → go w' (n + 1 ∷ Int)
      -- a page the plan only has to classify: a page never written is nothing
      PendingProbes ps → go (foldl (\w' p → windowProbe total p (maybe BS.empty id (diskRead (hDisk h) p)) w') w ps) (n + 1 ∷ Int)
      other → Right (other, w, n)

fillPlan ∷ H → Delta → TxClass → Either String Planned
fillPlan h d cls = (\(p, _, _) → p) <$> fillWith h (\w → planDeltaPinned standardBounds (hCfg h) (hIdent h) (storeRoots (hStore h)) (pinnedRoots (hStore h)) w cls d)

-- | A delta over the committed header: the next header advances the store revision
-- (and the content and knowledge revisions as the flags say), as #661 does.
deltaFor ∷ Store → Bool → Bool → Int → [(RecordKey, Maybe Record)] → Delta
deltaFor s terrain knowledge updates ws =
  let hdr = storeHeader s
      Authority a (Revision c) (Revision k) (Revision st) = hAuthority hdr
      next = hdr {hAuthority = Authority a (Revision (if terrain then c + 1 else c)) (Revision (if knowledge then k + 1 else k)) (Revision (st + 1))}
   in Delta (hAuthority hdr) next terrain knowledge updates ws

-- | What one transaction did.
data Outcome
  = Committed Plan
  | Nothing'
  | Refusal' PlanRefusal
  deriving stock (Eq, Show)

-- | Admit, write every page and publish: the whole happy path.
commitPlan ∷ H → Plan → Either String H
commitPlan h plan = do
  (tid, s1) ← either (Left . ("admit: " <>) . show) Right (admit plan (hStore h))
  let go (s, d) (p, bs) = do
        let (r1, sa) = dispatchWrite tid p s
        if r1 /= Applied then Left ("dispatch " <> show p) else Right ()
        let (r2, sb) = completeWrite tid p WriteDone sa
        if r2 /= Applied then Left ("complete " <> show p) else Right ()
        Right (sb, diskWrite p bs d)
  (s2, d2) ← foldM go (s1, hDisk h) (plPages plan)
  (_, s3) ← either (Left . ("publish: " <>) . show) Right (publish tid s2)
  let m = plMeasure plan
      mx = hMaxes h
      mx' =
        mx
          { mxPages = max (mxPages mx) (mPagesWritten m)
          , mxRam = max (mxRam mx) (ramTotal (mRam m))
          , mxSteps = max (mxSteps mx) (mReadSteps m)
          , mxWindow = max (mxWindow mx) (mWindowPages m)
          , mxClaim = max (mxClaim mx) (mClaimed m)
          , mxPlans = mxPlans mx + 1
          , mxWrites = mxWrites mx + mPagesWritten m
          , mxFreed = mxFreed mx + mFreed m
          }
  Right h {hStore = s3, hDisk = d2, hMaxes = mx'}

-- | Plan a delta, and commit it when it is planned.
commitDelta ∷ H → TxClass → Delta → Either String (H, Outcome)
commitDelta h cls d = do
  p ← fillPlan h d cls
  runPlanned h p

runPlanned ∷ H → Planned → Either String (H, Outcome)
runPlanned h p = case p of
  Planned plan → (\h' → (h', Committed plan)) <$> commitPlan h plan
  NoWork → Right (h, Nothing')
  Refused r → Right (h, Refusal' r)
  BlockedByReader a b → Left ("blocked by reader " <> show (a, b))
  Pending q → Left ("unfilled pending " <> show q)
  PendingProbes q → Left ("unfilled probes " <> show q)

-- | Reclaim until nothing more can be reclaimed, returning the number of
-- transactions. Stops on a block by a reader or a refusal.
reclaimAll ∷ H → Either String (H, Int)
reclaimAll = reclaimAllWithin 400

-- | 'reclaimAll' allowing a given number of transactions (a large store needs several hundred).
reclaimAllWithin ∷ Int → H → Either String (H, Int)
reclaimAllWithin limit = go 0
  where
    go n h
      | n > limit = Left ("reclamation did not terminate: retired " <> show (usRetiredBytes (usage (hStore h))) <> " free " <> show (rFreePages (storeRoots (hStore h))) <> " loose " <> show (length (rLoose (storeRoots (hStore h)))) <> " version " <> show (storeVersion (hStore h)))
      | otherwise = do
          (p, _, _) ← fillWith h (planMaintenance (hStore h))
          case p of
            Planned plan → commitPlan h plan >>= \h' → go (n + 1) h'
            NoWork → Right (h, n)
            BlockedByReader {} → Right (h, n)
            Refused r → Left ("reclaim refused: " <> show r)
            Pending _ → Left "pending after fill"
            PendingProbes _ → Left "pending probes after fill"

-- | The independent checks of the committed store against the disk: the partition,
-- the counters and every tree's structure.
checkH ∷ H → Either String ()
checkH h = case owViolations o of
  [] → Right ()
  vs → Left (unlines (take 8 vs))
  where
    ArenaId a = siArena (hIdent h)
    o = ownership a (siSource (hIdent h)) (hStore h) (diskRead (hDisk h))

-- ---------------------------------------------------------------------------
-- Records

-- | Every record the committed store holds, read through the production reader
-- (bounded ranged reads) after filling the window from the disk.
storeRecords ∷ H → Either String [(RecordKey, Record)]
storeRecords h = concat <$> mapM one [(TreeRuns, minRun), (TreeLinks, minLink), (TreeTodo, KeyTodo 0)]
  where
    s = hStore h
    total = cfgUsablePages (hCfg h)
    one (tree, start) = loop emptyW tree (RangeFrom start) []
    emptyW = storeWindow s
    loop w tree start acc = case rangeRecordsAt s w tree start of
      Left (Need p) → case diskRead (hDisk h) p of
        Nothing → Left ("page " <> show p <> " missing")
        Just bs → either (Left . show) (\w' → loop w' tree start acc) (windowInsert total p bs w)
      Left e → Left (show e)
      Right [] → Right acc
      Right rs →
        let acc' = acc ++ rs
            (lastKey, _) = last rs
         in if length rs < 256 then Right acc' else loop w tree (RangeAfter lastKey) acc'
    minRun = KeyRun (columnAt (-(2 ^ (62 ∷ Int))) (-(2 ^ (62 ∷ Int)))) minBound
    minLink = KeyLink (srcNode (-(2 ^ (62 ∷ Int))) (-(2 ^ (62 ∷ Int))) (-(2 ^ (62 ∷ Int))))
    rangeRecordsAt st w tree start = rangeRecords w (committedRoot st) tree start 256

allRecords ∷ H → Either String [(RecordKey, Record)]
allRecords = storeRecords

-- | The records the reference holds against those the store holds.
compareRecords ∷ [(RecordKey, Record)] → H → Either String ()
compareRecords expected h = do
  actual ← storeRecords h
  let e = Map.fromList expected
      a = Map.fromList actual
  if e == a
    then Right ()
    else
      Left
        ( "records differ: expected "
            <> show (Map.size e)
            <> ", store has "
            <> show (Map.size a)
            <> "; first difference "
            <> show (take 2 (Map.toList (Map.difference e a)), take 2 (Map.toList (Map.difference a e)), take 2 [(k, v, Map.lookup k a) | (k, v) ← Map.toList e, Map.lookup k a /= Just v])
        )


-- | Every record a reader sees, read through a fresh window and the disk only.
readAll ∷ H → ReaderToken → Either String [(RecordKey, Record)]
readAll h tok = concat <$> mapM one [(TreeRuns, minRun), (TreeLinks, minLink), (TreeTodo, KeyTodo 0)]
  where
    s = hStore h
    total = cfgUsablePages (hCfg h)
    minRun = KeyRun (columnAt (-(2 ^ (62 ∷ Int))) (-(2 ^ (62 ∷ Int)))) minBound
    minLink = KeyLink (srcNode (-(2 ^ (62 ∷ Int))) (-(2 ^ (62 ∷ Int))) (-(2 ^ (62 ∷ Int))))
    one (tree, start) = do
      w0 ← either (const (Left "stale reader")) Right (readerWindow s tok)
      loop w0 tree (RangeFrom start) []
    loop w tree start acc = case readerRange s tok w tree start 256 of
      Read [] → Right acc
      Read rs →
        let acc' = acc ++ rs
         in if length rs < 256 then Right acc' else loop w tree (RangeAfter (fst (last rs))) acc'
      ReadNeeds p → case diskRead (hDisk h) p of
        Nothing → Left ("page " <> show p <> " missing")
        Just bs → either (Left . show) (\w' → loop w' tree start acc) (windowInsert total p bs w)
      ReadCorrupt e → Left (show e)
      ReadStale → Left "stale reader"
      ReadWrongWindow w' → Left ("wrong window " <> show w')

-- ---------------------------------------------------------------------------
-- Keys

tileAt ∷ Integer → Integer → Integer → TileCoord
tileAt x y z = either (error . show) id (tileCoord x y z)

columnAt ∷ Integer → Integer → Column
columnAt x y = either (error . show) id (mkColumn x y)

runKey ∷ Integer → Integer → Integer → RecordKey
runKey x y lo = KeyRun (columnAt x y) (fromInteger lo)

runRec ∷ Integer → Record
runRec = RecRun . fromInteger

srcNode ∷ Integer → Integer → Integer → Node
srcNode x y z = SrcNode (maybe (error "key") id (mkComponentKey (tileAt x y z) []))

linkKey ∷ Node → RecordKey
linkKey = KeyLink

childRec ∷ Node → Record
childRec = RecChild

rootRec ∷ Word64 → Bool → Record
rootRec n k = RecRoot (Root n k)

todoKey ∷ Word64 → RecordKey
todoKey = KeyTodo

todoRec ∷ Integer → Integer → Integer → Word8 → Record
todoRec x y z d = RecTodo (Todo (tileAt x y z) d)

-- | A window over root sets a test builds by hand, which no root record or pin gives a checksum: the test-only
-- constructor that reads such roots unchecked. A production window refuses them ('RootChecksumMissing').
uncheckedWindow ∷ StoreIdentity → Word64 → Window
uncheckedWindow ident v = windowUnchecked (emptyWindow ident v)
