-- | The sample's package and import boundary (requirement 1), read from the Cabal description and the
-- imports rather than from what the examples happened to run: the library depends on foundation,
-- runtime and the Lua package's public modules; it imports no runner and no internal module; it needs
-- no Vulkan, GLFW or console package; nothing in the engine depends on it; and no routine check
-- launches its executable.
module Test.Domains.Dependencies (spec) where

import Control.Monad (filterM, forM)
import Data.Char (isSpace)
import Data.List (isInfixOf, isPrefixOf, sort)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (takeExtension, takeFileName, (</>))
import Test.Hspec

cabalName ∷ FilePath
cabalName = "hetoimasia-sample-lua-domains.cabal"

-- | The directory above the working directory that holds this file.
above ∷ FilePath → IO FilePath
above name = search "." (10 ∷ Int)
  where
    search _ 0 = fail (name <> " was not found above the working directory")
    search directory budget = do
      here ← doesFileExist (directory </> name)
      if here then pure directory else search (directory </> "..") (budget - 1)

trim ∷ String → String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

-- | The lines of the stanza with this header.
stanzaBody ∷ String → IO [String]
stanzaBody header = do
  root ← above cabalName
  description ← readFile (root </> cabalName)
  case dropWhile (/= header) (lines description) of
    [] → fail ("the cabal description has no `" <> header <> "` stanza")
    (_ : rest) → pure (takeWhile indented rest)
  where
    indented line = null (trim line) || " " `isPrefixOf` line

-- | The dependency names the stanza with this header declares.
dependencies ∷ String → IO [String]
dependencies header = sort . names <$> stanzaBody header
  where
    names body =
      [ name
      | line ← takeWhile (not . endOfField) (drop 1 (dropWhile ((/= "build-depends:") . trim) body))
      , let name = trim (takeWhile (\character → character /= ' ' && character /= ',') (trim line))
      , not (null name)
      ]
    endOfField line = not (null (trim line)) && not ("        " `isPrefixOf` line)

-- | Every Haskell source under a directory of the package.
sourcesUnder ∷ FilePath → IO [FilePath]
sourcesUnder directory = do
  root ← above cabalName
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
    , moduleName ← take 1 (filter (`notElem` ["qualified", "safe"]) (words (drop (length ("import " ∷ String)) line)))
    ]

-- | Every Cabal description in the repository, outside build and version-control directories.
cabalFiles ∷ FilePath → IO [FilePath]
cabalFiles directory = do
  entries ← listDirectory directory
  let paths = [directory </> entry | entry ← entries, entry `notElem` ["dist-newstyle", ".git", "node_modules"]]
  subdirectories ← filterM doesDirectoryExist paths
  files ← filterM doesFileExist paths
  nested ← forM subdirectories cabalFiles
  pure ([file | file ← files, takeExtension file == ".cabal"] <> concat nested)

spec ∷ Spec
spec = describe "the package and import boundary" $ do
  it "has a library that depends on the foundation, the runtime and the Lua package's public modules, and base libraries, and nothing else" $
    dependencies "library"
      `shouldReturn` sort
        [ "base"
        , "bytestring"
        , "containers"
        , "cryptohash-sha256"
        , "deepseq"
        , "directory"
        , "filepath"
        , "hetoimasia-foundation"
        , "hetoimasia-runtime"
        , "hetoimasia-scripting-lua"
        , "hetoimasia-scripting-lua:runtime-lua"
        , "stm"
        , "template-haskell"
        , "text"
        , "unix"
        ]

  it "has an executable that depends on the sample, the runtime's lifecycle and the foundation, and no GLFW, Vulkan or console package" $
    dependencies "executable hetoimasia-lua-domains"
      `shouldReturn` sort ["base", "hetoimasia-foundation", "hetoimasia-runtime", "hetoimasia-sample-lua-domains", "text"]

  it "imports no runner, no internal module and nothing of GLFW, Vulkan, rendering or the console" $ do
    sources ← (<>) <$> sourcesUnder "src" <*> sourcesUnder "app"
    sources `shouldSatisfy` ((>= 10) . length)
    imported ← concat <$> mapM (\path → map ((,) (takeFileName path)) <$> importsOf path) sources
    [file <> ": " <> name | (file, name) ← imported, not (permitted name)] `shouldBe` []
    [file <> ": " <> name | (file, name) ← imported, "Hetoimasia.Scripting.Lua.Runner" `isPrefixOf` name || ".Internal" `isInfixOf` name] `shouldBe` []

  it "keeps its Lua sources as files under the library's source directory" $ do
    root ← above cabalName
    mapM_
      (\file → doesFileExist (root </> "src" </> "lua" </> file) `shouldReturn` True)
      ["gameplay.lua", "gameplay_init.lua", "interface.lua", "ui_facade.lua"]
    body ← stanzaBody "library"
    [trim line | line ← body, "hs-source-dirs:" `isPrefixOf` trim line] `shouldBe` ["hs-source-dirs: src"]

  it "is listed by both project files, and depended on by no other package" $ do
    root ← above "cabal.project"
    mapM_
      (\file → readFile (root </> file) >>= \listing → ("samples/lua-domains" `isInfixOf` listing) `shouldBe` True)
      ["cabal.project", "cabal.project.cpu"]
    others ← filter ((/= cabalName) . takeFileName) <$> cabalFiles root
    others `shouldSatisfy` ((> 10) . length)
    offenders ← filterM (fmap ("hetoimasia-sample-lua-domains" `isInfixOf`) . readFile) others
    offenders `shouldBe` []

  it "is launched by no validation group: the catalog never names its executable" $ do
    root ← above "cabal.project"
    catalog ← readFile (root </> "tools" </> "validation" </> "catalog.json")
    ("hetoimasia-lua-domains" `isInfixOf` catalog) `shouldBe` False
    ("hetoimasia-sample-lua-domains:lua-domains-tests" `isInfixOf` catalog) `shouldBe` True
  where
    permitted name =
      any
        (`isPrefixOf` name)
        [ "Control."
        , "Crypto.Hash."
        , "Data."
        , "GHC."
        , "Language.Haskell.TH"
        , "Numeric"
        , "System."
        , "Text."
        , "Prelude"
        , "Hetoimasia.Foundation."
        , "Hetoimasia.Runtime."
        , "Hetoimasia.Scripting.Lua."
        , "Hetoimasia.Sample.LuaDomains"
        ]
