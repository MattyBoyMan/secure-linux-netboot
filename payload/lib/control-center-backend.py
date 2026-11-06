#!/usr/bin/env python3
"""Narrow system adapter for Secure Linux Control Centre.

Public commands:
  status                         print a JSON snapshot; never changes anything
  apply FEATURE on|off           apply one named change and verify it
  scan-now                       run the existing ClamAV scan
  --askpass                      graphical sudo password prompt (no logging)

There is no shell command input, no password storage, and no arbitrary service
name input. Existing Secure Linux helpers own DNS, VPN and OpenSnitch internals.
"""
from __future__ import annotations

import getpass
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from typing import Dict, List, Optional, Sequence, Tuple

ROOT = Path(os.environ.get("SL_CC_ROOT", "/usr/local/lib/secure-linux"))
if not ROOT.exists() and Path(__file__).resolve().parent.name == "lib":
    ROOT = Path(__file__).resolve().parent.parent
SYSROOT = Path(os.environ.get("SL_CC_SYSROOT", "/"))
BIN = Path(os.environ.get("SL_CC_BIN", "/usr/local/bin"))
SELF = Path(__file__).resolve()
ON_STATES = {"on", "encrypted", "family", "private", "home", "warp", "active", "enabled"}
FEATURES = {"firewall", "opensnitch", "dns", "vpn", "updates", "clamav", "usbguard", "fail2ban", "screen_lock", "auditd"}


def rooted(name: str) -> Path:
    return SYSROOT / name.lstrip("/")


def helper(name: str) -> Path:
    installed = BIN / name
    if installed.exists() or shutil.which(name):
        return installed if installed.exists() else Path(shutil.which(name) or name)
    return ROOT / "bin" / name


def have(name: str) -> bool:
    return shutil.which(name) is not None


def run(args: Sequence[object], env: Optional[dict] = None) -> subprocess.CompletedProcess:
    """Run a fixed argument vector. Output is returned, never written to a log."""
    try:
        return subprocess.run(
            [str(a) for a in args],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            env=env,
            check=False,
        )
    except OSError as exc:
        return subprocess.CompletedProcess([str(a) for a in args], 127, str(exc))


def short_output(result: subprocess.CompletedProcess, fallback: str) -> str:
    lines = [line.strip() for line in (result.stdout or "").splitlines() if line.strip()]
    if not lines:
        return fallback
    # Avoid flooding the GUI. No output is persisted, and no passwords are read.
    return "\n".join(lines[-8:])[:3500]


def unit_exists(unit: str) -> bool:
    return have("systemctl") and run(["systemctl", "cat", unit]).returncode == 0


def unit_active(unit: str) -> bool:
    return have("systemctl") and run(["systemctl", "is-active", "--quiet", unit]).returncode == 0


def unit_enabled(unit: str) -> bool:
    return have("systemctl") and run(["systemctl", "is-enabled", "--quiet", unit]).returncode == 0


def first_unit(names: Sequence[str], active: bool = False) -> Optional[str]:
    for name in names:
        if unit_exists(name) and (not active or unit_active(name)):
            return name
    return None


def distro() -> str:
    text = ""
    try:
        text = rooted("/etc/os-release").read_text(encoding="utf-8")
    except OSError:
        pass
    values = {}
    for line in text.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value.strip().strip('"')
    return "debian" if values.get("ID") in {"debian", "ubuntu"} or "debian" in values.get("ID_LIKE", "") else "fedora"


def profile() -> str:
    try:
        return rooted("/etc/secure-linux/profile").read_text(encoding="utf-8").strip() or "full"
    except OSError:
        return "full"


def status_template(feature: str) -> Dict[str, object]:
    return {
        "feature": feature,
        "state": "unknown",
        "detail": "Status could not be determined.",
        "supported": False,
        "manageable": False,
        "can_disable": False,
        "reversible": True,
    }


def firewall_status() -> Dict[str, object]:
    item = status_template("firewall")
    if unit_exists("firewalld.service") or have("firewall-cmd"):
        active = unit_active("firewalld.service")
        item.update(state="on" if active else "off", supported=True, manageable=have("systemctl"), can_disable=True,
                    detail="Firewalld is running. Incoming connections are filtered by its existing zones." if active else
                           "Firewalld is installed but not running.")
    elif have("ufw") or unit_exists("ufw.service"):
        active = unit_active("ufw.service")
        item.update(state="on" if active else "off", supported=True, manageable=True, can_disable=True,
                    detail="UFW is active. Its existing rules are unchanged by this centre." if active else
                           "UFW is installed but not active.")
    else:
        item["detail"] = "Neither firewalld nor UFW was found. Run Secure Linux repair before enabling one."
    return item


def opensnitch_status() -> Dict[str, object]:
    item = status_template("opensnitch")
    tool = helper("secure-linux-netguard")
    if not tool.exists() and not have("secure-linux-netguard"):
        item["detail"] = "Secure Linux Netguard is not installed on this setup."
        return item
    result = run([tool, "status", "--short"])
    state = (result.stdout or "").strip().splitlines()[-1] if result.returncode == 0 and result.stdout else "unknown"
    unit = first_unit(("opensnitch.service", "opensnitchd.service"))
    installed = state != "not-installed"
    item.update(state="on" if state == "on" else state, supported=installed,
                manageable=installed and (unit is not None or state == "paused"), can_disable=installed,
                detail={
                    "on": "OpenSnitch is running with the existing Netguard rules.",
                    "paused": "OpenSnitch is paused temporarily. Resume it to restore protection.",
                    "off": "OpenSnitch is installed but switched off.",
                    "down": "OpenSnitch is installed but its service is not running.",
                    "not-installed": "OpenSnitch is not installed. Debian and atomic setups may not include it.",
                }.get(state, "OpenSnitch status is unavailable."))
    return item


def dns_status() -> Dict[str, object]:
    item = status_template("dns")
    tool = helper("secure-linux-dns")
    result = run([tool, "status", "--short"]) if tool.exists() or have("secure-linux-dns") else None
    state = (result.stdout or "").strip().splitlines()[-1] if result and result.returncode == 0 and result.stdout else "unknown"
    supported = state in {"encrypted", "family", "vpn", "paused", "off"}
    item.update(state=state, supported=supported and state != "off", manageable=supported and state != "off", can_disable=True,
                detail={
                    "encrypted": "Encrypted DNS is on; the VPN is not replacing it.",
                    "family": "Encrypted DNS with the existing family filter is on.",
                    "vpn": "Your connected VPN currently supplies secure DNS.",
                    "paused": "Secure DNS is paused temporarily for a Wi-Fi login page.",
                    "off": "Secure DNS is not configured. Use Secure Linux repair; this centre will not invent DNS settings.",
                }.get(state, "Secure Linux DNS is unavailable on this setup."))
    return item


def vpn_status() -> Dict[str, object]:
    item = status_template("vpn")
    tool = helper("secure-linux-vpn")
    result = run([tool, "status", "--short"]) if tool.exists() or have("secure-linux-vpn") else None
    state = (result.stdout or "").strip().splitlines()[-1] if result and result.returncode == 0 and result.stdout else "unknown"
    supported = state in {"private", "home", "warp", "off", "both"}
    item.update(state=state, supported=supported, manageable=supported, can_disable=True,
                detail={
                    "private": "NordVPN private mode is connected.",
                    "home": "VPN home mode is connected.",
                    "warp": "Cloudflare WARP is connected.",
                    "both": "Two VPNs report connected. Turn private mode on to restore the one-VPN rule.",
                    "off": "VPN is off. Turning it on uses your existing Secure Linux VPN configuration.",
                }.get(state, "Secure Linux VPN is unavailable. Set up or repair the VPN first."))
    return item


def update_units() -> List[str]:
    if distro() == "debian":
        candidates = ["apt-daily.timer", "apt-daily-upgrade.timer", "unattended-upgrades.service"]
    elif profile() == "atomic":
        candidates = ["rpm-ostreed-automatic.timer"]
    elif profile() == "lite":
        candidates = ["dnf5-automatic.timer", "dnf-automatic.timer", "dnf-automatic-install.timer"]
    else:
        candidates = ["secure-linux-offline-updates.timer"]
    return [name for name in candidates if unit_exists(name)]


def updates_status() -> Dict[str, object]:
    item = status_template("updates")
    units = update_units()
    active = [unit for unit in units if unit_active(unit)]
    timer_count = len([unit for unit in units if unit.endswith(".timer")])
    expected = min(2, timer_count) if distro() == "debian" and timer_count else 1
    on = len(active) >= expected
    item.update(state="on" if on else "off", supported=bool(units), manageable=bool(units), can_disable=True,
                detail=("Automatic update jobs are active: " + ", ".join(active)) if on else
                       ("No automatic update job is active. Installed jobs: " + ", ".join(units)) if units else
                       "No supported automatic update timer was found. Repair the setup first.")
    return item


def scan_unit() -> Optional[str]:
    return first_unit(("secure-linux-clamscan.timer", "secure-linux-scan.timer"))


def clamav_status() -> Dict[str, object]:
    item = status_template("clamav")
    installed = have("clamscan")
    unit = scan_unit()
    active = unit_active(unit) if unit else False
    item.update(state="on" if active else "off", supported=installed and unit is not None,
                manageable=installed and unit is not None, can_disable=True,
                detail=("The weekly ClamAV scan is scheduled; suspicious files are never deleted.") if active else
                       "ClamAV is installed, but the weekly scan timer is off." if installed and unit else
                       "ClamAV or its Secure Linux scan timer is not installed. This can be a memory or setup limitation.")
    return item


def service_status(feature: str, units: Sequence[str], on_text: str, off_text: str, missing_text: str,
                   can_disable: bool = True) -> Dict[str, object]:
    item = status_template(feature)
    unit = first_unit(units)
    active = unit_active(unit) if unit else False
    item.update(state="on" if active else "off", supported=unit is not None, manageable=unit is not None,
                can_disable=can_disable, detail=on_text if active else off_text if unit else missing_text)
    return item


def usbguard_status() -> Dict[str, object]:
    item = service_status("usbguard", ("usbguard.service",), "USBGuard is running with its existing device policy.",
                          "USBGuard is installed but stopped.", "USBGuard is not installed on this setup.")
    rules = rooted("/etc/usbguard/rules.conf")
    try:
        has_rules = rules.stat().st_size > 0
    except OSError:
        has_rules = False
    if item["supported"] and not has_rules and not unit_active("usbguard.service"):
        item.update(manageable=False, detail="USBGuard is installed but has no readable device rules. The centre will not risk blocking your keyboard or mouse.")
    return item


def screen_lock_status() -> Dict[str, object]:
    item = status_template("screen_lock")
    if have("gsettings") and os.environ.get("XDG_CURRENT_DESKTOP", "").upper().find("GNOME") >= 0:
        result = run(["gsettings", "get", "org.gnome.desktop.screensaver", "lock-enabled"])
        if result.returncode == 0:
            on = result.stdout.strip() == "true"
            item.update(state="on" if on else "off", supported=True, manageable=True, can_disable=True,
                        detail="GNOME asks for your password after the screen locks." if on else "GNOME screen locking is off.")
        return item
    reader = "kreadconfig6" if have("kreadconfig6") else "kreadconfig5" if have("kreadconfig5") else None
    if reader:
        result = run([reader, "--file", "kscreenlockerrc", "--group", "Daemon", "--key", "Autolock", "--default", "false"])
        if result.returncode == 0:
            on = result.stdout.strip().lower() == "true"
            item.update(state="on" if on else "off", supported=True, manageable=True, can_disable=True,
                        detail="KDE locks automatically after the configured idle time." if on else "KDE automatic screen locking is off.")
        return item
    if have("xfconf-query") and os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
        result = run(["xfconf-query", "-c", "xfce4-screensaver", "-p", "/lock/enabled"])
        if result.returncode == 0:
            on = result.stdout.strip().lower() == "true"
            item.update(state="on" if on else "off", supported=True, manageable=True, can_disable=True,
                        detail="Xfce asks for your password when the screen saver starts." if on else "Xfce screen locking is off.")
        return item
    item["detail"] = "No supported KDE, GNOME or Xfce screen-lock setting was found in this user session."
    return item


def secure_boot_status() -> Dict[str, object]:
    item = status_template("secure_boot")
    if have("mokutil"):
        result = run(["mokutil", "--sb-state"])
        output = (result.stdout or "").lower()
        if "secureboot enabled" in output:
            item.update(state="on", supported=True, detail="Secure Boot is enabled in firmware. No change is needed.")
        elif "secureboot disabled" in output:
            item.update(state="off", supported=True, detail="Secure Boot is off. Enabling it requires firmware settings and usually a restart; some drivers may need signed keys.")
        else:
            item["detail"] = "This computer did not report a Secure Boot state. It may not support UEFI Secure Boot."
    else:
        item["detail"] = "mokutil is not installed, so Secure Boot cannot be checked here. Firmware capabilities vary by computer."
    item["reversible"] = False
    return item


def disk_status() -> Dict[str, object]:
    item = status_template("disk_encryption")
    source_result = run(["findmnt", "-no", "SOURCE", "/"]) if have("findmnt") else None
    source = source_result.stdout.strip().split("[", 1)[0] if source_result and source_result.returncode == 0 else ""
    result = run(["lsblk", "-rpsno", "NAME,FSTYPE", source]) if source and have("lsblk") else None
    encrypted = bool(result and result.returncode == 0 and any(
        line.split()[-1:] == ["crypto_LUKS"] for line in result.stdout.splitlines() if line.split()))
    item.update(state="on" if encrypted else "off", supported=result is not None and result.returncode == 0,
                detail="The system disk's root filesystem is behind LUKS encryption. Keep your disk recovery key safe." if encrypted else
                       "The root filesystem is not behind LUKS encryption. Adding it safely can require a full backup and reinstall; an encrypted USB disk does not protect the system disk." if result is not None and result.returncode == 0 else
                       "The system disk's encryption state could not be determined. No change will be offered here.")
    item["reversible"] = False
    return item


def flatpak_status() -> Dict[str, object]:
    item = status_template("flatpak_permissions")
    installed = have("flatseal")
    if not installed and have("flatpak"):
        installed = run(["flatpak", "info", "com.github.tchx84.Flatseal"]).returncode == 0
    item.update(state="available" if installed else "unavailable", supported=installed,
                detail="Flatseal is available to review one app's permissions at a time." if installed else
                       "Flatseal is not installed. The centre will not reset Flatpak permissions blindly.")
    return item


def docker_status() -> Dict[str, object]:
    item = status_template("docker_rootless")
    if not have("docker"):
        item["detail"] = "Docker is not installed. The existing Home & Server Helper can explain the options."
        return item
    result = run(["docker", "context", "show"])
    context = result.stdout.strip() if result.returncode == 0 else "unknown"
    on = context == "rootless"
    item.update(state="on" if on else "off", supported=True,
                detail="Docker is using your per-user rootless context." if on else
                       f"Docker is available, but the active context is '{context}', not rootless. Use Home & Server Helper to set up rootless Docker.")
    return item


STATUS_FUNCTIONS = {
    "firewall": firewall_status,
    "opensnitch": opensnitch_status,
    "dns": dns_status,
    "vpn": vpn_status,
    "updates": updates_status,
    "clamav": clamav_status,
    "usbguard": usbguard_status,
    "fail2ban": lambda: service_status("fail2ban", ("fail2ban.service",), "Fail2ban is running with its existing login-protection rules.",
                                               "Fail2ban is installed but stopped.", "Fail2ban is not installed on this setup."),
    "screen_lock": screen_lock_status,
    "auditd": lambda: service_status("auditd", ("auditd.service",), "The audit service is running with its existing rules.",
                                             "Auditd is installed but stopped.", "Auditd is not installed on this setup.", can_disable=False),
}

# Buttons in the GUI use these informational readers too.
ALL_STATUS = dict(STATUS_FUNCTIONS, secure_boot=secure_boot_status, disk_encryption=disk_status,
                  flatpak_permissions=flatpak_status, docker_rootless=docker_status)


def update_command(units: Sequence[str], enable: bool) -> List[object]:
    if distro() == "debian" and enable:
        # apt's two calendar timers are a pair; unattended-upgrades is activated by them.
        units = [u for u in units if u.endswith(".timer")] or list(units)
    return ["systemctl", "enable" if enable else "disable", "--now" if enable else "--now", *units]


def execute(feature: str, desired: bool) -> subprocess.CompletedProcess:
    """Execute exactly one allow-listed operation."""
    if feature == "firewall":
        if unit_exists("firewalld.service") or have("firewall-cmd"):
            return run(["systemctl", "enable" if desired else "disable", "--now", "firewalld.service"])
        return run(["ufw", "--force", "enable"] if desired else ["ufw", "disable"])
    if feature == "opensnitch":
        choice = run([helper("secure-linux-choice"), "set", "opensnitch", "yes" if desired else "no"])
        if choice.returncode != 0:
            return choice
        state = opensnitch_status()["state"]
        if desired and state == "paused":
            return run([helper("secure-linux-netguard"), "resume"])
        unit = first_unit(("opensnitch.service", "opensnitchd.service"))
        return run(["systemctl", "enable" if desired else "disable", "--now", unit or "opensnitch.service"])
    if feature == "dns":
        return run([helper("secure-linux-dns"), "secure" if desired else "open", *(() if desired else ("15",))])
    if feature == "vpn":
        return run([helper("secure-linux-vpn"), "private" if desired else "off"])
    if feature == "updates":
        units = update_units()
        return run(update_command(units, desired)) if units else subprocess.CompletedProcess([], 1, "No supported update timer found")
    if feature == "clamav":
        unit = scan_unit()
        return run(["systemctl", "enable" if desired else "disable", "--now", unit]) if unit else subprocess.CompletedProcess([], 1, "No scan timer found")
    if feature == "usbguard":
        return run(["systemctl", "enable" if desired else "disable", "--now", "usbguard.service"])
    if feature == "fail2ban":
        return run(["systemctl", "enable" if desired else "disable", "--now", "fail2ban.service"])
    if feature == "auditd" and desired:
        return run(["systemctl", "enable", "--now", "auditd.service"])
    if feature == "screen_lock":
        return set_screen_lock(desired)
    return subprocess.CompletedProcess([], 2, "Operation is not allowed")


def set_screen_lock(desired: bool) -> subprocess.CompletedProcess:
    value = "true" if desired else "false"
    if have("gsettings") and "GNOME" in os.environ.get("XDG_CURRENT_DESKTOP", "").upper():
        first = run(["gsettings", "set", "org.gnome.desktop.screensaver", "lock-enabled", value])
        if first.returncode != 0 or not desired:
            return first
        return run(["gsettings", "set", "org.gnome.desktop.screensaver", "idle-activation-enabled", "true"])
    writer = "kwriteconfig6" if have("kwriteconfig6") else "kwriteconfig5" if have("kwriteconfig5") else None
    if writer:
        results = [run([writer, "--file", "kscreenlockerrc", "--group", "Daemon", "--key", key, value])
                   for key in ("Autolock", "LockOnResume")]
        failed = next((r for r in results if r.returncode != 0), None)
        return failed or results[-1]
    if have("xfconf-query") and os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
        commands = [
            ["xfconf-query", "-c", "xfce4-screensaver", "-p", "/lock/enabled", "-n", "-t", "bool", "-s", value],
            ["xfconf-query", "-c", "xfce4-screensaver", "-p", "/saver/enabled", "-n", "-t", "bool", "-s", "true"],
        ]
        if desired:
            commands += [
                ["xfconf-query", "-c", "xfce4-screensaver", "-p", "/saver/idle-activation/enabled", "-n", "-t", "bool", "-s", "true"],
                ["xfconf-query", "-c", "xfce4-screensaver", "-p", "/saver/idle-activation/delay", "-n", "-t", "int", "-s", "5"],
                ["xfconf-query", "-c", "xfce4-screensaver", "-p", "/lock/saver-activation/enabled", "-n", "-t", "bool", "-s", "true"],
                ["xfconf-query", "-c", "xfce4-screensaver", "-p", "/lock/saver-activation/delay", "-n", "-t", "int", "-s", "0"],
            ]
        for command in commands:
            result = run(command)
            if result.returncode != 0:
                return result
        return result
    return subprocess.CompletedProcess([], 1, "No supported desktop screen-lock setting was found")


def needs_elevation(feature: str) -> bool:
    # DNS and VPN helpers own their own pkexec boundaries and must remain in the
    # user's session. Screen lock is always per user.
    return feature not in {"dns", "vpn", "screen_lock"}


def run_privileged(args: Sequence[object]) -> subprocess.CompletedProcess:
    if os.geteuid() == 0:
        return run(args)
    if have("pkexec"):
        return run(["pkexec", *args])
    if have("sudo"):
        env = os.environ.copy()
        env["SUDO_ASKPASS"] = str(SELF.with_name("control-center-askpass"))
        env["SUDO_ASKPASS_REQUIRE"] = "force"
        return run(["sudo", "-A", *args], env=env)
    return subprocess.CompletedProcess([], 1, "Neither pkexec nor sudo is available for the graphical administrator prompt.")


def elevated_apply(feature: str, desired: bool) -> subprocess.CompletedProcess:
    if os.geteuid() == 0 or not needs_elevation(feature):
        return execute(feature, desired)
    return run_privileged([SELF, "_execute", feature, "on" if desired else "off"])


def verified_apply(feature: str, desired: bool) -> Dict[str, object]:
    before = ALL_STATUS[feature]()
    result = elevated_apply(feature, desired)
    after = ALL_STATUS[feature]()
    actual_on = after["state"] in ON_STATES
    verified = result.returncode == 0 and actual_on == desired
    response = {
        "feature": feature,
        "desired": desired,
        "ok": result.returncode == 0,
        "verified": verified,
        "state": after["state"],
        "detail": short_output(result, "The setting now matches." if verified else "The command did not report a useful result."),
        "rollback_supported": bool(before.get("reversible", True)),
        "rollback_attempted": False,
        "rollback_ok": None,
    }
    if verified:
        return response
    response["detail"] += f"\nVerification: expected {'on' if desired else 'off'}, found {after['state']}. {after['detail']}"
    # A failed operation may have changed part of the system. Immediately try to
    # restore its observed prior state when that state is known and reversible.
    before_on = before["state"] in ON_STATES
    if before.get("reversible", True) and before["state"] != "unknown" and actual_on != before_on:
        response["rollback_attempted"] = True
        undo = elevated_apply(feature, before_on)
        restored = ALL_STATUS[feature]()
        response["rollback_ok"] = undo.returncode == 0 and (restored["state"] in ON_STATES) == before_on
    return response


def scan_now() -> Dict[str, object]:
    if not have("clamscan"):
        return {"ok": False, "detail": "ClamAV is not installed. No scan was started."}
    if distro() == "debian" and (helper("secure-linux-scan").exists() or have("secure-linux-scan")):
        result = run([helper("secure-linux-scan"), "now"])
    else:
        unit = "secure-linux-clamscan.service"
        result = run_privileged(["systemctl", "start", unit])
    return {"ok": result.returncode == 0, "detail": short_output(result, "The scan finished. Open Secure Linux Status to review any findings.")}


def snapshot() -> Dict[str, object]:
    return {
        "version": 1,
        "distro": distro(),
        "profile": profile(),
        "features": {name: function() for name, function in ALL_STATUS.items()},
    }


def askpass() -> int:
    """sudo -A callback: a local Tk password box, never a stored credential."""
    import tkinter as tk
    from tkinter import ttk
    root = tk.Tk()
    root.title("Administrator permission")
    root.resizable(False, False)
    root.attributes("-topmost", True)
    value = tk.StringVar()
    answer = []
    frame = ttk.Frame(root, padding=24)
    frame.grid()
    ttk.Label(frame, text="Administrator permission is needed", font=("TkDefaultFont", 13, "bold")).grid(row=0, column=0, columnspan=2, sticky="w", pady=(0, 10))
    ttk.Label(frame, text="Your password is used only by sudo. It is not saved or logged.").grid(row=1, column=0, columnspan=2, sticky="w", pady=(0, 14))
    ttk.Label(frame, text="Password:").grid(row=2, column=0, sticky="e", padx=(0, 8))
    entry = ttk.Entry(frame, textvariable=value, show="•", width=28)
    entry.grid(row=2, column=1, sticky="ew")
    def accept(_event=None):
        answer.append(value.get())
        root.destroy()
    def cancel(_event=None):
        root.destroy()
    ttk.Button(frame, text="Cancel", command=cancel).grid(row=3, column=0, pady=(18, 0))
    ttk.Button(frame, text="Continue", command=accept, default="active").grid(row=3, column=1, sticky="e", pady=(18, 0))
    root.bind("<Return>", accept)
    root.bind("<Escape>", cancel)
    entry.focus_set()
    root.mainloop()
    if answer:
        print(answer[0])
        return 0
    return 1


def main(argv: Sequence[str]) -> int:
    if len(argv) >= 2 and argv[1] == "--askpass":
        return askpass()
    if len(argv) >= 2 and argv[1] == "status":
        print(json.dumps(snapshot(), ensure_ascii=False))
        return 0
    if len(argv) == 4 and argv[1] in {"apply", "_execute"} and argv[2] in FEATURES and argv[3] in {"on", "off"}:
        desired = argv[3] == "on"
        if argv[1] == "_execute":
            if os.geteuid() != 0 and needs_elevation(argv[2]):
                print(json.dumps({"ok": False, "verified": False, "detail": "Elevated operation was not started as root."}))
                return 1
            result = execute(argv[2], desired)
            print(short_output(result, "Operation finished"))
            return result.returncode
        print(json.dumps(verified_apply(argv[2], desired), ensure_ascii=False))
        return 0
    if len(argv) == 2 and argv[1] == "scan-now":
        print(json.dumps(scan_now(), ensure_ascii=False))
        return 0
    print("Use: control-center-backend.py status | apply FEATURE on|off | scan-now", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
