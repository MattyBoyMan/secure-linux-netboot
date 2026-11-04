#!/usr/bin/env python3
"""Secure Linux: write the OpenSnitch allow rules that depend on this computer. Idempotent (prints changed/unchanged).

  genrules.py immich URL OUT_DIR
      Allow the home server (Immich) named in URL. A server given by a private/LAN IP address needs no rule
      (the local-network rule covers it); a server given by a public name or address gets its own rule
      000-secure-linux-allow-immich.json. Any older rule of that name is removed when URL is empty or private.

  genrules.py apps OUT_DIR [--flatpaks FILE] [--desktop DIR]... [--path DIR]...
      Pre-approve everything installed right now: Flatpak application IDs (one per line in FILE) and the
      programs started by the *.desktop menu entries in each DIR (looked up in the --path folders). Programs
      that run other programs (shells, interpreters, sudo) are never added. Written once at install time;
      programs installed LATER are asked about once, as designed.
"""
import ipaddress
import json
import os
import re
import sys
from urllib.parse import urlparse

NEVER = {"env", "sh", "bash", "zsh", "fish", "dash", "python", "python3", "perl", "ruby", "node", "java", "php",
         "pkexec", "sudo", "su", "xdg-open", "flatpak", "snap", "nc", "ncat", "socat", "ssh", "telnet", "busybox",
         "gdb", "strace", "lua", "wish", "tclsh", "pwsh", "dotnet", "mono"}
STAMP = "2026-11-03T00:00:00Z"


def write_rule(path, rule):
    text = json.dumps(rule, indent=2) + "\n"
    try:
        with open(path) as f:
            if f.read() == text:
                print("unchanged")
                return
    except OSError:
        pass
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, 0o644)
    print("changed")


def base_rule(name, description, op, precedence):
    return {"created": STAMP, "updated": STAMP, "name": name, "description": description, "enabled": True,
            "precedence": precedence, "nolog": True, "action": "allow", "duration": "always", "operator": op}


def immich(url, out_dir):
    name = "000-secure-linux-allow-immich"
    path = os.path.join(out_dir, name + ".json")
    host = ""
    if url:
        u = urlparse(url if "://" in url else "http://" + url)
        host = (u.hostname or "").lower()
    if not re.fullmatch(r"[a-z0-9.-]+|[0-9a-f:]+", host or "x!"):
        host = ""
    is_ip = False
    if host:
        try:
            ip = ipaddress.ip_address(host)
            is_ip = True
            if ip.is_private or ip.is_loopback or ip.is_link_local or ip in ipaddress.ip_network("100.64.0.0/10"):
                host = ""
        except ValueError:
            if host.endswith((".lan", ".local", ".home", ".internal")) or "." not in host:
                host = ""   # local names resolve to LAN addresses, which the local-network rule allows
    if not host:
        if os.path.exists(path):
            os.remove(path)
            print("changed")
        else:
            print("unchanged")
        return
    op = {"type": "simple", "operand": "dest.ip" if is_ip else "dest.host", "sensitive": False, "data": host,
          "list": []}
    write_rule(path, base_rule(name, "Secure Linux: always allow your photo server (Immich) at " + host, op, True))


def desktop_programs(ddir, path_dirs):
    progs = set()
    try:
        names = sorted(os.listdir(ddir))
    except OSError:
        return progs
    for n in names:
        if not n.endswith(".desktop"):
            continue
        try:
            with open(os.path.join(ddir, n), encoding="utf-8", errors="replace") as f:
                lines = f.read().splitlines()
        except OSError:
            continue
        sect, typ, ex = None, "", ""
        for ln in lines:
            if ln.startswith("["):
                sect = ln.strip()
            elif sect == "[Desktop Entry]" and ln.startswith("Exec=") and not ex:
                ex = ln[5:].strip()
            elif sect == "[Desktop Entry]" and ln.startswith("Type="):
                typ = ln[5:].strip()
        if typ != "Application" or not ex:
            continue
        tok = ex.split()[0].strip('"')
        if tok.startswith("%"):
            continue
        if "/" not in tok:
            tok = next((os.path.join(d, tok) for d in path_dirs if os.path.exists(os.path.join(d, tok))), "")
        if not tok.startswith("/") or os.path.basename(tok) in NEVER:
            continue
        if re.search(r'[\s"\\]', tok):
            continue
        progs.add(tok)
        # Fedora's /usr/bin and /usr/sbin are the same folder; /bin and /sbin are links to them
        for a, b in (("/usr/bin/", "/bin/"), ("/usr/sbin/", "/sbin/")):
            if tok.startswith(b):
                progs.add(a + tok[len(b):])
    return progs


def apps(out_dir, flat_file, ddirs, path_dirs):
    ids = set()
    if flat_file and os.path.exists(flat_file):
        with open(flat_file) as f:
            ids = {l.strip() for l in f if re.fullmatch(r"[A-Za-z0-9_.-]+", l.strip())}
    progs = set()
    for d in ddirs:
        progs |= desktop_programs(d, path_dirs)
    # One rule per operand: a "list" operator would need BOTH conditions to be true
    for suffix, operand, items in (("flatpak", "process.env.FLATPAK_ID", ids), ("programs", "process.path", progs)):
        name = "050-secure-linux-installed-" + suffix
        path = os.path.join(out_dir, name + ".json")
        if not items:
            if os.path.exists(path):
                os.remove(path)
                print("changed")
            else:
                print("unchanged")
            continue
        rx = "^(" + "|".join(sorted(re.escape(i) for i in items)) + ")$"
        op = {"type": "regexp", "operand": operand, "sensitive": False, "data": rx, "list": []}
        write_rule(path, base_rule(name, "Secure Linux: allow what was already installed when the computer was set up (%s)" % suffix, op, False))


def main():
    a = sys.argv[1:]
    if not a or a[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if a[0] == "immich" and len(a) == 3:
        immich(a[1], a[2])
        return 0
    if a[0] == "apps" and len(a) >= 2:
        flat, dd, pd, i = "", [], [], 2
        while i < len(a):
            if a[i] == "--flatpaks":
                flat = a[i + 1]
            elif a[i] == "--desktop":
                dd.append(a[i + 1])
            elif a[i] == "--path":
                pd.append(a[i + 1])
            i += 2
        apps(a[1], flat, dd, pd or ["/usr/bin", "/usr/local/bin", "/usr/sbin"])
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
