#!/usr/bin/env bash
# Run one command inside an isolated X11 display: a private Xvfb server with a
# window manager on it, started for that command alone and stopped after it.
#
# This is the native worker's display setup and no other worker's. It never
# selects a dummy or null platform and never leaves a Wayland session for GLFW
# to reach: WAYLAND_DISPLAY is removed, XDG_SESSION_TYPE is x11, and DISPLAY
# names the server this script started. A server or window manager that is
# missing, exits, or never becomes ready ends the run before the command
# starts, so a requested native group is blocked rather than passed, retried,
# or skipped.
#
# The native suite enters no session without consent. Once the display is up,
# and only then, the command runs with HETOIMASIA_NATIVE_SESSION set to
# isolated-x11:DISPLAY, the authorization the suite accepts for that isolated
# display alone: the child chain (the validation runner, cabal, the suite, and
# its private-session children) inherits it, nothing else does, and a run that
# never establishes the display gives it to nothing. This never stands in for
# the human's HETOIMASIA_NATIVE_SESSION=desktop on a real desktop, which no
# script supplies.
#
#   tools/display/x11.sh [--summary FILE] -- COMMAND [ARGUMENT...]
#
# Exit status: the command's own once it ran; 1 when the display could not be
# established, with the command never started; 2 for a usage error. See
# docs/validation.md.
set -uo pipefail

usage() {
  echo "x11.sh: usage: x11.sh [--summary FILE] -- COMMAND [ARGUMENT...]" >&2
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
  echo "x11.sh: $1; the isolated X11 display is unavailable, so the command did not run" >&2
  exit 1
}

for tool in Xvfb openbox xdpyinfo xprop; do
  command -v "$tool" >/dev/null 2>&1 || refuse "$tool was not found on PATH"
done

scratch="$(mktemp -d "${TMPDIR:-/tmp}/hetoimasia-x11.XXXXXX")" || refuse "no scratch directory could be created"
server=""
manager=""

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
  if [ -n "$manager" ]; then
    kill "$manager" 2>/dev/null
    wait "$manager" 2>/dev/null
  fi
  if [ -n "$server" ]; then
    kill "$server" 2>/dev/null
    wait "$server" 2>/dev/null
  fi
  rm -rf "$scratch"
}
trap stop EXIT

unset WAYLAND_DISPLAY
export XDG_SESSION_TYPE=x11

# The server picks a free display number and writes it to the descriptor once
# it accepts connections, so readiness is its own report rather than a guess.
mkfifo "$scratch/displayfd" || refuse "no display-number channel could be created"
Xvfb -displayfd 3 -screen 0 1280x1024x24 -nolisten tcp >"$scratch/server.log" 2>&1 3>"$scratch/displayfd" &
server=$!
number=""
read -r -t 30 number <"$scratch/displayfd"
case "$number" in
  '' | *[!0-9]*)
    if ! alive "$server"; then
      refuse "the X server exited before reporting a display: $(tail -n 5 "$scratch/server.log" | tr '\n' ' ')"
    fi
    refuse "the X server reported no display within 30 seconds"
    ;;
esac
export DISPLAY=":$number"

xdpyinfo >"$scratch/server.txt" 2>&1 || refuse "the X server on $DISPLAY does not answer: $(tail -n 5 "$scratch/server.txt" | tr '\n' ' ')"
vendor="$(sed -n 's/^vendor string: *//p' "$scratch/server.txt")"

openbox --sm-disable >"$scratch/manager.log" 2>&1 &
manager=$!
# A window manager announces itself on the root window. This is setup
# readiness, bounded, and never a stand-in for any assertion the command makes.
ready=""
attempt=0
while [ "$attempt" -lt 100 ]; do
  if ! alive "$manager"; then
    refuse "the window manager exited before taking $DISPLAY: $(tail -n 5 "$scratch/manager.log" | tr '\n' ' ')"
  fi
  check="$(xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null)"
  case "$check" in
    *"window id # "*)
      ready="${check##*# }"
      break
      ;;
  esac
  attempt=$((attempt + 1))
  sleep 0.1
done
[ -n "$ready" ] || refuse "the window manager did not take $DISPLAY within 10 seconds"
name="$(xprop -id "$ready" _NET_WM_NAME 2>/dev/null | sed -n 's/^_NET_WM_NAME[^=]*= *//p')"

report="display $DISPLAY on X server ${vendor:-of unknown vendor}, window manager ${name:-unnamed} ($ready), WAYLAND_DISPLAY unset"
echo "x11.sh: $report"
if [ -n "$summary" ]; then
  printf '## Isolated X11 display\n\n%s.\n\n' "$report" >>"$summary"
fi

# The isolated display exists and is served; the command, and only the
# command, may enter a native session on it.
export HETOIMASIA_NATIVE_SESSION="isolated-x11:$DISPLAY"
"$@"
exit "$?"
