-- | The public boundary of the inventory: a client sees the limits, the scan,
-- the questions and the verified read, and nothing that would let it build an
-- inventory, a digest or a checked limit around the checks that guard them, or
-- reach a native component, a handle or the private library.
--
-- Each example compiles a separate single-module client against the package's
-- main library alone, as "Test.Content.Opacity" does; the accepted client is
-- compiled, linked and run against a tree this example builds, so it is also
-- the evidence that the interface is usable without a private import.
module Test.Content.Inventory.Boundary (spec) where

import qualified Data.ByteString.Char8 as BC
import System.Directory (createDirectory)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.Process (proc, readCreateProcessWithExitCode)
import Test.Content.Support (withTree, writeBytes)
import Test.Hspec
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withStorePackageClient)

spec ∷ Spec
spec = describe "Inventory package boundary" $ do
  it "rejects a client that forges an inventory around the scan" $
    withClient "Client.hs" inventoryConstructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      clientOutput outcome `shouldContain` "Inventory"

  it "rejects a client that forges a digest" $
    withClient "Client.hs" digestConstructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      clientOutput outcome `shouldContain` "Sha256"

  it "rejects a client that builds checked limits around the check" $
    withClient "Client.hs" limitsConstructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      clientOutput outcome `shouldContain` "InventoryLimits"

  it "rejects a client that reads an inventory's mapping or files directly" $
    withClient "Client.hs" fieldClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-61689"
      clientOutput outcome `shouldContain` "invMapping"

  it "rejects a client that reaches the scan or the read through the private library" $
    withClient "Client.hs" privateClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess → expectationFailure ("the client compiled, so the private library is reachable:\n" <> clientOutput outcome)
      clientOutput outcome `shouldContain` "hidden package"
      clientOutput outcome `shouldContain` "hetoimasia-content-0.1.0.0:internal"

  it "accepts and runs a client that scans, asks, and reads verified bytes through the public interface alone" $
    withTree $ \tree →
      withClient "Main.hs" scopedClient $ \compile → do
        outcome ← compile Link
        case clientStatus outcome of
          ExitSuccess → pure ()
          status →
            expectationFailure
              ("the supported client must compile, but the compiler exited with " <> show status <> ":\n" <> clientOutput outcome)
        createDirectory (tree </> "root")
        writeBytes (tree </> "root" </> "data.txt") (BC.pack "abc")
        (status, out, err) ← readCreateProcessWithExitCode (proc (clientDirectory outcome </> "client") [tree </> "root"]) ""
        (status, out, err)
          `shouldBe` ( ExitSuccess
                     , unlines
                         [ "entries 2"
                         , "present 3"
                         , "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
                         , "abc"
                         , "read not found"
                         ]
                     , ""
                     )

withClient ∷ String → String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withStorePackageClient ["base", "bytestring", "hetoimasia-content-0.1.0.0-inplace"]

inventoryConstructorClient ∷ String
inventoryConstructorClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Content.Inventory (Inventory (Inventory))"
    , ""
    , "forged ∷ Maybe Inventory"
    , "forged = Nothing"
    ]

digestConstructorClient ∷ String
digestConstructorClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Data.ByteString (ByteString)"
    , "import Hetoimasia.Content.Inventory (Sha256 (Sha256))"
    , ""
    , "forged ∷ ByteString → Sha256"
    , "forged = Sha256"
    ]

limitsConstructorClient ∷ String
limitsConstructorClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Content.Inventory (InventoryLimits (InventoryLimits))"
    , ""
    , "forged ∷ Maybe InventoryLimits"
    , "forged = Nothing"
    ]

fieldClient ∷ String
fieldClient =
  unlines
    [ "module Client (peek) where"
    , ""
    , "import Hetoimasia.Content.Inventory (Inventory, invMapping)"
    , ""
    , "peek ∷ Inventory → ()"
    , "peek inventory = invMapping inventory `seq` ()"
    ]

privateClient ∷ String
privateClient =
  unlines
    [ "module Client (scan) where"
    , ""
    , "import Hetoimasia.Content.Internal.Inventory.Scan (scanInventory)"
    , ""
    , "scan ∷ ()"
    , "scan = scanInventory `seq` ()"
    ]

scopedClient ∷ String
scopedClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import qualified Data.ByteString.Char8 as BC"
    , "import Hetoimasia.Content"
    , "import Hetoimasia.Content.Identity"
    , "import Hetoimasia.Content.Inventory"
    , "import System.Environment (getArgs)"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  [directory] ← getArgs"
    , "  key ← either (fail . show) pure (rootKey (BC.pack \"client-root\"))"
    , "  limits ←"
    , "    either (fail . show) pure . inventoryLimits $"
    , "      InventorySpec {specEntries = 16, specSegments = 4, specPathBytes = 64, specSegmentBytes = 16, specFileBytes = 1024, specRootBytes = 4096, specBufferBytes = 8}"
    , "  withContentRoot defaultContentLimits directory $ \\root → do"
    , "    inventory ← scanInventory limits key root >>= either (fail . show) pure"
    , "    reference ← either (fail . show) pure (parseReference (inventoryIdentityLimits limits) key (BC.pack \"data.txt\"))"
    , "    putStrLn (\"entries \" <> show (inventoryEntryCount inventory))"
    , "    case inspectEntry inventory reference of"
    , "      PresentFile size → putStrLn (\"present \" <> show size)"
    , "      other → putStrLn (\"unexpected \" <> show other)"
    , "    mapM_ (\\entry → mapM_ (putStrLn . sha256Hex . factDigest) (entryFact entry)) (listInventory inventory)"
    , "    readVerified inventory root reference 1024 >>= either (fail . show) BC.putStrLn"
    , "    absent ← either (fail . show) pure (parseReference (inventoryIdentityLimits limits) key (BC.pack \"absent.txt\"))"
    , "    readVerified inventory root absent 1024 >>= \\case"
    , "      Left failure | readFailureOutcome failure == ReadNotFound → putStrLn \"read not found\""
    , "      other → putStrLn (\"unexpected read \" <> either show (const \"bytes\") other)"
    ]
