-- | One asynchronous request: its single-assignment slot, and the two
-- obligations its bookkeeping holds.
--
-- = Two obligations, never one
--
-- Accepting a request creates two independent debts, and the record lives
-- until both are paid:
--
-- * a __result-storage reservation__ ('requestResultHeld'), taken before the
--   request is accepted so a reply never has to wait for the requester to
--   drain anything, and released when the settlement is observed or discarded;
-- * __provider-work accounting__ ('requestProviderOutstanding'), which records
--   that somebody else is still doing work on our behalf, and is released only
--   by evidence that the work ended.
--
-- Discharging one never discharges the other. Provider completion does not
-- release an unobserved result's storage, and observing a cancellation does
-- not establish that the provider stopped. 'requestReclaimable' is true only
-- when both are discharged, which is when the session may forget the request
-- and reuse its outstanding-request capacity.
--
-- = Settling once
--
-- 'requestSettlement' is a single-assignment slot. 'applyReply' fills it if it
-- is empty and refuses otherwise, and a refused reply never overwrites what is
-- there. Every refused reply is counted in 'requestLateReplies', because a
-- provider replying twice is evidence about that provider whether or not
-- anyone was listening.
--
-- A refused reply still /retires the provider's work/. A provider that
-- answered has finished, even if the answer arrived after we cancelled or
-- after an epoch change revoked our interest, so the late answer retires the
-- accounting without publishing its stale value and without changing the
-- settled local outcome. That is the one case in this module where a rejection
-- also changes the record, and it is why a cancelled request does not hold
-- capacity forever.
--
-- = Cancellation
--
-- 'cancelLocally' settles the local waiter and revokes interest. It leaves
-- 'requestProviderOutstanding' alone, because P-7 is explicit that cancelling
-- is not proof native work ended and borrowed dependencies stay owned until it
-- does. 'revokeInterest' is the same settlement for an invalidation — an
-- epoch change, a session failure, a stop — except that it also discards the
-- result, since the owner that would have observed it no longer exists.
module Hetoimasia.Scripting.Lua.Internal.Protocol.Request
  ( -- * Settlement
    CancelCause (..)
  , Settlement (..)
  , SettlementKind (..)
  , settlementKind
  , Reply (..)
  , replySettlement

    -- * The record
  , RequestRecord (..)
  , openRequest
  , requestReclaimable
  , requestSettled

    -- * Rejections
  , ReplyRejection (..)
  , ObserveRejection (..)
  , ProviderRejection (..)

    -- * Operations
  , applyReply
  , cancelLocally
  , revokeInterest
  , Revocation (..)
  , observeSettlement
  , completeProviderWork
  ) where

import Data.Maybe (fromMaybe)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Failure (FailureReason)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity (EndpointId, RequestId, TaskId)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Value (Payload)

-- | Why interest in a request ended without a provider answer.
data CancelCause
  = -- | The owner asked.
    CancelledByOwner
  | -- | The owning task was invalidated.
    CancelledByTaskInvalidation
  | -- | The session's epoch changed under it.
    CancelledByEpochChange
  | -- | The session failed unsafely.
    CancelledBySessionFailure
  | -- | The session stopped.
    CancelledByStop
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | What a request settled as. Written once.
data Settlement v
  = SettledResult !(Payload v)
  | SettledFailure !FailureReason
  | SettledCancelled !CancelCause
  deriving (Eq, Show)

-- | A settlement without its value, for records that report dispositions.
data SettlementKind
  = KindResult
  | KindFailure
  | KindCancelled
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The kind of a settlement.
settlementKind ∷ Settlement v → SettlementKind
settlementKind (SettledResult _) = KindResult
settlementKind (SettledFailure _) = KindFailure
settlementKind (SettledCancelled _) = KindCancelled

-- | What a provider may send.
--
-- A provider answers with a result or a failure. It cannot send a
-- cancellation: cancelling is the owner's act, and giving a provider a way to
-- report one would blur the distinction this model exists to keep.
data Reply v
  = ReplyResult !(Payload v)
  | ReplyFailure !FailureReason
  deriving (Eq, Show)

-- | The settlement a reply would write.
replySettlement ∷ Reply v → Settlement v
replySettlement (ReplyResult message) = SettledResult message
replySettlement (ReplyFailure reason) = SettledFailure reason

-- | One accepted request.
data RequestRecord v = RequestRecord
  { requestIdentity ∷ !RequestId
  , requestOwner ∷ !TaskId
  , requestEndpoint ∷ !EndpointId
  , requestSettlement ∷ !(Maybe (Settlement v))
  , requestResultHeld ∷ !Bool
  , requestProviderOutstanding ∷ !Bool
  , requestLateReplies ∷ !Int
  , requestLateCompletions ∷ !Int
  }
  deriving (Eq, Show)

-- | Accept a request: empty slot, storage reserved, provider work outstanding.
openRequest ∷ RequestId → TaskId → EndpointId → RequestRecord v
openRequest identity owner endpoint =
  RequestRecord
    { requestIdentity = identity
    , requestOwner = owner
    , requestEndpoint = endpoint
    , requestSettlement = Nothing
    , requestResultHeld = True
    , requestProviderOutstanding = True
    , requestLateReplies = 0
    , requestLateCompletions = 0
    }

-- | Whether both obligations are discharged and the record may be forgotten.
requestReclaimable ∷ RequestRecord v → Bool
requestReclaimable record =
  not (requestResultHeld record) && not (requestProviderOutstanding record)

-- | Whether the slot has been written.
requestSettled ∷ RequestRecord v → Bool
requestSettled record = case requestSettlement record of
  Just _ → True
  Nothing → False

-- | Why a reply was refused.
newtype ReplyRejection
  = -- | The slot already holds this kind of settlement. Nothing was
    -- overwritten; the reply was counted, and it retired the provider's work.
    ReplyAlreadySettled SettlementKind
  deriving (Eq, Show)

-- | Why a settlement could not be observed.
data ObserveRejection
  = -- | Nothing has settled yet.
    ResultUnsettled
  | -- | The storage reservation is already released: observed, or discarded by
    -- an invalidation.
    ResultNotHeld
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Why provider completion was refused.
data ProviderRejection
  = -- | The provider's work was already known to have ended. Counted.
    ProviderAlreadyComplete
  | -- | The request has not settled, so \"the work ended\" has no answer to
    -- go with it. A provider that finished should reply; this changes nothing.
    ProviderStillAwaitingReply
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Apply a provider's reply.
--
-- A first reply settles the slot and retires the provider's work, because an
-- answer is evidence the work ended. A later, duplicate, or stale reply is
-- refused and counted, overwrites nothing, and still retires the work.
applyReply ∷ Reply v → RequestRecord v → (RequestRecord v, Either ReplyRejection ())
applyReply reply record = case requestSettlement record of
  Just settled →
    ( record
        { requestLateReplies = requestLateReplies record + 1
        , requestProviderOutstanding = False
        }
    , Left (ReplyAlreadySettled (settlementKind settled))
    )
  Nothing →
    ( record
        { requestSettlement = Just (replySettlement reply)
        , requestProviderOutstanding = False
        }
    , Right ()
    )

-- | Cancel at the owner's request.
--
-- Settles the local waiter so the owner can observe that its request ended,
-- and leaves provider accounting outstanding. A request cancelled after it
-- settled is refused and counted like any other late settlement attempt.
cancelLocally ∷ CancelCause → RequestRecord v → (RequestRecord v, Either ReplyRejection ())
cancelLocally cause record = case requestSettlement record of
  Just settled → (record, Left (ReplyAlreadySettled (settlementKind settled)))
  Nothing → (record {requestSettlement = Just (SettledCancelled cause)}, Right ())

-- | What an invalidation did to a request.
data Revocation = Revocation
  { revokedUnsettled ∷ !Bool
  -- ^ Whether the revocation is what settled it.
  , revokedResult ∷ !Bool
  -- ^ Whether a held result reservation was discarded.
  , revokedProviderOutstanding ∷ !Bool
  -- ^ Whether the provider's work is still unaccounted for afterwards.
  }
  deriving (Eq, Show)

-- | Revoke interest because the owner is gone.
--
-- Settles an unsettled slot as cancelled, discards whatever result storage was
-- held — nobody is left to observe it — and leaves provider accounting exactly
-- as it was. The record survives if and only if the provider's work is still
-- outstanding, which is how an invalidated request stays accounted for without
-- becoming an unbounded history.
revokeInterest ∷ CancelCause → RequestRecord v → (RequestRecord v, Revocation)
revokeInterest cause record =
  ( record
      { requestSettlement = Just (fromMaybe (SettledCancelled cause) (requestSettlement record))
      , requestResultHeld = False
      }
  , Revocation
      { revokedUnsettled = not (requestSettled record)
      , revokedResult = requestResultHeld record
      , revokedProviderOutstanding = requestProviderOutstanding record
      }
  )

-- | Observe the settlement, releasing its storage reservation.
--
-- Releases storage and nothing else: a cancelled request whose cancellation
-- has been observed still holds its provider accounting.
observeSettlement
  ∷ RequestRecord v
  → Either ObserveRejection (Settlement v, RequestRecord v)
observeSettlement record
  | not (requestResultHeld record) = Left ResultNotHeld
  | otherwise = case requestSettlement record of
      Nothing → Left ResultUnsettled
      Just settled → Right (settled, record {requestResultHeld = False})

-- | Apply explicit evidence that the provider's work ended.
--
-- The only thing that releases provider accounting other than a reply. It
-- leaves the settlement and the storage reservation untouched, so applying it
-- to a cancelled request whose cancellation nobody has observed keeps the
-- record alive for that observation.
completeProviderWork ∷ RequestRecord v → (RequestRecord v, Either ProviderRejection ())
completeProviderWork record
  | not (requestSettled record) = (record, Left ProviderStillAwaitingReply)
  | not (requestProviderOutstanding record) =
      ( record {requestLateCompletions = requestLateCompletions record + 1}
      , Left ProviderAlreadyComplete
      )
  | otherwise = (record {requestProviderOutstanding = False}, Right ())
