-- | What the owner's thread, and the application's, does with the provider service: calls
-- the providers, polls what they have proved, disposes of what their work needed, serves the
-- requests due at a tick, ends what a requester or an epoch or the owner held, and waits.
--
-- = Every call into provider code goes through one guard
--
-- 'guarded' is the guard: a call into provider code (handing a request over, withdrawing
-- interest, disposing of what its work needed) is run and /fully evaluated/ inside it, and
-- what it raises is answered as a value with its context, never loose. The provider's own
-- reading of its retirement is the one call that cannot be run in IO, because it is a
-- transaction, and it goes through the transactional form of the same guard,
-- 'Hetoimasia.Scripting.Lua.Retention.pollObligation'. Nothing else calls a provider.
--
-- = What a failure is
--
-- * A provider reporting a failure is a reply, and settles the request as a failure, returned
--   to the script as data.
-- * Provider code raising when the engine calls it (handing a request over, withdrawing
--   interest) is a failure of application code: a failure of the host under the owner's
--   policy, unconverted. Where several arise together the first is raised and the others are
--   kept whole as cleanup evidence ('raiseFirst').
-- * A provider's retirement that fails, and the disposal of what its work needed that
--   raises, are cleanup failures: they are cleanup evidence on the owner, fatal under every
--   policy, retained on the work, and never retried.
module Hetoimasia.Scripting.Lua.Provider.Serve
  ( -- * Calling providers
    guarded
  , tellProviders
  , raiseFirst
  , raiseAmong

    -- * Serving
  , serveTick
  , serveWatchOnly
  , serviceProvider
  , providerBoundary
  , providerWork

    -- * Ending
  , endRequester
  , sweepRequesters
  , retireProvider
  , advanceRequestEpoch
  ) where

import Control.Concurrent.STM (STM, atomically, retry)
import Control.Exception
  ( ExceptionWithContext
  , SomeException
  , mask_
  , rethrowIO
  , tryWithContext
  , uninterruptibleMask_
  )
import Control.Monad (forM, unless, when)
import Control.Concurrent.STM (readTVar)
import Data.IORef (IORef, modifyIORef')
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.Foundation.Failure (operation, throwFailure)
import Hetoimasia.Foundation.Resource (composeCleanup)
import Hetoimasia.Scripting.Lua.Lease.State (LeaseHost, adoptReserved, releaseKey)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Request (CancelCause (CancelledByTaskInvalidation))
import Hetoimasia.Scripting.Lua.Retention (guarded)
import Hetoimasia.Scripting.Lua.Provider.Events (nextStagedAfter)
import Hetoimasia.Scripting.Lua.Provider.State
import Hetoimasia.Scripting.Lua.Provider.Types
import Hetoimasia.Scripting.Lua.Runtime.Shared (runtimeComponent)
import Hetoimasia.Scripting.Lua.Scheduler
  ( CadenceFiring (FiredLogical)
  , Scheduler
  , releaseWatch
  , setWatch
  , takeNextCadenceFiring
  , watchKey
  )

-- Calling providers ---------------------------------------------------------------------

-- | Tell the providers whose interest was withdrawn, once each: the work is claimed in a
-- transaction first, so no other thread tells it again, and the telling is guarded. Answers
-- what the providers raised, in the order they were told; every one is told whatever another
-- raised. A provider that finished is not told.
tellProviders ∷ ProviderState → IO [ExceptionWithContext SomeException]
tellProviders service = mask_ $ do
  -- Claiming and telling are one masked step: a claim is never left without its telling, which
  -- nothing would make again.
  claimed ← atomically (claimCancels service)
  failures ← forM claimed $ \found → guarded (workCancel (claimedWork found))
  pure [failure | Left failure ← failures]

-- | Raise the first of several failures, and keep each of the others whole as cleanup
-- evidence under this label, so that none is dropped.
raiseFirst ∷ IORef [(Text, ExceptionWithContext SomeException)] → Text → [ExceptionWithContext SomeException] → IO ()
raiseFirst evidence label = \case
  [] → pure ()
  first : others → do
    modifyIORef' evidence (<> [(label, other) | other ← others])
    rethrowIO first

-- | Raise the first of several failures with the others attached to it as cleanup evidence,
-- for a caller with no list of its own to keep them in.
raiseAmong ∷ Text → [ExceptionWithContext SomeException] → IO ()
raiseAmong label = \case
  [] → pure ()
  [only] → rethrowIO only
  first : others → do
    composed ← composeCleanup (Just first) [(label, other) | other ← others]
    maybe (rethrowIO first) rethrowIO composed

-- | A provider defect as the failure the owner raises: the bounded diagnostic, with the context
-- of the boundary that found it.
defectOf ∷ Text → IO (ExceptionWithContext SomeException)
defectOf why = do
  raised ← tryWithContext @SomeException (throwFailure runtimeComponent (operation "provider-reply") [] (ProviderDefect why))
  either pure (\() → throwFailure runtimeComponent (operation "provider-reply") [] (ProviderDefect why)) raised

-- | Build the resources the providers replied with into the leases their requests reserved, on the
-- owner's thread through the capability it holds: one at a time, each uninterrupted from the
-- building to the recording that the lease is live and the result applied. A request that was
-- cancelled or ended while its resource was being built gets the resource released at once. A
-- recipe that raises is a failure of application code: the reservation is given back, and the failure
-- is the owner's, after the others were built. Answers the failures, in order.
adoptPending ∷ ProviderState → Maybe LeaseHost → IO [ExceptionWithContext SomeException]
adoptPending service leaseHost = mask_ $ do
  pending ← atomically (takePendingAdoptions service)
  concat
    <$> forM pending
      ( \(identity, adopting) → case (leaseHost, adoptingBuild adopting) of
          (Nothing, _) → do
            -- The reservation was made in leases the owner was given, so it has a host: this is
            -- the engine's own inconsistency.
            atomically (failAdoption service identity)
            raised ← tryWithContext @SomeException (throwFailure runtimeComponent (operation "adopt-resource") [] (userError "a result lease was reserved on an owner that holds no lease host"))
            pure [failure | Left failure ← [raised]]
          (Just host, Adoption build) → do
            built ← adoptReserved host (adoptingInstance adopting) (adoptingKey adopting) build
            case built of
              Left failure → do
                atomically (failAdoption service identity)
                pure [failure]
              Right () → do
                applied ← atomically (finishAdoption service identity adopting)
                case applied of
                  Just _ → pure []
                  Nothing → do
                    released ← releaseKey host (adoptingInstance adopting) (adoptingKey adopting)
                    pure [failure | Left failure ← [released]]
      )

-- Serving ----------------------------------------------------------------------------------

-- | Serve a tick the owner has reached: the requests due at it or before are settled by the
-- completions they held, in the order of their places, and the tasks waiting for them are
-- woken in that order. All of it is one transaction, so nothing runs between. Answers the
-- earliest tick a request or an event still unserved is due at, for the owner to watch. The
-- events held for this tick are the instance layer's to admit ('serveEvents'), after the
-- controls the tick holds, which come first.
serveTick ∷ ProviderState → Word64 → STM (Maybe Word64)
serveTick service tick = do
  due ← takeDue service tick
  settled ← serveDue service due
  _ ← ticksWakeOrdered (psTicks service) settled
  requests ← nextDueTick service
  events ← nextStagedAfter service tick
  pure $ case (requests, events) of
    (Just first, Just second) → Just (min first second)
    (first, Nothing) → first
    (Nothing, second) → second

-- | Serve the watch's points for an owner that hosts no instances, so has nothing else that
-- takes them: each reached tick serves its requests and the grant that reached it is let go.
-- Answers whether it served any.
serveWatchOnly ∷ ProviderState → Scheduler v → IO Bool
serveWatchOnly service scheduler = go False
  where
    go served =
      atomically (takeNextCadenceFiring scheduler) >>= \case
        Just (key, firing)
          | key == watchKey → do
              atomically $ do
                case firing of
                  FiredLogical tick → serveTick service tick >>= setWatch scheduler
                  _ → pure ()
                releaseWatch scheduler
              go True
          | otherwise → go served
        Nothing → pure served

-- | Poll the providers' own accounts of work whose interest was withdrawn, dispose of what
-- the work that is over needed, and forget the work that is done. Answers the cleanup
-- failures that arose: a retirement a provider reports failed, and a disposal that raised.
-- Each is retained on its work, answered once, and is fatal for the owner.
serviceProvider ∷ ProviderState → IO [(Text, ExceptionWithContext SomeException)]
serviceProvider service = mask_ $ do
  (polled, ready) ← atomically (sweepWorks service)
  disposed ← forM ready $ \(identity, label, actions) → do
    -- One at a time, uninterruptibly, a failure of one not stopping the rest.
    results ← forM actions $ \dispose → guarded (uninterruptibleMask_ dispose)
    let failures = [failure | Left failure ← results]
    atomically (mapM_ (failWorkOnce identity) (take 1 failures))
    pure [(label, failure) | failure ← failures]
  atomically (reapWorks service)
  pure (polled <> concat disposed)
  where
    failWorkOnce identity = failWork service identity

-- | The owner's step at a safe boundary, for its requests: end the requesters whose tasks are
-- gone, tell the providers whose interest was withdrawn, poll and dispose, serve the watch's
-- points when no instance layer does, and wake the tasks whose requests have settled.
-- Answers whether it changed anything the boundary should look at again.
--
-- A failure of a provider told to stop is a failure of the host and is raised, after the rest
-- were told, with the others kept as evidence; a cleanup failure is kept as evidence and
-- fails the owner. @hasInstances@ says whether an instance layer serves the watch.
providerBoundary
  ∷ ProviderState
  → Scheduler v
  → Bool
  → Maybe LeaseHost
  → IORef [(Text, ExceptionWithContext SomeException)]
  → IO ()
  → IO Bool
providerBoundary service scheduler hasInstances leaseHost evidence onCleanupFailure = mask_ $ do
  -- One masked step from the claims to their recording: a failure that servicing took out of
  -- the accounts, or a tell that was claimed, is recorded or raised before a cancellation can
  -- be delivered, so none is dropped.
  before ← atomically (workPendingCount service)
  swept ← sweepRequesters service
  told ← tellProviders service
  cleanup ← serviceProvider service
  unless (null cleanup) $ do
    modifyIORef' evidence (<> cleanup)
    onCleanupFailure
  -- The resources the providers replied with are built into the leases their requests reserved,
  -- on this thread, before the results they belong to can be held or settled.
  adopting ← atomically (not . Map.null . pAdopting <$> readTVar (psVar service))
  adopted ← adoptPending service leaseHost
  defects ← atomically (takeDefects service)
  defective ← forM defects defectOf
  served ← if hasInstances then pure False else serveWatchOnly service scheduler
  woke ← atomically (ticksWakeSettled (psTicks service) (settledNumber service))
  after ← atomically (workPendingCount service)
  raiseFirst evidence "lua provider boundary" (defective <> adopted <> swept <> told)
  pure (woke || served || before /= after || not (null cleanup) || adopting || not (null defects))

-- | Whether the owner has anything to do for its requests, and a wait to compose into its
-- wait for work: a task whose request has settled, a provider's account that is no longer
-- pending, or disposals to run.
providerWork ∷ ProviderState → STM ()
providerWork service = do
  waiting ← ticksWaiting (psTicks service) (settledNumber service)
  work ← workWaiting service
  unless (waiting || work) retry

-- Ending -----------------------------------------------------------------------------------

-- | End a requester on the owner's thread: its requests are revoked for this cause and the
-- providers whose interest that withdrew are told. Answers what the providers raised.
endRequester ∷ ProviderState → Requester → CancelCause → IO [ExceptionWithContext SomeException]
endRequester service requester cause = mask_ $ do
  _ ← atomically (endRequesterSTM service requester cause)
  tellProviders service

-- | End the task requesters whose tasks are gone. Answers what the providers raised.
sweepRequesters ∷ ProviderState → IO [ExceptionWithContext SomeException]
sweepRequesters service = do
  gone ← atomically (goneRequesters service)
  concat <$> forM gone (\requester → endRequester service requester CancelledByTaskInvalidation)

-- | The owner is exiting, after its instances have ended: nothing is admitted from here on,
-- every request still held is revoked, the providers are told, and then the owner waits,
-- uninterruptibly, serving as it goes, until every provider has proved its work over and
-- what the work needed is disposed of. Nothing is disposed of before the provider says it is
-- safe, through a stop and through a cancellation. Answers what the providers raised when
-- told, and the cleanup failures.
retireProvider ∷ ProviderState → IO ([ExceptionWithContext SomeException], [(Text, ExceptionWithContext SomeException)])
retireProvider service = mask_ $ do
  _ ← atomically (closeSTM service)
  told ← tellProviders service
  cleanup ← uninterruptibleMask_ (settleAll [])
  pure (told, cleanup)
  where
    settleAll acc = do
      failures ← serviceProvider service
      done ← atomically $ do
        pending ← anyWorkPending service
        ready ← workWaiting service
        when (pending && not ready) retry
        pure (not pending)
      -- A tell that was claimed while the work was still being handed over is made now.
      late ← tellProviders service
      let acc' = acc <> failures <> [("lua request cancel", failure) | failure ← late]
      if done then pure acc' else settleAll acc'

-- | Replace the generation of the owner's records (P-9): every outstanding request settles,
-- once, as cancelled by the epoch change, and the provider work on all of them is to be told.
-- The application chooses when; the epoch changes in one transaction, and the answer is what it
-- invalidated. 'Nothing' for an owner that has exited, which has no epoch to advance.
--
-- The providers are told by the owner, at its next boundary, as for every other withdrawal of
-- interest: a provider that raises when told is then a failure of the host under the owner's
-- policy, whoever advanced the epoch, and is never raised on the application's thread, where
-- no policy is applied and nothing would remember the claim.
advanceRequestEpoch ∷ ProviderState → IO (Maybe EpochReport)
advanceRequestEpoch service = mask_ (atomically (advanceEpochSTM service))
