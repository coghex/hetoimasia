-- | Examples proving that 'Hetoimasia.Foundation.Messaging.Payload.Prepared'
-- can be obtained only through preparation, and that each channel endpoint of
-- "Hetoimasia.Foundation.Messaging.Channel" carries only its own authority, from
-- clients outside the foundation package.
--
-- These examples compile separate single-module clients with the harness from
-- "Test.Engine.Resources.Opacity", exposing @base@, @deepseq@, and
-- @hetoimasia-foundation@ and hiding everything else; @deepseq@ is exposed
-- because every client that defines a payload imports "Control.DeepSeq".
--
-- Six clients must be rejected, each for the specific diagnostic naming its
-- cause, so a missing package, an absent compiler, or an unrelated error can
-- never pass for the boundary holding. Two of them reach for 'Data.Coerce':
-- one wraps an unprepared value, and one changes a handle's payload type
-- between two client newtypes over the same representation. The second is the
-- one that proves the nominal role, and it carries a control coercion between
-- the two newtypes themselves in the same module, which must not be reported.
--
-- One client must be accepted, linked, and run. It is the environment control,
-- and it shows that preparing, reading, and forwarding stay usable, with
-- unconstrained polymorphic readers and forwarders that require no 'NFData'.
--
-- The channel clients also expose @stm@. Five must be rejected for their named
-- cause: receiving from a send endpoint, closing from a send or a receive
-- endpoint, naming an endpoint's constructor, and replacing an endpoint through
-- record update. One must be accepted, linked, and run, using every supported
-- send, receive, control, and statistics operation.
module Test.Engine.Messaging.Opacity (spec) where

import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.Process (CreateProcess (cwd), proc, readCreateProcessWithExitCode)
import Test.Engine.Resources.Opacity (Client (..), Mode (..), rejectedBecause, withPackageClient)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldContain, shouldNotContain)

spec ∷ Spec
spec = do
  payloadSpec
  channelSpec

payloadSpec ∷ Spec
payloadSpec = describe "Prepared payload opacity across the package boundary" $ do
  it "rejects a client that names the constructor" $
    withClient constructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export any children"
      clientOutput outcome `shouldContain` "Prepared"

  it "rejects a client that replaces the payload with record update" $
    withClient recordUpdateClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "Not in scope: record field"
      clientOutput outcome `shouldContain` "preparedValue"

  it "rejects a client that wraps an unprepared value with coerce" $
    withClient wrapCoerceClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "Couldn't match representation of type"
      clientOutput outcome `shouldContain` "is not in scope"

  it "rejects a client that changes the payload type with coerce between equivalent newtypes" $
    withClient retypeCoerceClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "Couldn't match type"
      clientOutput outcome `shouldContain` "Metres"
      clientOutput outcome `shouldContain` "Feet"
      clientOutput outcome `shouldContain` ("Client.hs:" <> show retypeLine <> ":")
      -- The control coercion between the newtypes themselves is accepted, so
      -- only the role of Prepared can have caused the rejection.
      clientOutput outcome `shouldNotContain` ("Client.hs:" <> show controlLine <> ":")

  it "rejects a client that maps over a handle with fmap" $
    withClient fmapClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "No instance for"
      clientOutput outcome `shouldContain` "Functor Prepared"

  it "rejects a client that traverses a handle" $
    withClient traverseClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "No instance for"
      clientOutput outcome `shouldContain` "Traversable Prepared"

  it "accepts and runs a client that prepares, reads, and forwards without NFData" $
    withPackageClient packages "Main.hs" supportedClient $ \compile → do
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
        `shouldBe` [ "read = Reading \"thermometer\" [20,21,22]"
                   , "forwarded = Reading \"thermometer\" [20,21,22]"
                   , "kept = [20,21,22]"
                   , "rejected = sample unavailable"
                   ]

packages ∷ [String]
packages = ["base", "deepseq", "hetoimasia-foundation"]

channelSpec ∷ Spec
channelSpec = describe "Channel endpoint authority across the package boundary" $ do
  it "rejects a client that receives from a send endpoint" $
    withChannelClient receiveFromSenderClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "Couldn't match type"
      clientOutput outcome `shouldContain` "Sender"
      clientOutput outcome `shouldContain` "Receiver"

  it "rejects a client that closes from a send endpoint" $
    withChannelClient closeFromSenderClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "Couldn't match type"
      clientOutput outcome `shouldContain` "Sender"
      clientOutput outcome `shouldContain` "ChannelControl"

  it "rejects a client that closes from a receive endpoint" $
    withChannelClient closeFromReceiverClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "Couldn't match type"
      clientOutput outcome `shouldContain` "Receiver"
      clientOutput outcome `shouldContain` "ChannelControl"

  it "rejects a client that constructs an endpoint from its internals" $
    withChannelClient endpointConstructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export any children"
      clientOutput outcome `shouldContain` "Sender"

  it "rejects a client that replaces an endpoint with record update" $
    withChannelClient endpointUpdateClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "Not in scope: record field"
      clientOutput outcome `shouldContain` "channelSender"

  it "accepts and runs a client using every send, receive, control, and statistics operation" $
    withPackageClient channelPackages "Main.hs" supportedChannelClient $ \compile → do
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
        `shouldBe` [ "sends = Accepted Admitted Full"
                   , "received first"
                   , "delivered second"
                   , "empty"
                   , "reopened = Accepted"
                   , "after close = Closed"
                   , "received third"
                   , "ended Drained"
                   , "statistics = 2 0 2 3 3 0"
                   , "discarded = 1"
                   , "after abort = AdmissionClosed"
                   , "terminated Aborted"
                   , "statistics = 1 0 1 1 0 1"
                   , "rejected = CapacityNotPositive 0"
                   , "rejected = CapacityAboveMaximum " <> show (toInteger (maxBound ∷ Int) + 1)
                   ]

channelPackages ∷ [String]
channelPackages = ["base", "deepseq", "stm", "hetoimasia-foundation"]

withChannelClient ∷ String → ((Mode → IO Client) → IO ()) → IO ()
withChannelClient = withPackageClient channelPackages "Client.hs"

-- | Receiving through a send endpoint.
receiveFromSenderClient ∷ String
receiveFromSenderClient =
  unlines
    [ "module Client (taken) where"
    , ""
    , "import Control.Concurrent.STM (STM)"
    , "import Hetoimasia.Foundation.Messaging.Channel (Receipt, Sender, receive)"
    , ""
    , "taken ∷ Sender Int → STM (Receipt Int)"
    , "taken = receive"
    ]

-- | Closing through a send endpoint.
closeFromSenderClient ∷ String
closeFromSenderClient =
  unlines
    [ "module Client (closed) where"
    , ""
    , "import Control.Concurrent.STM (STM)"
    , "import Hetoimasia.Foundation.Messaging.Channel (Sender, closeChannel)"
    , ""
    , "closed ∷ Sender Int → STM ()"
    , "closed = closeChannel"
    ]

-- | Closing through a receive endpoint.
closeFromReceiverClient ∷ String
closeFromReceiverClient =
  unlines
    [ "module Client (closed) where"
    , ""
    , "import Control.Concurrent.STM (STM)"
    , "import Hetoimasia.Foundation.Messaging.Channel (Receiver, closeChannel)"
    , ""
    , "closed ∷ Receiver Int → STM ()"
    , "closed = closeChannel"
    ]

-- | Building a send endpoint by naming its constructor.
endpointConstructorClient ∷ String
endpointConstructorClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Foundation.Messaging.Channel (ChannelControl, Sender (Sender))"
    , ""
    , "forged ∷ ChannelControl Int → Sender Int"
    , "forged = Sender"
    ]

-- | Replacing the send endpoint an owner-control endpoint hands out, through
-- record-update syntax. The reader is imported by name, so the rejection means
-- it is not a field rather than that it was never imported.
endpointUpdateClient ∷ String
endpointUpdateClient =
  unlines
    [ "module Client (rewired) where"
    , ""
    , "import Hetoimasia.Foundation.Messaging.Channel (ChannelControl, Sender, channelSender)"
    , ""
    , "rewired ∷ ChannelControl Int → Sender Int → ChannelControl Int"
    , "rewired control replacement = control { channelSender = replacement }"
    ]

-- | A client using every supported channel operation.
supportedChannelClient ∷ String
supportedChannelClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import Control.Concurrent.STM (atomically)"
    , "import Control.Exception (try)"
    , "import Hetoimasia.Foundation.Messaging.Channel"
    , "import Hetoimasia.Foundation.Messaging.Payload (prepare, preparedValue)"
    , ""
    , "receipt ∷ Receipt String → String"
    , "receipt (Received payload) = \"received \" <> preparedValue payload"
    , "receipt Empty = \"empty\""
    , "receipt (Terminated termination) = \"terminated \" <> show termination"
    , ""
    , "delivery ∷ Delivery String → String"
    , "delivery (Delivered payload) = \"delivered \" <> preparedValue payload"
    , "delivery (Ended termination) = \"ended \" <> show termination"
    , ""
    , "statistics ∷ ChannelControl String → IO String"
    , "statistics control = do"
    , "  s ← atomically (channelStatistics control)"
    , "  pure $ unwords"
    , "    [ \"statistics =\""
    , "    , show (statisticsCapacity s), show (statisticsDepth s), show (statisticsHighWater s)"
    , "    , show (statisticsAccepted s), show (statisticsDequeued s), show (statisticsDiscarded s)"
    , "    ]"
    , ""
    , "rejected ∷ Integer → IO ()"
    , "rejected capacity = do"
    , "  outcome ← try (newChannel capacity ∷ IO (ChannelControl String))"
    , "  case outcome of"
    , "    Left failure → putStrLn (\"rejected = \" <> show (failure ∷ ChannelCapacityRejected))"
    , "    Right _ → putStrLn \"rejected = nothing\""
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  control ← newChannel 2"
    , "  let sender = channelSender control"
    , "      receiver = channelReceiver control"
    , "  first ← prepare \"first\""
    , "  second ← prepare \"second\""
    , "  third ← prepare \"third\""
    , "  sent ← atomically (send sender first)"
    , "  waited ← atomically (awaitSend sender second)"
    , "  full ← atomically (send sender third)"
    , "  putStrLn (unwords [\"sends =\", show sent, show waited, show full])"
    , "  atomically (receive receiver) >>= putStrLn . receipt"
    , "  atomically (awaitReceive receiver) >>= putStrLn . delivery"
    , "  atomically (receive receiver) >>= putStrLn . receipt"
    , "  atomically (send sender third) >>= putStrLn . (\"reopened = \" <>) . show"
    , "  atomically (closeChannel control)"
    , "  atomically (send sender first) >>= putStrLn . (\"after close = \" <>) . show"
    , "  atomically (receive receiver) >>= putStrLn . receipt"
    , "  atomically (awaitReceive receiver) >>= putStrLn . delivery"
    , "  statistics control >>= putStrLn"
    , "  other ← newChannel 1"
    , "  _ ← atomically (send (channelSender other) first)"
    , "  atomically (abortChannel other) >>= putStrLn . (\"discarded = \" <>) . show"
    , "  atomically (awaitSend (channelSender other) second) >>= putStrLn . (\"after abort = \" <>) . show"
    , "  atomically (receive (channelReceiver other)) >>= putStrLn . receipt"
    , "  statistics other >>= putStrLn"
    , "  rejected 0"
    , "  rejected (maximumCapacity + 1)"
    ]

withClient ∷ String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withPackageClient packages "Client.hs"

-- | Building a handle of the client's own by naming the constructor.
constructorClient ∷ String
constructorClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Foundation.Messaging.Payload (Prepared (Prepared))"
    , ""
    , "forged ∷ Int → Prepared Int"
    , "forged = Prepared"
    ]

-- | Replacing a prepared payload through record-update syntax, which needs only
-- the reader in scope. The reader is imported by name, so the rejection means
-- it is not a field rather than that it was never imported.
recordUpdateClient ∷ String
recordUpdateClient =
  unlines
    [ "module Client (replaced) where"
    , ""
    , "import Hetoimasia.Foundation.Messaging.Payload (Prepared, preparedValue)"
    , ""
    , "replaced ∷ Prepared Int → Int → Prepared Int"
    , "replaced handle replacement = handle { preparedValue = replacement }"
    ]

-- | Wrapping a value that was never prepared with 'Data.Coerce.coerce'.
wrapCoerceClient ∷ String
wrapCoerceClient =
  unlines
    [ "module Client (wrapped) where"
    , ""
    , "import Data.Coerce (coerce)"
    , "import Hetoimasia.Foundation.Messaging.Payload (Prepared)"
    , ""
    , "wrapped ∷ Int → Prepared Int"
    , "wrapped = coerce"
    ]

-- | Re-typing a handle between two client newtypes over the same
-- representation. With a representational role this would compile without the
-- constructor in scope, so it is the client that exercises the role itself.
retypeCoerceClient ∷ String
retypeCoerceClient =
  unlines
    [ "module Client (feet, relabelled) where"
    , ""
    , "import Data.Coerce (coerce)"
    , "import Hetoimasia.Foundation.Messaging.Payload (Prepared)"
    , ""
    , "newtype Metres = Metres Double"
    , "newtype Feet = Feet Double"
    , ""
    , "feet ∷ Metres → Feet"
    , "feet = coerce"
    , ""
    , "relabelled ∷ Prepared Metres → Prepared Feet"
    , "relabelled = coerce"
    ]

-- | The source lines of the control and the rejected coercion in
-- 'retypeCoerceClient'.
controlLine, retypeLine ∷ Int
controlLine = 10
retypeLine = 13

-- | Transforming a prepared payload without preparing the result.
fmapClient ∷ String
fmapClient =
  unlines
    [ "module Client (incremented) where"
    , ""
    , "import Hetoimasia.Foundation.Messaging.Payload (Prepared)"
    , ""
    , "incremented ∷ Prepared Int → Prepared Int"
    , "incremented = fmap (+ 1)"
    ]

-- | Traversing a prepared payload, which would rebuild it effectfully without
-- preparation.
traverseClient ∷ String
traverseClient =
  unlines
    [ "module Client (checked) where"
    , ""
    , "import Hetoimasia.Foundation.Messaging.Payload (Prepared)"
    , ""
    , "checked ∷ Prepared Int → Maybe (Prepared Int)"
    , "checked = traverse Just"
    ]

-- | A client using only what the module offers. The reader and forwarder are
-- polymorphic with no 'NFData' constraint, and the failing preparation shows
-- a nested failure raised by 'prepare' with its own type.
supportedClient ∷ String
supportedClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import Control.DeepSeq (NFData (rnf))"
    , "import Control.Exception (ErrorCall (ErrorCall), throw, try)"
    , "import Hetoimasia.Foundation.Messaging.Payload (Prepared, prepare, preparedValue)"
    , ""
    , "data Reading = Reading !String [Int]"
    , "  deriving (Show)"
    , ""
    , "instance NFData Reading where"
    , "  rnf (Reading label samples) = rnf label `seq` rnf samples"
    , ""
    , "samplesOf ∷ Reading → [Int]"
    , "samplesOf (Reading _ samples) = samples"
    , ""
    , "describePayload ∷ Show a ⇒ Prepared a → String"
    , "describePayload = show . preparedValue"
    , ""
    , "forward ∷ Prepared a → (Prepared a, Prepared a)"
    , "forward handle = (handle, handle)"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  prepared ← prepare (Reading \"thermometer\" [20, 21, 22])"
    , "  putStrLn (\"read = \" <> describePayload prepared)"
    , "  let (kept, sent) = forward prepared"
    , "  putStrLn (\"forwarded = \" <> describePayload sent)"
    , "  putStrLn (\"kept = \" <> show (samplesOf (preparedValue kept)))"
    , "  failed ← try (prepare (Reading \"broken\" [1, throw (ErrorCall \"sample unavailable\")]))"
    , "  case failed of"
    , "    Left (ErrorCall message) → putStrLn (\"rejected = \" <> message)"
    , "    Right _ → putStrLn \"rejected = nothing\""
    ]
