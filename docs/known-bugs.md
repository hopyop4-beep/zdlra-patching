# Known bugs: automated run (`main`)

From a code review of all the code on `main` (commit 59ab2d5), on 2026-11-03. None of these
are fixed yet. Line numbers are from that commit. Almost all of this also applies to the
`platinum` branch, which has its own list in `docs/platinum-known-bugs.md`.

**The "fix before any real run" group is fixed (2026-11-03), tested with stand-ins only.** The
other groups are still open. Even a dry run executes the real precheck, which changes the
system.

How far each finding was checked:

- **Open bugs run in bash during the review:** 35a.
- **Not run on the real tools:** nothing here has run on an appliance. Anything about how
  `sqlplus`, `emcli`, `patchmgr` or `racli` behave comes from knowledge of those tools, so
  check it on the real system. That applies most to 27b and 37.
- The other findings come from the review and have not been checked separately.

## Fixed: was "fix before any real run"

Fixed on `main`, tested with stand-ins on a PC only. Still to check on a real appliance:
`sqlplus` really running the blocks, `setsid`, and `ps` output.

1. **Replication never paused or resumed.** PL/SQL blocks had no closing `/`. `sql_exec` now adds
   one to blocks only, so a plain statement doesn't run twice. The `sqlplus` stand-in now only runs
   a block when `/` follows, so this can't come back unnoticed.
2. **The guard against starting over a running command mostly didn't match.** It now finds
   `patchmgr` (`-cells`, `--roceswitches`, `-dbnodes`), the `racli` upgrade steps and the Oracle
   precheck, by full path, through bash, or in the wrapper. The precheck phase is guarded too, and
   a refusal comes before detaching, while someone can see it.
3. **The precheck could be killed.** It now runs like `patchmgr` and `racli`: in a session of its
   own, with no time limit. `PRECHECK_TIMEOUT` is gone; `PRECHECK_WARN_MINUTES` only warns.
4. **A failed start could look like a finished run.** The jump server records `started=0` before
   starting a stage's phases and `started=1` once that worked. A pickup at `started=0` asks the
   node, and starts the phases if they never started.
5. **`--continue` could patch things left out.** The phase list, `--keep-blackout` and
   `--skip-backup-wait` are saved with the run from the precheck on, and pickups use them. `-p` on a
   pickup is ignored with a warning. With no saved list, it stops and asks for `-p`.
6. **A good command could be run again in full.** A result left by an earlier attempt is picked up,
   not run again, and the checks before it are skipped. A cells `-patch` or switches `--upgrade`
   that worked is never repeated in the run. A failed one does run again, and old logs are kept.
7. **Staging could replace `/radump/patches` during a run.** It now refuses, before changing anything,
   on a node with a run holding the lock or a command from bug 2 running.
25. **A missing state file killed `--watch` and `--continue` silently.** `state_get` no longer fails.
28. **The "cannot enter folder" error could never appear.** The wrapper now writes its result.
29. **A signal just after a command started could remove its lock.** The trap is now set before the
    command starts. A slow start no longer reports "did not start" while the command runs on.
43. **The cell prep steps were wrong.** Now: the prereq check; only if it fails, `-reset_force` and
    `-cleanup`, then the check again; a second failure stops for review. Then `-patch`.
    `CELL_PREP_STEPS` is replaced by `CELL_PREREQ_STEP` and `CELL_RECOVERY_STEPS`.

Found and fixed while testing these:

44. **A signal to the script could record the run as `completed`.** Outside a running command, `TERM`
    ended the script with exit code 0 in its exit handler, so the jump server would take the run as
    finished, then resume the jobs and end the blackout. It now records `failed in <phase>`.
45. **A pickup without `-x` on a real run could mark it done** with nothing resumed. The jump server now
    saves whether the run was real, and refuses a mismatch either way.
46. **`--resume` on a run past its precheck could approve it again and create another blackout.** It now
    refuses and points to `--continue`. `--watch` and `--continue` refuse a run still at its precheck.

## Could finish wrongly or leave backups off

8. **The printed "Resume OEM jobs" command doesn't resume anything** (`jump/zdlra_patch_run.sh:287`,
   also `:689`, `:694`). `sr_jobs_new.ksh` only generates the script that does. Following the
   printed command leaves the backup jobs suspended, and nothing reports it.
9. **An expired `emcli` login leaves every job suspended** (`jump/zdlra_patch_run.sh:693`). Resume
   doesn't refresh the login. Every `emcli` line fails, only warnings appear, and the run ends
   "Done". `verify` then only warns too.
10. **A suspend where no jobs succeeded still starts patching** (`jump/zdlra_patch_run.sh:269`),
    although the README (line 170) says it won't. A generated script with no jobs also passes, as
    "0 of 0". At a minimum, 0 of N or 0 of 0 should fail the suspend.
11. **A cell that doesn't come back still passes** (`zdlra_patch.sh:1195`). `check_cell_versions`
    skips lines it can't read, so "All cells on target" is reported, and `postcheck` only warns.
    Compare against the names in `CELL_GROUP_FILE`.
12. **An unreadable `SWITCH_TYPE` skips the switches and marks them done** (`zdlra_patch.sh:1313`).
    Only an explicit `ib` should skip them; empty should fail.
13. **A precheck killed partway can count as passed** (`zdlra_patch.sh:552`). Any summary it printed
    is trusted, whatever the exit code. Treat signal exits (128 and up) as failures at least, and
    show the exit code at approval.
14. **Rerunning the precheck doesn't clear the old approval** (`zdlra_patch.sh:1604`). `--approve`
    says "already approved" and can't renew an expired one. A rerun that dies early leaves the old
    approval valid, so patch steps go ahead after a failed precheck. `phase_precheck` should remove
    `precheck_passed` and the approval at its start.
15. **A dry-run approval can authorize a real run** (`zdlra_patch.sh:612`) that never ran
    `-recheck_all`. The approval doesn't record whether the precheck was a dry run.
16. **The node-only commands in the README fail at `postcheck`** (`README.md:37`, also lines 46, 49,
    95). They have no compute step, so `postcheck` finds every compute node on the old version and
    stops, and replication stays paused. Either document that real runs go through the jump server,
    or make compute mismatches soft when the run didn't include compute.

## Can hang forever

17. **The jump server never checks that the node process is alive** (`jump/zdlra_patch_run.sh:616`).
    After a reboot or kill, the status stays `running`, or `still running (pid N)` (set at
    `zdlra_patch.sh:1075`) even after the command ends. `--continue` only watches it. Fix with a
    machine-readable state plus a liveness check.
18. **An approval expiring mid-window leaves the status "running"** (`zdlra_patch.sh:628`). The
    background process rechecks before each phase and exits with `PRESERVE_STATUS=1`, so nothing
    records the failure and the watch never ends.
19. **`patchmgr` dying without a result file is waited on forever** (`jump/zdlra_patch_run.sh:407`).
    The node's `run_detached` detects this, but the jump server's copy doesn't. The compute version
    check (`:448`) can also loop forever, and it discards `dcli` errors.
20. **A compute step that never started hangs on `--watch`** (`jump/zdlra_patch_run.sh:543`). The
    state says `step=precheck` before the start can fail; `--watch` then assumes it's running.
21. **A compute pass stopped by warnings or a `FAILED` line can't move on**
    (`jump/zdlra_patch_run.sh:438`), despite the message telling you to use `--watch`. Only a non-zero
    exit restarts a step, so someone has to delete files on the node by hand.

## Other bugs

22. **`cells` fails on patchmgr's version text after a good patch** (`zdlra_patch.sh:1233`), a format
    not yet seen on a real system. `--continue` then re-patches every cell. The `imageinfo` check at
    `:1235` is the real one; make the first advisory.
23. **A blackout record that has expired blocks `start`** (`jump/oem_blackout.sh:110`). The README's
    recovery step (line 119) fails, `stop` can fail too, and preflight blocks the next run until
    someone deletes the file.
24. **`sqlplus` has no `ORACLE_HOME` or `ORACLE_SID` set up** (`zdlra_patch.sh:167`). Root over a
    non-login ssh is unlikely to have them, and the DB home changes during `ra_update`, so a fixed
    path in the conf goes stale.
26. **Bad phase lists fail late** (`jump/zdlra_patch_run.sh:148`, `:742`, `:822`). A typo in `-p`, or a
    list starting with `compute`, only fails after the blackout and about 30 minutes of job suspend.
    Validate up front.
27. **`oem_blackout.sh`:**
    - a. A valid reason can be rejected (`:105`), because `grep -q` under `pipefail` can falsely fail.
      `-F` also accepts part of a reason.
    - b. `targets` may list nothing (`:96`): `get_targets -targets=%NAME%` probably filters on type.
      Check against the `emcli` docs.
30. **On bash older than 4.4, `--approve` fails** (`zdlra_patch.sh:393`) with "PHASES: unbound
    variable", because of an unguarded empty array.
31. **`verify` can falsely say no replication was paused** (`zdlra_patch.sh:1463`): `cat | grep -q .`
    under `pipefail`.
32. **An empty `STAGED_RECORD` crashes the precheck** (`zdlra_patch.sh:481`), though `:761` accepts it.
33. **A refused run leaves an empty folder that `--status` shows as the latest** (`zdlra_patch.sh:390`).
    The run folder is created before the lock is taken.
34. **The OEM jobs check compares clocks across what may be a shared mount**
    (`jump/zdlra_patch_run.sh:224`). Skew can make it miss the new script. Create the marker inside
    `OEM_JOBS_DIR`.
35. **`staging/zdlra_stage.sh`:**
    - a. `on_node` has no `ssh -n` (`:225`), so it swallows input, and only the first extra backup is
      removed.
      When fixing: `step_no_active_run` feeds its script to `on_node` on stdin, so it must keep working.
    - b. An archive taken from an already staged appliance is rejected (`:387`), because
      `CONF_GLOB` also matches `patch.conf_*.orig`. The archive also carries that appliance's record
      and unpacked `tmp/`.
    - c. Re-staging after a precheck fails (`:803`, `:1014`), because the gold images have moved to
      `/radump`, though the README (line 276) says rerunning is safe.
    - d. An interrupted copy can become the kept backup (`:663`). Copy to a temporary name and rename
      after checking the SHA.
    - e. Long `sha256sum`, `cmp` and `unzip` sessions have no keepalive (`:99`).
36. **`staging/Copy-ZdlraPatches.ps1`:**
    - a. A mistyped `-Manifest` path is ignored (`:220`), so the required-file check never runs.
    - b. Long silent ssh sessions have no keepalive (`:210`), and the archive may be left in `/radump`.
    - c. PC free space is only checked after the archive is built (`:281`), and that failure doesn't
      say the archive is still on the appliance.

## To confirm, not necessarily a bug

37. **Cell patching command** (`zdlra_patch.sh:1230`). The user confirmed on 2026-11-03 that ZDLRA cell
    patching is non-rolling, and will check the actual command during testing. The script's plain
    `-patch` with no `-rolling` should fit that, as far as I recall, but it hasn't been checked. The
    README (line 321) is wrong to say "rolling is handled by `patchmgr`": correct it. The order of
    the prep steps is settled: see bug 43.

## Bloat and stale docs

38. **Dead code:**
    - `zdlra_patch.sh`: `run()` (`:220`) and `sql_ready` (`:646`) have no callers, and `phase_verify`
      re-implements `sql_ready` (`:1474`). Also the `-ef` test (`:948`), the always-true `ALL_PHASES`
      guard (`:1026`), the redundant `ps` probe (`:1153`) and the nested `note()` (`:1472`).
    - `jump/zdlra_patch_run.sh`: `from=precheck` (`:483`), the unused `local pass` (`:522`), and the
      repeated `grep` (`:266`).
39. **Duplicates:**
    - Conf parsing is repeated (`zdlra_patch.sh:485`, `:911`, `:1018`); use `conf_value`.
    - The node and the jump server have separate detached-command code that has drifted apart (bugs
      19 and 28).
    - `on_node` is just `on "$NODE"` (`jump/zdlra_patch_run.sh:177`). `STAGE` and the local `stage`
      are near-identical names with different meanings.
    - `$(cat <<<"$list")` is just `"$list"` (`staging/zdlra_stage.sh:444`).
40. **Wasted time:** `sha256sum` runs twice per node on a very large archive, one node at a time
    (`staging/zdlra_stage.sh:658`). `du -sb` also runs twice (`staging/Copy-ZdlraPatches.ps1:172`,
    `:175`).
41. **Misleading output:**
    - The advertised `tail -f` of the run log shows nothing during the longest steps
      (`zdlra_patch.sh:1584`, `:1144`), because a step's log is only added once it finishes.
    - Snapshot diffs always differ, because of a timestamped log line in each file
      (`zdlra_patch.sh:854`, `:1342`).
42. **Stale docs:**
    - The "skeleton" status text (`zdlra_patch.sh:5`, `staging/zdlra_stage.sh:52`, `README.md:5`).
    - Roadmap items that are already done (`README.md:288`, `:305`, `:313`).
    - Switches are missing from the approval and overlap lists (`README.md:61`, `:62`, `:85`,
      `zdlra_patch.conf.example:45`).
    - An old precheck example that drops the SR argument (`README.md:126`,
      `staging/manifests/example.txt:6`).
