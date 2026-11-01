-- | The adapter on a real device, with no window: the examples the controlled lifecycle suite cannot make.
--
-- Every example loads real files through the pipeline's verified reading and bounded decoding and this
-- backend, on the production graphics owner, and every claim about the device is read back from the device:
-- a texture drawn through the renderer's public path in a frame-less offscreen batch, its texels and
-- orientation and alpha judged; the largest legal level accepted through the configured staging; two
-- instances' independent textures; and the model's native accounting returning to what it was. Delays and
-- cancellations are coordinated through the adapter seam (a gated port over the same session) and then the
-- real native work is drained.
--
-- A skipped run is not a pass: the executable refuses to start without consent, and the examples have no
-- pending branch.
module Test.LuaEngine.Graphics.Native.Spec (spec, within, withLoaded, load, decoded') where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, retry, writeTVar)
import Control.Monad (unless)
import Data.IORef (readIORef)
import qualified Data.Map.Strict as Map
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Read as Text
import System.Timeout (timeout)
import Test.HUnit.Lang (assertFailure)
import Test.Hspec

import Hetoimasia.Asset (Asset (..), AssetId (..), Provenance (FromMemory))
import Hetoimasia.Asset.Image (DecodedImage (..), ImageKind (ColourImage))
import Hetoimasia.Asset.Image.Png (decodePng)
import Hetoimasia.GPU.Model (Usage (..))
import Hetoimasia.GPU.Vulkan.GLFW (UploadTicket, Image, VulkanHost (..))
import Hetoimasia.LuaEngine.Graphics.Texture
import Hetoimasia.LuaEngine.Graphics.Texture.Backend (readBackend, textureBackend, withBackend)
import Hetoimasia.LuaEngine.Graphics.Texture.Port
import Hetoimasia.LuaEngine.Texture (OwnerReading (..), ownerReading)
import Hetoimasia.Render.TwoD.Vulkan.Textures (registeredMark, retainedEntries)
import Hetoimasia.Runtime.GLFW (hostWindowIdentities)
import Test.LuaEngine.Graphics.Composition
import Test.LuaEngine.Graphics.Native.Frame
import Test.LuaEngine.Graphics.Native.Session
import qualified Test.LuaEngine.Graphics.Png as Png

spec ∷ Env → Spec
spec env = describe "the texture backend on a real device, with no window" $ do
  it "shows a small asymmetric PNG's texels, orientation and alpha through the public table and renderer path, after the request reported success" $
    within 60 . withLoaded env [("tiny.png", Png.asymmetric 8 4)] $ \comp vm → do
      identity ← load comp vm "a" "k" "tiny.png"
      noWindows env
      decoded ← decoded' (Png.asymmetric 8 4)
      shot ← draw env identity decoded
      shotFailed shot `shouldBe` []
      shotDeterminate shot `shouldSatisfy` (> 20)
      evidence env ("tiny.png: " <> tshow (shotDeterminate shot) <> " pixels judged by the oracle, hand probes " <> Text.intercalate "; " (shotProbes shot))
      -- Translucent texels, so the mark is not the binary-alpha cutout one.
      registeredMark (graphicsTextures (envGraphics env)) (textureHandleOf (fromIntegral identity)) `shouldReturn` Just False
      release' env comp vm "a" "k"
      settleToRest env

  it "accepts the largest legal level, 2,048 by 2,048, through the configured staging and registers it" $
    within 120 . withLoaded env [("big.png", Png.solid 2048 2048 (200, 100, 50, 255))] $ \comp vm → do
      atRest ← restNow env
      identity ← loadWith comp vm "a" "k" "big.png" (\line → line `shouldSatisfy` Text.isInfixOf "width=2048")
      during ← usageNow env
      -- The texture is a native resource for as long as it lives, and its staging copy is the configured
      -- staging's, charged once, so the session holds one resource more and no second copy of the level.
      usageResources during `shouldSatisfy` (> usageResources atRest)
      registeredMark (graphicsTextures (envGraphics env)) (textureHandleOf (fromIntegral identity)) `shouldReturn` Just True
      evidence env ("2048x2048: accounting at rest " <> summarise atRest <> "; while live " <> summarise during <> "; the configuration budgets " <> tshow (accountingNativeBytes (configurationAccounting (graphicsConfiguration (envGraphics env)))) <> " native bytes of " <> tshow (accountingNativeLimit (configurationAccounting (graphicsConfiguration (envGraphics env)))))
      release' env comp vm "a" "k"
      awaitUsage env (\now → usageBytes now == usageBytes atRest && usageObjects now == usageObjects atRest && usageResources now == usageResources atRest)

  it "loads the same content independently for two instances, and ending one leaves the other's texels" $
    within 90 . withLoaded env [("tiny.png", Png.asymmetric 8 4)] $ \comp vm → do
      one ← load comp vm "a" "k" "tiny.png"
      two ← load comp vm "b" "k" "tiny.png"
      one `shouldNotBe` two
      decoded ← decoded' (Png.asymmetric 8 4)
      first ← draw env one decoded
      shotFailed first `shouldBe` []
      -- The first instance ends; its texture is released and retires on the table's evidence.
      stopInstance comp vm "a"
      _ ← awaitFailure comp "a"
      ownerA ← ownerOf vm "a"
      atomically (ownerReading ownerA >>= \reading → if ownerSlotsHeld reading == 0 then pure () else retry)
      second ← draw env two decoded
      shotFailed second `shouldBe` []
      shotDeterminate second `shouldSatisfy` (> 20)
      release' env comp vm "b" "k"
      settleToRest env

  it "coordinates a delayed completion and a cancellation through the adapter seam, then drains the real native work" $
    within 90 . withLoadedOver env [("tiny.png", Png.asymmetric 8 4)] $ \gate comp vm → do
      atRest ← restNow env
      marks ← retainedEntries (graphicsTextures (envGraphics env))
      -- The real upload completes while the backend is told it has not: nothing may register.
      admit comp vm "a"
      commandLoad comp vm "a" "k" "tiny.png" False
      awaitRealUploads gate
      command comp vm "a" "cancel" "k"
      _ ← awaitNoteContaining comp "a cancel k"
      openGate gate
      -- The cancelled request's result is taken: the banks of a request that produced no texture return then.
      command comp vm "a" "wait_take" "k"
      taken ← awaitNoteContaining comp "a wait_take k"
      taken `shouldSatisfy` Text.isInfixOf "cancelled"
      owner ← ownerOf vm "a"
      atomically (ownerReading owner >>= \reading → if ownerSlotsHeld reading == 0 && ownerNominalHeld reading == 0 then pure () else retry)
      awaitUsage env (\now → usageBytes now == usageBytes atRest && usageObjects now == usageObjects atRest && usageResources now == usageResources atRest)
      retainedEntries (graphicsTextures (envGraphics env)) `shouldReturn` marks
      evidence env "a request cancelled while its completed upload was still hidden from the backend registered nothing and drained"

  it "returns the model's native accounting to what the session held at rest" $ do
    rest ← restNow env
    awaitUsage env (\now → usageBytes now == usageBytes rest && usageObjects now == usageObjects rest && usageResources now == usageResources rest)
    now ← usageNow env
    usageBytes now `shouldBe` usageBytes rest
    usageObjects now `shouldBe` usageObjects rest
    usageResources now `shouldBe` usageResources rest
    evidence env ("accounting at rest: " <> tshow (usageBytes now) <> " bytes, " <> tshow (usageObjects now) <> " objects, " <> tshow (usageResources now) <> " resources")

-- The seam ------------------------------------------------------------------------------------------------------

-- | A gate in front of the backend's reading of upload completion: the device finishes the upload, the
-- backend is told so only when the gate opens.
data Gate = Gate
  { gateOpen ∷ !(TVar Bool)
  , gateTickets ∷ !(TVar [UploadTicketOf])
  , gateReal ∷ !(Port Image' Ticket')
  }

type Image' = Image
type Ticket' = UploadTicket
type UploadTicketOf = UploadTicket

openGate ∷ Gate → IO ()
openGate gate = atomically (writeTVar (gateOpen gate) True)

-- | Wait until every upload admitted through the gate is complete on the device itself.
awaitRealUploads ∷ Gate → IO ()
awaitRealUploads gate = atomically $ do
  tickets ← readTVar (gateTickets gate)
  states ← traverse (portTicket (gateReal gate)) tickets
  unless (not (null tickets) && all (== TicketComplete) states) retry

-- Helpers --------------------------------------------------------------------------------------------------------

within ∷ Int → IO a → IO a
within seconds action =
  timeout (seconds * 1000000) action >>= \case
    Just value → pure value
    Nothing → assertFailure ("the example did not finish within " <> show seconds <> " seconds")

withLoaded ∷ Env → Files → (Composition → Vm → IO a) → IO a
withLoaded env files body =
  withComposition compositionProfile files (graphicsBackend (envGraphics env)) $ \comp _ runtime → do
    vm ← startVm comp runtime "native-vm"
    body comp vm

-- | A composition over a second backend that runs over the same session through a gated port.
withLoadedOver ∷ Env → Files → (Gate → Composition → Vm → IO a) → IO a
withLoadedOver env files body = do
  open ← newTVarIO False
  tickets ← newTVarIO []
  let real = graphicsPort (envGraphics env)
      gate = Gate open tickets real
      delayed =
        real
          { portUpload = \image bytes → do
              admitted ← portUpload real image bytes
              either (const (pure ())) (\ticket → atomically (modifyTVar' tickets (<> [ticket]))) admitted
              pure admitted
          , portTicket = \ticket → do
              state ← portTicket real ticket
              released ← readTVar open
              pure (if released || state /= TicketComplete then state else TicketUploading)
          }
  withBackend delayed $ \backend →
    withComposition compositionProfile files (textureBackend backend) $ \comp _ runtime → do
      vm ← startVm comp runtime "native-gated-vm"
      timeout 40000000 (body gate comp vm) >>= \case
        Just value → pure value
        Nothing → do
          seen ← notes comp
          reading ← atomically (readBackend backend)
          issued ← atomically (readTVar (gateTickets gate))
          states ← atomically (traverse (portTicket (gateReal gate)) issued)
          now ← usageNow env
          owners ← readIORef (vmOwners vm) >>= traverse (atomically . ownerReading) . Map.elems
          assertFailure ("the gated example did not finish; scripts recorded " <> show seen <> "; the backend read " <> show reading <> "; the real tickets read " <> show states <> "; accounting now " <> show now <> " against " <> show (envBaseline env) <> "; owners " <> show owners)

load ∷ Composition → Vm → Text → Text → Text → IO Integer
load comp vm who key path = loadWith comp vm who key path (\_ → pure ())

-- | Admit an instance, load this path and answer the texture's identity once the request reported success.
loadWith ∷ Composition → Vm → Text → Text → Text → (Text → IO ()) → IO Integer
loadWith comp vm who key path check = do
  admit comp vm who
  commandLoad comp vm who key path False
  command comp vm who "wait_take" key
  line ← awaitNoteContaining comp (who <> " wait_take " <> key)
  line `shouldSatisfy` Text.isInfixOf "status=success"
  check line
  command comp vm who "use" key
  used ← awaitNoteContaining comp (who <> " use " <> key)
  case Text.decimal (last (Text.words used)) of
    Right (identity, _) → pure identity
    Left reason → assertFailure ("the identity was not a number: " <> reason)

release' ∷ Env → Composition → Vm → Text → Text → IO ()
release' _ comp vm who key = do
  command comp vm who "release" key
  _ ← awaitNoteContaining comp (who <> " release " <> key)
  owner ← ownerOf vm who
  atomically (ownerReading owner >>= \reading → if ownerSlotsHeld reading == 0 then pure () else retry)

noWindows ∷ Env → IO ()
noWindows env = atomically (hostWindowIdentities (vulkanWindowHost (envHost env))) `shouldReturn` []

draw ∷ Env → Integer → DecodedImage → IO Shot
draw env identity decoded =
  shoot (envHost env) (graphicsRenderer (envGraphics env)) (textureHandleOf (fromIntegral identity)) decoded (Png.asymmetricTexel 8 4) >>= \case
    Left failure → assertFailure ("the frame failed: " <> Text.unpack failure)
    Right shot → pure shot

decoded' ∷ ByteString.ByteString → IO DecodedImage
decoded' bytes =
  case decodePng ColourImage (Asset (AssetId "native") (FromMemory "the fixture")) bytes of
    Left refusal → assertFailure ("the fixture was refused by the decoder: " <> show refusal)
    Right image → pure image

-- | Wait for the session's native accounting to come to rest, then record it as the standard later examples
-- return to. The first drawing leaves one thing behind that is not a leak: the renderer's pipeline for the
-- target's format, which it keeps for the session. Everything else a drawing made is released by now.
settleToRest ∷ Env → IO ()
settleToRest env = do
  awaitUsage env (\now → usageDeviceMemory now == usageDeviceMemory (envBaseline env))
  markRest env
  rest ← restNow env
  evidence env ("accounting at rest after the first drawing: " <> summarise rest <> " (the session began with " <> summarise (envBaseline env) <> ")")

-- | The accounting that matters here, in a line.
summarise ∷ Usage → Text
summarise now = tshow (usageBytes now) <> " bytes, " <> tshow (usageDeviceMemory now) <> " device bytes, " <> tshow (usageObjects now) <> " objects, " <> tshow (usageResources now) <> " resources"

evidence ∷ Env → Text → IO ()
evidence env line = atomically (modifyTVar' (envEvidence env) (line :))

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
