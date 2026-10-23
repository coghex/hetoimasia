{-# LANGUAGE OverloadedStrings #-}

-- | The coordinator from outside the package: a separately compiled client that composes checked
-- content, the worker service and the module coordinator through public modules alone, with no raw
-- VM handle, no private module and no way to forge the coordinator's state.
module Test.LuaEngine.Modules.Client (spec) where

import Control.Monad (forM_)
import System.Directory (createDirectory)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (proc, readCreateProcessWithExitCode)
import Test.Hspec
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withStorePackageClient)
import qualified Data.ByteString.Char8 as BC

spec ∷ Spec
spec = describe "the coordinator from outside the package" $ do
  it "lets a separately compiled client compose a content root, a read pool and a coordinator, and load a module in the boot phase, through public modules alone" $
    withSystemTempDirectory "hetoimasia-lua-engine-modules-client" $ \tree →
      withClient "Main.hs" composedClient $ \compile → do
        outcome ← compile Link
        case clientStatus outcome of
          ExitSuccess → pure ()
          status → expectationFailure ("the supported client must compile, but the compiler exited with " <> show status <> ":\n" <> clientOutput outcome)
        createDirectory (tree </> "root")
        forM_ [("main.lua", "local dep = import('dep.lua') return { id = 'main', dep = dep }"), ("dep.lua", "return { id = 'dep' }")] $ \(name, body) →
          BC.writeFile (tree </> "root" </> name) body
        (status, out, err) ← readCreateProcessWithExitCode (proc (clientDirectory outcome </> "client") [tree </> "root"]) ""
        (status, out, err) `shouldBe` (ExitSuccess, "boot: BootReady\nlookup: ready\nlookup other: not_ready\njobs: 2 ready: 2\nslots: 4 held, drained: True\n", "")

  it "does not let a client reach a private module of the coordinator" $
    withClient "Client.hs" privateClient $ \compile → do
      outcome ← compile Typecheck
      clientStatus outcome `shouldNotBe` ExitSuccess
      clientOutput outcome `shouldContain` "it is a hidden module in the package"

  it "does not let a client read or forge the coordinator's state" $
    withClient "Client.hs" forgedClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-88464"

withClient ∷ String → String → ((Mode → IO Client) → IO ()) → IO ()
withClient =
  withStorePackageClient
    [ "base"
    , "bytestring"
    , "stm"
    , "text"
    , "hetoimasia-content-0.1.0.0-inplace"
    , "hetoimasia-foundation-0.1.0.0-inplace"
    , "hetoimasia-lua-engine-0.1.0.0-inplace"
    , "hetoimasia-lua-engine-0.1.0.0-inplace-modules"
    , "hetoimasia-lua-engine-0.1.0.0-inplace-request"
    , "hetoimasia-runtime-0.1.0.0-inplace"
    , "hetoimasia-scripting-lua-0.1.0.0-inplace"
    , "hetoimasia-scripting-lua-0.1.0.0-inplace-runtime-lua"
    ]

privateClient ∷ String
privateClient =
  unlines
    [ "module Client (counted) where"
    , ""
    , "import Hetoimasia.LuaEngine.Modules.State (countsSTM)"
    , ""
    , "counted ∷ Int"
    , "counted = 0 `seq` const 0 countsSTM"
    ]

forgedClient ∷ String
forgedClient =
  unlines
    [ "module Client (reach) where"
    , ""
    , "import Control.Concurrent.STM (TVar)"
    , "import Hetoimasia.LuaEngine.Modules (Coordinator)"
    , ""
    , "reach ∷ Coordinator → TVar ()"
    , "reach = coordState"
    ]

composedClient ∷ String
composedClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import Control.Concurrent.STM (atomically)"
    , "import qualified Data.ByteString.Char8 as BC"
    , "import qualified Data.Text as Text"
    , "import qualified Data.Text.Encoding as Text"
    , "import Hetoimasia.Content"
    , "import Hetoimasia.Content.Identity (parseReference, rootKey)"
    , "import Hetoimasia.Content.Inventory"
    , "import Hetoimasia.Content.ReadPool"
    , "import Hetoimasia.Foundation.Log (MetadataProviders (..), callbackSink, defaultLogFilter, mkLoggerWith, unsafeComponent)"
    , "import Hetoimasia.LuaEngine.Behavior (exportLimits)"
    , "import Hetoimasia.LuaEngine.Modules"
    , "import Hetoimasia.LuaEngine.Profile (fixedM1Profile)"
    , "import Hetoimasia.LuaEngine.Request (m1Requests)"
    , "import Hetoimasia.Runtime.Logging (withLoggingLifetime)"
    , "import Hetoimasia.Runtime.Supervision (Recognition (Unrecognized), Role (Service), WorkerPolicy (..), awaitSupervised, withSupervision)"
    , "import qualified Hetoimasia.Runtime.Supervision as Supervision"
    , "import Hetoimasia.Scripting.Lua.Admission (newRequestHandles)"
    , "import Hetoimasia.Scripting.Lua.Owner"
    , "import Hetoimasia.Scripting.Lua.Provider"
    , "import Hetoimasia.Scripting.Lua.Runtime (newLuaRuntime)"
    , "import Hetoimasia.Scripting.Lua.Scheduled"
    , "import System.Environment (getArgs)"
    , ""
    , "bounds ∷ SchedulerBounds"
    , "bounds = SchedulerBounds 8 8 8 (Quanta (Quantum 4) (Quantum 4) (Quantum 4)) 4 4 Nothing"
    , ""
    , "describe ∷ ImmediateLookup → String"
    , "describe found = case found of"
    , "  ImmediateReady _ → \"ready\""
    , "  ImmediateNotReady → \"not_ready\""
    , "  ImmediateFailed failure → \"failed \" <> show (failureCode failure)"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  [directory] ← getArgs"
    , "  Right limits ← pure (inventoryLimits (InventorySpec 100 8 200 40 1048576 4194304 65536))"
    , "  Right root' ← pure (rootKey (BC.pack \"client\"))"
    , "  Right sizes ← pure (poolSpec 2 8)"
    , "  let logger = mkLoggerWith defaultLogFilter (MetadataProviders (error \"no clock is read\") (pure (Text.pack \"1\"))) (callbackSink (\\_ → pure ()))"
    , "      resolve _ path _ = pure (either (Left . Text.pack . show) Right (parseReference (inventoryIdentityLimits limits) root' (Text.encodeUtf8 path)))"
    , "  withContentRoot defaultContentLimits directory $ \\root → do"
    , "    Right inventory ← scanInventory limits root' root"
    , "    withReadPool sizes inventory root $ \\pool → do"
    , "      handles ← newRequestHandles"
    , "      Right requests ← pure (m1Requests fixedM1Profile handles)"
    , "      let spec = ModuleSpec requests inventory pool resolve logger (Text.pack \"client\") 4 2 Nothing"
    , "      withModuleCoordinator spec $ \\coordinator →"
    , "        withLoggingLifetime logger $ \\lifetime → withSupervision lifetime $ \\control → do"
    , "          runtime ← newLuaRuntime control"
    , "          let vm = (vmConfig [LibraryBase]) {vmExportLimits = exportLimits fixedM1Profile}"
    , "              policy = WorkerPolicy Service Supervision.Required (unsafeComponent (Text.pack \"client\")) (\\_ → pure Unrecognized)"
    , "              grant = RequestGrant [coordinatorEndpoint coordinator] 8 SettleOnArrival"
    , "              owned = (scheduledSpec vm policy bounds) {scheduledRequestHandles = Just handles, scheduledRequests = Just grant, scheduledLoader = Just (coordinatorPlan coordinator)}"
    , "          started ← startScheduledOwner runtime owned"
    , "          case started of"
    , "            ScheduledStarted owner → do"
    , "              Just endpoint ← pure (scheduledLoaderEndpoint owner)"
    , "              attachLoader coordinator endpoint"
    , "              Right key ← pure (moduleKey coordinator (BC.pack \"main.lua\"))"
    , "              Right ticket ← bootModule coordinator key"
    , "              outcome ← awaitSupervised control (awaitBoot ticket)"
    , "              putStrLn (\"boot: \" <> show outcome)"
    , "              ready ← atomically (lookupImmediate coordinator (moduleIdentity key))"
    , "              putStrLn (\"lookup: \" <> describe ready)"
    , "              Right other ← pure (moduleKey coordinator (BC.pack \"nobody.lua\"))"
    , "              nobody ← atomically (lookupImmediate coordinator (moduleIdentity other))"
    , "              putStrLn (\"lookup other: \" <> describe nobody)"
    , "              counted ← atomically (coordinatorCounts coordinator)"
    , "              putStrLn (\"jobs: \" <> show (jobsHeld counted) <> \" ready: \" <> show (jobsReady counted))"
    , "              retireScheduled owner"
    , "              atomically (awaitDrained coordinator)"
    , "              drained ← atomically (coordinatorCounts coordinator)"
    , "              putStrLn (\"slots: \" <> show (limitSlots (coordinatorLimits coordinator)) <> \" held, drained: \" <> show (slotsHeld drained == 0))"
    , "            _ → putStrLn \"the owner did not start\""
    ]
