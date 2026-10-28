#!/usr/bin/env bash
#
# zdlra_stage.sh - stage a patch archive on every ZDLRA compute node
#
# Step 2 of staging. Copy-ZdlraPatches.ps1 brings the patch folder to a Windows PC as
# one archive (.zip or .tar) plus <archive>.sha256. Once that archive is on one compute
# node, run this script there as root. It:
#
#   verify      checks the archive's SHA-256 on this node
#   distribute  copies the archive to the other nodes (scp)
#   check       verifies the SHA-256 and free space on every node
#   extract     unpacks the archive on every node into <extract root>/<archive name>/
#   post        per-node steps after unpacking (TODO hooks, filled in later)
#
# STATUS: skeleton. Commands that change something run only with --execute.
#
# Usage:
#   ./zdlra_stage.sh [options] -a ARCHIVE
#
# Options:
#   -a, --archive FILE      archive on this node (required)
#   -s, --sha-file FILE     checksum file (default: ARCHIVE.sha256)
#   -n, --nodes LIST        comma-separated compute nodes (default: from olsnodes)
#   -d, --extract-root DIR  where to unpack on each node (default: /radump/zdlra_stage)
#   -x, --execute           run commands for real (default is dry run)
#   -h, --help              show this help

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
VERSION="0.1.0"

ARCHIVE=""
SHA_FILE=""
NODES_ARG=""
EXTRACT_ROOT="/radump/zdlra_stage"
DRY_RUN=1
MIN_FREE_GB=20                  # free space needed beyond the unpacked size
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15)
LOG_DIR="/radump/zdlra_stage_logs"
LOG_FILE=""

NODES=()
THIS_NODE="$(hostname)"; THIS_NODE="${THIS_NODE%%.*}"   # short name

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

# Paths go into remote shell commands, so allow only plain characters.
safe_path() { [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ && "$1" != *..* ]]; }

is_local() { [[ "$1" == "$THIS_NODE" || "$1" == "$(hostname)" || "$1" == localhost ]]; }

# Run a command string on a node: locally for this node, over ssh for the others.
on_node() {
    local node="$1"; shift
    if is_local "$node"; then
        bash -c "$*"
    else
        ssh "${SSH_OPTS[@]}" "root@${node}" "$*"
    fi
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

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
parse_args() {
    while (( $# )); do
        case "$1" in
            -a|--archive)      ARCHIVE="$2"; shift 2 ;;
            -s|--sha-file)     SHA_FILE="$2"; shift 2 ;;
            -n|--nodes)        NODES_ARG="$2"; shift 2 ;;
            -d|--extract-root) EXTRACT_ROOT="$2"; shift 2 ;;
            -x|--execute)      DRY_RUN=0; shift ;;
            -h|--help)         usage; exit 0 ;;
            *)                 die "Unknown argument: $1 (see --help)" ;;
        esac
    done
    [[ -n "$ARCHIVE" ]] || { usage; exit 1; }
    ARCHIVE="$(cd "$(dirname "$ARCHIVE")" 2>/dev/null && pwd)/$(basename "$ARCHIVE")" || die "Bad archive path."
    SHA_FILE="${SHA_FILE:-${ARCHIVE}.sha256}"
    safe_path "$ARCHIVE"      || die "Archive path has unsupported characters: $ARCHIVE"
    safe_path "$EXTRACT_ROOT" || die "Extract root has unsupported characters: $EXTRACT_ROOT"
    case "$ARCHIVE" in
        *.zip|*.tar) ;;
        *) die "Archive must be .zip or .tar: $ARCHIVE" ;;
    esac
}

# Compute nodes from --nodes, or from the cluster (olsnodes).
find_nodes() {
    if [[ -n "$NODES_ARG" ]]; then
        IFS=',' read -r -a NODES <<<"$NODES_ARG"
    else
        local ols
        ols="$(command -v olsnodes 2>/dev/null || ls /u01/app/*/grid/bin/olsnodes 2>/dev/null | head -1 || true)"
        [[ -n "$ols" ]] || die "olsnodes not found; pass --nodes node1,node2"
        mapfile -t NODES < <("$ols" 2>/dev/null)
    fi
    (( ${#NODES[@]} )) || die "No compute nodes found."
    local n
    for n in "${NODES[@]}"; do
        [[ "$n" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "Bad node name: $n"
    done
}

init_log() {
    mkdir -p "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/stage_$(date +%Y%m%d_%H%M%S).log"
    info "$SCRIPT_NAME $VERSION  dry_run=$DRY_RUN"
    info "Archive:      $ARCHIVE"
    info "Nodes:        ${NODES[*]} (this node: $THIS_NODE)"
    [[ "$(id -un)" == root ]] || die "Run as root."
}

ARCHIVE_NAME=""
STAGE_DIR=""
EXPECTED_SHA=""

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
step_verify() {
    info "== verify =="
    [[ -f "$ARCHIVE" ]]  || die "Archive not found: $ARCHIVE"
    [[ -f "$SHA_FILE" ]] || die "Checksum file not found: $SHA_FILE (copy it with the archive)"
    EXPECTED_SHA="$(awk 'NR == 1 { print tolower($1) }' "$SHA_FILE")"
    [[ "$EXPECTED_SHA" =~ ^[0-9a-f]{64}$ ]] || die "No SHA-256 found in $SHA_FILE"
    local actual
    actual="$(sha256sum "$ARCHIVE" | cut -d' ' -f1)"
    [[ "$actual" == "$EXPECTED_SHA" ]] || die "SHA-256 mismatch on $THIS_NODE: $actual, expected $EXPECTED_SHA"
    info "SHA-256 OK on $THIS_NODE ($(du -h "$ARCHIVE" | cut -f1))"

    ARCHIVE_NAME="$(basename "$ARCHIVE")"
    STAGE_DIR="${EXTRACT_ROOT}/${ARCHIVE_NAME%.*}"
    info "Unpack to:    $STAGE_DIR (on every node)"
}

step_distribute() {
    info "== distribute =="
    local node
    for node in "${NODES[@]}"; do
        if is_local "$node"; then
            info "${node}: has the archive (this node)"
            continue
        fi
        on_node "$node" "true" || die "Cannot ssh to root@${node} without a password. Check SSH equivalence."
        change_on_node "$node" "mkdir -p '$(dirname "$ARCHIVE")'"
        if (( DRY_RUN )); then
            info "[dry-run] scp $ARCHIVE root@${node}:$ARCHIVE"
        else
            info "[exec] scp $ARCHIVE root@${node}:$ARCHIVE"
            scp -q "${SSH_OPTS[@]}" "$ARCHIVE" "root@${node}:$ARCHIVE" || die "scp to $node failed."
        fi
    done
}

step_check() {
    info "== check =="
    # Unpacked size is about the archive size, because the archive is stored (not compressed).
    local need_kb=$(( $(du -k "$ARCHIVE" | cut -f1) + MIN_FREE_GB * 1024 * 1024 ))
    local node sha free_kb
    for node in "${NODES[@]}"; do
        if (( DRY_RUN )) && ! is_local "$node"; then
            info "[dry-run] ${node}: archive not copied yet; skipping SHA-256 check"
        else
            sha="$(on_node "$node" "sha256sum '$ARCHIVE' | cut -d' ' -f1")" || die "${node}: cannot read $ARCHIVE"
            [[ "$sha" == "$EXPECTED_SHA" ]] || die "${node}: SHA-256 mismatch ($sha)"
            info "${node}: SHA-256 OK"
        fi
        free_kb="$(on_node "$node" "mkdir -p '$EXTRACT_ROOT' 2>/dev/null; df -Pk '$EXTRACT_ROOT' 2>/dev/null || df -Pk '$(dirname "$EXTRACT_ROOT")'" | awk 'NR == 2 { print $4 }')"
        [[ "$free_kb" =~ ^[0-9]+$ ]] || die "${node}: cannot read free space for $EXTRACT_ROOT"
        info "${node}: $(( free_kb / 1024 / 1024 ))G free for $EXTRACT_ROOT (need $(( need_kb / 1024 / 1024 ))G)"
        (( free_kb >= need_kb )) || die "${node}: not enough free space in $EXTRACT_ROOT"
        if on_node "$node" "[ -e '$STAGE_DIR' ]"; then
            die "${node}: $STAGE_DIR already exists. Remove it or use another --extract-root."
        fi
    done
}

step_extract() {
    info "== extract =="
    local node unpack
    case "$ARCHIVE" in
        *.zip) unpack="unzip -q '$ARCHIVE' -d '$STAGE_DIR'" ;;
        *.tar) unpack="tar -xf '$ARCHIVE' -C '$STAGE_DIR'" ;;
    esac
    for node in "${NODES[@]}"; do
        change_on_node "$node" "mkdir -p '$STAGE_DIR' && $unpack" || die "${node}: unpack failed."
        if (( ! DRY_RUN )); then
            info "${node}: $(on_node "$node" "find '$STAGE_DIR' -type f | wc -l") file(s) in $STAGE_DIR"
        fi
    done
}

# ---------------------------------------------------------------------------
# Per-node steps after unpacking. Fill these in later. Each runs once per node;
# use change_on_node for anything that changes the node, so dry run still works.
# ---------------------------------------------------------------------------
post_unpack_patch_zips() {
    local node="$1"
    # TODO: unzip the Oracle patch zips inside $STAGE_DIR to where racli expects them.
    info "${node}: TODO unpack patch zips inside $STAGE_DIR"
}

post_set_permissions() {
    local node="$1"
    # TODO: set owner and permissions the patch README asks for.
    info "${node}: TODO set ownership and permissions"
}

post_place_precheck() {
    local node="$1"
    # TODO: put the precheck script where zdlra_patch.sh expects it (PRECHECK_SCRIPT).
    info "${node}: TODO place the precheck script"
}

step_post() {
    info "== post =="
    local node
    for node in "${NODES[@]}"; do
        post_unpack_patch_zips "$node"
        post_set_permissions "$node"
        post_place_precheck "$node"
    done
}

# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    find_nodes
    init_log
    step_verify
    step_distribute
    step_check
    step_extract
    step_post
    info "Done. Staged in $STAGE_DIR on: ${NODES[*]}"
    (( DRY_RUN )) && info "Dry run: nothing was copied or unpacked. Add --execute to run it."
    return 0
}

main "$@"
