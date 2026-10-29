#!/usr/bin/env bash
#
# zdlra_stage.sh - stage patches.zip on the compute nodes of one or more ZDLRAs
#
# Step 2 of staging. Runs on a jump server that holds patches.zip (plus
# patches.zip.sha256) and can reach the appliances over ssh. Unzipped, the archive is
# /radump/patches/ with patches/ (the patch files), conf/ (patch.conf_<SR>), bin/,
# tmp/ and so on. The conf file lists the right patches and versions, but its
# component settings (COMPUTE_NODE ... RA_DATABASE) come from the appliance it was
# prepared on, so they are rewritten for each appliance this script stages.
#
#   verify      on the jump server: checks the SHA-256, reads patch.conf_<SR> from the
#               zip, and checks every file its FILES_* variables name is in patches/
#   nodes       finds the compute nodes (inventory file, or olsnodes on the appliance)
#               and works out the appliance's component values (see below)
#   distribute  copies the archive to every node as /radump/patches.zip (skips nodes
#               that already have it); an older patches.zip is backed up or replaced
#   check       verifies the SHA-256 and free space on every node; nodes already
#               staged with this archive are skipped from here on
#   extract     unzips it in /radump, giving /radump/patches/; an older
#               /radump/patches/ is backed up or replaced first
#   configure   on every node: checks the patch files are there, rewrites the
#               component settings in patch.conf_<SR> (original kept as .orig), checks
#               the result, and writes /radump/patches/ZDLRA_STAGED.txt
#
# Component values, per appliance, come from the appliance itself: the jump server
# reads /root/dbs_group (COMPUTE_NODE; its first line is COMPUTE_NODE_01 and
# CELL_PATCH_LAUNCH_NODE), /root/cell_group (CELL_NODE) and the switch group file
# (SWITCHES and IB_SWITCHES; on a RoCE rack both hold the RoCE switches) on the first
# compute node, and works out SWITCH_TYPE and RA_DATABASE there (COMPONENT_CMDS).
# If a group file is missing, the script pauses and asks you to create it.
# dbs_group must match the compute nodes being staged. components/<appliance>.conf
# next to this script can override any value. An appliance with any value missing
# is refused, so a conf file with another appliance's components is never left behind.
#
# Older versions (OLD_VERSION_ACTION=backup, the default): the first older version
# is kept as <name>.<date>.bak. Once a backup exists, later older versions are
# replaced without another backup, so only the oldest is kept.
#
# STATUS: skeleton. Commands that change something run only with --execute.
#
# Usage:
#   ./zdlra_stage.sh [options] -a patches.zip -z ZDLRA [-z ZDLRA ...]
#
# Options:
#   -a, --archive FILE      archive on this jump server (required)
#   -s, --sha-file FILE     checksum file (default: ARCHIVE.sha256)
#   -z, --zdlra NAME        appliance to stage; repeat for several (required)
#   -c, --config FILE       settings (default: zdlra_stage.conf next to this script, if any)
#   -i, --inventory FILE    appliance-to-nodes list (default: appliances.conf next to
#                           this script); appliances not listed use olsnodes
#   -u, --user USER         ssh user on the nodes (default: root)
#   -r, --remote-dir DIR    where the archive is copied on each node (default: /radump)
#   -d, --extract-root DIR  where it is unzipped on each node (default: /radump)
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
VERSION="0.5.0"

ARCHIVE=""
SHA_FILE=""
ZDLRAS=()
CONFIG_FILE="${SCRIPT_DIR}/zdlra_stage.conf"
INVENTORY="${SCRIPT_DIR}/appliances.conf"
COMPONENTS_DIR="${SCRIPT_DIR}/components"
SSH_USER="root"
REMOTE_DIR="/radump"
REMOTE_ARCHIVE_NAME="patches.zip"   # name of the archive on the nodes
EXTRACT_ROOT="/radump"
# What to do with an older patches.zip, or an older unzipped folder, on a node:
#   backup     keep the oldest older version as <name>.<date>.bak (default)
#   overwrite  replace it
OLD_VERSION_ACTION="backup"
RELAY=0
KEEP_GOING=0
DRY_RUN=1
MIN_FREE_GB=20                  # free space needed beyond the unpacked size
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15)
LOG_DIR="${HOME}/zdlra_stage_logs"
LOG_FILE=""

# Layout inside the unzipped folder, and the conf file.
PATCHES_SUBDIR="patches"        # the patch files
CONF_SUBDIR="conf"
CONF_GLOB="patch.conf_*"        # exactly one, e.g. patch.conf_4-003351830
# Settings in the conf file rewritten for each appliance.
COMPONENT_VARS=(COMPUTE_NODE COMPUTE_NODE_01 CELL_NODE CELL_PATCH_LAUNCH_NODE
                SWITCH_TYPE SWITCHES IB_SWITCHES RA_DATABASE)
# Group files on the appliance's first compute node. They must exist and not be
# empty; if one is missing the script pauses and asks you to create it.
DBS_GROUP_FILE="/root/dbs_group"        # compute nodes, one per line
CELL_GROUP_FILE="/root/cell_group"      # storage cells, one per line
SWITCH_GROUP_FILE="/root/switch_group"  # switches, one per line (RoCE switches on a RoCE rack)
# How each component value is found: a command run on the appliance's first compute
# node (as SSH_USER). Its output lines are joined with commas.
# components/<appliance>.conf, if present, overrides any of them.
# On a RoCE rack the RoCE switch names go in IB_SWITCHES as well, so both read the
# switch group file. RA_DATABASE comes from the database's pmon process.
# TODO(site): SWITCH_TYPE (from the network interface names) is still a guess.
# The config can set any entry; default_component_cmds fills in the rest after the
# config is loaded, so it uses the group file paths from the config.
declare -A COMPONENT_CMDS=()

default_component_cmds() {
    local first="grep -v '^[[:space:]]*\$' '$DBS_GROUP_FILE' | head -1"
    declare -A defaults=(
        [COMPUTE_NODE]="cat '$DBS_GROUP_FILE'"
        [COMPUTE_NODE_01]="$first"
        [CELL_PATCH_LAUNCH_NODE]="$first"
        [CELL_NODE]="cat '$CELL_GROUP_FILE'"
        [SWITCHES]="cat '$SWITCH_GROUP_FILE'"
        [IB_SWITCHES]="cat '$SWITCH_GROUP_FILE'"
        [SWITCH_TYPE]='if ls /sys/class/net | grep -qE "^re[0-9]"; then echo roce; elif ls /sys/class/net | grep -qE "^ib[0-9]"; then echo IB; fi'
        # pmon of the RA database instance (ora_pmon_<db><n>), minus the instance number.
        [RA_DATABASE]="ps -eo args | sed -n 's/^ora_pmon_//p' | sed 's/[0-9]\$//' | sort -u"
    )
    local key
    for key in "${!defaults[@]}"; do
        [[ -n "${COMPONENT_CMDS[$key]:-}" ]] || COMPONENT_CMDS[$key]="${defaults[$key]}"
    done
}
# Settings in the conf file that name patch files (checked in PATCHES_SUBDIR).
# Values are comma-separated file names: FILES_PATCHBASE, FILES_SWITCH, FILES_YUM,
# FILES_CELL, FILES_RA, plus STAGE_FILE and FRAMEWORK_FILE.
FILE_VARS_RE='^(FILES_[A-Z0-9_]+|STAGE_FILE|FRAMEWORK_FILE)$'
STAGED_RECORD_NAME="ZDLRA_STAGED.txt"   # written in the unzipped folder on each node

ARCHIVE_NAME=""
REMOTE_ARCHIVE=""
RUN_STAMP="$(date +%Y%m%d_%H%M%S)"   # suffix for backups made by this run
STAGE_DIR=""                    # unzipped folder on the nodes, e.g. /radump/patches
UNPACK_INTO=""                  # where unzip runs, e.g. /radump
ZIP_PREFIX=""                   # top folder inside the zip, e.g. "patches/"
CONF_NAME=""                    # e.g. patch.conf_4-003351830
CONF_TEXT=""                    # its contents, read from the zip
PATCH_FILES=()                  # files named by the FILES_* settings
EXPECTED_SHA=""
NODES=()
TODO_NODES=()                   # nodes of the current appliance that still need staging
declare -A COMP=()              # component values for the current appliance

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
safe_path()  { [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ && "$1" != *..* ]]; }
safe_host()  { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; }
safe_name()  { [[ "$1" =~ ^[A-Za-z0-9._*-]+$ && "$1" != *..* ]]; }
safe_value() { [[ "$1" =~ ^[A-Za-z0-9_.,:@-]*$ ]]; }

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
    on_node "$1" "sed -n 's/^sha256=//p' '${STAGE_DIR}/${STAGED_RECORD_NAME}' 2>/dev/null" 2>/dev/null || true
}

# Value of KEY in conf text ($1 = text, $2 = key), without surrounding quotes.
conf_value() {
    sed -n "s/^$2=//p" <<<"$1" | head -1 | sed -E "s/^\"(.*)\"$/\\1/; s/^'(.*)'$/\\1/"
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
    local z p v
    for z in "${ZDLRAS[@]}"; do safe_host "$z" || die "Bad appliance name: $z"; done
    [[ "$SSH_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "Bad ssh user: $SSH_USER"
    for p in "$REMOTE_DIR" "$EXTRACT_ROOT" "$DBS_GROUP_FILE" "$CELL_GROUP_FILE" "$SWITCH_GROUP_FILE"; do
        safe_path "$p" || die "Path has unsupported characters: $p"
    done
    for v in "$PATCHES_SUBDIR" "$CONF_SUBDIR" "$CONF_GLOB" "$STAGED_RECORD_NAME"; do
        safe_name "$v" || die "Setting has unsupported characters: $v"
    done
    for v in "${COMPONENT_VARS[@]}"; do
        [[ "$v" =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "Bad name in COMPONENT_VARS: $v"
    done
    case "$ARCHIVE" in
        *.zip|*.tar) ;;
        *) die "Archive must be .zip or .tar: $ARCHIVE" ;;
    esac
    ARCHIVE_NAME="$(basename "$ARCHIVE")"
    [[ "$ARCHIVE_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "Archive name has unsupported characters: $ARCHIVE_NAME"
    [[ "$REMOTE_ARCHIVE_NAME" =~ ^[A-Za-z0-9._-]+\.(zip|tar)$ ]] || die "Bad REMOTE_ARCHIVE_NAME: $REMOTE_ARCHIVE_NAME"
    [[ "${ARCHIVE##*.}" == "${REMOTE_ARCHIVE_NAME##*.}" ]] \
        || die "$ARCHIVE_NAME is a .${ARCHIVE##*.} but the nodes expect $REMOTE_ARCHIVE_NAME; set REMOTE_ARCHIVE_NAME to match."
    case "$OLD_VERSION_ACTION" in backup|overwrite) ;; *) die "OLD_VERSION_ACTION must be backup or overwrite: $OLD_VERSION_ACTION" ;; esac
    REMOTE_ARCHIVE="${REMOTE_DIR}/${REMOTE_ARCHIVE_NAME}"
}

init_log() {
    mkdir -p "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/stage_$(date +%Y%m%d_%H%M%S).log"
    info "$SCRIPT_NAME $VERSION  dry_run=$DRY_RUN  relay=$RELAY"
    info "Archive:      $ARCHIVE"
    info "Appliances:   ${ZDLRAS[*]}"
    info "On nodes:     copy to $REMOTE_ARCHIVE, unzip in $EXTRACT_ROOT (older versions: $OLD_VERSION_ACTION)"
}

# ---------------------------------------------------------------------------
# Archive checks on the jump server, before touching any appliance
# ---------------------------------------------------------------------------
zip_list() {
    case "$ARCHIVE" in
        *.tar) tar -tf "$ARCHIVE" ;;
        *) if command -v unzip >/dev/null 2>&1; then unzip -Z1 "$ARCHIVE"
           else python3 -c 'import sys, zipfile; print("\n".join(zipfile.ZipFile(sys.argv[1]).namelist()))' "$ARCHIVE"; fi ;;
    esac
}

zip_cat() {
    case "$ARCHIVE" in
        *.tar) tar -xOf "$ARCHIVE" "$1" ;;
        *) if command -v unzip >/dev/null 2>&1; then unzip -p "$ARCHIVE" "$1"
           else python3 -c 'import sys, zipfile; sys.stdout.write(zipfile.ZipFile(sys.argv[1]).read(sys.argv[2]).decode())' "$ARCHIVE" "$1"; fi ;;
    esac
}

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

    local list tops
    list="$(zip_list | sed -E 's#^\./##')" || die "Cannot read the file list of $ARCHIVE"

    # One top folder (patches/) -> unzip straight into EXTRACT_ROOT. Otherwise unzip
    # into a folder of its own, so files are not scattered in EXTRACT_ROOT.
    tops="$(sed -E 's#/.*##' <<<"$list" | grep -v '^$' | sort -u)"
    if [[ "$(grep -c . <<<"$tops")" == 1 ]] && grep -q "^${tops}/" <<<"$list"; then
        [[ "$tops" =~ ^[A-Za-z0-9._-]+$ ]] || die "Top folder in the archive has unsupported characters: $tops"
        ZIP_PREFIX="${tops}/"
        UNPACK_INTO="$EXTRACT_ROOT"
        STAGE_DIR="${EXTRACT_ROOT}/${tops}"
    else
        ZIP_PREFIX=""
        UNPACK_INTO="${EXTRACT_ROOT}/${REMOTE_ARCHIVE_NAME%.*}_zip"
        STAGE_DIR="$UNPACK_INTO"
        warn "Archive has no single top folder; it will be unzipped into $STAGE_DIR"
    fi
    info "Unzips to:    $STAGE_DIR on each node"

    # The conf file: exactly one conf/patch.conf_<SR>.
    local confs pattern
    pattern="^${ZIP_PREFIX}${CONF_SUBDIR}/${CONF_GLOB//\*/[^/]+}$"
    confs="$(grep -E "$pattern" <<<"$list" || true)"
    [[ -n "$confs" ]] || die "No ${CONF_SUBDIR}/${CONF_GLOB} in the archive."
    [[ "$(grep -c . <<<"$confs")" == 1 ]] || die "More than one conf file in the archive: $(tr '\n' ' ' <<<"$confs")"
    CONF_NAME="$(basename "$confs")"
    [[ "$CONF_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "Conf file name has unsupported characters: $CONF_NAME"
    CONF_TEXT="$(zip_cat "$confs" | tr -d '\r')" || die "Cannot read $confs from the archive."
    info "Conf file:    ${CONF_SUBDIR}/${CONF_NAME} (SR ${CONF_NAME#*_})"

    # Patch files named by the FILES_* settings must be in patches/.
    local key value f missing=()
    PATCH_FILES=()
    while IFS='=' read -r key value; do
        [[ "$key" =~ $FILE_VARS_RE ]] || continue
        value="$(sed -E "s/^\"(.*)\"$/\\1/; s/^'(.*)'$/\\1/" <<<"$value")"
        local parts=()
        IFS=',' read -r -a parts <<<"$value"    # comma-separated; no globbing of the raw value
        for f in ${parts[@]+"${parts[@]}"}; do
            f="$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$f")"
            [[ -n "$f" ]] || continue
            f="$(basename "$f")"
            [[ "$f" =~ ^[A-Za-z0-9._+-]+$ ]] || die "Unexpected file name in $key: $f"
            PATCH_FILES+=("$f")
            if grep -qxF "${ZIP_PREFIX}${PATCHES_SUBDIR}/${f}" <<<"$list"; then
                info "  $key: $f"
            else
                missing+=("$f ($key)")
            fi
        done
    done < <(grep -E '^[A-Z_][A-Z0-9_]*=' <<<"$CONF_TEXT")
    (( ${#PATCH_FILES[@]} )) || die "The conf file names no patch files (no ${FILE_VARS_RE} settings with values)."
    (( ${#missing[@]} == 0 )) || die "Not in ${PATCHES_SUBDIR}/ in the archive: ${missing[*]}"
    # A file named by several settings is checked once.
    mapfile -t PATCH_FILES < <(printf '%s\n' "${PATCH_FILES[@]}" | sort -u)
    info "All ${#PATCH_FILES[@]} patch file(s) named in the conf file are in ${PATCHES_SUBDIR}/."
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

# The group files must exist (and not be empty) on the appliance's first compute
# node. If any is missing, pause and ask the operator to create them, then check
# again; without a terminal to ask, stop instead.
wait_for_group_files() {
    local z="$1" node="${NODES[0]}" f missing reply
    while :; do
        missing=()
        for f in "$DBS_GROUP_FILE" "$CELL_GROUP_FILE" "$SWITCH_GROUP_FILE"; do
            on_node "$node" "[ -s '$f' ]" || missing+=("$f")
        done
        (( ${#missing[@]} == 0 )) && return 0

        err "${z}: missing or empty on ${node}: ${missing[*]}"
        {
            echo "  Create them on ${node}, one host name per line:"
            for f in "${missing[@]}"; do
                case "$f" in
                    "$DBS_GROUP_FILE")    echo "    $f    the compute nodes" ;;
                    "$CELL_GROUP_FILE")   echo "    $f    the storage cells" ;;
                    "$SWITCH_GROUP_FILE") echo "    $f    the switches (RoCE switches on a RoCE rack)" ;;
                esac
            done
        } | tee -a "$LOG_FILE" >&2
        [[ -t 0 ]] || die "${z}: cannot wait for the files (no terminal). Create them and run again."
        reply=""
        read -r -p "  Press Enter when they are in place to check again, or type q to stop: " reply || reply=q
        [[ "$reply" != q ]] || die "${z}: stopped by the operator; group files missing on ${node}."
    done
}

# Component values for the appliance, in order of precedence:
#   1. components/<appliance>.conf (optional override; read as KEY=VALUE lines, not run)
#   2. COMPONENT_CMDS, run on the appliance's first compute node (group files etc.)
#   3. the node list (COMPUTE_NODE, COMPUTE_NODE_01, CELL_PATCH_LAUNCH_NODE), if the
#      command for them is unset
# Every COMPONENT_VARS entry must end up set; empty is accepted only when the
# override file sets it on purpose.
step_components() {
    local z="$1" file="${COMPONENTS_DIR}/${1}.conf" key value
    COMP=()
    declare -A given=() source=()
    COMP[COMPUTE_NODE]="$(IFS=,; echo "${NODES[*]}")"
    COMP[COMPUTE_NODE_01]="${NODES[0]}"
    COMP[CELL_PATCH_LAUNCH_NODE]="${NODES[0]}"
    for key in COMPUTE_NODE COMPUTE_NODE_01 CELL_PATCH_LAUNCH_NODE; do source[$key]="node list"; done

    wait_for_group_files "$z"

    # Ask the appliance.
    local out
    for key in "${COMPONENT_VARS[@]}"; do
        [[ -n "${COMPONENT_CMDS[$key]:-}" ]] || continue
        if out="$(on_node "${NODES[0]}" "${COMPONENT_CMDS[$key]}" 2>/dev/null)"; then
            value="$(tr -d '\r' <<<"$out" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$' | paste -sd, -)"
            safe_value "$value" || die "${z}: unexpected output for $key from '${COMPONENT_CMDS[$key]}': $value"
            if [[ -n "$value" ]]; then
                COMP[$key]="$value"
                source[$key]="from ${NODES[0]}"
            fi
        else
            warn "${z}: the command for $key failed on ${NODES[0]}: ${COMPONENT_CMDS[$key]}"
        fi
    done

    if [[ -f "$file" ]]; then
        while IFS='=' read -r key value; do
            key="${key//[[:space:]]/}"
            [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
            [[ " ${COMPONENT_VARS[*]} " == *" $key "* ]] || { warn "${z}: $file: $key is not a component setting; ignored"; continue; }
            value="$(sed -E "s/^[[:space:]]+//; s/[[:space:]]+$//; s/^\"(.*)\"$/\\1/; s/^'(.*)'$/\\1/" <<<"$value")"
            safe_value "$value" || die "${z}: $file: unsupported characters in $key=$value"
            COMP[$key]="$value"
            given[$key]=1
            source[$key]="override in $file"
        done < <(grep -E '^[[:space:]]*[A-Z_][A-Z0-9_]*[[:space:]]*=' "$file")
    fi

    case "${COMP[SWITCH_TYPE]:-}" in
        roce|RoCE|ROCE|ib|IB) ;;
        *) die "${z}: SWITCH_TYPE must be roce or IB (got '${COMP[SWITCH_TYPE]:-}'). Check COMPONENT_CMDS[SWITCH_TYPE] or set it in $file." ;;
    esac
    local missing=()
    for key in "${COMPONENT_VARS[@]}"; do
        [[ -n "${COMP[$key]:-}" || -n "${given[$key]:-}" ]] || missing+=("$key")
    done
    (( ${#missing[@]} == 0 )) || die "${z}: could not find ${missing[*]} on the appliance. Check COMPONENT_CMDS, or set them in $file."
    [[ "${COMP[RA_DATABASE]}" != *,* ]]         || die "${z}: more than one database found for RA_DATABASE (${COMP[RA_DATABASE]}). Set it in $file."

    # dbs_group must list the compute nodes being staged (short names compared), or
    # the conf would point at the wrong nodes.
    local listed staged
    listed="$(tr ',' '\n' <<<"${COMP[COMPUTE_NODE]}" | sed 's/\..*//' | sort -u | paste -sd' ' -)"
    staged="$(printf '%s\n' "${NODES[@]}" | sed 's/\..*//' | sort -u | paste -sd' ' -)"
    [[ "$listed" == "$staged" ]] \
        || die "${z}: COMPUTE_NODE ($listed, ${source[COMPUTE_NODE]:-?}) does not match the compute nodes being staged ($staged). Fix $DBS_GROUP_FILE on ${NODES[0]} or the inventory."

    info "${z}: component settings for ${CONF_NAME} (was -> now):"
    for key in "${COMPONENT_VARS[@]}"; do
        local was
        was="$(conf_value "$CONF_TEXT" "$key")"
        info "    $key: ${was:-<empty>} -> ${COMP[$key]:-<empty>}   (${source[$key]:-?})"
    done
}

# Deal with an older file or folder at $2 on node $1, per OLD_VERSION_ACTION.
# backup: keep it as <path>.<date>.bak, unless a backup already exists - then only
# the oldest backup is kept and the current old version is replaced.
# $3 = what it is, for messages.
set_aside_old() {
    local node="$1" path="$2" what="$3" baks oldest
    if [[ "$OLD_VERSION_ACTION" == overwrite ]]; then
        change_on_node "$node" "rm -rf -- '$path'" || die "${node}: could not remove the old $what."
        (( DRY_RUN )) || info "${node}: old $what removed"
        return 0
    fi
    # Only this path's own backups (<path>.YYYYmmdd_HHMMSS.bak): a plain '<path>.*.bak'
    # would also match /radump/patches.zip.<date>.bak when path is /radump/patches.
    local d='[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]' t='[0-9][0-9][0-9][0-9][0-9][0-9]'
    baks="$(on_node "$node" "ls -1d '$path'.${d}_${t}.bak 2>/dev/null | sort" || true)"
    if [[ -z "$baks" ]]; then
        change_on_node "$node" "mv '$path' '$path.$RUN_STAMP.bak'" || die "${node}: could not back up the old $what."
        (( DRY_RUN )) || info "${node}: old $what kept as $path.$RUN_STAMP.bak"
        return 0
    fi
    oldest="$(head -1 <<<"$baks")"
    info "${node}: keeping the oldest backup, $oldest; replacing the current old $what without another backup"
    local extra
    extra="$(tail -n +2 <<<"$baks")"
    if [[ -n "$extra" ]]; then
        local b
        while IFS= read -r b; do
            safe_path "$b" || die "${node}: unexpected backup name: $b"
            change_on_node "$node" "rm -rf -- '$b'" || die "${node}: could not remove extra backup $b"
        done <<<"$extra"
    fi
    change_on_node "$node" "rm -rf -- '$path'" || die "${node}: could not remove the old $what."
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
    local z="$1" node first="${NODES[0]}" sha
    for node in "${NODES[@]}"; do
        if [[ "$(staged_sha "$node")" == "$EXPECTED_SHA" ]]; then
            info "${z}/${node}: already staged with this archive; not copying"
            continue
        fi
        sha="$(remote_sha "$node")"
        if [[ "$sha" == "$EXPECTED_SHA" ]]; then
            info "${z}/${node}: already has the archive (SHA-256 matches); not copying"
            continue
        fi
        if [[ -n "$sha" ]]; then
            info "${z}/${node}: $REMOTE_ARCHIVE is an older version (SHA-256 ${sha:0:12}...)"
            set_aside_old "$node" "$REMOTE_ARCHIVE" "$REMOTE_ARCHIVE_NAME"
        fi
        change_on_node "$node" "mkdir -p '$REMOTE_DIR'"
        copy_to_node "$node" "$first" || die "${z}/${node}: copy failed."
    done
}

# Decides which nodes still need staging (TODO_NODES). A node whose staged record
# names this archive is done.
step_check() {
    local z="$1" node sha free_kb
    # Unpacked size is about the archive size, because the archive is stored (not compressed).
    local need_kb=$(( $(du -k "$ARCHIVE" | cut -f1) + MIN_FREE_GB * 1024 * 1024 ))
    TODO_NODES=()
    for node in "${NODES[@]}"; do
        if [[ "$(staged_sha "$node")" == "$EXPECTED_SHA" ]]; then
            info "${z}/${node}: already staged with this archive ($STAGE_DIR/$STAGED_RECORD_NAME); skipping"
            continue
        fi
        sha="$(remote_sha "$node")"
        if [[ "$sha" != "$EXPECTED_SHA" ]] && (( DRY_RUN )); then
            info "[dry-run] ${z}/${node}: new archive not copied yet; skipping SHA-256 check"
        else
            [[ "$sha" == "$EXPECTED_SHA" ]] || die "${z}/${node}: SHA-256 mismatch or archive missing (${sha:-none})"
            info "${z}/${node}: SHA-256 OK"
        fi
        free_kb="$(on_node "$node" "d='$EXTRACT_ROOT'; while [ ! -d \"\$d\" ]; do d=\$(dirname \"\$d\"); done; df -Pk \"\$d\"" | awk 'NR == 2 { print $4 }')"
        [[ "$free_kb" =~ ^[0-9]+$ ]] || die "${z}/${node}: cannot read free space for $EXTRACT_ROOT"
        info "${z}/${node}: $(( free_kb / 1024 / 1024 ))G free for $EXTRACT_ROOT (need $(( need_kb / 1024 / 1024 ))G)"
        (( free_kb >= need_kb )) || die "${z}/${node}: not enough free space in $EXTRACT_ROOT"
        TODO_NODES+=("$node")
    done
}

step_extract() {
    local z="$1" node unpack
    case "$ARCHIVE" in
        *.zip) unpack="unzip -q '$REMOTE_ARCHIVE' -d '$UNPACK_INTO'" ;;
        *.tar) unpack="tar -xf '$REMOTE_ARCHIVE' -C '$UNPACK_INTO'" ;;
    esac
    for node in ${TODO_NODES[@]+"${TODO_NODES[@]}"}; do
        # An older (or half-finished) unzipped folder from an earlier staging.
        if on_node "$node" "[ -e '$STAGE_DIR' ]"; then
            info "${z}/${node}: $STAGE_DIR is from an earlier staging"
            set_aside_old "$node" "$STAGE_DIR" "unzipped folder"
        fi
        change_on_node "$node" "mkdir -p '$UNPACK_INTO' && $unpack" || die "${z}/${node}: unpack failed."
        if (( ! DRY_RUN )); then
            info "${z}/${node}: $(on_node "$node" "find '$STAGE_DIR' -type f | wc -l") file(s) in $STAGE_DIR"
        fi
    done
}

# ---------------------------------------------------------------------------
# Configure step: runs on the node as one bash script (fed on stdin). Arguments:
#   <dry> <stage dir> <patches subdir> <conf subdir> <conf name> <record name>
#   <archive> <sha256> <from host> <archive path on the node>
#   KEY=VALUE ... -- FILE ...
# Paths are passed as arguments, never written into the script itself.
# ---------------------------------------------------------------------------
CONFIGURE_SCRIPT=$(cat <<'REMOTE'
set -uo pipefail
dry=$1 stage=$2 psub=$3 csub=$4 confname=$5 record=$6 archive=$7 sha=$8 from=$9 remote=${10}
shift 10
settings=(); files=()
while [ $# -gt 0 ] && [ "$1" != "--" ]; do settings+=("$1"); shift; done
[ $# -gt 0 ] && shift
files=("$@")
fail() { echo "ERROR $*"; exit 1; }
c="$stage/$csub/$confname"

if [ "$dry" = 1 ]; then
    echo "[dry-run] would check ${#files[@]} patch file(s) in $stage/$psub/"
    echo "[dry-run] would update ${#settings[@]} component setting(s) in $c (original kept as .orig)"
    echo "[dry-run] would write $stage/$record"
    exit 0
fi

# Check everything before changing anything.
[ -d "$stage" ] || fail "unzipped folder not found: $stage"
[ -f "$c" ] || fail "conf file not found: $c"
for f in "${files[@]}"; do
    [ -s "$stage/$psub/$f" ] || fail "patch file missing or empty: $stage/$psub/$f"
done
echo "OK ${#files[@]} patch file(s) present in $stage/$psub/"

# Rewrite the component settings, keeping each line's quoting style.
cp -p "$c" "$c.orig" || fail "cannot back up $c"
for kv in "${settings[@]}"; do
    k=${kv%%=*}; v=${kv#*=}
    cur=$(grep -m1 "^$k=" "$c" || true)
    if [ -n "$cur" ]; then
        old=${cur#*=}
        case "$old" in
            \"*) q='"' ;;
            \'*) q="'" ;;
            *)   q='' ;;
        esac
        sed -i "s|^$k=.*|$k=$q$v$q|" "$c" || fail "cannot update $k in $c"
    else
        echo "$k=$v" >> "$c" || fail "cannot add $k to $c"
        echo "NOTE $k was not in $c; added it"
    fi
done
echo "OK updated $c (original kept as $c.orig); changes:"
diff "$c.orig" "$c" | sed 's/^/   /'

# Check the result.
for kv in "${settings[@]}"; do
    k=${kv%%=*}; v=${kv#*=}
    got=$(sed -n "s/^$k=//p" "$c" | head -1 | sed -E "s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/")
    [ "$got" = "$v" ] || fail "check: $k is '$got' in $c, expected '$v'"
done
echo "OK checked: component settings in $c"

# Staged record, read by zdlra_patch.sh.
{
    echo "archive=$archive"
    echo "node_archive=$remote"
    echo "sha256=$sha"
    echo "staged_at=$(date '+%F %T %Z')"
    echo "staged_from=$from"
    echo "patch_conf=$c"
    echo "sr=${confname#*_}"
    for kv in "${settings[@]}"; do echo "component_$kv"; done
    for f in "${files[@]}"; do echo "file=$f"; done
} > "$stage/$record" || fail "cannot write $stage/$record"
echo "OK wrote $stage/$record"
REMOTE
)

step_configure() {
    local z="$1" node key out rc
    local args="'$DRY_RUN' '$STAGE_DIR' '$PATCHES_SUBDIR' '$CONF_SUBDIR' '$CONF_NAME' '$STAGED_RECORD_NAME'"
    args+=" '$ARCHIVE_NAME' '$EXPECTED_SHA' '$(hostname)' '$REMOTE_ARCHIVE'"
    for key in "${COMPONENT_VARS[@]}"; do args+=" '$key=${COMP[$key]:-}'"; done
    args+=" --"
    local f
    for f in "${PATCH_FILES[@]}"; do args+=" '$f'"; done
    for node in ${TODO_NODES[@]+"${TODO_NODES[@]}"}; do
        rc=0
        out="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${node}" "bash -s -- $args" <<<"$CONFIGURE_SCRIPT" 2>&1)" || rc=$?
        printf '%s\n' "$out" | sed "s|^|  ${z}/${node}: |" | tee -a "$LOG_FILE" >&2
        (( rc == 0 )) || die "${z}/${node}: configure step failed (see above)."
    done
}

stage_appliance() {
    local z="$1"
    info "======== $z ========"
    info "== nodes ==";      step_nodes "$z"; step_components "$z"
    info "== distribute =="; step_distribute "$z"
    info "== check ==";      step_check "$z"
    if (( ${#TODO_NODES[@]} == 0 )); then
        info "${z}: every node is already staged with this archive."
        return 0
    fi
    info "== extract ==";    step_extract "$z"
    info "== configure ==";  step_configure "$z"
    if (( DRY_RUN )); then
        info "${z}: dry run passed; would stage on ${TODO_NODES[*]}"
    else
        info "${z}: staged on ${TODO_NODES[*]} in $STAGE_DIR (conf ${CONF_NAME} set for ${z})"
    fi
}

# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    load_config
    default_component_cmds
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
