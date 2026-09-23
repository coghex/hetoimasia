"""Reporter for optional Python probes; Hspec workloads need no adapter.

A probe owns its checks and fixtures. The lab owns build preparation, repetition,
process limits and recording. Import this from a repository-relative tools path.
"""
import os
from pathlib import Path

from common import atomic_json


def report(checks: dict[str, str]) -> int:
    if not checks or any(value not in ("passed", "failed", "unproven") for value in checks.values()):
        raise ValueError("provide nonempty stable check ids with explicit outcomes")
    target = os.environ.get("HETOIMASIA_PROBE_RESULT")
    if not target:
        raise ValueError("this probe requires the lab's result path")
    atomic_json(Path(target), dict(schema="hetoimasia-probe/v1", checks=checks))
    return 0 if all(v == "passed" for v in checks.values()) else 1
