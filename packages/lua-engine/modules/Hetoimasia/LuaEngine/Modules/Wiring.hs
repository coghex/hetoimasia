{-# LANGUAGE OverloadedStrings #-}

-- | What the owner's thread, the loader and the request host see of the coordinator: the supplier,
-- the resolver, the hooks, the request endpoint with its credits and checks, the boot loads, and the
-- scope that makes and ends a coordinator. Hidden; "Hetoimasia.LuaEngine.Modules" is the public view.
module Hetoimasia.LuaEngine.Modules.Wiring
  ( -- * Making one
    ModuleSpec (..)
  , ModuleSpecRefused (..)
  , PoolTooSmall (..)
  , withModuleCoordinator
  , closeModuleCoordinator
  , attachLoader
    -- * What the owner is given
  , coordinatorPlan
  , coordinatorEndpoint
  , moduleEndpointName
  , moduleValueSchema
    -- * Asking
  , ModuleRequest (..)
  , moduleKey
  , moduleArguments
  , moduleAsk
  , startModule
  , ModuleStart (..)
  , moduleArgumentCheck
    -- * Boot loads
  , BootRefusal (..)
  , bootModule
  , awaitBoot
  , pollBoot
    -- * Observation
  , lookupImmediate
  , coordinatorCounts
  , awaitDrained
  , coordinatorLimits
  ) where

import Control.Concurrent.STM
  ( STM
  , atomically
  , newTVarIO
  , readTVar
  , retry
  , throwSTM
  , writeTVar
  )
import Control.Exception (Exception, onException, throwIO)
import Control.Monad (replicateM_, unless, when)
import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import GHC.Stack (HasCallStack)
import Hetoimasia.Content.Identity
  ( ContentKey
  , ReferenceRefusal
  , contentKeyPath
  , contentKeyRoot
  , logicalPathBytes
  , parseReference
  , rootKeyBytes
  )
import Hetoimasia.Content.Inventory (Inventory, inventoryIdentityLimits, inventoryLimitsOf, inventoryRootKey)
import Hetoimasia.Content.ReadPool (ReadPool, reserveSlot)
import Hetoimasia.Foundation.Log (Logger)
import Hetoimasia.Foundation.Resource (withResourceLabelled)
import Hetoimasia.LuaEngine.Modules.Address (moduleIdentity, moduleLabel, pathText)
import Hetoimasia.LuaEngine.Modules.Bank (BankLimits (..))
import Hetoimasia.LuaEngine.Modules.Failure (moduleCodes)
import Hetoimasia.LuaEngine.Modules.State
import Hetoimasia.LuaEngine.Modules.Types
import Hetoimasia.LuaEngine.Profile
  ( ByteLimit (ActiveChainReserveBytes, ModuleSourceBytes, SourceBankBytes)
  , Bytes (Bytes)
  , Count (Count)
  , CountLimit (ModuleIdentitiesPerVm)
  , bytesLimit
  , countLimit
  )
import Hetoimasia.LuaEngine.Request
  ( M1Ask (..)
  , M1Requests
  , M1Start (..)
  , m1Ask
  , m1ArgumentCheck
  , m1Profile
  , startM1
  )
import Hetoimasia.Scripting.Lua.Admission (Credit (..), Necessity (RequiredRequest))
import Hetoimasia.Scripting.Lua.Loading
  ( LoaderEndpoint
  , LoaderHooks (..)
  , LoaderPlan (..)
  , loaderPlan
  )
import Hetoimasia.Scripting.Lua.Owner
  ( Blocked (BlockedSource)
  , ExportIdentity
  , ModulePhase
  , ResolvedAddress (..)
  , SourceSupplier (..)
  )
import Hetoimasia.Scripting.Lua.Provider
  ( ProviderWork
  , RequestEndpoint (..)
  , Submission (..)
  , RequestInfo (..)
  )
import Hetoimasia.Scripting.Lua.Registration (ArgumentCheck, RequestContext)
import Hetoimasia.Scripting.Lua.Value (Schema (SExportTable), Value (VBytes))

-- Making one -----------------------------------------------------------------------------------------

-- | What one VM's coordinator is made from. The profile is the one the request policy was read from;
-- the numbers are read from it once.
data ModuleSpec = ModuleSpec
  { specRequests ∷ !M1Requests
  -- ^ The request policy, which carries the validated profile.
  , specInventory ∷ !Inventory
  -- ^ The immutable inventory every source is classified and verified against.
  , specPool ∷ !ReadPool
  -- ^ The session's pool of verified-read workers, shared with every other consumer.
  , specResolve ∷ !ImportResolver
  -- ^ How an @import@ becomes a content key: the content boundary's, injected.
  , specLogger ∷ !Logger
  -- ^ Where the diagnostic for a failed module nobody waits for is written.
  , specRole ∷ !Text
  -- ^ The VM's role, as a diagnostic names it.
  , specSlots ∷ !Int
  -- ^ How many pool slots the coordinator holds for its life: at least two, one of them for the
  -- active chain alone.
  , specBootWaiters ∷ !Int
  -- ^ How many boot subscriptions may be unsettled at once: at least one.
  , specPhase ∷ !(Maybe ModulePhase)
  -- ^ Set while a module's top level runs, for the application's own preconditions.
  }

-- | Why a coordinator could not be made.
data ModuleSpecRefused
  = -- | Fewer than two slots: the active chain's would leave none for prefetch.
    SlotsBelowTwo !Int
  | -- | No boot subscription could ever be taken.
    BootWaitersBelowOne !Int
  | -- | The source budget cannot guarantee the active chain its next source: the reserve must hold
    -- one module's source and be smaller than the bank. The reserve, the module limit and the bank.
    ReserveRefused !Word64 !Word64 !Word64
  | -- | A profile value does not fit a machine integer.
    LimitNotRepresentable !Text
  deriving (Eq, Show)

instance Exception ModuleSpecRefused

-- | The pool holds fewer free slots than the coordinator asked to keep: how many were asked for.
newtype PoolTooSmall = PoolTooSmall Int
  deriving (Eq, Show)

instance Exception PoolTooSmall

-- | Make a coordinator, run the body, and close it. The pool slots are reserved all together or not at
-- all, from the shared pool, and given back as the reads they back finish. The coordinator belongs
-- inside the pool's scope and outside its owners': stop the owner first.
--
-- Leaving the scope closes admission and withdraws every read no worker has taken; a read a worker
-- holds finishes in the pool, whose own scope drains it before the root and the inventory it borrows
-- can be released. The release itself never waits.
withModuleCoordinator ∷ ModuleSpec → (Coordinator → IO a) → IO a
withModuleCoordinator spec = withResourceLabelled "module coordinator" (acquire spec) (closeModuleCoordinator)

acquire ∷ ModuleSpec → IO Coordinator
acquire spec = do
  limits <- either throwIO pure (limitsOf spec)
  state <- newTVarIO (newState (limitSlots limits))
  loader <- newTVarIO Nothing
  atomically (replicateM_ (limitSlots limits) (reserveSlot (specPool spec) >>= \ok -> unless ok (throwSTM (PoolTooSmall (limitSlots limits)))))
  pure
    Coordinator
      { coordLimits = limits
      , coordInventory = specInventory spec
      , coordPool = specPool spec
      , coordRequests = specRequests spec
      , coordResolve = specResolve spec
      , coordLogger = specLogger spec
      , coordRole = specRole spec
      , coordPhase = specPhase spec
      , coordLoader = loader
      , coordState = state
      }

limitsOf ∷ ModuleSpec → Either ModuleSpecRefused Limits
limitsOf spec = do
  when (specSlots spec < 2) $ Left (SlotsBelowTwo (specSlots spec))
  when (specBootWaiters spec < 1) $ Left (BootWaitersBelowOne (specBootWaiters spec))
  when (reserve < source || reserve >= bank) $ Left (ReserveRefused reserve source bank)
  identities' <- machine "ModuleIdentitiesPerVm" identities
  Right
    Limits
      { limitSourceBytes = source
      , limitIdentities = identities'
      , limitBank = BankLimits bank reserve
      , limitSlots = specSlots spec
      , limitBootWaiters = specBootWaiters spec
      }
  where
    profile = m1Profile (specRequests spec)
    Bytes source = bytesLimit profile ModuleSourceBytes
    Bytes bank = bytesLimit profile SourceBankBytes
    Bytes reserve = bytesLimit profile ActiveChainReserveBytes
    Count identities = countLimit profile ModuleIdentitiesPerVm
    machine name value
      | value <= fromIntegral (maxBound ∷ Int) = Right (fromIntegral value)
      | otherwise = Left (LimitNotRepresentable name)

-- | Close admission, now and without waiting. Idempotent. See 'withModuleCoordinator'.
closeModuleCoordinator ∷ Coordinator → IO ()
closeModuleCoordinator = atomically . closeSTM

-- | Give the coordinator the side of its owner's loader any thread may use, once the owner exists. A
-- second endpoint is refused: a coordinator serves one VM.
attachLoader ∷ Coordinator → LoaderEndpoint → IO ()
attachLoader c endpoint = do
  attached <- atomically $ do
    held <- readTVar (coordLoader c)
    case held of
      Nothing -> True <$ writeTVar (coordLoader c) (Just endpoint)
      Just _ -> pure False
  unless attached (throwIO (ModuleDefect "a coordinator was given a second loader"))

-- What the owner is given -----------------------------------------------------------------------------

-- | The loader plan of the owner: the supplier, the resolver and the hooks, with an inbox as large as
-- the VM may hold identities, so that no root, arrived source or earlier position is ever refused
-- for want of room in it.
coordinatorPlan ∷ Coordinator → LoaderPlan
coordinatorPlan c =
  (loaderPlan supplier resolver)
    { planBound = limitIdentities (coordLimits c)
    , planPhase = coordPhase c
    , planHooks = hooks
    }
  where
    supplier =
      SourceSupplier
        { supplierAcquire = atomically . acquireSTM c
        , supplierRelease = atomically . releaseSTM c
        }
    resolver context path root =
      fmap
        (fmap (\key -> ResolvedAddress (moduleIdentity key) (moduleLabel key)))
        (coordResolve c context path root)
    hooks =
      LoaderHooks
        { hookService = atomically (defectSTM c) >>= mapM_ throwIO
        , hookSettled = \settled -> atomically (publishSTM c settled) >>= sequence_
        , hookBlocked = \case
            BlockedSource identity -> atomically (blockedSTM c identity)
            _ -> pure ()
        , hookReserved = atomically . reservedForLoaderSTM c
        , hookObserved = \identity fault -> atomically (observedReasonSTM c identity fault)
        , hookExit = atomically (closeSTM c)
        }

-- | The name of the endpoint in a grant.
moduleEndpointName ∷ Text
moduleEndpointName = "module"

-- | What @take@ hands as a success value: the export table the VM holds, by reference.
moduleValueSchema ∷ Schema
moduleValueSchema = SExportTable

-- | The endpoint a grant names.
coordinatorEndpoint ∷ Coordinator → RequestEndpoint
coordinatorEndpoint c =
  RequestEndpoint
    { endpointName = moduleEndpointName
    , endpointResult = moduleValueSchema
    , endpointSubmit = submitModule c
    }

-- | Hand a request over. Never opens a file or waits for a worker.
submitModule ∷ Coordinator → Submission → IO ProviderWork
submitModule c submission = do
  key <- keyFromArguments c (submissionArguments submission)
  let info = submissionInfo submission
  accepted <- atomically (acceptRequest c key (infoDue info) (infoNumber info) (submissionCompletion submission))
  sequence_ (acceptedActions accepted)
  pure (acceptedWork accepted)

-- | The key the arguments name, or an engine defect: a binding that passed other arguments broke the
-- endpoint's contract.
keyFromArguments ∷ Coordinator → [Value] → IO ContentKey
keyFromArguments c = \case
  [VBytes root, VBytes path] ->
    case moduleKey c path of
      Right key | rootKeyBytes (contentKeyRoot key) == root -> pure key
      Right _ -> malformed "the root is not the coordinator's"
      Left refusal -> malformed ("the path was refused: " <> show refusal)
  other -> malformed ("expected a root and a path, found " <> show (length other) <> " arguments")
  where
    malformed why = throwIO (ModuleDefect (Text.pack ("the module endpoint was handed arguments it does not take: " <> why)))

-- Asking ----------------------------------------------------------------------------------------------

-- | A request for a module: the content it names and a logical owner's tick offset (positive;
-- 'Nothing' is the default of one). Every module request is required.
data ModuleRequest = ModuleRequest
  { requestedKey ∷ !ContentKey
  , requestedOffset ∷ !(Maybe Word64)
  }

-- | The key a reference names in this inventory's root: the checked-address boundary. A malformed
-- reference is a permanent argument error, refused before any admission, never a content failure.
moduleKey ∷ Coordinator → ByteString → Either ReferenceRefusal ContentKey
moduleKey c =
  parseReference
    (inventoryIdentityLimits (inventoryLimitsOf (coordInventory c)))
    (inventoryRootKey (coordInventory c))

-- | The two values the endpoint is handed: the root key and the NFC path, as bytes.
moduleArguments ∷ ModuleRequest → [Value]
moduleArguments request =
  [ VBytes (rootKeyBytes (contentKeyRoot (requestedKey request)))
  , VBytes (logicalPathBytes (contentKeyPath (requestedKey request)))
  ]

-- | The ask the host admits: the requirement, the source, the offset, the codes, and the one credit a
-- request for a new identity needs: its place among the VM's permanent identities. A request that
-- joins an identity the VM already holds needs none, so a full cache still answers joins and lookups.
moduleAsk ∷ Coordinator → ModuleRequest → IO M1Ask
moduleAsk c request = do
  held <- atomically (Map.member identity . csJobs <$> readTVar (coordState c))
  pure
    (m1Ask RequiredRequest ("module " <> pathText key))
      { askOffset = requestedOffset request
      , askCodes = moduleCodes
      , askCredits = [identityCredit c identity | not held]
      }
  where
    key = requestedKey request
    identity = moduleIdentity key

identityCredit ∷ Coordinator → ExportIdentity → Credit
identityCredit c identity =
  Credit
    { creditName = "module identity"
    , creditReserve = reserveIdentitySTM c identity
    , creditRelease = releaseIdentitySTM c identity
    , creditTransfers = False
    }

-- | Start a request for a module atomically: accepted, or busy with nothing reserved. A new identity
-- reserves its permanent place together with the request's own records, before the endpoint is handed
-- anything and before a source is asked for; temporary pressure on the request, result or identity
-- banks is the host's busy answer with no handle, read or partial reservation.
startModule ∷ HasCallStack ⇒ Coordinator → ModuleRequest → RequestContext → IO () → IO ModuleStart
startModule c request context after = do
  ask <- moduleAsk c request
  -- Whatever the admission comes to, the room its check reserved is adopted or given back; an exception
  -- that leaves the admission undecided gives it back too.
  started <-
    startM1 (coordRequests c) ask context moduleEndpointName (moduleArguments request) after
      `onException` atomically (releaseCheckSTM c (requestedKey request))
  case started of
    M1Busy _ -> do
      -- Not accepted: the room the argument check reserved was not adopted, and is given back.
      atomically (releaseCheckSTM c (requestedKey request))
      -- The identity cache never frees a place, so a place that is gone is gone: if the admission met a
      -- full cache, or a coordinator that closed, after the argument check let it through (another
      -- thread's boot load took the last place in between), it was not a bank that would have room
      -- later. The permanent state is read after the failed admission, and can only have grown.
      atomically (permanentRefusalSTM c (requestedKey request)) >>= \case
        Just why -> pure (StartRefused why)
        Nothing -> pure (StartAnswered started)
    M1Accepted _ -> pure (StartAnswered started)

-- | What starting a request for a module came to: what the request host answered, or a permanent
-- refusal. The argument check decides the permanent questions and holds the place, so only a call that
-- skipped the check meets one here: the caller fails that call with the reason, as the host fails a call
-- that skipped its own permanent checks, and never answers busy for what waiting cannot change.
data ModuleStart
  = -- | Accepted, or busy on a temporary bank.
    StartAnswered !M1Start
  | -- | The identity cache is full for a new identity, or the coordinator has closed: the bounded reason.
    StartRefused !Text
  deriving (Eq, Show)

-- | The argument check of a binding that builds the request from its copied arguments: the host's
-- permanent refusals first (role, phase, offset, ceiling, exhausted numbers), then this one's: a new
-- identity when the VM already holds every identity it may, or a coordinator that has closed. Each is
-- an ordinary Lua error before any admission, never busy.
moduleArgumentCheck ∷ Coordinator → ([Value] → ModuleRequest) → ArgumentCheck
moduleArgumentCheck c requestOf owner values = do
  let request = requestOf values
  ask <- moduleAsk c request
  hosts <- m1ArgumentCheck (coordRequests c) (const ask) owner values
  case hosts of
    Just why -> pure (Just why)
    Nothing -> atomically (reserveForCheckSTM c (requestedKey request))

-- Boot loads --------------------------------------------------------------------------------------------

-- | Why a boot load was not accepted.
data BootRefusal
  = -- | The coordinator has closed.
    BootClosed
  | -- | A new identity, and the VM holds all it may.
    BootCacheFull
  | -- | Too many boot subscriptions are unsettled.
    BootBusy
  deriving (Eq, Show)

-- | Ask for the load of a module in the boot phase, before any role's @init@: the same identity,
-- reads and import chain as a request, with no instance, no result position and no tick. The ticket
-- says how it came out, bounded, for the startup coordinator.
bootModule ∷ Coordinator → ContentKey → IO (Either BootRefusal BootTicket)
bootModule c key =
  atomically (acceptBoot c key) >>= \case
    BootAccepted ticket -> pure (Right ticket)
    BootRefusedClosed -> pure (Left BootClosed)
    BootRefusedFull -> pure (Left BootCacheFull)
    BootRefusedBusy -> pure (Left BootBusy)

-- | The outcome of a boot load, waiting for it (to be composed with the application's supervised wait).
awaitBoot ∷ BootTicket → STM BootOutcome
awaitBoot ticket = pollBoot ticket >>= maybe retry pure

-- | The outcome of a boot load if it has one.
pollBoot ∷ BootTicket → STM (Maybe BootOutcome)
pollBoot (BootTicket var) = readTVar var

-- Observation -------------------------------------------------------------------------------------------

-- | The hook-time lookup of an identity LFE-12 binds. Exactly three answers: a ready identity's export
-- table, a failed identity's cached required failure, or not ready — which starts no work, allocates
-- no identity, joins no job and contributes no position.
lookupImmediate ∷ Coordinator → ExportIdentity → STM ImmediateLookup
lookupImmediate = lookupImmediateSTM

-- | A coherent reading.
coordinatorCounts ∷ Coordinator → STM Counts
coordinatorCounts = countsSTM

-- | Block until the coordinator has closed and given everything back: every pool slot returned and
-- no byte charged. Composes with the application's supervised wait.
awaitDrained ∷ Coordinator → STM ()
awaitDrained c = drainedSTM c >>= \done -> unless done retry

-- | The numbers the coordinator works to, read once from its profile.
coordinatorLimits ∷ Coordinator → Limits
coordinatorLimits = coordLimits
