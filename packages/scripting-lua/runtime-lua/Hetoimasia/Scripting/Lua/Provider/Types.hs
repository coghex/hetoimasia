-- | What the provider service is made of: the grant an application gives an owner, the
-- surface a provider implements, the answers a provider is given, and the state one
-- owner's requests live in.
--
-- This is a hidden module. "Hetoimasia.Scripting.Lua.Provider" is the application's and
-- the provider's view of it, and "Hetoimasia.Scripting.Lua.Request" is a binding author's.
-- Nothing here runs anything: "Hetoimasia.Scripting.Lua.Provider.State" holds the
-- transactions over this state, and "Hetoimasia.Scripting.Lua.Provider.Serve" what the
-- owner's thread does with it.
--
-- = The state, and who touches it
--
-- One 'PState' per owner, in one variable, so every change is a single transaction and an
-- invariant is a property of a step and not of an interleaving. Three kinds of thread
-- change it, and none of them waits for another:
--
-- * a /binding's action/, on the callback thread of the Lua call it serves, admits,
--   cancels, reads and takes requests;
-- * a /provider/, on any thread, completes a request through the 'Completion' it was
--   handed, which is one transaction that writes the request's reserved slot and never
--   waits;
-- * the /owner's thread/ serves what is due at a tick, wakes the waiters whose requests
--   have settled, polls the providers' retirements and ends a requester's holdings.
--
-- The application's thread advances the epoch.
--
-- = A request, in this state
--
-- A request has a record the script can reach ('Rec', until its settlement is taken or
-- its requester ends) and, apart from it, the accounting of the provider's work ('Work',
-- until the provider has proved the work over and its dependencies are disposed of). They
-- are separate because they end separately: a script that takes a cancellation has not
-- stopped the provider, and a provider that finished has not told the script anything.
-- The protocol model's own record for the request ('RequestRecord') carries the same two
-- obligations and is what decides when the capacity a request holds is free again.
module Hetoimasia.Scripting.Lua.Provider.Types
  ( -- * The grant
    RequestGrant (..)
  , requestGrant
  , defaultRequestBound
  , maxRequestBound
  , RequestTiming (..)
  , DueSlot (..)
  , RequestInfo (..)
  , AssignRequest
  , RequestGrantViolation (..)
  , RequestGrantRefused (..)

    -- * What a provider implements
  , RequestEndpoint (..)
  , Submission (..)
  , ProviderWork (..)
  , Completion (..)
  , ProviderReply (..)
  , ReplyAnswer (..)

    -- * Refusals a script reads
  , RequestRefusal (..)
  , renderRequestRefusal

    -- * Who asks
  , Requester (..)

    -- * The state
  , Ticks (..)
  , ProviderState (..)
  , PState (..)
  , Rec (..)
  , Work (..)
  , ProviderCounts (..)
  , noCounts
  , ProviderDiagnostics (..)
  ) where

import Control.Concurrent.STM (STM, TVar)
import Control.Exception (Exception, ExceptionWithContext, SomeException)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Scripting.Lua.Instance.Types (InstanceId, Instances)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity (Epoch, RequestId, TaskId)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Request (CancelCause, Reply, Settlement)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session (ExitRecord, Session)
import Hetoimasia.Scripting.Lua.Retention (Retained, RetirementState)
import Hetoimasia.Scripting.Lua.Runtime.Types (OwnerId)
import Hetoimasia.Scripting.Lua.Value (Schema, Value, ValueLimits)

-- The grant ------------------------------------------------------------------------

-- | What an application grants one owner so that its scripts can make asynchronous
-- requests of providers (P-7).
--
-- The grant is the whole of the authority: an owner created with none keeps the
-- not-yet-supported fault every asynchronous request answered before this slice, with
-- its action never run, whichever registration it was given. It names the providers'
-- endpoints, bounds what is outstanding and says when a settlement reaches Lua.
data RequestGrant = RequestGrant
  { grantEndpoints ∷ [RequestEndpoint]
    -- ^ The providers the owner's scripts may ask, each by its own name, once.
  , grantRequestBound ∷ !Int
    -- ^ How many requests the owner holds at once. A request holds its place from its
    -- admission until its result has been taken or discarded /and/ its provider has
    -- proved its work over, so a settled result nobody has taken counts, and so does a
    -- cancelled request whose provider has not finished. At least one.
  , grantTiming ∷ !RequestTiming
    -- ^ When a settlement reaches Lua.
  }

-- | A grant of these endpoints with the default bound, settling on arrival.
requestGrant ∷ [RequestEndpoint] → RequestGrant
requestGrant endpoints = RequestGrant endpoints defaultRequestBound SettleOnArrival

-- | Thirty-two requests.
defaultRequestBound ∷ Int
defaultRequestBound = 32

-- | The most requests one owner may be granted at once.
maxRequestBound ∷ Int
maxRequestBound = 65536

-- | When a settlement reaches Lua.
data RequestTiming
  = -- | On arrival: an owner on elapsed time. A reply settles the request at once, the
    -- first settlement wins, and the waiter resumes at the next safe boundary after it.
    SettleOnArrival
  | -- | At the tick the application assigned (D-36): an owner on logical time. Each
    -- request is given, at admission, the tick its settlement is due; a reply that
    -- arrives earlier is held and is no settlement; the tick does not begin until the
    -- request is complete; and a cancel before the tick always wins (D-39). The
    -- assignment is the application's policy, and 'Nothing' for it is the next tick.
    SettleAtAssignedTick !(Maybe AssignRequest)

-- | The place a request's settlement takes in a logical owner's input sequence: the
-- tick whose boundary delivers it, and its place among the requests due then. Settlements
-- reach Lua in the order of (tick, sequence), whatever order the replies arrived in.
data DueSlot = DueSlot
  { dueTick ∷ !Word64
  , dueSequence ∷ !Word64
  }
  deriving (Eq, Ord, Show)

-- | What the application is told of a request when it assigns its place: all of it the
-- engine's own knowledge, none of it a value a script supplied.
data RequestInfo = RequestInfo
  { infoOwner ∷ !OwnerId
  , infoInstance ∷ !(Maybe InstanceId)
    -- ^ The instance whose code made the request; 'Nothing' for a task.
  , infoEndpoint ∷ !Text
  , infoNumber ∷ !Word64
    -- ^ The request's number, which is unique to its owner and never reissued.
  }
  deriving (Eq, Show)

-- | The application's assignment of a request to a tick (D-23, D-36): run on the
-- caller's thread, before the request is admitted, and never to block. 'Nothing' refuses
-- the request as unassigned. What it raises is a failure of the host.
type AssignRequest = RequestInfo → IO (Maybe DueSlot)

-- | Why a grant was refused.
data RequestGrantViolation
  = -- | The bound is below one or above 'maxRequestBound': what was given.
    RequestBoundOutOfRange !Int
  | -- | No endpoint at all: nothing could be asked.
    NoEndpoints
  | -- | An endpoint name that is not a valid name.
    InvalidEndpointName !Text
  | -- | The same endpoint named twice.
    DuplicateEndpoint !Text
  | -- | An endpoint whose result schema names a capability, which is a VM's.
    EndpointResultCapability !Text
  deriving (Eq, Show)

-- | A grant was refused, and nothing was made. Every violation.
newtype RequestGrantRefused = RequestGrantRefused (NonEmpty RequestGrantViolation)
  deriving (Eq, Show)

instance Exception RequestGrantRefused

-- What a provider implements --------------------------------------------------------

-- | A provider's surface for requests, by name: how a request is handed to it, and the
-- shape of what it answers.
data RequestEndpoint = RequestEndpoint
  { endpointName ∷ !Text
    -- ^ A name of the kind bindings have: 1 to 64 ASCII letters, digits and underscores.
  , endpointResult ∷ !Schema
    -- ^ What a result must conform to. A result that does not is the provider's failure:
    -- it settles the request as a failure, and the value is never retained. No capability.
  , endpointSubmit ∷ Submission → IO ProviderWork
    -- ^ Hand a request to the provider. It must not block, and it answers through the
    -- 'Completion' it is given, from any thread, now or later. What it raises is a failure
    -- of application code: a failure of the host under the owner's policy, unconverted,
    -- and the request is taken back as though it had never been admitted.
  }

-- | A request, as the provider is handed it.
data Submission = Submission
  { submissionArguments ∷ [Value]
    -- ^ The bounded copies the binding passed.
  , submissionCompletion ∷ !Completion
    -- ^ How the provider answers.
  , submissionInfo ∷ !RequestInfo
  }

-- | What the engine holds of a provider's work on one request, so that interest in it can
-- end and its end can be proved.
data ProviderWork = ProviderWork
  { workCancel ∷ IO ()
    -- ^ Withdraw the engine's interest: called once, on any path that ends it (a script's
    -- cancel, the requester's end, an epoch change, the owner's stop). It is not proof the
    -- work ended, and the engine does not treat it as such. What it raises is a failure of
    -- application code.
  , workRetirement ∷ STM RetirementState
    -- ^ The provider's own reading of where its work has got to, polled after interest was
    -- withdrawn: 'Hetoimasia.Scripting.Lua.Retention.ProviderPending' until it can prove
    -- the work over, then 'Hetoimasia.Scripting.Lua.Retention.ProviderComplete', or
    -- 'Hetoimasia.Scripting.Lua.Retention.ProviderFailed'. It must not retry. A reply the
    -- provider has made is proof as well, and needs no reading.
  }

-- | How a provider answers one request. One transaction behind it, which writes the
-- request's reserved slot or holds the answer, and never waits for the owner, a queue
-- or Lua: a provider's thread is never made to wait by a full owner.
newtype Completion = Completion {completeRequest ∷ ProviderReply → IO ReplyAnswer}

-- | What a provider answers.
data ProviderReply
  = -- | A result. Bounded by the owner's value limits and checked against the endpoint's
    -- schema before it is retained.
    ProviderResult !Value
  | -- | The provider's own failure, returned to the script as data.
    ProviderFailure !Text
  deriving (Eq, Show)

-- | What became of an answer. Never an error: a duplicate, late or stale answer is evidence
-- about the provider and is counted, and it still retires the provider's work.
data ReplyAnswer
  = -- | It settled the request.
    ReplySettled
  | -- | The owner settles at assigned ticks: the answer is held as the provider's
    -- completion, and is no settlement until its tick.
    ReplyHeld
  | -- | It was refused for its size or its shape, and the request settles as a failure
    -- instead; the value was not retained.
    ReplyRefusedValue
  | -- | The request had settled already, or its completion was already held. Counted;
    -- nothing was overwritten.
    ReplyLate
  | -- | No such request: of a replaced epoch, taken back, or never issued. Counted.
    ReplyUnknown
  deriving (Eq, Show)

-- Refusals --------------------------------------------------------------------------

-- | Why the engine refused to admit a request. Each is an answer the script reads as a
-- fault of its call, never a failure of the host.
data RequestRefusal
  = -- | No instance's code and no task's segment is running: nobody to read the answer.
    NoRequester
  | -- | The owner, or the instance, is not taking requests: it is stopping or has exited.
    RequestsClosed
  | -- | The application's assignment declined to place the request.
    RequestUnassigned
  | -- | The tick assigned is one the owner has begun.
    RequestLate
  | -- | The place assigned is taken.
    RequestDuplicatePlace
  | -- | Every place is held: the bound.
    RequestsFull !Int
  | -- | The handle is another requester's.
    NotTheRequester
  | -- | The handle names no request: its settlement was taken, its requester ended, or it
    -- was never issued.
    RequestEnded
  deriving (Eq, Show)

-- | A refusal as the reason a script reads.
renderRequestRefusal ∷ RequestRefusal → Text
renderRequestRefusal = \case
  NoRequester → "request refused: no instance or task is running to receive the answer"
  RequestsClosed → "request refused: the owner is no longer taking requests"
  RequestUnassigned → "request refused: the application assigned it no place"
  RequestLate → "request refused: the tick assigned to it has begun"
  RequestDuplicatePlace → "request refused: the place assigned to it is taken"
  RequestsFull bound → "request refused: all " <> Text.pack (show bound) <> " places are held"
  NotTheRequester → "request refused: the handle belongs to another requester"
  RequestEnded → "request refused: the handle names no request that is still held"

-- Who asks ---------------------------------------------------------------------------

-- | Who owns a request's interest. Never a script's claim: it is read from what the
-- owner is running.
data Requester
  = -- | An instance, which owns its requests across its invocations until it ends.
    RequesterInstance !Word64
  | -- | A task of the owner that is no instance's invocation, which owns them until it
    -- ends.
    RequesterTask !TaskId
  deriving (Eq, Ord, Show)

-- The state --------------------------------------------------------------------------

-- | What the provider service needs of the owner's scheduler, so that it names none: the
-- tick, the need that a tick not begin, the owner's watch on a tick, whether producers
-- are admitted, whether a task is gone, and waking the tasks that wait for a request.
data Ticks = Ticks
  { ticksNow ∷ STM Word64
  , ticksHold ∷ Word64 → STM ()
  , ticksRelease ∷ Word64 → STM ()
  , ticksWatch ∷ Word64 → STM ()
  , ticksOpen ∷ STM Bool
  , ticksTaskGone ∷ TaskId → STM Bool
  , ticksWaiting ∷ (Word64 → STM Bool) → STM Bool
    -- ^ Whether a task is waiting, and not paused, for a request this says has settled.
  , ticksWakeSettled ∷ (Word64 → STM Bool) → STM Bool
    -- ^ Wake every task waiting for a request this says has settled, in the order their
    -- waits began.
  , ticksWakeOrdered ∷ [Word64] → STM Bool
    -- ^ Wake the tasks waiting for these requests, in this order.
  }

-- | One owner's provider service.
data ProviderState = ProviderState
  { psOwner ∷ !OwnerId
  , psLabel ∷ !Text
  , psLimits ∷ !ValueLimits
  , psTiming ∷ !RequestTiming
  , psEndpoints ∷ !(Map Text RequestEndpoint)
  , psTicks ∷ !Ticks
  , psInstances ∷ !(Maybe Instances)
  , psTask ∷ !(TVar (Maybe TaskId))
    -- ^ The task whose segment the owner is running, set around each segment by the
    -- owner's own thread: who a call from a task that is no instance's was made by.
  , psVar ∷ !(TVar PState)
  }

-- | Everything one owner's requests are.
data PState = PState
  { pSession ∷ !(Session Value)
    -- ^ The protocol model's session: identities, slots, settlement, late replies, epochs.
  , pRecs ∷ !(Map RequestId Rec)
  , pByNumber ∷ !(Map Word64 RequestId)
  , pWork ∷ !(Map RequestId Work)
  , pHolders ∷ !(Map Requester TaskId)
    -- ^ The model's holder for each requester that has made a request this epoch.
  , pClosing ∷ !(Set TaskId)
    -- ^ The tasks whose coroutines are being closed: their closing handlers run script code
    -- after the stop began, and a stopping requester is not taking requests.
  , pDue ∷ !(Map DueSlot RequestId)
    -- ^ The logical requests whose tick has not been served, by their places.
  , pNext ∷ !Word64
    -- ^ The next request number. Never rewinds.
  , pClosed ∷ !Bool
    -- ^ Set once the owner has exited: nothing is admitted or answered after it.
  , pCounts ∷ !ProviderCounts
  , pExit ∷ !(Maybe ExitRecord)
  }

-- | A request, as a script can reach it.
data Rec = Rec
  { recNumber ∷ !Word64
  , recIdentity ∷ !RequestId
  , recRequester ∷ !Requester
  , recEndpoint ∷ !Text
  , recSchema ∷ !Schema
    -- ^ What a result must conform to: the endpoint's.
  , recDue ∷ !(Maybe DueSlot)
  , recHeld ∷ !(Maybe (Reply Value))
    -- ^ The provider's completion, held until the request's tick: no settlement yet.
  , recGated ∷ !(Maybe Word64)
    -- ^ The tick this request keeps from beginning, until it is complete.
  , recEnded ∷ !(Maybe (Settlement Value, CancelCause))
    -- ^ How an epoch change settled it, for its script to take: the model's record was
    -- discarded with the epoch.
  }

-- | The accounting of a provider's work on one request.
data Work = Work
  { workNumber ∷ !Word64
  , workRequester ∷ !Requester
  , workLabel ∷ !Text
  , workProvider ∷ !(Maybe ProviderWork)
    -- ^ Nothing until the provider has accepted the request.
  , workWantsCancel ∷ !Bool
    -- ^ Interest was withdrawn: the provider is to be told, once, as soon as it can be.
  , workCancelClaimed ∷ !Bool
    -- ^ Telling it has been claimed by a thread, so no other tells it again.
  , workEnded ∷ !Bool
    -- ^ The provider has proved the work over: it replied, or its retirement is complete.
  , workFailure ∷ !(Maybe (ExceptionWithContext SomeException))
    -- ^ Its retirement, or the disposal of what it needed, failed. Retained; nothing is
    -- retried, and nothing is reported as reclaimed.
  , workRetained ∷ !Retained
    -- ^ The retained obligation (the provider's own reading of its retirement) and, behind
    -- it, what the work needed: disposed of once the work is over and never if it failed.
  }

-- | Evidence the service keeps that the protocol model has no counter for.
data ProviderCounts = ProviderCounts
  { countAdmitted ∷ !Int
  , countRefused ∷ !Int
  , countHeld ∷ !Int
    -- ^ Completions held for their tick.
  , countDuplicateHeld ∷ !Int
    -- ^ Completions that found one held already: counted, never replacing it.
  , countLateCancels ∷ !Int
    -- ^ Cancels that found the request settled already.
  , countSettledAtTick ∷ !Int
  , countCancelledBeforeTick ∷ !Int
  , countEpochCancelled ∷ !Int
  }
  deriving (Eq, Show)

-- | Nothing happened yet.
noCounts ∷ ProviderCounts
noCounts = ProviderCounts 0 0 0 0 0 0 0 0

-- | A reading of the service, taken in one transaction.
data ProviderDiagnostics = ProviderDiagnostics
  { rdEpoch ∷ !Epoch
  , rdOutstanding ∷ !Int
    -- ^ Requests holding a place: the model's records, stubs for provider work included.
  , rdHeldNow ∷ !Int
    -- ^ Completions held and not yet served.
  , rdWorkPending ∷ !Int
    -- ^ Provider work not yet proved over.
  , rdWorkFailed ∷ !Int
  , rdAdmitted ∷ !Int
  , rdRefused ∷ !Int
  , rdHeldTotal ∷ !Int
  , rdDuplicateHeld ∷ !Int
  , rdLateCancels ∷ !Int
  , rdLateReplies ∷ !Int
    -- ^ Replies that found the request settled already.
  , rdUnknownReplies ∷ !Int
  , rdOversize ∷ !Int
  , rdLateCompletions ∷ !Int
  , rdInvalidated ∷ !Int
  , rdDiscardedResults ∷ !Int
  , rdSettledAtTick ∷ !Int
  , rdCancelledBeforeTick ∷ !Int
  , rdEpochCancelled ∷ !Int
  }
  deriving (Eq, Show)
