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
-- reachable: a head that advances between the decision and the write, a
-- canonical approval granted to that head after the decision was made, and a
-- read that fails rather than coming back empty, do not occur on demand
-- against a real repository.
--
-- The same step also records a carried approval at the head it was carried
-- to, which is what the next push's decision reads to prove that head, and
-- publishes the provenance of an approval that outlived a code push. That
-- summary is the only place a reader can see which review is being carried
-- and how the head was reached from the revision it was granted at, so it is
-- asserted here rather than treated as decoration.
module DismissalStep
  ( spec
  , Repository (..)
  , Outcome (..)
  , settled
  , withStep
  , approval
  , pushedHead
  , approvedHead
  , approvalMarker
  , feedEntry
  , quoted
  ) where

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

-- | The revision a reviewer actually read, two carries behind the pushed head.
originHead ∷ String
originHead = "ffffffffffffffffffffffffffffffffffffffff"

approval ∷ String
approval = "reviewed:approve"

-- | The run this fixture job believes it is: what its record has to name, so
-- the proof can later ask whether that run's job actually concluded.
recordingRun ∷ String
recordingRun = "34650000001"

-- | The account whose review markers are canonical in the fixture repository.
owner ∷ String
owner = "coghex"

-- | The canonical coordinator's marker for one head, as the owner posts it.
approvalMarker ∷ String → String → String
approvalMarker headSha verdict =
  "<!-- pr-review:v2 reviewers=codex models=unspecified head=" ++ headSha ++ " verdict=" ++ verdict ++ " -->"

-- | One comment object as GitHub returns it, with or without the timestamp
-- that orders it.
feedEntry ∷ Int → Maybe String → String → String → String
feedEntry number created login text =
  "{\"id\": " ++ show number
    ++ maybe "" (\stamp → ", \"created_at\": " ++ quoted stamp) created
    ++ ", \"user\": {\"login\": " ++ quoted login ++ ", \"type\": \"User\"}"
    ++ ", \"body\": " ++ quoted text ++ "}"

quoted ∷ String → String
quoted text = "\"" ++ concatMap escape text ++ "\""
  where
    escape '"' = "\\\""
    escape '\\' = "\\\\"
    escape '\n' = "\\n"
    escape character = [character]

-- | The owner's comments, in posting order, as one page of the feed.
posted ∷ [String] → [String]
posted = zipWith entry [1 ..]
  where
    entry number text = feedEntry number (Just ("2026-09-11T00:00:" ++ pad number ++ "Z")) owner text
    pad number = let text = show number in replicate (2 - length text) '0' ++ text

-- | How the stubbed repository and the decision before it answer this run.
data Repository = Repository
  { liveHead ∷ String
  , labelsAfter ∷ [String]
  , labelReadFails ∷ Bool
  , replay ∷ String
  , replayReached ∷ Bool
  , decision ∷ String
  , -- | The comment objects the feed read before acting returns, as one page.
    markers ∷ [String]
  , markerReadFails ∷ Bool
  , recordFails ∷ Bool
  , provenance ∷ String
  , provenanceReason ∷ String
  , origin ∷ String
  , chain ∷ String
  , headVerdict ∷ String
  }

-- | A repository that behaves: the head is the pushed one, the removal took,
-- the replay reached its inputs and refused to carry the approval, and the
-- starting point was a head a reviewer read.
settled ∷ Repository
settled =
  Repository
    { liveHead = pushedHead
    , labelsAfter = []
    , labelReadFails = False
    , replay = "strip"
    , replayReached = True
    , decision = "success"
    , markers = []
    , markerReadFails = False
    , recordFails = False
    , provenance = "proven"
    , provenanceReason = "a canonical review approved the starting point itself"
    , origin = approvedHead
    , chain = approvedHead
    , headVerdict = "none"
    }

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

  describe "a canonical approval that arrived after the decision" $ do
    it "keeps the approval a review granted to this exact head" $
      -- The head-equality guard cannot see this one: the head did not move, a
      -- reviewer simply approved it while the decision was queued. Removing
      -- now would strip a review somebody just granted to this very revision.
      withStep
        settled {labelsAfter = [approval], markers = posted [approvalMarker pushedHead "APPROVE"]}
        "remove"
        "removed"
        $ \outcome → do
          result outcome `shouldBe` ExitSuccess
          unwords (calls outcome) `shouldNotContain` "--remove-label"
          output outcome `shouldContain` "after the decision was made"
          summary outcome `shouldContain` "named this head itself"
          unwords (calls outcome) `shouldNotContain` "approval-provenance:v1"

    it "removes an approval the decision kept when a review denied this head afterwards" $
      -- The mirror image: the decision found a proven carry and kept, and a
      -- reviewer then refused this very revision. The markers are re-read
      -- before every keep is confirmed, not only before a removal, so the
      -- denial strips instead of being recorded as a carry.
      withStep
        settled {replay = "keep", markers = posted [approvalMarker pushedHead "CHANGES_REQUESTED"]}
        "none"
        "kept"
        $ \outcome → do
          result outcome `shouldBe` ExitSuccess
          calls outcome `shouldSatisfy` any (isInfixOf "--remove-label")
          unwords (calls outcome) `shouldNotContain` "-X POST"
          output outcome `shouldContain` "requested changes on head"
          summary outcome `shouldContain` "- `reviewed:approve`: removed"
          summary outcome `shouldContain` "requested changes on this head itself"

    it "treats a late approval as the origin even when the decision already kept" $
      -- The action does not change, but the provenance does: a head approved
      -- in its own right is a new origin, so no carry is recorded for it and
      -- the summary does not claim nobody read it.
      withStep
        settled {labelsAfter = [approval], replay = "keep", markers = posted [approvalMarker pushedHead "APPROVE"]}
        "none"
        "kept"
        $ \outcome → do
          result outcome `shouldBe` ExitSuccess
          unwords (calls outcome) `shouldNotContain` "--remove-label"
          unwords (calls outcome) `shouldNotContain` "-X POST"
          summary outcome `shouldContain` "named this head itself"
          summary outcome `shouldContain` ("- Proven origin: `" ++ pushedHead ++ "`")
          summary outcome `shouldNotContain` "no reviewer examined"

    it "names this head as the origin for an approval the decision already saw" $
      -- The decision knew the head was approved but still handed over the
      -- starting point's origin; the re-read normalises it to this head.
      withStep
        settled
          { labelsAfter = [approval]
          , replay = "keep"
          , headVerdict = "approved"
          , origin = approvedHead
          , chain = approvedHead
          , markers = posted [approvalMarker pushedHead "APPROVE"]
          }
        "none"
        "kept"
        $ \outcome → do
          result outcome `shouldBe` ExitSuccess
          unwords (calls outcome) `shouldNotContain` "-X POST"
          summary outcome `shouldContain` ("- Proven origin: `" ++ pushedHead ++ "`")
          summary outcome `shouldContain` "named this head itself"

    it "reports a late denial even when the removal was already planned" $
      withStep settled {markers = posted [approvalMarker pushedHead "CHANGES_REQUESTED"]} "remove" "removed" $
        \outcome → do
          result outcome `shouldBe` ExitSuccess
          calls outcome `shouldSatisfy` any (isInfixOf "--remove-label")
          summary outcome `shouldContain` "requested changes on this head itself"
          summary outcome `shouldContain` "- Proven origin: not established"

    it "fails a keep it cannot re-verify against the markers" $
      withStep settled {labelsAfter = [approval], replay = "keep", markerReadFails = True} "none" "kept" $
        \outcome → do
          result outcome `shouldSatisfy` (/= ExitSuccess)
          output outcome `shouldContain` "comment feed could not be read back"
          unwords (calls outcome) `shouldNotContain` "-X POST"

    it "lets the newest marker naming the head win" $
      -- An approval later withdrawn for the same head is not an approval.
      withStep
        settled
          { markers =
              posted
                [ approvalMarker pushedHead "APPROVE"
                , approvalMarker pushedHead "CHANGES_REQUESTED"
                ]
          }
        "remove"
        "removed"
        $ \outcome → do
          result outcome `shouldBe` ExitSuccess
          calls outcome `shouldSatisfy` any (isInfixOf "--remove-label")

    it "is not persuaded by a fresh approval of some other head" $
      withStep settled {markers = posted [approvalMarker newerHead "APPROVE"]} "remove" "removed" $
        \outcome → do
          result outcome `shouldBe` ExitSuccess
          calls outcome `shouldSatisfy` any (isInfixOf "--remove-label")

    describe "evidence it cannot read" $ do
      let truncated = "<!-- pr-review:v2 reviewers=codex head=" ++ pushedHead ++ " verdict=CHANGES_REQUESTED -->"
      it "lets a truncated newer denial stand in the way of an older approval reversing a removal" $
        -- The older approval is well-formed and the newer withdrawal is not.
        -- Skipping the withdrawal would let the approval reverse the removal;
        -- refusing to read the feed at all keeps the removal.
        withStep settled {markers = posted [approvalMarker pushedHead "APPROVE", truncated]} "remove" "removed" $
          \outcome → do
            result outcome `shouldBe` ExitSuccess
            calls outcome `shouldSatisfy` any (isInfixOf "--remove-label")
            output outcome `shouldContain` "malformed or incomplete"
            summary outcome `shouldContain` "malformed or incomplete"

      it "turns a planned keep into a removal rather than confirm it from a feed it cannot read" $
        withStep settled {replay = "keep", markers = posted [approvalMarker pushedHead "APPROVE", truncated]} "none" "kept" $
          \outcome → do
            result outcome `shouldBe` ExitSuccess
            calls outcome `shouldSatisfy` any (isInfixOf "--remove-label")
            unwords (calls outcome) `shouldNotContain` "-X POST"
            summary outcome `shouldContain` "- `reviewed:approve`: removed"

      it "treats a well-shaped but unreal timestamp the same way" $
        withStep
          settled
            { markers =
                [ feedEntry 1 (Just "2026-09-11T00:00:01Z") owner (approvalMarker pushedHead "APPROVE")
                , feedEntry 2 (Just "0000-00-00T00:00:00Z") owner (approvalMarker pushedHead "CHANGES_REQUESTED")
                ]
            }
          "remove"
          "removed"
          $ \outcome → do
            result outcome `shouldBe` ExitSuccess
            calls outcome `shouldSatisfy` any (isInfixOf "--remove-label")
            output outcome `shouldContain` "malformed or incomplete"

      it "leaves prose that merely mentions the marker's name alone" $
        withStep
          settled
            { labelsAfter = [approval]
            , markers = posted ["The pr-review:v2 marker below approves this head.\n\n" ++ approvalMarker pushedHead "APPROVE"]
            }
          "remove"
          "removed"
          $ \outcome → do
            result outcome `shouldBe` ExitSuccess
            unwords (calls outcome) `shouldNotContain` "--remove-label"
            summary outcome `shouldContain` "named this head itself"

    it "fails rather than reading a failed feed lookup as no approval" $
      withStep settled {markerReadFails = True} "remove" "removed" $ \outcome → do
        result outcome `shouldSatisfy` (/= ExitSuccess)
        output outcome `shouldContain` "comment feed could not be read back"
        unwords (calls outcome) `shouldNotContain` "--remove-label"

  describe "the carry it records" $ do
    it "records a kept approval at the head it was carried to" $
      -- The record is what the next push's decision reads to prove this head,
      -- so it names the link exactly — where the carry started, where it
      -- landed, and the revision the review was granted at — and the run and
      -- attempt writing it, since it is posted before this job has concluded
      -- and is only as good as that conclusion.
      withStep settled {labelsAfter = [approval], replay = "keep"} "none" "kept" $ \outcome → do
        result outcome `shouldBe` ExitSuccess
        calls outcome `shouldSatisfy` any (isInfixOf "-X POST")
        unwords (calls outcome)
          `shouldContain` ( "<!-- approval-provenance:v1 origin=" ++ approvedHead
                              ++ " before=" ++ approvedHead ++ " after=" ++ pushedHead
                              ++ " run=" ++ recordingRun ++ " attempt=2 -->"
                          )

    it "records nothing when a canonical review named the head itself" $
      -- The marker is that head's own proof; a record would only restate it.
      withStep
        settled {labelsAfter = [approval], headVerdict = "approved", origin = pushedHead, chain = ""}
        "none"
        "kept"
        $ \outcome → do
          result outcome `shouldBe` ExitSuccess
          unwords (calls outcome) `shouldNotContain` "-X POST"
          summary outcome `shouldContain` "named this head itself"

    it "records nothing when the label was gone by the time the decision was applied" $
      -- A successful job with no label is the handshake's "no approval", and
      -- a record here would let a later push prove a carry that never was.
      withStep settled {replay = "keep"} "none" "kept" $ \outcome → do
        result outcome `shouldBe` ExitSuccess
        unwords (calls outcome) `shouldNotContain` "-X POST"
        summary outcome `shouldContain` "no longer attached"

    it "fails rather than confirming a carry it could not record" $
      -- A carry the next push cannot see is a strip waiting to happen; better
      -- that this job says so than that the next push discovers it.
      withStep settled {labelsAfter = [approval], replay = "keep", recordFails = True} "none" "kept" $
        \outcome → do
          result outcome `shouldSatisfy` (/= ExitSuccess)
          output outcome `shouldContain` "could not be recorded"

    it "fails rather than recording a carry with no proven origin" $
      withStep settled {labelsAfter = [approval], replay = "keep", origin = ""} "none" "kept" $
        \outcome → do
          result outcome `shouldSatisfy` (/= ExitSuccess)
          output outcome `shouldContain` "without a proven origin"
          unwords (calls outcome) `shouldNotContain` "-X POST"

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

    it "names the proven origin and the route the carry took from it" $
      withStep
        settled
          { labelsAfter = [approval]
          , replay = "keep"
          , origin = originHead
          , chain = originHead ++ "," ++ approvedHead
          , provenanceReason = "the starting point was reached from the canonically approved origin through 1 recorded carry"
          }
        "none"
        "kept"
        $ \outcome → do
          result outcome `shouldBe` ExitSuccess
          summary outcome `shouldContain` ("- Proven origin: `" ++ originHead ++ "`")
          summary outcome
            `shouldContain` ( "- Reached from the proven origin through: `" ++ take 12 originHead
                                ++ "` → `" ++ take 12 approvedHead ++ "` → `" ++ take 12 pushedHead ++ "`"
                            )
          summary outcome `shouldContain` "- Starting point: proven — the starting point was reached"

    it "credits the earlier review without claiming the new tree was read" $
      -- Repeated clean updates carry one review through a chain of heads. The
      -- origin is the revision somebody examined; nobody examined the
      -- integration tree at all.
      withStep settled {labelsAfter = [approval], replay = "keep"} "none" "kept" $
        \outcome → do
          summary outcome `shouldContain` "granted at the proven origin, the revision a reviewer read"
          summary outcome `shouldContain` "no reviewer examined the resulting integration tree"

    it "states which link could not be proven when it strips" $
      withStep
        settled
          { replay = "keep"
          , provenance = "unproven"
          , provenanceReason = "the starting point cccccccccccc has no canonical approval and no recorded carry leads into it"
          , origin = ""
          , chain = ""
          }
        "remove"
        "removed"
        $ \outcome → do
          result outcome `shouldBe` ExitSuccess
          summary outcome `shouldContain` "- Starting point: unproven — the starting point cccccccccccc has no canonical approval"
          summary outcome `shouldContain` "- Proven origin: not established"
          summary outcome `shouldNotContain` "no reviewer examined"

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
    writeFixtureFile directory "markers" ("[[" ++ commaSeparated (markers repository) ++ "]]\n")
    unless (not (labelReadFails repository)) $
      writeFixtureFile directory "labels-fail" ""
    unless (not (markerReadFails repository)) $
      writeFixtureFile directory "markers-fail" ""
    unless (not (recordFails repository)) $
      writeFixtureFile directory "record-fail" ""
    writeFixtureFile directory "summary" ""
    writeFixtureFile directory "step.sh" body
    writeFixtureFile binPath "gh" (stub directory)
    _ ← run inherited directory "chmod" ["+x", binPath </> "gh"]
    let reached value = if replayReached repository then value else ""
        overrides =
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
          , ("PROVENANCE", provenance repository)
          , ("PROVENANCE_REASON", provenanceReason repository)
          , ("ORIGIN", origin repository)
          , ("CHAIN", chain repository)
          , ("HEAD_VERDICT", headVerdict repository)
          , ("OWNER", owner)
          , ("LABEL", approval)
          , ("GITHUB_RUN_ID", recordingRun)
          , ("GITHUB_RUN_ATTEMPT", "2")
          , ("RUNNER_TEMP", directory)
          , ("GITHUB_STEP_SUMMARY", directory </> "summary")
          ]
        -- Every one of those has to *replace* the inherited entry rather than
        -- sit in front of it: Bash resolves a duplicate environment entry to the
        -- later one, so an inherited copy left behind would win. That is not
        -- hypothetical for `GITHUB_STEP_SUMMARY` — the runner sets it, so these
        -- examples would write the fixture's summary into the real job summary
        -- and then assert against an empty file, failing only on CI.
        settings = overrides ++ filter (\(name, _) → name `notElem` map fst overrides) inherited
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

commaSeparated ∷ [String] → String
commaSeparated = foldr (\item rest → if null rest then item else item ++ ", " ++ rest) ""

-- | A `gh` that records every call and answers from the fixture directory.
--
-- The comment feed is answered twice over: the paged read of the whole feed
-- before acting, which the step then validates with the real `jq`, and the
-- record the step posts after a carry. Both are told apart by the request
-- rather than the endpoint, since they share one.
stub ∷ FilePath → String
stub directory =
  unlines
    [ "#!/bin/sh"
    , "printf '%s\\n' \"$*\" >> " ++ show (directory </> "calls")
    , "case \"$*\" in"
    , "  *' -X POST '*'/comments'*)"
    , "    if [ -f " ++ show (directory </> "record-fail") ++ " ]; then"
    , "      echo 'stub: the record could not be posted' >&2"
    , "      exit 1"
    , "    fi"
    , "    echo '{}'"
    , "    ;;"
    , "  *'/comments'*)"
    , "    if [ -f " ++ show (directory </> "markers-fail") ++ " ]; then"
    , "      echo 'stub: the comments could not be read' >&2"
    , "      exit 1"
    , "    fi"
    , "    cat " ++ show (directory </> "markers")
    , "    ;;"
    , "  'api '*) cat " ++ show (directory </> "head") ++ " ;;"
    , "  'pr edit'*) exit 0 ;;"
    , "  'pr view'*)"
    , "    if [ -f " ++ show (directory </> "labels-fail") ++ " ]; then"
    , "      echo 'stub: the labels could not be read' >&2"
    , "      exit 1"
    , "    fi"
    , "    cat " ++ show (directory </> "labels")
    , "    ;;"
    , "  *) echo \"stub: unexpected gh $*\" >&2; exit 64 ;;"
    , "esac"
    ]
