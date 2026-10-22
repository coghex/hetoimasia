-- | Anchored, no-follow reading of one launcher-selected content folder.
--
-- 'withContentRoot' resolves a launch path once, opens the directory it names
-- and keeps that directory for the rest of the scope. Everything else is
-- relative to it: 'withFile' and 'withDirectory' open a root-relative path one
-- component at a time without following a symbolic link, check the type of each
-- object they actually opened, and lend the result to a callback as a bounded,
-- strict reader. Nothing is a pathname once the root is open, and nothing is
-- cached: when a callback returns, every descriptor it used is closed.
--
-- The package reads; it never creates, truncates, links or mounts. It hashes
-- nothing, validates no logical path and builds no inventory. Those belong to
-- the layers above it, which use 'readEntry', 'withEntryDirectory' and
-- 'withEntryFile' to walk a tree and 'readChunk' to consume exactly the bytes
-- they then verify.
--
-- See @packages/content/README.md@ for the contract in full: the native calls
-- and flags, platform limits, ownership and cleanup, and the failure
-- classification.
module Hetoimasia.Content
  ( -- * Names
    NativeName
  , nativeName
  , nativeNameBytes
  , NameRefusal (..)

    -- * Limits
  , ContentLimits
  , contentLimits
  , defaultContentLimits
  , limitPathDepth
  , limitReadChunk

    -- * The root
  , ContentRoot
  , withContentRoot
  , withContentRootBytes
  , rootReport
  , RootReport (..)
  , NativeIdentity (..)

    -- * Files
  , FileReader
  , withFile
  , readChunk
  , fileMetadata
  , filePath
  , FileMetadata (..)

    -- * Directories
  , DirectoryReader
  , withDirectory
  , readEntry
  , withEntryDirectory
  , withEntryFile
  , directoryIdentity
  , directoryPath
  , DirectoryEntry (..)
  , EntryKind (..)

    -- * Failures
  , ContentFailure (..)
  , FailureKind (..)
  , SelectionRefusal (..)
  , LimitKind (..)
  , NativeOp (..)
  , RootAttribution (..)
  , ContentDefect (..)
  , Defect (..)
  , CloseFailure (..)
  , HandleKind (..)
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import GHC.Foreign (withCStringLen)
import GHC.IO.Encoding (getFileSystemEncoding)
import Hetoimasia.Content.Internal.Access
import Hetoimasia.Content.Internal.Native (productionSeam)
import Hetoimasia.Content.Internal.Root (ContentRoot, rootReport, withContentRootWith)
import Hetoimasia.Content.Internal.Types

-- | Select, open and anchor the folder a launch path names, for the body.
--
-- The path is an ordinary 'FilePath', relative to the process working directory
-- or absolute, and may pass through symbolic links anywhere, the selected
-- folder itself included. It is encoded with the file-system encoding, which
-- round-trips arbitrary bytes. No shell syntax is expanded and the working
-- directory is not changed.
--
-- The scope's exit stops admitting operations and waits, uninterruptibly, for
-- every operation already running on this root to retire; only then is the root
-- closed. A cancellation of the exiting thread is delivered after that. An
-- operation therefore must not wait for something the exiting thread would have
-- to provide.
withContentRoot ∷ ContentLimits → FilePath → (ContentRoot → IO r) → IO r
withContentRoot limits path body = do
  encoding ← getFileSystemEncoding
  bytes ← withCStringLen encoding path BS.packCStringLen
  withContentRootBytes limits bytes body

-- | 'withContentRoot' for a launch path already held as native bytes.
withContentRootBytes ∷ ContentLimits → ByteString → (ContentRoot → IO r) → IO r
withContentRootBytes = withContentRootWith productionSeam
