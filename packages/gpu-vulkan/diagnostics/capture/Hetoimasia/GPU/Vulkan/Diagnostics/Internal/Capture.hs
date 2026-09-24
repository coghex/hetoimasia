-- | The C capture storage, seen from Haskell.
--
-- Everything the storage does happens in @cbits/hetoimasia_vulkan_capture.c@;
-- this module only builds one, frees one, reads its latches and counters, and
-- takes published records out of it as owned Haskell values. It is the
-- package's private sublibrary so the public library and this package's own
-- suite can share it while no client can: a client never sees a storage, a
-- record pointer, or the test producer below.
--
-- Calls that only read an atomic, copy a record out, or advance a position are
-- @unsafe@: they are short, never block, and never call back. Closing waits for
-- producers already inside the callback to leave, so it is @safe@. The test
-- producer is @safe@ too, so several Haskell threads can run it at once on
-- separate capabilities, as several driver threads would.
module Hetoimasia.GPU.Vulkan.Diagnostics.Internal.Capture
  ( -- * Limits
    Limits (..)
  , LimitError (..)
  , checkLimits
  , recordFootprint

    -- * Storage
  , Storage
  , CreateFailure (..)
  , createStorage
  , freeStorage
  , closeStorage
  , storageClosed
  , storageUserData

    -- * The producer
  , CaptureCallback
  , captureCallback

    -- * Records
  , Severity (..)
  , classifySeverity
  , severityBits
  , CapturedObject (..)
  , CapturedRecord (..)
  , takeRecord

    -- * Latches and counters
  , Counter (..)
  , Latch (..)
  , SlotStatus (..)
  , slotStatus
  , counterValue
  , latchSet

    -- * Test support
  , Offer (..)
  , plainOffer
  , offer
  , offerMissingData
  , Hold
  , newHold
  , offerHeld
  , offerAnnounced
  , holdArrived
  , releaseHold
  , presetCounter
  ) where

import Control.Exception (Exception, throwIO)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Int (Int32)
import Data.Maybe (fromMaybe)
import Data.Word (Word32, Word64)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Marshal.Array (allocaArray, peekArray, withArray, withArrayLen)
import Foreign.ForeignPtr (ForeignPtr, mallocForeignPtr, withForeignPtr)
import Foreign.Ptr (FunPtr, Ptr, nullPtr)
import Foreign.Storable (peek, poke, pokeByteOff)

-- Limits ---------------------------------------------------------------------

-- | The three bounds a storage is built with.
data Limits = Limits
  { limitQueueCapacity ∷ !Int
    -- ^ Records queued at once. A record offered while this many wait is dropped.
  , limitTextBudget ∷ !Int
    -- ^ Bytes of text copied per record, shared by the message id name, the
    -- message and every object name.
  , limitObjectLimit ∷ !Int
    -- ^ Object identifiers copied per record.
  }
  deriving (Eq, Show)

-- | Which bound was rejected, with the value that was.
data LimitError
  = QueueCapacityRejected !Int
  | TextBudgetRejected !Int
  | ObjectLimitRejected !Int
  | AllocationUnrepresentable !Integer
    -- ^ Each bound fits, but the bytes they need together do not fit in the
    -- sizes the allocation is computed in.
  deriving (Eq, Show)

-- | Check every bound without performing IO.
--
-- Each must be at least one and at most what the C storage counts in, an
-- unsigned 32-bit value; an 'Int' is finite by construction, so these bounds
-- are the whole of "positive and finite". The total the storage would allocate
-- is then computed exactly, in 'Integer', and must be representable as both a
-- C @size_t@ and an 'Int', so no size is ever computed in arithmetic that could
-- wrap.
checkLimits ∷ Limits → Either LimitError Limits
checkLimits limits
  | outOfRange (limitQueueCapacity limits) = Left (QueueCapacityRejected (limitQueueCapacity limits))
  | outOfRange (limitTextBudget limits) = Left (TextBudgetRejected (limitTextBudget limits))
  | outOfRange (limitObjectLimit limits) = Left (ObjectLimitRejected (limitObjectLimit limits))
  | total > largest = Left (AllocationUnrepresentable total)
  | otherwise = Right limits
  where
    outOfRange value = value < 1 || toInteger value > toInteger (maxBound ∷ Word32)
    total = toInteger (limitQueueCapacity limits) * recordFootprint limits
    largest = min (toInteger (maxBound ∷ CSize)) (toInteger (maxBound ∷ Int))

-- | The bytes one queued record needs: its fixed part, its text budget, and its
-- object records.
recordFootprint ∷ Limits → Integer
recordFootprint limits =
  toInteger hetoimasia_capture_record_size
    + toInteger (limitTextBudget limits)
    + toInteger (limitObjectLimit limits) * toInteger hetoimasia_capture_object_size

-- Storage --------------------------------------------------------------------

data StorageT

-- | One C capture storage and the user data its messengers carry. The storage
-- is valid between 'createStorage' and 'freeStorage'. The user data stays safe
-- to hand the producer and to read status by forever: it names a slot of a
-- static table rather than the storage, and answers nothing once that slot
-- serves another storage.
data Storage = Storage !(Ptr StorageT) !(Ptr ())

-- | Why a storage could not be built.
data CreateFailure
  = InvalidLimits !LimitError
  | StorageSizeOverflow
  | StorageOutOfMemory
  | StorageSlotsExhausted
    -- ^ Every slot of the process's static table serves a live storage.
  deriving (Eq, Show)

instance Exception CreateFailure

-- | Build a storage. The limits are checked first, so nothing is allocated for
-- a rejected configuration.
createStorage ∷ Limits → IO Storage
createStorage limits = do
  checked ← either (throwIO . InvalidLimits) pure (checkLimits limits)
  allocaBytes limitsSize $ \cLimits → do
    pokeByteOff cLimits 0 (fromIntegral (limitQueueCapacity checked) ∷ Word32)
    pokeByteOff cLimits 4 (fromIntegral (limitTextBudget checked) ∷ Word32)
    pokeByteOff cLimits 8 (fromIntegral (limitObjectLimit checked) ∷ Word32)
    alloca $ \out → do
      status ← hetoimasia_capture_create cLimits out
      case status of
        0 → do
          storage ← peek out
          pure (Storage storage (hetoimasia_capture_user_data storage))
        1 → throwIO (InvalidLimits (QueueCapacityRejected (limitQueueCapacity checked)))
        2 → throwIO StorageSizeOverflow
        4 → throwIO StorageSlotsExhausted
        _ → throwIO StorageOutOfMemory
  where
    -- Three uint32_t fields, and no padding between or after them.
    limitsSize = 12

-- | Close the storage if it is not closed, and free it; its consumer must not
-- take a record again. Its slot's latches and counters stay readable through
-- 'slotStatus' until another storage claims the slot, and a report still
-- reaching the producer is counted there as a capture failure.
freeStorage ∷ Storage → IO ()
freeStorage (Storage storage _) = hetoimasia_capture_free storage

-- | Stop admission and wait for every producer already inside the callback.
closeStorage ∷ Storage → IO ()
closeStorage (Storage storage _) = hetoimasia_capture_close storage

-- | Whether admission has been closed.
storageClosed ∷ Storage → IO Bool
storageClosed (Storage storage _) = (/= 0) <$> hetoimasia_capture_closed storage

-- | The user data a messenger registers with the producer.
storageUserData ∷ Storage → Ptr ()
storageUserData (Storage _ userData) = userData

-- The producer -------------------------------------------------------------

-- | The C producer's type: severity, message types, callback data, user data.
-- It is the debug-utils messenger callback with each Vulkan type spelled by its
-- width, and it always answers 0.
type CaptureCallback = Word32 → Word32 → Ptr () → Ptr () → IO Word32

-- | The production producer. Installing it is the native backend's business;
-- this package never calls it through this pointer.
captureCallback ∷ FunPtr CaptureCallback
captureCallback = hetoimasia_capture_callback_address

-- Records --------------------------------------------------------------------

-- | A record's severity, classified from its bits before anything else is
-- done with it.
data Severity
  = SeverityVerbose
  | SeverityInfo
  | SeverityWarning
  | SeverityError
  | SeverityUnclassified !Word32
    -- ^ No severity bit this package knows was set.
  deriving (Eq, Ord, Show)

-- | The most severe bit present wins, exactly as the producer latches it.
classifySeverity ∷ Word32 → Severity
classifySeverity bits
  | bits .&. 0x1000 /= 0 = SeverityError
  | bits .&. 0x0100 /= 0 = SeverityWarning
  | bits .&. 0x0010 /= 0 = SeverityInfo
  | bits .&. 0x0001 /= 0 = SeverityVerbose
  | otherwise = SeverityUnclassified bits

-- | The bit a severity is offered with.
severityBits ∷ Severity → Word32
severityBits = \case
  SeverityVerbose → 0x0001
  SeverityInfo → 0x0010
  SeverityWarning → 0x0100
  SeverityError → 0x1000
  SeverityUnclassified bits → bits

-- | One object identifier a record carried.
data CapturedObject = CapturedObject
  { objectType ∷ !Int32
  , objectHandle ∷ !Word64
  , objectName ∷ !(Maybe ByteString)
    -- ^ As much of the name as the record's text budget held.
  }
  deriving (Eq, Show)

-- | One record, copied out of the storage. It owns all of its data: nothing
-- in it points into the storage or at anything the callback was passed.
data CapturedRecord = CapturedRecord
  { recordSeverity ∷ !Severity
  , recordTypes ∷ !Word32
  , recordIdNumber ∷ !Int32
  , recordIdName ∷ !(Maybe ByteString)
  , recordMessage ∷ !ByteString
  , recordTruncated ∷ !Bool
    -- ^ Something the callback carried did not fit.
  , recordObjectsReported ∷ !Word32
    -- ^ How many objects the callback said it carried.
  , recordObjects ∷ ![CapturedObject]
    -- ^ The ones that were copied, at most the object limit.
  }
  deriving (Eq, Show)

-- | Take the oldest published record, if there is one. Only the storage's one
-- consumer may call this.
takeRecord ∷ Storage → IO (Maybe CapturedRecord)
takeRecord (Storage storage _) = do
  record ← hetoimasia_capture_peek storage
  if record == nullPtr
    then pure Nothing
    else do
      captured ← copyRecord record
      hetoimasia_capture_release storage
      pure (Just captured)

copyRecord ∷ Ptr RecordT → IO CapturedRecord
copyRecord record = do
  severity ← hetoimasia_capture_record_severity record
  types ← hetoimasia_capture_record_types record
  number ← hetoimasia_capture_record_id_number record
  hasName ← hetoimasia_capture_record_has_id_name record
  name ←
    if hasName /= 0
      then
        Just
          <$> copyText
            (hetoimasia_capture_record_id_name record)
            (hetoimasia_capture_record_id_name_length record)
      else pure Nothing
  message ←
    copyText
      (hetoimasia_capture_record_message record)
      (hetoimasia_capture_record_message_length record)
  truncated ← hetoimasia_capture_record_truncated record
  reported ← hetoimasia_capture_record_objects_reported record
  count ← hetoimasia_capture_record_object_count record
  objects ← traverse (copyObject record) (takeWhile (< count) [0 ..])
  pure
    CapturedRecord
      { recordSeverity = classifySeverity severity
      , recordTypes = types
      , recordIdNumber = number
      , recordIdName = name
      , recordMessage = message
      , recordTruncated = truncated /= 0
      , recordObjectsReported = reported
      , recordObjects = objects
      }

copyObject ∷ Ptr RecordT → Word32 → IO CapturedObject
copyObject record index = do
  kind ← hetoimasia_capture_record_object_type record index
  handle ← hetoimasia_capture_record_object_handle record index
  hasName ← hetoimasia_capture_record_object_has_name record index
  name ←
    if hasName /= 0
      then
        Just
          <$> copyText
            (hetoimasia_capture_record_object_name record index)
            (hetoimasia_capture_record_object_name_length record index)
      else pure Nothing
  pure CapturedObject {objectType = kind, objectHandle = handle, objectName = name}

copyText ∷ IO CString → IO Word32 → IO ByteString
copyText pointer size = do
  start ← pointer
  len ← size
  ByteString.packCStringLen (start, fromIntegral len)

-- Latches and counters -------------------------------------------------------

-- | The storage's saturating counters.
data Counter
  = Offered
    -- ^ Every call that named a live storage.
  | Admitted
    -- ^ Records queued for the consumer.
  | Dropped
    -- ^ Records lost because the queue was full.
  | Truncated
    -- ^ Admitted records that had to be cut to fit.
  | CaptureFailed
    -- ^ Calls that could not be captured at all: no callback data, or
    -- offered after admission closed.
  | Errors
    -- ^ Error-severity records, whatever became of them.
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The storage's latches, which are set once and never cleared.
data Latch
  = ErrorLatch
    -- ^ An error-severity record was offered.
  | CaptureFailureLatch
    -- ^ A producer-side capture failed.
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Every counter, indexed by 'Counter', and both latches, indexed by 'Latch'.
data SlotStatus = SlotStatus
  { slotCounters ∷ ![Word64]
  , slotLatches ∷ ![Bool]
  }
  deriving (Eq, Show)

-- | The latches and counters of the storage this user data was issued for, or
-- 'Nothing' once its slot serves another. Safe at any time, from any thread,
-- with no consumer running, before and after the storage is freed.
slotStatus ∷ Ptr () → IO (Maybe SlotStatus)
slotStatus userData =
  allocaArray countersLength $ \counters →
    allocaArray 2 $ \latches → do
      current ← hetoimasia_capture_status userData counters latches
      if current == 0
        then pure Nothing
        else do
          values ← peekArray countersLength counters
          flags ← peekArray 2 latches
          pure (Just (SlotStatus values (map (/= 0) flags)))
  where
    countersLength = fromEnum (maxBound ∷ Counter) + 1

-- | One counter, for the package's own examples, which never outlive their
-- storage's slot.
counterValue ∷ Storage → Counter → IO Word64
counterValue storage counter =
  slotStatus (storageUserData storage) >>= \case
    Just status → pure (slotCounters status !! fromEnum counter)
    Nothing → ioError (userError "counterValue: the storage's slot serves another storage")

-- | One latch, likewise.
latchSet ∷ Storage → Latch → IO Bool
latchSet storage which =
  slotStatus (storageUserData storage) >>= \case
    Just status → pure (slotLatches status !! fromEnum which)
    Nothing → ioError (userError "latchSet: the storage's slot serves another storage")

-- Test support ---------------------------------------------------------------

-- | One record to offer through the package-local producer entry.
data Offer = Offer
  { offerSeverity ∷ !Word32
  , offerTypes ∷ !Word32
  , offerIdName ∷ !(Maybe ByteString)
  , offerIdNumber ∷ !Int32
  , offerMessage ∷ !(Maybe ByteString)
  , offerObjects ∷ !(Maybe [(Int32, Word64, Maybe ByteString)])
    -- ^ 'Nothing' passes a NULL object array.
  , offerObjectCount ∷ !(Maybe Word32)
    -- ^ The count the callback data claims; the array's length when 'Nothing'.
  }

-- | A validation-typed record with this severity and message and nothing else.
plainOffer ∷ Severity → ByteString → Offer
plainOffer severity message =
  Offer
    { offerSeverity = severityBits severity
    , offerTypes = 0x2
    , offerIdName = Nothing
    , offerIdNumber = 0
    , offerMessage = Just message
    , offerObjects = Just []
    , offerObjectCount = Nothing
    }

-- | Offer one record exactly as a messenger would: the callback data is built
-- on a C frame and handed to the production producer, with this user data.
offer ∷ Ptr () → Offer → IO ()
offer userData request = submit userData request False

-- | Offer with NULL callback data, the producer-side failure a messenger could
-- hand the callback.
offerMissingData ∷ Ptr () → Offer → IO ()
offerMissingData userData request = submit userData request True

submit ∷ Ptr () → Offer → Bool → IO ()
submit userData request missing =
  withOptional (offerIdName request) $ \idName →
    withOptional (offerMessage request) $ \message →
      case offerObjects request of
        Nothing →
          call idName message (fromMaybe 0 (offerObjectCount request)) nullPtr nullPtr nullPtr
        Just objects →
          withArray [kind | (kind, _, _) ← objects] $ \kinds →
            withArray [handle | (_, handle, _) ← objects] $ \handles →
              withNames [name | (_, _, name) ← objects] $ \names →
                call
                  idName
                  message
                  (fromMaybe (fromIntegral (length objects)) (offerObjectCount request))
                  kinds
                  handles
                  names
  where
    call idName message count kinds handles names = do
      _ ←
        hetoimasia_capture_offer
          userData
          (offerSeverity request)
          (offerTypes request)
          idName
          (offerIdNumber request)
          message
          count
          kinds
          handles
          names
          (if missing then 1 else 0)
      pure ()

-- | A NUL-terminated copy of the text, or NULL.
withOptional ∷ Maybe ByteString → (CString → IO a) → IO a
withOptional Nothing continue = continue nullPtr
withOptional (Just text) continue = ByteString.useAsCString text continue

withNames ∷ [Maybe ByteString] → (Ptr CString → IO a) → IO a
withNames names continue = go names []
  where
    go [] acquired = withArrayLen (reverse acquired) (\_ → continue)
    go (name : rest) acquired = withOptional name (\pointer → go rest (pointer : acquired))

-- | A producer held between entering the callback and announcing itself.
data Hold = Hold !(ForeignPtr CInt) !(ForeignPtr CInt)

newHold ∷ IO Hold
newHold = do
  arrived ← mallocForeignPtr
  gate ← mallocForeignPtr
  withForeignPtr arrived (`poke` 0)
  withForeignPtr gate (`poke` 0)
  pure (Hold arrived gate)

-- | Offer one plain record, held at the callback's entry until 'releaseHold'.
-- Blocks the calling thread for as long as it is held; run it on its own.
offerHeld ∷ Ptr () → Hold → Severity → ByteString → IO ()
offerHeld userData (Hold arrived gate) severity message =
  withForeignPtr arrived $ \arrivedPtr →
    withForeignPtr gate $ \gatePtr →
      ByteString.useAsCString message $ \text →
        () <$ hetoimasia_capture_offer_held userData arrivedPtr gatePtr (severityBits severity) text

-- | Offer one plain record through the production producer, held just after it
-- has announced itself until 'releaseHold'. Closing waits for it there.
offerAnnounced ∷ Ptr () → Hold → Severity → ByteString → IO ()
offerAnnounced userData (Hold arrived gate) severity message =
  withForeignPtr arrived $ \arrivedPtr →
    withForeignPtr gate $ \gatePtr →
      ByteString.useAsCString message $ \text →
        () <$ hetoimasia_capture_offer_announced userData arrivedPtr gatePtr (severityBits severity) text

-- | Whether the held producer has entered the callback.
holdArrived ∷ Hold → IO Bool
holdArrived (Hold arrived _) = withForeignPtr arrived (fmap (/= 0) . hetoimasia_capture_flag_get)

-- | Let the held producer go on.
releaseHold ∷ Hold → IO ()
releaseHold (Hold _ gate) = withForeignPtr gate hetoimasia_capture_flag_set

-- | Set a counter directly, so saturation can be shown.
presetCounter ∷ Storage → Counter → Word64 → IO ()
presetCounter (Storage storage _) counter = hetoimasia_capture_preset_counter storage (fromIntegral (fromEnum counter))

-- Imports --------------------------------------------------------------------

data RecordT

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_record_size"
  hetoimasia_capture_record_size ∷ CSize

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_object_size"
  hetoimasia_capture_object_size ∷ CSize

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_create"
  hetoimasia_capture_create ∷ Ptr () → Ptr (Ptr StorageT) → IO CInt

foreign import ccall safe "hetoimasia_vulkan_capture.h hetoimasia_capture_free"
  hetoimasia_capture_free ∷ Ptr StorageT → IO ()

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_user_data"
  hetoimasia_capture_user_data ∷ Ptr StorageT → Ptr ()

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_status"
  hetoimasia_capture_status ∷ Ptr () → Ptr Word64 → Ptr CInt → IO CInt

foreign import ccall safe "hetoimasia_vulkan_capture.h hetoimasia_capture_offer_announced"
  hetoimasia_capture_offer_announced ∷ Ptr () → Ptr CInt → Ptr CInt → Word32 → CString → IO Word32

foreign import ccall safe "hetoimasia_vulkan_capture.h hetoimasia_capture_offer_held"
  hetoimasia_capture_offer_held ∷ Ptr () → Ptr CInt → Ptr CInt → Word32 → CString → IO Word32

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_flag_set"
  hetoimasia_capture_flag_set ∷ Ptr CInt → IO ()

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_flag_get"
  hetoimasia_capture_flag_get ∷ Ptr CInt → IO CInt

foreign import ccall safe "hetoimasia_vulkan_capture.h hetoimasia_capture_close"
  hetoimasia_capture_close ∷ Ptr StorageT → IO ()

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_closed"
  hetoimasia_capture_closed ∷ Ptr StorageT → IO CInt

foreign import ccall unsafe "hetoimasia_vulkan_capture.h &hetoimasia_capture_callback"
  hetoimasia_capture_callback_address ∷ FunPtr CaptureCallback

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_peek"
  hetoimasia_capture_peek ∷ Ptr StorageT → IO (Ptr RecordT)

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_release"
  hetoimasia_capture_release ∷ Ptr StorageT → IO ()

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_record_severity"
  hetoimasia_capture_record_severity ∷ Ptr RecordT → IO Word32

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_record_types"
  hetoimasia_capture_record_types ∷ Ptr RecordT → IO Word32

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_record_id_number"
  hetoimasia_capture_record_id_number ∷ Ptr RecordT → IO Int32

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_record_has_id_name"
  hetoimasia_capture_record_has_id_name ∷ Ptr RecordT → IO CInt

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_record_id_name"
  hetoimasia_capture_record_id_name ∷ Ptr RecordT → IO CString

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_record_id_name_length"
  hetoimasia_capture_record_id_name_length ∷ Ptr RecordT → IO Word32

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_record_message"
  hetoimasia_capture_record_message ∷ Ptr RecordT → IO CString

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_record_message_length"
  hetoimasia_capture_record_message_length ∷ Ptr RecordT → IO Word32

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_record_truncated"
  hetoimasia_capture_record_truncated ∷ Ptr RecordT → IO CInt

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_record_objects_reported"
  hetoimasia_capture_record_objects_reported ∷ Ptr RecordT → IO Word32

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_record_object_count"
  hetoimasia_capture_record_object_count ∷ Ptr RecordT → IO Word32

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_record_object_type"
  hetoimasia_capture_record_object_type ∷ Ptr RecordT → Word32 → IO Int32

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_record_object_handle"
  hetoimasia_capture_record_object_handle ∷ Ptr RecordT → Word32 → IO Word64

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_record_object_has_name"
  hetoimasia_capture_record_object_has_name ∷ Ptr RecordT → Word32 → IO CInt

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_record_object_name"
  hetoimasia_capture_record_object_name ∷ Ptr RecordT → Word32 → IO CString

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_record_object_name_length"
  hetoimasia_capture_record_object_name_length ∷ Ptr RecordT → Word32 → IO Word32

foreign import ccall unsafe "hetoimasia_vulkan_capture.h hetoimasia_capture_preset_counter"
  hetoimasia_capture_preset_counter ∷ Ptr StorageT → CInt → Word64 → IO ()

foreign import ccall safe "hetoimasia_vulkan_capture.h hetoimasia_capture_offer"
  hetoimasia_capture_offer
    ∷ Ptr ()
    → Word32
    → Word32
    → CString
    → Int32
    → CString
    → Word32
    → Ptr Int32
    → Ptr Word64
    → Ptr CString
    → CInt
    → IO Word32
