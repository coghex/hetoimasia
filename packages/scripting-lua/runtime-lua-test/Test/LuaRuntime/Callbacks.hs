-- | No reply waits from callbacks (D-13): a thread running a binding's action or
-- any other Lua callback, of any VM, may submit but may not wait for a reply.
module Test.LuaRuntime.Callbacks (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (void)
import Data.IORef (atomicModifyIORef', readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Runtime
import Hetoimasia.Scripting.Lua.Value
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.LuaRuntime.Support

-- | Remember a call's ticket under a label, for the bindings to find.
keep ∷ Fixture → Text → CallTicket → IO ()
keep fixture label ticket = atomicModifyIORef' (fixtureTickets fixture) (\held → (Map.insert label ticket held, ()))

spec ∷ Spec
spec = describe "waits from callbacks" $ do
  it "refuses, at once and typed, a wait for its own owner's reply and for another owner's, from inside a binding" $ bounded $ do
    fixture ← newFixture
    withBoundary $ \control runtime → do
      writeIORef (fixtureControl fixture) (Just control)
      a ← startOwner runtime (quickSpec fixture "a" ["app"])
      b ← startOwner runtime (quickSpec fixture "b" ["app"])
      forA ← submit (ownerEndpoint a) "echo" [VInteger 1] >>= accepted
      forB ← submit (ownerEndpoint b) "echo" [VInteger 2] >>= accepted
      keep fixture "a" forA
      keep fixture "b" forB
      -- Both are settled by now, so the refusal is the callback's, not a wait's.
      void (settle forA) >> void (settle forB)
      let asked entry label = do
            ticket ← submit (ownerEndpoint a) entry [VText label] >>= accepted
            returnedValues <$> settleOutcome ticket
      asked "wait_for" "a" >>= (`shouldBe` Just [VBoolean True])
      asked "wait_for" "b" >>= (`shouldBe` Just [VBoolean True])
      asked "await_for" "a" >>= (`shouldBe` Just [VBoolean True])
      asked "await_for" "b" >>= (`shouldBe` Just [VBoolean True])
      readIORef (fixtureProbe fixture) >>= (`shouldBe` ["await-call", "await-call", "wait-call", "wait-call"])
      retireOwner a
      retireOwner b

  it "refuses a wait action that was built before the callback and runs inside it" $ bounded $ do
    fixture ← newFixture
    withBoundary $ \_ runtime → do
      owner ← startOwner runtime (quickSpec fixture "prebuilt" ["app"])
      ticket ← submit (ownerEndpoint owner) "echo" [VInteger 1] >>= accepted
      let prebuilt = void (waitCall ticket)
      writeIORef (fixturePrebuilt fixture) prebuilt
      call ← submit (ownerEndpoint owner) "run_prebuilt" [] >>= accepted
      returnedValues <$> settleOutcome call >>= (`shouldBe` Just [VBoolean True])
      readIORef (fixtureProbe fixture) >>= (`shouldBe` ["wait-call"])
      retireOwner owner

  it "accepts a submission made from inside a binding to another owner, which settles" $ bounded $ do
    fixture ← newFixture
    withBoundary $ \_ runtime → do
      a ← startOwner runtime (quickSpec fixture "a" ["app"])
      b ← startOwner runtime (quickSpec fixture "b" ["app"])
      atomicModifyIORef' (fixtureEndpoints fixture) (\held → (Map.insert "b" (ownerEndpoint b) held, ()))
      call ← submit (ownerEndpoint a) "submit_to" [VText "b", VInteger 5] >>= accepted
      -- Answer 0: accepted.
      returnedValues <$> settleOutcome call >>= (`shouldBe` Just [VInteger 0])
      Just forwarded ← Map.lookup "b" <$> readIORef (fixtureTickets fixture)
      returnedValues <$> settleOutcome forwarded >>= (`shouldBe` Just [VInteger 5])
      retireOwner a
      retireOwner b

  it "refuses a wait from a callback of a VM created outside the adapter" $ bounded $ do
    fixture ← newFixture
    withBoundary $ \_ runtime → do
      owner ← startOwner runtime (quickSpec fixture "served" ["app"])
      ticket ← submit (ownerEndpoint owner) "echo" [VInteger 1] >>= accepted
      keep fixture "served" ticket
      let outside =
            (vmConfig libraries)
              { vmRegistration = sampleRegistration fixture
              , vmPolicy = ["app"]
              , vmOwnerName = "foreign"
              }
      withVmOwner outside $ \owned → evalOwned owned (chunkName "foreign") "app.wait('served')"
      readIORef (fixtureProbe fixture) >>= (`shouldBe` ["wait-call"])
      void (settle ticket)
      retireOwner owner

  it "refuses a wait from a capability-liveness callback, of a foreign VM and of an owner of the adapter" $ bounded $ do
    fixture ← newFixture
    withBoundary $ \_ runtime → do
      owner ← startOwner runtime (quickSpec fixture "served" ["app"])
      held ← submit (ownerEndpoint owner) "echo" [VInteger 1] >>= accepted
      -- The application's own check tries to wait for the reply of a call.
      writeIORef (fixtureLiveCheck fixture) (void (attemptWait fixture (void (waitCall held))))
      -- Through an owner of the adapter.
      redeemed ← submit (ownerEndpoint owner) "redeem" [VCapability (capability "ticket" 1)] >>= accepted
      returnedValues <$> settleOutcome redeemed >>= (`shouldBe` Just [VInteger 1])
      readIORef (fixtureProbe fixture) >>= (`shouldBe` ["wait-call"])
      -- And through a VM made outside it, whose module call runs the same check.
      let outside =
            (vmConfig libraries)
              { vmRegistration = sampleRegistration fixture
              , vmPolicy = ["app"]
              , vmOwnerName = "foreign"
              , vmModules = [sampleModule]
              }
      withVmOwner outside $ \owned → do
        Just handle ← loadedModule owned theModule
        callEntry owned handle "redeem" [VCapability (capability "ticket" 2)] >>= (`shouldBe` Returned [VInteger 1])
      readIORef (fixtureProbe fixture) >>= (`shouldBe` ["wait-call", "wait-call"])
      retireOwner owner

  it "refuses creating an owner from inside a callback, which waits for readiness" $ bounded $ do
    fixture ← newFixture
    withBoundary $ \_ runtime → do
      writeIORef (fixtureRuntime fixture) (Just runtime)
      owner ← startOwner runtime (quickSpec fixture "creator" ["app"])
      call ← submit (ownerEndpoint owner) "make_owner" [] >>= accepted
      returnedValues <$> settleOutcome call >>= (`shouldBe` Just [VBoolean True])
      readIORef (fixtureProbe fixture) >>= (`shouldBe` ["start-lua-owner"])
      retireOwner owner

  it "lets an ordinary thread wait, and a callback's submission and poll go through" $ bounded $ do
    fixture ← newFixture
    withBoundary $ \control runtime → do
      owner ← startOwner runtime (quickSpec fixture "ordinary" ["app"])
      ticket ← submit (ownerEndpoint owner) "echo" [VInteger 4] >>= accepted
      done ← newEmptyMVar
      void (awaitCall control ticket >>= putMVar done . returnedValues . settledOutcome)
      takeMVar done >>= (`shouldBe` Just [VInteger 4])
      retireOwner owner
