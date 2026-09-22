"""Focused Python-boundary checks invoked individually by workflow-tests.

SQLite transactions, lock inheritance and guardian death need Python/process
fixtures. Hspec owns discovery/selection and treats each invariant as an example.
No real engine or compiler runs here; all paths are temporary.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from catalog import rank, validate
from common import LabError, atomic_json, file_hash
from lab import check_report, recover, retained_trial
import process
from state import State


def fixture_probe(**changes):
    return validate(dict(id="sample", kind="command", description="A fixture", command=[sys.executable, "probe.py"],
                         inputs=["probe.py"], checks=["sample-check"], **changes))


class LabChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hetoimasia-flake-check-")
        self.root = Path(self.temp.name)
        self.state = State(self.root / "lab")

    def tearDown(self):
        self.state.db.close()
        self.temp.cleanup()

    def run_child(self, code, timeout=2):
        with self.state.execution_lock() as lock:
            return process.run([sys.executable, "-c", code], self.root, dict(os.environ),
                               self.root / "attempt", timeout, lock, lambda: None, grace=0.1)

    def test_history_immutable_and_idempotent(self):
        p = fixture_probe()
        self.state.begin("one", p, "flake", "a" * 40, "key", {"probe": p})
        self.state.start_attempt("one", 1, {})
        result = dict(outcome="failed", returncode=1)
        self.state.finish_attempt("one", 1, result)
        self.state.finish_attempt("one", 1, result)
        with self.assertRaises(LabError):
            self.state.finish_attempt("one", 1, dict(outcome="passed"))
        self.assertEqual(len(self.state.attempts("one")), 1)
        self.state.finish("one", "complete", {})
        self.state.finish("one", "complete", {})
        self.assertEqual(len(self.state.histories()), 1)

    def test_transaction_rolls_back(self):
        with self.assertRaises(RuntimeError):
            with self.state.transaction():
                self.state.event("temporary", {})
                raise RuntimeError("interrupted transaction")
        self.assertEqual(self.state.db.execute("SELECT count(*) FROM events").fetchone()[0], 0)

    def test_shared_execution_lock(self):
        with self.state.execution_lock() as first:
            self.assertIsNotNone(first)
            other = State(self.state.directory)
            with other.execution_lock() as second:
                self.assertIsNone(second)
            other.db.close()
        with self.state.execution_lock() as third:
            self.assertIsNotNone(third)

    def test_future_schema_refused(self):
        self.state.db.execute("PRAGMA user_version=99")
        with self.assertRaises(LabError):
            State(self.state.directory)

    def test_deferral_survives_explicit_selection(self):
        p = fixture_probe(optional=True)
        self.state.defer(p["id"], "needs fixture", "fixture repaired")
        chosen, skipped = rank([p], [], self.state.deferred(), "flake", {"sample": "key"}, 5000, "Darwin", "sample")
        self.assertIsNone(chosen)
        self.assertIn("deferred", skipped["sample"])
        with self.assertRaises(LabError):
            self.state.resume("sample", "")
        self.state.resume("sample", "fixture repair verified at commit abc")
        self.assertEqual(self.state.deferred(), {})

    def test_selection_freshness_and_modes(self):
        p = fixture_probe(optional=False)
        self.assertIsNone(rank([p], [], {}, "test", {"sample": "key"}, 5000, "Darwin")[0])
        history = [dict(probe_id="sample", mode="flake", identity="key", finished_epoch=4900, state="complete")]
        self.assertIsNone(rank([p], history, {}, "flake", {"sample": "key"}, 5000, "Darwin")[0])
        self.assertEqual(rank([p], history, {}, "flake", {"sample": "changed"}, 5000, "Darwin")[0], p)
        self.assertEqual(rank([p], history, {}, "flake", {"sample": "key"}, 100000, "Darwin")[0], p)
        self.assertEqual(rank([p], history, {}, "flake", {"sample": "key"}, 5000, "Darwin", "sample")[0], p)

    def test_platform_and_desktop_excluded(self):
        p = fixture_probe(platforms=["Linux"])
        self.assertIsNone(rank([p], [], {}, "flake", {"sample": "key"}, 5000, "Darwin", "sample")[0])
        p = fixture_probe(desktop=True)
        self.assertIsNone(rank([p], [], {}, "flake", {"sample": "key"}, 5000, "Darwin", "sample")[0])

    def test_proposals_deduplicate_and_retain_disposition(self):
        p = dict(probe_id="missing", question="Does cancellation publish?", gap="No assertion", scenario="Cancel at publication", oracle="Exactly one result", cost="one second", tier="optional", revision="a" * 40)
        first = self.state.propose(p)
        self.assertEqual(self.state.propose(p), first)
        self.state.close_proposal(first, "accepted", "owner approved planning")
        self.assertEqual(self.state.proposals()[0]["status"], "accepted")
        self.assertEqual(len(self.state.proposals()), 1)

    def test_success_failure_and_crash_distinct(self):
        self.assertEqual(self.run_child("print('evidence')")["outcome"], "passed")
        self.assertEqual(self.run_child("raise SystemExit(1)")["outcome"], "failed")
        self.assertEqual(self.run_child("import os, signal; os.kill(os.getpid(), signal.SIGKILL)")["outcome"], "crashed")

    def test_timeout_reaps_stubborn_descendant(self):
        pid = self.root / "child.pid"
        child = f"import os,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); open({str(pid)!r},'w').write(str(os.getpid())); time.sleep(60)"
        code = f"import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',{child!r}]); time.sleep(60)"
        result = self.run_child(code, timeout=0.5)
        self.assertEqual(result["outcome"], "timeout")
        self.assertTrue(pid.exists())
        self.assert_stopped(int(pid.read_text()))

    def assert_stopped(self, pid):
        for _ in range(100):
            found = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], text=True, capture_output=True)
            if not found.stdout.strip() or found.stdout.strip().startswith("Z"):
                return
            time.sleep(0.02)
        self.fail(f"owned child {pid} survived")

    def test_leaked_child_is_not_a_pass(self):
        code = "import subprocess,sys; subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'])"
        self.assertEqual(self.run_child(code)["outcome"], "harness-error")

    def test_parent_death_stops_child_and_releases_lock(self):
        pid = self.root / "child.pid"
        ready = self.root / "ready"
        code = f"import os,time; open({str(pid)!r},'w').write(str(os.getpid())); time.sleep(60)"
        wrapper = f"""import sys,os
sys.path.insert(0,{str(Path(__file__).parent)!r})
from pathlib import Path
from state import State
import process
state=State(Path({str(self.state.directory)!r}))
with state.execution_lock() as lock:
    Path({str(ready)!r}).write_text('ready')
    process.run([sys.executable,'-c',{code!r}],Path({str(self.root)!r}),dict(os.environ),Path({str(self.root / 'death')!r}),60,lock,lambda:None,grace=0.1)
"""
        parent = subprocess.Popen([sys.executable, "-c", wrapper], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            until = time.monotonic() + 5
            while not pid.exists() and parent.poll() is None and time.monotonic() < until:
                time.sleep(0.02)
            self.assertTrue(pid.exists())
            parent.kill()
            parent.wait(timeout=5)
            self.assert_stopped(int(pid.read_text()))
            until = time.monotonic() + 5
            while time.monotonic() < until:
                with self.state.execution_lock() as lock:
                    if lock is not None:
                        return
                time.sleep(0.02)
            self.fail("guardian retained the execution lock")
        finally:
            if parent.poll() is None:
                parent.kill()
            parent.communicate(timeout=5)

    def test_empty_or_inconsistent_probe_report_refused(self):
        p = fixture_probe()
        result = dict(outcome="passed", returncode=0)
        report = self.root / "checks.json"
        self.assertEqual(check_report(p, result, report)["outcome"], "harness-error")
        atomic_json(report, dict(schema="hetoimasia-probe/v1", checks={}))
        self.assertEqual(check_report(p, result, report)["outcome"], "harness-error")
        atomic_json(report, dict(schema="hetoimasia-probe/v1", checks={"sample-check": "failed"}))
        self.assertEqual(check_report(p, result, report)["outcome"], "harness-error")
        atomic_json(report, dict(schema="hetoimasia-probe/v1", checks={"sample-check": "unproven"}))
        self.assertEqual(check_report(p, dict(outcome="failed", returncode=1), report)["outcome"], "inconclusive")

    def test_recovery_ingests_once_and_does_not_invent_passes(self):
        p = fixture_probe()
        self.state.begin("one", p, "flake", "a" * 40, "key", {"probe": p})
        self.state.start_attempt("one", 1, {})
        directory = self.state.directory / "runs/one"
        directory.mkdir(parents=True)
        log = directory / "trial-0001.log"
        log.write_text("checks passed")
        result = dict(outcome="passed", returncode=0, token="trial-0001", log=str(log), log_sha256=file_hash(log))
        atomic_json(directory / "trial-0001.result.json", result)
        # No check report: raw exit zero cannot become a pass during recovery.
        with self.state.execution_lock():
            recover(self.state)
            recover(self.state)
        self.assertEqual(self.state.attempts("one")[0]["state"], "harness-error")
        self.assertEqual(len(self.state.attempts("one")), 1)
        self.assertEqual(self.state.histories()[0]["state"], "interrupted")

    def test_markdown_regenerates_from_history(self):
        self.state.inventory("a" * 40, [fixture_probe()])
        path = self.state.render()
        self.assertIn("sample", path.read_text())
        path.write_text("stale view")
        self.state.render()
        self.assertNotIn("stale view", path.read_text())

    def repository_fixture(self):
        root = self.root / "repo"
        root.mkdir()
        source = Path(__file__).resolve().parents[1]
        shutil.copytree(source / "flake", root / "tools/flake", ignore=shutil.ignore_patterns("__pycache__"))
        shutil.copytree(source / "validation", root / "tools/validation", ignore=shutil.ignore_patterns("__pycache__"))
        (root / "tools/flake/probes.json").write_text('{"schema_version":1,"probes":[]}')
        (root / "tools/validation/catalog.json").write_text('{"groups":[]}')
        (root / ".github/workflows").mkdir(parents=True)
        (root / ".github/workflows/validation.yml").write_text("jobs: {}\n")
        (root / "cabal.project").write_text("packages: .\n")
        (root / "sample.cabal").write_text("cabal-version: 3.16\nname: sample\nversion: 0.1.0.0\nbuild-type: Simple\nlibrary\n    hs-source-dirs: src\n    build-depends: base\n")
        (root / "probe.py").write_text("import os,sys,json\nfrom pathlib import Path\nfailed=os.environ['HETOIMASIA_LAB_ATTEMPT']=='1'\nPath(os.environ['HETOIMASIA_PROBE_RESULT']).write_text(json.dumps({'schema':'hetoimasia-probe/v1','checks':{'sample-check':'failed' if failed else 'passed'}}))\nprint('retained evidence')\nsys.exit(1 if failed else 0)\n")
        env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
                   GIT_AUTHOR_NAME="Test", GIT_AUTHOR_EMAIL="test@example.invalid",
                   GIT_COMMITTER_NAME="Test", GIT_COMMITTER_EMAIL="test@example.invalid")
        for args in [["init", "-q"], ["add", "."], ["commit", "-qm", "fixture"]]:
            subprocess.run(["git", *args], cwd=root, env=env, check=True, capture_output=True)
        return root, env

    def invoke(self, root, env, *args):
        return subprocess.run([sys.executable, "tools/flake/lab.py", *args], cwd=root, env=env,
                              capture_output=True, text=True, timeout=20)

    def test_full_batch_records_all_attempts_and_export(self):
        root, env = self.repository_fixture()
        declaration = self.root / "probe.json"
        declaration.write_text(json.dumps(fixture_probe(optional=True, attempts=2)))
        self.assertEqual(self.invoke(root, env, "register", str(declaration)).returncode, 0)
        measured = self.invoke(root, env, "run", "--ref", "HEAD")
        self.assertEqual(measured.returncode, 0, measured.stdout + measured.stderr)
        db = State(root / ".git/flake-lab")
        try:
            history = db.histories()
            self.assertEqual(len(history), 1)
            self.assertEqual([a['state'] for a in db.attempts(history[0]['id'])], ['failed', 'passed'])
            self.assertEqual(history[0]['state'], 'complete')
            previous = self.invoke(root, env, "run", "--ref", "HEAD")
            self.assertIn('no-candidate', previous.stdout)
            self.assertEqual(len(db.histories()), 1)
            # test mode is one execution and uses the same history owner.
            once = self.invoke(root, env, "run", "--ref", "HEAD", "--mode", "test", "--probe", "sample")
            self.assertEqual(once.returncode, 0, once.stdout + once.stderr)
            self.assertEqual(len(db.histories()), 2)
            self.assertEqual(len(db.attempts(db.histories()[0]['id'])), 1)
            archive = self.root / "export.zip"
            exported = self.invoke(root, env, "export", "--output", str(archive))
            self.assertEqual(exported.returncode, 0, exported.stderr)
            import zipfile
            with zipfile.ZipFile(archive) as z:
                self.assertIn('history.json', z.namelist())
                self.assertTrue(any(n.endswith('trial-0001.log') for n in z.namelist()))
            self.assertNotEqual(self.invoke(root, env, "export", "--output", str(archive)).returncode, 0)
        finally:
            db.db.close()

    def test_source_identity_ignores_prose_and_changes_for_consumed_input(self):
        root, env = self.repository_fixture()
        from catalog import Catalog
        p = fixture_probe()
        original = Catalog(root, 'HEAD', [p]).identity(p, {})
        for path, content, expected_same in [('README.md', 'prose', True), ('probe.py', 'changed probe', False)]:
            (root / path).write_text(content)
            subprocess.run(['git', 'add', path], cwd=root, env=env, check=True, capture_output=True)
            subprocess.run(['git', 'commit', '-qm', path], cwd=root, env=env, check=True, capture_output=True)
            current = Catalog(root, 'HEAD', [p]).identity(p, {})
            self.assertEqual(original == current, expected_same)

    def test_existing_registration_cannot_silently_change_contract(self):
        self.state.register(fixture_probe())
        with self.assertRaises(LabError):
            self.state.register(fixture_probe(attempts=99))
        self.assertEqual(self.state.registrations()[0]['attempts'], 20)

    def test_skill_install_preserves_other_workflows_and_is_idempotent(self):
        from install_skills import install
        root = self.root / 'skills'
        original = '---\nname: flake\ndescription: old\n---\nSynarchy tools/probe_census.py tools/deflake.py\n'
        for name in ['flake', 'test', 'autotest']:
            path = root / name / 'SKILL.md'
            path.parent.mkdir(parents=True)
            path.write_text(original if name == 'flake' else f'---\nname: {name}\ndescription: preserve\n---\nOriginal {name} workflow.\n')
        install(root, True)
        first = {str(p.relative_to(root)): p.read_text() for p in root.rglob('*.md')}
        self.assertEqual((root / 'flake/references/synarchy.md').read_text(), original)
        self.assertIn('Original test workflow.', (root / 'test/SKILL.md').read_text())
        install(root, True)
        self.assertEqual(first, {str(p.relative_to(root)): p.read_text() for p in root.rglob('*.md')})

    def test_malformed_declarations_and_reports_fail_closed(self):
        for changes in [dict(id=4), dict(checks=[[]]), dict(attempts=True), dict(source_group=[]), dict(command='shell string'), dict(batch_seconds=1, trial_seconds=2)]:
            declaration = fixture_probe()
            declaration.update(changes)
            with self.assertRaises(LabError):
                validate(declaration)
        report = self.root / 'checks.json'
        atomic_json(report, dict(schema='hetoimasia-probe/v1', checks=['sample-check']))
        result = check_report(fixture_probe(), dict(outcome='passed', returncode=0), report)
        self.assertEqual(result['outcome'], 'harness-error')


if __name__ == "__main__":
    unittest.main()
