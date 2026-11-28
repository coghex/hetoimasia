{-# LANGUAGE PatternSynonyms #-}

-- | The copy-on-write B+tree over immutable pages: bounded reads through a window
-- of validated page buffers, and updates that never touch a committed page.
--
-- = The window
--
-- Every operation reads through a 'Window', a bounded set of validated page buffers
-- pages the caller has supplied. A page the operation needs and the window lacks
-- stops it with @'Need' page@: the pending result of a missing page, never an
-- empty index or an absent key. The caller fetches the page, adds it and runs the
-- operation again; the window is the continuation, so no work is lost and no
-- history-sized structure is retained. A page that fails its decode is never in
-- the window, and a page the tree reaches that contradicts its parent (a wrong
-- tree, a wrong level, a key outside the parent's separators) is refused with
-- 'Bad'.
--
-- = Structure
--
-- Leaves hold sorted key and value entries; an internal page holds sorted
-- separators, each the least key its child may hold, and child pages one level
-- lower. A key belongs to the last child whose separator is at most the key. The
-- root is the only node that may hold few entries. After a deletion every other
-- node that falls below a quarter of a payload ('minNodeBytes') is repacked with a
-- neighbour under the same parent, either merged into one page or split evenly
-- into two, so adjacent siblings never both fit one page and every non-root node
-- is at least a quarter full. An insertion that overflows splits a node by
-- bytes; a root that splits grows the tree by one level (refused beyond
-- 'maxLevel', never truncated) and a root left with one child gives its level back.
--
-- = Copy on write
--
-- An update copies each page it changes into an 'Edit' overlay and records the
-- committed page it replaces; a page already in the overlay is changed in place.
-- Nothing is numbered until the plan is finished: 'assignPages' gives the
-- reachable overlay pages their page numbers, children first, from the supply the
-- allocator chose, and 'freshPages' encodes them. An overlay page a later step
-- made unreachable costs nothing.
--
-- The worst cost of one update at height @h@ is @2h + 1@ new pages (a copy of the
-- path, a split at every level and a new root); a deletion copies the path and one
-- neighbour per level, at most @2h@.
--
-- State, ownership and lifetime: none beyond the values passed. An 'Edit' is the
-- working state of one plan and is discarded with it.
module Hetoimasia.Terrain.Runtime.Store.Internal.Tree
  ( -- * Window
    Window
  , Probe (..)
  , emptyWindow
  , windowBelow
  , windowTrust
  , Fact (..)
  , Fingerprint (..)
  , Facts (..)
  , PackedReads (..)
  , packReads
  , factsOf
  , packedReadsBytes
  , packedReadsFresh
  , packedFactBytes
  , fingerprintBytes
  , factsRetainedBytes
  , recordFact
  , carryFacts
  , windowMemoBytes
  , editHeldFacts
  , editHeldFactBytes
  , editHeldMemoBytes
  , memoListCellBytes
  , withMemoCap
  , edgeFact
  , useMemo
  , useMemoM
  , recordProof
  , editFacts
  , factBytes
  , factBytesOf
  , memoBaseBytes
  , memoBoundBytes
  , windowCheckpoint
  , windowFactsFor
  , noReadFacts
  , windowReadRecord
  , windowReadFloor
  , windowReadFactCount
  , windowReadFactBytes
  , recordFactBytes
  , readFactOverheadBytes
  , windowKnows
  , windowFactCount
  , limitWork
  , reduceWork
  , windowWork
  , windowWorkAtLeast
  , windowUnchecked
  , pageCrcOf
  , windowInsert
  , windowProbe
  , windowProbeOf
  , windowProbeBytes
  , windowProbesBytes
  , windowProbeCount
  , windowSize
  , windowVersion
  , windowIdentity
  , windowBytes
  , windowPageOverhead
  , windowPageNumbers
  , windowMember
  , windowPage

    -- * Plans
  , Stop (..)
  , M
  , runM
  , runMKeep
  , Edit
  , newEdit
  , editSteps
  , editReplaced
  , editWindow
  , editFreshBytes
  , overlayNodeBytes
  , windowPayloadBytes
  , packParsedNode
  , packedBytes
  , parsedNode
  , parsedNodeWeight
  , storedPayload
  , Stored
  , hotNodes
  , hotNodeBytes
  , Ref (.., Disk)
  , liftStop
  , failInvariant

    -- * Reads
  , lookupKey
  , lookupKeyWith
  , livePageAt
  , floorKey
  , floorKeyWith
  , ceilKey
  , ceilKeyWith
  , rangeKeys

    -- * Updates
  , insertKey
  , insertAbsentKey
  , deleteKey

    -- * Finishing
  , freshCount
  , assignPages
  , worstUpdatePages
  , splitEven

    -- * Exposed for the suite
  , exitProbe
  , ProbeSpec (..)
  , buildProbe
  , shapeViolations
  , exitRootProbe
  , editDeleteSplits
  , treeHeight
  , getEditProbe
  , editPackedPayload
  ) where

import Data.ByteString (ByteString)
import Data.ByteString.Short (ShortByteString, fromShort, toShort)
import qualified Data.ByteString.Short as SBS
import qualified Data.ByteString as BS
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Int (Int64)
import Data.Word (Word32, Word64)
import Hetoimasia.Terrain.Cell (Column)
import Hetoimasia.Terrain.Changes (Replacement (..))
import Hetoimasia.Terrain.Discovery (ReadSet (..), Record, RecordKey (..))
import Hetoimasia.Terrain.Residency (ArenaId (..))
import Hetoimasia.Terrain.Shape (cornerMaskValue, mkCornerMask)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Page
import Hetoimasia.Terrain.Runtime.Store.Internal.Records (be64, decodeValue, encodeKey, encodeValue, getBe64, getLe32)

-- ---------------------------------------------------------------------------
-- Window

-- | A validated page buffer a window keeps: the 4 KiB buffer and what a lookup needs
-- to place it. The entries are parsed from the buffer when a node is visited, so the
-- window's memory is the pages and not a pointer structure around each of them.
data VPage = VPage
  { vpTree ∷ !TreeId
  , vpLevel ∷ !Int
  , vpBytes ∷ !ByteString
  }
  deriving stock (Eq, Show)

-- | What a page that was read only to be classified is: nothing a store could reach
-- (it does not decode as a page of this store at that number), a tree page with the
-- first key it holds, or a retirement list with the version of its entry. A probe is
-- a few bytes, never the 4 KiB buffer.
data Probe
  = ProbeNone
  | ProbeTree !TreeId !Int !ShortByteString
  | ProbeList !Word64
  deriving stock (Eq, Show)

-- | Validated pages the caller has supplied, for one store and one version of it. A
-- window is the continuation of one plan or read; it is bound to the arena and source
-- it was made for (a page of another store is refused on insertion and a plan or read
-- through a window of another store or version is refused) and it is never carried
-- across a published version, because a page number may then name other content.
--
-- It also holds the probes of pages a plan only had to classify (a page it was about
-- to overwrite or free), and the used page space of the version it serves: a page at
-- or past it has never been numbered, so no tree may reach one.
data Window = Window
  { wIdent ∷ !StoreIdentity
  , wVersion ∷ !Word64
  , wPages ∷ !(Map PageNo VPage)
  , wProbes ∷ !(Map PageNo Probe)
  , wBelow ∷ !Word64
  , wUnchecked ∷ !Bool
  -- ^ Test-only: roots with no recorded checksum are read unchecked. No production path sets it.
  , wRoots ∷ !(Map PageNo Word32)
  -- ^ The checksum each root page must carry, by page number, as the root record publishes it.
  , wFacts ∷ !(Maybe Fingerprint)
  -- ^ What the facts of 'wProven' were proven against; facts of any other state are not trusted.
  , wProven ∷ !(Set Fact)
  -- ^ Read-only facts established by earlier plans through windows of this version, carried through a
  -- 'windowCheckpoint' (see 'Facts').
  , wWork ∷ !Int
  -- ^ The most units of work a plan through this window may take on (the pages one maintenance
  -- transaction frees, the writes of one discovery batch): the caller's bounded retry, see 'limitWork'.
  , wReadRecords ∷ !(Map ShortByteString ShortByteString)
  -- ^ The records the committed roots answered an earlier run of THIS plan, carried through a 'windowCheckpoint' like the
  -- proofs (see 'Facts'): trusted only for the fingerprint they were read against.
  , wReadFloors ∷ !(Map ShortByteString ShortByteString)
  -- ^ The floor-run answers of the same reads.
  }
  deriving stock (Eq, Show)

-- | An empty window for a store and a version.
emptyWindow ∷ StoreIdentity → Word64 → Window
emptyWindow ident v = Window ident v Map.empty Map.empty maxBound False Map.empty Nothing Set.empty maxBound Map.empty Map.empty

-- | The window of a version whose used page space is the first @n@ pages: a
-- reference to a page at or past @n@ is refused, never read.
windowBelow ∷ Word64 → Window → Window
windowBelow n w = w {wBelow = n}

-- | The window of a root set whose root pages carry given checksums: a root page is loaded only
-- if it carries the checksum the root record published for it, as a child is loaded only if it
-- carries the checksum its parent recorded. A root set made by hand has none and is read unchecked.
windowTrust ∷ [(PageNo, Word32)] → Window → Window
windowTrust cs w = w {wRoots = Map.fromList cs}

-- | TEST-ONLY. A window that reads a root whose checksum no record names unchecked, for the suites that build
-- root sets by hand. A production window fails closed: a root with no recorded checksum is refused with
-- 'RootChecksumMissing'. Nothing outside the test suites calls this; the public facade does not export it
-- and every window a store hands out is built by 'windowTrust' from a root record or a reader's pin.
windowUnchecked ∷ Window → Window
windowUnchecked w = w {wUnchecked = True}

-- | Limit the work a plan through this window takes on. The window is the only state a caller carries
-- between a plan and the next, so it is where a retry remembers that the larger unit of work did not
-- fit: when a plan answers a window that outgrew its bounds ('WindowExceeded', 'WindowBytesExceeded',
-- 'ProbesExceeded') the caller builds a fresh window for the same version with half of the work
-- ('windowWork', halved, never below one) and plans again. The limit counts units of the planner's own work and a planner
-- never does less than its atomic unit ('windowWorkAtLeast': one page for maintenance, the three writes of one connection
-- inspection for discovery), so a limit below that unit means the unit; the unit needs a bounded window, so the retry ends
-- in at most @log2 64@ steps with the work done.
limitWork ∷ Int → Window → Window
limitWork n w = w {wWork = max 1 n}

-- | The fresh window a retry continues with after a plan answered that the window @old@ outgrew its bounds:
-- the same work as @old@ allowed, halved (the largest unit of work is 64, a page or a write), never below
-- one. The caller builds @new@ for the same version, as for any plan.
reduceWork ∷ Window → Window → Window
reduceWork old new = limitWork (min 64 (wWork old) `div` 2) new

-- | The work a plan through this window may take on ('maxBound' for a window nobody limited).
windowWork ∷ Window → Int
windowWork = wWork

-- | The work a planner takes on through this window when its own smallest atomic unit is @unit@: a limit below the unit means the
-- unit, because a planner cannot do less than one of its atomic steps (a connection inspection stages three writes; asking for
-- one or two would make it refuse a valid store). Every planner that reads the work limit reads it through this.
windowWorkAtLeast ∷ Int → Window → Int
windowWorkAtLeast unit w = max unit (wWork w)

-- | A read-only fact about the committed and pinned state, established by a plan and remembered through a
-- retry: the proofs that a page a plan is about to overwrite or free is not owned by anyone but the
-- allocator ('FactUnreachable', 'FactNotRetired', 'FactNotFree'), that a page a retirement entry names is
-- a record page no root reaches ('FactRetirable'), and that a page the entry consumed is gone from the
-- retired-page index ('FactGone'). Each is a function of the committed roots, the pinned roots and the pages
-- of their trees and of nothing the plan stages: a lookup is made from a committed root ('Disk'), never from
-- the edit's own.
data Fact
  = FactUnreachable !PageNo
  | FactRetirable !PageNo
  | FactNotRetired !PageNo
  | FactNotFree !PageNo
  | FactGone !Word64 !PageNo
  | -- | The page number is absent from the retired-page index of the committed roots: the proof an edit makes for each page it retires
    -- before it inserts the number, so that the insertion (of a key known to be absent) reads no neighbour.
    FactNotIndexed !PageNo
  | -- | A reclamation chunk smaller than the work limit was taken because the larger one passed the memo budget: a checkpoint carries the work
    -- limit it reduced to, so the next call starts at that size and not again at the larger one.
    FactChunk !Int
  | -- | The progress of one 'FactUnreachable' or 'FactRetirable' proof: the page is not reachable from THIS root (the root's page).
    -- A proof against every committed and pinned root is a unit for each, so that the window holds one root's paths at a time;
    -- the units of a page are dropped when its proof is complete.
    FactOutOf !PageNo !PageNo
  | -- | A MEMO of an edit's lookup in the given tree: the chain of pages from this page (the root of a neighbouring subtree, with the checksum its parent
    -- records) to its extreme leaf on one side (@True@: the leftmost) was read and every key of every page lay inside the bounds and the
    -- level the descent gave it. Pages are immutable and the bounds are values, so the fact does not depend on the path that led
    -- there, a staged one included: the lookup that made it need not load the chain again, and a checkpoint carries it.
    FactEdge !TreeId !Bool !PageNo !Word32 !(Maybe ShortByteString) !(Maybe ShortByteString) !Int
  deriving stock (Eq, Ord, Show)

-- | The state a set of facts was proven against: the store, the version, the committed roots with the
-- checksums they carry and the pinned roots with their versions. A window trusts facts only for the very
-- state it plans against, so a reader acquired or released in between, or a window kept across a version,
-- costs a proof again and never skips one it should have made.
data Fingerprint = Fingerprint !StoreIdentity !Word64 ![(PageNo, Word32)] ![(Word64, [(PageNo, Word32)])]
  deriving stock (Eq, Show)

-- | The facts a plan established before its window filled up, with what they were proven against. OPAQUE
-- outside the store's own modules: a caller receives it in 'Hetoimasia.Terrain.Runtime.Store.Internal.Plan.Checkpoint'
-- and gives it to 'windowCheckpoint', and has no way to make or change one.
--
-- The read facts are carried PACKED, in the form the window holds them (see 'PackedReads'): they are packed when the facts are
-- CREATED ('factsOf'), so nothing typed leaves the planner and what the caller holds is what 'factsRetainedBytes' accounts.
data Facts = Facts !Fingerprint ![Fact] !PackedReads
  deriving stock (Eq, Show)

-- | The record and floor facts a plan read, as the bytes the pages hold: two maps from the encoded key to the encoded value (the
-- EMPTY value for an absent answer; a floor answer is its 17 bytes). The form a window holds them in.
data PackedReads = PackedReads !(Map ShortByteString ShortByteString) !(Map ShortByteString ShortByteString)
  deriving stock (Eq, Show)

-- | No read facts: what a proof checkpoint carries (it made proofs, not reads).
noReadFacts ∷ PackedReads
noReadFacts = PackedReads Map.empty Map.empty

-- | Pack what a plan read: the ONLY place the typed records of a read set are turned into facts.
packReads ∷ ReadSet → PackedReads
packReads (ReadSet rs fl) =
  PackedReads
    (Map.fromList [(packKey k, maybe SBS.empty (toShort . encodeValue) v) | (k, v) ← rs])
    (Map.fromList [(packKey (KeyRun c z), floorFact v) | ((c, z), v) ← fl])

-- | Facts made from what a plan established and read: the reads are packed here, at creation.
factsOf ∷ Fingerprint → [Fact] → ReadSet → Facts
factsOf fp fs rs = Facts fp fs (packReads rs)

-- | The accounted bytes of one packed read fact: its key and value bytes and the entry around them ('readFactOverheadBytes').
packedFactBytes ∷ ShortByteString → ShortByteString → Int
packedFactBytes k v = SBS.length k + SBS.length v + readFactOverheadBytes

-- | The accounted bytes of packed reads, counted from what is held.
packedReadsBytes ∷ PackedReads → Int
packedReadsBytes (PackedReads rs fl) = sum [packedFactBytes k v | m ← [rs, fl], (k, v) ← Map.toList m]

-- | How many of the packed reads the window does not carry yet, and their accounted bytes.
packedReadsFresh ∷ PackedReads → Window → (Int, Int)
packedReadsFresh (PackedReads rs fl) w =
  let new = [packedFactBytes k v | (k, v) ← Map.toList rs, not (Map.member k (wReadRecords w))] <> [packedFactBytes k v | (k, v) ← Map.toList fl, not (Map.member k (wReadFloors w))]
   in (length new, sum new)

-- | What the accounted fingerprint of a facts value is: the store identity, the version, five root checksums and up to
-- 'maxReaders' pinned versions of three roots each. MEASURED (the suite's @Memory@ regression): 7,285 bytes at the worst; held to 8,192.
fingerprintBytes ∷ Int
fingerprintBytes = 8192

-- | The RAM a facts value holds (what the caller keeps between a 'Checkpoint' and 'windowCheckpoint'): the fingerprint, every proof
-- fact and every packed read fact, counted from what is held. The ceiling on the reads a plan carries ('maxReadFactBytes') is
-- checked against this form.
factsRetainedBytes ∷ Facts → Int
factsRetainedBytes (Facts _ fs pr) = fingerprintBytes + sum (map factBytesOf fs) + packedReadsBytes pr

-- | The accounted bytes of one remembered record fact: its key, its value and the entry around them. A fact is held in the
-- plan's RAM (as a retained continuation), never in the window's page bytes.
recordFactBytes ∷ Int
recordFactBytes = maxKeyBytes + maxValueBytes + readFactOverheadBytes

-- | What one packed fact costs beyond its key and value bytes: a map node and two byte-array headers with their padding. MEASURED
-- (forced live heap, the suite's @Memory@ regression): at most 100 bytes; held to 128.
readFactOverheadBytes ∷ Int
readFactOverheadBytes = 128

-- | The accounted bytes of one remembered fact.
factBytes ∷ Int
factBytes = 80

-- | The accounted bytes of one fact: 'factBytes', and for a memo of a chain ('FactEdge') what it holds: 112 bytes (the constructor, its
-- set node and the margin the suite measures it under) and each bound it carries, a @Just@, a byte string and its array (48 bytes)
-- and the bytes of the key rounded to a word.
factBytesOf ∷ Fact → Int
factBytesOf (FactEdge _ _ _ _ lo hi _) = memoBaseBytes + boundBytes lo + boundBytes hi
factBytesOf _ = factBytes

-- | The accounted bytes of a memo that holds no bound, and of one bound of a key of the given length.
memoBaseBytes ∷ Int
memoBaseBytes = 112

boundBytes ∷ Maybe ShortByteString → Int
boundBytes = maybe 0 (\b → memoBoundBytes (SBS.length b))

-- | The accounted bytes of a bound of a key of the given length.
memoBoundBytes ∷ Int → Int
memoBoundBytes len = 48 + 8 * ((len + 7) `div` 8)

-- | The window of a retry after a plan filled its window while proving: a fresh window for the same store,
-- version, trust, work and used space, holding none of the pages or probes of the old one and the facts the
-- plan established (added to those it already had when they were proven against the same state).
windowCheckpoint ∷ Facts → Window → Window
windowCheckpoint (Facts fp fs (PackedReads rs fl)) w =
  let same = wFacts w == Just fp
      -- I2: a checkpoint that REDUCES the work (it carries the smaller limit, 'FactChunk') releases all the state of the batch it abandons: the memos,
      -- the proofs and the packed reads its window held, keeping only what the smaller batch is funded for, which is nothing yet. Any other
      -- checkpoint hands on the memos the plan made or used (those it did not touch are released here) and keeps its proofs and reads.
      reduces = same && not (null [() | FactChunk _ ← fs])
      kept = if same && not reduces then Set.filter (not . isMemo) (wProven w) else Set.empty
      keptR = if same && not reduces then wReadRecords w else Map.empty
      keptF = if same && not reduces then wReadFloors w else Map.empty
   in w
        { wPages = Map.empty
        , wProbes = Map.empty
        , wFacts = Just fp
        , wProven = settled (Set.union kept (Set.fromList fs))
        , wWork = foldr (\f acc → case f of FactChunk n → min n acc; _ → acc) (wWork w) fs
        , wReadRecords = Map.union rs keptR
        , wReadFloors = Map.union fl keptF
        }

-- | The facts without the progress of a proof that is complete: a 'FactOutOf' of a page whose 'FactUnreachable' or 'FactRetirable'
-- is known says nothing more. What stays is the progress of the proof a checkpoint interrupted, at most one page's.
settled ∷ Set Fact → Set Fact
settled fs = Set.filter live fs
  where
    live (FactOutOf pg _) = not (Set.member (FactUnreachable pg) fs || Set.member (FactRetirable pg) fs)
    live _ = True

-- | The window, with the facts it carries kept only if they were proven against this state.
windowFactsFor ∷ Fingerprint → Window → Window
windowFactsFor fp w = if wFacts w == Just fp then w else w {wFacts = Nothing, wProven = Set.empty, wReadRecords = Map.empty, wReadFloors = Map.empty}

-- | Whether the window carries a fact (after 'windowFactsFor').
windowKnows ∷ Fact → Window → Bool
windowKnows f w = Set.member f (wProven w)

-- | The facts a window carries.
windowFactCount ∷ Window → Int
windowFactCount = Set.size . wProven

-- | What the committed roots answered for a key, if the window carries it ('Nothing': not known; @Just Nothing@: absent).
windowReadRecord ∷ RecordKey → Window → Maybe (Maybe Record)
windowReadRecord k w = case Map.lookup (packKey k) (wReadRecords w) of
  Nothing → Nothing
  Just v
    | SBS.null v → Just Nothing
    | otherwise → case decodeValue k (fromShort v) of
        Nothing → Nothing
        Just r → Just (Just r)

-- | The same for a floor-run query.
windowReadFloor ∷ (Column, Int64) → Window → Maybe (Maybe (Int64, Int64, Replacement))
windowReadFloor (c, z) w = case Map.lookup (packKey (KeyRun c z)) (wReadFloors w) of
  Nothing → Nothing
  Just v
    | SBS.null v → Just Nothing
    | otherwise → Just <$> unpackRun v

-- | How many record and floor facts the window carries.
windowReadFactCount ∷ Window → Int
windowReadFactCount w = Map.size (wReadRecords w) + Map.size (wReadFloors w)

-- | The RAM the read facts of the window hold: the bytes of every packed key and value plus the entry around them
-- ('readFactOverheadBytes'), counted from what is held.
windowReadFactBytes ∷ Window → Int
windowReadFactBytes w = sum [SBS.length k + SBS.length v + readFactOverheadBytes | m ← [wReadRecords w, wReadFloors w], (k, v) ← Map.toList m]

-- | A read fact is held PACKED, as the bytes the pages hold: its key and value as two compact, unpinned byte arrays in a map, never
-- as the decoded Haskell values (a source node key and child are hundreds of bytes of constructors and thunks). A floor query is
-- keyed as a run key and holds the run's two ends and its payload.
--
-- An ABSENT answer (no such record, no such run) is held as the EMPTY value, so it is load-bearing that a PRESENT one never is: every
-- 'encodeValue' case is at least one byte (a run's 8, a root's 10, a child's tag, a todo's tile and counter) and a floor answer is
-- always its 17 bytes. The suite pins this over every 'Record' constructor at its edges and through the window itself
-- (@Codec@: \"a present record never encodes to an empty value\").
packKey ∷ RecordKey → ShortByteString
packKey = toShort . encodeKey

-- | The packed fact of a floor answer: the empty value for none, else the run's two ends and its payload byte (0 for air, the
-- mask for a mask run, which is never 0).
floorFact ∷ Maybe (Int64, Int64, Replacement) → ShortByteString
floorFact Nothing = SBS.empty
floorFact (Just (lo, hi, tag)) = packRun (lo, hi, tag)

packRun ∷ (Int64, Int64, Replacement) → ShortByteString
packRun (lo, hi, tag) = toShort (BS.concat [be64 (fromIntegral lo), be64 (fromIntegral hi), BS.singleton (payloadByte tag)])
  where
    payloadByte ReplaceAir = 0
    payloadByte (ReplaceMask mask) = fromIntegral (cornerMaskValue mask)

-- | The run a packed floor answer holds, if its bytes are well formed.
unpackRun ∷ ShortByteString → Maybe (Int64, Int64, Replacement)
unpackRun v
  | BS.length b /= 17 = Nothing
  | BS.index b 16 == 0 = Just (lo, hi, ReplaceAir)
  | Right mask ← mkCornerMask (fromIntegral (BS.index b 16)) = Just (lo, hi, ReplaceMask mask)
  | otherwise = Nothing
  where
    b = fromShort v
    lo = fromIntegral (getBe64 b 0)
    hi = fromIntegral (getBe64 b 8)

-- | The version the window was filled for.
windowVersion ∷ Window → Word64
windowVersion = wVersion

-- | The store the window was made for.
windowIdentity ∷ Window → StoreIdentity
windowIdentity = wIdent

-- | The accounted bytes a window holds: each page's 4 KiB buffer and the map entry
-- and headers around it ('windowPageOverhead').
windowBytes ∷ Window → Int
windowBytes w = Map.size (wPages w) * (pageSize + windowPageOverhead)

-- | The accounted bytes of the probes a window holds, 'probeBytes' each.
windowProbesBytes ∷ Window → Int
windowProbesBytes w = Map.size (wProbes w) * probeBytes

windowProbeBytes ∷ Window → Int
windowProbeBytes w = Map.size (wProbes w) * probeBytes + sum (map factBytesOf (Set.toList (wProven w)))

-- | Decode a page read for a page number against the window's store and add it. A page
-- that fails any check is refused and the window is unchanged. The window keeps its own
-- copy of the buffer: a caller's buffer may be a slice of something far larger (a read of
-- many pages), and what a window retains must be exactly the 4 KiB it accounts.
windowInsert ∷ Word64 → PageNo → ByteString → Window → Either PageError Window
windowInsert total no bytes w = do
  page ← decodePage (wIdent w) total no bytes
  Right w {wPages = Map.insert no (VPage (pgTree page) (pgLevel page) (BS.copy bytes)) (wPages w)}

-- | Classify a page read for a page number and keep only the classification. A page
-- that does not decode as a page of this store at that number is 'ProbeNone': nothing
-- reaches it, so nothing is lost by overwriting or freeing it. This never refuses. The
-- key a probe keeps is copied out of the page buffer: a slice of the 4 KiB input would
-- keep all of it alive behind a figure that accounts for a few dozen bytes.
windowProbe ∷ Word64 → PageNo → ByteString → Window → Window
windowProbe total no bytes w = w {wProbes = Map.insert no (detach probe) (wProbes w)}
  where
    probe = case decodePage (wIdent w) total no bytes of
      Left _ → ProbeNone
      Right page → probeOfPage page
    detach (ProbeTree t l k) = ProbeTree t l k
    detach other = other

probeOfPage ∷ Page → Probe
probeOfPage (Page tree level _ body) = case body of
  Leaf ((k, _) : _) → ProbeTree tree level (toShort k)
  Inner ((k, _) : _) → ProbeTree tree level (toShort k)
  List v _ → ProbeList v
  _ → ProbeNone

-- | The probes a window holds.
windowProbeCount ∷ Window → Int
windowProbeCount = Map.size . wProbes

-- | What a page is, if the window has it (as a full page or as a probe).
windowProbeOf ∷ PageNo → Window → Maybe Probe
windowProbeOf p w = case Map.lookup p (wProbes w) of
  Just pr → Just pr
  Nothing → (\pg → probeOfPage pg) <$> windowPage p w

windowSize ∷ Window → Int
windowSize = Map.size . wPages

windowPageNumbers ∷ Window → [PageNo]
windowPageNumbers = Map.keys . wPages

windowMember ∷ PageNo → Window → Bool
windowMember p w = Map.member p (wPages w)

-- | A page the window holds, parsed into a value.
windowPage ∷ PageNo → Window → Maybe Page
windowPage p w = (\vp → Page (vpTree vp) (vpLevel vp) p (bodyOfValid (vpBytes vp))) <$> Map.lookup p (wPages w)

-- ---------------------------------------------------------------------------
-- The plan monad

-- | Why an operation stopped.
data Stop
  = -- | A page the operation needs is not in the window: the work is pending.
    Need !PageNo
  | -- | A page contradicts its place in the tree, or the structure is invalid.
    Bad !PageError !PageNo
  | -- | An update would make the tree taller than 'maxLevel'.
    TooTall !TreeId
  | -- | An internal invariant of the tree code failed (never a caller's fault).
    Invariant !TreeId
  | -- | The overlay of new pages would hold more bytes than a plan may: the figure.
    Over !Int
  | -- | The memos a plan holds would pass what its RAM is charged for: the figure.
    MemoOver !Int
  deriving stock (Eq, Show)

-- | A reference to a node: a committed page (with the checksum its parent records for it, when
-- a parent does: a root is named by the root record and has none) or an overlay page.
data Ref = DiskRef !PageNo !(Maybe Word32) | Fresh !Int
  deriving stock (Eq, Ord, Show)

-- | A committed page with no recorded checksum (a tree's root).
pattern Disk ∷ PageNo → Ref
pattern Disk p ← DiskRef p _
  where
    Disk p = DiskRef p Nothing

{-# COMPLETE Disk, Fresh #-}

data NBody
  = NLeaf [(ByteString, ByteString)]
  | NInner [(ByteString, Ref)]
  deriving stock (Eq, Show)

data Node = Node
  { nTree ∷ !TreeId
  , nLevel ∷ !Int
  , nBody ∷ !NBody
  }
  deriving stock (Eq, Show)

-- | The committed nodes a plan keeps parsed: the last 8 (per tree edit).
hotNodes ∷ Int
hotNodes = 8

-- | The accounted bytes of one parsed node held in that set: a dense leaf's entry
-- list, a cons cell, a pair and two string headers per entry (119 entries at most for a
-- record page and 225 for the smallest bookkeeping entry), rounded up.
hotNodeBytes ∷ Int
hotNodeBytes = 32768

-- | A new page held packed: its entries as one byte string.
data Stored = Stored !TreeId !Int !Bool !Int !ByteString

packNode ∷ Node → Stored
packNode (Node t l body) = case body of
  NLeaf es → Stored t l True (length es) (packBody (Left es))
  NInner es → Stored t l False (length es) (packBody (Right [(k, refCode r) | (k, r) ← es]))
  where
    refCode (DiskRef (PageNo p) (Just crc)) = (0, p, crc)
    refCode (DiskRef (PageNo p) Nothing) = (2, p, 0)
    refCode (Fresh i) = (1, fromIntegral i, 0)

unpackNode ∷ Stored → Node
unpackNode (Stored t l leaf n pl) = case unpackBody leaf n pl of
  Left es → Node t l (NLeaf es)
  Right es → Node t l (NInner [(k, case tag of 0 → DiskRef (PageNo c) (Just crc); 2 → DiskRef (PageNo c) Nothing; _ → Fresh (fromIntegral c)) | (k, (tag, c, crc)) ← es])

-- | The working state of one plan: the window, the new pages (packed, accounted and
-- bounded by a byte budget), the committed pages replaced and the visits made.
data Edit = Edit
  { eWin ∷ !Window
  , eFresh ∷ !(IntMap Stored)
  , eFreshBytes ∷ !Int
  , eSizes ∷ !(IntMap Int)
  , eFreshHot ∷ [(Int, Node)]
  -- ^ The last few new pages written, kept parsed (at most 'hotNodes'); an older one is
  -- packed into 'eFresh'. Every new page is accounted at its packed size in 'eSizes'.
  , eBudget ∷ !Int
  , eNext ∷ !Int
  , eReplaced ∷ !(Set PageNo)
  , eSteps ∷ !Int
  , eFacts ∷ [Fact]
  -- ^ The facts this plan established so far (in this call, not those its window already carried).
  , eDelSplits ∷ !Int
  -- ^ The nodes the deletions of this plan split: the counter of the suite, read by nothing else.
  , eMemoCap ∷ !Int
  -- ^ The accounted bytes of memos ('FactEdge') the plan may hold, those its window carries and those it makes ('maxMemoBytes' in production).
  , eHot ∷ [(PageNo, Node)]
  -- ^ The last few committed nodes parsed, so a run of updates in one neighbourhood
  -- does not parse the same page again for every key. At most 'hotNodes' are held and
  -- 'hotNodeBytes' each is accounted in a plan's scratch.
  }

-- | An edit that starts with the facts another edit of the same plan has established (a plan's record and bookkeeping edits are two, and a
-- checkpoint carries what both made).
carryFacts ∷ Edit → Edit → Edit
carryFacts from to = to {eFacts = eFacts from}

-- | The edit, holding at most the given accounted bytes of memos.
withMemoCap ∷ Int → Edit → Edit
withMemoCap cap e = e {eMemoCap = cap}

-- | The accounted bytes of the memos ('FactEdge') a window carries.
windowMemoBytes ∷ Window → Int
windowMemoBytes w = sum [factBytesOf f | f@(FactEdge {}) ← Set.toList (wProven w)]

-- | THE LEDGER of what a plan holds of facts: every fact its window carries and every one the plan has made or used, each counted ONCE (a
-- set), at the accounted bytes of its kind ('factBytesOf'). It is the one place the plan's fact bytes are read: the charge of every way a plan
-- ends (a plan, a header-only plan, a reclamation chunk, a checkpoint) and the memo budget at the record of a memo.
editHeldFacts ∷ Edit → Set Fact
editHeldFacts e = Set.union (wProven (eWin e)) (Set.fromList (eFacts e))

-- | The accounted bytes of every fact the plan holds ('editHeldFacts'), and the list cell the edit keeps for each MEMO its window also
-- carries (a memo used again is two structures: the window's set entry and the edit's list cell, 'memoListCellBytes').
editHeldFactBytes ∷ Edit → Int
editHeldFactBytes e = sum (map factBytesOf (Set.toList (editHeldFacts e))) + memoListCellBytes * editSharedMemos e

-- | The accounted bytes of the memos ('FactEdge') among them, the shared ones' list cells included.
editHeldMemoBytes ∷ Edit → Int
editHeldMemoBytes e = sum [factBytesOf f | f@(FactEdge {}) ← Set.toList (editHeldFacts e)] + memoListCellBytes * editSharedMemos e

-- | The memos the edit has used again that its window carries.
editSharedMemos ∷ Edit → Int
editSharedMemos e = length [() | f@(FactEdge {}) ← eFacts e, Set.member f (wProven (eWin e))]

-- | The bytes of the list cell an edit keeps for a fact it holds.
memoListCellBytes ∷ Int
memoListCellBytes = 24

isMemo ∷ Fact → Bool
isMemo (FactEdge {}) = True
isMemo _ = False

-- | Note a fact this plan has just established.
recordFact ∷ Fact → Edit → Edit
recordFact f e = e {eFacts = f : eFacts e}

-- | Note that a page's proof against every root is complete: its fact, and none of the progress that led to it.
recordProof ∷ Fact → PageNo → Edit → Edit
recordProof f pg e = let kept = [x | x ← eFacts e, not (partOf x)] in foldr seq () kept `seq` e {eFacts = f : kept}
  where
    partOf (FactOutOf p _) = p == pg
    partOf _ = False

-- | The facts this plan established so far, oldest first.
editFacts ∷ Edit → [Fact]
editFacts = reverse . eFacts

-- | A fresh plan state over a window, whose new pages may hold at most the given
-- accounted bytes.
newEdit ∷ Int → Window → Edit
newEdit budget w = Edit w IntMap.empty 0 IntMap.empty [] budget 0 Set.empty 0 [] 0 maxBound []

-- | The accounted bytes of the new pages the plan holds now.
editFreshBytes ∷ Edit → Int
editFreshBytes = eFreshBytes

-- | The page reads this plan has made, counting every visit: the measure of its
-- bounded read work.
editSteps ∷ Edit → Int
editSteps = eSteps

-- | The committed pages this plan replaced or removed.
editReplaced ∷ Edit → Set PageNo
editReplaced = eReplaced

editWindow ∷ Edit → Window
editWindow = eWin

-- | A plan step: it threads the plan's state and, when it stops, hands back the state it had reached, so that the facts established
-- before the stop (a validated neighbour, a proof) are not lost with it ('runMKeep').
newtype M a = M {unM ∷ Edit → (Either Stop a, Edit)}

instance Functor M where
  fmap f (M g) = M $ \e → case g e of
    (Left s, e') → (Left s, e')
    (Right a, e') → (Right (f a), e')

instance Applicative M where
  pure a = M $ \e → (Right a, e)
  M f <*> M g = M $ \e → case f e of
    (Left s, e') → (Left s, e')
    (Right h, e') → case g e' of
      (Left s, e'') → (Left s, e'')
      (Right a, e'') → (Right (h a), e'')

instance Monad M where
  M g >>= f = M $ \e → case g e of
    (Left s, e') → (Left s, e')
    (Right a, e') → unM (f a) e'

-- | Run a plan step from a state.
runM ∷ M a → Edit → Either Stop (a, Edit)
runM m e = case unM m e of
  (Left s, _) → Left s
  (Right a, e') → Right (a, e')

-- | Run a plan step from a state, and have the state it stopped in too: what the step established before it stopped.
runMKeep ∷ M a → Edit → (Either Stop a, Edit)
runMKeep = unM

stop ∷ Stop → M a
stop s = M (\e → (Left s, e))

-- | Fail the plan because an invariant of the tree code does not hold.
failInvariant ∷ TreeId → M a
failInvariant = stop . Invariant

-- | Lift a failed decode of a page the caller supplied into the plan.
liftStop ∷ Either Stop a → M a
liftStop (Left s) = stop s
liftStop (Right a) = pure a

getEdit ∷ M Edit
getEdit = M (\e → (Right e, e))

putEdit ∷ Edit → M ()
putEdit e = M (\_ → (Right (), e))

-- | Load a node, counting the visit. The tree and level are checked against what
-- the parent expects.
load ∷ TreeId → Maybe Int → Ref → M Node
load tree expectLevel ref = do
  e ← getEdit
  putEdit e {eSteps = eSteps e + 1}
  node ← case ref of
    Fresh i → maybe (stop (Invariant tree)) pure (freshNode e i)
    DiskRef p recorded → let expected = case recorded of Just c → Just c; Nothing → Map.lookup p (wRoots (eWin e)) in case lookup p (eHot e) of
      Just hot | nTree hot == tree, hotAgrees expected p e → pure hot
      -- a root with no recorded checksum fails closed
      _ | Nothing ← expected, not (wUnchecked (eWin e)) → stop (Bad RootChecksumMissing p)
      _ | let PageNo n = p, n >= wBelow (eWin e) → stop (Bad (BadReference p) p)
      _ → case Map.lookup p (wPages (eWin e)) of
          Nothing → stop (Need p)
          -- the page a parent points at is the version it recorded, not another valid page
          Just vp | Just want <- expected, pageCrcOf (vpBytes vp) /= want → stop (Bad (ChildChecksum want (pageCrcOf (vpBytes vp))) p)
          Just vp → case nodeOfPage tree p (Page (vpTree vp) (vpLevel vp) p (bodyOfValid (vpBytes vp))) of
            Left err → stop (Bad err p)
            Right n → do
              e2 ← getEdit
              putEdit e2 {eHot = take hotNodes ((p, n) : filter ((/= p) . fst) (eHot e2))}
              pure n
  case expectLevel of
    Just l | l /= nLevel node → stop (Bad (BadLevel (nLevel node)) (refPage ref))
    _ → pure ()
  -- A page reached from its parent (the level is expected) and not the root holds at least a quarter of a payload. This is the
  -- ONE role-dependent check of a load, and it applies to every disk-backed node however it was obtained: a page first loaded as
  -- a root (exempt) and still hot when a parent names it as a child is the same page in another role, and is refused alike.
  case (ref, expectLevel) of
    (DiskRef {}, Just _) | not (wUnchecked (eWin e)), underFull False (bodyBytesOf (nBody node)) → stop (Bad (UnderFull (bodyBytesOf (nBody node))) (refPage ref))
    _ → pure node

refPage ∷ Ref → PageNo
refPage (DiskRef p _) = p
refPage (Fresh _) = PageNo maxBound

-- | The checksum a page carries: its last four bytes.
pageCrcOf ∷ ByteString → Word32
pageCrcOf bs = getLe32 bs pageChecksumOffset

-- | A cached node is used only for the checksum its parent records: a page reached through a
-- pointer that names another checksum is looked up in the window and refused there.
hotAgrees ∷ Maybe Word32 → PageNo → Edit → Bool
hotAgrees Nothing _ _ = True
hotAgrees (Just want) p e = maybe False (\vp → pageCrcOf (vpBytes vp) == want) (Map.lookup p (wPages (eWin e)))

nodeOfPage ∷ TreeId → PageNo → Page → Either PageError Node
nodeOfPage tree _ (Page t level _ body)
  | t /= tree = Left KindMismatch
  | otherwise = case body of
      Leaf es → Right (Node tree 0 (NLeaf es))
      Inner es → Right (Node tree level (NInner [(k, DiskRef c (Just crc)) | (k, Child c crc) ← es]))
      List _ _ → Left KindMismatch

-- | The keys a node holds must lie in the range its parent promises.
checkBounds ∷ Maybe ByteString → Maybe ByteString → Ref → Node → M ()
checkBounds lo hi ref node = case keysOf node of
  [] → stop (Bad KeyOrder (refPage ref))
  ks@(k0 : _)
    | maybe False (k0 <) lo → stop (Bad KeyOrder (refPage ref))
    | maybe False (\h → last ks >= h) hi → stop (Bad KeyOrder (refPage ref))
    | otherwise → pure ()

keysOf ∷ Node → [ByteString]
keysOf (Node _ _ (NLeaf es)) = map fst es
keysOf (Node _ _ (NInner es)) = map fst es

loadChecked ∷ TreeId → Maybe ByteString → Maybe ByteString → Maybe Int → Ref → M Node
loadChecked tree lo hi lvl ref = do
  node ← load tree lvl ref
  checkBounds lo hi ref node
  pure node

-- ---------------------------------------------------------------------------
-- Reads

-- | A sibling subtree of the node a descent is in: its reference, the bounds its separators
-- give it and its level.
data Sib = Sib !Ref !(Maybe ByteString) !(Maybe ByteString) !(Maybe Int)

-- | The bounds of the child at an index, and the nearest sibling subtrees on each side of it:
-- the neighbours inside the same node, else the ones the descent inherited.
childContext ∷ Maybe ByteString → Maybe ByteString → [(ByteString, Ref)] → Int → Int → Maybe Sib → Maybe Sib → (Maybe ByteString, Maybe ByteString, Maybe Sib, Maybe Sib)
childContext lo hi es i lv ls rs =
  let (lo', hi') = childBounds lo hi es i
      left = if i > 0 then (let (a, b) = childBounds lo hi es (i - 1) in Just (Sib (snd (es !! (i - 1))) a b (Just (lv - 1)))) else ls
      right = if i + 1 < length es then (let (a, b) = childBounds lo hi es (i + 1) in Just (Sib (snd (es !! (i + 1))) a b (Just (lv - 1)))) else rs
   in (lo', hi', left, right)

-- | The leaf at one end of a subtree, loaded through the separators that bound it.
extremeLeaf ∷ TreeId → Bool → Ref → Maybe ByteString → Maybe ByteString → Maybe Int → M [(ByteString, ByteString)]
extremeLeaf tree leftmost ref lo hi lvl = do
  n ← loadChecked tree lo hi lvl ref
  case nBody n of
    NLeaf es → pure es
    NInner [] → failInvariant tree
    NInner es →
      let i = if leftmost then 0 else length es - 1
          (lo', hi') = childBounds lo hi es i
       in extremeLeaf tree leftmost (snd (es !! i)) lo' hi' (Just (nLevel n - 1))

-- | An absence, a floor, a ceiling, the start of a scan and the unreachability of a page are
-- all concluded from the leaf (or node) a key leads to. That is only as true as the separators
-- that led there, which are checked against the leaves they separate only when those leaves
-- are loaded: a separator moved to another valid key sends a read to a neighbour that holds
-- no such record and the record reads as absent. So a conclusion is drawn only after the
-- landing node's neighbouring subtrees are loaded too, each through its own separators and
-- so checked against the bound it shares with the landing node. A key below the first
-- separator belongs to the first child, never to nothing.
validateLanding ∷ TreeId → Maybe Ref → ByteString → Int → M ()
validateLanding = validateLandingWith False

-- | 'validateLanding', and when asked (@memo@, an EDIT's lookups: its tree may be a staged one, and a plan holds many) each neighbouring
-- chain is MEMOISED ('FactEdge') once read, so that it is read only when no memo of it is known: the pages of the chain need not stay in a
-- window, and a checkpoint carries the memo.
validateLandingWith ∷ Bool → TreeId → Maybe Ref → ByteString → Int → M ()
validateLandingWith _ _ Nothing _ _ = pure ()
validateLandingWith memo tree (Just root) key stopLevel = go root Nothing Nothing Nothing Nothing Nothing
  where
    -- the landing node itself is not loaded here (a page being proved unreachable may not be in the
    -- window): its neighbours are, through the separators the descent used
    go ref lo hi lvl ls rs = do
      n ← loadChecked tree lo hi lvl ref
      case nBody n of
        NLeaf _ → pure ()
        NInner es → do
          let i = maybe 0 id (chooseChild key es)
              (lo', hi', ls', rs') = childContext lo hi es i (nLevel n) ls rs
          if nLevel n - 1 <= stopLevel
            then sides ls' rs'
            else go (snd (es !! i)) lo' hi' (Just (nLevel n - 1)) ls' rs'
    sides ls rs = do
      mapM_ (\(Sib r a b l) → edgeChecked memo tree False r a b l) ls
      mapM_ (\(Sib r a b l) → edgeChecked memo tree True r a b l) rs

-- | The extreme leaf of a neighbouring subtree read through its bounds (and not again when a memo of it is known and @memo@ is asked).
edgeChecked ∷ Bool → TreeId → Bool → Ref → Maybe ByteString → Maybe ByteString → Maybe Int → M ()
edgeChecked True tree leftmost ref@(DiskRef pg (Just crc)) lo hi lvl = do
  e ← getEdit
  let fact = edgeFact tree leftmost pg crc lo hi lvl
  if fact `elem` eFacts e
    then pure ()
    else
      if windowKnows fact (eWin e)
        -- a memo the window carries and this plan uses again is carried forward: it is one the plan made or used that a checkpoint hands on
        then useMemoM fact
        else do
          _ ← extremeLeaf tree leftmost ref lo hi lvl
          e' ← getEdit
          -- the memos a plan holds stay inside what its RAM is charged for: the ledger of what it holds, read here
          let held = editHeldMemoBytes e' + factBytesOf fact
          if held > eMemoCap e' then stop (MemoOver held) else putEdit (recordFact fact e')
edgeChecked _ tree leftmost ref lo hi lvl = () <$ extremeLeaf tree leftmost ref lo hi lvl

-- | A memo the window carries, used again by an edit: the edit keeps the window's own value, not the copy a lookup built to ask for it, so
-- the window and the edit never hold two copies of a memo.
useMemo ∷ Fact → Edit → Edit
useMemo fact e = let !stored = (case Set.lookupGE fact (wProven (eWin e)) of Just f | f == fact → f; _ → fact) in recordFact stored e

-- | Use a memo the window carries: the edit keeps it ('useMemo'), which the ledger charges a list cell for, so the budget is checked HERE as it is
-- at the record of a new one: a reuse that would pass it stops the plan as the shrinkable 'MemoOver'.
useMemoM ∷ Fact → M ()
useMemoM fact = do
  e ← getEdit
  let e' = useMemo fact e
      held = editHeldMemoBytes e'
  if held > eMemoCap e' then stop (MemoOver held) else putEdit e'

-- | The memo of a chain, its bounds COPIED out of the page buffers they are slices of and evaluated, so that a fact never keeps a 4 KiB page
-- alive for the bytes of a key it is charged for.
edgeFact ∷ TreeId → Bool → PageNo → Word32 → Maybe ByteString → Maybe ByteString → Maybe Int → Fact
edgeFact tree leftmost pg crc lo hi lvl = FactEdge tree leftmost pg crc (copied lo) (copied hi) (maybe (-1) id lvl)
  where
    copied = maybe Nothing (\b → let !c = toShort b in Just c)

-- | The page a tree currently holds at a level on the path of a key, if the tree has
-- one there: the root when its level is the target, else the child reference of the
-- node one level above (not loaded: only the interior path is read). Every step is
-- checked as any other descent is, so a malformed path is refused, never followed. It
-- answers whether a page is reachable from the committed tree without a sweep of the
-- store: a page reachable at all is on the path of its own first key.
livePageAt ∷ TreeId → Maybe Ref → ByteString → Int → M (Maybe PageNo)
livePageAt _ Nothing _ _ = pure Nothing
livePageAt tree (Just root) key target = do
  r ← walk
  -- a page is declared unreachable only once the neighbouring subtrees of the node its key
  -- leads to have been checked against the separators that led there
  validateLanding tree (Just root) key target
  pure r
  where
    walk = go root Nothing Nothing Nothing
    go ref lo hi lvl = do
      n ← loadChecked tree lo hi lvl ref
      case compare (nLevel n) target of
        EQ → pure (Just (refPage ref))
        LT → pure Nothing
        GT → case nBody n of
          NLeaf _ → pure Nothing
          -- a key below the first separator belongs to the first child (whose own keys then fail its
          -- bounds if the separator is not a lower bound of them): it is never absent from the index
          NInner es →
            let i = maybe 0 id (chooseChild key es)
                (lo', hi') = childBounds lo hi es i
                child = snd (es !! i)
             in if nLevel n - 1 == target then pure (Just (refPage child)) else go child lo' hi' (Just (nLevel n - 1))

-- | The index of the last separator at most the key, if any.
chooseChild ∷ ByteString → [(ByteString, a)] → Maybe Int
chooseChild k es = case length (takeWhile ((<= k) . fst) es) of
  0 → Nothing
  n → Just (n - 1)

-- | The bounds a child's keys lie in, from its position among its siblings.
childBounds ∷ Maybe ByteString → Maybe ByteString → [(ByteString, Ref)] → Int → (Maybe ByteString, Maybe ByteString)
childBounds lo hi es i =
  ( Just (fst (es !! i)) `orElse` lo
  , if i + 1 < length es then Just (fst (es !! (i + 1))) else hi
  )
  where
    orElse a _ = a

-- | The value stored under a key.
lookupKey ∷ TreeId → Maybe Ref → ByteString → M (Maybe ByteString)
lookupKey = lookupKeyWith False

-- | 'lookupKey' of an edit: the neighbours an absence is concluded from are memoised ('validateLandingWith').
lookupKeyWith ∷ Bool → TreeId → Maybe Ref → ByteString → M (Maybe ByteString)
lookupKeyWith _ _ Nothing _ = pure Nothing
lookupKeyWith memo tree (Just root) k = go root Nothing Nothing Nothing
  where
    go ref lo hi lvl = do
      n ← loadChecked tree lo hi lvl ref
      case nBody n of
        NLeaf es → case lookup k es of
          Just v → pure (Just v)
          -- an absence is concluded only after the leaf's neighbours were checked against its bounds
          Nothing → validateLandingWith memo tree (Just root) k 0 >> pure Nothing
        -- absence is concluded only from a leaf that passed its bounds: a key below the first
        -- separator is looked for in the first child, which is validated like any other
        NInner es →
          let i = maybe 0 id (chooseChild k es)
              (lo', hi') = childBounds lo hi es i
           in go (snd (es !! i)) lo' hi' (Just (nLevel n - 1))

-- | The greatest entry whose key is at most the given key.
floorKey ∷ TreeId → Maybe Ref → ByteString → M (Maybe (ByteString, ByteString))
floorKey = floorKeyWith False

-- | 'floorKey' of an edit ('lookupKeyWith').
floorKeyWith ∷ Bool → TreeId → Maybe Ref → ByteString → M (Maybe (ByteString, ByteString))
floorKeyWith _ _ Nothing _ = pure Nothing
floorKeyWith memo tree (Just root) k = validateLandingWith memo tree (Just root) k 0 >> go root Nothing Nothing Nothing
  where
    go ref lo hi lvl = do
      n ← loadChecked tree lo hi lvl ref
      case nBody n of
        NLeaf es → pure (lastMaybe (takeWhile ((<= k) . fst) es))
        NInner es → do
            let i = maybe 0 id (chooseChild k es)
                (lo', hi') = childBounds lo hi es i
            r ← go (snd (es !! i)) lo' hi' (Just (nLevel n - 1))
            case r of
              Just _ → pure r
              Nothing
                | i > 0 →
                    let (plo, phi) = childBounds lo hi es (i - 1)
                     in extreme False (snd (es !! (i - 1))) plo phi (Just (nLevel n - 1))
                | otherwise → pure Nothing
    extreme leftmost ref lo hi lvl = do
      n ← loadChecked tree lo hi lvl ref
      case nBody n of
        NLeaf es → pure (if leftmost then headMaybe es else lastMaybe es)
        NInner es →
          let i = if leftmost then 0 else length es - 1
              (lo', hi') = childBounds lo hi es i
           in extreme leftmost (snd (es !! i)) lo' hi' (Just (nLevel n - 1))
    lastMaybe [] = Nothing
    lastMaybe xs = Just (last xs)
    headMaybe [] = Nothing
    headMaybe (x : _) = Just x

-- | The least entry whose key is at least (or, when strict, greater than) the key.
ceilKey ∷ TreeId → Bool → Maybe Ref → ByteString → M (Maybe (ByteString, ByteString))
ceilKey = ceilKeyWith False

-- | 'ceilKey' of an edit ('lookupKeyWith').
ceilKeyWith ∷ Bool → TreeId → Bool → Maybe Ref → ByteString → M (Maybe (ByteString, ByteString))
ceilKeyWith _ _ _ Nothing _ = pure Nothing
ceilKeyWith memo tree strict (Just root) k = validateLandingWith memo tree (Just root) k 0 >> go root Nothing Nothing Nothing
  where
    keep key = if strict then key > k else key >= k
    go ref lo hi lvl = do
      n ← loadChecked tree lo hi lvl ref
      case nBody n of
        NLeaf es → pure (firstMaybe (filter (keep . fst) es))
        NInner es → do
          let i = maybe 0 id (chooseChild k es)
              (lo', hi') = childBounds lo hi es i
          r ← go (snd (es !! i)) lo' hi' (Just (nLevel n - 1))
          case r of
            Just _ → pure r
            Nothing
              | i + 1 < length es →
                  let (nlo, nhi) = childBounds lo hi es (i + 1)
                   in leftmost (snd (es !! (i + 1))) nlo nhi (Just (nLevel n - 1))
              | otherwise → pure Nothing
    leftmost ref lo hi lvl = do
      n ← loadChecked tree lo hi lvl ref
      case nBody n of
        NLeaf es → pure (firstMaybe es)
        NInner [] → failInvariant tree
        NInner es@((_, c0) : _) →
          let (lo', hi') = childBounds lo hi es 0
           in leftmost c0 lo' hi' (Just (nLevel n - 1))
    firstMaybe [] = Nothing
    firstMaybe (x : _) = Just x

-- | Up to @limit@ entries in key order from the first key at or after the start (or
-- strictly after it), stopping before a key at or after the end. Each entry costs
-- one bounded successor lookup, so the work is at most @limit@ times the tree's
-- height.
rangeKeys ∷ TreeId → Maybe Ref → Bool → ByteString → Maybe ByteString → Int → M [(ByteString, ByteString)]
rangeKeys _ Nothing _ _ _ _ = pure []
rangeKeys tree (Just root) strictStart start end limit = do
  validateLanding tree (Just root) start 0
  (es, _, _) ← go root Nothing Nothing Nothing limit
  pure es
  where
    keep k = (if strictStart then k > start else k >= start) && maybe True (k <) end
    beforeEnd k = maybe True (k <) end
    -- Entries in order, how many more may be taken and whether the end was reached.
    go ref lo hi lvl n
      | n <= 0 = pure ([], 0, False)
      | otherwise = do
          nd ← loadChecked tree lo hi lvl ref
          case nBody nd of
            NLeaf es → do
              let inRange = filter (\(k, _) → keep k) es
                  taken = take n inRange
                  past = any (\(k, _) → not (beforeEnd k)) es
              pure (taken, n - length taken, past)
            NInner es → do
              let i0 = maybe 0 id (chooseChild start es)
              children nd lo hi es [i0 .. length es - 1] n []
    children _ _ _ _ [] n acc = pure (concat (reverse acc), n, False)
    children nd lo hi es (i : is) n acc
      | n <= 0 = pure (concat (reverse acc), 0, False)
      | maybe False (\e → fst (es !! i) >= e) end = pure (concat (reverse acc), n, True)
      | otherwise = do
          let (clo, chi) = childBounds lo hi es i
          (got, n', past) ← go (snd (es !! i)) clo chi (Just (nLevel nd - 1)) n
          if past
            then pure (concat (reverse (got : acc)), n', True)
            else children nd lo hi es is n' (got : acc)

-- ---------------------------------------------------------------------------
-- Overlay

-- | A new page as a parsed node: from the hot set, or unpacked from its packed form.
freshNode ∷ Edit → Int → Maybe Node
freshNode e i = case lookup i (eFreshHot e) of
  Just n → Just n
  Nothing → unpackNode <$> IntMap.lookup i (eFresh e)

-- | The accounted bytes of a node held packed: the length of its packed entries and a
-- header, computed without packing it.
packedBytes ∷ Node → Int
packedBytes (Node _ _ body) = overlayNodeBytes (case body of
  NLeaf es → sum [2 + BS.length k + BS.length v | (k, v) ← es]
  -- the page's entry and one byte more for the tag of the reference it is packed with
  NInner es → sum [innerKeyBytes k + 1 | (k, _) ← es])

-- | Set a new page, accounting its packed bytes and refusing the plan when the new
-- pages would hold more than the budget. The page is kept parsed in a small hot set;
-- the page that falls out of it is packed.
setFresh ∷ Int → Node → Edit → M Edit
setFresh i node e = do
  let size = packedBytes node
      total = eFreshBytes e - IntMap.findWithDefault 0 i (eSizes e) + size
  if total > eBudget e
    then stop (Over total)
    else do
      let hot = (i, node) : filter ((/= i) . fst) (eFreshHot e)
          (keep, spill) = splitAt hotNodes hot
          packedOut = foldr (\(j, n) m → IntMap.insert j (packNode n) m) (IntMap.delete i (eFresh e)) spill
      pure e {eFresh = packedOut, eFreshHot = keep, eSizes = IntMap.insert i size (eSizes e), eFreshBytes = total}

-- | Put a node in the overlay under a reference that is being rewritten: an overlay
-- page is changed in place; a committed page is recorded as replaced and its copy
-- gets a new overlay number.
rewrite ∷ Ref → Node → M Ref
rewrite (Fresh i) node = do
  e ← getEdit
  e' ← setFresh i node e
  putEdit e'
  pure (Fresh i)
rewrite (Disk p) node = do
  e ← getEdit
  let i = eNext e
  e' ← setFresh i node e
  putEdit e' {eNext = i + 1, eReplaced = Set.insert p (eReplaced e')}
  pure (Fresh i)

-- | A node with no committed predecessor.
fresh ∷ Node → M Ref
fresh node = do
  e ← getEdit
  let i = eNext e
  e' ← setFresh i node e
  putEdit e' {eNext = i + 1}
  pure (Fresh i)

-- | Drop a node that is no longer part of the tree.
discard ∷ Ref → M ()
discard (Fresh i) = do
  e ← getEdit
  let old = IntMap.findWithDefault 0 i (eSizes e)
  putEdit e {eFresh = IntMap.delete i (eFresh e), eFreshHot = filter ((/= i) . fst) (eFreshHot e), eSizes = IntMap.delete i (eSizes e), eFreshBytes = eFreshBytes e - old}
discard (Disk p) = do
  e ← getEdit
  putEdit e {eReplaced = Set.insert p (eReplaced e)}

bodyBytesOf ∷ NBody → Int
bodyBytesOf (NLeaf es) = sum (map entryBytes es)
bodyBytesOf (NInner es) = sum [innerKeyBytes k | (k, _) ← es]

nodeBytesOf ∷ Node → Int
nodeBytesOf = bodyBytesOf . nBody

-- | The split of a list of sized entries into two non-empty halves that each fit a
-- payload, as even as the entries allow.
splitEven ∷ (a → Int) → [a] → Maybe ([a], [a])
splitEven size xs
  | null candidates = Nothing
  | otherwise = Just (splitAt (snd (minimum candidates)) xs)
  where
    total = sum (map size xs)
    prefixes = scanl1 (+) (map size xs)
    candidates =
      [ (abs (2 * p - total), j)
      | (j, p) ← zip [1 ..] (init prefixes)
      , p <= pagePayloadBytes
      , total - p <= pagePayloadBytes
      ]

-- ---------------------------------------------------------------------------
-- Insert

data Ins = InsNone | InsOne !Ref | InsTwo !Ref !ByteString !Ref

-- | Insert or replace an entry and return the new root. An entry already holding
-- the value changes nothing (no copy, no replaced page): a no-op appends nothing.
insertKey ∷ TreeId → Maybe Ref → ByteString → ByteString → M (Maybe Ref)
insertKey tree root k v = do
  existing ← lookupKeyWith True tree root k
  if existing == Just v then pure root else insertAbsentKey tree root k v

-- | 'insertKey' of a key the caller has PROVEN absent from the tree (a fact of the committed roots, 'FactNotIndexed', and the key is
-- one no earlier write of the plan made): it looks nothing up, so reads no neighbour, and descends to the leaf alone.
insertAbsentKey ∷ TreeId → Maybe Ref → ByteString → ByteString → M (Maybe Ref)
insertAbsentKey tree root k v =
  case root of
      Nothing → Just <$> fresh (Node tree 0 (NLeaf [(k, v)]))
      Just r → do
        res ← ins r Nothing Nothing Nothing
        exitRoot tree res
  where
    ins ref lo hi lvl = do
      n ← loadChecked' lo hi lvl ref
      case nBody n of
        NLeaf es → do
          let es' = insertSorted (k, v) es
          exitNode tree ref n (NLeaf es')
        NInner es → do
          let i = maybe 0 id (chooseChild k es)
              (clo, chi) = childBounds lo hi es i
              below = maybe False (k <) (firstSep es)
              (clo', chi') = if below then (lo, chi) else (clo, chi)
          r ← ins (snd (es !! i)) clo' chi' (Just (nLevel n - 1))
          -- an insertion never empties a child
          when' (case r of InsNone → True; _ → False) (stop (Invariant tree))
          let relabel (sk, c) = if i == 0 && below then (k, c) else (sk, c)
              es' = case r of
                InsNone → es
                InsOne c → take i es ++ [relabel (fst (es !! i), c)] ++ drop (i + 1) es
                InsTwo c1 sep c2 → take i es ++ [relabel (fst (es !! i), c1), (sep, c2)] ++ drop (i + 1) es
          -- a child that shrank (a value replaced by a shorter one, a first separator replaced by a shorter key) is
          -- repacked by the same step a deletion uses; a child that split has two halves far above the minimum
          es'' ← case r of
            InsOne c → do
              cn ← load tree (Just (nLevel n - 1)) c
              if nodeBytesOf cn < minNodeBytes && length es' >= 2
                then rebalanceChild tree lo hi (nLevel n - 1) i es'
                else pure es'
            _ → pure es'
          exitNode tree ref n (NInner es'')
    -- A freshly inserted key may sit below the node's lowest key only on the
    -- leftmost spine, whose bounds are open; the check there tolerates it.
    loadChecked' lo hi lvl ref = do
      node ← load tree lvl ref
      case keysOf node of
        [] → stop (Bad KeyOrder (refPage ref))
        ks@(k0 : _)
          | maybe False (k0 <) lo → stop (Bad KeyOrder (refPage ref))
          | maybe False (\h → last ks >= h) hi → stop (Bad KeyOrder (refPage ref))
          | otherwise → pure node

firstSep ∷ [(ByteString, a)] → Maybe ByteString
firstSep ((s, _) : _) = Just s
firstSep [] = Nothing

insertSorted ∷ (ByteString, ByteString) → [(ByteString, ByteString)] → [(ByteString, ByteString)]
insertSorted (k, v) es = before ++ [(k, v)] ++ dropWhile ((== k) . fst) after
  where
    (before, after) = span ((< k) . fst) es

-- ---------------------------------------------------------------------------
-- Delete

-- | Remove an entry and return the new root, rebalancing under-full nodes and
-- collapsing a root left with one child. An absent key changes nothing.
deleteKey ∷ TreeId → Maybe Ref → ByteString → M (Maybe Ref)
deleteKey _ Nothing _ = pure Nothing
deleteKey tree root@(Just r0) k = do
  existing ← lookupKeyWith True tree root k
  case existing of
    Nothing → pure root
    Just _ → do
      res ← del r0 Nothing Nothing Nothing
      case res of
        InsTwo {} → bumpDeleteSplit
        _ → pure ()
      exitRoot tree res
  where
    del ref lo hi lvl = do
      n ← loadChecked tree lo hi lvl ref
      case nBody n of
        NLeaf es → exitNode tree ref n (NLeaf (filter ((/= k) . fst) es))
        NInner es → do
          i ← maybe (stop (Invariant tree)) pure (chooseChild k es)
          let (clo, chi) = childBounds lo hi es i
          r ← del (snd (es !! i)) clo chi (Just (nLevel n - 1))
          es' ← case r of
            InsNone → pure (take i es ++ drop (i + 1) es)
            InsOne c → do
              cn ← load tree (Just (nLevel n - 1)) c
              let replaced = take i es ++ [(fst (es !! i), c)] ++ drop (i + 1) es
              if nodeBytesOf cn < minNodeBytes && length es >= 2
                then rebalance lo hi (nLevel n - 1) i replaced
                else pure replaced
            -- a child that split (a repack of its children moved a longer separator into it) has two halves above the minimum
            InsTwo c1 sep c2 → bumpDeleteSplit >> pure (take i es ++ [(fst (es !! i), c1), (sep, c2)] ++ drop (i + 1) es)
          exitNode tree ref n (NInner es')
    rebalance = rebalanceChild tree

-- | What the shared exit of a write does with an inner node of @n@ children whose separators are the given keys: @\"none\"@
-- (emptied, dropped), @\"one\"@ (fits a page, rewritten) or @\"two\"@ plus the payload bytes of the two halves (split).
exitProbe ∷ [ByteString] → Either Stop (String, [Int])
exitProbe seps = fst <$> runM act (newEdit maxBound (emptyWindow (StoreIdentity (ArenaId 1) 7) 0))
  where
    body = NInner [(k, Fresh 0) | k ← seps]
    act = do
      r ← fresh (Node TreeLinks 1 body)
      res ← exitNode TreeLinks r (Node TreeLinks 1 body) body
      case res of
        InsNone → pure ("none", [])
        InsOne _ → pure ("one", [bodyBytesOf body])
        InsTwo a _ b → do
          na ← load TreeLinks Nothing a
          nb ← load TreeLinks Nothing b
          pure ("two", [bodyBytesOf (nBody na), bodyBytesOf (nBody nb)])

-- | Run an action when a condition holds.
when' ∷ Bool → M () → M ()
when' c act = if c then act else pure ()

-- | THE exit of every node a write produces, shared by insertion and deletion: an emptied node is dropped, a node that fits
-- a page is rewritten, a node that holds more than a payload is split into two halves that are reported upward (each at least
-- @(payload + 1 - maxEntry) / 2@ bytes, far above the minimum). Every write can make a node larger (an entry added, a
-- separator replaced by a longer key, a value by a longer one) or smaller, and the next level up repacks a child that fell
-- under the minimum: neither direction is left to the caller.
exitNode ∷ TreeId → Ref → Node → NBody → M Ins
exitNode tree ref n body
  | emptyBody body = discard ref >> pure InsNone
  | bodyBytesOf body <= pagePayloadBytes = InsOne <$> rewrite ref n {nBody = body}
  | otherwise = case body of
      NLeaf es → case splitEven entryBytes es of
        Just (l, r@((sk, _) : _)) → twoNodes (NLeaf l) (NLeaf r) sk
        _ → stop (Invariant tree)
      NInner es → case splitEven (innerKeyBytes . fst) es of
        Just (l, r@((sk, _) : _)) → twoNodes (NInner l) (NInner r) sk
        _ → stop (Invariant tree)
  where
    emptyBody (NLeaf es) = null es
    emptyBody (NInner es) = null es
    twoNodes l r sep = do
      a ← rewrite ref n {nBody = l}
      b ← fresh n {nBody = r}
      pure (InsTwo a sep b)

-- | THE exit of every write that returns a root, shared by insertion and deletion: an emptied tree has no root, a root that
-- fits stays (a root left with one child collapses, 'collapseRoot'), and a root that split becomes the two children of a
-- new root.
exitRoot ∷ TreeId → Ins → M (Maybe Ref)
exitRoot tree res = case res of
  InsNone → pure Nothing
  InsOne r → Just <$> collapseRoot tree r
  InsTwo a sep b → do
    na ← load tree Nothing a
    let level = nLevel na + 1
    if level > maxLevel
      then stop (TooTall tree)
      else do
        lowest ← case keysOf na of
          (x : _) → pure x
          [] → stop (Invariant tree)
        Just <$> fresh (Node tree level (NInner [(lowest, a), (sep, b)]))

-- | THE exit of every write that returns a root: a root left with one child collapses to that child (the child is the
-- root then, exempt from the minimum fill). Follows single-child roots down, checking each child's level (one lower
-- than its parent's, so the walk is bounded by the tree height and a cycle cannot loop) and the separator bounds its
-- parent promises, exactly as every other descent does. A deletion and an insertion both end here: a repack of the
-- root's only two children by either can leave a root with one.
collapseRoot ∷ TreeId → Ref → M Ref
collapseRoot tree ref0 = load tree Nothing ref0 >>= go Nothing Nothing ref0
  where
    go lo hi ref n = case nBody n of
      NInner es@[(_, c)] | nLevel n > 0 → do
        let (clo, chi) = childBounds lo hi es 0
        cn ← loadChecked tree clo chi (Just (nLevel n - 1)) c
        discard ref
        go clo chi c cn
      _ → pure ref

-- | THE step that keeps minimum fill, shared by every write that can shrink a node (a deletion, a value replaced by a
-- shorter one, a separator replaced by a shorter key): repack the under-full child at index @i@ of a node with a
-- neighbour, one merged node when the pair fits a page, otherwise two nodes split evenly. A split of a node that
-- holds more than a payload leaves each half at least @(payload + 1 - maxEntry) / 2@ bytes (the even split differs
-- from half by at most one entry), far above 'minNodeBytes' even with entries of the maximum size; a merge holds a
-- sibling that is itself at the minimum or more.
rebalanceChild ∷ TreeId → Maybe ByteString → Maybe ByteString → Int → Int → [(ByteString, Ref)] → M [(ByteString, Ref)]
rebalanceChild tree lo hi childLevel i es = do
  let j = if i + 1 < length es then i + 1 else i - 1
      (a, b) = (min i j, max i j)
      (sa, ra) = es !! a
      (_, rb) = es !! b
      (alo, ahi) = childBounds lo hi es a
      (blo, bhi) = childBounds lo hi es b
  -- both siblings are checked against the separators their parent promises, so a
  -- malformed one is refused and never merged into a replacement page
  na ← loadChecked tree alo ahi (Just childLevel) ra
  nb ← loadChecked tree blo bhi (Just childLevel) rb
  combined ← case (nBody na, nBody nb) of
    (NLeaf x, NLeaf y) → pure (Left (x ++ y))
    (NInner x, NInner y) → pure (Right (x ++ y))
    _ → stop (Invariant tree)
  let repacked = case combined of
        Left xs → case packEntries entryBytes xs of
          Nothing → Nothing
          Just parts → Just (map NLeaf parts)
        Right xs → case packEntries (innerKeyBytes . fst) xs of
          Nothing → Nothing
          Just parts → Just (map NInner parts)
  case repacked of
    -- unreachable: the pair holds one node under the minimum and one that fits a page, so at most 5,065 bytes, and a split
    -- with both halves within a page exists for any total up to two pages
    Nothing → stop (Invariant tree)
    Just bodies → do
      mapM_ discard [ra, rb]
      refs ← mapM (fresh . Node tree childLevel) bodies
      let firstKeys = [sa] ++ [k' | body ← drop 1 bodies, Just k' ← [firstKeyOf body]]
          entries = zip firstKeys refs
      pure (take a es ++ entries ++ drop (b + 1) es)
  where
    firstKeyOf (NLeaf ((x, _) : _)) = Just x
    firstKeyOf (NInner ((x, _) : _)) = Just x
    firstKeyOf _ = Nothing

-- | One page when the entries fit, else the most even valid split into two.
packEntries ∷ (a → Int) → [a] → Maybe [[a]]
packEntries size xs
  | sum (map size xs) <= pagePayloadBytes = Just [xs]
  | otherwise = (\(l, r) → [l, r]) <$> splitEven size xs

-- ---------------------------------------------------------------------------
-- Finishing

reachableFresh ∷ Edit → [Maybe Ref] → [Int]
reachableFresh e roots = reverse (snd (foldl' visit (Set.empty, []) [r | Just r ← roots]))
  where
    visit acc (Disk _) = acc
    visit (seen, out) (Fresh i)
      | Set.member i seen = (seen, out)
      | otherwise = case freshNode e i of
          Nothing → (seen, out)
          Just n →
            let (seen', out') = case nBody n of
                  NLeaf _ → (Set.insert i seen, out)
                  NInner es → foldl' visit (Set.insert i seen, out) (map snd es)
             in (seen', i : out')

-- | How many overlay pages the given roots reach: the new pages the plan writes
-- for these trees.
freshCount ∷ Edit → [Maybe Ref] → Int
freshCount e roots = length (reachableFresh e roots)

-- | Number the reachable overlay pages from a supply of page numbers, children before
-- parents, and encode each one as it is built: one parsed page exists at a time, and
-- each output buffer is forced before the next page is built, so the result holds the
-- encoded pages and nothing around them. It fails if the supply is short or a page
-- does not encode.
assignPages ∷ (Page → Either PageError ByteString) → Edit → [Maybe Ref] → [PageNo] → Either Stop ([(PageNo, ByteString)], [Maybe PageNo], [PageNo])
assignPages encode e roots supply0 = do
  let order = reachableFresh e roots
  if length supply0 < length order
    then Left (Invariant TreeFree)
    else do
      let (used, rest) = splitAt (length order) supply0
          numbering = Map.fromList (zip order used) ∷ Map Int PageNo
          resolvePage (DiskRef p _) = Right p
          resolvePage (Fresh i) = maybe (Left (Invariant TreeFree)) Right (Map.lookup i numbering)
          -- a child's entry carries the checksum of the child's page: a committed child brings the one its
          -- parent recorded, a new child the one it was just encoded with (children are encoded first)
          resolveChild _ (DiskRef p (Just crc)) = Right (Child p crc)
          resolveChild _ (DiskRef _ Nothing) = Left (Invariant TreeFree)
          resolveChild crcs (Fresh i) = Child <$> resolvePage (Fresh i) <*> maybe (Left (Invariant TreeFree)) Right (Map.lookup i crcs)
          toPage crcs i = do
            n ← maybe (Left (Invariant TreeFree)) Right (freshNode e i)
            no ← maybe (Left (Invariant TreeFree)) Right (Map.lookup i numbering)
            body ← case nBody n of
              NLeaf es → Right (Leaf es)
              NInner es → Inner <$> traverse (\(sk, c) → (,) sk <$> resolveChild crcs c) es
            Right (Page (nTree n) (nLevel n) no body)
          step (acc, crcs) i = do
            page ← toPage crcs i
            bytes ← either (\err → Left (Bad err (pgNo page))) Right (encode page)
            -- force the buffer now, so the parsed page it came from can go
            -- and the page number, which would otherwise keep the whole parsed page alive
            let PageNo no = pgNo page
                crc = pageCrcOf bytes
            no `seq` crc `seq` BS.length bytes `seq` Right ((PageNo no, bytes) : acc, Map.insert i crc crcs)
      (encoded, _) ← foldM' step ([], Map.empty) order
      rootNos ← traverse (traverse resolvePage) roots
      Right (reverse encoded, rootNos, rest)
  where
    foldM' f z xs = go z xs
      where
        go acc [] = Right acc
        go acc (y : ys) = f acc y >>= \acc' → go acc' ys

-- ---------------------------------------------------------------------------
-- Exposed for the suite: building a tree of a given shape, checking a tree's shape, and the exits' answers

-- | A tree of a given shape for the suite: leaves of entries and inner nodes of children, every node a new page of the plan.
data ProbeSpec = PLeaf [(ByteString, ByteString)] | PInner [ProbeSpec]

-- | Build the tree a spec describes (an inner node's separators are its children's first keys; its level is one above its
-- first child's). The nodes are built as given: no fill rule is applied, so a spec may hold a node the store would refuse.
buildProbe ∷ TreeId → ProbeSpec → M Ref
buildProbe tree spec = fst <$> go spec
  where
    go (PLeaf es) = do
      r ← fresh (Node tree 0 (NLeaf es))
      pure (r, 0 ∷ Int)
    go (PInner cs) = do
      built ← mapM go cs
      firsts ← mapM (firstKey . fst) built
      let level = 1 + (case built of ((_, l) : _) → l; [] → 0)
      r ← fresh (Node tree level (NInner (zip firsts (map fst built))))
      pure (r, level)
    firstKey r = do
      n ← load tree Nothing r
      case keysOf n of
        (k : _) → pure k
        [] → stop (Invariant tree)

-- | Every way the tree under a root breaks the shape its writes keep: a node over a payload, a non-root node under a quarter of one,
-- a root with one child, keys or separators out of order or outside the bounds their parent promises, a level that is not one
-- below its parent's. Empty when the tree is legal.
shapeViolations ∷ TreeId → Maybe Ref → M [String]
shapeViolations _ Nothing = pure []
shapeViolations tree (Just root) = go True Nothing Nothing Nothing root
  where
    asc ks = and (zipWith (<) ks (drop 1 ks))
    go isRoot lo hi mlevel ref = do
      n ← load tree Nothing ref
      let bytes = nodeBytesOf n
          ks = keysOf n
          here =
            ["level " <> show (nLevel n) <> " where " <> show l <> " was expected" | Just l ← [mlevel], l /= nLevel n]
              ++ ["over-full: " <> show bytes | bytes > pagePayloadBytes]
              ++ ["under-full: " <> show bytes | not isRoot, underFull False bytes]
              ++ ["keys out of order" | not (asc ks)]
              ++ ["empty node" | null ks]
              ++ ["a key below its lower bound" | Just l ← [lo], any (< l) ks]
              ++ ["a key at or past its upper bound" | Just h ← [hi], any (>= h) ks]
      case nBody n of
        NLeaf _ → pure (here ++ ["a leaf above level 0" | nLevel n /= 0])
        NInner es → do
          subs ← mapM (\i → let (clo, chi) = childBounds lo hi es i in go False clo chi (Just (nLevel n - 1)) (snd (es !! i))) [0 .. length es - 1]
          pure (here ++ ["a root with one child" | isRoot, length es == 1] ++ concat subs)

-- | What the exit shared by insertion and deletion answers for a root that split into two nodes at the given level: the level of the
-- new root it makes, or the typed refusal ('TooTall') when that level is past 'maxLevel'.
exitRootProbe ∷ Int → Either Stop Int
exitRootProbe level = fst <$> runM act (newEdit maxBound (emptyWindow (StoreIdentity (ArenaId 1) 7) 0))
  where
    body = if level == 0 then NLeaf [(BS.singleton 1, BS.empty)] else NInner [(BS.singleton 1, Fresh 0)]
    act = do
      a ← fresh (Node TreeLinks level body)
      b ← fresh (Node TreeLinks level body)
      r ← exitRoot TreeLinks (InsTwo a (BS.singleton 2) b)
      case r of
        Just ref → nLevel <$> load TreeLinks Nothing ref
        Nothing → stop (Invariant TreeLinks)

-- | How many nodes the deletions of this plan split (a repack may install a longer separator, so a deletion can make a parent
-- over-full).
editDeleteSplits ∷ Edit → Int
editDeleteSplits = eDelSplits

-- | Count one split made by a deletion.
bumpDeleteSplit ∷ M ()
bumpDeleteSplit = do
  e ← getEdit
  putEdit e {eDelSplits = eDelSplits e + 1}

-- | The levels of the tree under a root (0 when it has none).
treeHeight ∷ TreeId → Maybe Ref → M Int
treeHeight _ Nothing = pure 0
treeHeight tree (Just r) = (\n → nLevel n + 1) <$> load tree Nothing r

-- | The plan state, for the suite.
-- | Test exposure: a page parsed as a plan holds it in its hot set (for the suite's forced-memory regression of 'hotNodeBytes').
parsedNode ∷ Page → Either PageError Node
parsedNode pg@(Page t _ p _) = nodeOfPage t p pg

-- | Test exposure: forces every key, value, page number and checksum of a parsed node, and answers how many entries it has.
parsedNodeWeight ∷ Node → Int
parsedNodeWeight (Node _ _ b) = case b of
  NLeaf es → length es + sum [BS.length k + BS.length v | (k, v) ← es]
  NInner es → length es + sum [BS.length k + refWeight r | (k, r) ← es]
  where
    refWeight (DiskRef (PageNo p) mc) = fromIntegral p + maybe 0 fromIntegral mc
    refWeight (Fresh i) = i

-- | Test exposure: the bytes of the page buffers a window holds (forces every one), for the suite's forced-memory regression.
windowPayloadBytes ∷ Window → Int
windowPayloadBytes w = sum [BS.length (vpBytes v) | v ← Map.elems (wPages w)]

-- | Test exposure: a parsed node packed as an edit packs it (at a level that varies with the number, so no two packings are shared).
packParsedNode ∷ Int → Node → Stored
packParsedNode i (Node t _ b) = packNode (Node t (i `mod` 7 + 1) b)

-- | Test exposure: the packed payload of a stored node (forces it).
storedPayload ∷ Stored → Int
storedPayload (Stored _ _ _ n pl) = n + BS.length pl

-- | Test exposure: the bytes of the packed new pages an edit holds (forces every one), for the suite's forced-memory regression of
-- 'overlayNodeBytes'.
editPackedPayload ∷ Edit → Int
editPackedPayload e = sum [BS.length pl | Stored _ _ _ _ pl ← IntMap.elems (eFresh e)]

getEditProbe ∷ M Edit
getEditProbe = getEdit
