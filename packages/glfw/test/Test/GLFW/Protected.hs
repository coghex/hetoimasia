-- | Examples for the protected host lifetime and its owner-thread retirement
-- boundary, over the test seam.
--
-- Each example runs a whole application through
-- 'runProtectedWindowApplication' on a thread the seam treats as the process
-- main thread, with a protected host built over a seam session. The exit order,
-- the drain, the stall policy, and the outcome settling are the production
-- code, and nothing initializes GLFW.
--
-- Every example asserts an /order of flags/, never a time. One journal collects
-- them all: the scripted graphics owners note the obligations they end and the
-- dependents they dispose, the seam's own destroy and terminate hooks note the
-- native calls, and a scripted parent notes its release. One list therefore
-- shows admission closing, each chain retiring, each window being destroyed,
-- the session ending, and the parent being released, in the order they really
-- happened.
--
-- Threads are coordinated with STM and 'MVar's, never with a sleep. The seam's
-- finite wait blocks until an empty event has been posted, which is what the
-- session's internal wake does, so a drain round with nothing to do really
-- waits and a completion published from another thread really ends that wait.
module Test.GLFW.Protected (spec) where

import Control.Concurrent (ThreadId, forkIO, forkOS, killThread)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , check
  , modifyTVar'
  , newTVarIO
  , readTVar
  , readTVarIO
  , retry
  , writeTVar
  )
import Control.Exception
  ( AsyncException (ThreadKilled)
  , Exception
  , ExceptionWithContext
  , SomeException
  , fromException
  , throwIO
  , try
  )
import Control.Monad (forM_, void, when)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Hetoimasia.Foundation.Log
  ( Component
  , LogEntry (..)
  , Logger
  , callbackSink
  , componentText
  , defaultLogFilter
  , mkLoggerWith
  , systemMetadata
  , unsafeComponent
  )
import Hetoimasia.Foundation.Recovery (Disposition (..))
import Hetoimasia.Foundation.Resource (Scoped, allocResource, withScoped)
import Hetoimasia.Foundation.Worker (WorkerDefinition, awaitStopRequest, workerDefinition)
import Hetoimasia.GLFW.Internal.Attachment
  ( Acknowledgement
  , AttachmentEvidence (..)
  , AttachmentFailure (..)
  , AttachmentPhase (..)
  , AttachmentView (..)
  , NoticeAdmission (..)
  , RetirementFact (..)
  , RollbackOutcome (..)
  , acknowledgedAttachment
  , allRetirementFacts
  , completionNotice
  )
import Hetoimasia.GLFW.Internal.Seam
  ( NativeCall (DestroyWindow)
  , Seam
  , SeamScript (..)
  , asProcessMainThread
  , defaultScript
  , designateProcessMainThread
  , newSeam
  , seamCalls
  , seamSession
  )
import Hetoimasia.GLFW.Session (defaultSessionConfig)
import Hetoimasia.GLFW.Window
import Hetoimasia.Runtime.Application (runManagedApplication)
import Hetoimasia.Runtime.GLFW.Internal
import Hetoimasia.Runtime.GLFW.Internal.Retirement (publishCompletion)
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.Runtime.Supervision
  ( Recognition (..)
  , Role (..)
  , RuntimeControl
  , SupervisedStart (..)
  , SupervisedWorker
  , WorkerPolicy (..)
  , awaitSupervised
  , startSupervised
  )
import qualified Hetoimasia.Runtime.Supervision as Supervision
import Test.GLFW.Window (boundedExample, caughtAs, unexpected)
import Test.Hspec (Expectation, Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy)

spec ∷ Spec
spec = describe "GLFW protected host" $ do
  describe "exit paths" $ do
    it "retires its attachment, then destroys the window and ends the session, on a normal return"
      (boundedExample (testExitPath ReturnsNormally))
    it "keeps the action's failure primary and still retires before any window or session is released"
      (boundedExample (testExitPath ActionFails))
    it "retires after a failed startup, with its workers already drained"
      (boundedExample (testExitPath StartupFails))
    it "retires after the owner loop fails"
      (boundedExample (testExitPath LoopFails))
    it "retires after a latched supervised failure, which asked its workers to stop before quiescence"
      (boundedExample (testExitPath SupervisionLatches))
    it "retires before it re-raises a cancellation delivered to the action"
      (boundedExample testCancelledAction)
    it "retires after a dependent construction that failed before supervision was ever entered"
      (boundedExample testDependencyConstructionFails)

  describe "the host's own close" $ do
    it "closes attachment admission and retires even when the application installed no quiescence hook"
      (boundedExample testOmittedQuiescence)
    it "refuses an attachment to a host built with allocWindowHost, before any effect"
      (boundedExample testUnprotectedHostRefuses)

  describe "construction ownership" $ do
    it "retires a construction whose owned rollback established safety, publishing nothing usable"
      (boundedExample (testConstructionFailure RollbackSafe))
    it "retains a construction whose rollback could not, keeping its original failure and every owed fact"
      (boundedExample (testConstructionFailure RollbackUnsafe))
    it "enters no consumer, and attaches nothing, when the host's own setup fails"
      (boundedExample testHostSetupFails)
    it "counts a cancellation delivered during construction and still retires what it left registered"
      (boundedExample testCancelledConstruction)

  describe "the drain" $ do
    it "retains repeated cancellation as evidence, establishes no fact, and re-raises one only once retirement is safe"
      (boundedExample testRepeatedCancellation)
    it "destroys a safely retired chain's closed window while another chain, the session, and a parent are retained"
      (boundedExample testIndependentChains)
    it "keeps a stalled attachment and its window until independent evidence arrives, reporting the stall once"
      (boundedExample testStalledThenEvidence)
    it "retains a stalled diagnostic's own failure without unwinding anything it is holding"
      (boundedExample testStallDiagnosticFails)

  describe "failed retirement steps" $ do
    it "keeps a required step's failure and evidence, never marks the attachment safe, and never replays the step"
      (boundedExample (testFailedStep Required))
    it "leaves a recognized optional step unavailable with its evidence, which is still no permission to destroy"
      (boundedExample (testFailedStep Optional))

  describe "closing an attached window during the run" $
    it "begins retirement without destroying it, and destroys it only once every fact is certified"
      (boundedExample testEarlyClose)

-- ---------------------------------------------------------------------------
-- The journal

-- | The independent facts an example asserts the order of. Each is set by the
-- party that owns it: a scripted graphics owner, the seam's own native calls,
-- or a scripted parent's release.
data Flag
  = AdmissionClosed
    -- ^ A worker saw its attachment stop admitting new graphics use, with the
    -- windows still live and while the worker drain was still under way.
  | CpuUsesEnded !Text
  | WorkEnded !Text
  | PresentationSettled !Text
  | DependentsGone !Text
  | WindowGone !Int
    -- ^ The seam's own destroy call, named by the window's creation order.
  | SessionEnded
  | ParentReleased !Text
  deriving (Eq, Show)

-- | The flag one certified fact sets.
flagOf ∷ Text → RetirementFact → Flag
flagOf name = \case
  CpuUseRetired → CpuUsesEnded name
  SubmittedWorkEnded → WorkEnded name
  PresentationEnded → PresentationSettled name
  DependentsDisposed → DependentsGone name

note ∷ TVar [Flag] → Flag → STM ()
note journal flag = modifyTVar' journal (<> [flag])

-- | Every flag a whole retirement sets, in the order the owner sets them.
retiring ∷ Text → [Flag]
retiring name = map (flagOf name) allRetirementFacts

-- ---------------------------------------------------------------------------
-- The scripted graphics owner

-- | What one scripted opportunity does. A plan that runs out stalls, so an
-- example never silently retires an attachment it did not certify.
data Step
  = Certify !RetirementFact
    -- ^ Note the obligation's flag and certify the fact on the owner thread.
  | Await
    -- ^ No progress this round; the path is kept.
  | Stall
    -- ^ No safe progress path; the path is withdrawn.
  | FailWith !Text
  deriving (Eq, Show)

-- | What an example scripts one owner to do.
data OwnerScript = OwnerScript
  { scriptName ∷ Text
  , scriptConstruct ∷ IO ()
  , scriptRollback ∷ RollbackOutcome
  , scriptPlan ∷ [Step]
  , scriptDisposition ∷ Disposition
  , scriptRecognizes ∷ Bool
  }

-- | An owner that constructs without effect and certifies every fact, one per
-- opportunity.
ownerNamed ∷ Text → OwnerScript
ownerNamed name = OwnerScript name (pure ()) RollbackSafe (map Certify allRetirementFacts) Required False

-- | One attached scripted owner, as the example observes it.
data Owner = Owner
  { ownerName ∷ !Text
  , ownerAcknowledgement ∷ !(TVar (Maybe Acknowledgement))
    -- ^ Stored by the construction, so another thread can publish notices.
  , ownerPlan ∷ !(TVar [Step])
  , ownerStalls ∷ !(TVar Int)
  , ownerAwaits ∷ !(TVar Int)
  , ownerViews ∷ !(TVar [AttachmentView Evidence])
    -- ^ The view each certifying opportunity saw before it certified, so an
    -- example can assert the evidence an attachment carried while it was live.
  }

type Evidence = ExceptionWithContext SomeException

newtype Scripted = Scripted Text
  deriving (Eq, Show)

instance Exception Scripted

-- | Attach one scripted owner to a window of a protected host.
attachOwner ∷ TVar [Flag] → WindowHost → WindowId → OwnerScript → IO (Owner, AttachmentOutcome)
attachOwner journal host window script = do
  owner ←
    Owner (scriptName script)
      <$> newTVarIO Nothing
      <*> newTVarIO (scriptPlan script)
      <*> newTVarIO 0
      <*> newTVarIO 0
      <*> newTVarIO []
  outcome ← attachHostWindow host window (protocolFor journal host owner script)
  pure (owner, outcome)

-- | The one scripted owner established, or why it was not.
establishedOwner ∷ TVar [Flag] → WindowHost → WindowId → OwnerScript → IO Owner
establishedOwner journal host window script =
  attachOwner journal host window script >>= \case
    (owner, AttachmentEstablished _ _) → pure owner
    (_, other) → unexpected ("the attachment was not established: " <> show other)

protocolFor ∷ TVar [Flag] → WindowHost → Owner → OwnerScript → AttachmentProtocol
protocolFor journal host owner script =
  AttachmentProtocol
    { protocolConstruct = \_ acknowledgement → do
        atomically (writeTVar (ownerAcknowledgement owner) (Just acknowledgement))
        scriptConstruct script
    , protocolRollback = pure (scriptRollback script)
    , protocolStep = \target acknowledgement → do
        step ← atomically $ do
          plan ← readTVar (ownerPlan owner)
          case plan of
            [] → pure Stall
            next : rest → next <$ writeTVar (ownerPlan owner) rest
        perform target acknowledgement step
    , protocolDisposition = scriptDisposition script
    , protocolRecognizes = \_ → pure (scriptRecognizes script)
    }
  where
    perform target acknowledgement = \case
      Await → RetirementAwaiting <$ atomically (modifyTVar' (ownerAwaits owner) (+ 1))
      Stall → RetirementStalled <$ atomically (modifyTVar' (ownerStalls owner) (+ 1))
      FailWith message → throwIO (Scripted message)
      Certify fact → do
        atomically $ do
          seen ← hostAttachmentView host target
          forM_ seen (\view → modifyTVar' (ownerViews owner) (<> [view]))
          note journal (flagOf (ownerName owner) fact)
        void (reportHostRetirementFact host acknowledgement fact)
        pure RetirementAdvanced

-- | Publish an owner's certified facts from a thread that is not the owner.
-- Each admitted notice wakes the owner exactly as a command admission does.
publishFacts ∷ TVar [Flag] → WindowHost → Owner → [RetirementFact] → IO ()
publishFacts journal host owner facts = do
  publisher ← maybe (unexpected "the host publishes no completions") pure (hostCompletionPublisher host)
  acknowledgement ← atomically (readTVar (ownerAcknowledgement owner) >>= maybe retry pure)
  let target = acknowledgedAttachment acknowledgement
  forM_ facts $ \fact → do
    atomically (note journal (flagOf (ownerName owner) fact))
    publishCompletion publisher (completionNotice target acknowledgement fact) >>= \case
      NoticeRejectedFull → unexpected "the completion inbox refused a notice"
      _ → pure ()

-- | A supervised job that waits until its attachment stops admitting new
-- graphics use and notes it.
--
-- It proves the close happened with the windows live and while the workers were
-- still being drained, rather than during retirement: nothing in the drain can
-- run until this job has completed.
admissionWatcher ∷ TVar [Flag] → WindowHost → Owner → WorkerDefinition ()
admissionWatcher journal host owner =
  workerDefinition
    "renderer"
    (\_ → allocResource (pure ()) (\() → noteClosedAdmission journal host owner))
    (\token () → atomically (awaitStopRequest token))

-- | The worker's own release, which supervision runs while draining it: by then
-- the quiescence transaction has already committed, so the attachment must have
-- stopped admitting new graphics use. It waits for nothing.
noteClosedAdmission ∷ TVar [Flag] → WindowHost → Owner → IO ()
noteClosedAdmission journal host owner = atomically $ do
  held ← readTVar (ownerAcknowledgement owner)
  forM_ held $ \acknowledgement → do
    seen ← hostAttachmentView host (acknowledgedAttachment acknowledgement)
    case seen of
      Just view | viewPhase view == AttachmentActive → pure ()
      _ → note journal AdmissionClosed

-- ---------------------------------------------------------------------------
-- The seam and the runner

-- | A seam that journals its own destroy and terminate calls, so the native
-- lifetime appears in the same list as the flags the owners set.
--
-- Its finite wait blocks until an empty event has been posted, which is exactly
-- what the session's internal wake does, so a drain round with nothing to do
-- really waits and a completion published from another thread really ends it.
journallingSeam ∷ TVar [Flag] → IO Seam
journallingSeam = journallingSeamWaiting True

-- | 'journallingSeam' whose finite wait returns at once, for an example that
-- runs ordinary owner turns and would otherwise park in an idle turn's wait.
pollingSeam ∷ TVar [Flag] → IO Seam
pollingSeam = journallingSeamWaiting False

journallingSeamWaiting ∷ Bool → TVar [Flag] → IO Seam
journallingSeamWaiting blocking journal = do
  posts ← newTVarIO (0 ∷ Int)
  held ← newIORef Nothing
  seam ←
    newSeam
      defaultScript
        { scriptDestroyWindow = \_ → do
            destroyed ← readIORef held >>= maybe (pure 0) (fmap latestDestroyed . seamCalls)
            atomically (note journal (WindowGone destroyed))
        , scriptTerminate = \_ → atomically (note journal SessionEnded)
        , scriptWaitEvents = \_ _ →
            when blocking $
              atomically (readTVar posts >>= \pending → if pending <= 0 then retry else writeTVar posts (pending - 1))
        , scriptPostEmptyEvent = \_ → atomically (modifyTVar' posts (+ 1))
        }
  writeIORef held (Just seam)
  pure seam
  where
    -- The seam records the call before it runs this hook, so the last one
    -- recorded is the window being destroyed now.
    latestDestroyed calls = last (0 : [key | DestroyWindow key ← calls])

-- | Run one application over a protected host in the seam's session, on a bound
-- thread designated as the process main thread.
--
-- @inside@ runs inside the protected lifetime, after its exit handler is
-- installed and before the consumer is entered: it is where an example attaches
-- its owners and constructs dependents, exactly where an integration would.
protectedRun
  ∷ Seam
  → Logger
  → HostConfig
  → (WindowHost → IO ())
  → (WindowHost → RuntimeControl → IO s)
  → (s → RuntimeControl → IO a)
  → IO a
protectedRun seam logger config inside startup action =
  asProcessMainThread seam (protectedRunHere seam logger config inside startup action)

protectedRunHere
  ∷ Seam
  → Logger
  → HostConfig
  → (WindowHost → IO ())
  → (WindowHost → RuntimeControl → IO s)
  → (s → RuntimeControl → IO a)
  → IO a
protectedRunHere seam logger config inside startup action =
  runProtectedWindowApplication
    (withLoggingLifetime logger)
    "protected-host-example"
    (\_ use → protectedHost seam logger config (\host → inside host >> use host))
    id
    startup
    action

protectedHost ∷ Seam → Logger → HostConfig → (WindowHost → IO r) → IO r
protectedHost seam logger config =
  withProtectedWindowHostIn logger (seamSession seam defaultSessionConfig) config

-- ---------------------------------------------------------------------------
-- Exit paths

-- | The exits the protected boundary covers that differ only in how the
-- consumer ends.
data ExitPath
  = ReturnsNormally
  | ActionFails
  | StartupFails
  | LoopFails
  | SupervisionLatches
  deriving (Eq, Show)

testExitPath ∷ ExitPath → Expectation
testExitPath path = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  owned ← newTVarIO Nothing
  outcome ←
    try $
      protectedRun
        seam
        quietLogger
        (settings [windowNamed "alpha"])
        (attaching journal owned)
        ( \host control → do
            owner ← heldOwner owned
            void (startSupervised control workerPolicy (admissionWatcher journal host owner) >>= started)
            case path of
              StartupFails → throwIO (Scripted "startup")
              SupervisionLatches → do
                void (startSupervised control workerPolicy breaking >>= started)
                awaitSupervised control retry
              _ → pure ()
            pure host
        )
        ( \host control → case path of
            ActionFails → throwIO (Scripted "action")
            LoopFails →
              runOwnerLoop host control $
                LoopHooks
                  { loopLogger = quietLogger
                  , loopEvent = noApplicationEvents
                  , loopUpdate = \_ → throwIO (Scripted "owner loop")
                  }
            _ → pure ()
        )
  case (path, outcome ∷ Either SomeException ()) of
    (ReturnsNormally, Right ()) → pure ()
    (ReturnsNormally, Left caught) → unexpected ("the run failed: " <> show caught)
    (_, Left _) → pure ()
    (_, Right ()) → unexpected "the failing run returned"
  readTVarIO journal `shouldReturn` ([AdmissionClosed] <> retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | Attach one owner named @alpha@ inside the protected lifetime and stash it.
attaching ∷ TVar [Flag] → TVar (Maybe Owner) → WindowHost → IO ()
attaching journal owned host = do
  window ← onlyWindow host
  owner ← establishedOwner journal host window (ownerNamed "alpha")
  atomically (writeTVar owned (Just owner))

heldOwner ∷ TVar (Maybe Owner) → IO Owner
heldOwner owned = readTVarIO owned >>= maybe (unexpected "no owner was attached") pure

testCancelledAction ∷ Expectation
testCancelledAction = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  owned ← newTVarIO Nothing
  inside ← newEmptyMVar
  never ← newEmptyMVar
  (runner, finished) ←
    onMainThread seam $
      protectedRunHere
        seam
        quietLogger
        (settings [windowNamed "alpha"])
        (attaching journal owned)
        ( \host control → do
            owner ← heldOwner owned
            void (startSupervised control workerPolicy (admissionWatcher journal host owner) >>= started)
        )
        (\() _ → putMVar inside () >> takeMVar never)
  takeMVar inside
  killThread runner
  takeMVar finished >>= \case
    Left caught → (fromException caught ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled
    Right () → unexpected "the cancelled run returned"
  readTVarIO journal `shouldReturn` ([AdmissionClosed] <> retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | A dependent construction that fails after the host is built never enters
-- supervision, so no quiescence hook exists and no worker is drained. The
-- protected host still closes attachment admission itself and retires what the
-- construction left registered.
testDependencyConstructionFails ∷ Expectation
testDependencyConstructionFails = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  entered ← newIORef False
  (failure, _) ←
    caughtAs $
      protectedRun
        seam
        quietLogger
        (settings [windowNamed "alpha"])
        ( \host → do
            window ← onlyWindow host
            void (establishedOwner journal host window (ownerNamed "alpha"))
            throwIO (Scripted "dependent")
        )
        (\_ _ → writeIORef entered True)
        (\() _ → pure ())
  failure `shouldBe` Scripted "dependent"
  readIORef entered `shouldReturn` False
  readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- ---------------------------------------------------------------------------
-- The host's own close

-- | The runner's own quiescence hook is what closes admission before the worker
-- drain. An application that installs none still cannot leave an attachment
-- admitting new use: the protected host closes it itself on the way out, and
-- the retirement facts an owner then certifies prove it, because the model
-- refuses every one of them before retirement has begun.
testOmittedQuiescence ∷ Expectation
testOmittedQuiescence = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  pending ← newIORef []
  asProcessMainThread seam $
    runManagedApplication
      (withLoggingLifetime quietLogger)
      "protected-host-example"
      ( \use →
          protectedHost seam quietLogger (settings [windowNamed "alpha"]) $ \host → do
            window ← onlyWindow host
            void (establishedOwner journal host window (ownerNamed "alpha"))
            use host
      )
      -- No quiescence: the application omits the host entirely.
      (\_ → pure ())
      (\host _ → pure host)
      ( \host _ → do
          held ← atomically (hostPendingAttachments host)
          writeIORef pending held
      )
  held ← readIORef pending
  length held `shouldBe` 1
  readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | A host built by 'allocWindowHost' is issued no attachment identity, so a
-- registration against it is refused before any effect and nothing is retired.
testUnprotectedHostRefuses ∷ Expectation
testUnprotectedHostRefuses = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  refused ← newIORef Nothing
  asProcessMainThread seam $
    runWindowApplication
      (withLoggingLifetime quietLogger)
      "host-example"
      (allocWindowHostIn (seamSession seam defaultSessionConfig) (settings [windowNamed "alpha"]))
      id
      ( \host _ → do
          hostAttachmentIdentity host `shouldSatisfy` \case
            Nothing → True
            Just _ → False
          window ← onlyWindow host
          (_, outcome) ← attachOwner journal host window (ownerNamed "alpha")
          writeIORef refused (Just outcome)
          atomically (hostPendingAttachments host) `shouldReturn` []
      )
      (\() _ → pure ())
  readIORef refused >>= \case
    Just AttachmentHostUnprotected → pure ()
    other → unexpected ("the unprotected host did not refuse: " <> show other)
  readTVarIO journal `shouldReturn` [WindowGone 1, SessionEnded]

-- ---------------------------------------------------------------------------
-- Construction ownership

testConstructionFailure ∷ RollbackOutcome → Expectation
testConstructionFailure rollback = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  answered ← newIORef Nothing
  observed ← newIORef Nothing
  asProcessMainThread seam $
    runProtectedWindowApplication
      (withLoggingLifetime quietLogger)
      "protected-host-example"
      ( \_ use →
          protectedHost seam quietLogger (settings [windowNamed "alpha"]) $ \host → do
            window ← onlyWindow host
            (_, outcome) ←
              attachOwner
                journal
                host
                window
                (ownerNamed "alpha") {scriptConstruct = throwIO (Scripted "construction"), scriptRollback = rollback}
            writeIORef answered (Just outcome)
            held ← atomically (hostPendingAttachments host)
            views ← traverse (atomically . hostAttachmentView host) held
            writeIORef observed (Just (length held, concatMap (maybe [] pure) views))
            use host
      )
      id
      (\host _ → pure host)
      (\_ _ → pure ())
  readIORef answered >>= \case
    Just (AttachmentRolledBack _ answeredRollback) → answeredRollback `shouldBe` rollback
    other → unexpected ("the construction failure was not answered: " <> show other)
  (count, views) ← readIORef observed >>= maybe (unexpected "nothing was observed") pure
  case rollback of
    RollbackSafe → do
      -- A safe rollback discharged every obligation the construction never
      -- created: nothing is left to retire, and nothing usable was published.
      count `shouldBe` 0
      readTVarIO journal `shouldReturn` [WindowGone 1, SessionEnded]
    RollbackUnsafe → do
      count `shouldBe` 1
      map viewMissing views `shouldBe` [allRetirementFacts]
      map (constructionEvidence . viewEvidence) views `shouldBe` [Just rollback]
      readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

constructionEvidence ∷ AttachmentEvidence Evidence → Maybe RollbackOutcome
constructionEvidence evidence = case evidenceFirstFailure evidence of
  Just (ConstructionFailure _ outcome) → Just outcome
  _ → Nothing

-- | A configuration the host itself refuses leaves no consumer to enter and no
-- attachment to make.
testHostSetupFails ∷ Expectation
testHostSetupFails = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  attached ← newIORef False
  begun ← newIORef False
  (rejection, _) ←
    caughtAs $
      protectedRun
        seam
        quietLogger
        (settings [windowNamed "alpha", windowNamed "bad\NUL"])
        (\_ → writeIORef attached True)
        (\_ _ → writeIORef begun True)
        (\() _ → pure ())
  rejection `shouldBe` WindowTitleRejected
  readIORef attached `shouldReturn` False
  readIORef begun `shouldReturn` False
  readTVarIO journal `shouldReturn` [WindowGone 1, SessionEnded]

-- | A cancellation delivered inside a construction is counted as the
-- attachment's evidence, establishes no fact, and leaves nothing outside
-- registration: the drain still retires what the construction left behind.
testCancelledConstruction ∷ Expectation
testCancelledConstruction = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  constructing ← newEmptyMVar
  never ← newEmptyMVar
  (runner, finished) ←
    onMainThread seam $
      protectedRunHere
        seam
        quietLogger
        (settings [windowNamed "alpha"])
        ( \host → do
            window ← onlyWindow host
            void $
              attachOwner
                journal
                host
                window
                (ownerNamed "alpha")
                  { scriptConstruct = putMVar constructing () >> takeMVar never
                  , scriptRollback = RollbackUnsafe
                  }
        )
        (\_ _ → pure ())
        (\() _ → pure ())
  takeMVar constructing
  killThread runner
  takeMVar finished >>= \case
    Left caught → (fromException caught ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled
    Right () → unexpected "the cancelled construction returned"
  readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- ---------------------------------------------------------------------------
-- The drain

-- | Cancellation during the drain is deferred: it is counted against every
-- pending attachment, establishes no fact, releases nothing, and is re-raised
-- only once the last fact has been certified.
testRepeatedCancellation ∷ Expectation
testRepeatedCancellation = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  owned ← newTVarIO Nothing
  (runner, finished) ←
    onMainThread seam $
      protectedRunHere
        seam
        quietLogger
        (settings [windowNamed "alpha"])
        ( \host → do
            window ← onlyWindow host
            owner ←
              establishedOwner
                journal
                host
                window
                (ownerNamed "alpha") {scriptPlan = [Await, Await] <> map Certify allRetirementFacts}
            atomically (writeTVar owned (Just owner))
        )
        (\_ _ → pure ())
        (\() _ → pure ())
  owner ← awaitHeld owned
  -- Each cancellation is delivered while the drain is inside a finite wait it
  -- has no progress to skip, which is where the deferral must hold.
  forM_ [1 .. 2 ∷ Int] $ \round' → do
    atomically (readTVar (ownerAwaits owner) >>= check . (>= round'))
    killThread runner
  takeMVar finished >>= \case
    Left caught → (fromException caught ∷ Maybe AsyncException) `shouldBe` Just ThreadKilled
    Right () → unexpected "the cancelled drain returned"
  seen ← readTVarIO (ownerViews owner)
  map viewPhase (take 1 seen) `shouldBe` [AttachmentRetiring]
  map (evidenceCancellations . viewEvidence) (take 1 seen) `shouldSatisfy` \case
    [counted] → counted >= 2
    _ → False
  map viewMissing (take 1 seen) `shouldBe` [allRetirementFacts]
  readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- | Wait for a value another thread publishes, parked in a transaction rather
-- than spinning: a busy loop here would keep a capability from ever reaching a
-- safe point.
awaitHeld ∷ TVar (Maybe a) → IO a
awaitHeld held = atomically (readTVar held >>= maybe retry pure)

-- | Two chains, one of which cannot retire. The chain that can retires, and its
-- closed window is destroyed, while the other chain's window, the session they
-- share, and a parent borrowed outside the protected lifetime all stay live.
testIndependentChains ∷ Expectation
testIndependentChains = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  betaHeld ← newTVarIO Nothing
  hostHeld ← newTVarIO Nothing
  -- Beta's independent evidence arrives only once alpha's chain is already
  -- safe and its own window destroyed, so the order below is the order the
  -- boundary produced and not one the example imposed.
  helper ← forkIO (supplyEvidence journal hostHeld betaHeld (afterAlphaDestroyed journal) allRetirementFacts)
  asProcessMainThread seam $
    runProtectedWindowApplication
      (withLoggingLifetime quietLogger)
      "protected-host-example"
      ( \_ use →
          withScoped (scriptedParent journal "parent") $ \() →
            protectedHost seam quietLogger (settings [windowNamed "alpha", windowNamed "beta"]) $ \host → do
              (alpha, beta) ← twoWindows host
              void (establishedOwner journal host alpha (ownerNamed "alpha"))
              betaOwner ← establishedOwner journal host beta (ownerNamed "beta") {scriptPlan = [Stall]}
              atomically (writeTVar betaHeld (Just betaOwner))
              atomically (writeTVar hostHeld (Just host))
              use host
      )
      id
      (\host _ → pure host)
      ( \host _ → do
          -- The chain that can retire is closed during the run, so its own
          -- window is destroyed as soon as it is safe, and not before.
          (alpha, _) ← twoWindows host
          closeHostWindow host alpha `shouldReturn` CloseStarted
      )
  void (pure helper)
  readTVarIO journal
    `shouldReturn` ( retiring "alpha"
                   <> [WindowGone 1]
                   <> retiring "beta"
                   <> [WindowGone 2, SessionEnded, ParentReleased "parent"]
               )

-- | Once the owner has declared its stall, publish its certified facts from
-- another thread. Each notice wakes the owner out of its finite wait.
supplyEvidence
  ∷ TVar [Flag]
  → TVar (Maybe WindowHost)
  → TVar (Maybe Owner)
  → (Owner → STM ())
  → [RetirementFact]
  → IO ()
supplyEvidence journal hostHeld owned ready facts = do
  owner ← awaitHeld owned
  host ← awaitHeld hostHeld
  atomically (ready owner)
  publishFacts journal host owner facts

-- | The owner has declared it has no safe progress path.
afterStall ∷ Owner → STM ()
afterStall owner = readTVar (ownerStalls owner) >>= check . (> 0)

-- | Alpha's chain is safe and its own closed window has already been destroyed.
afterAlphaDestroyed ∷ TVar [Flag] → Owner → STM ()
afterAlphaDestroyed journal _ = readTVar journal >>= \flags → check (WindowGone 1 `elem` flags)

-- | A parent borrowed outside the protected lifetime, which may not be released
-- until every dependent is safe.
scriptedParent ∷ TVar [Flag] → Text → Scoped ()
scriptedParent journal name = allocResource (pure ()) (\() → atomically (note journal (ParentReleased name)))

-- | An attachment with no safe progress path keeps its window, the session, and
-- every parent, reports the stall exactly once, and finishes when independent
-- evidence arrives.
testStalledThenEvidence ∷ Expectation
testStalledThenEvidence = do
  journal ← newTVarIO []
  entries ← newIORef []
  seam ← journallingSeam journal
  owned ← newTVarIO Nothing
  hostHeld ← newTVarIO Nothing
  helper ← forkIO (supplyEvidence journal hostHeld owned afterStall allRetirementFacts)
  let logger = recordingLogger entries
  asProcessMainThread seam $
    runProtectedWindowApplication
      (withLoggingLifetime logger)
      "protected-host-example"
      ( \_ use →
          protectedHost seam logger (settings [windowNamed "alpha"]) $ \host → do
            window ← onlyWindow host
            owner ← establishedOwner journal host window (ownerNamed "alpha") {scriptPlan = [Stall]}
            atomically (writeTVar owned (Just owner))
            atomically (writeTVar hostHeld (Just host))
            use host
      )
      id
      (\host _ → pure host)
      (\_ _ → pure ())
  void (pure helper)
  readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])
  stallReports entries `shouldReturn` 1

-- | The stall diagnostic is claimed once, and its own failure may not unwind
-- what the stall is retaining: the window is destroyed only after the evidence
-- arrives, and the diagnostic's failure becomes the run's outcome afterwards.
testStallDiagnosticFails ∷ Expectation
testStallDiagnosticFails = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  owned ← newTVarIO Nothing
  hostHeld ← newTVarIO Nothing
  helper ← forkIO (supplyEvidence journal hostHeld owned afterStall allRetirementFacts)
  let logger = failingLogger "glfw.retirement"
  (failure, _) ←
    caughtAs . asProcessMainThread seam $
      runProtectedWindowApplication
        (withLoggingLifetime logger)
        "protected-host-example"
        ( \_ use →
            protectedHost seam logger (settings [windowNamed "alpha"]) $ \host → do
              window ← onlyWindow host
              owner ← establishedOwner journal host window (ownerNamed "alpha") {scriptPlan = [Stall]}
              atomically (writeTVar owned (Just owner))
              atomically (writeTVar hostHeld (Just host))
              use host
        )
        id
        (\host _ → pure host)
        (\_ _ → pure ())
  void (pure helper)
  failure `shouldBe` Scripted "sink"
  readTVarIO journal `shouldReturn` (retiring "alpha" <> [WindowGone 1, SessionEnded])

-- ---------------------------------------------------------------------------
-- Failed retirement steps

-- | A failed step keeps its evidence, withdraws the attachment's progress path
-- rather than replaying it, and never makes the attachment safe. A required
-- failure fails the application; a recognized optional one leaves the component
-- unavailable — and neither is permission to destroy the dependent.
testFailedStep ∷ Disposition → Expectation
testFailedStep disposition = do
  journal ← newTVarIO []
  seam ← journallingSeam journal
  owned ← newTVarIO Nothing
  hostHeld ← newTVarIO Nothing
  helper ← forkIO (supplyEvidence journal hostHeld owned afterFailedStep [CpuUseRetired])
  outcome ←
    try . asProcessMainThread seam $
      runProtectedWindowApplication
        (withLoggingLifetime quietLogger)
        "protected-host-example"
        ( \_ use →
            protectedHost seam quietLogger (settings [windowNamed "alpha"]) $ \host → do
              window ← onlyWindow host
              owner ←
                establishedOwner
                  journal
                  host
                  window
                  (ownerNamed "alpha")
                    { scriptPlan = FailWith "disposal" : map Certify allRetirementFacts
                    , scriptDisposition = disposition
                    , scriptRecognizes = disposition == Optional
                    }
              atomically (writeTVar owned (Just owner))
              atomically (writeTVar hostHeld (Just host))
              use host
        )
        id
        (\host _ → pure host)
        (\_ _ → pure ())
  void (pure helper)
  owner ← awaitHeld owned
  seen ← readTVarIO (ownerViews owner)
  -- The step ran once, its evidence is the attachment's, and the only fact it
  -- no longer owed by the next opportunity is the one the notice certified.
  map (disposalEvidence . viewEvidence) (take 1 seen) `shouldBe` [True]
  map viewMissing (take 1 seen) `shouldBe` [filter (/= CpuUseRetired) allRetirementFacts]
  readTVarIO (ownerPlan owner) `shouldReturn` []
  -- The notice certifies CPU-use retirement; the revived plan then certifies
  -- every fact, the first of which the model has already recorded.
  readTVarIO journal
    `shouldReturn` ([CpuUsesEnded "alpha"] <> retiring "alpha" <> [WindowGone 1, SessionEnded])
  case (disposition, outcome ∷ Either SomeException ()) of
    (Required, Left caught) → (fromException caught ∷ Maybe Scripted) `shouldBe` Just (Scripted "disposal")
    (Required, Right ()) → unexpected "the required failure did not fail the run"
    (Optional, Right ()) → pure ()
    (Optional, Left caught) → unexpected ("the optional failure failed the run: " <> show caught)

-- | The independent safe evidence that revives a withdrawn progress path: one
-- certified fact, published from a thread that is not the owner, once the step
-- that failed has been taken and withdrawn.
-- | The step that fails has been taken, so its path has been withdrawn.
afterFailedStep ∷ Owner → STM ()
afterFailedStep owner = readTVar (ownerPlan owner) >>= \plan → check (FailWith "disposal" `notElem` plan)

disposalEvidence ∷ AttachmentEvidence Evidence → Bool
disposalEvidence evidence = case evidenceFirstFailure evidence of
  Just (DisposalFailure _) → True
  _ → False

-- ---------------------------------------------------------------------------
-- Closing an attached window during the run

-- | Closing an attached window begins its retirement and destroys nothing. The
-- window stays alive — with its close acknowledged — until every one of its
-- attachment's facts is certified, and a later owner turn then destroys it.
testEarlyClose ∷ Expectation
testEarlyClose = do
  journal ← newTVarIO []
  seam ← pollingSeam journal
  owned ← newTVarIO Nothing
  whileRetiring ← newIORef Nothing
  afterSafety ← newIORef Nothing
  asProcessMainThread seam $
    runProtectedWindowApplication
      (withLoggingLifetime quietLogger)
      "protected-host-example"
      ( \_ use →
          protectedHost seam quietLogger (settings [windowNamed "alpha"]) $ \host → do
            window ← onlyWindow host
            owner ← establishedOwner journal host window (ownerNamed "alpha") {scriptPlan = []}
            atomically (writeTVar owned (Just owner))
            use host
      )
      id
      (\host _ → pure host)
      ( \host control → do
          window ← onlyWindow host
          owner ← heldOwner owned
          acknowledgement ← atomically (readTVar (ownerAcknowledgement owner) >>= maybe retry pure)
          runOwnerLoop host control $
            LoopHooks
              { loopLogger = quietLogger
              , loopEvent = noApplicationEvents
              , loopUpdate = \turn → case turnNumber turn of
                  1 → Continue <$ (closeHostWindow host window `shouldReturn` CloseStarted)
                  2 → do
                    -- The close is acknowledged and the attachment is retiring,
                    -- but the window is not destroyed: its attachment vetoes it.
                    destroyed ← destroyedWindows seam
                    writeIORef whileRetiring (Just destroyed)
                    forM_ allRetirementFacts (void . reportHostRetirementFact host acknowledgement)
                    pure Continue
                  3 → pure Continue
                  _ → do
                    destroyed ← destroyedWindows seam
                    writeIORef afterSafety (Just destroyed)
                    pure (Finish ())
              }
      )
  readIORef whileRetiring `shouldReturn` Just []
  readIORef afterSafety `shouldReturn` Just [1]
  readTVarIO journal `shouldReturn` [WindowGone 1, SessionEnded]

destroyedWindows ∷ Seam → IO [Int]
destroyedWindows seam = (\calls → [key | DestroyWindow key ← calls]) <$> seamCalls seam

-- ---------------------------------------------------------------------------
-- Support

settings ∷ [WindowConfig] → HostConfig
settings windows =
  (defaultHostConfig windows)
    { hostCommandCapacity = 8
    , hostCommandBudget = 3
    , hostEventBudget = 2
    , hostIdleWait = 0.25
    }

windowNamed ∷ Text → WindowConfig
windowNamed name = hiddenTestWindowConfig name 64 48

onlyWindow ∷ WindowHost → IO WindowId
onlyWindow host =
  atomically (hostWindowIdentities host) >>= \case
    [identity] → pure identity
    windows → unexpected ("expected one window, found " <> show (length windows))

twoWindows ∷ WindowHost → IO (WindowId, WindowId)
twoWindows host =
  atomically (hostWindowIdentities host) >>= \case
    [alpha, beta] → pure (alpha, beta)
    windows → unexpected ("expected two windows, found " <> show (length windows))

quietLogger ∷ Logger
quietLogger = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\_ → pure ()))

recordingLogger ∷ IORef [LogEntry] → Logger
recordingLogger entries =
  mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\entry → modifyIORef' entries (<> [entry])))

-- | A logger whose sink fails for one component's entries alone.
failingLogger ∷ Text → Logger
failingLogger component =
  mkLoggerWith defaultLogFilter systemMetadata . callbackSink $ \entry →
    when (componentText (entryComponent entry) == component) (throwIO (Scripted "sink"))

stallReports ∷ IORef [LogEntry] → IO Int
stallReports entries =
  length . filter ((== "glfw.retirement") . componentText . entryComponent) <$> readIORef entries

-- | Run an action on a new bound thread designated as the process main thread,
-- so an example can cancel it.
onMainThread ∷ ∀ a. Seam → IO a → IO (ThreadId, MVar (Either SomeException a))
onMainThread seam action = do
  finished ← newEmptyMVar
  runner ← forkOS (designateProcessMainThread seam >> (try action ∷ IO (Either SomeException a)) >>= putMVar finished)
  pure (runner, finished)

workerPolicy ∷ WorkerPolicy
workerPolicy = WorkerPolicy Job Supervision.Required testComponent (\_ → pure Unrecognized)

testComponent ∷ Component
testComponent = unsafeComponent "test.protected"

started ∷ SupervisedStart r → IO (SupervisedWorker r)
started = \case
  WorkerStarted worker → pure worker
  WorkerStartUnavailable _ _ → unexpected "the worker was unavailable"
  WorkerStartRejected → unexpected "the worker's start was rejected"

breaking ∷ WorkerDefinition ()
breaking = workerDefinition "breaker" (\_ → pure ()) (\_ () → throwIO (Scripted "worker"))
