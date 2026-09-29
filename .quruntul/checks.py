"""Checks that .quruntul/adapter.py still describes the catalog's suites faithfully.

The adapter is Python that quruntul imports, so it is checked in Python, driven
one example at a time by tools/test/QuruntulAdapter.hs. A stub context stands in
for quruntul's (same `Suite`, `Prepared`, `digest` and `run` surface), so these
checks need neither quruntul nor a compiler, display or network. They compare
the adapter against tools/validation/catalog.json directly: the catalog stays
the one authority for what exists.
"""
from __future__ import annotations

import ast
from dataclasses import dataclass, field
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True


@dataclass
class Suite:
    id: str
    kind: str
    framework: str
    description: str
    area: str = ""
    platforms: list = field(default_factory=lambda: ["Darwin", "Linux"])
    desktop: bool = False
    trial_seconds: int = 900
    batch_seconds: int = 7200
    identity: str = ""
    rts: list = field(default_factory=list)
    checks: list = field(default_factory=list)
    priority: int = 10
    data: dict = field(default_factory=dict)


@dataclass
class Prepared:
    argv: list
    cwd: str
    environment: dict
    provenance: dict = field(default_factory=dict)
    wrapper: list = field(default_factory=list)
    launches_executable: bool = True


class Context:
    Suite = Suite
    Prepared = Prepared
    version = (0, 2, 0)

    def __init__(self, platform="Darwin"):
        self.checkout = ROOT
        self.revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True,
                                       text=True, check=True).stdout.strip()
        self.platform = platform
        self.calls = []

    @staticmethod
    def digest(value):
        return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

    def run(self, argv, name, timeout, cwd=None, environment=None):
        self.calls.append(dict(argv=argv, name=name, environment=environment))
        return dict(outcome="passed", log="/dev/null", command=argv)


def load():
    spec = importlib.util.spec_from_file_location("hetoimasia_quruntul_adapter", ROOT / ".quruntul" / "adapter.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CATALOG = json.loads((ROOT / "tools" / "validation" / "catalog.json").read_text())


def selectors(group):
    options = [w.split("=", 1)[1] for w in group.get("command", []) if w.startswith("--test-option=")]
    return [options[i + 1] for i, o in enumerate(options) if o in ("--match", "-m") and i + 1 < len(options)]


def hspec_profiles():
    """(suite id, component, selectors) -> the groups that run that profile."""
    found = {}
    for group in CATALOG["groups"]:
        if group.get("framework") != "hspec":
            continue
        names = [group["component"]] if ":test:" in (group.get("component") or "") else []
        names += [w for w in group.get("command", []) if re.fullmatch(r"[\w-]+:test:[\w-]+", w) and w not in names]
        chosen = selectors(group)
        for component in names:
            suite = component.split(":")[2] + (f":{group['id'].removeprefix('test.')}" if chosen else "")
            found.setdefault((suite, component, tuple(chosen)), []).append(group)
    return found


def wayland_groups():
    workflow = (ROOT / ".github" / "workflows" / "validation.yml").read_text()
    return set(re.findall(r'if \[ "\$group" = "([\w.-]+)" \]; then\s+helper=tools/display/wayland\.sh', workflow))


class AdapterChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load()
        cls.suites = {s.id: s for s in cls.module.adapter().suites(Context())}

    def test_every_catalog_hspec_profile_is_exactly_one_suite(self):
        profiles = hspec_profiles()
        self.assertEqual(sorted(self.suites), sorted(suite for suite, _, _ in profiles))
        for suite, component, chosen in profiles:
            self.assertEqual(self.suites[suite].data["component"], component)
            if chosen:
                self.assertEqual(self.suites[suite].data["options"], [x for s in chosen for x in ("--match", s)])

    def test_profiles_restrict_only_through_options_quruntul_intersects_with_selection(self):
        # quruntul 0.2.0 drops a suite's --match selectors when a trial selects
        # exact tests (Hspec ORs every --match) and keeps its --skip selectors,
        # so a narrowed profile must narrow only with --match and an unnarrowed
        # one only with --skip; then a selected example never widens a trial.
        for suite in self.suites.values():
            options = suite.data["options"]
            flags = options[0::2]
            if ":" in suite.id:
                self.assertTrue(options and set(flags) == {"--match"}, suite.id)
            else:
                self.assertTrue(set(flags) <= {"--skip"}, suite.id)

    def test_an_older_quruntul_is_refused(self):
        old = Context()
        old.version = (0, 1, 0)
        with self.assertRaisesRegex(RuntimeError, "needs quruntul"):
            self.module.adapter().suites(old)

    def test_vulkan_native_launches_through_its_runner_with_provenance(self):
        adapter = self.module.adapter()
        adapter._check_toolchain = lambda checkout: None
        adapter._discovery = lambda checkout, build_dir: {"HETOIMASIA_VULKAN_LIBDIR": "/l", "HETOIMASIA_VULKAN_INCLUDEDIR": "/i"}
        adapter._list_bin = lambda checkout, flags, component, environment: sys.executable
        adapter._tools = lambda checkout, component: []
        suite = self.suites["vulkan-native-tests"]
        runner = (ROOT / "tools" / "vulkan" / "run.sh").read_text()
        # The provenance the native suite checks is set by run.sh native itself.
        self.assertIn("HETOIMASIA_VULKAN_SOURCE_DIGEST", runner)
        self.assertIn("HETOIMASIA_VULKAN_REVISION", runner)
        for platform in ("Darwin", "Linux"):
            prepared = adapter.prepare(Context(platform), suite)
            self.assertEqual(prepared.wrapper, ["bash", str(ROOT / "tools" / "vulkan" / "run.sh"), "native",
                                                suite.data["component"], "--"])
            self.assertFalse(prepared.launches_executable)
            self.assertEqual(prepared.cwd, str(ROOT))
            self.assertEqual(prepared.environment.get("HETOIMASIA_NATIVE_SESSION"),
                             "desktop" if platform == "Darwin" else None)

    def test_an_unnarrowed_suite_skips_every_narrowed_profile_of_its_executable(self):
        profiles = hspec_profiles()
        for suite, component, chosen in profiles:
            if chosen:
                continue
            narrowed = [s for _, c, sel in profiles if c == component for s in sel]
            self.assertEqual(self.suites[suite].data["options"], [x for s in narrowed for x in ("--skip", s)], suite)

    def test_probes_are_exactly_the_local_only_optional_groups(self):
        workflow = (ROOT / ".github" / "workflows" / "validation.yml").read_text()
        routed = set()
        for declaration in re.findall(r'--worker "[^"$]+=[^"$]+:([^"$]+)"', workflow):
            routed.update(declaration.split(","))
        for (suite, _, _), groups in hspec_profiles().items():
            local = any(g.get("optional") and g.get("category") == "probe" and g["id"] not in routed for g in groups)
            self.assertEqual(self.suites[suite].kind, "probe" if local else "ci", suite)

    def test_display_helpers_follow_ci(self):
        wayland = wayland_groups()
        self.assertTrue(wayland, "validation.yml no longer names a Wayland group; update the adapter and this check")
        for (suite, _, _), groups in hspec_profiles().items():
            if any(g["id"] in wayland for g in groups):
                self.assertEqual((self.suites[suite].data["display"], self.suites[suite].desktop,
                                  self.suites[suite].platforms), ("wayland", False, ["Linux"]), suite)
            else:
                display = any(g.get("runner") == "display" for g in groups)
                self.assertEqual(self.suites[suite].desktop, display, suite)

    def test_build_routes_follow_the_project_files(self):
        cpu = (ROOT / "cabal.project.cpu").read_text()
        vulkan = (ROOT / "cabal.project.vulkan").read_text()
        for suite in self.suites.values():
            directory = suite.data["directory"] or "."
            route = suite.data["route"]
            if route == "cpu":
                self.assertRegex(cpu, rf"(?m)^\s+{re.escape(directory)}\s*$", suite.id)
            elif route == "vulkan":
                self.assertRegex(vulkan, rf"(?m)^\s+{re.escape(directory)}\s*$", suite.id)
                self.assertNotRegex(cpu, rf"(?m)^\s+{re.escape(directory)}\s*$", suite.id)
            else:
                self.assertEqual(suite.data["package"], "hetoimasia-glfw", suite.id)

    def test_platform_bound_probes(self):
        self.assertEqual(self.suites["macos-confinement-probe"].platforms, ["Darwin"])
        self.assertEqual(self.suites["linux-confinement-probe"].platforms, ["Linux"])

    def test_identities_are_stable_and_distinct(self):
        again = {s.id: s.identity for s in self.module.adapter().suites(Context())}
        self.assertEqual(again, {k: s.identity for k, s in self.suites.items()})
        self.assertEqual(len(set(again.values())), len(again))

    def test_desktop_consent_is_per_command_on_macos_and_an_isolated_display_on_linux(self):
        adapter = self.module.adapter()
        adapter._check_toolchain = lambda checkout: None
        adapter._discovery = lambda checkout, build_dir: {"HETOIMASIA_VULKAN_LIBDIR": "/l", "HETOIMASIA_VULKAN_INCLUDEDIR": "/i"}
        adapter._list_bin = lambda checkout, flags, component, environment: sys.executable
        adapter._tools = lambda checkout, component: []
        for platform, suite_id in (("Darwin", "glfw-native-tests"), ("Linux", "glfw-native-tests"),
                                   ("Linux", "glfw-native-tests:glfw-wayland"),
                                   ("Darwin", "foundation-tests")):
            ctx = Context(platform)
            prepared = adapter.prepare(ctx, self.suites[suite_id])
            desktop = self.suites[suite_id].desktop
            self.assertEqual(prepared.argv[1:], self.suites[suite_id].data["options"])
            if self.suites[suite_id].data["display"] == "wayland":
                self.assertNotIn("HETOIMASIA_NATIVE_SESSION", prepared.environment)
                self.assertEqual(prepared.wrapper[-2:], [str(ROOT / "tools" / "display" / "wayland.sh"), "--"])
            elif desktop and platform == "Darwin":
                self.assertEqual(prepared.environment.get("HETOIMASIA_NATIVE_SESSION"), "desktop")
                self.assertEqual(prepared.wrapper, [])
            elif desktop:
                self.assertNotIn("HETOIMASIA_NATIVE_SESSION", prepared.environment)
                self.assertEqual(prepared.wrapper[-2:], [str(ROOT / "tools" / "display" / "x11.sh"), "--"])
            else:
                self.assertNotIn("HETOIMASIA_NATIVE_SESSION", prepared.environment)
            if self.suites[suite_id].data["route"] == "vulkan":
                self.assertEqual(ctx.calls[0]["argv"][:3], ["bash", "tools/vulkan/run.sh", "build"])

    def test_the_adapter_imports_nothing_from_quruntul(self):
        tree = ast.parse((ROOT / ".quruntul" / "adapter.py").read_text())
        imported = [alias.name for node in ast.walk(tree) if isinstance(node, ast.Import) for alias in node.names]
        imported += [node.module or "" for node in ast.walk(tree) if isinstance(node, ast.ImportFrom)]
        self.assertEqual([name for name in imported if name.split(".")[0] == "quruntul"], [])


if __name__ == "__main__":
    unittest.main()
