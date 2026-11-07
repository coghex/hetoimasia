-- | The terrain material's window-free evidence (TRA-8, Q-13): the plans of the
-- terrain arena's faces, adapted through the existing fixed-quad and material
-- ABI, drawn into offscreen colour targets with a real @D32_SFLOAT@ depth image
-- in a surface-free session, every batch awaited to its actual completion before
-- its readback, every pixel judged twice — against @hetoimasia-render-2d-oracle@
-- given the terrain material's pure model, and against a hand-stated
-- line-of-sight expectation that shares no code with the planner, the material
-- or the oracle ("Test.GPU.Vulkan.Native.TerrainJudge") — and the pure pick's
-- frontmost cell and face compared with both.
--
-- The art is the approved loam and granite, copied byte for byte into
-- @samples/ecce-homo/content/textures@ and decoded by the production decoder as
-- colour art, and a technical diagnostic sheet (not artwork) of unique opaque
-- texels with transparent blocks. The fixtures are the scenes of
-- "Hetoimasia.Terrain.Render2D.Scenes", the same the CPU suite judges.
--
-- = Fixtures
--
-- * the 16 shape identities in each of 4 facings, each face of each shape
--   tinted by the technical diagnostic colour of its plane ('Tinted'), and the
--   16 at native scale with the approved art alone;
-- * roofs over a cavity cut at the roof and below it, disconnected spans, ramps
--   and corners, manual cutaways at several depths, the automatic follow with its
--   own headroom, a floor 70 levels below the cut (deeper than a 32-level storage
--   band, inside the 250-level cap), the zoom endpoints and values between, a
--   fractional camera, a viewport away from the corner, a target of content
--   scale 2 and pixel snapping;
-- * the same scene submitted in plan order, in a scrambled order, split between
--   two registered materials of identical behaviour, and split between two
--   retained chunks and the dynamic layer, which must draw one image;
-- * transparent coverage: a nearer cell's transparent texels showing what lies
--   behind;
-- * three negative controls, each a draw broken once — reversed overlap (the
--   depth keys' order inverted), an incorrect coverage mask (the whole quad)
--   and a pick through a nearer face — which the same judge must reject, on the
--   scene that makes the protected behaviour matter.
--
-- = What a fixture is judged by
--
-- The oracle judges every pixel it can decide; every pixel it cannot is listed
-- with its reason and counted for nothing. The independent expectation judges
-- every pixel it can decide, the same way. A named probe for each behaviour the
-- fixture exists to show must be determinate for the oracle and differ from its
-- contrast. A fixture's tolerance is declared in "Test.GPU.Vulkan.Native.TerrainJudge".
--
-- The depth requirement is never relaxed: where the device chooses another depth
-- format the run is reported as unable to qualify (a failure, never a skip).
module Test.GPU.Vulkan.Native.TerrainPath
  ( terrainSuite
  , runTerrain
  , terrainFixtureCount
  ) where

import Control.Concurrent.STM (atomically, check, orElse, readTVar, registerDelay, retry)
import Control.Exception (evaluate)
import Control.Monad (foldM, forM)
import Crypto.Hash.SHA256 (hash)
import Data.Array (Array, listArray, (!))
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (partition, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Numeric (showHex)
import System.Directory (createDirectoryIfMissing, doesPathExist, getCurrentDirectory)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, (</>))

import Hetoimasia.Asset (Asset (..), AssetId (..), Provenance (..))
import Hetoimasia.Asset.Image (DecodedImage (..), ImageKind (ColourImage), TexelFormat (..))
import Hetoimasia.Asset.Image.Png (decodePng)
import Hetoimasia.GPU.Vulkan.GLFW
  ( ImageDescription (..)
  , ImageFormat (..)
  , ImageKind (TextureImage)
  , Refusal (..)
  , UploadRequest (..)
  , constructDepthFormat
  , constructImage
  )
import Hetoimasia.GPU.Vulkan.Native.Shader (CheckedShader (..), CheckedShaders (..))
import Hetoimasia.Math.Vector (V2 (..))
import qualified Hetoimasia.Render.Api.Texture as Api
import Hetoimasia.Render.TwoD.Chunk (BoundsRequest (..), ChunkKind (..), ChunkRef)
import Hetoimasia.Render.TwoD.DrawPlan (DrawPlan (..), DrawRun (..), PlannedLayer (..), PlannedPass (..), PlannedView (..), planSnapshot)
import Hetoimasia.Render.TwoD.Mapping (worldToTarget)
import Hetoimasia.Render.TwoD.Material (MaterialData (..), MaterialRef)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..))
import Hetoimasia.Render.TwoD.Oracle
  ( Expectation (..)
  , OracleInput (..)
  , Probe (..)
  , TargetSpec (..)
  , expect
  , newOracleWith
  )
import Hetoimasia.Render.TwoD.Oracle.Colour (Rgba8 (..))
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Validation (validateSnapshotWith)
import qualified Hetoimasia.Render.TwoD.Vulkan as Render
import Hetoimasia.Render.TwoD.Vulkan.Chunks
  ( ChunkStanding (..)
  , Retained
  , buildRetainedChunkWith
  , chunkStandingSTM
  , liveChunks
  , newRetained
  , releaseChunkNow
  , retainedBuffers
  , retainedChunks
  )
import Hetoimasia.Render.TwoD.Vulkan.Material (DefinedMaterial (..))
import Hetoimasia.Render.TwoD.Vulkan.Textures
  ( MarkPolicy (..)
  , Textures
  , newTextures
  , registerTexture
  , registeredMark
  , registeredMarks
  , releaseTextureNow
  )
import Hetoimasia.Terrain.Cell (mkMaterialId)
import Hetoimasia.Terrain.Coordinate (TileCoord (..), axisValue)
import Hetoimasia.Terrain.Render2D.Agreement
import Hetoimasia.Terrain.Render2D.Camera (CameraState, camClip, camFacing, camRef)
import Hetoimasia.Terrain.Render2D.Evidence
import Hetoimasia.Terrain.Render2D.Material
import Hetoimasia.Terrain.Render2D.Plan
import Hetoimasia.Terrain.Render2D.Projection (ViewSetup (..), rvMapping)
import Hetoimasia.Terrain.Render2D.Scenes
import Hetoimasia.Terrain.Render2D.Vulkan.Material (terrainMaterial, terrainMaterialEquivalent)
import Hetoimasia.Terrain.Shape (ViewFacing (..), allViewFacings)
import Test.GPU.Vulkan.Native.OrderedPath
  ( Evidence
  , FixtureResult (..)
  , ProbeResult (..)
  , Suite (..)
  , awaitPlaceholder
  , configuration
  , finishEvidence
  , runValidatedWith
  )
import qualified Test.GPU.Vulkan.Native.OrderedPath as OrderedPath
import Test.GPU.Vulkan.Native.OrderedPath.Fixtures (Fixture (..), NamedProbe (..), TargetShape (..), colourFormatOf, depthShape)
import Test.GPU.Vulkan.Native.RetainedPath (RetainedHost (..), buildersWith)
import Test.GPU.Vulkan.Native.TerrainJudge

-- ---------------------------------------------------------------------------
-- The fixtures

-- | How a scene's faces are submitted.
data Variant
  = -- | One material, the instances in plan order.
    Dynamic
  | -- | One material, the instances in a scrambled order.
    Scrambled
  | -- | The faces split between two registered materials of identical behaviour,
    -- the instances scrambled: the runs group by material.
    TwoMaterials
  | -- | Two retained chunks and a dynamic remainder, the chunks built from
    -- scrambled instances.
    Retained
  | -- | A control: the depth keys' order inverted, which the judge must reject.
    ReversedKeys
  | -- | A control: every coverage mask the whole quad, which the judge must reject.
    WholeQuad
  | -- | A control: drawn correctly, but the pick answers through the backmost face,
    -- which the judge must reject.
    BackmostPick
  deriving stock (Eq, Show)

-- | What a fixture must show, each by a named probe that is determinate for the
-- oracle and differs from its contrast.
data Need = Foreground | Overlap | Reveal | Cap | Clipped | SnapSensitive
  deriving stock (Eq, Show)

data Spec = Spec
  { specName ∷ !String
  , specScenes ∷ ![Scene]
  -- ^ One pass each, into a target of its own.
  , specVariant ∷ !Variant
  , specLook ∷ !Look
  , specNeeds ∷ ![Need]
  , specControl ∷ !Bool
  -- ^ Whether the independent judge must reject the draw.
  , specCamera ∷ !(Maybe (Integer, Integer))
  -- ^ The cut level and vertical reference the scene's camera must come to, stated
  -- here by hand, so that a camera that was panned off its column is a failure.
  }

suffixOf ∷ Variant → String
suffixOf = \case
  Dynamic → ""
  Scrambled → "-scrambled"
  TwoMaterials → "-two-materials"
  Retained → "-retained"
  ReversedKeys → "-control-reversed-overlap"
  WholeQuad → "-control-whole-quad-mask"
  BackmostPick → "-control-pick-through-nearer-face"

-- | A fixture of one scene.
spec ∷ Look → [Need] → Variant → Scene → Spec
spec look needs variant sc = Spec (sceneName sc <> suffixOf variant) [sc] variant look needs (isControl variant) Nothing

-- | A fixture that must come to this cut level and vertical reference.
expecting ∷ (Integer, Integer) → Spec → Spec
expecting camera s = s {specCamera = Just camera}

-- | A fixture of several scenes, each drawn in a pass of its own into a small
-- target, so the oracle's work for a pixel is that of its own scene alone.
specMany ∷ String → Look → [Need] → [Scene] → Spec
specMany name look needs scs = Spec name scs Dynamic look needs False Nothing

isControl ∷ Variant → Bool
isControl variant = variant `elem` [ReversedKeys, WholeQuad, BackmostPick]

-- | The fixtures, in the order they are rendered. The oracle's cost for a pixel
-- grows with the faces of its pass, and the whole scenario must finish inside
-- the 20-second child deadline, so the scenes are small and drawn at zooms that
-- keep their targets small; the full 16 × 4 matrix is 16 one-cell passes in each
-- facing, and native scale is shown by the same matrix in one facing and by the
-- zoom endpoints.
specs ∷ [Spec]
specs =
  [specMany ("matrix-" <> show facing <> "-0.25") Tinted [Foreground] [shapeMatrixCell shape facing 0.25 | shape ← [0 .. 15]] | facing ← allViewFacings]
    <> [specMany "native-scale-FaceSouth-1" Plain [Foreground] [shapeMatrixCell shape FaceSouth 1 | shape ← [0, 7]]]
    <> [ spec Plain [Foreground, Overlap] Dynamic (atZoom 0.125 (roofOverCavity 2 FaceSouth))
       , spec Plain [Foreground, Overlap, Cap] Dynamic (atZoom 0.125 (roofOverCavity 1 FaceSouth))
       , spec Plain [Foreground, Overlap, Cap] Dynamic (atZoom 0.125 (roofOverCavity 1 FaceWest))
       , spec Plain [Foreground, Overlap, Cap] Scrambled (atZoom 0.125 (roofOverCavity 1 FaceWest))
       , spec Plain [Foreground, Overlap, Cap] TwoMaterials (atZoom 0.125 (roofOverCavity 1 FaceWest))
       , spec Plain [Foreground, Overlap, Cap] Retained (atZoom 0.125 (roofOverCavity 1 FaceWest))
       , spec Plain [Foreground, Overlap] Dynamic (atZoom 0.125 (disconnectedSpans FaceNorth))
       , spec Plain [Foreground, Overlap] Dynamic (atZoom 0.125 (rampsCorners FaceEast))
       ]
    <> [spec Plain [Foreground, Cap] Dynamic (atZoom 0.125 (staircase cut FaceSouth)) | cut ← [1, 3]]
    <> [spec Plain [Foreground] Dynamic (atZoom 0.125 (staircase 5 FaceSouth))]
    <> [ expecting (28, 4) (spec Plain [Foreground, Cap] Dynamic (atZoom 0.125 (followHeadroom FaceSouth)))
       , expecting (0, -33) (spec Plain [Foreground] Dynamic (deepFloor FaceSouth))
       ]
    <> [spec Plain [Foreground] Dynamic (capTarget (96, 64) (zoomEndpoint zoom)) | zoom ← [0.125, 8]]
    <> [ spec Plain [Foreground] Dynamic (atZoom 0.1875 fractionalCamera)
       , spec Plain [Foreground, Clipped] Dynamic (viewportOffset 0.125)
       , spec Plain [Foreground] Dynamic (capTarget (96, 64) (atZoom 0.125 scaledTarget))
       , spec Plain [Foreground, SnapSensitive] Dynamic snapped
       ]
    <> [spec Tinted [Foreground, Overlap, Reveal] Dynamic (atZoom 0.25 (diagnosticOverlap facing)) | facing ← [FaceSouth, FaceWest]]
    <> [ spec Plain [Foreground, Overlap] ReversedKeys (atZoom 0.125 (disconnectedSpans FaceSouth))
       , spec Plain [Foreground] WholeQuad (atZoom 0.125 (rampsCorners FaceSouth))
       , spec Plain [Foreground, Overlap] BackmostPick (atZoom 0.125 (disconnectedSpans FaceSouth))
       ]

-- | One cell of a shape in a facing at a zoom, in a target sized to its hexagon.
shapeMatrixCell ∷ Int → ViewFacing → Float → Scene
shapeMatrixCell shape facing zoom = atZoom zoom (singleShape shape facing)

terrainFixtureCount ∷ Int
terrainFixtureCount = length specs

-- | The suite: its fixtures are the specs, counted for the record's verdict.
terrainSuite ∷ Suite
terrainSuite = Suite "terrain" "tra8-terrain-probes.json" [] (map placeholder specs) True
  where
    placeholder s = Fixture (Text.pack (specName s)) [] [] (const (Snapshot [])) []

-- ---------------------------------------------------------------------------
-- The session

data Ctx = Ctx
  { ctxHost ∷ !RetainedHost
  , ctxDirectory ∷ !FilePath
  , ctxRenderer ∷ !Render.Renderer
  , ctxTextures ∷ !Textures
  , ctxRetained ∷ !Retained
  , ctxHandles ∷ !(Map.Map String Api.TextureHandle)
  , ctxDecoded ∷ !(Map.Map Api.TextureHandle DecodedImage)
  , ctxPrimary ∷ !MaterialRef
  , ctxSecond ∷ !MaterialRef
  , ctxSheets ∷ !(Map.Map String ArtPixels)
  , ctxStyle ∷ !TerrainStyle
  , ctxDevice ∷ !Text
  , ctxJudged ∷ !(IORef (Map.Map String Judged))
  -- ^ The pure judge's answer for a scene and picker, shared by its variants.
  }

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show

-- | The approved sheets' repository paths.
approvedPath ∷ String → FilePath
approvedPath name = "samples/ecce-homo/content/textures" </> (name <> ".png")

-- | A path found under the working directory or above it: the runner starts the
-- suite from the repository root, and a package directory is the other place a
-- developer may run it from.
findUpwards ∷ FilePath → IO (Maybe FilePath)
findUpwards relative = getCurrentDirectory >>= go
  where
    go directory = do
      found ← doesPathExist (directory </> relative)
      if found
        then pure (Just (directory </> relative))
        else
          let parent = takeDirectory directory
           in if parent == directory then pure Nothing else go parent

-- | A sheet's level-0 texels (premultiplied sRGB) as 'ArtPixels'.
pixelsOf ∷ DecodedImage → ArtPixels
pixelsOf decoded = ArtPixels w h $ \x y →
  let base = 4 * (y * w + x)
      at i = ByteString.index level i
   in (at base, at (base + 1), at (base + 2), at (base + 3))
  where
    w = fromIntegral (decodedWidth decoded)
    h = fromIntegral (decodedHeight decoded)
    level = case decodedLevels decoded of
      first : _ → first
      [] → ByteString.empty

-- | The technical diagnostic sheet as a decoded image.
diagnosticDecoded ∷ DecodedImage
diagnosticDecoded =
  DecodedImage
    { decodedFormat = TexelRgba8Srgb
    , decodedWidth = 96
    , decodedHeight = 64
    , decodedLevels = [ByteString.pack (concat [[r, g, b, a] | y ← [0 .. 63], x ← [0 .. 95], let (r, g, b, a) = artTexel diagnosticSheet x y])]
    , decodedBinaryAlpha = True
    }

-- | The approved sheets decoded as colour art, and the diagnostic sheet.
loadSheets ∷ IO (Either Text [(String, DecodedImage, ByteString.ByteString)])
loadSheets = do
  approved ← forM ["loam", "granite"] $ \name → do
    found ← findUpwards (approvedPath name)
    case found of
      Nothing → pure (Left ("the approved " <> Text.pack name <> " sheet was not found above the working directory"))
      Just path → do
        bytes ← ByteString.readFile path
        pure $ case decodePng ColourImage (Asset (AssetId (Text.pack name)) (FromFile path)) bytes of
          Left refusal → Left ("the approved " <> Text.pack name <> " sheet was refused: " <> tshow refusal)
          Right decoded → Right (name, decoded, bytes)
  pure (traverse id approved <&> (<> [("diagnostic", diagnosticDecoded, ByteString.empty)]))
  where
    (<&>) = flip fmap

sha256Hex ∷ ByteString.ByteString → String
sha256Hex = concatMap two . ByteString.unpack . hash
  where
    two byte = (if byte < 16 then "0" else "") <> showHex byte ""

-- | The session's depth must be @D32_SFLOAT@; a fixture is never rendered over
-- anything lower, and nothing is skipped.
runTerrain ∷ RetainedHost → IO (Maybe Text) → FilePath → IO Evidence
runTerrain host deviceName directory = do
  started ← getCurrentTime
  createDirectoryIfMissing True directory
  depth ← OrderedPath.hostAct (retainedBase host) "choosing the depth format" constructDepthFormat
  device ← fromMaybe "unknown" <$> deviceName
  case depth of
    Left why → finish Nothing (Just why) []
    Right format
      | format /= Depth32Float → finish (Just format) (Just ("this device cannot qualify the terrain material: it chose the depth format " <> tshow format <> ", never a lower-precision substitute for D32_SFLOAT; nothing was rendered")) []
      | otherwise →
          loadSheets >>= \case
            Left why → finish (Just format) (Just why) []
            Right sheets →
              prepare host directory device sheets >>= \case
                Left why → finish (Just format) (Just why) []
                Right ctx → do
                  results ← foldM (\done s → (: done) <$> timed s (runSpec ctx s)) [] specs
                  teardown ctx
                  ended ← getCurrentTime
                  let ordered = reverse results
                  writeRecord ctx sheets format (realToFrac (diffUTCTime ended started)) ordered
                  finish (Just format) Nothing (map fst ordered)
  where
    finish format failure results = finishEvidence terrainSuite directory format Nothing failure results

-- | A fixture's run, with the seconds it took noted in its probe results' failure
-- field never, and in the fixture record: the time is evidence of the budget.
timed ∷ Spec → IO (FixtureResult, Extra) → IO (FixtureResult, Extra)
timed _ action = do
  started ← getCurrentTime
  (result, extra) ← action
  acted ← getCurrentTime
  -- The verdicts are lazy: force each here, so the time is the fixture's, and say
  -- where it went: the oracle's judging of every pixel, the independent
  -- expectation, and the pure coverage, model and pick judge.
  _ ← evaluate (OrderedPath.fixturePassed result)
  oracled ← getCurrentTime
  _ ← evaluate (maybe 0 indMismatchCount (extraIndependent extra))
  independent ← getCurrentTime
  _ ← evaluate (maybe 0 judgedMismatchCount (extraPick extra))
  ended ← getCurrentTime
  let seconds a b = realToFrac (diffUTCTime b a)
  pure (result, extra {extraSeconds = [seconds started acted, seconds acted oracled, seconds oracled independent, seconds independent ended]})

-- | Make the renderer, the registries, the textures and both materials.
prepare ∷ RetainedHost → FilePath → Text → [(String, DecodedImage, ByteString.ByteString)] → IO (Either Text Ctx)
prepare host directory device sheets = do
  made ← OrderedPath.hostAct (retainedBase host) "making the renderer and the textures" $ \construction → do
    renderer ← Render.makeRenderer (buildersWith (retainedSubmit host) construction) configuration
    images ← traverse (\(_, decoded, _) → constructImage construction (ImageDescription TextureImage Rgba8Srgb (decodedWidth decoded) (decodedHeight decoded) 1)) sheets
    pure ((,) <$> renderer <*> sequence images)
  case made of
    Left failure → pure (Left failure)
    Right (renderer, images) → do
      uploads ← traverse (\((_, decoded, _), image) → OrderedPath.hostUpload (retainedBase host) (UploadImage image (decodedLevels decoded))) (zip sheets images)
      case sequence uploads of
        Left failure → pure (Left ("an upload did not complete: " <> failure))
        Right _ →
          awaitPlaceholder (retainedBase host) (200 ∷ Int) >>= \case
            Left failure → pure (Left failure)
            Right () → do
              textures ← newTextures
              registered ← OrderedPath.hostAct (retainedBase host) "registering the sheets" $ \construction →
                fmap sequence . forM (zip sheets images) $ \((name, decoded, _), image) →
                  registerTexture (buildersWith (retainedSubmit host) construction) textures image decoded DefaultMark >>= \case
                    Left refusal → pure (Left (RefusedIllegal (tshow refusal)))
                    Right handle → pure (Right (name, handle, decoded))
              case registered of
                Left failure → pure (Left failure)
                Right entries → do
                  retained ← newRetained
                  judged ← newIORef Map.empty
                  primary ← Render.registerMaterial renderer terrainMaterial
                  second ← Render.registerMaterial renderer terrainMaterialEquivalent
                  let style = styleFromList [(either (error . show) id (mkMaterialId name), isoSheet handle) | (name, handle, _) ← entries]
                  pure
                    ( Right
                        Ctx
                          { ctxHost = host
                          , ctxDirectory = directory
                          , ctxRenderer = renderer
                          , ctxTextures = textures
                          , ctxRetained = retained
                          , ctxHandles = Map.fromList [(name, handle) | (name, handle, _) ← entries]
                          , ctxDecoded = Map.fromList [(handle, decoded) | (_, handle, decoded) ← entries]
                          , ctxPrimary = primary
                          , ctxSecond = second
                          , ctxSheets = Map.fromList [(name, pixelsOf decoded) | (name, _, decoded) ← entries]
                          , ctxStyle = style
                          , ctxDevice = device
                          , ctxJudged = judged
                          }
                    )

-- | Release what the run made: the retained chunks it still holds, and the sheets.
teardown ∷ Ctx → IO ()
teardown ctx = do
  live ← liveChunks (ctxRetained ctx)
  _ ← OrderedPath.hostAct (retainedBase (ctxHost ctx)) "releasing the retained chunks" $ \construction → do
    let builders = buildersWith (retainedSubmit (ctxHost ctx)) construction
    results ← traverse (releaseChunkNow builders (ctxRetained ctx)) live
    pure (sequence_ results)
  _ ← OrderedPath.hostAct (retainedBase (ctxHost ctx)) "releasing the sheets" $ \construction → do
    let builders = buildersWith (retainedSubmit (ctxHost ctx)) construction
    results ← traverse (releaseTextureNow builders (ctxTextures ctx)) (Map.elems (ctxHandles ctx))
    pure (sequence_ results)
  pure ()

-- ---------------------------------------------------------------------------
-- One fixture

-- | What a fixture's record keeps besides its probes.
data Extra = Extra
  { extraSpec ∷ !Spec
  , extraPlanFaces ∷ ![Int]
  , extraCompleteness ∷ ![String]
  , extraIdentity ∷ ![String]
  , extraRuns ∷ ![(String, Int, String)]
  , extraMarks ∷ ![(String, Maybe Bool)]
  , extraIndependent ∷ !(Maybe Independent)
  , extraPick ∷ !(Maybe Judged)
  , extraRejected ∷ !(Maybe Bool)
  , extraTargets ∷ ![(Int, Int)]
  , extraSnapDifferences ∷ !(Maybe Int)
  -- ^ For a snapping fixture: pixels read as the snapped view and not as the unsnapped one.
  , extraSeconds ∷ ![Double]
  -- ^ Rendering and reading back, the oracle's verdicts, the independent expectation, the pure judge.
  }

emptyExtra ∷ Spec → Extra
emptyExtra s = Extra s [] [] [] [] [] Nothing Nothing Nothing [] Nothing []

failed ∷ String → String → FixtureResult
failed name why = FixtureResult (Text.pack name) [] [] [] (Just (Text.pack why))

-- | The faces of a plan as a variant submits them.
variantFaces ∷ Variant → [PlannedFace] → [PlannedFace]
variantFaces = \case
  ReversedKeys → \faces →
    let keys = sortOn negate (map faceDepthKey faces)
     in [f {faceDepthKey = k} | (f, k) ← zip (sortOn faceDepthKey faces) keys]
  WholeQuad → map (\f → f {faceMask = [(0, 0), (1, 0), (1, 1), (0, 1)]})
  _ → id

-- | A deterministic scramble: neither plan order, nor reversed, nor sorted by anything the
-- planner or the renderer uses.
scramble ∷ [a] → [a]
scramble items = map snd (sortOn fst [(((i * 2654435761) `mod` 4294967291) ∷ Int, item) | (i, item) ← zip [1 ..] items])

-- | One scene of a fixture: its plan, its camera, the target it is drawn into and the
-- pass that draws it.
data Part = Part
  { partScene ∷ !Scene
  , partPlan ∷ !Plan
  , partCamera ∷ !CameraState
  , partShape ∷ !TargetShape
  , partPass ∷ !Pass
  }

runSpec ∷ Ctx → Spec → IO (FixtureResult, Extra)
runSpec ctx s = case traverse planOf (zip [1 ..] (specScenes s)) of
  Left why → pure (failed (specName s) why, emptyExtra s)
  Right planned → case specVariant s of
    Retained → case planned of
      [(sc, plan, shape)] → retainedFixture ctx s sc plan shape
      _ → pure (failed (specName s) "a retained fixture draws one scene", emptyExtra s)
    variant → do
      let drawn = traverse (draw variant) planned
      case drawn of
        Left why → pure (failed (specName s) why, emptyExtra s)
        Right parts → renderSnapshot ctx s parts
  where
    planOf (index, sc) = case scenePlan sc of
      Left refused → Left ("the scene " <> sceneName sc <> "'s plan was refused: " <> show refused)
      Right plan → Right (sc, plan, shapeOf index sc)
    draw variant (sc, plan, shape) = do
      let camera = sceneCameraFollowed sc
          faces = variantFaces variant (planFaces plan)
      adapted ← either (\refused → Left ("the faces could not be adapted: " <> show refused)) Right (adaptFaces (ctxStyle ctx) faces)
      let entries = adaptedFaces adapted
          materialFor entry = if even (cellX' (adaptedFace entry)) then ctxPrimary ctx else ctxSecond ctx
          instances = case variant of
            TwoMaterials → [instanceOf camera (materialFor e) e | e ← scramble entries]
            Scrambled → [instanceOf camera (ctxPrimary ctx) e | e ← scramble entries]
            _ → [instanceOf camera (ctxPrimary ctx) e | e ← entries]
          held = [(ref, MaterialData (adaptedRecords adapted) ByteString.empty) | ref ← [ctxPrimary ctx, ctxSecond ctx]]
      view ← maybe (Left "the plan's view is not representable") Right (terrainView plan held [WorldLayer DepthEnabled instances])
      pure (Part sc plan camera shape (Pass (OffscreenTarget (shapeRef shape)) (ClearColour 0 0 0 1) [view]))
    instanceOf camera material entry = (adaptedInstance material entry) {instanceTint = tintOfFace s camera (adaptedFace entry)}

-- | The tint an instance carries under the fixture's look.
tintOfFace ∷ Spec → CameraState → PlannedFace → Tint
tintOfFace s camera face = case specLook s of
  Plain → Tint 255 255 255 255
  Tinted → let (r, g, b) = surfaceTint (faceSurface (camFacing camera) face) in Tint r g b 255

-- | The tile's X and Y as integers, for the even and odd split.
cellX', cellY' ∷ PlannedFace → Integer
cellX' face = toInteger (axisValue (tileX (faceCell face)))
cellY' face = toInteger (axisValue (tileY (faceCell face)))

-- | The target scene number @index@ is drawn into: its framebuffer extent, the
-- metrics of its view setup, and a depth image of its extent.
shapeOf ∷ Int → Scene → TargetShape
shapeOf index sc = (depthShape (fromIntegral (index ∷ Int)) Rgba8Srgb (fromIntegral w) (fromIntegral h)) {shapeMetrics = setupMetrics (sceneSetup sc)}
  where
    (w, h) = sceneTarget sc

-- ---------------------------------------------------------------------------
-- The retained variant

-- | Two retained chunks, of the cells of even X and of odd X with even Y, built
-- from scrambled instances, and the rest dynamic, in one depth-enabled layer.
retainedFixture ∷ Ctx → Spec → Scene → Plan → TargetShape → IO (FixtureResult, Extra)
retainedFixture ctx s sc plan shape =
  case adaptFaces (ctxStyle ctx) (planFaces plan) of
    Left refused → pure (failed (specName s) ("the faces could not be adapted: " <> show refused), emptyExtra s)
    Right adapted → do
      marks ← registeredMarks (ctxTextures ctx)
      let camera = sceneCameraFollowed sc
          entries = adaptedFaces adapted
          records = adaptedRecords adapted
          held = [(ref, MaterialData records ByteString.empty) | ref ← [ctxPrimary ctx, ctxSecond ctx]]
          instanceFor e = (adaptedInstance (ctxPrimary ctx) e) {instanceTint = tintOfFace s camera (adaptedFace e)}
          (even', odd') = partition (even . cellX' . adaptedFace) entries
          (chunkB, dynamic) = partition (even . cellY' . adaptedFace) odd'
          built group = OrderedPath.hostAct (retainedBase (ctxHost ctx)) "building a retained chunk" $ \construction →
            buildRetainedChunkWith
              (buildersWith (retainedSubmit (ctxHost ctx)) construction)
              (ctxRetained ctx)
              marks
              ChunkWorldDepth
              DeriveBounds
              (Map.singleton (ctxPrimary ctx) records)
              (map instanceFor (scramble group))
              >>= \case
                Left refusal → pure (Left (RefusedIllegal (tshow refusal)))
                Right reference → pure (Right reference)
      firstChunk ← built even'
      secondChunk ← built chunkB
      case (firstChunk, secondChunk) of
        (Right a, Right b) → do
          ready ← and <$> traverse (awaitChunk (ctxRetained ctx)) [a, b]
          if not ready
            then pure (failed (specName s) "a retained chunk's upload did not complete", emptyExtra s)
            else case terrainView plan held [WorldLayerWith DepthEnabled [a, b] (map instanceFor (scramble dynamic))] of
              Nothing → pure (failed (specName s) "the plan's view is not representable", emptyExtra s)
              Just view → do
                outcome ← renderSnapshot ctx s [Part sc plan camera shape (Pass (OffscreenTarget (shapeRef shape)) (ClearColour 0 0 0 1) [view])]
                _ ← OrderedPath.hostAct (retainedBase (ctxHost ctx)) "releasing the fixture's chunks" $ \construction → do
                  let builders = buildersWith (retainedSubmit (ctxHost ctx)) construction
                  results ← traverse (releaseChunkNow builders (ctxRetained ctx)) [a, b]
                  pure (sequence_ results)
                pure outcome
        (Left why, _) → pure (failed (specName s) ("a retained chunk was not built: " <> Text.unpack why), emptyExtra s)
        (_, Left why) → pure (failed (specName s) ("a retained chunk was not built: " <> Text.unpack why), emptyExtra s)

-- | Wait, on the chunk's own upload state and not on a clock's ordering, for it to
-- be ready or to fail; a deadline only bounds a hung upload.
awaitChunk ∷ Retained → ChunkRef → IO Bool
awaitChunk retained reference = do
  deadline ← registerDelay 10000000
  atomically $
    ( chunkStandingSTM retained reference >>= \case
        Just ChunkReady → pure True
        Just (ChunkFailed _) → pure False
        _ → retry
    )
      `orElse` (readTVar deadline >>= check >> pure False)

-- ---------------------------------------------------------------------------
-- Rendering and judging

-- | Render the parts of a fixture, one pass each, and judge every pixel of every target.
renderSnapshot ∷ Ctx → Spec → [Part] → IO (FixtureResult, Extra)
renderSnapshot ctx s parts = do
  let snapshot = Snapshot (map partPass parts)
  held ← retainedChunks (ctxRetained ctx)
  case validateSnapshotWith held snapshot of
    Left refused → pure (failed name ("the snapshot was refused: " <> show refused), baseExtra)
    Right valid → do
      marks ← registeredMarks (ctxTextures ctx)
      buffers ← retainedBuffers (ctxRetained ctx)
      let shapes = map partShape parts
          models = Map.fromList [(ref, terrainModel) | ref ← [ctxPrimary ctx, ctxSecond ctx]]
          decodedAt = (`Map.lookup` ctxDecoded ctx)
          grids = map gridOf parts
          gridOf part =
            let sc = partScene part
                (gw, gh) = sceneTarget sc
             in listArray ((0, 0), (gw - 1, gh - 1)) [expectedAtFast (`Map.lookup` ctxSheets ctx) sc (partCamera part) (partPlan part) (x, y) | x ← [0 .. gw - 1], y ← [0 .. gh - 1]] ∷ Array (Int, Int) Expected
          oracle = newOracleWith models (oracleInput valid marks shapes decodedAt)
          determinate probe = case expect oracle probe of
            e@(Expected _ _) → Just e
            _ → Nothing
          firstGrid = case grids of
            g : _ → g
            [] → listArray ((0, 0), (0, 0)) [ExpectedClear]
          alternative part need = case need of
            Clipped → altGrid part (partScene part) {sceneViewport = let (aw, ah) = sceneTarget (partScene part) in (0, 0, fromIntegral aw, fromIntegral ah)}
            SnapSensitive → altGrid part (partScene part) {sceneSnap = False}
            _ → Nothing
          altGrid part alt = case scenePlan alt of
            Right altPlan →
              let (gw, gh) = sceneTarget alt
               in Just ((listArray ((0, 0), (gw - 1, gh - 1)) [expectedAtFast (`Map.lookup` ctxSheets ctx) alt (partCamera part) altPlan (x, y) | x ← [0 .. gw - 1], y ← [0 .. gh - 1]] ∷ Array (Int, Int) Expected) !)
            Left _ → Nothing
          named = case parts of
            part : _ → chooseNamed (partPlan part) (partScene part) (firstGrid !) (alternative part) determinate (specNeeds s)
            [] → []
          cameraProblems =
            [ "the camera came to cut " <> show (axisValue (camClip (partCamera part)), camRef (partCamera part)) <> " (cut, reference), expected " <> show wanted <> ": it was panned off its column or follows another surface"
            | Just wanted <- [specCamera s]
            , part ← parts
            , (toInteger (axisValue (camClip (partCamera part))), camRef (partCamera part)) /= wanted
            ]
          missing = [need | need ← specNeeds s, need `notElem` (SnapSensitive : map fst named)]
          runFacts = runsOf (planSnapshot marks valid)
      markFacts ← traverse (\(sheet, handle) → (,) sheet <$> registeredMark (ctxTextures ctx) handle) (Map.toList (ctxHandles ctx))
      result ← runValidatedWith models (retainedBase (ctxHost ctx)) terrainSuite (ctxDirectory ctx) Depth32Float (ctxRenderer ctx) marks buffers decodedAt (Text.pack name) shapes (map snd named) valid
      let perPass = splitPasses (map (sceneTarget . partScene) parts) (resultProbes result)
          independents = [judgeIndependent (specLook s) (sceneTarget (partScene part)) (grid !) (observedFrom (fst (sceneTarget (partScene part))) probes) | (part, grid, probes) ← zip3 parts grids perPass]
          independent = foldr1 plus independents
          -- Pixels the readback shows as the snapped view and not as the same view
          -- without snapping: the expectations differ by more than the tolerance, and
          -- the pixel read agrees with the snapped one and not with the other.
          snapDifferences = case (SnapSensitive `elem` specNeeds s, parts, perPass) of
            (True, part : _, firstProbes : _) → case alternative part SnapSensitive of
              Just unsnapped →
                let (gw, gh) = sceneTarget (partScene part)
                    observed = observedFrom gw firstProbes
                    tolerance = lookTolerance (specLook s)
                    near (a, b, c, d) (Rgba8 e f g h') = all (\(x, y) → abs (fromIntegral x - fromIntegral y) <= tolerance) [(a, e), (b, f), (c, g), (d, h')]
                 in length
                      [ ()
                      | x ← [0 .. gw - 1]
                      , y ← [0 .. gh - 1]
                      , Just with ← [expectedRgba (specLook s) (firstGrid ! (x, y))]
                      , Just without ← [expectedRgba (specLook s) (unsnapped (x, y))]
                      , Just seen ← [observed x y]
                      , near with seen
                      , not (near without seen)
                      ]
              Nothing → 0
            _ → 0
          plus a b = Independent (indCompared a + indCompared b) (indAmbiguous a + indAmbiguous b) (indCovered a + indCovered b) (indReveals a + indReveals b) (indMismatchCount a + indMismatchCount b) (take 12 (indMismatches a <> indMismatches b))
      pickJudgeds ← traverse (pureJudge ctx s . partScene) parts
      let pickJudged = foldr1 plusJudged pickJudgeds
          plusJudged a b = Judged (judgedCompared a + judgedCompared b) (judgedSkipped a + judgedSkipped b) (judgedMismatches a <> judgedMismatches b) (judgedHoles a + judgedHoles b) (judgedReveals a + judgedReveals b) (judgedCovered a + judgedCovered b)
          rejected
            | specControl s = Just (indMismatchCount independent > 0 || judgedMismatchCount pickJudged > 0)
            | otherwise = Nothing
          problems =
            [ "the independent expectation found " <> show (indMismatchCount independent) <> " mismatches, e.g. " <> show (take 3 (indMismatches independent))
            | not (specControl s)
            , indMismatchCount independent > 0
            ]
              <> ["the pure pick, the planner's coverage or the material's model disagreed at " <> show (judgedMismatchCount pickJudged) <> " pixels, e.g. " <> show (take 3 (judgedMismatches pickJudged)) | not (specControl s), judgedMismatchCount pickJudged > 0]
              <> cameraProblems
              <> ["pixel snapping changed " <> show snapDifferences <> " pixels the readback shows, fewer than the 20 that discriminate it from a view that ignores the setting" | SnapSensitive `elem` specNeeds s, snapDifferences < 20]
              <> ["no determinate probe for " <> show need | need ← missing]
              <> ["the independent expectation compared no pixel the scene covers" | indCovered independent == 0]
              <> ["the control was not rejected: the judge found no disagreement with a draw broken on purpose" | rejected == Just False]
              <> [Text.unpack reason | Just reason ← [resultFailure result]]
          finished = case problems of
            [] → result
            _ → result {resultFailure = Just (Text.pack (concatMap (<> "; ") problems))}
          factsExtra =
            Extra
              { extraSpec = s
              , extraPlanFaces = [length (planFaces (partPlan part)) | part ← parts]
              , extraCompleteness = [show (planCompleteness (partPlan part)) | part ← parts]
              , extraIdentity = [show (planIdentity (partPlan part)) | part ← parts]
              , extraRuns = runFacts
              , extraMarks = markFacts
              , extraIndependent = Just independent
              , extraPick = Just pickJudged
              , extraRejected = rejected
              , extraTargets = map (sceneTarget . partScene) parts
              , extraSnapDifferences = if SnapSensitive `elem` specNeeds s then Just snapDifferences else Nothing
              , extraSeconds = []
              }
      pure (finished, factsExtra)
  where
    name = specName s
    baseExtra = (emptyExtra s) {extraTargets = map (sceneTarget . partScene) parts}
    oracleInput valid marks shapes decodedAt =
      OracleInput
        { inputSnapshot = valid
        , inputCutoutMarks = marks
        , inputWindow = Nothing
        , inputOffscreen = Map.fromList [(shapeRef shape, TargetSpec (shapeMetrics shape) (colourFormatOf (shapeFormat shape)) (PixelExtent (fromIntegral (shapeWidth shape)) (fromIntegral (shapeHeight shape)))) | shape ← shapes]
        , inputTextures = decodedAt
        }

-- | The oracle's probes of a fixture, which run pass by pass and row by row, split by pass.
splitPasses ∷ [(Int, Int)] → [ProbeResult] → [[ProbeResult]]
splitPasses extents probes = case extents of
  [] → []
  (w, h) : rest →
    let (these, others) = splitAt (w * h) probes
     in these : splitPasses rest others

-- | The draw path of each run the plan made, with the material's reference and the number of its instances.
runsOf ∷ DrawPlan → [(String, Int, String)]
runsOf plan =
  [ (show (runPath run), runCount run, show (runMaterial run))
  | PlannedPass {plannedViews = views} ← planPasses plan
  , PlannedView {plannedLayers = layers} ← views
  , layer ← layers
  , run ← plannedRuns layer
  ]

-- | The readback's pixels by (x, y), from the oracle probes, which run row by row.
observedFrom ∷ Int → [ProbeResult] → Int → Int → Maybe Rgba8
observedFrom width probes = \x y → table ! (y * width + x)
  where
    table = listArray (0, length probes - 1) (map probeObserved probes) ∷ Array Int (Maybe Rgba8)

-- | The named probes the fixture's needs ask for: for each, a pixel the scene's
-- hand-stated expectation says shows the behaviour and a contrast where it is
-- absent, both determinate for the oracle and expected to differ.
chooseNamed
  ∷ Plan
  → Scene
  → ((Int, Int) → Expected)
  → (Need → Maybe ((Int, Int) → Expected))
  → (Probe → Maybe Expectation)
  → [Need]
  → [(Need, NamedProbe)]
chooseNamed plan sc expectedAtPixel alternative determinate = concatMap one
  where
    (w, h) = sceneTarget sc
    pixels = [(x, y) | y ← [0 .. h - 1], x ← [0 .. w - 1]]
    centreDistance (x, y) = (x - w `div` 2) ^ (2 ∷ Int) + (y - h `div` 2) ^ (2 ∷ Int)
    probeAt (x, y) = Probe 0 x y
    ok pixel = isJust (determinate (probeAt pixel))
    differs a b = case (determinate (probeAt a), determinate (probeAt b)) of
      (Just (Expected one' _), Just (Expected other _)) → one' /= other
      _ → False
    covered = sortOn centreDistance [p | p ← pixels, ExpectedHit {} ← [expectedAtPixel p]]
    -- Sorted on what is cheap, and only then asked of the oracle, lazily: the
    -- oracle's work for a pixel grows with the faces of its pass.
    clear = filter ok (sortOn centreDistance [p | p ← pixels, expectedAtPixel p == ExpectedClear])
    pair need behaviour candidates contrasts =
      listToMaybe
        [ (need, NamedProbe behaviour (probeAt a) (probeAt b))
        | a ← take 5 (filter ok candidates)
        , b ← take 5 (filter ok contrasts)
        , differs a b
        ]
    one = \case
      Foreground → maybe [] pure (pair Foreground "a face's art covers the pixels its coverage holds and nothing beside them" covered (clear <> reverse covered))
      Overlap →
        let overlapped = [p | p ← covered, ExpectedHit {expectedAll = _ : _ : _} ← [expectedAtPixel p]]
            single = [p | p ← covered, ExpectedHit {expectedAll = [_]} ← [expectedAtPixel p]]
         in maybe [] pure (pair Overlap "the nearer face hides the farther where their projections overlap" overlapped single)
      Reveal →
        let revealed = [p | p ← covered, ExpectedHit {expectedFront = f, expectedShown = Just (h', _)} ← [expectedAtPixel p], hitCell f /= hitCell h' || hitKind f /= hitKind h']
            shown = [p | p ← covered, ExpectedHit {expectedFront = f, expectedShown = Just (h', _)} ← [expectedAtPixel p], hitCell f == hitCell h', hitKind f == hitKind h']
         in maybe [] pure (pair Reveal "a transparent part of a nearer face shows what lies behind it, not the face" revealed shown)
      Clipped → case alternative Clipped of
        -- A pixel outside the viewport that the scene would cover if the viewport were
        -- the whole target: clear here only because the viewport clips it.
        Just unclipped →
          let clippedAway = [p | p ← pixels, expectedAtPixel p == ExpectedClear, ExpectedHit {} ← [unclipped p]]
           in maybe [] pure (pair Clipped "a viewport away from the corner clips the scene and leaves the rest of the target clear" covered clippedAway)
        Nothing → []
      SnapSensitive → case alternative SnapSensitive of
        -- Pixels that snapping changes: covered with it and clear without it, and the reverse.
        Just unsnapped →
          let movedIn = [p | p ← pixels, ExpectedHit {} ← [expectedAtPixel p], unsnapped p == ExpectedClear]
              movedOut = [p | p ← pixels, expectedAtPixel p == ExpectedClear, ExpectedHit {} ← [unsnapped p]]
           in maybe [] pure (pair SnapSensitive "pixel snapping moves the image: a pixel covered only when snapping, against one covered only when not" movedIn movedOut)
        Nothing → []
      Cap →
        let capCentres =
              [ pixel
              | face ← sortOn (negate . area) [f | f ← planFaces plan, faceRole f == RoleCap]
              , Just pixel ← [centreOf face]
              , ExpectedHit {expectedFront = front} ← [expectedAtPixel pixel]
              , hitCell front == cellOf' face
              ]
         in maybe [] pure (pair Cap "a cutaway cap shows its cell's top at the cut" capCentres clear)
    area face = let (x0, x1, y0, y1) = (minimum xs, maximum xs, minimum ys, maximum ys) in (x1 - x0) * (y1 - y0)
      where
        xs = map fst (facePolygon face)
        ys = map snd (facePolygon face)
    centreOf face = do
      let points = facePolygon face
          n = fromIntegral (length points) ∷ Rational
          cx = sum (map fst points) / n
          cy = sum (map snd points) / n
      V2 tx ty ← worldToTarget (rvMapping (planView plan)) (V2 (fromRational cx) (fromRational cy))
      pure (floor tx, floor ty)
    cellOf' face = (cellX' face, cellY' face, toInteger (axisValue (tileZ (faceCell face))))

-- | The pure judge of the planner's coverage, the material's model and the pure
-- pick against the hand-stated expectation, on a stride of the scene's pixels;
-- a control that breaks the pick answers through the backmost face. The answer
-- for a scene is kept, because its variants share it.
pureJudge ∷ Ctx → Spec → Scene → IO Judged
pureJudge ctx s sc = do
  known ← readIORef (ctxJudged ctx)
  case Map.lookup key known of
    Just answer → pure answer
    Nothing → do
      let answer = judge env config (stride 600 (sceneTarget sc)) sc
      length (judgedMismatches answer) `seq` modifyIORef' (ctxJudged ctx) (Map.insert key answer)
      pure answer
  where
    key = sceneName sc <> show (specVariant s == BackmostPick)
    env = envWith (Map.toList (ctxSheets ctx))
    config = case specVariant s of
      BackmostPick → backmost
      _ → normal

judgedMismatchCount ∷ Judged → Int
judgedMismatchCount = length . judgedMismatches

-- ---------------------------------------------------------------------------
-- The record

-- | The fixture record, one JSON document beside the probe record: the build and
-- device, the shader identity, the art's hashes, and for every fixture its scene,
-- plan identity, draw path, counts, tolerance and outcome.
writeRecord ∷ Ctx → [(String, DecodedImage, ByteString.ByteString)] → ImageFormat → Double → [(FixtureResult, Extra)] → IO ()
writeRecord ctx sheets format seconds results = do
  revision ← lookupEnv "HETOIMASIA_VULKAN_REVISION"
  digest ← lookupEnv "HETOIMASIA_VULKAN_SOURCE_DIGEST"
  let shaderHash definition = case definition of
        Just checked → JString (sha256Hex (checkedSpirv (checkedFragment checked)))
        Nothing → JNull
      document =
        JObject
          [ ("record", JString "tra8-terrain fixture record")
          , ("source_revision", maybe JNull JString revision)
          , ("source_digest", maybe JNull JString digest)
          , ("backend_device", JString (Text.unpack (ctxDevice ctx)))
          , ("depth_format", JString (show format))
          , ("target_format", JString (show Rgba8Srgb))
          , ("scenario_seconds", JNumber (show seconds))
          , ("reproduce", JString "HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --private-roots tra8-terrain")
          , ( "shaders"
            , JObject
                [ ("terrain_material_cutout_fragment_sha256", shaderHash (definedCutout terrainMaterial))
                , ("terrain_material_translucent_fragment_sha256", JString (sha256Hex (checkedSpirv (checkedFragment (definedTranslucent terrainMaterial)))))
                , ("equivalent_material_cutout_fragment_sha256", shaderHash (definedCutout terrainMaterialEquivalent))
                , ("note", JString "SPIR-V of the checked variants; the glslang that compiled them is the one tools/vulkan/run.sh reports")
                ]
            )
          , ( "art"
            , JArray
                [ JObject
                    [ ("name", JString name)
                    , ("sha256", if ByteString.null bytes then JNull else JString (sha256Hex bytes))
                    , ("width", JNumber (show (decodedWidth decoded)))
                    , ("height", JNumber (show (decodedHeight decoded)))
                    , ("binary_alpha", JBool (decodedBinaryAlpha decoded))
                    , ("kind", JString (if ByteString.null bytes then "technical diagnostic sheet, not artwork" else "approved artwork, byte for byte from Synarchy 3777d437ea00e1302bf55162ad5693fee4879187"))
                    ]
                | (name, decoded, bytes) ← sheets
                ]
            )
          , ("fixtures", JArray (map fixtureJson results))
          ]
  writeFile (ctxDirectory ctx </> "tra8-terrain-fixtures.json") (renderJson document <> "\n")
  where
    fixtureJson (result, extra) =
      let sp = extraSpec extra
          sc = case specScenes sp of
            first : _ → first
            [] → error "a fixture without a scene"
          probes = resultProbes result
          determinate = length [() | p ← probes, OrderedPath.isDeterminate p]
          (zoomValue, (panX, panY)) = (sceneZoom sc, scenePan sc)
       in JObject
            [ ("name", JString (specName sp))
            , ("passed", JBool (OrderedPath.fixturePassed result))
            , ("failure", maybe JNull (JString . Text.unpack) (resultFailure result))
            , ("snap_discriminating_pixels", maybe JNull (JNumber . show) (extraSnapDifferences extra))
            , ("seconds", JNumber (show (sum (extraSeconds extra))))
            , ("seconds_by_stage", JObject (zip ["render_and_readback", "oracle_verdicts", "independent_expectation", "pure_coverage_model_pick"] (map (JNumber . show) (extraSeconds extra))))
            , ("variant", JString (show (specVariant sp)))
            , ("look", JString (show (specLook sp)))
            , ("control_expected_rejected", maybe JNull JBool (extraRejected extra))
            , ( "scene"
              , JObject
                  [ ("facing", JString (show (sceneFacing sc)))
                  , ("zoom", JNumber (show zoomValue))
                  , ("pan_tiles", JArray [JNumber (show panX), JNumber (show panY)])
                  , ("mode", JString (show (sceneMode sc)))
                  , ("anchor", JArray [JNumber (show (fst (sceneAnchor sc))), JNumber (show (snd (sceneAnchor sc)))])
                  , ("scenes", JArray [JString (sceneName c) | c ← specScenes sp])
                  , ("targets_framebuffer", JArray [JArray [JNumber (show tw), JNumber (show th)] | (tw, th) ← extraTargets extra])
                  , ("target_logical", JArray [JNumber (show (fst (sceneLogical sc))), JNumber (show (snd (sceneLogical sc)))])
                  , ("content_scale", JNumber (show (sceneScale sc)))
                  , ("viewport", JString (show (sceneViewport sc)))
                  , ("pixel_snap", JBool (sceneSnap sc))
                  , ("cells", JArray [JString (show c) | c ← sceneCells sc])
                  ]
              )
            , ("plans", JArray [JObject [("faces", JNumber (show faces)), ("completeness", JString completeness), ("identity", JString identity)] | (faces, completeness, identity) ← zip3 (extraPlanFaces extra) (extraCompleteness extra) (extraIdentity extra)])
            , ("draw_path", JArray [JObject [("path", JString path), ("instances", JNumber (show n)), ("material", JString ref)] | (path, n, ref) ← extraRuns extra])
            , ("cutout_marks", JArray [JObject [("sheet", JString name), ("binary_alpha_mark", maybe JNull JBool mark)] | (name, mark) ← extraMarks extra])
            , ("tolerance_per_channel", JNumber (show (lookTolerance (specLook sp))))
            , ( "oracle"
              , JObject
                  [ ("probes", JNumber (show (length probes)))
                  , ("determinate", JNumber (show determinate))
                  , ("indeterminate", JNumber (show (length probes - determinate)))
                  , ("named", JArray [JString (Text.unpack (OrderedPath.namedName n)) | n ← resultNamed result])
                  ]
              )
            , ( "independent"
              , case extraIndependent extra of
                  Nothing → JNull
                  Just i →
                    JObject
                      [ ("compared", JNumber (show (indCompared i)))
                      , ("ambiguous", JNumber (show (indAmbiguous i)))
                      , ("covered", JNumber (show (indCovered i)))
                      , ("transparent_reveals", JNumber (show (indReveals i)))
                      , ("mismatches", JNumber (show (indMismatchCount i)))
                      , ("first_mismatches", JArray (map JString (indMismatches i)))
                      ]
              )
            , ( "pure_coverage_model_pick"
              , case extraPick extra of
                  Nothing → JNull
                  Just j →
                    JObject
                      [ ("compared", JNumber (show (judgedCompared j)))
                      , ("skipped", JNumber (show (judgedSkipped j)))
                      , ("mismatches", JNumber (show (judgedMismatchCount j)))
                      , ("first_mismatches", JArray (map JString (take 6 (judgedMismatches j))))
                      ]
              )
            ]
