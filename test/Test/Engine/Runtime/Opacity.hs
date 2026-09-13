-- | Examples proving that 'Hetoimasia.Runtime.Supervision.SupervisedWorker' is
-- a read-only handle to a client outside the runtime package.
--
-- A supervised handle pairs the foundation worker with the supervision state
-- registered for it. 'Hetoimasia.Runtime.Supervision.stopSupervised' and
-- 'Hetoimasia.Runtime.Supervision.cancelSupervised' record the owner's request
-- in that state and ask the worker to stop, and
-- 'Hetoimasia.Runtime.Supervision.workerStatus' reads only that state, so a
-- handle rewritten to pair one worker's state with another worker would record
-- a request against the wrong worker and report the wrong status.
--
-- These examples compile separate single-module clients with the harness from
-- "Test.Engine.Resources.Opacity", exposing @base@, @text@, @stm@,
-- @hetoimasia-foundation@, and @hetoimasia-runtime@ and hiding everything
-- else. Two clients must be rejected, each for the specific diagnostic naming
-- its cause, so a missing package, an absent compiler, or an unrelated error
-- can never pass for the boundary holding. One must be accepted, linked, and
-- run, which is both the environment control and the evidence that the
-- supported readers and operations stay usable.
module Test.Engine.Runtime.Opacity (spec) where

import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.Process (CreateProcess (cwd), proc, readCreateProcessWithExitCode)
import Test.Engine.Resources.Opacity (Client (..), Mode (..), rejectedBecause, withPackageClient)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldContain)

spec ∷ Spec
spec = describe "Supervised worker opacity across the package boundary" $ do
  it "rejects a client that replaces the raw worker with record update" $
    withClient "Client.hs" recordUpdateClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "Not in scope: record field"
      clientOutput outcome `shouldContain` "supervisedWorker"

  it "rejects a client that names the constructor" $
    withClient "Client.hs" constructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export any children"
      clientOutput outcome `shouldContain` "SupervisedWorker"

  it "accepts and runs a client using the reader, completion, status, stop, and cancel" $
    withClient "Main.hs" supportedClient $ \compile → do
      outcome ← compile Link
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ( "the supported client must compile, but the compiler exited with "
                <> show status
                <> ":\n"
                <> clientOutput outcome
            )
      (status, out, err) ←
        readCreateProcessWithExitCode
          (proc (clientDirectory outcome </> "client") []) { cwd = Just (clientDirectory outcome) }
          ""
      status `shouldBe` ExitSuccess
      err `shouldBe` ""
      lines out
        `shouldBe` [ "job result = 5"
                   , "job status = completed"
                   , "stopped status = stopped"
                   , "cancelled status = stopped"
                   ]

withClient ∷ FilePath → String → ((Mode → IO Client) → IO ()) → IO ()
withClient =
  withPackageClient ["base", "text", "stm", "hetoimasia-foundation", "hetoimasia-runtime"]

-- | The client from the issue: it pairs one handle's supervision state with
-- another handle's worker through record-update syntax, which needs only the
-- exported reader to be a field label.
--
-- The handles come in as arguments, because a client obtains them only from
-- 'Hetoimasia.Runtime.Supervision.startSupervised'; what is under test is the
-- rewrite, not the acquisition.
recordUpdateClient ∷ String
recordUpdateClient =
  unlines
    [ "module Client (rewritten) where"
    , ""
    , "import Hetoimasia.Runtime.Supervision (SupervisedWorker, supervisedWorker)"
    , ""
    , "rewritten ∷ SupervisedWorker r → SupervisedWorker r → SupervisedWorker r"
    , "rewritten first second = first { supervisedWorker = supervisedWorker second }"
    ]

-- | The other half of the same reach: assembling a handle from components of
-- the client's choosing by naming the constructor.
constructorClient ∷ String
constructorClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Runtime.Supervision (SupervisedWorker (SupervisedWorker))"
    , ""
    , "forged ∷ SupervisedWorker r → SupervisedWorker r"
    , "forged handle = handle"
    ]

-- | A client using only what the supervision interface offers: it starts a job
-- and two services, reads the job's result through 'supervisedWorker' and raw
-- completion, stops one service and cancels the other, and reports every
-- committed status.
supportedClient ∷ String
supportedClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import Control.Concurrent.STM (atomically)"
    , "import Data.Text (pack)"
    , "import Hetoimasia.Foundation.Log (callbackSink, defaultLogFilter, mkLogger, unsafeComponent)"
    , "import Hetoimasia.Foundation.Worker"
    , "  ( Completion (completionResult)"
    , "  , Result (Succeeded)"
    , "  , awaitCompletion"
    , "  , awaitStopRequest"
    , "  , workerDefinition"
    , "  )"
    , "import Hetoimasia.Runtime.Logging (withLoggingLifetime)"
    , "import Hetoimasia.Runtime.Supervision"
    , "  ( Disposition (Required)"
    , "  , Recognition (Unrecognized)"
    , "  , Role (Job, Service)"
    , "  , SupervisedStart (WorkerStarted)"
    , "  , SupervisedWorker"
    , "  , WorkerPolicy (WorkerPolicy)"
    , "  , WorkerStatus (..)"
    , "  , awaitSupervised"
    , "  , cancelSupervised"
    , "  , checkRuntime"
    , "  , startSupervised"
    , "  , stopSupervised"
    , "  , supervisedWorker"
    , "  , withSupervision"
    , "  , workerStatus"
    , "  )"
    , "import System.Exit (exitFailure)"
    , "import System.IO (hPutStrLn, stderr)"
    , ""
    , "policy ∷ Role → WorkerPolicy"
    , "policy role = WorkerPolicy role Required (unsafeComponent (pack \"client.supervision\")) (\\_ → pure Unrecognized)"
    , ""
    , "started ∷ SupervisedStart r → IO (SupervisedWorker r)"
    , "started (WorkerStarted handle) = pure handle"
    , "started _ = hPutStrLn stderr \"expected a started worker\" >> exitFailure"
    , ""
    , "named ∷ WorkerStatus → String"
    , "named status = case status of"
    , "  WorkerLive → \"live\""
    , "  WorkerCompleted → \"completed\""
    , "  WorkerStopped → \"stopped\""
    , "  WorkerUnavailable _ → \"unavailable\""
    , "  WorkerFatal _ → \"fatal\""
    , ""
    , "main ∷ IO ()"
    , "main ="
    , "  withLoggingLifetime (mkLogger defaultLogFilter (callbackSink (\\_ → pure ()))) $ \\lifetime →"
    , "    withSupervision lifetime $ \\control → do"
    , "      counted ← started =<< startSupervised control (policy Job)"
    , "        (workerDefinition (pack \"count\") (\\_ → pure ()) (\\_ () → pure (5 ∷ Int)))"
    , "      completion ← awaitSupervised control (awaitCompletion (supervisedWorker counted))"
    , "      case completionResult completion of"
    , "        Succeeded value → putStrLn (\"job result = \" <> show value)"
    , "        _ → hPutStrLn stderr \"the job did not succeed\" >> exitFailure"
    , "      let service name ="
    , "            workerDefinition (pack name) (\\_ → pure ()) (\\token () → atomically (awaitStopRequest token))"
    , "      stopped ← started =<< startSupervised control (policy Service) (service \"stopped\")"
    , "      cancelled ← started =<< startSupervised control (policy Service) (service \"cancelled\")"
    , "      stopSupervised stopped"
    , "      cancelSupervised cancelled"
    , "      _ ← awaitSupervised control (awaitCompletion (supervisedWorker stopped))"
    , "      _ ← awaitSupervised control (awaitCompletion (supervisedWorker cancelled))"
    , "      checkRuntime control"
    , "      statuses ← atomically ((,,) <$> workerStatus counted <*> workerStatus stopped <*> workerStatus cancelled)"
    , "      let (jobStatus, stoppedStatus, cancelledStatus) = statuses"
    , "      putStrLn (\"job status = \" <> named jobStatus)"
    , "      putStrLn (\"stopped status = \" <> named stoppedStatus)"
    , "      putStrLn (\"cancelled status = \" <> named cancelledStatus)"
    ]
