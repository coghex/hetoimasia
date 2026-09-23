"""Workload declarations and source identities; reuse the validation Cabal graph.

Python owns process isolation and repetition. Hspec still owns engine assertions.
No command is executed during discovery. Local registrations are stored by State.
"""
from __future__ import annotations

import json
from pathlib import Path
import re
import sys

from common import LabError, digest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "validation"))
import plan as validation

FIELDS = {"id", "kind", "description", "component", "project", "match", "seed", "rts",
          "attempts", "trial_seconds", "batch_seconds", "priority", "platforms",
          "command", "prepare", "inputs", "desktop", "optional", "source_group", "checks"}


def validate(probe: dict) -> dict:
    if not isinstance(probe, dict) or set(probe) - FIELDS:
        raise LabError("unknown probe fields or non-object declaration")
    p = dict(probe)
    if not isinstance(p.get("id"), str) or not re.fullmatch(r"[a-z][a-z0-9.-]{0,79}", p["id"]):
        raise LabError("probe id must be a stable lowercase identifier")
    if p.get("kind") not in ("hspec", "command"):
        raise LabError("probe kind must be hspec or command")
    if not isinstance(p.get("description"), str) or not p["description"].strip():
        raise LabError("probe needs a description")
    for key, default, maximum in [("attempts", 20, 10000), ("trial_seconds", 15, 3600),
                                   ("batch_seconds", 300, 14400), ("priority", 10, 100)]:
        value = p.setdefault(key, default)
        if type(value) is not int or not 1 <= value <= maximum:
            raise LabError(f"{key} must be an integer from 1 to {maximum}")
    if p["batch_seconds"] < p["trial_seconds"]:
        raise LabError("batch_seconds must allow at least one full trial deadline")
    for key in ("desktop", "optional"):
        if type(p.setdefault(key, False)) is not bool:
            raise LabError(f"{key} must be boolean")
    platforms = p.setdefault("platforms", ["Darwin", "Linux"])
    if not isinstance(platforms, list) or not platforms or not all(x in ("Darwin", "Linux") for x in platforms):
        raise LabError("platforms must name Darwin and/or Linux")
    if p["kind"] == "hspec":
        if not isinstance(p.get("component"), str) or not re.fullmatch(r"[\w-]+:test:[\w-]+", p["component"]):
            raise LabError("component must be package:test:suite")
        project = p.setdefault("project", "cabal.project.cpu")
        if not isinstance(project, str) or not project.startswith("cabal.project") or "/" in project:
            raise LabError("project must name a root Cabal project file")
        if not isinstance(p.setdefault("match", ""), str):
            raise LabError("match must be an Hspec selector string")
        if type(p.setdefault("seed", 1196626676)) is not int or p["seed"] < 0:
            raise LabError("seed must be a nonnegative integer")
        if not isinstance(p.setdefault("rts", []), list) or not all(isinstance(x, str) for x in p["rts"]):
            raise LabError("rts must be an argv array")
    else:
        for field in ("command", "prepare"):
            argv = p.setdefault(field, [])
            if not isinstance(argv, list) or not all(isinstance(x, str) and x for x in argv):
                raise LabError(f"{field} must be an argv array, never a shell string")
        checks = p.get("checks")
        if not isinstance(checks, list) or not checks or not all(isinstance(x, str) and re.fullmatch(r"[a-z][a-z0-9.-]+", x) for x in checks) or len(set(checks)) != len(checks):
            raise LabError("command probes require distinct stable check ids")
        if not p["command"] or not p.get("inputs"):
            raise LabError("command probes require command argv and explicit input paths")
    if "source_group" in p and not isinstance(p["source_group"], str):
        raise LabError("source_group must name a validation group")
    inputs = p.setdefault("inputs", [])
    if not isinstance(inputs, list) or not all(isinstance(x, str) and x and not x.startswith("/")
                                             and ".." not in x.split("/") for x in inputs):
        raise LabError("inputs must be repository-relative files or directory prefixes")
    return p


class Catalog:
    def __init__(self, root: Path, revision: str, registrations: list[dict]):
        self.root, self.revision = root, revision
        self.tree = validation.GitTree(str(root), revision)
        self.packages = validation.load_packages(self.tree, required=True)
        self.entries = validation.tree_entries(str(root), revision)
        document = json.loads(self.tree.read("tools/validation/catalog.json"))
        self.groups = {g["id"]: g for g in document["groups"]}
        # A local-only probe has no hosted worker. Optional CI selectors are
        # deliberately excluded from test mode, even if marked category=probe.
        workflow = self.tree.read(".github/workflows/validation.yml")
        routed = set()
        for declaration in re.findall(r'--worker "[^"$]+=[^"$]+:([^"$]+)"', workflow):
            routed.update(declaration.split(","))
        definitions = json.loads(Path(__file__).with_name("probes.json").read_text())
        if definitions.get("schema_version") != 1:
            raise LabError("unsupported probe registry schema")
        self.routed = routed
        self.probes = {}
        for p in definitions["probes"] + registrations:
            self.add(p)
        for group in self.groups.values():
            if not (group["optional"] and group["category"] == "probe" and group["id"] not in routed):
                continue
            if group["framework"] != "hspec":
                continue
            self.add(dict(id=group["id"], kind="hspec", description=group["description"],
                          component=group["component"], optional=True, desktop=group["runner"] == "display", source_group=group["id"],
                          project="cabal.project.cpu", inputs=group["inputs"], attempts=3,
                          trial_seconds=min(group["timeout_seconds"], 600), batch_seconds=1800,
                          platforms=group.get("platforms", ["Darwin"] if group["id"] == "test.macos-confinement" else ["Darwin", "Linux"])))

    def add(self, declaration):
        p = validate(declaration)
        if p["id"] in self.probes:
            raise LabError(f"duplicate probe id: {p['id']}")
        if p["kind"] == "hspec" and not validation.resolve_component(self.packages, p["component"]):
            p["unavailable"] = f"component absent from tested revision: {p['component']}"
        if p["kind"] == "hspec" and any(g["component"] == p["component"] and g["runner"] == "display" for g in self.groups.values()):
            p["desktop"] = True
        if p["kind"] == "hspec" and p["optional"]:
            group = self.groups.get(p.get("source_group"))
            if not group or not group["optional"] or group["id"] in self.routed or group["component"] != p["component"]:
                raise LabError("optional Hspec registrations must refer to a local-only catalog probe; CI examples belong to flake mode")
        self.probes[p["id"]] = p

    def identity(self, p: dict, environment: dict) -> str:
        inputs = set(p["inputs"]) | {"cabal.project.common", "tools/ci-image/toolchain.pin"}
        if p["kind"] == "hspec":
            inputs |= validation.component_inputs(self.packages, p["component"])
            inputs.add(p["project"])
            for g in self.groups.values():
                if g["component"] == p["component"]:
                    inputs.update(g["inputs"])
        entries = [entry for entry in self.entries if any(validation.matches_input(entry[0], x) for x in inputs)]
        return digest(dict(probe=p, entries=entries, environment={k: v for k, v in environment.items() if k != "harness_revision"}))

    def tool_components(self, p: dict) -> list[str]:
        package, kind, name = p["component"].split(":")
        return [f"{pkg}:exe:{component}" for pkg, kind, component in sorted(
            validation.component_closure(self.packages, [(package, kind, name)])) if kind == "exe"]


def rank(probes, histories, deferred, mode, identities, now, runner_os, explicit=None, desktop_consent=False):
    """Pure selection; a fresh failure is not an invitation to rerun until green."""
    candidates, skipped = [], {}
    for p in probes:
        key = p["id"]
        reason = None
        if explicit and key != explicit:
            reason = "not-requested"
        elif key in deferred:
            reason = "deferred: " + deferred[key]["reason"]
        elif p.get("unavailable"):
            reason = p["unavailable"]
        elif runner_os not in p["platforms"]:
            reason = "platform-inapplicable"
        elif p["desktop"] and not (explicit and desktop_consent):
            reason = "desktop-consent-required"
        elif mode == "test" and not p["optional"]:
            reason = "hspec-investigation-only"
        else:
            previous = next((h for h in histories if h["probe_id"] == key and (mode == "test" or h["mode"] == "flake")
                             and h["identity"] == identities[key]), None)
            if previous and not explicit:
                age = now - previous["finished_epoch"]
                if age < 86400:
                    reason = "recently-measured" if previous["state"] == "complete" else "recently-blocked"
            if not reason:
                candidates.append((-p["priority"], previous["finished_epoch"] if previous else 0, key, p))
        if reason:
            skipped[key] = reason
    if explicit and explicit not in {p["id"] for p in probes}:
        raise LabError(f"unknown probe: {explicit}")
    return (min(candidates)[3] if candidates else None), skipped
