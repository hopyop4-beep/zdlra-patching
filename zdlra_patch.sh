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
#
# Phases (run in this order by "all"):
#   precheck    appliance health, versions, free space, running jobs
#   snapshot    save configuration and state so you can compare after patching
#   stage       verify and unpack the patch bundle on the staging filesystem
#   patch1      racli <action> appliance --step=1
#   patch2      racli <action> appliance --step=2
#   postcheck   rerun health checks and compare with the snapshot
#   report      write a summary of this run
#
# Options:
#   -c, --config FILE   config file (default: ./zdlra_patch.conf)
#   -x, --execute       run commands for real (default is dry run)
#   -y, --yes           do not prompt before disruptive phases
#   -h, --help          show this help

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="0.1.0"

ALL_PHASES=(precheck snapshot stage patch1 patch2 postcheck report)

# ---------------------------------------------------------------------------
# Defaults (override in the config file)
# ---------------------------------------------------------------------------
CONFIG_FILE="${SCRIPT_DIR}/zdlra_patch.conf"
DRY_RUN=1
ASSUME_YES=0

RACLI="/opt/oracle.RecoveryAppliance/bin/racli"
PATCH_ACTION="patch"            # "patch" for a bundle patch, "upgrade" for a release upgrade
PATCH_ZIP=""                    # full path to the patch bundle zip
PATCH_STAGE_DIR="/radump/zdlra_patch_stage"
WORK_DIR="/radump/zdlra_patch_runs"
MIN_FREE_GB=50
REQUIRED_USER="root"

# External precheck script (e.g. the Oracle-supplied precheck). Not shipped in this repo.
PRECHECK_SCRIPT=""              # full path; empty = skip with a warning
PRECHECK_ARGS=()                # arguments passed to the script
PRECHECK_TIMEOUT=3600           # seconds before the precheck is killed
PRECHECK_SUMMARY_HEADER="FAILURE SUMMARY"   # failures are read from after this line
PRECHECK_FAIL_PATTERN='\[FAIL\]'            # extended regex for a failure line
PRECHECK_WAIVERS=()             # failure names (substrings) accepted as known; logged, not fatal
PRECHECK_REQUIRED=1             # 1 = stop if PRECHECK_SCRIPT is not set
POSTCHECK_RERUN_PRECHECK=1      # 1 = run the same script again after patching

RUN_ID="$(date +%Y%m%d_%H%M%S)"
RUN_DIR=""
LOG_FILE=""
LOCK_FILE="/tmp/zdlra_patch.lock"

# ---------------------------------------------------------------------------
# Logging and helpers
# ---------------------------------------------------------------------------
log()  { local lvl="$1"; shift; printf '%s [%-5s] %s\n' "$(date '+%F %T')" "$lvl" "$*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
err()  { log ERROR "$@"; }
die()  { err "$@"; exit 1; }

usage() { sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'; }

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
    local reply
    read -r -p "$1 [type YES to continue]: " reply
    [[ "$reply" == "YES" ]] || die "Aborted by operator."
}

on_error() {
    err "Failed at line $1 (exit $2). Log: ${LOG_FILE:-none}"
}
trap 'on_error $LINENO $?' ERR

cleanup() { rm -f "$LOCK_FILE"; }

acquire_lock() {
    if [[ -e "$LOCK_FILE" ]]; then
        die "Lock file $LOCK_FILE exists (pid $(cat "$LOCK_FILE" 2>/dev/null)). Is another run active?"
    fi
    echo $$ > "$LOCK_FILE"
    trap cleanup EXIT
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
parse_args() {
    PHASES=()
    while (( $# )); do
        case "$1" in
            -c|--config)  CONFIG_FILE="$2"; shift 2 ;;
            -x|--execute) DRY_RUN=0; shift ;;
            -y|--yes)     ASSUME_YES=1; shift ;;
            -h|--help)    usage; exit 0 ;;
            all)          PHASES+=("${ALL_PHASES[@]}"); shift ;;
            -*)           die "Unknown option: $1" ;;
            *)            PHASES+=("$1"); shift ;;
        esac
    done
    (( ${#PHASES[@]} )) || { usage; exit 1; }
    for p in "${PHASES[@]}"; do
        [[ " ${ALL_PHASES[*]} " == *" $p "* ]] || die "Unknown phase: $p"
    done
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    else
        warn "Config file $CONFIG_FILE not found; using built-in defaults."
    fi
}

init_run() {
    RUN_DIR="${WORK_DIR}/${RUN_ID}"
    mkdir -p "$RUN_DIR"
    LOG_FILE="${RUN_DIR}/zdlra_patch.log"
    info "$SCRIPT_NAME $VERSION  run=$RUN_ID  dry_run=$DRY_RUN  phases=${PHASES[*]}"
    [[ "$(id -un)" == "$REQUIRED_USER" ]] || die "Run as $REQUIRED_USER (current: $(id -un))."
    [[ -x "$RACLI" ]] || die "racli not found at $RACLI"
}

# Run the external precheck script. It is read-only, so it runs in dry-run mode too.
# Failures are the PRECHECK_FAIL_PATTERN lines after PRECHECK_SUMMARY_HEADER, e.g.
#   FAILURE SUMMARY
#   ***********************************
#   <date> [FAIL] <failure name>
# The phase fails on any failure not listed in PRECHECK_WAIVERS, a timeout, or a
# non-zero exit code. Files written to precheck_<label>/:
#   output.txt          full output
#   failures.txt        failure lines from the summary
#   failure_names.txt   failure names only (date and tag removed), sorted
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
    info "Running precheck ($label): $PRECHECK_SCRIPT ${PRECHECK_ARGS[*]-} (timeout ${PRECHECK_TIMEOUT}s)"

    local rc=0
    ( cd "$out_dir" && timeout "$PRECHECK_TIMEOUT" "$PRECHECK_SCRIPT" ${PRECHECK_ARGS[@]+"${PRECHECK_ARGS[@]}"} ) \
        > "$out_file" 2>&1 || rc=$?
    info "Precheck output: $out_file (exit code $rc)"
    (( rc == 124 )) && die "Precheck timed out after ${PRECHECK_TIMEOUT}s."

    # Read failures from the last summary section (colour codes removed). If the
    # header is missing, fall back to searching the whole output.
    local plain fail_file="${out_dir}/failures.txt" names_file="${out_dir}/failure_names.txt" have_summary=0
    plain="$(sed 's/\x1b\[[0-9;]*m//g' "$out_file")"
    if grep -qF "$PRECHECK_SUMMARY_HEADER" <<<"$plain"; then
        have_summary=1
        awk -v h="$PRECHECK_SUMMARY_HEADER" 'index($0, h) { buf = ""; next } { buf = buf $0 "\n" } END { printf "%s", buf }' <<<"$plain" \
            | grep -E "$PRECHECK_FAIL_PATTERN" > "$fail_file" || true
    else
        warn "No '$PRECHECK_SUMMARY_HEADER' section found; searching the whole output for failures."
        grep -E "$PRECHECK_FAIL_PATTERN" <<<"$plain" > "$fail_file" || true
    fi
    sed -E "s/.*${PRECHECK_FAIL_PATTERN}[[:space:]]*//; s/[[:space:]]+$//" "$fail_file" | LC_ALL=C sort -u > "$names_file"

    local name waiver blocking=0 waived=0
    while IFS= read -r name; do
        for waiver in ${PRECHECK_WAIVERS[@]+"${PRECHECK_WAIVERS[@]}"}; do
            if [[ "$name" == *"$waiver"* ]]; then
                warn "  [waived] $name"
                waived=$((waived + 1))
                continue 2
            fi
        done
        err "  [FAIL] $name"
        blocking=$((blocking + 1))
    done < "$names_file"
    info "Precheck ($label): $blocking failure(s), $waived waived. List: $fail_file"

    if [[ "$label" == after && -f "${RUN_DIR}/precheck_before/failure_names.txt" ]]; then
        local before="${RUN_DIR}/precheck_before/failure_names.txt"
        LC_ALL=C comm -13 "$before" "$names_file" | while IFS= read -r name; do warn "  new since before patching: $name"; done
        LC_ALL=C comm -23 "$before" "$names_file" | while IFS= read -r name; do info "  resolved by patching: $name"; done
    fi

    (( blocking == 0 )) || die "Precheck ($label) found $blocking failure(s) that are not waived."
    # With a summary, the summary decides: the script may exit non-zero for waived failures.
    if (( rc != 0 )); then
        (( have_summary )) || die "Precheck exited with code $rc and printed no summary. See $out_file"
        warn "Precheck exited with code $rc; every failure in its summary is waived."
    fi
    info "Precheck ($label) passed."
}

# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------
phase_precheck() {
    info "== precheck =="
    run_ro "$RACLI" version || warn "racli version failed"
    run_ro "$RACLI" status appliance || die "Appliance status check failed"

    run_external_precheck before

    local free_gb
    free_gb=$(df -BG --output=avail "$(dirname "$PATCH_STAGE_DIR")" | tail -1 | tr -dc '0-9')
    info "Free space near $PATCH_STAGE_DIR: ${free_gb}G (need ${MIN_FREE_GB}G)"
    (( free_gb >= MIN_FREE_GB )) || die "Not enough free space."

    # TODO: check for running backup/copy-to-tape/replication jobs and decide whether to wait.
    # TODO: confirm protected databases are not mid-backup (query RASYS views).
    # TODO: confirm the patch is valid for the current version (compare racli version with patch README).
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

phase_stage() {
    info "== stage =="
    [[ -n "$PATCH_ZIP" ]] || die "PATCH_ZIP is not set in the config."
    [[ -f "$PATCH_ZIP" ]] || die "Patch bundle not found: $PATCH_ZIP"
    # TODO: verify the checksum against the value published with the patch.
    run mkdir -p "$PATCH_STAGE_DIR"
    run unzip -o -q "$PATCH_ZIP" -d "$PATCH_STAGE_DIR"
    # TODO: copy or link the unpacked bundle to the location racli expects for this release.
}

phase_patch1() {
    info "== patch step 1 =="
    confirm "Run '$RACLI $PATCH_ACTION appliance --step=1'?"
    run "$RACLI" "$PATCH_ACTION" appliance --step=1
    # TODO: parse output/log for success markers; stop if step 1 did not complete cleanly.
}

phase_patch2() {
    info "== patch step 2 =="
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
    local report="${RUN_DIR}/report.txt"
    {
        echo "ZDLRA patch run $RUN_ID"
        echo "Host:      $(hostname)"
        echo "Action:    $PATCH_ACTION"
        echo "Bundle:    ${PATCH_ZIP:-<not set>}"
        echo "Dry run:   $DRY_RUN"
        echo "Phases:    ${PHASES[*]}"
        echo "Log:       $LOG_FILE"
    } > "$report"
    # TODO: optional email/webhook notification.
    info "Report written to $report"
}

# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    load_config
    init_run
    acquire_lock
    for p in "${PHASES[@]}"; do
        "phase_${p}"
    done
    info "Done. Run directory: $RUN_DIR"
}

main "$@"
