-- | Hspec coverage for the import guard of the ownership transactions' issuer bridge (#721; the design's "Guard
-- mechanism").
--
-- @owner-tx-guard@ takes its facts from Cabal (components, configurations, sources, dependencies) and GHC (each source's
-- imports, each checked module's typed exports) and compares them with @tools/validation/owner_tx_issuers.json@. Every
-- example runs the production guard against a temporary tree of valid minimal packages: a Foundation of the real one's
-- shape (its main library, the private library with the representation, the issuer sublibrary and a test suite with the
-- composition), a consumer whose listed adapter exports a concrete slot reservation, and a package only
-- @cabal.project.vulkan@ lists. Each negative example asserts the guard's own policy diagnostic, so an incidental
-- compiler error cannot satisfy it.
--
-- The last group runs the guard on this repository: it passes, it reads only what its catalog group lists as inputs, and
-- the planner selects that group for a change to a Vulkan-only package's source, to a package description and to the
-- allowlist.
module OwnerTxGuard (spec) where

import Control.Monad (forM_, void)
import Data.List (intercalate, isPrefixOf)
import Json (Json (..), asArray, asString, entryFor, field, parseJson)
import Sandbox (git, run, sanitizedEnvironment, writeFixtureFile)
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist, getCurrentDirectory)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, expectationFailure, it, pendingWith, shouldBe, shouldContain, shouldSatisfy)

-- ---------------------------------------------------------------------------
-- The fixture tree

cabalHeader ∷ String → [String]
cabalHeader name = ["cabal-version: 3.4", "name: " <> name, "version: 0.1.0.0", "build-type: Simple", ""]

foundationDescription ∷ String
foundationDescription =
  unlines $
    cabalHeader "hetoimasia-foundation"
      <> [ "library"
         , "    exposed-modules: Hetoimasia.Foundation.OwnerTx"
         , "    hs-source-dirs: src"
         , "    default-language: GHC2024", "    default-extensions: UnicodeSyntax"
         , "    build-depends: base, stm, hetoimasia-foundation:internal"
         , ""
         , "library internal"
         , "    visibility: private"
         , "    exposed-modules: Hetoimasia.Foundation.OwnerTx.Representation"
         , "    hs-source-dirs: internal"
         , "    default-language: GHC2024", "    default-extensions: UnicodeSyntax"
         , "    build-depends: base, stm"
         , ""
         , "library owner-tx-issuer"
         , "    visibility: public"
         , "    exposed-modules: Hetoimasia.Foundation.OwnerTx.Issuer"
         , "    hs-source-dirs: owner-tx-issuer"
         , "    default-language: GHC2024", "    default-extensions: UnicodeSyntax"
         , "    build-depends: base, stm, hetoimasia-foundation:internal"
         , ""
         , "test-suite foundation-tests"
         , "    type: exitcode-stdio-1.0"
         , "    main-is: Main.hs"
         , "    hs-source-dirs: test"
         , "    other-modules: Composition, Sibling"
         , "    default-language: GHC2024", "    default-extensions: UnicodeSyntax"
         , "    build-depends: base, stm, hetoimasia-foundation, hetoimasia-foundation:owner-tx-issuer"
         ]

-- | A consumer the root project lists: the listed adapter, a plain module, and what an example adds.
consumerDescription ∷ [String] → [String] → String
consumerDescription modules extra =
  unlines $
    cabalHeader "consumer"
      <> [ "library"
         , "    exposed-modules: " <> intercalate ", " (["Consumer.Adapter", "Consumer.Plain"] <> modules)
         , "    hs-source-dirs: src"
         , "    default-language: GHC2024", "    default-extensions: UnicodeSyntax"
         , "    build-depends: base, stm, hetoimasia-foundation, hetoimasia-foundation:owner-tx-issuer"
         ]
      <> extra

vulkanDescription ∷ [String] → String
vulkanDescription extra =
  unlines $
    cabalHeader "vulkanpkg"
      <> [ "library"
         , "    exposed-modules: Vulkan.Native"
         , "    hs-source-dirs: src"
         , "    default-language: GHC2024", "    default-extensions: UnicodeSyntax"
         , "    build-depends: base, hetoimasia-foundation" <> concatMap (", " <>) extra
         ]

haskell ∷ String → [String] → [String] → String
haskell header imports body = unlines ([header, ""] <> imports <> [""] <> body)

-- | The adapter every passing tree has: a concrete slot reservation, the bridge used inside it and exported nowhere.
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

passingAdapter ∷ String
passingAdapter = adapter "module Consumer.Adapter (reserveSlot) where" []

-- | One export contract entry.
export' ∷ String → String → String → String → String → String
export' component module' symbol kind ty =
  "{\"component\": " <> show component <> ", \"module\": " <> show module' <> ", \"symbol\": " <> show symbol <> ", \"kind\": " <> show kind <> ", \"type\": " <> show ty <> "}"

foundationLib, internalLib, issuerLib, foundationTests, consumerLib ∷ String
foundationLib = "hetoimasia-foundation:lib:hetoimasia-foundation"
internalLib = "hetoimasia-foundation:lib:internal"
issuerLib = "hetoimasia-foundation:lib:owner-tx-issuer"
foundationTests = "hetoimasia-foundation:test:foundation-tests"
consumerLib = "consumer:lib:consumer"

-- | The reviewed contract of the passing tree.
baseExports ∷ [String]
baseExports =
  [ export' foundationLib "Hetoimasia.Foundation.OwnerTx" "OwnerTx" "type" ""
  , export' foundationLib "Hetoimasia.Foundation.OwnerTx" "commit" "value" "forall a. OwnerTx a -> IO a"
  , export' internalLib "Hetoimasia.Foundation.OwnerTx.Representation" "OwnerTx" "type" ""
  , export' internalLib "Hetoimasia.Foundation.OwnerTx.Representation" "OwnerTx" "constructor" "forall a. STM a %1 -> OwnerTx a"
  , export' issuerLib "Hetoimasia.Foundation.OwnerTx.Issuer" "fromIssuerSTM" "value" "forall a. STM a -> OwnerTx a"
  , export' foundationTests "Composition" "holdOne" "value" "TVar Int -> OwnerTx Bool"
  , export' consumerLib "Consumer.Adapter" "reserveSlot" "value" "TVar Int -> OwnerTx (Either [Char] ())"
  ]

baseImporters ∷ [(String, String)]
baseImporters =
  [ (foundationLib, "Hetoimasia.Foundation.OwnerTx")
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
  , ("foundation/src/Hetoimasia/Foundation/OwnerTx.hs", haskell "module Hetoimasia.Foundation.OwnerTx (OwnerTx, commit) where" ["import Control.Concurrent.STM (atomically)", "import Hetoimasia.Foundation.OwnerTx.Representation (OwnerTx (..))"] ["commit ∷ OwnerTx a → IO a", "commit (OwnerTx t) = atomically t"])
  , ("foundation/internal/Hetoimasia/Foundation/OwnerTx/Representation.hs", haskell "module Hetoimasia.Foundation.OwnerTx.Representation (OwnerTx (..)) where" ["import Control.Concurrent.STM (STM)"] ["newtype OwnerTx a = OwnerTx (STM a)"])
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

-- ---------------------------------------------------------------------------
-- Running the guard

guarded ∷ [String] → [(FilePath, String)] → IO (ExitCode, String)
guarded arguments files = withSystemTempDirectory "hetoimasia-owner-tx-guard" $ \directory → do
  forM_ files (uncurry (writeFixtureFile directory))
  settings ← sanitizedEnvironment
  (result, _, errors) ← run settings directory "owner-tx-guard" (arguments <> ["--root", directory])
  pure (result, errors)

checked ∷ [(FilePath, String)] → IO (ExitCode, String)
checked = guarded ["check"]

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
      checked baseTree `shouldReturn'` (ExitSuccess, "")

    it "refuses an unlisted sibling module in a component listed for the bridge" $
      refused
        (changed [("foundation/test/Sibling.hs", haskell "module Sibling () where" ["import Hetoimasia.Foundation.OwnerTx.Issuer ()"] [])])
        ["foundation/test/Sibling.hs: Sibling in hetoimasia-foundation:test:foundation-tests", "imports Hetoimasia.Foundation.OwnerTx.Issuer and is not listed as an importer"]

    it "reads every import form as GHC does, explicit braces and a CPP-made module name included" $
      forM_
        [ haskell "module Consumer.Plain () where" ["import Hetoimasia.Foundation.OwnerTx.Issuer ()"] []
        , haskell "module Consumer.Plain () where" ["import qualified Hetoimasia.Foundation.OwnerTx.Issuer as Bridge ()"] []
        , haskell "module Consumer.Plain () where" ["import Hetoimasia.Foundation.OwnerTx.Issuer qualified as Bridge ()"] []
        , haskell "module Consumer.Plain () where" ["import Hetoimasia.Foundation.OwnerTx.Issuer hiding (fromIssuerSTM)"] []
        , haskell "module Consumer.Plain () where" ["import \"hetoimasia-foundation\" Hetoimasia.Foundation.OwnerTx.Issuer ()"] []
        , haskell "module Consumer.Plain () where" ["import {-# SOURCE #-} Hetoimasia.Foundation.OwnerTx.Issuer ()"] []
        , haskell "module Consumer.Plain () where" ["import safe Hetoimasia.Foundation.OwnerTx.Issuer ()"] []
        , "module Consumer.Plain () where { import Data.Maybe (); import Hetoimasia.Foundation.OwnerTx.Issuer () }\n"
        , unlines ["{-# LANGUAGE CPP #-}", "#define BRIDGE Hetoimasia.Foundation.OwnerTx.Issuer", "module Consumer.Plain () where", "import BRIDGE ()"]
        ]
        $ \source →
          refused [entry | entry ← changed [("consumer/src/Consumer/Plain.hs", source)]] ["Consumer.Plain in consumer:lib:consumer", "imports Hetoimasia.Foundation.OwnerTx.Issuer and is not listed as an importer"]

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
      refused
        (changed [("vulkanpkg/vulkanpkg.cabal", vulkanDescription ["hetoimasia-foundation:owner-tx-issuer>=0.1"])])
        ["vulkanpkg:lib:vulkanpkg", "depends on hetoimasia-foundation:owner-tx-issuer and is not a listed dependent"]

    it "reads a dependency inherited through nested common stanzas, and a foreign library's" $ do
      refused
        ( changed
            [ ( "vulkanpkg/vulkanpkg.cabal"
              , unlines $
                  cabalHeader "vulkanpkg"
                    <> [ "common inner"
                       , "    build-depends: hetoimasia-foundation:owner-tx-issuer"
                       , ""
                       , "common outer"
                       , "    import: inner"
                       , ""
                       , "library"
                       , "    import: outer"
                       , "    exposed-modules: Vulkan.Native"
                       , "    hs-source-dirs: src"
                       , "    default-language: GHC2024", "    default-extensions: UnicodeSyntax"
                       , "    build-depends: base, hetoimasia-foundation"
                       ]
              )
            ]
        )
        ["vulkanpkg:lib:vulkanpkg", "depends on hetoimasia-foundation:owner-tx-issuer and is not a listed dependent"]
      refused
        ( changed
            [ ( "vulkanpkg/vulkanpkg.cabal"
              , vulkanDescription []
                  <> unlines
                    [ ""
                    , "foreign-library native"
                    , "    type: native-shared"
                    , "    other-modules: Vulkan.Foreign"
                    , "    hs-source-dirs: src"
                    , "    default-language: GHC2024", "    default-extensions: UnicodeSyntax"
                    , "    build-depends: base, hetoimasia-foundation:owner-tx-issuer"
                    ]
              )
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
                    <> [ "flag full"
                       , "    default: True"
                       , "    manual: True"
                       , ""
                       , "library"
                       , "    exposed-modules: Consumer.Adapter, Consumer.Plain, Consumer.Variant"
                       , "    hs-source-dirs: src"
                       , "    default-language: GHC2024", "    default-extensions: UnicodeSyntax"
                       , "    build-depends: base, stm, hetoimasia-foundation, hetoimasia-foundation:owner-tx-issuer"
                       , "    if flag(full)"
                       , "        hs-source-dirs: full"
                       , "    else"
                       , "        hs-source-dirs: lean"
                       ]
              )
            , ("consumer/full/Consumer/Variant.hs", haskell "module Consumer.Variant () where" [] [])
            , ("consumer/lean/Consumer/Variant.hs", haskell "module Consumer.Variant () where" ["import Hetoimasia.Foundation.OwnerTx.Issuer ()"] [])
            ]
        )
        ["consumer/lean/Consumer/Variant.hs: Consumer.Variant in consumer:lib:consumer", "-full", "imports Hetoimasia.Foundation.OwnerTx.Issuer and is not listed as an importer"]

    it "refuses a listed adapter that re-exports the bridge through an import alias" $
      refused
        -- an unqualified alias puts the bridge's names in scope under it, so `module Bridge` exports them
        (changed [("consumer/src/Consumer/Adapter.hs", adapter "module Consumer.Adapter (reserveSlot, module Bridge) where" [] `withImport` "import Hetoimasia.Foundation.OwnerTx.Issuer as Bridge")])
        ["Consumer.Adapter in consumer:lib:consumer", "re-exports the bridge's fromIssuerSTM"]

    it "refuses the bridge's own module re-exporting the representation's constructor" $
      refused
        (changed [("foundation/owner-tx-issuer/Hetoimasia/Foundation/OwnerTx/Issuer.hs", haskell "module Hetoimasia.Foundation.OwnerTx.Issuer (fromIssuerSTM, OwnerTx (..)) where" ["import Control.Concurrent.STM (STM)", "import Hetoimasia.Foundation.OwnerTx.Representation (OwnerTx (..))"] ["fromIssuerSTM ∷ STM a → OwnerTx a", "fromIssuerSTM = OwnerTx"])])
        ["Hetoimasia.Foundation.OwnerTx.Issuer in hetoimasia-foundation:lib:owner-tx-issuer", "exports the representation's constructor OwnerTx"]

    it "refuses an adapter exporting an inferred or synonymous wrapper of the embedding under a new name" $ do
      refused
        (changed [("consumer/src/Consumer/Adapter.hs", adapter "module Consumer.Adapter (reserveSlot, lift) where" ["lift = Bridge.fromIssuerSTM"])])
        ["Consumer.Adapter in consumer:lib:consumer", "exports lift, which converts between STM and the ownership transaction"]
      refused
        ( changed
            [ ( "consumer/src/Consumer/Adapter.hs"
              , adapter "module Consumer.Adapter (reserveSlot, embed) where" ["type Embedding a = STM a → OwnerTx a", "embed ∷ Embedding a", "embed = Bridge.fromIssuerSTM"]
                  `withImport` "import Control.Concurrent.STM (STM)"
              )
            ]
        )
        ["Consumer.Adapter in consumer:lib:consumer", "exports embed, which converts between STM and the ownership transaction"]

    it "refuses an export its contract does not list, and a contract entry no longer exported" $ do
      refused
        (changed [("consumer/src/Consumer/Adapter.hs", adapter "module Consumer.Adapter (reserveSlot, slots) where" ["slots ∷ Int", "slots = 4"])])
        ["Consumer.Adapter in consumer:lib:consumer", "exports slots (value ∷ Int), which its export contract does not list"]
      refused
        (changed [("tools/validation/owner_tx_issuers.json", allowlist baseImporters baseDependents (baseExports <> [export' consumerLib "Consumer.Adapter" "releaseSlot" "value" "TVar Int -> OwnerTx ()"]))])
        ["no longer exports releaseSlot", "a stale entry"]

    it "refuses a re-export through Cabal: reexported-modules, and a mixin naming the bridge" $ do
      refused (changed [("consumer/consumer.cabal", consumerDescription [] ["    reexported-modules: Hetoimasia.Foundation.OwnerTx.Issuer as Consumer.Bridge"])]) ["re-exports Hetoimasia.Foundation.OwnerTx.Issuer as Consumer.Bridge through reexported-modules"]
      refused (changed [("consumer/consumer.cabal", consumerDescription [] ["    mixins: hetoimasia-foundation:owner-tx-issuer (Hetoimasia.Foundation.OwnerTx.Issuer as Consumer.Bridge)"])]) ["names the issuer bridge in a mixin"]

    it "refuses a stale entry: a listed importer that imports nothing protected, and a listed dependent that depends on nothing" $
      refused
        (changed [("tools/validation/owner_tx_issuers.json", allowlist (baseImporters <> [(consumerLib, "Consumer.Plain")]) (baseDependents <> ["consumer:lib:gone"]) baseExports)])
        ["the listed importer Consumer.Plain of consumer:lib:consumer imports no protected module in any configuration: a stale entry", "the listed dependent consumer:lib:gone depends on no hetoimasia-foundation:owner-tx-issuer in any configuration: a stale entry"]

    it "fails closed on what it cannot read: a module without a source, a source of another kind, a description Cabal refuses, a missing allowlist" $ do
      refused (changed [("consumer/consumer.cabal", consumerDescription ["Consumer.Missing"] [])]) ["the module Consumer.Missing has no source in its source directories"]
      refused
        (changed [("consumer/consumer.cabal", consumerDescription ["Consumer.Generated"] []), ("consumer/src/Consumer/Generated.hsc", "module Consumer.Generated () where\n")])
        ["the module Consumer.Generated is a .hsc source, a kind the guard does not read"]
      (malformed, malformedSaid) ← checked (changed [("consumer/consumer.cabal", "cabal-version: 3.0\nname: consumer\nlibrary\n  exposed-modules: {\n")])
      malformed `shouldBe` ExitFailure 2
      malformedSaid `shouldContain` "consumer/consumer.cabal: Cabal refused it"
      (missing, missingSaid) ← checked [entry | entry@(path, _) ← baseTree, path /= "tools/validation/owner_tx_issuers.json"]
      missing `shouldBe` ExitFailure 2
      missingSaid `shouldContain` "tools/validation/owner_tx_issuers.json cannot be read"

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
  where
    shouldReturn' action expected = action >>= (`shouldBe` expected)
    withImport source line = unlines (case lines source of header : rest → header : line : rest; [] → [line])

-- | Run an example against the checkout, or leave it pending where this is not a checkout of the whole repository.
inCheckout ∷ (FilePath → IO ()) → IO ()
inCheckout example = do
  checkout ← getCurrentDirectory
  present ← doesFileExist (checkout </> "cabal.project")
  if present then example checkout else pendingWith "this is not a checkout of the whole repository (no cabal.project)"
