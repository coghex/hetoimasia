-- | The package and import boundary, read from the Cabal description and the
-- imports rather than from what the examples happened to run: the library
-- depends on the foundation's time values, the content package, the Lua host and
-- its runtime and base libraries only, its manifest and profile import nothing
-- that performs IO, its behavior selection imports only the Lua host's and
-- runtime's public modules, its boot checkpoint imports only the content
-- package's public modules (and reads only through them), it exposes four
-- modules, needs no GLFW, Vulkan, console, sample or game package, and is listed
-- by the ordinary and CPU projects and not by the Vulkan project (LFE-22 wires
-- that). Its request, data, texture and scene sublibraries are each held to their own
-- dependencies and public imports; the scene one imports no oracle, which is the suite's.
module Test.LuaEngine.Boundary (spec) where

import Control.Monad (filterM)
import Data.Char (isSpace)
import Data.List (isInfixOf, isPrefixOf, nub, sort)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (takeExtension, takeFileName, (</>))
import Test.Hspec

cabalName ∷ FilePath
cabalName = "hetoimasia-lua-engine.cabal"

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

-- | The entries of a list field of the stanza: the indented lines after the
-- field's name, up to the next field.
fieldEntries ∷ String → String → IO [String]
fieldEntries header field = do
  body ← stanzaBody header
  pure
    [ name
    | line ← takeWhile (not . endOfField) (drop 1 (dropWhile ((/= field) . trim) body))
    , let name = trim (takeWhile (\character → character /= ' ' && character /= ',') (trim line))
    , not (null name)
    ]
  where
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

importedBy ∷ [FilePath] → IO [(String, String)]
importedBy sources = concat <$> mapM (\path → map ((,) (takeFileName path)) <$> importsOf path) sources

spec ∷ Spec
spec = describe "the package and import boundary" $ do
  it "has a library that depends on the foundation, the content package, the Lua host and its runtime, and base libraries, and nothing else" $
    (sort <$> fieldEntries "library" "build-depends:")
      `shouldReturn` ["array", "base", "bytestring", "containers", "hetoimasia-content", "hetoimasia-foundation", "hetoimasia-scripting-lua", "hetoimasia-scripting-lua:runtime-lua", "text"]

  it "exposes the behavior selection, the boot checkpoint, the manifest and the profile, and nothing else" $
    fieldEntries "library" "exposed-modules:"
      `shouldReturn` ["Hetoimasia.LuaEngine.Behavior", "Hetoimasia.LuaEngine.Boot", "Hetoimasia.LuaEngine.Manifest", "Hetoimasia.LuaEngine.Profile"]

  it "imports only pure data libraries, the foundation's time values, the content package's public modules and its own modules: no IO of its own, no concurrency, no environment, no Lua" $ do
    sources ← sourcesUnder "src"
    sources `shouldSatisfy` ((>= 10) . length)
    imported ← importedBy sources
    [file <> ": " <> name | (file, name) ← imported, not (permitted file name)] `shouldBe` []
    [file <> ": " <> name | (file, name) ← imported, ".Internal" `isInfixOf` name] `shouldBe` []

  it "has a request sublibrary over the profile and the host's public modules, and nothing else" $ do
    (sort <$> fieldEntries "library request" "build-depends:")
      `shouldReturn` ["base", "bytestring", "hetoimasia-lua-engine", "hetoimasia-scripting-lua", "hetoimasia-scripting-lua:runtime-lua", "text"]
    fieldEntries "library request" "exposed-modules:" `shouldReturn` ["Hetoimasia.LuaEngine.Request"]

  it "imports, in the request sublibrary, only the profile, the host's public modules and base libraries: no private module, no content, window, GPU, console, sample or game" $ do
    sources ← sourcesUnder "request"
    sources `shouldSatisfy` ((>= 1) . length)
    imported ← importedBy sources
    [file <> ": " <> name | (file, name) ← imported, not (permittedRequest name)] `shouldBe` []
    [file <> ": " <> name | (file, name) ← imported, ".Internal" `isInfixOf` name] `shouldBe` []

  it "has a data sublibrary over the profile, the request adapter, the content package and the host's public modules, and nothing else" $ do
    (sort <$> fieldEntries "library data" "build-depends:")
      `shouldReturn` [ "base"
                     , "bytestring"
                     , "hetoimasia-content"
                     , "hetoimasia-lua-engine"
                     , "hetoimasia-lua-engine:request"
                     , "hetoimasia-scripting-lua"
                     , "hetoimasia-scripting-lua:runtime-lua"
                     , "stm"
                     , "text"
                     ]
    fieldEntries "library data" "exposed-modules:" `shouldReturn` ["Hetoimasia.LuaEngine.Data"]

  it "imports, in the data sublibrary, only the profile, the request adapter, the content package's public modules, the host's public modules and base libraries: no private module, window, GPU, console, sample or game" $ do
    sources ← sourcesUnder "data"
    sources `shouldSatisfy` ((>= 1) . length)
    imported ← importedBy sources
    [file <> ": " <> name | (file, name) ← imported, not (permittedData name)] `shouldBe` []
    [file <> ": " <> name | (file, name) ← imported, ".Internal" `isInfixOf` name] `shouldBe` []

  it "has a texture sublibrary over the profile, the request adapter, the content package, the bounded PNG decoder, the foundation and the host's public modules, and nothing else" $ do
    (sort <$> fieldEntries "library texture" "build-depends:")
      `shouldReturn` [ "base"
                     , "bytestring"
                     , "containers"
                     , "hetoimasia-asset"
                     , "hetoimasia-asset-image"
                     , "hetoimasia-content"
                     , "hetoimasia-foundation"
                     , "hetoimasia-lua-engine"
                     , "hetoimasia-lua-engine:request"
                     , "hetoimasia-scripting-lua"
                     , "hetoimasia-scripting-lua:runtime-lua"
                     , "stm"
                     , "text"
                     ]
    fieldEntries "library texture" "exposed-modules:" `shouldReturn` ["Hetoimasia.LuaEngine.Texture", "Hetoimasia.LuaEngine.Texture.Backend"]

  it "imports, in the texture sublibrary, only the profile, the request adapter, the content package's, the decoder's, the foundation's and the host's public modules and base libraries: no private module, window, GPU, GLFW, Vulkan, console, sample or game" $ do
    sources ← sourcesUnder "texture"
    sources `shouldSatisfy` ((>= 4) . length)
    imported ← importedBy sources
    [file <> ": " <> name | (file, name) ← imported, not (permittedTexture name)] `shouldBe` []
    [file <> ": " <> name | (file, name) ← imported, ".Internal" `isInfixOf` name] `shouldBe` []

  it "keeps the texture backend port free of the host: it imports the host's retirement state and nothing else of it" $ do
    sources ← sourcesUnder "texture"
    imported ← importedBy sources
    sort (nub [name | (file, name) ← imported, file == "Backend.hs", "Hetoimasia." `isPrefixOf` name])
      `shouldBe` ["Hetoimasia.Scripting.Lua.Provider"]

  it "has a scene sublibrary over the profile, the texture authority, the pure renderer packages and the host's public modules, and nothing else" $ do
    (sort <$> fieldEntries "library scene" "build-depends:")
      `shouldReturn` [ "base"
                     , "bytestring"
                     , "containers"
                     , "hetoimasia-lua-engine"
                     , "hetoimasia-lua-engine:texture"
                     , "hetoimasia-math"
                     , "hetoimasia-render-2d"
                     , "hetoimasia-render-api"
                     , "hetoimasia-scripting-lua"
                     , "hetoimasia-scripting-lua:runtime-lua"
                     , "text"
                     ]
    fieldEntries "library scene" "exposed-modules:" `shouldReturn` ["Hetoimasia.LuaEngine.Scene"]

  it "imports, in the scene sublibrary, only the profile, the texture sublibrary, the renderer's and the math package's public modules, the host's public modules and base libraries: no oracle, private module, window, GPU, GLFW, Vulkan, content, console, sample or game" $ do
    sources ← sourcesUnder "scene"
    sources `shouldSatisfy` ((>= 7) . length)
    imported ← importedBy sources
    [file <> ": " <> name | (file, name) ← imported, not (permittedScene name)] `shouldBe` []
    [file <> ": " <> name | (file, name) ← imported, ".Internal" `isInfixOf` name] `shouldBe` []

  it "lets only the behavior selection import the Lua host and runtime, and only their public modules" $ do
    sources ← sourcesUnder "src"
    imported ← importedBy sources
    [file | (file, name) ← imported, "Hetoimasia.Scripting." `isPrefixOf` name, file /= "Behavior.hs"] `shouldBe` []
    sort (nub [name | (file, name) ← imported, file == "Behavior.hs", "Hetoimasia.Scripting." `isPrefixOf` name])
      `shouldBe` [ "Hetoimasia.Scripting.Lua.Instance"
                 , "Hetoimasia.Scripting.Lua.Owner"
                 , "Hetoimasia.Scripting.Lua.Scheduled"
                 ]

  it "lets only the boot checkpoint import the content package, and only its public modules" $ do
    sources ← sourcesUnder "src"
    imported ← importedBy sources
    [file | (file, name) ← imported, "Hetoimasia.Content" `isPrefixOf` name, file /= "Boot.hs"] `shouldBe` []
    sort (nub [name | (file, name) ← imported, file == "Boot.hs", "Hetoimasia.Content" `isPrefixOf` name])
      `shouldBe` ["Hetoimasia.Content", "Hetoimasia.Content.Identity", "Hetoimasia.Content.Inventory"]

  it "is used by its own suite only through public modules: the manifest, the profile, the request adapter, the boot checkpoint, the content package's and the host's public interface" $ do
    sources ← sourcesUnder "test"
    sources `shouldSatisfy` ((>= 7) . length)
    imported ← importedBy sources
    [ file <> ": " <> name
      | (file, name) ← imported
      , "Hetoimasia." `isPrefixOf` name
      , not (permittedSuite name)
      ]
      `shouldBe` []
    [file <> ": " <> name | (file, name) ← imported, ".Internal" `isInfixOf` name] `shouldBe` []

  it "is listed by the ordinary and CPU projects, held to -Werror, and not by the Vulkan project" $ do
    root ← above "cabal.project"
    mapM_
      (\file → readFile (root </> file) >>= \listing → ("packages/lua-engine" `isInfixOf` listing) `shouldBe` True)
      ["cabal.project", "cabal.project.cpu"]
    vulkan ← readFile (root </> "cabal.project.vulkan")
    ("lua-engine" `isInfixOf` vulkan) `shouldBe` False
    common ← readFile (root </> "cabal.project.common")
    ("package hetoimasia-lua-engine\n  ghc-options: -Werror -j" `isInfixOf` common) `shouldBe` True

  it "is registered as the non-optional validation group that runs its suite" $ do
    root ← above "cabal.project"
    catalog ← readFile (root </> "tools" </> "validation" </> "catalog.json")
    ("\"hetoimasia-lua-engine:lua-engine-tests\"" `isInfixOf` catalog) `shouldBe` True
    ("\"id\": \"test.lua-engine\"" `isInfixOf` catalog) `shouldBe` True
  where
    permitted file name =
      "Data." `isPrefixOf` name
        || "GHC." `isPrefixOf` name
        || "Hetoimasia.LuaEngine." `isPrefixOf` name
        || name == "Hetoimasia.Foundation.Time"
        -- Only the behavior selection is over the Lua host's and runtime's public
        -- modules; the manifest and the profile import nothing of them.
        || (file == "Behavior.hs" && "Hetoimasia.Scripting.Lua." `isPrefixOf` name)
        -- Only the boot checkpoint is over the content package, through its
        -- public modules.
        || (file == "Boot.hs" && name `elem` ["Hetoimasia.Content", "Hetoimasia.Content.Identity", "Hetoimasia.Content.Inventory"])
    permittedRequest name =
      "Data." `isPrefixOf` name
        || "GHC." `isPrefixOf` name
        || name `elem` ["Hetoimasia.LuaEngine.Profile"]
        || "Hetoimasia.Scripting.Lua." `isPrefixOf` name
    permittedData name =
      "Data." `isPrefixOf` name
        || "GHC." `isPrefixOf` name
        || "Control." `isPrefixOf` name
        || name
          `elem` [ "Hetoimasia.LuaEngine.Profile"
                 , "Hetoimasia.LuaEngine.Request"
                 , "Hetoimasia.Content.Identity"
                 , "Hetoimasia.Content.Inventory"
                 , "Hetoimasia.Content.ReadPool"
                 ]
        || "Hetoimasia.Scripting.Lua." `isPrefixOf` name
    permittedTexture name =
      "Data." `isPrefixOf` name
        || "GHC." `isPrefixOf` name
        || "Control." `isPrefixOf` name
        || "Hetoimasia.LuaEngine.Texture" `isPrefixOf` name
        || name
          `elem` [ "Hetoimasia.LuaEngine.Profile"
                 , "Hetoimasia.LuaEngine.Request"
                 , "Hetoimasia.Content.Identity"
                 , "Hetoimasia.Content.Inventory"
                 , "Hetoimasia.Content.ReadPool"
                 , "Hetoimasia.Foundation.Resource"
                 , "Hetoimasia.Foundation.Worker"
                 , "Hetoimasia.Asset"
                 , "Hetoimasia.Asset.Image"
                 , "Hetoimasia.Asset.Image.PngDecode"
                 , "Hetoimasia.Asset.Image.PngPreflight"
                 , "Hetoimasia.Scripting.Lua.Admission"
                 , "Hetoimasia.Scripting.Lua.Lease"
                 , "Hetoimasia.Scripting.Lua.Provider"
                 , "Hetoimasia.Scripting.Lua.Registration"
                 , "Hetoimasia.Scripting.Lua.Value"
                 ]
    permittedScene name =
      "Data." `isPrefixOf` name
        || "GHC." `isPrefixOf` name
        || "Control." `isPrefixOf` name
        || "Hetoimasia.LuaEngine.Scene" `isPrefixOf` name
        || name
          `elem` [ "Hetoimasia.LuaEngine.Profile"
                 , "Hetoimasia.LuaEngine.Texture"
                 , "Hetoimasia.Math.Affine2"
                 , "Hetoimasia.Math.Vector"
                 , "Hetoimasia.Render.Api.Texture"
                 , "Hetoimasia.Scripting.Lua.Lease"
                 , "Hetoimasia.Scripting.Lua.Registration"
                 , "Hetoimasia.Scripting.Lua.Value"
                 ]
        || "Hetoimasia.Render.TwoD." `isPrefixOf` name
    permittedSuite name =
      name
        `elem` [ "Hetoimasia.LuaEngine.Manifest"
               , "Hetoimasia.LuaEngine.Behavior"
               , "Hetoimasia.LuaEngine.Boot"
               , "Hetoimasia.LuaEngine.Profile"
               , "Hetoimasia.LuaEngine.Request"
               , "Hetoimasia.LuaEngine.Data"
               , "Hetoimasia.LuaEngine.Texture"
               , "Hetoimasia.LuaEngine.Scene"
               , "Hetoimasia.Asset.Image"
               , "Hetoimasia.Math.Affine2"
               , "Hetoimasia.Math.Vector"
               , "Hetoimasia.Render.Api.Texture"
               , "Hetoimasia.Render.Api.Texture.Backend"
               , "Hetoimasia.Content.ReadPool"
               , "Hetoimasia.Foundation.Time"
               , "Hetoimasia.Foundation.Log"
               , "Hetoimasia.Foundation.Resource"
               , "Hetoimasia.Runtime.Logging"
               , "Hetoimasia.Runtime.Supervision"
               , "Hetoimasia.Content"
               , "Hetoimasia.Content.Identity"
               , "Hetoimasia.Content.Inventory"
               ]
        || "Hetoimasia.Scripting.Lua." `isPrefixOf` name
        || "Hetoimasia.Render.TwoD." `isPrefixOf` name
