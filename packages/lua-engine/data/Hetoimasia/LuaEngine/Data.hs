-- | The M1 raw-data provider (LFE-10): the endpoint that answers an asynchronous request for the
-- exact bytes of an inventoried file, and the accounting that bounds what it retains.
--
-- = What it is
--
-- A script's request for data ends in a Lua byte string: the whole file, NUL and invalid UTF-8
-- and BOMs and line endings untouched, empty included. The read is a verified read of the
-- immutable inventory ("Hetoimasia.Content.ReadPool"): the buffer the worker verified is the
-- buffer the request returns, no data is cached, and a repeated request repeats the read. This
-- module adapts that pool to the request adapter of "Hetoimasia.LuaEngine.Request" and holds the
-- one thing that is M1's alone, the per-VM byte bank.
--
-- It is a /composable typed endpoint/, not a Lua API. The eventual @api.content.data(path
-- [, options])@ (LFE-12) parses its arguments into a 'DataRequest' with 'dataKey', builds its
-- binding from 'startData' beside 'dataArgumentCheck', and declares 'dataValueSchema' for the
-- common @take@. Nothing here is installed in a VM.
--
-- = What is reserved, and when
--
-- Everything a request needs from a bounded resource is reserved in the one transaction the host
-- admits the request with (as @Credit@s of its 'M1Ask'), before the provider is handed anything:
--
-- * the request and result records, and the per-instance, per-VM and owner places, are the
--   host's;
-- * for a file the inventory says is an eligible regular file, the bytes of its known length in
--   the VM's 'ByteBank' (an @8 MiB@ file takes 8 MiB of the 64 MiB, a zero-byte file nothing but a
--   record), and one slot of the shared pool's queue.
--
-- A bank without room is the host's busy answer (data, never an error), with no file work and
-- nothing left reserved. A path the inventory does not hold (absent, a directory, another case) or
-- a file over the data ceiling is /not/ busy: it is accepted with only its records and fails as
-- @not_found@ or @too_large@ without a worker, a file open or a byte reserved, even while the byte
-- bank is full. The inventory is immutable, so classifying the request when it is asked and again
-- when it is handed over cannot disagree.
--
-- = The byte bank and the buffer
--
-- The bytes charged for a request are the one allocation the verified read produces. They are
-- charged from admission, while the job waits, while a worker reads, while a finished result is
-- held for its logical tick or waits for @take@, and while a cancelled request's read is retired,
-- and they are returned only when the host returns the credit: after the result was taken or
-- discarded /and/ the provider's work is retired, at an accounted boundary of the owner and not from
-- a worker's thread. The same allocation is never charged twice; the pool imposes no bank of its own
-- on a consumer's bytes. A Lua string made by @take@ is ordinary Lua memory outside the bank. The
-- bank bounds the payload this service retains, not Lua's or the process's memory: the streaming
-- hash workspace is bounded by the reader's buffer and the number of workers.
--
-- One bank belongs to one VM and is shared by its instances; the pool and its workers are the
-- session's, shared by every VM's service. A VM that ends discards its own results and returns its
-- own bytes, and neither stops the pool nor touches another VM's bank.
--
-- = Failures
--
-- An expected failure carries one of 'dataCodes': @not_found@ (not an inventoried regular file),
-- @content_changed@ (the content is no longer what the scan pinned), @io_error@ and @too_large@, with
-- the root and path of the file and a bounded message. A defect of the reader, the pool or a
-- worker is a provider defect ('ProviderFailure'): it fails the owner at its next boundary,
-- required or optional alike, and is never given a code.
module Hetoimasia.LuaEngine.Data
  ( -- * The byte bank
    ByteBank
  , newByteBankFor
  , byteBankLimit
  , byteBankCharged
  , reserveBytes
  , returnBytes
  , ByteBankDefect (..)
  , PoolRefusal (..)
  , EndpointDefect (..)

    -- * The service
  , DataService
  , DataServiceRefused (..)
  , dataService
  , dataEndpointName
  , dataEndpoint
  , dataCodes
  , dataValueSchema
  , dataCeiling
  , dataBank

    -- * What is asked
  , dataKey
  , DataRequest (..)
  , DataFate (..)
  , dataFate
  , dataAsk
  , startData
  , dataArgumentCheck
  , dataArguments
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, readTVar, throwSTM, writeTVar)
import Control.Exception (Exception, throwIO)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import qualified Data.Text.Encoding.Error as Encoding
import Data.Word (Word64)
import GHC.Stack (HasCallStack)
import Hetoimasia.Content.Identity
  ( ContentKey
  , ReferenceRefusal
  , contentKeyPath
  , contentKeyRoot
  , logicalPathBytes
  , parseReference
  , rootKeyBytes
  )
import Hetoimasia.Content.Inventory
  ( Change (..)
  , Inventory
  , Presence (..)
  , ReadFailure (..)
  , ReadOutcome (..)
  , inspectEntry
  , inventoryIdentityLimits
  , inventoryLimitsOf
  , inventoryRootKey
  )
import Hetoimasia.Content.ReadPool
  ( CancelOutcome
  , ReadPool
  , ReadPriority (OrdinaryRead)
  , ReadRequest (..)
  , ReadResult (..)
  , SubmitRefusal (..)
  , ReadTicket
  , cancel
  , releaseSlot
  , reserveSlot
  , retired
  , submit
  )
import Hetoimasia.LuaEngine.Profile
  ( ByteLimit (DataBytes, RetainedDataBytesPerVm)
  , Bytes (Bytes)
  , Profile
  , bytesLimit
  )
import Hetoimasia.LuaEngine.Request
  ( M1Ask (..)
  , M1Requests
  , M1Start
  , m1Ask
  , m1ArgumentCheck
  , m1Profile
  , startM1
  )
import Hetoimasia.Scripting.Lua.Admission (Credit (..), Necessity)
import Hetoimasia.Scripting.Lua.Provider
  ( Completion (..)
  , ExpectedFailure (..)
  , ProviderReply (..)
  , ProviderWork (..)
  , RequestEndpoint (..)
  , RetirementState (..)
  , Submission (..)
  )
import Hetoimasia.Scripting.Lua.Registration (ArgumentCheck, RequestContext)
import Hetoimasia.Scripting.Lua.Value (Schema (SBytes), Value (VBytes))

-- The byte bank -------------------------------------------------------------------------

-- | The payload bytes one VM's data service retains: queued reservations, active read buffers,
-- held and unconsumed results, and buffers still retiring.
--
-- Owner: the VM's data service. Writers: the host's admission transaction ('creditReserve') and
-- the owner's accounted boundaries ('creditRelease'), never a worker. Readers: anyone, through
-- 'byteBankCharged'. Lifetime: the VM's service; it is never reset, and at rest it reads zero.
data ByteBank = ByteBank
  { bankLimit ∷ !Word64
  , bankCharged ∷ !(TVar Word64)
  }

-- | A bank with this much room. Private: the only bank a VM's service accepts is the profile's own
-- ('newByteBankFor'), so no production path tunes the limit.
newByteBank ∷ Word64 → IO ByteBank
newByteBank limit = ByteBank limit <$> newTVarIO 0

-- | The bank the profile gives one VM: 'RetainedDataBytesPerVm'.
newByteBankFor ∷ Profile → IO ByteBank
newByteBankFor profile = let Bytes limit = bytesLimit profile RetainedDataBytesPerVm in newByteBank limit

-- | The most the bank holds.
byteBankLimit ∷ ByteBank → Word64
byteBankLimit = bankLimit

-- | What is charged now.
byteBankCharged ∷ ByteBank → STM Word64
byteBankCharged = readTVar . bankCharged

-- | The bank's own accounting failed: a return of bytes that were not charged. An engine defect.
newtype ByteBankDefect = ByteBankDefect Text
  deriving (Eq, Show)

instance Exception ByteBankDefect

-- | Charge these bytes if they fit, in the transaction of the admission that asks (a credit's
-- reserve). Checked arithmetic: the request is compared with the room
-- left, so nothing is added that could wrap.
reserveBytes ∷ ByteBank → Word64 → STM Bool
reserveBytes bank wanted = do
  charged ← readTVar (bankCharged bank)
  if wanted > bankLimit bank - charged
    then pure False
    else True <$ writeTVar (bankCharged bank) (charged + wanted)

-- | Return bytes that were charged, once, at the end the host names (a credit's release). Returning
-- more than is charged is an engine defect and raises.
returnBytes ∷ ByteBank → Word64 → STM ()
returnBytes bank given = do
  charged ← readTVar (bankCharged bank)
  if given > charged
    then throwSTM (ByteBankDefect "bytes were returned that the bank had not been charged")
    else writeTVar (bankCharged bank) (charged - given)

-- The service ---------------------------------------------------------------------------

-- | One VM's data service over the session's pool: the policy, the inventory it answers from, the
-- shared pool, the VM's bank and the data ceiling.
data DataService = DataService
  { serviceRequests ∷ !M1Requests
  , serviceInventory ∷ !Inventory
  , servicePool ∷ !ReadPool
  , serviceBank ∷ !ByteBank
  , serviceCeiling ∷ !Word64
  }

-- | Why a service could not be made.
data DataServiceRefused
  = -- | The profile's data ceiling does not fit the machine integer a read is asked with.
    CeilingNotRepresentable !Word64
  | -- | The bank is not the profile's per-VM bank (@RetainedDataBytesPerVm@): its limit and the
    -- profile's. A larger one would admit more than the VM may retain, a smaller one less.
    BankDisagreesWithProfile !Word64 !Word64
  deriving (Eq, Show)

-- | The service of one VM. @M1Requests@ carries the validated profile whose 'DataBytes' is the
-- ceiling.
dataService ∷ M1Requests → Inventory → ReadPool → ByteBank → Either DataServiceRefused DataService
dataService requests inventory pool bank
  | ceiling' > fromIntegral (maxBound ∷ Int) = Left (CeilingNotRepresentable ceiling')
  | bankLimit bank /= retained = Left (BankDisagreesWithProfile (bankLimit bank) retained)
  | otherwise = Right (DataService requests inventory pool bank ceiling')
  where
    Bytes ceiling' = bytesLimit (m1Profile requests) DataBytes
    Bytes retained = bytesLimit (m1Profile requests) RetainedDataBytesPerVm

-- | The most bytes one file or result may have.
dataCeiling ∷ DataService → Word64
dataCeiling = serviceCeiling

-- | The VM's bank.
dataBank ∷ DataService → ByteBank
dataBank = serviceBank

-- | The endpoint's name in a grant.
dataEndpointName ∷ Text
dataEndpointName = "data"

-- | The failure codes the service supplies.
dataCodes ∷ [Text]
dataCodes = ["not_found", "content_changed", "io_error", "too_large"]

-- | What @take@ hands as a success value: the whole file as a byte string.
dataValueSchema ∷ Schema
dataValueSchema = SBytes

-- What is asked ---------------------------------------------------------------------------

-- | The key a reference names in this service's root: the checked-address boundary. A malformed
-- reference is a permanent argument error, refused before any admission; it is never a content
-- failure.
dataKey ∷ DataService → ByteString.ByteString → Either ReferenceRefusal ContentKey
dataKey service =
  parseReference
    (inventoryIdentityLimits (inventoryLimitsOf (serviceInventory service)))
    (inventoryRootKey (serviceInventory service))

-- | A request for data: the file, whether its expected failure fails the instance, and a logical
-- owner's tick offset (positive; 'Nothing' is the default of one).
data DataRequest = DataRequest
  { requestedKey ∷ !ContentKey
  , requestedNecessity ∷ !Necessity
  , requestedOffset ∷ !(Maybe Word64)
  }

-- | What the inventory says will become of a request, decided from the immutable inventory
-- alone.
data DataFate
  = -- | An eligible regular file of this length: reserve its bytes and a queue slot, and read.
    DataRead !Word64
  | -- | Not an inventoried regular file: accepted, and failed as @not_found@ without a worker.
    DataNotFound
  | -- | An inventoried file over the data ceiling, of this length: accepted, and failed as
    -- @too_large@ without a worker, a file open or a reserved byte.
    DataTooLarge !Word64
  deriving (Eq, Show)

-- | The fate of a key.
dataFate ∷ DataService → ContentKey → DataFate
dataFate service key = case inspectEntry (serviceInventory service) key of
  Absent → DataNotFound
  PresentDirectory → DataNotFound
  PresentFile len
    | len > serviceCeiling service → DataTooLarge len
    | otherwise → DataRead len

-- | The ask the host admits: the request's requirement, its source, its offset, the codes, and the
-- credits its fate needs. Pure; a request that will fail without a worker asks for no credit.
dataAsk ∷ DataService → DataRequest → M1Ask
dataAsk service request =
  (m1Ask (requestedNecessity request) ("data " <> pathText key))
    { askOffset = requestedOffset request
    , askCodes = dataCodes
    , askCredits = case dataFate service key of
        DataRead len → [bytesCredit (serviceBank service) len, slotCredit (servicePool service)]
        _ → []
    }
  where
    key = requestedKey request

-- | The two values the endpoint is handed: the root key and the NFC path, as bytes.
dataArguments ∷ DataRequest → [Value]
dataArguments request =
  [ VBytes (rootKeyBytes (contentKeyRoot (requestedKey request)))
  , VBytes (logicalPathBytes (contentKeyPath (requestedKey request)))
  ]

-- | Start a data request atomically: accepted, or busy with nothing reserved. The same ask
-- 'dataArgumentCheck' decides the permanent refusals of.
startData ∷ HasCallStack ⇒ DataService → DataRequest → RequestContext → IO () → IO M1Start
startData service request context =
  startM1 (serviceRequests service) (dataAsk service request) context dataEndpointName (dataArguments request)

-- | The argument check of a binding that builds the request from its copied arguments: the host's
-- permanent refusals (role, phase, offset, ceiling, exhausted numbers), decided before any action.
dataArgumentCheck ∷ DataService → ([Value] → DataRequest) → ArgumentCheck
dataArgumentCheck service requestOf = m1ArgumentCheck (serviceRequests service) (dataAsk service . requestOf)

-- Credits ------------------------------------------------------------------------------------

-- | The bytes of a file, charged to the VM's bank. They are the request's, returned once, when the
-- host returns the credit; they do not transfer.
bytesCredit ∷ ByteBank → Word64 → Credit
bytesCredit bank len =
  Credit
    { creditName = "data bytes"
    , creditReserve = reserveBytes bank len
    , creditRelease = \_ → returnBytes bank len
    , creditTransfers = False
    }

-- | One slot of the shared pool's queue.
slotCredit ∷ ReadPool → Credit
slotCredit pool =
  Credit
    { creditName = "io queue"
    , creditReserve = reserveSlot pool
    , creditRelease = \_ → releaseSlot pool
    , creditTransfers = False
    }

-- The endpoint --------------------------------------------------------------------------------

-- | The endpoint a grant names: it classifies the request from the inventory, answers a request
-- that fails without a worker at once, and otherwise hands the job to the pool and answers its
-- work.
dataEndpoint ∷ DataService → RequestEndpoint
dataEndpoint service =
  RequestEndpoint
    { endpointName = dataEndpointName
    , endpointResult = dataValueSchema
    , endpointSubmit = submitData service
    }

-- | Hand a request over. Never opens a file or waits for a worker.
submitData ∷ DataService → Submission → IO ProviderWork
submitData service submission = do
  key ← keyFromArguments service (submissionArguments submission)
  let complete = completeRequest (submissionCompletion submission)
  case dataFate service key of
    DataNotFound → immediate (complete (ProviderExpected (notFound key)))
    DataTooLarge len → immediate (complete (ProviderExpected (tooLarge service key len)))
    DataRead _ → do
      -- The slot was reserved with the request: a refusal here is the pool being down, which is
      -- the engine's failure and not a content failure, and the host takes the request back.
      submitted ← atomically (submit (servicePool service) (readRequest service key complete))
      case submitted of
        Left refusal → throwIO (poolRefusal refusal)
        Right ticket → pure (workOf ticket)
  where
    immediate answer = answer >> pure finishedWork

-- | The key the arguments name, or an engine defect: a binding that passed other arguments
-- broke the endpoint's contract.
keyFromArguments ∷ DataService → [Value] → IO ContentKey
keyFromArguments service = \case
  [VBytes _root, VBytes path] →
    case dataKey service path of
      Right key | rootKeyBytes (contentKeyRoot key) == _root → pure key
      Right _ → malformed "the root is not the service's"
      Left refusal → malformed ("the path was refused: " <> show refusal)
  other → malformed ("expected a root and a path, found " <> show (length other) <> " arguments")
  where
    malformed why = throwIO (EndpointDefect (Text.pack ("the data endpoint was handed arguments it does not take: " <> why)))

-- | The job for the pool: the key, the data ceiling as its allowance, the ordinary class (a raw
-- data load is never an active chain's dependency), and a sink that answers the request.
readRequest ∷ DataService → ContentKey → (ProviderReply → IO a) → ReadRequest
readRequest service key complete =
  ReadRequest
    { requestKey = key
    , requestAllowance = fromIntegral (serviceCeiling service)
    , requestPriority = OrdinaryRead
    , requestSink = \result → () <$ complete (replyOf service key result)
    }

-- | The work the engine holds: interest is withdrawn through the pool, and retirement is the pool's
-- evidence about this one job. The reading only reads.
workOf ∷ ReadTicket → ProviderWork
workOf ticket =
  ProviderWork
    { workCancel = () <$ (atomically (cancel ticket) ∷ IO CancelOutcome)
    , workRetirement = (\done → if done then ProviderComplete else ProviderPending) <$> retired ticket
    }

-- | Work with nothing to retire: the request failed without a worker.
finishedWork ∷ ProviderWork
finishedWork = ProviderWork {workCancel = pure (), workRetirement = pure ProviderComplete}

-- Replies -------------------------------------------------------------------------------------

-- | What the pool's outcome means for the request.
replyOf ∷ DataService → ContentKey → ReadResult → ProviderReply
replyOf service key = \case
  ReadSucceeded bytes → ProviderResult (VBytes bytes)
  ReadFailed (ReadFailure _ _ outcome) → ProviderExpected (failureOf service key outcome)
  ReadDefect failure → ProviderFailure (clip (Text.pack ("the data read failed: " <> show failure)))
  ReadAbandoned → ProviderFailure "the data read was abandoned: its pool ended while the request was live"

failureOf ∷ DataService → ContentKey → ReadOutcome → ExpectedFailure
failureOf service key = \case
  ReadNotFound → notFound key
  ReadTooLarge len _ → tooLarge service key len
  ReadChanged change → attributed key "content_changed" (changeText change)
  ReadIoError kind → attributed key "io_error" ("the file could not be read: " <> Text.pack (show kind))

notFound ∷ ContentKey → ExpectedFailure
notFound key = attributed key "not_found" "the path is not an inventoried file"

tooLarge ∷ DataService → ContentKey → Word64 → ExpectedFailure
tooLarge service key len =
  attributed key "too_large" ("the file is " <> Text.pack (show len) <> " bytes, over the data limit of " <> Text.pack (show (serviceCeiling service)))

changeText ∷ Change → Text
changeText = \case
  Missing → "the file is gone"
  Retyped kind → "the path no longer names a regular file: " <> Text.pack (show kind)
  LengthChanged expected found → "the length changed from " <> Text.pack (show expected) <> " to " <> Text.pack (show found)
  Truncated expected seen → "the file ended after " <> Text.pack (show seen) <> " of " <> Text.pack (show expected) <> " bytes"
  Grew expected → "the file grew past " <> Text.pack (show expected) <> " bytes"
  DigestMismatch → "the bytes are not the ones the inventory pinned"

-- | An expected failure of this file: its root and path attribute it, its message is bounded.
attributed ∷ ContentKey → Text → Text → ExpectedFailure
attributed key code message =
  ExpectedFailure
    { expectedCode = code
    , expectedMessage = message
    , expectedRoot = Just (decodeLossy (rootKeyBytes (contentKeyRoot key)))
    , expectedPath = Just (pathText key)
    }

pathText ∷ ContentKey → Text
pathText = decodeLossy . logicalPathBytes . contentKeyPath

decodeLossy ∷ ByteString.ByteString → Text
decodeLossy = Encoding.decodeUtf8With Encoding.lenientDecode

-- | Bounded text for a defect's diagnostic. The host bounds what it keeps; this keeps a huge
-- rendering from being built into a reply first.
clip ∷ Text → Text
clip = Text.take 1024

-- | A pool that cannot take a job is the engine's failure.
newtype PoolRefusal = PoolRefusal Text
  deriving (Eq, Show)

instance Exception PoolRefusal

-- | The endpoint was handed arguments its contract does not allow: a binding's defect.
newtype EndpointDefect = EndpointDefect Text
  deriving (Eq, Show)

instance Exception EndpointDefect

poolRefusal ∷ SubmitRefusal → PoolRefusal
poolRefusal = \case
  PoolIsClosed → PoolRefusal "the read pool is closed"
  PoolHasFailed failure → PoolRefusal ("the read pool has failed: " <> Text.pack (show failure))
