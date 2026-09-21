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
# Server startup has three outcomes, and each refusal names the one it was:
# the server exited before reporting a display, its startup report was closed
# or invalid without naming one, or the thirty-second bound expired with the
# report still outstanding. Each is observed on its own channel, so a server
# that exits never reports a timeout and a server that stays alive never
# reports an exit. An unusable report is settled at the bound, because a
# server on its way out has until then to be reaped and named as the exit it
# is.
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

# Nothing is created until cleanup owns it. Every one of these is declared and
# both traps installed before the scratch directory exists, so a signal during
# setup — the window in which the server is starting and nothing has reported
# yet — still ends through the same cleanup.
scratch=""
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

# Stop everything this script started, and wait for it to be gone before the
# scratch directory goes. What to signal is taken from the job table rather
# than from a recorded process id: a job it still lists as running has not been
# reaped, so that number is still that process's own, while a number read back
# from a variable or a file may by then name a process this script never
# started. Nothing here decides an outcome; the startup observations below do
# that, on their own channels.
stop() {
  local job
  for job in $(jobs -pr); do
    kill "$job" 2>/dev/null
  done
  wait
  if [ -n "$scratch" ]; then
    rm -rf "$scratch"
  fi
} 2>/dev/null
trap stop EXIT

# A signal the helper can catch ends it through that same cleanup rather than
# ending it where it stands. Without this, a signal arriving while the helper
# waits for the server's startup report leaves the server running and the
# scratch directory behind, because the wait is what the shell dies in.
terminate() {
  trap - TERM INT HUP
  echo "x11.sh: terminated by SIG$1; the X server is stopped and its scratch directory removed" >&2
  exit "$2"
}
trap 'terminate TERM 143' TERM
trap 'terminate INT 130' INT
trap 'terminate HUP 129' HUP

scratch="$(mktemp -d "${TMPDIR:-/tmp}/hetoimasia-x11.XXXXXX")" || refuse "no scratch directory could be created"

unset WAYLAND_DISPLAY
export XDG_SESSION_TYPE=x11

# The server picks a free display number and writes it to the descriptor once
# it accepts connections, so readiness is its own report rather than a guess.
#
# Three observations tell the startup outcomes apart, and each is made on its
# own channel rather than by questioning a variable that came back empty:
#
#   * the report channel's own result — a complete line, or the channel
#     closing without one;
#   * the server's termination. Reaping it is the observation, so nothing is
#     signalled to make it, nothing is inferred from an exit status a server
#     chose for itself, and the job table — which notices an exit at its own
#     pace, and is what once let an immediate exit be called a timeout — is
#     never asked;
#   * the thirty-second bound, read from an outcome channel this script holds
#     a write end of. That channel therefore never reaches end-of-file, so a
#     failed read on it can only be the bound expiring; `read`'s own status
#     does not separate the two on every supported shell, returning 1 for both
#     under Bash 3.2.
#
# One process makes the first two, in that order: it starts the server, reads
# the report channel to its end, and only then waits for the server. Two
# processes reporting independently could not order what they saw — a server
# that writes a display number and exits at once would have its completed
# report overtaken by its own exit whenever the exit was noticed first, and be
# refused for never reporting. Reading first is also what orders them
# correctly: a report cannot still arrive on a channel that has closed, and
# until it closes an exit is not yet the whole story.
mkfifo "$scratch/displayfd" || refuse "no display-number channel could be created"
mkfifo "$scratch/startup" || refuse "no startup-outcome channel could be created"
exec 8<>"$scratch/startup" || refuse "no startup-outcome channel could be opened"
# The server writes to its own log, so this process's standard error would
# carry nothing but the notices a shell prints for a background process it
# stopped — its own doing rather than anything the caller asked to hear.
{
  # A request to stop arrives as a signal, because this process spends its
  # life reading the report channel and then waiting for the server. The
  # handler stops the server, waits for it to be gone, and ends this process
  # itself. Recording the request instead would strand it: for as long as the
  # report is outstanding — which is the whole of the helper's bound — this
  # process is not in the wait such a record was meant to be noticed after, and
  # the read it is in can be held open by anything that inherited the channel.
  # What it stops is what the job table still lists as running, so it never
  # signals a process id that has been reaped and handed to somebody else, and
  # what it waits for is what it started, so a descendant that outlives them
  # cannot hold cleanup up.
  #
  # Ending here rather than carrying on is also what keeps a stopped server out
  # of the outcomes: every line below is written by a process that was not
  # asked to stop, so no outcome can be the helper's own signalling coming back
  # to it. The trap is armed before the server exists, so a request that
  # arrives first finds nothing to stop and starts nothing.
  halt() {
    local job
    for job in $(jobs -pr); do
      kill "$job" 2>/dev/null
    done
  }
  settle() {
    while :; do
      wait
      [ "$?" -gt 128 ] || break
      halt
    done
  }
  trap 'halt; settle; exit' TERM
  Xvfb -displayfd 3 -screen 0 1280x1024x24 -nolisten tcp >"$scratch/server.log" 2>&1 3>"$scratch/displayfd" 8>&- &
  # Read without an `IFS=` prefix, for the reason the bounded read below gives.
  if read -r reported <"$scratch/displayfd"; then
    printf 'report %s\n' "$reported"
  else
    printf 'closed\n'
  fi
  settle
  # The server was reaped, and that is the whole report.
  printf 'exited\n'
} >&8 2>/dev/null &

# The report is usable until the channel says otherwise. An unusable report is
# not yet a refusal: the server may be on its way out, and an exit it made for
# itself is the more specific answer, so the bound is what settles which of the
# two this was.
number=""
usable="yes"
started=$SECONDS
while :; do
  remaining=$((30 - (SECONDS - started)))
  outcome="bound"
  if [ "$remaining" -gt 0 ]; then
    # Read without an `IFS=` prefix. An assignment prefixed to `read` is
    # restored when the read returns, but a signal arriving while it waits can
    # leave the empty value behind under Bash 5.3, and cleanup splits the job
    # table on whitespace. The outcomes below are single words or a word and a
    # number, so the surrounding whitespace this strips is nothing they carry.
    read -r -t "$remaining" outcome <&8 || outcome="bound"
  fi
  case "$outcome" in
    'exited')
      refuse "the X server exited before reporting a display: $(tail -n 5 "$scratch/server.log" | tr '\n' ' ')"
      ;;
    'report '*)
      number="${outcome#report }"
      case "$number" in
        '' | *[!0-9]*) usable="no" ;;
        *) break ;;
      esac
      ;;
    'closed')
      usable="no"
      ;;
    *)
      if [ "$usable" = "no" ]; then
        refuse "the X server's startup report was closed or invalid before it named a display: $(tail -n 5 "$scratch/server.log" | tr '\n' ' ')"
      fi
      refuse "the X server reported no display within 30 seconds"
      ;;
  esac
done
# The report arrived on a channel that has now closed, so nothing more is
# coming and nothing is left to carry into the command's own environment. A
# later exit has nowhere to go and nobody it could mislead.
exec 8<&-
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
