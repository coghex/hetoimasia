-- | The tick-assigned input log: its text format, the writer and the parser (#500 requirement 3).
--
-- The format is pinned line by line; the parser's every refusal is shown, each with the line it names; the writer's
-- output is shown to parse back to what was written, to hold one record for each successful admission in tick and place
-- order even when the admissions are raced, to leave out whatever was only offered, and never to hand back a log that has
-- lost a record.
module Test.Domains.InputLog (spec) where

import Control.Concurrent (yield)
import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVarIO, writeTVar)
import Control.Monad (forM, forM_, unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import qualified Data.ByteString.Lazy as Lazy
import Data.List (sort)
import Data.Word (Word64)
import Hetoimasia.Sample.LuaDomains (Bounds (boundPlaces, boundQueue), defaultBounds)
import Hetoimasia.Sample.LuaDomains.InputLog
import Hetoimasia.Sample.LuaDomains.Intention (Answer (..), FullCause (..), Intention (..), Placement (..), Refusal (RefusedEntity), Submitted (Submitted))
import Hetoimasia.Sample.LuaDomains.Queue (AdmitAt (..), closeQueue, seal, settle)
import Hetoimasia.Sample.LuaDomains.Shared (Shared (sharedCounts, sharedQueue, sharedRecorder), admitLogged, submit)
import Hetoimasia.Sample.LuaDomains.Tally (Counts (countAccepted, countDeclined))
import Test.Domains.Support
import Test.Hspec

-- | Every kind of record, and the extremes the format carries.
sample ∷ [Record]
sample =
  [ RecordControl 4 0 TargetGameplay OpPause
  , RecordIntention (Placement 5 0) ActsCurrent 4 3 0 1 (-2)
  , RecordIntention (Placement 5 1) ActsForeign 4 3 1 (-8) 8
  , RecordControl 9 0 TargetGameplay OpResume
  , RecordControl 9 1 TargetGameplay OpPause
  , RecordIntention (Placement 9 0) ActsCurrent 8 0 0 0 0
  , RecordIntention (Placement 9 255) ActsCurrent 100000 63 maxBound 1000 (-1000)
  ]

sampleText ∷ [ByteString]
sampleText =
  [ "hetoimasia-lua-domains input log v1"
  , "control tick=4 place=0 target=gameplay op=pause"
  , "intent tick=5 place=0 session=current view=4 entity=3 version=0 dx=1 dy=-2"
  , "intent tick=5 place=1 session=foreign view=4 entity=3 version=1 dx=-8 dy=8"
  , "control tick=9 place=0 target=gameplay op=resume"
  , "control tick=9 place=1 target=gameplay op=pause"
  , "intent tick=9 place=0 session=current view=8 entity=0 version=0 dx=0 dy=0"
  , "intent tick=9 place=255 session=current view=100000 entity=63 version=18446744073709551615 dx=1000 dy=-1000"
  , "end records=7"
  ]

lined ∷ [ByteString] → ByteString
lined = ByteString.concat . map (<> "\n")

header ∷ ByteString
header = "hetoimasia-lua-domains input log v1"

oneIntent ∷ ByteString
oneIntent = "intent tick=2 place=0 session=current view=1 entity=0 version=0 dx=1 dy=2"

-- | A log of a header, these records and a trailer that counts them.
logOfLines ∷ [ByteString] → ByteString
logOfLines records = lined ([header] <> records <> ["end records=" <> Char8.pack (show (length records))])

-- | A record line with one field replaced.
intentWith ∷ ByteString → ByteString → ByteString
intentWith field value = Char8.unwords [if key == field then field <> "=" <> value else token | token ← Char8.words oneIntent, let key = Char8.takeWhile (/= '=') token]

controlLine ∷ ByteString
controlLine = "control tick=4 place=0 target=gameplay op=pause"

refusal ∷ ByteString → Int → LogProblem → Expectation
refusal text line problem = parseLog text `shouldBe` Left (LogRefusal line problem)

spec ∷ Spec
spec = describe "the input log" $ do
  describe "the format" $ do
    it "writes a header, one line for each record in canonical order, and a trailer that counts them" $
      Lazy.toStrict (renderLog (logOf sample)) `shouldBe` lined sampleText

    it "reads what it wrote: every record, exactly, and the header and trailer of an empty log" $ do
      parseLog (lined sampleText) `shouldBe` Right (logOf sample)
      parseLog (Lazy.toStrict (renderLog (logOf sample))) `shouldBe` Right (logOf sample)
      parseLog (Lazy.toStrict (renderLog emptyLog)) `shouldBe` Right emptyLog
      logRecords <$> parseLog (lined sampleText) `shouldBe` Right sample

    it "puts records in canonical order whatever order they were given in: by tick, the controls before the intentions, each by place" $
      logRecords (logOf (reverse sample)) `shouldBe` sample

    it "names a control's target by its role and never by an owner or an instance identity" $ do
      let text = Lazy.toStrict (renderLog (logOf sample))
      [line | line ← Char8.lines text, "control" `ByteString.isPrefixOf` line, not ("target=gameplay" `ByteString.isInfixOf` line)] `shouldBe` []
      forM_ ["owner", "instance", "runtime", "id="] $ \word → ByteString.isInfixOf word text `shouldBe` False

    it "keeps an intention's place and a control's sequence apart: both may be zero in one tick" $
      parseLog (logOfLines [controlLine, "intent tick=4 place=0 session=current view=3 entity=0 version=0 dx=0 dy=0"])
        `shouldSatisfy` either (const False) ((== 2) . length . logRecords)

  describe "the parser" $ do
    it "refuses a log with nothing in it" $
      refusal "" 1 EmptyLog

    it "refuses what is no log, and a version it does not read" $ do
      refusal "not a log\n" 1 NotALog
      refusal "\n" 1 NotALog
      refusal (lined ["hetoimasia-lua-domains input log v2", "end records=0"]) 1 UnsupportedVersion
      refusal (lined ["hetoimasia-lua-domains input log v", "end records=0"]) 1 NotALog
      refusal (lined ["hetoimasia-lua-domains input log v10", "end records=0"]) 1 UnsupportedVersion
      refusal (lined [header <> " ", "end records=0"]) 1 NotALog
      refusal (lined ["hetoimasia-lua-domains input log v1x", "end records=0"]) 1 NotALog

    it "refuses a header longer than its bound, and a line longer than its bound, naming the line" $ do
      refusal (lined [header <> ByteString.replicate (maxHeaderBytes + 1 - ByteString.length header) 32, "end records=0"]) 1 HeaderTooLong
      refusal (lined [header, ByteString.replicate (maxLineBytes + 1) 120, "end records=0"]) 2 LineTooLong
      refusal (lined [header, oneIntent, ByteString.replicate (maxLineBytes + 1) 120, "end records=1"]) 3 LineTooLong
      -- A line at the bound is not one too long: it is refused for what it is.
      refusal (lined [header, ByteString.replicate maxLineBytes 120, "end records=0"]) 2 MalformedRecord
      -- A last line with no terminator that is too long is too long, not unterminated.
      refusal (header <> "\n" <> ByteString.replicate (maxLineBytes + 1) 120) 2 LineTooLong

    it "refuses a byte that is not printable ASCII, a carriage return among them, and a last line with no terminator" $ do
      refusal (lined [header, oneIntent <> "\t", "end records=1"]) 2 NotPrintable
      refusal (lined [header, oneIntent <> "\r", "end records=1"]) 2 NotPrintable
      refusal (lined [header, oneIntent <> ByteString.pack [0xC3, 0xA9], "end records=1"]) 2 NotPrintable
      refusal (lined [header <> "\NUL", "end records=0"]) 1 NotPrintable
      refusal (header <> "\n" <> oneIntent <> "\nend records=1") 3 MissingFinalNewline
      refusal header 1 NotALog

    it "refuses a log cut short, at a record boundary or inside a line, as truncated: never as a shorter complete one" $ do
      refusal (header <> "\n") 2 MissingTrailer
      refusal (lined [header, oneIntent]) 3 MissingTrailer
      refusal (header <> "\n" <> oneIntent <> "\nend rec") 3 MissingFinalNewline
      refusal (lined [header, oneIntent, "end rec"]) 3 MalformedRecord
      forM_ [1 .. length sampleText - 2] $ \kept →
        refusal (lined (take kept sampleText)) (kept + 1) MissingTrailer

    it "refuses a trailer that does not count the records, and anything after it" $ do
      refusal (lined [header, oneIntent, "end records=2"]) 3 TrailerMismatch
      refusal (lined [header, "end records=1"]) 2 TrailerMismatch
      refusal (lined [header, oneIntent, "end records=1", oneIntent]) 4 TextAfterTrailer
      refusal (lined [header, oneIntent, "end records=1", ""]) 4 TextAfterTrailer
      refusal (lined [header, oneIntent, "end records=01"]) 3 MalformedRecord
      refusal (lined [header, oneIntent, "end records=x"]) 3 MalformedRecord
      refusal (lined [header, oneIntent, "end"]) 3 MalformedRecord
      refusal (lined [header, oneIntent, "end  records=1"]) 3 MalformedRecord

    mapM_
      ( \(label, line) →
          it ("refuses a line that is not a record: " <> label) $
            refusal (logOfLines [oneIntent, line]) 3 MalformedRecord
      )
      [ ("another keyword", "move tick=2 place=1 session=current view=1 entity=0 version=0 dx=1 dy=2")
      , ("a missing field", "intent tick=2 place=1 session=current view=1 entity=0 version=0 dx=1")
      , ("an extra field", oneIntent <> " dz=0")
      , ("fields in another order", "intent place=1 tick=2 session=current view=1 entity=0 version=0 dx=1 dy=2")
      , ("two spaces between fields", "intent  tick=2 place=1 session=current view=1 entity=0 version=0 dx=1 dy=2")
      , ("a leading zero", intentWith "tick" "02")
      , ("a leading plus", intentWith "dx" "+1")
      , ("a negative zero", intentWith "dx" "-0")
      , ("a double minus", intentWith "dy" "--1")
      , ("a value that is no number", intentWith "tick" "x")
      , ("an empty value", intentWith "entity" "")
      , ("a number with a letter in it", intentWith "version" "1a")
      , ("a number of more than twenty digits", intentWith "view" (ByteString.replicate 21 49))
      , ("a session that is neither", intentWith "session" "other")
      , ("a session in capitals", intentWith "session" "CURRENT")
      , ("a decimal point", intentWith "dx" "1.5")
      , ("a hexadecimal number", intentWith "entity" "0x3")
      , ("a control of another target", "control tick=4 place=0 target=owner op=pause")
      , ("a control of another operation", "control tick=4 place=0 target=gameplay op=stop")
      , ("a control with an extra field", controlLine <> " x=1")
      , ("a control with a missing field", "control tick=4 place=0 target=gameplay")
      , ("a control of fields in another order", "control place=0 tick=4 target=gameplay op=pause")
      ]

    mapM_
      ( \(label, line) →
          it ("refuses a field the format does not carry: " <> label) $
            refusal (logOfLines [line]) 2 OutOfBound
      )
      [ ("tick zero", intentWith "tick" "0")
      , ("a tick past the session bound", intentWith "tick" "100001")
      , ("a place past the largest", intentWith "place" "256")
      , ("a view past the session bound", intentWith "view" "100001")
      , ("an entity the world cannot have", intentWith "entity" "64")
      , ("a delta past the largest bound", intentWith "dx" "1001")
      , ("a negative delta past the largest bound", intentWith "dy" "-1001")
      , ("a delta that does not fit 64 bits", intentWith "dx" "9223372036854775808")
      , ("a number too large for 64 bits", intentWith "version" "18446744073709551616")
      , ("a place too large for 32 bits", intentWith "place" "4294967296")
      , ("a control at tick zero", "control tick=0 place=0 target=gameplay op=pause")
      , ("a control past the session bound", "control tick=100001 place=0 target=gameplay op=pause")
      , ("a control's sequence past the largest", "control tick=4 place=256 target=gameplay op=pause")
      ]

    it "refuses records out of canonical order, and never skips one" $ do
      refusal (logOfLines [intentWith "tick" "3", intentWith "tick" "2"]) 3 Unordered
      refusal (logOfLines ["intent tick=2 place=1 session=current view=1 entity=0 version=0 dx=1 dy=2", oneIntent]) 3 Unordered
      refusal (logOfLines [oneIntent, "control tick=2 place=0 target=gameplay op=pause"]) 3 Unordered
      refusal (logOfLines ["control tick=2 place=0 target=gameplay op=pause", "control tick=3 place=0 target=gameplay op=pause", "control tick=2 place=1 target=gameplay op=pause"]) 4 Unordered
      -- One bad line among good ones refuses the whole log: nothing is read from the rest.
      refusal (logOfLines [oneIntent, "intent tick=2 place=1 session=current view=1 entity=0 version=0 dx=1 dy=2", "bad", "intent tick=2 place=2 session=current view=1 entity=0 version=0 dx=1 dy=2"]) 4 MalformedRecord

    it "refuses a place another record holds" $ do
      refusal (logOfLines [oneIntent, oneIntent]) 3 DuplicatePlace
      refusal (logOfLines [controlLine, controlLine]) 3 DuplicatePlace
      refusal (logOfLines [controlLine, "control tick=4 place=1 target=gameplay op=resume", "control tick=4 place=1 target=gameplay op=pause"]) 4 DuplicatePlace

    it "refuses more records than its bound" $ do
      let limits = defaultLimits {limitRecords = 2}
          three = logOfLines [oneIntent, intentWith "place" "1", intentWith "place" "2"]
      parseLogWith limits three `shouldBe` Left (LogRefusal 4 TooManyRecords)
      parseLogWith limits (logOfLines [oneIntent, intentWith "place" "1"]) `shouldSatisfy` either (const False) ((== 2) . length . logRecords)
      maxRecords `shouldBe` 1200000

    it "says what it refused in fixed words and the line's number, never text from the file" $ do
      let forged = "intent tick=2\nusage: forged \ESC[2J" ∷ ByteString
          text = either refusalText (const "") (parseLog (lined [header, forged, "end records=1"]))
      text `shouldSatisfy` \found → not (null (show found))
      forM_ (map (\problem → refusalText (LogRefusal 7 problem)) [EmptyLog, NotALog, UnsupportedVersion, HeaderTooLong, LineTooLong, NotPrintable, MissingFinalNewline, MalformedRecord, OutOfBound, Unordered, DuplicatePlace, TooManyRecords, MissingTrailer, TrailerMismatch, TextAfterTrailer]) $ \one →
        show one `shouldSatisfy` \shown → length shown < 160 && take 1 (reverse shown) /= "\n"

  describe "the writer" $ do
    it "reads out the records it was given in canonical order, and what it reads out parses back to the same log" $ do
      let recorder = foldr appendRecord newRecorder sample
      recorderCount recorder `shouldBe` length sample
      recorderLog recorder `shouldBe` Right (logOf sample)
      (recorderLog recorder >>= either (const (Left LogOverflow)) Right . parseLog . Lazy.toStrict . renderLog) `shouldBe` Right (logOf sample)

    it "never hands back a log that is cut short: past its bound it says it overflowed" $ do
      let filled most = foldl (flip (appendRecordWith most)) newRecorder sample
      recorderLog (filled 7) `shouldBe` Right (logOf sample)
      recorderLog (filled 6) `shouldBe` Left LogOverflow
      recorderLog (filled 0) `shouldBe` Left LogOverflow
      -- Nothing past the bound was kept, so a later record cannot make room for it by itself.
      recorderCount (filled 6) `shouldBe` 6

    it "never hands back a log with a record the format cannot carry" $
      forM_
        [ RecordControl 0 0 TargetGameplay OpPause
        , RecordControl 100001 0 TargetGameplay OpPause
        , RecordIntention (Placement 1 256) ActsCurrent 0 0 0 0 0
        , RecordIntention (Placement 1 0) ActsCurrent 0 64 0 0 0
        , RecordIntention (Placement 1 0) ActsCurrent 0 0 0 1001 0
        ]
        $ \record → recorderLog (appendRecord record (appendRecord (RecordControl 4 0 TargetGameplay OpPause) newRecorder)) `shouldBe` Left NotRepresentable

    it "records a control only once the engine accepted it, and never one it refused" $ do
      let pause = RecordControl 4 0 TargetGameplay OpPause
          resume = RecordControl 4 1 TargetGameplay OpResume
      recorderLog (acceptControl (assignControlRecord pause newRecorder)) `shouldBe` Right (logOf [pause])
      recorderLog (refuseControl (assignControlRecord pause newRecorder)) `shouldBe` Right emptyLog
      recorderLog (acceptControl (assignControlRecord resume (refuseControl (assignControlRecord pause newRecorder)))) `shouldBe` Right (logOf [resume])
      recorderLog (acceptControl (assignControlRecord resume (acceptControl (assignControlRecord pause newRecorder)))) `shouldBe` Right (logOf [pause, resume])

    it "never claims a log when a control's fate is not known: a place assigned and never answered, an answer with no place, two places at once" $ do
      let pause = RecordControl 4 0 TargetGameplay OpPause
      recorderLog (assignControlRecord pause newRecorder) `shouldBe` Left ControlUndecided
      recorderLog (acceptControl newRecorder) `shouldBe` Left ControlUndecided
      recorderLog (acceptControl (assignControlRecord pause (assignControlRecord pause newRecorder))) `shouldBe` Left ControlUndecided
      recorderLog (noteUnrepresentableControl newRecorder) `shouldBe` Left NotRepresentable

    it "makes one record for each intention the queue accepted, and none for an offer it answered otherwise" $ do
      shared ← newSharedFor defaultBounds
      let offerEntity entity = submit shared (Submitted 1 0 entity 0 1 0)
      accepted ← forM [0 .. 7] offerEntity
      accepted `shouldBe` [Accepted (Placement 1 place) | place ← [0 .. 7]]
      -- The tick's places are all taken; an entity the world does not have; a closed queue.
      offerEntity 0 `shouldReturn` Full FullPlaces
      offerEntity 99 `shouldReturn` Refused RefusedEntity
      recorded ← recordedNow shared
      recorded `shouldBe` Right [intentionRecordOf (Placement 1 place) entity | (place, entity) ← zip [0 ..] [0 .. 7]]
      atomically (closeQueue (sharedQueue shared))
      offerEntity 0 `shouldReturn` Closed
      recordedNow shared `shouldReturn` recorded
      countAccepted <$> readTVarIO (sharedCounts shared) `shouldReturn` 8

    it "makes a record for an intention a replay admitted, and none for one the seam refused as late or as a duplicate" $ do
      shared ← newSharedFor defaultBounds
      let intention = Intention 1 0 2 0 1 0
      atomically (admitLogged shared (Placement 1 0) intention) `shouldReturn` AdmittedAt (Placement 1 0)
      atomically (admitLogged shared (Placement 1 0) intention) `shouldReturn` AtDuplicate
      atomically (admitLogged shared (Placement 1 99) intention) `shouldReturn` AtFullPlaces
      _ ← atomically (seal (sharedQueue shared))
      atomically (admitLogged shared (Placement 1 1) intention) `shouldReturn` AtLate
      atomically (admitLogged shared (Placement 3 0) intention) `shouldReturn` AdmittedAt (Placement 3 0)
      recordedNow shared `shouldReturn` Right [intentionRecordOf (Placement 1 0) 2, intentionRecordOf (Placement 3 0) 2]
      countAccepted <$> readTVarIO (sharedCounts shared) `shouldReturn` 2

    it "records an intention that acted in another session as foreign, and a replay admits it as acting in one that is not this" $ do
      shared ← newSharedFor defaultBounds
      submit shared (Submitted 5 0 1 0 1 0) `shouldReturn` Accepted (Placement 1 0)
      submit shared (Submitted 1 0 1 0 1 0) `shouldReturn` Accepted (Placement 1 1)
      recorded ← recordedNow shared
      fmap (map actingOf) recorded `shouldBe` Right [Just ActsForeign, Just ActsCurrent]
      let admitted = [intention | record ← either (const []) id recorded, Just (_, intention) ← [intentionOf 1 record]]
      case map intentSession admitted of
        [foreignSession, currentSession] → (foreignSession /= 1, currentSession) `shouldBe` (True, 1)
        other → expectationFailure ("expected two intentions, found " <> show (length other))

    it "declines every offer of a session that takes its intentions from a log alone, taking no place for it" $ do
      shared ← newLogOnlyShared defaultBounds
      forM_ [0 .. 20] $ \entity → submit shared (Submitted 1 0 (entity `mod` 8) 0 1 0) `shouldReturn` Declined
      submit shared (Submitted 1 0 99 0 1 0) `shouldReturn` Refused RefusedEntity
      countDeclined <$> readTVarIO (sharedCounts shared) `shouldReturn` 21
      recordedNow shared `shouldReturn` Right []
      -- No place was taken: the log's own record at the first place is still admitted there.
      atomically (admitLogged shared (Placement 1 0) (Intention 1 0 2 0 1 0)) `shouldReturn` AdmittedAt (Placement 1 0)

    it "makes one record for each successful admission, in tick and place order, however many callers complete at once" $ do
      let bounds = defaultBounds {boundPlaces = 64, boundQueue = 200}
      shared ← newSharedFor bounds
      stop ← newTVarIO False
      accepted ← newTVarIO []
      let produce entity = do
            let go = do
                  done ← readTVarIO stop
                  unless done $ do
                    answer ← submit shared (Submitted 1 0 entity 0 1 0)
                    case answer of
                      Accepted place → atomically (modifyTVar' accepted (place :))
                      _ → pure ()
                    yield
                    go
            go
      producers ← forM [0 .. 3] (spawn . produce)
      -- The driver seals and settles ticks while the producers race it.
      forM_ [1 .. 40 ∷ Word64] $ \tick → do
        _ ← atomically (seal (sharedQueue shared))
        atomically (settle (sharedQueue shared) tick)
        yield
      atomically (writeTVar stop True)
      sequence_ producers
      taken ← readTVarIO accepted
      recorded ← recordedNow shared
      case recorded of
        Left problem → expectationFailure ("the log was refused: " <> show problem)
        Right records → do
          -- One record for each accepted intention, and the places the callers were told are the places recorded.
          length records `shouldBe` length taken
          sort [recordPlace record | record ← records] `shouldBe` sort taken
          -- In canonical order, with no place twice: it parses back as written.
          let log' = logOf records
          logRecords log' `shouldBe` records
          parseLog (Lazy.toStrict (renderLog log')) `shouldBe` Right log'
          length (filter (\place → placeOrder place >= 64) taken) `shouldBe` 0
          countAccepted <$> readTVarIO (sharedCounts shared) `shouldReturn` length taken

-- | The record an intention accepted at this place for this entity leaves: acting in the session, at version zero and a
-- delta of one in x, as the examples offer it.
intentionRecordOf ∷ Placement → Int → Record
intentionRecordOf place entity = RecordIntention place ActsCurrent 0 entity 0 1 0

-- | The place of an intention record.
recordPlace ∷ Record → Placement
recordPlace = \case
  RecordIntention place _ _ _ _ _ _ → place
  RecordControl {} → error "an intention was expected"

actingOf ∷ Record → Maybe Acting
actingOf = \case
  RecordIntention _ acting _ _ _ _ _ → Just acting
  RecordControl {} → Nothing

-- | The records a shared state's recorder reads out.
recordedNow ∷ Shared → IO (Either RecordProblem [Record])
recordedNow shared = fmap logRecords . recorderLog <$> readTVarIO (sharedRecorder shared)
