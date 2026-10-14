-- | Retained chunks over the headless native layer (R2D-10): building one and
-- its upload for each kind of layer, pressure before the upload completes, the
-- refusals and what they leave behind, recording a frame that draws from a
-- chunk's buffer and culling it, and the adapter's publication, holds and
-- release of chunks behind the window host's barrier.
--
-- __Where the expected values come from.__ Never from the code under test: the
-- bytes a chunk uploads and a layer writes are the render-2d encoder's own
-- encoding of the instances in the order worked out by hand in each example,
-- the commands are the ones the native layer was asked to record, read back
-- from its journal, and holds and releases are counted from the revisions
-- adopted and released.
module Test.Render.TwoD.Vulkan.Retained (spec) where

import Control.Concurrent (forkIO, yield)
import Control.Monad (forM_)
import Control.Concurrent.STM (atomically, newTVarIO, readTVar, readTVarIO, retry, writeTVar)
import qualified Data.Map.Strict as Map
import Control.Exception (AsyncException (ThreadKilled), throwIO, try)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.Set as Set
import qualified Data.Text as Text
import Data.Word (Word32, Word64)
import Hetoimasia.GPU.Vulkan.Native.Recording
  ( Buffer
  , BarrierObject (..)
  , ImageFormat (..)
  , NativeCommand (..)
  , Refusal (..)
  , releaseManaged
  , validateRingSize
  , validateStorageWindow
  )
import Hetoimasia.GPU.Vulkan.Native.TextureTable (validateTableConfig)
import Hetoimasia.GPU.Vulkan.Native.Uploads (UploadRefusal (..), UploadState (..))
import Hetoimasia.Math.Affine2 (fromColumns)
import Hetoimasia.Math.Vector (V2 (..))
import qualified Hetoimasia.Render.Api.Texture as Api
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.Api.Texture.Backend (textureHandle)
import Hetoimasia.Render.TwoD.Chunk
import qualified Hetoimasia.Render.TwoD.Chunk.Backend as Backend
import Hetoimasia.Render.TwoD.DrawPlan (CutoutMarks, cutoutMarks)
import Hetoimasia.Render.TwoD.Encoding (encodeLayer)
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..), defaultViewSettings)
import Hetoimasia.Render.TwoD.Material (defaultMaterial)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Target (TargetRef)
import Hetoimasia.Render.TwoD.Target.Backend (targetRef)
import Hetoimasia.Render.TwoD.Validation (Location (..), Reason (..), ValidSnapshot, validLayers, validateSnapshot, validateSnapshotWith)
import qualified Hetoimasia.Render.TwoD.Validation as Validation
import qualified Hetoimasia.Render.TwoD.Vulkan as Render
import Hetoimasia.Render.TwoD.Vulkan.Builders (Builders (..))
import Hetoimasia.Render.TwoD.Vulkan.Chunks
import Hetoimasia.Render.TwoD.Vulkan.Frame
import Hetoimasia.Render.TwoD.Vulkan.Textures (MarkPolicy (..), registeredMarks)
import Hetoimasia.Render.TwoD.Vulkan.Window
import Numeric.Natural (Natural)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Render.TwoD.Vulkan.Environment
import Test.Render.TwoD.Vulkan.StandIn

spec ∷ Spec
spec = describe "Retained chunks" $ do
  buildSpec
  refusalSpec
  recordingSpec
  cullingSpec
  publishSpec
  holdsSpec
  releaseSpec
  pressureSpec

-- ---------------------------------------------------------------------------
-- Fixtures

artHandle, otherHandle ∷ TextureHandle
artHandle = textureHandle 1 1
otherHandle = textureHandle 2 1

-- | The marks the chunks are built with: the art is cutout-safe.
artMarks ∷ CutoutMarks
artMarks = cutoutMarks [artHandle]

-- | A four-by-four sprite of this texture at this x with this depth key; with a
-- marked texture and no flag it is cutout-eligible in a depth-enabled layer.
sprite' ∷ TextureHandle → Float → Word32 → Instance
sprite' handle x key =
  Instance
    { instanceTransform = fromColumns (V2 4 0) (V2 0 4) (V2 x 0)
    , instanceUv = UvRect 0 0 1 1
    , instanceTexture = handle
    , instanceDepthKey = key
    , instanceTint = Tint 255 255 255 255
    , instanceSampler = SamplerNearest
    , instanceTranslucent = False
    , instanceAdditive = False
    , instanceClip = 0
    , instanceFrameTable = 0
    , instanceParameter = 0
    , instanceMaterial = defaultMaterial
    }

-- | A cutout-eligible sprite, and a translucent one, which is always ordered.
cutAt, ordAt ∷ Float → Word32 → Instance
cutAt x key = sprite' artHandle x key
ordAt x key = (sprite' artHandle x key) {instanceTranslucent = True}

layerOf ∷ ChunkKind → [ChunkRef] → [Instance] → Layer
layerOf = \case
  ChunkWorldDepth → WorldLayerWith DepthEnabled
  ChunkWorldFlat → WorldLayerWith DepthDisabled
  ChunkUi → UiLayerWith

-- | The bytes of these instances as the dynamic encoder writes them, in this order.
encoded ∷ [Instance] → ByteString
encoded instances = case validateSnapshot (Snapshot [Pass WindowTarget (ClearColour 0 0 0 1) [View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 8 8)) defaultViewSettings [] [UiLayer instances]]]) of
  Right valid → case validLayers valid of
    [only] → encodeLayer only
    other → error ("one layer expected, not " <> show (length other))
  Left refused → error ("refused: " <> show refused)

-- | The device, the registries and a renderer over a ring of 64 KiB and a table
-- of 16 slots, with the renderer's own uploads settled and its journal forgotten.
data Setup = Setup
  { setupRig ∷ !Rig
  , setupRetained ∷ !Retained
  , setupRenderer ∷ !Render.Renderer
  , setupTracked ∷ !Tracked
  }

-- | What the tracked constructions saw.
data Tracked = Tracked
  { trackedMade ∷ !(IORef [Buffer])
  , trackedReleased ∷ !(IORef [Buffer])
  , trackedUploads ∷ !(IORef Int)
  , trackedFail ∷ !(IORef Bool)
    -- ^ Whether the next upload admission is interrupted by an exception.
  }

withSetup ∷ (Setup → IO a) → IO a
withSetup action = do
  rig ← newRig
  renderer ←
    newRenderer
      rig
      Render.Configuration
        { Render.configurationRing = either (error . show) id (validateRingSize (64 * 1024))
        , Render.configurationRegionWindow = either (error . show) id (validateStorageWindow 4096)
        , Render.configurationTable = either (error . show) id (validateTableConfig 16 8 4)
        }
  resetJournal rig
  retained ← newRetained
  tracked ← Tracked <$> newIORef [] <*> newIORef [] <*> newIORef 0 <*> newIORef False
  action (Setup rig retained renderer tracked)

-- | The rig's constructions, noting every buffer made and released and every
-- upload admitted, and failing an admission on request.
trackedBuilders ∷ Setup → Builders () Int Int Text.Text Int Word64
trackedBuilders setup =
  (builders (setupRig setup))
    { buildVertexBuffer = \bytes → do
        made ← buildVertexBuffer (builders (setupRig setup)) bytes
        either (const (pure ())) (\buffer → atomicModifyIORef' (trackedMade tracked) (\held → (held <> [buffer], ()))) made
        pure made
    , uploadBuffer = \buffer bytes → do
        failing ← readIORef (trackedFail tracked)
        if failing
          then writeIORef (trackedFail tracked) False >> throwIO ThreadKilled
          else do
            answer ← uploadBuffer (builders (setupRig setup)) buffer bytes
            either (const (pure ())) (const (atomicModifyIORef' (trackedUploads tracked) (\count → (count + 1, ()))))  answer
            pure answer
    , releaseBuffer = \buffer → do
        atomicModifyIORef' (trackedReleased tracked) (\held → (held <> [buffer], ()))
        releaseBuffer (builders (setupRig setup)) buffer
    }
  where
    tracked = setupTracked setup

-- | Build a chunk of this kind with the art marked.
buildChunkOf ∷ Setup → ChunkKind → [Instance] → IO (Either BuildRefusal ChunkRef)
buildChunkOf setup kind = buildRetainedChunk (trackedBuilders setup) (setupRetained setup) artMarks kind DeriveBounds

-- | Build, expecting acceptance.
built ∷ Setup → ChunkKind → [Instance] → IO ChunkRef
built setup kind instances = buildChunkOf setup kind instances >>= either (fail . ("the build was refused: " <>) . show) pure

-- | Every copy into a buffer the journal holds: its destination handle and bytes.
copiesInto ∷ [NativeCommand] → [(Word64, Word64)]
copiesInto commands = [(destination, size) | CommandCopyBuffer _ _ destination _ size ← commands]

-- | The valid snapshot of one view over the first offscreen target listing these
-- chunks, against the chunks the registry holds.
snapshotOver ∷ Setup → [View] → IO ValidSnapshot
snapshotOver setup views = do
  chunks ← retainedChunks (setupRetained setup)
  case validateSnapshotWith chunks (Snapshot [Pass (OffscreenTarget target0) (ClearColour 0 0 0 1) views]) of
    Right valid → pure valid
    Left refused → fail ("the fixture was refused: " <> show refused)

target0 ∷ TargetRef
target0 = targetRef 1 1

-- | A view over the whole 32 × 32 target, the camera at its centre so that world
-- and target coordinates agree, holding these layers.
fullView ∷ [Layer] → View
fullView = View (Camera (V2 16 16) 1 Nothing) (Viewport (V2 0 0) (V2 32 32)) defaultViewSettings []

-- | The frame over the 32 × 32 target with a depth image, drawing chunks from
-- the registry's buffers with the art marked.
frameFor ∷ Setup → ValidSnapshot → IO FrameInput
frameFor setup snapshot = do
  image ← target (setupRig setup) Rgba8Linear 32 32
  depth ← depthTarget (setupRig setup) Depth32Float 32 32
  buffers ← retainedBuffers (setupRetained setup)
  pure
    FrameInput
      { frameSnapshot = snapshot
      , frameMarks = artMarks
      , frameTarget = \reference → if reference == target0 then Just (TargetBinding image (offscreenAttachment Rgba8Linear 32 32) (Just (DepthBinding depth Depth32Float))) else Nothing
      , frameWindow = Nothing
      , frameWindowDepth = Nothing
      , frameChunks = buffers
      , frameOmitted = Set.empty
      }

-- | Record a frame into a frame-less batch.
record ∷ Setup → FrameInput → IO (Either FrameRefusal ())
record setup input =
  Render.prepareSnapshot (trackedBuilders setup) (setupRenderer setup) input >>= \case
    Left refusal → pure (Left refusal)
    Right recording → framelessOnce (setupRig setup) recording

-- | The draws a recording made, in order: the native buffer each reads from, the
-- offset into it and the instances it draws.
draws ∷ [NativeCommand] → [(Word64, Word64, Word32)]
draws = go Nothing
  where
    go _ [] = []
    go bound (command : rest) = case command of
      CommandBindVertexBuffer _ buffer offset → go (Just (buffer, offset)) rest
      CommandDraw _ instances _ _ → maybe [] (\(buffer, offset) → [(buffer, offset, instances)]) bound <> go bound rest
      _ → go bound rest

-- | The buffers a recording draws from, once each, in the order first drawn.
drawnFrom ∷ [NativeCommand] → [Word64]
drawnFrom commands = nub [buffer | (buffer, _, _) ← draws commands]

-- ---------------------------------------------------------------------------
-- Building

buildSpec ∷ Spec
buildSpec = describe "building a chunk and its upload" $ do
  it "makes one device-local vertex buffer of exactly the cutout instances' bytes and uploads them, for a world chunk with depth" $
    withSetup $ \setup → do
      let cutouts = [cutAt 0 3, cutAt 5 1, cutAt 10 2]
          instances = cutouts <> [ordAt 15 9]
      reference ← built setup ChunkWorldDepth instances
      -- The upload is admitted, but not complete until the owner has turned it.
      chunkStanding (setupRetained setup) reference >>= (`shouldBe` Just ChunkUploading)
      readIORef (trackedUploads (setupTracked setup)) >>= (`shouldBe` 1)
      length <$> readIORef (trackedMade (setupTracked setup)) >>= (`shouldBe` 1)
      settleUploads (setupRig setup)
      chunkStanding (setupRetained setup) reference >>= (`shouldBe` Just ChunkReady)
      -- One copy of 192 bytes, three instances, into the chunk's buffer; the bytes staged are the
      -- instances' own encoding in the order the buffer holds them (by material, then build order).
      commands ← commandsRecorded (setupRig setup)
      map snd (copiesInto commands) `shouldBe` [192]
      writes ← mappedWrites (setupRig setup)
      [bytes | (_, _, bytes) ← writes, ByteString.length bytes == 192] `shouldBe` [encoded cutouts]

  it "makes no buffer and admits no upload for a chunk of a world layer without depth and of a UI layer, and none for a depth chunk with no cutout instance" $
    withSetup $ \setup →
      sequence_
        [ do
            reference ← built setup kind instances
            chunkBufferOf (setupRetained setup) reference >>= (`shouldBe` Nothing)
            -- Ready at once: there is nothing to wait for.
            chunkStanding (setupRetained setup) reference >>= (`shouldBe` Just ChunkReady)
        | (kind, instances) ←
            [ (ChunkWorldFlat, [cutAt 0 1, cutAt 4 2])
            , (ChunkUi, [cutAt 0 1, ordAt 4 2])
            , (ChunkWorldDepth, [ordAt 0 1, (cutAt 4 2) {instanceTexture = otherHandle}])
            ]
        ]
        >> do
          readIORef (trackedMade (setupTracked setup)) >>= (`shouldBe` [])
          readIORef (trackedUploads (setupTracked setup)) >>= (`shouldBe` 0)
          settleUploads (setupRig setup)
          commandsRecorded (setupRig setup) >>= (\commands → copiesInto commands `shouldBe` [])

  it "registers the chunk under a fresh reference, resolvable by the registry and by nothing else" $
    withSetup $ \setup → do
      first ← built setup ChunkUi [ordAt 0 1]
      second ← built setup ChunkUi [ordAt 0 2]
      first `shouldSatisfy` (/= second)
      held ← retainedChunks (setupRetained setup)
      (lookupChunk held first >>= Just . chunkInstances, lookupChunk held second >>= Just . chunkInstances) `shouldBe` (Just [ordAt 0 1], Just [ordAt 0 2])
      lookupChunk held (chunkRefOf 999 1) `shouldBe` Nothing
      liveChunks (setupRetained setup) >>= (`shouldBe` [first, second])

-- ---------------------------------------------------------------------------
-- Refusals

refusalSpec ∷ Spec
refusalSpec = describe "refusing a build" $ do
  it "refuses instances and bounds the description refuses, with every reason, holding nothing" $
    withSetup $ \setup → do
      let bad = (cutAt 0 16777216) {instanceClip = 2}
      buildChunkOf setup ChunkWorldDepth [cutAt 0 1, bad]
        `shouldReturnRefused` BuildInvalid (ChunkInstanceInvalid 1 DepthKeyTooLarge :| [ChunkInstanceInvalid 1 ClipIndexUnknown])
      buildRetainedChunk (trackedBuilders setup) (setupRetained setup) artMarks ChunkUi (SuppliedBounds (Bounds (V2 0 0) (V2 1 1))) [cutAt 0 1]
        `shouldReturnRefused` BuildInvalid (ChunkBoundsInsufficient :| [])
      liveChunks (setupRetained setup) >>= (`shouldBe` [])
      readIORef (trackedMade (setupTracked setup)) >>= (`shouldBe` [])

  it "refuses an upload that cannot ever fit the staging buffer, releasing the buffer it made, and holding nothing" $
    withSetup $ \setup → do
      -- 17,000 cutout instances are 1,088,000 bytes; the staging buffer holds 1,048,576.
      let huge = [cutAt (fromIntegral i) 1 | i ← [0 .. 16999 ∷ Int]]
      answer ← buildChunkOf setup ChunkWorldDepth huge
      case answer of
        Left (BuildUploadRefused (UploadOversized _ _)) → pure ()
        other → expectationFailure ("expected an oversized refusal, found " <> show other)
      made ← readIORef (trackedMade (setupTracked setup))
      released ← readIORef (trackedReleased (setupTracked setup))
      length made `shouldBe` 1
      released `shouldBe` made
      liveChunks (setupRetained setup) >>= (`shouldBe` [])

  it "answers pressure when the upload queue is full, as a retry that can succeed, releasing the buffer and holding nothing; the build succeeds once the uploads settle" $
    withSetup $ \setup → do
      -- The queue holds eight uploads and none has been turned.
      references ← mapM (\i → built setup ChunkWorldDepth [cutAt (fromIntegral (i ∷ Int)) 1]) [1 .. 8]
      answer ← buildChunkOf setup ChunkWorldDepth [cutAt 0 1]
      case answer of
        Left (BuildUploadBackpressure _) → pure ()
        other → expectationFailure ("expected backpressure, found " <> show other)
      made ← readIORef (trackedMade (setupTracked setup))
      released ← readIORef (trackedReleased (setupTracked setup))
      length made `shouldBe` 9
      released `shouldBe` drop 8 made
      liveChunks (setupRetained setup) >>= (`shouldBe` references)
      settleUploads (setupRig setup)
      _ ← built setup ChunkWorldDepth [cutAt 0 1]
      pure ()

  it "releases the buffer when the build is interrupted by an exception after it was made, leaving nothing registered" $
    withSetup $ \setup → do
      writeIORef (trackedFail (setupTracked setup)) True
      outcome ← try (buildChunkOf setup ChunkWorldDepth [cutAt 0 1])
      case outcome of
        Left ThreadKilled → pure ()
        Left other → expectationFailure ("a different exception: " <> show other)
        Right answer → expectationFailure ("expected an exception, found " <> show answer)
      made ← readIORef (trackedMade (setupTracked setup))
      released ← readIORef (trackedReleased (setupTracked setup))
      (length made, released) `shouldBe` (1, made)
      liveChunks (setupRetained setup) >>= (`shouldBe` [])

  it "ends the chunk's reference when it is released, whether its upload had completed or not, reusing the index under the next generation" $
    withSetup $ \setup → do
      pending ← built setup ChunkWorldDepth [cutAt 0 1]
      -- Released while the upload is pending: the backend settles it.
      markChunkReleased (setupRetained setup) pending >>= (`shouldBe` True)
      markChunkReleased (setupRetained setup) pending >>= (`shouldBe` False)
      releaseChunkNow (trackedBuilders setup) (setupRetained setup) pending >>= (`shouldBe` Right ())
      settleUploads (setupRig setup)
      chunkStanding (setupRetained setup) pending >>= (`shouldBe` Nothing)
      reused ← built setup ChunkWorldDepth [cutAt 4 2]
      (chunkRefIndexOf reused, chunkRefGenerationOf reused) `shouldBe` (chunkRefIndexOf pending, chunkRefGenerationOf pending + 1)
      -- The old reference resolves to nothing and never to the rebuilt content.
      held ← retainedChunks (setupRetained setup)
      (lookupChunk held pending, fmap chunkInstances (lookupChunk held reused)) `shouldBe` (Nothing, Just [cutAt 4 2])
  where
    shouldReturnRefused action expected = action >>= (`shouldBe` Left expected)

-- ---------------------------------------------------------------------------
-- Recording

recordingSpec ∷ Spec
recordingSpec = describe "recording a frame that draws chunks" $ do
  it "draws a chunk's cutouts from its own buffer, and writes to the ring only the dynamic cutouts and the merged ordered instances" $
    withSetup $ \setup → do
      -- The chunk: three cutouts (keys 3, 1, 2) and a translucent instance at key 9.
      -- The layer: a dynamic cutout at key 4 and a dynamic translucent at key 4.
      reference ← built setup ChunkWorldDepth [cutAt 0 3, cutAt 5 1, cutAt 10 2, ordAt 15 9]
      settleUploads (setupRig setup)
      uploads ← commandsRecorded (setupRig setup)
      chunkBuffer ← case copiesInto uploads of
        [(destination, 192)] → pure destination
        other → fail ("expected one upload of 192 bytes, found " <> show other)
      resetJournal (setupRig setup)
      let dynamicCut = cutAt 20 4
          dynamicOrd = ordAt 25 4
      snapshot ← snapshotOver setup [fullView [WorldLayerWith DepthEnabled [reference] [dynamicOrd, dynamicCut]]]
      input ← frameFor setup snapshot
      record setup input >>= (`shouldBe` Right ())
      commands ← commandsRecorded (setupRig setup)
      -- The ring holds, in one region: the dynamic cutout, then the ordered instances at keys 4
      -- (the dynamic translucent) and 9 (the chunk's), the chunk before nothing at an equal key.
      claimWrites (setupRig setup) >>= (`shouldBe` [(0, ByteString.replicate 16 0), (16, encoded [dynamicCut, dynamicOrd, ordAt 15 9])])
      ringOffsets (setupRig setup) >>= (`shouldBe` [0, 16])
      -- Three draws: the chunk's three cutouts from its buffer at offset 0, the dynamic cutout
      -- from the ring at offset 16 (after the clip region's one entry), then the two
      -- ordered instances from the ring at offset 80.
      case draws commands of
        [(first, firstOffset, firstCount), (second, secondOffset, secondCount), (third, thirdOffset, thirdCount)] → do
          (first, firstOffset, firstCount) `shouldBe` (chunkBuffer, 0, 3)
          (secondOffset, secondCount, thirdOffset, thirdCount) `shouldBe` (16, 1, 80, 2)
          second `shouldBe` third
          second `shouldSatisfy` (/= chunkBuffer)
        other → expectationFailure ("expected three draws, found " <> show other)
      -- The chunk's buffer was touched before rendering began: its entry barrier cannot be inside a pass.
      let beforeRendering = takeWhile (not . isBegin) commands
      [object | CommandResourceBarrier object _ _ ← beforeRendering, object == BarrierBuffer chunkBuffer] `shouldSatisfy` (not . null)

  it "uploads a chunk once and writes its cutout data to the ring never: later frames re-encode and re-upload nothing of it, and write only the ordered data" $
    withSetup $ \setup → do
      reference ← built setup ChunkWorldDepth [cutAt 0 3, cutAt 5 1, ordAt 15 9]
      settleUploads (setupRig setup)
      resetJournal (setupRig setup)
      snapshot ← snapshotOver setup [fullView [WorldLayerWith DepthEnabled [reference] []]]
      frames ← mapM (const (frameFor setup snapshot >>= record setup)) [1 .. 3 ∷ Int]
      frames `shouldBe` replicate 3 (Right ())
      -- Three frames: the cutout bytes (128) were never written to the ring; each frame wrote
      -- the one ordered instance's 64 bytes, and nothing was uploaded after the first build.
      writes ← mappedWrites (setupRig setup)
      let written = [bytes | (_, _, bytes) ← writes]
      -- Each frame wrote the one ordered instance's 64 bytes to the ring, and the cutouts' 128 never.
      length (filter ((== 64) . ByteString.length) written) `shouldBe` 3
      written `shouldSatisfy` notElem (encoded [cutAt 0 3, cutAt 5 1])
      readIORef (trackedUploads (setupTracked setup)) >>= (`shouldBe` 1)
      commands ← commandsRecorded (setupRig setup)
      copiesInto commands `shouldBe` []

  it "claims no ring region for a layer all of whose runs read a chunk's buffer" $
    withSetup $ \setup → do
      reference ← built setup ChunkWorldDepth [cutAt 0 3, cutAt 5 1]
      settleUploads (setupRig setup)
      resetJournal (setupRig setup)
      snapshot ← snapshotOver setup [fullView [WorldLayerWith DepthEnabled [reference] []]]
      frameFor setup snapshot >>= record setup >>= (`shouldBe` Right ())
      -- Only the clip region's single zero entry is claimed: nothing of the layer's.
      ringOffsets (setupRig setup) >>= (`shouldBe` [0])
      length . draws <$> commandsRecorded (setupRig setup) >>= (`shouldBe` 1)

  it "draws a chunk listed twice twice from its one buffer, and chunks of different layers from their own buffers" $
    withSetup $ \setup → do
      a ← built setup ChunkWorldDepth [cutAt 0 3]
      b ← built setup ChunkWorldDepth [cutAt 8 3, cutAt 12 4]
      settleUploads (setupRig setup)
      resetJournal (setupRig setup)
      snapshot ← snapshotOver setup [fullView [WorldLayerWith DepthEnabled [a, b, a] []]]
      frameFor setup snapshot >>= record setup >>= (`shouldBe` Right ())
      commands ← commandsRecorded (setupRig setup)
      map (\(_, offset, count) → (offset, count)) (draws commands) `shouldBe` [(0, 1), (0, 2), (0, 1)]
      length (drawnFrom commands) `shouldBe` 2

  it "records the ordered path of a world chunk without depth and of a UI chunk entirely through the ring, in merged order" $
    sequence_
      [ withSetup $ \setup → do
            reference ← built setup kind [cutAt 0 7, ordAt 4 2]
            resetJournal (setupRig setup)
            snapshot ← snapshotOver setup [fullView [layerOf kind [reference] [ordAt 8 5, ordAt 12 2]]]
            frameFor setup snapshot >>= record setup >>= (`shouldBe` Right ())
            -- Keys 2 (chunk build 1, then the dynamic), 5, 7: the chunk's key-2 instance
            -- before the dynamic one at an equal key.
            claimWrites (setupRig setup) >>= (`shouldBe` [(0, ByteString.replicate 16 0), (16, encoded [ordAt 4 2, ordAt 12 2, ordAt 8 5, cutAt 0 7])])
            commands ← commandsRecorded (setupRig setup)
            map (\(_, offset, count) → (offset, count)) (draws commands) `shouldBe` [(16, 4)]
            copiesInto commands `shouldBe` []
        | kind ← [ChunkWorldFlat, ChunkUi]
        ]

  it "refuses a depth image that is not D32_SFLOAT for a depth-enabled layer that lists chunks, and a session offering no D32_SFLOAT, naming the layer, even over an empty viewport" $
    withSetup $ \setup → do
      reference ← built setup ChunkWorldDepth [cutAt 0 3]
      settleUploads (setupRig setup)
      let emptyView = View (Camera (V2 16 16) 1 Nothing) (Viewport (V2 0 0) (V2 0 0)) defaultViewSettings [] [WorldLayerWith DepthEnabled [reference] []]
      lie ← depthTarget (setupRig setup) Depth24 32 32
      image ← target (setupRig setup) Rgba8Linear 32 32
      buffers ← retainedBuffers (setupRetained setup)
      forM_ [fullView [WorldLayerWith DepthEnabled [reference] []], emptyView] $ \view → do
        snapshot ← snapshotOver setup [view]
        let input =
              FrameInput
                { frameSnapshot = snapshot
                , frameMarks = artMarks
                , frameTarget = \_ → Just (TargetBinding image (offscreenAttachment Rgba8Linear 32 32) (Just (DepthBinding lie Depth32Float)))
                , frameWindow = Nothing
                , frameWindowDepth = Nothing
                , frameChunks = buffers
                , frameOmitted = Set.empty
                }
            declared = input {frameTarget = \_ → Just (TargetBinding image (offscreenAttachment Rgba8Linear 32 32) (Just (DepthBinding lie Depth24)))}
        fmap (const ()) (frameWork declared) `shouldBe` Left (DepthFormatRefused (AtLayer 0 0 0) Depth24)
        requireWorldDepth (Just Depth24) snapshot `shouldBe` Left (DepthFormatRefused (AtLayer 0 0 0) Depth24)
        requireWorldDepth Nothing snapshot `shouldBe` Left (NoDepthFormat (AtLayer 0 0 0))
        requireWorldDepth (Just Depth32Float) snapshot `shouldBe` Right ()

  it "refuses a frame that lists a chunk with cutout instances for which no buffer was supplied, naming the layer and the chunk" $
    withSetup $ \setup → do
      reference ← built setup ChunkWorldDepth [cutAt 0 3]
      settleUploads (setupRig setup)
      snapshot ← snapshotOver setup [fullView [WorldLayerWith DepthEnabled [reference] []]]
      input ← frameFor setup snapshot
      fmap (const ()) (frameWork input {frameChunks = const Nothing}) `shouldBe` Left (ChunkBufferMissing (AtLayer 0 0 0) reference)
      -- A chunk without cutout instances needs none.
      other ← built setup ChunkUi [ordAt 0 1]
      uiSnapshot ← snapshotOver setup [fullView [UiLayerWith [other] []]]
      uiInput ← frameFor setup uiSnapshot
      fmap (const ()) (frameWork uiInput {frameChunks = const Nothing}) `shouldBe` Right ()
  where
    isBegin = \case
      CommandBeginRendering {} → True
      _ → False

-- ---------------------------------------------------------------------------
-- Culling

cullingSpec ∷ Spec
cullingSpec = describe "culling a chunk by its bounds" $ do
  it "skips a chunk wholly outside the view: nothing of it is drawn, claimed or written, and the layer names it" $
    withSetup $ \setup → do
      near ← built setup ChunkWorldDepth [cutAt 4 1, ordAt 8 2]
      far ← built setup ChunkWorldDepth [cutAt 500 1, ordAt 504 2]
      settleUploads (setupRig setup)
      uploads ← commandsRecorded (setupRig setup)
      nearBuffer ← case [destination | (destination, 64) ← copiesInto uploads] of
        destination : _ → pure destination
        [] → fail "the upload of the near chunk was not seen"
      resetJournal (setupRig setup)
      snapshot ← snapshotOver setup [fullView [WorldLayerWith DepthEnabled [near, far] []]]
      input ← frameFor setup snapshot
      case frameWork input of
        Right [pass] → do
          let layers = concatMap workLayers (workViews pass)
          map layerCulled layers `shouldBe` [[far]]
          -- The far chunk's cutout run is not among the layer's runs, and neither is its ordered instance.
          map (map runInstanceCount . layerRunList) layers `shouldBe` [[1, 1]]
        other → expectationFailure ("expected one pass, found " <> either show (show . length) other)
      record setup input >>= (`shouldBe` Right ())
      commands <- commandsRecorded (setupRig setup)
      claimWrites (setupRig setup) >>= (`shouldBe` [(0, ByteString.replicate 16 0), (16, encoded [ordAt 8 2])])
      drawnFrom commands `shouldSatisfy` ((== 2) . length)
      (nearBuffer `elem` drawnFrom commands) `shouldBe` True

  it "records no scissor and no draw in a view whose only content is a chunk it skips, the pass still beginning and ending" $
    withSetup $ \setup → do
      reference ← built setup ChunkUi [ordAt 500 1]
      resetJournal (setupRig setup)
      snapshot ← snapshotOver setup [fullView [UiLayerWith [reference] []]]
      input ← frameFor setup snapshot
      case frameWork input of
        Right [pass] → map (map layerCulled . workLayers) (workViews pass) `shouldBe` [[[reference]]]
        other → expectationFailure ("expected one pass, found " <> either show (show . length) other)
      record setup input >>= (`shouldBe` Right ())
      commands ← commandsRecorded (setupRig setup)
      draws commands `shouldBe` []
      length [() | CommandSetScissor _ ← commands] `shouldBe` 0
      length [() | CommandBeginRendering {} ← commands] `shouldBe` 1
      length [() | CommandEndRendering ← commands] `shouldBe` 1

  it "leaves out a chunk the frame omits, in every view, though it lies in view: nothing of it is drawn, claimed or written, and the layer names it" $
    withSetup $ \setup → do
      kept ← built setup ChunkWorldDepth [cutAt 4 1, ordAt 8 2]
      omitted ← built setup ChunkWorldDepth [cutAt 12 1, ordAt 16 2]
      settleUploads (setupRig setup)
      resetJournal (setupRig setup)
      snapshot ← snapshotOver setup [fullView [WorldLayerWith DepthEnabled [kept, omitted] []]]
      input ← frameFor setup snapshot
      let leaving = input {frameOmitted = Set.singleton omitted}
      case frameWork leaving of
        Right [pass] → map (map layerCulled . workLayers) (workViews pass) `shouldBe` [[[omitted]]]
        other → expectationFailure ("expected one pass, found " <> either show (show . length) other)
      record setup leaving >>= (`shouldBe` Right ())
      claimWrites (setupRig setup) >>= (`shouldBe` [(0, ByteString.replicate 16 0), (16, encoded [ordAt 8 2])])
      length . draws <$> commandsRecorded (setupRig setup) >>= (`shouldBe` 2)

  it "keeps a chunk in one view and skips it in another, each view planned for itself" $
    withSetup $ \setup → do
      reference ← built setup ChunkWorldDepth [cutAt 4 1]
      settleUploads (setupRig setup)
      let layer = WorldLayerWith DepthEnabled [reference] []
          here = fullView [layer]
          elsewhere = View (Camera (V2 5000 16) 1 Nothing) (Viewport (V2 0 0) (V2 32 32)) defaultViewSettings [] [layer]
      snapshot ← snapshotOver setup [here, elsewhere]
      input ← frameFor setup snapshot
      case frameWork input of
        Right [pass] → map (map layerCulled . workLayers) (workViews pass) `shouldBe` [[[]], [[reference]]]
        other → expectationFailure ("expected one pass, found " <> either show (show . length) other)

  it "keeps a chunk the view's pixel snap could move into view" $
    withSetup $ \setup → do
      -- A chunk ending at world x = -0.3: unsnapped it is wholly left of the view,
      -- snapped an instance's origin may move it right by up to half a pixel.
      reference ← built setup ChunkUi [(ordAt (-4.3) 1) {instanceTransform = fromColumns (V2 4 0) (V2 0 4) (V2 (-4.3) 0)}]
      let snapping = (fullView [UiLayerWith [reference] []]) {viewSettings = defaultViewSettings {settingPixelSnap = True}}
          flat = fullView [UiLayerWith [reference] []]
      snapshot ← snapshotOver setup [flat, snapping]
      input ← frameFor setup snapshot
      case frameWork input of
        Right [pass] → map (map layerCulled . workLayers) (workViews pass) `shouldBe` [[[reference]], [[]]]
        other → expectationFailure ("expected one pass, found " <> either show (show . length) other)

-- ---------------------------------------------------------------------------
-- Publication

-- | An environment with these windows, the art registered and marked cutout, and
-- a world chunk with depth of two instances built from it, its upload settled.
withChunkEnv ∷ [Int] → (Env → TextureHandle' → ChunkRef → IO a) → IO a
withChunkEnv windows action = withEnv windows $ \env → do
  art ← registered env 1 True DefaultMark
  reference ← chunkIn env art ChunkWorldDepth
  settleUploads (envRig env)
  action env art reference

type TextureHandle' = Api.TextureHandle

-- | Build a chunk of the art, a cutout and a translucent instance.
chunkIn ∷ Env → Api.TextureHandle → ChunkKind → IO ChunkRef
chunkIn env art kind = do
  marks ← registeredMarks (envTextures env)
  buildRetainedChunk (builders (envRig env)) (envRetained env) marks kind DeriveBounds [sprite' art 0 1, (sprite' art 5 2) {instanceTranslucent = True}]
    >>= either (fail . ("the chunk was refused: " <>) . show) pure

-- | A window snapshot of one world layer with depth listing these chunks, beside
-- these dynamic instances.
windowListing ∷ [ChunkRef] → [Instance] → Snapshot
windowListing references dynamic =
  Snapshot [Pass WindowTarget (ClearColour 0 0 0 1) [View (Camera (V2 16 16) 1 Nothing) (Viewport (V2 0 0) (V2 32 32)) defaultViewSettings [] [WorldLayerWith DepthEnabled references dynamic]]]

-- | The same far from the view, where the chunk is culled.
windowListingFar ∷ [ChunkRef] → Snapshot
windowListingFar references =
  Snapshot [Pass WindowTarget (ClearColour 0 0 0 1) [View (Camera (V2 90000 16) 1 Nothing) (Viewport (V2 0 0) (V2 32 32)) defaultViewSettings [] [WorldLayerWith DepthEnabled references []]]]

publishChunks ∷ Env → Int → Snapshot → IO (Either PublishRefusal Natural)
publishChunks env = publish2DSnapshot (envAdapter env)

publishOkWith ∷ Env → Int → [ChunkRef] → [Instance] → IO Natural
publishOkWith env window references dynamic = publishChunks env window (windowListing references dynamic) >>= either (fail . ("refused: " <>) . show) pure

-- | The window host's barrier is met and the owner runs what it queued.
barrier ∷ Env → IO [Either Refusal ()]
barrier = runQueued

publishSpec ∷ Spec
publishSpec = describe "publishing a snapshot that lists chunks" $ do
  it "publishes a snapshot that lists a chunk in a layer of its kind, whose upload is still under way, without waiting" $
    withEnv [1] $ \env → do
      art ← registered env 1 True DefaultMark
      reference ← chunkIn env art ChunkWorldDepth
      chunkStanding (envRetained env) reference >>= (`shouldBe` Just ChunkUploading)
      publishChunks env 1 (windowListing [reference] []) >>= (`shouldBe` Right 1)

  it "refuses a chunk in a layer of another kind, naming the layer and the chunk, and publishes nothing" $
    withChunkEnv [1] $ \env _ reference → do
      let ui = Snapshot [Pass WindowTarget (ClearColour 0 0 0 1) [View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 32 32)) defaultViewSettings [] [UiLayerWith [reference] []]]]
      publishChunks env 1 ui `shouldReturn'` Left (SnapshotInvalid (Validation.Refusal (AtChunk 0 0 0 0 reference) ChunkKindMismatch :| []))
      length <$> readTVarIO (fakePublished (envFake env)) >>= (`shouldBe` 0)

  it "refuses a depth-enabled layer that lists chunks where the session's depth format is not D32_SFLOAT, naming the layer, and publishes nothing" $
    mapM_
      ( \(offered, session) → withEnvOffering offered [1] $ \env → do
          art ← registered env 1 True DefaultMark
          reference ← chunkIn env art ChunkWorldDepth
          publish2DSnapshot (envAdapter env) 1 (windowListing [reference] []) >>= (`shouldBe` Left (WorldDepthRefused (AtLayer 0 0 0) session))
          -- Even where the view's viewport is empty and nothing could be drawn.
          let empty = Snapshot [Pass WindowTarget (ClearColour 0 0 0 1) [View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 0 0)) defaultViewSettings [] [WorldLayerWith DepthEnabled [reference] []]]]
          publish2DSnapshot (envAdapter env) 1 empty >>= (`shouldBe` Left (WorldDepthRefused (AtLayer 0 0 0) session))
          length <$> readTVarIO (fakePublished (envFake env)) >>= (`shouldBe` 0)
      )
      [([Depth24, Depth16], Just Depth24), ([], Nothing)]

  it "refuses a reference the registry does not hold, naming the layer and the chunk: never built, or released since" $
    withChunkEnv [1] $ \env _ reference → do
      let stranger = chunkRefOf 77 1
      publishChunks env 1 (windowListing [stranger] []) `shouldReturn'` Left (SnapshotInvalid (Validation.Refusal (AtChunk 0 0 0 0 stranger) ChunkUnresolved :| []))
      markChunkReleased (envRetained env) reference >>= (`shouldBe` True)
      releaseChunkNow (builders (envRig env)) (envRetained env) reference >>= (`shouldBe` Right ())
      publishChunks env 1 (windowListing [reference] []) `shouldReturn'` Left (SnapshotInvalid (Validation.Refusal (AtChunk 0 0 0 0 reference) ChunkUnresolved :| []))

  it "refuses a chunk whose release has been requested, naming it, and accepts the snapshot without it" $
    withChunkEnv [1] $ \env _ reference → do
      release2DChunk (envAdapter env) reference >>= (`shouldBe` Right ())
      publishChunks env 1 (windowListing [reference] []) `shouldReturn'` Left (ChunkReleasedInSnapshot reference)
      publishChunks env 1 (windowListing [] []) >>= (`shouldBe` Right 1)

  it "never accepts a snapshot that lists a chunk whose release has run, however publications and the release interleave" $
    withChunkEnv [1] $ \env _ reference → do
      released ← newTVarIO False
      done ← newTVarIO False
      failure ← newTVarIO (Nothing ∷ Maybe String)
      -- Publications run on an application thread, as they do; the release runs on the owner's.
      _ ← forkIO $ do
        let loop remaining = do
              ran ← readTVarIO released
              answer ← publish2DSnapshot (envAdapter env) 1 (windowListing [reference] [])
              -- A publication that began after the release ran must have been refused.
              case answer of
                Right _ | ran → atomically (writeTVar failure (Just "a snapshot listing a released chunk was accepted after its release ran"))
                _ → pure ()
              if ran || remaining <= (0 ∷ Int) then atomically (writeTVar done True) else yield >> loop (remaining - 1)
        loop 2000
      markChunkReleased (envRetained env) reference >>= (`shouldBe` True)
      yield
      releaseChunkNow (builders (envRig env)) (envRetained env) reference >>= (`shouldBe` Right ())
      atomically (writeTVar released True)
      atomically (readTVar done >>= \finished → if finished then pure () else retry)
      readTVarIO failure >>= (`shouldBe` Nothing)
      -- Whatever got through before the marker, nothing lists the chunk now.
      publish2DSnapshot (envAdapter env) 1 (windowListing [reference] []) >>= (`shouldSatisfy` either (const True) (const False))
      view ← atomically (retainedViewSTM (envRetained env))
      Map.member reference (viewReleased view) `shouldBe` False

  it "reads the registry as one view: a marked chunk with its flag and standing, a released one absent from all of it" $
    withChunkEnv [1] $ \env _ reference → do
      before ← atomically (retainedViewSTM (envRetained env))
      (Map.lookup reference (viewReleased before), Map.lookup reference (viewStandings before)) `shouldBe` (Just False, Just ChunkReady)
      markChunkReleased (envRetained env) reference >>= (`shouldBe` True)
      marked ← atomically (retainedViewSTM (envRetained env))
      Map.lookup reference (viewReleased marked) `shouldBe` Just True
      releaseChunkNow (builders (envRig env)) (envRetained env) reference >>= (`shouldBe` Right ())
      after ← atomically (retainedViewSTM (envRetained env))
      (Map.member reference (viewReleased after), Map.member reference (viewStandings after), lookupChunk (viewChunks after) reference) `shouldBe` (False, False, Nothing)

  it "refuses a chunk whose upload ended without completing, naming it and how it ended" $
    withEnv [1] $ \env → do
      art ← registered env 1 True DefaultMark
      reference ← chunkIn env art ChunkWorldDepth
      -- The buffer is released under the pending upload, which the backend then cancels.
      Just buffer ← chunkBufferOf (envRetained env) reference
      releaseManaged (rigRecording (envRig env)) buffer >>= (`shouldBe` Right ())
      settleUploads (envRig env)
      chunkStanding (envRetained env) reference >>= (`shouldBe` Just (ChunkFailed UploadCancelled))
      publishChunks env 1 (windowListing [reference] []) `shouldReturn'` Left (ChunkUploadFailedInSnapshot reference UploadCancelled)

  it "makes a scene of the chunks it lists and of every texture reached through them, though no dynamic instance names one and a view culls the chunk" $
    withChunkEnv [1] $ \env art reference → do
      _ ← either (fail . show) pure =<< publishChunks env 1 (windowListingFar [reference])
      published ← readTVarIO (fakePublished (envFake env))
      case published of
        [(_, _, scene)] → do
          sceneChunks scene `shouldBe` Set.fromList [reference]
          sceneReferences scene `shouldBe` Set.fromList [art]
        other → expectationFailure ("expected one scene, found " <> show (length other))
  where
    shouldReturn' action expected = action >>= (`shouldBe` expected)

-- ---------------------------------------------------------------------------
-- Holds

holdsSpec ∷ Spec
holdsSpec = describe "holding chunks" $ do
  it "holds a chunk, and a texture only a chunk names, for as long as an adopted revision lists the chunk, once for each revision of each window" $
    withChunkEnv [1, 2] $ \env art reference → do
      first ← publishOkWith env 1 [reference] []
      second ← publishOkWith env 2 [reference] []
      chunkHolds (envAdapter env) reference >>= (`shouldBe` 0)
      adopt env 1 first
      chunkHolds (envAdapter env) reference >>= (`shouldBe` 1)
      textureHolds (envAdapter env) art >>= (`shouldBe` 1)
      adopt env 2 second
      chunkHolds (envAdapter env) reference >>= (`shouldBe` 2)
      releaseRevision env 1 first
      chunkHolds (envAdapter env) reference >>= (`shouldBe` 1)
      releaseRevision env 2 second
      chunkHolds (envAdapter env) reference >>= (`shouldBe` 0)
      textureHolds (envAdapter env) art >>= (`shouldBe` 0)

  it "holds a chunk the view culls, and the texture it names, exactly as one in view" $
    withChunkEnv [1] $ \env art reference → do
      revision ← either (fail . show) pure =<< publishChunks env 1 (windowListingFar [reference])
      adopt env 1 revision
      chunkHolds (envAdapter env) reference >>= (`shouldBe` 1)
      textureHolds (envAdapter env) art >>= (`shouldBe` 1)

  it "keeps holding a chunk after a revision that omits it supersedes the one that lists it, until the listing revision's last recording is over" $
    withChunkEnv [1] $ \env _ reference → do
      listing ← publishOkWith env 1 [reference] []
      adopt env 1 listing
      superseding ← publishOkWith env 1 [] []
      adopt env 1 superseding
      chunkHolds (envAdapter env) reference >>= (`shouldBe` 1)
      releaseRevision env 1 listing
      chunkHolds (envAdapter env) reference >>= (`shouldBe` 0)

-- ---------------------------------------------------------------------------
-- Release

releaseSpec ∷ Spec
releaseSpec = describe "releasing chunks behind the window host's barrier" $ do
  it "marks the chunk released at once, asks the host for a barrier, and releases the buffer only once the barrier is met and no adopted revision holds the chunk" $
    withChunkEnv [1] $ \env _ reference → do
      revision ← publishOkWith env 1 [reference] []
      adopt env 1 revision
      release2DChunk (envAdapter env) reference >>= (`shouldBe` Right ())
      pendingChunkReleases (envAdapter env) >>= (`shouldBe` Set.fromList [reference])
      readTVarIO (fakeAsked (envFake env)) >>= (`shouldBe` (1, 0))
      -- The barrier is met, but the adopted revision still shows the chunk: it keeps rendering.
      barrier env >>= (`shouldBe` [Right ()])
      chunkStanding (envRetained env) reference >>= (`shouldBe` Just ChunkReady)
      (/= Nothing) <$> chunkBufferOf (envRetained env) reference >>= (`shouldBe` True)
      -- The revision's last recording is over: the release is queued with no barrier of its own, and made.
      releaseRevision env 1 revision
      readTVarIO (fakeAsked (envFake env)) >>= (`shouldBe` (1, 1))
      barrier env >>= (`shouldBe` [Right ()])
      chunkStanding (envRetained env) reference >>= (`shouldBe` Nothing)
      liveChunks (envRetained env) >>= (`shouldBe` [])
      pendingChunkReleases (envAdapter env) >>= (`shouldBe` Set.empty)

  it "releases the buffer the moment the barrier is met when no adopted revision holds the chunk" $
    withChunkEnv [1] $ \env _ reference → do
      release2DChunk (envAdapter env) reference >>= (`shouldBe` Right ())
      barrier env >>= (`shouldBe` [Right ()])
      chunkStanding (envRetained env) reference >>= (`shouldBe` Nothing)

  it "waits for every window's revision that holds the chunk, and for a revision's last recording as well as its supersession" $
    withChunkEnv [1, 2] $ \env _ reference → do
      firstOne ← publishOkWith env 1 [reference] []
      secondOne ← publishOkWith env 2 [reference] []
      adopt env 1 firstOne
      adopt env 2 secondOne
      -- Window 1 moves on to a revision without the chunk; its old revision's recording is not over.
      moved ← publishOkWith env 1 [] []
      adopt env 1 moved
      release2DChunk (envAdapter env) reference >>= (`shouldBe` Right ())
      _ ← barrier env
      chunkStanding (envRetained env) reference >>= (`shouldBe` Just ChunkReady)
      releaseRevision env 2 secondOne
      barrier env >>= (`shouldBe` [])
      chunkStanding (envRetained env) reference >>= (`shouldBe` Just ChunkReady)
      releaseRevision env 1 firstOne
      barrier env >>= (`shouldBe` [Right ()])
      chunkStanding (envRetained env) reference >>= (`shouldBe` Nothing)

  it "keeps a texture only a chunk names rendering while an adopted revision lists the chunk, and releases it behind the same holds" $
    withChunkEnv [1] $ \env art reference → do
      revision ← publishOkWith env 1 [reference] []
      adopt env 1 revision
      release2DTexture (envAdapter env) art >>= (`shouldBe` Right ())
      _ ← barrier env
      resolves env art >>= (`shouldBe` True)
      releaseRevision env 1 revision
      _ ← barrier env
      resolves env art >>= (`shouldBe` False)

  it "refuses to release a chunk never built or already released" $
    withChunkEnv [1] $ \env _ reference → do
      let stranger = chunkRefOf 77 1
      release2DChunk (envAdapter env) stranger >>= (`shouldBe` Left (ReleaseChunkUnknown stranger))
      release2DChunk (envAdapter env) reference >>= (`shouldBe` Right ())
      _ ← barrier env
      release2DChunk (envAdapter env) reference >>= (`shouldBe` Left (ReleaseChunkUnknown reference))

  it "rebuilds by building a new chunk, publishing it and releasing the old, which the new revision's adoption lets go" $
    withChunkEnv [1] $ \env art old → do
      oldRevision ← publishOkWith env 1 [old] []
      adopt env 1 oldRevision
      new ← chunkIn env art ChunkWorldDepth
      settleUploads (envRig env)
      newRevision ← publishOkWith env 1 [new] []
      release2DChunk (envAdapter env) old >>= (`shouldBe` Right ())
      adopt env 1 newRevision
      _ ← barrier env
      releaseRevision env 1 oldRevision
      _ ← barrier env
      chunkStanding (envRetained env) old >>= (`shouldBe` Nothing)
      chunkStanding (envRetained env) new >>= (`shouldBe` Just ChunkReady)
      chunkHolds (envAdapter env) new >>= (`shouldBe` 1)

-- ---------------------------------------------------------------------------
-- Pressure

pressureSpec ∷ Spec
pressureSpec = describe "rendering a window's scene that lists chunks" $ do
  let info = FrameInfo (64, 64) 50 (Just (32, 32)) (Just (2, 2)) Nothing 0
      renderWith env scene = framelessOnce (envRig env) (renderWindowFrame (envAdapter env) (builders (envRig env)) 1 info scene)
      sceneOfRevision env = do
        published <- readTVarIO (fakePublished (envFake env))
        case reverse published of
          (_, _, scene) : _ → pure scene
          [] → fail "nothing was published"
  it "skips the frame while a chunk's upload has not completed, recording and claiming nothing, and names the chunk it waits for" $
    withEnv [1] $ \env → do
      art ← registered env 1 True DefaultMark
      reference ← chunkIn env art ChunkWorldDepth
      _ ← publishOkWith env 1 [reference] []
      scene ← sceneOfRevision env
      resetJournal (envRig env)
      pendingChunkUploads (envAdapter env) scene >>= (`shouldBe` [reference])
      answer ← renderWith env scene
      case answer of
        Left (RefusedIllegal reason) → reason `shouldSatisfy` Text.isInfixOf "upload has not completed"
        other → expectationFailure ("expected the frame to be skipped, found " <> show other)
      commandsRecorded (envRig env) >>= (`shouldBe` [])
      ringOffsets (envRig env) >>= (`shouldBe` [])

  it "records the frame once the upload has completed, nothing of the chunk having been drawn before" $
    withEnv [1] $ \env → do
      art ← registered env 1 True DefaultMark
      reference ← chunkIn env art ChunkWorldDepth
      _ ← publishOkWith env 1 [reference] []
      scene ← sceneOfRevision env
      settleUploads (envRig env)
      pendingChunkUploads (envAdapter env) scene >>= (`shouldBe` [])
      answer ← renderWith env scene
      -- A frame-less batch has no swapchain image, so the backend refuses the window pass: the
      -- chunk, ready, is not what stopped the frame.
      case answer of
        Left (RefusedIllegal reason) → reason `shouldSatisfy` (not . Text.isInfixOf "retained chunk")
        _ → pure ()

  it "records the frame without a chunk whose upload ended without completing, and names it, instead of refusing a frame the host would retry for ever" $
    withEnv [1] $ \env → do
      art ← registered env 1 True DefaultMark
      reference ← chunkIn env art ChunkWorldDepth
      _ ← publishOkWith env 1 [reference] []
      scene ← sceneOfRevision env
      Just buffer ← chunkBufferOf (envRetained env) reference
      releaseManaged (rigRecording (envRig env)) buffer >>= (`shouldBe` Right ())
      settleUploads (envRig env)
      pendingChunkUploads (envAdapter env) scene >>= (`shouldBe` [])
      failedChunkUploads (envAdapter env) scene >>= (`shouldBe` [(reference, UploadCancelled)])
      answer ← renderWith env scene
      -- Not refused for the chunk: a refusal is retried at the host's backoff, and this chunk
      -- can never be drawn. (The frame-less batch refuses the window pass for its own reason.)
      case answer of
        Left (RefusedIllegal reason) → reason `shouldSatisfy` (not . Text.isInfixOf "retained chunk")
        _ → pure ()

-- Accessors the examples use to read a reference's numbers.
chunkRefOf ∷ Word32 → Word32 → ChunkRef
chunkRefOf = Backend.chunkRef

chunkRefIndexOf, chunkRefGenerationOf ∷ ChunkRef → Word32
chunkRefIndexOf = Backend.chunkRefIndex
chunkRefGenerationOf = Backend.chunkRefGeneration
