-- | Directory-relative, no-follow reading beneath a content root.
--
-- Every component below the root, the final file included, is opened with
-- @openat@ relative to a descriptor this operation holds, with @O_NOFOLLOW@, and
-- the type of the object that was actually opened is read back with @fstat@ on
-- the descriptor. There is no exists, canonicalize or link check followed by a
-- pathname open anywhere in this module, and no string-prefix test: a swap of a
-- component for a link between two steps meets the no-follow open and is
-- refused, and a swap of a directory for another one after it was opened changes
-- nothing, because the held descriptor names the object that was opened.
--
-- A no-follow @fstatat@ appears in two places and authorizes nothing. After an
-- open fails it classifies the entry that defeated it (a socket answers @ENXIO@
-- or @EOPNOTSUPP@, a link met with @O_DIRECTORY@ answers @ENOTDIR@), and during
-- an enumeration it reports each entry's own kind. The kind of an opened object
-- is always the one read from its descriptor.
--
-- == Handles and scopes
--
-- Each descriptor an operation opens is owned by a foundation resource scope
-- whose release is the close, opened in the same masked step as the acquisition.
-- A file operation holds its intermediate directory descriptors and the file
-- descriptor until its callback returns; an enumeration holds one stream per
-- level of the traversal. The reader a callback receives is valid for that
-- callback on the thread that was lent it, and is marked dead before its
-- descriptor is closed, so a retained copy fails with a 'ContentDefect' instead
-- of reaching a descriptor number the process has since reused.
--
-- Peak descriptors per operation: path depth @d@ intermediate directories plus
-- one file or stream, at most 'limitPathDepth' plus one; per traversal, one
-- stream per active level of the same bound. None are cached or retained.
module Hetoimasia.Content.Internal.Access
  ( FileReader
  , DirectoryReader
  , withFile
  , withDirectory
  , withEntryFile
  , withEntryDirectory
  , readChunk
  , fileMetadata
  , readEntry
  , directoryIdentity
  , directoryPath
  , filePath
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Exception (finally, throwIO)
import Control.Monad (unless, when)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Internal as BSI
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (elemIndex)
import Data.Word (Word8)
import Foreign.Ptr (Ptr)
import Hetoimasia.Content.Internal.Errno
import Hetoimasia.Content.Internal.Native
import Hetoimasia.Content.Internal.Root
import Hetoimasia.Content.Internal.Types
import Hetoimasia.Foundation.Resource (withResourceLabelled)

-- | Whether a reader may still be used, and by whom.
data Liveness = Liveness !(IORef Bool) !ThreadId

newLiveness ∷ IO Liveness
newLiveness = Liveness <$> newIORef True <*> myThreadId

retireLiveness ∷ Liveness → IO ()
retireLiveness (Liveness flag _) = writeIORef flag False

assertLive ∷ Liveness → IO ()
assertLive (Liveness flag owner) = do
  here ← myThreadId
  when (here /= owner) (throwIO (ContentDefect WrongThread))
  alive ← readIORef flag
  unless alive (throwIO (ContentDefect ReaderNotLive))

-- | An opened regular file, lent to one callback on one thread.
--
-- Owner: the 'withFile' or 'withEntryFile' scope. Reader and only user: the
-- callback's thread. Dead when the callback returns or throws, before the
-- descriptor is closed.
data FileReader = FileReader
  { fileRoot ∷ !ContentRoot
  , fileFd ∷ !NativeFd
  , fileTrail ∷ ![NativeName]
  , fileLive ∷ !Liveness
  }

-- | An opened directory enumeration, lent to one callback on one thread.
--
-- It owns a directory stream, and with it the descriptor the stream was made
-- from. Its ancestors are the native identities of the directories above it,
-- root first, which is what the cycle rule compares against.
data DirectoryReader = DirectoryReader
  { dirRoot ∷ !ContentRoot
  , dirStream ∷ !NativeStream
  , dirFd ∷ !NativeFd
  , dirTrail ∷ ![NativeName]
  , dirIdentity ∷ !NativeIdentity
  , dirAncestors ∷ ![NativeIdentity]
  , dirLive ∷ !Liveness
  }

filePath ∷ FileReader → [NativeName]
filePath = fileTrail

directoryPath ∷ DirectoryReader → [NativeName]
directoryPath = dirTrail

directoryIdentity ∷ DirectoryReader → NativeIdentity
directoryIdentity = dirIdentity

-- | What an operation expects of an entry: nothing beyond its kind, or the kind
-- an enumeration observed, so a change since then is a changed mapping and not
-- a fresh kind of failure.
data Expect = Plain | Observed !EntryKind

native ∷ ContentRoot → Native
native = seamNative . rootSeam

hook ∷ ContentRoot → Boundary → IO ()
hook root = seamBoundary (rootSeam root)

refuse ∷ ContentRoot → [NativeName] → FailureKind → IO a
refuse root trail kind = throwIO (ContentFailure (rootAttributionOf root) trail kind)

-- | The failure for an entry of kind @found@ (nothing when it is absent) where
-- @wanted@ is required.
mismatch ∷ Expect → EntryKind → Maybe EntryKind → FailureKind
mismatch Plain _ Nothing = NotFound
mismatch Plain _ (Just KindSymlink) = ForbiddenLink
mismatch Plain wanted (Just found) = ForbiddenType found wanted
mismatch (Observed expected) _ found = MappingChanged (Just expected) found

-- | Turn a failed open into the failure that explains it. A no-follow type
-- query beside the held parent says what the entry is; the open's errno decides
-- only when the entry is of the required kind and the open failed for another
-- reason.
openFailure ∷ ContentRoot → NativeFd → NativeName → EntryKind → Expect → [NativeName] → Int → IO a
openFailure root parent name wanted expect trail code =
  nativeStatAt (native root) parent name >>= \case
    Right stat
      | statKind stat /= wanted → refuse root trail (mismatch expect wanted (Just (statKind stat)))
      | otherwise → refuse root trail (classifyErrno code)
    Left probe
      | isMissing probe → refuse root trail (mismatch expect wanted Nothing)
      | otherwise → refuse root trail (classifyErrno code)

-- | The type check on the object actually opened.
requireKind ∷ ContentRoot → [NativeName] → Expect → EntryKind → NativeStat → IO ()
requireKind root trail expect wanted stat =
  unless (statKind stat == wanted) $
    refuse root trail (mismatch expect wanted (Just (statKind stat)))

fstatOf ∷ ContentRoot → [NativeName] → NativeFd → IO NativeStat
fstatOf root trail fd =
  nativeFstat (native root) fd >>= either (refuse root trail . classifyErrno) pure

checkDepth ∷ ContentRoot → [NativeName] → IO ()
checkDepth root trail =
  when (length trail > limitPathDepth (rootLimits root)) $
    refuse root (take (limitPathDepth (rootLimits root) + 1) trail) (LimitExceeded PathDepth (limitPathDepth (rootLimits root)))

-- | Refuse a directory whose identity is already on the active ancestor chain.
checkCycle ∷ ContentRoot → [NativeName] → [NativeIdentity] → NativeIdentity → IO ()
checkCycle root trail ancestors identity =
  case elemIndex identity ancestors of
    Just depth → refuse root trail (DirectoryCycle trail depth)
    Nothing → pure ()

-- | Open one component beneath a held parent and hold it for the body.
--
-- The acquisition is the native open alone, so the resource scope's release is
-- registered in the same masked step that obtains the descriptor. Everything
-- else, including the type check, runs in the body, where a failure unwinds the
-- scope and closes the descriptor.
withOpened
  ∷ ContentRoot
  → NativeFd
  → Int
  → NativeName
  → EntryKind
  → Expect
  → [NativeName]
  → HandleKind
  → (NativeFd → NativeStat → IO r)
  → IO r
withOpened root parent index name wanted expect trail handleKind body = do
  hook root (BeforeOpen index name)
  withResourceLabelled
    "content descriptor close"
    ( nativeOpenAt (native root) parent name (wanted == KindDirectory)
        >>= either (openFailure root parent name wanted expect trail) pure
    )
    (closeHandle (rootSeam root) (rootAttributionOf root) handleKind trail)
    $ \fd → do
      hook root (AfterOpen index name)
      stat ← fstatOf root trail fd
      requireKind root trail expect wanted stat
      body fd stat

-- | Open a directory beneath a held parent as an enumeration stream.
--
-- The acquisition opens the descriptor and hands it to @fdopendir@, which on
-- success owns it; the scope's release is the stream's close, which closes the
-- descriptor, so there is exactly one close however the stream ends. If the
-- handover fails the descriptor is still ours and is closed here, with a failed
-- close kept as evidence beside the primary failure.
withStream
  ∷ ContentRoot
  → NativeFd
  → Int
  → NativeName
  → Expect
  → [NativeName]
  → [NativeIdentity]
  → (DirectoryReader → IO r)
  → IO r
withStream root parent index name expect trail ancestors body = do
  hook root (BeforeOpen index name)
  withResourceLabelled
    "content directory stream close"
    acquire
    release
    $ \stream → do
      hook root (AfterStream index name)
      fd ← nativeStreamFd (native root) stream
      stat ← fstatOf root trail fd
      requireKind root trail expect KindDirectory stat
      checkCycle root trail ancestors (statIdentity stat)
      liveness ← newLiveness
      let reader =
            DirectoryReader
              { dirRoot = root
              , dirStream = stream
              , dirFd = fd
              , dirTrail = trail
              , dirIdentity = statIdentity stat
              , dirAncestors = ancestors
              , dirLive = liveness
              }
      body reader `finally` retireLiveness liveness
  where
    acquire =
      nativeOpenAt (native root) parent name True >>= \case
        Left code → openFailure root parent name KindDirectory expect trail code
        Right fd →
          nativeOpenStream (native root) fd >>= \case
            Right stream → pure stream
            Left code →
              failWithClose
                (rootSeam root)
                (rootAttributionOf root)
                DirectoryHandle
                trail
                fd
                (ContentFailure (rootAttributionOf root) trail (classifyErrno code))
    release stream =
      nativeCloseStream (native root) stream >>= \case
        Right () → pure ()
        Left code → throwIO (CloseFailure DirectoryHandle code (rootAttributionOf root) trail)

-- | Walk the directory components of @names@ below @parent@, holding each, then
-- continue with the final held descriptor and the identities above it.
walk
  ∷ ContentRoot
  → NativeFd
  → Int
  → [NativeName]
  → [NativeIdentity]
  → [NativeName]
  → ([NativeName] → NativeFd → Int → [NativeIdentity] → IO r)
  → IO r
walk _ parent index trail ancestors [] continue = continue trail parent index ancestors
walk root parent index trail ancestors (name : rest) continue = do
  let here = trail <> [name]
  withOpened root parent index name KindDirectory Plain here IntermediateHandle $ \fd stat → do
    checkCycle root here ancestors (statIdentity stat)
    walk root fd (index + 1) here (ancestors <> [statIdentity stat]) rest continue

-- | Open the regular file at a root-relative path and lend it to the callback.
withFile ∷ ContentRoot → [NativeName] → (FileReader → IO r) → IO r
withFile root path body = borrow root $ do
  case path of
    [] → refuse root [] (ForbiddenType KindDirectory KindRegular)
    _ → pure ()
  checkDepth root path
  walk root (rootFd root) 0 [] [reportIdentity (rootReport root)] (init path) $ \trail parent index _ →
    let name = last path
        here = trail <> [name]
     in withOpened root parent index name KindRegular Plain here FileHandle $ \fd _ →
          lendFile root fd here body

lendFile ∷ ContentRoot → NativeFd → [NativeName] → (FileReader → IO r) → IO r
lendFile root fd trail body = do
  liveness ← newLiveness
  body (FileReader root fd trail liveness) `finally` retireLiveness liveness

-- | Open the directory at a root-relative path (the root itself for the empty
-- path) and lend its enumeration to the callback.
withDirectory ∷ ContentRoot → [NativeName] → (DirectoryReader → IO r) → IO r
withDirectory root path body = borrow root $ do
  checkDepth root path
  case path of
    [] → withStream root (rootFd root) 0 structuralName Plain [] [] body
    _ →
      walk root (rootFd root) 0 [] [reportIdentity (rootReport root)] (init path) $ \trail parent index ancestors →
        withStream root parent index (last path) Plain (trail <> [last path]) ancestors body

-- | Open the file an enumeration reported, beneath the enumeration's own held
-- directory. A change since the enumeration observed the entry is a changed
-- mapping.
withEntryFile ∷ DirectoryReader → DirectoryEntry → (FileReader → IO r) → IO r
withEntryFile parent entry body = do
  assertLive (dirLive parent)
  let root = dirRoot parent
      name = entryName entry
      trail = dirTrail parent <> [name]
  checkDepth root trail
  refuseEntry root trail (entryKind entry) KindRegular
  withOpened root (dirFd parent) (length (dirTrail parent)) name KindRegular (Observed (entryKind entry)) trail FileHandle $ \fd _ →
    lendFile root fd trail body

-- | Open the directory an enumeration reported as an enumeration of its own,
-- one level deeper, refusing a directory already on the active ancestor chain.
withEntryDirectory ∷ DirectoryReader → DirectoryEntry → (DirectoryReader → IO r) → IO r
withEntryDirectory parent entry body = do
  assertLive (dirLive parent)
  let root = dirRoot parent
      name = entryName entry
      trail = dirTrail parent <> [name]
  checkDepth root trail
  refuseEntry root trail (entryKind entry) KindDirectory
  withStream
    root
    (dirFd parent)
    (length (dirTrail parent))
    name
    (Observed (entryKind entry))
    trail
    (dirAncestors parent <> [dirIdentity parent])
    body

-- | An entry that was already not the kind required is refused without an open.
refuseEntry ∷ ContentRoot → [NativeName] → EntryKind → EntryKind → IO ()
refuseEntry root trail found wanted =
  unless (found == wanted) $
    refuse root trail (if found == KindSymlink then ForbiddenLink else ForbiddenType found wanted)

-- | The next entry of the directory, without the structural @.@ and @..@;
-- 'Nothing' at the end. Each entry's kind is the entry's own, from a no-follow
-- query beside the held directory.
readEntry ∷ DirectoryReader → IO (Maybe DirectoryEntry)
readEntry reader = do
  assertLive (dirLive reader)
  let root = dirRoot reader
      trail = dirTrail reader
      next = nativeReadStream (native root) (dirStream reader) >>= \case
        Left code → refuse root trail (classifyErrno code)
        Right Nothing → pure Nothing
        Right (Just bytes)
          | bytes == "." || bytes == ".." → next
          | otherwise → case nativeName bytes of
              Left refusal → refuse root trail (InvalidComponent refusal)
              Right name →
                nativeStatAt (native root) (dirFd reader) name >>= \case
                  Right stat → pure (Just (DirectoryEntry name (statKind stat)))
                  Left code
                    | isMissing code → refuse root (trail <> [name]) (MappingChanged Nothing Nothing)
                    | otherwise → refuse root (trail <> [name]) (classifyErrno code)
  next

-- | Metadata of the opened file, read from its descriptor.
fileMetadata ∷ FileReader → IO FileMetadata
fileMetadata reader = do
  assertLive (fileLive reader)
  stat ← fstatOf (fileRoot reader) (fileTrail reader) (fileFd reader)
  pure FileMetadata {metadataSize = statSize stat, metadataLinkCount = statLinks stat, metadataIdentity = statIdentity stat}

-- | Up to @size@ bytes from the opened file as a strict chunk; empty at the end
-- of the file. A short chunk is not the end. The bytes are copied out of the
-- read, so the result owns its memory and may be kept past the callback.
readChunk ∷ FileReader → Int → IO BS.ByteString
readChunk reader size = do
  assertLive (fileLive reader)
  let root = fileRoot reader
      bound = limitReadChunk (rootLimits root)
  when (size < 1) (throwIO (ContentDefect (BadChunkSize size)))
  when (size > bound) (refuse root (fileTrail reader) (LimitExceeded ReadChunk bound))
  hook root BeforeRead
  chunk ← BSI.createUptoN size $ \buffer → performRead root reader buffer size
  hook root AfterRead
  pure (if BS.length chunk < size then BS.copy chunk else chunk)

performRead ∷ ContentRoot → FileReader → Ptr Word8 → Int → IO Int
performRead root reader buffer size =
  nativeRead (native root) (fileFd reader) buffer size >>= \case
    Left code → refuse root (fileTrail reader) (classifyErrno code)
    Right got
      | got < 0 || got > size → throwIO (ContentDefect (ProviderDefect OpRead ("read returned " <> show got <> " for a request of " <> show size)))
      | otherwise → pure got
