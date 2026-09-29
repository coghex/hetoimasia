"""Hetoimasia's quruntul adapter: its test suites, and how to build and start each.

quruntul (https://github.com/coghex/quruntul) imports this file from the pinned
checkout it measures. The validation catalog stays the single authority for
what exists: every Hspec test component a catalog group runs is one suite, a
CI suite unless its group is an optional local-only probe. This file only says
how to build and start each one the way its group does. A group that narrows a
shared executable with `--match` (test.glfw-wayland) is its own suite, run with
that selector under the display helper CI gives it, and the executable's
unnarrowed suite skips those examples, so each example belongs to exactly one
profile. It imports nothing
from quruntul — the context supplies `Suite`, `Prepared` and `digest` — so
`tools/test/QuruntulAdapter.hs` can check it without quruntul installed.

Build routes follow AGENTS.md: CPU packages through `cabal.project.cpu`,
`hetoimasia-glfw` through `cabal.project` with the native prefix's
`PKG_CONFIG_PATH`, and the Vulkan packages through `tools/vulkan/run.sh`, whose
native-prefix discovery supplies the loader environment. Desktop suites get
the per-command consent on macOS (owner decision 2026-09-29: flake measures
them like every other test) and an isolated X11 display on Linux.
"""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

VULKAN_PACKAGES = {"hetoimasia-gpu-vulkan-native", "hetoimasia-gpu-vulkan-glfw", "hetoimasia-sample-triangle"}
GLFW_PACKAGES = {"hetoimasia-glfw"}
BUILD_SECONDS = 3600


def _planner(checkout: Path):
    """tools/validation/plan.py from the checkout being measured."""
    path = checkout / "tools" / "validation" / "plan.py"
    name = f"hetoimasia_plan_{abs(hash(str(path)))}"
    if name in sys.modules:
        return sys.modules[name]
    # plan.py imports its siblings (ci_image and others) by plain name.
    if str(path.parent) not in sys.path:
        sys.path.insert(0, str(path.parent))
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def _components(group: dict) -> list[str]:
    """Every Hspec test component a group runs: its declared one, plus any more its command names."""
    found = [group["component"]] if group.get("component") and ":test:" in group["component"] else []
    for word in group.get("command", []):
        if re.fullmatch(r"[\w-]+:test:[\w-]+", word) and word not in found:
            found.append(word)
    return found


def _selectors(group: dict) -> list[str]:
    """The Hspec `--match` patterns a group's command passes through `--test-option`."""
    options = [w.split("=", 1)[1] for w in group.get("command", []) if w.startswith("--test-option=")]
    found = []
    for index, option in enumerate(options):
        if option in ("--match", "-m") and index + 1 < len(options):
            found.append(options[index + 1])
        elif option.startswith("--match="):
            found.append(option.split("=", 1)[1])
    return found


def _wayland_groups(checkout: Path) -> set[str]:
    """Groups CI runs under the isolated Weston compositor rather than isolated X11."""
    workflow = (checkout / ".github" / "workflows" / "validation.yml").read_text()
    return set(re.findall(r'if \[ "\$group" = "([\w.-]+)" \]; then\s+helper=tools/display/wayland\.sh', workflow))


def _routed(checkout: Path) -> set[str]:
    """Groups some CI worker runs; an optional group absent here is local-only."""
    workflow = (checkout / ".github" / "workflows" / "validation.yml").read_text()
    routed: set[str] = set()
    for declaration in re.findall(r'--worker "[^"$]+=[^"$]+:([^"$]+)"', workflow):
        routed.update(declaration.split(","))
    return routed


class Hetoimasia:
    name = "hetoimasia"
    flake_trials = 10
    refresh_days = 7

    def suites(self, ctx):
        checkout = ctx.checkout
        plan = _planner(checkout)
        tree = plan.GitTree(str(checkout), ctx.revision)
        packages = plan.load_packages(tree, required=True)
        entries = plan.tree_entries(str(checkout), ctx.revision)
        catalog = json.loads((checkout / "tools" / "validation" / "catalog.json").read_text())
        routed = _routed(checkout)
        wayland = _wayland_groups(checkout)
        adapter_hash = ctx.digest((checkout / ".quruntul" / "adapter.py").read_text())
        hspec = [g for g in catalog["groups"] if g.get("framework") == "hspec"]
        # Every selector some group narrows a component to; its unnarrowed suite skips them.
        narrowed: dict[str, list[str]] = {}
        for group in hspec:
            for component in _components(group):
                narrowed.setdefault(component, []).extend(_selectors(group))
        suites: dict[str, object] = {}
        for group in hspec:
            selectors = _selectors(group)
            for component in _components(group):
                package, _, suite_name = component.split(":")
                if selectors:
                    suite_name = f"{suite_name}:{group['id'].removeprefix('test.')}"
                    options = [x for s in selectors for x in ("--match", s)]
                else:
                    options = [x for s in narrowed.get(component, []) for x in ("--skip", s)]
                if suite_name in suites or not plan.resolve_component(packages, component):
                    continue
                display = ("wayland" if group["id"] in wayland else
                           "desktop" if group.get("runner") == "display" else None)
                probe = bool(group.get("optional")) and group.get("category") == "probe" and group["id"] not in routed
                inputs = set(plan.component_inputs(packages, component)) | set(group.get("inputs", []))
                inputs |= {"cabal.project", "cabal.project.cpu", "cabal.project.common", "cabal.project.vulkan",
                           "tools/ci-image/toolchain.pin", "tools/toolchain/binding.pin"}
                identity = ctx.digest(dict(
                    adapter=adapter_hash, component=component, options=options,
                    entries=[e for e in entries if any(plan.matches_input(e[0], x) for x in inputs)]))
                route = "vulkan" if package in VULKAN_PACKAGES else "glfw" if package in GLFW_PACKAGES else "cpu"
                suites[suite_name] = ctx.Suite(
                    id=suite_name,
                    kind="probe" if probe else "ci",
                    framework="hspec",
                    description=group["description"],
                    area=group["id"].removeprefix("test."),
                    # The isolated compositor exists only on Linux; on Darwin every
                    # Wayland case is pending (Test.GLFW.Native.Wayland.onlyWayland).
                    platforms=["Linux"] if display == "wayland" else list(group.get("platforms", _platforms(group["id"]))),
                    # A Wayland session is private to its run and opens nothing on the desktop.
                    desktop=display == "desktop",
                    trial_seconds=max(60, min(int(group.get("timeout_seconds", 1800)), 3600)),
                    batch_seconds=14400,
                    identity=identity,
                    priority=10,
                    data=dict(component=component, package=package, route=route, group=group["id"],
                              directory=packages[package].directory, options=options, display=display),
                )
        return list(suites.values())

    def prepare(self, ctx, suite):
        checkout = ctx.checkout
        component = suite.data["component"]
        route = suite.data["route"]
        self._check_toolchain(checkout)
        environment: dict[str, str] = {}
        if route == "vulkan":
            build = ctx.run(["bash", "tools/vulkan/run.sh", "build", component], "build", BUILD_SECONDS)
            self._built(build)
            environment = self._discovery(checkout, "dist-vulkan")
            flags = ["--project-file=cabal.project.vulkan", f"--builddir={checkout / 'dist-vulkan'}",
                     f"--extra-lib-dirs={environment['HETOIMASIA_VULKAN_LIBDIR']}",
                     f"--extra-include-dirs={environment['HETOIMASIA_VULKAN_INCLUDEDIR']}"]
        else:
            if route == "glfw":
                environment = self._discovery(checkout, "dist-newstyle")
            flags = ["--project-file", "cabal.project" if route == "glfw" else "cabal.project.cpu"]
            build = ctx.run(["cabal", "build", *flags, component], "build", BUILD_SECONDS,
                            environment=environment)
            self._built(build)
        executable = self._list_bin(checkout, flags, component, environment)
        tools = [self._list_bin(checkout, flags, tool, environment) for tool in self._tools(checkout, component)]
        if tools:
            environment["PATH"] = os.pathsep.join([str(Path(t).parent) for t in tools] + [os.environ.get("PATH", "")])
        wrapper: list[str] = []
        if suite.data["display"] == "wayland":
            wrapper = ["bash", str(checkout / "tools" / "display" / "wayland.sh"), "--"]
        elif suite.data["display"] == "desktop":
            if ctx.platform == "Darwin":
                environment["HETOIMASIA_NATIVE_SESSION"] = "desktop"
            else:
                wrapper = ["bash", str(checkout / "tools" / "display" / "x11.sh"), "--"]
        return ctx.Prepared(
            argv=[executable, *suite.data["options"]],
            cwd=str(checkout / suite.data["directory"]),
            environment=environment,
            wrapper=wrapper,
            provenance=dict(component=component, route=route, build=build.get("command"),
                            executable=executable, executable_sha256=_sha256(Path(executable)),
                            tools=tools),
        )

    # -- helpers ------------------------------------------------------------

    @staticmethod
    def _check_toolchain(checkout: Path) -> None:
        pins = dict(line.split("=", 1) for line in (checkout / "tools/ci-image/toolchain.pin").read_text().splitlines()
                    if line and not line.startswith("#") and "=" in line)
        for tool, key in (("ghc", "GHC_VERSION"), ("cabal", "CABAL_VERSION")):
            try:
                actual = subprocess.run([tool, "--numeric-version"], capture_output=True, text=True,
                                        timeout=60).stdout.strip()
            except OSError:
                actual = "absent"
            if actual != pins[key]:
                raise RuntimeError(f"{tool} on PATH is {actual}; this revision pins {pins[key]}. "
                                   "Activate docs/toolchain.md's qualified toolchain first.")

    @staticmethod
    def _built(result: dict) -> None:
        if result["outcome"] != "passed":
            raise RuntimeError(f"build {result['outcome']}; see {result['log']}")

    @staticmethod
    def _discovery(checkout: Path, build_dir: str) -> dict[str, str]:
        """The environment `native.py prepare` exports for the private native prefix."""
        prefix = os.environ.get("HETOIMASIA_NATIVE_PREFIX",
                                str(Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
                                    / "hetoimasia" / "native" / "glfw"))
        result = subprocess.run([sys.executable, "tools/native/native.py", "prepare", "--prefix", prefix,
                                 "--build-dir", str(checkout / build_dir)],
                                cwd=checkout, capture_output=True, text=True, timeout=600)
        if result.returncode:
            raise RuntimeError("the native prefix is not what this revision provisions: "
                               + (result.stderr or result.stdout).strip()[-2000:])
        environment = {}
        for line in result.stdout.splitlines():
            if line.startswith("export "):
                name, _, value = line[len("export "):].partition("=")
                environment[name] = " ".join(shlex.split(value))
        return environment

    @staticmethod
    def _list_bin(checkout: Path, flags: list[str], component: str, environment: dict) -> str:
        result = subprocess.run(["cabal", "list-bin", "-v0", *flags, component], cwd=checkout,
                                capture_output=True, text=True, timeout=300,
                                env={**os.environ, **environment})
        path = result.stdout.strip()
        if result.returncode or not path or not Path(path).is_file():
            raise RuntimeError(f"cabal cannot name the built executable of {component}: {result.stderr.strip()}")
        return path

    @staticmethod
    def _tools(checkout: Path, component: str) -> list[str]:
        """Executables the suite's build-tool-depends puts on PATH under `cabal test`."""
        plan = _planner(checkout)
        tree = plan.GitTree(str(checkout), "HEAD")
        packages = plan.load_packages(tree, required=True)
        package, kind, name = component.split(":")
        return [f"{pkg}:exe:{exe}" for pkg, k, exe in sorted(
            plan.component_closure(packages, [(package, kind, name)])) if k == "exe"]


def _platforms(group_id: str) -> list[str]:
    # The catalog names Linux-only groups; the macOS confinement probe's
    # components are simply not built off Darwin (AGENTS.md), so say so here.
    return ["Darwin"] if group_id == "test.macos-confinement" else ["Darwin", "Linux"]


def _sha256(path: Path) -> str:
    import hashlib
    return hashlib.sha256(path.read_bytes()).hexdigest()


def adapter():
    return Hetoimasia()
