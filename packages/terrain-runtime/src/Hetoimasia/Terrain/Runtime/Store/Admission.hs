-- | The storage-aware admission decisions for the edit bank: the pure rules the later
-- terrain owner (TRA-22) applies to replace the baseline's lifetime-RAM retained-history
-- charge. Nothing here performs an effect, and nothing here changes the baseline.
--
-- = Which budget pays for what
--
-- The service-wide 64 MiB edit bank of "Hetoimasia.Terrain.Residency" is divided,
-- shared across arenas, into three accounts. This is the /store/ staging of the
-- edit bank; it is not the 128 MiB render and staging bank (@StagingBank@ and its
-- explicit reserve), which these decisions never touch.
--
-- +--------------------+---------+----------------------------------------------------------+
-- | Account            | Default | Charged                                                  |
-- +====================+=========+==========================================================+
-- | Record/page caches | 48 MiB  | Decoded page copies (a window's pages, pinned while a    |
-- |                    |         | plan or reader uses them), read-through copies           |
-- +--------------------+---------+----------------------------------------------------------+
-- | Staging            | 8 MiB   | A transaction's encoded I/O buffers, its keys and        |
-- |                    |         | scratch. 4 MiB are protected for a foreground mutation   |
-- +--------------------+---------+----------------------------------------------------------+
-- | Control/frontier   | 8 MiB   | Root and control records, reader pins' records, page     |
-- |                    |         | pin records and retained continuations                   |
-- +--------------------+---------+----------------------------------------------------------+
--
-- A transaction's RAM reservation ('Hetoimasia.Terrain.Runtime.Store.Internal.Plan.RamCharge',
-- at most 4 MiB) is split by 'transactionCredits'; its I/O buffers are inside that
-- reservation, not a separate bank.
--
-- = Backed and unbacked copies
--
-- A cache entry is 'Backed' (a copy of a page the store has written and holds) or
-- 'RamOnly' (the only copy: a staged page whose write has not completed, or a
-- baseline authoritative record that has no backing copy). Eviction releases only
-- backed, unpinned entries; 'dropEntry' refuses a 'RamOnly' one. Eviction never
-- deletes authoritative history or pending discovery, because those live in the
-- store and a backed copy is only a cache of them.
--
-- = All or nothing
--
-- 'reserve' funds every credit of one request in full or none: on a refusal the
-- admission is returned unchanged. Cache pressure that eviction could relieve is
-- relieved in the same step; a request that cannot fit even an empty account is
-- invalid; one that does not fit now is busy, with the reason.
--
-- = Distinct failures
--
-- 'Refusal' separates temporary pressure (@RefusedBusy@, which a release can
-- relieve), a request or configuration that can never fit (@RefusedInvalid@), and
-- the two failure classes this module never produces itself but 'classifyPlan' and
-- 'classifyAdmit' name for the store's refusals: exhausted disk allowance and
-- integrity failure. Capacity is never a licence to discard state or to retry in a
-- loop: nothing here retries.
--
-- State, ownership and lifetime: an immutable value held by the terrain owner; every
-- grant is released by the owner when its transaction ends.
module Hetoimasia.Terrain.Runtime.Store.Admission
  ( -- * Configuration
    EditBankSpec (..)
  , EditBankConfig
  , EditBankError (..)
  , mkEditBankConfig
  , defaultEditBankSpec
  , ebCacheBytes
  , ebStagingBytes
  , ebControlBytes
  , ebProtectedStagingBytes
  , ebTotalBytes
  , readerPinnedCacheBytes
  , worstTransactionCharge

    -- * Credits
  , Class (..)
  , Backing (..)
  , EntryId
  , Credit (..)
  , transactionCredits
  , maxQueuedDescriptors
  , descriptorRecordBytes
  , descriptorCredits

    -- * The admission
  , Admission
  , newAdmission
  , Grant
  , grantEntries
  , grantEvicted
  , Refusal (..)
  , BusyWhy (..)
  , InvalidCredit (..)
  , reserve
  , release
  , markBacked
  , pinEntry
  , unpinEntry
  , touchEntry
  , DropRefusal (..)
  , dropEntry
  , Ledger (..)
  , ledgers
  , arenaCacheBytes

    -- * Classification
  , Failure (..)
  , classifyPlan
  , classifyAdmit
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.List (sortOn)
import Data.Word (Word32, Word64)
import Hetoimasia.Terrain.Discovery (maxBatchUpdates)
import Hetoimasia.Terrain.Residency (ArenaId)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Model (AdmitRefusal (..), Condition)
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.State
import Hetoimasia.Terrain.Runtime.Store.Internal.Tree (hotNodeBytes, hotNodes)

-- ---------------------------------------------------------------------------
-- Configuration

-- | An unvalidated division of the edit bank. Every figure is an 'Integer' so that
-- an unrepresentable one is refused by name and never wrapped.
data EditBankSpec = EditBankSpec
  { ebsCache ∷ !Integer
  , ebsStaging ∷ !Integer
  , ebsControl ∷ !Integer
  , ebsProtectedStaging ∷ !Integer
  , ebsArenas ∷ !Integer
  -- ^ The arenas that may be open at once (the service allows four).
  , ebsReadersPerArena ∷ !Integer
  -- ^ The readers one arena's store may pin ('maxReaders').
  , ebsEditBank ∷ !Integer
  -- ^ The edit bank the three accounts must fit: 64 MiB.
  }
  deriving stock (Eq, Show)

-- | The approved division: 48 MiB caches, 8 MiB staging with 4 MiB protected, 8 MiB
-- control, four arenas of sixteen readers, inside a 64 MiB edit bank.
defaultEditBankSpec ∷ EditBankSpec
defaultEditBankSpec =
  EditBankSpec
    { ebsCache = 48 * m
    , ebsStaging = 8 * m
    , ebsControl = 8 * m
    , ebsProtectedStaging = 4 * m
    , ebsArenas = 4
    , ebsReadersPerArena = toInteger maxReaders
    , ebsEditBank = 64 * m
    }
  where
    m = toInteger mib

data EditBankConfig = EditBankConfig
  { cCache ∷ !Word64
  , cStaging ∷ !Word64
  , cControl ∷ !Word64
  , cProtected ∷ !Word64
  , cTotal ∷ !Word64
  }
  deriving stock (Eq, Show)

ebCacheBytes, ebStagingBytes, ebControlBytes, ebProtectedStagingBytes, ebTotalBytes ∷ EditBankConfig → Word64
ebCacheBytes = cCache
ebStagingBytes = cStaging
ebControlBytes = cControl
ebProtectedStagingBytes = cProtected
ebTotalBytes = cTotal

data EditBankError
  = EditBankNotPositive !String !Integer
  | EditBankUnrepresentable !String !Integer
  | -- | The three accounts together exceed the edit bank.
    AccountsExceedBank !Integer !Integer
  | ProtectedExceedsStaging !Integer !Integer
  | -- | The protected staging cannot hold one foreground transaction's staging.
    ProtectedBelowForeground !Integer !Integer
  | -- | The control account cannot hold one transaction's control records and every
    -- reader pin.
    ControlBelowNeed !Integer !Integer
  | -- | The cache cannot hold a transaction's decoded copies beside the most pinned by
    -- readers: no eviction could ever free enough.
    CacheBelowNeed !Integer !Integer
  deriving stock (Eq, Show)

-- | The cache bytes one reader may hold pinned: 32 decoded pages.
readerPinnedCacheBytes ∷ Word64
readerPinnedCacheBytes = 32 * fromIntegral windowPageBytes

-- | The most RAM one transaction can reserve at the format's bounds, by component.
worstTransactionCharge ∷ RamCharge
worstTransactionCharge =
  RamCharge
    { ramIoBuffers = maxTxnPages * pageSize
    , ramDecodedCopies = maxWindowBytes + overlayWorstBytes
    , ramKeys = 3 * maxBatchUpdates * maxEntryBytes
    , ramScratch = (maxListPages + bookkeepingReserve) * 16 + maxClaimPages * 8 + 4096 + (2 * hotNodes + 1) * hotNodeBytes
    , ramPagePins = maxWindowPages * 16
    , ramRootControl = rootRecordBytes + activeRecordBytes + 128
    , ramContinuation = 1024 + maxWindowPages * 8
    }

-- | Validate a division. A configuration is refused when a worst-case foreground
-- transaction could not be funded: its staging must fit the protected share, its
-- control records fit the control account beside every reader pin, and its decoded
-- copies fit the cache beside the most the readers can pin, so that the credits the
-- minimum explicit removal needs are either protected from camera reads or
-- reclaimable by evicting backed, unpinned copies.
mkEditBankConfig ∷ EditBankSpec → Either EditBankError EditBankConfig
mkEditBankConfig spec = do
  let fields =
        [ ("cache", ebsCache spec)
        , ("staging", ebsStaging spec)
        , ("control", ebsControl spec)
        , ("protected staging", ebsProtectedStaging spec)
        , ("arenas", ebsArenas spec)
        , ("readers per arena", ebsReadersPerArena spec)
        , ("edit bank", ebsEditBank spec)
        ]
  mapM_ check fields
  let total = ebsCache spec + ebsStaging spec + ebsControl spec
  if total > ebsEditBank spec then Left (AccountsExceedBank total (ebsEditBank spec)) else Right ()
  if ebsProtectedStaging spec > ebsStaging spec then Left (ProtectedExceedsStaging (ebsProtectedStaging spec) (ebsStaging spec)) else Right ()
  let w = worstTransactionCharge
      stagingNeed = toInteger (ramIoBuffers w + ramKeys w + ramScratch w)
      pins = ebsArenas spec * ebsReadersPerArena spec
      controlNeed = toInteger (ramPagePins w + ramRootControl w + ramContinuation w) + pins * toInteger readerRecordBytes + toInteger (fromIntegral maxQueuedDescriptors * descriptorRecordBytes)
      pinnedMax = pins * toInteger readerPinnedCacheBytes
      cacheNeed = toInteger (ramDecodedCopies w) + pinnedMax
  if stagingNeed > ebsProtectedStaging spec then Left (ProtectedBelowForeground stagingNeed (ebsProtectedStaging spec)) else Right ()
  if controlNeed > ebsControl spec then Left (ControlBelowNeed controlNeed (ebsControl spec)) else Right ()
  if cacheNeed > ebsCache spec then Left (CacheBelowNeed cacheNeed (ebsCache spec)) else Right ()
  Right
    EditBankConfig
      { cCache = fromInteger (ebsCache spec)
      , cStaging = fromInteger (ebsStaging spec)
      , cControl = fromInteger (ebsControl spec)
      , cProtected = fromInteger (ebsProtectedStaging spec)
      , cTotal = fromInteger total
      }
  where
    check (name, v)
      | v <= 0 = Left (EditBankNotPositive name v)
      | v > 2 ^ (40 ∷ Int) = Left (EditBankUnrepresentable name v)
      | otherwise = Right ()

-- ---------------------------------------------------------------------------
-- Credits

-- | Who asks. A foreground mutation may use all of the staging account; camera work
-- may not touch the protected share of it and holds no control record.
data Class = Foreground | Camera
  deriving stock (Eq, Show)

-- | Whether a cached copy is a copy of something the store holds.
data Backing
  = -- | A copy of a written page: evictable when unpinned.
    Backed
  | -- | The only copy (a staged page whose write has not completed, or a baseline
    -- authoritative record with no backing): never evicted.
    RamOnly
  deriving stock (Eq, Show)

newtype EntryId = EntryId Word64
  deriving stock (Eq, Ord, Show)

-- | One thing a request needs.
data Credit
  = -- | A cached copy: owner, bytes, backing, and whether it starts pinned.
    CacheCredit !ArenaId !Word64 !Backing !Bool
  | StagingCredit !Word64
  | ControlCredit !Word64
  deriving stock (Eq, Show)

-- | The credits one transaction needs, by the account each RAM item is charged to:
-- the I/O buffers, keys and scratch to staging; the decoded copies of its window to
-- the cache (backed, pinned while the plan runs); the page-pin records, the root and
-- control records and the retained continuation to control.
transactionCredits ∷ ArenaId → RamCharge → [Credit]
transactionCredits arena r =
  [ StagingCredit (fromIntegral (ramIoBuffers r + ramKeys r + ramScratch r))
  , CacheCredit arena (fromIntegral (ramDecodedCopies r)) Backed True
  , ControlCredit (fromIntegral (ramPagePins r + ramRootControl r + ramContinuation r))
  ]

-- | The I/O descriptors one session may have queued (P-15: eight). The workers and the
-- queue are TRA-21's; the admission charges each queued descriptor's metadata here.
maxQueuedDescriptors ∷ Int
maxQueuedDescriptors = 8

-- | The accounted control bytes of one queued descriptor's metadata.
descriptorRecordBytes ∷ Word64
descriptorRecordBytes = 128

-- | The control credit of @n@ queued descriptors, at most 'maxQueuedDescriptors'. A
-- descriptor's transfer buffer is inside its transaction's RAM reservation, not here.
descriptorCredits ∷ Int → Either InvalidCredit [Credit]
descriptorCredits n
  | n < 1 = Left EmptyRequest
  | n > maxQueuedDescriptors = Left (CreditExceedsAccount "queued descriptors" (fromIntegral n) (fromIntegral maxQueuedDescriptors))
  | otherwise = Right [ControlCredit (fromIntegral n * descriptorRecordBytes)]

-- ---------------------------------------------------------------------------
-- The admission

data Entry = Entry
  { enArena ∷ !ArenaId
  , enBytes ∷ !Word64
  , enBacking ∷ !Backing
  , enPins ∷ !Word32
  , enUse ∷ !Word64
  }

-- | The accounts' occupancy. The constructor is private: a client reads it through
-- 'ledgers'.
data Admission = Admission
  { aCfg ∷ !EditBankConfig
  , aClock ∷ !Word64
  , aEntries ∷ !(Map EntryId Entry)
  , aNextEntry ∷ !Word64
  , aStaging ∷ !(Map Word64 (Class, Word64))
  , aControl ∷ !(Map Word64 Word64)
  , aNextGrant ∷ !Word64
  }

newAdmission ∷ EditBankConfig → Admission
newAdmission cfg = Admission cfg 0 Map.empty 1 Map.empty Map.empty 1

-- | What a successful 'reserve' made: the new cache entries, and the entries it had
-- to evict (the owner discards those copies).
data Grant = Grant
  { gId ∷ !Word64
  , gEntries ∷ [EntryId]
  , gEvicted ∷ [EntryId]
  }
  deriving stock (Eq, Show)

grantEntries ∷ Grant → [EntryId]
grantEntries = gEntries

grantEvicted ∷ Grant → [EntryId]
grantEvicted = gEvicted

data BusyWhy
  = -- | Not enough unpinned backed cache could be evicted: bytes needed beyond the free
    -- cache, bytes that eviction could free.
    CachePressure !Word64 !Word64
  | StagingPressure !Word64 !Word64
  | ControlPressure !Word64 !Word64
  deriving stock (Eq, Show)

data InvalidCredit
  = -- | A credit, or the credits of an account together, larger than the account.
    CreditExceedsAccount !String !Word64 !Word64
  | -- | Camera work asked for a control record.
    CameraControl
  | -- | A request with no credit.
    EmptyRequest
  deriving stock (Eq, Show)

data Refusal
  = RefusedBusy !BusyWhy
  | RefusedInvalid !InvalidCredit
  deriving stock (Eq, Show)

cacheUsed ∷ Admission → Word64
cacheUsed a = sum (map enBytes (Map.elems (aEntries a)))

stagingUsed ∷ Admission → Word64
stagingUsed a = sum (map snd (Map.elems (aStaging a)))

controlUsed ∷ Admission → Word64
controlUsed a = sum (Map.elems (aControl a))

-- | Fund every credit of a request in full, or none. Cache credits evict backed,
-- unpinned entries, least recently used first, when the cache lacks room; a request
-- that cannot be funded leaves the admission exactly as it was.
reserve ∷ Class → [Credit] → Admission → Either Refusal (Grant, Admission)
reserve cls credits a = do
  if null credits then Left (RefusedInvalid EmptyRequest) else Right ()
  let cfg = aCfg a
      -- every total is taken in Integer, so no sum of credits can wrap
      wantCacheI = sum [toInteger b | CacheCredit _ b _ _ ← credits]
      wantStagingI = sum [toInteger b | StagingCredit b ← credits]
      wantControlI = sum [toInteger b | ControlCredit b ← credits]
      stagingLimit = case cls of
        Foreground → cStaging cfg
        Camera → cStaging cfg - cProtected cfg
      sat n = fromInteger (min n (toInteger (maxBound ∷ Word64))) ∷ Word64
  if cls == Camera && wantControlI > 0 then Left (RefusedInvalid CameraControl) else Right ()
  if wantCacheI > toInteger (cCache cfg) then Left (RefusedInvalid (CreditExceedsAccount "cache" (sat wantCacheI) (cCache cfg))) else Right ()
  if wantStagingI > toInteger stagingLimit then Left (RefusedInvalid (CreditExceedsAccount "staging" (sat wantStagingI) stagingLimit)) else Right ()
  if wantControlI > toInteger (cControl cfg) then Left (RefusedInvalid (CreditExceedsAccount "control" (sat wantControlI) (cControl cfg))) else Right ()
  -- each total now fits its account, so it fits a Word64
  let wantCache = fromInteger wantCacheI ∷ Word64
      wantStaging = fromInteger wantStagingI ∷ Word64
      wantControl = fromInteger wantControlI ∷ Word64
  if stagingUsed a + wantStaging > stagingLimit then Left (RefusedBusy (StagingPressure (stagingUsed a + wantStaging - stagingLimit) 0)) else Right ()
  if controlUsed a + wantControl > cControl cfg then Left (RefusedBusy (ControlPressure (controlUsed a + wantControl - cControl cfg) 0)) else Right ()
  let used = cacheUsed a
      deficit = if used + wantCache > cCache cfg then used + wantCache - cCache cfg else 0
      evictable = sortOn (\(i, e) → (enUse e, i)) [(i, e) | (i, e) ← Map.toList (aEntries a), enBacking e == Backed, enPins e == 0]
      (victims, freed) = takeUntil deficit evictable
  if freed < deficit then Left (RefusedBusy (CachePressure deficit (sum [enBytes e | (_, e) ← evictable]))) else Right ()
  let gid = aNextGrant a
      clock = aClock a + 1
      entries0 = foldr Map.delete (aEntries a) victims
      newIds = [EntryId (aNextEntry a + fromIntegral i) | (i, CacheCredit {}) ← zip [0 ∷ Int ..] [c | c@(CacheCredit {}) ← credits]]
      newEntries = [(i, Entry arena b backing (if pinned then 1 else 0) clock) | (i, CacheCredit arena b backing pinned) ← zip newIds [c | c@(CacheCredit {}) ← credits]]
      staging' = if wantStaging > 0 then Map.insert gid (cls, wantStaging) (aStaging a) else aStaging a
      control' = if wantControl > 0 then Map.insert gid wantControl (aControl a) else aControl a
  Right
    ( Grant gid newIds victims
    , a
        { aClock = clock
        , aEntries = foldr (uncurry Map.insert) entries0 newEntries
        , aNextEntry = aNextEntry a + fromIntegral (length newIds)
        , aStaging = staging'
        , aControl = control'
        , aNextGrant = gid + 1
        }
    )
  where
    takeUntil need es = go need es [] 0
    go need es acc got
      | got >= need = (reverse acc, got)
      | otherwise = case es of
          [] → (reverse acc, got)
          ((i, e) : rest) → go need rest (i : acc) (got + enBytes e)

-- | End a transaction's staging and control charges. Its cache entries stay as cached
-- copies (unpin them with 'unpinEntry').
release ∷ Grant → Admission → Admission
release g a = a {aStaging = Map.delete (gId g) (aStaging a), aControl = Map.delete (gId g) (aControl a)}

-- | A page the entry copies has been written: the copy is now backed.
markBacked ∷ EntryId → Admission → Admission
markBacked i a = a {aEntries = Map.adjust (\e → e {enBacking = Backed}) i (aEntries a)}

pinEntry ∷ EntryId → Admission → Admission
pinEntry i a = a {aEntries = Map.adjust (\e → e {enPins = enPins e + 1}) i (aEntries a)}

unpinEntry ∷ EntryId → Admission → Admission
unpinEntry i a = a {aEntries = Map.adjust (\e → e {enPins = if enPins e > 0 then enPins e - 1 else 0}) i (aEntries a)}

-- | Mark a use, so that least recently used eviction spares it.
touchEntry ∷ EntryId → Admission → Admission
touchEntry i a = a {aClock = aClock a + 1, aEntries = Map.adjust (\e → e {enUse = aClock a + 1}) i (aEntries a)}

data DropRefusal
  = -- | The copy is the only one: dropping it would discard authoritative state.
    DropNotBacked
  | DropPinned
  | DropUnknown
  deriving stock (Eq, Show)

-- | Discard a cached copy the owner no longer needs. Only a backed, unpinned copy
-- can go.
dropEntry ∷ EntryId → Admission → Either DropRefusal Admission
dropEntry i a = case Map.lookup i (aEntries a) of
  Nothing → Left DropUnknown
  Just e
    | enBacking e /= Backed → Left DropNotBacked
    | enPins e > 0 → Left DropPinned
    | otherwise → Right a {aEntries = Map.delete i (aEntries a)}

-- | The occupancy of the accounts, with the parts that are not interchangeable kept
-- apart.
data Ledger = Ledger
  { lgCacheLimit ∷ !Word64
  , lgCacheBacked ∷ !Word64
  , lgCacheRamOnly ∷ !Word64
  , lgCachePinned ∷ !Word64
  , lgStagingLimit ∷ !Word64
  , lgStagingForeground ∷ !Word64
  , lgStagingCamera ∷ !Word64
  , lgControlLimit ∷ !Word64
  , lgControlReserved ∷ !Word64
  }
  deriving stock (Eq, Show)

ledgers ∷ Admission → Ledger
ledgers a =
  Ledger
    { lgCacheLimit = cCache (aCfg a)
    , lgCacheBacked = sum [enBytes e | e ← es, enBacking e == Backed]
    , lgCacheRamOnly = sum [enBytes e | e ← es, enBacking e == RamOnly]
    , lgCachePinned = sum [enBytes e | e ← es, enPins e > 0]
    , lgStagingLimit = cStaging (aCfg a)
    , lgStagingForeground = sum [b | (Foreground, b) ← Map.elems (aStaging a)]
    , lgStagingCamera = sum [b | (Camera, b) ← Map.elems (aStaging a)]
    , lgControlLimit = cControl (aCfg a)
    , lgControlReserved = controlUsed a
    }
  where
    es = Map.elems (aEntries a)

-- | The cache bytes one arena holds: the account is shared, and an arena's entries
-- are charged to it alone.
arenaCacheBytes ∷ ArenaId → Admission → Word64
arenaCacheBytes arena a = sum [enBytes e | e ← Map.elems (aEntries a), enArena e == arena]

-- ---------------------------------------------------------------------------
-- Classification

-- | The outcome classes the later owner maps to results. They are never conflated:
-- temporary pressure a release can relieve, a configuration or request that can
-- never fit, an exhausted disk allowance, an integrity failure, a request that
-- must be planned again, and a pause that only an explicit recovery clears.
data Failure
  = FailBusy
  | FailInvalid
  | FailDisk
  | FailIntegrity
  | FailReplan
  | FailTooLarge
  | FailPaused !Condition
  deriving stock (Eq, Show)

-- | The class of a planning refusal.
classifyPlan ∷ PlanRefusal → Failure
classifyPlan r = case r of
  Stale _ → FailReplan
  Invalid _ → FailInvalid
  Capacity (DiskFull {}) → FailDisk
  Capacity _ → FailTooLarge
  Integrity _ → FailIntegrity

-- | The class of an admission refusal.
classifyAdmit ∷ AdmitRefusal → Failure
classifyAdmit r = case r of
  BusyTransaction → FailBusy
  BusyGrowth → FailBusy
  StalePlan → FailReplan
  Paused c → FailPaused c
  NoCapacity _ _ → FailDisk
