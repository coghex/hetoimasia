-- | The protected host lifetime: a host that owns attachment retirement state,
-- lent to one consumer, whose exit retires every attachment before a window,
-- the session, or a parent is released.
--
-- It runs on the process main thread, the session's owner, from construction
-- through the consumer to the exit. The retirement state it issues is the
-- host's, in "Hetoimasia.Runtime.GLFW.Internal.Host.State", and its drain is
-- "Hetoimasia.Runtime.GLFW.Internal.Retirement"'s; what this module owns is
-- the order of the exit and how its failures settle. The exit runs no
-- application hook and no supervisor checkpoint: the only work it lends the
-- drain is the owner's own native event processing and window retirement.
module Hetoimasia.Runtime.GLFW.Internal.Host.Lifetime
  ( withProtectedWindowHost
  , withProtectedWindowHostIn
  , withProtectedWindowHostWith
  , withProtectedWindowHostOver
  , ProtectedExit (..)
  , noProtectedExit
  , runProtectedWindowApplication
  , retirementEnvironmentOf
  ) where

import Control.Concurrent.STM (STM, atomically)
import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , mask
  , rethrowIO
  , toException
  , tryWithContext
  )
import Control.Exception.Context (emptyExceptionContext)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Log (Logger)
import Hetoimasia.Foundation.Resource (Scoped, withResourceLabelled, withScoped)
import Hetoimasia.GLFW.Internal.Window (EventProcessing (..), processWindowEvents)
import Hetoimasia.GLFW.Session (Session, allocSession)
import Hetoimasia.Runtime.Application (runManagedApplication)
import Hetoimasia.Runtime.GLFW.Internal.Host.Application (recordingDiagnostics)
import Hetoimasia.Runtime.GLFW.Internal.Host.Config (HostConfig (..))
import Hetoimasia.Runtime.GLFW.Internal.Host.Construction (allocHostOver, quiesceWindowHost)
import Hetoimasia.Runtime.GLFW.Internal.Host.State (HostHooks (..), HostProtection (..), WindowHost (..), noHostHooks)
import Hetoimasia.Runtime.GLFW.Internal.Host.Wake (reportHostWakeDegradationAtExit)
import Hetoimasia.Runtime.GLFW.Internal.Host.Windows (retirePending)
import Hetoimasia.Runtime.GLFW.Internal.Retirement (DrainOutcome (..), RetirementEnvironment (..), drainRetirement)
import Hetoimasia.Runtime.Logging (LoggingLifetime)
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Numeric.Natural (Natural)

-- | Enter a session and build an attachment-capable host in it, for one
-- consumer on the calling thread, on the process main thread.
--
-- It builds exactly the host 'allocWindowHost' builds — the same validated
-- configuration, session, scoped collection, host port, configured windows, and
-- admission-closing release — and additionally owns the retirement state of
-- "Hetoimasia.GLFW.Internal.Attachment" under a host identity only this
-- lifetime issues. A host built by 'allocWindowHost' is issued none, so no
-- attachment can ever name it.
--
-- It is the shape
-- 'Hetoimasia.Runtime.Application.runManagedApplication' accepts, and it
-- follows that contract in full: once construction succeeds it invokes the
-- consumer exactly once, synchronously on the calling thread, with every
-- dependency it built live; when construction fails it invokes the consumer not
-- at all. Its exit handler is installed under masking before the host is handed
-- over and before interruptibility is restored for any dependent the consumer
-- constructs, so no exit can escape it.
--
-- __On every exit__ — a normal return, an action failure, a startup failure, a
-- dependency construction failure after host setup, an owner-loop failure, a
-- latched supervised failure, and cancellation — the boundary:
--
-- 1. runs the host's own 'quiesceWindowHost' — every port's admission, every
--    input feed, every demand slot, and attachment admission with new graphics
--    use — idempotently and in one finite transaction, even when the
--    application never installed a quiescence hook or omitted the host from
--    one. This is the host's own safeguard; when the application does install
--    it the runtime's ordering has already done it before the worker drain,
--    which is what keeps a worker from starting a use the drain would then have
--    to wait for. Nothing can be admitted or published after it, so the report
--    in step 3 cannot be outrun;
-- 2. retires every remaining attachment on the owner thread, with the windows,
--    the session, and every parent still live, through the narrow progress path
--    "Hetoimasia.Runtime.GLFW.Internal.Retirement" describes: completion
--    notices folded, one bounded opportunity per pending attachment per round,
--    native event processing and the session's internal wake kept live, finite
--    interruptible waits, and no application hook or supervisor checkpoint;
-- 3. makes the wake path's one guarded degradation report, as
--    'runWindowApplication' does, now that nothing further can be admitted or
--    published;
-- 4. settles the outcome and returns, at which point — and only once every
--    attachment is safe — the windows, the session, and the parents unwind in
--    dependency order.
--
-- __The outcome__ is recorded before any interruptible drain work. A body
-- failure stays primary and every drain, report, and deferred failure is
-- retained beside it under the @glfw protected retirement@ label. After a
-- successful body the first drain failure becomes primary and later ones are
-- retained. A cancellation delivered during the drain is deferred: it is
-- counted against every pending attachment as the model's evidence, never
-- establishes a fact, never replaces a recorded outcome, and is re-raised only
-- once retirement is safe — never before a window, the session, or a parent is
-- released.
withProtectedWindowHost ∷ HasCallStack ⇒ Logger → HostConfig → (WindowHost → IO r) → IO r
withProtectedWindowHost logger config =
  withProtectedWindowHostIn logger (allocSession (hostSessionConfig config)) config

-- | 'withProtectedWindowHost' over a session scope the caller supplies, such as
-- a test seam's session. The host owns the session only if that scope does.
withProtectedWindowHostIn
  ∷ HasCallStack ⇒ Logger → Scoped Session → HostConfig → (WindowHost → IO r) → IO r
withProtectedWindowHostIn = withProtectedWindowHostWith noHostHooks

-- | 'withProtectedWindowHostIn' with the private examples' hooks.
withProtectedWindowHostWith
  ∷ HasCallStack ⇒ HostHooks → Logger → Scoped Session → HostConfig → (WindowHost → IO r) → IO r
withProtectedWindowHostWith hooks = withProtectedHostOver hooks noProtectedExit

-- | 'withProtectedWindowHostIn' with an additive lifetime interposed on the
-- exit, for a composition that owns something the host's own drain cannot
-- retire for it.
--
-- It is the one extension point the protected exit has, and it is deliberately
-- narrow: an interposed lifetime closes its own admission inside the host's
-- quiescence transaction, and is given the host and the boundary's own
-- @restore@ at exactly two later points, in an order it cannot change.
-- "Hetoimasia.Runtime.GLFW.Internal.Owner.Lifetime" is its only production
-- caller, for the graphics owner D-33 keeps alive across the attachment drain.
--
-- A 'Nothing' session scope means the host enters the session its
-- configuration names, exactly as 'withProtectedWindowHost' does.
withProtectedWindowHostOver
  ∷ HasCallStack
  ⇒ HostHooks
  → ProtectedExit
  → Logger
  → Maybe (Scoped Session)
  → HostConfig
  → (WindowHost → IO r)
  → IO r
withProtectedWindowHostOver hooks exit logger sessionScope config =
  withProtectedHostOver
    hooks
    exit
    logger
    (fromMaybe (allocSession (hostSessionConfig config)) sessionScope)
    config

withProtectedHostOver
  ∷ HasCallStack
  ⇒ HostHooks
  → ProtectedExit
  → Logger
  → Scoped Session
  → HostConfig
  → (WindowHost → IO r)
  → IO r
withProtectedHostOver hooks exit logger sessionScope config use =
  -- The scope is entered under this mask, so the handler below is installed
  -- before anything at all can be delivered — including in the handoff out of
  -- the scope's own construction and into the consumer, which is a point the
  -- scope restores at. Each part still acquires exactly as it does for
  -- 'allocWindowHost', which already acquires under a mask of its own, and the
  -- consumer is lent the restore.
  mask $ \restore →
    withScoped (allocHostOver Protected hooks (exitQuiescence exit) sessionScope config) $ \host → do
      -- Inside the handler, so an attachment this makes is drained however it
      -- then fails; the consumer follows it on the same protected path.
      outcome ← tryWithContext (restore (beforeConsumer hooks host >> use host))
      settleProtectedExit exit restore logger host outcome

-- | What an additive lifetime interposes on the protected host's exit.
--
-- The quiescence step commits inside 'quiesceWindowHost', on whichever thread
-- runs it. The other two run on the owner thread, inside the boundary's own
-- mask and after the host's quiescence, and both are given the boundary's
-- @restore@ so the parts of them that must stay interruptible can be. None may
-- release a window, the session, or a parent: the boundary still owns that,
-- and still does it last.
--
-- A failure either IO step raises is retained beside the drain's own, under
-- the same @glfw protected retirement@ label, and never replaces a failure the
-- body already raised.
data ProtectedExit = ProtectedExit
  { exitQuiescence ∷ STM ()
    -- ^ In the host's own quiescence transaction, after the host's admission
    -- has closed. It runs wherever that transaction runs — at the
    -- application's pre-drain quiescence, before any ordinary worker is asked
    -- to stop, and again, idempotently, at this boundary — so it must be
    -- finite, non-retrying, and idempotent, and it may only close admission:
    -- it stops, retires, and joins nothing.
  , exitBeforeDrain ∷ WindowHost → (∀ a. IO a → IO a) → IO ()
    -- ^ After the host's quiescence has closed every admission, and before the
    -- attachment drain begins. This is where an interposed lifetime closes its
    -- own admission and asks its own workers to stop.
  , exitAfterDrain ∷ WindowHost → (∀ a. IO a → IO a) → IO ()
    -- ^ After the drain has found every attachment retired against its own
    -- terminal evidence, and before the wake report and before the host's
    -- windows, session, and parents unwind. This is where an interposed
    -- lifetime awaits whatever the drain could not, and joins.
  }

-- | An exit that interposes nothing, which is what every existing constructor
-- passes.
noProtectedExit ∷ ProtectedExit
noProtectedExit = ProtectedExit (pure ()) (\_ _ → pure ()) (\_ _ → pure ())

-- | 'runWindowApplication' over a protected host lifetime.
--
-- The third argument builds the application's dependencies inside the logging
-- lifetime, so the protected host can be given the logger its stall diagnostic
-- and its wake report are written through; the fourth finds the host among
-- them. Every other step keeps the runner's order, thread, and labels: the
-- host's quiescence transaction runs before the worker drain, supervision
-- drains, and the protected host's own exit then retires attachments before its
-- windows, session, and parents unwind.
--
-- Parents the host borrows belong outside the protected lifetime, so they
-- outlive retirement; dependents the consumer builds belong inside it.
runProtectedWindowApplication
  ∷ HasCallStack
  ⇒ (∀ r. (LoggingLifetime → IO r) → IO r)
  → Text
  → (LoggingLifetime → (∀ r. (dependencies → IO r) → IO r))
  → (dependencies → WindowHost)
  → (dependencies → RuntimeControl → IO services)
  → (services → RuntimeControl → IO a)
  → IO a
runProtectedWindowApplication enterLifetime name manage host startup action =
  enterLifetime $ \lifetime →
    runManagedApplication
      (\use → use lifetime)
      name
      (\use → recordingDiagnostics lifetime (manage lifetime use))
      (quiesceWindowHost . host)
      startup
      action

-- | What the drain is lent: the owner's own native event processing and the
-- host's configured finite bound. No application hook, no dispatch, and no
-- supervisor checkpoint is among them.
retirementEnvironmentOf ∷ Logger → WindowHost → RetirementEnvironment
retirementEnvironmentOf logger host =
  RetirementEnvironment
    { environmentLogger = logger
    , environmentPoll = processWindowEvents (hostSession host) ProcessPending
    , environmentAwait = processWindowEvents (hostSession host) (AwaitEventsFor bound)
    , environmentRetireWindows = retirePending host
    , environmentBound = bound
    }
  where
    bound = hostIdleWait (hostSettings host)

-- | The protected boundary's exit: the host's own close, the drain, the wake
-- report, and the settled outcome.
settleProtectedExit
  ∷ HasCallStack
  ⇒ ProtectedExit
  → (∀ a. IO a → IO a)
  → Logger
  → WindowHost
  → Either (ExceptionWithContext SomeException) r
  → IO r
settleProtectedExit exit restore logger host outcome = case hostRetirementState host of
  Nothing → either rethrowIO pure outcome
  Just retirement → do
    -- The host's whole admission, not only its attachments': a command
    -- admitted or a demand published after this point would register a
    -- notification obligation the one degradation report below has already
    -- waited past. Idempotent, so it changes nothing when the application's
    -- own quiescence already ran before the worker drain.
    atomically (quiesceWindowHost host)
    -- The interposed lifetime closes its own admission here, after the host's
    -- and before the drain, so nothing it owns can be admitted into a drain
    -- that has started waiting for it.
    began ← tryWithContext (exitBeforeDrain exit host restore)
    drained ← drainRetirement retirement (retirementEnvironmentOf logger host) restore
    -- Every attachment has been retired against its own terminal evidence.
    -- Whatever the interposed lifetime still owes — a whole-owner destruction
    -- no attachment could account for, and its join — happens here, still
    -- before a single window is released.
    finished ← tryWithContext (exitAfterDrain exit host restore)
    reported ← tryWithContext (reportHostWakeDegradationAtExit restore logger host)
    settleProtectedOutcome outcome drained [began, finished, reported]

-- | Combine the body's outcome with what the drain, the interposed exit, and
-- the report found.
--
-- A body failure stays primary. After a successful body the first drain
-- failure becomes primary, then the interposed exit's and the report's in the
-- order they were attempted, then the deferred cancellation; everything not
-- chosen is retained beside the primary as labelled cleanup evidence.
settleProtectedOutcome
  ∷ Either (ExceptionWithContext SomeException) r
  → DrainOutcome
  → [Either (ExceptionWithContext SomeException) ()]
  → IO r
settleProtectedOutcome body drained afterDrain = case body of
  Left primary → raiseRetaining primary afterwards
  Right result → case afterwards of
    [] → pure result
    primary : retained → raiseRetaining primary retained
  where
    afterwards =
      maybe [] pure (drainPrimary drained)
        <> drainRetained drained
        <> elided
        -- Each interposed step and the wake report contribute their own
        -- failure, in the order the boundary attempted them: one that fails
        -- does not hide a later one's.
        <> concatMap (either pure (const [])) afterDrain
        <> maybe [] pure (drainDeferred drained)
    elided
      | drainElided drained == 0 = []
      | otherwise =
          [ ExceptionWithContext
              emptyExceptionContext
              (toException (RetirementFailuresElided (drainElided drained)))
          ]

-- | Raise one failure with the others retained beside it, each under the
-- protected boundary's own cleanup label, in the order they happened.
--
-- Releases run inside out, so the failure to be recorded first is the innermost
-- scope: the list is reversed before it is folded, and inspection then reports
-- the evidence in the order the boundary found it.
raiseRetaining ∷ ExceptionWithContext SomeException → [ExceptionWithContext SomeException] → IO a
raiseRetaining primary = foldr retainOne (rethrowIO primary) . reverse
  where
    retainOne failure rest =
      withResourceLabelled retirementLabel (pure ()) (\() → rethrowIO failure) (\() → rest)

-- | The cleanup label the protected boundary's retained failures carry.
retirementLabel ∷ Text
retirementLabel = "glfw protected retirement"

-- | How many retirement failures the boundary counted rather than kept, when
-- more arrived than the drain's retained-failure bound keeps.
newtype RetirementFailuresElided = RetirementFailuresElided Natural
  deriving (Eq, Show)

instance Exception RetirementFailuresElided
