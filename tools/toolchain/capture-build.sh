#!/usr/bin/env bash
# Run one build command on the qualified toolchain and write a record of what
# was actually executed: the command, the compiler and build tool that ran it,
# the revision and tree it ran against, and the result.
#
# This exists because the validation catalog has no group for
# `cabal build all --project-file cabal.project.cpu`. `build.all` runs the
# ordinary project, so a passing receipt from it says nothing about the CPU-only
# configuration, and the issue requires evidence for both. Rather than assert
# the second one in prose, run it and keep the record.
#
#   bash tools/toolchain/capture-build.sh docs/toolchain/cpu-project-darwin.txt \
#     cabal build all --project-file cabal.project.cpu
#
# See docs/toolchain.md.
set -euo pipefail

destination="${1:?usage: capture-build.sh DESTINATION COMMAND...}"
shift
if [ "$#" -eq 0 ]; then
  echo "capture-build: no command to run" >&2
  exit 2
fi

root="$(cd "$(dirname "$0")/../.." && pwd)"

set -a
# shellcheck disable=SC1091
. "$root/tools/ci-image/toolchain.pin"
set +a

# The same refusal the binding qualification makes: a record produced on some
# other compiler describes something this repository has not pinned.
actual_ghc="$(ghc --numeric-version)"
actual_cabal="$(cabal --numeric-version)"
if [ "$actual_ghc" != "$GHC_VERSION" ] || [ "$actual_cabal" != "$CABAL_VERSION" ]; then
  echo "capture-build: ghc/cabal on PATH are $actual_ghc/$actual_cabal, but this repository pins $GHC_VERSION/$CABAL_VERSION" >&2
  exit 2
fi

revision="$(git -C "$root" rev-parse HEAD)"
tree="$(git -C "$root" rev-parse 'HEAD^{tree}')"
dirty=no
if ! git -C "$root" diff --quiet HEAD; then
  dirty=yes
fi

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

started="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
status=0
(cd "$root" && "$@") > "$log" 2>&1 || status=$?
ended="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

mkdir -p "$(dirname "$destination")"
{
  echo "command=$*"
  echo "ghc=$actual_ghc"
  echo "cabal=$actual_cabal"
  echo "platform=$(uname -s | tr '[:upper:]' '[:lower:]')/$(uname -m)"
  echo "executed-revision=$revision"
  echo "executed-tree=$tree"
  echo "uncommitted-changes=$dirty"
  echo "started-at=$started"
  echo "ended-at=$ended"
  echo "exit-status=$status"
  # The whole point is the warning policy, so the output is kept rather than
  # summarised: "warning-clean" is only believable beside what was printed.
  echo "output-lines=$(wc -l < "$log" | tr -d ' ')"
  echo "---"
  cat "$log"
} > "$destination"

if [ "$status" -ne 0 ]; then
  echo "capture-build: the command failed (exit $status); the record is at $destination" >&2
  exit "$status"
fi

echo "capture-build: recorded $* at $destination"
