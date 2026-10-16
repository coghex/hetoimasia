-- | The adapter's dependency closure, read from the build configuration and
-- from the imports rather than from what the examples happened to run.
--
-- The `runtime-lua` sublibrary depends on the host library, the private model
-- (and the private bridge where it must), the runtime and the foundation, and on
-- nothing of GLFW, Vulkan, the console or any game (P-1). It does not reach for
-- `Runtime.Inbox`, whose startup handoff P-3 says is not reused here. Both
-- places a dependency could be introduced are read: the stanza and the imports
-- of its modules. The check is deliberately textual and as small as the claim,
-- and needs no VM.
module Test.LuaRuntime.Dependencies (spec) where

import Control.Monad (filterM)
import Data.Char (isSpace)
import Data.List (isPrefixOf, sort)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (takeExtension, (</>))
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

-- | Every Haskell source file under a directory of the package.
sourcesUnder ∷ FilePath → IO [FilePath]
sourcesUnder directory = do
  root ← packageRoot
  walk (root </> directory)
  where
    walk path = do
      entries ← listDirectory path
      let paths = map (path </>) entries
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
spec = describe "the adapter's dependency closure" $ do
  it "declares the host library, the model, the bridge, the runtime, the foundation and base libraries, and nothing else" $
    dependencies "library runtime-lua"
      `shouldReturn` sort
        [ "base"
        , "containers"
        , "deepseq"
        , "hetoimasia-foundation"
        , "hetoimasia-runtime"
        , "hetoimasia-scripting-lua"
        , "hetoimasia-scripting-lua:bridge"
        , "hetoimasia-scripting-lua:model"
        , "stm"
        , "text"
        ]

  it "leaves the host library depending on neither the runtime nor the adapter" $ do
    host ← dependencies "library"
    host `shouldSatisfy` all (\name → name `notElem` ["hetoimasia-runtime", "hetoimasia-scripting-lua:runtime-lua"])

  it "imports from the host, the model, the bridge, the runtime's supervision, the foundation and base, and from nothing of GLFW, Vulkan, the console or a game" $ do
    sources ← sourcesUnder "runtime-lua"
    sources `shouldSatisfy` ((>= 4) . length)
    imported ← concat <$> mapM (\path → map ((,) path) <$> importsOf path) sources
    let offending = [path <> ": " <> name | (path, name) ← imported, not (permitted name)]
    offending `shouldBe` []
  where
    permitted name =
      any
        (`isPrefixOf` name)
        [ "Control."
        , "Data."
        , "GHC."
        , "Numeric"
        , "System."
        , "Text."
        , "Prelude"
        , "Hetoimasia.Foundation."
        , "Hetoimasia.Runtime.Supervision"
        , "Hetoimasia.Scripting.Lua."
        ]
