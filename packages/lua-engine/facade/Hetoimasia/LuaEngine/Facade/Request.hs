{-# LANGUAGE OverloadedStrings #-}

-- | The four operations on a request, @api.request.ready@, @take@, @cancel@ and @wait@ (P-72 section 4),
-- over the host's admission.
--
-- The operations are the common result adapter's ("Hetoimasia.LuaEngine.Request"): the same records,
-- the same refusals, the same ownership and cancellation races. What this module adds is only what a
-- facade is: each is refused as an ordinary Lua error unless an instance of this facade is running
-- (so none is available to a module's top level, whatever facade or handle it reached), and @wait@
-- is the update-only cooperative wait.
--
-- A request's value is a different thing for each content call (a module's export table by reference,
-- a data call's bytes), and a binding declares one result schema, so the operations exist once for each
-- kind of request handle. The facade's closures pick the pair by the kind of handle they were returned
-- for (see "Hetoimasia.LuaEngine.Facade.Source"); a handle of the other kind, or none, is refused by
-- the host's own handle check, as any wrong-kind handle is.
module Hetoimasia.LuaEngine.Facade.Request
  ( requestBindings
  ) where

import Data.Text (Text)
import Hetoimasia.LuaEngine.Facade.Bindings (instanceCheck)
import Hetoimasia.LuaEngine.Facade.Caller (Caller (..), Stage (..))
import Hetoimasia.LuaEngine.Facade.Content (dataHandleName, moduleHandleName)
import Hetoimasia.LuaEngine.Facade.Types
  ( Facade (fcGraphics)
  , graphicsTextureRequestType
  , graphicsTextureValueSchema
  , graphicsWindowRequestType
  , graphicsWindowValueSchema
  )
import Hetoimasia.LuaEngine.Request (m1TakeSchema, terminalRecord)
import Hetoimasia.Scripting.Lua.Admission
  ( CancelResult (..)
  , Taken (..)
  , cancelAdmitted
  , readyAdmitted
  , takeAdmitted
  )
import Hetoimasia.Scripting.Lua.Registration
  ( Binding
  , WaitKind (WaitSettlement)
  , asynchronousNativeRequestIn
  , recoverableRefusals
  , waitOperation
  , withPrecondition
  )
import Hetoimasia.Scripting.Lua.Value
  ( Schema (SBoolean, SBytes, SCapability, SExportTable, SText)
  , Value (VBoolean, VCapability, VRecord, VText)
  , capabilityKey
  )

-- | The operations for both kinds of request, named @ready_module@, @take_data@ and so on.
requestBindings ∷ Facade → [Binding]
requestBindings facade =
  operations facade "module" moduleHandleName SExportTable
    <> operations facade "data" dataHandleName SBytes
    <> maybe [] (const graphicsOperations) (fcGraphics facade)
  where
    -- A texture request's value and a window request's are different things again, so the injected graphics add
    -- their own pair of kinds (LFE-21); a facade with no graphics has no such operation and no such handle.
    graphicsOperations =
      operations facade "texture" graphicsTextureRequestType graphicsTextureValueSchema
        <> operations facade "window" graphicsWindowRequestType graphicsWindowValueSchema

operations ∷ Facade → Text → Text → Schema → [Binding]
operations facade kind handleType value =
  [ guarded ("ready_" <> kind) [SBoolean] ready
  , guarded ("take_" <> kind) [m1TakeSchema value] taken
  , guarded ("cancel_" <> kind) [SText] cancelled
  , withPrecondition (instanceCheck facade serving) (waitOperation ("wait_" <> kind) WaitSettlement [handle])
  ]
  where
    handle = SCapability handleType
    guarded name results action =
      withPrecondition (instanceCheck facade (const Nothing)) $
        recoverableRefusals (asynchronousNativeRequestIn name [handle] results action)
    ready context = \case
      [VCapability found] → (\settled → [VBoolean settled]) <$> readyAdmitted context (capabilityKey found)
      _ → pure []
    taken context = \case
      [VCapability found] →
        takeAdmitted context (capabilityKey found) >>= \case
          TakenPending → pure [VRecord [("status", VText "pending")]]
          Taken terminal → pure [terminalRecord terminal]
      _ → pure []
    cancelled context = \case
      [VCapability found] →
        cancelAdmitted context (capabilityKey found) >>= \case
          CancelWon → pure [VText "cancelled"]
          CancelAlreadySettled → pure [VText "already_settled"]
      _ → pure []
    serving caller = case callerStage caller of
      StageServing → Nothing
      StageInitializing → Just "wait is not available in init"
      StageEnding → Just "wait is not available in shutdown"
