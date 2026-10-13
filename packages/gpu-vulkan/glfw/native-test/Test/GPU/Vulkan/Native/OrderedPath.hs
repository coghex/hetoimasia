-- | The 2D renderer's window-free evidence (R2D-7, R2D-9): a suite's fixtures
-- ("Test.GPU.Vulkan.Native.OrderedPath.Fixtures" is the ordered path's)
-- rendered into offscreen colour targets of a surface-free session through
-- @hetoimasia-render-2d-vulkan@, each read back only once its batch's
-- completion is proved, and every pixel of every target judged against
-- @hetoimasia-render-2d-oracle@.
--
-- The recorder and the oracle are planned with the marks the fixture names
-- ('fixtureMarked'), and the oracle is given the metrics, the format and the
-- extent each target was made with, and the decoded texels each registered
-- handle names; a handle it does not know samples the placeholder. A target a
-- fixture gives a depth image has one in the format the device chooses for
-- depth; where that is not @D32_SFLOAT@, a suite that needs depth reports the
-- format and checks the recorder's refusal on it instead of rendering.
--
-- A run passes only when, for every fixture:
--
-- * every probe the oracle gives a determinate expectation read back within
--   its tolerance — every pixel of every target is probed, and a probe that is
--   indeterminate is listed with its reason and counted for nothing;
-- * at least one probe was determinate;
-- * every named probe, which stands for one rendering behaviour, was
--   determinate and read back, and its expectation differs from its contrast's:
--   the same question asked where the behaviour is absent.
--
-- Each target is written as a lossless PNG and every fixture's probes, formats,
-- metrics, tolerances and indeterminate reasons as one JSON record, into the
-- directory the caller names.
module Test.GPU.Vulkan.Native.OrderedPath
  ( Host (..)
  , Suite (..)
  , orderedSuite
  , Evidence (..)
  , FixtureResult (..)
  , ProbeResult (..)
  , NamedResult (..)
  , TargetResult (..)
  , fixturePassed
  , isDeterminate
  , verdictPasses
  , runEvidence
  , renderRecord
  ) where

import Control.Concurrent (threadDelay)
import Control.Monad (foldM)
import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import Data.List (intercalate)
import Data.Maybe (isJust)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Numeric (showHex)
import Numeric.Natural (Natural)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

import Hetoimasia.GPU.Vulkan.GLFW
  ( BatchTicket
  , Construction
  , Image
  , ImageDescription (..)
  , ImageFormat (..)
  , ImageKind (..)
  , Readback
  , Refusal (..)
  , ResourceUse (..)
  , TableView (..)
  , TextureHandle (..)
  , TransitionSource (..)
  , UploadRequest (..)
  , constructBlendedCheckedPipeline
  , constructDepthCheckedPipeline
  , constructDepthFormat
  , constructImage
  , constructImageFormat
  , constructReadback
  , constructRingWith
  , constructShaderSampledTablePipelineLayout
  , constructStorageTable
  , constructTablePipelineLayoutWith
  , TableLayoutOptions (..)
  , TableUse (..)
  , constructTextureTable
  , copyTargetToReadback
  , formatCode
  , registerConstructedTexture
  , releaseConstructedTexture
  , swapConstructedTexture
  , transitionResource
  , validateRingSize
  , validateStorageWindow
  , validateTableConfig
  )
import Hetoimasia.GPU.Vulkan.Native.Recording (Recorder)
import Hetoimasia.Asset.Image (DecodedImage)
import qualified Hetoimasia.Render.Api.Texture as Api
import Hetoimasia.Render.Api.Texture.Backend (textureHandle)
import Hetoimasia.Render.TwoD.DrawPlan (cutoutMarks)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import Hetoimasia.Render.TwoD.Oracle
  ( Expectation (..)
  , OracleInput (..)
  , Probe (..)
  , TargetSpec (..)
  , Verdict (..)
  , expect
  , judgeReadback
  , newOracle
  , passes
  )
import Hetoimasia.Render.TwoD.Oracle.Colour (Rgba8 (..), Tolerance (..))
import Hetoimasia.Render.TwoD.Oracle.Readback (readPixel)
import Hetoimasia.Render.TwoD.Validation (validateSnapshot)
import qualified Hetoimasia.Render.TwoD.Vulkan as Render
import Test.GPU.Vulkan.Native.OrderedPath.Fixtures
import Test.GPU.Vulkan.Native.Png (encodeRgba)

-- | What the evidence needs of a session.
data Host = Host
  { hostAct ∷ ∀ a. Text → (∀ q inst msgr phys dev cmd. Construction q inst msgr phys dev cmd → IO (Either Refusal a)) → IO (Either Text a)
    -- ^ Run an owner-thread action over the session's constructions, naming it
    -- for a failure's report.
  , hostRecord ∷ Text → (∀ q inst msgr phys dev cmd. Construction q inst msgr phys dev cmd → IO (Either Refusal (Recorder q inst msgr phys dev cmd → IO (Either Refusal ())))) → IO (Either Text BatchTicket)
    -- ^ Run an owner-thread action that prepares a frame-less batch's
    -- recording through the constructions, then records that batch, which is
    -- submitted when the action returns; answer its ticket.
  , hostUpload ∷ UploadRequest → IO (Either Text ())
    -- ^ Admit an upload off the owner's thread and wait, with a deadline, for
    -- it to complete.
  , hostAwait ∷ BatchTicket → IO (Either Text ())
    -- ^ Wait, with a deadline, for a batch to complete.
  , hostReadTable ∷ IO (Either Text (Maybe TableView))
    -- ^ The texture table as it stands, read on the owner's thread.
  , hostRead ∷ Readback → Natural → IO (Either Text ByteString)
    -- ^ The first bytes of a readback, once its batch has completed.
  }

-- | One probe of a target: what the oracle expected, what the readback held,
-- and the verdict.
data ProbeResult = ProbeResult
  { probeAt ∷ !Probe
  , probeExpectation ∷ !Expectation
  , probeObserved ∷ !(Maybe Rgba8)
  , probeVerdict ∷ !Verdict
  }

-- | A named probe and its contrast, judged.
data NamedResult = NamedResult
  { namedName ∷ !Text
  , namedProbeAt ∷ !Probe
  , namedContrastAt ∷ !Probe
  , namedExpected ∷ !Expectation
  , namedContrastExpected ∷ !Expectation
  , namedObserved ∷ !(Maybe Rgba8)
  , namedVerdict ∷ !Verdict
  , namedDistinguishes ∷ !Bool
    -- ^ Both expectations are determinate and they differ.
  }

-- | A target of a fixture: its shape, its PNG and the bytes read back.
data TargetResult = TargetResult
  { targetIndex ∷ !Int
  , targetShape ∷ !TargetShape
  , targetPng ∷ !(Maybe FilePath)
  , targetBytesRead ∷ !Int
  , targetDepthFormat ∷ !(Maybe ImageFormat)
    -- ^ The format of the depth image the pass drew with, if the shape has one.
  }

-- | A set of fixtures run together: the textures they use, their fixtures, the
-- name that prefixes their files, and whether they need a depth image.
data Suite = Suite
  { suiteName ∷ !String
  , suiteRecord ∷ !FilePath
  , suiteTextures ∷ ![Texture]
  , suiteFixtures ∷ ![Fixture]
  , suiteNeedsDepth ∷ !Bool
  }

-- | The ordered path's: eleven fixtures, one of them (a depth-enabled layer of
-- art drawn ordered) over a depth image.
orderedSuite ∷ Suite
orderedSuite = Suite "ordered-path" "ordered-path-probes.json" textures fixtures True

-- | One fixture's findings.
data FixtureResult = FixtureResult
  { resultFixture ∷ !Text
  , resultTargets ∷ ![TargetResult]
  , resultProbes ∷ ![ProbeResult]
  , resultNamed ∷ ![NamedResult]
  , resultFailure ∷ !(Maybe Text)
  }

-- | Whether a fixture met every condition of the run.
fixturePassed ∷ FixtureResult → Bool
fixturePassed result =
  resultFailure result == Nothing
    && not (null determinate)
    && all (passes . probeVerdict) determinate
    && not (any (failedVerdict . probeVerdict) (resultProbes result))
    && not (null (resultNamed result))
    && all (\named → namedDistinguishes named && passes (namedVerdict named)) (resultNamed result)
  where
    determinate = [probed | probed ← resultProbes result, isExpected (probeExpectation probed)]

failedVerdict ∷ Verdict → Bool
failedVerdict = \case
  OutOfTolerance _ → True
  ProbeUnevaluable _ → True
  ReadbackFaulty _ → True
  _ → False

-- | Whether the oracle gave this probe an expectation to read.
isDeterminate ∷ ProbeResult → Bool
isDeterminate = isExpected . probeExpectation

-- | Whether a verdict is a pass.
verdictPasses ∷ Verdict → Bool
verdictPasses = passes

isExpected ∷ Expectation → Bool
isExpected = \case
  Expected _ _ → True
  _ → False

-- | What one evidence run found.
data Evidence = Evidence
  { evidencePassed ∷ !Bool
  , evidenceFailure ∷ !(Maybe Text)
    -- ^ Why the run stopped before judging a fixture, if it did.
  , evidenceFixtures ∷ ![FixtureResult]
  , evidenceRecord ∷ !FilePath
  , evidenceDepthFormat ∷ !(Maybe ImageFormat)
    -- ^ The depth format the device chose, for a suite that needs depth.
  , evidenceUnavailable ∷ !(Maybe Text)
    -- ^ Why a suite that needs @D32_SFLOAT@ rendered nothing, when the device
    -- chose another depth format, and what its refusal check found.
  }

-- | What an evidence run came to before it was written.
data Outcome
  = Rendered ![FixtureResult]
  | -- | The device's depth format is not @D32_SFLOAT@: the format, and the
    -- refusal the recorder gave a depth-enabled snapshot over a depth image of it.
    Unavailable !ImageFormat !(Either Text Text)

-- | Run the evidence over a host, writing the PNGs and the probe record into
-- this directory, which is made if missing and never deleted.
runEvidence ∷ Host → Suite → FilePath → IO Evidence
runEvidence host suite directory = do
  createDirectoryIfMissing True directory
  depth ← if suiteNeedsDepth suite then hostAct host "choosing the depth format" (\construction → constructDepthFormat construction) else pure (Right Depth32Float)
  outcome ← case depth of
    Left why → pure (Left why)
    Right format
      | suiteNeedsDepth suite && format /= Depth32Float → Right . Unavailable format <$> refusalCheck host suite format
      | otherwise → fmap Rendered <$> evidenceOver host suite directory format
  let recordPath = directory </> suiteRecord suite
      depthFormat = either (const Nothing) (\format → if suiteNeedsDepth suite then Just format else Nothing) depth
      (failure, results, unavailable) = case outcome of
        Left why → (Just why, [], Nothing)
        Right (Rendered found) → (Nothing, found, Nothing)
        Right (Unavailable format (Left why)) → (Just why, [], Just ("D32_SFLOAT is not available: the device chose " <> tshow format))
        Right (Unavailable format (Right checked)) → (Nothing, [], Just ("D32_SFLOAT is not available: the device chose " <> tshow format <> "; " <> checked))
  ByteString.writeFile recordPath (Text.encodeUtf8 (renderRecord suite depthFormat unavailable failure results))
  pure
    Evidence
      { evidencePassed = failure == Nothing && (isJust unavailable || (length results == length (suiteFixtures suite) && all fixturePassed results))
      , evidenceFailure = failure
      , evidenceFixtures = results
      , evidenceRecord = recordPath
      , evidenceDepthFormat = depthFormat
      , evidenceUnavailable = unavailable
      }

-- | A table of 16 slots, 8 at first and four versions; a ring of a mebibyte.
configuration ∷ Render.Configuration
configuration =
  Render.Configuration
    { Render.configurationRing = either (error . show) id (validateRingSize (1024 * 1024))
    , Render.configurationClipWindow = either (error . show) id (validateStorageWindow (16 * 1024))
    , Render.configurationTable = either (error . show) id (validateTableConfig 16 8 4)
    }

builders ∷ Construction q inst msgr phys dev cmd → Render.Builders q inst msgr phys dev cmd
builders construction =
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
    }

-- | What the recorder gives a depth-enabled snapshot over a depth image of a
-- format that is not @D32_SFLOAT@: its refusal, naming the layer. The check is
-- the pure work of the frame, so no renderer, texture or batch is needed.
refusalCheck ∷ Host → Suite → ImageFormat → IO (Either Text Text)
refusalCheck host suite format =
  case [fixture' | fixture' ← suiteFixtures suite, any shapeDepth (fixtureShapes fixture')] of
    [] → pure (Left "the suite has no fixture with a depth image")
    fixture' : _ → do
      handles ← pure (Handles (const (textureHandle 1 1)) (textureHandle 1000 1) (textureHandle 1000 2))
      case validateSnapshot (fixtureSnapshot fixture' handles) of
        Left refused → pure (Left ("the snapshot was refused: " <> tshow refused))
        Right valid → do
          made ← hostAct host "making a depth image of the device's format" $ \construction → do
            colours ← traverse (\shape → constructImage construction (ImageDescription ColorTarget (shapeFormat shape) (shapeWidth shape) (shapeHeight shape) 1)) (fixtureShapes fixture')
            depths ← traverse (\shape → constructImage construction (ImageDescription DepthTarget format (shapeWidth shape) (shapeHeight shape) 1)) (fixtureShapes fixture')
            pure ((,) <$> sequence colours <*> sequence depths)
          case made of
            Left failure → pure (Left failure)
            Right (colours, depths) → do
              let shapes = fixtureShapes fixture'
                  input =
                    Render.FrameInput
                      { Render.frameSnapshot = valid
                      , Render.frameMarks = cutoutMarks []
                      , Render.frameTarget = \reference →
                          lookup
                            reference
                            [ ( shapeRef shape
                              , Render.TargetBinding
                                  colour
                                  (Render.Attachment (formatCode (shapeFormat shape)) (shapeWidth shape) (shapeHeight shape) (shapeMetrics shape))
                                  (if shapeDepth shape then Just (Render.DepthBinding depth format) else Nothing)
                              )
                            | (shape, colour, depth) ← zip3 shapes colours depths
                            ]
                      , Render.frameWindow = Nothing
                      , Render.frameWindowDepth = Nothing
                      }
              pure $ case Render.frameWork input of
                Left refusal@(Render.DepthFormatRefused _ refused) | refused == format → Right ("the recorder refused a depth-enabled layer over it before recording: " <> tshow refusal)
                Left other → Left ("the recorder's refusal was not the depth format's: " <> tshow other)
                Right _ → Left "the recorder accepted a depth-enabled layer over a depth image that is not D32_SFLOAT"

evidenceOver ∷ Host → Suite → FilePath → ImageFormat → IO (Either Text [FixtureResult])
evidenceOver host suite directory depthFormat = do
  made ← hostAct host "making the renderer and the textures" $ \construction → do
    renderer ← Render.makeRenderer (builders construction) configuration
    images ← traverse (\texture → constructImage construction (ImageDescription TextureImage (textureFormat texture) (textureWidth texture) (textureHeight texture) (fromIntegral (length (textureLevels texture))))) (suiteTextures suite)
    pure ((,) <$> renderer <*> sequence images)
  case made of
    Left failure → pure (Left failure)
    Right (renderer, images) → do
      uploads ← traverse (\(texture, image) → hostUpload host (UploadImage image (textureLevels texture))) (zip (suiteTextures suite) images)
      case sequence uploads of
        Left failure → pure (Left ("an upload did not complete: " <> failure))
        Right _ →
          awaitPlaceholder host (200 ∷ Int) >>= \case
            Left failure → pure (Left failure)
            Right () →
              hostAct host "registering the textures" (\construction → fmap sequence (traverse (registerConstructedTexture construction) images)) >>= \case
                Left failure → pure (Left failure)
                Right registered → do
                  let byKey = Map.fromList [(textureKey texture, textureHandle (handleIndex backend) (handleGeneration backend)) | (texture, backend) ← zip (suiteTextures suite) registered]
                      decodedByHandle = Map.fromList [(byKey Map.! textureKey texture, decoded texture) | texture ← suiteTextures suite]
                      handles =
                        Handles
                          { handleOf = (byKey Map.!)
                          , handleUnknown = textureHandle 1000 1
                          , handleStale = case registered of
                              backend : _ → textureHandle (handleIndex backend) (handleGeneration backend + 1)
                              [] → textureHandle 1000 2
                          }
                  Right . reverse <$> foldM (\done fixture' → (: done) <$> runFixture host suite directory depthFormat renderer handles decodedByHandle fixture') [] (suiteFixtures suite)

-- | The table binds once its placeholder's upload has completed and its
-- descriptor is written, which the owner's steps do.
awaitPlaceholder ∷ Host → Int → IO (Either Text ())
awaitPlaceholder host remaining =
  hostReadTable host >>= \case
    Left failure → pure (Left failure)
    Right (Just table) | tableViewPlaceholderWritten table → pure (Right ())
    Right _
      | remaining <= 0 → pure (Left "the texture table's placeholder was not written within ten seconds")
      | otherwise → threadDelay 50000 >> awaitPlaceholder host (remaining - 1)

-- | Render one fixture, read its targets back and judge every pixel.
runFixture
  ∷ Host
  → Suite
  → FilePath
  → ImageFormat
  → Render.Renderer
  → Handles
  → Map.Map Api.TextureHandle DecodedImage
  → Fixture
  → IO FixtureResult
runFixture host suite directory depthFormat renderer handles decodedByHandle fixture =
  case validateSnapshot (fixtureSnapshot fixture handles) of
    Left refused → pure (failed ("the snapshot was refused: " <> tshow refused))
    Right valid → do
      made ← hostAct host ("making " <> name <> "'s targets") $ \construction →
        fmap sequence . traverse (target construction) $ shapes
      case made of
        Left failure → pure (failed failure)
        Right pairs → do
          let input =
                Render.FrameInput
                  { Render.frameSnapshot = valid
                  , Render.frameMarks = marks
                  , Render.frameTarget = \reference →
                      lookup
                        reference
                        [ ( shapeRef shape
                          , Render.TargetBinding
                              image
                              (Render.Attachment (formatCode (shapeFormat shape)) (shapeWidth shape) (shapeHeight shape) (shapeMetrics shape))
                              (fmap (\held → Render.DepthBinding held depthFormat) depth)
                          )
                        | (shape, (image, _, depth)) ← zip shapes pairs
                        ]
                  , Render.frameWindow = Nothing
                  , Render.frameWindowDepth = Nothing
                  }
          ticket ← hostRecord host ("recording " <> name) $ \construction →
            Render.prepareSnapshot (builders construction) renderer input >>= \case
              Left refusal → pure (Left (RefusedIllegal (tshow refusal)))
              Right recording →
                pure . Right $ \recorder →
                  recording recorder >>= \case
                    Left refusal → pure (Left (RefusedIllegal (tshow refusal)))
                    Right () → inOrder (concatMap (copyOut recorder) [(image, readback) | (image, readback, _) ← pairs])
          case ticket of
            Left failure → pure (failed failure)
            Right batch →
              hostAwait host batch >>= \case
                Left failure → pure (failed ("the batch did not complete: " <> failure))
                Right () →
                  fmap sequence (traverse (\(shape, (_, readback, _)) → hostRead host readback (targetBytes shape)) (zip shapes pairs)) >>= \case
                    Left failure → pure (failed ("a readback was not read: " <> failure))
                    Right readbacks → judged valid readbacks
  where
    name = fixtureName fixture
    shapes = fixtureShapes fixture
    marks = cutoutMarks [handleOf handles key | key ← fixtureMarked fixture]
    failed failure = FixtureResult name [] [] [] (Just failure)
    targetBytes shape = fromIntegral (shapeWidth shape) * fromIntegral (shapeHeight shape) * 4 ∷ Natural
    target ∷ Construction q inst msgr phys dev cmd → TargetShape → IO (Either Refusal (Image, Readback, Maybe Image))
    target construction shape = do
      image ← constructImage construction (ImageDescription ColorTarget (shapeFormat shape) (shapeWidth shape) (shapeHeight shape) 1)
      readback ← constructReadback construction (targetBytes shape)
      depth ←
        if shapeDepth shape
          then fmap Just <$> constructImage construction (ImageDescription DepthTarget depthFormat (shapeWidth shape) (shapeHeight shape) 1)
          else pure (Right Nothing)
      pure ((,,) <$> image <*> readback <*> depth)
    -- The target leaves its colour-attachment use for a copy and returns to it.
    copyOut recorder (image, readback) =
      [ transitionResource recorder image (FromUse ColorAttachment) TransferRead
      , copyTargetToReadback recorder image readback
      , transitionResource recorder image (FromUse TransferRead) ColorAttachment
      ]
    judged valid readbacks = do
      let oracle =
            newOracle
              OracleInput
                { inputSnapshot = valid
                , inputCutoutMarks = marks
                , inputWindow = Nothing
                , inputOffscreen =
                    Map.fromList
                      [ (shapeRef shape, TargetSpec (shapeMetrics shape) (colourFormatOf (shapeFormat shape)) (PixelExtent (fromIntegral (shapeWidth shape)) (fromIntegral (shapeHeight shape))))
                      | shape ← shapes
                      ]
                , inputTextures = (`Map.lookup` decodedByHandle)
                }
          perPass = zip3 [0 ..] shapes readbacks
          bytesOf index = case drop index readbacks of
            bytes : _ → bytes
            [] → ByteString.empty
          colourOf index = case drop index shapes of
            shape : _ → Just (colourFormatOf (shapeFormat shape), PixelExtent (fromIntegral (shapeWidth shape)) (fromIntegral (shapeHeight shape)))
            [] → Nothing
          observed (Probe index x y) = do
            (format, extent) ← colourOf index
            either (const Nothing) Just (readPixel format extent (bytesOf index) x y)
          judge asked = judgeReadback oracle asked (bytesOf (probePass asked))
          probes =
            [ ProbeResult at (expect oracle at) (observed at) (judge at)
            | (index, shape, _) ← perPass
            , y ← [0 .. fromIntegral (shapeHeight shape) - 1]
            , x ← [0 .. fromIntegral (shapeWidth shape) - 1]
            , let at = Probe index x y
            ]
          named =
            [ NamedResult
                { namedName = namedBehaviour candidate
                , namedProbeAt = namedProbe candidate
                , namedContrastAt = namedContrast candidate
                , namedExpected = firstExpectation
                , namedContrastExpected = contrastExpectation
                , namedObserved = observed (namedProbe candidate)
                , namedVerdict = judge (namedProbe candidate)
                , namedDistinguishes = case (firstExpectation, contrastExpectation) of
                    (Expected one _, Expected other _) → one /= other
                    _ → False
                }
            | candidate ← fixtureNamed fixture
            , let firstExpectation = expect oracle (namedProbe candidate)
                  contrastExpectation = expect oracle (namedContrast candidate)
            ]
      pngs ←
        traverse
          ( \(index, shape, bytes) → do
              let path = directory </> (suiteName suite <> "-" <> Text.unpack name <> "-" <> show index <> ".png")
              ByteString.writeFile path (encodeRgba (fromIntegral (shapeWidth shape)) (fromIntegral (shapeHeight shape)) bytes)
              pure (TargetResult index shape (Just path) (ByteString.length bytes) (if shapeDepth shape then Just depthFormat else Nothing))
          )
          perPass
      pure (FixtureResult name pngs probes named Nothing)

-- | Run each command in order, stopping at the first refusal.
inOrder ∷ [IO (Either Refusal ())] → IO (Either Refusal ())
inOrder = \case
  [] → pure (Right ())
  step : rest → step >>= either (pure . Left) (const (inOrder rest))

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show

-- ---------------------------------------------------------------------------
-- The probe record

-- | The probe record: a JSON document of every fixture's targets with their
-- formats, metrics and PNGs, its named probes with the behaviour each stands
-- for, their expectations, tolerances, observed values, contrasts and
-- verdicts, the counts of what passed, failed and was indeterminate, and every
-- indeterminate probe with its reason.
renderRecord ∷ Suite → Maybe ImageFormat → Maybe Text → Maybe Text → [FixtureResult] → Text
renderRecord suite depthFormat unavailable failure results =
  Text.pack . (<> "\n") $
    object
      [ ("suite", str (suiteName suite))
      , ("depth_format", maybe "null" (str . show) depthFormat)
      , ("unavailable", maybe "null" (str . Text.unpack) unavailable)
      , ("failure", maybe "null" (str . Text.unpack) failure)
      , ("fixtures", list (map fixtureRecord results))
      , ("passed", bool (failure == Nothing && (isJust unavailable || (length results == length (suiteFixtures suite) && all fixturePassed results))))
      ]
  where
    fixtureRecord result =
      object
        [ ("name", str (Text.unpack (resultFixture result)))
        , ("failure", maybe "null" (str . Text.unpack) (resultFailure result))
        , ("targets", list (map targetRecord (resultTargets result)))
        , ("counts", counts result)
        , ("named", list (map namedRecord (resultNamed result)))
        , ("indeterminate", list [indeterminateRecord probed | probed ← resultProbes result, isIndeterminate probed])
        , ("failed", list [failedRecord probed | probed ← resultProbes result, failedVerdict (probeVerdict probed)])
        , ("passed", bool (fixturePassed result))
        ]
    targetRecord (TargetResult index shape png bytes' targetDepth) =
      let metrics = shapeMetrics shape
          PixelExtent logicalWidth logicalHeight = metricsLogical metrics
          PixelExtent framebufferWidth framebufferHeight = metricsFramebuffer metrics
       in object
            [ ("pass", show index)
            , ("format", str (show (shapeFormat shape)))
            , ("oracle_format", str (show (colourFormatOf (shapeFormat shape))))
            , ("width", show (shapeWidth shape))
            , ("height", show (shapeHeight shape))
            , ("logical_extent", list [show logicalWidth, show logicalHeight])
            , ("framebuffer_extent", list [show framebufferWidth, show framebufferHeight])
            , ("content_scale", list [show (metricsScaleX metrics), show (metricsScaleY metrics)])
            , ("png", maybe "null" str png)
            , ("readback_bytes", show bytes')
            , ("depth_format", maybe "null" (str . show) targetDepth)
            ]
    counts result =
      let probes = resultProbes result
          expected = [probed | probed ← probes, isExpected (probeExpectation probed)]
       in object
            [ ("probes", show (length probes))
            , ("determinate", show (length expected))
            , ("determinate_passed", show (length (filter (passes . probeVerdict) expected)))
            , ("indeterminate", show (length (filter isIndeterminate probes)))
            , ("failed", show (length (filter (failedVerdict . probeVerdict) probes)))
            ]
    namedRecord named =
      object
        [ ("behaviour", str (Text.unpack (namedName named)))
        , ("probe", probeRecord (namedProbeAt named))
        , ("contrast", probeRecord (namedContrastAt named))
        , ("expected", expectationRecord (namedExpected named))
        , ("contrast_expected", expectationRecord (namedContrastExpected named))
        , ("observed", maybe "null" rgba (namedObserved named))
        , ("verdict", str (show (namedVerdict named)))
        , ("distinguishes", bool (namedDistinguishes named))
        ]
    indeterminateRecord probed =
      object
        [ ("probe", probeRecord (probeAt probed))
        , ("reason", str (show (probeExpectation probed)))
        ]
    failedRecord probed =
      object
        [ ("probe", probeRecord (probeAt probed))
        , ("expected", expectationRecord (probeExpectation probed))
        , ("observed", maybe "null" rgba (probeObserved probed))
        , ("verdict", str (show (probeVerdict probed)))
        ]
    probeRecord (Probe pass' x y) = object [("pass", show pass'), ("x", show x), ("y", show y)]
    expectationRecord = \case
      Expected value (Tolerance tr tg tb ta) → object [("rgba", rgba value), ("tolerance", list (map show [tr, tg, tb, ta]))]
      other → str (show other)
    rgba (Rgba8 r g b a) = list (map show [r, g, b, a])
    isIndeterminate probed = case probeExpectation probed of
      Indeterminate _ → True
      _ → False
    object ∷ [(String, String)] → String
    object fields = "{" <> intercalate ", " [str key <> ": " <> value | (key, value) ← fields] <> "}"
    list ∷ [String] → String
    list items = "[" <> intercalate ", " items <> "]"
    str ∷ String → String
    str value = "\"" <> concatMap escape value <> "\""
    -- JSON's required escapes: the quote, the backslash, and every control
    -- character below U+0020, which a failure's message may carry.
    escape ∷ Char → String
    escape = \case
      '"' → "\\\""
      '\\' → "\\\\"
      '\n' → "\\n"
      '\r' → "\\r"
      '\t' → "\\t"
      c
        | c < ' ' → let digits = showHex (fromEnum c) "" in "\\u" <> replicate (4 - length digits) '0' <> digits
        | otherwise → [c]
    bool ∷ Bool → String
    bool value = if value then "true" else "false"
