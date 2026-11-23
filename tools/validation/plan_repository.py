"""Repository access for the validation planner: paths, trees, and changes.

Everything the planner knows about a revision it reads through here: a resolved
commit's tracked files (``GitTree``), a working tree read without Git
(``WorkTree``), repository-relative path matching, and the paths two revisions
differ in. ``PlannerError``, the diagnostic every planner module reports instead
of a plan, lives here because this is the one module all of them import.

It depends on Python 3 and Git alone. See ``docs/validation.md``.
"""

from __future__ import annotations

import os
import re
import subprocess


class PlannerError(Exception):
    """A diagnostic the planner reports instead of producing a plan."""


# --------------------------------------------------------------------------
# Paths


def join_path(*parts: str) -> str:
    """Join and normalize repository-relative POSIX path segments."""
    segments: list[str] = []
    for part in parts:
        for segment in part.replace("\\", "/").split("/"):
            if segment in ("", "."):
                continue
            if segment == "..":
                if not segments:
                    raise PlannerError(f"path escapes the repository root: {'/'.join(parts)}")
                segments.pop()
            else:
                segments.append(segment)
    return "/".join(segments)


def matches_input(path: str, entry: str) -> bool:
    """An input entry is a directory prefix when it ends in ``/``, else an exact path."""
    if entry.endswith("/"):
        return path == entry[:-1] or path.startswith(entry)
    if entry == "":
        return True
    return path == entry


def matches_class(path: str, pattern: str) -> bool:
    """Match a non-affecting class pattern.

    A pattern containing ``/`` is anchored at the repository root and its ``*``
    does not cross a directory separator; a pattern without ``/`` matches any
    file whose basename matches it.
    """
    if "/" in pattern:
        regex = "".join(r"[^/]*" if char == "*" else re.escape(char) for char in pattern)
        return re.fullmatch(regex, path) is not None
    basename = path.rsplit("/", 1)[-1]
    regex = "".join(r"[^/]*" if char == "*" else re.escape(char) for char in pattern)
    return re.fullmatch(regex, basename) is not None


# --------------------------------------------------------------------------
# Trees


def decode(raw: bytes, description: str) -> str:
    """Decode strictly: silently repaired metadata is not readable metadata."""
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise PlannerError(f"{description} is not valid UTF-8: {error}") from error


def run_git(root: str, *args: str) -> str:
    process = subprocess.run(
        ("git", "-C", root) + args,
        capture_output=True,
        check=False,
    )
    if process.returncode != 0:
        stderr = process.stderr.decode("utf-8", errors="replace").strip()
        raise PlannerError("git " + " ".join(args) + " failed: " + (stderr or "no output"))
    return decode(process.stdout, "git " + " ".join(args) + " output")


class GitTree:
    """The tracked contents of one resolved commit."""

    def __init__(self, root: str, revision: str) -> None:
        self.root = root
        self.revision = revision
        try:
            self.commit = run_git(root, "rev-parse", "--verify", "--quiet", revision + "^{commit}").strip()
        except PlannerError as error:
            raise PlannerError(f"cannot resolve revision {revision!r}: {error}") from error
        if not self.commit:
            raise PlannerError(f"cannot resolve revision {revision!r} to a commit")
        self.tree = run_git(root, "rev-parse", "--verify", self.commit + "^{tree}").strip()
        listing = run_git(root, "ls-tree", "-r", "-z", "--name-only", self.commit)
        self._files = frozenset(entry for entry in listing.split("\0") if entry)

    @property
    def label(self) -> str:
        return f"{self.revision} ({self.commit[:12]})"

    def files(self) -> frozenset[str]:
        return self._files

    def exists(self, path: str) -> bool:
        return path in self._files

    def read(self, path: str) -> str:
        if not self.exists(path):
            raise PlannerError(f"{path} does not exist at {self.label}")
        process = subprocess.run(
            ("git", "-C", self.root, "show", f"{self.commit}:{path}"),
            capture_output=True,
            check=False,
        )
        if process.returncode != 0:
            raise PlannerError(f"cannot read {path} at {self.label}")
        return decode(process.stdout, f"{path} at {self.label}")


class WorkTree:
    """The working-tree contents under a root directory, without consulting Git."""

    label = "working tree"
    commit = None
    tree = None
    revision = "working tree"

    def __init__(self, root: str) -> None:
        self.root = root
        found: set[str] = set()
        for directory, names, filenames in os.walk(root):
            names[:] = [name for name in names if name not in (".git", "dist-newstyle")]
            for filename in filenames:
                absolute = os.path.join(directory, filename)
                found.add(os.path.relpath(absolute, root).replace(os.sep, "/"))
        self._files = frozenset(found)

    def files(self) -> frozenset[str]:
        return self._files

    def exists(self, path: str) -> bool:
        return os.path.isfile(os.path.join(self.root, path))

    def read(self, path: str) -> str:
        try:
            with open(os.path.join(self.root, path), "rb") as handle:
                raw = handle.read()
        except OSError as error:
            raise PlannerError(f"cannot read {path}: {error}") from error
        return decode(raw, path)


# --------------------------------------------------------------------------
# Changed paths


def changed_paths(root: str, base: GitTree, head: GitTree) -> list[dict]:
    """Both endpoints of a rename and the removed path of a deletion count as changed."""
    raw = run_git(root, "diff", "--name-status", "-z", "--find-renames", base.commit, head.commit)
    fields = [entry for entry in raw.split("\0") if entry != ""]
    changes: dict[str, str] = {}
    index = 0
    while index < len(fields):
        status = fields[index]
        index += 1
        if status[0] in ("R", "C"):
            old, new = fields[index], fields[index + 1]
            index += 2
            changes.setdefault(old, "R-source")
            changes[new] = "R-target" if status[0] == "R" else "C-target"
        else:
            path = fields[index]
            index += 1
            changes.setdefault(path, status)
    return [{"path": path, "status": changes[path]} for path in sorted(changes)]
