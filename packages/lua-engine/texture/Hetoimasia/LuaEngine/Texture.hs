-- | The M1 texture pipeline (LFE-16): the endpoint that answers an asynchronous request for a usable,
-- instance-owned texture, the lanes, worker and reservations behind it, and the explicit release.
--
-- = What it is
--
-- A texture request is one operation that covers a verified read of an inventoried file, a static PNG
-- decode, an upload and a registration, and it succeeds only when the backend reports the upload
-- complete and the registration usable. The result carries the instance's opaque texture lease and the
-- source dimensions, ready for the later @{texture = HANDLE, width = INTEGER, height = INTEGER}@
-- ('textureValueSchema'). It does not promise a displayed frame, a window or a CPU image. What it may
-- additionally keep on the CPU, and only when the request's 'TexturePolicy' asked for it, is the one
-- shared binary-coverage plane and the checked normal-encoding fact of the loaded version (see
-- /Image kinds and the shared account/ below); never a decoded RGBA image.
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
-- | coverage bytes        | the session's one CPU account (128 MiB),  | the last CPU interest in the   |
-- | (@coverage="binary"@  | injected; worst case ceil (4,194,304 / 8) | loaded version (shrunk to the  |
-- | only)                 | plane bytes and the fixed metadata        | exact plane at the decode)     |
-- | texture slot          | 16 pending/live/retiring per UI instance  | texture proved retired         |
-- | nominal RGBA8 bytes   | 16 MiB reserved; 128 MiB per instance,    | texture proved retired         |
-- |                       | 256 MiB per session                       | (shrunk after the decode stage |
-- |                       |                                           | validated the dimensions)      |
-- | accepted-work record  | the pipeline's job capacity               | request taken, work retired    |
-- | queue slot            | the read pool's                           | request taken, read retired    |
-- +-----------------------+-------------------------------------------+--------------------------------+
--
-- A bank without room (the coverage account included) is the host's busy answer, with no file open, no
-- decode, no backend call and nothing reserved; the account is read only at that admission, so accepted work
-- is never turned busy by it later and no stage waits on it. A malformed address, a wrong role or phase, a closed owner or a stopping pipeline
-- are permanent and refused as ordinary Lua errors before any admission. The maximum 16 MiB output is
-- reserved without reading a header, so a small image can be refused busy while the banks hold large
-- reservations: that is accepted behavior. A file the inventory does not hold, or one over the
-- 32 MiB source limit, is accepted and fails as @not_found@ or @too_large@ without a worker.
--
-- The slot and the nominal bytes /transfer/ to the texture when the lease adopts it. They are not
-- returned when the request is taken, or when the pipeline's CPU buffers retire, or when Lua loses its
-- handle: they are returned when the backend proves the texture itself retired.
--
-- = Image kinds and the shared account
--
-- A request's 'TexturePolicy' chooses how the decoded level is read and what is checked before it is uploaded:
--
-- * @kind@ 'ColourKind' (the default): premultiplied sRGB, uploaded and registered as 'TexelRgba8Srgb'.
--   'DataKind': linear numeric data exactly as decoded (no gamma, no premultiplication, the RGB of a
--   transparent texel kept), uploaded and registered as 'TexelRgba8Linear' ('uploadFormat').
-- * @coverage = "binary"@: only alpha 0 and 255 are valid. One bit per texel is kept, as one immutable plane
--   shared by every reader of that loaded version.
-- * @normal_encoding@ 'UnitNormalRgbV1' (data only): every nontransparent texel's RGB in 1..255 and not
--   (128,128,128). Checked, never rewritten.
--
-- Both checks read the very bytes that will be uploaded, in the decode worker while the accounted decode
-- buffer exists, and a failure is the expected content failure @invalid_image@ with a bounded reason that names
-- the policy: nothing is uploaded, registered or published, and every charge returns once the request ends.
--
-- The plane is the /version/'s ("Hetoimasia.LuaEngine.Texture.Version"), kept alive by /interests/: the
-- pipeline's while it delivers, the lease's once a lease adopts the texture, and one for each consumer that
-- retains it through 'retainTexture'. Its bytes (plane and fixed metadata) are charged to the session's one
-- injected 'RenderAccount' by a reservation made at the request's atomic admission, shrunk at the decode and
-- passed to the version, and returned exactly once when its last interest ends (or, for a request that ends
-- without a version, by the host's credit release). That is the end of the CPU coverage and of nothing else:
-- the texture's slot and nominal bytes, and its GPU registration, are returned on the backend's evidence of
-- retirement, and neither event stands in for the other. A Lua release stops the lease from granting new
-- interests and leaves the ones already taken.
--
-- = Failures
--
-- An expected failure carries one of 'textureCodes' with the root and path: @not_found@,
-- @content_changed@, @io_error@, @too_large@ (a file or a decode over a limit, the workspace bank
-- included), @unsupported_format@ (not a PNG, or animated) and @invalid_image@ (a PNG that is not sound, a
-- nonbinary alpha under @coverage = "binary"@, or a texel that breaks the declared normal encoding). A required request's
-- failure latches at its eligible settlement whether or not it is read; an optional one is data.
-- A defect of the reader, the pool, the decode worker, the backend, the allocator or a release is a
-- provider defect: it fails the owner at its next boundary, required or optional alike, and is latched
-- as the pipeline's own failure ('awaitPipelineFailure'). It is never given a code and never busy.
--
-- = Independent loads
--
-- Every request has its own verified read, decode, upload and texture, even for the same path from the
-- same instance, and so its own loaded version and its own separately charged plane. There is no cache, no
-- coalescing of work in flight and no sharing between instances; only the pool, the decode worker, the lanes,
-- the device and the session's CPU account are shared. An instance may use one live
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
  , specMaxPixels
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

    -- * The shared CPU account
  , RenderAccount
  , newRenderAccount
  , m1RenderAccountBytes
  , accountLimit
  , accountCharged
  , accountReserve
  , accountRelease
  , AccountDefect (..)

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
  , TextureKind (..)
  , NormalEncoding (..)
  , normalEncodingName
  , parseNormalEncoding
  , TexturePolicy (..)
  , colourPolicy
  , texturePolicy
  , PolicyRefused (..)
  , policyRefusalText
  , TextureRequest (..)
  , textureAsk
  , TextureStart (..)
  , startTexture
  , textureArgumentCheck

    -- * Using and releasing
  , TextureView (..)
  , withTexture
  , withTextureOr

    -- * Retaining a version's facts
  , TextureRequirement (..)
  , noRequirement
  , RetainedTexture
  , retainedView
  , retainedVersion
  , retainedKind
  , retainedNormal
  , retainedCoverage
  , retainedWidth
  , retainedHeight
  , retainedInterests
  , retainTexture
  , releaseRetained
  , withRetainedTexture
  , TextureRelease (..)
  , releaseTexture
  , releaseWord
  ) where

import Control.Concurrent.STM (STM, atomically)
import Control.Exception (finally, mask, throwIO)
import Hetoimasia.Asset.Image.DataMap (CoveragePlane, NormalEncoding (..), normalEncodingName, parseNormalEncoding)
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
import Hetoimasia.LuaEngine.Texture.Account
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
import Hetoimasia.LuaEngine.Texture.Version
import Hetoimasia.Scripting.Lua.Admission (Necessity)
import Hetoimasia.Scripting.Lua.Lease
  ( Leases
  , Ownership (InstanceOwned)
  , ReleaseAnswer (..)
  , releaseLease
  , withLease
  , withLeaseOr
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
  , requestedPolicy ∷ !TexturePolicy
    -- ^ The image kind, binary coverage and normal encoding it asks for; 'colourPolicy' is the default
    -- every M1 request has.
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
  prepared ← prepareRequest pipeline owner (requestedKey request) (requestedPolicy request)
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

-- | 'withTexture' that hands the refusal to the caller as data instead of raising it: the same three
-- reasons (the lease has ended, it is another instance's, it holds another type), as bounded text, for
-- the binding that turns an expected refusal into an ordinary Lua error before its action. It decides and
-- borrows in one step on the calling thread. The scene preparation (LFE-19) is its client.
withTextureOr ∷ HasCallStack ⇒ Leases → Word64 → (Text → IO r) → (TextureView → IO r) → IO r
withTextureOr leases key refused use = withLeaseOr leases key refused $ \resource →
  use (TextureView (textureIdentity (resourceTexture resource)) (resourceWidth resource) (resourceHeight resource))

-- Retaining a version's facts ---------------------------------------------------------------------------

-- | What a consumer needs of the texture it retains. Anything less than this is a clear refusal, never a
-- partial grant.
data TextureRequirement = TextureRequirement
  { requireKind ∷ !(Maybe TextureKind)
    -- ^ The image kind the consumer needs, if it needs one.
  , requireCoverage ∷ !Bool
    -- ^ Binary coverage: the version must have been loaded with @coverage = "binary"@ and passed.
  , requireNormal ∷ !(Maybe NormalEncoding)
    -- ^ A checked normal encoding: the version must have been loaded with it and passed.
  }
  deriving (Eq, Show)

-- | A consumer that needs only the texture.
noRequirement ∷ TextureRequirement
noRequirement = TextureRequirement Nothing False Nothing

-- | A live texture together with the facts of the one loaded version it belongs to, and the CPU interest
-- that keeps those facts valid until 'releaseRetained'. The texture, the coverage plane and the checked
-- profile are paired here by the version that produced all three: a path, a recycled registration slot or a
-- reused handle generation never pairs an old plane with a new texture.
data RetainedTexture = RetainedTexture
  { retainedView ∷ !TextureView
  , retainedVersion ∷ !Word64
    -- ^ The version's identity, issued once by the pipeline.
  , retainedFacts ∷ !VersionFacts
  , retainedHold ∷ !Interest
  }

-- | The image kind of the retained version.
retainedKind ∷ RetainedTexture → TextureKind
retainedKind = factsKind . retainedFacts

-- | The normal encoding the pipeline checked before the upload, if one was asked for.
retainedNormal ∷ RetainedTexture → Maybe NormalEncoding
retainedNormal = factsNormal . retainedFacts

-- | The version's one shared coverage plane, if binary coverage was asked for and passed. The very value
-- every reader of the version shares.
retainedCoverage ∷ RetainedTexture → Maybe CoveragePlane
retainedCoverage = factsCoverage . retainedFacts

-- | How many CPU interests the retained version holds now (the lease's, every consumer's and this one):
-- a reading, for observation.
retainedInterests ∷ RetainedTexture → STM Int
retainedInterests = versionInterests . interestVersion . retainedHold

retainedWidth, retainedHeight ∷ RetainedTexture → Word32
retainedWidth = factsWidth . retainedFacts
retainedHeight = factsHeight . retainedFacts

-- | Retain the texture a lease names, with its version's facts, through the same protected-resource
-- boundary as 'withTextureOr': refused, as data and before anything is retained, when the lease has ended,
-- is another instance's or holds another type, and when the version lacks what the requirement needs
-- (missing or incompatible authority is a clear refusal), or no longer has a CPU interest to take.
--
-- The retained value holds an explicit CPU interest in its exact version. It survives the lease's release:
-- a Lua release prevents new authority from this boundary and leaves the interests already taken. It
-- releases nothing on the GPU side and is no evidence about it: registration, nominal charges and
-- retirement follow the backend's actual completion, whatever consumers hold. Call it with asynchronous
-- exceptions masked, or use 'withRetainedTexture', so that no exception can separate the interest from the
-- caller that must release it; 'releaseRetained' is idempotent.
retainTexture ∷ HasCallStack ⇒ Leases → Word64 → TextureRequirement → IO (Either Text RetainedTexture)
retainTexture leases key need = withLeaseOr leases key (pure . Left) $ \resource → do
  let version = resourceVersion resource
      facts = versionFacts version
      view = TextureView (textureIdentity (resourceTexture resource)) (resourceWidth resource) (resourceHeight resource)
  case unmet need facts of
    Just why → pure (Left why)
    Nothing →
      atomically (takeInterest version) <&> \case
        Nothing -> Left "the texture's version has no CPU interest left to take"
        Just interest -> Right (RetainedTexture view (versionId version) facts interest)

-- | Why a version does not meet a requirement, if it does not.
unmet ∷ TextureRequirement → VersionFacts → Maybe Text
unmet need facts
  | Just kind ← requireKind need, kind /= factsKind facts = Just ("the texture is not a " <> kindWord kind <> " texture")
  | requireCoverage need, Nothing ← factsCoverage facts = Just "the texture has no binary coverage: it was not loaded with coverage=\"binary\""
  | Just encoding ← requireNormal need, factsNormal facts /= Just encoding =
      Just ("the texture's texels were not validated as normal_encoding=" <> normalEncodingName encoding)
  | otherwise = Nothing
  where
    kindWord = \case
      ColourKind -> "colour"
      DataKind -> "data"

-- | End a retained texture's CPU interest. Idempotent.
releaseRetained ∷ RetainedTexture → IO ()
releaseRetained = atomically . dropInterest . retainedHold

-- | 'retainTexture' for the duration of an action: the interest is released when the action ends, however
-- it ends, and a refusal is handed to the caller as data before the action.
withRetainedTexture ∷ HasCallStack ⇒ Leases → Word64 → TextureRequirement → (Text → IO r) → (RetainedTexture → IO r) → IO r
withRetainedTexture leases key need refused use = mask $ \restore →
  retainTexture leases key need >>= \case
    Left why -> restore (refused why)
    Right retained -> restore (use retained) `finally` releaseRetained retained

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
