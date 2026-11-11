-- | One backing file, as a sequence of native steps with typed outcomes: its
-- private creation, the qualified reservation of a range, the exact bounded
-- transfer of a page and the release of an extra reservation.
--
-- Nothing here owns a descriptor's lifetime or knows about workers, queues or
-- accounting: that is "Hetoimasia.Terrain.Runtime.Storage.Internal.Service". A
-- function takes the 'Fd' it acts on and answers a value; it never closes one
-- (except 'closeFile', the one place a close is made, which never retries).
--
-- == The reservation contract
--
-- 'reserveRange' obtains a real native reservation and then proves it. Its steps,
-- each one a failure the caller classifies:
--
-- 1. the filesystem the descriptor is on is on the qualified list, else
--    @storage_unsupported@ (even if the native call would have succeeded);
-- 2. the free space that the unprivileged process sees on that volume leaves the
--    configured headroom (256 MiB at least) after the request, else
--    @reservation_failed@;
-- 3. the native allocation (@F_PREALLOCATE@ with @F_ALLOCATEALL@ on macOS,
--    @fallocate@ mode 0 on Linux); an unsupported call is @storage_unsupported@, a
--    refused one @reservation_failed@; the platform's own count of allocated
--    bytes must equal the request;
-- 4. the file length is established (checked);
-- 5. the filesystem's own report of the file's allocated bytes covers the whole
--    length. A sparse file of the right length passes steps 3 and 4 and fails
--    here: this check is what makes a reservation more than a length.
module Hetoimasia.Terrain.Runtime.Storage.Internal.File
  ( -- * Creation
    Created (..)
  , createPrivate
  , unlinkFile
  , verifyPrivate

    -- * Reservation
  , Reserved (..)
  , Stopped (..)
  , reserveRange
  , releaseExtra

    -- * Transfers
  , ReadError (..)
  , readFully
  , writeFully

    -- * Closing
  , closeFile
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Data.Word (Word64, Word8)
import Foreign.C.Error (Errno (..), eEXIST, eINTR, eNOSYS, eNOTSUP, eOPNOTSUPP)
import Foreign.Ptr (Ptr, plusPtr)
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native
import qualified Hetoimasia.Terrain.Runtime.Storage.Internal.Types as T
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types
  ( IoFailure (..)
  , IoKind (..)
  , IoOp (..)
  , ReservationFailure (..)
  , ReservationOp (..)
  , StorageConfig (..)
  , StorageFailure (..)
  , UnsupportedWhy (..)
  )
import Hetoimasia.Terrain.Runtime.Storage.Internal.Volume

-- | Run a native operation between its hooks.
around ∷ Seam → NativeOp → IO a → IO a
around seam op act = seamBefore seam op *> act <* seamAfter seam op

errnoValue ∷ T.Errno → Int
errnoValue (T.Errno n) = n

isErrno ∷ Errno → T.Errno → Bool
isErrno (Errno c) e = fromIntegral c == errnoValue e

-- | The errnos that mean the native call or the filesystem lacks the
-- mechanism, rather than that this request could not be met.
unsupportedErrno ∷ T.Errno → Bool
unsupportedErrno e = any (`isErrno` e) [eNOTSUP, eOPNOTSUPP, eNOSYS]

ioFailure ∷ IoOp → T.Errno → Maybe Word64 → IoFailure
ioFailure op e off = IoFailure op (IoErrno e) Nothing off 0 0

-- ---------------------------------------------------------------------------
-- Creation

-- | A file created, with the name that was used.
data Created = Created
  { crFd ∷ !Fd
  , crName ∷ !ByteString
  }

-- | Create a private file exclusively beneath a directory: private permissions,
-- close-on-exec, never following a link. The name is derived from the caller's
-- unique number, and an existing name (@EEXIST@) takes the next attempt, at most
-- eight in all, so a name clash is bounded and never an overwrite.
createPrivate ∷ Seam → ByteString → Word64 → IO (Either IoFailure Created)
createPrivate seam dir unique = go (0 ∷ Int)
  where
    go attempt = do
      let name = BC.pack ("hetoimasia-terrain-" <> show unique <> "-" <> show attempt)
      r ← around seam OpCreateFile (nativeCreate (seamNative seam) dir name)
      case r of
        Right fd → pure (Right (Created fd name))
        Left e
          | isErrno eEXIST e && attempt < 7 → go (attempt + 1)
          | otherwise → pure (Left (ioFailure IoCreate e Nothing))

-- | Remove the file's name (the descriptor keeps the file).
unlinkFile ∷ Seam → ByteString → ByteString → IO (Either T.Errno ())
unlinkFile seam dir name = around seam OpUnlinkFile (nativeUnlink (seamNative seam) dir name)

-- | The checks a private file must pass before it is used: close-on-exec is set
-- on the descriptor, the file has no name left, and only its owner can open it.
-- A descriptor that could leak through a child's @exec@ is a setup failure.
verifyPrivate ∷ Seam → Fd → IO (Either IoFailure NativeStat)
verifyPrivate seam fd = do
  flag ← around seam OpCloexecFlag (nativeCloexec (seamNative seam) fd)
  case flag of
    Left e → pure (Left (ioFailure IoCloexec e Nothing))
    Right False → pure (Left (IoFailure IoCloexec IoStateWrong Nothing Nothing 0 0))
    Right True → do
      st ← around seam OpStatFile (nativeStat (seamNative seam) fd)
      pure $ case st of
        Left e → Left (ioFailure IoStat e Nothing)
        Right s
          | nsLinks s /= 0 → Left (IoFailure IoUnlink IoStateWrong Nothing Nothing (nsLinks s) 0)
          | otherwise → Right s

-- ---------------------------------------------------------------------------
-- Reservation

-- | A reservation that was obtained and proven.
data Reserved = Reserved
  { rvAllocated ∷ !Word64
  -- ^ The bytes the filesystem reports the file occupies.
  , rvLength ∷ !Word64
  -- ^ The file length that was established.
  , rvOverhead ∷ !Word64
  -- ^ What it occupies beyond its length (rounding and format overhead).
  , rvProfile ∷ !VolumeProfile
  -- ^ The volume as it was before the reservation.
  }
  deriving stock (Eq, Show)

-- | Why a step did not finish: a failure, or a cancellation seen between steps.
data Stopped = StoppedFailure !StorageFailure | StoppedCancelled
  deriving stock (Eq, Show)

-- | Reserve @[off, off + len)@ and prove it. The caller holds the volume's
-- coordination for the whole call, so no other reservation spends the headroom
-- observed here. The cancellation test is read between steps; a stop leaves
-- whatever the native steps obtained for the caller to release.
reserveRange ∷ Seam → StorageConfig → IO Bool → Fd → Word64 → Word64 → IO (Either Stopped Reserved)
reserveRange seam cfg cancelled fd off len = do
  prof ← profileOf seam fd
  case prof of
    Left (op, e) → pure (Left (StoppedFailure (StorageIo (ioFailure op e Nothing))))
    Right p
      | not (qualifies (scQualified cfg) p) → pure (stopFail (StorageUnsupported (FilesystemNotQualified (vpFilesystem p))))
      | otherwise → case headroomLeft p of
          Nothing → pure (stopFail (ReservationFailed (InsufficientHeadroom (vpAvailableBytes p) len (scHeadroomBytes cfg))))
          Just () → afterCheck p
  where
    end = off + len
    stopFail = Left . StoppedFailure
    headroomLeft p = case availableAfter p len of
      Just left | left >= scHeadroomBytes cfg → Just ()
      _ → Nothing
    afterCheck p = do
      stopped0 ← cancelled
      if stopped0
        then pure (Left StoppedCancelled)
        else do
          r ← around seam (OpReserveRange off len) (nativeReserve (seamNative seam) fd off len)
          case r of
            Left e
              | unsupportedErrno e → pure (stopFail (StorageUnsupported (NativeUnsupported StepAllocate e)))
              | otherwise → pure (stopFail (ReservationFailed (AllocationRefused e)))
            Right reported
              | reported /= len → pure (stopFail (ReservationFailed (AllocationShort reported len)))
              | otherwise → establish p
    establish p = do
      stopped1 ← cancelled
      if stopped1
        then pure (Left StoppedCancelled)
        else do
          l ← around seam (OpSetFileLength end) (nativeSetLength (seamNative seam) fd end)
          case l of
            Left e → pure (stopFail (ReservationFailed (LengthFailed e)))
            Right () → verify p
    verify p = do
      st ← around seam OpStatFile (nativeStat (seamNative seam) fd)
      pure $ case st of
        Left e → stopFail (StorageIo (ioFailure IoStat e Nothing))
        Right s
          | nsSize s /= end → stopFail (ReservationFailed (LengthMismatch (nsSize s) end))
          | nsAllocated s < end → stopFail (ReservationFailed (CoverageShort (nsAllocated s) end))
          | otherwise → Right (Reserved (nsAllocated s) (nsSize s) (nsAllocated s - end) p)

-- | Give back the reservation of @[from, to)@: make sure the file is at least
-- @to@ long, then set it to @from@. Truncating a file to the length it already
-- has releases nothing that was preallocated beyond its end on APFS (measured in
-- the qualification), so the length is raised first: the blocks beyond @from@ are
-- then inside the file, and shortening it frees them on both targets.
releaseExtra ∷ Seam → Fd → Word64 → Word64 → IO (Either T.Errno ())
releaseExtra seam fd from to = do
  st ← around seam OpStatFile (nativeStat (seamNative seam) fd)
  case st of
    Left e → pure (Left e)
    Right s → do
      up ← if nsSize s < to then around seam (OpSetFileLength to) (nativeSetLength (seamNative seam) fd to) else pure (Right ())
      case up of
        Left e → pure (Left e)
        Right () → around seam (OpSetFileLength from) (nativeSetLength (seamNative seam) fd from)

-- ---------------------------------------------------------------------------
-- Transfers

-- | A read that did not complete.
data ReadError
  = ReadFailed !IoFailure
  | -- | The file ended inside the transfer: bytes read, bytes wanted.
    ReadEnded !Word64 !Word64

-- | Read exactly @n@ bytes at an offset into a buffer. A short read advances the
-- offset and the buffer position by what was read; an interrupted call is retried
-- without repeating bytes, at most 'T.maxInterrupts' times in a row; zero bytes
-- before the end is a premature end of file. The loop ends in at most one failure
-- or after the bytes are all in: it cannot spin.
readFully ∷ Seam → Ptr Word8 → Int → Word64 → Fd → IO (Either ReadError ())
readFully seam buf n off fd = go 0 (0 ∷ Int)
  where
    go done storm
      | done >= n = pure (Right ())
      | otherwise = do
          let want = n - done
              at = off + fromIntegral done
          r ← around seam (OpReadAt at want) (nativePread (seamNative seam) fd (buf `plusPtr` done) want at)
          case r of
            Right 0 → pure (Left (ReadEnded (fromIntegral done) (fromIntegral n)))
            Right got
              | got > want → pure (Left (ReadFailed (IoFailure IoRead IoOverrun Nothing (Just at) (fromIntegral done) (fromIntegral n))))
              | otherwise → go (done + got) 0
            Left e
              | isErrno eINTR e → if storm + 1 > T.maxInterrupts then pure (Left (ReadFailed (IoFailure IoRead IoInterruptStorm Nothing (Just at) (fromIntegral done) (fromIntegral n)))) else go done (storm + 1)
              | otherwise → pure (Left (ReadFailed (IoFailure IoRead (IoErrno e) Nothing (Just at) (fromIntegral done) (fromIntegral n))))

-- | Write exactly @n@ bytes at an offset, with the same rules. A call that makes
-- no progress is 'IoZeroProgress', never a retry.
writeFully ∷ Seam → Ptr Word8 → Int → Word64 → Fd → IO (Either IoFailure ())
writeFully seam buf n off fd = go 0 (0 ∷ Int)
  where
    go done storm
      | done >= n = pure (Right ())
      | otherwise = do
          let want = n - done
              at = off + fromIntegral done
              fail' k = IoFailure IoWrite k Nothing (Just at) (fromIntegral done) (fromIntegral n)
          r ← around seam (OpWriteAt at want) (nativePwrite (seamNative seam) fd (buf `plusPtr` done) want at)
          case r of
            Right 0 → pure (Left (fail' IoZeroProgress))
            Right put
              | put > want → pure (Left (fail' IoOverrun))
              | otherwise → go (done + put) 0
            Left e
              | isErrno eINTR e → if storm + 1 > T.maxInterrupts then pure (Left (fail' IoInterruptStorm)) else go done (storm + 1)
              | otherwise → pure (Left (fail' (IoErrno e)))

-- ---------------------------------------------------------------------------
-- Closing

-- | Close a descriptor, once. A failure is returned and the close is never
-- repeated: the descriptor may already be released, and a second close could
-- close another resource that reused its number.
closeFile ∷ Seam → Fd → IO (Either T.Errno ())
closeFile seam fd = around seam OpCloseFile (nativeClose (seamNative seam) fd)
