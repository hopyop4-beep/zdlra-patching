#!/usr/bin/env bash
#
# zdlra_detached.sh - run a command that must never be cut short, and report on it.
#
# Copied to each compute node by the zdlra_patch role. patchmgr, the racli upgrade steps
# and Oracle's precheck run through it, each in a detached screen session of its own, as
# Oracle recommends for patchmgr (and racli once hung under nohup when it wanted a
# terminal). The command has a terminal (the screen window), ignores Ctrl-C, Ctrl-\,
# Ctrl-Z and hangups, and writes straight to its log file: nothing that happens to
# Ansible, the controller, an ssh session or the screen session itself can stop it.
# Ansible only starts it and polls it. There is no time limit. The session's second
# window follows the log; "screen -r <session>" shows it. The session closes by itself
# when the command ends.
#
# Files, for a log path LOG and a pid file PIDF (e.g. <run dir>/detached.pid):
#   LOG       the command's output
#   LOG.rc    its exit status, written when it ends (97 = could not enter the folder)
#   PIDF      the pid of the wrapper that runs it
#   PIDF with .screen for .pid (e.g. detached.screen): the screen session's name
#
# ZDLRA_SCREEN in the environment names the screen program (default: screen), and
# ZDLRA_SESSION the start of the session name (default: zdlra_<log folder>_<log name>).
#
# Usage:
#   zdlra_detached.sh state LOG PIDF
#       prints one of: running <pid> | pending <rc> | none
#       ("pending": it finished, and nobody has collected its result yet)
#   zdlra_detached.sh start [--fresh] LOG PIDF DIR -- COMMAND [ARGS...]
#       prints: STARTED <pid> <session> | RUNNING <pid> <session> | PENDING <rc>
#       If it is already running, it is not started again (RUNNING). If an earlier
#       attempt left a result, that is used and it is not run again (PENDING), unless
#       --fresh is given. Without screen it starts nothing: ERROR, exit 1.
#   zdlra_detached.sh poll LOG PIDF [ALIVE_ERE]
#       prints: STATE=<running|done|gone> RC=<rc> LINES=<n> ELAPSED=<seconds>
#       "gone": no exit status, and neither the wrapper nor any process whose command
#       line matches ALIVE_ERE is running (it was killed, or the node rebooted).
#   zdlra_detached.sh settle PIDF
#       once the command has ended, waits up to 30 s for its screen session to close
#       (until then ps still shows its command line), then forgets the session.
#       Prints CLOSED, or OPEN <session> if it is still there.
#   zdlra_detached.sh screen_ok
#       exits 0 if screen is installed, else prints ERROR and exits 1
#   zdlra_detached.sh collect LOG
#       marks the result as used (LOG.rc -> LOG.rc.collected), so the next start runs it
#   zdlra_detached.sh running [PRECHECK_NAME]
#       prints "pid <pid> (<args>)" of any patchmgr run, racli upgrade step or Oracle
#       precheck running on this node, and exits 0; exits 1 if there is none

set -uo pipefail

alive() { [[ -n "$1" ]] && kill -0 "$1" 2>/dev/null; }
pid_of() { tr -dc '0-9' 2>/dev/null < "$1"; }

SCREEN="${ZDLRA_SCREEN:-screen}"
screen_file() { echo "${1%.pid}.screen"; }
# Does a screen session with exactly this name exist? $1 = name
screen_session_exists() { [[ -n "$1" ]] && "$SCREEN" -ls 2>/dev/null | grep -q "[0-9]\.${1}[[:space:]]"; }
cmd_screen_ok() {
    command -v "$SCREEN" >/dev/null 2>&1 \
        || { echo "ERROR screen not found on $(hostname) ($SCREEN): the precheck, racli and patchmgr run only in a screen session"; exit 1; }
}

# What a session's first window runs: ignore Ctrl-C, Ctrl-\, Ctrl-Z and hangups (the
# command inherits that), record its pid, run the command with its output going straight
# to the log, record the exit status, then close the session.
# $0 = .rc file, $1 = pid file, $2 = folder, $3 = log, rest = the command.
# shellcheck disable=SC2016
WRAPPER='trap "" INT QUIT TSTP HUP; echo $$ > "$1"; cd "$2" || { echo 97 > "$0"; exit 97; }; l=$3; shift 3; "$@" >> "$l" 2>&1; echo $? > "$0"; "$ZDLRA_SCREEN" -S "$STY" -X quit >/dev/null 2>&1'

cmd_state() {
    local log="$1" pidf="$2" pid
    pid="$(pid_of "$pidf")"
    if [[ -s "${log}.rc" ]]; then
        echo "pending $(pid_of "${log}.rc")"
    elif alive "$pid"; then
        echo "running $pid"
    else
        echo "none"
    fi
}

cmd_start() {
    local fresh=0
    if [[ "${1:-}" == --fresh ]]; then fresh=1; shift; fi
    local log="$1" pidf="$2" dir="$3"
    shift 3
    [[ "${1:-}" == -- ]] && shift
    (( $# )) || { echo "ERROR no command given"; exit 2; }
    local rcfile="${log}.rc" pid
    pid="$(pid_of "$pidf")"
    if [[ ! -s "$rcfile" ]] && alive "$pid"; then
        echo "RUNNING $pid $(cat "$(screen_file "$pidf")" 2>/dev/null)"
        return 0
    fi
    if (( ! fresh )) && [[ -s "$rcfile" ]]; then
        echo "PENDING $(pid_of "$rcfile")"
        return 0
    fi
    cmd_screen_ok
    mkdir -p "$(dirname "$log")" "$(dirname "$pidf")" || { echo "ERROR cannot create the log folder"; exit 1; }
    rm -f -- "$rcfile" "$pidf"
    # Keep the log of an earlier attempt: it may be the only record of what happened.
    [[ ! -s "$log" ]] || mv -f -- "$log" "${log}.$(date +%Y%m%d_%H%M%S)"
    : > "$log"
    # Named after the run and the log (ZDLRA_SESSION, or else the log's folder and name),
    # with the time, so no two attempts share a name.
    local session base run
    base="$(basename "$log" .log)"; run="$(basename "$(dirname "$log")")"
    session="$(tr -c 'A-Za-z0-9_\n-' '_' <<<"${ZDLRA_SESSION:-zdlra_${run}_${base}}")_$(date +%H%M%S)"
    echo "$session" > "$(screen_file "$pidf")"
    if ! ZDLRA_SCREEN="$SCREEN" "$SCREEN" -dmS "$session" bash -c "$WRAPPER" \
            "$rcfile" "$pidf" "$dir" "$log" "$@" < /dev/null >> "$log" 2>&1; then
        echo "ERROR could not start a screen session on $(hostname); see $log"
        exit 1
    fi
    # However slow the start, wait for its own record of its pid while the session is
    # there. A session that hasn't appeared after 10 seconds didn't start.
    local waited=0
    while [[ ! -s "$pidf" && ! -s "$rcfile" ]]; do
        if ! screen_session_exists "$session" && (( waited >= 10 )); then break; fi
        sleep 1; waited=$((waited + 1))
    done
    if [[ ! -s "$pidf" && ! -s "$rcfile" ]]; then
        echo "ERROR the command did not start in screen session $session; see $log"
        exit 1
    fi
    # The window "screen -r" shows: the log, so Ctrl-C there only stops tail.
    "$SCREEN" -S "$session" -X screen -t log tail -n +1 -F "$log" >/dev/null 2>&1 || true
    echo "STARTED $(pid_of "$pidf") $session"
}

cmd_settle() {
    local pidf="$1" sf session n=0
    sf="$(screen_file "$pidf")"
    session="$(cat "$sf" 2>/dev/null || true)"
    while screen_session_exists "$session" && (( n < 30 )); do sleep 1; n=$((n + 1)); done
    if screen_session_exists "$session"; then
        echo "OPEN $session"
    else
        rm -f -- "$sf"
        echo "CLOSED"
    fi
}

cmd_poll() {
    local log="$1" pidf="$2" alive_re="${3:-}" pid rc="" state lines elapsed=0 start
    pid="$(pid_of "$pidf")"
    if [[ -s "${log}.rc" ]]; then
        state=done; rc="$(pid_of "${log}.rc")"
    elif alive "$pid"; then
        state=running
    elif [[ -n "$alive_re" ]] && ps -eo args= 2>/dev/null | grep -Eq -- "$alive_re"; then
        state=running
    else
        # It may have finished between the two looks.
        sleep 2
        if [[ -s "${log}.rc" ]]; then state=done; rc="$(pid_of "${log}.rc")"; else state=gone; fi
    fi
    lines="$(wc -l < "$log" 2>/dev/null || echo 0)"
    start="$(stat -c %Y "$pidf" 2>/dev/null || true)"
    [[ -z "$start" ]] || elapsed=$(( $(date +%s) - start ))
    echo "STATE=$state RC=$rc LINES=$lines ELAPSED=$elapsed"
}

cmd_collect() { [[ ! -f "${1}.rc" ]] || mv -f -- "${1}.rc" "${1}.rc.collected"; }

# A patchmgr run, a racli upgrade step or the Oracle precheck ($1 = its file name),
# however it was started: by full path, through bash, or in the wrapper above.
cmd_running() {
    local pc="${1:-}" line
    line="$(ps -eo pid=,args= 2>/dev/null | awk -v pc="$pc" -v me="$$" '$1 != me {
        # A shell running a command string (sh -c "...") is not the command itself.
        if ($2 ~ /(^|\/)(ba|k|z|da)?sh$/ && $3 == "-c") next
        for (i = 2; i <= NF; i++) {
            if ($i ~ /(^|\/)patchmgr$/ && $0 ~ / (-cells|--roceswitches|-dbnodes) /) { print; exit }
            if ($i ~ /(^|\/)racli$/ && ($(i+1) " " $(i+2)) ~ /^(run preinstall|alter appliance|update appliance)/) { print; exit }
            if (pc != "" && substr($i, length($i) - length(pc)) == "/" pc) { print; exit }
        }
    }')"
    [[ -n "$line" ]] || return 1
    line="${line#"${line%%[![:space:]]*}"}"
    echo "pid ${line%% *} (${line#* })"
}

action="${1:-}"
shift || true
case "$action" in
    state)   cmd_state "$@" ;;
    start)   cmd_start "$@" ;;
    poll)    cmd_poll "$@" ;;
    collect) cmd_collect "$@" ;;
    settle)  cmd_settle "$@" ;;
    screen_ok) cmd_screen_ok ;;
    running) cmd_running "$@" ;;
    *)       echo "usage: $0 state|start|poll|settle|screen_ok|collect|running ..." >&2; exit 2 ;;
esac
