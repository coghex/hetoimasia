-- | The tick-assigned input log: its records, its text format, the writer that collects it and the parser that reads
-- it back with bounds, and the checks that decide, before a session starts, whether a log can be replayed (#500
-- requirements 3 and 4; D-23, D-45).
--
-- = What a record is
--
-- A record is something the session /accepted/, in exactly the terms its admission takes it, with the tick it was
-- accepted for and its place in that tick; never something merely offered. Two kinds exist, because the session has two
-- admission paths, each with its own places in a tick:
--
-- * an /intention/ (the queue's seam, @admitAt@): the tick, the place, whether it acted in the session that took it
--   (@current@) or in another (@foreign@: an identity is run-local, so a log never names one), the tick of the view it
--   acted on, the entity, the entity's version in that view, and the move's delta;
-- * a /control/ (the owner's logical admission, @requestInstanceControlAt@): the tick, the sequence place, the target
--   by its sample-local role (@gameplay@, the behavior of the gameplay owner; never an owner or instance identity,
--   which belong to a run) and the operation (@pause@ or @resume@).
--
-- An intention's places and a control's places are two spaces: the queue and the engine each hold their own, as they
-- did when the sample was delivered, so a control's sequence and an intention's place may be equal in one tick.
--
-- = The text format (version 1)
--
-- One line per record, ASCII, @\\n@-terminated, between a header and a trailer:
--
-- @
-- hetoimasia-lua-domains input log v1
-- control tick=4 place=0 target=gameplay op=pause
-- intent tick=5 place=0 session=current view=4 entity=3 version=0 dx=1 dy=-2
-- end records=2
-- @
--
-- Numbers are canonical decimals (no sign but @-@, no leading zero, no @-0@). The fields come in exactly this order.
-- Records are in /canonical order/: by tick, then the tick's controls by sequence, then its intentions by place, each
-- strictly increasing. The trailer carries the record count, so a log cut short at a record boundary is refused as
-- truncated and never read as a shorter complete one.
--
-- = Bounds
--
-- A header is at most 'maxHeaderBytes' bytes, a line at most 'maxLineBytes', a log at most 'maxRecords' records
-- ('maxLogBytes' in all). 'maxRecords' is a valid bounded session's most: 'maxSessionTicks' ticks, each taking at most
-- the default bounds' eight places and four controls. A session whose accepted records would pass it (a configuration
-- of larger bounds) leaves no log: the recorder says it overflowed, and never hands back one that is cut short.
--
-- A parser refuses a malformed, unordered, duplicated-place or over-bound line, the header or the trailer, whole, naming
-- the line, and never skips a line. What it says names fixed words and numbers, never text from the file.
module Hetoimasia.Sample.LuaDomains.InputLog
  ( -- * Records
    Record (..)
  , Acting (..)
  , ControlTarget (..)
  , ControlOp (..)
  , recordTick
  , recordKey
  , withinFormat
  , intentionRecord
  , intentionOf
    -- * Logs
  , InputLog
  , logRecords
  , logOf
  , emptyLog
  , byTick
    -- * The format
  , headerLine
  , renderLog
  , parseLog
  , parseLogWith
  , Limits (..)
  , defaultLimits
  , LogRefusal (..)
  , LogProblem (..)
  , refusalText
  , maxHeaderBytes
  , maxLineBytes
  , maxRecords
  , maxLogBytes
  , maxLogPlace
    -- * The writer
  , Recorder
  , newRecorder
  , appendRecord
  , appendRecordWith
  , assignControlRecord
  , acceptControl
  , refuseControl
  , noteUnrepresentableControl
  , recorderCount
  , recorderLog
  , RecordProblem (..)
  , recordProblemText
    -- * Can it be replayed
  , ReplayProblem (..)
  , checkReplayable
  , replayProblemText
  , maxProblemsListed
  ) where

import Control.DeepSeq (NFData (rnf))
import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Char8 as Char8
import qualified Data.ByteString.Lazy as Lazy
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word64)
import Hetoimasia.Sample.LuaDomains.Bounds (Bounds (boundPendingControls, boundPlaces, boundQueue), maxDeltaLimit, maxEntities, maxSessionTicks)
import Hetoimasia.Sample.LuaDomains.Intention (Intention (..), Placement (..), Refusal, Submitted (..), refusalReason, validate)

-- | Whether an intention acted in the session that took it.
data Acting = ActsCurrent | ActsForeign
  deriving (Eq, Show)

-- | A control's target, by role.
data ControlTarget = TargetGameplay
  deriving (Eq, Show)

-- | A control's operation.
data ControlOp = OpPause | OpResume
  deriving (Eq, Show)

-- | One accepted record.
data Record
  = -- | The place, whether it acted in this session, the tick of its view, the entity, its version and the delta.
    RecordIntention !Placement !Acting !Word64 !Int !Word64 !Int64 !Int64
  | -- | The tick, the sequence place, the target and the operation.
    RecordControl !Word64 !Word64 !ControlTarget !ControlOp
  deriving (Eq, Show)

instance NFData Record where
  rnf record = record `seq` ()

-- | The tick a record is for.
recordTick ∷ Record → Word64
recordTick = \case
  RecordIntention place _ _ _ _ _ _ → placeTick place
  RecordControl tick _ _ _ → tick

-- | Canonical order: the tick, then the controls, then the intentions, each by place.
recordKey ∷ Record → (Word64, Int, Word64)
recordKey = \case
  RecordIntention (Placement tick order) _ _ _ _ _ _ → (tick, 1, fromIntegral order)
  RecordControl tick sequence' _ _ → (tick, 0, sequence')

-- | The record of an accepted intention, as the session that took it (with this identity) saw it.
intentionRecord ∷ Word64 → Placement → Intention → Record
intentionRecord session place intention =
  RecordIntention
    place
    (if intentSession intention == session then ActsCurrent else ActsForeign)
    (intentTick intention)
    (intentEntity intention)
    (intentVersion intention)
    (intentDx intention)
    (intentDy intention)

-- | The placement and intention a record is, in the session with this identity: one that acted in another session acts
-- in an identity that is not this one. 'Nothing' for a control.
intentionOf ∷ Word64 → Record → Maybe (Placement, Intention)
intentionOf session = \case
  RecordIntention place acting view entity version dx dy →
    Just
      ( place
      , Intention
          { intentSession = case acting of ActsCurrent → session; ActsForeign → session + 1
          , intentTick = view
          , intentEntity = entity
          , intentVersion = version
          , intentDx = dx
          , intentDy = dy
          }
      )
  RecordControl {} → Nothing

-- Bounds --------------------------------------------------------------------------------

-- | The longest header, in bytes.
maxHeaderBytes ∷ Int
maxHeaderBytes = 64

-- | The longest line, in bytes: the longest record the format has is 112.
maxLineBytes ∷ Int
maxLineBytes = 128

-- | The most records a log holds: a valid bounded session's most ('maxSessionTicks' ticks of the default eight places and
-- four controls).
maxRecords ∷ Int
maxRecords = fromIntegral maxSessionTicks * 12

-- | The most bytes a log can have: a header, 'maxRecords' lines of 'maxLineBytes' and a trailer.
maxLogBytes ∷ Int
maxLogBytes = maxHeaderBytes + 1 + maxRecords * (maxLineBytes + 1) + 64

-- | The largest place or sequence a log names.
maxLogPlace ∷ Word64
maxLogPlace = 255

-- | Whether every field of a record is within what the format carries: the tick from one to the session bound, the
-- place and sequence to 'maxLogPlace', the view's tick to the session bound, the entity below the world's most and each
-- component of a delta within the largest bound a configuration may choose.
withinFormat ∷ Record → Bool
withinFormat = \case
  RecordIntention (Placement tick order) _ view entity _ dx dy →
    tickOk tick
      && fromIntegral order <= maxLogPlace
      && view <= maxSessionTicks
      && entity >= 0
      && entity < maxEntities
      && deltaOk dx
      && deltaOk dy
  RecordControl tick sequence' _ _ → tickOk tick && sequence' <= maxLogPlace
  where
    tickOk tick = tick >= 1 && tick <= maxSessionTicks
    deltaOk delta = delta >= negate limit && delta <= limit
    limit = fromIntegral maxDeltaLimit

-- Logs ---------------------------------------------------------------------------------

-- | A log: its records, in canonical order.
newtype InputLog = InputLog [Record]
  deriving (Eq, Show)

logRecords ∷ InputLog → [Record]
logRecords (InputLog records) = records

-- | A log of these records, put in canonical order (the order of equal keys kept).
logOf ∷ [Record] → InputLog
logOf = InputLog . sortOn recordKey

emptyLog ∷ InputLog
emptyLog = InputLog []

-- | The records of each tick, in canonical order: the tick's controls, then its intentions.
byTick ∷ InputLog → Map Word64 [Record]
byTick (InputLog records) = Map.fromListWith (flip (<>)) [(recordTick record, [record]) | record ← records]

-- The text format ------------------------------------------------------------------------

-- | The header's text, which names the format and its version.
headerLine ∷ ByteString
headerLine = "hetoimasia-lua-domains input log v1"

-- | The log as text: the header, a line for each record, and the trailer.
renderLog ∷ InputLog → Lazy.ByteString
renderLog (InputLog records) =
  Builder.toLazyByteString $
    Builder.byteString headerLine <> newline <> foldMap (\record → recordLine record <> newline) records <> Builder.string7 "end records=" <> Builder.intDec (length records) <> newline
  where
    newline = Builder.char7 '\n'

recordLine ∷ Record → Builder.Builder
recordLine = \case
  RecordIntention (Placement tick order) acting view entity version dx dy →
    Builder.string7 "intent tick="
      <> Builder.word64Dec tick
      <> Builder.string7 " place="
      <> Builder.word32Dec order
      <> Builder.string7 " session="
      <> Builder.string7 (case acting of ActsCurrent → "current"; ActsForeign → "foreign")
      <> Builder.string7 " view="
      <> Builder.word64Dec view
      <> Builder.string7 " entity="
      <> Builder.intDec entity
      <> Builder.string7 " version="
      <> Builder.word64Dec version
      <> Builder.string7 " dx="
      <> Builder.int64Dec dx
      <> Builder.string7 " dy="
      <> Builder.int64Dec dy
  RecordControl tick sequence' TargetGameplay op →
    Builder.string7 "control tick="
      <> Builder.word64Dec tick
      <> Builder.string7 " place="
      <> Builder.word64Dec sequence'
      <> Builder.string7 " target=gameplay op="
      <> Builder.string7 (case op of OpPause → "pause"; OpResume → "resume")

-- | Why a log was refused, and at which line (the first is line one).
data LogRefusal = LogRefusal
  { refusalLine ∷ !Int
  , refusalProblem ∷ !LogProblem
  }
  deriving (Eq, Show)

-- | What was wrong with the line.
data LogProblem
  = -- | Nothing at all.
    EmptyLog
  | -- | The first line is not this format's header.
    NotALog
  | -- | The header names a version this reader does not read.
    UnsupportedVersion
  | -- | The header is longer than 'maxHeaderBytes'.
    HeaderTooLong
  | -- | A line is longer than 'maxLineBytes'.
    LineTooLong
  | -- | A byte that is not printable ASCII, or a carriage return.
    NotPrintable
  | -- | The last line has no line terminator.
    MissingFinalNewline
  | -- | The line is no record: its shape, a keyword, a field name or a value that is not a canonical number or a word the
    -- format has.
    MalformedRecord
  | -- | A field is a number of the right shape that the format does not carry.
    OutOfBound
  | -- | A record sorts before the one above it.
    Unordered
  | -- | A record holds the tick and place the one above it holds, or the tick and sequence of an earlier control.
    DuplicatePlace
  | -- | More records than 'maxRecords'.
    TooManyRecords
  | -- | The log ends without its trailer.
    MissingTrailer
  | -- | The trailer's count is not the number of records read.
    TrailerMismatch
  | -- | Something follows the trailer.
    TextAfterTrailer
  deriving (Eq, Show)

-- | A refusal as one bounded line: fixed words and the line's number, never text from the file.
refusalText ∷ LogRefusal → Text
refusalText (LogRefusal line problem) = "line " <> Text.pack (show line) <> ": " <> why
  where
    why = case problem of
      EmptyLog → "the log is empty"
      NotALog → "not a hetoimasia-lua-domains input log"
      UnsupportedVersion → "an input log version this reader does not read"
      HeaderTooLong → "the header is longer than " <> number maxHeaderBytes <> " bytes"
      LineTooLong → "the line is longer than " <> number maxLineBytes <> " bytes"
      NotPrintable → "a byte that is not printable ASCII"
      MissingFinalNewline → "the last line has no line terminator"
      MalformedRecord → "not a record of the format"
      OutOfBound → "a value the format does not carry"
      Unordered → "a record out of canonical order"
      DuplicatePlace → "a place that another record holds"
      TooManyRecords → "more than " <> number maxRecords <> " records"
      MissingTrailer → "the log ends without its trailer: it is truncated"
      TrailerMismatch → "the trailer's count is not the number of records"
      TextAfterTrailer → "text after the trailer"
    number = Text.pack . show

-- | The three bounds a parser applies. The format's are 'defaultLimits'; a smaller set lets an example reach the bound
-- of a record count without a hundred megabytes of text.
data Limits = Limits
  { limitHeader ∷ !Int
  , limitLine ∷ !Int
  , limitRecords ∷ !Int
  }

defaultLimits ∷ Limits
defaultLimits = Limits maxHeaderBytes maxLineBytes maxRecords

-- | Read a log, refusing the first thing wrong with it, whole.
parseLog ∷ ByteString → Either LogRefusal InputLog
parseLog = parseLogWith defaultLimits

-- | 'parseLog' under these bounds.
parseLogWith ∷ Limits → ByteString → Either LogRefusal InputLog
parseLogWith limits bytes
  | ByteString.null bytes = Left (LogRefusal 1 EmptyLog)
  | otherwise = do
      let pieces = Char8.split '\n' bytes
          (terminated, final) = (init pieces, last pieces)
      case terminated of
        [] → Left (LogRefusal 1 (if ByteString.length final > limitHeader limits then HeaderTooLong else NotALog))
        header : rest → do
          checkHeader header
          InputLog <$> body final 2 Nothing [] 0 rest
  where
    checkHeader header
      | ByteString.length header > limitHeader limits = Left (LogRefusal 1 HeaderTooLong)
      | not (printable header) = Left (LogRefusal 1 NotPrintable)
      | header == headerLine = Right ()
      | Just digits ← ByteString.stripPrefix "hetoimasia-lua-domains input log v" header
      , not (ByteString.null digits)
      , Char8.all (\c → c >= '0' && c <= '9') digits =
          Left (LogRefusal 1 UnsupportedVersion)
      | otherwise = Left (LogRefusal 1 NotALog)
    -- The lines after the header: the records, then the trailer, which is last. The text after the last line terminator is
    -- what the file ends in: nothing, when it is whole.
    body ∷ ByteString → Int → Maybe (Word64, Int, Word64) → [Record] → Int → [ByteString] → Either LogRefusal [Record]
    body final line _ _ _ []
      | ByteString.null final = Left (LogRefusal line MissingTrailer)
      | ByteString.length final > limitLine limits = Left (LogRefusal line LineTooLong)
      | otherwise = Left (LogRefusal line MissingFinalNewline)
    body final line previous found count (this : rest)
      | ByteString.length this > limitLine limits = Left (LogRefusal line LineTooLong)
      | not (printable this) = Left (LogRefusal line NotPrintable)
      | "end " `ByteString.isPrefixOf` this = do
          claimed ← maybe (Left (LogRefusal line MalformedRecord)) Right (trailerCount this)
          if claimed /= toInteger count then Left (LogRefusal line TrailerMismatch) else Right ()
          if null rest && ByteString.null final then Right () else Left (LogRefusal (line + 1) TextAfterTrailer)
          pure (reverse found)
      | count >= limitRecords limits = Left (LogRefusal line TooManyRecords)
      | otherwise = do
          record ← either (Left . LogRefusal line) Right (parseRecord this)
          let key = recordKey record
          case previous of
            Just before
              | key == before → Left (LogRefusal line DuplicatePlace)
              | key < before → Left (LogRefusal line Unordered)
            _ → Right ()
          body final (line + 1) (Just key) (record : found) (count + 1) rest
    printable = ByteString.all (\byte → byte >= 32 && byte <= 126)
    -- The trailer is exactly @end records=@ and a canonical number.
    trailerCount line = ByteString.stripPrefix "end records=" line >>= decimalInteger

-- | The value of a @key=value@ token, if it is for this key.
keyed ∷ ByteString → ByteString → Maybe ByteString
keyed key token = ByteString.stripPrefix (key <> "=") token

-- | A canonical unsigned decimal: digits only, no leading zero but zero itself, at most twenty of them. It is read as an
-- 'Integer', so that a value too large for the field it is for is not wrapped into one that fits.
decimalInteger ∷ ByteString → Maybe Integer
decimalInteger text
  | ByteString.null text || ByteString.length text > 20 = Nothing
  | not (Char8.all (\c → c >= '0' && c <= '9') text) = Nothing
  | ByteString.length text > 1 && Char8.head text == '0' = Nothing
  | otherwise = Just (Char8.foldl' (\acc c → acc * 10 + toInteger (fromEnum c - 48)) 0 text)

-- | A canonical signed decimal: as 'decimalInteger', with an optional minus sign that zero does not take.
signed ∷ ByteString → Maybe Integer
signed text = case Char8.uncons text of
  Just ('-', digits) | digits /= "0" → negate <$> decimalInteger digits
  _ → decimalInteger text

-- | One record's line.
parseRecord ∷ ByteString → Either LogProblem Record
parseRecord line = case Char8.words line of
  ["intent", tickT, placeT, sessionT, viewT, entityT, versionT, dxT, dyT]
    | Char8.count ' ' line == 8 → do
        tick ← unsigned maxWord64 "tick" tickT
        order ← unsigned maxWord32 "place" placeT
        acting ← case keyed "session" sessionT of
          Just "current" → Right ActsCurrent
          Just "foreign" → Right ActsForeign
          _ → Left MalformedRecord
        view ← unsigned maxWord64 "view" viewT
        entity ← unsigned (toInteger (maxBound ∷ Int)) "entity" entityT
        version ← unsigned maxWord64 "version" versionT
        dx ← signedField "dx" dxT
        dy ← signedField "dy" dyT
        bounded
          ( RecordIntention
              (Placement (fromInteger tick) (fromInteger order))
              acting
              (fromInteger view)
              (fromInteger entity)
              (fromInteger version)
              dx
              dy
          )
  ["control", tickT, placeT, targetT, opT]
    | Char8.count ' ' line == 4 → do
        tick ← unsigned maxWord64 "tick" tickT
        sequence' ← unsigned maxWord64 "place" placeT
        target ← case keyed "target" targetT of
          Just "gameplay" → Right TargetGameplay
          _ → Left MalformedRecord
        op ← case keyed "op" opT of
          Just "pause" → Right OpPause
          Just "resume" → Right OpResume
          _ → Left MalformedRecord
        bounded (RecordControl (fromInteger tick) (fromInteger sequence') target op)
  _ → Left MalformedRecord
  where
    maxWord64 = toInteger (maxBound ∷ Word64)
    maxWord32 = toInteger (maxBound ∷ Word32)
    -- A canonical number that fits the field it is for; one that does not is a number the format does not carry.
    unsigned ∷ Integer → ByteString → ByteString → Either LogProblem Integer
    unsigned most name token = case keyed name token >>= decimalInteger of
      Nothing → Left MalformedRecord
      Just value
        | value <= most → Right value
        | otherwise → Left OutOfBound
    signedField name token = case keyed name token >>= signed of
      Nothing → Left MalformedRecord
      Just value
        | value >= toInteger (minBound ∷ Int64) && value <= toInteger (maxBound ∷ Int64) → Right (fromInteger value)
        | otherwise → Left OutOfBound
    bounded record = if withinFormat record then Right record else Left OutOfBound

-- The writer ----------------------------------------------------------------------------

-- | What the session has accepted so far, in the order it was accepted, until the log is read out. Its one owner is the
-- shared state's transactional variable: every admission appends in the transaction that admits, so a record is made
-- exactly once for each successful admission, in the order the admissions took effect, however many callers complete
-- concurrently; reading the log out puts them in canonical order.
data Recorder = Recorder
  { recorderRecords ∷ ![Record]
    -- ^ Newest first.
  , recorderCount ∷ !Int
  , recorderOverflowed ∷ !Bool
  , recorderUnrepresentable ∷ !Bool
  , recorderPending ∷ !(Maybe Record)
    -- ^ A control the application assigned a place whose acceptance by the engine it has not yet been told.
  , recorderUndecided ∷ !Bool
  }

newRecorder ∷ Recorder
newRecorder = Recorder [] 0 False False Nothing False

-- | Record an accepted record. One that the format cannot carry, or one past the log's bound, is not kept and is
-- remembered: the log cannot then be read out as complete.
appendRecord ∷ Record → Recorder → Recorder
appendRecord = appendRecordWith maxRecords

-- | 'appendRecord' for a log of at most this many records.
appendRecordWith ∷ Int → Record → Recorder → Recorder
appendRecordWith most record recorder
  | not (withinFormat record) = recorder {recorderUnrepresentable = True}
  | recorderCount recorder >= most = recorder {recorderOverflowed = True}
  | otherwise = recorder {recorderRecords = record : recorderRecords recorder, recorderCount = recorderCount recorder + 1}

-- | A control has been assigned its place and is awaiting the engine's answer. Another still awaiting one is a control
-- whose fate is not known, which the log cannot then claim to have all of.
assignControlRecord ∷ Record → Recorder → Recorder
assignControlRecord record recorder = case recorderPending recorder of
  Nothing → recorder {recorderPending = Just record}
  Just _ → recorder {recorderPending = Just record, recorderUndecided = True}

-- | The engine accepted the control that was awaiting its answer: it is recorded.
acceptControl ∷ Recorder → Recorder
acceptControl recorder = case recorderPending recorder of
  Nothing → recorder {recorderUndecided = True}
  Just record → appendRecord record recorder {recorderPending = Nothing}

-- | The engine refused the control that was awaiting its answer: nothing is recorded.
refuseControl ∷ Recorder → Recorder
refuseControl recorder = recorder {recorderPending = Nothing}

-- | A control was assigned that the format cannot name (another target or operation): the log cannot be complete.
noteUnrepresentableControl ∷ Recorder → Recorder
noteUnrepresentableControl recorder = recorder {recorderUnrepresentable = True}

-- | Why no log can be read out.
data RecordProblem
  = -- | More records were accepted than a log holds.
    LogOverflow
  | -- | A record the format cannot carry was accepted.
    NotRepresentable
  | -- | A control was assigned a place and the engine's answer to it was never told.
    ControlUndecided
  deriving (Eq, Show)

recordProblemText ∷ RecordProblem → Text
recordProblemText = \case
  LogOverflow → "more records were accepted than a log holds (" <> Text.pack (show maxRecords) <> ")"
  NotRepresentable → "a record the format cannot carry was accepted"
  ControlUndecided → "a control was assigned a place and its answer was never told"

-- | The log of everything accepted, in canonical order, or why there is none: it never hands back a log that has lost a
-- record.
recorderLog ∷ Recorder → Either RecordProblem InputLog
recorderLog recorder
  | recorderOverflowed recorder = Left LogOverflow
  | recorderUnrepresentable recorder = Left NotRepresentable
  | recorderUndecided recorder || recorderPending recorder /= Nothing = Left ControlUndecided
  | otherwise = Right (logOf (reverse (recorderRecords recorder)))

-- Can it be replayed -----------------------------------------------------------------------

-- | Why a log cannot be replayed in a session of this configuration, decided before the session starts from the log, the
-- tick limit and the scenario alone; what an execution does after it starts is not predicted here.
data ReplayProblem
  = -- | A record is for a tick after the session's last: the tick and the last.
    ReplayBeyondTicks !Word64 !Word64
  | -- | A record is for a tick after the one the scenario stops the session at: the tick and that tick.
    ReplayBeyondStop !Word64 !Word64
  | -- | A tick holds more intentions than the queue takes: the tick, how many, the most.
    ReplayTooManyIntentions !Word64 !Int !Int
  | -- | A tick holds more controls than the engine is given reservations for: the tick, how many, the most.
    ReplayTooManyControls !Word64 !Int !Int
  | -- | An intention's place is not one of the tick's places: the tick, the place, the number of places.
    ReplayPlaceBeyondBound !Word64 !Word32 !Int
  | -- | An intention the live path would have refused, outside the configured bounds: the tick, the place, the bound.
    ReplayOutsideBounds !Word64 !Word32 !Refusal
  | -- | Two records hold one place: the tick.
    ReplayDuplicate !Word64
  deriving (Eq, Show)

-- | The most problems 'checkReplayable' lists.
maxProblemsListed ∷ Int
maxProblemsListed = 8

-- | Every reason (the first 'maxProblemsListed') a log cannot be replayed under these bounds, up to this last tick (when
-- the session is finite) and, for a scenario that stops the session, up to this tick.
checkReplayable ∷ Bounds → Maybe Word64 → Maybe Word64 → InputLog → [ReplayProblem]
checkReplayable bounds final stopAfter log' = take maxProblemsListed (concatMap perTick (Map.toAscList (byTick log')))
  where
    intentionsMost = min (boundPlaces bounds) (boundQueue bounds)
    controlsMost = boundPendingControls bounds
    perTick (tick, records) =
      [ReplayBeyondTicks tick last' | Just last' ← [final], tick > last']
        <> [ReplayBeyondStop tick stop | Just stop ← [stopAfter], tick > stop]
        <> [ReplayTooManyIntentions tick (length intentions) intentionsMost | length intentions > intentionsMost]
        <> [ReplayTooManyControls tick (length controls) controlsMost | length controls > controlsMost]
        <> [ReplayDuplicate tick | duplicated (map recordKey records)]
        <> concat
          [ [ReplayPlaceBeyondBound tick order (boundPlaces bounds) | fromIntegral order >= boundPlaces bounds]
              <> [ReplayOutsideBounds tick order refusal | Left refusal ← [validate bounds (submitted intention)]]
          | RecordIntention (Placement _ order) _ view entity version dx dy ← records
          , let intention = (view, entity, version, dx, dy)
          ]
      where
        intentions = [() | RecordIntention {} ← records]
        controls = [() | RecordControl {} ← records]
    submitted (view, entity, version, dx, dy) = Submitted 0 (fromIntegral view) (fromIntegral entity) (fromIntegral version) dx dy
    duplicated keys = or (zipWith (==) keys (drop 1 keys))

-- | One bounded line for a problem: fixed words and numbers.
replayProblemText ∷ ReplayProblem → Text
replayProblemText = \case
  ReplayBeyondTicks tick final → "a record for tick " <> n tick <> ", after the session's last tick " <> n final
  ReplayBeyondStop tick stop → "a record for tick " <> n tick <> ", after the tick " <> n stop <> " the scenario stops the session at"
  ReplayTooManyIntentions tick found most → "tick " <> n tick <> " holds " <> n found <> " intentions, and the queue takes " <> n most <> " for a tick"
  ReplayTooManyControls tick found most → "tick " <> n tick <> " holds " <> n found <> " controls, and the engine holds reservations for " <> n most <> " for a tick"
  ReplayPlaceBeyondBound tick order places → "tick " <> n tick <> " place " <> n order <> " is not one of the tick's " <> n places <> " places"
  ReplayOutsideBounds tick order refusal → "tick " <> n tick <> " place " <> n order <> " is outside the configured bounds: " <> refusalReason refusal
  ReplayDuplicate tick → "tick " <> n tick <> " holds one place twice"
  where
    n ∷ (Show a) ⇒ a → Text
    n = Text.pack . show
