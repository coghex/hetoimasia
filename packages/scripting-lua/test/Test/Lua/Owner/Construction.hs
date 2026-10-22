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
import Hetoimasia.Scripting.Lua.Internal.Library (LibraryProfile (LibraryProfileM1))
import Hetoimasia.Scripting.Lua.Internal.Owner
  ( OwnerConfig (ownerAfterAllocation, ownerAfterLibraries, ownerBudget, ownerChunks, ownerProfile)
  , defaultOwnerConfig
  )
import Hetoimasia.Scripting.Lua.Internal.Vm (Phase (Closed), vmPhase)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Lua.Owner.Support
import Test.Lua.Support (newRecorder, recorded, recordingCallback)

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
    stages ← map snd <$> sweepBudgets (defaultOwnerConfig [LibraryBase, LibraryString, LibraryTable, LibraryMath]) [0, 400 .. 150000]
    let seen = nub stages
    -- Memory ran out at the state's allocation, while a library was opening, and
    -- while a chunk loaded or ran, and also never ran out at all.
    seen `shouldSatisfy` elem "new-state"
    seen `shouldSatisfy` any (`elem` ["library", "grow"])
    seen `shouldSatisfy` elem "grow"
    seen `shouldSatisfy` elem "completed"
    seen `shouldSatisfy` elem "library"
    forM_ seen $ \stage → stage `shouldSatisfy` (`elem` allowedStages)

  it "survives memory running out at every step of a profiled owner's construction, running no authored code" $ do
    let profiled = (defaultOwnerConfig []) {ownerProfile = Just LibraryProfileM1}
    wide ← sweepBudgets profiled [0, 400 .. 150000]
    -- The boundary between the libraries and the first authored step is where the
    -- profile installs, so walk it one byte at a time: every allocation there is
    -- the one that fails in some run. The filtering itself finds every name it
    -- removes already interned and only overwrites existing fields, so it may
    -- allocate nothing and the "profile" stage may never be the one that runs
    -- out; the stage is still allowed, because its call is protected and would be
    -- classified like any other.
    let beforeAuthored = [limit | (limit, stage) ← wide, stage `elem` ["new-state", "library", "profile"]]
        boundary = maximum (0 : beforeAuthored)
    fine ← sweepBudgets profiled [max 0 (boundary - 100) .. boundary + 500]
    let seen = nub (map snd (wide <> fine))
    seen `shouldSatisfy` elem "new-state"
    seen `shouldSatisfy` elem "library"
    seen `shouldSatisfy` elem "grow"
    seen `shouldSatisfy` elem "completed"
    forM_ seen $ \stage → stage `shouldSatisfy` (`elem` allowedStages)

-- | The steps a construction can run out of memory in.
allowedStages ∷ [Text]
allowedStages = ["new-state", "library", "profile", "dependency", "grow", "completed"]

-- | Construct an owner once at each of these byte budgets, each with a dependency
-- installed after the libraries and an initial chunk that grows, and answer each
-- budget with the step it ended in.
--
-- At every budget: the VM that was made is closed; the body ran only if
-- construction completed; a failure is Lua's report of memory running out; a
-- dependency installed before the failure is released exactly once and one that
-- was never installed is not released at all; and the initial chunk ran only when
-- every step before it had succeeded, so no authored code runs under a partly
-- built surface.
sweepBudgets ∷ OwnerConfig → [Int] → IO [(Int, Text)]
sweepBudgets base limits =
  forM limits $ \limit → do
    releases ← newIORef (0 ∷ Int)
    vmRef ← newCaptured
    bodyRan ← newIORef False
    authored ← newRecorder
    let config =
          base
            { ownerBudget = Just limit
            , ownerAfterAllocation = capture vmRef
            , ownerAfterLibraries = \vm → do
                installCallback vm "dependency" (pure NoResult) (modifyIORef' releases (+ 1))
                recordingCallback vm authored "authored"
            , ownerChunks = [(chunkName "grow", "authored() t = {} for i = 1, 300 do t[i] = tostring(i) .. 'x' end")]
            }
    outcome ← runOwner config (\_ → writeIORef bodyRan True)
    held ← readIORef releases
    ran ← readIORef bodyRan
    chunkRuns ← recorded authored
    captured vmRef >>= \case
      Nothing → pure ()
      Just vm → vmPhase vm >>= (`shouldBe` Closed)
    case outcome of
      Right () → do
        ran `shouldBe` True
        held `shouldBe` 1
        chunkRuns `shouldBe` ["authored"]
        pure (limit, "completed")
      Left failure → do
        ran `shouldBe` False
        case causeOf failure of
          Just fault → do
            faultKind fault `shouldBe` MemoryExhausted
            -- A dependency installed before the failure is released once;
            -- one that was never installed is not released at all.
            let stage = stageOf (faultChunk fault)
            held `shouldBe` (if stage `elem` ["dependency", "grow"] then 1 else 0)
            -- Only the chunk's own failure can follow authored code.
            if stage == "grow" then pure () else chunkRuns `shouldBe` []
            pure (limit, stage)
          Nothing → expectationFailure "memory ran out and the failure was not Lua's report of it" >> pure (limit, "unexpected")

-- | The failure a lifetime ended with, failing the example if it succeeded.
failureOf ∷ Outcome a → IO (ExceptionWithContext SomeException)
failureOf = \case
  Left failure → pure failure
  Right _ → expectationFailure "the construction failure was lost" >> throwIO (BodyBroke "unreachable")

-- | The step a fault names: the interpreter, a library, a profile's filtering, a
-- callback or a chunk.
stageOf ∷ Text → Text
stageOf name
  | name == "new-state" = "new-state"
  | "profile " `Text.isPrefixOf` name = "profile"
  | "Library" `Text.isPrefixOf` name = "library"
  | name `elem` ["dependency", "authored"] = "dependency"
  | otherwise = name

closedVm ∷ Captured Vm → IO ()
closedVm vmRef = captured vmRef >>= \case
  Nothing → expectationFailure "the VM was never constructed"
  Just vm → vmPhase vm >>= (`shouldBe` Closed)
