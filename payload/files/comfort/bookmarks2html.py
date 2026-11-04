#!/usr/bin/env python3
"""Convert Chrome / Edge / Brave "Bookmarks" files (JSON) and Firefox "places.sqlite" files into one
Netscape bookmarks HTML file that
LibreWolf and Firefox import with  Bookmarks > Manage bookmarks > Import and Backup > Import Bookmarks from HTML.

    bookmarks2html.py OUT.html BOOKMARKS_FILE [BOOKMARKS_FILE...]
    bookmarks2html.py OUT.html --search FOLDER      find every Bookmarks / places.sqlite below FOLDER

Each input becomes a top-level folder named after the browser and profile ("Chrome - Default"), so nothing
gets mixed up. Only http(s), ftp and file links are kept (javascript: bookmarklets are dropped for safety).
Standard library only. Exit code 0 = written, 1 = nothing found / unreadable input.
"""
import html
import json
import os
import shutil
import sqlite3
import sys
import tempfile

SAFE_SCHEMES = ("http://", "https://", "ftp://", "file://")
ROOT_NAMES = {"bookmark_bar": "Bookmarks bar", "other": "Other bookmarks", "synced": "Mobile bookmarks"}


def chrome_time_to_unix(value):
    """Chrome stores microseconds since 1601-01-01 as a string. Returns seconds since 1970 (int) or 0."""
    try:
        v = int(value)
    except (TypeError, ValueError):
        return 0
    if v <= 0:
        return 0
    secs = v // 1_000_000 - 11_644_473_600
    return secs if secs > 0 else 0


def esc(text):
    return html.escape(text or "", quote=True)


def write_node(node, out, depth, counts):
    pad = "    " * depth
    kind = node.get("type")
    if kind == "url":
        url = (node.get("url") or "").strip()
        if not url.lower().startswith(SAFE_SCHEMES):
            counts["skipped"] += 1
            return
        added = chrome_time_to_unix(node.get("date_added"))
        attrs = f' HREF="{esc(url)}"'
        if added:
            attrs += f' ADD_DATE="{added}"'
        out.append(f"{pad}<DT><A{attrs}>{esc(node.get('name') or url)}</A>")
        counts["links"] += 1
    elif kind == "folder" or "children" in node:
        write_folder(node.get("name") or "Folder", node.get("children") or [], out, depth, counts,
                     chrome_time_to_unix(node.get("date_added")))


def write_folder(name, children, out, depth, counts, added=0):
    pad = "    " * depth
    attrs = f' ADD_DATE="{added}"' if added else ""
    out.append(f"{pad}<DT><H3{attrs}>{esc(name)}</H3>")
    out.append(f"{pad}<DL><p>")
    for child in children:
        write_node(child, out, depth + 1, counts)
    out.append(f"{pad}</DL><p>")
    counts["folders"] += 1


def label_for(path):
    """browsers/Chrome/Profile 1/Bookmarks -> 'Chrome - Profile 1'"""
    parts = os.path.normpath(os.path.abspath(path)).split(os.sep)
    if len(parts) >= 3:
        return f"{parts[-3]} - {parts[-2]}"
    return os.path.basename(os.path.dirname(path)) or "Imported"


def firefox_tree(path):
    """Read a Firefox places.sqlite (with its -wal file) into Chrome-style nodes. Works on a copy."""
    tmp = tempfile.mkdtemp()
    try:
        for suffix in ("", "-wal"):
            if os.path.exists(path + suffix):
                shutil.copy2(path + suffix, os.path.join(tmp, "places.sqlite" + suffix))
        con = sqlite3.connect(os.path.join(tmp, "places.sqlite"))
        rows = con.execute(
            "SELECT b.id, b.type, b.parent, b.position, b.title, b.dateAdded, p.url, b.guid "
            "FROM moz_bookmarks b LEFT JOIN moz_places p ON b.fk = p.id ORDER BY b.parent, b.position").fetchall()
        roots = {r[1]: r[0] for r in con.execute("SELECT root_name, folder_id FROM moz_bookmarks_roots")}             if con.execute("SELECT name FROM sqlite_master WHERE name='moz_bookmarks_roots'").fetchone() else {}
        con.close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    children = {}
    info = {}
    guids = {}
    for bid, typ, parent, _pos, title, added, url, guid in rows:
        info[bid] = (typ, title, added, url)
        guids[bid] = guid or ""
        children.setdefault(parent, []).append(bid)

    def build(bid):
        typ, title, added, url = info[bid]
        chrome_added = str((added or 0) + 11_644_473_600_000_000) if added else "0"
        if typ == 1:
            return {"type": "url", "name": title or url or "", "url": url or "", "date_added": chrome_added}
        if typ == 2:
            return {"type": "folder", "name": title or "Folder", "date_added": chrome_added,
                    "children": [build(c) for c in children.get(bid, []) if c in info and info[c][0] in (1, 2)]}
        return None

    def kids(name, guid_fallback):
        fid = roots.get(name)
        if fid is None:   # Firefox 62+: roots are children of the root, known by GUID (toolbar_____ ...)
            for c in children.get(1, []):
                if guids.get(c, "").rstrip("_") in guid_fallback or (info.get(c) or (0, ""))[1] in guid_fallback:
                    fid = c
        return [n for n in (build(c) for c in children.get(fid, [])) if n] if fid is not None else []

    return {"roots": {
        "bookmark_bar": {"children": kids("toolbar", ("toolbar",))},
        "other": {"children": kids("menu", ("menu",)) + kids("unfiled", ("unfiled",))},
        "synced": {"children": kids("mobile", ("mobile",))},
    }}


def load(path):
    if os.path.basename(path) == "places.sqlite":
        return firefox_tree(path)
    with open(path, encoding="utf-8-sig") as fh:
        return json.load(fh)


def convert(inputs):
    counts = {"links": 0, "folders": 0, "skipped": 0, "files": 0}
    out = [
        "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
        "<!-- This is an automatically generated file. It will be read and overwritten. DO NOT EDIT! -->",
        '<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">',
        "<TITLE>Bookmarks</TITLE>",
        "<H1>Bookmarks</H1>",
        "<DL><p>",
    ]
    for path in inputs:
        try:
            data = load(path)
        except (OSError, ValueError, sqlite3.Error) as err:
            print(f"Skipping {path}: {err}", file=sys.stderr)
            continue
        roots = data.get("roots") if isinstance(data, dict) else None
        if not isinstance(roots, dict):
            print(f"Skipping {path}: not a Chrome bookmarks file", file=sys.stderr)
            continue
        counts["files"] += 1
        out.append(f"    <DT><H3>{esc(label_for(path))}</H3>")
        out.append("    <DL><p>")
        for key in ("bookmark_bar", "other", "synced"):
            root = roots.get(key)
            if isinstance(root, dict) and root.get("children"):
                write_folder(ROOT_NAMES[key], root["children"], out, 2, counts)
        out.append("    </DL><p>")
    out.append("</DL><p>")
    return "\n".join(out) + "\n", counts


def find_bookmark_files(folder):
    found = []
    for dirpath, dirnames, filenames in os.walk(folder):
        dirnames.sort()
        depth = os.path.relpath(dirpath, folder).count(os.sep)
        if depth > 5:
            dirnames[:] = []
            continue
        for name in ("Bookmarks", "places.sqlite"):
            if name in filenames:
                found.append(os.path.join(dirpath, name))
    return found


def main(argv):
    if len(argv) < 3 or argv[1] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if len(argv) > 1 and argv[1] in ("-h", "--help") else 1
    out_path = argv[1]
    if argv[2] == "--search":
        if len(argv) < 4:
            print("--search needs a folder", file=sys.stderr)
            return 1
        inputs = find_bookmark_files(argv[3])
    else:
        inputs = argv[2:]
    if not inputs:
        print("No Chrome/Edge bookmarks files found.", file=sys.stderr)
        return 1
    text, counts = convert(inputs)
    if counts["files"] == 0:
        return 1
    tmp = out_path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    os.replace(tmp, out_path)
    print(f"{counts['links']} bookmarks in {counts['folders']} folders from {counts['files']} profile(s)"
          + (f"; {counts['skipped']} non-web links left out" if counts["skipped"] else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
