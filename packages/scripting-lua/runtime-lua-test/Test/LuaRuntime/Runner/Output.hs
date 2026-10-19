-- | Where a script's @print@ and @warn@ go, how much of it, and what a script can reach.
module Test.LuaRuntime.Runner.Output (spec) where

import Control.Monad (forM_)
import qualified Data.ByteString as ByteString
import Data.Char (isControl)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.IORef (newIORef, readIORef)
import Hetoimasia.Foundation.Log (LogEntry (entryComponent, entryMessage), componentText)
import Hetoimasia.Scripting.Lua.Runner
import Hetoimasia.Scripting.Lua.Runner.Internal (outputLines)
import Test.Hspec (Spec, describe, it, shouldBe, shouldContain, shouldNotContain, shouldReturn, shouldSatisfy)
import Test.LuaRuntime.Runner.Support
import Test.LuaRuntime.Support (bounded, recordingLogger, withBoundary)

-- | The lines a script printed, found by what they start with.
startingWith ∷ Text → [Text] → [Text]
startingWith prefix = filter (Text.isPrefixOf prefix)

-- | Run one one-shot that prints, and answer what each sink was handed.
printing ∷ [Text] → IO ([Text], [Text])
printing body = do
  fixture ← newRFixture
  withScripts [("p.lua", lua (["function run(self)"] <> body <> ["end"]))] $ \paths →
    withBoundary $ \_ runtime → do
      report ← run fixture runtime (config fixture [noWait (scriptAt paths 0)]) >>= expectRan
      reportEnding report `shouldBe` EndedAllInstances
      statusOf report `shouldBe` StatusSuccess
      (,) <$> outLines fixture <*> errLines fixture

spec ∷ Spec
spec = describe "output" $ do
  it "writes print to the output sink and warn to the error sink, from the top level, init, run, a callback and shutdown" $ bounded $ do
    fixture ← newRFixture
    withScripts
      [ ( "a.lua"
        , lua
            [ "print('top'); warn('top')"
            , "function init(self, api) print('init'); warn('init'); api.connect('tick', function(self, event) print('callback'); warn('callback') end) end"
            , "function shutdown(self, reason) print('shutdown'); warn('shutdown') end"
            ]
        )
      , ("b.lua", lua ["function run(self) print('run'); warn('run') end"])
      ]
      $ \paths →
        withBoundary $ \_ runtime → do
          report ←
            alongside
              (awaitOut fixture 4 >> deliverTick fixture 0 1 >> awaitCount (length . startingWith "callback" <$> outLines fixture) 1 >> setStop fixture True)
              (runTick fixture runtime (config fixture (map noWait paths)) >>= expectRan)
          reportEnding report `shouldBe` EndedStopRequest
          out ← outLines fixture
          err ← errLines fixture
          forM' ["top", "init", "callback", "shutdown", "run"] $ \word → do
            out `shouldContain` [word]
            err `shouldContain` ["Lua warning: " <> word]
            out `shouldNotContain` ["Lua warning: " <> word]
            err `shouldNotContain` [word]

  it "never writes to the process's C streams" $ bounded $ do
    fixture ← newRFixture
    withScripts [("p.lua", lua ["print('to the sink'); warn('to the other sink')", "function run(self) print('run'); warn('run') end"])] $ \paths →
      withBoundary $ \_ runtime → do
        (report, cOut, cErr) ← withCapturedStreams (run fixture runtime (config fixture [noWait (scriptAt paths 0)]) >>= expectRan)
        reportEnding report `shouldBe` EndedAllInstances
        cOut `shouldBe` ByteString.empty
        cErr `shouldBe` ByteString.empty
        out ← outLines fixture
        err ← errLines fixture
        forM' ["to the sink", "run"] $ \word → out `shouldSatisfy` elem word
        forM' ["Lua warning: to the other sink", "Lua warning: run"] $ \word → err `shouldSatisfy` elem word

  describe "one call" $ do
    it "joins its arguments' tostring forms with a tab and ends the line" $ do
      (out, _) ← printing ["print(1, nil, true, 'x', 2.5)"]
      startingWith "1" out `shouldBe` ["1\tnil\ttrue\tx\t2.5"]
    it "writes at most a documented number of bytes, cut with a visible marker" $ do
      (out, err) ← printing ["print('L:' .. string.rep('x', 100000))", "warn('W:' .. string.rep('y', 100000))"]
      case startingWith "L:" out of
        [line] → do
          Text.length line `shouldSatisfy` (<= outputCallLimit)
          Text.isSuffixOf truncationMarker line `shouldBe` True
        other → fail ("expected one cut line, found " <> show (length other))
      case filter (Text.isInfixOf "W:") err of
        [line] → do
          Text.length line `shouldSatisfy` (<= outputCallLimit)
          Text.isSuffixOf truncationMarker line `shouldBe` True
        other → fail ("expected one cut warning, found " <> show (length other))
    it "writes what is under the bound whole" $ do
      (out, _) ← printing ["print('M:' .. string.rep('z', 4000))"]
      startingWith "M:" out `shouldBe` ["M:" <> Text.replicate 4000 "z"]
    it "accepts invalid UTF-8, replacing what is not text, and fails nothing" $ do
      (out, _) ← printing ["print('U:a\\255\\254b')", "print('after')"]
      startingWith "U:" out `shouldBe` ["U:a\xFFFD\xFFFD" <> "b"]
      out `shouldContain` ["after"]
    it "accepts an embedded NUL byte, written as an escape" $ do
      (out, _) ← printing ["print('N:a\\0b')"]
      startingWith "N:" out `shouldBe` ["N:a\\x00b"]
    it "splits a line break into lines of the sink and replaces the other control characters, keeping a tab" $ do
      (out, _) ← printing ["print('one\\ntwo')", "print('C:\\27[31m\\r\\127|\\t|')"]
      out `shouldContain` ["one", "two"]
      startingWith "C:" out `shouldBe` ["C:\\x1b[31m\\x0d\\x7f|\t|"]
    it "hands the sink lines with no control character but a tab" $ do
      (out, err) ← printing ["print('a\\0b\\1c\\ndef\\r\\n\\27x')", "warn('w\\0')"]
      forM' (out <> err) $ \line → Text.any (\character → isControl character && character /= '\t') line `shouldBe` False

  describe "what a script can reach" $ do
    it "has no io, os, package or debug, and no reference to the original print or warn" $ do
      fixture ← newRFixture
      withScripts
        [ ( "r.lua"
          , lua
              [ "function run(self)"
              , "  fx.record(type(io) .. ' ' .. type(os) .. ' ' .. type(package) .. ' ' .. type(debug))"
              , "  fx.record(type(hetoimasia_runner_output))"
              , "  fx.record(tostring((pcall(string.dump, print))) .. ' ' .. tostring((pcall(string.dump, warn))))"
              , "  fx.record(tostring(print == rawget(_G, 'print')))"
              , "  fx.record(type(dofile) .. ' ' .. type(load))"
              , "end"
              ]
          )
        ]
        $ \paths →
          withBoundary $ \_ runtime → do
            report ← run fixture runtime (config fixture [noWait (scriptAt paths 0)]) >>= expectRan
            statusOf report `shouldBe` StatusSuccess
            -- The four libraries are not there; the runner's own namespace is gone; print and warn are the
            -- Lua functions the runner defined (a C function cannot be dumped).
            recorded fixture
              `shouldReturn` ["nil nil nil nil", "nil", "true true", "true", "function function"]

  describe "the bound on what is written holds after decoding and escaping" $ do
    -- What a call writes: the bytes of its lines as UTF-8, and one more for the end of each.
    let written ls = sum [ByteString.length (Text.encodeUtf8 line) + 1 | line ← ls]
        script' bytes = bytes
        expanding =
          [ ("NUL bytes", ByteString.replicate 4096 0)
          , ("invalid UTF-8", ByteString.replicate 4096 255)
          , ("line breaks", ByteString.replicate 4096 10)
          , ("control characters", ByteString.take 4096 (ByteString.concat (replicate 2000 (ByteString.pack [27, 1, 2]))))
          , ("multibyte characters", Text.encodeUtf8 (Text.replicate 2048 "\233"))
          , ("a mix", ByteString.take 4096 (ByteString.concat (replicate 1000 (ByteString.pack [0, 255, 10, 195, 169]))))
          ]
    forM_ expanding $ \(label, bytes) →
      it ("holds for " <> label <> ", cut with the marker") $ do
        let ls = outputLines (script' bytes)
        written ls `shouldSatisfy` (<= outputCallLimit)
        reverse ls `shouldSatisfy` \case
          lastLine : _ → Text.isSuffixOf truncationMarker lastLine
          [] → False
    it "writes what fits whole, and counts the end of each line" $ do
      outputLines "a\nb" `shouldBe` ["a", "b"]
      let fits = Text.replicate (outputCallLimit - 1) "x"
      outputLines (Text.encodeUtf8 fits) `shouldBe` [fits]
      -- One byte more and it is cut, to fit the marker.
      let ls = outputLines (Text.encodeUtf8 (fits <> "x"))
      written ls `shouldSatisfy` (<= outputCallLimit)
      ls `shouldSatisfy` all (Text.isSuffixOf truncationMarker)
    forM_ [("print", "print('X:' .. string.rep('\\0', 4096))", False), ("print", "print('X:' .. string.rep('\\255', 4096))", False), ("warn", "warn(string.rep('\\0', 4096))", True), ("print", "print(string.rep('\\n', 4096))", False)] $ \(function', call, toErrors) →
      it ("holds through a real VM for " <> function' <> ": " <> Text.unpack call) $ do
        (out, err) ← printing [call]
        let lines' = if toErrors then err else scriptLines out
        written lines' `shouldSatisfy` (<= outputCallLimit)
        written lines' `shouldSatisfy` (> 0)

  it "keeps the runner's own diagnostics in the logger under one component, and script output, tables and reports out of it" $ bounded $ do
    fixture ← newRFixture
    entries ← newIORef []
    withScripts [("p.lua", lua ["function run(self) print('script output'); error('a failure') end"])] $ \paths →
      withBoundary $ \_ runtime → do
        report ← run fixture runtime ((config fixture [noWait (scriptAt paths 0)]) {runnerLogger = recordingLogger entries}) >>= expectRan
        statusOf report `shouldBe` StatusFailure
        logged ← readIORef entries
        map (componentText . entryComponent) logged `shouldSatisfy` all (== "scripting.lua.runner")
        map entryMessage logged `shouldBe` ["script run ended", "script run started"]
        forM' logged $ \entry → entryMessage entry `shouldSatisfy` (not . Text.isInfixOf "script output")

-- | The lines a script wrote, without the tables the runner wrote to the same sink: a table is its title, its header and its row.
scriptLines ∷ [Text] → [Text]
scriptLines = go
  where
    go [] = []
    go (line : rest)
      | line == startTitle || line == endTitle = go (drop 2 rest)
      | otherwise = line : go rest

forM' ∷ [a] → (a → IO ()) → IO ()
forM' items body = mapM_ body items
