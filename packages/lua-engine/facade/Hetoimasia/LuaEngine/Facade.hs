{-# LANGUAGE OverloadedStrings #-}

-- | The M1 Lua authoring surface for one VM (LFE-12): the facade an instance's hooks are handed, the
-- lexical-root @import@, the role clocks and cooperative waits, and bounded @print@ and @warn@, bound
-- over the content, data, module and request services that already exist.
--
-- = What a script sees
--
-- @init(self, api)@, @update(self, dt_seconds)@ and @shutdown(self, reason)@ are called as before; @api@
-- is the same table as @self.api@, fresh for each instance, and holds copied strings and the
-- service tables:
--
-- > api.role, api.content_id, api.instance_id   -- strings: "gameplay" | "presentation", the content identifier, an opaque session identity
-- > api.content.module(path [, {root=, tick_offset=}])         -- request, nil | nil, {code="busy", message=}
-- > api.content.data(path [, {root=, tick_offset=, optional=}])
-- > api.request.ready(r) / take(r) / wait(r) / cancel(r)
-- > api.time.tick() / tick_seconds() / seconds() / wait_ticks(n) / wait_seconds(s) / yield()
--
-- Every call is a dot call with exactly its declared arguments: a mistaken colon call, an extra or
-- missing argument (an explicit @nil@ counts as an argument), a value of the wrong type or a table
-- with the wrong keys is an ordinary Lua error, raised before any provider, file, reservation or
-- suspension, which @pcall@ can catch. Only @nil@ or an absent argument omits an optional one; @false@
-- is a value. Nothing is coerced and no authored metamethod runs. @import(path [, root_id])@, @print@
-- and @warn@ are globals, available to module evaluation and to every hook. An error's text begins with the
-- name of the engine binding that refused (@hetoimasia_engine.content_module: ...@): the reason is the
-- contract, the name is diagnostic.
--
-- == Who may call what, and when
--
-- * @content.module@ and @content.data@: in @init@ and in an update; refused at a module's top level and in
--   @shutdown@.
-- * @request.ready@, @take@ and @cancel@: in @init@, an update and @shutdown@; refused at a module's top level.
-- * @request.wait@ and @time.yield@: in an update only.
-- * @time.tick@ and @time.tick_seconds@: a gameplay instance's, in @init@, an update and @shutdown@.
-- * @time.seconds@: a presentation instance's, in @init@, an update and @shutdown@.
-- * @time.wait_ticks@: a gameplay instance's update. @time.wait_seconds@: a presentation instance's update.
--
-- Every call is refused at a module's top level, through a captured facade included; the clocks and the waits
-- are also refused to the other role.
--
-- A request is also refused (an ordinary error, never @busy@) when the session's admission is stopping or
-- closed. @tick_offset@ is gameplay's alone (an integer from 1; the default is 1) and a presentation instance
-- that names it, even as 1, is refused; @optional@ is data's alone. An update here is any serving segment,
-- including a callback.
--
-- == Content roots
--
-- @import(path [, root_id])@ resolves a path from a root: by default the root of the module whose code makes
-- the call (captured when the module was evaluated, so a shared helper keeps it whichever instance's hook runs
-- it); @content.module@ and @content.data@ default to the facade's own content identifier instead. A root
-- is an identifier of 1 to 64 characters of @[a-z][a-z0-9_-]*@ and must be enabled for the session (in M1,
-- only the game's) and held by it. @import@ called where it cannot wait raises @import: module_not_ready:
-- ROOT:PATH@ for an identity that was never asked for or has not finished, and starts no work; an argument
-- error is @import: REASON@.
--
-- = How a facade is bound to its instance
--
-- The functions of a facade are Lua closures over the instance's identity. Each one first asks the
-- engine to check that identity against the instance the host says is running, then does its work with
-- the caller's own arguments, so a facade passed through a shared export, or kept by a module and used
-- from its top level, grants nothing: its calls are refused as ordinary errors before any action.
-- Overwriting @api@, a field of it or @self.api@ changes only that Lua table: the engine's attribution,
-- the instance's captured hooks and every other instance's facade are not in it.
--
-- = What an assembly does
--
-- Make the pieces the facade borrows (the profile's request policy, the module coordinator, made with
-- 'inventoryResolver' as its resolver and one shared 'ModulePhase', and the data service), then 'newFacade'
-- inside the scopes that own them and inside 'withOutput'; 'installFacade' on the owner's configuration and
-- 'facadeInstanceConfig' on its instances' ('instanceOnSegment' is where the presentation clock is
-- sampled); grant 'facadeRequestEndpoints' to the owner's request service; and for each instance
-- 'declareInstance', which answers the facade source to put in the behavior's request, and 'forgetInstance'
-- once the instance has settled. The scopes nest as the owners need them: the output outside, then the
-- coordinator and the pool, then the owner, which is stopped first, so a shutdown hook that prints still
-- finds its sink. Nothing here is global: a second VM has a second facade, and a facade cannot be reached
-- from Lua.
module Hetoimasia.LuaEngine.Facade
  ( -- * The services a facade is injected with
    AdmissionState (..)
  , FacadeEndpoints (..)
  , EngineFailure (..)
  , OutputSink (..)
  , Stream (..)
  , Output
  , withOutput
  , OutputFailure (..)
  , writeAuthored
  , outputInFlight
  , awaitOutputIdle
  , outputFailure
  , InstanceIds
  , newInstanceIds
    -- * One VM's facade
  , FacadeSpec (..)
  , Facade
  , FacadeRefused (..)
  , newFacade
  , facadeRole
  , facadeLimits
  , minimumInstanceIdBytes
  , minimumPrintWarnBytes
  , minimumContextBytes
    -- * Instances
  , Declared (..)
  , DeclareRefused (..)
  , declareInstance
  , forgetInstance
    -- * Installing
  , installFacade
  , InstallRefused (..)
  , facadeInstanceConfig
  , facadeRequestEndpoints
  , facadeRefusedWait
  , facadeExportLimits
  , lexicalResolver
  , inventoryResolver
  , validRootId
  , segmentStarted
    -- * Spelled out
  , moduleHandleName
  , dataHandleName
  , engineNamespaceName
  , FacadeDefect (..)
  ) where

import Control.Concurrent.STM (atomically, newTVarIO, readTVar, writeTVar)
import Data.List (nub)
import Data.Maybe (listToMaybe)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.ByteString as ByteString
import Hetoimasia.Content.Inventory (Inventory, inventoryIdentityLimits, inventoryLimitsOf)
import Hetoimasia.Foundation.Time (Duration)
import Hetoimasia.LuaEngine.Behavior (exportLimits)
import Hetoimasia.LuaEngine.Data (DataService, dataEndpoint)
import Hetoimasia.LuaEngine.Facade.Bindings
  ( callingIn
  , failEngine
  , minimumContextBytes
  , minimumInstanceIdBytes
  , minimumPrintWarnBytes
  , warnPrefix
  )
import Hetoimasia.LuaEngine.Facade.Caller
  ( BindOutcome (..)
  , DeclareOutcome (..)
  , bindRecord
  , checkFacade
  , declareRecord
  , forgetRecord
  , newRegistry
  )
import Hetoimasia.LuaEngine.Facade.Content (contentBindings, dataHandleName, lexicalResolver, moduleHandleName, validRootId)
import Hetoimasia.LuaEngine.Facade.Output
import Hetoimasia.LuaEngine.Facade.Request (requestBindings)
import Hetoimasia.LuaEngine.Facade.Source (builderIdentity, builderSource, engineChunk, engineChunkName)
import Hetoimasia.LuaEngine.Facade.Time (forgetSamples, segmentStarted, timeBindings)
import Hetoimasia.LuaEngine.Facade.Types
import Hetoimasia.LuaEngine.Manifest (Role (..))
import Hetoimasia.LuaEngine.Modules (Coordinator, ImportResolver, coordinatorEndpoint)
import Hetoimasia.LuaEngine.Profile
  ( ByteLimit (CopiedValueBytes, InstanceIdBytes, MessageBytes, PrintWarnBytes)
  , Bytes (Bytes)
  , Count (Count)
  , CountLimit (CopiedValueDepth, CopiedValueElements, InstancesPerVm, LuaIntegerMaximum)
  , Profile
  , bytesLimit
  , countLimit
  )
import Hetoimasia.LuaEngine.Request (M1Requests, m1HandleType, m1Profile)
import Hetoimasia.Scripting.Lua.Admission (callerInstance)
import Hetoimasia.Scripting.Lua.Instance (BehaviorFacade (FacadeBuilder), InstanceConfig (instanceOnSegment), instanceLocal)
import Hetoimasia.Scripting.Lua.Output (authoredLinesWith)
import Hetoimasia.Scripting.Lua.Owner
  ( ExportLimits (exportMaxIdentities)
  , ModulePhase
  , VmConfig (..)
  )
import Hetoimasia.Scripting.Lua.Provider (RequestEndpoint)
import Hetoimasia.Scripting.Lua.Scheduled (WaitRefusal)
import Hetoimasia.Scripting.Lua.Registration
  ( Binding
  , CapabilityType
  , Namespace
  , OwnerContexts
  , RegistrationRefusal
  , asynchronousNativeRequestIn
  , namespace
  , namespaceName
  , registration
  , withArgumentCheck
  )
import Hetoimasia.Scripting.Lua.Value (LimitsRefusal, Schema (SBytes, SText), Value (VBytes, VRecord, VText), ValueLimits, valueLimits)

-- | What one VM's facade is made from.
data FacadeSpec = FacadeSpec
  { fsRole ∷ !Role
  -- ^ The VM's role. A gameplay facade needs the tick duration.
  , fsRequests ∷ !M1Requests
  -- ^ The request policy, which carries the validated profile every number here is read from.
  , fsCoordinator ∷ !Coordinator
  -- ^ The VM's module coordinator, whose loader plan the owner is configured with.
  , fsData ∷ !DataService
  -- ^ The VM's data service.
  , fsInventory ∷ !Inventory
  -- ^ The session's inventory: the root the session holds content for, and the identity limits.
  , fsOutput ∷ !Output
  -- ^ The session's authored output, shared by every VM.
  , fsEndpoints ∷ !FacadeEndpoints
  , fsPhase ∷ !ModulePhase
  -- ^ The phase flag the coordinator's loader sets while a module's top level runs: the one the
  -- coordinator was made with.
  , fsRoots ∷ ![Text]
  -- ^ The enabled content roots. In M1 this is the game's root alone.
  , fsIds ∷ !InstanceIds
  -- ^ The session's source of instance identities.
  , fsTickDuration ∷ !(Maybe Duration)
  -- ^ A gameplay VM's fixed tick duration, as the manifest gave it.
  }

-- | Why a facade could not be made.
data FacadeRefused
  = -- | A profile value that does not fit the machine integer it is held in.
    FacadeLimitNotRepresentable !Text
  | -- | A gameplay facade without the tick duration.
    GameplayNeedsTickDuration
  | -- | No enabled root, or one that is not an identifier.
    RootsRefused ![Text]
  | -- | A bound of the profile that is below what the facade's own formatting needs: the name of the
    -- limit, the value the profile gave and the least it may be ('minimumInstanceIdBytes',
    -- 'minimumPrintWarnBytes', 'minimumContextBytes').
    LimitBelowFormatting !Text !Int !Int
  deriving (Eq, Show)

-- | Make one VM's facade. It holds nothing that needs releasing: what it borrows belongs to the scopes
-- the assembly made it inside.
newFacade ∷ FacadeSpec → IO (Either FacadeRefused Facade)
newFacade spec = case limits of
  Left refused → pure (Left refused)
  Right found
    | fsRole spec == Gameplay && fsTickDuration spec == Nothing → pure (Left GameplayNeedsTickDuration)
    | null (fsRoots spec) || not (all validRootId (fsRoots spec)) → pure (Left (RootsRefused (fsRoots spec)))
    | Just refused ← belowFormatting found → pure (Left refused)
    | otherwise → do
        registry ← newRegistry
        origin ← newTVarIO Nothing
        samples ← newTVarIO Map.empty
        pure . Right $
          Facade
            { fcRole = fsRole spec
            , fcProfile = profile
            , fcLimits = found
            , fcRequests = fsRequests spec
            , fcCoordinator = fsCoordinator spec
            , fcData = fsData spec
            , fcInventory = fsInventory spec
            , fcOutput = fsOutput spec
            , fcEndpoints = fsEndpoints spec
            , fcPhase = fsPhase spec
            , fcRoots = fsRoots spec
            , fcIds = fsIds spec
            , fcTickDuration = fsTickDuration spec
            , fcRegistry = registry
            , fcTime = TimeState origin samples
            }
  where
    profile = m1Profile (fsRequests spec)
    limits = do
      Bytes idBytes ← Right (bytesLimit profile InstanceIdBytes)
      Bytes printBytes ← Right (bytesLimit profile PrintWarnBytes)
      Bytes messageBytes ← Right (bytesLimit profile MessageBytes)
      Count instances ← Right (countLimit profile InstancesPerVm)
      Count maximum' ← Right (countLimit profile LuaIntegerMaximum)
      FacadeLimits
        <$> machine "InstanceIdBytes" idBytes
        <*> machine "InstancesPerVm" instances
        <*> machine "PrintWarnBytes" printBytes
        <*> Right maximum'
        <*> machine "MessageBytes" messageBytes
    machine name value
      | value <= fromIntegral (maxBound ∷ Int) = Right (fromIntegral value)
      | otherwise = Left (FacadeLimitNotRepresentable name)
    -- The context record is also four elements and one level deep; the profile's own relations keep the element
    -- bound at 12 or more (a scene of one sprite) and every bound positive, so neither can be below it.
    -- Every bound the facade formats with is checked against the least its own format needs, in this order,
    -- and the first that is below it is the refusal. A profile below one could not keep the format the facade
    -- promises (an identity that fits, a warning that names its writer on every line, a context the builder
    -- can be handed), so no facade is made over it.
    belowFormatting found =
      listToMaybe
        [ LimitBelowFormatting name given least
        | (name, given, least) ←
            [ ("InstanceIdBytes", limitInstanceIdBytes found, minimumInstanceIdBytes)
            , ("PrintWarnBytes", limitPrintBytes found, minimumPrintWarnBytes (limitInstanceIdBytes found))
            , ("CopiedValueBytes", copiedBytes, minimumContextBytes (limitInstanceIdBytes found))
            ]
        , given < least
        ]
    copiedBytes = let Bytes n = bytesLimit profile CopiedValueBytes in fromIntegral (min n (fromIntegral (maxBound ∷ Int)))

-- | The VM's role.
facadeRole ∷ Facade → Role
facadeRole = fcRole

-- | The numbers the facade works to.
facadeLimits ∷ Facade → FacadeLimits
facadeLimits = fcLimits

-- | The session's source of instance identities.
newInstanceIds ∷ IO InstanceIds
newInstanceIds = InstanceIds <$> newTVarIO 0

-- Instances ----------------------------------------------------------------------------------------

-- | An instance declared to a facade: its identity, and the facade source for the behavior's request
-- (the builder, handed the copied role, content identifier and instance identity).
data Declared = Declared
  { declaredId ∷ !Text
  , declaredFacade ∷ !BehaviorFacade
  }

-- | Why an instance could not be declared.
data DeclareRefused
  = -- | The content identifier is not an enabled root identifier.
    ContentRefused !Text
  | -- | The facade already holds as many instances as one VM may have.
    TooManyInstances !Int
  | -- | The session's identities are exhausted. They are never reused or wrapped.
    IdsExhausted
  | -- | The identity does not fit the profile's bound. Never produced by the engine's own ids.
    IdTooLong !Int
  deriving (Eq, Show)

-- | Declare an instance of this facade's role and the content, before it is admitted. The identity is
-- the engine's, never a script's.
declareInstance ∷ Facade → Text → IO (Either DeclareRefused Declared)
declareInstance facade content
  | not (validRootId content) || content `notElem` fcRoots facade = pure (Left (ContentRefused content))
  | otherwise = do
      let InstanceIds counter = fcIds facade
      issued ← atomically $ do
        next ← readTVar counter
        if next == maxBound then pure Nothing else Just next <$ writeTVar counter (next + 1)
      case issued of
        Nothing → pure (Left IdsExhausted)
        Just number → do
          let identity = "inst-" <> Text.pack (show (number + 1))
              size = ByteString.length (Text.encodeUtf8 identity)
          if size > limitInstanceIdBytes (fcLimits facade)
            then pure (Left (IdTooLong size))
            else do
              outcome ← atomically (declareRecord (fcLimits facade) (fcRegistry facade) (InstanceRecord identity (fcRole facade) content Nothing))
              pure $ case outcome of
                DeclareAccepted → Right (Declared identity (builderFacade identity))
                DeclareDuplicate → Left IdsExhausted
                DeclareFull bound → Left (TooManyInstances bound)
  where
    builderFacade identity =
      FacadeBuilder
        builderIdentity
        "build"
        (VRecord [("role", VText (roleWord (fcRole facade))), ("content_id", VText content), ("instance_id", VText identity)])

roleWord ∷ Role → Text
roleWord = \case
  Gameplay → "gameplay"
  Presentation → "presentation"

-- | Forget an instance: its identity and the host instance it was bound to, and its sample. For an
-- instance that was never admitted, or has ended and been observed.
forgetInstance ∷ Facade → Text → IO ()
forgetInstance facade identity = do
  number ← atomically $ do
    held ← Map.lookup identity <$> readTVar (registryRecords (fcRegistry facade))
    forgetRecord (fcRegistry facade) identity
    pure (held >>= recordNumber)
  mapM_ (forgetSamples facade) number

-- Installing ---------------------------------------------------------------------------------------

-- | Why a configuration could not be made.
data InstallRefused
  = -- | The bindings could not be registered.
    RegistrationRefused !RegistrationRefusal
  | -- | The profile's copied-value ceilings are not limits the host accepts.
    ValueLimitsRefused !LimitsRefusal
  deriving (Eq, Show)

-- | The ceilings a VM's export modules are held to when it carries a facade: the profile's, and one
-- identity more, for the facade's own builder module, which is not authored content and must not take
-- a place from the 256 the profile gives authored modules (the coordinator enforces those).
facadeExportLimits ∷ Facade → ExportLimits
facadeExportLimits facade = limits {exportMaxIdentities = exportMaxIdentities limits + 1}
  where
    limits = exportLimits (fcProfile facade)

-- | A VM configuration that carries the facade: the registration of its bindings (with these other
-- namespaces and capability types of the application's, replacing any it had), the policy naming them,
-- the initial chunk that rebinds @print@ and @warn@ and defines the builder, the builder's export
-- module, and the export ceilings. The owner's other settings are the caller's.
installFacade ∷ Facade → [Namespace] → [CapabilityType] → VmConfig → Either InstallRefused VmConfig
installFacade facade others types config = do
  registered ← either (Left . RegistrationRefused) Right (registration (handleTypes <> types) (facadeNamespace facade : others))
  limits ← either (Left . ValueLimitsRefused) Right (copiedValueLimits (fcProfile facade))
  Right
    config
      { vmRegistration = registered
      , vmPolicy = nub (vmPolicy config <> [engineNamespaceName] <> [nameOf found | found ← others])
      , vmInitialChunks = vmInitialChunks config <> [(engineChunkName, engineChunk (limitPrintBytes (fcLimits facade)))]
      , vmExports = vmExports config <> [builderSource]
      , vmExportLimits = facadeExportLimits facade
      , vmValueLimits = limits
      }
  where
    handleTypes = [m1HandleType (fcRequests facade) moduleHandleName, m1HandleType (fcRequests facade) dataHandleName]
    nameOf = namespaceName

-- | The copied-value ceilings of a profile as the limits on everything that crosses for an owner: 16 MiB
-- encoded, depth 8 and 65,536 elements under the fixed profile. A script's arguments and a service's
-- results are read and written under them.
copiedValueLimits ∷ Profile → Either LimitsRefusal ValueLimits
copiedValueLimits profile = valueLimits (fromIntegral bytes) (fromIntegral depth) (fromIntegral elements)
  where
    Bytes bytes = bytesLimit profile CopiedValueBytes
    Count depth = countLimit profile CopiedValueDepth
    Count elements = countLimit profile CopiedValueElements

-- | The namespace of the facade's bindings: hidden, read once by the initial chunk and removed.
facadeNamespace ∷ Facade → Namespace
facadeNamespace facade =
  namespace
    engineNamespaceName
    ( outputBindings facade
        <> callerBindings facade
        <> contentBindings facade
        <> requestBindings facade
        <> timeBindings facade
    )

-- | A configuration of a VM's instances that tells the facade whenever a hook begins or resumes, after
-- whatever the configuration already did.
facadeInstanceConfig ∷ Facade → InstanceConfig → InstanceConfig
facadeInstanceConfig facade config =
  config {instanceOnSegment = \found → segmentStarted facade found >> instanceOnSegment config found}

-- | What the application's 'scheduledRefusedWait' does for a facade: the scheduler refused a wait that the
-- facade's own binding had checked and prepared, which can only be because the clock moved between the
-- check and the placement (a deadline that was representable at the first reading was not at the
-- second). That is the engine's fact and not the script's: it is reported through the injected failure
-- boundary and raised, which is a failure of the host and ends the owner, as a tick no Lua integer
-- holds does. Without it the generic scheduler would fail the task and the default policy would isolate
-- an instance for a refusal no script caused.
facadeRefusedWait ∷ Facade → WaitRefusal → IO ()
facadeRefusedWait facade refusal =
  failEngine facade ("the scheduler refused a wait the facade had checked: " <> Text.pack (show refusal))

-- | The request endpoints to grant the owner: the module coordinator's and the data service's.
facadeRequestEndpoints ∷ Facade → [RequestEndpoint]
facadeRequestEndpoints facade = [coordinatorEndpoint (fcCoordinator facade), dataEndpoint (fcData facade)]

-- | The lexical-root resolver over the session's inventory, for the coordinator's specification.
inventoryResolver ∷ Inventory → [Text] → ImportResolver
inventoryResolver inventory = lexicalResolver (inventoryIdentityLimits (inventoryLimitsOf inventory))

-- The facade's own bindings -----------------------------------------------------------------------------

-- | @out@ and @err@: @print@ and @warn@'s writers.
outputBindings ∷ Facade → [Binding]
outputBindings facade =
  [ asynchronousNativeRequestIn "out" [SBytes] [] $ \_ values → do
      case values of
        [VBytes bytes] → writeAuthored (fcOutput facade) Stdout (authoredLinesWith limit "" bytes)
        _ → pure ()
      pure []
  , asynchronousNativeRequestIn "err" [SBytes] [] $ \context values → do
      calling ← callingIn facade context
      case values of
        [VBytes bytes] → writeAuthored (fcOutput facade) Stderr (authoredLinesWith limit (warnPrefix facade calling) bytes)
        _ → pure ()
      pure []
  ]
  where
    limit = limitPrintBytes (fcLimits facade)

-- | @bind@ and @check@: how a facade is tied to the instance the host is running when its builder runs,
-- and the check each of its calls makes.
callerBindings ∷ Facade → [Binding]
callerBindings facade =
  [ asynchronousNativeRequestIn "bind" [SText] [] $ \context values → case values of
      [VText identity] →
        callerInstance context >>= \case
          Nothing → failEngine facade "a facade was built with no instance running"
          Just found →
            atomically (bindRecord (fcRegistry facade) identity (instanceLocal found)) >>= \case
              Bound → pure []
              other → failEngine facade ("a facade could not be bound to its instance: " <> Text.pack (show other))
      _ → failEngine facade "a facade was built without an identity"
  , withArgumentCheck check (asynchronousNativeRequestIn "check" [SText] [] (\_ _ → pure []))
  ]
  where
    check ∷ OwnerContexts → [Value] → IO (Maybe Text)
    check owner = \case
      [VText identity] → checkFacade facade owner identity
      _ → pure (Just "a facade is checked with its identity")
