-- | The content root: one launcher-selected directory, opened once, whose
-- descriptor outlives every operation that borrows it.
--
-- 'withContentRootWith' resolves the launch path once, with the operating
-- system's own symbolic-link resolution, opens the actual directory, records its
-- native identity and keeps the descriptor for the rest of the scope. Every later
-- operation is relative to that descriptor, so renaming the folder, replacing its
-- old pathname or retargeting the selection link never switches an existing root
-- to another directory. A root opened afterwards selects whatever the path names
-- then.
--
-- The scope's exit closes admission, waits uninterruptibly until every admitted
-- operation has retired, and only then lets the foundation's resource scope
-- release the descriptor. The wait is therefore before the final release and
-- outside it, as @docs/resources.md@ requires. A cancellation of the thread that
-- is waiting is delivered after the wait and the release have finished.
module Hetoimasia.Content.Internal.Root
  ( ContentRoot (..)
  , withContentRootWith
  , borrow
  , rootAttributionOf
  , closeHandle
  , failWithClose
  , captureFailure
  ) where

import Control.Exception
  ( Exception
  , allowInterrupt
  , ExceptionWithContext
  , SomeException
  , mask
  , rethrowIO
  , throwIO
  , tryWithContext
  , uninterruptibleMask_
  )
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Hetoimasia.Content.Internal.Errno (classifyErrno)
import Hetoimasia.Content.Internal.Gate
import Hetoimasia.Content.Internal.Native
import Hetoimasia.Content.Internal.Types
import Hetoimasia.Foundation.Resource (composeCleanup, withResourceLabelled)

-- | An open root.
--
-- Owner: the 'withContentRootWith' scope that made it. Borrowers: every
-- operation admitted through 'rootGate', on any thread. The record is valid
-- exactly while its scope runs; after that every operation is refused by the
-- gate before any descriptor is touched, so a retained copy cannot reach a
-- descriptor number the process has since reused.
data ContentRoot = ContentRoot
  { rootSeam ∷ !Seam
  , rootLimits ∷ !ContentLimits
  , rootFd ∷ !NativeFd
  , rootGate ∷ !Gate
  , rootReport ∷ !RootReport
  }

rootAttributionOf ∷ ContentRoot → RootAttribution
rootAttributionOf root =
  RootAttribution
    { attributedSelection = reportSelection (rootReport root)
    , attributedIdentity = Just (reportIdentity (rootReport root))
    }

-- | Run an operation as a borrower of the root.
borrow ∷ ContentRoot → IO r → IO r
borrow root operation =
  withAdmitted (rootGate root) $ do
    seamBoundary (rootSeam root) OperationAdmitted
    operation

-- | Close one descriptor, reporting a failed close as cleanup evidence. The
-- release a resource scope runs: one @close@, whose duration the kernel
-- controls for the local filesystems the service supports (see the README for
-- network filesystems).
closeHandle ∷ Seam → RootAttribution → HandleKind → [NativeName] → NativeFd → IO ()
closeHandle seam attribution kind path fd =
  nativeClose (seamNative seam) fd >>= \case
    Right () → pure ()
    Left code → throwIO (CloseFailure kind code attribution path)

-- | An exception caught with its context, for 'composeCleanup'.
captureFailure ∷ Exception e ⇒ e → IO (ExceptionWithContext SomeException)
captureFailure exception =
  tryWithContext @SomeException (throwIO exception) >>= \case
    Left captured → pure captured
    Right () → error "captureFailure: throwIO returned"

-- | Fail with @primary@ after closing a descriptor that no scope tracks yet,
-- keeping a failed close as evidence beside the primary failure.
failWithClose ∷ Seam → RootAttribution → HandleKind → [NativeName] → NativeFd → ContentFailure → IO a
failWithClose seam attribution kind path fd primary = do
  closed ← nativeClose (seamNative seam) fd
  primaryContext ← captureFailure primary
  cleanups ← case closed of
    Right () → pure []
    Left code → do
      captured ← captureFailure (CloseFailure kind code attribution path)
      pure [("content descriptor close after a failed acquisition", captured)]
  composeCleanup (Just primaryContext) cleanups >>= maybe (throwIO primary) rethrowIO

-- | Select, open and anchor a root for the duration of the body.
--
-- The launch path is passed to the operating system as given: no shell syntax is
-- expanded, the process working directory is not changed, and a relative path
-- resolves against it. The final component and every ancestor may be a symbolic
-- link here, and nowhere below the root.
--
-- A selection that is not an accessible directory, or whose directory-relative
-- opening cannot be qualified on this filesystem, is refused before the body
-- runs.
withContentRootWith ∷ Seam → ContentLimits → ByteString → (ContentRoot → IO r) → IO r
withContentRootWith seam limits selection body = do
  let unattributed = RootAttribution selection Nothing
      refuse ∷ FailureKind → IO a
      refuse kind = throwIO (ContentFailure unattributed [] kind)
      native = seamNative seam
  when (BS.null selection) (refuse (InvalidSelection EmptySelection))
  when (BS.elem 0 selection) (refuse (InvalidSelection NulInSelection))
  when (BS.length selection > maxSelectionBytes) (refuse (InvalidSelection (SelectionTooLong (BS.length selection))))
  withResourceLabelled
    "content root close"
    (nativeOpenRoot native selection >>= either (refuse . classifyErrno) pure)
    (closeHandle seam unattributed RootHandle [])
    $ \fd → do
      stat ← nativeFstat native fd >>= either (refuse . Unreadable) pure
      let identity = statIdentity stat
          attributed = RootAttribution selection (Just identity)
          refuseOpened ∷ FailureKind → IO a
          refuseOpened kind = throwIO (ContentFailure attributed [] kind)
      unless (statKind stat == KindDirectory) $
        refuseOpened (ForbiddenType (statKind stat) KindDirectory)
      resolved ← either (const Nothing) Just <$> nativeFdPath native fd
      let report = RootReport {reportSelection = selection, reportResolved = resolved, reportIdentity = identity}
      seamBoundary seam RootOpened
      qualify seam attributed fd identity
      gate ← newGate
      let root = ContentRoot {rootSeam = seam, rootLimits = limits, rootFd = fd, rootGate = gate, rootReport = report}
      drainOnExit seam gate (body root)

-- | The longest launch path accepted: the platform's @PATH_MAX@.
maxSelectionBytes ∷ Int
maxSelectionBytes = 4096

-- | Prove the directory-relative, no-follow opening this service is built on
-- works on the opened root: open @.@ beneath the root descriptor and see the
-- same identity. A filesystem or platform that cannot is refused here, rather
-- than part way into a scan.
qualify ∷ Seam → RootAttribution → NativeFd → NativeIdentity → IO ()
qualify seam attributed fd identity =
  withResourceLabelled
    "content root qualification close"
    ( nativeOpenAt native fd structuralName True >>= \case
        Right opened → pure opened
        Left code → throwIO (ContentFailure attributed [] (Unsupported code))
    )
    (closeHandle seam attributed IntermediateHandle [])
    $ \opened → do
      stat ← nativeFstat native opened >>= either (\code → throwIO (ContentFailure attributed [] (Unsupported code))) pure
      unless (statIdentity stat == identity && statKind stat == KindDirectory) $
        throwIO (ContentFailure attributed [] (Unsupported 0))
  where
    native = seamNative seam

-- | Run the body, then close admission and wait for every borrower before
-- returning, however the body ended.
--
-- The body's outcome is captured with its context and the exit then runs
-- uninterruptibly, so a cancellation aimed at this thread while it waits cannot
-- shorten the wait. Once every borrower has retired the cancellation, if one is
-- pending, is delivered here, at the one interruptible point after the wait;
-- the enclosing resource scope then releases the descriptor with the
-- cancellation as its primary failure and any failed close retained beside it.
-- The wait is the price of letting other threads borrow the root: an operation
-- that never returns holds the exit.
drainOnExit ∷ Seam → Gate → IO r → IO r
drainOnExit seam gate body = mask $ \restore → do
  outcome ← tryWithContext @SomeException (restore body)
  uninterruptibleMask_ $ do
    closeAdmission gate
    seamBoundary seam DrainStarted
    awaitDrained gate
  allowInterrupt
  either rethrowIO pure outcome
