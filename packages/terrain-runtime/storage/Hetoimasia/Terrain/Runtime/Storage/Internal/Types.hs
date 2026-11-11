-- | The backend's vocabulary: configuration, the expected failures and the
-- identities that tell one arena incarnation, service and job from another.
--
-- Every storage failure a caller can meet is a value here ('StorageFailure'), and
-- each is one of the four classes the design names (@storage_unsupported@,
-- @reservation_failed@, @storage_io@, @storage_integrity@) or a refusal the
-- caller can classify without reading text ('InvalidWhy', 'BusyWhy', a closed or
-- foreign handle). None carries a page, a path or a descriptor number beyond the
-- bounded attribution the diagnosis needs (the operation, the page, the file
-- offset and the bytes involved).
module Hetoimasia.Terrain.Runtime.Storage.Internal.Types
  ( -- * Errors from the platform
    Errno (..)

    -- * Configuration
  , StorageConfig (..)
  , StorageConfigError (..)
  , mkStorageConfig
  , defaultQualified
  , minHeadroomBytes
  , maxIoJobBytes
  , maxIoPages
  , maxQueuedJobs
  , maxRunningJobs
  , maxJobRecords
  , maxInterrupts
  , maxDirectoryBytes

    -- * Failures
  , StorageFailure (..)
  , failureCode
  , IoOp (..)
  , IoKind (..)
  , IoFailure (..)
  , IntegrityFailure (..)
  , UnsupportedWhy (..)
  , ReservationFailure (..)
  , ReservationOp (..)
  , InvalidWhy (..)
  , BusyReason (..)
  , CleanupNote (..)

    -- * Work
  , WorkClass (..)
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.Terrain.Runtime.Store.Internal.Admission (BusyWhy, InvalidCredit)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageError, PageNo, pageSize)
import Hetoimasia.Terrain.Runtime.Store.Internal.State (ConfigError, OffsetError)

-- | An errno the platform reported.
newtype Errno = Errno Int
  deriving stock (Eq, Ord, Show)

-- | A job transfers at most 1 MiB.
maxIoJobBytes ∷ Int
maxIoJobBytes = 1024 * 1024

-- | The pages one job names: a 1 MiB job of 4 KiB pages.
maxIoPages ∷ Int
maxIoPages = maxIoJobBytes `div` pageSize

-- | Queued I/O descriptors per session: eight, shared across arenas.
maxQueuedJobs ∷ Int
maxQueuedJobs = 8

-- | Storage I/O workers: exactly two.
maxRunningJobs ∷ Int
maxRunningJobs = 2

-- | Job records the service holds at once: the queued descriptors, the running
-- jobs and the finished outcomes not yet taken or discarded. A refusal never
-- grows it; every record is charged against the edit bank from submission until
-- the outcome is retired.
maxJobRecords ∷ Int
maxJobRecords = 32

-- | How many times one transfer is retried after @EINTR@ before it is reported:
-- an interrupted call is retried without repeating transferred bytes, and a
-- storm of interruptions is a bounded failure, never a spin.
maxInterrupts ∷ Int
maxInterrupts = 64

-- | The longest directory path a backing may be opened in. A job record holds it, so
-- it is part of the record's measured size.
maxDirectoryBytes ∷ Int
maxDirectoryBytes = 512

-- | The reported free-space headroom that must remain on the file's volume after
-- the proposed reservation, growth included: 256 MiB.
minHeadroomBytes ∷ Word64
minHeadroomBytes = 256 * 1024 * 1024

-- | The filesystems a build qualifies, by the name the platform reports for the
-- filesystem the descriptor is on. This is the explicit list the contract
-- requires, never a guess from a name or from one successful native call:
-- @apfs@ on macOS and @ext4@ on Linux are the two this slice qualified
-- (the README's qualification table and the evidence under
-- @docs/evidence/terrain/tra21/@ record each). Anything else returns
-- @storage_unsupported@ even when the native call would have succeeded: that is
-- memory-backed filesystems (Linux tmpfs, ramfs), network filesystems and any
-- copy-on-write configuration whose rewrites would need fresh allocation.
defaultQualified ∷ [ByteString]
defaultQualified = ["apfs", "ext4"]

-- | The service's configuration.
data StorageConfig = StorageConfig
  { scQualified ∷ ![ByteString]
  -- ^ The qualified filesystems.
  , scHeadroomBytes ∷ !Word64
  -- ^ The headroom that must remain after a reservation; never below
  -- 'minHeadroomBytes'.
  }
  deriving stock (Eq, Show)

data StorageConfigError
  = -- | A headroom below the approved 256 MiB: a limit never loosens.
    HeadroomBelowMinimum !Word64
  deriving stock (Eq, Show)

-- | Validate a configuration. The headroom may be raised and never lowered, so a
-- test or an application cannot defeat the guard.
mkStorageConfig ∷ [ByteString] → Word64 → Either StorageConfigError StorageConfig
mkStorageConfig qualified headroom
  | headroom < minHeadroomBytes = Left (HeadroomBelowMinimum headroom)
  | otherwise = Right (StorageConfig qualified headroom)

-- | Who asks. Explicit work (a user's edit or read) precedes camera prefetch;
-- maintenance is accepted work and reclamation, which must make progress under a
-- stream of either.
data WorkClass = ExplicitWork | MaintenanceWork | CameraWork
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The native operation a failure names.
data IoOp
  = IoCreate
  | IoUnlink
  | IoCloexec
  | IoStat
  | IoStatFs
  | IoRead
  | IoWrite
  | IoSetLength
  | IoClose
  deriving stock (Eq, Show)

-- | How a transfer failed.
data IoKind
  = -- | The call failed with an errno.
    IoErrno !Errno
  | -- | A write made no progress.
    IoZeroProgress
  | -- | More than 'maxInterrupts' interruptions in a row.
    IoInterruptStorm
  | -- | A call reported moving more bytes than were asked: a platform or
    -- adapter defect, never believed.
    IoOverrun
  | -- | The call succeeded and the state it left is not what the contract
    -- requires (a descriptor that is not close-on-exec, a file that kept its
    -- name).
    IoStateWrong
  deriving stock (Eq, Show)

-- | A transfer or setup error, with the bounded attribution diagnosis and
-- revalidation need: the operation, the page and file offset where it applies,
-- and how many bytes of the failing transfer had moved.
data IoFailure = IoFailure
  { ioOp ∷ !IoOp
  , ioKind ∷ !IoKind
  , ioPage ∷ !(Maybe PageNo)
  , ioOffset ∷ !(Maybe Word64)
  , ioMoved ∷ !Word64
  , ioWanted ∷ !Word64
  }
  deriving stock (Eq, Show)

-- | A page that was read and is not the authoritative page it should be.
data IntegrityFailure
  = -- | The page decoded with a failure (checksum, format, identity, place):
    -- never absent history, empty terrain or regenerated source.
    PageInvalid !PageNo !Word64 !PageError
  | -- | The file ended inside an expected complete page.
    PageTruncated !PageNo !Word64 !Word64 !Word64
  deriving stock (Eq, Show)

-- | Why a mechanism or a filesystem is outside the contract.
data UnsupportedWhy
  = -- | The filesystem the descriptor is on is not on the qualified list; the
    -- name is what the platform reported (empty when it reported none).
    FilesystemNotQualified !ByteString
  | -- | The native allocation call itself is unsupported here.
    NativeUnsupported !ReservationOp !Errno
  | -- | The build has no native allocation for this platform.
    NoNativeAllocation
  deriving stock (Eq, Show)

-- | The reservation step a failure names.
data ReservationOp = StepAllocate | StepSetLength | StepVerify | StepRelease
  deriving stock (Eq, Show)

-- | Why an otherwise supported reservation could not be obtained.
data ReservationFailure
  = -- | The free space on the file's volume leaves less than the headroom after
    -- the request: available, requested, headroom.
    InsufficientHeadroom !Word64 !Word64 !Word64
  | -- | The platform refused the allocation.
    AllocationRefused !Errno
  | -- | The platform allocated fewer bytes than asked.
    AllocationShort !Word64 !Word64
  | -- | The length could not be established.
    LengthFailed !Errno
  | -- | The length the file reports is not the one established: found, wanted.
    LengthMismatch !Word64 !Word64
  | -- | The filesystem reports fewer allocated bytes than the file's length: a
    -- sparse file is not a reservation. Allocated, wanted.
    CoverageShort !Word64 !Word64
  | -- | The physical overhead (allocated beyond the logical size) exceeds what
    -- the model was configured to charge: measured, modelled.
    OverheadExceedsModel !Word64 !Word64
  | -- | An earlier growth's extra reservation has not been released.
    PendingReservationBlocks !Word64
  deriving stock (Eq, Show)

-- | A request refused before any I/O.
data InvalidWhy
  = AllowanceInvalid !ConfigError
  | PageOutsideFile !PageNo !OffsetError
  | PageWrongSize !PageNo !Int
  | DuplicatePage !PageNo
  | TooManyPages !Int
  | EmptyRequest
  | -- | The request's configuration names an allowance the backing has not
    -- reserved and committed: allowance asked, committed.
    BeyondCommittedCap !Word64 !Word64
  | IdentityMismatch
  | GrowthNotIncreasing !Word64 !Word64
  | GrowthStaleBase !Word64 !Word64
  | NoPreparedGrowth
  | DirectoryInvalid
  | CreditInvalid !InvalidCredit
  | ThreadedRuntimeRequired
  deriving stock (Eq, Show)

-- | Temporary pressure: nothing was created, and the same request may succeed
-- later.
data BusyReason
  = QueueFull
  | RecordsFull
  | MutationActive
  | GrowthActive
  | AccountPressure !BusyWhy
  deriving stock (Eq, Show)

-- | What the backend answers instead of an effect.
data StorageFailure
  = StorageUnsupported !UnsupportedWhy
  | ReservationFailed !ReservationFailure
  | StorageIo !IoFailure
  | StorageIntegrity !IntegrityFailure
  | InvalidRequest !InvalidWhy
  | BusyNow !BusyReason
  | -- | The handle names a backing that is closed or closing.
    BackingClosed
  | -- | The handle belongs to another service.
    ForeignHandle
  | -- | The service is closing or has stopped.
    ServiceStopped
  | -- | A defect: an invariant, accounting or worker failure, never an expected
    -- storage result. The service stops after one.
    HostFailure !Text
  deriving stock (Eq, Show)

-- | The stable code a caller maps a failure to (design P-15's names where they
-- exist).
failureCode ∷ StorageFailure → Text
failureCode f = case f of
  StorageUnsupported _ → "storage_unsupported"
  ReservationFailed _ → "reservation_failed"
  StorageIo _ → "storage_io"
  StorageIntegrity _ → "storage_integrity"
  InvalidRequest _ → "invalid_request"
  BusyNow _ → "busy"
  BackingClosed → "backing_closed"
  ForeignHandle → "foreign_handle"
  ServiceStopped → "service_stopped"
  HostFailure _ → "host_failure"

-- | A cleanup step that failed while unwinding: the step and the platform's
-- error, kept beside the primary failure and never replaced by it.
data CleanupNote = CleanupNote
  { cnStep ∷ !IoOp
  , cnErrno ∷ !Errno
  }
  deriving stock (Eq, Show)
