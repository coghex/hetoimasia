{-# LANGUAGE OverloadedStrings #-}

-- | What a module's failure is told as: the expected-failure code of P-72's vocabulary, a bounded
-- message, the content that failed and the import chain it was reached through.
--
-- A failure of a module is /data/: the loader keeps the first fault of an identity, stickily, and
-- this reads it. The code follows the cause, innermost first, because an importer fails with
-- 'DependencyFailed' carrying the dependency's own fault and the reader wants the cause and not the
-- wrapper: a missing file is @not_found@ however many modules import it, a cycle is @module_cycle@,
-- a cache or depth limit met by an accepted load is @module_limit@, and everything the module's own
-- code did (syntax, a raised error, a return that is not exactly one plain table) is @module_error@.
-- Engine and provider defects are not here: they are not module failures and are never given a code.
module Hetoimasia.LuaEngine.Modules.Failure
  ( ModuleFailure (..)
  , moduleCodes
  , sourceCodes
  , encodeSourceReason
  , innermostFault
  , dependencyIdentities
  , failureOfFault
  , clipBytes
  , messageLimit
  , tracebackLimit
  ) where

import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import Hetoimasia.Scripting.Lua.Owner
  ( BoundaryFault (boundaryReason, boundaryTraceback)
  , ErrorValue (..)
  , ExportShape (..)
  , FaultReason (..)
  , ModuleProblem (..)
  )

-- | A module's failure as an expected failure: its code, bounded message, the root and path of the
-- content that failed (the dependency, when the cause is one), the labels of the imports it was
-- reached through, outermost first, and the cause's traceback if Lua gave one.
data ModuleFailure = ModuleFailure
  { failureCode ∷ !Text
  , failureMessage ∷ !Text
  , failureRoot ∷ !Text
  , failurePath ∷ !Text
  , failureChain ∷ ![Text]
  , failureTraceback ∷ !(Maybe Text)
  }
  deriving (Eq, Show)

-- | The codes a module request's expected failures carry.
moduleCodes ∷ [Text]
moduleCodes = sourceCodes <> ["module_error", "module_cycle", "module_limit"]

-- | The codes of a failure to obtain a source.
sourceCodes ∷ [Text]
sourceCodes = ["not_found", "content_changed", "io_error", "too_large"]

-- | The 2 KiB bound of a message (P-74).
messageLimit ∷ Int
messageLimit = 2048

-- | The 8 KiB bound of a traceback (P-74).
tracebackLimit ∷ Int
tracebackLimit = 8192

-- | A source failure as the reason a supplier hands the loader: the code, a colon, the message. The
-- loader keeps it in the fault of the identity and bounds it; the code is read back by 'failureOfFault'.
encodeSourceReason ∷ Text → Text → Text
encodeSourceReason code message = code <> ":" <> message

-- | The fault at the bottom of a chain of dependency failures, with the labels of the dependencies
-- walked through, outermost first.
innermostFault ∷ BoundaryFault → ([Text], BoundaryFault)
innermostFault fault = case boundaryReason fault of
  ModuleRefused (DependencyFailed label _ inner) →
    let (labels, cause) = innermostFault inner in (label : labels, cause)
  _ → ([], fault)

-- | The identities, as bytes, of the dependencies a fault was reached through, outermost first. The
-- last is the dependency whose own failure is the cause; none means the fault is the module's own.
dependencyIdentities ∷ BoundaryFault → [ByteString.ByteString]
dependencyIdentities fault = case boundaryReason fault of
  ModuleRefused (DependencyFailed _ identity inner) → identity : dependencyIdentities inner
  _ → []

-- | The failure a fault is told as. The first label is the module that was asked for; the root and
-- path are those of the failing content, which the caller locates (the requested content when it
-- cannot).
failureOfFault ∷ Text → (Text, Text) → BoundaryFault → ModuleFailure
failureOfFault requested (root, path) fault =
  ModuleFailure
    { failureCode = code
    , failureMessage = clipBytes messageLimit message
    , failureRoot = root
    , failurePath = path
    , failureChain = requested : labels
    , failureTraceback = clipBytes tracebackLimit <$> boundaryTraceback cause
    }
  where
    (labels, cause) = innermostFault fault
    (code, detail) = classify (boundaryReason cause)
    via = case labels of
      [] → ""
      _ → " (imported through " <> Text.intercalate " -> " (requested : labels) <> ")"
    message = detail <> via

-- | The code and detail of a cause.
classify ∷ FaultReason → (Text, Text)
classify = \case
  ModuleRefused problem → case problem of
    SourceUnavailable _ reason → fromSource reason
    SourceTooLarge bound → ("too_large", "the module's source is over the limit of " <> shown bound <> " bytes")
    ImportCycle names → ("module_cycle", "import cycle: " <> Text.intercalate " -> " names)
    ImportCacheFull bound label → ("module_limit", "no room for the module " <> label <> ": the VM holds " <> shown bound <> " module identities")
    ImportChainTooDeep bound label → ("module_limit", "the module " <> label <> " would make the import chain longer than " <> shown bound)
    ImportNotSuspendable _ label → ("module_error", "the module " <> label <> " was imported where Lua cannot suspend")
    DependencyFailed label _ _ → ("module_error", "the dependency " <> label <> " failed")
    other → ("module_error", "the module was refused: " <> Text.pack (show other))
  ScriptFailed _ value → ("module_error", "the module raised an error: " <> renderError value)
  ExportShapeRefused shape → ("module_error", "the module did not return exactly one plain table: " <> renderShape shape)
  UnscheduledYield → ("module_error", "the module yielded to no one")
  other → ("module_error", "the module failed: " <> Text.pack (show other))
  where
    shown = Text.pack . show

-- | The code and message a supplier encoded; a reason with no code of ours is an I/O failure.
fromSource ∷ Text → (Text, Text)
fromSource reason = case Text.breakOn ":" reason of
  (code, rest)
    | code `elem` sourceCodes, Just message ← Text.stripPrefix ":" rest → (code, message)
  _ → ("io_error", reason)

renderError ∷ ErrorValue → Text
renderError = \case
  ErrorMessage text cut → text <> (if cut then "..." else "")
  ErrorOpaque kind → "a " <> kind <> " value"
  ErrorAbsent → "no error value"

renderShape ∷ ExportShape → Text
renderShape = \case
  ExportNoResult → "it returned nothing"
  ExportNil → "it returned nil"
  ExportNotTable kind → "it returned a " <> kind
  ExportMultiple → "it returned more than one value"
  ExportMetatable → "its table has a metatable"

-- | Text cut to at most this many UTF-8 bytes, at a character, with a visible mark when cut.
clipBytes ∷ Int → Text → Text
clipBytes bound text
  | ByteString.length (Encoding.encodeUtf8 text) <= bound = text
  | bound < 3 = Text.empty
  | otherwise = go (bound - 3) text <> "..."
  where
    go room remaining = case Text.uncons remaining of
      Just (character, rest)
        | width character <= room → Text.cons character (go (room - width character) rest)
      _ → Text.empty
    width = ByteString.length . Encoding.encodeUtf8 . Text.singleton
