-- | Ownership, cancellation and cleanup: a root closes only after every
-- operation borrowing it has retired; every descriptor is closed exactly once
-- on every path, whatever interrupts the operation; cleanup failures are
-- retained beside the primary failure; and repeated work leaves nothing behind.
--
-- Each scenario holds a real operation at a named boundary with a 'Pause',
-- changes the world, and lets it go; none sleeps. The accounting reads the
-- recording seam's log, so it counts only this service's own acquisitions and
-- closes, never process-wide descriptor totals.
module Test.Content.Lifecycle (spec) where

import Control.Concurrent (killThread, yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , ExceptionWithContext (ExceptionWithContext)
  , fromException
  )
import Control.Monad (forM_, replicateM_)
import qualified Data.ByteString as BS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (elemIndex)
import GHC.Conc (BlockReason (BlockedOnException), ThreadStatus (ThreadBlocked, ThreadFinished), threadStatus)
import Hetoimasia.Content
import Hetoimasia.Content.Internal.Gate (borrowCount)
import Hetoimasia.Content.Internal.Native
import Hetoimasia.Content.Internal.Root (ContentRoot (rootGate))
import Hetoimasia.Foundation.Resource (cleanupFailures)
import System.Directory (createDirectory)
import System.FilePath ((</>))
import Test.Content.Support
import Test.Hspec
import Test.Support.Bounded (bounded)

lifecycleTree ∷ (FilePath → IO a) → IO a
lifecycleTree use = withTree $ \tree → do
  let root = tree </> "root"
  createDirectory root
  createDirectory (root </> "dir")
  writeBytes (root </> "file.bin") "0123456789"
  writeBytes (root </> "dir" </> "inner.bin") "inner"
  use root

readFirst ∷ ContentRoot → [BS.ByteString] → IO BS.ByteString
readFirst root path = withFile root (names path) $ \reader → readChunk reader 4

-- | The descriptor the root was opened as: the first thing the log acquired.
rootDescriptor ∷ [Event] → Int
rootDescriptor log' = case [fd | Opened fd "<root>" ← log'] of
  fd : _ → fd
  [] → -1

positionOf ∷ Event → [Event] → Int
positionOf event log' = maybe (-1) id (elemIndex event log')

-- | Wait until the thread that is cancelling another has its exception pending:
-- blocked in 'killThread', which returns only once the exception is delivered.
awaitPendingThrow ∷ Child a → IO ()
awaitPendingThrow thrower = bounded loop
  where
    loop = do
      status ← threadStatus (childThread thrower)
      case status of
        ThreadBlocked BlockedOnException → pure ()
        ThreadFinished → expectationFailure "the cancelling thread finished before its exception was pending"
        _ → yield *> loop

-- | Hold the calling thread, without any interruptible operation, until the
-- thread cancelling it has its exception pending: the cancellation is then
-- requested while the caller is still inside the step that acquired a handle.
spinUntilCancelling ∷ IORef (Maybe (Child a)) → IO ()
spinUntilCancelling ref = do
  killer ← readIORef ref
  case killer of
    Nothing → yield *> spinUntilCancelling ref
    Just child → do
      status ← threadStatus (childThread child)
      case status of
        ThreadBlocked BlockedOnException → pure ()
        _ → yield *> spinUntilCancelling ref

spec ∷ Spec
spec = do
  describe "the root's exit" $ do
    it "waits for a paused operation, refuses new ones, and closes the root only after it retires" $
      lifecycleTree $ \path → do
        (recorded, rig) ← recordingSeam
        pause ← newPause
        drainStarted ← newEmptyMVar
        rootVar ← newEmptyMVar
        opVar ← newEmptyMVar
        let seam = onBoundary (announce drainStarted) (pauseWhen (== BeforeRead) pause recorded)
        owner ← spawn $ withRootVia seam defaultContentLimits path $ \root → do
          putMVar rootVar root
          operation ← spawn (readFirst root ["file.bin"])
          putMVar opVar operation
          awaitReached pause
        root ← bounded (takeMVar rootVar)
        bounded (takeMVar drainStarted)
        isFinished owner `shouldReturn` False
        borrowCount (rootGate root) `shouldReturn` 1
        ExceptionWithContext _ refused ← failsWith (readFirst root ["file.bin"])
        refused `shouldBe` ContentDefect RootNotAdmitting
        beforeResume ← events rig
        Closed (rootDescriptor beforeResume) `shouldNotSatisfy` (`elem` beforeResume)
        resumePaused pause
        awaitChild owner
        operation ← bounded (takeMVar opVar)
        awaitChild operation `shouldReturn` "0123"
        afterExit ← events rig
        let closedAt = positionOf (Closed (rootDescriptor afterExit)) afterExit
        positionOf (Boundary DrainStarted) afterExit `shouldSatisfy` (< closedAt)
        positionOf (Boundary AfterRead) afterExit `shouldSatisfy` (< closedAt)
        length (filter (== Closed (rootDescriptor afterExit)) afterExit) `shouldBe` 1
        _ ← asserting rig
        borrowCount (rootGate root) `shouldReturn` 0

    it "does not let a cancellation of the exiting thread shorten the wait, and delivers it afterwards" $
      lifecycleTree $ \path → do
        (recorded, rig) ← recordingSeam
        pause ← newPause
        drainStarted ← newEmptyMVar
        opVar ← newEmptyMVar
        let seam = onBoundary (announce drainStarted) (pauseWhen (== BeforeRead) pause recorded)
        owner ← spawn $ withRootVia seam defaultContentLimits path $ \root → do
          operation ← spawn (readFirst root ["file.bin"])
          putMVar opVar operation
          awaitReached pause
        bounded (takeMVar drainStarted)
        killer ← spawn (killThread (childThread owner))
        awaitPendingThrow killer
        isFinished owner `shouldReturn` False
        isFinished killer `shouldReturn` False
        mid ← events rig
        Closed (rootDescriptor mid) `shouldNotSatisfy` (`elem` mid)
        resumePaused pause
        outcome ← awaitOutcome owner
        awaitDone killer
        case outcome of
          Left exception → fromException exception `shouldBe` Just ThreadKilled
          Right _ → expectationFailure "the exiting thread's cancellation was not delivered"
        operation ← bounded (takeMVar opVar)
        awaitChild operation `shouldReturn` "0123"
        final ← events rig
        length (filter (== Closed (rootDescriptor final)) final) `shouldBe` 1
        positionOf (Boundary AfterRead) final `shouldSatisfy` (< positionOf (Closed (rootDescriptor final)) final)
        _ ← asserting rig
        pure ()

    it "retains a root close failure as evidence beside the delivered cancellation" $
      lifecycleTree $ \path → do
        (recorded, rig) ← recordingSeam
        counter ← newIORef 0
        pause ← newPause
        drainStarted ← newEmptyMVar
        opVar ← newEmptyMVar
        -- closes: 1 the qualification probe, 2 the operation's file, 3 the root
        let seam = failNthClose counter 3 28 (onBoundary (announce drainStarted) (pauseWhen (== BeforeRead) pause recorded))
        owner ← spawn $ withRootVia seam defaultContentLimits path $ \root → do
          operation ← spawn (readFirst root ["file.bin"])
          putMVar opVar operation
          awaitReached pause
        bounded (takeMVar drainStarted)
        killer ← spawn (killThread (childThread owner))
        awaitPendingThrow killer
        resumePaused pause
        outcome ← awaitOutcome owner
        awaitDone killer
        case outcome of
          Left exception → do
            fromException exception `shouldBe` Just ThreadKilled
            let retained = closeFailuresOf (cleanupFailures exception)
            map closeKind retained `shouldBe` [RootHandle]
            map closeErrno retained `shouldBe` [28]
          Right _ → expectationFailure "the exiting thread's cancellation was not delivered"
        operation ← bounded (takeMVar opVar)
        awaitChild operation `shouldReturn` "0123"
        _ ← asserting rig
        pure ()

    it "waits for the operations of a body that failed, and keeps the body's failure primary" $
      lifecycleTree $ \path → do
        (recorded, rig) ← recordingSeam
        pause ← newPause
        drainStarted ← newEmptyMVar
        opVar ← newEmptyMVar
        let seam = onBoundary (announce drainStarted) (pauseWhen (== BeforeRead) pause recorded)
        owner ← spawn $ withRootVia seam defaultContentLimits path $ \root → do
          operation ← spawn (readFirst root ["file.bin"])
          putMVar opVar operation
          awaitReached pause
          fail "the body failed"
        bounded (takeMVar drainStarted)
        isFinished owner `shouldReturn` False
        resumePaused pause
        outcome ← awaitOutcome owner
        case outcome of
          Left exception → show exception `shouldContain` "the body failed"
          Right _ → expectationFailure "the body's failure was lost"
        operation ← bounded (takeMVar opVar)
        awaitChild operation `shouldReturn` "0123"
        _ ← asserting rig
        pure ()

  describe "operations that are interrupted" $ do
    it "closes every handle once when a paused operation is cancelled, at each boundary" $
      forM_ [BeforeRead, AfterOpen 0 (name "file.bin"), OperationAdmitted] $ \boundary →
        lifecycleTree $ \path → do
          (recorded, rig) ← recordingSeam
          pause ← newPause
          withRootVia (pauseWhen (== boundary) pause recorded) defaultContentLimits path $ \root → do
            operation ← spawn (readFirst root ["file.bin"])
            awaitReached pause
            borrowCount (rootGate root) `shouldReturn` 1
            killThread (childThread operation)
            outcome ← awaitOutcome operation
            case outcome of
              Left exception → fromException exception `shouldBe` Just ThreadKilled
              Right _ → expectationFailure "the cancelled operation completed"
            borrowCount (rootGate root) `shouldReturn` 0
          _ ← asserting rig
          pure ()

    it "closes the intermediate directories and the file when the cancellation lands deep in a path" $
      lifecycleTree $ \path → do
        (recorded, rig) ← recordingSeam
        pause ← newPause
        withRootVia (pauseWhen (== AfterOpen 1 (name "inner.bin")) pause recorded) defaultContentLimits path $ \root → do
          operation ← spawn (readFirst root ["dir", "inner.bin"])
          awaitReached pause
          killThread (childThread operation)
          awaitDone operation
        log' ← events rig
        length [() | Opened _ label ← log', label /= "<root>"] `shouldBe` 3
        _ ← asserting rig
        pure ()

    it "closes the opened intermediate directory when a later component fails" $
      lifecycleTree $ \path → do
        (seam, rig) ← recordingSeam
        withRootVia seam defaultContentLimits path $ \root → do
          failure' ← contentFailure (readFirst root ["dir", "missing.bin"])
          failureKind failure' `shouldBe` NotFound
          failurePath failure' `shouldBe` names ["dir", "missing.bin"]
        _ ← asserting rig
        pure ()

    it "closes the descriptor when the object opened is the wrong type" $
      lifecycleTree $ \path → do
        (seam, rig) ← recordingSeam
        withRootVia seam defaultContentLimits path $ \root → do
          failureKindOf (readFirst root ["dir"]) `shouldReturn` ForbiddenType KindDirectory KindRegular
          failureKindOf (withDirectory root (names ["file.bin"]) (\_ → pure ())) `shouldReturn` ForbiddenType KindRegular KindDirectory
        _ ← asserting rig
        pure ()

  describe "cancellation between an open and its tracking" $ do
    it "closes a file descriptor whose open returned with a cancellation already pending" $
      lifecycleTree $ \path → do
        (recorded, rig) ← recordingSeam
        reached ← newEmptyMVar
        killerRef ← newIORef Nothing
        let pendingAfter = mapNative (\native → native {nativeOpenAt = \parent component directory → do
              result ← nativeOpenAt native parent component directory
              if component == name "file.bin"
                then putMVar reached () >> spinUntilCancelling killerRef
                else pure ()
              pure result}) recorded
        withRootVia pendingAfter defaultContentLimits path $ \root → do
          operation ← spawn (readFirst root ["file.bin"])
          bounded (takeMVar reached)
          killer ← spawn (killThread (childThread operation))
          writeIORef killerRef (Just killer)
          outcome ← awaitOutcome operation
          case outcome of
            Left exception → fromException exception `shouldBe` Just ThreadKilled
            Right _ → expectationFailure "the cancellation was lost"
          awaitDone killer
        log' ← events rig
        length [() | Opened _ label ← log', label == show (name "file.bin")] `shouldBe` 1
        _ ← asserting rig
        pure ()

    it "closes a stream whose handover returned with a cancellation already pending" $
      lifecycleTree $ \path → do
        (recorded, rig) ← recordingSeam
        reached ← newEmptyMVar
        killerRef ← newIORef Nothing
        let pendingAfter = mapNative (\native → native {nativeOpenStream = \fd → do
              result ← nativeOpenStream native fd
              putMVar reached () >> spinUntilCancelling killerRef
              pure result}) recorded
        withRootVia pendingAfter defaultContentLimits path $ \root → do
          operation ← spawn (withDirectory root (names ["dir"]) (\_ → pure ()))
          bounded (takeMVar reached)
          killer ← spawn (killThread (childThread operation))
          writeIORef killerRef (Just killer)
          outcome ← awaitOutcome operation
          case outcome of
            Left exception → fromException exception `shouldBe` Just ThreadKilled
            Right _ → expectationFailure "the cancellation was lost"
          awaitDone killer
        log' ← events rig
        length [() | StreamClosed _ ← log'] `shouldBe` 1
        _ ← asserting rig
        pure ()

    it "closes the root descriptor when its open returned with a cancellation already pending" $
      lifecycleTree $ \path → do
        (recorded, rig) ← recordingSeam
        reached ← newEmptyMVar
        killerRef ← newIORef Nothing
        let pendingAfter = mapNative (\native → native {nativeOpenRoot = \selection → do
              result ← nativeOpenRoot native selection
              putMVar reached () >> spinUntilCancelling killerRef
              pure result}) recorded
        owner ← spawn (withRootVia pendingAfter defaultContentLimits path (\_ → pure ()))
        bounded (takeMVar reached)
        killer ← spawn (killThread (childThread owner))
        writeIORef killerRef (Just killer)
        outcome ← awaitOutcome owner
        case outcome of
          Left exception → fromException exception `shouldBe` Just ThreadKilled
          Right _ → expectationFailure "the cancellation was lost"
        awaitDone killer
        _ ← asserting rig
        pure ()

  describe "enumeration ownership" $ do
    it "closes a stream once, through the stream, when cancelled right after the handover" $
      lifecycleTree $ \path → do
        (recorded, rig) ← recordingSeam
        pause ← newPause
        withRootVia (pauseWhen (== AfterStream 0 (name "dir")) pause recorded) defaultContentLimits path $ \root → do
          operation ← spawn (withDirectory root (names ["dir"]) (\_ → pure ()))
          awaitReached pause
          killThread (childThread operation)
          awaitDone operation
        log' ← events rig
        length [() | StreamOpened _ ← log'] `shouldBe` 1
        length [() | StreamClosed _ ← log'] `shouldBe` 1
        _ ← asserting rig
        pure ()

    it "closes the descriptor itself when the handover to a stream fails" $
      lifecycleTree $ \path → do
        (recorded, rig) ← recordingSeam
        let seam = mapNative (\native → native {nativeOpenStream = \_ → pure (Left 12)}) recorded
        withRootVia seam defaultContentLimits path $ \root → do
          failure' ← contentFailure (withDirectory root (names ["dir"]) (\_ → pure ()))
          failureKind failure' `shouldBe` Unreadable 12
        log' ← events rig
        length [() | StreamOpened _ ← log'] `shouldBe` 0
        _ ← asserting rig
        pure ()

    it "keeps a failed close beside a failed handover" $
      lifecycleTree $ \path → do
        (recorded, rig) ← recordingSeam
        counter ← newIORef 0
        -- closes: 1 the qualification probe, 2 the descriptor of the failed handover
        let seam = failNthClose counter 2 28 (mapNative (\native → native {nativeOpenStream = \_ → pure (Left 12)}) recorded)
        withRootVia seam defaultContentLimits path $ \root → do
          caught ← failsWith (withDirectory root (names ["dir"]) (\_ → pure ()))
          let ExceptionWithContext _ failure' = caught
          failureKind failure' `shouldBe` Unreadable 12
          let retained = closeFailuresOf (evidenceOf caught)
          map closeKind retained `shouldBe` [DirectoryHandle]
          map closeErrno retained `shouldBe` [28]
        _ ← asserting rig
        pure ()

  describe "cleanup failures" $ do
    it "reports a read failure and a failed close together, and still closes every handle" $
      lifecycleTree $ \path → do
        (recorded, rig) ← recordingSeam
        counter ← newIORef 0
        -- closes: 1 the qualification probe, 2 the file, 3 the root
        let seam = failNthClose counter 2 28 (mapNative (\native → native {nativeRead = \_ _ _ → pure (Left 5)}) recorded)
        withRootVia seam defaultContentLimits path $ \root → do
          caught ← failsWith (readFirst root ["file.bin"])
          let ExceptionWithContext _ failure' = caught
          failureKind failure' `shouldBe` Unreadable 5
          let retained = closeFailuresOf (evidenceOf caught)
          map closeKind retained `shouldBe` [FileHandle]
          map closePath retained `shouldBe` [names ["file.bin"]]
        _ ← asserting rig
        pure ()

    it "attempts the remaining closes when one close fails, and reports the failure" $
      lifecycleTree $ \path → do
        (recorded, rig) ← recordingSeam
        counter ← newIORef 0
        -- closes: 1 the qualification probe, 2 the file, 3 the intermediate directory
        let seam = failNthClose counter 3 28 recorded
        withRootVia seam defaultContentLimits path $ \root → do
          ExceptionWithContext _ failure' ← failsWith (readFirst root ["dir", "inner.bin"])
          closeKind failure' `shouldBe` IntermediateHandle
          closeErrno failure' `shouldBe` 28
          closePath failure' `shouldBe` names ["dir"]
        _ ← asserting rig
        pure ()

    it "reports a failed root close after a successful body" $
      lifecycleTree $ \path → do
        (recorded, rig) ← recordingSeam
        counter ← newIORef 0
        -- closes: 1 the qualification probe, 2 the file, 3 the root
        let seam = failNthClose counter 3 28 recorded
        ExceptionWithContext _ failure' ←
          failsWith (withRootVia seam defaultContentLimits path (\root → readFirst root ["file.bin"] >>= \bytes → bytes `shouldBe` "0123"))
        closeKind failure' `shouldBe` RootHandle
        _ ← asserting rig
        pure ()

  describe "independence and accounting" $ do
    it "lets two operations borrow one root at once" $
      lifecycleTree $ \path → do
        (recorded, rig) ← recordingSeam
        first ← newPause
        second ← newPause
        let seam = pauseWhen (== BeforeRead) first (pauseWhen (== BeforeRead) second recorded)
        withRootVia seam defaultContentLimits path $ \root → do
          one ← spawn (readFirst root ["file.bin"])
          awaitReached second
          two ← spawn (readFirst root ["dir", "inner.bin"])
          awaitReached first
          borrowCount (rootGate root) `shouldReturn` 2
          resumePaused first
          resumePaused second
          awaitChild one `shouldReturn` "0123"
          awaitChild two `shouldReturn` "inne"
        _ ← asserting rig
        pure ()

    it "leaves a second root untouched when the first root exits" $
      lifecycleTree $ \path → withTree $ \otherTree → do
        let other = otherTree </> "other"
        createDirectory other
        writeBytes (other </> "x.bin") "other bytes"
        (recordedOne, rigOne) ← recordingSeam
        (recordedTwo, rigTwo) ← recordingSeam
        pause ← newPause
        withRootVia (pauseWhen (== BeforeRead) pause recordedTwo) defaultContentLimits other $ \second → do
          withRootVia recordedOne defaultContentLimits path $ \first →
            readFirst first ["file.bin"] `shouldReturn` "0123"
          -- the first root is closed; the second still has an operation inside it
          operation ← spawn (readFirst second ["x.bin"])
          awaitReached pause
          readFirst second ["x.bin"] `shouldReturn` "othe"
          resumePaused pause
          awaitChild operation `shouldReturn` "othe"
        _ ← asserting rigOne
        _ ← asserting rigTwo
        pure ()

    it "returns to its starting point after repeated success, refusal and cancellation" $
      lifecycleTree $ \path → do
        (recorded, rig) ← recordingSeam
        withRootVia recorded defaultContentLimits path $ \root → do
          replayAll root
          before' <- openDescriptors <$> events rig
          replicateM_ 150 (replayAll root)
          after' <- openDescriptors <$> events rig
          after' `shouldBe` before'
          length before' `shouldBe` 1
        log' ← events rig
        peak ← either fail pure (accounting log')
        -- the root, plus at most a two-component path and its file at a time
        peak `shouldSatisfy` (<= 4)
        _ ← asserting rig
        pure ()
  where
    announce var = \case
      DrainStarted → putMVar var ()
      _ → pure ()

replayAll ∷ ContentRoot → IO ()
replayAll root = do
  readFirst root ["file.bin"] `shouldReturn` "0123"
  readFirst root ["dir", "inner.bin"] `shouldReturn` "inne"
  _ ← failureKindOf (readFirst root ["absent"])
  _ ← failureKindOf (readFirst root ["dir"])
  withDirectory root [] $ \reader → do
    first ← readEntry reader
    first `shouldNotBe` Nothing
  withDirectory root (names ["dir"]) $ \reader → () <$ drain (readEntry reader)
