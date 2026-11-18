# Filters used by the ZDLRA patching playbooks.

import re


def zdlra_kv(text):
    """KEY=VALUE lines (a staged record, patch.conf_<SR>) as a dict.

    The first line for a key wins. Carriage returns, one pair of surrounding quotes and
    trailing spaces are removed from values, as the shell scripts do.
    """
    out = {}
    for line in (text or '').splitlines():
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)=(.*)$', line)
        if not m or m.group(1) in out:
            continue
        val = m.group(2).replace('\r', '')
        val = re.sub(r'^["\']', '', val)
        val = re.sub(r'["\']$', '', val)
        out[m.group(1)] = val.rstrip()
    return out


def zdlra_image_versions(text):
    """'host: version' lines (dcli ... 'imageinfo -ver') as a dict; the first wins."""
    out = {}
    for line in (text or '').splitlines():
        m = re.match(r'^\s*([A-Za-z0-9._-]+):\s*([0-9][0-9.]*)\s*$', line)
        if m and m.group(1) not in out:
            out[m.group(1)] = m.group(2)
    return out


def zdlra_has_version(text, version):
    """Does the text show this version as a whole version? 10.2 isn't in 10.25(3)."""
    if not version:
        return False
    pat = r'(^|[^0-9A-Za-z.])' + re.escape(version) + r'([^0-9A-Za-z.]|$)'
    return re.search(pat, text or '', re.M) is not None


def zdlra_version_line(text):
    """The line worth showing from a switch's version output: NXOS/version, else the first."""
    lines = (text or '').splitlines()
    for line in lines:
        if re.search(r'nxos|version', line, re.I):
            return line.strip()
    return lines[0].strip() if lines else ''


def zdlra_lines(text):
    """Non-empty lines, trimmed (a group file)."""
    return [l.strip() for l in (text or '').splitlines() if l.strip()]


def zdlra_fill(args, values):
    """Replace {name} placeholders in each argument with values[name]."""
    out = []
    for a in args or []:
        a = str(a)
        for k, v in (values or {}).items():
            a = a.replace('{' + k + '}', str(v))
        out.append(a)
    return out


def zdlra_summary_items(summary, pattern):
    """Lines of a precheck summary matching pattern, and their names (sorted, unique).

    The name is everything after the tag, as in the script's extract_summary_items.
    """
    lines = [l for l in (summary or '').splitlines() if re.search(pattern, l)]
    names = set()
    for l in lines:
        name = re.sub(r'.*' + pattern + r'\s*', '', l, count=1)
        names.add(name.rstrip())
    return {'lines': lines, 'names': sorted(names)}


def zdlra_waived(items, waivers):
    """Items ("TAG name") whose name contains any of the waivers."""
    waivers = [w for w in (waivers or []) if w]
    return [i for i in (items or []) if any(w in i.split(' ', 1)[-1] for w in waivers)]


def zdlra_switch_results(results):
    """Loop results of the switch version commands as [{name, ok, text}]."""
    return [{'name': r.get('item'), 'ok': r.get('rc') == 0, 'text': r.get('stdout', '')}
            for r in (results or [])]


def zdlra_row(component, name, now, target, on_target, soft=False):
    """One row of the version table, with its result:
    UNREAD (no version), NO TARGET, OK, CHECK (off target, a warning) or MISMATCH (fails).
    """
    if not now:
        result = 'UNREAD'
    elif not target:
        result = 'NO TARGET'
    elif on_target:
        result = 'OK'
    elif soft:
        result = 'CHECK'
    else:
        result = 'MISMATCH'
    return {'component': component, 'name': name, 'now': now or '?',
            'target': target or '<not set>', 'result': result}


def zdlra_table(rows):
    """The version table as text, as zdlra_patch.sh writes versions.txt."""
    fmt = '%-9s %-20s %-34s %-24s %s'
    lines = [fmt % ('COMPONENT', 'NAME', 'VERSION NOW', 'TARGET', 'RESULT')]
    for r in rows or []:
        lines.append(fmt % (r['component'], r['name'], r['now'], r['target'], r['result']))
    return '\n'.join(lines) + '\n'


class FilterModule(object):
    def filters(self):
        return {
            'zdlra_kv': zdlra_kv,
            'zdlra_image_versions': zdlra_image_versions,
            'zdlra_has_version': zdlra_has_version,
            'zdlra_version_line': zdlra_version_line,
            'zdlra_lines': zdlra_lines,
            'zdlra_fill': zdlra_fill,
            'zdlra_summary_items': zdlra_summary_items,
            'zdlra_waived': zdlra_waived,
            'zdlra_switch_results': zdlra_switch_results,
            'zdlra_row': zdlra_row,
            'zdlra_table': zdlra_table,
        }
