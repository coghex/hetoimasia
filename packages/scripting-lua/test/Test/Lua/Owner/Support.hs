-- | What the owner's examples share: the failures they raise, an ordered event
-- log, a running owner on a thread of its own, and a standard finalizing
-- callback with a dependency whose liveness the examples can see.
--
-- The owner is built through the package-private 'OwnerConfig', whose hooks and
-- allowlist the public configuration does not offer, so an example can install a
-- callback a finalizer reaches, make memory run out at a chosen step, or fail a
-- chosen construction step.
module Test.Lua.Owner.Support
  ( -- * Failures an example raises
    BodyBroke (..)
  , CloseBroke (..)
  , Marker (..)
    -- * Reading how a lifetime ended
  , Outcome
  , runOwner
  , causeOf
  , evidenceLabels
  , evidenceCauses
  , evidenceMarkers
  , primaryMarkers
  , asyncCancellation
    -- * An ordered log
  , Events
  , newEvents
  , note
  , events
    -- * A finalizing callback with a dependency
  , Finalizing (..)
  , newFinalizing
  , finalizingConfig
  , failingReleaseConfig
  , failingFinalizerConfig
  , failingCloseConfig
    -- * Running an owner on its own thread
  , ownerThread
  , Captured
  , newCaptured
  , capture
  , captured
  ) where

import Control.Concurrent (ThreadId, forkIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar)
import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , annotateIO
  , fromException
  , mask
  , throwIO
  , tryWithContext
  )
import Control.Exception.Annotation (ExceptionAnnotation)
import Control.Exception.Context (ExceptionContext, getExceptionAnnotations)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Set as Set
import Data.Text (Text)
import Hetoimasia.Foundation.Resource
  ( CleanupFailure
  , cleanupFailureException
  , cleanupFailureLabel
  , cleanupFailuresInContext
  )
import Hetoimasia.Scripting.Lua.Bridge (Library (LibraryBase), Vm, chunkName)
import Hetoimasia.Scripting.Lua.Internal.Callback (CallbackResult (NoResult), installCallback)
import Hetoimasia.Scripting.Lua.Internal.Owner
  ( OwnedVm
  , OwnerConfig (ownerAfterLibraries, ownerAllowlist, ownerChunks)
  , defaultOwnerConfig
  , withOwnedVm
  )

-- | The failure an example's body raises.
newtype BodyBroke = BodyBroke String
  deriving (Eq, Show)

instance Exception BodyBroke

-- | A failure a finalizer's callback or a retained release raises during the
-- close.
newtype CloseBroke = CloseBroke String
  deriving (Eq, Show)

instance Exception CloseBroke

-- | A caller's own annotation, used to prove a failure keeps the context it was
-- raised with.
newtype Marker = Marker String
  deriving (Eq, Show)

instance ExceptionAnnotation Marker

-- | How a lifetime ended, with the context of whatever it raised.
type Outcome a = Either (ExceptionWithContext SomeException) a

-- | Run an owner and catch how it ended, keeping the context.
runOwner ∷ OwnerConfig → (OwnedVm → IO a) → IO (Outcome a)
runOwner config body = tryWithContext (withOwnedVm config body)

-- | The primary exception, as a particular type.
causeOf ∷ Exception e ⇒ ExceptionWithContext SomeException → Maybe e
causeOf (ExceptionWithContext _ exception) = fromException exception

-- | Whether the primary exception is a cancellation, which is what a worker's
-- outcome classifies as cancelled.
asyncCancellation ∷ ExceptionWithContext SomeException → Bool
asyncCancellation (ExceptionWithContext _ exception) = case fromException exception ∷ Maybe SomeAsyncException of
  Just _ → True
  Nothing → False

-- | The cleanup failures the failure carries, read as a supervisor reads them.
evidenceOf ∷ ExceptionWithContext SomeException → [CleanupFailure]
evidenceOf (ExceptionWithContext context _) = cleanupFailuresInContext context

-- | The labels of those cleanup failures, in order.
evidenceLabels ∷ ExceptionWithContext SomeException → [Text]
evidenceLabels = map cleanupFailureLabel . evidenceOf

-- | The exceptions of those cleanup failures, as a particular type.
evidenceCauses ∷ Exception e ⇒ ExceptionWithContext SomeException → [Maybe e]
evidenceCauses failure =
  [ fromException exception
  | cleanup ← evidenceOf failure
  , let ExceptionWithContext _ exception = cleanupFailureException cleanup
  ]

-- | The 'Marker' annotations each cleanup failure's own context carries.
evidenceMarkers ∷ ExceptionWithContext SomeException → [[String]]
evidenceMarkers failure =
  [ markersIn context
  | cleanup ← evidenceOf failure
  , let ExceptionWithContext context _ = cleanupFailureException cleanup
  ]

-- | The 'Marker' annotations the primary failure's own context carries.
primaryMarkers ∷ ExceptionWithContext SomeException → [String]
primaryMarkers (ExceptionWithContext context _) = markersIn context

markersIn ∷ ExceptionContext → [String]
markersIn context = [note' | Marker note' ← getExceptionAnnotations context]

-- | An ordered log of what happened, oldest first.
newtype Events = Events (IORef [Text])

newEvents ∷ IO Events
newEvents = Events <$> newIORef []

note ∷ Events → Text → IO ()
note (Events ref) entry = atomicModifyIORef' ref (\held → (entry : held, ()))

events ∷ Events → IO [Text]
events (Events ref) = reverse <$> readIORef ref

-- | A callback a finalizer calls, with the dependency it borrows.
data Finalizing = Finalizing
  { finalizingEvents ∷ !Events
    -- ^ What the callback and its release noted, in order.
  , finalizingLive ∷ !(IORef Bool)
    -- ^ Whether the dependency is still held: true from the callback's
    -- installation and false once its release has run.
  }

newFinalizing ∷ IO Finalizing
newFinalizing = Finalizing <$> newEvents <*> newIORef False

-- | An owner config over the base library whose VM holds a guard that calls the
-- allowlisted callback @finalize@ when the state closes.
--
-- The callback notes that it ran and whether its dependency was still held then;
-- its release notes that it ran. Together they show the callback reached during
-- the close with its dependency live and the dependency released afterwards.
finalizingConfig ∷ Finalizing → OwnerConfig
finalizingConfig finalizing =
  (defaultOwnerConfig [LibraryBase])
    { ownerAllowlist = Set.fromList ["finalize"]
    , ownerAfterLibraries = \vm → install finalizing vm
    , ownerChunks = [(chunkName "guard", "guard = setmetatable({}, {__gc = function() finalize() end})")]
    }

install ∷ Finalizing → Vm → IO ()
install (Finalizing log' live) vm = do
  writeIORef live True
  installCallback
    vm
    "finalize"
    ( do
        held ← readIORef live
        note log' (if held then "finalizer: dependency live" else "finalizer: dependency gone")
        pure NoResult
    )
    (writeIORef live False >> note log' "release")

-- | 'finalizingConfig' plus a dependency whose release fails, annotated, when the
-- close releases it.
failingReleaseConfig ∷ Finalizing → OwnerConfig
failingReleaseConfig finalizing =
  let base = finalizingConfig finalizing
   in base
        { ownerAfterLibraries = \vm → do
            ownerAfterLibraries base vm
            installCallback
              vm
              "unused"
              (pure NoResult)
              (annotateIO (Marker "release context") (throwIO (CloseBroke "release")))
        }

-- | 'finalizingConfig' plus an allowlisted callback that a second guard's
-- finalizer calls and that fails, annotated.
failingFinalizerConfig ∷ Finalizing → OwnerConfig
failingFinalizerConfig finalizing =
  let base = finalizingConfig finalizing
   in base
        { ownerAllowlist = Set.fromList ["finalize", "boom"]
        , ownerAfterLibraries = \vm → do
            ownerAfterLibraries base vm
            installCallback
              vm
              "boom"
              (annotateIO (Marker "finalizer context") (throwIO (CloseBroke "finalizer")))
              (pure ())
        , ownerChunks =
            ownerChunks base
              <> [(chunkName "failing guard", "failing_guard = setmetatable({}, {__gc = function() boom() end})")]
        }

-- | 'failingFinalizerConfig' plus a dependency whose release fails, annotated:
-- a close that fails in a finalizer's callback and again in a release.
failingCloseConfig ∷ Finalizing → OwnerConfig
failingCloseConfig finalizing =
  let base = failingFinalizerConfig finalizing
   in base
        { ownerAfterLibraries = \vm → do
            ownerAfterLibraries base vm
            installCallback
              vm
              "unused"
              (pure NoResult)
              (annotateIO (Marker "release context") (throwIO (CloseBroke "release")))
        }

-- | Run an owner on a thread of its own, forked masked so that it is masked from
-- its first instruction, and publish how it ended once.
ownerThread ∷ OwnerConfig → (OwnedVm → IO a) → IO (ThreadId, MVar (Outcome a))
ownerThread config body = do
  slot ← newEmptyMVar
  thread ← mask $ \restore →
    forkIO (restore (runOwner config body) >>= putMVar slot)
  pure (thread, slot)

-- | A value an example's body publishes for the example to read.
newtype Captured a = Captured (IORef (Maybe a))

newCaptured ∷ IO (Captured a)
newCaptured = Captured <$> newIORef Nothing

capture ∷ Captured a → a → IO ()
capture (Captured ref) = writeIORef ref . Just

captured ∷ Captured a → IO (Maybe a)
captured (Captured ref) = readIORef ref
