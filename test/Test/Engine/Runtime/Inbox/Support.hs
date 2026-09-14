-- | Fixtures shared by the inbox service examples in "Test.Engine.Runtime.Inbox"
-- and "Test.Engine.Runtime.InboxFinish".
--
-- Each component context is a traced resource whose release records whether
-- the inbox still admits a message, through the send endpoint the start
-- returned, so a trace shows the inbox closed before the component was torn
-- down. Handlers signal entry through an 'MVar' and wait on a gate.
module Test.Engine.Runtime.Inbox.Support
  ( -- * Policies
    ignoreWrites
  , requiredInbox
  , optionalInbox
  , unrecognizedOptionalInbox

    -- * Services
  , Probe
  , probedContext
  , handling
  , inbox
  , ignore
  , startedWith
  , offer
  , holdingFirst
  , Provenance (..)
  , failingFirst

    -- * Reading outcomes
  , exitOf
  , resultName
  , statusName
  , statusOf
  , showText
  ) where

import Control.Concurrent.MVar (MVar, putMVar, readMVar, tryReadMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), rethrowIO, throwIO, toException)
import Control.Exception.Annotation (ExceptionAnnotation (displayExceptionAnnotation))
import Control.Exception.Context (addExceptionAnnotation, emptyExceptionContext)
import Control.Monad (when)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log (LogEntry)
import Hetoimasia.Foundation.Messaging.Channel (SendResult (..), Sender, send)
import Hetoimasia.Foundation.Messaging.Payload (Prepared, prepare, preparedValue)
import Hetoimasia.Foundation.Resource (Scoped, allocResource)
import Hetoimasia.Foundation.Worker (Completion (..), Result (..))
import Hetoimasia.Runtime.Inbox
import Hetoimasia.Runtime.Supervision (Disposition (..), Recognition (..), WorkerStatus (..))
import Numeric.Natural (Natural)
import Test.Engine.Runtime.Supervision.Support (Broken (..), Gate, Trace, record, supervisionComponent)

ignoreWrites ∷ LogEntry → IO ()
ignoreWrites _ = pure ()

requiredInbox, optionalInbox, unrecognizedOptionalInbox ∷ InboxPolicy
requiredInbox = InboxPolicy Required supervisionComponent (\_ → pure Unrecognized)
optionalInbox = InboxPolicy Optional supervisionComponent (\_ → pure Recognized)
unrecognizedOptionalInbox = InboxPolicy Optional supervisionComponent (\_ → pure Unrecognized)

-- | Where a started service's send endpoint is kept for the context's release.
type Probe = MVar (Sender Int)

-- | A traced context whose release records whether the inbox still admits a
-- message, or that no endpoint was ever handed out.
probedContext ∷ Trace → Probe → Scoped ()
probedContext trace probe =
  allocResource (record trace "acquire context") $ \() → do
    held ← tryReadMVar probe
    admission ← case held of
      Nothing → pure "no endpoint"
      Just sender → do
        payload ← prepare (0 ∷ Int)
        atomically (send sender payload) >>= \case
          Closed → pure "closed"
          _ → pure "open"
    record trace ("release context: inbox " <> admission)

-- | A handler that records each message, then runs a step for it.
handling ∷ Trace → (Int → IO ()) → () → Prepared Int → IO ()
handling trace step () message = do
  let value = preparedValue message
  record trace ("handle " <> showText value)
  step value

inbox ∷ Trace → Probe → Integer → (Int → IO ()) → InboxDefinition Int
inbox trace probe capacity step = inboxDefinition "inbox" capacity (\_ → probedContext trace probe) (handling trace step)

ignore ∷ Int → IO ()
ignore _ = pure ()

-- | Require a started service and keep its endpoint for the context's release.
startedWith ∷ Probe → InboxStart Int → IO (InboxService Int)
startedWith probe = \case
  InboxStarted started → putMVar probe (inboxSender started) >> pure started
  InboxStartUnavailable _ → throwIO (userError "expected a started inbox, found an unavailable one")
  InboxStartRejected → throwIO (userError "expected a started inbox, found a rejection")

offer ∷ InboxService Int → Int → IO SendResult
offer started value = prepare value >>= atomically . send (inboxSender started)

-- | Hold the handler inside message 1, after signalling entry, until the gate
-- opens.
holdingFirst ∷ MVar () → Gate → Int → IO ()
holdingFirst entered gate value = when (value == 1) (putMVar entered () >> readMVar gate)

-- | A context annotation the handler attaches to its own failure.
newtype Provenance = Provenance Text

instance ExceptionAnnotation Provenance where
  displayExceptionAnnotation (Provenance name) = "raised by " <> show name

-- | Throw from inside message 1 once the gate opens, with a 'Provenance'.
failingFirst ∷ MVar () → Gate → Int → IO ()
failingFirst entered gate value = when (value == 1) $ do
  putMVar entered ()
  readMVar gate
  rethrowIO (ExceptionWithContext (addExceptionAnnotation (Provenance "handler") emptyExceptionContext) (toException (Broken "handler")))

exitOf ∷ Completion InboxExit → Maybe Natural
exitOf completion = case completionResult completion of
  Succeeded exit → Just (inboxDiscarded exit)
  _ → Nothing

resultName ∷ Completion r → Text
resultName completion = case completionResult completion of
  Succeeded _ → "succeeded"
  Failed _ → "failed"
  Cancelled _ → "cancelled"

statusName ∷ WorkerStatus → Text
statusName = \case
  WorkerLive → "live"
  WorkerCompleted → "completed"
  WorkerStopped → "stopped"
  WorkerUnavailable _ → "unavailable"
  WorkerFatal _ → "fatal"

statusOf ∷ InboxService a → IO Text
statusOf started = statusName <$> atomically (inboxStatus started)

showText ∷ Show a ⇒ a → Text
showText = Text.pack . show
