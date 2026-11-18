#!/usr/bin/env bash
#
# make_fake_appliance.sh ROOT - build a fake ZDLRA under ROOT, to run the playbooks on one
# Linux box with no appliance: stand-ins for racli, patchmgr (cells, switches, compute),
# dcli, sqlplus, the switch version command, emcli and sr_jobs_new.ksh, plus a staged
# record, a patch conf file and the patch zips. Versions live in ROOT/state and move to the
# targets as the stand-ins "patch". Also writes ROOT/vars.yml (the paths) and
# ROOT/inventory.yml (two "compute nodes", both this box, and localhost as the OMS).
#
# It only tests the playbooks' logic, never Oracle's tools: see docs/testing-notes.md.

set -euo pipefail
Z="$(mkdir -p "$1" && cd "$1" && pwd)"
rm -rf "${Z:?}"/{bin,state,radump,root,oem,raacfs,work,compute,helpers,ctl}
mkdir -p "$Z"/{bin,state,root,oem,work,compute,helpers,ctl} "$Z"/radump/patches/{bin,conf,patches,tmp} "$Z"/raacfs/raadmin/tmp

T_RA=23.1.2 T_IMG=24.1.10.0.0 T_SW="10.25(3)"
echo "22.1.1" > "$Z/state/ra"
for h in zdlra01db01 zdlra01db02; do echo "23.1.20.0.0" > "$Z/state/img_$h"; done
for h in cel01 cel02; do echo "23.1.20.0.0" > "$Z/state/img_$h"; done
for s in sw-rocea0 sw-roceb0; do echo "10.2(5)" > "$Z/state/sw_$s"; done
printf 'cel01\ncel02\n' > "$Z/root/cell_group"
printf 'sw-rocea0\nsw-roceb0\n' > "$Z/root/switch_group"
printf 'zdlra01db01\nzdlra01db02\n' > "$Z/root/dbs_group"

# --- racli -----------------------------------------------------------------------------
cat > "$Z/bin/racli" <<R
#!/usr/bin/env bash
Z="$Z"
case "\$1 \${2:-}" in
  "version ")        echo "Recovery Appliance Version: \$(cat \$Z/state/ra)" ;;
  "status appliance") echo "Appliance status: ONLINE" ;;
  "run preinstall")  echo "CHECK: free space PASS"; echo "HOST: zdlra01db01 PASS"; sleep 2
                     touch \$Z/root/.ra_preinstall.install; echo "End: ra_preinstall post cleanup" ;;
  "alter appliance") sleep 2; echo "New homes created"; echo "End: Alter Appliance" ;;
  "update appliance") sleep \${FAKE_UPDATE_SECONDS:-3}; echo "$T_RA" > \$Z/state/ra
                     echo "End: Patch Recovery Appliance - Step [Patch]" ;;
  *) echo "racli: unknown: \$*"; exit 2 ;;
esac
R

# --- dcli: -g FILE or -c a,b, then 'imageinfo -ver' --------------------------------------
cat > "$Z/bin/dcli" <<R
#!/usr/bin/env bash
Z="$Z"; hosts=""
while (( \$# )); do case "\$1" in -g) hosts="\$(cat "\$2")"; shift 2 ;; -c) hosts="\$(tr , '\n' <<<"\$2")"; shift 2 ;; -l) shift 2 ;; *) shift ;; esac; done
for h in \$hosts; do echo "\$h: \$(cat \$Z/state/img_\$h 2>/dev/null || echo unknown)"; done
R

# --- the switch version command ------------------------------------------------------------
cat > "$Z/bin/switchver" <<R
#!/usr/bin/env bash
v="\$(cat "$Z/state/sw_\$1" 2>/dev/null)" || { echo "ssh: connect to host \$1: refused"; exit 255; }
echo "Cisco Nexus Operating System (NX-OS) Software"; echo "  NXOS: version \$v"
R

# --- sqlplus: answers by the SQL it is given --------------------------------------------------
cat > "$Z/bin/sqlplus" <<R
#!/usr/bin/env bash
in="\$(cat)"
echo "\$in" >> "$Z/state/sql.log"
grep -q '^connect raAutomation/' <<<"\$in" || { echo "ORA-01017: invalid username/password"; exit 1; }
case "\$in" in
  *"FAKE_VERIFY"*)                       echo "5" ;;
  *"from dual"*)                         echo "         1" ;;
  *"remote_ra_dbname from ra_replication_pair"*) echo "RA2DR" ;;
  *"replication_server_state ||"*|*"state=' ||"*) echo "RA2DR  state=RUNNING  role=UPSTREAM" ;;
  *"select count(*) from gv"*)           echo "0" ;;
  *"pause_replication_server"*|*"resume_replication_server"*) : ;;
  *) : ;;
esac
R

# --- emcli and the OEM jobs script ---------------------------------------------------------------
cat > "$Z/bin/emcli" <<R
#!/usr/bin/env bash
echo "emcli \$*" >> "$Z/state/emcli.log"
case "\$1" in
  sync|login|create_blackout|stop_blackout|suspend_job|resume_job) : ;;
  get_blackout_reasons) echo "Patch"; echo "  Other" ;;
  get_blackout_details) echo "Status: Started" ;;
  get_targets) echo "zdlra01  oracle_ra" ;;
esac
R
cat > "$Z/oem/sr_jobs_new.ksh" <<R
#!/usr/bin/env bash
PATH="$Z/bin:\$PATH"
R
cat >> "$Z/oem/sr_jobs_new.ksh" <<'R'
db=$2 a=$4; act=suspend; [ "$a" = r ] && act=resume
f="${db}_${act}_job_$(date +%Y%m%d%H%M%S).ksh"
{ echo '#!/usr/bin/env bash'; echo "PATH=\"$PATH\""
  for j in BKP_I1 BKP_ARC; do echo "emcli ${act}_job -name=\"$j\" && echo 'Job \"$j\" ${act}ed successfully'"; done
} > "$f"
chmod +x "$f"; echo "wrote $f"
R

# --- Oracle's precheck: one warning in its summary --------------------------------------------
cat > "$Z/radump/patches/bin/precheck" <<'R'
#!/usr/bin/env bash
echo "precheck $*"; sleep 2
echo "FAILURE SUMMARY"; echo "***********************************"
echo "2026-11-18 [WARN] Some harmless warning"
R

# --- patch zips, each with one top folder holding a patchmgr ---------------------------------------
mk_patch() {  # $1 zip name, $2 top folder, $3 patchmgr body
    local d; d="$(mktemp -d)"
    mkdir -p "$d/$2"; printf '#!/usr/bin/env bash\nZ="%s"\n%s\n' "$Z" "$3" > "$d/$2/patchmgr"; chmod +x "$d/$2/patchmgr"
    (cd "$d" && zip -qr "$Z/radump/patches/patches/$1" "$2")
    cp -r "$d/$2" "$Z/radump/patches/tmp/"
    rm -rf "$d"
}
ok='echo "SUCCESS: Completed run of command: $*"; echo "Exit status:0"'
mk_patch cellpatch.zip patch_cell_24.1.10 "sleep 2
case \"\$*\" in *-patch\\ *|*-patch) for c in \$(cat \$2); do echo $T_IMG > \$Z/state/img_\$c; done; echo 'Current image version on cell(s) is:';; esac
$ok"
mk_patch switchpatch.zip patch_switch_24.1.10 "sleep 2
case \"\$*\" in *roceswitch-precheck*) ;; *--upgrade*) for s in \$(cat \$2); do echo '$T_SW' > \$Z/state/sw_\$s; done ;; esac
$ok"
mk_patch dbserver.zip dbserver_patch_24.1.10 "sleep 2
f=\$2; t=\$(cat \$f)
case \"\$*\" in *-upgrade*) echo $T_IMG > \$Z/state/img_\$t ;; esac
echo \"\$t: has state: SUCCESS\"
$ok"
echo "iso" > "$Z/radump/patches/patches/iso.zip"
for g in gi.zip db.zip; do echo "$g" > "$Z/raacfs/raadmin/tmp/$g"; cp "$Z/raacfs/raadmin/tmp/$g" "$Z/radump/$g"; done
echo "sw" > "$Z/raacfs/raadmin/tmp/zdlra_sw.zip"

cat > "$Z/radump/patches/conf/patch.conf_3-123" <<C
SR_NUMBER=3-123
TARGET_RA_VERSION="$T_RA"
TARGET_CELL_VERSION=$T_IMG
TARGET_COMPUTE_VERSION=$T_IMG
TARGET_SWITCH_VERSION='$T_SW'
SWITCH_TYPE=roce
FILES_YUM=iso.zip,dbserver.zip
FILES_CELL=cellpatch.zip
FILES_SWITCH=switchpatch.zip
C
cat > "$Z/radump/patches/ZDLRA_STAGED.txt" <<C
archive=patches.zip
sha256=abc123
staged_at=2026-11-18 10:00:00
patch_conf=$Z/radump/patches/conf/patch.conf_3-123
ra_release=$Z/raacfs/raadmin/tmp/zdlra_sw.zip
ra_gold_images=$Z/raacfs/raadmin/tmp/gi.zip,$Z/raacfs/raadmin/tmp/db.zip
unpacked=FILES_YUM:dbserver.zip:tmp
unpacked=FILES_CELL:cellpatch.zip:tmp
unpacked=FILES_SWITCH:switchpatch.zip:tmp
component_COMPUTE_NODE=zdlra01db01,zdlra01db02
C
chmod +x "$Z"/bin/* "$Z/oem/sr_jobs_new.ksh" "$Z/radump/patches/bin/precheck"

cat > "$Z/vars.yml" <<V
zdlra_required_user: $(id -un)
zdlra_racli: $Z/bin/racli
zdlra_dcli: $Z/bin/dcli
zdlra_sqlplus: $Z/bin/sqlplus
zdlra_staged_record: $Z/radump/patches/ZDLRA_STAGED.txt
zdlra_work_dir: $Z/work
zdlra_min_free_gb: 0
zdlra_helper_dir: $Z/helpers
zdlra_poll_seconds: 2
zdlra_precheck_script: $Z/radump/patches/bin/precheck
zdlra_ra_preinstall_done_file: $Z/root/.ra_preinstall.install
zdlra_ra_gold_images_path: $Z/radump/
zdlra_cell_group_file: $Z/root/cell_group
zdlra_switch_group_file: $Z/root/switch_group
zdlra_patch_tmp_dir: $Z/radump/patches/tmp
zdlra_patch_files_dir: $Z/radump/patches/patches
zdlra_switch_version_cmd: "$Z/bin/switchver {switch}"
zdlra_ra_sql_connect: "raAutomation/secret"
zdlra_quiesce_poll_seconds: 2
zdlra_verify_backups_sql: "select 'FAKE_VERIFY' from dual where {since} is not null;"
zdlra_verify_replication_sql: "select 'FAKE_VERIFY' from dual where {since} is not null;"
zdlra_verify_poll_seconds: 2
zdlra_compute_work_dir: $Z/compute
zdlra_node_ready_cmd: "true"
zdlra_node_ready_minutes: 1
zdlra_compute_version_wait_minutes: 1
zdlra_state_dir: $Z/ctl
zdlra_log_dir: $Z/ctl/logs
oem_state_dir: $Z/ctl
oem_emcli: $Z/bin/emcli
oem_jobs_dir: $Z/oem
oem_blackout_reason: Patch
V
cat > "$Z/inventory.yml" <<V
all:
  hosts:
    localhost:
      ansible_connection: local
      ansible_python_interpreter: $(command -v python3)
  children:
    zdlra01:
      hosts:
        zdlra01db01:
        zdlra01db02:
      vars:
        ansible_connection: local
        ansible_python_interpreter: $(command -v python3)
        oem_blackout_targets: "zdlra01:oracle_ra"
        oem_jobs_db: RA1GF2
V
echo "Fake appliance in $Z"
