-- | The model component's dependency closure, checked from the build
-- configuration rather than from what the examples happened to run.
--
-- Running these examples without acquiring an interpreter, which
-- "Test.Lua.Protocol.Fixture" records, proves that this group did not need
-- one. It does not prove that the model /could not/ need one: a component may
-- depend on the binding and simply not call it. That is a different question,
-- and it is answered here, by reading the Cabal stanza that declares the
-- component and the imports of the modules it contains.
--
-- Both checks are deliberately textual. The alternative is to ask Cabal for
-- the build plan, which would mean running the build tool from inside a test;
-- the stanza and the imports are the two places the dependency could be
-- introduced, and reading them is the smallest check that would fail if it
-- were.
module Test.Lua.Protocol.Boundary (spec) where

import Control.Monad (filterM)
import Data.Char (isSpace)
import Data.List (isInfixOf, isPrefixOf, sort)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>), takeExtension)
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn)

-- | The package this suite belongs to, found from wherever the suite runs.
packageRoot ∷ IO FilePath
packageRoot = search "." (8 ∷ Int)
  where
    search _ 0 = fail "hetoimasia-scripting-lua.cabal was not found above the working directory"
    search directory budget = do
      here ← doesFileExist (directory </> cabalName)
      if here then pure directory else search (directory </> "..") (budget - 1)

cabalName ∷ FilePath
cabalName = "hetoimasia-scripting-lua.cabal"

-- | The dependency names the @library model@ stanza declares.
modelDependencies ∷ IO [String]
modelDependencies = do
  root ← packageRoot
  description ← readFile (root </> cabalName)
  case stanza (lines description) of
    [] → fail "the cabal description has no `library model` stanza"
    body → pure (sort (dependencyNames body))
  where
    stanza allLines = case dropWhile (/= "library model") allLines of
      [] → []
      (_ : rest) → takeWhile indented rest
    indented line = null (trim line) || " " `isPrefixOf` line
    dependencyNames body =
      [ name
      | line ← takeWhile (not . endOfField) (drop 1 (dropWhile (not . isDependencyField) body))
      , let name = trim (takeWhile (\character → character /= ' ' && character /= ',') (trim line))
      , not (null name)
      ]
    isDependencyField line = trim line == "build-depends:"
    endOfField line = not (null (trim line)) && not ("        " `isPrefixOf` line)
    trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

-- | Every Haskell source file of the model component.
modelSources ∷ IO [FilePath]
modelSources = do
  root ← packageRoot
  walk (root </> "model")
  where
    walk directory = do
      entries ← listDirectory directory
      let paths = map (directory </>) entries
      directories ← filterM doesDirectoryExist paths
      files ← filterM doesFileExist paths
      nested ← mapM walk directories
      pure ([file | file ← files, takeExtension file == ".hs"] <> concat nested)

spec ∷ Spec
spec = describe "boundary" $ do
  it "declares no dependency on the Lua binding in the model component" $
    modelDependencies `shouldReturn` ["base", "containers", "text"]

  it "contains modules, all of which import neither the binding nor raw Lua" $ do
    sources ← modelSources
    length sources `shouldBe` 8
    offending ← concat <$> mapM bindingImports sources
    offending `shouldBe` []
  where
    bindingImports path = do
      contents ← readFile path
      pure
        [ path <> ": " <> line
        | line ← lines contents
        , "import " `isPrefixOf` line
        , any (`isInfixOf` line) forbidden
        ]
    forbidden =
      [ "Hetoimasia.Scripting.Lua.Bridge"
      , "Hetoimasia.Scripting.Lua.Internal.Call"
      , "Hetoimasia.Scripting.Lua.Internal.Callback"
      , "Hetoimasia.Scripting.Lua.Internal.Fault"
      , "Hetoimasia.Scripting.Lua.Internal.Library"
      , "Hetoimasia.Scripting.Lua.Internal.Vm"
      , "import Lua"
      , "import qualified Lua"
      ]
