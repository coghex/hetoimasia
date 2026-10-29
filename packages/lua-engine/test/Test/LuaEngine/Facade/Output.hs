{-# LANGUAGE OverloadedStrings #-}

-- | Authored @print@ and @warn@ (D-71): the streams, the context a warning carries, the escaping and the
-- bound of a call, and what a script cannot reach. The sinks are recording ones; the bound of a call is
-- checked as the bytes it wrote, prefixes and line ends and the visible truncation marker included.
module Test.LuaEngine.Facade.Output (spec) where

import Control.Concurrent.STM (readTVarIO)
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.LuaEngine.Profile (ByteLimit (PrintWarnBytes), fixedM1Profile)
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Request.Profiles (bytesOf)

files ∷ [(FilePath, ByteString)]
files =
  [ ("lua/helper.lua", "return {warns = function() warn('from the helper') print('helper print') end}")
  , ("data.bin", "xx")
  ]

-- | The bytes a call wrote: each line and the line end that follows it.
written ∷ [Text] → Int
written = sum . map ((+ 1) . ByteString.length . Text.encodeUtf8)

spec ∷ Spec
spec = describe "authored output" $ do
  it "writes print to stdout plainly and warn to stderr with the role, the content and the instance, one prefix to each line" $
    withOneIn Gameplay fixedM1Profile
      script
        { scPrelude = ["local helper = import('lua/helper.lua')", "print('module print', 1, nil, true)", "warn('module warning')", "print('module sees', type(hetoimasia_engine), type(hetoimasia_engine_builder), type(io), type(os), type(debug))"]
        , scInit =
            [ "print('a', 'b', 3, nil, false, 2.5)"
            , "warn('line one\\nline two')"
            , "warn('@on')"
            , "print('@off')"
            , "helper.warns()"
            ]
        , scUpdate = ["if self.ran then return end self.ran = true", "print('update')", "warn('update warning')"]
        , scShutdown = ["print('shutdown')", "warn('shutdown warning')"]
        }
      files
      $ \world control fvm spawned → do
        tickBy control fvm 1
        stopSpawned spawned
        _ ← settledOf spawned
        let who = "lua warning role=gameplay content=modules-test instance=" <> spId spawned <> ": "
        outLines world
          >>= ( `shouldBe`
                  [ "module print\t1\tnil\ttrue"
                  , "module sees\tnil\tnil\tnil\tnil\tnil"
                  , "a\tb\t3\tnil\tfalse\t2.5"
                  , "@off"
                  , "helper print"
                  , "update"
                  , "shutdown"
                  ]
              )
        errLines world
          >>= ( `shouldBe`
                  [ "lua warning role=gameplay module=modules-test:lua/main.lua: module warning"
                  , who <> "line one"
                  , who <> "line two"
                  , who <> "@on"
                  , who <> "from the helper"
                  , who <> "update warning"
                  , who <> "shutdown warning"
                  ]
              )
        -- every call flushed its stream before it returned
        readTVarIO (wFlushes world) >>= (`shouldBe` 13)
        pure (const () fvm)
  it "attributes a presentation warning to its role, whatever the script wrote into its own api" $
    withOneIn Presentation fixedM1Profile
      script {scInit = ["api.role = 'gameplay'", "api.content_id = 'x'", "warn('who am I')"]}
      files
      $ \world _ _ spawned →
        errLines world >>= (`shouldBe` ["lua warning role=presentation content=modules-test instance=" <> spId spawned <> ": who am I"])
  it "turns what cannot be shown into text that can: invalid UTF-8, controls, NUL, and keeps a tab" $
    withOneIn Gameplay fixedM1Profile
      script
        { scInit =
            [ "print('bad \\255\\254 bytes')"
            , "print('ctrl \\1 \\27 \\127 nul \\0 tab\\there')"
            , "print('line\\r\\nbreak')"
            , "warn('warn \\0 \\255')"
            ]
        }
      files
      $ \world _ _ spawned → do
        outLines world
          >>= ( `shouldBe`
                  [ "bad \65533\65533 bytes"
                  , "ctrl \\x01 \\x1b \\x7f nul \\x00 tab\there"
                  , "line\\x0d"
                  , "break"
                  ]
              )
        errLines world >>= (`shouldBe` ["lua warning role=gameplay content=modules-test instance=" <> spId spawned <> ": warn \\x00 \65533"])
  it "writes nothing of a call whose conversion fails, and the failure is the script's own ordinary error" $
    withOneIn Gameplay fixedM1Profile
      script
        { scInit =
            [ "local bad = setmetatable({}, {__tostring = function() error('no thanks') end})"
            , "try('print', function() print('first', bad, 'third') end)"
            , "try('warn', function() warn('first', bad) end)"
            , "print('still running')"
            ]
        }
      files
      $ \world _ _ spawned → do
        out ← outLines world
        length out `shouldBe` 3
        take 2 out `shouldSatisfy` all (\line → "=> false ; " `Text.isInfixOf` line && "no thanks" `Text.isInfixOf` line && not ("first" `Text.isInfixOf` line && not ("=>" `Text.isInfixOf` line)))
        drop 2 out `shouldBe` ["still running"]
        errLines world >>= (`shouldBe` [])
        phaseOf spawned >>= (`shouldNotBe` Nothing)
  it "bounds a call to the profile's bytes in all, prefixes and line ends and the marker included, whatever it is made of" $ do
    withOneIn Gameplay fixedM1Profile
      script
        { scInit =
            [ "local function call(f, ...) print('BEGIN') f(...) print('END') end"
            , "call(print, string.rep('x', 5000))"
            , "call(print, string.rep('\\226\\130\\172', 2000))"
            , "call(print, string.rep('\\0', 5000))"
            , "call(print, string.rep('\\255', 5000))"
            , "call(print, string.rep('line\\n', 2000))"
            , "call(print, string.rep('x', 4095))"
            , "warn('BEGIN') warn(string.rep('y', 5000)) warn('END')"
            , "warn('BEGIN') warn(string.rep('\\0', 5000)) warn('END')"
            ]
        }
      files
      $ \world _ _ _ → do
        out ← outLines world
        err ← errLines world
        let prefix = "lua warning role=gameplay content=modules-test instance=inst-1: "
        case (callsBetween "BEGIN" "END" out, callsBetween "BEGIN" "END" (map (Text.drop (Text.length prefix)) err)) of
          ([xs, euros, nuls, invalid, linesCall, exact], [yarn, nulWarn]) → do
            -- an ASCII call is cut to exactly the bound, and says it was cut
            written xs `shouldBe` 4096
            last xs `shouldSatisfy` Text.isSuffixOf "..."
            -- a multi-byte call is cut at a character, never inside one
            written euros `shouldSatisfy` (<= 4096)
            written euros `shouldSatisfy` (> 4090)
            last euros `shouldSatisfy` Text.isSuffixOf "..."
            -- escaping makes the text longer, and it is bounded again afterwards
            written nuls `shouldSatisfy` (<= 4096)
            last nuls `shouldSatisfy` Text.isSuffixOf "..."
            written invalid `shouldSatisfy` (<= 4096)
            written linesCall `shouldSatisfy` (<= 4096)
            last linesCall `shouldSatisfy` Text.isSuffixOf "..."
            -- exactly the bound is not cut at all
            written exact `shouldBe` 4096
            last exact `shouldNotSatisfy` Text.isSuffixOf "..."
            -- a warning's prefix is part of what it may write
            written (map (prefix <>) yarn) `shouldBe` 4096
            last yarn `shouldSatisfy` Text.isSuffixOf "..."
            written (map (prefix <>) nulWarn) `shouldSatisfy` (<= 4096)
          (printed, warned) → expectationFailure ("expected six printed calls and two warned, found " <> show (length printed) <> " and " <> show (length warned))
    -- the least bound the facade is made over: a profile below it is refused (see "the bounds the facade formats with")
    withOneIn Gameplay (bytesOf [(PrintWarnBytes, fromIntegral (minimumPrintWarnBytes 128))])
      script {scInit = ["print(string.rep('z', 1000))", "warn(string.rep('w', 1000))"]}
      files
      $ \world _ _ _ → do
        out ← outLines world
        err ← errLines world
        (written out, written err) `shouldBe` (minimumPrintWarnBytes 128, minimumPrintWarnBytes 128)
  it "marks every line of a warning with its whole prefix, however the call is cut: across a line break, in the first line, in a later one, and with many lines" $
    withOneIn Gameplay fixedM1Profile
      script
        { scInit =
            [ "warn('BEGIN') warn(string.rep('x', 4027) .. '\\nnext') warn('END')"
            , "warn('BEGIN') warn(string.rep('y', 3990) .. '\\n' .. string.rep('z', 200) .. '\\nlast') warn('END')"
            , "warn('BEGIN') warn('short\\nlines\\nonly') warn('END')"
            , "warn('BEGIN') warn(string.rep('w\\n', 3000)) warn('END')"
            , "warn('BEGIN') warn(string.rep('\\0', 5000)) warn('END')"
            ]
        }
      files
      $ \world _ _ _ → do
        err ← errLines world
        let prefix = "lua warning role=gameplay content=modules-test instance=inst-1: "
        -- the raw lines, not lines with the prefix taken off: a line that lost its prefix, or kept part of it,
        -- or is the marker alone, is not a line that starts with it
        err `shouldSatisfy` (not . null)
        err `shouldSatisfy` all (Text.isPrefixOf prefix)
        let calls = callsBetween "BEGIN" "END" (map (Text.drop (Text.length prefix)) err)
        length calls `shouldBe` 5
        forM_ calls $ \call → do
          written (map (prefix <>) call) `shouldSatisfy` (<= 4096)
        -- the call that is cut ends in the marker on a prefixed line, and says nothing after it
        case calls of
          [reported, spread, short, many, nuls] → do
            last reported `shouldSatisfy` Text.isSuffixOf "..."
            reported `shouldSatisfy` ((== 1) . length)
            last spread `shouldSatisfy` Text.isSuffixOf "..."
            short `shouldBe` ["short", "lines", "only"]
            last many `shouldSatisfy` Text.isSuffixOf "..."
            last nuls `shouldSatisfy` Text.isSuffixOf "..."
          other → expectationFailure ("five calls were expected, found " <> show (length other))
  it "gives a script no logger and no way to the engine's own bindings or the process's streams" $
    withOneIn Gameplay fixedM1Profile
      script
        { scInit =
            [ "local keys = {}"
            , "for k in pairs(api) do keys[#keys + 1] = k end"
            , "table.sort(keys)"
            , "print(table.concat(keys, ','))"
            , "print(type(logger), type(api.logger), type(hetoimasia_engine), type(hetoimasia_engine_builder), type(io), type(os), type(debug), type(package), type(require), type(load), type(dofile))"
            ]
        }
      files
      $ \world _ _ _ →
        outLines world >>= (`shouldBe` ["content,content_id,instance_id,request,role,session,state,time", "nil\tnil\tnil\tnil\tnil\tnil\tnil\tnil\tnil\tnil\tnil"])

-- | The lines between each pair of marker lines, per call.
callsBetween ∷ Text → Text → [Text] → [[Text]]
callsBetween begin end' = go
  where
    go found = case break (== begin) found of
      (_, _ : rest) → case break (== end') rest of
        (call, _ : more) → call : go more
        _ → []
      _ → []
