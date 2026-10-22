-- | Questions about an inventory, and the verified read of an inventoried file.
--
-- == The verified read
--
-- 'readVerified' answers from the immutable inventory first and touches the
-- folder only for an inventoried regular file that fits the caller's byteCeiling.
-- It then:
--
-- 1. opens the file through its preserved native components and the root's
--    retained no-follow descriptor, with the same directory-relative opens the
--    scan used, so no pathname is ever opened and no link is followed;
-- 2. compares the length of the opened object with the inventoried one, before
--    a single byte of the result is allocated;
-- 3. reads exactly the inventoried length into one buffer the operation owns,
--    hashing each chunk as it arrives from that same buffer, never from a second
--    open, and probes one byte past the end;
-- 4. compares the SHA-256 of what it read with the inventoried digest, and only
--    then returns the buffer.
--
-- The caller therefore gets the exact bytes that were verified or nothing. The
-- buffer is allocated once, at the inventoried length, which the byteCeiling check
-- has already bounded; a file that grew is refused before anything is
-- allocated for the growth, or after at most one byte of probe. The result
-- belongs to the caller; the service keeps no cache and no copy.
module Hetoimasia.Content.Internal.Inventory.Read
  ( readVerified
  , inspectEntry
  , bytesMatch
  , listInventory
  ) where

import Control.Exception (SomeException, fromException, throwIO)
import Control.Monad (unless, when)
import qualified Crypto.Hash.SHA256 as SHA256
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Internal as BSI
import qualified Data.ByteString.Unsafe as BSU
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Word (Word8)
import Foreign.ForeignPtr (ForeignPtr, mallocForeignPtrBytes, withForeignPtr)
import Foreign.Ptr (castPtr, plusPtr)
import Hetoimasia.Content.Internal.Access (fileMetadata, readChunk, readInto, withFile)
import Hetoimasia.Content.Internal.Identity.Mapping
import Hetoimasia.Content.Internal.Identity.Types (ContentKey (..), logicalPathBytes)
import Hetoimasia.Content.Internal.Inventory.Outcome (ordinarily)
import Hetoimasia.Content.Internal.Inventory.Types
import Hetoimasia.Content.Internal.Native (Boundary (..), seamBoundary)
import Hetoimasia.Content.Internal.Root (ContentRoot (..))
import Hetoimasia.Content.Internal.Types

-- | What the inventory says is at the key.
inspectEntry ∷ Inventory → ContentKey → Presence
inspectEntry inventory key = case entryAt inventory key of
  Nothing → Absent
  Just (entry, fact)
    | mappedKind entry == ObservedDirectory → PresentDirectory
    | otherwise → maybe Absent (PresentFile . factLength) fact

-- | The mapped entry for the key and its fact, when the key names an entry of
-- this inventory's root.
entryAt ∷ Inventory → ContentKey → Maybe (MappedEntry, Maybe FileFact)
entryAt inventory key
  | keyRoot key /= invRootKey inventory = Nothing
  | otherwise = do
      entry ← lookupPath (invMapping inventory) (keyPath key)
      pure (entry, Map.lookup (logicalPathBytes (mappedPath entry)) (invFiles inventory))

-- | Whether these bytes are the inventoried file's: the same length and the
-- same SHA-256. It reads nothing and is no reason to skip a verified read.
bytesMatch ∷ Inventory → ContentKey → ByteString → Bool
bytesMatch inventory key bytes = case entryAt inventory key of
  Just (entry, Just fact)
    | mappedKind entry == ObservedFile →
        factLength fact == fromIntegral (BS.length bytes) && factDigest fact == Sha256 (SHA256.hash bytes)
  _ → False

-- | Every entry the inventory holds, directories included, depth first in the
-- byte order of their NFC names.
listInventory ∷ Inventory → [InventoryEntry]
listInventory inventory =
  [ InventoryEntry
      { entryLogicalPath = mappedPath entry
      , entryObservedKind = mappedKind entry
      , entryFact = Map.lookup (logicalPathBytes (mappedPath entry)) (invFiles inventory)
      }
  | entry ← mappingEntries (invMapping inventory)
  ]

-- | Read an inventoried regular file and return exactly the bytes whose length
-- and digest the inventory holds.
--
-- The order of decisions is fixed. A negative byteCeiling and a root of another
-- identity are misuse and throw. Then, from the inventory alone and before any
-- open: a key that is not an inventoried regular file (absent, a different
-- case, a directory, another root's) is 'NotFound', and an inventoried length
-- above the byteCeiling is 'TooLarge'. Only then is the folder touched: a missing
-- file or a path that no longer resolves to a regular file is
-- 'ContentChanged', as is any difference in length or digest, growth past the
-- byteCeiling included; an access or read error is 'IoError'.
readVerified ∷ Inventory → ContentRoot → ContentKey → Int → IO (Either ReadFailure ByteString)
readVerified inventory root key byteCeiling = do
  when (byteCeiling < 0) $ throwIO (ContentDefect (BadReadCeiling byteCeiling))
  unless (Just (reportIdentity (rootReport root)) == attributedIdentity (invAttribution inventory)) $
    throwIO (ContentDefect InventoryRootMismatch)
  case entryAt inventory key of
    Just (entry, Just fact)
      | mappedKind entry == ObservedFile →
          if factLength fact > fromIntegral byteCeiling
            then pure (Left (failed (ReadTooLarge (factLength fact) byteCeiling)))
            else verify (NonEmpty.toList (mappedNative entry)) fact
    _ → pure (Left (failed ReadNotFound))
  where
    failed = ReadFailure (invAttribution inventory) key
    seam = rootSeam root
    verify natives fact = do
      outcome ← ordinarily classify (withFile root natives (verifying natives fact))
      pure $ case outcome of
        Left ordinary → Left (failed ordinary)
        Right (Left change) → Left (failed (ReadChanged change))
        Right (Right bytes) → Right bytes
    verifying natives fact file = do
      let len = fromIntegral (factLength fact) ∷ Int
          bufferBytes = inventoryBufferBytes (invLimits inventory)
      metadata ← fileMetadata file
      if metadataSize metadata /= factLength fact
        then pure (Left (LengthChanged (factLength fact) (metadataSize metadata)))
        else do
          seamBoundary seam (ReadOpened natives)
          buffer ← mallocForeignPtrBytes len ∷ IO (ForeignPtr Word8)
          withForeignPtr buffer $ \pointer → do
            let go !context done
                  | done == len = finish context
                  | otherwise = do
                      got ← readInto file (pointer `plusPtr` done) (min bufferBytes (len - done))
                      if got == 0
                        then pure (Left (Truncated (factLength fact) (fromIntegral done)))
                        else do
                          view ← BSU.unsafePackCStringLen (castPtr (pointer `plusPtr` done), got)
                          go (SHA256.update context view) (done + got)
                finish context = do
                  extra ← readChunk file 1
                  after ← fileMetadata file
                  seamBoundary seam (ReadBeforeCompare natives)
                  pure $
                    if not (BS.null extra)
                      then Left (Grew (factLength fact))
                      else
                        if metadataSize after /= factLength fact
                          then Left (LengthChanged (factLength fact) (metadataSize after))
                          else
                            if Sha256 (SHA256.finalize context) /= factDigest fact
                              then Left DigestMismatch
                              else Right (BSI.fromForeignPtr buffer 0 len)
            go SHA256.init 0

-- | The ordinary failures a verified read of an inventoried name can meet. A
-- missing file, or a path that no longer resolves to a regular file by
-- no-follow opens, is a content change; an access or read error is an I/O
-- error. Any other kind (a bound the inventory was checked against, a name it
-- already validated) cannot arise from an inventoried path and is left to
-- propagate as the content failure it is.
classify ∷ SomeException → Maybe ReadOutcome
classify exception = do
  ContentFailure _ _ kind ← fromException exception
  case kind of
    NotFound → Just (ReadChanged Missing)
    ForbiddenLink → Just (ReadChanged (Retyped kind))
    ForbiddenType _ _ → Just (ReadChanged (Retyped kind))
    NotDirectory → Just (ReadChanged (Retyped kind))
    MappingChanged _ _ → Just (ReadChanged (Retyped kind))
    DirectoryCycle _ _ → Just (ReadChanged (Retyped kind))
    Unreadable _ → Just (ReadIoError kind)
    Unsupported _ → Just (ReadIoError kind)
    _ → Nothing
