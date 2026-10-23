{-# LANGUAGE OverloadedStrings #-}

-- | What the texture pipeline examples share: a session of a real content root, inventory, read
-- pool and texture pipeline over the real bounded decoder, a /gated fake backend/, real supervised
-- Lua owners (one VM each, with its own lease scope) that call the pipeline through bindings written
-- the way an engine facade writes them, and the Lua that drives them.
--
-- Evidence from the real adapter and evidence that is injected are kept apart by name. The probe
-- wraps the real verified reader: a gated read still opens and hashes a real file once its gate
-- opens. The backend is injected, and says so: it is the example's, it decides when an upload
-- completes, when its buffers retire, when a texture is registered and when a released texture is
-- proved retired, and it proves ownership transitions, not uploaded texels or GPU readiness.
--
-- Nothing sleeps. An example knows what has happened by blocking in STM, on a gate or on what a
-- script recorded, and the whole example is bounded. Every thread an example starts is waited for.
module Test.LuaEngine.Texture.Support
  ( -- * The session
    Session (..)
  , Config (..)
  , config
  , ReaderOf
  , realReader
  , injectedIoError
  , injectedDefect
  , withSession
  , fatalSession
  , Layout (..)
  , note
  , history
  , awaitNote
  , awaitHistory
  , lineStarting
  , rewrite
  , key'

    -- * The probe
  , Probe
  , closeGate
  , openGate
  , awaitStarted
  , startedPaths
  , readsStarted
  , maxActive

    -- * The fake backend
  , Fake
  , Held (..)
  , awaitUploads
  , uploadsSeen
  , uploadN
  , retireBuffers
  , registerTexture
  , finishUpload
  , failUpload
  , withdrawUpload
  , retireTexture
  , setAutoRetire
  , setRaiseOnUpload
  , setRaiseOnRelease
  , setImmediate
  , Immediate (..)
  , setHoldSubmission
  , awaitSubmitting
  , withNested
  , releaseCalls
  , awaitReleaseCalls
  , uploadCancelled
  , awaitUploadCancelled
  , texturesLive

    -- * VMs
  , Timing (..)
  , Vm (..)
  , startVm
  , startVmWith
  , admitDriver
  , admitModule
  , ownerOf
  , stopInstance
  , command
  , commandWith
  , Load (..)
  , load
  , vmDiagnostics
  , awaitVmDiagnostic
  , awaitEnd
  , awaitOwnerEnded
  , awaitFailure
  , instanceTicket
  , requestFailureOf
  , awaitPhase
  , awaitGate
  , releaseGate
  , directRead
  , grantOne
  , leaseSummary
  , awaitLeaseSummary

    -- * Readings
  , pipelineNow
  , awaitPipeline
  , ownerNow
  , awaitOwner
  , sessionNow
  , awaitSession
  , poolReading
  , awaitPool
  , lanesCharged

    -- * Re-exports
  , module Hetoimasia.LuaEngine.Texture
  , Necessity (..)
  ) where

import Control.Concurrent (ThreadId, forkIO, killThread, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, tryPutMVar)
import Control.Concurrent.STM
  ( TVar
  , atomically
  , modifyTVar'
  , newTVar
  , newTVarIO
  , readTVar
  , readTVarIO
  , retry
  , writeTVar
  )
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, finally, fromException, rethrowIO, throwIO, tryWithContext)
import Control.Monad (forM_, unless, void, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (UTCTime), secondsToDiffTime)
import Data.Word (Word64)
import Hetoimasia.Content (FailureKind (Unreadable), defaultContentLimits, withContentRoot)
import Hetoimasia.Content.Identity (ContentKey, contentKeyPath, logicalPathBytes, parseReference, rootKey)
import Hetoimasia.Content.Inventory
  ( Inventory
  , InventorySpec (..)
  , ReadFailure (..)
  , ReadOutcome (ReadIoError)
  , inventoryIdentityLimits
  , inventoryLimits
  , inventoryLimitsOf
  , inventoryRoot
  , inventoryRootKey
  , readVerified
  , scanInventory
  )
import Hetoimasia.Content.ReadPool
  ( PoolStatus
  , ReadPool
  , ReadPriority
  , ReadRequest (..)
  , ReadResult (..)
  , poolSpec
  , reserveSlot
  , status
  , submit
  , withReadPoolUsing
  )
import Hetoimasia.Foundation.Log (Logger, MetadataProviders (..), callbackSink, defaultLogFilter, mkLoggerWith, unsafeComponent)
import Hetoimasia.Foundation.Time (DurationRequirement (RequirePositive), durationFromNanoseconds)
import Hetoimasia.LuaEngine.Profile (ByteLimit (CopiedValueBytes), Bytes (Bytes), Count (Count), CountLimit (CopiedValueDepth, CopiedValueElements), Profile, bytesLimit, countLimit)
import Hetoimasia.LuaEngine.Request
import Hetoimasia.LuaEngine.Texture
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.Runtime.Supervision
  ( Recognition (Unrecognized)
  , Role (Service)
  , RuntimeControl
  , WorkerPolicy (..)
  , WorkerStatus (..)
  , awaitSupervised
  , withSupervision
  )
import qualified Hetoimasia.Runtime.Supervision as Supervision
import Hetoimasia.Scripting.Lua.Admission (Necessity (..), admittedHandleType, newRequestHandles)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lease (Leases, ScopeSummary, instanceLeases, leaseCapabilityType, newLeases)
import Hetoimasia.Scripting.Lua.Lending (newLending)
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime, newLuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.HUnit.Lang (HUnitFailure, assertFailure)

-- The session --------------------------------------------------------------------------------------

-- | The files to create, relative to the content root.
newtype Layout = Layout [(FilePath, ByteString)]

-- | What an example chooses: the profile, the pool's workers and slots, the pipeline's job capacity,
-- how the pool's reader is made, the files, and how many leases an instance's scope holds.
data Config = Config
  { cfgProfile ∷ !Profile
  , cfgPool ∷ !(Int, Int)
  , cfgJobs ∷ !Int
  , cfgReader ∷ ReaderOf
  , cfgLayout ∷ !Layout
  , cfgLeases ∷ !Int
  , cfgHooks ∷ !PipelineHooks
  }

-- | The usual configuration: a pool of two workers and sixteen slots, room for sixteen jobs and
-- sixteen leases, the real reader behind the probe's gates.
config ∷ Profile → Layout → Config
config profile layout = Config profile (2, 16) 16 realReader layout 16 noHooks

-- | How the pool's reader is made from the real one and the session's probe.
type ReaderOf = Probe → Inventory → (ContentKey → Int → IO (Either ReadFailure ByteString)) → ContentKey → Int → IO (Either ReadFailure ByteString)

realReader ∷ ReaderOf
realReader probe _ = probeReader probe

-- | A reader that answers an expected I/O failure for the paths it is given and reads the rest for
-- real, behind the probe's gates. Injected: the failure is not one a filesystem produced.
injectedIoError ∷ [ByteString] → ReaderOf
injectedIoError paths probe inventory real = probeReader probe $ \key allowance →
  if pathOfKey key `elem` paths
    then pure (Left (ReadFailure (inventoryRoot inventory) key (ReadIoError (Unreadable 5))))
    else real key allowance

-- | A reader that raises this for the paths it is given and reads the rest for real. Injected: an
-- engine defect, not an expected failure.
injectedDefect ∷ [ByteString] → IOError → ReaderOf
injectedDefect paths failure probe _ real = probeReader probe $ \key allowance →
  if pathOfKey key `elem` paths then throwIO failure else real key allowance

-- | Everything an example shares.
data Session = Session
  { ssProfile ∷ !Profile
  , ssTree ∷ !FilePath
  , ssInventory ∷ !Inventory
  , ssPool ∷ !ReadPool
  , ssPipeline ∷ !TexturePipeline
  , ssProbe ∷ !Probe
  , ssFake ∷ !Fake
  , ssLog ∷ !(IORef [Text])
  , ssGates ∷ !(IORef (Map Text (MVar ())))
  , ssEntered ∷ !(IORef (Map Text (MVar ())))
  , ssOpened ∷ !(IORef Bool)
  , ssIds ∷ !(IORef (Map Text InstanceId))
  , ssTickets ∷ !(IORef (Map Text InstanceTicket))
  , ssConfig ∷ !Config
  }

scanSpec ∷ InventorySpec
scanSpec =
  InventorySpec
    { specEntries = 100
    , specSegments = 8
    , specPathBytes = 200
    , specSegmentBytes = 40
    , specFileBytes = 40 * 1024 * 1024
    , specRootBytes = 128 * 1024 * 1024
    , specBufferBytes = 64 * 1024
    }

-- | Run an example over a session: a temporary content root with these files, scanned; a pool whose
-- reader is made by the config; a texture pipeline over a fake backend; real supervision.
--
-- However the example ends, the gates are opened and the backend's janitor answers every upload still
-- held and proves every released texture retired, so a failing example fails instead of waiting for
-- what is right to wait for. The janitor is stopped, and waited for, after the pipeline's scope.
withSession ∷ Config → (Session → RuntimeControl → LuaRuntime → IO a) → IO a
withSession cfg body =
  withSystemTempDirectory "hetoimasia-lua-engine-texture" $ \tree → do
    forM_ (let Layout files = cfgLayout cfg in files) $ \(path, bytes) → do
      createDirectoryIfMissing True (takeDirectory (tree </> path))
      ByteString.writeFile (tree </> path) bytes
    limits ← either (\refused → assertFailure ("scan limits refused: " <> show refused)) pure (inventoryLimits scanSpec)
    root' ← either (\refused → assertFailure ("root key refused: " <> show refused)) pure (rootKey "texture-test")
    textureSpec' ← either (\refused → assertFailure ("texture spec refused: " <> show refused)) pure (textureSpec (cfgProfile cfg) (cfgJobs cfg))
    withContentRoot defaultContentLimits tree $ \root → do
      inventory ← scanInventory limits root' root >>= either (\refused → assertFailure ("scan refused: " <> show refused)) pure
      probe ← newProbe
      fake ← newFake
      spec ← either (\refused → assertFailure ("pool refused: " <> show refused)) pure (uncurry poolSpec (cfgPool cfg))
      withJanitor fake $
        withReadPoolUsing spec (cfgReader cfg probe inventory (readVerified inventory root)) $ \pool →
          withTexturePipelineWith (cfgHooks cfg) textureSpec' (fakeBackend fake) pool inventory $ \pipeline → do
            session ←
              Session (cfgProfile cfg) tree inventory pool pipeline probe fake
                <$> newIORef []
                <*> newIORef Map.empty
                <*> newIORef Map.empty
                <*> newIORef False
                <*> newIORef Map.empty
                <*> newIORef Map.empty
                <*> pure cfg
            withLoggingLifetime quietLogger $ \lifetime →
              withSupervision lifetime $ \control → do
                runtime ← newLuaRuntime control
                outcome ←
                  timeout exampleBound (body session control runtime)
                    `finally` (writeIORef (ssOpened session) True >> openGates session >> openAllProbeGates probe >> flushFake fake)
                case outcome of
                  Just value → pure value
                  Nothing → do
                    seen ← history session
                    assertFailure ("the example did not finish within its bound; it had recorded: " <> show (reverse (take 12 (reverse seen))))

-- | A second pipeline inside the example, over a backend of its own that no janitor answers, for the
-- examples about the pipeline's own end. The body runs with a session whose pipeline and backend are
-- the nested ones and must end every instance it started on them; when it returns the nested scope
-- closes admission and drains. @onClosed@ runs on a helper thread, once the nested pipeline has closed
-- admission and while its scope is still draining, and is what lets the backend finish; the scope
-- cannot return before it has, and the helper's own failure is raised after.
withNested ∷ Session → (Session → IO a) → (Session → IO ()) → IO a
withNested session body onClosed = do
  fake ← newFake
  spec ← either (\refused → assertFailure ("texture spec refused: " <> show refused)) pure (textureSpec (ssProfile session) (cfgJobs (ssConfig session)))
  done ← newEmptyMVar
  value ←
    withTexturePipelineWith (cfgHooks (ssConfig session)) spec (fakeBackend fake) (ssPool session) (ssInventory session) $ \pipeline → do
      let nested = session {ssPipeline = pipeline, ssFake = fake}
      _ ← forkIO $ do
        atomically (pipelineOpen pipeline >>= \open → when open retry)
        tryWithContext @SomeException (onClosed nested) >>= putMVar done
      body nested
  readMVar done >>= either rethrowIO pure
  pure value

-- | An example whose owner is expected to end in a failure of the application's own, which
-- supervision raises at the boundary: answers the failure with its context. A failed assertion or
-- the example's bound is not that failure, and is raised as itself.
fatalSession ∷ Config → (Session → RuntimeControl → LuaRuntime → IO ()) → IO (ExceptionWithContext SomeException)
fatalSession cfg body =
  tryWithContext @SomeException (withSession cfg body) >>= \case
    Left failure@(ExceptionWithContext _ raised)
      | Just (_ ∷ HUnitFailure) ← fromException raised → throwIO raised
      | otherwise → pure failure
    Right () → assertFailure "expected the owner to fail, but the example returned"

exampleBound ∷ Int
exampleBound = 30 * 1000 * 1000

quietLogger ∷ Logger
quietLogger = mkLoggerWith defaultLogFilter metadata (callbackSink (\_ → pure ()))
  where
    metadata =
      MetadataProviders
        { metadataClock = pure (UTCTime (fromGregorian 2026 10 22) (secondsToDiffTime 43200))
        , metadataThread = pure "1"
        }

-- | Replace a file's content on disk after the scan: an edit the inventory does not know of.
rewrite ∷ Session → FilePath → ByteString → IO ()
rewrite session path = ByteString.writeFile (ssTree session </> path)

-- | The key a path names in the session's root.
key' ∷ Session → ByteString → ContentKey
key' session path =
  either (\refused → error ("invalid fixture path " <> show path <> ": " <> show refused)) id $
    parseReference (inventoryIdentityLimits (inventoryLimitsOf (ssInventory session))) (inventoryRootKey (ssInventory session)) path

-- | Record that something happened, in the order the scripts and the fakes share.
note ∷ Session → Text → IO ()
note session entry = atomicModifyIORef' (ssLog session) (\held → (entry : held, ()))

-- | What happened, oldest first.
history ∷ Session → IO [Text]
history session = reverse <$> readIORef (ssLog session)

-- | Wait, without sleeping, until this was recorded.
awaitNote ∷ Session → Text → IO ()
awaitNote session wanted = awaitHistory session (wanted `elem`)

awaitHistory ∷ Session → ([Text] → Bool) → IO ()
awaitHistory session wanted = do
  seen ← history session
  if wanted seen then pure () else yield >> awaitHistory session wanted

-- | Wait for a line that starts with this, and answer it.
lineStarting ∷ Session → Text → IO Text
lineStarting session prefix = do
  seen ← history session
  case filter (Text.isPrefixOf prefix) seen of
    line : _ → pure line
    [] → yield >> lineStarting session prefix

-- The probe -------------------------------------------------------------------------------------------

-- | What the wrapped reader did.
data Probe = Probe
  { prStarted ∷ !(TVar [ByteString])
  , prActive ∷ !(TVar Int)
  , prMax ∷ !(TVar Int)
  , prClosed ∷ !(TVar (Set ByteString))
  , prReleased ∷ !(TVar Bool)
  }

newProbe ∷ IO Probe
newProbe = Probe <$> newTVarIO [] <*> newTVarIO 0 <*> newTVarIO 0 <*> newTVarIO Set.empty <*> newTVarIO False

probeReader ∷ Probe → (ContentKey → Int → IO a) → ContentKey → Int → IO a
probeReader probe inner key allowance = do
  let path = pathOfKey key
  atomically $ do
    modifyTVar' (prStarted probe) (<> [path])
    active ← readTVar (prActive probe)
    writeTVar (prActive probe) (active + 1)
    modifyTVar' (prMax probe) (max (active + 1))
  ( do
      atomically $ do
        closed ← readTVar (prClosed probe)
        released ← readTVar (prReleased probe)
        when (Set.member path closed && not released) retry
      inner key allowance
    )
    `finally` atomically (modifyTVar' (prActive probe) (subtract 1))

-- | Close the gate of a path: a read of it waits when it reaches the gate.
closeGate ∷ Probe → ByteString → IO ()
closeGate probe path = atomically (modifyTVar' (prClosed probe) (Set.insert path))

openGate ∷ Probe → ByteString → IO ()
openGate probe path = atomically (modifyTVar' (prClosed probe) (Set.delete path))

openAllProbeGates ∷ Probe → IO ()
openAllProbeGates probe = atomically (writeTVar (prReleased probe) True)

-- | Wait until this many reads have begun.
awaitStarted ∷ Probe → Int → IO ()
awaitStarted probe wanted = atomically $ do
  started ← readTVar (prStarted probe)
  unless (length started >= wanted) retry

-- | The paths the reader began, oldest first.
startedPaths ∷ Probe → IO [ByteString]
startedPaths = atomically . readTVar . prStarted

readsStarted ∷ Probe → IO Int
readsStarted probe = length <$> startedPaths probe

-- | The most reads that were inside the reader at once.
maxActive ∷ Probe → IO Int
maxActive = atomically . readTVar . prMax

pathOfKey ∷ ContentKey → ByteString
pathOfKey = logicalPathBytes . contentKeyPath

-- The fake backend --------------------------------------------------------------------------------------

-- | What the fake does when it is called inside 'backendUpload', before it returns: the immediate
-- callback during submission.
data Immediate
  = ImmediateReady
  | ImmediateFailed
  deriving (Eq, Show)

-- | One upload the fake accepted, and what has been told of it.
data Held = Held
  { heldIndex ∷ !Int
  , heldUpload ∷ !Upload
  , heldSink ∷ !UploadSink
  , heldCancelled ∷ !(TVar Bool)
  }

-- | The injected backend: it holds every upload until the example finishes it, and every released
-- texture until the example proves it retired.
data Fake = Fake
  { fkHeld ∷ !(TVar [Held])
  , fkTerminal ∷ !(TVar (Set Int))
  , fkBuffers ∷ !(TVar (Set Int))
  , fkTextures ∷ !(TVar (Map Word64 (TVar RetirementState)))
  , fkReleases ∷ !(TVar [Word64])
  , fkNext ∷ !(TVar Word64)
  , fkAuto ∷ !(TVar Bool)
  , fkRaiseUpload ∷ !(TVar Bool)
  , fkRaiseRelease ∷ !(TVar Bool)
  , fkImmediate ∷ !(TVar (Maybe Immediate))
  , fkFlush ∷ !(TVar Bool)
  , fkHold ∷ !(TVar Bool)
  , fkEntered ∷ !(TVar Int)
  }

newFake ∷ IO Fake
newFake =
  Fake
    <$> newTVarIO []
    <*> newTVarIO Set.empty
    <*> newTVarIO Set.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO []
    <*> newTVarIO 100
    <*> newTVarIO False
    <*> newTVarIO False
    <*> newTVarIO False
    <*> newTVarIO Nothing
    <*> newTVarIO False
    <*> newTVarIO False
    <*> newTVarIO 0

fakeBackend ∷ Fake → TextureBackend
fakeBackend fake =
  TextureBackend $ \upload sink → do
    raising ← readTVarIO (fkRaiseUpload fake)
    when raising $ throwIO (userError "the fake backend refused the upload")
    held ← atomically $ do
      seen ← readTVar (fkHeld fake)
      cancelled ← newTVar False
      let found = Held (length seen) upload sink cancelled
      writeTVar (fkHeld fake) (seen <> [found])
      pure found
    readTVarIO (fkImmediate fake) >>= \case
      Just ImmediateReady → void (retireBuffers fake held >> registerTexture fake held)
      Just ImmediateFailed → void (retireBuffers fake held >> failUpload fake held "an immediate device loss")
      Nothing → pure ()
    -- The submission window: the call has been entered and has not returned. A fake that holds it
    -- here says so; a real backend never blocks in the call.
    atomically (modifyTVar' (fkEntered fake) (+ 1))
    atomically $ do
      holding ← readTVar (fkHold fake)
      when holding retry
    pure (UploadWork (atomically (writeTVar (heldCancelled held) True)))

-- | The index-th upload, waiting for it to arrive.
uploadN ∷ Fake → Int → IO Held
uploadN fake index = atomically $ do
  seen ← readTVar (fkHeld fake)
  case drop index seen of
    found : _ → pure found
    [] → retry

-- | Wait until this many uploads were accepted.
awaitUploads ∷ Fake → Int → IO ()
awaitUploads fake wanted = atomically $ do
  seen ← readTVar (fkHeld fake)
  unless (length seen >= wanted) retry

-- | How many uploads the fake accepted.
uploadsSeen ∷ Fake → IO Int
uploadsSeen fake = length <$> readTVarIO (fkHeld fake)

-- | Tell the sink the backend no longer reads the level of this upload.
retireBuffers ∷ Fake → Held → IO SinkAnswer
retireBuffers fake held = do
  atomically (modifyTVar' (fkBuffers fake) (Set.insert (heldIndex held)))
  sinkBuffersRetired (heldSink held)

-- | Register a texture for this upload and tell the sink it is usable. Answers the identity the
-- fake gave it and what the sink said.
registerTexture ∷ Fake → Held → IO (Word64, SinkAnswer)
registerTexture fake held = do
  (identity, state) ← atomically $ do
    identity ← readTVar (fkNext fake)
    writeTVar (fkNext fake) (identity + 1)
    state ← newTVar ProviderPending
    modifyTVar' (fkTextures fake) (Map.insert identity state)
    modifyTVar' (fkTerminal fake) (Set.insert (heldIndex held))
    pure (identity, state)
  let texture =
        BackendTexture
          { textureIdentity = identity
          , textureRelease = do
              atomically (modifyTVar' (fkReleases fake) (<> [identity]))
              raising ← readTVarIO (fkRaiseRelease fake)
              when raising $ throwIO (userError "the fake backend could not release the texture")
              auto ← readTVarIO (fkAuto fake)
              when auto (atomically (writeTVar state ProviderComplete))
              pure (readTVar state)
          }
  answer ← sinkReady (heldSink held) texture
  pure (identity, answer)

-- | The buffers retire and the texture is registered: an upload that finished.
finishUpload ∷ Fake → Held → IO Word64
finishUpload fake held = retireBuffers fake held >> fst <$> registerTexture fake held

-- | The upload failed on the device. The backend still owes the end of the borrowed level, which it
-- gives first.
failUpload ∷ Fake → Held → Text → IO SinkAnswer
failUpload fake held why = do
  atomically (modifyTVar' (fkTerminal fake) (Set.insert (heldIndex held)))
  _ ← retireBuffers fake held
  sinkFailed (heldSink held) (UploadFailure why)

-- | The backend honoured a cancellation: no texture, and the buffers retire.
withdrawUpload ∷ Fake → Held → IO SinkAnswer
withdrawUpload fake held = do
  atomically (modifyTVar' (fkTerminal fake) (Set.insert (heldIndex held)))
  _ ← retireBuffers fake held
  sinkWithdrawn (heldSink held)

-- | Prove a released texture retired: nothing holds it, the GPU has finished.
retireTexture ∷ Fake → Word64 → IO ()
retireTexture fake identity = atomically $ do
  textures ← readTVar (fkTextures fake)
  forM_ (Map.lookup identity textures) (\state → writeTVar state ProviderComplete)

-- | Whether a released texture is proved retired at once, or only when the example says.
setAutoRetire ∷ Fake → Bool → IO ()
setAutoRetire fake = atomically . writeTVar (fkAuto fake)

setRaiseOnUpload ∷ Fake → Bool → IO ()
setRaiseOnUpload fake = atomically . writeTVar (fkRaiseUpload fake)

setRaiseOnRelease ∷ Fake → Bool → IO ()
setRaiseOnRelease fake = atomically . writeTVar (fkRaiseRelease fake)

setImmediate ∷ Fake → Maybe Immediate → IO ()
setImmediate fake = atomically . writeTVar (fkImmediate fake)

-- | The identities whose release the backend was asked for, oldest first.
releaseCalls ∷ Fake → IO [Word64]
releaseCalls = readTVarIO . fkReleases

awaitReleaseCalls ∷ Fake → Int → IO ()
awaitReleaseCalls fake wanted = atomically $ do
  calls ← readTVar (fkReleases fake)
  unless (length calls >= wanted) retry

-- | Hold every submission inside 'backendUpload' (the call entered, not returned) until it is let go.
setHoldSubmission ∷ Fake → Bool → IO ()
setHoldSubmission fake = atomically . writeTVar (fkHold fake)

-- | Wait until this many submissions have entered 'backendUpload'.
awaitSubmitting ∷ Fake → Int → IO ()
awaitSubmitting fake wanted = atomically $ do
  entered ← readTVar (fkEntered fake)
  unless (entered >= wanted) retry

-- | Whether the backend was told to cancel this upload.
uploadCancelled ∷ Held → IO Bool
uploadCancelled = readTVarIO . heldCancelled

awaitUploadCancelled ∷ Held → IO ()
awaitUploadCancelled held = atomically (readTVar (heldCancelled held) >>= \flag → unless flag retry)

-- | The textures the fake registered and has not been asked to release.
texturesLive ∷ Fake → IO [Word64]
texturesLive fake = atomically $ do
  textures ← readTVar (fkTextures fake)
  released ← readTVar (fkReleases fake)
  pure [identity | identity ← Map.keys textures, identity `notElem` released]

-- | The janitor of an example: once the example ends, it finishes every upload still held (completes
-- it, or withdraws it when the engine cancelled it) and proves every texture retired, and keeps doing so until it is stopped. The
-- pipeline's drain waits for the backend; the janitor is what lets a failing example end.
flushFake ∷ Fake → IO ()
flushFake fake = atomically (writeTVar (fkFlush fake) True >> writeTVar (fkAuto fake) True)

withJanitor ∷ Fake → IO a → IO a
withJanitor fake action = do
  done ← newEmptyMVar
  thread ← forkIO (janitor `finally` putMVar done ())
  action `finally` stop thread done
  where
    stop ∷ ThreadId → MVar () → IO ()
    stop thread done = killThread thread >> readMVar done
    janitor = do
      work ← atomically $ do
        flushing ← readTVar (fkFlush fake)
        unless flushing retry
        terminal ← readTVar (fkTerminal fake)
        buffers ← readTVar (fkBuffers fake)
        held ← readTVar (fkHeld fake)
        textures ← readTVar (fkTextures fake)
        pending ← fmap concat . mapM (\(identity, state) → (\s → [identity | isPending s]) <$> readTVar state) $ Map.toList textures
        let open = [found | found ← held, not (Set.member (heldIndex found) terminal)]
            unretired = [found | found ← held, Set.member (heldIndex found) terminal, not (Set.member (heldIndex found) buffers)]
        when (null open && null unretired && null pending) retry
        pure (open, unretired, pending)
      forM_ (first3 work) $ \found → do
        cancelled ← uploadCancelled found
        if cancelled then void (withdrawUpload fake found) else void (finishUpload fake found)
      forM_ (second3 work) (void . retireBuffers fake)
      forM_ (third3 work) (retireTexture fake)
      janitor
    isPending = \case ProviderPending → True; _ → False
    first3 (a, _, _) = a
    second3 (_, b, _) = b
    third3 (_, _, c) = c

-- VMs -----------------------------------------------------------------------------------------------------

-- | How the owner's settlements reach Lua: an owner on elapsed time, or one on logical time.
data Timing = OnArrival | AtAssignedTick
  deriving (Eq, Show)

-- | One VM: its owner, its service, its lease scope and the texture owners of its instances.
data Vm = Vm
  { vmOwner ∷ ScheduledOwner
  , vmService ∷ !TextureService
  , vmLeases ∷ !Leases
  , vmOwners ∷ !(IORef (Map Text TextureOwner))
  }

requiredPolicy ∷ WorkerPolicy
requiredPolicy = WorkerPolicy Service Supervision.Required (unsafeComponent "test.luaengine.texture") (\_ → pure Unrecognized)

requestHandleType ∷ Text
requestHandleType = "treq"

-- | A VM over the session's pipeline: its own lease scope and handle registry, one owner on this
-- timing. The pool, the pipeline and its workers are the session's.
startVm ∷ Session → LuaRuntime → Text → Timing → IO Vm
startVm session = startVmWith session id

-- | The same, with the endpoint the grant names wrapped by the example: a wrapper that observes or
-- holds the provider's completion from outside it. The wrapper is the example's, and says so where it
-- is used.
startVmWith ∷ Session → (RequestEndpoint → RequestEndpoint) → LuaRuntime → Text → Timing → IO Vm
startVmWith session wrap runtime label timing = do
  handles ← newRequestHandles
  requests ← either (\refused → assertFailure ("the profile was refused: " <> show refused)) pure (m1Requests (ssProfile session) handles)
  service ← either (\refused → assertFailure ("the service was refused: " <> show refused)) pure (textureService requests (ssPipeline session))
  lending ← newLending
  leases ← newLeases lending (cfgLeases (ssConfig session))
  owners ← newIORef Map.empty
  let vm' = Vm (error "owner not started") service leases owners
      registered =
        either (error . ("registration refused: " <>) . show) id $
          registration [admittedHandleType handles requestHandleType, leaseCapabilityType leases textureHandleType] (bindings session vm' requests)
      Bytes copied = bytesLimit (ssProfile session) CopiedValueBytes
      Count depth = countLimit (ssProfile session) CopiedValueDepth
      Count elements = countLimit (ssProfile session) CopiedValueElements
      limits = either (error . show) id (valueLimits (fromIntegral copied) (fromIntegral depth) (fromIntegral elements))
      vm =
        (vmConfig [LibraryBase, LibraryString, LibraryTable, LibraryMath])
          { vmRegistration = registered
          , vmPolicy = ["fx", "request", "tex"]
          , vmOwnerName = label
          , vmModules = [driverSource, enderSource, failingSource]
          , vmValueLimits = limits
          }
      grant =
        RequestGrant
          [wrap (textureEndpoint service)]
          64
          (if timing == OnArrival then SettleOnArrival else SettleAtAssignedTick Nothing)
      spec =
        (scheduledSpec vm requiredPolicy bounds)
          { scheduledInstances = Just (defaultInstanceConfig {instanceBounds = InstanceBounds 8 16 8 8, instanceSources = [commandSource]})
          , scheduledLending = Just lending
          , scheduledLeases = Just leases
          , scheduledRequestHandles = Just handles
          , scheduledRequests = Just grant
          }
  startScheduledOwner runtime spec >>= \case
    ScheduledStarted owner → pure vm' {vmOwner = owner}
    other → assertFailure ("expected an owner, found " <> take 80 (showStart other))
  where
    bounds =
      SchedulerBounds
        { boundActiveTasks = 16
        , boundQueuedAdmissions = 16
        , boundRetainedResults = 32
        , boundQuanta = Quanta (Quantum 4) (Quantum 4) (Quantum 4)
        , boundOutstandingGrants = 4
        , boundControlRequests = 8
        , boundServiceBudget = Nothing
        }
    showStart = \case
      ScheduledUnavailable failure → "unavailable: " <> show failure
      ScheduledRejected → "rejected"
      ScheduledEnded → "ended"
      ScheduledStarted _ → "started"

-- | The texture owner of the instance of this name.
ownerOf ∷ Vm → Text → IO TextureOwner
ownerOf vm name = (Map.! name) <$> readIORef (vmOwners vm)

-- | The bindings: @fx.record@ and @fx.block@, the common operations from the adapter, and
-- @tex.load(who, path [, optional])@, @tex.use(texture)@ and @tex.release(texture)@, written the way
-- the facade will write them from "Hetoimasia.LuaEngine.Texture". The @who@ names the texture owner:
-- this is the example's own scaffolding, where the facade would hold the instance's owner in its
-- binding. It is not an API of the engine.
bindings ∷ Session → Vm → M1Requests → [Namespace]
bindings session vm _ =
  [ namespace "fx" [recording, blocking]
  , namespace "request" (m1RequestBindings (M1Service requestHandleType textureValueSchema))
  , namespace "tex" [loading, using, releasing]
  ]
  where
    service = vmService vm
    recording =
      stateOperation "record" [SText] [] $ \arguments → do
        case arguments of
          [VText text] → note session text
          _ → pure ()
        pure []
    blocking =
      stateOperation "block" [SText] [] $ \arguments → do
        case arguments of
          [VText name] → do
            gateIn (ssEntered session) name >>= void . (`tryPutMVar` ())
            opened ← readIORef (ssOpened session)
            gate ← gateIn (ssGates session) name
            when opened (void (tryPutMVar gate ()))
            readMVar gate
          _ → pure ()
        pure []
    loading =
      withArgumentCheck check $
        asynchronousNativeRequestIn "load" [SText, SText, SOptional SBoolean] (m1StartSchemas requestHandleType) $ \context values → do
          asked ← requestFrom values
          case asked of
            Left why → throwIO (userError (Text.unpack why))
            Right request → do
              started ← startTexture service request context
              pure (m1StartResults requestHandleType started)
    check owner values =
      requestFrom values >>= \case
        Left why → pure (Just why)
        Right request → textureArgumentCheck service (const request) owner values
    using =
      recoverableRefusals $
        stateOperation "use" [SCapability textureHandleType] [SInteger] $ \arguments → case arguments of
          [VCapability handle] → do
            view ← withTexture (vmLeases vm) (capabilityKey handle) pure
            pure [VInteger (fromIntegral (viewIdentity view))]
          _ → pure []
    releasing =
      recoverableRefusals . releaseOperation "release" textureHandleType [SText] $ \arguments → case arguments of
        [VCapability handle] → do
          answer ← releaseTexture (vmLeases vm) (capabilityKey handle)
          pure [VText (releaseWord answer)]
        _ → pure []
    requestFrom ∷ [Value] → IO (Either Text TextureRequest)
    requestFrom = \case
      VText who : VText path : rest → do
        owners ← readIORef (vmOwners vm)
        pure $ case Map.lookup who owners of
          Nothing → Left ("no texture owner named " <> who)
          Just owner → case textureKey service (Text.encodeUtf8 path) of
            Left refused → Left ("address refused: " <> Text.pack (show refused))
            Right key →
              Right
                TextureRequest
                  { requestedOwner = owner
                  , requestedKey = key
                  , requestedNecessity = case rest of
                      [VBoolean True] → OptionalRequest
                      _ → RequiredRequest
                  }
      _ → pure (Left "a texture owner and a path are required")

gateIn ∷ IORef (Map Text (MVar ())) → Text → IO (MVar ())
gateIn table name = do
  fresh ← newEmptyMVar
  atomicModifyIORef' table $ \held → case Map.lookup name held of
    Just existing → (held, existing)
    Nothing → (Map.insert name fresh held, fresh)

openGates ∷ Session → IO ()
openGates session = do
  held ← readIORef (ssGates session)
  mapM_ (void . (`tryPutMVar` ())) held

-- | Wait until a script is inside the call that holds this gate.
awaitGate ∷ Session → Text → IO ()
awaitGate session name = gateIn (ssEntered session) name >>= readMVar

-- | Let the script that is inside the call holding this gate go on.
releaseGate ∷ Session → Text → IO ()
releaseGate session name = gateIn (ssGates session) name >>= void . (`tryPutMVar` ())

-- | Read this path through the shared pool directly, as another consumer of the pool does (the module
-- loader, for one): a slot reserved and the job submitted at this priority. Answers a variable the
-- read's sink fills with whether it succeeded. The caller releases the slot when the read retired.
directRead ∷ Session → ReadPriority → ByteString → IO (MVar Bool)
directRead session priority path = do
  done ← newEmptyMVar
  reserved ← atomically (reserveSlot (ssPool session))
  unless reserved (assertFailure "the pool has no slot left for a direct read")
  submitted ←
    atomically $
      submit
        (ssPool session)
        ReadRequest
          { requestKey = key' session path
          , requestAllowance = 1048576
          , requestPriority = priority
          , requestSink = \result → putMVar done (case result of ReadSucceeded _ → True; _ → False)
          }
  case submitted of
    Right _ → pure done
    Left _ → assertFailure "the pool refused a direct read"

-- | The Lua the commands run. A table is shown with its keys in order, a capability as its type.
driverSource ∷ ModuleSource
driverSource =
  ModuleSource (ModuleRef "driver" "1") (Text.encodeUtf8 (Text.unlines source)) hookEntries
  where
    source =
      [ "local function fmt(v)"
      , "  local t = type(v)"
      , "  if t == 'string' then return v end"
      , "  if t ~= 'table' then"
      , "    if t == 'userdata' or t == 'function' then return '<' .. t .. '>' end"
      , "    return tostring(v)"
      , "  end"
      , "  local keys = {}"
      , "  for k in pairs(v) do keys[#keys + 1] = tostring(k) end"
      , "  table.sort(keys)"
      , "  local out = {}"
      , "  for _, k in ipairs(keys) do out[#out + 1] = k .. '=' .. fmt(v[k]) end"
      , "  return '{' .. table.concat(out, ',') .. '}'"
      , "end"
      , "local function run(self, p)"
      , "  local key = p.key or 'a'"
      , "  local out = '?'"
      , "  if p.op == 'start' then"
      , "    local r, err = tex.load(p.name, p.path or 'a.png', p.optional)"
      , "    if r then self.hs[key] = r out = 'started' else out = 'busy:' .. err.code .. ':' .. err.message end"
      , "  elseif p.op == 'pstart' then"
      , "    local ok, r, err = pcall(tex.load, p.name, p.path or 'a.png', p.optional)"
      , "    if not ok then out = 'error ' .. tostring(r)"
      , "    elseif r then self.hs[key] = r out = 'started'"
      , "    else out = 'busy:' .. err.code .. ':' .. err.message end"
      , "  elseif p.op == 'ready' then out = tostring(request.ready(self.hs[key]))"
      , "  elseif p.op == 'take' then"
      , "    local r = request.take(self.hs[key])"
      , "    if r.status == 'success' then self.ts[key] = r.value.texture end"
      , "    out = fmt(r)"
      , "  elseif p.op == 'ptake' then"
      , "    local ok, r = pcall(request.take, self.hs[key])"
      , "    if ok then out = fmt(r) else out = 'error ' .. tostring(r) end"
      , "  elseif p.op == 'cancel' then out = request.cancel(self.hs[key])"
      , "  elseif p.op == 'wait' then"
      , "    fx.record('waiting ' .. key)"
      , "    out = tostring(select('#', request.wait(self.hs[key])))"
      , "  elseif p.op == 'wait_take' then"
      , "    fx.record('waiting ' .. key)"
      , "    request.wait(self.hs[key])"
      , "    local r = request.take(self.hs[key])"
      , "    if r.status == 'success' then self.ts[key] = r.value.texture end"
      , "    out = fmt(r)"
      , "  elseif p.op == 'use' then out = tostring(tex.use(self.ts[key]))"
      , "  elseif p.op == 'puse' then"
      , "    local ok, r = pcall(tex.use, self.ts[key])"
      , "    out = ok and tostring(r) or ('error ' .. tostring(r))"
      , "  elseif p.op == 'release' then out = tex.release(self.ts[key])"
      , "  elseif p.op == 'prelease' then"
      , "    local ok, r = pcall(tex.release, self.ts[key])"
      , "    out = ok and tostring(r) or ('error ' .. tostring(r))"
      , "  elseif p.op == 'share' then"
      , "    shared = self.ts[key]"
      , "    out = 'shared'"
      , "  elseif p.op == 'adopt' then"
      , "    self.ts[key] = shared"
      , "    out = 'adopted'"
      , "  elseif p.op == 'block_cancel' then"
      , "    fx.block(key)"
      , "    out = request.cancel(self.hs[key])"
      , "  elseif p.op == 'block' then fx.block(key) out = 'released'"
      , "  end"
      , "  fx.record(p.name .. ' ' .. p.op .. ' ' .. key .. ' ' .. out)"
      , "end"
      , "function init(self, api)"
      , "  self.hs = {}"
      , "  self.ts = {}"
      , "  api.connect('cmd', function(self, event) run(self, event.payload) end)"
      , "end"
      , "function shutdown(self, reason) fx.record('shutdown ' .. reason) end"
      ]

commandSource ∷ EventSource
commandSource =
  EventSource
    "cmd"
    ( SRecord
        [ ("op", SText)
        , ("key", SOptional SText)
        , ("name", SText)
        , ("path", SOptional SText)
        , ("optional", SOptional SBoolean)
        ]
    )

-- | An instance that asks for a texture from its @shutdown@ hook, where a request is refused, and
-- records what came of it. Its texture owner is named @e@.
enderSource ∷ ModuleSource
enderSource =
  ModuleSource (ModuleRef "ender" "1") (Text.encodeUtf8 (Text.unlines source)) hookEntries
  where
    source =
      [ "function init(self, api) end"
      , "function shutdown(self, reason)"
      , "  local ok, err = pcall(tex.load, 'e', 'a.png', nil)"
      , "  fx.record('shutdown load ' .. tostring(ok) .. ' ' .. tostring(err))"
      , "end"
      ]

-- | An instance that starts a texture request in @init@ and whose @shutdown@ hook raises. Its texture
-- owner is named @f@.
failingSource ∷ ModuleSource
failingSource =
  ModuleSource (ModuleRef "failing" "1") (Text.encodeUtf8 (Text.unlines source)) hookEntries
  where
    source =
      [ "function init(self, api)"
      , "  self.r = tex.load('f', 'a.png', nil)"
      , "  fx.record('failing started')"
      , "end"
      , "function shutdown(self, reason) error('shutdown boom') end"
      ]

-- | Admit an instance of the driver under this name, with a texture owner of that name, and wait
-- until it is active.
admitDriver ∷ Session → Vm → Text → IO ()
admitDriver session vm name = admitModule session vm "driver" name

-- | Admit an instance of this module under this name, with a texture owner of that name, and wait
-- until it is active.
admitModule ∷ Session → Vm → Text → Text → IO ()
admitModule session vm moduleName name = do
  owner ← newTextureOwner (ssPipeline session)
  atomicModifyIORef' (vmOwners vm) (\held → (Map.insert name owner held, ()))
  admitInstance (scheduledEndpoint (vmOwner vm)) (InstanceRequest (ModuleRef moduleName "1") EventOnly (Just name) OrdinaryClass ["cmd"]) >>= \case
    InstanceAccepted identity ticket → do
      atomicModifyIORef' (ssIds session) (\held → (Map.insert name identity held, ()))
      atomicModifyIORef' (ssTickets session) (\held → (Map.insert name ticket held, ()))
    other → assertFailure ("expected the instance accepted, found " <> take 80 (show other))
  awaitPhase session vm name Active

-- | Ask the instance of this name to stop, expecting the request accepted.
stopInstance ∷ Session → Vm → Text → IO ()
stopInstance session vm name = do
  identity ← (Map.! name) <$> readIORef (ssIds session)
  requestInstanceControl (scheduledEndpoint (vmOwner vm)) identity InstanceStop >>= \case
    InstanceControlAccepted _ → pure ()
    other → assertFailure ("expected the stop accepted, found " <> take 80 (show other))

-- | What a command starts.
data Load = Load
  { loadPath ∷ !Text
  , loadOptional ∷ !Bool
  }

-- | A required load of this path.
load ∷ Text → Load
load path = Load path False

-- | Tell the instance of this name to do this with the request or texture it keeps under the key.
command ∷ Session → Vm → Text → Text → Text → IO ()
command session vm name op key = commandWith session vm name op key Nothing

-- | The same, with what to load when the command starts a request.
commandWith ∷ Session → Vm → Text → Text → Text → Maybe Load → IO ()
commandWith session vm name op key asked = do
  identity ← (Map.! name) <$> readIORef (ssIds session)
  let payload =
        VRecord $
          [("op", VText op), ("key", VText key), ("name", VText name)]
            <> concat
              [ [("path", VText (loadPath found))] <> [("optional", VBoolean True) | loadOptional found]
              | Just found ← [asked]
              ]
  deliverEvent (scheduledEndpoint (vmOwner vm)) identity "cmd" payload >>= \case
    DeliveryAccepted _ → pure ()
    other → assertFailure ("expected the command accepted, found " <> take 80 (show other))

-- | Grant one logical step and wait for the tick to complete.
grantOne ∷ RuntimeControl → Vm → IO ()
grantOne control vm = do
  one ← either (\refused → assertFailure (show refused)) pure (durationFromNanoseconds RequirePositive 1)
  void (grantScheduledStep (scheduledEndpoint (vmOwner vm)) one)
  void (awaitTicksComplete control (vmOwner vm))

-- | The owner's request service, read in one transaction.
vmDiagnostics ∷ Vm → IO ProviderDiagnostics
vmDiagnostics vm =
  atomically (requestDiagnostics (scheduledEndpoint (vmOwner vm))) >>= maybe (assertFailure "the owner has no request service") pure

-- | Block, in STM, until the owner's request service reads like this.
awaitVmDiagnostic ∷ Vm → (ProviderDiagnostics → Bool) → IO ()
awaitVmDiagnostic vm wanted = atomically $ do
  found ← requestDiagnostics (scheduledEndpoint (vmOwner vm))
  case found of
    Just reading | wanted reading → pure ()
    _ → retry

-- | One instance's leases, in one transaction.
leaseSummary ∷ Session → Vm → Text → IO ScopeSummary
leaseSummary session vm name = do
  identity ← (Map.! name) <$> readIORef (ssIds session)
  atomically (instanceLeases (vmLeases vm) identity)

-- | Block, in STM, until an instance's leases satisfy this.
awaitLeaseSummary ∷ Session → Vm → Text → (ScopeSummary → Bool) → IO ()
awaitLeaseSummary session vm name wanted = do
  identity ← (Map.! name) <$> readIORef (ssIds session)
  atomically $ do
    summary ← instanceLeases (vmLeases vm) identity
    unless (wanted summary) retry

-- | Block until an instance is in this phase.
awaitPhase ∷ Session → Vm → Text → InstancePhase → IO ()
awaitPhase session vm name wanted = do
  identity ← (Map.! name) <$> readIORef (ssIds session)
  atomically $
    inspectInstance (scheduledEndpoint (vmOwner vm)) identity >>= \case
      Just snapshot | snapshotPhase snapshot == wanted → pure ()
      _ → retry

-- | Wait for the owner to end, and answer how.
awaitEnd ∷ RuntimeControl → Vm → IO WorkerStatus
awaitEnd control vm =
  awaitSupervised control $
    scheduledStatus (vmOwner vm) >>= \case
      WorkerLive → retry
      status' → pure status'

-- | Wait, without supervision's rethrow, until the owner is no longer live.
awaitOwnerEnded ∷ Vm → IO ()
awaitOwnerEnded vm = atomically $
  scheduledStatus (vmOwner vm) >>= \case
    WorkerLive → retry
    _ → pure ()

-- | The failure an instance settled with, waiting for it to settle.
awaitFailure ∷ Session → Text → IO (Maybe InstanceFailure)
awaitFailure session name = do
  ticket ← (Map.! name) <$> readIORef (ssTickets session)
  settlement ← waitInstance ticket
  pure $ case resultOutcome settlement of
    InstanceFailed failure → Just failure
    _ → Nothing

-- | The ticket of an instance admitted under this name: wait on it to see the instance settle.
instanceTicket ∷ Session → Text → IO InstanceTicket
instanceTicket session name = (Map.! name) <$> readIORef (ssTickets session)

-- | The endpoint and attributed text of a required request's failure.
requestFailureOf ∷ Maybe InstanceFailure → Maybe (Text, Text)
requestFailureOf failure = case fmap failureError failure of
  Just (ErrorRequest endpoint why) → Just (endpoint, why)
  _ → Nothing

-- Readings --------------------------------------------------------------------------------------------------

-- | The pipeline, read in one transaction.
pipelineNow ∷ Session → IO PipelineReading
pipelineNow session = atomically (pipelineReading (ssPipeline session))

-- | Block until the pipeline reads like this.
awaitPipeline ∷ Session → (PipelineReading → Bool) → IO ()
awaitPipeline session wanted = atomically $ do
  reading ← pipelineReading (ssPipeline session)
  unless (wanted reading) retry

-- | One instance's texture banks.
ownerNow ∷ Vm → Text → IO OwnerReading
ownerNow vm name = ownerOf vm name >>= atomically . ownerReading

-- | Block until the instance's banks read like this.
awaitOwner ∷ Vm → Text → (OwnerReading → Bool) → IO ()
awaitOwner vm name wanted = do
  owner ← ownerOf vm name
  atomically $ do
    reading ← ownerReading owner
    unless (wanted reading) retry

-- | The nominal bytes the session's textures hold.
sessionNow ∷ Session → IO Word64
sessionNow session = atomically (sessionNominal (ssPipeline session))

awaitSession ∷ Session → Word64 → IO ()
awaitSession session wanted = atomically $ do
  now ← sessionNominal (ssPipeline session)
  unless (now == wanted) retry

-- | The pool, read in one transaction.
poolReading ∷ Session → IO PoolStatus
poolReading session = atomically (status (ssPool session))

-- | Block until the pool reads like this.
awaitPool ∷ Session → (PoolStatus → Bool) → IO ()
awaitPool session wanted = atomically $ do
  reading ← status (ssPool session)
  unless (wanted reading) retry

-- | What each lane's workspace is charged now.
lanesCharged ∷ Session → IO [Word64]
lanesCharged session = map laneReadingCharged . readingLanes <$> pipelineNow session
