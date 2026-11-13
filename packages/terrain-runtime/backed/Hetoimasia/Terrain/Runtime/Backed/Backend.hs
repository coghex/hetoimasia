-- | What the terrain owner does with every outcome of the storage backend (#663) and
-- of the store planner (#662): one total decision per outcome, never a wildcard.
--
-- The functions here are pure. They read an outcome and the owner's own state
-- ('Closing'), and answer a 'Handling' or a 'Reaction'; the owner (the transaction
-- driver, the opening, the closing, the growth) performs it. Keeping the decision pure
-- is what lets the suite enumerate every outcome of every job kind and assert what
-- the owner does, and what lets the compiler prove that a constructor added to the
-- backend or the store is decided here: no case below ends in a catch-all.
--
-- == The classes of outcome
--
-- +---------------------+-------------------------------------------------------+
-- | 'HandleDomain'      | the request or open ends with an expected, typed      |
-- |                     | storage outcome; nothing is paused                    |
-- | 'HandlePause'       | the arena pauses for a cause; an uncommitted user     |
-- |                     | mutation settles with the fault; the last committed   |
-- |                     | roots, knowledge and frontier are untouched           |
-- | 'HandlePausedFor'   | new history is already paused for a cause; the        |
-- |                     | request settles with the fault recorded for it        |
-- | 'HandleRetryLater'  | temporary pressure: nothing was created, the owner    |
-- |                     | keeps the work and tries again when capacity moves    |
-- | 'HandleSerialize'   | another mutating transaction or a growth holds the    |
-- |                     | session's one mutation slot: wait for its outcome     |
-- | 'HandleReplan'      | the candidate was made against another version: it is |
-- |                     | made again against the committed one                  |
-- | 'HandleWaitReclaim' | a reader's pin holds retirement: wait for its release |
-- |                     | and a maintenance transaction                         |
-- | 'HandleClosing'     | the backing or service is going away: the work ends   |
-- |                     | as an arena closure                                   |
-- | 'HandleDefect'      | an invariant, accounting, worker or provider failure: |
-- |                     | a supervised host failure, never a domain result      |
-- +---------------------+-------------------------------------------------------+
module Hetoimasia.Terrain.Runtime.Backed.Backend
  ( -- * Owner state the decision depends on
    Closing (..)

    -- * Failures
  , JobKind (..)
  , Handling (..)
  , classifyFailure
  , classifyPlanRefusal
  , classifyAdmitRefusal

    -- * Outcomes
  , Reaction (..)
  , reactTo
  , WriteReaction (..)
  , writeReaction

    -- * Cancellation and closing
  , CancelReaction (..)
  , reactToCancel
  , CloseHandling (..)
  , reactToClose
  ) where

import Data.ByteString (ByteString)
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Terrain.Runtime.Backed.Fault
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service
  ( Backing
  , CancelResult (..)
  , CloseReport (..)
  , Outcome (..)
  , PageResult (..)
  , PreparedGrowth
  , Reservation
  , WriteReport (..)
  )
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types
  ( BusyReason
  , CleanupNote
  , InvalidWhy (..)
  , StorageFailure (..)
  )
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageNo)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model (AdmitRefusal (..), Condition (..), WriteOutcome (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan (CapacityWhy (..), PlanRefusal (..))

-- | Whether the owner is retiring the arena or the service. A backing that is closed
-- or a service that has stopped is the owner's own doing while it is closing, and a
-- defect otherwise.
data Closing = OwnerRunning | OwnerClosing
  deriving stock (Eq, Show)

-- | The kind of job an outcome answers. The same constructor means different things
-- for different jobs (an unsupported allocation is an arena open's expected result
-- and a read's impossibility), so every decision names the kind.
data JobKind = JkOpen | JkRead | JkWrite | JkGrowth | JkRelease
  deriving stock (Eq, Show, Enum, Bounded)

-- | What the owner does about a failure.
data Handling
  = HandleDomain !StorageFault
  | HandlePause !Condition !StorageFault
  | HandlePausedFor !Condition
  | HandleRetryLater !BusyReason
  | HandleSerialize
  | HandleReplan
  | -- | The retirement entries and the retired pages outstanding.
    HandleWaitReclaim !Int !Int
  | HandleClosing
  | HandleDefect !Text
  deriving stock (Eq, Show)

defect ∷ String → Handling
defect = HandleDefect . Text.pack

-- | The decision for a failure of a job of a kind.
--
-- The owner builds every request from its own validated configuration, so an
-- 'InvalidRequest' of any reason is the owner's defect, except a growth that is not
-- larger, which is the typed refusal the creator is owed.
classifyFailure ∷ Closing → JobKind → StorageFailure → Handling
classifyFailure closing kind = \case
  StorageUnsupported why → case kind of
    JkOpen → HandleDomain (FaultUnsupported why)
    -- the extra range of a growth is asked of the same allocation call
    JkGrowth → HandleDomain (FaultUnsupported why)
    JkRead → defect ("an unsupported mechanism answered a read: " <> show why)
    JkWrite → defect ("an unsupported mechanism answered a write: " <> show why)
    JkRelease → defect ("an unsupported mechanism answered a release: " <> show why)
  ReservationFailed why → case kind of
    JkOpen → HandleDomain (FaultReservation why)
    JkGrowth → HandleDomain (FaultReservation why)
    JkRead → defect ("a reservation failure answered a read: " <> show why)
    JkWrite → defect ("a reservation failure answered a write: " <> show why)
    JkRelease → defect ("a reservation failure answered a release: " <> show why)
  StorageIo io → case kind of
    -- the arena does not exist yet: it is never published, and its name is released
    JkOpen → HandleDomain (FaultIo io)
    JkRead → HandlePause CondIo (FaultIo io)
    JkWrite → HandlePause CondIo (FaultIo io)
    -- a growth that fails before it commits keeps the old cap, the roots and the pause
    JkGrowth → HandleDomain (FaultIo io)
    -- a release that failed keeps its extra pending and charged; the retry is explicit
    JkRelease → HandleDomain (FaultIo io)
  StorageIntegrity why → case kind of
    JkRead → HandlePause CondIntegrity (FaultIntegrity (FromBackend why))
    JkOpen → defect ("an integrity failure answered an open, which reads no page: " <> show why)
    JkWrite → defect ("an integrity failure answered a write, which reads no page: " <> show why)
    JkGrowth → defect ("an integrity failure answered a growth, which reads no page: " <> show why)
    JkRelease → defect ("an integrity failure answered a release, which reads no page: " <> show why)
  InvalidRequest why → invalidRequest kind why
  BusyNow reason → HandleRetryLater reason
  BackingClosed → HandleClosing
  ForeignHandle → defect "a handle of another storage service reached this one"
  ServiceStopped → case closing of
    OwnerClosing → HandleClosing
    OwnerRunning → defect "the storage service stopped under a running terrain owner"
  HostFailure why → HandleDefect why

invalidRequest ∷ JobKind → InvalidWhy → Handling
invalidRequest kind why = case why of
  -- the creator's size is validated by the store's pure proposal first: a backend that still
  -- finds it not larger reports the same typed refusal
  GrowthNotIncreasing committed asked → case kind of
    JkGrowth → HandleDomain (FaultSizeNotIncreased committed asked)
    JkOpen → ownerDefect
    JkRead → ownerDefect
    JkWrite → ownerDefect
    JkRelease → ownerDefect
  AllowanceInvalid _ → ownerDefect
  PageOutsideFile _ _ → ownerDefect
  PageWrongSize _ _ → ownerDefect
  DuplicatePage _ → ownerDefect
  TooManyPages _ → ownerDefect
  EmptyRequest → ownerDefect
  BeyondCommittedCap _ _ → ownerDefect
  PayloadBeyondBacking _ _ → ownerDefect
  IdentityMismatch → ownerDefect
  GrowthStaleBase _ _ → ownerDefect
  NoPreparedGrowth → ownerDefect
  DirectoryInvalid → ownerDefect
  CreditInvalid _ → ownerDefect
  where
    ownerDefect = defect ("the owner built an invalid " <> show kind <> " request: " <> show why)

-- | The decision for a planner refusal that the protocol driver could not resolve
-- by itself (the window-bound and loose-list refusals never reach here: the driver
-- shrinks its window for them, or asks for maintenance).
classifyPlanRefusal ∷ PlanRefusal → Handling
classifyPlanRefusal = \case
  Stale _ → HandleReplan
  Invalid why → defect ("the planner refused a valid candidate: " <> show why)
  Capacity why → case why of
    DiskFull needed available protected → HandlePause CondCapacity (FaultFull (AllowanceExhausted needed available protected))
    TreeTooTall tree → HandlePause CondCapacity (FaultFull (TreeBeyondFormat tree))
    -- a reader's pin holds the retirement the plan must first prove against
    RetirementBacklog entries pages → HandleWaitReclaim entries pages
    -- the atomic unit of every planner fits its bounds on a valid store, and the batches that
    -- can shrink are shrunk inside the call or by the driver: reaching here is a defect
    TxnPagesExceeded n → defect ("a transaction's pages exceeded their bound: " <> show n)
    TxnRamExceeded n → defect ("a transaction's RAM exceeded its bound: " <> show n)
    WindowExceeded n → defect ("a window result reached the owner: " <> show n)
    WindowBytesExceeded n → defect ("a window result reached the owner: " <> show n)
    OverlayExceeded n → defect ("a plan's new pages exceeded their bound: " <> show n)
    ListTooLarge n → defect ("a retirement list exceeded its bound: " <> show n)
    ProbesExceeded n → defect ("a window result reached the owner: " <> show n)
    BookkeepingExceeded n → defect ("the bookkeeping of a plan exceeded its bound: " <> show n)
    LooseExceeded n → defect ("the loose list result reached the owner: " <> show n)
  Integrity why → HandlePause CondIntegrity (FaultIntegrity (FromStore why))

-- | The decision for a refused admission of a planned transaction.
classifyAdmitRefusal ∷ AdmitRefusal → Handling
classifyAdmitRefusal = \case
  -- another mutating transaction or a growth holds the session's one slot: the owner serialises
  -- them, and this is the ordinary wait for the holder's outcome, not a failure
  BusyTransaction → HandleSerialize
  BusyGrowth → HandleSerialize
  StalePlan → HandleReplan
  Paused condition → HandlePausedFor condition
  NoCapacity needed available → HandlePause CondCapacity (FaultFull (AllowanceExhausted needed available 0))

-- | What an outcome of a job means to the owner.
data Reaction
  = -- | The arena's backing is reserved, proven and unlinked: only now is it ready.
    GotBacking !Backing !Reservation
  | -- | Validated pages, in the order asked.
    GotPages ![(PageNo, ByteString)]
  | GotWritten !WriteReaction
  | -- | A growth's extra range is obtained and held, not spendable: the owner commits
    -- the cap and the result in one arbitration, or abandons it.
    GotGrowthPrepared !PreparedGrowth !Reservation
  | -- | The requested allowance is the committed one: an idempotent success.
    GotGrowthNoChange
  | -- | The extra reservation was given back.
    GotReleased
  | -- | The failure's decision, and the cleanup that also failed beside it.
    GotFailure !Handling ![CleanupNote]
  | -- | The job stopped at a safe point after a cancellation request. Its cleanup
    -- notes are evidence.
    GotCancelled ![CleanupNote]
  | -- | An outcome that cannot answer this kind of job: a defect.
    GotMismatch !Text
  deriving stock (Eq, Show)

-- | The decision for an outcome of a job of a kind. Every outcome constructor is
-- matched; the kinds it can answer are checked, and one it cannot is a mismatch.
reactTo ∷ Closing → JobKind → Outcome → Reaction
reactTo closing kind = \case
  Opened backing reservation → only JkOpen "Opened" (GotBacking backing reservation)
  Pages pages → only JkRead "Pages" (GotPages pages)
  Written report → only JkWrite "Written" (GotWritten (writeReaction closing report))
  GrowthPrepared prepared reservation → only JkGrowth "GrowthPrepared" (GotGrowthPrepared prepared reservation)
  GrowthNoChange → only JkGrowth "GrowthNoChange" GotGrowthNoChange
  Released → only JkRelease "Released" GotReleased
  Failed failure notes → GotFailure (classifyFailure closing kind failure) notes
  Cancelled notes → GotCancelled notes
  where
    only wanted name reaction
      | kind == wanted = reaction
      | otherwise = GotMismatch (Text.pack (name <> " answered a " <> show kind <> " job"))

-- | A write job's report, as the model's outcomes for each page and the decision for
-- the first page that failed.
data WriteReaction = WriteReaction
  { wrOutcomes ∷ ![(PageNo, WriteOutcome)]
  -- ^ For the model, in the order staged: a page not attempted is a page not written.
  , wrAllWritten ∷ !Bool
  , wrNotAttempted ∷ ![PageNo]
  -- ^ Pages the job never reached (it stopped at a failure or at a cancellation).
  , wrFirstFailure ∷ !(Maybe (PageNo, Handling))
  -- ^ The first page whose write failed, in the order staged, and what the owner does about it.
  }
  deriving stock (Eq, Show)

-- | The report of a write job, page by page. A failed page and the pages after it are
-- not written: the transaction is not eligible, and the owner aborts it (an abort needs
-- no write) and pauses for the first failure.
writeReaction ∷ Closing → WriteReport → WriteReaction
writeReaction closing report =
  WriteReaction
    { wrOutcomes = [(page, outcome result) | (page, result) ← wrPages report]
    , wrAllWritten = all ((== Wrote) . snd) (wrPages report)
    , wrNotAttempted = [page | (page, NotAttempted) ← wrPages report]
    , wrFirstFailure = listToMaybe (mapMaybe failed (wrPages report))
    }
  where
    outcome = \case
      Wrote → WriteDone
      WriteFailedAt _ → WriteFailed
      NotAttempted → WriteFailed
    failed (page, result) = case result of
      WriteFailedAt failure → Just (page, classifyFailure closing JkWrite failure)
      Wrote → Nothing
      NotAttempted → Nothing

-- | What a cancellation request found.
data CancelReaction
  = -- | A queued job was withdrawn and settled as cancelled; it holds nothing.
    CancelWithdrawn
  | -- | A running job will stop at its next safe point and keeps every resource until it
    -- has returned: the claims of its transaction retire only after its outcome.
    CancelWaitsForDrain
  | -- | The job had finished: its outcome stands and is taken as it is.
    CancelOutcomeStands
  | -- | The ticket names nothing. The owner never retires a ticket it still cancels, so
    -- this is a defect.
    CancelDefect !Text
  deriving stock (Eq, Show)

reactToCancel ∷ CancelResult → CancelReaction
reactToCancel = \case
  CancelledBeforeDispatch → CancelWithdrawn
  CancelRequested → CancelWaitsForDrain
  CancelTooLate → CancelOutcomeStands
  CancelUnknown → CancelDefect "a cancellation named a ticket the service does not hold"

-- | What a close left, for the owner's record. A failing close is kept by the service
-- (one keeper), reported when the service ends, and never retried.
data CloseHandling = CloseHandling
  { chClosedHere ∷ !Bool
  -- ^ This call closed the descriptor.
  , chEvidence ∷ ![Text]
  -- ^ The platform's close error, a raised exception and an extra reservation that closed with the file.
  , chReservationHeld ∷ !Bool
  -- ^ The close failed where a failed close is not established to have released the descriptor
  -- (macOS, owner decision on #663, option A): the reservation stays counted until the service ends,
  -- so the owner counts it as held, never as free.
  , chPendingBytes ∷ !(Maybe Word64)
  }
  deriving stock (Eq, Show)

reactToClose ∷ CloseReport → CloseHandling
reactToClose report =
  CloseHandling
    { chClosedHere = crClosed report
    , chEvidence =
        [Text.pack ("close error: " <> show e) | Just e ← [crCloseError report]]
          <> [Text.pack ("close raised: " <> Text.unpack t) | Just t ← [crCloseException report]]
          <> [Text.pack ("extra reservation closed with the file: " <> show n) | Just n ← [crPendingReservation report]]
    , chReservationHeld = crReservationHeld report
    , chPendingBytes = crPendingReservation report
    }
