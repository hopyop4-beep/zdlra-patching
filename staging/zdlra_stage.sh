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
#   check       verifies the SHA-256 and free space on every node; nodes already
#               staged with this archive are skipped from here on
#   extract     unpacks the archive on every node into <extract root>/<archive name>/
#   place       on every node: moves the patch files to PATCH_TARGET_DIR and the
#               precheck folder to PRECHECK_TARGET_DIR, updates the precheck's config
#               file, checks the result, and writes a "staged" record
#
# Oracle's precheck (run by zdlra_patch.sh) then confirms the files are in place; the
# staged record tells zdlra_patch.sh which archive was staged.
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
#   -c, --config FILE       settings for the place step (default: zdlra_stage.conf next
#                           to this script, if it exists)
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
VERSION="0.3.0"

ARCHIVE=""
SHA_FILE=""
ZDLRAS=()
CONFIG_FILE="${SCRIPT_DIR}/zdlra_stage.conf"
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

# Place step. TODO(site): the defaults below are placeholders until the real
# directories and precheck settings are known; override them in zdlra_stage.conf.
PATCH_TARGET_DIR="/radump/ra_patches"          # where the patch files go
PATCH_FILES_GLOB="*.zip"                       # which files in the archive are patch files
PRECHECK_SRC_SUBDIR="precheck"                 # precheck folder inside the archive
PRECHECK_TARGET_DIR="/radump/ra_precheck"      # where the precheck folder goes
PRECHECK_CONF_FILE="precheck.conf"             # precheck's config file, inside PRECHECK_TARGET_DIR
# KEY=VALUE lines to set in that file. {patch_dir} and {precheck_dir} are replaced
# with PATCH_TARGET_DIR and PRECHECK_TARGET_DIR.
PRECHECK_CONF_SETTINGS=("PATCH_DIR={patch_dir}")
STAGED_RECORD_NAME="ZDLRA_STAGED.txt"          # written in PATCH_TARGET_DIR on each node

ARCHIVE_NAME=""
REMOTE_ARCHIVE=""
STAGE_DIR=""
EXPECTED_SHA=""
NODES=()
TODO_NODES=()                   # nodes of the current appliance that still need staging

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
safe_name() { [[ "$1" =~ ^[A-Za-z0-9._*-]+$ && "$1" != *..* ]]; }

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

# SHA-256 in the node's staged record, or empty if it has none.
staged_sha() {
    on_node "$1" "sed -n 's/^sha256=//p' '${PATCH_TARGET_DIR}/${STAGED_RECORD_NAME}' 2>/dev/null" 2>/dev/null || true
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
            -c|--config)       CONFIG_FILE="$2"; shift 2 ;;
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
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi
}

validate() {
    local z kv
    for z in "${ZDLRAS[@]}"; do safe_host "$z" || die "Bad appliance name: $z"; done
    [[ "$SSH_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "Bad ssh user: $SSH_USER"
    local p
    for p in "$REMOTE_DIR" "$EXTRACT_ROOT" "$PATCH_TARGET_DIR" "$PRECHECK_TARGET_DIR"; do
        safe_path "$p" || die "Path has unsupported characters: $p"
    done
    safe_name "$PATCH_FILES_GLOB"    || die "Bad PATCH_FILES_GLOB: $PATCH_FILES_GLOB"
    safe_name "$PRECHECK_SRC_SUBDIR" || die "Bad PRECHECK_SRC_SUBDIR: $PRECHECK_SRC_SUBDIR"
    safe_name "$PRECHECK_CONF_FILE"  || die "Bad PRECHECK_CONF_FILE: $PRECHECK_CONF_FILE"
    safe_name "$STAGED_RECORD_NAME"  || die "Bad STAGED_RECORD_NAME: $STAGED_RECORD_NAME"
    # Settings are written with sed on the node, so keep them to plain characters.
    for kv in ${PRECHECK_CONF_SETTINGS[@]+"${PRECHECK_CONF_SETTINGS[@]}"}; do
        [[ "$kv" =~ ^[A-Za-z_][A-Za-z0-9_]*=[A-Za-z0-9_./:,@+{}-]*$ ]] || die "Bad PRECHECK_CONF_SETTINGS entry: $kv"
    done
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
    info "Place:        $PATCH_FILES_GLOB -> $PATCH_TARGET_DIR, $PRECHECK_SRC_SUBDIR/ -> $PRECHECK_TARGET_DIR"
    [[ -f "$CONFIG_FILE" ]] || warn "No $CONFIG_FILE; using the built-in placeholder directories (TODO)."
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
        if [[ "$(staged_sha "$node")" == "$EXPECTED_SHA" ]]; then
            info "${z}/${node}: already staged with this archive; not copying"
            continue
        fi
        if [[ "$(remote_sha "$node")" == "$EXPECTED_SHA" ]]; then
            info "${z}/${node}: already has the archive (SHA-256 matches); not copying"
            continue
        fi
        change_on_node "$node" "mkdir -p '$REMOTE_DIR'"
        copy_to_node "$node" "$first" || die "${z}/${node}: copy failed."
    done
}

# Decides which nodes still need staging (TODO_NODES). A node whose staged record
# names this archive is done; a node with a half-finished staging is refused.
step_check() {
    local z="$1" node sha free_kb
    # Unpacked size is about the archive size, because the archive is stored (not compressed).
    local need_kb=$(( $(du -k "$ARCHIVE" | cut -f1) + MIN_FREE_GB * 1024 * 1024 ))
    TODO_NODES=()
    for node in "${NODES[@]}"; do
        if [[ "$(staged_sha "$node")" == "$EXPECTED_SHA" ]]; then
            info "${z}/${node}: already staged with this archive (record in $PATCH_TARGET_DIR); skipping"
            continue
        fi
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
            die "${z}/${node}: $STAGE_DIR exists but the node has no staged record for this archive (an earlier staging stopped partway?). Check it and remove it, or use another --extract-root."
        fi
        TODO_NODES+=("$node")
    done
}

step_extract() {
    local z="$1" node unpack
    case "$ARCHIVE" in
        *.zip) unpack="unzip -q '$REMOTE_ARCHIVE' -d '$STAGE_DIR'" ;;
        *.tar) unpack="tar -xf '$REMOTE_ARCHIVE' -C '$STAGE_DIR'" ;;
    esac
    for node in ${TODO_NODES[@]+"${TODO_NODES[@]}"}; do
        change_on_node "$node" "mkdir -p '$STAGE_DIR' && $unpack" || die "${z}/${node}: unpack failed."
        if (( ! DRY_RUN )); then
            info "${z}/${node}: $(on_node "$node" "find '$STAGE_DIR' -type f | wc -l") file(s) in $STAGE_DIR"
        fi
    done
}

# ---------------------------------------------------------------------------
# Place step: runs on the node as one bash script (fed on stdin). Arguments:
#   <dry> <stage dir> <patch target> <precheck src subdir> <precheck target>
#   <files glob> <conf file> <record name> <archive> <sha256> <from host> [KEY=VALUE ...]
# Paths are passed as arguments, never written into the script itself.
# ---------------------------------------------------------------------------
PLACE_SCRIPT=$(cat <<'REMOTE'
set -uo pipefail
dry=$1 stage=$2 ptarget=$3 csub=$4 ctarget=$5 glob=$6 conf=$7 record=$8 archive=$9 sha=${10} from=${11}
shift 11
fail() { echo "ERROR $*"; exit 1; }
do_or_say() { if [ "$dry" = 1 ]; then echo "[dry-run] $*"; else "$@" || fail "command failed: $*"; fi; }

if [ "$dry" = 1 ]; then
    echo "[dry-run] would move $glob from $stage/<top folder>/ to $ptarget/"
    echo "[dry-run] would move $stage/<top folder>/$csub/ to $ctarget/"
    for kv in "$@"; do
        k=${kv%%=*}
        cur=$(grep -m1 "^$k=" "$ctarget/$conf" 2>/dev/null || true)
        echo "[dry-run] would set in $ctarget/$conf: $kv (now: ${cur:-not set, or file not there yet})"
    done
    echo "[dry-run] would write $ptarget/$record"
    exit 0
fi

# The archive holds one top folder (the patch folder that was zipped).
tops=$(find "$stage" -mindepth 1 -maxdepth 1 -type d)
[ "$(printf '%s\n' "$tops" | grep -c .)" = 1 ] || fail "expected one top folder in $stage, found: $(echo $tops)"
src=$tops

# Check everything before moving anything, so a problem never leaves a node half-staged.
shopt -s nullglob
files=( "$src"/$glob )
[ ${#files[@]} -gt 0 ] || fail "no $glob files in $src"
[ -d "$src/$csub" ] || fail "no $csub/ folder in $src"
[ -f "$src/$csub/$conf" ] || fail "precheck config $csub/$conf not found in the archive"
[ ! -e "$ctarget" ] || fail "$ctarget already exists; move it aside first"
for f in "${files[@]}"; do
    name=$(basename "$f")
    if [ -e "$ptarget/$name" ] && ! cmp -s "$f" "$ptarget/$name"; then
        fail "$ptarget/$name exists and differs from the staged file; not overwriting"
    fi
done
echo "OK checks passed: ${#files[@]} patch file(s), $csub/ with $conf, targets free"

# 1. Patch files. A file already at the target is kept (it was checked to be identical).
mkdir -p "$ptarget" || fail "cannot create $ptarget"
placed=()
for f in "${files[@]}"; do
    name=$(basename "$f")
    if [ -e "$ptarget/$name" ]; then
        echo "OK already in place: $ptarget/$name"
    else
        mv "$f" "$ptarget/$name" || fail "cannot move $name to $ptarget"
        echo "OK moved $name -> $ptarget/"
    fi
    placed+=("$name")
done

# 2. Precheck folder.
mkdir -p "$(dirname "$ctarget")" || fail "cannot create $(dirname "$ctarget")"
mv "$src/$csub" "$ctarget" || fail "cannot move $csub/ to $ctarget"
echo "OK moved $csub/ -> $ctarget/"

# 3. Precheck config: keep the original, then set each KEY=VALUE.
c="$ctarget/$conf"
cp -p "$c" "$c.orig" || fail "cannot back up $c"
for kv in "$@"; do
    k=${kv%%=*}
    if grep -q "^$k=" "$c"; then
        sed -i "s|^$k=.*|$kv|" "$c" || fail "cannot update $k in $c"
    else
        echo "$kv" >> "$c" || fail "cannot add $k to $c"
    fi
done
echo "OK updated $c (original kept as $c.orig); changes:"
diff "$c.orig" "$c" | sed 's/^/   /'

# 4. Check the result.
for name in "${placed[@]}"; do
    [ -s "$ptarget/$name" ] || fail "check: $ptarget/$name missing"
done
for kv in "$@"; do
    grep -qxF "$kv" "$c" || fail "check: $c does not contain $kv"
done
echo "OK checked: ${#placed[@]} patch file(s) in $ptarget, precheck config updated"

# 5. Staged record, read by zdlra_patch.sh.
{
    echo "archive=$archive"
    echo "sha256=$sha"
    echo "staged_at=$(date '+%F %T %Z')"
    echo "staged_from=$from"
    echo "patch_dir=$ptarget"
    echo "precheck_dir=$ctarget"
    for name in "${placed[@]}"; do echo "file=$name"; done
} > "$ptarget/$record" || fail "cannot write $ptarget/$record"
echo "OK wrote $ptarget/$record"
REMOTE
)

step_place() {
    local z="$1" node kv out rc
    local settings=()
    for kv in ${PRECHECK_CONF_SETTINGS[@]+"${PRECHECK_CONF_SETTINGS[@]}"}; do
        kv="${kv//\{patch_dir\}/$PATCH_TARGET_DIR}"
        settings+=("'${kv//\{precheck_dir\}/$PRECHECK_TARGET_DIR}'")
    done
    local args="'$DRY_RUN' '$STAGE_DIR' '$PATCH_TARGET_DIR' '$PRECHECK_SRC_SUBDIR' '$PRECHECK_TARGET_DIR'"
    args+=" '$PATCH_FILES_GLOB' '$PRECHECK_CONF_FILE' '$STAGED_RECORD_NAME' '$ARCHIVE_NAME' '$EXPECTED_SHA' '$(hostname)'"
    args+=" ${settings[*]-}"
    for node in ${TODO_NODES[@]+"${TODO_NODES[@]}"}; do
        rc=0
        out="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${node}" "bash -s -- $args" <<<"$PLACE_SCRIPT" 2>&1)" || rc=$?
        printf '%s\n' "$out" | sed "s|^|  ${z}/${node}: |" | tee -a "$LOG_FILE" >&2
        (( rc == 0 )) || die "${z}/${node}: place step failed (see above). Files moved so far stay where they are."
    done
}

stage_appliance() {
    local z="$1"
    info "======== $z ========"
    info "== nodes ==";      step_nodes "$z"
    info "== distribute =="; step_distribute "$z"
    info "== check ==";      step_check "$z"
    if (( ${#TODO_NODES[@]} == 0 )); then
        info "${z}: every node is already staged with this archive."
        return 0
    fi
    info "== extract ==";    step_extract "$z"
    info "== place ==";      step_place "$z"
    if (( DRY_RUN )); then
        info "${z}: dry run passed; would stage on ${TODO_NODES[*]}"
    else
        info "${z}: staged on ${TODO_NODES[*]} (patches in $PATCH_TARGET_DIR, precheck in $PRECHECK_TARGET_DIR)"
    fi
}

# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    load_config
    validate
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
    # exit, not a failing test, so the ERR trap does not report a bogus line number.
    if (( failed > 0 )); then exit 1; fi
    return 0
}

main "$@"
