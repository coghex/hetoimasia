-- | Ending a rig run at each boundary of the graphics owner's start (#612).
--
-- The six examples that hold the owner inside its startup, and the one whose exit hook waits for an owner the body publishes, strand
-- the protected exit when the run ends before the body has begun to release what they hold. This module is the harness that proves
-- they no longer do: a 'Cutting' says where the run is cut, how, and whether the fixture's rescue is in force, and the examples it
-- builds judge that the exit finishes and propagates what was injected, or (for the control) that the same fixture without its
-- rescue does not.
--
-- = The boundaries
--
-- Derived from the source (@Owner/Start.hs@, @Owner/Lifetime.hs@, @Foundation/Worker/Startup.hs@, @Runtime/Application.hs@):
--
-- * 'BeforePublication': the owner's worker is registered and forked and its handle is not yet published. The host hook
--   'Private.ownerBoundary' is called with 'Private.OwnerBeforePublication' at the start of the preparation step.
-- * 'AfterStart': the owner has started and its handle is published; the start has not returned it. The same hook, with
--   'Private.OwnerStarted'.
-- * 'StartupCallback': the application's startup callback, which the runner calls after supervision, the quiescence guard and the
--   first runtime check, and before the second. The rig's own callback ('ownedHostAt').
-- * 'BodyEntry': the example's body, at its first statement and before its first masked step.
--
-- Two further boundaries of the start, the owner handle's publication inside the preparation step and the wait for its startup, are
-- a known production gap (#613): no fixture can end a run there, so none is named here.
--
-- = The states
--
-- Each boundary is crossed with three ways of ending the run: a failure the boundary raises ('CutFails'), a cancellation that is
-- already pending when the run reaches the boundary and is received at the first point the run is unmasked ('CutPending'), and a
-- cancellation delivered while the run is parked at the boundary ('CutDelivered').
module Test.GLFW.Owner.Fixture.Cut
  ( Boundary (..)
  , allBoundaries
  , CutState (..)
  , allStates
  , Cutting (..)
  , uncut
  , withCutting
  , ownedHostCut
  , heldBody
  , boundaryExamples
  , boundaryControls
  , stalledSnapshots
  ) where

import Control.Concurrent (ThreadId, myThreadId, throwTo, yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, tryReadMVar)
import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , check
  , modifyTVar'
  , newTVarIO
  , readTVar
  , readTVarIO
  , writeTVar
  )
import Control.Exception
  ( AsyncException (UserInterrupt)
  , SomeException
  , finally
  , fromException
  , mask
  , throwIO
  , try
  , uninterruptibleMask_
  )
import Control.Monad (forM_, join, void, when)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Maybe (isNothing)
import GHC.Conc (BlockReason (BlockedOnException), ThreadStatus (..), threadStatus)
import Hetoimasia.Foundation.Log (Logger)
import Hetoimasia.Runtime.GLFW
import qualified Hetoimasia.Runtime.GLFW.Internal as Private
import Hetoimasia.GLFW.Internal.Seam (Seam)
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Test.GLFW.Owner.Fixture.Journal (Note (..), Scene, journalled)
import Test.GLFW.Owner.Fixture.Rig (Rig (..), ownedHostAt)
import Test.GLFW.Support
  ( Boom (..)
  , Scope
  , boundedExample
  , endedAndJoined
  , holdForever
  , recordingThreads
  , unexpected
  , withDeferredThreadVia
  )
import Test.Hspec (Expectation, Spec, it, shouldBe, shouldSatisfy)
import Test.Support.Owned (withOwnedThreadOpening)

-- | Where a run is cut.
data Boundary
  = BeforePublication
  | AfterStart
  | StartupCallback
  | BodyEntry
  deriving (Eq, Ord, Show, Enum, Bounded)

allBoundaries ∷ [Boundary]
allBoundaries = [minBound .. maxBound]

-- | How a run is cut at a boundary.
data CutState
  = -- | The boundary raises a failure of its own.
    CutFails
  | -- | A cancellation is queued for the run while it is masked and is received when it is next unmasked after the boundary.
    CutPending
  | -- | The run parks at the boundary and a cancellation is delivered to it there.
    CutDelivered
  deriving (Eq, Show, Enum, Bounded)

allStates ∷ [CutState]
allStates = [minBound .. maxBound]

-- | What a fixture is run under: where it is cut (nowhere, for an ordinary run), whether its own rescue is in force, the gate it
-- holds the owner at, and what the harness reads afterwards.
data Cutting = Cutting
  { cuttingBoundary ∷ !(Maybe Boundary)
  , cuttingAction ∷ IO ()
    -- ^ The cut itself, performed on the run's main thread at the boundary.
  , cuttingRescued ∷ !Bool
    -- ^ Whether the fixture's rescue is in force. The control runs the fixture without it.
  , cuttingGate ∷ !(TVar Bool)
    -- ^ The gate the fixture holds its owner at. A fixture takes it from here instead of creating its own, so the harness can open it
    -- from outside the run when the control must end.
  , cuttingRig ∷ !(IORef (Maybe Rig))
    -- ^ The fixture's rig, recorded by the fixture, so the harness can read its journal.
  , cuttingSnapshots ∷ !(TVar Int)
    -- ^ How many turns of the exit's wait for the owner's destruction have taken their snapshot.
  , cuttingCrossed ∷ !(IORef [Boundary])
    -- ^ Every boundary the run crossed, oldest first, recorded as it was reached and before the cut was performed there: the observed
    -- boundary of a cell, and the proof that a failure meant for a pre-callback boundary was not raised after the body began.
  , cuttingRelease ∷ !(IORef (IO ()))
    -- ^ What else the control does, besides opening the gate, to end a run the unrescued fixture stranded somewhere other than at
    -- its gate. A fixture that strands only there leaves it alone.
  }

-- | An ordinary run: no cut, the rescue in force.
uncut ∷ IO Cutting
uncut = do
  gate ← newTVarIO False
  rigs ← newIORef Nothing
  snapshots ← newTVarIO 0
  release ← newIORef (pure ())
  crossed ← newIORef []
  pure (Cutting Nothing (pure ()) True gate rigs snapshots crossed release)

-- | Build a cutting for one cell and run the body with it, inside the scope of the thread that delivers the cancellation.
-- The thread is owned: however the body ends it has been stopped and joined before this returns, and the thread is recorded so the
-- caller can judge it.
withCutting ∷ IORef [ThreadId] → CutState → Boundary → Bool → (Cutting → IO r) → IO r
withCutting recorded state boundary rescued body = do
  gate ← newTVarIO False
  rigs ← newIORef Nothing
  snapshots ← newTVarIO 0
  release ← newIORef (pure ())
  crossed ← newIORef []
  let scope ∷ Scope
      scope = recordingThreads recorded withOwnedThreadOpening
  withDeferredThreadVia scope (pure ()) (\target → throwTo target UserInterrupt) $ \helper handOver → do
    let cut = case state of
          CutFails → throwIO Boom
          CutDelivered → myThreadId >>= handOver >> holdForever
          -- Masked so the cancellation cannot be received before the boundary has been left: the thread that delivers it is blocked
          -- in its throw, which is the one state a cancellation can be pending in.
          CutPending → uninterruptibleMask_ (myThreadId >>= handOver >> awaitThrowing helper)
    body (Cutting (Just boundary) cut rescued gate rigs snapshots crossed release)

-- | Wait, by yielding, until the thread is blocked delivering its exception.
awaitThrowing ∷ ThreadId → IO ()
awaitThrowing thread =
  threadStatus thread >>= \case
    ThreadBlocked BlockedOnException → pure ()
    ThreadFinished → unexpected "the thread that delivers the cancellation ended before it was pending"
    ThreadDied → unexpected "the thread that delivers the cancellation died before it was pending"
    _ → yield >> awaitThrowing thread

-- | 'ownedHostAt' with the cutting's boundaries and its exit rescue. The cut is performed at its boundary and nowhere else. When the
-- rescue is in force the exit's wait for the owner's destruction opens the cutting's gate on every turn, whatever the run was cut in
-- the middle of, which is the earliest the exit can; the body's own rescue is 'heldBody'.
ownedHostCut
  ∷ Cutting
  → Private.HostHooks
  → Logger
  → Seam
  → HostConfig
  → GraphicsOwnerConfig Scene
  → (WindowHost → GraphicsOwner Scene → RuntimeControl → IO a)
  → IO a
ownedHostCut cutting hooks logger seam config ownerConfig action =
  ownedHostAt hooked (at StartupCallback) logger seam config ownerConfig $ \host owner control →
    at BodyEntry >> action host owner control
  where
    at boundary = do
      atomicModifyIORef' (cuttingCrossed cutting) (\crossed → (crossed <> [boundary], ()))
      when (cuttingBoundary cutting == Just boundary) (cuttingAction cutting)
    hooked =
      hooks
        { Private.ownerBoundary = \reached → do
            case reached of
              Private.OwnerBeforePublication → at BeforePublication
              Private.OwnerStarted → at AfterStart
            Private.ownerBoundary hooks reached
        , Private.afterDestructionSnapshot = do
            -- Opened before the snapshot is counted: a control that has seen the count has seen whether the gate was opened.
            when (cuttingRescued cutting) (atomically (writeTVar (cuttingGate cutting) True))
            atomically (modifyTVar' (cuttingSnapshots cutting) (+ 1))
            Private.afterDestructionSnapshot hooks
        }

-- | The body of a fixture that holds its owner at the cutting's gate: when the rescue is in force the gate is opened however the body
-- ends. The step is masked, so a cancellation cannot land between its being installed and the body's start; one that lands before it
-- (the body's entry) is the exit's to rescue.
heldBody ∷ Cutting → IO a → IO a
heldBody cutting body
  | cuttingRescued cutting = mask $ \restore → restore body `finally` open
  | otherwise = body
  where
    open = atomically (writeTVar (cuttingGate cutting) True)

-- | Wait until the exit's wait for the owner's destruction has taken at least this many snapshots.
stalledSnapshots ∷ Cutting → Int → STM ()
stalledSnapshots cutting count = readTVar (cuttingSnapshots cutting) >>= check . (>= count)

-- | The examples that cut one fixture at every boundary in every state. Each judges that the run raised what was injected and
-- nothing else, that the thread that delivered it has ended and been joined, that the owner terminated and was destroyed once the
-- gate it was held at was released, and that the session was torn down.
boundaryExamples ∷ String → (Cutting → IO ()) → Spec
boundaryExamples what fixture =
  forM_ allBoundaries $ \boundary →
    forM_ allStates $ \state →
      it (describeCut what boundary state <> " (#612)") $ boundedExample (cutRuns state boundary fixture)

-- | The negative controls for the cells where the fixture without its rescue strands (a held owner exists, which is every boundary
-- after the owner's handle was published): the unrescued fixture's exit waits for the held owner, which is recorded first, and only
-- then is the gate opened from outside the run and the run joined.
boundaryControls ∷ String → (Cutting → IO ()) → Spec
boundaryControls what fixture =
  forM_ [boundary | boundary ← allBoundaries, boundary /= BeforePublication] $ \boundary →
    forM_ allStates $ \state →
      it ("negative control: " <> describeCut what boundary state <> ", unrescued (#612)") $
        boundedExample (cutStrands state boundary fixture)

describeCut ∷ String → Boundary → CutState → String
describeCut what boundary state =
  "finishes the exit of " <> what <> " when the run " <> describeState state <> " " <> describeBoundary boundary
  where
    describeState = \case
      CutFails → "fails"
      CutPending → "is cancelled, the cancellation pending"
      CutDelivered → "is cancelled while parked"
    describeBoundary = \case
      BeforePublication → "before the owner's handle is published"
      AfterStart → "after the owner has started and before the start returns it"
      StartupCallback → "in the application's startup callback"
      BodyEntry → "at the body's entry, before its first masked step"

-- | What the injected cut raises, as itself.
raisedAsInjected ∷ CutState → SomeException → Bool
raisedAsInjected CutFails caught = fromException caught == Just Boom
raisedAsInjected _ caught = fromException caught == Just UserInterrupt

cutRuns ∷ CutState → Boundary → (Cutting → IO ()) → Expectation
cutRuns state boundary fixture = do
  recorded ← newIORef []
  withCutting recorded state boundary True $ \cutting → do
    outcome ← try (fixture cutting)
    case outcome of
      Right () → unexpected "the cut run returned instead of raising what was injected"
      Left caught → caught `shouldSatisfy` raisedAsInjected state
    -- The run reached the boundary it was cut at, having crossed every earlier one in order and none after it: a failure meant for a
    -- boundary before the body never became one raised by the body.
    readIORef (cuttingCrossed cutting) >>= (`shouldBe` [reached | reached ← allBoundaries, reached <= boundary])
    judgeFinished boundary cutting
  endedAndJoined recorded >>= (`shouldBe` True)

-- | The exit finished: the session is torn down, and an owner that was started has been destroyed after its gate was released.
judgeFinished ∷ Boundary → Cutting → IO ()
judgeFinished boundary cutting = do
  rig ← readIORef (cuttingRig cutting) >>= maybe (unexpected "the fixture recorded no rig") pure
  notes ← journalled (rigJournal rig)
  notes `shouldSatisfy` elem SessionEnded
  case boundary of
    BeforePublication → notes `shouldSatisfy` notElem OwnerStartup
    _ → do
      notes `shouldSatisfy` elem OwnerDestruction
      readTVarIO (cuttingGate cutting) >>= (`shouldBe` True)

cutStrands ∷ CutState → Boundary → (Cutting → IO ()) → Expectation
cutStrands state boundary fixture = do
  recorded ← newIORef []
  done ← newEmptyMVar @(Either SomeException ())
  withCutting recorded state boundary False $ \cutting → do
    let open = atomically (writeTVar (cuttingGate cutting) True)
    withOwnedThreadOpening open (try (fixture cutting) >>= putMVar done) $ \_ _ →
      ( do
          -- The exit is waiting for a destruction that cannot come: it has taken its first snapshot of the owner's terminal record, which
          -- holds no evidence, and its owner is held at its gate, so nothing can end the wait but the release below.
          atomically (stalledSnapshots cutting 1)
          stranded ← isNothing <$> tryReadMVar done
          rig ← readIORef (cuttingRig cutting) >>= maybe (unexpected "the fixture recorded no rig") pure
          notes ← journalled (rigJournal rig)
          gate ← readTVarIO (cuttingGate cutting)
          -- The judgement, recorded before anything is released: the owner is still held at its gate, which nothing opened, and the
          -- run has not finished.
          gate `shouldBe` False
          stranded `shouldBe` True
          -- Nothing was released while the owner was unfinished: the session is still open.
          notes `shouldSatisfy` notElem SessionEnded
        )
        `finally` ( do
                      -- The rescue that does not depend on the stuck exit: the gate opened from here, then the run joined.
                      open
                      join (readIORef (cuttingRelease cutting))
                      void (readMVar done)
                  )
