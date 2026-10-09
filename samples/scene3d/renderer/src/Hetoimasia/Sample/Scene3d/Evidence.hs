-- | The scene3d sample's window-free evidence (GRS-10): the scene rendered
-- from two camera poses into a 256×192 linear RGBA8 target with a depth
-- target, in a surface-free session, each pose read back only once its
-- batch's completion is proved, checked against the independent oracle, and
-- written as a lossless PNG together with a probe record.
--
-- The sample's executable (@hetoimasia-scene3d --evidence@) and the window
-- integration's native suite both run it, over the same scene and renderer:
-- each supplies a 'Host' over its own session and calls 'runEvidence'.
--
-- The second pose is recorded only after the first pose's batch has
-- completed, into the same two targets: it keeps the colour and depth the
-- first one initialized ('ClearTarget') and clears both again, so the run also
-- shows that nothing of the first pose survives into the second.
--
-- The run fails — 'evidencePassed' is false, and the record still says why
-- when it could be written — when an owner-thread action is refused, the
-- depth format cannot be chosen, a batch does not complete, a readback is
-- missing or short, or any probe fails.
module Hetoimasia.Sample.Scene3d.Evidence
  ( Host (..)
  , Evidence (..)
  , PoseEvidence (..)
  , runEvidence
  , pngNameFor
  , recordName
  , renderRecord
  , depthFormatName
  ) where

import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import Data.List (intercalate)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Word (Word8)
import Numeric (showHex)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

import Hetoimasia.GPU.Vulkan.Native.Recording
  ( BatchTicket
  , ImageFormat (..)
  , PassStart (..)
  , Readback
  , Recorder
  , Refusal
  , formatCode
  )
import Hetoimasia.Sample.Scene3d
  ( Builders (..)
  , Made (..)
  , makeScene
  , readbackFor
  , recordPose
  )
import Hetoimasia.Sample.Scene3d.Oracle (Hit (..), ProbeResult (..), evaluateProbes, probesPassed)
import Hetoimasia.Sample.Scene3d.Png (encodePng)
import Hetoimasia.Sample.Scene3d.Scene
  ( Cube (..)
  , Pose (..)
  , PoseName (..)
  , Probe (..)
  , Rgba (..)
  , clearColour
  , cubes
  , drawOrder
  , poses
  , targetBytes
  , targetHeight
  , targetWidth
  )

-- | What the evidence needs of a session.
data Host = Host
  { hostAct ∷ ∀ a. Text → (∀ q inst msgr phys dev cmd. Builders q inst msgr phys dev cmd → IO (Either Refusal a)) → IO (Either Text a)
    -- ^ Run an owner-thread action over the session's constructions, naming
    -- it for a failure's report.
  , hostRecord ∷ Text → (∀ q inst msgr phys dev cmd. Builders q inst msgr phys dev cmd → IO (Either Refusal (Recorder q inst msgr phys dev cmd → IO (Either Refusal ())))) → IO (Either Text BatchTicket)
    -- ^ Run an owner-thread action that prepares a frame-less batch's
    -- recording through the constructions, then records that batch, which
    -- is submitted when the action returns; answer its ticket.
  , hostAwait ∷ BatchTicket → IO (Either Text ())
    -- ^ Wait, with a deadline, for a batch to complete.
  , hostRead ∷ Readback → IO (Either Text ByteString)
    -- ^ The readback's bytes, once its batch has completed.
  }

-- | What one pose's capture found.
data PoseEvidence = PoseEvidence
  { poseEvidenceName ∷ !PoseName
  , poseEvidenceProbes ∷ ![ProbeResult]
  , poseEvidenceBytes ∷ !Int
    -- ^ The bytes read back.
  , poseEvidencePng ∷ !(Maybe FilePath)
    -- ^ The capture, written only when the whole target was read back.
  }

-- | What one evidence run found.
data Evidence = Evidence
  { evidencePassed ∷ !Bool
  , evidenceFailure ∷ !(Maybe Text)
    -- ^ Why the run stopped before checking every probe, if it did.
  , evidenceDepthFormat ∷ !(Maybe ImageFormat)
    -- ^ The depth format the backend chose: 'Nothing' when the run stopped
    -- before it was chosen.
  , evidencePoses ∷ ![PoseEvidence]
  , evidenceRecord ∷ !FilePath
  }

pngNameFor ∷ PoseName → FilePath
pngNameFor = \case
  FrontPose → "scene3d-front.png"
  SidePose → "scene3d-side.png"

recordName ∷ FilePath
recordName = "scene3d-probes.json"

-- | Run the evidence over a host, writing the PNGs and the probe record into
-- this directory, which is made if missing and never deleted.
runEvidence ∷ Host → FilePath → IO Evidence
runEvidence Host {hostAct = actOn, hostRecord = recordOn, hostAwait = awaitBatch, hostRead = readBytes} directory = do
  createDirectoryIfMissing True directory
  (depthFormat, outcome) ← collect
  let (failure, captured) = case outcome of
        Left (reason, found) → (Just reason, found)
        Right found → (Nothing, found)
      recordPath = directory </> recordName
  written ← traverse (write directory) captured
  ByteString.writeFile recordPath (Text.encodeUtf8 (renderRecord failure depthFormat written))
  pure
    Evidence
      { evidencePassed = failure == Nothing && length written == length poses && all (probesPassed . poseEvidenceProbes) written
      , evidenceFailure = failure
      , evidenceDepthFormat = depthFormat
      , evidencePoses = written
      , evidenceRecord = recordPath
      }
  where
    collect = do
      madeAnswer ← actOn "making the ring, the targets, the readbacks and the pipeline" makeScene
      case madeAnswer of
        Left failure → pure (Nothing, Left (failure, []))
        Right made -> (,) (Just (madeDepthFormat made)) <$> capture made [] (zip poses (ClearFromUndefined : repeat ClearTarget))
    -- Each pose is recorded after the one before it has completed and been
    -- read back.
    capture _ done [] = pure (Right (reverse done))
    capture made done ((pose, start) : rest) =
      case readbackFor made (poseName pose) of
        Nothing → pure (Left (called pose "has no readback", reverse done))
        Just readback → do
          ticket ← recordOn ("recording the " <> tshow (poseName pose)) $ \_ → pure (Right (recordPose made (poseName pose) start))
          case ticket of
            Left failure → pure (Left (failure, reverse done))
            Right batch →
              awaitBatch batch >>= \case
                Left failure → pure (Left (called pose ("batch did not complete: " <> failure), reverse done))
                Right () →
                  readBytes readback >>= \case
                    Left failure → pure (Left (called pose ("readback was not read: " <> failure), reverse done))
                    Right bytes
                      | ByteString.length bytes /= fromIntegral targetBytes →
                          pure (Left (called pose ("readback held " <> tshow (ByteString.length bytes) <> " bytes, not " <> tshow targetBytes), reverse ((poseName pose, bytes) : done)))
                      | otherwise → capture made ((poseName pose, bytes) : done) rest
    called pose what = "the " <> tshow (poseName pose) <> "'s " <> what

-- | Check one pose's readback against the oracle, and write its PNG if the
-- whole target was read.
write ∷ FilePath → (PoseName, ByteString) → IO PoseEvidence
write directory (name, bytes)
  | ByteString.length bytes == fromIntegral targetBytes = do
      let path = directory </> pngNameFor name
      ByteString.writeFile path (encodePng targetWidth targetHeight bytes)
      pure (PoseEvidence name (evaluateProbes name bytes) (ByteString.length bytes) (Just path))
  | otherwise = pure (PoseEvidence name [] (ByteString.length bytes) Nothing)

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show

-- | The Vulkan name of a depth format.
depthFormatName ∷ ImageFormat → String
depthFormatName = \case
  Depth32Float → "D32_SFLOAT"
  Depth24 → "X8_D24_UNORM_PACK32"
  Depth16 → "D16_UNORM"
  other → show other

-- | The probe record: a JSON document of the target, the depth state, the
-- draw order, the cubes, the poses, the readbacks, and every probe's
-- coordinates, expected and observed values, the face and cubes its ray
-- strikes, the cube it would show without a depth test, and its result.
renderRecord ∷ Maybe Text → Maybe ImageFormat → [PoseEvidence] → Text
renderRecord failure depthFormat captured =
  Text.pack . (<> "\n") $
    object
      [ ("target", object [("width", show targetWidth), ("height", show targetHeight), ("format", str "R8G8B8A8_UNORM"), ("clear", rgba clearColour), ("mip_level", "0")])
      , ( "depth"
        , object
            [ ("format", maybe "null" (str . depthFormatName) depthFormat)
            , ("format_code", maybe "null" (show . formatCode) depthFormat)
            , ("clear", "1.0")
            , ("test", "true")
            , ("write", "true")
            , ("compare", str "LESS_OR_EQUAL")
            ]
        )
      , ("draw_order", list [str (show name) | name ← drawOrder])
      , ("cubes", list [cubeRecord cube | cube ← cubes])
      , ("poses", list [poseRecord pose | pose ← poses])
      , ("failure", maybe "null" (str . Text.unpack) failure)
      , ("passed", bool (failure == Nothing && length captured == length poses && all (probesPassed . poseEvidenceProbes) captured))
      ]
  where
    cubeRecord cube =
      object
        [ ("name", str (show (cubeName cube)))
        , ("centre", vec (cubeCentre cube))
        , ("yaw_degrees", show (cubeYawDegrees cube))
        , ("half_extent", show (cubeHalfExtent cube))
        ]
    poseRecord pose =
      let found = [capture | capture ← captured, poseEvidenceName capture == poseName pose]
       in object
            [ ("name", str (show (poseName pose)))
            , ("eye", vec (poseEye pose))
            , ("target", vec (poseTarget pose))
            , ("up", vec (poseUp pose))
            , ("fov_degrees", show (poseFovDegrees pose))
            , ("near", show (poseNear pose))
            , ("far", show (poseFar pose))
            , ("readback_bytes", show (sum (map poseEvidenceBytes found)))
            , ("readback_expected_bytes", show targetBytes)
            , ("probes", list [probeRecord result | capture ← found, result ← poseEvidenceProbes capture])
            ]
    probeRecord result =
      object
        [ ("name", str (Text.unpack (probeName (resultProbe result))))
        , ("purpose", str (show (probePurpose (resultProbe result))))
        , ("x", show (fst (probePixel (resultProbe result))))
        , ("y", show (snd (probePixel (resultProbe result))))
        , ("expected", rgba (resultExpected result))
        , ("observed", rgba (resultObserved result))
        , ("face", maybe "null" (\hit → str (show (hitCube hit) <> " " <> show (hitFace hit))) (resultHit result))
        , ("covered_by", list [str (show name) | name ← resultCovered result])
        , ("without_depth_test", maybe "null" (str . show) (resultPainter result))
        , ("passed", bool (resultPassed result))
        ]
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
      '\b' → "\\b"
      '\f' → "\\f"
      c
        | c < ' ' → let digits = showHex (fromEnum c) "" in "\\u" <> replicate (4 - length digits) '0' <> digits
        | otherwise → [c]
    bool ∷ Bool → String
    bool value = if value then "true" else "false"
    rgba ∷ Rgba → String
    rgba (Rgba r g b a) = list (map show ([r, g, b, a] ∷ [Word8]))
    vec ∷ (Double, Double, Double) → String
    vec (x, y, z) = list (map show [x, y, z])
