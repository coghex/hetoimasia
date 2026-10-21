-- | The executable's command line as a pure function (requirement 13): every accepted form and
-- every refusal, without a process.
module Test.Domains.Command (spec) where

import Data.Char (isControl)
import Data.Word (Word64)
import qualified Data.Text as Text
import Hetoimasia.Sample.LuaDomains.Canonical (parseDigest)
import Hetoimasia.Sample.LuaDomains.Command
import Hetoimasia.Sample.LuaDomains.Scenario (Scenario (Normal, Pause))
import Test.Hspec

-- | A command with none of the file or digest options.
plain ∷ Word64 → Word64 → Scenario → Command
plain ticks seed scenario = Command ticks seed scenario Nothing Nothing False Nothing

aDigest ∷ String
aDigest = replicate 64 'a'

spec ∷ Spec
spec = describe "the command line" $ do
  it "runs the documented default session when given nothing" $
    parseArguments [] `shouldBe` Right (Run (plain defaultTicks 1 Normal))

  it "reads the ticks and the seed, in either order" $ do
    parseArguments ["--ticks", "5"] `shouldBe` Right (Run (plain 5 1 Normal))
    parseArguments ["--seed", "7", "--ticks", "9"] `shouldBe` Right (Run (plain 9 7 Normal))
    parseArguments ["--ticks", "20", "--seed", "18446744073709551615"] `shouldBe` Right (Run (plain 20 18446744073709551615 Normal))
    parseArguments ["--seed", "0"] `shouldBe` Right (Run (plain defaultTicks 0 Normal))
    parseArguments ["--ticks", "100000"] `shouldBe` Right (Run (plain 100000 1 Normal))

  it "reads the record, replay, digests and expect-digest options, in any order, beside the others" $ do
    parseArguments ["--record", "out.log"] `shouldBe` Right (Run ((plain defaultTicks 1 Normal) {commandRecord = Just "out.log"}))
    parseArguments ["--replay", "in.log", "--ticks", "9"] `shouldBe` Right (Run ((plain 9 1 Normal) {commandReplay = Just "in.log"}))
    parseArguments ["--digests"] `shouldBe` Right (Run ((plain defaultTicks 1 Normal) {commandDigests = True}))
    parseArguments ["--expect-digest", aDigest] `shouldBe` Right (Run ((plain defaultTicks 1 Normal) {commandExpect = parseDigest aDigest}))
    parseArguments ["--expect-digest", replicate 64 'A'] `shouldBe` Right (Run ((plain defaultTicks 1 Normal) {commandExpect = parseDigest (replicate 64 'a')}))
    parseArguments ["--digests", "--scenario", "pause", "--replay", "a", "--record", "b", "--expect-digest", aDigest]
      `shouldBe` Right (Run (Command defaultTicks 1 Pause (Just "b") (Just "a") True (parseDigest aDigest)))

  it "treats --help alone as help, and refuses it beside anything else" $ do
    parseArguments ["--help"] `shouldBe` Right Help
    parseArguments ["--help", "--ticks", "5"] `shouldBe` Left HelpAlone
    parseArguments ["--ticks", "5", "--help"] `shouldBe` Left HelpAlone

  mapM_
    refused
    [ (["--bogus"], UnknownArgument "--bogus")
    , (["ticks"], UnknownArgument "ticks")
    , (["--ticks", "5", "extra"], UnknownArgument "extra")
    , (["--ticks"], MissingValue "--ticks")
    , (["--seed"], MissingValue "--seed")
    , (["--ticks", "5", "--ticks", "6"], RepeatedOption "--ticks")
    , (["--seed", "1", "--seed", "1"], RepeatedOption "--seed")
    , (["--ticks", "abc"], MalformedValue "--ticks" "abc")
    , (["--ticks", "0"], MalformedValue "--ticks" "0")
    , (["--ticks", "100001"], MalformedValue "--ticks" "100001")
    , (["--ticks", "-1"], MalformedValue "--ticks" "-1")
    , (["--ticks", "1.5"], MalformedValue "--ticks" "1.5")
    , (["--ticks", ""], MalformedValue "--ticks" "")
    , (["--seed", "-1"], MalformedValue "--seed" "-1")
    , (["--seed", "18446744073709551616"], MalformedValue "--seed" "18446744073709551616")
    , (["--seed", "000000000000000000001"], MalformedValue "--seed" "000000000000000000001")
    , (["--seed", "0x10"], MalformedValue "--seed" "0x10")
    , (["--record"], MissingValue "--record")
    , (["--replay"], MissingValue "--replay")
    , (["--expect-digest"], MissingValue "--expect-digest")
    , (["--record", "a", "--record", "b"], RepeatedOption "--record")
    , (["--replay", "a", "--replay", "b"], RepeatedOption "--replay")
    , (["--digests", "--digests"], RepeatedOption "--digests")
    , (["--expect-digest", aDigest, "--expect-digest", aDigest], RepeatedOption "--expect-digest")
    , (["--record", ""], MalformedValue "--record" "")
    , (["--replay", "a\NULb"], MalformedValue "--replay" "a\NULb")
    , (["--expect-digest", "abc"], MalformedValue "--expect-digest" "abc")
    , (["--expect-digest", replicate 63 'a' <> "g"], MalformedValue "--expect-digest" (replicate 63 'a' <> "g"))
    , (["--expect-digest", replicate 65 'a'], MalformedValue "--expect-digest" (replicate 65 'a'))
    ]

  it "writes every refusal as one bounded line, with the user's text escaped" $ do
    let forged = "--bad\nusage: forged\ESC[2J\233\128512"
        line = problemLine (UnknownArgument forged)
    Text.unpack line `shouldNotSatisfy` any isControl
    Text.unpack line `shouldSatisfy` all (< '\128')
    Text.isInfixOf "\\x0a" line `shouldBe` True
    Text.isInfixOf "\\x1b" line `shouldBe` True
    Text.isInfixOf "\\xe9" line `shouldBe` True
    Text.isInfixOf "\\x{1f600}" line `shouldBe` True
    Text.isSuffixOf usage line `shouldBe` True
    -- A very long argument is cut, so the line's length does not follow the user's.
    Text.length (problemLine (UnknownArgument (replicate 5000 'x'))) `shouldSatisfy` (< 300)
    Text.length (problemLine (MalformedValue "--ticks" (replicate 5000 'y'))) `shouldSatisfy` (< 300)
    -- A path, and a refusal of what is in a file, are cut and escaped the same way.
    let path = "/tmp/\nforged" <> replicate 5000 'z'
    mapM_
      (\problem → do
          let one = problemLine problem
          Text.unpack one `shouldNotSatisfy` any isControl
          Text.length one `shouldSatisfy` (< 400)
          Text.isSuffixOf usage one `shouldBe` True)
      [ReplayUnreadable path "no such file", ReplayMalformed path "line 3: not a record of the format", ReplayNotReplayable path "a record for tick 4" 2, RecordRefused path "the path exists"]
  where
    refused (arguments, problem) =
      it ("refuses " <> show arguments) $
        parseArguments arguments `shouldBe` Left problem
