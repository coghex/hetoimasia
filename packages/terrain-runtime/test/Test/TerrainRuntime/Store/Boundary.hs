-- | What the store's public interface exposes to a client.
--
-- A suite inside the package reaches the private library and every constructor, so it
-- cannot observe the boundary. These examples compile separate single-module clients
-- with "Test.Support.ExternalClient", exposing the public packages alone. One client
-- must be accepted, linked and run: it opens a store, plans a removal through the
-- public interface, writes the pages to a map standing for the file, publishes,
-- reads the record back through a pinned reader, and proposes growth and admission.
-- Every other client must be refused for the diagnostic that names its cause:
--
-- * the constructor of a plan, a configuration, a store, a transaction, a reader or
--   growth token, a window, an admission or a grant cannot be named (@GHC-10237@ for
--   an import, @GHC-01928@ for a term-level use), so a client cannot forge the
--   authority to publish, to read a pinned version or to enlarge an allowance;
-- * a plan's and a proposal's accessors are functions, never field labels, so
--   record-update syntax cannot rewrite them (@GHC-22385@);
-- * the private library's modules are not reachable (@GHC-87110@).
module Test.TerrainRuntime.Store.Boundary (spec) where

import Control.Monad (forM_)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.Process (CreateProcess (cwd), proc)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldContain)
import Test.Support.ExternalClient (Client (..), Mode (..), clientRunBound, rejectedBecause, withPackageClient)
import Test.Support.Subprocess (runCaptured)

spec ∷ Spec
spec = describe "the store's public interface across the package boundary" $ do
  it "accepts and runs a client that plans, writes, publishes and reads through the public interface" $
    withClient "Main.hs" supportedClient $ \compile → do
      outcome ← compile Link
      case clientStatus outcome of
        ExitSuccess → pure ()
        status → expectationFailure ("the supported client must compile, but the compiler exited with " <> show status <> ":\n" <> clientOutput outcome)
      (status, out, err) ←
        runCaptured
          clientRunBound
          (proc (clientDirectory outcome </> "client") []) {cwd = Just (clientDirectory outcome)}
          ""
      status `shouldBe` ExitSuccess
      err `shouldBe` ""
      lines out `shouldBe` supportedOutput

  forM_ constructors $ \(name, imports) →
    it ("rejects a client that names the constructor of " <> name) $
      withClient "Client.hs" (clientImporting imports []) $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "GHC-10237"
        clientOutput outcome `shouldContain` name

  forM_ forged $ \(name, imports, source) →
    it ("rejects a client that builds " <> name <> " from its constructor") $
      withClient "Client.hs" (clientImporting imports source) $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "GHC-01928"
        clientOutput outcome `shouldContain` "Illegal term-level use of the type constructor"
        clientOutput outcome `shouldContain` name

  forM_ recordUpdates $ \(name, imports, source) →
    it ("rejects a client that rewrites " <> name <> " with record-update syntax") $
      withClient "Client.hs" (clientImporting imports source) $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "GHC-22385"
        clientOutput outcome `shouldContain` "Not in scope: record field"
        clientOutput outcome `shouldContain` name

  forM_ hidden $ \module' →
    it ("rejects a client that imports the private module " <> module') $
      withClient "Client.hs" (unlines ["module Client () where", "", "import " <> module']) $ \compile → do
        outcome ← compile Typecheck
        case clientStatus outcome of
          ExitFailure _ → pure ()
          ExitSuccess → expectationFailure ("the client compiled, so " <> module' <> " is reachable:\n" <> clientOutput outcome)
        clientOutput outcome `shouldContain` module'
        clientOutput outcome `shouldContain` "GHC-87110"

withClient ∷ FilePath → String → ((Mode → IO Client) → IO ()) → IO ()
withClient =
  withPackageClient
    ["base", "bytestring", "containers", "hetoimasia-terrain", "hetoimasia-terrain-runtime-0.1.0.0-inplace"]

clientImporting ∷ [String] → [String] → String
clientImporting imports body = unlines (["module Client () where", ""] <> imports <> [""] <> body)

store, admission ∷ String
store = "import Hetoimasia.Terrain.Runtime.Store ("
admission = "import Hetoimasia.Terrain.Runtime.Store.Admission ("

constructors ∷ [(String, [String])]
constructors =
  [ ("Plan", [store <> "Plan (Plan))"])
  , ("StoreConfig", [store <> "StoreConfig (StoreConfig))"])
  , ("Store", [store <> "Store (Store))"])
  , ("TxnId", [store <> "TxnId (TxnId))"])
  , ("ReaderToken", [store <> "ReaderToken (ReaderToken))"])
  , ("GrowthProposal", [store <> "GrowthProposal (GrowthProposal))"])
  , ("Roots", [store <> "Roots (Roots))"])
  , ("Window", [store <> "Window (Window))"])
  , ("EditBankConfig", [admission <> "EditBankConfig (EditBankConfig))"])
  , ("Admission", [admission <> "Admission (Admission))"])
  , ("Grant", [admission <> "Grant (Grant))"])
  , ("EntryId", [admission <> "EntryId (EntryId))"])
  ]

forged ∷ [(String, [String], [String])]
forged =
  [ ("Plan", [store <> "Plan)"], ["forged = Plan"])
  , ("TxnId", [store <> "TxnId)"], ["forged = TxnId"])
  , ("ReaderToken", [store <> "ReaderToken)"], ["forged = ReaderToken"])
  , ("GrowthProposal", [store <> "GrowthProposal)"], ["forged = GrowthProposal"])
  , ("StoreConfig", [store <> "StoreConfig)"], ["forged = StoreConfig"])
  ]

recordUpdates ∷ [(String, [String], [String])]
recordUpdates =
  [ ("planPages", [store <> "Plan, planPages)"], ["tamper ∷ Plan → Plan", "tamper p = p {planPages = []}"])
  , ("planEffects", [store <> "Plan, planEffects)"], ["tamper ∷ Plan → Plan", "tamper p = p {planEffects = undefined}"])
  , ("growthTo", [store <> "GrowthProposal, growthTo)"], ["tamper ∷ GrowthProposal → GrowthProposal", "tamper g = g {growthTo = 0}"])
  , ("rootsVersion", [store <> "Roots, rootsVersion)"], ["tamper ∷ Roots → Roots", "tamper r = r {rootsVersion = 0}"])
  ]

hidden ∷ [String]
hidden =
  [ "Hetoimasia.Terrain.Runtime.Store.Internal.Model"
  , "Hetoimasia.Terrain.Runtime.Store.Internal.Plan"
  , "Hetoimasia.Terrain.Runtime.Store.Internal.Page"
  , "Hetoimasia.Terrain.Runtime.Store.Internal.Tree"
  , "Hetoimasia.Terrain.Runtime.Store.Internal.State"
  , "Hetoimasia.Terrain.Runtime.Store.Internal.Crc32c"
  ]

-- | A client that stores one removal's records and reads them back.
supportedClient ∷ String
supportedClient =
  unlines
    [ "{-# LANGUAGE UnicodeSyntax #-}"
    , "module Main (main) where"
    , ""
    , "import qualified Data.Map.Strict as Map"
    , "import Hetoimasia.Terrain.Connectivity (defaultConnectivityLimits, prepareConnectivity)"
    , "import Hetoimasia.Terrain.Coordinate (tileCoord)"
    , "import Hetoimasia.Terrain.Discovery"
    , "import Hetoimasia.Terrain.Residency (ArenaId (..))"
    , "import Hetoimasia.Terrain.Runtime.Store"
    , "import Hetoimasia.Terrain.Runtime.Store.Admission"
    , "import Hetoimasia.Terrain.Source"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  cfg ← either (fail . show) pure (mkStoreConfig defaultStoreSpec)"
    , "  let ident = StoreIdentity (ArenaId 1) 7"
    , "      s0 = newStore cfg ident"
    , "  putStrLn (\"allowance \" <> show (usAllowanceBytes (usage s0)))"
    , "  source ← either (fail . show) pure (mkSource defaultSourceLimits (SourceSpec [\"stone\", \"slab\"] [LayerSpec Nothing (Just 8) \"stone\" 0] []))"
    , "  (conn, _) ← either (fail . show) pure (prepareConnectivity defaultConnectivityLimits source)"
    , "  limits ← either (fail . show) pure (mkDiscoveryLimits (DiscoverySpec 64 100000 100000 1048576 4194304 65536 50331648 1024))"
    , "  let env = mkEnv limits source conn"
    , "  tile ← either (fail . show) pure (tileCoord 3 3 3)"
    , "  case planRemoval env s0 (storeWindow s0) tile of"
    , "    Planned plan → do"
    , "      putStrLn (\"planned pages > 0: \" <> show (not (null (planPages plan))))"
    , "      putStrLn (\"within 256 pages: \" <> show (length (planPages plan) <= maxTxnPages))"
    , "      (tid, s1) ← either (fail . show) pure (admit plan s0)"
    , "      let write (s, file) (p, bytes) = do"
    , "            let (_, sa) = dispatchWrite tid p s"
    , "                (_, sb) = completeWrite tid p WriteDone sa"
    , "            pure (sb, Map.insert p bytes file)"
    , "      (s2, file) ← foldlM' write (s1, Map.empty) (planPages plan)"
    , "      putStrLn (\"eligible: \" <> show (eligibility tid s2 == Eligible))"
    , "      (published, s3) ← either (fail . show) pure (publish tid s2)"
    , "      putStrLn (\"version \" <> show (storeVersion s3) <> \" content revision advanced: \" <> show (effTerrain (pubEffects published)))"
    , "      (tok, s4) ← either (fail . show) pure (acquireReader s3)"
    , "      let load w = case readerLookup s4 tok w (KeyTodo 0) of"
    , "            ReadNeeds p → case Map.lookup p file of"
    , "              Just bytes → either (fail . show) load (addPage cfg p bytes w)"
    , "              Nothing → fail \"page not in the file\""
    , "            Read r → pure (r /= Nothing)"
    , "            other → fail (show other)"
    , "      readBack ← either (const (fail \"stale reader\")) load (readerWindow s4 tok)"
    , "      putStrLn (\"obligation read back: \" <> show readBack)"
    , "      case planMaintenance s4 (storeWindow s4) of"
    , "        NoWork → putStrLn \"nothing to reclaim\""
    , "        other → putStrLn (\"unexpected \" <> show (fmap (const ()) (Just other)))"
    , "      case proposeGrowth s4 (2 * 1024 * 1024 * 1024) of"
    , "        GrowthProposed g → putStrLn (\"growth \" <> show (growthFrom g) <> \" to \" <> show (growthTo g))"
    , "        other → putStrLn (\"growth refused \" <> show other)"
    , "      ebc ← either (fail . show) pure (mkEditBankConfig defaultEditBankSpec)"
    , "      case reserve Foreground (transactionCredits (ArenaId 1) worstTransactionCharge) (newAdmission ebc) of"
    , "        Right (grant, _) → putStrLn (\"worst transaction funded: \" <> show (length (grantEntries grant)))"
    , "        Left why → putStrLn (\"refused \" <> show why)"
    , "    other → putStrLn (\"not planned: \" <> show other)"
    , "  where"
    , "    foldlM' f z xs = go z xs"
    , "      where"
    , "        go acc [] = pure acc"
    , "        go acc (y : ys) = f acc y >>= \\acc' → go acc' ys"
    ]

supportedOutput ∷ [String]
supportedOutput =
  [ "allowance 1073741824"
  , "planned pages > 0: True"
  , "within 256 pages: True"
  , "eligible: True"
  , "version 1 content revision advanced: True"
  , "obligation read back: True"
  , "nothing to reclaim"
  , "growth 1073741824 to 2147483648"
  , "worst transaction funded: 1"
  ]
