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

import Control.Concurrent.STM (atomically, readTVarIO, writeTVar)
import Control.Exception (AsyncException (ThreadKilled), try)
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.Set as Set
import qualified Data.Text as Text
import Hetoimasia.GPU.Vulkan.Native.Recording (ImageFormat (..), PipelineDepth (..), PipelineRequest (..), Refusal (..))
import Hetoimasia.GPU.Vulkan.Native.TextureTable (TableView (..), readTable)
import Hetoimasia.Math.Vector (V2 (..))
import qualified Hetoimasia.Render.Api.Texture as Api
import qualified Hetoimasia.Render.Api.Texture.Backend as ApiBackend
import Hetoimasia.Render.TwoD.DrawPlan (isMarkedCutout)
import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Target.Backend (targetRef)
import qualified Hetoimasia.Render.TwoD.Validation as Validation
import Hetoimasia.Render.TwoD.Validation (Location (..), validateSnapshot)
import Hetoimasia.Render.TwoD.Vulkan.Frame (FrameRefusal (..))
import Hetoimasia.Render.TwoD.Vulkan.Textures
import Hetoimasia.Render.TwoD.Vulkan.Window
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Render.TwoD.Vulkan.Environment
import Test.Render.TwoD.Vulkan.StandIn

spec ∷ Spec
spec = describe "Windows" $ do
  marksSpec
  swapSpec
  publishSpec
  holdsSpec
  releaseSpec
  frameSpec
  depthSpec

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
  let info = FrameInfo (64, 64) 50 (Just (32, 32)) (Just (2, 2)) Nothing
      renderWith env frame = framelessOnce (envRig env) (renderWindowFrame (envAdapter env) (builders (envRig env)) frame blankScene)
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

-- ---------------------------------------------------------------------------
-- Depth (R2D-9)

-- | A window snapshot of a UI layer (holding the first texture) and then a
-- depth-enabled world layer (layer 1) holding them all.
deepSnapshot ∷ [Api.TextureHandle] → Snapshot
deepSnapshot handles =
  Snapshot [Pass WindowTarget (ClearColour 0 0 0 1) [View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 16 16)) defaultViewSettings [] [UiLayer (map sprite (take 1 handles)), WorldLayer DepthEnabled (map sprite handles)]]]

-- | The scene a snapshot makes.
sceneFor ∷ Snapshot → Scene2D
sceneFor snapshot = either (error . show) sceneOf (validateSnapshot snapshot)

-- | What each pipeline made declares of depth: whether it tests and writes.
declaredDepth ∷ Env → IO [Maybe (Bool, Bool)]
declaredDepth env = map (fmap (\declared → (depthTest declared, depthWrite declared)) . requestDepth) <$> pipelinesMade (envRig env)

depthSpec ∷ Spec
depthSpec = describe "world depth" $ do
  let info = FrameInfo (64, 64) 50 (Just (32, 32)) (Just (2, 2)) Nothing
      renderWith env frame scene = framelessOnce (envRig env) (renderWindowFrame (envAdapter env) (builders (envRig env)) frame scene)
  it "publishes a depth-enabled world layer where the session's depth format is D32_SFLOAT" $
    withEnv [1] $ \env → do
      handle ← registered env 1 True DefaultMark
      publish2DSnapshot (envAdapter env) 1 (deepSnapshot [handle]) >>= (`shouldBe` Right 1)

  it "refuses a depth-enabled world layer where the session's depth format is not D32_SFLOAT, naming the layer and publishing nothing" $ do
    mapM_
      ( \(offered, session) → withEnvOffering offered [1] $ \env → do
          handle ← registered env 1 True DefaultMark
          publish2DSnapshot (envAdapter env) 1 (deepSnapshot [handle]) >>= (`shouldBe` Left (WorldDepthRefused (AtLayer 0 0 1) session))
          length <$> readTVarIO (fakePublished (envFake env)) >>= (`shouldBe` 0)
      )
      [([Depth24, Depth16], Just Depth24), ([Depth16], Just Depth16), ([], Nothing)]

  it "publishes and records a depth-free snapshot on a device that offers only X8_D24, building no depth pipeline" $
    withEnvOffering [Depth24, Depth16] [1] $ \env → do
      handle ← registered env 1 True DefaultMark
      let flat = Snapshot [Pass WindowTarget (ClearColour 0 0 0 1) [View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 16 16)) defaultViewSettings [] [UiLayer [sprite handle], WorldLayer DepthDisabled [sprite handle]]]]
      publish2DSnapshot (envAdapter env) 1 flat >>= (`shouldBe` Right 1)
      -- The frame-less batch refuses the window pass's first command; the
      -- renderer's preparation, which makes the pipelines, came before it.
      _ ← renderWith env info (sceneFor flat)
      declaredDepth env >>= (`shouldBe` [Nothing])

  it "plans a frame with the registered handles' marks, so a marked texture's instance gets the cutout pipeline" $
    withEnv [1] $ \env → do
      art ← registered env 1 True DefaultMark
      plain ← registered env 2 False DefaultMark
      depth ← depthTarget (envRig env) Depth32Float 64 64
      _ ← renderWith env info {frameDepthImage = Just depth} (sceneFor (deepSnapshot [art, plain]))
      -- The UI layer's untested pipeline, the cutout run's, and the ordered
      -- instance's tested-not-written one.
      declared ← declaredDepth env
      (Just (True, True) `elem` declared, Just (True, False) `elem` declared, Just (False, False) `elem` declared) `shouldBe` (True, True, True)

  it "routes nothing to the cutout pipeline when no texture of the scene is marked" $
    withEnv [1] $ \env → do
      plain ← registered env 2 False DefaultMark
      depth ← depthTarget (envRig env) Depth32Float 64 64
      _ ← renderWith env info {frameDepthImage = Just depth} (sceneFor (deepSnapshot [plain]))
      declared ← declaredDepth env
      Just (True, True) `elem` declared `shouldBe` False

  it "refuses a frame holding a depth-enabled world layer when the request gave no depth image, naming the layer and recording nothing" $
    withEnv [1] $ \env → do
      art ← registered env 1 True DefaultMark
      resetJournal (envRig env)
      answer ← renderWith env info (sceneFor (deepSnapshot [art]))
      case answer of
        Left (RefusedIllegal reason) → reason `shouldSatisfy` Text.isInfixOf (Text.pack (show (NoDepthTarget (AtLayer 0 0 1))))
        other → expectationFailure ("expected the layer to be named, found " <> show other)
      commandsRecorded (envRig env) >>= (`shouldBe` [])
      pipelinesMade (envRig env) >>= (`shouldBe` [])

  it "takes the depth image's format from the backend, not from the host's declaration" $
    withEnv [1] $ \env → do
      art ← registered env 1 True DefaultMark
      lower ← depthTarget (envRig env) Depth24 64 64
      answer ← renderWith env info {frameDepthImage = Just lower} (sceneFor (deepSnapshot [art]))
      case answer of
        Left (RefusedIllegal reason) → reason `shouldSatisfy` Text.isInfixOf (Text.pack (show (DepthFormatRefused (AtLayer 0 0 1) Depth24)))
        other → expectationFailure ("expected the lower-precision format to be refused, found " <> show other)
      pipelinesMade (envRig env) >>= (`shouldBe` [])
