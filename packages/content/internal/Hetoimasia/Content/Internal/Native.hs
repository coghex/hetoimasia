-- | The native adapter and the seam around it.
--
-- 'Native' is the record of every raw operation the service performs on a
-- descriptor. 'posixNative' is the production adapter, a thin layer over the C
-- shim in @cbits/hetoimasia_content.c@: directory-relative @openat@ with
-- @O_NOFOLLOW@, @fstat@, @fstatat@ without following, @fdopendir@ and @read@,
-- each reporting its failure as a negated errno the Haskell side reads from the
-- return value, never from @errno@.
--
-- 'Seam' pairs an adapter with 'Boundary' hooks the operations call at named
-- points. The production seam ignores the hooks. A test builds its own seam
-- from the production adapter, to count acquisitions and closes, to inject a
-- native failure or an identity, or to pause an operation at a boundary. This
-- module is internal: the public package exposes neither the record nor the
-- hooks, so a client cannot reach a raw descriptor or a seam.
--
-- A 'NativeFd' is the descriptor number and nothing more. Whether it is still
-- open is the owning scope's business, never this module's.
module Hetoimasia.Content.Internal.Native
  ( NativeFd (..)
  , NativeStream (..)
  , NativeStat (..)
  , Native (..)
  , Boundary (..)
  , Seam (..)
  , posixNative
  , productionSeam
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BSU
import Data.Word (Word64, Word8)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Marshal.Array (allocaArray, peekArray)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (peek)
import Hetoimasia.Content.Internal.Types

-- | A descriptor number.
newtype NativeFd = NativeFd CInt
  deriving (Eq, Ord, Show)

-- | A directory stream, owning the descriptor it was made from.
newtype NativeStream = NativeStream (Ptr ())
  deriving (Eq, Show)

-- | What @fstat@ or @fstatat@ reported.
data NativeStat = NativeStat
  { statKind ∷ !EntryKind
  , statIdentity ∷ !NativeIdentity
  , statSize ∷ !Word64
  , statLinks ∷ !Word64
  }
  deriving (Eq, Show)

-- | Every raw operation, each failing with an errno.
data Native = Native
  { nativeOpenRoot ∷ ByteString → IO (Either Int NativeFd)
  -- ^ Open the launch path as a directory, following symbolic links.
  , nativeOpenAt ∷ NativeFd → NativeName → Bool → IO (Either Int NativeFd)
  -- ^ Open an entry beneath a directory without following a final link; the
  -- flag asks for a directory.
  , nativeFstat ∷ NativeFd → IO (Either Int NativeStat)
  , nativeStatAt ∷ NativeFd → NativeName → IO (Either Int NativeStat)
  -- ^ A no-follow type query. It classifies; it never authorizes an open.
  , nativeOpenStream ∷ NativeFd → IO (Either Int NativeStream)
  -- ^ @fdopendir@. On success the stream owns the descriptor and the caller
  -- must not close it; on failure the descriptor is still the caller's.
  , nativeStreamFd ∷ NativeStream → IO NativeFd
  , nativeReadStream ∷ NativeStream → IO (Either Int (Maybe ByteString))
  -- ^ The next raw name, structural entries included; 'Nothing' at the end.
  , nativeCloseStream ∷ NativeStream → IO (Either Int ())
  -- ^ Release the stream and its descriptor.
  , nativeRead ∷ NativeFd → Ptr Word8 → Int → IO (Either Int Int)
  , nativeClose ∷ NativeFd → IO (Either Int ())
  , nativeFdPath ∷ NativeFd → IO (Either Int ByteString)
  }

-- | The points an operation announces to its seam. Each is called on the
-- thread running the operation, at the place the constructor names, with the
-- handles that place holds already protected by their scope.
data Boundary
  = RootOpened
  -- ^ The root descriptor is tracked; qualification has not begun.
  | OperationAdmitted
  -- ^ An operation holds its admission and has acquired nothing.
  | BeforeOpen !Int !NativeName
  -- ^ About to open component @i@ below its held parent.
  | AfterOpen !Int !NativeName
  -- ^ The component is open and its scope holds the descriptor.
  | AfterStream !Int !NativeName
  -- ^ The component became a stream: the stream now owns the descriptor.
  | BeforeRead
  | AfterRead
  | DrainStarted
  -- ^ The root's exit closed admission and is about to wait for borrows.
  deriving (Eq, Show)

-- | An adapter and its boundary hooks.
data Seam = Seam
  { seamNative ∷ Native
  , seamBoundary ∷ Boundary → IO ()
  }

-- | The production seam: the POSIX adapter and no hooks.
productionSeam ∷ Seam
productionSeam = Seam {seamNative = posixNative, seamBoundary = \_ → pure ()}

foreign import ccall safe "hetc_open_root"
  c_open_root ∷ CString → Ptr CInt → IO CInt

foreign import ccall safe "hetc_openat"
  c_openat ∷ CInt → CString → CInt → Ptr CInt → IO CInt

foreign import ccall safe "hetc_fstat"
  c_fstat ∷ CInt → Ptr Word64 → IO CInt

foreign import ccall safe "hetc_fstatat_nofollow"
  c_fstatat ∷ CInt → CString → Ptr Word64 → IO CInt

foreign import ccall safe "hetc_fdopendir"
  c_fdopendir ∷ CInt → Ptr (Ptr ()) → IO CInt

foreign import ccall unsafe "hetc_dirfd"
  c_dirfd ∷ Ptr () → IO CInt

foreign import ccall safe "hetc_readdir"
  c_readdir ∷ Ptr () → Ptr Word8 → CSize → Ptr CSize → IO CInt

foreign import ccall safe "hetc_closedir"
  c_closedir ∷ Ptr () → IO CInt

foreign import ccall safe "hetc_read"
  c_read ∷ CInt → Ptr Word8 → CSize → IO Int

foreign import ccall safe "hetc_close"
  c_close ∷ CInt → IO CInt

foreign import ccall safe "hetc_fd_path"
  c_fd_path ∷ CInt → Ptr Word8 → CSize → IO CInt

-- | The production adapter.
posixNative ∷ Native
posixNative =
  Native
    { nativeOpenRoot = \path →
        BSU.unsafeUseAsCString (path <> BS.singleton 0) $ \cPath →
          alloca $ \out →
            status (c_open_root cPath out) (NativeFd <$> peek out)
    , nativeOpenAt = \(NativeFd parent) (NativeName name) wantDirectory →
        BSU.unsafeUseAsCString (name <> BS.singleton 0) $ \cName →
          alloca $ \out →
            status (c_openat parent cName (if wantDirectory then 1 else 0) out) (NativeFd <$> peek out)
    , nativeFstat = \(NativeFd fd) → statResult (c_fstat fd)
    , nativeStatAt = \(NativeFd parent) (NativeName name) →
        BSU.unsafeUseAsCString (name <> BS.singleton 0) $ \cName →
          statResult (c_fstatat parent cName)
    , nativeOpenStream = \(NativeFd fd) →
        alloca $ \out →
          status (c_fdopendir fd out) (NativeStream <$> peek out)
    , nativeStreamFd = \(NativeStream stream) → NativeFd <$> c_dirfd stream
    , nativeReadStream = \(NativeStream stream) →
        allocaBytes (maxNameBytes + 1) $ \buffer →
          alloca $ \len → do
            code ← c_readdir stream buffer (fromIntegral maxNameBytes) len
            case compare code 0 of
              LT → pure (Left (negate (fromIntegral code)))
              GT → pure (Right Nothing)
              EQ → do
                size ← peek len
                Right . Just <$> BS.packCStringLen (castPtr buffer, fromIntegral size)
    , nativeCloseStream = \(NativeStream stream) → status (c_closedir stream) (pure ())
    , nativeRead = \(NativeFd fd) buffer size → do
        got ← c_read fd buffer (fromIntegral size)
        pure (if got < 0 then Left (negate got) else Right got)
    , nativeClose = \(NativeFd fd) → status (c_close fd) (pure ())
    , nativeFdPath = \(NativeFd fd) →
        allocaBytes 4096 $ \buffer → do
          code ← c_fd_path fd buffer 4096
          if code < 0
            then pure (Left (negate (fromIntegral code)))
            else Right <$> BS.packCStringLen (castPtr buffer, fromIntegral code)
    }

-- | A C call that returns 0 or a negated errno, and the value to read after 0.
status ∷ IO CInt → IO a → IO (Either Int a)
status call success = do
  code ← call
  if code == 0 then Right <$> success else pure (Left (negate (fromIntegral code)))

statResult ∷ (Ptr Word64 → IO CInt) → IO (Either Int NativeStat)
statResult call = allocaArray 5 $ \out → status (call out) (decode <$> peekArray 5 out)
  where
    decode [kind, device, inode, size, links] =
      NativeStat
        { statKind = toEnum (fromIntegral kind)
        , statIdentity = NativeIdentity device inode
        , statSize = size
        , statLinks = links
        }
    decode _ = NativeStat KindOther (NativeIdentity 0 0) 0 0
