-- | A creator's growth of an arena's allowance, driven through the storage backend by the
-- terrain owner as a resumable state machine (requirement 9), holding the session's one
-- mutation slot (growth is serialised with mutation).
--
-- == The protocol
--
-- The store's pure proposal was validated at admission. On the grant the store begins the
-- growth (refused while a transaction is active: the slot excludes one) and the backend
-- reserves the extra range under its own proof ('submitGrowth'). What it obtains is NOT
-- spendable: the run stops at 'GReady' with the backend's prepared token, and the owner's ONE
-- publication decision commits the store's cap, the backend's cap and the creator's result in
-- one transaction. When the owner decides against it (a cancellation, a close, the host no
-- longer eligible) the prepared extra is given back ('submitAbandon'): a release that fails
-- keeps the extra PENDING, charged and visible (@pending_reserved_bytes@), and blocks another
-- growth until it is released by an explicit recovery or the close. A growth that fails before
-- it obtains anything keeps the old cap, the roots and any pause.
--
-- A pending extra is released before anything else ('submitReleasePending'): a growth granted
-- while one is pending releases it first and then begins; an explicit retry runs a release-only
-- run ('startRelease') under the slot. A release that fails leaves the extra pending, and the
-- growth or retry settles with that failure.
--
-- == One step at a time
--
-- As "Hetoimasia.Terrain.Runtime.Backed.Txn": ONE step per 'advanceGrowth' (one submission or
-- the taking of one outcome), called masked; the waits are the owner's one blocking transaction.
module Hetoimasia.Terrain.Runtime.Backed.Growth
  ( GrowthRun
  , startGrowth
  , startRelease
  , GrowthStep (..)
  , GrowthEnd (..)
  , advanceGrowth
  , abandonGrowth
  , growthTicket
  , growthPhaseName
  , growthDraining
  ) where

import Control.Concurrent.STM (STM, atomically)
import Control.Exception (evaluate)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Terrain.Runtime.Backed.Backend
import Hetoimasia.Terrain.Runtime.Backed.Txn (Io (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service
  ( BackingView (..)
  , PreparedGrowth
  , Ticket
  , awaitTicket
  , backingView
  , cancelTicket
  , pollTicket
  , submitAbandon
  , submitGrowth
  , submitReleasePending
  , withOutcome
  )
import Hetoimasia.Terrain.Runtime.Storage.Internal.Types (StorageFailure (BackingClosed))
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
  ( GrowthProposal
  , Store
  , beginGrowth
  , growthFailed
  , gpFrom
  , growthReleaseFailed
  , growthReleased
  , growthReserved
  , growthView
  , gpTo
  , GrowthView (..)
  )

-- | The continuation of one growth.
newtype GrowthRun = GrowthRun Phase

data Phase
  = -- | Granted: the store has not begun it yet.
    Begin !GrowthProposal
  | -- | The backend reserves the extra range.
    Reserving !Ticket
  | -- | The extra is obtained and held, not spendable: the owner decides.
    Prepared !PreparedGrowth
  | -- | The owner decided against a running reservation: it is stopped and drained (the backend's
    -- own arbitration gives back an extra it obtained).
    Withdrawing !Ticket
  | -- | The owner decided against an obtained extra: it is being given back.
    Abandoning !Ticket
  | -- | An extra left pending by an earlier growth must be released first; then the growth (if
    -- any) begins.
    ReleaseFirst !(Maybe GrowthProposal)
  | -- | That release is in flight.
    ReleasingPending !(Maybe GrowthProposal) !Ticket
  | Ended

-- | Begin a growth: the first 'advanceGrowth' begins it in the store and submits the reservation.
startGrowth ∷ GrowthProposal → GrowthRun
startGrowth = GrowthRun . Begin

-- | Release an extra left pending by an earlier growth, and nothing more (an explicit retry's).
startRelease ∷ GrowthRun
startRelease = GrowthRun (ReleaseFirst Nothing)

-- | The ticket a growth waits for, if any.
growthTicket ∷ GrowthRun → Maybe Ticket
growthTicket (GrowthRun phase) = case phase of
  Reserving t → Just t
  Withdrawing t → Just t
  Abandoning t → Just t
  ReleasingPending _ t → Just t
  ReleaseFirst _ → Nothing
  Begin _ → Nothing
  Prepared _ → Nothing
  Ended → Nothing

-- | Whether the owner decided against the growth and it waits for its job.
growthDraining ∷ GrowthRun → Bool
growthDraining (GrowthRun phase) = case phase of
  Withdrawing _ → True
  Abandoning _ → True
  Ended → True
  Begin _ → False
  Reserving _ → False
  Prepared _ → False
  ReleaseFirst _ → False
  ReleasingPending _ _ → False

growthPhaseName ∷ GrowthRun → Text
growthPhaseName (GrowthRun phase) = case phase of
  Begin _ → "begin"
  Reserving _ → "reserving"
  Prepared _ → "prepared"
  Withdrawing _ → "withdrawing"
  Abandoning _ → "abandoning"
  ReleaseFirst _ → "release-first"
  ReleasingPending _ _ → "releasing-pending"
  Ended → "ended"

-- | Where a step left the growth.
data GrowthStep
  = GrowthMore
  | GrowthBlocked !(STM ())
  | -- | The extra is obtained: the owner's decision commits it (or abandons it).
    GrowthReady !PreparedGrowth
  | GrowthOver !GrowthEnd

-- | How a growth ended without being committed. The store reflects it already.
data GrowthEnd
  = -- | It failed before it obtained anything: the old cap, roots and pause stand.
    GrowthFailedWith !Handling
  | -- | The owner decided against it and the extra (if any) was given back.
    GrowthWithdrawn
  | -- | The owner decided against it and giving the extra back failed: it is pending, charged and
    -- visible, and blocks another growth until it is released.
    GrowthLeftPending !(Maybe Handling)
  | -- | A release-only run released the pending extra: the store's growth is idle again.
    GrowthPendingReleased
  deriving stock (Eq, Show)

-- | Take one step. The owner calls it masked.
advanceGrowth ∷ Io → Closing → Store → GrowthRun → IO (Store, GrowthRun, GrowthStep)
advanceGrowth io closing store (GrowthRun phase) = case phase of
  Ended → pure (store, GrowthRun Ended, GrowthOver GrowthWithdrawn)
  Prepared prepared → pure (store, GrowthRun phase, GrowthReady prepared)
  Begin proposal
    -- an extra left pending by an earlier growth is released before another growth begins
    | gvReleasing (growthView store) → yieldTo store (ReleaseFirst (Just proposal)) GrowthMore
  Begin proposal → case beginGrowth proposal store of
    Left refusal → over store (GrowthFailedWith (HandleDefect (Text.pack ("a granted growth could not begin: " <> show refusal))))
    Right begun →
      submitGrowth (ioService io) (ioBacking io) (gpFrom proposal) (gpTo proposal) >>= \case
        Left failure → over (growthFailed begun) (GrowthFailedWith (classifyFailure closing JkGrowth failure))
        Right ticket → yieldTo begun (Reserving ticket) (GrowthBlocked (awaitTicket (ioService io) ticket))
  Reserving ticket → waitThen ticket $
    withOutcome (ioService io) ticket (\outcome → evaluate $! reactTo closing JkGrowth outcome) >>= \case
      Just (GotGrowthPrepared prepared _) → case growthReserved store of
        Right reserved → yieldTo reserved (Prepared prepared) (GrowthReady prepared)
        Left refusal → over store (GrowthFailedWith (HandleDefect (Text.pack ("the store refused an obtained growth: " <> show refusal))))
      -- the proposal said larger; the backend found the allowance already that large
      Just GotGrowthNoChange → over (growthFailed store) (GrowthFailedWith (HandleDefect "a proposed growth found no change in the backend"))
      Just (GotFailure handling _) → over (growthFailed store) (GrowthFailedWith handling)
      Just (GotCancelled _) → over (growthFailed store) (GrowthFailedWith (classifyUnaskedCancel closing))
      Just (GotMismatch why) → over (growthFailed store) (GrowthFailedWith (HandleDefect why))
      Just other → over (growthFailed store) (GrowthFailedWith (HandleDefect (Text.pack ("a growth answered " <> show other))))
      Nothing → over (growthFailed store) . GrowthFailedWith =<< lost
  ReleaseFirst next →
    submitReleasePending (ioService io) (ioBacking io) >>= \case
      Left failure → over store (GrowthFailedWith (classifyFailure closing JkRelease failure))
      Right ticket → yieldTo store (ReleasingPending next ticket) (GrowthBlocked (awaitTicket (ioService io) ticket))
  ReleasingPending next ticket → waitThen ticket $
    withOutcome (ioService io) ticket (\outcome → evaluate $! reactTo closing JkRelease outcome) >>= \case
      Just GotReleased → case next of
        Just proposal → yieldTo (growthReleased store) (Begin proposal) GrowthMore
        Nothing → over (growthReleased store) GrowthPendingReleased
      -- the release failed: the extra stays pending, charged and visible; the store is unchanged
      Just (GotFailure handling _) → over store (GrowthFailedWith handling)
      Just (GotCancelled _) → over store (GrowthFailedWith (classifyUnaskedCancel closing))
      Just (GotMismatch why) → over store (GrowthFailedWith (HandleDefect why))
      Just other → over store (GrowthFailedWith (HandleDefect (Text.pack ("a pending release answered " <> show other))))
      Nothing → over store . GrowthFailedWith =<< lost
  Withdrawing ticket → waitThen ticket $ do
    -- the running reservation stopped: the backend's own arbitration gave back an extra it had
    -- obtained, or kept it pending if that failed; the store follows what the backing reports
    _ ← withOutcome (ioService io) ticket (\_ → pure ())
    pending ← atomically (backingView (ioService io) (ioBacking io))
    case pending >>= bvPendingReservation of
      Just _ → over (growthReleaseFailed (growthFailed store)) (GrowthLeftPending Nothing)
      Nothing → over (growthFailed store) GrowthWithdrawn
  Abandoning ticket → waitThen ticket $
    withOutcome (ioService io) ticket (\outcome → evaluate $! reactTo closing JkRelease outcome) >>= \case
      Just GotReleased → over (growthReleased store) GrowthWithdrawn
      Just (GotFailure handling _) → over (growthReleaseFailed store) (GrowthLeftPending (Just handling))
      Just (GotCancelled _) → over (growthReleaseFailed store) (GrowthLeftPending (Just (classifyUnaskedCancel closing)))
      Just (GotMismatch why) → over (growthReleaseFailed store) (GrowthLeftPending (Just (HandleDefect why)))
      Just other → over (growthReleaseFailed store) (GrowthLeftPending (Just (HandleDefect (Text.pack ("a release answered " <> show other)))))
      Nothing → over (growthReleaseFailed store) . GrowthLeftPending . Just =<< lost
  where
    yieldTo s next step = do
      s' ← evaluate s
      pure (s', GrowthRun next, step)
    over s end = yieldTo s Ended (GrowthOver end)
    waitThen ticket action = do
      finished ← atomically (pollTicket (ioService io) ticket)
      if finished then action else pure (store, GrowthRun phase, GrowthBlocked (awaitTicket (ioService io) ticket))
    lost = do
      view ← atomically (backingView (ioService io) (ioBacking io))
      pure $ case view of
        Just v | not (bvClosing v) → HandleDefect "a finished growth job named a ticket the service does not hold"
        _ → classifyFailure closing JkGrowth BackingClosed

-- | The owner decided against the growth (a cancellation, a close, the host no longer eligible):
-- a running reservation is stopped and drained, an obtained extra is given back. Nothing is
-- released until the job in flight has returned. Called masked.
abandonGrowth ∷ Io → Store → GrowthRun → IO (Store, GrowthRun, GrowthStep)
abandonGrowth io store (GrowthRun phase) = case phase of
  Ended → pure (store, GrowthRun Ended, GrowthOver GrowthWithdrawn)
  Begin _ → pure (store, GrowthRun Ended, GrowthOver GrowthWithdrawn)
  Reserving ticket → do
    _ ← cancelTicket (ioService io) ticket
    pure (store, GrowthRun (Withdrawing ticket), GrowthBlocked (awaitTicket (ioService io) ticket))
  Prepared prepared →
    submitAbandon (ioService io) (ioBacking io) prepared >>= \case
      Right ticket → pure (store, GrowthRun (Abandoning ticket), GrowthBlocked (awaitTicket (ioService io) ticket))
      Left failure → do
        s ← evaluate (growthReleaseFailed (growthFailed store))
        pure (s, GrowthRun Ended, GrowthOver (GrowthLeftPending (Just (classifyFailure OwnerClosing JkRelease failure))))
  -- nothing submitted yet: the pending extra stays pending
  ReleaseFirst _ → pure (store, GrowthRun Ended, GrowthOver GrowthWithdrawn)
  -- a release in flight is taken as it ends (released, or left pending), and nothing begins after it
  ReleasingPending _ ticket → do
    (s, r, step) ← advanceGrowth io OwnerClosing store (GrowthRun (ReleasingPending Nothing ticket))
    pure (s, r, case step of
      GrowthOver GrowthPendingReleased → GrowthOver GrowthWithdrawn
      GrowthOver (GrowthFailedWith h) → GrowthOver (GrowthLeftPending (Just h))
      other → other)
  -- already decided against: wait for its job and take the outcome, as 'advanceGrowth' does
  Withdrawing _ → advanceGrowth io OwnerClosing store (GrowthRun phase)
  Abandoning _ → advanceGrowth io OwnerClosing store (GrowthRun phase)
