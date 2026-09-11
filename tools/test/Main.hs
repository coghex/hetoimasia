module Main (main) where

import Control.Monad (void)
import Sandbox (git, run, sanitizedEnvironment)
import System.Directory (createDirectory, createFileLink, getCurrentDirectory, removeFile)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (describe, hspec, it, shouldBe, shouldContain, shouldReturn)
import qualified DismissalStep
import qualified Execution
import qualified Reuse
import qualified ReviewGate
import qualified Timings
import qualified Validation

data Repository = Repository
  { primary ∷ FilePath
  , documents ∷ FilePath
  , script ∷ FilePath
  , environment ∷ [(String, String)]
  }

main ∷ IO ()
main = hspec $ do
  describe "Kanban documentation landing" $ do
    it "lands a regular AGENTS.md and a new design without unrelated staged work" $
      withRepository False $ \repo → do
        writeFile (documents repo </> "AGENTS.md") "updated agreements\n"
        writeFile (documents repo </> "docs/new_design.md") "ready design\n"
        writeFile (documents repo </> "docs/pending.md") "unfinished\n"
        void $ repoGit repo (documents repo) ["add", "docs/pending.md"]
        before ← repoGit repo (primary repo) ["rev-parse", "HEAD"]
        (planned, _, _) ← land repo ["-n", "-m", "Land designs", "AGENTS.md", "docs/new_design.md"]
        planned `shouldBe` ExitSuccess
        repoGit repo (primary repo) ["rev-parse", "HEAD"] `shouldReturn` before
        (result, _, _) ← land repo ["-m", "Land designs", "AGENTS.md", "docs/new_design.md"]
        result `shouldBe` ExitSuccess
        repoGit repo (primary repo) ["show", "origin/master:AGENTS.md"]
          `shouldReturn` "updated agreements\n"
        repoGit repo (primary repo) ["show", "origin/master:docs/new_design.md"]
          `shouldReturn` "ready design\n"
        repoGit repo (primary repo) ["show", "origin/master:docs/pending.md"]
          `shouldReturn` "pending seed\n"
        repoGit repo (documents repo) ["show", ":docs/pending.md"]
          `shouldReturn` "unfinished\n"
        repoGit repo (primary repo) ["status", "--porcelain"] `shouldReturn` ""

    it "keeps canonicalization for an intact tracked AGENTS.md alias" $
      withRepository True $ \repo → do
        writeFile (documents repo </> "AGENTS.md") "updated through alias\n"
        (result, _, _) ← land repo ["-m", "Land agreements", "AGENTS.md"]
        result `shouldBe` ExitSuccess
        repoGit repo (primary repo) ["show", "origin/master:CLAUDE.md"]
          `shouldReturn` "updated through alias\n"
        repoGit repo (primary repo) ["show", "origin/master:AGENTS.md"]
          `shouldReturn` "CLAUDE.md"

    it "refuses a staged replacement of an upstream alias without publishing" $
      withRepository True $ \repo → do
        before ← repoGit repo (primary repo) ["rev-parse", "origin/master"]
        removeFile (documents repo </> "AGENTS.md")
        writeFile (documents repo </> "AGENTS.md") "replacement\n"
        void $ repoGit repo (documents repo) ["add", "AGENTS.md"]
        (result, _, errors) ← land repo ["-m", "Invalid replacement", "AGENTS.md"]
        result `shouldBe` ExitFailure 6
        errors `shouldContain` "alias"
        repoGit repo (primary repo) ["rev-parse", "origin/master"] `shouldReturn` before

  Validation.spec
  Execution.spec
  Reuse.spec
  Timings.spec
  ReviewGate.spec
  DismissalStep.spec

withRepository ∷ Bool → (Repository → IO a) → IO a
withRepository alias action = do
  root ← getCurrentDirectory
  settings ← sanitizedEnvironment
  withSystemTempDirectory "hetoimasia-workflow" $ \temporaryRoot → do
    let mainPath = temporaryRoot </> "main"
        docsPath = temporaryRoot </> "docs"
        origin = temporaryRoot </> "origin.git"
        repo = Repository mainPath docsPath (root </> "tools/docs_land.sh") settings
    createDirectory mainPath
    void $ repoGit repo mainPath ["init", "--bare", origin]
    void $ repoGit repo mainPath ["init", "-b", "master"]
    createDirectory (mainPath </> "docs")
    writeFile (mainPath </> "CLAUDE.md") "root seed\n"
    if alias
      then createFileLink "CLAUDE.md" (mainPath </> "AGENTS.md")
      else writeFile (mainPath </> "AGENTS.md") "agreements seed\n"
    writeFile (mainPath </> "docs/pending.md") "pending seed\n"
    void $ repoGit repo mainPath ["add", "."]
    void $ repoGit repo mainPath ["commit", "-m", "Seed"]
    void $ repoGit repo mainPath ["remote", "add", "origin", origin]
    void $ repoGit repo mainPath ["push", "-u", "origin", "master"]
    void $ repoGit repo mainPath ["worktree", "add", "-b", "docs-wip", docsPath, "origin/master"]
    action repo

repoGit ∷ Repository → FilePath → [String] → IO String
repoGit repo = git (environment repo)

land ∷ Repository → [String] → IO (ExitCode, String, String)
land repo args = run (environment repo) (primary repo) "bash" (script repo : args)
