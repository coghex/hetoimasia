-- | The ownership transaction's public boundary, from outside the package.
--
-- Each example compiles a separate single-module client against @base@, @stm@ and the exact unit of Foundation's main
-- library (its in-place unit id, so neither the issuer sublibrary nor the private one is in scope), through
-- "Test.Support.ExternalClient". A client that composes cells, read-only capabilities and publications compiles. One
-- that names the transaction's constructor, coerces caller 'STM' into a transaction, retries inside one, lifts 'IO'
-- into one, publishes from inside one, mutates a cell through its read-only capability, or names a function-taking
-- mutation helper is refused, each for the diagnostic naming its cause.
module Test.Foundation.Ownership.Opacity (spec) where

import Control.Monad (forM_)
import System.Exit (ExitCode (ExitSuccess))
import Test.Hspec
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withStorePackageClient)

-- The main library's unit alone.
withClient ∷ String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withStorePackageClient ["base", "stm", "hetoimasia-foundation-0.1.0.0-inplace"] "Client.hs"

client ∷ [String] → [String] → String
client imports body = unlines (["module Client where"] <> imports <> body)

spec ∷ Spec
spec = describe "the public boundary" $ do
  it "accepts a client composing cells, read-only capabilities and publications through the public module alone" $
    withClient composing $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitSuccess → pure ()
        status → expectationFailure ("the supported client must compile, but the compiler exited with " <> show status <> ":\n" <> clientOutput outcome)

  it "rejects a client that names the transaction's constructor" $
    withClient (client ["import Hetoimasia.Foundation.OwnerTx (OwnerTx (OwnerTx))"] ["x ∷ ()", "x = ()"]) $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      clientOutput outcome `shouldContain` "OwnerTx"

  it "rejects a client that coerces its own STM into a transaction" $
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

  it "rejects a client that publishes from inside a transaction" $
    withClient
      (client ["import Hetoimasia.Foundation.Messaging.Payload (Prepared)", "import Hetoimasia.Foundation.OwnerTx"] ["writing ∷ Publisher Int → Prepared Int → OwnerTx ()", "writing source value = publish source value"])
      $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "GHC-83865"
        clientOutput outcome `shouldContain` "STM"

  it "rejects a client that mutates a cell through its read-only capability" $
    withClient
      (client ["import Hetoimasia.Foundation.OwnerTx"] ["mutating ∷ ReadOnly Int → OwnerTx ()", "mutating capability = writeCell capability 1"])
      $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "GHC-83865"
        clientOutput outcome `shouldContain` "ReadOnly"

  forM_ ["Publisher", "Publication"] $ \endpoint →
    it ("rejects a client that coerces a " <> endpoint <> " of one payload to a newtype of it") $
      withClient
        ( client
            ["import Data.Coerce (coerce)", "import Hetoimasia.Foundation.OwnerTx"]
            [ "newtype Shallow = Shallow [Int]"
            , "recast ∷ " <> endpoint <> " [Int] → " <> endpoint <> " Shallow"
            , "recast = coerce"
            ]
        )
        $ \compile → do
          outcome ← compile Typecheck
          -- the payload's role is nominal: no coercion lifts through it
          rejectedBecause outcome "GHC-18872"
          clientOutput outcome `shouldContain` "Couldn't match type ‘[Int]’ with ‘Shallow’"

  forM_ ["modifyCell", "stateCell", "fromIssuerSTM"] $ \helper →
    it ("rejects a client that asks the public module for " <> helper) $
      withClient (client ["import Hetoimasia.Foundation.OwnerTx (" <> helper <> ")"] ["x ∷ ()", "x = ()"]) $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "GHC-61689"
        clientOutput outcome `shouldContain` helper

composing ∷ String
composing =
  client
    ["import Control.Concurrent.STM (STM, check)", "import Hetoimasia.Foundation.Messaging.Payload (prepare)", "import Hetoimasia.Foundation.OwnerTx"]
    [ "transition ∷ OwnerCell Int → ReadOnly Bool → Publication Bool → OwnerTx (Either String Int)"
    , "transition cell gate open = do"
    , "  (_, live) ← readPublication open"
    , "  allowed ← readTx gate"
    , "  current ← readCell cell"
    , "  if live && allowed then Right current <$ writeCell cell (current + 1) else pure (Left \"ended\")"
    , "waitOpen ∷ Publication Bool → STM ()"
    , "waitOpen open = watchPublication open >>= check . snd"
    , "run ∷ OwnerCell Int → ReadOnly Bool → IO (Either String Int)"
    , "run cell gate = do"
    , "  source ← prepare True >>= newPublisherIO"
    , "  commit (transition cell gate (publication source))"
    ]
