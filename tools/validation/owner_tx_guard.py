#!/usr/bin/env python3
"""The import guard of the ownership transactions' issuer bridge (#721).

Foundation's ``OwnerTx`` is abstract, and its public library offers no way to embed caller code in a commit. An issuer
embeds its own concrete operations through ``Hetoimasia.Foundation.OwnerTx.Issuer.fromIssuerSTM``, in the public
sublibrary ``hetoimasia-foundation:owner-tx-issuer``. Cabal cannot say *who* may depend on a public sublibrary, so this
guard does, against the exact allowlist ``tools/validation/owner_tx_issuers.json``:

* **Imports.** A module that imports the bridge, or a bridge-equivalent module (one that exports the transaction's
  representation: ``Hetoimasia.Foundation.OwnerTx.Representation``), must be listed with its component. Every import form
  counts: plain, ``qualified`` before or after the name, aliased, with an import list or ``hiding``, ``safe``,
  package-qualified, ``{-# SOURCE #-}``.
* **Dependencies.** A component whose ``build-depends`` names ``hetoimasia-foundation:owner-tx-issuer`` must be a listed
  dependent.
* **Re-exports.** No module may re-export the bridge: an export list naming ``module`` of a bridge or bridge-equivalent
  module, or, in a module that imports one, a bridge function (``fromIssuerSTM``, ``modifyCell``, ``stateCell``) or a
  representation type with its constructors. The defining modules are the only exceptions. A Cabal ``reexported-modules``
  entry naming a bridge or bridge-equivalent module, and a ``mixins`` entry naming the sublibrary or such a module, are
  re-exports too. A listed module is held to this as any other.
* **Exactness.** A listed entry whose component or module does not exist, or that imports no bridge module, is stale and
  fails, so the list says exactly who imports the bridge.

Scope: every component (libraries and sublibraries, executables, test suites, benchmarks) of every package
``cabal.project`` and ``cabal.project.vulkan`` list, read by the planner's own Cabal reader, which counts the fields of
both branches of a manual flag's conditional and rejects syntax it does not understand. A component's sources are its
``exposed-modules``, ``other-modules`` and ``main-is``, found in its ``hs-source-dirs``.

It fails closed: a manifest the reader rejects, a listed module with no source, a source of a kind it does not read
(anything but ``.hs``), an allowlist it cannot read, and a module header it cannot parse are errors, never a pass.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from owned_starts import Unsupported, blank_non_code  # noqa: E402
from plan_cabal import load_packages  # noqa: E402
from plan_repository import PlannerError, WorkTree  # noqa: E402

ALLOWLIST_PATH = "tools/validation/owner_tx_issuers.json"
SCHEMA_VERSION = 1

BRIDGE_PACKAGE = "hetoimasia-foundation"
BRIDGE_LIBRARY = "owner-tx-issuer"
BRIDGE_MODULE = "Hetoimasia.Foundation.OwnerTx.Issuer"
EQUIVALENT_MODULES = ("Hetoimasia.Foundation.OwnerTx.Representation",)
GUARDED_MODULES = (BRIDGE_MODULE,) + EQUIVALENT_MODULES
BRIDGE_FUNCTIONS = frozenset({"fromIssuerSTM", "modifyCell", "stateCell"})
REPRESENTATION_TYPES = frozenset({"OwnerTx", "OwnerCell", "ReadOnly", "Publisher", "Publication"})
# The modules that define what they export: the bridge its functions, the representation its constructors.
DEFINING = {
    (f"{BRIDGE_PACKAGE}:lib:{BRIDGE_LIBRARY}", BRIDGE_MODULE),
    (f"{BRIDGE_PACKAGE}:lib:internal", "Hetoimasia.Foundation.OwnerTx.Representation"),
}

MODULE_NAME = re.compile(r"[A-Z][A-Za-z0-9_']*(?:\.[A-Z][A-Za-z0-9_']*)*")
IMPORT_LINE = re.compile(r"(?m)^[ \t]*import\b(?P<rest>[^\n]*)")
IMPORT_HEAD = re.compile(r"^\s*(?:safe\s+)?(?:qualified\s+)?(?P<module>[A-Z][A-Za-z0-9_']*(?:\.[A-Z][A-Za-z0-9_']*)*)")
MODULE_HEADER = re.compile(r"(?s)^\s*module\s+(?P<name>[A-Z][A-Za-z0-9_'.]*)\s*(?P<rest>.*)")


class GuardError(Exception):
    """An allowlist or tree the guard cannot read; never a pass."""


def component_id(package: str, kind: str, name: str) -> str:
    return f"{package}:{kind}:{name}"


def load_allowlist(root: str) -> tuple[set[tuple[str, str]], set[str]]:
    path = os.path.join(root, ALLOWLIST_PATH)
    try:
        with open(path, encoding="utf-8") as handle:
            document = json.load(handle)
    except (OSError, ValueError) as error:
        raise GuardError(f"{ALLOWLIST_PATH} cannot be read: {error}") from error
    if not isinstance(document, dict) or document.get("schema_version") != SCHEMA_VERSION:
        raise GuardError(f"{ALLOWLIST_PATH} must be an object with schema_version {SCHEMA_VERSION}")
    importers: set[tuple[str, str]] = set()
    for entry in document.get("importers", []):
        if not isinstance(entry, dict) or not all(isinstance(entry.get(key), str) and entry.get(key) for key in ("component", "module", "reason")):
            raise GuardError(f"{ALLOWLIST_PATH}: an importer entry needs a component, a module and a reason: {entry!r}")
        importers.add((entry["component"], entry["module"]))
    dependents: set[str] = set()
    for entry in document.get("dependents", []):
        if not isinstance(entry, dict) or not all(isinstance(entry.get(key), str) and entry.get(key) for key in ("component", "reason")):
            raise GuardError(f"{ALLOWLIST_PATH}: a dependent entry needs a component and a reason: {entry!r}")
        dependents.add(entry["component"])
    unknown = set(document) - {"schema_version", "description", "importers", "dependents"}
    if unknown:
        raise GuardError(f"{ALLOWLIST_PATH}: unknown fields {sorted(unknown)}")
    return importers, dependents


def imported_modules(code: str) -> list[str]:
    """The modules a source imports, from its code with comments, pragmas and literals blanked."""
    found = []
    for match in IMPORT_LINE.finditer(code):
        head = IMPORT_HEAD.match(match.group("rest"))
        if head is None:
            raise Unsupported(f"an import declaration it cannot read: {match.group(0).strip()!r}")
        found.append(head.group("module"))
    return found


def export_items(code: str) -> list[str] | None:
    """The module header's export list as items, or None for a module without one."""
    header = MODULE_HEADER.match(code)
    if header is None:
        return None
    rest = header.group("rest")
    if rest.startswith("where"):
        return None
    if not rest.startswith("("):
        raise Unsupported("a module header it cannot read")
    depth = 0
    for index, character in enumerate(rest):
        if character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0:
                inner = rest[1:index]
                break
    else:
        raise Unsupported("an export list that does not close")
    items: list[str] = []
    depth = 0
    current = ""
    for character in inner:
        if character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
        if character == "," and depth == 0:
            items.append(current.strip())
            current = ""
        else:
            current += character
    if current.strip():
        items.append(current.strip())
    return items


def reexport_problems(items: list[str], imports_guarded: bool, defining: bool) -> list[str]:
    problems = []
    for item in items:
        words = item.split()
        if len(words) >= 2 and words[0] == "module" and words[1] in GUARDED_MODULES:
            problems.append(f"re-exports the module {words[1]}")
            continue
        if not imports_guarded or defining:
            continue
        name = re.sub(r"\s+", "", item)
        base = name.split("(", 1)[0].split(".")[-1]
        if base in BRIDGE_FUNCTIONS:
            problems.append(f"re-exports the bridge's {base}")
        elif base in REPRESENTATION_TYPES and "(" in name and name.split("(", 1)[1] != ")":
            problems.append(f"re-exports the representation's {name}")
    return problems


def source_of(root: str, package_directory: str, directories: list[str], relative: str) -> str | None:
    for directory in directories:
        candidate = os.path.normpath(os.path.join(package_directory, directory, relative))
        if os.path.isfile(os.path.join(root, candidate)):
            return candidate
    return None


def component_sources(root: str, package, fields: dict[str, list[str]]) -> tuple[list[tuple[str, str]], list[str]]:
    """The component's (module, path) sources, and the problems finding them."""
    directories = fields.get("hs-source-dirs", []) or ["."]
    problems = []
    for directory in directories:
        if not os.path.isdir(os.path.join(root, package.directory, directory)):
            problems.append(f"{package.cabal_path}: the source directory {directory!r} does not exist")
    sources = []
    for module in fields.get("exposed-modules", []) + fields.get("other-modules", []):
        if not MODULE_NAME.fullmatch(module):
            problems.append(f"{package.cabal_path}: {module!r} is not a module name it can read")
            continue
        stem = module.replace(".", "/")
        path = source_of(root, package.directory, directories, stem + ".hs")
        if path is None:
            other = [kind for kind in (".lhs", ".hsc", ".hs-boot", ".hsig", ".x", ".y", ".chs") if source_of(root, package.directory, directories, stem + kind)]
            problems.append(
                f"{package.cabal_path}: the module {module} has "
                + (f"a source of a kind the guard does not read ({', '.join(other)})" if other else "no source in its source directories")
            )
            continue
        sources.append((module, path))
    for main in fields.get("main-is", []):
        if not main.endswith(".hs"):
            problems.append(f"{package.cabal_path}: main-is {main!r} is of a kind the guard does not read")
            continue
        path = source_of(root, package.directory, directories, main)
        if path is None:
            problems.append(f"{package.cabal_path}: main-is {main!r} has no source in its source directories")
            continue
        sources.append(("Main", path))
    return sources, problems


def depends_on_bridge(fields: dict[str, list[str]], cabal_path: str) -> tuple[bool, list[str]]:
    problems = []
    found = False
    for token in fields.get("build-depends", []):
        if token.startswith(f"{BRIDGE_PACKAGE}:"):
            library = token.split(":", 1)[1]
            if library.startswith("{"):
                problems.append(f"{cabal_path}: the braced dependency {token!r} is not read by the guard; name each library on its own")
            elif library == BRIDGE_LIBRARY:
                found = True
    return found, problems


def cabal_reexport_problems(fields: dict[str, list[str]], cabal_path: str, component: str) -> list[str]:
    problems = []
    for token in fields.get("reexported-modules", []):
        if any(module in token for module in GUARDED_MODULES):
            problems.append(f"{cabal_path} ({component}): reexported-modules re-exports {token}")
    mixins = " ".join(fields.get("mixins", []))
    if BRIDGE_LIBRARY in mixins or any(module in mixins for module in GUARDED_MODULES):
        problems.append(f"{cabal_path} ({component}): a mixin names the issuer bridge")
    return problems


def check(root: str) -> list[str]:
    importers, dependents = load_allowlist(root)
    try:
        packages = load_packages(WorkTree(root), required=True)
    except PlannerError as error:
        raise GuardError(str(error)) from error
    problems: list[str] = []
    seen_importers: set[tuple[str, str]] = set()
    seen_components: set[str] = set()
    seen_modules: set[tuple[str, str]] = set()
    for package in sorted(packages.values(), key=lambda entry: entry.name):
        for (kind, name), fields in sorted(package.components.items()):
            component = component_id(package.name, kind, name)
            seen_components.add(component)
            depends, dependency_problems = depends_on_bridge(fields, package.cabal_path)
            problems.extend(dependency_problems)
            if depends and component not in dependents:
                problems.append(f"{package.cabal_path}: {component} depends on {BRIDGE_PACKAGE}:{BRIDGE_LIBRARY} and is not a listed dependent in {ALLOWLIST_PATH}")
            problems.extend(cabal_reexport_problems(fields, package.cabal_path, component))
            sources, source_problems = component_sources(root, package, fields)
            problems.extend(source_problems)
            for module, path in sources:
                seen_modules.add((component, module))
                try:
                    with open(os.path.join(root, path), encoding="utf-8") as handle:
                        text = handle.read()
                except (OSError, UnicodeDecodeError) as error:
                    problems.append(f"{path}: cannot be read: {error}")
                    continue
                try:
                    code = blank_non_code(text)
                    guarded = [imported for imported in imported_modules(code) if imported in GUARDED_MODULES]
                    items = export_items(code)
                except Unsupported as error:
                    problems.append(f"{path} ({component}): {error}; the guard does not pass what it cannot read")
                    continue
                if guarded:
                    if (component, module) in importers:
                        seen_importers.add((component, module))
                    else:
                        problems.append(f"{path}: {module} in {component} imports {', '.join(sorted(set(guarded)))} and is not listed in {ALLOWLIST_PATH}")
                defining = (component, module) in DEFINING
                for problem in reexport_problems(items or [], bool(guarded), defining):
                    problems.append(f"{path}: {module} in {component} {problem}")
    for component, module in sorted(importers - seen_importers):
        if component not in seen_components:
            problems.append(f"{ALLOWLIST_PATH}: the listed component {component} does not exist")
        elif (component, module) not in seen_modules:
            problems.append(f"{ALLOWLIST_PATH}: the listed module {module} is not a source of {component}")
        else:
            problems.append(f"{ALLOWLIST_PATH}: the listed module {module} of {component} imports no bridge module: a stale entry")
    for component in sorted(dependents - seen_components):
        problems.append(f"{ALLOWLIST_PATH}: the listed dependent {component} does not exist")
    return problems


def scope(root: str) -> list[str]:
    """The paths the guard reads: every package description and every source directory, one `kind path` per line."""
    try:
        packages = load_packages(WorkTree(root), required=True)
    except PlannerError as error:
        raise GuardError(str(error)) from error
    lines = {f"description {package.cabal_path}" for package in packages.values()}
    for package in packages.values():
        for fields in package.components.values():
            for directory in fields.get("hs-source-dirs", []) or ["."]:
                lines.add(f"directory {os.path.normpath(os.path.join(package.directory, directory))}")
    return sorted(lines)


def default_root() -> str:
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", default=default_root(), help="the repository root to check")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="fail on an unlisted import or dependency, a re-export, or a stale entry")
    commands.add_parser("scope", help="print the package descriptions and source directories the guard reads")
    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "scope":
            for line in scope(arguments.root):
                print(line)
            return 0
        problems = check(arguments.root)
    except GuardError as error:
        print(f"owner_tx_guard: {error}", file=sys.stderr)
        return 2
    for problem in problems:
        print(f"owner_tx_guard: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
