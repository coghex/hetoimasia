-- | The fixtures every examples module of the content suite shares: temporary
-- trees, the recording seam, fault injection and boundary gates, and child
-- threads that are always waited for.
--
-- == The recording seam
--
-- 'recordingSeam' wraps the production adapter so that every native
-- acquisition and close is written to one ordered log, beside the boundaries
-- the operations announce. 'accounting' reads the log and decides, without
-- comparing process-wide descriptor totals, whether each descriptor the service
-- acquired was closed exactly once, never closed while its stream owned it, and
-- never closed or used after its close. The runtime's own descriptors and the
-- test harness's are invisible to it, because it only sees the service's calls.
--
-- == Fault injection
--
-- Each injector wraps a 'Seam' and returns one. The failing close injectors
-- close the real descriptor first and then report the failure, because the
-- production close releases the descriptor even when it reports an error; that
-- keeps an injected failure from leaking a real descriptor out of the suite.
--
-- == Children
--
-- Every thread an example starts is a 'Child': its result is read back and
-- re-raised in the example, so an assertion failing inside it fails the example,
-- and 'withChild' kills and waits for it on the way out, so no example leaves a
-- thread running.
module Test.Content.Support
  ( -- * Trees
    withTree
  , name
  , names
  , writeBytes
  , relativeFromCurrent
  , drain
  , entryNamed
  , limitsOf

    -- * The recording seam
  , Event (..)
  , Rig
  , recordingSeam
  , events
  , accounting
  , openDescriptors
  , asserting

    -- * Injection
  , mapNative
  , onBoundary
  , failClose
  , failNthClose
  , failCloseStream
  , Pause
  , newPause
  , pauseWhen
  , awaitReached
  , resumePaused

    -- * Roots
  , withRoot
  , withRootVia
  , withRootOwned
  , readAll

    -- * Children
  , Child
  , spawn
  , withChild
  , awaitChild
  , awaitOutcome
  , awaitDone
  , childThread
  , isFinished

    -- * Failures
  , failsWith
  , contentFailure
  , failureKindOf
  , evidenceOf
  , closeFailuresOf
  ) where

import Control.Concurrent (ThreadId, forkIOWithUnmask, killThread)
import Control.Concurrent.MVar
  ( MVar
  , newEmptyMVar
  , putMVar
  , readMVar
  , takeMVar
  , tryReadMVar
  )
import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , bracket
  , fromException
  , tryWithContext
  )
import qualified Control.Exception as Exception
import Control.Monad (when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Foldable (for_)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (intercalate)
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Hetoimasia.Content (CloseFailure, ContentFailure (..), ContentLimits, DirectoryEntry (..), FailureKind, NativeName, contentLimits, defaultContentLimits, nativeName)
import Hetoimasia.Content.Internal.Native
import Hetoimasia.Content.Internal.Root (ContentRoot, withContentRootWith)
import Hetoimasia.Foundation.Resource
  ( CleanupFailure
  , cleanupFailureException
  , cleanupFailuresInContext
  )
import System.Directory (getCurrentDirectory)
import System.FilePath (splitDirectories)
import System.IO.Temp (withSystemTempDirectory)
import Test.Support.Bounded (bounded)

-- | A fresh temporary directory, removed afterwards. It lives under the system
-- temporary directory, whose ancestors may themselves be symbolic links (macOS
-- keeps it under @/var@, itself a link), which is a launch-path case the root
-- must handle.
withTree ∷ (FilePath → IO a) → IO a
withTree = withSystemTempDirectory "hetoimasia-content"

-- | A native name, for a literal the example knows is valid.
name ∷ ByteString → NativeName
name bytes = either (\refusal → error ("invalid fixture name " <> show bytes <> ": " <> show refusal)) id (nativeName bytes)

names ∷ [ByteString] → [NativeName]
names = map name

writeBytes ∷ FilePath → ByteString → IO ()
writeBytes = BS.writeFile

-- | A path to @target@ spelled relative to the current working directory, so a
-- relative launch path can be exercised without changing that directory.
relativeFromCurrent ∷ FilePath → IO FilePath
relativeFromCurrent target = do
  here ← getCurrentDirectory
  let up = replicate (length (filter (/= "/") (splitDirectories here))) ".."
  pure (intercalate "/" (up <> [dropWhile (== '/') target]))

-- | Everything an action yields until it yields nothing.
drain ∷ IO (Maybe a) → IO [a]
drain next = next >>= maybe (pure []) (\x → (x :) <$> drain next)

-- | The enumerated entry with this name.
entryNamed ∷ [DirectoryEntry] → ByteString → IO DirectoryEntry
entryNamed entries wanted = case [e | e ← entries, entryName e == name wanted] of
  e : _ → pure e
  [] → fail ("no entry named " <> show wanted <> " among " <> show (map entryName entries))

limitsOf ∷ Int → Int → ContentLimits
limitsOf depth chunk = maybe (error "limitsOf: bounds must be positive") id (contentLimits depth chunk)

-- | One thing the service did, in order.
data Event
  = Opened !Int !String
  -- ^ A descriptor was acquired, with the name it was opened under.
  | Closed !Int
  | StreamOpened !Int
  -- ^ The descriptor was handed to a directory stream, which now owns it.
  | StreamClosed !Int
  | Read !Int !Int
  | Boundary !Boundary
  deriving (Eq, Show)

-- | The log a recording seam writes.
newtype Rig = Rig (IORef [Event])

events ∷ Rig → IO [Event]
events (Rig ref) = reverse <$> readIORef ref

record ∷ Rig → Event → IO ()
record (Rig ref) event = atomicModifyIORef' ref (\log' → (event : log', ()))

-- | The production adapter with every acquisition, close and boundary logged.
recordingSeam ∷ IO (Seam, Rig)
recordingSeam = do
  rig ← Rig <$> newIORef []
  let native = seamNative productionSeam
      note = record rig
      recorded =
        native
          { nativeOpenRoot = \path → do
              result ← nativeOpenRoot native path
              for_ result (\(NativeFd fd) → note (Opened (fromIntegral fd) "<root>"))
              pure result
          , nativeOpenAt = \parent component directory → do
              result ← nativeOpenAt native parent component directory
              for_ result (\(NativeFd fd) → note (Opened (fromIntegral fd) (show component)))
              pure result
          , nativeOpenStream = \(NativeFd fd) → do
              result ← nativeOpenStream native (NativeFd fd)
              for_ result (\_ → note (StreamOpened (fromIntegral fd)))
              pure result
          , nativeCloseStream = \stream → do
              NativeFd fd ← nativeStreamFd native stream
              result ← nativeCloseStream native stream
              note (StreamClosed (fromIntegral fd))
              pure result
          , nativeClose = \(NativeFd fd) → do
              result ← nativeClose native (NativeFd fd)
              note (Closed (fromIntegral fd))
              pure result
          , nativeRead = \(NativeFd fd) buffer size → do
              note (Read (fromIntegral fd) size)
              nativeRead native (NativeFd fd) buffer size
          }
  pure (Seam {seamNative = recorded, seamBoundary = note . Boundary}, rig)

-- | Decide whether a log is a balanced account of descriptors, returning the
-- most that were open at once.
--
-- Every acquisition must be closed exactly once: a descriptor handed to a stream
-- is closed only by the stream's close, never separately, and a descriptor that
-- was never handed over is closed only separately. A close of a descriptor that
-- is not open (a double close, which could close a reused number) is an error,
-- and so is an acquisition of a number that is still open.
accounting ∷ [Event] → Either String Int
accounting = go Set.empty Set.empty 0
  where
    go open _ peak [] =
      if Set.null open
        then Right peak
        else Left ("descriptors never closed: " <> show (Set.toList open))
    go open streams peak (event : rest) = case event of
      Opened fd label
        | fd `Set.member` open → Left ("descriptor " <> show fd <> " opened as " <> label <> " while still open")
        | otherwise → go (Set.insert fd open) streams (max peak (Set.size (Set.insert fd open))) rest
      StreamOpened fd
        | fd `Set.member` open && not (fd `Set.member` streams) → go open (Set.insert fd streams) peak rest
        | otherwise → Left ("descriptor " <> show fd <> " handed to a stream when not open and unowned")
      Closed fd
        | fd `Set.member` streams → Left ("descriptor " <> show fd <> " closed separately while its stream owned it")
        | fd `Set.member` open → go (Set.delete fd open) streams peak rest
        | otherwise → Left ("descriptor " <> show fd <> " closed when not open")
      StreamClosed fd
        | fd `Set.member` streams → go (Set.delete fd open) (Set.delete fd streams) peak rest
        | otherwise → Left ("stream of descriptor " <> show fd <> " closed when it owned nothing")
      Read fd _
        | fd `Set.member` open → go open streams peak rest
        | otherwise → Left ("descriptor " <> show fd <> " read when not open")
      Boundary _ → go open streams peak rest

-- | The descriptors still open at the end of a log.
openDescriptors ∷ [Event] → [Int]
openDescriptors = Set.toList . foldl step Set.empty
  where
    step open = \case
      Opened fd _ → Set.insert fd open
      Closed fd → Set.delete fd open
      StreamClosed fd → Set.delete fd open
      _ → open

-- | Require a balanced log, reporting the log itself when it is not.
asserting ∷ Rig → IO Int
asserting rig = do
  log' ← events rig
  case accounting log' of
    Right peak → pure peak
    Left problem →
      fail (problem <> "\n" <> intercalate "\n" (map show log'))

-- | Replace part of the adapter.
mapNative ∷ (Native → Native) → Seam → Seam
mapNative change seam = seam {seamNative = change (seamNative seam)}

-- | Run an extra action at every boundary, after the seam's own.
onBoundary ∷ (Boundary → IO ()) → Seam → Seam
onBoundary extra seam = seam {seamBoundary = \boundary → seamBoundary seam boundary >> extra boundary}

-- | Make the close of every descriptor the predicate selects report @code@,
-- after really closing it.
failClose ∷ (Int → Bool) → Int → Seam → Seam
failClose selected code = mapNative $ \native →
  native
    { nativeClose = \(NativeFd fd) → do
        result ← nativeClose native (NativeFd fd)
        pure (if selected (fromIntegral fd) then Left code else result)
    }

-- | Make the @n@th close (counting from one, across all descriptors the seam
-- closes) report @code@, after really closing it.
failNthClose ∷ IORef Int → Int → Int → Seam → Seam
failNthClose counter n code = mapNative $ \native →
  native
    { nativeClose = \fd → do
        result ← nativeClose native fd
        position ← atomicModifyIORef' counter (\count → (count + 1, count + 1))
        pure (if position == n then Left code else result)
    }

-- | 'failClose' for the close of a directory stream.
failCloseStream ∷ (Int → Bool) → Int → Seam → Seam
failCloseStream selected code = mapNative $ \native →
  native
    { nativeCloseStream = \stream → do
        NativeFd fd ← nativeStreamFd native stream
        result ← nativeCloseStream native stream
        pure (if selected (fromIntegral fd) then Left code else result)
    }

-- | A rendezvous: an operation announces it has reached a boundary and waits
-- there until the example lets it go.
data Pause = Pause (MVar ()) (MVar ()) (IORef Bool)

newPause ∷ IO Pause
newPause = Pause <$> newEmptyMVar <*> newEmptyMVar <*> newIORef False

-- | Pause the first operation to reach a boundary the predicate selects.
pauseWhen ∷ (Boundary → Bool) → Pause → Seam → Seam
pauseWhen selected (Pause reached resume fired) = onBoundary $ \boundary →
  when (selected boundary) $ do
    first ← atomicModifyIORef' fired (\already → (True, not already))
    when first $ do
      putMVar reached ()
      takeMVar resume

-- | Wait until an operation has reached the pause.
awaitReached ∷ Pause → IO ()
awaitReached (Pause reached _ _) = bounded (readMVar reached)

-- | Let the paused operation go.
resumePaused ∷ Pause → IO ()
resumePaused (Pause _ resume _) = putMVar resume ()

-- | Open a root over the production adapter.
withRoot ∷ FilePath → (ContentRoot → IO a) → IO a
withRoot = withRootVia productionSeam defaultContentLimits

-- | The root's scope on the calling thread, for an example that owns the thread
-- the scope runs on (to cancel it, or to watch its exit from outside).
withRootOwned ∷ Seam → ContentLimits → FilePath → (ContentRoot → IO a) → IO a
withRootOwned seam limits path = withContentRootWith seam limits (BC.pack path)

-- | The root's scope runs on a child of its own, which the example waits for
-- within a bound. A defect that kept an operation from retiring would hold the
-- scope's exit, which waits uninterruptibly by design; running the scope here
-- turns that hang into an example that fails within its bound instead of one
-- that never ends.
withRootVia ∷ Seam → ContentLimits → FilePath → (ContentRoot → IO a) → IO a
withRootVia seam limits path use =
  spawn (withContentRootWith seam limits (BC.pack path) use) >>= awaitChild

-- | Every byte of an opened file, read in chunks of @size@.
readAll ∷ Int → (Int → IO ByteString) → IO ByteString
readAll size readChunk' = go []
  where
    go acc = do
      chunk ← readChunk' size
      if BS.null chunk then pure (BS.concat (reverse acc)) else go (chunk : acc)

-- | A thread an example started, and what it ended with.
data Child a = Child ThreadId (MVar (Either SomeException a))

spawn ∷ IO a → IO (Child a)
spawn action = do
  result ← newEmptyMVar
  -- The action runs unmasked whatever state the example thread was in, so a
  -- cancellation is delivered inside it; the outcome is recorded masked, so it
  -- is always filled, and the example re-raises it.
  thread ← forkIOWithUnmask (\unmask → Exception.mask_ (Exception.try (unmask action) >>= putMVar result))
  pure (Child thread result)

-- | Run an example with a child, killing and awaiting it on the way out.
withChild ∷ IO a → (Child a → IO r) → IO r
withChild action = bracket (spawn action) finish
  where
    finish (Child thread result) = do
      killThread thread
      bounded (readMVar result) >>= \_ → pure ()

childThread ∷ Child a → ThreadId
childThread (Child thread _) = thread

-- | Whether the child has already ended, without waiting for it.
isFinished ∷ Child a → IO Bool
isFinished (Child _ result) = maybe False (const True) <$> tryReadMVar result

-- | Wait for the child, re-raising what it ended with.
awaitChild ∷ Child a → IO a
awaitChild (Child _ result) = bounded (readMVar result) >>= either Exception.throwIO pure

-- | Wait for the child and return how it ended.
awaitOutcome ∷ Child a → IO (Either SomeException a)
awaitOutcome (Child _ result) = bounded (readMVar result)

-- | Wait for the child to have terminated, whatever it ended with.
awaitDone ∷ Child a → IO ()
awaitDone child = awaitOutcome child >>= \_ → pure ()

-- | Run an action that must fail with an @e@, returning the exception with its
-- context. Any other exception, an assertion failure included, propagates
-- untouched; an action that returns fails the example.
failsWith ∷ Exception e ⇒ IO a → IO (ExceptionWithContext e)
failsWith action =
  tryWithContext action >>= \case
    Left failure -> pure failure
    Right _ → fail "expected the action to fail, but it returned"

contentFailure ∷ IO a → IO ContentFailure
contentFailure action = (\(ExceptionWithContext _ failure) → failure) <$> failsWith action

failureKindOf ∷ IO a → IO FailureKind
failureKindOf action = failureKind <$> contentFailure action

-- | The cleanup evidence retained beside an exception.
evidenceOf ∷ ExceptionWithContext e → [CleanupFailure]
evidenceOf (ExceptionWithContext context _) = cleanupFailuresInContext context

-- | The close failures among retained cleanup evidence.
closeFailuresOf ∷ [CleanupFailure] → [CloseFailure]
closeFailuresOf = mapMaybe keep
  where
    keep failure' = case cleanupFailureException failure' of
      ExceptionWithContext _ exception → fromException exception

