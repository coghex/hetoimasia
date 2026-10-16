-- | Partial construction: a failure at any construction or initialization step.
--
-- Whatever step fails, the owner releases exactly what was constructed, closes
-- the VM that was made through the same protected close a finished one gets,
-- raises the primary failure with any close failure retained beside it, and
-- never runs the body, so no half-constructed VM is reachable afterwards.
--
-- The steps are the VM's allocation, each library's opening, the callbacks the
-- initialization installs, and each initial chunk. A failure is injected at each
-- by a fixture step, or, for memory exhaustion, by an allocator that refuses to
-- grow past a byte budget: sweeping the budget makes memory run out at every
-- point of the construction in turn, which no single chosen point would show.
module Test.Lua.Owner.Construction (spec) where

import Control.Monad (forM, forM_)
import Control.Exception (ExceptionWithContext, SomeException, throwIO)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Bridge
  ( FaultKind (CallFailed, MemoryExhausted)
  , Library (LibraryBase, LibraryMath, LibraryString, LibraryTable)
  , LuaFault (faultChunk, faultKind)
  , Vm
  , chunkName
  )
import Hetoimasia.Scripting.Lua.Internal.Callback (CallbackResult (NoResult), installCallback)
import Hetoimasia.Scripting.Lua.Internal.Owner
  ( OwnerConfig (ownerAfterAllocation, ownerAfterLibraries, ownerBudget, ownerChunks)
  , defaultOwnerConfig
  )
import Hetoimasia.Scripting.Lua.Internal.Vm (Phase (Closed), vmPhase)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Lua.Owner.Support

spec ∷ Spec
spec = describe "partial construction" $ do
  it "closes the VM and runs no body when the first step after allocation fails" $ do
    vmRef ← newCaptured
    bodyRan ← newIORef False
    let config =
          (defaultOwnerConfig [LibraryBase])
            { ownerAfterAllocation = \vm → capture vmRef vm >> throwIO (BodyBroke "after allocation")
            }
    outcome ← runOwner config (\_ → writeIORef bodyRan True)
    failureOf outcome >>= \failure → do
      causeOf failure `shouldBe` Just (BodyBroke "after allocation")
      evidenceLabels failure `shouldBe` []
    readIORef bodyRan >>= (`shouldBe` False)
    closedVm vmRef

  it "releases a dependency the initialization installed, once, when a later step fails" $ do
    finalizing ← newFinalizing
    vmRef ← newCaptured
    bodyRan ← newIORef False
    let base = finalizingConfig finalizing
        config =
          base
            { ownerAfterAllocation = capture vmRef
            , ownerAfterLibraries = \vm → ownerAfterLibraries base vm >> throwIO (BodyBroke "after libraries")
            , ownerChunks = []
            }
    outcome ← runOwner config (\_ → writeIORef bodyRan True)
    failureOf outcome >>= \failure → do
      causeOf failure `shouldBe` Just (BodyBroke "after libraries")
      evidenceLabels failure `shouldBe` []
    readIORef bodyRan >>= (`shouldBe` False)
    closedVm vmRef
    -- Installed, never called by a finalizer, and released exactly once.
    events (finalizingEvents finalizing) >>= (`shouldBe` ["release"])

  it "closes through the same close when an initial chunk fails, running the finalizers a loaded chunk set" $ do
    finalizing ← newFinalizing
    vmRef ← newCaptured
    bodyRan ← newIORef False
    let base = finalizingConfig finalizing
        config =
          base
            { ownerAfterAllocation = capture vmRef
            , ownerChunks = ownerChunks base <> [(chunkName "second chunk", "error('the initial chunk failed')")]
            }
    outcome ← runOwner config (\_ → writeIORef bodyRan True)
    failureOf outcome >>= \failure → do
      fmap faultKind (causeOf failure) `shouldBe` Just CallFailed
      fmap faultChunk (causeOf failure) `shouldBe` Just "second chunk"
    readIORef bodyRan >>= (`shouldBe` False)
    closedVm vmRef
    -- The first chunk's guard was finalized by the close, with the dependency
    -- still held, and released after.
    events (finalizingEvents finalizing) >>= (`shouldBe` ["finalizer: dependency live", "release"])

  it "reports the construction failure primary with a failed close retained beside it" $ do
    finalizing ← newFinalizing
    let base = failingCloseConfig finalizing
        config = base {ownerChunks = ownerChunks base <> [(chunkName "failing chunk", "error('initial')")]}
    outcome ← runOwner config (\_ → pure ())
    failureOf outcome >>= \failure → do
      fmap faultKind (causeOf failure) `shouldBe` Just CallFailed
      evidenceLabels failure `shouldBe` ["lua finalizer", "lua release"]
      evidenceCauses failure `shouldBe` [Just (CloseBroke "finalizer"), Just (CloseBroke "release")]

  it "survives memory running out at every step of construction, closing what it built" $ do
    stages ←
      forM [0, 400 .. 150000] $ \limit → do
        releases ← newIORef (0 ∷ Int)
        vmRef ← newCaptured
        bodyRan ← newIORef False
        let config =
              (defaultOwnerConfig [LibraryBase, LibraryString, LibraryTable, LibraryMath])
                { ownerBudget = Just limit
                , ownerAfterAllocation = capture vmRef
                , ownerAfterLibraries = \vm →
                    installCallback vm "dependency" (pure NoResult) (modifyIORef' releases (+ 1))
                , ownerChunks = [(chunkName "grow", "t = {} for i = 1, 300 do t[i] = tostring(i) .. 'x' end")]
                }
        outcome ← runOwner config (\_ → writeIORef bodyRan True)
        held ← readIORef releases
        ran ← readIORef bodyRan
        captured vmRef >>= \case
          Nothing → pure ()
          Just vm → vmPhase vm >>= (`shouldBe` Closed)
        case outcome of
          Right () → do
            ran `shouldBe` True
            held `shouldBe` 1
            pure ("completed" ∷ Text)
          Left failure → do
            ran `shouldBe` False
            case causeOf failure of
              Just fault → do
                faultKind fault `shouldBe` MemoryExhausted
                -- A dependency installed before the failure is released once;
                -- one that was never installed is not released at all.
                let stage = stageOf (faultChunk fault)
                held `shouldBe` (if stage `elem` ["dependency", "grow"] then 1 else 0)
                pure stage
              Nothing → expectationFailure "memory ran out and the failure was not Lua's report of it" >> pure "unexpected"
    let seen = nub stages
    -- Memory ran out at the state's allocation, while a library was opening, and
    -- while a chunk loaded or ran, and also never ran out at all.
    seen `shouldSatisfy` elem "new-state"
    seen `shouldSatisfy` any (`elem` ["library", "grow"])
    seen `shouldSatisfy` elem "grow"
    seen `shouldSatisfy` elem "completed"
    seen `shouldSatisfy` elem "library"
    forM_ seen $ \stage → stage `shouldSatisfy` (`elem` ["new-state", "library", "dependency", "grow", "completed"])

-- | The failure a lifetime ended with, failing the example if it succeeded.
failureOf ∷ Outcome a → IO (ExceptionWithContext SomeException)
failureOf = \case
  Left failure → pure failure
  Right _ → expectationFailure "the construction failure was lost" >> throwIO (BodyBroke "unreachable")

-- | The step a fault names: the interpreter, a library, a callback or a chunk.
stageOf ∷ Text → Text
stageOf name
  | name == "new-state" = "new-state"
  | "Library" `Text.isPrefixOf` name = "library"
  | name == "dependency" = "dependency"
  | otherwise = name

closedVm ∷ Captured Vm → IO ()
closedVm vmRef = captured vmRef >>= \case
  Nothing → expectationFailure "the VM was never constructed"
  Just vm → vmPhase vm >>= (`shouldBe` Closed)
