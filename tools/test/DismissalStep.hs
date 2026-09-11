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
--
-- The same step also publishes the provenance of an approval that outlived a
-- code push. That summary is the only place a reader can see which review is
-- being carried and which revisions the replay was decided from, so it is
-- asserted here rather than treated as decoration.
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

-- | The provenance a completed replay hands this job to publish.
approvedHead, incorporatedBase, replayTree ∷ String
approvedHead = "cccccccccccccccccccccccccccccccccccccccc"
incorporatedBase = "dddddddddddddddddddddddddddddddddddddddd"
replayTree = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

approval ∷ String
approval = "reviewed:approve"

-- | How the stubbed repository and the decision before it answer this run.
data Repository = Repository
  { liveHead ∷ String
  , labelsAfter ∷ [String]
  , labelReadFails ∷ Bool
  , replay ∷ String
  , replayReached ∷ Bool
  , decision ∷ String
  }

-- | A repository that behaves: the head is the pushed one, the removal took,
-- and the replay reached its inputs and refused to carry the approval.
settled ∷ Repository
settled = Repository pushedHead [] False "strip" True "success"

-- | The outcome of running the shipped step: its own result, every `gh` call it
-- made, and the job summary it published.
data Outcome = Outcome
  { result ∷ ExitCode
  , output ∷ String
  , calls ∷ [String]
  , summary ∷ String
  }

spec ∷ Spec
spec = describe "Stale approval mutation" $ do
  it "removes the approval a content-changing push invalidated" $
    withStep settled "remove" "removed" $ \outcome → do
      result outcome `shouldBe` ExitSuccess
      calls outcome `shouldSatisfy` any (isInfixOf "--remove-label")

  it "writes nothing when the decision was to keep the approval" $
    withStep settled {labelsAfter = [approval]} "none" "kept" $ \outcome → do
      result outcome `shouldBe` ExitSuccess
      unwords (calls outcome) `shouldNotContain` "--remove-label"

  it "refuses to write when the head advanced after the decision" $
    -- The staged failure the guard exists for. The decision was made for the
    -- pushed head and was right then; by the time this job runs, a newer push
    -- has landed. Removing approval now would strip it from a head neither this
    -- run nor its reviewer ever examined.
    withStep settled {liveHead = newerHead, labelsAfter = [approval]} "remove" "removed" $
      \outcome → do
        result outcome `shouldSatisfy` (/= ExitSuccess)
        -- A workflow command is an annotation on stdout, which is where the
        -- job's own diagnostic lands.
        output outcome `shouldContain` "::error::"
        output outcome `shouldContain` "superseded head"
        unwords (calls outcome) `shouldNotContain` "--remove-label"

  it "fails when the label survived the removal" $
    withStep settled {labelsAfter = [approval]} "remove" "removed" $ \outcome → do
      result outcome `shouldSatisfy` (/= ExitSuccess)
      output outcome `shouldContain` "still attached after the removal"

  it "fails rather than reading a failed label lookup as an absent label" $
    -- A failed read is not an empty one. Left to a pipeline in an `if`
    -- condition, Bash would exempt the failure from `set -e` and this job would
    -- report a confirmed removal it never observed.
    withStep settled {labelReadFails = True} "remove" "removed" $ \outcome → do
      result outcome `shouldSatisfy` (/= ExitSuccess)
      output outcome `shouldContain` "could not be read back"

  it "fails rather than confirming a verdict the decision never reached" $
    -- This job runs on `always()` so that a push always leaves the check with a
    -- verdict. The cost is that it also runs when the decision failed, where
    -- every output it would act on is an empty string; reporting success there
    -- would tell the drainer an approval was confirmed by a job that never ran.
    withStep settled {labelsAfter = [approval], decision = "failure"} "" "" $ \outcome → do
      result outcome `shouldSatisfy` (/= ExitSuccess)
      output outcome `shouldContain` "stale-approval decision for this push was failure"
      unwords (calls outcome) `shouldNotContain` "--remove-label"

  it "tolerates an unrelated label left on the pull request" $
    withStep settled {labelsAfter = ["ci"]} "remove" "removed" $ \outcome →
      result outcome `shouldBe` ExitSuccess

  describe "the provenance it publishes" $ do
    it "names every revision a carried approval was decided from" $
      -- The summary is the only place a reader can see why an approval outlived
      -- a code push, so an approval that should not have survived stays
      -- traceable to the replay that let it.
      withStep settled {labelsAfter = [approval], replay = "keep"} "none" "kept" $
        \outcome → do
          result outcome `shouldBe` ExitSuccess
          summary outcome `shouldContain` "- Replay: keep"
          summary outcome `shouldContain` ("- Approved head: `" ++ approvedHead ++ "`")
          summary outcome
            `shouldContain` ("- Incorporated base commit: `" ++ incorporatedBase ++ "`")
          summary outcome `shouldContain` ("- Replay tree: `" ++ replayTree ++ "`")
          summary outcome `shouldContain` ("- Resulting head: `" ++ pushedHead ++ "`")

    it "credits the earlier review without claiming the new tree was read" $
      -- Repeated clean updates carry one review through a chain of heads, so the
      -- approved head is not necessarily the revision anybody examined — and
      -- nobody examined the integration tree at all.
      withStep settled {labelsAfter = [approval], replay = "keep"} "none" "kept" $
        \outcome → do
          summary outcome `shouldContain` "immediately preceding approval-bearing head"
          summary outcome `shouldContain` "no reviewer examined the resulting integration tree"

    it "reports a replay with no label as eligibility rather than inheritance" $
      withStep settled {replay = "keep"} "none" "absent" $ \outcome → do
        result outcome `shouldBe` ExitSuccess
        summary outcome `shouldContain` "replay-eligible"
        summary outcome `shouldNotContain` "no reviewer examined"

    it "records the fields a strip could not establish rather than omitting them" $
      -- A summary that simply drops them reads as though the replay was never
      -- attempted, which is the one thing it must not be confused with.
      withStep settled {replayReached = False} "remove" "removed" $ \outcome → do
        result outcome `shouldBe` ExitSuccess
        summary outcome `shouldContain` "- Replay: strip"
        summary outcome `shouldContain` "- Incorporated base commit: not established"
        summary outcome `shouldContain` "- Replay tree: not established"

-- ---------------------------------------------------------------------------
-- Running the shipped step

-- | Extract the step's own shell, stub `gh`, and run it.
withStep ∷ Repository → String → String → (Outcome → IO a) → IO a
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
    let reached value = if replayReached repository then value else ""
        settings =
          [ ("PATH", binPath ++ ":/usr/bin:/bin:/usr/sbin:/sbin")
          , ("GH_TOKEN", "stub-token")
          , ("REPOSITORY", "coghex/hetoimasia")
          , ("NUMBER", "16")
          , ("EVENT_HEAD", pushedHead)
          , ("BEFORE", approvedHead)
          , ("DECISION", decision repository)
          , ("ACTION", action)
          , ("EXPECTED", expected)
          , ("REASON", "a fixture decision")
          , ("REPLAY", replay repository)
          , ("REPLAY_REASON", "a fixture replay")
          , ("APPROVED_HEAD", reached approvedHead)
          , ("INCORPORATED_BASE", reached incorporatedBase)
          , ("REPLAY_TREE", reached replayTree)
          , ("RESULTING_HEAD", pushedHead)
          , ("LABEL", approval)
          , ("GITHUB_STEP_SUMMARY", directory </> "summary")
          ]
              ++ filter (\(name, _) → name `notElem` ["PATH", "GH_TOKEN"]) inherited
    (status, stdout', _) ← run settings directory "bash" [directory </> "step.sh"]
    logged ← doesFileExist (directory </> "calls")
    recorded ← if logged then lines <$> readFile (directory </> "calls") else pure []
    published ← readFile (directory </> "summary")
    assertion (Outcome status stdout' recorded published)

-- | The literal @run@ block of one named step, read from the workflow itself.
--
-- Deliberately dependency-free: the point is to assert against the file the
-- pipeline actually loads, and a test that needed a YAML library installed to
-- do so would be skipped exactly when it mattered.
stepBody ∷ FilePath → String → IO String
stepBody checkout name = do
  (status, stdout', errors) ←
    run [] checkout "python3" ["-c", extractor, ".github/workflows/review-gate.yml", name]
  (status, errors) `shouldBe` (ExitSuccess, "")
  pure stdout'

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
