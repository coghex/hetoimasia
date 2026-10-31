{-# LANGUAGE OverloadedStrings #-}

-- | LFE-23, M1 integrated capacity, one-shot results and cancellation across the composed services: a real UI VM, the
-- real data service and request reservations over the real two-worker read pool, with the pool's reader held at gates
-- the example opens.
--
-- __Injected__: the clock and timer, the sinks, the gates around the reader, and the session endpoints. The pool is
-- the compact boundary this example injects (two workers, twelve slots, of which the VM's coordinator holds four), so
-- eight data reads can be held; the fixed profile's 16 places per instance are not reachable before the pool is full
-- and are not faked here.
module Test.LuaEngine.Integrated.Capacity (spec) where

import Control.Concurrent (yield)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import qualified Data.Text as Text
import Test.Support.Bounded (bounded)
import Control.Monad (void)
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.Scripting.Lua.Instance (InstanceOutcome (InstanceStopped), InstanceSettlement (resultOutcome))
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Integrated.Support
import Hetoimasia.Content.ReadPool (PoolStatus (statusActive))
import Test.LuaEngine.Modules.Support (Probe, awaitPool, closeGate, finishedPaths, openGate, startedPaths)

spec ∷ Spec
spec = describe "M1 integrated capacity, one-shot results and cancellation" $ do
  creditSpec
  endSpec

-- | Reads the pool can hold for the data service in this harness: twelve slots less the coordinator's four.
reachable ∷ Int
reachable = 8

creditSpec ∷ Spec
creditSpec =
  it "answers busy atomically with nothing reserved, frees a place only at the actual boundary of the work (a started read, not its cancellation), and lets only Lua's later explicit request use it" $
    withWorld fixedM1Profile (Layout (("lua/main.lua", credit) : [("slow.bin", "ss"), ("done.bin", "dd")])) $ \world _ runtime →
      withFvm world runtime presentationShape $ \ui → do
        let probe = ssProbe (wSession world)
        closeGate probe "slow.bin"
        x ← spawn world ui "modules-test" mainPath
        dumpOnFailure world [x] $ do
          awaitLine world ("filled " <> Text.pack (show reachable) <> " busy")
          awaitStartedPath probe "slow.bin"
          -- both workers hold a read: the two oldest requests (the pool serves its one queue in admission order), so that the
          -- request cancelled below is one a worker holds
          awaitPool (wSession world) (\found → statusActive found >= 2)
          -- the refused ask took nothing: no handle came back and no read of the refused file started
          startedPaths probe >>= \started → length (filter (== "done.bin") started) `shouldBe` 0
          -- cancelling a read that a worker holds does not give its place back: the next ask is still busy
          setStatus world (StatusSample True Nothing Nothing)
          awaitLine world "cancel_started cancelled"
          awaitLine world "cancel_taken cancelled"
          awaitLine world "retry_after_cancel busy"
          -- only when the held read has returned (its actual boundary) is the place free, and nobody asked for it meanwhile
          openGate probe "slow.bin"
          awaitFinishedPath probe "slow.bin"
          awaitLine world "retry_after_drain accepted"
          awaitLine world "take_once refused"
          out <- outLines world
          -- one terminal settlement, one take: the result is taken once, and a second take is an ordinary error
          named "take_once" out `shouldBe` ["success", "refused"]
        stopSpawned x
        mapM_ settledOf [x]
  where
    credit =
      luaMain
        [ "local function init(self, api) self.keep = api; self.reqs = {} end"
        , "local function update(self, dt)"
        , "  local api = self.keep"
        , "  local status = api.session.status()"
        , "  if not self.filled then"
        , "    self.filled = true"
        , "    local busy"
        , "    for i = 1, 40 do"
        , "      local r, e = api.content.data('slow.bin')"
        , "      if r == nil then busy = e.code break end"
        , "      self.reqs[#self.reqs + 1] = r"
        , "    end"
        , "    print('filled ' .. #self.reqs .. ' ' .. tostring(busy))"
        , "    local again, e = api.content.data('done.bin')"
        , "    print('refused ' .. tostring(again) .. ' ' .. tostring(e and e.code))"
        , "  elseif status.stopping and not self.cancelled then"
        , "    self.cancelled = true"
        , "    print('cancel_started ' .. api.request.cancel(self.reqs[1]))"
        , "    print('cancel_taken ' .. api.request.take(self.reqs[1]).status)"
        , "    local r, e = api.content.data('done.bin')"
        , "    print('retry_after_cancel ' .. (r == nil and e.code or 'accepted'))"
        , "  elseif self.cancelled and not self.drained then"
        , "    local r, e = api.content.data('done.bin')"
        , "    if r ~= nil then"
        , "      self.drained = true"
        , "      print('retry_after_drain accepted')"
        , "      while not api.request.ready(r) do api.time.yield() end"
        , "      print('take_once ' .. api.request.take(r).status)"
        , "      print('take_once ' .. (pcall(api.request.take, r) and 'success' or 'refused'))"
        , "    end"
        , "  end"
        , "end"
        , "return {gameplay = {every_ticks = 1, init = init, update = update}, presentation = {every_seconds = 1, init = init, update = update}}"
        ]

-- | An instance ends holding unconsumed successes and dropped handles; the room it held comes back exactly once.
endSpec ∷ Spec
endSpec =
  it "returns an ended instance's room exactly once, for results it never took and handles it dropped, so that the next instance can fill the same room and no more" $
    withWorld fixedM1Profile (Layout (("lua/main.lua", fillingAll) : [("slow.bin", "ss")])) $ \world _ runtime →
      withFvm world runtime presentationShape $ \ui → do
        x ← spawn world ui "modules-test" mainPath
        dumpOnFailure world [x] $ do
          awaitLine world ("filled inst-1 " <> Text.pack (show reachable) <> " busy")
          -- every one of the eight reads has finished: the results sit unconsumed, and their places are still taken
          awaitFinishedCount (ssProbe (wSession world)) "slow.bin" reachable
          stopSpawned x
          settlement ← settledOf x
          resultOutcome settlement `shouldSatisfy` isStopped
        -- the same room is available again, to the next instance, and not a place more (no double return)
        y ← spawn world ui "modules-test" mainPath
        dumpOnFailure world [y] $ do
          awaitLine world ("filled inst-2 " <> Text.pack (show reachable) <> " busy")
          stopSpawned y
          void (settledOf y)
  where
    isStopped = \case
      InstanceStopped → True
      _ → False
    -- every instance asks for the file until busy and drops the handles at once: nothing is taken, nothing cancelled
    fillingAll =
      luaMain
        [ "local function init(self, api) self.keep = api end"
        , "local function update(self, dt)"
        , "  local api = self.keep"
        , "  if self.filled then return end"
        , "  self.filled = true"
        , "  local n, busy = 0, nil"
        , "  for i = 1, 40 do"
        , "    local r, e = api.content.data('slow.bin')"
        , "    if r == nil then busy = e.code break end"
        , "    n = n + 1"
        , "  end"
        , "  print('filled ' .. api.instance_id .. ' ' .. n .. ' ' .. tostring(busy))"
        , "end"
        , "return {gameplay = {every_ticks = 1, init = init, update = update}, presentation = {every_seconds = 1, init = init, update = update}}"
        ]

-- | Wait until the pool's reader has finished at least this many reads of this path.
awaitFinishedCount ∷ Probe → ByteString → Int → IO ()
awaitFinishedCount probe path wanted = bounded loop
  where
    loop = finishedPaths probe >>= \found → unless (length (filter (== path) found) >= wanted) (yield >> loop)
