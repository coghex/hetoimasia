-- | The read pool's public boundary: a client sees the scoped pool, the slot reservation, the job
-- and its ticket, and nothing that would build a pool around its checks, reach its hooks or its
-- state, or substitute the reader through the private library.
--
-- Each compiles a separate single-module client with the shared harness, exposing @base@,
-- @bytestring@, @stm@ and the package's main library only. The accepted client is compiled, linked
-- and run against a tree this example builds: a real root, scan and pool composed from public
-- modules alone.
module Test.Content.ReadPool.Boundary (spec) where

import qualified Data.ByteString.Char8 as BC
import System.Directory (createDirectory)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.Process (proc, readCreateProcessWithExitCode)
import Test.Content.Support (withTree, writeBytes)
import Test.Hspec
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withStorePackageClient)

spec ∷ Spec
spec = do
  it "rejects a client that builds a pool specification around its checks" $
    withClient "Client.hs" specClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      clientOutput outcome `shouldContain` "PoolSpec"

  it "rejects a client that reaches the pool's coordination hooks" $
    withClient "Client.hs" hooksClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-61689"
      clientOutput outcome `shouldContain` "PoolHooks"

  it "rejects a client that reaches the pool through the private library" $
    withClient "Client.hs" privateClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess → expectationFailure ("the client compiled, so the private pool is reachable:\n" <> clientOutput outcome)
      clientOutput outcome `shouldContain` "GHC-87110"
      clientOutput outcome `shouldContain` "hetoimasia-content-0.1.0.0:internal"

  it "accepts and runs a client composing a root, a scan and a pool from public modules alone" $
    withTree $ \tree →
      withClient "Main.hs" composedClient $ \compile → do
        outcome ← compile Link
        case clientStatus outcome of
          ExitSuccess → pure ()
          status →
            expectationFailure
              ("the supported client must compile, but the compiler exited with " <> show status <> ":\n" <> clientOutput outcome)
        createDirectory (tree </> "root")
        writeBytes (tree </> "root" </> "data.txt") (BC.pack "read by a pooled worker")
        (status, out, err) ← readCreateProcessWithExitCode (proc (clientDirectory outcome </> "client") [tree </> "root"]) ""
        (status, out, err) `shouldBe` (ExitSuccess, "read by a pooled worker", "")

withClient ∷ String → String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withStorePackageClient ["base", "bytestring", "stm", "hetoimasia-content-0.1.0.0-inplace"]

specClient ∷ String
specClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Content.ReadPool (PoolSpec (PoolSpec))"
    , ""
    , "forged ∷ Int → Int → PoolSpec"
    , "forged = PoolSpec"
    ]

hooksClient ∷ String
hooksClient =
  unlines
    [ "module Client (hooks) where"
    , ""
    , "import Hetoimasia.Content.ReadPool (PoolHooks)"
    , ""
    , "hooks ∷ Maybe PoolHooks"
    , "hooks = Nothing"
    ]

privateClient ∷ String
privateClient =
  unlines
    [ "module Client (hooks) where"
    , ""
    , "import Hetoimasia.Content.Internal.Pool (PoolHooks, noHooks)"
    , ""
    , "hooks ∷ PoolHooks"
    , "hooks = noHooks"
    ]

composedClient ∷ String
composedClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)"
    , "import Control.Concurrent.STM (atomically)"
    , "import qualified Data.ByteString.Char8 as BC"
    , "import Hetoimasia.Content"
    , "import Hetoimasia.Content.Identity (parseReference, rootKey)"
    , "import Hetoimasia.Content.Inventory"
    , "import Hetoimasia.Content.ReadPool"
    , "import System.Environment (getArgs)"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  [directory] ← getArgs"
    , "  Right limits ← pure (inventoryLimits (InventorySpec 10 4 64 32 1024 4096 64))"
    , "  Right root' ← pure (rootKey (BC.pack \"client\"))"
    , "  Right sizes ← pure (poolSpec 2 4)"
    , "  done ← newEmptyMVar"
    , "  withContentRoot defaultContentLimits directory $ \\root → do"
    , "    Right inventory ← scanInventory limits root' root"
    , "    Right key ← pure (parseReference (inventoryIdentityLimits limits) root' (BC.pack \"data.txt\"))"
    , "    withReadPool sizes inventory root $ \\pool → do"
    , "      True ← atomically (reserveSlot pool)"
    , "      Right ticket ← atomically (submit pool (ReadRequest key 1024 OrdinaryRead (putMVar done)))"
    , "      result ← takeMVar done"
    , "      case result of"
    , "        ReadSucceeded bytes → BC.putStr bytes"
    , "        _ → fail \"the read did not succeed\""
    , "      atomically (retired ticket >>= \\finished → if finished then releaseSlot pool else pure ())"
    ]
