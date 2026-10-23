{-# LANGUAGE OverloadedStrings #-}

-- | What the module coordinator is made of. Hidden: "Hetoimasia.LuaEngine.Modules" is the public
-- view. Nothing here runs anything; "Hetoimasia.LuaEngine.Modules.State" holds the transactions
-- over it and "Hetoimasia.LuaEngine.Modules.Wiring" what the owner's thread and the request
-- endpoint do with them.
--
-- = The state, and who touches it
--
-- One 'CState' per VM, in one variable, so every invariant is a property of a transaction and not
-- of an interleaving. Four kinds of thread change it, and none waits for another:
--
-- * the VM owner's thread, from a hook (a request is admitted: 'Hetoimasia.LuaEngine.Modules.State.acceptRequest'),
--   from the loader's callbacks (a dependency is discovered, a source interest is acquired or
--   released) and from its boundary hooks (an outcome is published, a stop);
-- * a content read worker, which completes a read through the sink it was given: one transaction
--   that stores the verified buffer or the failure and hands it to the owner's inbox, and never waits;
-- * the withdrawing of a waiter (the host calls 'workCancel' on the owner's thread);
-- * the application's thread, for boot loads and for observation.
--
-- = The invariants
--
-- * @csCharges@ is the sum of the 'jobCharge' of every job, and nothing else: a source is charged
--   from the moment its read is reserved until the loader has compiled it, or the read has retired
--   if nobody wants it any more.
-- * @csSlotsFree + number of jobs whose read is queued or in flight == csPoolHeld@ while the
--   coordinator is open: the pool slots it holds are free or under a live job, never both.
-- * @csPromised@ counts identity reservations a request's admission made and 'acceptRequest' has not
--   yet turned into a job; @Map.size csJobs + csPromised@ never passes the identity bound.
-- * A job's waiters are exactly the requests that subscribed to it and have neither been answered nor
--   withdrawn; a waiter is answered or withdrawn once, whichever comes first.
-- * Jobs are never removed: an identity is permanent for the VM's life (no eviction, restart or retry).
module Hetoimasia.LuaEngine.Modules.Types
  ( -- * Configuration
    Limits (..)
  , ImportResolver
    -- * Sources
  , Fate (..)
  , SourceProblem (..)
  , Source (..)
    -- * Jobs
  , Outcome (..)
  , WaiterState (..)
  , Waiter (..)
  , BootOutcome (..)
  , BootTicket (..)
  , Job (..)
  , jobWaiterCount
    -- * The state
  , Phase (..)
  , Peaks (..)
  , CState (..)
  , newState
  , Coordinator (..)
  , Counts (..)
    -- * Failures of the coordinator itself
  , ModuleDefect (..)
  ) where

import Control.Concurrent.STM (TVar)
import Control.Exception (Exception, SomeException)
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.Content.Identity (ContentKey)
import Hetoimasia.Content.Inventory (Inventory)
import Hetoimasia.Content.ReadPool (ReadPool, ReadTicket)
import Hetoimasia.Foundation.Log (Logger)
import Hetoimasia.LuaEngine.Modules.Bank (BankLimits, Charges, Class, noCharges)
import Hetoimasia.LuaEngine.Modules.Failure (ModuleFailure)
import Hetoimasia.LuaEngine.Request (M1Requests)
import Hetoimasia.Scripting.Lua.Loading (LoaderEndpoint, RootDue)
import Hetoimasia.Scripting.Lua.Owner
  ( BoundaryFault
  , ExportHandle
  , ExportIdentity
  , ImportContext
  , ModulePhase
  )
import Hetoimasia.Scripting.Lua.Provider (Completion)

-- Configuration ----------------------------------------------------------------------------------

-- | The numbers one coordinator works to, read once from a validated profile.
data Limits = Limits
  { limitSourceBytes ∷ !Word64
  -- ^ The most source one module may have: the profile's 1 MiB.
  , limitIdentities ∷ !Int
  -- ^ The most identities the VM may hold, pending, evaluating, ready and failed: 256.
  , limitBank ∷ !BankLimits
  -- ^ The source bank (16 MiB) and the part of it only the active chain may use (1 MiB).
  , limitSlots ∷ !Int
  -- ^ The pool slots the coordinator holds for its reads, one of them for the active chain alone.
  , limitBootWaiters ∷ !Int
  -- ^ How many boot subscriptions may be unsettled at once.
  }
  deriving (Eq, Show)

-- | How an @import@ becomes a content key: the importing module's context, the path the script gave
-- and the root it named, if it named one. A 'Left' is an ordinary Lua argument error, raised before
-- any identity, source interest or work exists. Production path, Unicode and root validation, and
-- the lexical-root rules, are the content boundary's, behind this seam (LFE-12).
type ImportResolver = ImportContext → Text → Maybe Text → IO (Either Text ContentKey)

-- Sources ------------------------------------------------------------------------------------------

-- | What the immutable inventory says will become of a module's read.
data Fate
  = -- | A regular file of this length within the module limit: reserve its bytes and read it.
    FateRead !Word64
  | -- | Not an inventoried regular file: an accepted load that fails as @not_found@, with no read.
    FateMissing
  | -- | An inventoried file over the module limit, of this length: fails as @too_large@, with no read
    -- and no reserved byte.
    FateTooLarge !Word64
  deriving (Eq, Show)

-- | A source that cannot be had: the code and bounded message. The content it names is the job's.
data SourceProblem = SourceProblem
  { problemCode ∷ !Text
  , problemMessage ∷ !Text
  }
  deriving (Eq, Show)

-- | Where one module's source is.
data Source
  = -- | No read has been asked of the pool yet: it waits, among the admitted jobs, for room in the
    -- bank and a slot.
    SrcNone
  | -- | A read is queued in the pool or running on a worker.
    SrcQueued !ReadTicket
  | -- | The verified buffer arrived before the loader had a record of the identity, and waits here for
    -- the supplier to be asked.
    SrcArrived !ByteString
  | -- | A failure is known and waits here for the supplier to be asked.
    SrcFailed !SourceProblem
  | -- | The answer went to the loader (through the supplier, or its inbox), which owns it now.
    SrcHanded
  | -- | The source is no longer wanted: the interest ended, or the coordinator closed.
    SrcGone

-- Jobs ---------------------------------------------------------------------------------------------

-- | What a job has come to.
data Outcome
  = -- | Pending or evaluating.
    Live
  | -- | Ready: the export table the VM holds.
    Ready !ExportHandle
  | -- | Failed, stickily: the loader's first fault and what it is told as.
    Failed !BoundaryFault !ModuleFailure
  | -- | Pending or evaluating when the VM stopped. Not a failure of the module.
    Stopped

-- | Where a waiter is.
data WaiterState
  = -- | Subscribed; neither answered nor withdrawn.
    Registered
  | -- | The request has been answered.
    Replied
  | -- | The request withdrew: only its subscription ended, never the job.
    Detached
  deriving (Eq, Show)

-- | One request's subscription to a job.
data Waiter = Waiter
  { waiterNumber ∷ !Word64
  , waiterCompletion ∷ !Completion
  , waiterState ∷ !(TVar WaiterState)
  }

-- | How a boot load came out.
data BootOutcome
  = BootReady
  | BootFailed !ModuleFailure
  | -- | The VM stopped first.
    BootStopped
  deriving (Eq, Show)

-- | Where a boot load's outcome appears.
newtype BootTicket = BootTicket (TVar (Maybe BootOutcome))

-- | One module of one VM, from the moment a request or an import named it until the VM ends.
data Job = Job
  { jobKey ∷ !ContentKey
  , jobLabel ∷ !Text
  , jobSerial ∷ !Word64
  -- ^ The order jobs were admitted in: oldest first among equals.
  , jobFate ∷ !Fate
  , jobOutcome ∷ !Outcome
  , jobDue ∷ !(Maybe RootDue)
  -- ^ The earliest position any admitted request contributed. It is never made later, so it
  -- survives the cancellation of the request that set it. 'Nothing' for a job nothing asked for.
  , jobRoot ∷ !Bool
  -- ^ A root was submitted to the loader for it.
  , jobRecorded ∷ !Bool
  -- ^ The loader holds a record of it. A root is reserved room before it is recorded.
  , jobInterest ∷ !Bool
  -- ^ The loader holds an interest in its source: acquired and not yet released.
  , jobWaiters ∷ !(Map Word64 Waiter)
  , jobBoots ∷ ![TVar (Maybe BootOutcome)]
  , jobSource ∷ !Source
  , jobCharge ∷ !(Maybe (Word64, Class))
  -- ^ The bytes charged to the bank for its source and the region they were charged to.
  , jobNeeded ∷ !Bool
  -- ^ The active chain waits for it: its read is of the strongest class and may use the reserve.
  , jobDiagnosed ∷ !Bool
  -- ^ A diagnostic was emitted for its failure.
  }

-- | How many requests are subscribed to a job.
jobWaiterCount ∷ Job → Int
jobWaiterCount = Map.size . jobWaiters

-- The state ----------------------------------------------------------------------------------------

-- | Whether the coordinator takes new work.
data Phase = Open | Closed
  deriving (Eq, Show)

-- | The most of each that was ever held at once: instrumentation, for the examples that prove the
-- bank and the slots were never overbooked and not merely that the work finished.
data Peaks = Peaks
  { peakOrdinary ∷ !Word64
  , peakActive ∷ !Word64
  , peakSlots ∷ !Int
  , peakTotal ∷ !Word64
  }
  deriving (Eq, Show)

-- | Everything one VM's coordinator holds.
data CState = CState
  { csPhase ∷ !Phase
  , csJobs ∷ !(Map ExportIdentity Job)
  , csPromised ∷ !(Set ExportIdentity)
  -- ^ The identities a request's admission reserved room for and 'acceptRequest' has not yet turned
  -- into a job. The room is the identity's own, so taking an admission back after the job exists
  -- gives nothing back, and an admission taken back before it releases exactly its own reservation.
  , csSerial ∷ !Word64
  , csCharges ∷ !Charges
  , csSlotsFree ∷ !Int
  , csPoolHeld ∷ !Int
  , csBootWaiters ∷ !Int
  , csReadsStarted ∷ !Int
  , csDefect ∷ !(Maybe SomeException)
  -- ^ The first failure of the coordinator's own, recorded by a thread that could not raise it. The
  -- owner raises it at its next boundary.
  , csPeaks ∷ !Peaks
  }

-- | A state with this many pool slots held and nothing else.
newState ∷ Int → CState
newState slots =
  CState
    { csPhase = Open
    , csJobs = Map.empty
    , csPromised = Set.empty
    , csSerial = 0
    , csCharges = noCharges
    , csSlotsFree = slots
    , csPoolHeld = slots
    , csBootWaiters = 0
    , csReadsStarted = 0
    , csDefect = Nothing
    , csPeaks = Peaks 0 0 0 0
    }

-- | One VM's module coordinator.
data Coordinator = Coordinator
  { coordLimits ∷ !Limits
  , coordInventory ∷ !Inventory
  , coordPool ∷ !ReadPool
  , coordRequests ∷ !M1Requests
  , coordResolve ∷ !ImportResolver
  , coordLogger ∷ !Logger
  , coordRole ∷ !Text
  , coordPhase ∷ !(Maybe ModulePhase)
  , coordLoader ∷ !(TVar (Maybe LoaderEndpoint))
  , coordState ∷ !(TVar CState)
  }

-- | A coherent reading of the coordinator, for observation.
data Counts = Counts
  { jobsHeld ∷ !Int
  , jobsLive ∷ !Int
  , jobsReady ∷ !Int
  , jobsFailed ∷ !Int
  , jobsStopped ∷ !Int
  , waitersHeld ∷ !Int
  , promisedHeld ∷ !Int
  -- ^ Identities a request's admission reserved room for and the endpoint has not yet made jobs of.
  , bytesOrdinary ∷ !Word64
  , bytesActive ∷ !Word64
  , slotsFree ∷ !Int
  , slotsHeld ∷ !Int
  , readsDeferred ∷ !Int
  -- ^ Jobs whose read waits for room.
  , jobsNeeded ∷ !Int
  -- ^ Unfinished jobs the active chain waits for: its next source, and every module of the chain
  -- that imported it.
  , readsBegun ∷ !Int
  -- ^ Reads handed to the pool, ever.
  , phaseNow ∷ !Phase
  , peaksSeen ∷ !Peaks
  }
  deriving (Eq, Show)

-- | The coordinator's own bookkeeping disagreed with itself or with a collaborator: an engine defect,
-- never a failure of a module. It fails the owner, whatever its waiters.
newtype ModuleDefect = ModuleDefect Text
  deriving (Eq, Show)

instance Exception ModuleDefect
