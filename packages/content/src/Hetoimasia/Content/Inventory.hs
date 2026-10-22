-- | The bounded whole-folder inventory and the verified read.
--
-- 'scanInventory' walks the entire folder beneath an open content root once,
-- through the anchored no-follow operations of "Hetoimasia.Content", hashes
-- every regular file with a streaming SHA-256 and returns one immutable
-- 'Inventory': the checked logical identities of "Hetoimasia.Content.Identity",
-- the exact native components that open them, each file's byte length and its
-- digest. Nothing is decoded, parsed or evaluated, no file is skipped, and no
-- file's bytes are retained.
--
-- 'readVerified' is the only way bytes leave an inventoried file: it reopens the
-- file through the preserved native components and the root's retained
-- descriptor, reads the inventoried length within the caller's ceiling, checks
-- length and SHA-256 against the inventory, and returns exactly the bytes it
-- verified, or a structured refusal and no bytes at all.
--
-- The inventory is the content version of one session. It is not an atomic
-- snapshot of the filesystem and not containment of a hostile one: authors keep
-- the folder stable while it boots, and a later edit is detected when the
-- affected file is next read, never by this value. The package knows no manifest
-- schema, role or special file name.
--
-- See @packages/content/README.md@ for the contract in full: limits and
-- accounting, ownership and cleanup, what a scan detects and what it cannot,
-- and the classification of outcomes.
module Hetoimasia.Content.Inventory
  ( -- * Limits
    InventorySpec (..)
  , InventoryLimits
  , inventoryLimits
  , InventoryLimitName (..)
  , InventoryLimitsRefusal (..)
  , inventoryEntries
  , inventorySegments
  , inventoryPathBytes
  , inventorySegmentBytes
  , inventoryFileBytes
  , inventoryRootBytes
  , inventoryBufferBytes
  , inventoryIdentityLimits

    -- * Scanning
  , scanInventory
  , InventoryFailure (..)
  , InventoryFailureReason (..)
  , InventoryBound (..)
  , Change (..)

    -- * The inventory
  , Inventory
  , inventoryLimitsOf
  , inventoryRootKey
  , inventoryRoot
  , inventoryEntryCount
  , inventoryByteTotal
  , inspectEntry
  , Presence (..)
  , bytesMatch
  , listInventory
  , InventoryEntry (..)
  , FileFact (..)
  , Sha256
  , sha256Bytes
  , sha256Hex

    -- * Verified reads
  , readVerified
  , ReadFailure (..)
  , ReadOutcome (..)
  ) where

import Data.Word (Word64)
import Hetoimasia.Content.Internal.Identity.Types (RootKey)
import Hetoimasia.Content.Internal.Inventory.Read
import Hetoimasia.Content.Internal.Inventory.Scan
import Hetoimasia.Content.Internal.Inventory.Types hiding (invLimits)
import qualified Hetoimasia.Content.Internal.Inventory.Types as Types
import Hetoimasia.Content.Internal.Types (RootAttribution)

-- | The limits the inventory was scanned under.
inventoryLimitsOf ∷ Inventory → InventoryLimits
inventoryLimitsOf = Types.invLimits

-- | The root value its keys carry: parse references against it.
inventoryRootKey ∷ Inventory → RootKey
inventoryRootKey = Types.invRootKey

-- | The launch path and native identity of the root it was built for.
inventoryRoot ∷ Inventory → RootAttribution
inventoryRoot = Types.invAttribution

-- | Entries counted, the root included.
inventoryEntryCount ∷ Inventory → Int
inventoryEntryCount = Types.invEntryCount

-- | Regular-file bytes summed over every path, a hard-link alias charged once
-- for each of its names.
inventoryByteTotal ∷ Inventory → Word64
inventoryByteTotal = Types.invByteTotal
