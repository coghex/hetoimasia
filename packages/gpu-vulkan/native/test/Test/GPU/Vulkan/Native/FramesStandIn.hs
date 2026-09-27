-- | A stand-in native layer for the frames: every call recorded in order, any
-- step made to fail, a hook run inside every call so an example can observe
-- the model at that instant or aim a cancellation at it, and a small model of
-- what Vulkan itself would hold the application to.
--
-- That model is the point of the stand-in. It tracks each fence — unsignalled,
-- pending on a submission or a presentation, or signalled — and each binary
-- semaphore — unsignalled, owed a signal, or waited on by a pending submission
-- or presentation — and each swapchain image the application owns, and it
-- records a violation, instead of failing, whenever a call breaks a rule:
-- asking or waiting on a fence no queue operation made pending, resetting or
-- destroying a pending fence, acquiring into or signalling a semaphore that is
-- not unsignalled, waiting on one nothing will signal, destroying one a
-- submission or a presentation still uses, presenting an image the application
-- does not own, or releasing an image whose acquisition signal was never waited
-- on to completion. Every example ends by requiring there were none.
--
-- A fence signals only when an example says its submission or presentation
-- completed ('completeFence', 'completeAll'), which is the injected completion
-- a native run gets from the device. A presentation's answer is scripted
-- ('scriptPresent'); by default it succeeds.
--
-- A step can be made to lose the device ('loseFrameStep'): it raises the
-- roots' stand-in's 'StandInLoss', which the roots classify as device loss.
-- From then on the stand-in holds the frames to the device-loss rules instead:
-- a fence or a semaphore may be destroyed whatever it was owed, and asking or
-- waiting on a fence, resetting one, acquiring, submitting, presenting and
-- releasing are each a violation — the lost device answers none of them with
-- anything that could be evidence.
module Test.GPU.Vulkan.Native.FramesStandIn
  ( FramesStandIn (..)
  , newFramesStandIn
  , framesStandInOps
  , FrameCall (..)
  , frameCalls
  , FrameStep (..)
  , failFrameStep
  , clearFrameStep
  , loseFrameStep
  , markDeviceLost
  , duringFrameCall
  , scriptAcquire
  , PresentScript (..)
  , scriptPresent
  , StandInOutOfMemory (..)
  , completeFence
  , completeAll
  , pendingFences
  , violations
  , FrameStepFailed (..)
  , imagesOwned
  , fenceStandings
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (Exception, SomeException, fromException, throwIO)
import Control.Monad (unless, when)
import Data.Foldable (for_)
import Data.IORef (writeIORef)
import Data.Maybe (isJust)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word64)

import Hetoimasia.GPU.Vulkan.Native.Frames (AcquireResult (..), FrameOps (..), PresentRequest (..), PresentStatus (..), SubmitBatch (..), WaitStage)
import Test.GPU.Vulkan.Native.StandIn (StandInLoss (..), Step (AtFrameCall))

-- | One native call the frames made, in the order it made it. A command buffer
-- is its number, as the recording's stand-in makes it.
data FrameCall
  = CreatedSemaphore !Word64
  | DestroyedSemaphore !Word64
  | CreatedFence !Word64
  | DestroyedFence !Word64
  | ResetFence !Word64
  | QueriedFence !Word64
  | Acquired !Word64 !Word64 !AcquireResult
    -- ^ The swapchain, the semaphore, and what the call answered.
  | Submitted ![([Word64], WaitStage, [Word64], [Word64])] !Word64
    -- ^ Each batch's waits, their stage, its command buffers and its signals;
    -- and the fence.
  | Released !Word64 ![Word32]
  | Presented !PresentRequest !PresentStatus
    -- ^ What was presented, and the swapchain's entry the call wrote.
  | WaitedFence !Word64 !Word64 !Bool
    -- ^ The fence, the timeout in nanoseconds, and whether it signalled.
  deriving (Eq, Show)

-- | A step the stand-in can be made to fail at.
data FrameStep
  = AtCreateSemaphore
  | AtCreateFence
  | AtResetFence
  | AtQueryFence
  | AtAcquire
  | AtSubmit
    -- ^ Fail with an effect the frames cannot know.
  | AtSubmitNoEffect
    -- ^ Fail as out of memory does: the specified no-effect result, which
    -- 'opsNoEffect' recognizes.
  | AtCleanupSubmit
    -- ^ Fail only a submission that runs no command.
  | AtRelease
  | AtDestroy
  | AtWait
  deriving (Eq, Ord, Show)

-- | How the next presentation answers.
data PresentScript
  = PresentReturning !PresentStatus
    -- ^ The call returns, writing this entry.
  | PresentRaising !PresentStatus !SomeException
    -- ^ The call writes this entry, then raises this failure.
  | PresentRaisingUnwritten !SomeException
    -- ^ The call raises without writing its entry.

-- | The out-of-memory failure a presentation or a submission raises, which the
-- stand-in's 'opsNoEffect' recognizes as the specified no-effect one.
data StandInOutOfMemory = StandInOutOfMemory
  deriving (Eq, Show)

instance Exception StandInOutOfMemory

-- | What a failing step raises, after recording the call.
newtype FrameStepFailed = FrameStepFailed FrameStep
  deriving (Eq, Show)

instance Exception FrameStepFailed

data FenceState = Unsignalled | Pending | Signalled
  deriving (Eq, Show)

data SemaphoreState = Idle | SignalOwed | WaitedBy !Word64
  deriving (Eq, Show)

data FramesStandIn = FramesStandIn
  { standJournal ∷ !(TVar [FrameCall])
    -- ^ Newest first.
  , standFailing ∷ !(TVar (Set FrameStep))
  , standHandles ∷ !(TVar Word64)
  , standFences ∷ !(TVar (Map Word64 FenceState))
  , standSemaphores ∷ !(TVar (Map Word64 SemaphoreState))
  , standPending ∷ !(TVar (Map Word64 [Word64]))
    -- ^ Each pending fence, and the semaphores its submission waits on.
  , standOwned ∷ !(TVar (Map (Word64, Word32) Word64))
    -- ^ Each image the application owns, and the semaphore its acquisition
    -- signals.
  , standScript ∷ !(TVar [AcquireResult])
    -- ^ Answers for the next acquisitions, before the default.
  , standPresents ∷ !(TVar [PresentScript])
    -- ^ Answers for the next presentations, before the default success.
  , standImages ∷ !Word32
    -- ^ How many images each swapchain has.
  , standViolations ∷ !(TVar [Text])
  , standDuring ∷ !(TVar (FrameCall → IO ()))
  , standLosing ∷ !(TVar (Set FrameStep))
    -- ^ Steps that lose the device.
  , standLost ∷ !(TVar Bool)
    -- ^ Whether the device has been lost.
  }

newFramesStandIn ∷ IO FramesStandIn
newFramesStandIn =
  FramesStandIn
    <$> newTVarIO []
    <*> newTVarIO Set.empty
    <*> newTVarIO 9000
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO []
    <*> newTVarIO []
    <*> pure 3
    <*> newTVarIO []
    <*> newTVarIO (\_ → pure ())
    <*> newTVarIO Set.empty
    <*> newTVarIO False

-- | Every call so far, oldest first.
frameCalls ∷ FramesStandIn → IO [FrameCall]
frameCalls standIn = reverse <$> readTVarIO (standJournal standIn)

failFrameStep ∷ FramesStandIn → FrameStep → IO ()
failFrameStep standIn at = atomically (modifyTVar' (standFailing standIn) (Set.insert at))

clearFrameStep ∷ FramesStandIn → FrameStep → IO ()
clearFrameStep standIn at = atomically (modifyTVar' (standFailing standIn) (Set.delete at))

-- | Make this step lose the device: it raises 'StandInLoss', after recording
-- the call.
loseFrameStep ∷ FramesStandIn → FrameStep → IO ()
loseFrameStep standIn at = atomically (modifyTVar' (standLosing standIn) (Set.insert at))

-- | The device was lost by a call outside the frames — a generation's, say.
markDeviceLost ∷ FramesStandIn → IO ()
markDeviceLost standIn = atomically (writeTVar (standLost standIn) True)

-- | Run this inside every call, after its effect and before it returns.
duringFrameCall ∷ FramesStandIn → (FrameCall → IO ()) → IO ()
duringFrameCall standIn action = atomically (writeTVar (standDuring standIn) action)

-- | Answer the next acquisitions with these, in order.
scriptAcquire ∷ FramesStandIn → [AcquireResult] → IO ()
scriptAcquire standIn answers = atomically (modifyTVar' (standScript standIn) (<> answers))

-- | Answer the next presentations with these, in order.
scriptPresent ∷ FramesStandIn → [PresentScript] → IO ()
scriptPresent standIn answers = atomically (modifyTVar' (standPresents standIn) (<> answers))

-- | Where every fence stands: unsignalled, pending or signalled.
fenceStandings ∷ FramesStandIn → IO [(Word64, Text)]
fenceStandings standIn = map (fmap shown) . Map.toList <$> readTVarIO (standFences standIn)

-- | The submission or presentation pending on this fence completed: the fence
-- signals, and every semaphore it waited on is unsignalled again.
completeFence ∷ FramesStandIn → Word64 → IO ()
completeFence standIn fence = atomically (complete standIn fence)

-- | Every pending submission completed.
completeAll ∷ FramesStandIn → IO ()
completeAll standIn = atomically $ readTVar (standPending standIn) >>= mapM_ (complete standIn) . Map.keys

complete ∷ FramesStandIn → Word64 → STM ()
complete standIn fence = do
  waited ← Map.findWithDefault [] fence <$> readTVar (standPending standIn)
  modifyTVar' (standPending standIn) (Map.delete fence)
  modifyTVar' (standFences standIn) (Map.insert fence Signalled)
  for_ waited $ \semaphore → modifyTVar' (standSemaphores standIn) (Map.insert semaphore Idle)

pendingFences ∷ FramesStandIn → IO [Word64]
pendingFences standIn = Map.keys <$> readTVarIO (standPending standIn)

-- | Every rule a call broke, oldest first.
violations ∷ FramesStandIn → IO [Text]
violations standIn = reverse <$> readTVarIO (standViolations standIn)

-- | The images the application owns now, by swapchain and index.
imagesOwned ∷ FramesStandIn → IO [(Word64, Word32)]
imagesOwned standIn = Map.keys <$> readTVarIO (standOwned standIn)

violate ∷ FramesStandIn → Text → STM ()
violate standIn complaint = modifyTVar' (standViolations standIn) (complaint :)

-- | Record the call, run the hook, then lose the device or fail if the step is
-- scripted to. A call the lost device could only answer with a phantom is a
-- violation.
step ∷ FramesStandIn → [FrameStep] → FrameCall → IO ()
step standIn at call = do
  atomically $ do
    modifyTVar' (standJournal standIn) (call :)
    lost ← readTVar (standLost standIn)
    when (lost && phantom call) $ violate standIn ("made a call the lost device answers nothing to: " <> shown call)
  action ← readTVarIO (standDuring standIn)
  action call
  losing ← readTVarIO (standLosing standIn)
  when (any (`Set.member` losing) at) $ do
    atomically (writeTVar (standLost standIn) True)
    throwIO (StandInLoss AtFrameCall)
  failing ← readTVarIO (standFailing standIn)
  for_ at $ \each → when (Set.member each failing) (throwIO (FrameStepFailed each))
  where
    phantom = \case
      QueriedFence _ → True
      WaitedFence {} → True
      ResetFence _ → True
      Acquired {} → True
      Submitted {} → True
      Released {} → True
      Presented {} → True
      _ → False

fresh ∷ FramesStandIn → IO Word64
fresh standIn = atomically $ do
  next ← readTVar (standHandles standIn)
  writeTVar (standHandles standIn) (next + 1)
  pure next

shown ∷ Show a ⇒ a → Text
shown = Text.pack . show

-- | The stand-in's frames layer. The device is whatever the roots hold; a
-- command buffer is a number.
framesStandInOps ∷ FramesStandIn → FrameOps Int Word64
framesStandInOps standIn =
  FrameOps
    { opsCreateSemaphore = \_ → do
        handle ← fresh standIn
        step standIn [AtCreateSemaphore] (CreatedSemaphore handle)
        atomically (modifyTVar' (standSemaphores standIn) (Map.insert handle Idle))
        pure handle
    , opsDestroySemaphore = \_ handle → do
        atomically $ do
          state ← Map.lookup handle <$> readTVar (standSemaphores standIn)
          -- A lost device's objects may be destroyed whatever they were owed.
          lost ← readTVar (standLost standIn)
          unless (state == Just Idle || lost) $ violate standIn ("destroyed semaphore " <> shown handle <> " while " <> shown state)
          modifyTVar' (standSemaphores standIn) (Map.delete handle)
        step standIn [AtDestroy] (DestroyedSemaphore handle)
    , opsCreateFence = \_ → do
        handle ← fresh standIn
        step standIn [AtCreateFence] (CreatedFence handle)
        atomically (modifyTVar' (standFences standIn) (Map.insert handle Unsignalled))
        pure handle
    , opsDestroyFence = \_ handle → do
        atomically $ do
          state ← Map.lookup handle <$> readTVar (standFences standIn)
          lost ← readTVar (standLost standIn)
          when (state == Just Pending && not lost) $ violate standIn ("destroyed pending fence " <> shown handle)
          modifyTVar' (standFences standIn) (Map.delete handle)
        step standIn [AtDestroy] (DestroyedFence handle)
    , opsResetFence = \_ handle → do
        step standIn [AtResetFence] (ResetFence handle)
        atomically $ do
          state ← Map.lookup handle <$> readTVar (standFences standIn)
          when (state == Just Pending) $ violate standIn ("reset pending fence " <> shown handle)
          modifyTVar' (standFences standIn) (Map.insert handle Unsignalled)
    , opsFenceSignalled = \_ handle → do
        step standIn [AtQueryFence] (QueriedFence handle)
        atomically $
          (Map.lookup handle <$> readTVar (standFences standIn)) >>= \case
            Just Pending → pure False
            Just Signalled → pure True
            other → do
              violate standIn ("asked fence " <> shown handle <> ", which no submission made pending: " <> shown other)
              pure False
    , opsAcquireImage = \_ swapchain semaphore → do
        answer ← atomically $ do
          script ← readTVar (standScript standIn)
          owned ← readTVar (standOwned standIn)
          case script of
            next : rest → do
              writeTVar (standScript standIn) rest
              pure next
            [] → pure $ case [index | index ← [0 .. standImages standIn - 1], not (Map.member (swapchain, index) owned)] of
              index : _ → AcquiredIndex index
              [] → AcquiringNotReady
        step standIn [AtAcquire] (Acquired swapchain semaphore answer)
        let acquired index = atomically $ do
              state ← Map.lookup semaphore <$> readTVar (standSemaphores standIn)
              unless (state == Just Idle) $ violate standIn ("acquired into semaphore " <> shown semaphore <> " while " <> shown state)
              modifyTVar' (standSemaphores standIn) (Map.insert semaphore SignalOwed)
              owned ← Map.member (swapchain, index) <$> readTVar (standOwned standIn)
              when owned $ violate standIn ("acquired image " <> shown index <> ", which the application already owns")
              modifyTVar' (standOwned standIn) (Map.insert (swapchain, index) semaphore)
        case answer of
          AcquiredIndex index → acquired index
          AcquiredSuboptimalIndex index → acquired index
          _ → pure ()
        pure answer
    , opsSubmit = \_ _ batches fence → do
        let cleanup = all (null . submitCommands) batches
        step
          standIn
          ([AtSubmit, AtSubmitNoEffect] <> [AtCleanupSubmit | cleanup])
          (Submitted [(submitWaits batch, submitWaitStage batch, submitCommands batch, submitSignals batch) | batch ← batches] fence)
        atomically $ do
          fenceState ← Map.lookup fence <$> readTVar (standFences standIn)
          unless (fenceState == Just Unsignalled) $ violate standIn ("submitted with fence " <> shown fence <> " while " <> shown fenceState)
          let waits = concatMap submitWaits batches
              signals = concatMap submitSignals batches
          for_ waits $ \semaphore → do
            state ← Map.lookup semaphore <$> readTVar (standSemaphores standIn)
            unless (state == Just SignalOwed) $ violate standIn ("waited on semaphore " <> shown semaphore <> " while " <> shown state)
            modifyTVar' (standSemaphores standIn) (Map.insert semaphore (WaitedBy fence))
          for_ signals $ \semaphore → do
            state ← Map.lookup semaphore <$> readTVar (standSemaphores standIn)
            unless (state == Just Idle) $ violate standIn ("signalled semaphore " <> shown semaphore <> " while " <> shown state)
            modifyTVar' (standSemaphores standIn) (Map.insert semaphore SignalOwed)
          modifyTVar' (standFences standIn) (Map.insert fence Pending)
          modifyTVar' (standPending standIn) (Map.insert fence waits)
    , opsNoEffect = \failure →
        fromException failure == Just (FrameStepFailed AtSubmitNoEffect) || fromException failure == Just StandInOutOfMemory
    , opsReleaseImages = \_ swapchain indices → do
        step standIn [AtRelease] (Released swapchain indices)
        atomically $ for_ indices $ \index →
          (Map.lookup (swapchain, index) <$> readTVar (standOwned standIn)) >>= \case
            Nothing → violate standIn ("released image " <> shown index <> ", which the application does not own")
            Just semaphore → do
              state ← Map.lookup semaphore <$> readTVar (standSemaphores standIn)
              -- The acquisition's signal must have been waited on, and that
              -- wait completed: the semaphore is idle again.
              unless (state == Just Idle) $ violate standIn ("released image " <> shown index <> " while its acquisition semaphore is " <> shown state)
              modifyTVar' (standOwned standIn) (Map.delete (swapchain, index))
    , opsPresent = \_ _ request status → do
        answer ← atomically $ do
          script ← readTVar (standPresents standIn)
          case script of
            next : rest → Just next <$ writeTVar (standPresents standIn) rest
            [] → pure Nothing
        let (written, raised) = case answer of
              Nothing → (PresentStatusSuccess, Nothing)
              Just (PresentReturning entry) → (entry, Nothing)
              Just (PresentRaising entry failure) → (entry, Just failure)
              Just (PresentRaisingUnwritten failure) → (PresentStatusUnwritten, Just failure)
            fence = presentFence request
            semaphore = presentWait request
            image = (presentSwapchain request, presentIndex request)
            enqueued = written `elem` [PresentStatusSuccess, PresentStatusSuboptimal, PresentStatusOutOfDate, PresentStatusSurfaceLost]
        atomically $ do
          modifyTVar' (standJournal standIn) (Presented request written :)
          lost ← readTVar (standLost standIn)
          when lost $ violate standIn ("presented to the lost device: " <> shown request)
        action ← readTVarIO (standDuring standIn)
        -- A presentation that was enqueued has its effect, whatever it answers:
        -- the semaphore wait is the presentation engine's, the fence is
        -- pending, and the image is the presentation engine's again.
        when enqueued $ atomically $ do
          fenceState ← Map.lookup fence <$> readTVar (standFences standIn)
          unless (fenceState == Just Unsignalled) $ violate standIn ("presented with fence " <> shown fence <> " while " <> shown fenceState)
          state ← Map.lookup semaphore <$> readTVar (standSemaphores standIn)
          unless (state == Just SignalOwed) $ violate standIn ("presented waiting on semaphore " <> shown semaphore <> " while " <> shown state)
          owned ← Map.member image <$> readTVar (standOwned standIn)
          unless owned $ violate standIn ("presented image " <> shown image <> ", which the application does not own")
          modifyTVar' (standSemaphores standIn) (Map.insert semaphore (WaitedBy fence))
          modifyTVar' (standFences standIn) (Map.insert fence Pending)
          modifyTVar' (standPending standIn) (Map.insert fence [semaphore])
          modifyTVar' (standOwned standIn) (Map.delete image)
        writeIORef status written
        action (Presented request written)
        for_ raised $ \failure → do
          when (isJust (fromException failure ∷ Maybe StandInLoss)) $ atomically (writeTVar (standLost standIn) True)
          throwIO failure
    , opsWaitFence = \_ fence timeout → do
        signalled ← atomically $
          (Map.lookup fence <$> readTVar (standFences standIn)) >>= \case
            Just Pending → pure False
            Just Signalled → pure True
            other → do
              violate standIn ("waited on fence " <> shown fence <> ", which no queue operation made pending: " <> shown other)
              pure False
        step standIn [AtWait] (WaitedFence fence timeout signalled)
        pure signalled
    }
