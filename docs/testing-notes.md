# What to test

For the automated run on `main`. Nothing here has run on a real appliance yet: all testing so
far used stand-ins on a PC. Work from top to bottom, and use a non-production appliance if
there is one.

Open bugs are in [known-bugs.md](known-bugs.md). The ones to watch for while testing are listed in
step 5.

## 1. Set up

- [ ] Copy the scripts to the jump server and to node 1.
- [ ] Create `zdlra_patch.conf`, `jump/zdlra_jump.conf`, `staging/appliances.conf` and
      `staging/zdlra_stage.conf` from their examples, and `chmod 600 zdlra_patch.conf`.
- [ ] If you already have a config, replace these settings. The script warns and ignores the old
      ones:
  - `CELL_PREP_STEPS`: now `CELL_PREREQ_STEP` and `CELL_RECOVERY_STEPS`.
  - `PRECHECK_TIMEOUT`: now `PRECHECK_WARN_MINUTES`, which only warns.
- [ ] Fill in `VERIFY_BACKUPS_SQL` and `VERIFY_REPLICATION_SQL`, or `verify` only warns. Each prints one
      number, with `{since}` where the start time goes.
- [ ] Set `OEM_JOBS_DB` for the appliance, and `BLACKOUT_TARGETS`.
- [ ] **`emcli` login:** the session is refreshed before suspending and resuming the jobs. If `EM_USER`
      asks for a password, the script waits at that prompt. Check how the login works on the OMS, as
      it could be hours into the window by then.

## 2. Checks that change nothing

Run these by hand on node 1, and note what each prints.

- [ ] **`setsid` keeps a command alive.** This is the protection against `patchmgr` and `racli` being
      cut short. It couldn't be tested on the PC. Run this, close the ssh session, log back in after
      2 minutes, and check the file exists:

  ```bash
  setsid nohup bash -c 'sleep 90; echo survived > /tmp/setsid_test' >/dev/null 2>&1 </dev/null &
  ```

- [ ] **Version formats:**
  - Does `racli version` contain `TARGET_RA_VERSION` as written in the conf file?
  - Does `dcli -g /root/cell_group -l root 'imageinfo -ver'` print `host: version`?
  - Does `ssh admin@<switch> "show version"` contain `TARGET_SWITCH_VERSION`?
- [ ] **`sqlplus` as root over plain ssh.** Does it work with no `ORACLE_HOME` or `ORACLE_SID` set
      (bug 24)? From the jump server:

  ```bash
  ssh root@<node1> 'which sqlplus; echo "ORACLE_HOME=$ORACLE_HOME ORACLE_SID=$ORACLE_SID"'
  ```

- [ ] **The switch patch folder.** Your note said `/radump/patching/tmp`; the scripts assume
      `/radump/patches/tmp`.
- [ ] **`bash --version` on the nodes.** Below 4.4, `--approve` fails (bug 30).
- [ ] **`emcli get_targets`:** does `oem_blackout.sh targets -z <zdlra>` list anything (bug 27b)?
- [ ] **`sr_jobs_new.ksh`:** what exit code does it give with a wrong value?

## 3. The guard, with harmless stand-ins

These use dummy commands in `/tmp`, so nothing real runs. On node 1:

```bash
mkdir -p /tmp/guard && cd /tmp/guard
printf '#!/bin/bash\nsleep 600\n' > patchmgr && cp patchmgr racli && chmod +x patchmgr racli
./patchmgr -cells /root/cell_group -patch &
```

Then, from the jump server, a staging dry run must refuse:

```bash
./staging/zdlra_stage.sh -a ~/patches.zip -z <zdlra>
```

- [ ] It says "not staging while patching is active". Kill the dummy, and repeat with
      `./racli update appliance &` and with `/tmp/guard/racli update appliance &`.
- [ ] Copy the `ps -eo pid=,args=` line for each real `patchmgr` and `racli` when one first runs, to
      check they look the same.

## 4. Dry run from the jump server

```bash
./jump/zdlra_patch_run.sh -z <zdlra>
```

**The precheck runs for real, even in a dry run, and it changes the system:** it installs and rolls
back an RPM and moves the gold images. Nothing else changes. No blackout is created.

- [ ] Preflight passes: ssh, scripts, `emcli` login, blackout reason and targets, OEM job commands.
- [ ] The precheck runs detached, and its results appear at the approval screen.
- [ ] The failure and warning lines were read correctly from its real output.
- [ ] Each later step prints what it would run. Check each command against your procedure:
  - `racli run preinstall`, `alter appliance`, `update appliance`.
  - Cells: **check the actual command.** It's plain `-patch`, and ZDLRA cell patching is non-rolling.
  - Compute: both passes, `-target_version`, `-iso_repo`.
  - Switches. The admin switch needs separate commands, which you'll add later.
- [ ] Ctrl-C while watching, then `--watch <run id>` without `-x`: it picks up.
- [ ] The same run with `-x` is refused, because it was started as a dry run.

## 5. First real run

The bugs most likely to matter here are fixed, but only tested with stand-ins, so check these
yourself on the first run:

- **OEM jobs:** after each suspend and resume, check them in OEM. To resume by hand, run the generated
  `<zdlra db>_resume_job_*.ksh`, not just `sr_jobs_new.ksh`. If not all jobs resumed, the run says so
  in its last line.
- **Cells and switches:** check them yourself, even if the run says they're fine.
- **A run that seems stuck:** check `zdlra_patch.sh --status --run-id <id>` on the node, and `ps`. The
  status should read `failed: the run's process is gone` if the script and its command have both gone.

Check at each step:

- [ ] **Replication really pauses.** This has only been tested with a stand-in. After `quiesce`, look at
      `ra_replication_pair`: the state must have changed. After `resume`, check it's back.
- [ ] **Incoming backups:** the RMAN session count looks right.
- [ ] **Blackout and OEM jobs:** both show correctly in OEM. Note how long the suspend takes.
- [ ] **Success lines, against the real output:**
  - `End: ra_preinstall post cleanup`, and no `CHECK:` or `HOST:` line with `FAIL`, and
    `/root/.ra_preinstall.install` is written.
  - `End: Alter Appliance`.
  - `End: Patch Recovery Appliance - Step [Patch]`.
  - patchmgr: `SUCCESS: Completed run of command`, `Exit status:0`.
  - Cells: `Current image version on cell(s) is:` ... `For details`. This is only logged; `imageinfo` decides.
- [ ] **Cell prereq flow:** `-reset_force` and `-cleanup` run only if `-patch_check_prereq` fails.
- [ ] **Compute:** both passes, through the reboots. Decide about "SUCCESS WITH WARNING(S)", which carries
      on for now (`COMPUTE_PAUSE_ON_WARNINGS=0`).
- [ ] **Commands survive:** if you can do it safely, close the terminal during a long step, then
      `--watch <run id> -x`. The command must carry on.
- [ ] **End of the run:** the version table, jobs resumed, blackout ended, `verify` sees new backups and
      replication, and the report looks right.

## 6. Failure and recovery, if there's a safe chance

- [ ] A step fails, then `--continue <run id> -x`: finished phases are skipped.
- [ ] The cell prereq fails once: it recovers. Fails twice: it stops.
- [ ] Compute: `patchmgr` fails, then `--watch <run id> -x`: that step starts again. With
      `COMPUTE_PAUSE_ON_WARNINGS=1`, it stops on warnings until you add `--accept-warnings`.
- [ ] **Compute guard:** `ps -eo args=` on a compute node shows `patchmgr ... -dbnodes` while one runs.

## 7. For Platinum later

Platinum waits until `main` is tested, but `--wait` depends on these. If you get the chance, note:

- [ ] Where each step's log ends up: cells, switches, compute (with `-log_dir auto`) and racli.
- [ ] Whether the Oracle engineer runs `patchmgr` from the staged folders under `/radump/patches/tmp`,
      on the compute nodes.
- [ ] The common pre-patch fix commands.

## What to send back

- The real output of the success lines and version commands, wherever it differs from the above.
- The two `verify` queries.
- The `ps` lines for `patchmgr` and `racli`.
- Anything that stopped, with the `--status` output and the step's log from
  `/radump/zdlra_patch_runs/<run id>/`.
