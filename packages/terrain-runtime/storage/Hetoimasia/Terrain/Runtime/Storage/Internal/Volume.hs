-- | The file's own volume: what filesystem the descriptor is on, how much space
-- is available there, and whether that filesystem is one this build qualified.
--
-- Everything here is asked of the opened descriptor (@fstat@ and @fstatfs@ on
-- it), never of a path: a path lookup can name another volume than the file
-- lives on (a bind mount, a symlink, a replaced directory), and the current
-- directory is irrelevant. The volume's identity (the device number) keys the
-- service's reservation coordination.
module Hetoimasia.Terrain.Runtime.Storage.Internal.Volume
  ( VolumeProfile (..)
  , profileOf
  , linuxFilesystemName
  , parseMountInfo
  , decodeLinuxDevice
  , qualifies
  , availableAfter
  ) where

import Control.Exception (IOException, try)
import Data.Bits (complement, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Data.Word (Word64)
import Hetoimasia.Terrain.Runtime.Storage.Internal.Native
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types

-- | What a descriptor's filesystem is, as the platform reports it.
data VolumeProfile = VolumeProfile
  { vpDevice ∷ !Word64
  -- ^ The volume's identity.
  , vpFilesystem ∷ !ByteString
  -- ^ The filesystem's name; empty when the platform could not name it.
  , vpBlockSize ∷ !Word64
  , vpTotalBytes ∷ !Word64
  , vpAvailableBytes ∷ !Word64
  -- ^ Bytes available to the unprivileged process.
  , vpTypeNumber ∷ !Word64
  , vpFileAllocatedBytes ∷ !Word64
  -- ^ What the descriptor's file occupied when it was observed: the base a reservation adds to, so what a
  -- reservation OBTAINED (overhead included) is the difference, never only what was asked.
  }
  deriving stock (Eq, Show)

-- | Observe the descriptor's volume.
profileOf ∷ Seam → Fd → IO (Either (IoOp, Errno) VolumeProfile)
profileOf seam fd = do
  st ← around seam OpStatFile NothingAcquired (nativeStat (seamNative seam) fd)
  case st of
    Left e → pure (Left (IoStat, e))
    Right s → do
      fs ← around seam OpStatFilesystem NothingAcquired (nativeStatFs (seamNative seam) fd)
      case fs of
        Left e → pure (Left (IoStatFs, e))
        Right f → do
          name ← if BC.null (nfTypeName f) then linuxFilesystemName (nsDevice s) else pure (nfTypeName f)
          -- the name is the profile's OWN copy: on Linux it is a view into the whole mount table, and a profile is
          -- retained (in the reservation an opened backing reports, in a refusal) long after that table is gone
          -- built here, completely: the profile that is returned is a value, not a thunk holding the name it was made from
          let profile = VolumeProfile (nsDevice s) (BC.copy name) (nfBlockSize f) (nfTotalBytes f) (nfAvailableBytes f) (nfTypeNumber f) (nsAllocated s)
          profile `seq` pure (Right profile)

-- | Whether the profile's filesystem is on the qualified list.
qualifies ∷ [ByteString] → VolumeProfile → Bool
qualifies listed p = not (BC.null (vpFilesystem p)) && vpFilesystem p `elem` listed

-- | The space left on the volume once a request is taken, or 'Nothing' when the
-- request is more than is available.
availableAfter ∷ VolumeProfile → Word64 → Maybe Word64
availableAfter p want
  | want > vpAvailableBytes p = Nothing
  | otherwise = Just (vpAvailableBytes p - want)

-- | The filesystem name of a Linux device from @/proc/self/mountinfo@: the
-- kernel reports only a type number for @fstatfs@, and the number of ext2, ext3
-- and ext4 is the same, so the name comes from the mount table, matched on the
-- device the file is on. A device the table does not name (a btrfs subvolume, a
-- missing @/proc@) is the empty name, which is never qualified.
linuxFilesystemName ∷ Word64 → IO ByteString
linuxFilesystemName dev = do
  table ← try (BC.readFile "/proc/self/mountinfo")
  pure $ case table of
    Left (_ ∷ IOException) → BC.empty
    Right bytes → maybe BC.empty id (lookup (decodeLinuxDevice dev) (parseMountInfo bytes))

-- | Split a Linux @dev_t@ into (major, minor) the way glibc's @major@ and
-- @minor@ do.
decodeLinuxDevice ∷ Word64 → (Word64, Word64)
decodeLinuxDevice dev = (major, minor)
  where
    major = ((dev `shiftR` 8) .&. 0xfff) .|. ((dev `shiftR` 32) .&. complement 0xfff)
    minor = (dev .&. 0xff) .|. ((dev `shiftR` 12) .&. complement 0xff)

-- | The (device, filesystem type) pairs of a mountinfo table. A line is
-- @id parent major:minor root mountpoint options [optional...] - type source
-- superoptions@; a malformed line contributes nothing.
parseMountInfo ∷ ByteString → [((Word64, Word64), ByteString)]
parseMountInfo = concatMap line . BC.lines
  where
    line l = case BC.words l of
      (_ : _ : mm : rest) →
        case (parseDev mm, drop 1 (dropWhile (/= "-") rest)) of
          (Just d, fsType : _) → [(d, fsType)]
          _ → []
      _ → []
    parseDev mm = case BC.split ':' mm of
      [a, b] → (,) <$> number a <*> number b
      _ → Nothing
    number s = case BC.readInteger s of
      Just (n, rest) | BC.null rest && n >= 0 → Just (fromInteger n)
      _ → Nothing
