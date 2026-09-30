-- | The vocabulary every session operation is written in: answering a
-- refusal, recording evidence on the counters, the two preconditions, issuing
-- ordinals, task names and generations, recognising what this epoch issued,
-- and applying one task transition.
--
-- These are building blocks, not operations. None of them is exported by the
-- facade, and each operation that composes them remains responsible for the
-- rejection contract stated there: a refusal built from 'refuse' leaves the
-- session exactly as it was given, and only the operation decides what
-- evidence to record first.
module Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Step
  ( -- * Answering
    refuse
  , discard
  , counting
  , limitsIn

    -- * Preconditions
  , notStopped
  , notFailed

    -- * Issuing
  , takeOrdinal
  , takeTaskName
  , takeGeneration
  , issuedHere
  , queuedHere

    -- * Task transitions
  , transition
  ) where

import qualified Data.Map.Strict as Map
import Hetoimasia.Scripting.Lua.Internal.Protocol.Failure (RecoverySafety (RecoveryUnsafe))
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity
  ( Generation
  , Ordinal
  , TaskId (taskName, taskScope)
  , TaskName
  , nextGeneration
  , nextOrdinal
  , nextTaskName
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Limits (Limits, limitsOf)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.State
  ( Counters
  , FailureRecord (failedRecovery)
  , QueuedAdmission (queuedTask)
  , Session (..)
  , SessionRejection (SessionAlreadyFailed, SessionAlreadyStopped, TransitionRefused, UnknownTask)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Task (Task, TransitionRejection)

-- Answering ------------------------------------------------------------------

limitsIn ∷ Session v → Limits
limitsIn = limitsOf . sessionLimits

counting ∷ (Counters → Counters) → Session v → Session v
counting change session = session {sessionCounters = change (sessionCounters session)}

refuse ∷ Session v → SessionRejection → (Session v, Either SessionRejection a)
refuse session rejection = (session, Left rejection)

-- | Keep an operation's session and drop the value it answered.
discard ∷ (Session v, Either SessionRejection a) → (Session v, Either SessionRejection ())
discard (session, answer) = (session, () <$ answer)

-- Preconditions --------------------------------------------------------------

-- | The session has not stopped.
--
-- This is the precondition of every ordinary operation, and it deliberately
-- does not include "has not failed". A session that failed unsafely closes
-- mutation admission and keeps reporting: its observing tasks still run, still
-- ask providers, and still watch endpoints, because a failed gameplay session
-- that could say nothing about itself would be worse than a stopped one.
notStopped ∷ Session v → Either SessionRejection ()
notStopped session = case sessionExit session of
  Just _ → Left SessionAlreadyStopped
  Nothing → Right ()

-- | The session has not reached its terminal failed state.
--
-- Required only by the two operations that would be a continuation of it:
-- advancing its epoch, and reporting a second failure over the first.
notFailed ∷ Session v → Either SessionRejection ()
notFailed session = case sessionFailure session of
  Just record | failedRecovery record == RecoveryUnsafe → Left SessionAlreadyFailed
  _ → Right ()

-- Issuing --------------------------------------------------------------------

takeOrdinal ∷ Session v → (Ordinal, Session v)
takeOrdinal session =
  ( sessionNextOrdinal session
  , session {sessionNextOrdinal = nextOrdinal (sessionNextOrdinal session)}
  )

-- | Whether this session issued a task identity /in its current epoch/,
-- whatever became of it.
--
-- Names come from one counter that is never rewound, and an epoch change
-- records where the new epoch's range starts, so "this epoch issued it" is two
-- comparisons and nothing has to be remembered. Both ends matter: without the
-- lower bound, a name this session issued under a /previous/ epoch would pass
-- when paired with the current scope, and an identity nothing ever issued
-- would be treated as one of ours.
--
-- It distinguishes a task whose record has been observed and forgotten from
-- one that is foreign, of a replaced epoch, or was never issued at all — a
-- distinction a failure report turns on, and one that a list of retired
-- identities would otherwise have to grow forever to make.
issuedHere ∷ TaskId → Session v → Bool
issuedHere identity session =
  taskScope identity == sessionKey session
    && taskName identity >= sessionEpochFirstTask session
    && taskName identity < sessionNextTask session

-- | Whether an identity names an admission that is accepted but not activated.
--
-- A queued admission is a task that has not run rather than one that has
-- finished, and telling the two apart is what keeps a failure report about
-- work that never happened from being honoured as one about work that did.
queuedHere ∷ TaskId → Session v → Bool
queuedHere identity session = any ((== identity) . queuedTask) (sessionQueued session)

-- | Issue the next task name.
--
-- Never rewound, and not reset by an epoch change. A task whose result has
-- been observed and whose record has been forgotten therefore cannot have its
-- name handed to another task, which is what keeps a segment outcome
-- addressed to the old one from landing on the new one.
takeTaskName ∷ Session v → (TaskName, Session v)
takeTaskName session =
  ( sessionNextTask session
  , session {sessionNextTask = nextTaskName (sessionNextTask session)}
  )

-- | Issue the next generation, for a request or a subscription identity.
--
-- One counter for both, because its job is only to differ from every
-- generation this session has issued before. A caller may reuse a
-- 'RequestName' or a 'SubscriptionName' freely: the identity the session
-- builds from it is new either way, so a reply or an event still in flight for
-- the record that handle named before cannot reach the record it names now.
takeGeneration ∷ Session v → (Generation, Session v)
takeGeneration session =
  ( sessionNextGeneration session
  , session {sessionNextGeneration = nextGeneration (sessionNextGeneration session)}
  )

-- Task transitions -----------------------------------------------------------

-- | Apply a task transition, reporting a missing task and a refused transition
-- with the same shape.
transition
  ∷ TaskId
  → (Task v → Either TransitionRejection (Task v))
  → Session v
  → (Session v, Either SessionRejection (Task v))
transition identity step session = case Map.lookup identity (sessionTasks session) of
  Nothing → refuse session (UnknownTask identity)
  Just task → case step task of
    Left rejection → refuse session (TransitionRefused rejection)
    Right next →
      ( session {sessionTasks = Map.insert identity next (sessionTasks session)}
      , Right next
      )
