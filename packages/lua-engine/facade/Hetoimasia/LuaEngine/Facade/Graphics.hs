{-# LANGUAGE OverloadedStrings #-}

-- | @api.content.texture@, @api.window.open@, @api.scene.publish@ and @api.texture.release@: the UI-only graphics
-- calls of the M1 facade (LFE-21), bound over the graphics operations a composition injects
-- ('GraphicsServices').
--
-- = What this module decides, and what it leaves to the providers
--
-- Everything a script can get wrong is decided here, before any provider is asked, as an ordinary Lua error: the
-- caller (an instance of this facade, never a module's top level and never another instance's captured facade), its
-- role (the presentation role alone), its phase (acquisition and publication are refused in @shutdown@), the
-- session's admission (a stopping or closed session takes no new work, and that is an error, never @busy@), then
-- the shape of the arguments, the root and the path. Only then are the injected checks asked for the provider's own
-- permanent facts (an ended owner, an occupied window slot, a title or size out of range). The host's arity, type and
-- table rules come first of all, with no authored metamethod run.
--
-- Release is the one call allowed in @shutdown@ and after a quit: it needs an instance of this facade and the
-- presentation role, and the host's special release path accepts a lease that has already ended.
--
-- Nothing here is a service locator: every operation is a field of the one facade's 'GraphicsServices', reached by
-- a closure built over that facade. The requests these calls return are read, taken, cancelled and waited for
-- through the common request operations ("Hetoimasia.LuaEngine.Facade.Request"), whose kinds this module adds.
module Hetoimasia.LuaEngine.Facade.Graphics
  ( graphicsBindings
  , graphicsHandleTypes
  ) where

import qualified Data.ByteString as ByteString
import Data.Int (Int64)
import Data.Text (Text)
import Hetoimasia.Content.Identity (ContentKey, parseReference)
import Hetoimasia.Content.Inventory (inventoryIdentityLimits, inventoryLimitsOf, inventoryRootKey)
import Hetoimasia.LuaEngine.Facade.Bindings
import Hetoimasia.LuaEngine.Facade.Caller (Caller (..), Stage (..), requireInstance, whoIsCalling)
import Hetoimasia.LuaEngine.Facade.Content (checkRoot, describeRefusal)
import Hetoimasia.LuaEngine.Facade.Types
import Hetoimasia.LuaEngine.Manifest (Role (..))
import Hetoimasia.LuaEngine.Request (m1HandleType, m1StartResults, m1StartSchemas)
import Hetoimasia.Scripting.Lua.Registration
  ( ArgumentCheck
  , Binding
  , CapabilityType
  , asynchronousNativeRequestIn
  , recoverableRefusals
  , refuseOrdinarily
  , releaseOperation
  , withArgumentCheck
  , withPrecondition
  )
import Hetoimasia.Scripting.Lua.Value (Schema (..), Value (..), capabilityKey)

-- | The request handle types this VM's graphics requests are returned under, for the facade's registration.
graphicsHandleTypes ∷ Facade → [CapabilityType]
graphicsHandleTypes facade =
  [ m1HandleType (fcRequests facade) graphicsTextureRequestType
  , m1HandleType (fcRequests facade) graphicsWindowRequestType
  ]

-- | The four bindings of the hidden namespace: @content_texture@, @window_open@, @scene_publish@ and
-- @texture_release@. The initial chunk wraps each in the facade's own closure.
graphicsBindings ∷ Facade → GraphicsServices → [Binding]
graphicsBindings facade services =
  [ withArgumentCheck textureCheck $
      asynchronousNativeRequestIn "content_texture" [SBytes, SOptional (SRecord textureOptions)] (m1StartSchemas graphicsTextureRequestType) textureAct
  , withArgumentCheck windowCheck $
      asynchronousNativeRequestIn "window_open" [SRecord windowFields] (m1StartSchemas graphicsWindowRequestType) windowAct
  , gsPublish services "scene_publish" (uiCheck "scene publication")
  , -- A release is allowed wherever an instance's finite hook runs, shutdown and after a quit included, so the
    -- session's admission is deliberately not read. It is a UI operation.
    withPrecondition (\owner → instanceRule owner (releaseRule)) $
      recoverableRefusals (releaseOperation "texture_release" graphicsTextureType [SText] releaseAct)
  ]
  where
    textureOptions = [("root", SOptional SText), ("optional", SOptional SBoolean)]
    windowFields = [("title", SBytes), ("width", SInteger), ("height", SInteger)]

    instanceRule owner rule = do
      calling ← whoIsCalling facade owner
      pure $ case requireInstance calling of
        Left why → refuseText' why
        Right caller → rule caller
    releaseRule caller
      | recordRole (callerRecord caller) /= Presentation = refuseText' "texture release is available to the presentation role only"
      | otherwise = Nothing
    refuseText' = Just . clipText 200

    -- The rule every acquisition and publication meets first: the presentation role, not shutdown, and a session
    -- that takes new work.
    uiCheck ∷ Text → ArgumentCheck
    uiCheck what owner _ = do
      calling ← whoIsCalling facade owner
      case requireInstance calling of
        Left why → pure (refuseText why)
        Right caller → gate what caller

    gate ∷ Text → Caller → IO (Maybe Text)
    gate what caller
      | recordRole (callerRecord caller) /= Presentation = pure (refuseText (what <> " is available to the presentation role only"))
      | callerStage caller == StageEnding = pure (refuseText (what <> " is not available in shutdown"))
      | otherwise =
          endpointAdmission (fcEndpoints facade) >>= \case
            AdmissionStopping → pure (refuseText "the session is stopping: no new graphics work starts")
            AdmissionClosed → pure (refuseText "the session is closed: no new graphics work starts")
            AdmissionOpen → pure Nothing

    identityOf caller = recordId (callerRecord caller)

    textureCheck ∷ ArgumentCheck
    textureCheck owner values = do
      calling ← whoIsCalling facade owner
      case requireInstance calling of
        Left why → pure (refuseText why)
        Right caller →
          gate "a texture request" caller >>= \case
            Just why → pure (Just why)
            Nothing → case textureTarget facade caller values of
              Left why → pure (refuseText why)
              Right (key, optional) → gsTextureCheck services (identityOf caller) key optional owner values

    textureAct context values = do
      calling ← callingIn facade context
      case requireInstance calling of
        Left why → failEngine facade ("a texture request was made with no instance running: " <> why)
        Right caller → case textureTarget facade caller values of
          Left why → failEngine facade ("a texture request was valid at its check and is not at its action: " <> why)
          Right (key, optional) →
            gsTextureStart services (identityOf caller) key optional context >>= \case
              GraphicsStarted started → pure (m1StartResults graphicsTextureRequestType started)
              GraphicsRefused why → refuseOrdinarily (clipText 200 why)

    windowCheck ∷ ArgumentCheck
    windowCheck owner values = do
      calling ← whoIsCalling facade owner
      case requireInstance calling of
        Left why → pure (refuseText why)
        Right caller →
          gate "a window request" caller >>= \case
            Just why → pure (Just why)
            Nothing → case windowTarget values of
              Nothing → pure (refuseText "a window needs a title, a width and a height")
              Just (title, width, height) → gsWindowCheck services (identityOf caller) title width height owner values

    windowAct context values = do
      calling ← callingIn facade context
      case requireInstance calling of
        Left why → failEngine facade ("a window request was made with no instance running: " <> why)
        Right caller → case windowTarget values of
          Nothing → failEngine facade "a window request was valid at its check and is not at its action"
          Just (title, width, height) →
            gsWindowStart services (identityOf caller) title width height context >>= \case
              GraphicsStarted started → pure (m1StartResults graphicsWindowRequestType started)
              GraphicsRefused why → refuseOrdinarily (clipText 200 why)

    releaseAct = \case
      [VCapability handle] → (\word → [VText word]) <$> gsRelease services (capabilityKey handle)
      _ → pure []

-- | The texture the copied arguments name for this caller, or why not: the checked root (defaulting to the
-- instance's content identifier) and path, and whether the request is optional. Pure: the check and the action read
-- it the same way. A field the script left out may arrive as nil, which is absent.
textureTarget ∷ Facade → Caller → [Value] → Either Text (ContentKey, Bool)
textureTarget facade caller = \case
  [VBytes path, options] → do
    fields ← case options of
      VNil → Right []
      VRecord found → Right [(name, value) | (name, value) ← found, value /= VNil]
      _ → Left "the options must be a table"
    optional ← case lookup "optional" fields of
      Nothing → Right False
      Just (VBoolean given) → Right given
      Just _ → Left "optional must be a boolean"
    root ← case lookup "root" fields of
      Nothing → Right (recordContent (callerRecord caller))
      Just (VText given) → Right given
      Just _ → Left "root must be text"
    checkRoot facade root
    key ← either (Left . describeRefusal) Right (parse path)
    Right (key, optional)
  _ → Left "a path and options are required"
  where
    inventory = fcInventory facade
    parse = parseReference (inventoryIdentityLimits (inventoryLimitsOf inventory)) (inventoryRootKey inventory)

-- | The window request's title, width and height, as the host read them. The values' ranges are the adapter's.
windowTarget ∷ [Value] → Maybe (ByteString.ByteString, Int64, Int64)
windowTarget = \case
  [VRecord fields]
    | Just (VBytes title) ← lookup "title" fields
    , Just (VInteger width) ← lookup "width" fields
    , Just (VInteger height) ← lookup "height" fields →
        Just (title, width, height)
  _ → Nothing
