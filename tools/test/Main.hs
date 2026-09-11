module Main (main) where

import Control.Monad (void)
import Data.List (isPrefixOf)
import System.Directory (createDirectory, createFileLink, getCurrentDirectory, removeFile)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import Test.Hspec (describe, expectationFailure, hspec, it, shouldBe, shouldContain, shouldReturn)

data Repository = Repository
  { primary ∷ FilePath
  , documents ∷ FilePath
  , script ∷ FilePath
  , environment ∷ [(String, String)]
  }

main ∷ IO ()
main = hspec $ describe "Kanban documentation landing" $ do
  it "lands a regular AGENTS.md and a new design without unrelated staged work" $
    withRepository False $ \repo → do
      writeFile (documents repo </> "AGENTS.md") "updated agreements\n"
      writeFile (documents repo </> "docs/new_design.md") "ready design\n"
      writeFile (documents repo </> "docs/pending.md") "unfinished\n"
      void $ git repo (documents repo) ["add", "docs/pending.md"]
      before ← git repo (primary repo) ["rev-parse", "HEAD"]
      (planned, _, _) ← land repo ["-n", "-m", "Land designs", "AGENTS.md", "docs/new_design.md"]
      planned `shouldBe` ExitSuccess
      git repo (primary repo) ["rev-parse", "HEAD"] `shouldReturn` before
      (result, _, _) ← land repo ["-m", "Land designs", "AGENTS.md", "docs/new_design.md"]
      result `shouldBe` ExitSuccess
      git repo (primary repo) ["show", "origin/master:AGENTS.md"]
        `shouldReturn` "updated agreements\n"
      git repo (primary repo) ["show", "origin/master:docs/new_design.md"]
        `shouldReturn` "ready design\n"
      git repo (primary repo) ["show", "origin/master:docs/pending.md"]
        `shouldReturn` "pending seed\n"
      git repo (documents repo) ["show", ":docs/pending.md"]
        `shouldReturn` "unfinished\n"
      git repo (primary repo) ["status", "--porcelain"] `shouldReturn` ""

  it "keeps canonicalization for an intact tracked AGENTS.md alias" $
    withRepository True $ \repo → do
      writeFile (documents repo </> "AGENTS.md") "updated through alias\n"
      (result, _, _) ← land repo ["-m", "Land agreements", "AGENTS.md"]
      result `shouldBe` ExitSuccess
      git repo (primary repo) ["show", "origin/master:CLAUDE.md"]
        `shouldReturn` "updated through alias\n"
      git repo (primary repo) ["show", "origin/master:AGENTS.md"]
        `shouldReturn` "CLAUDE.md"

  it "refuses a staged replacement of an upstream alias without publishing" $
    withRepository True $ \repo → do
      before ← git repo (primary repo) ["rev-parse", "origin/master"]
      removeFile (documents repo </> "AGENTS.md")
      writeFile (documents repo </> "AGENTS.md") "replacement\n"
      void $ git repo (documents repo) ["add", "AGENTS.md"]
      (result, _, errors) ← land repo ["-m", "Invalid replacement", "AGENTS.md"]
      result `shouldBe` ExitFailure 6
      errors `shouldContain` "alias"
      git repo (primary repo) ["rev-parse", "origin/master"] `shouldReturn` before

withRepository ∷ Bool → (Repository → IO a) → IO a
withRepository alias action = do
  root ← getCurrentDirectory
  inherited ← getEnvironment
  withSystemTempDirectory "hetoimasia-workflow" $ \temporaryRoot → do
    let mainPath = temporaryRoot </> "main"
        docsPath = temporaryRoot </> "docs"
        origin = temporaryRoot </> "origin.git"
        settings =
          [ ("GIT_CONFIG_GLOBAL", "/dev/null")
          , ("GIT_CONFIG_NOSYSTEM", "1")
          , ("GIT_AUTHOR_NAME", "Workflow test")
          , ("GIT_AUTHOR_EMAIL", "workflow@example.invalid")
          , ("GIT_COMMITTER_NAME", "Workflow test")
          , ("GIT_COMMITTER_EMAIL", "workflow@example.invalid")
          , ("GIT_TERMINAL_PROMPT", "0")
          , ("LC_ALL", "C")
          ]
        names = map fst settings
        keep (name, _) = not ("GIT_" `isPrefixOf` name) && name `notElem` names
        repo = Repository mainPath docsPath (root </> "tools/docs_land.sh")
          (settings ++ filter keep inherited)
    createDirectory mainPath
    void $ git repo mainPath ["init", "--bare", origin]
    void $ git repo mainPath ["init", "-b", "master"]
    createDirectory (mainPath </> "docs")
    writeFile (mainPath </> "CLAUDE.md") "root seed\n"
    if alias
      then createFileLink "CLAUDE.md" (mainPath </> "AGENTS.md")
      else writeFile (mainPath </> "AGENTS.md") "agreements seed\n"
    writeFile (mainPath </> "docs/pending.md") "pending seed\n"
    void $ git repo mainPath ["add", "."]
    void $ git repo mainPath ["commit", "-m", "Seed"]
    void $ git repo mainPath ["remote", "add", "origin", origin]
    void $ git repo mainPath ["push", "-u", "origin", "master"]
    void $ git repo mainPath ["worktree", "add", "-b", "docs-wip", docsPath, "origin/master"]
    action repo

git ∷ Repository → FilePath → [String] → IO String
git repo path args = do
  (result, output, errors) ← run repo path "git" args
  case result of
    ExitSuccess → pure output
    ExitFailure _ → expectationFailure (unwords ("git" : args) ++ "\n" ++ errors) >> pure ""

land ∷ Repository → [String] → IO (ExitCode, String, String)
land repo args = run repo (primary repo) "bash" (script repo : args)

run ∷ Repository → FilePath → String → [String] → IO (ExitCode, String, String)
run repo path executable args = readCreateProcessWithExitCode
  (proc executable args) {cwd = Just path, env = Just (environment repo)} ""
