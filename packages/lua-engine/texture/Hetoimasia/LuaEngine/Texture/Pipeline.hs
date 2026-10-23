-- | The session-owned texture pipeline (LFE-16): two lanes over the shared read pool, one decode
-- worker, and the injected upload backend, with the state that makes each obligation exact.
--
-- This is the hidden implementation of "Hetoimasia.LuaEngine.Texture"; that module's header is the
-- contract. What follows is the machine: who owns each piece of state, which thread writes it, and
-- what keeps each transition honest.
--
-- = One state, one variable
--
-- Everything the pipeline decides is a property of one transaction on 'PState', held in one
-- 'TVar': the accepted jobs, the two lanes and their workspace charges, the delivered textures
-- nobody owns yet, the first failure and its evidence. Owner: the pipeline scope
-- ('withTexturePipeline'). Writers, always in STM: the host's admission and credit release (on the
-- owners' threads), the read workers' sinks, the decode worker, the backend's sink calls (the
-- graphics owner's thread) and the drain. Readers: anyone, through 'pipelineReading'. Nothing is
-- reset: a scope is never reopened.
--
-- = A job
--
-- A job exists from the moment its request was accepted (the admission reserved its record) until
-- the host returns that record's credit. Its stage only moves forward:
--
-- @
-- Pending --lane--> Reading --sink--> DecodeWait --worker--> Decoding --handoff--> Uploading --> Settled
--    \\_________________\\______________\\_____________________\\_________________________/
--                              (withdrawn, refused, failed: any stage --> Settled)
-- @
--
-- * /Pending/: accepted and waiting for a lane. Holds no workspace and has touched no file. Cancelling
--   it is free.
-- * /Reading/: a lane's workspace is charged the file's known length and the read was submitted to the
--   shared pool with the texture's 32 MiB allowance. The pool's ticket is the evidence about the read.
-- * /DecodeWait/: the verified buffer arrived (the lane's charge for it is unchanged: it is the same
--   allocation) and waits for the decode worker.
-- * /Decoding/: the decode worker holds the buffer. It preflights the PNG, shrinks the nominal charge
--   to the validated @width * height * 4@, and decodes through "Hetoimasia.Asset.Image.PngDecode" onto
--   the lane's workspace bank.
-- * /Uploading/: the decoded level is borrowed by the backend and charged to the lane (the encoded
--   input was released at the handoff, the one place the pipeline stops holding it).
-- * /Settled/: the job holds no lane, no workspace and no buffer. A job is /never answered to the host
--   before it is Settled/: the host takes an answer as proof the provider's work is over, so an answer
--   while a lane still charges the job's buffers would end the request's work early.
--
-- The lane is released, and the next pending job started in the same transaction, at 'settleJob'.
--
-- = A texture nobody owns yet
--
-- When the backend reports a usable registration, the pipeline holds a 'Cell' for it and answers the
-- request with a resource the host builds, on the owner's thread, into the lease the admission
-- reserved. Until that build runs the texture belongs to the cell, and afterwards to the lease. The
-- cell's state machine decides who may release it: the pipeline for a cell no lease adopted, the lease
-- for an adopted one, once. If the host drops the build (the request was cancelled, its instance ended)
-- it never tells the provider, so the pipeline learns of it where the host does return a credit: a
-- credit that transfers and is returned unused means no lease owns the texture, and 'settleCharge'
-- hands the cell to the pipeline's own housekeeping, which releases it and returns the charge only
-- when the backend proves the texture retired.
--
-- = Housekeeping
--
-- A transition that no event drives has to be driven by somebody: a read cancelled after its worker took
-- it retires without calling the sink, and a delivered texture no lease will own has to be released.
-- The decode worker is that actor ('nextWork'): in one transaction it reaps withdrawn reads, starts the
-- oldest pending job on a free lane, releases and retires unowned textures, and otherwise takes the
-- oldest decode job; when there is nothing to do it blocks in STM until a variable it read changes.
-- Nothing polls and nothing sleeps. The drain runs the same step, so closing never depends on the worker
-- being alive.
module Hetoimasia.LuaEngine.Texture.Pipeline
  ( -- * The specification
    TextureSpec (..)
  , specProfile
  , specJobs
  , specIoWorkers
  , specDecodeWorkers
  , specLanes
  , specWorkspace
  , specSourceLimit
  , specInitialNominal
  , specInstanceSlots
  , specInstanceBytes
  , specSessionBytes
  , TextureSpecRefused (..)
  , textureSpec

    -- * The pipeline
  , TexturePipeline
  , withTexturePipeline
  , withTexturePipelineWith
  , PipelineHooks (..)
  , noHooks
  , pipelineSpec
  , newTextureOwner
  , pipelineOpen
  , pipelineDrained
  , pipelineInventory
  , pipelineSession

    -- * Observation
  , PipelineReading (..)
  , LaneReading (..)
  , pipelineReading
  , awaitPipelineFailure
  , pipelineFailureEvidence
  , sessionNominal

    -- * Admission
  , Prepared (..)
  , Fate (..)
  , prepareRequest
  , forgetPrepared
  , requestCredits
  , ownerLiveName
  , ownerAndPipelineLive
  , fateOf
  , textureCodes

    -- * The endpoint
  , submitJob

    -- * The texture
  , Cell
  , cellTexture
  , TextureResource (..)
  , releaseResource
  , adoptionFor
  , TextureDefect (..)
  ) where

import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , catchSTM
  , newTVar
  , newTVarIO
  , readTVar
  , readTVarIO
  , retry
  , throwSTM
  , writeTVar
  )
import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException (SomeAsyncException)
  , SomeException
  , evaluate
  , fromException
  , mask
  , mask_
  , rethrowIO
  , throwIO
  , tryWithContext
  )
import Control.Monad (forM, forM_, unless, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Functor ((<&>))
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.List (sortOn)
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import qualified Data.Text.Encoding.Error as Encoding
import Data.Int (Int64)
import Data.Word (Word32, Word64)
import Hetoimasia.Asset (Asset (..), AssetId (..), Provenance (FromMemory))
import Hetoimasia.Asset.Image (DecodedImage (..))
import Hetoimasia.Asset.Image.PngDecode (PayloadAccount (..), decodeBounded)
import Hetoimasia.Asset.Image.PngPreflight
  ( PngLimitSettings (..)
  , PngLimits
  , PngRefusal (..)
  , PngRefusalClass (..)
  , pngLimits
  , preflightHeight
  , preflightPng
  , preflightRgba8Bytes
  , preflightWidth
  )
import Hetoimasia.Content.Identity (ContentKey, contentKeyPath, contentKeyRoot, logicalPathBytes, rootKeyBytes)
import Hetoimasia.Content.Inventory
  ( Change (..)
  , Inventory
  , Presence (..)
  , ReadFailure (..)
  , ReadOutcome (..)
  , inspectEntry
  )
import Hetoimasia.Content.ReadPool
  ( CancelOutcome (..)
  , PoolStatus (statusWorkers)
  , ReadPool
  , ReadPriority (OrdinaryRead)
  , ReadRequest (..)
  , ReadResult (..)
  , ReadTicket
  , SubmitRefusal (..)
  , cancel
  , retired
  , status
  , submit
  )
import qualified Hetoimasia.Content.ReadPool as ReadPool
import Hetoimasia.Foundation.Resource (acquirePart, cleanupFailureException, cleanupFailureLabel, composeCleanup, releaseRank)
import Hetoimasia.Foundation.Worker
  ( Completion (completionCleanup, completionLabel, completionResult)
  , GroupReport (reportDrained, reportExitedBeforeClosing, reportObservedFailures)
  , Result (Cancelled, Failed, Succeeded)
  , StartOutcome (Started, StartRejected, StartupFailed)
  , StopToken
  , WorkerCancelled (WorkerCancelled)
  , closeWorkerGroup
  , startWorker
  , stopRequested
  , withWorkerGroup
  , workerDefinition
  )
import Hetoimasia.LuaEngine.Profile
  ( ByteLimit (..)
  , Bytes (Bytes)
  , Count (Count)
  , CountLimit (..)
  , Profile
  , bytesLimit
  , countLimit
  , pngOutputBytes
  )
import Hetoimasia.LuaEngine.Texture.Backend
import Hetoimasia.LuaEngine.Texture.Banks
import Hetoimasia.Scripting.Lua.Admission (Credit (..), ExpectedFailure (..))
import Hetoimasia.Scripting.Lua.Lease (Retirements, afterRetirement, retireAsynchronously)
import Hetoimasia.Scripting.Lua.Provider
  ( Adoption (..)
  , ProviderReply (..)
  , ProviderWork (..)
  , ReplyAnswer (..)
  )
import Hetoimasia.Scripting.Lua.Value (Value (VInteger, VRecord))

-- The specification --------------------------------------------------------------------------------

-- | The numbers a pipeline is built from: the validated profile's limits, read once, and the one
-- capacity the assembly chooses.
data TextureSpec = TextureSpec
  { tsProfile ∷ !Profile
  , tsJobs ∷ !Int
    -- ^ The accepted-work records the session holds at once: every accepted, unretired texture
    -- request, from admission until the host returns its record. Bounds every stage queue.
  , tsIoWorkers ∷ !Int
  , tsDecodeWorkers ∷ !Int
  , tsLanes ∷ !Int
  , tsWorkspace ∷ !Word64
    -- ^ The accounted CPU payload one lane may hold.
  , tsSourceLimit ∷ !Word64
    -- ^ The PNG source limit, also the read's allowance.
  , tsInitialNominal ∷ !Word64
    -- ^ The nominal bytes reserved for a texture at admission: the largest RGBA8 output.
  , tsInstanceSlots ∷ !Int
  , tsInstanceBytes ∷ !Word64
  , tsSessionBytes ∷ !Word64
  , tsPngLimits ∷ !PngLimits
  }

-- | The numbers, read. The record's own fields are not exported by the facade: a field selector is also
-- a record update, and a client must not be able to write a specification of its own.
specProfile ∷ TextureSpec → Profile
specProfile = tsProfile

specJobs, specIoWorkers, specDecodeWorkers, specLanes, specInstanceSlots ∷ TextureSpec → Int
specJobs = tsJobs
specIoWorkers = tsIoWorkers
specDecodeWorkers = tsDecodeWorkers
specLanes = tsLanes
specInstanceSlots = tsInstanceSlots

specWorkspace, specSourceLimit, specInitialNominal, specInstanceBytes, specSessionBytes ∷ TextureSpec → Word64
specWorkspace = tsWorkspace
specSourceLimit = tsSourceLimit
specInitialNominal = tsInitialNominal
specInstanceBytes = tsInstanceBytes
specSessionBytes = tsSessionBytes

-- | Why a profile could not be turned into a pipeline's numbers.
data TextureSpecRefused
  = -- | A profile value that does not fit the machine integer it is held in: which one.
    SpecNotRepresentable !Text
  | -- | The job capacity is below one.
    SpecJobsNotPositive !Int
  | -- | The PNG limits the profile gives the decoder were refused by it: the decoder's own reason.
    SpecPngLimitsRefused !Text
  deriving (Eq, Show)

-- | The pipeline's numbers for a validated profile and a job capacity. Every smaller profile a test
-- injects went through "Hetoimasia.LuaEngine.Profile"'s validation; there is no product tuning API.
textureSpec ∷ Profile → Int → Either TextureSpecRefused TextureSpec
textureSpec profile jobs = do
  when (jobs < 1) $ Left (SpecJobsNotPositive jobs)
  ioWorkers ← machine "IoWorkers" (count IoWorkers)
  decodeWorkers ← machine "DecodeWorkers" (count DecodeWorkers)
  lanes ← machine "TexturePipelineLanes" (count TexturePipelineLanes)
  slots ← machine "TextureLeasesPerUiInstance" (count TextureLeasesPerUiInstance)
  axis ← pure (toInteger (count PngAxisMaximum))
  let Bytes workspace = bytesLimit profile PngPipelineWorkspaceBytes
      Bytes source = bytesLimit profile PngEncodedBytes
      Bytes inflated = bytesLimit profile PngInflatedScanlineBytes
      Bytes output = pngOutputBytes profile
      Bytes perInstance = bytesLimit profile TextureBytesPerUiInstance
      Bytes perSession = bytesLimit profile TextureBytesPerSession
  limits ←
    either
      (Left . SpecPngLimitsRefused . Text.pack . show)
      Right
      ( pngLimits
          PngLimitSettings
            { settingSourceBytes = toInteger source
            , settingChunks = toInteger (count PngChunks)
            , settingWidth = axis
            , settingHeight = axis
            , settingPixels = toInteger (count PngPixels)
            , settingRgba8Bytes = toInteger output
            , settingInflatedBytes = toInteger inflated
            }
      )
  Right
    TextureSpec
      { tsProfile = profile
      , tsJobs = jobs
      , tsIoWorkers = ioWorkers
      , tsDecodeWorkers = decodeWorkers
      , tsLanes = lanes
      , tsWorkspace = workspace
      , tsSourceLimit = source
      , tsInitialNominal = output
      , tsInstanceSlots = slots
      , tsInstanceBytes = perInstance
      , tsSessionBytes = perSession
      , tsPngLimits = limits
      }
  where
    count limit = let Count value = countLimit profile limit in value
    machine name value
      | value <= fromIntegral (maxBound ∷ Int) = Right (fromIntegral value)
      | otherwise = Left (SpecNotRepresentable name)

-- The state ----------------------------------------------------------------------------------------

-- | An engine inconsistency: a state the pipeline's own transitions cannot reach, or a contract the
-- backend or the host broke. Latched as the pipeline's failure, never given a content code.
newtype TextureDefect = TextureDefect Text
  deriving (Eq, Show)

instance Exception TextureDefect

newtype JobId = JobId Word64
  deriving (Eq, Ord, Show)

-- | Whether the pipeline still accepts work.
data Phase = Open | Closed
  deriving (Eq, Show)

data Stage
  = StagePending
  | StageReading !ReadTicket
  | StageDecodeWait !ByteString
  | StageDecoding
  | StageUploading
  | StageSettled

-- | Where the handoff to the backend is.
data UploadPhase
  = -- | Nothing was handed over.
    UploadNone
  | -- | 'backendUpload' was entered and has not returned: an event may already be arriving.
    UploadIssuing
  | UploadIssued !UploadWork

-- | The state of a delivered texture. See the module header.
data CellState
  = -- | Delivered, reported usable, and owned by no lease yet.
    CellJob
  | -- | A lease owns it.
    CellAdopted
  | -- | Someone is calling the backend's release now.
    CellClaimed
  | -- | Release requested; the backend's reading of its retirement.
    CellReleasing !(STM RetirementState)
  | -- | The backend's release raised: the texture is never reported reclaimed.
    CellFailed !(ExceptionWithContext SomeException)
  | -- | The backend's reading of the retirement failed, or threw: terminal, recorded once, and the
    -- texture is never reported reclaimed.
    CellRetirementFailed !SomeException

-- | A texture the backend registered, and the one record of who may release it.
data Cell = Cell
  { cellTexture ∷ !BackendTexture
  , cellState ∷ !(TVar CellState)
  }

instance Eq Cell where
  a == b = cellState a == cellState b

-- | One lane: the job it serves and the workspace bytes charged.
data Lane = Lane
  { laneJob ∷ !(Maybe JobId)
  , laneCharged ∷ !Word64
  }

-- | What the host's admission hands the endpoint through the pipeline: what is needed to start the
-- request, prepared before the admission and consumed by the submission.
data Prepared = Prepared
  { prepToken ∷ !Word64
  , prepKey ∷ !ContentKey
  , prepFate ∷ !Fate
  , prepCharge ∷ !TextureCharge
  }

-- | What the inventory says will become of a request, decided from the immutable inventory alone.
data Fate
  = -- | An eligible regular file of this length: read it.
    FateRead !Word64
  | -- | Not an inventoried regular file: accepted, and failed as @not_found@ without a worker.
    FateNotFound
  | -- | An inventoried file over the PNG source limit: accepted, and failed as @too_large@ without a
    -- worker or a file open.
    FateTooLarge !Word64
  deriving (Eq, Show)

data Job = Job
  { jKey ∷ !ContentKey
  , jLength ∷ !Word64
  , jCharge ∷ !TextureCharge
  , jReply ∷ ProviderReply → IO ReplyAnswer
  , jStage ∷ !Stage
  , jLane ∷ !(Maybe Int)
  , jEncoded ∷ !Word64
    -- ^ Workspace bytes charged to the lane for the encoded input.
  , jOutput ∷ !Word64
    -- ^ Workspace bytes charged to the lane for the decoded level.
  , jWithdrawn ∷ !Bool
    -- ^ The engine no longer wants a result: cancelled, or its instance ended. Never answered.
  , jStopping ∷ !Bool
    -- ^ The pipeline closed: no success will be delivered.
  , jUpload ∷ !UploadPhase
  , jUploadCancelled ∷ !Bool
  , jTerminal ∷ !Bool
  , jBuffersRetired ∷ !Bool
  , jDims ∷ !(Maybe (Word32, Word32))
  , jCell ∷ !(Maybe Cell)
  , jOrder ∷ !Word64
    -- ^ Where the admission transaction placed the request: stage queues serve the oldest first.
  , jFailure ∷ !(Maybe Text)
    -- ^ What the backend said when it reported a failure.
  }

-- | A delivered texture no lease owns, awaiting its release and retirement, with the charge that is
-- returned only when the backend proves it retired.
data Orphan = Orphan
  { orphanCell ∷ !Cell
  , orphanCharge ∷ !TextureCharge
  }

data PState = PState
  { psPhase ∷ !Phase
  , psFailure ∷ !(Maybe (ExceptionWithContext SomeException))
  , psEvidence ∷ ![(Text, ExceptionWithContext SomeException)]
  , psJobs ∷ !(Map JobId Job)
  , psReserved ∷ !Int
  , psNext ∷ !Word64
  , psPrepared ∷ !(Map Word64 Prepared)
  , psLanes ∷ !(Map Int Lane)
  , psOrphans ∷ !(Map Word64 Orphan)
  , psOwners ∷ !Word64
  , psLate ∷ !Word64
  , psWorkers ∷ !Int
  , psAdmissions ∷ !(Map Word64 Word64)
    -- ^ The admission order of each reserved record, from its reservation to its return.
  , psOrderNext ∷ !Word64
    -- ^ Decode workers running now.
  }

-- | The pipeline: its numbers, its one state, and what it borrows. The pool, the inventory and the
-- backend are borrowed from enclosing scopes that outlive it.
data TexturePipeline = TexturePipeline
  { tpSpec ∷ !TextureSpec
  , tpHooks ∷ !PipelineHooks
  , tpState ∷ !(TVar PState)
  , tpBackend ∷ !TextureBackend
  , tpPool ∷ !ReadPool
  , tpInventory ∷ !Inventory
  , tpSession ∷ !SessionBytes
  }

-- | Coordination points of the pipeline's own transitions, for this package's tests. Production uses
-- 'noHooks'. A hook runs on the decode worker's thread, outside any transaction and interruptibly:
-- an asynchronous exception raised in it ends the job as any other interruption of a decode does.
data PipelineHooks = PipelineHooks
  { hookDecoding ∷ !(ContentKey → IO ())
    -- ^ The decode worker took the job and has preflighted nothing.
  , hookDecoded ∷ !(ContentKey → IO ())
    -- ^ The level is decoded, charged to the lane and recorded on the job; the handoff is next.
  }

-- | No hooks.
noHooks ∷ PipelineHooks
noHooks = PipelineHooks (\_ → pure ()) (\_ → pure ())

-- | The numbers the pipeline was built with.
pipelineSpec ∷ TexturePipeline → TextureSpec
pipelineSpec = tpSpec

-- | The nominal bytes the session's textures hold.
sessionNominal ∷ TexturePipeline → STM Word64
sessionNominal = sessionBytesCharged . tpSession

-- | The session bank the pipeline's owners are charged to: an owner made by another pipeline holds a
-- different one.
pipelineSession ∷ TexturePipeline → SessionBytes
pipelineSession = tpSession

-- | The inventory the pipeline reads from.
pipelineInventory ∷ TexturePipeline → Inventory
pipelineInventory = tpInventory

-- | Whether the pipeline still accepts requests.
pipelineOpen ∷ TexturePipeline → STM Bool
pipelineOpen tp = (== Open) . psPhase <$> readTVar (tpState tp)

-- | An instance's texture banks, numbered by this pipeline, with the role its facade boundary declared
-- for it. The instance's bindings hold it; the pipeline keeps no list of owners.
newTextureOwner ∷ TexturePipeline → TextureRole → IO TextureOwner
newTextureOwner tp role = atomically $ do
  st ← readTVar (tpState tp)
  when (psOwners st == maxBound) $ throwSTM (TextureDefect "the texture owner numbers are exhausted")
  writeTVar (tpState tp) st {psOwners = psOwners st + 1}
  newOwner (psOwners st) (tpSession tp) (tsInstanceSlots (tpSpec tp)) (tsInstanceBytes (tpSpec tp)) role

-- The scope ----------------------------------------------------------------------------------------

-- | Run a body over a texture pipeline of this specification, this backend, this shared read pool and
-- this inventory.
--
-- The scope, in order: the worker group (inside the scopes of the pool and the backend it borrows); the
-- state; the decode workers, each started with registration checked; the body. On every exit the pipeline
-- closes admission first, withdraws what has not started and tells the rest to stop, then /drains/: it
-- waits, in STM and outside any uninterruptible release, until every started read, decode and upload has
-- retired and every delivered texture no lease owns has been released and proved retired; only then
-- does the group stop the worker, and only then may the pool, the inventory and the backend unwind. A
-- cancellation delivered while it drains is remembered and raised once the drain is over.
withTexturePipeline ∷ TextureSpec → TextureBackend → ReadPool → Inventory → (TexturePipeline → IO a) → IO a
withTexturePipeline = withTexturePipelineWith noHooks

-- | 'withTexturePipeline' with the coordination hooks of this package's tests.
withTexturePipelineWith ∷ PipelineHooks → TextureSpec → TextureBackend → ReadPool → Inventory → (TexturePipeline → IO a) → IO a
withTexturePipelineWith hooks spec backend pool inventory body = withWorkerGroup $ \group → do
  var ← newTVarIO (PState Open Nothing [] Map.empty 0 0 Map.empty (Map.fromList [(lane, Lane Nothing 0) | lane ← [0 .. tsLanes spec - 1]]) Map.empty 0 0 0 Map.empty 0)
  session ← newSessionBytes (tsSessionBytes spec)
  let tp = TexturePipeline spec hooks var backend pool inventory session
  result ← mask $ \restore → do
    outcome ← tryWithContext @SomeException $ restore $ do
      reading ← atomically (status pool)
      when (statusWorkers reading /= tsIoWorkers spec) $
        throwIO (TextureDefect (Text.pack ("the read pool has " <> show (statusWorkers reading) <> " workers, not the profile's " <> show (tsIoWorkers spec))))
      forM_ [0 .. tsDecodeWorkers spec - 1] $ \index →
        startWorker group (workerDefinition (Text.pack ("texture-decode-" <> show index)) (\_ → pure ()) (\token () → runWorker tp token)) >>= \case
          Started _ → pure ()
          StartupFailed _ _ → throwIO (TextureDefect (Text.pack ("decode worker " <> show index <> " did not start")))
          StartRejected _ → throwIO (TextureDefect (Text.pack ("decode worker " <> show index <> " was not accepted")))
      body tp
    closed ← tryWithContext @SomeException (closeAndDrain tp)
    latched ← latchedFailure tp
    let kept = [("texture pipeline failure", found) | Just found ← [latched]]
    case (outcome, closed) of
      (Right value, Right ()) → pure (Right value)
      (Right _, Left closing) → Left <$> withEvidence closing kept
      (Left primary, Right ()) → Left <$> withEvidence primary kept
      (Left primary, Left closing) → Left <$> withEvidence primary (("texture pipeline close", closing) : kept)
  case result of
    Left failure → rethrowIO failure
    Right value → do
      -- The body returned. A failure the pipeline latched is still the scope's; failing that, the
      -- group's report of its workers' own outcomes is read, and anything but a clean exit is raised.
      report ← closeWorkerGroup group
      latched ← latchedFailure tp
      case latched of
        Just failure → rethrowIO failure
        Nothing →
          unclean report >>= \case
            Nothing → pure value
            Just failure → rethrowIO failure

-- | What a worker group's report holds that is not a clean exit: a worker that failed, was cancelled or
-- retained a cleanup failure. Raised when the body returned and no failure was latched, since a worker
-- that was not asked to cancel and did not return cleanly is a failure of the pipeline.
unclean ∷ GroupReport → IO (Maybe (ExceptionWithContext SomeException))
unclean report = do
  let summaries = reportExitedBeforeClosing report <> reportDrained report <> reportObservedFailures report
      evidence =
        concat
          [ [(completionLabel found, raised) | raised ← resultFailure (completionResult found)]
            <> [(cleanupFailureLabel cleanup, cleanupFailureException cleanup) | cleanup ← completionCleanup found]
          | found ← summaries
          ]
  if null evidence
    then pure Nothing
    else do
      primary ← defect "a decode worker's report was not a clean exit"
      Just <$> withEvidence primary evidence
  where
    resultFailure = \case
      Succeeded () → []
      Failed raised → [raised]
      Cancelled raised → [raised]

withEvidence ∷ ExceptionWithContext SomeException → [(Text, ExceptionWithContext SomeException)] → IO (ExceptionWithContext SomeException)
withEvidence primary [] = pure primary
withEvidence primary evidence = fromMaybe primary <$> composeCleanup (Just primary) evidence

-- | The latched failure with all the evidence recorded so far composed beside it, if one is latched.
latchedFailure ∷ TexturePipeline → IO (Maybe (ExceptionWithContext SomeException))
latchedFailure tp = do
  st ← readTVarIO (tpState tp)
  case psFailure st of
    Nothing → pure Nothing
    Just first → Just <$> withEvidence first (psEvidence st)

-- | Latch a failure: the first is the pipeline's, every later one is evidence beside it, appended by
-- the transaction that reads the current list. Atomic: two failures at once are both kept.
latchFailure ∷ TexturePipeline → Text → ExceptionWithContext SomeException → IO ()
latchFailure tp label failure = atomically $ do
  st ← readTVar (tpState tp)
  writeTVar (tpState tp) $ case psFailure st of
    Nothing → st {psFailure = Just failure}
    Just _ → st {psEvidence = psEvidence st <> [(label, failure)]}

-- | Wait, in STM, for the first failure, so a supervisor can compose it into a supervised wait.
awaitPipelineFailure ∷ TexturePipeline → STM (ExceptionWithContext SomeException)
awaitPipelineFailure tp = readTVar (tpState tp) >>= maybe retry pure . psFailure

-- | The evidence recorded beside the first failure, oldest first.
pipelineFailureEvidence ∷ TexturePipeline → STM [(Text, ExceptionWithContext SomeException)]
pipelineFailureEvidence tp = psEvidence <$> readTVar (tpState tp)

-- | Raise a defect with its context, as the pipeline's own failure.
defect ∷ Text → IO (ExceptionWithContext SomeException)
defect why = do
  raised ← tryWithContext @SomeException (throwIO (TextureDefect why))
  either pure (\() → throwIO (TextureDefect why)) raised

-- | A defect to be latched, as an effect.
latchDefect ∷ TexturePipeline → Text → IO ()
latchDefect tp why = defect why >>= latchFailure tp "texture pipeline defect"

-- Observation --------------------------------------------------------------------------------------

-- | One lane read in a transaction.
data LaneReading = LaneReading
  { laneReadingJob ∷ !(Maybe Word64)
  , laneReadingCharged ∷ !Word64
  }
  deriving (Eq, Show)

-- | The pipeline read in one transaction.
data PipelineReading = PipelineReading
  { readingOpen ∷ !Bool
  , readingFailed ∷ !Bool
  , readingJobs ∷ !Int
  , readingPending ∷ !Int
  , readingReading ∷ !Int
  , readingDecodeWait ∷ !Int
  , readingDecoding ∷ !Int
  , readingUploading ∷ !Int
  , readingSettled ∷ !Int
  , readingReserved ∷ !Int
  , readingLanes ∷ ![LaneReading]
  , readingOrphans ∷ !Int
  , readingLate ∷ !Word64
  , readingDecodeWorkers ∷ !Int
  , readingPrepared ∷ !Int
    -- ^ Start calls in flight: requests prepared and not yet taken or dropped.
  }
  deriving (Eq, Show)

-- | Read the pipeline in one transaction.
pipelineReading ∷ TexturePipeline → STM PipelineReading
pipelineReading tp = do
  st ← readTVar (tpState tp)
  let stages = [jStage job | job ← Map.elems (psJobs st)]
      count predicate = length (filter predicate stages)
  pure
    PipelineReading
      { readingOpen = psPhase st == Open
      , readingFailed = isJust (psFailure st)
      , readingJobs = Map.size (psJobs st)
      , readingPending = count (\case StagePending → True; _ → False)
      , readingReading = count (\case StageReading _ → True; _ → False)
      , readingDecodeWait = count (\case StageDecodeWait _ → True; _ → False)
      , readingDecoding = count (\case StageDecoding → True; _ → False)
      , readingUploading = count (\case StageUploading → True; _ → False)
      , readingSettled = count (\case StageSettled → True; _ → False)
      , readingReserved = psReserved st
      , readingLanes = [LaneReading (jobNumber <$> laneJob lane) (laneCharged lane) | lane ← Map.elems (psLanes st)]
      , readingOrphans = Map.size (psOrphans st)
      , readingLate = psLate st
      , readingDecodeWorkers = psWorkers st
      , readingPrepared = Map.size (psPrepared st)
      }
  where
    jobNumber (JobId number) = number

-- Admission ----------------------------------------------------------------------------------------

-- | The failure codes the texture service supplies.
textureCodes ∷ [Text]
textureCodes = ["not_found", "content_changed", "io_error", "too_large", "unsupported_format", "invalid_image"]

-- | What the inventory says will become of a key. Decided from the immutable inventory alone, so
-- classifying a request when it is asked and again when it is handed over cannot disagree.
fateOf ∷ TexturePipeline → ContentKey → Fate
fateOf tp key = case inspectEntry (tpInventory tp) key of
  Absent → FateNotFound
  PresentDirectory → FateNotFound
  PresentFile len
    | len > tsSourceLimit (tpSpec tp) → FateTooLarge len
    | otherwise → FateRead len

-- | Prepare one request's start: its token and its charge, kept until the submission consumes them
-- or 'forgetPrepared' drops them. The table's size is the number of start calls in flight, one per
-- calling thread.
prepareRequest ∷ TexturePipeline → TextureOwner → ContentKey → IO Prepared
prepareRequest tp owner key = atomically $ do
  st ← readTVar (tpState tp)
  -- The token travels as a Lua integer, so the numbers stop at the largest one.
  when (psNext st >= fromIntegral (maxBound ∷ Int64)) $ throwSTM (TextureDefect "the texture job numbers are exhausted")
  charge ← newCharge owner
  let prepared = Prepared (psNext st) key (fateOf tp key) charge
  writeTVar (tpState tp) st {psNext = psNext st + 1, psPrepared = Map.insert (psNext st) prepared (psPrepared st)}
  pure prepared

-- | Drop a prepared request: after a refusal, busy or a failure, or after the submission consumed it.
-- Idempotent.
forgetPrepared ∷ TexturePipeline → Word64 → IO ()
forgetPrepared tp token = atomically $ modifyState tp $ \st → st {psPrepared = Map.delete token (psPrepared st)}

modifyState ∷ TexturePipeline → (PState → PState) → STM ()
modifyState tp change = readTVar (tpState tp) >>= writeTVar (tpState tp) . change

-- | The credits a request reserves with its admission, in the order they are reserved: the instance's
-- texture slot, the nominal bytes of the instance and the session, a record in the pipeline's
-- accepted-work bound, and, for a file that will be read, a slot of the shared pool's queue.
--
-- The slot and the nominal bytes transfer to the texture when a lease adopts it: the lease's release
-- returns them, after the backend proved the texture retired. The record and the pool slot are the
-- request's, returned when the host returns them.
requestCredits ∷ TexturePipeline → Prepared → [Credit]
requestCredits tp prepared =
  [ Credit
      { creditName = ownerLiveName
      , creditReserve = ownerAndPipelineLive tp (chargeOwner charge)
      , creditRelease = \_ → pure ()
      , creditTransfers = False
      }
  , Credit
      { creditName = "texture slots"
      , creditReserve = reserveSlot charge
      , creditRelease = \_ → settleCharge tp token charge
      , creditTransfers = True
      }
  , Credit
      { creditName = "texture bytes"
      , creditReserve = reserveNominal charge (tsInitialNominal (tpSpec tp))
      , creditRelease = \_ → settleCharge tp token charge
      , creditTransfers = True
      }
  , Credit
      { creditName = "texture jobs"
      , creditReserve = reserveRecord tp token
      , creditRelease = \_ → releaseRecord tp token
      , creditTransfers = False
      }
  ]
    <> case prepFate prepared of
      FateRead _ →
        [ Credit
            { creditName = "io queue"
            , creditReserve = ReadPool.reserveSlot (tpPool tp)
            , creditRelease = \_ → ReadPool.releaseSlot (tpPool tp)
            , creditTransfers = False
            }
        ]
      _ → []
  where
    token = prepToken prepared
    charge = prepCharge prepared

-- | The name of the admission's first credit, which reserves nothing and says whether the owner still
-- takes requests and the pipeline is open: read in the admission's own transaction, so a closure that
-- lands between the argument check and the admission cannot let a request reserve for a closed owner.
-- A bank that answers no here is busy to the host; 'Hetoimasia.LuaEngine.Texture.startTexture' reads
-- the same facts again and reports the permanent refusal it was.
ownerLiveName ∷ Text
ownerLiveName = "texture owner"

ownerAndPipelineLive ∷ TexturePipeline → TextureOwner → STM Bool
ownerAndPipelineLive tp owner = do
  open ← pipelineOpen tp
  taking ← ownerIsOpen owner
  pure (open && taking)

-- | Take one of the pipeline's accepted-work records, if one is left, and place the request in the
-- admission order, in the one transaction that admits it: the stage queues serve the oldest first, and
-- the oldest is the one the host admitted first, not the one that was prepared first.
reserveRecord ∷ TexturePipeline → Word64 → STM Bool
reserveRecord tp token = do
  st ← readTVar (tpState tp)
  if psReserved st >= tsJobs (tpSpec tp)
    then pure False
    else do
      when (psOrderNext st == maxBound) $ throwSTM (TextureDefect "the texture admission order is exhausted")
      writeTVar
        (tpState tp)
        st
          { psReserved = psReserved st + 1
          , psAdmissions = Map.insert token (psOrderNext st) (psAdmissions st)
          , psOrderNext = psOrderNext st + 1
          }
      pure True

-- | Give the record back and forget the job, once the job is over. A job that is not 'StageSettled'
-- here is an engine defect: the host returns a record only after the request's work was proved over,
-- and no answer is made while a job holds a lane.
releaseRecord ∷ TexturePipeline → Word64 → STM ()
releaseRecord tp token = do
  st ← readTVar (tpState tp)
  case Map.lookup (JobId token) (psJobs st) of
    Just job | not (isSettled job) → throwSTM (TextureDefect "a job's record was returned while it still holds a lane")
    _ → pure ()
  when (psReserved st <= 0) $ throwSTM (TextureDefect "an accepted-work record was returned that was not reserved")
  writeTVar
    (tpState tp)
    st
      { psJobs = Map.delete (JobId token) (psJobs st)
      , psReserved = psReserved st - 1
      , psAdmissions = Map.delete token (psAdmissions st)
      }

isSettled ∷ Job → Bool
isSettled job = case jStage job of
  StageSettled → True
  _ → False

isUploading ∷ Job → Bool
isUploading job = case jStage job of
  StageUploading → True
  _ → False

-- | Return a request's texture charge when the host returns the request's credit (its request ended,
-- or the admission was taken back), unless some other owner still has the texture:
--
-- * no texture was ever delivered: the charge is returned now;
-- * a lease adopted it: the lease returns the charge after the backend proved the texture retired;
-- * delivered and owned by no lease: the pipeline's housekeeping releases the texture and returns the
--   charge when the backend proves it retired, never before and never if its release failed.
settleCharge ∷ TexturePipeline → Word64 → TextureCharge → STM ()
settleCharge tp token charge = do
  st ← readTVar (tpState tp)
  case Map.lookup (JobId token) (psJobs st) >>= jCell of
    Nothing → returnCharge charge
    Just cell →
      readTVar (cellState cell) >>= \case
        CellAdopted → pure ()
        CellFailed _ → pure ()
        CellRetirementFailed _ → pure ()
        CellReleasing poll →
          readRetirement poll >>= \case
            ProviderComplete → returnCharge charge
            ProviderPending → defer st cell
            -- The housekeeping latches the failure and keeps the charge held.
            ProviderFailed _ → defer st cell
        CellJob → defer st cell
        CellClaimed → defer st cell
  where
    defer st cell =
      writeTVar (tpState tp) st {psOrphans = Map.insertWith (\_ old → old) token (Orphan cell charge) (psOrphans st)}

-- | A backend's reading of a retirement, as the host reads one: it only reads, and what it throws is the
-- retirement failing, not an exception loose in whoever polls it. Evaluated inside the guard.
readRetirement ∷ STM RetirementState → STM RetirementState
readRetirement poll =
  (poll >>= \state → state `seq` pure state) `catchSTM` \failure → pure (ProviderFailed (failure ∷ SomeException))

returnCharge ∷ TextureCharge → STM ()
returnCharge charge = returnSlot charge >> returnNominal charge

-- The endpoint --------------------------------------------------------------------------------------

-- | Hand the accepted request to the pipeline: classify it, answer a request that fails without a
-- worker at once, and otherwise record the job and let a free lane start it. Never opens a file, never
-- decodes and never waits.
--
-- A job is recorded as the last step, so a submission that raises leaves nothing behind for the host to
-- take back.
submitJob ∷ TexturePipeline → Word64 → (ProviderReply → IO ReplyAnswer) → IO ProviderWork
submitJob tp token reply = mask_ $ do
  prepared ← atomically $ do
    st ← readTVar (tpState tp)
    writeTVar (tpState tp) st {psPrepared = Map.delete token (psPrepared st)}
    pure (Map.lookup token (psPrepared st))
  found ← maybe (throwIO (TextureDefect "the texture endpoint was handed a request nobody prepared")) pure prepared
  let key = prepKey found
      jid = JobId token
  case prepFate found of
    FateNotFound → immediate (notFound key)
    FateTooLarge len → immediate (tooLarge tp key len)
    FateRead len → do
      effects ← atomically $ do
        st ← readTVar (tpState tp)
        when (psPhase st /= Open) $ throwSTM (TextureDefect "the texture pipeline is closed")
        order ← maybe (throwSTM (TextureDefect "a texture job was submitted that the admission did not place")) pure (Map.lookup token (psAdmissions st))
        writeTVar
          (tpState tp)
          st
            { psJobs =
                Map.insert
                  jid
                  Job
                    { jKey = key
                    , jLength = len
                    , jCharge = prepCharge found
                    , jReply = reply
                    , jStage = StagePending
                    , jLane = Nothing
                    , jEncoded = 0
                    , jOutput = 0
                    , jWithdrawn = False
                    , jStopping = False
                    , jUpload = UploadNone
                    , jUploadCancelled = False
                    , jTerminal = False
                    , jBuffersRetired = False
                    , jDims = Nothing
                    , jCell = Nothing
                    , jOrder = order
                    , jFailure = Nothing
                    }
                  (psJobs st)
            }
        promote tp
      runEffects tp effects
      pure ProviderWork {workCancel = cancelJob tp jid, workRetirement = jobRetirement tp jid}
  where
    immediate failure = do
      _ ← reply (ProviderExpected failure)
      pure ProviderWork {workCancel = pure (), workRetirement = pure ProviderComplete}

-- Failures as the content layer says them ------------------------------------------------------------

notFound ∷ ContentKey → ExpectedFailure
notFound key = attributed key "not_found" "the path is not an inventoried file"

tooLarge ∷ TexturePipeline → ContentKey → Word64 → ExpectedFailure
tooLarge tp key len =
  attributed key "too_large" ("the file is " <> Text.pack (show len) <> " bytes, over the PNG limit of " <> Text.pack (show (tsSourceLimit (tpSpec tp))))

readFailure ∷ ContentKey → ReadOutcome → TexturePipeline → ExpectedFailure
readFailure key outcome tp = case outcome of
  ReadNotFound → notFound key
  ReadTooLarge len _ → tooLarge tp key len
  ReadChanged change → attributed key "content_changed" (changeText change)
  ReadIoError kind → attributed key "io_error" ("the file could not be read: " <> Text.pack (show kind))

changeText ∷ Change → Text
changeText = \case
  Missing → "the file is gone"
  Retyped kind → "the path no longer names a regular file: " <> Text.pack (show kind)
  LengthChanged expected found → "the length changed from " <> Text.pack (show expected) <> " to " <> Text.pack (show found)
  Truncated expected seen → "the file ended after " <> Text.pack (show seen) <> " of " <> Text.pack (show expected) <> " bytes"
  Grew expected → "the file grew past " <> Text.pack (show expected) <> " bytes"
  DigestMismatch → "the bytes are not the ones the inventory pinned"

-- | The expected failure a PNG refusal is: not a PNG or animated is @unsupported_format@, a PNG that is
-- not sound is @invalid_image@, and one over a limit (the workspace bank included) is @too_large@.
refusalFailure ∷ ContentKey → PngRefusal → ExpectedFailure
refusalFailure key refusal = attributed key code (pngRefusalReason refusal)
  where
    code = case pngRefusalClass refusal of
      UnsupportedFormat → "unsupported_format"
      MalformedPng → "invalid_image"
      ExceededLimit _ → "too_large"

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

decodeLossy ∷ ByteString → Text
decodeLossy = Encoding.decodeUtf8With Encoding.lenientDecode

-- Effects ------------------------------------------------------------------------------------------

-- | Run what a transaction decided to do after it committed, masked: each runs, each failure is latched
-- as the pipeline's (an effect is the engine's own call into the host or the backend, and a failure of
-- either is fatal), and an asynchronous exception is raised after the rest ran.
runEffects ∷ TexturePipeline → [IO ()] → IO ()
runEffects tp effects = mask_ $ do
  outcomes ← forM effects (tryWithContext @SomeException)
  forM_ [failure | Left failure ← outcomes] $ \failure@(ExceptionWithContext _ raised) →
    unless (isAsynchronous raised) (latchFailure tp "texture pipeline effect" failure)
  case [failure | Left failure@(ExceptionWithContext _ raised) ← outcomes, isAsynchronous raised] of
    [] → pure ()
    first : _ → rethrowIO first

isAsynchronous ∷ SomeException → Bool
isAsynchronous failure = case fromException failure of
  Just (SomeAsyncException _) → True
  Nothing → False

-- Lanes and stages ---------------------------------------------------------------------------------

-- | Start the oldest pending jobs on every free lane, in one transaction. A job takes a lane and
-- the workspace for its encoded input before its read is submitted; a job that cannot be started
-- (the workspace is too small for its input, or the pool refused it) is settled as a failure.
promote ∷ TexturePipeline → STM [IO ()]
promote tp = snd <$> promoteWith tp

-- | 'promote', and whether it moved any job: a transaction that wrote must not be discarded by a
-- later retry, so the caller needs to know.
promoteWith ∷ TexturePipeline → STM (Bool, [IO ()])
promoteWith tp = do
  st ← readTVar (tpState tp)
  let free = [lane | (lane, found) ← Map.toList (psLanes st), isNothing (laneJob found)]
      pending = sortOn (jOrder . snd) [(jid, job) | (jid, job) ← Map.toAscList (psJobs st), StagePending ← [jStage job]]
  case (psPhase st, free, pending) of
    (Open, lane : _, (jid, job) : _) → do
      effects ← startRead tp lane jid job
      (_, more) ← promoteWith tp
      pure (True, effects <> more)
    _ → pure (False, [])

startRead ∷ TexturePipeline → Int → JobId → Job → STM [IO ()]
startRead tp lane jid job
  | jLength job > tsWorkspace (tpSpec tp) =
      failStage tp jid (ProviderExpected (attributed (jKey job) "too_large" "the file does not fit the pipeline's workspace"))
  | otherwise = do
      submitted ←
        submit
          (tpPool tp)
          ReadRequest
            { requestKey = jKey job
            , requestAllowance = fromIntegral (tsSourceLimit (tpSpec tp))
            , requestPriority = OrdinaryRead
            , requestSink = readSink tp jid
            }
      case submitted of
        Left refusal → do
          let why = case refusal of
                PoolIsClosed → "the read pool is closed"
                PoolHasFailed failure → "the read pool has failed: " <> Text.pack (show failure)
          effects ← failStage tp jid (ProviderFailure ("the texture read was refused: " <> why))
          pure (latchDefect tp ("the texture read was refused: " <> why) : effects)
        Right ticket → do
          modifyState tp $ \st →
            st
              { psLanes = Map.insert lane (Lane (Just jid) (jLength job)) (psLanes st)
              , psJobs = Map.adjust (\found → found {jStage = StageReading ticket, jLane = Just lane, jEncoded = jLength job}) jid (psJobs st)
              }
          pure []

-- | Settle a job and answer it, unless the engine withdrew its interest. The answer is made after the
-- transaction, once the job holds nothing.
failStage ∷ TexturePipeline → JobId → ProviderReply → STM [IO ()]
failStage tp jid reply = do
  settleJob tp jid
  answerFor tp jid reply

-- | The answer a settled job owes the host, as an effect: none for a job the engine withdrew.
answerFor ∷ TexturePipeline → JobId → ProviderReply → STM [IO ()]
answerFor tp jid reply = do
  st ← readTVar (tpState tp)
  pure $ case Map.lookup jid (psJobs st) of
    Just job | not (jWithdrawn job) → [() <$ jReply job reply]
    _ → []

-- | Release everything a job holds on its lane, free the lane and leave the job 'StageSettled'. The
-- job's buffers are dropped with its stage.
settleJob ∷ TexturePipeline → JobId → STM ()
settleJob tp jid = do
  st ← readTVar (tpState tp)
  case Map.lookup jid (psJobs st) of
    Nothing → pure ()
    Just job → do
      let lanes = case jLane job of
            Nothing → Right (psLanes st)
            Just lane → case Map.lookup lane (psLanes st) of
              Just held
                | laneCharged held >= jEncoded job + jOutput job →
                    Right (Map.insert lane (Lane Nothing (laneCharged held - jEncoded job - jOutput job)) (psLanes st))
              _ → Left ()
      case lanes of
        Left () → throwSTM (TextureDefect "a lane was settled for more workspace than it was charged")
        Right updated →
          writeTVar
            (tpState tp)
            st
              { psLanes = updated
              , psJobs = Map.insert jid job {jStage = StageSettled, jLane = Nothing, jEncoded = 0, jOutput = 0} (psJobs st)
              }

-- The reads ------------------------------------------------------------------------------------------

-- | The sink the pool calls, on a read worker's thread, when a read finishes. One transaction: it
-- never waits for a decode, a lane, the backend or Lua.
readSink ∷ TexturePipeline → JobId → ReadResult → IO ()
readSink tp jid result = mask_ $ do
  effects ← atomically (readArrived tp jid result)
  runEffects tp effects

readArrived ∷ TexturePipeline → JobId → ReadResult → STM [IO ()]
readArrived tp jid result = do
  st ← readTVar (tpState tp)
  case Map.lookup jid (psJobs st) of
    Just job | StageReading _ ← jStage job → case result of
      ReadSucceeded bytes
        | psPhase st == Closed || jStopping job → settledAs stopped
        | fromIntegral (ByteString.length bytes) /= jLength job →
            settledAs (ProviderFailure "the verified read returned a buffer other than the inventory's length")
        | jWithdrawn job → settledAs stopped
        | otherwise → [] <$ modifyState tp (\now → now {psJobs = Map.adjust (\found → found {jStage = StageDecodeWait bytes}) jid (psJobs now)})
      ReadFailed (ReadFailure _ _ outcome) → settledAs (ProviderExpected (readFailure (jKey job) outcome tp))
      ReadDefect failure → do
        effects ← settledAs (ProviderFailure (Text.take 1024 (Text.pack ("the texture read failed: " <> show failure))))
        pure (latchDefect tp ("the texture read failed: " <> Text.pack (show failure)) : effects)
      ReadAbandoned → settledAs (ProviderFailure "the texture read was abandoned: its pool ended while the request was live")
    _ → do
      -- A sink for a job that is not reading is a stale delivery: counted, retaining nothing.
      modifyState tp (\now → now {psLate = psLate now + 1})
      pure []
  where
    -- The job is settled and its lane freed first; the answer (none for a withdrawn job) and the
    -- next job's start follow.
    settledAs reply = do
      effects ← failStage tp jid reply
      (effects <>) <$> promote tp
    stopped = ProviderFailure "the texture pipeline stopped while the request was live"

-- The decode worker ----------------------------------------------------------------------------------

-- | What the worker found to do.
data Work
  = WorkStop
  | -- | Something was done in the transaction: these effects follow, maybe none.
    WorkDid ![IO ()]
  | -- | A job to decode, on this lane, from this buffer.
    WorkDecode !JobId !Job !ByteString !Int

-- | The decode worker: the pipeline's progress actor. See the module header.
--
-- It is never allowed to end quietly while the pipeline is open: whether it returned because it was
-- asked to stop, was terminated by an asynchronous exception nobody in this scope sent, or raised,
-- the pipeline fails (what is queued will not run, and every decode job it holds is settled), so
-- nothing accepted is left behind a pipeline that looks healthy. The scope's own exit closes the
-- pipeline before it stops or cancels a worker, so that exit is not a failure.
runWorker ∷ TexturePipeline → StopToken → IO ()
runWorker tp token = mask $ \restore → do
  atomically (modifyState tp (\st → st {psWorkers = psWorkers st + 1}))
  outcome ← tryWithContext @SomeException (loop restore)
  atomically (modifyState tp (\st → st {psWorkers = psWorkers st - 1}))
  open ← atomically (pipelineOpen tp)
  case outcome of
    Right ()
      | not open → pure ()
      | otherwise → do
          failure ← defect "the decode worker ended while the pipeline was open"
          failPipeline tp failure
          rethrowIO failure
    Left caught@(ExceptionWithContext _ raised)
      | not open, Just WorkerCancelled ← fromException raised → rethrowIO caught
      | otherwise → do
          failPipeline tp caught
          rethrowIO caught
  where
    loop ∷ (∀ x. IO x → IO x) → IO ()
    loop restore =
      atomically (nextWork tp token) >>= \case
        WorkStop → pure ()
        WorkDid effects → runEffects tp effects >> loop restore
        WorkDecode jid job bytes lane → do
          decodeJob tp restore jid job bytes lane
          loop restore

-- | The pipeline failed: latch it, close admission and settle every job a transition of the worker
-- would have driven, telling each once.
failPipeline ∷ TexturePipeline → ExceptionWithContext SomeException → IO ()
failPipeline tp failure = do
  latchFailure tp "texture decode worker" failure
  mask_ (closeAndWithdraw tp)

-- | The next thing for the worker to do, in one transaction. Housekeeping first, so a lane is never
-- kept from a pending job by a decode; then the oldest buffer waiting for a decode; otherwise it
-- waits, in STM, for any variable it read to change, or for a stop.
nextWork ∷ TexturePipeline → StopToken → STM Work
nextWork tp token = do
  (progressed, effects) ← housekeeping tp
  if progressed || not (null effects)
    then pure (WorkDid effects)
    else do
      st ← readTVar (tpState tp)
      case sortOn (\(_, job, _) → jOrder job) [(jid, job, bytes) | (jid, job) ← Map.toAscList (psJobs st), StageDecodeWait bytes ← [jStage job], isJust (jLane job)] of
        (jid, job, bytes) : _
          | Just lane ← jLane job → do
              writeTVar (tpState tp) st {psJobs = Map.insert jid job {jStage = StageDecoding} (psJobs st)}
              pure (WorkDecode jid job bytes lane)
        _ → do
          stopping ← stopRequested token
          if stopping then pure WorkStop else retry

-- | The transitions no event drives, in one transaction: reap the reads that retired without calling
-- their sink, start pending jobs on free lanes, and release and retire the textures no lease owns.
-- Answers whether it changed anything, and what to do after it commits. A caller that blocks after
-- calling it must not discard a transaction that wrote, so it acts on the flag.
housekeeping ∷ TexturePipeline → STM (Bool, [IO ()])
housekeeping tp = do
  st ← readTVar (tpState tp)
  reaped ← fmap concat . forM (Map.toAscList (psJobs st)) $ \(jid, job) → case jStage job of
    StageReading ticket | jWithdrawn job || jStopping job → do
      done ← retired ticket
      if done
        then (: []) <$> failStage tp jid (ProviderFailure "the texture pipeline stopped while the request was live")
        else pure []
    _ → pure []
  (started, startEffects) ← promoteWith tp
  now ← readTVar (tpState tp)
  unowned ← forM (Map.toAscList (psOrphans now)) $ \(token, orphan) → orphanStep tp token orphan
  -- A texture the pipeline released for a job nobody will adopt, whose retirement the backend cannot
  -- prove: recorded once as the pipeline's failure, with the charge left held.
  watched ← fmap concat . forM (Map.elems (psJobs now)) $ \job → case jCell job of
    Just cell →
      readTVar (cellState cell) >>= \case
        CellReleasing poll →
          readRetirement poll >>= \case
            ProviderFailed failure → do
              writeTVar (cellState cell) (CellRetirementFailed failure)
              pure [(True, [latchDefect tp ("a texture's retirement failed: " <> Text.pack (show failure))])]
            _ → pure []
        _ → pure []
    Nothing → pure []
  pure
    ( not (null reaped) || started || any fst unowned || not (null watched)
    , concat reaped <> startEffects <> concatMap snd unowned <> concatMap snd watched
    )

-- | One unowned texture: release it if nobody has, and return its charge once the backend proved it
-- retired. A release that failed leaves the charge held and its failure latched.
orphanStep ∷ TexturePipeline → Word64 → Orphan → STM (Bool, [IO ()])
orphanStep tp token orphan =
  readTVar (cellState cell) >>= \case
    -- Nobody has released it: do it after this transaction. The claim inside 'releaseCell' is
    -- atomic, so two actors that both see this release it once.
    CellJob → pure (True, [releaseCell tp cell])
    CellClaimed → pure (False, [])
    CellAdopted → forget []
    CellFailed failure → forget [latchFailure tp "texture release" failure]
    CellRetirementFailed failure → forget [latchDefect tp ("a texture's retirement failed: " <> Text.pack (show failure))]
    CellReleasing poll →
      readRetirement poll >>= \case
        ProviderComplete → returnCharge (orphanCharge orphan) >> forget []
        ProviderPending → pure (False, [])
        ProviderFailed failure → forget [latchDefect tp ("a texture's retirement failed: " <> Text.pack (show failure))]
  where
    cell = orphanCell orphan
    forget effects = do
      modifyState tp (\st → st {psOrphans = Map.delete token (psOrphans st)})
      pure (True, effects)

-- | Preflight, shrink, decode and hand over one buffer. Always ends with the job settled or uploading,
-- whatever happens: an exception settles a job that is still decoding before it propagates, and
-- never one that was already handed to the backend.
decodeJob ∷ TexturePipeline → (∀ x. IO x → IO x) → JobId → Job → ByteString → Int → IO ()
decodeJob tp restore jid job bytes lane = do
  outcome ← tryWithContext @SomeException (decodeStages tp restore jid job bytes lane)
  case outcome of
    Right () → pure ()
    Left caught@(ExceptionWithContext _ raised) → do
      effects ← atomically $ do
        st ← readTVar (tpState tp)
        case Map.lookup jid (psJobs st) of
          Just found | StageDecoding ← jStage found → do
            settled ← failStage tp jid (ProviderFailure "the texture decode was interrupted or failed")
            (settled <>) <$> promote tp
          _ → pure []
      runEffects tp effects
      unless (isAsynchronous raised) (latchFailure tp "texture decode" caught)
      rethrowIO caught

decodeStages ∷ TexturePipeline → (∀ x. IO x → IO x) → JobId → Job → ByteString → Int → IO ()
decodeStages tp restore jid job bytes lane = do
  let key = jKey job
      asset = Asset (AssetId (pathText key)) (FromMemory "verified content read")
  restore (hookDecoding (tpHooks tp) key)
  preflight ← restore (evaluate (preflightPng (tsPngLimits (tpSpec tp)) asset bytes))
  case preflight of
    Left refusal → settleAs (ProviderExpected (refusalFailure key refusal))
    Right pf → do
      let width = fromIntegral (preflightWidth pf) ∷ Word32
          height = fromIntegral (preflightHeight pf) ∷ Word32
      -- The accounted stage boundary: after the fingerprint-verified input and the validated
      -- dimensions, the nominal charge becomes the actual checked size, in one transaction.
      wanted ← atomically $ do
        shrinkNominal (jCharge job) (fromIntegral (preflightRgba8Bytes pf))
        modifyState tp $ \st → st {psJobs = Map.adjust (\found → found {jDims = Just (width, height)}) jid (psJobs st)}
        st ← readTVar (tpState tp)
        pure (maybe False (\found → not (jWithdrawn found || jStopping found)) (Map.lookup jid (psJobs st)))
      if not wanted
        then settleAs (ProviderFailure "the texture pipeline stopped while the request was live")
        else
          decodeBounded (laneAccount tp lane) pf >>= \case
            Left refusal → settleAs (ProviderExpected (refusalFailure key refusal))
            Right image → do
              level ← case decodedLevels image of
                [only] → pure only
                _ → throwIO (TextureDefect "the bounded decode did not produce exactly one level")
              -- The decoder charged the level to the lane: the job records it before anything else can
              -- run, so no interruption leaves a lane carrying a charge no job accounts for.
              atomically $ modifyState tp $ \st →
                st {psJobs = Map.adjust (\found → found {jOutput = fromIntegral (ByteString.length level)}) jid (psJobs st)}
              restore (hookDecoded (tpHooks tp) key)
              handoff tp jid level width height
  where
    settleAs reply = do
      effects ← atomically $ do
        settled ← failStage tp jid reply
        (settled <>) <$> promote tp
      runEffects tp effects

-- | The decoder's account onto one lane's workspace bank: each reservation is checked against what is
-- left and charged in a transaction before the buffer it covers is allocated.
laneAccount ∷ TexturePipeline → Int → PayloadAccount
laneAccount tp lane =
  PayloadAccount
    { reservePayload = \_ amount → atomically (reserveLane tp lane amount)
    , releasePayload = \_ amount → atomically (releaseLane tp lane amount)
    }

reserveLane ∷ TexturePipeline → Int → Int → STM Bool
reserveLane tp lane amount = do
  st ← readTVar (tpState tp)
  case Map.lookup lane (psLanes st) of
    Nothing → throwSTM (TextureDefect "a decode reserved workspace on a lane that does not exist")
    Just found
      | amount < 0 → throwSTM (TextureDefect "a decode reserved a negative amount of workspace")
      | fromIntegral amount > tsWorkspace (tpSpec tp) - laneCharged found → pure False
      | otherwise → do
          writeTVar (tpState tp) st {psLanes = Map.insert lane found {laneCharged = laneCharged found + fromIntegral amount} (psLanes st)}
          pure True

releaseLane ∷ TexturePipeline → Int → Int → STM ()
releaseLane tp lane amount = do
  st ← readTVar (tpState tp)
  case Map.lookup lane (psLanes st) of
    Just found
      | amount >= 0 && fromIntegral amount <= laneCharged found →
          writeTVar (tpState tp) st {psLanes = Map.insert lane found {laneCharged = laneCharged found - fromIntegral amount} (psLanes st)}
    _ → throwSTM (TextureDefect "a decode released workspace its lane was not charged")

-- | The decoded level is the lane's: the encoded input is released and dropped here, the one place
-- the pipeline stops holding it, and the backend is handed the level (borrowed, charged to the lane until
-- the backend retires it).
--
-- The intent to hand over is recorded before the call, so a sink event that arrives while
-- 'backendUpload' is still running finds the job uploading; and what the call returned is recorded after,
-- so a cancellation that arrived meanwhile is told to the work at once.
handoff ∷ TexturePipeline → JobId → ByteString → Word32 → Word32 → IO ()
handoff tp jid level width height = do
  decision ← atomically $ do
    st ← readTVar (tpState tp)
    job ← maybe (throwSTM (TextureDefect "a decoded job's record was lost")) pure (Map.lookup jid (psJobs st))
    lane ← maybe (throwSTM (TextureDefect "a decoded job holds no lane")) pure (jLane job)
    held ← maybe (throwSTM (TextureDefect "a decoded job's lane was lost")) pure (Map.lookup lane (psLanes st))
    when (laneCharged held < jEncoded job) $ throwSTM (TextureDefect "a lane's charge for the encoded input was lost")
    -- The encoded input is released and dropped in this one transaction.
    let wanted = not (jWithdrawn job || jStopping job || psPhase st == Closed)
        job' = job {jEncoded = 0, jStage = if wanted then StageUploading else jStage job, jUpload = if wanted then UploadIssuing else UploadNone}
    writeTVar
      (tpState tp)
      st
        { psLanes = Map.insert lane held {laneCharged = laneCharged held - jEncoded job} (psLanes st)
        , psJobs = Map.insert jid job' (psJobs st)
        }
    if wanted
      then pure (Just (jKey job), [])
      else do
        settled ← failStage tp jid (ProviderFailure "the texture pipeline stopped while the request was live")
        (Nothing,) . (settled <>) <$> promote tp
  case decision of
    (Nothing, effects) → runEffects tp effects
    (Just key, _) → do
      let upload = Upload {uploadSource = renderKey key, uploadWidth = width, uploadHeight = height, uploadTexels = level}
      issued ← tryWithContext @SomeException (backendUpload (tpBackend tp) upload (sinkFor tp jid))
      case issued of
        Right work → do
          effects ← atomically $ do
            st ← readTVar (tpState tp)
            case Map.lookup jid (psJobs st) of
              -- The backend may deliver both events before the call returns, the job settle, its result
              -- be adopted and taken, and the host return its record: there is then nothing left to
              -- record the work against, and nothing the work still owes.
              Nothing → pure []
              Just job | not (isUploading job) → pure []
              Just job → do
                let cancelNow = (jWithdrawn job || jStopping job) && not (jUploadCancelled job)
                    -- An event delivered while the call ran may have moved the job on: only a
                    -- job still issuing records the work.
                    recorded = case jUpload job of
                      UploadIssuing → UploadIssued work
                      other → other
                modifyState tp (\now → now {psJobs = Map.insert jid job {jUpload = recorded, jUploadCancelled = jUploadCancelled job || cancelNow} (psJobs now)})
                pure [uploadCancel work | cancelNow]
          runEffects tp effects
        Left caught@(ExceptionWithContext _ raised) → do
          -- The backend raised: it accepted nothing and retained nothing, so the level is no longer
          -- borrowed. A job that events had already settled is left as they left it.
          effects ← atomically $ do
            st ← readTVar (tpState tp)
            case Map.lookup jid (psJobs st) of
              Just job | StageUploading ← jStage job → do
                modifyState tp (\now → now {psJobs = Map.adjust (\found → found {jTerminal = True, jBuffersRetired = True, jUpload = UploadNone}) jid (psJobs now)})
                released ← releaseOutput tp jid
                settled ← failStage tp jid (ProviderFailure "the upload backend raised while it was handed the texture")
                cells ← releaseDeliveredCell tp jid
                more ← promote tp
                pure (released <> settled <> cells <> more)
              _ → pure []
          runEffects tp effects
          unless (isAsynchronous raised) (latchFailure tp "texture backend upload" caught)
          rethrowIO caught
  where
    renderKey key = decodeLossy (rootKeyBytes (contentKeyRoot key)) <> ":" <> pathText key

-- | Release the job's charge for the decoded level on its lane (the backend no longer reads it).
releaseOutput ∷ TexturePipeline → JobId → STM [IO ()]
releaseOutput tp jid = do
  st ← readTVar (tpState tp)
  case Map.lookup jid (psJobs st) of
    Just job | Just lane ← jLane job, jOutput job > 0 → case Map.lookup lane (psLanes st) of
      Just held
        | laneCharged held >= jOutput job → do
            writeTVar
              (tpState tp)
              st
                { psLanes = Map.insert lane held {laneCharged = laneCharged held - jOutput job} (psLanes st)
                , psJobs = Map.insert jid job {jOutput = 0} (psJobs st)
                }
            pure []
      _ → throwSTM (TextureDefect "a lane's charge for the decoded level was lost")
    _ → pure []

-- The upload sink -----------------------------------------------------------------------------------

data Event
  = EventReady !BackendTexture
  | EventFailed !UploadFailure
  | EventWithdrawn
  | EventBuffersRetired

-- | The sink the backend answers one upload through. Each call is one transaction and never waits.
sinkFor ∷ TexturePipeline → JobId → UploadSink
sinkFor tp jid =
  UploadSink
    { sinkReady = event . EventReady
    , sinkFailed = event . EventFailed
    , sinkWithdrawn = event EventWithdrawn
    , sinkBuffersRetired = event EventBuffersRetired
    }
  where
    event ev = mask_ $ do
      (answer, effects) ← atomically (uploadEvent tp jid ev)
      runEffects tp effects
      pure answer

uploadEvent ∷ TexturePipeline → JobId → Event → STM (SinkAnswer, [IO ()])
uploadEvent tp jid ev = do
  st ← readTVar (tpState tp)
  case Map.lookup jid (psJobs st) of
    Just job | StageUploading ← jStage job → case ev of
      EventBuffersRetired
        | jBuffersRetired job → late
        | otherwise → do
            modifyState tp (\now → now {psJobs = Map.adjust (\found → found {jBuffersRetired = True}) jid (psJobs now)})
            released ← releaseOutput tp jid
            (SinkTaken,) . (released <>) <$> finishIfDone job {jBuffersRetired = True}
      EventReady texture
        | jTerminal job → late
        | otherwise → do
            state ← newTVar CellJob
            let cell = Cell texture state
            modifyState tp (\now → now {psJobs = Map.adjust (\found → found {jTerminal = True, jCell = Just cell}) jid (psJobs now)})
            (SinkTaken,) <$> finishIfDone job {jTerminal = True, jCell = Just cell} {- the answer, if any, follows -}
      EventFailed (UploadFailure why) → terminal job (Just why)
      EventWithdrawn → terminal job Nothing
    _ → late
  where
    late = do
      modifyState tp (\now → now {psLate = psLate now + 1})
      pure (SinkLate, [])
    terminal job failure
      | jTerminal job = late
      | otherwise = do
          modifyState tp (\now → now {psJobs = Map.adjust (\found → found {jTerminal = True, jFailure = failure}) jid (psJobs now)})
          effects ← case failure of
            Just why → pure [latchDefect tp ("the upload backend failed: " <> why)]
            Nothing
              | jWithdrawn job || jStopping job → pure []
              | otherwise → pure [latchDefect tp "the upload backend withdrew an upload nobody cancelled"]
          (SinkTaken,) . (effects <>) <$> finishIfDone job {jTerminal = True, jFailure = failure}
    -- When both the terminal event and the retirement of the borrowed level have arrived the job
    -- holds nothing: settle it, start the next job on the lane, and only then answer.
    finishIfDone job
      | jTerminal job && jBuffersRetired job = do
          now ← readTVar (tpState tp)
          case Map.lookup jid (psJobs now) of
            Nothing → pure []
            Just current → do
              settleJob tp jid
              next ← promote tp
              answers ← settledAnswer tp jid current
              pure (answers <> next)
      | otherwise = pure []

-- | What an upload that ended owes the host: success when a usable registration arrived and nobody
-- withdrew or stopped; the matching failure otherwise. Nothing for a withdrawn job, whose texture, if any,
-- is released by the pipeline.
settledAnswer ∷ TexturePipeline → JobId → Job → STM [IO ()]
settledAnswer tp jid job = case jCell job of
  Just cell
    | jWithdrawn job → pure [releaseCell tp cell]
    | jStopping job → do
        answers ← answerFor tp jid (ProviderFailure "the texture pipeline stopped while the request was live")
        pure (releaseCell tp cell : answers)
    | Just (width, height) ← jDims job →
        pure
          [ do
              answer ← jReply job (ProviderResource (VRecord [("width", VInteger (fromIntegral width)), ("height", VInteger (fromIntegral height))]) (adoptionFor tp jid cell width height (jCharge job)))
              case answer of
                ReplyLate → releaseCell tp cell
                ReplyUnknown → releaseCell tp cell
                ReplyRefusedValue → latchDefect tp "the host refused a texture result" >> releaseCell tp cell
                ReplyDefective → latchDefect tp "the host found a texture result defective" >> releaseCell tp cell
                _ → pure ()
          ]
    | otherwise → pure [latchDefect tp "a texture was delivered for a job with no dimensions"]
  Nothing
    | jWithdrawn job → pure []
    | jStopping job → answerFor tp jid (ProviderFailure "the texture pipeline stopped while the request was live")
    | Just why ← jFailure job → answerFor tp jid (ProviderFailure ("the upload backend failed: " <> why))
    | otherwise → answerFor tp jid (ProviderFailure "the upload ended without a texture or a failure")

-- | The delivered texture of a job nobody will adopt, as an effect to release it.
releaseDeliveredCell ∷ TexturePipeline → JobId → STM [IO ()]
releaseDeliveredCell tp jid = do
  st ← readTVar (tpState tp)
  pure [releaseCell tp cell | Just job ← [Map.lookup jid (psJobs st)], Just cell ← [jCell job]]

-- Cancellation --------------------------------------------------------------------------------------

-- | The host's one telling that the engine's interest in a job was withdrawn (the script cancelled,
-- the instance ended, an epoch changed or the owner stopped). Withdraws what has not started and
-- cancels what has, as far as each stage allows, and never waits. It is not proof the work ended: the
-- retirement reading is.
cancelJob ∷ TexturePipeline → JobId → IO ()
cancelJob tp jid = do
  effects ← atomically $ do
    modifyState tp (\st → st {psJobs = Map.adjust (\job → job {jWithdrawn = True}) jid (psJobs st)})
    withdrawJob tp jid
  runEffects tp effects

-- | Tell the stage a job is in that nobody wants its result, in a transaction that has already marked
-- the job withdrawn or stopping.
withdrawJob ∷ TexturePipeline → JobId → STM [IO ()]
withdrawJob tp jid = do
  st ← readTVar (tpState tp)
  case Map.lookup jid (psJobs st) of
    Nothing → pure []
    Just job → do
      stageEffects ← case jStage job of
        StagePending → [] <$ settleJob tp jid
        StageReading ticket →
          cancel ticket >>= \case
            CancelWithdrawn → (<>) <$> pure [] <*> (settleJob tp jid >> promote tp)
            CancelInFlight → pure []
            CancelTooLate → pure []
        StageDecodeWait _ → (<>) <$> pure [] <*> (settleJob tp jid >> promote tp)
        StageDecoding → pure []
        StageUploading → case jUpload job of
          UploadIssued work | not (jUploadCancelled job) → do
            modifyState tp (\now → now {psJobs = Map.adjust (\found → found {jUploadCancelled = True}) jid (psJobs now)})
            pure [uploadCancel work]
          _ → pure []
        StageSettled → pure []
      -- A texture delivered and not yet adopted is the pipeline's to release.
      cellEffects ← case jCell job of
        Just cell | jWithdrawn job → pure [releaseCell tp cell]
        _ → pure []
      pure (stageEffects <> cellEffects)

-- | The provider's own reading of where a job's work has got to: over once the job is settled and any
-- texture the pipeline holds for it is proved retired. It only reads.
jobRetirement ∷ TexturePipeline → JobId → STM RetirementState
jobRetirement tp jid = do
  st ← readTVar (tpState tp)
  case Map.lookup jid (psJobs st) of
    Nothing → pure ProviderComplete
    Just job
      | not (isSettled job) → pure ProviderPending
      | otherwise → case jCell job of
          Nothing → pure ProviderComplete
          Just cell →
            readTVar (cellState cell) >>= \case
              CellAdopted → pure ProviderComplete
              CellJob → pure ProviderPending
              CellClaimed → pure ProviderPending
              CellReleasing poll → readRetirement poll
              CellFailed (ExceptionWithContext _ failure) → pure (ProviderFailed failure)
              CellRetirementFailed failure → pure (ProviderFailed failure)

-- The texture ----------------------------------------------------------------------------------------

-- | Who is releasing a cell.
data Claimant = ByPipeline | ByLease
  deriving (Eq)

-- | The resource a lease holds for a texture: the backend's registration and what is needed to give
-- it back. Typeable, so the lease can find it again for a use.
data TextureResource = TextureResource
  { resourceTexture ∷ !BackendTexture
  , resourceWidth ∷ !Word32
  , resourceHeight ∷ !Word32
  , resourceCell ∷ !Cell
  , resourceCharge ∷ !TextureCharge
  }

-- | The recipe the host runs, on the owner's thread, to build the texture into the lease the request
-- reserved. It adopts the cell if no one has released it; if the pipeline already did (the request was
-- cancelled between the answer and the build) the lease is built over a texture whose release is
-- already under way, so its charges are returned when that release retires.
adoptionFor ∷ TexturePipeline → JobId → Cell → Word32 → Word32 → TextureCharge → Adoption
adoptionFor _ _ cell width height charge =
  Adoption $ \retirements →
    acquirePart
      "texture"
      (releaseRank 0)
      ( do
          atomically $ readTVar (cellState cell) >>= \case
            CellJob → writeTVar (cellState cell) CellAdopted
            _ → pure ()
          pure TextureResource {resourceTexture = cellTexture cell, resourceWidth = width, resourceHeight = height, resourceCell = cell, resourceCharge = charge}
      )
      (releaseResource retirements)

-- | The release of a texture's lease: request the backend's release once, and return the texture's slot
-- and nominal bytes only after the backend proved it retired. It never waits for the backend.
--
-- If the backend can already prove the texture retired, the release itself completes the retirement:
-- the charges are returned here and nothing is left for the lease to wait for, so the lease answers
-- that the release is done. Otherwise the retirement is recorded and the lease stays charged until the
-- backend's reading says it is over. A release that raised is retained and re-raised, and the charges
-- stay held: a failed cleanup is never reported as reclaimed.
releaseResource ∷ Retirements → TextureResource → IO ()
releaseResource retirements resource = do
  releaseCellBy ByLease (resourceCell resource)
  settled ← atomically $
    readTVar (cellState (resourceCell resource)) >>= \case
      CellClaimed → retry
      other → pure other
  case settled of
    CellFailed failure → rethrowIO failure
    -- Its retirement already failed: the lease records that, whole, and keeps the charges held.
    CellRetirementFailed failure → retireAsynchronously retirements "texture" (pure (ProviderFailed failure))
    CellReleasing poll → do
      now ← atomically (readRetirement poll)
      case now of
        ProviderComplete → atomically (returnCharge (resourceCharge resource))
        _ → do
          retireAsynchronously retirements "texture" poll
          afterRetirement retirements (atomically (returnCharge (resourceCharge resource)))
    _ → throwIO (TextureDefect "a lease released a texture whose release was never requested")

-- | Request the release of a cell on behalf of the pipeline.
releaseCell ∷ TexturePipeline → Cell → IO ()
releaseCell tp cell = do
  outcome ← tryWithContext @SomeException (releaseCellBy ByPipeline cell)
  case outcome of
    Right () → pure ()
    Left failure@(ExceptionWithContext _ raised) → unless (isAsynchronous raised) (latchFailure tp "texture release" failure)

-- | Claim the cell for release if its state allows this claimant to, call the backend's release (never
-- waiting) and record what it answered. Exactly one claimant ever calls the backend: the claim is one
-- transaction on the cell, and the pipeline may claim only a cell no lease adopted, the lease only an
-- adopted one.
releaseCellBy ∷ Claimant → Cell → IO ()
releaseCellBy by cell = mask_ $ do
  claimed ← atomically $
    readTVar (cellState cell) >>= \case
      CellJob | by == ByPipeline → True <$ writeTVar (cellState cell) CellClaimed
      CellAdopted | by == ByLease → True <$ writeTVar (cellState cell) CellClaimed
      _ → pure False
  when claimed $ do
    outcome ← tryWithContext @SomeException (textureRelease (cellTexture cell))
    atomically . writeTVar (cellState cell) $ case outcome of
      Right poll → CellReleasing poll
      Left failure → CellFailed failure
    either rethrowIO (\_ → pure ()) outcome

-- Closing and draining --------------------------------------------------------------------------------

-- | Close admission, withdraw what has not started and tell every started job to stop: nothing is
-- answered with a success from here on. Every job is told once; what is in flight retires on its own.
closeAndWithdraw ∷ TexturePipeline → IO ()
closeAndWithdraw tp = do
  effects ← atomically $ do
    modifyState tp (\st → st {psPhase = Closed})
    st ← readTVar (tpState tp)
    fmap concat . forM (Map.toAscList (psJobs st)) $ \(jid, job) → case jStage job of
      -- A texture delivered and not yet adopted is the pipeline's to release: the host's build of
      -- it, if it still comes, finds it released.
      StageSettled → pure [releaseCell tp cell | Just cell ← [jCell job]]
      _ → stopJob jid job
  runEffects tp effects
  where
    stopJob jid job = do
      modifyState tp (\st → st {psJobs = Map.adjust (\found → found {jStopping = True}) jid (psJobs st)})
      let stoppedAnswer = [() <$ jReply job (ProviderFailure "the texture pipeline stopped while the request was live") | not (jWithdrawn job)]
          settledNow = (stoppedAnswer <>) <$> (settleJob tp jid >> pure [])
      case jStage job of
        StagePending → settledNow
        StageDecodeWait _ → settledNow
        StageReading ticket →
          cancel ticket >>= \case
            CancelWithdrawn → settledNow
            _ → pure []
        StageDecoding → pure []
        StageUploading → case jUpload job of
          UploadIssued work | not (jUploadCancelled job) → do
            modifyState tp (\st → st {psJobs = Map.adjust (\found → found {jUploadCancelled = True}) jid (psJobs st)})
            pure [uploadCancel work]
          _ → pure []
        StageSettled → pure []

-- | Wait until nothing the pipeline started is left: no lane in use, no job in a stage, no decode
-- running, and no delivered texture unreleased or unretired. Runs the housekeeping itself, so it never
-- depends on the worker being alive. Cancellation delivered meanwhile is remembered and raised at the
-- end, so a drain is never cut short by it.
drain ∷ TexturePipeline → IO ()
drain tp = do
  pending ← newIORef (Nothing ∷ Maybe (ExceptionWithContext SomeException))
  go pending
  readIORef pending >>= maybe (pure ()) rethrowIO
  where
    go ∷ IORef (Maybe (ExceptionWithContext SomeException)) → IO ()
    go pending = do
      stepped ← tryWithContext @SomeException . atomically $ do
        (progressed, effects) ← housekeeping tp
        if progressed || not (null effects)
          then pure (Just effects)
          else do
            done ← drained tp
            if done then pure Nothing else retry
      case stepped of
        Right (Just effects) → runEffects tp effects >> go pending
        Right Nothing → pure ()
        Left caught → do
          atomicModifyIORef' pending (\held → (Just (fromMaybe caught held), ()))
          go pending

-- | Whether nothing the pipeline started is left: the condition a closing scope waits for. Read-only.
pipelineDrained ∷ TexturePipeline → STM Bool
pipelineDrained = drained

-- | Nothing left in flight.
drained ∷ TexturePipeline → STM Bool
drained tp = do
  st ← readTVar (tpState tp)
  let idle = all (\job → isSettled job) (Map.elems (psJobs st))
      lanesFree = all (isNothing . laneJob) (Map.elems (psLanes st))
  unretired ← fmap or . forM (Map.elems (psJobs st)) $ \job → case jCell job of
    Just cell →
      readTVar (cellState cell) >>= \case
        CellJob → pure True
        CellClaimed → pure True
        CellReleasing poll → readRetirement poll <&> \case ProviderPending → True; _ → False
        _ → pure False
    Nothing → pure False
  pure (idle && lanesFree && Map.null (psOrphans st) && not unretired)

closeAndDrain ∷ TexturePipeline → IO ()
closeAndDrain tp = mask_ (closeAndWithdraw tp) >> drain tp
