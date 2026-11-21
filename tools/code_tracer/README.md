# Code tracer

An interactive viewer for learning this repo, and Ansible, line by line.
Open `docs/code-tracer.html` in a browser (download it from GitHub, or open it from your
clone; it needs no server and no internet). Then:

- **Click any line.** The right-hand panel says what kind of line it is (a task keyword,
  a module, a module option, a Jinja filter, a Bash construct...) in plain words, which task
  or function it belongs to and the author's comment above that task, and where it connects.
- **Underlined words are links.** A variable shows where it is defined (with the comment
  above its default) and every place it is read. A file name or `tasks_from:` shows the file
  it runs; double-click it, or use the link in the panel, to open it. A custom filter
  (`| zdlra_kv`) opens its Python. A Bash function opens its definition.
- **"How a run gets to this file"** shows the chain of includes from the playbook you run
  (`zdlra_patch.yml` → `run_phase.yml` → `phase_compute.yml` → `compute_pass.yml` → ...).
- **Outline** (left) lists the tasks or functions of the open file. **Concepts** is the
  whole glossary. **Search** (or `/`) finds files, variables, functions and concepts.
- **↑ / ↓** move line by line. **Back** returns to where you were before following a link.

## Rebuilding it

The page is generated from the code, so rebuild it after the code changes:

    python3 tools/code_tracer/build.py

It needs Python 3.6+ and PyYAML (which Ansible already installs), and writes
`docs/code-tracer.html` and `docs/trainer/code-tracer.html` (see "Two builds" below). The commit it was built from shows at the top of the page.

| File | What it holds |
|---|---|
| `build.py` | Reads every file in the repo, works out the tasks, variables, includes and functions, and writes the page. |
| `glossary.py` | The plain-language explanations. Add or reword an entry, then rebuild. |
| `viewer.html` | The page itself (layout and script); `build.py` puts the data into it. |
| `page.py` | Puts the data into `viewer.html` for each build: standalone (no Claude) or trainer (Ask Claude). |

The "what this does in the script" side comes from the repo itself: task names, the
comments above tasks and variables, and each file's opening comment. Better comments in
the code make better explanations here.

## The Bash version: docs/code-tracer-bash.html

A second page covers only the shell version (`zdlra_patch.sh`, `jump/`, `staging/` and their
config examples), and goes deeper into Bash:

- **In plain words.** Every line gets a sentence that reads the code out:
  `[[ -n "$RUN_ID" ]] || die "..."` becomes "Makes sure that `$RUN_ID` is not empty; if not,
  stops the script with the error ...". `if`, `for`, `while` and `case` say which lines they
  cover; `fi`, `done` and `}` say where their block started. The cards below it explain the
  Bash syntax and commands on the line (with the options used, e.g. `grep -qxF`).
- **Functions.** Click a function name to jump to its definition. The definition shows the
  comment above it, every place that calls it, every function it calls, and **how a run gets
  here**: the chains of calls from the script you run, e.g. `zdlra_patch.sh` → `main()` →
  `"phase_${p}"` → `phase_cells()` → `run_patchmgr()` → `patchmgr_attempt()`. A name built at
  run time (`"phase_${p}"`, `"do_${ACTION}"`) lists every function it can be.
- **Variables.** A `local` variable links only within its function. A setting links to its
  default in the script and to the line of the config example that replaces it.
- **Across scripts.** The jump server's calls to `zdlra_patch.sh` over ssh and to
  `oem_blackout.sh`, the `source` of the config file, and the scripts sent to the nodes in
  quoted here-documents (`<<'REMOTE'`) are followed too; lines inside such a here-document
  say that they run on the node, not where they are written.

Rebuild it after the scripts change:

    python3 tools/code_tracer/build_bash.py

It needs only Python 3.6+ (no PyYAML) and writes `docs/code-tracer-bash.html` and
`docs/trainer/code-tracer-bash.html`.

| File | What it holds |
|---|---|
| `build_bash.py` | Reads the shell scripts, works out functions, calls, variables and blocks, writes the plain-words reading of each line, and writes the page. |
| `shlex_lite.py` | A small Bash reader: which words are commands, where blocks start and end, here-documents, strings over several lines. |
| `glossary_bash.py` | The Bash explanations: commands and their options, syntax, test operators, traps. Add or reword an entry, then rebuild. |

The plain-words reading is worked out from the code by rules, not by hand, so an unusual
line may read awkwardly; the comment above it (and, in the trainer, Ask Claude) are there for
those.

## Two builds: standalone, and the Exadata Trainer's Code tracer tab

Each build script writes the same tracer twice:

| Page | Claude | Use it |
|---|---|---|
| `docs/code-tracer.html`, `docs/code-tracer-bash.html` | none at all | Standalone: download and open in any browser, no server, no internet. This is the one the main README links to. |
| `docs/trainer/code-tracer.html`, `docs/trainer/code-tracer-bash.html` | **Ask Claude about this line** | Only inside the Exadata Trainer, which serves them in its **Code tracer** tab (Reference, in the sidebar). |

In the trainer build, the explanation panel ends with a chat: type a question (or nothing, for
"explain this line") and press Enter. Claude is shown the file with the line marked, the task or
function around it and the tracer's plain-words reading, and answers in the panel; follow-up
questions keep the conversation for that line. A picker chooses Claude Sonnet 5.5 (quicker, the
default) or Claude Opus 5.5 (deeper).

**How it reaches Claude, and why there is no API key.** The page never calls Claude itself. It
posts the question to the trainer's own server (`POST /ai/tracer` on 127.0.0.1), which asks
through the trainer's existing link to Claude (`claude_conn.py`: the Claude Code that the Claude
desktop app installs, signed in once with `Claude Login.bat`, run with no tools). So no API key is
typed, stored in the browser, or kept in this repo, and nothing is sent anywhere but Claude. The
trainer serves the pages straight from this repo (`../zdlra-patching/docs/trainer/` next to the
trainer, or `EXADATA_TRACER_DIR`), so `git pull` here updates the tab.

The Claude code lives between `/*ASK-BEGIN*/` and `/*ASK-END*/` in `viewer.html`; `page.py`
leaves it out of the standalone build. `--trainer-output ''` skips the trainer build.
