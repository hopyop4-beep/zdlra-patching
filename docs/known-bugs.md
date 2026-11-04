# Known bugs: automated run (`main`)

From a code review of all the code on `main` (commit 59ab2d5), on 2026-11-03. None of these
are fixed yet. Line numbers are from that commit. Almost all of this also applies to the
`platinum` branch, which has its own list in `docs/platinum-known-bugs.md`.

**Bugs 1-36 and 38-48 are fixed (2026-11-03), tested with stand-ins only.** Only item 37 is open. Even a dry run executes the real precheck, which changes the system.

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

## Fixed: staging (35, 36)

Fixed on `main`, tested with stand-ins on a PC only.

35. **`staging/zdlra_stage.sh`:**
    - a. `on_node` now uses `ssh -n`, so it can't swallow a list or what you type. All extra backups are
      removed. `on_node_stdin` is for the two commands that do read their input.
    - b. A folder's `patch.conf_*.orig` no longer counts as a second conf file. `Copy-ZdlraPatches.ps1` also
      leaves out the record, `tmp/` and `conf/*.orig` from an already staged folder, and says so.
    - c. Staging again after a precheck no longer fails on the gold images. If one has moved to
      `FILE_ALT_DIR` (`/radump`), it's taken as a gold image and not compared. A file that isn't there
      either is still a failure.
    - d. The archive is copied as `patches.zip.part`, and only gets its name once its SHA-256 is right.
    - e. `ServerAliveInterval=30` on ssh and scp.
36. **`staging/Copy-ZdlraPatches.ps1`:**
    - a. A `-Manifest` path that doesn't exist now stops the script.
    - b. `ServerAliveInterval=30` on ssh and scp. A dropped session says an archive may be left, and where.
    - c. The PC's free space is checked before the ZDLRA builds the archive.

Each node's archive is now hashed once per run (half of bug 40).

## To confirm, not necessarily a bug

37. **Cell patching command** (`zdlra_patch.sh:1230`). The user confirmed on 2026-11-03 that ZDLRA cell
    patching is non-rolling, and will check the actual command during testing. The script's plain
    `-patch` with no `-rolling` should fit that, as far as I recall, but it hasn't been checked. The
    README is corrected. The order of the prep steps is settled: see bug 43.

## Fixed: bloat and stale docs (38-42)

38. **Dead code:** removed `run()`, the `-ef` test, the always-true `ALL_PHASES` guard, the extra `ps` probe,
    `from=precheck`, the unused `local pass` and the repeated `grep`. `phase_verify` uses `sql_ready`, and
    `note()` is now `verify_note`.
39. **Duplicates:** conf parsing uses `conf_value`; `on_node` calls `on`; the jump server's `STAGE` is now
    `WATCHING`, as it was too close to the local `stage`.
    **Left as it is:** the node and the jump server keep separate detached-command code. One runs locally
    and one is sent over ssh to a node with no copy of the scripts, so sharing it would add more than it
    saves.
40. **Wasted time:** each node's archive is hashed once per run, and `du -sb` runs once.
    **Left as it is:** hashing one node at a time. Doing it in parallel isn't worth the extra code.
41. **Misleading output:**
    - `--status` now names a running step's own log and shows its last lines. `tail -f` on the run log still
      only gets a step's output when it ends, and the script now says so.
    - Snapshot files hold only the command's output, so the before/after diff shows real changes.
42. **Stale docs:** the status text, roadmap items, switches in the approval and warning lists, and the old
    precheck example are all corrected.

## Second review of `main` (2026-11-04): open

Found by a second review of commit 20097c2. Items 49-54 and 57 were confirmed by reading the code, and 79
by running it. The others are the review's findings. None has run on a real appliance. Line numbers are from that commit.

### Could repeat a patch, or do the wrong thing

49. **A brief ssh failure can re-run a finished `-upgrade`** (`jump/zdlra_patch_run.sh:512`, `:553`). A failed log
    copy looks like a failed `patchmgr`, and the good result is overwritten with `98`, so `--watch` upgrades again.
50. **The upgrade pickup reads a failed ssh as "no pid file"** (`jump/zdlra_patch_run.sh:628`), so it can also start
    a second `-upgrade`.
51. **`--continue` can treat a half-finished run as done** (`jump/zdlra_patch_run.sh:1043`). Any by-hand command that
    succeeds writes `completed`, so the jump server moves on to compute, or resumes the jobs and ends the blackout.
52. **A compute precheck that fails fast restarts forever** (`jump/zdlra_patch_run.sh:610`), and each restart wipes
    its log.
53. **A rerun precheck can reuse an old pre-install result** (`zdlra_patch.sh:872`), so `ra_alter` and `ra_update` run
    with the RPM rolled back.
54. **A result can be lost** (`zdlra_patch.sh:1274`). It's marked collected before the step is recorded as done, so a
    stop in between re-runs a good `-patch` or `--upgrade`.
55. **`blackout_over` is too loose** (`jump/oem_blackout.sh:97`). Any "not found", even an error, counts as ended.

### Could hang or leave things on

56. **`--continue` after re-approving a precheck watches forever** (`jump/zdlra_patch_run.sh:780`).
57. **`--resume` on an expired approval is only refused after the blackout and job suspend** (`:795`).
58. **`postcheck` fails on cells or switches the run left out** (`zdlra_patch.sh:1745`), before `resume`.
59. **The `NOT ALL BACKUPS ARE BACK ON` warning can be lost** (`jump/zdlra_patch_run.sh:1001`), and `verify` still waits
    for backups that can't arrive.
60. **Ctrl-C during the blackout start or job suspend says "nothing has changed"** (`:750`), with no undo commands.
61. **`--keep-blackout` added on a pickup isn't saved** (`:379`).
62. **`--watch` during compute pass 2 fails while node 1 reboots** (`:421`).
63. **File checks run before a leftover result is picked up** (`zdlra_patch.sh:1054`).
64. **A partly failed `resume` retries servers that already resumed** (`zdlra_patch.sh:947`).
65. **`admin_switches` shows as done when skipped** (`zdlra_patch.sh:1576`), so enabling it later and using
    `--continue` won't run it.
66. **The blackout reason check can still falsely fail** (`jump/oem_blackout.sh:117`): a pipe under `pipefail`.

### Lower risk

67. **A failed staging copy leaves `.part`, and free space is checked after the old archive is removed**
    (`staging/zdlra_stage.sh:694`).
68. **An interrupted move or unzip can become the kept backup** (`staging/zdlra_stage.sh:896`, `:766`).
69. **A brief ssh failure can make a staged node look unstaged** (`staging/zdlra_stage.sh:260`).
70. **After a reboot, a reused pid can make a dead run look alive** (`zdlra_patch.sh:440`).
71. **Compute restarts wipe the previous attempt's log** (`jump/zdlra_patch_run.sh:463`).
72. **A slow compute start can report "did not start" while it's running** (`:467`).
73. **A signal right at a command's start can drop its lock** (`zdlra_patch.sh:1228`).
74. **After the last compute pass, the run only waits for ssh, not the database** (`jump/zdlra_patch_run.sh:678`).
75. **Two pickups of one run aren't prevented** (`:901`), and could both resume the jobs.
76. **`postcheck` starts the Oracle precheck with no running-command guard** (`zdlra_patch.sh:1953`).
77. **The free-space and SQL checks only run after the long precheck** (`zdlra_patch.sh:873`).
78. **Bad compute settings only show up hours into the window** (`jump/zdlra_patch_run.sh:646`).
79. **`--status` with no runs crashes** (`zdlra_patch.sh:458`).
80. **The `--relay` copy has no keepalive** (`staging/zdlra_stage.sh:689`).

### Docs and cleanup

81. **Stale docs:** `SWITCH_TYPE` (`README.md:20`, `zdlra_patch.conf.example:88`), the cell version check (`README.md:19`),
    the phase lists (`README.md:180`, `zdlra_patch.conf.example:45`), the precheck timeout (`zdlra_patch.conf.example:21`),
    this file's opening lines, and a comment above the wrong function (`staging/zdlra_stage.sh:619`).
82. **Design:** the jump server decides progress from one status word. It should compare a stage's phases against the
    node's `phases_done` (root of 51 and 56).
83. **Duplicates:** three "is a patch running" checks that have drifted apart. `phase_admin_switches` is a copy of
    `phase_switches`. The compute log polling uses two ssh sessions per check.
