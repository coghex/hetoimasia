#!/usr/bin/env python3
"""The build identity `tools/vulkan/run.sh build` stamps and `run.sh native` reads.

An executable built earlier is run later, by a command that builds nothing. What
that run reports as its provenance must describe the executable, not the source
tree at run time, so the build records, beside the executable, the revision and
source digest of the tree it built from, and the run reads them back.

A stamp is bound to the executable it was made for by that executable's own
content (SHA-256), its path and the build variant, so it is refused rather than
trusted when it is missing, incomplete, malformed, copied from another build or
another component, or left behind by an executable that has since been replaced.

    build_identity.py record --directory DIR --executable PATH --variant NAME
                             --revision TEXT --digest HEX
    build_identity.py verify --directory DIR --executable PATH --variant NAME

`record` writes the stamp atomically (a temporary file in DIR renamed over the
stamp), and exits 1 with a one-line diagnostic when it cannot. `verify` prints
the recorded revision and digest, one per line, and exits 0; otherwise it prints
one line saying why the identity cannot be trusted and exits 1. Neither reads
the source tree: the digest is computed by `run.sh`, which compares it.

Ownership: a stamp is written by `run.sh build` in the build directory's
`native-identity` directory, read by `run.sh native`, and removed with the build
directory it lives in. Nothing else writes it, and no state outlives one call.
"""

import argparse
import hashlib
import os
import re
import sys
import tempfile

FORMAT = "hetoimasia-native-identity 1"
HEX = re.compile(r"[0-9a-f]{64}\Z")
# A commit id, optionally dirty, or the word the runner uses outside a checkout.
REVISION = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})(?: \(dirty\))?\Z|unknown\Z")
VARIANT = re.compile(r"[a-z]+\Z")
CHUNK = 1 << 20


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            block = handle.read(CHUNK)
            if not block:
                return digest.hexdigest()
            digest.update(block)


def stamp_path(directory, executable):
    """One stamp per executable path, named so two components never share one."""
    key = hashlib.sha256(executable.encode("utf-8")).hexdigest()[:16]
    return os.path.join(directory, os.path.basename(executable) + "-" + key + ".stamp")


def render(executable, variant, executable_sha256, revision, digest):
    return "\n".join([
        FORMAT,
        "executable " + executable,
        "variant " + variant,
        "sha256 " + executable_sha256,
        "revision " + revision,
        "digest " + digest,
        "end",
    ]) + "\n"


def parse(text):
    """The stamp's fields, or the reason it is not a complete, well-formed one."""
    if not text.endswith("\n"):
        return None, "it is truncated"
    lines = text[:-1].split("\n")
    expected = ["", "executable ", "variant ", "sha256 ", "revision ", "digest ", "end"]
    if lines[:1] != [FORMAT]:
        return None, "it is not a build identity of this format"
    if len(lines) != len(expected):
        return None, "it is incomplete or has extra lines"
    values = {}
    for line, prefix in zip(lines[1:], expected[1:]):
        if prefix == "end":
            if line != "end":
                return None, "it has no end marker"
            continue
        if not line.startswith(prefix) or len(line) == len(prefix):
            return None, "its '%s' field is absent or empty" % prefix.strip()
        values[prefix.strip()] = line[len(prefix):]
    if not VARIANT.match(values["variant"]):
        return None, "its variant is malformed"
    if not HEX.match(values["sha256"]):
        return None, "its executable hash is malformed"
    if not REVISION.match(values["revision"]):
        return None, "its revision is malformed"
    if not HEX.match(values["digest"]):
        return None, "its source digest is malformed"
    return values, None


def record(arguments):
    executable = os.path.abspath(arguments.executable)
    if not os.path.isfile(executable):
        return fail("%s is not a file" % executable)
    if "\n" in executable:
        return fail("the executable's path contains a newline")
    if not VARIANT.match(arguments.variant):
        return fail("variant %r is malformed" % arguments.variant)
    if not REVISION.match(arguments.revision):
        return fail("revision %r is malformed" % arguments.revision)
    if not HEX.match(arguments.digest):
        return fail("source digest %r is malformed" % arguments.digest)
    text = render(executable, arguments.variant, sha256_of(executable), arguments.revision, arguments.digest)
    target = stamp_path(arguments.directory, executable)
    descriptor, temporary = tempfile.mkstemp(dir=arguments.directory, prefix=".stamp-")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(temporary, target)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise
    return 0


def verify(arguments):
    executable = os.path.abspath(arguments.executable)
    target = stamp_path(arguments.directory, executable)
    try:
        with open(target, "r", encoding="utf-8", errors="strict", newline="") as handle:
            text = handle.read()
    except FileNotFoundError:
        return fail("it has no recorded build identity")
    except (OSError, UnicodeDecodeError) as error:
        return fail("its recorded build identity cannot be read (%s)" % error)
    values, reason = parse(text)
    if values is None:
        return fail("its recorded build identity is unusable: %s" % reason)
    if values["executable"] != executable:
        return fail("its recorded build identity was made for %s" % values["executable"])
    if values["variant"] != arguments.variant:
        return fail("its recorded build identity belongs to the %s variant" % values["variant"])
    try:
        actual = sha256_of(executable)
    except OSError as error:
        return fail("the executable cannot be read (%s)" % error)
    if values["sha256"] != actual:
        return fail("the executable is not the one its recorded build identity was made for (it was replaced after that build)")
    sys.stdout.write(values["revision"] + "\n" + values["digest"] + "\n")
    return 0


def fail(message):
    sys.stdout.write(message + "\n")
    return 1


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("record", "verify"):
        command = commands.add_parser(name)
        command.add_argument("--directory", required=True)
        command.add_argument("--executable", required=True)
        command.add_argument("--variant", required=True)
        if name == "record":
            command.add_argument("--revision", required=True)
            command.add_argument("--digest", required=True)
    arguments = parser.parse_args(argv)
    if arguments.command == "record":
        try:
            os.makedirs(arguments.directory, exist_ok=True)
            return record(arguments)
        except OSError as error:
            return fail(str(error))
    return verify(arguments)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
