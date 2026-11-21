"""A small Bash reader for the code tracer.

It is not a full Bash parser. It reads a script line by line and works out what a reader
needs: which words are commands (so a function call can be linked to its definition),
where if / for / while / case / { ... } blocks start and end, here-documents, quoted
strings that span lines, and the top-level shape of each command line (its words and the
;, &&, ||, | between them), which the explainer turns into plain sentences.
"""

import re

NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)(\[[^\]]*\])?(\+?=)")
FUNC_DEF = re.compile(r"^(\s*)(?:function\s+)?([A-Za-z_][A-Za-z0-9_:.-]*)\s*\(\)\s*")
FUNC_KW = re.compile(r"^(\s*)function\s+([A-Za-z_][A-Za-z0-9_:.-]*)\s*(?:\(\))?\s*")

# After these words the next word is again a command.
CMD_PREFIX = {"if", "then", "else", "elif", "do", "while", "until", "!", "{", "time", "exec", "command", "builtin", "nohup", "setsid", "sudo", "env", "eval", "timeout"}
# Reserved words that end something; what follows is not a command (only redirects or ;).
CLOSERS = {"fi", "done", "esac", "}"}
OPERATORS = ["<<<", "<<-", ";;&", "&>>", "<<", ">>", "&&", "||", ";;", ";&", "|&", ">&", "<&", "&>", ">|", "<>", "|", "&", ";", "<", ">", "(", ")"]


class Block(object):
    __slots__ = ("kind", "start", "end", "mids", "name", "words")

    def __init__(self, kind, start, name=None, words=None):
        self.kind, self.start, self.end, self.mids, self.name, self.words = kind, start, None, [], name, words or []


class Line(object):
    """What the reader found on one physical line."""

    def __init__(self, i):
        self.i = i
        self.items = []      # base-level items: ("w", text, s, e) / ("op", text, s, e) / ("pat", text, s, e)
        self.cmds = []       # command-position words: (name, s, e, depth)
        self.vars = []       # variable uses: (name, s, e)
        self.arith = []      # bare names inside (( )) / $(( )): (name, s, e)
        self.comment = None  # column where a # comment starts
        self.funcdef = None  # (name, s, e) when the line defines a function
        self.opens = []      # blocks opened on this line
        self.closes = []     # blocks closed on this line
        self.mids = []       # (block, word) for else / elif / then / do on this line
        self.heredocs = []   # (delimiter, quoted, cmd) started on this line
        self.cont_of = None  # first line of the logical line, when this continues an earlier one
        self.body_of = None  # here-document this line belongs to: dict
        self.in_string = False   # the line starts inside a quoted string


CMD_FRAMES = ("cmd", "sub", "bq", "dbr")


class Frame(object):
    __slots__ = ("t", "at", "depth", "parens", "ws", "last", "carry", "wline", "wcol")

    def __init__(self, t, at=False, depth=0):
        self.t, self.at, self.depth, self.parens, self.ws, self.last, self.carry = t, at, depth, 0, None, None, ""
        self.wline, self.wcol = None, None


class Reader(object):
    def __init__(self, lines, first=0, last=None):
        self.lines = lines
        self.first = first
        self.last = len(lines) if last is None else last
        self.out = {}
        self.blocks = []
        self.bstack = []
        self.heredoc_regions = []    # dicts: start (the << line), body (first, last), delim, quoted, cmd
        self.case_frame = None
        self.prev_text = ""
        self.func_open_for = None
        self.pending_hd = []

    # ------------------------------------------------------------------------------------
    def read(self):
        stack = [Frame("cmd", True, 0)]
        logical_start = None
        pending_func = None
        i = self.first
        while i < self.last:
            text = self.lines[i]
            L = self.out[i] = Line(i)
            L.in_string = stack[-1].t in ("sq", "dq")
            if logical_start is not None:
                L.cont_of = logical_start
            base = stack[-1].t == "cmd" and len(stack) == 1
            start_col = 0
            if base and logical_start is None:
                m = FUNC_DEF.match(text) or FUNC_KW.match(text)
                if m and not text.lstrip().startswith("#"):
                    name = m.group(2)
                    s = text.index(name, len(m.group(1)))
                    L.funcdef = (name, s, s + len(name))
                    start_col = m.end()
                    pending_func = (name, i)
                    stack[0].at = True
            self.pending_hd = []
            cont = self.scan(text, i, stack, start_col, L, pending_func)
            if L.funcdef is None and pending_func and any(b.kind == "func" for b in L.opens):
                pending_func = None
            if L.funcdef is not None:
                if any(b.kind == "func" for b in L.opens):
                    pending_func = None
            # logical line bookkeeping
            if cont or len(stack) > 1 or stack[-1].t != "cmd":
                if logical_start is None:
                    logical_start = i
            else:
                logical_start = None
                stack[0].at = True
            if self.pending_hd:
                # The here-document bodies follow this line, one after another.
                j = i + 1
                for delim, quoted, strip, cmd in self.pending_hd:
                    body_first = j
                    while j < self.last:
                        t = self.lines[j]
                        if (t.lstrip("\t") if strip else t) == delim:
                            break
                        j += 1
                    region = {"start": i, "first": body_first, "last": j - 1, "end": j, "delim": delim,
                              "quoted": quoted, "cmd": cmd}
                    self.heredoc_regions.append(region)
                    for k in range(body_first, min(j + 1, self.last)):
                        BL = self.out[k] = Line(k)
                        BL.body_of = region
                    j += 1
                i = j
                continue
            i += 1
        for b in self.bstack:
            b.end = self.last - 1
            self.blocks.append(b)
        return self

    # ------------------------------------------------------------------------------------
    def open_block(self, kind, i, L, name=None, words=None):
        b = Block(kind, i, name, words)
        self.bstack.append(b)
        L.opens.append(b)
        return b

    def close_block(self, kinds, i, L):
        for k in range(len(self.bstack) - 1, -1, -1):
            if self.bstack[k].kind in kinds:
                b = self.bstack.pop(k)
                b.end = i
                self.blocks.append(b)
                L.closes.append(b)
                # anything opened inside and never closed (a reader mistake) closes here too
                while len(self.bstack) > k:
                    x = self.bstack.pop()
                    x.end = i
                    self.blocks.append(x)
                return b
        return None

    def innermost(self, kinds):
        for b in reversed(self.bstack):
            if b.kind in kinds:
                return b
        return None

    # ------------------------------------------------------------------------------------
    def scan(self, text, i, stack, col, L, pending_func):
        """Scan one physical line. Returns True when it ends with a backslash (continues)."""
        n = len(text)
        j = col
        expect = {"heredoc": None, "redirect": False}
        base = stack[0]
        prev = self.prev_text
        for fr in stack:
            if fr.t in CMD_FRAMES and fr.ws is not None:
                fr.carry += prev[fr.ws:] + "\n"     # a word carried over from the line before
                fr.ws = 0

        def start_word(f, k):
            if f.ws is None:
                f.ws = k
                f.wline, f.wcol = i, k

        def end_word(f, upto):
            if f.ws is None:
                return
            ws, f.ws = f.ws, None
            w = text[ws:upto]
            full, f.carry = f.carry + w, ""
            if f is base:
                if f.wline is not None and f.wline != i and f.wline in self.out:
                    # a word that started on an earlier line belongs to that line
                    self.out[f.wline].items.append(("w", full, f.wcol, f.wcol + len(full.split("\n")[0])))
                else:
                    L.items.append(("w", w, ws, upto))
            self.word_done(full, ws, upto, f, i, L, expect, pending_func)

        def push(f, t, at=False, depth=None):
            if f.t in CMD_FRAMES:
                start_word(f, j)
            stack.append(Frame(t, at, f.depth if depth is None else depth))

        while j < n:
            f = stack[-1]
            c = text[j]
            if f.t == "sq":
                k = text.find("'", j)
                if k < 0:
                    j = n
                    break
                stack.pop()
                j = k + 1
                continue
            if f.t in ("dq", "brace"):
                if c == "\\":
                    j += 2
                    continue
                if f.t == "dq" and c == '"':
                    stack.pop()
                    j += 1
                    continue
                if f.t == "brace":
                    if c == "}":
                        stack.pop()
                        j += 1
                        continue
                    if c == "'":
                        push(f, "sq")
                        j += 1
                        continue
                    if c == '"':
                        push(f, "dq")
                        j += 1
                        continue
                if c == "$":
                    j = self.dollar(text, j, stack, L, f.depth)
                    continue
                if c == "`":
                    push(f, "bq", True, f.depth + 1)
                    j += 1
                    continue
                j += 1
                continue
            if f.t == "arith":
                if text.startswith("))", j) and f.parens == 0:
                    stack.pop()
                    j += 2
                    continue
                if c == "(":
                    f.parens += 1
                elif c == ")":
                    f.parens -= 1
                elif c == "$":
                    j = self.dollar(text, j, stack, L, f.depth)
                    continue
                elif c == '"':
                    push(f, "dq")
                elif c == "'":
                    push(f, "sq")
                else:
                    m = NAME.match(text, j)
                    if m and (j == 0 or not (text[j - 1].isalnum() or text[j - 1] in "_#$")):
                        L.arith.append((m.group(0), j, m.end()))
                        j = m.end()
                        continue
                j += 1
                continue
            if f.t == "arr":
                if c == ")":
                    stack.pop()
                    j += 1
                    continue
                if c == "#" and text[j - 1] in " \t(":
                    L.comment = j
                    j = n
                    break
                if c == "'":
                    push(f, "sq")
                elif c == '"':
                    push(f, "dq")
                elif c == "$":
                    j = self.dollar(text, j, stack, L, f.depth)
                    continue
                elif c == "\\":
                    j += 2
                    continue
                j += 1
                continue

            # ---- a command frame: cmd (the line), sub ($( ) or <( )), bq (backticks), dbr ([[ ]]) ----
            if c in " \t":
                end_word(f, j)
                j += 1
                continue
            # case patterns: the words up to the closing )
            if f is base and f.at and f.ws is None and self.bstack:
                b = self.bstack[-1]
                if b.kind == "case" and b.words == ["<pattern>"] and not re.match(r"esac\b", text[j:]):
                    k = self.pattern_end(text, j)
                    if k is not None:
                        L.items.append(("pat", text[j:k + 1], j, k + 1))
                        b.words = []
                        f.at = True
                        j = k + 1
                        continue
            if c == "\\":
                if j == n - 1:
                    end_word(f, j)
                    self.prev_text = text
                    return True
                start_word(f, j)
                j += 2
                continue
            if c == "#" and f.ws is None:
                L.comment = j
                break
            if f.t == "bq" and c == "`":
                end_word(f, j)
                stack.pop()
                j += 1
                continue
            if f.t == "dbr":
                if text.startswith("]]", j) and f.ws is None and (j + 2 >= n or text[j + 2] in " \t;)&|"):
                    stack.pop()
                    j += 2
                    continue
                if c == "'":
                    push(f, "sq")
                elif c == '"':
                    push(f, "dq")
                elif c == "$":
                    start_word(f, j)
                    j = self.dollar(text, j, stack, L, f.depth)
                    continue
                elif c not in " \t":
                    start_word(f, j)
                j += 1
                continue
            op = None
            for o in OPERATORS:
                if text.startswith(o, j):
                    op = o
                    break
            if op == "(" and f.ws is not None and ASSIGN.match(text[f.ws:j]) and text[f.ws:j].endswith("="):
                push(f, "arr")
                j += 1
                continue
            if op in ("<", ">") and text.startswith(op + "(", j):
                expect["redirect"] = False      # the <( ... ) itself is what is redirected from
                push(f, "sub", True, f.depth + 1)
                j += 2
                continue
            if op == "(" and text.startswith("((", j) and f.ws is None and (f.at or f.last == "for"):
                push(f, "arith")
                f.at = False
                j += 2
                continue
            if op is not None:
                if op[0] in "<>" and f.ws is not None and text[f.ws:j].isdigit() and f.wline == i:
                    op_s, f.ws = f.ws, None      # 2> : the fd number belongs to the redirect
                else:
                    end_word(f, j)
                    op_s = j
                if op == ")" and f.t == "sub":
                    if f.parens == 0:
                        stack.pop()
                        j += 1
                        continue
                    f.parens -= 1
                elif op == "(" and f.t == "sub":
                    f.parens += 1
                if f is base:
                    L.items.append(("op", text[op_s:j + len(op)], op_s, j + len(op)))
                j += len(op)
                if op in (";", "&&", "||", "|", "&", "|&", "(", ")", ";;", ";&", ";;&"):
                    f.at = True
                    f.last = op
                    if op in (";;", ";&", ";;&"):
                        b = self.innermost(("case",))
                        if b is not None:
                            b.words = ["<pattern>"]
                elif op in ("<<", "<<-"):
                    expect["heredoc"] = op
                elif op != "<<<" or True:
                    expect["redirect"] = op != "<<<"
                continue
            if c == "'":
                push(f, "sq")
                j += 1
                continue
            if c == '"':
                push(f, "dq")
                j += 1
                continue
            if c == "`":
                push(f, "bq", True, f.depth + 1)
                j += 1
                continue
            if c == "$":
                start_word(f, j)
                j = self.dollar(text, j, stack, L, f.depth)
                continue
            if f.ws is None and f.at and text.startswith("[[", j) and (j + 2 >= n or text[j + 2] in " \t"):
                push(f, "dbr")
                j += 2
                continue
            start_word(f, j)
            j += 1
        # end of the line
        self.prev_text = text
        f = stack[-1]
        if f.t in CMD_FRAMES and f.t != "dbr":
            end_word(f, n if L.comment is None else L.comment)
        return False

    # ------------------------------------------------------------------------------------
    def pattern_end(self, text, j):
        """Index of the ) that closes a case pattern starting at j, or None."""
        k = j
        n = len(text)
        if k < n and text[k] == "(":
            k += 1
        q = None
        while k < n:
            c = text[k]
            if q:
                if c == q:
                    q = None
            elif c in "'\"":
                q = c
            elif c == "\\":
                k += 1
            elif c == ")":
                return k
            elif c in " \t" and text[j:k].strip() and not text[k:].lstrip().startswith(("|", ")")):
                if not re.match(r"\s*[|)]", text[k:]):
                    return None
            elif c == "$" and text.startswith("$(", k):
                return None
            k += 1
        return None

    def dollar(self, text, j, stack, L, depth):
        """Read a $ expansion starting at j; return the index after it (or after its opener)."""
        if text.startswith("$((", j):
            stack.append(Frame("arith", False, depth))
            return j + 3
        if text.startswith("$(", j):
            stack.append(Frame("sub", True, depth + 1))
            return j + 2
        if text.startswith("${", j):
            m = re.compile(r"\$\{[#!]?([A-Za-z_][A-Za-z0-9_]*)").match(text, j)
            if m:
                L.vars.append((m.group(1), j, m.end()))
            stack.append(Frame("brace", False, depth))
            return j + 2
        m = NAME.match(text, j + 1)
        if m:
            L.vars.append((m.group(0), j, m.end()))
            return m.end()
        if j + 1 < len(text) and (text[j + 1].isdigit() or text[j + 1] in "?#@*$!-"):
            return j + 2
        return j + 1

    # ------------------------------------------------------------------------------------
    def word_done(self, w, s, e, f, i, L, expect, pending_func):
        if expect["heredoc"]:
            strip = expect["heredoc"] == "<<-"
            expect["heredoc"] = None
            quoted = any(q in w for q in "'\"\\")
            delim = w.replace("'", "").replace('"', "").replace("\\", "")
            cmd = L.cmds[-1][0] if L.cmds else None
            self.pending_hd.append((delim, quoted, strip, cmd))
            L.heredocs.append((delim, quoted, cmd))
            return
        if expect["redirect"]:
            expect["redirect"] = False
            return
        if f.t not in ("cmd", "sub", "bq"):
            return
        last, f.last = f.last, w
        if w.startswith(("<(", ">(")):
            return
        if f.at and w.startswith("-") and last in ("command", "exec", "nohup", "setsid", "sudo", "env", "timeout", "builtin"):
            f.last = last
            return
        if w.startswith(("[[", "((")):
            f.at = False
            return
        if not f.at:
            if w == "in" and self.bstack and self.bstack[-1].kind == "case" and self.bstack[-1].words == ["<word>"] and f is self.case_frame:
                self.bstack[-1].words = ["<pattern>"]
                f.at = True
            elif w == "do" and self.bstack and self.bstack[-1].kind == "loop":
                L.mids.append((self.bstack[-1], "do"))
                f.at = True
            return
        if ASSIGN.match(w):
            return  # NAME=value before a command (or alone): the next word is still a command
        if w in ("then", "do", "else", "elif"):
            b = self.innermost(("if",)) if w != "do" else self.innermost(("loop",))
            if b is not None:
                b.mids.append((i, w))
                L.mids.append((b, w))
            return
        if w in ("if", "while", "until", "for", "select", "case", "{"):
            if w == "if":
                self.open_block("if", i, L)
            elif w in ("while", "until", "for", "select"):
                self.open_block("loop", i, L, w)
            elif w == "case":
                self.open_block("case", i, L, None, ["<word>"])
                self.case_frame = f
            elif w == "{":
                if pending_func and self.func_open_for != pending_func:
                    self.func_open_for = pending_func
                    self.open_block("func", pending_func[1], L, pending_func[0])
                else:
                    self.open_block("group", i, L)
            f.at = w in ("if", "while", "until", "{")
            return
        if w in CLOSERS:
            kind = {"fi": ("if",), "done": ("loop",), "esac": ("case",), "}": ("func", "group")}[w]
            self.close_block(kind, i, L)
            f.at = False
            return
        if w in CMD_PREFIX:
            return
        if w == "function":
            return
        name = w
        if len(name) >= 2 and name[0] == name[-1] and name[0] in "'\"":
            name = name[1:-1]
        L.cmds.append((name, s, e, f.depth))
        f.at = False


def read(lines, first=0, last=None):
    return Reader(lines, first, last).read()


def split_words(text):
    """Split a [[ ... ]] or argument string into words, keeping quotes together."""
    out, cur, q, k, depth = [], "", None, 0, 0
    while k < len(text):
        c = text[k]
        if q:
            cur += c
            if c == q:
                q = None
            elif c == "\\" and q == '"' and k + 1 < len(text):
                cur += text[k + 1]
                k += 1
        elif c in "'\"":
            q = c
            cur += c
        elif c == "\\" and k + 1 < len(text):
            cur += text[k:k + 2]
            k += 1
        elif c in "({":
            depth += 1
            cur += c
        elif c in ")}":
            depth -= 1
            cur += c
        elif c in " \t" and depth <= 0:
            if cur:
                out.append(cur)
            cur = ""
        else:
            cur += c
        k += 1
    if cur:
        out.append(cur)
    return out
