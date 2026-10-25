{-# LANGUAGE OverloadedStrings #-}

-- | The session's failure data: the approved role-failure schema (P-73), the bounds it is held to
-- (P-74) and the engine report, as pure values.
--
-- Nothing here performs IO or touches a VM. A failure is built from what the host reported, cut
-- visibly at UTF-8 boundaries to the profile's bounds, and kept in the session's state by
-- "Hetoimasia.LuaEngine.Session.State", which is the only writer. The first failure of a role is never
-- replaced; later cleanup failures are accounted in the engine report, which keeps at most the
-- profile's number of secondary summaries and counts the rest.
--
-- = The schema
--
-- A failure has a required @code@, @message@, @role@ and @stage@, and, when known, a @content_id@, an
-- @instance_id@, a @path@ and a @traceback@; an unknown one is absent, and no instance is invented for
-- work that has none (a module that fails before an instance exists).
--
-- = The bounds
--
-- Every text field is cut to its own bound: the message, the traceback, the opaque instance identity
-- and the path to the profile's, and the content identifier to the 64 bytes the manifest allows one
-- (it is not a profile number, because a validated identifier cannot exceed it; a record built by a
-- caller that did not validate one is cut all the same). The whole record is then held to the profile's
-- record bound (16 KiB) by shortening the traceback first, then the message, then the path, then the
-- instance identity, then the content identifier. The record's size is the sum of the UTF-8 bytes of
-- every text it holds, the schema's words included, so no field escapes the count. A cut ends in a
-- visible @...@ and never splits a code point; a bound too small to hold the marker is simply the first
-- bytes. Only a record bound smaller than the schema's own words (code, stage, role) cannot be met.
module Hetoimasia.LuaEngine.Session.Failure
  ( -- * The schema
    FailureCode (..)
  , FailureStage (..)
  , RoleFailure (..)
  , codeWord
  , stageWord
  , roleWord
  , newRoleFailure

    -- * Bounds
  , FailureLimits (..)
  , failureLimitsOf
  , truncateText
  , utf8Bytes
  , boundFailure
  , recordBytes

    -- * The engine report
  , EngineEntry (..)
  , EngineReport (..)
  , emptyReport
  , noteEngine
  , reportAccounted
  , engineEntry
  , engineRoleFailure
  , roleFailureEntry

    -- * From the host
  , classifyInstance
  ) where

import qualified Data.ByteString as ByteString
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.LuaEngine.Manifest (Role (..))
import Hetoimasia.LuaEngine.Profile
  ( ByteLimit (EngineReportBytes, InstanceIdBytes, MessageBytes, PathBytes, RoleFailureRecordBytes, SecondarySummaryBytes, TracebackBytes)
  , Bytes (Bytes)
  , Count (Count)
  , CountLimit (SecondarySummaries)
  , Profile
  , bytesLimit
  , countLimit
  )
import Hetoimasia.Scripting.Lua.Instance
  ( HookStage (..)
  , InstanceError (..)
  , InstanceFailure (..)
  )
import Hetoimasia.Scripting.Lua.Runtime (CallFault (ModuleNotLoaded))

-- The schema --------------------------------------------------------------------------------------

-- | What kind of failure it was.
data FailureCode
  = -- | A script error.
    LuaError
  | -- | A module that failed to evaluate, or a behavior that does not fit its schema.
    ModuleError
  | -- | A required content request that failed.
    RequiredRequest
  | -- | A failure of the engine, a provider, a sink or the host.
    HostFailure
  | -- | A failure of cleanup.
    CleanupFailure
  | -- | The unavailable-state guard (LFE-26's, latched here).
    StateUnavailable
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Where it happened.
data FailureStage
  = OnModule
  | OnInit
  | OnUpdate
  | OnShutdown
  | OnRequest
  | OnCleanup
  | OnEngine
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | One role's failure, as the status record shows it.
data RoleFailure = RoleFailure
  { rfCode ∷ !FailureCode
  , rfMessage ∷ !Text
  , rfRole ∷ !Role
  , rfStage ∷ !FailureStage
  , rfContent ∷ !(Maybe Text)
  -- ^ The content identifier, when known.
  , rfInstance ∷ !(Maybe Text)
  -- ^ The executing instance's opaque identity, when there was one.
  , rfPath ∷ !(Maybe Text)
  -- ^ The content path, when known.
  , rfTraceback ∷ !(Maybe Text)
  -- ^ A bounded traceback, when one was captured.
  }
  deriving (Eq, Show)

-- | A failure with its required fields and nothing else known.
newRoleFailure ∷ FailureCode → FailureStage → Role → Text → RoleFailure
newRoleFailure code stage role message = RoleFailure code message role stage Nothing Nothing Nothing Nothing

-- | The code as the schema spells it.
codeWord ∷ FailureCode → Text
codeWord = \case
  LuaError → "lua_error"
  ModuleError → "module_error"
  RequiredRequest → "required_request"
  HostFailure → "host_failure"
  CleanupFailure → "cleanup_failure"
  StateUnavailable → "state_unavailable"

-- | The stage as the schema spells it.
stageWord ∷ FailureStage → Text
stageWord = \case
  OnModule → "module"
  OnInit → "init"
  OnUpdate → "update"
  OnShutdown → "shutdown"
  OnRequest → "request"
  OnCleanup → "cleanup"
  OnEngine → "engine"

-- | The role as the schema spells it.
roleWord ∷ Role → Text
roleWord = \case
  Gameplay → "gameplay"
  Presentation → "presentation"

-- Bounds ------------------------------------------------------------------------------------------

-- | The numbers failures are held to, read once from a validated profile.
data FailureLimits = FailureLimits
  { limitMessage ∷ !Int
  , limitTraceback ∷ !Int
  , limitRecord ∷ !Int
  , limitInstance ∷ !Int
  , limitContent ∷ !Int
  -- ^ The bytes of a content identifier: the manifest's 64, not a profile number.
  , limitPath ∷ !Int
  , limitReport ∷ !Int
  , limitSecondary ∷ !Int
  -- ^ How many secondary summaries the engine report retains.
  , limitSummary ∷ !Int
  -- ^ The bytes of one secondary summary.
  }
  deriving (Eq, Show)

-- | The limits of a profile. A bound beyond what a machine integer holds is held to the integer.
failureLimitsOf ∷ Profile → FailureLimits
failureLimitsOf profile =
  FailureLimits
    { limitMessage = bytes MessageBytes
    , limitTraceback = bytes TracebackBytes
    , limitRecord = bytes RoleFailureRecordBytes
    , limitInstance = bytes InstanceIdBytes
    , limitContent = contentIdBytes
    , limitPath = bytes PathBytes
    , limitReport = bytes EngineReportBytes
    , limitSecondary = let Count n = countLimit profile SecondarySummaries in clamp n
    , limitSummary = bytes SecondarySummaryBytes
    }
  where
    bytes limit = let Bytes n = bytesLimit profile limit in clamp n
    clamp n = fromIntegral (min n (fromIntegral (maxBound ∷ Int)))

-- | The longest content identifier the manifest admits ('Hetoimasia.LuaEngine.Manifest.ContentId': 1 to 64
-- ASCII characters).
contentIdBytes ∷ Int
contentIdBytes = 64

-- | The marker a cut ends in.
marker ∷ Text
marker = "..."

-- | The bytes of a text in UTF-8.
utf8Bytes ∷ Text → Int
utf8Bytes = ByteString.length . Text.encodeUtf8

-- | Cut a text to at most this many bytes of UTF-8, at a code point, ending in a visible marker when
-- anything was cut. A bound below the marker's own size is the first bytes that fit, and none at zero.
truncateText ∷ Int → Text → Text
truncateText limit text
  | limit <= 0 = Text.empty
  | utf8Bytes text <= limit = text
  | limit < markerBytes = prefix limit
  | otherwise = prefix (limit - markerBytes) <> marker
  where
    markerBytes = utf8Bytes marker
    prefix room = Text.pack (go room (Text.unpack text))
    go _ [] = []
    go room (c : rest)
      | width c <= room = c : go (room - width c) rest
      | otherwise = []
    width c
      | c < '\x80' = 1
      | c < '\x800' = 2
      | c < '\x10000' = 3
      | otherwise = 4 ∷ Int

-- | The size of a record: the UTF-8 bytes of its text fields, the schema's words included.
recordBytes ∷ RoleFailure → Int
recordBytes failure =
  sum
    [ utf8Bytes (codeWord (rfCode failure))
    , utf8Bytes (stageWord (rfStage failure))
    , utf8Bytes (roleWord (rfRole failure))
    , utf8Bytes (rfMessage failure)
    , maybe 0 utf8Bytes (rfContent failure)
    , maybe 0 utf8Bytes (rfInstance failure)
    , maybe 0 utf8Bytes (rfPath failure)
    , maybe 0 utf8Bytes (rfTraceback failure)
    ]

-- | A failure held to the bounds: each text field to its own, then the whole to the record's, shortening
-- the traceback, then the message, then the path, then the instance identity, then the content
-- identifier. The code, role and stage are words of the schema and stay.
boundFailure ∷ FailureLimits → RoleFailure → RoleFailure
boundFailure limits failure = fitRecord limits each
  where
    each =
      failure
        { rfMessage = truncateText (limitMessage limits) (rfMessage failure)
        , rfContent = truncateText (limitContent limits) <$> rfContent failure
        , rfInstance = truncateText (limitInstance limits) <$> rfInstance failure
        , rfPath = truncateText (limitPath limits) <$> rfPath failure
        , rfTraceback = truncateText (limitTraceback limits) <$> rfTraceback failure
        }

-- | Shrink the fields, in order, each by only what the record is still over by. Every text 'recordBytes'
-- counts that is not a schema word has a place in the list.
fitRecord ∷ FailureLimits → RoleFailure → RoleFailure
fitRecord limits failure = foldl' (flip ($)) failure shrinkers
  where
    shrinkers =
      [ shrinkOptional rfTraceback (\f v → f {rfTraceback = v})
      , shrinkMessage
      , shrinkOptional rfPath (\f v → f {rfPath = v})
      , shrinkOptional rfInstance (\f v → f {rfInstance = v})
      , shrinkOptional rfContent (\f v → f {rfContent = v})
      ]
    shrinkMessage f
      | over f <= 0 = f
      | otherwise = f {rfMessage = truncateText (max 0 (utf8Bytes (rfMessage f) - over f)) (rfMessage f)}
    shrinkOptional get set f
      | over f <= 0 = f
      | otherwise = case get f of
          Nothing → f
          Just text → set f (nonEmpty (truncateText (max 0 (utf8Bytes text - over f)) text))
    over f = recordBytes f - limitRecord limits
    nonEmpty text = if Text.null text then Nothing else Just text

-- The engine report -------------------------------------------------------------------------------

-- | One failure of the engine, the host, a provider or cleanup that is not a role's script.
data EngineEntry = EngineEntry
  { eeCode ∷ !FailureCode
  , eeRole ∷ !(Maybe Role)
  -- ^ The role whose owner it concerned, when one.
  , eeStage ∷ !FailureStage
  , eeMessage ∷ !Text
  }
  deriving (Eq, Show)

-- | A failure of the engine. Roles and stage are the caller's; the message is bounded when noted.
engineEntry ∷ FailureCode → Maybe Role → FailureStage → Text → EngineEntry
engineEntry = EngineEntry

-- | The engine report: the first failure, at most 'limitSecondary' later ones, and how many were not
-- kept. Every failure the session was told of is accounted for in one of the three.
data EngineReport = EngineReport
  { erPrimary ∷ !(Maybe EngineEntry)
  , erSecondary ∷ ![EngineEntry]
  , erOmitted ∷ !Int
  }
  deriving (Eq, Show)

-- | Nothing yet.
emptyReport ∷ EngineReport
emptyReport = EngineReport Nothing [] 0

-- | Account for one failure. The first is the primary and later ones never replace it; a later one
-- is a secondary summary while there is room and is otherwise counted. The primary's message is cut so
-- that the whole report stays within its bound whatever the secondaries add; a secondary is cut to a
-- summary's bound.
noteEngine ∷ FailureLimits → EngineEntry → EngineReport → EngineReport
noteEngine limits entry report = case erPrimary report of
  Nothing → report {erPrimary = Just entry {eeMessage = truncateText primaryBytes (eeMessage entry)}}
  Just _
    | length (erSecondary report) < limitSecondary limits →
        report {erSecondary = erSecondary report <> [entry {eeMessage = truncateText (limitSummary limits) (eeMessage entry)}]}
    | otherwise → report {erOmitted = erOmitted report + 1}
  where
    primaryBytes = min (limitRecord limits) (max 0 (limitReport limits - limitSecondary limits * limitSummary limits))

-- | How many failures the report accounts for.
reportAccounted ∷ EngineReport → Int
reportAccounted report = maybe 0 (const 1) (erPrimary report) + length (erSecondary report) + erOmitted report

-- | An engine failure as the status record of a role shows it (when its owner is known).
engineRoleFailure ∷ Role → EngineEntry → RoleFailure
engineRoleFailure role entry =
  newRoleFailure (eeCode entry) (eeStage entry) role (eeMessage entry)

-- | A role's failure as the engine report accounts for it: the report holds the session's first failure of any
-- kind as its primary and every later one as a secondary, so each failure the session was told of is
-- accounted once.
roleFailureEntry ∷ RoleFailure → EngineEntry
roleFailureEntry failure = EngineEntry (rfCode failure) (Just (rfRole failure)) (rfStage failure) (rfMessage failure)

-- From the host -----------------------------------------------------------------------------------

-- | A host instance failure as the session records it: the role's failure, bounded, and what else
-- failed while the instance ended, as engine entries for the report.
--
-- The code follows the host's error: a script error is @lua_error@; a module or a behavior that does not
-- fit, @module_error@; a required request, @required_request@; a release, @cleanup_failure@; anything
-- the host itself could not do, @host_failure@. The stage follows the hook the failure happened in; the
-- failures of the engine and of cleanup are staged @engine@ and @cleanup@.
classifyInstance
  ∷ FailureLimits
  → Role
  → Text
  -- ^ The content identifier.
  → Maybe Text
  -- ^ The facade's identity for the instance, when the session knows it.
  → Maybe Text
  -- ^ The path of the instance's entry module, for a failure that is the module's.
  → InstanceFailure
  → (RoleFailure, [EngineEntry])
classifyInstance limits role content identity entryPath failure =
  ( boundFailure
      limits
      RoleFailure
        { rfCode = code
        , rfMessage = failureMessage failure
        , rfRole = role
        , rfStage = stage
        , rfContent = Just content
        , rfInstance = identity
        , rfPath = if stage == OnModule then entryPath else Nothing
        , rfTraceback = failureTraceback failure
        }
  , mapMaybe secondary (failureSecondary failure)
  )
  where
    (code, stage) = codeAndStage (failureStage failure) (failureError failure)
    secondary (hook, problem) =
      let (c, s) = codeAndStage hook problem
       in Just (EngineEntry c (Just role) s (Text.pack (take 2048 (show problem))))

-- | The code and the stage of a failure: the host's error says what kind it is, and the hook says where.
codeAndStage ∷ HookStage → InstanceError → (FailureCode, FailureStage)
codeAndStage hook problem = case problem of
  ErrorRequest _ _ → (RequiredRequest, OnRequest)
  ErrorExportMissing _ → (ModuleError, OnModule)
  ErrorExportFailed _ → (ModuleError, OnModule)
  ErrorBehavior _ → (ModuleError, OnModule)
  ErrorRelease _ → (CleanupFailure, OnCleanup)
  ErrorDelivery _ _ → (HostFailure, OnEngine)
  ErrorCadence _
    | hook == StageConstruct → (ModuleError, OnModule)
    | otherwise → (HostFailure, OnEngine)
  ErrorFault (ModuleNotLoaded _) → (HostFailure, OnEngine)
  ErrorFault _ → (LuaError, stageOf hook)
  ErrorMissingEntry _ → (ModuleError, OnModule)
  ErrorRefusedWait _ → (LuaError, stageOf hook)
  where
    stageOf = \case
      StageInit → OnInit
      StageRun → OnUpdate
      StageUpdate → OnUpdate
      StageEvent _ → OnUpdate
      StageShutdown → OnShutdown
      StageRelease → OnCleanup
      StageRequest _ → OnRequest
      StageConstruct → OnModule
