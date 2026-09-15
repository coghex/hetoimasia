-- | Bounded evidence of what GLFW's error callback reported.
--
-- GLFW reports an error by calling one process-wide callback with a code and a
-- description that is valid only while the callback runs. It may call it on
-- the thread that made the failing call, which for this package is the process
-- main thread inside a session operation, or on another thread entirely. The
-- callback installed by a session is 'captureCallback': it copies the
-- description while it is valid, records one 'NativeError' in bounded storage,
-- and returns. It invokes no sink, takes no lock, waits for nothing, and lets no
-- Haskell exception unwind into C.
--
-- Reports are kept in two buckets, chosen by the OS identity of the reporting
-- thread, never by its Haskell 'Control.Concurrent.ThreadId': a callback that
-- re-enters Haskell runs in a thread of its own. A report made on the process
-- main thread while a session operation's native call is running belongs to
-- that operation, which takes it with 'takeOwnerReports' after the call
-- returns. Every other report is asynchronous: it stays in the other bucket
-- until 'takeOtherReports' reads it, and is never attributed to whichever
-- operation happens to be running when it is observed.
--
-- Both buckets are bounded. Each keeps the first 'errorEvidenceCapacity'
-- reports it receives and counts the rest in 'reportsLost', and each
-- description is copied up to 'errorDescriptionLimit' bytes, with truncation
-- recorded. A lost report still makes 'hasReports' true, so full storage can
-- never turn a reported native failure into success. A callback that fails to
-- record is counted in 'callbackFaults' rather than rethrown into C.
--
-- The buckets live in one 'IORef' updated with 'atomicModifyIORef'', so a
-- callback invoked synchronously from inside an owner call, or concurrently
-- from another thread, never blocks on the owner.
--
-- An owner operation that took reports made during its native call raises them
-- with 'raiseReported' as a 'NativeFailure' attributed to the @glfw@ component,
-- which the session, window, and monitor models share.
module Hetoimasia.GLFW.Internal.Capture
  ( -- * Evidence
    NativeError (..)
  , ReportingThread (..)
  , Reports (..)
  , hasReports
  , rnfReports
  , errorEvidenceCapacity
  , errorDescriptionLimit

    -- * Failures raised from the evidence
  , glfwComponent
  , NativeOutcome (..)
  , NativeFailure (..)
  , raiseReported

    -- * Capture
  , ErrorCallback
  , Capture
  , newCapture
  , captureCallback
  , settleStrayOwnerReports
  , takeOwnerReports
  , takeOtherReports
  ) where

import Control.DeepSeq (rnf)
import Control.Exception (Exception, SomeException, try, uninterruptibleMask_)
import Control.Monad (when)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Encoding (decodeUtf8Lenient)
import Data.Word (Word8)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt)
import Foreign.Ptr (nullPtr)
import Foreign.Storable (peekByteOff)
import Hetoimasia.Foundation.Failure (Operation, throwFailure)
import Hetoimasia.Foundation.Log (Component, unsafeComponent)
import Numeric.Natural (Natural)

-- | One report the native error callback made.
data NativeError = NativeError
  { nativeErrorCode ∷ !Int
    -- ^ The GLFW error code, such as @GLFW_PLATFORM_UNAVAILABLE@.
  , nativeErrorDescription ∷ !Text
    -- ^ The description, decoded leniently as UTF-8 from at most
    -- 'errorDescriptionLimit' bytes.
  , nativeErrorTruncated ∷ !Bool
    -- ^ Whether the native description was longer than the bytes kept.
  , nativeErrorThread ∷ !ReportingThread
    -- ^ The OS thread the callback ran on.
  }
  deriving (Eq, Show)

-- | Which OS thread a report was made on.
data ReportingThread
  = ProcessMainThread
    -- ^ The thread that entered the process main function, which owns the
    -- session.
  | OtherThread
  deriving (Eq, Show)

-- | The reports one bucket held when it was taken.
data Reports = Reports
  { reportedErrors ∷ ![NativeError]
    -- ^ Oldest first; at most 'errorEvidenceCapacity' entries.
  , reportsLost ∷ !Natural
    -- ^ Reports received after the bucket was full.
  , callbackFaults ∷ !Natural
    -- ^ Callback invocations that could not record their report.
  }
  deriving (Eq, Show)

-- | Whether anything was reported at all, including a report that was lost or
-- could not be recorded.
hasReports ∷ Reports → Bool
hasReports reports =
  not (null (reportedErrors reports)) || reportsLost reports > 0 || callbackFaults reports > 0

-- | Evaluate reports fully, for the prepared data that carries them.
rnfReports ∷ Reports → ()
rnfReports reports =
  foldr (seq . rnfError) () (reportedErrors reports)
    `seq` rnf (reportsLost reports)
    `seq` rnf (callbackFaults reports)
  where
    rnfError reported =
      rnf (nativeErrorCode reported)
        `seq` rnf (nativeErrorDescription reported)
        `seq` nativeErrorTruncated reported
        `seq` nativeErrorThread reported
        `seq` ()

-- | The component every failure raised by this package is attributed to.
glfwComponent ∷ Component
glfwComponent = unsafeComponent "glfw"

-- | Whether the native call itself signalled failure.
data NativeOutcome
  = NativeCallReturned
    -- ^ The call returned normally, but errors were reported during it.
  | NativeCallFailed
    -- ^ The call returned its failure value.
  deriving (Eq, Show)

-- | A native call failed or reported errors on the owner thread while it ran.
data NativeFailure = NativeFailure
  { nativeOutcome ∷ !NativeOutcome
  , nativeReports ∷ !Reports
  }
  deriving (Eq, Show)

instance Exception NativeFailure

-- | Raise reports taken after a native call as that operation's
-- 'NativeFailure', if anything was reported.
raiseReported ∷ Operation → [(Text, Text)] → NativeOutcome → Reports → IO ()
raiseReported operationName identifiers outcome reports =
  when (hasReports reports) $
    throwFailure glfwComponent operationName identifiers (NativeFailure outcome reports)

-- | How many reports each bucket keeps before counting the rest as lost.
errorEvidenceCapacity ∷ Int
errorEvidenceCapacity = 16

-- | How many bytes of a native description are copied.
errorDescriptionLimit ∷ Int
errorDescriptionLimit = 1024

-- | The shape of GLFW's error callback.
type ErrorCallback = CInt → CString → IO ()

-- | Bounded storage for one reporting thread class: the count kept, the kept
-- reports newest first, the lost count, and the fault count.
data Bucket = Bucket !Int ![NativeError] !Natural !Natural

emptyBucket ∷ Bucket
emptyBucket = Bucket 0 [] 0 0

data Buckets = Buckets
  { mainBucket ∷ !Bucket
  , otherBucket ∷ !Bucket
  }

-- | The capture state of one session.
data Capture = Capture
  { captureIdentity ∷ IO Bool
    -- ^ Whether the calling OS thread is the process main thread.
  , captureBuckets ∷ !(IORef Buckets)
  }

-- | Empty capture storage, identifying reporting threads with the given query.
newCapture ∷ IO Bool → IO Capture
newCapture identity = Capture identity <$> newIORef (Buckets emptyBucket emptyBucket)

-- | The error callback a session installs.
--
-- It runs uninterruptibly: its work is bounded by 'errorDescriptionLimit' and
-- one non-blocking update, and nothing may unwind through the C frame that
-- called it. A failure to identify the thread is counted as a fault among
-- asynchronous reports, since it cannot be attributed; a failure to copy or
-- record is counted in the bucket of the thread it happened on.
captureCallback ∷ Capture → ErrorCallback
captureCallback capture code description = uninterruptibleMask_ $ do
  identified ← try (captureIdentity capture)
  case identified of
    Left (_ ∷ SomeException) → update (onBucket False countFault)
    Right onMain → do
      recorded ← try $ do
        (text, truncated) ← copyDescription description
        let !entry =
              NativeError
                { nativeErrorCode = fromIntegral code
                , nativeErrorDescription = text
                , nativeErrorTruncated = truncated
                , nativeErrorThread = if onMain then ProcessMainThread else OtherThread
                }
        update (onBucket onMain (store entry))
      case recorded of
        Right () → pure ()
        Left (_ ∷ SomeException) → update (onBucket onMain countFault)
  where
    update change = atomicModifyIORef' (captureBuckets capture) (\buckets → (change buckets, ()))

-- | Move reports made on the process main thread outside any operation's native
-- call into the asynchronous bucket, so the next operation cannot claim them.
settleStrayOwnerReports ∷ Capture → IO ()
settleStrayOwnerReports capture =
  atomicModifyIORef' (captureBuckets capture) $ \(Buckets stray other) →
    (Buckets emptyBucket (absorb other stray), ())

-- | Take, and empty, the reports made on the process main thread.
takeOwnerReports ∷ Capture → IO Reports
takeOwnerReports capture =
  atomicModifyIORef' (captureBuckets capture) $ \(Buckets owned other) →
    (Buckets emptyBucket other, reportsOf owned)

-- | Take, and empty, the asynchronous reports.
takeOtherReports ∷ Capture → IO Reports
takeOtherReports capture =
  atomicModifyIORef' (captureBuckets capture) $ \(Buckets owned other) →
    (Buckets owned emptyBucket, reportsOf other)

onBucket ∷ Bool → (Bucket → Bucket) → Buckets → Buckets
onBucket True change buckets = buckets {mainBucket = change (mainBucket buckets)}
onBucket False change buckets = buckets {otherBucket = change (otherBucket buckets)}

store ∷ NativeError → Bucket → Bucket
store entry (Bucket kept entries lost faults)
  | kept < errorEvidenceCapacity = Bucket (kept + 1) (entry : entries) lost faults
  | otherwise = Bucket kept entries (lost + 1) faults

countFault ∷ Bucket → Bucket
countFault (Bucket kept entries lost faults) = Bucket kept entries lost (faults + 1)

-- | Add a bucket's reports, oldest first, to another bucket under its bound.
absorb ∷ Bucket → Bucket → Bucket
absorb into (Bucket _ entries lost faults) =
  case foldl' (flip store) into (reverse entries) of
    Bucket kept merged lost' faults' → Bucket kept merged (lost' + lost) (faults' + faults)

reportsOf ∷ Bucket → Reports
reportsOf (Bucket _ entries lost faults) = Reports (reverse entries) lost faults

-- | Copy at most 'errorDescriptionLimit' bytes of a NUL-terminated description.
--
-- No byte past the terminator is read: the scan stops at the first NUL, and
-- the byte at the limit is inspected only when every byte before it was
-- non-NUL, in which case the string extends at least that far.
copyDescription ∷ CString → IO (Text, Bool)
copyDescription pointer
  | pointer == nullPtr = pure (Text.empty, False)
  | otherwise = do
      kept ← scan 0
      bytes ← ByteString.packCStringLen (pointer, kept)
      truncated ←
        if kept < errorDescriptionLimit
          then pure False
          else (/= 0) <$> (peekByteOff pointer errorDescriptionLimit ∷ IO Word8)
      let !text = decodeUtf8Lenient bytes
      pure (text, truncated)
  where
    scan offset
      | offset >= errorDescriptionLimit = pure errorDescriptionLimit
      | otherwise = do
          byte ← peekByteOff pointer offset ∷ IO Word8
          if byte == 0 then pure offset else scan (offset + 1)
