-- | The module loader: ordered import chains whose modules suspend on a dependency's
-- source and resume on the VM's owner.
--
-- Every example runs a real interpreter through the public owner and the rig of
-- injected seams ("Test.Lua.Boundary.Loader.Support"). Order is what modules marked,
-- through a binding, so it is read from what the application observed and not from a
-- module's own claim. A source is held by not having it, and let go by delivering it:
-- nothing here sleeps or reads a clock.
--
-- The bounds, the stop and the threads have examples of their own beside this one
-- ("Test.Lua.Boundary.Loader.Limits", "Test.Lua.Boundary.Loader.Stop",
-- "Test.Lua.Boundary.Loader.Threads").
module Test.Lua.Boundary.Loader (spec) where

import Control.Concurrent (myThreadId)
import Control.Monad (forM_)
import Data.IORef (readIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Internal.Module (Lead (..), callEntryWith)
import Hetoimasia.Scripting.Lua.Internal.Owner (ownedHost)
import Hetoimasia.Scripting.Lua.Value (Value (VInteger, VRecord))
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldNotBe, shouldSatisfy)
import Test.Lua.Boundary.Loader.Support

-- | The identities an advance settled, in order.
settledIds ∷ AdvanceReport → [ExportIdentity]
settledIds = map fst . advanceSettled

-- | The fault's dependency failure, if that is what it is: the dependency's label and
-- the fault the dependency failed with.
dependencyOf ∷ BoundaryFault → Maybe (Text, BoundaryFault)
dependencyOf fault = case boundaryReason fault of
  ModuleRefused (DependencyFailed label inner) → Just (label, inner)
  _ → Nothing

-- | A module that marks, imports, and returns what it was given.
simple ∷ Text → [Text] → [Text]
simple name body = ["trace.mark('" <> name <> "')"] <> body <> ["return { name = '" <> name <> "' }"]

spec ∷ Spec
spec = describe "the module loader" $ do
  describe "an import chain" $ do
    it "evaluates a dependency depth first, in the order Lua calls import, and hands back the very table" $
      withRig $ \rig owned → do
        _ ← admit owned "a"
        _ ←
          supply
            rig
            owned
            "a"
            [ "trace.mark('a:start')"
            , "local b = import('b')"
            , "trace.mark('a:got ' .. b.name)"
            , "local c = import('c')"
            , "trace.mark('a:got ' .. c.name)"
            , "return { name = 'a', b = b, c = c }"
            ]
        held ← advance owned
        advanceBlocked held `shouldBe` BlockedSource (ident "b")
        advanceChainDepth held `shouldBe` 1
        traced rig >>= (`shouldBe` ["a:start"])
        _ ← supply rig owned "b" (simple "b" ["local c = import('c')", "trace.mark('b:got ' .. c.name)"])
        again ← advance owned
        advanceBlocked again `shouldBe` BlockedSource (ident "c")
        advanceChainDepth again `shouldBe` 2
        _ ← supply rig owned "c" (simple "c" [])
        done ← advance owned
        advanceBlocked done `shouldBe` BlockedIdle
        advanceChainDepth done `shouldBe` 0
        settledIds done `shouldBe` map ident ["c", "b", "a"]
        traced rig >>= (`shouldBe` ["a:start", "b", "c", "b:got c", "a:got b", "a:got c"])
        ledger owned >>= (`shouldSatisfy` balanced)

    it "returns one table for repeated imports of an identity, shared with every importer of it" $
      withRig $ \rig owned → do
        _ ← supply rig owned "shared" (simple "shared" [])
        _ ←
          supply
            rig
            owned
            "a"
            [ "local one = import('shared')"
            , "local two = import('shared')"
            , "local b = import('b')"
            , "trace.mark(tostring(one == two) .. ':' .. tostring(b.shared == one))"
            , "return { shared = one }"
            ]
        _ ← supply rig owned "b" ["return { shared = import('shared') }"]
        _ ← admit owned "a"
        _ ← advance owned
        traced rig >>= (`shouldBe` ["shared", "true:true"])
        -- The very table a hook later imports, and the one the VM holds for the identity.
        statusOfName owned "shared" >>= (\status → status `shouldSatisfy` isReady)
        shared ← readyOf owned "shared"
        retrieveExport owned (ident "shared") >>= (`shouldBe` Just (ExportReady shared))
        ledger owned >>= (`shouldSatisfy` balanced)
        acquired rig >>= (`shouldBe` map ident ["a", "shared", "b"])

    it "reuses a dependency that is already a later root: evaluated within the chain, once, with its interest taken once" $
      withRig $ \rig owned → do
        _ ← admit owned "a"
        _ ← admit owned "b"
        _ ← supply rig owned "a" ["trace.mark('a:start')", "local b = import('b')", "trace.mark('a:end')", "return { b = b }"]
        held ← advance owned
        advanceBlocked held `shouldBe` BlockedSource (ident "b")
        acquired rig >>= (`shouldBe` map ident ["a", "b"])
        _ ← supply rig owned "b" (simple "b" [])
        done ← advance owned
        advanceBlocked done `shouldBe` BlockedIdle
        -- The later root settled within the importer's chain, before it, and the queue's
        -- later turn for it finds an outcome and evaluates nothing again.
        settledIds done `shouldBe` map ident ["b", "a"]
        traced rig >>= (`shouldBe` ["a:start", "b", "a:end"])
        acquired rig >>= (`shouldBe` map ident ["a", "b"])
        released rig >>= (`shouldBe` map ident ["a", "b"])
        ledger owned >>= (`shouldSatisfy` balanced)

    it "joins an identity that is evaluating or pending instead of taking a second interest in its source" $
      withRig $ \rig owned → do
        _ ← admit owned "a"
        _ ← supply rig owned "a" ["local b = import('b')", "return {}"]
        _ ← advance owned
        statusOfName owned "a" >>= (`shouldBe` ModuleEvaluating)
        statusOfName owned "b" >>= (`shouldBe` ModulePending)
        admit owned "a" >>= (`shouldBe` RootJoined)
        admit owned "b" >>= (`shouldBe` RootJoined)
        acquired rig >>= (`shouldBe` map ident ["a", "b"])
        counts ← moduleLoaderCounts owned
        (countPending counts, countEvaluating counts) `shouldBe` (1, 1)

    it "gives an export module evaluated without the loader no import: the loader is opt-in" $
      withRig $ \rig owned → do
        outcome ← evaluateExport owned (ExportSource (ident "legacy") "legacy" (lua ["trace.mark(type(import))", "return {}"]))
        outcome `shouldSatisfy` \case ExportReady _ → True; _ → False
        traced rig >>= (`shouldBe` ["nil"])

    it "runs every seam on the owner's thread or a callback of its VM, and only the owner releases" $
      withRig $ \rig owned → do
        owner ← myThreadId
        _ ← supply rig owned "b" ["return {}"]
        _ ← supply rig owned "a" ["local b = import('b')", "return {}"]
        _ ← admit owned "a"
        _ ← advance owned
        threads ← readIORef (rigThreads rig)
        forM_ [thread | ("release", thread) ← threads] (`shouldBe` owner)
        forM_ [thread | ("eligible", thread) ← threads] (`shouldBe` owner)
        -- The resolver and the acquire of a dependency run inside the callback an import is.
        forM_ [thread | ("resolve", thread) ← threads] (`shouldNotBe` owner)

    it "keeps a separate cache for each VM: the same identity is evaluated in each, to a table of its own" $
      withRig $ \rig owned → do
        _ ← supply rig owned "shared" (simple "shared" [])
        _ ← admit owned "shared"
        _ ← advance owned
        first ← readyOf owned "shared"
        withRig $ \rig' owned' → do
          statusOfName owned' "shared" >>= (`shouldBe` ModuleUnknown)
          _ ← supply rig' owned' "shared" (simple "shared" [])
          _ ← admit owned' "shared"
          _ ← advance owned'
          second ← readyOf owned' "shared"
          second `shouldNotBe` first
          traced rig' >>= (`shouldBe` ["shared"])
        -- Each ran its own module once, and the other's evaluation changed nothing here.
        traced rig >>= (`shouldBe` ["shared"])
        statusOfName owned "shared" >>= (`shouldBe` ModuleReady first)

    it "does not let a later root overtake the current one when its source arrives first" $
      withRig $ \rig owned → do
        _ ← admit owned "first"
        _ ← admit owned "second"
        _ ← supply rig owned "second" (simple "second" [])
        none ← advance owned
        advanceBlocked none `shouldBe` BlockedSource (ident "first")
        traced rig >>= (`shouldBe` [])
        _ ← supply rig owned "first" (simple "first" [])
        both ← advance owned
        traced rig >>= (`shouldBe` ["first", "second"])
        settledIds both `shouldBe` map ident ["first", "second"]

    it "does not start a root the coordinator has not made eligible, whatever has arrived" $
      withRig $ \rig owned → do
        _ ← supply rig owned "tick1" (simple "tick1" [])
        _ ← supply rig owned "tick2" (simple "tick2" [])
        _ ← admit owned "tick1"
        _ ← admit owned "tick2"
        setEligible rig ["tick2"]
        held ← advance owned
        -- The head is not eligible, so the eligible root behind it waits too.
        advanceBlocked held `shouldBe` BlockedIneligible (ident "tick1")
        traced rig >>= (`shouldBe` [])
        setEligible rig ["tick1"]
        some ← advance owned
        advanceBlocked some `shouldBe` BlockedIneligible (ident "tick2")
        traced rig >>= (`shouldBe` ["tick1"])
        allEligible rig
        _ ← advance owned
        traced rig >>= (`shouldBe` ["tick1", "tick2"])

    it "says what source arrival alone does: it evaluates nothing until the loader is advanced" $
      withRig $ \rig owned → do
        _ ← admit owned "a"
        delivered ← supply rig owned "a" (simple "a" [])
        delivered `shouldBe` SourceDelivered
        traced rig >>= (`shouldBe` [])
        statusOfName owned "a" >>= (`shouldBe` ModulePending)
        _ ← advance owned
        traced rig >>= (`shouldBe` ["a"])

  describe "failures" $ do
    it "keeps a source failure, a rejected chunk, a script error and every bad return as the identity's sticky failure" $
      withRig $ \rig owned → do
        let cases ∷ [(Text, [Text])]
            cases =
              [ ("syntax", ["return {"])
              , ("runtime", ["error('boom')"])
              , ("none", [])
              , ("nil", ["return nil"])
              , ("number", ["return 1"])
              , ("two", ["return {}, {}"])
              , ("metatable", ["return setmetatable({}, {})"])
              ]
        forM_ cases $ \(name, body) → do
          _ ← admit owned name
          _ ← supply rig owned name body
          _ ← advance owned
          failed ← failureOf owned name
          boundaryOperation failed `shouldBe` EvaluateExport
        _ ← admit owned "gone"
        _ ← supplyFailure rig owned "gone" "the file is missing"
        _ ← advance owned
        gone ← failureOf owned "gone"
        boundaryReason gone `shouldBe` ModuleRefused (SourceUnavailable "game:gone" "the file is missing")
        -- A later import of any of them is the cached failure, with no retry and no new
        -- interest in the source.
        before ← acquired rig
        _ ← admit owned "user"
        _ ← supply rig owned "user" ["local ok, err = pcall(import, 'syntax')", "return { ok = ok }"]
        _ ← advance owned
        user ← failureOf owned "user"
        fmap fst (dependencyOf user) `shouldBe` Just "game:syntax"
        acquired rig >>= (`shouldBe` (before <> [ident "user"]))
        ledger owned >>= (`shouldSatisfy` balanced)

    it "fails a module that imported a failed dependency even when its code caught the error and returned a table" $
      withRig $ \rig owned → do
        _ ← supply rig owned "bad" ["error('no')"]
        _ ← supply rig owned "a" ["local ok, err = pcall(import, 'bad')", "trace.mark('caught ' .. tostring(ok))", "return { survived = true }"]
        _ ← admit owned "a"
        _ ← advance owned
        traced rig >>= (`shouldBe` ["caught false"])
        failed ← failureOf owned "a"
        fmap fst (dependencyOf failed) `shouldBe` Just "game:bad"
        -- Nothing of it was published.
        ledger owned >>= \found → ledgerExports found `shouldBe` 0

    it "grants a module chunk no scheduler yield: the call is refused before it suspends anything, and the module fails" $
      withRig $ \rig owned → do
        _ ← supply rig owned "yielding" ["local ok = pcall(sched.yield)", "trace.mark('after ' .. tostring(ok))", "return {}"]
        _ ← supply rig owned "after" (simple "after" [])
        _ ← admit owned "yielding"
        _ ← admit owned "after"
        report ← advance owned
        advanceBlocked report `shouldBe` BlockedIdle
        failed ← failureOf owned "yielding"
        boundaryReason failed `shouldBe` SuspendRefused SuspendOutsideTask
        statusOfName owned "after" >>= (`shouldSatisfy` isReady)
        traced rig >>= (`shouldBe` ["after false", "after"])
        ledger owned >>= (`shouldSatisfy` balanced)

    it "refuses a precompiled chunk: only text is loaded" $
      withRig $ \rig owned → do
        _ ← admit owned "binary"
        delivered ← supplyBytes rig owned "binary" "\ESCLua\x54\x00\x19\x93\r\n\x1a\n"
        delivered `shouldBe` SourceDelivered
        _ ← advance owned
        failed ← failureOf owned "binary"
        failed `shouldSatisfy` \fault → case boundaryReason fault of ScriptFailed _ _ → boundaryEffect fault == NoEffect; _ → False
        ledger owned >>= (`shouldSatisfy` balanced)

    it "fails a module a binding refused as a fault of the call, even when its code caught the error, and goes on" $
      withRig $ \rig owned → do
        _ ← supply rig owned "refused" ["local ok = pcall(trace.strict, 5)", "trace.mark('caught ' .. tostring(ok))", "return {}"]
        _ ← supply rig owned "after" (simple "after" [])
        _ ← admit owned "refused"
        _ ← admit owned "after"
        report ← advance owned
        advanceBlocked report `shouldBe` BlockedIdle
        failed ← failureOf owned "refused"
        case boundaryReason failed of
          ValueRefused _ → pure ()
          other → expectationFailure ("unexpected reason " <> show other)
        statusOfName owned "after" >>= (`shouldSatisfy` isReady)
        traced rig >>= (`shouldBe` ["caught false", "after"])
        ledger owned >>= (`shouldSatisfy` balanced)

    it "fails the importer of a dependency that failed, keeps the dependencies that completed, and does not rerun them" $
      withRig $ \rig owned → do
        _ ← supply rig owned "good" (simple "good" [])
        _ ← supply rig owned "bad" ["error('no')"]
        _ ← supply rig owned "a" ["import('good')", "import('bad')", "return {}"]
        _ ← supply rig owned "later" ["local good = import('good')", "return { good = good }"]
        _ ← admit owned "a"
        _ ← admit owned "later"
        _ ← advance owned
        failureOf owned "a" >>= \failed → fmap fst (dependencyOf failed) `shouldBe` Just "game:bad"
        statusOfName owned "good" >>= (`shouldSatisfy` isReady)
        statusOfName owned "later" >>= (`shouldSatisfy` isReady)
        traced rig >>= (`shouldBe` ["good"])
        ledger owned >>= (`shouldSatisfy` balanced)

    it "reports a cycle with its chain, and not as an extra frame" $
      withRig $ \rig owned → do
        _ ← supply rig owned "a" ["local b = import('b')", "return {}"]
        _ ← supply rig owned "b" ["local c = import('c')", "return {}"]
        _ ← supply rig owned "c" ["local a = import('a')", "return {}"]
        _ ← admit owned "a"
        _ ← advance owned
        failed ← failureOf owned "c"
        boundaryReason failed `shouldBe` ModuleRefused (ImportCycle (map (\n → "game:" <> n) ["a", "b", "c", "a"]))
        -- Each importer above it fails with the dependency.
        failureOf owned "b" >>= \inner → fmap fst (dependencyOf inner) `shouldBe` Just "game:c"
        failureOf owned "a" >>= \inner → fmap fst (dependencyOf inner) `shouldBe` Just "game:b"
        ledger owned >>= (`shouldSatisfy` balanced)

    it "reports an import of itself with the identity twice" $
      withRig $ \rig owned → do
        _ ← supply rig owned "a" ["return import('a')"]
        _ ← admit owned "a"
        _ ← advance owned
        failureOf owned "a" >>= \failed → boundaryReason failed `shouldBe` ModuleRefused (ImportCycle ["game:a", "game:a"])

  describe "where Lua cannot suspend" $ do
    let refusedIn name body = it ("refuses a pending import inside " <> name <> ", admits nothing and fails the containing load even if caught") $
          withRig $ \rig owned → do
            _ ← supply rig owned "m" (["local ok = pcall(function()"] <> map ("  " <>) body <> ["end)", "trace.mark('caught')", "return {}"])
            _ ← admit owned "m"
            before ← ledger owned
            report ← advance owned
            advanceBlocked report `shouldBe` BlockedIdle
            traced rig >>= (`shouldBe` ["caught"])
            failed ← failureOf owned "m"
            case boundaryReason failed of
              ModuleRefused (ImportNotSuspendable _ "game:p") → pure ()
              other → expectationFailure ("unexpected reason " <> show other)
            -- The dependency was neither admitted nor asked for.
            statusOfName owned "p" >>= (`shouldBe` ModuleUnknown)
            acquired rig >>= (`shouldBe` [ident "m"])
            after ← ledger owned
            countFailed (ledgerCounts after) `shouldBe` 1
            countPending (ledgerCounts after) `shouldBe` countPending (ledgerCounts before) - 1
    refusedIn "a coroutine the script created" ["coroutine.wrap(function() import('p') end)()"]
    refusedIn "a table.sort comparator" ["table.sort({3, 2, 1}, function(a, b) import('p') return a < b end)"]
    refusedIn "a string.gsub replacement callback" ["string.gsub('x', 'x', function() import('p') return 'y' end)"]
    refusedIn "a finalizer" ["setmetatable({}, { __gc = function() import('p') end })", "collectgarbage()"]
    refusedIn
      "a to-be-closed handler run by coroutine.close on a coroutine the script created"
      [ "local co = coroutine.create(function()"
      , "  local guard <close> = setmetatable({}, { __close = function() import('p') end })"
      , "  coroutine.yield()"
      , "end)"
      , "coroutine.resume(co)"
      , "coroutine.close(co)"
      ]

    it "still returns a ready identity in those places" $
      withRig $ \rig owned → do
        _ ← supply rig owned "ready" (simple "ready" [])
        _ ←
          supply
            rig
            owned
            "m"
            [ "local ready = import('ready')"
            , "coroutine.wrap(function() trace.mark('coroutine ' .. import('ready').name) end)()"
            , "table.sort({2, 1}, function(a, b) trace.mark('sort ' .. import('ready').name) return a < b end)"
            , "string.gsub('x', 'x', function() trace.mark('gsub ' .. import('ready').name) return 'y' end)"
            , "return { ready = ready }"
            ]
        _ ← admit owned "m"
        _ ← advance owned
        statusOfName owned "m" >>= (`shouldSatisfy` isReady)
        marked ← traced rig
        marked `shouldSatisfy` elem "coroutine ready"
        marked `shouldSatisfy` elem "sort ready"
        marked `shouldSatisfy` elem "gsub ready"

    it "still reports the cached failure of a failed identity in those places, and condemns the module" $
      withRig $ \rig owned → do
        _ ← supply rig owned "bad" ["error('x')"]
        _ ← supply rig owned "first" ["import('bad')"]
        _ ← admit owned "first"
        _ ← admit owned "m"
        _ ← advance owned
        _ ← supply rig owned "m" ["pcall(function() table.sort({2, 1}, function(a, b) import('bad') return a < b end) end)", "return {}"]
        _ ← advance owned
        failureOf owned "m" >>= \failed → fmap fst (dependencyOf failed) `shouldBe` Just "game:bad"

    it "suspends in a to-be-closed handler of the module's own coroutine, where Lua can suspend it, and resumes the handler" $
      withRig $ \rig owned → do
        _ ←
          supply
            rig
            owned
            "m"
            [ "do"
            , "  local guard <close> = setmetatable({}, { __close = function() trace.mark('closing ' .. import('late').name) end })"
            , "end"
            , "local ok = pcall(function()"
            , "  local guard <close> = setmetatable({}, { __close = function() trace.mark('unwinding ' .. import('late').name) end })"
            , "  error('unwound')"
            , "end)"
            , "return {}"
            ]
        _ ← admit owned "m"
        held ← advance owned
        advanceBlocked held `shouldBe` BlockedSource (ident "late")
        _ ← supply rig owned "late" (simple "late" [])
        _ ← advance owned
        statusOfName owned "m" >>= (`shouldSatisfy` isReady)
        traced rig >>= (`shouldBe` ["late", "closing late", "unwinding late"])

    it "suspends across pcall, xpcall and a metamethod called from Lua code like any other call" $
      withRig $ \rig owned → do
        _ ←
          supply
            rig
            owned
            "m"
            [ "local ok1, one = pcall(import, 'one')"
            , "local ok2, two = xpcall(import, function(e) return e end, 'two')"
            , "local lazy = setmetatable({}, { __index = function(_, key) return import(key) end })"
            , "local three = lazy.three"
            , "trace.mark(tostring(ok1) .. tostring(ok2) .. one.name .. two.name .. three.name)"
            , "return {}"
            ]
        _ ← admit owned "m"
        forM_ ["one", "two", "three"] $ \name → do
          held ← advance owned
          advanceBlocked held `shouldBe` BlockedSource (ident name)
          _ ← supply rig owned name (simple name [])
          pure ()
        _ ← advance owned
        traced rig >>= (`shouldBe` ["one", "two", "three", "truetrueonetwothree"])

    it "fails a module that yields at its top level, with a fault of its own, and goes on" $
      withRig $ \rig owned → do
        _ ← supply rig owned "yields" ["coroutine.yield()", "return {}"]
        _ ← supply rig owned "after" (simple "after" [])
        _ ← admit owned "yields"
        _ ← admit owned "after"
        _ ← advance owned
        failureOf owned "yields" >>= \failed → boundaryReason failed `shouldBe` UnscheduledYield
        statusOfName owned "after" >>= (`shouldSatisfy` isReady)
        ledger owned >>= (`shouldSatisfy` balanced)

  describe "a facade stashed in shared exports" $
    it "gives a module's top level no engine service, and gives it to a hook that calls the same closure" $
      withRigAt (\config → config {vmModules = [hookDriver]}) $ \rig owned → do
        -- The first module keeps the facade a hook is handed in its own exports.
        _ ←
          supply
            rig
            owned
            "keeper"
            [ "local M = {}"
            , "M.build = function(context) return { acquire = function() return svc.acquire() end } end"
            , "M.gameplay = { init = function(self, api)"
            , "  M.stash = api"
            , "  if M.invoke then trace.mark('hook:' .. tostring(M.stash.acquire())) end"
            , "end }"
            , "return M"
            ]
        _ ← admit owned "keeper"
        _ ← advance owned
        keeper ← readyOf owned "keeper"
        driverHandle ← loadedModule owned (ModuleRef "driver" "1") >>= maybe (error "no driver") pure
        capture ← captureBehavior owned keeper "gameplay" (FacadeBuilt keeper "build" (VRecord [])) >>= either (error . show) pure
        let runHook' = callEntryWith (LeadCaptured driverHandle "call_init" (capturedHandle capture) HookInit) (ownedHost owned) driverHandle "init" [VInteger 0]
        _ ← runHook'
        -- A module evaluated later reaches the facade through the shared exports and calls it
        -- at its top level: refused as an ordinary error, before the binding's action.
        _ ←
          supply
            rig
            owned
            "later"
            [ "local keeper = import('keeper')"
            , "trace.mark('stash:' .. type(keeper.stash))"
            , "local ok, err = pcall(keeper.stash.acquire)"
            , "trace.mark('later:' .. tostring(ok) .. ':' .. tostring(err))"
            , "keeper.invoke = true"
            , "return {}"
            ]
        _ ← admit owned "later"
        _ ← advance owned
        marked ← traced rig
        take 1 marked `shouldBe` ["stash:table"]
        marked `shouldSatisfy` any (\line → "later:false:" `Text.isPrefixOf` line && "no service while a module's top level runs" `Text.isInfixOf` line)
        actions rig >>= (`shouldBe` 0)
        -- The same closure, called by a hook, acts.
        _ ← runHook'
        traced rig >>= (`shouldSatisfy` elem "hook:1")
        actions rig >>= (`shouldBe` 1)

  describe "the default root of an import" $
    it "is the root of the module the closure belongs to, even when a helper runs in a hook of a module of another root" $
      withRigAt (\config → config {vmModules = [hookDriver]}) $ \rig owned → do
        _ ← supplyIn rig owned (rootAt "mod" "lib") ["return { helper = function() return import('x') end }"]
        _ ← admitRoot owned (RootRequest (rootAt "mod" "lib") "mod:lib")
        _ ← supply rig owned "hook" ["local lib = import('lib', 'mod')", "return { gameplay = { init = function(self, api) local ok, err = pcall(lib.helper) trace.mark(tostring(err)) end } }"]
        _ ← admit owned "hook"
        _ ← advance owned
        statusOfName owned "hook" >>= (`shouldSatisfy` isReady)
        runInit owned "hook"
        -- The helper belongs to a module of the mod root, so its import is a module of that root,
        -- whichever module's hook called it.
        traced rig >>= (`shouldSatisfy` any (Text.isInfixOf "module_not_ready: mod:x"))

  describe "the resolver's refusals" $ do
    it "are ordinary Lua errors before any identity, source interest or frame, and do not latch a failure" $
      withRig $ \rig owned → do
        _ ←
          supply
            rig
            owned
            "m"
            [ "local results = {}"
            , "results[1] = pcall(import, '../escape')"
            , "results[2] = pcall(import, 'x', 'off')"
            , "results[3] = pcall(import, 7)"
            , "results[4] = pcall(import)"
            , "results[5] = pcall(import, 'x', 'game', 'extra')"
            , "results[6] = pcall(import, '')"
            , "local flags = {}"
            , "for i = 1, 6 do flags[i] = tostring(results[i]) end"
            , "trace.mark(table.concat(flags, ','))"
            , "return {}"
            ]
        _ ← admit owned "m"
        before ← ledger owned
        _ ← advance owned
        traced rig >>= (`shouldBe` ["false,false,false,false,false,false"])
        statusOfName owned "m" >>= (`shouldSatisfy` isReady)
        after ← ledger owned
        -- Nothing was admitted, asked for or left on the chain by any of them.
        countFailed (ledgerCounts after) `shouldBe` 0
        countPending (ledgerCounts after) `shouldBe` 0
        acquired rig >>= (`shouldBe` [ident "m"])
        ledgerStack after `shouldBe` ledgerStack before

    it "choose the importing module's root unless one is given, and resolve a given root" $
      withRig $ \rig owned → do
        _ ← supply rig owned "m" ["local other = import('x', 'mod')", "return { other = other }"]
        _ ← supply rig owned "x" ["return { root = 'game' }"]
        _ ← admit owned "m"
        _ ← advance owned
        acquired rig >>= (`shouldBe` [ident "m", rootAt "mod" "x"])

  describe "the immediate lookup of a hook" $ do
    it "returns a ready module's exports, and refuses an absent or pending one without reading anything" $
      withRigAt (\config → config {vmModules = [hookDriver]}) $ \rig owned → do
        _ ← supply rig owned "ready" (simple "ready" [])
        _ ← admit owned "ready"
        _ ← supply rig owned "hook"
          [ "return { gameplay = { init = function(self, api)"
          , "  trace.mark('hook:' .. import('ready').name)"
          , "  local ok1, err1 = pcall(import, 'absent')"
          , "  trace.mark('absent:' .. tostring(ok1) .. ':' .. tostring(err1))"
          , "  local ok2, err2 = pcall(import, 'pending')"
          , "  trace.mark('pending:' .. tostring(ok2))"
          , "end } }"
          ]
        _ ← admit owned "hook"
        _ ← admit owned "pending"
        _ ← advance owned
        before ← ledger owned
        acquiredBefore ← acquired rig
        runInit owned "hook"
        marked ← traced rig
        marked `shouldSatisfy` elem "hook:ready"
        marked `shouldSatisfy` any ("absent:false:" `Text.isPrefixOf`)
        marked `shouldSatisfy` any (Text.isInfixOf "module_not_ready" . (\line → line))
        marked `shouldSatisfy` elem "pending:false"
        after ← ledger owned
        -- It read nothing, started no work and suspended nothing.
        acquired rig >>= (`shouldBe` acquiredBefore)
        ledgerCounts after `shouldBe` ledgerCounts before
        ledgerTasks after `shouldBe` ledgerTasks before

    it "reports the cached failure of a failed module" $
      withRigAt (\config → config {vmModules = [hookDriver]}) $ \rig owned → do
        _ ← supply rig owned "bad" ["error('no')"]
        _ ← supply rig owned "hook" ["return { gameplay = { init = function(self, api) local ok, err = pcall(import, 'bad') trace.mark('bad:' .. tostring(ok) .. ':' .. tostring(err)) end } }"]
        _ ← admit owned "bad"
        _ ← admit owned "hook"
        _ ← advance owned
        runInit owned "hook"
        marked ← traced rig
        marked `shouldSatisfy` any ("bad:false:" `Text.isPrefixOf`)

  describe "the phase of a module's top level" $ do
    it "refuses an engine service as an ordinary error before its action, and allows it to a helper called from a hook" $
      withRigAt (\config → config {vmModules = [hookDriver]}) $ \rig owned → do
        _ ←
          supply
            rig
            owned
            "m"
            [ "local M = {}"
            , "local ok, err = pcall(svc.acquire)"
            , "trace.mark('top:' .. tostring(ok))"
            , "function M.helper() return svc.acquire() end"
            , "M.gameplay = { init = function(self, api) trace.mark('hook:' .. tostring(M.helper())) end }"
            , "return M"
            ]
        _ ← admit owned "m"
        _ ← advance owned
        statusOfName owned "m" >>= (`shouldSatisfy` isReady)
        traced rig >>= (`shouldBe` ["top:false"])
        actions rig >>= (`shouldBe` 0)
        runInit owned "m"
        traced rig >>= (`shouldBe` ["top:false", "hook:1"])
        actions rig >>= (`shouldBe` 1)
        -- An unguarded service call at the top level does not fail the module: the
        -- refusal is an ordinary error, and a script that does not catch it fails.
        _ ← supply rig owned "u" ["svc.acquire()", "return {}"]
        _ ← admit owned "u"
        _ ← advance owned
        failureOf owned "u" >>= \failed → case boundaryReason failed of
          ScriptFailed _ _ → pure ()
          other → expectationFailure ("unexpected reason " <> show other)
        actions rig >>= (`shouldBe` 1)

-- | Whether a status is a ready module.
isReady ∷ ModuleStatus → Bool
isReady = \case
  ModuleReady _ → True
  _ → False
