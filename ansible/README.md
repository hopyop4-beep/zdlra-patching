# zdlra-patching: the Ansible version

This folder holds an Ansible version of `zdlra_patch.sh` and the jump-server scripts
(`jump/zdlra_patch_run.sh`, `jump/oem_blackout.sh`). The shell scripts in the repository
root are unchanged and remain a separate, complete version. Use one or the other for a run:
do not mix them within one run.

> **Status: not yet run on a real appliance.** It has been tested only on a stand-in
> appliance (fake `racli`, `dcli`, `patchmgr`, `sqlplus`, `emcli`; see "Tests" below). Do not
> use it on a production appliance before a supervised first run.

## What it does

For a detailed walkthrough with diagrams, see
[docs/how-it-works-ansible.html](../docs/how-it-works-ansible.html) (download it and open it
in a browser).

Ansible runs from the jump server (the OMS host) and connects to the appliance's compute
nodes as root. One playbook covers the whole patch, in the same order as the scripts:

1. OEM preflight (the EM login, the blackout reason and targets)
2. `precheck`: the staged record, appliance status, free space, Oracle's precheck script, a
   read-only plan (replication, incoming backups, RA files, cell and switch versions). Then
   you review it and type `APPROVE`
3. OEM blackout started and OEM backup jobs suspended
4. `quiesce`, `snapshot`, `ra_preinstall`, `ra_alter`, `ra_update`, `cells`
5. `compute`: the compute nodes, from the jump server, through their reboots
6. `switches`, `admin_switches` (still a placeholder, off by default), `postcheck`,
   `resume`, `report`
7. OEM jobs resumed and the blackout ended (unless `zdlra_keep_blackout=true`)
8. `verify`: waits for new backups (and replication) to arrive

What each phase checks and how it decides success is the same as in the shell script; see
the phase table in the main [README](../README.md).

**Dry run is the default.** Without `-e zdlra_execute=true`, commands that change something
are only shown; read-only commands still run. `--check` is also a dry run.

## Setup

On the jump server:

```bash
python3 -m pip install --user 'ansible-core>=2.16,<2.17'   # see "Python on the nodes" below
cd ansible
cp inventory/hosts.yml.example inventory/hosts.yml
vi inventory/hosts.yml
cp inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml
vi inventory/group_vars/all/vault.yml
ansible-vault encrypt inventory/group_vars/all/vault.yml
vi inventory/group_vars/all/main.yml          # blackout reason, waivers, verify SQL, ...
```

- **Inventory.** One group per appliance, named as you pass it with `-e zdlra=<name>`. The
  hosts are the compute nodes, **named exactly as in `/root/dbs_group`** (use `ansible_host`
  if they are reached by another address). The first host is the patch node. Each group
  also sets `oem_blackout_targets` and `oem_jobs_db`.
- **Vault.** `vault_zdlra_ra_sql_connect` (the `raAutomation` login for SQL*Plus) and,
  if `emcli sync` is not enough, `vault_oem_em_password`. Run the playbooks with
  `--ask-vault-pass`. SQL runs with `no_log`, and the connect string goes on stdin, so the
  password does not show in output or in `ps`.
- **Settings.** Every setting of `zdlra_patch.conf` has a `zdlra_` counterpart in
  [roles/zdlra_patch/defaults/main.yml](roles/zdlra_patch/defaults/main.yml) (for example
  `PRECHECK_WAIVERS` is `zdlra_precheck_waivers`). Put your values in
  `inventory/group_vars/all/main.yml`, or per appliance in the inventory group. The patch
  details still come from staging: the staged record (`/radump/patches/ZDLRA_STAGED.txt`) and
  the `patch.conf_<SR>` file it names (`TARGET_*_VERSION`, `SWITCH_TYPE`, `FILES_*`).
- **Staging** is not part of this version. Use `staging/` (Windows PC) and the jump-server
  staging scripts as before.

`inventory/hosts.yml`, `vault.yml` and `logs/` are in `.gitignore`.

### Python on the nodes

ZDLRA compute nodes have Python 3.6 (3.6.8). ansible-core 2.17 and later cannot run modules
on Python 3.6, so use **ansible-core 2.16** on the jump server (2.16 needs Python 3.10 to 3.12
on the jump server itself). No newer Python is needed on the appliance: leave the nodes'
Python as it is. If a newer ansible-core is installed by mistake, setup stops at once and
says so. `zdlra_node_python` (default `/usr/bin/python3`) is the interpreter that check
reads.

Tested on the stand-in with ansible-core 2.16.3 and 2.16.20 against Python 3.6.15 nodes, and
with 2.22 against newer Python.

## Usage

Run these from this folder. Use `tmux` or `screen`: the run takes hours, and the playbook
waits for each long step (see "Long steps" below).

```bash
# Dry run of everything
ansible-playbook zdlra_patch.yml -e zdlra=zdlra01 --ask-vault-pass

# Precheck only (then type APPROVE)
ansible-playbook zdlra_patch.yml -e zdlra=zdlra01 -e zdlra_execute=true --tags precheck

# Real run of everything
ansible-playbook zdlra_patch.yml -e zdlra=zdlra01 -e zdlra_execute=true

# Continue or pick up a run (after a failure is fixed, or after the playbook was stopped)
ansible-playbook zdlra_patch.yml -e zdlra=zdlra01 -e zdlra_execute=true -e zdlra_run_id=<id>

# Some phases only, of the same run
ansible-playbook zdlra_patch.yml -e zdlra=zdlra01 -e zdlra_execute=true -e zdlra_run_id=<id> --tags quiesce,snapshot

# State of the latest run, or a given one, or its report
ansible-playbook zdlra_status.yml -e zdlra=zdlra01
ansible-playbook zdlra_status.yml -e zdlra=zdlra01 -e zdlra_run_id=<id> -e show=report
```

The run ID is shown at the start of each run and in the status.

**Tags.** Each phase has a tag of its own (`precheck`, `quiesce`, `snapshot`,
`ra_preinstall`, `ra_alter`, `ra_update`, `cells`, `compute`, `switches`, `admin_switches`,
`postcheck`, `resume`, `report`, `verify`). `ra` covers the three RA phases, and `oem` the
blackout and job steps. Tags select phases but do not reorder them.

**Useful settings** (with `-e`):

| Setting | Effect |
|---------|--------|
| `zdlra_execute=true` | A real run |
| `zdlra_run_id=<id>` | Continue or pick up that run |
| `zdlra_rerun=[cells]` | Run these phases again even though this run finished them |
| `zdlra_confirm_steps=false` | No `YES` prompt before each racli and patchmgr step |
| `zdlra_compute_enabled=false` | Leave the compute nodes out |
| `zdlra_keep_blackout=true` | Leave the blackout on and the jobs suspended at the end |
| `zdlra_skip_backup_wait=true` | `quiesce` does not wait for incoming backups |
| `zdlra_accept_warnings=true` | Accept compute warnings once reviewed (with `zdlra_compute_pause_on_warnings`) |

## Approval

After the precheck, the playbook shows the failures, warnings, the staged archive and its
SHA-256, and waits for you to type `APPROVE`. Nothing skips this, and with no terminal the
answer is empty, so the run stops. The approval is saved in the run folder with who approved
it, when, and a fingerprint of the results and the staged archive. A later phase of the run
refuses to start if the approval is missing, older than
`zdlra_precheck_approval_max_age_hours` (24), from a dry run when this is a real run, or if
the fingerprint no longer matches.

A precheck failure stops the run unless it is waived in `zdlra_precheck_waivers` (a part of
its name, after you have reviewed it).

## Long steps

patchmgr, racli and Oracle's precheck are never cut short. Each runs in a detached `screen`
session of its own on the node, as Oracle recommends for patchmgr (and as the shell script
does from v0.8.0). The command ignores Ctrl-C, hangups and the like and writes straight to its
log, with its exit code and PID recorded beside the log in the run folder. Every compute node
needs `screen` (`zdlra_screen`); setup checks for it before anything starts. To watch a step
live, run the `screen -r <session>` command the playbook prints on that node (leave with
Ctrl-A then d); `zdlra_status.yml` shows it too. Ansible checks on them every `zdlra_poll_seconds` (30). After the step's warn time it
says so and keeps waiting, up to `zdlra_wait_max_hours` (12). If Ansible stops for any
reason (the SSH session drops, Ctrl-C, the wait limit), the command keeps running.
`zdlra_status.yml` shows it and the last lines of its log. Run the playbook again with the
same `zdlra_run_id`: it waits for the running command, or uses the result it left, and
does not start it a second time. A precheck or racli step started outside this run (for
example by hand) makes the playbook refuse to start another.

## OEM on its own

`oem.yml` does the OEM steps for one appliance by themselves (the Ansible version of
`jump/oem_blackout.sh`):

```bash
ansible-playbook oem.yml -e zdlra=zdlra01 -e oem_action=targets      # find the EM targets
ansible-playbook oem.yml -e zdlra=zdlra01 -e oem_action=check        # check what start needs
ansible-playbook oem.yml -e zdlra=zdlra01 -e oem_action=status
ansible-playbook oem.yml -e zdlra=zdlra01 -e oem_action=start -e zdlra_execute=true
ansible-playbook oem.yml -e zdlra=zdlra01 -e oem_action=stop -e zdlra_execute=true
ansible-playbook oem.yml -e zdlra=zdlra01 -e oem_action=suspend_jobs -e zdlra_execute=true
ansible-playbook oem.yml -e zdlra=zdlra01 -e oem_action=resume_jobs -e zdlra_execute=true
ansible-playbook oem.yml -e zdlra=zdlra01 -e oem_action=finish -e zdlra_execute=true
```

The blackout name is kept in `~/zdlra_ansible_state/<appliance>.blackout`, as the script
does. The jobs are suspended and resumed with `sr_jobs_new.ksh`; each job must report
success in the generated script's log.

## Where things are kept

- **On the patch node**, under `/radump/zdlra_patch_runs/<run id>/`: the same layout as the
  shell script (`status`, `phases_done`, `phases_skipped`, `steps_done`,
  `precheck_approval.txt`, step logs, `versions.txt`, `report.txt`, ...).
- **On the jump server**: `~/zdlra_ansible_state/<appliance>_<run id>.json` (the blackout,
  suspended jobs, finished compute passes), copies of the compute logs in
  `~/zdlra_ansible_logs/`, and the Ansible log in `logs/ansible.log`.

## Differences from the shell script

- No background mode. Run under `tmux` or `screen`; if the session ends, run the playbook
  again with the same `zdlra_run_id` to pick up.
- Waiting stops after `zdlra_wait_max_hours`, but the command carries on. Run again to pick
  it up.
- The output is Ansible's task output and `logs/ansible.log`, not one streamed run log.
  Each long step still has its own log in the run folder.
- The approval time is the jump server's clock.
- Inventory host names must match `/root/dbs_group`.
- Staging still uses the shell and PowerShell scripts.

## Tests

`tests/standins/make_fake_appliance.sh <folder>` builds a stand-in appliance on the local
machine: fake `racli`, `dcli`, `switchver`, `sqlplus`, `emcli` and `sr_jobs_new.ksh`, a fake
precheck, patch zips with fake patchmgrs, a staged record, plus an inventory and variables
that point the playbooks at it. `tests/standins/run_with_answers.py` answers the `APPROVE`
and `YES` prompts.

```bash
tests/standins/make_fake_appliance.sh /tmp/z
python tests/standins/run_with_answers.py -- \
  ansible-playbook -i /tmp/z/inventory.yml zdlra_patch.yml -e zdlra=zdlra01 -e @/tmp/z/vars.yml
```

Tested this way: a full dry run; a full real run; picking up after Ansible was killed during
`racli update` (racli kept running and was not started again); a blocking precheck failure;
a waiver; a declined approval; and a real run refused because its approval came from a dry
run. `ansible-playbook --syntax-check` and `ansible-lint` pass.
