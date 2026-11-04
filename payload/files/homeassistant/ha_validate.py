#!/usr/bin/env python3
# Secure Linux - strict YAML + structure check for a Home Assistant config folder.  Owned by: homeassistant (Job L).
# Used by:  secure-linux-ha validate [FOLDER]
# Understands Home Assistant's !secret / !include / !input tags, finds duplicate keys and missing include files,
# and checks that every automation has a trigger and an action (and says so, in plain English, when not).
# Exit code: 0 = nothing wrong, 1 = something would stop Home Assistant starting or an automation working.
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ha_secure as hs                                                    # noqa: E402


def automations_in(doc):
    """Yield automation dicts from a loaded YAML document (a list, a package, or a whole configuration)."""
    if isinstance(doc, list):
        for a in doc:
            if isinstance(a, dict) and any(k in a for k in ("trigger", "triggers", "action", "actions", "alias")):
                yield a
    elif isinstance(doc, dict):
        a = doc.get("automation")
        if isinstance(a, list):
            for x in a:
                if isinstance(x, dict):
                    yield x
        elif isinstance(a, dict):
            for x in a.values():
                for y in (x if isinstance(x, list) else [x]):
                    if isinstance(y, dict):
                        yield y


def main(argv):
    if not argv:
        print("Use: ha_validate.py CONFIG_FOLDER")
        return 2
    root = Path(argv[0])
    errors, warnings = [], []
    main_cfg = root / "configuration.yaml"
    issues = []
    cfg = hs.load_yaml_file(main_cfg, root, issues)
    errors.extend(issues)
    if cfg is None and not issues:
        errors.append("configuration.yaml is empty")
    elif cfg is not None and not isinstance(cfg, dict):
        errors.append("configuration.yaml must be a list of settings (name: value), not a single value")
    # every other YAML file on its own: catches mistakes in files nothing includes yet
    n_files = 1
    n_auto = 0
    for p in sorted(root.rglob("*.yaml")):
        rel = p.relative_to(root)
        if any(part in hs.SKIP_DIRS or part.startswith(".") for part in rel.parts) or p.name in ("secrets.yaml", "configuration.yaml"):
            continue
        n_files += 1
        i2 = []
        doc = hs.load_yaml_file(p, root, i2)
        errors.extend(i2)
        if doc is None:
            continue
        if rel.parts[0] == "blueprints":
            bp = doc.get("blueprint") if isinstance(doc, dict) else None
            if not isinstance(bp, dict) or not bp.get("name") or not bp.get("domain"):
                errors.append("%s: a blueprint needs 'blueprint:' with at least a name and a domain" % rel.as_posix())
            else:
                if not bp.get("description"):
                    warnings.append("%s: add a description so you remember what this blueprint does" % rel.as_posix())
                if not (isinstance(doc, dict) and (doc.get("triggers") or doc.get("trigger")) and (doc.get("actions") or doc.get("action"))):
                    errors.append("%s: the blueprint has no trigger or no action" % rel.as_posix())
            continue
        for a in automations_in(doc):
            n_auto += 1
            name = a.get("alias") or a.get("id") or "(unnamed)"
            if not (a.get("trigger") or a.get("triggers")):
                errors.append("%s: automation '%s' has no trigger, so it can never start" % (rel.as_posix(), name))
            if not (a.get("action") or a.get("actions")):
                errors.append("%s: automation '%s' has no action, so it would do nothing" % (rel.as_posix(), name))
            if not a.get("alias"):
                warnings.append("%s: an automation has no alias (a name); add one so you can find it" % rel.as_posix())
            elif not a.get("description"):
                warnings.append("%s: automation '%s' has no description; add one for your future self" % (rel.as_posix(), name))
    print("Read %d YAML file(s), %d automation(s)." % (n_files, n_auto))
    for e in errors:
        print("PROBLEM: " + e)
    for w in warnings:
        print("tip: " + w)
    if not errors:
        print("YAML structure: no problems found.")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
