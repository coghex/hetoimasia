{-# LANGUAGE OverloadedStrings #-}

-- | LFE-23, M1 integrated shared jobs and assigned results: real module and data requests from real Lua over the
-- one two-worker read pool a session shares between its VMs, with the pool's reader held at gates the example
-- opens, and a logical owner and a UI VM running at once.
--
-- __Real__: Lua VMs, the module coordinator and loader, the data service, the request reservations, the facade, the
-- scheduled owners and the verified read pool with its two workers.
--
-- __Injected__: the clock and the timer, the recording sinks, and the gates around the pool's reader (a gated read
-- still opens and hashes a real file once its gate opens). Logical time is moved by the example's own grants.
--
-- The expected positions are stated from the Lua each example wrote (a request's @tick_offset@ and the tick it was
-- made in), never read back from the implementation.
module Test.LuaEngine.Integrated.Jobs (spec) where

import Control.Monad (forM_)
import qualified Data.Text as Text
import Data.ByteString (ByteString)
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.Scripting.Lua.Instance (InstanceOutcome (InstanceStopped), InstancePhase (Active), InstanceSettlement (resultOutcome))
import Hetoimasia.Scripting.Lua.Scheduled (retireScheduled)
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Integrated.Support
import Hetoimasia.Content.ReadPool (PoolStatus (statusQueued))
import Test.LuaEngine.Modules.Support (awaitDiagnostics, awaitPool, closeGate, diagnostics, finishedPaths, openGate, startedPaths)

spec ∷ Spec
spec = describe "M1 integrated shared jobs and assigned results" $ do
  heldResultSpec
  importChainSpec
  waitersSpec
  vmStopSpec

-- | A logical request's result, held at its position, with UI traffic sharing the pool.
heldResultSpec ∷ Spec
heldResultSpec =
  it "settles a logical result at its assigned tick: an early result stays unavailable, a late required one holds that tick without stretching wall time or the UI, and a worker never waits for Lua or a tick" $
    withWorld fixedM1Profile (Layout (("lua/main.lua", held) : files)) $ \world control runtime →
      withFvm world runtime gameplayShape $ \logical → withFvm world runtime presentationShape $ \ui → do
        let probe = ssProbe (wSession world)
        closeGate probe "lua/late.lua"
        l ← spawn world logical "modules-test" mainPath
        u ← spawn world ui "modules-test" mainPath
        dumpOnFailure world [l, u] $ do
          -- ticks 1 and 2: the module due at tick 3 and the data due at tick 5 are not visible. The early data has been
          -- read long since: its worker is free, and only its position keeps it from the script.
          tickBy control logical 2
          awaitFinishedPath probe "early.bin"
          out2 ← outLines world
          named "L tick" out2 `shouldBe` ["1 late=false early=false", "2 late=false early=false"]
          -- tick 3 is granted and its module's source has not arrived: the tick is held, however much wall time passes
          grantTick logical
          awaitStartedPath probe "lua/late.lua"
          advanceClock world 10000000000
          ownerTick logical >>= (`shouldBe` 2)
          -- meanwhile the UI is served, and its own read finishes through the second worker (the held read occupies one)
          awaitLine world "U data success"
          pumpClock world ((>= 3) . length . named "U update" <$> outLines world)
          ownerTick logical >>= (`shouldBe` 2)
          named "L tick" <$> outLines world >>= (`shouldBe` ["1 late=false early=false", "2 late=false early=false"])
          finished ← finishedPaths probe
          ("lua/late.lua" `elem` finished) `shouldBe` False
          -- the source arrives: the held tick completes at its own number, and the module is visible exactly then
          openGate probe "lua/late.lua"
          awaitTickDone control logical
          ownerTick logical >>= (`shouldBe` 3)
          tickBy control logical 2
          out ← outLines world
          -- no tick was dropped, repeated or retimed, and the data became visible at tick 5 and not before
          named "L tick" out
            `shouldBe` ["1 late=false early=false", "2 late=false early=false", "3 late=true early=false", "4 late=true early=false", "5 late=true early=true"]
          stopSpawned l >> stopSpawned u
          mapM_ settledOf [l, u]
  where
    files =
      [ ("lua/late.lua", luaMain ["return {id = 'late'}"])
      , ("early.bin", "ee")
      , ("data.bin", "dd")
      ]
    held =
      luaMain
        [ "local function ginit(self, api)"
        , "  self.keep = api"
        , "  self.late = api.content.module('lua/late.lua', {tick_offset = 3})"
        , "  self.early = api.content.data('early.bin', {tick_offset = 5})"
        , "end"
        , "local function gupdate(self, dt)"
        , "  local api = self.keep"
        , "  print('L tick ' .. api.time.tick() .. ' late=' .. tostring(api.request.ready(self.late)) .. ' early=' .. tostring(api.request.ready(self.early)))"
        , "end"
        , "local function uinit(self, api)"
        , "  self.keep = api"
        , "  self.n = 0"
        , "  self.d = api.content.data('data.bin')"
        , "end"
        , "local function uupdate(self, dt)"
        , "  local api = self.keep"
        , "  self.n = self.n + 1"
        , "  if self.d and api.request.ready(self.d) then"
        , "    print('U data ' .. api.request.take(self.d).status)"
        , "    self.d = nil"
        , "  end"
        , "  print('U update ' .. self.n)"
        , "end"
        , "return {"
        , "  gameplay = {every_ticks = 1, init = ginit, update = gupdate},"
        , "  presentation = {every_seconds = 1, init = uinit, update = uupdate}"
        , "}"
        ]

-- | An import chain active at its position while unrelated reads hold both workers.
importChainSpec ∷ Spec
importChainSpec =
  it "evaluates a module once in its importer's chain at the importer's tick while its own request settles at its own, and the chain's dependency read proceeds while unrelated prefetch holds both workers" $
    withWorld fixedM1Profile (Layout (("lua/main.lua", chain) : files)) $ \world control runtime →
      withFvm world runtime gameplayShape $ \logical → do
        let probe = ssProbe (wSession world)
        forM_ ["pre1.bin", "pre2.bin", "pre3.bin"] (closeGate probe)
        l ← spawn world logical "modules-test" mainPath
        dumpOnFailure world [l] $ do
          -- A and B were requested at tick 0 and their sources have been read. Unrelated prefetch, asked for in tick 1 and
          -- due at tick 11, then holds both workers in the reader with a third read queued behind them
          tickBy control logical 1
          awaitFinishedPath probe "lua/a.lua"
          awaitFinishedPath probe "lua/b.lua"
          awaitStartedPath probe "pre1.bin"
          awaitStartedPath probe "pre2.bin"
          tickBy control logical 8
          named "L tick" <$> outLines world >>= (`shouldBe` map (\n → Text.pack (show n) <> " a=false b=false") [1 ∷ Int .. 9])
          startedPaths probe >>= (`shouldNotContain` ["pre3.bin"])
          -- tick 10 is granted: A is evaluated, B, already requested for tick 12, is evaluated in A's chain, and C, which
          -- nobody asked for, is wanted by the chain with both workers held. A worker is freed; the chain's dependency
          -- is read before the prefetch that was queued earlier.
          grantTick logical
          awaitErrLines world 2
          ownerTick logical >>= (`shouldBe` 9)
          -- the chain's dependency is queued beside the prefetch that was queued earlier (both wait for a worker) before a worker is
          -- freed, so that the order the pool serves them in is the priority and not an accident of arrival
          awaitPool (wSession world) (\found → statusQueued found >= 2)
          openGate probe "pre2.bin"
          awaitFinishedPath probe "lua/c.lua"
          awaitTickDone control logical
          ownerTick logical >>= (`shouldBe` 10)
          started ← startedPaths probe
          let position path = lookup path (zip started [0 ∷ Int ..])
          position "lua/c.lua" `shouldSatisfy` maybe False (\c → maybe True (c <) (position "pre3.bin"))
          finished ← finishedPaths probe
          ("pre1.bin" `elem` finished) `shouldBe` False
          out10 ← outLines world
          last (named "L tick" out10) `shouldBe` "10 a=true b=false"
          err10 ← errLines world
          [Text.takeWhileEnd (/= ' ') line | line ← err10, "eval " `Text.isInfixOf` line] `shouldBe` ["a", "b", "c"]
          -- the prefetch is released; its data is visible at tick 11; B's own request at tick 12, and it is the very table
          -- A's chain evaluated
          forM_ ["pre1.bin", "pre3.bin"] (openGate probe)
          tickBy control logical 2
          out ← outLines world
          drop 9 (named "L tick" out) `shouldBe` ["10 a=true b=false", "11 a=true b=false", "12 a=true b=true"]
          named "L pre" out `shouldBe` ["11 true true"]
          named "L same" out `shouldBe` ["true"]
          -- one evaluation of each module in all
          err ← errLines world
          length [line | line ← err, "eval b" `Text.isSuffixOf` line] `shouldBe` 1
          stopSpawned l
          mapM_ settledOf [l]
  where
    files =
      [ ("lua/a.lua", luaMain ["warn('eval a')", "local b = import('lua/b.lua')", "local c = import('lua/c.lua')", "return {id = 'a', b = b, c = c}"])
      , ("lua/b.lua", luaMain ["warn('eval b')", "return {id = 'b'}"])
      , ("lua/c.lua", luaMain ["warn('eval c')", "return {id = 'c'}"])
      , ("pre1.bin", "p1")
      , ("pre2.bin", "p2")
      , ("pre3.bin", "p3")
      ]
    chain =
      luaMain
        [ "local function ginit(self, api)"
        , "  self.keep = api"
        , "  self.b = api.content.module('lua/b.lua', {tick_offset = 12})"
        , "  self.a = api.content.module('lua/a.lua', {tick_offset = 10})"
        , "end"
        , "local function gupdate(self, dt)"
        , "  local api = self.keep"
        , "  local t = api.time.tick()"
        , "  if t == 1 then"
        , "    self.p1 = api.content.data('pre1.bin', {tick_offset = 10})"
        , "    self.p2 = api.content.data('pre2.bin', {tick_offset = 10})"
        , "    self.p3 = api.content.data('pre3.bin', {tick_offset = 10})"
        , "  end"
        , "  print('L tick ' .. t .. ' a=' .. tostring(api.request.ready(self.a)) .. ' b=' .. tostring(api.request.ready(self.b)))"
        , "  if t == 11 then print('L pre 11 ' .. tostring(api.request.ready(self.p1)) .. ' ' .. tostring(api.request.ready(self.p2))) end"
        , "  if t == 12 then"
        , "    local a = api.request.take(self.a).value"
        , "    local b = api.request.take(self.b).value"
        , "    print('L same ' .. tostring(rawequal(a.b, b)))"
        , "  end"
        , "end"
        , "return {gameplay = {every_ticks = 1, init = ginit, update = gupdate}, presentation = {}}"
        ]

-- | Two UI instances wait for one module; one leaves, then the other; the job is the VM's.
waitersSpec ∷ Spec
waitersSpec =
  it "keeps a shared module job and the peer's result when one waiter ends, finishes and caches a job at its retained position when its last waiter cancels, and logs an ordinary no-waiter failure without failing any instance" $
    withWorld fixedM1Profile (Layout (("lua/main.lua", waiters) : waiterFiles)) $ \world _ runtime →
      withFvm world runtime presentationShape $ \ui → do
        let probe = ssProbe (wSession world)
        forM_ ["lua/m.lua", "lua/n.lua", "lua/bad.lua"] (closeGate probe)
        x ← spawn world ui "modules-test" mainPath
        y ← spawn world ui "modules-test" mainPath
        dumpOnFailure world [x, y] $ do
          awaitLine world "X asked"
          awaitLine world "Y asked"
          awaitStartedPath probe "lua/m.lua"
          awaitStartedPath probe "lua/n.lua"
          -- two waiters on each module, one VM-owned job and one read for each
          started0 ← startedPaths probe
          length (filter (== "lua/m.lua") started0) `shouldBe` 1
          length (filter (== "lua/n.lua") started0) `shouldBe` 1
          -- one waiter ends (Haskell-controlled): both jobs and the peer's interest survive
          stopSpawned y
          settlement ← settledOf y
          resultOutcome settlement `shouldSatisfy` isStopped
          finished0 ← finishedPaths probe
          (any (`elem` finished0) ["lua/m.lua", "lua/n.lua"]) `shouldBe` False
          phaseOf x >>= (`shouldBe` Just Active)
          -- the peer's result is delivered when the source arrives
          openGate probe "lua/m.lua"
          awaitLine world "X m success"
          -- the last waiter of the other job cancels: nobody waits for it, and the admitted job still finishes and caches
          setStatus world (StatusSample True Nothing Nothing)
          awaitLine world "X cancel_n cancelled"
          openGate probe "lua/n.lua"
          awaitFinishedPath probe "lua/n.lua"
          _ ← awaitErr world 3
          -- a request made afterwards is served from the cache; an ordinary failure with no waiter is logged and cached
          setStatus world (StatusSample True (Just (RoleSample True "running" Nothing)) Nothing)
          awaitLine world "X again success"
          awaitLine world "X bad_cancel cancelled"
          openGate probe "lua/bad.lua"
          awaitFinishedPath probe "lua/bad.lua"
          awaitDiagnostics (wSession world) 1
          err ← errLines world
          length [line | line ← err, "eval m" `Text.isSuffixOf` line] `shouldBe` 1
          length [line | line ← err, "eval n" `Text.isSuffixOf` line] `shouldBe` 1
          started ← startedPaths probe
          length (filter (== "lua/n.lua") started) `shouldBe` 1
          diagnostics (wSession world) >>= \found → found `shouldSatisfy` any ("lua/bad.lua" `Text.isInfixOf`)
          -- the failure was nobody's: the surviving instance is untouched
          phaseOf x >>= (`shouldBe` Just Active)
        stopSpawned x
        mapM_ settledOf [x]
  where
    isStopped = \case
      InstanceStopped → True
      _ → False

-- | The files of the waiter examples.
waiterFiles ∷ [(FilePath, ByteString)]
waiterFiles =
  [ ("lua/share.lua", shareModule)
  , ("lua/m.lua", luaMain ["warn('eval m')", "return {id = 'm'}"])
  , ("lua/n.lua", luaMain ["warn('eval n')", "return {id = 'n'}"])
  , ("lua/bad.lua", luaMain ["this is not lua"])
  ]

-- | X and Y ask for two modules. X takes the first, cancels the second on the session's first word, and on its second
-- asks for a broken module it cancels at once and for the cached one again; Y only asks.
waiters ∷ ByteString
waiters =
  luaMain
    [ "local share = import('lua/share.lua')"
    , "local function init(self, api) share.n = share.n + 1; self.me = share.n; self.keep = api end"
    , "local function update(self, dt)"
    , "  local api = self.keep"
    , "  local status = api.session.status()"
    , "  if not self.asked then"
    , "    self.asked = true"
    , "    self.m = api.content.module('lua/m.lua')"
    , "    self.n = api.content.module('lua/n.lua')"
    , "    print((self.me == 1 and 'X' or 'Y') .. ' asked')"
    , "    return"
    , "  end"
    , "  if self.me == 2 then return end"
    , "  if self.m and api.request.ready(self.m) then"
    , "    print('X m ' .. api.request.take(self.m).status)"
    , "    self.m = nil"
    , "  end"
    , "  if status.stopping and not self.cancelled then"
    , "    self.cancelled = true"
    , "    api.request.cancel(self.n)"
    , "    print('X cancel_n ' .. api.request.take(self.n).status)"
    , "  end"
    , "  if status.gameplay ~= nil and self.cancelled and not self.third then"
    , "    self.third = true"
    , "    local bad = api.content.module('lua/bad.lua')"
    , "    api.request.cancel(bad)"
    , "    print('X bad_cancel ' .. api.request.take(bad).status)"
    , "    self.again = api.content.module('lua/n.lua')"
    , "  end"
    , "  if self.again and api.request.ready(self.again) then"
    , "    print('X again ' .. api.request.take(self.again).status)"
    , "    self.again = nil"
    , "  end"
    , "end"
    , "return {gameplay = {every_ticks = 1, init = init, update = update}, presentation = {every_seconds = 1, init = init, update = update}}"
    ]

-- | The VM stops with a waiter and a read borrowed from the pool.
vmStopSpec ∷ Spec
vmStopSpec =
  it "stops a VM closed to evaluation while a module read is borrowed: the owner ends, the borrowed read returns to the pool and the module is never evaluated" $
    withWorld fixedM1Profile (Layout (("lua/main.lua", waiters) : waiterFiles)) $ \world control runtime → do
      let probe = ssProbe (wSession world)
      closeGate probe "lua/m.lua"
      withFvm world runtime presentationShape $ \ui → do
        x ← spawn world ui "modules-test" mainPath
        dumpOnFailure world [x] $ do
          awaitLine world "X asked"
          awaitStartedPath probe "lua/m.lua"
          retireScheduled (fvOwner ui)
          _ ← awaitEnded control ui
          finishedPaths probe >>= \finished → ("lua/m.lua" `elem` finished) `shouldBe` False
          openGate probe "lua/m.lua"
      -- the scope is left: the borrowed read returned to the pool, and nothing evaluated the module. (That a session
      -- retires a role only after its coordinator has drained is the session's, in the session examples.)
      awaitFinishedPath probe "lua/m.lua"
      errLines world >>= \err → length [line | line ← err, "eval m" `Text.isSuffixOf` line] `shouldBe` 0
