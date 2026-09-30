-- | Record preparation for "Hetoimasia.Runtime.AsyncLog": the retained-text
-- budget and collection limits, the truncation marker, and the bounded,
-- detached copy of an entry the adapter queues.
--
-- Everything here is pure and uses log-entry and 'Text' data alone, never the
-- adapter's state, writer, or borrowed sink. That purity does not choose where
-- the work happens: the adapter's admission evaluates 'forceEntry' over
-- 'boundEntry' on the producer thread, before its enqueueing transaction, so no
-- record reaching the queue is a deferred copy over a producer's buffers.
--
-- This module is private to the runtime library. The adapter re-exports its
-- public constants; the module header there and @docs/logging.md@,
-- \"Asynchronous adapter\", state the retention and truncation contract.
module Hetoimasia.Runtime.AsyncLog.Entry
  ( -- * Bounds
    minimumTextBudget
  , maximumTextBudget
  , maxRetainedFields
  , maxRetainedBreadcrumbs

    -- * Truncation
  , truncationComponent
  , truncationField
  , Truncation
  , truncated

    -- * Preparation
  , boundEntry
  , forceEntry
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Foreign (lengthWord8)
import Hetoimasia.Foundation.Log
  ( Component
  , LogEntry (..)
  , SourceLocation (..)
  , componentText
  , mkComponent
  , unsafeComponent
  )

-- Bounds ----------------------------------------------------------------------

-- | The smallest retained-text budget an adapter accepts. The truncation
-- marker's maximum size and 'truncationComponent' both fit inside it, so a
-- record is still admitted here.
minimumTextBudget ∷ Int
minimumTextBudget = 256

-- | The largest retained-text budget an adapter accepts.
maximumTextBudget ∷ Int
maximumTextBudget = 65536

-- | Field entries one queued record retains, counting entries with empty text.
-- On a truncated record the adapter's own 'truncationField' marker is one of
-- them, so at most one fewer producer field survives there.
maxRetainedFields ∷ Int
maxRetainedFields = 64

-- | Breadcrumbs one queued record retains, counting empty ones.
maxRetainedBreadcrumbs ∷ Int
maxRetainedBreadcrumbs = 32

-- Truncation ------------------------------------------------------------------

-- | The valid component a record carries when its own component does not fit.
truncationComponent ∷ Component
truncationComponent = unsafeComponent "log.truncated"

-- | The reserved field key carrying the truncation marker. A producer field of
-- this name is the adapter's to write: it is removed at admission, and its
-- removal is itself counted as a dropped field.
truncationField ∷ Text
truncationField = "log.truncated"

-- | The marker's largest rendered size in bytes, key included, reserved inside
-- the budget whenever a record is truncated. Each count renders in at most five
-- bytes, clamped to @9999+@ beyond four digits.
markerReserve ∷ Int
markerReserve = 64

-- | Which categories a record lost text from, and how much.
data Truncation = Truncation
  { lostMessage ∷ !Bool
  , lostComponent ∷ !Bool
  , lostFields ∷ !Int
  , lostBreadcrumbs ∷ !Int
  , lostThread ∷ !Bool
  , lostSource ∷ !Bool
  }

noTruncation ∷ Truncation
noTruncation = Truncation False False 0 0 False False

truncated ∷ Truncation → Bool
truncated note =
  lostMessage note
    || lostComponent note
    || lostFields note > 0
    || lostBreadcrumbs note > 0
    || lostThread note
    || lostSource note

-- | The marker's value: the affected categories in a fixed order, with the
-- dropped counts for the two collections.
renderMarker ∷ Truncation → Text
renderMarker note = Text.intercalate "," (concat parts)
  where
    parts =
      [ ["msg" | lostMessage note]
      , ["cmp" | lostComponent note]
      , ["fields=" <> count (lostFields note) | lostFields note > 0]
      , ["crumbs=" <> count (lostBreadcrumbs note) | lostBreadcrumbs note > 0]
      , ["thread" | lostThread note]
      , ["source" | lostSource note]
      ]
    count value
      | value > 9999 = "9999+"
      | otherwise = Text.pack (show value)

-- Bounded retention -----------------------------------------------------------------

-- | UTF-8 bytes of a text, which is what the budget counts.
byteLength ∷ Text → Int
byteLength = lengthWord8

-- | The longest whole-code-point prefix fitting in @limit@ bytes.
takeBytes ∷ Int → Text → Text
takeBytes limit text
  | limit <= 0 = Text.empty
  | byteLength text <= limit = text
  | otherwise = Text.take (fitting 0 0 text) text
  where
    fitting characters used rest = case Text.uncons rest of
      Nothing → characters
      Just (character, more)
        | used + utf8Width character > limit → characters
        | otherwise → fitting (characters + 1) (used + utf8Width character) more

utf8Width ∷ Char → Int
utf8Width character
  | point < 0x80 = 1
  | point < 0x800 = 2
  | point < 0x10000 = 3
  | otherwise = 4
  where
    point = fromEnum character

-- | Detach a text from the producer's buffer, so retaining a short slice cannot
-- keep an oversized array alive.
detach ∷ Text → Text
detach = Text.copy

-- | The bounded copy of an entry, and what it lost.
--
-- A record already inside every bound keeps its text verbatim, copied. Anything
-- else reserves the marker's maximum size and then fits the members in
-- attribution order: component, thread, source, fields, breadcrumbs, and last
-- the message, which is the one member that shortens gracefully. So what
-- survives at a small budget is what identifies the record, and the message is
-- reduced as far as empty text rather than costing the record its context.
boundEntry ∷ Int → LogEntry → (LogEntry, Truncation)
boundEntry budget entry
  | fitsVerbatim = (verbatim, noTruncation)
  | otherwise = (bounded, note)
  where
    supplied = Map.delete truncationField (entryFields entry)
    reservedTaken = Map.size supplied /= Map.size (entryFields entry)
    suppliedFields = Map.toAscList supplied
    fieldCount = Map.size (entryFields entry)
    crumbCount = length (entryBreadcrumbs entry)
    component = entryComponent entry

    verbatimBytes =
      byteLength (entryMessage entry)
        + byteLength (componentText component)
        + sum [byteLength key + byteLength value | (key, value) ← suppliedFields]
        + sum (map byteLength (entryBreadcrumbs entry))
        + byteLength (entryThread entry)
        + maybe 0 sourceBytes (entrySource entry)
    fitsVerbatim =
      not reservedTaken
        && fieldCount <= maxRetainedFields
        && crumbCount <= maxRetainedBreadcrumbs
        && verbatimBytes <= budget

    verbatim = entry
      { entryComponent = detachComponent component
      , entryMessage = detach (entryMessage entry)
      , entryFields = Map.fromList [(detach key, detach value) | (key, value) ← suppliedFields]
      , entryBreadcrumbs = map detach (entryBreadcrumbs entry)
      , entryThread = detach (entryThread entry)
      , entrySource = detachSource <$> entrySource entry
      }

    allowance = max 0 (budget - markerReserve)

    (keptComponent, componentLost, afterComponent)
      | byteLength (componentText component) <= allowance =
          (detachComponent component, False, allowance - byteLength (componentText component))
      | otherwise =
          ( truncationComponent
          , True
          , max 0 (allowance - byteLength (componentText truncationComponent))
          )

    keptThread = detach (takeBytes afterComponent (entryThread entry))
    threadLost = byteLength keptThread < byteLength (entryThread entry)
    afterThread = afterComponent - byteLength keptThread

    (keptSource, sourceLost, afterSource) = case entrySource entry of
      Nothing → (Nothing, False, afterThread)
      Just location
        | sourceBytes location <= afterThread →
            (Just (detachSource location), False, afterThread - sourceBytes location)
        | otherwise → (Nothing, True, afterThread)

    -- One of the retained entries is the marker this record is about to carry.
    (keptFields, afterFields) =
      fitPairs afterSource (take (maxRetainedFields - 1) suppliedFields)
    (keptCrumbs, afterCrumbs) =
      fitTexts afterFields (take maxRetainedBreadcrumbs (entryBreadcrumbs entry))

    keptMessage = detach (takeBytes afterCrumbs (entryMessage entry))
    messageLost = byteLength keptMessage < byteLength (entryMessage entry)

    note = Truncation
      { lostMessage = messageLost
      , lostComponent = componentLost
      , lostFields = fieldCount - length keptFields
      , lostBreadcrumbs = crumbCount - length keptCrumbs
      , lostThread = threadLost
      , lostSource = sourceLost
      }

    bounded = entry
      { entryComponent = keptComponent
      , entryMessage = keptMessage
      , entryFields = Map.insert truncationField (renderMarker note) (Map.fromList keptFields)
      , entryBreadcrumbs = keptCrumbs
      , entryThread = keptThread
      , entrySource = keptSource
      }

sourceBytes ∷ SourceLocation → Int
sourceBytes location = byteLength (sourceFile location) + byteLength (sourceFunction location)

detachSource ∷ SourceLocation → SourceLocation
detachSource location = location
  { sourceFile = detach (sourceFile location)
  , sourceFunction = detach (sourceFunction location)
  }

-- | Re-validating the copied name keeps the component opaque and forces the
-- copy; a name that was valid stays valid, so the fallback is unreachable.
detachComponent ∷ Component → Component
detachComponent component =
  either (const truncationComponent) id (mkComponent (detach (componentText component)))

-- | Keep the leading entries whose key and value both fit, detached; stop at the
-- first that does not, so what is kept is a prefix rather than a selection.
fitPairs ∷ Int → [(Text, Text)] → ([(Text, Text)], Int)
fitPairs remaining [] = ([], remaining)
fitPairs remaining ((key, value) : rest)
  | needed > remaining = ([], remaining)
  | otherwise =
      let (kept, left) = fitPairs (remaining - needed) rest
       in ((detach key, detach value) : kept, left)
  where
    needed = byteLength key + byteLength value

fitTexts ∷ Int → [Text] → ([Text], Int)
fitTexts remaining [] = ([], remaining)
fitTexts remaining (text : rest)
  | needed > remaining = ([], remaining)
  | otherwise =
      let (kept, left) = fitTexts (remaining - needed) rest
       in (detach text : kept, left)
  where
    needed = byteLength text

-- | Complete every retained copy before the record is published, so nothing
-- reaching the queue is still a deferred slice of a producer's buffer.
forceEntry ∷ LogEntry → LogEntry
forceEntry entry =
  componentText (entryComponent entry)
    `seq` entryMessage entry
    `seq` entryThread entry
    `seq` forceFields (entryFields entry)
    `seq` maybe () forceSource (entrySource entry)
    `seq` crumbs
    `seq` entry { entryBreadcrumbs = crumbs }
  where
    crumbs = forceTexts (entryBreadcrumbs entry)

forceFields ∷ Map Text Text → ()
forceFields = Map.foldlWithKey' (\() key value → key `seq` value `seq` ()) ()

forceSource ∷ SourceLocation → ()
forceSource location = sourceFile location `seq` sourceFunction location `seq` ()

-- | Forcing the result walks the whole spine: each step forces its own tail,
-- which is another call to this function.
forceTexts ∷ [Text] → [Text]
forceTexts [] = []
forceTexts (text : rest) = text `seq` rest' `seq` (text : rest')
  where
    rest' = forceTexts rest
