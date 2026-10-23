{-# LANGUAGE OverloadedStrings #-}

-- | The coordinator's transactions. Hidden. Each is one atomic step over the one state variable of
-- "Hetoimasia.LuaEngine.Modules.Types"; none waits, none runs Lua, none touches the VM. What a step
-- needs done outside the transaction (answering a request, writing a diagnostic) it returns as an
-- action for the caller to run after the commit.
--
-- = Reads: where bytes come from, and what they cost
--
-- A module's source is read by the session's pool ("Hetoimasia.Content.ReadPool") through slots this
-- coordinator holds for its life. A read is /started/ ('pump') when the bank has room for the file's
-- inventoried length in the class it may use (ordinary prefetch: the bank less the active reserve;
-- the active chain's next source: the reserve) and a slot is free (prefetch: all but one; the
-- active chain: the last). A job that cannot start yet waits where it is, in the admitted-job table,
-- which the identity bound bounds: it neither takes the reserve nor turns acceptance into busy. The
-- sink of a read, which runs on a pool worker, stores the verified buffer or the failure and hands it
-- to the owner's inbox in the same transaction, then starts the next read that fits: the worker never
-- waits for Lua, a tick or another job, and its slot returns the moment its sink does.
--
-- The charge for a source is the file's known length, reserved before the read starts, kept while it
-- queues, reads, waits for the loader and is compiled, and returned when the loader's interest ends
-- (it consumed the bytes, the source failed, or the loader stopped); for a read nobody wants any more
-- it is returned when the read retires.
module Hetoimasia.LuaEngine.Modules.State
  ( -- * Observation
    countsSTM
  , defectSTM
  , ImmediateLookup (..)
  , lookupImmediateSTM
  , drainedSTM
    -- * Reserving identities
  , reserveIdentitySTM
  , releaseIdentitySTM
  , permanentRefusalSTM
  , reservedForLoaderSTM
    -- * Requests
  , Accepted (..)
  , acceptRequest
    -- * Boot loads
  , BootAnswer (..)
  , acceptBoot
    -- * The loader's seams
  , acquireSTM
  , releaseSTM
  , publishSTM
  , blockedSTM
  , closeSTM
    -- * Failures
  , recordDefectSTM
  ) where

import Control.Concurrent.STM
  ( STM
  , atomically
  , newTVar
  , readTVar
  , throwSTM
  , writeTVar
  )
import Control.Exception (SomeException, throwIO, toException)
import Control.Monad (foldM, forM, forM_, unless, when)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Content.Identity (ContentKey)
import Hetoimasia.Content.Inventory
  ( Change (..)
  , Presence (..)
  , ReadFailure (..)
  , ReadOutcome (..)
  , inspectEntry
  )
import Hetoimasia.Content.ReadPool
  ( ReadPriority (..)
  , ReadRequest (..)
  , ReadResult (..)
  , SubmitRefusal (..)
  , releaseSlot
  , submit
  , withdrawQueued
  )
import Hetoimasia.Foundation.Log (Component, logWarning, unsafeComponent)
import Hetoimasia.LuaEngine.Modules.Address (identityKey, moduleIdentity, moduleLabel, pathText, rootText)
import Hetoimasia.LuaEngine.Modules.Bank
  ( Class (..)
  , charge
  , chargedActive
  , chargedOrdinary
  , chargedTotal
  , discharge
  , mayCharge
  )
import Hetoimasia.LuaEngine.Modules.Failure
  ( ModuleFailure (..)
  , encodeSourceReason
  , failureOfFault
  , innermostFault
  )
import Hetoimasia.LuaEngine.Modules.Types
import Hetoimasia.Scripting.Lua.Admission (CreditEnd (..))
import Hetoimasia.Scripting.Lua.Loading
  ( NotifyAnswer (..)
  , PromoteAnswer (..)
  , RootDue (..)
  , SubmitAnswer (..)
  , notifySourceNow
  , pokeLoader
  , promoteSubmitted
  , submitReservedRoot
  )
import Hetoimasia.Scripting.Lua.Owner
  ( BoundaryFault
  , ExportHandle
  , ExportIdentity
  , ModuleStatus (..)
  , RootRequest (..)
  , SourceAnswer (..)
  , exportTableValue
  )
import Hetoimasia.Scripting.Lua.Provider
  ( Completion (..)
  , DueSlot (..)
  , ExpectedFailure (..)
  , ProviderReply (..)
  , ProviderWork (..)
  , ReplyAnswer (..)
  , RetirementState (..)
  )

-- Small helpers ---------------------------------------------------------------------------------

readState ∷ Coordinator → STM CState
readState = readTVar . coordState

writeState ∷ Coordinator → CState → STM ()
writeState = writeTVar . coordState

defect ∷ Text → STM a
defect = throwSTM . ModuleDefect

-- | How many identities are held or promised.
identitiesUsed ∷ CState → Int
identitiesUsed st = Map.size (csJobs st) + csPromised st

-- | The position of a due, to compare: a request that waits for no tick stands before any placed one.
dueRank ∷ RootDue → (Word64, Word64)
dueRank = \case
  DueAt tick sequenceNumber → (tick, sequenceNumber)
  _ → (0, 0)

earlier ∷ RootDue → Maybe RootDue → RootDue
earlier due = \case
  Just held | dueRank held <= dueRank due → held
  _ → due

-- | What the inventory says will become of a module's read.
fateOf ∷ Coordinator → ContentKey → Fate
fateOf c key = case inspectEntry (coordInventory c) key of
  Absent → FateMissing
  PresentDirectory → FateMissing
  PresentFile len
    | len > limitSourceBytes (coordLimits c) → FateTooLarge len
    | otherwise → FateRead len

failureOfFate ∷ Coordinator → Fate → Maybe SourceProblem
failureOfFate c = \case
  FateRead _ → Nothing
  FateMissing → Just (SourceProblem "not_found" "the path is not an inventoried regular file")
  FateTooLarge len ->
    Just (SourceProblem "too_large" ("the file is " <> shown len <> " bytes, over the module limit of " <> shown (limitSourceBytes (coordLimits c))))

shown ∷ Show a ⇒ a → Text
shown = Text.pack . show

-- | A new job for a key. Its source is a failure already known, or waits for a read.
admitJob ∷ Coordinator → ContentKey → Bool → CState → (Job, CState)
admitJob c key recorded st = (job, st {csSerial = csSerial st + 1})
  where
    fate = fateOf c key
    job =
      Job
        { jobKey = key
        , jobLabel = moduleLabel key
        , jobSerial = csSerial st
        , jobFate = fate
        , jobOutcome = Live
        , jobDue = Nothing
        , jobRoot = False
        , jobRecorded = recorded
        , jobInterest = False
        , jobWaiters = Map.empty
        , jobBoots = []
        , jobSource = maybe SrcNone SrcFailed (failureOfFate c fate)
        , jobCharge = Nothing
        , jobNeeded = False
        , jobDiagnosed = False
        }

setJob ∷ ExportIdentity → Job → CState → CState
setJob identity job st = st {csJobs = Map.insert identity job (csJobs st)}

-- | Record the first failure of the coordinator's own that a thread could not raise, and wake the
-- owner to raise it.
recordDefectSTM ∷ Coordinator → SomeException → STM ()
recordDefectSTM c failure = do
  st <- readState c
  when (isNothing (csDefect st)) (writeState c st {csDefect = Just failure})
  wake c

wake ∷ Coordinator → STM ()
wake c = readTVar (coordLoader c) >>= mapM_ pokeLoader

-- | The failure recorded, if any.
defectSTM ∷ Coordinator → STM (Maybe SomeException)
defectSTM c = csDefect <$> readState c

-- Slots and the bank ------------------------------------------------------------------------------

-- | A slot comes back from a read that is over: free for the next read while the coordinator is open,
-- and back to the pool once it has closed.
returnSlot ∷ Coordinator → CState → STM CState
returnSlot c st = case csPhase st of
  Open → pure st {csSlotsFree = csSlotsFree st + 1}
  Closed → do
    releaseSlot (coordPool c)
    pure st {csPoolHeld = csPoolHeld st - 1}

-- | Give a job's charge back to the bank.
releaseCharge ∷ Job → CState → STM (Job, CState)
releaseCharge job st = case jobCharge job of
  Nothing → pure (job, st)
  Just (bytes, class') → case discharge class' bytes (csCharges st) of
    Left _ → defect "bytes were returned to the source bank that it had not been charged"
    Right charges → pure (job {jobCharge = Nothing}, st {csCharges = charges})

-- Starting reads -----------------------------------------------------------------------------------

-- | Start every read that fits: the jobs the active chain waits for first, then the oldest. Called by
-- everything that can make room (a read ending, a source released, a job admitted or needed).
pump ∷ Coordinator → STM ()
pump c = do
  st <- readState c
  when (csPhase st == Open && isNothing (csDefect st)) $
    case choose st of
      Nothing → pure ()
      Just (identity, class') → startRead c identity class' >> pump c
  where
    choose st =
      let candidates =
            sortOn
              (\(_, job) → (not (jobNeeded job), jobSerial job))
              [ (identity, job)
              | (identity, job) ← Map.toList (csJobs st)
              , SrcNone ← [jobSource job]
              , isLive job
              , jobRecorded job || jobRoot job
              ]
       in firstJust [fmap ((,) identity) (fitting st job) | (identity, job) ← candidates]
    fitting st job = case jobFate job of
      FateRead len →
        let limits = limitBank (coordLimits c)
            free = csSlotsFree st
            active = jobNeeded job && free >= 1 && mayCharge limits (csCharges st) Active len
            ordinary = mayCharge limits (csCharges st) Ordinary len && free >= (if jobNeeded job then 1 else 2)
         in if active then Just Active else if ordinary then Just Ordinary else Nothing
      _ → Nothing
    firstJust = foldr (\next rest → maybe rest Just next) Nothing

isLive ∷ Job → Bool
isLive job = case jobOutcome job of
  Live → True
  _ → False

-- | Hand a job's read to the pool, charged to the class.
startRead ∷ Coordinator → ExportIdentity → Class → STM ()
startRead c identity class' = do
  st <- readState c
  case Map.lookup identity (csJobs st) of
    Just job | FateRead len ← jobFate job → do
      submitted <- submit (coordPool c) (readRequestFor c identity job)
      case submitted of
        Left refusal -> do
          let why = case refusal of
                PoolIsClosed → "the read pool is closed"
                PoolHasFailed failure → "the read pool has failed: " <> shown failure
          writeState c st {csDefect = Just (toException (ModuleDefect ("a module read was refused: " <> why)))}
          wake c
        Right ticket -> do
          let charges = charge class' len (csCharges st)
              slots = csPoolHeld st - (csSlotsFree st - 1)
              total = chargedTotal charges
              peaks = csPeaks st
              job' = job {jobSource = SrcQueued ticket, jobCharge = Just (len, class')}
          writeState c $
            setJob identity job' st
              { csCharges = charges
              , csSlotsFree = csSlotsFree st - 1
              , csReadsStarted = csReadsStarted st + 1
              , csPeaks =
                  peaks
                    { peakOrdinary = max (peakOrdinary peaks) (chargedOrdinary charges)
                    , peakActive = max (peakActive peaks) (chargedActive charges)
                    , peakSlots = max (peakSlots peaks) slots
                    , peakTotal = max (peakTotal peaks) total
                    }
              }
    _ → defect "a read was started for a job that has none to make"

readRequestFor ∷ Coordinator → ExportIdentity → Job → ReadRequest
readRequestFor c identity job =
  ReadRequest
    { requestKey = jobKey job
    , requestAllowance = fromIntegral (limitSourceBytes (coordLimits c))
    , requestPriority = if jobNeeded job then DependencyProgress else OrdinaryRead
    , requestSink = \result → atomically (sinkSTM c identity result)
    }

-- | The active chain waits for this job: its read is of the strongest class from now on. A read that
-- is queued behind unrelated prefetch is withdrawn and queued again ahead of it, keeping its slot and
-- its charge; a read a worker already took is left to finish; one that has not started may now use
-- the reserve.
needJob ∷ Coordinator → ExportIdentity → STM ()
needJob c identity = do
  st <- readState c
  case Map.lookup identity (csJobs st) of
    Just job | isLive job, not (jobNeeded job) → do
      let job' = job {jobNeeded = True}
      case jobSource job of
        SrcQueued ticket → do
          withdrawn <- withdrawQueued ticket
          if withdrawn
            then do
              resubmitted <- submit (coordPool c) (readRequestFor c identity job')
              case resubmitted of
                Right ticket' -> writeState c (setJob identity job' {jobSource = SrcQueued ticket'} st)
                Left refusal -> do
                  writeState c (setJob identity job' {jobSource = SrcGone} st {csDefect = Just (toException (ModuleDefect ("a module read could not be queued again: " <> shownRefusal refusal)))})
                  wake c
            else writeState c (setJob identity job' st)
        SrcNone → writeState c (setJob identity job' st) >> pump c
        _ → writeState c (setJob identity job' st)
    _ → pure ()
  where
    shownRefusal = \case
      PoolIsClosed → "the read pool is closed"
      PoolHasFailed failure → "the read pool has failed: " <> shown failure

-- The sink of a read --------------------------------------------------------------------------------

-- | A read is over. On a pool worker: one transaction that returns the slot, stores or hands over what
-- was read, and starts the next read that fits.
sinkSTM ∷ Coordinator → ExportIdentity → ReadResult → STM ()
sinkSTM c identity result = do
  st0 <- readState c
  case Map.lookup identity (csJobs st0) of
    Nothing → recordDefectSTM c (toException (ModuleDefect "a read finished for a job the coordinator does not hold"))
    Just job0 → do
      st1 <- returnSlot c st0
      let closed = csPhase st1 == Closed
          pendingRecord = not (jobRecorded job0)
          abandoned = jobRecorded job0 && not (jobInterest job0)
          unwanted = closed || abandoned || not (isLive job0)
      case result of
        ReadSucceeded bytes
          | unwanted → drop' job0 st1
          | pendingRecord → keep job0 {jobSource = SrcArrived bytes} st1
          | otherwise → handOver job0 st1 (SourceVerified bytes)
        ReadFailed failure
          | unwanted → drop' job0 st1
          | otherwise → do
              (job1, st2) <- releaseCharge job0 st1
              let sf = sourceFailureOf job0 failure
              if pendingRecord
                then keep job1 {jobSource = SrcFailed sf} st2
                else handOver job1 st2 (failureAnswer sf)
        ReadDefect failure -> do
          (job1, st2) <- releaseCharge job0 st1
          writeState c (setJob identity job1 {jobSource = SrcGone} st2)
          unless closed (recordDefectSTM c (toException (ModuleDefect ("a module read failed: " <> shown failure))))
        ReadAbandoned -> do
          (job1, st2) <- releaseCharge job0 st1
          writeState c (setJob identity job1 {jobSource = SrcGone} st2)
          unless closed (recordDefectSTM c (toException (ModuleDefect "a module read was abandoned while the VM was live")))
      pump c
  where
    drop' job st = do
      (job1, st1) <- releaseCharge job st
      writeState c (setJob identity job1 {jobSource = SrcGone} st1)
    keep job st = writeState c (setJob identity job st)
    handOver job st answer = do
      loader <- readTVar (coordLoader c)
      case loader of
        Nothing -> do
          writeState c (setJob identity job st)
          recordDefectSTM c (toException (ModuleDefect "a source arrived before a loader was attached"))
        Just endpoint -> do
          noted <- notifySourceNow endpoint identity answer
          case noted of
            NotifyAccepted -> keep job {jobSource = SrcHanded} st
            NotifyClosed -> drop' job st
            other -> do
              keep job {jobSource = SrcHanded} st
              recordDefectSTM c (toException (ModuleDefect ("the loader's inbox refused an arrived source: " <> shown other)))

-- | What a read's refusal is told as.
sourceFailureOf ∷ Job → ReadFailure → SourceProblem
sourceFailureOf _ (ReadFailure _ _ outcome) = case outcome of
  ReadNotFound → SourceProblem "not_found" "the path is not an inventoried regular file"
  ReadTooLarge len _ → SourceProblem "too_large" ("the file is " <> shown len <> " bytes, over the module limit")
  ReadChanged change → SourceProblem "content_changed" (changeText change)
  ReadIoError kind → SourceProblem "io_error" ("the file could not be read: " <> shown kind)

changeText ∷ Change → Text
changeText = \case
  Missing → "the file is gone"
  Retyped kind → "the path no longer names a regular file: " <> shown kind
  LengthChanged expected found → "the length changed from " <> shown expected <> " to " <> shown found
  Truncated expected seen → "the file ended after " <> shown seen <> " of " <> shown expected <> " bytes"
  Grew expected → "the file grew past " <> shown expected <> " bytes"
  DigestMismatch → "the bytes are not the ones the inventory pinned"

-- The loader's seams ----------------------------------------------------------------------------------

-- | The loader asks for an identity's source, once, when it holds a record of it: a root it admitted
-- (whose room was reserved when the request was accepted, and whose read may have begun or even
-- finished) or a dependency a module discovered (whose read begins now, of the strongest class).
acquireSTM ∷ Coordinator → ExportIdentity → STM SourceAnswer
acquireSTM c identity = do
  st <- readState c
  case Map.lookup identity (csJobs st) of
    Just job
      | jobInterest job → defect "the loader asked for a source it already holds an interest in"
      | otherwise → do
          let job1 = job {jobRecorded = True, jobInterest = True}
          case jobSource job of
            SrcArrived bytes → writeState c (setJob identity job1 {jobSource = SrcHanded} st) >> pure (SourceVerified bytes)
            SrcFailed sf → writeState c (setJob identity job1 {jobSource = SrcHanded} st) >> pure (failureAnswer sf)
            SrcNone → writeState c (setJob identity job1 st) >> pure SourcePending
            SrcQueued _ → writeState c (setJob identity job1 st) >> pure SourcePending
            _ → defect "the loader asked for a source that is no longer held"
    Nothing → do
      key <- maybe (defect "the loader asked for an identity no content address made") pure (identityKey (coordInventory c) identity)
      when (identitiesUsed st >= limitIdentities (coordLimits c)) $
        defect "the loader recorded a dependency the identity bound has no room for"
      let (job0, st1) = admitJob c key True st
          job1 = job0 {jobInterest = True, jobNeeded = True}
      case jobSource job1 of
        SrcFailed sf → writeState c (setJob identity job1 {jobSource = SrcHanded} st1) >> pure (failureAnswer sf)
        _ → do
          writeState c (setJob identity job1 st1)
          pump c
          pure SourcePending

failureAnswer ∷ SourceProblem → SourceAnswer
failureAnswer sf = SourceFailure (encodeSourceReason (problemCode sf) (problemMessage sf))

-- | The loader no longer needs an identity's source: it compiled the bytes, the source failed, or the
-- loader stopped. The bytes come out of the bank. A read that is still queued is withdrawn and gives
-- its slot back; one a worker holds finishes, and its sink returns the slot and the bytes.
releaseSTM ∷ Coordinator → ExportIdentity → STM ()
releaseSTM c identity = do
  st <- readState c
  case Map.lookup identity (csJobs st) of
    Just job
      | jobInterest job → do
          let job1 = job {jobInterest = False}
          case jobSource job1 of
            SrcQueued ticket → do
              withdrawn <- withdrawQueued ticket
              if withdrawn
                then do
                  st1 <- returnSlot c st
                  (job2, st2) <- releaseCharge job1 st1
                  writeState c (setJob identity job2 {jobSource = SrcGone} st2)
                else writeState c (setJob identity job1 st)
            _ → do
              (job2, st1) <- releaseCharge job1 st
              writeState c (setJob identity job2 {jobSource = SrcGone} st1)
          pump c
    _ → defect "the loader released a source interest it did not hold"

-- | The active chain waits for this identity's source.
blockedSTM ∷ Coordinator → ExportIdentity → STM ()
blockedSTM = needJob

-- Publication ----------------------------------------------------------------------------------------

-- | The loader came to an outcome for these identities, in the order they did. Each is published once:
-- the job takes it, every subscribed request is answered with it (a held answer is the host's to
-- hold until the request's own position), boot loads are told, and a failure nobody waits for is
-- diagnosed. Answers and diagnostics are returned for the caller to run after the commit.
publishSTM ∷ Coordinator → [(ExportIdentity, ModuleStatus)] → STM [IO ()]
publishSTM c settled = concat <$> forM settled (publishOne c)

publishOne ∷ Coordinator → (ExportIdentity, ModuleStatus) → STM [IO ()]
publishOne c (identity, status) = do
  st <- readState c
  case Map.lookup identity (csJobs st) of
    Just job | isLive job → case status of
      ModuleReady handle → settle st job (Ready handle) (replyReady handle) BootReady Nothing
      ModuleFailed fault →
        let failure = failureFor st job fault
         in settle st job (Failed fault failure) (replyFailed job failure) (BootFailed failure) (Just (fault, failure))
      _ → pure []
    _ → pure []
  where
    settle st job outcome reply boot failed = do
      waiters <- forM (Map.elems (jobWaiters job)) $ \waiter -> do
        waiting <- readTVar (waiterState waiter)
        case waiting of
          Registered -> do
            writeTVar (waiterState waiter) Replied
            pure [answerWith (waiterCompletion waiter) reply]
          _ -> pure []
      forM_ (jobBoots job) $ \ticket -> writeTVar ticket (Just boot)
      let nobody = Map.null (jobWaiters job) && null (jobBoots job)
          diagnose = case failed of
            Just (fault, failure) | nobody && not (jobDiagnosed job) -> Just (fault, failure)
            _ -> Nothing
          job' =
            job
              { jobOutcome = outcome
              , jobWaiters = Map.empty
              , jobBoots = []
              , jobDiagnosed = jobDiagnosed job || isJust diagnose
              }
      writeState c $
        setJob identity job' st {csBootWaiters = csBootWaiters st - length (jobBoots job)}
      pure (concat waiters <> [diagnosing (jobKey job) failure | Just (_, failure) <- [diagnose]])
    diagnosing key failure = diagnoseModule c key failure

-- | A failure told as the expected failure a request carries.
replyFailed ∷ Job → ModuleFailure → ProviderReply
replyFailed _ failure =
  ProviderExpected
    ExpectedFailure
      { expectedCode = failureCode failure
      , expectedMessage = failureMessage failure
      , expectedRoot = Just (failureRoot failure)
      , expectedPath = Just (failurePath failure)
      }

replyReady ∷ ExportHandle → ProviderReply
replyReady = ProviderResult . exportTableValue

-- | Answer a request, and treat anything but an accepted answer as the provider defect it is.
answerWith ∷ Completion → ProviderReply → IO ()
answerWith completion reply = do
  answered <- completeRequest completion reply
  case answered of
    ReplySettled -> pure ()
    ReplyHeld -> pure ()
    ReplyLate -> pure ()
    ReplyUnknown -> pure ()
    other -> throwModuleDefect ("a module answer was refused: " <> shown other)

-- | What a fault is told as, with the failing content located among the jobs by the fault of the
-- cause: the dependency that failed first, or the module itself.
failureFor ∷ CState → Job → BoundaryFault → ModuleFailure
failureFor st job fault =
  failureOfFault (jobLabel job) located fault
  where
    (_, cause) = innermostFault fault
    located =
      case [ (rootText (jobKey other), pathText (jobKey other))
           | other <- Map.elems (csJobs st)
           , Failed found _ <- [jobOutcome other]
           , found == cause
           ] of
        found : _ -> found
        [] -> (rootText (jobKey job), pathText (jobKey job))

-- Requests ---------------------------------------------------------------------------------------------

-- | The room for a new identity, reserved in the transaction that admits the request that names it.
-- It is permanent: the identity is the VM's for its life, and the reservation is not given back when
-- the request ends, only when the admission is taken back before the endpoint was handed anything.
reserveIdentitySTM ∷ Coordinator → STM Bool
reserveIdentitySTM c = do
  st <- readState c
  if csPhase st == Open && identitiesUsed st < limitIdentities (coordLimits c)
    then True <$ writeState c st {csPromised = csPromised st + 1}
    else pure False

-- | Give the reservation back if the request never reached the endpoint.
releaseIdentitySTM ∷ Coordinator → CreditEnd → STM ()
releaseIdentitySTM c = \case
  CreditSettled → pure ()
  CreditUnused -> do
    st <- readState c
    if csPromised st <= 0
      then defect "an identity reservation was returned that had not been made"
      else writeState c st {csPromised = csPromised st - 1}

-- | A permanent reason the request would be refused: the coordinator has closed, or the identity is
-- new and the VM already holds every identity it may. Reads only. A pending or finished identity
-- needs no slot, so a full cache still answers lookups and joins.
permanentRefusalSTM ∷ Coordinator → ContentKey → STM (Maybe Text)
permanentRefusalSTM c key = do
  st <- readState c
  pure $
    if csPhase st == Closed
      then Just "the module loader has stopped and takes no more requests"
      else
        if Map.member (moduleIdentity key) (csJobs st) || identitiesUsed st < limitIdentities (coordLimits c)
          then Nothing
          else Just ("module limit: the VM already holds all " <> shown (limitIdentities (coordLimits c)) <> " module identities")

-- | How many identities the application has promised room for that the loader holds no record of,
-- other than this one: the loader's 'loaderReserved'.
reservedForLoaderSTM ∷ Coordinator → ExportIdentity → STM Int
reservedForLoaderSTM c identity = do
  st <- readState c
  let unrecorded = length [() | (other, job) <- Map.toList (csJobs st), other /= identity, jobRoot job, not (jobRecorded job)]
  pure (csPromised st + unrecorded)

-- | What accepting a request came to: the work to hand the host, and what to do after the commit.
data Accepted = Accepted
  { acceptedWork ∷ !ProviderWork
  , acceptedActions ∷ ![IO ()]
  }

finished ∷ ProviderWork
finished = ProviderWork {workCancel = pure (), workRetirement = pure ProviderComplete}

-- | Accept a request for a module: join the job that names it, or make the job, in one transaction. A
-- request for an identity the VM does not hold has already reserved its place; the job is made from
-- that reservation, together with the root submitted to the loader at the request's own position.
-- A request for a pending identity subscribes, and moves the job's position earlier if its own is. A
-- request for a finished identity is answered at once with the outcome, which the host delivers at
-- the request's own position.
acceptRequest ∷ Coordinator → ContentKey → Maybe DueSlot → Word64 → Completion → STM Accepted
acceptRequest c key due number completion = do
  st <- readState c
  loader <- readTVar (coordLoader c)
  let identity = moduleIdentity key
      position = maybe DueUi (\slot -> DueAt (dueTick slot) (dueSequence slot)) due
  if csPhase st == Closed
    then pure (Accepted finished [])
    else case loader of
      Nothing -> defect "a request was accepted before a loader was attached"
      Just endpoint -> case Map.lookup identity (csJobs st) of
        Nothing -> do
          when (csPromised st <= 0) $ defect "a request for a new identity was accepted without its reservation"
          let (job0, st1) = admitJob c key False st
          (work, waiter) <- subscribe identity number completion
          let job1 = job0 {jobRoot = True, jobDue = Just position, jobWaiters = Map.singleton number waiter}
          writeState c (setJob identity job1 st1 {csPromised = csPromised st1 - 1})
          queued <- submitReservedRoot endpoint (RootRequest identity (jobLabel job1)) position
          closedOr queued
          pump c
          pure (Accepted work [])
        Just job -> case jobOutcome job of
          Live -> do
            (work, waiter) <- subscribe identity number completion
            let job1 = job {jobWaiters = Map.insert number waiter (jobWaiters job), jobDue = Just (earlier position (jobDue job)), jobRoot = True}
            writeState c (setJob identity job1 st)
            if jobRoot job
              then forM_ (jobDue job) $ \held -> when (dueRank position < dueRank held) $ do
                promoted <- promoteSubmitted endpoint identity position
                case promoted of
                  PromoteAccepted -> pure ()
                  PromoteUnknown -> pure ()
                  PromoteClosed -> pure ()
                  PromoteFull -> defect "the loader's inbox could not hold an earlier position"
              else do
                queued <- submitReservedRoot endpoint (RootRequest identity (jobLabel job)) position
                closedOr queued
            pure (Accepted work [])
          Ready handle -> pure (Accepted finished [answerWith completion (replyReady handle)])
          Failed _ failure -> pure (Accepted finished [answerWith completion (replyFailed job failure)])
          Stopped -> pure (Accepted finished [])
  where
    closedOr = \case
      SubmitAccepted -> pure ()
      SubmitClosed -> pure ()
      other -> defect ("the loader's inbox refused a root: " <> shown other)
    subscribe identity n completion' = do
      var <- newTVar Registered
      let waiter = Waiter n completion' var
          work =
            ProviderWork
              { workCancel = atomically (detach identity n var)
              , workRetirement = (\s -> if s == Registered then ProviderPending else ProviderComplete) <$> readTVar var
              }
      pure (work, waiter)
    detach identity n var = do
      s <- readTVar var
      when (s == Registered) $ do
        writeTVar var Detached
        st <- readState c
        forM_ (Map.lookup identity (csJobs st)) $ \job ->
          writeState c (setJob identity job {jobWaiters = Map.delete n (jobWaiters job)} st)

-- Boot loads -------------------------------------------------------------------------------------------

-- | What asking for a boot load came to.
data BootAnswer
  = BootAccepted !BootTicket
  | -- | The coordinator has closed.
    BootRefusedClosed
  | -- | A new identity, and the VM holds all it may.
    BootRefusedFull
  | -- | Too many boot loads are unsettled.
    BootRefusedBusy
  deriving ()

-- | Ask for a boot load of a key, in the pre-init boot phase: the same identity, chain and read as a
-- request, with no waiter, no result position and no tick. The ticket's outcome is told when the
-- loader comes to one.
acceptBoot ∷ Coordinator → ContentKey → STM BootAnswer
acceptBoot c key = do
  st <- readState c
  loader <- readTVar (coordLoader c)
  let identity = moduleIdentity key
  case loader of
    Nothing -> defect "a boot load was asked for before a loader was attached"
    Just endpoint
      | csPhase st == Closed -> pure BootRefusedClosed
      | otherwise -> case Map.lookup identity (csJobs st) of
          Nothing
            | identitiesUsed st >= limitIdentities (coordLimits c) -> pure BootRefusedFull
            | csBootWaiters st >= limitBootWaiters (coordLimits c) -> pure BootRefusedBusy
            | otherwise -> do
                var <- newTVar Nothing
                let (job0, st1) = admitJob c key False st
                    job1 = job0 {jobRoot = True, jobDue = Just DueUi, jobBoots = [var]}
                writeState c (setJob identity job1 st1 {csBootWaiters = csBootWaiters st1 + 1})
                answer <- submitReservedRoot endpoint (RootRequest identity (jobLabel job1)) DueUi
                case answer of
                  SubmitAccepted -> pure ()
                  SubmitClosed -> pure ()
                  other -> defect ("the loader's inbox refused a boot root: " <> shown other)
                pump c
                pure (BootAccepted (BootTicket var))
          Just job
            | csBootWaiters st >= limitBootWaiters (coordLimits c) -> pure BootRefusedBusy
            | otherwise -> do
                var <- newTVar (case jobOutcome job of
                  Ready _ -> Just BootReady
                  Failed _ failure -> Just (BootFailed failure)
                  Stopped -> Just BootStopped
                  Live -> Nothing)
                case jobOutcome job of
                  Live -> do
                    let job1 = job {jobBoots = var : jobBoots job, jobRoot = True, jobDue = Just (earlier DueUi (jobDue job))}
                    writeState c (setJob identity job1 st {csBootWaiters = csBootWaiters st + 1})
                    unless (jobRoot job) $ do
                      answer <- submitReservedRoot endpoint (RootRequest identity (jobLabel job)) DueUi
                      case answer of
                        SubmitAccepted -> pure ()
                        SubmitClosed -> pure ()
                        other -> defect ("the loader's inbox refused a boot root: " <> shown other)
                    when (jobRoot job) $
                      forM_ (jobDue job) $ \held -> when (dueRank DueUi < dueRank held) $ do
                        promoted <- promoteSubmitted endpoint identity DueUi
                        case promoted of
                          PromoteFull -> defect "the loader's inbox could not hold an earlier position"
                          _ -> pure ()
                  _ -> pure ()
                pure (BootAccepted (BootTicket var))

-- Closing --------------------------------------------------------------------------------------------

-- | The VM is stopping, on its owner's thread, after its loader stopped: admission closes; every job
-- that was pending or evaluating reads stopped; boot loads are told; reads nobody has taken are
-- withdrawn and the bytes that arrived for nobody are dropped; the slots no read holds go back to the
-- pool. A read a worker holds finishes, and its sink gives back its slot and its bytes. Idempotent.
closeSTM ∷ Coordinator → STM ()
closeSTM c = do
  st0 <- readState c
  when (csPhase st0 == Open) $ do
    writeState c st0 {csPhase = Closed}
    forM_ (Map.toList (csJobs st0)) $ \(identity, _) -> do
      st <- readState c
      forM_ (Map.lookup identity (csJobs st)) $ \job -> do
        forM_ (jobBoots job) $ \var -> do
          settled <- readTVar var
          when (isNothing settled && isLive job) (writeTVar var (Just BootStopped))
        let job1 = job {jobOutcome = if isLive job then Stopped else jobOutcome job, jobBoots = [], jobWaiters = jobWaiters job}
        case jobSource job1 of
          SrcQueued ticket -> do
            withdrawn <- withdrawQueued ticket
            if withdrawn
              then do
                st1 <- returnSlot c st
                (job2, st2) <- releaseCharge job1 st1
                writeState c (setJob identity job2 {jobSource = SrcGone} st2)
              else writeState c (setJob identity job1 st)
          SrcArrived _ -> do
            (job2, st1) <- releaseCharge job1 st
            writeState c (setJob identity job2 {jobSource = SrcGone} st1)
          _ -> do
            (job2, st1) <- releaseCharge job1 st
            writeState c (setJob identity job2 st1)
    st2 <- readState c
    let free = csSlotsFree st2
    replicateSTM free (releaseSlot (coordPool c))
    writeState c st2 {csSlotsFree = 0, csPoolHeld = csPoolHeld st2 - free, csBootWaiters = 0}

replicateSTM ∷ Int → STM () → STM ()
replicateSTM n action = foldM (\() _ -> action) () [1 .. n]

-- | Whether the coordinator has closed and given everything back: no slot held, nothing charged.
drainedSTM ∷ Coordinator → STM Bool
drainedSTM c = do
  st <- readState c
  pure (csPhase st == Closed && csPoolHeld st == 0 && chargedTotal (csCharges st) == 0)

-- Observation -----------------------------------------------------------------------------------------

-- | What an immediate lookup finds: exactly three answers.
data ImmediateLookup
  = -- | Pending, evaluating or unheld: nothing is started, no identity is allocated, no job is joined
    -- and no position is contributed.
    ImmediateNotReady
  | -- | The export table the VM holds.
    ImmediateReady !ExportHandle
  | -- | The cached required failure, as the expected failure it was told as.
    ImmediateFailed !ModuleFailure

-- | The hook-time lookup of an identity. Reads only.
lookupImmediateSTM ∷ Coordinator → ExportIdentity → STM ImmediateLookup
lookupImmediateSTM c identity = do
  st <- readState c
  pure $ case Map.lookup identity (csJobs st) of
    Just job -> case jobOutcome job of
      Ready handle -> ImmediateReady handle
      Failed _ failure -> ImmediateFailed failure
      _ -> ImmediateNotReady
    Nothing -> ImmediateNotReady

-- | A coherent reading.
countsSTM ∷ Coordinator → STM Counts
countsSTM c = do
  st <- readState c
  let jobs = Map.elems (csJobs st)
      count p = length (filter p jobs)
  pure
    Counts
      { countJobs = length jobs
      , countLive = count isLive
      , countReady = count (\job -> case jobOutcome job of Ready _ -> True; _ -> False)
      , countFailed = count (\job -> case jobOutcome job of Failed _ _ -> True; _ -> False)
      , countStopped = count (\job -> case jobOutcome job of Stopped -> True; _ -> False)
      , countWaiters = sum (map jobWaiterCount jobs)
      , countOrdinary = chargedOrdinary (csCharges st)
      , countActive = chargedActive (csCharges st)
      , countSlotsFree = csSlotsFree st
      , countPoolHeld = csPoolHeld st
      , countDeferred = count (\job -> case jobSource job of SrcNone -> isLive job && (jobRecorded job || jobRoot job) && fateIsRead (jobFate job); _ -> False)
      , countReadsStarted = csReadsStarted st
      , countPhase = csPhase st
      , countPeaks = csPeaks st
      }
  where
    fateIsRead = \case
      FateRead _ -> True
      _ -> False

-- Outside the transaction -------------------------------------------------------------------------

throwModuleDefect ∷ Text → IO a
throwModuleDefect = throwIO . ModuleDefect

moduleComponent ∷ Component
moduleComponent = unsafeComponent "luaengine.modules"

-- | A failed module nothing waits for: an attributed, bounded diagnostic through the logger the
-- coordinator was given, at most once for the identity (the caller marks it), so the history is
-- bounded by the identity cache. It is a diagnostic and not application output, and it fails no
-- instance.
diagnoseModule ∷ Coordinator → ContentKey → ModuleFailure → IO ()
diagnoseModule c _ failure =
  logWarning (coordLogger c) moduleComponent "a module failed and no request was waiting for it" $
    [ ("role", coordRole c)
    , ("root", failureRoot failure)
    , ("path", failurePath failure)
    , ("code", failureCode failure)
    , ("message", failureMessage failure)
    ]
      <> [("chain", Text.intercalate " -> " (failureChain failure)) | length (failureChain failure) > 1]
      <> [("traceback", traceback) | Just traceback <- [failureTraceback failure]]
