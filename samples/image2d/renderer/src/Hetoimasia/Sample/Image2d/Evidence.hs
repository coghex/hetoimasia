-- | The sample's window-free evidence (R2D-8): the scene rendered into an
-- offscreen colour target of a surface-free session through
-- @hetoimasia-render-2d-vulkan@, read back once its batch's completion is
-- proved, judged against @hetoimasia-render-2d-oracle@ and against positions
-- and colours stated by hand, and the swap rule shown on the registered
-- textures.
--
-- = The frame
--
-- A 256×256 RGBA8 sRGB target of logical extent 128×128 at content scale 2,
-- UI scale 1, holds the PNG's world copy, the KTX2 copy beside it and the
-- PNG's UI copy (see "Hetoimasia.Sample.Image2d.Scene"). The snapshot is planned
-- with 'noCutoutMarks', which the recorder is given explicitly (an offscreen
-- pass names its marks, R2D-9) as the oracle is, and the oracle is given the
-- decoded images the registered handles name.
--
-- A run passes only when:
--
-- * every pixel the oracle gives a determinate expectation read back within
--   its tolerance, and at least one did; indeterminate pixels are listed with
--   their reasons and count for nothing;
-- * every named probe of "Hetoimasia.Sample.Image2d.Fixtures" — a position and
--   a colour read off the image tables by hand, so independent of the decoder,
--   the oracle and the readback — read back within one step per channel of its
--   colour, the oracle agreed with that colour, and its contrast was
--   determinate and a different colour;
-- * each of the PNG's world copy, the PNG's UI copy, the KTX2 copy and the
--   clear background has a named probe;
-- * the swap demonstration held: a swap of the quadrants' handle to the
--   fade image, whose alpha is not binary, was refused naming both marks and
--   changed no mark, and the same swap with the registered mark explicitly
--   kept was accepted and left the mark as registered.
--
-- The target is written as a lossless PNG and the probes, the oracle's
-- findings and the swap demonstration as one JSON record into the directory
-- the caller names.
module Hetoimasia.Sample.Image2d.Evidence
  ( Evidence (..)
  , ProbeResult (..)
  , NamedResult (..)
  , SwapDemonstration (..)
  , evidenceTarget
  , runEvidence
  , runEvidenceWith
  , renderRecord
  , pngName
  , recordName
  ) where

import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import Data.List (intercalate)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Word (Word8)
import Numeric (showHex)
import Numeric.Natural (Natural)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

import Hetoimasia.GPU.Vulkan.Native.Recording
  ( ImageDescription (..)
  , ImageFormat (..)
  , ImageKind (..)
  , Refusal (..)
  , ResourceUse (..)
  , TransitionSource (..)
  , copyTargetToReadback
  , formatCode
  , transitionResource
  )
import Hetoimasia.Render.TwoD.DrawPlan (noCutoutMarks)
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
import Hetoimasia.Render.TwoD.Oracle.Colour (ColourFormat (..), Rgba8 (..), Tolerance (..))
import Hetoimasia.Render.TwoD.Oracle.Readback (readPixel)
import Hetoimasia.Render.TwoD.Snapshot (Target (..))
import Hetoimasia.Render.TwoD.Target.Backend (targetRef)
import Hetoimasia.Render.TwoD.Validation (ValidSnapshot, validateSnapshot)
import qualified Hetoimasia.Render.TwoD.Vulkan as Render
import Hetoimasia.Render.TwoD.Vulkan.Textures
  ( SwapPolicy (..)
  , TextureRefusal (..)
  , registeredMark
  , swapTexture
  )
import Hetoimasia.Sample.Image2d
import Hetoimasia.Sample.Image2d.Assets (ImageName (..))
import Hetoimasia.Sample.Image2d.Fixtures (Colour (..), NamedProbe (..), namedProbes)
import Hetoimasia.Sample.Image2d.Png (encodePng)
import Hetoimasia.Sample.Image2d.Scene (evidenceLayout, evidenceMetrics, snapshotFor)

-- | One pixel: what the oracle expected, what the readback held, the verdict.
data ProbeResult = ProbeResult
  { probeAt ∷ !Probe
  , probeExpectation ∷ !Expectation
  , probeObserved ∷ !(Maybe Rgba8)
  , probeVerdict ∷ !Verdict
  }

-- | A named probe and its contrast, judged.
data NamedResult = NamedResult
  { namedProbe ∷ !NamedProbe
  , namedOracle ∷ !Expectation
  , namedContrastOracle ∷ !Expectation
  , namedObserved ∷ !(Maybe Rgba8)
  , namedHeld ∷ !Bool
    -- ^ The readback is within a step per channel of the hand-stated colour.
  , namedAgreed ∷ !Bool
    -- ^ The oracle's expectation is determinate and within its tolerance of
    -- the hand-stated colour.
  , namedDistinguishes ∷ !Bool
    -- ^ The contrast is determinate in the oracle and a different colour.
  }

-- | What the swap demonstration found.
data SwapDemonstration = SwapDemonstration
  { swapRefused ∷ !(Maybe (Bool, Bool))
    -- ^ The two marks a swap to a different mark was refused with: the
    -- registered, then the replacement's.
  , swapMarkAfterRefusal ∷ !(Maybe Bool)
  , swapKeepAccepted ∷ !Bool
  , swapMarkAfterKeep ∷ !(Maybe Bool)
  }
  deriving (Eq, Show)

-- | What one evidence run found.
data Evidence = Evidence
  { evidencePassed ∷ !Bool
  , evidenceFailure ∷ !(Maybe Text)
    -- ^ Why the run stopped before judging the frame, if it did.
  , evidenceProbes ∷ ![ProbeResult]
  , evidenceNamed ∷ ![NamedResult]
  , evidenceSwap ∷ !(Maybe SwapDemonstration)
  , evidenceReadback ∷ !Int
  , evidencePng ∷ !(Maybe FilePath)
  , evidenceRecord ∷ !FilePath
  }

pngName, recordName ∷ FilePath
pngName = "image2d.png"
recordName = "image2d-probes.json"

-- | The evidence target's side.
side ∷ Int
side = 256

targetBytes ∷ Natural
targetBytes = fromIntegral (side * side * 4)

-- | The offscreen target the frame is drawn to.
evidenceTarget ∷ Target
evidenceTarget = OffscreenTarget (targetRef 1 1)

-- | Run the evidence over a host, writing the PNG and the probe record into
-- this directory, which is made if missing and never deleted. The host's
-- textures are prepared first; a host that has prepared them already uses
-- 'runEvidenceWith'.
runEvidence ∷ Host → FilePath → IO Evidence
runEvidence host directory =
  prepare host >>= \case
    Right prepared → runEvidenceWith host prepared directory
    Left failure → do
      createDirectoryIfMissing True directory
      let recordPath = directory </> recordName
      ByteString.writeFile recordPath (Text.encodeUtf8 (renderRecord (Just failure) 0 [] [] Nothing))
      pure (Evidence False (Just failure) [] [] Nothing 0 Nothing recordPath)

-- | Run the evidence over textures a host has prepared. It swaps the
-- quadrants' handle, kept at its registered mark, and registers nothing.
runEvidenceWith ∷ Host → Prepared → FilePath → IO Evidence
runEvidenceWith host prepared directory = do
  createDirectoryIfMissing True directory
  outcome ← evidence host prepared
  let recordPath = directory </> recordName
  case outcome of
    Left failure → do
      ByteString.writeFile recordPath (Text.encodeUtf8 (renderRecord (Just failure) 0 [] [] Nothing))
      pure (Evidence False (Just failure) [] [] Nothing 0 Nothing recordPath)
    Right (bytes, probes, named, swap) → do
      let complete = ByteString.length bytes == fromIntegral targetBytes
          failure = if complete then Nothing else Just ("the readback held " <> tshow (ByteString.length bytes) <> " bytes, not " <> tshow targetBytes)
          pngPath = directory </> pngName
          expectedSwap = SwapDemonstration (Just (True, False)) (Just True) True (Just True)
          passed = complete && probesPassed probes && all namedPassed named && covered named && swap == expectedSwap
      ByteString.writeFile pngPath (encodePng side side bytes)
      ByteString.writeFile recordPath (Text.encodeUtf8 (renderRecord failure (ByteString.length bytes) probes named (Just swap)))
      pure (Evidence passed failure probes named (Just swap) (ByteString.length bytes) (Just pngPath) recordPath)

-- | Every determinate probe passed, none failed, and at least one was
-- determinate.
probesPassed ∷ [ProbeResult] → Bool
probesPassed probes =
  not (null determinate) && all (passes . probeVerdict) determinate && not (any (failedVerdict . probeVerdict) probes)
  where
    determinate = [probed | probed ← probes, isExpected (probeExpectation probed)]

namedPassed ∷ NamedResult → Bool
namedPassed named = namedHeld named && namedAgreed named && namedDistinguishes named

-- | Each kind of coverage has a named probe.
covered ∷ [NamedResult] → Bool
covered named = all (\kind → any ((== kind) . probeCovers . namedProbe) named) [minBound .. maxBound]

failedVerdict ∷ Verdict → Bool
failedVerdict = \case
  OutOfTolerance _ → True
  ProbeUnevaluable _ → True
  ReadbackFaulty _ → True
  _ → False

isExpected ∷ Expectation → Bool
isExpected = \case
  Expected _ _ → True
  _ → False

evidence ∷ Host → Prepared → IO (Either Text (ByteString, [ProbeResult], [NamedResult], SwapDemonstration))
evidence Host {hostAct = actOn, hostRecord = recordOn, hostAwait = awaitBatch, hostRead = readBytes} prepared = do
  let handles = handlesOf prepared
  case validateSnapshot (snapshotFor evidenceTarget handles evidenceLayout) of
    Left refused → pure (Left ("the snapshot was refused: " <> tshow refused))
    Right valid → do
      made ← actOn "making the evidence target" $ \builders → do
        image ← buildImage builders (ImageDescription ColorTarget Rgba8Srgb (fromIntegral side) (fromIntegral side) 1)
        readback ← buildReadback builders targetBytes
        pure ((,) <$> image <*> readback)
      case made of
        Left failure → pure (Left failure)
        Right (target, readback) → do
          let input =
                Render.FrameInput
                  { Render.frameSnapshot = valid
                  , Render.frameMarks = noCutoutMarks
                  , Render.frameTarget = \reference →
                      if evidenceTarget == OffscreenTarget reference
                        then Just (Render.TargetBinding target (Render.Attachment (formatCode Rgba8Srgb) (fromIntegral side) (fromIntegral side) evidenceMetrics) Nothing)
                        else Nothing
                  , Render.frameWindow = Nothing
                  , Render.frameWindowDepth = Nothing
                  , Render.frameChunks = const Nothing
                  , Render.frameOmitted = Set.empty
                  }
          ticket ← recordOn "recording the frame" $ \builders →
            Render.prepareSnapshot (renderBuilders builders) (preparedRenderer prepared) input >>= \case
              Left refusal → pure (Left (RefusedIllegal (tshow refusal)))
              Right recording →
                pure . Right $ \recorder →
                  recording recorder >>= \case
                    Left refusal → pure (Left (RefusedIllegal (tshow refusal)))
                    Right () →
                      inOrder
                        [ transitionResource recorder target (FromUse ColorAttachment) TransferRead
                        , copyTargetToReadback recorder target readback
                        , transitionResource recorder target (FromUse TransferRead) ColorAttachment
                        ]
          case ticket of
            Left failure → pure (Left failure)
            Right batch →
              awaitBatch batch >>= \case
                Left failure → pure (Left ("the batch did not complete: " <> failure))
                Right () →
                  readBytes readback targetBytes >>= \case
                    Left failure → pure (Left ("the readback was not read: " <> failure))
                    Right bytes → do
                      swap ← demonstrateSwap actOn prepared
                      pure $ case swap of
                        Left failure → Left failure
                        Right shown →
                          let (probes, named) = judged valid prepared bytes
                           in Right (bytes, probes, named, shown)

-- | Judge every pixel against the oracle and every named probe against its
-- hand-stated colour.
judged ∷ ValidSnapshot → Prepared → ByteString → ([ProbeResult], [NamedResult])
judged valid prepared bytes = (probes, named)
  where
    decodedByHandle = Map.fromList [(handle, preparedDecoded prepared Map.! name) | (name, handle) ← Map.toList (preparedHandles prepared)]
    extent = PixelExtent side side
    oracle =
      newOracle
        OracleInput
          { inputSnapshot = valid
          , inputCutoutMarks = noCutoutMarks
          , inputWindow = Nothing
          , inputOffscreen = Map.singleton (targetRef 1 1) (TargetSpec evidenceMetrics R8G8B8A8Srgb extent)
          , inputTextures = (`Map.lookup` decodedByHandle)
          }
    observed (Probe _ x y) = either (const Nothing) Just (readPixel R8G8B8A8Srgb extent bytes x y)
    judge probe = judgeReadback oracle probe bytes
    probes =
      [ ProbeResult at (expect oracle at) (observed at) (judge at)
      | y ← [0 .. side - 1]
      , x ← [0 .. side - 1]
      , let at = Probe 0 x y
      ]
    named =
      [ NamedResult
          { namedProbe = candidate
          , namedOracle = oracleSays
          , namedContrastOracle = contrastSays
          , namedObserved = observed at
          , namedHeld = maybe False (within 1 (probeColour candidate)) (observed at)
          , namedAgreed = case oracleSays of
              Expected value (Tolerance tr tg tb ta) → withinBy (tr, tg, tb, ta) (probeColour candidate) value
              _ → False
          , namedDistinguishes = case contrastSays of
              Expected value _ → not (within 8 (probeContrastColour candidate) value) || probeColour candidate /= probeContrastColour candidate
              _ → False
          }
      | candidate ← namedProbes
      , let at = at' (probePixel candidate)
            oracleSays = expect oracle at
            contrastSays = expect oracle (at' (probeContrastPixel candidate))
      ]
    at' (x, y) = Probe 0 x y

-- | Whether the readback is within this many steps of the colour on every
-- channel.
within ∷ Int → Colour → Rgba8 → Bool
within steps colour = withinBy (fromIntegral steps, fromIntegral steps, fromIntegral steps, fromIntegral steps) colour

withinBy ∷ (Word8, Word8, Word8, Word8) → Colour → Rgba8 → Bool
withinBy (tr, tg, tb, ta) (Colour r g b a) (Rgba8 r' g' b' a') =
  close tr r r' && close tg g g' && close tb b b' && close ta a a'
  where
    close tolerance one other = abs (fromIntegral one - fromIntegral other ∷ Int) <= fromIntegral tolerance

-- | Show the swap rule on the registered textures: a swap of the quadrants'
-- handle to the fade image is refused, changes nothing, and is accepted when
-- the registered mark is explicitly kept.
demonstrateSwap
  ∷ (∀ a. Text → (∀ q inst msgr phys dev cmd. Builders q inst msgr phys dev cmd → IO (Either Refusal a)) → IO (Either Text a))
  → Prepared
  → IO (Either Text SwapDemonstration)
demonstrateSwap actOn prepared = do
  let quadrants = preparedHandles prepared Map.! Quadrants
      fade = preparedImages prepared Map.! Fade
      decoded = preparedDecoded prepared Map.! Fade
      textures = preparedTextures prepared
  actOn "swapping the quadrants' texture" $ \builders → do
    refused ← swapTexture (renderBuilders builders) textures quadrants fade decoded RefuseMarkChange
    afterRefusal ← registeredMark textures quadrants
    kept ← swapTexture (renderBuilders builders) textures quadrants fade decoded KeepRegisteredMark
    afterKeep ← registeredMark textures quadrants
    pure . Right $
      SwapDemonstration
        { swapRefused = case refused of
            Left (MarkMismatch registered computed) → Just (registered, computed)
            _ → Nothing
        , swapMarkAfterRefusal = afterRefusal
        , swapKeepAccepted = either (const False) (const True) kept
        , swapMarkAfterKeep = afterKeep
        }

-- | Run each command in order, stopping at the first refusal.
inOrder ∷ [IO (Either Refusal ())] → IO (Either Refusal ())
inOrder = \case
  [] → pure (Right ())
  step : rest → step >>= either (pure . Left) (const (inOrder rest))

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show

-- ---------------------------------------------------------------------------
-- The probe record

-- | The probe record: a JSON document of the target, the counts of what
-- passed, failed and was indeterminate, each named probe with its behaviour,
-- hand-stated colour, the oracle's expectation, the observed value and its
-- contrast, every failed probe, the first indeterminate ones with their
-- reasons, and the swap demonstration.
renderRecord ∷ Maybe Text → Int → [ProbeResult] → [NamedResult] → Maybe SwapDemonstration → Text
renderRecord failure bytesRead probes named swap =
  Text.pack . (<> "\n") $
    object
      [ ("failure", maybe "null" (str . Text.unpack) failure)
      , ("target", targetRecord)
      , ("counts", counts)
      , ("named", list (map namedRecord named))
      , ("failed", list [failedRecord probed | probed ← take 50 (filter (failedVerdict . probeVerdict) probes)])
      , ("indeterminate", list [indeterminateRecord probed | probed ← take 50 (filter isIndeterminate probes)])
      , ("swap", maybe "null" swapRecord swap)
      , ("png", str pngName)
      ]
  where
    metrics = evidenceMetrics
    PixelExtent logicalWidth logicalHeight = metricsLogical metrics
    PixelExtent framebufferWidth framebufferHeight = metricsFramebuffer metrics
    targetRecord =
      object
        [ ("format", str "Rgba8Srgb")
        , ("width", show side)
        , ("height", show side)
        , ("logical_extent", list [show logicalWidth, show logicalHeight])
        , ("framebuffer_extent", list [show framebufferWidth, show framebufferHeight])
        , ("content_scale", list [show (metricsScaleX metrics), show (metricsScaleY metrics)])
        , ("ui_scale", "1.0")
        , ("readback_bytes", show bytesRead)
        ]
    determinate = [probed | probed ← probes, isExpected (probeExpectation probed)]
    counts =
      object
        [ ("probes", show (length probes))
        , ("determinate", show (length determinate))
        , ("determinate_passed", show (length (filter (passes . probeVerdict) determinate)))
        , ("indeterminate", show (length (filter isIndeterminate probes)))
        , ("failed", show (length (filter (failedVerdict . probeVerdict) probes)))
        ]
    namedRecord result =
      let candidate = namedProbe result
       in object
            [ ("behaviour", str (probeBehaviour candidate))
            , ("covers", str (show (probeCovers candidate)))
            , ("pixel", pixel (probePixel candidate))
            , ("colour", colour (probeColour candidate))
            , ("contrast_pixel", pixel (probeContrastPixel candidate))
            , ("contrast_colour", colour (probeContrastColour candidate))
            , ("oracle", expectationRecord (namedOracle result))
            , ("contrast_oracle", expectationRecord (namedContrastOracle result))
            , ("observed", maybe "null" rgba (namedObserved result))
            , ("held", bool (namedHeld result))
            , ("oracle_agreed", bool (namedAgreed result))
            , ("distinguishes", bool (namedDistinguishes result))
            ]
    failedRecord probed =
      object
        [ ("probe", probeRecord (probeAt probed))
        , ("expected", expectationRecord (probeExpectation probed))
        , ("observed", maybe "null" rgba (probeObserved probed))
        , ("verdict", str (show (probeVerdict probed)))
        ]
    indeterminateRecord probed =
      object
        [ ("probe", probeRecord (probeAt probed))
        , ("reason", str (show (probeExpectation probed)))
        ]
    swapRecord shown =
      object
        [ ("refused_with_marks", maybe "null" (\(registered, computed) → list [bool registered, bool computed]) (swapRefused shown))
        , ("mark_after_refusal", maybe "null" bool (swapMarkAfterRefusal shown))
        , ("keep_accepted", bool (swapKeepAccepted shown))
        , ("mark_after_keep", maybe "null" bool (swapMarkAfterKeep shown))
        ]
    probeRecord (Probe pass' x y) = object [("pass", show pass'), ("x", show x), ("y", show y)]
    pixel (x, y) = list [show x, show y]
    colour (Colour r g b a) = list (map show [r, g, b, a])
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
