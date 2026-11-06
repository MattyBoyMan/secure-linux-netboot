#!/usr/bin/env python3
"""Headless command adapter and lazy native entry for Secure Linux Pi-hole."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import sys

from gui_tools_common import CommandSpec


class PiHoleBackend:
    def __init__(self, root: Path | None = None):
        source = Path(__file__).resolve().parent.parent
        self.root = root or Path(os.environ.get("SL_ROOT", str(source)))
        candidate = self.root / "bin" / "secure-linux-pihole"
        self.launcher = candidate if candidate.is_file() else Path("/usr/local/bin/secure-linux-pihole")

    def _base(self, privileged: bool) -> list[str]:
        argv = [os.environ.get("BASH", "bash"), str(self.launcher)] if os.name == "nt" else [str(self.launcher)]
        if privileged and hasattr(os, "geteuid") and os.geteuid() != 0:
            pkexec = shutil.which("pkexec")
            if not pkexec:
                return argv
            argv = [pkexec, *argv]
        if privileged:
            argv.append("--privileged")
        return argv

    def spec(self, action: str, args: list[str] | None = None, *, privileged: bool = True,
             title: str, expected: tuple[str, ...] = (), password: str = "", confirmation: bool = False,
             remote: bool = False) -> CommandSpec:
        secrets = [password] if password else []
        input_text = ("Confirm\n" if confirmation else "") + (password + "\n" if password else "")
        return CommandSpec(
            [*self._base(privileged), action, *(args or [])],
            title,
            input_text=input_text or None,
            secrets=secrets,
            expected=expected,
            remote=remote,
            success_label="The Pi-hole engine finished; read its own output above.",
            verified_label="The Pi-hole engine returned its verified-result marker.",
        )

    def assess(self, ip: str, network: str) -> CommandSpec:
        return self.spec("assess", ["--lan-ip", ip, "--network", network, "--json"], privileged=False,
                         title="Read-only Pi-hole host assessment", expected=("PIHOLE_ASSESSMENT_JSON=",))

    def install(self, ip: str, network: str, timezone: str, prevent_sleep: bool, password: str) -> CommandSpec:
        return self.spec("install", ["--lan-ip", ip, "--network", network, "--timezone", timezone,
                                      "--prevent-sleep", "yes" if prevent_sleep else "no"],
                         title="Install reviewed LAN-only Pi-hole", expected=("PIHOLE_INSTALL_VERIFIED",), password=password)

    def unraid_assess(self, target: str, ip: str, network: str, reserved: bool, always_on: bool) -> CommandSpec:
        return self.spec("unraid-assess", ["--target", target, "--lan-ip", ip, "--network", network,
                                            "--reserved", "yes" if reserved else "no", "--always-on", "yes" if always_on else "no"],
                         privileged=False, title="Read-only unRAID SSH, Docker, port and resource assessment",
                         expected=("PIHOLE_UNRAID_ASSESSMENT_JSON=",), remote=True)

    def unraid_install(self, target: str, ip: str, network: str, timezone: str, password: str) -> CommandSpec:
        return self.spec("unraid-install", ["--target", target, "--lan-ip", ip, "--network", network, "--timezone", timezone],
                         privileged=False, title="Install reviewed LAN-only Pi-hole on existing unRAID",
                         expected=("PIHOLE_UNRAID_INSTALL_VERIFIED",), password=password, confirmation=True, remote=True)

    def unraid_backup(self, target: str) -> CommandSpec:
        return self.spec("unraid-backup", ["--target", target], privileged=False,
                         title="Back up an existing unRAID Pi-hole before conflict resolution",
                         expected=("PIHOLE_UNRAID_BACKUP_VERIFIED=",), confirmation=True, remote=True)

    def unraid_health(self, target: str, ip: str) -> CommandSpec:
        return self.spec("unraid-health", ["--target", target, "--lan-ip", ip], privileged=False,
                         title="Check unRAID container plus real LAN DNS and web health",
                         expected=("PIHOLE_UNRAID_HEALTH_OK",), remote=True)

    def unraid_rollback(self, target: str, archive: str, ip: str) -> CommandSpec:
        return self.spec("unraid-rollback", ["--target", target, "--archive", archive, "--lan-ip", ip], privileged=False,
                         title="Restore a verified unRAID Pi-hole backup",
                         expected=("PIHOLE_UNRAID_ROLLBACK_VERIFIED",), confirmation=True, remote=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Whole-home Pi-hole")
    parser.add_argument("--demo", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--tab", "--view", dest="view", choices=("start", "router", "maintenance", "dhcp", "limits", "unraid"), default="start")
    args = parser.parse_args(argv)
    from gui_tools_launcher import check_native
    if not check_native("Whole-home Pi-hole"):
        return 1
    from pihole_gtk import PiHoleWindow, run_native
    return run_native(PiHoleWindow, "org.securelinux.PiHole", [sys.argv[0]],
                      backend=PiHoleBackend(), demo=args.demo, view=args.view)


if __name__ == "__main__":
    raise SystemExit(main())
