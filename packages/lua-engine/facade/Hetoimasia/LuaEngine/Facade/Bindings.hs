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
  , minimumInstanceIdBytes
  , minimumPrintWarnBytes
  , minimumContextBytes
  , minimumCopiedValueBytes
  ) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeAsyncException, SomeException, fromException, rethrowIO, throwIO, tryWithContext)
import qualified Data.ByteString as ByteString
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Word (Word64)
import Hetoimasia.Foundation.Resource (composeCleanup)
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

-- | Report an engine failure through the injected boundary, then raise it. If the report itself raises, the
-- engine failure is still the primary failure and what the report raised is retained beside it as cleanup
-- evidence, so neither is lost; an asynchronous exception during the report is raised as it was.
failEngine ∷ Facade → Text → IO a
failEngine facade why = do
  let failure = EngineFailure why
  reported ← tryWithContext @SomeException (endpointFailure (fcEndpoints facade) failure)
  case reported of
    Right () → throwIO failure
    Left raised@(ExceptionWithContext _ cause)
      | isJust (fromException cause ∷ Maybe SomeAsyncException) → rethrowIO raised
      | otherwise → do
          primary ← tryWithContext @SomeException (throwIO failure)
          composed ← composeCleanup (either Just (const Nothing) primary) [("lua facade failure report", raised)]
          maybe (throwIO failure) rethrowIO composed

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
     in warnLead <> roleWord (recordRole record) <> contentLead <> recordContent record <> instanceLead <> recordId record <> warnEnd
  InModule label → warnLead <> roleWord (fcRole facade) <> moduleLead <> maybe "?" (clipText moduleLabelBytes) label <> warnEnd
  Nowhere → warnLead <> roleWord (fcRole facade) <> warnEnd

-- The pieces of a warning's prefix. 'warnPrefix' is built from them and so is 'minimumPrintWarnBytes', so that
-- what the format takes and what the bound is checked against cannot drift apart.
warnLead, contentLead, instanceLead, moduleLead, warnEnd ∷ Text
warnLead = "lua warning role="
contentLead = " content="
instanceLead = " instance="
moduleLead = " module="
warnEnd = ": "

-- | The most bytes of a module's label a prefix names; the rest is cut. The host already gives every module a
-- label of at most 128 bytes (its own bound on a label in a diagnostic), so the cut is a guard and not a loss.
moduleLabelBytes ∷ Int
moduleLabelBytes = 128

-- | The most bytes of a content identifier (a root identifier is 1 to 64 ASCII characters).
contentIdBytes ∷ Int
contentIdBytes = 64

roleWord ∷ Role → Text
roleWord = \case
  Gameplay → "gameplay"
  Presentation → "presentation"

bytesOfText ∷ Text → Int
bytesOfText = ByteString.length . Text.encodeUtf8

-- | The fewest bytes the profile's bound on an instance identity may be: the first identity the session issues,
-- @inst-1@. A later identity that does not fit is refused when it is declared, never written.
minimumInstanceIdBytes ∷ Int
minimumInstanceIdBytes = bytesOfText "inst-1"

-- | The fewest bytes the profile's bound on one @print@ or @warn@ may be, given its bound on an identity: the
-- longest prefix a warning takes (an instance's, or a module's with its label cut), the truncation marker and a line
-- end, so that a call that is cut can still say so on a prefixed line. A smaller bound is refused when the facade is
-- made, because the format it promises cannot be kept in it.
minimumPrintWarnBytes ∷ Int → Int
minimumPrintWarnBytes idBytes = max instanceForm moduleForm + bytesOfText "..." + 1
  where
    longestRole = maximum (map (bytesOfText . roleWord) [Gameplay, Presentation])
    instanceForm = bytesOfText warnLead + longestRole + bytesOfText contentLead + contentIdBytes + bytesOfText instanceLead + idBytes + bytesOfText warnEnd
    moduleForm = bytesOfText warnLead + longestRole + bytesOfText moduleLead + moduleLabelBytes + bytesOfText warnEnd

-- | The fewest bytes the profile's bound on a copied value may be, given its bounds on an identity and on one
-- @print@ or @warn@: the largest of everything the facade itself makes cross the value boundary, each with the
-- header the host adds to it. These are the text of one call to @out@ or @err@ (at most the print bound, and a text
-- argument has a five-byte header), an identity handed to @check@ or @bind@ (a text, the same header), and the
-- context record the builder is handed ('minimumContextBytes'). What a script passes in as the path or the
-- options of a content request is the script's, and a value too large to cross is an ordinary error there.
minimumCopiedValueBytes ∷ Int → Int → Int
minimumCopiedValueBytes idBytes printBytes = maximum [minimumContextBytes idBytes, printBytes + 5, idBytes + 5]

-- | The fewest bytes the profile's bound on a copied value may be for the builder's context alone, given its
-- bound on an identity: the bytes the host counts for the context record the builder is handed (a record of five bytes and, for each of @role@,
-- @content_id@ and @instance_id@, a key of five bytes and its name and a text of five bytes and its length).
minimumContextBytes ∷ Int → Int
minimumContextBytes idBytes =
  5
    + sum [5 + bytesOfText key | key <- ["role", "content_id", "instance_id"]]
    + sum [5 + n | n ← [longestRole, contentIdBytes, idBytes]]
  where
    longestRole = maximum (map (bytesOfText . roleWord) [Gameplay, Presentation])
