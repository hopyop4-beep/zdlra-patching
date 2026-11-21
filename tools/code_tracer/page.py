"""Writes the tracer page(s): viewer.html with the data put in, in one of two builds.

  "none"     the standalone page (docs/code-tracer*.html): no Claude at all. The code between the ASK-BEGIN and
             ASK-END markers in viewer.html is left out.
  "trainer"  the page for the Exadata Trainer's Code tracer tab (docs/trainer/): an "Ask Claude about this line" chat
             that asks through the trainer's own server. It only works when the trainer serves it.
"""
import json
import re

ASK_JS = re.compile(r"/\*ASK-BEGIN\*/.*?/\*ASK-END\*/\n?", re.S)
NO_ASK = 'function askBox() { return ""; }\nfunction wireAsk() {}\n'


def render(viewer, data, mode, title=None):
    if mode not in ("none", "trainer"):
        raise ValueError(mode)
    data = dict(data, ask=mode)
    page = viewer
    if mode == "none":
        style_end = page.index("</style>")
        page = ASK_JS.sub("", page[:style_end]) + ASK_JS.sub(NO_ASK, page[style_end:], count=1)
        if "ASK-BEGIN" in page:
            raise SystemExit("viewer.html: more than one ASK-BEGIN block in the script")
    else:
        page = page.replace("/*ASK-BEGIN*/\n", "").replace("/*ASK-END*/\n", "").replace("/*ASK-BEGIN*/", "").replace("/*ASK-END*/", "")
    if title:
        page = page.replace("<title>ZDLRA code tracer</title>", "<title>%s</title>" % title)
    blob = json.dumps(data, separators=(",", ":"), ensure_ascii=False).replace("</", "<\\/")
    return page.replace("/*__DATA__*/null", blob)
