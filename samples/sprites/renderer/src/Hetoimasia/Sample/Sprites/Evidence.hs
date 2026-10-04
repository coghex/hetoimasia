-- | The sprites sample's window-free evidence (GRS-8): the scene rendered
-- into the 256×256 linear RGBA8 target of a surface-free session, read back
-- only once its batch's completion is proved, checked against the
-- independent oracle, and written as a lossless PNG and a probe record.
--
-- The sample's executable (@hetoimasia-sprites --evidence@) and the window
-- integration's native suite both run it, over the same scene and renderer:
-- each supplies a 'Host' over its own session and calls 'runEvidence'.
--
-- The run fails — 'evidencePassed' is false, and the PNG and record still
-- say why when they could be written — when an owner-thread action is
-- refused, an upload does not complete, the placeholder is not written in
-- time, the batch does not complete, the readback is missing or short, or
-- any probe fails. The BC7 fixture is the one optional check: on a device
-- that does not take BC7 it is not drawn, its probes are not made, and the
-- record says so.
module Hetoimasia.Sample.Sprites.Evidence
  ( Host (..)
  , Evidence (..)
  , runEvidence
  , pngName
  , recordName
  , renderRecord
  ) where

import Control.Concurrent (threadDelay)
import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map
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
  , ImageDescription (..)
  , ImageFormat (..)
  , ImageKind (..)
  , Readback
  , Recorder
  , Refusal
  , formatCode
  )
import Hetoimasia.GPU.Vulkan.Native.TextureTable (TableView (..), tableSamplerIndex)
import Hetoimasia.GPU.Vulkan.Native.Uploads (UploadRequest)
import Hetoimasia.Sample.Sprites
  ( Builders (..)
  , Made (..)
  , SceneTarget (..)
  , makeSprites
  , pipelineFor
  , recordScene
  , registerSprites
  , spritesWithBc7
  , uploadRequests
  )
import Hetoimasia.Sample.Sprites.Fixtures (Fixture (..), Rgba (..), fixture)
import Hetoimasia.Sample.Sprites.Oracle (Expectation (..), ProbeResult (..), evaluateProbes, probesPassed)
import Hetoimasia.Sample.Sprites.Png (encodePng)
import Hetoimasia.Sample.Sprites.Scene (Draw (..), Probe (..), sceneDraws, targetBytes, targetSide)

-- | What the evidence needs of a session.
data Host = Host
  { hostAct ∷ ∀ a. Text → (∀ q inst msgr phys dev cmd. Builders q inst msgr phys dev cmd → IO (Either Refusal a)) → IO (Either Text a)
    -- ^ Run an owner-thread action over the session's constructions, naming
    -- it for a failure's report.
  , hostRecord ∷ Text → (∀ q inst msgr phys dev cmd. Builders q inst msgr phys dev cmd → IO (Either Refusal (Recorder q inst msgr phys dev cmd → IO (Either Refusal ())))) → IO (Either Text BatchTicket)
    -- ^ Run an owner-thread action that prepares a frame-less batch's
    -- recording through the constructions, then records that batch, which
    -- is submitted when the action returns; answer its ticket.
  , hostUpload ∷ UploadRequest → IO (Either Text ())
    -- ^ Admit an upload off the owner's thread and wait, with a deadline,
    -- for it to complete.
  , hostAwait ∷ BatchTicket → IO (Either Text ())
    -- ^ Wait, with a deadline, for a batch to complete.
  , hostReadTable ∷ IO (Either Text (Maybe TableView))
    -- ^ The texture table as it stands, read on the owner's thread.
  , hostRead ∷ Readback → IO (Either Text ByteString)
    -- ^ The readback's bytes, once its batch has completed.
  }

-- | What one evidence run found.
data Evidence = Evidence
  { evidencePassed ∷ !Bool
  , evidenceFailure ∷ !(Maybe Text)
    -- ^ Why the run stopped before checking probes, if it did.
  , evidenceBc7 ∷ !(Maybe Bool)
    -- ^ Whether the BC7 fixture was drawn: 'Nothing' when the run stopped
    -- before the textures were made.
  , evidenceProbes ∷ ![ProbeResult]
  , evidenceReadback ∷ !Int
    -- ^ The bytes read back.
  , evidencePng ∷ !(Maybe FilePath)
  , evidenceRecord ∷ !FilePath
  }

pngName, recordName ∷ FilePath
pngName = "sprites.png"
recordName = "sprites-probes.json"

-- | Run the evidence over a host, writing the PNG and the probe record into
-- this directory, which is made if missing and never deleted.
runEvidence ∷ Host → FilePath → IO Evidence
runEvidence Host {hostAct = actOn, hostRecord = recordOn, hostUpload = upload, hostAwait = awaitBatch, hostReadTable = readTable, hostRead = readBytes} directory = do
  createDirectoryIfMissing True directory
  outcome ← evidence
  let recordPath = directory </> recordName
  case outcome of
    Left (failure, bc7) → do
      ByteString.writeFile recordPath (Text.encodeUtf8 (renderRecord (Just failure) bc7 0 []))
      pure (Evidence False (Just failure) bc7 [] 0 Nothing recordPath)
    Right (bc7, bytes, probes) → do
      let complete = ByteString.length bytes == fromIntegral targetBytes
          failure = if complete then Nothing else Just ("the readback held " <> tshow (ByteString.length bytes) <> " bytes, not " <> tshow targetBytes)
          pngPath = directory </> pngName
      ByteString.writeFile pngPath (encodePng targetSide targetSide bytes)
      ByteString.writeFile recordPath (Text.encodeUtf8 (renderRecord failure (Just bc7) (ByteString.length bytes) probes))
      pure (Evidence (complete && probesPassed probes) failure (Just bc7) probes (ByteString.length bytes) (Just pngPath) recordPath)
  where
    evidence = do
      madeAnswer ← actOn "making the ring, the table, the textures and the layout" $ \builders → do
        made ← makeSprites builders
        target ← buildImage builders (ImageDescription ColorTarget Rgba8Linear side side 1)
        readback ← buildReadback builders targetBytes
        pure ((,,) <$> made <*> target <*> readback)
      case madeAnswer of
        Left failure → pure (Left (failure, Nothing))
        Right (made, target, readback) → do
          let bc7 = Map.size (madeTextures made) == 3
          uploads ← traverse upload (uploadRequests made)
          case sequence uploads of
            Left failure → pure (Left ("an upload did not complete: " <> failure, Just bc7))
            Right _ →
              awaitPlaceholder (200 ∷ Int) >>= \case
                Left failure → pure (Left (failure, Just bc7))
                Right () → do
                  ticket ← recordOn "registering the textures and recording the scene" $ \builders →
                    registerSprites builders made >>= \case
                      Left refusal → pure (Left refusal)
                      Right sprites →
                        fmap (\pipeline → recordScene sprites pipeline (Offscreen target readback))
                          <$> pipelineFor builders sprites (formatCode Rgba8Linear)
                  case ticket of
                    Left failure → pure (Left (failure, Just bc7))
                    Right batch →
                      awaitBatch batch >>= \case
                        Left failure → pure (Left ("the scene's batch did not complete: " <> failure, Just bc7))
                        Right () →
                          readBytes readback >>= \case
                            Left failure → pure (Left ("the readback was not read: " <> failure, Just bc7))
                            Right bytes → pure (Right (bc7, bytes, evaluateProbes bc7 bytes))
    side = fromIntegral targetSide
    -- The table binds once its placeholder's upload has completed and its
    -- descriptor is written, which the owner's steps do.
    awaitPlaceholder remaining =
      readTable >>= \case
        Left failure → pure (Left failure)
        Right (Just view) | tableViewPlaceholderWritten view → pure (Right ())
        Right _
          | remaining <= 0 → pure (Left "the texture table's placeholder was not written within ten seconds")
          | otherwise → threadDelay 50000 >> awaitPlaceholder (remaining - 1)

-- | The probe record: a JSON document of the target, the fixtures, the
-- draws, the BC7 status, the readback, and every probe's expected and
-- observed values, tolerance and result.
renderRecord ∷ Maybe Text → Maybe Bool → Int → [ProbeResult] → Text
renderRecord failure bc7 readbackBytes probes =
  Text.pack . (<> "\n") $
    object
      [ ("target", object [("width", show targetSide), ("height", show targetSide), ("format", str "R8G8B8A8_UNORM"), ("clear", rgba (Rgba 0 0 0 0)), ("mip_level", "0")])
      , ("fixtures", list [fixtureRecord (fixture name) | name ← [minBound .. maxBound]])
      , ( "draws"
        , list
            [ object
                [ ("name", str (show (drawName draw)))
                , ("sampler", str (show (drawFilter draw)))
                , ("sampler_index", show (tableSamplerIndex (drawFilter draw)))
                , ("instances", show (length (drawInstances draw)))
                ]
            | draw ← sceneDraws (bc7 == Just True)
            ]
        )
      , ("bc7", object [("supported", maybe "null" bool bc7), ("exercised", maybe "false" bool bc7)])
      , ("readback_bytes", show readbackBytes)
      , ("readback_expected_bytes", show targetBytes)
      , ("failure", maybe "null" (str . Text.unpack) failure)
      , ( "probes"
        , list
            [ object
                [ ("name", str (Text.unpack (probeName (resultProbe result))))
                , ("purpose", str (show (probePurpose (resultProbe result))))
                , ("x", show (fst (probePixel (resultProbe result))))
                , ("y", show (snd (probePixel (resultProbe result))))
                , ("expected", rgba (expectedRgba (resultExpected result)))
                , ("observed", rgba (resultObserved result))
                , ("tolerance", show (expectedTolerance (resultExpected result)))
                , ("passed", bool (resultPassed result))
                ]
            | result ← probes
            ]
        )
      , ("passed", bool (failure == Nothing && probesPassed probes))
      ]
  where
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
      c → [c]
    bool ∷ Bool → String
    bool value = if value then "true" else "false"
    rgba ∷ Rgba → String
    rgba (Rgba r g b a) = list (map show [r, g, b, a])
    fixtureRecord texture =
      object
        [ ("name", str (show (fixtureName texture)))
        , ("format", str (show (fixtureFormat texture)))
        , ("width", show (fixtureWidth texture))
        , ("height", show (fixtureHeight texture))
        , ("mip_levels", "1")
        , ("bytes", str (concatMap hex (ByteString.unpack (fixtureBytes texture))))
        ]
    hex ∷ Word8 → String
    hex byte = let digits = showHex byte "" in if length digits == 1 then '0' : digits else digits

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
