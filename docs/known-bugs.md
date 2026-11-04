# Known bugs: automated run (`main`)

From a code review of all the code on `main` (commit 59ab2d5), on 2026-11-03. None of these
are fixed yet. Line numbers are from that commit. Almost all of this also applies to the
`platinum` branch, which has its own list in `docs/platinum-known-bugs.md`.

**Bugs 1-34 and 43-48 are fixed (2026-11-03), tested with stand-ins only.** The rest are still open. Even a dry run executes the real precheck, which changes the system.

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

## Fixed: could finish wrongly, leave backups off, or hang

Fixed on `main`, tested with stand-ins on a PC only.

8. **The printed "Resume OEM jobs" command resumed nothing.** It now includes running the script that
   `sr_jobs_new.ksh` writes.
9. **An expired `emcli` login left every job suspended.** The session is refreshed before each suspend
   and resume. If that fails, it counts as a failure.
10. **A suspend where no jobs succeeded still started patching.** None succeeding, or a script naming no
    jobs, now fails: patching doesn't start. Some not succeeding still carries on, as agreed. If a
    resume fails or is partial, the run says so again as its very last line.
11. **A cell that didn't come back still passed.** Every cell in `CELL_GROUP_FILE` must now report its
    version.
12. **An unreadable `SWITCH_TYPE` skipped the switches.** Only `IB` skips them now. Anything else that
    isn't `roce` stops the phase.
13. **A precheck killed partway could pass.** Exit codes of 128 and up now fail it, and the review shows
    the exit code. A lower non-zero exit with a summary still counts, as before.
14. **A rerun precheck left the old approval valid.** It now removes the old pass and approval at the
    start, so `--approve` works again and patch steps refuse until the new one is approved.
15. **A dry-run approval could authorize a real run.** The approval records it, and a real run refuses.
16. **Node-only commands failed at `postcheck`.** Compute nodes off target only fail the version table
    in a run that upgrades them (the jump server passes `--expect-compute`). Otherwise they are a
    warning, marked `CHECK`. The README says real runs go through the jump server.
17. **The jump server never checked the node process was alive.** `--status` now reads
    `failed: the run's process is gone` if the status says running, but neither the script nor its
    command is alive. The jump server then stops watching and prints `--continue`.
18. **An approval expiring mid-window left the status "running".** Covered by 17.
19. **A `patchmgr` dying without a result was waited on forever.** If the node answers, and neither the
    wrapper nor any `patchmgr -dbnodes` is running, it's recorded as failed, and picking up starts it
    again. The compute version check gives up after `COMPUTE_VERSION_WAIT_MINUTES` (60).
20. **A compute step that never started hung on `--watch`.** A pickup now starts it.
21. **A compute pass that stopped could never move on.** A step that ended badly with exit 0 is started
    again on pickup. For warnings (`COMPUTE_PAUSE_ON_WARNINGS=1`), add `--accept-warnings` to `--watch`.
22. **`cells` failed on patchmgr's version text after a good patch.** That text is now only for the log;
    `imageinfo` decides.

Found and fixed while testing these:

48. **`--status` could report a good run as failed.** The fix for 17 read the status, then checked the
    process, so a run finishing between the two looked gone. The jump server would stop at the end of a
    phase with the jobs and blackout left on. It now reads the status again once the process is gone.
    This was in `c98f5fe` and is fixed in the commit after `2f6d19e`.
47. **`--watch` could start a second `patchmgr` on a compute node.** If the wrapper was killed while
    `patchmgr` itself ran on, it looked finished. The check and the start guard now look for
    `patchmgr -dbnodes` too. A surviving one is waited for, and a new start is refused.

## Fixed: other bugs (23-34)

Fixed on `main`, tested with stand-ins on a PC only. The items marked "check" depend on real output.

23. **A blackout record that had expired blocked `start`.** `start` and `stop` now ask `emcli`. If the
    details clearly say it has ended, the record is set aside; if in doubt, it still blocks. Check: what
    `get_blackout_details` prints for an ended blackout.
24. **`sqlplus` had no Oracle environment.** Each SQL step now finds `ORACLE_HOME` and `ORACLE_SID` from the
    running `ora_pmon_<sid>` process, so it follows the new home after `ra_update`. `RA_ORACLE_HOME` and
    `RA_ORACLE_SID` override it. Check: that it connects as root.
26. **Bad phase lists failed late.** Preflight now checks the list against the node's, before the precheck
    starts. A list starting with `compute`, or only `compute`, now works.
27. **`oem_blackout.sh`:** a. Reasons are read first and matched whole, so a valid one can't be falsely
    rejected. Check: each reason is on a line of its own. b. `targets` uses `%NAME%:%`. Check against
    the `emcli` docs.
30. **On bash older than 4.4, `--approve` failed.** The empty phase list is now guarded.
31. **`verify` could falsely say no replication was paused.** It now reads the files directly.
32. **An empty `STAGED_RECORD` crashed the precheck.** It no longer does.
33. **A refused run left an empty folder.** A run refused before it takes the lock now removes its folder.
34. **The OEM jobs check compared clocks across what may be a shared mount.** The marker is now created
    inside `OEM_JOBS_DIR`, so both timestamps come from the same clock.

## Other bugs

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
