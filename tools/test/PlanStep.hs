-- | Hspec coverage for the MEMORY.md rule as the validation workflow applies
-- it.
--
-- The planner applies the rule only when it is told the range is a pull
-- request's, so the rule is only as good as the plan step that says so. These
-- examples extract that step's own @run@ body out of
-- @.github/workflows/validation.yml@ and execute it, with the checked-in
-- catalog and the worker declarations the step itself passes, once as a pull
-- request whose body requests nothing and once as a push of the same change.
-- What is asserted is therefore the shell that actually ships: that the event
-- alone decides, and that the refusal reaches the job summary.
module PlanStep (spec) where

import Control.Monad (void)
import Data.List (isPrefixOf)
import Sandbox (fixtureIgnore, git, run, sanitizedEnvironment, workflowStepBody, writeFixtureFile)
import System.Directory (getCurrentDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, shouldBe, shouldContain, shouldNotBe, shouldNotContain, shouldSatisfy)

data Fixture = Fixture
  { root ∷ FilePath
  , scratch ∷ FilePath
  , environment ∷ [(String, String)]
  , base ∷ String
  , head' ∷ String
  }

-- | What one run of the step left behind.
data Outcome = Outcome
  { result ∷ ExitCode
  , logged ∷ String
  , outputs ∷ String
  , summary ∷ String
  }

spec ∷ Spec
spec = describe "The plan step's MEMORY.md rule" $ do
  it "refuses a pull request whose body requests nothing when it changes MEMORY.md beside code" $
    withFixture $ \fixture → do
      outcome ← planStep fixture "pull_request"
      result outcome `shouldNotBe` ExitSuccess
      logged outcome `shouldContain` "::error::the validation planner failed"
      summary outcome `shouldContain` "the MEMORY.md rule refuses this pull request"
      summary outcome `shouldContain` "(tools/feature.sh)"
      summary outcome `shouldContain` "Drop the MEMORY.md edit"
      lines (outputs outcome) `shouldSatisfy` all (not . ("selected=" `isPrefixOf`))

  it "plans the same change when it is pushed to master" $
    withFixture $ \fixture → do
      outcome ← planStep fixture "push"
      (result outcome, logged outcome) `shouldBe` (ExitSuccess, "")
      lines (outputs outcome) `shouldSatisfy` any ("selected=build.all" `isPrefixOf`)
      summary outcome `shouldContain` "## Validation plan"
      summary outcome `shouldNotContain` "MEMORY.md rule"

-- ---------------------------------------------------------------------------
-- Running the shipped step

-- | Run the step as the named event would, with an empty pull-request body
-- captured for a pull request exactly as the capture step writes it.
planStep ∷ Fixture → String → IO Outcome
planStep fixture event = do
  checkout ← getCurrentDirectory
  body ← workflowStepBody checkout ".github/workflows/validation.yml" "Resolve the plan"
  writeFixtureFile (scratch fixture) "step.sh" body
  writeFixtureFile (scratch fixture) "output" ""
  writeFixtureFile (scratch fixture) "summary" ""
  writeFixtureFile (root fixture) "request.txt" ""
  let step =
        overriding
          [ ("EVENT_NAME", event)
          , ("BASE", base fixture)
          , ("HEAD", head' fixture)
          , ("CANDIDATE", head' fixture)
          , ("GHC_VERSION", "9.14.1")
          , ("CABAL_VERSION", "3.18.1.0")
          , ("WORKER_OS", "Linux")
          , ("GITHUB_OUTPUT", scratch fixture </> "output")
          , ("GITHUB_STEP_SUMMARY", scratch fixture </> "summary")
          ]
          (environment fixture)
  (exit, stdout', stderr') ← run step (root fixture) "bash" [scratch fixture </> "step.sh"]
  written ← readFile (scratch fixture </> "output")
  reported ← readFile (scratch fixture </> "summary")
  pure (Outcome exit (stdout' ++ stderr') written reported)

-- | The step's environment replaces, rather than joins, whatever the test
-- process inherited: under CI this suite itself runs inside a job whose own
-- output and summary files must not receive the fixture's.
overriding ∷ [(String, String)] → [(String, String)] → [(String, String)]
overriding overrides inherited = overrides ++ filter ((`notElem` map fst overrides) . fst) inherited

-- ---------------------------------------------------------------------------
-- The fixture repository

-- | A repository carrying this checkout's own catalog, one minimal package per
-- component it names, a root MEMORY.md, and a stand-in @plan.py@ that runs this
-- checkout's planner, so the step's relative invocation finds it. Its head
-- changes MEMORY.md and a file that is not Markdown.
withFixture ∷ (Fixture → IO a) → IO a
withFixture action = do
  checkout ← getCurrentDirectory
  settings ← sanitizedEnvironment
  withSystemTempDirectory "hetoimasia-plan-step" $ \directory → do
    let repository = directory </> "repository"
        outside = directory </> "scratch"
    writeFixtureFile repository ".gitignore" fixtureIgnore
    writeFixtureFile repository "README.md" "ordinary prose\n"
    writeFixtureFile repository "MEMORY.md" "durable context\n"
    writeFixtureFile repository "tools/validation/plan.py" (standIn checkout)
    (generated, _, errors) ←
      run settings repository "python3" ["-c", checkedInPackages, checkout </> "tools/validation/catalog.json"]
    (generated, errors) `shouldBe` (ExitSuccess, "")
    void $ git settings repository ["init", "-q", "-b", "master"]
    void $ git settings repository ["add", "-A", "."]
    void $ git settings repository ["commit", "-q", "-m", "Seed the checked-in catalog"]
    seed ← takeWhile (/= '\n') <$> git settings repository ["rev-parse", "HEAD"]
    writeFixtureFile repository "MEMORY.md" "a status paragraph for the change\n"
    writeFixtureFile repository "tools/feature.sh" "#!/bin/sh\necho feature\n"
    void $ git settings repository ["add", "-A", "."]
    void $ git settings repository ["commit", "-q", "-m", "Implement and record status"]
    changed ← takeWhile (/= '\n') <$> git settings repository ["rev-parse", "HEAD"]
    action (Fixture repository outside settings seed changed)

-- | The planner the step invokes as @tools/validation/plan.py@, relative to the
-- repository it plans; this runs the checkout's own with the same arguments.
standIn ∷ FilePath → String
standIn checkout =
  unlines
    [ "import os, sys"
    , "planner = " ++ show (checkout </> "tools/validation/plan.py")
    , "os.execv(sys.executable, [sys.executable, planner] + sys.argv[1:])"
    ]

-- | Copy the checked-in catalog and give each component it names a package
-- description, so the catalog validates and the step's worker declarations
-- route against it. Nothing executes, so the groups' commands are untouched.
checkedInPackages ∷ String
checkedInPackages =
  unlines
    [ "import json, os, sys"
    , "catalog = json.load(open(sys.argv[1], encoding='utf-8'))"
    , "packages = {}"
    , "for group in catalog['groups']:"
    , "    if group['component'] not in (None, 'all'):"
    , "        package, kind, name = group['component'].split(':')"
    , "        packages.setdefault(package, set()).add((kind, name))"
    , "os.makedirs('tools/validation', exist_ok=True)"
    , "json.dump(catalog, open('tools/validation/catalog.json', 'w', encoding='utf-8'), indent=2)"
    , "stanza = {'test': 'test-suite', 'exe': 'executable', 'lib': 'library'}"
    , "for package, components in packages.items():"
    , "    os.makedirs(package, exist_ok=True)"
    , "    with open(os.path.join(package, package + '.cabal'), 'w') as description:"
    , "        description.write('cabal-version: 3.16\\nname: ' + package + '\\nversion: 0.1.0.0\\nbuild-type: Simple\\n')"
    , "        for kind, name in sorted(components):"
    , "            description.write('\\n' + stanza[kind] + ' ' + name + '\\n    main-is: Main.hs\\n    hs-source-dirs: ' + name + '\\n    default-language: GHC2024\\n    build-depends: base\\n')"
    , "open('cabal.project', 'w').write('packages:\\n' + ''.join('  ' + package + '\\n' for package in sorted(packages)))"
    ]
