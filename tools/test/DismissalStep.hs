-- | Hspec coverage for the label mutation itself.
--
-- The job that removes @reviewed:approve@ holds the only write token in this
-- repository's workflows, so it checks nothing out and runs no repository
-- code: a helper from the pull request's own head would be executing beside
-- that token, and neither a sparse checkout nor unpersisted credentials would
-- make it trusted. Its guard is therefore inline shell.
--
-- Inline is not a reason to leave it unproven. These examples extract that
-- step's own @run@ body out of @.github/workflows/review-gate.yml@ and execute
-- it against a stubbed @gh@, so what is asserted is the shell that actually
-- ships rather than a restatement of it. The stub is what makes the races
-- reachable: a head that advances between the decision and the write, and a
-- label read that fails rather than coming back empty, do not occur on demand
-- against a real repository.
module DismissalStep (spec) where

import Control.Monad (unless)
import Data.List (isInfixOf)
import Sandbox (run, sanitizedEnvironment, writeFixtureFile)
import System.Directory (createDirectoryIfMissing, doesFileExist, getCurrentDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, shouldBe, shouldContain, shouldNotContain, shouldSatisfy)

-- | The head the push was announced for, and the one a later push moved it to.
pushedHead, newerHead ∷ String
pushedHead = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
newerHead = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

approval ∷ String
approval = "reviewed:approve"

-- | How the stubbed repository answers this run.
data Repository = Repository
  { liveHead ∷ String
  , labelsAfter ∷ [String]
  , labelReadFails ∷ Bool
  }

-- | A repository that behaves: the head is the pushed one, and the removal took.
settled ∷ Repository
settled = Repository pushedHead [] False

spec ∷ Spec
spec = describe "Stale approval mutation" $ do
  it "removes the approval a content-changing push invalidated" $
    withStep settled "remove" "removed" $ \(result, _, _) calls → do
      result `shouldBe` ExitSuccess
      calls `shouldSatisfy` any (isInfixOf "--remove-label")

  it "writes nothing when the decision was to keep the approval" $
    withStep settled {labelsAfter = [approval]} "none" "kept" $ \(result, _, _) calls → do
      result `shouldBe` ExitSuccess
      unwords calls `shouldNotContain` "--remove-label"

  it "refuses to write when the head advanced after the decision" $
    -- The staged failure the guard exists for. The decision was made for the
    -- pushed head and was right then; by the time this job runs, a newer push
    -- has landed. Removing approval now would strip it from a head neither this
    -- run nor its reviewer ever examined.
    withStep settled {liveHead = newerHead, labelsAfter = [approval]} "remove" "removed" $
      \(result, output, _) calls → do
        result `shouldSatisfy` (/= ExitSuccess)
        -- A workflow command is an annotation on stdout, which is where the
        -- job's own diagnostic lands.
        output `shouldContain` "::error::"
        output `shouldContain` "superseded head"
        unwords calls `shouldNotContain` "--remove-label"

  it "fails when the label survived the removal" $
    withStep settled {labelsAfter = [approval]} "remove" "removed" $ \(result, output, _) _ → do
      result `shouldSatisfy` (/= ExitSuccess)
      output `shouldContain` "still attached after the removal"

  it "fails rather than reading a failed label lookup as an absent label" $
    -- A failed read is not an empty one. Left to a pipeline in an `if`
    -- condition, Bash would exempt the failure from `set -e` and this job would
    -- report a confirmed removal it never observed.
    withStep settled {labelReadFails = True} "remove" "removed" $ \(result, output, _) _ → do
      result `shouldSatisfy` (/= ExitSuccess)
      output `shouldContain` "could not be read back"

  it "tolerates an unrelated label left on the pull request" $
    withStep settled {labelsAfter = ["ci"]} "remove" "removed" $ \(result, _, _) _ →
      result `shouldBe` ExitSuccess

-- ---------------------------------------------------------------------------
-- Running the shipped step

-- | Extract the step's own shell, stub `gh`, and run it.
withStep
  ∷ Repository
  → String
  → String
  → ((ExitCode, String, String) → [String] → IO a)
  → IO a
withStep repository action expected assertion = do
  checkout ← getCurrentDirectory
  inherited ← sanitizedEnvironment
  body ← stepBody checkout "Apply the decision"
  withSystemTempDirectory "hetoimasia-dismissal" $ \directory → do
    let binPath = directory </> "bin"
    createDirectoryIfMissing True binPath
    writeFixtureFile directory "head" (liveHead repository ++ "\n")
    writeFixtureFile directory "labels" (unlines (labelsAfter repository))
    unless (not (labelReadFails repository)) $
      writeFixtureFile directory "labels-fail" ""
    writeFixtureFile directory "summary" ""
    writeFixtureFile directory "step.sh" body
    writeFixtureFile binPath "gh" (stub directory)
    _ ← run inherited directory "chmod" ["+x", binPath </> "gh"]
    let settings =
          [ ("PATH", binPath ++ ":/usr/bin:/bin:/usr/sbin:/sbin")
          , ("GH_TOKEN", "stub-token")
          , ("REPOSITORY", "coghex/hetoimasia")
          , ("NUMBER", "16")
          , ("EVENT_HEAD", pushedHead)
          , ("BEFORE", "cccccccccccccccccccccccccccccccccccccccc")
          , ("ACTION", action)
          , ("EXPECTED", expected)
          , ("REASON", "a fixture decision")
          , ("LABEL", approval)
          , ("GITHUB_STEP_SUMMARY", directory </> "summary")
          ]
              ++ filter (\(name, _) → name `notElem` ["PATH", "GH_TOKEN"]) inherited
    outcome ← run settings directory "bash" [directory </> "step.sh"]
    logged ← doesFileExist (directory </> "calls")
    calls ← if logged then lines <$> readFile (directory </> "calls") else pure []
    assertion outcome calls

-- | The literal @run@ block of one named step, read from the workflow itself.
--
-- Deliberately dependency-free: the point is to assert against the file the
-- pipeline actually loads, and a test that needed a YAML library installed to
-- do so would be skipped exactly when it mattered.
stepBody ∷ FilePath → String → IO String
stepBody checkout name = do
  (result, output, errors) ←
    run [] checkout "python3" ["-c", extractor, ".github/workflows/review-gate.yml", name]
  (result, errors) `shouldBe` (ExitSuccess, "")
  pure output

extractor ∷ String
extractor =
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

-- | A `gh` that records every call and answers from the fixture directory.
stub ∷ FilePath → String
stub directory =
  unlines
    [ "#!/bin/sh"
    , "printf '%s\\n' \"$*\" >> " ++ show (directory </> "calls")
    , "case \"$1 $2\" in"
    , "  'api '*) cat " ++ show (directory </> "head") ++ " ;;"
    , "  'pr edit') exit 0 ;;"
    , "  'pr view')"
    , "    if [ -f " ++ show (directory </> "labels-fail") ++ " ]; then"
    , "      echo 'stub: the labels could not be read' >&2"
    , "      exit 1"
    , "    fi"
    , "    cat " ++ show (directory </> "labels")
    , "    ;;"
    , "  *) echo \"stub: unexpected gh $*\" >&2; exit 64 ;;"
    , "esac"
    ]
