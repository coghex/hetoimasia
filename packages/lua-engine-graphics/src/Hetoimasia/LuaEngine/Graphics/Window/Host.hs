-- | The production window 'Port' (LFE-18), over a running 'VulkanHost'.
--
-- Everything native stays the host's. This module issues ordinary commands through the window host's
-- bounded command port, hands a created window to the graphics owner on the process main thread, and
-- reads facts the host and the owner already publish. It adds no native operation of its own, holds no
-- raw native pointer and gives the instance-facing interface no control, input reader or disposal
-- authority: the only capability a ready window yields is 'WindowTarget', the narrow right to publish a
-- scene to /that/ window's incarnation.
--
-- = What each fact is read from
--
-- * /Created/: the creation command's ticket settled as @WindowCreated@ and handed over the window's
--   client. The host registers the window before the ticket settles, so a ticket nobody collected never
--   makes an untracked window; the provider keeps the token from the moment the command was issued.
-- * /Admitted/: the owner's own answer for the attachment (@readTargetStanding@), never the handover.
--   @VulkanTargetHandedOver@, an attachment, a deferred announcement and an allocated surface are not
--   success.
-- * /A genuine close request/: the newest 'observedCloseRequest' in the window's own observations.
--   Only the native close callback produces one; the closing phase, the end and a close the provider
--   begins never do.
-- * /Retired/: graphics from the attachment's own observation (@SlotFree@), native from the window's
--   terminal phase (@WindowReleased@); a release that failed is reported as failed and is the
--   provider's to keep.
--
-- = State
--
-- One 'HostState' per port, written by transactions only: the creation tickets issued and not yet
-- collected, the windows made (each with its client, its service once handed over and its close
-- ticket). It is bounded by the provider's slots, and entries are never reissued.
module Hetoimasia.LuaEngine.Graphics.Window.Host
  ( -- * The port
    hostPort

    -- * The capability a ready window yields
  , WindowTarget (..)
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
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, displayException)
import Control.Monad (when)
import Data.Functor ((<&>))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Numeric.Natural (Natural)
import Hetoimasia.Foundation.Messaging.Payload (Prepared, preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (observedValue, readSnapshot)
import Hetoimasia.GLFW.Command
  ( CommandRejection (..)
  , CommandResult (..)
  , CompletionTicket
  , Disposition (..)
  , SubmitResult (..)
  , WindowClient
  , WindowCommandPort
  , clientObservations
  , closeWindowCommand
  , createWindowCommand
  , pollCompletion
  , pollWindowClient
  , submitWindowCommand
  )
import Hetoimasia.GLFW.Window
  ( WindowId
  , WindowPhase (..)
  , closeRequestNumber
  , defaultWindowConfig
  , observedCloseRequest
  , observedPhase
  )
import Hetoimasia.GPU.Model.Identity (TargetClass (RequiredTarget))
import Hetoimasia.GPU.Vulkan.GLFW
  ( VulkanHandover (..)
  , VulkanHost (..)
  , VulkanRejection (..)
  , announceVulkanTarget
  , handOverVulkanTarget
  , publishVulkanWindowScene
  , readTargetRejection
  )
import Hetoimasia.GPU.Vulkan.Native.Profile (TargetRejection (..))
import Hetoimasia.LuaEngine.Graphics.Window.Port
import Hetoimasia.Runtime.GLFW
  ( AttachmentId
  , EventAdmission (..)
  , GraphicsObservation (..)
  , GraphicsRefusal (..)
  , GraphicsService
  , NativeDisposal (..)
  , RollbackOutcome (..)
  , RolledBack (..)
  , SlotState (..)
  , TargetStanding (..)
  , WindowGraphics (..)
  , WindowScenePublication
  , graphicsAttachment
  , hostCommandPort
  , hostCommandStatistics
  , readGraphicsService
  , readOwnerFailure
  , readTargetStanding
  , wakeGraphicsHost
  , windowGraphicsStatus
  )

-- | The right to publish a scene to one window's incarnation, and to ask whether that incarnation is
-- still the usable one. It carries no native control, input reader or disposal authority.
data WindowTarget scene = WindowTarget
  { targetWindow ∷ !WindowId
  , targetAttachment ∷ !AttachmentId
  , targetPublish ∷ Prepared scene → IO WindowScenePublication
    -- ^ Publish an owned scene to this window alone; it asks this window's target for a frame and no
    -- other's, and promises no displayed frame.
  , targetUsable ∷ STM Bool
    -- ^ Whether this incarnation's target is still the admitted, attached one.
  }

-- The state ------------------------------------------------------------------------------------------

data Made = Made
  { madeWindow ∷ !WindowId
  , madeClient ∷ !WindowClient
  , madeService ∷ !(Maybe GraphicsService)
  , madeClose ∷ !(Maybe CompletionTicket)
  }

data HostState = HostState
  { hsNext ∷ !Word64
  , hsCreates ∷ !(Map Word64 CompletionTicket)
  , hsTokens ∷ !(Map Word64 WindowToken)
    -- ^ The window made for each create token that has settled, so reading an outcome twice never makes
    -- a second token.
  , hsMade ∷ !(Map WindowToken Made)
  }

-- | A port over this host. Create it once per session; it is read and written from the provider's pump
-- and from the process main thread, by transactions.
hostPort ∷ ∀ scene. VulkanHost scene → IO (Port (WindowTarget scene))
hostPort vulkan = do
  var ← newTVarIO (HostState 0 Map.empty Map.empty Map.empty)
  let commands = hostCommandPort (vulkanWindowHost vulkan)
  pure
    Port
      { portIssueCreate = \title width height →
          submitWindowCommand commands [("client", "lua-window")] (createWindowCommand (defaultWindowConfig title width height)) >>= \case
            SubmitAccepted ticket → atomically $ do
              st ← readTVar var
              writeTVar var st {hsNext = hsNext st + 1, hsCreates = Map.insert (hsNext st) ticket (hsCreates st)}
              pure (CreateIssued (CreateToken (hsNext st)))
            SubmitFull → pure CreateQueueFull
            SubmitClosed → pure CreateClosed
      , portCreateOutcome = \(CreateToken number) → createOutcome var number
      , portAttach = attach vulkan var
      , portStanding = standing vulkan var
      , portCloseRequest = \token → closeRequested var token
      , portBeginClose = beginClose commands var
      , portRetirement = retirement vulkan var
      , portTarget = target vulkan var
      , portOwnerFailure = ownerFailure vulkan
      , portProgress = do
          before ← hostCommandStatistics (vulkanWindowHost vulkan)
          pure $ do
            now ← hostCommandStatistics (vulkanWindowHost vulkan)
            when (now == before) retry
      , portWakeMain = wakeGraphicsHost (vulkanGraphicsOwner vulkan)
      }

-- Creation -------------------------------------------------------------------------------------------

createOutcome ∷ TVar HostState → Word64 → STM (Maybe CreateOutcome)
createOutcome var number = do
  st ← readTVar var
  case Map.lookup number (hsCreates st) of
    Nothing → pure (Just (CreateFatal (Fatal "a creation was read that was never issued")))
    Just ticket →
      pollCompletion ticket >>= \case
        Nothing → pure Nothing
        Just disposition → case disposition of
          Performed (WindowCreated window) → case Map.lookup number (hsTokens st) of
            Just token → pure (Just (Created token))
            Nothing →
              pollWindowClient ticket >>= \case
                Nothing → pure (Just (CreateFatal (Fatal "a window was created without its client")))
                Just client → do
                  let token = WindowToken (hsNext st)
                  writeTVar
                    var
                    st
                      { hsNext = hsNext st + 1
                      , hsTokens = Map.insert number token (hsTokens st)
                      , hsMade = Map.insert token (Made window client Nothing Nothing) (hsMade st)
                      }
                  pure (Just (Created token))
          -- Clean and verified: the host rolled back exactly what it acquired and consumed no capacity.
          Rejected (WindowCreationFailed {}) → pure (Just (CreateRefusedClean "the window could not be created"))
          NotExecuted → pure (Just CreateNotExecuted)
          Rejected rejection → pure (Just (CreateFatal (Fatal (bounded ("a window creation was rejected: " <> Text.pack (show rejection))))))
          Interrupted request → pure (Just (CreateFatal (Fatal (bounded ("a window creation was interrupted: " <> Text.pack (show request))))))
          other → pure (Just (CreateFatal (Fatal (bounded ("a window creation settled unexpectedly: " <> Text.pack (show other))))))

-- Attachment (main thread) ---------------------------------------------------------------------------

attach ∷ VulkanHost scene → TVar HostState → WindowToken → IO AttachOutcome
attach vulkan var token = do
  found ← atomically (Map.lookup token . hsMade <$> readTVar var)
  case found of
    Nothing → pure (AttachFault (Fatal "a window was attached that was never made"))
    Just made -> case madeService made of
      -- A deferred announcement is announced again on the same attachment: no second surface or window.
      Just service →
        announceVulkanTarget vulkan service >>= \case
          EventAdmitted → pure AttachAnnounced
          EventRefusedFull → pure AttachDeferred
          EventPortClosed → pure AttachEnded
      Nothing →
        handOverVulkanTarget vulkan (madeWindow made) RequiredTarget >>= \case
          VulkanTargetHandedOver service → keep service >> pure AttachAnnounced
          VulkanAnnouncementDeferred service → keep service >> pure AttachDeferred
          VulkanRootsNotReady _ → pure AttachRootsPending
          VulkanOwnerClosed _ → pure AttachEnded
          VulkanHandoverSuperseded _ → pure AttachEnded
          VulkanHandoverRefused refusal -> pure (refused refusal)
          VulkanHandoverRolledBack rolled
            | rolledBackOutcome rolled == RollbackSafe → pure (AttachRefusedClean "the window's graphics setup was refused and rolled back")
            | otherwise → pure (AttachFault (Fatal "a window's graphics setup could not be rolled back safely"))
          VulkanHandoverUnavailable why → pure (AttachFault (Fatal (bounded ("the host cannot attach windows: " <> why))))
          VulkanSessionFailed _ → pure (AttachFault (Fatal "the graphics session has failed"))
          VulkanDiagnosticPending → pure (AttachFault (Fatal "a graphics diagnostic failure is pending"))
  where
    keep service = atomically $ do
      st ← readTVar var
      writeTVar var st {hsMade = Map.adjust (\made → made {madeService = Just service}) token (hsMade st)}
    -- The refusals of the host's own reservation. Closing and unavailable windows are this adapter's own
    -- cleanup or the session's stop; the rest are fatal after the adapter's own validation.
    refused = \case
      GraphicsAdmissionEnded → AttachEnded
      GraphicsWindowClosing _ → AttachEnded
      GraphicsWindowUnavailable _ → AttachEnded
      other → AttachFault (Fatal (bounded ("the host refused a window's attachment: " <> Text.pack (show other))))

-- Standing -------------------------------------------------------------------------------------------

standing ∷ VulkanHost scene → TVar HostState → WindowToken → STM Standing
standing vulkan var token = do
  found ← Map.lookup token . hsMade <$> readTVar var
  case found >>= madeService of
    Nothing → pure StandingPending
    Just service → do
      let attachment = graphicsAttachment service
      graphics ← readGraphicsService service
      readTargetStanding (vulkanGraphicsOwner vulkan) attachment >>= \case
        Nothing → pure StandingPending
        Just TargetConstructing → pure StandingPending
        Just TargetUsable → pure $ case observedSlot graphics of
          SlotAttached → StandingUsable
          _ → StandingEnded
        Just (TargetUnusable True) → pure (StandingFatal (Fatal "a window's target construction was partial or unverified"))
        Just (TargetUnusable False) →
          readTargetRejection (vulkanController vulkan) attachment >>= \case
            Just (RejectedByRoots (TargetSurfaceUnsupported _)) → pure (StandingRefusedClean "the window's surface cannot be presented to by this session")
            Just (SurfaceNotCreated _) → pure (StandingRefusedClean "the window's surface could not be created")
            Just (SurfaceUnusable _) → pure (StandingRefusedClean "the window's surface could not be used")
            Just (RejectedByRoots TargetAdmissionClosed) → pure StandingEnded
            Just SurfaceNotHandedOver → pure StandingEnded
            Just other → pure (StandingFatal (Fatal (bounded ("a window's target was refused: " <> Text.pack (show other)))))
            Nothing → pure (StandingFatal (Fatal "a window's target was rolled back with no recorded reason"))

target ∷ ∀ scene. VulkanHost scene → TVar HostState → WindowToken → STM (Maybe (WindowTarget scene))
target vulkan var token = do
  found ← Map.lookup token . hsMade <$> readTVar var
  case found of
    Just made | Just service ← madeService made → do
      current ← standing vulkan var token
      pure $ case current of
        StandingUsable →
          Just
            WindowTarget
              { targetWindow = madeWindow made
              , targetAttachment = graphicsAttachment service
              , targetPublish = publishVulkanWindowScene vulkan (madeWindow made)
              , targetUsable = (== StandingUsable) <$> standing vulkan var token
              }
        _ → Nothing
    _ → pure Nothing

-- Close ----------------------------------------------------------------------------------------------

closeRequested ∷ TVar HostState → WindowToken → STM Natural
closeRequested var token = do
  found ← Map.lookup token . hsMade <$> readTVar var
  case found of
    Nothing → pure 0
    Just made → do
      observation ← preparedValue . observedValue <$> readSnapshot (clientObservations (madeClient made))
      pure (maybe 0 closeRequestNumber (observedCloseRequest observation))

beginClose ∷ WindowCommandPort → TVar HostState → WindowToken → IO CloseBegin
beginClose commands var token = do
  found ← atomically (Map.lookup token . hsMade <$> readTVar var)
  case found of
    Nothing → pure CloseGone
    Just made
      | Just _ ← madeClose made → pure CloseBegun
      | otherwise →
          submitWindowCommand commands [("client", "lua-window")] (closeWindowCommand (madeWindow made)) >>= \case
            SubmitAccepted ticket → do
              atomically $ do
                st ← readTVar var
                writeTVar var st {hsMade = Map.adjust (\now → now {madeClose = Just ticket}) token (hsMade st)}
              pure CloseBegun
            SubmitFull → pure CloseQueueFull
            SubmitClosed → pure CloseGone

-- Retirement -----------------------------------------------------------------------------------------

retirement ∷ VulkanHost scene → TVar HostState → WindowToken → STM Retirement
retirement vulkan var token = do
  found ← Map.lookup token . hsMade <$> readTVar var
  case found of
    Nothing → pure (Retirement GraphicsRetired NativeDisposed)
    Just made → do
      observation ← preparedValue . observedValue <$> readSnapshot (clientObservations (madeClient made))
      graphics ← case madeService made of
        Just service → graphicsOf <$> readGraphicsService service
        Nothing →
          windowGraphicsStatus (vulkanWindowHost vulkan) (madeWindow made) <&> \case
            GraphicsPresent present → graphicsOf present
            _ → GraphicsRetired
      let native = case observedPhase observation of
            WindowReleased → NativeDisposed
            WindowDisposalFailed → NativeDisposalFailed (Fatal "a window's disposal failed")
            WindowReleaseUncertain → NativeDisposalFailed (Fatal "a window's release could not establish that it ended safely")
            _ → NativePending
      closeFault ← case madeClose made of
        Nothing → pure Nothing
        Just ticket → pollCompletion ticket <&> \case
          Just (Interrupted request) → Just (Fatal (bounded ("a window's close was interrupted: " <> Text.pack (show request))))
          Just (Rejected rejection) | fatalClose rejection → Just (Fatal (bounded ("a window's close was rejected: " <> Text.pack (show rejection))))
          _ → Nothing
      pure $ case closeFault of
        Just found' → Retirement (GraphicsRetireFailed found') native
        Nothing → Retirement graphics native
  where
    graphicsOf present = case (observedSlot present, observedDisposal present) of
      (SlotFree, _) → GraphicsRetired
      (_, DisposalFailed) → GraphicsRetireFailed (Fatal "a window's graphics disposal failed")
      _ → GraphicsInUse
    -- Beginning a close twice, a window already gone and a window already closing are the protocol's
    -- idempotent answers; anything else is the executor refusing a close it should have performed.
    fatalClose = \case
      WindowIsClosing _ → False
      WindowAlreadyEnded _ → False
      WindowNotServed _ → False
      _ → True

-- The owner ------------------------------------------------------------------------------------------

ownerFailure ∷ VulkanHost scene → STM (Maybe Fatal)
ownerFailure vulkan =
  readOwnerFailure (vulkanGraphicsOwner vulkan) <&> fmap (\(ExceptionWithContext _ raised) → Fatal (bounded (Text.pack (describe raised))))
  where
    describe ∷ SomeException → String
    describe = displayException

bounded ∷ Text → Text
bounded = Text.take 2048
