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
  , ownedHostCaught
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM
  ( TVar
  , atomically
  , modifyTVar'
  , newTVarIO
  , readTVar
  , retry
  , writeTVar
  )
import Control.Exception (SomeException, try)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log (Logger)
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Time (MonotonicSource, scriptedSource)
import Hetoimasia.GLFW.Internal.Seam
  ( NativeCall (..)
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
ownerSeam ∷ TVar [Note] → IO (Seam, TVar [(ThreadId, NativeCall)])
ownerSeam journal = do
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
        , scriptPostEmptyEvent = \_ → do
            recordFrom PostEmptyEvent
            atomically (modifyTVar' posts (+ 1))
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
ownedHostHooked hooks logger seam config ownerConfig action =
  asProcessMainThread seam (ownedHostRun hooks logger seam config ownerConfig action)

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
ownedHostCaught seam config ownerConfig action =
  asProcessMainThread seam (try (ownedHostRun Private.noHostHooks quietLogger seam config ownerConfig action))

-- | The composition itself, already on the designated main thread.
ownedHostRun
  ∷ Private.HostHooks
  → Logger
  → Seam
  → HostConfig
  → GraphicsOwnerConfig Scene
  → (WindowHost → GraphicsOwner Scene → RuntimeControl → IO a)
  → IO a
ownedHostRun hooks logger seam config ownerConfig action =
    runGraphicsOwnerApplication
      (withLoggingLifetime logger)
      (Text.pack "owner-example")
      ( \_ use →
          Private.withGraphicsOwnerHostWith
            hooks
            logger
            (seamSession seam defaultSessionConfig)
            config
            ownerConfig
            (\host owner → use (host, owner))
      )
      fst
      (\dependencies _ → pure dependencies)
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
  }

newRig ∷ IO Rig
newRig = newRigWith id

newRigWith ∷ (GraphicsOwnerConfig Scene → GraphicsOwnerConfig Scene) → IO Rig
newRigWith adjust = do
  journal ← newTVarIO []
  (seam, threaded) ← ownerSeam journal
  fake ← newFake journal
  (timer, injected) ← newScriptedTimer
  clock ← countingClock
  scene ← prepare (Scene 0)
  let ownerConfig =
        adjust
          (graphicsOwnerConfig (fakeOperations fake) scene)
            {ownerClockTimer = injected}
  pure (Rig seam threaded journal fake timer (ownerSettings clock) ownerConfig)
