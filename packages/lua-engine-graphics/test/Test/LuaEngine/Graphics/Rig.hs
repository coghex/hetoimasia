-- | What the lifecycle examples share: a backend over the fake owner, a recording sink that can hold
-- the pipeline's answer, and the bound every example runs under.
--
-- An example ends however it ends with every hold of the fake opened, so a failing example fails instead
-- of waiting for what is right to wait for, and then the rig checks what must hold of every example: no
-- native image, registration or open upload is left, and the backend's scope returned.
module Test.LuaEngine.Graphics.Rig
  ( -- * The rig
    Rig (..)
  , withRig
  , withRigUnchecked
  , withBackendOnRaw
  , bounded
  , leaked

    -- * The sink
  , Probe (..)
  , SinkEvent (..)
  , newProbe
  , probeSink
  , submit
  , level
  , awaitTerminal
  , awaitEvents
  , terminals
  , sinkEvents
  , Forked (..)
  , forkScope
  , assertBefore
  , gateReady
  , raiseFromReady
  , raiseFromTerminal
  , openReady
  , answerReady
  , delivered
  , awaitPhase
  , readingNow
  , awaitBackend
  ) where

import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , modifyTVar'
  , newTVarIO
  , readTVar
  , readTVarIO
  , retry
  , swapTVar
  , writeTVar
  )
import Control.Concurrent (ThreadId, forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, finally, throwIO, try)
import Data.List (findIndex)
import Data.IORef (newIORef, readIORef, writeIORef)
import Control.Monad (forM_, unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word64, Word8)
import Hetoimasia.LuaEngine.Graphics.Texture.Backend
import Hetoimasia.LuaEngine.Texture.Backend
import System.Environment (lookupEnv)
import System.Timeout (timeout)
import Text.Read (readMaybe)
import Test.HUnit.Lang (assertFailure)
import Test.LuaEngine.Graphics.Fake

-- | A backend over a fake owner, with the pipeline's port it hands out.
data Rig = Rig
  { rigFake ∷ !Fake
  , rigBackend ∷ !(Backend Int Int)
  , rigPort ∷ !TextureBackend
  }

-- | How long an example may take. It bounds a failure; it certifies nothing about retirement, which the
-- backend establishes from the owner's own facts. Fifteen seconds, or what @HETOIMASIA_EXAMPLE_BOUND_SECONDS@
-- names, which a deliberate mutation of the backend uses to see a negative control fail quickly.
bounded ∷ IO a → IO a
bounded action = do
  seconds ← exampleBound
  timeout (seconds * 1000000) action >>= \case
    Just value → pure value
    Nothing → assertFailure "the example did not finish within its bound"

-- | Run an example over a rig and check what must hold of every example after it.
withRig ∷ FakeConfig → (Rig → IO a) → IO a
withRig cfg body = do
  fake ← newFake cfg
  value ← withRigOver fake body
  problems ← atomically (leaked fake)
  unless (null problems) (assertFailure ("the example left native work behind: " <> Text.unpack (Text.intercalate "; " problems)))
  pure value

-- | The same without the leak check, for an example whose fake is made and checked by the example.
withRigUnchecked ∷ Fake → (Rig → IO a) → IO a
withRigUnchecked = withRigOver

withRigOver ∷ Fake → (Rig → IO a) → IO a
withRigOver fake body = do
  seen ← newIORef Nothing
  seconds ← exampleBound
  outcome ←
    timeout (seconds * 1000000) . withFakeOwner fake $
      withBackendOnRaw fake $ \rig → do
        writeIORef seen (Just rig)
        body rig `finally` openEveryHold fake
  case outcome of
    Just value → pure value
    Nothing → do
      lines' ← events fake
      reading ← readIORef seen >>= traverse readingNow
      assertFailure
        ( "the example did not finish within its bound; the fake recorded:\n  "
            <> Text.unpack (Text.intercalate "\n  " lines')
            <> "\nthe backend read: "
            <> show reading
        )

-- | A backend over this fake, with no owner thread, no bound and no hold released: the example runs the
-- fake's owner and manages its holds itself.
withBackendOnRaw ∷ Fake → (Rig → IO a) → IO a
withBackendOnRaw fake body =
  withBackend (fakePort fake) $ \backend → body (Rig fake backend (textureBackend backend))

openEveryHold ∷ Fake → IO ()
openEveryHold fake = forM_ [minBound .. maxBound] (release fake)

-- | What a finished example must not have left.
leaked ∷ Fake → STM [Text]
leaked fake = do
  reading ← readFake fake
  pure $
    [ "native images alive: " <> tshow (readingImagesAlive reading) | readingImagesAlive reading /= 0 ]
      <> [ "registrations alive: " <> tshow (readingRegistrations reading) | readingRegistrations reading /= 0 ]
      <> [ "uploads open: " <> tshow (readingUploadsOpen reading) | readingUploadsOpen reading /= 0 ]
      <> [ "actions queued: " <> tshow (readingActsQueued reading + readingReleasesQueued reading) | readingActsQueued reading + readingReleasesQueued reading /= 0 ]

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show

-- The sink --------------------------------------------------------------------------------------------------

data SinkEvent
  = SeReady !Word64
  | -- | 'sinkReady' was answered 'SinkLate': the pipeline took nothing.
    SeReadyLate !Word64
  | SeFailed !Text
  | SeWithdrawn
  | SeBuffersRetired
  deriving (Eq, Show)

-- | What the pipeline's sink saw, and what it answers.
data Probe = Probe
  { probeEvents ∷ !(TVar [SinkEvent])
  , probeTexture ∷ !(TVar (Maybe BackendTexture))
  , probeGate ∷ !(TVar Bool)
    -- ^ While set, 'sinkReady' does not return.
  , probeAnswer ∷ !(TVar SinkAnswer)
  , probeReadyRaises ∷ !(TVar (Maybe SomeException))
    -- ^ Raised by 'sinkReady' after it recorded the texture.
  , probeTerminalRaises ∷ !(TVar (Maybe SomeException))
    -- ^ Raised by the first terminal call (failed or withdrawn), after it recorded the event.
  }

newProbe ∷ IO Probe
newProbe = Probe <$> newTVarIO [] <*> newTVarIO Nothing <*> newTVarIO False <*> newTVarIO SinkTaken <*> newTVarIO Nothing <*> newTVarIO Nothing

-- | The sink over this probe, whose every call is also written into the fake's event log.
probeSink ∷ Fake → Probe → UploadSink
probeSink fake probe =
  UploadSink
    { sinkReady = \texture → do
        atomically (writeTVar (probeTexture probe) (Just texture))
        noteEvent fake "sink ready"
        atomically (readTVar (probeGate probe) >>= \gated → if gated then retry else pure ())
        answer ← readTVarIO (probeAnswer probe)
        atomically (modifyTVar' (probeEvents probe) (<> [(if answer == SinkLate then SeReadyLate else SeReady) (textureIdentity texture)]))
        raising ← atomically (swapTVar (probeReadyRaises probe) Nothing)
        forM_ raising throwIO
        pure answer
    , sinkFailed = \(UploadFailure why) → note "sink failed" (SeFailed why) <* raiseTerminal
    , sinkWithdrawn = note "sink withdrawn" SeWithdrawn <* raiseTerminal
    , sinkBuffersRetired = note "sink buffers retired" SeBuffersRetired
    }
  where
    raiseTerminal = atomically (swapTVar (probeTerminalRaises probe) Nothing) >>= \raising → forM_ raising throwIO
    note line event = do
      noteEvent fake line
      atomically (modifyTVar' (probeEvents probe) (<> [event]))
      readTVarIO (probeAnswer probe) >>= \answer → pure (if answer == SinkLate then SinkLate else SinkTaken)

-- | A scope run on a thread of its own, for an example that must act while the scope is still inside its exit.
data Forked a = Forked
  { forkedThread ∷ !ThreadId
  , forkedJoin ∷ IO (Either SomeException a)
    -- ^ Waits for the scope's outcome, and then for the thread to have ended.
  }

forkScope ∷ IO a → IO (Forked a)
forkScope scope = do
  result ← newEmptyMVar
  done ← newEmptyMVar
  thread ← forkIO ((try @SomeException scope >>= putMVar result) `finally` putMVar done ())
  pure Forked {forkedThread = thread, forkedJoin = takeMVar result <* takeMVar done}

-- | The first event of the fake's log with this prefix came before the first with that one: an order the log
-- records, not an instant a thread happened to be observed at.
assertBefore ∷ Fake → Text → Text → IO ()
assertBefore fake earlier later = do
  seen ← events fake
  let at prefix = findIndex (Text.isPrefixOf prefix) seen
  case (at earlier, at later) of
    (Just first, Just second) | first < second → pure ()
    found → assertFailure ("expected '" <> Text.unpack earlier <> "' before '" <> Text.unpack later <> "', the log read " <> show found <> ": " <> show seen)

-- | Make the next 'sinkReady' raise this once it has recorded the texture.
raiseFromReady ∷ Probe → SomeException → IO ()
raiseFromReady probe = atomically . writeTVar (probeReadyRaises probe) . Just

-- | Make the next terminal call raise this once it has recorded its event.
raiseFromTerminal ∷ Probe → SomeException → IO ()
raiseFromTerminal probe = atomically . writeTVar (probeTerminalRaises probe) . Just

-- | Hold the next 'sinkReady' inside the call.
gateReady ∷ Probe → IO ()
gateReady probe = atomically (writeTVar (probeGate probe) True)

openReady ∷ Probe → IO ()
openReady probe = atomically (writeTVar (probeGate probe) False)

-- | What 'sinkReady' answers: 'SinkTaken', or 'SinkLate' for a pipeline that ended the job.
answerReady ∷ Probe → SinkAnswer → IO ()
answerReady probe = atomically . writeTVar (probeAnswer probe)

-- | The texture 'sinkReady' was offered, waiting for the call.
delivered ∷ Probe → IO BackendTexture
delivered probe = atomically (readTVar (probeTexture probe) >>= maybe retry pure)

sinkEvents ∷ Probe → IO [SinkEvent]
sinkEvents = readTVarIO . probeEvents

-- | The terminal events so far: ready, failed or withdrawn.
terminals ∷ Probe → IO [SinkEvent]
terminals probe = filter terminal <$> sinkEvents probe
  where
    terminal = \case SeBuffersRetired → False; SeReadyLate _ → False; _ → True

-- | Block until a terminal event arrived, and answer it.
awaitTerminal ∷ Probe → IO SinkEvent
awaitTerminal probe = atomically $ do
  found ← filter (\e → e /= SeBuffersRetired) <$> readTVar (probeEvents probe)
  case found of
    event : _ → pure event
    [] → retry

-- | Block until the sink has seen events satisfying this.
awaitEvents ∷ Probe → ([SinkEvent] → Bool) → IO ()
awaitEvents probe wanted = atomically $ do
  seen ← readTVar (probeEvents probe)
  unless (wanted seen) retry

-- | Accept one level of this extent whose alpha is this, and answer the work and the level's bytes.
submit ∷ Rig → Probe → Word32 → Word32 → Word8 → IO UploadWork
submit rig probe width height alpha =
  backendUpload (rigPort rig) (Upload "test:a.png" width height (level width height alpha)) (probeSink (rigFake rig) probe)

-- | A tightly packed RGBA8 level whose every texel has this alpha.
level ∷ Word32 → Word32 → Word8 → ByteString
level width height alpha = ByteString.concat (replicate (fromIntegral (width * height)) (ByteString.pack [10, 20, 30, alpha]))

readingNow ∷ Rig → IO BackendReading
readingNow rig = atomically (readBackend (rigBackend rig))

-- | Block until the backend's only job (or the first) is in this phase.
awaitPhase ∷ Rig → Text → IO ()
awaitPhase rig wanted = atomically $ do
  reading ← readBackend (rigBackend rig)
  unless (wanted `elem` readingJobPhases reading) retry

-- | Block until the backend reads like this.
awaitBackend ∷ Rig → (BackendReading → Bool) → IO ()
awaitBackend rig wanted = atomically $ do
  reading ← readBackend (rigBackend rig)
  unless (wanted reading) retry

exampleBound :: IO Int
exampleBound = maybe 15 id . (>>= readMaybe) <$> lookupEnv "HETOIMASIA_EXAMPLE_BOUND_SECONDS"
