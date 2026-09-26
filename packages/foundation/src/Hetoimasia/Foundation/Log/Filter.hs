-- | Startup configuration parsing and the admission predicate a logger applies
-- before it builds an entry.
--
-- 'parseLogLevel', 'parseComponentLevels', and 'parseDebugSelection' validate
-- the three configurable parts of a 'LogFilter' without performing IO and
-- without knowing where the text came from. 'resolveLogFilter' assembles them
-- over a caller-supplied lookup and a caller-supplied 'LogVariables', so the
-- variable names and the environment access both belong to the application.
-- 'emits' is the filter's decision for one level and component, taken before a
-- message, a field, or any metadata is forced.
--
-- The public facade is "Hetoimasia.Foundation.Log", which re-exports the
-- parsers and 'resolveLogFilter'; 'emits' stays private to the foundation
-- package, as this module does.
module Hetoimasia.Foundation.Log.Filter
  ( -- * Startup configuration
    parseLogLevel
  , parseComponentLevels
  , parseDebugSelection
  , resolveLogFilter

    -- * Admission
  , emits
  ) where

import Control.Monad (foldM)
import Data.List (find)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log.Base (LogLevel (..), LogVariables (..))
import Hetoimasia.Foundation.Log.Component (Component, componentText, mkComponent, quoted)
import Hetoimasia.Foundation.Log.Types (DebugSelection (..), LogFilter (..))

-- | Parse a threshold: @debug@, @info@, @warn@, @warning@, or @error@,
-- case-insensitively, with surrounding whitespace trimmed. An empty or
-- unrecognized value is an error, never a silent default.
parseLogLevel ∷ Text → Either Text LogLevel
parseLogLevel value = case Text.toLower trimmed of
  "debug" → Right Debug
  "info" → Right Info
  "warn" → Right Warning
  "warning" → Right Warning
  "error" → Right Error
  _
    | Text.null trimmed → Left ("a level is required: " <> levelForms)
    | otherwise → Left (invalid "level" trimmed levelForms)
  where
    trimmed = Text.strip value

levelForms ∷ Text
levelForms = "expected debug, info, warn, warning, or error"

-- | Parse exact per-component thresholds: a comma-separated list of
-- @component=level@ pairs whose component name and level are each trimmed, for
-- example @gpu.vulkan=warn,lua=info@.
--
-- A missing @=@, an empty entry, an empty value, a component name
-- 'mkComponent' rejects — internal whitespace included — and a component key
-- that appears twice are all errors. Matching stays exact: a key is the
-- validated name and nothing is normalized.
parseComponentLevels ∷ Text → Either Text (Map Component LogLevel)
parseComponentLevels value = do
  entries ← splitList "override list" overrideForms value
  pairs ← traverse pair entries
  foldM insert Map.empty pairs
  where
    pair entry
      | Text.null rest = Left (invalid "override" entry "expected component=level")
      | otherwise = do
          component ← mkComponent (Text.strip name)
          level ← either (const (Left (invalid "override" entry levelForms))) Right
                    (parseLogLevel (Text.drop 1 rest))
          Right (component, level)
      where
        (name, rest) = Text.breakOn "=" entry

    insert known (component, level)
      | Map.member component known =
          Left (invalid "override list" (Text.strip value)
                 ("component " <> quoted (componentText component) <> " appears twice"))
      | otherwise = Right (Map.insert component level known)

overrideForms ∷ Text
overrideForms = "expected a comma-separated list of component=level pairs"

-- | Parse a Debug selection: exactly lowercase @none@, exactly lowercase
-- @all@, or a comma-separated component list in which a repeated name collapses
-- to one entry.
--
-- Any other spelling of either selector, a selector combined with component
-- names, an empty entry, an empty value, and a name 'mkComponent' rejects are
-- all errors.
parseDebugSelection ∷ Text → Either Text DebugSelection
parseDebugSelection value
  | trimmed == "none" = Right DebugNone
  | trimmed == "all" = Right DebugAll
  | selector trimmed =
      Left (invalid "Debug selection" trimmed
             "the selectors \"all\" and \"none\" are spelled in lowercase")
  | otherwise = do
      entries ← splitList "Debug selection" debugForms value
      case find selector entries of
        Just reserved →
          Left (invalid "Debug selection" trimmed
                 (quoted reserved <> " cannot be combined with component names"))
        Nothing → DebugComponents . Set.fromList <$> traverse mkComponent entries
  where
    trimmed = Text.strip value

debugForms ∷ Text
debugForms = "expected none, all, or a comma-separated component list"

-- | Whether text is one of the two reserved selectors in any spelling, which
-- is what separates a bad spelling from a component name.
selector ∷ Text → Bool
selector value = lowered == "all" || lowered == "none"
  where
    lowered = Text.toLower value

-- | Split a comma-separated value and trim each entry, rejecting an empty
-- value or an empty entry rather than dropping it.
splitList ∷ Text → Text → Text → Either Text [Text]
splitList kind forms value
  | Text.null trimmed = Left ("a " <> kind <> " is required: " <> forms)
  | any Text.null entries = Left (invalid kind trimmed "an entry is empty")
  | otherwise = Right entries
  where
    trimmed = Text.strip value
    entries = map Text.strip (Text.splitOn "," trimmed)

invalid ∷ Text → Text → Text → Text
invalid kind value reason = "invalid " <> kind <> " " <> quoted value <> ": " <> reason

-- | Assemble a 'LogFilter' from a base configuration and a lookup, consulting
-- each of the three names exactly once, in a fixed order, and before any value
-- is parsed.
--
-- An absent value keeps the base configuration's own. A present but invalid one
-- yields a message naming the variable it came from, and the first such
-- variable in that order is the one reported. That message is always one line:
-- the rejected value is quoted and escaped, so a value carrying a newline
-- cannot forge a second line of output. 'filterEnabled' and 'filterSource' are
-- carried through untouched: they stay programmatic configuration with no
-- variable of their own.
--
-- The lookup performs whatever IO reading the environment needs; this function
-- performs none of its own, so a test supplies a pure, exhaustive, or counting
-- lookup instead.
resolveLogFilter
  ∷ Monad m
  ⇒ LogVariables → (Text → m (Maybe Text)) → LogFilter → m (Either Text LogFilter)
resolveLogFilter names lookupValue base = do
  global ← lookupValue (variableGlobalLevel names)
  overrides ← lookupValue (variableComponentLevels names)
  debug ← lookupValue (variableDebug names)
  pure $ do
    level ←
      configured (variableGlobalLevel names) parseLogLevel (filterGlobalLevel base) global
    levels ←
      configured (variableComponentLevels names) parseComponentLevels
        (filterComponentLevels base) overrides
    selection ←
      configured (variableDebug names) parseDebugSelection (filterDebug base) debug
    Right base
      { filterGlobalLevel = level
      , filterComponentLevels = levels
      , filterDebug = selection
      }
  where
    configured name parse fallback =
      maybe (Right fallback) (either (Left . named name) Right . parse)
    named name reason = name <> ": " <> reason

-- | Whether a filter admits an entry at this level for this component, in the
-- order 'LogFilter' documents. It reads nothing but its arguments, so deciding
-- forces no payload and runs no metadata provider.
emits ∷ LogFilter → LogLevel → Component → Bool
emits configuration level component
  | not (filterEnabled configuration) = False
  | level == Debug = debugSelected (filterDebug configuration) component
  | otherwise = level >= threshold
  where
    threshold =
      Map.findWithDefault
        (filterGlobalLevel configuration)
        component
        (filterComponentLevels configuration)

debugSelected ∷ DebugSelection → Component → Bool
debugSelected DebugNone _ = False
debugSelected DebugAll _ = True
debugSelected (DebugComponents selected) component = Set.member component selected
