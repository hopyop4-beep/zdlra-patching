# Tests used by the ZDLRA patching playbooks.

import re


def zdlra_has_version(text, version):
    """Does the text show this version as a whole version? 10.2 isn't in 10.25(3)."""
    if not version:
        return False
    pat = r'(^|[^0-9A-Za-z.])' + re.escape(version) + r'([^0-9A-Za-z.]|$)'
    return re.search(pat, text or '', re.M) is not None


class TestModule(object):
    def tests(self):
        return {'zdlra_has_version': zdlra_has_version}
