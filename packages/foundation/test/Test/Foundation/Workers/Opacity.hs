-- | Examples proving that the worker group's coordination probe stays inside
-- the foundation package while the drain status is public.
--
-- The worker examples import the probe from the package's private
-- implementation library, which this suite may reach because it belongs to the
-- same package. These examples therefore compile separate single-module
-- clients against this build's package database, exposing @base@, @stm@,
-- @text@, and @hetoimasia-foundation@ and hiding everything else, as the resource opacity
-- examples do.
--
-- Three clients are compiled. Two must be rejected, each for its own cause: the
-- public module does not export the probe, and the implementation module lives
-- in a library no client can expose. The third must be accepted, linked, and
-- run: it is the control proving the environment is sound, and the evidence
-- that a client reads the drain status through the public module alone.
module Test.Foundation.Workers.Opacity (spec) where

import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.Process (CreateProcess (cwd), proc, readCreateProcessWithExitCode)
import Test.Hspec
  ( Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldContain
  , shouldNotContain
  )
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withPackageClient)

spec ∷ Spec
spec = describe "Probe opacity across the package boundary" $ do
  it "rejects a client that imports the probe from the public module" $
    withClient "Client.hs" publicProbeClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export"
      clientOutput outcome `shouldContain` "withWorkerGroupProbed"

  it "rejects a client that imports the probe from the implementation module" $
    withClient "Client.hs" internalProbeClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess →
          expectationFailure ("the client compiled, so the probe is reachable:\n" <> clientOutput outcome)
      -- Found in the package's private implementation library and refused as
      -- hidden; naming that library's unit tells this apart from a missing
      -- package.
      clientOutput outcome `shouldContain` "GHC-87110"
      clientOutput outcome `shouldContain` "hetoimasia-foundation-0.1.0.0:internal"
      clientOutput outcome `shouldNotContain` "cannot satisfy"

  it "accepts and runs a client that reads the drain status through the public module" $
    withClient "Main.hs" statusClient $ \compile → do
      outcome ← compile Link
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ("the status client did not build (" <> show status <> "):\n" <> clientOutput outcome)
      (status, out, err) ←
        readCreateProcessWithExitCode
          (proc (clientDirectory outcome </> "client") []) {cwd = Just (clientDirectory outcome)}
          ""
      status `shouldBe` ExitSuccess
      err `shouldBe` ""
      lines out `shouldBe` ["open [\"waiting\"]", "closed []"]

withClient ∷ FilePath → String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withPackageClient ["base", "stm", "text", "hetoimasia-foundation"]

publicProbeClient ∷ String
publicProbeClient =
  unlines
    [ "module Client (probed) where"
    , ""
    , "import Hetoimasia.Foundation.Worker (withWorkerGroupProbed)"
    , ""
    , "probed = withWorkerGroupProbed"
    ]

internalProbeClient ∷ String
internalProbeClient =
  unlines
    [ "module Client (probed) where"
    , ""
    , "import Hetoimasia.Foundation.Worker.Internal (withWorkerGroupProbed)"
    , ""
    , "probed = withWorkerGroupProbed"
    ]

statusClient ∷ String
statusClient =
  unlines
    [ "{-# LANGUAGE OverloadedStrings #-}"
    , "module Main (main) where"
    , ""
    , "import Control.Concurrent.STM (atomically)"
    , "import Hetoimasia.Foundation.Worker"
    , ""
    , "describeStatus ∷ GroupStatus → String"
    , "describeStatus status ="
    , "  phase (statusPhase status) <> \" \" <> show (map outstandingLabel (statusOutstanding status))"
    , "  where"
    , "    phase GroupOpen = \"open\""
    , "    phase GroupClosing = \"closing\""
    , "    phase GroupClosed = \"closed\""
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  group ← withWorkerGroup $ \\group → do"
    , "    started ← startWorker group (workerDefinition \"waiting\" (\\_ → pure ()) (\\token () → atomically (awaitStopRequest token)))"
    , "    case started of"
    , "      Started _ → pure ()"
    , "      _ → fail \"the worker did not start\""
    , "    atomically (groupStatus group) >>= putStrLn . describeStatus"
    , "    pure group"
    , "  atomically (groupStatus group) >>= putStrLn . describeStatus"
    ]
