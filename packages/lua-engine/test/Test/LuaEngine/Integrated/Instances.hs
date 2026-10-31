{-# LANGUAGE OverloadedStrings #-}

-- | LFE-23, M1 integrated ownership (instances): two ordinary presentation instances A and B of one content root in one
-- real UI VM and an independent logical owner in its own VM, composed through the construction/attribution path the
-- session's launcher uses ('declareInstance' and 'admitBehaviorInstance' over the real facade, coordinator, data
-- service, read pool and scheduled owners).
--
-- __Real__: Lua VMs and their filters, instance construction, module environments and cache, the content root,
-- inventory and verified read pool, the data service, request reservations, the facade and the coordinator.
--
-- __Injected__: the monotonic clock and the timer (a scripted clock and a fake timer a test moves by hand), the
-- recording output sinks, the admission state, the session's status/quit/terminal endpoints, and the gate the read
-- pool's reader sits behind. Nothing here asks the implementation for its own expected answer: every expectation is
-- written from the contract (P-40 part 4, P-72, D-48/D-52/D-58) and the Lua each example authored.
--
-- Nothing sleeps; the example learns what happened from the authored output, from a gate it holds or from STM.
module Test.LuaEngine.Integrated.Instances (spec) where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import qualified Data.Text as Text
import qualified Data.ByteString.Char8 as Char8
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.Scripting.Lua.Instance (InstanceOutcome (InstanceStopped), InstancePhase (Active, Stopping), InstanceSettlement (resultOutcome))
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Integrated.Support
import Test.LuaEngine.Modules.Support (closeGate, openGate, startedPaths)

files ∷ [(FilePath, ByteString)]
files =
  [ ("lua/share.lua", shareModule)
  , ("lua/dep.lua", luaMain ["return {id = 'dep'}"])
  , ("slow.bin", "zz")
  , ("data.bin", "xx")
  , ("foreign.bin", "yy")
  ]

spec ∷ Spec
spec = describe "M1 integrated ownership: instances of one VM and an independent role" $ do
  identitySpec
  orderSpec
  endingSpec

-- | Two presentation instances, A and B, and one logical instance L.
identitySpec ∷ Spec
identitySpec =
  it "gives two UI instances and a logical owner separate self and capabilities, shares exports only inside the UI VM, and lets no instance act through another's facade or request handle" $
    withWorld fixedM1Profile (Layout (("lua/main.lua", twins) : files)) $ \world control runtime →
      withFvm world runtime gameplayShape $ \logical → withFvm world runtime presentationShape $ \ui → do
        a ← spawn world ui "modules-test" mainPath
        b ← spawn world ui "modules-test" mainPath
        l ← spawn world logical "modules-test" mainPath
        dumpOnFailure world [a, b, l] $ do
          -- the logical owner runs one tick; the UI instances run once their cadence is due
          tickBy control logical 2
          awaitLine world "done settled"
          out ← outLines world
          -- distinct identities, one content id, correct roles
          let ids = [spId a, spId b, spId l]
          ids `shouldBe` ["inst-1", "inst-2", "inst-3"]
          named "init" out `shouldMatchList` ["presentation inst-1 modules-test me=1", "presentation inst-2 modules-test me=2", "gameplay inst-3 modules-test me=1"]
          -- the UI instances share one export table and its mutable state; the logical VM has its own
          named "sees" out `shouldMatchList` ["presentation inst-1 mark=by inst-1", "presentation inst-2 mark=by inst-1", "gameplay inst-3 mark=by inst-3"]
          named "same_export" out `shouldBe` ["true"]
          named "distinct" out `shouldBe` ["api=false self=false data=false"]
          -- separate evaluations: one per VM, never one per instance
          err ← errLines world
          length (filter ("share evaluated" `Text.isSuffixOf`) err) `shouldBe` 2
          length (filter (\line → "role=presentation" `Text.isInfixOf` line && "share evaluated" `Text.isSuffixOf` line) err) `shouldBe` 1
          length (filter (\line → "role=gameplay" `Text.isInfixOf` line && "share evaluated" `Text.isSuffixOf` line) err) `shouldBe` 1
          -- B's use of A's facade and handle is refused as an ordinary error and acts on nothing
          forM_ ["foreign facade data", "foreign facade module", "foreign ready", "foreign take", "foreign cancel"] $ \label →
            named label out `shouldSatisfy` (\found → length found == 1 && all ("=> false ; " `Text.isPrefixOf`) found)
          named "foreign facade data" out `shouldSatisfy` all ("this facade belongs to another instance" `Text.isInfixOf`)
          named "foreign facade module" out `shouldSatisfy` all ("this facade belongs to another instance" `Text.isInfixOf`)
          started ← startedPaths (ssProbe (wSession world))
          filter (== Char8.pack "foreign.bin") started `shouldBe` []
          -- A's own request was untouched by the peer's attempts to take or cancel it
          -- (the peer's edit did reach the table the script holds, so the check below is not vacuous)
          named "own_take" out `shouldBe` ["inst-1 success table_id=inst-99"]
          -- a peer that rewrote A's saved facade and A's own self cannot change A's attribution or authority
          named "mutate_attempt" out `shouldSatisfy` ((== 1) . length)
          err' ← errLines world
          [line | line ← err', "after the peer's edits" `Text.isInfixOf` line] `shouldBe` ["lua warning role=presentation content=modules-test instance=inst-1: after the peer's edits"]
          named "own_after" out `shouldBe` ["inst-1 accepted"]
          stopSpawned a >> stopSpawned b >> stopSpawned l
          mapM_ settledOf [a, b, l]
  where
    twins =
      luaMain $
        tryPrelude
          <> [ "local share = import('lua/share.lua')"
             , "local function init(self, api)"
             , "  share.n = share.n + 1"
             , "  self.me = share.n"
             , "  self.share = share"
             , "  self.keep = api"
             , "  self.id = api.instance_id"
             , "  share.apis[self.me] = api"
             , "  share.selves[self.me] = self"
             , "  share.data[self.me] = api.content.data('data.bin')"
             , "  if self.me == 1 then share.mark = 'by ' .. api.instance_id end"
             , "  print('init ' .. api.role .. ' ' .. api.instance_id .. ' ' .. api.content_id .. ' me=' .. self.me)"
             , "  print('sees ' .. api.role .. ' ' .. api.instance_id .. ' mark=' .. tostring(share.mark))"
             , "end"
             , "local function ui_update(self, dt)"
             , "  local api = self.keep"
             , "  if self.me == 2 and not self.done then"
             , "    self.done = true"
             , "    local first = share.apis[1]"
             , "    print('same_export ' .. tostring(rawequal(self.share, share.selves[1].share)))"
             , "    print('distinct api=' .. tostring(rawequal(first, api)) .. ' self=' .. tostring(rawequal(share.selves[1], self)) .. ' data=' .. tostring(rawequal(share.data[1], share.data[2])))"
             , "    try('foreign facade data', function() return first.content.data('foreign.bin') end)"
             , "    try('foreign facade module', function() return first.content.module('lua/main.lua') end)"
             , "    try('foreign ready', function() return api.request.ready(share.data[1]) end)"
             , "    try('foreign take', function() return api.request.take(share.data[1]) end)"
             , "    try('foreign cancel', function() return api.request.cancel(share.data[1]) end)"
             , "    print('mutate_attempt ' .. tostring((pcall(function() first.role = 'gameplay'; first.instance_id = 'inst-99'; share.selves[1].api = nil end))))"
             , "    share.attempted = true"
             , "  end"
             , "  if self.me == 1 and share.attempted and not self.took then"
             , "    if api.request.ready(share.data[1]) then"
             , "      self.took = true"
             , "      print('own_take ' .. self.id .. ' ' .. api.request.take(share.data[1]).status .. ' table_id=' .. api.instance_id)"
             , "      warn(\"after the peer's edits\")"
             , "      print('own_after ' .. self.id .. ' ' .. tostring(api.content.data('data.bin') ~= nil and 'accepted' or 'refused'))"
             , "      print('done settled')"
             , "    end"
             , "  end"
             , "end"
             , "local function logic_update(self, dt)"
             , "  local api = self.keep"
             , "  if not self.done and api.request.ready(share.data[self.me]) then self.done = true end"
             , "end"
             , "return {"
             , "  gameplay = {every_ticks = 1, init = init, update = logic_update},"
             , "  presentation = {every_seconds = 1, init = init, update = ui_update}"
             , "}"
             ]

-- | One entry for the ordering and ending examples: every instance records its place, and the hooks the example
-- drives are chosen by the instance's number.
orderSpec ∷ Spec
orderSpec = do
  it "serves two ready UI instances of one VM first-in first-out, puts a yielding segment behind the peer already ready, and never interleaves a segment that does not yield" $
    withWorld fixedM1Profile (Layout (("lua/main.lua", ordering) : files)) $ \world _ runtime →
      withFvm world runtime presentationShape $ \ui → do
        a ← spawn world ui "modules-test" mainPath
        b ← spawn world ui "modules-test" mainPath
        dumpOnFailure world [a, b] $ do
          -- both instances' first update fall due at the same injected moment; A was admitted first
          advanceClock world 1000000000
          awaitLine world "step A post"
          out ← outLines world
          -- A runs first up to its yield, B's whole non-yielding segment follows uninterrupted, then A resumes
          named "step" out `shouldBe` ["A pre", "B 1", "B 2", "B 3", "A post"]
        stopSpawned a >> stopSpawned b
        mapM_ settledOf [a, b]
  where
    ordering =
      luaMain
        [ "local share = import('lua/share.lua')"
        , "local function init(self, api) share.n = share.n + 1; self.me = share.n; self.keep = api end"
        , "local function update(self, dt)"
        , "  local api = self.keep"
        , "  if self.ran then return end"
        , "  self.ran = true"
        , "  if self.me == 1 then"
        , "    print('step A pre')"
        , "    api.time.yield()"
        , "    print('step A post')"
        , "  else"
        , "    print('step B 1'); print('step B 2'); print('step B 3')"
        , "  end"
        , "end"
        , "return {gameplay = {every_ticks = 1, init = init, update = update}, presentation = {every_seconds = 1, init = init, update = update}}"
        ]

-- | A ends while its read is in flight; B, its peer, goes on.
endingSpec ∷ Spec
endingSpec =
  it "ends one UI instance with a read in flight: the peer keeps the shared VM and its cached definitions, the ended instance's facade and handles act on nothing, and its read drains without delivery" $
    withWorld fixedM1Profile (Layout (("lua/main.lua", ending) : files)) $ \world _ runtime →
      withFvm world runtime presentationShape $ \ui → do
        let probe = ssProbe (wSession world)
        closeGate probe "slow.bin"
        a ← spawn world ui "modules-test" mainPath
        b ← spawn world ui "modules-test" mainPath
        dumpOnFailure world [a, b] $ do
          -- A took the shared module's export and has a read of slow.bin in flight, held at the pool's reader
          awaitLine world "a took_dep"
          awaitStartedPath probe "slow.bin"
          startedBefore ← startedPaths probe
          -- A ends through Haskell while its read is held at the pool: it retires only when the read it has borrowed has
          -- actually returned, so it stays stopping, and B is untouched
          stopSpawned a
          awaitPhaseOf a Stopping
          phaseOf b >>= (`shouldBe` Just Active)
          -- the survivor is told, as the session would, that the first instance is going, and goes on meanwhile
          setStatus world (StatusSample True Nothing Nothing)
          awaitLine world "b done"
          phaseOf a >>= (`shouldBe` Just Stopping)
          -- the held read is let go: it finishes in the pool (an engine-owned job), A settles stopped and delivers nothing
          openGate probe "slow.bin"
          awaitFinishedPath probe "slow.bin"
          settlement ← settledOf a
          resultOutcome settlement `shouldSatisfy` isStopped
          out ← outLines world
          -- B asked for the module A had already loaded: the VM's cached export, the same table
          named "b dep_same" out `shouldBe` ["true"]
          -- A's handle and facade, kept in the shared export, act on nothing
          named "b foreign_handle" out `shouldSatisfy` (\found → length found == 1 && all ("=> false ; " `Text.isPrefixOf`) found)
          named "b foreign_facade" out `shouldSatisfy` (\found → length found == 1 && all ("=> false ; " `Text.isPrefixOf`) found)
          -- B's own request succeeded after the peer ended, and the peer's calls started no read of their own
          named "b own_data" out `shouldBe` ["success"]
          started ← startedPaths probe
          length (filter (== "foreign.bin") started) `shouldBe` 0
          length (filter (== "slow.bin") started) `shouldBe` length (filter (== "slow.bin") startedBefore)
          -- no output attributed to A after its settlement, and B is still serving
          phaseOf b >>= (`shouldBe` Just Active)
        stopSpawned b
        _ ← settledOf b
        pure ()
  where
    isStopped = \case
      InstanceStopped → True
      _ → False
    ending =
      luaMain $
        tryPrelude
          <> [ "local share = import('lua/share.lua')"
             , "local function init(self, api)"
             , "  share.n = share.n + 1"
             , "  self.me = share.n"
             , "  self.keep = api"
             , "  share.apis[self.me] = api"
             , "  if self.me == 1 then"
             , "    self.dep = api.content.module('lua/dep.lua')"
             , "    self.slow = api.content.data('slow.bin')"
             , "    share.data[1] = self.slow"
             , "  end"
             , "end"
             , "local function update(self, dt)"
             , "  local api = self.keep"
             , "  if self.me == 1 then"
             , "    if self.dep and api.request.ready(self.dep) then"
             , "      share.dep = api.request.take(self.dep).value"
             , "      self.dep = nil"
             , "      print('a took_dep')"
             , "    end"
             , "    return"
             , "  end"
             , "  if not api.session.status().stopping then return end"
             , "  if not self.asked then"
             , "    self.asked = true"
             , "    self.again = api.content.module('lua/dep.lua')"
             , "    self.own = api.content.data('data.bin')"
             , "    try('b foreign_handle', function() return api.request.ready(share.data[1]) end)"
             , "    try('b foreign_facade', function() return share.apis[1].content.data('foreign.bin') end)"
             , "    return"
             , "  end"
             , "  if self.again and api.request.ready(self.again) then"
             , "    print('b dep_same ' .. tostring(rawequal(api.request.take(self.again).value, share.dep)))"
             , "    self.again = nil"
             , "  end"
             , "  if self.own and api.request.ready(self.own) then"
             , "    print('b own_data ' .. api.request.take(self.own).status)"
             , "    self.own = nil"
             , "  end"
             , "  -- done only once both of B's requests have been taken, whichever settled first"
             , "  if self.asked and not self.again and not self.own and not self.fin then"
             , "    self.fin = true"
             , "    print('b done')"
             , "  end"
             , "end"
             , "return {gameplay = {every_ticks = 1, init = init, update = update}, presentation = {every_seconds = 1, init = init, update = update}}"
             ]
