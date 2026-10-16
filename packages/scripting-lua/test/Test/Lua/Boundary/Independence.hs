-- | Owners sharing one registration but nothing else.
--
-- A registration is shared data. Each owner built over it has a VM, a set of
-- granted namespaces, a set of module identities and a set of handles of its
-- own, and closing, failing or cancelling one leaves every other one with its
-- state and its evidence untouched.
module Test.Lua.Boundary.Independence (spec) where

import Control.Concurrent (ThreadId, forkIO, killThread, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Exception (SomeException, fromException, try)
import Control.Monad (replicateM_)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Value
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)
import Test.Lua.Boundary.Support

-- | Run an owner's lifetime on a thread of its own, publishing how it ended.
onThread ∷ VmConfig → (OwnedVm → IO a) → IO (ThreadId, MVar (Either SomeException a))
onThread config body = do
  result ← newEmptyMVar
  thread ← forkIO (try (withVmOwner config body) >>= putMVar result)
  pure (thread, result)

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
    (_, first) ←
      onThread (owner ["sample"]) $ \owned → do
        putMVar firstIn ()
        readMVar go
        run owned "assert(other == nil); for i = 1, 500 do assert(sample.add(i, 1) == i + 1) end"
    (_, second) ←
      onThread (owner ["other"]) $ \owned → do
        putMVar secondIn ()
        readMVar go
        run owned "assert(sample == nil); for i = 1, 500 do assert(other.ping() == 'pong') end"
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
    results ← mapM (const newEmptyMVar) [1 .. 4 ∷ Int]
    mapM_
      ( \slot →
          forkIO $
            try @SomeException
              ( withVmOwner config $ \owned → do
                  handle ← loadModule owned counter
                  replicateM_ 50 yield
                  _ ← callEntry owned handle "bump" []
                  callEntry owned handle "bump" []
              )
              >>= putMVar slot
      )
      results
    -- Every owner loaded the same identity and counted from its own zero.
    (map shown <$> mapM takeMVar results) >>= (`shouldBe` replicate 4 (Right (Returned [VInteger 2])))

  it "leaves one owner running when another fails, closes or is cancelled" $ do
    fixture ← newFixture
    let registered = sampleRegistration fixture
        config = (vmConfig libraries) {vmRegistration = registered, vmPolicy = ["sample"]}
    survivorStarted ← newEmptyMVar
    survivorGo ← newEmptyMVar
    (_, survivor) ← onThread config $ \owned → do
      handle ← loadModule owned counter
      _ ← callEntry owned handle "bump" []
      putMVar survivorStarted ()
      readMVar survivorGo
      run owned "sample.set_value('survivor', 1)"
      callEntry owned handle "bump" []
    takeMVar survivorStarted
    -- One owner fails with a boundary fault.
    failed ← try @SomeException (withVmOwner config (\owned → run owned "sample.add(1.5, 2)"))
    case failed of
      Left failure | Just (_ ∷ BoundaryFault) ← fromException failure → pure ()
      other → expectationFailure ("not a boundary fault: " <> show other)
    -- One owner is cancelled while it waits between operations.
    waiting ← newEmptyMVar
    (cancelled, outcome) ← onThread config $ \_ → putMVar waiting () >> newEmptyMVar @() >>= takeMVar
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
