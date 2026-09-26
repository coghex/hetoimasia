-- | The validated 'Component' name, its constructors and operations, and the
-- quoting every logging diagnostic and record shares.
--
-- The constructor stays inside this module, so every component in an entry, a
-- filter, or a failure origin has passed 'mkComponent'. 'quoted' lives here
-- rather than with the record layout because component validation needs it to
-- name the text it rejected, and the filter diagnostics and the record layout
-- in "Hetoimasia.Foundation.Log.Filter" and "Hetoimasia.Foundation.Log.Format"
-- reuse this one implementation. The public facade is
-- "Hetoimasia.Foundation.Log"; this module is private to the foundation
-- package.
module Hetoimasia.Foundation.Log.Component
  ( -- * Components
    Component
  , mkComponent
  , unsafeComponent
  , componentText

    -- * Quoting
  , quoted
  ) where

import Data.Char (isAsciiLower, isControl, isDigit, ord)
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Stack (HasCallStack)

-- | A validated component name: one or more nonempty segments matching
-- @[a-z][a-z0-9_-]*@ joined by @.@, for example @gpu.vulkan@ or @game.world@.
--
-- Matching is exact everywhere — there is no hierarchy, registry, or central
-- enum — so @gpu@ and @gpu.vulkan@ are unrelated names. Build one with
-- 'mkComponent'; the constructor is private so every component in an entry or
-- a filter has been validated.
newtype Component = Component Text
  deriving (Eq, Ord, Show)

-- | Validate a component name, rejecting an invalid one with a descriptive
-- message rather than normalizing it. The standalone names @all@ and @none@
-- are rejected because they are reserved
-- 'Hetoimasia.Foundation.Log.DebugSelection' spellings.
mkComponent ∷ Text → Either Text Component
mkComponent name
  | name == "all" || name == "none" =
      Left (rejected name "\"all\" and \"none\" are reserved Debug selectors")
  | Text.null name =
      Left (rejected name "a component name needs at least one segment")
  | any Text.null segments =
      Left (rejected name "every dot-separated segment must be nonempty")
  | Just bad ← find (not . validSegment) segments =
      Left (rejected name ("segment " <> quoted bad <> " must match [a-z][a-z0-9_-]*"))
  | otherwise = Right (Component name)
  where
    segments = Text.splitOn "." name

-- | Build a component from a name that is a literal in the source, failing
-- loudly with 'mkComponent'''s message when it is invalid. Use 'mkComponent'
-- for any name that comes from configuration, a file, or a user.
unsafeComponent ∷ HasCallStack ⇒ Text → Component
unsafeComponent name = either (error . Text.unpack) id (mkComponent name)

-- | The validated name, as it is matched and printed.
componentText ∷ Component → Text
componentText (Component name) = name

validSegment ∷ Text → Bool
validSegment segment = case Text.uncons segment of
  Nothing → False
  Just (leading, rest) → isAsciiLower leading && Text.all validTail rest
  where
    validTail character =
      isAsciiLower character || isDigit character || character == '_' || character == '-'

rejected ∷ Text → Text → Text
rejected name reason = "invalid component name " <> quoted name <> ": " <> reason

-- | Text as a double-quoted, escaped literal inside a message. Every diagnostic
-- that names text it rejected goes through this, so a value carrying a newline,
-- a quote, or any other control character cannot split the message across lines
-- or forge a second one. It is the same escaping the record layout applies (see
-- 'Hetoimasia.Foundation.Log.formatEntry'), and ordinary text is unchanged
-- inside the quotes.
quoted ∷ Text → Text
quoted value = "\"" <> Text.concatMap escaped value <> "\""

escaped ∷ Char → Text
escaped '"' = "\\\""
escaped '\\' = "\\\\"
escaped '\n' = "\\n"
escaped '\r' = "\\r"
escaped '\t' = "\\t"
escaped character
  | isControl character = "\\u" <> hex4 (ord character)
  | otherwise = Text.singleton character

hex4 ∷ Int → Text
hex4 value = Text.pack (map nibble [4096, 256, 16, 1])
  where
    nibble place = "0123456789ABCDEF" !! ((value `div` place) `mod` 16)
