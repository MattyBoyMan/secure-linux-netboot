#!/usr/bin/env python3
"""Read-only, local-only data collection for My Computer Activity.

Every collector returns a consistent card dictionary.  A failed or missing data
source is represented as unavailable; no collector substitutes example values.
Commands are fixed argument lists, run without a shell, with a short timeout.
No network request, packet capture, DNS lookup, or content inspection is made.
"""

from __future__ import annotations

import copy
import datetime as _datetime
import getpass
import html
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from dataclasses import dataclass
from typing import Any, Iterable

SCHEMA = 1
MAX_ROWS = 100
SECTION_ORDER = (
    "network", "firewall", "services", "updates", "disk", "resources",
    "logins", "devices", "containers", "recovery", "security",
)
TITLES = {
    "network": "Current network connections",
    "firewall": "Firewall & OpenSnitch alerts",
    "services": "Secure Linux background jobs",
    "updates": "Updates & scheduled runs",
    "disk": "Disk space & SMART health",
    "resources": "CPU, memory & storage",
    "logins": "Recent logins & admin actions",
    "devices": "USB & device events",
    "containers": "Docker & Home Assistant",
    "recovery": "Backup, install & recovery",
    "security": "Security findings & your next steps",
}
ACTIONS = {
    "network": ("Open Network Monitor", "opensnitch"),
    "firewall": ("Open Network Monitor", "opensnitch"),
    "services": ("Open Status & Fixes", "status"),
    "updates": ("Open Status & Fixes", "status"),
    "disk": ("Open Hardware Health", "health"),
    "resources": ("Open System Monitor", "resources"),
    "logins": ("Open Status & Fixes", "status"),
    "devices": ("Open Hardware Health", "health"),
    "containers": ("Open Home Assistant", "homeassistant"),
    "recovery": ("Open Pika Backup", "backup"),
    "security": ("Review in Status & Fixes", "status"),
}


def _now() -> str:
    return _datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def _clean(value: Any, limit: int = 2000) -> str:
    """Make command/log output safe for a single GUI or report cell."""
    text = str(value).replace("\x00", "�")
    text = "".join(ch if ch in "\n\t" or ord(ch) >= 32 else "?" for ch in text)
    return text.strip()[:limit]


def _row(label: Any, value: Any) -> dict[str, str]:
    return {"label": _clean(label, 300), "value": _clean(value)}


def _section(
    key: str, status: str, summary: str, rows: Iterable[dict[str, str]] = (),
    notes: Iterable[str] = (), **data: Any,
) -> dict[str, Any]:
    action, action_key = ACTIONS[key]
    return {
        "id": key,
        "title": TITLES[key],
        "status": status if status in {"ok", "info", "warn", "bad", "unknown"} else "unknown",
        "summary": _clean(summary, 600),
        "rows": list(rows)[:MAX_ROWS],
        "notes": [_clean(note, 800) for note in notes if _clean(note, 800)],
        "action_label": action,
        "action": action_key,
        **data,
    }


def _unavailable(key: str, reason: str, extra: Iterable[str] = ()) -> dict[str, Any]:
    return _section(
        key, "unknown", "Unavailable — " + _clean(reason, 350),
        notes=[
            "Nothing has been estimated or filled in. This card will update after a refresh if the information becomes readable.",
            *extra,
        ],
    )


@dataclass
class CommandResult:
    code: int | None
    stdout: str = ""
    stderr: str = ""
    error: str = ""

    @property
    def ok(self) -> bool:
        return self.code == 0

    def reason(self) -> str:
        text = _clean(self.error or self.stderr or self.stdout, 350)
        if self.code is None:
            return text or "the command could not be run"
        if _is_permission(text):
            return "permission is needed to read this information"
        return text or f"the command exited with status {self.code}"


def _is_permission(text: str) -> bool:
    return bool(re.search(
        r"permission denied|operation not permitted|access denied|authentication|not authorized|insufficient privileges",
        text, re.IGNORECASE,
    ))


class LocalRunner:
    """Small injectable command runner; deliberately has no shell option."""

    def run(self, args: list[str], timeout: float = 4.0) -> CommandResult:
        if not args or not isinstance(args[0], str):
            return CommandResult(None, error="No command was supplied")
        if shutil.which(args[0]) is None:
            return CommandResult(None, error=f"{args[0]} is not installed")
        env = os.environ.copy()
        env.update({"LC_ALL": "C", "LANG": "C"})
        try:
            result = subprocess.run(
                args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True, errors="replace",
                timeout=timeout, env=env, check=False,
            )
            return CommandResult(
                result.returncode, result.stdout[:2_000_000],
                result.stderr[:100_000],
            )
        except subprocess.TimeoutExpired:
            return CommandResult(None, error=f"{args[0]} took too long to answer")
        except PermissionError:
            return CommandResult(None, error="Permission denied")
        except OSError as exc:
            return CommandResult(None, error=_clean(exc.strerror or exc, 250))

    def which(self, command: str) -> str | None:
        return shutil.which(command)


class ActivityCollector:
    """Collect only metadata already exposed by the local operating system."""

    def __init__(
        self, runner: Any | None = None,
        state_dir: str | os.PathLike[str] | None = None,
        log_dir: str | os.PathLike[str] | None = None,
        etc_dir: str | os.PathLike[str] | None = None,
        proc_dir: str | os.PathLike[str] | None = None,
        home: str | os.PathLike[str] | None = None,
    ) -> None:
        self.runner = runner or LocalRunner()
        self.state = Path(state_dir or os.environ.get("SL_STATE", "/var/lib/secure-linux"))
        self.logs = Path(log_dir or os.environ.get("SL_LOGDIR", "/var/log/secure-linux"))
        self.etc = Path(etc_dir or os.environ.get("SL_ETC", "/etc/secure-linux"))
        self.proc = Path(proc_dir or os.environ.get("SL_ACTIVITY_PROC", "/proc"))
        self.home = Path(home or Path.home())

    def _run(self, *args: str, timeout: float = 4.0) -> CommandResult:
        return self.runner.run(list(args), timeout=timeout)

    @staticmethod
    def _service_state(result: CommandResult) -> str:
        reported = _clean(result.stdout, 80)
        if reported in {"active", "inactive", "failed", "activating", "deactivating", "reloading"}:
            return reported
        if re.search(r"not found|does not exist|could not be found", result.stderr, re.I):
            return "not installed"
        return "unavailable — " + result.reason()

    def _read(self, path: Path, limit: int = 500_000) -> str:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            return handle.read(limit)

    @staticmethod
    def _read_error(exc: OSError) -> str:
        if isinstance(exc, PermissionError):
            return "permission is needed to read this information"
        return _clean(exc.strerror or exc, 250)

    def collect(self) -> dict[str, Any]:
        collectors = {
            "network": self.network,
            "firewall": self.firewall,
            "services": self.services,
            "updates": self.updates,
            "disk": self.disk,
            "resources": self.resources,
            "logins": self.logins,
            "devices": self.devices,
            "containers": self.containers,
            "recovery": self.recovery,
            "security": self.security,
        }
        sections = []
        for key in SECTION_ORDER:
            try:
                sections.append(collectors[key]())
            except Exception as exc:  # a broken source must not blank the whole dashboard
                sections.append(_unavailable(
                    key, "this information could not be read safely",
                    [f"Local collector error: {type(exc).__name__}"],
                ))
        usernames = set()
        for candidate in (getpass.getuser(), os.environ.get("USER", ""), os.environ.get("LOGNAME", "")):
            if candidate and candidate not in {"unknown", "root"}:
                usernames.add(candidate)
        try:
            configured = self._read(self.etc / "user", 100).strip()
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]{0,31}", configured):
                usernames.add(configured)
        except OSError:
            pass
        return {
            "schema": SCHEMA,
            "generated_at": _now(),
            "demo": False,
            "collection": "local read-only metadata; no network requests or content inspection",
            "privacy": {"usernames": sorted(usernames)},
            "sections": sections,
        }

    # ---------------------------------------------------------------- network
    def network(self) -> dict[str, Any]:
        result = self._run("ss", "-H", "-tupn")
        if not result.ok:
            return _unavailable("network", result.reason())
        rows, malformed = [], 0
        for line in result.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.split()
            if len(parts) < 6:
                malformed += 1
                continue
            protocol, state, local, destination = parts[0], parts[1], parts[4], parts[5]
            if ":" not in destination:
                malformed += 1
                continue
            process_match = re.search(r'users:\(\("([^"]+)"', line)
            process = process_match.group(1) if process_match else "Process name unavailable (permissions)"
            rows.append(_row(f"{process} · {protocol.upper()} · {state}", f"destination {destination}; local {local}"))
        notes = [
            "Only connection metadata is shown. Packet contents, browsing history and DNS lookups are not inspected.",
            f"Local addresses are included in the detailed local view only when available; {len(rows)} records are listed.",
        ]
        if malformed:
            notes.append(f"{malformed} malformed or incomplete line(s) were skipped.")
        status = "info" if rows or not malformed else "unknown"
        summary = (f"{len(rows)} current connection(s) reported by the system" if rows
                   else "No current connections reported" if not malformed
                   else "Connection details are unavailable because the system output was not understood")
        return _section("network", status, summary, rows, notes)

    # --------------------------------------------------------------- firewall
    def firewall(self) -> dict[str, Any]:
        rows, notes = [], []
        states = {}
        for service in ("firewalld", "ufw", "opensnitchd"):
            result = self._run("systemctl", "is-active", service)
            states[service] = self._service_state(result)
            rows.append(_row(service, states[service]))
        ufw = self._run("ufw", "status")
        ufw_active = bool(ufw.ok and re.search(r"Status:\s*active", ufw.stdout, re.I))
        if ufw.ok:
            rows.append(_row("UFW firewall", "active" if ufw_active else "inactive"))
        ufw_component_active = ufw_active if ufw.ok else states.get("ufw") == "active"
        firewall_active = states.get("firewalld") == "active" or ufw_component_active or states.get("opensnitchd") == "active"
        opensnitch = self._run(
            "journalctl", "-u", "opensnitchd", "--since", "24 hours ago",
            "-n", "80", "--no-pager", "-o", "short-iso",
        )
        alerts = []
        if opensnitch.ok:
            alerts = [line for line in opensnitch.stdout.splitlines()
                      if re.search(r"\b(deny|denied|block|blocked|reject|rejected|alert)\b", line, re.I)]
            rows.extend(_row("Recent OpenSnitch alert", line) for line in alerts[-25:])
            if not alerts:
                notes.append("No alert lines were found in the accessible OpenSnitch journal for the last 24 hours. This is not a guarantee that no alert occurred.")
        else:
            notes.append("OpenSnitch alert history unavailable: " + opensnitch.reason())
        notes.append("Opening Network Monitor is optional. This dashboard never pauses or changes the firewall.")
        if firewall_active:
            status, summary = "ok", "A supported firewall is active"
        elif not ufw.ok and not any(value in {"active", "inactive", "failed", "activating", "deactivating", "reloading", "not installed"} for value in states.values()):
            status, summary = "unknown", "Firewall state is unavailable"
        else:
            status, summary = "bad", "No supported firewall reported itself active"
        if states.get("opensnitchd") == "active":
            summary += "; OpenSnitch is running"
        return _section("firewall", status, summary, rows, notes)

    # --------------------------------------------------------------- services
    @staticmethod
    def _human_unit(unit: str) -> str:
        known = {
            "secure-linux-check": "Computer health check",
            "secure-linux-clamscan": "Virus scan",
            "secure-linux-scan": "Virus scan",
            "secure-linux-health": "Hardware health check",
            "secure-linux-flatpak-update": "App updates",
            "secure-linux-snapshot": "System snapshot",
            "secure-linux-netguard-lists": "Network protection list update",
            "secure-linux-netguard-summary": "Network protection summary",
            "secure-linux-notify": "Notifications",
            "secure-linux-autofix": "Automatic hardware checks",
        }
        base = re.sub(r"\.(service|timer|path|socket)$", "", unit)
        return known.get(base, base.replace("secure-linux-", "").replace("-", " ").strip().capitalize() or unit)

    def services(self) -> dict[str, Any]:
        rows, unit_states, enabled_timers, notes = [], {}, 0, []
        readable_scope = False
        for scope, user_flags in (("System", []), ("User", ["--user"])):
            prefix = ["systemctl", *user_flags]
            units = self._run(*prefix, "list-unit-files", "secure-linux*", "--no-legend", "--no-pager")
            active = self._run(*prefix, "list-units", "secure-linux*", "--all", "--no-legend", "--no-pager")
            timers = self._run(*prefix, "list-timers", "secure-linux*", "--all", "--no-legend", "--no-pager")
            readable_scope = readable_scope or units.ok or active.ok
            if units.ok:
                for line in units.stdout.splitlines():
                    parts = line.split()
                    if len(parts) >= 2 and parts[0].startswith("secure-linux"):
                        unit_states[(scope, parts[0])] = {"enabled": parts[1], "active": "not currently running"}
            if active.ok:
                for line in active.stdout.splitlines():
                    parts = line.split()
                    if len(parts) >= 4 and parts[0].startswith("secure-linux"):
                        unit_states.setdefault((scope, parts[0]), {"enabled": "unknown", "active": parts[3]})
                        unit_states[(scope, parts[0])]["active"] = parts[3]
            if timers.ok:
                for line in timers.stdout.splitlines():
                    if "secure-linux" not in line:
                        continue
                    rows.append(_row(f"{scope} schedule", line))
                    enabled_timers += 1
            else:
                notes.append(f"{scope} timer schedule unavailable: " + timers.reason())
            journal_prefix = ["journalctl", *user_flags]
            history = self._run(*journal_prefix, "-u", "secure-linux*", "-n", "60", "--no-pager", "-o", "short-iso")
            if history.ok:
                rows.extend(_row(f"Recent {scope.lower()} job history", line) for line in history.stdout.splitlines()[-40:])
            else:
                notes.append(f"{scope} job history unavailable: " + history.reason())
        if not readable_scope:
            return _unavailable("services", "neither system nor user Secure Linux units are readable")
        for scope, unit in sorted(unit_states):
            state = unit_states[(scope, unit)]
            rows.append(_row(f"{scope}: {self._human_unit(unit)} ({unit})", f"{state['active']}; {state['enabled']}"))
        running = sum(1 for state in unit_states.values() if state["active"] in {"active", "activating", "reloading"})
        notes.append("Every discovered Secure Linux system and per-user unit is listed, including inactive one-shot jobs. Journal history appears when your account may read it.")
        return _section(
            "services", "info", f"{running} running now; {enabled_timers} scheduled timer(s) found",
            rows, notes,
        )

    # ---------------------------------------------------------------- updates
    def updates(self) -> dict[str, Any]:
        timers = self._run("systemctl", "list-timers", "--all", "--no-legend", "--no-pager")
        units = self._run("systemctl", "list-units", "--all", "--no-legend", "--no-pager")
        if not timers.ok and not units.ok:
            return _unavailable("updates", timers.reason() or units.reason())
        pattern = re.compile(r"apt-daily|dnf-automatic|rpm-ostreed-automatic|secure-linux-flatpak-update|unattended-upgrade")
        rows = []
        next_count = 0
        if timers.ok:
            for line in timers.stdout.splitlines():
                if pattern.search(line):
                    rows.append(_row("Update schedule", line))
                    next_count += 1
        else:
            rows.append(_row("Next scheduled run", "Unavailable — " + timers.reason()))
        if timers.ok and next_count == 0:
            rows.append(_row("Next scheduled run", "No supported update timer was found"))
        if units.ok:
            for line in units.stdout.splitlines():
                if pattern.search(line):
                    rows.append(_row("Last update job state", line))
        else:
            rows.append(_row("Last update job state", "Unavailable — " + units.reason()))
        if not any(row["label"] == "Last update job state" for row in rows):
            rows.append(_row("Last update job state", "No supported update unit state was found"))
        stamps = [
            Path("/var/lib/apt/periodic/update-success-stamp"),
            Path("/var/log/dnf.log"), Path("/var/log/dnf5.log"),
            self.state / "checks.time",
        ]
        for path in stamps:
            try:
                modified = _datetime.datetime.fromtimestamp(path.stat().st_mtime).astimezone()
                rows.append(_row(f"Recorded timestamp: {path}", modified.isoformat(timespec="seconds")))
            except FileNotFoundError:
                continue
            except OSError as exc:
                rows.append(_row(f"Recorded timestamp: {path}", "Unavailable — " + self._read_error(exc)))
        rows.append(_row("Update availability", "Not checked — refreshing this dashboard makes no network request"))
        return _section(
            "updates", "info", f"{next_count} update schedule(s) found; last run details are below when recorded",
            rows, ["Times come from local systemd and package-manager records. No update check is started."],
        )

    # ------------------------------------------------------------------- disk
    def disk(self) -> dict[str, Any]:
        df = self._run("df", "-P", "-B1")
        lsblk = self._run("lsblk", "-J", "-b", "-o", "NAME,MODEL,SIZE,FSTYPE,MOUNTPOINTS,TYPE")
        if not df.ok and not lsblk.ok:
            return _unavailable("disk", df.reason() or lsblk.reason())
        rows, root_percent = [], None
        if df.ok:
            for line in df.stdout.splitlines()[1:]:
                parts = line.split()
                if len(parts) < 6:
                    continue
                source, size, used, avail, percent = parts[0], parts[-5], parts[-4], parts[-3], parts[-2]
                target = " ".join(parts[5:-4]) if len(parts) > 6 else parts[-1]
                # POSIX df is source size used avail capacity mount; prefer the final mount field.
                target = parts[-1]
                rows.append(_row(f"Storage: {target}", f"{percent} used; {avail} bytes available; device {source}"))
                if target == "/":
                    root_percent = percent
        else:
            rows.append(_row("Storage use", "Unavailable — " + df.reason()))
        if lsblk.ok:
            try:
                data = json.loads(lsblk.stdout)
                for device in data.get("blockdevices", [])[:30]:
                    if not isinstance(device, dict):
                        continue
                    label = device.get("name", "unnamed device")
                    rows.append(_row(
                        f"Disk: {label}",
                        f"model {device.get('model') or 'unavailable'}; {device.get('size') or 'unknown'} bytes; type {device.get('type') or 'unknown'}",
                    ))
            except (json.JSONDecodeError, AttributeError, TypeError):
                rows.append(_row("Disk list", "Unavailable — lsblk returned malformed JSON"))
        else:
            rows.append(_row("Disk list", "Unavailable — " + lsblk.reason()))
        smart_states = []
        scan = self._run("smartctl", "--scan")
        if scan.ok:
            devices = [line.split() for line in scan.stdout.splitlines() if line.strip().startswith("/dev/")]
            for parts in devices[:8]:
                args = ["smartctl", "-H", "-j"]
                if len(parts) >= 3 and parts[1] == "-d":
                    args += ["-d", parts[2]]
                args.append(parts[0])
                health = self._run(*args)
                state = "unavailable"
                if health.ok:
                    try:
                        passed = json.loads(health.stdout).get("smart_status", {}).get("passed")
                        state = "passed" if passed is True else "failed" if passed is False else "not reported"
                    except (json.JSONDecodeError, AttributeError, TypeError):
                        if "PASSED" in health.stdout:
                            state = "passed"
                        elif "FAILED" in health.stdout:
                            state = "failed"
                else:
                    state = "unavailable — " + health.reason()
                smart_states.append(state)
                rows.append(_row(f"SMART: {parts[0]}", state))
        else:
            rows.append(_row("SMART disk self-health", "Unavailable — " + scan.reason()))
        if any(state == "failed" for state in smart_states):
            status, smart_summary = "bad", "a disk reports a SMART failure"
        elif smart_states and all(state == "passed" for state in smart_states):
            status, smart_summary = "ok", "all readable disks report SMART passed"
        else:
            status, smart_summary = "info", "SMART health is partly or wholly unavailable"
        summary = (f"Root storage {root_percent} used; " if root_percent else "") + smart_summary
        return _section("disk", status, summary, rows, ["SMART is a disk self-report, not a guarantee against failure. Keep backups."])

    # --------------------------------------------------------------- resources
    def resources(self) -> dict[str, Any]:
        rows = []
        try:
            meminfo = {}
            for line in self._read(self.proc / "meminfo", 100_000).splitlines():
                key, _, rest = line.partition(":")
                value = rest.strip().split()
                if value and value[0].isdigit():
                    meminfo[key] = int(value[0]) * 1024
            total = meminfo["MemTotal"]
            available = meminfo.get("MemAvailable", meminfo.get("MemFree", 0))
            used = max(0, total - available)
            percent = round(used * 100 / total) if total else None
            rows += [_row("Memory total", f"{total} bytes"), _row("Memory available", f"{available} bytes")]
            mem_summary = f"{percent}% memory used" if percent is not None else "memory use unavailable"
        except (OSError, KeyError, ValueError) as exc:
            percent = None
            mem_summary = "memory use unavailable"
            rows.append(_row("Memory", "Unavailable — " + (self._read_error(exc) if isinstance(exc, OSError) else "malformed /proc/meminfo")))
        try:
            loads = self._read(self.proc / "loadavg", 1000).split()
            load_text = ", ".join(loads[:3]) if len(loads) >= 3 else "malformed load average"
            rows.append(_row("CPU load (1, 5 and 15 minutes)", load_text))
        except OSError as exc:
            rows.append(_row("CPU load", "Unavailable — " + self._read_error(exc)))
        rows.append(_row("Logical CPU count", os.cpu_count() or "unavailable"))
        try:
            usage = shutil.disk_usage(self.proc.parent if str(self.proc) != "/proc" else "/")
            root_percent = round(usage.used * 100 / usage.total) if usage.total else None
            rows.append(_row("Main filesystem", f"{usage.used} of {usage.total} bytes used; {usage.free} bytes free"))
            storage_summary = f"{root_percent}% storage used" if root_percent is not None else "storage use unavailable"
        except OSError as exc:
            rows.append(_row("Main filesystem", "Unavailable — " + self._read_error(exc)))
            storage_summary = "storage use unavailable"
        status = "unknown" if percent is None else "warn" if percent >= 90 else "ok"
        return _section("resources", status, f"{mem_summary}; {storage_summary}", rows,
                        ["CPU load is a demand indicator, not a percentage. No process is stopped or changed."])

    # ------------------------------------------------------------------ logins
    def logins(self) -> dict[str, Any]:
        last = self._run("last", "-n", "20", "-F", "-w")
        sudo = self._run("journalctl", "--no-pager", "-n", "50", "-o", "short-iso", "_COMM=sudo")
        if not last.ok and not sudo.ok:
            return _unavailable("logins", "login and administrator logs are not readable", [sudo.reason(), last.reason()])
        rows = []
        login_lines = [line for line in last.stdout.splitlines() if line.strip()] if last.ok else []
        rows.extend(_row("Recorded login", line) for line in login_lines)
        sudo_lines = [line for line in sudo.stdout.splitlines() if line.strip()] if sudo.ok else []
        rows.extend(_row("Recorded sudo/admin action", line) for line in sudo_lines)
        notes = [
            "These are local login and sudo journal records, not a live monitor. Log retention varies by system.",
            "Exported reports redact account names and network addresses by default.",
        ]
        if not last.ok:
            notes.append("Login history unavailable: " + last.reason())
        if not sudo.ok:
            notes.append("Administrator history unavailable: " + sudo.reason())
        summary = f"{len(login_lines)} recent login record(s); {len(sudo_lines)} sudo record(s) accessible"
        return _section("logins", "info", summary, rows, notes)

    # ----------------------------------------------------------------- devices
    def devices(self) -> dict[str, Any]:
        lsusb = self._run("lsusb")
        journal = self._run("journalctl", "-k", "--since", "7 days ago", "-n", "300", "--no-pager", "-o", "short-iso")
        if not lsusb.ok and not journal.ok:
            return _unavailable("devices", "USB and device information is not readable", [lsusb.reason(), journal.reason()])
        rows = []
        usb_lines = [line for line in lsusb.stdout.splitlines() if line.strip()] if lsusb.ok else []
        rows.extend(_row("Connected USB device", line) for line in usb_lines)
        event_lines = []
        if journal.ok:
            event_lines = [line for line in journal.stdout.splitlines()
                           if re.search(r"\b(usb|udev|removable|thunderbolt)\b", line, re.I)]
            rows.extend(_row("Recent device event", line) for line in event_lines[-60:])
        notes = ["Device events come from the accessible kernel journal for the last seven days. No device is opened or modified."]
        if not lsusb.ok:
            notes.append("Current USB device list unavailable: " + lsusb.reason())
        if not journal.ok:
            notes.append("Device event history unavailable: " + journal.reason())
        return _section("devices", "info", f"{len(usb_lines)} USB device(s) connected; {len(event_lines[-60:])} recent event line(s)", rows, notes)

    # --------------------------------------------------------------- containers
    def containers(self) -> dict[str, Any]:
        rows, active_services, notes = [], [], []
        for scope, flags in (("System", []), ("User", ["--user"])):
            for service in ("docker", "podman", "secure-linux-homeassistant", "homeassistant"):
                result = self._run("systemctl", *flags, "is-active", service)
                state = self._service_state(result)
                rows.append(_row(f"{scope}: {service}", state))
                if state == "active":
                    active_services.append(f"{scope.lower()}:{service}")
        for engine in ("docker", "podman"):
            result = self._run(engine, "ps", "--format", "{{.Names}}\t{{.Image}}\t{{.Status}}")
            if result.ok:
                lines = [line for line in result.stdout.splitlines() if line.strip()]
                rows.extend(_row(f"Running {engine} container", line) for line in lines)
                if not lines:
                    rows.append(_row(f"Running {engine} containers", "None reported"))
            else:
                rows.append(_row(f"{engine} containers", "Unavailable — " + result.reason()))
        notes.append("Only local service/container state is read. Home Assistant is not contacted and no container environment variables or secrets are shown.")
        if active_services:
            summary = "Running: " + ", ".join(active_services)
            status = "ok"
        else:
            summary = "No supported Docker or Home Assistant service reported itself active"
            status = "info"
        return _section("containers", status, summary, rows, notes)

    # ----------------------------------------------------------------- recovery
    @staticmethod
    def _find_backup_times(value: Any, found: list[str]) -> None:
        if isinstance(value, dict):
            outcome = json.dumps(value.get("outcome", value.get("result", "")))
            if value.get("end") and "Completed" in outcome:
                found.append(str(value["end"]))
            last = value.get("last_completed")
            if isinstance(last, dict) and last.get("end"):
                found.append(str(last["end"]))
            for child in value.values():
                ActivityCollector._find_backup_times(child, found)
        elif isinstance(value, list):
            for child in value:
                ActivityCollector._find_backup_times(child, found)

    def recovery(self) -> dict[str, Any]:
        rows, notes = [], []
        try:
            progress = _clean(self._read(self.state / "progress", 2000), 500)
            rows.append(_row("Install/setup state", progress.replace("|", " — ")))
            progress_summary = progress
        except FileNotFoundError:
            progress_summary = "install state not recorded"
            rows.append(_row("Install/setup state", "Unavailable — no local progress record"))
        except OSError as exc:
            progress_summary = "install state unavailable"
            rows.append(_row("Install/setup state", "Unavailable — " + self._read_error(exc)))
        try:
            journal_lines = self._read(self.state / "setup-journal", 200_000).splitlines()
            safe_records = []
            for line in journal_lines:
                parts = line.split("|")
                if line == "secure-linux-setup-journal-v1":
                    continue
                if parts and parts[0] == "run" and len(parts) >= 3:
                    safe_records.append(f"run {parts[1]}; mode {parts[2]}")
                elif parts and parts[0] == "stage" and len(parts) >= 3:
                    safe_records.append(f"stage {parts[1]}; {parts[2]}")
            rows.extend(_row("Setup recovery journal", record) for record in safe_records[-30:])
            if not safe_records:
                rows.append(_row("Setup recovery journal", "No understandable status records; no state was inferred"))
        except FileNotFoundError:
            rows.append(_row("Setup recovery journal", "No interrupted setup journal is present"))
        except OSError as exc:
            rows.append(_row("Setup recovery journal", "Unavailable — " + self._read_error(exc)))
        pika = self.home / ".var/app/org.gnome.World.PikaBackup/config/pika-backup"
        backup_count = 0
        backup_times: list[str] = []
        try:
            config = json.loads(self._read(pika / "backup.json"))
            backup_count = len(config) if isinstance(config, (list, dict)) else 0
            rows.append(_row("Pika backup configurations", backup_count))
        except FileNotFoundError:
            rows.append(_row("Pika backup configurations", "Unavailable — no readable Pika configuration was found"))
        except (OSError, json.JSONDecodeError) as exc:
            rows.append(_row("Pika backup configurations", "Unavailable — " + (self._read_error(exc) if isinstance(exc, OSError) else "malformed JSON")))
        try:
            history = json.loads(self._read(pika / "history.json"))
            self._find_backup_times(history, backup_times)
            rows.append(_row("Last recorded completed backup", max(backup_times) if backup_times else "No completed time found in the readable history"))
        except FileNotFoundError:
            rows.append(_row("Backup history", "Unavailable — no readable Pika history was found"))
        except (OSError, json.JSONDecodeError) as exc:
            rows.append(_row("Backup history", "Unavailable — " + (self._read_error(exc) if isinstance(exc, OSError) else "malformed JSON")))
        notes.append("Restore work stays in Pika Backup or the existing recovery tools. This dashboard never starts a backup, restore, install or recovery operation.")
        return _section("recovery", "info", f"Setup: {progress_summary}; {backup_count} backup configuration(s) readable", rows, notes)

    # ----------------------------------------------------------------- security
    def security(self) -> dict[str, Any]:
        rows, notes = [], []
        alerts = []
        directories = [self.state / "alerts.d"]
        try:
            user = getpass.getuser()
            if user:
                directories.append(self.state / "user-alerts" / user)
        except Exception:
            pass
        for directory in directories:
            try:
                entries = sorted(directory.iterdir(), key=lambda p: p.name)[:50]
            except FileNotFoundError:
                continue
            except OSError as exc:
                notes.append(f"Pending actions in {directory} unavailable: {self._read_error(exc)}")
                continue
            for path in entries:
                if not path.is_file():
                    continue
                try:
                    lines = self._read(path, 12_000).splitlines()
                    title = lines[0] if lines else path.name
                    message = lines[1] if len(lines) > 1 else "No additional detail recorded"
                    hint = lines[2] if len(lines) > 2 else "Open Status & Fixes for guidance"
                    alerts.append(title)
                    rows.append(_row(f"Pending: {title}", f"{message}\nNext step: {hint}"))
                except OSError as exc:
                    rows.append(_row(f"Pending item {path.name}", "Unavailable — " + self._read_error(exc)))
        checks_path = self.state / "checks"
        try:
            for line in self._read(checks_path, 500_000).splitlines():
                parts = line.split("|", 4)
                if len(parts) == 5 and parts[1] in {"warn", "bad"}:
                    rows.append(_row(f"Security/health finding: {parts[2]}", f"{parts[1]} — {parts[3]}"))
        except FileNotFoundError:
            notes.append("The local health-check results are not present yet. No scan was started by this dashboard.")
        except OSError as exc:
            notes.append("Health-check findings unavailable: " + self._read_error(exc))
        try:
            scan_logs = sorted((self.logs / "clamscan").glob("*.log"), key=lambda p: p.stat().st_mtime, reverse=True)
            if scan_logs:
                lines = self._read(scan_logs[0], 1_000_000).splitlines()
                findings = [line for line in lines if "FOUND" in line or "WARNING" in line]
                rows.extend(_row("Latest virus scan finding", line) for line in findings[-40:])
                if not findings:
                    rows.append(_row("Latest virus scan", "No finding lines in the readable latest log; this is not a guarantee that every file was scanned"))
            else:
                notes.append("No virus-scan log was found. Scan state is unavailable rather than assumed clean.")
        except OSError as exc:
            notes.append("Virus-scan findings unavailable: " + self._read_error(exc))
        status = "warn" if alerts else "info"
        summary = f"{len(alerts)} pending item(s) need your attention" if alerts else "No pending kit alerts are readable; scan details may still be unavailable"
        return _section("security", status, summary, rows, notes)


# --------------------------------------------------------------- privacy report
_SECRET_KEY = re.compile(r"pass(word|phrase)?|secret|token|api[-_]?key|authorization|credential|private[-_]?key|cookie|session[-_]?id", re.I)
_USER_KEY = re.compile(r"^(user|username|login|account|owner|sudo_user)$", re.I)
_IP_KEY = re.compile(r"^(ip|ip_address|address|destination|remote|remote_address|local_address)$", re.I)
_IPV4 = re.compile(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])")
_IPV6 = re.compile(r"(?<![\w:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![\w:])")
_MAC = re.compile(r"(?<![0-9A-Fa-f])(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f])")
_JWT = re.compile(r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b")
_BEARER = re.compile(r"\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+", re.I)
_SECRET_NAME = r"(?:[A-Za-z0-9_-]*(?:password|passwd|passphrase|secret|token|api[-_]?key|authorization|credential|cookie|session[-_]?id)[A-Za-z0-9_-]*)"
_SECRET_ASSIGN = re.compile(
    rf"(?i)(\b{_SECRET_NAME}\b\s*[:=]\s*)(\"[^\"]*\"|'[^']*'|[^\s,;]+)"
)
_PRIVATE_KEY_BLOCK = re.compile(r"-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----", re.S)
_URL_USERINFO = re.compile(r"\b([A-Za-z][A-Za-z0-9+.-]*://)([^\s/@:]+):([^\s/@]+)@")


def _mask_ips(text: str) -> str:
    def valid_ipv4(match: re.Match[str]) -> str:
        return "[redacted-ip]" if all(0 <= int(part) <= 255 for part in match.group(0).split(".")) else match.group(0)
    text = _IPV4.sub(valid_ipv4, text)
    text = _IPV6.sub(lambda m: "[redacted-ip]" if m.group(0).count(":") >= 2 else m.group(0), text)
    return _MAC.sub("[redacted-device-address]", text)


def redact_text(
    value: Any, usernames: Iterable[str] = (), redact_usernames: bool = True,
    redact_ips: bool = True, redact_tokens: bool = True,
) -> str:
    text = _clean(value, 1_000_000)
    if redact_tokens:
        text = _PRIVATE_KEY_BLOCK.sub("[redacted-private-key]", text)
        text = _JWT.sub("[redacted-token]", text)
        text = _BEARER.sub(lambda m: m.group(1) + " [redacted-token]", text)
        text = _SECRET_ASSIGN.sub(lambda m: m.group(1) + "[redacted-secret]", text)
        text = _URL_USERINFO.sub(lambda m: m.group(1) + "[redacted-user]:[redacted-secret]@", text)
    if redact_ips:
        text = _mask_ips(text)
    if redact_usernames:
        names = {name for name in usernames if isinstance(name, str) and len(name) >= 2}
        for name in sorted(names, key=len, reverse=True):
            escaped = re.escape(name)
            text = re.sub(rf"(/home/){escaped}(?=/|\b)", r"\1[redacted-user]", text)
            text = re.sub(rf"(?i)(\bsudo:\s+){escaped}\b", r"\1[redacted-user]", text)
            text = re.sub(rf"(?i)(\b(?:user|username|login|account)=){escaped}\b", r"\1[redacted-user]", text)
            text = re.sub(rf"(?m)^{escaped}(?=\s+(?:pts/|tty|:|reboot|shutdown))", "[redacted-user]", text)
        # Also cover other accounts in multi-user login/sudo logs, not just the current account.
        text = re.sub(r"(/home/)[^/\s]+", r"\1[redacted-user]", text)
        text = re.sub(r"(?i)(\bsudo:\s+)[A-Za-z_][A-Za-z0-9_.-]{0,31}", r"\1[redacted-user]", text)
        text = re.sub(r"(?i)(\b(?:user|username|login|account)=)[A-Za-z_][A-Za-z0-9_.-]{0,31}", r"\1[redacted-user]", text)
        text = re.sub(r"(?m)^[A-Za-z_][A-Za-z0-9_.-]{0,31}(?=\s+(?:pts/|tty|:|reboot|shutdown))", "[redacted-user]", text)
        text = re.sub(r"(?i)(\bfor(?: invalid user)?\s+)[A-Za-z_][A-Za-z0-9_.-]{0,31}(?=\s+from\s)", r"\1[redacted-user]", text)
        text = re.sub(r"(?i)(\bfor user\s+)[A-Za-z_][A-Za-z0-9_.-]{0,31}", r"\1[redacted-user]", text)
    return text


def redact_snapshot(
    snapshot: dict[str, Any], redact_usernames: bool = True,
    redact_ips: bool = True, redact_tokens: bool = True,
) -> dict[str, Any]:
    usernames = snapshot.get("privacy", {}).get("usernames", [])

    def scrub(value: Any, key: str = "") -> Any:
        if redact_tokens and _SECRET_KEY.search(key):
            return "[redacted-secret]"
        if redact_usernames and _USER_KEY.match(key):
            return "[redacted-user]"
        if redact_ips and _IP_KEY.match(key):
            return "[redacted-ip]"
        if isinstance(value, dict):
            return {str(k): scrub(v, str(k)) for k, v in value.items()}
        if isinstance(value, list):
            return [scrub(item, key) for item in value]
        if isinstance(value, str):
            return redact_text(value, usernames, redact_usernames, redact_ips, redact_tokens)
        return value

    result = scrub(copy.deepcopy(snapshot))
    result["report_redaction"] = {
        "usernames": redact_usernames,
        "ip_and_device_addresses": redact_ips,
        "tokens_and_secrets": redact_tokens,
    }
    return result


def report_text(snapshot: dict[str, Any]) -> str:
    lines = [
        "MY COMPUTER ACTIVITY — PRIVACY REVIEW",
        f"Generated: {snapshot.get('generated_at', 'unavailable')}",
        "Local read-only metadata. No packet contents or remote telemetry.",
        f"Redaction: {json.dumps(snapshot.get('report_redaction', {}), sort_keys=True)}",
        "",
    ]
    for section in snapshot.get("sections", []):
        lines += [section.get("title", "Untitled").upper(), section.get("summary", "Unavailable")]
        for row in section.get("rows", []):
            lines.append(f"  {row.get('label', 'Detail')}: {row.get('value', 'Unavailable')}")
        for note in section.get("notes", []):
            lines.append(f"  Note: {note}")
        lines.append("")
    return "\n".join(lines)


def report_html(snapshot: dict[str, Any]) -> str:
    generated = html.escape(str(snapshot.get("generated_at", "unavailable")))
    redaction = html.escape(json.dumps(snapshot.get("report_redaction", {}), sort_keys=True))
    cards = []
    for section in snapshot.get("sections", []):
        rows = "".join(
            "<tr><th scope=\"row\">{}</th><td>{}</td></tr>".format(
                html.escape(str(row.get("label", "Detail"))),
                html.escape(str(row.get("value", "Unavailable"))),
            ) for row in section.get("rows", [])
        ) or "<tr><td>No detailed records available.</td></tr>"
        notes = "".join(f"<li>{html.escape(str(note))}</li>" for note in section.get("notes", []))
        cards.append(
            f'<section class="card {html.escape(str(section.get("status", "unknown")))}">'
            f'<h2>{html.escape(str(section.get("title", "Untitled")))}</h2>'
            f'<p class="summary">{html.escape(str(section.get("summary", "Unavailable")))}</p>'
            f'<details><summary>Show details</summary><table>{rows}</table><ul>{notes}</ul></details></section>'
        )
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
<title>My Computer Activity — privacy-safe report</title>
<style>
:root{{color-scheme:light;--ink:#172b3a;--muted:#536777;--navy:#10263f;--paper:#f3f6fa}}*{{box-sizing:border-box}}
body{{margin:0;background:var(--paper);color:var(--ink);font:16px/1.55 system-ui,-apple-system,Segoe UI,sans-serif}}
header{{background:var(--navy);color:white;padding:2rem max(1rem,calc((100% - 1100px)/2))}}header p{{max-width:75ch}}
main{{max-width:1100px;margin:1.5rem auto;padding:0 1rem;display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,430px),1fr));gap:1rem}}
.card{{background:white;border:1px solid #d7e0e8;border-top:5px solid #76899a;border-radius:14px;padding:1.2rem;box-shadow:0 4px 18px #17324d0c}}
.card.ok{{border-top-color:#198754}}.card.warn{{border-top-color:#b76e00}}.card.bad{{border-top-color:#c43d4b}}
h1,h2{{line-height:1.2}}h2{{font-size:1.2rem;margin-top:0}}.summary{{font-weight:650}}details{{margin-top:1rem}}summary{{cursor:pointer;color:#135d86;font-weight:650}}
table{{width:100%;border-collapse:collapse;margin-top:.8rem;font-size:.9rem}}th,td{{text-align:left;vertical-align:top;border-bottom:1px solid #e6ebef;padding:.55rem;white-space:pre-wrap;overflow-wrap:anywhere}}th{{width:38%;color:var(--muted)}}
footer{{max-width:1100px;margin:1rem auto 3rem;padding:0 1rem;color:var(--muted)}}@media(max-width:520px){{body{{font-size:15px}}header{{padding:1.4rem 1rem}}main{{padding:0 .65rem}}th,td{{display:block;width:100%}}}}
</style></head><body><header><h1>My Computer Activity</h1><p>Privacy review copy · generated {generated}</p>
<p>Created entirely on this computer from read-only metadata. No packet contents, remote server or telemetry.</p><p>Redaction settings: {redaction}</p></header>
<main>{''.join(cards)}</main><footer>Review this file before sharing it. Redaction reduces risk but cannot guarantee that every private detail in arbitrary system logs is recognized.</footer></body></html>"""


def demo_snapshot() -> dict[str, Any]:
    """Explicitly labelled fixture for visual tests; never used by normal launch."""
    sections = [
        _section("network", "info", "3 current connections reported by the system", [
            _row("Firefox · TCP · ESTAB", "203.0.113.24:443"),
            _row("Syncthing · TCP · ESTAB", "192.168.1.20:22000"),
            _row("System process · UDP · UNCONN", "198.51.100.8:123"),
        ], ["Example data. Packet contents and browsing history are not inspected."]),
        _section("firewall", "ok", "A supported firewall is active; OpenSnitch is running", [
            _row("firewalld", "active"), _row("OpenSnitch", "active"),
            _row("Recent OpenSnitch alert", "2026-11-05 09:14 example-app denied connection to 203.0.113.99:443"),
        ]),
        _section("services", "info", "1 running now; 6 scheduled timers found", [
            _row("Computer health check (secure-linux-check.timer)", "waiting; enabled"),
            _row("Recent job history", "2026-11-05 08:00 secure-linux-check.service: Completed successfully"),
        ]),
        _section("updates", "info", "2 update schedules found; last run details are below", [
            _row("Update schedule", "Next: 2026-11-06 06:17 · dnf-automatic.timer"),
            _row("Update availability", "Not checked — no network request"),
        ]),
        _section("disk", "ok", "Root storage 58% used; all readable disks report SMART passed", [
            _row("Storage: /", "58% used; 438 GB available"), _row("SMART: /dev/sda", "passed"),
        ]),
        _section("resources", "ok", "42% memory used; 58% storage used", [
            _row("CPU load (1, 5 and 15 minutes)", "1.24, 0.98, 0.76"),
            _row("Memory available", "9.2 GB"),
        ]),
        _section("logins", "info", "2 recent login records; 1 sudo record accessible", [
            _row("Recorded login", "alex pts/0 192.168.1.20 Wed Nov 5 08:42"),
            _row("Recorded sudo/admin action", "sudo: alex : COMMAND=/usr/bin/systemctl status"),
        ]),
        _section("devices", "info", "2 USB devices connected; 1 recent event line", [
            _row("Connected USB device", "Bus 001 Device 004: Example flash drive"),
        ]),
        _section("containers", "ok", "Running: docker, secure-linux-homeassistant", [
            _row("Running docker container", "homeassistant · ghcr.io/example/home-assistant · Up 3 days"),
        ]),
        _section("recovery", "info", "Setup finished; 1 backup configuration readable", [
            _row("Install/setup state", "done — Setup finished"),
            _row("Last recorded completed backup", "2026-11-05T02:15:00+11:00"),
        ]),
        _section("security", "warn", "1 pending item needs your attention", [
            _row("Pending: Monthly backup test", "Take two minutes to check you can restore one file.\nNext step: Open Pika Backup"),
        ]),
    ]
    return {
        "schema": SCHEMA, "generated_at": _now(), "demo": True,
        "collection": "EXAMPLE DATA for visual inspection — not measurements from this computer",
        "privacy": {"usernames": ["alex"]}, "sections": sections,
    }
