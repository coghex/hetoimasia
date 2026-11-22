-- | Hspec coverage for the dependency guard of the ownership transactions' issuer bridge (#721; the design's "Cabal
-- issuer dependency guard").
--
-- @owner-tx-guard@ takes its facts from Cabal alone (components, their configurations on Linux and Darwin on x86_64 and
-- aarch64 under every manual flag, structured dependencies, re-exports, mixins, declared modules and visibility) and
-- compares them with the exact component allowlist @tools/validation/owner-tx-issuers.fields@. Every example runs the
-- production guard against a temporary tree of buildable minimal packages under ordinary Cabal visibility: a
-- Foundation of the real one's shape (a public main library, the private representation library, the public issuer
-- sublibrary and a test suite composing through the bridge), a consumer that depends on public libraries only, and a
-- package only @cabal.project.vulkan@ lists. One example builds that passing tree with Cabal, test suite included.
-- Each negative example asserts the guard's own diagnostic.
--
-- The last group runs the guard on this repository: it passes, it reads only what its catalog group lists as inputs, and
-- the planner selects that group for a change to a Vulkan-only package's source, to a package description, to either
-- project file or their shared import, and to the allowlist.
module OwnerTxGuard (spec) where

import Control.Exception (finally)
import Control.Monad (forM_, void)
import Data.List (isInfixOf, isPrefixOf)
import Json (Json (..), asArray, asString, entryFor, field, parseJson)
import Sandbox (git, run, sanitizedEnvironment, writeFixtureFile)
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist, getCurrentDirectory, getPermissions, setOwnerWritable, setPermissions)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, expectationFailure, it, pendingWith, shouldBe, shouldContain, shouldNotContain, shouldSatisfy)

-- ---------------------------------------------------------------------------
-- The fixture tree

cabalHeader ∷ String → [String]
cabalHeader name = ["cabal-version: 3.4", "name: " <> name, "version: 0.1.0.0", "build-type: Simple", ""]

-- The common fields of every fixture component.
common ∷ [String]
common = ["    default-language: GHC2024", "    default-extensions: UnicodeSyntax"]

-- | Foundation's shape, with these extra fields on its private library.
foundationWith ∷ [String] → String
foundationWith internalExtra = foundationDescription internalExtra [] []

-- | Foundation's shape, with extra fields on its private library, extra dependencies of its test suite and extra fields
-- there.
foundationDescription ∷ [String] → [String] → [String] → String
foundationDescription internalExtra testDependencies testExtra =
  unlines $
    cabalHeader "hetoimasia-foundation"
      <> ["library", "    exposed-modules: Hetoimasia.Foundation.OwnerTx", "    hs-source-dirs: src"]
      <> common
      <> ["    build-depends: base, hetoimasia-foundation:internal", ""]
      <> ["library internal", "    visibility: private", "    exposed-modules: Hetoimasia.Foundation.OwnerTx.Representation, Hetoimasia.Foundation.OwnerTx.Cells, Hetoimasia.Foundation.OwnerTx.Operations", "    hs-source-dirs: internal"]
      <> common
      <> ["    build-depends: base, stm"]
      <> internalExtra
      <> [""]
      <> ["library owner-tx-issuer", "    visibility: public", "    exposed-modules: Hetoimasia.Foundation.OwnerTx.Issuer", "    hs-source-dirs: owner-tx-issuer"]
      <> common
      <> ["    build-depends: base, stm, hetoimasia-foundation:internal", ""]
      <> ["test-suite foundation-tests", "    type: exitcode-stdio-1.0", "    main-is: Main.hs", "    hs-source-dirs: test", "    other-modules: Composition"]
      <> common
      <> ["    build-depends: base, stm, hetoimasia-foundation, hetoimasia-foundation:owner-tx-issuer" <> concatMap (", " <>) testDependencies]
      <> testExtra

-- | The consumer the root project lists: public libraries only, with these extra fields on its library.
consumerWith ∷ [String] → String
consumerWith extra =
  unlines $
    cabalHeader "consumer"
      <> ["library", "    exposed-modules: Consumer.Adapter", "    hs-source-dirs: src"]
      <> common
      <> ["    build-depends: base, stm, hetoimasia-foundation, hetoimasia-foundation:owner-tx-issuer"]
      <> extra

-- | The package only the Vulkan project lists, with these extra dependencies and fields.
vulkanWith ∷ [String] → [String] → String
vulkanWith dependencies extra =
  unlines $
    cabalHeader "vulkanpkg"
      <> ["library", "    exposed-modules: Vulkan.Native", "    hs-source-dirs: src"]
      <> common
      <> ["    build-depends: base, hetoimasia-foundation" <> concatMap (", " <>) dependencies]
      <> extra

haskell ∷ String → [String] → [String] → String
haskell header imports body = unlines ([header, ""] <> imports <> [""] <> body)

allowlist ∷ [String] → String
allowlist dependents = unlines (concat [["dependent", "  component: " <> component, "  reason: a fixture"] | component ← dependents])

baseDependents ∷ [String]
baseDependents = ["hetoimasia-foundation:test:foundation-tests", "consumer:lib:consumer"]

baseTree ∷ [(FilePath, String)]
baseTree =
  [ ("cabal.project", "import: cabal.project.common\npackages:\n  foundation\n  consumer\n")
  , ("cabal.project.vulkan", "import: cabal.project.common\npackages:\n  foundation\n  consumer\n  vulkanpkg\n")
  , ("cabal.project.common", "active-repositories: :none\n")
  , ("foundation/hetoimasia-foundation.cabal", foundationWith [])
  , ("foundation/internal/Hetoimasia/Foundation/OwnerTx/Representation.hs", haskell "module Hetoimasia.Foundation.OwnerTx.Representation (OwnerTx (..)) where" ["import Control.Concurrent.STM (STM)"] ["newtype OwnerTx a = OwnerTx (STM a)", "  deriving newtype (Functor, Applicative, Monad)"])
  , ("foundation/internal/Hetoimasia/Foundation/OwnerTx/Cells.hs", haskell "module Hetoimasia.Foundation.OwnerTx.Cells (ReadOnly (..), watch) where" ["import Control.Concurrent.STM (STM, TVar, readTVar)"] ["newtype ReadOnly a = ReadOnly (TVar a)", "watch ∷ ReadOnly a → STM a", "watch (ReadOnly cell) = readTVar cell"])
  , ( "foundation/internal/Hetoimasia/Foundation/OwnerTx/Operations.hs"
    , haskell
        "module Hetoimasia.Foundation.OwnerTx.Operations (OwnerTx, commit, readTx) where"
        ["import Control.Concurrent.STM (atomically, readTVar)", "import Hetoimasia.Foundation.OwnerTx.Cells (ReadOnly (..))", "import Hetoimasia.Foundation.OwnerTx.Representation (OwnerTx (..))"]
        ["commit ∷ OwnerTx a → IO a", "commit (OwnerTx t) = atomically t", "readTx ∷ ReadOnly a → OwnerTx a", "readTx (ReadOnly cell) = OwnerTx (readTVar cell)"]
    )
  , ("foundation/src/Hetoimasia/Foundation/OwnerTx.hs", haskell "module Hetoimasia.Foundation.OwnerTx (OwnerTx, ReadOnly, commit, readTx, watch) where" ["import Hetoimasia.Foundation.OwnerTx.Cells (ReadOnly, watch)", "import Hetoimasia.Foundation.OwnerTx.Operations (OwnerTx, commit, readTx)"] [])
  , ("foundation/owner-tx-issuer/Hetoimasia/Foundation/OwnerTx/Issuer.hs", haskell "module Hetoimasia.Foundation.OwnerTx.Issuer (fromIssuerSTM) where" ["import Control.Concurrent.STM (STM)", "import Hetoimasia.Foundation.OwnerTx.Representation (OwnerTx (..))"] ["fromIssuerSTM ∷ STM a → OwnerTx a", "fromIssuerSTM = OwnerTx"])
  , ( "foundation/test/Main.hs"
    , haskell
        "module Main (main) where"
        ["import Composition (holdOne)", "import Control.Concurrent.STM (newTVarIO)", "import Hetoimasia.Foundation.OwnerTx (commit)"]
        ["main ∷ IO ()", "main = newTVarIO (1 ∷ Int) >>= commit . holdOne >>= print"]
    )
  , ("foundation/test/Composition.hs", haskell "module Composition (holdOne) where" ["import Control.Concurrent.STM (TVar, readTVar, writeTVar)", "import Hetoimasia.Foundation.OwnerTx (OwnerTx)", "import Hetoimasia.Foundation.OwnerTx.Issuer (fromIssuerSTM)"] ["holdOne ∷ TVar Int → OwnerTx Bool", "holdOne free = fromIssuerSTM (readTVar free >>= \\n → if n <= 0 then pure False else True <$ writeTVar free (n - 1))"])
  , ("consumer/consumer.cabal", consumerWith [])
  , ("consumer/src/Consumer/Adapter.hs", adapterImporting "Hetoimasia.Foundation.OwnerTx")
  , ("vulkanpkg/vulkanpkg.cabal", vulkanWith [] [])
  , ("vulkanpkg/src/Vulkan/Native.hs", haskell "module Vulkan.Native () where" ["import Hetoimasia.Foundation.OwnerTx ()"] [])
  , ("tools/validation/owner-tx-issuers.fields", allowlist baseDependents)
  ]

-- | The consumer's adapter, importing the public transaction type from this module.
adapterImporting ∷ String → String
adapterImporting moduleName = adapterWith moduleName "Hetoimasia.Foundation.OwnerTx.Issuer"

-- | The consumer's adapter, importing the transaction type and the bridge from these modules.
adapterWith ∷ String → String → String
adapterWith moduleName bridge =
  haskell
    "module Consumer.Adapter (reserveSlot) where"
    ["import Control.Concurrent.STM (TVar, readTVar, writeTVar)", "import " <> moduleName <> " (OwnerTx)", "import " <> bridge <> " (fromIssuerSTM)"]
    ["reserveSlot ∷ TVar Int → OwnerTx (Either String ())", "reserveSlot free = fromIssuerSTM (readTVar free >>= \\n → if n <= 0 then pure (Left \"full\") else Right () <$ writeTVar free (n - 1))"]

-- | A package whose library depends on the bridge on every target.
extraPackage ∷ [(FilePath, String)]
extraPackage =
  [ ("extra/extra.cabal", unlines (cabalHeader "extra" <> ["library", "    exposed-modules: Extra", "    hs-source-dirs: src"] <> common <> ["    build-depends: base, hetoimasia-foundation:owner-tx-issuer"]))
  , ("extra/src/Extra.hs", "module Extra () where\n")
  ]

changed ∷ [(FilePath, String)] → [(FilePath, String)]
changed updates = [entry | entry@(path, _) ← baseTree, path `notElem` map fst updates] <> updates

-- ---------------------------------------------------------------------------
-- Running the guard

checked ∷ [(FilePath, String)] → IO (ExitCode, String)
checked files = withSystemTempDirectory "hetoimasia-owner-tx-guard" $ \directory → do
  forM_ files (uncurry (writeFixtureFile directory))
  settings ← sanitizedEnvironment
  (result, _, errors) ← run settings directory "owner-tx-guard" ["check", "--root", directory]
  pure (result, errors)

-- | The guard refused the tree with its policy diagnostic, saying all of these.
refused ∷ [(FilePath, String)] → [String] → IO ()
refused files said = do
  (result, errors) ← checked files
  (result, errors) `shouldSatisfy` ((== ExitFailure 1) . fst)
  forM_ said (errors `shouldContain`)

-- | The guard accepts the tree and Cabal builds it, test suites included.
acceptedAndBuilt ∷ [(FilePath, String)] → IO ()
acceptedAndBuilt files =
  withSystemTempDirectory "hetoimasia-owner-tx-build" $ \directory → do
    forM_ files (uncurry (writeFixtureFile directory))
    settings ← sanitizedEnvironment
    (guarded, _, guardErrors) ← run settings directory "owner-tx-guard" ["check", "--root", directory]
    (guarded, guardErrors) `shouldBe` (ExitSuccess, "")
    (built, _, buildErrors) ← run settings directory "cabal" ["build", "--offline", "--enable-tests", "all"]
    (built, if built == ExitSuccess then "" else buildErrors) `shouldBe` (ExitSuccess, "")

-- | The guard refuses the tree with its policy diagnostic, though Cabal builds it: the refusal is the policy's, not a
-- build failure's.
refusedButBuilt ∷ [(FilePath, String)] → [String] → IO ()
refusedButBuilt files said = do
  refused files said
  withSystemTempDirectory "hetoimasia-owner-tx-build" $ \directory → do
    forM_ files (uncurry (writeFixtureFile directory))
    settings ← sanitizedEnvironment
    (built, _, buildErrors) ← run settings directory "cabal" ["build", "--offline", "--enable-tests", "all"]
    (built, if built == ExitSuccess then "" else buildErrors) `shouldBe` (ExitSuccess, "")

-- | The lines of the guard's diagnostics that mention this text.
mentioning ∷ String → String → [String]
mentioning text errors = filter (text `isInfixOf`) (lines errors)

spec ∷ Spec
spec = describe "The issuer bridge's dependency guard (tools/owner-tx-guard)" $ do
  describe "a fixture tree" $ do
    it "accepts the listed dependents of a tree Cabal builds, its test suite composing through the bridge" $
      acceptedAndBuilt baseTree

    it "refuses an unlisted dependency in a package only the Vulkan project lists, read apart from its compact version bound" $ do
      (result, errors) ← checked (changed [("vulkanpkg/vulkanpkg.cabal", vulkanWith ["hetoimasia-foundation:owner-tx-issuer>=0.1"] [])])
      result `shouldBe` ExitFailure 1
      length (mentioning "vulkanpkg:lib:vulkanpkg (" errors) `shouldBe` 4
      errors `shouldContain` "vulkanpkg:lib:vulkanpkg (darwin/aarch64) depends on hetoimasia-foundation:owner-tx-issuer and is not a listed dependent"

    it "refuses a dependency selected only in a manual flag's inactive branch" $
      refused
        ( changed
            [ ( "vulkanpkg/vulkanpkg.cabal"
              , unlines $
                  cabalHeader "vulkanpkg"
                    <> ["flag full", "    default: True", "    manual: True", ""]
                    <> ["library", "    exposed-modules: Vulkan.Native", "    hs-source-dirs: src"]
                    <> common
                    <> ["    build-depends: base, hetoimasia-foundation", "    if flag(full)", "        cpp-options: -DFULL", "    else", "        build-depends: hetoimasia-foundation:owner-tx-issuer"]
              )
            ]
        )
        ["vulkanpkg:lib:vulkanpkg (linux/x86_64 -full) depends on hetoimasia-foundation:owner-tx-issuer and is not a listed dependent"]

    it "admits a dependency confined to an unbuildable configuration, and still diagnoses that configuration's unsupported forms" $ do
      let native extra =
            unlines $
              cabalHeader "vulkanpkg"
                <> ["flag native", "    default: False", "    manual: True", ""]
                <> ["library", "    exposed-modules: Vulkan.Native", "    hs-source-dirs: src"]
                <> common
                <> ["    build-depends: base, hetoimasia-foundation", "    if flag(native)", "        build-depends: hetoimasia-foundation:owner-tx-issuer", "        buildable: False"]
                <> extra
      checked (changed [("vulkanpkg/vulkanpkg.cabal", native [])]) >>= (`shouldBe` (ExitSuccess, ""))
      refused
        (changed [("vulkanpkg/vulkanpkg.cabal", native []), ("tools/validation/owner-tx-issuers.fields", allowlist (baseDependents <> ["vulkanpkg:lib:vulkanpkg"]))])
        ["the listed dependent vulkanpkg:lib:vulkanpkg depends on no hetoimasia-foundation:owner-tx-issuer in any supported configuration: a stale entry"]
      refused
        (changed [("vulkanpkg/vulkanpkg.cabal", native ["        ghc-options: -package hetoimasia-foundation:owner-tx-issuer"])])
        ["unsupported: the GHC option -package, outside the guard's supported options in vulkanpkg:lib:vulkanpkg"]

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
        ["vulkanpkg:lib:vulkanpkg (", "depends on hetoimasia-foundation:owner-tx-issuer and is not a listed dependent"]
      refused
        ( changed
            [ ("vulkanpkg/vulkanpkg.cabal", vulkanWith [] [] <> unlines (["", "foreign-library native", "    type: native-shared", "    other-modules: Vulkan.Foreign", "    hs-source-dirs: src"] <> common <> ["    build-depends: base, hetoimasia-foundation:owner-tx-issuer"]))
            , ("vulkanpkg/src/Vulkan/Foreign.hs", haskell "module Vulkan.Foreign () where" [] [])
            ]
        )
        ["vulkanpkg:flib:native (", "depends on hetoimasia-foundation:owner-tx-issuer and is not a listed dependent"]

    it "follows a project import to its package and reads a dependency only one target selects" $ do
      (result, errors) ←
        checked
          ( changed
              [ ("cabal.project", "import: extra.project\npackages:\n  foundation\n  consumer\nactive-repositories: :none\n")
              , ("extra.project", "packages:\n  extra\n")
              , ("extra/extra.cabal", unlines (cabalHeader "extra" <> ["library", "    exposed-modules: Extra", "    hs-source-dirs: src"] <> common <> ["    build-depends: base", "    if os(darwin)", "        build-depends: hetoimasia-foundation:owner-tx-issuer"]))
              , ("extra/src/Extra.hs", "module Extra () where\n")
              ]
          )
      result `shouldBe` ExitFailure 1
      errors `shouldContain` "extra:lib:extra (darwin/x86_64) depends on hetoimasia-foundation:owner-tx-issuer and is not a listed dependent"
      mentioning "extra:lib:extra (linux/" errors `shouldBe` []

    it "refuses a missing entry and a stale entry" $ do
      refused (changed [("tools/validation/owner-tx-issuers.fields", allowlist ["hetoimasia-foundation:test:foundation-tests"])]) ["consumer:lib:consumer (darwin/aarch64) depends on hetoimasia-foundation:owner-tx-issuer and is not a listed dependent"]
      refused
        (changed [("tools/validation/owner-tx-issuers.fields", allowlist (baseDependents <> ["consumer:test:gone"]))])
        ["the listed dependent consumer:test:gone depends on no hetoimasia-foundation:owner-tx-issuer in any supported configuration: a stale entry"]

    it "refuses a Cabal re-export or mixin of a protected module, in a listed component too" $ do
      refused
        (changed [("consumer/consumer.cabal", consumerWith ["    reexported-modules: Hetoimasia.Foundation.OwnerTx.Issuer as Consumer.Bridge"])])
        ["consumer:lib:consumer (", "re-exports Hetoimasia.Foundation.OwnerTx.Issuer as Consumer.Bridge through reexported-modules, exposing a protected module"]
      refused
        (changed [("consumer/consumer.cabal", consumerWith ["    reexported-modules: hetoimasia-foundation:Hetoimasia.Foundation.OwnerTx.Issuer"])])
        ["re-exports Hetoimasia.Foundation.OwnerTx.Issuer as Hetoimasia.Foundation.OwnerTx.Issuer through reexported-modules"]
      refusedButBuilt
        ( changed
            [ ("consumer/consumer.cabal", consumerWith ["    mixins: hetoimasia-foundation:owner-tx-issuer (Hetoimasia.Foundation.OwnerTx.Issuer as Consumer.Bridge)"])
            , ("consumer/src/Consumer/Adapter.hs", adapterWith "Hetoimasia.Foundation.OwnerTx" "Consumer.Bridge")
            ]
        )
        ["consumer:lib:consumer (", "exposes or renames Hetoimasia.Foundation.OwnerTx.Issuer through the mixin hetoimasia-foundation:owner-tx-issuer (Hetoimasia.Foundation.OwnerTx.Issuer as Consumer.Bridge)"]
      refused
        (changed [("consumer/consumer.cabal", consumerWith ["    mixins: hetoimasia-foundation:owner-tx-issuer"])])
        ["consumer:lib:consumer (", "exposes or renames Hetoimasia.Foundation.OwnerTx.Issuer through the mixin hetoimasia-foundation:owner-tx-issuer"]
      refused
        (changed [("foundation/hetoimasia-foundation.cabal", foundationWith ["    reexported-modules: Hetoimasia.Foundation.OwnerTx.Representation as Hetoimasia.Foundation.OwnerTx.Raw"])])
        ["hetoimasia-foundation:lib:internal (", "re-exports Hetoimasia.Foundation.OwnerTx.Representation as Hetoimasia.Foundation.OwnerTx.Raw"]

    it "accepts, and Cabal builds, a re-export of the public module, a renaming mixin whose client imports the alias, and a same-package mixin of an unprotected private module" $ do
      acceptedAndBuilt
        ( changed
            [ ("consumer/consumer.cabal", consumerWith ["    mixins: hetoimasia-foundation (Hetoimasia.Foundation.OwnerTx as Consumer.Transactions)"])
            , ("consumer/src/Consumer/Adapter.hs", adapterImporting "Consumer.Transactions")
            , ("foundation/hetoimasia-foundation.cabal", foundationDescription [] ["hetoimasia-foundation:internal"] ["    mixins: hetoimasia-foundation:internal (Hetoimasia.Foundation.OwnerTx.Cells as CellsOnly)"])
            ]
        )
      acceptedAndBuilt (changed [("consumer/consumer.cabal", consumerWith ["    reexported-modules: Hetoimasia.Foundation.OwnerTx as Consumer.PublicTransactions"])])

    it "refuses a mixin by what its renaming brings into scope: all of a library holding a protected module, a renaming of it, or a hiding that leaves it" $ do
      let testMixin text = changed [("foundation/hetoimasia-foundation.cabal", foundationDescription [] ["hetoimasia-foundation:internal"] ["    mixins: " <> text])]
          representation = "exposes or renames Hetoimasia.Foundation.OwnerTx.Representation through the mixin hetoimasia-foundation:internal"
      refused (testMixin "hetoimasia-foundation:internal") ["hetoimasia-foundation:test:foundation-tests (", representation]
      refused (testMixin "hetoimasia-foundation:internal (Hetoimasia.Foundation.OwnerTx.Representation as Raw)") [representation <> " (Hetoimasia.Foundation.OwnerTx.Representation as Raw)"]
      refused (testMixin "hetoimasia-foundation:internal hiding (Hetoimasia.Foundation.OwnerTx.Cells)") [representation <> " hiding (Hetoimasia.Foundation.OwnerTx.Cells)"]
      checked (testMixin "hetoimasia-foundation:internal hiding (Hetoimasia.Foundation.OwnerTx.Representation)") >>= (`shouldBe` (ExitSuccess, ""))

    it "refuses a protected module declared outside its defining component, and a public representation library" $ do
      refused
        ( changed
            [ ("consumer/consumer.cabal", consumerWith ["    other-modules: Hetoimasia.Foundation.OwnerTx.Representation"])
            , ("consumer/src/Hetoimasia/Foundation/OwnerTx/Representation.hs", "module Hetoimasia.Foundation.OwnerTx.Representation () where\n")
            ]
        )
        ["consumer:lib:consumer (", "declares the protected module Hetoimasia.Foundation.OwnerTx.Representation, which only hetoimasia-foundation:lib:internal may"]
      refused
        (changed [("foundation/hetoimasia-foundation.cabal", foundationWith [] `replacing` ("    visibility: private", "    visibility: public"))])
        ["hetoimasia-foundation:lib:internal (", "declares the protected module Hetoimasia.Foundation.OwnerTx.Representation with visibility: public; its library must be private"]

    it "refuses unsupported selection and visibility forms before dropping a branch" $ do
      refused
        (changed [("cabal.project", "packages:\n  foundation\n  consumer\noptional-packages: extra\nactive-repositories: :none\n"), ("extra/extra.cabal", unlines (cabalHeader "extra" <> ["library", "    exposed-modules: Extra", "    hs-source-dirs: src"] <> common <> ["    build-depends: base"])), ("extra/src/Extra.hs", "module Extra () where\n")])
        ["unsupported: the project field optional-packages in cabal.project"]
      refused (changed [("vulkanpkg/vulkanpkg.cabal", vulkanWith [] ["    if os(freebsd)", "        build-depends: hetoimasia-foundation:owner-tx-issuer"])]) ["unsupported: condition os(freebsd)"]
      refused (changed [("vulkanpkg/vulkanpkg.cabal", vulkanWith [] ["    if impl(ghc >= 9.14)", "        build-depends: hetoimasia-foundation:owner-tx-issuer"])]) ["unsupported: condition impl(ghc >=9.14)"]
      refused (changed [("consumer/consumer.cabal", consumerWith ["    signatures: Consumer.Signature"])]) ["unsupported: signatures Consumer.Signature in consumer:lib:consumer"]
      refused
        (changed [("consumer/consumer.cabal", consumerWith ["    if os(linux) && os(darwin)", "        signatures: Demo.Signature", "        ghc-options: -hide-all-packages"])])
        [ "consumer/consumer.cabal: unsupported: signatures Demo.Signature in consumer:lib:consumer (in a branch no supported configuration selects)"
        , "consumer/consumer.cabal: unsupported: the GHC option -hide-all-packages, outside the guard's supported options in consumer:lib:consumer (in a branch no supported configuration selects)"
        ]
      refused (changed [("vulkanpkg/vulkanpkg.cabal", vulkanWith [] ["    ghc-options: -package-id hetoimasia-foundation-0.1.0.0-inplace-owner-tx-issuer"])]) ["unsupported: the GHC option -package-id, outside the guard's supported options in vulkanpkg:lib:vulkanpkg"]
      refused (changed [("vulkanpkg/vulkanpkg.cabal", vulkanWith [] ["    ghc-options: -Wall -fplugin=Some.Plugin"])]) ["unsupported: the GHC option -fplugin=Some.Plugin, outside the guard's supported options in vulkanpkg:lib:vulkanpkg"]
      refused
        (changed [("cabal.project", "packages:\n  foundation\n  consumer\nactive-repositories: :none\npackage consumer\n  ghc-options: -package hetoimasia-foundation:owner-tx-issuer\n")])
        ["unsupported: the GHC option -package in cabal.project (ghc-options), outside the guard's supported options"]

    it "reads a project as Cabal does: an imported project's field in any case, a continued option, and its conditions" $ do
      let imported text = changed [("cabal.project", "import: extra.project\npackages:\n  foundation\n  consumer\nactive-repositories: :none\n"), ("extra.project", text)] <> extraPackage
      refused (imported "Packages: extra\n") ["extra:lib:extra (linux/x86_64) depends on hetoimasia-foundation:owner-tx-issuer and is not a listed dependent"]
      refused
        (imported "packages: extra\npackage consumer\n  ghc-options: -Wall\n    -package-id hetoimasia-foundation-0.1.0.0-inplace-owner-tx-issuer\n")
        ["unsupported: the GHC option -package-id in extra.project (ghc-options), outside the guard's supported options"]
      refused (imported "packages: extra\npackage *\n  ghc-options: \"-hide-all-packages\"\n") ["unsupported: the GHC option -hide-all-packages in extra.project (ghc-options), outside the guard's supported options"]
      refused (imported "packages: extra\nprogram-options\n  ghc-options: -Wall\n") ["unsupported: the project section program-options in extra.project"]
      refused (imported "packages: extra\nlibrary-vanilla: False\n") ["unsupported: the project field library-vanilla in extra.project"]
      refused (imported "packages: extra\nif os(freebsd)\n  package consumer\n    ghc-options: -Wall\n") ["unsupported: condition os(freebsd) in extra.project"]
      refused (imported "packages: extra\nif impl(ghc >= 9.14)\n  package consumer\n    ghc-options: -Wall\n") ["unsupported: condition impl(ghc >=9.14) in extra.project"]

    it "supports exactly this repository's project syntax: no selection or import inside a conditional, no quoted or spaced path" $ do
      let imported text = changed [("cabal.project", "import: cabal.project.common\nimport: extra.project\npackages:\n  foundation\n  consumer\n"), ("extra.project", text)] <> extraPackage
      checked (imported "if os(darwin)\n  package consumer\n    ghc-options: -Wall\nelse\n  package consumer\n    flags: -full\n") >>= (`shouldBe` (ExitSuccess, ""))
      refused (imported "if os(linux)\n  packages: extra\n") ["unsupported: the project field packages inside a conditional in extra.project (only package sections)"]
      refused (imported "packages: extra\nif os(darwin)\n  import: more.project\n") ["unsupported: the project field import inside a conditional in extra.project (only package sections)"]
      refused (imported "if os(darwin)\n  jobs: 4\n") ["unsupported: the project field jobs inside a conditional in extra.project (only package sections)"]
      refused (imported "packages: \"extra\"\n") ["unsupported: the package entry \"extra\" in extra.project (only unquoted literal local directories)"]
      refused (imported "packages: extra\nimport: \"shared.project\"\n") ["unsupported: the project import \"shared.project\" in extra.project (only one unquoted literal relative local file)"]
      refused (imported "packages: extra\nimport: shared settings.project\n") ["unsupported: the project import shared settings.project in extra.project (only one unquoted literal relative local file)"]

    it "requires both project files and refuses an import cycle, while two projects may share an import" $ do
      (missing, missingSaid) ← checked [entry | entry@(path, _) ← baseTree, path /= "cabal.project.vulkan"]
      (missing, missingSaid) `shouldSatisfy` ((== ExitFailure 2) . fst)
      missingSaid `shouldContain` "cabal.project.vulkan does not exist: the guard reads both project files"
      (cycled, cycledSaid) ← checked (changed [("cabal.project", "import: cabal.project.common\npackages:\n  foundation\n  consumer\n"), ("cabal.project.common", "active-repositories: :none\nimport: cabal.project\n")])
      cycled `shouldBe` ExitFailure 2
      cycledSaid `shouldContain` "a cyclic project import: cabal.project → cabal.project.common → cabal.project"

    it "fails closed on a library selector it cannot resolve, a description Cabal refuses and an allowlist it cannot read" $ do
      refused (changed [("vulkanpkg/vulkanpkg.cabal", vulkanWith ["hetoimasia-foundation:issuer"] [])]) ["uncovered: vulkanpkg:lib:vulkanpkg selects hetoimasia-foundation:issuer, which names no library of the local package hetoimasia-foundation"]
      (unbuildable, unbuildableSaid) ← checked (changed [("vulkanpkg/vulkanpkg.cabal", vulkanWith [] ["    if os(darwin)", "        build-depends: hetoimasia-foundation:issuer", "        buildable: False"])])
      unbuildable `shouldBe` ExitFailure 1
      case mentioning "selects hetoimasia-foundation:issuer" unbuildableSaid of
        [line] → do
          line `shouldContain` "vulkanpkg/vulkanpkg.cabal: uncovered: vulkanpkg:lib:vulkanpkg selects hetoimasia-foundation:issuer, which names no library of the local package hetoimasia-foundation (in "
          forM_ ["vulkanpkg:lib:vulkanpkg (darwin/x86_64)", "vulkanpkg:lib:vulkanpkg (darwin/aarch64)"] (line `shouldContain`)
          line `shouldNotContain` "linux"
        other → expectationFailure ("one selector diagnostic naming its configurations, not " <> show other)
      refused
        (changed [("consumer/consumer.cabal", consumerWith ["    mixins: hetoimasia-foundation:missing"])])
        ["uncovered: consumer:lib:consumer selects hetoimasia-foundation:missing, which names no library of the local package hetoimasia-foundation"]
      (malformed, malformedSaid) ← checked (changed [("consumer/consumer.cabal", "cabal-version: 3.4\nname: consumer\nlibrary\n  exposed-modules: {\n")])
      malformed `shouldBe` ExitFailure 2
      malformedSaid `shouldContain` "consumer/consumer.cabal: Cabal refused it"
      (missing, missingSaid) ← checked [entry | entry@(path, _) ← baseTree, path /= "tools/validation/owner-tx-issuers.fields"]
      missing `shouldBe` ExitFailure 2
      missingSaid `shouldContain` "tools/validation/owner-tx-issuers.fields cannot be read"
      forM_
        [ ("dependent\n  component: consumer:lib:consumer\n  reason: one\ndependent\n  component: consumer:lib:consumer\n  reason: two\n", "a component listed more than once: consumer:lib:consumer")
        , ("version: 3\n", "the field version is outside a dependent section")
        , ("importer consumer\n  component: consumer:lib:consumer\n  reason: x\n", "the section importer is not a dependent section with no arguments")
        , ("dependent\n  component: consumer:lib:consumer\n  component: consumer:test:gone\n  reason: x\n", "a dependent section needs exactly one component (package:kind:name) and one reason")
        , ("dependent\n  component: consumer\n  reason: x\n", "a dependent section needs exactly one component (package:kind:name) and one reason")
        , ("{\"schema_version\": 3, \"dependents\": []}\n", "tools/validation/owner-tx-issuers.fields cannot be read")
        ]
        $ \(text, said) → do
          (unreadable, unreadableSaid) ← checked (changed [("tools/validation/owner-tx-issuers.fields", text)])
          unreadable `shouldBe` ExitFailure 2
          unreadableSaid `shouldContain` said

    it "resolves a mixin against its configuration's dependencies, and refuses a library selector outside the repository" $ do
      refused
        (changed [("cabal.project", "import: cabal.project.common\npackages:\n  foundation\n  consumer\n  extra\n")] <> [("extra/extra.cabal", unlines (cabalHeader "extra" <> ["library", "    exposed-modules: Extra", "    hs-source-dirs: src"] <> common <> ["    build-depends: base", "    mixins: hetoimasia-foundation (Hetoimasia.Foundation.OwnerTx as PublicTx)"])), ("extra/src/Extra.hs", "module Extra () where\n")])
        ["extra/extra.cabal: uncovered: extra:lib:extra (darwin/aarch64) has the mixin hetoimasia-foundation, which names no dependency of that configuration"]
      refused
        (changed [("vulkanpkg/vulkanpkg.cabal", vulkanWith ["base:missing"] [])])
        ["uncovered: vulkanpkg:lib:vulkanpkg selects base:missing, a library of a package outside this repository, which the guard cannot establish"]

    it "checks a read-only checkout without writing into it" $
      withSystemTempDirectory "hetoimasia-owner-tx-readonly" $ \directory → do
        forM_ baseTree (uncurry (writeFixtureFile directory))
        settings ← sanitizedEnvironment
        before ← getPermissions directory
        setPermissions directory (setOwnerWritable False before)
        (result, _, errors) ← run settings directory "owner-tx-guard" ["check", "--root", directory] `finally` setPermissions directory before
        (result, errors) `shouldBe` (ExitSuccess, "")

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

    it "selects its group for a change to a Vulkan-only package's source, to a package description, to either project file or their import, and to the allowlist" $ inCheckout $ \checkout → do
      settings ← sanitizedEnvironment
      files ← lines <$> git settings checkout ["-c", "safe.directory=*", "ls-files", "*.cabal", "cabal.project*", "tools/validation/catalog.json"]
      let changedPaths =
            [ "packages/gpu-vulkan/native/src/Hetoimasia/GPU/Vulkan/Native/Uploads.hs"
            , "packages/foundation/hetoimasia-foundation.cabal"
            , "cabal.project"
            , "cabal.project.vulkan"
            , "cabal.project.common"
            , "tools/validation/owner-tx-issuers.fields"
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

-- | A text with one line replaced.
replacing ∷ String → (String, String) → String
replacing text (old, new) = unlines [if line == old then new else line | line ← lines text]
