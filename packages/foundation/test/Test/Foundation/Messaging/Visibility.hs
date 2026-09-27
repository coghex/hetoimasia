-- | Examples proving that messaging's component and types modules stay inside
-- the foundation package, that its public modules keep every name they export,
-- and that every endpoint, cursor, and observation keeps its nominal role.
--
-- "Hetoimasia.Foundation.Messaging.Channel" re-exports its types from
-- "Hetoimasia.Foundation.Messaging.Channel.Types",
-- "Hetoimasia.Foundation.Messaging.Snapshot" re-exports its types from
-- "Hetoimasia.Foundation.Messaging.Snapshot.Types", and both re-export the one
-- component from "Hetoimasia.Foundation.Messaging.Component"; all three are
-- hidden modules of the foundation's main library. An example in this suite
-- cannot observe that boundary, so these examples compile separate
-- single-module clients with the harness from "Test.Support.ExternalClient",
-- exposing @base@ and @hetoimasia-foundation@ and hiding everything else, as
-- the examples in "Test.Foundation.Messaging.Opacity" do.
--
-- One client must be accepted: it imports, by name, every name the public
-- channel, snapshot, and payload modules export, with every constructor and
-- record selector they export and the abstract types without theirs, so a
-- removed name fails it. It imports 'messagingComponent' from both channel and
-- snapshot and uses it unqualified, which compiles only while the two are one
-- definition. Each hidden module is imported by a client of its own, so one
-- refusal cannot mask another, and each must be refused with @GHC-87110@ as a
-- hidden module of the main library's own unit.
--
-- Each endpoint, cursor, and observation type is re-typed with
-- 'Data.Coerce.coerce' between two client newtypes over the same
-- representation, by a client of its own. With a representational role that
-- coercion would compile without the constructor in scope, so its refusal is
-- the role itself. Each client carries a control coercion between the two
-- newtypes in the same module, which must not be reported.
module Test.Foundation.Messaging.Visibility (spec) where

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
spec = describe "Messaging module visibility across the package boundary" $ do
  it "accepts a client that imports every public channel, snapshot, and payload name" $
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

  forM_ hidden $ \module' →
    it ("rejects a client that imports the hidden module " <> module') $
      withClient (importClient module') $ \compile → do
        outcome ← compile Typecheck
        case clientStatus outcome of
          ExitFailure _ → pure ()
          ExitSuccess →
            expectationFailure ("the client compiled, so " <> module' <> " is reachable:\n" <> clientOutput outcome)
        -- Found in the main library and refused as hidden; naming that unit
        -- tells this apart from a missing module or an unresolvable package.
        -- These are local assertions because the shared 'rejectedBecause'
        -- treats "Could not load module", part of this very diagnostic, as an
        -- environment failure.
        clientOutput outcome `shouldContain` module'
        clientOutput outcome `shouldContain` "hidden module"
        clientOutput outcome `shouldContain` "GHC-87110"
        clientOutput outcome `shouldContain` "hetoimasia-foundation-0.1.0.0"
        clientOutput outcome `shouldNotContain` "cannot satisfy"
        clientOutput outcome `shouldNotContain` "Could not find module"

  forM_ nominalTypes $ \(module', type') →
    it ("rejects a client that changes the payload type of " <> type' <> " with coerce between equivalent newtypes") $
      withClient (retypeCoerceClient module' type') $ \compile → do
        outcome ← compile Typecheck
        -- The diagnostic names the payload types, not the messaging type; the
        -- line is the one coercion that mentions it.
        rejectedBecause outcome "Couldn't match type"
        clientOutput outcome `shouldContain` "Metres"
        clientOutput outcome `shouldContain` "Feet"
        clientOutput outcome `shouldContain` ("Client.hs:" <> show retypeLine <> ":")
        -- The control coercion between the newtypes themselves is accepted, so
        -- only the role of the messaging type can have caused the rejection.
        clientOutput outcome `shouldNotContain` ("Client.hs:" <> show controlLine <> ":")

withClient ∷ String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withPackageClient ["base", "hetoimasia-foundation"] "Client.hs"

-- | The modules hidden inside the main library.
hidden ∷ [String]
hidden =
  [ "Hetoimasia.Foundation.Messaging.Component"
  , "Hetoimasia.Foundation.Messaging.Channel.Types"
  , "Hetoimasia.Foundation.Messaging.Snapshot.Types"
  ]

importClient ∷ String → String
importClient module' = unlines ["module Client () where", "", "import " <> module']

-- | Every endpoint, cursor, and observation type whose role is nominal, with
-- the public module a client imports it from.
nominalTypes ∷ [(String, String)]
nominalTypes =
  [ (channel, "ChannelControl")
  , (channel, "Sender")
  , (channel, "Receiver")
  , (snapshot, "SnapshotPublisher")
  , (snapshot, "SnapshotReader")
  , (snapshot, "SnapshotCursor")
  , (snapshot, "Observation")
  ]
  where
    channel = "Hetoimasia.Foundation.Messaging.Channel"
    snapshot = "Hetoimasia.Foundation.Messaging.Snapshot"

-- | Re-typing a messaging type between two client newtypes over the same
-- representation, beside the control coercion between the newtypes.
retypeCoerceClient ∷ String → String → String
retypeCoerceClient module' type' =
  unlines
    [ "module Client (feet, relabelled) where"
    , ""
    , "import Data.Coerce (coerce)"
    , "import " <> module' <> " (" <> type' <> ")"
    , ""
    , "newtype Metres = Metres Double"
    , "newtype Feet = Feet Double"
    , ""
    , "feet ∷ Metres → Feet"
    , "feet = coerce"
    , ""
    , "relabelled ∷ " <> type' <> " Metres → " <> type' <> " Feet"
    , "relabelled = coerce"
    ]

-- | The source lines of the control and the rejected coercion in
-- 'retypeCoerceClient'.
controlLine, retypeLine ∷ Int
controlLine = 10
retypeLine = 13

supportedClient ∷ String
supportedClient =
  unlines
    [ "module Client (component) where"
    , ""
    , "import Hetoimasia.Foundation.Messaging.Channel"
    , "  ( ChannelControl"
    , "  , newChannel"
    , "  , maximumCapacity"
    , "  , ChannelCapacityRejected (CapacityNotPositive, CapacityAboveMaximum)"
    , "  , messagingComponent"
    , "  , newChannelOperation"
    , "  , Sender"
    , "  , channelSender"
    , "  , Receiver"
    , "  , channelReceiver"
    , "  , SendResult (Accepted, Full, Closed)"
    , "  , send"
    , "  , Admission (Admitted, AdmissionClosed)"
    , "  , awaitSend"
    , "  , Receipt (Received, Empty, Terminated)"
    , "  , receive"
    , "  , Delivery (Delivered, Ended)"
    , "  , awaitReceive"
    , "  , Termination (Drained, Aborted)"
    , "  , closeChannel"
    , "  , abortChannel"
    , "  , ChannelStatistics"
    , "      ( ChannelStatistics"
    , "      , statisticsCapacity"
    , "      , statisticsDepth"
    , "      , statisticsHighWater"
    , "      , statisticsAccepted"
    , "      , statisticsDequeued"
    , "      , statisticsDiscarded"
    , "      )"
    , "  , channelStatistics"
    , "  )"
    , "import Hetoimasia.Foundation.Messaging.Payload (Prepared, prepare, preparedValue)"
    , "import Hetoimasia.Foundation.Messaging.Snapshot"
    , "  ( SnapshotPublisher"
    , "  , newSnapshot"
    , "  , SnapshotReader"
    , "  , snapshotReader"
    , "  , Publication (Published, PublicationClosed)"
    , "  , publish"
    , "  , closeSnapshot"
    , "  , Observation"
    , "  , observedValue"
    , "  , observedCursor"
    , "  , SnapshotCursor"
    , "  , cursorRevision"
    , "  , readSnapshot"
    , "  , Update (Updated, EndOfStream)"
    , "  , awaitSnapshot"
    , "  , ForeignSnapshotCursor (ForeignSnapshotCursor)"
    , "  , messagingComponent"
    , "  , awaitSnapshotOperation"
    , "  )"
    , ""
    , "-- Imported from both modules and named unqualified: two definitions would"
    , "-- make this occurrence ambiguous."
    , "component = messagingComponent"
    ]
