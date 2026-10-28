# zdlra-patching

A phased Bash script to automate patching of the Oracle Zero Data Loss Recovery Appliance (ZDLRA).

> **Status: early skeleton.** The structure, logging, dry run, locking and config handling work. Several checks are still `TODO`. Do not run it against a production appliance yet.

## How it works

The script breaks a patch into phases. You can run them one at a time or all together:

| Phase | What it does |
|-------|--------------|
| `precheck` | Checks appliance status and free space, then runs your external precheck script |
| `snapshot` | Saves configuration and state before patching |
| `stage` | Unpacks the patch bundle into the staging directory |
| `patch1` | Runs `racli <patch\|upgrade> appliance --step=1` |
| `patch2` | Runs `racli <patch\|upgrade> appliance --step=2` |
| `postcheck` | Runs the checks again and compares the result with the snapshot |
| `report` | Writes a summary of the run |

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
```

Each run writes its log, snapshots and report to `$WORK_DIR/<run id>/`.

## External precheck script

The `precheck` phase calls a precheck script you provide, such as the one Oracle supplies to support customers. Set it in the config:

```bash
PRECHECK_SCRIPT="/root/zdlra/precheck/<precheck-script>"
PRECHECK_ARGS=()
PRECHECK_FAIL_PATTERN='^(FAIL|CRITICAL)'
```

The phase fails if the script exits with a non-zero code, runs past `PRECHECK_TIMEOUT`, or prints a line that matches `PRECHECK_FAIL_PATTERN`. Its output is saved to `<run id>/precheck_before/`. By default `postcheck` runs it again and saves the output to `precheck_after/`.

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
- [ ] Email or webhook notification
- [ ] Optional Exadata infrastructure (`patchmgr`) phases

## Disclaimer

This is not an Oracle product and Oracle does not support it. Use it at your own risk, and test it on a non-production appliance first.

## License

MIT. See [LICENSE](LICENSE).
