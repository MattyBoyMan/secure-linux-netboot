#!/usr/bin/env python3
"""Secure Linux: read OpenSnitch block events (used by secure-linux-netguard).

  events.py parse                 read OpenSnitch log lines on stdin, print "LIST|HOST|APP" for each connection
                                  blocked by a Secure Linux list (flushes every line: used live by the notifier)
  events.py summary --db FILE     weekly summary from the OpenSnitch window's statistics database (sqlite,
                                  table "connections": time, action, dst_host, process, rule ...)
  events.py summary --journal     weekly summary from log lines on stdin (journalctl -t opensnitchd-secure-linux)
     options: --days N (default 7)   prints JSON {"count": N, "top": [[host, n], ...], "lists": {list: n}}

The daemon's syslog logger writes RFC 5424 structured data; the exact key names are not documented, so the
parser accepts KEY="value", key=value and JSON ("key": "value") spellings of the destination host, process
and rule name (VERIFY on a real machine with: journalctl -t opensnitchd-secure-linux -n 5).
"""
import json
import re
import sqlite3
import sys
from collections import Counter
from datetime import datetime, timedelta
from pathlib import Path

RULE_RE = re.compile(r"100-secure-linux-block-(threats|trackers|telemetry)")


def field(line, *names):
    for n in names:
        for pat in (r'(?i)\b%s\s*=\s*"([^"]*)"' % n, r'(?i)"%s"\s*:\s*"([^"]*)"' % n, r'(?i)\b%s\s*=\s*([^\s,\]"]+)' % n):
            m = re.search(pat, line)
            if m and m.group(1):
                return m.group(1)
    return ""


def parse_line(line):
    m = RULE_RE.search(line)
    if not m:
        return None
    host = field(line, "dst_host", "dsthost", "DSTHOST", "host")
    if not host:
        host = field(line, "dst_ip", "dstip", "DSTIP", "dst")
    app = field(line, "process_path", "process", "PROCESS", "proc_path", "path")
    host = re.sub(r"[^A-Za-z0-9._:-]", "", host).lower()
    app = re.sub(r"[|\n]", "", app)
    return m.group(1), host, app


def summarize(events):
    hosts, lists = Counter(), Counter()
    for lst, host, _ in events:
        lists[lst] += 1
        if host:
            hosts[host] += 1
    return {"count": sum(lists.values()), "top": hosts.most_common(3), "lists": dict(lists)}


def main():
    a = sys.argv[1:]
    if not a or a[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if a[0] == "parse":
        for line in sys.stdin:
            ev = parse_line(line)
            if ev:
                print("|".join(ev), flush=True)
        return 0
    if a[0] == "summary":
        days = int(a[a.index("--days") + 1]) if "--days" in a else 7
        cutoff = datetime.now() - timedelta(days=days)
        events = []
        if "--db" in a:
            db = a[a.index("--db") + 1]
            con = sqlite3.connect(Path(db).resolve().as_uri() + "?mode=ro", uri=True)
            rows = con.execute("SELECT time, rule, dst_host, dst_ip, process FROM connections "
                               "WHERE rule LIKE '100-secure-linux-block-%' AND time >= ?",
                               (cutoff.strftime("%Y-%m-%d %H:%M:%S"),))
            for _t, rule, host, ip, proc in rows:
                m = RULE_RE.search(rule or "")
                if m:
                    events.append((m.group(1), (host or ip or "").lower(), proc or ""))
        else:  # --journal: caller already limited the time range (journalctl --since)
            for line in sys.stdin:
                ev = parse_line(line)
                if ev:
                    events.append(ev)
        print(json.dumps(summarize(events)))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
