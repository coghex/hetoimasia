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

    -- * Planning
  , Bounds (..)
  , standardBounds
  , Delta (..)
  , deltaOf
  , planCandidate
  , planDelta
  , planDeltaWith
  , planReclaimWith
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
import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word16, Word64)
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
  deriving stock (Eq, Show)

data IntegrityWhy
  = BadPage !PageError !PageNo
  | BrokenInvariant !TreeId
  | CorruptCounters
  | DoubleFree !PageNo
  | MalformedRetirement
  | BookkeepingOverflow !Int
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
  }
  deriving stock (Eq, Show)

-- | 256 pages (1 MiB of new encoded pages), 4 MiB of RAM, 512 window pages and 1.25 MiB
-- of window bytes.
standardBounds ∷ Bounds
standardBounds = Bounds maxTxnPages txnRamLimit maxWindowPages maxWindowBytes

-- ---------------------------------------------------------------------------
-- The planning monad

data Out = OutNeed !PageNo | OutRefuse !PlanRefusal

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
settle (Left (OutRefuse r)) = Refused r

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
  (extents, got) ← if needFree <= 0 then pure ([], 0) else readExtents (fmap Disk (rFree roots)) needFree
  let remaining = needFree - fromIntegral got
      tailPages = cfgUsablePages cfg - min (cfgUsablePages cfg) (rHw roots)
  if remaining > 0 && fromIntegral remaining > tailPages
    then pure Nothing
    else do
      let bump = fromIntegral (max 0 remaining) ∷ Word64
          freePagesList = concat [[PageNo (s + i) | i ← [0 .. t - 1]] | (s, _, t) ← extents]
          tailList = [PageNo (rHw roots + i) | bump > 0, i ← [0 .. bump - 1]]
      pure (Just (Take (loose ++ freePagesList ++ tailList) nl extents bump))
  where
    readExtents root need = go root need (BS.empty, False) []
    go root need (from, strict) acc
      | need <= 0 = pure (reverse acc, sum [t | (_, _, t) ← acc])
      | otherwise = do
          r ← ceilKey TreeFree strict root from
          case r of
            Nothing → pure (reverse acc, sum [t | (_, _, t) ← acc])
            Just (k, v) → case decodeFree maxBound k v of
              Nothing → failInvariant TreeFree
              Just (s, l) →
                let t = min l (fromIntegral need)
                 in go root (need - fromIntegral t) (k, True) ((s, l, t) : acc)

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
          before ← floorKey TreeFree root (be64 s)
          after ← ceilKey TreeFree False root (be64 s)
          case (before >>= dec, after >>= dec) of
            (Just (ps, pl), _) | ps + pl > s → pure (Just (PageNo s))
            (_, Just (ns, _)) | ns < s + n → pure (Just (PageNo s))
            _ → go rest
    dec (k, v) = decodeFree maxBound k v

-- | Add freed pages as extents, merging with the neighbours that touch them and
-- refusing a page that is already free.
insertFreed ∷ Word64 → Maybe Ref → [PageNo] → M (Either PageNo (Maybe Ref))
insertFreed hw root0 pages = go root0 (runsOf pages)
  where
    go root [] = pure (Right root)
    go root ((s, n) : rest)
      | s + n > hw = pure (Left (PageNo s))
      | otherwise = do
          before ← floorKey TreeFree root (be64 s)
          after ← ceilKey TreeFree False root (be64 s)
          case (before >>= dec, after >>= dec) of
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
    dec (k, v) = decodeFree maxBound k v

runsOf ∷ [PageNo] → [(Word64, Word64)]
runsOf = foldr add []
  where
    add (PageNo p) ((s, n) : rest) | p + 1 == s = (p, n + 1) : rest
    add (PageNo p) acc = (p, 1) : acc

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
planDeltaWith bounds cfg ident roots win cls cand = settle $ do
  checkWindow bounds ident roots win
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
  if d == 0 && not needRetire
    then
      if next == hdr
        then pure Nothing
        else Just <$> headerOnly cfg ident roots cls cand next version' edit1 writes
    else do
      let m = d + (if needRetire then 1 else 0) + bookkeepingReserve
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
        Just lp →
          let (k, v) = encodeRetire version' (Retire lp (fromIntegral listN) 0)
           in phase bkEdit0 (insertKey TreeRetire retireRoot0 k v)
      (freeRoot1, bkEdit2) ← phase bkEdit1 (consume (fmap Disk (rFree roots)) tk)
      (pagesBk, bkNos, slack) ← assign ident bkEdit2 [retireRoot1, freeRoot1] afterList
      let bkUsed = length pagesBk
      if bkUsed > bookkeepingReserve then refuse (Integrity (BookkeepingOverflow bkUsed)) else pure ()
      listPages ← traverse (\lp → encodeOut ident (Page TreeRetire 0 lp (List replacedRec))) (maybe [] pure listPage)
      let encoded = pagesRec ++ listPages ++ pagesBk
          written = length encoded
      if written > bdPages bounds then refuse (Capacity (TxnPagesExceeded written)) else pure ()
      (rr', rl', rt') ← case recNos of
        [a, b, c] → Right (a, b, c)
        _ → refuse (Integrity CorruptCounters)
      (retire', free') ← case bkNos of
        [a, b] → Right (a, b)
        _ → refuse (Integrity CorruptCounters)
      let replBk = Set.toAscList (editReplaced bkEdit2)
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
              }
          windowN = windowSize win
          steps = editSteps edit1 + editSteps bkEdit2
          ram = ramFor windowN (windowBytes win) (editFreshBytes edit1 + editFreshBytes bkEdit2) written (length writes) (listN + length replBk) m
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
  where
    protectedFor Ordinary = reservePages
    protectedFor Maintenance = 0

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

checkWindow ∷ Bounds → StoreIdentity → Roots → Window → P ()
checkWindow bounds ident roots win = do
  if windowIdentity win /= ident then refuse (Stale ForeignWindow) else pure ()
  if windowVersion win /= rVersion roots then refuse (Stale (StaleWindow (windowVersion win) (rVersion roots))) else pure ()
  if windowSize win > bdWindowPages bounds then refuse (Capacity (WindowExceeded (windowSize win))) else pure ()
  if windowBytes win > bdWindowBytes bounds then refuse (Capacity (WindowBytesExceeded (windowBytes win))) else pure ()

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
planReclaimWith bounds cfg ident roots oldest win = case reclaimM of
  Left (OutNeed p) → Pending p
  Left (OutRefuse r) → Refused r
  Right r → r
  where
    total = cfgTotalPages cfg
    reclaimM ∷ P Planned
    reclaimM = do
      checkWindow bounds ident roots win
      version' ← maybe (refuse (Invalid VersionArithmetic)) pure (bumpWord (rVersion roots))
      let retireRoot = fmap Disk (rRetire roots)
      (firstEntry, e0) ← phase (newEdit overlayBudgetBookkeeping win) (ceilKey TreeRetire False retireRoot BS.empty)
      case firstEntry of
        Nothing → pure NoWork
        Just (k, v) → do
          (e, ret) ← maybe (refuse (Integrity MalformedRetirement)) pure (decodeRetire total k v)
          case oldest of
            Just o | o < e → pure (BlockedByReader e o)
            _ → do
              let PageNo lp0 = retList ret
              page ← case windowPage (retList ret) win of
                Nothing → Left (OutNeed (PageNo lp0))
                Just p → Right p
              ps ← case pgBody page of
                List xs | pgTree page == TreeRetire && length xs == fromIntegral (retCount ret) → Right xs
                _ → refuse (Integrity MalformedRetirement)
              let remaining = drop (fromIntegral (retDone ret)) ps
              attempt e ret remaining version' e0 (chunkSizes (length remaining))
    attempt _ _ _ _ _ [] = refuse (Integrity MalformedRetirement)
    attempt e ret remaining version' edit (c : cs) = case tryChunk e ret remaining version' edit c of
      Right plan → Right (Planned plan)
      Left (OutRefuse why) | not (null cs) && tooBig why → attempt e ret remaining version' edit cs
      Left o → Left o
    tooBig (Integrity (BookkeepingOverflow _)) = True
    tooBig (Capacity (TxnPagesExceeded _)) = True
    tooBig (Capacity (TxnRamExceeded _)) = True
    tooBig _ = False
    chunkSizes n = let top = min n maxReclaimPages in takeWhile (>= 1) (iterate (`div` 2) top)
    tryChunk e ret remaining version' edit c = do
      let freed = take c remaining
          m = bookkeepingReserve + 2 * c
          lp = retList ret
          done' = fromIntegral (retDone ret) + c
          finished = done' == fromIntegral (retCount ret)
      (mtake, bkEdit0) ← phase edit (takeSupply cfg roots m)
      tk ← maybe (refuse (Capacity (DiskFull (fromIntegral m) (freePool cfg roots + fromIntegral (length (rLoose roots))) 0))) pure mtake
      let claim = fromIntegral m - fromIntegral (tkLoose tk) ∷ Word64
      if freePool cfg roots < claim then refuse (Capacity (DiskFull claim (freePool cfg roots) 0)) else pure ()
      -- nothing a plan frees may already be free, loose or claimed by this plan's own supply
      (overlap, bkEditA) ← phase bkEdit0 (overlapOf (fmap Disk (rFree roots)) (Set.fromList (tkPages tk ++ rLoose roots)) freed)
      case overlap of
        Just pg → refuse (Integrity (DoubleFree pg))
        Nothing → Right ()
      (freeRoot1, bkEdit1) ← phase bkEditA (consume (fmap Disk (rFree roots)) tk)
      (freed1, bkEdit2) ← phase bkEdit1 (insertFreed (rHw roots) freeRoot1 freed)
      freeRoot2 ← case freed1 of
        Left p → refuse (Integrity (DoubleFree p))
        Right r → Right r
      let retireRoot = fmap Disk (rRetire roots)
      (retireRoot1, bkEdit3) ←
        if finished
          then phase bkEdit2 (deleteKey TreeRetire retireRoot (be64 e))
          else
            let (k', v') = encodeRetire e (ret {retDone = fromIntegral done' ∷ Word16})
             in phase bkEdit2 (insertKey TreeRetire retireRoot k' v')
      (encoded, bkNos, slack) ← assign ident bkEdit3 [retireRoot1, freeRoot2] (tkPages tk)
      let bkUsed = length encoded
      if bkUsed > m then refuse (Integrity (BookkeepingOverflow bkUsed)) else pure ()
      if bkUsed > bdPages bounds then refuse (Capacity (TxnPagesExceeded bkUsed)) else pure ()
      (retire', free') ← case bkNos of
        [a, b] → Right (a, b)
        _ → refuse (Integrity CorruptCounters)
      let replBk = Set.toAscList (editReplaced bkEdit3 `Set.union` (if finished then Set.singleton lp else Set.empty))
          written = bkUsed
          freeTaken = sum [t | (_, _, t) ← tkExtents tk]
          live' = toInteger (rLivePages roots) + toInteger written - toInteger (length replBk)
          retired' = toInteger (rRetiredPages roots) - toInteger c
          free'' = toInteger (rFreePages roots) - toInteger freeTaken + toInteger c
          loose' = drop (tkLoose tk) (rLoose roots) ++ slack ++ replBk
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
              }
          windowN = windowSize win
          ram = ramFor windowN (windowBytes win) (editFreshBytes bkEdit3) written 0 (length replBk + c) m
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
              , mReadSteps = editSteps bkEdit3
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
