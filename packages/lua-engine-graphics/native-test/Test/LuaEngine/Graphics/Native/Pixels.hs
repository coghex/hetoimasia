{-# LANGUAGE OverloadedStrings #-}

-- | The `Lua offscreen pixels` subgroup (LFE-24): the pixels Lua actually authored, on a real device, with a managed
-- offscreen colour target in place of the display's native window and nothing else replaced.
--
-- = What runs for real
--
-- The real filtered Lua VMs and the roles of a real 'runSession'; the manifest checkpoint and the anchored inventory and
-- verified reads of a content root copied to an owned temporary directory before boot; module evaluation, instance and
-- role construction, request ready/take; the bounded PNG decoder; texture upload and registration through the
-- session's one table; the graphics facade ('graphicsInjection'); scene preparation and publication through the
-- production publisher; the host's adoption, hold ledger and release barrier; and the production renderer's
-- 'frameCandidate'. The shipped @samples/lua-quad/content@ runs unchanged. The ordinary logical stub runs beside the
-- UI Lua: every program has the manifest's gameplay role with its empty update.
--
-- = What is substituted
--
-- Only the display target: "Test.LuaEngine.Graphics.Native.Display" answers the window provider's port with a
-- surface-free offscreen scene target registered through LFE-27's public interface. The boundary is
-- 'registerVulkanSceneTarget' (the substitution), 'offscreenTargetAnswer' over 'publishVulkanTargetScene' (the
-- publication the production publisher composes with its authority checks) and 'recordVulkanTargetBatch' (the recording
-- boundary), with 'withWindowProvider', the window 'Port', 'scenePublisherOver' and 'graphicsInjection' (all
-- polymorphic in the target) carrying the target through. The adapter keeps no hold, barrier or lifecycle of its own.
--
-- = Pacing without sleeping
--
-- A program's steps are gated on the completion of texture requests the example holds at the read pool's reader
-- ('holdReadsOf'): Lua requests the gate file of its next step, the request completes only when the example lets the
-- read go, and the step runs when Lua takes the result. So the example, not a clock, decides when each publication
-- happens, and it knows the publication was accepted from the host's own scene state.
--
-- = What each image is judged by
--
-- See "Test.LuaEngine.Graphics.Pixels": the hand-stated expectations, the render-2d oracle over the specification, and the
-- render-2d oracle over the published window-pass scene with the managed target's own 'TargetSpec', every pixel.
module Test.LuaEngine.Graphics.Native.Pixels (spec) where

import Control.Concurrent (forkFinally, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Concurrent.STM (TVar, atomically, check, modifyTVar', newTVarIO, readTVar, readTVarIO, retry)
import Control.Exception (AsyncException (ThreadKilled), displayException, finally, fromException)
import Control.Monad (forM_, unless, void, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.IO as Text
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (UTCTime), secondsToDiffTime)
import Hetoimasia.Foundation.Log (Logger, MetadataProviders (..), callbackSink, defaultLogFilter, mkLoggerWith)
import Hetoimasia.Foundation.Time (monotonicSource)
import Hetoimasia.GPU.Vulkan.GLFW
  ( OffscreenTargetId
  , SceneTargetKey (..)
  , VulkanAction (..)
  , VulkanSceneState (..)
  , WindowSceneStanding (..)
  , awaitVulkanAction
  , readVulkanSceneState
  , submitVulkanAction
  )
import Hetoimasia.LuaEngine.Boot (bootCheckpointFrom)
import Hetoimasia.LuaEngine.Facade (OutputSink (..), withOutput)
import Hetoimasia.LuaEngine.Graphics.Facade (GraphicsFacade (..), defaultIssuedMemory, graphicsInjection)
import Hetoimasia.LuaEngine.Graphics.Scene
import Hetoimasia.LuaEngine.Graphics.Texture
import Hetoimasia.LuaEngine.Graphics.Window.Port (fatalText)
import Hetoimasia.LuaEngine.Graphics.Window.Provider (WindowConfig (..), windowMainStep, withWindowProvider)
import Hetoimasia.LuaEngine.Manifest (Role (Presentation))
import Hetoimasia.LuaEngine.Scene (SceneContent (..), SceneSprite (..), TextureUse (..))
import Hetoimasia.LuaEngine.Session
import Hetoimasia.LuaEngine.Texture (TextureView (..))
import Hetoimasia.Render.TwoD.Oracle (Oracle)
import Hetoimasia.Scripting.Lua.Scheduler (systemTimerBackend)
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.Timeout (timeout)
import System.FilePath ((</>))
import Test.HUnit.Lang (HUnitFailure (..), assertFailure)
import Test.Hspec
import Test.LuaEngine.Graphics.Composition (Composition (..), Files, compositionProfile, holdReadsOf, releaseAllReads, releaseReadsOf, withComposition)
import Test.LuaEngine.Graphics.FacadeScripts (manifestFor)
import Test.LuaEngine.Graphics.Native.Display
import Test.LuaEngine.Graphics.Native.Scenes (evidence, within)
import Test.LuaEngine.Graphics.Native.Session (Env (..), serveMain)
import qualified Test.LuaEngine.Graphics.Png as Png
import Test.LuaEngine.Graphics.Pixels

-- The subgroup ----------------------------------------------------------------------------------------------------------

spec ∷ Env → Spec
spec env = describe "Lua offscreen pixels" $ do
  it "shipped Lua quad: the unchanged samples/lua-quad content, at known offscreen metrics, draws its authored PNG at its declared rectangle over its clear" $
    within 120 $ do
      files ← shippedFiles
      withLiveSession env "shipped-quad" files [] $ \live → do
        awaitPublished live 1
        awaitAdopted live 1
        _ ← checkImage env live "shipped quad" quadSpec 1 (pure ())
        publishedNow live >>= (`shouldBe` Just 1)

  it "a Lua failure before any window exists ends the example with the roles' failure, with the scenario joined and nothing left behind" $
    -- Well inside the scenario's own 60-second bound: the session has already returned, so nothing may wait for that bound.
    within 30 $ do
      let files = [("hetoimasia.json", manifestFor True), ("lua/main.lua", failingBeforeWindow)]
          roleFailed (HUnitFailure _ reason) = "boom before any window" `isInfixOf` show reason
      -- The scenario never gets a target (no window is ever opened), so it waits in its startup; the session returns an
      -- unsuccessful outcome, and the example must end with that failure rather than wait on the scenario.
      withLiveSession env "failure-before-window" files [] (\_ → pure ()) `shouldThrow` roleFailed
      awaitGone env

  it "top-left, full image, nearest: an asymmetric twelve-colour texture, enlarged eight to a texel, shows every texel at its place with no colour between neighbours, after the initial scene read opaque black" $
    within 120 $
      withProgram env "top-left-nearest" gridProgram $ \live → do
        -- Before the first publication the target holds the host's initial scene: opaque black, naming nothing.
        awaitAdopted live 0
        _ ← checkImage env live "initial scene" initialSpec 0 (pure ())
        releaseGate live 1
        awaitAdopted live 1
        _ ← checkImage env live "grid" gridSpec 1 (pure ())
        publishedNow live >>= (`shouldBe` Just 1)

  it "ordered transparency: later list entries cover earlier ones with the premultiplied blend, and the reversed list in a separate publication shows the reversed overlap" $
    within 120 $
      withProgram env "ordered-transparency" orderedProgram $ \live → do
        awaitAdopted live 0
        releaseGate live 1
        awaitAdopted live 1
        _ ← checkImage env live "red then blue" orderedSpec 1 (pure ())
        releaseGate live 2
        awaitAdopted live 2
        _ ← checkImage env live "blue then red" orderedReversedSpec 2 (pure ())
        publishedNow live >>= (`shouldBe` Just 2)

  it "sRGB byte clear: a clear of byte 128 reads back 128 and not 188, an opaque mid-grey texel reads back 128, and the output is opaque" $
    within 120 $
      withProgram env "srgb-byte-clear" greyProgram $ \live → do
        awaitAdopted live 0
        releaseGate live 1
        awaitAdopted live 1
        _ ← checkImage env live "clear 128" greyClearSpec 1 (pure ())
        releaseGate live 2
        awaitAdopted live 2
        _ ← checkImage env live "texel 128" greySpriteSpec 2 (pure ())
        publishedNow live >>= (`shouldBe` Just 2)

  it "fractional, negative and clipping: fixed logical coordinates with no snapping, and rectangles across each target edge clip without recentring or stretching" $
    within 120 $
      withProgram env "fractional-negative-clipping" placementProgram $ \live → do
        awaitAdopted live 0
        releaseGate live 1
        awaitAdopted live 1
        _ ← checkImage env live "placement" placementSpec 1 (pure ())
        publishedNow live >>= (`shouldBe` Just 1)

  it "target metrics: one accepted scene, rendered at different nonzero extents and at content scales 1 and 2 with no new publication, keeps its logical-pixel positions and sizes" $
    within 120 $
      withProgram env "target-metrics" gridProgram $ \live → do
        awaitAdopted live 0
        releaseGate live 1
        awaitAdopted live 1
        forM_ metricsSpecs $ \(image, metricsSpec) → checkImage env live image metricsSpec 1 (pure ())
        -- The same accepted revision at every extent and scale: Lua published once and was never asked to again.
        publishedNow live >>= (`shouldBe` Just 1)
        adoptedNow live >>= (`shouldBe` Just 1)

  it "empty scene: publishing an empty sprite list clears the prior pixels to the authored opaque colour" $
    within 120 $
      withProgram env "empty-scene" emptyProgram $ \live → do
        awaitAdopted live 0
        releaseGate live 1
        awaitAdopted live 1
        _ ← checkImage env live "before: the grid" gridSpec 1 (pure ())
        releaseGate live 2
        awaitAdopted live 2
        _ ← checkImage env live "after: empty" emptySpec 2 (pure ())
        publishedNow live >>= (`shouldBe` Just 2)

  it "copied scene: mutating the original Lua table after publication changes no pixel until a later valid publication, which shows the new image" $
    within 120 $
      withProgram env "copied-scene" copyProgram $ \live → do
        awaitAdopted live 0
        releaseGate live 1
        awaitAdopted live 1
        -- The script has changed its own table by now: the line is written after the change.
        awaitWarn live "mutated"
        _ ← checkImage env live "as published, after the script changed its table" copyBeforeSpec 1 (pure ())
        publishedNow live >>= (`shouldBe` Just 1)
        releaseGate live 2
        awaitAdopted live 2
        void (checkImage env live "republished after the change" copyAfterSpec 2 (pure ()))

  it "refused publication: a malformed scene and a publication naming a released texture both refuse atomically, and a completed render still shows the last accepted pixels at the last accepted revision" $
    within 120 $
      withProgram env "refused-publication" refusalProgram $ \live → do
        awaitAdopted live 0
        releaseGate live 1
        awaitAdopted live 1
        _ ← checkImage env live "last accepted, before the refusals" refusalSpec 1 (pure ())
        releaseGate live 2
        expectWarned live "refused-malformed:" "true"
        expectWarned live "refused-released:" "true"
        -- Neither refusal reached the host: no new revision was accepted, none adopted.
        publishedNow live >>= (`shouldBe` Just 1)
        adoptedNow live >>= (`shouldBe` Just 1)
        _ ← checkImage env live "last accepted, after the refusals" refusalSpec 1 (pure ())
        publishedNow live >>= (`shouldBe` Just 1)

  it "release after publish: a texture released straight after its scene was accepted, before the target adopted it, is retained by the host, drawn after the release in two batches with no new publication, refused for a new publication, and freed only after the old uses completed" $
    within 120 $
      withProgram env "release-after-publish" releaseProgram $ \live → do
        let host = envHost env
            target = liveTarget live
            ledger = graphicsLedger (envGraphics env)
        -- The owner adopts the initial scene as revision 0 on its own, and Lua has loaded the texture (its upload
        -- needs the owner, so it must be complete before the owner is held).
        awaitAdopted live 0
        awaitWarn live "loaded"
        -- Hold the owner inside an action, so that it cannot adopt while the scene is accepted and the texture released.
        entered ← newEmptyMVar
        proceed ← newEmptyMVar
        let letGo = void (tryPutMVar proceed ())
        gate ←
          atomically (submitVulkanAction host (VulkanAction (\_ → putMVar entered () >> takeMVar proceed)))
            >>= either (\refusal → assertFailure ("the holding action was refused: " <> show refusal)) pure
        flip finally letGo $ do
          takeMVar entered
          releaseGate live 1
          -- Lua published and released in one hook: its own line says the release is only retiring, the host's own
          -- state says the revision is accepted and not adopted, and the release request waits behind a barrier
          -- naming the target.
          awaitWarn live "published-and-released"
          awaitWarn live "release:retiring"
          atomically $ do
            standing ← targetStanding host target
            check (fmap windowPublished standing == Just (Just 1) && fmap windowAdopted standing == Just (Just 0))
            state ← readVulkanSceneState host
            check (any ((== Just 1) . Map.lookup (KeyOffscreen target)) (sceneRequests state))
          live' ← atomically (graphicsReading (envGraphics env))
          readingLiveTextures live' `shouldSatisfy` (> 0)
        -- The owner is let go: it adopts revision 1, which the ledger then holds the texture for.
        void (atomically (awaitVulkanAction gate))
        awaitAdopted live 1
        atomically (ledgerReading ledger >>= \reading → check (not (Set.null (readingHeld reading))))
        _ ← checkImage env live "drawn after the release" gridSpec 1 (pure ())
        -- A further batch renders the retained scene again with no new publication.
        _ ← checkImage env live "drawn again, no new publication" gridSpec 1 (pure ())
        publishedNow live >>= (`shouldBe` Just 1)
        -- A publication naming the released handle is refused and changes nothing.
        releaseGate live 2
        expectWarned live "refused-released:" "true"
        publishedNow live >>= (`shouldBe` Just 1)
        -- The replacement is published while a batch that read revision 1 is recorded and not yet complete; what ends
        -- the old revision's use is that batch's own ticket.
        _ ←
          checkImage env live "drawn while the replacement is published" gridSpec 1 $ do
            releaseGate live 3
            awaitPublished live 2
        awaitAdopted live 2
        -- Retirement on the table's and the host's own evidence, after the batches' tickets completed.
        atomically $ do
          reading ← graphicsReading (envGraphics env)
          check (readingLiveTextures reading == 0)
        atomically $ do
          reading ← ledgerReading ledger
          check (Set.null (readingHeld reading))
          state ← readVulkanSceneState host
          check (all (null . windowAwaitingRelease) (Map.elems (sceneWindows state)))
        final ← atomically (ledgerReading ledger)
        readingDefects final `shouldBe` 0
        _ ← checkImage env live "the empty replacement" emptySpec 2 (pure ())
        publishedNow live >>= (`shouldBe` Just 2)
        evidence env "Lua offscreen pixels: a texture released straight after acceptance and before adoption was drawn after the release (two batches), refused for a new publication, and retired only after the replacement and the old batches' tickets completed"

-- | A program whose presentation role fails in its first hook, before it can open a window.
failingBeforeWindow ∷ ByteString
failingBeforeWindow =
  Text.encodeUtf8 . Text.unlines $
    [ "return {"
    , "  gameplay = {every_ticks=1, update=function(self, dt_seconds) end},"
    , "  presentation = {"
    , "    every_seconds=0.02,"
    , "    init=function(self, api) error(\"boom before any window\") end,"
    , "    update=function(self, dt_seconds) end"
    , "  }"
    , "}"
    ]

-- | The metrics rows: the grid scene viewed at other extents and scales, all of revision 1.
metricsSpecs ∷ [(Text, CaseSpec)]
metricsSpecs =
  [ ("extent 64x48, scale 1", gridAtScale 1 (64, 48) (64, 48) "grid 64x48 s1")
  , ("extent 128x96 for logical 64x48, scale 2", gridAtScale 2 (128, 96) (64, 48) "grid 128x96 s2")
  , ("extent 80x60, scale 1", gridAtScale 1 (80, 60) (80, 60) "grid 80x60 s1")
  , ("extent 40x30, scale 1", gridAtScale 1 (40, 30) (40, 30) "grid 40x30 s1")
  ]

-- The programs ------------------------------------------------------------------------------------------------------------

-- | Authored content: the textures it loads (by the name Lua knows them by) and the steps it runs, each after its gate.
data Program = Program
  { programTextures ∷ [(Text, Fixture)]
  , programSteps ∷ [Text]
  }

gateFile ∷ Int → FilePath
gateFile n = "images/gate" <> show n <> ".png"

luaPublish ∷ Program → CaseSpec → Text
luaPublish program spec' = "api.scene.publish(self.window, " <> sceneTable program spec' <> ")"

-- | A scene table written out from the specification.
sceneTable ∷ Program → CaseSpec → Text
sceneTable program spec' =
  "{clear={r=" <> number r <> ", g=" <> number g <> ", b=" <> number b <> "}, sprites={" <> Text.intercalate ", " (map sprite (specPlacements spec')) <> "}}"
  where
    (r, g, b) = specClear spec'
    number ∷ Real a ⇒ a → Text
    number value = let shown = realToFrac value ∷ Double in if shown == fromIntegral (round shown ∷ Int) then Text.pack (show (round shown ∷ Int)) else Text.pack (show shown)
    sprite (Placement fixture (x, y, w, h)) =
      "{texture=self.tex." <> nameOf fixture <> ", x=" <> number x <> ", y=" <> number y <> ", width=" <> number w <> ", height=" <> number h <> "}"
    nameOf fixture = case [name | (name, f) ← programTextures program, fixtureFile f == fixtureFile fixture] of
      name : _ → name
      [] → error ("the program does not load " <> fixtureFile fixture)

gridProgram, orderedProgram, greyProgram, placementProgram, emptyProgram, copyProgram, refusalProgram, releaseProgram ∷ Program
gridProgram = Program [("grid", gridFixture)] [luaPublish gridProgram gridSpec]
orderedProgram =
  Program
    [("red", redFixture), ("blue", blueFixture)]
    [luaPublish orderedProgram orderedSpec, luaPublish orderedProgram orderedReversedSpec]
greyProgram =
  Program
    [("grey", greyFixture)]
    [luaPublish greyProgram greyClearSpec, luaPublish greyProgram greySpriteSpec]
placementProgram =
  Program
    [("magenta", magentaFixture), ("grid", gridFixture)]
    [luaPublish placementProgram placementSpec]
emptyProgram =
  Program
    [("grid", gridFixture)]
    [luaPublish emptyProgram gridSpec, luaPublish emptyProgram emptySpec]
copyProgram =
  Program
    [("magenta", magentaFixture)]
    [ Text.unlines
        [ "local scene = " <> sceneTable copyProgram copyBeforeSpec
        , "api.scene.publish(self.window, scene)"
        , "scene.clear.r = 250"
        , "scene.sprites[1].x = 40"
        , "self.copy = scene"
        , "warn(\"mutated\")"
        ]
    , "api.scene.publish(self.window, self.copy)"
    ]
refusalProgram =
  Program
    [("grid", gridFixture)]
    [ luaPublish refusalProgram refusalSpec
    , Text.unlines
        [ "local ok1 = pcall(api.scene.publish, self.window, {clear={r=200, g=200, b=0}, sprites={{texture=self.tex.grid, x=1, y=1, width=-4, height=4}}})"
        , "warn(\"refused-malformed:\" .. tostring(not ok1))"
        , "api.texture.release(self.tex.grid)"
        , "local ok2 = pcall(api.scene.publish, self.window, {clear={r=0, g=200, b=200}, sprites={{texture=self.tex.grid, x=1, y=1, width=4, height=4}}})"
        , "warn(\"refused-released:\" .. tostring(not ok2))"
        ]
    ]
releaseProgram =
  Program
    [("grid", gridFixture)]
    [ Text.unlines
        [ luaPublish releaseProgram gridSpec
        , "warn(\"published-and-released\")"
        , "warn(\"release:\" .. api.texture.release(self.tex.grid))"
        ]
    , Text.unlines
        [ "local ok = pcall(api.scene.publish, self.window, {clear={r=0, g=200, b=200}, sprites={{texture=self.tex.grid, x=1, y=1, width=4, height=4}}})"
        , "warn(\"refused-released:\" .. tostring(not ok))"
        ]
    , luaPublish releaseProgram emptySpec
    ]

-- | The content files of a program: the manifest with the gameplay role's stub beside the presentation, the Lua, the
-- committed fixtures it loads and one gate file for each step.
programFiles ∷ Program → IO Files
programFiles program = do
  textures ← forM' (programTextures program) $ \(_, fixture) → (,) (fixtureFile fixture) <$> fixtureBytes fixture
  pure $
    [("hetoimasia.json", manifestFor True), ("lua/main.lua", Text.encodeUtf8 (programLua program))]
      <> textures
      <> [(gateFile n, gateBytes) | n ← [1 .. length (programSteps program)]]
  where
    forM' xs f = mapM f xs

-- | What a gate file holds: not a PNG. A request for it finishes, once the example lets its read go, as an ordinary
-- decode failure /without any upload/: so Lua is paced by the example even while the example holds the graphics owner,
-- which a texture that has to be uploaded could not be. The request is optional, so its failure is an ordinary result
-- and not a failure of the role.
gateBytes ∷ ByteString
gateBytes = "gate: this is not a PNG, by design; the read of it is the example's to release\n"

-- | The driver. It opens its window, loads its textures, and then runs each step after the request for that step's gate
-- file completed. Every call is an ordinary call of the real facade.
programLua ∷ Program → Text
programLua program =
  Text.unlines $
    [ "local TEXTURES = {" <> Text.intercalate ", " ["{\"" <> name <> "\", \"" <> Text.pack (fixtureFile fixture) <> "\"}" | (name, fixture) ← programTextures program] <> "}"
    , "local GATES = {" <> Text.intercalate ", " ["\"" <> Text.pack (gateFile n) <> "\"" | n ← [1 .. length (programSteps program)]] <> "}"
    , "local STEPS = {"
    ]
      <> concat [["function(self, api)", step, "end,"] | step ← programSteps program]
      <> [ "}"
         , "local function remember(self, key, request, refusal)"
         , "  if request then self[key] = request"
         , "  else assert(refusal.code == \"busy\") end"
         , "end"
         , "local function take(self, api, key)"
         , "  local request = self[key]"
         , "  if not request or not api.request.ready(request) then return nil end"
         , "  local result = api.request.take(request)"
         , "  self[key] = nil"
         , "  if result.status == \"success\" then return result.value end"
         , "  if result.status == \"cancelled\" then api.session.quit() return nil end"
         , "  error(result.error.message)"
         , "end"
         , "local function finished(self, api, key)"
         , "  local request = self[key]"
         , "  if not request or not api.request.ready(request) then return false end"
         , "  api.request.take(request)"
         , "  self[key] = nil"
         , "  return true"
         , "end"
         , "local function begin(self)"
         , "  local api = self.api"
         , "  self.tex = self.tex or {}"
         , "  if not self.window and not self.window_request then"
         , "    remember(self, \"window_request\", api.window.open({title=\"pixels\", width=64, height=48}))"
         , "  end"
         , "  for _, entry in ipairs(TEXTURES) do"
         , "    local key = \"tex_request_\" .. entry[1]"
         , "    if not self.tex[entry[1]] and not self[key] then"
         , "      remember(self, key, api.content.texture(entry[2]))"
         , "    end"
         , "  end"
         , "end"
         , "return {"
         , "  gameplay = {every_ticks=1, update=function(self, dt_seconds) end},"
         , "  presentation = {"
         , "    every_seconds=0.02,"
         , "    init=function(self, api) begin(self) end,"
         , "    update=function(self, dt_seconds)"
         , "      local api = self.api"
         , "      begin(self)"
         , "      local window = take(self, api, \"window_request\")"
         , "      if window then self.window = window end"
         , "      for _, entry in ipairs(TEXTURES) do"
         , "        local value = take(self, api, \"tex_request_\" .. entry[1])"
         , "        if value then self.tex[entry[1]] = value.texture end"
         , "      end"
         , "      if not self.window then return end"
         , "      for _, entry in ipairs(TEXTURES) do"
         , "        if not self.tex[entry[1]] then return end"
         , "      end"
         , "      if not self.loaded then"
         , "        self.loaded = true"
         , "        warn(\"loaded\")"
         , "      end"
         , "      self.step = self.step or 1"
         , "      if not self.gate_taken and not self.gate_request and GATES[self.step] then"
         , "        remember(self, \"gate_request\", api.content.texture(GATES[self.step], {optional=true}))"
         , "      end"
         , "      if finished(self, api, \"gate_request\") then"
         , "        self.gate_taken = true"
         , "      end"
         , "      if self.gate_taken and STEPS[self.step] then"
         , "        local step = self.step"
         , "        self.step = step + 1"
         , "        self.gate_taken = false"
         , "        STEPS[step](self, api)"
         , "      end"
         , "    end"
         , "  }"
         , "}"
         ]

-- | A committed fixture's bytes, read from the repository and held to the SHA-256 the suites state.
fixtureBytes ∷ Fixture → IO ByteString
fixtureBytes fixture = do
  path ← findUpwards $
    if fixtureFile fixture == fixtureFile quadFixture
      then "samples/lua-quad/content/images/quad.png"
      else "packages/lua-engine-graphics/test-common/fixtures/pixels/" <> drop (length ("images/" ∷ String)) (fixtureFile fixture)
  bytes ← ByteString.readFile path
  when (sha256Text bytes /= fixtureSha256 fixture) $
    assertFailure (fixtureFile fixture <> " is not the committed technical fixture: SHA-256 " <> Text.unpack (sha256Text bytes))
  pure bytes

-- | The shipped @samples/lua-quad/content@, byte for byte.
shippedFiles ∷ IO Files
shippedFiles = mapM one ["hetoimasia.json", "lua/main.lua", "images/quad.png"]
  where
    one name = do
      path ← findUpwards ("samples/lua-quad/content/" <> name)
      bytes ← ByteString.readFile path
      pure (name, bytes)

-- The session -----------------------------------------------------------------------------------------------------------------

-- | A running session over the display: its composition, its display, its one target and what the roles said.
data Live = Live
  { liveName ∷ !Text
  , liveComposition ∷ !Composition
  , liveTarget ∷ !OffscreenTargetId
  , liveWarns ∷ !(TVar [Text])
  , liveEnv ∷ !Env
  }

withProgram ∷ Env → Text → Program → (Live → IO ()) → IO ()
withProgram env name program body = do
  files ← programFiles program
  withLiveSession env name files (map gateFile [1 .. length (programSteps program)]) body

-- | Run content as the roles of a real session over the production host, the production facade and the display, hand the
-- scenario the target the one window Lua opened is, and end the session by a normal stop once the scenario returned. The
-- scenario's failure is raised here after the session has ended. The scenario runs on a thread of its own, started so
-- that the capture of its failure and the stop it must still make run masked ('forkFinally'), and ended and waited for
-- on every way out of the session.
withLiveSession ∷ Env → Text → Files → [FilePath] → (Live → IO ()) → IO ()
withLiveSession env name files held scenario = do
  display ← newDisplay (envHost env)
  providerStep ← newIORef (pure ())
  sessionRef ← newIORef Nothing
  let config =
        WindowConfig
          { windowRecords = 2
          , windowStop = readIORef sessionRef >>= mapM_ (\found → requestStop found StopQuit)
          , windowFatal = \failure → readIORef sessionRef >>= mapM_ (\found → void (latchTerminalFailure found (newRoleFailure HostFailure OnEngine Presentation (fatalText failure))))
          }
  serveMain env (readIORef providerStep >>= id) $
    withComposition compositionProfile files (graphicsBackend (envGraphics env)) $ \composition control runtime → do
      forM_ held (holdReadsOf composition . Text.encodeUtf8 . Text.pack)
      withWindowProvider config (displayPort display) $ \provider → do
        writeIORef providerStep (windowMainStep provider)
        warns ← newTVarIO []
        let publisher = scenePublisherOver (graphicsTextures (envGraphics env)) provider (offscreenTargetAnswer (envHost env)) (displayUsable display)
            injection = graphicsInjection (GraphicsFacade compositionProfile (cpPipeline composition) provider publisher noPublishHooks defaultIssuedMemory)
        checkpoint ← bootCheckpointFrom compositionProfile (cpRoot composition) (cpInventory composition) >>= either (\refused → assertFailure ("boot refused: " <> show refused)) pure
        let outSink = OutputSink {sinkLine = \_ → pure (), sinkFlush = pure ()}
            errSink = OutputSink {sinkLine = \line → atomically (modifyTVar' warns (<> [line])), sinkFlush = pure ()}
        withOutput outSink errSink $ \output → do
          handle ← newEmptyMVar
          result ← newEmptyMVar
          scenarioThread ←
            forkFinally
              -- The whole of the scenario's thread is bounded, its startup waits included (the session's handle, the
              -- display's target), and names what the roles said when the bound is not met.
              ( timeout (60 * 1000000) (readMVar handle >>= \found → writeIORef sessionRef (Just found) >> atomically (displayTargets display >>= \case [one] → pure one; _ → retry) >>= \target → scenario (Live name composition target warns env)) >>= \case
                  Just () → pure ()
                  Nothing → do
                    said ← readTVarIO warns
                    assertFailure ("the scenario did not finish within 60 seconds; the roles warned " <> show said)
              )
              ( \outcome →
                  -- Masked by 'forkFinally': however the scenario ended, every read it held is let go and the session
                  -- stops normally, and the outcome reaches the example that started it.
                  (releaseAllReads composition >> (readIORef sessionRef >>= mapM_ (\found → requestStop found StopQuit)))
                    `finally` putMVar result outcome
              )
          let sessionSpec =
                SessionSpec
                  { sxProfile = compositionProfile
                  , sxCheckpoint = checkpoint
                  , sxInventory = cpInventory composition
                  , sxPool = cpPool composition
                  , sxLogger = quietLogger
                  , sxOutput = output
                  , sxClock = monotonicSource
                  , sxTimer = systemTimerBackend
                  , sxRuntime = runtime
                  , sxControl = control
                  , sxHarness = noHarness
                  , sxGraphics = Just injection
                  }
          -- However the session ends (normally, with the roles' failure returned before any window existed, or by an
          -- exception), the scenario's thread has ended and been joined before this scope does: it is told to end
          -- unconditionally and its masked handler's outcome is waited for.
          outcome ← runSession sessionSpec (putMVar handle) `finally` (killThread scenarioThread >> void (readMVar result))
          scenarioOutcome ← readMVar result
          case scenarioOutcome of
            Right () → pure ()
            Left raised
              | Just ThreadKilled ← fromException raised →
                  assertFailure ("the session ended before the scenario finished; the verdict was " <> show (outVerdict outcome) <> "; the roles failed: " <> show (outFailures outcome))
              | otherwise →
                  assertFailure (displayException raised <> "; the verdict was " <> show (outVerdict outcome) <> "; the roles failed: " <> show (outFailures outcome))
          outVerdict outcome `shouldBe` VerdictSuccess
          outFailures outcome `shouldBe` []
          outRetired outcome `shouldBe` True
  awaitGone env

-- | Everything a session made is gone: its target is unregistered and its record released, its textures retired.
awaitGone ∷ Env → IO ()
awaitGone env = do
  atomically $ do
    state ← readVulkanSceneState (envHost env)
    check (not (any isOffscreen (Map.keys (sceneWindows state))))
  atomically $ do
    reading ← graphicsReading (envGraphics env)
    check (readingLiveTextures reading == 0)
  where
    isOffscreen = \case
      KeyOffscreen _ → True
      _ → False

quietLogger ∷ Logger
quietLogger = mkLoggerWith defaultLogFilter metadata (callbackSink (\_ → pure ()))
  where
    metadata =
      MetadataProviders
        { metadataClock = pure (UTCTime (fromGregorian 2026 10 22) (secondsToDiffTime 43200))
        , metadataThread = pure "1"
        }

-- | Let Lua past its gate: the read the example held is let go, the request completes, and Lua runs the step.
releaseGate ∷ Live → Int → IO ()
releaseGate live n = releaseReadsOf (liveComposition live) (Text.encodeUtf8 (Text.pack (gateFile n)))

-- | Block, in STM, until the host has accepted this revision for the target.
awaitPublished ∷ Live → Int → IO ()
awaitPublished live revision = awaitTarget (envHost (liveEnv live)) (liveTarget live) ((== Just (fromIntegral revision)) . windowPublished)

-- | Block, in STM, until the owner has adopted this revision for the target.
awaitAdopted ∷ Live → Int → IO ()
awaitAdopted live revision = awaitTarget (envHost (liveEnv live)) (liveTarget live) ((== Just (fromIntegral revision)) . windowAdopted)

publishedNow, adoptedNow ∷ Live → IO (Maybe Int)
publishedNow live = fmap fromIntegral . (>>= windowPublished) <$> atomically (targetStanding (envHost (liveEnv live)) (liveTarget live))
adoptedNow live = fmap fromIntegral . (>>= windowAdopted) <$> atomically (targetStanding (envHost (liveEnv live)) (liveTarget live))

-- | Block until a line the roles warned begins its report with this label, and fail, naming the line, unless the report
-- is the one expected: a refusal that did not happen is a failure now, not a wait that nothing ends.
expectWarned ∷ Live → Text → Text → IO ()
expectWarned live label expected = do
  line ← atomically $ do
    seen ← readTVar (liveWarns live)
    case [found | found ← seen, label `Text.isInfixOf` found] of
      found : _ → pure found
      [] → retry
  unless ((label <> expected) `Text.isSuffixOf` line) $
    assertFailure (Text.unpack (liveName live <> ": expected the script to report " <> label <> expected <> ", it said: " <> line))

-- | Block until a line the roles warned contains this text.
awaitWarn ∷ Live → Text → IO ()
awaitWarn live wanted = atomically (readTVar (liveWarns live) >>= \seen → unless (any (Text.isInfixOf wanted) seen) retry)

-- Judging an image ---------------------------------------------------------------------------------------------------------

-- | Render the target's adopted scene for the specification's facts and judge the image. The example fails, naming every
-- fault, when anything is wrong; the evidence is recorded either way.
checkImage ∷ Env → Live → Text → CaseSpec → Int → IO () → IO Rendered
checkImage env live image caseSpec revision between = do
  result ← renderTarget env (liveTarget live) (specFacts caseSpec) between
  rendered ← either (\failure → assertFailure (Text.unpack (liveName live <> " / " <> image <> ": " <> failure))) pure result
  let faults = assess caseSpec rendered ++ [ "the image is of revision " <> tshow (renderedRevision rendered) <> ", not the expected " <> tshow revision | renderedRevision rendered /= fromIntegral revision ]
      judgement = judgeWhole (oracleFor caseSpec rendered) (renderedReadback rendered)
  retain live image caseSpec rendered judgement faults
  unless (null faults) $
    assertFailure (Text.unpack (liveName live <> " / " <> image <> ": " <> Text.intercalate "; " (take 12 faults) <> (if length faults > 12 then "; and " <> tshow (length faults - 12) <> " more" else "")))
  pure rendered
  where
    _ = env

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show

-- | The oracle over the published window-pass scene itself, with the managed target's own 'TargetSpec' as its window, and
-- the textures of the specification, premultiplied here.
oracleFor ∷ CaseSpec → Rendered → Oracle
oracleFor caseSpec rendered =
  specOracle caseSpec (renderedMetrics rendered) (renderedValid rendered) (fmap fixtureDecoded . candidateTextures caseSpec (renderedCandidate rendered)) (renderedMarks rendered)

-- | Everything wrong with an image, in the order it is checked.
assess ∷ CaseSpec → Rendered → [Text]
assess caseSpec rendered =
  renderedCopyFaults rendered
    <> [ "the target's metrics are not the specification's: " <> tshow (renderedMetrics rendered) | renderedMetrics rendered /= specMetrics caseSpec ]
    <> [ "the readback is " <> tshow (readbackWidth readback) <> "x" <> tshow (readbackHeight readback) <> ", not " <> tshow (specFramebuffer caseSpec) | (readbackWidth readback, readbackHeight readback) /= specFramebuffer caseSpec ]
    <> [ "the readback holds " <> tshow (ByteString.length (readbackBytes readback)) <> " bytes" | ByteString.length (readbackBytes readback) /= readbackWidth readback * readbackHeight readback * 4 ]
    <> map ("the published scene is not the specification's: " <>) (translationDiffs (renderedCandidate rendered) (specSnapshot caseSpec))
    <> [ "pixel " <> pixel | pixel ← judgedFailed judgement ]
    <> [ "unevaluable " <> pixel | pixel ← judgedUnevaluable judgement ]
    <> [ "the oracle determined no pixel of the image" | judgedDeterminate judgement == 0 ]
    <> [ "named " <> mismatchName m <> ": wanted " <> showTexel (mismatchWanted m) <> ", read " <> maybe "nothing" showTexel (mismatchGot m) | m ← checkNamed readback (specNamed caseSpec) ]
    <> map ("the oracle and the specification disagree: " <>) (agreesWith (oracleFor caseSpec rendered) (specNamed caseSpec))
  where
    readback = renderedReadback rendered
    judgement = judgeWhole (oracleFor caseSpec rendered) readback

-- | The evidence of one image: a line in the run's record and, when a directory is named for it, the lossless PNG and a
-- machine-readable record with their SHA-256.
retain ∷ Live → Text → CaseSpec → Rendered → Judgement → [Text] → IO ()
retain live image caseSpec rendered judgement faults = do
  let readback = renderedReadback rendered
      png = Png.rgba8 (readbackWidth readback) (readbackHeight readback) (\x y → fromMaybe' (0, 0, 0, 0) (pixelOf readback x y))
      identities = [viewIdentity (useView (spriteTexture sprite)) | sprite ← sceneSprites (graphicsContent (renderedScene rendered))]
      facts = renderedFacts rendered
      record =
        Text.unlines
          [ "{"
          , "  \"case\": " <> quoted (liveName live) <> ","
          , "  \"image\": " <> quoted image <> ","
          , "  \"specification\": " <> quoted (specLabel caseSpec) <> ","
          , "  \"revision\": " <> tshow (renderedRevision rendered) <> ","
          , "  \"target\": {\"format\": \"R8G8B8A8_SRGB\", \"framebuffer\": " <> tshow' (factsFramebuffer facts) <> ", \"logical\": " <> maybe "null" tshow' (factsLogical facts) <> ", \"scale\": " <> maybe "null" (tshow . fst) (factsScale facts) <> "},"
          , "  \"textureIdentities\": " <> tshow identities <> ","
          , "  \"completion\": " <> quoted (renderedCompletion rendered) <> ","
          , "  \"copyChecked\": true,"
          , "  \"copyFaults\": " <> tshow (length (renderedCopyFaults rendered)) <> ","
          , "  \"determinatePixels\": " <> tshow (judgedDeterminate judgement) <> ","
          , "  \"failedPixels\": " <> tshow (length (judgedFailed judgement)) <> ","
          , "  \"unevaluablePixels\": " <> tshow (length (judgedUnevaluable judgement)) <> ","
          , "  \"indeterminatePixels\": {" <> Text.intercalate ", " [quoted reason <> ": " <> tshow count | (reason, count) ← judgedIndeterminate judgement] <> "},"
          , "  \"oracleTolerance\": \"the oracle's exactness rule: 0 or 1 per channel\","
          , "  \"namedProbes\": " <> tshow (length (specNamed caseSpec)) <> ","
          , "  \"namedTolerances\": " <> tshow (Set.toList (Set.fromList [namedTolerance n | n ← specNamed caseSpec])) <> ","
          , "  \"faults\": " <> tshow (length faults) <> ","
          , "  \"readbackSha256\": " <> quoted (sha256Text (readbackBytes readback)) <> ","
          , "  \"pngSha256\": " <> quoted (sha256Text png)
          , "}"
          ]
      line =
        "Lua offscreen pixels / "
          <> liveName live
          <> " / "
          <> image
          <> ": revision "
          <> tshow (renderedRevision rendered)
          <> ", "
          <> tshow (specFramebuffer caseSpec)
          <> ", "
          <> tshow (judgedDeterminate judgement)
          <> " determinate pixels judged, "
          <> tshow (sum (map snd (judgedIndeterminate judgement)))
          <> " indeterminate, "
          <> tshow (length (specNamed caseSpec))
          <> " named probes, "
          <> (if null faults then "no fault" else tshow (length faults) <> " faults")
          <> ", png sha256 "
          <> sha256Text png
  evidence (liveEnv live) line
  directory ← lookupEnv "HETOIMASIA_VALIDATION_EVIDENCE"
  forM_ directory $ \place → do
    let folder = place </> "lua-offscreen-pixels"
        stem = Text.unpack (slug (liveName live) <> "--" <> slug image)
    createDirectoryIfMissing True folder
    ByteString.writeFile (folder </> stem <> ".png") png
    Text.writeFile (folder </> stem <> ".json") record
  where
    fromMaybe' fallback = maybe fallback id
    tshow' ∷ (Show a, Show b) ⇒ (a, b) → Text
    tshow' (a, b) = "[" <> tshow a <> ", " <> tshow b <> "]"
    quoted text = "\"" <> Text.concatMap escape text <> "\""
    escape c = case c of
      '"' → "\\\""
      '\\' → "\\\\"
      _ → Text.singleton c
    slug = Text.map (\c → if c `elem` (['a' .. 'z'] <> ['0' .. '9']) then c else '-') . Text.toLower
