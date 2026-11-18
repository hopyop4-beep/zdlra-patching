#!/usr/bin/env bash
#
# zdlra_detached.sh - run a command that must never be cut short, and report on it.
#
# Copied to each compute node by the zdlra_patch role. patchmgr, the racli upgrade steps
# and Oracle's precheck run through it: in a session of their own (setsid, nohup, no
# terminal), with their output written straight to a log file. Nothing that happens to
# Ansible, the controller or an ssh session can reach the command. Ansible only starts
# it and polls it. There is no time limit.
#
# Files, for a log path LOG and a pid file PIDF:
#   LOG       the command's output
#   LOG.rc    its exit status, written when it ends (97 = could not enter the folder)
#   PIDF      the pid of the wrapper that runs it
#
# Usage:
#   zdlra_detached.sh state LOG PIDF
#       prints one of: running <pid> | pending <rc> | none
#       ("pending": it finished, and nobody has collected its result yet)
#   zdlra_detached.sh start [--fresh] LOG PIDF DIR -- COMMAND [ARGS...]
#       prints: STARTED <pid> | RUNNING <pid> | PENDING <rc>
#       If it is already running, it is not started again (RUNNING). If an earlier
#       attempt left a result, that is used and it is not run again (PENDING), unless
#       --fresh is given.
#   zdlra_detached.sh poll LOG PIDF [ALIVE_ERE]
#       prints: STATE=<running|done|gone> RC=<rc> LINES=<n> ELAPSED=<seconds>
#       "gone": no exit status, and neither the wrapper nor any process whose command
#       line matches ALIVE_ERE is running (it was killed, or the node rebooted).
#   zdlra_detached.sh collect LOG
#       marks the result as used (LOG.rc -> LOG.rc.collected), so the next start runs it
#   zdlra_detached.sh running [PRECHECK_NAME]
#       prints "pid <pid> (<args>)" of any patchmgr run, racli upgrade step or Oracle
#       precheck running on this node, and exits 0; exits 1 if there is none

set -uo pipefail

alive() { [[ -n "$1" ]] && kill -0 "$1" 2>/dev/null; }
pid_of() { tr -dc '0-9' < "$1" 2>/dev/null; }

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
        echo "RUNNING $pid"
        return 0
    fi
    if (( ! fresh )) && [[ -s "$rcfile" ]]; then
        echo "PENDING $(pid_of "$rcfile")"
        return 0
    fi
    mkdir -p "$(dirname "$log")" "$(dirname "$pidf")" || { echo "ERROR cannot create the log folder"; exit 1; }
    rm -f -- "$rcfile" "$pidf"
    # Keep the log of an earlier attempt: it may be the only record of what happened.
    [[ ! -s "$log" ]] || mv -f -- "$log" "${log}.$(date +%Y%m%d_%H%M%S)"
    : > "$log"
    local launcher=(nohup)
    command -v setsid >/dev/null 2>&1 && launcher=(setsid nohup)
    # The inner bash records its pid, runs the command, then writes the exit status.
    "${launcher[@]}" bash -c 'echo $$ > "$1"; cd "$2" || { echo 97 > "$0"; exit 97; }; shift 3; "$@"; echo $? > "$0"' \
        "$rcfile" "$pidf" "$dir" _ "$@" >> "$log" 2>&1 < /dev/null &
    local p=$!
    # However slow the start, wait for its own record of its pid while it is alive.
    while [[ ! -s "$pidf" && ! -s "$rcfile" ]] && kill -0 "$p" 2>/dev/null; do sleep 1; done
    if [[ -s "$pidf" ]]; then
        echo "STARTED $(pid_of "$pidf")"
    elif [[ -s "$rcfile" ]]; then
        echo "STARTED $p"
    else
        echo "ERROR the command did not start; see $log"
        exit 1
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
    running) cmd_running "$@" ;;
    *)       echo "usage: $0 state|start|poll|collect|running ..." >&2; exit 2 ;;
esac
