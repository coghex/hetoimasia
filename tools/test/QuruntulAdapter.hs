-- | The quruntul adapter (@.quruntul/adapter.py@) is Python that the external
-- quruntul lab imports, so its checks are Python too (@.quruntul/checks.py@);
-- these examples drive them one at a time. They compare the adapter with the
-- validation catalog through a stub context, needing neither quruntul nor a
-- compiler, display or network. Both files, like the Git history they read,
-- exist only in a checkout, so from a source distribution each example is
-- pending rather than failing. They read the checkout's own history, so they
-- inherit the caller's Git configuration (a CI container's safe.directory, for
-- one) rather than the sanitized environment the fixture repositories use.
module QuruntulAdapter (spec) where

import Control.Monad (forM_)
import Sandbox (run)
import System.Directory (doesDirectoryExist, doesFileExist, getCurrentDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import Test.Hspec (Spec, describe, it, pendingWith, shouldBe)

spec ∷ Spec
spec = describe "Quruntul adapter" $
  forM_
    [ "test_every_catalog_hspec_component_is_exactly_one_suite"
    , "test_probes_are_exactly_the_local_only_optional_groups"
    , "test_desktop_suites_are_the_display_runner_groups"
    , "test_build_routes_follow_the_project_files"
    , "test_platform_bound_probes"
    , "test_identities_are_stable_and_distinct"
    , "test_desktop_consent_is_per_command_on_macos_and_an_isolated_display_on_linux"
    , "test_the_adapter_imports_nothing_from_quruntul"
    ] $ \name →
      it name $ do
        root ← getCurrentDirectory
        checks ← doesFileExist (root </> ".quruntul" </> "checks.py")
        checkout ← doesDirectoryExist (root </> ".git")
        repository ← doesFileExist (root </> ".git")
        if not checks || not (checkout || repository)
          then pendingWith "the quruntul adapter and the Git history it reads are checkout-only"
          else do
            environment ← getEnvironment
            (result, output, errors) ← run environment root "python3" [".quruntul/checks.py", "AdapterChecks." ++ name]
            (result, if result == ExitSuccess then "" else output ++ errors) `shouldBe` (ExitSuccess, "")
