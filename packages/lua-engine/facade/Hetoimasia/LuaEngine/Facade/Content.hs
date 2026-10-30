{-# LANGUAGE OverloadedStrings #-}

-- | @api.content.module@ and @api.content.data@: an instance's requests for content, and the
-- lexical-root @import@'s address resolver (P-72 section 3, D-60, D-61, D-74).
--
-- = Two defaults for a root
--
-- Two calls name content, and their default roots are different on purpose. @import(path [, root_id])@
-- belongs to a /module/: its default root is the one captured from the module whose code made the call,
-- even when a helper that module exported runs inside another instance's hook, and a path is always
-- from that root, never relative to the source directory or the caller. @api.content.module(path [,
-- options])@ and @api.content.data(path [, options])@ belong to an /instance/: their default root is
-- the facade's content identifier. An explicit root overrides either; a library that needs its own
-- root from an instance's request names it.
--
-- = What is validated, and when
--
-- Everything a script can get wrong is decided before an admission, a provider, a file or a
-- reservation, as an ordinary Lua error: the argument count and types (the host), the options table
-- (exactly the declared keys, no metatable, no coercion: the host), then the role and phase of the
-- caller, the session's admission state, the offset and the optional flag, the root, the path (the
-- content identity policy: UTF-8, per-segment NFC, exact case, literal @/@ separators, no empty,
-- dot, backslash, colon, control, absolute or URL form, 32 segments, 1,024 bytes and 255 per segment on
-- the supplied and normalized forms), and last the host's permanent refusals of the request (the
-- numeric ceiling, exhausted request numbers, the module cache). A root is an identifier of 1 to 64
-- ASCII characters of @[a-z][a-z0-9_-]*@; one that is not is an argument error. In M1 the only
-- enabled root is the game's, so any other, valid or not, is an argument error without a file being
-- looked at; a root the session enables but holds no content for is the same kind of error.
--
-- A stopping or closed session is an ordinary error and never busy: busy is a temporary capacity
-- answer with no handle, and a session that is stopping will not have room later.
module Hetoimasia.LuaEngine.Facade.Content
  ( contentBindings
  , lexicalResolver
  , validRootId
  , moduleHandleName
  , dataHandleName
  , checkRoot
  , describeRefusal
  ) where

import qualified Data.ByteString as ByteString
import Data.Char (isAsciiLower, isDigit)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Word (Word64)
import Hetoimasia.Content.Identity
  ( ContentKey
  , IdentityLimits
  , ReferenceRefusal (..)
  , parseReferenceText
  , rootKey
  , rootKeyBytes
  )
import Hetoimasia.Content.Inventory (inventoryRootKey)
import Hetoimasia.LuaEngine.Data (DataRequest (..), dataArgumentCheck, dataKey, startData)
import Hetoimasia.LuaEngine.Facade.Bindings
import Hetoimasia.LuaEngine.Facade.Caller (Caller (..), Stage (..), requireInstance, whoIsCalling)
import Hetoimasia.LuaEngine.Facade.Types
import Hetoimasia.LuaEngine.Manifest (Role (..))
import Hetoimasia.LuaEngine.Modules (ImportResolver, ModuleRequest (..), moduleArgumentCheck, moduleKey, startModule)
import Hetoimasia.LuaEngine.Request (m1StartResults, m1StartSchemas, offsetFromLua)
import Hetoimasia.Scripting.Lua.Admission (Necessity (..))
import Hetoimasia.Scripting.Lua.Owner (ExportIdentity (ExportIdentity), ImportContext (importerIdentity))
import Hetoimasia.Scripting.Lua.Registration
  ( ArgumentCheck
  , Binding
  , asynchronousNativeRequestIn
  , withArgumentCheck
  )
import Hetoimasia.Scripting.Lua.Value (Schema (..), Value (..))

-- | The request handle capability type of a module request.
moduleHandleName ∷ Text
moduleHandleName = "module_request"

-- | The request handle capability type of a data request.
dataHandleName ∷ Text
dataHandleName = "data_request"

-- | Whether this is a content root identifier: 1 to 64 ASCII characters of @[a-z][a-z0-9_-]*@.
validRootId ∷ Text → Bool
validRootId root = case Text.uncons root of
  Just (first, rest) →
    Text.length root <= 64
      && isAsciiLower first
      && Text.all (\c → isAsciiLower c || isDigit c || c == '_' || c == '-') rest
  Nothing → False

-- Content requests -----------------------------------------------------------------------------------

-- | Which of the two content calls.
data Kind = ModuleCall | DataCall
  deriving (Eq, Show)

-- | A content request as its copied arguments name it.
data Target = Target
  { targetKey ∷ !ContentKey
  , targetOffset ∷ !(Maybe Word64)
  , targetOptional ∷ !Bool
  }

-- | The two calls: @content_module@ and @content_data@ of the hidden namespace.
contentBindings ∷ Facade → [Binding]
contentBindings facade =
  [ withArgumentCheck (check ModuleCall) $
      asynchronousNativeRequestIn "content_module" [SBytes, SOptional (SRecord moduleOptions)] (m1StartSchemas moduleHandleName) (act ModuleCall)
  , withArgumentCheck (check DataCall) $
      asynchronousNativeRequestIn "content_data" [SBytes, SOptional (SRecord dataOptions)] (m1StartSchemas dataHandleName) (act DataCall)
  ]
  where
    moduleOptions = [("root", SOptional SText), ("tick_offset", SOptional SInteger)]
    dataOptions = moduleOptions <> [("optional", SOptional SBoolean)]

    check ∷ Kind → ArgumentCheck
    check kind owner values = do
      calling ← whoIsCalling facade owner
      case requireInstance calling of
        Left why → pure (refuseText why)
        Right caller → case callerStage caller of
          StageEnding → pure (refuseText "a content request is not available in shutdown")
          _ → do
            admitted ← endpointAdmission (fcEndpoints facade)
            case admitted of
              AdmissionStopping → pure (refuseText "the session is stopping: no request starts")
              AdmissionClosed → pure (refuseText "the session is closed: no request starts")
              AdmissionOpen → case target facade kind caller values of
                Left why → pure (refuseText why)
                Right found → case kind of
                  ModuleCall → moduleArgumentCheck (fcCoordinator facade) (const (moduleRequest found)) owner values
                  DataCall → dataArgumentCheck (fcData facade) (const (dataRequest found)) owner values

    act kind context values = do
      calling ← callingIn facade context
      case requireInstance calling of
        Left why → failEngine facade ("a content request was made with no instance running: " <> why)
        Right caller → case target facade kind caller values of
          Left why → failEngine facade ("a content request was valid at its check and is not at its action: " <> why)
          Right found → case kind of
            ModuleCall → m1StartResults moduleHandleName <$> startModule (fcCoordinator facade) (moduleRequest found) context (pure ())
            DataCall → m1StartResults dataHandleName <$> startData (fcData facade) (dataRequest found) context (pure ())

    moduleRequest found = ModuleRequest {requestedKey = targetKey found, requestedOffset = targetOffset found}
    dataRequest found =
      DataRequest
        { requestedKey = targetKey found
        , requestedNecessity = if targetOptional found then OptionalRequest else RequiredRequest
        , requestedOffset = targetOffset found
        }

-- | The request the copied arguments name for this caller, or why not. Pure: the check and the action
-- read it the same way.
target ∷ Facade → Kind → Caller → [Value] → Either Text Target
target facade kind caller = \case
  [VBytes path, options] → do
    -- A declared optional field the script left out may arrive as nil: it is absent, as nil always is.
    fields ← case options of
      VNil → Right []
      VRecord found → Right [(name, value) | (name, value) ← found, not (isNil value)]
      _ → Left "the options must be a table"
    offset ← case (role, lookup "tick_offset" fields) of
      (_, Nothing) → Right Nothing
      (Presentation, Just _) → Left "tick_offset is not accepted from a presentation instance"
      (Gameplay, Just (VInteger given))
        | given >= 1 → Right (Just (offsetFromLua given))
        | otherwise → Left "tick_offset must be an integer from 1"
      (Gameplay, Just _) → Left "tick_offset must be an integer"
    optional ← case (kind, lookup "optional" fields) of
      (DataCall, Just (VBoolean given)) → Right given
      (_, Just _) → Left "optional must be a boolean"
      (_, Nothing) → Right False
    root ← case lookup "root" fields of
      Nothing → Right (recordContent record)
      Just (VText given) → Right given
      Just _ → Left "root must be text"
    checkRoot facade root
    key ← either (Left . describeRefusal) Right (parse path)
    Right (Target key offset optional)
  _ → Left "a path and options are required"
  where
    record = callerRecord caller
    role = recordRole record
    parse = case kind of
      ModuleCall → moduleKey (fcCoordinator facade)
      DataCall → dataKey (fcData facade)

isNil ∷ Value → Bool
isNil = \case
  VNil → True
  _ → False

-- | A root a request may name: an identifier, enabled for the session, and one the session holds
-- content for. The last is what the single inventory of this session can honour.
checkRoot ∷ Facade → Text → Either Text ()
checkRoot facade root
  | not (validRootId root) = Left ("root " <> shown <> " is not a content identifier")
  | root `notElem` fcRoots facade = Left ("root " <> shown <> " is not enabled")
  | Text.encodeUtf8 root /= rootKeyBytes (inventoryRootKey (fcInventory facade)) = Left ("root " <> shown <> " has no content in this session")
  | otherwise = Right ()
  where
    shown = clipText 80 (Text.pack (show root))

-- | Why a path is not a content address, in words that cannot carry the path itself.
describeRefusal ∷ ReferenceRefusal → Text
describeRefusal refusal = "the path is not a content address: " <> clipText 120 (Text.pack (show (refusalReason refusal)))

-- The import resolver ----------------------------------------------------------------------------------

-- | How an @import@ becomes a content key: the lexical-root rule. The default root is the root of the
-- module whose code made the call (the context the host captured when it evaluated that module), an
-- explicit root overrides it, and either must be an enabled identifier. The path is from that root and
-- is checked by the content identity policy before anything else exists. A refusal is an ordinary Lua
-- argument error with no record, source interest or work.
lexicalResolver ∷ IdentityLimits → [Text] → ImportResolver
lexicalResolver limits enabled context path explicit = pure $ do
  root ← case explicit of
    Just given → Right given
    Nothing → maybe (Left "the importing module names no root") Right (rootOf (importerIdentity context))
  if not (validRootId root)
    then Left ("root " <> shown root <> " is not a content identifier")
    else Right ()
  if root `notElem` enabled
    then Left ("root " <> shown root <> " is not enabled")
    else Right ()
  checked ← either (const (Left ("root " <> shown root <> " is not a content identifier"))) Right (rootKey (Text.encodeUtf8 root))
  either (Left . describeRefusal) Right (parseReferenceText limits checked path)
  where
    shown = clipText 80 . Text.pack . show
    -- A module's identity is the length of its root, the root, then the path.
    rootOf (ExportIdentity bytes) = do
      (declared, rest) ← ByteString.uncons bytes
      let (root, _) = ByteString.splitAt (fromIntegral declared) rest
      if ByteString.length root == fromIntegral declared
        then either (const Nothing) Just (Text.decodeUtf8' root)
        else Nothing
