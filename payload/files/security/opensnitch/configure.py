#!/usr/bin/env python3
"""Secure Linux: set OpenSnitch's daemon settings (/etc/opensnitchd/default-config.json). Idempotent.

usage: configure.py CONFIG_JSON PROC_MONITOR(ebpf|proc)
Prints "changed" when the file was rewritten, "unchanged" otherwise.

Keys (OpenSnitch 1.6-1.8 daemon/default-config.json, verified against the 1.8 source and wiki):
  DefaultAction   "allow"  what happens when no window can ask (before login, on the lite setup, or when the
                           window doesn't answer within the daemon's 120 s): never block what the user may need
  DefaultDuration "once"   (deprecated upstream, kept consistent): no rule is created by the default action
  InterceptUnknown false   connections without a known program aren't asked about
  ProcMonitorMethod        "ebpf" when the eBPF modules are installed, else "proc"
  LogLevel 2               "important" (keeps the log small)
  Firewall "nftables"; FwOptions.QueueBypass true = FAIL OPEN: if the daemon stops or crashes, packets are
                           accepted instead of queued to nobody, so the internet keeps working
  Rules.Path               /etc/opensnitchd/rules/
  Server.Loggers           syslog (local journal, RFC 5424, tag opensnitchd): one line per connection event; the
                           block notifier and the weekly summary read the "secure-linux-block" lines from it
"""
import json
import sys

path, monitor = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)
before = json.dumps(cfg, sort_keys=True)

cfg["DefaultAction"] = "allow"
cfg["DefaultDuration"] = "once"
cfg["InterceptUnknown"] = False
cfg["ProcMonitorMethod"] = monitor if monitor in ("ebpf", "proc", "audit") else "proc"
cfg["LogLevel"] = 2
cfg["Firewall"] = "nftables"
fw = cfg.setdefault("FwOptions", {})
fw["QueueBypass"] = True
fw.setdefault("ConfigPath", "/etc/opensnitchd/system-fw.json")
fw.setdefault("MonitorInterval", "15s")
cfg.setdefault("Rules", {})["Path"] = "/etc/opensnitchd/rules/"
server = cfg.setdefault("Server", {})
loggers = [l for l in server.get("Loggers") or [] if l.get("Tag") != "opensnitchd-secure-linux"]
loggers.append({"Name": "syslog", "Server": "", "Protocol": "", "Format": "rfc5424",
                "Tag": "opensnitchd-secure-linux", "Workers": 1})
server["Loggers"] = loggers

if json.dumps(cfg, sort_keys=True) != before:
    with open(path, "w") as f:
        json.dump(cfg, f, indent=4)
        f.write("\n")
    print("changed")
else:
    print("unchanged")
