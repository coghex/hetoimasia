-- | The store as one pure state machine: the committed roots, the readers pinned to
-- older versions, the one active transaction, the allowance and its growth, and the
-- conditions that pause new history.
--
-- Nothing here performs I/O, runs a thread, reads a clock or takes a lock. The later
-- terrain owner holds the one current 'Store' and feeds it the outcomes its workers
-- and its requests report; every transition returns the next value or a typed
-- refusal and leaves the argument untouched.
--
-- = The transaction
--
-- @
--   plan -> admit -> ( dispatch -> complete )* -> publish
--                       \\                         ^
--                        cancel (a request)       | eligible only when every page is
--                        \\                        |  Written and no I/O is outstanding
--                         abort (after drain)
-- @
--
-- At most one transaction is active. 'admit' claims the plan's pages (they are
-- /staged/: unreachable from the committed roots, claimed by this transaction
-- alone). A page's outcome is supplied by the owner: 'WriteDone' or 'WriteFailed'.
-- Completing every page makes the transaction eligible for the owner's decision; an
-- I/O completion is not a publication, and 'publish' is the owner's. Cancellation is
-- a request: it is recorded and releases nothing. 'abort' releases the claims only
-- once no write is in flight, and it needs no write: the committed roots were never
-- changed, so the old content, knowledge and frontier are exactly as they were.
-- After 'publish' the new roots are authoritative and a late cancellation or
-- outcome of that transaction changes nothing. A duplicate or stale outcome (an
-- unknown transaction, a page the transaction does not hold, a result already
-- recorded) changes nothing and is reported as such.
--
-- = Readers
--
-- A reader pins the record trees of one committed version. Writes, publication and
-- reclamation cannot change its answers: replaced record pages are retired and
-- reclaimed only once the oldest pinned version has passed the retirement entry's
-- version. A token for a released reader, another store or another incarnation
-- reads nothing.
--
-- = The allowance and growth
--
-- See "Hetoimasia.Terrain.Runtime.Store.Internal.State" for the page states and the
-- accounting. Growth is proposed purely, begun (serialised with mutation), recorded
-- as reserved when the effect owner reports it, and committed only then; a growth
-- that fails keeps the old allowance, and any extra reservation it had obtained
-- stays accounted as pending until its release is reported.
--
-- State, ownership and lifetime: values; the terrain owner is the only writer of
-- the current 'Store', on its one thread.
module Hetoimasia.Terrain.Runtime.Store.Internal.Model
  ( -- * The store
    Store
  , newStore
  , storeFromRoots
  , modifyRoots
  , modifyPins
  , storeConfig
  , storeIdentity
  , storeRoots
  , storeVersion
  , storeHeader
  , oldestPin
  , pinnedRoots
  , pinsOf
  , committedRoot

    -- * Usage
  , Usage (..)
  , usage
  , controlBytes

    -- * Planning
  , planEdit
  , planRemoval
  , planRemovalWith
  , planDiscovery
  , planDiscoveryWith
  , planMaintenanceWith
  , planMaintenance
  , WindowRefusal (..)
  , storeWindow
  , providerAt
  , missingAt

    -- * The transaction
  , TxnId
  , txnSerial
  , AdmitRefusal (..)
  , admit
  , EventResult (..)
  , WriteOutcome (..)
  , dispatchWrite
  , completeWrite
  , requestCancel
  , Eligibility (..)
  , eligibility
  , Published (..)
  , PublishRefusal (..)
  , publish
  , AbortRefusal (..)
  , abortTransaction
  , activePages
  , ActiveView (..)
  , activeView

    -- * Conditions
  , Condition (..)
  , conditions
  , pauseFor
  , clearCondition

    -- * Readers
  , ReaderToken
  , ReaderRefusal (..)
  , StaleReader (..)
  , acquireReader
  , releaseReader
  , readerVersion
  , readerWindow
  , ReadOutcome (..)
  , maxRangeRecords
  , readerLookup
  , readerFloorRun
  , readerRange
  , PinRefusal (..)
  , readerProviderFor
  , readerMissing

    -- * Growth
  , GrowthProposal
  , gpFrom
  , gpTo
  , GrowthDecision (..)
  , GrowthRefusal (..)
  , proposeGrowth
  , beginGrowth
  , growthReserved
  , commitGrowth
  , growthFailed
  , growthReleased
  , growthReleaseFailed
  , GrowthView (..)
  , growthView

    -- * Feasibility
  , Counterexample (..)
  , minimumRemovalFeasible
  , minimumRemovalPages
  , minimumRemovalRam
  , minimumDiscoveryUnitRam
  ) where

import Data.ByteString (ByteString)
import Data.List (nub)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, isNothing)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Word (Word64)
import Hetoimasia.Terrain.Cell (Column)
import Hetoimasia.Terrain.Coordinate (TileCoord)
import Hetoimasia.Terrain.Discovery
  ( Allowance (..)
  , Authority
  , Candidate
  , Env
  , Header (..)
  , Provider
  , ReadSet (..)
  , Record
  , RecordKey (..)
  , Refusal
  , Report (..)
  , StageOutcome (NoChange, EditSuspended)
  , Step (..)
  , allowanceOf
  , candidateReport
  , envLimits
  , stageRemovalTraced
  , stepDiscoveryTraced
  , worstEdgeReads
  , worstEdgeWrites
  , worstEditReads
  , worstEditWrites
  )
import Data.Int (Int64)
import qualified Hetoimasia.Terrain.Discovery as Discovery
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.State
import Hetoimasia.Terrain.Runtime.Store.Internal.Tree

-- ---------------------------------------------------------------------------
-- The store

data PageState = PsStaged | PsInFlight | PsWritten | PsFailed
  deriving stock (Eq, Show)

data Active = Active
  { acId ∷ !TxnId
  , acPlan ∷ !Plan
  , acPages ∷ !(Map PageNo PageState)
  , acCancel ∷ !Bool
  }

-- | A transaction's identity: the store's reader-independent serial. Outcomes
-- carry it, so one for another transaction or an earlier one changes nothing.
data TxnId = TxnId !StoreIdentity !Word64
  deriving stock (Eq, Show)

-- | The transaction's serial within its store. The identity of a transaction is the
-- store (arena and source) and this serial, so an outcome for another store's
-- transaction with the same serial changes nothing.
txnSerial ∷ TxnId → Word64
txnSerial (TxnId _ n) = n

-- | Why new history is paused. The first three of these pause an arena; none is
-- cleared by another's recovery.
data Condition = CondCapacity | CondIo | CondIntegrity
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data GrowthState
  = GrowthIdle
  | -- | A proposal is being executed; the flag says whether the extra reservation
    -- has been obtained.
    GrowthExecuting !GrowthProposal !Bool
  | -- | Extra reservation obtained by a growth that did not commit, awaiting
    -- release by the effect owner.
    GrowthReleasing !Word64

-- | A validated proposal to enlarge the allowance of the same store.
data GrowthProposal = GrowthProposal
  { gpIdentity ∷ !StoreIdentity
  , gpFrom ∷ !Word64
  , gpTo ∷ !Word64
  , gpConfig ∷ !StoreConfig
  }
  deriving stock (Eq, Show)

-- | The store.
data Store = Store
  { sCfg ∷ !StoreConfig
  , sIdent ∷ !StoreIdentity
  , sRoots ∷ !Roots
  , sReaders ∷ !(Map Word64 Pins)
  , sNextReader ∷ !Word64
  , sActive ∷ !(Maybe Active)
  , sNextTxn ∷ !Word64
  , sGrowth ∷ !GrowthState
  , sConditions ∷ !(Set Condition)
  }

-- | A fresh store: no page, no record, no reader, revisions zero.
newStore ∷ StoreConfig → StoreIdentity → Store
newStore cfg ident =
  Store
    { sCfg = cfg
    , sIdent = ident
    , sRoots = emptyRoots (siArena ident)
    , sReaders = Map.empty
    , sNextReader = 1
    , sActive = Nothing
    , sNextTxn = 1
    , sGrowth = GrowthIdle
    , sConditions = Set.empty
    }

-- | A store over given committed roots, with no reader, transaction or pause. This
-- is a seam of the private library for the suite (to reach states, such as revisions
-- at their limit, that no sequence of public operations reaches in a test's time);
-- it is not in the public interface and checks nothing about the roots.
storeFromRoots ∷ StoreConfig → StoreIdentity → Roots → Store
storeFromRoots cfg ident roots = (newStore cfg ident) {sRoots = roots}

-- | The same store with every reader's pinned roots changed: the same kind of seam, to forge what a
-- reader pinned. It checks nothing.
modifyPins ∷ (Pins → Pins) → Store → Store
modifyPins f s = s {sReaders = Map.map f (sReaders s)}

-- | The same store (its readers, transaction and pauses kept) over changed committed
-- roots: another seam of the private library for the suite, to forge a root set a
-- test then plans against. It checks nothing about the roots.
modifyRoots ∷ (Roots → Roots) → Store → Store
modifyRoots f s = s {sRoots = f (sRoots s)}

storeConfig ∷ Store → StoreConfig
storeConfig = sCfg

storeIdentity ∷ Store → StoreIdentity
storeIdentity = sIdent

-- | The committed root set.
storeRoots ∷ Store → Roots
storeRoots = sRoots

storeVersion ∷ Store → Word64
storeVersion = rVersion . sRoots

-- | The discovery control header of the committed version.
storeHeader ∷ Store → Header
storeHeader = rHeader . sRoots

-- | The oldest version a reader still pins, if any.
oldestPin ∷ Store → Maybe Word64
oldestPin s = case Map.elems (sReaders s) of
  [] → Nothing
  ps → Just (minimum (map pinVersion ps))

-- | The record roots every pinned reader holds, one for each distinct pin.
pinnedRoots ∷ Store → [Pins]
pinnedRoots = nub . Map.elems . sReaders

-- | A tree's committed root page.
committedRoot ∷ Store → TreeId → Maybe PageNo
committedRoot = rootOf . sRoots

-- ---------------------------------------------------------------------------
-- Usage

-- | The allowance, by what holds it. Every figure is a count of whole pages times
-- the page size, except the overhead, which is the conservative format and
-- reservation overhead the configuration states.
data Usage = Usage
  { usAllowanceBytes ∷ !Word64
  , usOverheadBytes ∷ !Word64
  , usUsedBytes ∷ !Word64
  -- ^ Live, retired, loose and staged pages and the overhead: free extents are not
  -- used bytes.
  , usLiveBytes ∷ !Word64
  , usStagedBytes ∷ !Word64
  , usRetiredBytes ∷ !Word64
  -- ^ Pending reclaim: a subset of the used bytes, not free capacity.
  , usLooseBytes ∷ !Word64
  , usFreeBytes ∷ !Word64
  -- ^ Free extents and the untouched tail, less what a pending transaction staged.
  , usProtectedBytes ∷ !Word64
  , usAvailableBytes ∷ !Word64
  -- ^ What ordinary history may still take: the free bytes less the protected
  -- reserve.
  , usPendingGrowthBytes ∷ !Word64
  , usReaders ∷ !Int
  , usPinnedVersions ∷ !Int
  , usHighWater ∷ !Word64
  }
  deriving stock (Eq, Show)

-- | The usage of the store now.
usage ∷ Store → Usage
usage s =
  Usage
    { usAllowanceBytes = allowance
    , usOverheadBytes = overhead
    , usUsedBytes = allowance - freeBytes
    , usLiveBytes = rLivePages r * pageSizeW
    , usStagedBytes = staged * pageSizeW
    , usRetiredBytes = rRetiredPages r * pageSizeW
    , usLooseBytes = fromIntegral (length (rLoose r)) * pageSizeW
    , usFreeBytes = freeBytes
    , usProtectedBytes = min protectedReserveBytes freeBytes
    , usAvailableBytes = if freeBytes > protectedReserveBytes then freeBytes - protectedReserveBytes else 0
    , usPendingGrowthBytes = pending
    , usReaders = Map.size (sReaders s)
    , usPinnedVersions = Set.size (Set.fromList (map pinVersion (Map.elems (sReaders s))))
    , usHighWater = rHw r
    }
  where
    r = sRoots s
    cfg = sCfg s
    allowance = cfgAllowanceBytes cfg
    usable = cfgUsablePages cfg
    overhead = allowance - usable * pageSizeW
    staged = maybe 0 (fromIntegral . mClaimed . plMeasure . acPlan) (sActive s) ∷ Word64
    poolPages = freePool cfg r
    freeBytes = (if poolPages > staged then poolPages - staged else 0) * pageSizeW
    pending = case sGrowth s of
      GrowthIdle → 0
      GrowthExecuting p True → gpTo p - gpFrom p
      GrowthExecuting _ False → 0
      GrowthReleasing b → b

-- | The RAM the store's control records hold: the root record, one record per
-- pinned reader and the active transaction's record.
controlBytes ∷ Store → Int
controlBytes s =
  rootRecordBytes
    + Discovery.headerBytes
    + Map.size (sReaders s) * readerRecordBytes
    + maybe 0 (const activeRecordBytes) (sActive s)

-- ---------------------------------------------------------------------------
-- Planning

-- | Plan an ordinary candidate against the committed roots.
planEdit ∷ Store → Window → Candidate → Planned
planEdit = planEditWith standardBounds

-- | 'planEdit' under given bounds.
planEditWith ∷ Bounds → Store → Window → Candidate → Planned
planEditWith bounds s win = planDeltaPinned bounds (sCfg s) (sIdent s) (sRoots s) (pinnedRoots s) win Ordinary . deltaOf

-- | Plan the reclamation of the oldest retired pages the readers no longer hold.
planMaintenance ∷ Store → Window → Planned
planMaintenance = planMaintenanceWith standardBounds

-- | 'planMaintenance' under given bounds.
planMaintenanceWith ∷ Bounds → Store → Window → Planned
planMaintenanceWith bounds s = planReclaimPinned bounds (sCfg s) (sIdent s) (sRoots s) (pinnedRoots s)

-- | Why a window cannot be used for a store or a pinned version.
data WindowRefusal
  = -- | The window was made for another arena or source.
    WindowOfAnotherStore
  | -- | The window was filled for another version: the window's, the one asked for.
    WindowOfAnotherVersion !Word64 !Word64
  deriving stock (Eq, Show)

windowRefusal ∷ StoreIdentity → Word64 → Window → Maybe WindowRefusal
windowRefusal ident version win
  | windowIdentity win /= ident = Just WindowOfAnotherStore
  | windowVersion win /= version = Just (WindowOfAnotherVersion (windowVersion win) version)
  | otherwise = Nothing

-- | A window as the committed version reads it: no page at or past its used space.
below ∷ Store → Window → Window
below s = windowBelow (rHw (sRoots s)) . windowTrust (rootTrust (sRoots s))

-- | A window as a reader's pinned version reads it: bounded by that version's used space and holding the
-- checksums its root pages must carry.
pinView ∷ Pins → Window → Window
pinView p = windowBelow (pinHw p) . windowTrust (pinTrust p)

-- | A window for the committed version of the store.
storeWindow ∷ Store → Window
storeWindow s = windowTrust (rootTrust (sRoots s)) (emptyWindow (sIdent s) (rVersion (sRoots s)))

-- | The provider #661's operations read the committed records through. A record the
-- window cannot supply is 'Unavailable', never absent. A window of another store or
-- version is refused, never read.
providerAt ∷ Store → Window → Either WindowRefusal Provider
providerAt s win = maybe (Right (providerFor (below s win) (committedRoot s))) Left (windowRefusal (sIdent s) (rVersion (sRoots s)) win)

-- | Why a record is unavailable: the page to fetch, or an integrity failure.
missingAt ∷ Store → Window → RecordKey → Either WindowRefusal (Either IntegrityWhy (Maybe PageNo))
missingAt s win key = maybe (Right (missingPage (below s win) (committedRoot s) key)) Left (windowRefusal (sIdent s) (rVersion (sRoots s)) win)

-- | Plan the removal of one whole cell with its minimum connection obligation, as
-- one candidate. Removing air or an already removed cell is 'NoWork'.
planRemoval ∷ Env → Store → Window → TileCoord → Planned
planRemoval = planRemovalWith standardBounds

-- | 'planRemoval' under given bounds.
--
-- A removal reads logical records (union-find chains, floor runs) before it can say what it writes, and every page of every read
-- stays in the caller's window until staging ends. Its READ phase is therefore bounded like the rest: the records it has read
-- are facts ('Checkpoint'), the provider answers from them first, and the phase ends in one of three ways: staging needs a
-- page and the window cannot take it (a 'Checkpoint' of what was read; the caller continues through a fresh window and staging
-- replays from the facts), staging completes holding more than 'readResiduePages' read pages (the same checkpoint, so the
-- edit phase starts from an empty window), or staging completes. A checkpoint that would carry no new fact is the typed
-- window result, never a loop. The record facts of a plan are for the retries of THAT plan.
planRemovalWith ∷ Bounds → Env → Store → Window → TileCoord → Planned
planRemovalWith bounds env s win0 tile = withWindow s win0 $ \_ →
  let (fp, win, prov) = readPhase s win0
   in case stageRemovalTraced env (rHeader (sRoots s)) prov (editAllowance env) tile of
        (Left refusal, _) → Refused (refusalOf refusal)
        (Right NoChange, _) → NoWork
        (Right (EditSuspended key), rs) → suspendedReads bounds s fp win rs key
        (Right (Discovery.Staged cand), rs) → settleReads bounds fp win rs (planEditWith bounds s win cand)

-- | The window as the read phase of a plan sees it (its read facts kept only for this very state), its fingerprint, and the
-- provider over it: the facts first, then the pages.
readPhase ∷ Store → Window → (Fingerprint, Window, Provider)
readPhase s win0 =
  let fp = fingerprintOf (sIdent s) (sRoots s) (pinnedRoots s)
      win = windowFactsFor fp win0
   in (fp, win, providerFacts (below s win) (committedRoot s))

-- | How many of the records a read phase resolved the window does not carry as facts yet.
newReadFacts ∷ Window → ReadSet → Int
newReadFacts win (ReadSet rs fl) =
  length [() | (k, _) ← rs, isNothing (windowReadRecord k win)] + length [() | (q, _) ← fl, isNothing (windowReadFloor q win)]

-- | A read phase's checkpoint: every record it resolved, as facts the next window carries. With no new fact it is the typed window
-- result (the window cannot hold one read, so no retry helps); with more facts than the plan's RAM may hold it is the shrinkable
-- 'TxnRamExceeded' (a discovery batch halves its work; a removal reads too few for it to happen).
checkpointReads ∷ Bounds → Fingerprint → Window → ReadSet → Planned
checkpointReads bounds fp win rs
  | fresh == 0 = Refused (Capacity (if windowSize win + 1 > bdWindowPages bounds then WindowExceeded (windowSize win) else WindowBytesExceeded (windowBytes win)))
  | (windowReadFactCount win + fresh) * recordFactBytes > maxReadFactBytes = Refused (Capacity (TxnRamExceeded ((windowReadFactCount win + fresh) * recordFactBytes)))
  | otherwise = Checkpoint (Facts fp [] rs)
  where
    fresh = newReadFacts win rs

-- | A read phase that needs a page: the page when the window can take it, else a checkpoint of what was read.
suspendedReads ∷ Bounds → Store → Fingerprint → Window → ReadSet → RecordKey → Planned
suspendedReads bounds s fp win rs key = case missingAt s win key of
  Right (Right (Just p))
    | windowFull bounds win → checkpointReads bounds fp win rs
    | otherwise → Pending p
  Right (Right Nothing) → Refused (Integrity CorruptCounters)
  Right (Left why) → Refused (Integrity why)
  Left _ → Refused (Stale ForeignWindow)

-- | The end of a read phase: more read pages than the residue a promised bound leaves for the edit hand what was read on as facts,
-- so the edit starts from an empty window; otherwise the edit goes on.
settleReads ∷ Bounds → Fingerprint → Window → ReadSet → Planned → Planned
settleReads bounds fp win rs next
  | windowSize win > bdReadResidue bounds && newReadFacts win rs > 0 = checkpointReads bounds fp win rs
  | otherwise = next

-- | Plan one discovery batch: as many structural updates as #661's limits and this
-- plan's page and RAM bounds allow (at most 64), the continuation staying in the
-- obligation records. When a batch does not fit the transaction bounds it is
-- planned again with fewer writes, so a bound that is tighter than 64 updates
-- stops the batch earlier. Its read phase is the removal's ('planRemovalWith').
planDiscovery ∷ Env → Store → Window → Planned
planDiscovery = planDiscoveryWith standardBounds

-- | 'planDiscovery' under given bounds.
planDiscoveryWith ∷ Bounds → Env → Store → Window → Planned
planDiscoveryWith bounds env s win0 = withWindow s win0 $ \_ →
  let (fp, win, prov) = readPhase s win0
   in go fp win prov (min (allowWrites full) (windowWorkAtLeast discoveryUnitWrites win0)) (8 ∷ Int)
  where
    full = allowanceOf (envLimits env)
    go fp win prov writes tries =
      case stepDiscoveryTraced env (rHeader (sRoots s)) prov full {allowWrites = writes} of
        (Left refusal, _) → Refused (refusalOf refusal)
        (Right Idle, _) → NoWork
        (Right (Stalled key), rs) → suspendedReads bounds s fp win rs key
        (Right (Progress cand _), rs) → case settleReads bounds fp win rs (planDeltaPinned bounds (sCfg s) (sIdent s) (sRoots s) (pinnedRoots s) win Ordinary (deltaOf cand)) of
          Refused why
            | tries > 0 && tooBig why && reportWrites (candidateReport cand) > discoveryUnitWrites →
                go fp win prov (max discoveryUnitWrites (reportWrites (candidateReport cand) `div` 2)) (tries - 1)
          other → other
    tooBig = shrinkable

editAllowance ∷ Env → Allowance
editAllowance = allowanceOf . envLimits

-- | Run a planner over the committed provider, refusing a window of another store or
-- version before anything is read.
withWindow ∷ Store → Window → (Provider → Planned) → Planned
withWindow s win f = case windowRefusal (sIdent s) (rVersion (sRoots s)) win of
  Just WindowOfAnotherStore → Refused (Stale ForeignWindow)
  Just (WindowOfAnotherVersion a b) → Refused (Stale (StaleWindow a b))
  Nothing → f (providerFor (below s win) (committedRoot s))

refusalOf ∷ Refusal → PlanRefusal
refusalOf = refusalToPlan

-- ---------------------------------------------------------------------------
-- Admission and the transaction

-- | Why a plan was not admitted. A refusal changes nothing.
data AdmitRefusal
  = -- | Another mutating transaction is active, or a growth is being executed.
    BusyTransaction
  | BusyGrowth
  | -- | The plan was made against another version, authority or store.
    StalePlan
  | -- | New history is paused for a condition.
    Paused !Condition
  | -- | The pages the plan stages do not fit the allowance beside the protected
    -- reserve: pages needed, available.
    NoCapacity !Word64 !Word64
  deriving stock (Eq, Show)

-- | Claim a plan's pages for the one active transaction. The plan must have been
-- made against exactly the committed roots; an ordinary plan must leave the
-- protected reserve untouched; a paused store admits nothing ordinary.
admit ∷ Plan → Store → Either AdmitRefusal (TxnId, Store)
admit plan s
  | isJust (sActive s) = Left BusyTransaction
  | growing (sGrowth s) = Left BusyGrowth
  | plIdentity plan /= PlanIdentity (sIdent s) (rVersion (sRoots s)) (hAuthority (rHeader (sRoots s))) = Left StalePlan
  | Just c ← blocking = Left (Paused c)
  | claim > availablePages (sCfg s) (plClass plan) (sRoots s) = Left (NoCapacity claim (availablePages (sCfg s) (plClass plan) (sRoots s)))
  | otherwise =
      let tid = TxnId (sIdent s) (sNextTxn s)
          pages = Map.fromList [(p, PsStaged) | (p, _) ← plPages plan]
       in Right (tid, s {sActive = Just (Active tid plan pages False), sNextTxn = sNextTxn s + 1})
  where
    claim = fromIntegral (mClaimed (plMeasure plan)) ∷ Word64
    growing GrowthIdle = False
    growing (GrowthReleasing _) = False
    growing (GrowthExecuting _ _) = True
    blocking = case plClass plan of
      Ordinary → listToMaybe' (Set.toDescList (sConditions s))
      Maintenance → if Set.member CondIntegrity (sConditions s) then Just CondIntegrity else Nothing
    listToMaybe' (x : _) = Just x
    listToMaybe' [] = Nothing

-- | What a reported outcome did.
data EventResult
  = Applied
  | -- | The same outcome was already recorded.
    Duplicate
  | -- | The transaction or the page is not one the store holds (stale, published,
    -- aborted or foreign): nothing changed.
    Unknown
  deriving stock (Eq, Show)

-- | What the owner's worker reports for one page write.
data WriteOutcome = WriteDone | WriteFailed
  deriving stock (Eq, Show)

withActive ∷ TxnId → Store → (Active → (EventResult, Active)) → (EventResult, Store)
withActive tid s f = case sActive s of
  Just a | acId a == tid → let (r, a') = f a in (r, s {sActive = Just a'})
  _ → (Unknown, s)

-- | A page's write was handed to a worker.
dispatchWrite ∷ TxnId → PageNo → Store → (EventResult, Store)
dispatchWrite tid p s = withActive tid s $ \a → case Map.lookup p (acPages a) of
  Just PsStaged → (Applied, a {acPages = Map.insert p PsInFlight (acPages a)})
  Just _ → (Duplicate, a)
  Nothing → (Unknown, a)

-- | A page's write finished or failed. Only an in-flight page can complete.
completeWrite ∷ TxnId → PageNo → WriteOutcome → Store → (EventResult, Store)
completeWrite tid p outcome s = withActive tid s $ \a → case Map.lookup p (acPages a) of
  Just PsInFlight → (Applied, a {acPages = Map.insert p (if outcome == WriteDone then PsWritten else PsFailed) (acPages a)})
  Just PsStaged → (Unknown, a)
  Just _ → (Duplicate, a)
  Nothing → (Unknown, a)

-- | A request to cancel. It is recorded and releases nothing: the claims stay until
-- 'abortTransaction' once the I/O has drained, or the owner publishes anyway.
requestCancel ∷ TxnId → Store → (EventResult, Store)
requestCancel tid s = withActive tid s $ \a →
  if acCancel a then (Duplicate, a) else (Applied, a {acCancel = True})

-- | Whether the owner may decide to publish.
data Eligibility
  = Eligible
  | -- | Pages not yet written or still in flight.
    StillWriting !Int
  | -- | Pages whose writes failed.
    WriteFailures [PageNo]
  | NoSuchTransaction
  deriving stock (Eq, Show)

-- | A transaction is eligible only when every page it must write has completed
-- successfully and none is in flight. This is not publication.
eligibility ∷ TxnId → Store → Eligibility
eligibility tid s = case sActive s of
  Just a | acId a == tid →
    let states = Map.toList (acPages a)
        failed = [p | (p, PsFailed) ← states]
        unwritten = length [() | (_, st) ← states, st /= PsWritten, st /= PsFailed]
     in if not (null failed)
          then WriteFailures failed
          else if unwritten > 0 then StillWriting unwritten else Eligible
  _ → NoSuchTransaction

-- | What publishing made authoritative.
data Published = Published
  { pubEffects ∷ !Effects
  , pubVersion ∷ !Word64
  , pubRetiredPages ∷ !Word64
  }
  deriving stock (Eq, Show)

data PublishRefusal
  = PublishNoSuchTransaction
  | PublishNotEligible !Eligibility
  | -- | The committed roots are no longer the plan's base.
    PublishStale
  deriving stock (Eq, Show)

-- | The owner's publication of an eligible transaction: the new roots become
-- authoritative at once, the replaced record pages are retired (their pending
-- obligation is in the new roots' retirement tree) and the transaction ends. The
-- owner decides it against cancellation and closure exactly once; this function is
-- that decision's effect.
publish ∷ TxnId → Store → Either PublishRefusal (Published, Store)
publish tid s = case sActive s of
  Just a | acId a == tid → case eligibility tid s of
    Eligible
      | plIdentity (acPlan a) /= PlanIdentity (sIdent s) (rVersion (sRoots s)) (hAuthority (rHeader (sRoots s))) → Left PublishStale
      | otherwise →
          let p = acPlan a
              next = plNext p
           in Right
                ( Published (plEffects p) (rVersion next) (fromIntegral (mReplacedRecord (plMeasure p)))
                , s {sRoots = next, sActive = Nothing}
                )
    other → Left (PublishNotEligible other)
  _ → Left PublishNoSuchTransaction

data AbortRefusal
  = AbortNoSuchTransaction
  | -- | Writes are still in flight: the pages and buffers are in use and stay
    -- claimed until they drain.
    AbortStillInFlight !Int
  deriving stock (Eq, Show)

-- | Abandon a transaction that has not published. It needs no write: the committed
-- roots were never changed. It is refused while any write is in flight, so no page
-- or buffer is released while it is in use.
abortTransaction ∷ TxnId → Store → Either AbortRefusal Store
abortTransaction tid s = case sActive s of
  Just a | acId a == tid →
    let inflight = length [() | (_, PsInFlight) ← Map.toList (acPages a)]
     in if inflight > 0 then Left (AbortStillInFlight inflight) else Right s {sActive = Nothing}
  _ → Left AbortNoSuchTransaction

-- | The encoded pages the active transaction must write.
activePages ∷ TxnId → Store → Maybe [(PageNo, ByteString)]
activePages tid s = case sActive s of
  Just a | acId a == tid → Just (plPages (acPlan a))
  _ → Nothing

-- | What the owner may inspect of the active transaction.
data ActiveView = ActiveView
  { avId ∷ !TxnId
  , avStaged ∷ !Int
  , avInFlight ∷ !Int
  , avWritten ∷ !Int
  , avFailed ∷ !Int
  , avCancelRequested ∷ !Bool
  , avClaimedPages ∷ !Int
  , avBase ∷ !Authority
  }
  deriving stock (Eq, Show)

activeView ∷ Store → Maybe ActiveView
activeView s = do
  a ← sActive s
  let states = map snd (Map.toList (acPages a))
      count st = length (filter (== st) states)
  Just
    ActiveView
      { avId = acId a
      , avStaged = count PsStaged
      , avInFlight = count PsInFlight
      , avWritten = count PsWritten
      , avFailed = count PsFailed
      , avCancelRequested = acCancel a
      , avClaimedPages = mClaimed (plMeasure (acPlan a))
      , avBase = pidBase (plIdentity (acPlan a))
      }

-- ---------------------------------------------------------------------------
-- Conditions

-- | The conditions that pause new history now.
conditions ∷ Store → [Condition]
conditions = Set.toAscList . sConditions

-- | Record a condition (the effect owner's report): idempotent.
pauseFor ∷ Condition → Store → Store
pauseFor c s = s {sConditions = Set.insert c (sConditions s)}

-- | Clear one condition after the owner has verified it is gone. A larger
-- allowance clears only the capacity condition, through 'commitGrowth'; this is the
-- explicit path for the others.
clearCondition ∷ Condition → Store → Store
clearCondition c s = s {sConditions = Set.delete c (sConditions s)}

-- ---------------------------------------------------------------------------
-- Readers

-- | A pin on one committed version, unforgeable outside this module.
data ReaderToken = ReaderToken
  { rtStore ∷ !StoreIdentity
  , rtSerial ∷ !Word64
  , rtVersion ∷ !Word64
  }
  deriving stock (Eq, Show)

data ReaderRefusal = TooManyReaders !Int
  deriving stock (Eq, Show)

data StaleReader = StaleReader
  deriving stock (Eq, Show)

-- | Pin the committed version. The pin is accounted and bounded.
acquireReader ∷ Store → Either ReaderRefusal (ReaderToken, Store)
acquireReader s
  | Map.size (sReaders s) >= maxReaders = Left (TooManyReaders maxReaders)
  | otherwise =
      let r = sRoots s
          pins = Pins (rVersion r) (rRuns r) (rLinks r) (rTodo r) (rRootCrcs r) (rHw r)
          n = sNextReader s
       in Right (ReaderToken (sIdent s) n (rVersion r), s {sReaders = Map.insert n pins (sReaders s), sNextReader = n + 1})

-- | Release a pin. Releasing twice, or a token of another store, changes nothing.
releaseReader ∷ ReaderToken → Store → (EventResult, Store)
releaseReader tok s
  | rtStore tok /= sIdent s = (Unknown, s)
  | Map.member (rtSerial tok) (sReaders s) = (Applied, s {sReaders = Map.delete (rtSerial tok) (sReaders s)})
  | otherwise = (Duplicate, s)

pinsOf ∷ Store → ReaderToken → Either StaleReader Pins
pinsOf s tok
  | rtStore tok /= sIdent s = Left StaleReader
  | otherwise = case Map.lookup (rtSerial tok) (sReaders s) of
      Just p | pinVersion p == rtVersion tok → Right p
      _ → Left StaleReader

-- | The version a live token pins.
readerVersion ∷ Store → ReaderToken → Either StaleReader Word64
readerVersion s tok = pinVersion <$> pinsOf s tok

-- | An empty window for a reader's version.
readerWindow ∷ Store → ReaderToken → Either StaleReader Window
readerWindow s tok = (\p → windowTrust (pinTrust p) (emptyWindow (sIdent s) (pinVersion p))) <$> pinsOf s tok

rootsOfPins ∷ Pins → TreeId → Maybe PageNo
rootsOfPins p TreeRuns = pinRuns p
rootsOfPins p TreeLinks = pinLinks p
rootsOfPins p TreeTodo = pinTodo p
rootsOfPins _ _ = Nothing

-- | What a bounded read through a window answered.
data ReadOutcome a
  = -- | The answer (a confirmed absence is an answer: @Nothing@ or an empty list).
    Read !a
  | -- | A page is missing from the window: fetch it, add it and read again. The
    -- read is pending, never answered as absent.
    ReadNeeds !PageNo
  | -- | A page contradicts its place in the tree: an integrity failure, never an
    -- empty or absent answer.
    ReadCorrupt !IntegrityWhy
  | -- | The token is not a live pin of this store.
    ReadStale
  | -- | The window was made for another store or another version than the pin's.
    ReadWrongWindow !WindowRefusal
  deriving stock (Eq, Show)

readOutcome ∷ Either Stop a → ReadOutcome a
readOutcome (Right a) = Read a
readOutcome (Left (Need p)) = ReadNeeds p
readOutcome (Left (Bad err p)) = ReadCorrupt (BadPage err p)
readOutcome (Left (TooTall t)) = ReadCorrupt (BrokenInvariant t)
readOutcome (Left (Invariant t)) = ReadCorrupt (BrokenInvariant t)
readOutcome (Left (Over _)) = ReadCorrupt CorruptCounters

-- | Run a read against a pinned version, refusing a dead token and a window of another
-- store or version before any page is read.
withPins ∷ Store → ReaderToken → Window → (Pins → Either Stop a) → ReadOutcome a
withPins s tok win f = case pinsOf s tok of
  Left StaleReader → ReadStale
  Right p → case windowRefusal (sIdent s) (pinVersion p) win of
    Just w → ReadWrongWindow w
    Nothing → readOutcome (f p)

-- | The pinned record for a key.
readerLookup ∷ Store → ReaderToken → Window → RecordKey → ReadOutcome (Maybe Record)
readerLookup s tok win key = withPins s tok win (\p → lookupRecord (pinView p win) (rootsOfPins p) key)

-- | The pinned removed run of a column at or below a level.
readerFloorRun ∷ Store → ReaderToken → Window → Column → Int64 → ReadOutcome (Maybe (Int64, Int64))
readerFloorRun s tok win col z = withPins s tok win (\p → floorRun (pinView p win) (rootsOfPins p) col z)

-- | A bounded ordered read of one record tree from a start (a key, or strictly after
-- one): at most 'maxRangeRecords' records, each costing one bounded successor lookup.
readerRange ∷ Store → ReaderToken → Window → TreeId → RangeStart → Int → ReadOutcome [(RecordKey, Record)]
readerRange s tok win tree start limit = withPins s tok win (\p → rangeRecords (pinView p win) (rootsOfPins p) tree start (min limit maxRangeRecords))

-- | The most records one ranged read returns.
maxRangeRecords ∷ Int
maxRangeRecords = 256

-- | Why a pinned provider or lookup could not be made.
data PinRefusal = PinStale | PinWindow !WindowRefusal
  deriving stock (Eq, Show)

-- | The provider over a pinned version.
readerProviderFor ∷ Store → ReaderToken → Window → Either PinRefusal Provider
readerProviderFor s tok win = do
  p ← either (const (Left PinStale)) Right (pinsOf s tok)
  maybe (Right (providerFor (pinView p win) (rootsOfPins p))) (Left . PinWindow) (windowRefusal (sIdent s) (pinVersion p) win)

-- | Why a pinned record is unavailable: the page to fetch, or an integrity failure.
readerMissing ∷ Store → ReaderToken → Window → RecordKey → Either PinRefusal (Either IntegrityWhy (Maybe PageNo))
readerMissing s tok win key = do
  p ← either (const (Left PinStale)) Right (pinsOf s tok)
  maybe (Right (missingPage (pinView p win) (rootsOfPins p) key)) (Left . PinWindow) (windowRefusal (sIdent s) (pinVersion p) win)

-- ---------------------------------------------------------------------------
-- Growth

-- | What a request to enlarge the allowance decided, before any provider work.
data GrowthDecision
  = -- | The same size: an idempotent success that changes nothing.
    GrowthNoOp
  | -- | A well-formed size below the current allowance: the request settles as
    -- @storage_size_not_increased@.
    GrowthNotIncreased
  | -- | A malformed, misaligned, too small or out-of-range size: a validation
    -- refusal before any provider work.
    GrowthInvalid !ConfigError
  | GrowthProposed !GrowthProposal
  deriving stock (Eq, Show)

-- | Propose a larger allowance for this store.
proposeGrowth ∷ Store → Integer → GrowthDecision
proposeGrowth s bytes = case validateSize (sCfg s) bytes of
  -- the size rules (minimum, alignment, offset limit) come first and alone
  Left err → GrowthInvalid err
  Right ()
    | bytes == toInteger (cfgAllowanceBytes (sCfg s)) → GrowthNoOp
    | bytes < toInteger (cfgAllowanceBytes (sCfg s)) → GrowthNotIncreased
    -- only an increase builds a replacement configuration, with the overhead it already has
    | otherwise → case growConfig (sCfg s) bytes of
        Left err → GrowthInvalid err
        Right cfg → GrowthProposed (GrowthProposal (sIdent s) (cfgAllowanceBytes (sCfg s)) (cfgAllowanceBytes cfg) cfg)

data GrowthRefusal
  = GrowthBusyTransaction
  | GrowthAlreadyExecuting
  | -- | An earlier growth's extra reservation is still to be released.
    GrowthReleasePending
  | -- | The proposal was made against another allowance or store: re-propose.
    GrowthStale
  | GrowthNotExecuting
  | GrowthNotReserved
  deriving stock (Eq, Show)

-- | Begin executing a proposal: serialised with mutation, against the allowance as
-- it is now.
beginGrowth ∷ GrowthProposal → Store → Either GrowthRefusal Store
beginGrowth p s
  | isJust (sActive s) = Left GrowthBusyTransaction
  | GrowthExecuting _ _ ← sGrowth s = Left GrowthAlreadyExecuting
  | GrowthReleasing _ ← sGrowth s = Left GrowthReleasePending
  | gpIdentity p /= sIdent s || gpFrom p /= cfgAllowanceBytes (sCfg s) = Left GrowthStale
  | otherwise = Right s {sGrowth = GrowthExecuting p False}

-- | The effect owner obtained the additional reservation. It is accounted as
-- pending and is not spendable until 'commitGrowth'.
growthReserved ∷ Store → Either GrowthRefusal Store
growthReserved s = case sGrowth s of
  GrowthExecuting p _ → Right s {sGrowth = GrowthExecuting p True}
  _ → Left GrowthNotExecuting

-- | Publish the larger allowance. Only a growth whose reservation was reported
-- obtained commits; it clears the capacity pause and nothing else.
commitGrowth ∷ Store → Either GrowthRefusal Store
commitGrowth s = case sGrowth s of
  GrowthExecuting p True
    | gpFrom p /= cfgAllowanceBytes (sCfg s) → Left GrowthStale
    | otherwise →
        Right s {sCfg = gpConfig p, sGrowth = GrowthIdle, sConditions = Set.delete CondCapacity (sConditions s)}
  GrowthExecuting _ False → Left GrowthNotReserved
  _ → Left GrowthNotExecuting

-- | The growth failed or was cancelled before commitment: the old allowance and
-- roots stand. An extra reservation it had obtained stays accounted as pending
-- until the owner reports its release.
growthFailed ∷ Store → Store
growthFailed s = case sGrowth s of
  GrowthExecuting p True → s {sGrowth = GrowthReleasing (gpTo p - gpFrom p)}
  GrowthExecuting _ False → s {sGrowth = GrowthIdle}
  _ → s

-- | The extra reservation was released.
growthReleased ∷ Store → Store
growthReleased s = case sGrowth s of
  GrowthReleasing _ → s {sGrowth = GrowthIdle}
  _ → s

-- | The release itself failed: the pending reservation stays accounted and reported.
growthReleaseFailed ∷ Store → Store
growthReleaseFailed = id

-- | What a status request may report of growth.
data GrowthView = GrowthView
  { gvExecuting ∷ !Bool
  , gvPendingBytes ∷ !Word64
  , gvReleasing ∷ !Bool
  }
  deriving stock (Eq, Show)

growthView ∷ Store → GrowthView
growthView s = case sGrowth s of
  GrowthIdle → GrowthView False 0 False
  GrowthExecuting p r → GrowthView True (if r then gpTo p - gpFrom p else 0) False
  GrowthReleasing b → GrowthView False b True

-- ---------------------------------------------------------------------------
-- Feasibility

-- | A requirement that cannot be met by a configuration: what, the figure needed and
-- the figure available. It is retained for the design decision, never relaxed.
data Counterexample = Counterexample
  { cxWhat ∷ !String
  , cxNeeded ∷ !Integer
  , cxAvailable ∷ !Integer
  }
  deriving stock (Eq, Show)

-- | The most RAM the minimum explicit removal reserves: a full window, its pages and
-- the control records.
minimumRemovalRam ∷ Int
minimumRemovalRam = removalRamWith worstEditWrites worstEditReads minimumRemovalPages

-- | The RAM the smallest unit of discovery (one connection inspection: 'worstEdgeWrites' writes, 'worstEdgeReads' reads) reserves,
-- by the same account: a full window, its pages, the control records and the read facts it retains.
minimumDiscoveryUnitRam ∷ Int
minimumDiscoveryUnitRam = removalRamWith worstEdgeWrites worstEdgeReads discoveryUnitPagesWritten

-- | The RAM an edit of the given writes and reads reserves in the worst state: the pages it writes, a full window, the ownership
-- proofs, the overlay, the control records and, as a retained continuation, the 'recordFactBytes' of every record it reads.
removalRamWith ∷ Int → Int → Int → Int
removalRamWith writes nReads pages = ramTotal (worstChargeWith pages writes (nReads * recordFactBytes))

-- | Whether the supported minimum explicit removal fits a configuration in an empty
-- workspace: its pages within the transaction bound, its RAM within the
-- transaction bound, and its claim within the allowance beside the protected
-- reserve.
minimumRemovalFeasible ∷ StoreConfig → Either Counterexample ()
minimumRemovalFeasible cfg
  | minimumRemovalPages > maxTxnPages = Left (Counterexample "pages written by the minimum removal" (toInteger minimumRemovalPages) (toInteger maxTxnPages))
  | minimumRemovalRam > txnRamLimit = Left (Counterexample "RAM reserved by the minimum removal" (toInteger minimumRemovalRam) (toInteger txnRamLimit))
  | minimumDiscoveryUnitRam > txnRamLimit = Left (Counterexample "RAM reserved by the smallest unit of discovery" (toInteger minimumDiscoveryUnitRam) (toInteger txnRamLimit))
  | need > have = Left (Counterexample "allowance pages for the minimum removal beside the protected reserve" need have)
  | otherwise = Right ()
  where
    need = toInteger maxClaimPages + toInteger reservePages
    have = toInteger (cfgUsablePages cfg)
