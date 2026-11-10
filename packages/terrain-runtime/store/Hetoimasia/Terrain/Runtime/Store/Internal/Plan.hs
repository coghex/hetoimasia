-- | Staged transaction planning: from the committed roots and a window of validated
-- pages to a complete, bounded candidate of new pages, or a typed result that
-- explains why there is none.
--
-- A plan is pure. It reads pages only through the supplied window (a missing page
-- is the pending result 'Pending', never an empty index), takes its new page
-- numbers from the allocator's supply, writes nothing and publishes nothing. Its
-- 'Plan' value names the base it was made against; a plan whose base is no longer
-- the committed root is refused when it is admitted and re-planned, never
-- relabelled.
--
-- = A candidate
--
-- A #661 candidate is one delta: the canonical removal together with its minimum
-- connection obligation, or one discovery batch's knowledge, exposed-boundary
-- records and remaining obligations. The plan applies all of its record writes to
-- the three record trees and carries the candidate's next control header; it is one
-- plan, so an edit never reaches the pages without its continuation, and new
-- knowledge never without the work it leaves. Writes that change nothing are
-- dropped; a candidate that then changes no page and no header is 'NoWork', and a
-- no-op appends no history.
--
-- = Page accounting
--
-- A plan writes, and counts against the 256-page (1 MiB) bound,
--
-- * the new record-tree pages (a copy of each changed path, splits, a new root);
-- * one retirement list page naming every committed record-tree page it replaced;
-- * the retirement tree pages that insert that entry's key; and
-- * the allocator tree pages that remove the pages the plan took.
--
-- It takes @d + 1 + 'bookkeepingReserve'@ pages from the supply (loose pages first,
-- then free extents lowest first, then the untouched tail), writes the pages it
-- needs and returns the rest as loose pages; so the allocator's own updates never
-- need a fixed point and never overwrite a page of the committed roots. The
-- committed bookkeeping pages it replaced become loose; the committed record pages
-- it replaced are retired.
--
-- = Memory accounting
--
-- The RAM a plan reserves (at most 4 MiB, 'ramTotal') is the memory it really holds,
-- by component. The window keeps validated page /buffers/ (4 KiB and a small header
-- each, at most 1.25 MiB, 'maxWindowBytes'): entries are parsed from a buffer when a
-- node is visited, never held as lists. The new pages a plan builds are held packed
-- (their entries as one byte string, at most 'overlayBudgetRecord' and
-- 'overlayBudgetBookkeeping' while it works, at most 256 pages' worth when it ends)
-- except for a few recently used nodes kept parsed ('hotNodes' per tree edit, each
-- accounted at 'hotNodeBytes'). The encoded output is 4 KiB a written page. The
-- control header is charged at its fixed record size: the discovery header's byte
-- total counts the retained /history/, which lives in pages, and is not resident
-- transaction memory.
--
-- = Reclamation
--
-- 'planReclaim' frees the pages of the oldest retirement entry once every reader
-- pinned before the entry's version has released, in chunks of at most
-- 'maxReclaimPages', under the same bounds. It is a maintenance transaction: it
-- may spend the protected reserve.
--
-- State, ownership and lifetime: none. Pure functions over immutable values.
module Hetoimasia.Terrain.Runtime.Store.Internal.Plan
  ( -- * Results
    TxClass (..)
  , PlanKind (..)
  , PlanIdentity (..)
  , Effects (..)
  , RamCharge (..)
  , ramTotal
  , Measure (..)
  , Plan (..)
  , Planned (..)
  , PlanRefusal (..)
  , StaleWhy (..)
  , InvalidWhy (..)
  , CapacityWhy (..)
  , IntegrityWhy (..)
  , shrinkable
  , fingerprintOf

    -- * Planning
  , Bounds (..)
  , standardBounds
  , Delta (..)
  , deltaOf
  , planCandidate
  , planDelta
  , planDeltaWith
  , planDeltaPinned
  , planReclaimWith
  , planReclaimPinned
  , planReclaim
  , freePool
  , availablePages

    -- * Reads through the window
  , providerFor
  , missingPage
  , lookupRecord
  , floorRun
  , RangeStart (..)
  , rangeRecords
  , refusalToPlan
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Control.Monad (foldM)
import Data.Int (Int64)
import Data.List (nub, sort)
import Data.Maybe (isNothing)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word16, Word32, Word64)
import Hetoimasia.Terrain.Cell (Column)
import Hetoimasia.Terrain.Discovery
  ( Authority (..)
  , Candidate
  , Fetch (..)
  , Header (..)
  , headerBytes
  , Integrity
  , Provider (..)
  , Record (..)
  , RecordKey (..)
  , Refusal (..)
  , Report (..)
  , candidateBase
  , candidateKnowledge
  , candidateNext
  , candidateReport
  , candidateTerrain
  , candidateWrites
  , maxBatchUpdates
  )
import Hetoimasia.Terrain.Residency (Revision (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Page
import Hetoimasia.Terrain.Runtime.Store.Internal.Records
import Hetoimasia.Terrain.Runtime.Store.Internal.State
import Hetoimasia.Terrain.Runtime.Store.Internal.Tree

-- ---------------------------------------------------------------------------
-- Results

-- | Who a transaction is. An ordinary transaction (an edit or a discovery batch)
-- cannot spend the protected reserve; maintenance (reclamation) can.
data TxClass = Ordinary | Maintenance
  deriving stock (Eq, Show)

data PlanKind = KindCandidate | KindReclaim
  deriving stock (Eq, Show)

-- | What a plan was made against: the store, the committed version and the
-- authority the discovery header named. Publication requires exactly this.
data PlanIdentity = PlanIdentity
  { pidStore ∷ !StoreIdentity
  , pidBaseVersion ∷ !Word64
  , pidBase ∷ !Authority
  }
  deriving stock (Eq, Show)

-- | What publishing the plan changes for the later owner: terrain (the content
-- revision), knowledge (the knowledge revision), or frontier or maintenance only
-- (the store revision), with the authority once published.
data Effects = Effects
  { effTerrain ∷ !Bool
  , effKnowledge ∷ !Bool
  , effFrontier ∷ !Bool
  , effAuthority ∷ !Authority
  , effVersion ∷ !Word64
  }
  deriving stock (Eq, Show)

-- | The RAM one transaction reserves, by component. Every buffer, window page, new page held packed, key,
-- scratch, page pin, root or control record and retained continuation is counted.
data RamCharge = RamCharge
  { ramIoBuffers ∷ !Int
  , ramDecodedCopies ∷ !Int
  , ramKeys ∷ !Int
  , ramScratch ∷ !Int
  , ramPagePins ∷ !Int
  , ramRootControl ∷ !Int
  , ramContinuation ∷ !Int
  }
  deriving stock (Eq, Show)

ramTotal ∷ RamCharge → Int
ramTotal r = ramIoBuffers r + ramDecodedCopies r + ramKeys r + ramScratch r + ramPagePins r + ramRootControl r + ramContinuation r

-- | What a plan measured: the evidence of the bounds.
data Measure = Measure
  { mPagesWritten ∷ !Int
  , mRecordPages ∷ !Int
  , mBookkeepingPages ∷ !Int
  , mListPages ∷ !Int
  , mReplacedRecord ∷ !Int
  , mReplacedBookkeeping ∷ !Int
  , mSlack ∷ !Int
  , mClaimed ∷ !Int
  , mLooseTaken ∷ !Int
  , mReadSteps ∷ !Int
  , mWindowPages ∷ !Int
  , mRam ∷ !RamCharge
  , mUpdates ∷ !Int
  , mRecordWrites ∷ !Int
  , mFreed ∷ !Int
  }
  deriving stock (Eq, Show)

-- | A complete candidate transaction.
data Plan = Plan
  { plIdentity ∷ !PlanIdentity
  , plClass ∷ !TxClass
  , plKind ∷ !PlanKind
  , plPages ∷ [(PageNo, ByteString)]
  , plNext ∷ !Roots
  , plEffects ∷ !Effects
  , plMeasure ∷ !Measure
  }
  deriving stock (Eq, Show)

-- | The result of planning.
data Planned
  = Planned !Plan
  | -- | Nothing to do: the candidate changes no page and no header, or there is
    -- nothing to reclaim.
    NoWork
  | -- | The oldest retirement entry is still held by a reader: its version and the
    -- oldest pinned version.
    BlockedByReader !Word64 !Word64
  | -- | A page the plan needs is not in the window: fetch it, add it and plan
    -- again from the same window.
    Pending !PageNo
  | -- | Pages the plan has to classify are not in the window: read each, 'windowProbe' it
    -- (never 'windowInsert': it may not be a page at all) and plan again from the same
    -- window. The plan is about to overwrite or free these pages and must first prove that
    -- no owner but the allocator claims them. All of the missing ones are named at once, so
    -- the plan is not rerun for each.
    PendingProbes ![PageNo]
  | -- | The plan's window filled while it was proving that the pages it is about to overwrite or free are
    -- owned by nobody but the allocator: the proofs made so far are read-only facts about the committed
    -- and pinned state. Build a fresh window of the same version with 'windowCheckpoint' (it keeps the
    -- facts, the work limit and the trust, and drops the pages and probes) and plan again: the plan does
    -- not repeat a proof it carries a fact for. A checkpoint always carries at least one new fact; a window
    -- that cannot hold the plan's edit and one proof is the typed 'WindowExceeded', never a checkpoint.
    Checkpoint !Facts
  | Refused !PlanRefusal
  deriving stock (Eq, Show)

data PlanRefusal
  = Stale !StaleWhy
  | Invalid !InvalidWhy
  | Capacity !CapacityWhy
  | Integrity !IntegrityWhy
  deriving stock (Eq, Show)

data StaleWhy
  = -- | The window was filled for another version: the window's, the committed one.
    StaleWindow !Word64 !Word64
  | -- | The window was made for another store (another arena or source).
    ForeignWindow
  | -- | The candidate was prepared against another authority: the candidate's, the
    -- store's.
    StaleAuthority !Authority !Authority
  deriving stock (Eq, Show)

data InvalidWhy
  = ForeignArena
  | InconsistentRevisions
  | RevisionArithmetic
  | TooManyUpdates !Int
  | MalformedWrite !RecordKey
  | VersionArithmetic
  | -- | #661's operation refused the request (a capacity or an authority overflow).
    DiscoveryRefusal !Refusal
  deriving stock (Eq, Show)

data CapacityWhy
  = -- | Not enough free allowance: pages needed, pages available and pages protected
    -- for reclamation.
    DiskFull !Word64 !Word64 !Word64
  | TxnPagesExceeded !Int
  | TxnRamExceeded !Int
  | WindowExceeded !Int
  | -- | The window holds more accounted bytes than a plan may: the figure.
    WindowBytesExceeded !Int
  | -- | The new pages of a plan would hold more accounted bytes than it may: the figure.
    OverlayExceeded !Int
  | TreeTooTall !TreeId
  | ListTooLarge !Int
  | -- | The window holds more page probes than a plan may: the figure.
    ProbesExceeded !Int
  | -- | Too much retirement is outstanding to prove a supply against it, or to add to:
    -- the entries and the retired pages they hold. A reader's pin holds them; a release
    -- and a maintenance transaction lower them.
    RetirementBacklog !Int !Int
  | -- | The allocator and retirement trees would need more pages than a plan may take for them: the
    -- figure. Every replaced record page is indexed in the retirement tree, so a batch that replaces
    -- many dispersed pages needs more; a smaller batch replaces fewer ('shrinkable').
    BookkeepingExceeded !Int
  deriving stock (Eq, Show)

-- | Whether a refusal says the batch was too big, so that a plan of a smaller batch can get past it: the
-- bounds on the pages, the RAM, the retired pages one transaction lists, the overlay, the window and the
-- probes, and the bookkeeping those need. Everything else (a full disk, a backlog that waits for a reader,
-- a tree too tall) a smaller batch does not change. An integrity result is never shrinkable.
shrinkable ∷ PlanRefusal → Bool
shrinkable (Capacity c) = case c of
  TxnPagesExceeded _ → True
  TxnRamExceeded _ → True
  ListTooLarge _ → True
  OverlayExceeded _ → True
  WindowExceeded _ → True
  WindowBytesExceeded _ → True
  ProbesExceeded _ → True
  BookkeepingExceeded _ → True
  _ → False
shrinkable _ = False

data IntegrityWhy
  = BadPage !PageError !PageNo
  | BrokenInvariant !TreeId
  | CorruptCounters
  | DoubleFree !PageNo
  | -- | A retirement entry names a page a committed or pinned tree still reaches, a list
    -- page, a bookkeeping page or a page outside the used space.
    RetiredPageLive !PageNo
  | -- | A page the allocator supplied for a write is reachable from a committed or a
    -- pinned root, or the allocator's records contradict each other: writing it would
    -- destroy a page a reader can still read, so nothing is written.
    SuppliedPageLive !PageNo
  | -- | A page the allocator supplied for a write is still owned by an outstanding
    -- retirement entry (the version of the entry): no root reaches it, but its retirement
    -- obligation has not been consumed.
    SuppliedPageRetired !PageNo !Word64
  | -- | A page taken from the loose list is also a free extent: it would have two owners.
    SuppliedPageDoubleOwned !PageNo
  | -- | A retirement entry frees a page its index does not record under the entry's version.
    RetiredIndexMismatch !PageNo
  | MalformedRetirement
  | LooseOverflow !Int
  | -- | #661's records are not a legitimate state.
    DiscoveryCorrupt !Integrity
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Bounds

-- | The bounds of one transaction: the pages it writes, the RAM it reserves and the
-- validated page bytes its continuation holds. The format fixes 'standardBounds'; the suite
-- plans under tighter ones to reach the refusals and the shrinking of a batch that
-- the standard ones allow only at a scale no routine test reaches.
data Bounds = Bounds
  { bdPages ∷ !Int
  , bdRamBytes ∷ !Int
  , bdWindowPages ∷ !Int
  , bdWindowBytes ∷ !Int
  , bdReserve ∷ !Int
  -- ^ the bookkeeping pages a candidate plan first asks for ('bookkeepingReserve' in production)
  , bdReserveMax ∷ !Int
  -- ^ the most it may ask for after counting ('maxBookkeepingPages' in production)
  }
  deriving stock (Eq, Show)

-- | 256 pages (1 MiB of new encoded pages), 4 MiB of RAM, 512 window pages and 1.25 MiB
-- of window bytes.
standardBounds ∷ Bounds
standardBounds = Bounds maxTxnPages txnRamLimit maxWindowPages maxWindowBytes bookkeepingReserve maxBookkeepingPages

-- ---------------------------------------------------------------------------
-- The planning monad

data Out = OutNeed !PageNo | OutProbes ![PageNo] | OutRefuse !PlanRefusal | OutMoreBookkeeping !Int | OutCheckpoint !Facts

type P a = Either Out a

phase ∷ Edit → M a → P (a, Edit)
phase e m = case runM m e of
  Left (Need p) → Left (OutNeed p)
  Left (Bad err p) → Left (OutRefuse (Integrity (BadPage err p)))
  Left (TooTall t) → Left (OutRefuse (Capacity (TreeTooTall t)))
  Left (Over n) → Left (OutRefuse (Capacity (OverlayExceeded n)))
  Left (Invariant t) → Left (OutRefuse (Integrity (BrokenInvariant t)))
  Right r → Right r

refuse ∷ PlanRefusal → P a
refuse = Left . OutRefuse

settle ∷ P (Maybe Plan) → Planned
settle (Right (Just p)) = Planned p
settle (Right Nothing) = NoWork
settle (Left (OutNeed p)) = Pending p
settle (Left (OutProbes ps)) = PendingProbes ps
settle (Left (OutRefuse r)) = Refused r
settle (Left (OutMoreBookkeeping n)) = Refused (Capacity (BookkeepingExceeded n))
settle (Left (OutCheckpoint f)) = Checkpoint f

-- ---------------------------------------------------------------------------
-- Capacity

-- | Free pages the allocator can hand out: the free extents and the untouched
-- tail (loose pages, held by the root set, are counted separately).
freePool ∷ StoreConfig → Roots → Word64
freePool cfg r = rFreePages r + (cfgUsablePages cfg - min (cfgUsablePages cfg) (rHw r))

-- | The pages an ordinary plan may take: the free pool less the protected reserve.
availablePages ∷ StoreConfig → TxClass → Roots → Word64
availablePages cfg Ordinary r = let p = freePool cfg r in if p > reservePages then p - reservePages else 0
availablePages cfg Maintenance r = freePool cfg r

-- ---------------------------------------------------------------------------
-- The supply

data Take = Take
  { tkPages ∷ [PageNo]
  , tkLoose ∷ !Int
  , tkExtents ∷ [(Word64, Word64, Word64)]
  , tkBump ∷ !Word64
  }

-- | The first @m@ pages the allocator hands out: loose pages, then free extents
-- lowest first (a bounded number of extent reads, each at most one per page
-- taken), then the untouched tail. 'Nothing' when the supply is short.
takeSupply ∷ StoreConfig → Roots → Int → M (Maybe Take)
takeSupply cfg roots m = do
  let loose = take m (rLoose roots)
      nl = length loose
      needFree = m - nl
  -- every loose page this supply takes lies inside the used page space, as every page the
  -- store ever numbered does, and none is listed twice: a page further down the list is
  -- checked when it reaches the front, so what is read is bounded by the supply, not by the
  -- list
  let looseSet = Set.fromList loose
  if any (\(PageNo p) → p >= rHw roots) loose || Set.size looseSet /= length loose then failInvariant TreeFree else pure ()
  (extents, got) ← if needFree <= 0 then pure ([], 0) else readExtents (fmap Disk (rFree roots)) needFree
  let remaining = needFree - fromIntegral got
      tailPages = cfgUsablePages cfg - min (cfgUsablePages cfg) (rHw roots)
  if remaining > 0 && fromIntegral remaining > tailPages
    then pure Nothing
    else do
      let bump = fromIntegral (max 0 remaining) ∷ Word64
          freePagesList = concat [[PageNo (s + i) | i ← [0 .. t - 1]] | (s, _, t) ← extents]
          tailList = [PageNo (rHw roots + i) | bump > 0, i ← [0 .. bump - 1]]
          supply = loose ++ freePagesList ++ tailList
      -- no page may be handed out twice: free extents never overlap each other, the loose
      -- list or the untouched tail, whatever the pages they were read from claim
      if Set.size (Set.fromList supply) /= length supply then failInvariant TreeFree else pure ()
      -- nor is a free page also loose, whether or not the loose page is in this supply
      if any (`Set.member` looseSet) freePagesList then failInvariant TreeFree else pure ()
      pure (Just (Take supply nl extents bump))
  where
    readExtents root need = go root need (BS.empty, False) 0 []
    -- Each extent lies inside the used page space and past the end of the one before.
    go root need (from, strict) prevEnd acc
      | need <= 0 = pure (reverse acc, sum [t | (_, _, t) ← acc])
      | otherwise = do
          r ← ceilKey TreeFree strict root from
          case r of
            Nothing → pure (reverse acc, sum [t | (_, _, t) ← acc])
            Just (k, v) → case decodeFree maxBound k v of
              Nothing → failInvariant TreeFree
              Just (s, l)
                | s < prevEnd || s + l > rHw roots → failInvariant TreeFree
                | otherwise →
                    let t = min l (fromIntegral need)
                     in go root (need - fromIntegral t) (k, True) (s + l) ((s, l, t) : acc)

-- | Remove the taken pages from the allocator tree: a whole extent is deleted, the
-- last one is shortened.
consume ∷ Maybe Ref → Take → M (Maybe Ref)
consume root0 tk = foldl' step (pure root0) (tkExtents tk)
  where
    step acc (s, l, t) = do
      root ← acc
      let (k, _) = encodeFree s l
      root' ← deleteKey TreeFree root k
      if t == l
        then pure root'
        else let (k', v') = encodeFree (s + t) (l - t) in insertKey TreeFree root' k' v'

-- | Whether any of the freed pages is already accounted for: free in the committed
-- allocator tree, loose, or claimed by this very plan's supply. Freeing such a page
-- would give it two owners.
overlapOf ∷ Maybe Ref → Set.Set PageNo → [PageNo] → M (Maybe PageNo)
overlapOf root taken pages = go (runsOf pages)
  where
    go [] = pure Nothing
    go ((s, n) : rest)
      | any (\i → Set.member (PageNo (s + i)) taken) [0 .. n - 1] = pure (Just (PageNo s))
      | otherwise = do
          before ← floorKey TreeFree root (be64 s) >>= neighbour
          after ← ceilKey TreeFree False root (be64 s) >>= neighbour
          case (before, after) of
            (Just (ps, pl), _) | ps + pl > s → pure (Just (PageNo s))
            (_, Just (ns, _)) | ns < s + n → pure (Just (PageNo s))
            _ → go rest

-- | A free extent read as a neighbour: one that does not decode is corruption, never
-- the absence of a neighbour.
neighbour ∷ Maybe (ByteString, ByteString) → M (Maybe (Word64, Word64))
neighbour Nothing = pure Nothing
neighbour (Just (k, v)) = maybe (failInvariant TreeFree) (pure . Just) (decodeFree maxBound k v)

-- | Add freed pages as extents, merging with the neighbours that touch them and
-- refusing a page that is already free.
insertFreed ∷ Word64 → Maybe Ref → [PageNo] → M (Either PageNo (Maybe Ref))
insertFreed hw root0 pages = go root0 (runsOf pages)
  where
    go root [] = pure (Right root)
    go root ((s, n) : rest)
      | s + n > hw = pure (Left (PageNo s))
      | otherwise = do
          before ← floorKey TreeFree root (be64 s) >>= neighbour
          after ← ceilKey TreeFree False root (be64 s) >>= neighbour
          case (before, after) of
            (Just (ps, pl), _) | ps + pl > s → pure (Left (PageNo s))
            (_, Just (ns, _)) | ns < s + n → pure (Left (PageNo s))
            (b, a) → do
              let (start, root1m) = case b of
                    Just (ps, pl) | ps + pl == s → (ps, deleteKey TreeFree root (be64 ps))
                    _ → (s, pure root)
              r1 ← root1m
              let (len1, root2m) = case a of
                    Just (ns, nl) | ns == s + n → (n + nl + (s - start), deleteKey TreeFree r1 (be64 ns))
                    _ → (n + (s - start), pure r1)
              r2 ← root2m
              let (k, v) = encodeFree start len1
              r3 ← insertKey TreeFree r2 k v
              go r3 rest

runsOf ∷ [PageNo] → [(Word64, Word64)]
runsOf = foldr add []
  where
    add (PageNo p) ((s, n) : rest) | p + 1 == s = (p, n + 1) : rest
    add (PageNo p) acc = (p, 1) : acc

-- | The record roots a reader pins, for a tree: none for a bookkeeping tree, which no
-- reader reads.
pinRootFor ∷ TreeId → Pins → Maybe PageNo
pinRootFor TreeRuns = pinRuns
pinRootFor TreeLinks = pinLinks
pinRootFor TreeTodo = pinTodo
pinRootFor _ = const Nothing

-- | Prove that none of the pages is reachable from the committed roots or from any
-- pinned reader's roots, by the one test the store has for it: a page that is
-- reachable at all is on the path of its own first key, so each page is classified
-- from a probe (never swept for) and looked for at the one place it could be.
--
-- * a page that does not decode as a page of this store at that number is reachable
--   from nowhere: it could never have been read;
-- * a tree page is looked for at its level on the path of its first key in the
--   committed tree it belongs to and, for a record tree, in each pinned tree (at most
--   'maxReaders', each at most 'maxLevel' + 1 steps);
-- * a retirement list is looked for under the version it is stamped with in the
--   committed retirement tree.
--
-- A page found is refused with the given constructor, and a page whose probe is not
-- in the window is asked for. The work is bounded by the pages given and the readers.
unreachable ∷ Bounds → Fingerprint → StoreConfig → Roots → [Pins] → (PageNo → IntegrityWhy) → (PageNo → Fact) → Window → [PageNo] → Edit → P Edit
unreachable bounds fp cfg roots pins why mk win pages edit0 =
  case [pg | pg ← pages, not (windowKnows (mk pg) win), isNothing (windowProbeOf pg win)] of
    missing@(_ : _) → Left (OutProbes missing)
    [] → proving bounds fp win mk one pages edit0
  where
    total = cfgTotalPages cfg
    one pg edit = case windowProbeOf pg win of
      Nothing → Left (OutProbes [pg])
      Just ProbeNone → Right edit
      Just (ProbeList v) → do
        (mv, edit') ← phase edit (lookupKey TreeRetire (fmap Disk (rRetire roots)) (be64 v))
        case mv >>= decodeRetire total (be64 v) of
          Just (_, ret) | retList ret == pg → refuse (Integrity (why pg))
          _ → Right edit'
      Just (ProbeTree tree level key) →
        let rootsOf = nub (rootOf roots tree : [pinRootFor tree p | p ← pins, isRecordTree tree])
         in foldM (\e r → do
                      (found, e') ← phase e (livePageAt tree (fmap Disk r) key level)
                      if found == Just pg then refuse (Integrity (why pg)) else Right e') edit rootsOf

-- | What a window must hold to take one more page: it would outgrow its page or byte bound.
windowFull ∷ Bounds → Window → Bool
windowFull bounds win =
  windowSize win + 1 > bdWindowPages bounds || windowBytes win + pageSize + windowPageOverhead > bdWindowBytes bounds

-- | The state facts are proven against: what a window trusts them for (and nothing else).
fingerprintOf ∷ StoreIdentity → Roots → [Pins] → Fingerprint
fingerprintOf ident roots pins = Fingerprint ident (rVersion roots) (rootTrust roots) (sort [(pinVersion p, pinTrust p) | p ← pins])

-- | The proofs a plan makes about pages, each a unit of its own that becomes a fact once made: a page the
-- window already carries the fact for is skipped, and a proof that needs a page the window can no longer hold
-- ends the call with a 'Checkpoint' of the facts made so far (in this call, across every kind of proof), so
-- that a retry through a fresh window repeats none of them and holds at once only what the plan edits and ONE
-- proof. A proof is a function of the committed and the pinned state alone: every lookup it makes starts from
-- a committed root ('Disk'), never from a root the plan is staging, so it is the same before the plan stages
-- its edits and after. No checkpoint carries no new fact: a window that cannot hold the edit and one proof
-- is the typed window result.
proving ∷ Bounds → Fingerprint → Window → (PageNo → Fact) → (PageNo → Edit → P Edit) → [PageNo] → Edit → P Edit
proving bounds fp win mk prove pages edit0 = go edit0 pages
  where
    go edit [] = Right edit
    go edit (pg : rest)
      | windowKnows (mk pg) win = go edit rest
      | otherwise = case prove pg edit of
          Right edit' → go (recordFact (mk pg) edit') rest
          Left (OutNeed _) | windowFull bounds win → checkpoint edit
          Left o → Left o
    checkpoint edit = case editFacts edit of
      [] → Left (OutRefuse (Capacity (if windowSize win + 1 > bdWindowPages bounds then WindowExceeded (windowSize win) else WindowBytesExceeded (windowBytes win))))
      fs → Left (OutCheckpoint (Facts fp fs))

-- | The one proof of ownership every page a plan is about to overwrite passes, against
-- every owner there is: the committed trees and every pinned reader's tree and the
-- retirement lists ('unreachable'), the retirement tree's index of retired pages (a page a
-- retirement entry still owns), the free extents (for a page taken from the loose list)
-- and the supply itself (checked when the supply is taken). A page offered by the allocator
-- is refused unless no owner but the allocator claims it, and nothing is written.
-- @fromLoose@ are the pages taken from the loose list.
provenFree ∷ Bounds → Fingerprint → StoreConfig → Roots → [Pins] → Window → Set.Set PageNo → [PageNo] → Edit → P Edit
provenFree bounds fp cfg roots pins win fromLoose pages edit0 = do
  edit1 ← unreachable bounds fp cfg roots pins SuppliedPageLive FactUnreachable win pages edit0
  edit2 ← proving bounds fp win FactNotRetired notRetired pages edit1
  proving bounds fp win FactNotFree looseNotFree [pg | pg ← pages, Set.member pg fromLoose] edit2
  where
    notRetired pg edit = do
      (mv, edit') ← phase edit (lookupKey TreeRetire (fmap Disk (rRetire roots)) (retiredKey pg))
      case mv of
        Just v → refuse (Integrity (SuppliedPageRetired pg (getBe64 v 0)))
        Nothing → Right edit'
    looseNotFree pg@(PageNo n) edit = do
      (mext, edit') ← phase edit (floorKey TreeFree (fmap Disk (rFree roots)) (be64 n) >>= neighbour)
      case mext of
        Just (s, l) | s <= n && n < s + l → refuse (Integrity (SuppliedPageDoubleOwned pg))
        _ → Right edit'

isRecordTree ∷ TreeId → Bool
isRecordTree t = t == TreeRuns || t == TreeLinks || t == TreeTodo

-- ---------------------------------------------------------------------------
-- Candidates

-- | What a plan applies: the authority it was prepared against, the control header
-- once applied, which revisions it advances, how many structural updates it holds
-- and its record writes. A #661 candidate is one 'Delta'.
data Delta = Delta
  { dlBase ∷ !Authority
  , dlNext ∷ !Header
  , dlTerrain ∷ !Bool
  , dlKnowledge ∷ !Bool
  , dlUpdates ∷ !Int
  , dlWrites ∷ [(RecordKey, Maybe Record)]
  }
  deriving stock (Eq, Show)

-- | The delta a #661 candidate carries.
deltaOf ∷ Candidate → Delta
deltaOf c =
  Delta
    { dlBase = candidateBase c
    , dlNext = candidateNext c
    , dlTerrain = candidateTerrain c
    , dlKnowledge = candidateKnowledge c
    , dlUpdates = reportUpdates (candidateReport c)
    , dlWrites = candidateWrites c
    }

-- | Plan a #661 candidate against the committed roots. The window must have been
-- filled for exactly this version and hold at most 'maxWindowPages' pages.
planCandidate ∷ StoreConfig → StoreIdentity → Roots → Window → TxClass → Candidate → Planned
planCandidate cfg ident roots win cls = planDelta cfg ident roots win cls . deltaOf

-- | Plan one delta: the checks of authority and revision arithmetic, the record
-- writes applied to the three record trees, and the retirement and allocator
-- bookkeeping, under every bound. This is the entry the candidate functions share
-- and the one the suite drives with arbitrary writes.
planDelta ∷ StoreConfig → StoreIdentity → Roots → Window → TxClass → Delta → Planned
planDelta = planDeltaWith standardBounds

-- | 'planDelta' under given bounds.
planDeltaWith ∷ Bounds → StoreConfig → StoreIdentity → Roots → Window → TxClass → Delta → Planned
planDeltaWith bounds cfg ident roots = planDeltaPinned bounds cfg ident roots []

-- | 'planDeltaWith' while readers pin older versions: the record roots they pin. A
-- page the plan is about to write is proven unreachable from the committed roots and
-- from every one of these before it is numbered into the plan.
planDeltaPinned ∷ Bounds → StoreConfig → StoreIdentity → Roots → [Pins] → Window → TxClass → Delta → Planned
planDeltaPinned bounds cfg ident roots pins win0 cls cand = settle $ do
  let fp = fingerprintOf ident roots pins
      win = windowFactsFor fp (windowTrust (rootTrust roots ++ concatMap pinTrust pins) (windowBelow (rHw roots) win0))
  checkWindow bounds ident roots win
  checkCounters roots
  let base = dlBase cand
      hdr = rHeader roots
      next = dlNext cand
  if authArena base /= siArena ident then refuse (Invalid ForeignArena) else pure ()
  if base /= hAuthority hdr then refuse (Stale (StaleAuthority base (hAuthority hdr))) else pure ()
  if dlUpdates cand > maxBatchUpdates then refuse (Invalid (TooManyUpdates (dlUpdates cand))) else pure ()
  expected ← maybe (refuse (Invalid RevisionArithmetic)) pure (nextAuthority base (dlTerrain cand) (dlKnowledge cand))
  if hAuthority next /= expected then refuse (Invalid InconsistentRevisions) else pure ()
  version' ← maybe (refuse (Invalid VersionArithmetic)) pure (bumpWord (rVersion roots))
  -- The worst-case claim is reserved before any work, so that an edit that cannot
  -- fit is refused before it changes anything.
  let worstClaim = fromIntegral maxClaimPages ∷ Word64
  if cls == Ordinary && freePool cfg roots < worstClaim + reservePages
    then refuse (Capacity (DiskFull worstClaim (freePool cfg roots) reservePages))
    else pure ()
  writes ← canonicalWrites (dlWrites cand)
  -- The record trees.
  let edit0 = newEdit overlayBudgetRecord win
      roots0 = (fmap Disk (rRuns roots), fmap Disk (rLinks roots), fmap Disk (rTodo roots))
  (rootsRec, edit1) ← applyWrites edit0 roots0 writes
  let (rr, rl, rt) = rootsRec
      d = freshCount edit1 [rr, rl, rt]
      replacedRec = Set.toAscList (editReplaced edit1)
      listN = length replacedRec
      needRetire = listN > 0
  if listN > maxListPages then refuse (Capacity (ListTooLarge listN)) else pure ()
  -- the backlog of retired pages is bounded: an ordinary plan that would add past it waits
  -- for a reader to release and for maintenance to reclaim
  if cls == Ordinary && toInteger (rRetiredPages roots) + toInteger listN > toInteger maxRetiredPages
    then refuse (Capacity (RetirementBacklog (fromIntegral (min (toInteger (maxBound ∷ Int)) (toInteger (rRetiredPages roots)))) listN))
    else pure ()
  if d == 0 && not needRetire
    then
      if next == hdr
        then pure Nothing
        else Just <$> headerOnly cfg ident roots cls cand next version' edit1 writes
    else
      let attempt rsv = do
            let m = d + (if needRetire then 1 else 0) + rsv
            -- The supply.
            (mtake, bkEdit0) ← phase (newEdit overlayBudgetBookkeeping win) (takeSupply cfg roots m)
            tk ← maybe (refuse (Capacity (DiskFull (fromIntegral m) (freePool cfg roots + fromIntegral (length (rLoose roots))) (protectedFor cls)))) pure mtake
            let claim = fromIntegral m - fromIntegral (tkLoose tk) ∷ Word64
            if freePool cfg roots < claim + protectedFor cls
              then refuse (Capacity (DiskFull claim (freePool cfg roots) (protectedFor cls)))
              else pure ()
            let supply = tkPages tk
            (pagesRec, recNos, afterRec) ← assign ident edit1 [rr, rl, rt] supply
            (listPage, afterList) ← case (needRetire, afterRec) of
              (True, lp : more) → Right (Just lp, more)
              (True, []) → refuse (Integrity CorruptCounters)
              (False, _) → Right (Nothing, afterRec)
            let retireRoot0 = fmap Disk (rRetire roots)
            (retireRoot1, bkEdit1) ← case listPage of
              Nothing → pure (retireRoot0, bkEdit0)
              Just lp → do
                let (k, v) = encodeRetire version' (Retire lp (fromIntegral listN) 0)
                (entryRoot, entryEdit) ← phase bkEdit0 (insertKey TreeRetire retireRoot0 k v)
                -- every replaced page is indexed by its number under this entry's version; a page
                -- already indexed is owned by two entries
                foldM (indexRetired version') (entryRoot, entryEdit) replacedRec
            (freeRoot1, bkEdit2) ← phase bkEdit1 (consume (fmap Disk (rFree roots)) tk)
            -- the pages the allocator and retirement edit really needs, counted before any is numbered: more
            -- than the supply asks for a larger one (below), never a failed numbering
            let bkNeed = freshCount bkEdit2 [retireRoot1, freeRoot1]
            if bkNeed > length afterList then Left (OutMoreBookkeeping bkNeed) else pure ()
            (pagesBk, bkNos, slack) ← assign ident bkEdit2 [retireRoot1, freeRoot1] afterList
            let bkUsed = length pagesBk
            listPages ← traverse (\lp → encodeOut ident (Page TreeRetire 0 lp (List version' replacedRec))) (maybe [] pure listPage)
            let encoded = pagesRec ++ listPages ++ pagesBk
                written = length encoded
            if written > bdPages bounds then refuse (Capacity (TxnPagesExceeded written)) else pure ()
            -- No page may be overwritten that a committed or a pinned root still reaches,
            -- whatever the allocator's records say: the pages below the used space that this
            -- plan writes are each proven unreachable first.
            bkEdit3 ← provenFree bounds fp cfg roots pins win (Set.fromList (take (tkLoose tk) (tkPages tk))) [pg | (pg@(PageNo n), _) ← encoded, n < rHw roots] bkEdit2
            (rr', rl', rt') ← case recNos of
              [a, b, c] → Right (a, b, c)
              _ → refuse (Integrity CorruptCounters)
            (retire', free') ← case bkNos of
              [a, b] → Right (a, b)
              _ → refuse (Integrity CorruptCounters)
            let replBk = Set.toAscList (editReplaced bkEdit3)
                used = fromIntegral written ∷ Integer
                live' = toInteger (rLivePages roots) + used - toInteger listN - toInteger (length replBk)
                retired' = toInteger (rRetiredPages roots) + toInteger listN
                freeTaken = sum [t | (_, _, t) ← tkExtents tk]
                free'' = toInteger (rFreePages roots) - toInteger freeTaken
                loose' = drop (tkLoose tk) (rLoose roots) ++ slack ++ replBk
            if live' < 0 || free'' < 0 then refuse (Integrity CorruptCounters) else pure ()
            if length loose' > looseCap then refuse (Integrity (LooseOverflow (length loose'))) else pure ()
            let next' =
                  roots
                    { rVersion = version'
                    , rRuns = rr'
                    , rLinks = rl'
                    , rTodo = rt'
                    , rFree = free'
                    , rRetire = retire'
                    , rHeader = next
                    , rHw = rHw roots + tkBump tk
                    , rFreePages = fromInteger free''
                    , rLivePages = fromInteger live'
                    , rRetiredPages = fromInteger retired'
                    , rLoose = loose'
                    , rRootCrcs = rootCrcsAfter roots encoded [(TreeRuns, rr'), (TreeLinks, rl'), (TreeTodo, rt'), (TreeFree, free'), (TreeRetire, retire')]
                    }
                windowN = windowSize win
                steps = editSteps edit1 + editSteps bkEdit3
                ram = ramFor windowN (windowBytes win + windowProbeBytes win) (editFreshBytes edit1 + editFreshBytes bkEdit3) written (length writes) (listN + length replBk) m
            if ramTotal ram > bdRamBytes bounds then refuse (Capacity (TxnRamExceeded (ramTotal ram))) else pure ()
            let measure =
                  Measure
                    { mPagesWritten = written
                    , mRecordPages = length pagesRec
                    , mBookkeepingPages = bkUsed
                    , mListPages = length listPages
                    , mReplacedRecord = listN
                    , mReplacedBookkeeping = length replBk
                    , mSlack = length slack
                    , mClaimed = fromIntegral claim
                    , mLooseTaken = tkLoose tk
                    , mReadSteps = steps
                    , mWindowPages = windowN
                    , mRam = ram
                    , mUpdates = dlUpdates cand
                    , mRecordWrites = length writes
                    , mFreed = 0
                    }
            pure (Just (finishPlan ident cls KindCandidate base next' cand encoded measure expected version'))
          -- a short reserve is answered by a larger supply, a bounded number of times, then by a shrinkable
          -- capacity result: a legitimate batch is never reported as corruption
          retry ∷ Int → Int → P (Maybe Plan)
          retry fuel rsv = case attempt rsv of
            Left (OutMoreBookkeeping need)
              | need > bdReserveMax bounds → refuse (Capacity (BookkeepingExceeded need))
              -- the pages a plan writes are bounded for a transaction: a plan that needs more is too big
              | d + (if needRetire then 1 else 0) + need > bdPages bounds → refuse (Capacity (TxnPagesExceeded (d + (if needRetire then 1 else 0) + need)))
              | fuel > 0 → retry (fuel - 1) (min (bdReserveMax bounds) (need + bookkeepingSlack))
              | otherwise → refuse (Capacity (BookkeepingExceeded need))
            r → r
       in retry (3 ∷ Int) (bdReserve bounds)
  where
    protectedFor Ordinary = reservePages
    protectedFor Maintenance = 0
    indexRetired ver (root, edit) pg = do
      (existing, edit1) ← phase edit (lookupKey TreeRetire root (retiredKey pg))
      case existing of
        Just _ → refuse (Integrity (DoubleFree pg))
        Nothing → phase edit1 (insertKey TreeRetire root (retiredKey pg) (be64 ver))

headerOnly ∷ StoreConfig → StoreIdentity → Roots → TxClass → Delta → Header → Word64 → Edit → [(RecordKey, Maybe Record)] → P Plan
headerOnly _ ident roots cls cand next version' edit writes = do
  let base = dlBase cand
      expected = hAuthority next
      next' = roots {rVersion = version', rHeader = next}
      ram = ramFor 0 (windowBytes win0) 0 0 (length writes) 0 0
      win0 = editWindow edit
      measure =
        Measure 0 0 0 0 0 0 0 0 0 (editSteps edit) 0 ram (dlUpdates cand) (length writes) 0
  pure (finishPlan ident cls KindCandidate base next' cand [] measure expected version')

finishPlan ∷ StoreIdentity → TxClass → PlanKind → Authority → Roots → Delta → [(PageNo, ByteString)] → Measure → Authority → Word64 → Plan
finishPlan ident cls kind base next' cand pages measure expected version' =
  Plan
    { plIdentity = PlanIdentity ident (version' - 1) base
    , plClass = cls
    , plKind = kind
    , plPages = pages
    , plNext = next'
    , plEffects =
        Effects
          { effTerrain = dlTerrain cand
          , effKnowledge = dlKnowledge cand
          , effFrontier = not (dlTerrain cand) && not (dlKnowledge cand)
          , effAuthority = expected
          , effVersion = version'
          }
    , plMeasure = measure
    }

-- | Number and encode a plan's new pages, one at a time.
assign ∷ StoreIdentity → Edit → [Maybe Ref] → [PageNo] → P ([(PageNo, ByteString)], [Maybe PageNo], [PageNo])
assign ident e roots supply = case assignPages (encodePage ident) e roots supply of
  Left (Invariant t) → refuse (Integrity (BrokenInvariant t))
  Left (Bad err p) → refuse (Integrity (BadPage err p))
  Left _ → refuse (Integrity CorruptCounters)
  Right r → Right r

encodeOut ∷ StoreIdentity → Page → P (PageNo, ByteString)
encodeOut ident page = case encodePage ident page of
  Left err → refuse (Integrity (BadPage err (pgNo page)))
  Right bs → let PageNo no = pgNo page in no `seq` BS.length bs `seq` Right (PageNo no, bs)

-- | The counters of a root set agree with each other and with what they count, exactly:
-- @hw = live + retired + free + loose@, a tree that has no root holds no page of its kind, and
-- a tree that has one holds at least one. A counter re-sealed to a figure the other three
-- and the loose list contradict is corruption at the next plan, whatever its sign; a
-- consistent forgery across two of them (a transfer between classes) keeps the identity and
-- can only change capacity decisions, never which page is overwritten, which the ownership
-- proof decides from the trees.
checkCounters ∷ Roots → P ()
checkCounters roots = do
  let total = toInteger (rLivePages roots) + toInteger (rRetiredPages roots) + toInteger (rFreePages roots) + toInteger (length (rLoose roots))
  if total /= toInteger (rHw roots) then refuse (Integrity CorruptCounters) else pure ()
  if (rFree roots == Nothing) /= (rFreePages roots == 0) then refuse (Integrity CorruptCounters) else pure ()
  if (rRetire roots == Nothing) /= (rRetiredPages roots == 0) then refuse (Integrity CorruptCounters) else pure ()
  -- an ordinary plan refuses to add past the backlog bound and maintenance only lowers it, so a store a plan wrote never
  -- retires more pages than the bound: the size of the retirement tree (and its internal pages) rests on this and on
  -- the minimum fill every page keeps
  if rRetiredPages roots > fromIntegral maxRetiredPages then refuse (Integrity CorruptCounters) else pure ()

-- | The checksums the roots a transaction publishes must carry: a root it wrote carries the checksum of
-- the page it just encoded, a root it left alone keeps the one the root record already held.
rootCrcsAfter ∷ Roots → [(PageNo, ByteString)] → [(TreeId, Maybe PageNo)] → [(TreeId, Word32)]
rootCrcsAfter roots encoded news =
  [ (t, c)
  | (t, Just no) ← news
  , Just c ← [maybe (lookup t (rRootCrcs roots)) (Just . pageCrcOf) (lookup no encoded)]
  ]

checkWindow ∷ Bounds → StoreIdentity → Roots → Window → P ()
checkWindow bounds ident roots win = do
  if windowIdentity win /= ident then refuse (Stale ForeignWindow) else pure ()
  if windowVersion win /= rVersion roots then refuse (Stale (StaleWindow (windowVersion win) (rVersion roots))) else pure ()
  if windowSize win > bdWindowPages bounds then refuse (Capacity (WindowExceeded (windowSize win))) else pure ()
  if windowBytes win > bdWindowBytes bounds then refuse (Capacity (WindowBytesExceeded (windowBytes win))) else pure ()
  if windowProbeCount win > maxWindowProbes then refuse (Capacity (ProbesExceeded (windowProbeCount win))) else pure ()

bumpWord ∷ Word64 → Maybe Word64
bumpWord w = if w == maxBound then Nothing else Just (w + 1)

nextAuthority ∷ Authority → Bool → Bool → Maybe Authority
nextAuthority (Authority arena (Revision c) (Revision k) (Revision s)) terrain knowledge = do
  c' ← if terrain then bumpWord c else Just c
  k' ← if knowledge then bumpWord k else Just k
  s' ← bumpWord s
  Just (Authority arena (Revision c') (Revision k') (Revision s'))

-- | The writes of a candidate in key order, the last write of a key winning, each
-- checked to be a record its key can hold.
canonicalWrites ∷ [(RecordKey, Maybe Record)] → P [(RecordKey, Maybe Record)]
canonicalWrites ws = do
  let m = Map.fromList ws
  mapM_ check (Map.toList m)
  Right (Map.toAscList m)
  where
    check (k, Just r) = case decodeValue k (encodeValue r) of
      Just r' | r' == r → Right ()
      _ → refuse (Invalid (MalformedWrite k))
    check _ = Right ()

applyWrites
  ∷ Edit
  → (Maybe Ref, Maybe Ref, Maybe Ref)
  → [(RecordKey, Maybe Record)]
  → P ((Maybe Ref, Maybe Ref, Maybe Ref), Edit)
applyWrites edit roots0 = go roots0 edit
  where
    go roots e [] = Right (roots, e)
    go (rr, rl, rt) e ((key, mrec) : rest) = do
      let tree = treeOfKey key
          kb = encodeKey key
          root = case tree of
            TreeRuns → rr
            TreeLinks → rl
            _ → rt
      (root', e') ← phase e $ case mrec of
        Just r → insertKey tree root kb (encodeValue r)
        Nothing → deleteKey tree root kb
      let roots' = case tree of
            TreeRuns → (root', rl, rt)
            TreeLinks → (rr, root', rt)
            _ → (rr, rl, root')
      go roots' e' rest

ramFor ∷ Int → Int → Int → Int → Int → Int → Int → RamCharge
ramFor windowN windowB overlayB written writes replaced supplyN =
  RamCharge
    { ramIoBuffers = written * pageSize
    , ramDecodedCopies = windowB + overlayB
    , ramKeys = writes * maxEntryBytes
    , ramScratch = replaced * 16 + supplyN * 8 + 4096 + (2 * hotNodes + 1) * hotNodeBytes
    , ramPagePins = windowN * 16
    , ramRootControl = rootRecordBytes + activeRecordBytes + headerBytes
    , ramContinuation = 1024 + windowN * 8
    }

-- ---------------------------------------------------------------------------
-- Reclamation

-- | Plan the reclamation of the oldest retirement entry's pages. @oldest@ is the
-- oldest pinned reader version, if any reader is pinned.
planReclaim ∷ StoreConfig → StoreIdentity → Roots → Maybe Word64 → Window → Planned
planReclaim = planReclaimWith standardBounds

-- | 'planReclaim' under given bounds.
planReclaimWith ∷ Bounds → StoreConfig → StoreIdentity → Roots → Maybe Word64 → Window → Planned
planReclaimWith bounds cfg ident roots = reclaimWith bounds cfg ident roots []

-- | 'planReclaimWith' with the readers' pinned roots: the oldest pinned version is
-- theirs, and a page the entry names is also proven unreachable from each of them.
planReclaimPinned ∷ Bounds → StoreConfig → StoreIdentity → Roots → [Pins] → Window → Planned
planReclaimPinned bounds cfg ident roots pins = reclaimWith bounds cfg ident roots pins (if null pins then Nothing else Just (minimum (map pinVersion pins)))

reclaimWith ∷ Bounds → StoreConfig → StoreIdentity → Roots → [Pins] → Maybe Word64 → Window → Planned
reclaimWith bounds cfg ident roots pins oldest win0 = case reclaimM of
  Left (OutNeed p) → Pending p
  Left (OutProbes ps) → PendingProbes ps
  Left (OutRefuse r) → Refused r
  Left (OutMoreBookkeeping n) → Refused (Capacity (BookkeepingExceeded n))
  Left (OutCheckpoint f) → Checkpoint f
  Right r → r
  where
    total = cfgTotalPages cfg
    fp = fingerprintOf ident roots pins
    win = windowFactsFor fp (windowTrust (rootTrust roots ++ concatMap pinTrust pins) (windowBelow (rHw roots) win0))
    reclaimM ∷ P Planned
    reclaimM = do
      checkWindow bounds ident roots win
      checkCounters roots
      version' ← maybe (refuse (Invalid VersionArithmetic)) pure (bumpWord (rVersion roots))
      let retireRoot = fmap Disk (rRetire roots)
      (firstEntry, e0) ← phase (newEdit overlayBudgetBookkeeping win) (ceilKey TreeRetire False retireRoot BS.empty)
      case firstEntry of
        Nothing → pure NoWork
        -- the retired-page index sorts after every entry: no entry key first means none left
        Just (k, _) | BS.length k /= 8 → pure NoWork
        Just (k, v) → do
          (e, ret) ← maybe (refuse (Integrity MalformedRetirement)) pure (decodeRetire total k v)
          case oldest of
            Just o | o < e → pure (BlockedByReader e o)
            _ → do
              let PageNo lp0 = retList ret
              -- the list lies inside the used space, like every page the store ever numbered
              if lp0 >= rHw roots then refuse (Integrity MalformedRetirement) else pure ()
              page ← case windowPage (retList ret) win of
                Nothing → Left (OutNeed (PageNo lp0))
                Just p → Right p
              -- the list is the one this entry's version stamped, with the pages it counts
              ps ← case pgBody page of
                List stamp xs | pgTree page == TreeRetire && stamp == e && length xs == fromIntegral (retCount ret) → Right xs
                _ → refuse (Integrity MalformedRetirement)
              let (prefix, remaining) = splitAt (fromIntegral (retDone ret)) ps
              attempt e ret prefix remaining version' e0 (chunkSizes (length remaining))
    -- A page a retirement entry names must be a record-tree page no committed or pinned
    -- tree reaches any more: it lies inside the used space, is classified as a record
    -- page (never a list page, a bookkeeping page or nothing) and is not the page the path
    -- of its own first key leads to in any tree that could still be read. A forged entry
    -- naming a live root, a shared live subtree, a bookkeeping page, a list page or a page a
    -- reader still pins (its version lowered past the reader) is corruption.
    notLive pages edit0 = do
      mapM_ (\pg@(PageNo n) → if n >= rHw roots then refuse (Integrity (RetiredPageLive pg)) else Right ()) pages
      let unproven = [pg | pg ← pages, not (windowKnows (FactRetirable pg) win)]
      case [pg | pg ← unproven, isNothing (windowProbeOf pg win)] of
        missing@(_ : _) → Left (OutProbes missing)
        [] → Right ()
      mapM_
        ( \pg → case windowProbeOf pg win of
            Just (ProbeTree t _ _) | isRecordTree t → Right ()
            _ → refuse (Integrity (RetiredPageLive pg))
        )
        unproven
      unreachable bounds fp cfg roots pins RetiredPageLive FactRetirable win pages edit0
    attempt _ _ _ _ _ _ [] = refuse (Integrity MalformedRetirement)
    attempt e ret prefix remaining version' edit (c : cs) = case tryChunk e ret prefix remaining version' edit c of
      Right plan → Right (Planned plan)
      Left (OutRefuse why) | not (null cs) && tooBig why → attempt e ret prefix remaining version' edit cs
      Left o → Left o
    -- a page reclaimed already is absent from the index, or was reused since and retired again under
    -- a newer version (its list keeps the number): only an index record under this entry's own version,
    -- or an older one, says the page was skipped
    goneFromIndex ver root pg edit = do
      (mv, edit') ← phase edit (lookupKey TreeRetire root (retiredKey pg))
      case mv of
        Just v | getBe64 v 0 <= ver → refuse (Integrity (RetiredIndexMismatch pg))
        _ → Right edit'
    unindexRetired ver (root, edit) pg = do
      (mv, edit1) ← phase edit (lookupKey TreeRetire root (retiredKey pg))
      if fmap (\v → getBe64 v 0) mv /= Just ver then refuse (Integrity (RetiredIndexMismatch pg)) else pure ()
      phase edit1 (deleteKey TreeRetire root (retiredKey pg))
    tooBig = shrinkable
    chunkSizes n = let top = min n (min maxReclaimPages (windowWork win)) in takeWhile (>= 1) (iterate (`div` 2) top)
    tryChunk e ret prefix remaining version' edit c = do
      let freed = take c remaining
          m = bdReserve bounds + 4 * c
          lp = retList ret
          done' = fromIntegral (retDone ret) + c
          finished = done' == fromIntegral (retCount ret)
      (mtake, bkEdit0) ← phase edit (takeSupply cfg roots m)
      tk ← maybe (refuse (Capacity (DiskFull (fromIntegral m) (freePool cfg roots + fromIntegral (length (rLoose roots))) 0))) pure mtake
      let claim = fromIntegral m - fromIntegral (tkLoose tk) ∷ Word64
      if freePool cfg roots < claim then refuse (Capacity (DiskFull claim (freePool cfg roots) 0)) else pure ()
      -- nothing a plan frees may still be reachable from a committed tree
      bkEditL ← notLive freed bkEdit0
      -- the excess of a long loose list goes to the allocator tree with the pages this transaction frees
      let looseAll = rLoose roots
          excess = max 0 (length looseAll - looseSoftCap)
          spill = drop (length looseAll - excess) looseAll
          looseKept = take (length looseAll - excess) looseAll
      -- nothing a plan frees may already be free, loose or claimed by this plan's own supply
      (overlap, bkEditA) ← phase bkEditL (overlapOf (fmap Disk (rFree roots)) (Set.fromList (tkPages tk ++ rLoose roots)) freed)
      case overlap of
        Just pg → refuse (Integrity (DoubleFree pg))
        Nothing → Right ()
      -- a spilled page is loose, so it is not in the supply (the supply is far shorter than what is kept), and it
      -- must not already be a free extent
      (spillOverlap, bkEditS) ← phase bkEditA (overlapOf (fmap Disk (rFree roots)) Set.empty spill)
      case spillOverlap of
        Just pg → refuse (Integrity (DoubleFree pg))
        Nothing → Right ()
      (freeRoot1, bkEdit1) ← phase bkEditS (consume (fmap Disk (rFree roots)) tk)
      (freed1, bkEdit2) ← phase bkEdit1 (insertFreed (rHw roots) freeRoot1 (freed ++ spill))
      freeRoot2 ← case freed1 of
        Left p → refuse (Integrity (DoubleFree p))
        Right r → Right r
      let retireRoot = fmap Disk (rRetire roots)
      -- every page this entry frees is indexed under this entry's version, and leaves the
      -- index as it leaves the entry: an entry that names a page that is not retired under it
      -- (a forged list or a lowered version) is refused before anything is freed
      (retireRootI, bkEditI0) ← foldM (unindexRetired e) (retireRoot, bkEdit2) freed
      -- the pages the progress field says were reclaimed must be gone from the index, or a forged field would
      -- drop a page from the obligation for good. Every transaction checks the last 'maxReclaimPages' of them,
      -- so its window never depends on how much of the entry was consumed before (a transaction of one page
      -- needs a window bounded by the tree heights, never by the history of the entry): a field forged forward
      -- skips the pages in front of its new value, which lie inside those pages (the skipped pages are all
      -- still indexed when a jump is longer than the span checked, and are all inside it when it is shorter),
      -- so the first transaction after the forgery refuses it; a field forged backward asks for a page that is
      -- no longer indexed under the entry, which unindexing refuses
      bkEditI ← proving bounds fp win (FactGone e) (goneFromIndex e retireRoot) (drop (length prefix - maxReclaimPages) prefix) bkEditI0
      (retireRoot1, bkEdit3) ←
        if finished
          then phase bkEditI (deleteKey TreeRetire retireRootI (be64 e))
          else
            let (k', v') = encodeRetire e (ret {retDone = fromIntegral done' ∷ Word16})
             in phase bkEditI (insertKey TreeRetire retireRootI k' v')
      -- counted before any page is numbered: more than the supply holds is a shrinkable capacity result
      -- (a smaller chunk frees fewer pages), never a failed numbering
      let bkNeed = freshCount bkEdit3 [retireRoot1, freeRoot2]
      if bkNeed > length (tkPages tk) then refuse (Capacity (BookkeepingExceeded bkNeed)) else pure ()
      (encoded, bkNos, slack) ← assign ident bkEdit3 [retireRoot1, freeRoot2] (tkPages tk)
      let bkUsed = length encoded
      if bkUsed > bdPages bounds then refuse (Capacity (TxnPagesExceeded bkUsed)) else pure ()
      -- the pages this maintenance writes are as unreachable as any other plan's
      bkEdit4 ← provenFree bounds fp cfg roots pins win (Set.fromList (take (tkLoose tk) (tkPages tk))) [pg | (pg@(PageNo n), _) ← encoded, n < rHw roots] bkEdit3
      (retire', free') ← case bkNos of
        [a, b] → Right (a, b)
        _ → refuse (Integrity CorruptCounters)
      let replBk = Set.toAscList (editReplaced bkEdit4 `Set.union` (if finished then Set.singleton lp else Set.empty))
          written = bkUsed
          freeTaken = sum [t | (_, _, t) ← tkExtents tk]
          live' = toInteger (rLivePages roots) + toInteger written - toInteger (length replBk)
          retired' = toInteger (rRetiredPages roots) - toInteger c
          free'' = toInteger (rFreePages roots) - toInteger freeTaken + toInteger c + toInteger (length spill)
          loose' = drop (tkLoose tk) looseKept ++ slack ++ replBk
      if live' < 0 || retired' < 0 || free'' < 0 then refuse (Integrity CorruptCounters) else pure ()
      if length loose' > looseCap then refuse (Integrity (LooseOverflow (length loose'))) else pure ()
      let hdr = rHeader roots
          base = hAuthority hdr
      expected ← maybe (refuse (Invalid RevisionArithmetic)) pure (nextAuthority base False False)
      let next' =
            roots
              { rVersion = version'
              , rRetire = retire'
              , rFree = free'
              , rHeader = hdr {hAuthority = expected}
              , rHw = rHw roots + tkBump tk
              , rFreePages = fromInteger free''
              , rLivePages = fromInteger live'
              , rRetiredPages = fromInteger retired'
              , rLoose = loose'
              , rRootCrcs = rootCrcsAfter roots encoded [(TreeRuns, rRuns roots), (TreeLinks, rLinks roots), (TreeTodo, rTodo roots), (TreeFree, free'), (TreeRetire, retire')]
              }
          windowN = windowSize win
          ram = ramFor windowN (windowBytes win + windowProbeBytes win) (editFreshBytes bkEdit4) written 0 (length replBk + c) m
      if ramTotal ram > bdRamBytes bounds then refuse (Capacity (TxnRamExceeded (ramTotal ram))) else pure ()
      let measure =
            Measure
              { mPagesWritten = written
              , mRecordPages = 0
              , mBookkeepingPages = bkUsed
              , mListPages = 0
              , mReplacedRecord = 0
              , mReplacedBookkeeping = length replBk
              , mSlack = length slack
              , mClaimed = fromIntegral claim
              , mLooseTaken = tkLoose tk
              , mReadSteps = editSteps bkEdit4
              , mWindowPages = windowN
              , mRam = ram
              , mUpdates = 0
              , mRecordWrites = 0
              , mFreed = c
              }
      pure
        Plan
          { plIdentity = PlanIdentity ident (rVersion roots) base
          , plClass = Maintenance
          , plKind = KindReclaim
          , plPages = encoded
          , plNext = next'
          , plEffects = Effects False False True expected version'
          , plMeasure = measure
          }

-- ---------------------------------------------------------------------------
-- Reads through the window

-- | One lookup of a logical record through a window of the committed or pinned
-- roots: the record, a confirmed absence, or the page it needs.
lookupRecord ∷ Window → (TreeId → Maybe PageNo) → RecordKey → Either Stop (Maybe Record)
lookupRecord win rootFor key = do
  let tree = treeOfKey key
  (mv, _) ← runM (lookupKey tree (fmap Disk (rootFor tree)) (encodeKey key)) (newEdit 0 win)
  case mv of
    Nothing → Right Nothing
    Just v → case decodeValue key v of
      Just r → Right (Just r)
      Nothing → Left (Bad MalformedValue (PageNo 0))

-- | The removed run of a column with the greatest lower end at or below a level.
floorRun ∷ Window → (TreeId → Maybe PageNo) → Column → Int64 → Either Stop (Maybe (Int64, Int64))
floorRun win rootFor col z = do
  (r, _) ← runM (floorKey TreeRuns (fmap Disk (rootFor TreeRuns)) (encodeKey (KeyRun col z))) (newEdit 0 win)
  case r of
    Nothing → Right Nothing
    Just (k, v) → case decodeKey TreeRuns k of
      Just key@(KeyRun c lo) | c == col → case decodeValue key v of
        Just (RecRun hi) → Right (Just (lo, hi))
        _ → Left (Bad MalformedValue (PageNo 0))
      Just _ → Right Nothing
      Nothing → Left (Bad MalformedKey (PageNo 0))

-- | Where a ranged read starts: at a key, or strictly after it.
data RangeStart = RangeFrom !RecordKey | RangeAfter !RecordKey
  deriving stock (Eq, Show)

-- | Up to @limit@ records of one tree in key order from a start.
rangeRecords ∷ Window → (TreeId → Maybe PageNo) → TreeId → RangeStart → Int → Either Stop [(RecordKey, Record)]
rangeRecords win rootFor tree start limit = do
  let (strict, key) = case start of
        RangeFrom k → (False, k)
        RangeAfter k → (True, k)
  (es, _) ← runM (rangeKeys tree (fmap Disk (rootFor tree)) strict (encodeKey key) Nothing limit) (newEdit 0 win)
  traverse decodeEntry es
  where
    decodeEntry (k, v) = case decodeKey tree k of
      Nothing → Left (Bad MalformedKey (PageNo 0))
      Just key → case decodeValue key v of
        Nothing → Left (Bad MalformedValue (PageNo 0))
        Just r → Right (key, r)

-- | The provider #661's operations read through: a record the window cannot
-- supply is 'Unavailable', never absent. A page that contradicts its place in the
-- tree is also unavailable here; 'missingPage' tells the two apart.
providerFor ∷ Window → (TreeId → Maybe PageNo) → Provider
providerFor win rootFor =
  Provider
    { fetchRecord = \key → case lookupRecord win rootFor key of
        Right (Just r) → Found r
        Right Nothing → Absent
        Left _ → Unavailable key
    , fetchFloorRun = \col z → case floorRun win rootFor col z of
        Right (Just run) → Found run
        Right Nothing → Absent
        Left _ → Unavailable (KeyRun col z)
    }

-- | Why a record is unavailable: the page to fetch, or an integrity failure. A removed
-- run may have been asked for by key or by a floor lookup (the run at or below a
-- level, which can also need the page of the previous leaf), and both are resolved, so
-- a suspension on either names the page it waits for.
missingPage ∷ Window → (TreeId → Maybe PageNo) → RecordKey → Either IntegrityWhy (Maybe PageNo)
missingPage win rootFor key = case [stop' | Left stop' ← attempts] of
  (Need p : _) → Right (Just p)
  (Bad err p : _) → Left (BadPage err p)
  (TooTall t : _) → Left (BrokenInvariant t)
  (Invariant t : _) → Left (BrokenInvariant t)
  (Over _ : _) → Left CorruptCounters
  [] → Right Nothing
  where
    attempts = void' (lookupRecord win rootFor key) : [void' (floorRun win rootFor col lo) | KeyRun col lo ← [key]]
    void' = fmap (const ())

-- | Map a #661 refusal to this plan's vocabulary: an integrity failure of its
-- records is an integrity result, anything else is its capacity or overflow.
refusalToPlan ∷ Refusal → PlanRefusal
refusalToPlan r = case r of
  Corrupt i → Integrity (DiscoveryCorrupt i)
  other → Invalid (DiscoveryRefusal other)
