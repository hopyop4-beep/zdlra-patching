#!/usr/bin/env bash
#
# zdlra_patch.sh - phased automation for Zero Data Loss Recovery Appliance (ZDLRA) patching
#
# STATUS: skeleton. Every phase logs what it would do; real commands run only with
# --execute, and several phases are still TODO. Check each racli command against the
# README that ships with your patch and the current Oracle patching note before use.
#
# Usage:
#   ./zdlra_patch.sh [options] <phase> [<phase> ...]
#   ./zdlra_patch.sh [options] all
#   ./zdlra_patch.sh --status [--run-id ID]
#
# Phases (run in this order by "all"; phases you list must keep this order):
#   precheck    appliance health and the external precheck script, then operator approval
#   quiesce     pause replication, wait for in-flight replication and incoming backups
#               to finish (needs an approved precheck)
#   snapshot    save configuration and state so you can compare after patching
#   ra_preinstall  racli run preinstall with the ZDLRA software from the staged
#               record (ra_release=). Must follow the precheck: the precheck rolls
#               back the RPM it installs
#   ra_alter    racli alter appliance --online_updates, with the gold images the
#               precheck put in /radump: installs the new grid and DB homes
#   ra_update   racli update appliance --ignore_incidents: patches the appliance
#               (about 2 hours). The three racli steps need an approved precheck,
#               run in a session of their own and are never cut short
#   cells       patch the storage cells with patchmgr from the cell patch folder,
#               then check every cell is on TARGET_CELL_VERSION (needs an approved
#               precheck)
#   postcheck   rerun health checks and compare with the snapshot
#   resume      resume the replication that quiesce paused
#   report      write a summary of this run
#
# Options:
#   -c, --config FILE   config file (default: ./zdlra_patch.conf)
#   -x, --execute       run commands for real (default is dry run)
#   -y, --yes           do not prompt before patch steps (precheck approval is still asked)
#   -b, --background    after precheck approval, run the remaining phases detached
#                       from the terminal, with no further prompts
#   -d, --detach        run only the precheck, detached from the terminal; approve it
#                       afterwards with --approve (for long prechecks)
#   -a, --approve       review and approve the precheck of --run-id ID (after --detach)
#   -r, --run-id ID     continue an existing run (reuses its folder and approval)
#       --continue      with --run-id: skip the phases this run already finished, so
#                       the one that failed runs again (racli update carries on where
#                       it stopped). Rerunning the precheck marks ra_preinstall as not
#                       done, because the precheck rolls back what it installed
#   -s, --status        show the state of the latest run, or of --run-id ID
#       --skip-backup-wait  quiesce does not wait for incoming backups to finish
#   -h, --help          show this help

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/${SCRIPT_NAME}"
VERSION="0.6.0"

ALL_PHASES=(precheck quiesce snapshot ra_preinstall ra_alter ra_update cells postcheck resume report)

# ---------------------------------------------------------------------------
# Defaults (override in the config file)
# ---------------------------------------------------------------------------
CONFIG_FILE="${SCRIPT_DIR}/zdlra_patch.conf"
DRY_RUN=1
ASSUME_YES=0
BACKGROUND=0
DETACH=0
APPROVE_MODE=0
BG_CHILD=0                      # set internally on the detached process
STATUS_MODE=0
FINAL_STATUS=""                 # status to record on success instead of "completed"
PRESERVE_STATUS=0               # 1 = a failure now leaves the run's status unchanged
SKIP_BACKUP_WAIT=0
CONTINUE=0

RACLI="/opt/oracle.RecoveryAppliance/bin/racli"
# Written by staging/zdlra_stage.sh once the patches and precheck are in place.
# It names the archive and the patch.conf_<SR> it set up (patch_conf=...).
STAGED_RECORD="/radump/patches/ZDLRA_STAGED.txt"
WORK_DIR="/radump/zdlra_patch_runs"
MIN_FREE_GB=50                  # free space needed in WORK_DIR's filesystem
REQUIRED_USER="root"

# External precheck script (e.g. the Oracle-supplied precheck). Not shipped in this repo.
# Oracle's precheck, run as ./precheck from its own folder. In PRECHECK_ARGS,
# {sr_number} is SR_NUMBER= from the conf file staging set up, and {patch_conf} is
# that conf file's path (both via the staged record).
PRECHECK_SCRIPT="/radump/patches/bin/precheck"   # full path; empty = skip with a warning
PRECHECK_ARGS=(-srnumber={sr_number})
PRECHECK_CWD=""                 # folder to run it from; empty = the script's own folder
# Added for the actual patching event (a run with --execute), not for dry runs.
PRECHECK_EVENT_ARGS=(-recheck_all)
PRECHECK_TIMEOUT=3600           # seconds before the precheck is killed
PRECHECK_SUMMARY_HEADER="FAILURE SUMMARY"   # failures are read from after this line
PRECHECK_FAIL_PATTERN='\[FAIL\]'            # extended regex for a failure line
PRECHECK_WARN_PATTERN='\[WARN\]'            # extended regex for a warning line
PRECHECK_WAIVERS=()             # failure names (substrings) accepted as known; logged, not fatal
PRECHECK_FAIL_ON_WARN=0         # 1 = treat warnings like failures (waivers apply)
PRECHECK_REQUIRED=1             # 1 = stop if PRECHECK_SCRIPT is not set
PRECHECK_REQUIRE_APPROVAL=1     # 1 = operator must type APPROVE after the precheck
PRECHECK_APPROVAL_MAX_AGE_HOURS=24   # patch steps refuse an approval older than this
POSTCHECK_RERUN_PRECHECK=1      # 1 = run the same script again after patching

# RA software upgrade (ra_preinstall, ra_alter, ra_update). In the arguments,
# {ra_release} is the ZDLRA software zip from the staged record (ra_release=) and
# {gold_images_path} is RA_GOLD_IMAGES_PATH. Each step runs in a session of its own
# and is never stopped by this script; past its WARN minutes a warning is logged.
RA_PREINSTALL_ARGS=(run preinstall --zdlra_release_file={ra_release})
RA_PREINSTALL_SUCCESS="End: ra_preinstall post cleanup"
RA_PREINSTALL_FAIL_RE='(CHECK|HOST):.*FAIL'     # any such line fails the step
RA_PREINSTALL_DONE_FILE="/root/.ra_preinstall.install"   # written by a good preinstall
RA_PREINSTALL_WARN_MINUTES=60
# The precheck moves the gold images (the first two FILES_RA files) here.
RA_GOLD_IMAGES_PATH="/radump/"
RA_ALTER_ARGS=(alter appliance --online_updates --gold_images_path={gold_images_path})
RA_ALTER_SUCCESS="End: Alter Appliance"
RA_ALTER_WARN_MINUTES=60        # about 13 minutes in one sample
RA_UPDATE_ARGS=(update appliance --ignore_incidents)
RA_UPDATE_SUCCESS="End: Patch Recovery Appliance - Step [Patch]"
RA_UPDATE_WARN_MINUTES=240      # about 2 hours in one sample

# Storage cells (cells phase). Runs from the first compute node, in the folder the
# cell patch (FILES_CELL) unzipped to under /radump/patches/tmp; the folder's name is
# read from the zip, as it changes with every release.
CELL_GROUP_FILE="/root/cell_group"
CELL_PATCH_TMP_DIR="/radump/patches/tmp"     # where staging unzipped the cell patch
CELL_PATCH_FILES_DIR="/radump/patches/patches"
# Run in this order before the patch itself.
CELL_PREP_STEPS=(-patch_check_prereq -reset_force -cleanup)
# Added to "patchmgr -cells <group> -patch", e.g. (-ignore_alerts) or
# (-smtp_from "addr" -smtp_to "addr1 addr2").
CELL_PATCH_EXTRA_ARGS=()
# patchmgr is never stopped by this script; past this long a warning is logged.
CELL_PATCH_WARN_MINUTES=360     # per patchmgr command (about 2 hours for 17 cells)
# TODO(site): check whether -patch should always use -ignore_alerts.
DCLI="dcli"

# SQL on the appliance, as the raAutomation account (see the config example).
SQLPLUS="sqlplus"
RA_SQL_CONNECT=""               # e.g. raAutomation/<password>; empty = SQL steps not set up
# Each query prints one value per line; the count queries print a single number.
# {server} in the statements is a remote_ra_dbname from REPLICATION_SERVERS_SQL.
# Replication to pause: every running upstream or paired replication server.
REPLICATION_SERVERS_SQL="select remote_ra_dbname from ra_replication_pair where upper(replication_server_state) = 'RUNNING' and upper(replication_server_role) in ('UPSTREAM','PAIRED');"
# Shown in the precheck review: every replication server with its state and role.
REPLICATION_STATUS_SQL="select remote_ra_dbname || '  state=' || replication_server_state || '  role=' || replication_server_role from ra_replication_pair;"
# Pause/resume each one by its remote_ra_dbname.
REPLICATION_PAUSE_SQL="begin dbms_ra.pause_replication_server(replication_server_name => '{server}'); end;"
REPLICATION_RESUME_SQL="begin dbms_ra.resume_replication_server(replication_server_name => '{server}'); end;"
ACTIVE_REPLICATION_SQL=""       # count of replication still in flight
# Incoming backups: active RMAN sessions on the appliance database, on all instances
# (idle sessions that are only connected are not counted).
ACTIVE_BACKUPS_SQL="select count(*) from gv\$session s where s.status = 'ACTIVE' and (lower(s.program) like '%rman%' or lower(s.module) like '%rman%');"
# The same sessions, one per line: shown in the precheck review and when the wait gives up.
ACTIVE_BACKUPS_LIST_SQL="select 'inst=' || s.inst_id || ' sid=' || s.sid || ',' || s.serial# || '  ' || s.program || '  machine=' || s.machine || '  event=' || s.event || '  wait=' || s.seconds_in_wait || 's' from gv\$session s where s.status = 'ACTIVE' and (lower(s.program) like '%rman%' or lower(s.module) like '%rman%') order by s.inst_id, s.sid;"
QUIESCE_POLL_SECONDS=60
QUIESCE_TIMEOUT_MINUTES=120     # give up waiting after this long
QUIESCE_WAIT_FOR_BACKUPS=1      # 0 = do not wait for incoming backups (same as --skip-backup-wait)
QUIESCE_ALLOW_UNCONFIGURED=0    # 1 = a real run may continue with these SQL settings empty

RUN_ID=""
RUN_DIR=""
LOG_FILE=""
LOCK_FILE="/tmp/zdlra_patch.lock"
LOCK_HELD=0
LOCK_HANDED_OFF=0
CURRENT_PHASE="setup"
BG_PHASES=()

# ---------------------------------------------------------------------------
# Logging and helpers
# ---------------------------------------------------------------------------
log()  { local lvl="$1"; shift; printf '%s [%-5s] %s\n' "$(date '+%F %T')" "$lvl" "$*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
err()  { log ERROR "$@"; }
die()  { err "$@"; exit 1; }

# Print the comment block at the top of this file.
usage() { awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"; }

# Run a command, or only log it in dry-run mode. Output goes to the run log.
run() {
    if (( DRY_RUN )); then
        info "[dry-run] $*"
        return 0
    fi
    info "[exec] $*"
    "$@" 2>&1 | tee -a "$LOG_FILE"
    return "${PIPESTATUS[0]}"
}

# Read-only commands run even in dry-run mode so prechecks give real answers.
run_ro() {
    info "[read] $*"
    "$@" 2>&1 | tee -a "$LOG_FILE"
    return "${PIPESTATUS[0]}"
}

confirm() {
    (( ASSUME_YES || DRY_RUN )) && return 0
    local reply=""
    read -r -p "$1 [type YES to continue]: " reply || true    # no input counts as "no"
    [[ "$reply" == "YES" ]] || die "Aborted by operator."
}

# One-line state of the run in <run dir>/status, read by --status.
set_status() {
    [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]] || return 0
    printf '%s  %s\n' "$(date '+%F %T')" "$*" > "${RUN_DIR}/status"
}

on_error() {
    err "Failed at line $1 (exit $2). Log: ${LOG_FILE:-none}"
}
trap 'on_error $LINENO $?' ERR

# Record the outcome in the run's status. A failure is recorded only when a phase had
# started: an invocation that stops during setup (e.g. the lock is held by a running
# job) or on a refused approval check must not overwrite the status of the run.
on_exit() {
    local rc=$?
    # A detached command (patchmgr, racli) still running: leave it, say so, hand it the lock.
    if (( ! STATUS_MODE && ! LOCK_HANDED_OFF )) && detached_leave_running; then
        return
    fi
    if (( ! STATUS_MODE && ! LOCK_HANDED_OFF )); then
        if (( rc == 0 )); then
            if [[ -n "$FINAL_STATUS" ]]; then set_status "$FINAL_STATUS"
            elif (( ! PRESERVE_STATUS )); then set_status "completed"; fi
        elif [[ "$CURRENT_PHASE" != setup ]] && (( ! PRESERVE_STATUS )); then
            set_status "failed in ${CURRENT_PHASE} (exit $rc)"
        fi
    fi
    if (( LOCK_HELD && ! LOCK_HANDED_OFF )); then rm -f "$LOCK_FILE"; fi
}
trap on_exit EXIT

# Take the lock. A detached process takes it over from the process that started it:
# that process writes the detached pid into the lock before exiting, so the lock is
# never left looking stale in between. A lock whose process is gone is stale.
acquire_lock() {
    if [[ -e "$LOCK_FILE" ]]; then
        local owner
        owner="$(cat "$LOCK_FILE" 2>/dev/null || true)"
        if [[ -n "${ZDLRA_LOCK_FROM:-}" && ( "$owner" == "$ZDLRA_LOCK_FROM" || "$owner" == "$$" ) ]]; then
            info "Taking over the lock from pid $owner."
        elif [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null; then
            die "Lock file $LOCK_FILE is held by running pid $owner. Is another run active?"
        else
            warn "Removing stale lock file $LOCK_FILE (pid ${owner:-?} is not running)."
        fi
    fi
    echo $$ > "$LOCK_FILE"
    LOCK_HELD=1
}

# Phases this run has finished (real runs only), one per line in <run dir>/phases_done,
# so --continue can skip them.
phase_done() { [[ -f "${RUN_DIR}/phases_done" ]] && grep -qxF "$1" "${RUN_DIR}/phases_done"; }
phase_mark_done() {
    (( DRY_RUN )) && return 0
    phase_done "$1" || echo "$1" >> "${RUN_DIR}/phases_done"
}
phase_undone() {
    phase_done "$1" || return 0
    sed -i "/^$1\$/d" "${RUN_DIR}/phases_done"
    info "$1 is marked as not done: it runs again."
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
phase_index() {
    local i
    for i in "${!ALL_PHASES[@]}"; do
        [[ "${ALL_PHASES[$i]}" == "$1" ]] && { echo "$i"; return 0; }
    done
    return 1
}

parse_args() {
    PHASES=()
    while (( $# )); do
        case "$1" in
            -c|--config)     CONFIG_FILE="$2"; shift 2 ;;
            -x|--execute)    DRY_RUN=0; shift ;;
            -y|--yes)        ASSUME_YES=1; shift ;;
            -b|--background) BACKGROUND=1; shift ;;
            -d|--detach)     DETACH=1; shift ;;
            -a|--approve)    APPROVE_MODE=1; shift ;;
            -r|--run-id)     RUN_ID="$2"; shift 2 ;;
            --skip-backup-wait) SKIP_BACKUP_WAIT=1; shift ;;
            --continue)      CONTINUE=1; shift ;;
            -s|--status)     STATUS_MODE=1; shift ;;
            --bg-child)      BG_CHILD=1; ASSUME_YES=1; shift ;;
            -h|--help)       usage; exit 0 ;;
            all)             PHASES+=("${ALL_PHASES[@]}"); shift ;;
            -*)              die "Unknown option: $1" ;;
            *)               PHASES+=("$1"); shift ;;
        esac
    done
    (( STATUS_MODE )) && return 0
    if (( APPROVE_MODE )); then
        [[ -n "$RUN_ID" ]] || die "--approve needs --run-id ID"
        (( ${#PHASES[@]} == 0 )) || die "--approve takes no phases."
        return 0
    fi
    (( ${#PHASES[@]} )) || { usage; exit 1; }
    (( ! CONTINUE )) || [[ -n "$RUN_ID" ]] || die "--continue needs --run-id ID"
    if (( DETACH )); then
        [[ "${PHASES[*]}" == precheck ]] || die "--detach runs the precheck only: $SCRIPT_NAME --detach precheck"
        (( ! BACKGROUND )) || die "Use --detach or --background, not both."
    fi
    local p idx last=-1
    for p in "${PHASES[@]}"; do
        idx="$(phase_index "$p")" || die "Unknown phase: $p"
        (( idx > last )) || die "Phases must be listed once each, in this order: ${ALL_PHASES[*]}"
        last=$idx
    done
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        config_password_check
    else
        warn "Config file $CONFIG_FILE not found; using built-in defaults."
    fi
    CONFIG_FILE="$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$(basename "$CONFIG_FILE")"
}

# RA_SQL_CONNECT may hold a password (user/password): then only root should be able
# to read the config. Warn if group or others can read it.
config_password_check() {
    [[ "$RA_SQL_CONNECT" == [!/]*/?* ]] || return 0
    local mode
    mode="$(stat -c %a "$CONFIG_FILE" 2>/dev/null)" || return 0
    if (( (8#$mode & 8#077) != 0 )); then
        warn "$CONFIG_FILE holds a password (RA_SQL_CONNECT) but has mode $mode; run: chmod 600 $CONFIG_FILE"
    fi
}

init_run() {
    if [[ -n "$RUN_ID" ]]; then
        RUN_DIR="${WORK_DIR}/${RUN_ID}"
        [[ -d "$RUN_DIR" ]] || die "No run folder for --run-id $RUN_ID in $WORK_DIR"
    else
        RUN_ID="$(date +%Y%m%d_%H%M%S)"
        RUN_DIR="${WORK_DIR}/${RUN_ID}"
        mkdir -p "$RUN_DIR"
    fi
    LOG_FILE="${RUN_DIR}/zdlra_patch.log"
    info "$SCRIPT_NAME $VERSION  run=$RUN_ID  dry_run=$DRY_RUN  background=$BACKGROUND  phases=${PHASES[*]}"
    (( BG_CHILD )) && info "Running detached as pid $$."
    [[ "$(id -un)" == "$REQUIRED_USER" ]] || die "Run as $REQUIRED_USER (current: $(id -un))."
    [[ -x "$RACLI" ]] || die "racli not found at $RACLI"
}

# --status: show the state, background process and recent log of a run.
show_status() {
    local dir
    if [[ -n "$RUN_ID" ]]; then
        dir="${WORK_DIR}/${RUN_ID}"
    else
        dir="$(ls -1d "${WORK_DIR}"/*/ 2>/dev/null | sort | tail -1)"
        dir="${dir%/}"
    fi
    [[ -n "$dir" && -d "$dir" ]] || die "No runs found in $WORK_DIR"
    echo "Run:     $(basename "$dir")"
    echo "Folder:  $dir"
    echo "Status:  $(cat "${dir}/status" 2>/dev/null || echo unknown)"
    [[ -s "${dir}/phases_done" ]] && echo "Done:    $(paste -sd' ' "${dir}/phases_done")"
    if [[ -f "${dir}/background.pid" ]]; then
        local pid
        pid="$(cat "${dir}/background.pid")"
        if kill -0 "$pid" 2>/dev/null; then echo "Process: pid $pid is running"; else echo "Process: pid $pid has finished"; fi
    fi
    if [[ -f "${dir}/precheck_approval.txt" ]]; then
        echo "Approval:"
        sed 's/^/  /' "${dir}/precheck_approval.txt"
    fi
    echo "Last log lines:"
    tail -n 15 "${dir}/zdlra_patch.log" 2>/dev/null | sed 's/^/  /'
}

# ---------------------------------------------------------------------------
# External precheck
# ---------------------------------------------------------------------------
# Write the summary lines matching a pattern to <lines_file>, and the names alone
# (everything up to the tag removed) sorted to <names_file>.
# $1 = summary text, $2 = pattern, $3 = lines_file, $4 = names_file
extract_summary_items() {
    grep -E "$2" <<<"$1" > "$3" || true
    sed -E "s/.*${2}[[:space:]]*//; s/[[:space:]]+$//" "$3" | LC_ALL=C sort -u > "$4"
}

# Log what changed between the before and after name lists.
# $1 = before names file, $2 = after names file, $3 = "failure" or "warning"
log_item_changes() {
    [[ -f "$1" ]] || return 0
    local name
    LC_ALL=C comm -13 "$1" "$2" | while IFS= read -r name; do warn "  new $3 since before patching: $name"; done
    LC_ALL=C comm -23 "$1" "$2" | while IFS= read -r name; do info "  $3 resolved by patching: $name"; done
}

# Run the external precheck script. It is read-only, so it runs in dry-run mode too.
# Failures and warnings are read from the lines after PRECHECK_SUMMARY_HEADER, e.g.
#   FAILURE SUMMARY
#   ***********************************
#   <date> [FAIL] <failure name>
#   <date> [WARN] <warning name>
# The phase fails on any failure not listed in PRECHECK_WAIVERS (and on warnings too
# when PRECHECK_FAIL_ON_WARN=1), a timeout, or a non-zero exit code with no summary.
# Files written to precheck_<label>/:
#   output.txt          full output
#   failures.txt        failure lines from the summary
#   failure_names.txt   failure names only (date and tag removed), sorted
#   warnings.txt        warning lines from the summary
#   warning_names.txt   warning names only, sorted
# $1 = label for the output folder (before/after)
run_external_precheck() {
    local label="$1"
    if [[ -z "$PRECHECK_SCRIPT" ]]; then
        (( PRECHECK_REQUIRED )) && die "PRECHECK_SCRIPT is not set in the config."
        warn "PRECHECK_SCRIPT is not set; skipping external precheck."
        return 0
    fi
    [[ -x "$PRECHECK_SCRIPT" ]] || die "Precheck script not found or not executable: $PRECHECK_SCRIPT"

    local out_dir="${RUN_DIR}/precheck_${label}"
    local out_file="${out_dir}/output.txt"
    mkdir -p "$out_dir"
    # {patch_conf} -> the conf file staging set up for this appliance;
    # {sr_number} -> SR_NUMBER= in that conf file.
    local args=() a conf sr=""
    conf="$(staged_value patch_conf)"
    if [[ " ${PRECHECK_ARGS[*]-} " == *"{sr_number}"* ]]; then
        [[ -n "$conf" ]] || die "PRECHECK_ARGS uses {sr_number}, but the staged record names no patch_conf."
        [[ -f "$conf" ]] || die "Conf file from the staged record not found: $conf"
        sr="$(sed -n 's/^SR_NUMBER=//p' "$conf" | head -1 | tr -d '\r' | sed -E "s/^[\"']//; s/[\"']$//; s/[[:space:]]+$//")"
        [[ -n "$sr" ]] || die "No SR_NUMBER= in $conf."
        [[ "$sr" =~ ^[A-Za-z0-9-]+$ ]] || die "Unexpected SR_NUMBER in $conf: $sr"
    fi
    for a in ${PRECHECK_ARGS[@]+"${PRECHECK_ARGS[@]}"}; do
        if [[ "$a" == *"{patch_conf}"* ]]; then
            [[ -n "$conf" ]] || die "PRECHECK_ARGS uses {patch_conf}, but the staged record names no patch_conf."
            a="${a//\{patch_conf\}/$conf}"
        fi
        a="${a//\{sr_number\}/$sr}"
        args+=("$a")
    done
    # The actual patching event (--execute) checks everything again.
    if (( ! DRY_RUN )); then
        args+=(${PRECHECK_EVENT_ARGS[@]+"${PRECHECK_EVENT_ARGS[@]}"})
    fi
    local cwd="${PRECHECK_CWD:-$(dirname "$PRECHECK_SCRIPT")}" cmd="./$(basename "$PRECHECK_SCRIPT")"
    [[ -n "$PRECHECK_CWD" ]] && cmd="$PRECHECK_SCRIPT"
    info "Running precheck ($label): cd $cwd && $cmd ${args[*]-} (timeout ${PRECHECK_TIMEOUT}s)"

    local rc=0
    ( cd "$cwd" && timeout "$PRECHECK_TIMEOUT" "$cmd" ${args[@]+"${args[@]}"} ) \
        > "$out_file" 2>&1 || rc=$?
    info "Precheck output: $out_file (exit code $rc)"
    (( rc == 124 )) && die "Precheck timed out after ${PRECHECK_TIMEOUT}s."

    # Use the last summary section (colour codes removed). If the header is
    # missing, fall back to searching the whole output.
    local plain summary have_summary=0
    plain="$(sed 's/\x1b\[[0-9;]*m//g' "$out_file")"
    if grep -qF "$PRECHECK_SUMMARY_HEADER" <<<"$plain"; then
        have_summary=1
        summary="$(awk -v h="$PRECHECK_SUMMARY_HEADER" 'index($0, h) { buf = ""; next } { buf = buf $0 "\n" } END { printf "%s", buf }' <<<"$plain")"
    else
        warn "No '$PRECHECK_SUMMARY_HEADER' section found; searching the whole output."
        summary="$plain"
    fi
    extract_summary_items "$summary" "$PRECHECK_FAIL_PATTERN" "${out_dir}/failures.txt" "${out_dir}/failure_names.txt"
    extract_summary_items "$summary" "$PRECHECK_WARN_PATTERN" "${out_dir}/warnings.txt" "${out_dir}/warning_names.txt"

    # Each entry is "<tag> <name>"; a warning blocks only when PRECHECK_FAIL_ON_WARN=1.
    local tag name waiver blocking=0 waived=0 warnings=0
    while read -r tag name; do
        if [[ "$tag" == WARN ]] && (( ! PRECHECK_FAIL_ON_WARN )); then
            warn "  [WARN] $name"
            warnings=$((warnings + 1))
            continue
        fi
        for waiver in ${PRECHECK_WAIVERS[@]+"${PRECHECK_WAIVERS[@]}"}; do
            if [[ "$name" == *"$waiver"* ]]; then
                warn "  [waived $tag] $name"
                waived=$((waived + 1))
                continue 2
            fi
        done
        err "  [$tag] $name"
        blocking=$((blocking + 1))
    done < <(sed 's/^/FAIL /' "${out_dir}/failure_names.txt"; sed 's/^/WARN /' "${out_dir}/warning_names.txt")
    info "Precheck ($label): $blocking blocking, $waived waived, $warnings warning(s). Lists: $out_dir"

    if [[ "$label" == after ]]; then
        log_item_changes "${RUN_DIR}/precheck_before/failure_names.txt" "${out_dir}/failure_names.txt" failure
        log_item_changes "${RUN_DIR}/precheck_before/warning_names.txt" "${out_dir}/warning_names.txt" warning
    fi

    (( blocking == 0 )) || die "Precheck ($label) found $blocking blocking item(s) that are not waived."
    # With a summary, the summary decides: the script may exit non-zero for warnings or waived failures.
    if (( rc != 0 )); then
        (( have_summary )) || die "Precheck exited with code $rc and printed no summary. See $out_file"
        warn "Precheck exited with code $rc; nothing in its summary is blocking."
    fi
    info "Precheck ($label) passed."
}

# ---------------------------------------------------------------------------
# Operator approval of the precheck
# ---------------------------------------------------------------------------
# Fingerprint of the before-patching results, so an approval only covers what was reviewed.
# It includes the staged archive, so re-staging a different bundle after approval is caught.
precheck_fingerprint() {
    { cat "${RUN_DIR}/precheck_before/failure_names.txt" "${RUN_DIR}/precheck_before/warning_names.txt" 2>/dev/null
      echo "staged=$(staged_value sha256)"; } \
        | sha256sum | cut -d' ' -f1
}

# A field from the staged record (archive, sha256, staged_at, ...), or empty.
staged_value() { sed -n "s/^$1=//p" "$STAGED_RECORD" 2>/dev/null | head -1; }

# Ask the operator to accept the precheck results and record who did, and when.
# --yes does not skip this; it needs a terminal.
approve_precheck() {
    (( PRECHECK_REQUIRE_APPROVAL )) || return 0
    # A detached precheck has nobody to ask: record that it is waiting instead.
    if (( BG_CHILD )); then
        FINAL_STATUS="awaiting approval: precheck finished; approve with --approve --run-id $RUN_ID"
        info "Precheck finished. Approve it with: $SCRIPT_PATH -c $CONFIG_FILE --approve --run-id $RUN_ID"
        return 0
    fi
    [[ -t 0 ]] || die "Precheck approval needs an interactive terminal."
    local dir="${RUN_DIR}/precheck_before" fails=0 warns=0 name
    [[ -f "${dir}/failure_names.txt" ]] && fails=$(wc -l < "${dir}/failure_names.txt")
    [[ -f "${dir}/warning_names.txt" ]] && warns=$(wc -l < "${dir}/warning_names.txt")

    {
        echo
        echo "================ PRECHECK REVIEW ================"
        echo "Run:          $RUN_ID   (dry run: $DRY_RUN)"
        echo "Failures:     $fails (all waived, or the precheck would have stopped)"
        [[ -s "${dir}/failure_names.txt" ]] && while IFS= read -r name; do echo "  [FAIL] $name"; done < "${dir}/failure_names.txt"
        echo "Warnings:     $warns"
        [[ -s "${dir}/warning_names.txt" ]] && while IFS= read -r name; do echo "  [WARN] $name"; done < "${dir}/warning_names.txt"
        echo "Full output:  ${dir}/output.txt"
        echo "Staged:       $(staged_value archive) (staged $(staged_value staged_at))"
        echo "  SHA-256     $(staged_value sha256)"
        if (( ${#BG_PHASES[@]} )); then
            echo
            echo "After approval these phases run in the BACKGROUND with NO further prompts:"
            echo "  ${BG_PHASES[*]}"
        fi
        echo "================================================="
    } >&2

    local reply
    read -r -p "Review the precheck output, then type APPROVE to continue: " reply
    [[ "$reply" == "APPROVE" ]] || die "Precheck not approved."

    local approver="${SUDO_USER:-$(logname 2>/dev/null || id -un)}"
    {
        echo "approved_by=$approver"
        echo "approved_at=$(date '+%F %T %Z')"
        echo "approved_epoch=$(date +%s)"
        echo "host=$(hostname)"
        echo "failures=$fails"
        echo "warnings=$warns"
        echo "fingerprint=$(precheck_fingerprint)"
    } > "${RUN_DIR}/precheck_approval.txt"
    info "Precheck approved by $approver."
}

# Patch steps call this: the run must have an approved, recent, unchanged precheck.
require_approval() {
    (( PRECHECK_REQUIRE_APPROVAL )) || return 0
    # Refusing here changes nothing, so it must not mark the run as failed.
    PRESERVE_STATUS=1
    local f="${RUN_DIR}/precheck_approval.txt"
    [[ -f "$f" ]] || die "Run $RUN_ID has no approved precheck. Run precheck first, or pass --run-id of an approved run."
    local by epoch fp age max
    by="$(sed -n 's/^approved_by=//p' "$f")"
    epoch="$(sed -n 's/^approved_epoch=//p' "$f")"
    fp="$(sed -n 's/^fingerprint=//p' "$f")"
    age=$(( $(date +%s) - epoch ))
    max=$(( PRECHECK_APPROVAL_MAX_AGE_HOURS * 3600 ))
    (( age <= max )) || die "Precheck approval is $(( age / 3600 ))h old (limit ${PRECHECK_APPROVAL_MAX_AGE_HOURS}h). Run precheck again."
    [[ "$fp" == "$(precheck_fingerprint)" ]] || die "Precheck results or the staged archive changed after approval. Run precheck again."
    info "Precheck approved by $by, $(( age / 60 )) minute(s) ago."
    PRESERVE_STATUS=0
}

# ---------------------------------------------------------------------------
# SQL on the appliance (raAutomation)
# ---------------------------------------------------------------------------
sql_ready() { [[ -n "$RA_SQL_CONNECT" && "$RA_SQL_CONNECT" != *"<password>"* ]]; }

# Run SQL as raAutomation and print the result rows, trimmed. Fails on ORA-/SP2- errors.
# The connect string is passed on stdin, so it never shows in the process list.
sql_rows() {
    local out
    out="$("$SQLPLUS" -S -L /nolog <<EOF
whenever sqlerror exit failure
connect $RA_SQL_CONNECT
set heading off feedback off pagesize 0 linesize 400 trimspool on verify off
$1
exit
EOF
)" || { err "SQL failed: $1"; printf '%s\n' "$out" | sed 's/^/  /' >&2; return 1; }
    if grep -qE '^(ORA|SP2)-[0-9]+' <<<"$out"; then
        err "SQL error: $1"; printf '%s\n' "$out" | sed 's/^/  /' >&2; return 1
    fi
    sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; /^$/d' <<<"$out"
}

# A count query must print one whole number.
sql_count() {
    local n
    n="$(sql_rows "$1")" || return 1
    [[ "$n" =~ ^[0-9]+$ ]] || { err "Expected a number from: $1 (got: $n)"; return 1; }
    echo "$n"
}

# Statements that change something go through dry-run handling like run().
sql_exec() {
    if (( DRY_RUN )); then
        info "[dry-run] SQL: $1"
        return 0
    fi
    info "[exec] SQL: $1"
    sql_rows "$1" >/dev/null
}

# Which SQL settings are still empty (TODO placeholders).
missing_sql_settings() {
    local v missing=()
    for v in RA_SQL_CONNECT REPLICATION_SERVERS_SQL REPLICATION_PAUSE_SQL REPLICATION_RESUME_SQL \
             ACTIVE_REPLICATION_SQL ACTIVE_BACKUPS_SQL; do
        [[ -n "${!v}" ]] || missing+=("$v")
    done
    # The example's placeholder password counts as not filled in.
    [[ "$RA_SQL_CONNECT" != *"<password>"* ]] || missing+=("RA_SQL_CONNECT(password)")
    echo "${missing[*]-}"
}

# Read-only summary for the precheck review: what quiesce will pause and wait for.
report_activity() {
    local missing
    missing="$(missing_sql_settings)"
    if [[ -n "$missing" ]]; then
        warn "Replication/backup checks not set up yet (TODO in config: $missing)."
        return 0
    fi
    local servers n line
    if [[ -n "${REPLICATION_STATUS_SQL:-}" ]]; then
        servers="$(sql_rows "$REPLICATION_STATUS_SQL")" || die "Could not read the replication configuration."
        info "Replication pairs (ra_replication_pair):"
        while IFS= read -r line; do info "    $line"; done <<<"${servers:-(no replication servers)}"
    fi
    servers="$(sql_rows "$REPLICATION_SERVERS_SQL")" || die "Could not list replication servers."
    info "Replication servers to pause (running, upstream or paired): $(tr '\n' ' ' <<<"${servers:-none}")"
    n="$(sql_count "$ACTIVE_REPLICATION_SQL")" || die "Could not count active replication."
    info "Replication in flight now: $n"
    n="$(sql_count "$ACTIVE_BACKUPS_SQL")" || die "Could not count incoming backups."
    info "Incoming backups running now: $n"
    (( n == 0 )) || show_rows "Incoming backup sessions:" "${ACTIVE_BACKUPS_LIST_SQL:-}"
}

# Print the rows of an optional listing query under a heading (read only; never fails).
show_rows() {
    local heading="$1" query="$2" rows line
    [[ -n "$query" ]] || return 0
    rows="$(sql_rows "$query")" || { warn "Could not list: $heading"; return 0; }
    info "$heading"
    while IFS= read -r line; do [[ -n "$line" ]] && info "    $line"; done <<<"$rows"
    return 0
}

# Poll a count query until it reaches 0 or the timeout passes.
# $1 = label, $2 = count query, $3 = optional listing query shown if the wait gives up
wait_for_zero() {
    local label="$1" query="$2" list="${3:-}" n waited=0 limit=$(( QUIESCE_TIMEOUT_MINUTES * 60 ))
    while :; do
        n="$(sql_count "$query")" || die "Could not count $label."
        if (( n == 0 )); then
            info "No $label running."
            return 0
        fi
        if (( waited >= limit )); then
            show_rows "Still running ($label):" "$list"
            die "$n $label still running after ${QUIESCE_TIMEOUT_MINUTES} min. Stopping before patching."
        fi
        info "Waiting: $n $label running (${waited}s of ${limit}s)"
        if (( DRY_RUN )); then
            info "[dry-run] would keep waiting for $label to finish"
            return 0
        fi
        sleep "$QUIESCE_POLL_SECONDS"
        waited=$(( waited + QUIESCE_POLL_SECONDS ))
    done
}

# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------
phase_precheck() {
    info "== precheck =="
    run_ro "$RACLI" version || warn "racli version failed"
    run_ro "$RACLI" status appliance || die "Appliance status check failed"

    # What is being patched: staging/zdlra_stage.sh leaves this record once the patches
    # and the precheck are in place. Oracle's precheck checks the files themselves.
    if [[ -n "$STAGED_RECORD" ]]; then
        [[ -f "$STAGED_RECORD" ]] || die "No staged record at $STAGED_RECORD. Stage the patches first (staging/zdlra_stage.sh)."
        info "Staged archive: $(staged_value archive), SHA-256 $(staged_value sha256), staged $(staged_value staged_at)"
    else
        warn "STAGED_RECORD is not set; not checking what was staged."
    fi

    # The precheck rolls back the RPM ra_preinstall installs, so preinstall must run
    # again, unless the upgrade has already finished (ra_update done).
    phase_done ra_update || phase_undone ra_preinstall
    run_external_precheck before

    local free_gb
    free_gb=$(df -BG --output=avail "$WORK_DIR" | tail -1 | tr -dc '0-9')
    info "Free space for $WORK_DIR: ${free_gb}G (need ${MIN_FREE_GB}G)"
    (( free_gb >= MIN_FREE_GB )) || die "Not enough free space."

    # Read-only look at what quiesce will deal with, so it is part of the review.
    report_activity
    report_ra_plan
    report_cell_plan

    # TODO: confirm the patch is valid for the current version (compare racli version with patch README).

    # Marks the precheck as passed, so a detached precheck can be approved later with --approve.
    touch "${RUN_DIR}/precheck_passed"
    approve_precheck
}

# Pauses the running upstream/paired replication (REPLICATION_SERVERS_SQL), then waits
# for in-flight replication and incoming backups (RMAN sessions). TODO(site): the in-flight
# replication count (ACTIVE_REPLICATION_SQL) is still to be filled in.
phase_quiesce() {
    info "== quiesce =="
    local missing
    missing="$(missing_sql_settings)"
    if [[ -n "$missing" ]]; then
        if (( DRY_RUN || QUIESCE_ALLOW_UNCONFIGURED )); then
            warn "Quiesce not set up yet (TODO in config: $missing); skipping."
            return 0
        fi
        die "Quiesce is not set up (TODO in config: $missing). Fill these in, or set QUIESCE_ALLOW_UNCONFIGURED=1 to patch without it."
    fi

    # Pause each active replication server, and record it so resume undoes only these.
    local servers server paused="${RUN_DIR}/replication_paused.txt"
    local name_re='^[A-Za-z0-9_.$#-]+$'    # in a variable: inside [[ =~ ]] bash would expand $#
    servers="$(sql_rows "$REPLICATION_SERVERS_SQL")" || die "Could not list replication servers."
    touch "$paused"
    while IFS= read -r server; do
        [[ -n "$server" ]] || continue
        [[ "$server" =~ $name_re ]] || die "Unexpected replication server name: $server"
        if grep -qxF "$server" "$paused"; then
            info "Replication server $server already paused by this run."
            continue
        fi
        sql_exec "${REPLICATION_PAUSE_SQL//\{server\}/$server}" || die "Could not pause replication server $server."
        (( DRY_RUN )) || echo "$server" >> "$paused"
        info "Paused replication server $server"
    done <<<"$servers"

    wait_for_zero "replication tasks" "$ACTIVE_REPLICATION_SQL"

    if (( SKIP_BACKUP_WAIT || ! QUIESCE_WAIT_FOR_BACKUPS )); then
        local n
        n="$(sql_count "$ACTIVE_BACKUPS_SQL")" || n="?"
        warn "Not waiting for incoming backups (override); $n running now."
    else
        wait_for_zero "incoming backups" "$ACTIVE_BACKUPS_SQL" "${ACTIVE_BACKUPS_LIST_SQL:-}"
    fi
}

phase_resume() {
    info "== resume =="
    local paused="${RUN_DIR}/replication_paused.txt" server
    if [[ ! -s "$paused" ]]; then
        info "This run paused no replication servers; nothing to resume."
        return 0
    fi
    [[ -n "$REPLICATION_RESUME_SQL" ]] || die "REPLICATION_RESUME_SQL is not set; resume these by hand: $(tr '\n' ' ' < "$paused")"
    while IFS= read -r server; do
        [[ -n "$server" ]] || continue
        sql_exec "${REPLICATION_RESUME_SQL//\{server\}/$server}" || die "Could not resume replication server $server."
        info "Resumed replication server $server"
    done < "$paused"
    (( DRY_RUN )) || mv "$paused" "${paused%.txt}_resumed_$(date +%Y%m%d_%H%M%S).txt"
    # TODO: confirm replication catches up and backups arrive again.
}

phase_snapshot() {
    info "== snapshot =="
    local snap="${RUN_DIR}/snapshot_before"
    mkdir -p "$snap"
    run_ro "$RACLI" version          > "${snap}/racli_version.txt"  2>&1 || true
    run_ro "$RACLI" status appliance > "${snap}/racli_status.txt"   2>&1 || true
    # TODO: capture CRS resource state (crsctl stat res -t), listener status, DB parameters,
    #       storage locations, protection policies, and replication config.
    info "Snapshot saved to $snap"
}

# ---------------------------------------------------------------------------
# RA software upgrade
# ---------------------------------------------------------------------------
# The ZDLRA software zip (racli run preinstall) and the gold images, from the staged
# record. The gold images are named there where staging put them; the precheck moves
# them to RA_GOLD_IMAGES_PATH.
ra_release_file() { staged_value ra_release; }
ra_gold_image_names() { staged_value ra_gold_images | tr ',' '\n' | sed 's#.*/##' | sed '/^$/d'; }

# Gold images missing from RA_GOLD_IMAGES_PATH, one per line (empty = all there).
ra_gold_images_missing() {
    local name
    while IFS= read -r name; do
        [[ -f "${RA_GOLD_IMAGES_PATH%/}/$name" ]] || echo "$name"
    done < <(ra_gold_image_names)
}

# Fill in {ra_release} and {gold_images_path}; prints one argument per line.
ra_args() {
    local a rel
    rel="$(ra_release_file)"
    for a in "$@"; do
        a="${a//\{ra_release\}/$rel}"
        printf '%s\n' "${a//\{gold_images_path\}/$RA_GOLD_IMAGES_PATH}"
    done
}

# For the precheck review: what the RA steps will use. Read only; never fatal.
report_ra_plan() {
    local rel names missing
    rel="$(ra_release_file)"
    if [[ -z "$rel" ]]; then
        warn "RA upgrade:   the staged record names no ra_release (stage again with the current staging script)"
    elif [[ -f "$rel" ]]; then
        info "RA software:  $rel"
    else
        warn "RA software:  $rel not found"
    fi
    names="$(ra_gold_image_names | paste -sd' ')"
    missing="$(ra_gold_images_missing | paste -sd' ')"
    info "Gold images:  ${names:-<none in the staged record>} (in ${RA_GOLD_IMAGES_PATH})"
    [[ -z "$missing" ]] || warn "Gold images not in ${RA_GOLD_IMAGES_PATH}: $missing (the precheck should have moved them there)"
    info "RA target:    $(conf_value TARGET_RA_VERSION || true)"
}

# A setting from the conf file staging set up (patch_conf in the staged record).
conf_value() {
    local conf
    conf="$(staged_value patch_conf)"
    [[ -f "$conf" ]] || return 1
    sed -n "s/^$1=//p" "$conf" | head -1 | tr -d '\r' | sed -E "s/^[\"']//; s/[\"']$//; s/[[:space:]]+$//"
}

# Run one racli step, never cut short (run_detached), then check its log.
# $1 = step name (log ra_<name>.log), $2 = WARN minutes, $3 = success line, rest = racli arguments
run_racli_step() {
    local name="$1" warn_min="$2" success="$3"; shift 3
    local log="${RUN_DIR}/ra_${name}.log"
    run_detached "racli $name" "$RUN_DIR" "$log" "$warn_min" "$RACLI" "$@"
    (( DETACHED_RC == 0 )) || die "racli $name exited with code $DETACHED_RC. Log: $log"
    grep -qF "$success" "$log" || die "racli $name did not report '$success'. Log: $log"
    info "racli $name: completed ('$success')."
}

phase_ra_preinstall() {
    info "== RA pre-install =="
    local rel args=()
    rel="$(ra_release_file)"
    [[ -n "$rel" ]] || die "The staged record has no ra_release (the ZDLRA software zip). Stage again with the current staging script."
    mapfile -t args < <(ra_args "${RA_PREINSTALL_ARGS[@]}")
    if (( DRY_RUN )); then
        [[ -f "$rel" ]] || warn "ZDLRA software zip not found: $rel"
        info "[dry-run] $RACLI ${args[*]}  (success: '$RA_PREINSTALL_SUCCESS', no lines matching '$RA_PREINSTALL_FAIL_RE')"
        return 0
    fi
    [[ -f "$rel" ]] || die "ZDLRA software zip not found: $rel"
    confirm "Run '$RACLI ${args[*]}'?"
    local marker="${RUN_DIR}/.ra_preinstall.start"
    touch "$marker"
    run_racli_step preinstall "$RA_PREINSTALL_WARN_MINUTES" "$RA_PREINSTALL_SUCCESS" "${args[@]}"
    local log="${RUN_DIR}/ra_preinstall.log" failed
    failed="$(grep -E "$RA_PREINSTALL_FAIL_RE" "$log" | head -20 || true)"
    if [[ -n "$failed" ]]; then
        while IFS= read -r line; do err "  $line"; done <<<"$failed"
        die "racli preinstall reported failed checks. Log: $log"
    fi
    if [[ -n "$RA_PREINSTALL_DONE_FILE" ]]; then
        [[ "$RA_PREINSTALL_DONE_FILE" -nt "$marker" || "$RA_PREINSTALL_DONE_FILE" -ef "$marker" ]] \
            || die "racli preinstall did not write $RA_PREINSTALL_DONE_FILE. Log: $log"
    fi
    info "Pre-install passed all checks."
}

phase_ra_alter() {
    info "== RA alter appliance (new grid and DB homes) =="
    local args=() missing
    mapfile -t args < <(ra_args "${RA_ALTER_ARGS[@]}")
    missing="$(ra_gold_images_missing | paste -sd' ')"
    if (( DRY_RUN )); then
        [[ -z "$missing" ]] || warn "Gold images not in ${RA_GOLD_IMAGES_PATH}: $missing"
        info "[dry-run] $RACLI ${args[*]}  (success: '$RA_ALTER_SUCCESS')"
        return 0
    fi
    [[ -n "$(ra_gold_image_names)" ]] || die "The staged record names no gold images (ra_gold_images). Stage again with the current staging script."
    [[ -z "$missing" ]] || die "Gold images not in ${RA_GOLD_IMAGES_PATH}: $missing. The precheck moves them there; check its output."
    confirm "Run '$RACLI ${args[*]}'?"
    run_racli_step alter "$RA_ALTER_WARN_MINUTES" "$RA_ALTER_SUCCESS" "${args[@]}"
}

phase_ra_update() {
    info "== RA update appliance =="
    local args=() target ver
    mapfile -t args < <(ra_args "${RA_UPDATE_ARGS[@]}")
    target="$(conf_value TARGET_RA_VERSION || true)"
    if (( DRY_RUN )); then
        info "[dry-run] $RACLI ${args[*]}  (success: '$RA_UPDATE_SUCCESS'; target ${target:-not set})"
        return 0
    fi
    confirm "Run '$RACLI ${args[*]}'? It stops the appliance services while it patches (about 2 hours)."
    run_racli_step update "$RA_UPDATE_WARN_MINUTES" "$RA_UPDATE_SUCCESS" "${args[@]}"
    ver="$("$RACLI" version 2>&1 || true)"
    printf '%s\n' "$ver" >> "$LOG_FILE"
    if [[ -n "$target" ]]; then
        if grep -qF "$target" <<<"$ver"; then
            info "racli version shows $target."
        else
            warn "racli version does not show TARGET_RA_VERSION $target; check: $RACLI version"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Storage cells
# ---------------------------------------------------------------------------
# The cell patch zip (from the staged record) and the folder it unzipped to.
# Prints "<zip> <folder>"; fails with a message if either cannot be found.
cell_patch_location() {
    local zip top
    zip="$(sed -n 's/^unpacked=FILES_CELL:\([^:]*\):.*/\1/p' "$STAGED_RECORD" 2>/dev/null | head -1)"
    [[ -n "$zip" ]] || { echo "the staged record names no unpacked FILES_CELL file"; return 1; }
    zip="${CELL_PATCH_FILES_DIR}/${zip}"
    [[ -f "$zip" ]] || { echo "cell patch zip not found: $zip"; return 1; }
    top="$(unzip -Z1 "$zip" 2>/dev/null | sed 's#^\./##; s#/.*##' | grep -v '^$' | sort -u)"
    [[ -n "$top" && "$(wc -l <<<"$top")" -eq 1 ]] || { echo "cannot tell the patch folder from $zip (top entries: $(tr '\n' ' ' <<<"$top"))"; return 1; }
    [[ -x "${CELL_PATCH_TMP_DIR}/${top}/patchmgr" ]] || { echo "no patchmgr in ${CELL_PATCH_TMP_DIR}/${top}"; return 1; }
    echo "$zip ${CELL_PATCH_TMP_DIR}/${top}"
}

# TARGET_CELL_VERSION from the conf file staging set up.
target_cell_version() {
    local conf
    conf="$(staged_value patch_conf)"
    [[ -f "$conf" ]] || return 0
    sed -n 's/^TARGET_CELL_VERSION=//p' "$conf" | head -1 | tr -d '\r' | sed -E "s/^[\"']//; s/[\"']$//; s/[[:space:]]+$//"
}

# Current image version of every cell, as "cell: version" lines.
cell_versions() { "$DCLI" -g "$CELL_GROUP_FILE" -l root 'imageinfo -ver' 2>&1; }

# For the precheck review: what the cells phase will use. Read only; never fatal.
report_cell_plan() {
    [[ " ${ALL_PHASES[*]} " == *" cells "* ]] || return 0
    local loc target
    if loc="$(cell_patch_location)"; then
        info "Cell patch:   ${loc#* } (from $(basename "${loc%% *}"))"
    else
        warn "Cell patch:   not ready ($loc)"
    fi
    target="$(target_cell_version)"
    info "Cell target:  ${target:-<TARGET_CELL_VERSION not set in the conf file>}"
    if command -v "$DCLI" >/dev/null 2>&1 && [[ -s "$CELL_GROUP_FILE" ]]; then
        local line
        while IFS= read -r line; do info "    now $line"; done < <(cell_versions)
    fi
}

# ---------------------------------------------------------------------------
# Commands that must never be cut short (patchmgr, and the racli upgrade steps)
# ---------------------------------------------------------------------------
# run_detached starts the command in a session of its own (setsid, nohup, no
# terminal), writing straight to its log: nothing that happens to this script or the
# operator's ssh session can reach it. This script only waits, shows the log as it
# grows, and reads the exit status from a file. Nothing here ever stops the command:
# there is no time limit (past WARN minutes a warning is logged), and if this script
# itself stops, the run's status says the command is still running and the lock
# passes to it, so nothing can start over it.
DETACHED_PID=""
DETACHED_LOG=""
DETACHED_WHAT=""
DETACHED_RC=""
DETACHED_POLL_SECONDS=10

detached_pidfile() { echo "${RUN_DIR}/detached.pid"; }

# The command this run started, if it is still running: prints "pid N".
detached_running() {
    local f pid
    f="$(detached_pidfile)"
    [[ -f "$f" ]] || return 1
    pid="$(cat "$f")"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && { echo "pid $pid"; return 0; }
    return 1
}

# Called when this script stops (exit trap, or INT/TERM/HUP) while the command runs:
# leave it alone, say so in the status, and hand it the lock.
detached_leave_running() {
    [[ -n "$DETACHED_PID" ]] && kill -0 "$DETACHED_PID" 2>/dev/null || return 1
    err "Stopping the script, NOT ${DETACHED_WHAT}: it keeps running (pid $DETACHED_PID). Log: $DETACHED_LOG"
    err "Do not start it again until it has finished."
    set_status "${DETACHED_WHAT} still running (pid $DETACHED_PID), log $DETACHED_LOG; do not start it again until it finishes"
    echo "$DETACHED_PID" > "$LOCK_FILE"
    LOCK_HANDED_OFF=1
    return 0
}

detached_on_signal() {
    trap - INT TERM HUP
    detached_leave_running || true
    exit 1
}

# run_detached WHAT DIR LOG WARN_MINUTES COMMAND [ARGS...]
# Runs COMMAND in DIR, detached as above; sets DETACHED_RC to its exit status.
run_detached() {
    local what="$1" dir="$2" log="$3" warn_min="$4"; shift 4
    local rcfile="${log}.rc" pidfile
    pidfile="$(detached_pidfile)"
    rm -f -- "$rcfile" "$pidfile"
    : > "$log"
    info "[exec] cd $dir && $* (own session; log: $log)"

    local launcher=(nohup)
    if command -v setsid >/dev/null 2>&1; then
        launcher=(setsid nohup)
    else
        warn "setsid not found: $what runs with nohup only."
    fi
    # The inner bash records its pid, runs the command, then writes the exit status.
    "${launcher[@]}" bash -c 'echo $$ > "$1"; cd "$2" || exit 97; shift 3; "$@"; echo $? > "$0"' \
        "$rcfile" "$pidfile" "$dir" _ "$@" >> "$log" 2>&1 < /dev/null &
    local waited=0
    while [[ ! -s "$pidfile" ]] && (( waited < 30 )); do sleep 1; waited=$((waited + 1)); done
    DETACHED_PID="$(cat "$pidfile" 2>/dev/null)"
    DETACHED_LOG="$log"
    DETACHED_WHAT="$what"
    [[ -n "$DETACHED_PID" ]] || die "$what did not start. Log: $log"
    trap detached_on_signal INT TERM HUP

    # Show the log as it grows: print the lines added since the last look, and once
    # more at the end so nothing is missed.
    local shown=0 start warned=0
    show_new_lines() {
        local total
        total=$(wc -l < "$log")
        (( total > shown )) && sed -n "$(( shown + 1 )),${total}p" "$log" >&2
        shown=$total
    }
    start=$(date +%s)
    while [[ ! -s "$rcfile" ]]; do
        show_new_lines
        if ! kill -0 "$DETACHED_PID" 2>/dev/null; then
            sleep 2
            [[ -s "$rcfile" ]] && break
            show_new_lines
            DETACHED_PID=""
            die "$what ended without an exit status (was it killed?). Log: $log"
        fi
        if (( ! warned && $(date +%s) - start > warn_min * 60 )); then
            warn "$what has run for over ${warn_min} min; still waiting (not stopping it). Log: $log"
            warned=1
        fi
        sleep "$DETACHED_POLL_SECONDS"
    done
    show_new_lines
    trap - INT TERM HUP
    DETACHED_RC="$(tr -dc '0-9' < "$rcfile")"
    DETACHED_PID=""
    rm -f -- "$pidfile"
    cat "$log" >> "$LOG_FILE"
    (( DETACHED_RC != 97 )) || die "$what: cannot enter $dir. Log: $log"
}

# A command this run started, or any "patchmgr -cells" or racli upgrade step on this
# node, still running: prints "pid N (command)".
long_command_running() {
    local line
    detached_running && return 0
    if ps -eo pid=,args= >/dev/null 2>&1; then
        line="$(ps -eo pid=,args= | awk '($2 ~ /patchmgr$/ && / -cells /) || / racli (run preinstall|alter appliance|update appliance)/ { print; exit }')"
        [[ -n "$line" ]] && { echo "pid ${line# }"; return 0; }
    fi
    return 1
}

# Called before a cells or RA phase is marked as running, so a refusal leaves the
# run's status as it is.
refuse_if_running() {
    local running
    if running="$(long_command_running)"; then
        PRESERVE_STATUS=1
        die "Still running: $running. Wait for it to finish before starting $1 again."
    fi
}

# Run one patchmgr command from the patch folder, never cut short (run_detached).
# Success: exit 0, "SUCCESS: Completed run of command", "Exit status:0", and no
# FAILED lines. $1 = folder, $2 = log name, rest = patchmgr arguments.
run_patchmgr() {
    local dir="$1" name="$2"; shift 2
    local log="${RUN_DIR}/cells_${name}.log" rc step="-$name"
    run_detached "cells patchmgr $step" "$dir" "$log" "$CELL_PATCH_WARN_MINUTES" ./patchmgr "$@"
    rc="$DETACHED_RC"
    local failed
    failed="$(grep -E 'FAILED' "$log" | head -10 || true)"
    if [[ -n "$failed" ]]; then
        while IFS= read -r line; do err "  $line"; done <<<"$failed"
        die "patchmgr $step reported failures. Log: $log"
    fi
    (( rc == 0 )) || die "patchmgr $step exited with code $rc. Log: $log"
    grep -q 'SUCCESS: Completed run of command' "$log" && grep -q 'Exit status:0' "$log" \
        || die "patchmgr $step did not report a completed run (no 'SUCCESS: Completed run of command' / 'Exit status:0'). Log: $log"
    info "patchmgr $step: completed."
}

# Every cell must be on the target version. $1 = text with "cell: version" lines.
check_cell_versions() {
    local text="$1" target="$2" line cell ver bad=0 seen=0
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*([A-Za-z0-9._-]+):[[:space:]]*([0-9][0-9.]*)[[:space:]]*$ ]] || continue
        cell="${BASH_REMATCH[1]}"; ver="${BASH_REMATCH[2]}"; seen=$((seen + 1))
        if [[ "$ver" == "$target" ]]; then
            info "    $cell: $ver"
        else
            err "    $cell: $ver (expected $target)"; bad=$((bad + 1))
        fi
    done <<<"$text"
    (( seen > 0 )) || die "No cell versions found to check."
    (( bad == 0 )) || die "$bad cell(s) not on $target."
}

phase_cells() {
    info "== cells =="
    local loc dir target
    loc="$(cell_patch_location)" || die "Cell patch: $loc"
    dir="${loc#* }"
    [[ -s "$CELL_GROUP_FILE" ]] || die "$CELL_GROUP_FILE is missing or empty."
    target="$(target_cell_version)"
    [[ -n "$target" ]] || die "TARGET_CELL_VERSION is not set in $(staged_value patch_conf)."
    info "Cell patch folder: $dir; cells: $(paste -sd' ' "$CELL_GROUP_FILE"); target: $target"

    local step
    if (( DRY_RUN )); then
        for step in "${CELL_PREP_STEPS[@]}"; do info "[dry-run] cd $dir && ./patchmgr -cells $CELL_GROUP_FILE $step"; done
        info "[dry-run] cd $dir && ./patchmgr -cells $CELL_GROUP_FILE -patch ${CELL_PATCH_EXTRA_ARGS[*]-}"
        info "[dry-run] $DCLI -g $CELL_GROUP_FILE -l root 'imageinfo -ver'  (each cell must be $target)"
        return 0
    fi

    for step in "${CELL_PREP_STEPS[@]}"; do
        run_patchmgr "$dir" "${step#-}" -cells "$CELL_GROUP_FILE" "$step"
    done
    confirm "Patch the storage cells now (patchmgr -patch; the cells reboot)?"
    run_patchmgr "$dir" patch -cells "$CELL_GROUP_FILE" -patch ${CELL_PATCH_EXTRA_ARGS[@]+"${CELL_PATCH_EXTRA_ARGS[@]}"}

    info "Image version reported by patchmgr:"
    check_cell_versions "$(sed -n '/Current image version on cell(s) is:/,/For details/p' "${RUN_DIR}/cells_patch.log" | sed -E 's/^.*:INFO *: *//')" "$target"
    info "Image version from imageinfo:"
    check_cell_versions "$(cell_versions)" "$target"
    info "All cells are on $target."
}

phase_postcheck() {
    info "== postcheck =="
    local snap="${RUN_DIR}/snapshot_after"
    mkdir -p "$snap"
    run_ro "$RACLI" version          > "${snap}/racli_version.txt" 2>&1 || true
    run_ro "$RACLI" status appliance > "${snap}/racli_status.txt"  2>&1 || true
    if [[ -d "${RUN_DIR}/snapshot_before" ]]; then
        diff -ru "${RUN_DIR}/snapshot_before" "$snap" > "${RUN_DIR}/snapshot.diff" || true
        info "Before/after diff: ${RUN_DIR}/snapshot.diff"
    fi
    if (( POSTCHECK_RERUN_PRECHECK )); then
        run_external_precheck after
    fi
    # TODO: confirm backups and replication resume, test a restore validate.
}

phase_report() {
    info "== report =="
    local report="${RUN_DIR}/report.txt" approval="${RUN_DIR}/precheck_approval.txt"
    {
        echo "ZDLRA patch run $RUN_ID"
        echo "Host:      $(hostname)"
        echo "Done:      $(paste -sd' ' "${RUN_DIR}/phases_done" 2>/dev/null)"
        echo "Staged:    $(staged_value archive) (SHA-256 $(staged_value sha256))"
        echo "Dry run:   $DRY_RUN"
        echo "Phases:    ${PHASES[*]}"
        if [[ -f "$approval" ]]; then
            echo "Approved:  $(sed -n 's/^approved_by=//p' "$approval") at $(sed -n 's/^approved_at=//p' "$approval")"
        fi
        local paused
        paused="$(cat "${RUN_DIR}"/replication_paused*.txt 2>/dev/null | sort -u | tr '
' ' ')"
        echo "Paused:    ${paused:-no replication servers}"
        echo "Log:       $LOG_FILE"
    } > "$report"
    # TODO: optional email/webhook notification (useful when the run is in the background).
    info "Report written to $report"
}

# ---------------------------------------------------------------------------
# Start the remaining phases as a detached process that survives logout. It continues
# this run (same folder and approval), takes over the lock, and never prompts.
start_background() {
    local args=(-c "$CONFIG_FILE" --run-id "$RUN_ID" --bg-child)
    (( DRY_RUN )) || args+=(--execute)
    (( SKIP_BACKUP_WAIT )) && args+=(--skip-backup-wait)
    args+=("${BG_PHASES[@]}")

    local launcher=(nohup)
    command -v setsid >/dev/null 2>&1 && launcher=(setsid nohup)
    ZDLRA_LOCK_FROM=$$ "${launcher[@]}" "$SCRIPT_PATH" "${args[@]}" \
        > "${RUN_DIR}/background.out" 2>&1 < /dev/null &
    local pid=$!
    echo "$pid" > "${RUN_DIR}/background.pid"
    echo "$pid" > "$LOCK_FILE"
    LOCK_HANDED_OFF=1
    set_status "running in background (pid $pid): ${BG_PHASES[*]}"
    info "Remaining phases started in the background as pid $pid: ${BG_PHASES[*]}"
    info "Follow it with:  tail -f $LOG_FILE"
    info "Check it with:   $SCRIPT_PATH -c $CONFIG_FILE --status --run-id $RUN_ID"
}

main() {
    parse_args "$@"
    load_config
    if (( STATUS_MODE )); then
        show_status
        exit 0
    fi
    init_run
    acquire_lock

    # --approve: review the saved results of a detached precheck.
    # A declined or impossible approval leaves the run's status as it was, so it can be retried.
    if (( APPROVE_MODE )); then
        CURRENT_PHASE="approve"
        PRESERVE_STATUS=1
        [[ -f "${RUN_DIR}/precheck_passed" ]] || die "Run $RUN_ID has no passed precheck to approve."
        if [[ -f "${RUN_DIR}/precheck_approval.txt" ]]; then
            info "Run $RUN_ID is already approved by $(sed -n 's/^approved_by=//p' "${RUN_DIR}/precheck_approval.txt")."
            return 0
        fi
        approve_precheck
        FINAL_STATUS="precheck approved"
        return 0
    fi

    # --continue: leave out the phases this run already finished.
    if (( CONTINUE )); then
        local keep=() q
        for q in "${PHASES[@]}"; do
            if phase_done "$q"; then info "Already done in run $RUN_ID: $q"; else keep+=("$q"); fi
        done
        PHASES=(${keep[@]+"${keep[@]}"})
        if (( ! ${#PHASES[@]} )); then
            info "Every listed phase is already done in run $RUN_ID."
            return 0
        fi
        info "Continuing run $RUN_ID with: ${PHASES[*]}"
    fi

    # With --background, phases up to and including precheck run here, the rest detached.
    # With --detach, the precheck itself runs detached.
    local fg_phases=("${PHASES[@]}") p
    if (( DETACH && ! BG_CHILD )); then
        fg_phases=()
        BG_PHASES=("${PHASES[@]}")
    elif (( BACKGROUND && ! BG_CHILD )); then
        fg_phases=()
        BG_PHASES=()
        local split=0
        [[ " ${PHASES[*]} " == *" precheck "* ]] || split=1
        for p in "${PHASES[@]}"; do
            if (( split )); then BG_PHASES+=("$p"); else fg_phases+=("$p"); fi
            [[ "$p" == precheck ]] && split=1
        done
        # Without precheck in this run, check the existing approval now, not after detaching.
        if (( ! ${#fg_phases[@]} )) && [[ " ${BG_PHASES[*]} " == *" ra_"* || " ${BG_PHASES[*]} " == *" quiesce "* || " ${BG_PHASES[*]} " == *" cells "* ]]; then
            require_approval
        fi
    fi

    for p in ${fg_phases[@]+"${fg_phases[@]}"}; do
        # Check approval before marking a changing step as running, so a refusal leaves
        # the run's status as it was.
        [[ "$p" == ra_* || "$p" == quiesce || "$p" == cells ]] && require_approval
        [[ "$p" == ra_* || "$p" == cells ]] && refuse_if_running "$p"
        CURRENT_PHASE="$p"
        set_status "running $p"
        "phase_${p}"
        phase_mark_done "$p"
    done

    if (( ${#BG_PHASES[@]} )); then
        start_background
        return 0
    fi
    CURRENT_PHASE="done"
    info "Done. Run directory: $RUN_DIR"
}

main "$@"
