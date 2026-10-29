#!/usr/bin/env bash
#
# zdlra_patch_run.sh - patch a ZDLRA from the jump server (OMS)
#
# Runs zdlra_patch.sh on the appliance's compute node over ssh, and handles the OEM
# blackout around it:
#
#   1. preflight   ssh to the node, patch script present, emcli logged in, blackout settings
#   2. precheck    starts on the node, detached: it keeps running if this terminal or
#                  the jump server connection drops; status is checked every POLL_SECONDS
#   3. approve     when the precheck finishes, you review it here and type APPROVE
#   4. blackout    created after approval, before anything changes
#   5. OEM jobs    your OEM_JOBS_SUSPEND_CMD suspends the OEM backup jobs
#   6. patch       remaining phases start on the node in the background
#   7. watch       status is checked every POLL_SECONDS until the run ends
#   8. finish      when the run completes: OEM jobs resumed, then the blackout ended.
#                  When it fails, both are left as they are while you investigate.
#
# Ctrl-C while watching stops watching only; the work on the node continues.
#
# Usage:
#   ./zdlra_patch_run.sh -z ZDLRA [-x] [-p "phase phase ..."]
#   ./zdlra_patch_run.sh -z ZDLRA --resume RUN_ID [-x]   continue from step 2/3 for a precheck run
#   ./zdlra_patch_run.sh -z ZDLRA --watch RUN_ID [-x]    continue from step 7 for a patch run
#
# Options:
#   -z, --zdlra NAME        appliance (required)
#   -x, --execute           real run: patch for real and create/end the blackout
#                           (default is dry run on the node and no blackout)
#   -p, --phases LIST       phases after precheck (default: all of them)
#   -r, --resume RUN_ID     pick up a run whose precheck is running, finished or approved
#   -w, --watch RUN_ID      watch a run whose patch phases are already going
#       --keep-blackout     do not end the blackout or resume OEM jobs when the run completes
#       --skip-backup-wait  quiesce on the node does not wait for incoming backups to finish
#   -c, --config FILE       config file (default: zdlra_jump.conf next to this script)
#   -h, --help              show this help

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/zdlra_jump.conf"
INVENTORY="${SCRIPT_DIR}/../staging/appliances.conf"
ZDLRA=""
DRY_RUN=1
PHASES="quiesce snapshot patch1 patch2 postcheck resume report"
SKIP_BACKUP_WAIT=0
RESUME_RUN_ID=""
WATCH_RUN_ID=""
KEEP_BLACKOUT=0

SSH_USER="root"
REMOTE_SCRIPT="/root/zdlra-patching/zdlra_patch.sh"
REMOTE_CONFIG="/root/zdlra-patching/zdlra_patch.conf"
POLL_SECONDS=60
declare -A PATCH_NODE=()
declare -A BLACKOUT_TARGETS=()   # not used here; lets the shared config load
OEM_JOBS_SUSPEND_CMD=()
OEM_JOBS_RESUME_CMD=()
SSH_OPTS=(-n -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30)   # -n: never read this terminal

NODE=""
RUN_ID=""
STAGE="precheck"                 # what is running on the node: precheck or patch
BLACKOUT_ACTIVE=0
JOBS_SUSPENDED=0

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
            -r|--resume)     RESUME_RUN_ID="$2"; shift 2 ;;
            -w|--watch)      WATCH_RUN_ID="$2"; shift 2 ;;
            --keep-blackout) KEEP_BLACKOUT=1; shift ;;
            --skip-backup-wait) SKIP_BACKUP_WAIT=1; shift ;;
            -c|--config)     CONFIG_FILE="$2"; shift 2 ;;
            -h|--help)       usage; exit 0 ;;
            *)               die "Unknown argument: $1 (see --help)" ;;
        esac
    done
    [[ -n "$ZDLRA" ]] || { usage; exit 1; }
    [[ "$ZDLRA" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "Bad appliance name: $ZDLRA"
    [[ "$PHASES" =~ ^[a-z0-9\ ]+$ ]] || die "Bad phase list: $PHASES"
    [[ " $PHASES " != *" precheck "* ]] || die "Leave precheck out of --phases; it always runs first."
    local id
    for id in "$RESUME_RUN_ID" "$WATCH_RUN_ID"; do
        [[ -z "$id" || "$id" =~ ^[0-9_]+$ ]] || die "Bad run id: $id"
    done
    [[ -z "$RESUME_RUN_ID" || -z "$WATCH_RUN_ID" ]] || die "Use --resume or --watch, not both."
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

on_node() { ssh "${SSH_OPTS[@]}" "${SSH_USER}@${NODE}" "$@"; }

remote_cmd() {
    local cmd="$REMOTE_SCRIPT -c $REMOTE_CONFIG $*"
    (( DRY_RUN )) || cmd+=" --execute"
    echo "$cmd"
}

blackout() { "${SCRIPT_DIR}/oem_blackout.sh" "$1" -z "$ZDLRA" -c "$CONFIG_FILE" $( (( DRY_RUN )) || echo -x ); }

# Field from the patch script's --status output, e.g. "Status" or "Run".
status_field() { awk -v k="$1:" '$1 == k && !done { $1 = ""; sub(/^ +/, ""); print; done = 1 }'; }   # reads all input: an early exit breaks the pipe

run_status() { on_node "$REMOTE_SCRIPT -c $REMOTE_CONFIG --status --run-id $RUN_ID" 2>/dev/null | status_field Status; }

xflag() { (( DRY_RUN )) || echo " -x"; }

# Run one of the OEM job commands from the config, with {zdlra} filled in.
# $1 = label for messages, rest = the command and its arguments.
run_jobs_cmd() {
    local label="$1"; shift
    if (( $# == 0 )); then
        warn "No OEM job command set for '$label' in $CONFIG_FILE; skipping."
        return 0
    fi
    local cmd=("${@//\{zdlra\}/$ZDLRA}")
    if (( DRY_RUN )); then
        info "[dry-run] $label OEM jobs: ${cmd[*]}"
        return 0
    fi
    info "[exec] $label OEM jobs: ${cmd[*]}"
    "${cmd[@]}"
}

jobs_cmd_text() { local c=("${@//\{zdlra\}/$ZDLRA}"); echo "${c[*]}"; }

# What to undo by hand after a failure or interruption, once the work has started.
print_undo() {
    # The node records which replication servers this run paused; its resume phase undoes only those.
    [[ "$STAGE" == patch ]] && err "Resume replication (if quiesce paused it): ssh ${SSH_USER}@${NODE} $(remote_cmd --run-id "$RUN_ID" resume)"
    (( JOBS_SUSPENDED )) && err "Resume OEM jobs: $(jobs_cmd_text ${OEM_JOBS_RESUME_CMD[@]+"${OEM_JOBS_RESUME_CMD[@]}"})"
    (( BLACKOUT_ACTIVE )) && err "End blackout:    ${SCRIPT_DIR}/oem_blackout.sh stop -z $ZDLRA -x"
    return 0
}

# ---------------------------------------------------------------------------
step_preflight() {
    info "== preflight =="
    info "Appliance $ZDLRA, patch node $NODE, dry run: $DRY_RUN"
    on_node true || die "Cannot ssh to ${SSH_USER}@${NODE} without a password."
    on_node "[ -x '$REMOTE_SCRIPT' ] && [ -f '$REMOTE_CONFIG' ]" \
        || die "${NODE}: $REMOTE_SCRIPT or $REMOTE_CONFIG not found."
    # A dry-run blackout start checks the emcli login, reason and targets without creating anything.
    local saved=$DRY_RUN
    DRY_RUN=1; blackout start || { DRY_RUN=$saved; die "Blackout settings are not ready (see above)."; }
    DRY_RUN=$saved
    local c
    for c in ${OEM_JOBS_SUSPEND_CMD[0]-} ${OEM_JOBS_RESUME_CMD[0]-}; do
        [[ -x "$c" ]] || command -v "$c" >/dev/null 2>&1 || die "OEM job command not found or not executable: $c"
    done
    (( ${#OEM_JOBS_SUSPEND_CMD[@]} )) || warn "OEM_JOBS_SUSPEND_CMD is not set; OEM backup jobs will not be suspended."
}

step_precheck_start() {
    info "== precheck (on $NODE, detached) =="
    on_node "$(remote_cmd --detach precheck)" || die "Could not start the precheck on $NODE."
    RUN_ID="$(on_node "$REMOTE_SCRIPT -c $REMOTE_CONFIG --status" | status_field Run)"
    [[ "$RUN_ID" =~ ^[0-9_]+$ ]] || die "Could not read the run id from $NODE."
    info "Precheck running in run $RUN_ID"
}

on_interrupt() {
    echo >&2
    if [[ "$STAGE" == precheck ]]; then
        warn "Stopped watching. The precheck keeps running on $NODE; nothing has changed yet."
        warn "Continue later:  $0 -z $ZDLRA --resume $RUN_ID$(xflag)"
    else
        warn "Stopped watching. The patch keeps running on $NODE."
        warn "Watch again:     $0 -z $ZDLRA --watch $RUN_ID$(xflag)"
        warn "Watching again resumes OEM jobs and ends the blackout when the run completes. To do it by hand:"
        print_undo
    fi
    exit 130
}

# Poll the run's status until it reaches an end state for the current stage.
# Prints the final status; returns 0 for a good end state, 1 for a failure.
# Runs in a subshell when its output is captured, so the Ctrl-C trap is set in main.
#   precheck: "awaiting approval", "precheck approved" or "completed" are good
#   patch:    "completed" is good
watch_until_done() {
    info "== watch $STAGE (every ${POLL_SECONDS}s; Ctrl-C stops watching only) =="
    local status last="" misses=0
    while :; do
        status="$(run_status || true)"
        if [[ -n "$status" ]]; then
            misses=0
            if [[ "$status" != "$last" ]]; then
                info "$NODE: $status"
                last="$status"
            fi
            case "$STAGE:$status" in
                *:*failed*)                                 echo "$status"; return 1 ;;
                precheck:*awaiting\ approval*|precheck:*precheck\ approved*|*:*completed*)
                                                            echo "$status"; return 0 ;;
            esac
        else
            misses=$((misses + 1))
            warn "Could not read status from $NODE (attempt $misses); the work continues there."
        fi
        sleep "$POLL_SECONDS"
    done
}

# Review and approve a finished precheck, unless it is already approved or the
# node's config does not ask for approval ($1 = status from the node).
step_approve() {
    case "$1" in
        *precheck\ approved*) info "Precheck in run $RUN_ID is already approved."; return 0 ;;
        *completed*)          info "Precheck finished; the node's config does not ask for approval."; return 0 ;;
    esac
    info "== approve (on $NODE) =="
    # -t gives the remote script a terminal for the review and the APPROVE prompt.
    ssh -t -o ConnectTimeout=15 "${SSH_USER}@${NODE}" "$(remote_cmd --approve --run-id "$RUN_ID")" \
        || die "Precheck not approved. Nothing was changed and no blackout was created. Continue later: $0 -z $ZDLRA --resume $RUN_ID$(xflag)"
    info "Precheck approved in run $RUN_ID"
}

step_blackout_start() {
    info "== blackout =="
    blackout start || die "Blackout was not created; patching not started. Continue later: $0 -z $ZDLRA --resume $RUN_ID$(xflag)"
    (( DRY_RUN )) || BLACKOUT_ACTIVE=1
}

step_jobs_suspend() {
    info "== suspend OEM backup jobs =="
    if ! run_jobs_cmd suspend ${OEM_JOBS_SUSPEND_CMD[@]+"${OEM_JOBS_SUSPEND_CMD[@]}"}; then
        err "Suspending OEM jobs failed; patching not started. Some jobs may already be suspended."
        JOBS_SUSPENDED=1
        print_undo
        exit 1
    fi
    (( DRY_RUN || ${#OEM_JOBS_SUSPEND_CMD[@]} == 0 )) || JOBS_SUSPENDED=1
}

step_patch() {
    info "== patch (on $NODE, background) =="
    local opts="--run-id $RUN_ID --background"
    (( SKIP_BACKUP_WAIT )) && opts+=" --skip-backup-wait"
    if ! on_node "$(remote_cmd $opts $PHASES)"; then
        err "Could not start the patch phases on $NODE."
        print_undo
        exit 1
    fi
    STAGE="patch"
}

step_jobs_resume() {
    if (( KEEP_BLACKOUT )); then
        info "OEM jobs left suspended (--keep-blackout). Resume them with: $(jobs_cmd_text ${OEM_JOBS_RESUME_CMD[@]+"${OEM_JOBS_RESUME_CMD[@]}"})"
        return 0
    fi
    info "== resume OEM backup jobs =="
    run_jobs_cmd resume ${OEM_JOBS_RESUME_CMD[@]+"${OEM_JOBS_RESUME_CMD[@]}"} \
        || warn "Resuming OEM jobs failed. Resume them with: $(jobs_cmd_text ${OEM_JOBS_RESUME_CMD[@]+"${OEM_JOBS_RESUME_CMD[@]}"})"
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
    trap on_interrupt INT

    if [[ -n "$WATCH_RUN_ID" ]]; then
        RUN_ID="$WATCH_RUN_ID"
        STAGE="patch"
        if (( ! DRY_RUN )); then
            BLACKOUT_ACTIVE=1
            (( ${#OEM_JOBS_SUSPEND_CMD[@]} == 0 )) || JOBS_SUSPENDED=1
        fi
    else
        step_preflight
        if [[ -n "$RESUME_RUN_ID" ]]; then
            RUN_ID="$RESUME_RUN_ID"
            info "Resuming run $RUN_ID (status: $(run_status || echo unknown))"
        else
            step_precheck_start
        fi
        local status
        status="$(watch_until_done)" || die "Precheck failed in run $RUN_ID ($status). Nothing was changed and no blackout was created."
        step_approve "$status"
        step_blackout_start
        step_jobs_suspend
        step_patch
    fi

    if watch_until_done >/dev/null; then
        info "Run $RUN_ID completed on $NODE."
        step_jobs_resume
        step_blackout_stop
        info "Done. Report on $NODE: $REMOTE_SCRIPT -c $REMOTE_CONFIG --status --run-id $RUN_ID"
    else
        err "Run $RUN_ID failed on $NODE. OEM jobs and the blackout are left as they are while you investigate."
        err "Details:         ssh ${SSH_USER}@${NODE} $REMOTE_SCRIPT -c $REMOTE_CONFIG --status --run-id $RUN_ID"
        print_undo
        exit 1
    fi
}

main "$@"
