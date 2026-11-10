-- | The injected owner of the lifecycle examples: a 'Port' whose owner, upload progression,
-- table binding and slot reclamation are each held or let go by the example, so every race of the
-- backend is driven without a device.
--
-- Evidence from this module is /injected/, and says so: it decides when the owner runs an action, when
-- an upload starts and completes, when the table binds and when a released slot is reclaimed. It proves the
-- backend's ownership transitions, ordering and cleanup, not uploaded texels or GPU readiness; the
-- separate native suite proves those on a real device.
--
-- The fake keeps what it has done (every image, every upload, its event log) for the examples to read, and none of its
-- operations looks at that history: each works from an index kept beside it (the images alive, the registered slots, the
-- uploads still open, the events newest first, the free slots in order), so the work an operation does does not depend on
-- how many images, uploads or events came before it (#679). 'fakeWork' counts it by site.
--
-- Nothing sleeps. The fake owner is one thread that waits, in STM, for something it may do that no hold
-- forbids, and an example knows what has happened by blocking in STM on the fake's own variables. Every
-- thread is started and stopped by 'withFakeOwner'.
module Test.LuaEngine.Graphics.Fake
  ( -- * The fake
    Fake
  , FakeConfig (..)
  , defaultFakeConfig
  , newFake
  , fakePort
  , fakeLedger
  , fakeWork
  , setBarrier
  , withFakeOwner
  , withFakeOwnerAs
  , latchHolds
  , ownerLoop

    -- * Holds
  , Hold (..)
  , hold
  , release
  , holdBarrier
  , holdTicket
  , releaseTicket
  , releaseAllTickets

    -- * Injections
  , Injection (..)
  , inject
  , clearInjection
  , setStanding
  , endOwner
  , setVersionHolders
  , grantOwner
  , progress

    -- * Readings
  , Reading (..)
  , readFake
  , awaitFake
  , noteEvent
  , events
  , awaitEvent
  , awaitEventCount
  , eventCount
  , imageStates
  , ImageState (..)
  ) where

import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , modifyTVar'
  , newTVar
  , newTVarIO
  , readTVar
  , readTVarIO
  , retry
  , throwSTM
  , writeTVar
  )
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM_, unless, when)
import qualified Data.ByteString as ByteString
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32)
import Hetoimasia.Asset.Image (TexelFormat (..))
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (SceneLedger, ledgerHeld, newSceneLedger)
import Hetoimasia.LuaEngine.Graphics.Texture.Port
import Test.LuaEngine.Graphics.Work
  ( CList
  , CMap
  , CSeq
  , Site (..)
  , Work
  , charge
  , clCons
  , clEmpty
  , clObserve
  , cmAdjust
  , cmDelete
  , cmEmpty
  , cmInsert
  , cmLookup
  , cmObserve
  , cmSize
  , cmToList
  , commitIO
  , csAppendList
  , csFromListInitial
  , csPopFront
  , csPush
  , newWork
  , observe
  )
import Test.Support.Owned (withOwnedThread)
import Control.Concurrent (ThreadId)

-- | What the fake owner holds back. A held stage waits until the example releases it.
data Hold
  = -- | The owner runs no action at all.
    HoldOwner
  | -- | An allocation waits inside its action.
    HoldAllocate
  | -- | A queued upload does not start.
    HoldUploadStart
  | -- | A started upload does not complete.
    HoldUploadFinish
  | -- | The table's placeholder is not bound.
    HoldBind
  | -- | A registration waits inside its action.
    HoldRegister
  | -- | A released slot is not reclaimed.
    HoldReclaim
  | -- | The release lane's barrier: the owner has not adopted the scene revisions current when a
    -- release was asked.
    HoldAdoption
  | -- | An action has run, but its outcome is not yet published to the ticket the backend reads.
    HoldOutcome
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A fault to inject, taken by the next call of the kind once (or for the count).
data Injection
  = FailAllocate !Fault
  | PressureAllocate !Int
  | FailDiscard !Fault
  | FailRegister !Fault
  | FailRelease !Fault
  | RaiseRelease
  | RaiseMark
  | AdmitPressure !Int
  | AdmitFault !AdmissionRefusal
  | LoseUploads
  | RaiseTable
  deriving (Eq, Show)

data FakeConfig = FakeConfig
  { fcActCapacity ∷ !Int
  , fcReleaseCapacity ∷ !Int
  , fcStagingBytes ∷ !Int
  , fcQueue ∷ !Int
  , fcSlots ∷ !Int
  , fcImages ∷ !Int
    -- ^ Native images alive at once; one more is 'FaultPressure'.
  , fcInitialHolds ∷ ![Hold]
    -- ^ Held from the start, before the owner's thread runs: the table binds at once otherwise.
  }

defaultFakeConfig ∷ FakeConfig
defaultFakeConfig = FakeConfig 16 16 (64 * 1024) 8 8 16 []

-- | What became of a native image.
data ImageState
  = Allocated
  | Uploaded
  | Registered !Word32
  | Discarded
  | ReleasedHandle !Word32
  deriving (Eq, Show)

data Pending = Pending
  { pendingRun ∷ Device Int → IO ()
  , pendingRefuse ∷ PortRefusal → STM ()
  , pendingGate ∷ STM Bool
    -- ^ The release lane's barrier as it stood when the request was admitted: the owner runs the action only once
    -- it reads true. An action in the other lane waits for nothing.
  }

data Upload = Upload
  { upImage ∷ !Int
  , upBytes ∷ !Int
  , upState ∷ !(TVar TicketStanding)
  }

data Fake = Fake
  { fConfig ∷ !FakeConfig
  , fStanding ∷ !(TVar Standing)
  , fHolds ∷ !(TVar (Set Hold))
  , fActs ∷ !(TVar [Pending])
  , fReleases ∷ !(TVar [Pending])
  , fEpoch ∷ !(TVar Int)
  , fEvents ∷ !(TVar (CList Text))
    -- ^ The event log, newest first.
  , fImages ∷ !(TVar (CMap Int ImageState))
  , fNextImage ∷ !(TVar Int)
  , fUploads ∷ !(TVar (CMap Int Upload))
  , fNextTicket ∷ !(TVar Int)
  , fBound ∷ !(TVar Bool)
  , fSlotsFree ∷ !(TVar (CSeq Word32))
  , fRetiring ∷ !(TVar (Set Word32))
  , fHolders ∷ !(TVar Int)
  , fMarked ∷ !(TVar (Set TextureRef))
  , fInjected ∷ !(TVar [Injection])
  , fNextGeneration ∷ !(TVar Word32)
  , fGrants ∷ !(TVar Int)
    -- ^ Actions the owner may run although 'HoldOwner' is on: one at a time, for an example that counts them.
  , fBarrier ∷ !(TVar (STM (STM Bool)))
    -- ^ What a release request captures when it is admitted (see 'setBarrier'): by default nothing, so the lane waits for
    -- 'HoldAdoption' alone.
  , fTicketHolds ∷ !(TVar (Set Int))
    -- ^ Upload tickets whose completion is held one at a time, beside the stage-wide 'HoldUploadFinish': the owner
    -- completes the other open uploads, in ticket order, and leaves these until they are let go.
  , fLedger ∷ !(SceneLedger Int)
    -- ^ The production ledger of what adopted scene revisions hold, which the fake's release is gated on exactly as
    -- the production port's is. The examples that adopt scenes drive its lifecycle hooks.
  , fLatched ∷ !(TVar Bool)
    -- ^ Set once the example's scope is stopping ('latchHolds'): from then on 'hold', 'holdTicket' and 'setVersionHolders'
    -- install nothing, so a worker that is cancelled before it installs its holds cannot reinstall them after the stop let go
    -- of every one (#599).
  , fOpen ∷ !(TVar (CMap Int Upload))
    -- ^ The uploads that are queued or uploading, by ticket: the only ones admission, the owner's loop and a reading look at.
    -- Written wherever an upload's state leaves those two (a completion, a cancellation, the owner's end).
  , fAlive ∷ !(TVar Int)
    -- ^ How many images are allocated, uploaded or registered; written only by 'setImage'.
  , fSlotOwner ∷ !(TVar (CMap Word32 Int))
    -- ^ The image each registered slot holds; written only with a registration and its release.
  , fWork ∷ !Work
  }

newFake ∷ FakeConfig → IO Fake
newFake cfg =
  Fake cfg
    <$> newTVarIO Running
    <*> newTVarIO (Set.fromList (fcInitialHolds cfg))
    <*> newTVarIO []
    <*> newTVarIO []
    <*> newTVarIO 0
    <*> newTVarIO clEmpty
    <*> newTVarIO cmEmpty
    <*> newTVarIO 0
    <*> newTVarIO cmEmpty
    <*> newTVarIO 0
    <*> newTVarIO False
    <*> newTVarIO (csFromListInitial [1 .. fromIntegral (fcSlots cfg)])
    <*> newTVarIO Set.empty
    <*> newTVarIO 0
    <*> newTVarIO Set.empty
    <*> newTVarIO []
    <*> newTVarIO 1
    <*> newTVarIO 0
    <*> newTVarIO (pure (pure True))
    <*> newTVarIO Set.empty
    <*> newSceneLedger
    <*> newTVarIO False
    <*> newTVarIO cmEmpty
    <*> newTVarIO 0
    <*> newTVarIO cmEmpty
    <*> newWork

-- | The work this fake and the backend over it have done, by site.
fakeWork ∷ Fake → Work
fakeWork = fWork

-- | Install what a release request captures at its admission: a transaction that reads the scene host's state and
-- answers the gate the owner waits on. The scene host model (the lifecycle suite's stand-in for the host's
-- ledger) installs it.
setBarrier ∷ Fake → STM (STM Bool) → IO ()
setBarrier fake capture = atomically (writeTVar (fBarrier fake) capture >> bump fake)

-- | The ledger the fake's port and device read: the production one.
fakeLedger ∷ Fake → SceneLedger Int
fakeLedger = fLedger

-- Holds and injections ---------------------------------------------------------------------------------------

hold ∷ Fake → Hold → IO ()
hold fake which = atomically (unlessLatched fake (modifyTVar' (fHolds fake) (Set.insert which)))

release ∷ Fake → Hold → IO ()
release fake which = atomically (modifyTVar' (fHolds fake) (Set.delete which) >> bump fake)

-- | Hold the completion of one upload (by the ticket its start event names) while the others complete: how an example
-- completes two open uploads in the reverse of the order they started.
holdTicket ∷ Fake → Int → IO ()
holdTicket fake ticket = atomically (unlessLatched fake (modifyTVar' (fTicketHolds fake) (Set.insert ticket)))

-- | Let one held upload complete.
releaseTicket ∷ Fake → Int → IO ()
releaseTicket fake ticket = atomically (modifyTVar' (fTicketHolds fake) (Set.delete ticket) >> bump fake)

-- | Let every held upload complete: what an example's scope does on every way out, so that a failing example never waits
-- on an upload it held.
releaseAllTickets ∷ Fake → IO ()
releaseAllTickets fake = atomically (writeTVar (fTicketHolds fake) Set.empty >> bump fake)

holdBarrier ∷ Fake → IO ()
holdBarrier fake = hold fake HoldAdoption

held ∷ Fake → Hold → STM Bool
held fake which = Set.member which <$> readTVar (fHolds fake)

inject ∷ Fake → Injection → IO ()
inject fake injection = atomically (modifyTVar' (fInjected fake) (<> [injection]))

clearInjection ∷ Fake → IO ()
clearInjection fake = atomically (writeTVar (fInjected fake) [])

setStanding ∷ Fake → Standing → IO ()
setStanding fake standing = atomically (writeTVar (fStanding fake) standing >> bump fake)

-- | The owner ends: every queued action is refused, nothing more runs.
endOwner ∷ Fake → Text → IO ()
endOwner fake why = atomically $ do
  writeTVar (fStanding fake) (Ended why)
  open ← readTVar (fOpen fake)
  forM_ (Map.elems (cmObserve open)) $ \upload → writeTVar (upState upload) TicketCancelled
  writeTVar (fOpen fake) cmEmpty
  forM_ [fActs fake, fReleases fake] $ \lane → do
    queued ← readTVar lane
    writeTVar lane []
    forM_ queued $ \pending → pendingRefuse pending (PortEnded why)
  -- No 'bump': the owner's end is readiness, not a change of the model a wake watches.

-- | The owner recorded progress that no variable of the backend's shows: a completion, a disposal.
progress ∷ Fake → IO ()
progress fake = atomically (bump fake)

-- | How many batches hold a table version that maps a released slot.
-- | Let a held owner run this many more actions, in the order they were queued, and no more.
grantOwner ∷ Fake → Int → IO ()
grantOwner fake count = atomically (modifyTVar' (fGrants fake) (+ count))

setVersionHolders ∷ Fake → Int → IO ()
setVersionHolders fake count = atomically (readTVar (fLatched fake) >>= \latched → writeTVar (fHolders fake) (if latched then 0 else count) >> bump fake)

-- | From now on no hold is installed: the stop of a scope calls this before it lets every hold go, in the same step, so a worker
-- the stop reaches before the worker has installed its holds does not install them afterwards and wait on them in a drain the
-- stop's kill cannot end. Idempotent; it never blocks.
latchHolds ∷ Fake → IO ()
latchHolds fake = atomically (writeTVar (fLatched fake) True >> bump fake)

unlessLatched ∷ Fake → STM () → STM ()
unlessLatched fake action = readTVar (fLatched fake) >>= \latched → unless latched action

bump ∷ Fake → STM ()
bump fake = modifyTVar' (fEpoch fake) (+ 1)

record ∷ Fake → Text → STM ()
record fake line = do
  seen ← readTVar (fEvents fake)
  clCons (charge (fWork fake) EventLog) line seen >>= writeTVar (fEvents fake)

-- | The first injection this predicate picks, removed.
takeInjection ∷ Fake → (Injection → Maybe a) → STM (Maybe a)
takeInjection fake pick = do
  now ← readTVar (fInjected fake)
  case [(index, found) | (index, injection) ← zip [0 ∷ Int ..] now, Just found ← [pick injection]] of
    (index, found) : _ → Just found <$ writeTVar (fInjected fake) (take index now <> drop (index + 1) now)
    [] → pure Nothing

-- | An injection that applies a number of times: decremented, removed when spent.
spend ∷ Fake → (Injection → Maybe (Int, Int → Injection)) → STM Bool
spend fake pick = do
  now ← readTVar (fInjected fake)
  case [(index, count, rebuild) | (index, injection) ← zip [0 ∷ Int ..] now, Just (count, rebuild) ← [pick injection]] of
    (index, count, rebuild) : _ → do
      let rest = take index now <> drop (index + 1) now
      writeTVar (fInjected fake) (if count > 1 then take index now <> [rebuild (count - 1)] <> drop (index + 1) now else rest)
      pure True
    [] → pure False

-- Readings -----------------------------------------------------------------------------------------------------

data Reading = Reading
  { readingImagesAlive ∷ !Int
    -- ^ Allocated, uploaded or registered images that were not discarded or released.
  , readingRegistrations ∷ !Int
    -- ^ Registered handles not released.
  , readingStagingUsed ∷ !Int
  , readingActsQueued ∷ !Int
  , readingReleasesQueued ∷ !Int
  , readingBoundNow ∷ !Bool
  , readingRetiringNow ∷ !(Set Word32)
  , readingMarkedNow ∷ !(Set TextureRef)
  , readingUploadsOpen ∷ !Int
  }
  deriving (Eq, Show)

readFake ∷ Fake → STM Reading
readFake fake = do
  alive ← readTVar (fAlive fake)
  registered ← readTVar (fSlotOwner fake)
  open ← Map.elems . cmObserve <$> readTVar (fOpen fake)
  acts ← readTVar (fActs fake)
  releases ← readTVar (fReleases fake)
  bound ← readTVar (fBound fake)
  retiring ← readTVar (fRetiring fake)
  marked ← readTVar (fMarked fake)
  pure
    Reading
      { readingImagesAlive = alive
      , readingRegistrations = cmSize registered
      , readingStagingUsed = sum (map upBytes open)
      , readingActsQueued = length acts
      , readingReleasesQueued = length releases
      , readingBoundNow = bound
      , readingRetiringNow = retiring
      , readingMarkedNow = marked
      , readingUploadsOpen = length open
      }

-- | Whether an image counts as native work alive.
aliveState ∷ ImageState → Bool
aliveState = \case
  Allocated → True
  Uploaded → True
  Registered _ → True
  Discarded → False
  ReleasedHandle _ → False

-- | Record what became of an image, keeping the count of those alive.
setImage ∷ Fake → Int → ImageState → STM ()
setImage fake image new = do
  images ← readTVar (fImages fake)
  found ← cmLookup (charge (fWork fake) ImageMap) image images
  let before = maybe 0 (fromEnum . aliveState) found
  cmInsert (charge (fWork fake) ImageMap) image new images >>= writeTVar (fImages fake)
  modifyTVar' (fAlive fake) (+ (fromEnum (aliveState new) - before))

awaitFake ∷ Fake → (Reading → Bool) → IO ()
awaitFake fake wanted = atomically $ do
  reading ← readFake fake
  unless (wanted reading) retry

-- | Add a line to the fake's event log, in order with what the fake itself records.
noteEvent ∷ Fake → Text → IO ()
noteEvent fake line = atomically (record fake line)

events ∷ Fake → IO [Text]
events fake = reverse . clObserve <$> readTVarIO (fEvents fake)

eventCount ∷ Fake → Text → IO Int
eventCount fake line = length . filter (== line) <$> events fake

-- | Block until the fake has recorded an event with this text as a prefix.
awaitEvent ∷ Fake → Text → IO ()
awaitEvent fake prefix = atomically $ do
  seen ← clObserve <$> readTVar (fEvents fake)
  unless (any (Text.isPrefixOf prefix) seen) retry

-- | Block until the fake has recorded this exact line at least this many times.
awaitEventCount ∷ Fake → Text → Int → IO ()
awaitEventCount fake line wanted = atomically $ do
  seen ← clObserve <$> readTVar (fEvents fake)
  unless (length (filter (== line) seen) >= wanted) retry

imageStates ∷ Fake → IO (Map Int ImageState)
imageStates fake = cmObserve <$> readTVarIO (fImages fake)

-- The port ------------------------------------------------------------------------------------------------------

fakePort ∷ Fake → Port Int Int
fakePort fake =
  Port
    { portStanding = readTVar (fStanding fake)
    , portAct = admit (fActs fake) (fcActCapacity cfg)
    , portRelease = admitGated (fReleases fake) (fcReleaseCapacity cfg)
    , portUpload = admitUpload fake
    , portTicket = \ticket → do
        uploads ← readTVar (fUploads fake)
        found ← cmLookup (observe (fWork fake) UploadHistory) ticket uploads
        maybe (error ("the fake has no upload " <> show ticket)) (readTVar . upState) found
    , portCancel = \ticket → do
        uploads ← readTVar (fUploads fake)
        found ← cmLookup (observe (fWork fake) UploadHistory) ticket uploads
        let upload = fromMaybe (error ("the fake has no upload " <> show ticket)) found
        readTVar (upState upload) >>= \case
          TicketQueued → do
            writeTVar (upState upload) TicketCancelled
            readTVar (fOpen fake) >>= cmDelete (observe (fWork fake) OwnerUploads) ticket >>= writeTVar (fOpen fake)
            record fake ("upload cancelled " <> tshow ticket)
            bump fake
            pure CancelledNow
          TicketUploading → pure CancelTooLate
          _ → pure CancelAlreadySettled
    , portWatch = do
        epoch ← readTVar (fEpoch fake)
        pure (readTVar (fEpoch fake) >>= \now → when (now == epoch) retry)
    , portMarkReleased = \ref → do
        raising ← takeInjection fake (\case RaiseMark → Just (); _ → Nothing)
        when (raising == Just ()) (throwSTM (userError "injected: marking the release raised"))
        modifyTVar' (fMarked fake) (Set.insert ref)
    , portHeld = ledgerHeld (fLedger fake) . textureIdentity
    }
  where
    cfg = fConfig fake
    admit ∷ ∀ a. TVar [Pending] → Int → (Device Int → IO a) → STM (Either PortRefusal (Submitted a))
    admit lane capacity = admitWith (pure (pure True)) lane capacity
    admitGated ∷ ∀ a. TVar [Pending] → Int → (Device Int → IO a) → STM (Either PortRefusal (Submitted a))
    admitGated lane capacity body = do
      capture ← readTVar (fBarrier fake)
      admitWith capture lane capacity body
    admitWith ∷ ∀ a. STM (STM Bool) → TVar [Pending] → Int → (Device Int → IO a) → STM (Either PortRefusal (Submitted a))
    admitWith capture lane capacity body =
      readTVar (fStanding fake) >>= \case
        Ended why → pure (Left (PortEnded why))
        Starting → pure (Left PortNotStarted)
        Running → do
          queued ← readTVar lane
          if length queued >= capacity
            then pure (Left PortFull)
            else do
              gate ← capture
              cell ← newTVar Nothing
              -- Queueing an action and answering it are not progress of the owner's model (the real port's wake is the
              -- model's change, and the model does not hold its action queue): a wait that woke on its own ask's
              -- answer would ask again at once, forever.
              let finish outcome = writeTVar cell (Just outcome)
                  pending =
                    Pending
                      { pendingRun = \device → do
                          outcome ← try (body device)
                          atomically (held fake HoldOutcome >>= \on → when on retry)
                          atomically (finish (either Raised Returned (outcome ∷ Either SomeException a)))
                      , pendingRefuse = finish . NotRun
                      , pendingGate = gate
                      }
              writeTVar lane (queued <> [pending])
              pure (Right (Submitted (readTVar cell)))

admitUpload ∷ Fake → Int → ByteString.ByteString → IO (Either AdmissionRefusal Int)
admitUpload fake image bytes = atomically $ do
  let cfg = fConfig fake
      size = ByteString.length bytes
  lost ← spend fake (\case LoseUploads → Just (1, const LoseUploads); _ → Nothing)
  pressured ← spend fake (\case AdmitPressure n → Just (n, AdmitPressure); _ → Nothing)
  faulty ← takeInjection fake (\case AdmitFault refusal → Just refusal; _ → Nothing)
  standing ← readTVar (fStanding fake)
  openUploads ← map snd <$> (readTVar (fOpen fake) >>= cmToList (charge (fWork fake) Admission))
  let open = length openUploads
      used = sum (map upBytes openUploads)
  case standing of
    Ended _ → pure (Left AdmissionEnded)
    _
      | Just refusal ← faulty → pure (Left refusal)
      | size > fcStagingBytes cfg → pure (Left (AdmissionFault "an upload larger than the whole staging buffer"))
      | pressured → Left AdmissionPressure <$ record fake "admission pressure"
      | open >= fcQueue cfg || used + size > fcStagingBytes cfg → Left AdmissionPressure <$ record fake "admission pressure"
      | otherwise → do
          ticket ← readTVar (fNextTicket fake)
          writeTVar (fNextTicket fake) (ticket + 1)
          state ← newTVar (if lost then TicketLost else TicketQueued)
          let upload = Upload image size state
          readTVar (fUploads fake) >>= cmInsert (charge (fWork fake) UploadHistory) ticket upload >>= writeTVar (fUploads fake)
          unless lost (readTVar (fOpen fake) >>= cmInsert (charge (fWork fake) Admission) ticket upload >>= writeTVar (fOpen fake))
          record fake ("upload admitted " <> tshow ticket <> " image " <> tshow image <> " bytes " <> tshow size)
          bump fake
          pure (Right ticket)

deviceFor ∷ Fake → Device Int
deviceFor fake =
  Device
    { deviceAllocate = \format width height → do
        atomically (held fake HoldAllocate >>= \on → when on retry)
        atomically $ do
          failure ← takeInjection fake (\case FailAllocate fault → Just fault; _ → Nothing)
          pressure ← spend fake (\case PressureAllocate n → Just (n, PressureAllocate); _ → Nothing)
          alive ← readTVar (fAlive fake)
          case failure of
            Just fault → pure (Left fault)
            Nothing
              | pressure || alive >= fcImages (fConfig fake) → Left FaultPressure <$ record fake "allocation pressure"
              | otherwise → do
                  image ← readTVar (fNextImage fake)
                  writeTVar (fNextImage fake) (image + 1)
                  setImage fake image Allocated
                  record fake ("allocated " <> tshow image <> " " <> tshow width <> "x" <> tshow height <> formatSuffix format)
                  bump fake
                  pure (Right image)
    , deviceDiscard = \image → atomically $ do
        failure ← takeInjection fake (\case FailDiscard fault → Just fault; _ → Nothing)
        setImage fake image Discarded
        record fake ("discarded " <> tshow image)
        bump fake
        pure (maybe (Right ()) Left failure)
    , deviceRegister = \image level → do
        atomically (held fake HoldRegister >>= \on → when on retry)
        atomically $ do
          failure ← takeInjection fake (\case FailRegister fault → Just fault; _ → Nothing)
          bound ← readTVar (fBound fake)
          images ← readTVar (fImages fake)
          imageNow ← cmLookup (charge (fWork fake) ImageMap) image images
          free ← readTVar (fSlotsFree fake)
          popped ← csPopFront (charge (fWork fake) FreeSlots) free
          case failure of
            Just fault → pure (Left fault)
            Nothing
              | not bound → pure (Left FaultNotReady)
              | imageNow /= Just Uploaded → pure (Left (FaultFatal ("registering image " <> tshow image <> " whose upload had not completed")))
              | Nothing ← popped → pure (Left FaultPressure)
              | Just (slot, rest) ← popped → do
                  generation ← readTVar (fNextGeneration fake)
                  writeTVar (fNextGeneration fake) (generation + 1)
                  writeTVar (fSlotsFree fake) rest
                  setImage fake image (Registered slot)
                  readTVar (fSlotOwner fake) >>= cmInsert (charge (fWork fake) SlotOwners) slot image >>= writeTVar (fSlotOwner fake)
                  record fake ("registered " <> tshow image <> " slot " <> tshow slot <> " alpha " <> tshow (levelBinaryAlpha level) <> formatSuffix (levelFormat level))
                  bump fake
                  pure (Right (Registration (TextureRef slot generation) slot))
    , deviceHeld = atomically . ledgerHeld (fLedger fake) . textureIdentity . registrationRef
    , deviceTable = do
        noteEvent fake "table read"
        raising ← atomically (takeInjection fake (\case RaiseTable → Just (); _ → Nothing))
        when (raising == Just ()) (throwIO (userError "injected: reading the table raised"))
        atomically (TableReading <$> readTVar (fBound fake) <*> readTVar (fRetiring fake))
    , deviceRelease = \registration → do
        noteEvent fake "release attempted"
        raising ← atomically (takeInjection fake (\case RaiseRelease → Just (); _ → Nothing))
        when (raising == Just ()) (throwIO (userError "injected: the release raised"))
        atomically $ releaseNow registration
    }
  where
    -- The interpretation an image was allocated and registered under, appended to the event only when it is not the
    -- default premultiplied sRGB colour, so the examples that predate data textures read their events unchanged.
    formatSuffix = \case
      TexelRgba8Srgb → ""
      TexelRgba8Linear → " linear"
      other → " " <> tshow other
    releaseNow registration = do
        failure ← takeInjection fake (\case FailRelease fault → Just fault; _ → Nothing)
        owners ← readTVar (fSlotOwner fake)
        let slot = registrationSlot registration
        holder ← cmLookup (charge (fWork fake) SlotOwners) slot owners
        case (failure, holder) of
          (Just fault, _) → pure (Left fault)
          (_, Just image) → do
            setImage fake image (ReleasedHandle slot)
            cmDelete (charge (fWork fake) SlotOwners) slot owners >>= writeTVar (fSlotOwner fake)
            holders ← readTVar (fHolders fake)
            if holders > 0
              then modifyTVar' (fRetiring fake) (Set.insert slot)
              else readTVar (fSlotsFree fake) >>= \free → csPush (charge (fWork fake) FreeSlots) free slot >>= writeTVar (fSlotsFree fake)
            record fake ("released " <> tshow image <> " slot " <> tshow slot)
            bump fake
            pure (Right ())
          _ → pure (Left (FaultFatal "released a registration that is not live"))

-- The owner's thread -------------------------------------------------------------------------------------------

-- | Run the fake owner for the body: one thread that does what no hold forbids — runs a queued action,
-- starts and completes uploads, binds the table, reclaims released slots — and nothing else. The thread is owned by the call
-- (#599): started and registered for its stop-and-join in one masked step, and ended and joined however the body ended, a
-- cancellation delivered between the thread's start and the body's first step included. It waits only in STM, so the kill ends
-- it wherever it is.
withFakeOwner ∷ Fake → IO a → IO a
withFakeOwner = withFakeOwnerAs (\_ → pure ())

-- | 'withFakeOwner' with a test-side seam: the action runs on the calling thread, inside the scope and before the body's first
-- step, and is given the owner's thread. It lets an example learn the thread and place a cancellation exactly there. No example
-- of the suite passes anything else.
withFakeOwnerAs ∷ (ThreadId → IO ()) → Fake → IO a → IO a
withFakeOwnerAs seam fake body = withOwnedThread (ownerLoop fake) (\thread _ → seam thread >> body)

ownerLoop ∷ Fake → IO ()
ownerLoop fake = do
  step ← atomically nextWork
  step
  ownerLoop fake
  where
    nextWork ∷ STM (IO ())
    nextWork = do
      holds ← readTVar (fHolds fake)
      let on which = Set.member which holds
      acts ← readTVar (fActs fake)
      releases ← readTVar (fReleases fake)
      uploads ← readTVar (fOpen fake)
      standing ← readTVar (fStanding fake)
      bound ← readTVar (fBound fake)
      retiring ← readTVar (fRetiring fake)
      holders ← readTVar (fHolders fake)
      grants ← readTVar (fGrants fake)
      ticketHolds ← readTVar (fTicketHolds fake)
      uploadList ← cmToList (observe (fWork fake) OwnerUploads) uploads
      states ← traverse (\(ticket, upload) → (,) (ticket, upload) <$> readTVar (upState upload)) uploadList
      observe (fWork fake) OwnerReleases (1 + length releases)
      gated ← traverse (\pending → (,) pending <$> pendingGate pending) releases
      let readyRelease = case break snd gated of
            (before, (pending, _) : after) → ([pending], map fst before <> map fst after)
            (_, []) → ([], map fst gated)
      let canRun = standing == Running && (not (on HoldOwner) || grants > 0)
          spendGrant = when (on HoldOwner) (writeTVar (fGrants fake) (grants - 1))
      chosen ← case () of
        _
          | canRun, pending : rest ← acts → do
              writeTVar (fActs fake) rest
              spendGrant
              pure (pendingRun pending (deviceFor fake))
          | canRun, not (on HoldAdoption), (pending : _, rest) ← readyRelease → do
              writeTVar (fReleases fake) rest
              spendGrant
              pure (pendingRun pending (deviceFor fake))
          | not (on HoldUploadStart), Just (ticket, upload) ← find' TicketQueued states → pure . atomically $ do
              writeTVar (upState upload) TicketUploading
              record fake ("upload started " <> tshow ticket)
              bump fake
          | not (on HoldUploadFinish), Just (ticket, upload) ← findFree ticketHolds TicketUploading states → pure . atomically $ do
              lost ← readTVar (fInjected fake)
              _ <- pure lost
              writeTVar (upState upload) TicketComplete
              readTVar (fOpen fake) >>= cmDelete (charge (fWork fake) OwnerUploads) ticket >>= writeTVar (fOpen fake)
              readTVar (fImages fake) >>= cmAdjust (charge (fWork fake) ImageMap) (\case Allocated → Uploaded; other → other) (upImage upload) >>= writeTVar (fImages fake)
              record fake ("upload completed " <> tshow ticket)
              bump fake
          | not (on HoldBind), not bound → pure . atomically $ do
              writeTVar (fBound fake) True
              record fake "table bound"
              bump fake
          | not (on HoldReclaim), holders == 0, not (Set.null retiring) → pure . atomically $ do
              free ← readTVar (fSlotsFree fake)
              csAppendList (charge (fWork fake) FreeSlots) free (Set.toList retiring) >>= writeTVar (fSlotsFree fake)
              writeTVar (fRetiring fake) Set.empty
              record fake ("reclaimed " <> Text.intercalate "," (map tshow (Set.toList retiring)))
              bump fake
          | otherwise → retry
      -- What the scan walked is the work of this evaluation only if it committed: the owner returns its charges and the loop
      -- counts them after the transaction (a charge written here would be read by a transaction that waits).
      pure (commitIO (fWork fake) OwnerUploads (1 + cmSize uploads) >> commitIO (fWork fake) OwnerReleases (1 + length releases) >> chosen)
    findFree blocked wanted states = case [(ticket, upload) | ((ticket, upload), state) ← states, state == wanted, ticket `Set.notMember` blocked] of
      first : _ → Just first
      [] → Nothing
    find' wanted states = case [(ticket, upload) | ((ticket, upload), state) ← states, state == wanted] of
      first : _ → Just first
      [] → Nothing

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
