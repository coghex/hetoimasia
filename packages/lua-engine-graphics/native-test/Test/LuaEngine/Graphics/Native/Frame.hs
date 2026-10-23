-- | A registered texture, resolved through the public table and renderer path in a frame-less offscreen
-- batch of a window-free session, and read back.
--
-- The path is the renderer's own ("Hetoimasia.Render.TwoD.Vulkan": a validated render-2d snapshot prepared
-- and recorded into one batch), through the session's one table, so a texture whose registration did not
-- resolve to its own slot would draw the transparent-black placeholder and the readback would say so. A raw
-- upload readback could not: it would prove the bytes arrived, not that the registration is usable.
--
-- Two judges look at the readback and neither is the device. The render-2d oracle expects every pixel the
-- scene determines, from the decoded image the file decoded to; and four hand-stated probes, read off the
-- fixture's own table, ask the orientation and the alpha directly, apart from any decoder and oracle.
module Test.LuaEngine.Graphics.Native.Frame
  ( Shot (..)
  , shoot
  , sideWidth
  , sideHeight
  ) where

import Control.Concurrent.STM (atomically, retry)
import Data.ByteString (ByteString)
import Data.Maybe (catMaybes)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word8)
import Numeric.Natural (Natural)

import Hetoimasia.Asset.Image (DecodedImage (..))
import Hetoimasia.GPU.Vulkan.GLFW
  ( ActionOutcome (..)
  , BatchTicket
  , ImageDescription (..)
  , ImageFormat (Rgba8Srgb)
  , ImageKind (ColorTarget)
  , Refusal (..)
  , ResourceUse (..)
  , TicketState (..)
  , TransitionSource (..)
  , VulkanAction (..)
  , VulkanHost
  , awaitVulkanAction
  , constructFramelessBatch
  , constructImage
  , constructReadback
  , copyTargetToReadback
  , formatCode
  , readConstructedReadback
  , readTicket
  , releaseConstructed
  , submitVulkanAction
  , transitionResource
  )
import Hetoimasia.LuaEngine.Graphics.Texture.Host (hostBuilders)
import Hetoimasia.Math.Affine2 (fromColumns)
import Hetoimasia.Math.Vector (V2 (..))
import qualified Hetoimasia.Render.Api.Texture as Api
import Hetoimasia.Render.TwoD.DrawPlan (noCutoutMarks)
import Hetoimasia.Render.TwoD.Material (defaultMaterial)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import Hetoimasia.Render.TwoD.Oracle
  ( Expectation (..)
  , OracleInput (..)
  , Probe (..)
  , TargetSpec (..)
  , expect
  , judgeReadback
  , newOracle
  , passes
  )
import Hetoimasia.Render.TwoD.Oracle.Colour (ColourFormat (..), Rgba8 (..))
import Hetoimasia.Render.TwoD.Oracle.Readback (readPixel)
import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Target.Backend (targetRef)
import Hetoimasia.Render.TwoD.Validation (validateSnapshot)
import qualified Hetoimasia.Render.TwoD.Vulkan as Render

-- | What one drawing came to.
data Shot = Shot
  { shotBytes ∷ !ByteString
    -- ^ The target's pixels, RGBA8, top row first.
  , shotDeterminate ∷ !Int
    -- ^ Pixels the oracle determined and the readback matched.
  , shotFailed ∷ ![Text]
    -- ^ Pixels the oracle determined and the readback did not match, and the hand probes that failed.
  , shotProbes ∷ ![Text]
    -- ^ The hand probes, as read.
  }

-- | The offscreen target's size: small enough to read in full, large enough for the texture with a margin.
sideWidth, sideHeight ∷ Int
sideWidth = 32
sideHeight = 16

metrics ∷ TargetMetrics
metrics = TargetMetrics (PixelExtent (fromIntegral sideWidth) (fromIntegral sideHeight)) (PixelExtent (fromIntegral sideWidth) (fromIntegral sideHeight)) 1 1

target ∷ Target
target = OffscreenTarget (targetRef 1 1)

-- | Draw this texture one texel to a pixel at the middle of the target and read the target back.
shoot ∷ ∀ scene. VulkanHost scene → Render.Renderer → Api.TextureHandle → DecodedImage → (Int → Int → (Word8, Word8, Word8, Word8)) → IO (Either Text Shot)
shoot host renderer handle decoded straight =
  case validateSnapshot snapshot of
    Left refused → pure (Left ("the snapshot was refused: " <> tshow refused))
    Right valid → do
      made ← act "making the target and the readback" $ VulkanAction $ \construction → do
        image ← constructImage construction (ImageDescription ColorTarget Rgba8Srgb (fromIntegral sideWidth) (fromIntegral sideHeight) 1)
        readback ← constructReadback construction bytesWanted
        pure ((,) <$> image <*> readback)
      case made of
        Left failure → pure (Left failure)
        Right (image, readback) → do
          let input =
                Render.FrameInput
                  { Render.frameSnapshot = valid
                  , Render.frameMarks = noCutoutMarks
                  , Render.frameTarget = \reference →
                      if target == OffscreenTarget reference
                        then Just (Render.TargetBinding image (Render.Attachment (formatCode Rgba8Srgb) (fromIntegral sideWidth) (fromIntegral sideHeight) metrics) Nothing)
                        else Nothing
                  , Render.frameWindow = Nothing
                  , Render.frameWindowDepth = Nothing
                  , Render.frameChunks = const Nothing
                  , Render.frameOmitted = Set.empty
                  }
          batch ← act "recording the frame" $ VulkanAction $ \construction →
            Render.prepareSnapshot (hostBuilders host construction) renderer input >>= \case
              Left refusal → pure (Left (RefusedIllegal (tshow refusal)))
              Right recording →
                constructFramelessBatch construction (\recorder →
                  recording recorder >>= \case
                    Left refusal → pure (Left (RefusedIllegal (tshow refusal)))
                    Right () →
                      inOrder
                        [ transitionResource recorder image (FromUse ColorAttachment) TransferRead
                        , copyTargetToReadback recorder image readback
                        , transitionResource recorder image (FromUse TransferRead) ColorAttachment
                        ])
                  >>= \case
                    Left refusal → pure (Left refusal)
                    Right (ticket, Left refusal) → const (Left refusal) <$> pure ticket
                    Right (ticket, Right ()) → pure (Right ticket)
          case batch of
            Left failure → pure (Left failure)
            Right ticket → do
              done ← awaitBatch ticket
              if not done
                then pure (Left "the batch did not complete")
                else do
                  read' ← act "reading the readback" $ VulkanAction $ \construction → readConstructedReadback construction readback 0 bytesWanted
                  -- The target and the readback are released whatever the read came to.
                  _ ← act "releasing the target" $ VulkanAction $ \construction → do
                    _ ← releaseConstructed construction image
                    releaseConstructed construction readback
                  pure (read' >>= judge valid)
  where
    bytesWanted ∷ Natural
    bytesWanted = fromIntegral (sideWidth * sideHeight * 4)
    snapshot = Snapshot [Pass target (ClearColour 0 0 0 1) [view]]
    textureWidth = fromIntegral (decodedWidth decoded) ∷ Float
    textureHeight = fromIntegral (decodedHeight decoded) ∷ Float
    view =
      ViewWith
        { viewCamera = Camera (V2 0 0) 1 Nothing
        , viewViewport = Viewport (V2 0 0) (V2 (fromIntegral sideWidth) (fromIntegral sideHeight))
        , viewSettings = defaultViewSettings
        , viewClips = []
        , viewMaterials = Map.empty
        , viewFrameTables = []
        , viewAnimationTime = 0
        , viewLayers = [WorldLayer DepthDisabled [sprite]]
        }
    sprite =
      Instance
        { instanceTransform = fromColumns (V2 textureWidth 0) (V2 0 textureHeight) (V2 (negate textureWidth / 2) (negate textureHeight / 2))
        , instanceUv = UvRect 0 0 1 1
        , instanceTexture = handle
        , instanceDepthKey = 0
        , instanceTint = Tint 255 255 255 255
        , instanceSampler = SamplerDefault
        , instanceTranslucent = False
        , instanceAdditive = False
        , instanceClip = 0
        , instanceFrameTable = 0
        , instanceParameter = 0
        , instanceMaterial = defaultMaterial
        }
    act ∷ ∀ a. Text → VulkanAction (Either Refusal a) → IO (Either Text a)
    act what action =
      atomically (submitVulkanAction host action) >>= \case
        Left refusal → pure (Left (what <> " was refused: " <> tshow refusal))
        Right ticket →
          atomically (awaitVulkanAction ticket) >>= \case
            ActionReturned (Right value) → pure (Right value)
            ActionReturned (Left refusal) → pure (Left (what <> " was refused: " <> tshow refusal))
            ActionRaised failure → pure (Left (what <> " raised: " <> tshow failure))
            ActionRefused refusal → pure (Left (what <> " was refused before it ran: " <> tshow refusal))
    judge valid bytes = Right (judged valid bytes)
    judged valid bytes = Shot bytes (length determinate) failures handProbes
      where
        extent = PixelExtent (fromIntegral sideWidth) (fromIntegral sideHeight)
        oracle =
          newOracle
            OracleInput
              { inputSnapshot = valid
              , inputCutoutMarks = noCutoutMarks
              , inputWindow = Nothing
              , inputOffscreen = Map.singleton (targetRef 1 1) (TargetSpec metrics R8G8B8A8Srgb extent)
              , inputTextures = (`Map.lookup` Map.singleton handle decoded)
              }
        results =
          [ (at, expect oracle at, judgeReadback oracle at bytes)
          | y ← [0 .. sideHeight - 1]
          , x ← [0 .. sideWidth - 1]
          , let at = Probe 0 x y
          ]
        determinate = [() | (_, Expected _ _, verdict) ← results, passes verdict]
        failures =
          [ "pixel (" <> tshow x <> "," <> tshow y <> ") " <> tshow verdict
          | (Probe _ x y, Expected _ _, verdict) ← results
          , not (passes verdict)
          ]
            <> handFailures
        (handProbes, handFailures) = hand bytes decoded straight

-- | Four probes read off the fixture's table by hand, apart from any decoder and oracle. The image is drawn
-- one texel to a pixel, centred, over an opaque black clear; its four corners are found from what is drawn
-- (every texel of the fixture has colour) and asked what the fixture says they are. The top-left texel is
-- opaque and red grows with x, so a mirror in either axis is a wrong colour; the top-right quarter is half
-- transparent, so it reads darker than the same colour opaque and is never black.
hand ∷ ByteString → DecodedImage → (Int → Int → (Word8, Word8, Word8, Word8)) → ([Text], [Text])
hand bytes decoded straight =
  case drawn of
    [] → (["nothing was drawn"], ["nothing was drawn: the registration drew the placeholder, or no texture"])
    _ →
      let left = minimum (map fst drawn)
          top = minimum (map snd drawn)
          width = fromIntegral (decodedWidth decoded)
          height = fromIntegral (decodedHeight decoded)
          corners = [("top-left", 0, 0), ("top-right", width - 1, 0), ("bottom-left", 0, height - 1), ("bottom-right", width - 1, height - 1)]
          observed = [(name, x, y, pixel (left + x) (top + y)) | (name, x, y) ← corners]
          report = [name <> " " <> tshow x <> "," <> tshow y <> " reads " <> tshow got | (name, x, y, got) ← observed]
          failures =
            catMaybes
              [ if a == 255
                  then if near 2 got (Rgba8 r g b 255) then Nothing else Just (name <> " should read " <> tshow (r, g, b) <> ", read " <> tshow got)
                  else
                    -- Half transparent over opaque black: darker than the opaque colour and not black.
                    let Rgba8 gr gg gb _ = got
                     in if gr + gg + gb > 0 && gr < r && gg <= g && gb <= b
                          then Nothing
                          else Just (name <> " should read darker than " <> tshow (r, g, b) <> " and not black, read " <> tshow got)
              | (name, x, y, got) ← observed
              , let (r, g, b, a) = straight x y
              ]
       in (report, failures)
  where
    pixel x y = either (const (Rgba8 0 0 0 0)) id (readPixel R8G8B8A8Srgb (PixelExtent (fromIntegral sideWidth) (fromIntegral sideHeight)) bytes x y)
    drawn = [(x, y) | y ← [0 .. sideHeight - 1], x ← [0 .. sideWidth - 1], let Rgba8 r g b _ = pixel x y, r + g + b > 0]
    near tolerance (Rgba8 a b c _) (Rgba8 d e f _) = all (\(p, q) → abs (fromIntegral p - fromIntegral q ∷ Int) <= tolerance) [(a, d), (b, e), (c, f)]

-- | Wait, in STM, for a batch to complete. The device's loss or a discard ends the wait with a no.
awaitBatch ∷ BatchTicket → IO Bool
awaitBatch ticket = atomically $ do
  readTicket ticket >>= \case
    TicketPending → retry
    TicketComplete → pure True
    _ → pure False

inOrder ∷ [IO (Either Refusal ())] → IO (Either Refusal ())
inOrder = \case
  [] → pure (Right ())
  step : rest → step >>= either (pure . Left) (const (inOrder rest))

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
