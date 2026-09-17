-- | Examples proving that 'Hetoimasia.Runtime.Supervision.SupervisedWorker' is
-- a read-only handle to a client outside the runtime package, and that
-- 'Hetoimasia.Runtime.Inbox' keeps its service handle and exit record closed.
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
-- "Test.Support.ExternalClient", exposing @base@, @text@, @stm@,
-- @hetoimasia-foundation@, and @hetoimasia-runtime@ and hiding everything
-- else. For the supervised handle two clients must be rejected, and for the
-- inbox service's handle, definition, start result, exit record, and drain
-- acknowledgement nine, each for the specific diagnostic naming its cause, so a
-- missing package, an absent compiler, or an unrelated error can never pass for
-- the boundary holding. One client for the supervised handle and two for the
-- inbox — one stopping a service, one finishing it — must be accepted, linked,
-- and run, which is both the environment control and the evidence that the
-- supported readers and operations stay usable.
module Test.Runtime.Opacity (spec) where

import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.Process (CreateProcess (cwd), proc, readCreateProcessWithExitCode)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldContain)
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withPackageClient)

spec ∷ Spec
spec = do
  supervisedSpec
  inboxSpec

supervisedSpec ∷ Spec
supervisedSpec = describe "Supervised worker opacity across the package boundary" $ do
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

-- Inbox services ---------------------------------------------------------------

-- | Examples proving that an inbox service's handle, its definition, and its
-- exit record stay closed to a client outside the runtime package.
--
-- A service handle pairs one supervised worker with the send endpoint its
-- startup handed off, so a rewritten handle would let a producer send to one
-- service while its owner stops another. The definition's constructor would
-- let a client build the startup, and so the handoff, itself. An exit record
-- rebuilt or updated by a client would claim a discard count no inbox counted,
-- or a drain no service acknowledged, and a forged acknowledgement would claim
-- the same. A failed start carries no service handle at all.
inboxSpec ∷ Spec
inboxSpec = describe "Inbox service opacity across the package boundary" $ do
  it "rejects a client that replaces a service's endpoint with record update" $
    withClient "Client.hs" inboxRecordUpdateClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "Not in scope: record field"
      clientOutput outcome `shouldContain` "inboxSender"

  it "rejects a client that names the service handle's constructor" $
    withClient "Client.hs" (importingClient "InboxService (InboxService)") $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export any children"
      clientOutput outcome `shouldContain` "InboxService"

  it "rejects a client that names the definition's constructor to build its own startup and handoff" $
    withClient "Client.hs" (importingClient "InboxDefinition (InboxDefinition)") $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export any children"
      clientOutput outcome `shouldContain` "InboxDefinition"

  it "rejects a client that takes a send endpoint from an unavailable start" $
    withClient "Client.hs" failedStartClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "should have 1 argument"
      clientOutput outcome `shouldContain` "InboxStartUnavailable"

  it "rejects a client that constructs an exit record" $
    withClient "Client.hs" (importingClient "InboxExit (InboxExit)") $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export any children"
      clientOutput outcome `shouldContain` "InboxExit"

  it "rejects a client that updates an exit record's discard count" $
    withClient "Client.hs" exitUpdateClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "Not in scope: record field"
      clientOutput outcome `shouldContain` "inboxDiscarded"

  it "rejects a client that updates an exit record's drain acknowledgement" $
    withClient "Client.hs" drainUpdateClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "Not in scope: record field"
      clientOutput outcome `shouldContain` "inboxDrain"

  it "rejects a client that forges a drain acknowledgement with its constructor" $
    withClient "Client.hs" (importingClient "DrainAcknowledgement (DrainAcknowledgement)") $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export any children"
      clientOutput outcome `shouldContain` "DrainAcknowledgement"

  it "rejects a client that rewrites a drain acknowledgement's handled count" $
    withClient "Client.hs" handledUpdateClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "Not in scope: record field"
      clientOutput outcome `shouldContain` "drainHandled"

  it "accepts and runs a client that starts a service, sends, stops it, and reads its discard count" $
    withClient "Main.hs" inboxClient $ \compile → do
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
      lines out `shouldBe` ["sends = [Accepted,Accepted]", "discarded = 2"]

  it "accepts and runs a client that finishes a service and reads both exit record accessors" $
    withClient "Main.hs" finishClient $ \compile → do
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
      lines out `shouldBe` ["sends = [Accepted,Accepted]", "discarded = 0", "drained after = Just 2", "handle drained after = Just 2"]

-- | A client that only imports the named item from the inbox module.
importingClient ∷ String → String
importingClient item =
  unlines
    [ "module Client () where"
    , ""
    , "import Hetoimasia.Runtime.Inbox (" <> item <> ")"
    ]

-- | Pairs one service's worker with another service's endpoint through
-- record-update syntax, which needs only the exported reader to be a field.
inboxRecordUpdateClient ∷ String
inboxRecordUpdateClient =
  unlines
    [ "module Client (rewritten) where"
    , ""
    , "import Hetoimasia.Runtime.Inbox (InboxService, inboxSender)"
    , ""
    , "rewritten ∷ InboxService a → InboxService a → InboxService a"
    , "rewritten first second = first { inboxSender = inboxSender second }"
    ]

-- | Expects an unavailable start to carry a service whose endpoint it can read.
failedStartClient ∷ String
failedStartClient =
  unlines
    [ "module Client (endpoint) where"
    , ""
    , "import Hetoimasia.Foundation.Messaging.Channel (Sender)"
    , "import Hetoimasia.Runtime.Inbox (InboxStart (..), inboxSender)"
    , ""
    , "endpoint ∷ InboxStart a → Maybe (Sender a)"
    , "endpoint (InboxStartUnavailable service _) = Just (inboxSender service)"
    , "endpoint _ = Nothing"
    ]

-- | Rewrites the discard count of an exit record it was given.
exitUpdateClient ∷ String
exitUpdateClient =
  unlines
    [ "module Client (reset) where"
    , ""
    , "import Hetoimasia.Runtime.Inbox (InboxExit, inboxDiscarded)"
    , ""
    , "reset ∷ InboxExit → InboxExit"
    , "reset exit = exit { inboxDiscarded = 0 }"
    ]

-- | Rewrites the drain acknowledgement of an exit record it was given.
drainUpdateClient ∷ String
drainUpdateClient =
  unlines
    [ "module Client (undrained) where"
    , ""
    , "import Hetoimasia.Runtime.Inbox (InboxExit, inboxDrain)"
    , ""
    , "undrained ∷ InboxExit → InboxExit"
    , "undrained exit = exit { inboxDrain = Nothing }"
    ]

-- | Rewrites the handled count of a drain acknowledgement it was given.
handledUpdateClient ∷ String
handledUpdateClient =
  unlines
    [ "module Client (inflated) where"
    , ""
    , "import Hetoimasia.Runtime.Inbox (DrainAcknowledgement, drainHandled)"
    , ""
    , "inflated ∷ DrainAcknowledgement → DrainAcknowledgement"
    , "inflated acknowledgement = acknowledgement { drainHandled = 99 }"
    ]

-- | A client using only what the inbox interface offers: it holds the handler
-- inside the first message, queues two more, stops the service, and reads the
-- discard count from the completion's exit record.
inboxClient ∷ String
inboxClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)"
    , "import Control.Concurrent.STM (atomically)"
    , "import Control.Monad (when)"
    , "import Data.Text (pack)"
    , "import Hetoimasia.Foundation.Log (callbackSink, defaultLogFilter, mkLogger, unsafeComponent)"
    , "import Hetoimasia.Foundation.Messaging.Channel (send)"
    , "import Hetoimasia.Foundation.Messaging.Payload (Prepared, prepare, preparedValue)"
    , "import Hetoimasia.Foundation.Worker (Completion (completionResult), Result (Succeeded))"
    , "import Hetoimasia.Runtime.Inbox"
    , "  ( InboxPolicy (InboxPolicy)"
    , "  , InboxStart (InboxStarted)"
    , "  , awaitInboxCompletion"
    , "  , inboxDefinition"
    , "  , inboxDiscarded"
    , "  , inboxSender"
    , "  , startInboxService"
    , "  , stopInboxService"
    , "  )"
    , "import Hetoimasia.Runtime.Logging (withLoggingLifetime)"
    , "import Hetoimasia.Runtime.Supervision (Disposition (Required), Recognition (Unrecognized), awaitSupervised, withSupervision)"
    , "import System.Exit (exitFailure)"
    , "import System.IO (hPutStrLn, stderr)"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  entered ← newEmptyMVar"
    , "  gate ← newEmptyMVar"
    , "  let policy = InboxPolicy Required (unsafeComponent (pack \"client.inbox\")) (\\_ → pure Unrecognized)"
    , "      handler ∷ () → Prepared Int → IO ()"
    , "      handler () message = when (preparedValue message == 1) (putMVar entered () >> readMVar gate)"
    , "  withLoggingLifetime (mkLogger defaultLogFilter (callbackSink (\\_ → pure ()))) $ \\lifetime →"
    , "    withSupervision lifetime $ \\control → do"
    , "      started ← startInboxService control policy (inboxDefinition (pack \"client\") 4 (\\_ → pure ()) handler)"
    , "      service ← case started of"
    , "        InboxStarted service → pure service"
    , "        _ → hPutStrLn stderr \"expected a started inbox service\" >> exitFailure"
    , "      let offer value = prepare value >>= atomically . send (inboxSender service)"
    , "      _ ← offer 1"
    , "      readMVar entered"
    , "      sends ← traverse offer [2, 3]"
    , "      putStrLn (\"sends = \" <> show sends)"
    , "      stopInboxService service"
    , "      putMVar gate ()"
    , "      completion ← awaitSupervised control (awaitInboxCompletion service)"
    , "      case completionResult completion of"
    , "        Succeeded exit → putStrLn (\"discarded = \" <> show (inboxDiscarded exit))"
    , "        _ → hPutStrLn stderr \"the inbox service did not stop cleanly\" >> exitFailure"
    ]

-- | A client using only what the inbox interface offers to finish a service: it
-- sends two messages, finishes the service, and reads the discard count and the
-- drain acknowledgement from the exit record and from the service handle.
finishClient ∷ String
finishClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import Control.Concurrent.STM (atomically)"
    , "import Data.Text (pack)"
    , "import Hetoimasia.Foundation.Log (callbackSink, defaultLogFilter, mkLogger, unsafeComponent)"
    , "import Hetoimasia.Foundation.Messaging.Channel (send)"
    , "import Hetoimasia.Foundation.Messaging.Payload (Prepared, prepare)"
    , "import Hetoimasia.Runtime.Inbox"
    , "  ( InboxFinish (InboxFinished)"
    , "  , InboxPolicy (InboxPolicy)"
    , "  , InboxStart (InboxStarted)"
    , "  , drainHandled"
    , "  , finishInboxService"
    , "  , inboxAcknowledgedDrain"
    , "  , inboxDefinition"
    , "  , inboxDiscarded"
    , "  , inboxDrain"
    , "  , inboxSender"
    , "  , startInboxService"
    , "  )"
    , "import Hetoimasia.Runtime.Logging (withLoggingLifetime)"
    , "import Hetoimasia.Runtime.Supervision (Disposition (Required), Recognition (Unrecognized), withSupervision)"
    , "import System.Exit (exitFailure)"
    , "import System.IO (hPutStrLn, stderr)"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  let policy = InboxPolicy Required (unsafeComponent (pack \"client.inbox\")) (\\_ → pure Unrecognized)"
    , "      handler ∷ () → Prepared Int → IO ()"
    , "      handler () _ = pure ()"
    , "  withLoggingLifetime (mkLogger defaultLogFilter (callbackSink (\\_ → pure ()))) $ \\lifetime →"
    , "    withSupervision lifetime $ \\control → do"
    , "      started ← startInboxService control policy (inboxDefinition (pack \"client\") 4 (\\_ → pure ()) handler)"
    , "      service ← case started of"
    , "        InboxStarted service → pure service"
    , "        _ → hPutStrLn stderr \"expected a started inbox service\" >> exitFailure"
    , "      sends ← traverse (\\value → prepare value >>= atomically . send (inboxSender service)) [1, 2]"
    , "      putStrLn (\"sends = \" <> show sends)"
    , "      finishInboxService control service >>= \\case"
    , "        InboxFinished exit → do"
    , "          putStrLn (\"discarded = \" <> show (inboxDiscarded exit))"
    , "          putStrLn (\"drained after = \" <> show (drainHandled <$> inboxDrain exit))"
    , "        _ → hPutStrLn stderr \"the inbox service did not finish\" >> exitFailure"
    , "      acknowledged ← atomically (inboxAcknowledgedDrain service)"
    , "      putStrLn (\"handle drained after = \" <> show (drainHandled <$> acknowledged))"
    ]
