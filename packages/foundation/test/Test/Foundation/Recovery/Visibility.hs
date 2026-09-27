-- | Examples proving that recovery's types module stays inside the foundation
-- package while its public module keeps every name it exports and its history
-- annotation stays private.
--
-- "Hetoimasia.Foundation.Recovery" re-exports its policy, outcome and history
-- types from "Hetoimasia.Foundation.Recovery.Types", a hidden module of the
-- foundation's main library. An example in this suite cannot observe that
-- boundary, so these examples compile separate single-module clients with the
-- harness from "Test.Support.ExternalClient", exposing @base@ and
-- @hetoimasia-foundation@ and hiding everything else, as the logging and
-- failure opacity examples do.
--
-- One client must be accepted: it imports, by name, every name the public
-- module exports, with every constructor and field it exports, so a removed
-- constructor or field fails it. Every other client is compiled on its own and
-- must be rejected for the diagnostic naming its cause. A client importing the
-- hidden module is refused with @GHC-87110@ against the main library's own
-- unit; a client asking the public module for the history annotation is
-- refused because the module does not export it.
module Test.Foundation.Recovery.Visibility (spec) where

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
spec = describe "Recovery module visibility across the package boundary" $ do
  it "accepts a client that imports every public recovery name" $
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

  it ("rejects a client that imports the hidden module " <> hidden) $
    withClient importClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess →
          expectationFailure ("the client compiled, so " <> hidden <> " is reachable:\n" <> clientOutput outcome)
      -- Found in the main library and refused as hidden; naming that unit
      -- tells this apart from a missing module or an unresolvable package.
      clientOutput outcome `shouldContain` "GHC-87110"
      clientOutput outcome `shouldContain` "hetoimasia-foundation-0.1.0.0"
      clientOutput outcome `shouldNotContain` "cannot satisfy"
      clientOutput outcome `shouldNotContain` "Could not find module"

  it ("rejects a client that asks " <> public <> " for the HistoryEntry annotation") $
    withClient historyEntryClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "does not export"
      clientOutput outcome `shouldContain` "HistoryEntry"

withClient ∷ String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withPackageClient ["base", "hetoimasia-foundation"] "Client.hs"

-- | The public module the clients below import from.
public ∷ String
public = "Hetoimasia.Foundation.Recovery"

-- | The types module hidden inside the main library.
hidden ∷ String
hidden = "Hetoimasia.Foundation.Recovery.Types"

importClient ∷ String
importClient = unlines ["module Client () where", "", "import " <> hidden]

historyEntryClient ∷ String
historyEntryClient =
  unlines ["module Client () where", "", "import " <> public <> " (HistoryEntry)"]

supportedClient ∷ String
supportedClient =
  unlines
    [ "module Client () where"
    , ""
    , "import Hetoimasia.Foundation.Recovery"
    , "  ( recover"
    , "  , allocComponent"
    , "  , RecoveryPolicy (RecoveryPolicy, policyDisposition, policyBudget, policyClassifier, policyWait)"
    , "  , Disposition (Required, Optional)"
    , "  , Strategy (Retry, Fallback)"
    , "  , InvalidRecoveryPolicy (NonPositiveBudget)"
    , "  , Outcome (Available, Unavailable)"
    , "  , Recovered (Recovered, recoveredValue, recoveredBy, recoveredFailures)"
    , "  , Unavailability (Unavailability, unavailableOperation, unavailableReason, unavailableEarlier)"
    , "  , AttemptFailure (AttemptFailure, attemptNumber, attemptKind, attemptException)"
    , "  , AttemptKind (InitialAttempt, RetryAttempt, FallbackAttempt)"
    , "  , RecoveryHistory (RecoveryHistory, historyOperation, historyAttempts)"
    , "  , recoveryHistory"
    , "  , recoveryHistoryInContext"
    , "  )"
    ]
