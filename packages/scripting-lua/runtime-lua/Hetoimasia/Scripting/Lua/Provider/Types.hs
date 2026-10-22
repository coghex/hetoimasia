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

    -- * The opt-in admission
  , Necessity (..)
  , Admission (..)
  , admission
  , Credit (..)
  , CreditEnd (..)
  , Bank (..)
  , renderBank
  , ExpectedFailure (..)
  , Adoption (..)
  , Held (..)
  , Adopting (..)
  , ProviderDefect (..)

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

    -- * Subscriptions
  , SubscriptionGrant (..)
  , subscriptionGrant
  , defaultSubscriptionBound
  , defaultStagingBound
  , maxSubscriptionBound
  , SubscriptionGrantViolation (..)
  , SubscriptionGrantRefused (..)
  , EventEndpoint (..)
  , EventSubscription (..)
  , SubscriptionInfo (..)
  , EventFeed (..)
  , EventAnswer (..)
  , SubscribeRefusal (..)
  , renderSubscribeRefusal
  , OverloadPolicy (..)

    -- * Who asks
  , Requester (..)

    -- * The state
  , Ticks (..)
  , ProviderState (..)
  , PState (..)
  , Rec (..)
  , Work (..)
  , Sub (..)
  , Staged (..)
  , EventCounts (..)
  , noEventCounts
  , SubscriptionDiagnostics (..)
  , SubscriptionReading (..)
  , workIdOf
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
import Data.Typeable (Typeable)
import Data.Word (Word64)
import Hetoimasia.Foundation.Resource (Assembly)
import Hetoimasia.Scripting.Lua.Instance.Types (InstanceId, Instances)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity (Epoch, RequestId (RequestId), RequestName (RequestName), SubscriptionId (SubscriptionId), SubscriptionName (SubscriptionName), TaskId)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Request (CancelCause, Reply, Settlement)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session (ExitRecord, Session)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Subscription (OverloadPolicy (..))
import Hetoimasia.Scripting.Lua.Internal.Protocol.Value (Payload)
import Hetoimasia.Scripting.Lua.Lease.State (Leases, Ownership, Retirements)
import Hetoimasia.Scripting.Lua.Retention (Retained, RetirementState)
import Hetoimasia.Scripting.Lua.Runtime.Types (OwnerId)
import Hetoimasia.Scripting.Lua.Value (Schema, Value (VText), ValueLimits)

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
  , infoNecessity ∷ !(Maybe Necessity)
    -- ^ Whether an expected failure of the request fails its instance. 'Nothing' for a request
    -- that did not take the opt-in admission ('Admission').
  , infoSource ∷ !(Maybe Text)
    -- ^ The attributable source context the opt-in admission recorded for the request.
  , infoOffset ∷ !(Maybe Word64)
    -- ^ The tick offset a logical request was admitted with, validated and fixed at admission.
  , infoDue ∷ !(Maybe DueSlot)
    -- ^ The place a logical request's settlement is due at, assigned once at admission.
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
  | -- | The owner's value limits cannot hold the smallest records a script is handed for a
    -- failure or a cancellation: no settlement could be delivered.
    SettlementsDoNotFit
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
    -- 'Hetoimasia.Scripting.Lua.Retention.ProviderFailed'. It must not retry, and it only reads:
    -- the engine may run it inside a transaction that has read state already, and what it
    -- writes is not kept ('Hetoimasia.Scripting.Lua.Retention.pollObligation'). It may read TVars
    -- that more than one reading shares, or that the provider's own thread writes. A reply the
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
  | -- | An expected failure of the content or service, with the code its service supplies. Only
    -- a request admitted through the opt-in 'Admission' takes it as such: its code must be
    -- one of the request's 'admitExpectedCodes', or the reply is a provider defect. A request
    -- that did not take the opt-in settles as the generic failure it would for a
    -- 'ProviderFailure' of the message.
    ProviderExpected !ExpectedFailure
  | -- | A result whose resource the instance is to own: the value, and how the engine builds
    -- the resource on the owner's thread into the lease the request reserved ('admitLease'),
    -- at the owner's next boundary. A request that reserved no lease takes it as a plain
    -- 'ProviderResult' of the value, and the recipe is never run.
    ProviderResource !Value !Adoption
  deriving (Show)

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
  | -- | The request reserved a result lease: the owner builds the resource into it on its
    -- thread at its next boundary, and only then settles (or, on logical time, holds) the
    -- result. Nothing is settled yet.
    ReplyAdoption
  | -- | A request admitted through the opt-in 'Admission' was answered with something its
    -- service did not declare: a result over the ceilings or not of the endpoint's schema, or a
    -- failure with no code the service supplies. This is a provider defect, never a
    -- result and never a failure of the request: it fails the owner, once, at its next
    -- boundary, and the work is proved over.
    ReplyDefective
  deriving (Eq, Show)

-- The opt-in admission --------------------------------------------------------------

-- | Whether an expected failure of a request fails the instance that made it (D-52): the
-- request's required or optional policy, which the service supplies.
data Necessity
  = -- | An expected failure, once it is eligible to settle, fails the instance, whether or not
    -- its script ever reads the request.
    RequiredRequest
  | -- | An expected failure is a result for the script to read.
    OptionalRequest
  deriving (Eq, Show)

-- | A bank of credit a provider declares for the requests it serves (a byte budget, a worker
-- lane), reserved with the request and returned when its lifetime ends.
--
-- The bank is the provider's: the engine reserves it inside the one transaction that admits the
-- request, so a reservation and the request are both made or neither is, and returns it exactly
-- once, at the end named by 'CreditEnd', in a transaction on the owner's thread (or, for an
-- admission taken back, on the thread that made it). Both actions run inside the engine's
-- transactions: they only read and write the provider's own variables, never retry, and
-- never run provider code that blocks.
data Credit = Credit
  { creditName ∷ !Text
    -- ^ Named in the busy answer and in evidence. Bounded to 64 characters when it is shown.
  , creditReserve ∷ STM Bool
    -- ^ Take the credit: 'True' when it was available and is now held. A bank that is full
    -- answers 'False'; whatever it wrote is undone with the rest of the admission.
  , creditRelease ∷ CreditEnd → STM ()
    -- ^ Give the credit back, once, with the reason. Never called for a credit that
    -- 'creditTransfers' and whose request succeeded with a resource.
  , creditTransfers ∷ !Bool
    -- ^ Whether a request that succeeds with a resource ('ProviderResource', adopted into its
    -- result lease) hands the credit to that resource: the provider's own release of the
    -- resource gives it back, and the engine does not. A credit that does not transfer is the
    -- request's, and is returned when the request is taken and its work is retired.
  }

-- | Why a credit is returned.
data CreditEnd
  = -- | The request was taken back before the provider was asked anything, or never reached
    -- the provider: the credit was never used.
    CreditUnused
  | -- | The request's result was taken or discarded and the provider's work on it is retired.
    CreditSettled
  deriving (Eq, Show)

-- | The bank that had no room for a request, which the answer names. Nothing was reserved.
data Bank
  = -- | The instance's accepted, unretired requests: the bound.
    BankInstanceRequests !Int
  | -- | The VM's accepted, unretired requests: the bound.
    BankVmRequests !Int
  | -- | The owner's request places (the grant's bound).
    BankOwnerRequests !Int
  | -- | The instance's lease capacity: the capacity and what is charged.
    BankLeases !Int !Int
  | -- | A provider-declared credit, by its name.
    BankCredit !Text
  deriving (Eq, Show)

-- | A bank, as the bounded diagnostic a busy answer carries.
renderBank ∷ Bank → Text
renderBank = \case
  BankInstanceRequests bound → "the instance holds all " <> Text.pack (show bound) <> " of its request places"
  BankVmRequests bound → "the VM holds all " <> Text.pack (show bound) <> " of its request places"
  BankOwnerRequests bound → "the owner holds all " <> Text.pack (show bound) <> " of its request places"
  BankLeases capacity charged → "the instance's lease capacity is charged: " <> Text.pack (show charged) <> " of " <> Text.pack (show capacity)
  BankCredit name → "the provider has no room in " <> Text.take 64 name

-- | An expected failure of the content or service a request asked for: a code the service
-- supplies, a bounded message, and for content the root and path that failed.
data ExpectedFailure = ExpectedFailure
  { expectedCode ∷ !Text
  , expectedMessage ∷ !Text
  , expectedRoot ∷ !(Maybe Text)
  , expectedPath ∷ !(Maybe Text)
  }
  deriving (Eq, Show)

-- | How the engine builds a request's resource into the lease the request reserved. Run once,
-- on the owner's thread, uninterruptibly masked as an acquisition is, at the owner's boundary
-- after the provider replied. A recipe that is never run (the request was cancelled first, its
-- requester ended) leaves the resource with the provider's own work to retire; one that
-- raises is a failure of application code, and ends the owner under its policy.
data Adoption = ∀ a. Typeable a ⇒ Adoption (Retirements → Assembly a)

instance Show Adoption where
  show _ = "Adoption"

-- | What an opt-in admission asks of the owner, beside the grant (D-52, D-53, D-54, D-67).
--
-- It is carried by one request and by nothing else: the owner's defaults, its generic
-- requests and its full-capacity behaviour (a refusal that fails the call) are unchanged.
data Admission = Admission
  { admitNecessity ∷ !Necessity
  , admitSource ∷ !Text
    -- ^ Attributable source context: what the requester asked for, recorded with the request
    -- and named when a required failure fails the instance. Bounded to 128 characters.
  , admitOffset ∷ !(Maybe Word64)
    -- ^ The tick offset of a logical request, positive; 'Nothing' is the default of one. An
    -- owner that settles on arrival refuses one that is given.
  , admitLogicalMaximum ∷ !Word64
    -- ^ The ceiling of every logical tick, offset and sequence the admission assigns.
  , admitPerInstance ∷ !Int
    -- ^ The most accepted, unretired requests one instance holds.
  , admitPerVm ∷ !Int
    -- ^ The most the owner's VM holds, across its instances.
  , admitReplyLimits ∷ !ValueLimits
    -- ^ The ceilings a reply is checked against beside the owner's: a reply past them is a
    -- provider defect ('ReplyDefective').
  , admitExpectedCodes ∷ ![Text]
    -- ^ The failure codes the request's service supplies: an expected failure with another is
    -- a provider defect.
  , admitMessageBytes ∷ !Int
    -- ^ The most UTF-8 bytes of an expected failure's message; a longer one is cut at a
    -- character, visibly.
  , admitPathBytes ∷ !Int
    -- ^ The most UTF-8 bytes of an expected failure's root or path; a longer one is a
    -- provider defect, since cutting an identity would name another.
  , admitCredits ∷ ![Credit]
    -- ^ Provider-declared credits, reserved in this order with the request.
  , admitLease ∷ !(Maybe Ownership)
    -- ^ Reserve a result lease in the instance's lease scope, to be adopted when the provider
    -- replies with a resource.
  , admitCombine ∷ !(Maybe (Value → Word64 → Value))
    -- ^ How the value a script is handed for a success holds the key of the adopted lease's
    -- handle: the service's own shape (a record carrying the handle and its dimensions, or the
    -- handle itself). 'Nothing' hands the provider's value as it is. Called with key 0 to measure
    -- the envelope at reply time, so it must not change its size with the key.
  , admitSuccessFrame ∷ Value → [(Text, Value)]
    -- ^ The record a script is handed for a success of the value: the shape the reply is
    -- measured against the owner's ceilings in. The service's own; the default is the generic
    -- result record.
  , admitFailureFrame ∷ ExpectedFailure → [(Text, Value)]
    -- ^ The record a script is handed for an expected failure: the service's own; the default is
    -- the generic failure record.
  }

-- | The shape of a success when the admission says nothing: the generic result record.
defaultSuccessFrame ∷ Value → [(Text, Value)]
defaultSuccessFrame value = [("status", VText "result"), ("value", value)]

-- | The shape of an expected failure when the admission says nothing: the generic failure
-- record, with the message as its reason.
defaultFailureFrame ∷ ExpectedFailure → [(Text, Value)]
defaultFailureFrame found = [("status", VText "failure"), ("reason", VText (expectedMessage found))]

-- | An admission with these policies, no offset, no codes, no credits and no result lease.
admission ∷ Necessity → Text → ValueLimits → Word64 → Int → Int → Admission
admission requirement source limits ceilingValue perInstance perVm =
  Admission
    { admitNecessity = requirement
    , admitSource = Text.take 128 source
    , admitOffset = Nothing
    , admitLogicalMaximum = ceilingValue
    , admitPerInstance = perInstance
    , admitPerVm = perVm
    , admitReplyLimits = limits
    , admitExpectedCodes = []
    , admitMessageBytes = 2048
    , admitPathBytes = 1024
    , admitCredits = []
    , admitLease = Nothing
    , admitCombine = Nothing
    , admitSuccessFrame = defaultSuccessFrame
    , admitFailureFrame = defaultFailureFrame
    }

-- | A provider answered a request admitted through the opt-in 'Admission' with something its
-- service did not declare. A failure of the engine's provider boundary, never an expected
-- content failure: it ends the owner under its policy, whatever the request's requirement.
newtype ProviderDefect = ProviderDefect Text
  deriving (Eq, Show)

instance Exception ProviderDefect

-- | What the service holds of an opt-in request's banks, from its admission until the request
-- is taken or discarded and the provider has retired its work. Written by admission and by
-- transactions on the owner's thread only, never by a provider's completion: that is how a
-- capacity a native thread frees reaches admission only at the owner's accounted boundary.
data Held = Held
  { heldRequester ∷ !Requester
  , heldCredits ∷ ![Credit]
    -- ^ The credits still charged.
  , heldLease ∷ !(Maybe Word64)
    -- ^ The key of the reserved result lease, until it is adopted or discharged.
  , heldRetiring ∷ !(Maybe Word64)
    -- ^ The key of a lease slot whose building failed and whose rolled-back stages are still being
    -- retired by their provider: the slot keeps its charge until they are, and the request's credits
    -- stay charged with it.
  }

-- | A provider's resource reply that the owner has yet to build into its reserved lease.
data Adopting = Adopting
  { adoptingKey ∷ !Word64
  , adoptingInstance ∷ !Word64
  , adoptingBuild ∷ !Adoption
  , adoptingValue ∷ !Value
  , adoptingBytes ∷ !Int
  , adoptingClaimed ∷ !Bool
    -- ^ The owner is building the resource now. A claimed entry stays until the building is
    -- finished or failed, so the reservation it builds into is not discharged under it, and
    -- nothing that ends the request drops it.
  }

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
  | -- | The opt-in admission is an instance's: a task is not one.
    RequestNotAnInstance
  | -- | An owner that settles on arrival takes no logical offset.
    RequestOffsetOnArrival
  | -- | The offset is not a positive integer.
    RequestOffsetInvalid
  | -- | The tick and the offset do not sum to a position within the numeric ceiling: the
    -- ceiling.
    RequestTickUnrepresentable !Word64
  | -- | The owner has issued every request number the numeric ceiling allows: the ceiling.
    RequestNumbersExhausted !Word64
  | -- | The admission reserves a result lease, and the instance has no lease scope: the
    -- owner was given no leases, or the instance is ending.
    RequestNoLeaseScope
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
  RequestNotAnInstance → "request refused: only an instance makes this request"
  RequestOffsetOnArrival → "request refused: this request settles on arrival and takes no tick offset"
  RequestOffsetInvalid → "request refused: the tick offset is not a positive integer"
  RequestTickUnrepresentable highest → "request refused: the tick and offset pass the ceiling of " <> Text.pack (show highest)
  RequestNumbersExhausted highest → "request refused: every request number up to " <> Text.pack (show highest) <> " has been issued"
  RequestNoLeaseScope → "request refused: the instance has no lease scope to reserve a result lease in"

-- Subscriptions ---------------------------------------------------------------------

-- | What an application grants one owner so that its instances can subscribe functions to
-- providers' events (LUA-26), beside the request service it is granted.
--
-- A subscription grant is made over a request grant: the owner's request service is the
-- provider service, and the owner's kind of time ('RequestTiming') is the kind of time its
-- events are admitted in. The grant is the whole of the authority: an instance's @api@ can
-- subscribe only to an endpoint the grant names and the instance was granted.
data SubscriptionGrant = SubscriptionGrant
  { grantEvents ∷ [EventEndpoint]
    -- ^ The providers' event endpoints, each by its own name, once.
  , grantSubscriptionBound ∷ !Int
    -- ^ How many subscriptions the owner holds at once. A subscription holds its place from
    -- its admission until it has ended /and/ its provider has proved its retirement, so
    -- subscribing and unsubscribing over and over cannot reclaim a place the provider has
    -- not given back. At least one.
  , grantStagingBound ∷ !Int
    -- ^ How many events an owner on logical time holds for a tick it has not reached yet. A
    -- delivery past it is refused and counted. At least one.
  }

-- | A grant of these endpoints with the default bounds.
subscriptionGrant ∷ [EventEndpoint] → SubscriptionGrant
subscriptionGrant endpoints = SubscriptionGrant endpoints defaultSubscriptionBound defaultStagingBound

-- | Thirty-two subscriptions.
defaultSubscriptionBound ∷ Int
defaultSubscriptionBound = 32

-- | Two hundred and fifty-six staged events.
defaultStagingBound ∷ Int
defaultStagingBound = 256

-- | The most subscriptions, or staged events, one owner may be granted.
maxSubscriptionBound ∷ Int
maxSubscriptionBound = 65536

-- | Why a subscription grant was refused.
data SubscriptionGrantViolation
  = -- | The bound on subscriptions is below one or above 'maxSubscriptionBound'.
    SubscriptionBoundOutOfRange !Int
  | -- | The bound on staged events is below one or above 'maxSubscriptionBound'.
    StagingBoundOutOfRange !Int
  | -- | No endpoint at all: nothing could be subscribed to.
    NoEventEndpoints
  | -- | An endpoint name that is not a valid name, or whose entry point in the driver would
    -- not be one.
    InvalidEventName !Text
  | -- | The same endpoint named twice.
    DuplicateEventName !Text
  | -- | An endpoint whose payload names a capability, which is a VM's.
    EventPayloadCapability !Text
  | -- | The owner has no request service: subscriptions are granted through it.
    SubscriptionsNeedService
  | -- | The owner hosts no instances: subscriptions are an instance's.
    SubscriptionsNeedInstances
  | -- | More event endpoints than the driver module can declare an entry point for beside
    -- the owner's event sources: how many were given, and how many fit.
    TooManyEventEndpoints !Int !Int
  deriving (Eq, Show)

-- | A subscription grant was refused, and nothing was made. Every violation.
newtype SubscriptionGrantRefused = SubscriptionGrantRefused (NonEmpty SubscriptionGrantViolation)
  deriving (Eq, Show)

instance Exception SubscriptionGrantRefused

-- | A provider's surface for events, by name: what its events are, how a subscription is
-- handed to it, and the shape of what it delivers.
data EventEndpoint = EventEndpoint
  { eventName ∷ !Text
    -- ^ A name of the kind bindings have: 1 to 64 ASCII letters, digits and underscores.
  , eventPayload ∷ !Schema
    -- ^ What every delivery must conform to. A delivery that does not is refused and counted.
    -- No capability.
  , eventPolicy ∷ !OverloadPolicy
    -- ^ What overload means for this endpoint, per P-7: 'OrderedEvents' refuses a delivery
    -- the queue has no place for, and 'ReplaceableState' keeps one unstarted delivery per
    -- subscription and replaces its value in place.
  , eventSubscribe ∷ EventSubscription → IO ProviderWork
    -- ^ Hand a subscription to the provider. It must not block, and it delivers through the
    -- 'EventFeed' it is given, from any thread, now or later. What it raises is a failure of
    -- application code: a failure of the host under the owner's policy, unconverted, and the
    -- subscription is taken back as though it had never been admitted. The 'ProviderWork' is
    -- how interest in it is later withdrawn ('workCancel', called once) and its retirement
    -- proved ('workRetirement').
  }

-- | A subscription, as the provider is handed it.
data EventSubscription = EventSubscription
  { subscriptionFeed ∷ !EventFeed
  , subscriptionInfo ∷ !SubscriptionInfo
  }

-- | What the provider is told of a subscription: all of it the engine's own knowledge, none
-- of it a value a script supplied.
data SubscriptionInfo = SubscriptionInfo
  { subscriptionOwner ∷ !OwnerId
  , subscriptionInstance ∷ !InstanceId
  , subscriptionEndpoint ∷ !Text
  , subscriptionNumber ∷ !Word64
    -- ^ The subscription's number, which is unique to its owner and never reissued.
  }
  deriving (Eq, Show)

-- | How a provider delivers to one subscription. It never blocks, never waits for the owner,
-- the queue or Lua, and a producer's thread never enters Lua: a delivery is one transaction
-- that places a reference in the instance's queue, and the owner looks up the callback when
-- it services it.
--
-- A feed is bound to the subscription it was made for. A delivery to one that has ended
-- (unsubscribed, invalidated by an epoch change, or ended with its instance) is refused and
-- counted, whatever has been subscribed since.
data EventFeed = EventFeed
  { feedDeliver ∷ Maybe DueSlot → Value → IO EventAnswer
    -- ^ Deliver a value. On an owner on elapsed time the place is 'Nothing': the delivery is
    -- admitted on arrival. On an owner on logical time the application assigns the place, the
    -- tick whose boundary admits it and its place among the events due then (D-36); a delivery
    -- with none is refused, as is one with a place on an owner on elapsed time.
  , feedFail ∷ Text → IO ()
    -- ^ The provider cannot preserve an authoritative event: it surfaces a delivery failure.
    -- The instance fails with it, once, and the application's escalation decides what that
    -- means for its peers. The reason is bounded.
  }

-- | What became of a delivery. Never an error: a refusal is evidence, counted, and the value
-- is not kept.
data EventAnswer
  = -- | Admitted on arrival, and given a place in the instance's queue.
    EventAdmitted
  | -- | Admitted on arrival, replacing the unstarted delivery of replaceable state in place.
    EventCoalesced
  | -- | Accepted for its tick, and admitted at that tick's boundary.
    EventStaged
  | -- | The instance's queue has no place for it: refused and counted, nothing evicted.
    EventQueueFull
  | -- | The owner holds as many events for ticks it has not reached as it will: refused and
    -- counted.
    EventStagingFull
  | -- | The subscription has ended, or its instance or its owner is no longer taking events:
    -- refused and counted, never run.
    EventEnded
  | -- | Over the owner's limits, not what the endpoint declares, or not evaluable: refused
    -- and counted.
    EventRefusedValue
  | -- | The tick assigned is one the owner has begun.
    EventLate
  | -- | The place assigned is taken.
    EventDuplicate
  | -- | An owner on logical time admits by an assigned place, never by arrival.
    EventUnassigned
  | -- | An owner on elapsed time admits on arrival, and takes no assigned place.
    EventNotLogical
  deriving (Eq, Show)

-- | Why the engine refused to admit a subscription. Each is an answer the script reads as a
-- fault of its call, never a failure of the host.
data SubscribeRefusal
  = -- | No instance's code is running: only an instance subscribes.
    NoSubscriber
  | -- | The owner, or the instance, is not taking subscriptions: it is stopping or has
    -- exited.
    SubscriptionsClosed
  | -- | The owner offers no such endpoint, or the instance was not granted it.
    EndpointNotGranted !Text
  | -- | Every place is held: the bound.
    SubscriptionsFull !Int
  deriving (Eq, Show)

-- | A refusal as the reason a script reads.
renderSubscribeRefusal ∷ SubscribeRefusal → Text
renderSubscribeRefusal = \case
  NoSubscriber → "subscribe refused: no instance is running to receive the events"
  SubscriptionsClosed → "subscribe refused: the instance is no longer taking subscriptions"
  -- The name is a script's, as long as the owner's limits let a string be: what is quoted is cut.
  EndpointNotGranted name → "subscribe refused: no event endpoint named " <> Text.take 64 name <> " is granted to this instance"
  SubscriptionsFull bound → "subscribe refused: all " <> Text.pack (show bound) <> " places are held"

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
  , psBound ∷ !Int
    -- ^ How many places the owner may hold.
  , psEndpoints ∷ !(Map Text RequestEndpoint)
  , psTicks ∷ !Ticks
  , psInstances ∷ !(Maybe Instances)
  , psLeases ∷ !(Maybe Leases)
    -- ^ The leases the owner's instances hold their resources through, when it was given them:
    -- what an admission reserves a result lease in.
  , psEvents ∷ !(Map Text EventEndpoint)
    -- ^ The event endpoints the owner offers, by name; none for an owner granted no subscriptions.
  , psSubscriptionBound ∷ !Int
    -- ^ How many places the owner may hold for subscriptions.
  , psStagingBound ∷ !Int
    -- ^ How many events for ticks not yet reached the owner stages.
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
    -- ^ The accounting of every provider's work: a request's, and a subscription's under the
    -- request identity its own makes ('workIdOf'), so that every path that polls, tells, disposes
    -- of and awaits provider work serves them both.
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
  , pSubs ∷ !(Map SubscriptionId Sub)
    -- ^ The subscriptions that are live, by the identity the model issued.
  , pSubNumbers ∷ !(Map Word64 SubscriptionId)
  , pStaged ∷ !(Map DueSlot Staged)
    -- ^ The events accepted for a tick not yet reached, by their places, which is their
    -- order. They are admitted at their ticks' boundaries, and never in arrival order.
  , pEvents ∷ !EventCounts
  , pNextSub ∷ !Word64
    -- ^ The next subscription number. Never rewinds.
  , pHeld ∷ !(Map RequestId Held)
    -- ^ The banks the opt-in requests hold, by request: what per-instance and per-VM admission
    -- counts. An entry leaves only in a transaction on the owner's thread ('releaseSettled').
  , pAdopting ∷ !(Map RequestId Adopting)
    -- ^ The resource replies the owner has yet to build into their leases.
  , pDefects ∷ ![Text]
    -- ^ The provider defects the owner has yet to raise, oldest first, each bounded.
  , pCleanup ∷ ![SomeException]
    -- ^ The failures of providers' credit releases on the owner's thread, oldest first, at most sixteen:
    -- cleanup evidence the owner keeps at its next boundary, fatal as any is.
  , pDiscards ∷ ![(Word64, Word64)]
    -- ^ The adopted leases, by instance and key, of requests that settled without delivering the
    -- resource to their script (cancelled, or ended by an epoch): nothing can reach them, and the
    -- owner releases them at its next boundary.
  , pForget ∷ !(Map Word64 [Word64])
    -- ^ The numbers of the subscriptions an epoch change ended, by instance, that the instance's VM
    -- still holds a callback for: the owner has its driver let go of them at its next boundary,
    -- without the script's help, and an instance that ends needs none.
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
  , recAdmission ∷ !(Maybe Admission)
    -- ^ What the opt-in admission recorded for the request, fixed at its admission and never
    -- read from anywhere a later callback could change.
  , recFailure ∷ !(Maybe ExpectedFailure)
    -- ^ The expected failure a failure settlement of an opt-in request carries.
  , recLease ∷ !(Maybe Word64)
    -- ^ The key of the result lease the admission reserved for it.
  , recAdopted ∷ !Bool
    -- ^ The resource was built into that lease: a success carries the lease, and taking it does
    -- not release it.
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
  , workSubscription ∷ !(Maybe SubscriptionId)
    -- ^ The subscription this is the work of, when it is not a request's.
  }

-- | A subscription, as the service holds it while it is live.
data Sub = Sub
  { subNumber ∷ !Word64
  , subIdentity ∷ !SubscriptionId
  , subInstance ∷ !Word64
  , subEndpoint ∷ !Text
  , subPolicy ∷ !OverloadPolicy
  , subSchema ∷ !Schema
  , subAdmitted ∷ !Int
    -- ^ Deliveries that took a place in the queue.
  , subCoalesced ∷ !Int
    -- ^ Deliveries of replaceable state that replaced the unstarted one: the value they
    -- replaced is counted here and was never delivered.
  , subRefused ∷ !Int
    -- ^ Deliveries refused for want of a place in the queue.
  , subDelivered ∷ !Int
    -- ^ Deliveries whose callback began.
  }

-- | An event accepted for a tick not yet reached.
data Staged = Staged
  { stagedSubscription ∷ !SubscriptionId
  , stagedPayload ∷ !(Payload Value)
  }

-- | What the subscription side of the service counts, by owner.
data EventCounts = EventCounts
  { evSubscribed ∷ !Int
  , evRefusedSubscribe ∷ !Int
  , evUnsubscribed ∷ !Int
  , evStaged ∷ !Int
  , evStagingFull ∷ !Int
  , evLate ∷ !Int
  , evDuplicate ∷ !Int
  , evUnassigned ∷ !Int
  , evNotLogical ∷ !Int
  , evRefusedEnded ∷ !Int
    -- ^ Deliveries refused because the subscription, its instance or the owner had ended.
  , evRefusedValue ∷ !Int
  , evRefusedFull ∷ !Int
    -- ^ Deliveries refused for want of a place in an instance's queue, on arrival or at a
    -- boundary.
  , evDiscarded ∷ !Int
    -- ^ Staged events discarded when their subscription or instance ended before their tick.
  , evFailures ∷ !Int
    -- ^ Delivery failures surfaced.
  , evCleanupJobs ∷ !Int
    -- ^ Times the owner was woken to have an instance's VM let go of callbacks an epoch change
    -- ended: once for each instance that gained a cleanup it had not been woken for.
  }
  deriving (Eq, Show)

-- | Nothing happened yet.
noEventCounts ∷ EventCounts
noEventCounts = EventCounts 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0

-- | A reading of one live subscription.
data SubscriptionReading = SubscriptionReading
  { readingNumber ∷ !Word64
  , readingInstance ∷ !Word64
  , readingEndpoint ∷ !Text
  , readingAdmitted ∷ !Int
  , readingCoalesced ∷ !Int
  , readingRefused ∷ !Int
  , readingDelivered ∷ !Int
  , readingBacklog ∷ !Int
    -- ^ Unstarted deliveries it holds.
  }
  deriving (Eq, Show)

-- | A reading of the subscription side of the service, taken in one transaction.
data SubscriptionDiagnostics = SubscriptionDiagnostics
  { sdEpoch ∷ !Epoch
  , sdLive ∷ !Int
  , sdCharged ∷ !Int
    -- ^ Places held: live subscriptions, and ended ones whose provider has not proved its
    -- retirement.
  , sdRetiring ∷ !Int
    -- ^ Subscription work not yet over.
  , sdRetirementFailed ∷ !Int
  , sdStaged ∷ !Int
  , sdSubscribed ∷ !Int
  , sdRefusedSubscribe ∷ !Int
  , sdUnsubscribed ∷ !Int
  , sdStagedTotal ∷ !Int
  , sdStagingFull ∷ !Int
  , sdLate ∷ !Int
  , sdDuplicate ∷ !Int
  , sdUnassigned ∷ !Int
  , sdNotLogical ∷ !Int
  , sdRefusedEnded ∷ !Int
  , sdRefusedValue ∷ !Int
  , sdRefusedFull ∷ !Int
  , sdDiscarded ∷ !Int
  , sdFailures ∷ !Int
  , sdCleanupJobs ∷ !Int
  , sdCoalesced ∷ !Int
    -- ^ The model's count of values replaced before they started.
  , sdInvalidated ∷ !Int
    -- ^ The model's count of subscriptions ended by an owner's end or an epoch change.
  , sdDiscardedEvents ∷ !Int
    -- ^ The model's count of unstarted deliveries discarded when their subscription ended.
  , sdSubscriptions ∷ ![SubscriptionReading]
  }
  deriving (Eq, Show)

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
  , countBusy ∷ !Int
    -- ^ Opt-in admissions that found a bank full and reserved nothing.
  , countDefects ∷ !Int
    -- ^ Replies to opt-in requests that were provider defects.
  , countLatched ∷ !Int
    -- ^ Required failures that were latched on their instances.
  , countAdopted ∷ !Int
    -- ^ Resource replies built into their reserved leases.
  }
  deriving (Eq, Show)

-- | Nothing happened yet.
noCounts ∷ ProviderCounts
noCounts = ProviderCounts 0 0 0 0 0 0 0 0 0 0 0 0

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
  , rdBusy ∷ !Int
  , rdHeld ∷ !Int
    -- ^ Opt-in requests holding their banks: what per-instance and per-VM admission counts.
  , rdHeldBy ∷ !(Map Word64 Int)
    -- ^ The same, by instance.
  , rdAdopting ∷ !Int
    -- ^ Resource replies the owner has yet to build into their leases.
  , rdDefects ∷ !Int
    -- ^ Provider defects raised or still to be raised.
  , rdLatched ∷ !Int
  , rdAdopted ∷ !Int
  }
  deriving (Eq, Show)

-- | The identity a subscription's provider work is accounted under, in the one accounting that a
-- request's is. It is the subscription's own scope, number and generation as a request identity:
-- the session issues generations from one counter it never rewinds, so no request the model issues
-- can have the same one, and the model, which knows no request by it, has nothing outstanding for
-- it.
workIdOf ∷ SubscriptionId → RequestId
workIdOf (SubscriptionId scope (SubscriptionName number) generation) = RequestId scope (RequestName number) generation
