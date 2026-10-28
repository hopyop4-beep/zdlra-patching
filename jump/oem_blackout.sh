#!/usr/bin/env bash
#
# oem_blackout.sh - create, check and end the OEM blackout for a ZDLRA patch
#
# Runs on the OMS (jump server) as the OS user that has emcli access.
#
# Usage:
#   ./oem_blackout.sh targets -z ZDLRA          list EM targets whose name matches ZDLRA
#   ./oem_blackout.sh start   -z ZDLRA [-x]     create a blackout for the patch
#   ./oem_blackout.sh status  -z ZDLRA          show the appliance's current blackout
#   ./oem_blackout.sh stop    -z ZDLRA [-x]     end it
#
# Options:
#   -z, --zdlra NAME     appliance (required)
#   -c, --config FILE    config file (default: zdlra_jump.conf next to this script)
#   -x, --execute        create or end the blackout for real (default is dry run;
#                        the read-only checks still run)
#   -h, --help           show this help
#
# Targets, reason and duration come from the config file. The name of the
# blackout that "start" creates is saved in $STATE_DIR/<appliance>.blackout,
# so "status" and "stop" know which one to use.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/zdlra_jump.conf"
STATE_DIR="${HOME}/zdlra_jump_state"
DRY_RUN=1
ACTION=""
ZDLRA=""

EMCLI="emcli"
EM_USER=""
BLACKOUT_REASON=""
BLACKOUT_HOURS=12
BLACKOUT_PROPAGATE=1
declare -A BLACKOUT_TARGETS=()
declare -A PATCH_NODE=()         # not used here; lets the shared config load

log()  { local lvl="$1"; shift; printf '%s [%-5s] %s\n' "$(date '+%F %T')" "$lvl" "$*" >&2; }
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
err()  { log ERROR "$@"; }
die()  { err "$@"; exit 1; }

usage() { awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"; }

parse_args() {
    while (( $# )); do
        case "$1" in
            targets|start|status|stop) ACTION="$1"; shift ;;
            -z|--zdlra)   ZDLRA="$2"; shift 2 ;;
            -c|--config)  CONFIG_FILE="$2"; shift 2 ;;
            -x|--execute) DRY_RUN=0; shift ;;
            -h|--help)    usage; exit 0 ;;
            *)            die "Unknown argument: $1 (see --help)" ;;
        esac
    done
    [[ -n "$ACTION" && -n "$ZDLRA" ]] || { usage; exit 1; }
    [[ "$ZDLRA" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "Bad appliance name: $ZDLRA"
}

load_config() {
    [[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE (copy zdlra_jump.conf.example)"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    command -v "$EMCLI" >/dev/null 2>&1 || die "emcli not found: $EMCLI (set EMCLI in $CONFIG_FILE)"
}

# emcli sync fails when there is no logged-in session.
ensure_login() {
    if "$EMCLI" sync >/dev/null 2>&1; then
        return 0
    fi
    [[ -n "$EM_USER" ]] || die "emcli is not logged in. Run 'emcli login -username=<user>' or set EM_USER in $CONFIG_FILE."
    info "Logging in to EM as $EM_USER"
    "$EMCLI" login -username="$EM_USER" || die "emcli login failed."
    "$EMCLI" sync >/dev/null || die "emcli sync failed after login."
}

state_file() { echo "${STATE_DIR}/${ZDLRA}.blackout"; }

current_blackout() {
    local f
    f="$(state_file)"
    [[ -f "$f" ]] || die "No blackout recorded for $ZDLRA in $f"
    cat "$f"
}

# ---------------------------------------------------------------------------
do_targets() {
    ensure_login
    info "EM targets matching '$ZDLRA' (name, type):"
    "$EMCLI" get_targets -targets="%${ZDLRA}%"
}

do_start() {
    local targets="${BLACKOUT_TARGETS[$ZDLRA]:-}"
    [[ -n "$targets" && "$targets" != *"<"* ]] || die "No BLACKOUT_TARGETS entry for $ZDLRA in $CONFIG_FILE. List candidates with: $0 targets -z $ZDLRA"
    [[ -n "$BLACKOUT_REASON" && "$BLACKOUT_REASON" != *"<"* ]] || die "Set BLACKOUT_REASON in $CONFIG_FILE (see: emcli get_blackout_reasons)"

    ensure_login
    "$EMCLI" get_blackout_reasons | grep -Fq -- "$BLACKOUT_REASON" \
        || die "BLACKOUT_REASON '$BLACKOUT_REASON' is not a known reason. See: emcli get_blackout_reasons"

    local f
    f="$(state_file)"
    if [[ -f "$f" ]]; then
        die "A blackout is already recorded for $ZDLRA: $(cat "$f"). Stop it first: $0 stop -z $ZDLRA -x"
    fi

    local name schedule
    name="PATCH_${ZDLRA}_$(date +%Y%m%d_%H%M)"
    if (( BLACKOUT_HOURS < 0 )); then
        schedule="duration:-1"
    else
        schedule="duration:${BLACKOUT_HOURS}:00"
    fi
    local args=(create_blackout -name="$name" -add_targets="$targets" -reason="$BLACKOUT_REASON" -schedule="$schedule")
    (( BLACKOUT_PROPAGATE )) && args+=(-propagate_targets)

    if (( DRY_RUN )); then
        info "[dry-run] $EMCLI ${args[*]}"
        return 0
    fi
    info "[exec] $EMCLI ${args[*]}"
    "$EMCLI" "${args[@]}" || die "create_blackout failed."
    mkdir -p "$STATE_DIR"
    echo "$name" > "$f"
    info "Blackout $name started for $ZDLRA (ends by itself after: ${BLACKOUT_HOURS}h; -1 = never)."
}

do_status() {
    ensure_login
    local name
    name="$(current_blackout)"
    info "Blackout $name:"
    "$EMCLI" get_blackout_details -name="$name"
}

do_stop() {
    ensure_login
    local name
    name="$(current_blackout)"
    if (( DRY_RUN )); then
        info "[dry-run] $EMCLI stop_blackout -name=$name"
        return 0
    fi
    info "[exec] $EMCLI stop_blackout -name=$name"
    "$EMCLI" stop_blackout -name="$name" || die "stop_blackout failed for $name."
    mv "$(state_file)" "$(state_file).stopped_$(date +%Y%m%d_%H%M%S)"
    info "Blackout $name stopped."
}

main() {
    parse_args "$@"
    load_config
    "do_${ACTION}"
}

main "$@"
