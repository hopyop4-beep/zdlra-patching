#!/usr/bin/env bash
#
# zdlra_patch_run.sh - patch a ZDLRA from the jump server (OMS)
#
# Runs zdlra_patch.sh on the appliance's compute node over ssh, and handles the OEM
# blackout around it:
#
#   1. preflight   ssh to the node, patch script present, emcli logged in, blackout settings
#   2. precheck    runs on the node in this terminal; you review it and type APPROVE
#   3. blackout    created after approval, before anything changes
#   4. patch       remaining phases start on the node in the background (they keep
#                  running if this terminal or the jump server connection drops)
#   5. watch       status is checked every POLL_SECONDS until the run ends
#   6. blackout    ended when the run completes; left in place when it fails
#
# Usage:
#   ./zdlra_patch_run.sh -z ZDLRA [-x] [-p "phase phase ..."]
#   ./zdlra_patch_run.sh -z ZDLRA --watch RUN_ID [-x]     resume watching a run
#
# Options:
#   -z, --zdlra NAME        appliance (required)
#   -x, --execute           real run: patch for real and create/end the blackout
#                           (default is dry run on the node and no blackout)
#   -p, --phases LIST       phases after precheck (default: all of them)
#   -w, --watch RUN_ID      skip to step 5 for a run that is already going
#       --keep-blackout     do not end the blackout when the run completes
#   -c, --config FILE       config file (default: zdlra_jump.conf next to this script)
#   -h, --help              show this help

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/zdlra_jump.conf"
INVENTORY="${SCRIPT_DIR}/../staging/appliances.conf"
ZDLRA=""
DRY_RUN=1
PHASES="snapshot stage patch1 patch2 postcheck report"
WATCH_RUN_ID=""
KEEP_BLACKOUT=0

SSH_USER="root"
REMOTE_SCRIPT="/root/zdlra-patching/zdlra_patch.sh"
REMOTE_CONFIG="/root/zdlra-patching/zdlra_patch.conf"
POLL_SECONDS=60
declare -A PATCH_NODE=()
declare -A BLACKOUT_TARGETS=()   # not used here; lets the shared config load
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30)

NODE=""
RUN_ID=""
BLACKOUT_ACTIVE=0

log()  { local lvl="$1"; shift; printf '%s [%-5s] %s\n' "$(date '+%F %T')" "$lvl" "$*" >&2; }
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
err()  { log ERROR "$@"; }
die()  { err "$@"; exit 1; }

usage() { awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"; }

parse_args() {
    while (( $# )); do
        case "$1" in
            -z|--zdlra)      ZDLRA="$2"; shift 2 ;;
            -x|--execute)    DRY_RUN=0; shift ;;
            -p|--phases)     PHASES="$2"; shift 2 ;;
            -w|--watch)      WATCH_RUN_ID="$2"; shift 2 ;;
            --keep-blackout) KEEP_BLACKOUT=1; shift ;;
            -c|--config)     CONFIG_FILE="$2"; shift 2 ;;
            -h|--help)       usage; exit 0 ;;
            *)               die "Unknown argument: $1 (see --help)" ;;
        esac
    done
    [[ -n "$ZDLRA" ]] || { usage; exit 1; }
    [[ "$ZDLRA" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "Bad appliance name: $ZDLRA"
    [[ "$PHASES" =~ ^[a-z0-9\ ]+$ ]] || die "Bad phase list: $PHASES"
    [[ " $PHASES " != *" precheck "* ]] || die "Leave precheck out of --phases; it always runs first."
    [[ -z "$WATCH_RUN_ID" || "$WATCH_RUN_ID" =~ ^[0-9_]+$ ]] || die "Bad run id: $WATCH_RUN_ID"
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE (copy zdlra_jump.conf.example)"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
}

# Node that runs the patch: PATCH_NODE in the config, else the first node in the
# staging inventory, else the appliance name.
pick_node() {
    NODE="${PATCH_NODE[$ZDLRA]:-}"
    if [[ -z "$NODE" && -f "$INVENTORY" ]]; then
        NODE="$(awk -v z="$ZDLRA" '$1 == z { print $2; exit }' "$INVENTORY")"
    fi
    NODE="${NODE:-$ZDLRA}"
    [[ "$NODE" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "Bad node name: $NODE"
}

remote_cmd() {
    local cmd="$REMOTE_SCRIPT -c $REMOTE_CONFIG $*"
    (( DRY_RUN )) || cmd+=" --execute"
    echo "$cmd"
}

blackout() { "${SCRIPT_DIR}/oem_blackout.sh" "$1" -z "$ZDLRA" -c "$CONFIG_FILE" $( (( DRY_RUN )) || echo -x ); }

# Field from the patch script's --status output, e.g. "Status" or "Run".
status_field() { awk -v k="$1:" '$1 == k && !done { $1 = ""; sub(/^ +/, ""); print; done = 1 }'; }   # reads all input: an early exit breaks the pipe

# ---------------------------------------------------------------------------
step_preflight() {
    info "== preflight =="
    info "Appliance $ZDLRA, patch node $NODE, dry run: $DRY_RUN"
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" true || die "Cannot ssh to ${SSH_USER}@${NODE} without a password."
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" "[ -x '$REMOTE_SCRIPT' ] && [ -f '$REMOTE_CONFIG' ]" \
        || die "${NODE}: $REMOTE_SCRIPT or $REMOTE_CONFIG not found."
    # A dry-run blackout start checks the emcli login, reason and targets without creating anything.
    local saved=$DRY_RUN
    DRY_RUN=1; blackout start || { DRY_RUN=$saved; die "Blackout settings are not ready (see above)."; }
    DRY_RUN=$saved
}

step_precheck() {
    info "== precheck (on $NODE) =="
    # -t gives the remote script a terminal, so you can review and type APPROVE.
    ssh -t -o ConnectTimeout=15 "${SSH_USER}@${NODE}" "$(remote_cmd precheck)" \
        || die "Precheck failed or was not approved. Nothing was changed and no blackout was created."
    RUN_ID="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" "$REMOTE_SCRIPT -c $REMOTE_CONFIG --status" | status_field Run)"
    [[ "$RUN_ID" =~ ^[0-9_]+$ ]] || die "Could not read the run id from $NODE."
    info "Precheck approved in run $RUN_ID"
}

step_blackout_start() {
    info "== blackout =="
    blackout start || die "Blackout was not created; patching not started. Run $RUN_ID is approved and can be continued."
    (( DRY_RUN )) || BLACKOUT_ACTIVE=1
}

step_patch() {
    info "== patch (on $NODE, background) =="
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" "$(remote_cmd --run-id "$RUN_ID" --background $PHASES)" \
        || die "Could not start the patch phases on $NODE. The blackout is still on: ${SCRIPT_DIR}/oem_blackout.sh stop -z $ZDLRA -x"
}

on_interrupt() {
    echo >&2
    warn "Stopped watching. The patch keeps running on $NODE."
    warn "Watch again:  $0 -z $ZDLRA --watch $RUN_ID $( (( DRY_RUN )) || echo -x )"
    (( BLACKOUT_ACTIVE )) && warn "The blackout is still on. End it later: ${SCRIPT_DIR}/oem_blackout.sh stop -z $ZDLRA -x"
    exit 130
}

step_watch() {
    info "== watch (every ${POLL_SECONDS}s; Ctrl-C stops watching, not patching) =="
    trap on_interrupt INT
    local out status last="" misses=0
    while :; do
        if out="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" "$REMOTE_SCRIPT -c $REMOTE_CONFIG --status --run-id $RUN_ID" 2>/dev/null)"; then
            misses=0
            status="$(status_field Status <<<"$out")"
            if [[ "$status" != "$last" ]]; then
                info "$NODE: $status"
                last="$status"
            fi
            case "$status" in
                *completed*) trap - INT; return 0 ;;
                *failed*)    trap - INT; return 1 ;;
            esac
        else
            misses=$((misses + 1))
            warn "Could not read status from $NODE (attempt $misses); the run continues there."
        fi
        sleep "$POLL_SECONDS"
    done
}

step_blackout_stop() {
    if (( KEEP_BLACKOUT )); then
        info "Blackout left on (--keep-blackout). End it with: ${SCRIPT_DIR}/oem_blackout.sh stop -z $ZDLRA -x"
        return 0
    fi
    info "== end blackout =="
    if (( DRY_RUN )); then
        info "[dry-run] would end the blackout for $ZDLRA (none was created)"
        return 0
    fi
    blackout stop || warn "Could not end the blackout. End it with: ${SCRIPT_DIR}/oem_blackout.sh stop -z $ZDLRA -x"
}

main() {
    parse_args "$@"
    load_config
    pick_node

    if [[ -n "$WATCH_RUN_ID" ]]; then
        RUN_ID="$WATCH_RUN_ID"
        (( DRY_RUN )) || BLACKOUT_ACTIVE=1
    else
        step_preflight
        step_precheck
        step_blackout_start
        step_patch
    fi

    if step_watch; then
        info "Run $RUN_ID completed on $NODE."
        step_blackout_stop
        info "Done. Report on $NODE: $REMOTE_SCRIPT -c $REMOTE_CONFIG --status --run-id $RUN_ID"
    else
        err "Run $RUN_ID failed on $NODE. The blackout is left on while you investigate."
        err "Details:      ssh ${SSH_USER}@${NODE} $REMOTE_SCRIPT -c $REMOTE_CONFIG --status --run-id $RUN_ID"
        err "End blackout: ${SCRIPT_DIR}/oem_blackout.sh stop -z $ZDLRA -x"
        exit 1
    fi
}

main "$@"
