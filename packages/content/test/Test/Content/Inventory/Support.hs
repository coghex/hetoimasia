-- | What every inventory examples module shares: validated limits (including
-- the M1 numbers, passed as test inputs), tree building, scanning over a seam,
-- the injected-evidence seams, and counters for what the native layer was asked
-- and what it returned.
--
-- Everything that is injected is built here and named for what it injects, so an
-- example's text says which evidence is native and which is injected: the
-- suite creates no mount, no device and no privileged setup.
module Test.Content.Inventory.Support
  ( -- * Limits
    baseSpec
  , m1Spec
  , limitsFrom
  , rootLimits
  , testKey

    -- * Trees
  , populate
  , withLayout
  , rootPath

    -- * Scanning
  , scanning
  , scanned
  , withScanned
  , keyFor
  , presenceOf
  , pathsOf
  , entryFor

    -- * Digest vectors
  , abcDigest
  , emptyDigest
  , helloWorldDigest
  , millionADigest

    -- * Injected evidence
  , overriding
  , supplyingEntries
  , denyingOpen
  , failingRead
  , shortReads
  , endingReadsAfter
  , Counter
  , newCounter
  , countReads
  , countStreamReads
  , readCount
  , bytesReturned
  , requestSizes
  , openedNames

    -- * Boundaries
  , at
  , atFile
  ) where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BC
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Hetoimasia.Content
  ( ContentLimits
  , ContentRoot
  , NativeIdentity (..)
  , NativeName
  , nativeName
  , nativeNameBytes
  )
import Hetoimasia.Content.Identity (ContentKey, RootKey, parseReference, rootKey)
import Hetoimasia.Content.Inventory
import Hetoimasia.Content.Internal.Native
import Hetoimasia.Content.Internal.Types (EntryKind (..))
import System.Directory (createDirectory, createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import Test.Content.Support

-- | A small profile whose numbers are easy to sit on both sides of: eight
-- segments, 200 path bytes, 40 per segment, 4 KiB per file, 16 KiB per root and
-- a 64-byte buffer, with 100 entries.
baseSpec ∷ InventorySpec
baseSpec =
  InventorySpec
    { specEntries = 100
    , specSegments = 8
    , specPathBytes = 200
    , specSegmentBytes = 40
    , specFileBytes = 4096
    , specRootBytes = 16384
    , specBufferBytes = 64
    }

-- | The approved M1 numbers, as an input to the same check any profile passes.
-- The package holds no such default: the assembly supplies them.
m1Spec ∷ InventorySpec
m1Spec =
  InventorySpec
    { specEntries = 10000
    , specSegments = 32
    , specPathBytes = 1024
    , specSegmentBytes = 255
    , specFileBytes = 64 * 1024 * 1024
    , specRootBytes = 1024 * 1024 * 1024
    , specBufferBytes = 64 * 1024
    }

-- | Validated limits from a specification.
limitsFrom ∷ InventorySpec → InventoryLimits
limitsFrom spec = either (\refusal → error ("invalid fixture limits " <> show spec <> ": " <> show refusal)) id (inventoryLimits spec)

-- | The root's own bounds: deeper and with a larger chunk than any profile here.
rootLimits ∷ ContentLimits
rootLimits = limitsOf 64 (1024 * 1024)

testKey ∷ RootKey
testKey = either (\refusal → error ("invalid fixture root key: " <> show refusal)) id (rootKey "test-root")

-- | Create files (and the directories above them) under a directory. A path
-- ending in @/@ is a directory.
populate ∷ FilePath → [(FilePath, ByteString)] → IO ()
populate root entries =
  forM_ entries $ \(path, bytes) →
    if last path == '/'
      then createDirectoryIfMissing True (root </> init path)
      else do
        createDirectoryIfMissing True (takeDirectory (root </> path))
        writeBytes (root </> path) bytes

-- | A fresh temporary directory holding an empty @root@ folder, with the
-- directory above it for outside files.
withLayout ∷ (FilePath → IO a) → IO a
withLayout use = withTree $ \tree → do
  createDirectory (tree </> "root")
  use tree

rootPath ∷ FilePath → FilePath
rootPath tree = tree </> "root"

-- | Scan the folder over the seam.
scanning ∷ Seam → InventoryLimits → FilePath → IO (Either InventoryFailure Inventory)
scanning seam limits path = withRootVia seam rootLimits path (scanInventory limits testKey)

-- | Scan and require success.
scanned ∷ Seam → InventoryLimits → FilePath → IO Inventory
scanned seam limits path =
  scanning seam limits path >>= \case
    Right inventory → pure inventory
    Left refusal → fail ("the scan was refused: " <> show refusal)

-- | Open the root, scan it, and run the body with both.
withScanned ∷ Seam → InventoryLimits → FilePath → (ContentRoot → Inventory → IO a) → IO a
withScanned seam limits path use =
  withRootVia seam rootLimits path $ \root →
    scanInventory limits testKey root >>= \case
      Right inventory → use root inventory
      Left refusal → fail ("the scan was refused: " <> show refusal)

-- | The key a reference names in the inventory's root, parsed with the
-- inventory's own limits.
keyFor ∷ Inventory → ByteString → ContentKey
keyFor inventory reference =
  either
    (\refusal → error ("invalid fixture reference " <> show reference <> ": " <> show refusal))
    id
    (parseReference (inventoryIdentityLimits (inventoryLimitsOf inventory)) (inventoryRootKey inventory) reference)

presenceOf ∷ Inventory → ByteString → Presence
presenceOf inventory = inspectEntry inventory . keyFor inventory

-- | Every logical path the inventory holds, as text, in its listing order.
pathsOf ∷ Inventory → [String]
pathsOf = map (show . entryLogicalPath) . listInventory

-- | The listing entry at a logical path.
entryFor ∷ Inventory → ByteString → IO InventoryEntry
entryFor inventory reference =
  case [e | e ← listInventory inventory, show (entryLogicalPath e) == BC.unpack reference] of
    e : _ → pure e
    [] → fail ("no inventory entry " <> show reference <> " among " <> show (pathsOf inventory))

-- | Known SHA-256 values: FIPS 180-2 examples and the standard
-- one-million-@a@ vector, with the empty string and a common phrase.
abcDigest, emptyDigest, helloWorldDigest, millionADigest ∷ String
abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
emptyDigest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
helloWorldDigest = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
millionADigest = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"

-- | A seam that reports chosen native identities for directories by the name
-- they were opened under; every other answer is the real one. Injected: no
-- mount or second device is created.
overriding ∷ [(ByteString, NativeIdentity)] → IO Seam
overriding table = do
  opened ← newIORef Map.empty
  let wanted = Map.fromList [(componentOf n, identity) | (n, identity) ← table]
      native = seamNative productionSeam
  pure
    productionSeam
      { seamNative =
          native
            { nativeOpenAt = \parent component directory → do
                result ← nativeOpenAt native parent component directory
                case result of
                  Right (NativeFd fd) → atomicModifyIORef' opened (\m → (Map.insert (fromIntegral fd ∷ Int) component m, ()))
                  Left _ → pure ()
                pure result
            , nativeFstat = \(NativeFd fd) → do
                result ← nativeFstat native (NativeFd fd)
                known ← readIORef opened
                pure $ case (result, Map.lookup (fromIntegral fd) known >>= (`Map.lookup` wanted)) of
                  (Right stat, Just identity) | statKind stat == KindDirectory → Right stat {statIdentity = identity}
                  _ → result
            }
      }

componentOf ∷ ByteString → NativeName
componentOf bytes = either (\refusal → error ("invalid fixture name " <> show bytes <> ": " <> show refusal)) id (nativeName bytes)

-- | A seam whose first enumeration yields these raw names after the real ones,
-- answering the kind query for them as the given kind. Injected: the names need
-- not exist, so a name the filesystem cannot hold (or ten thousand of them) can
-- be listed. Opening one fails as the real filesystem would for a missing
-- entry.
supplyingEntries ∷ [(ByteString, EntryKind)] → IO Seam
supplyingEntries extra = do
  remaining ← newIORef extra
  let native = seamNative productionSeam
      table = Map.fromList extra
  pure
    productionSeam
      { seamNative =
          native
            { nativeReadStream = \stream →
                nativeReadStream native stream >>= \case
                  Right Nothing →
                    atomicModifyIORef' remaining $ \left' → case left' of
                      [] → ([], Right Nothing)
                      (next, _) : rest → (rest, Right (Just next))
                  other → pure other
            , nativeStatAt = \parent component →
                case Map.lookup (nativeNameBytes component) table of
                  Just kind → pure (Right (NativeStat kind (NativeIdentity 1 1) 0 1))
                  Nothing → nativeStatAt native parent component
            }
      }

-- | A seam that makes opening the named component fail with an errno.
denyingOpen ∷ ByteString → Int → Seam → Seam
denyingOpen component code = mapNative $ \native →
  native
    { nativeOpenAt = \parent candidate directory →
        if candidate == componentOf component
          then pure (Left code)
          else nativeOpenAt native parent candidate directory
    }

-- | A seam whose every read fails with an errno.
failingRead ∷ Int → Seam → Seam
failingRead code = mapNative (\native → native {nativeRead = \_ _ _ → pure (Left code)})

-- | A seam that returns at most @n@ bytes per read.
shortReads ∷ Int → Seam → Seam
shortReads n = mapNative (\native → native {nativeRead = \fd buffer size → nativeRead native fd buffer (min n size)})

-- | A seam whose reads report the end of the file once @n@ reads have been
-- served, whatever the file still holds. Injected: a read that stops early.
endingReadsAfter ∷ IORef Int → Int → Seam → Seam
endingReadsAfter served n = mapNative $ \native →
  native
    { nativeRead = \fd buffer size → do
        count ← atomicModifyIORef' served (\c → (c + 1, c))
        if count >= n then pure (Right 0) else nativeRead native fd buffer size
    }

-- | A counter shared by a seam and its example.
type Counter = IORef Int

newCounter ∷ IO Counter
newCounter = newIORef 0

readCount ∷ Counter → IO Int
readCount = readIORef

-- | Count the reads the seam serves.
countReads ∷ Counter → Seam → Seam
countReads counter = mapNative $ \native →
  native
    { nativeRead = \fd buffer size → do
        atomicModifyIORef' counter (\c → (c + 1, ()))
        nativeRead native fd buffer size
    }

-- | Count the names an enumeration reads from its streams.
countStreamReads ∷ Counter → Seam → Seam
countStreamReads counter = mapNative $ \native →
  native
    { nativeReadStream = \stream → do
        atomicModifyIORef' counter (\c → (c + 1, ()))
        nativeReadStream native stream
    }

-- | Sum the bytes the seam's reads return.
bytesReturned ∷ Counter → Seam → Seam
bytesReturned counter = mapNative $ \native →
  native
    { nativeRead = \fd buffer size →
        nativeRead native fd buffer size >>= \result → do
          case result of
            Right got → atomicModifyIORef' counter (\c → (c + got, ()))
            Left _ → pure ()
          pure result
    }

-- | The sizes every read was asked for, in order, from a recording seam's log.
requestSizes ∷ [Event] → [Int]
requestSizes log' = [size | Read _ size ← log']

-- | The names every descriptor was opened under, root excluded.
openedNames ∷ [Event] → [String]
openedNames log' = [label | Opened _ label ← log', label /= "<root>"]

-- | Run an action when the named component is about to be opened.
at ∷ ByteString → IO () → Boundary → IO ()
at component action = \case
  BeforeOpen _ candidate | candidate == componentOf component → action
  _ → pure ()

-- | Run an action at a scan's named file boundary.
atFile ∷ (Boundary → Maybe [NativeName]) → [ByteString] → IO () → Boundary → IO ()
atFile select path action boundary =
  case select boundary of
    Just opened | opened == map componentOf path → action
    _ → pure ()
