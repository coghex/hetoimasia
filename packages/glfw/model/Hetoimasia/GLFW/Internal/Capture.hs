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
-- Reports are kept in buckets chosen by facts about the reporting OS thread,
-- never by its Haskell 'Control.Concurrent.ThreadId': a callback that re-enters
-- Haskell runs in a thread of its own.
--
-- * A report made while a wake call's native call runs on that OS thread
--   belongs to that wake call. The binding makes the call with the call's
--   /wake mark/ in the calling OS thread's native thread-local storage, and the
--   callback reads that storage on the thread GLFW invokes it on, so the mark,
--   the native call, and the report share one OS thread by construction.
--   'beginWakeReports' opens the call's own bucket and 'takeWakeReports'
--   removes it once the call returns, so concurrent wake calls each keep their
--   own reports.
-- * Otherwise, a report made on the process main thread while a session
--   operation's native call is running belongs to that operation, which takes
--   it with 'takeOwnerReports' after the call returns.
-- * Every other report is asynchronous: it stays in the other bucket until
--   'takeOtherReports' reads it, and is never attributed to whichever operation
--   happens to be running when it is observed. A report carrying a mark with no
--   open bucket, or made while the mark could not be read, cannot be attributed
--   and is counted there as a callback fault.
--
-- Every bucket is bounded. Each keeps the first 'errorEvidenceCapacity'
-- reports it receives and counts the rest in 'reportsLost', and each
-- description is copied up to 'errorDescriptionLimit' bytes, with truncation
-- recorded. A lost report still makes 'hasReports' true, so full storage can
-- never turn a reported native failure into success. A callback that fails to
-- record is counted in 'callbackFaults' rather than rethrown into C.
--
-- The buckets live in one 'IORef' updated with 'atomicModifyIORef'', so a
-- callback invoked synchronously from inside an owner or wake call, or
-- concurrently from another thread, never blocks on the owner or on another
-- wake call.
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

    -- * Wake calls
  , WakeMark
  , noWakeMark
  , beginWakeReports
  , takeWakeReports
  ) where

import Control.DeepSeq (rnf)
import Control.Exception (Exception, SomeException, try, uninterruptibleMask_)
import Control.Monad (when)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Encoding (decodeUtf8Lenient)
import Data.Word (Word64, Word8)
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
  , wakeBuckets ∷ !(Map WakeMark Bucket)
    -- ^ One per wake call whose native call may still report.
  , nextWakeMark ∷ !WakeMark
  }

-- | Which bucket a report belongs to.
data Destination
  = OwnerReports
  | OtherReports
  | WakeReports !WakeMark

-- | Identifies one wake call's reports for as long as its bucket is open. Marks
-- start at one and are never reissued within a capture; 'noWakeMark' is what
-- a thread outside any wake call reads.
type WakeMark = Word64

-- | The mark a thread outside any wake call reads.
noWakeMark ∷ WakeMark
noWakeMark = 0

-- | The capture state of one session.
data Capture = Capture
  { captureIdentity ∷ IO Bool
    -- ^ Whether the calling OS thread is the process main thread.
  , captureWakeMark ∷ IO WakeMark
    -- ^ The wake mark of the wake call running on the calling OS thread, or
    -- 'noWakeMark'.
  , captureBuckets ∷ !(IORef Buckets)
  }

-- | Empty capture storage, identifying reporting threads with the given
-- queries: whether the calling OS thread is the process main thread, and the
-- mark of the wake call running on it.
newCapture ∷ IO Bool → IO WakeMark → IO Capture
newCapture identity wakeMark =
  Capture identity wakeMark <$> newIORef (Buckets emptyBucket emptyBucket Map.empty 1)

-- | The error callback a session installs.
--
-- It runs uninterruptibly: its work is bounded by 'errorDescriptionLimit' and
-- one non-blocking update, and nothing may unwind through the C frame that
-- called it. The wake mark is read first. A failure to read it is counted as a
-- fault among asynchronous reports, since the report cannot be attributed. Inside
-- a wake call, a failure to identify the thread, copy, or record is counted in
-- that call's bucket; outside one, a failure to identify the thread is counted
-- among asynchronous reports, and a failure to copy or record in the bucket of
-- the thread it happened on.
captureCallback ∷ Capture → ErrorCallback
captureCallback capture code description = uninterruptibleMask_ $ do
  marked ← try (captureWakeMark capture)
  case marked of
    Left (_ ∷ SomeException) → update (onBucket OtherReports countFault)
    Right mark → do
      identified ← try (captureIdentity capture)
      case identified of
        Left (_ ∷ SomeException) → update (onBucket (unidentified mark) countFault)
        Right onMain → do
          let destination
                | mark /= noWakeMark = WakeReports mark
                | onMain = OwnerReports
                | otherwise = OtherReports
          recorded ← try $ do
            (text, truncated) ← copyDescription description
            let !entry =
                  NativeError
                    { nativeErrorCode = fromIntegral code
                    , nativeErrorDescription = text
                    , nativeErrorTruncated = truncated
                    , nativeErrorThread = if onMain then ProcessMainThread else OtherThread
                    }
            update (onBucket destination (store entry))
          case recorded of
            Right () → pure ()
            Left (_ ∷ SomeException) → update (onBucket destination countFault)
  where
    update change = atomicModifyIORef' (captureBuckets capture) (\buckets → (change buckets, ()))
    unidentified mark = if mark /= noWakeMark then WakeReports mark else OtherReports

-- | Move reports made on the process main thread outside any operation's native
-- call into the asynchronous bucket, so the next operation cannot claim them.
settleStrayOwnerReports ∷ Capture → IO ()
settleStrayOwnerReports capture =
  atomicModifyIORef' (captureBuckets capture) $ \buckets →
    (buckets {mainBucket = emptyBucket, otherBucket = absorb (otherBucket buckets) (mainBucket buckets)}, ())

-- | Take, and empty, the reports made on the process main thread.
takeOwnerReports ∷ Capture → IO Reports
takeOwnerReports capture =
  atomicModifyIORef' (captureBuckets capture) $ \buckets →
    (buckets {mainBucket = emptyBucket}, reportsOf (mainBucket buckets))

-- | Take, and empty, the asynchronous reports.
takeOtherReports ∷ Capture → IO Reports
takeOtherReports capture =
  atomicModifyIORef' (captureBuckets capture) $ \buckets →
    (buckets {otherBucket = emptyBucket}, reportsOf (otherBucket buckets))

-- | Open an empty bucket for one wake call and answer its fresh mark. The call
-- makes its native call with that mark, then takes the bucket with
-- 'takeWakeReports'.
beginWakeReports ∷ Capture → IO WakeMark
beginWakeReports capture =
  atomicModifyIORef' (captureBuckets capture) $ \buckets →
    let mark = nextWakeMark buckets
     in (buckets {wakeBuckets = Map.insert mark emptyBucket (wakeBuckets buckets), nextWakeMark = mark + 1}, mark)

-- | Remove a wake call's bucket and answer the reports it held. A report that
-- arrives with this mark afterwards has no bucket and is counted as an
-- asynchronous callback fault.
takeWakeReports ∷ Capture → WakeMark → IO Reports
takeWakeReports capture mark =
  atomicModifyIORef' (captureBuckets capture) $ \buckets →
    ( buckets {wakeBuckets = Map.delete mark (wakeBuckets buckets)}
    , maybe (Reports [] 0 0) reportsOf (Map.lookup mark (wakeBuckets buckets))
    )

onBucket ∷ Destination → (Bucket → Bucket) → Buckets → Buckets
onBucket OwnerReports change buckets = buckets {mainBucket = change (mainBucket buckets)}
onBucket OtherReports change buckets = buckets {otherBucket = change (otherBucket buckets)}
onBucket (WakeReports mark) change buckets = case Map.lookup mark (wakeBuckets buckets) of
  Just bucket → buckets {wakeBuckets = Map.insert mark (change bucket) (wakeBuckets buckets)}
  Nothing → buckets {otherBucket = countFault (otherBucket buckets)}

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
