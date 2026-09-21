#!/usr/bin/env bash
# Run one command inside an isolated headless Wayland session: a private Weston
# compositor on a socket of its own, started for that command alone and stopped
# after it.
#
# The isolation is deliberate and complete, so that what the command reaches is
# this compositor and nothing the machine happens to be running. A private
# XDG_RUNTIME_DIR is created for the run and holds the only socket; the headless
# backend is named explicitly and no configuration file is read, so neither a
# personal weston.ini nor an ambient variable can select another backend or turn
# XWayland on; and WAYLAND_DISPLAY, WAYLAND_SOCKET and DISPLAY are all removed
# before the compositor starts. DISPLAY and WAYLAND_SOCKET stay removed for the
# command too: the session it can reach is the one this script named.
#
# Readiness is a connection, not a wait. A socket file appears before the
# compositor serves it, so the helper connects to the socket it named with
# wayland-info, bounded, until that succeeds. A missing compositor, one that
# exits, and one that never serves the socket within the bound each end the run
# before the command starts.
#
# The native suite enters no session without consent. Once the compositor
# serves, and only then, the command runs with HETOIMASIA_NATIVE_SESSION set to
# isolated-wayland:SOCKET. The suite accepts that value on Linux, and only when
# WAYLAND_DISPLAY names exactly this socket and DISPLAY is unset, which is why
# both are established before the command starts; under it the shared session
# requests Wayland by name. This never stands in for the human's
# HETOIMASIA_NATIVE_SESSION=desktop on a real desktop, which no script
# supplies.
#
#   tools/display/wayland.sh [--summary FILE] -- COMMAND [ARGUMENT...]
#
# Exit status: the command's own once it ran; 1 when the compositor could not be
# established, with the command never started; 2 for a usage error; 128+N when
# the helper itself was terminated by signal N. The compositor is stopped and
# the private runtime directory removed on every exit path the helper can
# handle, from before that directory exists: cleanup and the signal traps are
# installed first, so the setup window in which the directory is there and the
# compositor is not is covered like any other. See docs/validation.md.
set -uo pipefail

usage() {
  echo "wayland.sh: usage: wayland.sh [--summary FILE] -- COMMAND [ARGUMENT...]" >&2
  exit 2
}

summary=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --summary)
      [ "$#" -ge 2 ] || usage
      summary="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *) usage ;;
  esac
done
[ "$#" -gt 0 ] || usage

refuse() {
  echo "wayland.sh: $1; the isolated Wayland session is unavailable, so the command did not run" >&2
  exit 1
}

for tool in weston wayland-info; do
  command -v "$tool" >/dev/null 2>&1 || refuse "$tool was not found on PATH"
done

# Nothing is created until cleanup owns it. Every one of these is declared and
# the traps installed before the first directory exists, so a signal or a
# failure during setup — the window in which the runtime directory exists and
# the compositor does not — still ends through the same cleanup.
scratch=""
socket=""
compositor=""
command_pid=""

# Whether a background process this script started is still running. The job
# table is asked rather than `kill -0`, which still answers for a child that
# has exited but not yet been reaped.
alive() {
  local job
  for job in $(jobs -pr); do
    [ "$job" = "$1" ] && return 0
  done
  return 1
}

stop() {
  if [ -n "$compositor" ]; then
    kill "$compositor" 2>/dev/null
    wait "$compositor" 2>/dev/null
  fi
  if [ -n "$scratch" ]; then
    rm -rf "$scratch"
  fi
}
trap stop EXIT

# A signal the helper can catch ends it through the same cleanup as any other
# exit: the command it started is stopped first, then the EXIT trap stops the
# compositor and removes the runtime directory. Waiting on the command rather
# than running it in the foreground is what lets a signal be handled while it
# runs instead of after it.
terminate() {
  trap - TERM INT HUP
  if [ -n "$command_pid" ]; then
    kill "$command_pid" 2>/dev/null
    wait "$command_pid" 2>/dev/null
  fi
  echo "wayland.sh: terminated by SIG$1; the compositor is stopped and its runtime directory removed" >&2
  exit "$2"
}
trap 'terminate TERM 143' TERM
trap 'terminate INT 130' INT
trap 'terminate HUP 129' HUP

scratch="$(mktemp -d "${TMPDIR:-/tmp}/hetoimasia-wayland.XXXXXX")" || refuse "no scratch directory could be created"
runtime="$scratch/runtime"
# A Wayland runtime directory is the user's alone; the compositor refuses one
# any other account can reach.
mkdir -m 700 "$runtime" || refuse "no private runtime directory could be created"
socket="hetoimasia-$$"

unset WAYLAND_DISPLAY
unset WAYLAND_SOCKET
unset DISPLAY
unset WESTON_CONFIG_FILE
export XDG_SESSION_TYPE=wayland
export XDG_RUNTIME_DIR="$runtime"
# Nothing under a personal configuration root is read; --no-config already
# refuses weston.ini, and this leaves no other root for a module to find one in.
export XDG_CONFIG_HOME="$scratch/config"
mkdir -p "$XDG_CONFIG_HOME"

version="$(weston --version 2>/dev/null | head -n 1)"

# The backend is named, the configuration file is refused, and no XWayland is
# requested, so this session is headless whatever the machine is configured for.
weston \
  --backend=headless \
  --socket="$socket" \
  --width=1280 \
  --height=1024 \
  --no-config \
  --idle-time=0 \
  >"$scratch/compositor.log" 2>&1 &
compositor=$!

# One bounded connection attempt to the socket this script named. A file in the
# runtime directory is not the assertion: wayland-info connects, reads the
# registry, and exits, so a success is a served socket.
probe() {
  local prober
  WAYLAND_DISPLAY="$socket" wayland-info >"$scratch/registry.txt" 2>&1 &
  prober=$!
  while [ "$budget" -gt 0 ]; do
    if ! alive "$prober"; then
      wait "$prober"
      return "$?"
    fi
    budget=$((budget - 1))
    sleep 0.1
  done
  kill "$prober" 2>/dev/null
  wait "$prober" 2>/dev/null
  return 1
}

# Ten seconds of ticks, shared by the attempts and the waits between them, so a
# compositor that hangs mid-connection cannot outlast the bound either.
budget=100
ready=""
while [ "$budget" -gt 0 ]; do
  if ! alive "$compositor"; then
    refuse "the compositor exited before serving $socket: $(tail -n 5 "$scratch/compositor.log" | tr '\n' ' ')"
  fi
  if probe; then
    ready="yes"
    break
  fi
  budget=$((budget - 1))
  sleep 0.1
done
if [ -z "$ready" ]; then
  if ! alive "$compositor"; then
    refuse "the compositor exited before serving $socket: $(tail -n 5 "$scratch/compositor.log" | tr '\n' ' ')"
  fi
  refuse "the compositor did not serve $socket within 10 seconds: $(tail -n 5 "$scratch/compositor.log" | tr '\n' ' ')"
fi

report="compositor ${version:-weston of unknown version} on socket $socket in runtime directory $runtime, DISPLAY and WAYLAND_SOCKET unset"
echo "wayland.sh: $report"
if [ -n "$summary" ]; then
  printf '## Isolated headless Wayland session\n\n%s.\n\n' "$report" >>"$summary"
fi

# The compositor serves; the command, and only the command, may enter a native
# session on it.
export WAYLAND_DISPLAY="$socket"
export HETOIMASIA_NATIVE_SESSION="isolated-wayland:$socket"
"$@" &
command_pid=$!
wait "$command_pid"
exit "$?"
