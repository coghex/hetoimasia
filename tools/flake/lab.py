#!/usr/bin/env python3
"""Local test/flake lab. See README.md for its contract and recovery semantics."""
from __future__ import annotations

import argparse
from collections import Counter
import json
import os
from pathlib import Path
import platform
import shutil
import sys
import time
import uuid
import zipfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from catalog import Catalog, rank, validate
from common import LabError, atomic_json, command, digest, file_hash, git, utc
import process
from state import State


def paths(supplied):
    root = Path(git(Path(supplied), "rev-parse", "--show-toplevel"))
    common = Path(git(root, "rev-parse", "--path-format=absolute", "--git-common-dir"))
    return root, common, common / "flake-lab"


def revision_at(root, ref):
    if ref is None:
        # Ordinary operation refreshes upstream without moving the user's branch.
        command(["git", "fetch", "origin", "master"], root)
        ref = "origin/master"
    return git(root, "rev-parse", "--verify", ref + "^{commit}")


def environment(root):
    result = dict(os=platform.system(), release=platform.release(), architecture=platform.machine(),
                  python=platform.python_version(),
                  harness=digest({str(p.relative_to(Path(__file__).parent.parent)): file_hash(p)
                                  for directory in (Path(__file__).parent, Path(__file__).parent.parent / "validation")
                                  for p in sorted(directory.glob("*.py"))}))
    for name in ("ghc", "cabal"):
        path = shutil.which(name)
        result[name] = dict(path=str(Path(path).resolve()), version=command([name, "--numeric-version"], root)) if path else None
    # Explicit configuration reaches the build; changes invalidate lab freshness.
    result["native_search"] = {key: os.environ.get(key, "") for key in
                               ("PKG_CONFIG_PATH", "PKG_CONFIG_LIBDIR", "LIBRARY_PATH", "CPATH")}
    return result


def child_environment():
    # An ambient Hspec filter or RTS override must never silently change a trial.
    return {k: v for k, v in os.environ.items()
            if not k.startswith("HSPEC_") and k not in ("GHCRTS", "HETOIMASIA_NATIVE_SESSION",
                "HETOIMASIA_MONITOR_HOTPLUG_SECONDS", "HETOIMASIA_INTERACTION_PROBE_SECONDS")}


def worktree(root, common, revision):
    base = common.parent.parent / ("." + common.parent.name + "-flake-worktrees")
    base.mkdir(exist_ok=True)
    target = base / revision
    if not target.exists():
        command(["git", "worktree", "add", "--detach", str(target), revision], root)
    actual_common = Path(git(target, "rev-parse", "--path-format=absolute", "--git-common-dir"))
    if actual_common != common or git(target, "rev-parse", "HEAD") != revision:
        raise LabError(f"unexpected checkout at lab worktree {target}")
    if git(target, "branch", "--show-current"):
        raise LabError(f"lab worktree is no longer detached: {target}")
    if git(target, "status", "--porcelain"):
        raise LabError(f"lab worktree has changes; preserve and inspect {target}, do not reset it")
    return target


def prepare(probe, catalog, checkout, artifacts, lock_fd, heartbeat):
    env = child_environment()
    if probe["kind"] == "command":
        if probe["prepare"]:
            result = process.run(probe["prepare"], checkout, env, artifacts / "build", 1800, lock_fd, heartbeat)
            if result["outcome"] != "passed":
                raise LabError(f"probe preparation {result['outcome']}; see {result['log']}")
        return probe["command"], env, dict(build_command=probe["prepare"], execution_cwd=str(checkout))
    for tool in ("ghc", "cabal"):
        if not shutil.which(tool):
            raise LabError(f"{tool} is not on PATH; activate docs/toolchain.md's qualified toolchain")
    pins = dict(line.split("=", 1) for line in (checkout / "tools/ci-image/toolchain.pin").read_text().splitlines()
                if line and not line.startswith("#") and "=" in line)
    for tool, key in (("ghc", "GHC_VERSION"), ("cabal", "CABAL_VERSION")):
        if command([tool, "--numeric-version"], checkout) != pins[key]:
            raise LabError(f"{tool} differs from the tested revision's {key}; activate its qualified toolchain")
    target = probe["component"]
    options = ["--project-file", probe["project"]]
    build = ["cabal", "build", *options, target]
    result = process.run(build, checkout, env, artifacts / "build", 1800, lock_fd, heartbeat)
    if result["outcome"] != "passed":
        raise LabError(f"build {result['outcome']}; see {result['log']}")
    executable = Path(command(["cabal", "list-bin", *options, target], checkout))
    tools = []
    for component in catalog.tool_components(probe):
        path = Path(command(["cabal", "list-bin", *options, component], checkout))
        tools.append(dict(component=component, path=str(path), sha256=file_hash(path)))
    env["PATH"] = os.pathsep.join([str(Path(t["path"]).parent) for t in tools] + [env.get("PATH", "")])
    argv = [str(executable), "--ignore-dot-hspec", "--fail-on=empty,pending", "--no-color", "--format=specdoc",
            f"--seed={probe['seed']}"]
    if probe["match"]:
        argv += ["--match", probe["match"]]
    if probe["rts"]:
        argv += ["+RTS", *probe["rts"], "-RTS"]
    # An invalid/empty selector is preparation failure, never a passing cohort.
    execution_cwd = checkout / catalog.packages[target.split(":")[0]].directory
    dry = process.run([*argv, "--dry-run"], execution_cwd, env, artifacts / "discovery", 30, lock_fd, heartbeat)
    if dry["outcome"] != "passed":
        raise LabError(f"Hspec discovery {dry['outcome']}; see {dry['log']}")
    return argv, env, dict(build_command=build, executable=str(executable),
                           executable_sha256=file_hash(executable), build_tools=tools, execution_cwd=str(execution_cwd),
                           cabal_plan_sha256=file_hash(checkout / "dist-newstyle/cache/plan.json"))


def verify_clean(checkout, revision):
    if git(checkout, "rev-parse", "HEAD") != revision or git(checkout, "status", "--porcelain"):
        raise LabError("the measured worktree changed during the run; results are inconclusive")


def recover(state):
    """Only under execution lock: guardians also hold it until children are gone."""
    active = list(state.db.execute("SELECT id FROM runs WHERE finished_epoch IS NULL"))
    for row in active:
        identifier = row["id"]
        directory = state.directory / "runs" / identifier
        for attempt in state.attempts(identifier):
            if attempt["state"] != "running":
                continue
            number = attempt["number"]
            probe = json.loads(state.db.execute("SELECT document FROM runs WHERE id=?", (identifier,)).fetchone()[0])["probe"]
            state.finish_attempt(identifier, number, retained_trial(directory, number, probe))
        document = json.loads(state.db.execute("SELECT document FROM runs WHERE id=?", (identifier,)).fetchone()[0])
        mode = state.db.execute("SELECT mode FROM runs WHERE id=?", (identifier,)).fetchone()[0]
        summary = dict(reason="previous coordinator exited; retained trials recovered, no attempts replayed",
                       counts=dict(Counter(a["state"] for a in state.attempts(identifier))),
                       planned_attempts=1 if mode == "test" else document["probe"]["attempts"],
                       interpretation="inconclusive")
        state.finish(identifier, "interrupted", summary)
        atomic_json(directory / "result.json", run_document(state, identifier))


def retained_trial(directory, number, probe):
    retained = directory / f"trial-{number:04}.result.json"
    if not retained.exists():
        return dict(outcome="interrupted", reason="coordinator exited before a durable trial result")
    try:
        candidate = json.loads(retained.read_text())
        log = directory / f"trial-{number:04}.log"
        if not (candidate.get("token") == f"trial-{number:04}" and candidate.get("log") == str(log)
                and log.exists() and file_hash(log) == candidate.get("log_sha256")):
            raise ValueError("retained attempt provenance or log hash differs")
        if probe["kind"] == "command" and candidate["outcome"] in ("passed", "failed"):
            candidate = check_report(probe, candidate, directory / f"trial-{number:04}.checks.json")
        return candidate
    except (ValueError, OSError, KeyError, TypeError, AttributeError) as error:
        return dict(outcome="harness-error", error=str(error))


def run_document(state, identifier):
    return next(r for r in state.snapshot()["runs"] if r["id"] == identifier)


def check_report(probe, result, path):
    """Exit zero alone cannot stand in for a probe's assertions."""
    try:
        report = json.loads(path.read_text())
        checks = report["checks"]
        if not isinstance(checks, dict) or report.get("schema") != "hetoimasia-probe/v1" or set(checks) != set(probe["checks"]):
            raise ValueError("report must contain exactly the declared checks")
        if any(v not in ("passed", "failed", "unproven") for v in checks.values()):
            raise ValueError("unknown check outcome")
        expected = 0 if all(v == "passed" for v in checks.values()) else 1
        if result["returncode"] != expected:
            raise ValueError("exit status disagrees with checks")
        return result | dict(checks=checks, check_report=str(path), check_report_sha256=file_hash(path),
                             outcome="inconclusive" if "unproven" in checks.values() and "failed" not in checks.values() else result["outcome"])
    except (OSError, ValueError, KeyError, TypeError) as error:
        return result | dict(outcome="harness-error", error=f"invalid probe report: {error}")


def measure(args, state, root, common):
    if args.desktop and not args.probe:
        raise LabError("--desktop requires one explicitly named --probe and prior human session consent")
    with state.execution_lock() as lock_fd:
        if lock_fd is None:
            return dict(outcome="busy", reason="another test/flake batch owns this repository's lab")
        recover(state)
        revision = revision_at(root, args.ref)
        catalog = Catalog(root, revision, state.registrations())
        state.inventory(revision, catalog.probes.values())
        harness_root = Path(__file__).resolve().parents[2]
        if git(harness_root, "status", "--porcelain", "--", "tools/flake", "tools/validation"):
            raise LabError("commit the lab implementation before measuring; evidence must name reproducible harness code")
        env_record = environment(root)
        env_record["harness_revision"] = git(harness_root, "rev-parse", "HEAD")
        identities = {key: catalog.identity(p, env_record) for key, p in catalog.probes.items()}
        selected, skipped = rank(list(catalog.probes.values()), state.histories(), state.deferred(),
                                 args.mode, identities, time.time(), platform.system(), args.probe, args.desktop)
        if selected is None:
            pending = [p for p in state.proposals() if p["status"] in ("pending", "accepted")]
            return dict(outcome="no-candidate", skipped=skipped, pending_proposals=pending,
                        next_step="Inspect coverage gaps; propose one useful missing probe when the eligible work is exhausted.")
        p = selected
        identifier = str(uuid.uuid4())
        artifacts = state.directory / "runs" / identifier
        artifacts.mkdir(parents=True)
        provenance = dict(schema_version=1, source_ref=args.ref or "origin/master", revision=revision,
                          probe=p, desktop_consent=args.desktop, environment=env_record, identity=identities[p["id"]], artifacts=str(artifacts))
        state.begin(identifier, p, args.mode, revision, identities[p["id"]], provenance)
        atomic_json(artifacts / "manifest.json", provenance)
        state.render()
        print(f"Preparing {p['id']} at {revision[:12]}; evidence: {artifacts}", flush=True)
        state_name, detail = "blocked", None
        try:
            checkout = worktree(root, common, revision)
            argv, env, prepared = prepare(p, catalog, checkout, artifacts, lock_fd, lambda: state.heartbeat(identifier))
            if args.desktop:
                env["HETOIMASIA_NATIVE_SESSION"] = "desktop"
            provenance.update(prepared, worktree=str(checkout), command=argv)
            atomic_json(artifacts / "manifest.json", provenance)
            state.prepared(identifier, provenance)
            verify_clean(checkout, revision)
            deadline = time.monotonic() + p["batch_seconds"]
            attempts = 1 if args.mode == "test" else p["attempts"]
            state_name = "complete"
            for number in range(1, attempts + 1):
                remaining = deadline - time.monotonic()
                if remaining < p["trial_seconds"]:
                    state_name = "budget-exhausted"
                    break
                state.start_attempt(identifier, number, dict(command=argv, started=utc()))
                trial_env = dict(env, HETOIMASIA_LAB_ATTEMPT=str(number),
                                 HETOIMASIA_PROBE_RESULT=str(artifacts / f"trial-{number:04}.checks.json"))
                result = process.run(argv, Path(prepared["execution_cwd"]), trial_env, artifacts / f"trial-{number:04}",
                                     p["trial_seconds"], lock_fd,
                                     lambda: state.heartbeat(identifier))
                if p["kind"] == "command" and result["outcome"] in ("passed", "failed"):
                    result = check_report(p, result, Path(trial_env["HETOIMASIA_PROBE_RESULT"]))
                state.finish_attempt(identifier, number, result)
                print(f"{p['id']} {number}/{attempts}: {result['outcome']} ({result['duration_seconds']:.3f}s)", flush=True)
                if result["outcome"] in ("interrupted", "harness-error", "setup-error"):
                    state_name, detail = "interrupted" if result["outcome"] == "interrupted" else "blocked", result["outcome"]
                    break
            verify_clean(checkout, revision)
            if prepared.get("executable") and file_hash(Path(prepared["executable"])) != prepared["executable_sha256"]:
                raise LabError("executable changed during measurement")
        except KeyboardInterrupt:
            state_name, detail = "interrupted", "user interrupted; owned processes stopped"
        except Exception as error:
            state_name, detail = "blocked", f"{type(error).__name__}: {error}"
        finally:
            # If interruption landed between guardian completion and ingestion,
            # consume that exact retained result; never execute the trial again.
            for a in state.attempts(identifier):
                if a["state"] == "running":
                    result = retained_trial(artifacts, a["number"], p)
                    state.finish_attempt(identifier, a["number"], result)
            counts = dict(Counter(a["state"] for a in state.attempts(identifier)))
            summary = dict(counts=counts, reason=detail, planned_attempts=1 if args.mode == "test" else p["attempts"],
                           interpretation="observations" if any(k != "passed" for k in counts) else
                           "no-failure-observed" if state_name == "complete" else "inconclusive")
            state.finish(identifier, state_name, summary)
            atomic_json(artifacts / "result.json", run_document(state, identifier))
            state.render()
        return dict(outcome=state_name, run_id=identifier, probe=p["id"], revision=revision,
                    summary=summary, result=str(artifacts / "result.json"), coordinator=str(state.directory / "coordinator.md"))


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--repo", default=".")
    sub = p.add_subparsers(dest="operation", required=True)
    run = sub.add_parser("run", help="select and measure one workload")
    run.add_argument("--mode", choices=["test", "flake"], default="flake")
    run.add_argument("--ref", help="explicit committed revision; default fetches origin/master")
    run.add_argument("--desktop", action="store_true", help="per-run desktop consent; only after explicit human approval, requires --probe")
    run.add_argument("--probe", help="explicit registered selection; still obeys deferral/platform/consent")
    sub.add_parser("status")
    export = sub.add_parser("export")
    export.add_argument("--output", required=True)
    register = sub.add_parser("register", help="register a local workload without changing tracked files")
    register.add_argument("file", help="JSON declaration; see probes.json and README.md")
    propose = sub.add_parser("propose")
    propose.add_argument("file", help="JSON proposal; records a gap, does not implement it")
    close = sub.add_parser("proposal-close")
    close.add_argument("id")
    close.add_argument("--status", required=True, choices=["accepted", "rejected", "implemented", "superseded"])
    close.add_argument("--note", required=True)
    defer = sub.add_parser("defer")
    defer.add_argument("id")
    defer.add_argument("--reason", required=True)
    defer.add_argument("--resume-when", required=True)
    resume = sub.add_parser("resume")
    resume.add_argument("id")
    resume.add_argument("--evidence", required=True)
    return p


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        root, common, directory = paths(args.repo)
        state = State(directory)
        if args.operation == "run":
            result = measure(args, state, root, common)
        elif args.operation == "status":
            revision = git(root, "rev-parse", "HEAD")
            catalog = Catalog(root, revision, state.registrations())
            state.inventory(revision, catalog.probes.values())
            with state.transaction():
                result = state.snapshot()
            result["coordinator"] = str(state.render())
        elif args.operation == "export":
            target = Path(args.output).resolve()
            if target.is_relative_to(directory) or target.exists():
                raise LabError("export needs a new archive path outside lab state")
            with state.execution_lock() as lock:
                if lock is None:
                    raise LabError("a batch is active; export after it finishes")
                recover(state)
                state.render()
                temporary = target.with_name(target.name + f".{os.getpid()}.tmp")
                try:
                    with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED) as archive:
                        archive.writestr("history.json", json.dumps(state.snapshot(), indent=2))
                        archive.write(directory / "coordinator.md", "coordinator.md")
                        for artifact in sorted((directory / "runs").rglob("*")):
                            if artifact.is_file():
                                archive.write(artifact, artifact.relative_to(directory))
                    with temporary.open("rb") as stream:
                        os.fsync(stream.fileno())
                    os.replace(temporary, target)
                finally:
                    temporary.unlink(missing_ok=True)
            result = dict(outcome="exported", path=str(target))
        elif args.operation == "register":
            declaration = validate(json.loads(Path(args.file).read_text()))
            state.register(declaration)
            result = dict(outcome="registered", probe=declaration["id"])
        elif args.operation == "propose":
            result = dict(outcome="proposed", proposal=state.propose(json.loads(Path(args.file).read_text())))
        elif args.operation == "proposal-close":
            state.close_proposal(args.id, args.status, args.note)
            result = dict(outcome=args.status, proposal=args.id)
        elif args.operation == "defer":
            state.defer(args.id, args.reason, args.resume_when)
            result = dict(outcome="deferred", probe=args.id)
        else:
            state.resume(args.id, args.evidence)
            result = dict(outcome="resumed", probe=args.id)
        state.render()
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0 if result.get("outcome") not in ("blocked", "interrupted", "budget-exhausted") else 1
    except (LabError, ValueError, OSError) as error:
        print(json.dumps(dict(outcome="error", error=str(error))), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
