-- | Shared helpers for workflow tests that drive real tools against temporary
-- Git repositories.
module Sandbox
  ( sanitizedEnvironment
  , run
  , git
  , writeFixtureFile
  , workflowStepBody
  , fixtureIgnore
  , fixtureGenerated
  ) where

import Data.List (isPrefixOf)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import Test.Hspec (expectationFailure, shouldBe)

-- | An environment with the caller's Git and locale configuration removed, so a
-- temporary repository behaves identically on every machine.
sanitizedEnvironment ∷ IO [(String, String)]
sanitizedEnvironment = do
  inherited ← getEnvironment
  let settings =
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
  pure (settings ++ filter keep inherited)

run ∷ [(String, String)] → FilePath → String → [String] → IO (ExitCode, String, String)
run environment path executable args = readCreateProcessWithExitCode
  (proc executable args) {cwd = Just path, env = Just environment} ""

-- | Run Git, failing the example with its diagnostics when it does not succeed.
git ∷ [(String, String)] → FilePath → [String] → IO String
git environment path args = do
  (result, output, errors) ← run environment path "git" args
  case result of
    ExitSuccess → pure output
    ExitFailure code →
      expectationFailure
        (unwords ("git" : args) ++ " exited " ++ show code ++ "\n" ++ output ++ errors)
        >> pure ""

-- | Write one fixture file, creating the directories it needs.
writeFixtureFile ∷ FilePath → FilePath → String → IO ()
writeFixtureFile root relative contents = do
  let target = root </> relative
  createDirectoryIfMissing True (takeDirectory target)
  writeFile target contents

-- | The literal @run@ block of one named step, read from the workflow itself.
--
-- Extracting the shipped shell is what lets an example assert against the file
-- the pipeline actually loads rather than a restatement of it, and it is the
-- only way to reach the boundaries a hosted step meets — an API that does not
-- answer, a response nothing can read — which do not occur on demand against a
-- real repository.
--
-- Deliberately dependency-free: a test that needed a YAML library installed to
-- read a workflow would be skipped exactly when it mattered. The cost is that
-- the extracted body is run as plain Bash, so a step this is used on must take
-- its @${{ }}@ values through @env:@ rather than interpolating them into the
-- shell, which Bash reads as a bad substitution.
workflowStepBody ∷ FilePath → FilePath → String → IO String
workflowStepBody checkout workflow name = do
  (status, stdout', errors) ← run [] checkout "python3" ["-c", stepExtractor, workflow, name]
  (status, errors) `shouldBe` (ExitSuccess, "")
  pure stdout'

stepExtractor ∷ String
stepExtractor =
  unlines
    [ "import sys"
    , "path, wanted = sys.argv[1], sys.argv[2]"
    , "lines = open(path, encoding='utf-8').read().splitlines()"
    , "start = next((i for i, l in enumerate(lines) if l.strip() == '- name: ' + wanted), None)"
    , "if start is None: raise SystemExit('no step named %r in %s' % (wanted, path))"
    , "run = next((i for i in range(start, len(lines)) if lines[i].strip() == 'run: |'), None)"
    , "if run is None: raise SystemExit('step %r has no run block' % wanted)"
    , "indent = len(lines[run]) - len(lines[run].lstrip()) + 2"
    , "body = []"
    , "for line in lines[run + 1:]:"
    , "    if line.strip() and len(line) - len(line.lstrip()) < indent: break"
    , "    body.append(line[indent:] if len(line) >= indent else line)"
    , "sys.stdout.write('\\n'.join(body).rstrip() + '\\n')"
    ]

-- | The operational artifacts a fixture repository's own examples write beside
-- the tree they validate: plans, applicability documents, request bodies,
-- receipts, and the stub GitHub these examples answer from.
--
-- Declaring them keeps an example's own `git add -A` from committing a plan or
-- a receipt into the tree it is about, the way a real repository keeps its
-- generated files out of one. It is deliberately not what makes the runner
-- tolerate them: the runner consults no ignore rule at all, and answers for an
-- untracked file by asking whether the candidate's own classification says some
-- group would read it.
fixtureIgnore ∷ String
fixtureIgnore =
  unlines
    [ "/*.json"
    , "/*.txt"
    , "/receipt-*"
    , "/child.pid"
    , "/receipts/"
    , "/gh-stub/"
    ]

-- | The same layout, as the catalog declaration the runner actually consults.
--
-- A fixture repository's examples write their plans, receipts, request bodies,
-- and stub GitHub beside the tree they validate, exactly as a real run writes
-- its plan and receipts into the checkout it is validating. The runner exempts
-- what the candidate's catalog declares here and nothing else, so this is what
-- keeps an ordinary example running — deliberately not the `.gitignore` beside
-- it, which Git reads and the runner does not.
fixtureGenerated ∷ String
fixtureGenerated =
  "[\"*.json\", \"receipts/\", \"gh-stub/\", \"fixtures/\", \"body.txt\", \"child.pid\", \"receipt-*\"]"
