-- | Hspec coverage for the import guard of the ownership transactions' issuer bridge (#721).
--
-- @tools/validation/owner_tx_guard.py@ refuses every module that imports @Hetoimasia.Foundation.OwnerTx.Issuer@ or the
-- bridge-equivalent @Hetoimasia.Foundation.OwnerTx.Representation@ without being listed with its component in
-- @tools/validation/owner_tx_issuers.json@, every unlisted component dependency on @hetoimasia-foundation:owner-tx-issuer@,
-- every re-export of the bridge or the representation, every stale entry, and anything it cannot read. Every example runs
-- the guard itself against a temporary tree: a small Foundation of the same shape (its main library, the private library
-- with the representation, the issuer sublibrary and a test suite), a consumer package the root project lists, and a
-- package only @cabal.project.vulkan@ lists.
--
-- The last group runs the guard on this repository: it passes, it reads only what its catalog group lists as inputs, and
-- the planner selects that group for a change to a Vulkan-only package's source, to a package description and to the
-- allowlist.
module OwnerTxGuard (spec) where

import Control.Monad (forM_, void)
import Data.List (isPrefixOf)
import Json (Json (..), asArray, asString, entryFor, field, parseJson)
import Sandbox (git, run, sanitizedEnvironment, writeFixtureFile)
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist, getCurrentDirectory)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, expectationFailure, it, pendingWith, shouldBe, shouldContain, shouldReturn, shouldSatisfy)

-- | The Foundation of a fixture: the same libraries and modules as the real one, each source a stub.
foundationDescription ∷ String
foundationDescription =
  unlines
    [ "cabal-version: 3.0"
    , "name: hetoimasia-foundation"
    , "version: 0.1.0.0"
    , "build-type: Simple"
    , ""
    , "library"
    , "    exposed-modules: Hetoimasia.Foundation.OwnerTx"
    , "    hs-source-dirs: src"
    , "    build-depends: base, hetoimasia-foundation:internal"
    , ""
    , "library internal"
    , "    visibility: private"
    , "    exposed-modules: Hetoimasia.Foundation.OwnerTx.Representation"
    , "    hs-source-dirs: internal"
    , "    build-depends: base"
    , ""
    , "library owner-tx-issuer"
    , "    visibility: public"
    , "    exposed-modules: Hetoimasia.Foundation.OwnerTx.Issuer"
    , "    hs-source-dirs: owner-tx-issuer"
    , "    build-depends: base, hetoimasia-foundation:internal"
    , ""
    , "test-suite foundation-tests"
    , "    type: exitcode-stdio-1.0"
    , "    main-is: Main.hs"
    , "    hs-source-dirs: test"
    , "    other-modules: Composition, Sibling"
    , "    build-depends: base, hetoimasia-foundation, hetoimasia-foundation:internal, hetoimasia-foundation:owner-tx-issuer"
    ]

-- | A consumer package the root project lists: one listed adapter, and the modules the examples change.
consumerDescription ∷ [String] → String
consumerDescription extra =
  unlines $
    [ "cabal-version: 3.0"
    , "name: consumer"
    , "version: 0.1.0.0"
    , "build-type: Simple"
    , ""
    , "library"
    , "    exposed-modules: Consumer.Adapter, Consumer.Plain"
    , "    hs-source-dirs: src"
    , "    build-depends: base, hetoimasia-foundation, hetoimasia-foundation:owner-tx-issuer"
    ]
      <> extra

-- | A package only the Vulkan project lists.
vulkanDescription ∷ [String] → String
vulkanDescription depends =
  unlines
    [ "cabal-version: 3.0"
    , "name: vulkanpkg"
    , "version: 0.1.0.0"
    , "build-type: Simple"
    , ""
    , "library"
    , "    exposed-modules: Vulkan.Native"
    , "    hs-source-dirs: src"
    , "    build-depends: " <> unwords' (["base", "hetoimasia-foundation"] <> depends)
    ]
  where
    unwords' = foldr1 (\a b → a <> ", " <> b)

-- | An allowlist: importers as component and module, and dependents.
allowlist ∷ [(String, String)] → [String] → String
allowlist importers dependents =
  unlines
    [ "{"
    , "  \"schema_version\": 1,"
    , "  \"importers\": [" <> joined [entry component module' | (component, module') ← importers] <> "],"
    , "  \"dependents\": [" <> joined [dependent component | component ← dependents] <> "]"
    , "}"
    ]
  where
    entry component module' = "{\"component\": " <> show component <> ", \"module\": " <> show module' <> ", \"reason\": \"a fixture\"}"
    dependent component = "{\"component\": " <> show component <> ", \"reason\": \"a fixture\"}"
    joined [] = ""
    joined items = foldr1 (\a b → a <> ", " <> b) items

baseImporters ∷ [(String, String)]
baseImporters =
  [ ("hetoimasia-foundation:lib:hetoimasia-foundation", "Hetoimasia.Foundation.OwnerTx")
  , ("hetoimasia-foundation:lib:owner-tx-issuer", "Hetoimasia.Foundation.OwnerTx.Issuer")
  , ("hetoimasia-foundation:test:foundation-tests", "Composition")
  , ("consumer:lib:consumer", "Consumer.Adapter")
  ]

baseDependents ∷ [String]
baseDependents = ["hetoimasia-foundation:test:foundation-tests", "consumer:lib:consumer"]

haskell ∷ String → [String] → [String] → String
haskell header imports body = unlines ([header, ""] <> imports <> [""] <> body)

-- | The passing tree: every importer listed, every dependent listed, no re-export.
baseTree ∷ [(FilePath, String)]
baseTree =
  [ ("cabal.project", "packages:\n  foundation\n  consumer\n")
  , ("cabal.project.vulkan", "packages:\n  foundation\n  consumer\n  vulkanpkg\n")
  , ("foundation/hetoimasia-foundation.cabal", foundationDescription)
  , ("foundation/src/Hetoimasia/Foundation/OwnerTx.hs", haskell "module Hetoimasia.Foundation.OwnerTx (OwnerTx, commit) where" ["import Hetoimasia.Foundation.OwnerTx.Representation (OwnerTx (..))"] ["commit = undefined"])
  , ("foundation/internal/Hetoimasia/Foundation/OwnerTx/Representation.hs", haskell "module Hetoimasia.Foundation.OwnerTx.Representation (OwnerTx (..)) where" [] ["newtype OwnerTx a = OwnerTx a"])
  , ("foundation/owner-tx-issuer/Hetoimasia/Foundation/OwnerTx/Issuer.hs", haskell "module Hetoimasia.Foundation.OwnerTx.Issuer (fromIssuerSTM, modifyCell, stateCell) where" ["import Hetoimasia.Foundation.OwnerTx.Representation (OwnerTx (..))"] ["fromIssuerSTM = undefined"])
  , ("foundation/test/Main.hs", haskell "module Main (main) where" ["import Composition ()", "import Sibling ()"] ["main = pure ()"])
  , ("foundation/test/Composition.hs", haskell "module Composition () where" ["import Hetoimasia.Foundation.OwnerTx.Issuer (fromIssuerSTM)"] [])
  , ("foundation/test/Sibling.hs", haskell "module Sibling () where" ["import Hetoimasia.Foundation.OwnerTx (OwnerTx)"] [])
  , ("consumer/consumer.cabal", consumerDescription [])
  , ("consumer/src/Consumer/Adapter.hs", haskell "module Consumer.Adapter (adapt) where" ["import qualified Hetoimasia.Foundation.OwnerTx.Issuer as Bridge"] ["adapt = Bridge.fromIssuerSTM"])
  , ("consumer/src/Consumer/Plain.hs", haskell "module Consumer.Plain () where" ["import Hetoimasia.Foundation.OwnerTx (OwnerTx)"] [])
  , ("vulkanpkg/vulkanpkg.cabal", vulkanDescription [])
  , ("vulkanpkg/src/Vulkan/Native.hs", haskell "module Vulkan.Native () where" ["import Hetoimasia.Foundation.OwnerTx (OwnerTx)"] [])
  , ("tools/validation/owner_tx_issuers.json", allowlist baseImporters baseDependents)
  ]

-- | Replace or add these files of the base tree.
changed ∷ [(FilePath, String)] → [(FilePath, String)]
changed updates = [entry | entry@(path, _) ← baseTree, path `notElem` map fst updates] <> updates

-- | Run the guard against a fixture tree: its exit code and what it said on standard error.
guarded ∷ [String] → [(FilePath, String)] → IO (ExitCode, String)
guarded arguments files = withSystemTempDirectory "hetoimasia-owner-tx-guard" $ \directory → do
  forM_ files (uncurry (writeFixtureFile directory))
  checkout ← getCurrentDirectory
  settings ← sanitizedEnvironment
  (result, _, errors) ← run (("PYTHONDONTWRITEBYTECODE", "1") : settings) checkout "python3" (["-I", "-W", "error", checkout </> "tools/validation/owner_tx_guard.py", "--root", directory] <> arguments)
  pure (result, errors)

checked ∷ [(FilePath, String)] → IO (ExitCode, String)
checked = guarded ["check"]

-- | The guard refused the tree, saying all of these.
refused ∷ [(FilePath, String)] → [String] → IO ()
refused files said = do
  (result, errors) ← checked files
  result `shouldBe` ExitFailure 1
  forM_ said (errors `shouldContain`)

spec ∷ Spec
spec = describe "The issuer bridge's import guard (tools/validation/owner_tx_guard.py)" $ do
  describe "a fixture tree" $ do
    it "accepts the listed importers and dependents" $
      checked baseTree `shouldReturn` (ExitSuccess, "")

    it "refuses an unlisted sibling module in a component listed for the bridge" $
      refused
        (changed [("foundation/test/Sibling.hs", haskell "module Sibling () where" ["import Hetoimasia.Foundation.OwnerTx.Issuer (fromIssuerSTM)"] [])])
        ["foundation/test/Sibling.hs", "Sibling in hetoimasia-foundation:test:foundation-tests imports Hetoimasia.Foundation.OwnerTx.Issuer", "is not listed"]

    it "refuses every import form of the bridge in an unlisted module" $
      forM_
        [ "import Hetoimasia.Foundation.OwnerTx.Issuer"
        , "import qualified Hetoimasia.Foundation.OwnerTx.Issuer as Bridge"
        , "import Hetoimasia.Foundation.OwnerTx.Issuer qualified as Bridge"
        , "import Hetoimasia.Foundation.OwnerTx.Issuer (fromIssuerSTM)"
        , "import Hetoimasia.Foundation.OwnerTx.Issuer hiding (modifyCell)"
        , "import \"hetoimasia-foundation\" Hetoimasia.Foundation.OwnerTx.Issuer"
        , "import {-# SOURCE #-} Hetoimasia.Foundation.OwnerTx.Issuer"
        , "import safe Hetoimasia.Foundation.OwnerTx.Issuer"
        , "import Hetoimasia.Foundation.OwnerTx.Issuer;"
        ]
        $ \form →
          refused
            (changed [("consumer/src/Consumer/Plain.hs", haskell "module Consumer.Plain () where" [form] [])])
            ["Consumer.Plain in consumer:lib:consumer imports Hetoimasia.Foundation.OwnerTx.Issuer"]

    it "refuses an unlisted import of the bridge-equivalent representation, from Foundation's own test suite too" $
      refused
        (changed [("foundation/test/Sibling.hs", haskell "module Sibling () where" ["import Hetoimasia.Foundation.OwnerTx.Representation (OwnerTx (..))"] [])])
        ["Sibling in hetoimasia-foundation:test:foundation-tests imports Hetoimasia.Foundation.OwnerTx.Representation"]

    it "refuses an unlisted dependency on the issuer sublibrary, and an unlisted import, in a package only the Vulkan project lists" $
      refused
        ( changed
            [ ("vulkanpkg/vulkanpkg.cabal", vulkanDescription ["hetoimasia-foundation:owner-tx-issuer"])
            , ("vulkanpkg/src/Vulkan/Native.hs", haskell "module Vulkan.Native () where" ["import Hetoimasia.Foundation.OwnerTx.Issuer (fromIssuerSTM)"] [])
            ]
        )
        ["vulkanpkg:lib:vulkanpkg depends on hetoimasia-foundation:owner-tx-issuer and is not a listed dependent", "Vulkan.Native in vulkanpkg:lib:vulkanpkg imports Hetoimasia.Foundation.OwnerTx.Issuer"]

    it "reads both branches of a manual flag's conditional: a module and a dependency the inactive branch declares are held to the list" $
      refused
        ( changed
            [ ( "consumer/consumer.cabal"
              , unlines
                  [ "cabal-version: 3.0"
                  , "name: consumer"
                  , "version: 0.1.0.0"
                  , "build-type: Simple"
                  , ""
                  , "flag extra"
                  , "    default: True"
                  , "    manual: True"
                  , ""
                  , "library"
                  , "    exposed-modules: Consumer.Adapter, Consumer.Plain"
                  , "    hs-source-dirs: src"
                  , "    build-depends: base, hetoimasia-foundation, hetoimasia-foundation:owner-tx-issuer"
                  , "    if flag(extra)"
                  , "        other-modules: Consumer.Flagged"
                  , "    else"
                  , "        other-modules: Consumer.Unflagged"
                  , ""
                  , "executable tool"
                  , "    main-is: Main.hs"
                  , "    hs-source-dirs: app"
                  , "    build-depends: base"
                  , "    if flag(extra)"
                  , "        build-depends: hetoimasia-foundation:owner-tx-issuer"
                  ]
              )
            , ("consumer/src/Consumer/Flagged.hs", haskell "module Consumer.Flagged () where" [] [])
            , ("consumer/src/Consumer/Unflagged.hs", haskell "module Consumer.Unflagged () where" ["import Hetoimasia.Foundation.OwnerTx.Issuer"] [])
            , ("consumer/app/Main.hs", haskell "module Main (main) where" [] ["main = pure ()"])
            ]
        )
        ["Consumer.Unflagged in consumer:lib:consumer imports Hetoimasia.Foundation.OwnerTx.Issuer", "consumer:exe:tool depends on hetoimasia-foundation:owner-tx-issuer"]

    it "refuses a listed module that re-exports the bridge's module, a bridge function or the representation's constructors" $
      forM_
        [ ("module Consumer.Adapter (module Hetoimasia.Foundation.OwnerTx.Issuer) where", "re-exports the module Hetoimasia.Foundation.OwnerTx.Issuer")
        , ("module Consumer.Adapter (Bridge.fromIssuerSTM) where", "re-exports the bridge's fromIssuerSTM")
        , ("module Consumer.Adapter (adapt, modifyCell) where", "re-exports the bridge's modifyCell")
        ]
        $ \(header, said) →
          refused
            (changed [("consumer/src/Consumer/Adapter.hs", haskell header ["import qualified Hetoimasia.Foundation.OwnerTx.Issuer as Bridge", "import Hetoimasia.Foundation.OwnerTx.Issuer (modifyCell)"] ["adapt = Bridge.fromIssuerSTM"])])
            ["Consumer.Adapter in consumer:lib:consumer " <> said]

    it "refuses a listed module of Foundation's main library that re-exports the representation's constructor" $
      refused
        (changed [("foundation/src/Hetoimasia/Foundation/OwnerTx.hs", haskell "module Hetoimasia.Foundation.OwnerTx (OwnerTx (..), commit) where" ["import Hetoimasia.Foundation.OwnerTx.Representation (OwnerTx (..))"] ["commit = undefined"])])
        ["re-exports the representation's OwnerTx(..)"]

    it "refuses a re-export through Cabal: reexported-modules, and a mixin naming the bridge" $
      forM_
        [ ["    reexported-modules: Hetoimasia.Foundation.OwnerTx.Issuer as Consumer.Bridge"]
        , ["    mixins: hetoimasia-foundation:owner-tx-issuer (Hetoimasia.Foundation.OwnerTx.Issuer as Consumer.Bridge)"]
        ]
        $ \extra →
          refused (changed [("consumer/consumer.cabal", consumerDescription extra)]) ["consumer.cabal (consumer:lib:consumer)"]

    it "refuses a stale entry: a listed module that imports no bridge module, and a listed component that does not exist" $ do
      refused
        (changed [("tools/validation/owner_tx_issuers.json", allowlist (baseImporters <> [("consumer:lib:consumer", "Consumer.Plain")]) baseDependents)])
        ["the listed module Consumer.Plain of consumer:lib:consumer imports no bridge module"]
      refused
        (changed [("tools/validation/owner_tx_issuers.json", allowlist (baseImporters <> [("consumer:lib:gone", "Gone")]) baseDependents)])
        ["the listed component consumer:lib:gone does not exist"]

    it "fails closed on what it cannot read: an import it cannot parse, a module without a source, a source of another kind, a conditional the reader rejects, a missing allowlist" $ do
      refused
        (changed [("consumer/src/Consumer/Plain.hs", haskell "module Consumer.Plain () where" ["import", "  Hetoimasia.Foundation.OwnerTx.Issuer"] [])])
        ["an import declaration it cannot read"]
      refused
        (changed [("consumer/consumer.cabal", consumerDescription ["    other-modules: Consumer.Missing"])])
        ["the module Consumer.Missing has no source in its source directories"]
      refused
        (changed [("consumer/consumer.cabal", consumerDescription ["    other-modules: Consumer.Generated"]), ("consumer/src/Consumer/Generated.hsc", "module Consumer.Generated () where\n")])
        ["a source of a kind the guard does not read (.hsc)"]
      (conditional, conditionalSaid) ←
        checked (changed [("consumer/consumer.cabal", consumerDescription ["    if impl(ghc >= 9.14)", "        build-depends: hetoimasia-foundation:owner-tx-issuer"])])
      conditional `shouldBe` ExitFailure 2
      conditionalSaid `shouldContain` "conditional or brace-delimited Cabal syntax is not supported"
      (missing, missingSaid) ← checked [entry | entry@(path, _) ← baseTree, path /= "tools/validation/owner_tx_issuers.json"]
      missing `shouldBe` ExitFailure 2
      missingSaid `shouldContain` "tools/validation/owner_tx_issuers.json cannot be read"

  describe "this repository" $ do
    it "passes the guard" $ inCheckout $ \checkout → do
      settings ← sanitizedEnvironment
      (result, _, errors) ← run (("PYTHONDONTWRITEBYTECODE", "1") : settings) checkout "python3" ["-I", "-W", "error", "tools/validation/owner_tx_guard.py", "check"]
      (result, errors) `shouldBe` (ExitSuccess, "")

    it "reads only what its catalog group lists as inputs, so a change anywhere it reads selects it" $ inCheckout $ \checkout → do
      settings ← sanitizedEnvironment
      (result, scope, errors) ← run (("PYTHONDONTWRITEBYTECODE", "1") : settings) checkout "python3" ["-I", "tools/validation/owner_tx_guard.py", "scope"]
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
