{-# LANGUAGE OverloadedStrings #-}

-- | A model test of the terrain lifecycle: bounded random sequences of two VMs' operations (both roles) on small service limits, with the
-- service's use checked at every quiescent point against what the live handles account for.
--
-- The two VMs are a presentation VM, whose instance opens the arena, and a gameplay VM (logical time), whose instance attaches to it.
-- Each instance is a scripted one: it runs the commands the example queues for it (start a read, take the oldest, cancel it, release its
-- arena handle, idle), and says each one's outcome, so the example knows which handles are live. Between commands the example also
-- changes an owner's epoch, and ends and replaces the gameplay instance. Nothing sleeps: the clocks and ticks are driven, and every wait is
-- for a line the instances print.
--
-- After every operation, once the service has had time to settle (every request has been served and every owner has passed its boundaries):
--
-- * the service holds no more requests, command slots and retained results than the reads the live handles can still take (nothing is
--   charged for work that has ended and been taken or discarded); and
-- * when every handle has been taken or discarded, released and ended, the service's requests, command slots, leases, arenas and clients
--   are exactly zero, and a read of a fresh instance is accepted: nothing a VM left behind keeps another from the capacity.
module Test.LuaEngine.Terrain.Model (spec) where

import Control.Concurrent.STM (atomically)
import Control.Monad (forM_, replicateM_, void, when)
import Data.Bits (shiftR, (.&.))
import Data.List (find)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Text as Text
import Data.Text (Text)
import qualified Hetoimasia.Scripting.Lua.Instance as Instance
import Hetoimasia.Scripting.Lua.Provider (advanceRequestEpoch)
import Hetoimasia.Scripting.Lua.Scheduled (scheduledEndpoint)
import Hetoimasia.LuaEngine.Profile (CountLimit (RequestsPerInstance, RequestsPerVm))
import Hetoimasia.Terrain.Runtime (Config (..), censusRequests, defaultConfig, inspectCensusSTM)
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Request.Profiles (counts)
import Test.LuaEngine.Terrain.Support

-- | A scripted instance: it runs the commands queued for its label.
scripted ∷ Text → Script
scripted label =
  script
    { scPrelude = terrainPrelude <> ["local ME = '" <> label <> "'"]
    , scInit = ["self.reqs = {}"]
    , scUpdate =
        [ "local function ack(n, what) print('ack', n, what) end"
        , "if self.opening then"
        , "  local t = settle(api, self.opening)"
        , "  if t then"
        , "    self.opening = nil"
        , "    if t.status == 'success' then self.arena = t.value end"
        , "    print('opened', ME, t.status)"
        , "  end"
        , "end"
        , "local c = TEST_CMD(ME)"
        , "while c ~= 'none' do"
        , "  local n, cmd = c:match('^(%d+) (.*)$')"
        , "  if cmd == 'open' then self.opening = api.terrain.open('m', DEF) ack(n, 'open')"
        , "  elseif cmd == 'attach' then self.opening = api.terrain.attach('m') ack(n, 'attach')"
        , "  elseif cmd == 'read' then"
        , "    if self.arena then"
        , "      local r, e = api.terrain.cell(self.arena, {x = 0, y = 0, z = 0})"
        , "      if r then self.reqs[#self.reqs + 1] = r ack(n, 'read ok') else ack(n, 'read ' .. e.code) end"
        , "    else ack(n, 'read noarena') end"
        , "  elseif cmd == 'take' then"
        , "    local r = self.reqs[1]"
        , "    if r and api.request.ready(r) then"
        , "      local t = api.request.take(r)"
        , "      table.remove(self.reqs, 1)"
        , "      ack(n, 'take ' .. t.status)"
        , "    else ack(n, r and 'take pending' or 'take none') end"
        , "  elseif cmd == 'cancel' then"
        , "    local r = self.reqs[1]"
        , "    if r then ack(n, 'cancel ' .. tostring(api.request.cancel(r))) else ack(n, 'cancel none') end"
        , "  elseif cmd == 'readtake' then"
        , "    -- started, seen complete and taken within one invocation, before the owner's next boundary can account its work"
        , "    local r, e = api.terrain.cell(self.arena, {x = 0, y = 0, z = 0})"
        , "    if r then TEST_AWAIT_SETTLED() ack(n, 'readtake ' .. api.request.take(r).status) else ack(n, 'readtake ' .. e.code) end"
        , "  elseif cmd == 'forget' then self.reqs = {} ack(n, 'forget')"
        , "  elseif cmd == 'release' then"
        , "    if self.arena then ack(n, 'release ' .. tostring(api.terrain.release(self.arena))) self.arena = nil else ack(n, 'release none') end"
        , "  else ack(n, 'idle') end"
        , "  c = TEST_CMD(ME)"
        , "end"
        ]
    }

-- | What the model knows of one VM: whether its instance holds the arena handle, and how many reads it started and has not taken.
data Side = Side {sdHandle ∷ IORef Bool, sdReads ∷ IORef Int}

-- | A deterministic stream of numbers from a seed.
next ∷ Int → Int
next x = (x * 1103515245 + 12345) .&. 0x7fffffff

spec ∷ Spec
spec = describe "Terrain lifecycle model" $
  forM_ [1 .. 8 ∷ Int] $ \seed →
    it ("keeps the service's use equal to what the live handles account for, over a bounded random sequence of two VMs' operations (seed " <> show seed <> ")") $
      withRigConfig defaultConfig {configMaxClients = 8, configMaxLeases = 6, configMaxArenas = 2} $ \rig →
        withWorld (counts [(RequestsPerInstance, 3), (RequestsPerVm, 5)]) (Layout [("lua/p.lua", scriptSource (scripted "p")), ("lua/g.lua", scriptSource (scripted "g"))]) $ \world control runtime →
          withFvm world runtime (presentationOver rig) $ \pv →
            withFvm world runtime (gameplayOver rig) $ \gv → do
              serial ← newIORef (0 ∷ Int)
              tally ← newIORef ([] ∷ [Text])
              gSpawnRef ← newIORef (Nothing ∷ Maybe Spawned)
              clientBaseline ← newIORef (-1 ∷ Integer)
              p ← Side <$> newIORef False <*> newIORef 0
              g ← Side <$> newIORef False <*> newIORef 0
              let advance = tickBy control gv 1 >> advanceClock world 2000000000
                  settleAll = replicateM_ 6 (advance >> yield')
                  yield' = pure ()
                  -- Queue a command for a label, and wait for the instance's answer to it.
                  command label text = do
                    n ← atomicModifyIORef'' serial
                    modifyIORef' tally (Text.takeWhile (/= ' ') text :)
                    sendCommand rig label (Text.pack (show n) <> " " <> text)
                    let wanted = "ack\t" <> Text.pack (show n) <> "\t"
                    pumpUntil world (advance >> any (Text.isPrefixOf wanted) <$> outLines world)
                    printed ← outLines world
                    pure (maybe "" (Text.drop (Text.length wanted)) (find (Text.isPrefixOf wanted) printed))
                  sideOf label = if label == "p" then p else g
                  tallyNote kind = modifyIORef' tally (kind :)
                  census = length . censusRequests <$> atomically (inspectCensusSTM (rgService rig))
                  accounted = (+) <$> readIORef (sdReads p) <*> readIORef (sdReads g)
                  -- The service holds no more than the reads that can still be taken.
                  check what = do
                    settleAll
                    held ← census
                    bound ← accounted
                    slots ← limitHeld (rgService rig) "command slots"
                    leases ← limitHeld (rgService rig) "leases"
                    clients ← limitHeld (rgService rig) "clients"
                    clientsAtStart ← readIORef clientBaseline
                    handles ← (\a b → length (filter id [a, b])) <$> readIORef (sdHandle p) <*> readIORef (sdHandle g)
                    (what, held <= bound, slots <= toInteger bound, leases <= toInteger handles, (clientsAtStart < 0 || clients == clientsAtStart), (held, bound, slots, leases, handles, clients)) `shouldSatisfy` (\(_, a, b, c, d, _) → a && b && c && d)
                  -- One operation on a side.
                  operation label choice = do
                    let side = sideOf label
                    started ← readIORef (sdReads side)
                    handle ← readIORef (sdHandle side)
                    case choice of
                      0 | handle && started < 3 → do
                            outcome ← command label "read"
                            when (outcome == "read ok") (modifyIORef' (sdReads side) (+ 1))
                      1 | started > 0 → do
                            outcome ← command label "take"
                            when (Text.isPrefixOf "take " outcome && outcome /= "take pending" && outcome /= "take none") (modifyIORef' (sdReads side) (subtract 1))
                      2 | handle → do
                        -- a cancel needs a read to cancel: start one when there is none
                        when (started == 0) $ do
                          outcome ← command label "read"
                          when (outcome == "read ok") (modifyIORef' (sdReads side) (+ 1))
                        now ← readIORef (sdReads side)
                        when (now > 0) (void (command label "cancel"))
                      3 → void (command label "idle")
                      5 | handle && label == "p" → do
                        -- only when nothing else is pending anywhere: the wait is for every request the service holds to be settled
                        others ← accounted
                        when (others == 0) (void (command label "readtake"))
                      4 → do
                        void (advanceRequestEpoch (scheduledEndpoint (fvOwner (if label == "p" then pv else gv))))
                        void (command label "forget")
                        writeIORef (sdReads side) 0
                      6 | label == "g" && handle → do
                        -- the gameplay instance ends and is replaced: everything it held goes with it, and the new instance attaches again
                        Just old ← readIORef gSpawnRef
                        stopSpawned old
                        pumpUntil world (advance >> ((== Just Instance.Stopped) <$> phaseOf old))
                        forgetInstance (fvFacade gv) (spId old)
                        writeIORef (sdHandle g) False
                        writeIORef (sdReads g) 0
                        tallyNote "endinstance"
                        -- the gameplay instance's two clients (its owner's and its attach's) went with it, and only those
                        baseline ← readIORef clientBaseline
                        writeIORef clientBaseline (baseline - 2)
                        check "g after its instance ended"
                        writeIORef clientBaseline baseline
                        fresh ← spawn world gv "modules-test" "lua/g.lua"
                        writeIORef gSpawnRef (Just fresh)
                        opened ← length . filter (== "opened\tg\tsuccess") <$> outLines world
                        void (command "g" "attach")
                        pumpUntil world (advance >> ((> opened) . length . filter (== "opened\tg\tsuccess") <$> outLines world))
                        writeIORef (sdHandle g) True
                      _ → void (command label "idle")
                    check (label <> " op " <> Text.pack (show choice))
              -- p opens the arena and g attaches to it
              pSpawn ← spawn world pv "modules-test" "lua/p.lua"
              gSpawn0 ← spawn world gv "modules-test" "lua/g.lua"
              writeIORef gSpawnRef (Just gSpawn0)
              -- (on odd seeds g attaches while the open is still pending: the answer is not_found, the service's lease for that attach is
              -- let go at once, and g attaches again once the arena is published)
              void (command "p" "open")
              when (odd seed) (void (command "g" "attach"))
              pumpUntil world (advance >> elem "opened\tp\tsuccess" <$> outLines world)
              writeIORef (sdHandle p) True
              early ← length . filter (Text.isPrefixOf "opened\tg\t") <$> outLines world
              firstSuccess ← elem "opened\tg\tsuccess" <$> outLines world
              writeIORef (sdHandle g) firstSuccess
              when (early > 0) (check "after an attach before the open was published")
              when (not firstSuccess) $ do
                void (command "g" "attach")
                pumpUntil world (advance >> elem "opened\tg\tsuccess" <$> outLines world)
                writeIORef (sdHandle g) True
              -- the instances' clients are what they are while the instances live: nothing a sequence does adds or ends one
              limitHeld (rgService rig) "clients" >>= writeIORef clientBaseline
              -- a bounded random sequence of operations over both VMs
              seedRef ← newIORef seed
              -- (the first eight operations cover every kind once, in an order the seed shifts; the rest are drawn)
              forM_ [0 .. 15 ∷ Int] $ \step → do
                modifyIORef' seedRef next
                a ← readIORef seedRef
                modifyIORef' seedRef next
                b ← readIORef seedRef
                let kind = if step < 8 then (step + seed) `mod` 8 else (b `shiftR` 8) `mod` 8
                    label = if kind == 5 || (a `shiftR` 8) `mod` 2 == 0 then "p" else "g"
                operation label kind
              -- the other VM can always make progress: with every outstanding read taken, each VM starts and takes a fresh one
              forM_ (["p", "g"] ∷ [Text]) $ \label → do
                started ← readIORef (sdReads (sideOf label))
                replicateM_ (started + 1) (command label "take" >> settleAll)
                writeIORef (sdReads (sideOf label)) 0
              forM_ (["g", "p"] ∷ [Text]) $ \label → do
                outcome ← command label "read"
                (label, outcome) `shouldBe` (label, "read ok")
                void (command label "take")
                settleAll
                void (command label "take")
              settleAll
              -- every handle taken or discarded, released and ended: nothing is left charged
              forM_ ["p", "g"] $ \label → do
                started ← readIORef (sdReads (sideOf label))
                replicateM_ (started + 1) (command label "take" >> settleAll)
                writeIORef (sdReads (sideOf label)) 0
              void (command "g" "release")
              void (command "p" "release")
              settleAll
              held ← census
              (held, ()) `shouldBe` (0, ())
              forM_ ["command slots", "leases", "arenas"] $ \name → (name, ) <$> limitHeld (rgService rig) name >>= \(n, v) → (n, v) `shouldBe` (n, 0)
              stopSpawned pSpawn
              Just gSpawn ← readIORef gSpawnRef
              stopSpawned gSpawn
              pumpUntil world (advance >> ((== Just Instance.Stopped) <$> phaseOf pSpawn))
              pumpUntil world (advance >> ((== Just Instance.Stopped) <$> phaseOf gSpawn))
              settleAll
              -- the facade forgets an ended instance (the session does so in the host), and its clients go with it
              forgetInstance (fvFacade pv) (spId pSpawn)
              forgetInstance (fvFacade gv) (spId gSpawn)
              limitHeld (rgService rig) "clients" `shouldReturn` 0
              sent ← readIORef tally
              putStrLn ("model seed " <> show seed <> ": " <> show (length sent) <> " commands, " <> show [(k, length (filter (== k) sent)) | k ← ["read", "readtake", "take", "cancel", "forget", "idle", "attach", "open", "release", "endinstance"]])
  where
    atomicModifyIORef'' ref = do
      n ← readIORef ref
      writeIORef ref (n + 1)
      pure (n + 1)
