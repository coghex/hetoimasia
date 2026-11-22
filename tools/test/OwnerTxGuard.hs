-- | Hspec coverage for the dependency guard of the ownership transactions' issuer bridge (#721; the design's "Cabal
-- issuer dependency guard").
--
-- @owner-tx-guard@ takes its facts from Cabal alone (components, their configurations on Linux and Darwin on x86_64 and
-- aarch64 under every manual flag, structured dependencies, re-exports, mixins, declared modules and visibility) and
-- compares them with the exact component allowlist @tools/validation/owner_tx_issuers.json@. Every example runs the
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
import Data.List (intercalate, isInfixOf, isPrefixOf)
import Json (Json (..), asArray, asString, entryFor, field, parseJson)
import Sandbox (git, run, sanitizedEnvironment, writeFixtureFile)
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist, getCurrentDirectory, getPermissions, setOwnerWritable, setPermissions)
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

-- | Foundation's shape, with these extra fields on its private library.
foundationWith ∷ [String] → String
foundationWith internalExtra =
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
      <> ["    build-depends: base, stm, hetoimasia-foundation, hetoimasia-foundation:owner-tx-issuer"]

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
allowlist dependents =
  unlines
    [ "{"
    , "  \"schema_version\": 3,"
    , "  \"dependents\": [" <> intercalate ", " ["{\"component\": " <> show component <> ", \"reason\": \"a fixture\"}" | component ← dependents] <> "]"
    , "}"
    ]

baseDependents ∷ [String]
baseDependents = ["hetoimasia-foundation:test:foundation-tests", "consumer:lib:consumer"]

baseTree ∷ [(FilePath, String)]
baseTree =
  [ ("cabal.project", "packages:\n  foundation\n  consumer\nactive-repositories: :none\n")
  , ("cabal.project.vulkan", "packages:\n  foundation\n  consumer\n  vulkanpkg\nactive-repositories: :none\n")
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
  , ( "consumer/src/Consumer/Adapter.hs"
    , haskell
        "module Consumer.Adapter (reserveSlot) where"
        ["import Control.Concurrent.STM (TVar, readTVar, writeTVar)", "import Hetoimasia.Foundation.OwnerTx (OwnerTx)", "import Hetoimasia.Foundation.OwnerTx.Issuer (fromIssuerSTM)"]
        ["reserveSlot ∷ TVar Int → OwnerTx (Either String ())", "reserveSlot free = fromIssuerSTM (readTVar free >>= \\n → if n <= 0 then pure (Left \"full\") else Right () <$ writeTVar free (n - 1))"]
    )
  , ("vulkanpkg/vulkanpkg.cabal", vulkanWith [] [])
  , ("vulkanpkg/src/Vulkan/Native.hs", haskell "module Vulkan.Native () where" ["import Hetoimasia.Foundation.OwnerTx ()"] [])
  , ("tools/validation/owner_tx_issuers.json", allowlist baseDependents)
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

-- | The lines of the guard's diagnostics that mention this text.
mentioning ∷ String → String → [String]
mentioning text errors = filter (text `isInfixOf`) (lines errors)

spec ∷ Spec
spec = describe "The issuer bridge's dependency guard (tools/owner-tx-guard)" $ do
  describe "a fixture tree" $ do
    it "accepts the listed dependents of a tree Cabal builds, its test suite composing through the bridge" $
      withSystemTempDirectory "hetoimasia-owner-tx-build" $ \directory → do
        forM_ baseTree (uncurry (writeFixtureFile directory))
        settings ← sanitizedEnvironment
        guarded ← run settings directory "owner-tx-guard" ["check", "--root", directory]
        (\(result, _, errors) → (result, errors)) guarded `shouldBe` (ExitSuccess, "")
        (built, _, buildErrors) ← run settings directory "cabal" ["build", "--offline", "--enable-tests", "all"]
        (built, if built == ExitSuccess then "" else buildErrors) `shouldBe` (ExitSuccess, "")

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
        (changed [("vulkanpkg/vulkanpkg.cabal", native []), ("tools/validation/owner_tx_issuers.json", allowlist (baseDependents <> ["vulkanpkg:lib:vulkanpkg"]))])
        ["the listed dependent vulkanpkg:lib:vulkanpkg depends on no hetoimasia-foundation:owner-tx-issuer in any supported configuration: a stale entry"]
      refused
        (changed [("vulkanpkg/vulkanpkg.cabal", native ["        ghc-options: -package hetoimasia-foundation:owner-tx-issuer"])])
        ["vulkanpkg:lib:vulkanpkg (darwin/aarch64 +native)", "unsupported: the GHC option -package, which changes which packages are visible"]

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
      refused (changed [("tools/validation/owner_tx_issuers.json", allowlist ["hetoimasia-foundation:test:foundation-tests"])]) ["consumer:lib:consumer (darwin/aarch64) depends on hetoimasia-foundation:owner-tx-issuer and is not a listed dependent"]
      refused
        (changed [("tools/validation/owner_tx_issuers.json", allowlist (baseDependents <> ["consumer:test:gone"]))])
        ["the listed dependent consumer:test:gone depends on no hetoimasia-foundation:owner-tx-issuer in any supported configuration: a stale entry"]

    it "refuses a Cabal re-export or mixin of a protected module, in a listed component too" $ do
      refused
        (changed [("consumer/consumer.cabal", consumerWith ["    reexported-modules: Hetoimasia.Foundation.OwnerTx.Issuer as Consumer.Bridge"])])
        ["consumer:lib:consumer (", "re-exports Hetoimasia.Foundation.OwnerTx.Issuer as Consumer.Bridge through reexported-modules, exposing a protected module"]
      refused
        (changed [("consumer/consumer.cabal", consumerWith ["    reexported-modules: hetoimasia-foundation:Hetoimasia.Foundation.OwnerTx.Issuer"])])
        ["re-exports Hetoimasia.Foundation.OwnerTx.Issuer as Hetoimasia.Foundation.OwnerTx.Issuer through reexported-modules"]
      refused
        (changed [("consumer/consumer.cabal", consumerWith ["    mixins: hetoimasia-foundation:owner-tx-issuer (Hetoimasia.Foundation.OwnerTx.Issuer as Consumer.Bridge)"])])
        ["consumer:lib:consumer (", "names a protected module or library in the mixin hetoimasia-foundation:owner-tx-issuer (Hetoimasia.Foundation.OwnerTx.Issuer as Consumer.Bridge)"]
      refused
        (changed [("foundation/hetoimasia-foundation.cabal", foundationWith ["    reexported-modules: Hetoimasia.Foundation.OwnerTx.Representation as Hetoimasia.Foundation.OwnerTx.Raw"])])
        ["hetoimasia-foundation:lib:internal (", "re-exports Hetoimasia.Foundation.OwnerTx.Representation as Hetoimasia.Foundation.OwnerTx.Raw"]

    it "matches the protected modules by their exact names: a re-export or mixin of the public module is accepted" $ do
      checked (changed [("consumer/consumer.cabal", consumerWith ["    reexported-modules: Hetoimasia.Foundation.OwnerTx as Consumer.Transactions"])]) >>= (`shouldBe` (ExitSuccess, ""))
      checked (changed [("consumer/consumer.cabal", consumerWith ["    mixins: hetoimasia-foundation (Hetoimasia.Foundation.OwnerTx as Consumer.Transactions)"])]) >>= (`shouldBe` (ExitSuccess, ""))
      refused
        (changed [("consumer/consumer.cabal", consumerWith ["    mixins: hetoimasia-foundation (Hetoimasia.Foundation.OwnerTx as Consumer.Transactions, Hetoimasia.Foundation.OwnerTx.Representation as Consumer.Raw)"])])
        ["names a protected module or library in the mixin hetoimasia-foundation (Hetoimasia.Foundation.OwnerTx as Consumer.Transactions, Hetoimasia.Foundation.OwnerTx.Representation as Consumer.Raw)"]

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
        ["unsupported: optional-packages in cabal.project"]
      refused (changed [("vulkanpkg/vulkanpkg.cabal", vulkanWith [] ["    if os(freebsd)", "        build-depends: hetoimasia-foundation:owner-tx-issuer"])]) ["unsupported: condition os(freebsd)"]
      refused (changed [("vulkanpkg/vulkanpkg.cabal", vulkanWith [] ["    if impl(ghc >= 9.14)", "        build-depends: hetoimasia-foundation:owner-tx-issuer"])]) ["unsupported: condition impl(ghc >=9.14)"]
      refused (changed [("consumer/consumer.cabal", consumerWith ["    signatures: Consumer.Signature"])]) ["unsupported: signatures Consumer.Signature"]
      refused (changed [("vulkanpkg/vulkanpkg.cabal", vulkanWith [] ["    ghc-options: -package-id hetoimasia-foundation-0.1.0.0-inplace-owner-tx-issuer"])]) ["unsupported: the GHC option -package-id, which changes which packages are visible"]
      refused
        (changed [("cabal.project", "packages:\n  foundation\n  consumer\nactive-repositories: :none\npackage consumer\n  ghc-options: -package hetoimasia-foundation:owner-tx-issuer\n")])
        ["unsupported: the option -package in cabal.project, which changes which packages are visible"]

    it "fails closed on a library selector it cannot resolve, a description Cabal refuses and an allowlist it cannot read" $ do
      refused (changed [("vulkanpkg/vulkanpkg.cabal", vulkanWith ["hetoimasia-foundation:issuer"] [])]) ["uncovered: vulkanpkg:lib:vulkanpkg (", "selects hetoimasia-foundation:issuer, which names no library of the local package hetoimasia-foundation"]
      (malformed, malformedSaid) ← checked (changed [("consumer/consumer.cabal", "cabal-version: 3.4\nname: consumer\nlibrary\n  exposed-modules: {\n")])
      malformed `shouldBe` ExitFailure 2
      malformedSaid `shouldContain` "consumer/consumer.cabal: Cabal refused it"
      (missing, missingSaid) ← checked [entry | entry@(path, _) ← baseTree, path /= "tools/validation/owner_tx_issuers.json"]
      missing `shouldBe` ExitFailure 2
      missingSaid `shouldContain` "tools/validation/owner_tx_issuers.json cannot be read"
      (old, oldSaid) ← checked (changed [("tools/validation/owner_tx_issuers.json", "{\"schema_version\": 2, \"importers\": [], \"dependents\": [], \"exports\": []}\n")])
      old `shouldBe` ExitFailure 2
      oldSaid `shouldContain` "the allowlist must be an object with schema_version 3"

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

-- | A text with one line replaced.
replacing ∷ String → (String, String) → String
replacing text (old, new) = unlines [if line == old then new else line | line ← lines text]
