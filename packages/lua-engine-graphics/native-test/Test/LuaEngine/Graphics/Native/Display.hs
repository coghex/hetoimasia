{-# LANGUAGE OverloadedStrings #-}

-- | The test-only display adapter of the `Lua offscreen pixels` subgroup (LFE-24): the one thing the production
-- composition is run without, a native window as the final display target.
--
-- = The boundary
--
-- Everything else is the production path. Lua opens its window through the real facade and window provider; the provider
-- asks a 'Port' for the native window, and this module's 'Port' answers with a surface-free /offscreen scene target/
-- registered with the host through LFE-27's public interface ('registerVulkanSceneTarget'). That registration is the
-- substitution of the target. From it:
--
-- * Lua publishes through the production scene publisher ('scenePublisherOver') over the host's own transaction for a
--   registered offscreen target ('offscreenTargetAnswer', which is 'publishVulkanTargetScene'), composed with the
--   publisher's authority checks and the lease binding as a window's is.
-- * The host adopts the scene for the target, holds the scene's textures in the production ledger, and gates the
--   texture release on the target's scene barrier, all keyed by the target's 'SceneTargetKey'.
-- * The adapter /records/ the adopted scene only through 'recordVulkanTargetBatch', the host's recording boundary: the
--   batch is bound to the scene the host adopted and to the batch's own ticket before anything is recorded.
--
-- The adapter keeps no hold, no barrier, no ledger and no lifecycle of its own; it never calls the ledger's adopt or
-- release hooks. What it stores is identity bookkeeping the provider's port needs and nothing else: which creation
-- issued which target and which of them it has closed.
--
-- = What a rendering is
--
-- The production renderer ('renderGraphicsFrame') builds a frame with 'frameCandidate' and records it into a window's
-- swapchain image, which a frame-less batch cannot supply. So the adapter records, in a frame-less batch on the graphics
-- owner, the production 'frameCandidate' output for the adopted scene and the target's own 'FrameFacts', retargeted
-- /only in its pass target/ ('retargeted') to an offscreen reference that 'frameTarget' resolves to the managed RGBA8
-- sRGB colour target. The copy is checked, through 'validSnapshot', to equal the production candidate in every other
-- value. It adds no hook to render-2d-vulkan, the controller or the host.
--
-- The image is read back only after the batch's own ticket reports completion; neither the publication, nor a callback,
-- nor the end of the owner-thread action is taken as proof.
module Test.LuaEngine.Graphics.Native.Display
  ( -- * The display port
    Display
  , newDisplay
  , displayPort
  , displayTargets
  , displayUsable

    -- * Rendering a target
  , Rendered (..)
  , renderTarget

    -- * The host's reading of a target
  , targetStanding
  , awaitTarget
  ) where

import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , newTVarIO
  , readTVar
  , retry
  , writeTVar
  )
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, displayException, finally)
import Control.Monad (void)
import Data.Functor ((<&>))
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Numeric.Natural (Natural)

import qualified Hetoimasia.GPU.Vulkan.GLFW as G
import Hetoimasia.GPU.Vulkan.GLFW
  ( ActionOutcome (..)
  , BatchTicket
  , Construction
  , Image
  , Recorder
  , ImageDescription (..)
  , ImageFormat (Rgba8Srgb)
  , ImageKind (ColorTarget)
  , OffscreenTargetId
  , Refusal (..)
  , ResourceUse (..)
  , SceneTargetKey (..)
  , TicketState (..)
  , TransitionSource (..)
  , VulkanAction (..)
  , VulkanHost (..)
  , VulkanSceneState (..)
  , WindowSceneStanding (..)
  , awaitVulkanAction
  , constructImage
  , constructReadback
  , copyTargetToReadback
  , formatCode
  , readConstructedReadback
  , readTicket
  , readVulkanSceneState
  , recordVulkanTargetBatch
  , registerVulkanSceneTarget
  , releaseConstructed
  , submitVulkanAction
  , transitionResource
  , unregisterVulkanSceneTarget
  )
import Hetoimasia.LuaEngine.Graphics.Scene
import Hetoimasia.LuaEngine.Graphics.Texture
import Hetoimasia.LuaEngine.Graphics.Texture.Host (hostBuilders)
import Hetoimasia.LuaEngine.Graphics.Window.Port
import Hetoimasia.Render.TwoD.Metrics (TargetMetrics)
import Hetoimasia.Render.TwoD.Snapshot (Pass (..), Snapshot (..), Target (OffscreenTarget))
import Hetoimasia.Render.TwoD.Target.Backend (targetRef)
import Hetoimasia.Render.TwoD.Validation (ValidSnapshot, validSnapshot, validateSnapshot)
import qualified Hetoimasia.Render.TwoD.Vulkan as Render
import Hetoimasia.Render.TwoD.DrawPlan (CutoutMarks)
import Hetoimasia.Render.TwoD.Vulkan.Textures (registeredMarks)
import Hetoimasia.Runtime.GLFW (readOwnerFailure, wakeGraphicsHost)
import Test.LuaEngine.Graphics.Native.Session (Env (..))
import Test.LuaEngine.Graphics.Pixels (Readback (..), retargeted, sameExceptTarget)

-- The display port ------------------------------------------------------------------------------------------------------

-- | What the provider's port needs to know and the host does not: which creation issued which target, and which of the
-- targets have been closed. Never a hold of any texture or scene.
data Book = Book
  { bookNext :: !Word64
  , bookIssued :: !(Map.Map Word64 WindowToken)
  , bookTargets :: !(Map.Map WindowToken OffscreenTargetId)
  , bookClosed :: !(Map.Map WindowToken ())
  }

-- | The adapter: the provider's port, and a reading of the targets it made.
data Display = Display
  { displayBook :: !(TVar Book)
  , displayPort :: !(Port OffscreenTargetId)
  }

-- | A display over this host. Every window the provider asks for is a registered offscreen scene target, with no native
-- window and nothing opened.
newDisplay ∷ VulkanHost GraphicsScene → IO Display
newDisplay host = do
  var ← newTVarIO (Book 0 Map.empty Map.empty Map.empty)
  pure Display {displayBook = var, displayPort = portOver host var}

portOver ∷ VulkanHost GraphicsScene → TVar Book → Port OffscreenTargetId
portOver host var =
  Port
    { portIssueCreate = \_ _ _ →
        -- One transaction: the host's registration and this book's record of it are one step, so a target the host
        -- registered is never one nobody holds the identity of.
        atomically $
          registerVulkanSceneTarget host >>= \case
            Left refusal → pure (CreateFault (Fatal (Text.pack ("the host refused the offscreen target: " <> show refusal))))
            Right target → do
              book ← readTVar var
              let number = bookNext book
                  token = WindowToken number
              writeTVar
                var
                book
                  { bookNext = number + 1
                  , bookIssued = Map.insert number token (bookIssued book)
                  , bookTargets = Map.insert token target (bookTargets book)
                  }
              pure (CreateIssued (CreateToken number))
    , portCreateOutcome = \(CreateToken number) → do
        book ← readTVar var
        case Map.lookup number (bookIssued book) of
          Nothing → pure (Just (CreateFatal (Fatal "a creation was read that was never issued")))
          Just token → pure (Just (Created token))
    , portAttach = \_ → pure AttachAnnounced
    , portStanding = \token → do
        book ← readTVar var
        pure $ case Map.lookup token (bookTargets book) of
          Nothing → StandingPending
          Just _ | Map.member token (bookClosed book) → StandingEnded
          Just _ → StandingUsable
    , portCloseRequest = \_ → pure 0
    , portBeginClose = \token → atomically $ do
        book ← readTVar var
        case Map.lookup token (bookTargets book) of
          Nothing → pure CloseGone
          Just target
            | Map.member token (bookClosed book) → pure CloseBegun
            | otherwise → do
                void (unregisterVulkanSceneTarget host target)
                writeTVar var book {bookClosed = Map.insert token () (bookClosed book)}
                pure CloseBegun
    , portRetirement = \token → do
        book ← readTVar var
        case Map.lookup token (bookTargets book) of
          Nothing → pure (Retirement GraphicsRetired NativeDisposed)
          Just target
            | not (Map.member token (bookClosed book)) → pure (Retirement GraphicsInUse NativeDisposed)
            | otherwise → do
                -- The host's own reading: the target's record is gone once every revision it held was released.
                state ← readVulkanSceneState host
                pure (Retirement (if Map.member (KeyOffscreen target) (sceneWindows state) then GraphicsInUse else GraphicsRetired) NativeDisposed)
    , portTarget = \token → do
        book ← readTVar var
        pure $ case Map.lookup token (bookTargets book) of
          Just target | not (Map.member token (bookClosed book)) → Just target
          _ → Nothing
    , portOwnerFailure =
        readOwnerFailure (vulkanGraphicsOwner host)
          <&> fmap (\(ExceptionWithContext _ raised) → Fatal (Text.take 2048 (Text.pack (displayException (raised ∷ SomeException)))))
    , portQueueRoom = pure True
    , portWakeMain = wakeGraphicsHost (vulkanGraphicsOwner host)
    }

-- | The targets this display made and has not closed, oldest first.
displayTargets ∷ Display → STM [OffscreenTargetId]
displayTargets display = do
  book ← readTVar (displayBook display)
  pure [target | (token, target) ← Map.toList (bookTargets book), not (Map.member token (bookClosed book))]

-- | Whether this target is still the one the display made and has not closed.
displayUsable ∷ Display → OffscreenTargetId → STM Bool
displayUsable display target = elem target <$> displayTargets display

-- Reading the host ------------------------------------------------------------------------------------------------------

-- | The host's standing of a target, if it holds a record of it.
targetStanding ∷ VulkanHost scene → OffscreenTargetId → STM (Maybe WindowSceneStanding)
targetStanding host target = Map.lookup (KeyOffscreen target) . sceneWindows <$> readVulkanSceneState host

-- | Block, in STM, until the host's standing of the target satisfies the condition.
awaitTarget ∷ VulkanHost scene → OffscreenTargetId → (WindowSceneStanding → Bool) → IO ()
awaitTarget host target ok = atomically $ do
  standing ← targetStanding host target
  case standing of
    Just found | ok found → pure ()
    _ → retry

-- Rendering ------------------------------------------------------------------------------------------------------------

-- | What a recording hands back with its ticket: the revision and scene the host adopted, the production candidate and its
-- validation, the marks the frame was planned with, and how the retargeted copy differs from the candidate, if it does.
type Info = (Natural, GraphicsScene, Snapshot, ValidSnapshot, CutoutMarks, [Text])

-- | One rendering of an adopted scene: the evidence linking the image to its publication.
data Rendered = Rendered
  { renderedRevision :: !Natural
    -- ^ The revision of the scene the host adopted for the target and the batch read.
  , renderedScene :: !GraphicsScene
    -- ^ The exact scene the host handed the recording boundary.
  , renderedFacts :: !FrameFacts
  , renderedMetrics :: !TargetMetrics
  , renderedCandidate :: !Snapshot
    -- ^ The production 'frameCandidate' output: the published window-pass scene.
  , renderedValid :: !ValidSnapshot
  , renderedMarks :: !CutoutMarks
    -- ^ The cutout marks the registry gave the textures the frame was planned with.
  , renderedCopyFaults :: ![Text]
    -- ^ How the retargeted copy differs from the candidate other than in its target, if it does.
  , renderedReadback :: !Readback
  , renderedCompletion :: !Text
    -- ^ The ticket evidence the readback waited for.
  }

-- | Render the scene the host adopted for the target, once, with these facts: record one frame-less batch through the
-- host's recording boundary, run an action once the batch is recorded and before its completion is awaited, wait for
-- the batch's own ticket to report completion, and only then read the managed readback back. The managed target and
-- readback are released on every way out, after the batch's ticket has settled.
renderTarget ∷ Env → OffscreenTargetId → FrameFacts → IO () → IO (Either Text Rendered)
renderTarget env target facts between =
  case frameMetrics facts of
    Left skip → pure (Left ("the facts are not usable metrics: " <> tshow skip))
    Right metrics → do
      let (width, height) = factsFramebuffer facts
          bytesWanted = fromIntegral width * fromIntegral height * 4 ∷ Natural
      made ← act "making the target and the readback" $ VulkanAction $ \construction → do
        image ← constructImage construction (ImageDescription ColorTarget Rgba8Srgb width height 1)
        readback ← constructReadback construction bytesWanted
        pure ((,) <$> image <*> readback)
      case made of
        Left failure → pure (Left failure)
        Right (image, readback) → do
          ticketRef ← newIORef Nothing
          cleanupRef ← newIORef Nothing
          let body = do
                recorded ← recordOnce ticketRef image readback metrics
                case recorded of
                  Left failure → pure (Left failure)
                  Right (ticket, info) → do
                    between
                    completion ← awaitSettled ticket
                    case completion of
                      TicketComplete → do
                        bytes ← act "reading the readback" $ VulkanAction $ \construction → readConstructedReadback construction readback 0 bytesWanted
                        pure (bytes >>= \found → Right (finish info metrics (Readback (fromIntegral width) (fromIntegral height) found) "the batch's ticket reported complete before the readback was read"))
                      other → pure (Left ("the batch did not complete: its ticket read " <> tshow other))
              -- Run on every way out, masked: the batch's ticket has settled before the target and the readback are
              -- released, and a release that fails is recorded where it fails, not dropped.
              cleanup = do
                readIORef ticketRef >>= mapM_ (void . awaitSettled)
                released ← act "releasing the target and the readback" $ VulkanAction $ \construction → do
                  first ← releaseConstructed construction image
                  second ← releaseConstructed construction readback
                  pure (first *> second)
                either (writeIORef cleanupRef . Just) pure released
          outcome ← body `finally` cleanup
          cleaned ← readIORef cleanupRef
          pure $ case (outcome, cleaned) of
            (_, Nothing) → outcome
            (Right _, Just why) → Left ("the cleanup failed: " <> why)
            (Left failure, Just why) → Left (failure <> "; and the cleanup failed: " <> why)
  where
    host = envHost env
    graphics = envGraphics env
    tshow ∷ Show a ⇒ a → Text
    tshow = Text.pack . show

    recordOnce ticketRef image readback metrics =
      act "recording the adopted scene" $ VulkanAction $ \construction →
        recordVulkanTargetBatch host target construction (\scene revision recorder → record construction scene revision image readback metrics recorder) >>= \case
          Left refusal → pure (Left (RefusedIllegal ("the host refused the recording: " <> tshow refusal)))
          Right (ticket, Left failure) → pure (Left (RefusedIllegal failure)) <* keep ticketRef ticket
          Right (ticket, Right info) → keep ticketRef ticket >> pure (Right (ticket, info))

    keep ticketRef ticket = writeIORef ticketRef (Just ticket)

    -- The recording itself, on the owner's thread, inside the host's boundary.
    record
      ∷ ∀ q inst msgr phys dev cmd
      . Construction q inst msgr phys dev cmd
      → GraphicsScene
      → Natural
      → Image
      → G.Readback
      → TargetMetrics
      → Recorder q inst msgr phys dev cmd
      → IO (Either Text Info)
    record construction scene revision image readback metrics recorder =
      case frameCandidate scene facts of
        Left skip → pure (Left ("the adopted scene has no frame for these facts: " <> tshow skip))
        Right (candidate, valid) → do
          let reference = targetRef 1 1
              copy = retargeted reference candidate
          case validateSnapshot copy of
            Left refused → pure (Left ("the retargeted copy was refused: " <> tshow refused))
            Right validCopy → do
              marks ← registeredMarks (graphicsTextures graphics)
              let faults =
                    [ "the retargeted copy differs from the production candidate in more than its pass target"
                    | not (sameExceptTarget candidate (validSnapshot validCopy))
                    ]
                      <> [ "the retargeted copy does not draw into the offscreen reference" | map passTarget (snapshotPasses (validSnapshot validCopy)) /= [OffscreenTarget reference] ]
                  (width, height) = factsFramebuffer facts
                  input =
                    Render.FrameInput
                      { Render.frameSnapshot = validCopy
                      , Render.frameMarks = marks
                      , Render.frameTarget = \found →
                          if found == reference
                            then Just (Render.TargetBinding image (Render.Attachment (formatCode Rgba8Srgb) width height metrics) Nothing)
                            else Nothing
                      , Render.frameWindow = Nothing
                      , Render.frameWindowDepth = Nothing
                      , Render.frameChunks = const Nothing
                      , Render.frameOmitted = mempty
                      }
              Render.prepareSnapshot (hostBuilders host construction) (graphicsRenderer graphics) input >>= \case
                Left refusal → pure (Left ("the renderer refused the copy: " <> tshow refusal))
                Right recording →
                  recording recorder >>= \case
                    Left refusal → pure (Left ("recording the copy was refused: " <> tshow refusal))
                    Right () →
                      inOrder
                        [ transitionResource recorder image (FromUse ColorAttachment) TransferRead
                        , copyTargetToReadback recorder image readback
                        , transitionResource recorder image (FromUse TransferRead) ColorAttachment
                        ]
                        <&> \case
                          Left refusal → Left ("the transfer was refused: " <> tshow refusal)
                          Right () → Right (revision, scene, candidate, valid, marks, faults)

    finish ∷ Info → TargetMetrics → Readback → Text → Rendered
    finish (revision, scene, candidate, valid, marks, faults) metrics readback completion =
      Rendered
        { renderedRevision = revision
        , renderedScene = scene
        , renderedFacts = facts
        , renderedMetrics = metrics
        , renderedCandidate = candidate
        , renderedValid = valid
        , renderedMarks = marks
        , renderedCopyFaults = faults
        , renderedReadback = readback
        , renderedCompletion = completion
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

-- | Wait, in STM, until a batch's ticket is no longer pending: complete, discarded or lost.
awaitSettled ∷ BatchTicket → IO TicketState
awaitSettled ticket = atomically $ do
  state ← readTicket ticket
  case state of
    TicketPending → retry
    other → pure other

inOrder ∷ [IO (Either Refusal ())] → IO (Either Refusal ())
inOrder = \case
  [] → pure (Right ())
  step : rest → step >>= either (pure . Left) (const (inOrder rest))
