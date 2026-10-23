{-# LANGUAGE OverloadedStrings #-}

-- | Who is calling a binding, as the engine knows it, and the registry of the instances a facade
-- belongs to.
--
-- = Authority
--
-- A call's caller is never a script's claim. The host tells a binding which instance's code the owner is
-- running ('callerInstance'), and whether a module's top level is ('modulePhaseActive'); the registry says
-- which of the facade's instances that is, and what it is (role, content, identity). A facade's closure
-- holds its instance's opaque identity and gives it to 'checkFacade' before every call, so a facade
-- reached from another instance's hook, or from a module's top level, is refused as an ordinary Lua
-- error before any action. The identity is not a capability and not a secret: it is exposed as
-- @instance_id@; what makes a call the instance's own is that the host says the instance is running.
module Hetoimasia.LuaEngine.Facade.Caller
  ( -- * The registry
    newRegistry
  , declareRecord
  , bindRecord
  , forgetRecord
  , BindOutcome (..)
  , DeclareOutcome (..)
  , recordByNumber
  , recordById
    -- * Who is calling
  , Calling (..)
  , Caller (..)
  , whoIsCalling
  , refusalOf
  , requireInstance
  , checkFacade
  , Stage (..)
  , stageOf
  ) where

import Control.Concurrent.STM (STM, atomically, newTVarIO, readTVar, writeTVar)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.LuaEngine.Facade.Types
  ( Facade (..)
  , FacadeLimits (..)
  , InstanceRecord (..)
  , Registry (..)
  )
import Hetoimasia.Scripting.Lua.Admission (CallerPhase (..), callerInstance, callerPhase)
import Hetoimasia.Scripting.Lua.Instance (InstanceId (instanceLocal))
import Hetoimasia.Scripting.Lua.Owner (ImportContext (importerLabel), modulePhaseActive, modulePhaseModule)
import Hetoimasia.Scripting.Lua.Registration (OwnerContexts (contextRequests))

-- The registry ---------------------------------------------------------------------------------------

-- | An empty registry.
newRegistry ∷ IO Registry
newRegistry = Registry <$> newTVarIO Map.empty <*> newTVarIO Map.empty

-- | What declaring an instance came to.
data DeclareOutcome
  = DeclareAccepted
  | -- | The identity is already declared.
    DeclareDuplicate
  | -- | The facade already holds as many instances as the profile lets one VM have.
    DeclareFull !Int
  deriving (Eq, Show)

-- | Declare an instance: its identity, role and content, bound to no host instance yet.
declareRecord ∷ FacadeLimits → Registry → InstanceRecord → STM DeclareOutcome
declareRecord limits registry record = do
  held ← readTVar (registryRecords registry)
  if Map.member (recordId record) held
    then pure DeclareDuplicate
    else
      if Map.size held >= limitInstances limits
        then pure (DeclareFull (limitInstances limits))
        else DeclareAccepted <$ writeTVar (registryRecords registry) (Map.insert (recordId record) record held)

-- | What binding an instance's identity to the host's instance came to.
data BindOutcome
  = Bound
  | -- | No such identity was declared to this facade.
    BindUnknown
  | -- | The identity is already bound: a facade is built once for an instance.
    BindAlready
  | -- | The host instance already has an identity.
    BindNumberTaken
  deriving (Eq, Show)

-- | Bind a declared identity to the host's instance, once.
bindRecord ∷ Registry → Text → Word64 → STM BindOutcome
bindRecord registry identity number = do
  held ← readTVar (registryRecords registry)
  numbers ← readTVar (registryNumbers registry)
  case Map.lookup identity held of
    Nothing → pure BindUnknown
    Just record
      | isJust (recordNumber record) → pure BindAlready
      | Map.member number numbers → pure BindNumberTaken
      | otherwise → do
          writeTVar (registryRecords registry) (Map.insert identity record {recordNumber = Just number} held)
          writeTVar (registryNumbers registry) (Map.insert number identity numbers)
          pure Bound

-- | Forget an identity and the host instance it was bound to. Nothing is left that names either.
forgetRecord ∷ Registry → Text → STM ()
forgetRecord registry identity = do
  held ← readTVar (registryRecords registry)
  case Map.lookup identity held of
    Nothing → pure ()
    Just record → do
      writeTVar (registryRecords registry) (Map.delete identity held)
      case recordNumber record of
        Nothing → pure ()
        Just number → readTVar (registryNumbers registry) >>= writeTVar (registryNumbers registry) . Map.delete number

-- | The record bound to a host instance.
recordByNumber ∷ Registry → Word64 → STM (Maybe InstanceRecord)
recordByNumber registry number = do
  numbers ← readTVar (registryNumbers registry)
  held ← readTVar (registryRecords registry)
  pure (Map.lookup number numbers >>= (`Map.lookup` held))

-- | The record of an identity.
recordById ∷ Registry → Text → STM (Maybe InstanceRecord)
recordById registry identity = Map.lookup identity <$> readTVar (registryRecords registry)

-- Who is calling --------------------------------------------------------------------------------------

-- | Where in its life an instance's hook is.
data Stage
  = -- | Its @init@.
    StageInitializing
  | -- | Serving: an update or a callback may wait.
    StageServing
  | -- | Its @shutdown@, or after.
    StageEnding
  deriving (Eq, Show)

stageOf ∷ CallerPhase → Stage
stageOf = \case
  CallerInitializing → StageInitializing
  CallerServing → StageServing
  CallerEnding → StageEnding

-- | An instance of this facade, running a hook.
data Caller = Caller
  { callerRecord ∷ !InstanceRecord
  , callerNumber ∷ !Word64
  , callerStage ∷ !Stage
  }
  deriving (Eq, Show)

-- | Who is calling.
data Calling
  = -- | A module's top level, or the closing of one, is running: no instance, no authority. The
    -- label of the module, when the loader names one.
    InModule !(Maybe Text)
  | -- | An instance of this facade is running a hook.
    InInstance !Caller
  | -- | Nobody this facade knows: a task's segment, an instance of another facade, or no Lua of an
    -- instance.
    Nowhere
  deriving (Eq, Show)

-- | Who is calling a binding of this owner. A module's top level is checked first and wins: the phase
-- belongs to the module whatever the hook that started the load was.
whoIsCalling ∷ Facade → OwnerContexts → IO Calling
whoIsCalling facade owner = do
  inModule ← modulePhaseActive (fcPhase facade)
  if inModule
    then InModule . fmap importerLabel <$> modulePhaseModule (fcPhase facade)
    else case contextRequests owner of
      Nothing → pure Nowhere
      Just context →
        callerInstance context >>= \case
          Nothing → pure Nowhere
          Just instanceId → do
            known ← atomically (recordByNumber (fcRegistry facade) (instanceLocal instanceId))
            case known of
              Nothing → pure Nowhere
              Just record → do
                phase ← callerPhase context
                pure $ case phase of
                  Nothing → Nowhere
                  Just found → InInstance (Caller record (instanceLocal instanceId) (stageOf found))

-- | Why a call by this caller is refused outright, if it is: not an instance of this facade.
refusalOf ∷ Calling → Maybe Text
refusalOf = \case
  InInstance _ → Nothing
  InModule _ → Just "services are not available while a module is evaluated"
  Nowhere → Just "services are available only to an instance's hooks"

-- | The caller if it is an instance, or the refusal.
requireInstance ∷ Calling → Either Text Caller
requireInstance = \case
  InInstance caller → Right caller
  other → Left (maybe "services are available only to an instance's hooks" id (refusalOf other))

-- | The check a facade's closure makes before every call, with its instance's identity: the caller must
-- be the instance the facade was built for. A facade of another instance, of another facade, or reached
-- from a module's top level is refused.
checkFacade ∷ Facade → OwnerContexts → Text → IO (Maybe Text)
checkFacade facade owner identity = do
  calling ← whoIsCalling facade owner
  pure $ case calling of
    InInstance caller
      | recordId (callerRecord caller) == identity → Nothing
      | otherwise → Just "this facade belongs to another instance"
    other → refusalOf other
