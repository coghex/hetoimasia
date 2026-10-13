-- | The retained chunks' window-free evidence (R2D-10): over several frames,
-- retained content built once and listed by reference in each snapshot, merged
-- with dynamic content that alone is republished, rendered through
-- @hetoimasia-render-2d-vulkan@ into offscreen targets of a surface-free
-- session, every pixel of every target judged against
-- @hetoimasia-render-2d-oracle@ and each named behaviour distinguished from its
-- contrast, by "Test.GPU.Vulkan.Native.OrderedPath"'s runner.
--
-- The session is the ordinary one, with the registries the window host's
-- adapter is made over ('Textures', 'Retained') and an adapter whose holds the
-- case drives as the owner does: it adopts a revision before rendering it and
-- reports it released when its last recording is over, and a release is
-- requested through the integration's own request operation. Scenes are made
-- from snapshots validated against the chunks the registry holds
-- ('sceneOf'); a windowed snapshot is not used, because publication refuses an
-- offscreen pass and a window pass cannot be recorded without a window.
--
-- = The scenarios
--
-- Each frame is one fixture of the record, named @scenario-n@.
--
-- * @interleaved@ (3 frames): a world chunk with depth, built once, holding
--   cutouts and a translucent instance, listed in a depth-enabled world layer
--   beside dynamic cutouts, one of which moves each frame. Only the dynamic
--   instances are republished: the chunk's cutout bytes were uploaded once and
--   are never in the ring. A dynamic cutout at an equal key to a chunk cutout
--   wins the tie (the later source), the chunk's translucent instance is hidden
--   behind a nearer chunk cutout and blends over a farther one.
-- * @ordered-kinds@ (1 frame): a world chunk without depth and a UI chunk, drawn
--   wholly in the ordered path beside dynamic content in the same layers, merged
--   with it by key and then source. A texture registered with an explicit cutout
--   mark whose texel has an alpha under a half is the witness: a depth chunk
--   discards it (the cutout rule), the other two kinds blend it (the ordered
--   path).
-- * @swap@ (3 frames): a texture swapped under the chunk's handle shows through
--   it without a rebuild; a swap to an image whose computed mark differs is
--   refused (D-27), and the chunk keeps showing what it showed.
-- * @release@ (3 frames): a chunk released while the adopted snapshot shows it
--   is still drawn, in that snapshot's frame, until a snapshot without it is
--   adopted; its buffer is released only once the revision that held it is over.
-- * @culling@ (1 frame): a chunk shown in one view of a pass and skipped in
--   another, and a chunk wholly outside every view.
--
-- Each fixture names the behaviour it shows by a probe whose expectation must be
-- determinate and differ from its contrast's. What the case checks beyond pixels
-- (uploads admitted, holds, the chunk registry, the culling rule) fails the
-- fixture it belongs to. The numbers that show what was retained — bytes
-- uploaded once, bytes written to the ring each frame — are written to
-- @retained-measurements.json@ beside the probe record.
module Test.GPU.Vulkan.Native.RetainedPath
  ( RetainedHost (..)
  , retainedSuite
  , runRetained
  , buildersWith
  ) where

import Control.Concurrent (threadDelay)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteString8
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (intercalate)
import qualified Data.Set as Set
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word8)
import Numeric.Natural (Natural)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

import Hetoimasia.Asset.Image (DecodedImage (..), TexelFormat (..))
import Hetoimasia.GPU.Vulkan.GLFW
  ( BufferDescription (..)
  , BufferKind (..)
  , Construction
  , Image
  , ImageDescription (..)
  , ImageFormat (..)
  , ImageKind (..)
  , Refusal (..)
  , UploadRefusal
  , UploadRequest (..)
  , UploadTicket
  , constructBlendedCheckedPipeline
  , constructBuffer
  , constructDepthCheckedPipeline
  , constructDepthFormat
  , constructImage
  , constructImageFormat
  , constructRingWith
  , constructStorageTable
  , constructTablePipelineLayoutWith
  , TableLayoutOptions (..)
  , TableUse (..)
  , constructTextureTable
  , registerConstructedTexture
  , releaseConstructed
  , releaseConstructedTexture
  , swapConstructedTexture
  )
import Hetoimasia.Math.Vector (V2 (..))
import qualified Hetoimasia.Render.Api.Texture as Api
import Hetoimasia.Render.TwoD.Chunk
  ( BoundsRequest (..)
  , ChunkKind (..)
  , ChunkRef
  , chunkBounds
  , chunkCutoutPositions
  , chunkPlacementMagnitude
  , lookupChunk
  )
import Hetoimasia.Render.TwoD.Culling (chunkCulled)
import Hetoimasia.Render.TwoD.DrawPlan (CutoutMarks, DrawPlan (..), PlannedPass (..), PlannedView (..), drawingOrder, planSnapshot, plannedLayers)
import Hetoimasia.Render.TwoD.Mapping (viewMapping)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), offscreenMetrics)
import Hetoimasia.Render.TwoD.Oracle (Probe (..))
import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Validation (ValidSnapshot, validateSnapshotWith)
import qualified Hetoimasia.Render.TwoD.Vulkan as Render
import Hetoimasia.Render.TwoD.Vulkan.Chunks
  ( ChunkStanding (..)
  , Retained
  , buildRetainedChunk
  , chunkStanding
  , liveChunks
  , newRetained
  , retainedBuffers
  , retainedChunks
  )
import Hetoimasia.Render.TwoD.Vulkan.Textures
  ( MarkPolicy (..)
  , SwapPolicy (..)
  , TextureRefusal (..)
  , Textures
  , newTextures
  , registerTexture
  , registeredMarks
  , swapTexture
  )
import Hetoimasia.Render.TwoD.Vulkan.Window
  ( Adapter
  , Host (..)
  , HostPublication (..)
  , ReleaseBody
  , adapterAdopted
  , adapterReleased
  , chunkHolds
  , newAdapter
  , pendingChunkReleases
  , release2DChunk
  , sceneOf
  )
import Test.GPU.Vulkan.Native.OrderedPath
  ( Evidence
  , FixtureResult (..)
  , Suite (..)
  , awaitPlaceholder
  , configuration
  , finishEvidence
  , runValidated
  )
import qualified Test.GPU.Vulkan.Native.OrderedPath as OrderedPath
import Test.GPU.Vulkan.Native.OrderedPath.Fixtures
  ( Fixture (..)
  , NamedProbe (..)
  , TargetShape
  , depthShape
  , keyed
  , pass
  , quad
  , tinted
  )

-- ---------------------------------------------------------------------------
-- The host

-- | What the case needs of the session beyond the ordered path's host: uploads
-- admitted with a ticket to poll, and owner-thread actions queued for the
-- adapter's releases.
data RetainedHost = RetainedHost
  { retainedBase ∷ !OrderedPath.Host
  , retainedSubmit ∷ UploadRequest → IO (Either UploadRefusal UploadTicket)
    -- ^ Admit an upload from any thread, answering its ticket.
  , retainedRequestRelease ∷ ReleaseBody → IO (Either Text ())
    -- ^ The integration's release request: an owner-thread action that waits for
    -- the revisions its windows must have adopted (none here).
  , retainedRunOnOwner ∷ ReleaseBody → IO (Either Text ())
    -- ^ An owner-thread action that waits for nothing.
  }

-- | The renderer's constructions over a session's, with uploads admitted
-- through this function.
buildersWith
  ∷ (UploadRequest → IO (Either UploadRefusal UploadTicket))
  → Construction q inst msgr phys dev cmd
  → Render.Builders q inst msgr phys dev cmd
buildersWith submit construction =
  Render.Builders
    { Render.buildRing = constructRingWith construction
    , Render.buildStorageTable = constructStorageTable construction
    , Render.buildTable = constructTextureTable construction
    , Render.buildTableLayout = \shaders → constructTablePipelineLayoutWith construction shaders (TableLayoutOptions TableShaderSampler True)
    , Render.buildPipeline = constructBlendedCheckedPipeline construction
    , Render.buildDepthPipeline = constructDepthCheckedPipeline construction
    , Render.buildDepthFormat = constructDepthFormat construction
    , Render.buildImageFormat = constructImageFormat construction
    , Render.registerImage = registerConstructedTexture construction
    , Render.swapImage = swapConstructedTexture construction
    , Render.releaseImage = releaseConstructedTexture construction
    , Render.buildVertexBuffer = \bytes → constructBuffer construction (BufferDescription VertexBuffer bytes)
    , Render.uploadBuffer = \buffer bytes → submit (UploadBuffer buffer bytes)
    , Render.releaseBuffer = releaseConstructed construction
    }

-- | The adapter's host: nothing is published to a window, and the releases it
-- asks for go to the session.
windowHostOf ∷ RetainedHost → IORef Int → Host Int
windowHostOf host ran =
  Host
    { hostPublish = \_ _ → pure HostWindowUnknown
    , hostRequestRelease = \body → retainedRequestRelease host (counted body)
    , hostRunOnOwner = \body → retainedRunOnOwner host (counted body)
    }
  where
    -- Count each release action the owner has run, so the case can wait for one.
    counted ∷ ReleaseBody → ReleaseBody
    counted body builders = do
      answer ← body builders
      atomicModifyIORef' ran (\count → (count + 1, ()))
      pure answer

-- ---------------------------------------------------------------------------
-- The suite

-- | The frames the case judges, which the record's count is checked against.
frameCount ∷ Int
frameCount = 11

-- | The suite: its record, and as many fixtures as there are frames.
retainedSuite ∷ Suite
retainedSuite = Suite "retained" "retained-probes.json" [] (replicate frameCount placeholder) True
  where
    placeholder = Fixture "frame" [] [] (const (Snapshot [])) []

-- ---------------------------------------------------------------------------
-- The textures

-- | The one-texel textures the session registers.
data Piece = White | Swappable | Faint
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A piece's texel, premultiplied: white, the canvas tints are drawn on; red,
-- the swap's first image; and a faint red whose alpha is under a half, which is
-- registered with an explicit cutout mark.
texel ∷ Piece → [Word8]
texel = \case
  White → [255, 255, 255, 255]
  Swappable → [255, 0, 0, 255]
  Faint → [100, 0, 0, 100]

-- | The image the oracle samples for a texel.
decodedOf ∷ [Word8] → DecodedImage
decodedOf bytes =
  DecodedImage
    { decodedFormat = TexelRgba8Linear
    , decodedWidth = 1
    , decodedHeight = 1
    , decodedLevels = [ByteString.pack bytes]
    , decodedBinaryAlpha = (bytes !! 3) `elem` [0, 255]
    }

-- | The texel a swap replaces the first image with, an opaque green: the same
-- computed mark. And one whose alpha is not binary: a different mark.
greenTexel, wrongTexel ∷ [Word8]
greenTexel = [0, 255, 0, 255]
wrongTexel = [255, 0, 0, 128]

-- | What a session holds once it is prepared.
data Ctx = Ctx
  { ctxHost ∷ !RetainedHost
  , ctxSubmit ∷ UploadRequest → IO (Either UploadRefusal UploadTicket)
    -- ^ The host's upload admission, counting the uploads admitted.
  , ctxSubmits ∷ !(IORef Int)
  , ctxDirectory ∷ !FilePath
  , ctxFormat ∷ !ImageFormat
  , ctxRenderer ∷ !Render.Renderer
  , ctxTextures ∷ !Textures
  , ctxRetained ∷ !Retained
  , ctxAdapter ∷ !(Adapter Int)
  , ctxHandles ∷ !(Map.Map Piece Api.TextureHandle)
  , ctxDecoded ∷ !(IORef (Map.Map Api.TextureHandle DecodedImage))
    -- ^ What the oracle samples for each handle now: changed when a swap is accepted.
  , ctxUploaded ∷ !(IORef Int)
    -- ^ The bytes of chunk cutout instances uploaded so far.
  , ctxMeasures ∷ !(IORef [String])
    -- ^ The measurements, as JSON objects, newest first.
  , ctxRevision ∷ !(IORef Natural)
  , ctxReleasesRun ∷ !(IORef Int)
    -- ^ How many release actions the owner has run for the adapter.
  }

handleOf ∷ Ctx → Piece → Api.TextureHandle
handleOf ctx piece = ctxHandles ctx Map.! piece

base ∷ Ctx → OrderedPath.Host
base = retainedBase . ctxHost

-- ---------------------------------------------------------------------------
-- The run

-- | Run the case, writing the PNGs, the probe record and the measurements into
-- this directory.
runRetained ∷ RetainedHost → FilePath → IO Evidence
runRetained host directory = do
  createDirectoryIfMissing True directory
  depth ← OrderedPath.hostAct (retainedBase host) "choosing the depth format" constructDepthFormat
  case depth of
    Left why → finish Nothing Nothing (Just why) []
    Right format
      | format /= Depth32Float →
          finish (Just format) (Just ("D32_SFLOAT is not available: the device chose " <> tshow format <> "; the retained case, which draws depth-enabled world layers, renders nothing")) Nothing []
      | otherwise →
          prepare host directory format >>= \case
            Left why → finish (Just format) Nothing (Just why) []
            Right ctx → do
              results ← concat <$> sequence [interleaved ctx, orderedKinds ctx, swapped ctx, released ctx, culled ctx]
              measures ← reverse <$> readIORef (ctxMeasures ctx)
              ByteString.writeFile (directory </> "retained-measurements.json") (ByteString8.pack ("{\"measurements\": [" <> intercalate ", " measures <> "]}\n"))
              let wrong = if length results == frameCount then Nothing else Just ("the case judged " <> tshow (length results) <> " frames, not " <> tshow frameCount)
              finish (Just format) Nothing wrong results
  where
    finish format unavailable failure results = finishEvidence retainedSuite directory format unavailable failure results

-- | Make the renderer, the textures and the registries, and the adapter over
-- them.
prepare ∷ RetainedHost → FilePath → ImageFormat → IO (Either Text Ctx)
prepare host directory format = do
  submits ← newIORef 0
  let submit request = do
        answer ← retainedSubmit host request
        either (const (pure ())) (const (atomicModifyIORef' submits (\count → (count + 1, ())))) answer
        pure answer
  made ← OrderedPath.hostAct (retainedBase host) "making the renderer and the textures" $ \construction → do
    renderer ← Render.makeRenderer (buildersWith submit construction) configuration
    images ← traverse (const (constructImage construction (ImageDescription TextureImage Rgba8Linear 1 1 1))) pieces
    pure ((,) <$> renderer <*> sequence images)
  case made of
    Left failure → pure (Left failure)
    Right (renderer, images) → do
      uploads ← traverse (\(piece, image) → OrderedPath.hostUpload (retainedBase host) (UploadImage image [ByteString.pack (texel piece)])) (zip pieces images)
      case sequence uploads of
        Left failure → pure (Left ("an upload did not complete: " <> failure))
        Right _ →
          awaitPlaceholder (retainedBase host) (200 ∷ Int) >>= \case
            Left failure → pure (Left failure)
            Right () → do
              textures ← newTextures
              registered ←
                OrderedPath.hostAct (retainedBase host) "registering the textures" $ \construction →
                  fmap sequence . traverse (registerPiece (buildersWith submit construction) textures) $ zip pieces images
              case registered of
                Left failure → pure (Left failure)
                Right handles → do
                  retained ← newRetained
                  releasesRun ← newIORef 0
                  adapter ← newAdapter (windowHostOf host releasesRun) textures retained renderer
                  decoded ← newIORef (Map.fromList [(handle, decodedOf (texel piece)) | (piece, handle) ← handles])
                  uploaded ← newIORef 0
                  measures ← newIORef []
                  revision ← newIORef 0
                  pure (Right (Ctx host submit submits directory format renderer textures retained adapter (Map.fromList handles) decoded uploaded measures revision releasesRun))
  where
    pieces = [minBound .. maxBound] ∷ [Piece]
    registerPiece builders textures (piece, image) =
      registerTexture builders textures image (decodedOf (texel piece)) (if piece == Faint then OverrideMark True else DefaultMark) >>= \case
        Left refusal → pure (Left (RefusedIllegal (tshow refusal)))
        Right handle → pure (Right (piece, handle))

-- ---------------------------------------------------------------------------
-- Frames

-- | The target every frame draws into: 32 × 32, with a depth image.
shape ∷ TargetShape
shape = depthShape 1 Rgba8Linear 32 32

-- | A view over a viewport of the target whose camera is at the viewport's
-- centre, so world units are target pixels there, holding these layers.
viewOver ∷ (Float, Float) → (Float, Float) → [Layer] → View
viewOver (x, y) (w, h) = View (Camera (V2 (x + w / 2) (y + h / 2)) 1 Nothing) (Viewport (V2 x y) (V2 w h)) defaultViewSettings []

-- | A view over a viewport whose camera is at this world position.
viewAt ∷ (Float, Float) → (Float, Float) → (Float, Float) → [Layer] → View
viewAt (x, y) (w, h) (cx, cy) = View (Camera (V2 cx cy) 1 Nothing) (Viewport (V2 x y) (V2 w h)) defaultViewSettings []

-- | A rectangle of this piece's texture tinted with this colour. An opaque
-- colour from the white piece is cutout-eligible in a depth-enabled world layer.
block ∷ Ctx → Piece → (Word8, Word8, Word8, Word8) → Word32 → (Float, Float) → (Float, Float) → Instance
block ctx piece colour key origin extent = keyed key (tinted colour (quad origin extent (handleOf ctx piece)))

-- | Render one frame of the snapshot built from these views: adopt a revision
-- of its scene, record and read back the target, and judge it. The caller
-- reports the revision released when its last recording is over.
renderFrame ∷ Ctx → Text → Natural → [View] → [NamedProbe] → IO FixtureResult
renderFrame ctx name revision views probes = do
  chunks ← retainedChunks (ctxRetained ctx)
  case validateSnapshotWith chunks (Snapshot [pass shape (0, 0, 0, 1) views]) of
    Left refused → pure (FixtureResult name [] [] [] (Just ("the snapshot was refused: " <> tshow refused)))
    Right valid → do
      adapterAdopted (ctxAdapter ctx) 0 revision (sceneOf valid)
      marks ← registeredMarks (ctxTextures ctx)
      buffers ← retainedBuffers (ctxRetained ctx)
      decoded ← readIORef (ctxDecoded ctx)
      measure ctx name marks valid
      runValidated (base ctx) retainedSuite (ctxDirectory ctx) (ctxFormat ctx) (ctxRenderer ctx) marks buffers (`Map.lookup` decoded) name [shape] probes valid

-- | Note what a frame wrote: the bytes the plan puts in the ring, which a
-- retained chunk's cutout instances are never among, and the chunk bytes
-- uploaded so far.
measure ∷ Ctx → Text → CutoutMarks → ValidSnapshot → IO ()
measure ctx name marks valid = do
  uploaded ← readIORef (ctxUploaded ctx)
  submits ← readIORef (ctxSubmits ctx)
  atomicModifyIORef' (ctxMeasures ctx) $ \held →
    ( object
        [ ("frame", str (Text.unpack name))
        , ("ring_bytes", show ringBytes)
        , ("chunk_bytes_uploaded_so_far", show uploaded)
        , ("chunk_uploads_admitted_so_far", show submits)
        ]
        : held
    , ()
    )
  where
    ringBytes = 64 * sum [length (drawingOrder layer) | PlannedPass {plannedViews = views} ← planPasses (planSnapshot marks valid), PlannedView {plannedLayers = layers} ← views, layer ← layers]

next ∷ Ctx → IO Natural
next ctx = atomicModifyIORef' (ctxRevision ctx) (\revision → (revision + 1, revision + 1))

-- | The revision's last recording is over: the owner reports it released.
retire ∷ Ctx → Natural → IO ()
retire ctx = adapterReleased (ctxAdapter ctx) 0

-- | The fixture, failed by the first check that did not hold.
verified ∷ [(Text, Bool)] → FixtureResult → FixtureResult
verified checks result = case (resultFailure result, [what | (what, False) ← checks]) of
  (Nothing, what : _) → result {resultFailure = Just ("a check failed: " <> what)}
  _ → result

-- | A named probe at a pixel of the target, with its contrast.
named ∷ Text → (Int, Int) → (Int, Int) → NamedProbe
named behaviour (x, y) (cx, cy) = NamedProbe behaviour (Probe 0 x y) (Probe 0 cx cy)

-- ---------------------------------------------------------------------------
-- Building chunks

-- | Build a chunk on the owner's thread and wait, within a deadline, for its
-- upload to complete.
buildChunkOf ∷ Ctx → ChunkKind → [Instance] → IO (Either Text ChunkRef)
buildChunkOf ctx kind instances = do
  marks ← registeredMarks (ctxTextures ctx)
  built ←
    OrderedPath.hostAct (base ctx) "building a retained chunk" $ \construction →
      buildRetainedChunk (buildersWith (ctxSubmit ctx) construction) (ctxRetained ctx) marks kind DeriveBounds instances >>= \case
        Left refusal → pure (Left (RefusedIllegal (tshow refusal)))
        Right reference → pure (Right reference)
  case built of
    Left failure → pure (Left failure)
    Right reference → do
      ready ← awaitStanding ctx reference (400 ∷ Int)
      held ← retainedChunks (ctxRetained ctx)
      let cutouts = maybe 0 (length . chunkCutoutPositions) (lookupChunk held reference)
      atomicModifyIORef' (ctxUploaded ctx) (\bytes → (bytes + 64 * cutouts, ()))
      pure (if ready then Right reference else Left ("the chunk's upload did not complete: " <> tshow reference))

-- | Wait, a bounded time, for a chunk's standing to be ready.
awaitStanding ∷ Ctx → ChunkRef → Int → IO Bool
awaitStanding ctx reference remaining =
  chunkStanding (ctxRetained ctx) reference >>= \case
    Just ChunkReady → pure True
    _
      | remaining <= 0 → pure False
      | otherwise → threadDelay 25000 >> awaitStanding ctx reference (remaining - 1)

-- | Wait, a bounded time, for a chunk to be forgotten by the registry.
awaitForgotten ∷ Ctx → ChunkRef → Int → IO Bool
awaitForgotten ctx reference remaining =
  chunkStanding (ctxRetained ctx) reference >>= \case
    Nothing → pure True
    _
      | remaining <= 0 → pure False
      | otherwise → threadDelay 25000 >> awaitForgotten ctx reference (remaining - 1)

-- | Wait, a bounded time, for the owner to have run this many release actions.
awaitReleaseRun ∷ Ctx → Int → Int → IO Bool
awaitReleaseRun ctx wanted remaining = do
  ran ← readIORef (ctxReleasesRun ctx)
  if ran >= wanted
    then pure True
    else
      if remaining <= 0
        then pure False
        else threadDelay 25000 >> awaitReleaseRun ctx wanted (remaining - 1)

-- | A failed setup as a fixture.
failedAt ∷ Text → Text → FixtureResult
failedAt name why = FixtureResult name [] [] [] (Just why)

-- ---------------------------------------------------------------------------
-- Interleaved

-- | The chunk's blue cutout A, green cutout B and half-red translucent T, and
-- the layer's dynamic magenta M and the yellow Y that moves:
--
-- > A  blue     key 5  pixels  2..11 × 2..11     chunk cutout
-- > B  green    key 3  pixels  8..17 × 8..17     chunk cutout
-- > T  half red key 4  pixels 10..15 × 10..15    chunk, ordered (tint alpha 128)
-- > E  cyan     key 3  pixels 14..21 × 12..19    cutout of a second chunk, listed after the first
-- > M  magenta  key 3  pixels  8..15 × 2..9      dynamic cutout
-- > Y  yellow   key 9  pixels x..x+5 × 22..27    dynamic cutout, x = 2, 10, 18
--
-- Cutouts draw first, the chunk's before the layer's, and a larger key is nearer:
--
-- * (4, 4): A alone, blue; (9, 5): A over M (key 5 against 3), blue;
--   (13, 5): M alone, magenta.
-- * (13, 9): M over B at an equal key 3, the later source, magenta; (16, 16): B alone, green.
-- * (16, 14): E over B at an equal key 3, the later listed chunk, cyan; (16, 10): B alone, green.
-- * (13, 12): T over B, T being nearer (key 4 against 3): half red over green is
--   (255, 127, 0); (10, 10): T behind A (key 4 against 5), blue.
interleaved ∷ Ctx → IO [FixtureResult]
interleaved ctx = do
  before ← readIORef (ctxSubmits ctx)
  first ← buildChunkOf ctx ChunkWorldDepth [a, b, t]
  second ← buildChunkOf ctx ChunkWorldDepth [e]
  case (first, second) of
    (Right reference, Right laterReference) → do
      framed ← mapM (frameOf [reference, laterReference]) (zip [1 ..] [2, 10, 18])
      standing ← chunkStanding (ctxRetained ctx) reference
      holds ← chunkHolds (ctxAdapter ctx) reference
      submits ← readIORef (ctxSubmits ctx)
      -- The chunk was uploaded once for three frames, and the last frame's revision still holds it.
      let checks =
            [ ("each chunk's upload was admitted once for all three frames", submits - before == 2)
            , ("the chunk is ready", standing == Just ChunkReady)
            , ("only the last revision still holds the chunk", holds == 1)
            ]
      mapM_ (retire ctx . snd) (drop 2 framed)
      pure [verified checks result | (result, _) ← framed]
    _ → pure [failedAt (Text.pack ("interleaved-" <> show n)) "a chunk was not built" | n ← [1 .. 3 ∷ Int]]
  where
    white = White
    a = block ctx white (0, 0, 255, 255) 5 (2, 2) (10, 10)
    b = block ctx white (0, 255, 0, 255) 3 (8, 8) (10, 10)
    t = block ctx white (255, 0, 0, 128) 4 (10, 10) (6, 6)
    -- A second chunk, listed after the first: cyan at an equal key 3 over 14..21 × 12..19.
    e = block ctx white (0, 255, 255, 255) 3 (14, 12) (8, 8)
    magenta = block ctx white (255, 0, 255, 255) 3 (8, 2) (8, 8)
    yellow x = block ctx white (255, 255, 0, 255) 9 (x, 22) (6, 6)
    frameOf references (n, x) = do
      revision ← next ctx
      let layer = WorldLayerWith DepthEnabled references [magenta, yellow x]
          here = (floor x + 2, 24)
          probes =
            [ named "a dynamic cutout at an equal key to a chunk cutout wins the tie as the later source" (13, 9) (16, 8)
            , named "a later listed chunk's cutout wins a tie with an earlier chunk's at an equal key" (16, 14) (16, 10)
            , named "a chunk's translucent instance blends over a chunk cutout it is nearer than" (13, 12) (16, 16)
            , named "a chunk's translucent instance is hidden behind a nearer chunk cutout" (10, 10) (13, 12)
            , named "the dynamic cutout is drawn where this frame put it" here (28, 14)
            , named "the retained cutout is drawn though only the dynamic content was republished" (4, 4) (4, 30)
            ]
      result ← renderFrame ctx (Text.pack ("interleaved-" <> show (n ∷ Int))) revision [viewOver (0, 0) (32, 32) [layer]] probes
      -- The previous revision's last recording is over once this one is adopted and rendered.
      if n > 1 then retire ctx (revision - 1) else pure ()
      pure (result, revision)

-- ---------------------------------------------------------------------------
-- Ordered kinds

-- | A world chunk with depth, a world chunk without depth and a UI chunk, each
-- holding a faint texel (alpha 100 of 255) registered with an explicit cutout
-- mark, beside dynamic content in the same layers, in one view of the target:
--
-- * the depth chunk's faint block at (2, 2) is a cutout and the rule discards
--   it (alpha under a half): (4, 4) stays black;
-- * the flat chunk's at (12, 2), and the UI chunk's at (22, 2), take the ordered
--   path and blend: (100, 0, 0, 100) over black is (100, 0, 0, 255) at (14, 4) and (24, 4);
-- * flat layer: the chunk's blue P (key 9) at 2..9 × 12..19 and the dynamic green
--   G (key 2) at 6..13 × 16..23, by ascending key G then P: P is blue at (7, 17),
--   G green at (11, 21);
-- * UI layer: the chunk's blue Q (key 2) at 18..25 × 12..19 and the dynamic green
--   H (key 9) at 22..29 × 16..23: Q then H, H is green at (23, 17), Q blue at (19, 13).
orderedKinds ∷ Ctx → IO [FixtureResult]
orderedKinds ctx = do
  depthChunk ← buildChunkOf ctx ChunkWorldDepth [faint (2, 2)]
  flatChunk ← buildChunkOf ctx ChunkWorldFlat [faint (12, 2), block ctx White (0, 0, 255, 255) 9 (2, 12) (8, 8)]
  uiChunk ← buildChunkOf ctx ChunkUi [faint (22, 2), block ctx White (0, 0, 255, 255) 2 (18, 12) (8, 8)]
  case (depthChunk, flatChunk, uiChunk) of
    (Right depthRef, Right flatRef, Right uiRef) → do
      revision ← next ctx
      let layers =
            [ WorldLayerWith DepthEnabled [depthRef] []
            , WorldLayerWith DepthDisabled [flatRef] [block ctx White (0, 255, 0, 255) 2 (6, 16) (8, 8)]
            , UiLayerWith [uiRef] [block ctx White (0, 255, 0, 255) 9 (22, 16) (8, 8)]
            ]
          probes =
            [ named "a world chunk without depth blends a texel a depth chunk discards, in the ordered path" (14, 4) (4, 4)
            , named "a UI chunk blends it too" (24, 4) (4, 4)
            , named "a world chunk without depth merges with dynamic content by key: its larger key draws after" (7, 17) (11, 21)
            , named "a UI chunk's smaller key draws before the dynamic instance with the larger key" (23, 17) (19, 13)
            ]
      result ← renderFrame ctx "ordered-kinds-1" revision [viewOver (0, 0) (32, 32) layers] probes
      retire ctx revision
      holds ← mapM (chunkHolds (ctxAdapter ctx)) [depthRef, flatRef, uiRef]
      bufferless ← mapM (fmap (== Just ChunkReady) . chunkStanding (ctxRetained ctx)) [flatRef, uiRef]
      pure [verified [("the revision's holds were dropped with its release", holds == [0, 0, 0]), ("the flat and UI chunks were ready at once", and bufferless)] result]
    _ → pure [failedAt "ordered-kinds-1" "a chunk was not built"]
  where
    faint origin = block ctx Faint (255, 255, 255, 255) 1 origin (6, 6)

-- ---------------------------------------------------------------------------
-- Swap

-- | A cutout of the swappable texture (red) at 4..13 × 4..13, probed at (8, 8):
-- red; swapped under its handle to an opaque green of the same computed mark, the
-- same chunk and snapshot show green; a swap to an image whose alpha is not binary
-- is refused, naming both marks, and the pixel stays green.
swapped ∷ Ctx → IO [FixtureResult]
swapped ctx = do
  before ← readIORef (ctxSubmits ctx)
  buildChunkOf ctx ChunkWorldDepth [block ctx Swappable (255, 255, 255, 255) 4 (4, 4) (10, 10)] >>= \case
    Left why → pure [failedAt (Text.pack ("swap-" <> show n)) why | n ← [1 .. 3 ∷ Int]]
    Right reference → do
      let layers = [WorldLayerWith DepthEnabled [reference] []]
          probes colour = [named colour (8, 8) (24, 24)]
          handle = handleOf ctx Swappable
          frameOf label previous = do
            revision ← next ctx
            result ← renderFrame ctx label revision [viewOver (0, 0) (32, 32) layers] (probes "a texture shows through the chunk as the table maps it")
            mapM_ (retire ctx) previous
            pure (result, revision)
      (first, r1) ← frameOf "swap-1" Nothing
      -- A replacement of the same computed mark, uploaded, then swapped under the handle.
      replacement ← newImage ctx greenTexel
      accepted ← case replacement of
        Left why → pure (Left why)
        Right image →
          OrderedPath.hostAct (base ctx) "swapping the texture" $ \construction →
            swapTexture (buildersWith (ctxSubmit ctx) construction) (ctxTextures ctx) handle image (decodedOf greenTexel) RefuseMarkChange >>= \case
              Left refusal → pure (Left (RefusedIllegal (tshow refusal)))
              Right _ → pure (Right ())
      case accepted of
        Right () → atomicModifyIORef' (ctxDecoded ctx) (\held → (Map.insert handle (decodedOf greenTexel) held, ()))
        Left _ → pure ()
      (second, r2) ← frameOf "swap-2" (Just r1)
      -- A replacement whose computed mark differs from the registered one is refused.
      wrong ← newImage ctx wrongTexel
      refusal ← case wrong of
        Left why → pure (Left why)
        Right image →
          OrderedPath.hostAct (base ctx) "swapping the texture to a different mark" $ \construction →
            swapTexture (buildersWith (ctxSubmit ctx) construction) (ctxTextures ctx) handle image (decodedOf wrongTexel) RefuseMarkChange >>= \case
              Left (MarkMismatch registered computed) → pure (Right (registered, computed))
              Left other → pure (Left (RefusedIllegal (tshow other)))
              Right _ → pure (Left (RefusedIllegal "the swap to a different mark was accepted"))
      (third, r3) ← frameOf "swap-3" (Just r2)
      retire ctx r3
      submits ← readIORef (ctxSubmits ctx)
      holds ← chunkHolds (ctxAdapter ctx) reference
      pure
        [ verified [("the swap to a texture of the same mark was accepted", accepted == Right ()), ("the chunk was built and uploaded once, and never rebuilt", submits - before == 1)] first
        , verified [("the swap to a texture of the same mark was accepted", accepted == Right ())] second
        , verified [("the swap to a texture of a different mark was refused, naming the registered mark and the replacement's", refusal == Right (True, False)), ("every revision's hold was dropped", holds == 0)] third
        ]

-- | A one-texel texture image, uploaded and complete.
newImage ∷ Ctx → [Word8] → IO (Either Text Image)
newImage ctx bytes =
  OrderedPath.hostAct (base ctx) "making a replacement texture" (\construction → constructImage construction (ImageDescription TextureImage Rgba8Linear 1 1 1)) >>= \case
    Left why → pure (Left why)
    Right image →
      OrderedPath.hostUpload (base ctx) (UploadImage image [ByteString.pack bytes]) >>= \case
        Left why → pure (Left ("the replacement's upload did not complete: " <> why))
        Right () → pure (Right image)

-- ---------------------------------------------------------------------------
-- Release

-- | A red cutout chunk at 4..13 × 4..13 and a dynamic green block at 20..25 × 20..25:
--
-- * revision 1 lists the chunk and is adopted and rendered: red at (8, 8);
-- * the chunk's release is requested while that revision is adopted and shows it:
--   the owner runs the request, the revision still holds the chunk, so its buffer
--   stays, and the revision's frame rendered again still draws it;
-- * revision 2, which does not list the chunk, is adopted and rendered: black at (8, 8);
-- * revision 1's last recording is over: the buffer is released, the chunk forgotten.
released ∷ Ctx → IO [FixtureResult]
released ctx =
  buildChunkOf ctx ChunkWorldDepth [block ctx White (255, 0, 0, 255) 5 (4, 4) (10, 10)] >>= \case
    Left why → pure [failedAt (Text.pack ("release-" <> show n)) why | n ← [1 .. 3 ∷ Int]]
    Right reference → do
      let marker = block ctx White (0, 255, 0, 255) 1 (20, 20) (6, 6)
          withChunk = [viewOver (0, 0) (32, 32) [WorldLayerWith DepthEnabled [reference] [marker]]]
          withoutChunk = [viewOver (0, 0) (32, 32) [WorldLayerWith DepthEnabled [] [marker]]]
      r1 ← next ctx
      first ← renderFrame ctx "release-1" r1 withChunk [named "the chunk is drawn from the adopted snapshot" (8, 8) (28, 4)]
      runsBefore ← readIORef (ctxReleasesRun ctx)
      requested ← release2DChunk (ctxAdapter ctx) reference
      ran ← awaitReleaseRun ctx (runsBefore + 1) (400 ∷ Int)
      standingAfterRequest ← chunkStanding (ctxRetained ctx) reference
      holdsAfterRequest ← chunkHolds (ctxAdapter ctx) reference
      pending ← pendingChunkReleases (ctxAdapter ctx)
      second ← renderFrame ctx "release-2" r1 withChunk [named "a chunk released while shown is still drawn by the snapshot that shows it" (8, 8) (28, 4)]
      r2 ← next ctx
      third ← renderFrame ctx "release-3" r2 withoutChunk [named "the snapshot without the chunk draws none of it, and the dynamic content still" (22, 22) (8, 8)]
      -- The first revision's frames are over: it is reported released, and the release goes ahead.
      retire ctx r1
      forgotten ← awaitForgotten ctx reference (400 ∷ Int)
      holdsAfter ← chunkHolds (ctxAdapter ctx) reference
      pendingAfter ← pendingChunkReleases (ctxAdapter ctx)
      live ← liveChunks (ctxRetained ctx)
      resolvable ← retainedChunks (ctxRetained ctx)
      let refused = either (const True) (const False) (validateSnapshotWith resolvable (Snapshot [pass shape (0, 0, 0, 1) withChunk]))
      retire ctx r2
      pure
        [ verified [("the release was requested through the adapter", either (const False) (const True) requested)] first
        , verified
            [ ("the owner ran the release request", ran)
            , ("the request ran with an adopted revision still holding the chunk, which kept its buffer", standingAfterRequest == Just ChunkReady)
            , ("one adopted revision held it", holdsAfterRequest == 1)
            , ("the release was pending", pending == Set.singleton reference)
            ]
            second
        , verified
            [ ("the buffer was released once the revision that held it was over", forgotten)
            , ("no revision holds it", holdsAfter == 0)
            , ("no release is pending", null pendingAfter)
            , ("the registry no longer holds the chunk", reference `notElem` live)
            , ("a snapshot that lists it is refused as unresolved", refused)
            ]
            third
        ]

-- ---------------------------------------------------------------------------
-- Culling

-- | A chunk V (blue, at world 4..11 × 4..11) and a chunk W (at world x = 9000),
-- both listed in both views of one pass: view 0 over the target's rows 0..15 with
-- its camera at the viewport's centre, view 1 over rows 16..31 with its camera
-- 5000 units to the right. V is drawn in view 0 and skipped in view 1; W in neither.
culled ∷ Ctx → IO [FixtureResult]
culled ctx = do
  visible ← buildChunkOf ctx ChunkWorldDepth [block ctx White (0, 0, 255, 255) 1 (4, 4) (8, 8)]
  far ← buildChunkOf ctx ChunkWorldDepth [block ctx White (255, 0, 0, 255) 1 (9000, 4) (8, 8)]
  case (visible, far) of
    (Right v, Right w) → do
      held ← retainedChunks (ctxRetained ctx)
      let layer = WorldLayerWith DepthEnabled [v, w] []
          viewZero = viewOver (0, 0) (32, 16) [layer]
          viewOne = viewAt (0, 16) (32, 16) (5016, 24) [layer]
          metrics = offscreenMetrics (PixelExtent 32 32)
          skipped view reference = case (viewMapping metrics view, lookupChunk held reference) of
            (Just mapping, Just chunk) → Just (chunkCulled mapping (32, 32) (viewViewport view) ChunkWorldDepth (chunkBounds chunk) (chunkPlacementMagnitude chunk))
            _ → Nothing
      revision ← next ctx
      result ←
        renderFrame
          ctx
          "culling-1"
          revision
          [viewZero, viewOne]
          [ named "a chunk shown in one view is skipped in another" (6, 6) (6, 22)
          , named "a chunk wholly outside every view draws nothing" (6, 6) (30, 6)
          ]
      retire ctx revision
      pure
        [ verified
            [ ("the chunk is kept by the view it is in", skipped viewZero v == Just False)
            , ("the chunk is skipped by the view it is far from", skipped viewOne v == Just True)
            , ("the far chunk is skipped by both views", skipped viewZero w == Just True && skipped viewOne w == Just True)
            ]
            result
        ]
    _ → pure [failedAt "culling-1" "a chunk was not built"]

-- ---------------------------------------------------------------------------
-- The measurements

object ∷ [(String, String)] → String
object fields = "{" <> intercalate ", " [str key <> ": " <> value | (key, value) ← fields] <> "}"

str ∷ String → String
str value = "\"" <> concatMap escape value <> "\""
  where
    escape = \case
      '"' → "\\\""
      '\\' → "\\\\"
      c → [c]

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
