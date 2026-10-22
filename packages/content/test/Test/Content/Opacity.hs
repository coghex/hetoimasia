-- | Examples proving the package's public boundary: a client sees the scoped
-- operations and their values, and nothing that would let it build a name
-- around the checks, reach a descriptor, or substitute the native adapter.
--
-- Each compiles a separate single-module client with the harness from
-- "Test.Support.ExternalClient", exposing @base@, @bytestring@ and the
-- package's main library and hiding everything else, so what the client can say is
-- exactly what the library's @exposed-modules@ and export lists allow. Every
-- rejected client is checked against the diagnostic that names its cause; the
-- accepted client is compiled, linked and run against a tree this example
-- builds, which is both the control that the environment is sound and the
-- evidence that the scoped API is usable without any private import.
--
-- The failure-injection seam, the boundary hooks and the native adapter live in
-- the package's private sublibrary, which a client cannot expose; the example
-- that imports them is refused as a hidden package, naming that sublibrary.
module Test.Content.Opacity (spec) where

import qualified Data.ByteString.Char8 as BC
import System.Directory (createDirectory)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.Process (proc, readCreateProcessWithExitCode)
import Test.Content.Support (withTree, writeBytes)
import Test.Hspec
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withPackageClient)

spec ∷ Spec
spec = describe "Content package boundary" $ do
  it "rejects a client that builds a native name around the checked constructor" $
    withClient "Client.hs" constructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      clientOutput outcome `shouldContain` "NativeName"

  it "rejects a client that names a raw descriptor type" $
    withClient "Client.hs" descriptorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-61689"
      clientOutput outcome `shouldContain` "NativeFd"

  it "rejects a client that reads a root's descriptor" $
    withClient "Client.hs" rootDescriptorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-61689"
      clientOutput outcome `shouldContain` "rootFd"

  it "rejects a client that rewrites a root's report by record update" $
    withClient "Client.hs" reportUpdateClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess → expectationFailure ("the client compiled, so a root's report can be rewritten:\n" <> clientOutput outcome)
      clientOutput outcome `shouldContain` "rootReport"
      clientOutput outcome `shouldNotContain` "Could not find module"

  it "rejects a client that rewrites a limit by record update" $
    withClient "Client.hs" limitUpdateClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess → expectationFailure ("the client compiled, so a limit can be set to a value contentLimits refuses:\n" <> clientOutput outcome)
      clientOutput outcome `shouldContain` "limitPathDepth"
      clientOutput outcome `shouldNotContain` "Could not find module"

  it "rejects a client that builds a reader from its parts" $
    withClient "Client.hs" readerConstructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      clientOutput outcome `shouldContain` "FileReader"

  it "rejects a client that substitutes the native adapter through the private library" $
    withClient "Client.hs" adapterClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess → expectationFailure ("the client compiled, so the adapter is reachable:\n" <> clientOutput outcome)
      -- The private implementation library is found and refused as hidden;
      -- naming its unit tells this apart from a missing package.
      clientOutput outcome `shouldContain` "GHC-87110"
      clientOutput outcome `shouldContain` "hidden package"
      clientOutput outcome `shouldContain` "hetoimasia-content-0.1.0.0:internal"
      clientOutput outcome `shouldNotContain` "cannot satisfy"

  it "accepts and runs a client using only the scoped operations" $
    withTree $ \tree →
      withClient "Main.hs" scopedClient $ \compile → do
        outcome ← compile Link
        case clientStatus outcome of
          ExitSuccess → pure ()
          status →
            expectationFailure
              ("the supported client must compile, but the compiler exited with " <> show status <> ":\n" <> clientOutput outcome)
        createDirectory (tree </> "root")
        writeBytes (tree </> "root" </> "data.txt") (BC.pack "read through the public API")
        (status, out, err) ← readCreateProcessWithExitCode (proc (clientDirectory outcome </> "client") [tree </> "root"]) ""
        (status, out, err) `shouldBe` (ExitSuccess, "read through the public API", "")

withClient ∷ String → String → ((Mode → IO Client) → IO ()) → IO ()
-- | The facade is exposed by its unit id: a package with a private sublibrary
-- registers every component under one package name, so the name alone matches
-- more than one unit and the compiler's choice among them is not stable.
withClient = withPackageClient ["base", "bytestring", "hetoimasia-content-0.1.0.0-inplace"]

constructorClient ∷ String
constructorClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Data.ByteString (ByteString)"
    , "import Hetoimasia.Content (NativeName (NativeName))"
    , ""
    , "forged ∷ ByteString → NativeName"
    , "forged = NativeName"
    ]

descriptorClient ∷ String
descriptorClient =
  unlines
    [ "module Client (descriptor) where"
    , ""
    , "import Hetoimasia.Content (NativeFd)"
    , ""
    , "descriptor ∷ Maybe NativeFd"
    , "descriptor = Nothing"
    ]

rootDescriptorClient ∷ String
rootDescriptorClient =
  unlines
    [ "module Client (descriptor) where"
    , ""
    , "import Hetoimasia.Content (ContentRoot, rootFd)"
    , ""
    , "descriptor ∷ ContentRoot → ()"
    , "descriptor root = rootFd root `seq` ()"
    ]

reportUpdateClient ∷ String
reportUpdateClient =
  unlines
    [ "module Client (rewritten) where"
    , ""
    , "import Hetoimasia.Content (ContentRoot, RootReport, rootReport)"
    , ""
    , "rewritten ∷ ContentRoot → RootReport → ContentRoot"
    , "rewritten root report = root {rootReport = report}"
    ]

limitUpdateClient ∷ String
limitUpdateClient =
  unlines
    [ "module Client (zeroed) where"
    , ""
    , "import Hetoimasia.Content (ContentLimits, limitPathDepth)"
    , ""
    , "zeroed ∷ ContentLimits → ContentLimits"
    , "zeroed limits = limits {limitPathDepth = 0}"
    ]

readerConstructorClient ∷ String
readerConstructorClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Content (FileReader (FileReader))"
    , ""
    , "forged ∷ Maybe FileReader"
    , "forged = Nothing"
    ]

adapterClient ∷ String
adapterClient =
  unlines
    [ "module Client (substitute) where"
    , ""
    , "import Hetoimasia.Content.Internal.Native (Seam, productionSeam)"
    , ""
    , "substitute ∷ Seam"
    , "substitute = productionSeam"
    ]

scopedClient ∷ String
scopedClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import qualified Data.ByteString.Char8 as BC"
    , "import Hetoimasia.Content"
    , "import System.Environment (getArgs)"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  [directory] ← getArgs"
    , "  Right component ← pure (nativeName (BC.pack \"data.txt\"))"
    , "  bytes ←"
    , "    withContentRoot defaultContentLimits directory $ \\root →"
    , "      withFile root [component] $ \\reader → readChunk reader 64"
    , "  BC.putStr bytes"
    ]
