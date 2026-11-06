#!/usr/bin/env python3
"""Match an old computer's app-name record with Secure Linux's app equivalents.

Read-only apart from the text printed to stdout. No app files or personal data are opened.
The JSON collectors supply only hostname, collection time, app names, publishers and sources.
"""
import argparse
import collections
import json
import re
import sys

FIELDS = ("pattern", "linux_id", "pkg_type", "category", "what", "why_best",
          "compare", "debian_pkg", "state", "profiles")
CATEGORIES = ("Office", "Internet", "Photos & video", "Music", "Games", "Tools")
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
DEB_RE = re.compile(r"^[a-z0-9][a-z0-9+.-]*$")


class DatabaseError(ValueError):
    pass


def clean(value):
    return " ".join(str(value).replace("\t", " ").split())


def load_database(path):
    rows = []
    seen = set()
    try:
        fh = open(path, encoding="utf-8")
    except OSError as exc:
        raise DatabaseError("Cannot read the app mapping: %s" % exc)
    with fh:
        for number, raw in enumerate(fh, 1):
            raw = raw.rstrip("\r\n")
            if not raw.strip() or raw.lstrip().startswith("#"):
                continue
            parts = raw.split("\t")
            if len(parts) != len(FIELDS):
                raise DatabaseError("Mapping line %d has %d fields; expected %d" %
                                    (number, len(parts), len(FIELDS)))
            row = dict(zip(FIELDS, parts))
            row["line"] = number
            for field in FIELDS:
                row[field] = row[field].strip()
            key = row["pattern"].casefold()
            if not key or key in seen:
                raise DatabaseError("Mapping line %d has an empty or duplicate pattern" % number)
            seen.add(key)
            if row["category"] not in CATEGORIES:
                raise DatabaseError("Mapping line %d has an unknown category" % number)
            if row["state"] not in ("installed", "extra", "gap"):
                raise DatabaseError("Mapping line %d has an unknown state" % number)
            if row["profiles"] not in ("all", "full", "lite"):
                raise DatabaseError("Mapping line %d has unknown profiles" % number)
            if row["pkg_type"] not in ("flatpak", "rpm", "none"):
                raise DatabaseError("Mapping line %d has an unknown package type" % number)
            if row["state"] == "extra":
                if not row["linux_id"] or row["pkg_type"] == "none":
                    raise DatabaseError("Extra on mapping line %d needs a Linux package id" % number)
                if not all(row[field] for field in ("what", "why_best", "compare")):
                    raise DatabaseError("Extra on mapping line %d needs all explanations" % number)
            if row["state"] == "gap" and not row["compare"]:
                raise DatabaseError("Gap on mapping line %d needs an honest explanation" % number)
            if row["linux_id"] and not ID_RE.match(row["linux_id"]):
                raise DatabaseError("Mapping line %d has an unsafe Linux id" % number)
            if row["debian_pkg"] and not DEB_RE.match(row["debian_pkg"]):
                raise DatabaseError("Mapping line %d has an invalid Debian package" % number)
            if row["pkg_type"] == "none" and row["linux_id"]:
                raise DatabaseError("Mapping line %d has an id but no package type" % number)
            if row["pkg_type"] != "none" and not row["linux_id"]:
                raise DatabaseError("Mapping line %d has a package type but no id" % number)
            rows.append(row)
    if not rows:
        raise DatabaseError("The app mapping is empty")
    return rows


def load_record(path):
    try:
        with open(path, encoding="utf-8-sig") as fh:
            record = json.load(fh)
        if not isinstance(record, dict) or not isinstance(record.get("apps"), list):
            raise ValueError("the apps field is not a list")
    except (OSError, ValueError) as exc:
        raise ValueError("This is not a readable app scan record: %s" % exc)
    apps = {}
    for item in record["apps"]:
        if not isinstance(item, dict):
            continue
        name = clean(item.get("name", ""))
        if name:
            apps.setdefault(name.casefold(), name)
    return {"hostname": clean(record.get("hostname", "old computer")) or "old computer",
            "apps": [apps[key] for key in sorted(apps)]}


def applies(row, profile):
    return row["profiles"] == "all" or row["profiles"] == profile


def match_apps(rows, record, profile):
    covered = []
    recommendations = collections.OrderedDict()
    gaps = collections.OrderedDict()
    unknown = []
    for name in record["apps"]:
        folded = name.casefold()
        row = next((r for r in rows if r["pattern"].casefold() in folded), None)
        if row is None:
            unknown.append(name)
            continue
        if not applies(row, profile):
            key = row["pattern"]
            reason = ("%s is not included on the %s setup. %s" %
                      (row["what"], profile, row["compare"]))
            gaps.setdefault(key, {"old_apps": [], "why": reason})
            gaps[key]["old_apps"].append(name)
        elif row["state"] == "installed":
            covered.append({"old_app": name, "what": row["what"], "compare": row["compare"]})
        elif row["state"] == "extra":
            key = row["linux_id"]
            if key not in recommendations:
                item = dict(row)
                item["old_apps"] = []
                recommendations[key] = item
            recommendations[key]["old_apps"].append(name)
        else:
            key = row["pattern"]
            if key not in gaps:
                gaps[key] = {"old_apps": [], "why": row["compare"]}
            gaps[key]["old_apps"].append(name)
    return {"hostname": record["hostname"], "profile": profile, "total_apps": len(record["apps"]),
            "covered": covered, "recommendations": list(recommendations.values()),
            "gaps": list(gaps.values()), "unknown": unknown}


def shell_report(result):
    print("\t".join(("SUMMARY", result["hostname"], str(result["total_apps"]),
                     str(len(result["covered"])), str(len(result["recommendations"])),
                     str(len(result["gaps"])), str(len(result["unknown"])))))
    for item in result["covered"]:
        print("\t".join(("COVERED", clean(item["old_app"]), clean(item["what"]))))
    for item in result["recommendations"]:
        print("\t".join(("RECOMMEND", item["linux_id"], clean(", ".join(item["old_apps"])),
                         clean(item["what"]), clean(item["why_best"]), clean(item["compare"]),
                         item["pkg_type"], item["debian_pkg"])))
    for item in result["gaps"]:
        print("\t".join(("GAP", clean(", ".join(item["old_apps"])), clean(item["why"]))))


def human_report(result, debian=False):
    covered = len(result["covered"])
    recs = result["recommendations"]
    gaps = result["gaps"]
    lines = ["App list from %s: %d apps read." % (result["hostname"], result["total_apps"]), ""]
    examples = ", ".join(item["old_app"] for item in result["covered"][:4])
    lines.append("Already covered: %d recognised apps%s." %
                 (covered, (" (for example %s)" % examples) if examples else ""))
    if result["unknown"]:
        lines.append("%d other apps were not recognised, so nothing is suggested for them." % len(result["unknown"]))
    if recs:
        lines.extend(["", "Optional additions:"])
        for item in recs:
            lines.extend(["", "%s (for %s)" % (item["what"], ", ".join(item["old_apps"])),
                          "Why this one: " + item["why_best"],
                          "Compared with the old app: " + item["compare"]])
            if debian and not item["debian_pkg"]:
                lines.append("Not available as a Debian package in this mapping; it is left out of the command below.")
    else:
        lines.extend(["", "No extra apps are recommended. The stick already covers everything recognised."])
    if gaps:
        lines.extend(["", "Honest gaps (nothing will be installed for these):"])
        for item in gaps:
            lines.append("  %s: %s" % (", ".join(item["old_apps"]), item["why"]))
    if debian:
        ids = [item["linux_id"] for item in recs if item["debian_pkg"]]
        if ids:
            lines.extend(["", "To install all available additions above, run these two commands yourself:",
                          'sudo secure-linux-choice set extra_apps "%s"' % " ".join(ids),
                          "sudo /usr/local/lib/secure-linux/setup.sh --repair",
                          "To leave one out, remove its Linux id from the quoted list. Nothing is installed by this information page."])
    return "\n".join(lines)


def installed_report(rows, profile):
    groups = collections.OrderedDict((category, collections.OrderedDict()) for category in CATEGORIES)
    for row in rows:
        if row["state"] != "installed" or not applies(row, profile):
            continue
        # One entry per Linux app, not one entry for every old name it replaces. Built-in
        # rows have no package id, so their own explanation keeps them separate.
        key = row["linux_id"] or (row["category"], row["what"])
        if key not in groups[row["category"]]:
            groups[row["category"]][key] = {"row": row, "old": []}
        groups[row["category"]][key]["old"].append(row["pattern"])
    output = []
    for category, items in groups.items():
        if not items:
            continue
        output.append(category)
        for item in items.values():
            row = item["row"]
            output.append("  " + ", ".join(item["old"]) + "  ->  " + row["what"])
            output.append("    " + row["compare"])
        output.append("")
    return "\n".join(output).rstrip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("validate", "installed", "match"):
        p = sub.add_parser(name)
        p.add_argument("--database", required=True)
        if name != "validate":
            p.add_argument("--profile", choices=("full", "lite"), default="full")
        if name == "installed":
            p.add_argument("--format", choices=("text",), default="text")
        if name == "match":
            p.add_argument("--record", required=True)
            p.add_argument("--format", choices=("json", "shell", "text", "debian"), default="json")
    args = parser.parse_args()
    try:
        rows = load_database(args.database)
        if args.command == "validate":
            extras = set(row["linux_id"] for row in rows if row["state"] == "extra")
            print("Mapping OK: %d patterns, %d optional packages, %d honest-gap patterns" %
                  (len(rows), len(extras), sum(row["state"] == "gap" for row in rows)))
        elif args.command == "installed":
            print(installed_report(rows, args.profile))
        else:
            result = match_apps(rows, load_record(args.record), args.profile)
            if args.format == "json":
                print(json.dumps(result, ensure_ascii=False, indent=2))
            elif args.format == "shell":
                shell_report(result)
            else:
                print(human_report(result, debian=args.format == "debian"))
    except (DatabaseError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
