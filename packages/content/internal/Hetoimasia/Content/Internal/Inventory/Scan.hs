-- | The bounded whole-folder scan.
--
-- 'scanInventory' walks the entire tree beneath an open content root, once,
-- through the anchored no-follow operations of "Hetoimasia.Content.Internal.Access",
-- streams every regular file through SHA-256 and returns one immutable
-- 'Inventory'. Nothing is decoded, parsed or evaluated, nothing is filtered or
-- ignored, and no file's bytes are retained.
--
-- == State, ownership and lifetime
--
-- * The root and every descriptor the walk opens belong to the content layer's
--   scopes. The walk holds the root through one 'withDirectory' for its whole
--   duration, so the root cannot close under it, and holds exactly one
--   directory stream per active level plus one file at a time.
-- * The scan's own state is one 'IORef' created by the call and dropped with
--   it: the entry and byte counters, the entries observed so far (at most the
--   entry allowance), and the length and digest of each file hashed so far. It
--   has one writer, the calling thread, and is never published.
-- * An 'Inventory' is assembled from that state only after every handle is
--   closed and every check has passed. A refusal, an exception or a
--   cancellation at any earlier point leaves nothing: the state is dropped and
--   no value is returned.
--
-- == Order of work in a directory
--
-- A directory is listed completely before anything in it is opened, each entry
-- charged against the entry allowance as it is read, so an enormous directory
-- is refused at the entry that crosses the allowance and never materialized.
-- The listing is then checked as a whole (every kind is a regular file or a
-- directory, every name and path is valid under the identity policy, no two
-- siblings collide), and only then are its entries opened, in the byte order of
-- their native names. A refusal therefore precedes any hashing in that
-- directory.
--
-- == What can change under a scan, and what is detected
--
-- Detected: an entry that is no longer the kind it was listed as (the content
-- layer's changed mapping), a file whose size at open differs from the bytes
-- read, a read that ends early, a byte after the expected length, a size that
-- differs after the read, an unreadable file or directory, and an unsupported
-- native operation. Not detected: an entry added to or removed from a directory
-- after it was listed, a file edited behind the hash after it was read, and an
-- edit that keeps the length across a read the scan did not repeat. A scan is
-- the bytes observed for each file, not an atomic snapshot of the tree.
module Hetoimasia.Content.Internal.Inventory.Scan
  ( scanInventory
  ) where

import Control.Exception (SomeException, fromException, throwIO)
import Control.Monad (forM_, unless, when)
import qualified Crypto.Hash.SHA256 as SHA256
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (sortOn)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import Hetoimasia.Content.Internal.Access
import Hetoimasia.Content.Internal.Identity.Mapping
import Hetoimasia.Content.Internal.Identity.Types (RootKey, logicalPathBytes)
import Hetoimasia.Content.Internal.Inventory.Outcome (ordinarily)
import Hetoimasia.Content.Internal.Inventory.Types
import Hetoimasia.Content.Internal.Native (Boundary (..), seamBoundary)
import Hetoimasia.Content.Internal.Root (ContentRoot (..), rootAttributionOf)
import Hetoimasia.Content.Internal.Types

-- | What one scan is running with.
data Scan = Scan
  { scanLimits ∷ !InventoryLimits
  , scanKey ∷ !RootKey
  , scanRoot ∷ !ContentRoot
  , scanState ∷ !(IORef State)
  }

-- | The scan's mutable record. Local to one call, written by its thread only.
data State = State
  { stEntries ∷ !Int
  -- ^ Entries charged, the root included.
  , stBytes ∷ !Word64
  -- ^ Bytes charged to files opened so far, aliases counted per path.
  , stObserved ∷ ![ObservedEntry]
  -- ^ Entries observed, newest first.
  , stFacts ∷ !(Map [ByteString] FileFact)
  -- ^ Length and digest of each file hashed, by its exact native components.
  }

hook ∷ Scan → Boundary → IO ()
hook scan = seamBoundary (rootSeam (scanRoot scan))

refuse ∷ Scan → [NativeName] → InventoryFailureReason → IO a
refuse scan path reason = throwIO (InventoryFailure (rootAttributionOf (scanRoot scan)) path reason)

-- | Scan the whole folder beneath the root.
--
-- An ordinary refusal (see 'InventoryFailureReason') is returned as a value.
-- A cancellation, a misuse of the API, a defect of the provider and any
-- ordinary refusal that has retained cleanup evidence propagate as exceptions;
-- in no case is a partial inventory returned.
scanInventory ∷ InventoryLimits → RootKey → ContentRoot → IO (Either InventoryFailure Inventory)
scanInventory limits key root = do
  checkAgainstRoot limits root
  ordinarily classify $ do
    -- The root is the first entry.
    state ← newIORef State {stEntries = 1, stBytes = 0, stObserved = [], stFacts = Map.empty}
    let scan = Scan {scanLimits = limits, scanKey = key, scanRoot = root, scanState = state}
    -- The root is charged against an allowance of at least one by construction.
    withDirectory root [] (walk scan)
    hook scan ScanBeforePublish
    publish scan

classify ∷ SomeException → Maybe InventoryFailure
classify exception = case fromException exception of
  Just failure' → Just failure'
  Nothing → case fromException exception of
    Just (ContentFailure attribution path kind) → Just (InventoryFailure attribution path (Content kind))
    Nothing → Nothing

-- | The root's own bounds must honour the inventory's: its read chunk holds the
-- streaming buffer, and its path depth holds the deepest path.
checkAgainstRoot ∷ InventoryLimits → ContentRoot → IO ()
checkAgainstRoot limits root = do
  let rootLimits' = rootLimits root
  when (inventoryBufferBytes limits > limitReadChunk rootLimits') $
    throwIO (ContentDefect (InventoryLimitsExceedRoot ReadChunk (inventoryBufferBytes limits) (limitReadChunk rootLimits')))
  when (inventorySegments limits > limitPathDepth rootLimits') $
    throwIO (ContentDefect (InventoryLimitsExceedRoot PathDepth (inventorySegments limits) (limitPathDepth rootLimits')))

-- | Charge one entry the enumeration just read against the allowance.
chargeEntry ∷ Scan → [NativeName] → IO ()
chargeEntry scan path = do
  state ← readIORef (scanState scan)
  let count = stEntries state + 1
      allowance = inventoryEntries (scanLimits scan)
  when (count > allowance) $
    refuse scan path (Exceeded BoundEntries (fromIntegral count) (fromIntegral allowance))
  writeIORef (scanState scan) state {stEntries = count}
  hook scan (ScanEntryCharged count)

-- | List, check and then open the entries of one directory.
walk ∷ Scan → DirectoryReader → IO ()
walk scan reader = do
  entries ← sortOn (nativeNameBytes . entryName) <$> listing scan reader
  checkKinds scan reader entries
  checkNames scan reader entries
  forM_ entries $ \entry → do
    let path = directoryPath reader <> [entryName entry]
    modifyIORef' (scanState scan) $ \state →
      state {stObserved = ObservedEntry (map nativeNameBytes path) (observed (entryKind entry)) : stObserved state}
    case entryKind entry of
      KindDirectory → withEntryDirectory reader entry (walk scan)
      _ → fingerprint scan reader entry path

observed ∷ EntryKind → ObservedKind
observed = \case
  KindDirectory → ObservedDirectory
  _ → ObservedFile

-- | Read the directory to its end, charging each entry as it is read. At most
-- the remaining allowance is ever held.
listing ∷ Scan → DirectoryReader → IO [DirectoryEntry]
listing scan reader = go []
  where
    go acc =
      readEntry reader >>= \case
        Nothing → pure acc
        Just entry → do
          chargeEntry scan (directoryPath reader <> [entryName entry])
          go (entry : acc)

-- | Only ordinary files and directories are content.
checkKinds ∷ Scan → DirectoryReader → [DirectoryEntry] → IO ()
checkKinds scan reader entries =
  forM_ entries $ \entry →
    unless (entryKind entry `elem` [KindRegular, KindDirectory]) $
      refuse scan (directoryPath reader <> [entryName entry]) . Content $
        if entryKind entry == KindSymlink then ForbiddenLink else ForbiddenType (entryKind entry) KindRegular

-- | Every name and path the directory lists must be valid under the identity
-- policy and its siblings must not collide, which is decided for the whole
-- listing before any entry of it is opened.
checkNames ∷ Scan → DirectoryReader → [DirectoryEntry] → IO ()
checkNames scan reader entries =
  case buildMapping (inventoryIdentityLimits (scanLimits scan)) (scanKey scan) listed of
    Left refusal → refuse scan (directoryPath reader) (Identity (inventoryReason refusal))
    Right _ → pure ()
  where
    listed = [ObservedEntry (map nativeNameBytes (directoryPath reader <> [entryName entry])) (observed (entryKind entry)) | entry ← entries]

-- | Open a regular file beneath the directory that listed it, check its size
-- against the bounds before reading anything, stream it through SHA-256 and
-- record its length and digest.
fingerprint ∷ Scan → DirectoryReader → DirectoryEntry → [NativeName] → IO ()
fingerprint scan reader entry path =
  withEntryFile reader entry $ \file → do
    metadata ← fileMetadata file
    hook scan (ScanFileOpened path)
    let size = metadataSize metadata
        limits = scanLimits scan
        fileBound = fromIntegral (inventoryFileBytes limits) ∷ Word64
        rootBound = fromIntegral (inventoryRootBytes limits) ∷ Word64
    when (size > fileBound) $
      refuse scan path (Exceeded BoundFileBytes size fileBound)
    state ← readIORef (scanState scan)
    -- The total never exceeds the bound, so the subtraction cannot wrap.
    when (size > rootBound - stBytes state) $
      refuse scan path (Exceeded BoundRootBytes (saturatingAdd (stBytes state) size) rootBound)
    writeIORef (scanState scan) state {stBytes = stBytes state + size}
    digest ← stream scan file path size
    after ← fileMetadata file
    when (metadataSize after /= size) $
      refuse scan path (Changed (LengthChanged size (metadataSize after)))
    hook scan (ScanFileHashed path)
    modifyIORef' (scanState scan) $ \current →
      current {stFacts = Map.insert (map nativeNameBytes path) (FileFact size digest) (stFacts current)}

saturatingAdd ∷ Word64 → Word64 → Word64
saturatingAdd a b = if b > maxBound - a then maxBound else a + b

-- | Read exactly @size@ bytes in chunks of at most the buffer, hashing each as
-- it arrives, then probe one byte past the end. The workspace is one chunk of
-- the buffer's size, the probe's single byte and the digest state; a file that
-- grew is refused after reading no more than one byte beyond what it was
-- charged for.
stream ∷ Scan → FileReader → [NativeName] → Word64 → IO Sha256
stream scan file path size = go SHA256.init 0
  where
    buffer = fromIntegral (inventoryBufferBytes (scanLimits scan)) ∷ Word64
    go !context done
      | done == size = do
          extra ← readChunk file 1
          unless (BS.null extra) $
            refuse scan path (Changed (Grew size))
          pure (Sha256 (SHA256.finalize context))
      | otherwise = do
          chunk ← readChunk file (fromIntegral (min buffer (size - done)))
          when (BS.null chunk) $
            refuse scan path (Changed (Truncated size done))
          go (SHA256.update context chunk) (done + fromIntegral (BS.length chunk))

-- | Assemble the immutable inventory from the state, once every handle is
-- closed and every check has passed.
publish ∷ Scan → IO Inventory
publish scan = do
  state ← readIORef (scanState scan)
  mapping ← case buildMapping (inventoryIdentityLimits (scanLimits scan)) (scanKey scan) (reverse (stObserved state)) of
    Left refusal → refuse scan [] (Identity (inventoryReason refusal))
    Right built → pure built
  files ← fmap Map.fromList . sequence $
    [ case Map.lookup (map nativeNameBytes (NonEmpty.toList (mappedNative entry))) (stFacts state) of
        Just fact → pure (logicalPathBytes (mappedPath entry), fact)
        Nothing → throwIO (ContentDefect (InventoryInconsistent "a file in the mapping has no recorded digest"))
    | entry ← mappingEntries mapping
    , mappedKind entry == ObservedFile
    ]
  when (Map.size files /= Map.size (stFacts state)) $
    throwIO (ContentDefect (InventoryInconsistent "a recorded digest has no file in the mapping"))
  pure
    Inventory
      { invLimits = scanLimits scan
      , invRootKey = scanKey scan
      , invAttribution = rootAttributionOf (scanRoot scan)
      , invMapping = mapping
      , invFiles = files
      , invEntryCount = stEntries state
      , invByteTotal = stBytes state
      }
