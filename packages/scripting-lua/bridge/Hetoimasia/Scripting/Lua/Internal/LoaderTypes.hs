-- | What the module loader is configured with and what it answers: the narrow
-- injected seams, the outcomes and the counts. See
-- "Hetoimasia.Scripting.Lua.Internal.Loader" for the machinery and its contract.
--
-- Nothing here runs Lua. Every seam is an operation of the application's, called on
-- the owner's thread or a callback's, and none may block or ask the owner's VM for
-- anything.
module Hetoimasia.Scripting.Lua.Internal.LoaderTypes
  ( -- * The seams
    SourceAnswer (..)
  , SourceSupplier (..)
  , ImportContext (..)
  , ResolvedAddress (..)
  , AddressResolver
  , LoaderConfig (..)
  , loaderConfig
    -- * Phases
  , ModulePhase
  , newModulePhase
  , modulePhaseActive
  , setModulePhase
    -- * Admissions and deliveries
  , RootRequest (..)
  , RootAdmission (..)
  , RootRefusal (..)
  , SourceDelivery (..)
    -- * Outcomes
  , ModuleStatus (..)
  , Blocked (..)
  , AdvanceReport (..)
  , StopReport (..)
  , LoaderCounts (..)
  ) where

import Data.ByteString (ByteString)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Hetoimasia.Scripting.Lua.Internal.Boundary (BoundaryFault)
import Hetoimasia.Scripting.Lua.Internal.ExportTypes (ExportHandle, ExportIdentity)

-- | What a source supplier knows of an identity's verified bytes.
data SourceAnswer
  = -- | Not there yet. The supplier tells the owner when that changes, by whatever
    -- means the application has, and the owner delivers the answer.
    SourcePending
  | -- | The verified Lua source text, whole. Copied by the loader, and never kept
    -- past the evaluation that uses it.
    SourceVerified !ByteString
  | -- | The source cannot be had: the supplier's bounded reason. The identity fails
    -- stickily, attributed to this.
    SourceFailure !Text
  deriving (Eq, Show)

-- | The narrow seam through which the loader gets verified source bytes.
--
-- It does no blocking read inside Lua, and neither call may block at all: both run
-- on a thread that holds the VM's gate, as application code, and are refused if they
-- ask the same VM for anything. A call that raises is the application's failure.
--
-- 'supplierAcquire' registers the loader's interest in an identity, exactly once for
-- each identity the loader holds a record of. It answers what is known now. An
-- acquire that raises took no interest. 'supplierRelease' ends the interest exactly
-- once, when the loader no longer needs the source: when its bytes were consumed,
-- when it failed, or when the loader stopped. It is called for no identity that was
-- not acquired.
data SourceSupplier = SourceSupplier
  { supplierAcquire ∷ !(ExportIdentity → IO SourceAnswer)
  , supplierRelease ∷ !(ExportIdentity → IO ())
  }

-- | The module whose code called @import@: the identity it was admitted under and its
-- label. It is the module the call's context was captured from, which is the one the
-- resolver derives a default root from, even when the call is made from a helper that
-- another instance's hook runs.
data ImportContext = ImportContext
  { importerIdentity ∷ !ExportIdentity
  , importerLabel ∷ !Text
  }
  deriving (Eq, Show)

-- | The canonical identity an @import@ resolved to, and how it is named in a
-- diagnostic: bounded, and no key.
data ResolvedAddress = ResolvedAddress
  { resolvedIdentity ∷ !ExportIdentity
  , resolvedLabel ∷ !Text
  }
  deriving (Eq, Show)

-- | The injected address resolver: the importing module's context, the path the
-- script gave, and the root identifier it gave, if it gave one. A 'Left' refuses the
-- arguments, an unknown or disabled root among them, with a reason a script sees as an
-- ordinary Lua argument error; it makes no record and starts no work. Production
-- validation and normalization of paths and roots is the content service's, behind this
-- seam.
type AddressResolver = ImportContext → Text → Maybe Text → IO (Either Text ResolvedAddress)

-- | What a module loader is made from.
data LoaderConfig = LoaderConfig
  { loaderSupplier ∷ !SourceSupplier
  , loaderResolver ∷ !AddressResolver
  , loaderEligible ∷ !(ExportIdentity → IO Bool)
    -- ^ Whether the coordinator allows the root to begin evaluating now. Asked only of
    -- the root at the head of the queue, when no chain is active, each time the loader
    -- is advanced; source arriving never answers it. A dependency of the active chain
    -- is not asked: it evaluates within the chain. A call that raises is the
    -- application's failure.
  , loaderPhase ∷ !(Maybe ModulePhase)
    -- ^ Set while the loader runs a module's code, for an application's own
    -- preconditions to read.
  }

-- | A loader over a supplier and a resolver, in which every root is always eligible and
-- no phase is published.
loaderConfig ∷ SourceSupplier → AddressResolver → LoaderConfig
loaderConfig supplier resolver = LoaderConfig supplier resolver (const (pure True)) Nothing

-- | Whether a module's top level is running, readable by an application's own
-- preconditions without asking the VM for anything. A module's top level runs in a
-- phase of its own, and acquires no engine service: the application's bindings refuse,
-- as an ordinary Lua error before their action, whatever authority a facade or a helper
-- they were reached through would give them in a hook.
newtype ModulePhase = ModulePhase (IORef Bool)

newModulePhase ∷ IO ModulePhase
newModulePhase = ModulePhase <$> newIORef False

-- | Whether a module's top level is running now.
modulePhaseActive ∷ ModulePhase → IO Bool
modulePhaseActive (ModulePhase ref) = readIORef ref

setModulePhase ∷ ModulePhase → Bool → IO ()
setModulePhase (ModulePhase ref) = writeIORef ref

-- | A root the coordinator asks the loader to evaluate.
data RootRequest = RootRequest
  { rootIdentity ∷ !ExportIdentity
  , rootLabel ∷ !Text
  }
  deriving (Eq, Show)

-- | Why a root was refused before anything was admitted. Nothing was recorded, no
-- source was asked for and no slot was taken.
data RootRefusal
  = -- | The owner holds as many identities as it may, failed and in-progress ones
    -- included: the bound.
    RootCacheFull !Int
  | -- | The identity is empty or past the bound, in bytes: the bound.
    RootIdentityInvalid !Int
  deriving (Eq, Show)

-- | What asking the loader to evaluate a root came to.
data RootAdmission
  = -- | A new identity: recorded as pending, source asked for, queued.
    RootQueued
  | -- | The identity is already pending or evaluating, as a root or as a dependency of
    -- the active chain. No new slot was taken and no second interest in its source;
    -- it is queued as a root if it was not.
    RootJoined
  | -- | The identity already came to an outcome. It is reused, and nothing is queued.
    RootSettled !ModuleStatus
  | RootRefused !RootRefusal
  | -- | The loader has stopped and admits nothing.
    RootClosed
  deriving (Eq, Show)

-- | What delivering a source to the loader came to.
data SourceDelivery
  = -- | The loader holds the answer for the identity's next turn. Delivering it
    -- evaluates nothing: that is advancing.
    SourceDelivered
  | -- | The identity's source had been delivered already, or was consumed: nothing
    -- changed.
    SourceDuplicate
  | -- | The loader holds no interest in the identity: nothing changed.
    SourceUnwanted
  | -- | The loader has stopped: nothing changed and nothing will be published.
    SourceAfterStop
  | -- | The answer was 'SourcePending', which delivers nothing.
    SourceNotYet
  deriving (Eq, Show)

-- | What an identity is, as the loader's records say.
data ModuleStatus
  = -- | Evaluated: its export table, held by the VM.
    ModuleReady !ExportHandle
  | -- | Failed stickily, with the first failure it came to.
    ModuleFailed !BoundaryFault
  | -- | Admitted, and waiting for its source or for its turn.
    ModulePending
  | -- | Its chunk is running or suspended on an import.
    ModuleEvaluating
  | -- | Pending or evaluating when the loader stopped. Not a failure of the module.
    ModuleStopped
  | -- | No record.
    ModuleUnknown
  deriving (Eq, Show)

-- | What an advance of the loader is waiting for when it returns.
data Blocked
  = -- | Nothing is queued and no chain is active.
    BlockedIdle
  | -- | The root at the head of the queue is not eligible yet.
    BlockedIneligible !ExportIdentity
  | -- | The active chain, or the root about to start, waits for this identity's source.
    BlockedSource !ExportIdentity
  | -- | The loader has stopped.
    BlockedStopped
  deriving (Eq, Show)

-- | What one advance of the loader did.
data AdvanceReport = AdvanceReport
  { advanceSettled ∷ ![(ExportIdentity, ModuleStatus)]
    -- ^ The identities that came to an outcome, ready or failed, in the order they did,
    -- dependencies included. The loader settles no request: a coordinator reads its own
    -- roots here, or from 'Hetoimasia.Scripting.Lua.Internal.Loader.lookupModule', and
    -- delivers them when its own order allows.
  , advanceBlocked ∷ !Blocked
  , advanceChainDepth ∷ !Int
    -- ^ How many module frames the active chain holds when the advance returns: not
    -- zero means a chain is unfinished.
  }
  deriving (Eq, Show)

-- | What stopping the loader left behind.
data StopReport = StopReport
  { stopIdentities ∷ ![ExportIdentity]
    -- ^ The identities that were pending or evaluating and now read
    -- 'ModuleStopped'.
  , stopFrames ∷ !Int
    -- ^ How many suspended module frames were closed.
  , stopWithdrawn ∷ !Int
    -- ^ How many source interests were withdrawn.
  , stopWasStopped ∷ !Bool
    -- ^ The loader had already stopped: this call changed nothing.
  }
  deriving (Eq, Show)

-- | The loader's own bookkeeping, for a caller that wants to see it balance.
data LoaderCounts = LoaderCounts
  { countPending ∷ !Int
  , countEvaluating ∷ !Int
  , countReady ∷ !Int
  , countFailed ∷ !Int
  , countStopped ∷ !Int
  , countQueued ∷ !Int
    -- ^ Roots admitted and not yet started.
  , countChainDepth ∷ !Int
  , countInterestsHeld ∷ !Int
    -- ^ Source interests acquired and not yet released.
  , countInterestsAcquired ∷ !Int
  , countInterestsReleased ∷ !Int
  , countSourcesHeld ∷ !Int
    -- ^ Delivered source answers waiting to be consumed.
  , countContexts ∷ !Int
    -- ^ Modules that hold an @import@ of their own.
  }
  deriving (Eq, Show)
