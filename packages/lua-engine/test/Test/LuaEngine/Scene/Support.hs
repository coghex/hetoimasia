{-# LANGUAGE OverloadedStrings #-}

-- | What the scene examples share: the texture session of "Test.LuaEngine.Texture.Support" (a real
-- content root, pool, pipeline and decoder, a gated fake backend, real supervised Lua owners with their
-- own lease scopes) with two bindings the example adds in a namespace of its own, and the Lua that
-- drives them.
--
-- @scene.publish@ is the engine's 'scenePublishBinding' over a /controlled sink/ the example owns: it
-- records every prepared scene it was handed and nothing else, so a refused candidate is seen to have
-- reached no sink. @scene.consume@ stands for the later publication (LFE-20) and is the example's
-- scaffolding, not an API: it takes the last scene the sink recorded and asks the calling instance's
-- leases for every texture it names, so an example can show that a scene prepared earlier is not a grant.
--
-- Evidence from the real adapter and evidence that is injected are kept apart by name: the backend and
-- the sink are the example's.
module Test.LuaEngine.Scene.Support
  ( -- * The session
    Sink
  , newSink
  , published
  , publishedCount
  , sceneConfig
  , sceneConfigWith
  , layout
  , withReady
  , withReadyUnder
  , sceneProfile

    -- * Textures
  , acquire
  , acquireRequest

    -- * Running Lua in an instance
  , eval
  , evalOk

    -- * Re-exports
  , module Test.LuaEngine.Texture.Support
  ) where

import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.LuaEngine.Profile (ByteLimit (..), CountLimit (..), Profile)
import Hetoimasia.LuaEngine.Scene
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Value
import Test.Hspec (shouldBe, shouldSatisfy)
import Test.LuaEngine.Request.Profiles (smaller)
import Test.LuaEngine.Texture.Contract (small)
import Test.LuaEngine.Texture.Png (opaque, rgba8)
import Test.LuaEngine.Texture.Support

-- | The prepared scenes the controlled sink was handed, oldest last.
newtype Sink = Sink (IORef [PreparedScene])

newSink ∷ IO Sink
newSink = Sink <$> newIORef []

published ∷ Sink → IO [PreparedScene]
published (Sink ref) = readIORef ref

publishedCount ∷ Sink → IO Int
publishedCount sink = length <$> published sink

-- | The images the examples load: 8 by 4 and 16 by 16 texels, and a uniform opaque sRGB grey of 128.
layout ∷ Layout
layout = Layout [("a.png", opaque 8 4), ("b.png", opaque 8 4), ("c.png", opaque 16 16), ("grey.png", rgba8 8 4 (\_ _ → (128, 128, 128, 255)))]

-- | A session configuration over this profile whose VMs add the scene namespace, over this sink.
sceneConfig ∷ Profile → Layout → Sink → Config
sceneConfig profile files sink = sceneConfigWith profile files sink (record sink)
  where
    record (Sink ref) scene = atomicModifyIORef' ref (\held → (held <> [scene], ()))

-- | The same, with the action the sink takes for each prepared scene.
sceneConfigWith ∷ Profile → Layout → Sink → (PreparedScene → IO ()) → Config
sceneConfigWith profile files sink action = (config profile files) {cfgExtra = extra}
  where
    limits = either (\refused → error ("scene limits refused: " <> show refused)) id (sceneLimits profile)
    extra vm = [namespace "scene" [scenePublishBinding "publish" limits (vmLeases vm) action, consuming, probing vm]]
    -- The later publication's first act, as the example's scaffold: ask the calling instance's leases for
    -- every texture of the last scene the sink recorded, and say whether each is still the texture the
    -- scene was prepared against.
    consuming =
      recoverableRefusals . stateOperation "consume_last" [] [SText] $ \_ →
        published sink >>= \case
          [] → pure [VText "no scene"]
          scenes → do
            let scene = last scenes
            answers ← traverse (revalidate scene) (textureUses scene)
            pure [VText (Text.intercalate "; " answers)]
    -- Prepare a one-sprite scene of a capability the example forges, as the calling instance, and say what
    -- preparation answered. A capability the script could not make is built here, in Haskell.
    probing vm =
      recoverableRefusals . stateOperation "probe" [SText, SInteger] [SText] $ \arguments → case arguments of
        [VText typeName, VInteger key] → do
          let candidate =
                VRecord
                  [ ("clear", VRecord [("r", VInteger 0), ("g", VInteger 0), ("b", VInteger 0)])
                  , ("sprites", VList [VRecord [("texture", VCapability (capability typeName (fromIntegral key))), ("x", VInteger 1), ("y", VInteger 1), ("width", VInteger 1), ("height", VInteger 1)]])
                  ]
          found ← prepareScene limits (vmLeases vm) candidate
          pure [VText (either refusalReasonText (const "prepared") found)]
        _ → pure []
    revalidate scene use =
      withTextureOr (preparedOwner scene) (useLease use) (\why → pure ("refused: " <> why)) $ \view →
        pure (if view == useView use then "fresh" else "changed")

-- | An example over the small profile with one VM, one driver instance @i@ that owns the ready
-- texture @a@ (from @a.png@, 8 by 4 texels), and the sink. Answers the identity the backend gave it.
withReady ∷ (Session → Vm → Sink → Word64 → IO a) → IO a
withReady = withReadyUnder small

-- | The same, over this profile.
withReadyUnder ∷ Profile → (Session → Vm → Sink → Word64 → IO a) → IO a
withReadyUnder profile body = do
  sink ← newSink
  withSession (sceneConfig profile layout sink) $ \session _ runtime → do
    vm ← startVm session runtime "scene" OnArrival
    admitDriver session vm "i"
    identity ← acquire session vm "i" "a" "a.png"
    body session vm sink identity

-- | The small texture profile of the texture examples (32 by 32 texels at most, four textures to an instance)
-- with these counts and byte limits changed, validated: for the examples that shrink a scene limit.
sceneProfile ∷ [(CountLimit, Word64)] → [(ByteLimit, Word64)] → Profile
sceneProfile countChanges byteChanges = smaller (override countChanges [(PngPixels, 1024), (PngAxisMaximum, 32)]) (override byteChanges base)
  where
    base =
      [ (PngEncodedBytes, 65536)
      , (PngInflatedScanlineBytes, 65536)
      , (PngPipelineWorkspaceBytes, 1048576)
      , (TextureBytesPerUiInstance, 16384)
      , (TextureBytesPerSession, 32768)
      ]
    override changes defaults = changes <> [entry | entry@(limit, _) ← defaults, limit `notElem` map fst changes]

-- | Start a texture request under this key for the instance, finish its upload, and take the success
-- under the same key. The texture handle is then the instance's @self.ts[key]@. Answers the identity the
-- backend registered it under.
acquire ∷ Session → Vm → Text → Text → Text → IO Word64
acquire session vm name key path = do
  -- Counted before the request starts: its upload can arrive before the script's acknowledgement does.
  count ← uploadsSeen (ssFake session)
  commandWith session vm name "start" key (Just (load path))
  lineStarting session (name <> " start " <> key <> " ") >>= (`shouldBe` (name <> " start " <> key <> " started"))
  awaitUploads (ssFake session) (count + 1)
  identity ← uploadN (ssFake session) count >>= finishUpload (ssFake session)
  command session vm name "wait_take" key
  line ← lineStarting session (name <> " wait_take " <> key <> " ")
  line `shouldSatisfy` Text.isInfixOf "status=success"
  pure identity

-- | Start a texture request that stays pending (its upload is not finished): the instance keeps the
-- request handle under the key, and no texture exists yet.
acquireRequest ∷ Session → Vm → Text → Text → Text → IO ()
acquireRequest session vm name key path = do
  commandWith session vm name "start" key (Just (load path))
  lineStarting session (name <> " start " <> key <> " ") >>= (`shouldBe` (name <> " start " <> key <> " started"))

-- | Run this Lua in the instance, as a function of @self@, the key and the driver's formatter, and
-- answer what it returned, shown. A chunk that raises fails the instance, so an example that expects a
-- refusal catches it with @pcall@. The key makes the answer's line unique: use each once.
eval ∷ Session → Vm → Text → Text → Text → IO Text
eval session vm name key code = do
  commandWith session vm name "eval" key (Just (load code))
  line ← lineStarting session (name <> " eval " <> key <> " ")
  pure (Text.drop (Text.length (name <> " eval " <> key <> " ")) line)

-- | The same, expecting the chunk to return exactly this.
evalOk ∷ Session → Vm → Text → Text → Text → Text → IO ()
evalOk session vm name key code expected = eval session vm name key code >>= (`shouldBe` expected)
