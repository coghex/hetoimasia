-- | Examples for the rendered record layout.
module Test.Engine.Logging.Layout (spec) where

import Control.Monad (forM_)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (UTCTime), picosecondsToDiffTime)
import Hetoimasia.Foundation.Log
import Test.Engine.Logging.Support (fixedThread, gpuComponent, testComponent)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "Record layout" $ do
  it "renders the fixed-metadata examples" testLayoutExamples
  it "omits absent segments and sorts fields by key" testLayoutSegments
  it "omits the thread segment when the option is off" testLayoutThreadOption
  it "quotes and escapes text that would disturb the layout" testLayoutEscaping
  it "passes non-ASCII text through unchanged" testLayoutNonAscii
  it "quotes and escapes the source filename" testLayoutSourceFilename
  it "renders empty text as a pair of quotes" testLayoutEmptyText
  it "keeps an unvalidated field key from disturbing the layout" testLayoutFieldKeys
  it "truncates the timestamp to three fractional digits" testLayoutTimestamp

-- | The issue's fixed metadata: 2026-09-10T12:34:56 plus a millisecond offset.
exampleTime ∷ Integer → UTCTime
exampleTime milliseconds = UTCTime (fromGregorian 2026 9 10) (picosecondsToDiffTime picoseconds)
  where
    picoseconds = (((12 * 3600 + 34 * 60 + 56) * 1000) + milliseconds) * 1000000000

-- | An entry with every optional segment absent, for a test to add one to.
plainEntry ∷ LogEntry
plainEntry = LogEntry
  { entryLevel = Info
  , entryComponent = testComponent
  , entryMessage = "plain"
  , entryFields = Map.empty
  , entryBreadcrumbs = []
  , entryTime = exampleTime 0
  , entryThread = fixedThread
  , entrySource = Nothing
  }

rendered ∷ LogEntry → Text
rendered = formatEntry defaultFormatOptions

testLayoutExamples ∷ IO ()
testLayoutExamples = do
  rendered plainEntry
    { entryComponent = unsafeComponent "runtime"
    , entryMessage = "Starting hetoimasia"
    , entryTime = exampleTime 789
    }
    `shouldBe` "2026-09-10T12:34:56.789Z INFO runtime thread=3 msg=\"Starting hetoimasia\""
  rendered plainEntry
    { entryLevel = Warning
    , entryComponent = gpuComponent
    , entryMessage = "Device lost\nretrying"
    , entryFields = Map.fromList [("device", "Radeon RX"), ("attempt", "2")]
    , entryBreadcrumbs = ["runtime", "gpu"]
    , entryTime = exampleTime 790
    , entryThread = "7"
    , entrySource = Just (SourceLocation "app/Main.hs" 42 "main")
    }
    `shouldBe`
      "2026-09-10T12:34:56.790Z WARN gpu.vulkan thread=7 src=app/Main.hs:42 \
      \crumbs=runtime>gpu msg=\"Device lost\\nretrying\" attempt=2 device=\"Radeon RX\""

testLayoutSegments ∷ IO ()
testLayoutSegments = do
  -- The pure formatter returns a record, never a terminated one.
  rendered plainEntry `shouldSatisfy` not . Text.isInfixOf "\n"
  -- Absent optional segments are omitted entirely, not left empty.
  rendered plainEntry `shouldBe` "2026-09-10T12:34:56.000Z INFO test thread=3 msg=plain"
  rendered plainEntry { entryBreadcrumbs = ["runtime"] }
    `shouldBe` "2026-09-10T12:34:56.000Z INFO test thread=3 crumbs=runtime msg=plain"
  rendered plainEntry { entrySource = Just (SourceLocation "app/Main.hs" 7 "main") }
    `shouldBe` "2026-09-10T12:34:56.000Z INFO test thread=3 src=app/Main.hs:7 msg=plain"
  -- Fields follow the message sorted by key, whatever order they were given.
  rendered plainEntry { entryFields = Map.fromList [("zulu", "3"), ("alpha", "1"), ("mike", "2")] }
    `shouldBe` "2026-09-10T12:34:56.000Z INFO test thread=3 msg=plain alpha=1 mike=2 zulu=3"
  -- Every level has its own spelling.
  map (\level → Text.words (rendered plainEntry { entryLevel = level }) !! 1)
    [Debug, Info, Warning, Error]
    `shouldBe` ["DEBUG", "INFO", "WARN", "ERROR"]

testLayoutThreadOption ∷ IO ()
testLayoutThreadOption =
  formatEntry defaultFormatOptions { formatThread = False } plainEntry
    { entryBreadcrumbs = ["runtime"] }
    `shouldBe` "2026-09-10T12:34:56.000Z INFO test crumbs=runtime msg=plain"

-- | Every character the quoting rules name, in one value.
awkward ∷ Text
awkward = "a\nb\rc\td\"e\\f=g>h i\SOHj"

-- | That value as the layout writes it, quotes included.
awkwardRendered ∷ Text
awkwardRendered = "\"a\\nb\\rc\\td\\\"e\\\\f=g>h i\\u0001j\""

testLayoutEscaping ∷ IO ()
testLayoutEscaping = do
  let line = rendered plainEntry
        { entryMessage = awkward
        , entryBreadcrumbs = [awkward]
        , entryFields = Map.fromList [("key", awkward)]
        }
  -- One record, whatever the payload held.
  line `shouldSatisfy` not . Text.isInfixOf "\n"
  line `shouldBe`
    "2026-09-10T12:34:56.000Z INFO test thread=3 crumbs=" <> awkwardRendered
      <> " msg=" <> awkwardRendered <> " key=" <> awkwardRendered
  -- Each reserved character alone is enough to quote a value; a bare value
  -- needs none of them.
  forM_ ["\"", "\\", "=", ">", " ", "\n", "\r", "\t", "\SOH", "\DEL"] $ \reserved →
    rendered plainEntry { entryMessage = "x" <> reserved <> "y" }
      `shouldSatisfy` Text.isInfixOf " msg=\""
  rendered plainEntry { entryMessage = "no-reserved.characters/here:1" }
    `shouldSatisfy` Text.isInfixOf " msg=no-reserved.characters/here:1"
  -- A breadcrumb holding the separator is quoted, so the join stays readable.
  rendered plainEntry { entryBreadcrumbs = ["a>b", "c"] }
    `shouldSatisfy` Text.isInfixOf " crumbs=\"a>b\">c "
  -- An ordinary key is bare, as every example shows.
  rendered plainEntry { entryFields = Map.fromList [("odd.key-1", "v")] }
    `shouldSatisfy` Text.isInfixOf " odd.key-1=v"

testLayoutNonAscii ∷ IO ()
testLayoutNonAscii = do
  -- Printable non-ASCII needs no quoting and no escape.
  rendered plainEntry { entryMessage = "Ωμ±é日本" }
    `shouldBe` "2026-09-10T12:34:56.000Z INFO test thread=3 msg=Ωμ±é日本"
  -- Quoted for the space it also holds, but otherwise unchanged.
  rendered plainEntry { entryFields = Map.fromList [("device", "Radeon Ωé")] }
    `shouldSatisfy` Text.isInfixOf " device=\"Radeon Ωé\""

testLayoutSourceFilename ∷ IO ()
testLayoutSourceFilename = do
  -- An ordinary path stays bare, exactly as the examples show.
  rendered plainEntry { entrySource = Just (SourceLocation "app/Main.hs" 42 "main") }
    `shouldSatisfy` Text.isInfixOf " src=app/Main.hs:42 "
  -- A filename is text like any other, so it cannot break the layout.
  rendered plainEntry { entrySource = Just (SourceLocation "src/My File.hs" 12 "f") }
    `shouldSatisfy` Text.isInfixOf " src=\"src/My File.hs\":12 "
  rendered plainEntry { entrySource = Just (SourceLocation "src/Qu\"ote.hs" 3 "f") }
    `shouldSatisfy` Text.isInfixOf " src=\"src/Qu\\\"ote.hs\":3 "
  let broken = rendered plainEntry { entrySource = Just (SourceLocation "src/Bad\nName.hs" 7 "f") }
  broken `shouldSatisfy` Text.isInfixOf " src=\"src/Bad\\nName.hs\":7 "
  broken `shouldSatisfy` not . Text.isInfixOf "\n"

testLayoutEmptyText ∷ IO ()
testLayoutEmptyText = do
  rendered plainEntry
    { entryMessage = ""
    , entryBreadcrumbs = ["", "gpu"]
    , entryFields = Map.fromList [("key", "")]
    }
    `shouldBe` "2026-09-10T12:34:56.000Z INFO test thread=3 crumbs=\"\">gpu msg=\"\" key=\"\""

-- | Field keys are raw 'Text' from the caller, unlike the validated component
-- name beside them, so the layout rule has to cover them too.
testLayoutFieldKeys ∷ IO ()
testLayoutFieldKeys = do
  let withKey key = rendered plainEntry { entryFields = Map.fromList [(key, "v")] }
  -- A key that would split the record is quoted and escaped instead.
  withKey "a\nb" `shouldBe` "2026-09-10T12:34:56.000Z INFO test thread=3 msg=plain \"a\\nb\"=v"
  withKey "a\nb" `shouldSatisfy` not . Text.isInfixOf "\n"
  -- So is one that would forge a segment, or an empty one.
  withKey "a b" `shouldSatisfy` Text.isInfixOf " \"a b\"=v"
  withKey "a=b" `shouldSatisfy` Text.isInfixOf " \"a=b\"=v"
  withKey "a>b" `shouldSatisfy` Text.isInfixOf " \"a>b\"=v"
  withKey "a\"b" `shouldSatisfy` Text.isInfixOf " \"a\\\"b\"=v"
  withKey "a\\b" `shouldSatisfy` Text.isInfixOf " \"a\\\\b\"=v"
  withKey "a\tb" `shouldSatisfy` Text.isInfixOf " \"a\\tb\"=v"
  withKey "a\SOHb" `shouldSatisfy` Text.isInfixOf " \"a\\u0001b\"=v"
  withKey "" `shouldSatisfy` Text.isInfixOf " \"\"=v"
  -- Keys still sort by their own text, whatever rendering they need.
  rendered plainEntry { entryFields = Map.fromList [("b key", "2"), ("a", "1"), ("c", "3")] }
    `shouldBe` "2026-09-10T12:34:56.000Z INFO test thread=3 msg=plain a=1 \"b key\"=2 c=3"

testLayoutTimestamp ∷ IO ()
testLayoutTimestamp = do
  let stamped time = Text.takeWhile (/= ' ') (rendered plainEntry { entryTime = time })
      atPicoseconds picoseconds =
        UTCTime (fromGregorian 2026 9 10) (picosecondsToDiffTime picoseconds)
  -- Always three digits, zero-padded.
  stamped (exampleTime 0) `shouldBe` "2026-09-10T12:34:56.000Z"
  stamped (exampleTime 7) `shouldBe` "2026-09-10T12:34:56.007Z"
  stamped (exampleTime 70) `shouldBe` "2026-09-10T12:34:56.070Z"
  -- Finer precision is truncated, never rounded up into a digit shown.
  stamped (atPicoseconds 999999999999) `shouldBe` "2026-09-10T00:00:00.999Z"
  stamped (atPicoseconds 1) `shouldBe` "2026-09-10T00:00:00.000Z"
  stamped (atPicoseconds 789999999999) `shouldBe` "2026-09-10T00:00:00.789Z"
