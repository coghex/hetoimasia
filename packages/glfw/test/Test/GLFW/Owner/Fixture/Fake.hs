-- | The fake backend and the scripted timer the graphics-owner examples inject.
--
-- Every backend operation is a /fake/, injected through 'GraphicsOperations'
-- exactly as VK-7's Vulkan operations will be. The fakes hold no GLFW
-- capability at all, which is the first half of the evidence that the owner
-- makes no GLFW call; the second half is "Test.GLFW.Owner.Discipline", which
-- reads the seam's own record of every native call and the thread that made
-- each one.
module Test.GLFW.Owner.Fixture.Fake
  ( Fake (..)
  , newFake
  , fakeOperations
  , script
  , ScriptedTimer (..)
  , newScriptedTimer
  , fireTimer
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM
  ( TVar
  , atomically
  , modifyTVar'
  , newTVarIO
  , readTVar
  , readTVarIO
  , writeTVar
  )
import Control.Exception (SomeException, throwIO, try)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Time (Duration)
import Hetoimasia.Runtime.GLFW
import Test.GLFW.Owner.Fixture.Journal (Note (..), Scene, note)

-- ---------------------------------------------------------------------------
-- The fake backend

-- | Every injected operation, as a cell an example may replace before or
-- during a run, beside the record of what each was called with.
data Fake = Fake
  { fakeJournal ∷ !(TVar [Note])
  , fakeStart ∷ !(TVar (OwnerStart → IO OwnerReady))
  , fakeConstruct ∷ !(TVar (TargetStart → IO TargetHandoff))
  , fakeStep ∷ !(TVar (OwnerStep Scene → IO StepReport))
  , fakeDeadline ∷ !(TVar (IO NextDeadline))
  , fakePrepare ∷ !(TVar (TargetRetire → IO RetirementReadiness))
  , fakeRetireTarget ∷ !(TVar (TargetRetire → IO TargetRetired))
  , fakeRetireOwner ∷ !(TVar (OwnerRetire → IO OwnerRetired))
  , fakeDestroy ∷ !(TVar (OwnerDestroy → IO OwnerDestroyed))
  , fakeSteps ∷ !(TVar [[TargetStepView]])
    -- ^ Every step's target views, oldest first.
  , fakeScenes ∷ !(TVar [Scene])
  , fakeRetirements ∷ !(TVar [TargetRetire])
  , fakeOwnerRetirements ∷ !(TVar [OwnerRetire])
  , fakeThreads ∷ !(TVar [ThreadId])
    -- ^ The threads the operations ran on, which is how an example knows which
    -- thread is the owner's without the owner telling it.
  }

newFake ∷ TVar [Note] → IO Fake
newFake journal =
  Fake journal
    <$> newTVarIO (\_ → pure (ownerReady "started"))
    <*> newTVarIO (\start → pure (TargetConstructed (targetEvidence (describeTarget start))))
    <*> newTVarIO (\_ → pure noStepWork)
    <*> newTVarIO (pure NoOwnerDemand)
    <*> newTVarIO (\_ → pure RetirementReady)
    <*> newTVarIO (\retire → pure (targetRetired (Text.pack (show (retiringWindow retire)))))
    <*> newTVarIO (\_ → pure (ownerRetired "retired"))
    <*> newTVarIO (\_ → pure (ownerDestroyed "destroyed"))
    <*> newTVarIO []
    <*> newTVarIO []
    <*> newTVarIO []
    <*> newTVarIO []
    <*> newTVarIO []

describeTarget ∷ TargetStart → Text
describeTarget start = Text.pack (show (startingWindow start))

-- | The operation record the owner is given. It has no GLFW capability of any
-- kind: no session, no window handle, no event pump, no command port.
fakeOperations ∷ Fake → GraphicsOperations Scene
fakeOperations fake =
  GraphicsOperations
    { graphicsStartOwner = \start → do
        mark
        note (fakeJournal fake) OwnerStartup
        readTVarIO (fakeStart fake) >>= ($ start)
    , graphicsConstructTarget = \start → do
        mark
        note (fakeJournal fake) (Constructed (describeTarget start))
        readTVarIO (fakeConstruct fake) >>= ($ start)
    , graphicsStep = \step → do
        mark
        atomically $ do
          modifyTVar' (fakeSteps fake) (<> [stepTargets step])
          modifyTVar' (fakeScenes fake) (<> [stepScene step])
        note (fakeJournal fake) Stepped
        readTVarIO (fakeStep fake) >>= ($ step)
    , graphicsNextDeadline = mark >> readTVarIO (fakeDeadline fake) >>= id
    , graphicsWake = pure False
    , graphicsPrepareRetirement = \retire → do
        mark
        readTVarIO (fakePrepare fake) >>= ($ retire)
    , graphicsRetireTarget = \retire → do
        mark
        atomically (modifyTVar' (fakeRetirements fake) (<> [retire]))
        note (fakeJournal fake) (TargetRetirement (Text.pack (show (retiringWindow retire))))
        readTVarIO (fakeRetireTarget fake) >>= ($ retire)
    , graphicsRetireOwner = \retire → do
        mark
        atomically (modifyTVar' (fakeOwnerRetirements fake) (<> [retire]))
        note (fakeJournal fake) OwnerRetirement
        readTVarIO (fakeRetireOwner fake) >>= ($ retire)
    , graphicsDestroyOwner = \destroy → do
        mark
        note (fakeJournal fake) OwnerDestruction
        outcome ← try (readTVarIO (fakeDestroy fake) >>= ($ destroy))
        case outcome ∷ Either SomeException OwnerDestroyed of
          Right evidence → pure evidence
          Left caught → do
            note (fakeJournal fake) (DestroyRaised (Text.pack (show caught)))
            throwIO caught
    }
  where
    mark = do
      caller ← myThreadId
      atomically $ modifyTVar' (fakeThreads fake) $ \seen →
        if caller `elem` seen then seen else seen <> [caller]

-- | Replace one operation for the rest of the run.
script ∷ TVar a → a → IO ()
script cell = atomically . writeTVar cell

-- ---------------------------------------------------------------------------
-- The timer

-- | A timer nothing but the example fires. Arming it records the duration
-- asked for; firing it releases every wait armed so far.
data ScriptedTimer = ScriptedTimer
  { timerArmings ∷ !(TVar [Duration])
  , timerFired ∷ !(TVar Bool)
  }

newScriptedTimer ∷ IO (ScriptedTimer, OwnerTimer)
newScriptedTimer = do
  armings ← newTVarIO []
  fired ← newTVarIO False
  let timer = ScriptedTimer armings fired
  pure
    ( timer
    , ownerTimer $ \duration → do
        atomically (modifyTVar' armings (<> [duration]))
        pure (readTVar fired)
    )

fireTimer ∷ ScriptedTimer → IO ()
fireTimer timer = atomically (writeTVar (timerFired timer) True)
