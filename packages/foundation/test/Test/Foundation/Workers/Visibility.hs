-- | Examples proving that the worker group's implementation modules stay
-- inside the foundation package while its public module keeps every name it
-- exports and every abstract type stays closed.
--
-- "Hetoimasia.Foundation.Worker" re-exports what clients may use from the
-- package-private facade "Hetoimasia.Foundation.Worker.Internal", which
-- composes eight hidden modules of the package's private @internal@
-- sublibrary. An example in this suite cannot observe that boundary, so these
-- examples compile separate single-module clients with the harness from
-- "Test.Support.ExternalClient", exposing @base@, @text@, and
-- @hetoimasia-foundation@ and hiding everything else, as the resource
-- visibility examples do.
--
-- One client must be accepted: it imports, by name, every name the public
-- module exports, with exactly the constructors and fields it exports. Every
-- other client is compiled on its own, so one rejected import cannot conceal
-- another becoming reachable, and must be rejected for the diagnostic naming
-- its cause. A client importing a hidden module is refused with @GHC-87110@
-- against the private sublibrary's unit; a client asking the public module for
-- an abstract type's constructor is refused with @GHC-10237@.
module Test.Foundation.Workers.Visibility (spec) where

import Control.Monad (forM_)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import Test.Hspec
  ( Spec
  , describe
  , expectationFailure
  , it
  , shouldContain
  , shouldNotContain
  )
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withPackageClient)

spec ∷ Spec
spec = describe "Worker module visibility across the package boundary" $ do
  it "accepts a client that imports every public worker name" $
    withClient supportedClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ( "the supported client must compile, but the compiler exited with "
                <> show status
                <> ":\n"
                <> clientOutput outcome
            )

  forM_ privateModules $ \hidden →
    it ("rejects a client that imports the private module " <> hidden) $
      withClient (importClient hidden) $ \compile → do
        outcome ← compile Typecheck
        case clientStatus outcome of
          ExitFailure _ → pure ()
          ExitSuccess →
            expectationFailure ("the client compiled, so " <> hidden <> " is reachable:\n" <> clientOutput outcome)
        -- Found in the package's private sublibrary and refused as hidden;
        -- naming that unit tells this apart from a missing module or an
        -- unresolvable package.
        clientOutput outcome `shouldContain` "GHC-87110"
        clientOutput outcome `shouldContain` "hetoimasia-foundation-0.1.0.0:internal"
        clientOutput outcome `shouldNotContain` "cannot satisfy"
        clientOutput outcome `shouldNotContain` "Could not find module"

  forM_ abstractTypes $ \abstract →
    it ("rejects a client that asks " <> public <> " for the " <> abstract <> " constructor") $
      withClient (constructorClient abstract) $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "GHC-10237"
        clientOutput outcome `shouldContain` abstract

withClient ∷ String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withPackageClient ["base", "text", "hetoimasia-foundation"] "Client.hs"

-- | The public module every client below imports from.
public ∷ String
public = "Hetoimasia.Foundation.Worker"

-- | The worker modules hidden inside the private sublibrary, behind its
-- facade.
privateModules ∷ [String]
privateModules =
  [ "Hetoimasia.Foundation.Worker.Base"
  , "Hetoimasia.Foundation.Worker.Outcome"
  , "Hetoimasia.Foundation.Worker.Types"
  , "Hetoimasia.Foundation.Worker.Evidence"
  , "Hetoimasia.Foundation.Worker.Observation"
  , "Hetoimasia.Foundation.Worker.Requests"
  , "Hetoimasia.Foundation.Worker.Startup"
  , "Hetoimasia.Foundation.Worker.Group"
  ]

-- | Every type the public module exports without its constructor.
abstractTypes ∷ [String]
abstractTypes = ["WorkerGroup", "WorkerDefinition", "StopToken", "Worker", "WorkerId"]

importClient ∷ String → String
importClient hidden = unlines ["module Client () where", "", "import " <> hidden]

constructorClient ∷ String → String
constructorClient abstract =
  unlines
    [ "module Client () where"
    , ""
    , "import " <> public <> " (" <> abstract <> " (" <> abstract <> "))"
    ]

supportedClient ∷ String
supportedClient =
  unlines
    [ "module Client () where"
    , ""
    , "import Hetoimasia.Foundation.Worker"
    , "  ( WorkerGroup"
    , "  , withWorkerGroup"
    , "  , allocWorkerGroup"
    , "  , closeWorkerGroup"
    , "  , activeWorkerCount"
    , "  , GroupStatus (GroupStatus, statusPhase, statusOutstanding)"
    , "  , GroupPhase (GroupOpen, GroupClosing, GroupClosed)"
    , "  , OutstandingWorker"
    , "      ( OutstandingWorker"
    , "      , outstandingWorker"
    , "      , outstandingLabel"
    , "      , outstandingAcknowledged"
    , "      , outstandingRequested"
    , "      , outstandingCancelDelivered"
    , "      , outstandingState"
    , "      , outstandingHelpers"
    , "      )"
    , "  , Outstanding (AwaitingTerminal, AwaitingHelpers)"
    , "  , groupStatus"
    , "  , WorkerDefinition"
    , "  , workerDefinition"
    , "  , StopToken"
    , "  , stopRequested"
    , "  , awaitStopRequest"
    , "  , Worker"
    , "  , workerId"
    , "  , workerLabel"
    , "  , WorkerId"
    , "  , StartOutcome (Started, StartupFailed, StartRejected)"
    , "  , StartRejection (RegistrationClosed)"
    , "  , startWorker"
    , "  , startWorkerWith"
    , "  , requestStop"
    , "  , requestCancel"
    , "  , WorkerCancelled (WorkerCancelled)"
    , "  , Startup (Acknowledged, NotAcknowledged)"
    , "  , awaitStartup"
    , "  , awaitCompletion"
    , "  , pollCompletion"
    , "  , observeCompletion"
    , "  , Completion"
    , "      ( Completion"
    , "      , completionWorker"
    , "      , completionLabel"
    , "      , completionExit"
    , "      , completionResult"
    , "      , completionCleanup"
    , "      )"
    , "  , Result (Succeeded, Failed, Cancelled)"
    , "  , RunExit (RunNotEntered, RunExited)"
    , "  , RunEnd (RunReturned, RunFailed, RunCancelled)"
    , "  , Requested (NothingRequested, StopWasRequested, CancelWasRequested)"
    , "  , WorkerSummary"
    , "  , GroupReport (GroupReport, reportExitedBeforeClosing, reportDrained, reportObservedFailures)"
    , "  , WorkerEvidence (AbandonedStart, GroupExit)"
    , "  , workerEvidence"
    , "  , workerEvidenceInContext"
    , "  )"
    ]
