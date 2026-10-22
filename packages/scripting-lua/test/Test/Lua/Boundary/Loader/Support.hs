-- | What the module loader's examples share: a rig of injected seams that records what
-- the loader asked of them, a registration whose bindings record the order of module
-- effects, and the helpers that admit, supply and advance.
--
-- Nothing here sleeps or measures time. A source is held by not being in the rig's
-- table, and released by putting it there and delivering it, so every ordering an
-- example claims is one the example arranged.
module Test.Lua.Boundary.Loader.Support
  ( -- * The rig
    Rig (..)
  , newRig
  , rigConfig
  , rigRegistration
  , rigLoader
  , withRig
  , withRigAt
  , rigLibraries
    -- * Identities
  , ident
  , rootAt
    -- * Driving the loader
  , admit
  , supply
  , supplyText
  , supplyFailure
  , supplyBytes
  , pointRigAt
  , advance
  , statusOfName
  , readyOf
  , failureOf
  , traced
  , acquired
  , released
  , actions
  , setEligible
  , allEligible
    -- * Hooks
  , hookDriver
  , runInit
    -- * Reading outcomes
  , reasonIs
  , raised
  , lua
  , Ledger (..)
  , ledger
  , balanced
  ) where

import Control.Exception (SomeException, fromException, throwIO, try)
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Encoding (decodeUtf8Lenient, encodeUtf8)
import Hetoimasia.Scripting.Lua.Internal.Export (liveExportReferences)
import Hetoimasia.Scripting.Lua.Internal.Module (Lead (..), callEntryWith)
import Hetoimasia.Scripting.Lua.Internal.Owner (ownedHost, ownedInternalVm)
import Hetoimasia.Scripting.Lua.Internal.Task (liveTaskReferences)
import Hetoimasia.Scripting.Lua.Internal.Vm (stackDepth)
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Value
import Test.HUnit.Lang (HUnitFailure)
import Test.Hspec (expectationFailure)

-- | What the rig's seams observe and answer.
data Rig = Rig
  { rigTrace ∷ !(IORef [Text])
    -- ^ What modules marked, newest first.
  , rigAcquired ∷ !(IORef [ExportIdentity])
    -- ^ Sources the loader asked for, newest first.
  , rigReleased ∷ !(IORef [ExportIdentity])
  , rigAvailable ∷ !(IORef (Map ExportIdentity SourceAnswer))
    -- ^ What the supplier answers when asked: a source it already has.
  , rigEligible ∷ !(IORef (Maybe (Set ExportIdentity)))
    -- ^ The roots the coordinator allows to begin; 'Nothing' allows all.
  , rigResolved ∷ !(IORef [(Text, Maybe Text)])
    -- ^ The calls the resolver answered, newest first.
  , rigActions ∷ !(IORef Int)
    -- ^ How many times the injected service binding's action ran.
  , rigAcquireFails ∷ !(IORef (Set ExportIdentity))
  , rigReleaseFails ∷ !(IORef (Set ExportIdentity))
  , rigReenter ∷ !(IORef (Maybe OwnedVm))
    -- ^ The VM the supplier and the resolver try to run Lua on, from inside the loader.
  , rigReentered ∷ !(IORef [Text])
    -- ^ How each of those attempts ended.
  , rigResolverFails ∷ !(IORef Bool)
  , rigPhase ∷ !ModulePhase
  }

newRig ∷ IO Rig
newRig =
  Rig
    <$> newIORef []
    <*> newIORef []
    <*> newIORef []
    <*> newIORef Map.empty
    <*> newIORef Nothing
    <*> newIORef []
    <*> newIORef 0
    <*> newIORef Set.empty
    <*> newIORef Set.empty
    <*> newIORef Nothing
    <*> newIORef []
    <*> newIORef False
    <*> newModulePhase

-- | The identity of a module of the game's root by its path.
ident ∷ Text → ExportIdentity
ident = rootAt "game"

-- | The identity of a module of a root by its path: the canonical form the rig's
-- resolver produces.
rootAt ∷ Text → Text → ExportIdentity
rootAt root path = ExportIdentity (encodeUtf8 (root <> ":" <> path))

rigRegistration ∷ Rig → Registration
rigRegistration rig = either (error . show) id (registration [] [tracing, service])
  where
    tracing =
      namespace
        "trace"
        [ stateOperation "mark" [SText] [] $ \arguments → do
            case arguments of
              [VText text] → atomicModifyIORef' (rigTrace rig) (\held → (text : held, ()))
              _ → pure ()
            pure []
        ]
    -- A service a module's top level must not acquire: the precondition refuses it,
    -- as an ordinary Lua error before the action, while a module's top level runs.
    service =
      namespace
        "svc"
        [ withPrecondition inModule . stateOperation "acquire" [] [SInteger] $ \_ → do
            atomicModifyIORef' (rigActions rig) (\held → (held + 1, ()))
            pure [VInteger 1]
        ]
    inModule _ = do
      active ← modulePhaseActive (rigPhase rig)
      pure (if active then Just "no service while a module's top level runs" else Nothing)

-- | The libraries a module's code runs with.
rigLibraries ∷ [Library]
rigLibraries = [LibraryBase, LibraryString, LibraryTable, LibraryMath, LibraryCoroutine]

-- | A loader over the rig's seams. The resolver knows two roots, @game@ and @mod@;
-- @off@ is a root the injected resolver refuses.
rigLoader ∷ Rig → LoaderConfig
rigLoader rig =
  (loaderConfig supplier resolver)
    { loaderEligible = \identity → maybe True (Set.member identity) <$> readIORef (rigEligible rig)
    , loaderPhase = Just (rigPhase rig)
    }
  where
    supplier =
      SourceSupplier
        { supplierAcquire = \identity → do
            reenterIfAsked rig "acquire"
            failing ← Set.member identity <$> readIORef (rigAcquireFails rig)
            if failing
              then ioError (userError "the supplier failed to acquire")
              else do
                atomicModifyIORef' (rigAcquired rig) (\held → (identity : held, ()))
                Map.findWithDefault SourcePending identity <$> readIORef (rigAvailable rig)
        , supplierRelease = \identity → do
            atomicModifyIORef' (rigReleased rig) (\held → (identity : held, ()))
            failing ← Set.member identity <$> readIORef (rigReleaseFails rig)
            if failing then ioError (userError "the supplier failed to release") else pure ()
        }
    resolver context path root = do
      reenterIfAsked rig "resolve"
      boom ← readIORef (rigResolverFails rig)
      if boom then ioError (userError "the resolver failed") else pure ()
      atomicModifyIORef' (rigResolved rig) (\held → ((path, root) : held, ()))
      let ExportIdentity importer = importerIdentity context
          defaultRoot = decodeUtf8Lenient (ByteString.takeWhile (/= 58) importer)
          chosen = maybe defaultRoot id root
      pure $
        if chosen `notElem` ["game", "mod"]
          then Left ("unknown or disabled root " <> chosen)
          else
            if Text.null path || ".." `Text.isInfixOf` path || "/" `Text.isPrefixOf` path
              then Left ("malformed path " <> path)
              else Right (ResolvedAddress (rootAt chosen path) (chosen <> ":" <> path))

-- | When the example asked for it, try to run Lua on the owner's VM from inside a seam,
-- and note how that ended: it is refused as a re-entry, not left waiting for the
-- operation that called the seam.
reenterIfAsked ∷ Rig → Text → IO ()
reenterIfAsked rig where_ = do
  target ← readIORef (rigReenter rig)
  forM_ target $ \vm → do
    outcome ← try (evalOwned vm (chunkName "reenter") "reentered = true")
    let how = case outcome of
          Right () → "ran"
          Left failure
            | Just (VmReentered _) ← fromException failure → "reentered"
            | otherwise → "other: " <> Text.pack (show (failure ∷ SomeException))
    atomicModifyIORef' (rigReentered rig) (\held → ((where_ <> ":" <> how) : held, ()))
    -- Refused, so the supplier goes on: the examples that want the refusal to end the
    -- operation raise it themselves.
    pure ()

-- | An owner configuration over the rig with this adjustment.
rigConfig ∷ Rig → (VmConfig → VmConfig) → VmConfig
rigConfig rig adjust =
  adjust
    (vmConfig rigLibraries)
      { vmRegistration = rigRegistration rig
      , vmPolicy = ["trace", "svc"]
      , vmOwnerName = "loader owner"
      , vmLoader = Just (rigLoader rig)
      }

-- | An owner over a new rig.
withRig ∷ (Rig → OwnedVm → IO a) → IO a
withRig = withRigAt id

-- | An owner over a new rig, with this adjustment of its configuration.
withRigAt ∷ (VmConfig → VmConfig) → (Rig → OwnedVm → IO a) → IO a
withRigAt adjust body = do
  rig ← newRig
  withVmOwner (rigConfig rig adjust) (body rig)

-- | Lua source as bytes.
lua ∷ [Text] → ByteString
lua = encodeUtf8 . Text.unlines

-- | Admit a root of the game's root, by path.
admit ∷ OwnedVm → Text → IO RootAdmission
admit owned path = admitRoot owned (RootRequest (ident path) ("game:" <> path))

-- | The source a module has now, as the supplier would answer if asked; and delivered
-- if the loader already asked.
supply ∷ Rig → OwnedVm → Text → [Text] → IO SourceDelivery
supply rig owned path body = do
  let answer = SourceVerified (lua body)
  atomicModifyIORef' (rigAvailable rig) (\held → (Map.insert (ident path) answer held, ()))
  deliverSource owned (ident path) answer

-- | The same, from text lines already joined.
supplyText ∷ Rig → OwnedVm → Text → Text → IO SourceDelivery
supplyText rig owned path body = supply rig owned path (Text.lines body)

-- | A failing source for a module.
supplyFailure ∷ Rig → OwnedVm → Text → Text → IO SourceDelivery
supplyFailure rig owned path why = do
  let answer = SourceFailure why
  atomicModifyIORef' (rigAvailable rig) (\held → (Map.insert (ident path) answer held, ()))
  deliverSource owned (ident path) answer

-- | A source of these exact bytes.
supplyBytes ∷ Rig → OwnedVm → Text → ByteString → IO SourceDelivery
supplyBytes rig owned path bytes = do
  let answer = SourceVerified bytes
  atomicModifyIORef' (rigAvailable rig) (\held → (Map.insert (ident path) answer held, ()))
  deliverSource owned (ident path) answer

-- | Have the rig's seams try to run Lua on this VM from inside the loader.
pointRigAt ∷ Rig → OwnedVm → IO ()
pointRigAt rig owned = writeIORef (rigReenter rig) (Just owned)

advance ∷ OwnedVm → IO AdvanceReport
advance = advanceLoader

statusOfName ∷ OwnedVm → Text → IO ModuleStatus
statusOfName owned path = lookupModule owned (ident path)

-- | The table a module came to, or the example fails.
readyOf ∷ OwnedVm → Text → IO ExportHandle
readyOf owned path = do
  status ← statusOfName owned path
  case status of
    ModuleReady handle → pure handle
    other → expectationFailure (Text.unpack path <> " is " <> show other) >> error "unreachable"

-- | The fault a module failed with, or the example fails.
failureOf ∷ OwnedVm → Text → IO BoundaryFault
failureOf owned path = do
  status ← statusOfName owned path
  case status of
    ModuleFailed fault → pure fault
    other → expectationFailure (Text.unpack path <> " is " <> show other) >> error "unreachable"

-- | What modules marked, oldest first.
traced ∷ Rig → IO [Text]
traced rig = reverse <$> readIORef (rigTrace rig)

acquired ∷ Rig → IO [ExportIdentity]
acquired rig = reverse <$> readIORef (rigAcquired rig)

released ∷ Rig → IO [ExportIdentity]
released rig = reverse <$> readIORef (rigReleased rig)

-- | How many times the service binding's action ran.
actions ∷ Rig → IO Int
actions rig = readIORef (rigActions rig)

-- | Allow only these roots to begin.
setEligible ∷ Rig → [Text] → IO ()
setEligible rig paths = writeIORef (rigEligible rig) (Just (Set.fromList (map ident paths)))

allEligible ∷ Rig → IO ()
allEligible rig = writeIORef (rigEligible rig) Nothing

-- | Whether a fault's reason is this module problem.
reasonIs ∷ ModuleProblem → BoundaryFault → Bool
reasonIs problem fault = boundaryReason fault == ModuleRefused problem

-- | What an action raises, as the system under test raised it: a failed assertion of the
-- example is rethrown as itself, never taken for the failure being looked for.
raised ∷ IO a → IO (Either SomeException a)
raised action = do
  outcome ← try action
  case outcome of
    Left failure | Just (assertion ∷ HUnitFailure) ← fromException failure → throwIO assertion
    _ → pure outcome

-- | A module that runs a captured behavior's @init@ hook with the capture's @self@ and
-- facade: how the instance layer runs a hook, so that what the hook calls runs outside
-- any module's top level.
hookDriver ∷ ModuleSource
hookDriver =
  ModuleSource
    (ModuleRef "driver" "1")
    (lua ["function call_init(hook, self, api, n) return hook(self, api) end"])
    [EntryPoint "call_init" Required [SInteger] []]

-- | Run the @init@ hook of the @gameplay@ behavior of a ready module, as a hook.
runInit ∷ OwnedVm → Text → IO ()
runInit owned path = do
  handle ← readyOf' owned path
  driverHandle ← loadedModule owned (ModuleRef "driver" "1") >>= maybe (error "the driver is not loaded") pure
  captured ← captureBehavior owned handle "gameplay" (FacadeValue (VRecord []))
  case captured of
    Left problem → error ("the behavior was refused: " <> show problem)
    Right found → do
      _ ← callEntryWith (LeadCaptured driverHandle "call_init" (capturedHandle found) HookInit) (ownedHost owned) driverHandle "init" [VInteger 0]
      releaseBehavior owned (capturedHandle found)
  where
    readyOf' o p = do
      status ← statusOfName o p
      case status of
        ModuleReady handle → pure handle
        other → error (Text.unpack p <> " is " <> show other)

-- | What an owner holds that the loader is answerable for: the coroutines and export
-- tables the VM anchors, the loader's own counts, and the stack depth, which every
-- operation restores.
data Ledger = Ledger
  { ledgerTasks ∷ !Int
  , ledgerExports ∷ !Int
  , ledgerCounts ∷ !LoaderCounts
  , ledgerStack ∷ !Int
  }
  deriving (Eq, Show)

ledger ∷ OwnedVm → IO Ledger
ledger owned =
  Ledger
    <$> liveTaskReferences (ownedHost owned)
    <*> liveExportReferences (ownedHost owned)
    <*> moduleLoaderCounts owned
    <*> stackDepth (ownedInternalVm owned)

-- | Whether the ledger balances: one anchored coroutine for each module frame on the
-- chain, one export table for each ready identity, every source interest acquired either
-- released or held by a pending identity, and no delivered source kept for a module
-- that has no record.
balanced ∷ Ledger → Bool
balanced found =
  ledgerTasks found == countChainDepth counts
    && ledgerExports found == countReady counts
    && countInterestsAcquired counts == countInterestsReleased counts + countInterestsHeld counts
    && countInterestsHeld counts <= countPending counts
  where
    counts = ledgerCounts found
