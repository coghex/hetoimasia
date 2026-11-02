-- | Owners sharing one registration but nothing else.
--
-- A registration is shared data. Each owner built over it has a VM, a set of
-- granted namespaces, a set of module identities and a set of handles of its
-- own, and closing, failing or cancelling one leaves every other one with its
-- state and its evidence untouched.
module Test.Lua.Boundary.Independence (spec) where

import Control.Concurrent (ThreadId, killThread, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Exception (SomeException, fromException, try)
import Control.Monad (replicateM_)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Value
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)
import Test.Lua.Boundary.Support
import Control.Concurrent.MVar (tryPutMVar)
import Control.Monad (void)
import Test.Lua.Support (withProducers)
import Test.Support.Owned (withOwnedThreadOpening)

-- | Run an owner's lifetime on a thread of its own for the length of the continuation (#598), which is given the box the
-- thread publishes how it ended in. The thread is owned: however the continuation ends it has ended and been joined before
-- this returns, after the first argument, which lets go whatever only the example opens, has run.
withOnThread ∷ IO () → VmConfig → (OwnedVm → IO a) → (ThreadId → MVar (Either SomeException a) → IO b) → IO b
withOnThread open config body continue = do
  result ← newEmptyMVar
  withOwnedThreadOpening open (try (withVmOwner config body) >>= putMVar result) (\thread _ → continue thread result)

shown ∷ Either SomeException a → Either String a
shown = either (Left . show) Right

counter ∷ ModuleSource
counter =
  ModuleSource
    (ModuleRef "counter" "1")
    "local n = 0\nfunction bump() n = n + 1; return n end"
    [EntryPoint "bump" Required [] [SInteger]]

spec ∷ Spec
spec = describe "independent owners over one registration" $ do
  it "runs two owners with different policies at once, each seeing only what it was granted" $ do
    fixture ← newFixture
    let registered = sampleRegistration fixture
        owner granted = (vmConfig libraries) {vmRegistration = registered, vmPolicy = granted, vmOwnerName = Text.unwords granted}
    firstIn ← newEmptyMVar
    secondIn ← newEmptyMVar
    go ← newEmptyMVar
    let letGo = void (tryPutMVar go ())
    withOnThread letGo (owner ["sample"]) (\owned → do
        putMVar firstIn ()
        readMVar go
        run owned "assert(other == nil); for i = 1, 500 do assert(sample.add(i, 1) == i + 1) end"
      ) $ \_ first →
      withOnThread letGo (owner ["other"]) (\owned → do
          putMVar secondIn ()
          readMVar go
          run owned "assert(sample == nil); for i = 1, 500 do assert(other.ping() == 'pong') end"
        ) $ \_ second → do
        -- Both lifetimes are open before either runs a line.
        takeMVar firstIn
        takeMVar secondIn
        putMVar go ()
        takeMVar first >>= either (expectationFailure . show) pure
        takeMVar second >>= either (expectationFailure . show) pure

  it "gives each owner module identities and handles of its own" $ do
    fixture ← newFixture
    let registered = sampleRegistration fixture
        config = (vmConfig libraries) {vmRegistration = registered, vmPolicy = ["sample"]}
    outcomes ←
      withProducers
        ( replicate 4 . try @SomeException $
            withVmOwner config $ \owned → do
              handle ← loadModule owned counter
              replicateM_ 50 yield
              _ ← callEntry owned handle "bump" []
              callEntry owned handle "bump" []
        )
        (mapM takeMVar)
    -- Every owner loaded the same identity and counted from its own zero.
    map shown outcomes `shouldBe` replicate 4 (Right (Returned [VInteger 2]))

  it "leaves one owner running when another fails, closes or is cancelled" $ do
    fixture ← newFixture
    let registered = sampleRegistration fixture
        config = (vmConfig libraries) {vmRegistration = registered, vmPolicy = ["sample"]}
    survivorStarted ← newEmptyMVar
    survivorGo ← newEmptyMVar
    withOnThread (void (tryPutMVar survivorGo ())) config
      ( \owned → do
          handle ← loadModule owned counter
          _ ← callEntry owned handle "bump" []
          putMVar survivorStarted ()
          readMVar survivorGo
          run owned "sample.set_value('survivor', 1)"
          callEntry owned handle "bump" []
      )
      $ \_ survivor → do
        takeMVar survivorStarted
        -- One owner fails with a boundary fault.
        failed ← try @SomeException (withVmOwner config (\owned → run owned "sample.add(1.5, 2)"))
        case failed of
          Left failure | Just (_ ∷ BoundaryFault) ← fromException failure → pure ()
          other → expectationFailure ("not a boundary fault: " <> show other)
        -- One owner is cancelled while it waits between operations.
        waiting ← newEmptyMVar
        withOnThread (pure ()) config (\_ → putMVar waiting () >> newEmptyMVar @() >>= takeMVar) $ \cancelled outcome → do
          takeMVar waiting
          killThread cancelled
          takeMVar outcome >>= \case
            Left _ → pure ()
            Right () → expectationFailure "the cancelled owner returned"
        -- One owner closes normally.
        withVmOwner config (\owned → run owned "sample.set_value('closed', 1)")
        putMVar survivorGo ()
        (shown <$> takeMVar survivor) >>= (`shouldBe` Right (Returned [VInteger 2]))
        Map.keys <$> stateOf fixture >>= (`shouldBe` ["closed", "survivor"])
