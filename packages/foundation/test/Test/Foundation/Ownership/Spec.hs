-- | Ownership transactions ("Hetoimasia.Foundation.OwnerTx") and the exit classification
-- ("Hetoimasia.Foundation.Exit").
--
-- The transaction examples show a commit's reads and writes, a publication's revision, and a waiting reader outside
-- every commit. The boundary examples compile separate single-module clients against @base@, @stm@ and
-- @hetoimasia-foundation@ alone: a client composing cells and publications compiles; one that names the
-- transaction's constructor, coerces an 'STM' action into one, retries inside one, lifts 'IO' into one or publishes
-- from one is refused for the diagnostic naming its cause.
module Test.Foundation.Ownership.Spec (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM (atomically, check)
import Control.Exception (AsyncException (ThreadKilled), ErrorCall (ErrorCall), ExceptionWithContext (ExceptionWithContext), throwIO, toException, try)
import Control.Exception.Context (emptyExceptionContext)
import Hetoimasia.Foundation.Exit
import Hetoimasia.Foundation.OwnerTx
import System.Exit (ExitCode (ExitSuccess))
import Test.Hspec
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withPackageClient)

spec ∷ Spec
spec = describe "Ownership" $ do
  describe "transactions" $ do
    it "reads and replaces owner cells in one commit, and answers what the transition decided" $ do
      cell ← newCellIO (3 ∷ Int)
      answer ← commit (stateCell cell (\n → (n * 2, n + 1)))
      answer `shouldBe` 6
      commit (readCell cell) `shouldReturn` 4
      commit (modifyCell cell (* 10) >> readTx (readOnly cell)) `shouldReturn` 40

    it "lets a reader wait on a read-only capability outside every commit" $ do
      cell ← newCellIO False
      done ← newCellIO False
      _ ← forkIO $ do
        atomically (watch (readOnly cell) >>= check)
        commit (writeCell done True)
      commit (writeCell cell True)
      atomically (watch (readOnly done) >>= check)
      commit (readCell done) `shouldReturn` True

    it "keeps a publication's value and revision with its source, and lets a commit only read them" $ do
      source ← newPublisherIO ("open" ∷ String)
      let reading = publication source
      commit ((,) <$> publicationRevision reading <*> readPublication reading) `shouldReturn` (0, "open")
      atomically (publish source "ended")
      commit ((,) <$> publicationRevision reading <*> readPublication reading) `shouldReturn` (1, "ended")
      atomically (watchPublication reading) `shouldReturn` (1, "ended")

    it "refuses, in the source's own transaction, a published value whose evaluation raises, and keeps the prior one" $ do
      source ← newPublisherIO [1 ∷ Int]
      outcome ← try (atomically (publish source [2, error "unspeakable"]))
      case outcome of
        Left (ErrorCall _) → pure ()
        Right () → expectationFailure "the publication accepted a value that raises"
      commit ((,) <$> publicationRevision (publication source) <*> readPublication (publication source)) `shouldReturn` (0, [1])

  describe "exits" $ do
    let raised = ExceptionWithContext emptyExceptionContext (toException (ErrorCall "recoverable"))
        cancelled = ExceptionWithContext emptyExceptionContext (toException ThreadKilled)
        kind ∷ Exit Int () → String
        kind = \case
          Completed () → "completed"
          Refused _ → "refused"
          Raised _ → "raised"
          Cancelled _ → "cancelled"
          Terminal (Left _) → "terminal refusal"
          Terminal (Right _) → "terminal exception"
    it "classifies a value, a refusal and a synchronous exception while the issuer lives" $ do
      kind (classifyExit IssuerLive (Right (Right ()))) `shouldBe` "completed"
      kind (classifyExit IssuerLive (Right (Left 1))) `shouldBe` "refused"
      kind (classifyExit IssuerLive (Left raised)) `shouldBe` "raised"

    it "classifies a refusal or a synchronous exception after the issuer ended as terminal" $ do
      kind (classifyExit IssuerEnded (Right (Left 1))) `shouldBe` "terminal refusal"
      kind (classifyExit IssuerEnded (Left raised)) `shouldBe` "terminal exception"
      kind (classifyExit IssuerEnded (Right (Right ()))) `shouldBe` "completed"

    it "classifies an asynchronous exception as a cancellation whatever the issuer's standing" $ do
      kind (classifyExit IssuerLive (Left cancelled)) `shouldBe` "cancelled"
      kind (classifyExit IssuerEnded (Left cancelled)) `shouldBe` "cancelled"

    it "delivers a recoverable exception as the original exception" $ do
      outcome ← tryExit (throwIO (ErrorCall "original") ∷ IO (Either Int ()))
      delivered ← try (deliverExit (classifyExit IssuerLive outcome))
      case delivered of
        Left (ErrorCall message) → message `shouldBe` "original"
        Right _ → expectationFailure "the exception was not delivered"

  describe "the transaction boundary" $ do
    it "accepts a client composing cells, read-only capabilities and publications" $
      withClient composing $ \compile → do
        outcome ← compile Typecheck
        case clientStatus outcome of
          ExitSuccess → pure ()
          status → expectationFailure ("the supported client must compile, but the compiler exited with " <> show status <> ":\n" <> clientOutput outcome)

    it "rejects a client that names the transaction's constructor" $
      withClient (client ["import Hetoimasia.Foundation.OwnerTx (OwnerTx (OwnerTx))"] ["x = ()"]) $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "GHC-10237"
        clientOutput outcome `shouldContain` "OwnerTx"

    it "rejects a client that coerces an STM action into a transaction" $
      withClient
        (client ["import Control.Concurrent.STM (STM)", "import Data.Coerce (coerce)", "import Hetoimasia.Foundation.OwnerTx"] ["lifted ∷ STM () → OwnerTx ()", "lifted = coerce"])
        $ \compile → do
          outcome ← compile Typecheck
          rejectedBecause outcome "GHC-18872"
          clientOutput outcome `shouldContain` "OwnerTx"

    it "rejects a client that retries inside a transaction" $
      withClient
        (client ["import Control.Concurrent.STM (retry)", "import Hetoimasia.Foundation.OwnerTx"] ["waiting ∷ OwnerCell Bool → OwnerTx ()", "waiting cell = readCell cell >>= \\open → if open then pure () else retry"])
        $ \compile → do
          outcome ← compile Typecheck
          rejectedBecause outcome "GHC-83865"
          clientOutput outcome `shouldContain` "STM"

    it "rejects a client that lifts IO into a transaction" $
      withClient
        (client ["import Control.Monad.IO.Class (liftIO)", "import Hetoimasia.Foundation.OwnerTx"] ["effect ∷ OwnerTx ()", "effect = liftIO (putStrLn \"inside\")"])
        $ \compile → do
          outcome ← compile Typecheck
          rejectedBecause outcome "GHC-39999"
          clientOutput outcome `shouldContain` "MonadIO"
          clientOutput outcome `shouldContain` "OwnerTx"

    it "rejects a client that publishes from inside a transaction" $
      withClient
        (client ["import Hetoimasia.Foundation.OwnerTx"] ["writing ∷ Publisher Int → OwnerTx ()", "writing source = publish source 1"])
        $ \compile → do
          outcome ← compile Typecheck
          rejectedBecause outcome "GHC-83865"
          clientOutput outcome `shouldContain` "STM"

withClient ∷ String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withPackageClient ["base", "stm", "hetoimasia-foundation"] "Client.hs"

client ∷ [String] → [String] → String
client imports body = unlines (["module Client where"] <> imports <> body)

composing ∷ String
composing =
  client
    ["import Control.Concurrent.STM (STM, check)", "import Hetoimasia.Foundation.OwnerTx"]
    [ "transition ∷ OwnerCell Int → Publication Bool → OwnerTx (Either String Int)"
    , "transition cell open = do"
    , "  live ← readPublication open"
    , "  current ← readCell cell"
    , "  if live then Right current <$ writeCell cell (current + 1) else pure (Left \"ended\")"
    , "waitOpen ∷ Publication Bool → STM ()"
    , "waitOpen open = watchPublication open >>= check . snd"
    , "run ∷ OwnerCell Int → Publication Bool → IO (Either String Int)"
    , "run cell open = commit (transition cell open)"
    ]
