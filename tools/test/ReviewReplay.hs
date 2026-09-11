-- | Hspec coverage for the replay that carries a review through a base update.
--
-- The rule this proves is narrow on purpose: an approval survives a
-- content-changing push only when the push is Git's own clean merge of the
-- approved head with a commit the base already contains, and the tree that was
-- pushed is the tree that merge produces. Every example therefore builds a real
-- history in a temporary repository and asks the shipped
-- @tools/validation/review_replay.py@ about it, because the question is
-- genuinely about what Git does — rename detection, conflict resolution, and
-- reachability are not things a restatement of the rule can assert.
--
-- Two properties are asserted everywhere rather than in one example. Every
-- decision exits zero, including the conservative ones: the caller removes a
-- label on @strip@, and a tool that failed instead would abort the job before
-- it got there and leave the stale approval standing on exactly the histories
-- that are least trustworthy. And every @strip@ says which rule it failed, so a
-- contributor reading the job log learns whether Git could not reach an object
-- or the update really did carry something extra.
module ReviewReplay (spec) where

import Control.Monad (void)
import Data.Maybe (fromMaybe)
import Sandbox (git, run, sanitizedEnvironment, writeFixtureFile)
import System.Directory (getCurrentDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, shouldBe, shouldContain, shouldSatisfy)

data Fixture = Fixture
  { root ∷ FilePath
  , environment ∷ [(String, String)]
  , tool ∷ FilePath
  }

-- | A well-formed object name that no fixture repository contains, standing in
-- for a head a force-push left unreachable.
absentRevision ∷ String
absentRevision = "0123456789abcdef0123456789abcdef01234567"

spec ∷ Spec
spec = describe "Review replay" $ do
  describe "an update that carries its approval" $ do
    it "keeps the branch update that merges the base into the approved head" $
      withFixture $ \fixture → do
        approved ← approvedWork fixture
        advanceBase fixture "docs/notes.md" "An upstream note.\n" "Note upstream"
        merged ← mergeBase fixture
        replay fixture approved merged "master" >>= shouldKeep

    it "keeps two additions to one manifest that merge cleanly" $
      -- Disjoint edits to a single file are the case a path-overlap rule gets
      -- wrong in both directions; the merge itself is the only honest answer.
      withFixture $ \fixture → do
        void $ startBranch fixture
        writeManifest fixture "The branch's first entry." lastEntry
        approved ← commitAll fixture "Revise the first entry"
        void $ at fixture ["checkout", "master"]
        writeManifest fixture firstEntry "The base's last entry."
        void $ commitAll fixture "Revise the last entry"
        void $ at fixture ["checkout", "feature"]
        merged ← mergeBase fixture
        replay fixture approved merged "master" >>= shouldKeep

    it "keeps a base rename Git carries into the approved work" $
      withFixture $ \fixture → do
        approved ← approvedWork fixture
        void $ at fixture ["checkout", "master"]
        void $ at fixture ["mv", "src/module.hs", "src/renamed.hs"]
        void $ commitAll fixture "Rename the module"
        void $ at fixture ["checkout", "feature"]
        merged ← mergeBase fixture
        replay fixture approved merged "master" >>= shouldKeep

    it "keeps an update whose incorporated commit the base has since moved past" $
      -- The base tip a later check fetches is not the base the update
      -- incorporated. Judging against the tip would invalidate an approval that
      -- nothing about the candidate changed.
      withFixture $ \fixture → do
        approved ← approvedWork fixture
        advanceBase fixture "docs/notes.md" "The first upstream note.\n" "Note upstream"
        merged ← mergeBase fixture
        advanceBase fixture "docs/later.md" "A later upstream note.\n" "Note upstream again"
        replay fixture approved merged "master" >>= shouldKeep

    it "keeps an update incorporating a base commit that itself reverts code" $
      -- No commit message is read and no semantic revert is detected: base
      -- history that undoes base history is still base history, and inheriting
      -- through it is the rule working rather than a hole in it.
      withFixture $ \fixture → do
        approved ← approvedWork fixture
        void $ at fixture ["checkout", "master"]
        writeFixture fixture "docs/notes.md" "An upstream note.\n"
        undone ← commitAll fixture "Note upstream"
        void $ at fixture ["revert", "--no-edit", undone]
        void $ at fixture ["checkout", "feature"]
        merged ← mergeBase fixture
        replay fixture approved merged "master" >>= shouldKeep

  describe "an update that does not" $ do
    it "strips a merge carrying an edit the replay does not produce" $
      withFixture $ \fixture → do
        approved ← approvedWork fixture
        advanceBase fixture "docs/notes.md" "An upstream note.\n" "Note upstream"
        void $ mergeBase fixture
        writeFixture fixture "src/module.hs" (seedModule ++ "-- one line the review never saw\n")
        amended ← amendHead fixture
        replay fixture approved amended "master" >>= shouldStrip "carries more than the merge"

    it "strips a merge whose conflict someone resolved by hand" $
      withFixture $ \fixture → do
        void $ startBranch fixture
        writeManifest fixture "The branch's first entry." lastEntry
        approved ← commitAll fixture "Revise the first entry"
        void $ at fixture ["checkout", "master"]
        writeManifest fixture "The base's first entry." lastEntry
        void $ commitAll fixture "Revise the same entry"
        void $ at fixture ["checkout", "feature"]
        startConflictedMerge fixture
        writeManifest fixture "An entry somebody chose." lastEntry
        resolved ← commitAll fixture "Resolve the conflict"
        replay fixture approved resolved "master" >>= shouldStrip "does not merge cleanly"

    it "strips a rename Git cannot carry" $
      -- Both sides moved the same file. The resolution is a human decision
      -- about where the code lives, and no earlier review covers it.
      withFixture $ \fixture → do
        void $ startBranch fixture
        void $ at fixture ["mv", "src/module.hs", "src/branch_name.hs"]
        approved ← commitAll fixture "Rename the module on the branch"
        void $ at fixture ["checkout", "master"]
        void $ at fixture ["mv", "src/module.hs", "src/base_name.hs"]
        void $ commitAll fixture "Rename the module on the base"
        void $ at fixture ["checkout", "feature"]
        startConflictedMerge fixture
        resolved ← commitAll fixture "Settle on one name"
        replay fixture approved resolved "master" >>= shouldStrip "does not merge cleanly"

    it "strips an ordinary commit pushed on top of the approved head" $
      withFixture $ \fixture → do
        approved ← approvedWork fixture
        writeFixture fixture "src/module.hs" (seedModule ++ "-- an afterthought\n")
        pushed ← commitAll fixture "Add an afterthought"
        replay fixture approved pushed "master" >>= shouldStrip "not the two a base merge leaves"

    it "strips a revert of the approved work" $
      withFixture $ \fixture → do
        approved ← approvedWork fixture
        void $ at fixture ["revert", "--no-edit", approved]
        reverted ← revision fixture "HEAD"
        replay fixture approved reverted "master" >>= shouldStrip "not the two a base merge leaves"

    it "strips a merge with more parents than a base update leaves" $
      withFixture $ \fixture → do
        sidecar fixture
        approved ← approvedWork fixture
        advanceBase fixture "docs/notes.md" "An upstream note.\n" "Note upstream"
        void $ at fixture ["merge", "--no-ff", "-m", "Merge both", "master", "sidecar"]
        merged ← revision fixture "HEAD"
        replay fixture approved merged "master" >>= shouldStrip "3 parent(s)"

    it "strips a merge made from the base's side" $
      -- First-parent order is what says which side is being carried forward.
      -- Reversed, the approved work is the thing being merged in, not the thing
      -- the approval belongs to.
      withFixture $ \fixture → do
        approved ← approvedWork fixture
        advanceBase fixture "docs/notes.md" "An upstream note.\n" "Note upstream"
        void $ at fixture ["checkout", "master"]
        void $ at fixture ["merge", "--no-ff", "-m", "Merge feature into master", "feature"]
        merged ← revision fixture "HEAD"
        replay fixture approved merged "master" >>= shouldStrip "is not the approved head"

    it "strips a merge whose second parent the base does not contain" $
      withFixture $ \fixture → do
        sidecar fixture
        approved ← approvedWork fixture
        void $ at fixture ["merge", "--no-ff", "-m", "Merge sidecar into feature", "sidecar"]
        merged ← revision fixture "HEAD"
        replay fixture approved merged "master" >>= shouldStrip "is not contained in master"

  describe "an update Git cannot answer for" $ do
    it "strips when the approved head is no longer in the repository" $
      -- What a force-push that rewrote the branch leaves behind: the object the
      -- approval belongs to is unreachable, so nothing can be replayed.
      withFixture $ \fixture → do
        void $ approvedWork fixture
        advanceBase fixture "docs/notes.md" "An upstream note.\n" "Note upstream"
        merged ← mergeBase fixture
        replay fixture absentRevision merged "master"
          >>= shouldStrip "is not in this repository"

    it "strips when the pushed head cannot be read" $
      withFixture $ \fixture → do
        approved ← approvedWork fixture
        replay fixture approved absentRevision "master" >>= shouldStrip "could not be read"

    it "strips when the base cannot be resolved" $
      -- A shallow or partial fetch leaves the base ref missing. Containment is
      -- then unprovable, and an unprovable rule may not carry an approval.
      withFixture $ \fixture → do
        approved ← approvedWork fixture
        advanceBase fixture "docs/notes.md" "An upstream note.\n" "Note upstream"
        merged ← mergeBase fixture
        replay fixture approved merged "origin/master" >>= shouldStrip "could not be resolved"

-- ---------------------------------------------------------------------------
-- Asserting a decision

shouldKeep ∷ (ExitCode, String, String) → IO ()
shouldKeep (result, output, errors) = do
  (result, errors) `shouldBe` (ExitSuccess, "")
  field "replay_decision" output `shouldBe` Just "keep"
  -- A keep is only usable if it names what it carried: the summary the workflow
  -- publishes is built entirely out of these.
  filter (null . value output) provenanceFields `shouldBe` []

shouldStrip ∷ String → (ExitCode, String, String) → IO ()
shouldStrip fragment (result, output, _) = do
  -- Never a failure. The caller has a label to remove, and a non-zero exit
  -- would abort the job before it reached the removal.
  result `shouldBe` ExitSuccess
  field "replay_decision" output `shouldBe` Just "strip"
  value output "replay_reason" `shouldContain` fragment

provenanceFields ∷ [String]
provenanceFields = ["approved_head", "incorporated_base", "replay_tree", "resulting_head"]

field ∷ String → String → Maybe String
field name = lookup name . map split . lines
  where split line = let (key, rest) = break (== '=') line in (key, drop 1 rest)

value ∷ String → String → String
value output name = fromMaybe "" (field name output)

-- ---------------------------------------------------------------------------
-- Building a history to ask about

-- | A file with room for two edits that do not touch each other, and one entry
-- both sides can be made to fight over.
firstEntry, lastEntry ∷ String
firstEntry = "The first entry."
lastEntry = "The last entry."

middleEntries ∷ [String]
middleEntries =
  [ "A second entry."
  , "A third entry."
  , "A fourth entry."
  , "A fifth entry."
  ]

seedModule ∷ String
seedModule =
  unlines
    [ "module Seed (seed) where"
    , ""
    , "seed :: Int"
    , "seed = 1"
    ]

withFixture ∷ (Fixture → IO a) → IO a
withFixture action = do
  checkout ← getCurrentDirectory
  settings ← sanitizedEnvironment
  withSystemTempDirectory "hetoimasia-replay" $ \directory → do
    let fixture =
          Fixture directory settings (checkout </> "tools/validation/review_replay.py")
    void $ at fixture ["init", "-b", "master", "."]
    writeManifest fixture firstEntry lastEntry
    writeFixture fixture "docs/notes.md" "A seed note.\n"
    writeFixture fixture "src/module.hs" seedModule
    void $ commitAll fixture "Seed"
    action fixture

at ∷ Fixture → [String] → IO String
at fixture = git (environment fixture) (root fixture)

writeFixture ∷ Fixture → FilePath → String → IO ()
writeFixture fixture = writeFixtureFile (root fixture)

-- | The manifest, with its first and last entries chosen by the caller, so two
-- edits to one file can be made to merge cleanly or to collide on demand.
writeManifest ∷ Fixture → String → String → IO ()
writeManifest fixture first final =
  writeFixture fixture "manifest.txt" (unlines ([first] ++ middleEntries ++ [final]))

commitAll ∷ Fixture → String → IO String
commitAll fixture message = do
  void $ at fixture ["add", "-A"]
  void $ at fixture ["commit", "-m", message]
  revision fixture "HEAD"

amendHead ∷ Fixture → IO String
amendHead fixture = do
  void $ at fixture ["add", "-A"]
  void $ at fixture ["commit", "--amend", "--no-edit"]
  revision fixture "HEAD"

revision ∷ Fixture → String → IO String
revision fixture reference = takeWhile (/= '\n') <$> at fixture ["rev-parse", reference]

startBranch ∷ Fixture → IO String
startBranch fixture = at fixture ["checkout", "-b", "feature", "master"]

-- | The approved work: one branch commit, which is what the review examined.
approvedWork ∷ Fixture → IO String
approvedWork fixture = do
  void $ startBranch fixture
  writeFixture fixture "src/module.hs" (seedModule ++ "-- the approved work\n")
  commitAll fixture "Extend the module"

-- | A branch the base never incorporates, for a second parent that is not base
-- history.
sidecar ∷ Fixture → IO ()
sidecar fixture = do
  void $ at fixture ["checkout", "-b", "sidecar", "master"]
  writeFixture fixture "docs/sidecar.md" "Work the base never took.\n"
  void $ commitAll fixture "Work on the sidecar"
  void $ at fixture ["checkout", "master"]

-- | Move the base on, leaving the feature branch behind it.
advanceBase ∷ Fixture → FilePath → String → String → IO ()
advanceBase fixture path contents message = do
  void $ at fixture ["checkout", "master"]
  writeFixture fixture path contents
  void $ commitAll fixture message
  void $ at fixture ["checkout", "feature"]

-- | The merge a branch update performs: the base into the approved head.
mergeBase ∷ Fixture → IO String
mergeBase fixture = do
  void $ at fixture ["merge", "--no-ff", "-m", "Merge master into feature", "master"]
  revision fixture "HEAD"

-- | Begin the same merge where it cannot succeed, leaving the resolution to the
-- example.
startConflictedMerge ∷ Fixture → IO ()
startConflictedMerge fixture = do
  (result, _, _) ←
    run
      (environment fixture)
      (root fixture)
      "git"
      ["merge", "--no-ff", "-m", "Merge master into feature", "master"]
  result `shouldSatisfy` (/= ExitSuccess)

replay ∷ Fixture → String → String → String → IO (ExitCode, String, String)
replay fixture before after base =
  run
    (environment fixture)
    (root fixture)
    "python3"
    [tool fixture, "--before", before, "--after", after, "--base", base]
