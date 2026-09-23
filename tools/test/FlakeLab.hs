-- | Python owns SQLite transactions and guardian processes; these examples
-- exercise those boundaries through disposable Python fixtures, without an engine.
module FlakeLab (spec) where

import Control.Monad (forM_)
import Sandbox (run, sanitizedEnvironment)
import System.Directory (getCurrentDirectory)
import System.Exit (ExitCode (ExitSuccess))
import Test.Hspec (Spec, describe, it, shouldBe)

spec ∷ Spec
spec = describe "Local flake lab" $
  forM_
    [ "test_history_immutable_and_idempotent"
    , "test_transaction_rolls_back"
    , "test_shared_execution_lock"
    , "test_future_schema_refused"
    , "test_deferral_survives_explicit_selection"
    , "test_selection_freshness_and_modes"
    , "test_platform_and_desktop_excluded"
    , "test_proposals_deduplicate_and_retain_disposition"
    , "test_success_failure_and_crash_distinct"
    , "test_timeout_reaps_stubborn_descendant"
    , "test_timeout_preserves_outcome_for_exited_unreaped_member"
    , "test_leaked_child_is_not_a_pass"
    , "test_parent_death_stops_child_and_releases_lock"
    , "test_empty_or_inconsistent_probe_report_refused"
    , "test_recovery_ingests_once_and_does_not_invent_passes"
    , "test_markdown_regenerates_from_history"
    , "test_full_batch_records_all_attempts_and_export"
    , "test_source_identity_ignores_prose_and_changes_for_consumed_input"
    , "test_existing_registration_cannot_silently_change_contract"
    , "test_skill_install_preserves_other_workflows_and_is_idempotent"
    , "test_malformed_declarations_and_reports_fail_closed"
    ] $ \name →
      it name $ do
        root ← getCurrentDirectory
        environment ← sanitizedEnvironment
        (result, output, errors) ← run environment root "python3" ["tools/flake/checks.py", "LabChecks." ++ name]
        (result, if result == ExitSuccess then "" else output ++ errors) `shouldBe` (ExitSuccess, "")
