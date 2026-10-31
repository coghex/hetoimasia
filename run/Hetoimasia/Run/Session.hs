-- | The session of @hetoimasia run@: the services a prepared folder is run with, composed once at their proper
-- scope, and the one session coordinator run over them (LFE-22 requirements 3 to 5).
--
-- = What is composed, and in what order
--
-- Outermost first; each scope borrows only what encloses it, and each ends before what it borrows:
--
-- > prepared root and inventory                  (the caller's: "Hetoimasia.Run.Boot")
-- >   the session's pool of verified reads        two I/O workers, once for the session
-- >     the texture pipeline                      one decode worker and two lanes, once for the session
-- >       supervision and the Lua runtime
-- >         the graphics mount                    the window provider and the graphics injection
-- >           the authored output sinks
-- >             'runSession'                      the roles' VMs, never one per request
--
-- The pipeline, the window provider and everything under them are made before the session and closed after it;
-- the session never closes them. Each VM keeps its own module cache and each instance its own request and
-- resource authority: nothing here is shared between the two roles but the services above.
--
-- = Stop, failure and signals
--
-- A 'SessionLink' is how the services that exist before the session handle (the window provider's stop and fatal
-- endpoints) reach it afterwards: whichever of the two came first, a stop or a terminal failure recorded before
-- the session was bound is applied the moment it is. A first signal arrives as the caller's @stop@ transaction;
-- a forwarder thread turns it into 'StopInterrupt' on the session, idempotently, and is ended with the session.
--
-- = The graphics seam
--
-- 'Graphics' is what the production command supplies from the main thread's native owner. A composition with
-- 'Nothing' has no graphics call, handle or request kind; it exists so the content, role, failure and exit rules
-- are examined without a native session. The command itself always passes the production graphics: there is no
-- option, variable or fallback that selects anything else.
module Hetoimasia.Run.Session
  ( Environment (..)
  , productionEnvironment
  , Graphics (..)
  , SessionLink
  , newSessionLink
  , linkStop
  , linkFailure
  , newSessionLinkEndingWith
  , awaitDiagnostics
  , joinDiagnostics
  , noteLinkedDiagnostics
  , ioQueueSlots
  , textureJobs
  , runPrepared
  ) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , check
  , newTVarIO
  , readTVar
  , writeTVar
  )
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, finally, mask_, rethrowIO, toException)
import Control.Exception.Context (emptyExceptionContext)
import Control.Monad (forM_, join, void, when)
import Data.Foldable (traverse_)
import Data.IORef (newIORef, readIORef, writeIORef)
import Hetoimasia.Content.ReadPool (poolSpec, withReadPool)
import Hetoimasia.Foundation.Time (MonotonicSource, monotonicSource)
import Hetoimasia.LuaEngine.Facade (GraphicsInjection, OutputSink, withOutput)
import Hetoimasia.LuaEngine.Profile (Count (Count), CountLimit (IoWorkers), countLimit)
import Hetoimasia.LuaEngine.Session
  ( DiagEvidence (..)
  , RoleFailure
  , Session
  , SessionOutcome (outDiagnostics)
  , SessionSpec (..)
  , StopKind (StopInterrupt)
  , latchTerminalFailure
  , noHarness
  , requestStop
  , runSession
  , sessionDiagnosticsEnded
  , sessionOutcomeNow
  )
import Hetoimasia.LuaEngine.Texture
  ( TexturePipeline
  , specIoWorkers
  , textureSpec
  , withTexturePipeline
  )
import Hetoimasia.LuaEngine.Texture.Backend (TextureBackend)
import Hetoimasia.Run.Boot (Prepared (..))
import Hetoimasia.Run.Output (authoredSinks)
import qualified Data.Text as Text
import Hetoimasia.Run.Output (reportText)
import Hetoimasia.Run.Settle (notePathFailure, rememberingInterruption)
import Hetoimasia.Runtime.Logging (LoggingLifetime, lifetimeLogger)
import Hetoimasia.Runtime.Supervision (withSupervision)
import Hetoimasia.Scripting.Lua.Runtime (newLuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduler (TimerBackend, systemTimerBackend)

-- | The inputs of a composition that are not part of the folder: the clock the owners, facades and pacing share,
-- what sleeps, and the two authored sinks (stdout first). The production values come from
-- 'productionEnvironment'; the suite injects a clock and timer it can drive.
data Environment = Environment
  { envClock ∷ !MonotonicSource
  , envTimer ∷ !TimerBackend
  , envStdout ∷ !OutputSink
  , envStderr ∷ !OutputSink
  }

-- | The process's own clock, timer and streams.
productionEnvironment ∷ Environment
productionEnvironment = Environment monotonicSource systemTimerBackend out err
  where
    (out, err) = authoredSinks

-- | The accepted-work records of the session's texture pipeline, and the slots of the pool its reads queue in. Both
-- are the M1 profile's sixteen textures of the one UI instance a role can hold (P-74 part 3), and the module
-- coordinator's reads share the pool's slots with the textures'.
textureJobs, ioQueueSlots ∷ Int
textureJobs = 16
ioQueueSlots = 16

-- | What the main thread's native owner supplies: the backend the pipeline is composed over, and a scope that,
-- given the pipeline and the link to the session, makes the window provider and the graphics injection and runs a
-- body inside them. The mount ends every window before the pipeline's scope drains, as the adapter requires.
data Graphics = Graphics
  { graphicsTextureBackend ∷ !TextureBackend
  , graphicsMount ∷ ∀ a. TexturePipeline → SessionLink → (GraphicsInjection → IO a) → IO a
  }

-- | The session handle, reachable before it exists.
data SessionLink = SessionLink
  { linkSession ∷ !(TVar (Maybe Session))
  , linkPendingStop ∷ !(TVar (Maybe StopKind))
  , linkPendingFailures ∷ !(TVar [RoleFailure])
  , linkEnded ∷ !(TVar (STM Bool))
  -- ^ Whether the session's diagnostics writer (and the helper that cancels it) has ended: true while no session
  -- is bound, because then nothing writes.
  }

newSessionLink ∷ IO SessionLink
newSessionLink = newSessionLinkEndingWith (pure True)

-- | A link whose diagnostics writer's end is read from this, for a suite that gates it.
newSessionLinkEndingWith ∷ STM Bool → IO SessionLink
newSessionLinkEndingWith ended = SessionLink <$> newTVarIO Nothing <*> newTVarIO Nothing <*> newTVarIO [] <*> newTVarIO ended

-- | Wait until the session's diagnostics writer has ended. The session permits it to outlive 'runSession', and it
-- borrows the logger, so whoever owns the logger joins it before the logger is released. The wait is interruptible;
-- a cancellation meanwhile is remembered and raised after the writer has ended.
awaitDiagnostics ∷ SessionLink → IO ()
awaitDiagnostics link = joinDiagnostics link >>= traverse_ rethrowIO

-- | 'awaitDiagnostics' that /answers/ a remembered cancellation instead of raising it, for a caller that has a failure
-- of its own to keep beside it before it raises either.
joinDiagnostics ∷ SessionLink → IO (Maybe (ExceptionWithContext SomeException))
joinDiagnostics link = rememberingInterruption (atomically (join (readTVar (linkEnded link)) >>= check))

-- | Ask the session to stop; recorded and applied on binding when the session does not exist yet.
linkStop ∷ SessionLink → StopKind → IO ()
linkStop link kind = do
  bound ← atomically $ do
    found ← readTVar (linkSession link)
    case found of
      Just _ → pure found
      Nothing → do
        writeTVar (linkPendingStop link) (Just kind)
        pure Nothing
  forM_ bound (`requestStop` kind)

-- | Latch a terminal failure; recorded and applied on binding when the session does not exist yet.
linkFailure ∷ SessionLink → RoleFailure → IO ()
linkFailure link failure = do
  bound ← atomically $ do
    found ← readTVar (linkSession link)
    case found of
      Just _ → pure found
      Nothing → do
        pending ← readTVar (linkPendingFailures link)
        writeTVar (linkPendingFailures link) (pending <> [failure])
        pure Nothing
  forM_ bound (\session → void (latchTerminalFailure session failure))

-- | Bind the handle and apply what was recorded before it existed.
bindLink ∷ SessionLink → Session → IO ()
bindLink link session = do
  (stop, failures) ← atomically $ do
    writeTVar (linkSession link) (Just session)
    writeTVar (linkEnded link) (sessionDiagnosticsEnded session)
    (,) <$> readTVar (linkPendingStop link) <*> readTVar (linkPendingFailures link)
  forM_ failures (void . latchTerminalFailure session)
  forM_ stop (requestStop session)

-- | Run the prepared folder as one session, to the actual retirement of every role. This runs on the thread
-- that owns the supervision it creates, and returns only once the session has retired or failed to; whatever the
-- session or a scope raises propagates after every scope has unwound.
--
-- The @link@ is the caller's, so a service made before the session can stop it or latch its failure; the
-- @hook@ receives the session handle before any VM exists and must not block: it is how a caller wires a
-- further stop, such as the suite's, to the session.
runPrepared
  ∷ Environment
  → LoggingLifetime
  → STM Bool
  → SessionLink
  → Prepared
  → Maybe Graphics
  → (Session → IO ())
  → IO SessionOutcome
runPrepared environment lifetime stop link prepared graphics hook =
  case poolSpec ioWorkers ioQueueSlots of
    Left refusal → ioError (userError ("the read pool was refused: " <> show refusal))
    Right pool →
      withReadPool pool (preparedInventory prepared) (preparedRoot prepared) $ \readPool →
        case graphics of
          Nothing → compose readPool Nothing
          Just production →
            case textureSpec profile textureJobs of
              Left refusal → ioError (userError ("the texture pipeline was refused: " <> show refusal))
              Right spec
                | specIoWorkers spec /= ioWorkers → ioError (userError "the pipeline and the pool disagree on the I/O workers")
                | otherwise →
                    withTexturePipeline spec (graphicsTextureBackend production) readPool (preparedInventory prepared) $ \pipeline →
                      graphicsMount production pipeline link $ \injection →
                        compose readPool (Just injection)
  where
    profile = preparedProfile prepared
    Count ioWorkerCount = countLimit profile IoWorkers
    ioWorkers = fromIntegral ioWorkerCount
    logger = lifetimeLogger lifetime

    compose readPool injection =
      withSupervision lifetime $ \control → do
        runtime ← newLuaRuntime control
        withOutput (envStdout environment) (envStderr environment) $ \output → do
          forwarder ← newIORef Nothing
          let spec =
                SessionSpec
                  { sxProfile = profile
                  , sxCheckpoint = preparedCheckpoint prepared
                  , sxInventory = preparedInventory prepared
                  , sxPool = readPool
                  , sxLogger = logger
                  , sxOutput = output
                  , sxClock = envClock environment
                  , sxTimer = envTimer environment
                  , sxRuntime = runtime
                  , sxControl = control
                  , sxHarness = noHarness
                  , sxGraphics = injection
                  }
              -- The handle is bound before any VM exists; the callback never blocks.
              callback session = do
                bindLink link session
                hook session
                -- Created and tracked in one masked step, so the forwarder is always ended below.
                mask_ $ do
                  thread ← forkIO (atomically (stop >>= check) >> requestStop session StopInterrupt)
                  writeIORef forwarder (Just thread)
              endForwarder = readIORef forwarder >>= mapM_ killThread
          -- The session's refused diagnostics are recorded here, on a return and on an exception alike, while every
          -- scope the session used is still open: the handle was bound to the link before any VM existed, and its
          -- state holds what its writer has counted, whether or not 'runSession' answered. No cleanup that fails
          -- later, and no failure that 'runSession' itself raises, can come before the record.
          runSession spec callback `finally` (noteLinkedDiagnostics lifetime link >> endForwarder)

-- | Record what the linked session's diagnostics writer has refused so far, if a session is bound: nonblocking, and
-- it answers whether or not the session ended well. Safe to call from a protected finalization.
noteLinkedDiagnostics ∷ LoggingLifetime → SessionLink → IO ()
noteLinkedDiagnostics lifetime link =
  atomically (readTVar (linkSession link) >>= traverse sessionOutcomeNow)
    >>= traverse_ (noteSessionDiagnostics lifetime)

-- | Carry the session's own diagnostic-sink failures into the logging lifetime. The session's writer counts the
-- writes its sink refused and returns them as data in the outcome; they raise nothing. Left there, the lifetime
-- would finish normally and flush the very sink that failed. Recording the first of them as a failed report makes
-- the lifetime skip that flush and the launcher write nothing more through the path. A session that lost nothing
-- records nothing.
noteSessionDiagnostics ∷ LoggingLifetime → SessionOutcome → IO ()
noteSessionDiagnostics lifetime outcome = do
  let evidence = outDiagnostics outcome
  when (deSinkFailures evidence > 0) $
    notePathFailure lifetime . ExceptionWithContext emptyExceptionContext . toException . userError . Text.unpack . reportText $
      "the session's diagnostics could not be written (" <> Text.pack (show (deSinkFailures evidence)) <> " refused): " <> Text.intercalate "; " (deSinkFirst evidence)
