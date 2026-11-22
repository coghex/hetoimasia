{-# LANGUAGE MultiWayIf #-}

-- | Hspec coverage for the import guard of the ownership transactions' issuer bridge (#721; the design's "Guard
-- mechanism", supported subset).
--
-- @owner-tx-guard@ takes its facts from Cabal (components, their configurations on Linux and Darwin on x86_64 and
-- aarch64 under every manual flag, sources, dependencies) and GHC (each source's imports per target, each checked
-- module's typed interface per combination of dependency variants) and compares them with
-- @tools/validation/owner_tx_issuers.json@. Every example runs the production guard against a temporary tree of valid
-- minimal packages: a Foundation of the real one's shape (the representation, the cells, the listed adapter of
-- STM-free operations, the issuer sublibrary, the public module and a test suite with the composition), a consumer
-- whose listed adapter exports a concrete slot reservation, a dependency with a manual flag, and a package only
-- @cabal.project.vulkan@ lists. Each negative example asserts the guard's own diagnostic, so an incidental compiler
-- error cannot satisfy it.
--
-- The last group runs the guard on this repository: it passes, it reads only what its catalog group lists as inputs, and
-- the planner selects that group for a change to a Vulkan-only package's source, to a package description and to the
-- allowlist.
module OwnerTxGuard (spec) where

import Control.Exception (finally)
import Control.Monad (forM_, void)
import Data.List (intercalate, isInfixOf, isPrefixOf)
import Json (Json (..), asArray, asString, entryFor, field, parseJson)
import Sandbox (git, run, sanitizedEnvironment, writeFixtureFile)
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist, getCurrentDirectory, getPermissions, setOwnerExecutable, setOwnerWritable, setPermissions)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, expectationFailure, it, pendingWith, shouldBe, shouldContain, shouldSatisfy)

-- ---------------------------------------------------------------------------
-- The fixture tree

cabalHeader ∷ String → [String]
cabalHeader name = ["cabal-version: 3.4", "name: " <> name, "version: 0.1.0.0", "build-type: Simple", ""]

-- The common fields of every fixture component.
common ∷ [String]
common = ["    default-language: GHC2024", "    default-extensions: UnicodeSyntax"]

foundationDescription ∷ String
foundationDescription =
  unlines $
    cabalHeader "hetoimasia-foundation"
      <> ["library", "    exposed-modules: Hetoimasia.Foundation.OwnerTx", "    hs-source-dirs: src"]
      <> common
      <> ["    build-depends: base, stm, hetoimasia-foundation:internal", ""]
      <> ["library internal", "    visibility: private", "    exposed-modules: Hetoimasia.Foundation.OwnerTx.Representation, Hetoimasia.Foundation.OwnerTx.Cells, Hetoimasia.Foundation.OwnerTx.Operations", "    hs-source-dirs: internal"]
      <> common
      <> ["    build-depends: base, stm", ""]
      <> ["library owner-tx-issuer", "    visibility: public", "    exposed-modules: Hetoimasia.Foundation.OwnerTx.Issuer", "    hs-source-dirs: owner-tx-issuer"]
      <> common
      <> ["    build-depends: base, stm, hetoimasia-foundation:internal", ""]
      <> ["test-suite foundation-tests", "    type: exitcode-stdio-1.0", "    main-is: Main.hs", "    hs-source-dirs: test", "    other-modules: Composition, Sibling"]
      <> common
      <> ["    build-depends: base, stm, hetoimasia-foundation, hetoimasia-foundation:owner-tx-issuer"]

-- | A consumer the root project lists: the listed adapter, a plain module, what an example adds, and its fields.
consumerDescription ∷ [String] → [String] → String
consumerDescription modules extra =
  unlines $
    cabalHeader "consumer"
      <> ["library", "    exposed-modules: " <> intercalate ", " (["Consumer.Adapter", "Consumer.Plain"] <> modules), "    hs-source-dirs: src"]
      <> common
      <> ["    build-depends: base, stm, hetoimasia-foundation, hetoimasia-foundation:internal, hetoimasia-foundation:owner-tx-issuer"]
      <> extra

vulkanDescription ∷ [String] → String
vulkanDescription extra =
  unlines $
    cabalHeader "vulkanpkg"
      <> ["library", "    exposed-modules: Vulkan.Native", "    hs-source-dirs: src"]
      <> common
      <> ["    build-depends: base, hetoimasia-foundation" <> concatMap (", " <>) extra]

haskell ∷ String → [String] → [String] → String
haskell header imports body = unlines ([header, ""] <> imports <> [""] <> body)

-- | The listed adapter: a concrete slot reservation, the bridge used inside it and exported nowhere.
adapter ∷ String → [String] → String
adapter header extra =
  haskell
    header
    ["import Control.Concurrent.STM (TVar, readTVar, writeTVar)", "import Hetoimasia.Foundation.OwnerTx (OwnerTx)", "import qualified Hetoimasia.Foundation.OwnerTx.Issuer as Bridge"]
    ( [ "reserveSlot ∷ TVar Int → OwnerTx (Either String ())"
      , "reserveSlot free = Bridge.fromIssuerSTM (readTVar free >>= \\n → if n <= 0 then pure (Left \"full\") else Right () <$ writeTVar free (n - 1))"
      ]
        <> extra
    )

withImport ∷ String → String → String
withImport source line = unlines (case lines source of header : rest → header : line : rest; [] → [line])

passingAdapter ∷ String
passingAdapter = adapter "module Consumer.Adapter (reserveSlot) where" []

export' ∷ String → String → String → String → String → String
export' component module' symbol kind ty =
  "{\"component\": " <> show component <> ", \"module\": " <> show module' <> ", \"symbol\": " <> show symbol <> ", \"kind\": " <> show kind <> ", \"type\": " <> show ty <> "}"

internalLib, issuerLib, foundationTests, consumerLib ∷ String
internalLib = "hetoimasia-foundation:lib:internal"
issuerLib = "hetoimasia-foundation:lib:owner-tx-issuer"
foundationTests = "hetoimasia-foundation:test:foundation-tests"
consumerLib = "consumer:lib:consumer"

adapterExport ∷ String → String → String → String
adapterExport = export' consumerLib "Consumer.Adapter"

-- | The reviewed contract of the passing tree.
baseExports ∷ [String]
baseExports =
  [ export' internalLib "Hetoimasia.Foundation.OwnerTx.Operations" "OwnerTx" "type" ""
  , export' internalLib "Hetoimasia.Foundation.OwnerTx.Operations" "commit" "value" "forall a. OwnerTx a -> IO a"
  , export' internalLib "Hetoimasia.Foundation.OwnerTx.Operations" "readTx" "value" "forall a. ReadOnly a -> OwnerTx a"
  , export' internalLib "Hetoimasia.Foundation.OwnerTx.Representation" "OwnerTx" "type" ""
  , export' internalLib "Hetoimasia.Foundation.OwnerTx.Representation" "OwnerTx" "constructor" "forall a. STM a %1 -> OwnerTx a"
  , export' issuerLib "Hetoimasia.Foundation.OwnerTx.Issuer" "fromIssuerSTM" "value" "forall a. STM a -> OwnerTx a"
  , export' foundationTests "Composition" "holdOne" "value" "TVar Int -> OwnerTx Bool"
  , adapterExport "reserveSlot" "value" "TVar Int -> OwnerTx (Either [Char] ())"
  ]

baseImporters ∷ [(String, String)]
baseImporters =
  [ (internalLib, "Hetoimasia.Foundation.OwnerTx.Operations")
  , (issuerLib, "Hetoimasia.Foundation.OwnerTx.Issuer")
  , (foundationTests, "Composition")
  , (consumerLib, "Consumer.Adapter")
  ]

baseDependents ∷ [String]
baseDependents = [foundationTests, consumerLib]

allowlist ∷ [(String, String)] → [String] → [String] → String
allowlist importers dependents exports =
  unlines
    [ "{"
    , "  \"schema_version\": 2,"
    , "  \"importers\": [" <> intercalate ", " [entry component module' | (component, module') ← importers] <> "],"
    , "  \"dependents\": [" <> intercalate ", " ["{\"component\": " <> show component <> ", \"reason\": \"a fixture\"}" | component ← dependents] <> "],"
    , "  \"exports\": [" <> intercalate ", " exports <> "]"
    , "}"
    ]
  where
    entry component module' = "{\"component\": " <> show component <> ", \"module\": " <> show module' <> ", \"reason\": \"a fixture\"}"

baseTree ∷ [(FilePath, String)]
baseTree =
  [ ("cabal.project", "packages:\n  foundation\n  consumer\n")
  , ("cabal.project.vulkan", "packages:\n  foundation\n  consumer\n  vulkanpkg\n")
  , ("foundation/hetoimasia-foundation.cabal", foundationDescription)
  , ("foundation/internal/Hetoimasia/Foundation/OwnerTx/Representation.hs", haskell "module Hetoimasia.Foundation.OwnerTx.Representation (OwnerTx (..)) where" ["import Control.Concurrent.STM (STM)"] ["newtype OwnerTx a = OwnerTx (STM a)"])
  , ("foundation/internal/Hetoimasia/Foundation/OwnerTx/Cells.hs", haskell "module Hetoimasia.Foundation.OwnerTx.Cells (ReadOnly (..), watch) where" ["import Control.Concurrent.STM (STM, TVar, readTVar)"] ["newtype ReadOnly a = ReadOnly (TVar a)", "watch ∷ ReadOnly a → STM a", "watch (ReadOnly cell) = readTVar cell"])
  , ( "foundation/internal/Hetoimasia/Foundation/OwnerTx/Operations.hs"
    , haskell
        "module Hetoimasia.Foundation.OwnerTx.Operations (OwnerTx, commit, readTx) where"
        ["import Control.Concurrent.STM (atomically, readTVar)", "import Hetoimasia.Foundation.OwnerTx.Cells (ReadOnly (..))", "import Hetoimasia.Foundation.OwnerTx.Representation (OwnerTx (..))"]
        ["commit ∷ OwnerTx a → IO a", "commit (OwnerTx t) = atomically t", "readTx ∷ ReadOnly a → OwnerTx a", "readTx (ReadOnly cell) = OwnerTx (readTVar cell)"]
    )
  , ("foundation/src/Hetoimasia/Foundation/OwnerTx.hs", haskell "module Hetoimasia.Foundation.OwnerTx (OwnerTx, ReadOnly, commit, readTx, watch) where" ["import Hetoimasia.Foundation.OwnerTx.Cells (ReadOnly, watch)", "import Hetoimasia.Foundation.OwnerTx.Operations (OwnerTx, commit, readTx)"] [])
  , ("foundation/owner-tx-issuer/Hetoimasia/Foundation/OwnerTx/Issuer.hs", haskell "module Hetoimasia.Foundation.OwnerTx.Issuer (fromIssuerSTM) where" ["import Control.Concurrent.STM (STM)", "import Hetoimasia.Foundation.OwnerTx.Representation (OwnerTx (..))"] ["fromIssuerSTM ∷ STM a → OwnerTx a", "fromIssuerSTM = OwnerTx"])
  , ("foundation/test/Main.hs", haskell "module Main (main) where" ["import Composition ()", "import Sibling ()"] ["main ∷ IO ()", "main = pure ()"])
  , ("foundation/test/Composition.hs", haskell "module Composition (holdOne) where" ["import Control.Concurrent.STM (TVar, readTVar, writeTVar)", "import Hetoimasia.Foundation.OwnerTx (OwnerTx)", "import Hetoimasia.Foundation.OwnerTx.Issuer (fromIssuerSTM)"] ["holdOne ∷ TVar Int → OwnerTx Bool", "holdOne free = fromIssuerSTM (readTVar free >>= \\n → if n <= 0 then pure False else True <$ writeTVar free (n - 1))"])
  , ("foundation/test/Sibling.hs", haskell "module Sibling () where" ["import Hetoimasia.Foundation.OwnerTx (OwnerTx)"] [])
  , ("consumer/consumer.cabal", consumerDescription [] [])
  , ("consumer/src/Consumer/Adapter.hs", passingAdapter)
  , ("consumer/src/Consumer/Plain.hs", haskell "module Consumer.Plain () where" ["import Hetoimasia.Foundation.OwnerTx (OwnerTx)"] [])
  , ("vulkanpkg/vulkanpkg.cabal", vulkanDescription [])
  , ("vulkanpkg/src/Vulkan/Native.hs", haskell "module Vulkan.Native () where" ["import Hetoimasia.Foundation.OwnerTx (OwnerTx)"] [])
  , ("tools/validation/owner_tx_issuers.json", allowlist baseImporters baseDependents baseExports)
  ]

changed ∷ [(FilePath, String)] → [(FilePath, String)]
changed updates = [entry | entry@(path, _) ← baseTree, path `notElem` map fst updates] <> updates

-- | The adapter with these exports and lines, its contract listing these extra entries.
adapterWith ∷ String → [String] → [String] → [(FilePath, String)]
adapterWith header extra contract =
  changed
    [ ("consumer/src/Consumer/Adapter.hs", adapter header extra `withImport` "import Control.Concurrent.STM (STM, retry)")
    , ("tools/validation/owner_tx_issuers.json", allowlist baseImporters baseDependents (baseExports <> contract))
    ]

-- | A description with one more dependency on its library's build-depends line.
withDependency ∷ String → String → String
withDependency description dependency =
  unlines [if "    build-depends: base, stm, hetoimasia-foundation," `isPrefixOf` line then line <> ", " <> dependency else line | line ← lines description]

-- | The tree with one more import in one of its sources.
addImport ∷ [(FilePath, String)] → (FilePath, String) → [(FilePath, String)]
addImport files (target, line) = [(path, if path == target then source `withImport` line else source) | (path, source) ← files]

-- ---------------------------------------------------------------------------
-- Running the guard

guardedWith ∷ ([(String, String)] → [(String, String)]) → [String] → [(FilePath, String)] → IO (ExitCode, String)
guardedWith adjust arguments files = withSystemTempDirectory "hetoimasia-owner-tx-guard" $ \directory → do
  forM_ files (uncurry (writeFixtureFile directory))
  settings ← adjust <$> sanitizedEnvironment
  (result, _, errors) ← run settings directory "owner-tx-guard" (arguments <> ["--root", directory])
  pure (result, errors)

checked ∷ [(FilePath, String)] → IO (ExitCode, String)
checked = guardedWith id ["check"]

-- | The guard refused the tree with its policy diagnostic, saying all of these.
refused ∷ [(FilePath, String)] → [String] → IO ()
refused files said = do
  (result, errors) ← checked files
  (result, errors) `shouldSatisfy` ((== ExitFailure 1) . fst)
  forM_ said (errors `shouldContain`)

spec ∷ Spec
spec = describe "The issuer bridge's import guard (tools/owner-tx-guard)" $ do
  describe "a fixture tree" $ do
    it "accepts the listed importers, dependents and export contracts, with a concrete slot reservation as the adapter" $
      checked baseTree >>= (`shouldBe` (ExitSuccess, ""))

    it "refuses an unlisted sibling module in a component listed for the bridge" $
      refused
        (changed [("foundation/test/Sibling.hs", haskell "module Sibling () where" ["import Hetoimasia.Foundation.OwnerTx.Issuer ()"] [])])
        ["foundation/test/Sibling.hs: Sibling in hetoimasia-foundation:test:foundation-tests", "imports Hetoimasia.Foundation.OwnerTx.Issuer and is not listed as an importer"]

    it "reads every supported import form as GHC does, explicit braces and a CPP-made module name included" $
      forM_
        [ haskell "module Consumer.Plain () where" ["import Hetoimasia.Foundation.OwnerTx.Issuer ()"] []
        , haskell "module Consumer.Plain () where" ["import qualified Hetoimasia.Foundation.OwnerTx.Issuer as Bridge ()"] []
        , haskell "module Consumer.Plain () where" ["import Hetoimasia.Foundation.OwnerTx.Issuer qualified as Bridge ()"] []
        , haskell "module Consumer.Plain () where" ["import Hetoimasia.Foundation.OwnerTx.Issuer hiding (fromIssuerSTM)"] []
        , haskell "module Consumer.Plain () where" ["import \"hetoimasia-foundation\" Hetoimasia.Foundation.OwnerTx.Issuer ()"] []
        , haskell "module Consumer.Plain () where" ["import safe Hetoimasia.Foundation.OwnerTx.Issuer ()"] []
        , "module Consumer.Plain () where { import Data.Maybe (); import Hetoimasia.Foundation.OwnerTx.Issuer () }\n"
        , unlines ["{-# LANGUAGE CPP #-}", "#define BRIDGE Hetoimasia.Foundation.OwnerTx.Issuer", "module Consumer.Plain () where", "import BRIDGE ()"]
        ]
        $ \source →
          refused (changed [("consumer/src/Consumer/Plain.hs", source)]) ["Consumer.Plain in consumer:lib:consumer", "imports Hetoimasia.Foundation.OwnerTx.Issuer and is not listed as an importer"]

    it "reads a protected import visible only on the other target, whatever the host" $
      forM_ [("darwin_HOST_OS", "darwin/", "linux/"), ("linux_HOST_OS", "linux/", "darwin/")] $ \(macro, visible, hidden) → do
        (result, errors) ←
          checked (changed [("consumer/src/Consumer/Plain.hs", unlines ["{-# LANGUAGE CPP #-}", "module Consumer.Plain () where", "#if defined(" <> macro <> ")", "import Hetoimasia.Foundation.OwnerTx.Issuer ()", "#endif"])])
        result `shouldBe` ExitFailure 1
        errors `shouldContain` ("Consumer.Plain in consumer:lib:consumer (" <> visible)
        errors `shouldContain` "imports Hetoimasia.Foundation.OwnerTx.Issuer and is not listed as an importer"
        filter (("Consumer.Plain in consumer:lib:consumer (" <> hidden) `isInfixOf`) (lines errors) `shouldBe` []

    it "refuses CPP outside the subset, a SOURCE import and a boot file" $ do
      refused
        (changed [("consumer/src/Consumer/Plain.hs", unlines ["{-# LANGUAGE CPP #-}", "module Consumer.Plain () where", "#include \"bridge.h\""]), ("consumer/src/Consumer/bridge.h", "import Hetoimasia.Foundation.OwnerTx.Issuer ()\n")])
        ["unsupported: the CPP directive #include \"bridge.h\""]
      refused (changed [("consumer/src/Consumer/Plain.hs", haskell "module Consumer.Plain () where" ["import {-# SOURCE #-} Hetoimasia.Foundation.OwnerTx.Issuer ()"] [])]) ["unsupported: a {-# SOURCE #-} import of Hetoimasia.Foundation.OwnerTx.Issuer"]
      refused
        (changed [("consumer/src/Consumer/Plain.hs-boot", haskell "module Consumer.Plain where" ["import Hetoimasia.Foundation.OwnerTx.Issuer ()"] [])])
        ["unsupported: the boot file consumer/src/Consumer/Plain.hs-boot beside Consumer.Plain"]

    it "refuses an unlisted import of the bridge-equivalent representation, from Foundation's own test suite too" $
      refused
        (changed [("foundation/test/Sibling.hs", haskell "module Sibling () where" ["import Hetoimasia.Foundation.OwnerTx.Representation ()"] [])])
        ["Sibling in hetoimasia-foundation:test:foundation-tests", "imports Hetoimasia.Foundation.OwnerTx.Representation and is not listed as an importer"]

    it "refuses an unlisted dependency on the issuer sublibrary and an unlisted import in a package only the Vulkan project lists" $
      refused
        ( changed
            [ ("vulkanpkg/vulkanpkg.cabal", vulkanDescription ["hetoimasia-foundation:owner-tx-issuer"])
            , ("vulkanpkg/src/Vulkan/Native.hs", haskell "module Vulkan.Native () where" ["import Hetoimasia.Foundation.OwnerTx.Issuer ()"] [])
            ]
        )
        ["vulkanpkg:lib:vulkanpkg", "depends on hetoimasia-foundation:owner-tx-issuer and is not a listed dependent", "Vulkan.Native in vulkanpkg:lib:vulkanpkg"]

    it "reads the dependency's library apart from its version range, in the compact spelling" $
      refused (changed [("vulkanpkg/vulkanpkg.cabal", vulkanDescription ["hetoimasia-foundation:owner-tx-issuer>=0.1"])]) ["vulkanpkg:lib:vulkanpkg", "depends on hetoimasia-foundation:owner-tx-issuer and is not a listed dependent"]

    it "reads a dependency inherited through nested common stanzas, and a foreign library's" $ do
      refused
        ( changed
            [ ( "vulkanpkg/vulkanpkg.cabal"
              , unlines $
                  cabalHeader "vulkanpkg"
                    <> ["common inner", "    build-depends: hetoimasia-foundation:owner-tx-issuer", "", "common outer", "    import: inner", ""]
                    <> ["library", "    import: outer", "    exposed-modules: Vulkan.Native", "    hs-source-dirs: src"]
                    <> common
                    <> ["    build-depends: base, hetoimasia-foundation"]
              )
            ]
        )
        ["vulkanpkg:lib:vulkanpkg", "depends on hetoimasia-foundation:owner-tx-issuer and is not a listed dependent"]
      refused
        ( changed
            [ ("vulkanpkg/vulkanpkg.cabal", vulkanDescription [] <> unlines (["", "foreign-library native", "    type: native-shared", "    other-modules: Vulkan.Foreign", "    hs-source-dirs: src"] <> common <> ["    build-depends: base, hetoimasia-foundation:owner-tx-issuer"]))
            , ("vulkanpkg/src/Vulkan/Foreign.hs", haskell "module Vulkan.Foreign () where" [] [])
            ]
        )
        ["vulkanpkg:flib:native", "depends on hetoimasia-foundation:owner-tx-issuer and is not a listed dependent"]

    it "reads both branches of a manual flag: two files providing one module, only the second importing the bridge" $
      refused
        ( changed
            [ ( "consumer/consumer.cabal"
              , unlines $
                  cabalHeader "consumer"
                    <> ["flag full", "    default: True", "    manual: True", ""]
                    <> ["library", "    exposed-modules: Consumer.Adapter, Consumer.Plain, Consumer.Variant", "    hs-source-dirs: src"]
                    <> common
                    <> ["    build-depends: base, stm, hetoimasia-foundation, hetoimasia-foundation:internal, hetoimasia-foundation:owner-tx-issuer", "    if flag(full)", "        hs-source-dirs: full", "    else", "        hs-source-dirs: lean"]
              )
            , ("consumer/full/Consumer/Variant.hs", haskell "module Consumer.Variant () where" [] [])
            , ("consumer/lean/Consumer/Variant.hs", haskell "module Consumer.Variant () where" ["import Hetoimasia.Foundation.OwnerTx.Issuer ()"] [])
            ]
        )
        ["consumer/lean/Consumer/Variant.hs: Consumer.Variant in consumer:lib:consumer", "-full", "imports Hetoimasia.Foundation.OwnerTx.Issuer and is not listed as an importer"]

    it "typechecks every variant of a local dependency with its own flags: a dependency's flag that puts STM in the adapter's inferred export is refused" $
      refused
        ( changed
            [ ("cabal.project", "packages:\n  foundation\n  consumer\n  dep\n")
            , ("cabal.project.vulkan", "packages:\n  foundation\n  consumer\n  dep\n  vulkanpkg\n")
            , ( "dep/dep.cabal"
              , unlines $
                  cabalHeader "dep"
                    <> ["flag full", "    default: False", "    manual: True", ""]
                    <> ["library", "    exposed-modules: Dep", "    hs-source-dirs: src"]
                    <> common
                    <> ["    build-depends: base, stm", "    if flag(full)", "        cpp-options: -DFULL"]
              )
            , ("dep/src/Dep.hs", unlines ["{-# LANGUAGE CPP #-}", "module Dep (payload) where", "import Control.Concurrent.STM (STM)", "#if defined(FULL)", "payload ∷ Maybe (STM Int)", "#else", "payload ∷ Maybe Int", "#endif", "payload = Nothing"])
            , ("consumer/consumer.cabal", consumerDescription [] [] `withDependency` "dep")
            , ("consumer/src/Consumer/Adapter.hs", adapter "module Consumer.Adapter (reserveSlot, fromDep) where" ["fromDep = Dep.payload"] `withImport` "import qualified Dep")
            , ("tools/validation/owner_tx_issuers.json", allowlist baseImporters baseDependents (baseExports <> [adapterExport "fromDep" "value" "Maybe Int"]))
            ]
        )
        ["Consumer.Adapter in consumer:lib:consumer", "with dep:lib:dep", "+full", "exports fromDep (value ∷ Maybe (STM Int)), whose type contains STM"]

    it "refuses an export listed in the contract that mentions STM under Maybe or IO, or inside a consumer's own type named like a boundary type, and accepts the genuine boundary handle" $ do
      (result, errors) ←
        checked
          ( adapterWith
              "module Consumer.Adapter (reserveSlot, nested, inIO, own, genuine) where"
              [ "newtype ReadOnly a = ReadOnly (STM a)"
              , "nested ∷ Maybe (STM Int → OwnerTx Int)"
              , "nested = Just Bridge.fromIssuerSTM"
              , "inIO ∷ IO (STM Int)"
              , "inIO = pure (pure 1)"
              , "own ∷ ReadOnly Int"
              , "own = ReadOnly (pure 1)"
              , "genuine ∷ Foundation.ReadOnly Int"
              , "genuine = undefined"
              ]
              [ adapterExport "nested" "value" "Maybe (STM Int -> OwnerTx Int)"
              , adapterExport "inIO" "value" "IO (STM Int)"
              , adapterExport "own" "value" "ReadOnly Int"
              , adapterExport "genuine" "value" "ReadOnly Int"
              ]
              `addImport` ("consumer/src/Consumer/Adapter.hs", "import qualified Hetoimasia.Foundation.OwnerTx as Foundation")
          )
      result `shouldBe` ExitFailure 1
      forM_ ["exports nested (value ∷ Maybe (STM Int -> OwnerTx Int)), whose type contains STM", "exports inIO (value ∷ IO (STM Int)), whose type contains STM", "exports own (value ∷ ReadOnly Int), whose type contains STM"] (errors `shouldContain`)
      filter ("exports genuine" `isInfixOf`) (lines errors) `shouldBe` []

    it "refuses an inferred, synonymous, callback, nested, newtype-wrapped or converse wrapper of the embedding under a new name" $
      forM_
        [ ("lift", ["lift = Bridge.fromIssuerSTM"])
        , ("embed", ["type Embedding a = STM a → OwnerTx a", "embed ∷ Embedding a", "embed = Bridge.fromIssuerSTM"])
        , ("fromCallback", ["fromCallback ∷ (Int → STM b) → OwnerTx b", "fromCallback k = Bridge.fromIssuerSTM (k 0)"])
        , ("fromPair", ["fromPair ∷ (STM a, Int) → OwnerTx a", "fromPair (t, _) = Bridge.fromIssuerSTM t"])
        , ("fromWrap", ["newtype Wrap a = Wrap (STM a)", "fromWrap ∷ Wrap a → OwnerTx a", "fromWrap (Wrap t) = Bridge.fromIssuerSTM t"])
        , ("toSTM", ["toSTM ∷ OwnerTx a → Maybe (STM a)", "toSTM _ = Nothing"])
        ]
        $ \(name, body) →
          refused (adapterWith ("module Consumer.Adapter (reserveSlot, " <> name <> ") where") body []) ["Consumer.Adapter in consumer:lib:consumer", "exports " <> name <> " (value ∷ ", "), whose type contains STM"]

    it "refuses a listed adapter that re-exports the bridge through an import alias" $
      refused
        (changed [("consumer/src/Consumer/Adapter.hs", adapter "module Consumer.Adapter (reserveSlot, module Bridge) where" [] `withImport` "import Hetoimasia.Foundation.OwnerTx.Issuer as Bridge")])
        ["Consumer.Adapter in consumer:lib:consumer", "exports fromIssuerSTM (value ∷ forall a. STM a -> OwnerTx a), whose type contains STM"]

    it "holds the bridge's own module to its contract: re-exporting the representation's constructor is refused" $
      refused
        (changed [("foundation/owner-tx-issuer/Hetoimasia/Foundation/OwnerTx/Issuer.hs", haskell "module Hetoimasia.Foundation.OwnerTx.Issuer (fromIssuerSTM, OwnerTx (..)) where" ["import Control.Concurrent.STM (STM)", "import Hetoimasia.Foundation.OwnerTx.Representation (OwnerTx (..))"] ["fromIssuerSTM ∷ STM a → OwnerTx a", "fromIssuerSTM = OwnerTx"])])
        ["Hetoimasia.Foundation.OwnerTx.Issuer in hetoimasia-foundation:lib:owner-tx-issuer", "exports OwnerTx (constructor ∷ forall a. STM a %1 -> OwnerTx a), which its export contract does not list"]

    it "refuses an uncontracted instance on a protected type, which a client uses through the public class, though the module exports nothing new" $
      refused
        ( changed
            [ ("consumer/consumer.cabal", consumerDescription ["Consumer.Lift", "Consumer.Client"] [])
            , ("consumer/src/Consumer/Lift.hs", haskell "module Consumer.Lift (Lift (..)) where" ["import Control.Concurrent.STM (STM)"] ["class Lift m where", "  liftSTM ∷ STM a → m a"])
            , ("consumer/src/Consumer/Adapter.hs", adapter "module Consumer.Adapter (reserveSlot) where" ["instance Lift OwnerTx where", "  liftSTM = Bridge.fromIssuerSTM"] `withImport` "import Consumer.Lift (Lift (..))")
            , ("consumer/src/Consumer/Client.hs", haskell "module Consumer.Client (lifted) where" ["import Consumer.Adapter ()", "import Consumer.Lift (Lift (..))", "import Hetoimasia.Foundation.OwnerTx (OwnerTx)"] ["lifted ∷ OwnerTx Int", "lifted = liftSTM (pure 1)"])
            ]
        )
        ["Consumer.Adapter in consumer:lib:consumer", "defines the instance Lift OwnerTx on a protected type, which its contract does not list", "defines the instance Lift OwnerTx, whose method liftSTM lifts STM"]

    it "checks an entry point by its resolved source: of two files declaring Main in one directory, only the selected non-default one leaks" $
      refused
        ( changed
            [ ( "consumer/consumer.cabal"
              , consumerDescription [] $
                  ["", "test-suite roots", "    type: exitcode-stdio-1.0", "    main-is: RootsMain.hs", "    hs-source-dirs: test"]
                    <> common
                    <> ["    build-depends: base, stm, hetoimasia-foundation, hetoimasia-foundation:owner-tx-issuer", ""]
                    <> ["test-suite plain", "    type: exitcode-stdio-1.0", "    main-is: Main.hs", "    hs-source-dirs: test"]
                    <> common
                    <> ["    build-depends: base"]
              )
            , ("consumer/test/RootsMain.hs", haskell "module Main (main, lift) where" ["import Hetoimasia.Foundation.OwnerTx.Issuer (fromIssuerSTM)"] ["main ∷ IO ()", "main = pure ()", "lift = fromIssuerSTM"])
            , ("consumer/test/Main.hs", haskell "module Main (main) where" [] ["main ∷ IO ()", "main = pure ()"])
            , ("tools/validation/owner_tx_issuers.json", allowlist (baseImporters <> [("consumer:test:roots", "Main")]) (baseDependents <> ["consumer:test:roots"]) (baseExports <> [export' "consumer:test:roots" "Main" "main" "value" "IO ()"]))
            ]
        )
        ["Main in consumer:test:roots", "exports lift (value ∷ forall {a}. STM a -> OwnerTx a), whose type contains STM"]

    it "refuses an export its contract does not list, and a contract entry no longer exported" $ do
      refused (changed [("consumer/src/Consumer/Adapter.hs", adapter "module Consumer.Adapter (reserveSlot, slots) where" ["slots ∷ Int", "slots = 4"])]) ["Consumer.Adapter in consumer:lib:consumer", "exports slots (value ∷ Int), which its export contract does not list"]
      refused (changed [("tools/validation/owner_tx_issuers.json", allowlist baseImporters baseDependents (baseExports <> [adapterExport "releaseSlot" "value" "TVar Int -> OwnerTx ()"]))]) ["no longer exports releaseSlot", "a stale entry"]

    it "refuses a re-export through Cabal: reexported-modules, and a mixin naming the bridge" $ do
      refused (changed [("consumer/consumer.cabal", consumerDescription [] ["    reexported-modules: Hetoimasia.Foundation.OwnerTx.Issuer as Consumer.Bridge"])]) ["re-exports Hetoimasia.Foundation.OwnerTx.Issuer as Consumer.Bridge through reexported-modules"]
      refused (changed [("consumer/consumer.cabal", consumerDescription [] ["    mixins: hetoimasia-foundation:owner-tx-issuer (Hetoimasia.Foundation.OwnerTx.Issuer as Consumer.Bridge)"])]) ["names the issuer bridge in a mixin"]

    it "refuses a stale entry: a listed importer that imports nothing protected, and a listed dependent that depends on nothing" $
      refused
        (changed [("tools/validation/owner_tx_issuers.json", allowlist (baseImporters <> [(consumerLib, "Consumer.Plain")]) (baseDependents <> ["consumer:lib:gone"]) baseExports)])
        ["the listed importer Consumer.Plain of consumer:lib:consumer imports no protected module in any configuration: a stale entry", "the listed dependent consumer:lib:gone depends on no hetoimasia-foundation:owner-tx-issuer in any configuration: a stale entry"]

    it "refuses project and manifest forms outside the subset: optional packages, an unsupported target condition, signatures" $ do
      refused
        (changed [("cabal.project", "packages:\n  foundation\n  consumer\noptional-packages: extra\n"), ("extra/extra.cabal", unlines (cabalHeader "extra" <> ["library", "    exposed-modules: Extra", "    hs-source-dirs: src"] <> common <> ["    build-depends: base"])), ("extra/src/Extra.hs", "module Extra () where\n")])
        ["unsupported: optional-packages in cabal.project"]
      refused (changed [("vulkanpkg/vulkanpkg.cabal", vulkanDescription [] <> "    if os(freebsd)\n        build-depends: hetoimasia-foundation:owner-tx-issuer\n")]) ["unsupported: condition os(freebsd)"]
      refused (changed [("consumer/consumer.cabal", consumerDescription [] ["    signatures: Consumer.Signature"])]) ["unsupported: signatures Consumer.Signature"]

    it "fails closed on what it cannot read: a module without a source, a source of another kind, a description Cabal refuses, a missing allowlist" $ do
      refused (changed [("consumer/consumer.cabal", consumerDescription ["Consumer.Missing"] [])]) ["uncovered: the module Consumer.Missing has no source in its source directories"]
      refused (changed [("consumer/consumer.cabal", consumerDescription ["Consumer.Generated"] []), ("consumer/src/Consumer/Generated.hsc", "module Consumer.Generated () where\n")]) ["unsupported: the module Consumer.Generated is a .hsc source"]
      (malformed, malformedSaid) ← checked (changed [("consumer/consumer.cabal", "cabal-version: 3.4\nname: consumer\nlibrary\n  exposed-modules: {\n")])
      malformed `shouldBe` ExitFailure 2
      malformedSaid `shouldContain` "consumer/consumer.cabal: Cabal refused it"
      (missing, missingSaid) ← checked [entry | entry@(path, _) ← baseTree, path /= "tools/validation/owner_tx_issuers.json"]
      missing `shouldBe` ExitFailure 2
      missingSaid `shouldContain` "tools/validation/owner_tx_issuers.json cannot be read"

    it "finds the store without writing into a read-only checkout, and keeps a failed lookup's own diagnostic" $ do
      withSystemTempDirectory "hetoimasia-owner-tx-readonly" $ \directory → do
        forM_ baseTree (uncurry (writeFixtureFile directory))
        settings ← sanitizedEnvironment
        before ← getPermissions directory
        setPermissions directory (setOwnerWritable False before)
        (result, _, errors) ← run settings directory "owner-tx-guard" ["check", "--root", directory] `finally` setPermissions directory before
        (result, errors) `shouldBe` (ExitSuccess, "")
      withSystemTempDirectory "hetoimasia-owner-tx-fake-cabal" $ \tools → do
        writeFixtureFile tools "cabal" "#!/bin/sh\necho 'the fixture refuses the store lookup' >&2\nexit 3\n"
        permissions ← getPermissions (tools </> "cabal")
        setPermissions (tools </> "cabal") (setOwnerExecutable True permissions)
        (result, errors) ← guardedWith (map (\(name, value) → if name == "PATH" then (name, tools <> ":" <> value) else (name, value))) ["check"] baseTree
        result `shouldBe` ExitFailure 1
        errors `shouldContain` "cabal path --ignore-project --store-dir failed (3): the fixture refuses the store lookup"

  describe "this repository" $ do
    it "passes the guard" $ inCheckout $ \checkout → do
      settings ← sanitizedEnvironment
      (result, _, errors) ← run settings checkout "owner-tx-guard" ["check", "--root", checkout]
      (result, errors) `shouldBe` (ExitSuccess, "")

    it "reads only what its catalog group lists as inputs, so a change anywhere it reads selects it" $ inCheckout $ \checkout → do
      settings ← sanitizedEnvironment
      (result, scope, errors) ← run settings checkout "owner-tx-guard" ["scope", "--root", checkout]
      (result, errors) `shouldBe` (ExitSuccess, "")
      catalog ← readFile (checkout </> "tools/validation/catalog.json")
      let inputs = do
            document ← parseJson catalog
            entry ← field "groups" document >>= entryFor "id" "test.owner-tx-guard"
            elements ← field "inputs" entry >>= asArray
            traverse asString elements
          covered path = case inputs of
            Just entries → any (matches path) entries
            Nothing → False
          matches path entry
            | not (null entry) && last entry == '/' = path == init entry || entry `isPrefixOf` path
            | otherwise = path == entry
          missing =
            [ path
            | line ← lines scope
            , let path = drop 1 (dropWhile (/= ' ') line)
            , not (null path)
            , not (covered path || covered (path <> "/"))
            ]
      inputs `shouldSatisfy` (/= Nothing)
      missing `shouldBe` []

    it "selects its group for a change to a Vulkan-only package's source, to a package description and to the allowlist" $ inCheckout $ \checkout → do
      settings ← sanitizedEnvironment
      files ← lines <$> git settings checkout ["-c", "safe.directory=*", "ls-files", "*.cabal", "cabal.project*", "tools/validation/catalog.json"]
      let changedPaths =
            [ "packages/gpu-vulkan/native/src/Hetoimasia/GPU/Vulkan/Native/Uploads.hs"
            , "packages/foundation/hetoimasia-foundation.cabal"
            , "tools/validation/owner_tx_issuers.json"
            ]
      forM_ changedPaths $ \path →
        withSystemTempDirectory "hetoimasia-owner-tx-plan" $ \directory → do
          forM_ [file | file ← files, not ("docs/" `isPrefixOf` file)] $ \file → do
            createDirectoryIfMissing True (directory </> takeDirectory file)
            copyFile (checkout </> file) (directory </> file)
          present ← doesFileExist (directory </> path)
          if present then pure () else writeFixtureFile directory path "-- before\n"
          void $ git settings directory ["init", "-q", "-b", "master"]
          void $ git settings directory ["add", "-A", "."]
          void $ git settings directory ["commit", "-q", "-m", "base"]
          base ← takeWhile (/= '\n') <$> git settings directory ["rev-parse", "HEAD"]
          appendFile (directory </> path) "-- after\n"
          void $ git settings directory ["commit", "-q", "-a", "-m", "head"]
          (result, output, errors) ← run settings checkout "python3" [checkout </> "tools/validation/plan.py", "--repo-root", directory, "--base", base, "--head", "HEAD", "--json"]
          (result, errors) `shouldBe` (ExitSuccess, "")
          case parseJson output >>= field "groups" >>= entryFor "id" "test.owner-tx-guard" of
            Nothing → expectationFailure ("the plan for " <> path <> " has no test.owner-tx-guard group")
            Just entry → do
              (field "selected" entry, field "reason" entry) `shouldBe` (Just (JBool True), Just (JString "affected"))
              field "inputs_changed" entry `shouldBe` Just (JBool True)

-- | Run an example against the checkout, or leave it pending where this is not a checkout of the whole repository.
inCheckout ∷ (FilePath → IO ()) → IO ()
inCheckout example = do
  checkout ← getCurrentDirectory
  present ← doesFileExist (checkout </> "cabal.project")
  if present then example checkout else pendingWith "this is not a checkout of the whole repository (no cabal.project)"
