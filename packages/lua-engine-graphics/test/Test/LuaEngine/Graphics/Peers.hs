{-# LANGUAGE OverloadedStrings #-}

-- | Two presentation instances of one VM, through the /production/ graphics injection ('graphicsInjection') over the
-- real texture pipeline, window provider and scene publisher (the texture owner, the windows and the host's ledger
-- are the fakes and the model: injected evidence, as in the session examples).
--
-- A public @runSession@ composition has one instance of a role; the second instance of a role is the session harness's
-- private seam, so these examples compose the facade directly, the way the session does (a module coordinator, the data
-- service, a facade made with the injection's services, a supervised scheduled owner), and drive the instances' lives
-- themselves. They show that ending one instance through Haskell leaves its peer's window and texture usable and
-- publishable, that the owner map is cleaned for exactly the instance that ended, and that a peer's handle, facade or
-- retired texture is refused.
module Test.LuaEngine.Graphics.Peers (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Concurrent.STM (atomically, readTVarIO, retry, writeTVar)
import Control.Exception (finally)
import Control.Monad (forM_, unless, void)
import Data.ByteString (ByteString)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Maybe (isJust)
import qualified Data.Text as Text
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
import Hetoimasia.LuaEngine.Facade
import Hetoimasia.LuaEngine.Graphics.Facade (defaultIssuedMemory)
import Hetoimasia.LuaEngine.Graphics.Window.Provider
import Hetoimasia.Scripting.Lua.Instance hiding (forgetInstance)
import Hetoimasia.Scripting.Lua.Provider (advanceRequestEpoch)
import Hetoimasia.Scripting.Lua.Scheduled
import Test.HUnit.Lang (assertFailure)
import Test.Hspec
import qualified Test.LuaEngine.Graphics.Fake as Fake
import Test.LuaEngine.Graphics.PeersRig
import Test.LuaEngine.Graphics.SceneHost
import qualified Test.LuaEngine.Graphics.Window.Fake as WF


spec ∷ Spec
spec = describe "graphics facade, two instances of one VM" $ do
  boundSpec
  evictedSpec
  heldAdoptionSpec
  it "leaves a surviving instance's window and texture usable and publishable when its peer ends, cleans the owner map for the one that ended, and refuses the peer's handle, even once its texture has retired" $
    withPeers $ \peers → do
      first ← peAdmit peers
      second ← peAdmit peers
      -- Each instance opened a window and loaded a texture, took them and published a scene to its own window; the second
      -- keeps its window and texture live and waits for the example's word.
      awaitLine peers "published\t1"
      awaitLine peers "published\t2"
      forM_ [2, 4] $ \window → awaitRevision (peModel peers) window 1 >> void (adoptNow (peModel peers) window)
      atomically (providerReading (peProvider peers)) >>= \found → readingAcquisitions found `shouldBe` 2
      -- The first instance ends through Haskell: its window's target ends with it (the host releases what its adopted scene
      -- held), its texture retires completely, and the facade is told, as the session tells it once the settlement is seen.
      stop peers first
      removeWindow (peModel peers) 2
      _ ← waitInstance (spTicket first)
      forgetInstance (peFacade peers) (spIdentity first)
      -- Its window retires; only now is the survivor let go on, with its own window and texture still live.
      atomically (providerReading (peProvider peers) >>= \found → unless (readingAcquisitions found == 1) retry)
      atomically (writeTVar (peSignal peers) True)
      awaitLinePrefix peers "republished\t2\t"
      awaitRevision (peModel peers) 4 2
      -- Its handle, kept in the shared export, and its facade are refused to the survivor as ordinary errors, though its
      -- texture has retired completely and its owners are gone.
      awaitLine peers "foreign\tfalse\ttrue"
      -- The survivor's published scene is released by the host (its target ends), so its texture can retire with it.
      dissolve (peModel peers)
      stop peers second
      _ ← waitInstance (spTicket second)
      forgetInstance (peFacade peers) (spIdentity second)
      atomically (providerReading (peProvider peers) >>= \found → unless (readingAcquisitions found == 0) retry)

withPeers ∷ (Peers → IO a) → IO a
withPeers = withPeersWith peersEntry defaultIssuedMemory

-- | The most recent handles a VM remembers the issuing instance of, exceeded through the production injection: the memory
-- here is three ('gfIssuedMemory', the field the production composition sets to 'defaultIssuedMemory'), and the survivor
-- issues six textures in all. Inside the record a peer's retired handle is an ordinary error; once it has left the record
-- it answers @already_released@ with no provider action and no effect on a live texture; the owner's own releases answer
-- the same on both sides of the bound.
boundSpec ∷ Spec
boundSpec =
  it "refuses a peer's retired handle while it is remembered and answers already_released once it has left the record, with no provider action and no alias, and releases an instance's own handles alike on both sides of the bound" $
    withPeersWith boundEntry 3 $ \peers → do
      first ← peAdmit peers
      second ← peAdmit peers
      awaitLine peers "issued\t1"
      awaitLine peers "issued\t2"
      -- The first instance ends and is forgotten; its texture retires completely (the fake has released it), so that its
      -- lease is gone from the host and only the record can tell whose handle it was.
      stop peers first
      _ ← waitInstance (spTicket first)
      forgetInstance (peFacade peers) (spIdentity first)
      Fake.awaitEvent (peFake peers) "released "
      atomically (writeTVar (peSignal peers) True)
      awaitLine peers "finished"
      seen ← readTVarIO (peOut peers)
      let answers label = [Text.splitOn "\t" line | line ← seen, Just _ ← [Text.stripPrefix (label <> "\t") line]]
      -- inside the record (the first's handle and the survivor's own are both remembered): the peer's handle is refused
      answers "inside" `shouldBe` [["inside", "false", "true"]]
      -- the survivor's own handle, inside the record, answers its release and then already_released
      map (!! 2) (answers "own_inside") `shouldBe` ["already_released"]
      map (!! 1) (answers "own_inside") `shouldSatisfy` all (`elem` ["done", "retiring"])
      -- six textures were issued and three are remembered: the peer's handle (the oldest) has left the record
      answers "outside" `shouldBe` [["outside", "true", "already_released"]]
      -- the survivor's own handles outside the record: a retired one answers already_released at once, and a live one is
      -- still live (the answer for the peer's handle aliased nothing) and is released once
      answers "own_outside_retired" `shouldBe` [["own_outside_retired", "already_released", "already_released"]]
      map (!! 1) (answers "own_outside_live") `shouldSatisfy` all (`elem` ["done", "retiring"])
      map (!! 2) (answers "own_outside_live") `shouldBe` ["already_released"]
      -- six textures, each released by the provider exactly once: neither the peer's handle nor any repeated release of
      -- an instance's own reached the provider
      fakeEvents ← Fake.events (peFake peers)
      length (filter (Text.isPrefixOf "released ") fakeEvents) `shouldBe` 6
      stop peers second
      _ ← waitInstance (spTicket second)
      forgetInstance (peFacade peers) (spIdentity second)

-- | A handle that has left the record is not thereby retired: the host's own record of the lease decides while it holds one.
-- A peer's texture that is live, and then released but held by the host's adopted scene (retiring), is still refused to
-- the other instance once more than the memory of later textures have been issued, as an ordinary error with no provider
-- action; the peer stays healthy; and the owner's first release of that texture, out of the record, answers @retiring@,
-- revokes its authority for new scenes and leaves the provider's release for when the scene lets go.
evictedSpec ∷ Spec
evictedSpec =
  it "refuses a peer's live and scene-held texture after its issuance has left the record, with no provider action, and answers the owner's first release outside the record as a release" $
    withPeersWith evictedEntry 3 $ \peers → do
      first ← peAdmit peers
      second ← peAdmit peers
      awaitLine peers "published\t1"
      awaitRevision (peModel peers) 2 1
      -- The host adopts the scene that holds the texture, so that its release can only retire when the scene lets go.
      _ ← adoptNow (peModel peers) 2
      atomically (writeTVar (peSignal peers) True)
      awaitLine peers "finished"
      seen ← readTVarIO (peOut peers)
      let answers label = [Text.splitOn "\t" line | line ← seen, Just _ ← [Text.stripPrefix (label <> "\t") line]]
      -- the texture is live and four later ones were issued: the peer's call is refused, an ordinary error
      answers "evicted_live" `shouldBe` [["evicted_live", "false", "true"]]
      -- the owner's first release, outside the record: a release (the scene holds the texture, so retiring), and its
      -- authority for a new scene is gone
      answers "owner_first" `shouldBe` [["owner_first", "retiring"]]
      answers "revoked" `shouldBe` [["revoked", "false"]]
      -- released but held, and outside the record: still the host's lease, and still refused to the peer; and the peer
      -- goes on (its next texture loaded and released)
      answers "evicted_held" `shouldBe` [["evicted_held", "false", "true"]]
      map (!! 2) (answers "healthy") `shouldBe` ["already_released"]
      -- five textures were released by the provider (the peer's four and its next), and none for the peer's calls: the held
      -- texture is not among them, and neither refusal reached the provider
      fakeEvents ← Fake.events (peFake peers)
      length (filter (Text.isPrefixOf "released ") fakeEvents) `shouldBe` 5
      -- the held texture retires when the scene lets go
      dissolve (peModel peers)
      let settle found = do
            settled ← waitInstance (spTicket found)
            case resultOutcome settled of
              InstanceStopped → pure ()
              other → assertFailure ("expected the instance stopped, found " <> take 200 (show other))
            leasesFailed (resultLeases settled) `shouldBe` 0
            forgetInstance (peFacade peers) (spIdentity found)
      stop peers first
      removeWindow (peModel peers) 2
      settle first
      stop peers second
      settle second

-- | The host's own request invalidated while the provider holds its window's adoption: the epoch of the scheduled endpoint
-- advances (the public operation that settles every outstanding request as cancelled by the epoch) after the window was
-- created and attached and while the host's adoption recipe is held at 'hookBeforeAdopt'. The request being settled, the
-- provider closes the window it never handed over (the example holds the native window's destruction, so retirement is its
-- to release): the acquisition (the reservation) stays charged while the window has not retired, whether the adoption is
-- still parked or has run, and is returned only when the window retires. No success reaches the script, and the window is
-- closed once. The adoption gate and the retirement hold are let go on every exit, before the owner is torn down.
heldAdoptionSpec ∷ Spec
heldAdoptionSpec = do
  it "settles a window request whose host request is invalidated while the provider holds its adoption: no success is delivered, the window is closed once, and the reservation returns only after its retirement" $ do
    entered ← newEmptyMVar
    proceed ← newEmptyMVar
    seen ← newIORef False
    let hooks =
          noProviderHooks
            { hookBeforeAdopt = do
                first ← atomicModifyIORef' seen (\held → (True, not held))
                if first then putMVar entered () >> readMVar proceed else pure ()
            }
    -- The native window is held at its destruction, so that its retirement is the example's to release.
    withPeersHooked hooks (WF.defaultFakeConfig {WF.fcHolds = [WF.HoldNative]}) heldEntry defaultIssuedMemory $ \peers → do
      -- However the example ends, the adoption is let go before the owner is torn down.
      let acquisitions = atomically (providerReading (peProvider peers)) >>= pure . readingAcquisitions
          closes = length . filter (Text.isPrefixOf "close w") <$> WF.events (peWindows peers)
      ( do
          first ← peAdmit peers
          -- The window is created and attached, the host claimed the adoption recipe and the example holds it there.
          takeMVar entered
          acquisitions >>= (`shouldBe` 1)
          closes >>= (`shouldBe` 0)
          -- The host's request is invalidated through the public endpoint while the adoption is held. The request being
          -- settled, the provider closes the window it never handed over, while the adoption is still parked.
          advanceRequestEpoch (scheduledEndpoint (peOwner peers)) >>= (`shouldSatisfy` isJust)
          WF.awaitEvent (peWindows peers) "close w"
          closes >>= (`shouldBe` 1)
          -- Retirement is held: the reservation is charged for as long as the window has not retired, whether the
          -- adoption is still parked or has since run.
          acquisitions >>= (`shouldBe` 1)
          void (tryPutMVar proceed ())
          awaitLinePrefix peers "window\t"
          acquisitions >>= (`shouldBe` 1)
          -- Only when the window retires is the reservation back.
          WF.release (peWindows peers) WF.HoldNative
          atomically (providerReading (peProvider peers) >>= \found → unless (readingAcquisitions found == 0) retry)
          closes >>= (`shouldBe` 1)
          -- What the script was told: the request settled, but never as a success, and no other window came into being.
          awaitLine peers "after\ttrue"
          told ← readTVarIO (peOut peers)
          [line | line ← told, Text.isPrefixOf "window\t" line] `shouldSatisfy` all (/= "window\tsuccess")
          length (filter (Text.isPrefixOf "window\t") told) `shouldBe` 1
          length . filter (Text.isPrefixOf "issue create") <$> WF.events (peWindows peers) >>= (`shouldBe` 1)
          stop peers first
          _ ← waitInstance (spTicket first)
          forgetInstance (peFacade peers) (spIdentity first)
        )
        `finally` (void (tryPutMVar proceed ()) >> WF.release (peWindows peers) WF.HoldNative)

-- | One entry for both instances: open a window and load a texture in init, take both, publish a scene to the
-- instance's own window; when the first instance's shutdown says it ended, publish again and release the texture; and
-- try the first instance's handle and facade, kept in the shared export.
peersEntry ∷ ByteString
peersEntry =
  Text.encodeUtf8 . Text.unlines $
    [ "local share = import('lua/share.lua')"
    , "return {"
    , "  presentation = {"
    , "    every_seconds = 0.02,"
    , "    init = function(self, api)"
    , "      self.my = #share.apis + 1"
    , "      share.apis[self.my] = api"
    , "      self.w = api.window.open({title = 't', width = 64, height = 64})"
    , "      self.t = api.content.texture('images/quad.png')"
    , "    end,"
    , "    update = function(self, dt)"
    , "      local api = self.api"
    , "      if not self.win and api.request.ready(self.w) then self.win = api.request.take(self.w).value end"
    , "      if not self.img and api.request.ready(self.t) then"
    , "        self.img = api.request.take(self.t).value"
    , "        share.handles[self.my] = self.img.texture"
    , "      end"
    , "      if not (self.win and self.img) then return end"
    , "      -- the second instance goes on only once the first has handed over its texture, so that it has one to try"
    , "      if self.my == 2 and not share.handles[1] then return end"
    , "      if not self.a then"
    , "        self.a = true"
    , "        api.scene.publish(self.win, {clear = {r = self.my, g = 0, b = 0}, sprites = {{texture = self.img.texture, x = 0, y = 0, width = 2, height = 2}}})"
    , "        print('published', self.my)"
    , "        return"
    , "      end"
    , "      -- The example flips the session's status when the first instance has settled and been forgotten: the survivor reads"
    , "      -- it at the entry of this very update (a status is captured at each hook's entry) and goes on."
    , "      if self.my == 2 and not self.b and api.session.status().stopping then"
    , "        self.b = true"
    , "        api.scene.publish(self.win, {clear = {r = 9, g = 0, b = 0}, sprites = {{texture = self.img.texture, x = 0, y = 0, width = 2, height = 2}}})"
    , "        print('republished', self.my, api.texture.release(self.img.texture))"
    , "        local ok1, e1 = pcall(api.texture.release, share.handles[1])"
    , "        local ok2, e2 = pcall(share.apis[1].window.open, {title = 't', width = 1, height = 1})"
    , "        print('foreign', ok1, tostring(e1):find('belongs to another instance') ~= nil and tostring(e2):find('belongs to another instance') ~= nil)"
    , "      end"
    , "    end"
    , "  }"
    , "}"
    ]

-- | One instance that opens a window and does nothing with it until the host settles the request, then says how it
-- settled, and loads a texture to show that the instance's request places are back.
heldEntry ∷ ByteString
heldEntry =
  Text.encodeUtf8 . Text.unlines $
    [ "return {"
    , "  presentation = {"
    , "    every_seconds = 0.02,"
    , "    init = function(self, api)"
    , "      self.w = api.window.open({title = 't', width = 64, height = 64})"
    , "    end,"
    , "    update = function(self, dt)"
    , "      local api = self.api"
    , "      if not self.said and api.request.ready(self.w) then"
    , "        self.said = true"
    , "        print('window', api.request.take(self.w).status)"
    , "        self.t = api.content.texture('images/quad.png')"
    , "      end"
    , "      if self.t and not self.after and api.request.ready(self.t) then"
    , "        self.after = true"
    , "        print('after', api.request.take(self.t).status == 'success')"
    , "      end"
    , "    end"
    , "  }"
    , "}"
    ]

-- | One entry for both instances, for the bounded record: the first loads a texture and exports its handle; the second
-- (once it has the handle) loads its own, waits for the example's word that the first is gone, tries the first's handle
-- (the record still holds it), releases its own, loads and releases three more so that six handles were issued in all,
-- tries the first's handle again (it has left the record), and releases its own handles that are retired and live.
boundEntry ∷ ByteString
boundEntry =
  Text.encodeUtf8 . Text.unlines $
    planHelpers
      <>
    [ "add(function(self, api) return share.handles[1] ~= nil end)"
    , "load('t2')"
    , "add(function(self, api) print('issued', 2); return true end)"
    , "add(function(self, api) return api.session.status().stopping end)"
    , "add(function(self, api)"
    , "  local ok, e = pcall(api.texture.release, share.handles[1])"
    , "  print('inside', ok, tostring(e):find('belongs to another instance') ~= nil)"
    , "  return true"
    , "end)"
    , "drain('t2', 'own_inside')"
    , "load('t3')"
    , "load('t4'); drain('t4', 'churn')"
    , "load('t5'); drain('t5', 'churn')"
    , "load('t6'); drain('t6', 'churn')"
    , "add(function(self, api)"
    , "  local ok, answer = pcall(api.texture.release, share.handles[1])"
    , "  print('outside', ok, answer)"
    , "  return true"
    , "end)"
    , "drain('t2', 'own_outside_retired')"
    , "drain('t3', 'own_outside_live')"
    , "add(function(self, api) print('finished'); return true end)"
    , "return {"
    , "  presentation = {"
    , "    every_seconds = 0.02,"
    , "    init = function(self, api)"
    , "      self.my = #share.apis + 1"
    , "      share.apis[self.my] = api"
    , "      self.n = 1"
    , "      if self.my == 1 then self.q = api.content.texture(PATH) end"
    , "    end,"
    , "    update = function(self, dt)"
    , "      local api = self.api"
    , "      if self.my == 1 then"
    , "        if not self.done and api.request.ready(self.q) then"
    , "          self.done = true"
    , "          share.handles[1] = api.request.take(self.q).value.texture"
    , "          print('issued', 1)"
    , "        end"
    , "        return"
    , "      end"
    , "      local step = plan[self.n]"
    , "      if step and step(self, api) then self.n = self.n + 1 end"
    , "    end"
    , "  }"
    , "}"
    ]

-- | The Lua the bounded-record entries share: a plan of steps the second instance runs one a time, one per update, a step
-- being done when it answers true. @load@ takes a texture into the instance; @drain@ releases a handle, one call to an
-- update, until the answer is already_released, and prints the label, the first answer and the last.
planHelpers ∷ [Text]
planHelpers =
  [ "local share = import('lua/share.lua')"
  , "local PATH = 'images/quad.png'"
  , "local plan = {}"
  , "local function add(f) plan[#plan + 1] = f end"
  , "local function load(name)"
  , "  add(function(self, api) self.q = api.content.texture(PATH); return true end)"
  , "  add(function(self, api)"
  , "    if not api.request.ready(self.q) then return false end"
  , "    self[name] = api.request.take(self.q).value.texture"
  , "    return true"
  , "  end)"
  , "end"
  , "local function drain(name, label)"
  , "  add(function(self, api)"
  , "    local answer = api.texture.release(self[name])"
  , "    self.firsts = self.firsts or {}"
  , "    self.firsts[label] = self.firsts[label] or answer"
  , "    if answer ~= 'already_released' then return false end"
  , "    print(label, self.firsts[label], answer)"
  , "    return true"
  , "  end)"
  , "end"
  ]

-- | One entry for both instances, for the handles that are out of the record yet still the host's: the first opens a
-- window and publishes a scene with its texture, which the example's host adopts, then releases the texture on the
-- second's word (the scene holds it, so it retires only later) and tries to use it again; the second, once the host has
-- adopted the scene, loads and releases four textures (so that the first's has left a record of three), tries the first's
-- texture while it is live, tells the first to release it, tries it again while it is released and held, and loads and
-- releases one more to show it is well.
evictedEntry ∷ ByteString
evictedEntry =
  Text.encodeUtf8 . Text.unlines $
    planHelpers
      <> [ "add(function(self, api) return share.handles[1] ~= nil and api.session.status().stopping end)"
         , "for i = 1, 4 do load('c' .. i); drain('c' .. i, 'churn') end"
         , "add(function(self, api)"
         , "  local ok, e = pcall(api.texture.release, share.handles[1])"
         , "  print('evicted_live', ok, tostring(e):find('belongs to another instance') ~= nil)"
         , "  share.go = true"
         , "  return true"
         , "end)"
         , "add(function(self, api)"
         , "  if not share.released then return false end"
         , "  local ok, e = pcall(api.texture.release, share.handles[1])"
         , "  print('evicted_held', ok, tostring(e):find('belongs to another instance') ~= nil)"
         , "  return true"
         , "end)"
         , "load('h'); drain('h', 'healthy')"
         , "add(function(self, api) print('finished'); return true end)"
         , "return {"
         , "  presentation = {"
         , "    every_seconds = 0.02,"
         , "    init = function(self, api)"
         , "      self.my = #share.apis + 1"
         , "      share.apis[self.my] = api"
         , "      self.n = 1"
         , "      if self.my == 1 then"
         , "        self.w = api.window.open({title = 't', width = 64, height = 64})"
         , "        self.q = api.content.texture(PATH)"
         , "      end"
         , "    end,"
         , "    update = function(self, dt)"
         , "      local api = self.api"
         , "      if self.my == 1 then"
         , "        if not self.win and api.request.ready(self.w) then self.win = api.request.take(self.w).value end"
         , "        if not self.img and api.request.ready(self.q) then self.img = api.request.take(self.q).value end"
         , "        if not (self.win and self.img) then return end"
         , "        local scene = {clear = {r = 1, g = 0, b = 0}, sprites = {{texture = self.img.texture, x = 0, y = 0, width = 2, height = 2}}}"
         , "        if not self.published then"
         , "          self.published = true"
         , "          api.scene.publish(self.win, scene)"
         , "          share.handles[1] = self.img.texture"
         , "          print('published', 1)"
         , "        elseif share.go and not self.released then"
         , "          self.released = true"
         , "          print('owner_first', api.texture.release(self.img.texture))"
         , "          print('revoked', (pcall(api.scene.publish, self.win, scene)))"
         , "          share.released = true"
         , "        end"
         , "        return"
         , "      end"
         , "      local step = plan[self.n]"
         , "      if step and step(self, api) then self.n = self.n + 1 end"
         , "    end"
         , "  }"
         , "}"
         ]
