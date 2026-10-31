{-# LANGUAGE OverloadedStrings #-}

-- | LFE-23, M1 integrated ownership over the graphics adapter: two ordinary presentation instances A and B of one content
-- root in one real UI VM, composed through the production graphics injection ('graphicsInjection') over the real bounded PNG
-- decoder and CPU pipeline, the real window provider and the real scene publisher, with the controlled native edges.
--
-- __Real__: Lua VMs and filters, instance construction and attribution, module environments, the content root, inventory and
-- verified read pool, the data service, request reservations, the facade, the coordinator, the bounded PNG decoder, the texture
-- pipeline and backend, the window provider and the scene publisher with its hold ledger.
--
-- __Injected__ (and nothing else): the texture owner's native operations (allocation, upload start and completion,
-- registration, release, table reclamation: 'Test.LuaEngine.Graphics.Fake'), the native windows ('Test.LuaEngine.Graphics.Window.Fake'),
-- the host's adoption and use of published scenes ('Test.LuaEngine.Graphics.SceneHost') and the session endpoints. A fixture
-- gate holds or lets go of an operation; no fixture supplies a result the real adapter should compute. Controlled completion is
-- evidence of the adapter's ownership transitions, ordering and cleanup, never of pixels, a displayed frame or GPU behavior
-- (those are LFE-24 and LFE-25).
--
-- Nothing sleeps. An example learns what happened from what the Lua printed, from the fake's recorded events, or from STM.
module Test.LuaEngine.Graphics.Integrated (spec) where

import Control.Concurrent.STM (atomically, readTVarIO, retry, writeTVar)
import Control.Monad (forM_, unless, void)
import Data.ByteString (ByteString)
import Data.List (findIndex)
import Data.Maybe (isJust)
import qualified Data.Text as Text
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
import Hetoimasia.LuaEngine.Facade (forgetInstance)
import Hetoimasia.LuaEngine.Graphics.Window.Provider (noProviderHooks, providerReading, readingAcquisitions)
import Hetoimasia.Scripting.Lua.Instance hiding (forgetInstance)
import Hetoimasia.Scripting.Lua.Scheduled (scheduledEndpoint)
import Test.HUnit.Lang (assertFailure)
import Test.Hspec
import qualified Test.LuaEngine.Graphics.Fake as Fake
import Test.LuaEngine.Graphics.Composition (holdReadsOf, releaseReadsOf)
import Test.LuaEngine.Graphics.PeersRig
import Test.LuaEngine.Graphics.SceneHost
import qualified Test.LuaEngine.Graphics.Window.Fake as WF

spec ∷ Spec
spec = describe "M1 integrated texture, window and scene ownership across two instances" $ do
  sameFileSpec
  pendingEndSpec
  retainedEndSpec
  saturationSpec
  sharedPipelineSpec

-- | The texture owner's fake with every upload held at its completion, so that an example decides the order they finish in.
holdingUploads ∷ Fake.FakeConfig
holdingUploads = Fake.defaultFakeConfig {Fake.fcInitialHolds = [Fake.HoldUploadFinish]}

-- | Run an example over the two-instance composition with this entry and this fake.
withPair ∷ Fake.FakeConfig → ByteString → (Peers → IO a) → IO a
withPair fakeConfig entry = withPeersConfigured fakeConfig noProviderHooks WF.defaultFakeConfig entry 8

-- | The texture and window each instance asked for in its init, the scene it publishes, and what it says it saw.
--
-- A texture's handle is exported through the VM's one shared module so that an instance can compare it with its peer's.
-- After the session says it is stopping, the instance with the highest number publishes again, and (@release@) every
-- instance releases its Lua texture interest right after it publishes.
entryWith ∷ Bool → ByteString
entryWith release =
  Text.encodeUtf8 . Text.unlines $
    [ "local share = import('lua/share.lua')"
    , "local function scene(texture) return {clear = {r = 1, g = 0, b = 0}, sprites = {{texture = texture, x = 0, y = 0, width = 2, height = 2}}} end"
    , "return {"
    , "  presentation = {"
    , "    every_seconds = 0.02,"
    , "    init = function(self, api)"
    , "      self.my = #share.apis + 1"
    , "      share.apis[self.my] = api"
    , "      self.keep = api"
    , "      self.w = api.window.open({title = 't', width = 64, height = 64})"
    , "      self.t = api.content.texture('images/quad.png')"
    , "    end,"
    , "    update = function(self, dt)"
    , "      local api = self.keep"
    , "      if not self.win and api.request.ready(self.w) then self.win = api.request.take(self.w).value end"
    , "      if not self.img and api.request.ready(self.t) then"
    , "        local taken = api.request.take(self.t)"
    , "        self.img = taken.value"
    , "        if taken.status == 'success' then share.handles[self.my] = taken.value.texture end"
    , "        print('tex', self.my, taken.status)"
    , "      end"
    , "      if self.my == 2 and self.win and share.handles[1] and not self.checked then"
    , "        self.checked = true"
    , "        print('foreign_release', self.my, tostring((pcall(api.texture.release, share.handles[1]))))"
    , "        print('foreign_publish', self.my, tostring((pcall(api.scene.publish, self.win, scene(share.handles[1])))))"
    , "      end"
    , "      if self.win and self.img and not self.published then"
    , "        self.published = true"
    , "        api.scene.publish(self.win, scene(self.img.texture))"
    , "        print('published', self.my)"
    , "        if " <> (if release then "true" else "false") <> " then print('released', self.my, api.texture.release(self.img.texture)) end"
    , "        if share.handles[1] and share.handles[2] then print('distinct', tostring(not rawequal(share.handles[1], share.handles[2]))) end"
    , "        return"
    , "      end"
    , "      if self.published and self.my == 2 and not self.again and api.session.status().stopping then"
    , "        self.again = true"
    , "        if " <> (if release then "true" else "false") <> " then"
    , "          print('after_release', self.my, tostring((pcall(api.scene.publish, self.win, scene(self.img.texture)))))"
    , "          local ok, why = pcall(api.scene.publish, self.win, {clear = {r = 0, g = 0, b = 1}, sprites = {}})"
    , "          print('emptied', self.my, tostring(ok), tostring(why))"
    , "        else"
    , "          api.scene.publish(self.win, scene(self.img.texture))"
    , "          print('republished', self.my)"
    , "        end"
    , "      end"
    , "    end"
    , "  }"
    , "}"
    ]

-- | The index of the first event of the fake that starts like this.
firstEvent ∷ Text → [Text] → Maybe Int
firstEvent prefix = findIndex (Text.isPrefixOf prefix)

-- | The phase the instance is in, if the owner still holds it.
phaseNow ∷ Peers → Spawned → IO (Maybe InstancePhase)
phaseNow peers found = atomically (fmap snapshotPhase <$> inspectInstance (scheduledEndpoint (peOwner peers)) (spInstance found))

-- | Block until the reading of the window provider's acquisitions is this.
awaitAcquisitions ∷ Peers → Int → IO ()
awaitAcquisitions peers wanted = atomically (providerReading (peProvider peers) >>= \found → unless (readingAcquisitions found == wanted) retry)

-- | Let the instance settle, check it stopped with no failed lease, and tell the facade it is gone, as the session does.
settleStopped ∷ Peers → Spawned → IO ()
settleStopped peers found = do
  settled ← waitInstance (spTicket found)
  case resultOutcome settled of
    InstanceStopped → pure ()
    other → assertFailure ("expected the instance stopped, found " <> take 300 (show other))
  leasesFailed (resultLeases settled) `shouldBe` 0
  forgetInstance (peFacade peers) (spIdentity found)

-- | Both instances ask for the same inventoried PNG, each beside its own window, and the two uploads complete in the reverse
-- of the order they started.
sameFileSpec ∷ Spec
sameFileSpec =
  it "loads the same PNG for two instances as two independent read, decode, upload and registration obligations whose results come in the reverse of their start order, each through the usable registration, each to its own requester" $
    withPair holdingUploads (entryWith False) $ \peers → do
      let fake = peFake peers
      a ← peAdmit peers
      -- A's upload is open, held at its completion
      Fake.awaitEvent fake "upload started 0"
      b ← peAdmit peers
      Fake.awaitEvent fake "upload started 1"
      -- both obligations are open at once; the earlier one is held and the later one is let go
      Fake.holdTicket fake 0
      Fake.release fake Fake.HoldUploadFinish
      awaitLine peers "tex\t2\tsuccess"
      -- B's texture passed its upload completion and its registration, while A's upload had not completed
      events ← Fake.events fake
      let at prefix = firstEvent prefix events
      (at "upload completed 1", at "registered 1 ") `shouldSatisfy` \(done, registered) → isJust done && isJust registered && done < registered
      at "upload completed 0" `shouldBe` Nothing
      -- A has been told nothing: its result is not B's, and it is not early
      readTVarIO (peOut peers) >>= \told → filter (Text.isPrefixOf "tex\t1\t") told `shouldBe` []
      -- the earlier upload is let go: A is delivered its own, after B's
      Fake.releaseTicket fake 0
      awaitLine peers "tex\t1\tsuccess"
      awaitLine peers "distinct\ttrue"
      -- a peer's texture handle, passed through the shared export, authorizes B to neither release nor publish it, and acts on nothing
      awaitLine peers "foreign_release\t2\tfalse"
      awaitLine peers "foreign_publish\t2\tfalse"
      Fake.eventCount fake "released " >>= (`shouldBe` 0)
      events' ← Fake.events fake
      let at' prefix = firstEvent prefix events'
      (at' "registered 1 ", at' "upload completed 0") `shouldSatisfy` \(registered, done) → isJust registered && isJust done && registered < done
      -- two images were allocated, uploaded and registered; none was shared or coalesced
      length (filter (Text.isPrefixOf "allocated ") events') `shouldBe` 2
      length (filter (Text.isPrefixOf "registered ") events') `shouldBe` 2
      reading ← atomically (Fake.readFake fake)
      (Fake.readingImagesAlive reading, Fake.readingRegistrations reading) `shouldBe` (2, 2)
      -- ending the two instances retires each one's own holdings: the host lets go of both scenes
      forM_ [2, 4] $ \window → awaitRevision (peModel peers) window 1
      stop peers a
      stop peers b
      dissolve (peModel peers)
      forM_ [2, 4] (removeWindow (peModel peers))
      settleStopped peers a
      settleStopped peers b
      awaitAcquisitions peers 0
      atomically (Fake.readFake fake) >>= \final → (Fake.readingImagesAlive final, Fake.readingRegistrations final) `shouldBe` (0, 0)

-- | A ends while its texture upload and window work are pending; B goes on.
pendingEndSpec ∷ Spec
pendingEndSpec =
  it "ends A while its upload is open: A's result is never delivered and its native work drains before it retires, and B, unaffected, publishes and republishes on its own window and lease" $
    withPair holdingUploads (entryWith False) $ \peers → do
      let fake = peFake peers
      a ← peAdmit peers
      Fake.awaitEvent fake "upload started 0"
      b ← peAdmit peers
      Fake.awaitEvent fake "upload started 1"
      Fake.holdTicket fake 0
      Fake.release fake Fake.HoldUploadFinish
      awaitLine peers "tex\t2\tsuccess"
      awaitLine peers "published\t2"
      awaitRevision (peModel peers) 4 1
      void (adoptNow (peModel peers) 4)
      -- A is ended through Haskell with its upload open (an upload that has started cannot be withdrawn)
      stop peers a
      -- the end is not complete while the native work is: A is still held, B still serves
      Fake.awaitEvent fake "upload started 1"
      phaseNow peers a >>= \phase → phase `shouldSatisfy` maybe False (not . isTerminal)
      phaseNow peers b >>= (`shouldBe` Just Active)
      -- B publishes again on its own window with its own live lease while A's work is still open
      atomically (writeTVar (peSignal peers) True)
      awaitLine peers "republished\t2"
      awaitRevision (peModel peers) 4 2
      -- nothing of A's was delivered, nothing of B's was closed or revoked
      readTVarIO (peOut peers) >>= \told → filter (Text.isPrefixOf "tex\t1\t") told `shouldBe` []
      closes ← length . filter (Text.isPrefixOf "close w") <$> WF.events (peWindows peers)
      closes `shouldSatisfy` (<= 1)
      phaseNow peers b >>= (`shouldBe` Just Active)
      -- the actual completion of A's native work is supplied: only then can A retire, and it retires stopped
      Fake.releaseTicket fake 0
      Fake.awaitEvent fake "upload completed 0"
      settleStopped peers a
      readTVarIO (peOut peers) >>= \told → filter (Text.isPrefixOf "tex\t1\t") told `shouldBe` []
      -- B is still whole: its image and registration are the only ones left
      atomically (Fake.readFake fake) >>= \reading → Fake.readingRegistrations reading `shouldBe` 1
      phaseNow peers b >>= (`shouldBe` Just Active)
      dissolve (peModel peers)
      stop peers b
      removeWindow (peModel peers) 4
      settleStopped peers b

-- | A ends after both published and released their Lua texture interest; A's native use is held.
retainedEndSpec ∷ Spec
retainedEndSpec =
  it "ends A after both instances published and released: A's retained use stays live until its native completion is supplied, B's accepted scene and window survive, a new publication on B's released lease is refused, and an empty scene or B's end lets B retire" $
    withPair Fake.defaultFakeConfig (entryWith True) $ \peers → do
      let fake = peFake peers
      a ← peAdmit peers
      b ← peAdmit peers
      awaitLine peers "released\t1\tretiring"
      awaitLine peers "released\t2\tretiring"
      forM_ [2, 4] $ \window → awaitRevision (peModel peers) window 1 >> void (adoptNow (peModel peers) window)
      -- the table version that maps a released slot is still in use by the device
      Fake.setVersionHolders fake 1
      -- A ends: its target and window end with it, so its scene's hold is released and its texture is released to the owner,
      -- whose slot cannot be reclaimed while the device still holds the table version
      stop peers a
      removeWindow (peModel peers) 2
      Fake.awaitEvent fake "released 0 "
      -- A's retained use outlives the call: it has not retired while the native use is held
      phaseNow peers a >>= \phase → phase `shouldSatisfy` maybe False (\found → found /= Stopped)
      -- B goes on meanwhile: a new publication on its released lease is refused (its accepted scene is untouched), and an empty
      -- scene is accepted
      atomically (writeTVar (peSignal peers) True)
      awaitLine peers "after_release\t2\tfalse"
      awaitLine peers "emptied\t2\ttrue\tnil"
      awaitRevision (peModel peers) 4 2
      phaseNow peers b >>= (`shouldBe` Just Active)
      readTVarIO (peOut peers) >>= \told → filter (Text.isPrefixOf "tex\t1\t") told `shouldSatisfy` (not . null)
      -- the device lets go of the table version: A's slot is reclaimed and A retires, stopped, with nothing failed
      Fake.setVersionHolders fake 0
      Fake.awaitEvent fake "reclaimed"
      settleStopped peers a
      -- B's replacement scene is adopted; its earlier scene's hold ends, then ending B retires its own holdings
      void (adoptNow (peModel peers) 4)
      stop peers b
      removeWindow (peModel peers) 4
      dissolve (peModel peers)
      settleStopped peers b
      awaitAcquisitions peers 0
      atomically (Fake.readFake fake) >>= \final → Fake.readingRegistrations final `shouldBe` 0

-- | The texture bank of one UI instance, saturated through the fixed product profile, beside a peer.
--
-- A UI instance's texture bytes are 128 MiB and every request reserves 16 MiB of nominal RGBA8 bytes before it reads
-- anything, so eight requests are accepted and the ninth is busy (the instance's sixteen slots and request places are not
-- reached first). The peer has its own bank and its own places. Accepted work never turns back into busy; cancelling an
-- accepted request does not hand its reservation back, only the proof that its texture retired does; and only a later
-- explicit request from Lua uses the freed room.
saturationSpec ∷ Spec
saturationSpec =
  it "answers the ninth texture request of one UI instance busy with nothing reserved, leaves the peer's own bank and the accepted work alone, and frees a reservation only when its work has actually retired: queued work withdrawn without any read, and a read a worker holds only after it returns" $
    withPair holdingUploads saturating $ \peers → do
      let fake = peFake peers
      -- every read of the picture waits at the pool's reader, so that no decode has yet shrunk a 16 MiB reservation
      holdReadsOf (peComposition peers) "images/quad.png"
      a ← peAdmit peers
      awaitLine peers "filled\t1\t8\tbusy"
      b ← peAdmit peers
      awaitLine peers "asked\t2\ttrue"
      -- A cancels the request a worker holds: the read must drain, so its reservation stays and a new ask is still busy;
      -- then it cancels a request still queued, which is withdrawn without any read, so that exactly one place comes back
      -- while the reads are still held: the next ask is accepted and the one after it is busy again
      atomically (writeTVar (peSignal peers) True)
      awaitLine peers "cancel\t1\tcancelled"
      awaitLine peers "retry_after_started\t1\tbusy"
      awaitLine peers "cancel_queued\t1\tcancelled"
      awaitLine peers "retry_after_withdrawn\t1\taccepted"
      awaitLine peers "second_ask\t1\tbusy"
      -- the read the worker held is let go and the work drains; the room it kept is back, and A's ask is accepted again
      releaseReadsOf (peComposition peers) "images/quad.png"
      Fake.release fake Fake.HoldUploadFinish
      awaitLine peers "retry_after_drained\t1\taccepted"
      readTVarIO (peOut peers) >>= \told → filter (Text.isPrefixOf "asked\t2\t") told `shouldBe` ["asked\t2\ttrue"]
      phaseNow peers a >>= (`shouldBe` Just Active)
      phaseNow peers b >>= (`shouldBe` Just Active)
      stop peers a
      stop peers b
      dissolve (peModel peers)
      settleStopped peers a
      settleStopped peers b
      awaitAcquisitions peers 0
      atomically (Fake.readFake fake) >>= \final → (Fake.readingImagesAlive final, Fake.readingRegistrations final) `shouldBe` (0, 0)
  where
    saturating =
      Text.encodeUtf8 . Text.unlines $
        [ "local share = import('lua/share.lua')"
        , "return {"
        , "  presentation = {"
        , "    every_seconds = 0.02,"
        , "    init = function(self, api)"
        , "      self.my = #share.apis + 1"
        , "      share.apis[self.my] = api"
        , "      self.keep = api"
        , "      self.reqs = {}"
        , "      if self.my == 1 then"
        , "        local busy"
        , "        for i = 1, 20 do"
        , "          local r, e = api.content.texture('images/quad.png')"
        , "          if r == nil then busy = e.code break end"
        , "          self.reqs[#self.reqs + 1] = r"
        , "        end"
        , "        print('filled', self.my, #self.reqs, tostring(busy))"
        , "      else"
        , "        print('asked', self.my, tostring(api.content.texture('images/quad.png') ~= nil))"
        , "      end"
        , "    end,"
        , "    update = function(self, dt)"
        , "      local api = self.keep"
        , "      if self.my ~= 1 then return end"
        , "      local function ask(label, quiet)"
        , "        local r, e = api.content.texture('images/quad.png')"
        , "        if r ~= nil then self.reqs[#self.reqs + 1] = r end"
        , "        if r ~= nil or not quiet then print(label, self.my, r == nil and e.code or 'accepted') end"
        , "        return r ~= nil"
        , "      end"
        , "      if self.stage == 'draining' then"
        , "        if ask('retry_after_drained', true) then self.stage = 'done' end"
        , "      elseif self.stage == 'withdrawing' then"
        , "        if ask('retry_after_withdrawn', true) then"
        , "          ask('second_ask')"
        , "          self.stage = 'draining'"
        , "        end"
        , "      elseif not self.stage and api.session.status().stopping then"
        , "        print('cancel', self.my, api.request.cancel(self.reqs[1]))"
        , "        api.request.take(self.reqs[1])"
        , "        ask('retry_after_started')"
        , "        print('cancel_queued', self.my, api.request.cancel(self.reqs[8]))"
        , "        api.request.take(self.reqs[8])"
        , "        self.stage = 'withdrawing'"
        , "      end"
        , "    end"
        , "  }"
        , "}"
        ]

-- | Texture work open at the native owner while unrelated reads go through the same pool.
sharedPipelineSpec ∷ Spec
sharedPipelineSpec =
  it "serves another instance's data and module reads while a texture's upload is open at the owner: workers release their slots at handoff and never wait for the native stage" $
    withPair holdingUploads sharing $ \peers → do
      let fake = peFake peers
      a ← peAdmit peers
      Fake.awaitEvent fake "upload started 0"
      b ← peAdmit peers
      -- B's reads (a data file and a module) complete through the shared pool while A's upload is still open
      awaitLine peers "data\t2\tsuccess"
      awaitLine peers "module\t2\tsuccess"
      Fake.eventCount fake "upload completed 0" >>= (`shouldBe` 0)
      readTVarIO (peOut peers) >>= \told → filter (Text.isPrefixOf "tex\t1\t") told `shouldBe` []
      Fake.release fake Fake.HoldUploadFinish
      awaitLine peers "tex\t1\tsuccess"
      stop peers a
      stop peers b
      dissolve (peModel peers)
      settleStopped peers a
      settleStopped peers b
  where
    sharing =
      Text.encodeUtf8 . Text.unlines $
        [ "local share = import('lua/share.lua')"
        , "return {"
        , "  presentation = {"
        , "    every_seconds = 0.02,"
        , "    init = function(self, api)"
        , "      self.my = #share.apis + 1"
        , "      share.apis[self.my] = api"
        , "      self.keep = api"
        , "      if self.my == 1 then self.t = api.content.texture('images/quad.png')"
        , "      else"
        , "        self.d = api.content.data('images/quad.png')"
        , "        self.m = api.content.module('lua/share.lua')"
        , "      end"
        , "    end,"
        , "    update = function(self, dt)"
        , "      local api = self.keep"
        , "      if self.t and api.request.ready(self.t) then print('tex', self.my, api.request.take(self.t).status) self.t = nil end"
        , "      if self.d and api.request.ready(self.d) then print('data', self.my, api.request.take(self.d).status) self.d = nil end"
        , "      if self.m and api.request.ready(self.m) then print('module', self.my, api.request.take(self.m).status) self.m = nil end"
        , "    end"
        , "  }"
        , "}"
        ]
