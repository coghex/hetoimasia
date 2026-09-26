-- | The deterministic one-line text layout of a log record, and the rule that
-- decides when a piece of text in it is written bare or quoted.
--
-- The escaping inside quotes is 'Hetoimasia.Foundation.Log.Component.quoted',
-- the one implementation every logging diagnostic also uses. The public facade
-- is "Hetoimasia.Foundation.Log", which re-exports 'formatEntry'; this module
-- is private to the foundation package.
module Hetoimasia.Foundation.Log.Format
  ( formatEntry
  ) where

import Data.Char (isPrint, isSpace)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time.Clock (UTCTime (utctDayTime), diffTimeToPicoseconds)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Hetoimasia.Foundation.Log.Base (FormatOptions (..), LogLevel (..), SourceLocation (..))
import Hetoimasia.Foundation.Log.Component (componentText, quoted)
import Hetoimasia.Foundation.Log.Types (LogEntry (..))

-- | Render one entry as exactly one line, with no terminating newline: a sink
-- adds its own record terminator. Segments are separated by single spaces and
-- an absent optional segment is omitted entirely.
--
-- > <time> <LEVEL> <component> thread=<n> [src=<file>:<line>] [crumbs=<a>><b>] msg=<message> [<key>=<value> ...]
--
-- The time is UTC as ISO 8601 with exactly three fractional digits, truncating
-- finer precision, and a @Z@ suffix. @src=@ appears only for an entry carrying
-- a source location and @crumbs=@ only when there is at least one breadcrumb.
-- Fields follow the message, sorted by key.
--
-- Every piece of text in a record — message, breadcrumb, field key, field
-- value, source filename, and thread — goes through one rule, so nothing a
-- caller supplies can split a record or forge a segment. Text is written bare
-- when it is nonempty and holds only printable non-space characters other than
-- the four the layout reserves:
--
-- > " \ = >
--
-- Anything else is double-quoted, with these escapes inside the quotes:
--
-- > \" \\ \n \r \t
--
-- and every other control character written as a backslash, a @u@, and four
-- uppercase hex digits. Empty text renders as a pair of quotes.
--
-- A component name is validated before it can reach an entry, so it is always
-- bare. A field key is not, so it follows the same rule as everything else:
-- ordinary keys are bare, and only a key that would otherwise disturb the
-- layout is quoted.
formatEntry ∷ FormatOptions → LogEntry → Text
formatEntry options entry = Text.intercalate " " (concat parts)
  where
    parts =
      [ [formatTimestamp (entryTime entry)]
      , [levelName (entryLevel entry)]
      , [componentText (entryComponent entry)]
      , ["thread=" <> renderText (entryThread entry) | formatThread options]
      , foldMap (pure . sourceSegment) (entrySource entry)
      , [crumbSegment (entryBreadcrumbs entry) | not (null (entryBreadcrumbs entry))]
      , ["msg=" <> renderText (entryMessage entry)]
      , [ renderText key <> "=" <> renderText value
        | (key, value) ← Map.toAscList (entryFields entry)
        ]
      ]

    sourceSegment location =
      "src=" <> renderText (sourceFile location)
        <> ":" <> Text.pack (show (sourceLine location))

    crumbSegment crumbs = "crumbs=" <> Text.intercalate ">" (map renderText crumbs)

-- | UTC as ISO 8601 with millisecond precision. Sub-millisecond precision is
-- truncated rather than rounded, so the rendering of a timestamp never depends
-- on digits the layout does not show.
formatTimestamp ∷ UTCTime → Text
formatTimestamp time =
  Text.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S" time)
    <> "." <> Text.justifyRight 3 '0' (Text.pack (show milliseconds))
    <> "Z"
  where
    milliseconds =
      (diffTimeToPicoseconds (utctDayTime time) `mod` 1000000000000) `div` 1000000000

-- | A text value as one layout segment: bare when that cannot disturb the
-- layout, and double-quoted with escapes otherwise.
renderText ∷ Text → Text
renderText value
  | not (Text.null value) && Text.all bare value = value
  | otherwise = quoted value
  where
    bare character =
      isPrint character
        && not (isSpace character)
        && character /= '"'
        && character /= '\\'
        && character /= '='
        && character /= '>'

levelName ∷ LogLevel → Text
levelName Debug = "DEBUG"
levelName Info = "INFO"
levelName Warning = "WARN"
levelName Error = "ERROR"
