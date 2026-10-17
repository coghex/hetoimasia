-- | The scheduling machinery's dependency closure, read from the imports of its
-- modules rather than from what the examples happened to run: it names no VM,
-- no bridge, no registration, no owner, no supervision, and nothing of GLFW,
-- Vulkan, the console or a game, so it is exercised by scripted segments and is
-- independent of how coroutines come to exist.
module Test.LuaRuntime.Scheduler.Structure (spec) where

import Control.Monad (filterM)
import Data.List (isPrefixOf)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (takeExtension, (</>))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

packageRoot ∷ IO FilePath
packageRoot = search "." (8 ∷ Int)
  where
    search _ 0 = fail "hetoimasia-scripting-lua.cabal was not found above the working directory"
    search directory budget = do
      here ← doesFileExist (directory </> "hetoimasia-scripting-lua.cabal")
      if here then pure directory else search (directory </> "..") (budget - 1)

-- | The scheduler's source files: the facade and everything beneath it.
schedulerSources ∷ IO [FilePath]
schedulerSources = do
  root ← packageRoot
  let base = root </> "runtime-lua" </> "Hetoimasia" </> "Scripting" </> "Lua"
      directory = base </> "Scheduler"
  entries ← map (directory </>) <$> listDirectory directory
  files ← filterM doesFileExist entries
  nested ← filterM doesDirectoryExist entries
  pure ((base </> "Scheduler.hs") : [file | file ← files <> concatMap pure nested, takeExtension file == ".hs"])

importsOf ∷ FilePath → IO [String]
importsOf path = do
  contents ← readFile path
  pure
    [ moduleName
    | line ← lines contents
    , "import " `isPrefixOf` line
    , moduleName ← take 1 (filter (`notElem` ["qualified", "safe"]) (words (drop 7 line)))
    ]

spec ∷ Spec
spec = describe "the scheduling machinery's dependencies" $ do
  it "imports only base, the foundation's clock, the protocol model and itself" $ do
    sources ← schedulerSources
    length sources `shouldSatisfy` (>= 5)
    imported ← concat <$> mapM (\path → map ((,) path) <$> importsOf path) sources
    let permitted name =
          any
            (`isPrefixOf` name)
            [ "Control."
            , "Data."
            , "GHC."
            , "Prelude"
            , "Hetoimasia.Foundation.Time"
            , "Hetoimasia.Scripting.Lua.Internal.Protocol."
            , "Hetoimasia.Scripting.Lua.Scheduler"
            ]
    [path <> ": " <> name | (path, name) ← imported, not (permitted name)] `shouldBe` []
