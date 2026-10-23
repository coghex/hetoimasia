-- | The M1 texture pipeline (LFE-16): the endpoint that answers an asynchronous request for a usable,
-- instance-owned texture, the lanes, worker and reservations behind it, and the explicit release.
--
-- = What it is
--
-- A texture request is one operation that covers a verified read of an inventoried file, a static PNG
-- decode, an upload and a registration, and it succeeds only when the backend reports the upload
-- complete and the registration usable. The result carries the instance's opaque texture lease and the
-- source dimensions, ready for the later @{texture = HANDLE, width = INTEGER, height = INTEGER}@
-- ('textureValueSchema'). It does not promise a displayed frame, a window or a CPU image.
--
-- It is a /composable typed endpoint/, not a Lua API. The eventual graphics facade (LFE-21) parses its
-- arguments into a 'TextureRequest' with 'textureKey', builds its binding from 'startTexture' beside
-- 'textureArgumentCheck', registers the handle type @texture@ over its 'Leases', and binds
-- 'releaseTexture' to @release@. Nothing here is installed in a VM, imports a window, a Vulkan or GLFW
-- type, or can succeed without a backend: 'TextureBackend' is injected, and the concrete one is LFE-17's.
--
-- = The pieces, and who owns them
--
-- * The /pipeline/ ('withTexturePipeline') is the session's. It borrows the shared read pool (two
--   I/O workers, LFE-10) and the inventory, adds one CPU decode worker and two lanes, and is given the
--   backend. It owns every queue and record below; its scope ends only after every started read, decode
--   and upload has retired and every texture it still holds has been released and proved retired.
-- * A /texture owner/ ('newTextureOwner') is one UI instance's banks: its 16 texture slots and 128 MiB of
--   nominal bytes. The instance's bindings hold it. There is no registry of owners, no global instance
--   table and no environment record: ownership is a value passed to the bindings that need it.
-- * A /lane/ is one of two pipeline lanes. A job holds one from the moment its read is started until the
--   backend stops reading the decoded level, with a workspace bank of 128 MiB of accounted CPU payload.
-- * The /lease/ is the instance's: the engine's own lease tracking ("Hetoimasia.Scripting.Lua.Lease")
--   holds the texture after the request settled, until the instance releases it or ends.
--
-- = What is reserved, and when
--
-- One atomic admission, with the request's own bookkeeping, reserves everything the request will need
-- before the provider is handed anything:
--
-- +-----------------------+-------------------------------------------+--------------------------------+
-- | Reserved at admission | Bank                                      | Returned                       |
-- +=======================+===========================================+================================+
-- | request and result    | 16 per instance, 64 per VM (the host's)   | result taken and work retired  |
-- | result lease capacity | the instance's lease scope                | with the instance's lease      |
-- | texture slot          | 16 pending/live/retiring per UI instance  | texture proved retired         |
-- | nominal RGBA8 bytes   | 16 MiB reserved; 128 MiB per instance,    | texture proved retired         |
-- |                       | 256 MiB per session                       | (shrunk after the decode stage |
-- |                       |                                           | validated the dimensions)      |
-- | accepted-work record  | the pipeline's job capacity               | request taken, work retired    |
-- | queue slot            | the read pool's                           | request taken, read retired    |
-- +-----------------------+-------------------------------------------+--------------------------------+
--
-- A bank without room is the host's busy answer, with no file open, no decode, no backend call and
-- nothing reserved. A malformed address, a wrong role or phase, a closed owner or a stopping pipeline
-- are permanent and refused as ordinary Lua errors before any admission. The maximum 16 MiB output is
-- reserved without reading a header, so a small image can be refused busy while the banks hold large
-- reservations: that is accepted behavior. A file the inventory does not hold, or one over the
-- 32 MiB source limit, is accepted and fails as @not_found@ or @too_large@ without a worker.
--
-- The slot and the nominal bytes /transfer/ to the texture when the lease adopts it. They are not
-- returned when the request is taken, or when the pipeline's CPU buffers retire, or when Lua loses its
-- handle: they are returned when the backend proves the texture itself retired.
--
-- = Failures
--
-- An expected failure carries one of 'textureCodes' with the root and path: @not_found@,
-- @content_changed@, @io_error@, @too_large@ (a file or a decode over a limit, the workspace bank
-- included), @unsupported_format@ (not a PNG, or animated) and @invalid_image@. A required request's
-- failure latches at its eligible settlement whether or not it is read; an optional one is data.
-- A defect of the reader, the pool, the decode worker, the backend, the allocator or a release is a
-- provider defect: it fails the owner at its next boundary, required or optional alike, and is latched
-- as the pipeline's own failure ('awaitPipelineFailure'). It is never given a code and never busy.
--
-- = Independent loads
--
-- Every request has its own verified read, decode, upload and texture, even for the same path from the
-- same instance. There is no cache, no coalescing of work in flight and no sharing between instances;
-- only the pool, the decode worker, the lanes and the device are shared. An instance may use one live
-- texture in many sprites, and cannot use or release another instance's.
module Hetoimasia.LuaEngine.Texture
  ( -- * The pipeline
    TextureSpec
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
  , TexturePipeline
  , withTexturePipeline
  , withTexturePipelineWith
  , PipelineHooks (..)
  , noHooks
  , pipelineSpec
  , pipelineOpen
  , pipelineDrained
  , PipelineReading (..)
  , LaneReading (..)
  , pipelineReading
  , awaitPipelineFailure
  , pipelineFailureEvidence
  , TextureDefect (..)

    -- * The backend
  , module Hetoimasia.LuaEngine.Texture.Backend

    -- * One UI instance's banks
  , TextureOwner
  , TextureRole (..)
  , newTextureOwner
  , closeTextureOwner
  , OwnerReading (..)
  , ownerReading
  , sessionNominal
  , BankDefect (..)

    -- * The service
  , TextureService
  , TextureServiceRefused (..)
  , textureService
  , textureEndpointName
  , textureEndpoint
  , textureCodes
  , textureHandleType
  , textureResultSchema
  , textureValueSchema

    -- * What is asked
  , textureKey
  , TextureRequest (..)
  , textureAsk
  , TextureStart (..)
  , startTexture
  , textureArgumentCheck

    -- * Using and releasing
  , TextureView (..)
  , withTexture
  , TextureRelease (..)
  , releaseTexture
  , releaseWord
  ) where

import Control.Concurrent.STM (STM, atomically)
import Control.Exception (finally, mask, throwIO)
import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.Functor ((<&>))
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import qualified Data.Text.Encoding.Error as Encoding
import Data.Word (Word32, Word64)
import GHC.Stack (HasCallStack)
import Hetoimasia.Content.Identity
  ( ContentKey
  , ReferenceRefusal
  , contentKeyPath
  , logicalPathBytes
  , parseReference
  )
import Hetoimasia.Content.Inventory
  ( inventoryIdentityLimits
  , inventoryLimitsOf
  , inventoryRootKey
  )
import Hetoimasia.LuaEngine.Request
  ( M1Ask (..)
  , M1Requests
  , M1Start (..)
  , m1Ask
  , m1ArgumentCheck
  , m1Profile
  , startM1
  )
import Hetoimasia.LuaEngine.Texture.Backend
import Hetoimasia.LuaEngine.Texture.Banks
  ( BankDefect (..)
  , TextureOwner
  , TextureRole (..)
  , closeOwner
  , ownerBytesCharged
  , ownerIsOpen
  , ownerRole
  , ownerSession
  , ownerSlotsCharged
  )
import Hetoimasia.LuaEngine.Texture.Pipeline
import Hetoimasia.Scripting.Lua.Admission (Necessity)
import Hetoimasia.Scripting.Lua.Lease
  ( Leases
  , Ownership (InstanceOwned)
  , ReleaseAnswer (..)
  , releaseLease
  , withLease
  )
import Hetoimasia.Scripting.Lua.Provider
  ( Completion (..)
  , ProviderWork
  , RequestEndpoint (..)
  , Submission (..)
  )
import Hetoimasia.Scripting.Lua.Registration (ArgumentCheck, RequestContext)
import Hetoimasia.Scripting.Lua.Value (Schema (SCapability, SInteger, SRecord), Value (VCapability, VInteger, VRecord), capability)

-- The service ---------------------------------------------------------------------------------------

-- | The texture service of one VM's facade: the request policy and the session's pipeline.
data TextureService = TextureService
  { serviceRequests ∷ !M1Requests
  , servicePipeline ∷ !TexturePipeline
  }

-- | Why a service could not be made.
data TextureServiceRefused
  = -- | The request policy and the pipeline were built from different profiles. A larger policy
    -- would admit more than the pipeline's banks hold, a smaller one less.
    ProfileDisagrees
  deriving (Eq, Show)

-- | The service over this request policy and pipeline, which must share one validated profile.
textureService ∷ M1Requests → TexturePipeline → Either TextureServiceRefused TextureService
textureService requests pipeline
  | m1Profile requests /= specProfile (pipelineSpec pipeline) = Left ProfileDisagrees
  | otherwise = Right (TextureService requests pipeline)

-- | The endpoint's name in a grant.
textureEndpointName ∷ Text
textureEndpointName = "texture"

-- | The capability type name of a texture lease's handle: register it over the instance's 'Leases' with
-- @leaseCapabilityType leases textureHandleType@.
textureHandleType ∷ Text
textureHandleType = "texture"

-- | What the endpoint answers: the source dimensions. The lease's handle is composed in by the host, so
-- the schema a grant declares names no capability.
textureResultSchema ∷ Schema
textureResultSchema = SRecord [("width", SInteger), ("height", SInteger)]

-- | What @take@ hands as a success value, once the lease's handle is composed in:
-- @{texture = HANDLE, width = INTEGER, height = INTEGER}@.
textureValueSchema ∷ Schema
textureValueSchema = SRecord [("texture", SCapability textureHandleType), ("width", SInteger), ("height", SInteger)]

-- What is asked -------------------------------------------------------------------------------------

-- | The key a reference names in the service's root: the checked-address boundary. A malformed
-- reference is a permanent argument error, refused before any admission; it is never a content failure.
textureKey ∷ TextureService → ByteString → Either ReferenceRefusal ContentKey
textureKey service =
  parseReference
    (inventoryIdentityLimits (inventoryLimitsOf inventory))
    (inventoryRootKey inventory)
  where
    inventory = pipelineInventory (servicePipeline service)

-- | A request for a texture: for which instance, of which file, and whether its expected failure fails
-- the instance. Required is the default and optional is explicit, and there is no tick offset: a texture
-- is acquired by presentation-instance hook work and settles on arrival.
--
-- The owner and the necessity are the facade boundary's: they come from the immutable metadata of the
-- instance making the call and are never read from Lua tables.
data TextureRequest = TextureRequest
  { requestedOwner ∷ !TextureOwner
  , requestedKey ∷ !ContentKey
  , requestedNecessity ∷ !Necessity
  }

-- | The ask the host admits for a prepared request: its requirement, source, codes, credits and the
-- result lease it reserves, whose success value holds the lease's handle.
textureAsk ∷ TextureService → TextureRequest → Prepared → M1Ask
textureAsk service request prepared =
  (askFor service request) {askCredits = requestCredits (servicePipeline service) prepared}

-- | The ask without credits, for the permanent-refusal check that reserves nothing.
askFor ∷ TextureService → TextureRequest → M1Ask
askFor _ request =
  (m1Ask (requestedNecessity request) ("texture " <> pathText (requestedKey request)))
    { askOffset = Nothing
    , askCodes = textureCodes
    , askLease = Just (InstanceOwned, composeTexture)
    }
  where
    composeTexture value key = case value of
      VRecord fields → VRecord (("texture", VCapability (capability textureHandleType key)) : fields)
      other → other

pathText ∷ ContentKey → Text
pathText = Encoding.decodeUtf8With Encoding.lenientDecode . logicalPathBytes . contentKeyPath

-- | What starting a texture request came to.
data TextureStart
  = -- | The host's answer: accepted, or busy with nothing reserved.
    TextureStarted !M1Start
  | -- | A permanent refusal that reached the admission after the argument check passed (the owner was
    -- closed, or the pipeline began closing, in between): nothing was reserved and no work was done. The
    -- facade raises it as the error it is.
    TextureRefused !Text
  deriving (Eq, Show)

-- | Start a texture request atomically: accepted, or busy with nothing reserved, no file opened and no
-- backend call. Permanent refusals are the argument check's ('textureArgumentCheck'); one that lands
-- after it passed is the admission's own and comes back as 'TextureRefused', never as busy. A call that
-- skipped the check meets the role here, as a fault of the call.
--
-- The request's token and charge are prepared before the admission and dropped after it, whatever it
-- came to, so the pipeline keeps nothing for a request that was refused.
startTexture ∷ HasCallStack ⇒ TextureService → TextureRequest → RequestContext → IO TextureStart
startTexture service request context = mask $ \restore → do
  let pipeline = servicePipeline service
      owner = requestedOwner request
  when (ownerRole owner /= PresentationRole) $
    throwIO (TextureDefect "texture acquisition is presentation-instance hook work")
  prepared ← prepareRequest pipeline owner (requestedKey request)
  started ←
    restore
      ( startM1
          (serviceRequests service)
          (textureAsk service request prepared)
          context
          textureEndpointName
          [VInteger (fromIntegral (prepToken prepared))]
          (pure ())
      )
      `finally` forgetPrepared pipeline (prepToken prepared)
  case started of
    -- The first credit answered no: read the same facts again to tell a permanent refusal from a bank
    -- that was merely full when it was asked.
    M1Busy _ → do
      (open, taking) ← atomically ((,) <$> pipelineOpen pipeline <*> ownerIsOpen owner)
      pure $ case refusalOf pipeline owner open taking of
        Just why → TextureRefused why
        Nothing → TextureStarted started
    other → pure (TextureStarted other)

-- | The argument check of a binding that builds the request from its copied arguments: the service's
-- own permanent facts (the owner belongs to this pipeline and has not been closed, the pipeline is
-- taking requests) and then the host's (role, phase, exhausted numbers), decided before any action and
-- reserving nothing. A bank that is merely full is not here: that is busy.
textureArgumentCheck ∷ TextureService → ([Value] → TextureRequest) → ArgumentCheck
textureArgumentCheck service requestOf owner values = do
  let request = requestOf values
      pipeline = servicePipeline service
  refusal ← atomically $ do
    open ← pipelineOpen pipeline
    taking ← ownerIsOpen (requestedOwner request)
    pure $ refusalOf pipeline (requestedOwner request) open taking
  case refusal of
    Just why → pure (Just why)
    Nothing → m1ArgumentCheck (serviceRequests service) (askFor service . requestOf) owner values

-- | The service's own permanent facts, in the order they are decided.
refusalOf ∷ TexturePipeline → TextureOwner → Bool → Bool → Maybe Text
refusalOf pipeline owner open taking
  | ownerSession owner /= pipelineSession pipeline = Just "the texture owner belongs to another pipeline"
  | ownerRole owner /= PresentationRole = Just "texture acquisition is presentation-instance hook work"
  | not taking = Just "the texture owner has ended"
  | not open = Just "the texture pipeline is stopping"
  | otherwise = Nothing

-- The endpoint --------------------------------------------------------------------------------------

-- | The endpoint a grant names. It classifies the request from the inventory, answers one that fails
-- without a worker at once, and otherwise hands the job to the pipeline. Never opens a file or waits.
textureEndpoint ∷ TextureService → RequestEndpoint
textureEndpoint service =
  RequestEndpoint
    { endpointName = textureEndpointName
    , endpointResult = textureResultSchema
    , endpointSubmit = submit'
    }
  where
    submit' ∷ Submission → IO ProviderWork
    submit' submission = case submissionArguments submission of
      [VInteger token] | token >= 0 → submitJob (servicePipeline service) (fromIntegral token) (completeRequest (submissionCompletion submission))
      other → throwIO (TextureDefect (Text.pack ("the texture endpoint was handed arguments it does not take: " <> show (length other) <> " arguments")))

-- Using and releasing -------------------------------------------------------------------------------

-- | A live texture, as a scene's publication borrows it: the backend's registration identity and the
-- source dimensions.
data TextureView = TextureView
  { viewIdentity ∷ !Word64
  , viewWidth ∷ !Word32
  , viewHeight ∷ !Word32
  }
  deriving (Eq, Show)

-- | Borrow a live texture for the duration of the action. Refused, before the action, when the lease
-- has ended (released or retired), when it is another instance's and when it holds another type: the
-- boundary the later scene slices validate a texture through. A texture released after a scene
-- adopted it stays valid for that scene, which the backend holds until it proves otherwise.
withTexture ∷ HasCallStack ⇒ Leases → Word64 → (TextureView → IO r) -> IO r
withTexture leases key use = withLease leases key $ \resource →
  use (TextureView (textureIdentity (resourceTexture resource)) (resourceWidth resource) (resourceHeight resource))

-- | What an explicit release answered, in the words the later binding uses.
data TextureRelease
  = -- | The first release, and the texture is retired: @done@.
    TextureReleased
  | -- | The lease is revoked and the backend's retirement is pending, for a first or repeated release:
    -- @retiring@. Asking again restarts nothing.
    TextureRetiring
  | -- | A repeated release after an earlier one actually retired: @already_released@.
    TextureAlreadyReleased
  deriving (Eq, Show)

-- | The word the facade hands a script for a release.
releaseWord ∷ TextureRelease → Text
releaseWord = \case
  TextureReleased → "done"
  TextureRetiring → "retiring"
  TextureAlreadyReleased → "already_released"

-- | Release a texture before its instance ends. Revokes the instance's authority for new scenes
-- immediately, requests the backend's release once and never waits for it. A release that failed raises
-- its failure, answers neither of the three, runs no native cleanup again and is the answer to every
-- later release. Refused when the lease is another instance's.
releaseTexture ∷ HasCallStack ⇒ Leases → Word64 → IO TextureRelease
releaseTexture leases key =
  releaseLease leases key <&> \case
    Released → TextureReleased
    Retiring → TextureRetiring
    AlreadyReleased → TextureAlreadyReleased

-- One UI instance's banks ----------------------------------------------------------------------------

-- | Stop taking requests for this owner (its instance is ending). Releases nothing: each texture is
-- released by its lease, and retires on the backend's evidence.
closeTextureOwner ∷ TextureOwner → IO ()
closeTextureOwner = atomically . closeOwner

-- | What one owner's banks hold.
data OwnerReading = OwnerReading
  { ownerSlotsHeld ∷ !Int
  , ownerNominalHeld ∷ !Word64
  }
  deriving (Eq, Show)

-- | An owner's banks, in one transaction.
ownerReading ∷ TextureOwner → STM OwnerReading
ownerReading owner = OwnerReading <$> ownerSlotsCharged owner <*> ownerBytesCharged owner
