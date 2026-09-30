"""Hetoimasia's quruntul adapter: its test suites, and how to build and start each.

quruntul (https://github.com/coghex/quruntul) imports this file from the pinned
checkout it measures. The validation catalog stays the single authority for
what exists: every Hspec test component a catalog group runs is one suite, a
CI suite unless its group is an optional local-only probe. This file only says
how to build and start each one the way its group does. A group that narrows a
shared executable with `--match` (test.glfw-wayland) is its own suite, run with
that selector under the display helper CI gives it, and the executable's
unnarrowed suite skips those examples, so each example belongs to exactly one
profile. A group whose command launches its executable through
`tools/vulkan/run.sh native` is launched the same way, so the runner's source
digest and revision provenance reach the native suite. A group that declares a
`preparation` command is prepared by exactly that command, as CI prepares it
(test.vulkan-native also builds the triangle sample app, so an app that no
longer builds fails the suite here too). It imports nothing
from quruntul — the context supplies `Suite`, `Prepared` and `digest` — so
`tools/test/QuruntulAdapter.hs` can check it without quruntul installed.

Build routes follow AGENTS.md: CPU packages through `cabal.project.cpu`,
`hetoimasia-glfw` through `cabal.project` with the native prefix's
`PKG_CONFIG_PATH`, and the Vulkan packages through `tools/vulkan/run.sh`, whose
native-prefix discovery supplies the loader environment. The compiler is chosen
by `PATH` (docs/toolchain.md), so when the `ghc` or `cabal` on `PATH` is not
the revision's pin but ghcup's versioned `ghc-<pin>` is installed, every build
and trial runs with a private directory of links to it first on `PATH`;
ghcup's default, which may be another project's, is left alone. Desktop suites get
the per-command consent on macOS (owner decision 2026-09-29: flake measures
them like every other test) and an isolated X11 display on Linux.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

# What ghcup installs for each GHC version, as `<tool>-<version>`.
GHC_TOOLS = ("ghc", "ghc-pkg", "ghci", "haddock", "hp2ps", "hpc", "hsc2hs", "runghc", "runhaskell")
VULKAN_PACKAGES = {"hetoimasia-gpu-vulkan-native", "hetoimasia-gpu-vulkan-glfw", "hetoimasia-sample-triangle"}
GLFW_PACKAGES = {"hetoimasia-glfw"}
BUILD_SECONDS = 3600
# Exact per-test selection must supersede a profile's --match (quruntul 0.2.0).
ENGINE = (0, 2, 0)


# The planner modules this adapter reads helpers from, in dependency order: each
# imports only the standard library and the modules before it.
PLANNER_MODULES = ("plan_repository", "plan_cabal", "plan_identity")
_PLANNERS: dict[str, dict[str, object]] = {}


def _planner(checkout: Path, name: str):
    """One of the validation planner's modules from the checkout being measured.

    Each helper is imported from the module that owns it, never through the
    plan.py command line. One process may measure more than one checkout, so each
    checkout's modules are loaded from its own files under names of their own.
    They import each other by plain name, so those names point at this
    checkout's copies only while it loads and are restored afterwards; nothing is
    put on `sys.path`, and a `plan_` module another checkout loaded is never
    reused.
    """
    directory = (checkout / "tools" / "validation").resolve()
    key = f"hetoimasia_planner_{hashlib.sha256(str(directory).encode()).hexdigest()[:16]}"
    if key not in _PLANNERS:
        _PLANNERS[key] = _load_planner(directory, key)
    return _PLANNERS[key][name]


def _load_planner(directory: Path, key: str) -> dict[str, object]:
    saved = {name: sys.modules.get(name) for name in PLANNER_MODULES}
    writes_bytecode = sys.dont_write_bytecode
    # Loading them must leave no __pycache__ in the checkout, as plan.py ensures.
    sys.dont_write_bytecode = True
    loaded: dict[str, object] = {}
    try:
        for name in PLANNER_MODULES:
            spec = importlib.util.spec_from_file_location(f"{key}_{name}", directory / f"{name}.py")
            module = importlib.util.module_from_spec(spec)
            sys.modules[spec.name] = module
            sys.modules[name] = module
            spec.loader.exec_module(module)
            loaded[name] = module
    finally:
        sys.dont_write_bytecode = writes_bytecode
        for name, previous in saved.items():
            if previous is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = previous
    return loaded


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
        if getattr(ctx, "version", (0,)) < ENGINE:
            raise RuntimeError("this adapter needs quruntul " + ".".join(map(str, ENGINE)) + " or newer; update quruntul")
        checkout = ctx.checkout
        repository = _planner(checkout, "plan_repository")
        cabal = _planner(checkout, "plan_cabal")
        tree = repository.GitTree(str(checkout), ctx.revision)
        packages = cabal.load_packages(tree, required=True)
        entries = _planner(checkout, "plan_identity").tree_entries(str(checkout), ctx.revision)
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
                if suite_name in suites or not cabal.resolve_component(packages, component):
                    continue
                display = ("wayland" if group["id"] in wayland else
                           "desktop" if group.get("runner") == "display" else None)
                launch = "vulkan-native" if group.get("command", [])[:3] == ["bash", "tools/vulkan/run.sh", "native"] else "direct"
                probe = bool(group.get("optional")) and group.get("category") == "probe" and group["id"] not in routed
                inputs = set(cabal.component_inputs(packages, component)) | set(group.get("inputs", []))
                inputs |= {"cabal.project", "cabal.project.cpu", "cabal.project.common", "cabal.project.vulkan",
                           "tools/ci-image/toolchain.pin", "tools/toolchain/binding.pin"}
                identity = ctx.digest(dict(
                    adapter=adapter_hash, component=component, options=options,
                    entries=[e for e in entries if any(repository.matches_input(e[0], x) for x in inputs)]))
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
                              directory=packages[package].directory, options=options, display=display,
                              launch=launch, preparation=(group.get("preparation") or {}).get("command")),
                )
        return list(suites.values())

    def prepare(self, ctx, suite):
        checkout = ctx.checkout
        component = suite.data["component"]
        route = suite.data["route"]
        # Builds, list-bin and every trial see the pinned compiler: the
        # ExternalClient examples compile against the `ghc` on PATH.
        path = self._toolchain(checkout)
        environment: dict[str, str] = {"PATH": path}
        if route == "vulkan":
            # The group's own preparation when it declares one; else build the suite.
            command = suite.data.get("preparation") or ["bash", "tools/vulkan/run.sh", "build", component]
            # run.sh regenerates each shader toolchain fingerprint and deletes
            # the ones it created when it exits; `run.sh test` keeps them for
            # the suite it runs, and runtime shader compiles read them. A trial
            # starts the executable after the build, so the files exist first
            # and run.sh leaves its regenerated bytes (they are ignored, and
            # this checkout is quruntul's own).
            for fingerprint in self._fingerprints(checkout):
                fingerprint.parent.mkdir(parents=True, exist_ok=True)
                fingerprint.touch()
            build = ctx.run(command, "build", BUILD_SECONDS, environment=environment)
            self._built(build)
            environment.update(self._discovery(checkout, "dist-vulkan"))
            flags = ["--project-file=cabal.project.vulkan", f"--builddir={checkout / 'dist-vulkan'}",
                     f"--extra-lib-dirs={environment['HETOIMASIA_VULKAN_LIBDIR']}",
                     f"--extra-include-dirs={environment['HETOIMASIA_VULKAN_INCLUDEDIR']}"]
        else:
            if route == "glfw":
                environment.update(self._discovery(checkout, "dist-newstyle"))
            flags = ["--project-file", "cabal.project" if route == "glfw" else "cabal.project.cpu"]
            command = suite.data.get("preparation") or ["cabal", "build", *flags, component]
            build = ctx.run(command, "build", BUILD_SECONDS, environment=environment)
            self._built(build)
        executable = self._list_bin(checkout, flags, component, environment)
        tools = [self._list_bin(checkout, flags, tool, environment) for tool in self._tools(checkout, component)]
        if tools:
            environment["PATH"] = os.pathsep.join([str(Path(t).parent) for t in tools] + [path])
        if suite.data["launch"] == "vulkan-native":
            # As test.vulkan-native runs it: run.sh native sets the source digest
            # and revision the native suite's provenance checks require, starts
            # the executable from the repository root, and on Linux starts its
            # own isolated X11 display.
            return ctx.Prepared(
                argv=[executable, *suite.data["options"]],
                cwd=str(checkout),
                environment={"PATH": path, **({"HETOIMASIA_NATIVE_SESSION": "desktop"}
                                              if ctx.platform == "Darwin" and suite.desktop else {})},
                wrapper=["bash", str(checkout / "tools" / "vulkan" / "run.sh"), "native", component, "--"],
                launches_executable=False,
                provenance=dict(component=component, route=route, launch="tools/vulkan/run.sh native",
                                build=build.get("command"), executable=executable,
                                executable_sha256=_sha256(Path(executable))),
            )
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
    def _toolchain(checkout: Path) -> str:
        """The PATH on which `ghc` and `cabal` are this revision's pins, or a refusal.

        The PATH quruntul was started with when it already qualifies; otherwise
        that PATH behind a shim of the pinned version's ghcup binaries
        (`_shim`), for this run's builds and trials only.
        """
        pins = dict(line.split("=", 1) for line in (checkout / "tools/ci-image/toolchain.pin").read_text().splitlines()
                    if line and not line.startswith("#") and "=" in line)
        path = os.environ.get("PATH", "")
        for family, key in ((GHC_TOOLS, "GHC_VERSION"), (("cabal",), "CABAL_VERSION")):
            tool, pinned = family[0], pins[key]
            if _version(tool, path) != pinned:
                shim = _shim(family, pinned, path)
                if shim:
                    path = os.pathsep.join([shim, path])
            actual = _version(tool, path)
            if actual != pinned:
                raise RuntimeError(f"{tool} on PATH is {actual} and no {tool}-{pinned} is installed on PATH or in "
                                   f"ghcup's bin directory; this revision pins {pinned}. Install the qualified "
                                   "toolchain docs/toolchain.md names.")
        return path

    @staticmethod
    def _fingerprints(checkout: Path) -> list[Path]:
        """The shader toolchain fingerprints `tools/vulkan/run.sh` generates, from its own `fingerprints` array."""
        runner = (checkout / "tools" / "vulkan" / "run.sh").read_text()
        declared = re.search(r"(?m)^fingerprints=\(\n(.*?)^\)", runner, re.S)
        if not declared:
            raise RuntimeError("tools/vulkan/run.sh no longer declares its fingerprints array; update the adapter")
        return [checkout / path for path in re.findall(r'"([^"]+)"', declared.group(1))]

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
        cabal = _planner(checkout, "plan_cabal")
        tree = _planner(checkout, "plan_repository").GitTree(str(checkout), "HEAD")
        packages = cabal.load_packages(tree, required=True)
        package, kind, name = component.split(":")
        return [f"{pkg}:exe:{exe}" for pkg, k, exe in sorted(
            cabal.component_closure(packages, [(package, kind, name)])) if k == "exe"]


def _platforms(group_id: str) -> list[str]:
    # The catalog names Linux-only groups; the macOS confinement probe's
    # components are simply not built off Darwin (AGENTS.md), so say so here.
    return ["Darwin"] if group_id == "test.macos-confinement" else ["Darwin", "Linux"]


def _version(tool: str, path: str) -> str:
    """What `tool --numeric-version` reports when resolved on `path`."""
    executable = shutil.which(tool, path=path)
    if not executable:
        return "absent"
    try:
        return subprocess.run([executable, "--numeric-version"], capture_output=True, text=True, timeout=60,
                              env={**os.environ, "PATH": path}).stdout.strip() or "unknown"
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"


def _shim(tools: tuple[str, ...], version: str, path: str) -> str | None:
    """A directory naming each of `tools` as its installed `<tool>-<version>`, or None without the first.

    ghcup installs every version's binaries under versioned names beside its
    default's plain ones. The directory lives in the user's cache, keyed by
    version, and each link is replaced atomically, so concurrent batches share
    it and one that finds it current changes nothing.
    """
    ghcup = Path(os.environ.get("GHCUP_INSTALL_BASE_PREFIX") or Path.home()) / ".ghcup" / "bin"
    search = os.pathsep.join([path, str(ghcup)])
    targets = {tool: shutil.which(f"{tool}-{version}", path=search) for tool in tools}
    if not targets[tools[0]]:
        return None
    directory = (Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
                 / "hetoimasia" / "toolchain" / f"{tools[0]}-{version}" / "bin")
    directory.mkdir(parents=True, exist_ok=True)
    for tool, target in targets.items():
        link = directory / tool
        if not target or (link.is_symlink() and os.readlink(link) == target):
            continue
        staged = directory / f".{tool}.{os.getpid()}"
        staged.unlink(missing_ok=True)
        os.symlink(target, staged)
        os.replace(staged, link)
    return str(directory)


def _sha256(path: Path) -> str:
    import hashlib
    return hashlib.sha256(path.read_bytes()).hexdigest()


def adapter():
    return Hetoimasia()
