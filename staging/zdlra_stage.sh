#!/usr/bin/env bash
#
# zdlra_stage.sh - stage a patch archive on the compute nodes of one or more ZDLRAs
#
# Step 2 of staging. Runs on a jump server that holds the patch archive (.zip or .tar
# from Copy-ZdlraPatches.ps1, plus <archive>.sha256) and can reach the appliances over
# ssh. For each appliance given with -z, it:
#
#   nodes       finds the compute nodes (inventory file, or olsnodes on the appliance)
#   distribute  copies the archive to every node (skips nodes that already have it)
#   check       verifies the SHA-256 and free space on every node
#   extract     unpacks the archive on every node into <extract root>/<archive name>/
#   post        per-node steps after unpacking (TODO hooks, filled in later)
#
# STATUS: skeleton. Commands that change something run only with --execute.
#
# Usage:
#   ./zdlra_stage.sh [options] -a ARCHIVE -z ZDLRA [-z ZDLRA ...]
#
# Options:
#   -a, --archive FILE      archive on this jump server (required)
#   -s, --sha-file FILE     checksum file (default: ARCHIVE.sha256)
#   -z, --zdlra NAME        appliance to stage; repeat for several (required)
#   -i, --inventory FILE    appliance-to-nodes list (default: appliances.conf next to
#                           this script); appliances not listed use olsnodes
#   -u, --user USER         ssh user on the nodes (default: root)
#   -r, --remote-dir DIR    where the archive is copied on each node (default: /radump)
#   -d, --extract-root DIR  where it is unpacked on each node (default: /radump/zdlra_stage)
#       --relay             copy to the first node only; it copies to the other nodes
#       --keep-going        continue with the next appliance after a failure
#   -x, --execute           run commands for real (default is dry run)
#   -h, --help              show this help
#
# Inventory format (one appliance per line, # for comments):
#   zdlra01  zdlra01db01 zdlra01db02

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="0.2.0"

ARCHIVE=""
SHA_FILE=""
ZDLRAS=()
INVENTORY="${SCRIPT_DIR}/appliances.conf"
SSH_USER="root"
REMOTE_DIR="/radump"
EXTRACT_ROOT="/radump/zdlra_stage"
RELAY=0
KEEP_GOING=0
DRY_RUN=1
MIN_FREE_GB=20                  # free space needed beyond the unpacked size
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15)
LOG_DIR="${HOME}/zdlra_stage_logs"
LOG_FILE=""

ARCHIVE_NAME=""
REMOTE_ARCHIVE=""
STAGE_DIR=""
EXPECTED_SHA=""
NODES=()

# ---------------------------------------------------------------------------
# Logging and helpers
# ---------------------------------------------------------------------------
log()  { local lvl="$1"; shift; printf '%s [%-5s] %s\n' "$(date '+%F %T')" "$lvl" "$*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
err()  { log ERROR "$@"; }
die()  { err "$@"; exit 1; }

usage() { awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"; }

trap 'err "Failed at line $LINENO (exit $?). Log: ${LOG_FILE:-none}"' ERR

# Paths and names go into remote shell commands, so allow only plain characters.
safe_path() { [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ && "$1" != *..* ]]; }
safe_host() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; }

# Run a command string on a node over ssh.
on_node() {
    local node="$1"; shift
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${node}" "$*"
}

# Like on_node, but in dry-run mode only logs the command.
change_on_node() {
    local node="$1"; shift
    if (( DRY_RUN )); then
        info "[dry-run] ${node}: $*"
        return 0
    fi
    info "[exec] ${node}: $*"
    on_node "$node" "$*" 2>&1 | tee -a "$LOG_FILE"
    return "${PIPESTATUS[0]}"
}

# SHA-256 of the archive on a node, or empty if it is not there.
remote_sha() {
    on_node "$1" "[ -f '$REMOTE_ARCHIVE' ] && sha256sum '$REMOTE_ARCHIVE' | cut -d' ' -f1" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
parse_args() {
    while (( $# )); do
        case "$1" in
            -a|--archive)      ARCHIVE="$2"; shift 2 ;;
            -s|--sha-file)     SHA_FILE="$2"; shift 2 ;;
            -z|--zdlra)        ZDLRAS+=("$2"); shift 2 ;;
            -i|--inventory)    INVENTORY="$2"; shift 2 ;;
            -u|--user)         SSH_USER="$2"; shift 2 ;;
            -r|--remote-dir)   REMOTE_DIR="$2"; shift 2 ;;
            -d|--extract-root) EXTRACT_ROOT="$2"; shift 2 ;;
            --relay)           RELAY=1; shift ;;
            --keep-going)      KEEP_GOING=1; shift ;;
            -x|--execute)      DRY_RUN=0; shift ;;
            -h|--help)         usage; exit 0 ;;
            *)                 die "Unknown argument: $1 (see --help)" ;;
        esac
    done
    [[ -n "$ARCHIVE" && ${#ZDLRAS[@]} -gt 0 ]] || { usage; exit 1; }
    SHA_FILE="${SHA_FILE:-${ARCHIVE}.sha256}"
    local z
    for z in "${ZDLRAS[@]}"; do safe_host "$z" || die "Bad appliance name: $z"; done
    [[ "$SSH_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "Bad ssh user: $SSH_USER"
    safe_path "$REMOTE_DIR"   || die "Remote dir has unsupported characters: $REMOTE_DIR"
    safe_path "$EXTRACT_ROOT" || die "Extract root has unsupported characters: $EXTRACT_ROOT"
    case "$ARCHIVE" in
        *.zip|*.tar) ;;
        *) die "Archive must be .zip or .tar: $ARCHIVE" ;;
    esac
    ARCHIVE_NAME="$(basename "$ARCHIVE")"
    [[ "$ARCHIVE_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "Archive name has unsupported characters: $ARCHIVE_NAME"
    REMOTE_ARCHIVE="${REMOTE_DIR}/${ARCHIVE_NAME}"
    STAGE_DIR="${EXTRACT_ROOT}/${ARCHIVE_NAME%.*}"
}

init_log() {
    mkdir -p "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/stage_$(date +%Y%m%d_%H%M%S).log"
    info "$SCRIPT_NAME $VERSION  dry_run=$DRY_RUN  relay=$RELAY"
    info "Archive:      $ARCHIVE"
    info "Appliances:   ${ZDLRAS[*]}"
    info "On nodes:     copy to $REMOTE_ARCHIVE, unpack to $STAGE_DIR"
}

# Check the archive on the jump server once, before touching any appliance.
verify_local() {
    info "== verify (jump server) =="
    [[ -f "$ARCHIVE" ]]  || die "Archive not found: $ARCHIVE"
    [[ -f "$SHA_FILE" ]] || die "Checksum file not found: $SHA_FILE (copy it with the archive)"
    EXPECTED_SHA="$(awk 'NR == 1 { print tolower($1) }' "$SHA_FILE")"
    [[ "$EXPECTED_SHA" =~ ^[0-9a-f]{64}$ ]] || die "No SHA-256 found in $SHA_FILE"
    local actual
    actual="$(sha256sum "$ARCHIVE" | cut -d' ' -f1)"
    [[ "$actual" == "$EXPECTED_SHA" ]] || die "SHA-256 mismatch on the jump server: $actual, expected $EXPECTED_SHA"
    info "SHA-256 OK ($(du -h "$ARCHIVE" | cut -f1))"
}

# ---------------------------------------------------------------------------
# Steps for one appliance ($1 = appliance name)
# ---------------------------------------------------------------------------
step_nodes() {
    local z="$1"
    NODES=()
    if [[ -f "$INVENTORY" ]]; then
        local line
        line="$(awk -v z="$z" '$1 == z { $1 = ""; print; exit }' "$INVENTORY")"
        [[ -n "$line" ]] && read -r -a NODES <<<"$line"
    fi
    if (( ${#NODES[@]} )); then
        info "${z}: nodes from $INVENTORY: ${NODES[*]}"
    else
        local out
        out="$(on_node "$z" 'ols=$(command -v olsnodes 2>/dev/null || ls /u01/app/*/grid/bin/olsnodes 2>/dev/null | head -1); [ -n "$ols" ] && "$ols"')" \
            || die "${z}: cannot run olsnodes over ssh. Add the appliance to $INVENTORY."
        mapfile -t NODES <<<"$out"
        info "${z}: nodes from olsnodes: ${NODES[*]}"
    fi
    (( ${#NODES[@]} )) || die "${z}: no compute nodes found."
    local n
    for n in "${NODES[@]}"; do
        safe_host "$n" || die "${z}: bad node name: $n"
        on_node "$n" true || die "${z}: cannot ssh to ${SSH_USER}@${n} without a password."
    done
}

# Copy the archive to one node: from the jump server, or with --relay from the first node.
copy_to_node() {
    local node="$1" first="$2"
    if (( RELAY )) && [[ "$node" != "$first" ]]; then
        change_on_node "$first" "scp -q -o BatchMode=yes '$REMOTE_ARCHIVE' '${SSH_USER}@${node}:$REMOTE_ARCHIVE'"
    elif (( DRY_RUN )); then
        info "[dry-run] scp $ARCHIVE ${SSH_USER}@${node}:$REMOTE_ARCHIVE"
    else
        info "[exec] scp $ARCHIVE ${SSH_USER}@${node}:$REMOTE_ARCHIVE"
        scp -q "${SSH_OPTS[@]}" "$ARCHIVE" "${SSH_USER}@${node}:$REMOTE_ARCHIVE"
    fi
}

step_distribute() {
    local z="$1" node first="${NODES[0]}"
    for node in "${NODES[@]}"; do
        if [[ "$(remote_sha "$node")" == "$EXPECTED_SHA" ]]; then
            info "${z}/${node}: already has the archive (SHA-256 matches); not copying"
            continue
        fi
        change_on_node "$node" "mkdir -p '$REMOTE_DIR'"
        copy_to_node "$node" "$first" || die "${z}/${node}: copy failed."
    done
}

step_check() {
    local z="$1" node sha free_kb
    # Unpacked size is about the archive size, because the archive is stored (not compressed).
    local need_kb=$(( $(du -k "$ARCHIVE" | cut -f1) + MIN_FREE_GB * 1024 * 1024 ))
    for node in "${NODES[@]}"; do
        sha="$(remote_sha "$node")"
        if [[ -z "$sha" ]] && (( DRY_RUN )); then
            info "[dry-run] ${z}/${node}: archive not copied yet; skipping SHA-256 check"
        else
            [[ "$sha" == "$EXPECTED_SHA" ]] || die "${z}/${node}: SHA-256 mismatch or archive missing (${sha:-none})"
            info "${z}/${node}: SHA-256 OK"
        fi
        free_kb="$(on_node "$node" "d='$EXTRACT_ROOT'; while [ ! -d \"\$d\" ]; do d=\$(dirname \"\$d\"); done; df -Pk \"\$d\"" | awk 'NR == 2 { print $4 }')"
        [[ "$free_kb" =~ ^[0-9]+$ ]] || die "${z}/${node}: cannot read free space for $EXTRACT_ROOT"
        info "${z}/${node}: $(( free_kb / 1024 / 1024 ))G free for $EXTRACT_ROOT (need $(( need_kb / 1024 / 1024 ))G)"
        (( free_kb >= need_kb )) || die "${z}/${node}: not enough free space in $EXTRACT_ROOT"
        if on_node "$node" "[ -e '$STAGE_DIR' ]"; then
            die "${z}/${node}: $STAGE_DIR already exists. Remove it or use another --extract-root."
        fi
    done
}

step_extract() {
    local z="$1" node unpack
    case "$ARCHIVE" in
        *.zip) unpack="unzip -q '$REMOTE_ARCHIVE' -d '$STAGE_DIR'" ;;
        *.tar) unpack="tar -xf '$REMOTE_ARCHIVE' -C '$STAGE_DIR'" ;;
    esac
    for node in "${NODES[@]}"; do
        change_on_node "$node" "mkdir -p '$STAGE_DIR' && $unpack" || die "${z}/${node}: unpack failed."
        if (( ! DRY_RUN )); then
            info "${z}/${node}: $(on_node "$node" "find '$STAGE_DIR' -type f | wc -l") file(s) in $STAGE_DIR"
        fi
    done
}

# ---------------------------------------------------------------------------
# Per-node steps after unpacking. Fill these in later. Each runs once per node;
# use change_on_node for anything that changes the node, so dry run still works.
# $1 = appliance, $2 = node
# ---------------------------------------------------------------------------
post_unpack_patch_zips() {
    # TODO: unzip the Oracle patch zips inside $STAGE_DIR to where racli expects them.
    info "$1/$2: TODO unpack patch zips inside $STAGE_DIR"
}

post_set_permissions() {
    # TODO: set owner and permissions the patch README asks for.
    info "$1/$2: TODO set ownership and permissions"
}

post_place_precheck() {
    # TODO: put the precheck script where zdlra_patch.sh expects it (PRECHECK_SCRIPT).
    info "$1/$2: TODO place the precheck script"
}

step_post() {
    local z="$1" node
    for node in "${NODES[@]}"; do
        post_unpack_patch_zips "$z" "$node"
        post_set_permissions "$z" "$node"
        post_place_precheck "$z" "$node"
    done
}

stage_appliance() {
    local z="$1"
    info "======== $z ========"
    info "== nodes ==";      step_nodes "$z"
    info "== distribute =="; step_distribute "$z"
    info "== check ==";      step_check "$z"
    info "== extract ==";    step_extract "$z"
    info "== post ==";       step_post "$z"
    info "${z}: staged in $STAGE_DIR on ${NODES[*]}"
}

# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    init_log
    verify_local

    # Each appliance runs in a subshell, so a failure (die) ends only that appliance.
    local z rc failed=0 results=()
    for z in "${ZDLRAS[@]}"; do
        rc=0
        ( stage_appliance "$z" ) || rc=$?
        if (( rc == 0 )); then
            results+=("OK      $z")
        else
            results+=("FAILED  $z")
            failed=$((failed + 1))
            if (( ! KEEP_GOING )); then
                err "Stopping after $z failed (use --keep-going to continue with the others)."
                break
            fi
        fi
    done

    info "======== summary ========"
    local r
    for r in "${results[@]}"; do info "  $r"; done
    local skipped=$(( ${#ZDLRAS[@]} - ${#results[@]} ))
    (( skipped > 0 )) && info "  ($skipped appliance(s) not started)"
    info "Log: $LOG_FILE"
    (( DRY_RUN )) && info "Dry run: nothing was copied or unpacked. Add --execute to run it."
    (( failed == 0 ))
}

main "$@"
