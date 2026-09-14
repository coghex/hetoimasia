#!/usr/bin/env python3
"""The registry transport the CI image builder decides with.

``builder.py`` owns every decision; this answers its four questions against the
real GitHub Container Registry and the Docker CLI. See ``builder.py`` for the
protocol. A lookup authenticates with ``REGISTRY_USER`` and ``REGISTRY_TOKEN``
when both are set, and anonymously otherwise.

Exit status: ``0`` on success, ``3`` when a lookup is answered with a confirmed
absence, and ``2`` for anything else — including every registry response that is
not a plain answer, because a registry error is never a miss.
"""

from __future__ import annotations

import base64
import importlib.util
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

sys.dont_write_bytecode = True

ABSENT = 3
ABSENT_CODES = ("MANIFEST_UNKNOWN", "NAME_UNKNOWN")
MANIFEST_TYPES = (
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
)
INDEX_TYPES = MANIFEST_TYPES[:2]
PLATFORM = "linux/amd64"
IMAGE_ROOT = "/opt/hetoimasia"

REPOSITORY_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def load_contract():
    path = os.path.join(REPOSITORY_ROOT, "tools", "validation", "ci_image.py")
    specification = importlib.util.spec_from_file_location("ci_image", path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


class TransportError(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, url):
        return None


OPENER = urllib.request.build_opener(NoRedirect)


def request(url: str, headers: dict[str, str]) -> tuple[int, dict, bytes]:
    """One GET, following a redirect without forwarding credentials.

    Blob downloads redirect to object storage, which refuses a request carrying
    the registry's bearer token beside its own signature.
    """
    for _ in range(5):
        try:
            with OPENER.open(urllib.request.Request(url, headers=headers), timeout=60) as response:
                return response.status, dict(response.headers), response.read()
        except urllib.error.HTTPError as error:
            if error.code in (301, 302, 303, 307, 308) and error.headers.get("Location"):
                url = urllib.parse.urljoin(url, error.headers["Location"])
                headers = {name: value for name, value in headers.items() if name.lower() != "authorization"}
                continue
            return error.code, dict(error.headers), error.read()
        except OSError as error:
            raise TransportError(f"GET {url} did not answer: {error}") from error
    raise TransportError(f"GET {url} redirected too many times")


def split_reference(reference: str) -> tuple[str, str, str]:
    registry, _, rest = reference.partition("/")
    repository, separator, tag = rest.rpartition(":")
    if not registry or not separator or not repository or not tag or "@" in rest:
        raise TransportError(f"{reference!r} is not REGISTRY/REPOSITORY:TAG")
    return registry, repository, tag


def bearer(registry: str, repository: str) -> str:
    url = f"https://{registry}/token?service={registry}&scope=repository:{repository}:pull"
    headers = {}
    user, token = os.environ.get("REGISTRY_USER"), os.environ.get("REGISTRY_TOKEN")
    if user and token:
        headers["Authorization"] = "Basic " + base64.b64encode(f"{user}:{token}".encode()).decode()
    status, _, body = request(url, headers)
    if status != 200:
        raise TransportError(f"the token endpoint answered {status}: {body[:200]!r}")
    document = json.loads(body)
    value = document.get("token") or document.get("access_token")
    if not value:
        raise TransportError("the token endpoint returned no token")
    return value


def error_codes(body: bytes) -> list[str]:
    try:
        errors = json.loads(body).get("errors") or []
    except (ValueError, AttributeError):
        return []
    return [entry.get("code") for entry in errors if isinstance(entry, dict)]


def lookup(reference: str) -> int:
    registry, repository, tag = split_reference(reference)
    authorization = {"Authorization": "Bearer " + bearer(registry, repository)}
    base = f"https://{registry}/v2/{repository}"
    status, headers, body = request(f"{base}/manifests/{tag}", {**authorization, "Accept": ", ".join(MANIFEST_TYPES)})
    if status == 404:
        codes = error_codes(body)
        if codes and all(code in ABSENT_CODES for code in codes):
            return ABSENT
        raise TransportError(f"the manifest request answered 404 without a confirmed absence: {body[:300]!r}")
    if status != 200:
        raise TransportError(f"the manifest request answered {status}: {body[:300]!r}")
    lowered = {name.lower(): value for name, value in headers.items()}
    digest = lowered.get("docker-content-digest")
    if not digest:
        raise TransportError("the manifest response names no Docker-Content-Digest")
    manifest = json.loads(body)
    if manifest.get("mediaType") in INDEX_TYPES or "manifests" in manifest:
        chosen = [
            entry
            for entry in manifest.get("manifests", [])
            if f"{entry.get('platform', {}).get('os')}/{entry.get('platform', {}).get('architecture')}" == PLATFORM
        ]
        if len(chosen) != 1:
            raise TransportError(f"the image index does not name exactly one {PLATFORM} manifest")
        status, _, body = request(f"{base}/manifests/{chosen[0]['digest']}", {**authorization, "Accept": ", ".join(MANIFEST_TYPES)})
        if status != 200:
            raise TransportError(f"the platform manifest request answered {status}")
        manifest = json.loads(body)
    config = manifest.get("config", {}).get("digest")
    if not config:
        raise TransportError("the manifest names no config blob")
    status, _, body = request(f"{base}/blobs/{config}", authorization)
    if status != 200:
        raise TransportError(f"the config blob request answered {status}")
    labels = (json.loads(body).get("config") or {}).get("Labels") or {}
    print(json.dumps({"digest": digest, "labels": labels}, sort_keys=True))
    return 0


def docker(*arguments: str, capture: bool = False) -> str:
    process = subprocess.run(["docker", *arguments], capture_output=capture, check=False)
    if process.returncode != 0:
        detail = process.stderr.decode("utf-8", errors="replace").strip() if capture else ""
        raise TransportError(f"docker {arguments[0]} exited {process.returncode}{': ' + detail if detail else ''}")
    return process.stdout.decode("utf-8", errors="replace") if capture else ""


def build(context: str, local: str, fingerprint: str) -> int:
    contract = load_contract()
    arguments = [
        "build",
        "--platform", PLATFORM,
        "--build-arg", f"RECIPE_FINGERPRINT={fingerprint}",
        "--file", os.path.join(context, "tools", "ci-image", "Dockerfile"),
        "--tag", local,
    ]
    docker(*arguments, context)
    embedded = json.loads(docker("run", "--rm", "--platform", PLATFORM, local, "cat", f"{IMAGE_ROOT}/image.json", capture=True))
    labels = {
        contract.LABELS["recipe_fingerprint"]: fingerprint,
        contract.LABELS["native_manifest"]: embedded["native_manifest"],
        contract.LABELS["ghc"]: embedded["ghc"],
        contract.LABELS["cabal"]: embedded["cabal"],
    }
    # The manifest hash exists only once the image does, so the labels are
    # applied by a second build that every layer of the first satisfies.
    labelled = list(arguments)
    for name, value in sorted(labels.items()):
        labelled += ["--label", f"{name}={value}"]
    docker(*labelled, context)
    print(json.dumps({"native_manifest": embedded["native_manifest"]}))
    return 0


VALIDATION_SCRIPT = f"""
set -euo pipefail
python3 {IMAGE_ROOT}/recipe/tools/native/native.py check --prefix "$HETOIMASIA_NATIVE_PREFIX" >&2
python3 {IMAGE_ROOT}/recipe/tools/native/native.py link-check --prefix "$HETOIMASIA_NATIVE_PREFIX" >&2
echo "ghc=$(ghc --numeric-version)"
echo "cabal=$(cabal --numeric-version)"
echo "store=$(cabal path --store-dir)"
echo "cabal_dir=$CABAL_DIR"
echo "manifest=$(sha256sum "$HETOIMASIA_NATIVE_PREFIX/hetoimasia-native-manifest.json" | cut -d' ' -f1)"
echo "embedded=$(python3 -c 'import json; print(json.load(open("{IMAGE_ROOT}/image.json"))["recipe_fingerprint"])')"
test ! -e {IMAGE_ROOT}/descriptor.json
"""


def validate(local: str, fingerprint: str, native_manifest: str, ghc: str, cabal: str) -> int:
    contract = load_contract()
    output = docker("run", "--rm", "--platform", PLATFORM, local, "bash", "-c", VALIDATION_SCRIPT, capture=True)
    values = dict(line.split("=", 1) for line in output.splitlines() if "=" in line)
    expected = {
        "ghc": ghc,
        "cabal": cabal,
        "store": f"{IMAGE_ROOT}/cabal/store",
        "cabal_dir": f"{IMAGE_ROOT}/cabal",
        "manifest": native_manifest,
        "embedded": fingerprint,
    }
    problems = [f"{name} is {values.get(name)!r}, expected {value!r}" for name, value in expected.items() if values.get(name) != value]
    labels = json.loads(docker("image", "inspect", "--format", "{{json .Config.Labels}}", local, capture=True)) or {}
    for name, value in (
        ("recipe_fingerprint", fingerprint),
        ("native_manifest", native_manifest),
        ("ghc", ghc),
        ("cabal", cabal),
    ):
        if labels.get(contract.LABELS[name]) != value:
            problems.append(f"label {contract.LABELS[name]} is {labels.get(contract.LABELS[name])!r}, expected {value!r}")
    if problems:
        raise TransportError("the candidate image is not the recipe's: " + "; ".join(problems))
    print(json.dumps(values, sort_keys=True))
    return 0


def push(local: str, reference: str) -> int:
    docker("tag", local, reference)
    docker("push", reference)
    return 0


def main(argv: list[str]) -> int:
    if not argv:
        raise TransportError("usage: registry.py lookup|build|validate|push ...")
    command, arguments = argv[0], argv[1:]
    handlers = {"lookup": (lookup, 1), "build": (build, 3), "validate": (validate, 5), "push": (push, 2)}
    if command not in handlers or len(arguments) != handlers[command][1]:
        raise TransportError(f"unknown or malformed registry request: {' '.join(argv)}")
    return handlers[command][0](*arguments)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (TransportError, ValueError, KeyError) as failure:
        print(f"error: {failure}", file=sys.stderr)
        sys.exit(2)
