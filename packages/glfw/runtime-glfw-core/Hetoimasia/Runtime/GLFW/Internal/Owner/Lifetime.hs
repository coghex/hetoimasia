-- | The graphics owner's protected lifetime: the additive protected-host
-- constructors that compose one owner with the window host, the runner over
-- them, and the supervision sentinel.
--
-- It runs on the main thread, except the sentinel, which is one ordinary
-- supervised service in the application's worker group. It owns no state of
-- its own: the owner's worker group is scoped here, the host's lifetime is the
-- host's, and the two are joined only through the protected exit's two
-- interposition points, so their ordering stays visible at this composition.
-- Host attachment retirement stays the host's, and whole-owner destruction and
-- join stay the owner's, in "Hetoimasia.Runtime.GLFW.Internal.Owner.Exit".
--
-- = The exit, which is D-33's
--
-- 'withGraphicsOwnerHost' composes the owner with the protected host lifetime
-- so that a whole-session exit runs in this order:
--
-- 1. quiescence closes the host's admission — commands, demand, input, and new
--    graphics use — and then the owner's own lifetime port;
-- 2. ordinary application workers stop and drain, which is the runtime's own
--    ordering and touches the owner's group not at all;
-- 3. the owner stays alive and retires each target and then itself through its
--    injected operations, publishing each certified fact through the host's
--    existing completion publisher;
-- 4. the main-thread protected boundary services bounded native housekeeping
--    through the host's own retirement environment while it awaits verified
--    retirement. It offers each attachment an opportunity that /waits/ and
--    performs no owner work, and it validates each exact attachment's terminal
--    evidence rather than the owner's completion;
-- 5. once the injected whole-owner destruction has returned its evidence, and
--    only then, the boundary joins the owner;
-- 6. the host's windows, session, and parents unwind.
--
-- An individual close or detach is not that: 'releaseGraphicsTarget' retires
-- one target, the owner publishes that target's exact evidence, the main
-- thread acknowledges it and its window is released, and the owner and every
-- other target stay live. Only a whole-host exit requires the final join.
module Hetoimasia.Runtime.GLFW.Internal.Owner.Lifetime
  ( withGraphicsOwnerHost
  , withGraphicsOwnerHostIn
  , withGraphicsOwnerHostWith
  , runGraphicsOwnerApplication
  , superviseGraphicsOwner
  ) where

import Control.Concurrent.STM (atomically, check, readTVar, writeTVar)
import Control.Exception (mask_, rethrowIO)
import Control.Monad (when)
import Data.Foldable (traverse_)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Maybe (isJust)
import Data.Text (Text)
import Hetoimasia.Foundation.Log (Logger)
import Hetoimasia.Foundation.Recovery (Disposition (Required))
import Hetoimasia.Foundation.Resource (Scoped)
import Hetoimasia.Foundation.Worker (requestStop, stopRequested, withWorkerGroup, workerDefinition)
import Hetoimasia.GLFW.Session (Session)
import Hetoimasia.Runtime.GLFW.Internal.Host.Config (HostConfig)
import Hetoimasia.Runtime.GLFW.Internal.Host.Lifetime
  ( ProtectedExit (..)
  , runProtectedWindowApplication
  , withProtectedWindowHostOver
  )
import Hetoimasia.Runtime.GLFW.Internal.Host.State (HostHooks (..), WindowHost, noHostHooks)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Config (GraphicsOwnerConfig (..), graphicsOwnerComponent)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Exit (finishOwnerExit)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Handoff (closeOwnerPublications)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Start (startGraphicsOwner)
import Hetoimasia.Runtime.GLFW.Internal.Owner.State (GraphicsOwner (..), Latched (latchedFailure))
import Hetoimasia.Runtime.Logging (LoggingLifetime)
import Hetoimasia.Runtime.Supervision
  ( Recognition (Unrecognized)
  , Role (Service)
  , RuntimeControl
  , SupervisedStart
  , WorkerPolicy (..)
  , startSupervised
  )

-- | 'Hetoimasia.Runtime.GLFW.withProtectedWindowHost' with one supervised
-- graphics owner beside it.
--
-- Every existing constructor keeps its signature and its behaviour; this one
-- is additive and takes the owner's injected operations. See the module header
-- for the exit order, which is D-33's.
withGraphicsOwnerHost
  ∷ Logger
  → HostConfig
  → GraphicsOwnerConfig scene
  → (WindowHost → GraphicsOwner scene → IO r)
  → IO r
withGraphicsOwnerHost logger = withGraphicsOwnerHostOver logger Nothing

-- | 'withGraphicsOwnerHost' over a session scope the caller supplies, such as
-- a test seam's session.
withGraphicsOwnerHostIn
  ∷ Logger
  → Scoped Session
  → HostConfig
  → GraphicsOwnerConfig scene
  → (WindowHost → GraphicsOwner scene → IO r)
  → IO r
withGraphicsOwnerHostIn logger sessionScope = withGraphicsOwnerHostOver logger (Just sessionScope)

-- | 'withGraphicsOwnerHostIn' with the private examples' host hooks.
--
-- It is available only here, in the private @runtime-glfw-core@ sublibrary:
-- no public module exports it, and nothing in production calls it. The
-- examples that must deliver a cancellation, or a quiescence, at exactly the
-- handoff between an attachment's construction and its publication have no
-- other way to reach that instant, and asserting what the boundary does there
-- is worth more than the seam costs.
withGraphicsOwnerHostWith
  ∷ HostHooks
  → Logger
  → Scoped Session
  → HostConfig
  → GraphicsOwnerConfig scene
  → (WindowHost → GraphicsOwner scene → IO r)
  → IO r
withGraphicsOwnerHostWith hooks logger sessionScope =
  withGraphicsOwnerHostAll hooks logger (Just sessionScope)

withGraphicsOwnerHostOver
  ∷ Logger
  → Maybe (Scoped Session)
  → HostConfig
  → GraphicsOwnerConfig scene
  → (WindowHost → GraphicsOwner scene → IO r)
  → IO r
withGraphicsOwnerHostOver = withGraphicsOwnerHostAll noHostHooks

withGraphicsOwnerHostAll
  ∷ HostHooks
  → Logger
  → Maybe (Scoped Session)
  → HostConfig
  → GraphicsOwnerConfig scene
  → (WindowHost → GraphicsOwner scene → IO r)
  → IO r
withGraphicsOwnerHostAll hooks logger sessionScope config ownerConfig use = do
  -- The exit runs after the consumer has returned, so it reads the owner from
  -- a cell the consumer filled rather than from a value it could be given. An
  -- exit that finds none is a host whose owner never started, which still
  -- quiesces, drains, and unwinds exactly as an owner-less protected host does.
  pending ← newIORef Nothing
  let exit =
        ProtectedExit
          { exitBeforeDrain = \_ _ → readIORef pending >>= traverse_ beginOwnerExit
          , exitAfterDrain = \host restore → readIORef pending >>= traverse_ (finishOwnerExit (afterDestructionSnapshot hooks) restore logger host)
          }
  -- The group's own scope sits outside the protected host lifetime
  -- deliberately: D-33 forbids an automatic join that could run before the
  -- main thread has serviced retirement, and the exit's own
  -- 'closeWorkerGroup' — after verified destruction and before any window is
  -- released — is the join that matters. By the time this scope ends the group
  -- has already drained, so its automatic join finds it settled.
  withWorkerGroup $ \group →
    withProtectedWindowHostOver hooks exit logger sessionScope config $ \host → do
      owner ← startGraphicsOwner group host (afterOwnerOperation hooks) ownerConfig (writeIORef pending . Just)
      use host owner

-- | 'Hetoimasia.Runtime.GLFW.runProtectedWindowApplication' over a host that
-- owns a graphics owner.
--
-- Every step keeps the runner's order, thread, and labels. The application's
-- own quiescence still runs before the ordinary worker drain, supervision
-- still drains the ordinary group, and the owner's group is untouched by
-- either: its exit is the protected boundary's, in D-33's order.
runGraphicsOwnerApplication
  ∷ (∀ r. (LoggingLifetime → IO r) → IO r)
  → Text
  → (LoggingLifetime → (∀ r. (dependencies → IO r) → IO r))
  → (dependencies → WindowHost)
  → (dependencies → RuntimeControl → IO services)
  → (services → RuntimeControl → IO a)
  → IO a
runGraphicsOwnerApplication = runProtectedWindowApplication

-- | Register the sentinel that makes a terminal owner failure visible at the
-- application's own supervision checkpoints.
--
-- The owner's worker group is the component's, not the application's, so
-- supervision observes nothing of it on its own: a separate group provides no
-- connection at all. This registers one ordinary supervised service in the
-- application's group whose whole job is to wait on the owner's fatal latch
-- and fail with what it holds. A failure latched /before/ this ran — during
-- the owner's startup, before the application even reached its own startup
-- callback — is therefore seen the moment the sentinel is registered, because
-- the latch is durable and the sentinel reads it rather than an event it
-- might have missed.
--
-- It waits on a latch and nothing else, so it cannot delay retirement: the
-- owner keeps retiring while the application's checkpoint raises.
superviseGraphicsOwner ∷ RuntimeControl → GraphicsOwner scene → IO (SupervisedStart ())
superviseGraphicsOwner control owner = startSupervised control policy definition
  where
    policy =
      WorkerPolicy
        { policyRole = Service
        , policyDisposition = Required
        , policyComponent = graphicsOwnerComponent
        , policyClassifier = \_ → pure Unrecognized
        }
    definition =
      workerDefinition
        (ownerLabel (ownerSettings owner) <> ".supervision")
        (\_ → pure ())
        ( \token () → mask_ $ do
            -- The wait is the interruptible part, and it is interruptible on
            -- purpose: a sentinel cancelled before it has taken anything has
            -- delivered nothing, records nothing, and the exit reports the
            -- failure in full.
            latched ← atomically $ do
              held ← readTVar (ownerLatch owner)
              stopping ← stopRequested token
              check (isJust held || stopping)
              -- Recorded in the same transaction that takes it, so the exit
              -- can never read a latch this sentinel is about to raise and
              -- conclude that nobody has.
              when (isJust held) (writeTVar (ownerDelivered owner) True)
              pure (latchedFailure <$> held)
            -- Masked from that commit through the raise, so the record and
            -- the delivery it promises cannot come apart. Were a cancellation
            -- able to land between them, the sentinel would end without ever
            -- publishing the failure while the exit, seeing the record,
            -- suppressed it — and the owner's failure would be reported by
            -- nobody at all.
            traverse_ rethrowIO latched
        )

-- | Close the owner's ordinary admission and ask it to stop.
--
-- The order matters: the host's own quiescence has already closed attachment
-- admission, so nothing can reserve a port slot after this closes the port,
-- and an attachment that got past admission always found the port open.
beginOwnerExit ∷ GraphicsOwner scene → IO ()
beginOwnerExit owner = atomically $ do
  closeOwnerPublications (ownerHandoff' owner)
  requestStop (ownerWorkerHandle owner)
