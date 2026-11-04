#!/usr/bin/env python3
"""Split the START-HERE guide (one big HTML page) into small Markdown files, one per chapter and one per
app, so the desktop search (KRunner / Baloo on KDE, Catfish on Xfce) finds the right page when you type
"printer", "VPN" or "Steam" into the app launcher.

    guide2md.py GUIDE.html OUT_FOLDER [--link-base file:///usr/share/secure-linux/START-HERE.html]

Only files this script wrote before (listed in OUT_FOLDER/.generated) are replaced or removed; anything
else in the folder is left alone. Standard library only.
"""
import html.parser
import os
import re
import sys

SKIP_TAGS = {"script", "style", "nav", "button", "input", "svg", "head", "noscript", "header"}
SKIP_CLASSES = {"badges", "hi", "aicon", "badge", "qi"}
VOID = {"br", "img", "hr", "meta", "link", "input", "source", "wbr"}
BLOCKS = {"p", "div", "li", "h1", "h2", "h3", "h4", "summary", "pre", "tr", "dt", "dd", "details", "table", "ul", "ol"}


class Doc:
    def __init__(self, kind, ident):
        self.kind = kind          # "chapter" or "app"
        self.ident = ident
        self.title = ""
        self.lines = []
        self.cur = []
        self.prefix = ""

    def text(self, t):
        self.cur.append(t)

    def flush(self):
        line = re.sub(r"[ \t\r\n]+", " ", "".join(self.cur)).strip()
        if line:
            self.lines.append(self.prefix + line)
        self.cur = []
        self.prefix = ""


class GuideParser(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.docs = []
        self.stack = []        # (tag, opened_doc, skipping)
        self.doc_stack = []
        self.skip_depth = 0
        self.title_mode = None
        self.list_stack = []
        self.href = None
        self.link_text = []
        self.in_pre = False

    @property
    def doc(self):
        return self.doc_stack[-1] if self.doc_stack else None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        classes = set((a.get("class") or "").split())
        if tag in VOID:
            if tag == "br" and self.doc and not self.skip_depth:
                self.doc.text(" ")
            return
        opened = False
        skipping = False
        if self.skip_depth or tag in SKIP_TAGS or classes & SKIP_CLASSES:
            self.skip_depth += 1
            skipping = True
        elif tag == "section" and "chapter" in classes:
            self.doc_stack.append(Doc("chapter", a.get("id", "")))
            opened = True
        elif tag == "article" and "app" in classes:
            self.doc_stack.append(Doc("app", a.get("id", "")))
            opened = True
        self.stack.append((tag, opened, skipping))
        d = self.doc
        if skipping or d is None:
            return
        if tag in BLOCKS:
            d.flush()
        if tag in ("h2", "h3", "h4") and not d.title and (tag == "h2" if d.kind == "chapter" else tag == "h3"):
            self.title_mode = tag
        elif tag in ("h2", "h3", "h4", "summary"):
            d.prefix = {"h2": "## ", "h3": "### ", "h4": "#### ", "summary": "### "}[tag]
        elif tag in ("ul", "ol"):
            self.list_stack.append([tag, 0])
        elif tag == "li":
            if self.list_stack and self.list_stack[-1][0] == "ol":
                self.list_stack[-1][1] += 1
                d.prefix = "  " * (len(self.list_stack) - 1) + f"{self.list_stack[-1][1]}. "
            else:
                d.prefix = "  " * max(len(self.list_stack) - 1, 0) + "- "
        elif tag in ("b", "strong"):
            d.text("**")
        elif tag == "code" and not self.in_pre:
            d.text("`")
        elif tag == "pre":
            self.in_pre = True
            d.lines.append("```")
        elif tag == "a":
            href = a.get("href") or ""
            self.href = href if href.startswith(("http://", "https://")) else None
        elif tag in ("td", "th"):
            d.text(" | ")

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        # pop to the matching tag (tolerates sloppy HTML)
        while self.stack:
            t, opened, skipping = self.stack.pop()
            if skipping:
                self.skip_depth -= 1
            d = self.doc
            if not skipping and d is not None:
                self._close(t, d)
            if opened:
                d.flush()
                self.docs.append(self.doc_stack.pop())
            if t == tag:
                break

    def _close(self, tag, d):
        if tag == self.title_mode:
            d.title = re.sub(r"\s+", " ", "".join(d.cur)).strip()
            d.cur = []
            self.title_mode = None
            return
        if tag in ("b", "strong"):
            d.text("**")
        elif tag == "code" and not self.in_pre:
            d.text("`")
        elif tag == "pre":
            d.flush()
            d.lines.append("```")
            self.in_pre = False
        elif tag == "a" and self.href:
            d.text(f" ({self.href})")
            self.href = None
        elif tag in ("ul", "ol") and self.list_stack:
            self.list_stack.pop()
        if tag in BLOCKS:
            d.flush()

    def handle_data(self, data):
        if self.skip_depth or self.doc is None:
            return
        if self.in_pre:
            for i, part in enumerate(data.split("\n")):
                if i:
                    self.doc.lines.append("".join(self.doc.cur))
                    self.doc.cur = []
                self.doc.cur.append(part)
            return
        self.doc.text(data)


def safe_name(title, fallback):
    name = re.sub(r"[\\/:*?\"<>|\x00-\x1f]", "", title).strip(" .")
    name = re.sub(r"\s+", " ", name)
    return (name or fallback)[:80]


def tidy(lines):
    out = []
    for line in lines:
        line = line.replace("****", "").replace("** **", " ").rstrip()
        if line.strip() in ("**", "``", "-", "|"):
            continue
        if out and out[-1] == "" and line == "":
            continue
        out.append(line)
    # blank line between blocks for readable Markdown, but not inside lists or code
    result = []
    in_code = False
    for line in out:
        if line == "```":
            in_code = not in_code
        is_list = bool(re.match(r"\s*(- |\d+\. )", line))
        if result and not in_code and line != "```" and not (is_list and re.match(r"\s*(- |\d+\. )", result[-1])):
            if result[-1] != "":
                result.append("")
        result.append(line)
    return result


def write_docs(docs, out_dir, link_base):
    os.makedirs(os.path.join(out_dir, "Apps"), exist_ok=True)
    manifest_path = os.path.join(out_dir, ".generated")
    old = set()
    if os.path.exists(manifest_path):
        with open(manifest_path, encoding="utf-8") as fh:
            old = {line.strip() for line in fh if line.strip()}
    written = []
    chapters = [d for d in docs if d.kind == "chapter"]
    apps = [d for d in docs if d.kind == "app"]
    index = ["# Secure Linux Guide (searchable copy)", "",
             "These files are made from the START-HERE guide so the app launcher can find them.",
             f"The full guide, with pictures and links: {link_base}", "", "## Chapters", ""]
    used = set()
    for n, d in enumerate(chapters, 1):
        rel = f"{n:02d} {safe_name(d.title, d.ident or 'Chapter')}.md"
        write_one(out_dir, rel, d, link_base, written)
        index.append(f"- {d.title}")
        used.add(rel)
    index += ["", "## Apps", ""]
    for d in apps:
        base = safe_name(d.title, d.ident or "App")
        rel = os.path.join("Apps", base + ".md")
        k = 2
        while rel in used:
            rel = os.path.join("Apps", f"{base} ({k}).md")
            k += 1
        used.add(rel)
        write_one(out_dir, rel, d, link_base, written)
        index.append(f"- {d.title}")
    rel = "00 Start here - index.md"
    with open(os.path.join(out_dir, rel), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(index) + "\n")
    written.append(rel)
    for rel in sorted(old - set(written)):
        p = os.path.join(out_dir, rel)
        if os.path.isfile(p) and ".." not in rel.split(os.sep):
            os.remove(p)
    with open(manifest_path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(written) + "\n")
    return written


def write_one(out_dir, rel, d, link_base, written):
    body = tidy(d.lines)
    head = [f"# {d.title or d.ident}", "",
            f"_From the Secure Linux guide. Full page: {link_base}#{d.ident}_", ""]
    with open(os.path.join(out_dir, rel), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(head + body).rstrip() + "\n")
    written.append(rel)


def main(argv):
    if len(argv) < 3 or argv[1] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if len(argv) > 1 and argv[1] in ("-h", "--help") else 1
    link_base = "file:///usr/share/secure-linux/START-HERE.html"
    if "--link-base" in argv:
        i = argv.index("--link-base")
        link_base = argv[i + 1]
    with open(argv[1], encoding="utf-8") as fh:
        source = fh.read()
    parser = GuideParser()
    parser.feed(source)
    parser.close()
    docs = [d for d in parser.docs if d.lines or d.title]
    docs.sort(key=lambda d: source.find(f'id="{d.ident}"') if d.ident else 0)
    if not docs:
        print("No chapters found in the guide.", file=sys.stderr)
        return 1
    written = write_docs(docs, argv[2], link_base)
    print(f"Wrote {len(written)} files to {argv[2]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
