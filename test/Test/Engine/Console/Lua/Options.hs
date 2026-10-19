-- | The @lua@ subcommand's command line, as direct examples of a pure function: every refusal, every
-- default, every number at its boundary. No process is spawned here; a representative of each class of
-- refusal is run through the executable in "Test.Engine.Console.Lua.Process".
module Test.Engine.Console.Lua.Options (spec) where

import Control.Monad (forM_)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Console.Lua.Options
import Hetoimasia.Foundation.Time (Duration, DurationRequirement (RequirePositive), durationFromNanoseconds)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

nanoseconds ∷ Integer → Duration
nanoseconds count = either (error "not a duration") id (durationFromNanoseconds RequirePositive count)

script ∷ FilePath → Text → ScriptSpec
script path name = ScriptSpec path (Just name) Nothing Nothing

refused ∷ [String] → UsageProblem → Spec
refused arguments problem =
  it (unwords arguments <> " is refused as " <> show problem) $
    parseLua arguments `shouldBe` Left problem

-- | The name the only script of a valid line gets.
stemOf ∷ Either UsageProblem LuaParse → Maybe Text
stemOf = \case
  Right (LuaRun command) → case luaScripts command of
    first :| _ → specName first
  _ → Nothing

spec ∷ Spec
spec = describe "the lua command line" $ do
  describe "what it accepts" $ do
    it "takes the defaults of a bare script: the VM main, the file's stem, no clock and no limit" $
      parseLua ["--script", "dir/a.lua"]
        `shouldBe` Right (LuaRun (LuaCommand "main" Nothing Nothing Nothing (script "dir/a.lua" "a" :| [])))
    it "takes the documented example line" $
      parseLua ["--vm", "test", "--scheduler", "fifo", "--script", "./testscript.lua", "--headless"]
        `shouldBe` Right (LuaRun (LuaCommand "test" Nothing Nothing Nothing (script "./testscript.lua" "testscript" :| [])))
    it "takes VM options anywhere, among and after the scripts" $
      parseLua ["--script", "a.lua", "--vm", "v", "--script", "b.lua", "--tick", "0.5", "--ticks", "3", "--for", "2"]
        `shouldBe` Right
          ( LuaRun
              ( LuaCommand
                  "v"
                  (Just (nanoseconds 500000000))
                  (Just (nanoseconds 2000000000))
                  (Just 3)
                  (script "a.lua" "a" :| [script "b.lua" "b"])
              )
          )
    it "binds a script's options to the most recent --script" $
      parseLua ["--script", "a.lua", "--name", "first", "--every", "0.25", "--script", "b.lua", "--every", "1"]
        `shouldBe` Right
          ( LuaRun
              ( LuaCommand
                  "main"
                  Nothing
                  Nothing
                  Nothing
                  ( ScriptSpec "a.lua" (Just "first") (Just (nanoseconds 250000000)) Nothing
                      :| [ScriptSpec "b.lua" (Just "b") (Just (nanoseconds 1000000000)) Nothing]
                  )
              )
          )
    it "takes a tick interval on a tick VM" $
      parseLua ["--tick", "0.001", "--script", "a.lua", "--every-ticks", "4"]
        `shouldBe` Right
          (LuaRun (LuaCommand "main" (Just (nanoseconds 1000000)) Nothing Nothing (ScriptSpec "a.lua" (Just "a") Nothing (Just 4) :| [])))
    it "names a script by its file's stem: no directory and no extension" $
      forM_ [("x.lua", "x"), ("d/e/y.z.lua", "y.z"), ("noext", "noext")] $ \(path, stem) →
        stemOf (parseLua ["--script", path]) `shouldBe` Just stem
    it "asks for help only when --help is the whole line" $ do
      parseLua ["--help"] `shouldBe` Right LuaHelp
      parseLua ["--help", "--vm", "x"] `shouldBe` Left (UnknownOption "--help")

  describe "seconds" $ do
    let accepted =
          [ ("1", 1000000000)
          , ("0.5", 500000000)
          , ("0.000000001", 1)
          , ("12.34", 12340000000)
          , ("007", 7000000000)
          , ("18446744073.709551615", 18446744073709551615)
          ]
        rejected =
          [ "", "0", "0.0", "0.000000000", "0.0000000001", "1.0000000001", ".5", "5.", "-1", "+1", "1e3", "1E3", "1,5", "abc", "1.2.3", " 1", "1 "
          , "18446744073.709551616", "99999999999999999999"
          ]
    forM_ accepted $ \(text, count) →
      it ("accepts " <> show text <> " as " <> show count <> " nanoseconds") $
        parseSeconds (Text.pack text) `shouldBe` Just (nanoseconds count)
    forM_ rejected $ \text →
      it ("refuses " <> show text) $
        parseSeconds (Text.pack text) `shouldBe` Nothing

  describe "counts" $ do
    forM_ [("1", 1), ("42", 42), ("18446744073709551615", 18446744073709551615)] $ \(text, count) →
      it ("accepts " <> show text) $ parseCount (Text.pack text) `shouldBe` Just count
    forM_ ["", "0", "00", "-1", "+1", "1.5", "1e3", "abc", " 1", "18446744073709551616"] $ \text →
      it ("refuses " <> show text) $ parseCount (Text.pack text) `shouldBe` Nothing

  describe "what it refuses, each with its own reason" $ do
    refused ["--bogus", "--script", "a.lua"] (UnknownOption "--bogus")
    refused ["stray", "--script", "a.lua"] (UnknownArgument "stray")
    refused ["--script", "a.lua", "stray"] (UnknownArgument "stray")
    refused ["--script"] (MissingValue "--script")
    refused ["--script", "--name"] (MissingValue "--script")
    refused ["--script", ""] (MissingValue "--script")
    refused ["--script", "a.lua", "--name"] (MissingValue "--name")
    refused ["--vm"] (MissingValue "--vm")
    refused ["--script", "a.lua", "--vm", "--tick", "1"] (MissingValue "--vm")
    refused ["--tick"] (MissingValue "--tick")
    refused ["--for"] (MissingValue "--for")
    refused ["--ticks"] (MissingValue "--ticks")
    refused ["--scheduler"] (MissingValue "--scheduler")
    refused ["--script", "a.lua", "--every"] (MissingValue "--every")
    refused ["--script", "a.lua", "--every-ticks"] (MissingValue "--every-ticks")
    refused ["--vm", "a", "--vm", "b", "--script", "a.lua"] (RepeatedVmOption "--vm")
    refused ["--script", "a.lua", "--headless", "--headless"] (RepeatedVmOption "--headless")
    refused ["--scheduler", "fifo", "--scheduler", "fifo", "--script", "a.lua"] (RepeatedVmOption "--scheduler")
    refused ["--tick", "1", "--tick", "2", "--script", "a.lua"] (RepeatedVmOption "--tick")
    refused ["--for", "1", "--script", "a.lua", "--for", "2"] (RepeatedVmOption "--for")
    refused ["--tick", "1", "--ticks", "1", "--ticks", "2", "--script", "a.lua"] (RepeatedVmOption "--ticks")
    refused ["--name", "x", "--script", "a.lua"] (ScriptOptionBeforeScript "--name")
    refused ["--every", "1", "--script", "a.lua"] (ScriptOptionBeforeScript "--every")
    refused ["--every-ticks", "1", "--script", "a.lua"] (ScriptOptionBeforeScript "--every-ticks")
    refused ["--script", "a.lua", "--name", "x", "--name", "y"] (RepeatedScriptOption "--name" "a.lua")
    refused ["--script", "a.lua", "--every", "1", "--every", "2"] (RepeatedScriptOption "--every" "a.lua")
    refused ["--tick", "1", "--script", "a.lua", "--every-ticks", "1", "--every-ticks", "2"] (RepeatedScriptOption "--every-ticks" "a.lua")
    refused ["--scheduler", "round-robin", "--script", "a.lua"] (SchedulerNotFifo "round-robin")
    refused ["--scheduler", "FIFO", "--script", "a.lua"] (SchedulerNotFifo "FIFO")
    refused ["--tick", "0", "--script", "a.lua"] (MalformedNumber "--tick" "0")
    refused ["--for", "1e3", "--script", "a.lua"] (MalformedNumber "--for" "1e3")
    refused ["--tick", "0.0000000001", "--script", "a.lua"] (MalformedNumber "--tick" "0.0000000001")
    refused ["--tick", "1", "--ticks", "0", "--script", "a.lua"] (MalformedNumber "--ticks" "0")
    refused ["--script", "a.lua", "--every", "-1"] (MalformedNumber "--every" "-1")
    refused ["--tick", "1", "--script", "a.lua", "--every-ticks", "1.5"] (MalformedNumber "--every-ticks" "1.5")
    refused [] NoScript
    refused ["--vm", "x"] NoScript
    refused ["--ticks", "3", "--script", "a.lua"] TicksWithoutTick
    refused ["--script", "a.lua", "--every-ticks", "2"] (EveryTicksWithoutTick "a.lua")
    refused ["--tick", "1", "--script", "a.lua", "--every", "1"] (EveryWithTick "a.lua")
    refused ["--script", "a.lua", "--every", "1", "--every-ticks", "2"] (EveryWithEveryTicks "a.lua")
    refused ["--tick", "1", "--script", "a.lua", "--every-ticks", "2", "--every", "1"] (EveryWithEveryTicks "a.lua")
    it "finds the first problem reading left to right, then the whole line's, in a fixed order" $ do
      parseLua ["--bogus", "--tick", "0"] `shouldBe` Left (UnknownOption "--bogus")
      parseLua ["--ticks", "3", "--script", "a.lua", "--every", "1", "--every-ticks", "2"] `shouldBe` Left TicksWithoutTick
      parseLua ["--tick", "1", "--script", "a.lua", "--every", "1", "--script", "b.lua", "--every-ticks", "2", "--every", "1"]
        `shouldBe` Left (EveryWithTick "a.lua")
    it "escapes what the user typed, so a reason is one line of printable ASCII" $
      forM_
        [ MalformedNumber "--ticks" "1\n2"
        , UnknownArgument "a\rb"
        , UnknownOption "--x\ESC[0m"
        , RepeatedScriptOption "--name" "caf\233\8232.lua"
        , SchedulerNotFifo "\0"
        , MissingValue "--vm\n"
        ] $ \problem →
          problemReason problem `shouldSatisfy` Text.all (\character → character >= ' ' && character <= '~')
    it "bounds a long value with a visible marker" $
      Text.length (problemReason (UnknownArgument (replicate 5000 'a'))) `shouldSatisfy` (< 300)
    it "gives every refusal a one-line reason" $
      forM_
        [ UnknownOption "--x", UnknownArgument "y", MissingValue "--vm", RepeatedVmOption "--vm", ScriptOptionBeforeScript "--name"
        , RepeatedScriptOption "--name" "a.lua", SchedulerNotFifo "x", MalformedNumber "--tick" "0", NoScript, TicksWithoutTick
        , EveryTicksWithoutTick "a.lua", EveryWithTick "a.lua", EveryWithEveryTicks "a.lua"
        ] $ \problem →
          problemReason problem `shouldSatisfy` (\reason → not (Text.null reason) && Text.all (/= '\n') reason)
