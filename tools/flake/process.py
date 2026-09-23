"""Guardian process: deadlines and parent death cannot strand a test process group.

The coordinator hands this process its execution-lock descriptor. The guardian
retains it until its child group has been terminated and reaped. EOF on the
parent's pipe means the coordinator died; the group is then cancelled. No PID
from a previous run is ever signalled. A returned result is fsynced before exit.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import atomic_json, file_hash, utc


def group_exists(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False


def send(pgid, sig):
    try:
        os.killpg(pgid, sig)
    except ProcessLookupError:
        pass


def reap_group(process, grace):
    send(process.pid, signal.SIGTERM)
    end = time.monotonic() + grace
    while time.monotonic() < end:
        process.poll()  # Reap the leader, too; its zombie is not a live child.
        if not group_exists(process.pid):
            return
        time.sleep(0.02)
    send(process.pid, signal.SIGKILL)
    process.wait(timeout=5)


def supervise(spec):
    cancelled = False

    def stop(_sig, _frame):
        nonlocal cancelled
        cancelled = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    started = utc()
    before = time.monotonic()
    result = dict(schema_version=1, token=spec["token"], started=started, command=spec["command"],
                  cwd=spec["cwd"], log=spec["log"], outcome="setup-error", returncode=None)
    log = Path(spec["log"])
    try:
        with log.open("wb") as output:
            child = subprocess.Popen(spec["command"], cwd=spec["cwd"], env=spec["environment"],
                                     stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
                                     start_new_session=True)
            try:
                reason = None
                while child.poll() is None:
                    readable, _, _ = select.select([sys.stdin], [], [], 0.05)
                    if cancelled or (readable and os.read(sys.stdin.fileno(), 1) == b""):
                        reason = "interrupted"
                        break
                    if log.stat().st_size > 64 * 1024 * 1024:
                        reason = "harness-error"
                        result["error"] = "trial log exceeded 64 MiB"
                        break
                    if time.monotonic() - before >= spec["timeout"]:
                        reason = "timeout"
                        break
                if reason:
                    reap_group(child, spec["grace"])
                    result["outcome"] = reason
                else:
                    # A successful leader leaving live descendants is a broken
                    # probe, not a passing test. Still clean up our whole group.
                    leaked = group_exists(child.pid)
                    if leaked:
                        reap_group(child, spec["grace"])
                    result["outcome"] = ("harness-error" if leaked else
                                         "passed" if child.returncode == 0 else
                                         "crashed" if child.returncode < 0 else "failed")
                result["returncode"] = child.wait(timeout=5)
            finally:
                if child.poll() is None or group_exists(child.pid):
                    reap_group(child, spec["grace"])
            output.flush()
            os.fsync(output.fileno())
    except Exception as error:
        result["outcome"] = "harness-error"
        result["error"] = f"{type(error).__name__}: {error}"
    result.update(finished=utc(), duration_seconds=time.monotonic() - before,
                  log_sha256=file_hash(log) if log.exists() else None)
    atomic_json(Path(spec["result"]), result)
    return 0


def run(command, cwd, environment, artifact, timeout, lock_fd, heartbeat, grace=1.0):
    """Run a bounded child, retaining a recoverable result before DB ingestion."""
    token = artifact.name
    spec = dict(token=token, command=command, cwd=str(cwd), environment=environment,
                timeout=timeout, grace=grace, log=str(artifact.with_suffix(".log")),
                result=str(artifact.with_suffix(".result.json")))
    # Environment stays out of retained manifests; it may contain credentials.
    guardian = subprocess.Popen([sys.executable, "-I", str(Path(__file__).resolve()), "--guardian"],
                                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                stderr=subprocess.PIPE, pass_fds=(lock_fd,))
    try:
        guardian.stdin.write((json.dumps(spec) + "\n").encode())
        guardian.stdin.flush()
        last = 0.0
        while guardian.poll() is None:
            now = time.monotonic()
            if now - last >= 5:
                heartbeat()
                last = now
            time.sleep(0.05)
        if guardian.returncode:
            raise RuntimeError(f"guardian exited {guardian.returncode}: {guardian.stderr.read().decode(errors='replace')}")
        result = json.loads(Path(spec["result"]).read_text())
        if result["token"] != token:
            raise RuntimeError("guardian returned another attempt's result")
        return result
    finally:
        guardian.stdin.close()
        try:
            guardian.wait(timeout=grace + 10)
        except subprocess.TimeoutExpired:
            # This is our guardian. Ask it to stop; never signal a stale PID.
            guardian.terminate()
            guardian.wait(timeout=grace + 10)
        guardian.stderr.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--guardian", action="store_true", required=True)
    parser.parse_args()
    # -I isolates imports, so explicitly add only this trusted script directory.
    raise SystemExit(supervise(json.loads(sys.stdin.buffer.readline())))
