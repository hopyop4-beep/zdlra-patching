# zdlra-patching

A phased Bash script to automate patching of the Oracle Zero Data Loss Recovery Appliance (ZDLRA).

> **Status: early skeleton.** The structure, logging, dry run, locking and config handling work. Several checks are still `TODO`. Do not run it against a production appliance yet.

## How it works

The script breaks a patch into phases. You can run them one at a time or all together:

| Phase | What it does |
|-------|--------------|
| `precheck` | Checks appliance status and free space, runs your external precheck script, then asks you to approve the results |
| `snapshot` | Saves configuration and state before patching |
| `stage` | Unpacks the patch bundle into the staging directory |
| `patch1` | Runs `racli <patch\|upgrade> appliance --step=1` |
| `patch2` | Runs `racli <patch\|upgrade> appliance --step=2` |
| `postcheck` | Runs the checks again and compares the result with the snapshot |
| `report` | Writes a summary of the run |

You must list phases in this order. You can leave phases out, but you can't reorder them.

**Dry run is the default.** The script only logs commands that change something. Read-only commands such as `racli status` still run. To run every command, pass `--execute`.

## Usage

```bash
cp zdlra_patch.conf.example zdlra_patch.conf
vi zdlra_patch.conf

# Dry run of every phase
./zdlra_patch.sh all

# Prechecks only
./zdlra_patch.sh precheck

# Real run of step 1 (prompts before it starts)
./zdlra_patch.sh --execute precheck snapshot stage patch1

# Later: continue the same run for step 2
./zdlra_patch.sh --execute --run-id 20261028_140211 patch2 postcheck report
```

Each run writes its log, snapshots and report to `$WORK_DIR/<run id>/`.

## Precheck approval and background runs

After the precheck, the script shows the failures and warnings, then waits for you to type `APPROVE`. `--yes` does not skip this. The approval is saved in `<run id>/precheck_approval.txt` with who approved it, when, and a fingerprint of the results.

`patch1` and `patch2` refuse to run unless the run has an approval that:

- belongs to the same run, either the current one or the one named with `--run-id`
- is no older than `PRECHECK_APPROVAL_MAX_AGE_HOURS` (24 by default)
- matches the precheck results that were reviewed

With `--background`, the precheck runs in your terminal. After you approve it, the remaining phases continue in a detached process. That process keeps running if your SSH session drops. **It does not prompt again**, because nobody is there to answer; your approval covers the patch steps, and the review screen says so.

```bash
# Precheck in the terminal; after approval, everything else in the background
./zdlra_patch.sh --execute --background all

# Follow it
tail -f /radump/zdlra_patch_runs/<run id>/zdlra_patch.log

# Check its state: phase, process, approval, recent log lines
./zdlra_patch.sh --status
./zdlra_patch.sh --status --run-id <run id>
```

If you leave `precheck` out, for example to continue an approved run with `--run-id`, the approval is checked before the script detaches. A problem then shows up right away in your terminal.

## External precheck script

The `precheck` phase calls a precheck script you provide, such as the one Oracle supplies to support customers. Set it in the config:

```bash
PRECHECK_SCRIPT="/root/zdlra/precheck/<precheck-script>"
PRECHECK_ARGS=()
PRECHECK_WAIVERS=("a failure you have reviewed and accepted")
```

The script reads failures from the summary at the end of the precheck output:

```
FAILURE SUMMARY
***********************************
<date> [FAIL] <failure name>
<date> [WARN] <warning name>
```

Each failure and warning is listed in the run log. The phase fails if:

- there is any failure that is not in `PRECHECK_WAIVERS`
- the script runs past `PRECHECK_TIMEOUT`
- the script exits with a non-zero code and prints no summary

Warnings and waived failures are logged but do not stop the run. To make warnings stop the run as well, set `PRECHECK_FAIL_ON_WARN=1`; waivers then apply to warnings too. If your version of the script uses a different header or tags, change `PRECHECK_SUMMARY_HEADER`, `PRECHECK_FAIL_PATTERN` or `PRECHECK_WARN_PATTERN`.

Results are saved to `<run id>/precheck_before/`: the full output, plus the failure and warning lines and sorted lists of their names. By default `postcheck` runs the script again and saves the results to `precheck_after/`. It then logs which failures and warnings are new since patching and which were resolved.

The script runs in dry-run mode too, because it only reads. **Do not commit the script or its output to this repo.** Get it from Oracle and keep it on the appliance.

## Before you use it

- Read the README that comes with your patch bundle, and the current Oracle note on ZDLRA patching and upgrades on My Oracle Support. Check every `racli` command in the script against them, because the steps can change between releases.
- Run it as `root` on the first compute node.
- Remove every `TODO` that applies to your environment.

## Roadmap

- [x] Call an external precheck script and fail on errors
- [ ] Find active backup, copy-to-tape and replication jobs before patching starts
- [ ] Verify the bundle checksum
- [ ] Check success markers in the logs after each step
- [ ] Wait for services after step 2, with a timeout
- [ ] Wider before/after comparison (CRS resources, policies, replication)
- [x] Operator approval of the precheck, and background runs
- [ ] Email or webhook notification (most useful for background runs)
- [ ] Optional Exadata infrastructure (`patchmgr`) phases

## Disclaimer

This is not an Oracle product and Oracle does not support it. Use it at your own risk, and test it on a non-production appliance first.

## License

MIT. See [LICENSE](LICENSE).
