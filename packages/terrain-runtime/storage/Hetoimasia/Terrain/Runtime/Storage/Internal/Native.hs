-- | The native adapter and the seam around it.
--
-- 'Native' is the record of every raw operation the backend performs on a
-- descriptor. 'posixNative' is the production adapter, a thin layer over the C
-- shim in @cbits/hetoimasia_terrain_storage.c@: each operation reports its
-- failure as a negated errno that the Haskell side reads from the return value,
-- never from @errno@.
--
-- 'Seam' pairs an adapter with hooks the backend calls around every native
-- operation, on the thread that performs it. The production seam ignores them. A
-- test builds its own seam from the production adapter, to count acquisitions
-- and closes, to hold an operation at a named point, or to replace one operation
-- with a fault; it never bypasses the owner path, because the backend calls the
-- same functions either way. This module is internal: the public interface
-- exposes neither the record nor the hooks, so a client cannot reach a raw
-- descriptor or a seam.
--
-- A 'Fd' is the descriptor number and nothing more. Whether it is still open is
-- the owning backing's business, never this module's: a client of the backend
-- never holds one.
--
-- == Which foreign calls are @safe@, @unsafe@ or @interruptible@
--
-- Every import below is @safe@. A call may block in the kernel for as long as the
-- filesystem takes (a reservation on a slow device, a write waiting on the
-- device), and a @safe@ call releases the capability so the other Haskell
-- threads, the terrain owner included, keep running; this needs the threaded
-- runtime, which the service checks at its start. None is @unsafe@: an unsafe
-- call holds its capability for the whole call, and even a call that is usually
-- fast (an @fstat@ on a network filesystem) is not guaranteed to be. None is
-- @interruptible@: an interruptible call is abandoned with @EINTR@ when an
-- asynchronous exception arrives, and the backend promises the opposite, that
-- cancellation is an ownership protocol and never an attempt to interrupt a call
-- in progress or to close a descriptor under it.
module Hetoimasia.Terrain.Runtime.Storage.Internal.Native
  ( Fd
  , fdNumber
  , NativeStat (..)
  , NativeFs (..)
  , Native (..)
  , NativeOp (..)
  , Seam (..)
  , posixNative
  , productionSeam
  , seamed
  , Owns (..)
  , around
  , errnoText
  ) where

import Control.Exception (mask_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Word (Word64, Word8)
import Foreign.C.String (CString, peekCString)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Marshal.Array (allocaArray, peekArray)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (peek)
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types (Errno (..))

-- | A descriptor number.
newtype Fd = Fd CInt
  deriving stock (Eq, Ord, Show)

fdNumber ∷ Fd → Int
fdNumber (Fd n) = fromIntegral n

-- | What @fstat@ reported.
data NativeStat = NativeStat
  { nsDevice ∷ !Word64
  , nsSize ∷ !Word64
  , nsAllocated ∷ !Word64
  -- ^ @st_blocks * 512@: the bytes the filesystem says the file occupies.
  , nsLinks ∷ !Word64
  , nsMode ∷ !Word64
  , nsOwner ∷ !Word64
  }
  deriving stock (Eq, Show)

-- | What @fstatfs@ reported for the descriptor's own filesystem.
data NativeFs = NativeFs
  { nfBlockSize ∷ !Word64
  , nfTotalBytes ∷ !Word64
  , nfAvailableBytes ∷ !Word64
  -- ^ Available to an unprivileged process, root-reserved blocks excluded.
  , nfTypeNumber ∷ !Word64
  , nfTypeName ∷ !ByteString
  }
  deriving stock (Eq, Show)

-- | Every raw operation, each failing with an errno.
data Native = Native
  { nativeCreate ∷ ByteString → ByteString → IO (Either Errno Fd)
  -- ^ Create a file exclusively beneath a directory (private permissions,
  -- close-on-exec).
  , nativeUnlink ∷ ByteString → ByteString → IO (Either Errno ())
  , nativeCloexec ∷ Fd → IO (Either Errno Bool)
  , nativeStat ∷ Fd → IO (Either Errno NativeStat)
  , nativeStatFs ∷ Fd → IO (Either Errno NativeFs)
  , nativeReserve ∷ Fd → Word64 → Word64 → IO (Either Errno Word64)
  -- ^ Reserve a range natively; answers the bytes the platform reported
  -- allocating.
  , nativeSetLength ∷ Fd → Word64 → IO (Either Errno ())
  , nativePread ∷ Fd → Ptr Word8 → Int → Word64 → IO (Either Errno Int)
  , nativePwrite ∷ Fd → Ptr Word8 → Int → Word64 → IO (Either Errno Int)
  , nativeClose ∷ Fd → IO (Either Errno ())
  }

-- | The operations a hook can see. The payload names where the operation acts,
-- so a test can hold or fail one specific transfer.
data NativeOp
  = OpCreateFile
  | OpUnlinkFile
  | OpCloexecFlag
  | OpStatFile
  | OpStatFilesystem
  | OpReserveRange !Word64 !Word64
  | OpSetFileLength !Word64
  | OpReadAt !Word64 !Int
  | OpWriteAt !Word64 !Int
  | OpCloseFile
  | -- | A worker is about to wait for the coordination of a volume (not a native
    -- call: the point where two reservations on one volume are serialized).
    OpVolumeWait !Word64
  | -- | A worker is starting (not a native call: the point where a start can fail).
    OpWorkerStart !Int
  | -- | A worker is ending (its scope's release: the point a join can be held).
    OpWorkerStop !Int
  deriving stock (Eq, Show)

-- | An adapter and its hooks. The hooks run on the thread performing the
-- operation, immediately before and after the native call; the descriptor the
-- operation names is protected by its scope at both.
data Seam = Seam
  { seamNative ∷ Native
  , seamBefore ∷ NativeOp → IO ()
  , seamAfter ∷ NativeOp → IO ()
  }

-- | The production seam: the POSIX adapter and no hooks.
productionSeam ∷ Seam
productionSeam = Seam posixNative (\_ → pure ()) (\_ → pure ())

-- | The same adapter observed by hooks around each operation.
seamed ∷ Native → (NativeOp → IO ()) → (NativeOp → IO ()) → Seam
seamed = Seam

-- | What a native effect obtained that an owner must release. The seam is a port: its after-hook can raise or be
-- cancelled while blocked, and the effect has then already HAPPENED, so the hook must never be able to lose what the
-- effect obtained.
data Owns a
  = -- | The effect obtained nothing an owner must release (a query; a length, an allocation or a transfer, whose
    -- owner is the descriptor and which the caller gives back or accounts on any exception; a release or a close,
    -- whose result a lost hook turns into an exception that is recorded and never retried).
    NothingAcquired
  | -- | The effect obtained something: the recorder runs FIRST, before the after-hook, so the thing already has
    -- its owner when the hook runs.
    Acquires (a → IO ())

-- | THE ONE WAY a native effect runs between its hooks: the before-hook, the effect, the recorder of what it
-- obtained, and only then the after-hook. Every site says what it acquires. It does NOT rely on its caller being
-- masked: for an effect that acquires something, the effect and its recorder run together under 'mask_' (a safe
-- foreign call is not interruptible, so nothing else changes), so there is no unmasked point between the effect and
-- the record of what it obtained, whoever calls; the hooks stay outside the mask, where a cancellation can reach a
-- blocked one.
around ∷ Seam → NativeOp → Owns a → IO a → IO a
around seam op owns act = do
  seamBefore seam op
  r ← case owns of
    NothingAcquired → act
    Acquires record → mask_ (act >>= \x → record x >> pure x)
  seamAfter seam op
  pure r

foreign import ccall safe "hts_create"
  c_create ∷ CString → CString → Ptr CInt → IO CInt

foreign import ccall safe "hts_unlink"
  c_unlink ∷ CString → CString → IO CInt

foreign import ccall safe "hts_cloexec"
  c_cloexec ∷ CInt → Ptr CInt → IO CInt

foreign import ccall safe "hts_stat"
  c_stat ∷ CInt → Ptr Word64 → IO CInt

foreign import ccall safe "hts_statfs"
  c_statfs ∷ CInt → Ptr Word64 → Ptr Word8 → IO CInt

foreign import ccall safe "hts_reserve"
  c_reserve ∷ CInt → Word64 → Word64 → Ptr Word64 → IO CInt

foreign import ccall safe "hts_set_length"
  c_set_length ∷ CInt → Word64 → IO CInt

foreign import ccall safe "hts_pread"
  c_pread ∷ CInt → Ptr Word8 → CSize → Word64 → IO Word64

foreign import ccall safe "hts_pwrite"
  c_pwrite ∷ CInt → Ptr Word8 → CSize → Word64 → IO Word64

foreign import ccall safe "hts_close"
  c_close ∷ CInt → IO CInt

-- | A negated errno, or the success value.
status ∷ CInt → a → Either Errno a
status r ok
  | r < 0 = Left (Errno (fromIntegral (negate r)))
  | otherwise = Right ok

-- | The two's-complement count a transfer returns: a negated errno when negative.
transferred ∷ Word64 → Either Errno Int
transferred w
  | w >= 0x8000000000000000 = Left (Errno (fromIntegral (negate (fromIntegral w ∷ Int))))
  | otherwise = Right (fromIntegral w)

withName ∷ ByteString → (CString → IO a) → IO a
withName = BS.useAsCString

-- | The production adapter.
posixNative ∷ Native
posixNative =
  Native
    { nativeCreate = \dir name →
        withName dir $ \d → withName name $ \n → alloca $ \out → do
          r ← c_create d n out
          if r < 0 then pure (status r undefined) else Right . Fd <$> peek out
    , nativeUnlink = \dir name → withName dir $ \d → withName name $ \n → (\r → status r ()) <$> c_unlink d n
    , nativeCloexec = \(Fd fd) → alloca $ \out → do
        r ← c_cloexec fd out
        if r < 0 then pure (status r undefined) else Right . (/= 0) <$> peek out
    , nativeStat = \(Fd fd) → allocaArray 6 $ \out → do
        r ← c_stat fd out
        if r < 0
          then pure (status r undefined)
          else do
            [dev, size, alloc, links, mode, owner] ← peekArray 6 out
            pure (Right (NativeStat dev size alloc links mode owner))
    , nativeStatFs = \(Fd fd) → allocaArray 4 $ \out → allocaBytes 32 $ \name → do
        r ← c_statfs fd out name
        if r < 0
          then pure (status r undefined)
          else do
            [unit, total, avail, typeNo] ← peekArray 4 out
            fsName ← peekCString (castPtr name)
            pure (Right (NativeFs unit total avail typeNo (BC.pack fsName)))
    , nativeReserve = \(Fd fd) off len → alloca $ \out → do
        r ← c_reserve fd off len out
        if r < 0 then pure (status r undefined) else Right <$> peek out
    , nativeSetLength = \(Fd fd) len → (\r → status r ()) <$> c_set_length fd len
    , nativePread = \(Fd fd) buf n off → transferred <$> c_pread fd buf (fromIntegral n) off
    , nativePwrite = \(Fd fd) buf n off → transferred <$> c_pwrite fd buf (fromIntegral n) off
    , nativeClose = \(Fd fd) → (\r → status r ()) <$> c_close fd
    }

-- | A descriptor-free rendering of an errno for diagnostics.
errnoText ∷ Errno → String
errnoText (Errno n) = "errno " <> show n
