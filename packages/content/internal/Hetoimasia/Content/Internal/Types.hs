-- | The values the content service is made of: native names, identities, limits
-- and the failures it reports.
--
-- Everything here is plain data. The names and failures have no hidden
-- constructors for clients to defend: the public "Hetoimasia.Content" module
-- exports 'NativeName' without its constructor, so a client can build a name
-- only through the checked 'nativeName', and exports the failure types closed
-- over their readers.
module Hetoimasia.Content.Internal.Types
  ( -- * Native names
    NativeName (..)
  , NameRefusal (..)
  , nativeName
  , nativeNameBytes
  , maxNameBytes
  , structuralName
  , renderName
  , renderPath
  , renderBytes

    -- * Identities and kinds
  , EntryKind (..)
  , NativeIdentity (..)
  , RootReport (..)
  , FileMetadata (..)
  , DirectoryEntry (..)

    -- * Limits
  , ContentLimits (..)
  , contentLimits
  , defaultContentLimits

    -- * Failures
  , RootAttribution (..)
  , ContentFailure (..)
  , FailureKind (..)
  , SelectionRefusal (..)
  , LimitKind (..)
  , NativeOp (..)
  , Defect (..)
  , ContentDefect (..)
  , HandleKind (..)
  , CloseFailure (..)
  , failure
  ) where

import Control.Exception (Exception (displayException))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Word (Word64, Word8)
import Numeric (showHex)

-- | One native directory-entry name: a single component, lossless bytes.
--
-- The bytes are whatever the filesystem stores, valid UTF-8 or not; nothing
-- here decodes, normalizes or case-folds them. A name is never empty, never
-- contains NUL or a separator, and is never @.@ or @..@, so handing one to a
-- directory-relative open cannot cross a component boundary. The constructor is
-- exported by this internal module only; clients build a name with
-- 'nativeName'.
newtype NativeName = NativeName ByteString
  deriving (Eq, Ord)

-- | Shows the name escaped and bounded, never decoded.
instance Show NativeName where
  showsPrec _ = showString . renderName

-- | Why a byte string is not a native name.
data NameRefusal
  = EmptyName
  | NulInName
  | SeparatorInName
  | DotName
  | DotDotName
  | NameTooLong !Int
  deriving (Eq, Show)

-- | The longest name this service accepts or enumerates. It is the capacity of
-- the buffer an enumeration copies a name into; it exceeds @NAME_MAX@ on both
-- supported platforms, so a name the filesystem can store always fits.
maxNameBytes ∷ Int
maxNameBytes = 1023

-- | The checked constructor: refuses what could bypass a component boundary.
--
-- This is the minimal native safety check. It is not the logical path grammar:
-- Unicode validity, normalization and exact-case lookup are a later layer's.
nativeName ∷ ByteString → Either NameRefusal NativeName
nativeName bytes
  | BS.null bytes = Left EmptyName
  | BS.elem 0 bytes = Left NulInName
  | BS.elem 0x2f bytes = Left SeparatorInName
  | bytes == "." = Left DotName
  | bytes == ".." = Left DotDotName
  | BS.length bytes > maxNameBytes = Left (NameTooLong (BS.length bytes))
  | otherwise = Right (NativeName bytes)

-- | The name's bytes, exactly as the filesystem holds them.
nativeNameBytes ∷ NativeName → ByteString
nativeNameBytes (NativeName bytes) = bytes

-- | @.@, the one name the service itself opens that 'nativeName' refuses: the
-- root's own directory, to give an enumeration a stream of its own.
structuralName ∷ NativeName
structuralName = NativeName "."

-- | Bytes escaped for a diagnostic: printable ASCII as is, everything else as
-- @\\xHH@, truncated at 64 bytes with an ellipsis. The value carries the full
-- bytes; only this rendering is bounded.
renderBytes ∷ ByteString → String
renderBytes = renderBytesUpTo 64

-- | 'renderBytes' keeping at most @limit@ bytes.
renderBytesUpTo ∷ Int → ByteString → String
renderBytesUpTo limit bytes = foldr (\byte rest → escape byte <> rest) tailMark (BS.unpack kept)
  where
    kept = BS.take limit bytes
    tailMark = if BS.length bytes > limit then "…" else ""
    escape ∷ Word8 → String
    escape byte
      | byte == 0x5c = "\\\\"
      | byte >= 0x20 && byte < 0x7f = [toEnum (fromIntegral byte)]
      | otherwise = "\\x" <> (if byte < 16 then "0" else "") <> showHex byte ""

renderName ∷ NativeName → String
renderName (NativeName bytes) = renderBytes bytes

-- | A name inside a path diagnostic, shortened further so a path stays small.
renderPathName ∷ NativeName → String
renderPathName (NativeName bytes) = renderBytesUpTo 32 bytes

-- | A path for a diagnostic, at most sixteen components shown.
renderPath ∷ [NativeName] → String
renderPath [] = "."
renderPath names = go (16 ∷ Int) names
  where
    go _ [] = ""
    go 0 rest = "/…(" <> show (length rest) <> " more)"
    go budget (name : rest) = "/" <> renderPathName name <> go (budget - 1) rest

-- | What a directory entry is, as the operating system reports it for the
-- entry itself, never for what a symbolic link points at.
data EntryKind
  = KindRegular
  | KindDirectory
  | KindSymlink
  | KindFifo
  | KindSocket
  | KindCharDevice
  | KindBlockDevice
  | KindOther
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The device and inode the operating system reports for an opened object.
-- Together they are native evidence for the cycle rule and for diagnostics;
-- neither is a content-version key.
data NativeIdentity = NativeIdentity
  { identityDevice ∷ !Word64
  , identityInode ∷ !Word64
  }
  deriving (Eq, Ord, Show)

-- | What the launcher reports about the selected root.
data RootReport = RootReport
  { reportSelection ∷ !ByteString
  -- ^ The launch path exactly as given, never expanded.
  , reportResolved ∷ !(Maybe ByteString)
  -- ^ The pathname the operating system reported for the directory actually
  -- opened, asked of the opened descriptor. It is a diagnostic that can be
  -- stale as soon as it is read; 'reportIdentity' is what names the object.
  , reportIdentity ∷ !NativeIdentity
  }
  deriving (Eq, Show)

-- | Metadata read from an opened file.
data FileMetadata = FileMetadata
  { metadataSize ∷ !Word64
  , metadataLinkCount ∷ !Word64
  , metadataIdentity ∷ !NativeIdentity
  }
  deriving (Eq, Show)

-- | One entry of an enumeration.
data DirectoryEntry = DirectoryEntry
  { entryName ∷ !NativeName
  , entryKind ∷ !EntryKind
  }
  deriving (Eq, Show)

-- | The bounds the caller narrows the service with.
data ContentLimits = ContentLimits
  { limitPathDepth ∷ !Int
  -- ^ The most components below the root a path, or a traversal, may have.
  , limitReadChunk ∷ !Int
  -- ^ The most bytes one read may ask for.
  }
  deriving (Eq, Show)

-- | Positive bounds only.
contentLimits ∷ Int → Int → Maybe ContentLimits
contentLimits depth chunk
  | depth > 0 && chunk > 0 = Just (ContentLimits depth chunk)
  | otherwise = Nothing

-- | Sixty-four levels and one mebibyte per read.
defaultContentLimits ∷ ContentLimits
defaultContentLimits = ContentLimits {limitPathDepth = 64, limitReadChunk = 1048576}

-- | What a failure is attributed to: the launch path, and the identity of the
-- root when it was opened far enough to have one.
data RootAttribution = RootAttribution
  { attributedSelection ∷ !ByteString
  , attributedIdentity ∷ !(Maybe NativeIdentity)
  }
  deriving (Eq, Show)

-- | An ordinary failure of a content operation: the content is not there, not
-- readable, or not of an admissible kind, or the platform cannot say. It is
-- never a cancellation, a misuse of the API, or a cleanup failure.
data ContentFailure = ContentFailure
  { failureRoot ∷ !RootAttribution
  , failurePath ∷ ![NativeName]
  -- ^ The root-relative components the failure concerns, lossless.
  , failureKind ∷ !FailureKind
  }
  deriving (Eq, Show)

instance Exception ContentFailure where
  displayException (ContentFailure attribution path kind) =
    "content root "
      <> renderBytes (attributedSelection attribution)
      <> maybe "" (\identity → " (" <> showIdentity identity <> ")") (attributedIdentity attribution)
      <> " at "
      <> renderPath path
      <> ": "
      <> describeKind kind

showIdentity ∷ NativeIdentity → String
showIdentity (NativeIdentity device inode) = "dev " <> show device <> " ino " <> show inode

describeKind ∷ FailureKind → String
describeKind = \case
  NotFound → "not found"
  Unreadable code → "unreadable (errno " <> show code <> ")"
  ForbiddenLink → "a symbolic link is not content"
  NotDirectory → "a component is not a directory"
  ForbiddenType found wanted → "a " <> show found <> " where " <> show wanted <> " is required"
  InvalidComponent refusal → "invalid native component: " <> show refusal
  InvalidSelection refusal → "invalid root selection: " <> show refusal
  MappingChanged expected found →
    "the entry changed after it was observed: expected " <> show expected <> ", found " <> maybe "nothing" show found
  Unsupported code → "unsupported by this platform or filesystem (errno " <> show code <> ")"
  DirectoryCycle chain repeats →
    "directory cycle: " <> renderPath chain <> " is directory " <> show repeats <> " of its own chain again"
  LimitExceeded limit bound → show limit <> " limit " <> show bound <> " exceeded"

-- | Why the selection was refused before anything was opened.
data SelectionRefusal
  = EmptySelection
  | NulInSelection
  | SelectionTooLong !Int
  deriving (Eq, Show)

-- | Which caller-narrowed bound was exceeded.
data LimitKind = PathDepth | ReadChunk
  deriving (Eq, Show)

-- | The native operations the adapter performs, to attribute a refusal.
data NativeOp
  = OpOpenRoot
  | OpOpenAt
  | OpFstat
  | OpStatAt
  | OpOpenStream
  | OpReadStream
  | OpRead
  | OpClose
  | OpCloseStream
  | OpFdPath
  deriving (Eq, Show)

-- | The classes of ordinary failure, for a later caller to act on.
data FailureKind
  = NotFound
  | Unreadable !Int
  -- ^ Permission, I/O or any other errno the service does not classify
  -- further.
  | ForbiddenLink
  | ForbiddenType !EntryKind !EntryKind
  -- ^ The kind found, and the kind the operation requires.
  | NotDirectory
  -- ^ A component on the way, or the selected root, is not a directory and the
  -- operating system did not say what it is.
  | InvalidComponent !NameRefusal
  | InvalidSelection !SelectionRefusal
  | MappingChanged !(Maybe EntryKind) !(Maybe EntryKind)
  -- ^ An entry observed earlier is not what it was: the kind it was observed
  -- as, and the kind found now, nothing when it is gone.
  | Unsupported !Int
  -- ^ The platform or filesystem cannot do what was asked: the errno.
  | DirectoryCycle ![NativeName] !Int
  -- ^ The chain from the root to the directory that repeats, and the depth of
  -- the ancestor it repeats (0 is the root).
  | LimitExceeded !LimitKind !Int
  deriving (Eq, Show)

-- | A misuse of the API or a defect in the native provider: not content
-- trouble, and never reported as missing content.
data Defect
  = RootNotAdmitting
  -- ^ The root's scope has ended, or is ending, and admits no new operation.
  | ReaderNotLive
  -- ^ A reader, or a reader it was derived from, was used after its scope.
  | WrongThread
  -- ^ A reader was used from a thread other than the one that was lent it.
  | BadChunkSize !Int
  | ProviderDefect !NativeOp !String
  | -- | A byte ceiling below zero was passed to a verified read.
    BadReadCeiling !Int
  | -- | An inventory was used with a root of another native identity than the
    -- one it was built for.
    InventoryRootMismatch
  | -- | Inventory limits that the root they are used with cannot honour: the
    -- kind, the inventory's value and the root's.
    InventoryLimitsExceedRoot !LimitKind !Int !Int
  | -- | The scan's own records disagree with one another: an engine defect.
    InventoryInconsistent !String
  | -- | A worker of a read pool was not started: its index. The pool's scope ends.
    ReadWorkerNotStarted !Int
  | -- | A job was submitted to a read pool with no reserved slot left for it.
    ReadSubmittedWithoutSlot
  | -- | A worker of a read pool ended while the pool was open, without having been stopped or
    -- cancelled by the scope: it ran nothing further.
    ReadWorkerEndedOpen
  | -- | A worker of a read pool was terminated by an asynchronous exception while the pool was
    -- open: the exception, rendered.
    ReadWorkerTerminated !String
  | -- | The workers of a read pool were reported to have ended otherwise than by returning after
    -- the scope closed it: failed, cancelled without the scope's cancellation, or with a
    -- retained cleanup failure. Their evidence is kept beside this.
    ReadWorkerReportedUnclean
  | -- | A read pool accepted as many jobs as its sequence numbers can order: they never wrap.
    ReadSequenceExhausted
  | -- | A read pool's slot was released while every reserved slot was held by a live job, or
    -- more slots were released than were reserved.
    ReadSlotReleasedWhileLive
  deriving (Eq, Show)

newtype ContentDefect = ContentDefect Defect
  deriving (Eq, Show)

instance Exception ContentDefect

-- | Which handle a close concerned.
data HandleKind = RootHandle | IntermediateHandle | FileHandle | DirectoryHandle
  deriving (Eq, Show)

-- | A close that reported an error. The handle is released regardless; this is
-- cleanup evidence the scope retains beside the primary failure.
data CloseFailure = CloseFailure
  { closeKind ∷ !HandleKind
  , closeErrno ∷ !Int
  , closeAttribution ∷ !RootAttribution
  , closePath ∷ ![NativeName]
  }
  deriving (Eq, Show)

instance Exception CloseFailure where
  displayException (CloseFailure handle code attribution path) =
    "closing a "
      <> show handle
      <> " handle of content root "
      <> renderBytes (attributedSelection attribution)
      <> " at "
      <> renderPath path
      <> " failed (errno "
      <> show code
      <> ")"

-- | Build a failure.
failure ∷ RootAttribution → [NativeName] → FailureKind → ContentFailure
failure = ContentFailure
