-- | The host rig every graphics-owner example drives: the fake backend and the
-- scripted timer composed with the protected window host, over a journalling
-- seam and a counting clock, under the full application runner, on a bound
-- thread designated as the process main thread.
module Test.GLFW.Owner.Fixture.Rig
  ( Rig (..)
  , newRig
  , newRigWith
  , countingClock
  , ownerSettings
  , ownedHost
  , ownedHostWith
  , ownedHostHooked
  , ownedHostAt
  , Observer (..)
  , noObserver
  , ownedHostObserved
  , ownedHostBeforeBody
  , armedBody
  , armedFinally
  , publishAllFor
  , ownedHostCaught
  , ownedHostCaughtHooked
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM
  ( TVar
  , atomically
  , modifyTVar'
  , newTVarIO
  , readTVar
  , readTVarIO
  , retry
  , writeTVar
  )
import Control.Exception (SomeException, finally, mask, onException, throwIO, try)
import Control.Monad (forM_, void)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log (Logger)
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Time (MonotonicSource, scriptedSource)
import Hetoimasia.GLFW.Internal.Seam
  ( NativeCall (..)
  , Reporter
  , Seam
  , SeamScript (..)
  , asProcessMainThread
  , defaultScript
  , newSeam
  , seamCalls
  , seamSession
  )
import Hetoimasia.GLFW.Session (defaultSessionConfig)
import Hetoimasia.Runtime.GLFW
import qualified Hetoimasia.Runtime.GLFW.Internal as Private
import qualified Hetoimasia.Runtime.GLFW.Internal.Owner as Private
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Test.GLFW.Owner.Fixture.Fake (Fake, ScriptedTimer, fakeOperations, newFake, newScriptedTimer)
import Test.GLFW.Owner.Fixture.Journal (Note (..), Scene (..), note)
import Test.GLFW.Support (at, millis, quietLogger, windowNamed)

-- | A clock that advances one millisecond per reading and never runs out, so
-- an example that cannot predict how often the owner and the main thread each
-- read it still gets a monotonic, deterministic answer.
countingClock ∷ IO MonotonicSource
countingClock = do
  ticks ← newIORef (0 ∷ Integer)
  pure (scriptedSource (at . millis <$> atomicModifyIORef' ticks (\n → (n + 1, n))))

-- | A seam that journals its own destroy and terminate calls, records the
-- thread each native call was made from, and whose finite wait returns at once
-- so the main thread's housekeeping keeps turning.
--
-- Each empty-event post first runs whatever the cell holds, which is how an
-- example makes a wake report an error or raise. It still posts afterwards:
-- this wait ignores its bound, so the post stands in for the bound a real
-- finite wait would end by, and a failed wake never strands the main thread.
ownerSeam ∷ TVar [Note] → TVar (Reporter → IO ()) → IO (Seam, TVar [(ThreadId, NativeCall)])
ownerSeam journal waking = do
  threaded ← newTVarIO []
  posts ← newTVarIO (0 ∷ Int)
  held ← newIORef Nothing
  let recordFrom call = do
        caller ← myThreadId
        atomically (modifyTVar' threaded (<> [(caller, call)]))
  seam ←
    newSeam
      defaultScript
        { scriptDestroyWindow = \_ → do
            destroyed ← readIORef held >>= maybe (pure 0) (fmap latestDestroyed . seamCalls)
            note journal (WindowGone destroyed)
            recordFrom (DestroyWindow destroyed)
        , scriptTerminate = \_ → note journal SessionEnded >> recordFrom Terminate
        , scriptPollEvents = \_ → recordFrom PollEvents
        , -- The finite wait really waits, as a native one does, and the
          -- session's own internal wake is what ends it. That is what makes
          -- "the owner's publication woke the main thread" an observation
          -- rather than an assumption.
          scriptWaitEvents = \bound _ → do
            recordFrom (WaitEvents bound)
            atomically $
              readTVar posts >>= \pending →
                if pending <= 0 then retry else writeTVar posts (pending - 1)
        , scriptPostEmptyEvent = \reporter → do
            recordFrom PostEmptyEvent
            (readTVarIO waking >>= ($ reporter)) `finally` atomically (modifyTVar' posts (+ 1))
        , scriptCreateWindow = \_ → True <$ recordFrom (CreateWindow 0 0 (Text.pack "window"))
        }
  atomicModifyIORef' held (\_ → (Just seam, ()))
  pure (seam, threaded)

latestDestroyed ∷ [NativeCall] → Int
latestDestroyed calls = last (0 : [key | DestroyWindow key ← calls])

-- | A host configuration for these examples: one window, small budgets, and
-- the counting clock.
ownerSettings ∷ MonotonicSource → HostConfig
ownerSettings clock =
  (defaultHostConfig [windowNamed (Text.pack "owned")])
    { hostCommandCapacity = 8
    , hostCommandBudget = 3
    , hostEventBudget = 2
    , hostIdleWait = 0.01
    , hostClock = clock
    }

-- | Run a graphics-owner host under the full application runner, in the
-- seam's session, on a bound thread designated as the process main thread.
--
-- Every example uses it, because everything a main thread owes an attachment
-- happens on owner turns and nowhere else: this is the composition an
-- application really has.
ownedHost
  ∷ Seam
  → HostConfig
  → GraphicsOwnerConfig Scene
  → (WindowHost → GraphicsOwner Scene → RuntimeControl → IO a)
  → IO a
ownedHost = ownedHostWith quietLogger

-- | 'ownedHost' over a logger the example supplies, for the one example that
-- must observe the diagnostic an unverified destruction writes.
ownedHostWith
  ∷ Logger
  → Seam
  → HostConfig
  → GraphicsOwnerConfig Scene
  → (WindowHost → GraphicsOwner Scene → RuntimeControl → IO a)
  → IO a
ownedHostWith = ownedHostHooked Private.noHostHooks

-- | 'ownedHost' over the package's private host hooks.
--
-- `beforePublication` runs inside 'handOverGraphicsTarget''s own attachment,
-- after the construction has settled and before the service is published,
-- which is the one handoff an example cannot otherwise reach: the whole
-- sequence is masked, and the attachment itself runs on the main thread, so
-- there is no instant a helper could aim at from outside.
ownedHostHooked
  ∷ Private.HostHooks
  → Logger
  → Seam
  → HostConfig
  → GraphicsOwnerConfig Scene
  → (WindowHost → GraphicsOwner Scene → RuntimeControl → IO a)
  → IO a
ownedHostHooked hooks = ownedHostAt hooks (pure ())

-- | 'ownedHostHooked' with an action the run's startup callback performs (#612). That callback runs after the owner has started and
-- before the application's body, so it is where an example reaches the span between the start's return and the body's entry
-- (supervision, the quiescence guard and the runtime checks) that no host hook is part of.
ownedHostAt
  ∷ Private.HostHooks
  → IO ()
  → Logger
  → Seam
  → HostConfig
  → GraphicsOwnerConfig Scene
  → (WindowHost → GraphicsOwner Scene → RuntimeControl → IO a)
  → IO a
ownedHostAt hooks = ownedHostObserved hooks noObserver

-- | What an example observes of a run that the application never sees (#613): the owner the moment its handle is published to the
-- protected exit, which a start that is abandoned never returns, and the failure the run ends with, caught on the designated main
-- thread, where it still carries its context. An exception that crosses out of 'asProcessMainThread' arrives with none.
data Observer = Observer
  { observedOwner ∷ GraphicsOwner Scene → IO ()
  , observedFailure ∷ SomeException → IO ()
  }

noObserver ∷ Observer
noObserver = Observer (\_ → pure ()) (\_ → pure ())

-- | 'ownedHostAt' with an observer.
ownedHostObserved
  ∷ Private.HostHooks
  → Observer
  → IO ()
  → Logger
  → Seam
  → HostConfig
  → GraphicsOwnerConfig Scene
  → (WindowHost → GraphicsOwner Scene → RuntimeControl → IO a)
  → IO a
ownedHostObserved hooks observer startup logger seam config ownerConfig action =
  asProcessMainThread seam $
    ownedHostRun hooks (observedOwner observer) startup logger seam config ownerConfig action
      `onException'` observedFailure observer

-- | Run the action and, if it raises, tell the observer what it raised before raising it again unchanged.
onException' ∷ IO a → (SomeException → IO ()) → IO a
onException' action observe =
  try action >>= \case
    Right result → pure result
    Left failure → observe failure >> throwIO failure

-- | 'ownedHostWith' that runs an action on the main thread after the host is built and before the application's body begins (the
-- host's own 'beforeConsumer' hook), so an example can end a run during its startup (#593).
ownedHostBeforeBody
  ∷ IO ()
  → Logger
  → Seam
  → HostConfig
  → GraphicsOwnerConfig Scene
  → (WindowHost → GraphicsOwner Scene → RuntimeControl → IO a)
  → IO a
ownedHostBeforeBody beforeBody = ownedHostHooked Private.noHostHooks {Private.beforeConsumer = \_ → beforeBody}

-- | The body of a rig example under a rescue (#593). The example's scripted failing or gated backend behaviour (@arm@) is armed
-- only inside this body's first masked step, in the same step that registers the release that undoes it (@release@, run only
-- when the body ends exceptionally, before the host's drain), so no failing step, gated retirement or deferred releaser exists
-- before the rescue that can release it. The @cut@ hook is where an example ends the body to prove that: it is called with
-- 0 before the arming and with 1 once the arming and the release are registered; a fixture whose behaviour is reached only through an
-- attachment calls it with 2 once the first attachment exists.
armedBody ∷ (Int → IO ()) → IO () → IO () → IO a → IO a
armedBody cut arm release body = do
  cut 0
  mask $ \restore → do
    arm
    restore (cut 1 >> body) `onException` release

-- | 'armedBody' whose release also runs when the body returns: for a body that must leave nothing held on any exit (#593).
armedFinally ∷ (Int → IO ()) → IO () → IO () → IO a → IO a
armedFinally cut arm release body = do
  cut 0
  mask $ \restore → do
    arm
    restore (cut 1 >> body) `finally` release

-- | Publish every retirement fact for one attachment from the calling thread, if the host publishes completions and the owner holds
-- the attachment's acknowledgement, and do nothing otherwise. It blocks on nothing and raises nothing, and it is idempotent: the
-- rescue of an example whose protected drain waits for independent evidence the body would have published (#593).
publishAllFor ∷ WindowHost → GraphicsOwner Scene → AttachmentId → IO ()
publishAllFor host owner attachment = do
  acknowledgement ← atomically (ownerTargetAcknowledgement owner attachment)
  case (hostGraphicsPublisher host, acknowledgement) of
    (Just publisher, Just acknowledged) →
      forM_ allRetirementFacts $ \fact →
        void (publishCompletion publisher (completionNotice attachment acknowledged fact))
    _ → pure ()

-- | 'ownedHost', catching inside the seam's own bound thread.
--
-- Cleanup evidence lives in a failure's own context, and an exception that
-- crosses out of 'asProcessMainThread' arrives with none of it, so an example
-- that inspects what the exit retained beside its primary has to catch on
-- this side of that boundary.
ownedHostCaught
  ∷ Seam
  → HostConfig
  → GraphicsOwnerConfig Scene
  → (WindowHost → GraphicsOwner Scene → RuntimeControl → IO a)
  → IO (Either SomeException a)
ownedHostCaught = ownedHostCaughtHooked Private.noHostHooks

-- | 'ownedHostCaught' over the package's private host hooks (#612).
ownedHostCaughtHooked
  ∷ Private.HostHooks
  → Seam
  → HostConfig
  → GraphicsOwnerConfig Scene
  → (WindowHost → GraphicsOwner Scene → RuntimeControl → IO a)
  → IO (Either SomeException a)
ownedHostCaughtHooked hooks seam config ownerConfig action =
  asProcessMainThread seam (try (ownedHostRun hooks (\_ → pure ()) (pure ()) quietLogger seam config ownerConfig action))

-- | The composition itself, already on the designated main thread.
ownedHostRun
  ∷ Private.HostHooks
  → (GraphicsOwner Scene → IO ())
  → IO ()
  → Logger
  → Seam
  → HostConfig
  → GraphicsOwnerConfig Scene
  → (WindowHost → GraphicsOwner Scene → RuntimeControl → IO a)
  → IO a
ownedHostRun hooks observe startup logger seam config ownerConfig action =
    runGraphicsOwnerApplication
      (withLoggingLifetime logger)
      (Text.pack "owner-example")
      ( \_ use →
          Private.withGraphicsOwnerHostObserved
            hooks
            observe
            logger
            (seamSession seam defaultSessionConfig)
            config
            ownerConfig
            (\host owner → use (host, owner))
      )
      fst
      (\dependencies _ → startup >> pure dependencies)
      (\(host, owner) control → action host owner control)

-- | Everything an example needs to drive one owner.
data Rig = Rig
  { rigSeam ∷ !Seam
  , rigNative ∷ !(TVar [(ThreadId, NativeCall)])
  , rigJournal ∷ !(TVar [Note])
  , rigFake ∷ !Fake
  , rigTimer ∷ !ScriptedTimer
  , rigHostConfig ∷ !HostConfig
  , rigOwnerConfig ∷ !(GraphicsOwnerConfig Scene)
  , rigWake ∷ !(TVar (Reporter → IO ()))
    -- ^ What every later empty-event post does before it posts: nothing, until
    -- an example scripts a wake that reports an error or raises.
  }

newRig ∷ IO Rig
newRig = newRigWith id

newRigWith ∷ (GraphicsOwnerConfig Scene → GraphicsOwnerConfig Scene) → IO Rig
newRigWith adjust = do
  journal ← newTVarIO []
  waking ← newTVarIO (\_ → pure ())
  (seam, threaded) ← ownerSeam journal waking
  fake ← newFake journal
  (timer, injected) ← newScriptedTimer
  clock ← countingClock
  scene ← prepare (Scene 0)
  let ownerConfig =
        adjust
          (graphicsOwnerConfig (fakeOperations fake) scene)
            {ownerClockTimer = injected}
  pure (Rig seam threaded journal fake timer (ownerSettings clock) ownerConfig waking)
