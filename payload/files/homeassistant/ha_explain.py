#!/usr/bin/env python3
# Secure Linux - "read this Home Assistant YAML file out loud in plain English".  Owned by: homeassistant (Job L).
# Used by:  secure-linux-ha-learn explain FILE   (add --speak to hear it)
# It never changes the file. It narrates: the header comment (what/why/how), then each automation, script,
# helper, blueprint input or dashboard card in everyday words. Anything it doesn't know is read out as-is.
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ha_secure as hs                                                    # noqa: E402

TOP_LEVEL = {
    "homeassistant": "Basic settings: the home's name, location, units, and which folders to load extra files from.",
    "default_config": "Switches on the standard set of Home Assistant features (the app, history, logbook, and so on).",
    "http": "The web server: how the login page is reached and protected.",
    "logger": "How much detail goes into the log file.",
    "recorder": "How long Home Assistant remembers history before tidying it away.",
    "automation": "Your automations: 'when this happens, do that'.",
    "script": "Scripts: a saved list of actions you can run with one click.",
    "scene": "Scenes: a saved look for a room (which lights, what colour).",
    "lovelace": "Dashboards: the pages you look at.",
    "input_boolean": "On/off switches that you control. Useful as 'modes'.",
    "input_text": "Text boxes you can change from the dashboard.",
    "input_number": "Number sliders or boxes.",
    "template": "Sensors that Home Assistant works out itself from other things.",
    "mqtt": "Settings for the MQTT message broker (how many gadgets talk to Home Assistant).",
    "group": "Groups of things treated as one.",
    "sensor": "Sensors (readings).",
    "binary_sensor": "On/off sensors (open/closed, motion/clear).",
    "light": "Lights.", "switch": "Switches and plugs.", "notify": "Ways to send you messages.",
    "frontend": "How the web interface looks.", "mobile_app": "Lets the phone app connect.",
}

DOMAIN_NAMES = {"light": "the lights", "lock": "the locks", "climate": "the heating or cooling", "alarm_control_panel": "the alarm",
                "binary_sensor": "a yes/no sensor", "sensor": "a sensor", "input_boolean": "a switch", "script": "a script", "persistent_notification": "the notification bell"}


def ent(e):
    if isinstance(e, hs.Tagged):
        return "your choice for '%s'" % e.value if e.tag == "!input" else "the secret '%s'" % e.value
    if isinstance(e, list):
        return ", ".join(ent(x) for x in e)
    return str(e)


def dur(d):
    if isinstance(d, hs.Tagged):
        return "the time you choose (%s)" % d.value
    if isinstance(d, dict):
        parts = []
        for k in ("hours", "minutes", "seconds"):
            if k in d:
                parts.append("%s %s" % (ent(d[k]), k))
        return " and ".join(parts) or str(d)
    return str(d)


def trig(t):
    if not isinstance(t, dict):
        return "something happens"
    kind = t.get("trigger") or t.get("platform")
    if kind == "state":
        s = "%s changes" % ent(t.get("entity_id", "something"))
        if "from" in t and "to" in t:
            s += " from %s to %s" % (t["from"], t["to"])
        elif "to" in t:
            s += " to %s" % t["to"]
        if t.get("for"):
            s += " and stays that way for " + dur(t["for"])
        return s
    if kind == "numeric_state":
        s = "%s" % ent(t.get("entity_id", "a number"))
        if "below" in t:
            s += " goes below %s" % ent(t["below"])
        if "above" in t:
            s += " goes above %s" % ent(t["above"])
        if t.get("for"):
            s += " for " + dur(t["for"])
        return s
    if kind == "time":
        return "the clock reaches %s" % ent(t.get("at"))
    if kind == "time_pattern":
        return "the clock hits a repeating pattern"
    if kind == "sun":
        off = t.get("offset")
        return "the sun %ss%s" % (t.get("event", "sets"), (" (offset " + ent(off) + ")") if off else "")
    if kind == "template":
        s = "a calculated condition (a template) becomes true"
        if t.get("for"):
            s += " and stays true for " + dur(t["for"])
        return s
    if kind == "homeassistant":
        return "Home Assistant %s" % t.get("event", "starts")
    if kind == "persistent_notification":
        return "a notification '%s' appears in the bell" % t.get("notification_id", "")
    if kind == "event":
        return "the event '%s' happens" % t.get("event_type")
    if kind == "webhook":
        return "a web address (webhook) is called"
    if kind == "zone":
        return "%s %ss %s" % (ent(t.get("entity_id")), t.get("event", "enter"), ent(t.get("zone")))
    return "'%s' fires" % kind


def cond(c):
    if isinstance(c, str):
        return "this template is true"
    if not isinstance(c, dict):
        return "something is true"
    k = c.get("condition")
    if k == "state":
        return "%s is %s" % (ent(c.get("entity_id")), ent(c.get("state")))
    if k == "numeric_state":
        return "%s is within the limits" % ent(c.get("entity_id"))
    if k == "template":
        return "a calculated condition (template) is true"
    if k in ("or", "and", "not"):
        sub = [cond(x) for x in c.get("conditions", [])]
        word = {"or": " OR ", "and": " AND ", "not": " NOR "}[k]
        return "(" + word.join(sub) + ")"
    if k == "time":
        return "the time/day matches (%s)" % ", ".join(ent(c.get(x)) for x in ("weekday", "after", "before") if c.get(x))
    if k == "trigger":
        return "it was the '%s' trigger that fired" % ent(c.get("id"))
    return "'%s' holds" % k


def act(a, depth=0):
    pad = "  " * depth
    out = []
    if not isinstance(a, dict):
        return [pad + "- do something"]
    svc = a.get("action") or a.get("service")
    if svc:
        who = ""
        tgt = a.get("target") or {}
        if isinstance(tgt, hs.Tagged):
            who = " on " + ent(tgt)
        elif isinstance(tgt, dict) and tgt.get("entity_id"):
            who = " on " + ent(tgt["entity_id"])
        dom, _, name = str(svc).partition(".")
        plain = {"turn_on": "turn on", "turn_off": "turn off", "toggle": "toggle", "lock": "lock", "unlock": "unlock", "create": "create"}.get(name, name.replace("_", " "))
        if isinstance(svc, str) and svc.startswith("{{"):
            out.append("%s- send a message to the phone you set in the helper" % pad)
        elif svc == "script.sl_notify":
            d = a.get("data") or {}
            out.append("%s- send you a notification (bell + phone): '%s'" % (pad, ent(d.get("title", "")) if isinstance(d, dict) else ""))
        else:
            out.append("%s- %s %s%s" % (pad, plain, DOMAIN_NAMES.get(dom, dom), who))
    elif "delay" in a:
        out.append("%s- wait %s" % (pad, dur(a["delay"])))
    elif "wait_for_trigger" in a:
        out.append("%s- wait until: %s" % (pad, "; or ".join(trig(t) for t in as_list(a["wait_for_trigger"]))))
    elif "choose" in a:
        out.append("%s- choose what to do:" % pad)
        for opt in a["choose"]:
            out.append("%s    if %s then:" % (pad, " and ".join(cond(c) for c in as_list(opt.get("conditions")))))
            for sub in as_list(opt.get("sequence")):
                out.extend(act(sub, depth + 3))
    elif "if" in a:
        out.append("%s- if %s then:" % (pad, " and ".join(cond(c) for c in as_list(a["if"]))))
        for sub in as_list(a.get("then")):
            out.extend(act(sub, depth + 2))
        for sub in as_list(a.get("else")):
            out.append(pad + "  otherwise:")
            out.extend(act(sub, depth + 2))
    elif "variables" in a:
        out.append("%s- work out: %s" % (pad, ", ".join(a["variables"].keys()) if isinstance(a["variables"], dict) else "some values"))
    elif "condition" in a:
        out.append("%s- carry on only if %s" % (pad, cond(a)))
    else:
        out.append("%s- (%s)" % (pad, ", ".join(a.keys()) if a else "nothing"))
    return out


def as_list(v):
    return v if isinstance(v, list) else ([] if v is None else [v])


def narrate_automation(a):
    out = ["", "AUTOMATION: %s" % a.get("alias", "(no name)")]
    if a.get("description"):
        out.append("  What it's for: %s" % a["description"])
    trigs = as_list(a.get("triggers") or a.get("trigger"))
    out.append("  It starts when " + "; or when ".join(trig(t) for t in trigs) + ".")
    conds = as_list(a.get("conditions") or a.get("condition"))
    if conds:
        out.append("  But only if " + " and ".join(cond(c) for c in conds) + ".")
    out.append("  Then it will:")
    for x in as_list(a.get("actions") or a.get("action")):
        out.extend(act(x, 2))
    mode = a.get("mode")
    if mode:
        out.append("  If it's triggered again while running: %s." % {"single": "the new one is ignored", "restart": "it starts over", "queued": "the new one waits its turn", "parallel": "both run"}.get(mode, mode))
    return out


def header_comment(text):
    lines = []
    for l in text.splitlines():
        if l.startswith("#"):
            s = l[1:].strip()
            if set(s) <= set("=-"):
                continue
            lines.append(s)
        elif l.strip() == "" and not lines:
            continue
        else:
            break
    return lines


def narrate(path):
    text = open(path, encoding="utf-8").read()
    issues = []
    doc = hs.load_yaml_text(text, issues)
    out = []
    head = header_comment(text)
    if head:
        out.append("ABOUT THIS FILE")
        out.extend("  " + h for h in head)
    if isinstance(doc, dict) and "blueprint" in doc:
        bp = doc["blueprint"]
        out += ["", "BLUEPRINT: %s" % bp.get("name"), "  %s" % " ".join(str(bp.get("description", "")).split())]
        out.append("  When you use it, Home Assistant will ask you to choose:")
        for k, v in (bp.get("input") or {}).items():
            v = v or {}
            kind = next(iter((v.get("selector") or {"a thing": 0}).keys()), "a thing")
            out.append("    - %s (%s)%s" % (v.get("name", k), {"entity": "pick an item from a list", "target": "pick lights/rooms", "number": "a number", "boolean": "on or off",
                                                            "time": "a time of day", "text": "some text"}.get(kind, kind), (": " + " ".join(str(v["description"]).split())) if v.get("description") else ""))
        out += narrate_automation({"alias": bp.get("name"), "triggers": doc.get("triggers"), "conditions": doc.get("conditions"), "actions": doc.get("actions"), "mode": doc.get("mode")})[1:]
        return out + _issues(issues)
    if isinstance(doc, dict) and "views" in doc:
        out += ["", "DASHBOARD: %s" % doc.get("title", "")]
        for v in doc["views"]:
            out.append("  Page '%s' has these cards:" % v.get("title"))
            for c in v.get("cards", []):
                out.append("    - %s card%s" % (c.get("type"), (" titled '%s'" % c["title"]) if c.get("title") else ""))
        return out + _issues(issues)
    if isinstance(doc, dict):
        for key, val in doc.items():
            if key == "automation":
                items = val if isinstance(val, list) else []
                if items:
                    for a in items:
                        out.extend(narrate_automation(a))
                else:
                    out += ["", "automation: " + TOP_LEVEL["automation"]]
            elif key == "script" and isinstance(val, dict):
                for sid, s in val.items():
                    out += ["", "SCRIPT: %s (%s)" % (s.get("alias", sid), sid), "  %s" % s.get("description", "")]
                    out.append("  When you run it:")
                    for x in as_list(s.get("sequence")):
                        out.extend(act(x, 2))
            elif key in ("input_boolean", "input_text", "input_number") and isinstance(val, dict):
                out += ["", "%s: %s" % (key, TOP_LEVEL[key])]
                for k, v in val.items():
                    out.append("  - %s : %s" % (k, (v or {}).get("name", k)))
            else:
                out += ["", "%s: %s" % (key, TOP_LEVEL.get(key, "A setting block called '%s'." % key))]
                if isinstance(val, dict) and key in ("http", "recorder", "logger"):
                    for k, v in val.items():
                        out.append("  - %s: %s" % (k, v))
    return out + _issues(issues)


def _issues(issues):
    return ([""] + ["WARNING: " + i for i in issues]) if issues else []


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print("Use: ha_explain.py FILE")
        return 0 if argv else 2
    if not os.path.isfile(argv[0]):
        print("I can't find %s" % argv[0], file=sys.stderr)
        return 2
    print("\n".join(narrate(argv[0])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
