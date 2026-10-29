{-# LANGUAGE OverloadedStrings #-}

-- | The least each limit of a profile may be, which validation enforces.
--
-- __Why a minimum.__ Most limits are /caps on what comes in/ (a manifest, a module's source, a data file, a PNG, a
-- request): a cap too small to hold any real input refuses content, loudly and early, and breaks nothing the engine
-- makes itself, so the least such a cap may be is the least /positive/ value, one. A few limits are /bounds on what the
-- engine itself writes or hands across/, and a bound below the least that its own schema, format or crossing needs would
-- be a promise the engine cannot keep: the whole-record cap of a failure (whose schema words, a code, a stage and a role,
-- cannot be shortened), the bound on an instance identity (the first one the session issues must fit), the bound on one
-- @print@ or @warn@ (a warning must still be able to name its writer), and the bound on a copied value (the engine's own
-- context record and texts must cross). A texture holds at least one RGBA8 pixel, and a scene of one sprite is its fixed
-- elements and one sprite's. Validation refuses a value below these ('LimitBelowMinimum'), after the ceilings and before
-- the relations, so that a profile it accepts can be used by the engine without a second refusal at the point of use.
--
-- The formatting constants are here, and the facade formats with them, so that what the format takes and what the bound
-- is checked against cannot drift apart.
--
-- __Ownership.__ Pure; no state.
module Hetoimasia.LuaEngine.Profile.Minimum
  ( minimumBytes
  , minimumCount
  , minimumDuration

    -- * What a bound is checked against
  , schemaWordsBytes
  , minimumInstanceIdBytes
  , minimumPrintWarnBytes
  , minimumCopiedValueBytes
  , minimumContextBytes
  , failureTextBytes
  , minimumStatusBytes
  , minimumStatusDepth
  , minimumStatusElements

    -- * The format's pieces
  , codeWords
  , stageWords
  , roleWords
  , warnLead
  , contentLead
  , instanceLead
  , moduleLead
  , warnEnd
  , moduleLabelBytes
  , contentIdBytes
  , bytesOfText
  ) where

import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
import Data.Word (Word64)
import Hetoimasia.LuaEngine.Profile.Limits

-- | The least a byte limit may be in this specification: the others it depends on are read from it.
minimumBytes ∷ ProfileSpec → ByteLimit → Word64
minimumBytes spec = \case
  -- the failure record's schema words cannot be shortened, whatever the message, traceback, path, identity and content
  RoleFailureRecordBytes → fromIntegral schemaWordsBytes
  -- the first identity the session issues
  InstanceIdBytes → fromIntegral minimumInstanceIdBytes
  -- a warning's prefix, the truncation marker and a line end
  PrintWarnBytes → fromIntegral (minimumPrintWarnBytes identity)
  -- the engine's own context record, texts and status record that cross the value boundary
  CopiedValueBytes → fromIntegral (minimumCopiedValueBytes identity (fromIntegral (rawOf (specBytes spec PrintWarnBytes))) texts)
  -- one RGBA8 pixel: the least output a texture has
  PngPipelineWorkspaceBytes → rgba8BytesPerPixel
  TextureBytesPerUiInstance → rgba8BytesPerPixel
  TextureBytesPerSession → rgba8BytesPerPixel
  -- every other byte limit is a cap on what comes in, or on a text cut visibly to it: the least positive value
  _ → 1
  where
    identity = fromIntegral (rawOf (specBytes spec InstanceIdBytes))
    texts =
      failureTextBytes
        (fromIntegral (rawOf (specBytes spec MessageBytes)))
        (fromIntegral (rawOf (specBytes spec TracebackBytes)))
        identity
        (fromIntegral (rawOf (specBytes spec PathBytes)))
        (fromIntegral (rawOf (specBytes spec RoleFailureRecordBytes)))
    rawOf (Bytes value) = min value (fromIntegral (maxBound ∷ Int))

-- | The least a count limit may be: one, except that a scene of one sprite is its fixed elements and one sprite's, a
-- copied value must be able to hold it, and a copied value must be able to hold the largest status record a session
-- shows a script (its depth and its elements).
minimumCount ∷ ProfileSpec → CountLimit → Word64
minimumCount _ = \case
  CopiedValueElements → max (sceneFixedElements + sceneElementsPerSprite + sceneCallExtraElements) (fromIntegral minimumStatusElements)
  CopiedValueDepth → fromIntegral minimumStatusDepth
  _ → 1

-- | The least a duration limit may be, in nanoseconds: one.
minimumDuration ∷ ProfileSpec → DurationLimit → Word64
minimumDuration _ _ = 1

-- The failure record -------------------------------------------------------------------------------

-- | The codes of a failure, as the schema spells them.
codeWords ∷ [Text]
codeWords = ["lua_error", "module_error", "required_request", "host_failure", "cleanup_failure", "state_unavailable"]

-- | The stages of a failure, as the schema spells them.
stageWords ∷ [Text]
stageWords = ["module", "init", "update", "shutdown", "request", "cleanup", "engine"]

-- | The roles, as the schema spells them.
roleWords ∷ [Text]
roleWords = ["gameplay", "presentation"]

-- | The bytes of the longest code, the longest stage and the longest role together: what a failure record is, whatever its
-- texts, once they are all cut away. A record bound below it cannot be kept.
schemaWordsBytes ∷ Int
schemaWordsBytes = maximum (map bytesOfText codeWords) + maximum (map bytesOfText stageWords) + maximum (map bytesOfText roleWords)

-- The facade's format ------------------------------------------------------------------------------

-- The pieces of a warning's prefix. The facade builds the prefix from them and so does 'minimumPrintWarnBytes', so that
-- what the format takes and what the bound is checked against cannot drift apart.
warnLead, contentLead, instanceLead, moduleLead, warnEnd ∷ Text
warnLead = "lua warning role="
contentLead = " content="
instanceLead = " instance="
moduleLead = " module="
warnEnd = ": "

-- | The most bytes of a module's label a prefix names; the rest is cut. The host already gives every module a label of at
-- most 128 bytes (its own bound on a label in a diagnostic), so the cut is a guard and not a loss.
moduleLabelBytes ∷ Int
moduleLabelBytes = 128

-- | The most bytes of a content identifier (a root identifier is 1 to 64 ASCII characters).
contentIdBytes ∷ Int
contentIdBytes = 64

bytesOfText ∷ Text → Int
bytesOfText = ByteString.length . Text.encodeUtf8

-- | The fewest bytes the profile's bound on an instance identity may be: the first identity the session issues,
-- @inst-1@. A later identity that does not fit is refused when it is declared, never written.
minimumInstanceIdBytes ∷ Int
minimumInstanceIdBytes = bytesOfText "inst-1"

-- | The fewest bytes the profile's bound on one @print@ or @warn@ may be, given its bound on an identity: the longest
-- prefix a warning takes (an instance's, or a module's with its label cut), the truncation marker and a line end, so
-- that a call that is cut can still say so on a prefixed line.
minimumPrintWarnBytes ∷ Int → Int
minimumPrintWarnBytes idBytes = max instanceForm moduleForm + bytesOfText "..." + 1
  where
    longestRole = maximum (map bytesOfText roleWords)
    instanceForm = bytesOfText warnLead + longestRole + bytesOfText contentLead + contentIdBytes + bytesOfText instanceLead + idBytes + bytesOfText warnEnd
    moduleForm = bytesOfText warnLead + longestRole + bytesOfText moduleLead + moduleLabelBytes + bytesOfText warnEnd

-- | The fewest bytes the profile's bound on a copied value may be, given its bounds on an identity, on one @print@ or
-- @warn@ and on the texts a failure may hold ('failureTextBytes'): the largest of everything the facade itself makes cross
-- the value boundary, each with the header the host adds to it. These are the text of one call to @out@ or @err@ (at most
-- the print bound, and a text argument has a five-byte header), an identity handed to @check@ or @bind@ (a text, the same
-- header), the context record the builder is handed ('minimumContextBytes') and the largest status record a session shows
-- a presentation script ('minimumStatusBytes'). What a script passes in as the path or the options of a content request is
-- the script's, and a value too large to cross is an ordinary error there.
minimumCopiedValueBytes ∷ Int → Int → Int → Int
minimumCopiedValueBytes idBytes printBytes failureTexts = maximum [minimumContextBytes idBytes, printBytes + 5, idBytes + 5, minimumStatusBytes failureTexts]

-- | The most bytes of text one failure record may hold, given the profile's bounds on a message, a traceback, an
-- instance identity, a path and the whole record: each text is cut to its own bound, the schema's words (the longest
-- code, stage and role) and a content identifier cannot be cut, and the whole is held to the record bound. The status
-- record shows a failure as the session holds it, so this is the most any failure in it can weigh in text.
failureTextBytes ∷ Int → Int → Int → Int → Int → Int
failureTextBytes messageBytes tracebackBytes idBytes pathBytes recordBytes =
  min recordBytes (schemaWordsBytes + messageBytes + tracebackBytes + contentIdBytes + idBytes + pathBytes)

-- | The bytes the host counts for the largest status record a session shows a script, given the most text a failure
-- record may hold ('failureTextBytes'): both roles present and failed, every optional field of each failure present. The
-- host counts a table as five bytes and its keys and values, a key or a text as five bytes and its length, and a boolean
-- as one.
minimumStatusBytes ∷ Int → Int
minimumStatusBytes failureTexts = table (key "stopping" + 1 + key "gameplay" + role + key "presentation" + role)
  where
    table body = 5 + body
    key name = 5 + bytesOfText name
    text n = 5 + n
    role = table (key "present" + 1 + key "initialized" + 1 + key "phase" + text longestPhase + key "failed" + 1 + key "failure" + failure)
    failure = table (sum (map key statusFailureKeys) + length statusFailureKeys * 5 + failureTexts)
    longestPhase = maximum (map bytesOfText statusPhaseWords)

-- | How deep the largest status record nests: the record, a role, a failure.
minimumStatusDepth ∷ Int
minimumStatusDepth = 3

-- | How many values the host counts in the largest status record: every table and every value in it, keys not counted.
-- One for the record, one for @stopping@, and for each role the table, its four fields and the failure with its eight.
minimumStatusElements ∷ Int
minimumStatusElements = 1 + 1 + 2 * (1 + 4 + (1 + length statusFailureKeys))

-- | The keys of a failure in the status record.
statusFailureKeys ∷ [Text]
statusFailureKeys = ["code", "message", "role", "stage", "content_id", "instance_id", "path", "traceback"]

-- | The phases of a role, as the schema spells them.
statusPhaseWords ∷ [Text]
statusPhaseWords = ["starting", "ready", "running", "stopping", "retired"]

-- | The fewest bytes the profile's bound on a copied value may be for the builder's context alone, given its bound on an
-- identity: the bytes the host counts for the context record the builder is handed (a record of five bytes and, for each
-- of @role@, @content_id@ and @instance_id@, a key of five bytes and its name and a text of five bytes and its length).
minimumContextBytes ∷ Int → Int
minimumContextBytes idBytes =
  5
    + sum [5 + bytesOfText key | key ← ["role", "content_id", "instance_id"]]
    + sum [5 + n | n ← [longestRole, contentIdBytes, idBytes]]
  where
    longestRole = maximum (map bytesOfText roleWords)
