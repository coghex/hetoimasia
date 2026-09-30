-- | The reconciliation protocol: folding what a window's callbacks captured,
-- and a sample if one was taken, into its observation, and committing the
-- result.
--
-- It runs on the session's owner thread, at an owner boundary. Its commit is
-- the boundary's one step that empties the capture latch the callbacks in
-- "Hetoimasia.GLFW.Internal.Window.Callbacks" fill; construction and release
-- take the latch whole instead. The generation check, the latch clearing, the
-- observation commit, and the input publication all live in
-- 'reconcileAdjusted', under the masking described there.
--
-- = The reconciliation boundary
--
-- Captures are reconciled on the owner thread at an owner boundary: after the
-- initial sampling, and after any owner operation's native calls return,
-- whether they were a setter or a poll. Geometry, attribute, and cursor
-- captures coalesce to their latest values, so a snapshot preserves no event
-- history. Ordered input — key, character, button, scroll, and focus
-- transitions — is staged in a bounded buffer of 'inputStagingCapacity' events
-- and is never coalesced. Cursor position is not an input event: it coalesces
-- into the observation and updates the feed's cursor sample, so a later button
-- still carries the coordinates copied when that button callback ran. A
-- refresh or a close request always publishes a new revision, even when every
-- sampled attribute is unchanged. Preparation runs in 'IO', outside the
-- trampoline and outside 'STM'. Nothing changes until the commit: after
-- preparation, the captures are cleared, the observation published, and the
-- owner's state written in one masked step with no interruptible operation, so
-- a cancellation before it leaves every capture latched and nothing can
-- separate the three writes. A latched fault is taken and rethrown in one
-- masked step as well, so a cancellation cannot discard it. Once the observation is published, a latched
-- callback fault is rethrown with its original type and context, annotated
-- with the @window callback@ operation, the callback, and the window. An
-- asynchronous exception is rethrown unannotated, so cancellation stays
-- cancellation. If the operation's own native step fails first, its failure
-- propagates and the captures and fault stay latched for the next boundary.
--
-- Staging overflow sets a loss latch that remains set while the buffer is
-- full. At the next owner boundary the latch is checked before any staged
-- event is published: the ambiguous batch is discarded, none of its prefix is
-- replayed, and the window's input feed begins the same overflow reset a full
-- channel would. Close intent and the observation keep updating. One window's
-- loss leaves every other window's feed and commands usable. A feed is
-- attached with 'attachWindowInputFeed' after construction; until then staged
-- input is discarded at the boundary that would have published it, without a
-- reset.
module Hetoimasia.GLFW.Internal.Window.Reconcile
  ( reconciled
  , reconcileWindow
  , reconcileWith
  , reconcileAdjusted
  , commitObservation
  , raiseLatchedFault
  ) where

import Control.Concurrent.STM (atomically)
import Control.Exception (mask_, uninterruptibleMask_)
import Control.Monad (forM_, unless, void, when)
import Data.IORef (atomicModifyIORef', readIORef, writeIORef)
import Data.Maybe (isJust)
import Hetoimasia.Foundation.Messaging.Payload (Prepared, prepare)
import Hetoimasia.Foundation.Messaging.Snapshot (publish)
import Hetoimasia.GLFW.Internal.Attribute (Attribute (..))
import Hetoimasia.GLFW.Internal.Input
  ( InputPayload (..)
  , produceInput
  , recordCursor
  , resetFromStagingOverflow
  )
import Hetoimasia.GLFW.Internal.Mode (AppliedMode (..), deriveApplied, modeApplied, pruneClaims, recordApplied, settleClaims)
import Hetoimasia.GLFW.Internal.Session (currentSessionMonitors, liveMonitors, sessionClaims)
import Hetoimasia.GLFW.Internal.Window.Callbacks (rethrowFault)
import Hetoimasia.GLFW.Internal.Window.Identity (WindowId, windowLocalIdentity)
import Hetoimasia.GLFW.Internal.Window.Observation (CloseRequest (..), WindowObservation (..))
import Hetoimasia.GLFW.Internal.Window.Sample (Sample (..))
import Hetoimasia.GLFW.Internal.Window.State
  ( Captures (..)
  , OwnerState (..)
  , StagedInput (..)
  , Window (..)
  , noCaptures
  , windowIdentifiers
  )
import Numeric.Natural (Natural)

-- | Fold captures, and then a sample if one was taken, into an observation.
-- Returns the observation with its revision unchanged, and the close counter.
reconciled ∷ WindowId → Maybe Sample → Captures → WindowObservation → Natural → (WindowObservation, Natural)
reconciled identity sample pending current issued =
  (sampledOver (captured current), issued')
  where
    closes = capturedCloses pending
    issued' = issued + closes
    captured observation =
      observation
        { obsLogical = maybe (obsLogical observation) Observed (capturedSize pending)
        , obsFramebuffer = maybe (obsFramebuffer observation) Observed (capturedFramebuffer pending)
        , obsScale = maybe (obsScale observation) Observed (capturedScale pending)
        , obsPlacement = maybe (obsPlacement observation) Observed (capturedPlacement pending)
        , obsFocused = maybe (obsFocused observation) Observed (capturedFocused pending)
        , obsIconified = maybe (obsIconified observation) Observed (capturedIconified pending)
        , obsMaximized = maybe (obsMaximized observation) Observed (capturedMaximized pending)
        , obsCloseRequest =
            if closes > 0 then Just (CloseRequest identity issued') else obsCloseRequest observation
        , obsCursor = maybe (obsCursor observation) Just (capturedCursor pending)
        , obsCursorInside = maybe (obsCursorInside observation) Just (capturedCursorInside pending)
        }
    sampledOver observation = case sample of
      Nothing → observation
      Just taken →
        observation
          { obsLogical = sampleLogical taken
          , obsFramebuffer = sampleFramebuffer taken
          , obsScale = sampleScale taken
          , obsPlacement = samplePlacement taken
          , obsFocused = sampleFocused taken
          , obsIconified = sampleIconified taken
          , obsMaximized = sampleMaximized taken
          , obsVisible = sampleVisible taken
          , obsDecorated = sampleDecorated taken
          , obsMonitor = sampleMonitor taken
          }

-- | Fold the latched captures, and a sample if one was taken, into the current
-- observation, and publish a new revision if anything changed or a refresh or
-- close request was captured.
--
-- Nothing is mutated until the commit. The captures are read, not taken, and
-- the next observation is computed and prepared. Only then, masked and with no
-- interruptible operation, are the captures cleared, the snapshot published,
-- and the owner state written, so a cancellation or a failure before the commit
-- leaves the captures latched and the snapshot and owner state as they were,
-- and nothing can land between the three writes. If a callback recorded
-- anything between the read and the commit, the fold starts again from the
-- newer captures. A latched fault stays latched for 'raiseLatchedFault'.
--
-- @interruption@ runs at the preparation point, after preparation and before
-- the commit. Production passes @pure ()@; the test seam uses it to deliver a
-- cancellation exactly there.
reconcileWindow ∷ IO () → Window → Maybe Sample → IO ()
reconcileWindow = reconcileWith False

-- | 'reconcileWindow', publishing a new revision even when nothing changed if
-- @forced@ holds.
reconcileWith ∷ Bool → IO () → Window → Maybe Sample → IO ()
reconcileWith forced = reconcileAdjusted forced id

-- | 'reconcileWith', applying @adjust@ to the folded observation before it is
-- compared and prepared: how a transition publishes its mode record beside the
-- sample it was reconciled with.
reconcileAdjusted ∷ Bool → (WindowObservation → WindowObservation) → IO () → Window → Maybe Sample → IO ()
reconcileAdjusted forced adjust interruption window sample = do
  pending ← readIORef (windowCaptures window)
  derived ← case sample of
    Just taken → presentationFrom window taken
    Nothing
      | isJust (capturedPlacement pending) → borderlessFrom window
      | otherwise → pure id
  OwnerState current issued ← readIORef (windowOwnerState window)
  let (reconciledObservation, issued') = reconciled (windowId window) sample pending current issued
      folded = adjust (derived reconciledObservation)
      signalled = capturedRefresh pending || capturedCloses pending > 0
      next = folded {obsRevision = obsRevision current + 1}
  prepared ← if forced || folded /= current || signalled then Just <$> prepare next else pure Nothing
  interruption
  committed ← mask_ $ do
    cleared ← atomicModifyIORef' (windowCaptures window) $ \latched →
      if capturedGeneration latched == capturedGeneration pending
        then
          ( noCaptures
              { capturedGeneration = capturedGeneration latched
              , capturedFault = capturedFault latched
              , capturedCursor = capturedCursor latched
              , capturedCursorInside = capturedCursorInside latched
              }
          , True
          )
        else (latched, False)
    when cleared $ do
      forM_ prepared (commitObservation window next issued')
      -- Publication is bounded STM and evaluation. It stays uninterruptible
      -- so a cancellation cannot admit a prefix and drop the rest.
      uninterruptibleMask_ (publishCapturedInput window pending)
    interruption
    pure cleared
  unless committed (reconcileAdjusted forced adjust interruption window sample)

-- | Settle a window's monitor claims with a full sample, and answer how its
-- applied mode changes: derived from the sample against the current monitors.
presentationFrom ∷ Window → Sample → IO (WindowObservation → WindowObservation)
presentationFrom window taken = do
  monitors ← currentSessionMonitors session
  live ← liveMonitors session
  atomicModifyIORef' (sessionClaims session) $ \claims →
    (settleClaims (windowLocalIdentity (windowId window)) (sampleMonitor taken) (pruneClaims live claims), ())
  let applied = deriveApplied monitors (sampleMonitor taken) (sampleDecorated taken) (samplePlacement taken)
  pure (\observation → observation {obsMode = recordApplied applied (obsMode observation)})
  where
    session = windowSession window

-- | How a callback-only fold changes a borderless window's applied mode: its
-- monitor is re-derived from the folded placement, with the decoration and
-- fullscreen monitor of its latest sample. Any other applied mode depends on no
-- placement, and is left alone.
borderlessFrom ∷ Window → IO (WindowObservation → WindowObservation)
borderlessFrom window = do
  monitors ← currentSessionMonitors (windowSession window)
  pure $ \observation → case modeApplied (obsMode observation) of
   AppliedBorderless _ →
     let applied = deriveApplied monitors (obsMonitor observation) (obsDecorated observation) (obsPlacement observation)
      in observation {obsMode = recordApplied applied (obsMode observation)}
   _ → observation

-- | Publish a prepared observation and record it as the owner's current one.
-- The caller must be masked: neither write is interruptible, so the two cannot
-- be separated.
commitObservation ∷ Window → WindowObservation → Natural → Prepared WindowObservation → IO ()
commitObservation window next issued prepared = do
  _ ← atomically (publish (windowPublisher window) prepared)
  writeIORef (windowOwnerState window) (OwnerState next issued)

-- | Publish staged input into the attached feed, if any. Loss is checked
-- before any captured prefix is admitted: a latched overflow discards the
-- batch and starts the same reset a full channel would. Cursor samples update
-- the feed even when the batch is discarded, so a later button still has a
-- position after resumption.
publishCapturedInput ∷ Window → Captures → IO ()
publishCapturedInput window pending = do
  feed ← readIORef (windowFeed window)
  forM_ feed $ \attached → do
    forM_ (capturedCursor pending) (recordCursor attached)
    if capturedInputLoss pending
      then do
        let lost = capturedInputLost pending + fromIntegral (capturedInputCount pending)
        void (resetFromStagingOverflow attached lost (capturedFocused pending))
      else mapM_ (admitStaged attached) (reverse (capturedInput pending))
  where
    admitStaged feed = \case
      StagedKey event → void (produceInput feed (KeyInput event))
      StagedChar character → void (produceInput feed (TextInput character))
      StagedButton event → void (produceInput feed (ButtonInput event))
      StagedScroll event → void (produceInput feed (ScrollInput event))
      StagedFocus focused → void (produceInput feed (FocusInput focused))

-- | Take a latched callback fault and rethrow it, in one masked step, so a
-- cancellation cannot discard the fault between the take and the rethrow.
raiseLatchedFault ∷ Window → IO ()
raiseLatchedFault window = mask_ $ do
  fault ← atomicModifyIORef' (windowCaptures window) $ \latched →
   (latched {capturedFault = Nothing}, capturedFault latched)
  mapM_ (rethrowFault (windowIdentifiers (windowId window))) fault
