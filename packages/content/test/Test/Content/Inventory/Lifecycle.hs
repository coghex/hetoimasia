-- | Ownership, cancellation and cleanup of a scan and a verified read.
--
-- Each scenario holds a real operation at a named boundary with a 'Pause',
-- changes the world, and lets it go; none sleeps. The accounting reads the
-- recording seam's log, so it counts only this service's own acquisitions and
-- closes. Evidence is native (real descriptors, gated) throughout; the only
-- injected evidence is the failed close, which the production adapter reports
-- after really closing the descriptor.
module Test.Content.Inventory.Lifecycle (spec) where

import Control.Concurrent (killThread)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), ExceptionWithContext (ExceptionWithContext), SomeException, fromException)
import Control.Monad (forM_, replicateM_)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (elemIndex)
import Hetoimasia.Content
import Hetoimasia.Content.Internal.Gate (borrowCount)
import Hetoimasia.Content.Internal.Native
import Hetoimasia.Content.Internal.Root (ContentRoot (rootGate))
import Hetoimasia.Content.Inventory
import System.FilePath ((</>))
import System.Posix.Files (createSymbolicLink)
import Test.Content.Inventory.Support
import Test.Content.Support
import Hetoimasia.Foundation.Resource (cleanupFailures)
import Test.Hspec
import Test.Support.Bounded (bounded)

limits ∷ InventoryLimits
limits = limitsFrom baseSpec {specBufferBytes = 8}

-- | A tree with a nested directory, a file at each level and an empty file.
standardTree ∷ FilePath → IO ()
standardTree root =
  populate root [("top.bin", "top bytes"), ("a/b/c/deep.bin", "deep bytes"), ("a/mid.bin", "mid bytes"), ("empty.bin", "")]

-- | Report the drain starting.
announce ∷ MVar () → Boundary → IO ()
announce started = \case
  DrainStarted → putMVar started ()
  _ → pure ()

rootDescriptor ∷ [Event] → Int
rootDescriptor log' = case [fd | Opened fd "<root>" ← log'] of
  fd : _ → fd
  [] → -1

positionOf ∷ Event → [Event] → Int
positionOf event log' = maybe (-1) id (elemIndex event log')

killedWith ∷ Either SomeException a → Expectation
killedWith = \case
  Left exception → fromException exception `shouldBe` Just ThreadKilled
  Right _ → expectationFailure "the cancelled operation completed"

-- | Make every close report an errno once armed, after really closing.
failingCloseWhen ∷ IORef Bool → Int → Seam → Seam
failingCloseWhen flag code = mapNative $ \native →
  native
    { nativeClose = \fd → do
        result ← nativeClose native fd
        on ← readIORef flag
        pure (if on then Left code else result)
    }

spec ∷ Spec
spec = do
  describe "descriptor accounting" $ do
    it "closes every descriptor exactly once after a successful scan, with a bounded peak" $
      withLayout $ \tree → do
        standardTree (rootPath tree)
        (seam, rig) ← recordingSeam
        _ ← scanned seam limits (rootPath tree)
        peak ← asserting rig
        -- the root, its stream, a, b, c and the deepest file
        peak `shouldBe` 6

    it "closes every descriptor exactly once after each kind of refusal" $
      forM_ refusals $ \(label, build, change) →
        withLayout $ \tree → do
          build (rootPath tree)
          (seam, rig) ← recordingSeam
          outcome ← scanning (change seam) limits (rootPath tree)
          case outcome of
            Left _ → pure ()
            Right _ → expectationFailure (label <> " was inventoried")
          _ ← asserting rig
          pure ()

    it "closes every descriptor exactly once after verified reads that succeed and that refuse" $
      withLayout $ \tree → do
        standardTree (rootPath tree)
        (seam, rig) ← recordingSeam
        withScanned seam limits (rootPath tree) $ \root inventory → do
          Right _ ← readVerified inventory root (keyFor inventory "top.bin") 4096
          Left _ ← readVerified inventory root (keyFor inventory "a/b/c/deep.bin") 3
          Left _ ← readVerified inventory root (keyFor inventory "missing") 4096
          writeBytes (rootPath tree </> "a" </> "mid.bin") "MID BYTES"
          Left _ ← readVerified inventory root (keyFor inventory "a/mid.bin") 4096
          pure ()
        _ ← asserting rig
        pure ()

    it "returns to the starting accounting after repeated scans, refusals and reads" $
      withLayout $ \tree → do
        standardTree (rootPath tree)
        (seam, rig) ← recordingSeam
        withRootVia seam rootLimits (rootPath tree) $ \root →
          replicateM_ 20 $ do
            Right inventory ← scanInventory limits testKey root
            Right _ ← readVerified inventory root (keyFor inventory "a/mid.bin") 4096
            pure ()
        _ ← asserting rig
        pure ()

  describe "cancellation at each boundary" $ do
    forM_ scanGates $ \(label, gate) →
      it ("closes everything and publishes nothing when a scan is cancelled " <> label) $
        withLayout $ \tree → do
          standardTree (rootPath tree)
          (recorded, rig) ← recordingSeam
          pause ← newPause
          withRootVia (pauseWhen gate pause recorded) rootLimits (rootPath tree) $ \root → do
            operation ← spawn (scanInventory limits testKey root)
            awaitReached pause
            borrowCount (rootGate root) `shouldReturn` (if gate ScanBeforePublish then 0 else 1)
            killThread (childThread operation)
            awaitOutcome operation >>= killedWith
            borrowCount (rootGate root) `shouldReturn` 0
            -- the root is usable again, and a fresh scan sees the whole folder
            again ← scanInventory limits testKey root
            fmap (length . pathsOf) again `shouldBe` Right 7
          _ ← asserting rig
          pure ()

    forM_ readGates $ \(label, gate) →
      it ("closes everything and delivers nothing when a verified read is cancelled " <> label) $
        withLayout $ \tree → do
          standardTree (rootPath tree)
          (recorded, rig) ← recordingSeam
          pause ← newPause
          withScanned (pauseWhen gate pause recorded) limits (rootPath tree) $ \root inventory → do
            operation ← spawn (readVerified inventory root (keyFor inventory "a/mid.bin") 4096)
            awaitReached pause
            borrowCount (rootGate root) `shouldReturn` 1
            killThread (childThread operation)
            awaitOutcome operation >>= killedWith
            borrowCount (rootGate root) `shouldReturn` 0
            readVerified inventory root (keyFor inventory "a/mid.bin") 4096 `shouldReturn` Right "mid bytes"
          _ ← asserting rig
          pure ()

  describe "the root's exit" $ do
    it "waits for a scan in progress, and closes the root only after it retires" $
      withLayout $ \tree → do
        standardTree (rootPath tree)
        (recorded, rig) ← recordingSeam
        pause ← newPause
        drainStarted ← newEmptyMVar
        scanVar ← newEmptyMVar
        rootVar ← newEmptyMVar
        let seam = onBoundary (announce drainStarted) (pauseWhen (== ScanFileOpened (names ["top.bin"])) pause recorded)
        owner ← spawn $ withRootOwned seam rootLimits (rootPath tree) $ \root → do
          putMVar rootVar root
          operation ← spawn (scanInventory limits testKey root)
          putMVar scanVar operation
          awaitReached pause
        root ← bounded (takeMVar rootVar)
        bounded (takeMVar drainStarted)
        isFinished owner `shouldReturn` False
        borrowCount (rootGate root) `shouldReturn` 1
        -- admission is closed: a second scan is refused as misuse
        ExceptionWithContext _ refused ← failsWith (scanInventory limits testKey root)
        refused `shouldBe` ContentDefect RootNotAdmitting
        mid ← events rig
        Closed (rootDescriptor mid) `shouldNotSatisfy` (`elem` mid)
        resumePaused pause
        awaitChild owner
        operation ← bounded (takeMVar scanVar)
        scanResult ← awaitChild operation
        fmap (length . pathsOf) scanResult `shouldBe` Right 7
        final ← events rig
        let closedAt = positionOf (Closed (rootDescriptor final)) final
        positionOf (Boundary (ScanFileHashed (names ["top.bin"]))) final `shouldSatisfy` (< closedAt)
        positionOf (Boundary DrainStarted) final `shouldSatisfy` (< closedAt)
        _ ← asserting rig
        pure ()

    it "waits for a verified read in progress, and delivers its bytes" $
      withLayout $ \tree → do
        standardTree (rootPath tree)
        (recorded, rig) ← recordingSeam
        pause ← newPause
        drainStarted ← newEmptyMVar
        readVar ← newEmptyMVar
        let seam = onBoundary (announce drainStarted) (pauseWhen (\boundary → case boundary of ReadOpened _ → True; _ → False) pause recorded)
        owner ← spawn $ withScanned seam limits (rootPath tree) $ \root inventory → do
          operation ← spawn (readVerified inventory root (keyFor inventory "top.bin") 4096)
          putMVar readVar operation
          awaitReached pause
        bounded (takeMVar drainStarted)
        isFinished owner `shouldReturn` False
        resumePaused pause
        awaitChild owner
        operation ← bounded (takeMVar readVar)
        awaitChild operation `shouldReturn` Right "top bytes"
        _ ← asserting rig
        pure ()

    it "runs two scans of one root at once, each seeing the whole folder" $
      withLayout $ \tree → do
        standardTree (rootPath tree)
        withRoot (rootPath tree) $ \root → do
          first ← spawn (scanInventory limits testKey root)
          second ← spawn (scanInventory limits testKey root)
          a ← awaitChild first
          b ← awaitChild second
          fmap pathsOf a `shouldBe` fmap pathsOf b
          fmap (length . pathsOf) a `shouldBe` Right 7

  describe "failed cleanup" $ do
    it "reports a failed close after a successful scan as the failure it is, and publishes nothing" $
      withLayout $ \tree → do
        populate (rootPath tree) [("only.bin", "bytes")]
        counter ← newIORef 0
        -- closes: 1 the qualification probe, 2 the file, 3 the root
        (recorded, rig) ← recordingSeam
        ExceptionWithContext _ failed ← failsWith (scanning (failNthClose counter 2 28 recorded) limits (rootPath tree))
        closeKind failed `shouldBe` FileHandle
        closeErrno failed `shouldBe` 28
        _ ← asserting rig
        pure ()

    it "keeps a refusal primary when closing its directories also fails, and retains the evidence" $
      withLayout $ \tree → do
        populate (rootPath tree) [("d/", "")]
        createSymbolicLink "nowhere" (rootPath tree </> "d" </> "link")
        (recorded, rig) ← recordingSeam
        -- the scope runs on a child whose outcome is read back with its context, which carries the evidence
        let seam = failCloseStream (const True) 28 recorded
        outcome ← spawn (withRootOwned seam rootLimits (rootPath tree) (scanInventory limits testKey)) >>= awaitOutcome
        case outcome of
          Left exception → do
            case fromException exception of
              Just refusal → do
                inventoryFailureReason refusal `shouldBe` Content ForbiddenLink
                inventoryFailurePath refusal `shouldBe` names ["d", "link"]
              Nothing → expectationFailure ("expected the refusal to be primary, got " <> show exception)
            let retained = closeFailuresOf (cleanupFailures exception)
            -- the stream of "d" and the root's stream both failed to close, and both were attempted
            map closeKind retained `shouldBe` [DirectoryHandle, DirectoryHandle]
            map closeErrno retained `shouldBe` [28, 28]
          Right returned → expectationFailure ("a refusal with a failed close was returned as a value: " <> show (either show (const "an inventory") returned))
        _ ← asserting rig
        pure ()

    it "reports a failed close after a verified read as the failure it is, and delivers no bytes" $
      withLayout $ \tree → do
        populate (rootPath tree) [("f", "bytes")]
        flag ← newIORef False
        (recorded, rig) ← recordingSeam
        withScanned (failingCloseWhen flag 28 recorded) limits (rootPath tree) $ \root inventory → do
          writeIORef flag True
          ExceptionWithContext _ failed ← failsWith (readVerified inventory root (keyFor inventory "f") 4096)
          closeKind failed `shouldBe` FileHandle
          writeIORef flag False
        _ ← asserting rig
        pure ()

    it "reports a failed close after a refused verified read as the failure it is, not as changed content" $
      withLayout $ \tree → do
        populate (rootPath tree) [("f", "bytes")]
        flag ← newIORef False
        (recorded, rig) ← recordingSeam
        withScanned (failingCloseWhen flag 28 recorded) limits (rootPath tree) $ \root inventory → do
          writeBytes (rootPath tree </> "f") "BYTES"
          writeIORef flag True
          -- the bytes differ, which alone is a refusal; the close failed too, and that is not one
          ExceptionWithContext _ failed ← failsWith (readVerified inventory root (keyFor inventory "f") 4096)
          closeKind failed `shouldBe` FileHandle
          writeIORef flag False
        _ ← asserting rig
        pure ()
  where
    scanGates =
      [ ("while the entries of a directory are being charged", \boundary → case boundary of ScanEntryCharged 2 → True; _ → False)
      , ("with a file open and not yet read", \boundary → case boundary of ScanFileOpened p → p == names ["top.bin"]; _ → False)
      , ("after a file is hashed and before it is recorded", \boundary → case boundary of ScanFileHashed p → p == names ["a", "b", "c", "deep.bin"]; _ → False)
      , ("after the traversal and before the inventory is published", (== ScanBeforePublish))
      ]
    readGates =
      [ ("with the file open and its length checked", \boundary → case boundary of ReadOpened _ → True; _ → False)
      , ("with the bytes read and not yet compared", \boundary → case boundary of ReadBeforeCompare _ → True; _ → False)
      ]
    refusals ∷ [(String, FilePath → IO (), Seam → Seam)]
    refusals =
      [ ("a symbolic link", \root → populate root [("a/", ""), ("a/f", "x")] >> createSymbolicLink "a" (root </> "link"), id)
      , ("an oversized file", \root → populate root [("a/f", replicateBytes 5000)], id)
      , ("an unreadable file", \root → populate root [("a/f", "x")], denyingOpen "f" 13)
      , ("a read error", \root → populate root [("a/f", "x")], failingRead 5)
      , ("an invalid name", \root → populate root [("a/", ""), ("a/b:c", "x")], id)
      ]
    replicateBytes n = mconcat (replicate n "x")
