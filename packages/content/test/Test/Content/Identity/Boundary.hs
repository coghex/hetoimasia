-- | Examples proving the identity API's public boundary and the package's
-- dependency direction.
--
-- A client sees the checked constructors and the values they return, and
-- nothing that would let it build a logical path, a root key, a set of limits
-- or a mapping around the checks. Each rejected client is a separate
-- single-module program compiled with "Test.Support.ExternalClient" against
-- the package's public library alone, checked against the diagnostic that names
-- its cause. The accepted client builds limits from explicit numbers, a root
-- key, a reference and a mapping through the public interface only, and runs.
--
-- This package's libraries depend on Hackage packages (the Unicode data), so the
-- clients use the harness variant that also exposes the dependency store;
-- exposing the store widens nothing a client may say, because every package is
-- still named explicitly.
module Test.Content.Identity.Boundary (spec) where

import qualified Data.ByteString as BS
import Data.Char (isAlphaNum)
import Data.List (isPrefixOf, nub, sort)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.Process (proc, readCreateProcessWithExitCode)
import Test.Hspec
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withStorePackageClient)

spec ∷ Spec
spec = describe "Identity package boundary" $ do
  it "rejects a client that builds a logical path around the check" $
    withClient "Client.hs" logicalPathClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      clientOutput outcome `shouldContain` "LogicalPath"

  it "rejects a client that builds a root key around the check" $
    withClient "Client.hs" rootKeyClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      clientOutput outcome `shouldContain` "RootKey"

  it "rejects a client that builds limits around the check" $
    withClient "Client.hs" limitsClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      clientOutput outcome `shouldContain` "IdentityLimits"

  it "rejects a client that rewrites a limit by record update" $
    withClient "Client.hs" limitUpdateClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess → expectationFailure ("the client compiled, so a limit can be set to a value identityLimits refuses:\n" <> clientOutput outcome)
      clientOutput outcome `shouldContain` "limitPathBytes"
      clientOutput outcome `shouldNotContain` "Could not find module"

  it "rejects a client that builds a mapping around the inventory check" $
    withClient "Client.hs" mappingClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      clientOutput outcome `shouldContain` "NativeMapping"

  it "rejects a client that imports the private implementation" $
    withClient "Client.hs" internalClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess → expectationFailure ("the client compiled, so the implementation is reachable:\n" <> clientOutput outcome)
      clientOutput outcome `shouldContain` "GHC-87110"
      clientOutput outcome `shouldContain` "hidden package"
      clientOutput outcome `shouldContain` "hetoimasia-content-0.1.0.0:internal"
      clientOutput outcome `shouldNotContain` "cannot satisfy"

  it "accepts and runs a client that passes explicit narrow values and uses the checked results" $
    withClient "Main.hs" consumerClient $ \compile → do
      outcome ← compile Link
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ("the supported client must compile, but the compiler exited with " <> show status <> ":\n" <> clientOutput outcome)
      (status, out, err) ← readCreateProcessWithExitCode (proc (clientDirectory outcome </> "client") []) ""
      (status, out, err)
        `shouldBe` ( ExitSuccess
                   , unlines
                       [ "[\"images\",\"Hero.png\"]"
                       , "missing"
                       , "refused"
                       , "refused-inventory"
                       ]
                   , ""
                   )

  it "depends on no Lua, console, game or sample package: its libraries name only the foundation" $ do
    cabal ← T.unpack . TE.decodeUtf8 <$> BS.readFile "hetoimasia-content.cabal"
    let code = [line | line ← lines cabal, not ("--" `isPrefixOf` dropWhile (== ' ') line)]
        packages = nub (sort [word | line ← code, word ← words (map spaceUnlessName line), "hetoimasia-" `isPrefixOf` word])
    -- the test suite also names this package's own units and the test-support library
    filter (`notElem` ["hetoimasia-content", "hetoimasia-foundation", "hetoimasia-test-support"]) packages `shouldBe` []
  where
    spaceUnlessName c = if isAlphaNum c || c == '-' then c else ' '

withClient ∷ String → String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withStorePackageClient ["base", "bytestring", "hetoimasia-content-0.1.0.0-inplace"]

logicalPathClient ∷ String
logicalPathClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Content.Identity (LogicalPath (LogicalPath))"
    , ""
    , "forged ∷ Maybe LogicalPath"
    , "forged = Nothing"
    ]

rootKeyClient ∷ String
rootKeyClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Data.ByteString (ByteString)"
    , "import Hetoimasia.Content.Identity (RootKey (RootKey))"
    , ""
    , "forged ∷ ByteString → RootKey"
    , "forged = RootKey"
    ]

limitsClient ∷ String
limitsClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Content.Identity (IdentityLimits (IdentityLimits))"
    , ""
    , "forged ∷ Int → Int → Int → Int → IdentityLimits"
    , "forged = IdentityLimits"
    ]

limitUpdateClient ∷ String
limitUpdateClient =
  unlines
    [ "module Client (zeroed) where"
    , ""
    , "import Hetoimasia.Content.Identity (IdentityLimits, limitPathBytes)"
    , ""
    , "zeroed ∷ IdentityLimits → IdentityLimits"
    , "zeroed limits = limits {limitPathBytes = 0}"
    ]

mappingClient ∷ String
mappingClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Content.Identity (NativeMapping (NativeMapping))"
    , ""
    , "forged ∷ Maybe NativeMapping"
    , "forged = Nothing"
    ]

internalClient ∷ String
internalClient =
  unlines
    [ "module Client (substitute) where"
    , ""
    , "import Hetoimasia.Content.Internal.Identity.Types (IdentityLimits (..))"
    , ""
    , "substitute ∷ Int → IdentityLimits"
    , "substitute n = IdentityLimits n n n n"
    ]

consumerClient ∷ String
consumerClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import qualified Data.ByteString.Char8 as BC"
    , "import Data.List.NonEmpty (toList)"
    , "import Hetoimasia.Content (nativeNameBytes)"
    , "import Hetoimasia.Content.Identity"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  Right narrow ← pure (identityLimits 1024 255 32 10000)"
    , "  Right root ← pure (rootKey (BC.pack \"game\"))"
    , "  Right mapping ←"
    , "    pure (buildMapping narrow root [ObservedEntry [BC.pack \"images\", BC.pack \"Hero.png\"] ObservedFile])"
    , "  case parseReference narrow root (BC.pack \"images/Hero.png\") of"
    , "    Left refusal → putStrLn (\"refused \" <> show refusal)"
    , "    Right key → case lookupPath mapping (contentKeyPath key) of"
    , "      Nothing → putStrLn \"missing\""
    , "      Just entry → print (map (BC.unpack . nativeNameBytes) (toList (mappedNative entry)))"
    , "  case parseReference narrow root (BC.pack \"images/hero.png\") of"
    , "    Left _ → putStrLn \"refused\""
    , "    Right key → putStrLn (maybe \"missing\" (const \"found\") (lookupPath mapping (contentKeyPath key)))"
    , "  putStrLn (either (const \"refused\") (const \"accepted\") (parseReference narrow root (BC.pack \"a\\\\b\")))"
    , "  putStrLn"
    , "    ( either"
    , "        (const \"refused-inventory\")"
    , "        (const \"built\")"
    , "        (buildMapping narrow root [ObservedEntry [BC.pack \"A\"] ObservedFile, ObservedEntry [BC.pack \"a\"] ObservedFile])"
    , "    )"
    ]
