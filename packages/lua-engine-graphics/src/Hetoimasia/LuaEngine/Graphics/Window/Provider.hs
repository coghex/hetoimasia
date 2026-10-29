-- | The window provider (LFE-18): asynchronous creation and retirement of instance-owned windows.
--
-- A presentation instance asks for one visible window with 'startWindow' (the typed endpoint the
-- eventual graphics facade, LFE-21, binds as @api.window.open@), gets a pending request, and later
-- receives its owned window resource once the window's graphics setup has been admitted and a scene
-- can be published to it. The provider needs no Lua cooperation to retain ownership or to clean up:
-- it creates, attaches, observes, closes and retires on its own pump thread and on the process main
-- thread's owner-loop turns, whether or not the script ever polls, takes or loses its request.
--
-- = What it is made of
--
-- * The /provider/ ('withWindowProvider') is the session's. It owns every record below and one pump
--   worker; its scope ends only after every window it made has retired.
-- * A /window owner/ ('newWindowOwner') is one UI instance's single window slot. The slot is held
--   from admission until the window's /actual/ retirement (native destruction /and/ graphics
--   retirement), whether the window is pending, live or retiring.
-- * An /acquisition/ is one accepted request's native window and every fact about it. It exists from
--   admission until the pump returns its slot.
-- * The /port/ ("Hetoimasia.LuaEngine.Graphics.Window.Port") is the only way anything native is
--   asked or read.
--
-- = Admission
--
-- One atomic admission (the host's @startAdmitted@) reserves, before anything native is asked: the
-- request and result records and their places, the result lease capacity, the instance's one window
-- slot and one of the provider's bounded work records. A slot that is occupied is a /permanent/
-- refusal (an ordinary Lua error, decided first so a full temporary bank never hides it); a full
-- records bank is the host's busy answer, with nothing reserved, no command and no hidden retry.
-- Once accepted, pressure downstream (the host's command queue, a deferred announcement) keeps the
-- accepted work pending; it never becomes a refusal or an unbounded queue.
--
-- = The state machine of an acquisition
--
-- @
-- Queued ──issue──▶ Issued ──created──▶ Open(ToAttach) ──attach (main thread)──▶ Open(Attached)
--    │                 │                                                              │
--    │                 └─ refused clean ▶ window_error                  standing usable│
--    │                                                                               ▼
--    └─ cancelled before issuance ▶ retired            Open(Admitted)  ──offered──▶ adopted by the lease
--
-- every Open state ──(cancel | instance end | session stop | refusal)──▶ close begun ──▶ retired
-- @
--
-- /Retired/ means two outcomes, observed separately: graphics use and the attachment retired, and the
-- native window destroyed. A close ticket, a cancellation acknowledgement, a worker exit or the end
-- of a CPU scope is neither. Only retirement returns the slot, so a failed or uncertain release
-- keeps the slot, is recorded and fatal, and is never attempted again.
--
-- = Close: user versus cleanup
--
-- A genuine native close request, read from the window's own observation, is routed to the session's
-- idempotent stop endpoint, from the window's creation until its retirement and whatever the
-- cleanup is doing meanwhile. The provider never clears a request and never counts the close it
-- begins itself, a window's closing phase or its end as a user's wish, so ending one instance never
-- ends a healthy peer.
--
-- = Faults
--
-- A clean, verified refusal (a native creation refused with a clean rollback; a target the owner
-- rolled back with nothing remaining) is the expected @window_error@. Cancellation, stop and cleanup
-- outcomes are never errors of the window. Everything else (an interrupted command, retained
-- rollback evidence, an uncertain release, a failed owner) is /fatal/: it is latched once and handed
-- to 'windowFatal', and it never becomes @window_error@, busy or a retry.
module Hetoimasia.LuaEngine.Graphics.Window.Provider
  ( -- * The provider
    WindowConfig (..)
  , WindowProvider
  , withWindowProvider
  , providerFatal
  , WindowDefect (..)
  , ProviderReading (..)
  , providerReading

    -- * One UI instance's slot
  , WindowOwner
  , WindowRole (..)
  , newWindowOwner
  , closeWindowOwner
  , ownerSlotHeld
  , ownerNumber

    -- * The service
  , WindowService
  , windowService
  , windowEndpointName
  , windowEndpoint
  , windowCodes
  , windowHandleType
  , windowResultSchema
  , windowValueSchema

    -- * Asking
  , WindowAsk (..)
  , askWindow
  , WindowStart (..)
  , startWindow
  , windowArgumentCheck

    -- * The process main thread
  , windowMainStep
  , windowMainReady

    -- * The result
  , WindowResource (..)
  , withWindowOr
  ) where

import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , newTVar
  , newTVarIO
  , orElse
  , readTVar
  , retry
  , throwSTM
  , writeTVar
  )
import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException (SomeAsyncException)
  , SomeException
  , fromException
  , mask
  , rethrowIO
  , throwIO
  , toException
  , tryWithContext
  )
import Control.Monad (forM_, unless, void, when)
import Data.ByteString (ByteString)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Typeable (Typeable)
import Data.Unique (Unique, newUnique)
import Data.Word (Word64)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Resource (acquirePart, composeCleanup, releaseRank)
import qualified Hetoimasia.Foundation.Resource as Resource
import Hetoimasia.Foundation.Worker
  ( GroupReport (reportDrained, reportExitedBeforeClosing, reportObservedFailures)
  , Result (Cancelled, Failed, Succeeded)
  , StartOutcome (StartRejected, Started, StartupFailed)
  , StopToken
  , closeWorkerGroup
  , startWorker
  , stopRequested
  , withWorkerGroup
  , workerDefinition
  , completionCleanup
  , completionLabel
  , completionResult
  )
import Hetoimasia.LuaEngine.Graphics.Window.Port
import Hetoimasia.LuaEngine.Graphics.Window.Request
  ( RequestRefusal
  , WindowRequest
  , requestHeight
  , requestTitle
  , requestWidth
  , windowRequest
  )
import Hetoimasia.LuaEngine.Request
  ( M1Ask (..)
  , M1Requests
  , M1Start (..)
  , m1Ask
  , m1ArgumentCheck
  , startM1
  )
import Hetoimasia.Scripting.Lua.Admission (Credit (..), CreditRefused (..), ExpectedFailure (..), Necessity (RequiredRequest))
import Hetoimasia.Scripting.Lua.Lease
  ( Leases
  , Ownership (InstanceOwned)
  , Retirements
  , retireAsynchronously
  , withLeaseOr
  )
import Hetoimasia.Scripting.Lua.Provider
  ( Adoption (..)
  , Completion (..)
  , ProviderReply (..)
  , ProviderWork (..)
  , ReplyAnswer (..)
  , RequestEndpoint (..)
  , RetirementState (..)
  , Submission (..)
  )
import Hetoimasia.Scripting.Lua.Registration (ArgumentCheck, RequestContext)
import Hetoimasia.Scripting.Lua.Value
  ( Schema (SCapability, SNil)
  , Value (VCapability, VInteger, VNil)
  , capability
  )
import Numeric.Natural (Natural)

-- The configuration ----------------------------------------------------------------------------------

-- | What an assembly chooses for a provider.
data WindowConfig = WindowConfig
  { windowRecords ∷ !Int
    -- ^ The accepted-work records the provider holds at once, from admission until the host returns the
    -- request's record: the temporary bank whose exhaustion is the host's busy answer. The fixed M1
    -- profile (two UI instances, one window each) needs two.
  , windowStop ∷ IO ()
    -- ^ The session's idempotent, slot-free, normal stop endpoint ('Hetoimasia.LuaEngine.Session.requestStop'
    -- with a quit). It may be called any number of times, from the pump's thread, and must not block.
  , windowFatal ∷ Fatal → IO ()
    -- ^ How a fatal fault reaches the session's terminal failure (the session's failure latch). Called
    -- once, from the pump or the main thread, and must not block.
  }

-- The state ------------------------------------------------------------------------------------------

-- | Which role an instance has, declared by the facade boundary from the instance's immutable metadata
-- and never read from Lua. A window is presentation-instance hook work.
data WindowRole = PresentationRole | LogicalRole
  deriving (Eq, Show)

-- | One UI instance's single window slot. No registry holds owners.
data WindowOwner = WindowOwner
  { ownerNumber ∷ !Word64
  , ownerRole ∷ !WindowRole
  , ownerProvider ∷ !Unique
  , ownerHeld ∷ !(TVar Bool)
  , ownerOpen ∷ !(TVar Bool)
  }

instance Eq WindowOwner where
  a == b = ownerHeld a == ownerHeld b

-- | Whether the owner's one window slot is occupied: pending, live or retiring.
ownerSlotHeld ∷ WindowOwner → STM Bool
ownerSlotHeld = readTVar . ownerHeld

-- | The request's holdings: its owner's slot and its provider record, each held at most once.
data Charge = Charge
  { chargeOwner ∷ !WindowOwner
  , chargeSlot ∷ !(TVar Bool)
  , chargeRecord ∷ !(TVar Bool)
  }

-- | Why an acquisition is being taken apart.
data EndCause
  = -- | The request's interest was withdrawn (the script cancelled, the requester ended, the owner stopped).
    EndCancelled
  | -- | The instance ended, or released the lease.
    EndInstance
  | -- | The session is stopping, or the provider's scope is closing.
    EndStopped
  | -- | The target was refused (a clean rollback) or an error was answered: the window's native part
    -- still has to be taken apart.
    EndRefused
  | -- | A fatal fault: the window is still taken apart, with the fault's evidence kept.
    EndFault
  deriving (Eq, Show)

-- | How far a native window has got.
data Phase
  = -- | Accepted; no native command has been issued.
    Queued
  | -- | A creation command is in the host's queue.
    Issued !CreateToken
  | -- | The native window exists and is tracked.
    Open !WindowToken !Progress
  | -- | No native window exists and none will: nothing native is owed.
    Over
  deriving (Eq, Show)

-- | Where an open window is in its graphics setup.
data Progress
  = -- | Needs the process main thread to hand it to the graphics owner.
    ToAttach
  | -- | Handed over (or its announcement is deferred): waiting for the owner's admission.
    Attached !Bool
  deriving (Eq, Show)

-- | One accepted request's native window.
data Acq = Acq
  { aOwner ∷ !WindowOwner
  , aCharge ∷ !Charge
  , aRequest ∷ !WindowRequest
  , aCompletion ∷ !Completion
  , aPhase ∷ !Phase
  , aEnd ∷ !(Maybe EndCause)
  , aBegun ∷ !Bool
    -- ^ The close was begun (accepted by the host, or the host no longer serves the window).
  , aAnswered ∷ !Bool
    -- ^ The completion was claimed: a terminal answer was made, once.
  , aOffered ∷ !Bool
    -- ^ A success was offered to the host and the provider's ownership is waiting on its adoption.
  , aAdopted ∷ !Bool
    -- ^ The lease built the resource: the lease owns it.
  , aRouted ∷ !Natural
    -- ^ The newest genuine close request already routed to the stop endpoint.
  , aRetired ∷ !Bool
    -- ^ Graphics use and native destruction both observed.
  , aRetireFailed ∷ !(Maybe Fatal)
    -- ^ A retirement failure: recorded, fatal, never attempted twice, never frees the slot.
  , aWait ∷ !(Maybe (STM ()))
    -- ^ Until this returns, the acquisition waits on the hosts' bounded progress (a full command queue):
    -- read in the pump's own transaction, so the pump wakes when the progress changes and no other
    -- acquisition waits behind it.
  }

-- | A request admitted by the host, between its prepared holdings and its record.
data Prepared = Prepared
  { prepToken ∷ !Word64
  , prepCharge ∷ !Charge
  , prepRequest ∷ !WindowRequest
  }

data PState = PState
  { psOpen ∷ !Bool
  , psNext ∷ !Word64
  , psRecords ∷ !Int
  , psPrepared ∷ !(Map Word64 Prepared)
  , psAcqs ∷ !(Map Word64 Acq)
  , psFatal ∷ !(Maybe Fatal)
  , psEvidence ∷ ![Fatal]
  , psEscalated ∷ !Bool
  , psPumpFailure ∷ !(Maybe (ExceptionWithContext SomeException))
  , psOwners ∷ !Word64
  }

-- | The provider of one session.
data WindowProvider target = WindowProvider
  { wpConfig ∷ !WindowConfig
  , wpPort ∷ !(Port target)
  , wpState ∷ !(TVar PState)
  , wpIdentity ∷ !Unique
  , wpAdoption ∷ !(Word64 → WindowToken → target → Adoption)
    -- ^ How a lease adopts a window, made where the target's type is known to be 'Typeable'.
  }

-- | A defect of the provider itself or of what it was handed, never a content failure.
newtype WindowDefect = WindowDefect Text
  deriving (Eq, Show)

instance Exception WindowDefect

-- The scope ------------------------------------------------------------------------------------------

-- | Run a body over a provider of this port. The scope's exit closes admission, ends every acquisition
-- that is not yet the lease's /and/ every one that is (a shutdown hook that never ran cannot suppress
-- the engine's cleanup), and then waits, in STM and outside any uninterruptible release, until every
-- window has retired or failed to. A cancellation delivered meanwhile is remembered and raised after
-- the drain.
withWindowProvider ∷ ∀ target a. Typeable target ⇒ WindowConfig → Port target → (WindowProvider target → IO a) → IO a
withWindowProvider config port body
  | windowRecords config < 1 = throwIO (WindowDefect "a provider needs at least one work record")
  | otherwise = withWorkerGroup $ \group → do
      var ← newTVarIO (PState True 0 0 Map.empty Map.empty Nothing [] False Nothing 0)
      identity ← newUnique
      let provider = WindowProvider config port var identity (adoptionFor var)
      result ← mask $ \restore → do
        outcome ← tryWithContext @SomeException $ restore $ do
          started ← startWorker group (workerDefinition "window-provider-pump" (\_ → pure ()) (\token () → pump provider token))
          case started of
            Started _ → pure ()
            StartupFailed _ _ → throwIO (WindowDefect "the window provider's pump did not start")
            StartRejected _ → throwIO (WindowDefect "the window provider's pump was not accepted")
          body provider
        closed ← tryWithContext @SomeException (closeAndDrain provider)
        kept ← latchedEvidence provider
        case (outcome, closed) of
          (Right value, Right ()) → pure (Right value)
          (Right _, Left closing) → Left <$> withEvidence closing kept
          (Left primary, Right ()) → Left <$> withEvidence primary kept
          (Left primary, Left closing) → Left <$> withEvidence primary (("window provider close", closing) : kept)
      case result of
        Left failure → rethrowIO failure
        Right value → do
          report ← closeWorkerGroup group
          pumped ← atomically (psPumpFailure <$> readTVar var)
          case pumped of
            Just failure → rethrowIO failure
            Nothing →
              unclean report >>= \case
                Nothing → pure value
                Just failure → rethrowIO failure

-- | The first fatal fault the provider latched, if any.
providerFatal ∷ WindowProvider target → STM (Maybe Fatal)
providerFatal provider = psFatal <$> readTVar (wpState provider)

-- | What a provider holds, for evidence and for tests.
data ProviderReading = ProviderReading
  { readingRecords ∷ !Int
  , readingAcquisitions ∷ !Int
  , readingPrepared ∷ !Int
  , readingOpen ∷ !Bool
  , readingEvidence ∷ ![Fatal]
  }
  deriving (Eq, Show)

providerReading ∷ WindowProvider target → STM ProviderReading
providerReading provider = do
  st ← readTVar (wpState provider)
  pure (ProviderReading (psRecords st) (Map.size (psAcqs st)) (Map.size (psPrepared st)) (psOpen st) (psEvidence st))

-- One UI instance ------------------------------------------------------------------------------------

-- | The owner of one UI instance's window slot, from the instance's immutable metadata.
newWindowOwner ∷ WindowProvider target → WindowRole → IO WindowOwner
newWindowOwner provider role = atomically $ do
  st ← readTVar (wpState provider)
  when (psOwners st == maxBound) $ throwSTM (WindowDefect "the window owner numbers are exhausted")
  writeTVar (wpState provider) st {psOwners = psOwners st + 1}
  WindowOwner (psOwners st) role (wpIdentity provider) <$> newTVar False <*> newTVar True

-- | Stop taking requests for this owner (its instance is ending). Releases nothing: its window is
-- retired by its lease, or by the provider if the lease never adopted it.
closeWindowOwner ∷ WindowOwner → IO ()
closeWindowOwner owner = atomically (writeTVar (ownerOpen owner) False)

-- The service ----------------------------------------------------------------------------------------

-- | The window service of one VM's facade: the request policy and the session's provider.
data WindowService target = WindowService
  { serviceRequests ∷ !M1Requests
  , serviceProvider ∷ !(WindowProvider target)
  }

-- | The service over this request policy and provider.
windowService ∷ M1Requests → WindowProvider target → WindowService target
windowService = WindowService

-- | The endpoint's name in a grant.
windowEndpointName ∷ Text
windowEndpointName = "window"

-- | The one failure code of an expected window failure.
windowCodes ∷ [Text]
windowCodes = ["window_error"]

-- | The capability type name of a window lease's handle: register it over the instance's 'Leases'.
windowHandleType ∷ Text
windowHandleType = "window"

-- | What the endpoint answers: nothing beside the lease's handle, which the host composes in.
windowResultSchema ∷ Schema
windowResultSchema = SNil

-- | What @take@ hands as a success value, once the lease's handle is composed in: the window handle
-- itself, not a table.
windowValueSchema ∷ Schema
windowValueSchema = SCapability windowHandleType

-- Asking ---------------------------------------------------------------------------------------------

-- | A request for a window: for which instance, and what.
data WindowAsk = WindowAsk
  { askedOwner ∷ !WindowOwner
  , askedRequest ∷ !WindowRequest
  }

-- | Validate a request's typed values before anything else: title bytes, width and height as the Lua
-- integers the binding read.
askWindow ∷ WindowOwner → ByteString → Int64 → Int64 → Either RequestRefusal WindowAsk
askWindow owner title width height = WindowAsk owner <$> windowRequest title width height

-- | What starting a window request came to.
data WindowStart
  = -- | The host's answer: accepted, or busy with nothing reserved.
    WindowStarted !M1Start
  | -- | A permanent refusal that reached the admission after the argument check passed (the owner was
    -- closed or the provider began stopping in between): nothing was reserved.
    WindowRefused !Text
  deriving (Eq, Show)

-- | Start a window request atomically: accepted, or busy with nothing reserved, no command issued and
-- no hidden retry. A slot already occupied is a permanent refusal raised by the admission as an ordinary
-- Lua error (the binding opts in to recoverable refusals), decided before any temporary bank.
startWindow ∷ HasCallStack ⇒ WindowService target → WindowAsk → RequestContext → IO WindowStart
startWindow service ask context = mask $ \restore → do
  let provider = serviceProvider service
      owner = askedOwner ask
  when (ownerRole owner /= PresentationRole) $
    throwIO (WindowDefect "window acquisition is presentation-instance hook work")
  prepared ← prepare provider owner (askedRequest ask)
  started ←
    restore
      ( startM1
          (serviceRequests service)
          (windowAsk provider prepared)
          context
          windowEndpointName
          [VInteger (fromIntegral (prepToken prepared))]
          (pure ())
      )
      `finallyForget` forget provider (prepToken prepared)
  case started of
    M1Busy _ → do
      (open, taking) ← atomically ((,) <$> (psOpen <$> readTVar (wpState provider)) <*> readTVar (ownerOpen owner))
      pure $ case refusalOf provider owner open taking of
        Just why → WindowRefused why
        Nothing → WindowStarted started
    other → pure (WindowStarted other)
  where
    finallyForget action cleanup = do
      outcome ← tryWithContext @SomeException action
      void cleanup
      either rethrowIO pure outcome

-- | The argument check of a binding that builds the request from its copied arguments: the service's
-- own permanent facts (the owner belongs to this provider and has not ended, the provider takes
-- requests, the role is a presentation instance, the instance's slot is free) and then the host's
-- (phase, exhausted numbers), decided before any action, reserving nothing. A bank that is merely
-- full is not here: that is busy.
windowArgumentCheck ∷ WindowService target → ([Value] → WindowAsk) → ArgumentCheck
windowArgumentCheck service askOf owner values = do
  let ask = askOf values
      provider = serviceProvider service
  refusal ← atomically $ do
    open ← psOpen <$> readTVar (wpState provider)
    taking ← readTVar (ownerOpen (askedOwner ask))
    held ← readTVar (ownerHeld (askedOwner ask))
    pure $ case refusalOf provider (askedOwner ask) open taking of
      Just why → Just why
      Nothing
        | held → Just "this instance already has a window"
        | otherwise → Nothing
  case refusal of
    Just why → pure (Just why)
    Nothing → m1ArgumentCheck (serviceRequests service) (const (windowBaseAsk (askedOwner ask))) owner values

-- | The service's own permanent facts, in the order they are decided.
refusalOf ∷ WindowProvider target → WindowOwner → Bool → Bool → Maybe Text
refusalOf provider owner open taking
  | ownerProvider owner /= wpIdentity provider = Just "the window owner belongs to another provider"
  | ownerRole owner /= PresentationRole = Just "window acquisition is presentation-instance hook work"
  | not taking = Just "the window owner has ended"
  | not open = Just "the window provider is stopping"
  | otherwise = Nothing

-- The ask without credits, for the permanent-refusal check that reserves nothing.
windowBaseAsk ∷ WindowOwner → M1Ask
windowBaseAsk _ =
  (m1Ask RequiredRequest "window")
    { askOffset = Nothing
    , askCodes = windowCodes
    , askLease = Just (InstanceOwned, composeWindow)
    }

windowAsk ∷ WindowProvider target → Prepared → M1Ask
windowAsk provider prepared = (windowBaseAsk (chargeOwner (prepCharge prepared))) {askCredits = requestCredits provider prepared}

composeWindow ∷ Value → Word64 → Value
composeWindow _ key = VCapability (capability windowHandleType key)

-- Holdings ------------------------------------------------------------------------------------------

prepare ∷ WindowProvider target → WindowOwner → WindowRequest → IO Prepared
prepare provider owner request = atomically $ do
  st ← readTVar (wpState provider)
  when (psNext st >= fromIntegral (maxBound ∷ Int64)) $ throwSTM (WindowDefect "the window request numbers are exhausted")
  charge ← Charge owner <$> newTVar False <*> newTVar False
  let prepared = Prepared (psNext st) charge request
  writeTVar (wpState provider) st {psNext = psNext st + 1, psPrepared = Map.insert (psNext st) prepared (psPrepared st)}
  pure prepared

-- | Drop a prepared request: after a refusal, busy or a failure, or after the submission consumed it.
forget ∷ WindowProvider target → Word64 → IO ()
forget provider token = atomically $ modifyState provider $ \st → st {psPrepared = Map.delete token (psPrepared st)}

modifyState ∷ WindowProvider target → (PState → PState) → STM ()
modifyState provider change = readTVar (wpState provider) >>= writeTVar (wpState provider) . change

-- | The credits a request reserves with its admission, in the order they are reserved: the owner and
-- provider are live (permanent), the instance's one window slot (permanent when occupied, decided before
-- any temporary bank), and a record in the provider's bounded work bank (temporary: busy).
--
-- The slot is the lease's once adopted and is returned only by the pump, at actual retirement: neither the
-- host's return of a credit nor a lease's release ever frees it. The record is the request's, returned when
-- the host returns it.
requestCredits ∷ WindowProvider target → Prepared → [Credit]
requestCredits provider prepared =
  [ Credit
      { creditName = "window owner"
      , creditReserve = do
          open ← psOpen <$> readTVar (wpState provider)
          taking ← readTVar (ownerOpen owner)
          unless open $ throwSTM (CreditRefused "the window provider is stopping")
          unless taking $ throwSTM (CreditRefused "the window owner has ended")
          pure True
      , creditRelease = \_ → pure ()
      , creditTransfers = False
      }
  , Credit
      { creditName = "window slot"
      , creditReserve = do
          held ← readTVar (ownerHeld owner)
          when held $ throwSTM (CreditRefused "this instance already has a window")
          writeTVar (ownerHeld owner) True
          writeTVar (chargeSlot charge) True
          pure True
      , creditRelease = \_ → releaseSlotIfUnused provider charge (prepToken prepared)
      , creditTransfers = True
      }
  , Credit
      { creditName = "window records"
      , creditReserve = do
          st ← readTVar (wpState provider)
          if psRecords st >= windowRecords (wpConfig provider)
            then pure False
            else do
              writeTVar (wpState provider) st {psRecords = psRecords st + 1}
              writeTVar (chargeRecord charge) True
              pure True
      , creditRelease = \_ → returnRecord provider charge
      , creditTransfers = False
      }
  ]
  where
    charge = prepCharge prepared
    owner = chargeOwner charge

returnRecord ∷ WindowProvider target → Charge → STM ()
returnRecord provider charge = do
  held ← readTVar (chargeRecord charge)
  when held $ do
    writeTVar (chargeRecord charge) False
    modifyState provider $ \st → st {psRecords = psRecords st - 1}

-- A slot whose request never reached the provider (an admission taken back, the endpoint never given the
-- request) is returned here, since no acquisition will ever retire it. One that reached the provider is the
-- pump's, at retirement.
--
-- The host returns a credit that transfers only for a request that did not end with a resource a lease built.
-- So an acquisition that is still here and was never adopted is one the host dropped (its answer was cancelled
-- or its build never ran): no lease will ever own the window, and the provider takes it apart.
releaseSlotIfUnused ∷ WindowProvider target → Charge → Word64 → STM ()
releaseSlotIfUnused provider charge token = do
  st ← readTVar (wpState provider)
  case Map.lookup token (psAcqs st) of
    Nothing → returnSlot charge
    Just acq
      | aAdopted acq → pure ()
      | otherwise → endAcq provider token EndCancelled

returnSlot ∷ Charge → STM ()
returnSlot charge = do
  held ← readTVar (chargeSlot charge)
  when held $ do
    writeTVar (chargeSlot charge) False
    writeTVar (ownerHeld (chargeOwner charge)) False

-- The endpoint --------------------------------------------------------------------------------------

-- | The endpoint a grant names. It records the accepted request as a queued acquisition and returns at
-- once: it never issues a command, opens a window or waits.
windowEndpoint ∷ WindowService target → RequestEndpoint
windowEndpoint service =
  RequestEndpoint
    { endpointName = windowEndpointName
    , endpointResult = windowResultSchema
    , endpointSubmit = submit'
    }
  where
    provider = serviceProvider service
    submit' ∷ Submission → IO ProviderWork
    submit' submission = case submissionArguments submission of
      [VInteger token] | token >= 0 → accept provider (fromIntegral token) (submissionCompletion submission)
      other → throwIO (WindowDefect (Text.pack ("the window endpoint was handed arguments it does not take: " <> show (length other) <> " arguments")))

accept ∷ WindowProvider target → Word64 → Completion → IO ProviderWork
accept provider token completion = do
  placed ← atomically $ do
    st ← readTVar (wpState provider)
    case Map.lookup token (psPrepared st) of
      Nothing → pure False
      Just prepared → do
        let charge = prepCharge prepared
            acq =
              Acq
                { aOwner = chargeOwner charge
                , aCharge = charge
                , aRequest = prepRequest prepared
                , aCompletion = completion
                , aPhase = Queued
                , aEnd = if psOpen st then Nothing else Just EndStopped
                , aBegun = False
                , aAnswered = False
                , aOffered = False
                , aAdopted = False
                , aRouted = 0
                , aRetired = False
                , aRetireFailed = Nothing
                , aWait = Nothing
                }
        writeTVar (wpState provider) st {psAcqs = Map.insert token acq (psAcqs st)}
        pure True
  unless placed $ throwIO (WindowDefect "the window endpoint was handed a request that was never prepared")
  pure
    ProviderWork
      { -- A window the lease owns is the lease's: interest in the request ending never closes a window the
        -- instance holds. The lease's release, or the provider's close, ends it.
        workCancel = atomically (leaseless >>= \ownedByLease → unless ownedByLease (endAcq provider token EndCancelled))
      , workRetirement = retirementOf provider token
      }
  where
    leaseless = maybe False aAdopted . Map.lookup token . psAcqs <$> readTVar (wpState provider)

-- | Withdraw interest in an acquisition, or begin ending it: sets the cause once. Nothing native is done.
endAcq ∷ WindowProvider target → Word64 → EndCause → STM ()
endAcq provider token cause = modifyState provider $ \st →
  st {psAcqs = Map.adjust (\acq → if isNothing (aEnd acq) then acq {aEnd = Just cause} else acq) token (psAcqs st)}

-- | The provider's reading of where an acquisition's retirement stands: it only reads.
--
-- This is the /request's/ work: it is over once the window is retired or once the lease owns it (the lease's
-- own release then carries the retirement, below).
retirementOf ∷ WindowProvider target → Word64 → STM RetirementState
retirementOf provider token = do
  st ← readTVar (wpState provider)
  pure $ case Map.lookup token (psAcqs st) of
    Just acq | aAdopted acq, isNothing (aRetireFailed acq) → ProviderComplete
    _ → settledOrPending (Map.lookup token (psAcqs st))

-- | The retirement itself: complete only when graphics use and the native window have both retired (or the
-- acquisition is gone, which only retirement causes). Used by the lease, whose slot must wait for it.
retirementIn ∷ TVar PState → Word64 → STM RetirementState
retirementIn var token = settledOrPending . Map.lookup token . psAcqs <$> readTVar var

settledOrPending ∷ Maybe Acq → RetirementState
settledOrPending = \case
  Nothing → ProviderComplete
  Just acq
    | Just (Fatal why) ← aRetireFailed acq → ProviderFailed (toException (WindowDefect why))
    | aRetired acq → ProviderComplete
    | otherwise → ProviderPending

-- The pump ---------------------------------------------------------------------------------------------

data Step
  = StepDone
  | StepProgress
  | StepIO (IO ())

pump ∷ ∀ target. WindowProvider target → StopToken → IO ()
pump provider token = mask $ \restore → do
  outcome ← tryWithContext @SomeException (restore loop)
  case outcome of
    Right () → pure ()
    Left caught → do
      atomically (modifyState provider (\st → st {psPumpFailure = Just (fromMaybe caught (psPumpFailure st))}))
      latchFatal provider (Fatal "the window provider's pump failed and advances nothing again")
      rethrowIO caught
  where
    loop = atomically (nextStep provider token) >>= \case
      StepDone → pure ()
      StepProgress → loop
      StepIO act → do
        outcome ← tryWithContext @SomeException act
        case outcome of
          Right () → loop
          Left caught@(ExceptionWithContext _ raised)
            | Just (SomeAsyncException _) ← fromException raised → rethrowIO caught
            | otherwise → latchFatal provider (Fatal (Text.pack ("a window provider step failed: " <> show raised))) >> loop

-- | The next thing for the pump, in one transaction: the first acquisition with something to do, or a
-- wait on every variable read, or a stop once nothing is owed.
nextStep ∷ ∀ target. WindowProvider target → StopToken → STM Step
nextStep provider token = do
  st ← readTVar (wpState provider)
  failure ← portOwnerFailure (wpPort provider)
  case failure of
    Just found | isNothing (psFatal st) → latchSTM provider found >> pure StepProgress
    _
      -- A fatal fault is handed to the session once, by the pump, whoever recorded it and on whichever thread.
      | Just found ← psFatal st, not (psEscalated st) → do
          writeTVar (wpState provider) st {psEscalated = True}
          pure (StepIO (windowFatal (wpConfig provider) found))
      | otherwise → go st (Map.toAscList (psAcqs st))
  where
    go st [] = do
      stopping ← stopRequested token
      if stopping && Map.null (psAcqs st) then pure StepDone else retry
    go st ((key, acq) : rest) =
      stepOf provider key acq >>= \case
        Just step → pure step
        Nothing → go st rest

-- | What one acquisition needs next, if anything. Every read that decides it is in the same
-- transaction as the write that follows, so no outcome is observed twice or missed.
stepOf ∷ ∀ target. WindowProvider target → Word64 → Acq → STM (Maybe Step)
stepOf provider key acq
  | aRetired acq = do
      -- Actual retirement: the only moment the slot is returned and the acquisition forgotten.
      returnSlot (aCharge acq)
      modifyState provider $ \st → st {psAcqs = Map.delete key (psAcqs st)}
      pure (Just StepProgress)
  | isJust (aRetireFailed acq) = pure Nothing
  | otherwise = case aPhase acq of
      Queued
        | isJust (aEnd acq) → retireOver >> pure (Just StepProgress)
        | otherwise → gated (pure (Just (StepIO (issue provider key acq))))
      Issued ticket →
        portCreateOutcome port ticket >>= \case
          Nothing → pure Nothing
          Just outcome → Just <$> created outcome
      Open tok progress → openStep tok progress
      Over -> retireOver >> pure (Just StepProgress)
  where
    port = wpPort provider
    -- A request held back by a full host queue waits for the queue's progress without holding up any other.
    gated proceed = case aWait acq of
      Nothing → proceed
      Just waiting →
        (waiting >> putAcq provider key acq {aWait = Nothing} >> pure (Just StepProgress)) `orElse` pure Nothing
    retireOver = putAcq provider key acq {aPhase = Over, aRetired = True}
    created = \case
      Created tok → do
        putAcq provider key acq {aPhase = Open tok ToAttach}
        pure (StepIO (portWakeMain port))
      CreateRefusedClean why
        | wanted acq && not (aAnswered acq) → do
            putAcq provider key acq {aPhase = Over, aAnswered = True, aRetired = True}
            pure (StepIO (answerFailure acq why))
        | otherwise → retireOver >> pure StepProgress
      CreateNotExecuted → retireOver >> pure StepProgress
      CreateFatal found → latchSTM provider found >> retireOver >> pure StepProgress
    openStep tok progress = do
      requested ← portCloseRequest port tok
      if requested > aRouted acq
        then pure (Just (StepIO (route provider key requested)))
        else case aEnd acq of
          Just _ → closing tok
          Nothing → admitting tok progress
    -- Cleanup: begin the close once, then read the two retirement outcomes separately.
    closing tok
      | not (aBegun acq) = gated (pure (Just (StepIO (beginClose provider key tok))))
      | otherwise =
          portRetirement port tok >>= \reading → case reading of
            Retirement (GraphicsRetireFailed found) _ → failRetire found
            Retirement _ (NativeDisposalFailed found) → failRetire found
            _
              | retirementComplete reading → putAcq provider key acq {aRetired = True} >> pure (Just StepProgress)
              | otherwise → pure Nothing
    failRetire found = do
      latchSTM provider found
      putAcq provider key acq {aRetireFailed = Just found}
      pure (Just StepProgress)
    admitting tok progress = case progress of
      ToAttach → pure Nothing
      Attached _ →
        portStanding port tok >>= \case
          StandingPending → pure Nothing
          StandingUsable
            | aAnswered acq → pure Nothing
            | otherwise →
                portTarget port tok >>= \case
                  Nothing → pure Nothing
                  Just target → do
                    putAcq provider key acq {aAnswered = True, aOffered = True}
                    pure (Just (StepIO (publish provider key tok target)))
          StandingRefusedClean why
            | aAnswered acq → ended EndRefused
            | otherwise → do
                putAcq provider key acq {aAnswered = True, aEnd = Just EndRefused}
                pure (Just (StepIO (answerFailure acq why)))
          StandingEnded → ended EndStopped
          StandingFatal found → latchSTM provider found >> ended EndFault
    ended cause = do
      putAcq provider key acq {aEnd = Just (fromMaybe cause (aEnd acq))}
      pure (Just StepProgress)

wanted ∷ Acq → Bool
wanted = isNothing . aEnd

putAcq ∷ WindowProvider target → Word64 → Acq → STM ()
putAcq provider key acq = modifyState provider $ \st → st {psAcqs = Map.insert key acq (psAcqs st)}

-- | Issue the creation command, and track its token in the same masked step that learns it: an
-- uncollected command ticket never becomes an untracked window.
issue ∷ WindowProvider target → Word64 → Acq → IO ()
issue provider key acq = mask $ \restore → do
  let request = aRequest acq
  issued ← restore (portIssueCreate (wpPort provider) (requestTitle request) (requestWidth request) (requestHeight request))
  case issued of
    CreateIssued ticket → atomically (updateAcq provider key (\current → current {aPhase = Issued ticket}))
    CreateQueueFull -> do
      -- Pressure: the accepted request stays queued, bounded, and is issued again when the queue changes.
      wait ← atomically (portProgress (wpPort provider))
      atomically (updateAcq provider key (\current → current {aWait = Just wait}))
    CreateClosed → atomically (updateAcq provider key (\current → current {aEnd = Just (fromMaybe EndStopped (aEnd current))}))
    CreateFault found → do
      atomically (latchSTM provider found >> updateAcq provider key (\current → current {aEnd = Just EndFault}))

updateAcq ∷ WindowProvider target → Word64 → (Acq → Acq) → STM ()
updateAcq provider key change = modifyState provider $ \st → st {psAcqs = Map.adjust change key (psAcqs st)}

-- | Route a genuine close request to the session's idempotent stop endpoint, then remember the newest
-- number routed. A request already routed is never routed twice, and one not yet routed is never lost.
route ∷ WindowProvider target → Word64 → Natural → IO ()
route provider key number = do
  windowStop (wpConfig provider)
  atomically (updateAcq provider key (\acq → acq {aRouted = max number (aRouted acq)}))
  -- The stop closes admission: every acquisition still wanted is the session's to end.
  atomically (closeAdmission provider)

closeAdmission ∷ WindowProvider target → STM ()
closeAdmission provider = modifyState provider $ \st → st {psOpen = False}

-- | Begin the close of an open window, once.
beginClose ∷ WindowProvider target → Word64 → WindowToken → IO ()
beginClose provider key tok =
  portBeginClose (wpPort provider) tok >>= \case
    CloseBegun → mark
    CloseGone → mark
    CloseQueueFull → do
      wait ← atomically (portProgress (wpPort provider))
      atomically (updateAcq provider key (\acq → acq {aWait = Just wait}))
    CloseFault found → atomically (latchSTM provider found) >> mark
  where
    mark = atomically (updateAcq provider key (\acq → acq {aBegun = True}))

-- | Answer the request with a clean @window_error@: once, with bounded text and no root or path.
answerFailure ∷ Acq → Text → IO ()
answerFailure acq why =
  void (completeRequest (aCompletion acq) (ProviderExpected (ExpectedFailure "window_error" (Text.take 2048 why) Nothing Nothing)))

-- | Offer the success: the resource is built into the lease the request reserved, bound to this
-- window's incarnation and the instance's owner, on the owner's thread at its next boundary.
publish ∷ WindowProvider target → Word64 → WindowToken → target → IO ()
publish provider key tok target = do
  acq ← atomically (Map.lookup key . psAcqs <$> readTVar (wpState provider))
  case acq of
    Nothing → pure ()
    Just found → do
      answer ← completeRequest (aCompletion found) (ProviderResource VNil (wpAdoption provider key tok target))
      case answer of
        ReplyAdoption → pure ()
        ReplySettled → pure ()
        ReplyHeld → pure ()
        -- The host did not take it (cancelled first, stale, defective): the provider keeps the window and
        -- takes it apart; a late or defective answer is never delivered.
        _ → atomically $ updateAcq provider key (\current → current {aOffered = False, aEnd = Just (fromMaybe EndCancelled (aEnd current))})

-- The result ---------------------------------------------------------------------------------------

-- | The resource a lease holds for a window: opaque to the instance, bound to one window incarnation and
-- one owner. It carries the capability to publish a scene to that window and nothing native: no control,
-- input reader or disposal authority.
data WindowResource target = WindowResource
  { resourceTarget ∷ !target
  , resourceToken ∷ !WindowToken
  , resourceOwner ∷ !WindowOwner
  }

-- | Borrow a live window for the action, as the later scene adapter's check does: refused, before the
-- action, as bounded text when the lease has ended, is another instance's or holds another type.
withWindowOr ∷ (HasCallStack, Typeable target) ⇒ Leases → Word64 → (Text → IO r) → (WindowResource target → IO r) → IO r
withWindowOr = withLeaseOr'

withLeaseOr' ∷ (HasCallStack, Typeable target) ⇒ Leases → Word64 → (Text → IO r) → (WindowResource target → IO r) → IO r
withLeaseOr' leases key refused use = withLeaseOr leases key refused use

-- | The recipe the host runs, on the owner's thread, to build the window into the lease the request
-- reserved. Adopting marks the acquisition the lease's; releasing it (the instance ended or released the
-- lease) begins the close and hands the host the provider's own reading of the retirement. The slot is
-- returned by the pump at actual retirement, never by this release.
adoptionFor ∷ ∀ target. Typeable target ⇒ TVar PState → Word64 → WindowToken → target → Adoption
adoptionFor var key tok target =
  Adoption $ \retirements →
    acquirePart
      "window"
      (releaseRank 0)
      ( atomically $ do
          st ← readTVar var
          case Map.lookup key (psAcqs st) of
            Just acq → do
              writeTVar var st {psAcqs = Map.insert key acq {aAdopted = True, aOffered = False} (psAcqs st)}
              pure (WindowResource target tok (aOwner acq))
            Nothing → throwSTM (WindowDefect "a window was adopted that the provider no longer tracks")
      )
      (releaseResource var key retirements)

releaseResource ∷ TVar PState → Word64 → Retirements → WindowResource target → IO ()
releaseResource var key retirements _ = do
  atomically $ do
    st ← readTVar var
    writeTVar var st {psAcqs = Map.adjust (\acq → if isNothing (aEnd acq) then acq {aEnd = Just EndInstance} else acq) key (psAcqs st)}
  now ← atomically (retirementIn var key)
  case now of
    ProviderComplete → pure ()
    _ → retireAsynchronously retirements "window" (retirementIn var key)

-- The process main thread ----------------------------------------------------------------------------

-- | Whether the main thread has window work to do: a window that needs handing over, or an announcement
-- that is deferred. A turn of the owner loop reads this beside its other readiness.
windowMainReady ∷ WindowProvider target → STM Bool
windowMainReady provider = any needsMain . Map.elems . psAcqs <$> readTVar (wpState provider)

needsMain ∷ Acq → Bool
needsMain acq = isNothing (aEnd acq) && not (aRetired acq) && case aPhase acq of
  Open _ ToAttach → True
  Open _ (Attached True) → True
  _ → False

-- | One bounded main-thread step: hand over (or announce again) the windows that need it. Call it from
-- the process main thread, once per owner-loop turn. It never blocks, creates no window and repeats no
-- surface: a deferred announcement is announced again on the same attachment.
windowMainStep ∷ WindowProvider target → IO ()
windowMainStep provider = do
  work ← atomically (filter (needsMain . snd) . Map.toAscList . psAcqs <$> readTVar (wpState provider))
  forM_ work $ \(key, acq) → case aPhase acq of
    Open tok _ → do
      outcome ← portAttach (wpPort provider) tok
      -- The record says what happened, and claims the single answer, in one transaction; the answer
      -- itself runs after it.
      answer ← atomically $ case outcome of
        AttachAnnounced → updateAcq provider key (\current → current {aPhase = Open tok (Attached False)}) >> pure Nothing
        AttachDeferred → updateAcq provider key (\current → current {aPhase = Open tok (Attached True)}) >> pure Nothing
        AttachRootsPending → pure Nothing
        AttachEnded → updateAcq provider key (\current → current {aEnd = Just (fromMaybe EndStopped (aEnd current))}) >> pure Nothing
        AttachFault found → latchSTM provider found >> updateAcq provider key (\current → current {aEnd = Just EndFault}) >> pure Nothing
        AttachRefusedClean why → do
          current ← Map.lookup key . psAcqs <$> readTVar (wpState provider)
          case current of
            Just found | wanted found && not (aAnswered found) → do
              updateAcq provider key (\now → now {aAnswered = True, aEnd = Just EndRefused})
              pure (Just (answerFailure found why))
            _ → updateAcq provider key (\now → now {aEnd = Just (fromMaybe EndRefused (aEnd now))}) >> pure Nothing
      forM_ answer id
    _ → pure ()

-- Faults ---------------------------------------------------------------------------------------------

latchSTM ∷ WindowProvider target → Fatal → STM ()
latchSTM provider found = modifyState provider $ \st →
  st
    { psFatal = Just (fromMaybe found (psFatal st))
    , psEvidence = if isJust (psFatal st) then psEvidence st <> [found] else psEvidence st
    }

-- | Latch a fatal fault and hand the first to the session, once.
latchFatal ∷ WindowProvider target → Fatal → IO ()
latchFatal provider found = do
  escalate ← atomically $ do
    latchSTM provider found
    st ← readTVar (wpState provider)
    if psEscalated st
      then pure Nothing
      else do
        writeTVar (wpState provider) st {psEscalated = True}
        pure (psFatal st)
  forM_ escalate (windowFatal (wpConfig provider))

latchedEvidence ∷ WindowProvider target → IO [(Text, ExceptionWithContext SomeException)]
latchedEvidence provider = do
  st ← atomically (readTVar (wpState provider))
  pure [("window provider fault", ExceptionWithContext mempty (toException (WindowDefect why))) | Fatal why ← maybe [] pure (psFatal st) <> psEvidence st]

withEvidence ∷ ExceptionWithContext SomeException → [(Text, ExceptionWithContext SomeException)] → IO (ExceptionWithContext SomeException)
withEvidence primary [] = pure primary
withEvidence primary evidence = fromMaybe primary <$> composeCleanup (Just primary) evidence

-- Close and drain --------------------------------------------------------------------------------------

closeAndDrain ∷ WindowProvider target → IO ()
closeAndDrain provider = do
  atomically $ modifyState provider $ \st →
    st
      { psOpen = False
      , psAcqs = Map.map (\acq → acq {aEnd = Just (fromMaybe EndStopped (aEnd acq))}) (psAcqs st)
      }
  remembered ← newIORef Nothing
  let keep caught = atomicModifyIORef' remembered (\held → (Just (fromMaybe caught held), ()))
      wait =
        tryWithContext @SomeException (atomically drained) >>= \case
          Right () → pure ()
          Left caught@(ExceptionWithContext _ raised)
            | Just (SomeAsyncException _) ← fromException raised → keep caught >> wait
            | otherwise → keep caught
      drained = do
        st ← readTVar (wpState provider)
        let owing = [() | acq ← Map.elems (psAcqs st), isNothing (aRetireFailed acq)]
        unless (null owing) retry
  wait
  readIORef remembered >>= mapM_ rethrowIO

unclean ∷ GroupReport → IO (Maybe (ExceptionWithContext SomeException))
unclean report = do
  let summaries = reportExitedBeforeClosing report <> reportDrained report <> reportObservedFailures report
      evidence =
        concat
          [ [(completionLabel found, raised) | raised ← resultFailure (completionResult found)]
            <> [(Resource.cleanupFailureLabel cleanup, Resource.cleanupFailureException cleanup) | cleanup ← completionCleanup found]
          | found ← summaries
          ]
  if null evidence
    then pure Nothing
    else do
      raised ← tryWithContext @SomeException (throwIO (WindowDefect "the window provider's pump did not exit cleanly"))
      let primary = either id (\() → ExceptionWithContext mempty (toException (WindowDefect "the window provider's pump did not exit cleanly"))) raised
      Just <$> withEvidence primary evidence
  where
    resultFailure = \case
      Succeeded () → []
      Failed raised → [raised]
      Cancelled raised → [raised]

