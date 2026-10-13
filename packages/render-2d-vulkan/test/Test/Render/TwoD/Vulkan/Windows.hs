-- | Texture registration, the swap rule, publication, holds and releases
-- (R2D-8), over the headless native layer and a coordinated stand-in for the
-- window host.
--
-- The stand-in host publishes scenes per window with rising revisions and
-- queues the release actions it is asked for. The example plays the owner:
-- it adopts a revision (running the adapter's adoption hook with the scene
-- the host published), releases it, and runs the queued release actions when
-- it says the host's barrier is met. Registration, swaps and releases go
-- through the backend's real table over the stand-in recording, so what an
-- example reads of "released in the table" is the table's own mapping.
--
-- __Where the expected values come from.__ Never from the code under test:
-- marks are the ones each example chose or the image computed by its bytes,
-- holds are counted by hand from the revisions adopted, and a handle's
-- resolution is read from the table's own mapping.
module Test.Render.TwoD.Vulkan.Windows (spec) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (AsyncException (ThreadKilled), throwIO, try)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32)
import Hetoimasia.Asset.Image (DecodedImage (..), TexelFormat (..))
import Hetoimasia.GPU.Vulkan.Native.Recording (Refusal (..), validateRingSize)
import Hetoimasia.GPU.Vulkan.Native.TextureTable (LookupEntry (..), TableView (..), readTable, validateTableConfig)
import Hetoimasia.Math.Affine2 (fromColumns)
import Hetoimasia.Math.Vector (V2 (..))
import qualified Hetoimasia.Render.Api.Texture as Api
import qualified Hetoimasia.Render.Api.Texture.Backend as ApiBackend
import Hetoimasia.Render.TwoD.DrawPlan (isMarkedCutout)
import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Target.Backend (targetRef)
import qualified Hetoimasia.Render.TwoD.Validation as Validation
import qualified Hetoimasia.Render.TwoD.Vulkan as Render
import Hetoimasia.Render.TwoD.Vulkan.Textures
import Hetoimasia.Render.TwoD.Vulkan.Window
import Numeric.Natural (Natural)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Render.TwoD.Vulkan.StandIn

spec ∷ Spec
spec = describe "Windows" $ do
  marksSpec
  swapSpec
  publishSpec
  holdsSpec
  releaseSpec
  frameSpec

-- ---------------------------------------------------------------------------
-- The environment

-- | A release action the stand-in host was asked to queue, and whether it asked
-- for the barrier (the request) or nothing (the plain owner action).
data Queued = Queued !Bool ReleaseBody

data Fake = Fake
  { fakePublished ∷ !(TVar [(Int, Natural, Scene2D)])
  , fakeQueued ∷ !(TVar [Queued])
  , fakeRefusing ∷ !(TVar Bool)
    -- ^ Whether the host refuses the release requests it is asked for.
  , fakeCapacity ∷ !(TVar (Maybe Int))
    -- ^ How many actions the host's queue holds, when bounded.
  , fakeCancel ∷ !(TVar Bool)
    -- ^ Whether the next request is interrupted by a cancellation.
  , fakeCancelPlain ∷ !(TVar Bool)
    -- ^ Whether the next barrier-free action is.
  , fakeAsked ∷ !(TVar (Int, Int))
    -- ^ How many actions were admitted with a barrier and without one.
  }

data Env = Env
  { envRig ∷ !Rig
  , envRenderer ∷ !Render.Renderer
  , envTextures ∷ !Textures
  , envAdapter ∷ !(Adapter Int)
  , envFake ∷ !Fake
  }

-- | A stand-in host that holds these windows.
newFake ∷ [Int] → IO (Host Int, Fake)
newFake windows = do
  revisions ← newTVarIO (Map.fromList [(window, 0) | window ← windows])
  published ← newTVarIO []
  queued ← newTVarIO []
  refusing ← newTVarIO False
  capacity ← newTVarIO Nothing
  asked ← newTVarIO (0, 0)
  cancel ← newTVarIO False
  cancelPlain ← newTVarIO False
  let publish window scene = atomically $ do
        known ← Map.lookup window <$> readTVar revisions
        case known of
          Nothing → pure HostWindowUnknown
          Just revision → do
            modifyTVar' revisions (Map.insert window (revision + 1))
            modifyTVar' published (<> [(window, revision + 1, scene)])
            pure (HostPublished (revision + 1))
      admit ∷ Bool → ReleaseBody → IO (Either Text ())
      admit barrier body = atomically $ do
        refused ← readTVar refusing
        room ← readTVar capacity
        held ← length <$> readTVar queued
        if refused || maybe False (held >=) room
          then pure (Left "the host's queue is full")
          else do
            modifyTVar' queued (<> [Queued barrier body])
            modifyTVar' asked (\(b, p) → if barrier then (b + 1, p) else (b, p + 1))
            pure (Right ())
      request ∷ ReleaseBody → IO (Either Text ())
      request body = do
        interrupted ← atomically (readTVar cancel <* writeTVar cancel False)
        if interrupted then throwIO ThreadKilled else admit True body
      plain ∷ ReleaseBody → IO (Either Text ())
      plain body = do
        interrupted ← atomically (readTVar cancelPlain <* writeTVar cancelPlain False)
        if interrupted then throwIO ThreadKilled else admit False body
  pure (Host publish request plain, Fake published queued refusing capacity cancel cancelPlain asked)

withEnv ∷ [Int] → (Env → IO a) → IO a
withEnv windows action = do
  rig ← newRig
  renderer ←
    newRenderer
      rig
      Render.Configuration
        { Render.configurationRing = either (error . show) id (validateRingSize (64 * 1024))
        , Render.configurationTable = either (error . show) id (validateTableConfig 16 8 4)
        }
  resetJournal rig
  textures ← newTextures
  (host, fake) ← newFake windows
  adapter ← newAdapter host textures
  action (Env rig renderer textures adapter fake)

-- | Four texels of this colour.
bytesOf ∷ Word32 → ByteString
bytesOf shade = ByteString.concat (replicate 4 (ByteString.pack [fromIntegral shade, 0, 0, 255]))

-- | A decoded image whose mark the example states.
decodedWith ∷ Bool → DecodedImage
decodedWith binary = DecodedImage TexelRgba8Linear 2 2 [bytesOf 1] binary

-- | Make, upload and register a texture.
registered ∷ Env → Word32 → Bool → MarkPolicy → IO Api.TextureHandle
registered env shade binary policy = do
  image ← uploadedTexture (envRig env) (bytesOf shade)
  registerTexture (builders (envRig env)) (envTextures env) image (decodedWith binary) policy >>= either (fail . show) pure

-- | A window snapshot of one UI layer naming these textures.
windowSnapshot ∷ [Api.TextureHandle] → Snapshot
windowSnapshot handles =
  Snapshot [Pass WindowTarget (ClearColour 0 0 0 1) [View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 16 16)) defaultViewSettings [UiLayer (map sprite handles)]]]

sprite ∷ Api.TextureHandle → Instance
sprite handle =
  Instance
    { instanceTransform = fromColumns (V2 4 0) (V2 0 4) (V2 0 0)
    , instanceUv = UvRect 0 0 1 1
    , instanceTexture = handle
    , instanceDepthKey = 0
    , instanceTint = Tint 255 255 255 255
    , instanceSampler = SamplerDefault
    , instanceTranslucent = False
    , instanceAdditive = False
    , instanceClip = 0
    , instanceMaterial = 0
    }

-- | Publish, expecting acceptance.
publishOk ∷ Env → Int → [Api.TextureHandle] → IO Natural
publishOk env window handles = publish2DSnapshot (envAdapter env) window (windowSnapshot handles) >>= either (fail . ("refused: " <>) . show) pure

-- | The owner adopts this revision of the window: the adapter's hook with the
-- scene the host published.
adopt ∷ Env → Int → Natural → IO ()
adopt env window revision = do
  published ← readTVarIO (fakePublished (envFake env))
  case [scene | (w, r, scene) ← published, w == window, r == revision] of
    scene : _ → adapterAdopted (envAdapter env) window revision scene
    [] → expectationFailure ("revision " <> show revision <> " of window " <> show window <> " was never published")

-- | The owner has released this revision: its last recording is over.
releaseRevision ∷ Env → Int → Natural → IO ()
releaseRevision env = adapterReleased (envAdapter env)

-- | The host's barrier is met: run every release action it queued, in order,
-- on the owner's thread (here, the example's), with the real builders.
runQueued ∷ Env → IO [Either Refusal ()]
runQueued env = do
  queued ← readTVarIO (fakeQueued (envFake env))
  atomically (writeTVar (fakeQueued (envFake env)) [])
  mapM (\(Queued _ body) → body (builders (envRig env))) queued

-- | The host runs only the first queued action, on the owner's thread.
runNext ∷ Env → IO [Either Refusal ()]
runNext env = do
  queued ← readTVarIO (fakeQueued (envFake env))
  case queued of
    [] → pure []
    Queued _ body : rest → do
      atomically (writeTVar (fakeQueued (envFake env)) rest)
      (: []) <$> body (builders (envRig env))

-- | Whether the table resolves this handle to its own slot now.
resolves ∷ Env → Api.TextureHandle → IO Bool
resolves env handle =
  atomically (readTable (rigRecording (envRig env))) >>= \case
    Nothing → pure False
    Just view →
      pure $ case Map.lookup (ApiBackend.handleIndex handle) (tableViewMapping view) of
        Just entry → entryGeneration entry == ApiBackend.handleGeneration handle && entryGeneration entry /= 0
        Nothing → False

-- ---------------------------------------------------------------------------
-- Marks

marksSpec ∷ Spec
marksSpec = describe "registering with a mark" $ do
  it "defaults the mark to the decoded image's computed one and stores it with the handle" $
    withEnv [1] $ \env → do
      binary ← registered env 1 True DefaultMark
      translucent ← registered env 2 False DefaultMark
      registeredMark (envTextures env) binary >>= (`shouldBe` Just True)
      registeredMark (envTextures env) translucent >>= (`shouldBe` Just False)

  it "stores an explicit override over what the image computes, either way" $
    withEnv [1] $ \env → do
      forcedOff ← registered env 1 True (OverrideMark False)
      forcedOn ← registered env 2 False (OverrideMark True)
      registeredMark (envTextures env) forcedOff >>= (`shouldBe` Just False)
      registeredMark (envTextures env) forcedOn >>= (`shouldBe` Just True)

  it "exposes the marks of the registered handles, and only the marked ones are cutout-safe" $
    withEnv [1] $ \env → do
      marked ← registered env 1 True DefaultMark
      unmarked ← registered env 2 False DefaultMark
      marks ← registeredMarks (envTextures env)
      (isMarkedCutout marks marked, isMarkedCutout marks unmarked) `shouldBe` (True, False)

  it "keys a mark by the complete handle, so a reused index has its own mark and the old handle keeps none" $
    withEnv [1] $ \env → do
      old ← registered env 1 True DefaultMark
      releaseTextureNow (builders (envRig env)) (envTextures env) old >>= either (fail . show) pure
      new ← registered env 2 False DefaultMark
      new `shouldSatisfy` (/= old)
      registeredMark (envTextures env) old >>= (`shouldBe` Nothing)
      registeredMark (envTextures env) new >>= (`shouldBe` Just False)
      marks ← registeredMarks (envTextures env)
      (isMarkedCutout marks old, isMarkedCutout marks new) `shouldBe` (False, False)

-- ---------------------------------------------------------------------------
-- Swaps

swapSpec ∷ Spec
swapSpec = describe "swapping under the mark rule" $ do
  it "refuses a replacement whose computed mark differs, naming both marks, and changes nothing" $
    withEnv [1] $ \env → do
      handle ← registered env 1 True DefaultMark
      replacement ← uploadedTexture (envRig env) (bytesOf 9)
      answer ← swapTexture (builders (envRig env)) (envTextures env) handle replacement (decodedWith False) RefuseMarkChange
      either Just (const Nothing) answer `shouldBe` Just (MarkMismatch True False)
      registeredMark (envTextures env) handle >>= (`shouldBe` Just True)
      -- No swap was asked of the table, and the handle still shows its image.
      view ← atomically (readTable (rigRecording (envRig env)))
      fmap tableViewSwaps view `shouldBe` Just []
      resolves env handle >>= (`shouldBe` True)

  it "accepts the same mark, and a different one when the caller keeps the registered mark, which stays" $
    withEnv [1] $ \env → do
      handle ← registered env 1 True DefaultMark
      same ← uploadedTexture (envRig env) (bytesOf 8)
      first ← swapTexture (builders (envRig env)) (envTextures env) handle same (decodedWith True) RefuseMarkChange
      either (const False) (const True) first `shouldBe` True
      differing ← uploadedTexture (envRig env) (bytesOf 9)
      second ← swapTexture (builders (envRig env)) (envTextures env) handle differing (decodedWith False) KeepRegisteredMark
      either (const False) (const True) second `shouldBe` True
      registeredMark (envTextures env) handle >>= (`shouldBe` Just True)

  it "refuses a swap of a handle never registered or already released, before the table is asked" $
    withEnv [1] $ \env → do
      handle ← registered env 1 True DefaultMark
      replacement ← uploadedTexture (envRig env) (bytesOf 9)
      let stranger = ApiBackend.textureHandle 12 1
      stray ← swapTexture (builders (envRig env)) (envTextures env) stranger replacement (decodedWith True) RefuseMarkChange
      either Just (const Nothing) stray `shouldBe` Just (TextureUnknown stranger)
      _ ← markReleased (envTextures env) handle
      gone ← swapTexture (builders (envRig env)) (envTextures env) handle replacement (decodedWith True) RefuseMarkChange
      either Just (const Nothing) gone `shouldBe` Just (TextureReleased handle)
      view ← atomically (readTable (rigRecording (envRig env)))
      fmap tableViewSwaps view `shouldBe` Just []

-- ---------------------------------------------------------------------------
-- Publication

publishSpec ∷ Spec
publishSpec = describe "publishing a snapshot" $ do
  it "publishes a valid window snapshot, answering the window's revision, rising for each acceptance" $
    withEnv [1, 2] $ \env → do
      handle ← registered env 1 True DefaultMark
      first ← publishOk env 1 [handle]
      second ← publishOk env 1 [handle]
      other ← publishOk env 2 [handle]
      (first, second, other) `shouldBe` (1, 2, 1)

  it "refuses an invalid snapshot with validation's reasons" $
    withEnv [1] $ \env → do
      answer ← publish2DSnapshot (envAdapter env) 1 (Snapshot [Pass WindowTarget (ClearColour 2 0 0 1) []])
      case answer of
        Left (SnapshotInvalid (reason :| _)) → Validation.refusalReason reason `shouldBe` Validation.ClearColourInvalid
        other → expectationFailure ("expected validation's reasons, found " <> show other)

  it "refuses a snapshot holding an offscreen pass, naming the pass, an empty one and one holding two window passes" $
    withEnv [1] $ \env → do
      let offscreen = Pass (OffscreenTarget (targetRef 1 1)) (ClearColour 0 0 0 1) []
          window = Pass WindowTarget (ClearColour 0 0 0 1) []
      publish2DSnapshot (envAdapter env) 1 (Snapshot [window]) >>= (`shouldBe` Right 1)
      publish2DSnapshot (envAdapter env) 1 (Snapshot [offscreen, window]) >>= (`shouldBe` Left (OffscreenPassHeld 0))
      publish2DSnapshot (envAdapter env) 1 (Snapshot [offscreen]) >>= (`shouldBe` Left (OffscreenPassHeld 0))
      publish2DSnapshot (envAdapter env) 1 (Snapshot []) >>= (`shouldBe` Left NoWindowPass)
      -- A second window pass is validation's refusal, with its reason.
      publish2DSnapshot (envAdapter env) 1 (Snapshot [window, window]) >>= \case
        Left (SnapshotInvalid reasons) → map Validation.refusalReason (toList reasons) `shouldSatisfy` elem Validation.MultipleWindowPasses
        other → expectationFailure ("expected validation's reasons, found " <> show other)
      -- Nothing refused was published.
      length <$> readTVarIO (fakePublished (envFake env)) >>= (`shouldBe` 1)

  it "refuses a snapshot that references a texture whose release was requested, naming it, while another publishes" $
    withEnv [1] $ \env → do
      kept ← registered env 1 True DefaultMark
      dropped ← registered env 2 True DefaultMark
      release2DTexture (envAdapter env) dropped >>= (`shouldBe` Right ())
      publish2DSnapshot (envAdapter env) 1 (windowSnapshot [kept, dropped]) >>= (`shouldBe` Left (TextureReleasedInSnapshot dropped))
      publish2DSnapshot (envAdapter env) 1 (windowSnapshot [kept]) >>= (`shouldBe` Right 1)

  it "keeps a released handle refused after its index is reused, while the new generation publishes" $
    withEnv [1] $ \env → do
      old ← registered env 1 True DefaultMark
      release2DTexture (envAdapter env) old >>= (`shouldBe` Right ())
      _ ← runQueued env
      new ← registered env 2 True DefaultMark
      publish2DSnapshot (envAdapter env) 1 (windowSnapshot [old]) >>= (`shouldBe` Left (TextureReleasedInSnapshot old))
      publish2DSnapshot (envAdapter env) 1 (windowSnapshot [new]) >>= (`shouldBe` Right 1)

  it "names a window the host does not hold" $
    withEnv [1] $ \env → do
      publish2DSnapshot (envAdapter env) 7 (windowSnapshot []) >>= (`shouldBe` Left PublishWindowUnknown)

-- ---------------------------------------------------------------------------
-- Holds

holdsSpec ∷ Spec
holdsSpec = describe "holds taken on adoption and dropped on release" $ do
  it "takes a hold on every texture an adopted revision names, once however often it is named, and drops it on release" $
    withEnv [1] $ \env → do
      a ← registered env 1 True DefaultMark
      b ← registered env 2 True DefaultMark
      revision ← publishOk env 1 [a, a, a, b]
      adopt env 1 revision
      (,) <$> textureHolds (envAdapter env) a <*> textureHolds (envAdapter env) b >>= (`shouldBe` (1, 1))
      releaseRevision env 1 revision
      (,) <$> textureHolds (envAdapter env) a <*> textureHolds (envAdapter env) b >>= (`shouldBe` (0, 0))

  it "counts a texture two windows share twice, and drops each window's hold on its own" $
    withEnv [1, 2] $ \env → do
      shared ← registered env 1 True DefaultMark
      one ← publishOk env 1 [shared]
      two ← publishOk env 2 [shared]
      adopt env 1 one
      adopt env 2 two
      textureHolds (envAdapter env) shared >>= (`shouldBe` 2)
      releaseRevision env 2 two
      textureHolds (envAdapter env) shared >>= (`shouldBe` 1)
      releaseRevision env 1 one
      textureHolds (envAdapter env) shared >>= (`shouldBe` 0)

  it "keeps a superseded revision's hold until its own release, beside the newer revision's" $
    withEnv [1] $ \env → do
      a ← registered env 1 True DefaultMark
      b ← registered env 2 True DefaultMark
      first ← publishOk env 1 [a]
      second ← publishOk env 1 [a, b]
      adopt env 1 first
      adopt env 1 second
      (,) <$> textureHolds (envAdapter env) a <*> textureHolds (envAdapter env) b >>= (`shouldBe` (2, 1))
      -- The first is superseded, but its last recording is not over yet.
      releaseRevision env 1 first
      (,) <$> textureHolds (envAdapter env) a <*> textureHolds (envAdapter env) b >>= (`shouldBe` (1, 1))

  it "drops every hold of a window the host reports ended, each revision released on its own" $
    withEnv [1] $ \env → do
      a ← registered env 1 True DefaultMark
      first ← publishOk env 1 [a]
      second ← publishOk env 1 [a]
      adopt env 1 first
      adopt env 1 second
      mapM_ (releaseRevision env 1) [first, second]
      textureHolds (envAdapter env) a >>= (`shouldBe` 0)

-- ---------------------------------------------------------------------------
-- Release

releaseSpec ∷ Spec
releaseSpec = describe "releasing a texture behind the host's barrier" $ do
  it "marks the texture released at once and queues the host's request, releasing nothing in the table until it runs" $
    withEnv [1] $ \env → do
      handle ← registered env 1 True DefaultMark
      release2DTexture (envAdapter env) handle >>= (`shouldBe` Right ())
      atomically (isReleased (envTextures env) handle) >>= (`shouldBe` True)
      pendingReleases (envAdapter env) >>= (`shouldBe` Set.singleton handle)
      length <$> readTVarIO (fakeQueued (envFake env)) >>= (`shouldBe` 1)
      resolves env handle >>= (`shouldBe` True)

  it "refuses the release of a handle never registered, and of one whose release has run" $
    withEnv [1] $ \env → do
      handle ← registered env 1 True DefaultMark
      release2DTexture (envAdapter env) handle >>= (`shouldBe` Right ())
      _ ← runQueued env
      release2DTexture (envAdapter env) handle >>= (`shouldBe` Left (ReleaseUnknown handle))
      let stranger = ApiBackend.textureHandle 12 1
      release2DTexture (envAdapter env) stranger >>= (`shouldBe` Left (ReleaseUnknown stranger))

  it "repeats the request when a handle whose release is pending is released again, and releases once however many ran" $
    withEnv [1] $ \env → do
      handle ← registered env 1 True DefaultMark
      release2DTexture (envAdapter env) handle >>= (`shouldBe` Right ())
      release2DTexture (envAdapter env) handle >>= (`shouldBe` Right ())
      runQueued env >>= (`shouldBe` [Right (), Right ()])
      resolves env handle >>= (`shouldBe` False)
      pendingReleases (envAdapter env) >>= (`shouldBe` Set.empty)

  it "keeps a texture marked released and pending when the host refused the request, which asking again repeats" $
    withEnv [1] $ \env → do
      handle ← registered env 1 True DefaultMark
      atomically (writeTVar (fakeRefusing (envFake env)) True)
      release2DTexture (envAdapter env) handle >>= (`shouldBe` Left (ReleaseRequestRefused "the host's queue is full"))
      atomically (isReleased (envTextures env) handle) >>= (`shouldBe` True)
      pendingReleases (envAdapter env) >>= (`shouldBe` Set.singleton handle)
      publish2DSnapshot (envAdapter env) 1 (windowSnapshot [handle]) >>= (`shouldBe` Left (TextureReleasedInSnapshot handle))
      length <$> readTVarIO (fakeQueued (envFake env)) >>= (`shouldBe` 0)
      atomically (writeTVar (fakeRefusing (envFake env)) False)
      release2DTexture (envAdapter env) handle >>= (`shouldBe` Right ())
      runQueued env >>= (`shouldBe` [Right ()])
      resolves env handle >>= (`shouldBe` False)

  it "releases at once, once the barrier is met, a texture no adopted revision holds" $
    withEnv [1] $ \env → do
      handle ← registered env 1 True DefaultMark
      release2DTexture (envAdapter env) handle >>= (`shouldBe` Right ())
      runQueued env >>= (`shouldBe` [Right ()])
      resolves env handle >>= (`shouldBe` False)
      pendingReleases (envAdapter env) >>= (`shouldBe` Set.empty)
      registeredMark (envTextures env) handle >>= (`shouldBe` Nothing)

  it "keeps a texture rendering while an adopted snapshot shows it, and releases it in the table only after a snapshot without it is adopted and the shown one released" $
    withEnv [1] $ \env → do
      handle ← registered env 1 True DefaultMark
      showing ← publishOk env 1 [handle]
      adopt env 1 showing
      release2DTexture (envAdapter env) handle >>= (`shouldBe` Right ())
      -- The barrier is met, but the adopted snapshot still shows it.
      runQueued env >>= (`shouldBe` [Right ()])
      resolves env handle >>= (`shouldBe` True)
      textureHolds (envAdapter env) handle >>= (`shouldBe` 1)
      pendingReleases (envAdapter env) >>= (`shouldBe` Set.singleton handle)
      -- A snapshot without it is published, adopted and the first released.
      without ← publishOk env 1 []
      adopt env 1 without
      releaseRevision env 1 showing
      runQueued env >>= (`shouldBe` [Right ()])
      resolves env handle >>= (`shouldBe` False)
      pendingReleases (envAdapter env) >>= (`shouldBe` Set.empty)

  it "lets a snapshot accepted before the release be adopted and hold the texture, however late, and refuses one offered after" $
    withEnv [1] $ \env → do
      handle ← registered env 1 True DefaultMark
      accepted ← publishOk env 1 [handle]
      release2DTexture (envAdapter env) handle >>= (`shouldBe` Right ())
      publish2DSnapshot (envAdapter env) 1 (windowSnapshot [handle]) >>= (`shouldBe` Left (TextureReleasedInSnapshot handle))
      -- The owner takes the accepted revision only now.
      adopt env 1 accepted
      textureHolds (envAdapter env) handle >>= (`shouldBe` 1)
      runQueued env >>= (`shouldBe` [Right ()])
      resolves env handle >>= (`shouldBe` True)
      without ← publishOk env 1 []
      adopt env 1 without
      releaseRevision env 1 accepted
      runQueued env >>= (`shouldBe` [Right ()])
      resolves env handle >>= (`shouldBe` False)

  it "waits for every window's hold on a shared texture before releasing it" $
    withEnv [1, 2] $ \env → do
      shared ← registered env 1 True DefaultMark
      one ← publishOk env 1 [shared]
      two ← publishOk env 2 [shared]
      adopt env 1 one
      adopt env 2 two
      release2DTexture (envAdapter env) shared >>= (`shouldBe` Right ())
      -- Both windows move on; the first window's old revision is released alone.
      oneAfter ← publishOk env 1 []
      adopt env 1 oneAfter
      releaseRevision env 1 one
      _ ← runQueued env
      resolves env shared >>= (`shouldBe` True)
      twoAfter ← publishOk env 2 []
      adopt env 2 twoAfter
      releaseRevision env 2 two
      _ ← runQueued env
      resolves env shared >>= (`shouldBe` False)

  it "releases when the last holding window ends, its revisions released with it" $
    withEnv [1] $ \env → do
      handle ← registered env 1 True DefaultMark
      showing ← publishOk env 1 [handle]
      adopt env 1 showing
      release2DTexture (envAdapter env) handle >>= (`shouldBe` Right ())
      _ ← runQueued env
      resolves env handle >>= (`shouldBe` True)
      -- The window closes: the host reports its revision released.
      releaseRevision env 1 showing
      _ ← runQueued env
      resolves env handle >>= (`shouldBe` False)

  it "queues the release after the barrier was met with no barrier of its own, so nothing that appeared since can delay it" $
    withEnv [1] $ \env → do
      handle ← registered env 1 True DefaultMark
      showing ← publishOk env 1 [handle]
      adopt env 1 showing
      release2DTexture (envAdapter env) handle >>= (`shouldBe` Right ())
      _ ← runQueued env
      -- One request, with its barrier; the adopted snapshot held the texture.
      readTVarIO (fakeAsked (envFake env)) >>= (`shouldBe` (1, 0))
      releaseRevision env 1 showing
      -- The rest was asked for with no barrier at all.
      readTVarIO (fakeAsked (envFake env)) >>= (`shouldBe` (1, 1))
      _ ← runQueued env
      resolves env handle >>= (`shouldBe` False)

  it "keeps a texture whose follow-up the host's full queue refused, and queues it again as room is made, one action at a time" $
    withEnv [1] $ \env → do
      first ← registered env 1 True DefaultMark
      second ← registered env 2 True DefaultMark
      showing ← publishOk env 1 [first, second]
      adopt env 1 showing
      mapM_ (\handle → release2DTexture (envAdapter env) handle >>= (`shouldBe` Right ())) [first, second]
      _ ← runQueued env
      -- Room for one action only when the showing snapshot is released.
      atomically (writeTVar (fakeCapacity (envFake env)) (Just 1))
      releaseRevision env 1 showing
      length <$> readTVarIO (fakeQueued (envFake env)) >>= (`shouldBe` 1)
      pendingReleases (envAdapter env) >>= (`shouldBe` Set.fromList [first, second])
      -- The first runs; making room, it queues the other without anyone asking.
      runNext env >>= (`shouldBe` [Right ()])
      length <$> readTVarIO (fakeQueued (envFake env)) >>= (`shouldBe` 1)
      runNext env >>= (`shouldBe` [Right ()])
      mapM (resolves env) [first, second] >>= (`shouldBe` [False, False])
      pendingReleases (envAdapter env) >>= (`shouldBe` Set.empty)

  it "queues a refused follow-up again when the application asks, with no other event" $
    withEnv [1] $ \env → do
      handle ← registered env 1 True DefaultMark
      showing ← publishOk env 1 [handle]
      adopt env 1 showing
      release2DTexture (envAdapter env) handle >>= (`shouldBe` Right ())
      _ ← runQueued env
      atomically (writeTVar (fakeCapacity (envFake env)) (Just 0))
      releaseRevision env 1 showing
      length <$> readTVarIO (fakeQueued (envFake env)) >>= (`shouldBe` 0)
      retryReleases (envAdapter env)
      length <$> readTVarIO (fakeQueued (envFake env)) >>= (`shouldBe` 0)
      atomically (writeTVar (fakeCapacity (envFake env)) Nothing)
      retryReleases (envAdapter env)
      runQueued env >>= (`shouldBe` [Right ()])
      resolves env handle >>= (`shouldBe` False)

  it "recovers a release whose caller was cancelled after the marker and before the host was asked" $
    withEnv [1] $ \env → do
      handle ← registered env 1 True DefaultMark
      atomically (writeTVar (fakeCancel (envFake env)) True)
      try @AsyncException (release2DTexture (envAdapter env) handle) >>= (`shouldBe` Left ThreadKilled)
      -- The marker and the pending entry were one transaction.
      atomically (isReleased (envTextures env) handle) >>= (`shouldBe` True)
      pendingReleases (envAdapter env) >>= (`shouldBe` Set.singleton handle)
      publish2DSnapshot (envAdapter env) 1 (windowSnapshot [handle]) >>= (`shouldBe` Left (TextureReleasedInSnapshot handle))
      length <$> readTVarIO (fakeQueued (envFake env)) >>= (`shouldBe` 0)
      -- Asking again repeats the request, and the lock was not left held.
      release2DTexture (envAdapter env) handle >>= (`shouldBe` Right ())
      runQueued env >>= (`shouldBe` [Right ()])
      resolves env handle >>= (`shouldBe` False)

  it "recovers a follow-up whose caller was cancelled before the host admitted it" $
    withEnv [1] $ \env → do
      handle ← registered env 1 True DefaultMark
      showing ← publishOk env 1 [handle]
      adopt env 1 showing
      release2DTexture (envAdapter env) handle >>= (`shouldBe` Right ())
      _ ← runQueued env
      -- The hold ends, and the thread queueing the follow-up is cancelled.
      atomically (writeTVar (fakeCancelPlain (envFake env)) True)
      try @AsyncException (releaseRevision env 1 showing) >>= (`shouldBe` Left ThreadKilled)
      length <$> readTVarIO (fakeQueued (envFake env)) >>= (`shouldBe` 0)
      pendingReleases (envAdapter env) >>= (`shouldBe` Set.singleton handle)
      -- Neither the next retry nor a repeated release is shut out by it.
      retryReleases (envAdapter env)
      length <$> readTVarIO (fakeQueued (envFake env)) >>= (`shouldBe` 1)
      runQueued env >>= (`shouldBe` [Right ()])
      resolves env handle >>= (`shouldBe` False)

  it "recovers a repeated release of a texture whose barrier was met when its follow-up's caller was cancelled" $
    withEnv [1] $ \env → do
      handle ← registered env 1 True DefaultMark
      showing ← publishOk env 1 [handle]
      adopt env 1 showing
      release2DTexture (envAdapter env) handle >>= (`shouldBe` Right ())
      _ ← runQueued env
      atomically (writeTVar (fakeCancelPlain (envFake env)) True)
      try @AsyncException (releaseRevision env 1 showing) >>= (`shouldBe` Left ThreadKilled)
      release2DTexture (envAdapter env) handle >>= (`shouldBe` Right ())
      length <$> readTVarIO (fakeQueued (envFake env)) >>= (`shouldBe` 1)
      runQueued env >>= (`shouldBe` [Right ()])
      resolves env handle >>= (`shouldBe` False)

-- ---------------------------------------------------------------------------
-- Frames

frameSpec ∷ Spec
frameSpec = describe "rendering a window's scene" $ do
  let info = FrameInfo (64, 64) 50 (Just (32, 32)) (Just (2, 2))
      renderWith env frame = framelessOnce (envRig env) (renderWindowFrame (builders (envRig env)) (envRenderer env) frame blankScene)
  it "skips a frame whose request names no logical extent, no content scale, or unusable metrics, before recording anything" $
    withEnv [1] $ \env → do
      noLogical ← renderWith env info {frameLogical = Nothing}
      noScale ← renderWith env info {frameScale = Nothing}
      zeroScale ← renderWith env info {frameScale = Just (0, 2)}
      infiniteScale ← renderWith env info {frameScale = Just (1 / 0, 2)}
      map (either (const True) (const False)) [noLogical, noScale, zeroScale, infiniteScale] `shouldBe` [True, True, True, True]
      -- Each refusal says what was missing, and nothing was recorded or claimed.
      [reason | Left (RefusedIllegal reason) ← [noLogical, noScale]] `shouldSatisfy` ((== 2) . length)
      commandsRecorded (envRig env) >>= (`shouldBe` [])
      ringOffsets (envRig env) >>= (`shouldBe` [])

  it "maps the window pass under metrics built from the frame's own extent and the window's logical extent and scale, reaching the recorder" $
    withEnv [1] $ \env → do
      -- A frame-less batch has no swapchain image, so the backend refuses the
      -- window pass's first command; what matters is that the metrics were
      -- accepted and the work reached the backend, not another refusal first.
      answer ← renderWith env info
      case answer of
        Left (RefusedIllegal reason) → reason `shouldSatisfy` (\why → not (any (`Text.isInfixOf` why) ["logical extent", "content scale", "metrics"]))
        Left _ → pure ()
        Right () → pure ()
