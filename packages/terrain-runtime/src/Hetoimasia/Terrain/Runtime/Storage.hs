-- | The temporary store's storage backend (TRA-21): the private reserved file of
-- an arena incarnation, bounded asynchronous page I/O on two workers, and the
-- growth of an allowance, all as values and typed results.
--
-- The backend performs the effects the pure store model
-- ("Hetoimasia.Terrain.Runtime.Store") describes and decides nothing about
-- publication: no outcome here changes a root, a revision or a request's
-- result. The terrain owner (TRA-22) holds the one current 'Store', hands this
-- service the pages a transaction staged ('stageWrite'), reports each page's
-- outcome to the model and alone decides publication.
--
-- == Using it
--
-- @
-- withStorage config admission group logger $ \\svc → do
--   Right t ← submitOpen svc ExplicitWork (OpenSpec dir identity (storeConfig store))
--   atomically (awaitTicket svc t)
--   Just (Opened backing _) ← withOutcome svc t pure       -- the backing is reserved and ready
--   Right w ← pure (stageWrite store txn)                   -- the active transaction's pages
--   Right t2 ← submitWrite svc backing w
--   atomically (awaitTicket svc t2)
--   Just (Written report) ← withOutcome svc t2 pure
--   -- report 'writeOutcomes' to the model, then the owner decides to publish or abort
--   closeBacking svc backing                                -- drains, then closes the descriptor once
-- @
--
-- == What a caller holds
--
-- A 'Backing' is an opaque authority for one arena and source incarnation: it
-- names no descriptor and the service resolves it, so a closed, foreign or
-- reused handle is refused before any I/O and a descriptor number reused by a
-- later file can never be reached through an old handle. A 'Ticket' names one job
-- of one service. The caller never sees a file, a path after the open, a buffer
-- the service still owns or an errno that is not attributed to an operation.
--
-- == State, owner, thread, lifetime
--
-- The service owns every descriptor, job and buffer. Its two workers are the only
-- threads that touch a descriptor; a caller only submits (a transaction that
-- creates and charges a job or refuses and changes nothing) and reads outcomes.
-- A backing lives from the open job's success to 'closeBacking' (or the service's
-- own close); a job's record and a read's bytes stay charged to the shared
-- edit-bank 'Admission' from submission until its outcome is retired (taken
-- through 'withOutcome' or 'discardTicket'). The module's @README@ section "The
-- storage backend" has the tables.
--
-- == The failure classes
--
-- An expected failure is a 'StorageFailure': @storage_unsupported@,
-- @reservation_failed@, @storage_io@ and @storage_integrity@ are the four of the
-- design; the others are refusals ('InvalidRequest', 'BusyNow', a closed or
-- foreign handle). A defect is 'HostFailure' and stops the service.
module Hetoimasia.Terrain.Runtime.Storage
  ( -- * The service
    StorageService
  , withStorage
  , StartFailure (..)
  , StorageConfig
  , mkStorageConfig
  , StorageConfigError (..)
  , defaultQualified
  , minHeadroomBytes
  , maxQualifiedNames
  , maxQualifiedNameBytes
  , filesystemOf

    -- * Handles
  , Backing
  , backingIdentity
  , Ticket
  , PreparedGrowth
  , preparedFrom
  , preparedTo
  , preparedAllocated

    -- * Jobs
  , WorkClass (..)
  , OpenSpec (..)
  , ReadMode (..)
  , StagedWrite
  , WriteRefusal (..)
  , stageWrite
  , stagedPages
  , stagedTxn
  , submitOpen
  , submitRead
  , submitWrite
  , submitGrowth
  , submitAbandon
  , submitReleasePending
  , commitBackingGrowth

    -- * Outcomes
  , Outcome (..)
  , Reservation (..)
  , WriteReport (..)
  , PageResult (..)
  , writeOutcomes
  , awaitTicket
  , pollTicket
  , withOutcome
  , discardTicket
  , cancelTicket
  , CancelResult (..)

    -- * Scoped use and closing
  , withUse
  , closeBacking
  , CloseReport (..)
  , backingView
  , BackingView (..)

    -- * Bounds and inspection
  , maxQueuedJobs
  , maxRunningJobs
  , maxIoJobBytes
  , maxIoPages
  , maxJobRecords
  , jobRecordBytes
  , writeEntryBytes
  , writeFailureBytes
  , transferBufferBytes
  , resultPageBytes
  , backingRecordBytes
  , ServiceView (..)
  , serviceView

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
  , Errno (..)
  ) where

import Control.Concurrent.STM (TVar)
import Control.Exception (SomeException, mask, throwIO, try)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Hetoimasia.Terrain.Runtime.Storage.Internal.File (Created (..), closeFile, createPrivate)
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native (Native (..), posixNative)
import Hetoimasia.Terrain.Runtime.Storage.Internal.Volume (VolumeProfile (..), profileOf)
import Hetoimasia.Foundation.Log (Logger)
import Hetoimasia.Foundation.Worker (WorkerGroup)
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native (productionSeam)
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types
import Hetoimasia.Terrain.Runtime.Store.Internal.Admission (Admission)

-- | Run a body with the storage service on the production native adapter. The
-- service starts its two workers in the group the caller owns and drains, closes
-- every backing and joins the workers when the body ends, whatever ended it. The
-- threaded runtime is required: a blocking native call must not stall the
-- capability the terrain owner runs on, and without it the start refuses
-- ('NotThreaded').
withStorage ∷ StorageConfig → TVar Admission → WorkerGroup → Logger → (StorageService → IO a) → IO a
withStorage config admission group logger =
  withStorageService (StoragePorts admission group logger productionSeam config)

-- | The name of the filesystem a directory is on, as THE BACKEND ITSELF reads it: a private file is
-- created in the directory exactly as an arena's is, the volume is profiled from that descriptor by the
-- same code an open's qualification runs, and the file is unlinked and closed on every exit. A suite
-- outside this package names the volume it runs on with it, so that ITS 'StorageConfig' can qualify that
-- volume the way this package's own harness does.
--
-- It qualifies nothing: whether a name is qualified stays the caller's configuration ('mkStorageConfig'),
-- and 'defaultQualified' is not widened by it. The answer is the service's own copy of the name, bounded
-- by 'maxQualifiedNameBytes' (a longer name is refused as invalid, never truncated).
filesystemOf ∷ ByteString → IO (Either StorageFailure ByteString)
filesystemOf dir
  | BS.null dir || BS.length dir > maxDirectoryBytes || BS.elem 0 dir = pure (Left (InvalidRequest DirectoryInvalid))
  | otherwise = mask $ \restore → do
      made ← createPrivate productionSeam dir 0 (const (pure ()))
      case made of
        Left failure → pure (Left (StorageIo failure))
        Right created → do
          profiled ← try @SomeException (restore (profileOf productionSeam (crFd created)))
          _ ← nativeUnlink posixNative dir (crName created)
          _ ← closeFile productionSeam (crFd created)
          case profiled of
            Left e → throwIO e
            Right (Left (op, errno)) → pure (Left (StorageIo (IoFailure op (IoErrno errno) Nothing Nothing 0 0)))
            Right (Right profile)
              | BS.length (vpFilesystem profile) > maxQualifiedNameBytes || BS.null (vpFilesystem profile) →
                  pure (Left (InvalidRequest DirectoryInvalid))
              | otherwise → pure (Right (BS.copy (vpFilesystem profile)))
