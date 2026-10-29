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
#   6. patch       the phases before "compute" start on the node in the background,
#                  and are watched until they finish
#   7. compute     the compute nodes are upgraded from here (see below)
#   8. patch       the phases after "compute" run on the node, and are watched
#   9. finish      when the run completes: OEM jobs resumed, then the blackout ended.
#                  When it fails, both are left as they are while you investigate.
#
# Compute nodes ("compute" in the phase list): patchmgr runs on one compute node and
# upgrades another, which reboots. First the first node upgrades each of the others,
# one at a time; then the second node upgrades the first. Each patchmgr runs detached
# on its node (own session, log and exit-status file there), so nothing can cut it
# short; this script only starts it over ssh and polls it, through the reboots. For
# each pass, a db_nodes file listing only the node being patched is written for this
# run. Each pass: patchmgr -precheck (-nomodify_at_prereq), then -upgrade, then
# imageinfo on the patched node must show TARGET_COMPUTE_VERSION.
#
# Ctrl-C while watching stops watching only; the work on the node continues.
#
# Usage:
#   ./zdlra_patch_run.sh -z ZDLRA [-x] [-p "phase phase ..."]
#   ./zdlra_patch_run.sh -z ZDLRA --resume RUN_ID [-x]   continue from step 2/3 for a precheck run
#   ./zdlra_patch_run.sh -z ZDLRA --watch RUN_ID [-x]    pick up watching a run from step 6
#
# Options:
#   -z, --zdlra NAME        appliance (required)
#   -x, --execute           real run: patch for real and create/end the blackout
#                           (default is dry run on the node and no blackout)
#   -p, --phases LIST       phases after precheck (default: all of them); "compute"
#                           marks where the compute nodes are upgraded from here
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
PHASES="quiesce snapshot patch1 patch2 cells compute postcheck resume report"
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
OEM_JOBS_DIR=""                  # folder the OEM job commands run in (empty = current folder)
declare -A OEM_JOBS_DB=()        # per appliance: the name the OEM jobs script uses ({jobs_db})
# Output lines that mean the OEM jobs command failed, even if it exits 0: the error
# and usage text sr_jobs_new.ksh prints for a wrong zdlra db value. Empty = exit status only.
OEM_JOBS_FAIL_RE='zdlra db values must be|ksh -z <zdlra db>'
# The script sr_jobs_new.ksh writes, which is then run here ({action} = suspend or
# resume, {jobs_db} as above). Empty = only run the command itself.
OEM_JOBS_GENERATED='{jobs_db}_{action}_job_*.ksh'
# Lines in the generated script's log that mean an emcli command failed.
OEM_JOBS_ERROR_RE='^[[:space:]]*Error'
SSH_OPTS=(-n -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30)   # -n: never read this terminal

# Compute nodes (the "compute" phase, run from here). Paths are on the compute nodes.
NODE_STAGED_RECORD="/radump/patches/ZDLRA_STAGED.txt"
COMPUTE_TMP_DIR="/radump/patches/tmp"          # where staging unzipped the db_server_patch
COMPUTE_FILES_DIR="/radump/patches/patches"    # the computepatch (iso repo) is here
COMPUTE_WORK_DIR="/radump/zdlra_compute"       # per run: db_nodes files, logs, exit status
NODE_DCLI="dcli"
COMPUTE_WARN_MINUTES=240        # past this, a warning only; patchmgr is never stopped
COMPUTE_POLL_SECONDS=60
# "SUCCESS WITH WARNING(S)" from patchmgr: 0 = carry on (the warnings are listed),
# 1 = stop for review before going on. Decided for now: carry on, because the
# prechecks have already been reviewed. To revisit.
COMPUTE_PAUSE_ON_WARNINGS=0
STATE_DIR="${HOME}/zdlra_jump_state"
LOG_DIR="${HOME}/zdlra_jump_logs"

NODE=""
RUN_ID=""
STAGE="precheck"                 # what is running on the node: precheck or patch
BLACKOUT_ACTIVE=0
JOBS_SUSPENDED=0

log()  { local lvl="$1"; shift; printf '%s [%-5s] %s\n' "$(date '+%F %T')" "$lvl" "$*" >&2; }
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
err()  { log ERROR "$@"; }
die()  {
    err "$@"
    # During compute, say how to pick up again and what is still on.
    if [[ "${STAGE:-}" == compute ]]; then
        err "Fix the problem, then pick up again: $0 -z $ZDLRA --watch $RUN_ID$(xflag)"
        err "(a failed patchmgr step is started again; finished passes are skipped)"
        print_undo
    fi
    exit 1
}

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
    [[ "$(grep -o '\bcompute\b' <<<"$PHASES" | wc -l)" -le 1 ]] || die "compute can appear only once in --phases."
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

# The name the OEM jobs script uses for this appliance ({jobs_db}): OEM_JOBS_DB, or
# the appliance name itself when it is not listed.
jobs_db() { echo "${OEM_JOBS_DB[$ZDLRA]:-$ZDLRA}"; }

# Fill in {zdlra} and {jobs_db} in a command; prints one argument per line.
jobs_cmd_fill() {
    local a db; db="$(jobs_db)"
    for a in "$@"; do a="${a//\{zdlra\}/$ZDLRA}"; printf '%s\n' "${a//\{jobs_db\}/$db}"; done
}

# Run one of the OEM job commands from the config, in OEM_JOBS_DIR, with {zdlra} and
# {jobs_db} filled in. $1 = label for messages, rest = the command and its arguments.
run_jobs_cmd() {
    local label="$1"; shift
    if (( $# == 0 )); then
        warn "No OEM job command set for '$label' in $CONFIG_FILE; skipping."
        return 0
    fi
    local cmd=()
    mapfile -t cmd < <(jobs_cmd_fill "$@")
    if (( DRY_RUN )); then
        info "[dry-run] $label OEM jobs: ${OEM_JOBS_DIR:+cd $OEM_JOBS_DIR && }${cmd[*]}"
        [[ -z "$OEM_JOBS_GENERATED" ]] \
            || info "[dry-run] then run the script it writes ($(jobs_cmd_fill "${OEM_JOBS_GENERATED//\{action\}/$label}")) and check its log"
        return 0
    fi
    info "[exec] $label OEM jobs: ${OEM_JOBS_DIR:+cd $OEM_JOBS_DIR && }${cmd[*]}"
    # The output is shown as it comes and also checked: a nonzero exit or a line
    # matching OEM_JOBS_FAIL_RE (the script's error and usage text) counts as failed.
    local out rc marker
    out="$(mktemp)"; marker="$(mktemp)"    # marker: files newer than this were made by this call
    ( if [[ -n "$OEM_JOBS_DIR" ]]; then cd "$OEM_JOBS_DIR" || exit 1; fi; "${cmd[@]}" ) 2>&1 | tee "$out"
    rc=${PIPESTATUS[0]}
    if (( rc == 0 )) && [[ -n "$OEM_JOBS_FAIL_RE" ]] && grep -qE "$OEM_JOBS_FAIL_RE" "$out"; then
        err "$label OEM jobs: the output shows an error (matches OEM_JOBS_FAIL_RE), although the exit status was 0."
        rc=1
    fi
    rm -f "$out"
    if (( rc == 0 )) && [[ -n "$OEM_JOBS_GENERATED" ]]; then
        run_generated_jobs_script "$label" "$marker" || rc=1
    fi
    rm -f "$marker"
    return "$rc"
}

# sr_jobs_new.ksh only writes a script (<jobs_db>_<suspend|resume>_job_<stamp>.ksh) with
# one emcli command per job; this runs it. Exactly one such file must be newer than the
# marker, so an older one is never run. Its output goes to <same name>.log (as when run
# by hand) and to the screen. emcli errors in the log (OEM_JOBS_ERROR_RE) count as failed.
# $1 = suspend | resume, $2 = marker file made before sr_jobs_new.ksh ran
run_generated_jobs_script() {
    local label="$1" marker="$2" dir="${OEM_JOBS_DIR:-.}" pattern found=() f log rc n
    pattern="$(jobs_cmd_fill "$OEM_JOBS_GENERATED")"
    pattern="${pattern//\{action\}/$label}"
    mapfile -t found < <(find "$dir" -maxdepth 1 -type f -name "$pattern" -newer "$marker" 2>/dev/null)
    if (( ${#found[@]} != 1 )); then
        err "$label OEM jobs: expected one new $pattern in $dir; found ${#found[@]}${found[*]:+: ${found[*]##*/}}"
        return 1
    fi
    f="${found[0]##*/}"; log="${f%.ksh}.log"
    info "[exec] $label OEM jobs: cd $dir && ./$f > $log 2>&1 ($(grep -c 'emcli' "$dir/$f") emcli lines; about 30 min is normal)"
    ( cd "$dir" || exit 1; if [[ -x "$f" ]]; then "./$f"; else ksh "./$f"; fi ) 2>&1 | tee "$dir/$log"
    rc=${PIPESTATUS[0]}
    # The script runs every emcli command even if some fail, so its exit status says
    # little. Failed commands are listed as warnings and the run carries on; jobs that
    # are still running are caught by the wait for incoming backups before patching.
    n=0
    [[ -z "$OEM_JOBS_ERROR_RE" ]] || n="$(grep -cE "$OEM_JOBS_ERROR_RE" "$dir/$log" || true)"
    if (( n > 0 )); then
        warn "$label OEM jobs: $n emcli error line(s) in $dir/$log (carrying on):"
        grep -E "$OEM_JOBS_ERROR_RE" "$dir/$log" | head -20 | sed 's/^/  /' >&2
    fi
    (( rc == 0 )) || warn "$label OEM jobs: $f exited with status $rc (see $dir/$log)."
    info "$label OEM jobs: $f finished; log $dir/$log"
}

jobs_cmd_text() {
    local c=(); mapfile -t c < <(jobs_cmd_fill "$@")
    echo "${OEM_JOBS_DIR:+cd $OEM_JOBS_DIR && }${c[*]}"
}

# What to undo by hand after a failure or interruption, once the work has started.
print_undo() {
    # The node records which replication servers this run paused; its resume phase undoes only those.
    [[ "$STAGE" == patch || "$STAGE" == compute ]] && err "Resume replication (if quiesce paused it): ssh ${SSH_USER}@${NODE} $(remote_cmd --run-id "$RUN_ID" resume)"
    (( JOBS_SUSPENDED )) && err "Resume OEM jobs: $(jobs_cmd_text ${OEM_JOBS_RESUME_CMD[@]+"${OEM_JOBS_RESUME_CMD[@]}"})"
    (( BLACKOUT_ACTIVE )) && err "End blackout:    ${SCRIPT_DIR}/oem_blackout.sh stop -z $ZDLRA -x"
    return 0
}

# The node phases before and after "compute" in PHASES.
phases_before() { sed -E 's/(^| )compute( |$).*//' <<<"$PHASES" | xargs; }
phases_after()  { [[ " $PHASES " == *" compute "* ]] && sed -E 's/.*(^| )compute( |$)//' <<<"$PHASES" | xargs || true; }
has_compute()   { [[ " $PHASES " == *" compute "* ]]; }

# Where this run is, on the jump server, so --watch can pick it up:
#   stage=before|compute|after|done, and during compute the pass being worked on.
state_file() { echo "${STATE_DIR}/${ZDLRA}_${RUN_ID}.state"; }
state_set()  { mkdir -p "$STATE_DIR"; printf '%s\n' "$@" > "$(state_file)"; }
state_get()  { sed -n "s/^$1=//p" "$(state_file)" 2>/dev/null | head -1; }

run_log_dir() { local d="${LOG_DIR}/${ZDLRA}_${RUN_ID}"; mkdir -p "$d"; echo "$d"; }

# ssh to a named compute node (not just the patch node).
on() { local n="$1"; shift; ssh "${SSH_OPTS[@]}" "${SSH_USER}@${n}" "$@"; }
# The same, but feeding a script on stdin (so without -n, which would discard it).
on_script() { local n="$1"; shift; ssh "${SSH_OPTS[@]/#-n/-T}" "${SSH_USER}@${n}" "$@"; }

# ---------------------------------------------------------------------------
# Compute nodes
# ---------------------------------------------------------------------------
# What the compute passes need, read on the first node from the staged record and
# the conf file staging set up. Sets C_NODES (in order), C_TARGET, C_ISO, C_DIR.
C_NODES=(); C_TARGET=""; C_ISO=""; C_DIR=""
compute_gather() {
    local out
    out="$(on_script "$NODE" "bash -s -- '$NODE_STAGED_RECORD' '$COMPUTE_FILES_DIR' '$COMPUTE_TMP_DIR'" <<'REMOTE'
rec=$1 files=$2 tmp=$3
val() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -1 | tr -d '\r' | sed -E "s/^[\"']//; s/[\"']$//; s/[[:space:]]+$//"; }
[ -f "$rec" ] || { echo "ERROR no staged record at $rec"; exit 1; }
conf=$(val patch_conf "$rec"); [ -f "$conf" ] || { echo "ERROR conf file not found: $conf"; exit 1; }
echo "NODES=$(val component_COMPUTE_NODE "$rec")"
echo "TARGET=$(val TARGET_COMPUTE_VERSION "$conf")"
yum=$(val FILES_YUM "$conf")
iso=$(echo "$yum" | cut -d, -f1 | xargs); dbs=$(echo "$yum" | cut -d, -f2 | xargs)
echo "ISO=$iso"
[ -f "$files/$iso" ] || echo "ERROR computepatch not found: $files/$iso"
top=$(unzip -Z1 "$files/$dbs" 2>/dev/null | sed 's#^\./##; s#/.*##' | grep -v '^$' | sort -u)
[ "$(echo "$top" | grep -c .)" = 1 ] || echo "ERROR cannot tell the db_server_patch folder from $files/$dbs"
echo "DIR=$top"
[ -x "$tmp/$top/patchmgr" ] || echo "ERROR no patchmgr in $tmp/$top"
REMOTE
)" || die "Could not read the compute patch details on $NODE: $out"
    if grep -q '^ERROR' <<<"$out"; then
        grep '^ERROR' <<<"$out" | sed 's/^ERROR /  /' | while IFS= read -r l; do err "$l"; done
        die "Compute patch details are not ready on $NODE (see above)."
    fi
    IFS=',' read -r -a C_NODES <<<"$(sed -n 's/^NODES=//p' <<<"$out")"
    C_TARGET="$(sed -n 's/^TARGET=//p' <<<"$out")"
    # Names only: each node has its own copy under the same paths.
    C_ISO="${COMPUTE_FILES_DIR}/$(sed -n 's/^ISO=//p' <<<"$out")"
    C_DIR="${COMPUTE_TMP_DIR}/$(sed -n 's/^DIR=//p' <<<"$out")"
    (( ${#C_NODES[@]} >= 2 )) || die "The staged record lists fewer than 2 compute nodes: ${C_NODES[*]-}"
    [[ -n "$C_TARGET" ]] || die "TARGET_COMPUTE_VERSION is not set in the conf file."
    local n
    for n in "${C_NODES[@]}"; do [[ "$n" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "Bad compute node name: $n"; done
    [[ "$C_TARGET" =~ ^[0-9][0-9.]*$ ]] || die "Unexpected TARGET_COMPUTE_VERSION: $C_TARGET"
    [[ "$C_ISO" =~ ^/[A-Za-z0-9._/-]+$ && "$C_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "Unexpected compute patch paths: $C_ISO, $C_DIR"
}

# The passes, as "runner target": the first node upgrades each of the others, then
# the second node upgrades the first.
compute_passes() {
    local i
    for (( i = 1; i < ${#C_NODES[@]}; i++ )); do echo "${C_NODES[0]} ${C_NODES[i]}"; done
    echo "${C_NODES[1]} ${C_NODES[0]}"
}

# Start patchmgr detached on a node. Fails if one is already running there.
# $1 = runner, $2 = job name (log/rc/pid file prefix), rest = patchmgr arguments.
start_remote_patchmgr() {
    local runner="$1" job="$2"; shift 2
    local work="${COMPUTE_WORK_DIR}/${RUN_ID}" a args=""
    for a in "$@"; do args+=" '$a'"; done
    on_script "$runner" "bash -s -- '$C_DIR' '$work' '$job' $args" <<'REMOTE'
dir=$1 work=$2 job=$3; shift 3
log=$work/$job.log rc=$work/$job.rc pidf=$work/$job.pid
if [ -s "$work/running.pid" ] && kill -0 "$(cat "$work/running.pid")" 2>/dev/null; then
    echo "ERROR a patchmgr is already running on $(hostname) (pid $(cat "$work/running.pid"))"; exit 3
fi
mkdir -p "$work" || { echo "ERROR cannot create $work"; exit 1; }
: > "$log"; rm -f "$rc" "$pidf"
L="nohup"; command -v setsid >/dev/null 2>&1 && L="setsid nohup"
$L bash -c 'echo $$ > "$1"; cp "$1" "$(dirname "$1")/running.pid"; cd "$2" || { echo 97 > "$0"; exit; }; shift 3; ./patchmgr "$@"; echo $? > "$0"' \
    "$rc" "$pidf" "$dir" _ "$@" >> "$log" 2>&1 < /dev/null &
for i in $(seq 1 30); do [ -s "$pidf" ] && break; sleep 1; done
[ -s "$pidf" ] || { echo "ERROR patchmgr did not start"; exit 1; }
echo "STARTED pid $(cat "$pidf")"
REMOTE
}

# Poll a detached patchmgr on a node until its exit status is written, showing its
# log as it grows. A failed ssh (e.g. a reboot) only means "try again".
# Copies the full log here; prints its local path. $1 = runner, $2 = job.
wait_remote_patchmgr() {
    local runner="$1" job="$2" work="${COMPUTE_WORK_DIR}/${RUN_ID}"
    local local_log
    local_log="$(run_log_dir)/compute_${runner}_${job}.log"
    local shown=0 total rc="" start warned=0 out
    start=$(date +%s)
    while :; do
        if out="$(on "$runner" "cat '$work/$job.rc' 2>/dev/null; echo; wc -l < '$work/$job.log'" 2>/dev/null)"; then
            rc="$(head -1 <<<"$out" | tr -dc '0-9')"
            total="$(tail -1 <<<"$out" | tr -dc '0-9')"
            if [[ -n "$total" ]] && (( total > shown )); then
                on "$runner" "sed -n '$(( shown + 1 )),${total}p' '$work/$job.log'" 2>/dev/null | sed "s|^|  ${runner}: |" >&2 || true
                shown=$total
            fi
            [[ -n "$rc" ]] && break
        else
            warn "Could not reach $runner; patchmgr keeps running there. Trying again."
        fi
        if (( ! warned && $(date +%s) - start > COMPUTE_WARN_MINUTES * 60 )); then
            warn "patchmgr $job on $runner has run for over ${COMPUTE_WARN_MINUTES} min; still waiting (not stopping it)."
            warned=1
        fi
        sleep "$COMPUTE_POLL_SECONDS"
    done
    on "$runner" "cat '$work/$job.log'" > "$local_log" 2>/dev/null || true
    on "$runner" "rm -f '$work/running.pid'" 2>/dev/null || true
    echo "$rc $local_log"
}

# Check a finished patchmgr run. $1 = exit status, $2 = local log, $3 = what.
check_patchmgr_log() {
    local rc="$1" log="$2" what="$3" failed warnings
    failed="$(grep -E 'FAILED' "$log" | head -10 || true)"
    if [[ -n "$failed" ]]; then
        while IFS= read -r l; do err "  $l"; done <<<"$failed"
        die "$what reported failures. Log: $log"
    fi
    (( rc != 97 )) || die "$what: cannot enter $C_DIR. Log: $log"
    (( rc == 0 )) || die "$what exited with code $rc. Log: $log"
    grep -q 'SUCCESS: Completed run of command' "$log" && grep -q 'Exit status:0' "$log" \
        || die "$what did not report a completed run. Log: $log"
    if grep -qE 'has state: ' "$log" && grep -E 'has state: ' "$log" | grep -vqE 'has state: SUCCESS'; then
        die "$what: a node did not reach state SUCCESS. Log: $log"
    fi
    warnings="$(grep -E '^[A-Za-z0-9._-]+: WARNING:' "$log" || true)"
    if [[ -n "$warnings" ]]; then
        warn "$what: SUCCESS WITH WARNING(S):"
        while IFS= read -r l; do warn "  $(cut -c1-200 <<<"$l")"; done <<<"$warnings"
        if (( COMPUTE_PAUSE_ON_WARNINGS )); then
            die "$what has warnings and COMPUTE_PAUSE_ON_WARNINGS=1. Review them, then continue with --watch $RUN_ID."
        fi
    fi
    info "$what: completed."
}

# The patched node's image version, from the runner (the patched node may still be
# coming up, so this retries until it answers).
check_compute_version() {
    local runner="$1" target="$2" work="${COMPUTE_WORK_DIR}/${RUN_ID}" out ver
    while :; do
        if out="$(on "$runner" "$NODE_DCLI -g '$work/db_nodes_${target}' -l root 'imageinfo -ver'" 2>/dev/null)" && [[ -n "$out" ]]; then
            ver="$(sed -n "s/^${target}:[[:space:]]*//p" <<<"$out" | head -1 | tr -d '[:space:]')"
            [[ -n "$ver" ]] && break
        fi
        warn "No image version from $target yet (checked from $runner); trying again."
        sleep "$COMPUTE_POLL_SECONDS"
    done
    [[ "$ver" == "$C_TARGET" ]] || die "$target is on $ver, expected $C_TARGET."
    info "$target is on $C_TARGET."
}

# Exit status of a finished job on a node, or empty. $1 = runner, $2 = job.
job_rc() { on "$1" "cat '${COMPUTE_WORK_DIR}/${RUN_ID}/$2.rc' 2>/dev/null" 2>/dev/null | tr -dc '0-9'; }

# One pass: on runner, upgrade target. $3 = step to start from (precheck, upgrade,
# verify), so --watch can pick up a pass where it was.
compute_pass() {
    local runner="$1" target="$2" from="${3:-precheck}" work="${COMPUTE_WORK_DIR}/${RUN_ID}"
    local common=(-dbnodes "$work/db_nodes_${target}" -log_dir auto -target_version "$C_TARGET" -iso_repo "$C_ISO")
    info "-- pass: $runner upgrades $target (to $C_TARGET) --"
    if [[ "$from" == precheck ]]; then
        state_set stage=compute "runner=$runner" "target=$target" step=precheck
        on "$runner" "[ -f '$C_ISO' ] && [ -x '$C_DIR/patchmgr' ]" \
            || die "$runner: the ISO repo $C_ISO or $C_DIR/patchmgr is missing on this node."
        on "$runner" "mkdir -p '$work' && echo '$target' > '$work/db_nodes_${target}' && cd '$C_DIR' && { [ ! -f dbnodeupdate.zip ] || unzip -q -o dbnodeupdate.zip; }" \
            || die "$runner: could not prepare $work/db_nodes_${target} or unzip dbnodeupdate.zip in $C_DIR"
        local out
        out="$(start_remote_patchmgr "$runner" "precheck_${target}" "${common[@]}" -precheck -nomodify_at_prereq)" || die "$runner: $out"
        info "$runner: patchmgr -precheck ${out#STARTED }"
        from=precheck_wait
    fi
    # Picking up a precheck that already failed: start it again.
    if [[ "$from" == precheck_wait ]] && [[ "$(job_rc "$runner" "precheck_${target}")" =~ ^[1-9][0-9]*$ ]]; then
        info "$runner: the previous patchmgr -precheck for $target failed; starting it again"
        from=precheck
        compute_pass "$runner" "$target" precheck
        return
    fi
    if [[ "$from" == precheck || "$from" == precheck_wait ]]; then
        local res
        res="$(wait_remote_patchmgr "$runner" "precheck_${target}")"
        check_patchmgr_log "${res%% *}" "${res#* }" "patchmgr -precheck on $runner for $target"
        from=upgrade
    fi
    if [[ "$from" == upgrade ]]; then
        state_set stage=compute "runner=$runner" "target=$target" step=upgrade
        local out
        if [[ "$(job_rc "$runner" "upgrade_${target}")" =~ ^[1-9][0-9]*$ ]]; then
            info "$runner: the previous patchmgr -upgrade for $target failed; starting it again"
            on "$runner" "rm -f '$work/upgrade_${target}.pid' '$work/upgrade_${target}.rc'" || true
        fi
        if ! on "$runner" "[ -f '$work/upgrade_${target}.pid' ]" 2>/dev/null; then
            out="$(start_remote_patchmgr "$runner" "upgrade_${target}" "${common[@]}" -upgrade)" || die "$runner: $out"
            info "$runner: patchmgr -upgrade ${out#STARTED } ($target reboots)"
        else
            info "$runner: patchmgr -upgrade for $target was already started; waiting for it"
        fi
        local res
        res="$(wait_remote_patchmgr "$runner" "upgrade_${target}")"
        check_patchmgr_log "${res%% *}" "${res#* }" "patchmgr -upgrade on $runner for $target"
        from=verify
    fi
    state_set stage=compute "runner=$runner" "target=$target" step=verify
    check_compute_version "$runner" "$target"
}

step_compute() {
    info "== compute (from the jump server) =="
    STAGE="compute"
    compute_gather
    info "Compute nodes: ${C_NODES[*]}; target $C_TARGET"
    info "ISO repo: $C_ISO"
    info "db_server_patch: $C_DIR"
    local pass runner target
    if (( DRY_RUN )); then
        while read -r runner target; do
            info "[dry-run] on $runner: db_nodes file with only $target; cd $C_DIR; unzip -q dbnodeupdate.zip"
            info "[dry-run] on $runner: ./patchmgr -dbnodes <db_nodes $target> -precheck -log_dir auto -target_version $C_TARGET -iso_repo $C_ISO -nomodify_at_prereq"
            info "[dry-run] on $runner: ./patchmgr -dbnodes <db_nodes $target> -upgrade -log_dir auto -target_version $C_TARGET -iso_repo $C_ISO"
            info "[dry-run] on $runner: $NODE_DCLI -g <db_nodes $target> -l root 'imageinfo -ver'  ($target must be $C_TARGET)"
        done < <(compute_passes)
        return 0
    fi
    # Pick up where a previous watch left off (--watch), else start at the first pass.
    local resume_runner resume_target resume_step skipping=0
    resume_runner="$(state_get runner)"; resume_target="$(state_get target)"; resume_step="$(state_get step)"
    [[ "$(state_get stage)" == compute && -n "$resume_runner" ]] && skipping=1
    while read -r runner target; do
        if (( skipping )); then
            if [[ "$runner $target" != "$resume_runner $resume_target" ]]; then
                info "Pass $runner -> $target already done."
                continue
            fi
            skipping=0
            local step="$resume_step"; [[ "$step" == precheck ]] && step=precheck_wait
            compute_pass "$runner" "$target" "$step"
        else
            compute_pass "$runner" "$target"
        fi
    done < <(compute_passes)
    # The first node rebooted in the last pass: wait until it answers before going on.
    while ! on "$NODE" true 2>/dev/null; do
        warn "$NODE is not answering yet after its upgrade; trying again."
        sleep "$COMPUTE_POLL_SECONDS"
    done
    info "All compute nodes are on $C_TARGET."
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
    [[ -z "$OEM_JOBS_DIR" || -d "$OEM_JOBS_DIR" ]] || die "OEM_JOBS_DIR not found: $OEM_JOBS_DIR"
    for c in ${OEM_JOBS_SUSPEND_CMD[0]-} ${OEM_JOBS_RESUME_CMD[0]-}; do
        ( if [[ -n "$OEM_JOBS_DIR" ]]; then cd "$OEM_JOBS_DIR" || exit 1; fi
          [[ -x "$c" ]] || command -v "$c" >/dev/null 2>&1 )             || die "OEM job command not found or not executable${OEM_JOBS_DIR:+ in $OEM_JOBS_DIR}: $c"
    done
    if [[ "${OEM_JOBS_SUSPEND_CMD[*]-} ${OEM_JOBS_RESUME_CMD[*]-}" == *"{jobs_db}"* ]]; then
        [[ -n "${OEM_JOBS_DB[$ZDLRA]:-}" ]]             || die "OEM_JOBS_DB[$ZDLRA] is not set in $CONFIG_FILE: the name the OEM jobs script uses for $ZDLRA (for example RA1GF2)."
        info "OEM jobs name for $ZDLRA: $(jobs_db)"
    fi
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
    if [[ "$STAGE" == compute ]]; then
        warn "Stopped watching. patchmgr keeps running on its compute node; nothing is stopped."
        warn "Watch again:     $0 -z $ZDLRA --watch $RUN_ID$(xflag)"
        warn "Watching again picks up the compute pass where it was, then carries on."
        print_undo
    elif [[ "$STAGE" == precheck ]]; then
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

# Start node phases ($1, space-separated) in the background on the patch node.
step_patch() {
    local phases="$1"
    info "== patch (on $NODE, background): $phases =="
    local opts="--run-id $RUN_ID --background"
    (( SKIP_BACKUP_WAIT )) && opts+=" --skip-backup-wait"
    if ! on_node "$(remote_cmd $opts $phases)"; then
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

    local stage="before"
    if [[ -n "$WATCH_RUN_ID" ]]; then
        RUN_ID="$WATCH_RUN_ID"
        STAGE="patch"
        stage="$(state_get stage)"; stage="${stage:-before}"
        info "Picking up run $RUN_ID at: $stage"
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
        state_set stage=before
        step_patch "$(phases_before)"
    fi

    # The node phases before compute, then compute from here, then the rest.
    if [[ "$stage" == before ]]; then
        watch_until_done >/dev/null || patch_failed
        if has_compute; then
            state_set stage=compute
            step_compute
            stage=after
            state_set stage=after
            if [[ -n "$(phases_after)" ]]; then
                STAGE="patch"
                step_patch "$(phases_after)"
            fi
        fi
    elif [[ "$stage" == compute ]]; then
        step_compute
        state_set stage=after
        STAGE="patch"
        [[ -z "$(phases_after)" ]] || step_patch "$(phases_after)"
    fi

    if watch_until_done >/dev/null; then
        state_set stage=done
        info "Run $RUN_ID completed on $NODE."
        step_jobs_resume
        step_blackout_stop
        info "Done. Report on $NODE: $REMOTE_SCRIPT -c $REMOTE_CONFIG --status --run-id $RUN_ID"
    else
        patch_failed
    fi
}

patch_failed() {
    err "Run $RUN_ID failed on $NODE. OEM jobs and the blackout are left as they are while you investigate."
    err "Details:         ssh ${SSH_USER}@${NODE} $REMOTE_SCRIPT -c $REMOTE_CONFIG --status --run-id $RUN_ID"
    print_undo
    exit 1
}

main "$@"
