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
import Hetoimasia.Foundation.Time (Duration, Instant, deadlineReached, scriptedInstant, zeroDuration)
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

-- | A timer nothing but the example fires.
--
-- Arming it records the deadline and the remaining duration the owner gave
-- it. It decides expiry by comparing a scripted clock of its own with that
-- deadline, and only 'fireTimer' moves that clock. It does not read the
-- owner's counting clock: that clock advances on every reading, so a deadline
-- compared with it would come due by however often the owner and the main
-- thread happened to read it, not when the example says.
data ScriptedTimer = ScriptedTimer
  { timerArmings ∷ !(TVar [(Instant, Duration)])
    -- ^ Every arming's deadline and the duration that remained until it at
    -- the owner's reading, oldest first.
  , timerNow ∷ !(TVar Instant)
    -- ^ The timer's clock, from the script's origin.
  }

newScriptedTimer ∷ IO (ScriptedTimer, OwnerTimer)
newScriptedTimer = do
  armings ← newTVarIO []
  now ← newTVarIO (scriptedInstant zeroDuration)
  let timer = ScriptedTimer armings now
  pure
    ( timer
    , ownerTimer $ \due remaining → do
        atomically (modifyTVar' armings (<> [(due, remaining)]))
        pure ((`deadlineReached` due) <$> readTVar now)
    )

-- | Move the timer's clock to the latest deadline armed so far, which releases
-- every wait armed so far and any later one for a deadline no later than it.
fireTimer ∷ ScriptedTimer → IO ()
fireTimer timer = atomically $ do
  armed ← readTVar (timerArmings timer)
  modifyTVar' (timerNow timer) (\now → maximum (now : map fst armed))
