#!/usr/bin/env python3
"""Build the code tracer: one HTML file that opens the repo's code and shows, for any line,
what it does, the Ansible (or Bash) idea behind it, and where it connects.

    python3 tools/code_tracer/build.py            # writes docs/code-tracer.html
    python3 tools/code_tracer/build.py -o out.html

Needs Python 3.6+ and PyYAML (which Ansible already needs). Run it again after the code
changes; the page itself needs nothing but a browser.
"""

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import glossary as G  # noqa: E402
import page as P  # noqa: E402

REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
ENTRY_POINTS = ["ansible/zdlra_patch.yml", "ansible/oem.yml", "ansible/zdlra_status.yml",
                "zdlra_patch.sh", "jump/zdlra_patch_run.sh", "jump/oem_blackout.sh",
                "staging/zdlra_stage.sh"]
SKIP = re.compile(r"^(LICENSE|\.gitattributes|tools/|docs/.*\.html$)|\.gitkeep$|^\.gitignore$")

TASK_KEYS = set(G.TASK) | {"block", "rescue", "always", "local_action", "with_items",
                           "with_dict", "with_fileglob", "loop_control", "delegate_facts"}
BARE_JINJA = {"when", "that", "until", "changed_when", "failed_when"}
MOD_PREFIX = re.compile(r"^(ansible\.(builtin|posix|legacy)|community\.general)\.")
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
FILE_MENTION = re.compile(r"[A-Za-z0-9_./-]+\.(?:yml|yaml|sh|ksh|py|j2|cfg|ps1|md|conf\.example|example)\b")


def short_mod(name):
    return MOD_PREFIX.sub("", name)


def lang_of(path):
    b = os.path.basename(path)
    if b.endswith((".yml", ".yaml", ".yml.example")):
        return "yaml"
    if b.endswith((".sh", ".ksh")) or ".conf" in b or b.endswith(".conf.example"):
        return "bash"
    if b.endswith(".py"):
        return "python"
    if b.endswith(".j2"):
        return "jinja"
    if b.endswith(".cfg") or b in (".ansible-lint", ".yamllint"):
        return "ini" if b.endswith(".cfg") else "yaml"
    if b.endswith(".md"):
        return "markdown"
    if b.endswith(".ps1"):
        return "powershell"
    return "text"


class Index(object):
    def __init__(self):
        self.files = {}        # path -> file record
        self.symbols = {}      # key -> {title, kind, defs: [], uses: []}
        self.edges = []        # (from_path, from_line, to_path, how)
        self.def_at = set()    # (key, path, line)

    # --- symbols -------------------------------------------------------------------
    def sym(self, key, title, kind):
        s = self.symbols.get(key)
        if s is None:
            s = self.symbols[key] = {"title": title, "kind": kind, "defs": [], "uses": []}
        return s

    def define(self, key, title, kind, path, line, how, doc=""):
        s = self.sym(key, title, kind)
        if (key, path, line) in self.def_at:
            return
        self.def_at.add((key, path, line))
        s["defs"].append({"f": path, "l": line, "how": how, "doc": doc.strip()})

    # --- per-line annotations --------------------------------------------------------
    def concept(self, path, line, key):
        lst = self.files[path]["concepts"].setdefault(line, [])
        if key not in lst:
            lst.append(key)

    def token(self, path, line, start, end, kind, target):
        toks = self.files[path]["tokens"].setdefault(line, [])
        for t in toks:
            if t[0] < end and start < t[1]:
                return
        toks.append([start, end, kind, target])

    def note(self, path, line, text):
        lst = self.files[path]["notes"].setdefault(line, [])
        if text not in lst:
            lst.append(text)


def comments_above(lines, i):
    """The # lines directly above line i (0-based), without the #."""
    out = []
    j = i - 1
    while j >= 0 and lines[j].strip().startswith("#") and not lines[j].startswith("#!"):
        out.insert(0, re.sub(r"^\s*# ?", "", lines[j]))
        j -= 1
    return "\n".join(out)


def header_summary(lines, lang):
    """The file's opening comment block (or docstring), as its summary."""
    out, started = [], False
    for ln in lines[:60]:
        s = ln.strip()
        if lang == "python" and s.startswith('"""'):
            body = []
            for l2 in lines[lines.index(ln):]:
                body.append(l2.strip().strip('"'))
                if l2.strip().endswith('"""') and len(body) > 1 or (len(body) == 1 and l2.count('"""') == 2):
                    break
            return "\n".join(b for b in body).strip()
        if s.startswith("#!") or s == "---" or (not started and s == ""):
            continue
        if s.startswith("#") or (lang == "powershell" and s.startswith("<#")):
            started = True
            out.append(re.sub(r"^#+ ?", "", s))
        elif lang == "markdown" and s:
            out.append(s)
            started = True
            if len(out) > 6:
                break
        else:
            break
    return "\n".join(out).strip()


def task_start_line(node):
    return node.start_mark.line


def node_end_line(node):
    e = node.end_mark
    return e.line - 1 if e.column == 0 and e.line > node.start_mark.line else e.line


def scalar(node):
    return node.value if isinstance(node, yaml.ScalarNode) else None


def jinja_glob(text):
    """phase_{{ zdlra_phase }}.yml -> phase_*.yml"""
    return re.sub(r"\{\{.*?\}\}", "*", text)


class YamlWalker(object):
    def __init__(self, idx, path):
        self.idx = idx
        self.path = path
        self.rec = idx.files[path]
        self.lines = self.rec["lines"]
        parts = path.split("/")
        self.role = parts[parts.index("roles") + 1] if "roles" in parts else None
        self.dir = os.path.dirname(path)

    # --- resolving file references ---------------------------------------------------
    def role_file(self, role, sub, name, exts=("", ".yml", ".yaml")):
        base = "ansible/roles/%s/%s/" % (role, sub)
        for e in exts:
            p = base + name + e
            if p in self.idx.files:
                return [p]
        g = jinja_glob(name)
        if g != name:
            return sorted(p for p in self.idx.files if fnmatch.fnmatch(p, base + g + ("" if g.endswith(".yml") else ".yml")))
        return []

    def resolve_tasks_file(self, name):
        if self.role:
            hits = self.role_file(self.role, "tasks", name)
            if hits:
                return hits
        g = jinja_glob(name)
        p = os.path.normpath(os.path.join(self.dir, g))
        return sorted(f for f in self.idx.files if fnmatch.fnmatch(f, p))

    def link_value(self, node, targets, how):
        line = node.start_mark.line
        for t in targets:
            self.idx.edges.append((self.path, line, t, how))
        if targets:
            s, e = node.start_mark.column, node.end_mark.column if node.end_mark.line == line else len(self.lines[line])
            if self.lines[line][s:s + 1] in "\"'":
                s, e = s + 1, e - 1
            self.idx.token(self.path, line, s, e, "file", targets[0] if len(targets) == 1 else "glob:" + "|".join(targets))

    # --- variables -------------------------------------------------------------------
    def def_var(self, keynode, how, doc=""):
        name = scalar(keynode)
        if not name or not IDENT.fullmatch(name):
            return
        line = keynode.start_mark.line
        self.idx.define("var:" + name, name, "var", self.path, line, how, doc)
        c = keynode.start_mark.column
        self.idx.token(self.path, line, c, c + len(name), "var", "var:" + name)

    def var_file(self, node, how, depth=0):
        """A mapping of variables (defaults, group_vars, play vars)."""
        if not isinstance(node, yaml.MappingNode):
            return
        for k, v in node.value:
            line = k.start_mark.line
            doc = comments_above(self.lines, line)
            first = self.lines[line].split(":", 1)[1].strip() if ":" in self.lines[line] else ""
            self.def_var(k, how, doc)
            self.idx.concept(self.path, line, "note:vardef")
            self.mark_scalars(v)

    def inventory(self, node, depth=0):
        if not isinstance(node, yaml.MappingNode):
            return
        for k, v in node.value:
            key = scalar(k)
            line = k.start_mark.line
            if key == "vars":
                self.idx.concept(self.path, line, "note:invvars")
                self.var_file(v, "inventory variable (%s)" % self.path)
            elif key == "children":
                self.idx.concept(self.path, line, "note:children")
                for gk, gv in (v.value if isinstance(v, yaml.MappingNode) else []):
                    self.idx.concept(self.path, gk.start_mark.line, "note:group")
                    self.inventory(gv, depth + 1)
            elif key == "hosts":
                self.idx.concept(self.path, line, "note:hosts")
                for hk, hv in (v.value if isinstance(v, yaml.MappingNode) else []):
                    self.idx.concept(self.path, hk.start_mark.line, "note:host")
            elif key == "all":
                self.idx.concept(self.path, line, "note:all")
                self.inventory(v, depth + 1)

    # --- marking YAML syntax -----------------------------------------------------------
    def mark_scalars(self, node, owner=None):
        """Multi-line scalars: mark their continuation lines; flow collections."""
        if isinstance(node, yaml.ScalarNode):
            if node.style in (">", "|"):
                self.idx.concept(self.path, node.start_mark.line - 0, "yaml:folded" if node.style == ">" else "yaml:literal")
                for ln in range(node.start_mark.line + 1, node_end_line(node) + 1):
                    if self.lines[ln].strip():
                        self.idx.concept(self.path, ln, "yaml:continuation")
                        if owner:
                            self.idx.note(self.path, ln, "Part of the value of “%s”, which starts on line %d." % (owner, node.start_mark.line + 1))
            elif node_end_line(node) > node.start_mark.line:
                for ln in range(node.start_mark.line + 1, node_end_line(node) + 1):
                    self.idx.concept(self.path, ln, "yaml:continuation")
        elif isinstance(node, yaml.MappingNode):
            if node.flow_style:
                self.idx.concept(self.path, node.start_mark.line, "yaml:flow_map")
            for k, v in node.value:
                self.mark_scalars(v, scalar(k))
        elif isinstance(node, yaml.SequenceNode):
            if node.flow_style:
                self.idx.concept(self.path, node.start_mark.line, "yaml:flow_list")
            for v in node.value:
                self.mark_scalars(v, owner)

    def bare_jinja(self, node):
        for ln in range(node.start_mark.line, node_end_line(node) + 1):
            self.idx.concept(self.path, ln, "jinja:bare")

    # --- plays and tasks ---------------------------------------------------------------
    def playbook(self, root):
        for play in root.value:
            if not isinstance(play, yaml.MappingNode):
                continue
            for k, v in play.value:
                key = scalar(k)
                line = k.start_mark.line
                if key in G.PLAY:
                    self.idx.concept(self.path, line, "play:" + key)
                elif key in G.TASK:
                    self.idx.concept(self.path, line, "task:" + key)
                if key == "name":
                    self.idx.concept(self.path, line, "note:playname")
                if key == "vars":
                    self.var_file(v, "play vars (%s)" % os.path.basename(self.path))
                elif key in ("tasks", "pre_tasks", "post_tasks", "handlers"):
                    self.tasks(v, None)
                elif key == "roles":
                    for r in v.value:
                        rn = scalar(r) or (scalar(dict((scalar(a), b) for a, b in r.value).get("role")) if isinstance(r, yaml.MappingNode) else None)
                        if rn:
                            self.link_value(r, self.role_file(rn, "tasks", "main"), "role")
                else:
                    self.mark_scalars(v, key)

    def tasks(self, seq, parent, depth=0):
        if not isinstance(seq, yaml.SequenceNode):
            return
        for t in seq.value:
            if isinstance(t, yaml.MappingNode):
                self.task(t, parent, depth)

    def task(self, node, parent, depth):
        rec = self.rec
        keys = [(scalar(k), k, v) for k, v in node.value]
        kmap = dict((a, (b, c)) for a, b, c in keys)
        module = None
        for key, k, v in keys:
            if key not in TASK_KEYS and key not in ("name",):
                module = key
                break
        start = task_start_line(node)
        tid = len(rec["tasks"])
        name = scalar(kmap["name"][1]) if "name" in kmap else None
        kind = "block" if "block" in kmap else ("task" if module else "task")
        end = node.end_mark.line
        if end >= len(self.lines) or not self.lines[end][:node.end_mark.column].strip(" -"):
            end -= 1
        while end > start and (not self.lines[end].strip() or self.lines[end].strip().startswith("#")):
            end -= 1
        task = {"id": tid, "name": name or "", "module": module or ("block" if "block" in kmap else ""),
                "start": start, "end": end, "parent": parent, "depth": depth,
                "comment": comments_above(self.lines, start), "kind": kind,
                "keys": [a for a, b, c in keys]}
        rec["tasks"].append(task)
        for ln in range(start, task["end"] + 1):
            # innermost task wins: later (nested) tasks overwrite
            rec["task_of"][ln] = tid

        for key, k, v in keys:
            line = k.start_mark.line
            if key in ("block", "rescue", "always"):
                self.idx.concept(self.path, line, "task:" + key)
                self.tasks(v, tid, depth + 1)
                continue
            if key == module:
                self.module(module, k, v, task)
                continue
            if key in G.TASK:
                self.idx.concept(self.path, line, "task:" + key)
            if key in BARE_JINJA:
                self.bare_jinja(v)
            if key == "register":
                n = scalar(v)
                if n:
                    self.idx.define("var:" + n, n, "var", self.path, v.start_mark.line,
                                    "register (the result of: %s)" % (name or module), "")
                    c = v.start_mark.column
                    self.idx.token(self.path, v.start_mark.line, c, c + len(n), "var", "var:" + n)
            elif key == "vars":
                target = ""
                if module and short_mod(module) in ("include_tasks", "import_tasks", "include_role", "import_role"):
                    target = " (passed into the included file)"
                if isinstance(v, yaml.MappingNode):
                    for vk, vv in v.value:
                        self.def_var(vk, "vars on the task “%s”%s" % (name or module, target))
                        self.mark_scalars(vv, scalar(vk))
                continue
            elif key == "loop_control" and isinstance(v, yaml.MappingNode):
                for lk, lv in v.value:
                    lkey = scalar(lk)
                    if lkey in G.TASK:
                        self.idx.concept(self.path, lk.start_mark.line, "task:" + lkey)
                    if lkey == "loop_var" and scalar(lv):
                        n = scalar(lv)
                        self.idx.define("var:" + n, n, "var", self.path, lv.start_mark.line, "loop variable of “%s”" % (name or module))
                        c = lv.start_mark.column
                        self.idx.token(self.path, lv.start_mark.line, c, c + len(n), "var", "var:" + n)
                continue
            self.mark_scalars(v, key)

    def module(self, module, k, v, task):
        line = k.start_mark.line
        sm = short_mod(module)
        self.idx.concept(self.path, line, "module:" + sm)
        c = k.start_mark.column
        self.idx.token(self.path, line, c, c + len(module), "module", "module:" + sm)
        opts = {}
        if isinstance(v, yaml.MappingNode):
            for ok, ov in v.value:
                okey = scalar(ok)
                opts[okey] = ov
                if sm == "set_fact":
                    if okey != "cacheable":
                        doc = task["name"]
                        self.def_var(ok, "set_fact in “%s”" % (task["name"] or "a task"), "")
                        self.idx.concept(self.path, ok.start_mark.line, "note:setfactvar")
                    self.mark_scalars(ov, okey)
                    continue
                if okey == "apply" and isinstance(ov, yaml.MappingNode):
                    self.idx.concept(self.path, ok.start_mark.line, "task:apply")
                    for ak, av in ov.value:
                        if scalar(ak) in G.TASK:
                            self.idx.concept(self.path, ak.start_mark.line, "task:" + scalar(ak))
                    continue
                if okey in ("that",):
                    self.bare_jinja(ov)
                key = sm + "." + okey
                if key in G.OPTION:
                    self.idx.concept(self.path, ok.start_mark.line, "opt:" + key)
                elif "*." + okey in G.OPTION:
                    self.idx.concept(self.path, ok.start_mark.line, "opt:*." + okey)
                self.mark_scalars(ov, okey)
        else:
            self.mark_scalars(v, module)

        # where it leads
        if sm in ("include_tasks", "import_tasks"):
            fn = scalar(v) if isinstance(v, yaml.ScalarNode) else None
            fnode = v
            if fn is None and "file" in opts:
                fn, fnode = scalar(opts["file"]), opts["file"]
            if fn:
                self.link_value(fnode, self.resolve_tasks_file(fn), "include")
        elif sm in ("include_role", "import_role") and "name" in opts:
            role = scalar(opts["name"])
            tf = scalar(opts["tasks_from"]) if "tasks_from" in opts else "main"
            targets = self.role_file(role, "tasks", tf)
            if "tasks_from" in opts:
                self.link_value(opts["tasks_from"], targets, "include_role")
                self.idx.token(self.path, opts["name"].start_mark.line, opts["name"].start_mark.column,
                               opts["name"].start_mark.column + len(role), "role", "role:" + role)
            else:
                self.link_value(opts["name"], targets, "include_role")
            task["leads_to"] = targets
        elif sm in ("copy", "template") and "src" in opts:
            src = scalar(opts["src"])
            sub = "files" if sm == "copy" else "templates"
            if src and "{{" not in src and self.role:
                hits = self.role_file(self.role, sub, src, ("",))
                self.link_value(opts["src"], hits, sm)
            elif src and self.role:
                # src from a loop: the role's files named anywhere in the task
                base = "ansible/roles/%s/%s/" % (self.role, sub)
                text = "\n".join(self.lines[task["start"]:task["end"] + 1])
                for p in sorted(self.idx.files):
                    if p.startswith(base) and os.path.basename(p) in text:
                        self.idx.edges.append((self.path, opts["src"].start_mark.line, p, sm))
        if sm in ("include_tasks", "import_tasks") and self.idx.edges and self.idx.edges[-1][0] == self.path:
            task["leads_to"] = [e[2] for e in self.idx.edges if e[0] == self.path and e[1] in (line, getattr(v, "start_mark", k.start_mark).line)]

    # --- entry -------------------------------------------------------------------------
    def walk(self):
        text = "\n".join(self.lines)
        try:
            docs = list(yaml.compose_all(text, Loader=yaml.SafeLoader))
        except yaml.YAMLError as e:
            self.rec["error"] = str(e)
            return
        for i, ln in enumerate(self.lines):
            s = ln.strip()
            if s.startswith("#"):
                self.idx.concept(self.path, i, "yaml:comment")
            elif s == "---":
                self.idx.concept(self.path, i, "yaml:doc_start")
        p = self.path
        for root in docs:
            if root is None:
                continue
            if isinstance(root, yaml.SequenceNode):
                items = [n for n in root.value if isinstance(n, yaml.MappingNode)]
                if items and any(scalar(k) == "hosts" for n in items for k, _ in n.value):
                    self.rec["kind"] = "playbook"
                    self.playbook(root)
                elif "/tasks/" in p or items:
                    self.rec["kind"] = "tasks"
                    self.tasks(root, None)
            elif isinstance(root, yaml.MappingNode):
                if "/inventory/" in p and "hosts" in os.path.basename(p):
                    self.rec["kind"] = "inventory"
                    self.inventory(root)
                elif "/defaults/" in p:
                    self.rec["kind"] = "defaults"
                    self.var_file(root, "role default (%s)" % p.split("/")[2])
                elif "group_vars" in p or "host_vars" in p or "/vars/" in p:
                    self.rec["kind"] = "vars"
                    self.var_file(root, "inventory group_vars (%s)" % "/".join(p.split("/")[-2:]))
                else:
                    self.rec["kind"] = "config"
                    self.mark_scalars(root)


# --- Bash ------------------------------------------------------------------------------
BASH_FUNC = re.compile(r"^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{?")
BASH_ASSIGN = re.compile(r"^\s*(?:(?:local|export|readonly|declare(?:\s+-[A-Za-z]+)*)\s+)?([A-Za-z_][A-Za-z0-9_]*)(?:\[[^\]]*\])?\+?=")
BASH_FOR = re.compile(r"^\s*for\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b")
BASH_READ = re.compile(r"\bread\s+(?:-[a-zA-Z]+\s+(?:\S+\s+)?)*((?:[A-Za-z_][A-Za-z0-9_]*\s*)+)")
BASH_USE = re.compile(r"\$\{?#?!?([A-Za-z_][A-Za-z0-9_]*)")
BASH_CONCEPTS = [(re.compile(rx), i) for i, (rx, _, _) in enumerate(G.BASH)]


def bash_group(path):
    return os.path.dirname(path) or "."


def bash_pass1(idx, path):
    rec = idx.files[path]
    lines = rec["lines"]
    grp = bash_group(path)
    cur = None
    for i, ln in enumerate(lines):
        m = BASH_FUNC.match(ln)
        if m and not ln.strip().startswith("#"):
            fn = m.group(1)
            key = "func:%s:%s" % (path, fn)
            idx.define(key, fn + "()", "func", path, i, "function in " + os.path.basename(path), comments_above(lines, i))
            cur = {"id": len(rec["tasks"]), "name": fn + "()", "module": "function", "start": i, "end": i,
                   "parent": None, "depth": 0, "comment": comments_above(lines, i), "kind": "function", "keys": []}
            rec["tasks"].append(cur)
        if cur is not None:
            rec["task_of"][i] = cur["id"]
            cur["end"] = i
            if re.match(r"^\}", ln) or (m and ln.rstrip().endswith("}")):
                cur = None
        if ln.strip().startswith("#"):
            continue
        names = []
        m = BASH_ASSIGN.match(ln)
        if m:
            names.append((m.group(1), m.start(1), "set here" if "local" not in ln[:m.start(1)] else "local variable"))
        m = BASH_FOR.match(ln)
        if m:
            names.append((m.group(1), m.start(1), "for-loop variable"))
        for m in BASH_READ.finditer(ln):
            for nm in re.finditer(r"[A-Za-z_][A-Za-z0-9_]*", m.group(1)):
                names.append((nm.group(0), m.start(1) + nm.start(), "read from input"))
        for n, col, how in names:
            if n in ("then", "do", "in", "if"):
                continue
            key = "shvar:%s:%s" % (grp, n)
            doc = comments_above(lines, i) if (path.endswith((".conf", ".example")) or i < 400 and not ln.startswith(" ")) else ""
            idx.define(key, "$" + n, "shvar", path, i, how + " (" + os.path.basename(path) + ")", doc)
            idx.token(path, i, col, col + len(n), "shvar", key)


def bash_pass2(idx, path):
    rec = idx.files[path]
    lines = rec["lines"]
    grp = bash_group(path)
    funcs = {}
    for key, s in idx.symbols.items():
        if key.startswith("func:%s:" % path):
            funcs[key.rsplit(":", 1)[1]] = key
    for i, ln in enumerate(lines):
        for rx, ci in BASH_CONCEPTS:
            if rx.search(ln):
                if ci == 1 or not ln.strip().startswith("#"):
                    idx.concept(path, i, "bash:%d" % ci)
                if ln.strip().startswith("#"):
                    break
        if ln.strip().startswith("#"):
            continue
        for m in BASH_USE.finditer(ln):
            key = "shvar:%s:%s" % (grp, m.group(1))
            if key in idx.symbols:
                idx.token(path, i, m.start(), m.end(), "shvar", key)
        for m in IDENT.finditer(ln):
            w = m.group(0)
            if w in funcs:
                idx.token(path, i, m.start(), m.end(), "func", funcs[w])
            elif w in G.TOOLS:
                idx.token(path, i, m.start(), m.end(), "tool", "tool:" + w)


# --- Python (filter and test plugins) ------------------------------------------------------
def python_pass(idx, path):
    rec = idx.files[path]
    lines = rec["lines"]
    kind = "test" if "test_plugins" in path else "filter"
    defs = {}
    cur = None
    for i, ln in enumerate(lines):
        m = re.match(r"^(\s*)def\s+([A-Za-z_][A-Za-z0-9_]*)", ln)
        if m:
            doc = ""
            if i + 1 < len(lines) and lines[i + 1].strip().startswith('"""'):
                d = []
                for l2 in lines[i + 1:i + 15]:
                    d.append(l2.strip().replace('"""', ""))
                    if l2.strip().endswith('"""') and (len(d) > 1 or l2.strip().count('"""') == 2):
                        break
                doc = "\n".join(d).strip()
            defs[m.group(2)] = (i, doc)
            key = "func:%s:%s" % (path, m.group(2))
            idx.define(key, m.group(2) + "()", "func", path, i, "Python function", doc)
            if not m.group(1):
                cur = {"id": len(rec["tasks"]), "name": m.group(2) + "()", "module": "def", "start": i, "end": i,
                       "parent": None, "depth": 0, "comment": doc, "kind": "function", "keys": []}
                rec["tasks"].append(cur)
        elif re.match(r"^\S", ln):
            cur = None
        if cur is not None:
            rec["task_of"][i] = cur["id"]
            cur["end"] = i
    for i, ln in enumerate(lines):
        if re.match(r"^class (FilterModule|TestModule)\b", ln) or re.match(r"^\s+def (filters|tests)\(self\)", ln):
            idx.note(path, i, "This is how Ansible finds plugins: it loads every .py file in the folder that "
                     "ansible.cfg names (filter_plugins / test_plugins), looks for a class called FilterModule "
                     "(or TestModule), and calls its filters() (or tests()) method. That returns a dict of "
                     "name -> Python function; each name becomes usable in Jinja.")
        for m in re.finditer(r"'([A-Za-z_][A-Za-z0-9_]*)'\s*:\s*([A-Za-z_][A-Za-z0-9_]*)", ln):
            fname, func = m.group(1), m.group(2)
            if func in defs:
                dl, doc = defs[func]
                idx.define("%s:%s" % (kind, fname), fname, kind, path, dl,
                           "custom Jinja %s from %s" % (kind, path), doc)
                idx.note(path, i, "This registers the Python function %s() as the Jinja %s “%s”, so playbooks can write %s." % (
                    func, kind, fname, ("x | %s" if kind == "filter" else "x is %s") % fname))
        for m in IDENT.finditer(ln):
            if m.group(0) in defs:
                idx.token(path, i, m.start(), m.end(), "func", "func:%s:%s" % (path, m.group(0)))


# --- Tokens shared by YAML and Jinja templates ---------------------------------------------
def ansible_tokens(idx, path):
    rec = idx.files[path]
    for i, ln in enumerate(rec["lines"]):
        is_comment = ln.strip().startswith("#")
        if "{{" in ln:
            idx.concept(path, i, "jinja:expr")
        if "{%" in ln:
            idx.concept(path, i, "jinja:stmt")
            for m in re.finditer(r"\{%-?\s*set\s+([A-Za-z_][A-Za-z0-9_]*)", ln):
                idx.define("var:" + m.group(1), m.group(1), "var", path, i, "Jinja {% set %} (only inside this expression)")
        jinja_line = ("{{" in ln or "{%" in ln or "jinja:bare" in rec["concepts"].get(i, [])
                      or "yaml:continuation" in rec["concepts"].get(i, []))
        for m in re.finditer(r"\bansible\.(?:builtin|posix|legacy)\.[a-z_]+", ln):
            sm = short_mod(m.group(0))
            if sm in G.MODULE:
                idx.token(path, i, m.start(), m.end(), "module", "module:" + sm)
        for m in IDENT.finditer(ln):
            w = m.group(0)
            s, e = m.start(), m.end()
            if s > 0 and ln[s - 1] == ".":
                continue
            before = ln[:s]
            if not is_comment and re.search(r"\|\s*$", before) and (jinja_line or rec["lang"] == "jinja"):
                if "filter:" + w in idx.symbols:
                    idx.token(path, i, s, e, "filter", "filter:" + w)
                    idx.concept(path, i, "cfilter:" + w)
                elif w in G.FILTER:
                    idx.token(path, i, s, e, "gloss", "filter:" + w)
                    idx.concept(path, i, "filter:" + w)
                continue
            if not is_comment and re.search(r"\bis\s+(not\s+)?$", before):
                if "test:" + w in idx.symbols:
                    idx.token(path, i, s, e, "test", "test:" + w)
                    idx.concept(path, i, "ctest:" + w)
                elif w in G.TEST:
                    idx.token(path, i, s, e, "gloss", "test:" + w)
                    idx.concept(path, i, "test:" + w)
                continue
            if "var:" + w in idx.symbols:
                idx.token(path, i, s, e, "var", "var:" + w)
                if not is_comment and w in G.MAGIC:
                    idx.concept(path, i, "magic:" + w)
            elif w in G.MAGIC and not is_comment and (jinja_line or w.startswith("ansible_")):
                idx.token(path, i, s, e, "gloss", "magic:" + w)
                idx.concept(path, i, "magic:" + w)
            elif w in G.TOOLS:
                idx.token(path, i, s, e, "tool", "tool:" + w)
        if not is_comment and jinja_line:
            if re.search(r"\s~\s", ln):
                idx.concept(path, i, "jinja:tilde")
            if re.search(r"\bif\b.*\belse\b", ln) and "{%" not in ln:
                idx.concept(path, i, "jinja:inline_if")
            if "|" in ln and not ln.rstrip().endswith("|"):
                idx.concept(path, i, "jinja:filter")
            if re.search(r"\bis\s+(not\s+)?[a-z_]+", ln):
                idx.concept(path, i, "jinja:test")


def mention_tokens(idx, path):
    """Any repo file named in the text (zdlra_detached.sh, run_phase.yml, ...)."""
    rec = idx.files[path]
    by_base = {}
    for p in idx.files:
        by_base.setdefault(os.path.basename(p), []).append(p)
    for i, ln in enumerate(rec["lines"]):
        for m in FILE_MENTION.finditer(ln):
            t = m.group(0).strip("./")
            hits = [p for p in idx.files if p == t or p.endswith("/" + t)]
            if not hits:
                hits = by_base.get(os.path.basename(t), [])
                if len(hits) > 1 and rec["lang"] == "yaml" and "/tasks/" in path:
                    same = [h for h in hits if os.path.dirname(h) == os.path.dirname(path)]
                    hits = same or hits
            if len(hits) == 1 and hits[0] != path:
                idx.token(path, i, m.start(), m.end(), "file", hits[0])
                idx.edges.append((path, i, hits[0], "mention"))


def ini_pass(idx, path):
    rec = idx.files[path]
    for i, ln in enumerate(rec["lines"]):
        s = ln.strip()
        if s.startswith("#"):
            idx.concept(path, i, "yaml:comment")
        elif s in G.CFG:
            idx.concept(path, i, "cfg:" + s)
        else:
            m = re.match(r"^([a-z_]+)\s*=", s)
            if m and m.group(1) in G.CFG:
                idx.concept(path, i, "cfg:" + m.group(1))


def uses(idx):
    for path, rec in idx.files.items():
        for ln, toks in rec["tokens"].items():
            for s, e, kind, key in toks:
                if key in idx.symbols and (key, path, ln) not in idx.def_at:
                    u = idx.symbols[key]["uses"]
                    if not u or u[-1] != {"f": path, "l": ln}:
                        u.append({"f": path, "l": ln})


def chains(idx):
    """For each file, the include paths from an entry point that lead to it."""
    parents = {}
    for f, l, t, how in idx.edges:
        if how in ("include", "include_role", "role", "copy", "template") and f != t:
            parents.setdefault(t, [])
            if (f, l) not in parents[t]:
                parents[t].append((f, l))
    out = {}
    for target in idx.files:
        found = []

        def up(node, path, seen):
            if len(found) >= 8:
                return
            ps = parents.get(node, [])
            if not ps:
                if path:
                    found.append(list(reversed(path)))
                return
            for f, l in ps:
                if f in seen:
                    continue
                up(f, path + [[f, l]], seen | {f})

        up(target, [], {target})
        found.sort(key=len)
        if found:
            out[target] = found
    return out


def build(outputs):
    files = subprocess.check_output(["git", "ls-files"], cwd=REPO).decode().split("\n")
    idx = Index()
    for p in files:
        if not p or SKIP.search(p):
            continue
        full = os.path.join(REPO, p)
        try:
            with open(full, encoding="utf-8") as fh:
                text = fh.read()
        except (UnicodeDecodeError, IOError):
            continue
        lines = text.split("\n")
        if lines and lines[-1] == "":
            lines.pop()
        lang = lang_of(p)
        idx.files[p] = {"lang": lang, "lines": lines, "summary": header_summary(lines, lang),
                        "concepts": {}, "tokens": {}, "notes": {}, "tasks": [], "task_of": {}, "kind": lang}

    # pass 1: definitions
    for p, rec in sorted(idx.files.items()):
        if rec["lang"] == "yaml":
            YamlWalker(idx, p).walk()
        elif rec["lang"] == "bash":
            bash_pass1(idx, p)
        elif rec["lang"] == "python":
            python_pass(idx, p)
        elif rec["lang"] == "ini":
            ini_pass(idx, p)
    # pass 2: references
    for p, rec in sorted(idx.files.items()):
        mention_tokens(idx, p)
        if rec["lang"] in ("yaml", "jinja"):
            ansible_tokens(idx, p)
        elif rec["lang"] == "bash":
            bash_pass2(idx, p)
    uses(idx)

    incoming = {}
    for f, l, t, how in idx.edges:
        if f != t:
            lst = incoming.setdefault(t, [])
            if [f, l, how] not in lst:
                lst.append([f, l, how])

    # compact the per-file records
    out_files = {}
    for p, rec in idx.files.items():
        out_files[p] = {
            "lang": rec["lang"], "kind": rec["kind"], "lines": rec["lines"], "summary": rec["summary"],
            "concepts": rec["concepts"], "tokens": rec["tokens"], "notes": rec["notes"],
            "tasks": rec["tasks"], "taskOf": rec["task_of"], "error": rec.get("error"),
            "incoming": incoming.get(p, []),
        }
    gl = {}
    for name, table in (("yaml", G.YAML), ("play", G.PLAY), ("task", G.TASK), ("module", G.MODULE),
                        ("opt", G.OPTION), ("jinja", G.JINJA), ("filter", G.FILTER), ("test", G.TEST),
                        ("magic", G.MAGIC), ("tool", G.TOOLS), ("cfg", G.CFG)):
        for k, v in table.items():
            gl[name + ":" + k] = v
    for i, (_, t, x) in enumerate(G.BASH):
        gl["bash:%d" % i] = (t, x)
    gl.update({
        "note:vardef": ("A variable definition", "This line defines a variable (the key) and its value. Click the name to see every place that reads it. Role defaults have the lowest priority: inventory group_vars, host_vars and -e on the command line all override them."),
        "note:setfactvar": ("A variable set by set_fact", "The key is the variable's name, the value (often Jinja) is worked out now and kept for the rest of the run."),
        "note:invvars": ("Inventory vars", "Variables for every host of this group."),
        "note:children": ("children", "Groups inside this group. Here each appliance is a group."),
        "note:group": ("An inventory group", "A group name. Passed as -e zdlra=<group> to pick the appliance."),
        "note:hosts": ("hosts (inventory)", "The hosts of this group: the appliance's compute nodes."),
        "note:host": ("A host", "One machine Ansible can connect to."),
        "note:all": ("all", "The group every host belongs to."),
        "note:playname": ("Play name", "Printed as 'PLAY [ ... ]' when the play starts."),
        "cfilter": ("Custom filter", "A filter written for this repo in ansible/filter_plugins/zdlra.py. Click it to read the Python."),
        "ctest": ("Custom test", "A test written for this repo in ansible/test_plugins/zdlra.py."),
    })
    for k in list(idx.symbols):
        if k.startswith("filter:"):
            gl["cfilter:" + k[7:]] = ("| %s (custom filter)" % k[7:], (idx.symbols[k]["defs"][0]["doc"] if idx.symbols[k]["defs"] else "") + "\nWritten for this repo, in ansible/filter_plugins/zdlra.py.")
        if k.startswith("test:"):
            gl["ctest:" + k[5:]] = ("is %s (custom test)" % k[5:], (idx.symbols[k]["defs"][0]["doc"] if idx.symbols[k]["defs"] else "") + "\nWritten for this repo, in ansible/test_plugins/zdlra.py.")

    rev = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], cwd=REPO).decode().strip()
    branch = subprocess.check_output(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=REPO).decode().strip()
    data = {"files": out_files, "symbols": idx.symbols, "glossary": gl, "chains": chains(idx),
            "entries": [e for e in ENTRY_POINTS if e in idx.files], "rev": rev, "branch": branch}
    with open(os.path.join(HERE, "viewer.html"), encoding="utf-8") as fh:
        viewer = fh.read()
    for path, mode in outputs:
        page = P.render(viewer, data, mode)
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(page)
    n_links = sum(len(t) for r in idx.files.values() for t in r["tokens"].values())
    print("Wrote %s: %d files, %d symbols, %d links, %d KB" % (
        ", ".join(os.path.relpath(p) for p, _ in outputs), len(idx.files), len(idx.symbols), n_links, len(page) // 1024))


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("-o", "--output", default=os.path.join(REPO, "docs", "code-tracer.html"),
                    help="the standalone page, with no Claude (default: docs/code-tracer.html)")
    ap.add_argument("--trainer-output", default=os.path.join(REPO, "docs", "trainer", "code-tracer.html"),
                    help="the Exadata Trainer's page, with Ask Claude (default: docs/trainer/code-tracer.html; '' to skip)")
    a = ap.parse_args()
    build([(a.output, "none")] + ([(a.trainer_output, "trainer")] if a.trainer_output else []))
