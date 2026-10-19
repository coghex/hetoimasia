-- | Every exit status of the @lua@ subcommand, by running the built executable as a child process, and
-- which stream carries what.
--
-- A signal is delivered only after the child has reported on stdout that its script is running; every
-- read and every wait is bounded; every child is killed and reaped on every way out, independently of
-- the signal under test; no example sleeps. The three checked-in examples are run by the commands the
-- README documents.
module Test.Engine.Console.Lua.Process (spec) where

import Control.Monad (forM_)
import Data.List (isInfixOf, isPrefixOf)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.Posix.Signals (sigINT, sigTERM)
import Test.Engine.Console.Support
import Test.Hspec (Spec, describe, it, shouldBe, shouldContain, shouldNotContain, shouldSatisfy)

-- | The logging variables a run is given: a warn threshold, so the runner's own diagnostics do not
-- crowd the streams the examples read.
quiet ∷ [(String, String)]
quiet = [("HETOIMASIA_LOG_LEVEL", "warn")]

-- | The checked-in examples.
oneShot, looped, controller, watcher ∷ FilePath
oneShot = "test/lua-examples/oneshot.lua"
looped = "test/lua-examples/looped.lua"
controller = "test/lua-examples/controller.lua"
watcher = "test/lua-examples/watcher.lua"

-- | An event-only instance that says when it is running and when it is stopped.
waiting ∷ String
waiting =
  unlines
    [ "function init(self) print('running') end"
    , "function shutdown(self, reason) print('shutdown ' .. reason) end"
    ]

-- | Run the subcommand on these arguments, to its end.
lua ∷ [String] → IO Outcome
lua arguments = runToCompletion quiet ("lua" : arguments)

-- | The usage lines a refusal writes: the usage line and a one-line reason, and nothing on stdout.
expectUsageError ∷ Outcome → String → IO ()
expectUsageError outcome reason = do
  outcomeCode outcome `shouldBe` ExitFailure 2
  outcomeOut outcome `shouldBe` ""
  let diagnostics = lines (outcomeErr outcome)
  length diagnostics `shouldBe` 2
  take 1 diagnostics `shouldSatisfy` all ("Usage: hetoimasia lua" `isPrefixOf`)
  drop 1 diagnostics `shouldSatisfy` all (reason `isInfixOf`)

spec ∷ Spec
spec = describe "the lua subcommand, run as a process" $ do
  describe "exits 0" $ do
    it "for the one-shot example: it prints, completes, and the tables are on stdout" $ do
      outcome ← lua ["--script", oneShot]
      outcomeCode outcome `shouldBe` ExitSuccess
      lines (outcomeOut outcome)
        `shouldSatisfy` \seen → "one-shot: hello from run" `elem` seen && "instances at start" `elem` seen && "instances at end" `elem` seen
      outcomeErr outcome `shouldBe` ""
    it "for the looped example, paused, resumed and stopped by the controller, with the same output on every run" $ do
      let arguments = ["--tick", "0.001", "--ticks", "40", "--script", looped, "--every-ticks", "1", "--script", controller, "--every-ticks", "3"]
          wanted =
            [ "looped: update 1"
            , "looped: update 2"
            , "looped: update 3"
            , "controller: pause looped"
            , "controller: resume looped"
            , "looped: update 4"
            , "looped: update 5"
            , "controller: stop looped, then myself"
            , "looped: shutdown stopped"
            ]
      first ← lua arguments
      second ← lua arguments
      outcomeCode first `shouldBe` ExitSuccess
      -- What the scripts printed, without the two tables.
      filter (\line → any (`isPrefixOf` line) ["looped:", "controller:"]) (lines (outcomeOut first)) `shouldBe` wanted
      outcomeOut second `shouldBe` outcomeOut first
    it "for the event-only watcher, which stops itself once every other instance has ended" $ do
      outcome ← lua ["--tick", "0.001", "--ticks", "20", "--script", watcher, "--script", oneShot]
      outcomeCode outcome `shouldBe` ExitSuccess
      filter (\line → any (`isPrefixOf` line) ["watcher:", "one-shot:"]) (lines (outcomeOut outcome))
        `shouldBe` [ "one-shot: hello from run"
                   , "watcher: started watcher"
                   , "watcher: started oneshot"
                   , "watcher: ended oneshot completed"
                   , "watcher: every other instance has ended"
                   ]
    it "for a run ended by --ticks, with every remaining instance stopped" $
      withLuaFiles [("wait.lua", waiting)] $ \at → do
        outcome ← lua ["--tick", "0.001", "--ticks", "3", "--script", at "wait.lua"]
        outcomeCode outcome `shouldBe` ExitSuccess
        lines (outcomeOut outcome) `shouldSatisfy` elem "shutdown stopped"
    it "for a run ended by --for, which a script that never ends cannot hold" $
      withLuaFiles [("wait.lua", waiting)] $ \at → do
        -- The limit is measured from before admission and may end the run before, during or after it, so
        -- nothing here depends on how far the child got: it ends, bounded, successfully, with nothing
        -- on stderr.
        outcome ← lua ["--for", "0.05", "--script", at "wait.lua"]
        outcomeCode outcome `shouldBe` ExitSuccess
        outcomeErr outcome `shouldBe` ""
    it "for a looped example on the elapsed clock, once it has been seen to update, asserted on its structure" $
      withChild quiet ["lua", "--script", looped, "--every", "0.005"] $ \child → do
        -- Progress is coordinated through what the child printed, never through a deadline; the signal
        -- ends the run.
        seen ← awaitMarker child "looped: update 1"
        sendSignal sigINT child
        code ← awaitExit child
        rest ← readRest child
        code `shouldBe` ExitFailure 130
        lines rest `shouldSatisfy` elem "looped: shutdown stopped"
        seen `shouldSatisfy` elem "instances at start"

  describe "exits 1" $ do
    it "for an instance whose init fails, reporting it on stderr" $
      withLuaFiles [("bad.lua", "function init(self) error('init boom') end\n")] $ \at → do
        outcome ← lua ["--script", at "bad.lua"]
        outcomeCode outcome `shouldBe` ExitFailure 1
        outcomeErr outcome `shouldContain` "init boom"
        outcomeErr outcome `shouldContain` "stage=init"
    it "for an instance that fails later, while another completes" $
      withLuaFiles [("good.lua", "function run(self) print('good ran') end\n"), ("late.lua", "function run(self) error('run boom') end\n")] $ \at → do
        outcome ← lua ["--script", at "good.lua", "--script", at "late.lua"]
        outcomeCode outcome `shouldBe` ExitFailure 1
        lines (outcomeOut outcome) `shouldSatisfy` elem "good ran"
        outcomeErr outcome `shouldContain` "run boom"
    it "for a source with a syntax error, reporting that no file loaded" $
      withLuaFiles [("syntax.lua", "this is not lua\n")] $ \at → do
        outcome ← lua ["--script", at "syntax.lua"]
        outcomeCode outcome `shouldBe` ExitFailure 1
        outcomeOut outcome `shouldBe` ""
        outcomeErr outcome `shouldContain` "syntax.lua"
    it "for a file that does not exist" $ do
      outcome ← lua ["--script", "test/lua-examples/does-not-exist.lua"]
      outcomeCode outcome `shouldBe` ExitFailure 1
      outcomeOut outcome `shouldBe` ""
      outcomeErr outcome `shouldContain` "does-not-exist.lua"
    it "for an invalid logging variable, before any argument is read, even a bad one" $ do
      outcome ← runToCompletion [("HETOIMASIA_LOG_LEVEL", "verbose")] ["lua", "--bogus"]
      outcomeCode outcome `shouldBe` ExitFailure 1
      outcomeErr outcome `shouldContain` "HETOIMASIA_LOG_LEVEL"

  describe "exits 2" $ do
    let refusal label arguments reason = it ("for " <> label) $ lua arguments >>= \outcome → expectUsageError outcome reason
    refusal "an unknown option" ["--bogus"] "unknown option"
    refusal "an unknown argument" ["stray"] "unknown argument"
    refusal "a missing value" ["--script"] "needs a value"
    refusal "a repeated VM option" ["--vm", "a", "--vm", "b", "--script", oneShot] "more than once"
    refusal "a script option before the first --script" ["--name", "x", "--script", oneShot] "must follow the --script"
    refusal "a script option repeated for one script" ["--script", oneShot, "--name", "a", "--name", "b"] "more than once for"
    refusal "--every together with --every-ticks" ["--tick", "1", "--script", looped, "--every", "1", "--every-ticks", "1"] "both given"
    refusal "--every on a tick VM" ["--tick", "1", "--script", looped, "--every", "1"] "elapsed interval"
    refusal "--every-ticks without --tick" ["--script", looped, "--every-ticks", "1"] "needs --tick"
    refusal "--ticks without --tick" ["--ticks", "3", "--script", oneShot] "needs --tick"
    refusal "a scheduler other than fifo" ["--scheduler", "lifo", "--script", oneShot] "not supported"
    refusal "no --script" ["--vm", "x"] "no --script"
    refusal "no argument at all" [] "no --script"
    refusal "a zero duration" ["--for", "0", "--script", oneShot] "invalid value"
    refusal "a finer-than-nanosecond duration" ["--tick", "0.0000000001", "--script", oneShot] "invalid value"
    refusal "a malformed count" ["--tick", "1", "--ticks", "1.5", "--script", oneShot] "invalid value"
    it "for a refusal the runner returns: a module defining both run and update" $
      withLuaFiles [("both.lua", "function run(self) end\nfunction update(self, dt) end\n")] $ \at → do
        outcome ← lua ["--script", at "both.lua", "--every", "1"]
        outcomeCode outcome `shouldBe` ExitFailure 2
        outcomeOut outcome `shouldBe` ""
        outcomeErr outcome `shouldContain` "Usage: hetoimasia lua"
        outcomeErr outcome `shouldContain` "both.lua"
    it "with one usage line and one reason line, whatever control characters the arguments carry" $
      forM_
        [ ["--ticks", "1\n2", "--script", "a.lua"]
        , ["--script", "a\r\nb.lua", "--name", "x", "--name", "y"]
        , ["--bogus\tline\nbreak"]
        , ["stray\ESCargument"]
        , ["--script", "caf\233.lua", "--every-ticks", "1"]
        , ["--vm", replicate 5000 'v', "--vm", "w", "--script", "a.lua"]
        ] $ \arguments → do
          outcome ← lua arguments
          outcomeCode outcome `shouldBe` ExitFailure 2
          outcomeOut outcome `shouldBe` ""
          let diagnostics = lines (outcomeErr outcome)
          length diagnostics `shouldBe` 2
          -- Plain printable ASCII, and bounded.
          unlines diagnostics `shouldSatisfy` all (\character → character == '\n' || (character >= ' ' && character <= '~'))
          forM_ diagnostics $ \line → length line `shouldSatisfy` (< 600)
    it "for the top-level unknown argument carrying a line break, still one usage line and one reason" $ do
      outcome ← runToCompletion quiet ["--bad\nargument"]
      outcomeCode outcome `shouldBe` ExitFailure 2
      outcomeOut outcome `shouldBe` ""
      length (lines (outcomeErr outcome)) `shouldBe` 2
    it "for the top-level unknown argument, with a usage line naming the lua subcommand" $ do
      outcome ← runToCompletion quiet ["--resources"]
      outcomeCode outcome `shouldBe` ExitFailure 2
      outcomeOut outcome `shouldBe` ""
      -- One usage line and a one-line reason.
      length (lines (outcomeErr outcome)) `shouldBe` 2
      outcomeErr outcome `shouldContain` "Usage: hetoimasia"
      outcomeErr outcome `shouldContain` "lua"
    it "and writes help to stdout, with status 0, for lua --help" $ do
      outcome ← lua ["--help"]
      outcomeCode outcome `shouldBe` ExitSuccess
      outcomeErr outcome `shouldBe` ""
      outcomeOut outcome `shouldContain` "--script"

  describe "exits 130, after the orderly stop" $
    forM_ [("SIGINT", sigINT), ("SIGTERM", sigTERM)] $ \(label, signal) →
      it ("for " <> label <> ", with the instance's shutdown output on stdout before the process exits") $
        withLuaFiles [("wait.lua", waiting)] $ \at →
          withChild quiet ["lua", "--script", at "wait.lua"] $ \child → do
            _ ← awaitMarker child "running"
            sendSignal signal child
            code ← awaitExit child
            rest ← readRest child
            code `shouldBe` ExitFailure 130
            lines rest `shouldSatisfy` elem "shutdown stopped"
            -- The status table that follows the orderly stop is on stdout too.
            lines rest `shouldSatisfy` elem "instances at end"

  describe "a signal on logical ticks" $
    it "exits 130 for SIGINT on a tick VM, after the orderly stop" $
      withLuaFiles [("wait.lua", waiting)] $ \at →
        withChild quiet ["lua", "--tick", "0.001", "--script", at "wait.lua"] $ \child → do
          _ ← awaitMarker child "running"
          sendSignal sigINT child
          code ← awaitExit child
          rest ← readRest child
          code `shouldBe` ExitFailure 130
          lines rest `shouldSatisfy` elem "shutdown stopped"

  describe "a signal as the modules finish loading" $
    forM_ [("SIGINT", sigINT), ("SIGTERM", sigTERM)] $ \(label, signal) →
      it ("exits 130 for " <> label <> " delivered when the top level has run, before or during admission") $
        withLuaFiles [("early.lua", "print('loaded')\nfunction shutdown(self, reason) print('shutdown ' .. reason) end\n")] $ \at →
          withChild quiet ["lua", "--script", at "early.lua"] $ \child → do
            -- Module top levels run before anything is admitted. The instance never ends by itself, so
            -- the run ends by the signal whichever side of admission it lands on.
            _ ← awaitMarker child "loaded"
            sendSignal signal child
            code ← awaitExit child
            _ ← readRest child
            code `shouldBe` ExitFailure 130

  describe "ranks 1 over 130" $
    it "exits 1 for a run in which an instance failed and then a signal ended it" $
      withLuaFiles [("bad.lua", "function init(self) error('boom') end\n"), ("wait.lua", waiting)] $ \at →
        withChild quiet ["lua", "--script", at "bad.lua", "--script", at "wait.lua"] $ \child → do
          _ ← awaitMarker child "running"
          sendSignal sigINT child
          code ← awaitExit child
          rest ← readRest child
          code `shouldBe` ExitFailure 1
          lines rest `shouldSatisfy` elem "shutdown stopped"

  describe "the streams" $
    it "puts print and the tables on stdout, and warn and a failure report on stderr" $
      withLuaFiles
        [ ("noisy.lua", "function run(self) print('on stdout'); warn('on stderr') end\n")
        , ("bad.lua", "function run(self) error('reported') end\n")
        ]
        $ \at → do
          outcome ← lua ["--script", at "noisy.lua", "--script", at "bad.lua"]
          let out = lines (outcomeOut outcome)
              err = lines (outcomeErr outcome)
          out `shouldSatisfy` elem "on stdout"
          out `shouldSatisfy` elem "instances at start"
          out `shouldSatisfy` any ("TID" `isPrefixOf`)
          out `shouldNotContain` ["Lua warning: on stderr"]
          err `shouldSatisfy` elem "Lua warning: on stderr"
          err `shouldSatisfy` any ("failure: instance" `isPrefixOf`)
          unlines out `shouldNotContain` "reported"
