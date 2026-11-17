#!/usr/bin/env python3
"""Secure Linux App Library: the catalogue reader and checker (standard library only).

The catalogue is a folder of small tab-separated files, linux/setup-data/apps.d/<NN>-<group>.tsv (contract C11).
One app per line, nine columns:

    id  kind  title  plain_description  approx_size_mb  profiles  default  arch  idea

This module reads and checks those files and works out which apps a computer should install. It never installs
anything itself: secure-linux-app-library (bash) does that with the same helpers the setup steps use.

Command line (used by secure-linux-app-library and the setup step):
    app_library.py validate --apps-dir DIR
    app_library.py plan     --apps-dir DIR --profile P --arch A --choices FILE
    app_library.py list     --apps-dir DIR --profile P --arch A --choices FILE
    app_library.py show     --apps-dir DIR --id ID
    app_library.py save     --apps-dir DIR --profile P --arch A --choices FILE [--ids ID ...]
    app_library.py size     --apps-dir DIR --profile P --arch A --choices FILE [--ids ID ...]
    app_library.py check-id ID
Output lines are tab-separated and never contain an empty column, so a shell can read them with IFS=tab.
"""
import argparse
import os
import re
import sys
import tempfile

KINDS = ("flatpak", "rpm", "pipx", "serverapp", "kittool")
# Two kinds are not installed by setup at all (they are "listed only" kinds):
#   serverapp  a home-server app. The id is the recipe folder name under linux/files/server-apps/ and it is set up with
#              "secure-linux-server-apps install ID" (it asks for the person's own password and needs Docker or Podman).
#   kittool    a Secure Linux tool that is already on the computer (in /usr/local/bin) and sets itself up when the
#              person first opens it, for example the AI chat page or Talk to my AI. The id is the command name.
# Setup never installs either kind, so a row of these kinds must say default off and must not offer the atomic profile.
LISTED_ONLY_KINDS = ("serverapp", "kittool")
LISTED_ONLY_REASON = {
    "serverapp": "Home-server apps are set up from the Home-server apps window (or: secure-linux-server-apps install NAME), "
                 "never by setup, because they need your own say-so and Docker or Podman",
    "kittool": "This is a Secure Linux tool that is already on this computer. Open it from the app launcher; "
               "it sets itself up the first time you open it",
}
PROFILES = ("full", "lite", "atomic")
ARCHES = ("all", "x86_64")
MAX_TITLE = 60
MAX_DESC = 240
MAX_SIZE_MB = 100000

# The catalogue never offers these (Matthew's decisions): Windows tools, video or image generation, study tools,
# music-making, game and animation tools. The idea numbers are from the idea list; the words catch a row that
# slips in without a number.
EXCLUDED_IDEAS = ("42", "43", "64", "78", "79", "80")
EXCLUDED_WORDS = ("wine", "bottles", "playonlinux", "crossover", "stable-diffusion", "comfyui", "invokeai",
                  "automatic1111", "blender", "godot", "lmms", "ardour", "anki")

ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$")
FLATPAK_ID_RE = re.compile(r"^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+){2,}$")
IDEA_RE = re.compile(r"^[A-Za-z0-9._,/ -]{0,40}$")
BAD_TEXT_RE = re.compile(r"[\x00-\x1f\x7f`$\\<>]")


class Row(object):
    __slots__ = ("id", "kind", "title", "desc", "size_mb", "profiles", "default", "arch", "idea", "source")

    def __init__(self, **kw):
        for k in self.__slots__:
            setattr(self, k, kw.get(k))


def id_problem(app_id, kind=None):
    """Return a plain-English problem with an app id, or '' when it is fine. Shell characters are never allowed."""
    if not isinstance(app_id, str) or not app_id:
        return "the app name is empty"
    if not ID_RE.match(app_id):
        return "the app name '%s' has characters that are not allowed" % _show(app_id)
    if kind == "flatpak" and not FLATPAK_ID_RE.match(app_id):
        return "'%s' is not a Flatpak app id (it looks like org.example.App)" % app_id
    low = app_id.lower()
    for w in EXCLUDED_WORDS:
        if w in low:
            return "'%s' is in a category the App Library does not offer" % app_id
    return ""


def _show(text):
    """A safe, short copy of text for a message (control characters shown as ?)."""
    t = "".join(c if 32 <= ord(c) < 127 else "?" for c in text)
    return t[:40]


def parse_line(line, source, number):
    """Return (Row or None, error or None). Blank lines and comments give (None, None)."""
    raw = line.rstrip("\r\n")
    if not raw.strip() or raw.lstrip().startswith("#"):
        return None, None
    where = "%s line %d" % (source, number)
    cols = raw.split("\t")
    if len(cols) == 8:
        cols.append("")
    if len(cols) != 9:
        return None, "%s: expected 9 columns separated by tabs, found %d" % (where, len(cols))
    app_id, kind, title, desc, size, profiles, default, arch, idea = [c.strip() for c in cols]
    if kind not in KINDS:
        return None, "%s: kind must be flatpak, rpm, pipx, serverapp or kittool (found '%s')" % (where, _show(kind))
    prob = id_problem(app_id, kind)
    if prob:
        return None, "%s: %s" % (where, prob)
    for label, text, limit in (("title", title, MAX_TITLE), ("description", desc, MAX_DESC)):
        if not text:
            return None, "%s: the %s is empty" % (where, label)
        if len(text) > limit:
            return None, "%s: the %s is longer than %d characters" % (where, label, limit)
        if BAD_TEXT_RE.search(text):
            return None, "%s: the %s has a character that is not allowed" % (where, label)
    if not re.match(r"^[0-9]{1,6}$", size) or int(size) > MAX_SIZE_MB:
        return None, "%s: the size must be a whole number of megabytes" % where
    plist = [p.strip() for p in profiles.split(",") if p.strip()]
    if not plist or any(p not in PROFILES for p in plist):
        return None, "%s: profiles must be a list made of full, lite and atomic" % where
    if default not in ("on", "off"):
        return None, "%s: default must be on or off" % where
    if kind in LISTED_ONLY_KINDS:
        if default != "off":
            return None, "%s: a %s row must say default off (setup never installs it by itself)" % (where, kind)
        if "atomic" in plist:
            return None, "%s: a %s row must not offer the atomic profile" % (where, kind)
    if arch not in ARCHES:
        return None, "%s: arch must be all or x86_64" % where
    if not IDEA_RE.match(idea):
        return None, "%s: the idea column has characters that are not allowed" % where
    for token in re.split(r"[ ,/]+", idea):
        if token in EXCLUDED_IDEAS:
            return None, "%s: idea %s is in a category the App Library does not offer" % (where, token)
    return Row(id=app_id, kind=kind, title=title, desc=desc, size_mb=int(size), profiles=tuple(plist),
               default=default, arch=arch, idea=idea, source=source), None


def load_catalogue(apps_dir):
    """Read every *.tsv in apps_dir in name order. Returns (rows in order, errors). A bad line is reported and
    left out; the good lines still work. A second row with the same id is an error (the first one wins)."""
    rows, errors, seen = [], [], {}
    try:
        names = sorted(n for n in os.listdir(apps_dir) if n.endswith(".tsv") and not n.startswith("."))
    except OSError:
        return rows, ["the app catalogue folder is missing: %s" % apps_dir]
    for name in names:
        try:
            with open(os.path.join(apps_dir, name), "r", encoding="utf-8", newline="") as fh:
                text = fh.read()
        except (OSError, UnicodeDecodeError):
            errors.append("%s: could not be read as UTF-8 text" % name)
            continue
        if text.startswith("﻿"):
            errors.append("%s: starts with a byte-order mark (save it as UTF-8 without BOM)" % name)
            text = text[1:]
        for number, line in enumerate(text.split("\n"), 1):
            row, err = parse_line(line, name, number)
            if err:
                errors.append(err)
            elif row is not None:
                if row.id in seen:
                    errors.append("%s line %d: '%s' is already listed in %s" % (name, number, row.id, seen[row.id]))
                    continue
                seen[row.id] = name
                rows.append(row)
    return rows, errors


def read_choices(path):
    """Read /etc/secure-linux/app-library.list: 'id' = install it, '-id' = do not install it. Returns (on, off)."""
    on, off = set(), set()
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                item = line.split("#", 1)[0].strip()
                if not item:
                    continue
                neg = item.startswith("-")
                name = item[1:].strip() if neg else item
                if not ID_RE.match(name):
                    continue  # anything with shell characters is ignored, never acted on
                (off if neg else on).add(name)
    except OSError:
        pass
    return on, off


def eligible(row, profile, arch):
    """True when the app is offered for this profile (arch is handled separately so it can be explained)."""
    return profile in row.profiles


def arch_ok(row, arch):
    return row.arch == "all" or row.arch == arch


def wanted(row, on, off):
    if row.id in on:
        return True
    if row.id in off:
        return False
    return row.default == "on"


def plan(rows, profile, arch, on, off):
    """Rows to act on: [(action, row, reason)]. action is 'install' or 'skip' (an app this computer can not run).
    A serverapp or kittool row that somebody chose is never installed by setup: it is a 'skip' with a plain reason."""
    out = []
    for row in rows:
        if not eligible(row, profile, arch) or not wanted(row, on, off):
            continue
        if row.kind in LISTED_ONLY_KINDS:
            out.append(("skip", row, LISTED_ONLY_REASON[row.kind]))
        elif not arch_ok(row, arch):
            out.append(("skip", row, "This app only has a version for Intel and AMD computers, not for this one"))
        else:
            out.append(("install", row, "-"))
    return out


def format_size(mb):
    if mb >= 1024:
        return "%.1f GB" % (mb / 1024.0)
    return "%d MB" % mb


def save_choices(path, rows, profile, arch, on, off, selected):
    """Write the choices file so that, for the apps offered here, exactly `selected` is wanted. Entries for apps
    not offered on this computer are kept. Written atomically."""
    offered = {r.id: r for r in rows if eligible(r, profile, arch) and arch_ok(r, arch)}
    keep_on = {i for i in on if i not in offered}
    keep_off = {i for i in off if i not in offered}
    new_on, new_off = set(keep_on), set(keep_off)
    for app_id, row in offered.items():
        picked = app_id in selected
        if picked and row.default == "off":
            new_on.add(app_id)
        elif not picked and row.default == "on":
            new_off.add(app_id)
    lines = ["# Secure Linux App Library choices. 'name' = install it, '-name' = do not install it.",
             "# Change them with the Optional apps window; this file is read by secure-linux-app-library."]
    lines += sorted(new_on) + ["-" + i for i in sorted(new_off)]
    folder = os.path.dirname(os.path.abspath(path)) or "."
    os.makedirs(folder, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".app-library.", dir=folder)
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def _out(text):
    # Bytes with a plain LF: on Windows a text-mode write would add a CR and the shell would read it as part of the
    # last column.
    out = sys.stdout.buffer if hasattr(sys.stdout, "buffer") else None
    if out is None:
        sys.stdout.write(text + "\n")
    else:
        out.write((text + "\n").encode("utf-8"))
        out.flush()


def main(argv=None):
    ap = argparse.ArgumentParser(prog="app_library.py", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd")
    for name in ("validate", "plan", "list", "show", "save", "size"):
        p = sub.add_parser(name)
        p.add_argument("--apps-dir", required=True)
        if name in ("plan", "list", "save", "size"):
            p.add_argument("--profile", required=True, choices=PROFILES)
            p.add_argument("--arch", required=True)
            p.add_argument("--choices", required=True)
        if name == "show":
            p.add_argument("--id", required=True)
        if name in ("save", "size"):
            p.add_argument("--ids", nargs="*", default=[])
    p = sub.add_parser("check-id")
    p.add_argument("id")
    args = ap.parse_args(argv)
    if not args.cmd:
        ap.print_help()
        return 2
    if args.cmd == "check-id":
        prob = id_problem(args.id)
        if prob:
            sys.stderr.write(prob + "\n")
            return 1
        return 0
    rows, errors = load_catalogue(args.apps_dir)
    if args.cmd == "validate":
        for e in errors:
            _out("PROBLEM\t" + e)
        _out("ROWS\t%d" % len(rows))
        return 1 if errors else 0
    if args.cmd == "show":
        for r in rows:
            if r.id == args.id:
                _out("\t".join([r.id, r.kind, r.title, r.desc, str(r.size_mb), ",".join(r.profiles), r.default,
                                r.arch]))
                return 0
        return 1
    on, off = read_choices(args.choices)
    if args.cmd == "plan":
        for action, r, reason in plan(rows, args.profile, args.arch, on, off):
            _out("\t".join([action, r.id, r.kind, r.title, str(r.size_mb), reason]))
        return 0
    if args.cmd == "list":
        for r in rows:
            if eligible(r, args.profile, args.arch) and arch_ok(r, args.arch):
                state = "on" if wanted(r, on, off) else "off"
                _out("\t".join([state, r.id, r.kind, r.title, r.desc, format_size(r.size_mb), str(r.size_mb)]))
        return 0
    if args.cmd == "size":
        # Disk space the apps need (the catalogue's approx_size_mb): the named apps, or what setup would install
        # on this computer. The drive builder and the Optional apps window use it to warn before adding.
        if args.ids:
            by_id = {r.id: r for r in rows}
            bad = [i for i in args.ids if i not in by_id]
            if bad:
                sys.stderr.write("Not in the App Library list: %s\n" % ", ".join(_show(b) for b in bad))
                return 1
            chosen = [by_id[i] for i in args.ids]
        else:
            chosen = [r for action, r, _ in plan(rows, args.profile, args.arch, on, off) if action == "install"]
        for r in chosen:
            _out("\t".join(["APP", r.id, r.title, str(r.size_mb)]))
        _out("\t".join(["TOTAL_MB", str(sum(r.size_mb for r in chosen))]))
        return 0
    if args.cmd == "save":
        known = {r.id for r in rows if eligible(r, args.profile, args.arch) and arch_ok(r, args.arch)}
        bad = [i for i in args.ids if i not in known]
        if bad:
            sys.stderr.write("Not in the App Library list for this computer: %s\n" % ", ".join(_show(b) for b in bad))
            return 1
        save_choices(args.choices, rows, args.profile, args.arch, on, off, set(args.ids))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
