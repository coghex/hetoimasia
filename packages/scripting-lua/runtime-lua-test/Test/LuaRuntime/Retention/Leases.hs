-- | The same property for lease retirements (#488): two pending retirements whose readings read
-- one application-owned TVar are polled in one transaction, and a commit to that TVar by another
-- thread while the second is polled does not make the engine re-run the second reading against
-- the stale view the first left behind.
--
-- The first execution of the second reading holds a gate inside the engine's own transaction
-- (the owner's wait for retirements, or its servicing of them), the example commits once, and
-- the gate opens. Every execution is counted, including attempts a rolled-back transaction
-- discards. Nothing sleeps.
module Test.LuaRuntime.Retention.Leases
  ( spec
  , World (..)
  , staleSpec
  , pair
  , pairOnTick
  ) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, writeTVar)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Hetoimasia.Foundation.Resource (Assembly, acquirePart, releaseRank)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lease
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Lease.Support
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Retention.Probe
import Test.LuaRuntime.Scheduled.Support (awaitScheduledTerminal)
import Test.LuaRuntime.Support (Gated (..), bounded, requiredPolicy, withBoundaryOpening)

-- | The most times a reading may run from the one conflicting commit until the engine reports
-- the retirement over.
bound ∷ Int
bound = 20

-- | What the example's resources share.
data World = World
  { wShared ∷ !(TVar Int)
    -- ^ The application-owned TVar both readings read.
  , wProviders ∷ !(IORef (Map Text (TVar RetirementState)))
  , wProbes ∷ !(Map Text Probe)
  , wSentinel ∷ !(Maybe (TVar Int))
    -- ^ A TVar every reading writes when it runs: nothing it writes is kept.
  }

-- | The providers prove every retirement they were handed over, as the example does when its
-- checks are over, and as it must however it ends, or the owner waits for them for ever.
completeProviders ∷ IORef (Map Text (TVar RetirementState)) → IO ()
completeProviders providers = do
  held ← readIORef providers
  atomically (mapM_ (`writeTVar` ProviderComplete) (Map.elems held))

-- | A resource whose provider retires it later, whose reading is instrumented and reads the
-- sharedVar TVar.
retiredLater ∷ World → Text → Retirements → Assembly Text
retiredLater world name retirements = do
  _ ←
    acquirePart
      name
      (releaseRank 0)
      ( do
          tv ← newTVarIO ProviderPending
          atomicModifyIORef' (wProviders world) (\held → (Map.insert name tv held, ()))
          pure tv
      )
      ( \tv →
          retireAsynchronously retirements name $ do
            mapM_ (`modifyTVar'` (+ 1)) (wSentinel world)
            case Map.lookup name (wProbes world) of
              Just probe → instrumentAnswering probe (readTVar (wShared world) >> readTVar tv)
              Nothing → readTVar (wShared world) >> readTVar tv
      )
  pure name

-- | An owner of instances that open resources through 'retiredLater'.
staleSpec ∷ LFix → World → Text → [ModuleSource] → ScheduledSpec
staleSpec fixture world label modules =
  base {scheduledVm = vm {vmRegistration = extended, vmPolicy = vmPolicy vm <> ["stale"]}}
  where
    base = leaseSpec fixture label modules leaseConfig requiredPolicy
    vm = scheduledVm base
    reg = vmRegistration vm
    extended =
      either (error . ("registration refused: " <>) . show) id $
        registration
          (registrationCapabilityTypes reg)
          ( registrationNamespaces reg
              <> [ namespace
                     "stale"
                     [ stateOperation "open" [SText] [SCapability "res"] $ \arguments → case arguments of
                         [VText name] → do
                           lease ← acquireOwned (lfLeases fixture) (retiredLater world name)
                           pure [leaseHandle "res" lease]
                         _ → pure []
                     ]
                 ]
          )

-- | Opens two resources in @init@ and holds them.
pair ∷ ModuleSource
pair =
  hooksModule
    "stalepair"
    [ "function init(self, api)"
    , "  self.a = stale.open('a')"
    , "  self.b = stale.open('b')"
    , "end"
    ]

-- | Opens two resources in @init@ and releases both when a tick reaches it, so that their
-- retirements are pending while the owner goes on serving other instances.
pairOnTick ∷ ModuleSource
pairOnTick =
  hooksModule
    "stalepairontick"
    [ "function init(self, api)"
    , "  self.a = stale.open('a')"
    , "  self.b = stale.open('b')"
    , "  api.connect('tick', function(self, event)"
    , "    lease.release(self.a)"
    , "    lease.release(self.b)"
    , "  end)"
    , "end"
    ]

spec ∷ Spec
spec = describe "a retirement reading polled for the leases" $ do
  it "is not re-run against a stale view when the application commits to a TVar two retirements' readings share" $ bounded $ do
    fixture ← newLFix 4
    trace ← newTrace
    sharedVar ← newTVarIO (0 ∷ Int)
    providers ← newIORef Map.empty
    first ← newProbe trace "a"
    second ← newGatedProbe trace "b"
    let world = World sharedVar providers (Map.fromList [("a", first), ("b", second)]) Nothing
        base = lfBase fixture
    withBoundaryOpening [openAllGates second, openAllGates fixture, completeProviders providers] $ \control runtime → do
      owner ← startWith base runtime (staleSpec fixture world "stale lease reading" [pair])
      _ ← admit base owner "p" (moduleNamed "stalepair")
      awaitPhase base owner "p" Active
      liveFor fixture "p" 2
      -- Ending the instance hands both resources to their providers, whose retirements are
      -- polled in one transaction, the first before the second.
      retireScheduled owner
      entered ← awaitEntry second
      take 2 entered `shouldBe` ["b", "a"]
      -- The one conflicting commit: the application writes the shared TVar.
      commitThen second (atomically (modifyTVar' sharedVar (+ 1)))
      completeProviders providers
      _ ← awaitScheduledTerminal control owner
      runsAfterCommit second >>= (`shouldSatisfy` (<= bound))
