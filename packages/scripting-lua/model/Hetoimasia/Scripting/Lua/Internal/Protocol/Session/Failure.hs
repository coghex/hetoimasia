-- | Failure reporting: failing the task a report names, and moving the
-- session to its terminal failed state when the report is unsafe.
--
-- A failed session still reports. An unsafe failure invalidates every live
-- task, queued admission, subscription, and pending request of that moment and
-- closes @Mutating@ admission, and leaves @Observing@ admission open, so the
-- owner can admit work that reports on the failure it just had. That is P-8's
-- quiescent failed-session state: alive enough to be asked what happened, and
-- unable to touch authoritative state again. The invalidation it performs is
-- its own, not epoch replacement's or stop's: finished tasks keep their
-- results here, because a failed session cannot report a result it threw away.
module Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Failure
  ( reportFailure
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import Hetoimasia.Scripting.Lua.Internal.Protocol.Failure (RecoverySafety (RecoveryUnsafe))
import Hetoimasia.Scripting.Lua.Internal.Protocol.Request (CancelCause (CancelledBySessionFailure))
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Revocation (retire, revocableRequests, revokeOne)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.State
  ( AdmissionState (AdmissionClosed, MutationAdmissionClosed)
  , Counters (..)
  , FailureRecord (..)
  , Session (..)
  , SessionRejection (..)
  , TerminalResult (ResultFailed)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Step
  ( counting
  , issuedHere
  , notFailed
  , notStopped
  , queuedHere
  , refuse
  , transition
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Subscription (unsubscribe)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Task
  ( Task (taskState)
  , TaskFailure (TaskFailure)
  , TransitionRejection (AlreadyTerminal)
  , failTask
  , isTerminal
  )

-- | Report a failure.
--
-- A failure naming a task fails that task, whose terminal result records it. A
-- failure marked 'RecoveryUnsafe' additionally moves the session to its
-- terminal failed state: mutation admission closes, every live task, queued
-- admission, subscription, and pending request is invalidated, and the record
-- is kept beside the identity of the last good snapshot. Nothing restarts it.
--
-- An unsafe failure whose task has /already/ finished still ends the session.
-- The task keeps the one terminal outcome it reached — nothing here gives it a
-- second — but the session cannot: "the behaviour that touched authoritative
-- state was cancelled a moment ago" is not evidence that the state it touched
-- is consistent, and a failure that arrived after its task settled is exactly
-- the case where it is not. A /safe/ failure naming a finished task is
-- refused, because there is then nothing to record and nothing to end.
--
-- The same holds once the task's record has been /forgotten/. A terminal
-- result that has been observed takes its task's record with it, and a failure
-- naming that identity is neither a live task nor an unknown one:
-- 'issuedHere' tells the two apart in a comparison, an unsafe failure still
-- ends the session, and a safe one is refused as 'TaskRetired'.
--
-- An identity that names a /queued/ admission is refused as
-- 'TaskNotActivated', safe or unsafe alike, and escalates nothing: that task
-- has never run, so it cannot have left authoritative state half-applied, and
-- a report saying it did is wrong rather than urgent.
--
-- Which task is rejected outright is unchanged: an identity this session never
-- issued, or issued under a replaced epoch, is 'UnknownTask' and escalates
-- nothing.
--
-- Once the session itself has failed unsafely, one report still lands: a
-- 'RecoverySafe' failure naming an /active/ task of the current epoch. Only
-- 'Observing' work can be active there — the failure invalidated every live
-- task it found and closed mutation admission — so this is the failure of the
-- reporting work D-7 kept the session alive to run, and refusing it would
-- strand that task 'Running' with its reserved terminal-result storage held
-- until a cancellation or a stop. It settles exactly as it would in an
-- unfailed session, and it settles once: the task is terminal afterwards, so a
-- repeat is refused as 'SessionAlreadyFailed' like every other report a failed
-- session receives.
--
-- Nothing else gets through. A second 'RecoveryUnsafe' report, a safe report
-- naming no task, a queued admission, a task that already finished, one whose
-- result has been observed away, and an identity this session never issued are
-- all still 'SessionAlreadyFailed', and the session's own 'FailureRecord' is
-- never overwritten — 'escalate' does nothing for a safe report.
reportFailure ∷ FailureRecord → Session v → (Session v, Either SessionRejection ())
reportFailure record session = case notStopped session >> reportable of
  Left rejection → refuse session rejection
  Right () → case failedTask record of
    Nothing → (escalate session, Right ())
    Just identity
      | queuedHere identity session →
          -- A queued admission has never run, so it cannot have touched
          -- authoritative state, and a report that it did is incoherent
          -- whatever its recovery marking says. Refusing it is the answer; a
          -- session terminally failed on an impossible attribution would be a
          -- worse outcome than a caller told its report was wrong.
          refuse session (TaskNotActivated identity)
      | not (Map.member identity (sessionTasks session))
      , issuedHere identity session →
          -- The record has been observed and forgotten, so there is no task
          -- left to fail. The session is a different matter: a report that
          -- authoritative state may be half-applied does not become false
          -- because the behaviour that touched it was tidied away first, and
          -- unlike a queued admission this task did run.
          if unsafe
            then (escalate session, Right ())
            else refuse session (TaskRetired identity)
    Just identity →
      let failure = TaskFailure (failedReason record) (failedRecovery record)
       in case transition identity (failTask (sessionKey session) failure) session of
            (next, Left (TransitionRefused (AlreadyTerminal outcome)))
              | unsafe → (escalate next, Right ())
              | otherwise → (next, Left (TransitionRefused (AlreadyTerminal outcome)))
            (next, Left rejection) → (next, Left rejection)
            (next, Right _) →
              (escalate (retire identity (ResultFailed failure) next), Right ())
  where
    unsafe = failedRecovery record == RecoveryUnsafe
    -- | 'notFailed', less the one report a failed session still settles.
    reportable = case notFailed session of
      Right () → Right ()
      Left rejection
        | settlesActiveWork → Right ()
        | otherwise → Left rejection
    -- | Whether this report is a safe failure of a task that is still live.
    --
    -- Liveness is read off the task map rather than the authority the
    -- admission carried, which activation does not keep: on a failed session
    -- an active task /is/ observing work, because the failure invalidated
    -- every live task of that moment and nothing mutating has been admitted
    -- since. Being live also excludes the queued, finished, observed, and
    -- never-issued identities, whose refusals stand.
    settlesActiveWork = case failedTask record of
      Just identity
        | not unsafe →
            maybe False (not . isTerminal . taskState) (Map.lookup identity (sessionTasks session))
      _ → False
    escalate current
      | not unsafe = current
      | otherwise = invalidateEverything current {sessionFailure = Just record}

-- | Close mutation admission and invalidate every live record.
--
-- A live task that is invalidated is gone, so the terminal-result storage its
-- admission reserved is released and counted as discarded. The tasks that had
-- already finished keep their results: a failed session's job is to report,
-- and it cannot report a result it threw away.
invalidateEverything ∷ Session v → Session v
invalidateEverything session =
  counting
    ( \counters →
        counters
          { countInvalidatedTasks = countInvalidatedTasks counters + Map.size live
          , countInvalidatedSubscriptions =
              countInvalidatedSubscriptions counters + Map.size (sessionSubscriptions session)
          , countDiscardedAdmissions =
              countDiscardedAdmissions counters + Seq.length (sessionQueued session)
          , countDiscardedResults = countDiscardedResults counters + Map.size live
          , countDiscardedEvents = countDiscardedEvents counters + discardedBacklog
          }
    )
    revoked
      { sessionAdmission = closedAdmission
      , sessionTasks = Map.filter (isTerminal . taskState) (sessionTasks session)
      , sessionQueued = Seq.empty
      , sessionSubscriptions = Map.empty
      , sessionReservations =
          sessionReservations session - Map.size live - Seq.length (sessionQueued session)
      }
  where
    live = Map.filter (not . isTerminal . taskState) (sessionTasks session)
    discardedBacklog = sum (fmap unsubscribe (Map.elems (sessionSubscriptions session)))
    revoked =
      foldl'
        (flip (revokeOne CancelledBySessionFailure))
        session
        (revocableRequests session)
    closedAdmission = case sessionAdmission session of
      AdmissionClosed → AdmissionClosed
      _ → MutationAdmissionClosed
