#!/usr/bin/env python3
"""The guard against new unowned test starts (#584).

A test that starts a thread or a subprocess must own it: acquire it under mask, register its stop-and-join in the same
step, and stop *and join* it on every exit (a normal return, an exception, a timeout of the example, a cancellation). The
one shared facility for a thread is ``Test.Support.Owned`` in ``tools/test-support`` (``withOwnedThread``,
``withOwnedThreadOpening``), and the one for a subprocess is ``Test.Support.Subprocess`` in the same library
(``runToCompletion``, ``runCaptured``, ``withScopedChild``; #588). This tool finds every call to a start primitive in the repository's test sources and fails when one is neither made
through that facility nor accounted for.

What it checks, and what each check cannot do:

* ``check`` scans the test sources (below), counts the start primitives outside comments, string literals, character
  literals, imports and the module header, removes the exempt sites, and requires the remaining count of every file to
  *equal* the checked-in baseline (``owned_starts_baseline.json``): a count above the baseline is a new unowned start; a
  count below it is a stale baseline entry, so the baseline stays honest. It is a per-file *count* ratchet, as signed off:
  it cannot tell a new unowned start that replaces another in the same file from no change, and it does not track
  individual sites; that case stays a review responsibility. The baseline is a known-debt list classified mechanically,
  not a list of proven leaks: a later change must verify a site before converting it.
* ``ratchet --base REV`` requires the baseline to be no larger than the review base's: no entry may be added and no count
  may increase. A base without a baseline file is the explicit bootstrap, in which the baseline is established.
* ``bootstrap`` writes the baseline from what the scanner observes. It is the only way the initial baseline is made.

The scan scope is derived, not listed. The test sources are the source directories of every ``test-suite`` in the package
descriptions that ``cabal.project`` and ``cabal.project.vulkan`` list (so a new suite is covered without editing this tool)
and of every other library or executable that exists for tests (named for tests by ``TEST_ONLY_TOKENS``, or listed in the
configuration), through the planner's own Cabal reader, which counts conditional and platform-specific source directories
whichever platform runs it. Components the suites launch as child processes are excluded by name, with their reason, in
``owned_starts.json``; so are the sites that are provably owned, one binding at a time, with the number of sites each
holds, so an additional start inside an exempt helper fails like any other.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass

# A one-shot tool must not write into the checkout it is validating (this directory is a policy root, and the runner refuses
# a checkout that has gained a file in it). `python3 -I` ignores PYTHONDONTWRITEBYTECODE, so the switch is made here, before
# the imports that would leave a `__pycache__` beside the sibling modules.
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from plan_cabal import load_packages  # noqa: E402
from plan_repository import PlannerError, WorkTree  # noqa: E402

CONFIG_PATH = "tools/validation/owned_starts.json"
BASELINE_PATH = "tools/validation/owned_starts_baseline.json"
FACILITY_PATH = "tools/test-support/src/Test/Support/Owned.hs"
FACILITY = "Test.Support.Owned.withOwnedThread"
SUBPROCESS_FACILITY_PATH = "tools/test-support/src/Test/Support/Subprocess.hs"
SUBPROCESS_FACILITY = "Test.Support.Subprocess"

SCHEMA_VERSION = 1

# A component that is not a test suite is scanned when a dash-separated word of its name is one of these.
TEST_ONLY_TOKENS = frozenset({"test", "tests", "probe", "check", "harness", "fixtures"})

# The words a column-zero lower-case line may begin with that are not a function binding.
DECLARATION_KEYWORDS = frozenset(
    {
        "import",
        "module",
        "data",
        "type",
        "newtype",
        "class",
        "instance",
        "deriving",
        "default",
        "foreign",
        "infix",
        "infixl",
        "infixr",
        "pattern",
        "family",
        "where",
    }
)

SYMBOL_CHARACTERS = frozenset("!#$%&*+./<=>?@\\^|-~:")
CHARACTER_LITERAL = re.compile(r"'(?:[^\\'\n]|\\(?:'|\"|\\|[A-Za-z0-9^@\[\]_]+))'")
BINDING_START = re.compile(r"^([a-z_][A-Za-z0-9_']*)")


class GuardError(Exception):
    """A configuration or tree the guard cannot read; never a finding."""


class Unsupported(Exception):
    """Syntax the scanner cannot read with the certainty a guard needs. It is reported as a problem and fails the check:
    the guard rejects what it cannot see rather than passing it."""


# --------------------------------------------------------------------------
# Reading Haskell: what is code


def blank_non_code(text: str, pragmas: list[str] | None = None) -> str:
    """The source with comments, string literals and character literals replaced by spaces.

    Newlines and columns are kept, so a line number and an indentation in the result are the source's. Block comments nest.
    A line comment starts at a run of two or more dashes that is not part of a longer operator. The text of every pragma
    (a block comment that opens with ``{-#``) is appended to ``pragmas`` when it is given.
    """
    out: list[str] = []
    index = 0
    length = len(text)
    depth = 0
    pragma_start = -1
    while index < length:
        char = text[index]
        pair = text[index : index + 2]
        if depth > 0:
            if pair == "{-":
                depth += 1
                out.append("  ")
                index += 2
            elif pair == "-}":
                depth -= 1
                out.append("  ")
                index += 2
                if depth == 0 and pragma_start >= 0:
                    if pragmas is not None:
                        pragmas.append(text[pragma_start:index])
                    pragma_start = -1
            else:
                out.append("\n" if char == "\n" else " ")
                index += 1
            continue
        if pair == "{-":
            depth = 1
            pragma_start = index if text[index : index + 3] == "{-#" else -1
            out.append("  ")
            index += 2
            continue
        if char == "-" and pair == "--":
            end = index
            while end < length and text[end] == "-":
                end += 1
            before = text[index - 1] if index > 0 else "\n"
            after = text[end] if end < length else "\n"
            if before not in SYMBOL_CHARACTERS and after not in SYMBOL_CHARACTERS:
                while end < length and text[end] != "\n":
                    end += 1
                out.append(" " * (end - index))
                index = end
                continue
        if char == '"':
            if text[index : index + 3] == '"""':
                raise Unsupported("a multi-line string literal (three double quotes) is not supported by the scanner")
            end = index + 1
            while end < length:
                current = text[end]
                if current == "\\":
                    following = text[end + 1 : end + 2]
                    if following.isspace():
                        # A string gap: from the backslash to the next backslash.
                        end += 1
                        while end < length and text[end] != "\\":
                            end += 1
                        end += 1
                    else:
                        end += 2
                elif current == '"':
                    end += 1
                    break
                elif current == "\n":
                    # An unterminated string is not Haskell; stop at the line so one bad line cannot blank the file.
                    break
                else:
                    end += 1
            segment = text[index:end]
            out.append("".join("\n" if c == "\n" else " " for c in segment))
            index = end
            continue
        if char == "'":
            previous = text[index - 1] if index > 0 else " "
            if not (previous.isalnum() or previous in "_'"):
                match = CHARACTER_LITERAL.match(text, index)
                if match:
                    out.append(" " * (match.end() - index))
                    index = match.end()
                    continue
        out.append(char)
        index += 1
    return "".join(out)


MODULE_HEADER = re.compile(r"\A\s*module\b.*?\bwhere\b", re.DOTALL)


IMPORT_KEYWORD = re.compile(r"import(?![A-Za-z0-9_'])")


def body_column(code: str) -> int:
    """The column the top-level declarations of the module sit at: Haskell's layout rule for the module body.

    That is the column of the first token after the header's ``where``, or of the first token of a file with no header.
    It is column zero in almost every file, but a valid module may indent its whole body. A body in explicit braces has no
    such column, and the scanner does not read it: it is rejected.
    """
    header = MODULE_HEADER.match(code)
    rest = code[header.end() :] if header else code
    offset = header.end() if header else 0
    for match in re.finditer(r"\S", rest):
        position = offset + match.start()
        if code[position] == "{":
            raise Unsupported("a module body in explicit braces is not supported by the scanner; use the layout rule")
        return position - (code.rfind("\n", 0, position) + 1)
    return 0


def blank_declarations(code: str) -> str:
    """The code with import declarations and the module header (with its export list) replaced by spaces.

    A declaration starts at a line indented no further than the module body's column, and the more deeply indented lines
    after it belong to it. An import ends at the next declaration or at a semicolon outside its parentheses, and what follows
    that semicolon on the line is code again: ``import M; main = forkIO x`` has a start. What an import or an export list
    mentions is not a start.
    """
    header = MODULE_HEADER.match(code)
    if header:
        code = "".join("\n" if c == "\n" else " " for c in code[: header.end()]) + code[header.end() :]
    column = body_column(code)
    lines = code.split("\n")
    importing = False
    depth = 0
    for number, line in enumerate(lines):
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        position = 0
        if indent <= column:
            importing = False
            position = indent
        characters = list(line)
        while True:
            if not importing:
                if IMPORT_KEYWORD.match(line, position) and (indent <= column or position > indent):
                    importing = True
                    depth = 0
                else:
                    break
            ended = False
            while position < len(line):
                character = line[position]
                characters[position] = " "
                position += 1
                if character == "(":
                    depth += 1
                elif character == ")":
                    depth -= 1
                elif character == ";" and depth <= 0:
                    ended = True
                    break
            if not ended:
                break
            importing = False
            while position < len(line) and line[position].isspace():
                position += 1
        lines[number] = "".join(characters)
    return "\n".join(lines)


@dataclass(frozen=True)
class Site:
    """One call to a start primitive."""

    path: str
    line: int
    primitive: str
    binding: str | None


def primitive_pattern(primitives: list[str]) -> re.Pattern[str]:
    names = "|".join(re.escape(name) for name in sorted(primitives, key=len, reverse=True))
    # An optional module qualification, then the primitive as a whole identifier.
    return re.compile(r"(?<![A-Za-z0-9_'])(?:[A-Z][A-Za-z0-9_']*\.)*(" + names + r")(?![A-Za-z0-9_'])")


UNREADABLE_EXTENSIONS = ("TemplateHaskell", "QuasiQuotes")
SOURCE_KINDS_NOT_READ = (".lhs", ".hsc", ".chs", ".hs-boot", ".cpphs", ".gc", ".x", ".y", ".ly")


def enables_unreadable_extension(pragmas: list[str]) -> str | None:
    """The first of Template Haskell and quasi-quotation that a pragma of the source turns on, if any."""
    for pragma in pragmas:
        for name in UNREADABLE_EXTENSIONS:
            if re.search(r"(?<![A-Za-z0-9_])" + name + r"(?![A-Za-z0-9_])", pragma):
                return name
    return None


def find_sites(path: str, text: str, primitives: list[str]) -> list[Site]:
    """Every start primitive called in one source file, with the top-level binding it is in."""
    pragmas: list[str] = []
    readable = blank_non_code(text, pragmas)
    extension = enables_unreadable_extension(pragmas)
    if extension is not None:
        # A splice builds code from an expression and a quasi-quote is text of any shape between its bars, so neither can be
        # read the way ordinary code is. Such a file is accepted only when it names no start primitive anywhere, comments and
        # strings included; one that does is rejected. A splice that assembles a primitive's name from pieces is not seen.
        named = primitive_pattern(primitives).search(text)
        if named:
            raise Unsupported(
                f"{extension} is on and the source names {named.group(1)}: the scanner cannot tell code from quoted text there; "
                "move the start out of the file (or out of the splice's reach)"
            )
        return []
    column = body_column(readable)
    code = blank_declarations(readable)
    pattern = primitive_pattern(primitives)
    sites: list[Site] = []
    binding: str | None = None
    for number, line in enumerate(code.split("\n"), start=1):
        if line.strip() and len(line) - len(line.lstrip()) <= column:
            start = BINDING_START.match(line.lstrip())
            if start:
                binding = None if start.group(1) in DECLARATION_KEYWORDS else start.group(1)
            else:
                binding = None
        for match in pattern.finditer(line):
            sites.append(Site(path, number, match.group(1), binding))
    return sites


# --------------------------------------------------------------------------
# Which sources are test sources


def load_json(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as handle:
            document = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise GuardError(f"{path}: {error}") from error
    if not isinstance(document, dict):
        raise GuardError(f"{path} must contain a JSON object")
    return document


def load_config(root: str) -> dict:
    path = os.path.join(root, CONFIG_PATH)
    config = load_json(path)
    problems: list[str] = []
    if config.get("schema_version") != SCHEMA_VERSION:
        problems.append(f"schema_version must be {SCHEMA_VERSION}")
    primitives = config.get("primitives")
    if not isinstance(primitives, list) or not primitives or not all(isinstance(entry, str) for entry in primitives):
        problems.append("'primitives' must be a non-empty list of names")
    for key in ("test_only_components", "excluded_components", "exempt"):
        if not isinstance(config.get(key), list):
            problems.append(f"{key!r} must be a list")
    for entry in config.get("excluded_components", []) if isinstance(config.get("excluded_components"), list) else []:
        if not (isinstance(entry, dict) and isinstance(entry.get("component"), str) and isinstance(entry.get("reason"), str)):
            problems.append(f"an excluded component needs a 'component' and a 'reason': {entry!r}")
    for entry in config.get("test_only_components", []) if isinstance(config.get("test_only_components"), list) else []:
        if not (isinstance(entry, dict) and isinstance(entry.get("component"), str) and isinstance(entry.get("reason"), str)):
            problems.append(f"a test-only component needs a 'component' and a 'reason': {entry!r}")
    for entry in config.get("exempt", []) if isinstance(config.get("exempt"), list) else []:
        if not (
            isinstance(entry, dict)
            and isinstance(entry.get("file"), str)
            and isinstance(entry.get("binding"), str)
            and isinstance(entry.get("sites"), int)
            and isinstance(entry.get("reason"), str)
            and entry["reason"].strip()
        ):
            problems.append(f"an exemption needs a 'file', a 'binding', its number of 'sites' and a 'reason': {entry!r}")
    if problems:
        raise GuardError(f"{CONFIG_PATH}: " + "; ".join(problems))
    return config


def component_name(package: str, kind: str, name: str) -> str:
    return f"{package}:{kind}:{name}"


def scanned_directories(root: str, config: dict) -> tuple[dict[str, str], list[str]]:
    """The directories to scan, each with the component that brings it in, and every problem with the scope."""
    tree = WorkTree(root)
    try:
        packages = load_packages(tree, required=True)
    except PlannerError as error:
        raise GuardError(str(error)) from error
    excluded = {entry["component"]: entry["reason"] for entry in config["excluded_components"]}
    listed = {entry["component"] for entry in config["test_only_components"]}
    known: set[str] = set()
    directories: dict[str, str] = {}
    problems: list[str] = []
    for package in packages.values():
        for (kind, name), fields in sorted(package.components.items()):
            identifier = component_name(package.name, kind, name)
            known.add(identifier)
            if identifier in excluded:
                continue
            tokens = set(name.split("-"))
            wanted = kind == "test" or identifier in listed or bool(tokens & TEST_ONLY_TOKENS)
            if not wanted:
                continue
            for directory in fields.get("hs-source-dirs", []) or ["."]:
                joined = os.path.normpath(os.path.join(package.directory, directory)).replace(os.sep, "/")
                directories.setdefault("" if joined == "." else joined, identifier)
    for identifier in list(excluded) + sorted(listed):
        if identifier not in known:
            problems.append(f"{CONFIG_PATH} names the component {identifier!r}, which no package description declares")
    return directories, problems


def scanned_files(root: str, directories: dict[str, str]) -> dict[str, str]:
    """Every Haskell source under the scanned directories, with the component that brings it in."""
    tree = WorkTree(root)
    found: dict[str, str] = {}
    for path in sorted(tree.files()):
        if not path.endswith(".hs"):
            continue
        for directory, component in directories.items():
            prefix = directory + "/" if directory else ""
            if path.startswith(prefix):
                found.setdefault(path, component)
    return found


def unreadable_scope_problems(root: str, directories: dict[str, str]) -> list[str]:
    """What the scanned directories hold that the scanner cannot read: source kinds other than plain Haskell, and a package
    description that turns on Template Haskell or quasi-quotation for its components."""
    tree = WorkTree(root)
    problems: list[str] = []
    for path in sorted(tree.files()):
        if not path.endswith(SOURCE_KINDS_NOT_READ):
            continue
        if any(path.startswith(directory + "/" if directory else "") for directory in directories):
            problems.append(f"{path}: a source of a kind the scanner does not read (only plain .hs files are)")
    try:
        packages = load_packages(tree, required=True)
    except PlannerError as error:
        raise GuardError(str(error)) from error
    for package in packages.values():
        prefix = package.directory.rstrip("/") + "/" if package.directory not in ("", ".") else ""
        if not any(directory.startswith(prefix) for directory in directories):
            continue
        if not tree.exists(package.cabal_path):
            continue
        for number, line in enumerate(tree.read(package.cabal_path).splitlines(), start=1):
            if line.lstrip().startswith("--"):
                continue
            for name in UNREADABLE_EXTENSIONS:
                if re.search(r"(?<![A-Za-z0-9_])" + name + r"(?![A-Za-z0-9_])", line):
                    problems.append(
                        f"{package.cabal_path}:{number}: {name} is not supported by the scanner, and this package has scanned components"
                    )
    return problems


# --------------------------------------------------------------------------
# The scan


@dataclass
class Scan:
    files: dict[str, str]
    counts: dict[str, int]
    exempt_seen: dict[tuple[str, str], int]
    sites: dict[str, list[Site]]
    problems: list[str]


def scan(root: str) -> Scan:
    config = load_config(root)
    directories, problems = scanned_directories(root, config)
    files = scanned_files(root, directories)
    problems.extend(unreadable_scope_problems(root, directories))
    exempt = {(entry["file"], entry["binding"]): entry for entry in config["exempt"]}
    seen: dict[tuple[str, str], int] = {}
    counts: dict[str, int] = {}
    sites: dict[str, list[Site]] = {}
    for path in files:
        with open(os.path.join(root, path), encoding="utf-8") as handle:
            text = handle.read()
        remaining: list[Site] = []
        try:
            found_sites = find_sites(path, text, config["primitives"])
        except Unsupported as error:
            problems.append(f"{path}: {error}")
            continue
        for site in found_sites:
            key = (path, site.binding or "")
            if site.binding is not None and key in exempt:
                seen[key] = seen.get(key, 0) + 1
            else:
                remaining.append(site)
        if remaining:
            counts[path] = len(remaining)
            sites[path] = remaining
    for key, entry in exempt.items():
        found = seen.get(key, 0)
        if found != entry["sites"]:
            problems.append(
                f"stale exemption: {entry['file']} binding {entry['binding']!r} is exempt for {entry['sites']} start(s) "
                f"but holds {found}; an exempt helper's start count may not change without review"
            )
    return Scan(files, counts, seen, sites, problems)


def load_baseline(root: str) -> dict[str, int]:
    document = load_json(os.path.join(root, BASELINE_PATH))
    files = document.get("files")
    if document.get("schema_version") != SCHEMA_VERSION or not isinstance(files, dict):
        raise GuardError(f"{BASELINE_PATH} must have schema_version {SCHEMA_VERSION} and a 'files' object")
    for path, count in files.items():
        if not isinstance(path, str) or not isinstance(count, int) or isinstance(count, bool) or count < 1:
            raise GuardError(f"{BASELINE_PATH}: {path!r} must map to a positive integer")
    return dict(files)


def describe(sites: list[Site]) -> str:
    return ", ".join(f"{site.primitive}@{site.line}" for site in sites[:6]) + (" ..." if len(sites) > 6 else "")


def is_thread_primitive(name: str) -> bool:
    """A thread start is a ``fork`` primitive; every other primitive starts a subprocess."""
    return name.startswith("fork")


def advice(sites: list[Site]) -> str:
    """Which facility to use, named for the kind of start the file makes."""
    threads = any(is_thread_primitive(site.primitive) for site in sites)
    processes = any(not is_thread_primitive(site.primitive) for site in sites)
    parts: list[str] = []
    if threads or not sites:
        parts.append(f"Start helper threads through {FACILITY} ({FACILITY_PATH})")
    if processes:
        parts.append(
            f"Start subprocesses through {SUBPROCESS_FACILITY} ({SUBPROCESS_FACILITY_PATH}): runCaptured or runToCompletion "
            "for a command run to completion, withScopedChild for a child lent to a body"
        )
    return "; ".join(parts)


def check(root: str) -> list[str]:
    """Every problem with the tree's test starts; empty when the guard passes."""
    result = scan(root)
    baseline = load_baseline(root)
    problems = list(result.problems)
    for path in sorted(set(result.counts) | set(baseline)):
        observed = result.counts.get(path, 0)
        allowed = baseline.get(path, 0)
        if observed > allowed:
            problems.append(
                f"{path}: {observed} unowned thread or process start(s) where the baseline allows {allowed} "
                f"({describe(result.sites.get(path, []))}). {advice(result.sites.get(path, []))}; "
                f"only an already-owned helper may be exempted, in {CONFIG_PATH}, with its reason."
            )
        elif observed < allowed:
            reason = (
                "the file no longer exists in a scanned test source directory or no longer starts anything"
                if observed == 0
                else f"only {observed} remain"
            )
            problems.append(
                f"{path}: stale baseline entry, it allows {allowed} unowned start(s) but {reason}; "
                f"lower or remove the entry in {BASELINE_PATH} (the baseline can only shrink)"
            )
    return problems


def git_show(root: str, revision: str, path: str) -> str | None:
    process = subprocess.run(
        ("git", "-C", root, "show", f"{revision}:{path}"), capture_output=True, check=False
    )
    if process.returncode != 0:
        return None
    return process.stdout.decode("utf-8")


def ratchet(root: str, base: str) -> list[str]:
    """Every way the baseline grew relative to the review base; empty when it did not."""
    exists = subprocess.run(
        ("git", "-C", root, "rev-parse", "--verify", "--quiet", base + "^{commit}"), capture_output=True, check=False
    )
    if exists.returncode != 0:
        raise GuardError(f"cannot resolve the review base {base!r}")
    then_text = git_show(root, base, BASELINE_PATH)
    if then_text is None:
        return []
    try:
        then_document = json.loads(then_text)
        then = then_document["files"]
    except (json.JSONDecodeError, KeyError, TypeError) as error:
        raise GuardError(f"{BASELINE_PATH} at {base} is not a baseline: {error}") from error
    now = load_baseline(root)
    problems: list[str] = []
    for path, count in sorted(now.items()):
        if path not in then:
            problems.append(f"{path}: a baseline entry ({count}) that the review base does not have; the baseline cannot add one")
        elif count > then[path]:
            problems.append(f"{path}: the baseline grew from {then[path]} to {count}; it can only shrink")
    return problems


def bootstrap(root: str) -> dict[str, int]:
    """Write the baseline from what the scanner observes. The one way the initial baseline is made."""
    result = scan(root)
    if result.problems:
        raise GuardError("the scan has problems; fix them before establishing a baseline:\n" + "\n".join(result.problems))
    document = {
        "schema_version": SCHEMA_VERSION,
        "note": (
            "Unowned thread and process starts in the test sources that existed when the guard was introduced (#584), one "
            "count per file, classified mechanically. This is a known-debt list, not a list of proven leaks: verify a "
            "site before converting it. Entries can only shrink; an entry whose count is no longer reached fails the "
            "check. Written by `owned_starts.py bootstrap`; edited afterwards only to lower or remove an entry."
        ),
        "files": dict(sorted(result.counts.items())),
    }
    with open(os.path.join(root, BASELINE_PATH), "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2)
        handle.write("\n")
    return document["files"]


def default_root() -> str:
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", default=default_root(), help="the repository root to scan")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="fail on a new unowned start or a stale baseline entry")
    ratchet_parser = commands.add_parser("ratchet", help="fail when the baseline grew relative to the review base")
    ratchet_parser.add_argument("--base", required=True)
    commands.add_parser("bootstrap", help="write the initial baseline from the observed starts")
    commands.add_parser("inventory", help="print the scanned directories and the observed per-file counts")
    commands.add_parser("scope", help="print the scanned directories and package descriptions, one `kind path` per line")
    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "check":
            problems = check(arguments.root)
        elif arguments.command == "ratchet":
            problems = ratchet(arguments.root, arguments.base)
        elif arguments.command == "scope":
            config = load_config(arguments.root)
            directories, scope_problems = scanned_directories(arguments.root, config)
            for directory in sorted(directories):
                print(f"directory {directory or '.'}")
            for package in sorted(load_packages(WorkTree(arguments.root), required=True).values(), key=lambda entry: entry.name):
                print(f"description {package.cabal_path}")
            problems = scope_problems
        elif arguments.command == "bootstrap":
            written = bootstrap(arguments.root)
            print(f"wrote {BASELINE_PATH}: {sum(written.values())} start(s) in {len(written)} file(s)")
            return 0
        else:
            config = load_config(arguments.root)
            directories, scope_problems = scanned_directories(arguments.root, config)
            result = scan(arguments.root)
            for directory, component in sorted(directories.items()):
                print(f"scanned {directory or '.'} ({component})")
            for path, count in sorted(result.counts.items()):
                print(f"{count:4d} {path}")
            print(f"total {sum(result.counts.values())} in {len(result.counts)} file(s); {len(result.files)} source(s) scanned")
            problems = scope_problems + result.problems
    except GuardError as error:
        print(f"owned_starts: {error}", file=sys.stderr)
        return 2
    for problem in problems:
        print(f"owned_starts: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
