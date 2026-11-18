#!/usr/bin/env bash
#
# zdlra_sql.sh - run SQL on the appliance as the raAutomation account.
#
# Copied to the patch node by the zdlra_patch role. Reads from stdin: the connect string
# on the first line (e.g. raAutomation/<password>, or /@raAutomation), then the SQL. The
# connect string never shows in the process list.
#
# Usage:  zdlra_sql.sh query|exec  < input
#   query   prints the result rows, trimmed, one per line
#   exec    a statement that changes something; a PL/SQL block gets its "/" line
# Fails (exit 1) on an sqlplus failure or any ORA-/SP2- error.
#
# Root over plain ssh has no Oracle environment, and the DB home changes during
# ra_update. So unless RA_ORACLE_HOME and RA_ORACLE_SID are set in the environment, both
# are found from the running database: the SID from its ora_pmon_<sid> process, the home
# from that process's binary.

set -uo pipefail

mode="${1:-query}"
SQLPLUS="${SQLPLUS:-sqlplus}"
IFS= read -r connect || true
sql="$(cat)"
[[ -n "$connect" ]] || { echo "ERROR no connect string on stdin" >&2; exit 2; }

home="${RA_ORACLE_HOME:-}" sid="${RA_ORACLE_SID:-}"
if [[ -z "$home" || -z "$sid" ]]; then
    line="$(ps -eo pid=,args= 2>/dev/null | awk '$2 ~ /^ora_pmon_/ { print $1, $2; exit }' || true)"
    if [[ -n "$line" ]]; then
        [[ -n "$sid" ]] || sid="${line##*ora_pmon_}"
        if [[ -z "$home" ]]; then
            exe="$(readlink "/proc/${line%% *}/exe" 2>/dev/null || true)"
            [[ "$exe" != */bin/oracle ]] || home="${exe%/bin/oracle}"
        fi
    fi
fi
if [[ -n "$home" ]]; then
    export ORACLE_HOME="$home" PATH="${home}/bin:${PATH}" LD_LIBRARY_PATH="${home}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
[[ -z "$sid" ]] || export ORACLE_SID="$sid"

# SQL*Plus only runs a PL/SQL block on a "/" line. A plain statement ends with ";": it
# must not get one, or it would run twice.
if [[ "$mode" == exec ]] && grep -qiE '^[[:space:]]*(begin|declare)([[:space:]]|$)' <<<"$sql" && [[ "$sql" != */ ]]; then
    sql+=$'\n/'
fi

out="$("$SQLPLUS" -S -L /nolog <<EOF
whenever sqlerror exit failure
connect $connect
set heading off feedback off pagesize 0 linesize 400 trimspool on verify off
$sql
exit
EOF
)"
rc=$?
if (( rc != 0 )) || grep -qE '^(ORA|SP2)-[0-9]+' <<<"$out"; then
    echo "SQL failed (exit $rc):" >&2
    printf '%s\n' "$out" | sed 's/^/  /' >&2
    exit 1
fi
sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; /^$/d' <<<"$out"
