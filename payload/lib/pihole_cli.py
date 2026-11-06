#!/usr/bin/env python3
"""Narrow CLI for Secure Linux Pi-hole. Privileged actions require real root."""
from __future__ import annotations

import argparse
import getpass
import json
import os
from pathlib import Path
import sys

from pihole_core import (
    Engine,
    LIMITATIONS,
    PIHOLE_DIGEST,
    PIHOLE_IMAGE,
    PIHOLE_VERSION,
    PiHoleError,
    SOURCES,
    default_lan_ip,
    generate_password,
    network_for,
    power_guard,
    router_guide,
)
from pihole_unraid import UnraidEngine

ROOT_ACTIONS = {
    "install", "health", "backup", "restore", "check-update", "update", "rollback",
    "repair", "enable-dhcp", "disable-dhcp", "sleep-enable", "sleep-disable",
    "export-image", "power-guard", "test-dns",
}


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        prog="secure-linux-pihole",
        description="Reviewed, rootful-Docker Pi-hole for a private home LAN. No native curl|sh installer is used.",
        epilog="Official image: " + PIHOLE_IMAGE,
    )
    result.add_argument("--privileged", action="store_true", help=argparse.SUPPRESS)
    sub = result.add_subparsers(dest="action", required=True)
    assess = sub.add_parser("assess", help="Read-only host, Docker and port assessment")
    assess.add_argument("--lan-ip", default=default_lan_ip())
    assess.add_argument("--network", default="")
    assess.add_argument("--json", action="store_true")
    router = sub.add_parser("router-guide", help="Print model-pattern guidance, not a universal router UI")
    router.add_argument("choice", choices=("generic", "asus", "tplink", "fritzbox", "opnsense", "per-device"))
    router.add_argument("--lan-ip", default=default_lan_ip())
    sub.add_parser("limitations", help="Honest DNS filtering, device and availability limits")
    sub.add_parser("sources", help="Official references used by this implementation")
    install = sub.add_parser("install", help="Install the pinned image after an external review")
    install.add_argument("--lan-ip", required=True)
    install.add_argument("--network", required=True)
    install.add_argument("--timezone", required=True)
    install.add_argument("--prevent-sleep", choices=("yes", "no"), required=True)
    sub.add_parser("health", help="Require container, real DNS, web and selected power-guard checks")
    test = sub.add_parser("test-dns", help="Send a real local DNS request")
    test.add_argument("--hostname", default="example.com")
    backup = sub.add_parser("backup", help="Stop briefly, hash-verify, restart and health-check")
    backup.add_argument("--destination", type=Path)
    restore = sub.add_parser("restore", help="Verify, pre-backup, restore, health-check and rollback on failure")
    restore.add_argument("--archive", type=Path, required=True)
    sub.add_parser("check-update", help="Read the official latest release and registry digest")
    update = sub.add_parser("update", help="Update only to the separately reviewed version and digest")
    update.add_argument("--version", required=True)
    update.add_argument("--digest", required=True)
    sub.add_parser("rollback", help="Restore the verified pre-update backup")
    sub.add_parser("repair", help="Recreate from the saved pinned configuration and verify health")
    dhcp = sub.add_parser("enable-dhcp", help="Advanced: host networking and explicit one-DHCP-server acknowledgement")
    dhcp.add_argument("--interface", required=True)
    dhcp.add_argument("--start", required=True)
    dhcp.add_argument("--end", required=True)
    dhcp.add_argument("--router", required=True)
    dhcp.add_argument("--router-dhcp-disabled", required=True)
    dhcp.add_argument("--confirm", required=True)
    nodhcp = sub.add_parser("disable-dhcp", help="Return to bridge DNS after restoring router DHCP")
    nodhcp.add_argument("--router-dhcp-restored", required=True)
    sub.add_parser("sleep-enable", help="Enable the AC-only sleep/lid inhibitor service")
    sub.add_parser("sleep-disable", help="Disable the AC-only sleep/lid inhibitor service")
    export = sub.add_parser("export-image", help="Export and hash the exact pinned image for offline handoff")
    export.add_argument("--destination", type=Path, required=True)
    remote_assess = sub.add_parser("unraid-assess", help="Read-only SSH/Docker/port/resource assessment on existing unRAID")
    remote_assess.add_argument("--target", required=True)
    remote_assess.add_argument("--lan-ip", required=True)
    remote_assess.add_argument("--network", required=True)
    remote_assess.add_argument("--reserved", choices=("yes", "no"), required=True)
    remote_assess.add_argument("--always-on", choices=("yes", "no"), required=True)
    remote_install = sub.add_parser("unraid-install", help="Reviewed pinned LAN-only Pi-hole on existing unRAID over SSH")
    remote_install.add_argument("--target", required=True)
    remote_install.add_argument("--lan-ip", required=True)
    remote_install.add_argument("--network", required=True)
    remote_install.add_argument("--timezone", required=True)
    remote_backup = sub.add_parser("unraid-backup", help="Verified backup of an existing managed or conflicting unRAID Pi-hole")
    remote_backup.add_argument("--target", required=True)
    remote_health = sub.add_parser("unraid-health", help="Remote container plus real LAN DNS/web health")
    remote_health.add_argument("--target", required=True)
    remote_health.add_argument("--lan-ip", required=True)
    remote_rollback = sub.add_parser("unraid-rollback", help="Verify and restore an unRAID backup with health-based recovery")
    remote_rollback.add_argument("--target", required=True)
    remote_rollback.add_argument("--archive", required=True)
    remote_rollback.add_argument("--lan-ip", required=True)
    sub.add_parser("power-guard", help=argparse.SUPPRESS)
    return result


def read_password() -> str:
    if sys.stdin.isatty():
        first = getpass.getpass("Choose a Pi-hole admin password (12+ characters, hidden): ")
        second = getpass.getpass("Enter it once more: ")
        if first != second:
            raise PiHoleError("The two password entries did not match; nothing was installed.")
        return first
    # The GUI writes this directly to the privileged child's stdin. It is never
    # an argument, environment variable, Compose value or activity-log entry.
    return sys.stdin.read().removesuffix("\n")


def read_confirmation() -> str:
    if sys.stdin.isatty():
        return input("Type exactly Confirm to approve the reviewed remote action: ")
    return sys.stdin.read().splitlines()[0] if not sys.stdin.closed else ""


def read_unraid_password() -> tuple[str, str]:
    if sys.stdin.isatty():
        confirmation = input("Type exactly Confirm to approve the reviewed unRAID installation: ")
        return confirmation, getpass.getpass("Pi-hole admin password (hidden): ")
    lines = sys.stdin.read().splitlines()
    return (lines[0] if lines else ""), (lines[1] if len(lines) > 1 else "")


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if args.action in ROOT_ACTIONS and hasattr(os, "geteuid") and os.geteuid() != 0:
        print("PIHOLE_OPERATION_FAILED: Administrator permission is required. Use the graphical review or run this narrow command with sudo; the password is read only from standard input.", file=sys.stderr)
        return 1
    engine = Engine()
    try:
        if args.action == "assess":
            network = args.network or network_for(args.lan_ip)
            report = engine.assess(args.lan_ip, network)
            if args.json:
                print("PIHOLE_ASSESSMENT_JSON=" + json.dumps(report, sort_keys=True))
            else:
                print(json.dumps(report, indent=2, sort_keys=True))
            return 0 if report["ok"] else 1
        if args.action == "unraid-assess":
            remote = UnraidEngine(args.target)
            report = remote.assess(args.lan_ip, args.network, reserved=args.reserved == "yes", always_on=args.always_on == "yes")
            print("PIHOLE_UNRAID_ASSESSMENT_JSON=" + json.dumps(report, sort_keys=True))
            return 0 if report["ok"] else 1
        if args.action == "unraid-install":
            confirmation, password = read_unraid_password()
            config = {
                "format": 1, "lan_ip": args.lan_ip, "network": args.network,
                "timezone": args.timezone, "prevent_sleep": False, "dhcp": False,
                "version": PIHOLE_VERSION, "digest": PIHOLE_DIGEST, "image": PIHOLE_IMAGE,
            }
            UnraidEngine(args.target).install(config, password, confirmation)
            return 0
        if args.action == "unraid-backup":
            UnraidEngine(args.target).backup(read_confirmation())
            return 0
        if args.action == "unraid-health":
            report = UnraidEngine(args.target).health(args.lan_ip)
            print(report["detail"])
            if not report["ok"]:
                raise PiHoleError("unRAID container, real LAN DNS or LAN web health failed.")
            print("PIHOLE_UNRAID_HEALTH_OK")
            print("Admin URL: " + report["url"])
            return 0
        if args.action == "unraid-rollback":
            UnraidEngine(args.target).rollback(args.archive, read_confirmation(), args.lan_ip)
            return 0
        if args.action == "router-guide":
            print(router_guide(args.choice, args.lan_ip))
            return 0
        if args.action == "limitations":
            print(LIMITATIONS)
            return 0
        if args.action == "sources":
            print("\n".join(SOURCES))
            return 0
        if args.action == "install":
            config = {
                "format": 1,
                "lan_ip": args.lan_ip,
                "network": args.network,
                "timezone": args.timezone,
                "prevent_sleep": args.prevent_sleep == "yes",
                "dhcp": False,
                "version": PIHOLE_VERSION,
                "digest": PIHOLE_DIGEST,
                "image": PIHOLE_IMAGE,
            }
            engine.install(config, read_password())
            return 0
        if args.action == "health":
            report = engine.health()
            print(report["detail"])
            if not report["ok"]:
                raise PiHoleError("One or more health checks failed; Pi-hole is not reported healthy.")
            print("PIHOLE_HEALTH_OK")
            print("Admin URL: " + report["url"])
            return 0
        if args.action == "test-dns":
            from pihole_core import dns_query
            ok, detail = dns_query(engine.config()["lan_ip"], args.hostname)
            print(detail)
            if not ok:
                raise PiHoleError("The local DNS test failed; no success is claimed.")
            print("PIHOLE_DNS_TEST_OK")
            print("This proves a valid answer from Pi-hole, not that every device uses it or that every ad is blocked.")
            return 0
        if args.action == "backup":
            engine.backup(args.destination)
            return 0
        if args.action == "restore":
            engine.restore(args.archive)
            return 0
        if args.action == "check-update":
            engine.check_update()
            return 0
        if args.action == "update":
            engine.update(args.version, args.digest)
            return 0
        if args.action == "rollback":
            engine.rollback()
            return 0
        if args.action == "repair":
            engine.repair()
            return 0
        if args.action == "enable-dhcp":
            if args.router_dhcp_disabled != "I_DISABLED_ROUTER_DHCP" or args.confirm != "ENABLE_PIHOLE_DHCP":
                raise PiHoleError("Advanced DHCP requires both explicit acknowledgements. Router DHCP was not assumed to be disabled; nothing changed.")
            engine.set_dhcp(True, interface=args.interface, start=args.start, end=args.end, router=args.router)
            return 0
        if args.action == "disable-dhcp":
            if args.router_dhcp_restored != "I_RESTORED_ROUTER_DHCP":
                raise PiHoleError("Restore the router's DHCP first, then repeat with the explicit acknowledgement. Two active DHCP servers are never selected silently.")
            engine.set_dhcp(False)
            return 0
        if args.action in {"sleep-enable", "sleep-disable"}:
            enabled = args.action == "sleep-enable"
            if enabled:
                ac_online = __import__("pihole_core").ac_online(engine.sys_root / "sys/class/power_supply")
                if not ac_online:
                    raise PiHoleError("Plug in AC power before enabling the while-plugged-in guard. Nothing was enabled.")
            config = engine.config()
            engine.configure_sleep_guard(enabled)
            config["prevent_sleep"] = enabled
            engine.save_config(config)
            print("PIHOLE_SLEEP_GUARD_ENABLED_VERIFIED" if enabled else "PIHOLE_SLEEP_GUARD_DISABLED_VERIFIED")
            return 0
        if args.action == "export-image":
            engine.export_image(args.destination)
            return 0
        if args.action == "power-guard":
            return power_guard(engine)
        raise PiHoleError("Unsupported action.")
    except PiHoleError as exc:
        print("PIHOLE_OPERATION_FAILED: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
