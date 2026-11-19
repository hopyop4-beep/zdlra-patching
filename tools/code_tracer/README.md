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
- **Ask Claude about this line** copies your question with the line and its task, ready
  to paste into a chat with Claude.

## Rebuilding it

The page is generated from the code, so rebuild it after the code changes:

    python3 tools/code_tracer/build.py

It needs Python 3.6+ and PyYAML (which Ansible already installs), and writes
`docs/code-tracer.html`. The commit it was built from shows at the top of the page.

| File | What it holds |
|---|---|
| `build.py` | Reads every file in the repo, works out the tasks, variables, includes and functions, and writes the page. |
| `glossary.py` | The plain-language explanations. Add or reword an entry, then rebuild. |
| `viewer.html` | The page itself (layout and script); `build.py` puts the data into it. |

The "what this does in the script" side comes from the repo itself: task names, the
comments above tasks and variables, and each file's opening comment. Better comments in
the code make better explanations here.
