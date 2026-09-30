"""The local Cabal package graph, and the input paths each component derives.

A bounded, fail-closed reader of ``cabal.project`` and the package descriptions
it lists, which follows local dependencies transitively and turns a catalog
group's component into the repository paths that decide its result. Syntax it
does not understand is a diagnostic rather than something it skips.

See ``docs/validation.md`` for what a component's inputs are.
"""

from __future__ import annotations

import os
import re

from plan_repository import PlannerError, join_path

PROJECT_FILE = "cabal.project"

# Project files that select packages the root project deliberately leaves out.
# `cabal.project.vulkan` is the only one: it names the Vulkan native backend
# and its window integration, which neither `cabal.project` nor
# `cabal.project.cpu` may resolve. A group whose command runs through it names
# its component exactly as any other group does, so the component's transitive
# closure is derived from the same package graph; the packages it adds join
# that graph, and `component: "all"` — `cabal build all` through the root
# project — still means the root project's packages alone.
SECONDARY_PROJECT_FILES = ("cabal.project.vulkan",)

COMPONENT_KINDS = ("lib", "exe", "test")

FIELD_PATTERN = re.compile(r"^([A-Za-z][A-Za-z0-9_-]*)\s*:(.*)$")
STANZA_PATTERN = re.compile(r"^([A-Za-z][A-Za-z0-9-]*)(?:\s+(\S+))?\s*$")
CONDITIONAL_PATTERN = re.compile(r"^(if|elif|else)\b")
OS_CONDITIONAL_PATTERN = re.compile(r"^if\s+os\(\s*[A-Za-z][A-Za-z0-9_-]*\s*\)$")
FLAG_CONDITIONAL_PATTERN = re.compile(r"^if\s+flag\(\s*([A-Za-z][A-Za-z0-9_-]*)\s*\)$")
PACKAGE_NAME_PATTERN = re.compile(r"[A-Za-z][A-Za-z0-9-]*")

# The only fields an operating-system conditional may declare. None of them
# names a source, a dependency, or anything else a group's inputs are derived
# from: the link fields choose what an ordinary link adds on one platform, and
# `buildable` chooses whether the stanza is compiled there at all.
#
# `buildable` is deliberately invisible to input derivation. A component that is
# not built on this platform still has its sources, its package description, and
# its declared inputs counted, so a change to a platform-only probe is reported
# as a changed input on every platform. Whether the group that owns it is then
# selected is the group's own business; both confinement probes are optional.
# That is the point: what a candidate's inputs are
# must not depend on which machine planned it, or the same candidate would mean
# two things.
# A conditional on a manual flag the same package description declares is read
# as if both of its branches applied: every field either branch declares is
# counted, whatever the flag's default and whichever project turns it on. That
# over-approximates a component's sources and dependencies rather than letting
# the configuration a project chooses change what a candidate's inputs are, for
# the reason `buildable` is invisible above. A manual flag is required, because
# only a manual flag is never flipped by the solver; an automatic one could
# choose a branch on its own.
LINK_ONLY_FIELDS = frozenset({"extra-libraries", "frameworks"})
CONDITIONAL_FIELDS = LINK_ONLY_FIELDS | frozenset({"buildable"})

STANZA_KEYWORDS = {
    "library",
    "executable",
    "test-suite",
    "benchmark",
    "common",
    "source-repository",
    "flag",
    "custom-setup",
    "foreign-library",
}


# --------------------------------------------------------------------------
# Cabal parsing
#
# Supported syntax is deliberately bounded to what this repository uses:
# layout-style stanzas, ``common``/``import``, multiline fields, package
# relative ``hs-source-dirs``, ``main-is``, ``c-sources``/``cxx-sources`` and
# ``include-dirs``, ``build-depends`` (including a
# ``package:library`` sublibrary dependency) and ``build-tool-depends``, an
# ``if os(...)``/``else`` block inside a stanza that declares only link fields or
# ``buildable``, and an ``if flag(...)``/``else`` block on a manual flag the file
# declares, read as if both branches applied. Any other conditional, and
# brace-delimited syntax, can change dependencies, so it is rejected with a
# diagnostic rather than ignored.


class Package:
    def __init__(self, name: str, directory: str, cabal_path: str) -> None:
        self.name = name
        self.directory = directory
        self.cabal_path = cabal_path
        self.components: dict[tuple[str, str], dict[str, list[str]]] = {}
        # The project files that list this package. The root project's
        # packages are what `component: "all"` means.
        self.projects: set[str] = set()


def field_values(raw: str) -> list[str]:
    cleaned = raw.replace(",", " ")
    return [token for token in cleaned.split() if token]


def parse_cabal(text: str, path: str) -> tuple[str, dict[tuple[str, str], dict[str, list[str]]]]:
    """Parse one package description into its name and its components' fields."""
    package_name = ""
    commons: dict[str, dict[str, list[str]]] = {}
    flags: dict[str, dict[str, list[str]]] = {}
    components: dict[tuple[str, str], dict[str, list[str]]] = {}
    top_level: dict[str, list[str]] = {}

    stanza: dict[str, list[str]] = top_level
    field: str | None = None
    field_indent = 0
    # An open operating-system conditional: its indentation, whether it is the
    # `if` an `else` may follow, and the indentation of the field it is reading.
    conditional_indent: int | None = None
    conditional_is_if = False
    conditional_field_indent: int | None = None
    # An open manual-flag `if` whose `else` may follow, by indentation. Its
    # body is not a separate region: its fields are the stanza's own.
    flag_if_indents: set[int] = set()

    for number, line in enumerate(text.splitlines(), start=1):
        without_comment = line.split("--", 1)[0] if line.lstrip().startswith("--") else line
        if not without_comment.strip():
            continue
        indent = len(without_comment) - len(without_comment.lstrip())
        content = without_comment.strip()

        closed_if: int | None = None
        if conditional_indent is not None:
            if indent > conditional_indent:
                if conditional_field_indent is not None and indent > conditional_field_indent:
                    continue
                body = FIELD_PATTERN.match(content)
                if not body or body.group(1).lower() not in CONDITIONAL_FIELDS:
                    raise PlannerError(
                        f"{path}:{number}: an operating-system conditional may declare only "
                        f"{', '.join(sorted(CONDITIONAL_FIELDS))}; anything else inside it can "
                        "change dependencies or inputs silently"
                    )
                conditional_field_indent = indent
                continue
            closed_if = conditional_indent if conditional_is_if else None
            conditional_indent = None
            conditional_field_indent = None

        if stanza is not top_level:
            flag_if_indents = {opened for opened in flag_if_indents if opened <= indent}
        # A line indented beyond the field it follows continues that field's
        # value, as Cabal reads it, whatever word it begins with: a description
        # whose prose wraps onto a line starting with "else" or "if" is still
        # prose, not a conditional.
        if field is not None and indent > field_indent:
            stanza.setdefault(field, []).extend(field_values(content))
            continue
        if CONDITIONAL_PATTERN.match(content) or content in ("{", "}") or content.endswith("{"):
            flag_match = FLAG_CONDITIONAL_PATTERN.fullmatch(content)
            if indent > 0 and stanza is not top_level and flag_match is not None:
                name = flag_match.group(1)
                declared = flags.get(name)
                if declared is None:
                    raise PlannerError(
                        f"{path}:{number}: `if flag({name})` names a flag this package description "
                        "does not declare before it; the validation planner reads only a declared "
                        "manual flag's conditional"
                    )
                if [value.lower() for value in declared.get("manual", [])] != ["true"]:
                    raise PlannerError(
                        f"{path}:{number}: flag {name!r} is not declared `manual: True`, so the "
                        "solver may choose its branch and change dependencies silently"
                    )
                flag_if_indents.add(indent)
                field = None
                continue
            if content == "else" and indent in flag_if_indents:
                flag_if_indents.discard(indent)
                field = None
                continue
            opens_if = OS_CONDITIONAL_PATTERN.fullmatch(content) is not None
            opens_else = content == "else" and closed_if == indent
            if indent > 0 and stanza is not top_level and (opens_if or opens_else):
                conditional_indent = indent
                conditional_is_if = opens_if
                conditional_field_indent = None
                field = None
                continue
            raise PlannerError(
                f"{path}:{number}: conditional or brace-delimited Cabal syntax is not supported "
                "by the validation planner; it can change dependencies silently (only an "
                "`if os(...)` or `else` block inside a stanza declaring link fields is accepted)"
            )

        stanza_match = STANZA_PATTERN.match(content)
        if indent == 0 and stanza_match and stanza_match.group(1).lower() in STANZA_KEYWORDS:
            keyword = stanza_match.group(1).lower()
            label = stanza_match.group(2) or ""
            stanza = {}
            field = None
            flag_if_indents = set()
            if keyword == "common":
                commons[label] = stanza
            elif keyword == "flag":
                flags[label] = stanza
            elif keyword == "library":
                components[("lib", label or "@package")] = stanza
            elif keyword == "executable":
                components[("exe", label)] = stanza
            elif keyword in ("test-suite", "benchmark"):
                components[("test" if keyword == "test-suite" else "bench", label)] = stanza
            continue

        match = FIELD_PATTERN.match(content)
        if match:
            name = match.group(1).lower()
            values = field_values(match.group(2))
            if indent == 0:
                stanza = top_level
                if name == "name" and values:
                    package_name = values[0]
            stanza.setdefault(name, []).extend(values)
            field = name
            field_indent = indent
            continue

        raise PlannerError(f"{path}:{number}: unsupported Cabal syntax: {content!r}")

    if not package_name:
        raise PlannerError(f"{path}: the package description declares no name")

    resolved: dict[tuple[str, str], dict[str, list[str]]] = {}
    for (kind, label), fields in components.items():
        merged: dict[str, list[str]] = {}
        for imported in fields.get("import", []):
            if imported not in commons:
                raise PlannerError(f"{path}: stanza imports undefined common stanza {imported!r}")
            for key, values in commons[imported].items():
                merged.setdefault(key, []).extend(values)
        for key, values in fields.items():
            if key == "import":
                continue
            merged.setdefault(key, []).extend(values)
        resolved[(kind, package_name if label == "@package" else label)] = merged
    return package_name, resolved


def parse_project(text: str, path: str) -> list[str]:
    """Read the ``packages:`` field of a ``cabal.project``."""
    entries: list[str] = []
    collecting = False
    indent = 0
    for number, line in enumerate(text.splitlines(), start=1):
        if line.lstrip().startswith("--") or not line.strip():
            continue
        current = len(line) - len(line.lstrip())
        content = line.strip()
        if collecting and current > indent:
            entries.extend(field_values(content))
            continue
        collecting = False
        match = FIELD_PATTERN.match(content)
        if match and match.group(1).lower() == "packages":
            collecting = True
            indent = current
            entries.extend(field_values(match.group(2)))
    for entry in entries:
        if any(character in entry for character in "*?["):
            raise PlannerError(
                f"{path}: glob package entry {entry!r} is not supported by the validation planner"
            )
    return entries


def load_packages(tree, required: bool) -> dict[str, Package]:
    """Read the local package graph from one tree.

    ``required`` distinguishes the head revision, where the project metadata must
    exist, from a base revision that may predate it. The root project is
    required; a secondary project file is read wherever it exists, and a
    package both list must be the same directory in each.
    """
    if not tree.exists(PROJECT_FILE):
        if required:
            raise PlannerError(f"{PROJECT_FILE} does not exist at {tree.label}")
        return {}
    packages: dict[str, Package] = {}
    for project in (PROJECT_FILE,) + SECONDARY_PROJECT_FILES:
        if project != PROJECT_FILE and not tree.exists(project):
            continue
        load_project_packages(tree, project, required, packages)
    return packages


def load_project_packages(tree, project: str, required: bool, packages: dict[str, Package]) -> None:
    """Add the packages one project file lists to the graph."""
    directories = parse_project(tree.read(project), f"{project}@{tree.label}")
    for entry in directories:
        directory = join_path(entry)
        candidates = sorted(
            path
            for path in tree.files()
            if path.endswith(".cabal") and join_path(os.path.dirname(path)) == directory
        )
        if not candidates:
            if required:
                raise PlannerError(
                    f"no package description under {entry!r} at {tree.label}; "
                    f"{project} lists it as a local package"
                )
            continue
        if len(candidates) > 1:
            raise PlannerError(f"{entry!r} contains more than one package description at {tree.label}")
        cabal_path = candidates[0]
        name, components = parse_cabal(tree.read(cabal_path), f"{cabal_path}@{tree.label}")
        known = packages.get(name)
        if known is not None:
            if known.directory != directory:
                raise PlannerError(f"two local packages are named {name!r} at {tree.label}")
            if project in known.projects:
                raise PlannerError(f"{project} lists {name!r} twice at {tree.label}")
            known.projects.add(project)
            continue
        package = Package(name, directory, cabal_path)
        package.components = components
        package.projects.add(project)
        packages[name] = package


def component_closure(
    packages: dict[str, Package], start: list[tuple[str, str, str]]
) -> set[tuple[str, str, str]]:
    """Follow local ``build-depends`` and ``build-tool-depends`` transitively."""
    seen: set[tuple[str, str, str]] = set()
    pending = list(start)
    while pending:
        current = pending.pop()
        if current in seen:
            continue
        seen.add(current)
        package_name, kind, component_name = current
        package = packages.get(package_name)
        if package is None:
            continue
        fields = package.components.get((kind, component_name))
        if fields is None:
            continue
        previous = ""
        for token in fields.get("build-depends", []):
            names_package = previous not in (">=", "<", "==", "&&", ">", "<=")
            if PACKAGE_NAME_PATTERN.fullmatch(token) and names_package:
                if token in packages:
                    pending.append((token, "lib", token))
            elif ":" in token and names_package:
                # `package:library` names one library of a package: a sublibrary,
                # or the main library when the two names agree, which is how the
                # main library is keyed.
                dependency, _, library = token.partition(":")
                if library.startswith("{"):
                    raise PlannerError(
                        f"{package.cabal_path}: the braced sublibrary dependency {token!r} is not "
                        "supported by the validation planner; name each library on its own"
                    )
                if (
                    PACKAGE_NAME_PATTERN.fullmatch(dependency)
                    and PACKAGE_NAME_PATTERN.fullmatch(library)
                    and dependency in packages
                ):
                    pending.append((dependency, "lib", library))
            previous = token
        for token in fields.get("build-tool-depends", []):
            if ":" in token:
                tool_package, _, tool_name = token.partition(":")
                tool_name = tool_name.split()[0] if tool_name.split() else tool_name
                if tool_package in packages:
                    pending.append((tool_package, "exe", tool_name))
    return seen


def component_inputs(packages: dict[str, Package], component: str | None) -> set[str]:
    """Derive the input paths of a catalog group's Cabal component."""
    if component is None:
        return set()
    if component == "all":
        start = [
            (package.name, kind, name)
            for package in packages.values()
            if PROJECT_FILE in package.projects
            for (kind, name) in package.components
        ]
    else:
        package_name, kind, name = component.split(":")
        if package_name not in packages:
            return set()
        if (kind, name) not in packages[package_name].components:
            return set()
        start = [(package_name, kind, name)]

    inputs: set[str] = {PROJECT_FILE}
    for package_name, kind, name in component_closure(packages, start):
        package = packages.get(package_name)
        if package is None:
            continue
        inputs.add(package.cabal_path)
        fields = package.components.get((kind, name))
        if fields is None:
            continue
        directories = fields.get("hs-source-dirs", []) or ["."]
        for directory in directories:
            prefix = join_path(package.directory, directory)
            inputs.add(prefix + "/" if prefix else "")
            for main in fields.get("main-is", []):
                inputs.add(join_path(prefix, main))
        # Native sources are compiled into the component as surely as its
        # Haskell is, and they are declared relative to the package rather than
        # to a Haskell source directory, so neither is reached by the loop
        # above. A group whose C changed and whose plan said nothing would be
        # evidence about a component that was not the one built.
        for source in fields.get("c-sources", []) + fields.get("cxx-sources", []):
            inputs.add(join_path(package.directory, source))
        for directory in fields.get("include-dirs", []):
            prefix = join_path(package.directory, directory)
            inputs.add(prefix + "/" if prefix else "")
    return inputs


def resolve_component(packages: dict[str, Package], component: str) -> bool:
    if component == "all":
        return any(PROJECT_FILE in package.projects for package in packages.values())
    parts = component.split(":")
    if len(parts) != 3 or parts[1] not in COMPONENT_KINDS:
        return False
    package_name, kind, name = parts
    package = packages.get(package_name)
    return package is not None and (kind, name) in package.components
