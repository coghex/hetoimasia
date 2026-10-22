-- | The format-1 launch manifest, @hetoimasia.json@: strict parsing of supplied
-- bytes into a resolved role, entry and tick configuration.
--
-- __Contract.__ 'parseManifest' takes the bytes of exactly one root manifest
-- and returns a 'Manifest' or the first refusal, as a plain value. It opens no
-- folder, reads no file, starts no Lua, worker, window or GPU, prints nothing
-- and exits nowhere, and says nothing about the filesystem: entry texts are
-- kept exactly as decoded, including a common entry every role overrides, so
-- the content layer can check every declared path (literal-path validation,
-- Unicode identity and inventory presence) before Lua runs. The manifest also
-- keeps the exact bytes that were parsed, so later anchored inventory work
-- checks what was parsed rather than a reserialization.
--
-- __Refusal order.__ The byte limit; then the whole document's syntax —
-- well-formed UTF-8, no byte order mark, RFC 8259's grammar with comments,
-- trailing commas, unescaped control characters and unpaired surrogate escapes
-- refused, nesting of at most eight containers (the outer object counts),
-- duplicate keys after escape decoding at any object, nothing but whitespace
-- after the object, and an object at the root; then the schema. Member order
-- never changes which refusal is returned.
--
-- __Schema.__ @format@ (a number whose exact decimal value is 1, judged without
-- binary floating point), @id@ (1–64 characters of @[a-z][a-z0-9_-]*@),
-- optional @entry@, @tick_seconds@ (decimal text, required exactly when
-- gameplay is present) and optional @vms@ (one or two role declarations,
-- gameplay with the logical clock and presentation with the elapsed clock,
-- each with an optional @entry@). Without @vms@ both roles are selected and use
-- the common entry. No other field is accepted; nothing is defaulted.
--
-- __Bounds.__ The input size and nesting come from the 'Profile' (the fixed M1
-- profile's 65,536 bytes and eight containers unless a test injects smaller
-- ones) and are enforced while parsing. Nothing allocated grows with a number's
-- exponent. A refusal's text is cut to 64 code points.
module Hetoimasia.LuaEngine.Manifest
  ( -- * Parsing
    parseManifest
  , parseManifestWith

    -- * The result
  , Manifest (..)
  , ContentId
  , contentIdText
  , RoleSelection (..)
  , GameplayRole (..)
  , PresentationRole (..)
  , EntryOrigin (..)
  , selectedRoles
  , EntrySlot (..)
  , DeclaredEntry (..)
  , declaredEntries

    -- * Refusals
  , ManifestError (..)
  , SyntaxError (..)
  , SchemaError (..)
  , Role (..)
  , ValueKind (..)
  , ExpectedType (..)
  , IdProblem (..)
  , TickProblem (..)
  , Excerpt (..)
  , excerptLimit
  , PathSegment (..)
  , FieldPath
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Hetoimasia.LuaEngine.Manifest.Error
import Hetoimasia.LuaEngine.Manifest.Json (parseJsonObject)
import Hetoimasia.LuaEngine.Manifest.Schema (resolveManifest)
import Hetoimasia.LuaEngine.Manifest.Types hiding (unsafeContentId)
import Hetoimasia.LuaEngine.Profile
  ( ByteLimit (ManifestBytes)
  , Bytes (Bytes)
  , Count (Count)
  , CountLimit (ManifestDepth)
  , DurationLimit (ManifestTickMaximum)
  , Profile
  , bytesLimit
  , countLimit
  , durationLimit
  , fixedM1Profile
  )

-- | Parse a manifest under the fixed M1 profile.
parseManifest ∷ ByteString → Either ManifestError Manifest
parseManifest = parseManifestWith fixedM1Profile

-- | Parse a manifest under a validated profile, which can only be the fixed
-- one or a smaller one.
parseManifestWith ∷ Profile → ByteString → Either ManifestError Manifest
parseManifestWith profile input
  | toInteger size > toInteger limit = Left (ManifestTooLarge size (fromIntegral limit))
  | otherwise = do
      root ← either (Left . ManifestSyntax) Right (parseJsonObject (fromIntegral depth) input)
      either (Left . ManifestSchema) Right (resolveManifest (durationLimit profile ManifestTickMaximum) input root)
  where
    size = ByteString.length input
    Bytes limit = bytesLimit profile ManifestBytes
    Count depth = countLimit profile ManifestDepth
