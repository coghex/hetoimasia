-- | Hspec coverage for the issuer guard of the ownership transactions (#721; the design's "Approved amendment · Textual
-- issuer guard").
--
-- @owner-tx-guard@ scans every @.cabal@ and @cabal.project*@ file at any depth, split into stanzas by Cabal-syntax's
-- @readFields@ alone, for the protected texts, and requires each to lie in a stanza
-- @tools/validation/owner-tx-issuers.fields@ lists. Every example runs the production guard against a temporary tree of
-- text: no fixture is built. Each negative example asserts the guard's own diagnostic.
--
-- The last group runs the guard on this repository: it passes, it reads only what its catalog group lists as inputs, and
-- the planner selects that group for a change to a Vulkan-only package's source, to a package description, to a project
-- file or its import, to a manifest outside the projects, and to the allowlist.
module OwnerTxGuard (spec) where

import Control.Exception (finally)
import Control.Monad (forM_, void)
import Data.List (isPrefixOf)
import Json (Json (..), asArray, asString, entryFor, field, parseJson)
import Sandbox (git, run, sanitizedEnvironment, writeFixtureFile)
import System.Directory (copyFile, createDirectoryIfMissing, createDirectoryLink, doesFileExist, getCurrentDirectory, getPermissions, setOwnerWritable, setPermissions)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, expectationFailure, it, pendingWith, shouldBe, shouldContain, shouldSatisfy)

-- ---------------------------------------------------------------------------
-- The fixture tree

header ∷ String → [String]
header name = ["cabal-version: 3.4", "name: " <> name, "version: 0.1.0.0", "build-type: Simple", ""]

-- | Foundation's manifest: the bridge's three stanzas, as the real one has them.
foundation ∷ String
foundation =
  unlines $
    header "hetoimasia-foundation"
      <> ["-- The issuer bridge, owner-tx-issuer, is guarded; a comment never counts.", ""]
      <> ["library", "    exposed-modules: Hetoimasia.Foundation.OwnerTx", "    build-depends: base, hetoimasia-foundation:internal", ""]
      <> ["library internal", "    visibility: private", "    exposed-modules:", "        Hetoimasia.Foundation.OwnerTx.Representation", "        Hetoimasia.Foundation.OwnerTx.Cells", ""]
      <> ["library owner-tx-issuer", "    visibility: public", "    exposed-modules: Hetoimasia.Foundation.OwnerTx.Issuer", "    build-depends: base, hetoimasia-foundation:internal", ""]
      <> ["test-suite foundation-tests", "    type: exitcode-stdio-1.0", "    main-is: Main.hs", "    build-depends: base, hetoimasia-foundation, hetoimasia-foundation:owner-tx-issuer"]

-- | A consumer's manifest: a library mentioning nothing protected, with these extra lines in it, then these stanzas.
consumer ∷ [String] → [String] → String
consumer libraryExtra after =
  unlines $
    header "consumer"
      <> ["library", "    exposed-modules: Consumer.Adapter", "    build-depends: base, hetoimasia-foundation"]
      <> libraryExtra
      <> after

allowed ∷ FilePath → String → [String]
allowed file stanza = ["entry", "  file: " <> file, "  stanza: " <> stanza, "  reason: a fixture", ""]

foundationEntries ∷ [String]
foundationEntries =
  concat [allowed "foundation/hetoimasia-foundation.cabal" stanza | stanza ← ["library internal", "library owner-tx-issuer", "test-suite foundation-tests"]]

allowlistFile ∷ FilePath
allowlistFile = "tools/validation/owner-tx-issuers.fields"

baseTree ∷ [(FilePath, String)]
baseTree =
  [ ("cabal.project", "import: cabal.project.common\npackages:\n  foundation\n  consumer\n")
  , ("cabal.project.vulkan", "import: cabal.project.common\npackages:\n  foundation\n  consumer\n")
  , ("cabal.project.common", "jobs: $ncpus\npackage consumer\n  ghc-options: -Wall\n")
  , ("foundation/hetoimasia-foundation.cabal", foundation)
  , ("consumer/consumer.cabal", consumer [] [])
  , (allowlistFile, unlines foundationEntries)
  ]

changed ∷ [(FilePath, String)] → [(FilePath, String)]
changed updates = [file | file@(path, _) ← baseTree, path `notElem` map fst updates] <> updates

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

-- | The guard could not read the allowlist, saying this.
unreadableAllowlist ∷ String → String → IO ()
unreadableAllowlist text said = do
  (result, errors) ← checked (changed [(allowlistFile, text)])
  result `shouldBe` ExitFailure 2
  errors `shouldContain` (allowlistFile <> " cannot be read: " <> said)

unlisted ∷ FilePath → Int → String → String → String
unlisted file line text stanza = file <> ":" <> show line <> ": " <> text <> " in the stanza " <> stanza <> ", which the allowlist does not list"

spec ∷ Spec
spec = describe "The issuer bridge's textual guard (tools/owner-tx-guard)" $ do
  describe "a fixture tree" $ do
    it "accepts protected text in the listed stanzas, a listed project stanza, comments and near-misses" $ do
      checked baseTree >>= (`shouldBe` (ExitSuccess, ""))
      checked
        ( changed
            [ ("cabal.project.common", "jobs: $ncpus\npackage consumer\n  ghc-options: -Wall\n  -- owner-tx-issuer in a comment\n  flags: +owner-tx-issuers +owner-tx-issuer_x +xowner-tx-issuer\n")
            , ("consumer/consumer.cabal", consumer ["    -- build-depends: hetoimasia-foundation:owner-tx-issuer", "    other-modules: Hetoimasia.Foundation.OwnerTx.IssuerX"] [])
            ]
        )
        >>= (`shouldBe` (ExitSuccess, ""))
      checked
        ( changed
            [ ("cabal.project.vulkan", "import: cabal.project.common\npackages:\n  foundation\n  consumer\npackage consumer\n  ghc-options: -package hetoimasia-foundation:owner-tx-issuer\n")
            , (allowlistFile, unlines (foundationEntries <> allowed "cabal.project.vulkan" "package consumer"))
            ]
        )
        >>= (`shouldBe` (ExitSuccess, ""))

    it "refuses an unlisted match in build-depends, mixins, reexported-modules and ghc-options, ASCII case-insensitively" $ do
      refused (changed [("consumer/consumer.cabal", consumer ["    build-depends: hetoimasia-foundation:owner-tx-issuer"] [])]) [unlisted "consumer/consumer.cabal" 9 "owner-tx-issuer" "library"]
      refused (changed [("consumer/consumer.cabal", consumer ["    mixins: hetoimasia-foundation:owner-tx-issuer (Hetoimasia.Foundation.OwnerTx.Issuer as Consumer.Bridge)"] [])]) [unlisted "consumer/consumer.cabal" 9 "owner-tx-issuer" "library", unlisted "consumer/consumer.cabal" 9 "Hetoimasia.Foundation.OwnerTx.Issuer" "library"]
      refused (changed [("consumer/consumer.cabal", consumer ["    reexported-modules: Hetoimasia.Foundation.OwnerTx.Representation as Consumer.Raw"] [])]) [unlisted "consumer/consumer.cabal" 9 "Hetoimasia.Foundation.OwnerTx.Representation" "library"]
      refused (changed [("consumer/consumer.cabal", consumer ["    ghc-options: -package-id hetoimasia-foundation-0.1.0.0-inplace-owner-tx-issuer"] [])]) [unlisted "consumer/consumer.cabal" 9 "owner-tx-issuer" "library"]
      refused (changed [("consumer/consumer.cabal", consumer ["    build-depends: HETOIMASIA-FOUNDATION:Owner-Tx-Issuer"] [])]) [unlisted "consumer/consumer.cabal" 9 "owner-tx-issuer" "library"]

    it "refuses an unlisted match in a common stanza, a section header, a continuation line and an unreachable branch" $ do
      refused
        (changed [("consumer/consumer.cabal", consumer ["    import: bridge"] ["", "common bridge", "    build-depends: hetoimasia-foundation:owner-tx-issuer"])])
        [unlisted "consumer/consumer.cabal" 12 "owner-tx-issuer" "common bridge"]
      refused (changed [("consumer/consumer.cabal", consumer [] ["", "library owner-tx-issuer", "    exposed-modules: Consumer.Bridge"])]) [unlisted "consumer/consumer.cabal" 10 "owner-tx-issuer" "library owner-tx-issuer"]
      refused
        (changed [("consumer/consumer.cabal", consumer ["    build-depends:", "        base,", "        hetoimasia-foundation:owner-tx-issuer"] [])])
        [unlisted "consumer/consumer.cabal" 11 "owner-tx-issuer" "library"]
      refused
        (changed [("consumer/consumer.cabal", consumer ["    if os(linux) && os(darwin)", "        build-depends: hetoimasia-foundation:owner-tx-issuer"] [])])
        [unlisted "consumer/consumer.cabal" 10 "owner-tx-issuer" "library"]

    it "refuses an unlisted match in a project file, at the top level, and in a manifest no project lists" $ do
      refused
        (changed [("cabal.project.vulkan", "import: cabal.project.common\npackages:\n  foundation\n  consumer\nif os(darwin)\n  package consumer\n    ghc-options: -package hetoimasia-foundation:owner-tx-issuer\n")])
        [unlisted "cabal.project.vulkan" 7 "owner-tx-issuer" "if os ( darwin )"]
      refused (changed [("cabal.project.common", "jobs: $ncpus\nconstraints: hetoimasia-foundation:owner-tx-issuer >=0\n")]) ["cabal.project.common:2: owner-tx-issuer at the top level, outside any listed stanza"]
      refused (changed [("consumer/consumer.cabal", "synopsis: wraps Hetoimasia.Foundation.OwnerTx.Issuer\n" <> consumer [] [])]) ["consumer/consumer.cabal:1: Hetoimasia.Foundation.OwnerTx.Issuer at the top level, outside any listed stanza"]
      refused
        (changed [("stray/nested/stray.cabal", unlines (header "stray" <> ["executable stray", "    main-is: Main.hs", "    build-depends: base, hetoimasia-foundation:owner-tx-issuer"]))])
        [unlisted "stray/nested/stray.cabal" 8 "owner-tx-issuer" "executable stray"]

    it "refuses a stale entry and an entry that names more than one stanza" $ do
      refused (changed [(allowlistFile, unlines (foundationEntries <> allowed "consumer/consumer.cabal" "library"))]) ["consumer/consumer.cabal: the allowlist entry for library is stale: the stanza mentions no protected text"]
      refused (changed [(allowlistFile, unlines (foundationEntries <> allowed "consumer/consumer.cabal" "library adapters"))]) ["consumer/consumer.cabal: the allowlist entry for library adapters is stale: the file has no stanza with that header"]
      refused (changed [(allowlistFile, unlines (foundationEntries <> allowed "gone/gone.cabal" "library"))]) ["gone/gone.cabal: the allowlist entry for library is stale: no scanned file has that path"]
      refused
        ( changed
            [ ("cabal.project.vulkan", "import: cabal.project.common\npackages:\n  foundation\n  consumer\npackage consumer\n  ghc-options: -package hetoimasia-foundation:owner-tx-issuer\npackage consumer\n  flags: +owner-tx-issuer\n")
            , (allowlistFile, unlines (foundationEntries <> allowed "cabal.project.vulkan" "package consumer"))
            ]
        )
        ["cabal.project.vulkan: the allowlist entry for package consumer names 2 stanzas (lines 5, 7)"]

    it "refuses a duplicate or malformed allowlist entry, and a missing allowlist" $ do
      unreadableAllowlist (unlines (foundationEntries <> allowed "foundation/hetoimasia-foundation.cabal" "library  internal")) "an entry listed more than once: foundation/hetoimasia-foundation.cabal (library internal)"
      unreadableAllowlist (unlines (foundationEntries <> ["entry", "  file: consumer/consumer.cabal", "  stanza: library"])) "an entry needs exactly one nonempty file, stanza and reason, and nothing else"
      unreadableAllowlist (unlines (foundationEntries <> ["entry", "  file: consumer/consumer.cabal", "  stanza: library", "  reason: x", "  component: consumer:lib:consumer"])) "an entry needs exactly one nonempty file, stanza and reason, and nothing else"
      unreadableAllowlist (unlines (foundationEntries <> ["entry", "  file: consumer/consumer.cabal", "  file: other.cabal", "  stanza: library", "  reason: x"])) "an entry needs exactly one nonempty file, stanza and reason, and nothing else"
      unreadableAllowlist (unlines ("version: 4" : foundationEntries)) "the field version is outside an entry section"
      unreadableAllowlist (unlines (foundationEntries <> allowed "docs/tool sets/cabal.project" "package consumer")) "unsupported: a file or stanza with a space or a quote"
      unreadableAllowlist (unlines (foundationEntries <> allowed "cabal.project" "package \"a b\"")) "unsupported: a file or stanza with a space or a quote"
      unreadableAllowlist (unlines (["dependent", "  component: consumer:lib:consumer", "  reason: x", ""] <> foundationEntries)) "the section dependent is not an entry section with no arguments"
      (missing, missingSaid) ← checked [file | file@(path, _) ← baseTree, path /= allowlistFile]
      missing `shouldBe` ExitFailure 2
      missingSaid `shouldContain` (allowlistFile <> " cannot be read: it does not exist")

    it "refuses a quoted section argument and a symbolic link as unsupported, never following the link" $ do
      refused
        (changed [("cabal.project.common", "jobs: $ncpus\npackage \"consumer\"\n  ghc-options: -Wall\n")])
        ["cabal.project.common: unsupported: a quoted section argument at line 2"]
      withSystemTempDirectory "hetoimasia-owner-tx-outside" $ \outside → do
        writeFixtureFile outside "elsewhere/elsewhere.cabal" (unlines (header "elsewhere" <> ["library", "    build-depends: hetoimasia-foundation:owner-tx-issuer"]))
        withSystemTempDirectory "hetoimasia-owner-tx-guard" $ \directory → do
          forM_ baseTree (uncurry (writeFixtureFile directory))
          createDirectoryLink (outside </> "elsewhere") (directory </> "linked")
          settings ← sanitizedEnvironment
          (result, _, errors) ← run settings directory "owner-tx-guard" ["check", "--root", directory]
          (result, errors) `shouldBe` (ExitFailure 1, "owner_tx_guard: linked: unsupported: a symbolic link, which the guard never follows\n")

    it "refuses input Cabal's lexer cannot split, or splits with an ambiguous boundary" $ do
      refused (changed [("consumer/consumer.cabal", "library {\n  build-depends: base }\n")]) ["consumer/consumer.cabal: unreadable: Cabal's lexer cannot split it"]
      refused (changed [("consumer/consumer.cabal", "library\n\tbuild-depends: base\n")]) ["consumer/consumer.cabal: unreadable: an ambiguous stanza boundary (LexWarningTab) at line 2"]
      refused (changed [("consumer/consumer.cabal", "library foo\n  build-depends: base\n library-bad\n")]) ["consumer/consumer.cabal: unreadable: an ambiguous stanza boundary (LexInconsistentIndentation) at line 3"]

    it "skips version-control metadata and the catalog's generated directories, and nothing else" $ do
      let copy path = (path, foundation `withExtra` "    build-depends: hetoimasia-foundation:owner-tx-issuer")
          withExtra text line = text <> line <> "\n"
      checked (changed [copy ".git/modules/x/x.cabal", copy "dist-newstyle/src/x/x.cabal", copy ".worktrees/copy/packages/foundation/hetoimasia-foundation.cabal", copy "dist-vulkan/x.cabal"]) >>= (`shouldBe` (ExitSuccess, ""))
      refused (changed [copy "packages/dist-newstyle/x.cabal"]) [unlisted "packages/dist-newstyle/x.cabal" 15 "Hetoimasia.Foundation.OwnerTx.Representation" "library internal"]

    it "checks a read-only checkout without writing into it" $
      withSystemTempDirectory "hetoimasia-owner-tx-readonly" $ \directory → do
        forM_ baseTree (uncurry (writeFixtureFile directory))
        settings ← sanitizedEnvironment
        before ← getPermissions directory
        setPermissions directory (setOwnerWritable False before)
        (result, _, errors) ← run settings directory "owner-tx-guard" ["check", "--root", directory] `finally` setPermissions directory before
        (result, errors) `shouldBe` (ExitSuccess, "")

  describe "this repository" $ do
    it "passes the guard" $ inCheckoutWith "packages/foundation/hetoimasia-foundation.cabal" $ \checkout → do
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
            | '*' `elem` entry && '/' `notElem` entry = glob entry (reverse (takeWhile (/= '/') (reverse path)))
            | not (null entry) && last entry == '/' = path == init entry || entry `isPrefixOf` path
            | otherwise = path == entry
          -- the catalog's basename classes: '*' matches any run of characters
          glob pattern text = case pattern of
            [] → null text
            '*' : rest → any (glob rest) [drop n text | n ← [0 .. length text]]
            c : rest → case text of
              t : more → c == t && glob rest more
              [] → False
          missing =
            [ path
            | line ← lines scope
            , let path = drop 1 (dropWhile (/= ' ') line)
            , not (null path)
            , not (covered path || covered (path <> "/"))
            ]
      inputs `shouldSatisfy` (/= Nothing)
      missing `shouldBe` []

    it "selects its group for a change to a Vulkan-only package's source, to a package description, to a project file or its import, to a manifest outside the projects, and to the allowlist" $ inCheckout $ \checkout → do
      settings ← sanitizedEnvironment
      files ← lines <$> git settings checkout ["-c", "safe.directory=*", "ls-files", "*.cabal", "cabal.project*", "tools/validation/catalog.json"]
      let changedPaths =
            [ "packages/gpu-vulkan/native/src/Hetoimasia/GPU/Vulkan/Native/Uploads.hs"
            , "packages/foundation/hetoimasia-foundation.cabal"
            , "cabal.project"
            , "cabal.project.vulkan"
            , "cabal.project.common"
            , "cabal.project.cpu"
            , "docs/toolchain/binding-bundle-linux/cabal.project"
            , "docs/toolchain/binding-bundle-darwin/binding-qualification.cabal"
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

    it "selects its group and changes the input identity for a project file anywhere, however it is spelled, another group's prefix included" $ inCheckout $ \checkout → do
      settings ← sanitizedEnvironment
      files ← lines <$> git settings checkout ["-c", "safe.directory=*", "ls-files", "*.cabal", "cabal.project*", "tools/validation/catalog.json"]
      forM_ ["cabal.project.notes.md", "docs/elsewhere/cabal.project", "docs/elsewhere/stray.cabal", "tools/terrain-storage/cabal.project.extra"] $ \path →
        withSystemTempDirectory "hetoimasia-owner-tx-plan" $ \directory → do
          forM_ [file | file ← files, not ("docs/" `isPrefixOf` file)] $ \file → do
            createDirectoryIfMissing True (directory </> takeDirectory file)
            copyFile (checkout </> file) (directory </> file)
          writeFixtureFile directory path "-- before\n"
          void $ git settings directory ["init", "-q", "-b", "master"]
          void $ git settings directory ["add", "-A", "."]
          void $ git settings directory ["commit", "-q", "-m", "base"]
          base ← takeWhile (/= '\n') <$> git settings directory ["rev-parse", "HEAD"]
          appendFile (directory </> path) "-- after\n"
          void $ git settings directory ["commit", "-q", "-a", "-m", "head"]
          let plan revision = run settings checkout "python3" [checkout </> "tools/validation/plan.py", "--repo-root", directory, "--base", base, "--head", revision, "--json"]
          (result, output, errors) ← plan "HEAD"
          (result, errors) `shouldBe` (ExitSuccess, "")
          (baseResult, baseOutput, baseErrors) ← plan base
          (baseResult, baseErrors) `shouldBe` (ExitSuccess, "")
          case parseJson output >>= field "groups" >>= entryFor "id" "test.owner-tx-guard" of
            Nothing → expectationFailure ("the plan for " <> path <> " has no test.owner-tx-guard group")
            Just entry → (field "selected" entry, field "reason" entry) `shouldBe` (Just (JBool True), Just (JString "affected"))
          (parseJson output >>= field "changed_paths" >>= entryFor "path" path >>= field "classification") `shouldSatisfy` (/= Just (JString "non-affecting"))
          (parseJson output >>= field "input_identity") `shouldSatisfy` (\identity → identity /= Nothing && identity /= (parseJson baseOutput >>= field "input_identity"))

-- | Run an example against the checkout, or leave it pending where this is not a checkout of the whole repository.
inCheckout ∷ (FilePath → IO ()) → IO ()
inCheckout = inCheckoutWith "cabal.project"

-- | Run an example against the checkout, or leave it pending where this checkout-only file is absent.
inCheckoutWith ∷ FilePath → (FilePath → IO ()) → IO ()
inCheckoutWith marker example = do
  checkout ← getCurrentDirectory
  present ← doesFileExist (checkout </> marker)
  if present then example checkout else pendingWith ("this is not a checkout of the whole repository (no " <> marker <> ")")
