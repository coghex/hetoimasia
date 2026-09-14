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
-- The seam exposes no native handle and no session constructor.
module Hetoimasia.GLFW.Seam
  ( -- * Seams
    Seam
  , newSeam
  , SeamScript (..)
  , defaultScript
  , seamSession
  , seamWindow
  , seamCalls
  , seamLiveCallbacks

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
  , WindowRequest (..)
  , WindowVisibility (..)
  ) where

import Control.Concurrent (ThreadId, forkIO, myThreadId, runInBoundThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, finally, throwIO, try)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, atomicModifyIORef', atomicWriteIORef, newIORef, readIORef)
import Data.Int (Int32)
import Data.Text (Text)
import Foreign.Ptr (castFunPtrToPtr, castPtrToFunPtr, intPtrToPtr, nullPtr, ptrToIntPtr)
import Hetoimasia.Foundation.Resource (Assembly, Scoped, allocComposite)
import Hetoimasia.GLFW.Internal.Capture (ErrorCallback)
import Hetoimasia.GLFW.Internal.Session
  ( Backend (..)
  , CallbackStorage (CallbackStorage)
  , Guard
  , Native (..)
  , Session
  , SessionConfig
  , WindowHint (..)
  , WindowRequest (..)
  , WindowVisibility (..)
  , newGuard
  , sessionAssembly
  , windowAssemblyThrough
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
  | DestroyWindow
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
    }

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

-- | Enter a session over this seam's native table.
seamSession ∷ Seam → SessionConfig → Scoped Session
seamSession seam = allocComposite . sessionAssembly (seamNative seam)

-- | Construct a creation-seam window through this seam's native table, which
-- creates nothing real.
seamWindow ∷ Seam → Session → WindowRequest → Assembly ()
seamWindow seam session request = () <$ windowAssemblyThrough (seamNative seam) session request

-- | Every native call so far, oldest first.
seamCalls ∷ Seam → IO [NativeCall]
seamCalls seam = reverse <$> readIORef (seamLog seam)

-- | How many allocated callback storages have not been freed.
seamLiveCallbacks ∷ Seam → IO Int
seamLiveCallbacks seam = length <$> readIORef (seamCallbacks seam)

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
    , nativeDestroyWindow = \_ → do
        record DestroyWindow
        scriptDestroyWindow script reporter
    }
  where
    script = seamScript seam
    reporter = Reporter seam
    record call = atomicModifyIORef' (seamLog seam) (\calls → (call : calls, ()))
    keyOf (CallbackStorage pointer) = fromIntegral (ptrToIntPtr (castFunPtrToPtr pointer))
    identity = do
      failing ← readIORef (seamIdentityFails seam)
      if failing
        then throwIO (userError "the scripted thread identity query failed")
        else do
          self ← myThreadId
          elem self <$> readIORef (seamMainThreads seam)
