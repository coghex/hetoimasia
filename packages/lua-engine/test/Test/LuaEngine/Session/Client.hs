{-# LANGUAGE OverloadedStrings #-}

-- | The session coordinator composed from outside the packages: a separately compiled client, given the content
-- package, the foundation and runtime, the Lua host's public modules and the Lua engine's configuration, facade
-- and session sublibraries, opens a root, scans it, makes the boot checkpoint, starts the supervision and the
-- read pool, and runs a session to its end, through public modules alone, with no private Lua handle, graphics,
-- console, game or sample; and what the coordinator keeps hidden, it cannot name.
module Test.LuaEngine.Session.Client (spec) where

import qualified Data.ByteString as ByteString
import System.Directory (createDirectory)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (proc, readCreateProcessWithExitCode)
import Test.Hspec
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withStorePackageClient)

spec ∷ Spec
spec = describe "composition from outside the packages" $ do
  it "lets a separately compiled client open a root, make the checkpoint and run a session to its end through public modules alone" $
    withSystemTempDirectory "hetoimasia-session-client" $ \tree →
      withClient "Main.hs" composingClient $ \compile → do
        outcome ← compile Link
        case clientStatus outcome of
          ExitSuccess → pure ()
          status → expectationFailure ("the client must compile, but the compiler exited with " <> show status <> ":\n" <> clientOutput outcome)
        createDirectory (tree </> "root")
        ByteString.writeFile (tree </> "root" </> "hetoimasia.json") manifest
        ByteString.writeFile (tree </> "root" </> "main.lua") entry
        (status, out, err) ← readCreateProcessWithExitCode (proc (clientDirectory outcome </> "client") [tree </> "root"]) ""
        (status, out) `shouldBe` (ExitSuccess, "init presentation\nshutdown presentation stopped\nVerdictSuccess\nretired: True\nfailures: 0\n")
        -- the coordinator reports its lifecycle through the logger it was given, and nothing else is written; the note of the
        -- start was acknowledged before the session was stopped, and the last note ("session ended") may legally be left
        -- undelivered when the session returns (D-87), so it is not required
        err `shouldContain` "msg=\"session starting\""
        err `shouldNotContain` "ERROR"

  it "keeps the handle's and the harness's fields out of a client's reach" $ do
    withClient "Client.hs" handleClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
    withClient "Client.hs" harnessClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"

  it "keeps the near-limit tick seam out of every client: the harness is an abstract type, its constructor and fields are in a library of the package no one outside it can depend on" $ do
    withClient "Client.hs" tickBaseImportClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
    withClient "Client.hs" tickBaseUpdateClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-22385"
  where
    withClient = withStorePackageClient ["base", "bytestring", "text", "stm", "hetoimasia-content-0.1.0.0-inplace", "hetoimasia-foundation-0.1.0.0-inplace", "hetoimasia-runtime-0.1.0.0-inplace", "hetoimasia-scripting-lua-0.1.0.0-inplace", "hetoimasia-scripting-lua-0.1.0.0-inplace-runtime-lua", "hetoimasia-lua-engine-0.1.0.0-inplace", "hetoimasia-lua-engine-0.1.0.0-inplace-facade", "hetoimasia-lua-engine-0.1.0.0-inplace-session"]
    manifest = "{\"format\":1,\"id\":\"client\",\"entry\":\"main.lua\",\"vms\":[{\"role\":\"presentation\",\"clock\":\"elapsed\"}]}"
    entry = "return { presentation = { init = function(self, api) print('init ' .. api.role) end, shutdown = function(self, reason) print('shutdown ' .. self.api.role .. ' ' .. reason) end } }"

composingClient ∷ String
composingClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import qualified Data.ByteString.Char8 as BC"
    , "import Control.Concurrent (forkIO)"
    , "import Control.Concurrent.STM (atomically, retry)"
    , "import Control.Monad (void)"
    , "import qualified Data.Text as Text"
    , "import System.Environment (getArgs)"
    , "import System.IO (hFlush, stdout, stderr)"
    , "import Hetoimasia.Content"
    , "import Hetoimasia.Content.Identity (rootKey)"
    , "import Hetoimasia.Content.Inventory"
    , "import Hetoimasia.Content.ReadPool (poolSpec, withReadPool)"
    , "import Hetoimasia.Foundation.Log (defaultLogFilter, handleLogger, unsafeComponent)"
    , "import Hetoimasia.Foundation.Time (monotonicSource)"
    , "import Hetoimasia.LuaEngine.Boot"
    , "import Hetoimasia.LuaEngine.Facade (OutputSink (..), withOutput)"
    , "import Hetoimasia.LuaEngine.Profile (fixedM1Profile)"
    , "import Hetoimasia.LuaEngine.Session"
    , "import Hetoimasia.Runtime.Logging (withLoggingLifetime)"
    , "import Hetoimasia.Runtime.Supervision (withSupervision)"
    , "import Hetoimasia.Scripting.Lua.Runtime (newLuaRuntime)"
    , "import Hetoimasia.Scripting.Lua.Scheduler (TimerBackend (..))"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  [directory] ← getArgs"
    , "  configuration ← either (fail . show) pure (contentConfiguration fixedM1Profile)"
    , "  key ← either (fail . show) pure (rootKey (BC.pack \"client\"))"
    , "  logger ← handleLogger defaultLogFilter stderr"
    , "  let sink = OutputSink {sinkLine = putStrLn . Text.unpack, sinkFlush = hFlush stdout}"
    , "  withContentRoot (configContentLimits configuration) directory $ \\root → do"
    , "    inventory ← scanInventory (configInventoryLimits configuration) key root >>= either (fail . show) pure"
    , "    checkpoint ← bootCheckpointFrom fixedM1Profile root inventory >>= either (fail . show) pure"
    , "    pool ← either (fail . show) pure (poolSpec 2 12)"
    , "    withReadPool pool inventory root $ \\readPool →"
    , "      withOutput sink sink $ \\output →"
    , "        withLoggingLifetime logger $ \\lifetime →"
    , "          withSupervision lifetime $ \\control → do"
    , "            runtime ← newLuaRuntime control"
    , "            let spec ="
    , "                  SessionSpec"
    , "                    { sxProfile = fixedM1Profile"
    , "                    , sxCheckpoint = checkpoint"
    , "                    , sxInventory = inventory"
    , "                    , sxPool = readPool"
    , "                    , sxLogger = logger"
    , "                    , sxOutput = output"
    , "                    , sxClock = monotonicSource"
    , "                    , sxTimer = TimerBackend (\\_ _ → pure (pure ()))"
    , "                    , sxRuntime = runtime"
    , "                    , sxControl = control"
    , "                    , sxHarness = noHarness"
    , "                    }"
    , "            outcome ← runSession spec $ \\session → void . forkIO $ do"
    , "              atomically $ do"
    , "                status ← sessionStatus session"
    , "                case statusPresentation status of"
    , "                  Just role | rolePhase role == Running → pure ()"
    , "                  _ → retry"
    , "              -- the note of the start is on the stream before the session is stopped: the call does not wait for the writer"
    , "              atomically $ do"
    , "                history ← sessionHistory session"
    , "                if any ((== Text.pack \"session starting\") . fst) (historyDiagnostics history) then retry else pure ()"
    , "              requestStop session StopQuit"
    , "            putStrLn (show (outVerdict outcome))"
    , "            putStrLn (\"retired: \" <> show (outRetired outcome))"
    , "            putStrLn (\"failures: \" <> show (length (outFailures outcome)))"
    ]

handleClient ∷ String
handleClient =
  unlines
    [ "module Client (reach) where"
    , ""
    , "import Hetoimasia.LuaEngine.Session (Session (sessionState))"
    , ""
    , "reach ∷ Maybe Session"
    , "reach = Nothing"
    ]

-- | A client that asks the public module for the tick base field.
tickBaseImportClient ∷ String
tickBaseImportClient =
  unlines
    [ "module Client (reach) where"
    , ""
    , "import Hetoimasia.LuaEngine.Session (Harness (harnessTickBase, harnessSecond))"
    , ""
    , "reach ∷ Maybe Harness"
    , "reach = Nothing"
    ]

-- | A client that sets the tick base on the one harness a public composition can name.
tickBaseUpdateClient ∷ String
tickBaseUpdateClient =
  unlines
    [ "module Client (reach) where"
    , ""
    , "import Hetoimasia.LuaEngine.Session (Harness, noHarness)"
    , ""
    , "reach ∷ Harness"
    , "reach = noHarness {harnessTickBase = 9223372036854775806}"
    ]

harnessClient ∷ String
harnessClient =
  unlines
    [ "module Client (reach) where"
    , ""
    , "import Hetoimasia.LuaEngine.Session (Harness (harnessProbe))"
    , ""
    , "reach ∷ Maybe Harness"
    , "reach = Nothing"
    ]
