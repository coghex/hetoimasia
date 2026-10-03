-- | The windows a host holds: registration, borrowing, and the close protocol.
--
-- Every operation that touches a window runs on the process main thread, the
-- session's owner; the public ones refuse other threads with
-- 'Hetoimasia.GLFW.Session.NotSessionOwner'. The registry and the collection
-- member behind each window are the host's, in
-- "Hetoimasia.Runtime.GLFW.Internal.Host.State"; a window leaves the registry
-- only here, once its close protocol has retired it. The STM readers answer on
-- any thread.
module Hetoimasia.Runtime.GLFW.Internal.Host.Windows
  ( -- * Reading the registry
    hostWindowIdentities
  , hostWindowClient
  , hostWindowClosing

    -- * Borrowing
  , withHostWindow
  , borrowWindow
  , withholdBeforeHide

    -- * Registration
  , registerWindow

    -- * The close protocol
  , CloseStart (..)
  , closeHostWindow
  , honourHostCloseRequest
  , rejectHostCloseRequest
  , beginClose
  , closeEntryAdmission
  , retirePending
  , latestCloseRequest
  ) where

import Control.Concurrent.STM (STM, atomically, modifyTVar', readTVar, readTVarIO, writeTVar)
import Control.Exception (ExceptionWithContext, SomeException, bracket_, rethrowIO, tryWithContext)
import Control.Monad (forM_, void, when)
import Data.IORef (modifyIORef', readIORef)
import qualified Data.Map.Strict as Map
import Hetoimasia.Foundation.Failure (Operation, operation)
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (observedValue, readSnapshot)
import Hetoimasia.Foundation.Resource.Collection
  ( MemberStatus (..)
  , Retirement (..)
  , acquireMemberThen
  , memberStatus
  , retireMember
  , withMember
  )
import Hetoimasia.GLFW.Command (WindowClient, closeWindowCommands)
import Hetoimasia.GLFW.Internal.Command (commandHostNotifier, commandsAdmissionClosed, newWindowClient, newWindowPortHost)
import Hetoimasia.GLFW.Internal.Demand (closeDemandSlot, demandPublisher, newDemandSlot)
import Hetoimasia.GLFW.Internal.Input (closeInputFeed, feedControl, feedReader, newInputFeed)
import Hetoimasia.GLFW.Internal.Session (ownerOperation)
import Hetoimasia.GLFW.Internal.Window
  ( attachWindowInputFeed
  , beginWindowClosing
  , guardWindowHide
  , reconcileWindowEvents
  , rejectCloseRequest
  , windowAssembly
  )
import Hetoimasia.GLFW.Window
  ( Attribute (Observed)
  , CloseRequest
  , Window
  , WindowConfig
  , WindowId
  , WindowResult (..)
  , closeRequestWindow
  , observedCloseRequest
  , observedFocused
  , windowIdentity
  , windowObservations
  )
import Hetoimasia.Runtime.GLFW.Internal.Graphics (NativeDisposal (..), SlotState (..), writeGraphicsDisposal, writeGraphicsSlot)
import Hetoimasia.Runtime.GLFW.Internal.Host.Config (HostConfig (..))
import Hetoimasia.Runtime.GLFW.Internal.Host.Progress (markRetirementImmediate, refreshGraphicsCells)
import Hetoimasia.Runtime.GLFW.Internal.Host.State (HostEntry (..), HostHooks (..), WindowHost (..), windowIdentifiers)
import Hetoimasia.Runtime.GLFW.Internal.Retirement
  ( AttachmentProtocol (..)
  , forgetRetiredWindow
  , recordClosingWindow
  , recordRegisteredWindow
  , windowAttachmentProtocol
  , windowRetirementVeto
  )

rejectOperation, borrowOperation, closeOperation, honourOperation ∷ Operation
rejectOperation = operation "reject close request"
borrowOperation = operation "borrow host window"
closeOperation = operation "close host window"
honourOperation = operation "honour close request"

-- | The identities of the windows the host holds, in registration order: every
-- window created and not yet retired, closing ones included. Any thread may
-- read it; it is bounded by the live-window limit.
hostWindowIdentities ∷ WindowHost → STM [WindowId]
hostWindowIdentities host = Map.keys <$> readTVar (hostEntries host)

-- | The client capabilities of a window the host holds: its own command port
-- and its read-only observations. 'Nothing' once the window has been retired,
-- or for an identity the host never held.
hostWindowClient ∷ WindowHost → WindowId → STM (Maybe WindowClient)
hostWindowClient host target = fmap entryClient . Map.lookup target <$> readTVar (hostEntries host)

-- | Lend a window the host holds to an owner-thread callback, closing or not.
-- A window already retired, or never held, answers 'WindowEnded' without
-- running the callback.
--
-- The window must not escape the callback. While it runs, the window cannot be
-- retired: a close protocol begun meanwhile defers retirement until every
-- borrow has ended. Refuses other threads with
-- 'Hetoimasia.GLFW.Session.NotSessionOwner'.
--
-- A hide made through the lent window — 'Hetoimasia.GLFW.Command.performWindowCommand'
-- with 'Hetoimasia.GLFW.Command.hideWindowCommand', or any other control route
-- — withholds the presentation of the window's graphics attachment before its
-- native call, as a hide through the host's ports does ('withholdBeforeHide',
-- #368). The attachment is the one occupying the window's slot when the hide
-- is about to be made, whatever its phase, so a window detached or reattached
-- while lent is protected by the attachment it has then.
withHostWindow ∷ WindowHost → WindowId → (Window → IO r) → IO (WindowResult r)
withHostWindow host target action =
  ownerOperation (hostSession host) borrowOperation (windowIdentifiers target) $
    readTVarIO (hostEntries host) >>= \entries → case Map.lookup target entries of
      Nothing → pure (WindowEnded target)
      Just entry → WindowAvailable <$> borrowWindow host target entry (action . guarded)
  where
    guarded = guardWindowHide (void (withholdBeforeHide host target))

-- | Have the graphics attachment occupying a window's slot, if any, withhold
-- its presentation before the window is hidden natively, on the owner thread,
-- and answer the action that lifts that hold again for a hide that made no
-- native call. The hold outlives the native call: the owner presents to the
-- window again only once an observation newer than the one it had when the
-- hold began is published, and the hidden window's is (#357). A window with no
-- attachment, and every window of an ordinary host, hold nothing, and the
-- answer lifts nothing.
withholdBeforeHide ∷ WindowHost → WindowId → IO (IO ())
withholdBeforeHide host target = case hostRetirementState host of
  Nothing → pure (pure ())
  Just retirement →
    atomically (windowAttachmentProtocol retirement target) >>= \case
      Nothing → pure (pure ())
      Just (attachment, protocol) → protocolBeforeHide protocol attachment

borrowWindow ∷ WindowHost → WindowId → HostEntry → (Window → IO r) → IO r
borrowWindow host target entry action =
  bracket_
    (modifyIORef' (hostBorrowed host) (Map.insertWith (+) target 1))
    (modifyIORef' (hostBorrowed host) (Map.update (\count → if count > 1 then Just (count - 1) else Nothing) target))
    (withMember (hostCollection host) (entryMember entry) action)

-- | Whether a window the host holds has begun closing; 'Nothing' for one it
-- does not hold. Any thread may read it.
hostWindowClosing ∷ WindowHost → WindowId → STM (Maybe Bool)
hostWindowClosing host target = fmap entryClosing . Map.lookup target <$> readTVar (hostEntries host)

-- | How a request to begin a window's close protocol was answered.
data CloseStart
  = CloseStarted
    -- ^ The protocol began now.
  | CloseAlreadyStarted
    -- ^ The window was already closing; nothing changed.
  | CloseNotServed
    -- ^ The host holds no window with this identity; nothing changed.
  | CloseRequestSuperseded
    -- ^ The close request is no longer the window's latest; nothing changed.
  deriving (Eq, Show)

-- | Begin a window's close protocol on the owner thread, as a close command
-- does. Refuses other threads with 'Hetoimasia.GLFW.Session.NotSessionOwner'.
closeHostWindow ∷ WindowHost → WindowId → IO CloseStart
closeHostWindow host target =
  ownerOperation (hostSession host) closeOperation (windowIdentifiers target) (beginClose host target)

-- | Honour a surfaced close request on the owner thread: begin its window's
-- close protocol if the request is still that window's latest, after
-- reconciling what its callbacks captured. Refuses other threads with
-- 'Hetoimasia.GLFW.Session.NotSessionOwner'.
honourHostCloseRequest ∷ WindowHost → CloseRequest → IO CloseStart
honourHostCloseRequest host request =
  ownerOperation (hostSession host) honourOperation (windowIdentifiers target) $
    readTVarIO (hostEntries host) >>= \entries → case Map.lookup target entries of
      Nothing → pure CloseNotServed
      Just entry
        | entryClosing entry → pure CloseAlreadyStarted
        | otherwise → do
            latest ←
              borrowWindow host target entry $ \window →
                reconcileWindowEvents window >>= \case
                  WindowEnded _ → pure Nothing
                  WindowAvailable () → latestCloseRequest window
            if latest == Just request then beginClose host target else pure CloseRequestSuperseded
  where
    target = closeRequestWindow request

-- | The close protocol, on the owner thread:
--
-- 1. the window's closing observation is prepared, and nothing has changed yet;
-- 2. in one transaction, masked and with nothing interruptible after it, the
--    window is marked closing, its port's admission closes, its queued commands
--    settle as not executed, its input feed closes without awaiting any
--    acknowledgement, and the 'Hetoimasia.GLFW.Window.WindowClosing'
--    phase is published, so a cancellation can never leave the port closed
--    with the phase unpublished, or the reverse;
-- 3. it is retired through the collection, unless it or another window is
--    borrowed, in which case a later turn retries.
beginClose ∷ WindowHost → WindowId → IO CloseStart
beginClose host target =
  Map.lookup target <$> readTVarIO (hostEntries host) >>= \case
    Nothing → pure CloseNotServed
    Just entry
      | entryClosing entry → pure CloseAlreadyStarted
      | otherwise →
          borrowWindow host target entry (beginWindowClosing (pure ()) (commitClosing host target)) >>= \case
            WindowAvailable True → do
              retireClosing host target entry
              pure CloseStarted
            WindowAvailable False → pure CloseAlreadyStarted
            WindowEnded _ → pure CloseNotServed

-- | The host's half of step 2: mark the window closing, close its port, settle
-- its queue, and close its input feed, answering whether it was still open.
-- Finite and never retries.
commitClosing ∷ WindowHost → WindowId → STM Bool
commitClosing host target =
  Map.lookup target <$> readTVar (hostEntries host) >>= \case
    Just entry | not (entryClosing entry) → do
      modifyTVar' (hostEntries host) (Map.insert target entry {entryClosing = True})
      closeEntryAdmission entry
      -- On a protected host the same step ends the window's new graphics use:
      -- its attachment, if it has one, begins retiring before the close is
      -- answered, and its veto then holds destruction back. Its retained
      -- service is brought up to date here too, so no reader can see the
      -- closing phase published while the service still reports an attached
      -- owner.
      mapM_ (`recordClosingWindow` target) (hostRetirementState host)
      refreshGraphicsCells host
      -- A retirement this close just began has never been offered an
      -- opportunity, so the next turn polls rather than waiting its idle bound
      -- before giving it one. A window with no attachment, and every window of
      -- an ordinary host, leave the demand exactly as they found it.
      markRetirementImmediate host
      pure True
    _ → pure False

-- | Attempt a closing window's retirement. A borrow of another window defers it
-- without calling the collection, and a borrow of this one defers it with the
-- collection's in-use answer. A retirement that succeeded or failed forgets the
-- window: a failed release is latched by the collection as evidence for its
-- exit and is never attempted again, and the window's observations report it.
retireClosing ∷ WindowHost → WindowId → HostEntry → IO ()
retireClosing host target entry = do
  borrowed ← readIORef (hostBorrowed host)
  vetoed ← attachmentVetoes host target
  if vetoed || any (/= target) (Map.keys borrowed)
    then pure ()
    else
      tryWithContext (retireMember (hostCollection host) (entryMember entry)) >>= \case
        Right RetirementInUse → pure ()
        Right _ → forget DisposalCompleted
        Left (caught ∷ ExceptionWithContext SomeException) →
          memberStatus (entryMember entry) >>= \case
            -- The collection latched the failed release as evidence for its own
            -- exit and will never attempt it again. The window is forgotten
            -- either way, and the attachment observation says the disposal
            -- failed rather than claiming a destruction that did not happen.
            MemberRetirementFailed _ → forget DisposalFailed
            _ → rethrowIO caught
  where
    forget disposal = do
      atomically $ do
        modifyTVar' (hostEntries host) (Map.delete target)
        mapM_ (`forgetRetiredWindow` target) (hostRetirementState host)
        -- The window's last attachment learns how its window ended before the
        -- host drops the cell; whoever retains the service keeps that answer.
        cells ← readTVar (hostGraphicsCells host)
        forM_ (Map.lookup target cells) $ \cell → do
          writeGraphicsSlot cell SlotFree []
          writeGraphicsDisposal cell disposal
        writeTVar (hostGraphicsCells host) (Map.delete target cells)
      modifyIORef' (hostSurfaced host) (Map.delete target)

-- | Whether a protected host's attachment still vetoes this window's native
-- destruction. An ordinary host has no attachment and vetoes nothing, so its
-- close protocol is exactly what it was.
attachmentVetoes ∷ WindowHost → WindowId → IO Bool
attachmentVetoes host target = case hostRetirementState host of
  Nothing → pure False
  Just retirement → atomically (windowRetirementVeto retirement target)

-- | Retry the retirement of every closing window, in registration order.
retirePending ∷ WindowHost → IO ()
retirePending host = do
  atomically (refreshGraphicsCells host)
  entries ← readTVarIO (hostEntries host)
  forM_ (Map.toAscList entries) $ \(target, entry) →
    if entryClosing entry then retireClosing host target entry else pure ()

-- | Acquire a window as a collection member and register it with its own port
-- and input feed. The feed starts focused if the window's initial observation
-- observed focus.
--
-- The window's construction runs with the caller's masking state, so a
-- cancellation during it rolls construction back and registers nothing. The
-- host's registration is the collection's handoff: it runs in the masked step
-- that registered the member, with nothing interruptible before it and nothing
-- that blocks inside it, so no cancellation separates the collection's
-- registration from the host's.
registerWindow ∷ WindowHost → WindowConfig → IO WindowClient
registerWindow host config =
  acquireMemberThen (hostCollection host) (windowAssembly (hostSession host) config) $ \member → do
    (identity, reader, feed) ←
      withMember (hostCollection host) member $ \window → do
        let identity = windowIdentity window
            reader = windowObservations window
        focused ← (== Observed True) . observedFocused . preparedValue . observedValue <$> atomically (readSnapshot reader)
        feed ← newInputFeed identity (hostInputCapacity (hostSettings host)) focused
        attachWindowInputFeed window feed
        pure (identity, reader, feed)
    commands ← newWindowPortHost (hostSession host) (hostCommandCapacity (hostSettings host)) identity
    demand ← newDemandSlot
    let client =
          newWindowClient identity commands reader (feedReader feed) (feedControl feed) $
            demandPublisher demand (commandHostNotifier (hostCommands host))
        entry = HostEntry member commands feed demand client False
    -- Registration and the quiescence check commit together, so a window whose
    -- creation was claimed before quiescence and finished after it is
    -- registered already closed: its port, its feed, and its demand slot admit
    -- nothing, and the client its ticket hands over can revive none of them.
    atomically $ do
      quiesced ← commandsAdmissionClosed (hostCommands host)
      when quiesced (closeEntryAdmission entry)
      modifyTVar' (hostEntries host) (Map.insert identity entry)
      -- The model learns of the window in the same step, so an attachment can
      -- never name a window the host does not hold, or miss one it does.
      mapM_ (`recordRegisteredWindow` identity) (hostRetirementState host)
    afterRegistration (hostHooks host)
    pure client

-- | Close one window's admission: its port, its input feed, and its demand
-- slot. Finite, never retries, and idempotent.
closeEntryAdmission ∷ HostEntry → STM ()
closeEntryAdmission entry = do
  void (closeWindowCommands (entryCommands entry))
  closeInputFeed (entryInput entry)
  closeDemandSlot (entryDemand entry)

-- | Reject a close request on the owner thread: it is cleared from its window's
-- observation only if it is still that window's latest, and the answer says
-- whether it was. A request for a window the host does not hold answers
-- 'False'.
rejectHostCloseRequest ∷ WindowHost → CloseRequest → IO Bool
rejectHostCloseRequest host request =
  ownerOperation (hostSession host) rejectOperation [] $
    readTVarIO (hostEntries host) >>= \entries → case Map.lookup target entries of
      Nothing → pure False
      Just entry →
        borrowWindow host target entry (\window → rejectCloseRequest window request) >>= \case
          WindowAvailable cleared → pure cleared
          WindowEnded _ → pure False
  where
    target = closeRequestWindow request

latestCloseRequest ∷ Window → IO (Maybe CloseRequest)
latestCloseRequest window =
  observedCloseRequest . preparedValue . observedValue <$> atomically (readSnapshot (windowObservations window))
