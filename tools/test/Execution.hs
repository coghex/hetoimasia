-- | Hspec coverage for the validation runner and the aggregate.
--
-- Every example drives the real @tools/validation/run.py@ and
-- @tools/validation/aggregate.py@ against a temporary Git repository, a fixture
-- catalog, and a plan resolved by the real planner, so the assertions describe
-- the published verdict's actual failure contract rather than a restatement of
-- it. The fixture groups run @true@, @false@, and a sleeping shell so an
-- execution's outcome is decided by the test rather than by a compiler.
module Execution (spec) where

import Control.Concurrent (threadDelay)
import Control.Monad (void)
import Data.Maybe (isNothing)
import Json (Json (..), asBool, asString, entryFor, field, parseJson)
import Sandbox
  ( fixtureGenerated
  , fixtureIgnore
  , git
  , run
  , sanitizedEnvironment
  , writeFixtureFile
  )
import System.Directory
  ( copyFile
  , createDirectoryIfMissing
  , createDirectoryLink
  , createFileLink
  , doesFileExist
  , getCurrentDirectory
  , getPermissions
  , removeDirectoryRecursive
  , removeFile
  , setOwnerExecutable
  , setPermissions
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
  ( Spec
  , describe
  , it
  , shouldBe
  , shouldContain
  , shouldNotContain
  , shouldReturn
  , shouldSatisfy
  )

data Fixture = Fixture
  { root ∷ FilePath
  , tools ∷ FilePath
  , environment ∷ [(String, String)]
  , seeded ∷ String
  , initial ∷ String
  }

spec ∷ Spec
spec = describe "Validation execution" $ do
  describe "the runner" $ do
    it "records a failing command as a non-zero receipt" $
      withFixture $ \fixture → do
        change fixture "src/note.txt" "revised source\n"
        plan ← planAgainst fixture (seeded fixture)
        head' ← revision fixture "HEAD"
        (result, _, _) ← runGroup fixture "test.fail" plan []
        result `shouldBe` ExitFailure 1
        receipt ← readReceipt fixture "test.fail"
        stringField receipt "outcome" `shouldBe` Just "failed"
        numberField receipt "exit_status" `shouldBe` Just 1
        stringField receipt "group" `shouldBe` Just "test.fail"
        stringField receipt "head_commit" `shouldBe` Just head'
        -- The contract later slices consume, asserted by name: a whole-document
        -- comparison would churn on every addition without proving any of them
        -- is present.
        filter (isNothing . stringField receipt) requiredReceiptFields `shouldBe` []
        numberField receipt "duration_seconds" `shouldSatisfy` maybe False (>= 0)

    it "distinguishes the pull request's head from the commit that executed" $
      withFixture $ \fixture → do
        -- A pull request is validated on an integration candidate that is
        -- neither endpoint, so the receipt records both rather than implying
        -- that the head itself ran. The candidate is a real commit, and this
        -- checkout is of it: that is the only way an execution earns the right
        -- to name one.
        change fixture "README.md" "the pull request's own prose\n"
        head' ← revision fixture "HEAD"
        change fixture "README.md" "the integration candidate's prose\n"
        candidate ← revision fixture "HEAD"
        head' `shouldSatisfy` (/= candidate)
        plan ← planCandidateInto fixture (seeded fixture) head' candidate "candidate.json"
        (result, _, errors) ← runGroup fixture "build.pass" plan []
        (result, errors) `shouldBe` (ExitSuccess, "")
        receipt ← readReceipt fixture "build.pass"
        stringField receipt "head_commit" `shouldBe` Just head'
        stringField receipt "executed_commit" `shouldBe` Just candidate
        candidateTree ← revision fixture "HEAD^{tree}"
        stringField receipt "executed_tree" `shouldBe` Just candidateTree
        -- The verdict accepts it: a candidate that is not the head is the
        -- ordinary hosted shape, not an irregularity.
        (verdict, output, _) ← aggregate fixture plan []
        verdict `shouldBe` ExitSuccess
        output `shouldContain` "verdict: passed"

    it "enforces the catalog timeout and reaps the command's descendants" $
      withFixture $ \fixture → do
        change fixture "slow/note.txt" "revised slow input\n"
        plan ← planAgainst fixture (seeded fixture)
        (result, _, _) ← runGroup fixture "smoke.slow" plan []
        result `shouldBe` ExitFailure 1
        receipt ← readReceipt fixture "smoke.slow"
        stringField receipt "outcome" `shouldBe` Just "timeout"
        -- The sleeping grandchild outlives its shell unless the runner ends the
        -- whole process group. Its death is asynchronous, so this polls for it
        -- within a bound instead of assuming an instant the kernel never
        -- promised.
        child ← readFile (root fixture </> "child.pid")
        reaped fixture (takeWhile (/= '\n') child) 50 `shouldReturn` True

    it "kills a descendant that ignores the termination signal" $
      withFixture $ \fixture → do
        change fixture "stubborn/note.txt" "revised stubborn input\n"
        plan ← planAgainst fixture (seeded fixture)
        (result, _, _) ← runGroup fixture "smoke.stubborn" plan []
        result `shouldBe` ExitFailure 1
        receipt ← readReceipt fixture "smoke.stubborn"
        stringField receipt "outcome" `shouldBe` Just "timeout"
        -- The shell exits on SIGTERM while the child it started ignores the
        -- signal entirely, so the leader's exit says nothing about the group.
        -- Only a kill aimed at the group reaches this process.
        child ← readFile (root fixture </> "child.pid")
        reaped fixture (takeWhile (/= '\n') child) 50 `shouldReturn` True

    it "refuses a group the plan explained away, leaving no receipt behind" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        (result, _, errors) ← runGroup fixture "test.fail" plan []
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "did not select"
        doesFileExist (receiptPath fixture "test.fail") `shouldReturn` False

  describe "execution provenance" $ do
    it "refuses a stale plan executed from a commit that replaced its candidate" $
      withFixture $ \fixture → do
        -- The candidate genuinely fails, which is the verdict a later commit
        -- must not be able to stand in for. Both revisions are committed and
        -- no receipt is touched: nothing here is a tampered document.
        change fixture "flag/value" "bad\n"
        candidate ← revision fixture "HEAD"
        plan ← planAgainst fixture (seeded fixture)
        (atCandidate, _, _) ← runGroup fixture "test.flag" plan []
        atCandidate `shouldBe` ExitFailure 1
        removeFile (receiptPath fixture "test.flag")
        change fixture "flag/value" "good\n"
        executed ← revision fixture "HEAD"
        (result, _, errors) ← runGroup fixture "test.flag" plan []
        result `shouldBe` ExitFailure 2
        errors `shouldContain` candidate
        errors `shouldContain` executed
        doesFileExist (receiptPath fixture "test.flag") `shouldReturn` False
        -- The aggregate agrees rather than certifying the candidate from the
        -- run that was refused.
        (verdict, output, _) ← aggregate fixture plan []
        verdict `shouldBe` ExitFailure 1
        output `shouldContain` "test.flag"
        output `shouldContain` "verdict: failed"

    it "refuses a commit that only happens to carry the candidate's tree" $
      withFixture $ \fixture → do
        change fixture "src/note.txt" "revised source\n"
        candidate ← revision fixture "HEAD"
        candidateTree ← revision fixture "HEAD^{tree}"
        plan ← planAgainst fixture (seeded fixture)
        -- Reuse may cross commits whose inputs agree; a fresh execution may
        -- not, because its receipt names the commit it read.
        void $ gitIn fixture ["commit", "-q", "--allow-empty", "-m", "Add no content"]
        executed ← revision fixture "HEAD"
        executed `shouldSatisfy` (/= candidate)
        revision fixture "HEAD^{tree}" `shouldReturn` candidateTree
        (result, _, errors) ← runGroup fixture "build.pass" plan []
        result `shouldBe` ExitFailure 2
        errors `shouldContain` candidate
        errors `shouldContain` executed

    it "offers no override that could record a revision it did not execute" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        (result, _, errors) ←
          runGroup fixture "build.pass" plan ["--executed-commit", integrationCommit]
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "unrecognized arguments"
        doesFileExist (receiptPath fixture "build.pass") `shouldReturn` False

    it "refuses an uncommitted edit to a source a group consumes" $
      withDirtyFixture $ \fixture plan → do
        writeFixtureFile (root fixture) "src/note.txt" "an edit no commit carries\n"
        refusesDirty fixture plan ["src/note.txt"]

    it "refuses a staged addition as readily as an untracked one" $
      withDirtyFixture $ \fixture plan → do
        writeFixtureFile (root fixture) "src/extra.txt" "a source no commit carries\n"
        refusesDirty fixture plan ["src/extra.txt"]
        void $ gitIn fixture ["add", "--", "src/extra.txt"]
        refusesDirty fixture plan ["src/extra.txt"]

    it "refuses an uncommitted deletion" $
      withDirtyFixture $ \fixture plan → do
        removeFile (root fixture </> "src/note.txt")
        refusesDirty fixture plan ["src/note.txt"]

    it "refuses an uncommitted rename, naming both of its endpoints" $
      withDirtyFixture $ \fixture plan → do
        void $ gitIn fixture ["mv", "src/note.txt", "src/moved.txt"]
        refusesDirty fixture plan ["src/note.txt", "src/moved.txt"]

    it "refuses an uncommitted mode change" $
      withDirtyFixture $ \fixture plan → do
        void $ gitIn fixture ["update-index", "--chmod=+x", "--", "src/note.txt"]
        refusesDirty fixture plan ["src/note.txt"]

    it "refuses an uncommitted edit to Markdown a group declares as an input" $
      withDirtyFixture $ \fixture plan → do
        -- Prose is harmless only while nothing consumes it. A declared input
        -- outranks the extension, so this edit cannot call itself harmless.
        writeFixtureFile (root fixture) "docs/consumed.md" "an edit no commit carries\n"
        refusesDirty fixture plan ["docs/consumed.md"]

    it "refuses an uncommitted edit to the policy that classifies the candidate" $
      withDirtyFixture $ \fixture plan → do
        -- Exempting the edit would mean reading the classification from the
        -- very file the edit rewrote.
        writeFixtureFile
          (root fixture)
          "tools/validation/catalog.json"
          (fixtureCatalogWith "[\"*.md\", \"*.txt\", \".gitignore\", \"LICENSE\"]")
        refusesPolicy fixture plan ["tools/validation/catalog.json"]

    it "refuses an addition no group declares and no catalog calls generated" $
      withDirtyFixture $ \fixture plan → do
        -- Every Cabal command reads `cabal.project.local`, and no catalog can
        -- have declared it as an input. A checkout carrying one is running with
        -- flags the candidate does not describe, so relevance is the same
        -- conservative complement of harmless prose a tracked path is held to.
        writeFixtureFile (root fixture) "cabal.project.local" "package demo\n"
        refusesDirty fixture plan ["cabal.project.local"]

    it "refuses an edit the index was told to stop noticing" $
      withDirtyFixture $ \fixture plan → do
        -- `--assume-unchanged` empties every ordinary diff while the command
        -- still reads the edited file.
        void $ gitIn fixture ["update-index", "--assume-unchanged", "--", "src/note.txt"]
        writeFixtureFile (root fixture) "src/note.txt" "an edit no diff reports\n"
        void $ gitIn fixture ["diff", "--name-only", "HEAD"] >>= \reported →
          reported `shouldBe` ""
        refusesDirty fixture plan ["src/note.txt"]

    it "refuses an unstaged mode change a configuration hid" $
      withDirtyFixture $ \fixture plan → do
        -- `core.fileMode=false` tells this checkout not to compare modes.
        void $ gitIn fixture ["config", "core.fileMode", "false"]
        permissions ← getPermissions (root fixture </> "src/note.txt")
        setPermissions (root fixture </> "src/note.txt") (setOwnerExecutable True permissions)
        void $ gitIn fixture ["diff", "--name-only", "HEAD"] >>= \reported →
          reported `shouldBe` ""
        refusesDirty fixture plan ["src/note.txt"]

    it "refuses an edit a clean filter reports as the committed bytes" $
      withDirtyFixture $ \fixture plan → do
        -- A clean filter runs on the way into Git, so one that always emits the
        -- committed content empties every diff while the command still reads
        -- what is on disk.
        writeFixtureFile (root fixture) ".git/info/attributes" "src/note.txt filter=hide\n"
        void $ gitIn fixture ["config", "filter.hide.clean", "printf 'a source the failing group consumes\n'"]
        writeFixtureFile (root fixture) "src/note.txt" "an edit no diff reports\n"
        gitIn fixture ["diff", "--name-only", "HEAD"] `shouldReturn` ""
        refusesDirty fixture plan ["src/note.txt"]

    it "refuses a tracked symlink replaced by a file of the same text" $
      withFixture $ \fixture → do
        -- The candidate records a symlink; the checkout holds a regular file
        -- whose content is the link's target. With `core.symlinks` off Git
        -- compares them as equal, and the command reads a file where the
        -- candidate has a link.
        void $ gitIn fixture ["rm", "-q", "--cached", "--", "src/note.txt"]
        removeFile (root fixture </> "src/note.txt")
        createFileLink (root fixture </> "probe/note.txt") (root fixture </> "src/note.txt")
        void $ gitIn fixture ["add", "-A", "."]
        void $ gitIn fixture ["commit", "-q", "-m", "Make the source a link"]
        plan ← planAgainst fixture (seeded fixture)
        void $ gitIn fixture ["config", "core.symlinks", "false"]
        removeFile (root fixture </> "src/note.txt")
        writeFixtureFile (root fixture) "src/note.txt" (root fixture </> "probe/note.txt")
        gitIn fixture ["diff", "--name-only", "HEAD"] `shouldReturn` ""
        refusesDirty fixture plan ["src/note.txt"]

    it "refuses a consumed input dropped inside a generated directory" $
      withDirtyFixture $ \fixture plan → do
        -- `fixtures/` is declared generated and stays exempt; what a group
        -- declares inside it does not inherit that exemption.
        writeFixtureFile (root fixture) "fixtures/other.json" "{}\n"
        (tolerated, _, errors) ← runGroup fixture "build.pass" plan []
        (tolerated, errors) `shouldBe` (ExitSuccess, "")
        removeFile (receiptPath fixture "build.pass")
        writeFixtureFile (root fixture) "fixtures/consumed.txt" "an input no commit carries\n"
        refusesDirty fixture plan ["fixtures/consumed.txt"]

    it "refuses a generated directory that is a link out of the checkout" $
      withDirtyFixture $ \fixture plan →
        withSystemTempDirectory "hetoimasia-outside" $ \outside → do
          -- `fixtures/` is declared generated, so a link wearing that name
          -- would inherit the exemption while the command read a consumed
          -- input from a directory that is not this checkout at all.
          writeFile (outside </> "consumed.txt") "an input no commit carries\n"
          createDirectoryLink outside (root fixture </> "fixtures")
          refusesDirty fixture plan ["fixtures/"]

    it "refuses a dirty input a replaced package description would excuse" $
      withFixture $ \fixture → do
        -- The candidate's package derives its inputs from `hs-source-dirs`, so
        -- the description decides whether `docs/` is consumed. Replacing that
        -- blob leaves every recorded identifier untouched — `ls-tree` still
        -- names the committed object — while `git show` hands the classifier a
        -- description that drops the directory.
        writeFixtureFile (root fixture) "demo.cabal" (demoPackageWith "app docs")
        writeFixtureFile (root fixture) "docs/reader.md" "a document the package consumes\n"
        void $ gitIn fixture ["add", "-A", "."]
        void $ gitIn fixture ["commit", "-q", "-m", "Consume the documents"]
        original ← blobOf fixture "HEAD" "demo.cabal"
        writeFixtureFile (root fixture) "demo.cabal" (demoPackageWith "app")
        void $ gitIn fixture ["add", "-A", "."]
        void $ gitIn fixture ["commit", "-q", "-m", "Stop consuming them"]
        narrowed ← blobOf fixture "HEAD" "demo.cabal"
        void $ gitIn fixture ["reset", "-q", "--hard", "HEAD~1"]
        plan ← planAgainst fixture (seeded fixture)
        void $ gitIn fixture ["replace", original, narrowed]
        writeFixtureFile (root fixture) "docs/reader.md" "an edit no commit carries\n"
        refusesDirty fixture plan ["docs/reader.md"]

    it "refuses a shadow module an inherited import path would reach" $
      withDirtyFixture $ \fixture plan → do
        -- `PYTHONPATH` naming the checkout puts a root-level module ahead of
        -- the standard library, so it would run before anything looked at it.
        writeFixtureFile
          (root fixture)
          "platform.py"
          "import sys\nprint('the shadow ran', file=sys.stderr)\n\n\ndef system():\n    return 'Shadow'\n"
        (result, _, errors) ←
          run
            (("PYTHONPATH", root fixture) : environment fixture)
            (root fixture)
            "python3"
            [ tools fixture </> "run.py", "build.pass"
            , "--plan", plan
            , "--receipts", receiptsDirectory fixture
            ]
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "platform.py"
        errors `shouldNotContain` "the shadow ran"
        doesFileExist (receiptPath fixture "build.pass") `shouldReturn` False

    it "refuses a generated basename sitting under a path a group consumes" $
      withDirtyFixture $ \fixture plan → do
        -- The catalog declares `*.json` generated, but `src/` is a declared
        -- input. A declaration never outranks one: the exemption is for a run's
        -- own output, not a way to write into what a group reads.
        writeFixtureFile (root fixture) "src/plan.json" "{}\n"
        refusesDirty fixture plan ["src/plan.json"]

    it "refuses a generated basename sitting under a mandatory policy root" $
      withDirtyFixture $ \fixture plan → do
        writeFixtureFile (root fixture) "tools/validation/plan.json" "{}\n"
        refusesPolicy fixture plan ["tools/validation/plan.json"]

    it "refuses a submodule that is at the candidate's commit but carries an edit" $
      withFixture $ \fixture →
        withSystemTempDirectory "hetoimasia-submodule" $ \inner → do
          void $ git (environment fixture) inner ["init", "-q", "-b", "master"]
          writeFixtureFile inner "value.txt" "the submodule's committed input\n"
          void $ git (environment fixture) inner ["add", "-A", "."]
          void $ git (environment fixture) inner ["commit", "-q", "-m", "Seed the submodule"]
          void $
            gitIn
              fixture
              [ "-c", "protocol.file.allow=always"
              , "submodule", "add", "-q", inner, "vendor/lib"
              ]
          void $ gitIn fixture ["add", "-A", "."]
          void $ gitIn fixture ["commit", "-q", "-m", "Add the submodule"]
          plan ← planAgainst fixture (seeded fixture)
          writeFixtureFile (root fixture) "vendor/lib/value.txt" "an edit no commit carries\n"
          -- A gitlink records one commit and nothing about the tree beside it.
          -- The submodule is still exactly that commit, the superproject's own
          -- index is untouched, and its untracked listing does not reach
          -- inside — yet the command reads the edited file.
          recorded ← revisionIn fixture (root fixture </> "vendor/lib") "HEAD"
          gitIn fixture ["ls-tree", "HEAD", "vendor/lib"] >>= \entry →
            entry `shouldContain` recorded
          gitIn fixture ["diff", "--name-only", "--cached", "HEAD"] `shouldReturn` ""
          others ← gitIn fixture ["ls-files", "--others"]
          others `shouldNotContain` "vendor/lib/value.txt"
          refusesDirty fixture plan ["vendor/lib/value.txt"]

    it "refuses a symlink standing in for a submodule at the same commit" $
      withFixture $ \fixture →
        withSystemTempDirectory "hetoimasia-submodule" $ \inner → do
          void $ git (environment fixture) inner ["init", "-q", "-b", "master"]
          writeFixtureFile inner "value.txt" "the submodule's committed input\n"
          void $ git (environment fixture) inner ["add", "-A", "."]
          void $ git (environment fixture) inner ["commit", "-q", "-m", "Seed the submodule"]
          void $
            gitIn
              fixture
              [ "-c", "protocol.file.allow=always"
              , "submodule", "add", "-q", inner, "vendor/lib"
              ]
          void $ gitIn fixture ["add", "-A", "."]
          void $ gitIn fixture ["commit", "-q", "-m", "Add the submodule"]
          plan ← planAgainst fixture (seeded fixture)
          -- A link to a clean checkout resting at the very same commit. Git
          -- follows it and reports that tree as this submodule, while the
          -- commands read another directory entirely.
          removeDirectoryRecursive (root fixture </> "vendor/lib")
          createDirectoryLink inner (root fixture </> "vendor/lib")
          recorded ← revisionIn fixture (root fixture </> "vendor/lib") "HEAD"
          gitIn fixture ["ls-tree", "HEAD", "vendor/lib"] >>= \entry →
            entry `shouldContain` recorded
          refusesDirty fixture plan ["vendor/lib"]

    it "refuses an edited classifier without consulting it" $
      withFixture $ \fixture → do
        -- A hosted worker runs the checkout's own copy of these tools, so the
        -- classifier is itself one of the inputs it would classify. This one
        -- has been taught that every path is harmless prose, which under the
        -- old order would have excused its own edit and every other.
        mapM_ (vendorTool fixture) ["run.py", "plan.py", "receipts.py"]
        void $ gitIn fixture ["add", "-A", "."]
        void $ gitIn fixture ["commit", "-q", "-m", "Vendor the validation tools"]
        plan ← planAgainst fixture (seeded fixture)
        -- Appended, so the later definition is the one the module ends with.
        appendFile
          (root fixture </> "tools/validation/plan.py")
          "\n\ndef harmless_prose(path, consumed, catalog):\n    return True\n"
        (result, _, errors) ←
          runFrom fixture (root fixture </> "tools/validation/run.py") "build.pass" plan
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "changed the policy that decides what a result means"
        errors `shouldContain` "tools/validation/plan.py"
        doesFileExist (receiptPath fixture "build.pass") `shouldReturn` False

    it "refuses an edited receipt contract without importing it" $
      withFixture $ \fixture → do
        -- `receipts.py` supplies the plan contract and writes the receipt, so
        -- importing a dirty copy would run its code — and let it forge one —
        -- before anything had looked at its path.
        mapM_ (vendorTool fixture) ["run.py", "plan.py", "receipts.py"]
        void $ gitIn fixture ["add", "-A", "."]
        void $ gitIn fixture ["commit", "-q", "-m", "Vendor the validation tools"]
        plan ← planAgainst fixture (seeded fixture)
        appendFile
          (root fixture </> "tools/validation/receipts.py")
          "\n\nimport sys\nprint('the dirty contract ran', file=sys.stderr)\n"
        (result, _, errors) ←
          runFrom fixture (root fixture </> "tools/validation/run.py") "build.pass" plan
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "changed the policy that decides what a result means"
        errors `shouldContain` "tools/validation/receipts.py"
        errors `shouldNotContain` "the dirty contract ran"
        doesFileExist (receiptPath fixture "build.pass") `shouldReturn` False

    it "refuses a module dropped beside the runner without importing it" $
      withFixture $ \fixture → do
        -- The runner's own directory leads the import path, so a file named for
        -- a standard library module would be imported in its place, before
        -- anything had looked at its path.
        mapM_ (vendorTool fixture) ["run.py", "plan.py", "receipts.py"]
        void $ gitIn fixture ["add", "-A", "."]
        void $ gitIn fixture ["commit", "-q", "-m", "Vendor the validation tools"]
        plan ← planAgainst fixture (seeded fixture)
        writeFixtureFile
          (root fixture)
          "tools/validation/platform.py"
          "import sys\nprint('the shadow ran', file=sys.stderr)\n\n\ndef system():\n    return 'Shadow'\n"
        (result, _, errors) ←
          runFrom fixture (root fixture </> "tools/validation/run.py") "build.pass" plan
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "changed the policy that decides what a result means"
        errors `shouldContain` "tools/validation/platform.py"
        errors `shouldNotContain` "the shadow ran"
        doesFileExist (receiptPath fixture "build.pass") `shouldReturn` False

    it "refuses a tree substituted for the candidate's by a replacement object" $
      withFixture $ \fixture → do
        change fixture "src/note.txt" "the candidate's own source\n"
        candidateTree ← revision fixture "HEAD^{tree}"
        plan ← planAgainst fixture (seeded fixture)
        change fixture "src/note.txt" "another revision's source\n"
        otherTree ← revision fixture "HEAD^{tree}"
        void $ gitIn fixture ["reset", "-q", "--hard", "HEAD~1"]
        -- The replacement leaves both identifiers reporting the candidate while
        -- every listing and every file describes the other tree.
        void $ gitIn fixture ["replace", candidateTree, otherTree]
        void $ gitIn fixture ["reset", "-q", "--hard", "HEAD"]
        revision fixture "HEAD^{tree}" `shouldReturn` candidateTree
        refusesDirty fixture plan ["src/note.txt"]

    it "refuses an added directory the candidate cannot contain" $
      withDirtyFixture $ \fixture plan → do
        -- Git records no empty directory, so one here is content the candidate
        -- does not have — and a command under a declared input can read it.
        createDirectoryIfMissing True (root fixture </> "src/scratch")
        refusesDirty fixture plan ["src/scratch/"]

    it "refuses an addition a redirected working tree would hide" $
      withDirtyFixture $ \fixture plan →
        withSystemTempDirectory "hetoimasia-elsewhere" $ \elsewhere → do
          -- `core.worktree` points Git's own listing at a clean directory the
          -- commands will never read, while they still run here.
          void $ gitIn fixture ["config", "core.worktree", elsewhere]
          writeFixtureFile (root fixture) "cabal.project.local" "package demo\n"
          others ← gitIn fixture ["ls-files", "--others"]
          others `shouldNotContain` "cabal.project.local"
          refusesDirty fixture plan ["cabal.project.local"]

    it "refuses a relevant addition that the repository's own ignore rules hide" $
      withDirtyFixture $ \fixture plan → do
        -- The checkout's ignore rules are not the candidate's classification,
        -- and two of the three places Git reads them from are not even part of
        -- the candidate. None of them may answer this question.
        appendFile (root fixture </> ".gitignore") "src/hidden.txt\n"
        writeFixtureFile (root fixture) ".git/info/exclude" "src/excluded.txt\n"
        writeFixtureFile (root fixture) "src/hidden.txt" "a source no commit carries\n"
        writeFixtureFile (root fixture) "src/excluded.txt" "another one\n"
        refusesDirty fixture plan ["src/hidden.txt", "src/excluded.txt"]

    it "classifies a dirty input with the catalog its own plan was resolved with" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        -- The alternate catalog consumes a document the committed one treats as
        -- harmless prose. Reading the candidate's own catalog instead would
        -- accept this edit and stamp the alternate plan's identity on it.
        writeFixtureFile (root fixture) "fixtures/alternate.json" alternateCatalog
        plan ←
          planWith
            fixture
            [ "--base", seeded fixture
            , "--head", "HEAD"
            , "--catalog", root fixture </> "fixtures/alternate.json"
            ]
            "alternate-plan.json"
        -- The same plan runs from the clean checkout it was resolved for.
        (clean, _, errors) ← runGroup fixture "build.pass" plan []
        (clean, errors) `shouldBe` (ExitSuccess, "")
        removeFile (receiptPath fixture "build.pass")
        writeFixtureFile (root fixture) "docs/alternate.md" "an edit no commit carries\n"
        refusesDirty fixture plan ["docs/alternate.md"]

    it "refuses an override catalog rewritten after the plan was resolved" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        writeFixtureFile (root fixture) "fixtures/alternate.json" alternateCatalog
        plan ←
          planWith
            fixture
            [ "--base", seeded fixture
            , "--head", "HEAD"
            , "--catalog", root fixture </> "fixtures/alternate.json"
            ]
            "alternate-plan.json"
        -- Naming the path binds nothing on its own. Rewriting the fixture to
        -- stop consuming the document would otherwise let a dirty edit to it
        -- pass under the identity the plan had already taken.
        writeFixtureFile (root fixture) "fixtures/alternate.json" fixtureCatalog
        writeFixtureFile (root fixture) "docs/alternate.md" "an edit no commit carries\n"
        (result, _, errors) ← runGroup fixture "build.pass" plan []
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "not the one this plan was resolved with"
        doesFileExist (receiptPath fixture "build.pass") `shouldReturn` False

    it "refuses a receipt produced under a classification the plan never had" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        writeFixtureFile (root fixture) "fixtures/alternate.json" alternateCatalog
        let arguments =
              [ "--base", seeded fixture
              , "--head", "HEAD"
              , "--catalog", root fixture </> "fixtures/alternate.json"
              ]
        plan ← planWith fixture arguments "alternate-plan.json"
        -- A worker that rewrites the catalog to stop consuming the document and
        -- updates its own copy of the plan to match satisfies the runner's own
        -- digest check, so the execution succeeds and the dirty edit passes.
        copyFile plan (root fixture </> "worker-plan.json")
        writeFixtureFile (root fixture) "fixtures/alternate.json" fixtureCatalog
        rewritten ← planWith fixture arguments "rewritten-plan.json"
        copyCatalogDigest fixture rewritten (root fixture </> "worker-plan.json")
        writeFixtureFile (root fixture) "docs/alternate.md" "an edit no commit carries\n"
        (executed, _, errors) ← runGroup fixture "build.pass" (root fixture </> "worker-plan.json") []
        (executed, errors) `shouldBe` (ExitSuccess, "")
        -- The verdict is decided against the plan that was actually resolved,
        -- and the classification is part of what that plan's identity names.
        (result, output, _) ← aggregate fixture plan []
        result `shouldBe` ExitFailure 1
        output `shouldContain` "names plan"

    it "executes with prose no group consumes and the artifacts a run writes" $
      withDirtyFixture $ \fixture plan → do
        -- The hosted layout: the plan and the applicability document are
        -- downloaded into the checkout, and the receipts are written beside
        -- them. None of that is a change to the candidate.
        writeFixtureFile (root fixture) "NOTES.md" "prose no group declares\n"
        writeFixtureFile (root fixture) "applicability.json" "{}\n"
        (result, _, errors) ← runGroup fixture "build.pass" plan []
        (result, errors) `shouldBe` (ExitSuccess, "")
        receipt ← readReceipt fixture "build.pass"
        candidate ← revision fixture "HEAD"
        stringField receipt "executed_commit" `shouldBe` Just candidate

  describe "the aggregate" $ do
    it "fails a selected group that produced no receipt" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        (result, output, _) ← aggregate fixture plan []
        result `shouldBe` ExitFailure 1
        output `shouldContain` "build.pass"
        output `shouldContain` "neither an execution nor an applicable earlier receipt"

    it "passes omitted unaffected and optional groups without receipts" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        (executed, _, _) ← runGroup fixture "build.pass" plan []
        executed `shouldBe` ExitSuccess
        (result, output, _) ← aggregate fixture plan []
        result `shouldBe` ExitSuccess
        output `shouldContain` "unaffected"
        output `shouldContain` "optional-unrequested"
        output `shouldContain` "verdict: passed"

    it "fails one failing group even when every other group passed" $
      withFixture $ \fixture → do
        change fixture "src/note.txt" "revised source\n"
        plan ← planAgainst fixture (seeded fixture)
        (passed, _, _) ← runGroup fixture "build.pass" plan []
        passed `shouldBe` ExitSuccess
        (failed, _, _) ← runGroup fixture "test.fail" plan []
        failed `shouldBe` ExitFailure 1
        (result, output, _) ← aggregate fixture plan []
        result `shouldBe` ExitFailure 1
        output `shouldContain` "test.fail"
        output `shouldContain` "verdict: failed"

    it "refuses a receipt that names another plan" $
      withFixture $ \fixture → do
        change fixture "src/note.txt" "revised source\n"
        current ← planAgainst fixture (seeded fixture)
        (executed, _, _) ← runGroup fixture "build.pass" current []
        executed `shouldBe` ExitSuccess
        -- The same head, compared against a different base, is a different
        -- question and therefore a different plan.
        other ← planInto fixture (initial fixture) "other-plan.json"
        (result, output, _) ← aggregate fixture other []
        result `shouldBe` ExitFailure 1
        output `shouldContain` "names plan"

    it "refuses a receipt that names another head" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        (executed, _, _) ← runGroup fixture "build.pass" plan []
        executed `shouldBe` ExitSuccess
        patchReceipt fixture "build.pass" "head_commit" (initial fixture)
        (result, output, _) ← aggregate fixture plan []
        result `shouldBe` ExitFailure 1
        output `shouldContain` "names head"

    it "refuses a fresh receipt recording an execution of another revision" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        (executed, _, _) ← runGroup fixture "build.pass" plan []
        executed `shouldBe` ExitSuccess
        patchReceipt fixture "build.pass" "executed_commit" (initial fixture)
        (result, output, _) ← aggregate fixture plan []
        result `shouldBe` ExitFailure 1
        output `shouldContain` "not the plan's candidate"

    it "refuses a fresh receipt recording another tree for the candidate" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        (executed, _, _) ← runGroup fixture "build.pass" plan []
        executed `shouldBe` ExitSuccess
        patchReceipt fixture "build.pass" "executed_tree" integrationTree
        (result, output, _) ← aggregate fixture plan []
        result `shouldBe` ExitFailure 1
        output `shouldContain` "not the candidate's"

    -- Each compatibility field is asked about on its own, because a check that
    -- only ever fired for one of them would look identical from the outside.
    disagreesAbout "input_identity" "\"0000000000000000000000000000000000000000\""
    disagreesAbout "policy_version" "\"1111111111111111111111111111111111111111\""
    disagreesAbout "toolchain" "{\"ghc\": \"0.0.0\"}"
    disagreesAbout "runner_os" "\"Plan9\""

    it "refuses a malformed receipt rather than reading past it" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        (executed, _, _) ← runGroup fixture "build.pass" plan []
        executed `shouldBe` ExitSuccess
        writeFile (receiptPath fixture "build.pass") "{ not a receipt\n"
        (result, output, _) ← aggregate fixture plan []
        result `shouldBe` ExitFailure 1
        output `shouldContain` "malformed"

    it "refuses a plan that registers no groups" $
      withFixture $ \fixture → do
        writeFixtureFile (root fixture) "empty.json" emptyPlan
        (result, _, errors) ← aggregate fixture (root fixture </> "empty.json") []
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "registers no groups"

    it "refuses a plan whose selected list omits a group it flagged" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        -- Dropping the floor from `selected` while its own flag stays true
        -- would let every worker skip it and the aggregate excuse it.
        patchDocument fixture plan "selected" "[]"
        (result, _, errors) ← aggregate fixture plan []
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "does not match the groups it flags as selected"

    it "refuses a plan that names a selected group twice" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        patchDocument fixture plan "selected" "[\"build.pass\", \"build.pass\"]"
        (result, _, errors) ← aggregate fixture plan []
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "more than once"

    it "reports a malformed plan as a diagnostic rather than a verdict" $
      withFixture $ \fixture → do
        writeFixtureFile (root fixture) "broken.json" "{ not a plan\n"
        (result, _, errors) ← aggregate fixture (root fixture </> "broken.json") []
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "not valid JSON"

    it "fails a worker that was cancelled while its groups were selected" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        (executed, _, _) ← runGroup fixture "build.pass" plan []
        executed `shouldBe` ExitSuccess
        (result, output, _) ← aggregate fixture plan ["--worker", "floor=cancelled:build.pass"]
        result `shouldBe` ExitFailure 1
        output `shouldContain` "worker floor was cancelled"

    it "fails a worker that concluded failure even with every receipt passing" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        (executed, _, _) ← runGroup fixture "build.pass" plan []
        executed `shouldBe` ExitSuccess
        -- A job can fail after its groups passed, so a passing receipt in an
        -- artifact cannot vouch for the job that produced it.
        (result, output, _) ← aggregate fixture plan ["--worker", "floor=failure:build.pass"]
        result `shouldBe` ExitFailure 1
        output `shouldContain` "worker floor was failure"

    it "fails a worker that was skipped while its groups were selected" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        (executed, _, _) ← runGroup fixture "build.pass" plan []
        executed `shouldBe` ExitSuccess
        (result, output, _) ← aggregate fixture plan ["--worker", "floor=skipped:build.pass"]
        result `shouldBe` ExitFailure 1
        output `shouldContain` "worker floor was skipped"

    it "accepts a worker skipped because the plan selected none of its groups" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        (executed, _, _) ← runGroup fixture "build.pass" plan []
        executed `shouldBe` ExitSuccess
        (result, _, _) ←
          aggregate
            fixture
            plan
            [ "--worker"
            , "floor=success:build.pass"
            , "--worker"
            , "extra=skipped:test.fail,smoke.slow"
            ]
        result `shouldBe` ExitSuccess

  describe "publication freshness" $ do
    it "refuses to answer for a head the pull request has moved past" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        (executed, _, _) ← runGroup fixture "build.pass" plan []
        executed `shouldBe` ExitSuccess
        (result, output, _) ← aggregate fixture plan ["--expect-head", initial fixture]
        result `shouldBe` ExitFailure 1
        output `shouldContain` "head is now"

    it "refuses to satisfy a request edited after the plan was resolved" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        plan ← planAgainst fixture (seeded fixture)
        (executed, _, _) ← runGroup fixture "build.pass" plan []
        executed `shouldBe` ExitSuccess
        writeFixtureFile (root fixture) "body.txt" (requestBlock ["probe.optional"])
        (result, output, _) ←
          aggregate fixture plan ["--expect-request-file", root fixture </> "body.txt"]
        result `shouldBe` ExitFailure 1
        output `shouldContain` "now asks for"

    it "accepts a plan that still describes the pull request" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        head' ← revision fixture "HEAD"
        plan ← planAgainst fixture (seeded fixture)
        (executed, _, _) ← runGroup fixture "build.pass" plan []
        executed `shouldBe` ExitSuccess
        writeFixtureFile (root fixture) "body.txt" "Ordinary prose with no request.\n"
        (result, _, _) ←
          aggregate
            fixture
            plan
            [ "--expect-head"
            , head'
            , "--expect-base"
            , seeded fixture
            , "--expect-request-file"
            , root fixture </> "body.txt"
            ]
        result `shouldBe` ExitSuccess

  describe "the comparison range" $ do
    it "compares a pull request across its merge base" $
      withFixture $ \fixture → do
        change fixture "src/note.txt" "revised source\n"
        head' ← revision fixture "HEAD"
        (result, output, _) ←
          resolveRange fixture ["--event", "pull_request", "--base-sha", seeded fixture, "--head-sha", head']
        result `shouldBe` ExitSuccess
        output `shouldContain` ("base=" ++ seeded fixture)
        output `shouldContain` ("head=" ++ head')

    it "compares a push from the commit it actually started at" $
      withFixture $ \fixture → do
        change fixture "src/note.txt" "revised source\n"
        head' ← revision fixture "HEAD"
        (result, output, _) ←
          resolveRange fixture ["--event", "push", "--before", seeded fixture, "--after", head']
        result `shouldBe` ExitSuccess
        output `shouldContain` ("base=" ++ seeded fixture)

    it "compares a history-replacing push against the history it replaced" $
      withFixture $ \fixture → do
        -- `before` changed a consumed source; `after` abandons that line and
        -- edits prose instead. Their merge base predates both, so a range taken
        -- from it sees only the prose and would omit the group whose input the
        -- push reverted. The event's own `before` is what makes the removal
        -- visible.
        change fixture "src/note.txt" "a source change this push discards\n"
        before ← revision fixture "HEAD"
        void $ git (environment fixture) (root fixture) ["reset", "-q", "--hard", seeded fixture]
        change fixture "README.md" "prose only\n"
        after ← revision fixture "HEAD"
        (result, output, _) ←
          resolveRange fixture ["--event", "push", "--before", before, "--after", after]
        result `shouldBe` ExitSuccess
        output `shouldContain` ("base=" ++ before)
        -- Planned from that range the discarded source counts, so the group
        -- that consumes it is selected rather than quietly dropped.
        plan ← planInto fixture before "divergent.json"
        selectionOf plan "test.fail" `shouldReturn` Just (Selection "affected" True True)
        -- Planned from the merge base instead, the same push looks like prose.
        merged ← planInto fixture (seeded fixture) "merged.json"
        selectionOf merged "test.fail" `shouldReturn` Just (Selection "unaffected" False False)

    it "refuses a push whose starting commit is unavailable" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        head' ← revision fixture "HEAD"
        (missing, _, absent) ←
          resolveRange fixture ["--event", "push", "--before", "", "--after", head']
        missing `shouldBe` ExitFailure 2
        absent `shouldContain` "names no starting commit"
        (unknown, _, errors) ←
          resolveRange
            fixture
            ["--event", "push", "--before", "6c1f2a0d4b8e3f57a9c0d1e2b3a4f5061728394a", "--after", head']
        unknown `shouldBe` ExitFailure 2
        errors `shouldContain` "starting commit"

  describe "the planner's own failure" $
    it "produces a diagnostic and no plan when the request is invalid" $
      withFixture $ \fixture → do
        change fixture "README.md" "revised prose\n"
        writeFixtureFile (root fixture) "body.txt" (requestBlock ["group.absent"])
        (result, _, errors) ←
          run
            (environment fixture)
            (root fixture)
            "python3"
            [ tools fixture </> "plan.py"
            , "--base"
            , seeded fixture
            , "--head"
            , "HEAD"
            , "--request-file"
            , root fixture </> "body.txt"
            , "--json"
            ]
        result `shouldBe` ExitFailure 2
        errors `shouldContain` "group.absent"

-- | A fresh receipt that agrees with its plan about everything but one
-- compatibility field is still evidence about another candidate.
disagreesAbout ∷ String → String → Spec
disagreesAbout name value =
  it ("refuses a fresh receipt recording a different " ++ name) $
    withFixture $ \fixture → do
      change fixture "README.md" "revised prose\n"
      plan ← planAgainst fixture (seeded fixture)
      (executed, _, _) ← runGroup fixture "build.pass" plan []
      executed `shouldBe` ExitSuccess
      patchDocument fixture (receiptPath fixture "build.pass") name value
      (result, output, _) ← aggregate fixture plan []
      result `shouldBe` ExitFailure 1
      output `shouldContain` ("different " ++ name)

-- | A fixture whose plan is resolved and whose checkout is that plan's
-- candidate, so a dirty-checkout example only has to make its own edit.
withDirtyFixture ∷ (Fixture → FilePath → IO a) → IO a
withDirtyFixture action = withFixture $ \fixture → do
  change fixture "README.md" "revised prose\n"
  plan ← planAgainst fixture (seeded fixture)
  action fixture plan

-- | Execute the floor group and require a refusal that names every path given
-- and leaves no receipt behind.
refusesDirty ∷ Fixture → FilePath → [String] → IO ()
refusesDirty = refusesWith "uncommitted changes"

-- | The same, for a difference under a policy root: that one is refused before
-- any classification, because the classifier is one of the files it covers.
refusesPolicy ∷ Fixture → FilePath → [String] → IO ()
refusesPolicy = refusesWith "changed the policy that decides what a result means"

refusesWith ∷ String → Fixture → FilePath → [String] → IO ()
refusesWith reason fixture plan paths = do
  (result, _, errors) ← runGroup fixture "build.pass" plan []
  result `shouldBe` ExitFailure 2
  errors `shouldContain` reason
  mapM_ (shouldContain errors) paths
  doesFileExist (receiptPath fixture "build.pass") `shouldReturn` False

-- | Selection facts for one catalog group: its reason, whether it was
-- selected, and whether its own inputs changed.
data Selection = Selection String Bool Bool
  deriving (Eq, Show)

selectionOf ∷ FilePath → String → IO (Maybe Selection)
selectionOf plan identifier = do
  document ← parseJson <$> readFile plan
  pure $ do
    entry ← document >>= field "groups" >>= entryFor "id" identifier
    reason ← field "reason" entry >>= asString
    selected ← field "selected" entry >>= asBool
    changed ← field "inputs_changed" entry >>= asBool
    pure (Selection reason selected changed)

-- | Every field a receipt must carry for a later slice to attribute it.
requiredReceiptFields ∷ [String]
requiredReceiptFields =
  [ "group"
  , "outcome"
  , "started_at"
  , "ended_at"
  , "plan_identity"
  , "head_commit"
  , "executed_commit"
  , "executed_tree"
  , "runner_os"
  , "runner_arch"
  , "input_identity"
  , "policy_version"
  , "source_run_url"
  ]

-- | Stand-ins for a revision this checkout never was, so an example can offer
-- a provenance no execution here could have produced.
integrationCommit, integrationTree ∷ String
integrationCommit = "1111111111111111111111111111111111111111"
integrationTree = "2222222222222222222222222222222222222222"

-- ---------------------------------------------------------------------------
-- Driving the tools

planAgainst ∷ Fixture → String → IO FilePath
planAgainst fixture base = planInto fixture base "plan.json"

-- | Resolve a plan with the real planner and keep it where the runner and the
-- aggregate both read it from.
planInto ∷ Fixture → String → FilePath → IO FilePath
planInto fixture base = planCandidateInto fixture base "HEAD" "HEAD"

-- | The same, for a plan whose integration candidate is not its head.
planCandidateInto ∷ Fixture → String → String → String → FilePath → IO FilePath
planCandidateInto fixture base head' candidate name =
  planWith fixture ["--base", base, "--head", head', "--candidate", candidate] name

-- | Resolve a plan with whichever planner arguments an example needs.
planWith ∷ Fixture → [String] → FilePath → IO FilePath
planWith fixture arguments name = do
  (result, output, errors) ←
    run
      (environment fixture)
      (root fixture)
      "python3"
      ((tools fixture </> "plan.py") : arguments ++ ["--json"])
  (result, errors) `shouldBe` (ExitSuccess, "")
  let target = root fixture </> name
  writeFile target output
  pure target

-- | Copy one of the real tools into the fixture's own tree, so an example can
-- drive the checkout's copy the way a hosted worker does.
vendorTool ∷ Fixture → FilePath → IO ()
vendorTool fixture name = do
  createDirectoryIfMissing True (root fixture </> "tools/validation")
  copyFile (tools fixture </> name) (root fixture </> "tools/validation" </> name)

-- | Execute a group through a nominated runner rather than the checkout's.
runFrom ∷ Fixture → FilePath → String → FilePath → IO (ExitCode, String, String)
runFrom fixture runner group plan =
  run
    (environment fixture)
    (root fixture)
    "python3"
    [runner, group, "--plan", plan, "--receipts", receiptsDirectory fixture]

runGroup ∷ Fixture → String → FilePath → [String] → IO (ExitCode, String, String)
runGroup fixture group plan extra =
  run
    (environment fixture)
    (root fixture)
    "python3"
    ( [ tools fixture </> "run.py"
      , group
      , "--plan"
      , plan
      , "--receipts"
      , receiptsDirectory fixture
      ]
        ++ extra
    )

resolveRange ∷ Fixture → [String] → IO (ExitCode, String, String)
resolveRange fixture arguments =
  run
    (environment fixture)
    (root fixture)
    "python3"
    ((tools fixture </> "range.py") : "--repo-root" : root fixture : arguments)

aggregate ∷ Fixture → FilePath → [String] → IO (ExitCode, String, String)
aggregate fixture plan extra =
  run
    (environment fixture)
    (root fixture)
    "python3"
    ( [ tools fixture </> "aggregate.py"
      , "--plan"
      , plan
      , "--receipts"
      , receiptsDirectory fixture
      ]
        ++ extra
    )

-- ---------------------------------------------------------------------------
-- Reading and tampering with receipts

receiptsDirectory ∷ Fixture → FilePath
receiptsDirectory fixture = root fixture </> "receipts"

receiptPath ∷ Fixture → String → FilePath
receiptPath fixture group = receiptsDirectory fixture </> (group ++ ".json")

readReceipt ∷ Fixture → String → IO (Maybe Json)
readReceipt fixture group = parseJson <$> readFile (receiptPath fixture group)

stringField ∷ Maybe Json → String → Maybe String
stringField document name = document >>= field name >>= asString

numberField ∷ Maybe Json → String → Maybe Double
numberField document name = case document >>= field name of
  Just (JNumber value) → Just value
  _ → Nothing

-- | Replace one string field, so an otherwise genuine receipt can claim the
-- wrong provenance without hand-writing the whole document.
patchReceipt ∷ Fixture → String → String → String → IO ()
patchReceipt fixture group name value = do
  (result, _, errors) ←
    run
      (environment fixture)
      (root fixture)
      "python3"
      [ "-c"
      , "import json,sys\n\
        \path, key, value = sys.argv[1:4]\n\
        \document = json.load(open(path, encoding='utf-8'))\n\
        \document[key] = value\n\
        \json.dump(document, open(path, 'w', encoding='utf-8'))\n"
      , receiptPath fixture group
      , name
      , value
      ]
  (result, errors) `shouldBe` (ExitSuccess, "")

-- | Copy one document's recorded catalog digest into another, so a doctored
-- plan can carry a digest matching the catalog beside it.
copyCatalogDigest ∷ Fixture → FilePath → FilePath → IO ()
copyCatalogDigest fixture source target = do
  (result, _, errors) ←
    run
      (environment fixture)
      (root fixture)
      "python3"
      [ "-c"
      , "import json,sys\n\
        \source, target = sys.argv[1:3]\n\
        \recorded = json.load(open(source, encoding='utf-8'))\n\
        \document = json.load(open(target, encoding='utf-8'))\n\
        \document['catalog']['candidate_digest'] = recorded['catalog']['candidate_digest']\n\
        \json.dump(document, open(target, 'w', encoding='utf-8'))\n"
      , source
      , target
      ]
  (result, errors) `shouldBe` (ExitSuccess, "")

-- | Replace one top-level field of a JSON document with a literal value, so an
-- otherwise genuine plan or receipt can contradict itself.
patchDocument ∷ Fixture → FilePath → String → String → IO ()
patchDocument fixture plan name value = do
  (result, _, errors) ←
    run
      (environment fixture)
      (root fixture)
      "python3"
      [ "-c"
      , "import json,sys\n\
        \path, key, value = sys.argv[1:4]\n\
        \document = json.load(open(path, encoding='utf-8'))\n\
        \document[key] = json.loads(value)\n\
        \json.dump(document, open(path, 'w', encoding='utf-8'))\n"
      , plan
      , name
      , value
      ]
  (result, errors) `shouldBe` (ExitSuccess, "")

-- | A structurally valid plan that registers nothing. Every worker would skip
-- and every group would be vacuously accounted for.
emptyPlan ∷ String
emptyPlan =
  unlines
    [ "{"
    , "  \"schema_version\": 2,"
    , "  \"policy_version\": \"eeee\","
    , "  \"catalog_policy_version\": 1,"
    , "  \"input_identity\": \"ffff\","
    , "  \"runner_os\": \"Linux\","
    , "  \"catalog\": {\"source\": \"fixture\", \"override\": null,"
    , "               \"candidate_digest\": \"aaaa\", \"groups\": 0},"
    , "  \"toolchain\": {},"
    , "  \"base\": {\"commit\": \"aaaa\", \"tree\": \"bbbb\"},"
    , "  \"head\": {\"commit\": \"cccc\", \"tree\": \"dddd\"},"
    , "  \"candidate\": {\"commit\": \"cccc\", \"tree\": \"dddd\"},"
    , "  \"request\": {\"ids\": [], \"all_hspec\": false, \"resolved\": []},"
    , "  \"groups\": [],"
    , "  \"selected\": []"
    , "}"
    ]

-- | Whether a process identifier has stopped existing, polled within a bound.
reaped ∷ Fixture → String → Int → IO Bool
reaped _ _ 0 = pure False
reaped fixture pid attempts = do
  (result, _, _) ← run (environment fixture) (root fixture) "kill" ["-0", pid]
  case result of
    ExitFailure _ → pure True
    ExitSuccess → threadDelay 100000 >> reaped fixture pid (attempts - 1)

-- ---------------------------------------------------------------------------
-- The fixture repository

withFixture ∷ (Fixture → IO a) → IO a
withFixture action = do
  checkout ← getCurrentDirectory
  settings ← sanitizedEnvironment
  withSystemTempDirectory "hetoimasia-execution" $ \directory → do
    let fixture =
          Fixture directory (checkout </> "tools/validation") settings "" ""
    void $ git settings directory ["init", "-b", "master"]
    writeFixtureFile directory "README.md" "fixture\n"
    void $ git settings directory ["add", "."]
    void $ git settings directory ["commit", "-q", "-m", "Seed a project without validation"]
    firstCommit ← revision fixture "HEAD"
    mapM_ (uncurry (writeFixtureFile directory)) fixtureFiles
    void $ git settings directory ["add", "."]
    void $ git settings directory ["commit", "-q", "-m", "Seed the fixture project"]
    secondCommit ← revision fixture "HEAD"
    createDirectoryIfMissing True (directory </> "receipts")
    action fixture {seeded = secondCommit, initial = firstCommit}

gitIn ∷ Fixture → [String] → IO String
gitIn fixture = git (environment fixture) (root fixture)

-- | The object a revision records at one path.
blobOf ∷ Fixture → String → FilePath → IO String
blobOf fixture revision' path = do
  listing ← gitIn fixture ["ls-tree", revision', "--", path]
  case words listing of
    (_ : _ : object : _) → pure object
    _ → fail ("no object recorded for " ++ path ++ " at " ++ revision')

revision ∷ Fixture → String → IO String
revision fixture name = revisionIn fixture (root fixture) name

-- | The same, resolved inside another checkout — a submodule, for instance.
revisionIn ∷ Fixture → FilePath → String → IO String
revisionIn fixture where' name =
  takeWhile (/= '\n') <$> git (environment fixture) where' ["rev-parse", name]

change ∷ Fixture → FilePath → String → IO ()
change fixture path contents = do
  writeFixtureFile (root fixture) path contents
  void $ gitIn fixture ["add", "-A", "."]
  void $ gitIn fixture ["commit", "-q", "-m", "Change " ++ path]

requestBlock ∷ [String] → String
requestBlock entries =
  unlines (["Some pull request prose.", "", "```validation-request"] ++ entries ++ ["```"])

fixtureFiles ∷ [(FilePath, String)]
fixtureFiles =
  [ (".gitignore", fixtureIgnore)
  , ("cabal.project", "packages:\n  .\n")
  , ("demo.cabal", demoPackage)
  , ("app/Main.hs", "module Main (main) where\nmain :: IO ()\nmain = pure ()\n")
  , ("src/note.txt", "a source the failing group consumes\n")
  , ("slow/note.txt", "an input the slow group consumes\n")
  , ("stubborn/note.txt", "an input the stubborn group consumes\n")
  , ("probe/note.txt", "an input the optional group consumes\n")
  , ("flag/value", "good\n")
  , ("docs/consumed.md", "a document the flag group consumes\n")
  , ("docs/alternate.md", "a document only the alternate catalog consumes\n")
  , ("tools/validation/catalog.json", fixtureCatalog)
  ]

demoPackage ∷ String
demoPackage = demoPackageWith "app"

-- | The same package, deriving its inputs from whichever source directories an
-- example needs it to declare.
demoPackageWith ∷ String → String
demoPackageWith directories =
  unlines
    [ "cabal-version: 3.16"
    , "name: demo"
    , "version: 0.1.0.0"
    , "synopsis: Fixture package"
    , "build-type: Simple"
    , ""
    , "executable demo"
    , "    main-is: Main.hs"
    , "    hs-source-dirs: " ++ directories
    , "    default-language: GHC2024"
    , "    build-depends: base"
    ]

-- | A catalog whose commands decide their own outcome, so an example can
-- exercise a pass, a failure, and an exhausted budget without a compiler.
fixtureCatalog ∷ String
fixtureCatalog = fixtureCatalogWith "[\"*.md\", \".gitignore\", \"LICENSE\"]"

-- | The same catalog with whichever non-affecting classes an example needs, so
-- one can widen them and still be refused for editing the catalog itself.
fixtureCatalogWith ∷ String → String
fixtureCatalogWith nonAffecting =
  unlines
    [ "{"
    , "  \"schema_version\": 1,"
    , "  \"policy_version\": 1,"
    , "  \"policy_inputs\": [\"tools/validation/catalog.json\"],"
    , "  \"non_affecting_paths\": " ++ nonAffecting ++ ","
    , "  \"generated_paths\": " ++ fixtureGenerated ++ ","
    , "  \"floor\": [\"build.pass\"],"
    , "  \"groups\": ["
    , groupDocument "build.pass" "[\"true\"]" "[]" "none" "build" "60" "false" ++ ","
    , groupDocument "test.fail" "[\"false\"]" "[\"src/\"]" "hspec" "test" "60" "false" ++ ","
    , groupDocumentFor "test.flag" "\"demo:exe:demo\"" flagCommand flagInputs "hspec" "test" "60" "false" ++ ","
    , groupDocument "smoke.slow" slowCommand "[\"slow/\"]" "none" "smoke" "1" "false" ++ ","
    , groupDocument "smoke.stubborn" stubbornCommand "[\"stubborn/\"]" "none" "smoke" "1" "false" ++ ","
    , groupDocument "probe.optional" "[\"true\"]" "[\"probe/\"]" "hspec" "probe" "60" "true"
    , "  ]"
    , "}"
    ]

-- | A catalog that consumes a document the committed one leaves as harmless
-- prose, so an example can tell which of the two classified a dirty checkout.
alternateCatalog ∷ String
alternateCatalog =
  unlines
    [ "{"
    , "  \"schema_version\": 1,"
    , "  \"policy_version\": 1,"
    , "  \"policy_inputs\": [\"tools/validation/catalog.json\"],"
    , "  \"non_affecting_paths\": [\"*.md\", \".gitignore\", \"LICENSE\"],"
    , "  \"generated_paths\": " ++ fixtureGenerated ++ ","
    , "  \"floor\": [\"build.pass\"],"
    , "  \"groups\": ["
    , groupDocument "build.pass" "[\"true\"]" "[\"docs/alternate.md\"]" "none" "build" "60" "false"
    , "  ]"
    , "}"
    ]

-- | A group whose outcome is decided by the tree it reads rather than by the
-- catalog, so an example can tell one committed revision's verdict from
-- another's. Its declared Markdown input is what proves a consumed document is
-- never harmless prose.
flagCommand ∷ String
flagCommand = "[\"sh\", \"-c\", \"test \\\"$(cat flag/value)\\\" = good\"]"

-- | `fixtures/consumed.txt` is an exact input inside a directory the fixture
-- declares generated, so an example can prove that calling a directory a run's
-- own output does not make what is dropped inside it stop being an input.
flagInputs ∷ String
flagInputs = "[\"flag/\", \"docs/consumed.md\", \"fixtures/consumed.txt\"]"

-- | A shell that backgrounds a long sleep and records it, so an example can ask
-- whether the timeout reached the descendant rather than only the shell.
slowCommand ∷ String
slowCommand = "[\"sh\", \"-c\", \"sleep 300 & echo $! > child.pid; wait\"]"

-- | A shell that exits on SIGTERM while the child it started ignores it, so an
-- example can tell a group-wide kill apart from one aimed at the leader.
stubbornCommand ∷ String
stubbornCommand =
  "[\"sh\", \"-c\", \"(trap '' TERM; sleep 300) & echo $! > child.pid; wait\"]"

groupDocument ∷ String → String → String → String → String → String → String → String
groupDocument identifier = groupDocumentFor identifier "null"

-- | The same, for a group whose inputs are derived from a real component, so an
-- example can exercise the package graph the classifier reads.
groupDocumentFor ∷ String → String → String → String → String → String → String → String → String
groupDocumentFor identifier component command inputs framework category timeout optional =
  init $
    unlines
      [ "    {"
      , "      \"id\": \"" ++ identifier ++ "\","
      , "      \"description\": \"Fixture group " ++ identifier ++ ".\","
      , "      \"command\": " ++ command ++ ","
      , "      \"component\": " ++ component ++ ","
      , "      \"inputs\": " ++ inputs ++ ","
      , "      \"framework\": \"" ++ framework ++ "\","
      , "      \"runner\": \"cpu\","
      , "      \"timeout_seconds\": " ++ timeout ++ ","
      , "      \"category\": \"" ++ category ++ "\","
      , "      \"optional\": " ++ optional
      , "    }"
      ]
