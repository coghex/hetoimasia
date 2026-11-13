-- | What the storage backend's boundary exposes to a client.
--
-- A suite inside the package shares its module environment and can reach every
-- constructor, so it cannot observe the boundary. These examples compile separate
-- single-module clients with "Test.Support.ExternalClient". One client is accepted,
-- linked and run: it composes the public backend end to end. Every other client is
-- refused for the diagnostic that names its cause:
--
-- * the constructor of an authority (a backing handle, a ticket, a prepared growth, a
--   staged write, the service) cannot be named, so a client cannot forge the
--   authority to touch a file or to make a capacity spendable: @GHC-10237@ for an
--   import and @GHC-01928@ for a term-level use;
-- * the native seam and its adapter, the descriptor type and every internal module
--   are not in the public interface: @GHC-87110@.
module Test.TerrainRuntime.Storage.Opacity (spec) where

import Control.Monad (forM_)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.Process (CreateProcess (cwd), proc)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldContain)
import Test.Support.ExternalClient (Client (..), Mode (..), clientRunBound, rejectedBecause, withPackageClient)
import Test.Support.Subprocess (runCaptured)

spec ∷ Spec
spec = describe "Storage backend opacity across the package boundary" $ do
  it "accepts and runs a client that composes the public backend" $
    withClient "Main.hs" supportedClient $ \compile → do
      outcome ← compile Link
      case clientStatus outcome of
        ExitSuccess → pure ()
        status → expectationFailure ("the supported client must compile, but the compiler exited with " <> show status <> ":\n" <> clientOutput outcome)
      (status, out, err) ←
        runCaptured clientRunBound (proc (clientDirectory outcome </> "client") []) {cwd = Just (clientDirectory outcome)} ""
      status `shouldBe` ExitSuccess
      err `shouldBe` ""
      -- the harness builds a client on the non-threaded runtime, which the backend refuses by design;
      -- the threaded path is exercised by the package's own examples
      lines out `shouldBe` ["not threaded"]

  forM_ constructors $ \name →
    it ("rejects a client that names the constructor of " <> name) $
      withClient "Client.hs" (importing ["import Hetoimasia.Terrain.Runtime.Storage (" <> name <> " (" <> name <> "))"] []) $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "GHC-10237"
        clientOutput outcome `shouldContain` name

  forM_ forged $ \(name, body) →
    it ("rejects a client that builds " <> name <> " from a constructor") $
      withClient "Client.hs" (importing ["import Hetoimasia.Terrain.Runtime.Storage (" <> name <> ")"] body) $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "GHC-01928"
        clientOutput outcome `shouldContain` name

  forM_ hidden $ \module' →
    it ("rejects a client that imports " <> module') $
      withClient "Client.hs" (importing ["import " <> module'] []) $ \compile → do
        outcome ← compile Typecheck
        case clientStatus outcome of
          ExitFailure _ → pure ()
          ExitSuccess → expectationFailure ("the client compiled, so " <> module' <> " is reachable:\n" <> clientOutput outcome)
        clientOutput outcome `shouldContain` module'
        clientOutput outcome `shouldContain` "GHC-87110"

withClient ∷ FilePath → String → ((Mode → IO Client) → IO ()) → IO ()
withClient =
  withPackageClient
    ["base", "text", "stm", "bytestring", "hetoimasia-foundation", "hetoimasia-runtime", "hetoimasia-terrain", "hetoimasia-terrain-runtime-0.1.0.0-inplace"]

importing ∷ [String] → [String] → String
importing imports body = unlines (["module Client () where", ""] <> imports <> [""] <> body)

-- | Authorities exported abstractly: importing the constructor is refused.
constructors ∷ [String]
constructors = ["Backing", "Ticket", "PreparedGrowth", "StagedWrite", "StorageService"]

-- | An authority forged by applying a constructor the client never imported.
forged ∷ [(String, [String])]
forged =
  [ ("Backing", ["forgedBacking :: Backing", "forgedBacking = Backing undefined 0 undefined"])
  , ("Ticket", ["forgedTicket :: Ticket", "forgedTicket = Ticket undefined 0"])
  , ("PreparedGrowth", ["forgedGrowth :: PreparedGrowth", "forgedGrowth = PreparedGrowth 1 2 3 4"])
  ]

-- | The native seam, the adapter, the descriptor type and the implementation.
hidden ∷ [String]
hidden =
  [ "Hetoimasia.Terrain.Runtime.Storage.Internal.Native"
  , "Hetoimasia.Terrain.Runtime.Storage.Internal.Service"
  , "Hetoimasia.Terrain.Runtime.Storage.Internal.File"
  , "Hetoimasia.Terrain.Runtime.Storage.Internal.Types"
  , "Hetoimasia.Terrain.Runtime.Storage.Internal.Volume"
  ]

supportedClient ∷ String
supportedClient =
  unlines
    [ "{-# LANGUAGE OverloadedStrings #-}"
    , "module Main (main) where"
    , ""
    , "import Control.Concurrent.STM (atomically, newTVarIO)"
    , "import Control.Exception (try)"
    , "import Hetoimasia.Foundation.Log (callbackSink, defaultLogFilter, mkLogger)"
    , "import Hetoimasia.Foundation.Worker (withWorkerGroup)"
    , "import Hetoimasia.Terrain.Residency (ArenaId (..))"
    , "import Hetoimasia.Terrain.Runtime.Storage"
    , "import Hetoimasia.Terrain.Runtime.Store"
    , "import Hetoimasia.Terrain.Runtime.Store.Admission (defaultEditBankSpec, mkEditBankConfig, newAdmission)"
    , ""
    , "main :: IO ()"
    , "main = withWorkerGroup $ \\group -> do"
    , "  let logger = mkLogger defaultLogFilter (callbackSink (\\_ -> pure ()))"
    , "  Right bank <- pure (mkEditBankConfig defaultEditBankSpec)"
    , "  admission <- newTVarIO (newAdmission bank)"
    , "  Right config <- pure (mkStorageConfig defaultQualified minHeadroomBytes)"
    , "  Right store <- pure (mkStoreConfig (StoreSpec (64 * 1024 * 1024) Nothing (toInteger defaultOffsetLimit)))"
    , "  started <- try (withStorage config admission group logger (run store))"
    , "  case started of"
    , "    Left NotThreaded -> putStrLn \"not threaded\""
    , "    Left other -> print other"
    , "    Right () -> pure ()"
    , ""
    , "run :: StoreConfig -> StorageService -> IO ()"
    , "run store svc = do"
    , "    -- the volume the client runs on may not be a qualified one: either way the answer is typed"
    , "    Right ticket <- submitOpen svc ExplicitWork (OpenSpec \".\" (StoreIdentity (ArenaId 1) 7) store)"
    , "    atomically (awaitTicket svc ticket)"
    , "    outcome <- withOutcome svc ticket pure"
    , "    case outcome of"
    , "      Just (Opened backing _) -> do"
    , "        report <- closeBacking svc backing"
    , "        print (crClosed report)"
    , "      Just (Failed failure _) -> print (not (failureCode failure == \"\"))"
    , "      _ -> print False"
    , "    view <- atomically (serviceView svc)"
    , "    print (svBackings view == 0 && svRecords view == 0)"
    ]
