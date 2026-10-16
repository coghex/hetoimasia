-- | Stack, registry and memory discipline across the boundary.
--
-- A completed operation leaves the stack at the depth it entered at, and the
-- registry as it found it, on every path: a call, a refusal of an argument, a
-- refusal of a result, a fault raised by a script, a failed load. A loaded module
-- is the one thing that legitimately holds more of the registry, and it holds
-- exactly one reference for the owner's lifetime; the live count is read beside
-- 'probeReferenceSlot', which only shows that nothing was left behind in the
-- registry's free list.
--
-- Memory is swept: the interpreter's allocator is given a byte budget and the
-- budget is walked across installation, loading, calling and marshalling in both
-- directions, so exhaustion lands at every step in turn. Wherever it lands the
-- outcome is a classified failure -- never a panic, never a Lua error unwinding
-- through a Haskell frame, never a reference left behind. The guarantee is for the
-- recoverable allocator failures Lua reports; an operating-system failure to
-- obtain memory at all is outside it.
module Test.Lua.Boundary.Discipline (spec) where

import Control.Exception (SomeException, fromException, try)
import Control.Monad (forM, forM_, replicateM_)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Encoding (encodeUtf8)
import Hetoimasia.Scripting.Lua.Bridge (FaultKind (MemoryExhausted), LuaFault (faultChunk, faultKind), chunkName)
import Hetoimasia.Scripting.Lua.Internal.Module (liveModuleReferences)
import Hetoimasia.Scripting.Lua.Internal.Owner
  ( OwnedVm
  , OwnerConfig (..)
  , defaultOwnerConfig
  , ownedHost
  , ownedInternalVm
  )
import Hetoimasia.Scripting.Lua.Internal.Vm (Phase (Closed), stackDepth, vmPhase)
import Hetoimasia.Scripting.Lua.Owner
  ( BoundaryFault (boundaryReason)
  , EntryPoint (..)
  , FaultReason (..)
  , ModuleRef (..)
  , ModuleSource (..)
  , Requirement (..)
  , callEntry
  , evalOwned
  , loadModule
  , loadedModule
  )
import Hetoimasia.Scripting.Lua.Value
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Lua.Boundary.Support
import Test.Lua.Owner.Support (capture, captured, causeOf, newCaptured, runOwner)
import Test.Lua.Support (referenceSlot)

-- | A module with an entry point that works, one that raises, and one that
-- answers something its schema refuses.
workbench ∷ ModuleSource
workbench =
  ModuleSource
    (ModuleRef "workbench" "1")
    ( encodeUtf8 . Text.unlines $
        [ "function add(a, b) return a + b end"
        , "function boom() error('boom') end"
        , "function wrong() return 'text' end"
        , "function echo(list) return list end"
        , "function caught() return pcall(sample.add, 1.5, 2) end"
        , "function many(...) return select('#', ...) end"
        ]
    )
    [ EntryPoint "add" Required [SInteger, SInteger] [SInteger]
    , EntryPoint "boom" Required [] []
    , EntryPoint "wrong" Required [] [SInteger]
    , EntryPoint "echo" Required [SList SInteger] [SList SInteger]
    , EntryPoint "caught" Required [] [SBoolean]
    , EntryPoint "many" Required (replicate 16 SInteger) [SInteger]
    ]

-- | What the registry and the stack look like.
data Reading = Reading {readDepth ∷ !Int, readSlot ∷ !Int, readModules ∷ !Int}
  deriving (Eq, Show)

reading ∷ OwnedVm → IO Reading
reading owned = do
  let vm = ownedInternalVm owned
  Reading <$> stackDepth vm <*> (fromIntegral <$> referenceSlot vm) <*> liveModuleReferences (ownedHost owned)

spec ∷ Spec
spec = describe "discipline" $ do
  wideSweep
  it "leaves the stack and the registry as it found them across a thousand calls, refusals and faults" $ do
    fixture ← newFixture
    withOwnerOf ((sampleConfig fixture ["sample"])) $ \owned → do
      handle ← loadModule owned workbench
      before ← reading owned
      before `shouldBe` before {readModules = 1}
      replicateM_ 1000 $ do
        _ ← callEntry owned handle "add" [VInteger 1, VInteger 2]
        _ ← try @BoundaryFault (callEntry owned handle "add" [VFloat 1, VInteger 2])
        _ ← try @BoundaryFault (callEntry owned handle "boom" [])
        _ ← try @BoundaryFault (callEntry owned handle "wrong" [])
        _ ← try @BoundaryFault (callEntry owned handle "caught" [])
        _ ← try @BoundaryFault (callEntry owned handle "echo" [VList [VInteger 1]])
        _ ← try @BoundaryFault (evalOwned owned (chunkName "refused") "sample.add(1.5, 2)")
        _ ← try @BoundaryFault (evalOwned owned (chunkName "short") "sample.short_result()")
        _ ← try @BoundaryFault (evalOwned owned (chunkName "unsupported") "sample.stop()")
        _ ← try @BoundaryFault (evalOwned owned (chunkName "cycle") "local t = {}; t[1] = t; sample.echo_list(t)")
        evalOwned owned (chunkName "ok") "sample.add(1, 2); sample.submit('x'); sample.echo_record({name = 'n', count = 1})"
      reading owned >>= (`shouldBe` before)

  it "holds one reference for each module that loads, and none for a load that fails" $ do
    fixture ← newFixture
    withOwner fixture ["sample"] $ \owned → do
      start ← reading owned
      readModules start `shouldBe` 0
      forM_ [1 .. 40 ∷ Int] $ \index → do
        loaded ← reading owned
        readModules loaded `shouldBe` index - 1
        _ ← loadModule owned (ModuleSource (ModuleRef "m" (Text.pack (show index))) "function f() end" [EntryPoint "f" Required [] []])
        after ← reading owned
        readModules after `shouldBe` index
        -- Failed loads of every kind, between the successful ones, retain nothing.
        _ ← try @BoundaryFault (loadModule owned (ModuleSource (ModuleRef "bad" (Text.pack (show index))) "this is not lua" []))
        _ ← try @BoundaryFault (loadModule owned (ModuleSource (ModuleRef "bad" (Text.pack (show index))) "error('load')" []))
        _ ← try @BoundaryFault (loadModule owned (ModuleSource (ModuleRef "bad" (Text.pack (show index))) "x = 1" [EntryPoint "missing" Required [] []]))
        _ ← try @BoundaryFault (loadModule owned (ModuleSource (ModuleRef "bad" (Text.pack (show index))) "sample.add(1.5, 2)" []))
        _ ← try @BoundaryFault (loadModule owned (ModuleSource (ModuleRef "m" (Text.pack (show index))) "x = 1" []))
        reading owned >>= (`shouldBe` after)
      -- The slot probe never moved, and the stack is where it began.
      end ← reading owned
      (readDepth end, readSlot end) `shouldBe` (readDepth start, readSlot start)
      readModules end `shouldBe` 40

  it "keeps the heap bounded across many crossings whose script phases allocate nothing" $ do
    fixture ← newFixture
    withOwner fixture ["sample"] $ \owned → do
      handle ← loadModule owned (ModuleSource (ModuleRef "echo" "1") "function echo(s) return s end" [EntryPoint "echo" Required [SText] [SText]])
      let kilobytes = do
            run owned "sample.set_value('kb', math.floor(collectgarbage('count')))"
            Map.findWithDefault 0 "kb" <$> stateOf fixture
          kib = VText (Text.replicate 1024 "x")
      -- Warmed, then a collection, so the start is the live size.
      mapM_ (const (callEntry owned handle "echo" [kib])) [1 .. 100 ∷ Int]
      run owned "collectgarbage()"
      start ← kilobytes
      mapM_ (const (callEntry owned handle "echo" [kib])) [1 .. 10000 ∷ Int]
      afterEntries ← kilobytes
      -- Ten thousand one-KiB arguments are ten megabytes of garbage if nothing
      -- ever pays for them; collected as they go, the heap stays near its start.
      (afterEntries - start) `shouldSatisfy` (< 2048)
      -- The same through a binding's results, in one chunk whose own code
      -- allocates nothing but the calls' arguments and results.
      run owned "collectgarbage()"
      middle ← kilobytes
      run owned "local s = ('x'):rep(1024); for i = 1, 10000 do sample.echo_text(s) end"
      afterBindings ← kilobytes
      (afterBindings - middle) `shouldSatisfy` (< 2048)

  it "releases the module's reference when the owner closes, finalizing what it held" $ do
    fixture ← newFixture
    withOwner fixture ["sample"] $ \owned → do
      _ ← loadModule owned (ModuleSource (ModuleRef "m" "1") "held = setmetatable({}, {__gc = function() end})" [])
      pure ()
    -- The owner closed cleanly with a module in its registry.
    logged fixture >>= (`shouldBe` [])

  describe "memory running out" $ do
    let libs = libraries
        config fixture budget slot =
          (defaultOwnerConfig libs)
            { ownerBudget = Just budget
            , ownerAfterAllocation = capture slot
            , ownerRegistration = sampleRegistration fixture
            , ownerGranted = ["sample", "other"]
            , ownerChunks = [(chunkName "init", "grown = {} for i = 1, 60 do grown[i] = tostring(i) .. 'x' end")]
            , ownerModules = [workbench]
            }

    it "is classified wherever it lands in installation, loading, calling and marshalling" $ do
      fixture ← newFixture
      outcomes ←
        forM [0, 100 .. 160000] $ \budget → do
          slot ← newCaptured
          entered ← newIORef False
          seen ← newIORef []
          result ← runOwner (config fixture budget slot) $ \owned → do
            writeIORef entered True
            let try' ∷ ∀ a. Text → IO a → IO ()
                try' label op = do
                  before ← stackDepth (ownedInternalVm owned)
                  outcome ← try @SomeException op
                  after ← stackDepth (ownedInternalVm owned)
                  after `shouldBe` before
                  atomicModifyIORef' seen (\held → (label <> ":" <> classify' outcome : held, ()))
            loaded ← try @SomeException (loadModule owned (workbench {sourceIdentity = ModuleRef "second" "1"}))
            forM_ loaded $ \handle → do
              try' "call" (callEntry owned handle "add" [VInteger 1, VInteger 2])
              try' "echo" (callEntry owned handle "echo" [VList (map VInteger [1 .. 50])])
              try' "many" (callEntry owned handle "many" (replicate 16 (VInteger 1)))
            atomicModifyIORef' seen (\held → (("load:" <> classify' loaded) : held, ()))
            try' "args" (evalOwned owned (chunkName "args") "local t = {} for i = 1, 200 do t[i] = i end sample.echo_list(t)")
            try' "results" (evalOwned owned (chunkName "results") "assert(#sample.make_list(200) == 200)")
            try' "record" (evalOwned owned (chunkName "record") "sample.echo_record({name = ('x'):rep(300), count = 1, note = 'n'})")
          ran ← readIORef entered
          captured slot >>= \case
            Nothing → pure ()
            Just vm → vmPhase vm >>= (`shouldBe` Closed)
          steps ← readIORef seen
          case result of
            Right () → do
              ran `shouldBe` True
              pure (("completed" ∷ Text) : steps)
            Left failure
              | Just (fault ∷ LuaFault) ← causeOf failure, faultKind fault == MemoryExhausted →
                  (ran `shouldBe` False) >> pure ["construction", "construction:" <> faultChunk fault]
              | Just (fault ∷ BoundaryFault) ← causeOf failure
              , ScriptFailed MemoryExhausted _ ← boundaryReason fault →
                  (ran `shouldBe` False) >> pure ["initial module"]
              | otherwise →
                  expectationFailure ("memory ran out and the failure was not classified: " <> show failure) >> pure []
      let kinds = nub (concat outcomes)
      -- Nothing ended any other way than completing or being refused for memory.
      filter (Text.isInfixOf "unclassified") kinds `shouldBe` []
      -- Memory ran out inside the boundary's own marshalling, in each direction,
      -- and it was reported as a fault of the call.
      forM_ ["args", "results", "record"] $ \label →
        kinds `shouldSatisfy` elem (label <> ":memory at the boundary")
      kinds `shouldSatisfy` elem "construction"
      -- Memory ran out while the registration's bindings were being installed in
      -- the VM, and while its namespaces and the value boundary's registry share
      -- were being made.
      kinds `shouldSatisfy` any ("construction:sample." `Text.isPrefixOf`)
      kinds `shouldSatisfy` any (`elem` ["construction:sample", "construction:other", "construction:values"])
      kinds `shouldSatisfy` elem "completed"
      kinds `shouldSatisfy` elem "initial module"
      -- Every operation of the body was, somewhere in the sweep, refused for lack
      -- of memory in a classified way, and somewhere succeeded.
      forM_ ["load", "args", "results", "record"] $ \label →
        kinds `shouldSatisfy` any (\entry → (label <> ":memory") `Text.isPrefixOf` entry)
      forM_ ["load", "call", "echo", "many", "args", "results", "record"] $ \label →
        kinds `shouldSatisfy` elem (label <> ":ok")

-- | A wide entry point's arguments are built on a stack that has to grow, so memory
-- can run out in reserving it: swept finely, and always a classified failure.
wideSweep ∷ Spec
wideSweep = describe "a wide entry point" $
  it "is a classified failure when memory runs out reserving the stack for its arguments" $ do
    fixture ← newFixture
    outcomes ←
      forM [0, 7 .. 60000] $ \budget → do
        result ←
          runOwner
            ( (defaultOwnerConfig libraries)
                { ownerBudget = Just budget
                , ownerRegistration = sampleRegistration fixture
                , ownerModules = [workbench]
                }
            )
            $ \owned → do
              Just handle ← loadedModule' owned
              try @SomeException (callEntry owned handle "many" (replicate 16 (VInteger 1)))
        pure $ case result of
          Right outcome → classify' outcome
          Left _ → "construction"
    filter (Text.isInfixOf "unclassified") (nub outcomes) `shouldBe` []
    nub outcomes `shouldSatisfy` elem "ok"
  where
    loadedModule' owned = loadedModule owned (ModuleRef "workbench" "1")

-- | How an operation of the sweep ended: it did, or it was refused for lack of
-- memory in one of the classified ways. Anything else is reported as such, and
-- the sweep's expectations name none.
classify' ∷ Either SomeException a → Text
classify' = \case
  Right _ → "ok"
  Left failure
    | Just (fault ∷ LuaFault) ← fromException failure, faultKind fault == MemoryExhausted → "memory in Lua"
    | Just (fault ∷ BoundaryFault) ← fromException failure → case boundaryReason fault of
        ScriptFailed MemoryExhausted _ → "memory at the boundary"
        other → "unclassified " <> Text.pack (show other)
    | otherwise → "unclassified " <> Text.pack (show failure)
