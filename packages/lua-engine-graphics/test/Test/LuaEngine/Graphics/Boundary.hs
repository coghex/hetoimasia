-- | The package boundary of the texture backend: its implementation and the seams the package's own suite uses (an observed scope, an
-- unpumped scope, one pump turn, the observer hooks) live in a private sub-library, and the public library keeps the interface it
-- has on master (#679). The examples read the Cabal description, and compile separate single-module clients with the harness from
-- "Test.Support.ExternalClient", which expose only the packages they name and so can say exactly what the package's
-- @exposed-modules@ and export lists allow a client to say: a client importing the public module by every name it exports compiles;
-- one importing a module of the private sub-library is refused as hidden, against that sub-library's unit; one asking the public
-- module for a seam is refused as not exported.
module Test.LuaEngine.Graphics.Boundary (spec) where

import Control.Monad (forM_)
import Data.Char (isSpace)
import Data.List (isInfixOf, isPrefixOf, sort)
import System.Directory (doesFileExist)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import Test.Hspec
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withStorePackageClient)

cabalName ∷ FilePath
cabalName = "hetoimasia-lua-engine-graphics.cabal"

-- | The Cabal description, found above the working directory.
cabal ∷ IO String
cabal = search "." (10 ∷ Int)
  where
    search _ 0 = fail (cabalName <> " was not found above the working directory")
    search directory budget = do
      here ← doesFileExist (directory </> cabalName)
      if here then readFile (directory </> cabalName) else search (directory </> "..") (budget - 1)

trim ∷ String → String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

-- | The entries of a list field of the stanza with this header.
fieldEntries ∷ String → String → IO [String]
fieldEntries header field = do
  description ← cabal
  let body = case dropWhile (/= header) (lines description) of
        [] → []
        (_ : rest) → takeWhile (\line → null (trim line) || " " `isPrefixOf` line) rest
  pure
    [ name
    | line ← takeWhile (not . endOfField) (drop 1 (dropWhile ((/= field) . trim) body))
    , let name = trim (takeWhile (\character → character /= ' ' && character /= ',') (trim line))
    , not (null name)
    ]
  where
    endOfField line = not (null (trim line)) && not ("        " `isPrefixOf` line)

-- | The modules the private sub-library holds.
hiddenModules ∷ [String]
hiddenModules =
  [ "Hetoimasia.LuaEngine.Graphics.Texture.Backend.Internal"
  , "Hetoimasia.LuaEngine.Graphics.Texture.Port.Internal"
  ]

-- | What the public backend module exports, as on master.
publicNames ∷ String
publicNames = "Backend, withBackend, textureBackend, BackendReading (..), readBackend, awaitBackendFailure, awaitBound, backendEvidence, BackendDefect (..)"

-- | The test seams, which only the private sub-library has.
seams ∷ [String]
seams = ["withBackendObserved", "withBackendUnpumped", "pumpOnce", "Examined (..)"]

withClient ∷ String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withStorePackageClient ["base", "text", "hetoimasia-lua-engine-graphics"] "Client.hs"

spec ∷ Spec
spec = describe "the texture backend's package boundary" $ do
  it "keeps the backend and the port in a private sub-library, and exposes none of its modules from the public library" $ do
    fieldEntries "library internal" "exposed-modules:" `shouldReturn` hiddenModules
    description ← cabal
    ("library internal\n    import: language\n    visibility: private\n" `isInfixOf` description) `shouldBe` True
    exposed ← fieldEntries "library" "exposed-modules:"
    [name | name ← exposed, ".Internal" `isInfixOf` name || name `elem` hiddenModules] `shouldBe` []
    exposed
      `shouldSatisfy` \names →
        all (`elem` names) ["Hetoimasia.LuaEngine.Graphics.Texture.Backend", "Hetoimasia.LuaEngine.Graphics.Texture.Port"]

  it "has a private sub-library over base libraries, the foundation, the asset package and the Lua engine's texture library, and nothing else" $
    (sort <$> fieldEntries "library internal" "build-depends:")
      `shouldReturn` ["base", "bytestring", "containers", "hetoimasia-asset", "hetoimasia-foundation", "hetoimasia-lua-engine:texture", "stm", "text"]

  it "accepts a client that imports every name the public backend module exports" $
    withClient (importClient "Hetoimasia.LuaEngine.Graphics.Texture.Backend" publicNames) $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitSuccess → pure ()
        status → expectationFailure ("the supported client must compile, but the compiler exited with " <> show status <> ":\n" <> clientOutput outcome)

  forM_ hiddenModules $ \hidden →
    it ("rejects a client that imports the private module " <> hidden) $
      withClient (importClient hidden "") $ \compile → do
        outcome ← compile Typecheck
        case clientStatus outcome of
          ExitFailure _ → pure ()
          ExitSuccess → expectationFailure ("the client compiled, so " <> hidden <> " is reachable:\n" <> clientOutput outcome)
        -- Found in the package's private sub-library and refused as hidden; naming that unit tells this apart from a missing module
        -- or an unresolvable package.
        clientOutput outcome `shouldContain` "GHC-87110"
        clientOutput outcome `shouldContain` "hetoimasia-lua-engine-graphics-0.1.0.0:internal"
        clientOutput outcome `shouldNotContain` "cannot satisfy"
        clientOutput outcome `shouldNotContain` "Could not find module"

  forM_ seams $ \seam →
    it ("rejects a client that asks the public backend module for " <> seam) $
      withClient (importClient "Hetoimasia.LuaEngine.Graphics.Texture.Backend" seam) $ \compile → do
        outcome ← compile Typecheck
        rejectedBecause outcome "GHC-61689"
        clientOutput outcome `shouldContain` takeWhile (/= ' ') seam

-- | A client that imports these names from a module, or only the module when no name is given.
importClient ∷ String → String → String
importClient moduleName names =
  unlines
    [ "module Client () where"
    , "import " <> moduleName <> (if null names then "" else " (" <> names <> ")")
    ]
