{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

-- | What the facade's bindings share: reading who is calling from the context the host hands an
-- action, refusing as an ordinary Lua error from a check, and raising an engine failure.
--
-- Every refusal here is a value a check returns, so it reaches the script as the ordinary Lua error
-- of an opted-in binding, before any action; an engine failure is an exception raised from an action,
-- which ends the owner whatever the script did with the stand-in error.
module Hetoimasia.LuaEngine.Facade.Bindings
  ( callingIn
  , instanceCheck
  , instanceArgumentCheck
  , failEngine
  , requireRole
  , refuseText
  , clipText
  , luaMaximum
  , warnPrefix
  ) where

import Control.Exception (throwIO)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Word (Word64)
import Hetoimasia.LuaEngine.Facade.Caller (Caller (callerRecord), Calling (..), requireInstance, whoIsCalling)
import Hetoimasia.LuaEngine.Facade.Types
  ( EngineFailure (EngineFailure)
  , Facade (..)
  , FacadeEndpoints (endpointFailure)
  , FacadeLimits (limitIntegerMaximum)
  , InstanceRecord (recordContent, recordId, recordRole)
  )
import Hetoimasia.LuaEngine.Manifest (Role (..))
import Hetoimasia.Scripting.Lua.Registration (ArgumentCheck, OwnerContexts (OwnerContexts), Precondition, RequestContext)
import Hetoimasia.Scripting.Lua.Value (Value)

-- | Who is calling, from the context the host hands an action: the same reading a check makes of the
-- owner's contexts.
callingIn ∷ Facade → RequestContext → IO Calling
callingIn facade context = whoIsCalling facade (OwnerContexts Nothing (Just context))

-- | A precondition: the caller must be an instance of the facade, and the rule must accept it.
instanceCheck ∷ Facade → (Caller → Maybe Text) → Precondition
instanceCheck facade rule owner = do
  calling ← whoIsCalling facade owner
  pure $ case requireInstance calling of
    Left why → Just why
    Right caller → rule caller

-- | An argument check of the same shape that also sees the copied arguments.
instanceArgumentCheck ∷ Facade → (Caller → [Value] → IO (Maybe Text)) → ArgumentCheck
instanceArgumentCheck facade rule owner values = do
  calling ← whoIsCalling facade owner
  case requireInstance calling of
    Left why → pure (Just why)
    Right caller → rule caller values

-- | Report an engine failure through the injected boundary, then raise it.
failEngine ∷ Facade → Text → IO a
failEngine facade why = do
  let failure = EngineFailure why
  endpointFailure (fcEndpoints facade) failure
  throwIO failure

-- | Refuse unless the caller's role is this one.
requireRole ∷ Role → Text → Caller → Maybe Text
requireRole wanted what caller
  | recordRole (callerRecord caller) == wanted = Nothing
  | otherwise = Just what

-- | A refusal reason, bounded to the bytes the host takes.
refuseText ∷ Text → Maybe Text
refuseText = Just . clipText 200

-- | Text cut to at most this many UTF-8 bytes, at a character.
clipText ∷ Int → Text → Text
clipText bound text
  | ByteString.length (Text.encodeUtf8 text) <= bound = text
  | otherwise = Text.pack (go (bound - 3) (Text.unpack text)) <> "..."
  where
    go room (character : rest)
      | width character <= room = character : go (room - width character) rest
    go _ _ = []
    width = ByteString.length . Text.encodeUtf8 . Text.singleton

-- | The largest Lua integer, as the profile's ceiling for ticks and counts.
luaMaximum ∷ Facade → Word64
luaMaximum = limitIntegerMaximum . fcLimits

-- | The prefix of every line of a @warn@ call: engine-made, never from a field a script can change. In a
-- hook it names the role, the content and the instance whose hook is running; while a module is
-- evaluated, the role and the module (a shared helper called in a hook is the executing instance's, and a
-- module invents no instance); otherwise just the role.
warnPrefix ∷ Facade → Calling → Text
warnPrefix facade = \case
  InInstance caller →
    let record = callerRecord caller
     in "lua warning role=" <> roleWord (recordRole record) <> " content=" <> recordContent record <> " instance=" <> recordId record <> ": "
  InModule label → "lua warning role=" <> roleWord (fcRole facade) <> " module=" <> maybe "?" (clipText 300) label <> ": "
  Nowhere → "lua warning role=" <> roleWord (fcRole facade) <> ": "
  where
    roleWord = \case
      Gameplay → "gameplay"
      Presentation → "presentation"
