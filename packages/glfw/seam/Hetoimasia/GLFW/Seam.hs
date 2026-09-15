-- | The private test seam: the real GLFW session model over a scripted native
-- library.
--
-- A 'Seam' is a native table that initializes nothing. It records every native
-- operation the session model asks for as a 'NativeCall', answers each from a
-- 'SeamScript', and invokes the error callback the model installed when a
-- scripted step reports an error. The model itself — entry order, thread
-- checks, exclusivity, attribution, rollback, and poisoning — is the production
-- code, not a copy of it.
--
-- Thread identity is scripted as well. A seam treats as the process main
-- thread only the Haskell threads designated with
-- 'designateProcessMainThread'; 'asProcessMainThread' runs an action in a
-- bound thread designated that way. Boundness is the runtime's own answer, so
-- an unbound designated thread and an undesignated bound worker are both
-- rejected, each for its own reason.
--
-- Each seam has its own guard, so examples never share occupancy with each
-- other or with a production session.
--
-- Windows are created through the public "Hetoimasia.GLFW.Window" interface
-- in a seam session. The seam hands each a scripted native handle, keeps the
-- callbacks the model attached to it, and delivers scripted 'WindowEvent's to
-- them from inside an owner-boundary step, as GLFW would from inside a setter
-- or a poll: 'seamDrive'. 'seamRejectCloseRequest' is the private close-request
-- transition. Neither is a public command, and neither has authority over a
-- window the seam did not create: each refuses, with 'ForeignSeamWindow' and
-- before anything else, a window whose session was not entered over this
-- seam's own native table. A production window's session holds the process
-- guard, which no seam shares, so no client of this component can inject
-- callbacks into, or clear close requests on, a real window.
--
-- The seam exposes no native handle and no session or window constructor.
module Hetoimasia.GLFW.Seam
  ( -- * Seams
    Seam
  , newSeam
  , SeamScript (..)
  , defaultScript
  , seamSession
  , seamCalls
  , seamLiveCallbacks
  , seamLiveWindowCallbacks
  , featureUnavailableCode

    -- * Driving windows
  , WindowEvent (..)
  , DriveOrigin (..)
  , seamDrive
  , seamDriveCancelledBeforeCommit
  , seamRejectCloseRequest
  , ForeignSeamWindow (..)

    -- * Thread identity
  , asProcessMainThread
  , designateProcessMainThread

    -- * Reporting errors from a scripted step
  , Reporter
  , reportError
  , reportErrorFromOtherThread
  , reportErrorWithFailingIdentity

    -- * What the model asked of the native library
  , NativeCall (..)
  , WindowHint (..)
  , WindowAttribute (..)
  ) where

import Control.Concurrent (ThreadId, forkIO, myThreadId, runInBoundThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), Exception, SomeException, finally, throw, throwIO, try)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, atomicModifyIORef', atomicWriteIORef, newIORef, readIORef)
import Data.Int (Int32)
import Data.Text (Text)
import Foreign.Ptr (Ptr, castFunPtrToPtr, castPtrToFunPtr, intPtrToPtr, nullPtr, ptrToIntPtr)
import Hetoimasia.Foundation.Failure (operation)
import Hetoimasia.Foundation.Resource (Scoped, allocComposite)
import Hetoimasia.GLFW.Internal.Capture (ErrorCallback)
import Hetoimasia.GLFW.Internal.Session
  ( Backend (..)
  , CallbackStorage (CallbackStorage)
  , Guard
  , Native (..)
  , NativeWindow
  , Session
  , SessionConfig
  , WindowAttribute (..)
  , WindowCallbackStorage (WindowCallbackStorage)
  , WindowCallbacks (..)
  , WindowHint (..)
  , newGuard
  , sessionAssembly
  , sessionNative
  )
import Hetoimasia.GLFW.Internal.Window
  ( CloseRequest
  , Window
  , WindowResult
  , rejectCloseRequest
  , windowSession
  , windowStepWith
  )

-- | One native operation the model asked for, in the order it asked.
data NativeCall
  = QueryPlatformSupported Backend
  | CreateErrorCallback
  | AttachErrorCallback
  | DetachErrorCallback
  | FreeErrorCallback
  | SetInitHints Backend
  | Initialize
  | QueryPlatform
  | Terminate
  | ResetWindowHints
  | SetWindowHint WindowHint
  | CreateWindow Int32 Int32 Text
    -- ^ Answered with the next window key, starting at one.
  | DestroyWindow Int
  | CreateWindowCallbacks
  | AttachWindowCallbacks Int
  | DetachWindowCallbacks Int
  | FreeWindowCallbacks
  | QueryWindowSize
  | QueryFramebufferSize
  | QueryContentScale
  | QueryWindowPosition
  | QueryWindowAttribute WindowAttribute
  deriving (Eq, Show)

-- | A native event the seam delivers to a window's attached callbacks.
data WindowEvent
  = ResizedTo Int Int
  | FramebufferResizedTo Int Int
  | ContentScaledTo Float Float
  | MovedTo Int Int
  | FocusChanged Bool
  | IconifyChanged Bool
  | MaximizeChanged Bool
  | RefreshRequested
  | CloseRequested
  | CallbackRaises SomeException
    -- ^ A size callback whose payload raises the exception when copied.

-- | Which kind of native call the events are delivered from inside.
data DriveOrigin
  = DuringSetter
  | DuringPoll
  deriving (Eq, Show)

-- | How the scripted native library answers.
--
-- Each step runs after its call is recorded, and may report errors through the
-- 'Reporter' it is given, or throw.
data SeamScript = SeamScript
  { scriptHostBackend ∷ Maybe Backend
    -- ^ The backend the scripted platform supports.
  , scriptPlatformSupported ∷ Bool
  , scriptInitialize ∷ Reporter → IO Bool
  , scriptReportedPlatform ∷ Maybe Backend → Maybe Backend
    -- ^ What the platform query answers, given the backend last hinted.
  , scriptTerminate ∷ Reporter → IO ()
  , scriptDetachErrorCallback ∷ Reporter → IO ()
  , scriptCreateWindow ∷ Reporter → IO Bool
    -- ^ 'True' returns a live handle; 'False' returns null.
  , scriptDestroyWindow ∷ Reporter → IO ()
  , scriptAttachWindowCallbacks ∷ Reporter → IO ()
  , scriptDetachWindowCallbacks ∷ Reporter → IO ()
  , scriptWindowSize ∷ Reporter → IO (Int, Int)
  , scriptFramebufferSize ∷ Reporter → IO (Int, Int)
  , scriptContentScale ∷ Reporter → IO (Float, Float)
  , scriptWindowPosition ∷ Reporter → IO (Int, Int)
  , scriptWindowAttribute ∷ WindowAttribute → Reporter → IO Bool
  }

-- | A platform supporting X11 on which every step succeeds silently.
defaultScript ∷ SeamScript
defaultScript =
  SeamScript
    { scriptHostBackend = Just X11
    , scriptPlatformSupported = True
    , scriptInitialize = \_ → pure True
    , scriptReportedPlatform = id
    , scriptTerminate = \_ → pure ()
    , scriptDetachErrorCallback = \_ → pure ()
    , scriptCreateWindow = \_ → pure True
    , scriptDestroyWindow = \_ → pure ()
    , scriptAttachWindowCallbacks = \_ → pure ()
    , scriptDetachWindowCallbacks = \_ → pure ()
    , scriptWindowSize = \_ → pure (800, 600)
    , scriptFramebufferSize = \_ → pure (1600, 1200)
    , scriptContentScale = \_ → pure (2, 2)
    , scriptWindowPosition = \_ → pure (40, 30)
    , scriptWindowAttribute = \_ _ → pure False
    }

-- | The code the scripted library reports for a property it cannot provide.
featureUnavailableCode ∷ Int
featureUnavailableCode = 0x0001000C

-- | A scripted native library and what it has observed.
data Seam = Seam
  { seamScript ∷ SeamScript
  , seamGuard ∷ Guard
  , seamLog ∷ IORef [NativeCall]
    -- ^ Newest first.
  , seamMainThreads ∷ IORef [ThreadId]
  , seamIdentityFails ∷ IORef Bool
  , seamCallbacks ∷ IORef [(Int, ErrorCallback)]
    -- ^ Allocated and not yet freed callback storage, by key.
  , seamAttached ∷ IORef (Maybe Int)
  , seamNextKey ∷ IORef Int
  , seamHinted ∷ IORef (Maybe Backend)
  , seamNextWindow ∷ IORef Int
  , seamWindowCallbacks ∷ IORef [(Int, WindowCallbacks)]
    -- ^ Allocated and not yet freed window callback storage, by key.
  , seamAttachedWindows ∷ IORef [(Int, Int)]
    -- ^ Window key to the callback storage key attached to it.
  }

-- | What a scripted step reports errors through.
newtype Reporter = Reporter Seam

-- | A fresh seam with a vacant guard and no designated main thread.
newSeam ∷ SeamScript → IO Seam
newSeam script =
  Seam script
    <$> newGuard
    <*> newIORef []
    <*> newIORef []
    <*> newIORef False
    <*> newIORef []
    <*> newIORef Nothing
    <*> newIORef 1
    <*> newIORef Nothing
    <*> newIORef 1
    <*> newIORef []
    <*> newIORef []

-- | Enter a session over this seam's native table.
seamSession ∷ Seam → SessionConfig → Scoped Session
seamSession seam = allocComposite . sessionAssembly (seamNative seam)

-- | Every native call so far, oldest first.
seamCalls ∷ Seam → IO [NativeCall]
seamCalls seam = reverse <$> readIORef (seamLog seam)

-- | How many allocated callback storages have not been freed.
seamLiveCallbacks ∷ Seam → IO Int
seamLiveCallbacks seam = length <$> readIORef (seamCallbacks seam)

-- | How many allocated window callback storages have not been freed.
seamLiveWindowCallbacks ∷ Seam → IO Int
seamLiveWindowCallbacks seam = length <$> readIORef (seamWindowCallbacks seam)

-- | A seam driver was handed a window its seam did not create.
data ForeignSeamWindow = ForeignSeamWindow
  deriving (Eq, Show)

instance Exception ForeignSeamWindow

-- | Refuse a window whose session was not entered over this seam's native table.
requireSeamWindow ∷ Seam → Window → IO ()
requireSeamWindow seam window =
  unless (nativeGuard (sessionNative (windowSession window)) == seamGuard seam) $
    throwIO ForeignSeamWindow

-- | Deliver events to a window's attached callbacks from inside one owner
-- boundary step, then let the model reconcile them. An ended window answers
-- without a native step; events for a window with no callbacks attached are
-- dropped, as GLFW drops them.
seamDrive ∷ Seam → Window → DriveOrigin → [WindowEvent] → IO (WindowResult ())
seamDrive seam window origin = driveWith (pure ()) seam window (originName origin)
  where
    originName DuringSetter = "seam setter"
    originName DuringPoll = "seam poll"

-- | 'seamDrive' from inside a poll, with a cancellation delivered to the owner
-- at the reconciliation's preparation point: after the captures were folded and
-- the next observation prepared, before anything is committed.
seamDriveCancelledBeforeCommit ∷ Seam → Window → [WindowEvent] → IO (WindowResult ())
seamDriveCancelledBeforeCommit seam window = driveWith (throwIO ThreadKilled) seam window "seam poll"

driveWith ∷ IO () → Seam → Window → Text → [WindowEvent] → IO (WindowResult ())
driveWith interruption seam window originName events = do
  requireSeamWindow seam window
  windowStepWith interruption window (operation originName) $ \handle → do
    attached ← readIORef (seamAttachedWindows seam)
    stored ← readIORef (seamWindowCallbacks seam)
    case lookup (windowKey handle) attached >>= (`lookup` stored) of
      Nothing → pure ()
      Just callbacks → mapM_ (deliver callbacks) events
  where
    deliver callbacks event = case event of
      ResizedTo width height → onWindowSize callbacks (fromIntegral width) (fromIntegral height)
      FramebufferResizedTo width height → onFramebufferSize callbacks (fromIntegral width) (fromIntegral height)
      ContentScaledTo x y → onContentScale callbacks (realToFrac x) (realToFrac y)
      MovedTo x y → onWindowPosition callbacks (fromIntegral x) (fromIntegral y)
      FocusChanged flag → onWindowFocus callbacks (flagOf flag)
      IconifyChanged flag → onWindowIconify callbacks (flagOf flag)
      MaximizeChanged flag → onWindowMaximize callbacks (flagOf flag)
      RefreshRequested → onWindowRefresh callbacks
      CloseRequested → onWindowClose callbacks
      CallbackRaises failure → onWindowSize callbacks (throw failure) 1
    flagOf flag = if flag then 1 else 0

-- | Reject a close request through the model's private transition, on a window
-- this seam created.
seamRejectCloseRequest ∷ Seam → Window → CloseRequest → IO (WindowResult Bool)
seamRejectCloseRequest seam window request = do
  requireSeamWindow seam window
  rejectCloseRequest window request

-- | Treat the calling Haskell thread as the process main thread.
designateProcessMainThread ∷ Seam → IO ()
designateProcessMainThread seam = do
  self ← myThreadId
  atomicModifyIORef' (seamMainThreads seam) (\threads → (self : threads, ()))

-- | Run an action in a bound thread designated as the process main thread.
asProcessMainThread ∷ Seam → IO a → IO a
asProcessMainThread seam action = runInBoundThread (designateProcessMainThread seam >> action)

-- | Invoke the attached error callback on the calling thread, as GLFW does
-- from inside a failing call. With no callback attached the report is dropped,
-- as GLFW drops it.
reportError ∷ Reporter → Int → ByteString → IO ()
reportError (Reporter seam) code description = do
  attached ← readIORef (seamAttached seam)
  callbacks ← readIORef (seamCallbacks seam)
  case attached >>= (`lookup` callbacks) of
    Nothing → pure ()
    Just callback →
      ByteString.useAsCString description (callback (fromIntegral code))

-- | Invoke the attached error callback from another, undesignated thread and
-- wait for it to return. Anything that escaped the callback is rethrown here,
-- so an example can observe that nothing did.
reportErrorFromOtherThread ∷ Reporter → Int → ByteString → IO ()
reportErrorFromOtherThread reporter code description = do
  finished ← newEmptyMVar
  _ ← forkIO (try (reportError reporter code description) >>= putMVar finished)
  outcome ← takeMVar finished
  either (throwIO ∷ SomeException → IO ()) pure outcome

-- | Invoke the attached error callback on the calling thread while the
-- thread-identity query fails.
reportErrorWithFailingIdentity ∷ Reporter → Int → ByteString → IO ()
reportErrorWithFailingIdentity reporter@(Reporter seam) code description = do
  atomicWriteIORef (seamIdentityFails seam) True
  reportError reporter code description `finally` atomicWriteIORef (seamIdentityFails seam) False

-- | The scripted key a seam window handle stands for.
windowKey ∷ Ptr NativeWindow → Int
windowKey = fromIntegral . ptrToIntPtr

seamNative ∷ Seam → Native
seamNative seam =
  Native
    { nativeHostBackend = scriptHostBackend script
    , nativeGuard = seamGuard seam
    , nativeIsProcessMainThread = identity
    , nativePlatformSupported = \backend → do
        record (QueryPlatformSupported backend)
        pure (scriptPlatformSupported script)
    , nativeNewErrorCallback = \callback → do
        record CreateErrorCallback
        key ← atomicModifyIORef' (seamNextKey seam) (\next → (next + 1, next))
        atomicModifyIORef' (seamCallbacks seam) (\stored → ((key, callback) : stored, ()))
        pure (CallbackStorage (castPtrToFunPtr (intPtrToPtr (fromIntegral key))))
    , nativeAttachErrorCallback = \storage → do
        record AttachErrorCallback
        atomicWriteIORef (seamAttached seam) (Just (keyOf storage))
    , nativeDetachErrorCallback = do
        record DetachErrorCallback
        scriptDetachErrorCallback script reporter
        atomicWriteIORef (seamAttached seam) Nothing
    , nativeFreeErrorCallback = \storage → do
        record FreeErrorCallback
        atomicModifyIORef' (seamCallbacks seam) $ \stored →
          (filter ((/= keyOf storage) . fst) stored, ())
    , nativeSetInitHints = \backend → do
        record (SetInitHints backend)
        atomicWriteIORef (seamHinted seam) (Just backend)
    , nativeInitialize = do
        record Initialize
        scriptInitialize script reporter
    , nativeCurrentBackend = do
        record QueryPlatform
        scriptReportedPlatform script <$> readIORef (seamHinted seam)
    , nativeTerminate = do
        record Terminate
        scriptTerminate script reporter
    , nativeResetWindowHints = record ResetWindowHints
    , nativeSetWindowHint = record . SetWindowHint
    , nativeCreateWindow = \width height title → do
        record (CreateWindow width height title)
        live ← scriptCreateWindow script reporter
        if live
          then do
            handle ← atomicModifyIORef' (seamNextWindow seam) (\next → (next + 1, next))
            pure (intPtrToPtr (fromIntegral handle))
          else pure nullPtr
    , nativeDestroyWindow = \handle → do
        record (DestroyWindow (windowKey handle))
        scriptDestroyWindow script reporter
    , nativeNewWindowCallbacks = \callbacks → do
        record CreateWindowCallbacks
        key ← atomicModifyIORef' (seamNextKey seam) (\next → (next + 1, next))
        atomicModifyIORef' (seamWindowCallbacks seam) (\stored → ((key, callbacks) : stored, ()))
        pure (WindowCallbackStorage [castPtrToFunPtr (intPtrToPtr (fromIntegral key))])
    , nativeAttachWindowCallbacks = \handle storage → do
        record (AttachWindowCallbacks (windowKey handle))
        scriptAttachWindowCallbacks script reporter
        atomicModifyIORef' (seamAttachedWindows seam) $ \attached →
          ((windowKey handle, storageKey storage) : attached, ())
    , nativeDetachWindowCallbacks = \handle → do
        record (DetachWindowCallbacks (windowKey handle))
        scriptDetachWindowCallbacks script reporter
        atomicModifyIORef' (seamAttachedWindows seam) $ \attached →
          (filter ((/= windowKey handle) . fst) attached, ())
    , nativeFreeWindowCallbacks = \storage → do
        record FreeWindowCallbacks
        atomicModifyIORef' (seamWindowCallbacks seam) $ \stored →
          (filter ((/= storageKey storage) . fst) stored, ())
    , nativeWindowSize = \_ → record QueryWindowSize >> scriptWindowSize script reporter
    , nativeFramebufferSize = \_ → record QueryFramebufferSize >> scriptFramebufferSize script reporter
    , nativeContentScale = \_ → record QueryContentScale >> scriptContentScale script reporter
    , nativeWindowPosition = \_ → record QueryWindowPosition >> scriptWindowPosition script reporter
    , nativeWindowAttribute = \_ attribute → do
        record (QueryWindowAttribute attribute)
        scriptWindowAttribute script attribute reporter
    , nativeFeatureUnavailable = featureUnavailableCode
    }
  where
    script = seamScript seam
    reporter = Reporter seam
    record call = atomicModifyIORef' (seamLog seam) (\calls → (call : calls, ()))
    keyOf (CallbackStorage pointer) = fromIntegral (ptrToIntPtr (castFunPtrToPtr pointer))
    storageKey (WindowCallbackStorage pointers) = case pointers of
      [pointer] → fromIntegral (ptrToIntPtr (castFunPtrToPtr pointer))
      _ → 0
    identity = do
      failing ← readIORef (seamIdentityFails seam)
      if failing
        then throwIO (userError "the scripted thread identity query failed")
        else do
          self ← myThreadId
          elem self <$> readIORef (seamMainThreads seam)
