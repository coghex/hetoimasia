-- | The host library's dependency closure, checked from the build configuration
-- and the imports rather than from what the examples happened to run.
--
-- The scripting host depends on the foundation and on the Lua binding, and on
-- nothing of the runtime, the window system, the GPU or any game namespace
-- (P-1). Both places a dependency could be introduced are read: the Cabal
-- stanzas that declare the host's components, and the imports of the modules
-- they contain. The check is deliberately textual and as small as the claim.
module Test.Lua.Boundary.Dependencies (spec) where

import Control.Monad (filterM)
import Data.Char (isSpace)
import Data.List (isPrefixOf, sort)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>), takeExtension)
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy)

packageRoot ∷ IO FilePath
packageRoot = search "." (8 ∷ Int)
  where
    search _ 0 = fail "hetoimasia-scripting-lua.cabal was not found above the working directory"
    search directory budget = do
      here ← doesFileExist (directory </> cabalName)
      if here then pure directory else search (directory </> "..") (budget - 1)

cabalName ∷ FilePath
cabalName = "hetoimasia-scripting-lua.cabal"

-- | The dependency names the stanza with this header declares.
dependencies ∷ String → IO [String]
dependencies header = do
  root ← packageRoot
  description ← readFile (root </> cabalName)
  case stanza (lines description) of
    [] → fail ("the cabal description has no `" <> header <> "` stanza")
    body → pure (sort (dependencyNames body))
  where
    stanza allLines = case dropWhile (/= header) allLines of
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

-- | Every Haskell source file under these directories of the package.
sourcesUnder ∷ [FilePath] → IO [FilePath]
sourcesUnder directories = do
  root ← packageRoot
  concat <$> mapM (walk . (root </>)) directories
  where
    walk directory = do
      entries ← listDirectory directory
      let paths = map (directory </>) entries
      subdirectories ← filterM doesDirectoryExist paths
      files ← filterM doesFileExist paths
      nested ← mapM walk subdirectories
      pure ([file | file ← files, takeExtension file == ".hs"] <> concat nested)

-- | The modules a source file imports.
importsOf ∷ FilePath → IO [String]
importsOf path = do
  contents ← readFile path
  pure
    [ moduleName
    | line ← lines contents
    , "import " `isPrefixOf` line
    , let afterImport = words (drop (length ("import " ∷ String)) line)
    , moduleName ← take 1 (filter (`notElem` ["qualified", "safe"]) afterImport)
    ]

spec ∷ Spec
spec = describe "the host library's dependency closure" $ do
  it "declares only the foundation, the binding and base libraries in the bridge" $
    dependencies "library bridge"
      `shouldReturn` ["base", "bytestring", "containers", "hetoimasia-foundation", "lua", "text"]

  it "declares only the foundation and the bridge in the public library" $
    dependencies "library"
      `shouldReturn` ["base", "bytestring", "hetoimasia-foundation", "hetoimasia-scripting-lua:bridge", "text"]

  it "imports from the foundation, the binding, itself and base, and from nothing of the runtime, window system, GPU or game" $ do
    sources ← sourcesUnder ["bridge", "src"]
    sources `shouldSatisfy` any (("Internal" </> "Module.hs") `isSuffix`)
    imported ← concat <$> mapM (\path → map ((,) path) <$> importsOf path) sources
    let offending = [path <> ": " <> name | (path, name) ← imported, not (permitted name)]
    offending `shouldBe` []
  where
    isSuffix suffix path = suffix == reverse (take (length suffix) (reverse path))
    permitted name =
      any
        (`isPrefixOf` name)
        [ "Control."
        , "Data."
        , "Foreign"
        , "GHC."
        , "Numeric"
        , "System."
        , "Text."
        , "Prelude"
        , "Lua"
        , "Hetoimasia.Foundation."
        , "Hetoimasia.Scripting.Lua."
        ]
