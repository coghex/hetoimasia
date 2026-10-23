-- | The texture backend of the Lua-first engine (LFE-17): the implementation, over a
-- "Hetoimasia.LuaEngine.Graphics.Texture.Port", of the upload port the texture pipeline (LFE-16) is
-- injected with.
--
-- One accepted upload finishes here only when four things have been /observed/, in this order: the
-- native image exists, every byte of the decoded level has been uploaded and its upload observed
-- complete, the table's placeholder is bound, and the image is registered with the table so that it
-- resolves to its own slot. Only then does the backend answer 'sinkReady'. An allocated image, an
-- accepted upload ticket, a queue submission, a table handle and a placeholder resolution are none
-- of them that fact.
--
-- = Owner, writers, readers, thread, lifetime
--
-- The /state/ ('State') is one 'TVar' owned by one 'Backend' for the duration of 'withBackend'.
-- Writers: the pipeline's decode worker ('textureBackend''s upload, a transaction that adds a job),
-- any thread that cancels or releases (one transaction each), the owner-thread actions the pump
-- submits (one transaction each, tracking what they made), and the /pump/, the only thread that
-- advances a job. Readers: any thread ('readBackend', the retirement reading). Nothing here is a
-- global, a registry of instances or a cache: the maps hold exactly the jobs the pipeline has
-- accepted and not yet answered the terminal event for, and the textures delivered and not yet
-- proved retired, and both are bounded by the pipeline's own banks (lanes, jobs, texture slots).
--
-- The /pump/ is one worker of a 'Hetoimasia.Foundation.Worker' group started by 'withBackend' and
-- stopped by it, after the backend has drained. It does the work the owner's thread must not: it
-- admits uploads (a copy into bounded staging), reads tickets and the table, and submits the
-- owner-thread actions that allocate, register and release. It waits only in STM, on the variables
-- the next fact lives in (see "Hetoimasia.LuaEngine.Graphics.Texture.Port"): never on a timer, never
-- on a frame, never on Lua, a window or a peer instance. It never calls Lua; the sink it answers
-- through is the pipeline's, whose operations are single transactions.
--
-- = The invariants
--
-- * /Admission before tracking/. A job exists the moment 'backendUpload' returns, so cancellation
--   from then on finds it. Nothing native exists before the pump has issued the allocation.
-- * /Intent before issuance, tracking before escape/. Every native object is recorded in its job
--   (the image, the ticket, the registration) /by the code that made it, in the same masked step/,
--   never by the code that later reads the action's outcome. So an outcome nobody reads, a
--   cancellation that wins between the action's return and the pump's next step, and an exception
--   after construction all find the object recorded and dispose of it exactly once.
-- * /Cancellation is a flag, not a state/. A cancelled, failed or stopping job finishes the step it
--   is in (work already issued to the owner or the GPU cannot be recalled), then is taken apart in
--   dependency order: the registration is released through the table (or, never registered, the image
--   is discarded), and only then is the terminal event delivered. A job is never answered terminal
--   while a native object it made may still be in use.
-- * /One terminal event, one retirement of the borrow/. 'sinkBuffersRetired' is sent exactly once,
--   as soon as the copy into staging ended (or the job ended without one); the terminal event is
--   sent exactly once, after disposal.
-- * /Transfer of ownership is the sink's answer/. A texture is offered with 'sinkReady' after its
--   record exists; 'SinkTaken' makes it the pipeline's (its release is then the lease's, once),
--   'SinkLate' leaves it the backend's, which disposes of it like any undelivered object.
-- * /Retirement is evidence/. A delivered texture's retirement is read from the table: the release ran
--   on the owner's thread and the slot is no longer mapped by a version a batch holds. A release
--   request, a queue acknowledgement, a dropped reference are none of them that.
-- * /Faults keep their severity/. 'FaultPressure' (a native budget answered backpressure) retains
--   the work until the owner's progress changes; every other fault is fatal and is delivered with
--   'sinkFailed', never as an image error, a cancellation or a retry. A cleanup that fails is
--   evidence beside the primary failure and is never retried.
module Hetoimasia.LuaEngine.Graphics.Texture.Backend
  ( -- * The backend
    Backend
  , withBackend
  , textureBackend

    -- * Observation
  , BackendReading (..)
  , readBackend
  , awaitBackendFailure
  , awaitBound
  , backendEvidence

    -- * Failures
  , BackendDefect (..)
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
  , writeTVar
  )
import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException (SomeAsyncException)
  , SomeException (SomeException)
  , fromException
  , mask
  , mask_
  , rethrowIO
  , throwIO
  , toException
  , tryWithContext
  )
import Control.Monad (forM_, unless, void, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Unsafe as ByteString
import Data.Foldable (for_)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Functor ((<&>))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word64)
import Hetoimasia.Foundation.Resource (composeCleanup)
import Hetoimasia.Foundation.Worker
  ( Result (Cancelled, Failed, Succeeded)
  , StartOutcome (StartRejected, Started, StartupFailed)
  , StopToken
  , closeWorkerGroup
  , startWorker
  , stopRequested
  , withWorkerGroup
  , workerDefinition
  , GroupReport (reportDrained, reportExitedBeforeClosing, reportObservedFailures)
  , Completion (completionCleanup, completionLabel, completionResult)
  )
import qualified Hetoimasia.Foundation.Resource as Resource
import Hetoimasia.LuaEngine.Graphics.Texture.Port hiding (textureIdentity)
import qualified Hetoimasia.LuaEngine.Graphics.Texture.Port as Port
import Hetoimasia.LuaEngine.Texture.Backend
  ( BackendTexture (..)
  , RetirementState (..)
  , SinkAnswer (..)
  , TextureBackend (..)
  , Upload (..)
  , UploadFailure (..)
  , UploadSink (..)
  , UploadWork (..)
  )

-- The state ------------------------------------------------------------------------------------------

type JobId = Word64

type TexId = Word64

-- | The backend over one port.
data Backend image ticket = Backend
  { bPort ∷ !(Port image ticket)
  , bState ∷ !(TVar (State image ticket))
  }

data Lifecycle = Running' | Stopping'
  deriving (Eq, Show)

data State image ticket = State
  { sLifecycle ∷ !Lifecycle
  , sJobs ∷ !(Map JobId (Job image ticket))
  , sNextJob ∷ !Word64
  , sTextures ∷ !(Map TexId Tex)
  , sNextTexture ∷ !Word64
  , sBoot ∷ !Boot
  , sEnded ∷ !(Maybe Text)
    -- ^ Why the owner ended, once it has.
  , sFailure ∷ !(Maybe (ExceptionWithContext SomeException))
  , sEvidence ∷ ![(Text, ExceptionWithContext SomeException)]
  , sLate ∷ !Int
    -- ^ Sink answers that were 'SinkLate'.
  }

-- | The table's bootstrap: whether slot 0's placeholder is bound.
data Boot
  = -- | Nobody has needed the table yet.
    BootIdle
  | -- | Someone needs to know whether the placeholder is bound: read it, on the owner's thread.
    BootPending
  | -- | The reading was asked of the owner, with the owner's progress as it stood when it was asked.
    BootChecking !(STM ()) !(Submitted TableReading)
  | -- | Not bound at the last reading: read again when the owner's progress moves.
    BootWaiting !(STM ())
  | BootReady

-- | One accepted upload, from 'backendUpload' to its terminal event.
data Job image ticket = Job
  { jWidth ∷ !Word32
  , jHeight ∷ !Word32
  , jTexels ∷ !ByteString
    -- ^ The borrowed level, until the copy into staging ended.
  , jSink ∷ !UploadSink
  , jCancel ∷ !Bool
  , jFailure ∷ !(Maybe Text)
  , jBorrowEnded ∷ !Bool
  , jRetiredSent ∷ !Bool
  , jLate ∷ !Bool
    -- ^ The pipeline answered 'SinkLate' to the texture: it ended the job, so no terminal event is owed.
  , jWait ∷ !(Maybe (STM ()))
    -- ^ Until this returns, the job waits on the owner's progress.
  , jImage ∷ !(Maybe image)
  , jRegistration ∷ !(Maybe Registration)
  , jBinary ∷ !Bool
    -- ^ The decoded level's alpha classification, read while the level was borrowed.
  , jPhase ∷ !(Phase ticket)
  }

data Phase ticket
  = PNew
  | PAllocating !(STM ()) !(Submitted (Maybe Fault))
    -- ^ The wake is the owner's progress as it stood when the action was submitted, so a relief that lands
    -- between the submission and the reading of a pressure answer is not lost.
  | PAllocated
  | PSubmitting
  | PUploading !ticket
  | PUploaded
  | PRegistering !(STM ()) !(Submitted (Maybe Fault))
  | PRegistered
  | PDelivering
  | PDiscarding !(Submitted (Maybe Fault))
  | PReleasing !(Submitted (Maybe Fault))
  | PRetiring
  | PRetireChecking !(STM ()) !(Submitted TableReading)
  | PSettled
  | PEmitting

-- | A texture the backend registered and offered, until it is proved retired.
data Tex = Tex
  { tRegistration ∷ !Registration
  , tStage ∷ !(TVar TexStage)
  }

data TexStage
  = -- | 'sinkReady' is in flight.
    TexOffered
  | -- | Released while 'sinkReady' was still in flight.
    TexOfferedReleased
  | TexLive
  | TexReleaseRequested
  | TexReleasing !(Submitted (Maybe Fault))
  | TexRetiring !(Maybe (STM ()))
  | TexChecking !(STM ()) !(Submitted TableReading)
  | TexRetired
  | TexFailed !SomeException

-- | A defect of the backend itself or of what it was handed, never a content failure.
newtype BackendDefect = BackendDefect Text
  deriving (Eq, Show)

instance Exception BackendDefect

-- The scope --------------------------------------------------------------------------------------------

-- | Run a body over a backend of this port. The scope's exit closes admission, withdraws what has not
-- issued native work, releases any texture nobody released, and then /drains/: it waits, in STM and
-- outside any uninterruptible release, until every job has answered its terminal event and every
-- texture is proved retired (or failed to be). Only then does the pump stop. A cancellation delivered
-- while it drains is remembered and raised once the drain is over.
withBackend ∷ ∀ image ticket a. Port image ticket → (Backend image ticket → IO a) → IO a
withBackend port body = withWorkerGroup $ \group → do
  var ← newTVarIO (State Running' Map.empty 0 Map.empty 0 BootIdle Nothing Nothing [] 0)
  let backend = Backend port var
  result ← mask $ \restore → do
    outcome ← tryWithContext @SomeException $ restore $ do
      started ← startWorker group (workerDefinition "texture-backend-pump" (\_ → pure ()) (\token () → pumpWorker backend token))
      case started of
        Started _ → pure ()
        StartupFailed _ _ → throwIO (BackendDefect "the texture backend's pump did not start")
        StartRejected _ → throwIO (BackendDefect "the texture backend's pump was not accepted")
      body backend
    closed ← tryWithContext @SomeException (closeAndDrain backend)
    latched ← latchedFailure backend
    let kept = [("texture backend failure", found) | Just found ← [latched]]
    case (outcome, closed) of
      (Right value, Right ()) → pure (Right value)
      (Right _, Left closing) → Left <$> withEvidence closing kept
      (Left primary, Right ()) → Left <$> withEvidence primary kept
      (Left primary, Left closing) → Left <$> withEvidence primary (("texture backend close", closing) : kept)
  case result of
    Left failure → rethrowIO failure
    Right value → do
      report ← closeWorkerGroup group
      latched ← latchedFailure backend
      case latched of
        Just failure → rethrowIO failure
        Nothing →
          unclean report >>= \case
            Nothing → pure value
            Just failure → rethrowIO failure

-- | The upload port the pipeline is injected with. The backend must outlive the pipeline and every
-- texture it delivered; 'withBackend' is that scope.
textureBackend ∷ ∀ image ticket. Backend image ticket → TextureBackend
textureBackend backend = TextureBackend {backendUpload = accept backend}

-- | Accept one decoded level: record the job and return at once. Nothing native is touched here.
accept ∷ ∀ image ticket. Backend image ticket → Upload → UploadSink → IO UploadWork
accept backend upload sink = do
  let width = uploadWidth upload
      height = uploadHeight upload
      texels = uploadTexels upload
      expected = 4 * toInteger width * toInteger height
  when (width == 0 || height == 0 || toInteger (ByteString.length texels) /= expected) $
    throwIO (BackendDefect (Text.pack ("the pipeline handed the backend a level of " <> show (ByteString.length texels) <> " bytes for " <> show width <> " x " <> show height <> " texels")))
  taken ← atomically $ do
    st ← readTVar (bState backend)
    case (sLifecycle st, sFailure st) of
      (Running', Nothing) → do
        let job =
              Job
                { jWidth = width
                , jHeight = height
                , jTexels = texels
                , jSink = sink
                , -- An owner that has ended takes nothing: the job is accepted so that its terminal event is
                  -- owed and delivered, and it is failed at once, honestly.
                  jCancel = isJust (sEnded st)
                , jFailure = ("the graphics owner ended: " <>) <$> sEnded st
                , jBorrowEnded = False
                , jRetiredSent = False
                , jLate = False
                , jWait = Nothing
                , jImage = Nothing
                , jRegistration = Nothing
                , jBinary = False
                , jPhase = PNew
                }
            jid = sNextJob st
        writeTVar (bState backend) st {sJobs = Map.insert jid job (sJobs st), sNextJob = jid + 1}
        pure (Just jid)
      _ → pure Nothing
  case taken of
    Nothing → throwIO (BackendDefect "the texture backend is closed or has failed, and takes no more uploads")
    Just jid → pure UploadWork {uploadCancel = atomically (modifyJob backend jid (\job → job {jCancel = True}))}

-- Observation ------------------------------------------------------------------------------------------

-- | The backend read in one transaction.
data BackendReading = BackendReading
  { readingJobs ∷ !Int
    -- ^ Accepted uploads that have not answered their terminal event.
  , readingJobPhases ∷ ![Text]
  , readingTextureStages ∷ ![Text]
    -- ^ Where each texture not yet proved retired (or failed) stands, for an observer to wait on.
  , readingLiveTextures ∷ !Int
    -- ^ Textures offered or delivered and not yet proved retired (or failed).
  , readingBound ∷ !Bool
    -- ^ The table's placeholder is bound.
  , readingOpen ∷ !Bool
  , readingEnded ∷ !(Maybe Text)
  , readingLate ∷ !Int
  , readingFailed ∷ !Bool
  }
  deriving (Eq, Show)

readBackend ∷ Backend image ticket → STM BackendReading
readBackend backend = do
  st ← readTVar (bState backend)
  stages ← traverse (readTVar . tStage) (Map.elems (sTextures st))
  let live = length (filter (not . terminalStage) stages)
  pure
    BackendReading
      { readingJobs = Map.size (sJobs st)
      , readingJobPhases = [phaseName (jPhase job) | job ← Map.elems (sJobs st)]
      , readingTextureStages = [stageName stage | stage ← stages, not (terminalStage stage)]
      , readingLiveTextures = live
      , readingBound = case sBoot st of
          BootReady → True
          _ → False
      , readingOpen = sLifecycle st == Running'
      , readingEnded = sEnded st
      , readingLate = sLate st
      , readingFailed = isJust (sFailure st)
      }

-- | Wait, in STM, until the table's placeholder is bound (read on the owner's thread, and again as its progress
-- moves), or the owner has ended. Interruptible: it is assembly, and a cancellation ends it.
awaitBound ∷ Backend image ticket → IO ()
awaitBound backend = do
  atomically . modifySTMState backend $ \st → case sBoot st of
    BootIdle → st {sBoot = BootPending}
    _ → st
  atomically $ do
    st ← readTVar (bState backend)
    case (sBoot st, sEnded st) of
      (BootReady, _) → pure ()
      (_, Just _) → pure ()
      _ → retry

-- | Wait, in STM, for the first failure the backend latched: a defect, a raised action, a cleanup that
-- failed. A supervisor composes it into a supervised wait.
awaitBackendFailure ∷ Backend image ticket → STM (ExceptionWithContext SomeException)
awaitBackendFailure backend = readTVar (bState backend) >>= maybe retry pure . sFailure

-- | The failures recorded beside the first, oldest first.
backendEvidence ∷ Backend image ticket → STM [(Text, ExceptionWithContext SomeException)]
backendEvidence backend = sEvidence <$> readTVar (bState backend)

phaseName ∷ Phase ticket → Text
phaseName = \case
  PNew → "new"
  PAllocating _ _ → "allocating"
  PAllocated → "allocated"
  PSubmitting → "submitting"
  PUploading _ → "uploading"
  PUploaded → "uploaded"
  PRegistering _ _ → "registering"
  PRegistered → "registered"
  PDelivering → "delivering"
  PDiscarding _ → "discarding"
  PReleasing _ → "releasing"
  PRetiring → "retiring"
  PRetireChecking _ _ → "retiring"
  PSettled → "settled"
  PEmitting → "emitting"

stageName ∷ TexStage → Text
stageName = \case
  TexOffered → "offered"
  TexOfferedReleased → "offered-released"
  TexLive → "live"
  TexReleaseRequested → "release-requested"
  TexReleasing _ → "releasing"
  TexRetiring _ → "retiring"
  TexChecking _ _ → "retiring"
  TexRetired → "retired"
  TexFailed _ → "failed"

terminalStage ∷ TexStage → Bool
terminalStage = \case
  TexRetired → True
  TexFailed _ → True
  _ → False

-- State helpers ----------------------------------------------------------------------------------------

modifyJob ∷ Backend image ticket → JobId → (Job image ticket → Job image ticket) → STM ()
modifyJob backend jid f = do
  st ← readTVar (bState backend)
  case Map.lookup jid (sJobs st) of
    Nothing → pure ()
    Just job → writeTVar (bState backend) st {sJobs = Map.insert jid (f job) (sJobs st)}

setPhase ∷ Backend image ticket → JobId → Phase ticket → STM ()
setPhase backend jid phase = modifyJob backend jid (\job → job {jPhase = phase})

-- | Latch a failure: the first is the backend's, every later one is evidence beside it, bounded.
latchSTM ∷ Backend image ticket → Text → ExceptionWithContext SomeException → STM ()
latchSTM backend label failure = do
  st ← readTVar (bState backend)
  writeTVar (bState backend) $ case sFailure st of
    Nothing → st {sFailure = Just failure}
    Just _
      | length (sEvidence st) < 16 → st {sEvidence = sEvidence st <> [(label, failure)]}
      | otherwise → st

latchIO ∷ Backend image ticket → Text → ExceptionWithContext SomeException → IO ()
latchIO backend label failure = atomically (latchSTM backend label failure)

-- | The failure with the evidence recorded beside it.
latchedFailure ∷ Backend image ticket → IO (Maybe (ExceptionWithContext SomeException))
latchedFailure backend = do
  (first, evidence) ← atomically ((\st → (sFailure st, sEvidence st)) <$> readTVar (bState backend))
  case first of
    Nothing → pure Nothing
    Just found → Just <$> withEvidence found evidence

withEvidence ∷ ExceptionWithContext SomeException → [(Text, ExceptionWithContext SomeException)] → IO (ExceptionWithContext SomeException)
withEvidence primary [] = pure primary
withEvidence primary evidence = fromMaybe primary <$> composeCleanup (Just primary) evidence

defect ∷ Text → IO (ExceptionWithContext SomeException)
defect why = do
  raised ← tryWithContext @SomeException (throwIO (BackendDefect why))
  either pure (\() → throwIO (BackendDefect why)) raised

faultText ∷ Fault → Text
faultText = \case
  FaultPressure → "a native budget answered backpressure"
  FaultNotReady → "the texture table was not bound"
  FaultFatal why → why

-- | An exception recorded as evidence by a transaction, which has no context of its own to attach.
plain ∷ SomeException → ExceptionWithContext SomeException
plain = ExceptionWithContext mempty

-- | Add a failure beside the primary one a job already has: the primary is kept first.
failWith ∷ Text → Job image ticket → Job image ticket
failWith why job =
  job
    { jFailure = Just (maybe why (\first → first <> "; then " <> why) (jFailure job))
    , jCancel = True
    }

-- The pump ---------------------------------------------------------------------------------------------

data Step
  = StepDone
  | StepProgress
  | StepIO (IO ())

pumpWorker ∷ ∀ image ticket. Backend image ticket → StopToken → IO ()
pumpWorker backend token = mask $ \restore → do
  outcome ← tryWithContext @SomeException (restore loop)
  case outcome of
    Right () → pure ()
    Left caught → do
      latchIO backend "texture backend pump" caught
      abandonAll backend "the texture backend's pump failed and advances nothing again"
      rethrowIO caught
  where
    loop = atomically (nextStep backend token) >>= \case
      StepDone → pure ()
      StepProgress → loop
      StepIO act → do
        outcome ← tryWithContext @SomeException act
        case outcome of
          Right () → loop
          Left caught@(ExceptionWithContext _ raised)
            | Just (SomeAsyncException _) ← fromException raised → rethrowIO caught
            | otherwise → latchIO backend "texture backend step" caught >> loop

-- | The pump will advance nothing again. Every job is told so, once, and every texture is reported failed to
-- retire; no native object is claimed reclaimed, because none was proved so: what the pump had made stays the
-- session's managed resources, which the owner's own teardown destroys (and fails, if it cannot). Without this a
-- pipeline waiting on a job's terminal event would wait for a thread that is gone.
abandonAll ∷ Backend image ticket → Text → IO ()
abandonAll backend why = do
  jobs ← atomically $ do
    st ← readTVar (bState backend)
    forM_ (Map.elems (sTextures st)) $ \tex → do
      stage ← readTVar (tStage tex)
      unless (terminalStage stage) $
        writeTVar (tStage tex) (TexFailed (toException (BackendDefect ("the texture was not proved retired: " <> why))))
    writeTVar (bState backend) st {sJobs = Map.empty, sTextures = Map.empty, sLifecycle = Stopping'}
    pure (Map.elems (sJobs st))
  forM_ jobs $ \job → unless (jLate job) $ do
    unless (jRetiredSent job) (void (tryWithContext @SomeException (sinkBuffersRetired (jSink job))))
    void (tryWithContext @SomeException (sinkFailed (jSink job) (UploadFailure why)))

-- | The next thing for the pump, in one transaction: the first job or texture with something to do, the
-- table's bootstrap, and otherwise a wait on every variable read, or a stop.
nextStep ∷ ∀ image ticket. Backend image ticket → StopToken → STM Step
nextStep backend token = do
  st ← readTVar (bState backend)
  standing ← portStanding (bPort backend)
  case standing of
    Ended why | sEnded st == Nothing → ownerEnded backend why >> pure StepProgress
    _ → do
      let candidates =
            [jobStep backend standing jid job | (jid, job) ← Map.toAscList (sJobs st)]
              <> [textureStep backend tid tex | (tid, tex) ← Map.toAscList (sTextures st)]
              <> [bootStep backend]
      found ← firstJust candidates
      case found of
        Just step → pure step
        Nothing → do
          stopping ← stopRequested token
          if stopping then pure StepDone else retry

firstJust ∷ [STM (Maybe a)] → STM (Maybe a)
firstJust = foldr (\candidate rest → candidate >>= maybe rest (pure . Just)) (pure Nothing)

-- | Note the owner's end once, whichever way it was learned.
noteEnded ∷ Backend image ticket → Text → STM ()
noteEnded backend why = do
  st ← readTVar (bState backend)
  when (sEnded st == Nothing) (ownerEnded backend why)

-- | The owner has ended: nothing more will run on its thread, and what it made is retired by its own
-- teardown, which this backend cannot prove. Every unfinished job fails and every texture not proved
-- retired is reported failed to retire, so no credit is returned for a native use that may remain.
ownerEnded ∷ Backend image ticket → Text → STM ()
ownerEnded backend why = do
  st ← readTVar (bState backend)
  writeTVar (bState backend) st {sEnded = Just why, sJobs = Map.map (failWith ("the graphics owner ended: " <> why)) (sJobs st)}
  forM_ (Map.elems (sTextures st)) $ \tex → do
    stage ← readTVar (tStage tex)
    unless (terminalStage stage) $
      writeTVar (tStage tex) (TexFailed (toException (BackendDefect ("the graphics owner ended before the texture was proved retired: " <> why))))

-- | Whether a job is being ended: cancelled, failed or stopping.
ending ∷ State image ticket → Job image ticket → Bool
ending st job = jCancel job || isJust (jFailure job) || sLifecycle st /= Running'

-- | One job's next step, if it has one.
jobStep ∷ ∀ image ticket. Backend image ticket → Standing → JobId → Job image ticket → STM (Maybe Step)
jobStep backend standing jid job = do
  st ← readTVar (bState backend)
  waiting ← case jWait job of
    Nothing → pure False
    -- A job being ended waits for nothing: its cancellation is what it was waiting for.
    Just _ | ending st job → pure False
    Just wake → (wake >> pure False) `orElse` pure True
  if waiting
    then pure Nothing
    else
      if isJust (jWait job)
        then -- The owner's progress the job waited for has come: take the wait off and look again.
          Just StepProgress <$ modifyJob backend jid (\found → found {jWait = Nothing})
        else -- The borrow ends once the copy ended, or the job ended without one; the pipeline is then told
          -- so exactly once, whatever else the job is doing.
          if jBorrowEnded job && not (jRetiredSent job)
            then do
              modifyJob backend jid (\found → found {jRetiredSent = True, jTexels = ByteString.empty})
              pure (Just (StepIO (retireBorrow backend jid (jSink job))))
            else phaseStep st
  where
    atRest st = ending st job
    phaseStep st = case jPhase job of
      PNew
        | atRest st → beginDisposal backend jid job
        | otherwise → whenRunning $ do
            let action = allocateAction backend jid (jWidth job) (jHeight job)
            wake ← portWatch (bPort backend)
            portAct (bPort backend) action >>= \case
              Right sub → Just StepProgress <$ setPhase backend jid (PAllocating wake sub)
              Left refusal → refused refusal
      PAllocating wake sub → outcomeOf sub $ \case
        Returned Nothing → advance PAllocated
        Returned (Just FaultPressure) → waitFor wake PNew
        Returned (Just fault) → failAt PNew (faultText fault)
        Raised raised → raisedAt PNew "allocating the texture's image" raised
        NotRun refusal → failAt PNew (refusalText refusal)
      PAllocated
        | atRest st → beginDisposal backend jid job
        | otherwise → do
            setPhase backend jid PSubmitting
            pure (Just (StepIO (submitUpload backend jid)))
      PSubmitting → pure Nothing
      PUploading ticket → do
        standingOf ← portTicket (bPort backend) ticket
        case standingOf of
          TicketComplete → advance PUploaded
          TicketCancelled
            | atRest st → advance PAllocated
            | otherwise → failAt PAllocated "the upload was cancelled although nobody cancelled it"
          TicketLost → failAt PAllocated "the device was lost during the upload"
          _
            | atRest st →
                portCancel (bPort backend) ticket >>= \case
                  CancelledNow → advance PAllocated
                  _ → pure Nothing
            | otherwise → pure Nothing
      PUploaded
        | atRest st → beginDisposal backend jid job
        | otherwise → whenRunning $ do
            boot ← sBoot <$> readTVar (bState backend)
            case boot of
              BootReady → case jImage job of
                Nothing → failAt PUploaded "an uploaded job holds no image"
                Just image → do
                  wake ← portWatch (bPort backend)
                  portAct (bPort backend) (registerAction backend jid image (Level (jWidth job) (jHeight job) (jBinary job))) >>= \case
                    Right sub → Just StepProgress <$ setPhase backend jid (PRegistering wake sub)
                    Left refusal → refused refusal
              -- The table's bootstrap is read once, when the first upload needs it, and read again as the owner
              -- progresses until it is bound. Nothing is registered before it is.
              BootIdle → Just StepProgress <$ modifySTMState backend (\now → now {sBoot = BootPending})
              _ → pure Nothing
      PRegistering wake sub → outcomeOf sub $ \case
        Returned Nothing → advance PRegistered
        Returned (Just FaultPressure) → waitFor wake PUploaded
        Returned (Just FaultNotReady) → do
          -- The table said it was not bound although the bootstrap read it so: read it again.
          st' ← readTVar (bState backend)
          writeTVar (bState backend) st' {sBoot = BootPending}
          waitFor wake PUploaded
        Returned (Just (FaultFatal why)) → failAt PUploaded why
        Raised raised → raisedAt PUploaded "registering the texture" raised
        NotRun refusal → failAt PUploaded (refusalText refusal)
      PRegistered
        | atRest st → beginDisposal backend jid job
        | otherwise → case jRegistration job of
            Nothing → failAt PRegistered "a registered job holds no registration"
            Just registration → do
              tid ← claimTexture backend registration
              setPhase backend jid PDelivering
              pure (Just (StepIO (deliver backend jid tid registration (jSink job))))
      PDelivering → pure Nothing
      PDiscarding sub → outcomeOf sub $ \case
        Returned Nothing → advance PSettled
        Returned (Just fault) → cleanupFailed (faultText fault)
        Raised raised → cleanupRaised "discarding the texture's image" raised
        NotRun refusal → cleanupFailed (refusalText refusal)
      PReleasing sub → outcomeOf sub $ \case
        Returned Nothing → advance PRetiring
        Returned (Just fault) → cleanupFailed (faultText fault)
        Raised raised → cleanupRaised "releasing the texture's registration" raised
        NotRun refusal → cleanupFailed (refusalText refusal)
      PRetiring → case jRegistration job of
        Nothing → advance PSettled
        Just _ → do
          -- The reading is the owner's, taken at the start of one of its steps, after the previous step's table
          -- refresh: so a slot released and reclaimed there is seen reclaimed.
          wake ← portWatch (bPort backend)
          portAct (bPort backend) (\device → deviceTable device) >>= \case
            Right sub → Just StepProgress <$ setPhase backend jid (PRetireChecking wake sub)
            Left refusal → refused refusal
      PRetireChecking wake sub → outcomeOf sub $ \case
        Returned reading
          | Just registration ← jRegistration job, Set.member (registrationSlot registration) (tableRetiring reading) → waitFor wake PRetiring
          | otherwise → advance PSettled
        Raised raised → cleanupRaised "reading the table for a texture's retirement" raised
        NotRun refusal → cleanupFailed (refusalText refusal)
      PSettled → do
        -- The borrow ends with the job, if the copy never began.
        unless (jBorrowEnded job) (modifyJob backend jid (\found → found {jBorrowEnded = True}))
        if not (jBorrowEnded job)
          then pure (Just StepProgress)
          else do
            setPhase backend jid PEmitting
            pure (Just (StepIO (emitTerminal backend jid job)))
      PEmitting → pure Nothing

    -- The step transitions, all of them writes and so all of them progress.
    advance next = Just StepProgress <$ setPhase backend jid next
    failAt next why = Just StepProgress <$ modifyJob backend jid (\found → (failWith why found) {jPhase = next})
    raisedAt next what (SomeException raised) = do
      let why = what <> " raised: " <> Text.pack (show raised)
      latchSTM backend what (plain (SomeException raised))
      failAt next why
    cleanupFailed why = do
      -- A cleanup that failed is evidence beside the job's own failure, kept until the scope closes, and is
      -- never retried: the native object may still exist, so nothing downstream may call it reclaimed.
      latchSTM backend "cleanup of a texture's native objects" (plain (toException (BackendDefect why)))
      Just StepProgress <$ modifyJob backend jid (\found → (failWith ("cleanup failed: " <> why) found) {jPhase = PSettled})
    cleanupRaised what (SomeException raised) = do
      latchSTM backend what (plain (SomeException raised))
      cleanupFailed (what <> " raised: " <> Text.pack (show raised))
    waitFor wake next = Just StepProgress <$ modifyJob backend jid (\found → found {jPhase = next, jWait = Just wake})
    outcomeOf sub k = submittedOutcome sub >>= maybe (pure Nothing) k
    whenRunning k = case standing of
      Running → k
      _ → pure Nothing
    refused = \case
      PortFull → pure Nothing
      PortNotStarted → pure Nothing
      PortEnded why → Just StepProgress <$ noteEnded backend why

refusalText ∷ PortRefusal → Text
refusalText = \case
  PortFull → "the owner's queue was full"
  PortNotStarted → "the owner had not started"
  PortEnded why → "the graphics owner ended: " <> why

-- | The bootstrap's next step. It is read on the owner's thread, as an action: an action runs at the start of an
-- owner step, after the previous step's table refresh, so a descriptor written at the end of one step is seen at the
-- start of the next and a wake that fires between the owner's poll and its refresh cannot be missed.
bootStep ∷ Backend image ticket → STM (Maybe Step)
bootStep backend = readTVar (bState backend) >>= \st → case sBoot st of
  BootIdle → pure Nothing
  BootReady → pure Nothing
  BootPending → do
    wake ← portWatch (bPort backend)
    portAct (bPort backend) (\device → deviceTable device) >>= \case
      Right sub → Just StepProgress <$ writeTVar (bState backend) st {sBoot = BootChecking wake sub}
      Left (PortEnded why) → Just StepProgress <$ noteEnded backend why
      Left _ → pure Nothing
  BootChecking wake sub →
    submittedOutcome sub >>= \case
      Nothing → pure Nothing
      Just (Returned reading) →
        Just StepProgress <$ writeTVar (bState backend) st {sBoot = if tablePlaceholderWritten reading then BootReady else BootWaiting wake}
      Just (Raised raised) → do
        latchSTM backend "reading the texture table" (plain raised)
        Just StepProgress <$ writeTVar (bState backend) st {sBoot = BootWaiting wake}
      Just (NotRun (PortEnded why)) → Just StepProgress <$ noteEnded backend why
      Just (NotRun _) → Just StepProgress <$ writeTVar (bState backend) st {sBoot = BootPending}
  BootWaiting wake → do
    waiting ← (wake >> pure False) `orElse` pure True
    if waiting
      then pure Nothing
      else Just StepProgress <$ writeTVar (bState backend) st {sBoot = BootPending}

modifySTMState ∷ Backend image ticket → (State image ticket → State image ticket) → STM ()
modifySTMState backend f = readTVar (bState backend) >>= writeTVar (bState backend) . f

-- | Take a finished job apart, in dependency order: the registration through the table, else the image.
beginDisposal ∷ Backend image ticket → JobId → Job image ticket → STM (Maybe Step)
beginDisposal backend jid job = do
  let port = bPort backend
      noCopy = case jPhase job of
        PUploading _ → False
        _ → True
  -- A job that never admitted its bytes has no borrow left to end.
  when (noCopy && not (jBorrowEnded job)) (modifyJob backend jid (\found → found {jBorrowEnded = True}))
  case (jRegistration job, jImage job) of
    (Just registration, _) →
      portAct port (releaseAction registration) >>= \case
        Right sub → Just StepProgress <$ setPhase backend jid (PReleasing sub)
        Left (PortEnded why) → ended why
        Left _ → pure Nothing
    (Nothing, Just image) →
      portAct port (discardAction image) >>= \case
        Right sub → Just StepProgress <$ setPhase backend jid (PDiscarding sub)
        Left (PortEnded why) → ended why
        Left _ → pure Nothing
    (Nothing, Nothing) → Just StepProgress <$ setPhase backend jid PSettled
  where
    ended why = do
      noteEnded backend why
      Just StepProgress
        <$ modifyJob
          backend
          jid
          (\found → (failWith ("the graphics owner ended, so the native objects were not released by the backend: " <> why) found) {jPhase = PSettled})

-- Owner-thread actions ------------------------------------------------------------------------------------

faultOf ∷ Fault → Maybe Fault
faultOf = Just

-- | Allocate a job's image on the owner's thread and record it in the job before the action returns.
allocateAction ∷ ∀ image ticket. Backend image ticket → JobId → Word32 → Word32 → Device image → IO (Maybe Fault)
allocateAction backend jid width height device = mask_ $
  deviceAllocate device width height >>= \case
    Left fault → pure (faultOf fault)
    Right image →
      atomically (trackImage backend jid image) >>= \case
        True → pure Nothing
        False →
          -- The job is gone: nobody else will ever name this image.
          deviceDiscard device image >>= \case
            Right () → pure (Just (FaultFatal "a texture image was allocated for a job that no longer exists"))
            Left fault → pure (Just (FaultFatal ("a texture image was allocated for a job that no longer exists, and its release failed: " <> faultText fault)))

trackImage ∷ Backend image ticket → JobId → image → STM Bool
trackImage backend jid image = do
  st ← readTVar (bState backend)
  case Map.lookup jid (sJobs st) of
    Nothing → pure False
    Just job → True <$ writeTVar (bState backend) st {sJobs = Map.insert jid job {jImage = Just image} (sJobs st)}

-- | Register a job's uploaded image on the owner's thread and record the registration before returning.
registerAction ∷ ∀ image ticket. Backend image ticket → JobId → image → Level → Device image → IO (Maybe Fault)
registerAction backend jid image level device = mask_ $
  deviceRegister device image level >>= \case
    Left fault → pure (faultOf fault)
    Right registration →
      atomically (trackRegistration backend jid registration) >>= \case
        True → pure Nothing
        False →
          deviceRelease device registration >>= \case
            Right () → pure (Just (FaultFatal "a texture was registered for a job that no longer exists"))
            Left fault → pure (Just (FaultFatal ("a texture was registered for a job that no longer exists, and its release failed: " <> faultText fault)))

trackRegistration ∷ Backend image ticket → JobId → Registration → STM Bool
trackRegistration backend jid registration = do
  st ← readTVar (bState backend)
  case Map.lookup jid (sJobs st) of
    Nothing → pure False
    Just job → True <$ writeTVar (bState backend) st {sJobs = Map.insert jid job {jRegistration = Just registration} (sJobs st)}

discardAction ∷ image → Device image → IO (Maybe Fault)
discardAction image device = deviceDiscard device image <&> either Just (const Nothing)

releaseAction ∷ Registration → Device image → IO (Maybe Fault)
releaseAction registration device = deviceRelease device registration <&> either Just (const Nothing)

-- The pump's IO steps ---------------------------------------------------------------------------------------

-- | Tell the pipeline it may stop charging the borrowed level to its lane.
retireBorrow ∷ Backend image ticket → JobId → UploadSink → IO ()
retireBorrow backend _ sink = do
  answer ← sinkBuffersRetired sink
  when (answer == SinkLate) (atomically (modifySTMState backend (\st → st {sLate = sLate st + 1})))

-- | Admit the level's bytes. The ticket is recorded in the same masked step that obtains it.
submitUpload ∷ ∀ image ticket. Backend image ticket → JobId → IO ()
submitUpload backend jid = do
  taken ← atomically $ do
    st ← readTVar (bState backend)
    pure (Map.lookup jid (sJobs st))
  case taken of
    Nothing → pure ()
    Just job → case jImage job of
      Nothing → atomically (modifyJob backend jid (\found → (failWith "an allocated job holds no image" found) {jPhase = PNew}))
      Just image → do
        let texels = jTexels job
            !binary = binaryAlpha texels
        wake ← atomically (portWatch (bPort backend))
        mask_ $ do
          admitted ← tryWithContext @SomeException (portUpload (bPort backend) image texels)
          atomically $ case admitted of
            Right (Right ticket) →
              modifyJob backend jid (\found → found {jPhase = PUploading ticket, jBorrowEnded = True, jTexels = ByteString.empty, jBinary = binary})
            Right (Left AdmissionPressure) →
              modifyJob backend jid (\found → found {jPhase = PAllocated, jWait = Just wake})
            Right (Left AdmissionEnded) →
              modifyJob backend jid (\found → (failWith "the graphics owner admits no more uploads" found) {jPhase = PAllocated})
            Right (Left (AdmissionFault why)) →
              modifyJob backend jid (\found → (failWith ("the upload was refused: " <> why) found) {jPhase = PAllocated})
            Left caught@(ExceptionWithContext _ (SomeException raised)) → do
              latchSTM backend "admitting the texture's upload" caught
              modifyJob backend jid (\found -> (failWith ("admitting the upload raised: " <> Text.pack (show raised)) found) {jPhase = PAllocated})

-- | Offer the registered texture. The pipeline's answer decides who owns it.
deliver ∷ ∀ image ticket. Backend image ticket → JobId → TexId → Registration → UploadSink → IO ()
deliver backend jid tid registration sink = do
  tex ← atomically $ do
    st ← readTVar (bState backend)
    pure (Map.lookup tid (sTextures st))
  case tex of
    Nothing → atomically (modifyJob backend jid (\found → (failWith "an offered texture's record was lost" found) {jPhase = PRegistered}))
    Just offered → do
      let texture =
            BackendTexture
              { textureIdentity = textureIdentityOf registration
              , textureRelease = releaseTexture backend offered
              }
      answered ← tryWithContext @SomeException (sinkReady sink texture)
      case answered of
        Right SinkTaken → atomically $ do
          stage ← readTVar (tStage offered)
          writeTVar (tStage offered) $ case stage of
            TexOfferedReleased → TexReleaseRequested
            _ → TexLive
          modifySTMState backend (\st → st {sJobs = Map.delete jid (sJobs st)})
        Right SinkLate → atomically $ do
          -- The pipeline ended the job: it took nothing, and the texture is still the backend's.
          modifySTMState backend (\st → st {sTextures = Map.delete tid (sTextures st), sLate = sLate st + 1})
          modifyJob backend jid (\found → found {jLate = True, jCancel = True, jPhase = PRegistered})
        Left caught@(ExceptionWithContext _ (SomeException raised)) → atomically $ do
          latchSTM backend "answering the pipeline's sink" caught
          modifySTMState backend (\st → st {sTextures = Map.delete tid (sTextures st)})
          modifyJob backend jid (\found → (failWith ("the sink raised: " <> Text.pack (show raised)) found) {jPhase = PRegistered})

textureIdentityOf ∷ Registration → Word64
textureIdentityOf = Port.textureIdentity . registrationRef

-- | Deliver the terminal event, once, and drop the job.
emitTerminal ∷ ∀ image ticket. Backend image ticket → JobId → Job image ticket → IO ()
emitTerminal backend jid job = do
  answered ← tryWithContext @SomeException $
    if jLate job
      then pure SinkTaken
      else case jFailure job of
        Just why → sinkFailed (jSink job) (UploadFailure why)
        Nothing → sinkWithdrawn (jSink job)
  atomically $ do
    case answered of
      Right SinkLate → modifySTMState backend (\st → st {sLate = sLate st + 1})
      Right SinkTaken → pure ()
      Left caught → latchSTM backend "delivering the terminal event" caught
    modifySTMState backend (\st → st {sJobs = Map.delete jid (sJobs st)})

-- Textures ---------------------------------------------------------------------------------------------------

-- | Record a registered texture the backend is about to offer. Its record exists before the offer, so a
-- release that arrives the moment the pipeline took it finds it.
claimTexture ∷ Backend image ticket → Registration → STM TexId
claimTexture backend registration = do
  st ← readTVar (bState backend)
  stage ← newTVar TexOffered
  let tid = sNextTexture st
  writeTVar (bState backend) st {sTextures = Map.insert tid (Tex registration stage) (sTextures st), sNextTexture = tid + 1}
  pure tid

-- | The release the lease calls, once: revoke at once (the logical release a publication's check sees),
-- ask the table to release when the holds allow, and answer the reading of the retirement. Never waits.
releaseTexture ∷ Backend image ticket → Tex → IO (STM RetirementState)
releaseTexture backend tex = do
  atomically $ do
    stage ← readTVar (tStage tex)
    case stage of
      TexLive → request TexReleaseRequested
      TexOffered → request TexOfferedReleased
      _ → pure ()
  pure (retirementOf (tStage tex))
  where
    request next = do
      portMarkReleased (bPort backend) (registrationRef (tRegistration tex))
      writeTVar (tStage tex) next

retirementOf ∷ TVar TexStage → STM RetirementState
retirementOf stage =
  readTVar stage <&> \case
    TexRetired → ProviderComplete
    TexFailed failure → ProviderFailed failure
    _ → ProviderPending

-- | A texture's next step, if it has one.
textureStep ∷ ∀ image ticket. Backend image ticket → TexId → Tex → STM (Maybe Step)
textureStep backend tid tex = do
  stage ← readTVar (tStage tex)
  case stage of
    TexReleaseRequested →
      portRelease (bPort backend) (releaseAction (tRegistration tex)) >>= \case
        Right sub → Just StepProgress <$ writeTVar (tStage tex) (TexReleasing sub)
        Left (PortEnded why) → do
          noteEnded backend why
          Just StepProgress <$ failTexture ("the graphics owner ended before the release ran: " <> why)
        Left _ → pure Nothing
    TexReleasing sub →
      submittedOutcome sub >>= \case
        Nothing → pure Nothing
        Just (Returned Nothing) → Just StepProgress <$ writeTVar (tStage tex) (TexRetiring Nothing)
        Just (Returned (Just fault)) → Just StepProgress <$ failTexture ("the table's release failed: " <> faultText fault)
        Just (Raised raised) → do
          latchSTM backend "releasing a texture" (plain raised)
          Just StepProgress <$ writeTVar (tStage tex) (TexFailed raised)
        Just (NotRun refusal) → Just StepProgress <$ failTexture (refusalText refusal)
    TexRetiring wake → do
      waiting ← case wake of
        Nothing → pure False
        Just w → (w >> pure False) `orElse` pure True
      if waiting
        then pure Nothing
        else do
          fresh ← portWatch (bPort backend)
          portAct (bPort backend) (\device → deviceTable device) >>= \case
            Right sub → Just StepProgress <$ writeTVar (tStage tex) (TexChecking fresh sub)
            Left (PortEnded why) → do
              noteEnded backend why
              Just StepProgress <$ failTexture ("the graphics owner ended before the texture was proved retired: " <> why)
            Left _ → pure Nothing
    TexChecking wake sub →
      submittedOutcome sub >>= \case
        Nothing → pure Nothing
        Just (Returned reading) ->
          Just StepProgress
            <$ writeTVar
              (tStage tex)
              (if Set.member (registrationSlot (tRegistration tex)) (tableRetiring reading) then TexRetiring (Just wake) else TexRetired)
        Just (Raised raised) → do
          latchSTM backend "reading the table for a texture's retirement" (plain raised)
          Just StepProgress <$ writeTVar (tStage tex) (TexFailed raised)
        Just (NotRun refusal) → Just StepProgress <$ failTexture (refusalText refusal)
    TexRetired → Just StepProgress <$ forget
    TexFailed _ → Just StepProgress <$ forget
    _ → pure Nothing
  where
    failTexture why = do
      let raised = toException (BackendDefect why)
      latchSTM backend "texture release" (plain raised)
      writeTVar (tStage tex) (TexFailed raised)
    forget = modifySTMState backend (\st → st {sTextures = Map.delete tid (sTextures st)})

-- The close ---------------------------------------------------------------------------------------------------

-- | Close admission, ask every job to end, release what nobody released, and wait for the lot. A
-- cancellation delivered while it waits is remembered and the wait resumes: the scope must not unwind under
-- a native object the owner may still be using. The first exception is raised once the drain is over.
closeAndDrain ∷ Backend image ticket → IO ()
closeAndDrain backend = do
  atomically $ do
    modifySTMState backend (\st → st {sLifecycle = Stopping'})
    st ← readTVar (bState backend)
    forM_ (Map.elems (sTextures st)) $ \tex → do
      stage ← readTVar (tStage tex)
      case stage of
        TexLive → do
          portMarkReleased (bPort backend) (registrationRef (tRegistration tex))
          writeTVar (tStage tex) TexReleaseRequested
        _ → pure ()
  remembered ← newIORef Nothing
  let keep caught = atomicModifyIORef' remembered (\held → (Just (fromMaybe caught held), ()))
      wait =
        tryWithContext @SomeException (atomically drained) >>= \case
          Right () → pure ()
          Left caught@(ExceptionWithContext _ raised)
            | Just (SomeAsyncException _) ← fromException raised → keep caught >> wait
            | otherwise → keep caught
  wait
  readIORef remembered >>= maybe (pure ()) rethrowIO
  where
    drained = do
      st ← readTVar (bState backend)
      unless (Map.null (sJobs st)) retry
      for_ (Map.elems (sTextures st)) $ \tex → do
        stage ← readTVar (tStage tex)
        unless (terminalStage stage) retry

-- | What a worker group's report holds that is not a clean exit.
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
      primary ← defect "the texture backend's pump did not exit cleanly"
      Just <$> withEvidence primary evidence
  where
    resultFailure = \case
      Succeeded () → []
      Failed raised → [raised]
      Cancelled raised → [raised]

-- Alpha ----------------------------------------------------------------------------------------------------

-- | Whether every texel of an RGBA8 level has alpha 0 or 255: the cutout mark the renderer takes.
-- Premultiplying never changes alpha, so the answer is the decoded image's own.
binaryAlpha ∷ ByteString → Bool
binaryAlpha bytes = go 3
  where
    size = ByteString.length bytes
    go i
      | i >= size = True
      | otherwise =
          let a = ByteString.unsafeIndex bytes i
           in (a == 0 || a == 255) && go (i + 4)
