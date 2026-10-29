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
#   patch1      racli <action> appliance --step=1   (needs an approved precheck)
#   patch2      racli <action> appliance --step=2   (needs an approved precheck)
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
#   -s, --status        show the state of the latest run, or of --run-id ID
#       --skip-backup-wait  quiesce does not wait for incoming backups to finish
#   -h, --help          show this help

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/${SCRIPT_NAME}"
VERSION="0.5.0"

ALL_PHASES=(precheck quiesce snapshot patch1 patch2 postcheck resume report)

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

RACLI="/opt/oracle.RecoveryAppliance/bin/racli"
PATCH_ACTION="patch"            # "patch" for a bundle patch, "upgrade" for a release upgrade
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

# SQL on the appliance, as the raadmin account (see the config example).
SQLPLUS="sqlplus"
RA_SQL_CONNECT=""               # e.g. /@raadmin (wallet alias); empty = SQL steps not set up
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
ACTIVE_BACKUPS_SQL=""           # count of incoming backups still running
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
    else
        warn "Config file $CONFIG_FILE not found; using built-in defaults."
    fi
    CONFIG_FILE="$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$(basename "$CONFIG_FILE")"
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
# SQL on the appliance (raadmin)
# ---------------------------------------------------------------------------
sql_ready() { [[ -n "$RA_SQL_CONNECT" ]]; }

# Run SQL as raadmin and print the result rows, trimmed. Fails on ORA-/SP2- errors.
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
}

# Poll a count query until it reaches 0 or the timeout passes.
# $1 = label, $2 = count query
wait_for_zero() {
    local label="$1" query="$2" n waited=0 limit=$(( QUIESCE_TIMEOUT_MINUTES * 60 ))
    while :; do
        n="$(sql_count "$query")" || die "Could not count $label."
        if (( n == 0 )); then
            info "No $label running."
            return 0
        fi
        (( waited < limit )) || die "$n $label still running after ${QUIESCE_TIMEOUT_MINUTES} min. Stopping before patching."
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

    run_external_precheck before

    local free_gb
    free_gb=$(df -BG --output=avail "$WORK_DIR" | tail -1 | tr -dc '0-9')
    info "Free space for $WORK_DIR: ${free_gb}G (need ${MIN_FREE_GB}G)"
    (( free_gb >= MIN_FREE_GB )) || die "Not enough free space."

    # Read-only look at what quiesce will deal with, so it is part of the review.
    report_activity

    # TODO: confirm the patch is valid for the current version (compare racli version with patch README).

    # Marks the precheck as passed, so a detached precheck can be approved later with --approve.
    touch "${RUN_DIR}/precheck_passed"
    approve_precheck
}

# TODO(site): confirm the replication pause process (it may be done from the upstream
# appliance) and fill in the SQL settings; the steps below are placeholders around them.
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
        wait_for_zero "incoming backups" "$ACTIVE_BACKUPS_SQL"
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

phase_patch1() {
    info "== patch step 1 =="
    require_approval
    confirm "Run '$RACLI $PATCH_ACTION appliance --step=1'?"
    run "$RACLI" "$PATCH_ACTION" appliance --step=1
    # TODO: parse output/log for success markers; stop if step 1 did not complete cleanly.
}

phase_patch2() {
    info "== patch step 2 =="
    require_approval
    confirm "Run '$RACLI $PATCH_ACTION appliance --step=2'? This stops services."
    run "$RACLI" "$PATCH_ACTION" appliance --step=2
    # TODO: wait for services to return, with a timeout.
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
        echo "Action:    $PATCH_ACTION"
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
        if (( ! ${#fg_phases[@]} )) && [[ " ${BG_PHASES[*]} " == *" patch"* || " ${BG_PHASES[*]} " == *" quiesce "* ]]; then
            require_approval
        fi
    fi

    for p in ${fg_phases[@]+"${fg_phases[@]}"}; do
        # Check approval before marking a changing step as running, so a refusal leaves
        # the run's status as it was.
        [[ "$p" == patch* || "$p" == quiesce ]] && require_approval
        CURRENT_PHASE="$p"
        set_status "running $p"
        "phase_${p}"
    done

    if (( ${#BG_PHASES[@]} )); then
        start_background
        return 0
    fi
    CURRENT_PHASE="done"
    info "Done. Run directory: $RUN_DIR"
}

main "$@"
