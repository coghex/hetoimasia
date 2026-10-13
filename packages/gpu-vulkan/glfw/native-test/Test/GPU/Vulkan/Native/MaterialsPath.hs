-- | The application materials' window-free evidence (R2D-11): the sample
-- material and two others, defined by a Template Haskell splice, registered with
-- the renderer and drawn from render-2d snapshots into offscreen targets of a
-- surface-free session through @hetoimasia-render-2d-vulkan@, every pixel of
-- every target judged against @hetoimasia-render-2d-oracle@ given a pure model of
-- each material, by "Test.GPU.Vulkan.Native.OrderedPath"'s runner.
--
-- The session is the ordinary one with the registries the window host's adapter
-- is made over ('Textures', 'Retained'): the textures are registered with it, a
-- chunk is built through the registry, and a texture is released and its index
-- reused through the textures' own operations.
--
-- = The frames
--
-- * @ordered@: the sample material, declared not cutout-capable so that it draws
--   in the ordered path, in three views of one target. The views hold the same
--   record (a second texture and a weight) and different push blocks: the push
--   block changes the material's colour. One instance names a second record of
--   the same view whose weight is zero, and one carries a tint that wraps the
--   material's colour.
-- * @cutout@: the cutout-capable sample material in a depth-enabled world layer
--   beside an instance of the default material, so the layer holds one cutout run
--   for each material; the cutout variant writes the material's colour whole,
--   a tint wraps it, and the parameter word selects the record.
-- * @split@: a UI layer of the default material, the sample material (two
--   instances, two records), a material that has a push block and no record, and
--   the default material again, in key order: the runs split by material, the
--   parameter word indexes the view's records, and a material with no record
--   takes its push block.
-- * @chunks@: two retained chunks that each carry their own record for the same
--   material and parameter word, and a dynamic instance of the view's: each
--   shows its own second texture.
-- * @reuse-before@ and @reuse-after@: a record names a texture, which is then
--   released and its index reused by another; the record's handle then samples
--   the placeholder, and a record naming the new handle samples the new texture.
--
-- Each frame names the behaviour it shows by a probe whose expectation must be
-- determinate and differ from its contrast's. The numbers the frames are checked
-- by beyond pixels (the runs the plan split, the handle's reuse) fail the frame
-- they belong to.
module Test.GPU.Vulkan.Native.MaterialsPath
  ( materialsSuite
  , runMaterials
  ) where

import Control.Concurrent (threadDelay)
import qualified Data.ByteString as ByteString
import Data.ByteString.Builder (floatLE, toLazyByteString)
import qualified Data.ByteString.Lazy as Lazy
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import System.Directory (createDirectoryIfMissing)
import Data.Word (Word32, Word8)

import Hetoimasia.Asset.Image (DecodedImage (..), TexelFormat (..))
import Hetoimasia.GPU.Vulkan.GLFW
  ( Image
  , ImageDescription (..)
  , ImageFormat (..)
  , ImageKind (..)
  , Refusal (..)
  , UploadRequest (..)
  , constructDepthFormat
  , constructImage
  )
import Hetoimasia.Math.Vector (V2 (..))
import qualified Hetoimasia.Render.Api.Texture as Api
import Hetoimasia.Render.Api.Texture.Backend (handleGeneration, handleIndex)
import Hetoimasia.Render.TwoD.Chunk (BoundsRequest (..), ChunkKind (..), ChunkRef)
import Hetoimasia.Render.TwoD.DrawPlan (DrawPlan (..), DrawRun (..), PlannedLayer (..), PlannedPass (..), PlannedView (..), RecordSource (..), planSnapshot)
import Hetoimasia.Render.TwoD.Material
import Hetoimasia.Render.TwoD.Oracle (Probe (..))
import Hetoimasia.Render.TwoD.Oracle.Material (Colour (..), MaterialModel (..), MaterialInput (..), pushFloat)
import Hetoimasia.Render.TwoD.Oracle.Material.Sample (mixModel)
import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Validation (validateSnapshotWith)
import qualified Hetoimasia.Render.TwoD.Vulkan as Render
import Hetoimasia.Render.TwoD.Vulkan.Chunks
  ( ChunkStanding (..)
  , Retained
  , buildRetainedChunkWith
  , chunkStanding
  , newRetained
  , retainedBuffers
  , retainedChunks
  )
import Hetoimasia.Render.TwoD.Vulkan.Material.Sample (mixMaterial, tintOnlyMaterial, translucentMixMaterial)
import Hetoimasia.Render.TwoD.Vulkan.Textures
  ( MarkPolicy (..)
  , Textures
  , newTextures
  , registerTexture
  , registeredMarks
  , releaseTextureNow
  )
import Test.GPU.Vulkan.Native.OrderedPath
  ( Evidence
  , FixtureResult (..)
  , Suite (..)
  , awaitPlaceholder
  , configuration
  , finishEvidence
  , runValidatedWith
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
import Test.GPU.Vulkan.Native.RetainedPath (RetainedHost (..), buildersWith)

-- ---------------------------------------------------------------------------
-- The suite

-- | The frames the case judges.
frameCount ∷ Int
frameCount = 6

materialsSuite ∷ Suite
materialsSuite = Suite "materials" "materials-probes.json" [] (replicate frameCount placeholder) True
  where
    placeholder = Fixture "frame" [] [] (const (Snapshot [])) []

-- ---------------------------------------------------------------------------
-- The textures

-- | The one-texel textures the session registers.
data Piece = Primary | SecondA | SecondB | SecondC | Plain | Short
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A piece's texel, opaque, in linear light.
texel ∷ Piece → [Word8]
texel = \case
  Primary → [200, 100, 0, 255]
  SecondA → [0, 100, 200, 255]
  SecondB → [0, 200, 100, 255]
  SecondC → [200, 0, 100, 255]
  Plain → [255, 255, 255, 255]
  Short → [100, 0, 100, 255]

-- | The texture that reuses the short-lived one's index.
replacementTexel ∷ [Word8]
replacementTexel = [0, 255, 0, 255]

data Ctx = Ctx
  { ctxHost ∷ !RetainedHost
  , ctxDirectory ∷ !FilePath
  , ctxFormat ∷ !ImageFormat
  , ctxRenderer ∷ !Render.Renderer
  , ctxTextures ∷ !Textures
  , ctxRetained ∷ !Retained
  , ctxHandles ∷ !(Map.Map Piece Api.TextureHandle)
  , ctxDecoded ∷ !(IORef (Map.Map Api.TextureHandle DecodedImage))
  , ctxMix ∷ !MaterialRef
  , ctxTranslucent ∷ !MaterialRef
  , ctxTint ∷ !MaterialRef
  , ctxReplacement ∷ !Image
  }

base ∷ Ctx → OrderedPath.Host
base = retainedBase . ctxHost

handleOf ∷ Ctx → Piece → Api.TextureHandle
handleOf ctx piece = ctxHandles ctx Map.! piece

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

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show

-- ---------------------------------------------------------------------------
-- The models

-- | The tint-only material's model: the texel's colour times the push block's,
-- keeping the texel's alpha.
tintModel ∷ MaterialModel
tintModel = MaterialModel $ \input →
  let Colour r g b a = materialTexel input
      push = materialPush input
   in Right (Colour (r * pushFloat push 0) (g * pushFloat push 4) (b * pushFloat push 8) a)

-- ---------------------------------------------------------------------------
-- The run

runMaterials ∷ RetainedHost → FilePath → IO Evidence
runMaterials host directory = do
  createDirectoryIfMissing True directory
  depth ← OrderedPath.hostAct (retainedBase host) "choosing the depth format" constructDepthFormat
  case depth of
    Left why → finish Nothing Nothing (Just why) []
    Right format
      | format /= Depth32Float →
          finish (Just format) (Just ("D32_SFLOAT is not available: the device chose " <> tshow format <> "; the materials case, which draws depth-enabled world layers, renders nothing")) Nothing []
      | otherwise →
          prepare host directory format >>= \case
            Left why → finish (Just format) Nothing (Just why) []
            Right ctx → do
              results <- sequence [ordered ctx, cutout ctx, split ctx, chunkFrame ctx, reuseBefore ctx, reuseAfter ctx]
              let wrong = if length results == frameCount then Nothing else Just ("the case judged " <> tshow (length results) <> " frames, not " <> tshow frameCount)
              finish (Just format) Nothing wrong results
  where
    finish format unavailable failure results = finishEvidence materialsSuite directory format unavailable failure results

-- | Make the renderer, the registries, the textures and the materials.
prepare ∷ RetainedHost → FilePath → ImageFormat → IO (Either Text Ctx)
prepare host directory format = do
  made ← OrderedPath.hostAct (retainedBase host) "making the renderer and the textures" $ \construction → do
    renderer ← Render.makeRenderer (buildersWith (retainedSubmit host) construction) configuration
    images ← traverse (const (constructImage construction (ImageDescription TextureImage Rgba8Linear 1 1 1))) (pieces <> [Short])
    pure ((,) <$> renderer <*> sequence images)
  case made of
    Left failure → pure (Left failure)
    Right (renderer, allImages) → do
      let (images, replacement) = (take (length pieces) allImages, drop (length pieces) allImages)
      case replacement of
        [] → pure (Left "no image was made for the replacement texture")
        replacementImage : _ → do
          uploads ← traverse (\(bytes, image) → OrderedPath.hostUpload (retainedBase host) (UploadImage image [ByteString.pack bytes])) (zip (map texel pieces) images <> [(replacementTexel, replacementImage)])
          case sequence uploads of
            Left failure → pure (Left ("an upload did not complete: " <> failure))
            Right _ →
              awaitPlaceholder (retainedBase host) (200 ∷ Int) >>= \case
                Left failure → pure (Left failure)
                Right () → do
                  textures ← newTextures
                  registered ←
                    OrderedPath.hostAct (retainedBase host) "registering the textures" $ \construction →
                      fmap sequence . traverse (registerPiece (buildersWith (retainedSubmit host) construction) textures) $ zip pieces images
                  case registered of
                    Left failure → pure (Left failure)
                    Right handles → do
                      retained ← newRetained
                      mix ← Render.registerMaterial renderer mixMaterial
                      translucent ← Render.registerMaterial renderer translucentMixMaterial
                      tint ← Render.registerMaterial renderer tintOnlyMaterial
                      decoded ← newIORef (Map.fromList [(handle, decodedOf (texel piece)) | (piece, handle) ← handles])
                      pure (Right (Ctx host directory format renderer textures retained (Map.fromList handles) decoded mix translucent tint replacementImage))
  where
    pieces = [minBound .. maxBound] ∷ [Piece]
    registerPiece builders textures (piece, image) =
      registerTexture builders textures image (decodedOf (texel piece)) DefaultMark >>= \case
        Left refusal → pure (Left (RefusedIllegal (tshow refusal)))
        Right handle → pure (Right (piece, handle))

-- ---------------------------------------------------------------------------
-- Frames

shape ∷ TargetShape
shape = depthShape 1 Rgba8Linear 32 32

-- | The models of the session's three materials, by the references issued.
modelsOf ∷ Ctx → Map.Map MaterialRef MaterialModel
modelsOf ctx = Map.fromList [(ctxMix ctx, mixModel), (ctxTranslucent ctx, mixModel), (ctxTint ctx, tintModel)]

-- | Render one frame of this snapshot (validated against the chunks the registry
-- holds) and judge it.
renderFrame ∷ Ctx → Text → [Pass] → [NamedProbe] → IO (FixtureResult, Maybe (DrawPlan))
renderFrame ctx name passes probes = do
  held ← retainedChunks (ctxRetained ctx)
  case validateSnapshotWith held (Snapshot passes) of
    Left refused → pure (FixtureResult name [] [] [] (Just ("the snapshot was refused: " <> tshow refused)), Nothing)
    Right valid → do
      marks ← registeredMarks (ctxTextures ctx)
      buffers ← retainedBuffers (ctxRetained ctx)
      decoded ← readIORef (ctxDecoded ctx)
      result ← runValidatedWith (modelsOf ctx) (base ctx) materialsSuite (ctxDirectory ctx) (ctxFormat ctx) (ctxRenderer ctx) marks buffers (`Map.lookup` decoded) name [shape] probes valid
      pure (result, Just (planSnapshot marks valid))

-- | The materials each layer's runs draw with, in order, and where their records
-- are read from.
runsOfPlan ∷ DrawPlan → [[(MaterialRef, RecordSource, Int)]]
runsOfPlan plan = [[(runMaterial run, runRecords run, runCount run) | run ← plannedRuns layer] | PlannedPass {plannedViews = views} ← planPasses plan, PlannedView {plannedLayers = layers} ← views, layer ← layers]

-- | The fixture, failed by the first check that did not hold.
verified ∷ [(Text, Bool)] → FixtureResult → FixtureResult
verified checks result = case (resultFailure result, [what | (what, False) ← checks]) of
  (Nothing, what : _) → result {resultFailure = Just ("a check failed: " <> what)}
  _ → result

named ∷ Text → (Int, Int) → (Int, Int) → NamedProbe
named behaviour (x, y) (cx, cy) = NamedProbe behaviour (Probe 0 x y) (Probe 0 cx cy)

-- | Two floats, little-endian: the sample material's push block.
twoFloats ∷ Float → Float → ByteString.ByteString
twoFloats a b = Lazy.toStrict (toLazyByteString (floatLE a <> floatLE b))

-- | Three floats and a one: the tint-only material's push block.
colour4 ∷ Float → Float → Float → ByteString.ByteString
colour4 r g b = Lazy.toStrict (toLazyByteString (floatLE r <> floatLE g <> floatLE b <> floatLE 1))

recordOf ∷ Api.TextureHandle → Word32 → MaterialRecord
recordOf handle weight = MaterialRecord [handle] [weight]

-- | An instance of a material, with its parameter word, at a depth key.
inst ∷ Ctx → MaterialRef → Piece → Word32 → Word32 → (Float, Float) → (Float, Float) → Instance
inst ctx material piece parameter key origin extent = (keyed key (quad origin extent (handleOf ctx piece))) {instanceMaterial = material, instanceParameter = parameter}

-- | A view of the whole target, UI space or world space (camera at the centre).
viewWith ∷ (Float, Float) → (Float, Float) → [(MaterialRef, MaterialData)] → [Layer] → View
viewWith (x, y) (w, h) held = ViewWith (Camera (V2 (x + w / 2) (y + h / 2)) 1 Nothing) (Viewport (V2 x y) (V2 w h)) defaultViewSettings [] (Map.fromList held)

-- ---------------------------------------------------------------------------
-- Ordered

-- | Three views of the target, the sample material in the ordered path in each.
--
-- > view A (0..15)   push strength 0.5   instance 1 at 2..13 × 1..8    record 0 (second A, weight 255) → (100, 100, 100)
-- >                                      instance 2 at 2..13 × 11..18  record 1 (weight 0)             → the texel
-- >                                      instance 3 at 2..13 × 21..28  record 0, tint (255, 128, 255)  → (100, 50, 100)
-- > view B (16..31)  push strength 0     instance 1 at 2..13 × 1..8    record 0                         → the texel
ordered ∷ Ctx → IO FixtureResult
ordered ctx = do
  let records = [recordOf (handleOf ctx SecondA) 255, recordOf (handleOf ctx SecondA) 0]
      held strength = [(ctxTranslucent ctx, MaterialData records (twoFloats strength 0))]
      mix = inst ctx (ctxTranslucent ctx) Primary
      layerA = UiLayer [mix 0 0 (2, 1) (12, 8), mix 1 1 (2, 11) (12, 8), tinted (255, 128, 255, 255) (mix 0 2 (2, 21) (12, 8))]
      layerB = UiLayer [mix 0 0 (2, 1) (12, 8)]
      views = [viewWith (0, 0) (16, 32) (held 0.5) [layerA], viewWith (16, 0) (16, 32) (held 0) [layerB]]
      probes =
        [ named "the application push block changes the material's colour" (8, 4) (24, 4)
        , named "the record's weight selects how much of the second texture is mixed in" (8, 4) (8, 14)
        , named "the engine's tint wraps the material's colour" (8, 24) (8, 4)
        ]
  (result, _) ← renderFrame ctx "ordered" [pass shape (0, 0, 0, 1) views] probes
  pure result

-- ---------------------------------------------------------------------------
-- Cutout

-- | A depth-enabled world layer of the cutout-capable sample material and the
-- default material (the view's camera is at its centre, so a world unit is a
-- target pixel).
--
-- > mix, record 0   at 2..9 × 2..9      → the second texture whole
-- > default (Plain) at 12..19 × 2..9    → the texel
-- > mix, tint       at 22..29 × 2..9    → the tinted material colour
-- > mix, record 1   at 2..9 × 12..19    → the texel (weight 0)
cutout ∷ Ctx → IO FixtureResult
cutout ctx = do
  let records = [recordOf (handleOf ctx SecondA) 255, recordOf (handleOf ctx SecondA) 0]
      held = [(ctxMix ctx, MaterialData records (twoFloats 1 0))]
      mix = inst ctx (ctxMix ctx) Primary
      layer =
        WorldLayer
          DepthEnabled
          [ mix 0 1 (2, 2) (8, 8)
          , inst ctx defaultMaterial Plain 0 1 (12, 2) (8, 8)
          , tinted (255, 128, 255, 255) (mix 0 2 (22, 2) (8, 8))
          , mix 1 1 (2, 12) (8, 8)
          ]
      views = [viewWith (0, 0) (32, 32) held [layer]]
      probes =
        [ named "the cutout variant writes the material's colour whole" (6, 6) (6, 28)
        , named "an instance of the default material is drawn by the default material beside the application's" (16, 6) (6, 6)
        , named "the engine's tint wraps the material's colour in the cutout variant" (26, 6) (6, 6)
        , named "the parameter word selects the record in the cutout path" (6, 16) (6, 6)
        ]
  (result, plan) ← renderFrame ctx "cutout" [pass shape (0, 0, 0, 1) views] probes
  let runs = maybe [] runsOfPlan plan
  pure (verified [("the layer planned into one cutout run for each material: the default's, then the sample's", map (\(material, _, count) → (material, count)) (concat runs) == [(defaultMaterial, 1), (ctxMix ctx, 3)] || map (\(material, _, count) → (material, count)) (concat runs) == [(ctxMix ctx, 3), (defaultMaterial, 1)])] result)

-- ---------------------------------------------------------------------------
-- Split

-- | A UI layer in key order: the default material, the sample material twice
-- (two records), the tint-only material, the second sample material, and the
-- default material again.
split ∷ Ctx → IO FixtureResult
split ctx = do
  let records = [recordOf (handleOf ctx SecondA) 255, recordOf (handleOf ctx SecondA) 0]
      held =
        [ (ctxMix ctx, MaterialData records (twoFloats 1 0))
        , (ctxTranslucent ctx, MaterialData (take 1 records) (twoFloats 1 0))
        , (ctxTint ctx, MaterialData [] (colour4 1 0.5 0.25))
        ]
      layer =
        UiLayer
          [ inst ctx defaultMaterial Plain 0 0 (1, 1) (6, 6)
          , inst ctx (ctxMix ctx) Primary 0 1 (9, 1) (6, 6)
          , inst ctx (ctxMix ctx) Primary 1 2 (17, 1) (6, 6)
          , inst ctx (ctxTint ctx) Primary 0 3 (25, 1) (6, 6)
          , inst ctx (ctxTranslucent ctx) Primary 0 4 (1, 9) (6, 6)
          , inst ctx defaultMaterial Primary 0 5 (9, 9) (6, 6)
          ]
      views = [viewWith (0, 0) (32, 32) held [layer]]
      probes =
        [ named "the parameter word selects the record the view holds" (12, 4) (20, 4)
        , named "a material with no record takes its push block" (28, 4) (12, 12)
        , named "the second sample material draws its own record between runs of the default" (4, 12) (12, 12)
        ]
  (result, plan) ← renderFrame ctx "split" [pass shape (0, 0, 0, 1) views] probes
  let runs = maybe [] runsOfPlan plan
      sequenceOfMaterials = [(material, count) | (material, _, count) ← concat runs]
  pure (verified [("the runs split by material in the drawing order", sequenceOfMaterials == [(defaultMaterial, 1), (ctxMix ctx, 2), (ctxTint ctx, 1), (ctxTranslucent ctx, 1), (defaultMaterial, 1)])] result)

-- ---------------------------------------------------------------------------
-- Chunks

-- | Two chunks each carrying a record of their own for the same material and
-- parameter word, listed beside a dynamic instance of the view's own record.
chunkFrame ∷ Ctx → IO FixtureResult
chunkFrame ctx = do
  marks ← registeredMarks (ctxTextures ctx)
  let build records instances =
        OrderedPath.hostAct (base ctx) "building a retained chunk" $ \construction →
          buildRetainedChunkWith (buildersWith (retainedSubmit (ctxHost ctx)) construction) (ctxRetained ctx) marks ChunkWorldDepth DeriveBounds (Map.singleton (ctxMix ctx) records) instances >>= \case
            Left refusal → pure (Left (RefusedIllegal (tshow refusal)))
            Right reference → pure (Right reference)
      mix = inst ctx (ctxMix ctx) Primary 0 1
  firstChunk ← build [recordOf (handleOf ctx SecondA) 255] [mix (2, 2) (8, 8)]
  secondChunk ← build [recordOf (handleOf ctx SecondB) 255] [mix (12, 2) (8, 8)]
  case (firstChunk, secondChunk) of
    (Right a, Right b) → do
      readyA ← awaitReady ctx a
      readyB ← awaitReady ctx b
      let held = [(ctxMix ctx, MaterialData [recordOf (handleOf ctx SecondC) 255] (twoFloats 1 0))]
          layer = WorldLayerWith DepthEnabled [a, b] [mix (22, 2) (8, 8)]
          views = [viewWith (0, 0) (32, 32) held [layer]]
          probes =
            [ named "a chunk's own record: the first chunk shows its second texture" (6, 6) (16, 6)
            , named "a second chunk with the same material and parameter word shows its own" (16, 6) (26, 6)
            , named "the view's record serves the dynamic instance beside the chunks'" (26, 6) (6, 6)
            ]
      (result, plan) ← renderFrame ctx "chunks" [pass shape (0, 0, 0, 1) views] probes
      let sources = [source | (_, source, _) ← concat (maybe [] runsOfPlan plan)]
      pure (verified [("both chunks were ready", readyA && readyB), ("the cutout runs read each chunk's records and then the view's", sources == [ChunkRecords 0, ChunkRecords 1, ViewRecords])] result)
    (Left why, _) → pure (failedAt "chunks" why)
    (_, Left why) → pure (failedAt "chunks" why)

awaitReady ∷ Ctx → ChunkRef → IO Bool
awaitReady ctx reference = go (400 ∷ Int)
  where
    go remaining =
      chunkStanding (ctxRetained ctx) reference >>= \case
        Just ChunkReady → pure True
        _
          | remaining <= 0 → pure False
          | otherwise → threadDelay 25000 >> go (remaining - 1)

failedAt ∷ Text → Text → FixtureResult
failedAt name why = FixtureResult name [] [] [] (Just why)

-- ---------------------------------------------------------------------------
-- Reuse

-- | A record naming a texture, which is then released and its index reused.
-- Before the release it shows the texture.
reuseBefore ∷ Ctx → IO FixtureResult
reuseBefore ctx = do
  let held = [(ctxMix ctx, MaterialData [recordOf (handleOf ctx Short) 255] (twoFloats 1 0))]
      layer = UiLayer [inst ctx (ctxMix ctx) Primary 0 0 (2, 2) (12, 12)]
      probes = [named "a record's handle shows its texture while the texture is live" (8, 8) (24, 24)]
  (result, _) ← renderFrame ctx "reuse-before" [pass shape (0, 0, 0, 1) [viewWith (0, 0) (32, 32) held [layer]]] probes
  pure result

-- | After the release and the reuse: the old handle, whose index another texture
-- now holds under the next generation, samples the placeholder, and a record
-- naming the new handle samples the new texture.
reuseAfter ∷ Ctx → IO FixtureResult
reuseAfter ctx = do
  let old = handleOf ctx Short
  released ← OrderedPath.hostAct (base ctx) "releasing the short-lived texture" $ \construction →
    releaseTextureNow (buildersWith (retainedSubmit (ctxHost ctx)) construction) (ctxTextures ctx) old
  case released of
    Left why → pure (failedAt "reuse-after" why)
    Right () → do
      registered ← OrderedPath.hostAct (base ctx) "registering the replacement" $ \construction →
        registerTexture (buildersWith (retainedSubmit (ctxHost ctx)) construction) (ctxTextures ctx) (ctxReplacement ctx) (decodedOf replacementTexel) DefaultMark >>= \case
          Left refusal → pure (Left (RefusedIllegal (tshow refusal)))
          Right handle → pure (Right handle)
      case registered of
        Left why → pure (failedAt "reuse-after" why)
        Right new → do
          atomicDecoded ← readIORef (ctxDecoded ctx)
          writeIORef (ctxDecoded ctx) (Map.insert new (decodedOf replacementTexel) (Map.delete old atomicDecoded))
          let held =
                [ ( ctxMix ctx
                  , MaterialData [recordOf old 255, recordOf new 255] (twoFloats 1 0)
                  )
                ]
              layer = UiLayer [inst ctx (ctxMix ctx) Primary 0 0 (2, 2) (12, 12), inst ctx (ctxMix ctx) Primary 1 1 (18, 2) (12, 12)]
              probes = [named "a released handle's record samples the placeholder, not the texture now at its index" (8, 8) (24, 8)]
          (result, _) ← renderFrame ctx "reuse-after" [pass shape (0, 0, 0, 1) [viewWith (0, 0) (32, 32) held [layer]]] probes
          pure
            ( verified
                [ ("the new texture reuses the released one's index under a later generation", handleIndex new == handleIndex old && handleGeneration new > handleGeneration old)
                ]
                result
            )
