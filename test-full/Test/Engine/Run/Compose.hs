-- | The command's composition over real content, real filtered Lua VMs, the real module and data services, the
-- real read pool and the real session coordinator, in this process and without a native session: what a folder
-- must be to boot, which roles run, how the session ends, and the status each end maps to.
--
-- Nothing authored runs unless the folder booted: every boot refusal is asserted with a script whose first line
-- would print, and the line is absent. Nothing sleeps.
module Test.Engine.Run.Compose (spec) where

import Control.Concurrent (forkIO, myThreadId, threadDelay, throwTo)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forever, void)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Console.Lua.Signals (Delivery (..))
import Hetoimasia.LuaEngine.Facade (OutputSink (..))
import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (AsyncException (UserInterrupt), ExceptionWithContext (ExceptionWithContext), SomeException, fromException, tryWithContext)
import Data.List (isInfixOf)
import GHC.Conc (BlockReason (BlockedOnSTM))
import Hetoimasia.Foundation.Log (callbackSinkWith, defaultLogFilter, mkLogger)
import Hetoimasia.Foundation.Resource (cleanupFailuresInContext, displayCleanupFailure, withResource)
import Hetoimasia.LuaEngine.Session (SessionOutcome)
import Hetoimasia.Run (Setup (..), runGame)
import Hetoimasia.Run.Session (newSessionLinkEndingWith)
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.Run.Boot (BootHooks (..), noBootHooks)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.Posix.Files (createSymbolicLink)
import Test.Engine.Run.Support
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldContain, shouldNotContain, shouldSatisfy)
import Test.Support.Bounded (bounded)

-- | Every one of these lines was printed, in any order: the roles' inits are dispatched together.
shouldInclude ∷ [Text] → [Text] → Expectation
shouldInclude seen wanted = (seen, all (`elem` seen) wanted) `shouldSatisfy` snd

spec ∷ Spec
spec = describe "Composition" $ do
  roles
  endings
  bootRefusals
  stops

-- | A presentation role that prints, waits to see the logical role initialised, and quits.
quittingUi ∷ [Text]
quittingUi =
  [ "  presentation = {"
  , "    every_seconds = 0.02,"
  , "    init = function(self, api) print('ui init') end,"
  , "    update = function(self, dt)"
  , "      local status = self.api.session.status()"
  , "      if status.gameplay.initialized then print('ui quit') self.api.session.quit() end"
  , "    end"
  , "  }"
  ]

logic ∷ [Text]
logic =
  [ "  gameplay = {"
  , "    every_ticks = 1,"
  , "    init = function(self, api) print('logic init') end,"
  , "    update = function(self, dt) end"
  , "  },"
  ]

entry ∷ [Text] → Text
entry body = Text.unlines (["return {"] <> body <> ["}"])

roles ∷ Spec
roles = describe "roles and entries" $ do
  it "runs the default pair on one common entry, each VM evaluating it separately, and a Lua quit is status 0" $ do
    observed ← observe [("hetoimasia.json", commonManifest), ("main.lua", lua (entry (logic <> quittingUi)))] (\_ → pure ())
    observedStatus observed `shouldBe` ExitSuccess
    observedOut observed `shouldInclude` ["logic init", "ui init", "ui quit"]
    observedForced observed `shouldBe` 0

  it "runs explicit separate entries, declared in the reverse order, each in its own VM" $ do
    let manifest =
          manifestWith
            [ "\"tick_seconds\":\"0.01\""
            , "\"vms\":[{\"role\":\"presentation\",\"clock\":\"elapsed\",\"entry\":\"ui.lua\"},{\"role\":\"gameplay\",\"clock\":\"logical\",\"entry\":\"logic.lua\"}]"
            ]
    observed ← observe [("hetoimasia.json", manifest), ("logic.lua", lua (entry logic)), ("ui.lua", lua (entry quittingUi))] (\_ → pure ())
    observedStatus observed `shouldBe` ExitSuccess
    observedOut observed `shouldInclude` ["logic init", "ui init", "ui quit"]

  it "runs the gameplay role alone, without inventing a presentation role" $ do
    let manifest = manifestWith ["\"entry\":\"main.lua\"", "\"tick_seconds\":\"0.01\"", "\"vms\":[{\"role\":\"gameplay\",\"clock\":\"logical\"}]"]
        only =
          entry
            [ "  gameplay = {"
            , "    every_ticks = 1,"
            , "    init = function(self, api) print('logic init') api.session.quit() end,"
            , "    update = function(self, dt) end"
            , "  },"
            , "  presentation = { init = function(self, api) print('ui init') end }"
            ]
    observed ← observe [("hetoimasia.json", manifest), ("main.lua", lua only)] (\_ → pure ())
    observedStatus observed `shouldBe` ExitSuccess
    observedOut observed `shouldContain` ["logic init"]
    observedOut observed `shouldNotContain` ["ui init"]

  it "runs the presentation role alone" $ do
    let manifest = manifestWith ["\"entry\":\"main.lua\"", "\"vms\":[{\"role\":\"presentation\",\"clock\":\"elapsed\"}]"]
        only =
          entry
            [ "  gameplay = { every_ticks = 1, init = function(self, api) print('logic init') end, update = function(self, dt) end },"
            , "  presentation = {"
            , "    every_seconds = 0.02,"
            , "    init = function(self, api) print('ui init') self.api = api end,"
            , "    update = function(self, dt) self.api.session.quit() end"
            , "  }"
            ]
    observed ← observe [("hetoimasia.json", manifest), ("main.lua", lua only)] (\_ → pure ())
    observedStatus observed `shouldBe` ExitSuccess
    observedOut observed `shouldContain` ["ui init"]
    observedOut observed `shouldNotContain` ["logic init"]

  it "starts neither init when the second role's behavior is invalid" $ do
    let broken = entry (logic <> ["  presentation = { every_seconds = -1, init = function(self, api) print('ui init') end }"])
    observed ← observe [("hetoimasia.json", commonManifest), ("main.lua", lua broken)] (\_ → pure ())
    observedStatus observed `shouldBe` ExitFailure 1
    observedOut observed `shouldNotContain` ["logic init"]
    observedOut observed `shouldNotContain` ["ui init"]

endings ∷ Spec
endings = describe "how a session ends" $ do
  it "is 1 for an init that raises" $ do
    let broken = entry (logic <> ["  presentation = { every_seconds = 0.02, init = function(self, api) error('init broke') end }"])
    observed ← observe [("hetoimasia.json", commonManifest), ("main.lua", lua broken)] (\_ → pure ())
    observedStatus observed `shouldBe` ExitFailure 1

  it "is 1 when an error follows a quit, which does not make the end normal" $ do
    let broken = entry (logic <> ["  presentation = { every_seconds = 0.02, init = function(self, api) api.session.quit() error('after quit') end }"])
    observed ← observe [("hetoimasia.json", commonManifest), ("main.lua", lua broken)] (\_ → pure ())
    observedStatus observed `shouldBe` ExitFailure 1

  it "is 1, never a stored success, when a script asks for state, even though it caught the error" $ do
    let asking = entry (logic <> ["  presentation = { every_seconds = 0.02, init = function(self, api) print(pcall(state, 1)) end }"])
    observed ← observe [("hetoimasia.json", commonManifest), ("main.lua", lua asking)] (\_ → pure ())
    observedStatus observed `shouldBe` ExitFailure 1
    -- Nothing else is asserted: the guard latches the whole session's failure and stop, so what the script printed after
    -- catching the error, and the guard's own interruptible stderr line, may be cut off by that stop.
    pure ()

  it "leaves a healthy UI running after an ordinary logical failure, and its later quit is still 1" $ do
    let failing =
          entry
            [ "  gameplay = { every_ticks = 1, init = function(self, api) print('logic init') end, update = function(self, dt) error('logic broke') end },"
            , "  presentation = {"
            , "    every_seconds = 0.02,"
            , "    init = function(self, api) end,"
            , "    update = function(self, dt)"
            , "      local status = self.api.session.status()"
            , "      if status.gameplay.failed then print('ui saw the failure') self.api.session.quit() end"
            , "    end"
            , "  }"
            ]
    observed ← observe [("hetoimasia.json", commonManifest), ("main.lua", lua failing)] (\_ → pure ())
    observedStatus observed `shouldBe` ExitFailure 1
    observedOut observed `shouldInclude` ["logic init", "ui saw the failure"]

  it "is 1 when an output sink fails, which is fatal and not retried" $ do
    let noisy = entry (logic <> ["  presentation = { every_seconds = 0.02, init = function(self, api) print('boom') end }"])
        failing (out, err) = (out {sinkLine = \line → if line == "boom" then ioError (userError "stdout is gone") else sinkLine out line}, err)
    observed ← observeWith unchanged {changeSinks = failing} [("hetoimasia.json", commonManifest), ("main.lua", lua noisy)] (\_ → pure ())
    observedStatus observed `shouldBe` ExitFailure 1

bootRefusals ∷ Spec
bootRefusals = describe "boot refusals, before any authored Lua" $ do
  let marker = lua "print('authored Lua ran')\nreturn {}\n"
      refused files = do
        observed ← observe files (\_ → pure ())
        observedStatus observed `shouldBe` ExitFailure 1
        observedOut observed `shouldNotContain` ["authored Lua ran"]
  it "refuses a missing manifest" $ refused [("main.lua", marker)]
  it "refuses a malformed manifest" $ refused [("hetoimasia.json", lua "{\"format\":1,"), ("main.lua", marker)]
  it "refuses a manifest with an unknown field" $ refused [("hetoimasia.json", manifestWith ["\"entry\":\"main.lua\"", "\"tick_seconds\":\"0.01\"", "\"mods\":[]"]), ("main.lua", marker)]
  it "refuses a missing declared entry" $ refused [("hetoimasia.json", commonManifest)]
  it "refuses an invalid entry path" $ refused [("hetoimasia.json", manifestWith ["\"entry\":\"../main.lua\"", "\"tick_seconds\":\"0.01\""]), ("main.lua", marker)]
  it "refuses a declared entry that an explicit entry overrides but that does not exist" $
    refused
      [ ("hetoimasia.json", manifestWith ["\"entry\":\"missing.lua\"", "\"tick_seconds\":\"0.01\"", "\"vms\":[{\"role\":\"gameplay\",\"clock\":\"logical\",\"entry\":\"main.lua\"},{\"role\":\"presentation\",\"clock\":\"elapsed\",\"entry\":\"main.lua\"}]"])
      , ("main.lua", marker)
      ]
  it "refuses a folder holding a symbolic link, which the whole-folder scan meets even if nothing uses it" $ do
    observed ←
      observeWith unchanged {changePrepare = \folder → createSymbolicLink "main.lua" (folder </> "unused.lua")} [("hetoimasia.json", commonManifest), ("main.lua", marker)] (\_ → pure ())
    observedStatus observed `shouldBe` ExitFailure 1
    observedOut observed `shouldNotContain` ["authored Lua ran"]
  it "scans an unused, hidden file and still boots, so an extra file is no refusal by itself" $ do
    observed ← observe [("hetoimasia.json", commonManifest), ("main.lua", lua (entry (logic <> quittingUi))), (".hidden/unused.bin", lua "x")] (\_ → pure ())
    observedStatus observed `shouldBe` ExitSuccess
  it "refuses a manifest that changed between its first read and the scan" $ do
    let changing folder = BootHooks (ByteString.writeFile (folder </> "hetoimasia.json") (manifestWith ["\"entry\":\"main.lua\"", "\"tick_seconds\":\"0.02\""]))
    observed ← observeWith unchanged {changeBoot = changing} [("hetoimasia.json", commonManifest), ("main.lua", marker)] (\_ → pure ())
    observedStatus observed `shouldBe` ExitFailure 1
    observedOut observed `shouldNotContain` ["authored Lua ran"]

stops ∷ Spec
stops = describe "stops and signals" $ do
  let ui =
        entry
          ( logic
              <> [ "  presentation = {"
                 , "    every_seconds = 0.02,"
                 , "    init = function(self, api) print('ui ready') end,"
                 , "    update = function(self, dt) end,"
                 , "    shutdown = function(self, reason) print('ui shutdown') end"
                 , "  }"
                 ]
          )
      files = [("hetoimasia.json", commonManifest), ("main.lua", lua ui)]
  it "stops in order on one signal, running shutdown, and is 130" $ do
    observed ← observe files $ \probe → do
      probeAwaitOut probe "ui ready"
      void (probeSignal probe)
    observedStatus observed `shouldBe` ExitFailure 130
    observedOut observed `shouldContain` ["ui shutdown"]
    observedForced observed `shouldBe` 0

  it "forces at most once, however many signals arrive, and the first still stops in order" $ do
    observed ← observe files $ \probe → do
      probeAwaitOut probe "ui ready"
      first ← probeSignal probe
      second ← probeSignal probe
      third ← probeSignal probe
      (first, second, third) `shouldBe` (Requested, Forcing, Ignored)
    observedForced observed `shouldBe` 1

  it "is 1, not 130, when a failure follows the stop" $ do
    let failing = lua (Text.replace "print('ui shutdown')" "error('shutdown broke')" ui)
    observed ← observe [("hetoimasia.json", commonManifest), ("main.lua", failing)] $ \probe → do
      probeAwaitOut probe "ui ready"
      void (probeSignal probe)
    observedStatus observed `shouldBe` ExitFailure 1

  it "is 1, not 130, when the abandoned preparation's cleanup failed" $ do
    started ← newEmptyMVar
    let failing _ =
          BootHooks . withResource (pure ()) (\_ → ioError (userError "preparation release failed")) $ \_ →
            putMVar started () >> forever (threadDelay 100000000)
    observed ← observeWith unchanged {changeBoot = failing} files $ \probe → do
      takeMVar started
      void (probeSignal probe)
    observedStatus observed `shouldBe` ExitFailure 1
    observedOut observed `shouldBe` []

  it "is 1, reaching no authored Lua, with no flush through the failed path and no line written to it, when a startup diagnostic fails" $ do
    writes ← newTVarIO (0 ∷ Int)
    flushes ← newTVarIO (0 ∷ Int)
    let sink =
          callbackSinkWith
            (\_ → atomically (modifyTVar' writes (+ 1)) >> ioError (userError "the diagnostic sink is broken"))
            (atomically (modifyTVar' flushes (+ 1)))
        logger = mkLogger defaultLogFilter sink
    observed ← observeWith unchanged {changeLogger = Just logger} [("hetoimasia.json", commonManifest), ("main.lua", lua (entry (logic <> quittingUi)))] (\_ → pure ())
    observedStatus observed `shouldBe` ExitFailure 1
    observedOut observed `shouldBe` []
    -- The failed write is marked as the diagnostics' own, so the lifetime does not flush through that sink, and the
    -- command writes no terminal line through the path that just failed.
    readTVarIO writes >>= (`shouldBe` 1)
    readTVarIO flushes >>= (`shouldBe` 0)
    observedReports observed `shouldBe` []

  it "writes one terminal line, and flushes once, for an ordinary failure with a working diagnostic path" $ do
    flushes ← newTVarIO (0 ∷ Int)
    let sink = callbackSinkWith (\_ → pure ()) (atomically (modifyTVar' flushes (+ 1)))
        logger = mkLogger defaultLogFilter sink
    observed ← observeWith unchanged {changeLogger = Just logger} [("main.lua", lua "return {}")] (\_ → pure ())
    observedStatus observed `shouldBe` ExitFailure 1
    length (observedReports observed) `shouldBe` 1
    readTVarIO flushes >>= (`shouldSatisfy` (>= 1))

  it "keeps the launch failure, with its cleanup evidence, when a cancellation arrives while the session's diagnostics writer is joined" $ do
    ended ← newTVarIO False
    started ← newEmptyMVar
    result ← newEmptyMVar
    caller ← newEmptyMVar
    let held = newSessionLinkEndingWith (readTVar ended)
        launching =
          withResource (pure ()) (\_ → ioError (userError "launch cleanup failed")) $ \_ → do
            putMVar started ()
            ioError (userError "launch failed") ∷ IO SessionOutcome
        setup =
          Setup
            { setupForce = pure ()
            , setupReady = \_ → pure ()
            , setupBoot = noBootHooks
            , setupLifetime = \_ → withLoggingLifetime silentLogger
            , setupLink = held
            , setupReport = \_ → pure ()
            , setupLaunch = \_ _ _ _ → launching
            }
    _ ← forkIO $ do
      myThreadId >>= putMVar caller
      outcome ← withFolder [("hetoimasia.json", commonManifest), ("main.lua", lua (entry logic))] $ \folder →
        tryWithContext @SomeException (runGame setup quietFilter folder)
      putMVar result outcome
    me ← takeMVar caller
    takeMVar started
    -- The launch failed, and the command is now joining the writer, which is held: interrupt it there.
    blockedFor BlockedOnSTM me
    throwTo me UserInterrupt
    atomically (writeTVar ended True)
    bounded (takeMVar result) >>= \case
      Left (ExceptionWithContext context failure) → do
        (fromException failure ∷ Maybe AsyncException) `shouldBe` Just UserInterrupt
        concatMap displayCleanupFailure (cleanupFailuresInContext context) `shouldSatisfy` isInfixOf "launch"
      Right _ → expectationFailure "the cancellation was lost"

  it "abandons the boot work on a signal, runs nothing authored, and is 130" $ do
    gate ← newEmptyMVar
    -- The gate is never filled: the work is cancelled while it waits, not released.
    let holding _ = BootHooks (takeMVar gate)
    observed ← observeWith unchanged {changeBoot = holding} files $ \probe → do
      void (probeSignal probe)
    observedStatus observed `shouldBe` ExitFailure 130
    observedOut observed `shouldBe` []
