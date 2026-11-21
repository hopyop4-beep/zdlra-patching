#!/usr/bin/env python3
"""Build the Bash code tracer: one HTML file that opens the shell version of the patching
(zdlra_patch.sh, jump/, staging/) and shows, for any line, what it does in plain words, the
Bash idea behind it, and where it connects: which function it is in, who calls that
function, and the chain of calls from the script you run down to it.

    python3 tools/code_tracer/build_bash.py            # writes docs/code-tracer-bash.html
    python3 tools/code_tracer/build_bash.py -o out.html

Needs Python 3.6+ only. Run it again after the scripts change; the page itself needs
nothing but a browser.
"""

import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import glossary_bash as GB  # noqa: E402
import shlex_lite as SH  # noqa: E402
import page as P  # noqa: E402

REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
ENTRY_POINTS = ["zdlra_patch.sh", "jump/zdlra_patch_run.sh", "jump/oem_blackout.sh", "staging/zdlra_stage.sh"]
SKIP = re.compile(r"^(ansible/|tools/|LICENSE$|\.git)|^docs/.*\.html$|\.gitkeep$")
FILE_MENTION = re.compile(r"[A-Za-z0-9_./-]+\.(?:sh|ksh|ps1|md|conf\.example|conf|txt)\b")
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
ORACLE_TOOLS = {
    "racli": ("racli (Recovery Appliance CLI)", "Oracle's command-line tool for the ZDLRA software: racli version, racli run preinstall, racli alter appliance, racli update appliance (the 2-hour patch)."),
    "patchmgr": ("patchmgr (Exadata patch manager)", "Oracle's tool that patches Exadata storage cells, switches and compute nodes. It runs from one node and patches others. It must never be cut short, which is why these scripts run it in a detached screen session."),
    "dcli": ("dcli (distributed CLI)", "Runs the same command on many cells or nodes at once, listed in a group file (-g cell_group)."),
    "imageinfo": ("imageinfo", "Shows the Exadata image version of a cell or compute node; used to check a patch worked."),
    "emcli": ("emcli (Enterprise Manager CLI)", "Command-line access to Oracle Enterprise Manager (OEM): log in, create or stop blackouts, suspend or resume jobs."),
    "sqlplus": ("sqlplus", "Oracle's SQL command-line client. Here it runs as the raAutomation user to pause and resume replication and count active backups."),
    "crsctl": ("crsctl", "Oracle Clusterware control: crsctl stat res -t shows the state of every cluster resource."),
    "cellcli": ("cellcli", "The command-line interface on a storage cell."),
    "precheck": ("Oracle precheck", "Oracle's ZDLRA precheck script: checks the appliance is ready to patch and lists failures and warnings. zdlra_patch.sh runs it in a screen session and reads its summary."),
    "blackout": ("OEM blackout", "Tells Enterprise Manager to ignore alerts for targets during maintenance, so patching doesn't page anyone."),
    "screen": ("screen", "Runs a program in a terminal session that keeps going when you disconnect. The long Oracle commands run in one, so nothing can cut them short."),
}


def lang_of(path):
    b = os.path.basename(path)
    if b.endswith((".sh", ".ksh")):
        return "bash"
    if b.endswith((".conf", ".conf.example")):
        return "bash"
    if b.endswith(".md"):
        return "markdown"
    if b.endswith(".ps1"):
        return "powershell"
    return "text"


def comments_above(lines, i):
    out = []
    j = i - 1
    while j >= 0 and lines[j].strip().startswith("#") and not lines[j].startswith("#!"):
        t = re.sub(r"^\s*# ?", "", lines[j])
        if re.match(r"^-{5,}$", t.strip()):
            break
        out.insert(0, t)
        j -= 1
    return "\n".join(out).strip()


def header_summary(lines):
    out, started = [], False
    for ln in lines[:80]:
        s = ln.strip()
        if s.startswith("#!") or (not started and s in ("", "#")):
            continue
        if s.startswith("#") or s.startswith("<#"):
            started = True
            out.append(re.sub(r"^#+ ?", "", s))
        elif not s.startswith("#") and started:
            break
        elif s and not started:
            out.append(s)
            started = True
            if len(out) > 6:
                break
    return "\n".join(out).strip()


def unquote(w):
    if len(w) >= 2 and w[0] == w[-1] and w[0] in "'\"":
        return w[1:-1]
    return w


def first_sentence(text, limit=150):
    t = " ".join(text.split()).replace("e.g.", "e\u2024g\u2024").replace("i.e.", "i\u2024e\u2024")
    m = re.match(r"(.+?[.:;])(\s|$)", t)
    s = m.group(1) if m else t
    if s.endswith((":", ";")):
        s = s[:-1]
    if len(s) > limit:
        s = s[:limit - 1].rsplit(" ", 1)[0] + "…"
    return s.replace("\u2024", ".")


def short_desc(d, limit=80):
    s = first_sentence(re.sub(r"\s*\([^)]*\)", "", d), 200).rstrip(".")
    if len(s) > limit:
        s = s[:limit - 1].rsplit(" ", 1)[0] + "…"
    if len(s) > 1 and s[0].isupper() and (s[1].islower() or s[1] == " "):
        s = s[0].lower() + s[1:]
    return s


def code(t, limit=70):
    t = " ".join(t.split())
    if len(t) > limit:
        t = t[:limit - 1] + "…"
    return "`" + t.replace("`", "'") + "`"


def msg(t, limit=90):
    t = unquote(" ".join(t.split()))
    if len(t) > limit:
        t = t[:limit - 1] + "…"
    return "“" + t + "”"


class Index(object):
    def __init__(self):
        self.files = {}
        self.symbols = {}
        self.def_at = set()
        self.nodes = {}       # call-graph nodes: key -> {label, f, l, kind}
        self.calls = []       # (from_node, to_node, file, line, how)
        self.edges = []       # file-level: (from_path, from_line, to_path, how)

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


# ======================================================================================
# One script (a file, or a script inside a quoted here-document)
# ======================================================================================
class Script(object):
    def __init__(self, idx, path, first=0, last=None, scope=None, parent=None):
        self.idx, self.path = idx, path
        self.rec = idx.files[path]
        self.lines = self.rec["lines"]
        self.first, self.last = first, (len(self.lines) if last is None else last)
        self.scope = scope or path                      # functions and remote variables are per script
        self.group = os.path.dirname(path) or "."       # globals are shared with the config file next to it
        self.parent = parent
        self.reader = SH.read(self.lines, self.first, self.last)
        self.funcs = {}                                  # name -> block
        for b in self.reader.blocks:
            if b.kind == "func":
                self.funcs.setdefault(b.name, b)
        self.func_blocks = sorted((b for b in self.reader.blocks if b.kind == "func"), key=lambda b: b.start)
        self.locals = {}                                 # func name -> {var: line}
        self.top = "top:" + self.scope
        self.inner = []                                  # Scripts inside quoted here-documents

    # --- helpers -------------------------------------------------------------------------
    def func_at(self, i):
        best = None
        for b in self.func_blocks:
            if b.start <= i <= (b.end if b.end is not None else b.start):
                if best is None or b.start >= best.start:
                    best = b
        return best

    def node_of(self, i):
        b = self.func_at(i)
        return self.fkey(b.name) if b else self.top

    def fkey(self, name):
        return "func:%s:%s" % (self.scope, name)

    def gkey(self, name):
        if self.parent is not None:
            return "shvar:%s:%s" % (self.scope, name)
        return "shvar:%s:%s" % (self.group, name)

    def lkey(self, fname, name):
        return "shvar:%s:%s:%s" % (self.scope, fname, name)

    def code_part(self, i):
        L = self.reader.out.get(i)
        t = self.lines[i]
        if L is not None and L.comment is not None:
            t = t[:L.comment]
        return t

    # --- pass 1: definitions ----------------------------------------------------------
    def pass1(self):
        idx, path = self.idx, self.path
        where = os.path.basename(path) if self.parent is None else "the script in the here-document on line %d" % (self.first)
        for b in self.func_blocks:
            doc = comments_above(self.lines, b.start)
            key = self.fkey(b.name)
            idx.define(key, b.name + "()", "func", path, b.start, "function in " + where, doc)
            idx.nodes[key] = {"label": b.name + "()", "f": path, "l": b.start, "kind": "func"}
        idx.nodes[self.top] = {"label": (os.path.basename(path) if self.parent is None else "here-document script, line %d" % self.first),
                               "f": path, "l": self.first, "kind": "top"}
        for i in sorted(self.reader.out):
            L = self.reader.out[i]
            if L.body_of is not None:
                continue
            if L.funcdef:
                n, s, e = L.funcdef
                idx.token(path, i, s, e, "func", self.fkey(n))
            fb = self.func_at(i)
            items = L.items
            words = [(t, s, e) for k, t, s, e in items if k == "w"]
            prev_kind = None
            for n_item, (k, t, s, e) in enumerate(items):
                if k != "w":
                    prev_kind = t
                    continue
                prevw = None
                for kk, tt, ss, ee in reversed(items[:n_item]):
                    prevw = (kk, tt)
                    break
                m = SH.ASSIGN.match(t)
                cmdpos = prevw is None or prevw[0] in ("op", "pat") and prevw[1] in (";", "&&", "||", "|", "(", ")", "{", ";;") or (
                    prevw[0] == "w" and (prevw[1] in ("then", "do", "else", "{", "local", "export", "readonly", "declare", "typeset", "!") or SH.ASSIGN.match(prevw[1]) or prevw[1].startswith("-") and self.decl_before(items, n_item)))
                if prevw is not None and prevw[0] == "op" and prevw[1] not in (";", "&&", "||", "|", "(", ")", "{", ";;"):
                    cmdpos = False
                if prevw is not None and prevw[0] == "pat":
                    cmdpos = True
                if m and cmdpos:
                    self.define_var(m.group(1), i, s, fb, self.decl_before(items, n_item), t)
                elif not m and self.decl_before(items, n_item) and IDENT.fullmatch(t):
                    self.define_var(t, i, s, fb, self.decl_before(items, n_item), t)
            # for x in / read x y / mapfile -t x / printf -v x
            for n_item, (k, t, s, e) in enumerate(items):
                if k != "w":
                    continue
                nxt = [it for it in items[n_item + 1:] if it[0] == "w"]
                if t == "for" and nxt and IDENT.fullmatch(nxt[0][1]):
                    self.define_var(nxt[0][1], i, nxt[0][2], fb, None, "for", how="loop variable")
                if t in ("read", "mapfile", "readarray") or (t == "printf" and nxt and nxt[0][1] == "-v"):
                    names = self.read_targets(t, nxt)
                    for nm, ns in names:
                        self.define_var(nm, i, ns, fb, None, t, how={"read": "read from input", "printf": "set by printf -v"}.get(t, "filled by mapfile"))
        for reg in self.reader.heredoc_regions:
            if reg["quoted"] and reg["first"] <= reg["last"]:
                inner = Script(self.idx, path, reg["first"], reg["last"] + 1, scope="%s@%d" % (path, reg["first"] + 1), parent=self)
                inner.region = reg
                self.inner.append(inner)
                inner.pass1()

    def decl_before(self, items, n):
        for k, t, s, e in reversed(items[:n]):
            if k != "w":
                return None
            if t in ("local", "declare", "typeset", "export", "readonly"):
                return t
            if not (t.startswith("-") or SH.ASSIGN.match(t) or IDENT.fullmatch(t)):
                return None
        return None

    def read_targets(self, cmd, nxt):
        out, skip = [], False
        takes_arg = {"read": ("-p", "-t", "-u", "-d", "-n", "-N", "-a"), "mapfile": ("-d", "-n", "-O", "-s", "-u", "-C", "-c"),
                     "readarray": ("-d", "-n", "-O", "-s", "-u"), "printf": ()}[cmd]
        for k, t, s, e in nxt:
            if skip:
                skip = False
                continue
            if t in (";", "<", "<<<"):
                break
            if t == "-a" and cmd == "read":
                continue
            if t.startswith("-"):
                if cmd == "printf" and t == "-v":
                    continue
                if t in takes_arg:
                    skip = True
                continue
            if IDENT.fullmatch(t):
                out.append((t, s))
                if cmd == "printf":
                    break
            else:
                break
        return out

    def define_var(self, name, i, col, fb, decl, word, how=None):
        idx, path = self.idx, self.path
        if name in ("then", "do", "in", "if", "IFS"):
            return
        is_local = fb is not None and (decl in ("local", "declare", "typeset") or name in self.locals.get(fb.name, {}))
        if is_local:
            self.locals.setdefault(fb.name, {}).setdefault(name, i)
            key = self.lkey(fb.name, name)
            title = "$" + name + " (local to " + fb.name + ")"
            how = how or ("local variable of %s()" % fb.name)
        else:
            key = self.gkey(name)
            title = "$" + name
            if how is None:
                if path.endswith((".conf", ".example")) and self.parent is None:
                    how = "set in the config file " + os.path.basename(path)
                elif fb is None:
                    how = "set when the script starts (" + os.path.basename(path) + ")"
                else:
                    how = "set in %s()" % fb.name
            else:
                how = how + (" in %s()" % fb.name if fb else "")
        doc = ""
        if fb is None and not self.lines[i].startswith((" ", "\t")):
            doc = comments_above(self.lines, i)
            L = self.reader.out.get(i)
            if L is not None and L.comment is not None:
                tail = self.lines[i][L.comment:].lstrip("# ").strip()
                doc = (doc + "\n" + tail).strip() if tail else doc
        idx.define(key, title, "shvar", path, i, how, doc)
        idx.token(path, i, col, col + len(name), "shvar", key)
        s = idx.symbols[key]
        if "value" not in s and decl != "local" and fb is None:
            v = self.lines[i][col + len(name):]
            m = re.match(r"\+?=(.*)", v)
            if m:
                val = m.group(1)
                L = self.reader.out.get(i)
                if L is not None and L.comment is not None:
                    val = self.lines[i][col + len(name):L.comment]
                    val = re.sub(r"^\+?=", "", val)
                s["value"] = val.strip()

    # --- pass 2: uses, calls, concepts ----------------------------------------------------
    def resolve_var(self, name, i):
        fb = self.func_at(i)
        if fb is not None and name in self.locals.get(fb.name, {}):
            return self.lkey(fb.name, name)
        k = self.gkey(name)
        if k in self.idx.symbols:
            return k
        return None

    def known_words(self):
        """Words a variable can hold here: items of list settings and case patterns."""
        if getattr(self, "_known", None) is None:
            w = set()
            for i, L in self.reader.out.items():
                for k, t, s_, e in L.items:
                    if k == "pat":
                        w.update(x.strip().strip("()") for x in t.split("|"))
                    elif k == "w":
                        m = SH.ASSIGN.match(t)
                        if m and t[m.end():].startswith("("):
                            w.update(SH.split_words(t[m.end() + 1:-1]))
            self._known = w
        return self._known

    def resolve_func(self, name):
        if name in self.funcs:
            return self.fkey(name)
        return None

    def pass2(self, scripts_by_base):
        idx, path = self.idx, self.path
        for i in sorted(self.reader.out):
            L = self.reader.out[i]
            if L.body_of is not None:
                continue
            here = self.node_of(i)
            for name, s, e in L.vars:
                k = self.resolve_var(name, i)
                if k:
                    idx.token(path, i, s, e, "shvar", k)
            for name, s, e in L.arith:
                k = self.resolve_var(name, i)
                if k:
                    idx.token(path, i, s, e, "shvar", k)
            for name, s, e, depth in L.cmds:
                fk = self.resolve_func(name)
                if fk:
                    off = self.lines[i].find(name, s)
                    if off >= 0:
                        idx.token(path, i, off, off + len(name), "func", fk)
                    idx.calls.append((here, fk, path, i, "call"))
                    continue
                m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$", name)
                if m:
                    pre = m.group(1)
                    cands = sorted(n for n in self.funcs if n.startswith(pre))
                    known = self.known_words()
                    picked = [n for n in cands if n[len(pre):] in known]
                    cands = picked or cands
                    if cands:
                        dk = "dyn:%s:%d" % (self.scope, i)
                        s_ = idx.sym(dk, name, "dyn")
                        s_["defs"] = [{"f": path, "l": self.funcs[n].start, "how": n + "()", "doc": first_sentence(comments_above(self.lines, self.funcs[n].start))} for n in cands]
                        off = self.lines[i].find(pre, s)
                        idx.token(path, i, off, off + len(pre), "dyn", dk)
                        for n in cands:
                            idx.calls.append((here, self.fkey(n), path, i, "dynamic"))
                    continue
                base = os.path.basename(unquote(name))
                if base in scripts_by_base and base.endswith(".sh"):
                    tgt = scripts_by_base[base]
                    idx.calls.append((here, "top:" + tgt, path, i, "runs"))
                    idx.edges.append((path, i, tgt, "runs"))
                    continue
                vm = re.match(r'^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$', name)
                if vm:
                    k = self.resolve_var(vm.group(1), i)
                    val = idx.symbols.get(k, {}).get("value", "") if k else ""
                    tool = os.path.basename(unquote(val)) if val else ""
                    if vm.group(1) in ("SCRIPT_PATH",) or tool.endswith(".sh") and tool in scripts_by_base:
                        tgt = path if vm.group(1) == "SCRIPT_PATH" else scripts_by_base[tool]
                        idx.calls.append((here, "top:" + tgt, path, i, "runs"))
                    if tool in ORACLE_TOOLS:
                        idx.concept(path, i, "tool:" + tool)
                    continue
                if name in GB.COMMANDS:
                    idx.concept(path, i, "cmd:" + name)
                if name in ("trap",):
                    self.trap_calls(i, L, here)
            # a script run over ssh: a variable holding a .sh path of this repo
            for name, s, e in L.vars:
                k = self.resolve_var(name, i)
                val = idx.symbols.get(k, {}).get("value", "") if k else ""
                b = os.path.basename(unquote(val))
                if b.endswith(".sh") and b in scripts_by_base and scripts_by_base[b] != path and any(
                        c[0] not in ("info", "warn", "err", "die", "log", "echo", "printf") for c in L.cmds):
                    tgt = scripts_by_base[b]
                    idx.calls.append((here, "top:" + tgt, path, i, "over ssh"))
                    idx.edges.append((path, i, tgt, "over ssh"))
            # source "$CONFIG_FILE": the config file of this folder
            if any(c[0] in ("source", ".") for c in L.cmds):
                for p in sorted(idx.files):
                    if (os.path.dirname(p) or ".") == self.group and p.endswith(".conf.example"):
                        idx.edges.append((path, i, p, "source"))
                        idx.calls.append((here, "file:" + p, path, i, "source"))
            # concepts from the code on this line
            code_t = self.code_part(i)
            if code_t.strip():
                for key, rx, t, x in SYNTAX_RX:
                    if rx.search(code_t):
                        idx.concept(path, i, "sh:" + key)
                for m in IDENT.finditer(code_t):
                    w = m.group(0)
                    if w in ORACLE_TOOLS and w not in ("screen", "precheck", "blackout"):
                        idx.token(path, i, m.start(), m.end(), "tool", "tool:" + w)
                        idx.concept(path, i, "tool:" + w)
            elif self.lines[i].lstrip().startswith("#"):
                idx.concept(path, i, "sh:shebang" if self.lines[i].startswith("#!") and i == 0 else "sh:comment")
        # here-document regions: a call edge from the function that feeds them
        for inner in self.inner:
            reg = inner.region
            mv = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)=\$\(\s*cat\s+<<", self.lines[reg["start"]])
            if mv:
                rx = re.compile(r"\$\{?%s\b" % mv.group(1))
                for j, ln in enumerate(self.lines):
                    Lj = self.reader.out.get(j)
                    if Lj is not None and Lj.body_of is None and rx.search(self.code_part(j)):
                        idx.calls.append((self.node_of(j), inner.top, path, j, "sends the script in $" + mv.group(1)))
                idx.nodes[inner.top]["label"] = "script in $" + mv.group(1)
            else:
                here = self.node_of(reg["start"])
                idx.calls.append((here, inner.top, path, reg["start"], "here-document"))
            inner.pass2(scripts_by_base)

    def trap_calls(self, i, L, here):
        idx, path = self.idx, self.path
        ws = [t for k, t, s, e in L.items if k == "w"]
        if "trap" not in ws:
            return
        n = ws.index("trap")
        if n + 1 >= len(ws):
            return
        body = unquote(ws[n + 1])
        sigs = " ".join(ws[n + 2:])
        for m in IDENT.finditer(body):
            if m.group(0) in self.funcs:
                fk = self.fkey(m.group(0))
                off = self.lines[i].find(m.group(0), self.lines[i].find("trap"))
                if off >= 0:
                    idx.token(path, i, off, off + len(m.group(0)), "func", fk)
                idx.calls.append((here, fk, path, i, "trap " + sigs))


SYNTAX_RX = [(k, re.compile(rx), t, x) for k, rx, t, x in GB.SYNTAX]


# ======================================================================================
# Plain-words explanations
# ======================================================================================
class Explainer(object):
    def __init__(self, idx, script):
        self.idx, self.sc = idx, script
        self.lines = script.lines

    # --- small pieces ----------------------------------------------------------------------
    def fdesc(self, name):
        if name in GB.HINTS:
            return GB.HINTS[name]
        b = self.sc.funcs.get(name)
        if b is None:
            return ""
        c = comments_above(self.lines, b.start)
        if not c:
            return ""
        s = first_sentence(c, 120).rstrip(".")
        if len(s) > 1 and s[0].isupper() and s[1].islower():
            s = s[0].lower() + s[1:]
        return s

    def show(self, w):
        """A word as the reader should see it."""
        if w.startswith('"') and w.endswith('"') and len(w) >= 2:
            inner = w[1:-1]
            if re.match(r"^\$\{?[A-Za-z_@#0-9][^\s]*\}?$", inner) or "$" in inner:
                return code(inner, 60)
            return msg(inner, 60)
        if w.startswith("'") and w.endswith("'") and len(w) >= 2:
            return code(w[1:-1], 60)
        return code(w, 60)

    def value(self, v):
        v = v.strip()
        if v in ("", '""', "''"):
            return "an empty value"
        if v.startswith("(") and v.endswith(")"):
            items = SH.split_words(v[1:-1])
            if not items:
                return "an empty list"
            shown = ", ".join(self.show(x) for x in items[:4]) + (", …" if len(items) > 4 else "")
            return "a list of %d item%s: %s" % (len(items), "s" if len(items) > 1 else "", shown)
        u = unquote(v) if v.startswith('"') else v
        m = re.match(r"^\$\((.*)\)$", u, re.S)
        if m and not u.startswith("$((") and re.match(r"^\s*cat\s+<<-?\s*'?(\w+)", m.group(1)):
            d = re.match(r"^\s*cat\s+<<-?\s*'?(\w+)", m.group(1)).group(1)
            return "the lines below, up to %s, exactly as written (a script to send to a node)" % code(d)
        if m and not u.startswith("$(("):
            inner = m.group(1).strip()
            fn = inner.split()[0] if inner.split() else ""
            extra = ""
            if fn in self.sc.funcs:
                d = self.fdesc(fn)
                extra = " (%s: %s)" % (fn, d) if d else ""
            return "the output of " + code(inner, 70) + extra
        m = re.match(r"^\$\(\((.*)\)\)$", u)
        if m:
            return "the result of " + code(m.group(1).strip())
        m = re.match(r"^\$\{([A-Za-z_][A-Za-z0-9_]*)(//?)(.*?[^\\])/(.*)\}$", u)
        if m:
            old = m.group(3).replace("\\", "")
            return "%s with %s %s replaced by %s" % (code("$" + m.group(1)), "every" if m.group(2) == "//" else "the first", code(old), code(m.group(4)) if m.group(4) else "nothing")
        m = re.match(r"^\$\{([A-Za-z_][A-Za-z0-9_]*)(##?|%%?)(.+)\}$", u)
        if m:
            how = {"#": "the shortest match of %s cut from the start", "##": "the longest match of %s cut from the start",
                   "%": "the shortest match of %s cut from the end", "%%": "the longest match of %s cut from the end"}[m.group(2)]
            return "%s with %s" % (code("$" + m.group(1)), how % code(m.group(3)))
        m = re.match(r"^\$\{([A-Za-z_][A-Za-z0-9_]*):-(.*)\}$", u)
        if m:
            d = m.group(2)
            return "%s, or %s if that is empty" % (code("$" + m.group(1)), code(d) if d else "nothing")
        if re.match(r"^-?\d+$", v):
            return v
        if v.startswith(("'", '"')):
            if "$" in v and v.startswith('"'):
                return code(unquote(v))
            return msg(v, 70)
        return code(v)

    def args_text(self, ws, limit=3):
        if not ws:
            return ""
        shown = [self.show(w) for w in ws[:limit]]
        return " with " + ", ".join(shown) + (" and more" if len(ws) > limit else "")

    # --- conditions ---------------------------------------------------------------------
    def test_prop(self, inner):
        toks = SH.split_words(inner)
        parts, conj, cur = [], [], []
        for t in toks:
            if t in ("&&", "||"):
                parts.append(cur)
                conj.append(" and " if t == "&&" else " or ")
                cur = []
            else:
                cur.append(t)
        parts.append(cur)
        out = []
        for p in parts:
            out.append(self.term(p))
        s = out[0]
        for c, p in zip(conj, out[1:]):
            s += c + p
        return s

    def term(self, p):
        p = [x for x in p if x not in ("(", ")")]
        neg = False
        while p and p[0] == "!":
            neg = not neg
            p = p[1:]
        if not p:
            return "true"
        if len(p) == 2 and p[0] in GB.TESTS:
            a = self.show(p[1])
            if neg:
                return NEG_UNARY.get(p[0], "it is not true that " + GB.TESTS[p[0]]).format(a=a)
            return GB.TESTS[p[0]].format(a=a)
        if len(p) >= 3 and p[1] in GB.TESTS:
            a, op, b = self.show(p[0]), p[1], " ".join(p[2:])
            if op in ("==", "=", "!="):
                bb = b
                neg2 = (op == "!=") != neg
                if bb.startswith("*") and bb.endswith("*") and len(bb) > 2:
                    core = self.show(bb[1:-1])
                    return "%s %s %s" % (a, "does not contain" if neg2 else "contains", core)
                if bb.endswith("*") and not bb.startswith("*") and "*" not in bb[:-1]:
                    return "%s %s %s" % (a, "does not start with" if neg2 else "starts with", self.show(bb[:-1]))
                if bb.startswith("*") and "*" not in bb[1:]:
                    return "%s %s %s" % (a, "does not end with" if neg2 else "ends with", self.show(bb[1:]))
                if re.search(r"[*?\[]", unquote(bb) if bb.startswith("'") else bb) and not bb.startswith('"'):
                    return "%s %s the pattern %s" % (a, "does not match" if neg2 else "matches", code(bb))
                return "%s %s %s" % (a, "is not" if neg2 else "is", self.show(bb))
            phrase = GB.TESTS[op].format(a=a, b=self.show(b) if op != "=~" else code(b))
            return ("it is not true that " + phrase) if neg else phrase
        if len(p) == 1:
            a = self.show(p[0])
            return ("%s is empty" if neg else "%s is not empty") % a
        return ("not " if neg else "") + code(" ".join(p))

    def arith_prop(self, e, neg=False):
        e = e.strip()
        parts = re.split(r"\s*(\|\||&&)\s*", e)
        if len(parts) > 1:
            out = [self.arith_prop(x) for x in parts[0::2]]
            s = out[0]
            for c, x in zip(parts[1::2], out[1:]):
                s += (" or " if c == "||" else " and ") + x
            return ("it is not true that " + s) if neg else s
        while e.startswith("!"):
            neg = not neg
            e = e[1:].strip()
        if e.startswith("(") and e.endswith(")"):
            return self.arith_prop(e[1:-1], neg)
        if e == "$#":
            return "no arguments are left" if neg else "there are arguments left"
        m = re.match(r"^\$?\{?#([A-Za-z_][A-Za-z0-9_]*)\[@\]\}?$", e)
        if m:
            return ("the list %s is empty" if neg else "the list %s has items") % code(m.group(1))
        if re.match(r"^\$?[A-Za-z_][A-Za-z0-9_]*$", e):
            n = e.lstrip("$")
            return ("%s is off (0)" if neg else "%s is on (not 0)") % code(n)
        m = re.match(r"^(.+?)\s*(==|!=|<=|>=|<|>)\s*(.+)$", e)
        if m:
            words = {"==": "equals", "!=": "is not", "<=": "is at most", ">=": "is at least", "<": "is less than", ">": "is greater than"}
            s = "%s %s %s" % (code(m.group(1)), words[m.group(2)], code(m.group(3)))
            return ("it is not true that " + s) if neg else s
        return ("%s is 0" if neg else "%s is not 0") % code(e)

    def arith_act(self, e):
        e = e.strip()
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*(\+\+|--)$|^(\+\+|--)\s*([A-Za-z_][A-Za-z0-9_]*)$", e)
        if m:
            n = m.group(1) or m.group(4)
            return ("adds 1 to %s" if "+" in (m.group(2) or m.group(3)) else "takes 1 from %s") % code(n)
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*(\+|-)=\s*(.+)$", e)
        if m:
            return ("adds %s to %s" if m.group(2) == "+" else "takes %s from %s") % (code(m.group(3)), code(m.group(1)))
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^=].*)$", e)
        if m:
            return "sets %s to the result of %s" % (code(m.group(1)), code(m.group(2)))
        return "checks that " + self.arith_prop(e)

    def prop(self, seg):
        ws = seg["words"]
        neg = False
        while ws and ws[0] == "!":
            neg = not neg
            ws = ws[1:]
        if not ws:
            return "true"
        w0 = ws[0]
        if w0.startswith("[[") and w0.endswith("]]"):
            p = self.test_prop(w0[2:-2].strip())
            return self.negate(p) if neg else p
        if w0.startswith("((") and w0.endswith("))"):
            return self.arith_prop(w0[2:-2], neg)
        if w0 in ("[", "test"):
            inner = " ".join(ws[1:-1] if ws[-1] == "]" else ws[1:])
            p = self.test_prop(inner)
            return self.negate(p) if neg else p
        a = [w for w in ws if not SH.ASSIGN.match(w)] or ws
        name = unquote(a[0])
        if SH.ASSIGN.match(w0) and len(a) == len(ws) and "$(" in w0:
            m = SH.ASSIGN.match(w0)
            return "%s could be read (the command in it succeeds)" % code(m.group(1)) if not neg else "the command filling %s fails" % code(m.group(1))
        cmd_txt = code(" ".join(a), 60)
        if name in self.sc.funcs:
            d = self.fdesc(name)
            s = "%s %s" % (cmd_txt, "fails" if neg else "succeeds")
            return s + (" (%s: %s)" % (name, d) if d else "")
        if name == "grep":
            return self.grep_prop(a[1:], seg["redirs"], neg)
        if name == "true":
            return "true"
        return "%s %s" % (cmd_txt, "fails" if neg else "succeeds")

    def grep_prop(self, args, redirs, neg=False):
        flags = "".join(x[1:] for x in args if x.startswith("-") and not x.startswith("--"))
        plain = [x for x in args if not x.startswith("-")]
        pat = plain[0] if plain else ""
        src = [self.show(x) for x in plain[1:3]]
        for op, t in redirs:
            if op == "<<<":
                src = [self.show(t)]
            elif op == "<" and not t.startswith("<("):
                src = [self.show(t)]
            elif op == "<" and t.startswith("<("):
                src = ["the output of " + code(t[2:-1], 50)]
        where = " or ".join(src) if src else "the input"
        if "x" in flags and "F" in flags:
            what = "the line %s" % self.show(pat)
        elif "F" in flags:
            what = "the text %s" % self.show(pat)
        else:
            what = "a line matching %s" % self.show(pat)
        if "i" in flags:
            what += " (upper or lower case)"
        return "%s %s %s" % (where, "does not have" if neg else "has", what)

    def negate(self, p):
        for a, b in NEG_PHRASES:
            if a in p:
                return p.replace(a, b, 1)
        return "it is not true that " + p

    # --- actions -----------------------------------------------------------------------------
    def act(self, seg):
        ws = list(seg["words"])
        if not ws:
            return ""
        w0 = ws[0]
        if w0 == "!":
            return "checks that " + self.prop(seg)
        if w0.startswith("[[") or w0 in ("[", "test"):
            return "checks that " + self.prop(seg)
        if w0.startswith("(("):
            return self.arith_act(w0[2:-2])
        assigns = []
        while ws and SH.ASSIGN.match(ws[0]):
            assigns.append(ws.pop(0))
        if not ws:
            parts = []
            for a in assigns:
                m = SH.ASSIGN.match(a)
                name, idxpart, op = m.group(1), m.group(2) or "", m.group(3)
                v = a[m.end():]
                if op == "+=":
                    if v.startswith("("):
                        parts.append("adds %s to the list %s" % (self.value(v).replace("a list of", "").replace("item:", "item").strip() if False else self.list_items(v), code(name)))
                    else:
                        parts.append("adds %s to the end of %s" % (self.value(v), code(name)))
                elif idxpart:
                    parts.append("sets item %s of %s to %s" % (code(idxpart[1:-1]), code(name), self.value(v)))
                else:
                    parts.append("sets %s to %s" % (code(name), self.value(v)))
            return ", and ".join(parts)
        env = ""
        if assigns:
            env = " (with %s set just for that command)" % ", ".join(code(a, 40) for a in assigns)
        name = unquote(ws[0])
        args = ws[1:]
        r = self.command(name, ws[0], args, seg)
        return r + env + self.redirs(seg)

    def list_items(self, v):
        items = SH.split_words(v[1:-1])
        if not items:
            return "nothing"
        return ", ".join(self.show(x) for x in items[:4]) + (", …" if len(items) > 4 else "")

    def command(self, name, raw, args, seg):
        flags = [a for a in args if a.startswith("-") and not a.startswith("--") or a in ("--",)]
        plain = [a for a in args if not a.startswith("-")]
        if name in ("local", "declare", "typeset", "readonly", "export"):
            return self.decl(name, args)
        if name == "return":
            return self.ret("leaves the function", args)
        if name == "exit":
            return self.ret("ends the script", args)
        if name == "shift":
            n = args[0] if args else "1"
            return "drops the first argument%s, so the next one becomes %s" % ("" if n == "1" else "s (%s of them)" % n, code("$1"))
        if name == "break":
            return "leaves the loop"
        if name == "continue":
            return "skips to the next pass of the loop"
        if name == "true" or name == ":":
            return "does nothing (always succeeds)"
        if name == "set":
            return self.set_flags(args)
        if name == "trap":
            return self.trap(args)
        if name in ("source", "."):
            return "reads %s into this shell, so the settings in it replace the defaults set earlier" % (self.show(args[0]) if args else "the file")
        if name == "read":
            names = [a for a in args if IDENT.fullmatch(a)]
            prompt = ""
            if "-p" in args and args.index("-p") + 1 < len(args):
                prompt = ", showing the prompt " + msg(args[args.index("-p") + 1], 60)
                names = [a for a in names if a != unquote(args[args.index("-p") + 1])]
            tgt = ", ".join(code("$" + n) for n in names) or code("$REPLY")
            return "reads a line of input into %s%s" % (tgt, prompt)
        if name in ("mapfile", "readarray"):
            names = [a for a in args if IDENT.fullmatch(a)]
            return "reads every line of its input into the list %s" % (code(names[-1]) if names else code("MAPFILE"))
        if name == "echo":
            text = " ".join(a for a in args if a not in ("-n", "-e"))
            return "prints " + (msg(text) if text else "an empty line")
        if name == "printf":
            if args and args[0] == "-v" and len(args) > 2:
                return "formats %s with %s and stores it in %s" % (code(unquote(args[2]), 40), ", ".join(self.show(a) for a in args[3:5]) or "nothing", code(args[1]))
            if args:
                fmt = unquote(args[0])
                rest = args[1:]
                if fmt in ("%s\\n", "'%s\\n'") and rest:
                    many = len(rest) > 1 or any("[@]" in a or "[*]" in a for a in rest)
                    return "prints %s%s" % (", ".join(self.show(a) for a in rest[:3]), ", one item per line" if many else "")
                return "prints %s%s" % (code(fmt, 50), (" filled in with " + ", ".join(self.show(a) for a in rest[:3])) if rest else "")
            return "prints nothing"
        if name == "cd":
            return "goes into the folder %s" % (self.show(args[0]) if args else "home")
        if name in ("info", "warn", "err", "die", "log") and name in self.sc.funcs:
            text = " ".join(args if name != "log" else args[1:])
            if text in ('"$@"', '"$*"'):
                level = {"info": "an INFO", "warn": "a WARN", "err": "an ERROR", "die": "an ERROR", "log": "a %s" % (args[0] if args else "")}[name]
                return ("logs the arguments it was given as %s line" % level) + (" and stops the script" if name == "die" else "")
            return {"info": "logs %s", "warn": "logs the warning %s", "err": "logs the error %s",
                    "die": "stops the script with the error %s", "log": "logs %s"}[name] % (msg(text) if text else "an empty line")
        if name in self.sc.funcs:
            d = self.fdesc(name)
            return "calls %s%s%s" % (code(name), self.args_text(args), (" (" + d + ")") if d else "")
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$", name)
        if m and any(n.startswith(m.group(1)) for n in self.sc.funcs):
            ex = sorted((n for n in self.sc.funcs if n.startswith(m.group(1))), key=lambda n: self.sc.funcs[n].start)
            ex = [n for n in ex if n[len(m.group(1)):] in self.sc.known_words()] or ex
            return "calls the function whose name is %s followed by the value of %s, for example %s" % (code(m.group(1)), code("$" + m.group(2)), code(ex[0]))
        if name in ("$@", "${@}"):
            return "runs the command it was given as its arguments (%s)" % code('"$@"')
        b = os.path.basename(name)
        if b.endswith(".sh"):
            return "runs the script %s%s" % (code(b), self.args_text(args, 4))
        vm = re.match(r'^\$\{?([A-Za-z_][A-Za-z0-9_]*)(\[@\])?\}?$', name)
        if vm:
            var = vm.group(1)
            k = self.sc.resolve_var(var, seg["line"])
            val = self.idx.symbols.get(k, {}).get("value", "") if k else ""
            if vm.group(2):
                return "runs the command held in the list %s%s" % (code(var), self.args_text(args))
            prog = os.path.basename(unquote(val)) if val and not val.startswith("(") else ""
            if prog and re.match(r"^[\w.-]+$", prog):
                d = ORACLE_TOOLS.get(prog, (None, ""))[1] or (GB.COMMANDS.get(prog, (None, ""))[1])
                return "runs %s (the program in %s)%s%s" % (code(prog), code("$" + var), self.args_text(args), (": " + first_sentence(d, 110)) if d else "")
            return "runs the program in %s%s" % (code("$" + var), self.args_text(args))
        b = os.path.basename(name)
        if b.endswith(".sh"):
            return "runs the script %s%s" % (code(b), self.args_text(args, 4))
        if name == "grep":
            pat = plain[0] if plain else ""
            src = plain[1:] if len(plain) > 1 else []
            where = (" in " + ", ".join(self.show(x) for x in src[:2])) if src else " in its input"
            fl = "".join(f[1:] for f in flags if f.startswith("-") and not f.startswith("--"))
            if "q" in fl:
                return "checks whether %s %s (grep -q prints nothing, it only succeeds or fails)" % (where.replace(" in ", "", 1), "has " + ("the line " if "x" in fl else "a line matching ") + self.show(pat))
            if "v" in fl:
                return "prints the lines that do not match %s%s" % (self.show(pat), where)
            if "c" in fl:
                return "counts the lines matching %s%s" % (self.show(pat), where)
            return "prints the lines matching %s%s" % (self.show(pat), where)
        if name == "sed" and "-n" in flags and plain:
            m = re.match(r"^s(.)\^?([^\1]*?)\1\1p$", unquote(plain[0]))
            m2 = re.match(r"^s#\^?(.*?)##p$|^s/\^?(.*?)//p$", unquote(plain[0]))
            if m2:
                key = (m2.group(1) or m2.group(2) or "").replace("\\", "")
                return "prints the value after %s%s" % (code(key), (" in " + self.show(plain[1])) if len(plain) > 1 else " in its input")
        if name == "mkdir":
            return "creates the folder %s%s" % (", ".join(self.show(x) for x in plain[:2]), " (and any missing parent folders)" if "-p" in flags else "")
        if name == "rm":
            return "deletes %s" % ", ".join(self.show(x) for x in plain[:3])
        if name == "touch":
            return "creates the marker file %s" % ", ".join(self.show(x) for x in plain[:2])
        if name == "sleep":
            return "waits %s seconds" % (self.show(plain[0]) if plain else "")
        if name == "cat" and plain:
            return "prints the contents of %s" % ", ".join(self.show(x) for x in plain[:2])
        if name == "kill" and "-0" in flags:
            return "checks that process %s is still running (kill -0 sends no signal)" % (self.show(plain[0]) if plain else "")
        if name == "mv":
            return "moves (renames) %s to %s" % (self.show(plain[0]), self.show(plain[-1])) if len(plain) >= 2 else "moves files"
        if name == "date":
            fmt = [a for a in args if a.startswith(("+", "'+", '"+'))]
            return "gets the current date and time" + ((" as " + code(unquote(fmt[0]))) if fmt else "")
        if name == "ssh":
            return "runs a command on another machine over ssh"
        if name == "screen":
            if any(f.startswith("-dm") for f in flags):
                return "starts a detached screen session (the command in it keeps running even if this connection drops)"
            if "-ls" in flags:
                return "lists the running screen sessions"
            return "runs screen"
        if name in GB.COMMANDS:
            d = GB.COMMANDS[name][1]
            return "runs %s (%s)" % (code(" ".join([name] + args), 60), short_desc(d) if d else name)
        if name in ORACLE_TOOLS:
            return "runs %s (%s)" % (code(" ".join([name] + args), 60), first_sentence(ORACLE_TOOLS[name][1], 100).rstrip("."))
        return "runs %s" % code(" ".join([raw] + args), 70)

    def decl(self, name, args):
        flags = "".join(a[1:] for a in args if a.startswith("-"))
        rest = [a for a in args if not a.startswith("-")]
        kind = {"local": "the local variable", "declare": "the variable", "typeset": "the variable", "readonly": "the read-only variable", "export": "the exported variable"}[name]
        if "A" in flags:
            kind = "the dictionary (associative array)"
        elif "a" in flags:
            kind = "the list (array)"
        if "g" in flags:
            kind = "the global " + kind.replace("the ", "", 1)
        elif name == "declare" and self.sc.func_at(self_line(self)) is not None:
            kind = kind.replace("the ", "the local ", 1) if "local" not in kind else kind
        names, sets = [], []
        for a in rest:
            m = SH.ASSIGN.match(a)
            if m:
                names.append(m.group(1))
                sets.append("%s to %s" % (code(m.group(1)), self.value(a[m.end():])))
            else:
                names.append(a)
        if not names:
            return "lists variables"
        plural = len(names) > 1
        k = kind + ("s" if plural and not kind.endswith(")") else "")
        if plural and kind.endswith(")"):
            k = kind.replace("the ", "the ", 1)
        s = "creates %s %s" % (k, ", ".join(code(n) for n in names))
        if name == "local" or (name == "declare" and "g" not in flags):
            s += " (only seen inside this function)" if self.sc.func_at(self_line(self)) is not None else ""
        if name == "export":
            s += ", passed on to the programs this script starts"
        if sets:
            s += ", and sets " + ", ".join(sets)
        return s

    def ret(self, what, args):
        if not args:
            return what + " (its exit code is that of the last command)"
        a = unquote(args[0])
        if a == "0":
            return what + ", reporting success (exit code 0)"
        if re.match(r"^\d+$", a):
            extra = {"130": " (the usual code after Ctrl-C)", "143": " (the usual code after a kill)", "129": " (the usual code after a hangup)"}.get(a, "")
            return what + ", reporting failure (exit code %s)%s" % (a, extra)
        if "PIPESTATUS" in a:
            return what + " with the exit code of the first command of the pipe above, not the last (%s)" % code(a)
        return what + " with the exit code in %s" % code(a)

    def set_flags(self, args):
        out = []
        sw = {"e": "stop at the first command that fails", "E": "keep the ERR trap working inside functions",
              "u": "treat an unset variable as an error", "x": "print each command before it runs", "o": None}
        k = 0
        while k < len(args):
            a = args[k]
            if a == "-o" and k + 1 < len(args):
                if args[k + 1] == "pipefail":
                    out.append("make a pipe fail if any command in it fails")
                else:
                    out.append("set " + args[k + 1])
                k += 2
                continue
            if a.startswith("-") and a != "--":
                for ch in a[1:]:
                    if ch == "o" and k + 1 < len(args):
                        if args[k + 1] == "pipefail":
                            out.append("make a pipe fail if any command in it fails")
                        k += 1
                    elif sw.get(ch):
                        out.append(sw[ch])
            elif a == "--":
                return "sets the arguments %s to %s" % (code("$1 $2 …"), ", ".join(self.show(x) for x in args[k + 1:k + 4]))
            elif a.startswith("+"):
                out.append("switch off " + a)
            k += 1
        return "switches on the safety settings: " + "; ".join(out) if out else "changes shell settings"

    def trap(self, args):
        if not args:
            return "lists the traps"
        body = unquote(args[0])
        sigs = args[1:]
        when = " or ".join(GB.TRAPS.get(s, s) for s in sigs) or "it gets a signal"
        if args[0] in ("''", '""'):
            return "ignores %s from here on" % " / ".join(sigs)
        if args[0] == "-":
            return "puts back the normal handling of %s" % " / ".join(sigs)
        m = re.match(r"^exit (\d+)$", body)
        if m:
            return "makes the script exit with code %s when %s" % (m.group(1), when)
        return "sets up %s to run when %s" % (code(body, 60), when)

    def redirs(self, seg):
        out = []
        for op, tgt in seg["redirs"]:
            t = tgt
            if op in (">", "1>", ">|") and t == "/dev/null":
                out.append(", throwing the output away")
            elif op in ("&>", "&>>") and t == "/dev/null":
                out.append(", throwing all output away")
            elif op == "2>" and t == "/dev/null":
                out.append(", hiding error messages")
            elif op in ("2>&", ) and t == "1":
                out.append(", with error messages mixed into the output")
            elif op in (">&", "1>&") and t == "2":
                out.append(", to the error stream (shown on screen, not captured)")
            elif op in (">", "1>", ">|"):
                out.append(", writing the output to %s (replacing it)" % self.show(t))
            elif op in (">>", "1>>"):
                out.append(", adding the output to the end of %s" % self.show(t))
            elif op == "2>>":
                out.append(", adding error messages to %s" % self.show(t))
            elif op == "2>":
                out.append(", writing error messages to %s" % self.show(t))
            elif op in ("&>", "&>>"):
                out.append(", writing all output to %s" % self.show(t))
            elif op == "<":
                if t.startswith("<("):
                    out.append(", reading its input from the output of %s" % code(t[2:-1], 60))
                else:
                    out.append(", reading its input from %s" % self.show(t))
            elif op == "<<<":
                out.append(", with %s as its input" % self.show(t))
            elif op in ("<<", "<<-"):
                out.append(", with the lines below (up to %s) as its input" % code(unquote(t).strip("'\"\\")))
        return "".join(out)

    # --- a whole logical line ----------------------------------------------------------------
    def segments(self, items, line):
        segs, cur = [], {"words": [], "redirs": [], "line": line}
        k = 0
        while k < len(items):
            kind, t, s, e = items[k]
            if kind == "pat":
                segs.append(("pat", t))
                k += 1
                continue
            if kind == "op":
                if t in (";", "&&", "||", "|", "&", "|&", ";;", ";&", ";;&", "(", ")"):
                    segs.append((cur, t))
                    cur = {"words": [], "redirs": [], "line": line}
                    k += 1
                    continue
                tgt = ""
                if k + 1 < len(items) and items[k + 1][0] == "w":
                    tgt = items[k + 1][1]
                    k += 1
                cur["redirs"].append((t, tgt))
                k += 1
                continue
            cur["words"].append(t)
            k += 1
        segs.append((cur, None))
        return segs

    def explain(self, i, items, L, blocks_by_start):
        """Sentences for the logical line starting at i."""
        segs = self.segments(items, i)
        out = []
        sentence = ""
        mode = None          # "test" after a test whose result decides what follows
        k = 0
        while k < len(segs):
            seg, op = segs[k]
            if seg == "pat":
                out.append(self.pattern(op) + ":")
                k += 1
                continue
            ws = seg["words"]
            if not ws and not seg["redirs"]:
                if op in (";;", ";&", ";;&"):
                    out.append("This ends the branch: the case is finished.")
                k += 1
                continue
            lead = ws[0] if ws else ""
            # keywords
            if lead in ("if", "elif", "while", "until"):
                cond = {"words": ws[1:], "redirs": seg["redirs"], "line": i}
                props = [self.prop(cond)]
                while op in ("&&", "||") and k + 1 < len(segs):
                    nxt = segs[k + 1][0]
                    props.append((" and " if op == "&&" else " or ") + self.prop(nxt))
                    k += 1
                    op = segs[k][1]
                p = "".join(props)
                b = self.block_opened(L, lead, i, blocks_by_start)
                tail = self.then_tail(segs, k, b)
                if lead == "if":
                    out.append("If %s, %s" % (p, tail))
                elif lead == "elif":
                    ib = self.block_mid(i, "elif")
                    out.append("Otherwise, if %s, %s" % (p, tail))
                elif lead == "while":
                    out.append("As long as %s, %s" % (p, tail.replace("the lines below run", "the lines below run, again and again")))
                else:
                    out.append("Until %s, %s" % (p, tail))
                k = self.skip_then(segs, k)
                continue
            if lead in ("for", "select"):
                out.append(self.for_loop(ws, i, L, blocks_by_start, segs, k))
                k = self.skip_then(segs, k)
                continue
            if lead == "case":
                b = self.block_opened(L, "case", i, blocks_by_start)
                end = " (up to line %d)" % (b.end + 1) if b and b.end is not None else ""
                subj = self.show(ws[1]) if len(ws) > 1 else "a value"
                out.append("Compares %s with each pattern below%s; the first pattern that matches runs its commands." % (subj, end))
                k += 1
                continue
            if lead in ("then", "do", "else", "{") and len(ws) == 1 and not seg["redirs"]:
                out.append(self.keyword_alone(lead, i))
                k += 1
                continue
            if lead in ("then", "do", "else"):
                if lead == "else":
                    out.append("Otherwise:")
                seg = dict(seg, words=ws[1:])
                ws = seg["words"]
                lead = ws[0] if ws else ""
            if lead in ("fi", "done", "esac", "}"):
                out.append(self.closer(lead, i, seg))
                k += 1
                continue
            # a chain of commands: a && b || c | d
            if ws is not segs[k][0]["words"]:
                segs = segs[:k] + [(seg, op)] + segs[k + 1:]
            phrase, k = self.chain(segs, k)
            if phrase:
                out.append(phrase[0].upper() + phrase[1:] + ("." if not phrase.endswith((".", ":", "?")) else ""))
        return [s for s in out if s]

    def unit(self, segs, k):
        """One unit of a command list: a { } group, a pipeline, or one command.
        Returns (text, is_test_text_or_None, op_after, next_k)."""
        seg, op = segs[k]
        ws = seg["words"]
        if ws and ws[0] in ("then", "do", "else"):
            seg = dict(seg, words=ws[1:])
            ws = seg["words"]
        if ws and ws[0] == "{":
            c = k
            while c < len(segs) and segs[c][0] != "pat" and not (segs[c][0]["words"] and segs[c][0]["words"][-1] == "}"):
                c += 1
            if c >= len(segs) or segs[c][0] == "pat":
                c = len(segs) - 1
            sub = list(segs[k:c + 1])
            sub[0] = (dict(sub[0][0], words=sub[0][0]["words"][1:]), sub[0][1])
            last_seg = sub[-1][0]
            redir = ""
            if last_seg != "pat" and last_seg["words"] and last_seg["words"][-1] == "}":
                redir = self.redirs(last_seg)
                sub[-1] = (dict(last_seg, words=last_seg["words"][:-1], redirs=[]), None)
            else:
                sub[-1] = (sub[-1][0], None)
            parts, n = [], 0
            while n < len(sub):
                if sub[n][0] == "pat" or not sub[n][0]["words"]:
                    n += 1
                    continue
                ph, n = self.chain(sub, n)
                parts.append(ph)
            op = segs[c][1] if c < len(segs) else None
            text = " and then ".join(p for p in parts if p) or "does nothing"
            if redir:
                text = text + "; all of that" + redir
            return text, None, op, c + 1
        pipe = [seg]
        while op in ("|", "|&") and k + 1 < len(segs) and segs[k + 1][0] != "pat":
            k += 1
            seg2, op = segs[k]
            pipe.append(seg2)
        if len(pipe) > 1:
            return self.act(pipe[0]) + ", and passes the output to " + ", then to ".join(self.short(p) for p in pipe[1:]), None, op, k + 1
        lead = ws[0] if ws else ""
        test = None
        if lead.startswith("[[") or lead in ("[", "test", "!") or (lead.startswith("((") and self.arith_act(lead[2:-2]).startswith("checks")):
            test = self.prop(seg)
        elif lead and unquote(lead) in self.sc.funcs and self.looks_like_question(unquote(lead)):
            test = self.prop(seg)
        elif lead == "grep" and any(w.startswith("-") and "q" in w for w in ws[1:3]):
            test = self.prop(seg)
        return self.act(seg), test, op, k + 1

    def chain(self, segs, k):
        text, test, op, k = self.unit(segs, k)
        ok = lambda j: j < len(segs) and segs[j][0] != "pat" and bool(segs[j][0]["words"])
        if test is not None and op in ("&&", "||") and ok(k):
            then, _, op2, k = self.unit(segs, k)
            if op == "||":
                fatal = then.startswith(("stops the script", "leaves the function", "ends the script", "logs the error", "logs the warning", "checks that", "makes sure")) or " and " in test or " or " in test
                text = ("makes sure that %s; if not, %s" % (test, then)) if fatal else ("if %s, %s" % (self.negate(test), then))
            else:
                text = "if %s, %s" % (test, then)
            op = op2
        while op in ("&&", "||") and ok(k):
            then, _, op2, k = self.unit(segs, k)
            text += ("; if that works, " if op == "&&" else "; if that fails, ") + then
            op = op2
        if op == "&":
            text += ", in the background (the script goes on without waiting)"
        return text, k

    def short(self, seg):
        ws = [w for w in seg["words"] if not SH.ASSIGN.match(w)]
        if not ws:
            return "nothing"
        n = unquote(ws[0])
        d = ""
        if n in GB.COMMANDS:
            d = GB.COMMANDS[n][1]
        elif n in self.sc.funcs:
            d = self.fdesc(n)
        return code(" ".join(ws), 50) + ((" (" + short_desc(d) + ")") if d else "") + self.redirs(seg)

    def looks_like_question(self, fname):
        b = self.sc.funcs.get(fname)
        if b is None:
            return False
        c = comments_above(self.lines, b.start)
        return bool(re.search(r"\?|^(is|has|does|can|are)\b|succeeds|true when|exit 0", c, re.I | re.M)) or bool(
            re.match(r"^(is_|has_|phase_done|step_done|pending_|.*_ready$|.*_exists$|.*_running$|.*_ours$|.*_on_target$|must_|phase_needs|phase_is|phase_still|text_has)", fname))

    def pattern(self, pat):
        p = pat.strip()
        if p.startswith("("):
            p = p[1:]
        p = p[:-1] if p.endswith(")") else p
        alts = [a.strip() for a in p.split("|")]
        if alts == ["*"]:
            return "For anything else"
        shown = []
        for a in alts:
            if a == "*":
                shown.append("anything else")
            elif a.endswith("*") and a.count("*") == 1:
                shown.append("anything starting with %s" % code(unquote(a[:-1])))
            elif a.startswith("*") and a.count("*") == 1:
                shown.append("anything ending with %s" % code(unquote(a[1:])))
            else:
                shown.append(code(unquote(a)))
        return "When it is " + " or ".join(shown)

    def block_opened(self, L, lead, i, blocks_by_start):
        kind = {"if": "if", "elif": "if", "while": "loop", "until": "loop", "for": "loop", "select": "loop", "case": "case"}[lead]
        for b in L.opens:
            if b.kind == kind:
                return b
        if lead == "elif":
            return self.block_mid(i, "elif")
        for b in blocks_by_start.get(i, []):
            if b.kind == kind:
                return b
        return None

    def block_mid(self, i, word):
        for b in self.sc.reader.blocks:
            for (ln, w) in b.mids:
                if ln == i and w == word:
                    return b
        return None

    def inline_body(self, segs, j):
        """The rest of a one-line if / for / while: '; then a; b; else c; fi'."""
        if not (j < len(segs) and segs[j][0] != "pat" and segs[j][0]["words"][:1] in (["then"], ["do"]) and len(segs[j][0]["words"]) > 1):
            return None
        L2 = list(segs[j:])
        L2[0] = (dict(L2[0][0], words=L2[0][0]["words"][1:]), L2[0][1])
        out, n, joiner = "", 0, ""
        while n < len(L2):
            seg, op = L2[n]
            if seg == "pat":
                break
            ws = seg["words"]
            if not ws:
                n += 1
                continue
            if ws[0] in ("fi", "done"):
                break
            if ws[0] == "else":
                out += "; otherwise, "
                joiner = ""
                if len(ws) == 1:
                    n += 1
                    continue
                L2[n] = (dict(seg, words=ws[1:]), op)
                continue
            if ws[0] == "elif":
                out += "; otherwise, if %s, " % self.prop(dict(seg, words=ws[1:]))
                joiner = ""
                n += 1
                continue
            if ws[0] in ("then", "do"):
                if len(ws) == 1:
                    n += 1
                    continue
                L2[n] = (dict(seg, words=ws[1:]), op)
                continue
            phrase, n = self.chain(L2, n)
            out += joiner + phrase
            joiner = ", then "
        return out + "."

    def then_tail(self, segs, k, b):
        body = self.inline_body(segs, k + 1)
        if body:
            return body
        nxt = self.next_mid(b, segs and segs[0][0] != "pat" and segs[0][0]["line"])
        if b is not None and b.end is not None and nxt is not None:
            return "the lines below run (up to line %d)." % (nxt + 1)
        return "the lines below run."

    def next_mid(self, b, line):
        if b is None:
            return None
        cands = [ln for ln, w in b.mids if w in ("else", "elif") and ln > line]
        return min(cands) - 1 if cands else b.end - 1 if b.end is not None else None

    def skip_then(self, segs, k):
        k += 1
        while k < len(segs) and segs[k][0] != "pat" and segs[k][0]["words"][:1] in (["then"], ["do"]):
            ws = segs[k][0]["words"]
            if len(ws) > 1:
                # the rest of a one-line if: skip to the end of the line
                return len(segs)
            k += 1
        return k

    def for_loop(self, ws, i, L, blocks_by_start, segs, k):
        b = self.block_opened(L, "for", i, blocks_by_start)
        end = " (up to line %d)" % (b.end + 1) if b and b.end is not None else ""
        if len(ws) > 1 and ws[1].startswith("(("):
            inner = ws[1][2:-2]
            parts = [p.strip() for p in inner.split(";")]
            return "Counts with %s from %s while %s, stepping %s each time; the lines below run once per step%s." % (
                code(re.split(r"\s*=", parts[0])[0] if parts else "i"), code(parts[0]) if parts else "", code(parts[1]) if len(parts) > 1 else "", code(parts[2]) if len(parts) > 2 else "", end)
        var = ws[1] if len(ws) > 1 else "x"
        if "in" in ws:
            items = ws[ws.index("in") + 1:]
            items = [w for w in items if w not in ("do", ";")]
            if len(items) == 1:
                w = items[0]
                m = re.match(r'^\$\{([A-Za-z_][A-Za-z0-9_]*)\[@\]\+"\$\{\1\[@\]\}"\}$', w) or re.match(r'^"?\$\{([A-Za-z_][A-Za-z0-9_]*)\[@\]\}"?$', w)
                mk = re.match(r'^"?\$\{!([A-Za-z_][A-Za-z0-9_]*)\[@\]\}"?$', w)
                if mk:
                    what = "key of the dictionary %s" % code(mk.group(1))
                elif m:
                    what = "item of the list %s" % code(m.group(1))
                    if "+" in w:
                        what += " (written this way so an empty list is safe with set -u)"
                elif "$(" in w:
                    what = "word in the output of %s" % code(w.strip('"')[2:-1], 60)
                else:
                    what = "item of %s" % self.show(w)
            else:
                what = "of " + ", ".join(self.show(x) for x in items[:5]) + (", …" if len(items) > 5 else "")
                what = "value " + what
        else:
            what = "argument"
        body = self.inline_body(segs, k + 1)
        if body:
            return "For each %s, with %s set to it: %s" % (what, code("$" + var), body)
        return "For each %s, the lines below run%s with %s set to it." % (what, end, code("$" + var))

    def keyword_alone(self, w, i):
        if w == "then":
            return "Starts the lines that run when the test above is true."
        if w == "do":
            return "Starts the body of the loop: the lines that repeat."
        if w == "{":
            return "Opens a block of commands; it ends at the matching }."
        b = self.block_mid(i, "else")
        if b is not None:
            nxt = [ln for ln, ww in b.mids if ww in ("else", "elif") and ln > i]
            end = (min(nxt) if nxt else b.end)
            return "Otherwise (when the test on line %d was false), the lines below run, up to line %d." % (b.start + 1, end)
        return "Otherwise, the lines below run."

    def closer(self, w, i, seg):
        L = self.sc.reader.out.get(i)
        b = None
        for x in (L.closes if L else []):
            if {"fi": "if", "done": "loop", "esac": "case", "}": None}[w] in (x.kind, None) and (w != "}" or x.kind in ("func", "group")):
                b = x
                break
        start = (" that starts on line %d" % (b.start + 1)) if b else ""
        if w == "fi":
            return "End of the if%s." % start
        if w == "esac":
            return "End of the case%s." % start
        if w == "done":
            r = self.redirs(seg)
            if r.startswith(", reading its input from"):
                return "End of the loop%s. The loop%s, one line per pass." % (start, r.replace(", reading", " reads", 1).replace("its input", "its lines", 1))
            return "End of the loop%s%s." % (start, r)
        if b is not None and b.kind == "func":
            return "End of the function %s%s." % (code(b.name), start)
        return "End of the { } block%s." % start


def self_line(ex):
    return ex.cur_line


NEG_UNARY = {"-z": "{a} is not empty", "-n": "{a} is empty", "-f": "{a} is not an existing file", "-d": "{a} is not an existing folder",
             "-e": "{a} does not exist", "-s": "{a} is missing or empty", "-x": "{a} cannot be run", "-r": "{a} cannot be read",
             "-t": "file descriptor {a} is not a terminal", "-v": "the variable {a} is not set", "-L": "{a} is not a symbolic link"}
NEG_PHRASES = [(" is on (not 0)", " is off (0)"), (" is off (0)", " is on (not 0)"), (" has items", " is empty"),
               (" exists and can be run", " is missing or cannot be run"), (" does not have ", " has "), (" has ", " does not have "),
               (" matches the regex", " does not match the regex"), (" equals ", " does not equal "),
               (" starts with ", " does not start with "), (" ends with ", " does not end with "),(" is not empty", " is empty"), (" is empty", " is not empty"), (" succeeds", " fails"), (" finds a match", " finds nothing"),
               (" is a file that exists", " is not an existing file"), (" is a folder that exists", " is not an existing folder"),
               (" exists", " does not exist"), (" contains ", " does not contain "), (" is not ", " is "), (" is ", " is not ")]


def explain_script(idx, sc, blocks_by_start):
    ex = Explainer(idx, sc)
    plain = idx.files[sc.path]["plain"]
    out = sc.reader.out
    groups = {}
    for i in sorted(out):
        L = out[i]
        if L.body_of is not None:
            continue
        start = L.cont_of if L.cont_of is not None else i
        groups.setdefault(start, []).append(i)
    for start, lines in groups.items():
        items = []
        for i in lines:
            items.extend(out[i].items)
        ex.cur_line = start
        L0 = out[start]
        sents = []
        try:
            if L0.funcdef is not None:
                sents.extend(func_def_sentences(ex, sc, start))
            if L0.funcdef is not None and items and items[0][:2] == ("w", "{"):
                items = items[1:]
                if items and items[-1][:2] == ("w", "}"):
                    items = items[:-1]
            if items:
                body = ex.explain(start, items, L0, blocks_by_start)
                if L0.funcdef is not None and body and body[0].startswith("Opens a block"):
                    body = body[1:]
                sents.extend(body)
        except Exception as e:  # an explanation must never break the build
            sents.append("(No plain-words reading for this line: %s)" % e.__class__.__name__)
        fb = sc.func_at(start)
        if fb is not None and L0.funcdef is None and sents and lines[-1] + 1 == fb.end and sents[-1].startswith(("Checks that", "If ", "Makes sure")):
            sents.append("It is the last command of %s(), so its result (success or failure) is what %s() returns." % (fb.name, fb.name))
        for i in lines:
            t = sc.lines[i].strip()
            s = list(sents)
            if i != start:
                s = ["This continues the command that starts on line %d:" % (start + 1)] + s
            if t.startswith("#") and not s:
                s = [comment_sentence(sc, i)]
            elif out[i].comment is not None and t and not t.startswith("#"):
                s.append("The text after # is a comment for the reader.")
            if out[i].in_string and i == start and not items:
                s = ["This line is part of a quoted text that started on an earlier line."]
            if s:
                plain[i] = s
    for inner in sc.inner:
        explain_script(idx, inner, {b.start: [b] for b in inner.reader.blocks})
    # here-document bodies
    for reg in sc.reader.heredoc_regions:
        feeder = reg["cmd"] or "the command"
        for i in range(reg["first"], reg["last"] + 1):
            mvar = re.match(r"^\s*(?:local\s+|readonly\s+)?([A-Za-z_][A-Za-z0-9_]*)=\$\(\s*cat\s+<<", sc.lines[reg["start"]])
            if reg["quoted"] and mvar:
                v = mvar.group(1)
                if i == reg["first"]:
                    pre = "This is the first line of a script (lines %d to %d) that is kept as text in the variable %s (line %d): %s copies the lines exactly as written. It does not run here; it is sent to a node later, wherever %s is used. Its variables are its own, and its %s, %s, ... are the words passed to it there." % (
                        reg["first"] + 1, reg["last"] + 1, code(v), reg["start"] + 1, code("cat <<'" + reg["delim"] + "'"), code("$" + v), code("$1"), code("$2"))
                else:
                    pre = "Part of the script kept in %s (lines %d to %d); it runs on a node, not here." % (code(v), reg["first"] + 1, reg["last"] + 1)
                plain[i] = [pre] + plain.get(i, [])
            elif reg["quoted"]:
                if i == reg["first"]:
                    pre = "This is the first line of a script (lines %d to %d) passed to %s on line %d as its input. It does not run here: it runs where that command sends it (on a node, over ssh). Its variables are its own, and its %s, %s, ... are the words after %s on line %d." % (
                        reg["first"] + 1, reg["last"] + 1, code(feeder), reg["start"] + 1, code("$1"), code("$2"), code("bash -s --"), reg["start"] + 1)
                else:
                    pre = "Part of the script (lines %d to %d) sent by %s on line %d; it runs on the node, not here." % (reg["first"] + 1, reg["last"] + 1, code(feeder), reg["start"] + 1)
                plain[i] = [pre] + plain.get(i, [])
            else:
                plain[i] = ["Part of the text (lines %d to %d) fed to %s on line %d as its input. $variables in it are filled in by this script before it is sent." % (
                    reg["first"] + 1, reg["last"] + 1, code(feeder), reg["start"] + 1)]
        if reg["end"] < len(sc.lines):
            plain[reg["end"]] = ["%s on its own line ends the here-document that starts on line %d." % (code(reg["delim"]), reg["start"] + 1)]


def func_def_sentences(ex, sc, i):
    L = sc.reader.out[i]
    name = L.funcdef[0]
    b = sc.funcs.get(name)
    if b is None or b.start != i:
        return ["Defines the function %s." % code(name)]
    calls = [c for c in ex.idx.calls if c[1] == sc.fkey(name)]
    who = ""
    if calls:
        who = " It is called from %d place%s (see “Called from” below)." % (len(calls), "s" if len(calls) > 1 else "")
    else:
        who = " Nothing in this file calls it by name."
    if b.end == i:
        return ["Defines the function %s on one line. Nothing runs yet: the commands between { and } run each time something calls %s.%s" % (code(name), code(name), who),
                "What it does:"]
    return ["Defines the function %s. Nothing runs yet: lines %d to %d run each time something calls %s.%s" % (code(name), i + 2, b.end + 1, code(name), who)]


def comment_sentence(sc, i):
    t = sc.lines[i].strip()
    if i == 0 and t.startswith("#!"):
        return "The shebang: it tells the system to run this file with %s." % code(t[2:].strip())
    body = t.lstrip("#").strip()
    if re.match(r"^-{5,}$|^={5,}$", body):
        return "A divider in the comments, marking the start or end of a section."
    if sc.path.endswith((".conf.example", ".conf")) and re.match(r"^[A-Z_][A-Z0-9_]*(\[[^]]*\])?\+?=", body):
        return "A setting that is switched off: remove the # at the start to use it."
    if re.match(r"^(shellcheck|TODO|FIXME)", body):
        if body.startswith("shellcheck"):
            return "A note for ShellCheck (a Bash checker), telling it to skip one warning here. Bash ignores it."
        return "A to-do note left in the code. Bash ignores it."
    return "A comment for the reader. Bash skips it."


# ======================================================================================
# Call chains
# ======================================================================================
def call_graph(idx):
    fwd, rev = {}, {}
    for a, b, f, l, how in idx.calls:
        if a == b:
            continue
        fwd.setdefault(a, []).append((b, f, l, how))
        rev.setdefault(b, []).append((a, f, l, how))
    return fwd, rev


def chains_to(idx, fwd, rev, roots, target, limit=5, max_len=14):
    """Shortest call paths from a root (the top of a script you run) to target."""
    from collections import deque
    dist = {}
    dq = deque()
    for r in roots:
        dist[r] = 0
        dq.append(r)
    while dq:
        n = dq.popleft()
        for b, f, l, how in fwd.get(n, []):
            if b not in dist:
                dist[b] = dist[n] + 1
                dq.append(b)
    if target not in dist or dist[target] == 0:
        return []
    out = []

    def back(node, path):
        if len(out) >= limit or len(path) > max_len:
            return
        if dist.get(node) == 0:
            out.append(list(reversed(path)))
            return
        seen_callers = set()
        for a, f, l, how in rev.get(node, []):
            if dist.get(a, 1e9) == dist[node] - 1 and (a, l) not in seen_callers:
                seen_callers.add((a, l))
                back(a, path + [[a, f, l, how]])
                if len(out) >= limit:
                    return

    back(target, [])
    return out


# ======================================================================================
def build(outputs):
    files = subprocess.check_output(["git", "ls-files"], cwd=REPO).decode().split("\n")
    idx = Index()
    for p in files:
        if not p or SKIP.search(p):
            continue
        try:
            with open(os.path.join(REPO, p), encoding="utf-8") as fh:
                text = fh.read()
        except (UnicodeDecodeError, IOError):
            continue
        lines = text.split("\n")
        if lines and lines[-1] == "":
            lines.pop()
        lang = lang_of(p)
        kind = lang
        if p.endswith((".conf.example", ".conf")):
            kind = "conf"
        idx.files[p] = {"lang": lang, "kind": kind, "lines": lines, "summary": header_summary(lines) if lang != "markdown" else "\n".join(lines[:6]),
                        "concepts": {}, "tokens": {}, "notes": {}, "tasks": [], "task_of": {}, "plain": {}, "sections": []}
    scripts = []
    for p, rec in sorted(idx.files.items()):
        if rec["lang"] == "bash":
            sc = Script(idx, p)
            scripts.append(sc)
    # configs first, so a script's defaults are the first definition... no: scripts first,
    # then configs, so "Defined" lists the default before the override.
    scripts.sort(key=lambda s: (s.path.endswith((".conf", ".example")), s.path))
    for sc in scripts:
        sc.pass1()
    by_base = {}
    for p in idx.files:
        by_base.setdefault(os.path.basename(p), p)
    for sc in scripts:
        sc.pass2(by_base)
    for p, rec in idx.files.items():
        mention_tokens(idx, p)
    uses(idx)

    # outline: functions, here-documents and comment sections
    for sc in scripts:
        rec = idx.files[sc.path]
        all_scripts = [sc] + sc.inner
        entries = []
        for s in all_scripts:
            for b in s.func_blocks:
                entries.append((b.start, b.end, b.name + "()", "function", s.fkey(b.name), comments_above(sc.lines, b.start)))
        for reg in sc.reader.heredoc_regions:
            label = "script fed to %s" % (reg["cmd"] or "a command") if reg["quoted"] else "text fed to %s" % (reg["cmd"] or "a command")
            mv = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)=\$\(\s*cat\s+<<", sc.lines[reg["start"]])
            if mv and reg["quoted"]:
                label = "script kept in %s" % mv.group(1)
            entries.append((reg["start"], reg["end"], "<<%s (%s)" % (reg["delim"], label), "heredoc", None, comments_above(sc.lines, reg["start"])))
        entries.sort(key=lambda e: (e[0], -(e[1] or e[0])))
        stack = []
        for s, e, name, kind, key, doc in entries:
            while stack and not (stack[-1]["start"] <= s <= stack[-1]["end"]):
                stack.pop()
            t = {"id": len(rec["tasks"]), "name": name, "module": kind, "start": s, "end": e if e is not None else s,
                 "parent": stack[-1]["id"] if stack else None, "depth": len(stack), "comment": doc, "kind": kind, "keys": [], "key": key}
            rec["tasks"].append(t)
            for i in range(t["start"], t["end"] + 1):
                rec["task_of"][i] = t["id"]
            stack.append(t)
        for i, ln in enumerate(sc.lines):
            if re.match(r"^# -{10,}", ln) and i + 1 < len(sc.lines) and re.match(r"^# [A-Za-z]", sc.lines[i + 1]):
                rec["sections"].append([i + 1, sc.lines[i + 1][2:].strip()])

    # explanations
    for sc in scripts:
        explain_script(idx, sc, {})
        rec = idx.files[sc.path]
        # $1 / $2 inside a function: whose arguments are they?
        for i in range(len(sc.lines)):
            L = sc.reader.out.get(i)
            if L is None or L.body_of is not None:
                continue
            c = sc.code_part(i)
            fb = sc.func_at(i)
            ps = sorted(set(re.findall(r"\$\{?([1-9])\b", c)))
            if ps and fb is not None:
                idx.note(sc.path, i, "Here %s %s the %s given to %s() when it is called (see “Called from” below for the calls)." % (
                    ", ".join("$" + p for p in ps), "is" if len(ps) == 1 else "are", "argument" if len(ps) == 1 else "arguments", fb.name))
            elif ps and fb is None and not sc.path.endswith(".example"):
                idx.note(sc.path, i, "Outside any function, %s %s the script's own command-line argument%s." % (", ".join("$" + p for p in ps), "is" if len(ps) == 1 else "are", "" if len(ps) == 1 else "s"))
            # option meanings for commands on this line
            for name, s, e, depth in L.cmds:
                if name in GB.COMMANDS and GB.COMMANDS[name][2]:
                    used = []
                    after = c[e:]
                    words = SH.split_words(re.split(r"[|;&]", after)[0]) if after else []
                    opts = GB.COMMANDS[name][2]
                    for w in words:
                        if w in opts:
                            used.append("%s %s" % (w, opts[w]))
                        elif re.match(r"^-[A-Za-z]{2,}$", w):
                            for ch in w[1:]:
                                if "-" + ch in opts:
                                    used.append("-%s %s" % (ch, opts["-" + ch]))
                        elif w.startswith("-o") and "BatchMode" in w:
                            used.append("BatchMode=yes: " + opts.get("BatchMode=yes", ""))
                    if "BatchMode=yes" in after and name == "ssh":
                        used.append("BatchMode=yes: " + opts["BatchMode=yes"])
                    used = list(dict.fromkeys(used))
                    if used:
                        idx.note(sc.path, i, "%s options here: %s." % (name, "; ".join(used)))
            # conf file: which default does this setting replace?
            if sc.path.endswith((".conf.example", ".conf")):
                for k, t, s, e in L.items:
                    m = SH.ASSIGN.match(t) if k == "w" else None
                    if m:
                        key = sc.gkey(m.group(1))
                        d = [x for x in idx.symbols.get(key, {}).get("defs", []) if x["f"] != sc.path]
                        if d:
                            idx.note(sc.path, i, "This replaces the default of %s set in %s line %d: the script sets its defaults first, then reads this file with source." % (
                                m.group(1), d[0]["f"], d[0]["l"] + 1))
                        else:
                            idx.note(sc.path, i, "%s has no default in the script: it must be set here." % m.group(1))
            elif L.items and sc.func_at(i) is None and sc.parent is None:
                for k, t, s, e in L.items[:1]:
                    m = SH.ASSIGN.match(t) if k == "w" else None
                    if m:
                        key = sc.gkey(m.group(1))
                        confs = [x for x in idx.symbols.get(key, {}).get("defs", []) if x["f"].endswith(".example")]
                        if confs:
                            idx.note(sc.path, i, "A default: %s also sets %s (line %d), and a site's config file wins over this line." % (
                                confs[0]["f"], m.group(1), confs[0]["l"] + 1))

    # call graph and chains
    fwd, rev = call_graph(idx)
    roots = ["top:" + e for e in ENTRY_POINTS if e in idx.files]
    calls_out = {}
    for key in idx.nodes:
        calls_out[key] = {
            "calls": sorted({(b, f, l, how) for b, f, l, how in fwd.get(key, [])}, key=lambda x: (x[1], x[2])),
            "callers": sorted({(a, f, l, how) for a, f, l, how in rev.get(key, [])}, key=lambda x: (x[1], x[2])),
        }
    fchains = {}
    for key in idx.nodes:
        c = chains_to(idx, fwd, rev, roots, key)
        if c:
            fchains[key] = c
    for p in idx.files:
        if "file:" + p in rev:
            c = chains_to(idx, fwd, rev, roots, "file:" + p)
            if c:
                fchains["file:" + p] = c
    for e in ENTRY_POINTS:
        k = "top:" + e
        if k in rev:
            c = []
            for a, f, l, how in rev[k]:
                c.append([[a, f, l, how]])
            fchains.setdefault(k + ":callers", c[:8])
    nodes = dict(idx.nodes)
    for p in idx.files:
        nodes["file:" + p] = {"label": os.path.basename(p), "f": p, "l": None, "kind": "file"}

    incoming = {}
    for f, l, t, how in idx.edges:
        if f != t:
            lst = incoming.setdefault(t, [])
            if [f, l, how] not in lst:
                lst.append([f, l, how])
    # where each script's work starts: the last top-level call (main "$@")
    starts = {}
    for sc in scripts:
        if sc.path in ENTRY_POINTS:
            last = None
            for a, b, f, l, how in idx.calls:
                if a == sc.top and f == sc.path:
                    last = l if last is None or l > last else last
            starts[sc.path] = last

    out_files = {}
    for p, rec in idx.files.items():
        out_files[p] = {
            "lang": rec["lang"], "kind": rec["kind"], "lines": rec["lines"], "summary": rec["summary"],
            "concepts": rec["concepts"], "tokens": rec["tokens"], "notes": rec["notes"], "tasks": rec["tasks"],
            "taskOf": rec["task_of"], "incoming": incoming.get(p, []), "plain": rec["plain"], "sections": rec["sections"],
            "start": starts.get(p),
        }
    gl = {}
    for k, rx, t, x in GB.SYNTAX:
        gl["sh:" + k] = (t, x)
    gl["sh:comment"] = ("# comment", "Everything after a # (at the start of a word) is a comment: Bash skips it. The comments in these scripts explain why each step is there.")
    for k, (t, x, opts) in GB.COMMANDS.items():
        gl["cmd:" + k] = (t, x)
    for k, (t, x) in ORACLE_TOOLS.items():
        gl["tool:" + k] = (t, x)

    rev_id = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], cwd=REPO).decode().strip()
    branch = subprocess.check_output(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=REPO).decode().strip()
    data = {
        "title": "ZDLRA code tracer: the Bash version",
        "learning": "Bash",
        "placeholder": "Find a file, function, variable or Bash concept…",
        "help": "Click any line to read what it does in plain words, the Bash idea behind it, and where it connects. Underlined words are links: a function opens where it is defined, with everything that calls it and the chain of calls from the script you run; a variable shows where it is set and everywhere it is read. Double-click a file name to open it. ↑/↓ move line by line, / searches, Back returns to where you were.",
        "groups": [["sh", "Bash syntax"], ["cmd", "Commands"], ["tool", "Oracle and site tools"]],
        "files": out_files, "symbols": idx.symbols, "glossary": gl, "chains": {},
        "nodes": nodes, "calls": calls_out, "fchains": fchains,
        "entries": [e for e in ENTRY_POINTS if e in idx.files], "rev": rev_id, "branch": branch,
    }
    with open(os.path.join(HERE, "viewer.html"), encoding="utf-8") as fh:
        viewer = fh.read()
    for path, mode in outputs:
        page = P.render(viewer, data, mode, data["title"])
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(page)
    n_links = sum(len(t) for r in idx.files.values() for t in r["tokens"].values())
    n_plain = sum(len(r["plain"]) for r in idx.files.values())
    print("Wrote %s: %d files, %d functions, %d symbols, %d links, %d explained lines, %d KB" % (
        ", ".join(os.path.relpath(p) for p, _ in outputs), len(idx.files), sum(1 for k in idx.nodes if k.startswith("func:")), len(idx.symbols),
        n_links, n_plain, len(page) // 1024))


def mention_tokens(idx, path):
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
            if len(hits) == 1 and hits[0] != path:
                idx.token(path, i, m.start(), m.end(), "file", hits[0])
                idx.edges.append((path, i, hits[0], "mention"))


def uses(idx):
    for path, rec in idx.files.items():
        for ln, toks in rec["tokens"].items():
            for s, e, kind, key in toks:
                if key in idx.symbols and (key, path, ln) not in idx.def_at:
                    u = idx.symbols[key]["uses"]
                    if not u or u[-1] != {"f": path, "l": ln}:
                        u.append({"f": path, "l": ln})


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("-o", "--output", default=os.path.join(REPO, "docs", "code-tracer-bash.html"),
                    help="the standalone page, with no Claude (default: docs/code-tracer-bash.html)")
    ap.add_argument("--trainer-output", default=os.path.join(REPO, "docs", "trainer", "code-tracer-bash.html"),
                    help="the Exadata Trainer's page, with Ask Claude (default: docs/trainer/code-tracer-bash.html; '' to skip)")
    a = ap.parse_args()
    build([(a.output, "none")] + ([(a.trainer_output, "trainer")] if a.trainer_output else []))
