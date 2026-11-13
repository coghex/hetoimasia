-- | What the service's boundary exposes to a client.
--
-- A suite inside the package shares its module environment and can reach every
-- constructor, so it cannot observe the boundary. These examples compile
-- separate single-module clients with the harness from
-- "Test.Support.ExternalClient", exposing the public packages and hiding
-- everything else. One client must be accepted, linked and run: it composes the
-- public service end to end. Every other client must be refused for the
-- specific diagnostic that names its cause:
--
-- * the constructor of an authority (a client, a lease, a request, a view), of a
--   snapshot or of the service cannot be named, so a client cannot forge arena
--   authority, a mutable snapshot or the authority to settle a request:
--   @GHC-10237@ for an import and @GHC-01928@ for a term-level use;
-- * an exported accessor of a snapshot, or of a read-only inspection value (the census,
--   its arenas and requests, and the record of the owner's running work), is a function,
--   never a field label, so record-update syntax cannot rewrite one: @GHC-22385@; the
--   constructors of those inspection types are refused like an authority's, so a client
--   cannot construct or forge one (and none carries an authority, a handle or a
--   snapshot);
-- * each hidden module is refused as a hidden module of the package's library,
--   @GHC-87110@.
module Test.TerrainRuntime.Opacity (spec) where

import Control.Monad (forM_)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.Process (CreateProcess (cwd), proc)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldContain, shouldNotContain)
import Test.Support.ExternalClient (Client (..), Mode (..), clientRunBound, rejectedBecause, withPackageClient)
import Test.Support.Subprocess (runCaptured)

spec ∷ Spec
spec = describe "Terrain runtime opacity across the package boundary" $ do
  it "accepts and runs a client that composes the public service" $
    withClient "Main.hs" supportedClient $ \compile → do
      outcome <- compile Link
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ( "the supported client must compile, but the compiler exited with "
                <> show status
                <> ":\n"
                <> clientOutput outcome
            )
      (status, out, err) <-
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
        outcome <- compile Typecheck
        rejectedBecause outcome "GHC-10237"
        clientOutput outcome `shouldContain` name

  forM_ forged $ \(name, imports, source) →
    it ("rejects a client that builds " <> name <> " from its constructor") $
      withClient "Client.hs" (clientImporting imports source) $ \compile → do
        outcome <- compile Typecheck
        rejectedBecause outcome "GHC-01928"
        clientOutput outcome `shouldContain` "Illegal term-level use of the type constructor"
        clientOutput outcome `shouldContain` name

  forM_ recordUpdates $ \(name, imports, source) →
    it ("rejects a client that rewrites a snapshot through " <> name <> " with record-update syntax") $
      withClient "Client.hs" (clientImporting imports source) $ \compile → do
        outcome <- compile Typecheck
        rejectedBecause outcome "GHC-22385"
        clientOutput outcome `shouldContain` "Not in scope: record field"
        clientOutput outcome `shouldContain` name

  forM_ inspectionUpdates $ \(name, imports, source) →
    it ("rejects a client that rewrites an inspection value through " <> name <> " with record-update syntax") $
      withClient "Client.hs" (clientImporting imports source) $ \compile → do
        outcome <- compile Typecheck
        rejectedBecause outcome "GHC-22385"
        clientOutput outcome `shouldContain` "Not in scope: record field"
        clientOutput outcome `shouldContain` name

  forM_ hidden $ \module' →
    it ("rejects a client that imports the hidden module " <> module') $
      withClient "Client.hs" (unlines ["module Client () where", "", "import " <> module']) $ \compile → do
        outcome <- compile Typecheck
        case clientStatus outcome of
          ExitFailure _ → pure ()
          ExitSuccess →
            expectationFailure ("the client compiled, so " <> module' <> " is reachable:\n" <> clientOutput outcome)
        clientOutput outcome `shouldContain` module'
        clientOutput outcome `shouldContain` "GHC-87110"
        clientOutput outcome `shouldContain` "hetoimasia-terrain-runtime-0.1.0.0"
        clientOutput outcome `shouldNotContain` "cannot satisfy"
        clientOutput outcome `shouldNotContain` "Could not find module"

withClient ∷ FilePath → String → ((Mode → IO Client) → IO ()) → IO ()
withClient =
  withPackageClient
    ["base", "bytestring", "text", "stm", "hetoimasia-foundation", "hetoimasia-runtime", "hetoimasia-terrain", "hetoimasia-terrain-runtime-0.1.0.0-inplace"]

hidden ∷ [String]
hidden =
  [ "Hetoimasia.Terrain.Runtime.Internal.Content"
  , "Hetoimasia.Terrain.Runtime.Internal.Core"
  , "Hetoimasia.Terrain.Runtime.Internal.Owner"
  , "Hetoimasia.Terrain.Runtime.Internal.Snapshot"
  , "Hetoimasia.Terrain.Runtime.Internal.Types"
  ]

clientImporting ∷ [String] → [String] → String
clientImporting imports body = unlines (["module Client () where", ""] <> imports <> [""] <> body)

-- | An authority imported with its constructor: the type is exported
-- abstractly, so the import is refused.
constructors ∷ [(String, [String])]
constructors =
  [ ("Client", ["import Hetoimasia.Terrain.Runtime (Client (Client))"])
  , ("ArenaLease", ["import Hetoimasia.Terrain.Runtime (ArenaLease (ArenaLease))"])
  , ("Request", ["import Hetoimasia.Terrain.Runtime (Request (Request))"])
  , ("View", ["import Hetoimasia.Terrain.Runtime (View (View))"])
  , ("Snapshot", ["import Hetoimasia.Terrain.Runtime (Snapshot (Snapshot))"])
  , ("Service", ["import Hetoimasia.Terrain.Runtime (Service (Service))"])
  , ("Pending", ["import Hetoimasia.Terrain.Runtime (Pending (Pending))"])
  , -- The read-only inspection types: a client reads them through accessors only.
    ("Census", ["import Hetoimasia.Terrain.Runtime (Census (Census))"])
  , ("ArenaCensus", ["import Hetoimasia.Terrain.Runtime (ArenaCensus (ArenaCensus))"])
  , ("RequestCensus", ["import Hetoimasia.Terrain.Runtime (RequestCensus (RequestCensus))"])
  , ("RunningWork", ["import Hetoimasia.Terrain.Runtime (RunningWork (RunningWork))"])
  , ("JobWork", ["import Hetoimasia.Terrain.Runtime (JobWork (JobWork))"])
  , ("PreparationWork", ["import Hetoimasia.Terrain.Runtime (PreparationWork (PreparationWork))"])
  ]

-- | An authority forged by applying a constructor the client never imported.
forged ∷ [(String, [String], [String])]
forged =
  [ ("ArenaLease", ["import Hetoimasia.Terrain.Runtime (ArenaLease)"], ["forgedLease :: ArenaLease", "forgedLease = ArenaLease undefined 0"])
  , ("Client", ["import Hetoimasia.Terrain.Runtime (Client)"], ["forgedClient :: Client", "forgedClient = Client undefined 0"])
  , ("Request", ["import Hetoimasia.Terrain.Runtime (Request)"], ["forgedRequest :: Request", "forgedRequest = Request undefined undefined"])
  , ("Snapshot", ["import Hetoimasia.Terrain.Runtime (Snapshot)"], ["forgedSnapshot :: Snapshot", "forgedSnapshot = Snapshot undefined undefined undefined undefined undefined undefined"])
  , ("Census", ["import Hetoimasia.Terrain.Runtime (Census)"], ["forgedCensus :: Census", "forgedCensus = Census [] [] 0 undefined"])
  , ("ArenaCensus", ["import Hetoimasia.Terrain.Runtime (ArenaCensus)"], ["forgedArena :: ArenaCensus", "forgedArena = ArenaCensus undefined False undefined 0"])
  , ("RequestCensus", ["import Hetoimasia.Terrain.Runtime (RequestCensus)"], ["forgedRequestCensus :: RequestCensus", "forgedRequestCensus = RequestCensus 0 False False False False"])
  , ("RunningWork", ["import Hetoimasia.Terrain.Runtime (RunningWork)"], ["forgedWork :: RunningWork", "forgedWork = RunningWork undefined Nothing undefined"])
  , ("JobWork", ["import Hetoimasia.Terrain.Runtime (JobWork)"], ["forgedJob :: JobWork", "forgedJob = JobWork undefined undefined 0 0 1"])
  , ("PreparationWork", ["import Hetoimasia.Terrain.Runtime (PreparationWork)"], ["forgedPreparation :: PreparationWork", "forgedPreparation = PreparationWork undefined Nothing True 0 0 0 0"])
  ]

-- | A snapshot rewritten through an exported accessor used as a field label.
recordUpdates ∷ [(String, [String], [String])]
recordUpdates =
  [ ("snapshotRevision", ["import Hetoimasia.Terrain.Runtime (Snapshot, snapshotRevision)"], ["newer :: Snapshot -> Snapshot", "newer s = s {snapshotRevision = snapshotRevision s}"])
  , ("snapshotIncarnation", ["import Hetoimasia.Terrain.Runtime (Snapshot, snapshotIncarnation)"], ["other :: Snapshot -> Snapshot", "other s = s {snapshotIncarnation = snapshotIncarnation s}"])
  , ("snapshotGeneration", ["import Hetoimasia.Terrain.Runtime (Snapshot, snapshotGeneration)"], ["later :: Snapshot -> Snapshot", "later s = s {snapshotGeneration = snapshotGeneration s}"])
  ]

-- | An inspection value rewritten through an exported accessor used as a field label:
-- the accessors are functions, never field labels, so the update is refused.
inspectionUpdates ∷ [(String, [String], [String])]
inspectionUpdates =
  [ ("censusArenas", ["import Hetoimasia.Terrain.Runtime (Census, censusArenas)"], ["emptied :: Census -> Census", "emptied c = c {censusArenas = []}"])
  , ("censusRetainedBytes", ["import Hetoimasia.Terrain.Runtime (ArenaCensus, censusRetainedBytes)"], ["lighter :: ArenaCensus -> ArenaCensus", "lighter a = a {censusRetainedBytes = 0}"])
  , ("censusModelRecord", ["import Hetoimasia.Terrain.Runtime (RequestCensus, censusModelRecord)"], ["recordless :: RequestCensus -> RequestCensus", "recordless r = r {censusModelRecord = False}"])
  , ("jobWorkResident", ["import Hetoimasia.Terrain.Runtime (JobWork, jobWorkResident)"], ["cheaper :: JobWork -> JobWork", "cheaper j = j {jobWorkResident = 0}"])
  , ("preparationStaging", ["import Hetoimasia.Terrain.Runtime (PreparationWork, preparationStaging)"], ["lean :: PreparationWork -> PreparationWork", "lean p = p {preparationStaging = 0}"])
  , ("runningJobs", ["import Hetoimasia.Terrain.Runtime (RunningWork, runningJobs)"], ["idle :: RunningWork -> RunningWork", "idle w = w {runningJobs = []}"])
  ]

supportedClient ∷ String
supportedClient =
  unlines
    [ "{-# LANGUAGE OverloadedStrings #-}"
    , "module Main (main) where"
    , ""
    , "import Control.Concurrent.STM (atomically)"
    , "import Hetoimasia.Foundation.Log (callbackSink, defaultLogFilter, mkLogger)"
    , "import Hetoimasia.Foundation.Worker (withWorkerGroup)"
    , "import Hetoimasia.Terrain.Cell"
    , "import Hetoimasia.Terrain.Coordinate"
    , "import Hetoimasia.Terrain.Residency (Revision (..))"
    , "import Hetoimasia.Terrain.Runtime"
    , "import qualified Hetoimasia.Terrain.Runtime.Storage as Storage"
    , "import Hetoimasia.Terrain.Runtime.Store (StoreSpec (..), defaultStoreSpec, minAllowanceBytes)"
    , "import Hetoimasia.Terrain.Source"
    , ""
    , "main :: IO ()"
    , "main = withWorkerGroup $ \\group -> do"
    , "  -- the arenas' private files go in this directory (the client's own), on its qualified filesystem"
    , "  Right name <- Storage.filesystemOf \".\""
    , "  let Right storage = Storage.mkStorageConfig [name] Storage.minHeadroomBytes"
    , "      logger = mkLogger defaultLogFilter (callbackSink (\\_ -> pure ()))"
    , "      ports = Ports alwaysAdmitting (standaloneSupervisor group) logger noProbe (storagePort group storage \".\")"
    , "      config = defaultConfig {configStore = defaultStoreSpec {specAllowanceBytes = toInteger minAllowanceBytes}}"
    , "      definition = SourceSpec [\"soil\"] [LayerSpec Nothing (Just 10) \"soil\" 0] []"
    , "  withTerrainService config ports $ \\svc -> do"
    , "    Right client <- registerClient svc"
    , "    Right opened <- openArena svc client \"main\" definition"
    , "    Right lease <- await svc opened"
    , "    let Right at = tileCoord 1 2 3"
    , "    Right reading <- cellAt svc lease at"
    , "    Right answer <- await svc reading"
    , "    print (cellRevision answer, fmap (const ()) (Just (cellValue answer)))"
    , "    Right removing <- removeAt svc lease at Nothing"
    , "    Right removed <- await svc removing"
    , "    print (removeChangedFlag removed, removeRevision removed)"
    , "    Right again <- cellAt svc lease at"
    , "    Right second <- await svc again"
    , "    print (cellRevision second, cellValue second == Air)"
    , "    refused <- releaseLease svc lease"
    , "    print refused"
    , "    Right opened2 <- openArena svc client \"main\" definition"
    , "    Right lease2 <- await svc opened2"
    , "    Right third <- cellAt svc lease2 at"
    , "    Right fresh <- await svc third"
    , "    print (cellRevision fresh == Revision 0)"
    , "    census <- atomically (inspectCensusSTM svc)"
    , "    print (censusBorrows census, length (runningJobs (censusRunning census)))"
    , "    inspectInvariants svc >>= print"
    ]

supportedOutput ∷ [String]
supportedOutput =
  [ "(Revision 0,Just ())"
  , "(True,Revision 1)"
  , "(Revision 1,True)"
  , "Right ()"
  , "True"
  , "(0,0)"
  , "[]"
  ]
