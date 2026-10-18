-- | What the lease examples share: a fixture of fake resources, a fake provider that
-- completes or fails a retirement on the example's command, a namespace of bindings
-- that acquire, use and release them, and the modules of Lua that call them.
--
-- Every example runs real instances on a real supervised scheduled owner that lends
-- its collection and holds leases. No module written here cleans up after itself: the
-- point of the examples is that none of them needs to.
module Test.LuaRuntime.Instance.Lease.Support
  ( -- * The fixture
    LFix (..)
  , newLFix
  , note
  , history
  , historyCount
  , position
    -- * The fake world
  , breakRelease
  , blockRelease
  , throwQuery
  , awaitReleaseEntered
  , proceedRelease
  , completeRetirement
  , failRetirement
  , assetHolders
  , providersFinish
  , provided
    -- * The modules
  , holdsAtEveryHook
  , acquiresThenRaises
  , overwrites
  , losesTheHandle
  , releasesEarly
  , usesRetired
  , failingConstructor
  , unpublishable
  , sharedAsset
  , cachesHandle
  , asyncHolder
  , asyncRollback
  , asyncShutdownFails
  , asyncNamed
  , marker
  , escalating
  , dependentHolder
  , closingDependent
  , dependentNowHolder
  , dependentRollback
  , cycler
  , overCapacity
  , breaker
  , independent
  , threadedAcquire
  , closingReleaser
  , closingHolder
  , failInit
  , noShutdown
  , badShutdownHolder
  , oneShotHolder
  , faultingHolder
  , plain
    -- * Statuses
  , isLive
  , isStopped
    -- * Configurations
  , leaseSpec
  , startLeased
  , leaseConfig
  , summaryOf
  , awaitSummary
  , awaitChargedBy
  , liveFor
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, retry, throwSTM, writeTVar)
import Control.Exception (SomeException, finally, throwIO, toException, try)
import Control.Monad (forM_, void)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Resource (Assembly, acquirePart, releaseRank, restoredStep)
import Hetoimasia.Runtime.Supervision (WorkerPolicy, WorkerStatus (WorkerLive, WorkerStopped))
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lease
import Hetoimasia.Scripting.Lua.Lending (Lending, newLending)
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value
import Test.LuaRuntime.Instance.Support
  ( IFixture
  , hooksModule
  , idOf
  , instanceSpec
  , newIFixture
  , record
  , sf
  , startWith
  )
import Test.LuaRuntime.Scheduled.Support (SFixture (sfLog), defaultSchedulerBounds)
import Test.LuaRuntime.Support (Broken (Broken))

-- The fixture ---------------------------------------------------------------------

-- | The instance fixture, the handles the owner leases through, and the fake world.
data LFix = LFix
  { lfBase ∷ !IFixture
  , lfLending ∷ !Lending
  , lfLeases ∷ !Leases
  , lfBreaking ∷ !(IORef (Set Text))
    -- ^ The resources whose release fails, after it has recorded that it ran.
  , lfProvider ∷ !(IORef (Map Text (TVar RetirementState)))
    -- ^ What each asynchronously retired resource's provider has said.
  , lfAssets ∷ !(IORef (Map Text Int))
    -- ^ The interests taken in each shared asset: the application's own count.
  , lfBlocking ∷ !(IORef (Set Text))
    -- ^ The resources whose release waits at a gate before it goes on.
  , lfEntered ∷ !(MVar ())
    -- ^ Opened when a release has reached its gate.
  , lfProceed ∷ !(MVar ())
    -- ^ Opened by the example to let a release at its gate go on.
  , lfThrowing ∷ !(TVar (Set Text))
    -- ^ The resources whose provider's query of where its retirement has got to throws.
  }

-- | A fixture whose instances may each have this much charged.
newLFix ∷ Int → IO LFix
newLFix capacity = do
  base ← newIFixture
  lending ← newLending
  leases ← newLeases lending capacity
  LFix base lending leases <$> newIORef Set.empty <*> newIORef Map.empty <*> newIORef Map.empty <*> newIORef Set.empty <*> newEmptyMVar <*> newEmptyMVar <*> newTVarIO Set.empty

-- | Record that something happened, in the order the hooks and the fakes share.
note ∷ LFix → Text → IO ()
note fixture entry = atomicModifyIORef' (sfLog (sf (lfBase fixture))) (\held → (entry : held, ()))

-- | What happened, oldest first.
history ∷ LFix → IO [Text]
history fixture = reverse <$> readIORef (sfLog (sf (lfBase fixture)))

-- | How many times this happened.
historyCount ∷ LFix → Text → IO Int
historyCount fixture wanted = length . filter (== wanted) <$> history fixture

-- | Where in the history this first happened: its length if it never did.
position ∷ [Text] → Text → Int
position entries wanted = length (takeWhile (/= wanted) entries)

-- The fake world -------------------------------------------------------------------------

-- | Make this resource's release fail the way a native cleanup does.
breakRelease ∷ LFix → Text → IO ()
breakRelease fixture name = atomicModifyIORef' (lfBreaking fixture) (\held → (Set.insert name held, ()))

-- | Make this resource's release wait at a gate, inside the release, before it goes on.
blockRelease ∷ LFix → Text → IO ()
blockRelease fixture name = atomicModifyIORef' (lfBlocking fixture) (\held → (Set.insert name held, ()))

-- | From now on the query of where this resource's retirement has got to throws.
throwQuery ∷ LFix → Text → IO ()
throwQuery fixture name = atomically (modifyTVar' (lfThrowing fixture) (Set.insert name))

-- | Wait until a release has reached its gate.
awaitReleaseEntered ∷ LFix → IO ()
awaitReleaseEntered = readMVar . lfEntered

-- | Let the release at its gate go on.
proceedRelease ∷ LFix → IO ()
proceedRelease = void . (`tryPutMVar` ()) . lfProceed

-- | The provider of this asynchronously retired resource says it is done.
completeRetirement ∷ LFix → Text → IO ()
completeRetirement fixture name = provided fixture name >>= \tv → atomically (writeTVar tv ProviderComplete)

-- | The provider says it could not retire it.
failRetirement ∷ LFix → Text → IO ()
failRetirement fixture name = provided fixture name >>= \tv → atomically (writeTVar tv (ProviderFailed (toException (Broken ("retire " <> name)))))

-- | What the provider of this resource has said so far.
provided ∷ LFix → Text → IO (TVar RetirementState)
provided fixture name = (Map.! name) <$> readIORef (lfProvider fixture)

-- | Run an example, and whatever way it ends let every provider finish what it was
-- asked to retire, so that a failing example fails instead of waiting for an owner
-- that is right to wait.
providersFinish ∷ LFix → IO a → IO a
providersFinish fixture example =
  example `finally` do
    tvs ← Map.elems <$> readIORef (lfProvider fixture)
    atomically . forM_ tvs $ \tv → readTVar tv >>= \case
      ProviderPending → writeTVar tv ProviderComplete
      _ → pure ()

-- | How many interests the instances hold in this shared asset.
assetHolders ∷ LFix → Text → IO Int
assetHolders fixture name = Map.findWithDefault 0 name <$> readIORef (lfAssets fixture)

-- A fake resource of two parts, released b then a by their ranks, however they were
-- acquired.
twoParts ∷ LFix → Text → Assembly Text
twoParts fixture name = do
  _ ← part "a" 1
  _ ← part "b" 0
  pure name
  where
    part which rank =
      acquirePart
        (name <> "." <> which)
        (releaseRank rank)
        (() <$ note fixture ("acquire " <> name <> "." <> which))
        ( \_ → do
            note fixture ("release " <> name <> "." <> which)
            blocking ← readIORef (lfBlocking fixture)
            if which == "a" && Set.member name blocking
              then void (tryPutMVar (lfEntered fixture) ()) >> readMVar (lfProceed fixture)
              else pure ()
            breaking ← readIORef (lfBreaking fixture)
            if which == "a" && Set.member name breaking
              then throwIO (Broken ("release " <> name))
              else pure ()
        )

-- A resource whose second stage fails after the first has completed.
failingStages ∷ LFix → Text → Assembly Text
failingStages fixture name = do
  _ ← acquirePart (name <> ".first") (releaseRank 0) (() <$ note fixture ("acquire " <> name <> ".first")) $ \_ → do
    note fixture ("release " <> name <> ".first")
    breaking ← readIORef (lfBreaking fixture)
    if Set.member name breaking then throwIO (Broken ("release " <> name)) else pure ()
  restoredStep (note fixture ("construct " <> name <> ".second") >> throwIO (Broken "constructor"))
  pure name

-- A resource the provider retires later: its release hands it over and returns.
asynchronous ∷ LFix → Text → Retirements → Assembly Text
asynchronous fixture name retirements = do
  _ ←
    acquirePart
      name
      (releaseRank 0)
      ( do
          tv ← newTVarIO ProviderPending
          atomicModifyIORef' (lfProvider fixture) (\held → (Map.insert name tv held, ()))
          note fixture ("acquire " <> name)
          pure tv
      )
      ( \tv → do
          note fixture ("retire " <> name)
          retireAsynchronously retirements name $ do
            throwing ← readTVar (lfThrowing fixture)
            if Set.member name throwing then throwSTM (Broken ("query " <> name)) else readTVar tv
      )
  pure name

-- A resource retired by a provider that finishes later, over a device it needs: the
-- device is acquired first and ranked last, so its release comes after the resource's,
-- and hands its disposal to the retirement instead of disposing the device itself.
dependent ∷ LFix → Text → Retirements → Assembly Text
dependent fixture name retirements = do
  _ ←
    acquirePart
      (name <> ".device")
      (releaseRank 1)
      (note fixture ("acquire " <> name <> ".device"))
      ( \_ → afterRetirement retirements $ do
          note fixture ("dispose " <> name <> ".device")
          breaking ← readIORef (lfBreaking fixture)
          if Set.member (name <> ".device") breaking then throwIO (Broken ("dispose " <> name)) else pure ()
      )
  _ ← asynchronous fixture name retirements
  pure name

-- A resource released at once, over a device whose disposal is handed over all the same:
-- nothing is pending, so it is disposed of inside the release.
dependentNow ∷ LFix → Text → Retirements → Assembly Text
dependentNow fixture name retirements = do
  _ ←
    acquirePart
      (name <> ".device")
      (releaseRank 1)
      (note fixture ("acquire " <> name <> ".device"))
      (\_ → afterRetirement retirements (note fixture ("dispose " <> name <> ".device")))
  _ ←
    acquirePart
      name
      (releaseRank 0)
      (note fixture ("acquire " <> name))
      (\_ → note fixture ("release " <> name))
  pure name

-- | The same, with every failure of an instance escalated to the owner.
escalating ∷ InstanceConfig
escalating = leaseConfig {instanceEscalate = \_ → pure Escalate}

-- | The bindings: @lease.open@ and its variants acquire, @lease.use@ borrows, and
-- @lease.release@ is the explicit release. All of them are the binding author's view of
-- the API, and none of them does any cleanup of its own.
leaseNamespace ∷ LFix → Namespace
leaseNamespace fixture =
  namespace
    "lease"
    [ opening "open" (\name _ → twoParts fixture name)
    , opening "open_failing" (\name _ → failingStages fixture name)
    , opening "open_async" (\name retirements → asynchronous fixture name retirements)
    , opening "open_dependent" (dependent fixture)
    , opening "open_dependent_now" (dependentNow fixture)
    , opening "open_dependent_failing" $ \name retirements → do
        _ ← dependent fixture name retirements
        restoredStep (throwIO (Broken "constructor"))
        pure name
    , -- An asynchronously retired first stage, then a stage that fails: the rollback hands
      -- the first over to its provider.
      opening "open_async_failing" $ \name retirements → do
        _ ← asynchronous fixture name retirements
        restoredStep (throwIO (Broken "constructor"))
        pure name
    , stateOperation "open_shared" [SText] [SCapability "res"] $ \arguments → case arguments of
        [VText name] → do
          lease ← acquireShared (lfLeases fixture) ("interest in " <> name) (take' name) (drop' name)
          pure [leaseHandle "res" lease]
        _ → pure []
    , -- Acquires, and then answers more than the binding declares, so the result is
      -- refused after the action has run.
      stateOperation "open_unpublishable" [SText] [SCapability "res"] $ \arguments → case arguments of
        [VText name] → do
          lease ← acquireOwned (lfLeases fixture) (\_ → twoParts fixture name)
          pure [leaseHandle "res" lease, VNil]
        _ → pure []
    , -- Acquires from a thread the callback started, which is not the callback.
      stateOperation "open_elsewhere" [SText] [SText] $ \arguments → case arguments of
        [VText name] → do
          done ← newEmptyMVar
          _ ← forkIO $ do
            outcome ← try @SomeException (acquireOwned (lfLeases fixture) (\_ → twoParts fixture name))
            putMVar done outcome
          outcome ← takeMVar done
          pure [VText (either (const "refused") (const "acquired") outcome)]
        _ → pure []
    , stateOperation "use" [SCapability "res"] [SText] $ \arguments → case arguments of
        [VCapability handle] → do
          name ← withLease (lfLeases fixture) (capabilityKey handle) pure
          note fixture ("use " <> name)
          pure [VText name]
        _ → pure []
    , releaseOperation "release" "res" [SText] $ \arguments → case arguments of
        [VCapability handle] → do
          answer ← releaseLease (lfLeases fixture) (capabilityKey handle)
          note fixture ("released " <> Text.pack (show answer))
          pure [VText (Text.pack (show answer))]
        _ → pure []
    ]
  where
    opening name assembly =
      stateOperation name [SText] [SCapability "res"] $ \arguments → case arguments of
        [VText resource] → do
          lease ← acquireOwned (lfLeases fixture) (assembly resource)
          pure [leaseHandle "res" lease]
        _ → pure []
    take' name = do
      atomicModifyIORef' (lfAssets fixture) (\held → (Map.insertWith (+) name 1 held, ()))
      note fixture ("take " <> name)
      pure ("asset " <> name)
    drop' name _ = do
      atomicModifyIORef' (lfAssets fixture) (\held → (Map.adjust (subtract 1) name held, ()))
      note fixture ("drop " <> name)

-- Statuses ------------------------------------------------------------------------------

-- | Whether an owner's worker is still live.
isLive ∷ WorkerStatus → Bool
isLive = \case
  WorkerLive → True
  _ → False

-- | Whether an owner's worker stopped in order.
isStopped ∷ WorkerStatus → Bool
isStopped = \case
  WorkerStopped → True
  _ → False

-- Configurations ------------------------------------------------------------------------

-- | Eight live instances, sixteen results, a queue of eight and eight controls, and the
-- @tick@ source.
leaseConfig ∷ InstanceConfig
leaseConfig = defaultInstanceConfig {instanceBounds = InstanceBounds 8 16 8 8, instanceSources = [EventSource "tick" (SRecord [("n", SInteger)])]}

-- | An owner of this label hosting instances from these modules, lending its
-- collection and holding leases through the fixture's handles.
leaseSpec ∷ LFix → Text → [ModuleSource] → InstanceConfig → WorkerPolicy → ScheduledSpec
leaseSpec fixture label modules config worker =
  base
    { scheduledVm = vm {vmRegistration = extended, vmPolicy = vmPolicy vm <> ["lease"]}
    , scheduledLending = Just (lfLending fixture)
    , scheduledLeases = Just (lfLeases fixture)
    }
  where
    base = instanceSpec (lfBase fixture) label modules config worker defaultSchedulerBounds
    vm = scheduledVm base
    reg = vmRegistration vm
    extended =
      either (error . ("registration refused: " <>) . show) id $
        registration
          (registrationCapabilityTypes reg <> [leaseCapabilityType (lfLeases fixture) "res"])
          (registrationNamespaces reg <> [leaseNamespace fixture])

-- | Start such an owner.
startLeased ∷ LFix → LuaRuntime → Text → [ModuleSource] → InstanceConfig → WorkerPolicy → IO ScheduledOwner
startLeased fixture runtime label modules config worker =
  startWith (lfBase fixture) runtime (leaseSpec fixture label modules config worker)

-- | One instance's leases, in one transaction.
summaryOf ∷ LFix → Text → IO ScopeSummary
summaryOf fixture name = do
  identity ← idOf (lfBase fixture) name
  atomically (instanceLeases (lfLeases fixture) identity)

-- | Block, in STM, until an instance's leases satisfy this.
awaitSummary ∷ LFix → Text → (ScopeSummary → Bool) → IO ()
awaitSummary fixture name wanted = do
  identity ← idOf (lfBase fixture) name
  atomically $ do
    summary ← instanceLeases (lfLeases fixture) identity
    if wanted summary then pure () else retry

-- | Block until the instance has this many charged.
awaitChargedBy ∷ LFix → Text → Int → IO ()
awaitChargedBy fixture name n = awaitSummary fixture name ((== n) . summaryCharged)

-- | Block until the instance holds this many live resources.
liveFor ∷ LFix → Text → Int → IO ()
liveFor fixture name n = awaitSummary fixture name ((== n) . summaryLive)

-- The modules ---------------------------------------------------------------------------

-- | Acquires in @init@, in a callback and in @shutdown@, and uses the first in
-- @shutdown@, where it must still be live.
holdsAtEveryHook ∷ ModuleSource
holdsAtEveryHook =
  hooksModule
    "holdsateveryhook"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  self.a = lease.open('init-res')"
    , "  api.connect('tick', function(self, event) self.b = lease.open('callback-res') end)"
    , "end"
    , "function shutdown(self, reason)"
    , "  " <> record <> "('shutdown ' .. self.id .. ' ' .. reason)"
    , "  " <> record <> "('shutdown uses ' .. lease.use(self.a))"
    , "  self.c = lease.open('shutdown-res')"
    , "end"
    ]

-- | Acquires and then raises before storing the handle.
acquiresThenRaises ∷ ModuleSource
acquiresThenRaises =
  hooksModule
    "acquiresthenraises"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event)"
    , "    local h = lease.open('raised-res')"
    , "    error('boom before storing')"
    , "  end)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id .. ' ' .. reason) end"
    ]

-- | Overwrites its handles, the last with nil.
overwrites ∷ ModuleSource
overwrites =
  hooksModule
    "overwrites"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  self.h = lease.open('first')"
    , "  self.h = lease.open('second')"
    , "  self.h = lease.open('third')"
    , "  self.h = nil"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id .. ' ' .. reason) end"
    ]

-- | Never stores what it acquires.
losesTheHandle ∷ ModuleSource
losesTheHandle =
  hooksModule
    "losesthehandle"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  lease.open('lost-one')"
    , "  lease.open('lost-two')"
    , "end"
    ]

-- | Releases early, twice, and then a third time, recording what each answered. Its
-- retired handle is released after it has ended, which only the release operation
-- accepts.
releasesEarly ∷ ModuleSource
releasesEarly =
  hooksModule
    "releasesearly"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  self.keep = lease.open('kept')"
    , "  local h = lease.open('early')"
    , "  " <> record <> "('first ' .. lease.release(h))"
    , "  " <> record <> "('second ' .. lease.release(h))"
    , "  " <> record <> "('third ' .. lease.release(h))"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id) end"
    ]

-- | Releases a handle and then uses it, which every operation but the release refuses.
usesRetired ∷ ModuleSource
usesRetired =
  hooksModule
    "usesretired"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event)"
    , "    local h = lease.open('retired-res')"
    , "    lease.release(h)"
    , "    lease.use(h)"
    , "    " <> record <> "('unreachable')"
    , "  end)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id) end"
    ]

-- | A constructor that fails at its second stage.
failingConstructor ∷ ModuleSource
failingConstructor =
  hooksModule
    "failingconstructor"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event) lease.open_failing('doomed') end)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id) end"
    ]

-- | Acquires, and the result cannot be published.
unpublishable ∷ ModuleSource
unpublishable =
  hooksModule
    "unpublishable"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event) lease.open_unpublishable('unseen') end)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id) end"
    ]

-- | Takes an interest in the shared asset @shared-asset@ and keeps it; answers it on
-- a tick.
sharedAsset ∷ ModuleSource
sharedAsset =
  hooksModule
    "sharedasset"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  self.asset = lease.open_shared('shared-asset')"
    , "  api.connect('tick', function(self, event)"
    , "    " <> record <> "('uses ' .. self.id .. ' ' .. lease.use(self.asset))"
    , "  end)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id .. ' ' .. reason) end"
    ]

-- | Keeps its handle in a global the module's instances share.
cachesHandle ∷ ModuleSource
cachesHandle =
  hooksModule
    "cacheshandle"
    [ "cached = nil"
    , "function init(self, api)"
    , "  self.id = inst.next()"
    , "  if cached == nil then"
    , "    cached = lease.open('cached-res')"
    , "    " <> record <> "('cached by ' .. self.id)"
    , "  else"
    , "    self.mine = lease.open_shared('cache-asset')"
    , "    api.connect('tick', function(self, event)"
    , "      " <> record <> "('mine ' .. lease.use(self.mine))"
    , "      local ok = pcall(lease.use, cached)"
    , "      " <> record <> "('cached usable ' .. tostring(ok))"
    , "      lease.use(cached)"
    , "    end)"
    , "  end"
    , "end"
    ]

-- | Holds an asynchronously retired resource, and releases it on a tick.
asyncHolder ∷ ModuleSource
asyncHolder =
  hooksModule
    "asyncholder"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  self.h = lease.open_async('async-res')"
    , "  api.connect('tick', function(self, event)"
    , "    " <> record <> "('release ' .. lease.release(self.h))"
    , "    " <> record <> "('again ' .. lease.release(self.h))"
    , "  end)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id .. ' ' .. reason) end"
    ]

-- | Holds an asynchronously retired resource over a device, and releases it on a tick.
dependentHolder ∷ ModuleSource
dependentHolder =
  hooksModule
    "dependentholder"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  self.h = lease.open_dependent('dep-res')"
    , "  api.connect('tick', function(self, event)"
    , "    " <> record <> "('release ' .. lease.release(self.h))"
    , "  end)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id .. ' ' .. reason) end"
    ]

-- | Releases an asynchronously retired resource over a device early, and then holds a
-- callback suspended whose closing handler releases it again.
closingDependent ∷ ModuleSource
closingDependent =
  hooksModule
    "closingdependent"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  self.h = lease.open_dependent('dep-res')"
    , "  api.connect('tick', function(self, event)"
    , "    " <> record <> "('release ' .. lease.release(self.h))"
    , "    local guard <close> = setmetatable({}, {__close = function()"
    , "      local ok = pcall(lease.release, self.h)"
    , "      " <> record <> "('closing release ' .. tostring(ok))"
    , "    end})"
    , "    sched.wait_ticks(1)"
    , "  end)"
    , "end"
    ]

-- | Holds a resource released at once over a device whose disposal it hands over, and
-- releases it on a tick.
dependentNowHolder ∷ ModuleSource
dependentNowHolder =
  hooksModule
    "dependentnowholder"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  self.h = lease.open_dependent_now('now-res')"
    , "  api.connect('tick', function(self, event)"
    , "    " <> record <> "('release ' .. lease.release(self.h))"
    , "  end)"
    , "end"
    ]

-- | Holds an asynchronously retired resource and a @shutdown@ that fails the way the host
-- fails.
asyncShutdownFails ∷ ModuleSource
asyncShutdownFails =
  hooksModule
    "asyncshutdownfails"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  self.h = lease.open_async('async-hook')"
    , "  api.connect('tick', function(self, event) end)"
    , "end"
    , "function shutdown(self, reason) fx.fail('boom') end"
    ]

-- | Records that a tick reached it.
marker ∷ ModuleSource
marker =
  hooksModule
    "marker"
    [ "function init(self, api)"
    , "  api.connect('tick', function(self, event) " <> record <> "('ran marker') end)"
    , "end"
    ]

-- | Holds an asynchronously retired resource named for the instance, and releases it on a
-- tick.
asyncNamed ∷ ModuleSource
asyncNamed =
  hooksModule
    "asyncnamed"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  self.h = lease.open_async('named-' .. self.id)"
    , "  api.connect('tick', function(self, event)"
    , "    " <> record <> "('release ' .. lease.release(self.h))"
    , "  end)"
    , "end"
    ]

-- | A constructor that rolls back an asynchronously retired stage with a device.
dependentRollback ∷ ModuleSource
dependentRollback =
  hooksModule
    "dependentrollback"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event)"
    , "    local ok = pcall(lease.open_dependent_failing, 'dep-rolled')"
    , "  end)"
    , "end"
    ]

-- | A constructor that rolls back an asynchronously retired stage.
asyncRollback ∷ ModuleSource
asyncRollback =
  hooksModule
    "asyncrollback"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event)"
    , "    local ok = pcall(lease.open_async_failing, 'rolled-back')"
    , "  end)"
    , "end"
    ]

-- | Acquires and releases an asynchronously retired resource on each tick, and records
-- whether the next acquisition was refused.
cycler ∷ ModuleSource
cycler =
  hooksModule
    "cycler"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  self.n = 0"
    , "  api.connect('tick', function(self, event)"
    , "    self.n = self.n + 1"
    , "    local name = 'cycle-' .. self.n"
    , "    local ok, h = pcall(lease.open_async, name)"
    , "    " <> record <> "('open ' .. name .. ' ' .. tostring(ok))"
    , "    if ok then " <> record <> "('release ' .. lease.release(h)) end"
    , "  end)"
    , "end"
    ]

-- | Acquires up to the capacity and one more, catching the refusal.
overCapacity ∷ ModuleSource
overCapacity =
  hooksModule
    "overcapacity"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event)"
    , "    lease.open('one')"
    , "    lease.open('two')"
    , "    local ok, why = pcall(lease.open, 'three')"
    , "    " <> record <> "('third ' .. tostring(ok))"
    , "    " <> record <> "('caught ' .. tostring(why ~= nil))"
    , "    " <> record <> "('continued')"
    , "  end)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id) end"
    ]

-- | Holds a resource whose release fails, releases it early twice and records.
breaker ∷ ModuleSource
breaker =
  hooksModule
    "breaker"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  self.h = lease.open('brittle')"
    , "  api.connect('tick', function(self, event)"
    , "    local ok = pcall(lease.release, self.h)"
    , "    " <> record <> "('first ' .. tostring(ok))"
    , "    local again = pcall(lease.release, self.h)"
    , "    " <> record <> "('second ' .. tostring(again))"
    , "  end)"
    , "end"
    ]

-- | Holds three resources, of which the middle one's release fails.
independent ∷ ModuleSource
independent =
  hooksModule
    "independent"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  self.a = lease.open('indep-a')"
    , "  self.b = lease.open('indep-b')"
    , "  self.c = lease.open('indep-c')"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id .. ' ' .. reason) end"
    ]

-- | Acquires from a thread its callback started.
threadedAcquire ∷ ModuleSource
threadedAcquire =
  hooksModule
    "threadedacquire"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event)"
    , "    " <> record <> "('thread ' .. lease.open_elsewhere('from-thread'))"
    , "  end)"
    , "end"
    ]

-- | Holds a to-be-closed variable whose handler releases a handle, while it waits.
closingReleaser ∷ ModuleSource
closingReleaser =
  hooksModule
    "closingreleaser"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  self.h = lease.open('closing-res')"
    , "  api.connect('tick', function(self, event)"
    , "    local guard <close> = setmetatable({}, {__close = function()"
    , "      " <> record <> "('closing releases ' .. lease.release(self.h))"
    , "    end})"
    , "    sched.wait_ticks(1)"
    , "  end)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id .. ' ' .. reason) end"
    ]

-- | Holds a resource, and a callback whose closing handler raises while it waits.
closingHolder ∷ ModuleSource
closingHolder =
  hooksModule
    "closingholder"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  self.h = lease.open('closing-held')"
    , "  api.connect('tick', function(self, event)"
    , "    local guard <close> = setmetatable({}, {__close = function() error('close boom') end})"
    , "    sched.wait_ticks(1)"
    , "  end)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id .. ' ' .. reason) end"
    ]

-- | Acquires, and then its @init@ fails.
failInit ∷ ModuleSource
failInit =
  hooksModule
    "failinit"
    [ "function init(self, api)"
    , "  lease.open('init-fail-res')"
    , "  error('init boom')"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown') end"
    ]

-- | Holds a resource and defines no @shutdown@.
noShutdown ∷ ModuleSource
noShutdown =
  hooksModule
    "noshutdown"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  self.h = lease.open('no-shutdown-res')"
    , "  api.connect('tick', function(self, event) end)"
    , "end"
    ]

-- | Holds a resource and a @shutdown@ that raises.
badShutdownHolder ∷ ModuleSource
badShutdownHolder =
  hooksModule
    "badshutdownholder"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  self.h = lease.open('bad-shutdown-res')"
    , "  api.connect('tick', function(self, event) end)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id) error('shutdown boom') end"
    ]

-- | A one-shot that holds a resource through its run.
oneShotHolder ∷ ModuleSource
oneShotHolder =
  hooksModule
    "oneshotholder"
    [ "function init(self, api) self.id = inst.next() end"
    , "function run(self, api)"
    , "  self.h = lease.open('one-shot-res')"
    , "  sched.wait_ticks(1)"
    , "  " <> record <> "('run end ' .. self.id)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id .. ' ' .. reason) end"
    ]

-- | A callback that holds a resource and raises.
faultingHolder ∷ ModuleSource
faultingHolder =
  hooksModule
    "faultingholder"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event)"
    , "    self.h = lease.open('fault-res')"
    , "    error('callback boom')"
    , "  end)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id .. ' ' .. reason) end"
    ]

-- | A module that only holds one resource, for the examples that need an instance and
-- nothing more.
plain ∷ ModuleSource
plain =
  hooksModule
    "plain"
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  self.h = lease.open('plain-res')"
    , "  api.connect('tick', function(self, event) end)"
    , "end"
    , "function shutdown(self, reason) " <> record <> "('shutdown ' .. self.id .. ' ' .. reason) end"
    ]
