#!/usr/bin/env python3
"""Native GTK4/Libadwaita task views for the isolated Pi-hole engine."""
from __future__ import annotations

import ipaddress
import json
import os
from pathlib import Path
import re
import webbrowser

from gui_tools_common import OperationResult
from gui_tools_gtk import (
    Adw, Gdk, Gtk, advanced, card, check, choose_path, dropdown, entry, field,
    run_native, set_text, text_view, ui, NativeOperationWindow,
)
from pihole_core import (
    LIMITATIONS, PIHOLE_DIGEST, PIHOLE_VERSION, RELEASE_NOTES, SOURCES,
    default_lan_ip, device_playbook, generate_password, network_for,
    router_blocking_guide, router_guide, valid_network,
)

ROUTERS = ("generic", "asus", "tplink", "fritzbox", "opnsense", "per-device")
ROUTER_LABELS = (
    "generic — common LAN/DHCP DNS pattern", "asus — ASUS LAN DNS guidance",
    "tplink — TP-Link / Deco official FAQ", "fritzbox — FRITZ!Box LAN + guest guidance",
    "opnsense — OPNsense DHCPv4 + IPv6", "per-device — manual DNS on selected devices",
)
DEVICES = ("samsung", "chromecast")
DEVICE_LABELS = (
    "samsung — Samsung TV router/client DNS playbook",
    "chromecast — Chromecast / Google TV router/client DNS playbook",
)


class PiHoleWindow(NativeOperationWindow):
    app_title = "Whole-home Pi-hole"
    app_subtitle = "Optional LAN-only DNS filtering with preflight, real health checks and rollback."

    def __init__(self, application, backend, *, runner=None, demo=False, view="start"):
        super().__init__(application, runner=runner, demo=demo)
        self.backend = backend
        self.assessment = None
        self.unraid_assessment = None
        self.update_candidate = None
        self.one_time_password = ""
        ip = default_lan_ip()
        timezone = self._default_timezone()
        self.lan_ip = entry(ip, description="This computer's reserved LAN IPv4", on_change=self._invalidate_assessment)
        self.network = entry(network_for(ip), description="LAN network in CIDR notation", on_change=self._invalidate_assessment)
        self.timezone = entry(timezone, description="Pi-hole timezone")
        self.always_on = check("This host will stay awake and connected; DNS stops when it does not")
        self.reserved = check("I reserved this exact address in the router or completed a supported static-IP setup")
        self.prevent_sleep = check("While plugged into AC only, prevent system sleep and logind lid suspend")
        self.hostname = entry("example.com", description="DNS name to resolve")
        self.backup_dir = entry("/var/lib/secure-linux/pihole/backups", description="Verified Pi-hole backup folder")
        self.router_choice = dropdown(ROUTER_LABELS, description="Router guidance pattern", on_change=lambda _value: self.show_router_guide())
        self.device_choice = dropdown(DEVICE_LABELS, description="Samsung or Chromecast test playbook")
        self.dhcp_interface = entry(self._default_interface(), description="Linux LAN interface")
        self.dhcp_router = entry(self._octet_address(ip, 1), description="DHCP gateway or router")
        self.dhcp_start = entry(self._octet_address(ip, 100), description="DHCP pool start")
        self.dhcp_end = entry(self._octet_address(ip, 200), description="DHCP pool end")
        self.dhcp_ack = check("I disabled DHCP on the router and verified no other DHCP server is active")
        self.dhcp_restore_ack = check("I restored and verified the router's DHCP server")
        self.unraid_target = entry("root@tower.local", description="unRAID root SSH login", on_change=self._invalidate_unraid_assessment)
        self.unraid_ip = entry(ip, description="unRAID Pi-hole LAN IPv4", on_change=self._invalidate_unraid_assessment)
        self.unraid_network = entry(network_for(ip), description="unRAID LAN network", on_change=self._invalidate_unraid_assessment)
        self.unraid_timezone = entry(timezone, description="unRAID Pi-hole timezone")
        self.unraid_reserved = check("I reserved this exact IP in the router or completed a supported static-IP setup")
        self.unraid_always_on = check("This unRAID server will stay awake and connected")
        self.unraid_archive = entry(description="Verified rollback archive path on unRAID")
        self._build_start()
        self._build_router()
        self._build_maintenance()
        self._build_dhcp()
        self._build_limits()
        self._build_unraid()
        self.finish_pages(view)
        if demo:
            self.assessment = {
                "ok": True, "blockers": [], "warnings": ["Preview laptop: sleep, lid closing and battery power can interrupt DNS for every device."],
                "ports": {"53/udp": True, "53/tcp": True, "80/tcp": True}, "memory_mb": 16384,
                "free_gb": 220, "docker": "Rootful Docker server is reachable (preview).", "battery": True,
            }
            self._render_assessment()
            self.append_output("Preview only. No Docker, DNS, router, update or power operation is contacted.")

    @staticmethod
    def _default_timezone():
        try:
            value = Path("/etc/timezone").read_text(encoding="utf-8").strip()
            if value:
                return value
        except OSError:
            pass
        return os.environ.get("TZ", "Etc/UTC")

    @staticmethod
    def _default_interface():
        try:
            names = sorted(name for name in os.listdir("/sys/class/net") if name != "lo")
            return names[0] if names else ""
        except OSError:
            return ""

    @staticmethod
    def _octet_address(ip, final):
        try:
            address = ipaddress.IPv4Address(ip)
            network = ipaddress.IPv4Network(f"{address}/24", strict=False)
            return str(ipaddress.IPv4Address(int(network.network_address) + final))
        except ipaddress.AddressValueError:
            return f"192.168.1.{final}"

    def _build_start(self):
        page = ui.page_box()
        ui.add_heading(page, "Check before your home relies on DNS", "Pi-hole is optional. It uses the existing rootful Docker service and pinned official image—never a curl-piped installer or rootless conversion.")
        address = card("1. Reserve a LAN address", "Reserve this address in the router or follow supported static-IP guidance outside the DHCP pool. A changing address breaks client DNS.")
        field(address, "This computer's IPv4", self.lan_ip)
        field(address, "LAN network", self.network)
        tz_expander, tz_body = advanced("Advanced: timezone")
        field(tz_body, "Timezone", self.timezone)
        address.append(tz_expander)
        page.append(address)
        page.append(ui.button("Assess this computer — read only", self.assess, primary=True))
        scroll, self.assessment_text = text_view("No assessment yet. The read-only check tests actual 53/UDP, 53/TCP and 80/TCP binds, RAM, storage, Docker/Compose and laptop power risks. It cannot prove always-on behavior or your router reservation.", height=180, name="Host preflight assessment")
        page.append(scroll)
        choices = card("2. Confirm availability and power", "The app cannot prove your router reservation or that this host will remain awake.")
        choices.append(self.always_on)
        choices.append(self.reserved)
        power_expander, power_body = advanced("Advanced: optional AC-only sleep guard")
        power_body.append(self.prevent_sleep)
        power_body.append(ui.label("This increases power use. On battery the guard releases. Desktop and firmware lid behavior can differ, so test it. No power setting changes unless selected and approved again.", css=("sl-caption", "sl-muted")))
        choices.append(power_expander)
        page.append(choices)
        page.append(ui.button("Review & install LAN-only Pi-hole…", self.install, primary=True))
        self.add_page("start", "Start here", "go-home-symbolic", page)

    def _build_router(self):
        page = ui.page_box()
        ui.add_heading(page, "Tell devices to use Pi-hole", "Installation alone does not change device DNS. Reserve the host address, then give it to DHCP clients as their DNS server.")
        guide = card("Router guidance", "Menu names vary by router model and firmware. This is a pattern, not a universal router interface.")
        field(guide, "Router pattern", self.router_choice)
        guide.append(ui.button("Copy guidance", self.copy_router_guide))
        page.append(guide)
        scroll, self.router_text = text_view("", height=300, name="Router or device DNS guidance")
        page.append(scroll)
        device_expander, device_body = advanced("Advanced: Samsung TV and Chromecast test playbooks")
        field(device_body, "Device playbook", self.device_choice)
        device_body.append(ui.button("Show test playbook", self.show_device_playbook))
        device_body.append(ui.button("Review optional router blocking rules…", self.show_router_blocking))
        page.append(device_expander)
        verify = card("Verify this host, then test another device separately", "A valid answer proves this host's Pi-hole responded. It does not prove other devices use it, hard-coded DNS is covered, or all ads disappear.")
        field(verify, "DNS name to resolve", self.hostname)
        verify.append(ui.button("Run real local DNS test", self.test_dns, primary=True))
        verify.append(ui.button("Open LAN admin page", self.open_admin))
        page.append(verify)
        self.add_page("router", "Connect devices", "network-workgroup-symbolic", page)
        self.show_router_guide()

    def _build_maintenance(self):
        page = ui.page_box()
        ui.add_heading(page, "Maintenance with receipts and a way back", "Backups stop DNS briefly for a consistent copy. Updates are manual and target an exact official release and digest.")
        health = card("Health and repair", "Healthy means container running + matching real DNS response + LAN web response + selected sleep guard active. A zero exit alone is not health.")
        health.append(ui.button("Check real health", self.health, primary=True))
        health.append(ui.button("Review container repair…", self.repair))
        page.append(health)
        backup = card("Verified backup and restore", "Archives are hash-verified and root-only. The password file is excluded; restore keeps this host's existing password and makes a fresh pre-restore backup first.")
        row = ui.responsive_row(spacing=12)
        row.append(self.backup_dir)
        row.append(ui.button("Choose…", lambda: choose_path(self, self.backup_dir.set_text, folder=True, title="Choose verified-backup folder")))
        field(backup, "Backup folder", row)
        backup.append(ui.button("Review verified backup…", self.backup))
        backup.append(ui.button("Choose & review restore…", self.restore))
        page.append(backup)
        update_expander, update_body = advanced("Advanced: exact image updates and rollback")
        update_body.append(ui.label(f"Installed target at first setup: {PIHOLE_VERSION}\nDigest: {PIHOLE_DIGEST}", css=("sl-caption",)))
        update_body.append(ui.button("Check official release & digest", self.check_update))
        self.update_button = ui.button("Review fetched update…", self.update, primary=True)
        self.update_button.set_sensitive(False)
        update_body.append(self.update_button)
        update_body.append(ui.button("Open release notes", lambda: webbrowser.open(RELEASE_NOTES)))
        update_body.append(ui.button("Review rollback to pre-update backup…", self.rollback))
        page.append(update_expander)
        power_expander, power_body = advanced("Advanced: AC-only sleep guard")
        power_body.append(ui.button("Review enable while plugged in…", lambda: self.sleep_guard(True)))
        power_body.append(ui.button("Disable sleep guard", lambda: self.sleep_guard(False)))
        power_body.append(ui.label("Disabling can let the host sleep and interrupt home DNS. Firmware behavior is not guaranteed.", css=("sl-caption", "sl-muted")))
        page.append(power_expander)
        self.add_page("maintenance", "Backup & updates", "document-save-symbolic", page)

    def _build_dhcp(self):
        page = ui.page_box()
        ui.add_heading(page, "Optional DHCP — advanced", "Most homes should skip this page and leave DHCP on the router. Two active DHCP servers can cause random address, gateway and DNS failures.")
        page.append(card("Exactly one DHCP server", "Pi-hole DHCP uses host networking for LAN broadcasts. The web server stays bound to the selected LAN IP. The app never scans for or disables another DHCP server."))
        expander, body = advanced("Advanced values — verify against your actual LAN")
        for title, widget in (("Linux LAN interface", self.dhcp_interface), ("DHCP pool start", self.dhcp_start), ("DHCP pool end", self.dhcp_end), ("Gateway / router", self.dhcp_router)):
            field(body, title, widget)
        body.append(ui.label("The reserved Pi-hole IP must be outside this pool. All addresses must be inside the LAN network entered on Start here.", css=("sl-caption", "sl-muted")))
        body.append(self.dhcp_ack)
        body.append(ui.button("Review advanced Pi-hole DHCP conversion…", self.enable_dhcp, primary=True))
        page.append(expander)
        restore = card("Return to router DHCP first", "Before disabling Pi-hole DHCP, restore and verify the router's DHCP. Otherwise devices may receive no address at all.")
        restore.append(self.dhcp_restore_ack)
        restore.append(ui.button("Review return to DNS-only mode…", self.disable_dhcp))
        page.append(restore)
        self.add_page("dhcp", "Advanced DHCP", "network-wired-symbolic", page)

    def _build_limits(self):
        page = ui.page_box()
        ui.add_heading(page, "What Pi-hole can — and cannot — promise", "Device behavior, encrypted or hard-coded DNS, same-domain content and host availability set real limits.")
        scroll, _view = text_view(LIMITATIONS, height=340, name="Pi-hole limitations")
        page.append(scroll)
        expander, body = advanced("Official sources and release notes")
        source_scroll, _source_view = text_view("\n".join(SOURCES), height=220, name="Official implementation sources")
        body.append(source_scroll)
        body.append(ui.button("Open official Pi-hole documentation", lambda: webbrowser.open("https://docs.pi-hole.net/")))
        body.append(ui.button("Open pinned release notes", lambda: webbrowser.open(SOURCES[-2])))
        page.append(expander)
        self.add_page("limits", "Limits & sources", "dialog-information-symbolic", page)

    def _build_unraid(self):
        page = ui.page_box()
        ui.add_heading(page, "Deploy on an unRAID server you already own", "Four inputs, then read-only preflight. unRAID is not installed or converted; SSH keys and rootful Docker must already work.")
        form = card("Server and reserved LAN address", "DNS and the admin page bind only to this private LAN IP. Preflight measures SSH/root, Docker/Compose, ports, RAM and /mnt/user storage.")
        for title, widget in (("unRAID root SSH login", self.unraid_target), ("Pi-hole LAN IPv4", self.unraid_ip), ("LAN network", self.unraid_network), ("Timezone", self.unraid_timezone)):
            field(form, title, widget)
        form.append(self.unraid_reserved)
        form.append(self.unraid_always_on)
        form.append(ui.button("Assess unRAID — read only", self.assess_unraid, primary=True))
        page.append(form)
        scroll, self.unraid_assessment_text = text_view("No assessment yet. An existing pihole container is a hard conflict, never silently adopted. Checks are point-in-time measurements, not a promise of zero load or issues.", height=180, name="unRAID preflight assessment")
        page.append(scroll)
        tasks = card("Install, verify or preserve an existing deployment", "A failed new install removes only its new container. Backup briefly stops the existing container and does not resolve a conflict or install anything.")
        tasks.append(ui.button("Review & install…", self.install_unraid, primary=True))
        tasks.append(ui.button("Check real health", self.health_unraid))
        tasks.append(ui.button("Review backup of an existing unRAID Pi-hole…", self.backup_unraid))
        page.append(tasks)
        expander, body = advanced("Advanced: verified unRAID rollback")
        field(body, "Backup archive on unRAID", self.unraid_archive)
        body.append(ui.label("Rollback verifies archive hashes, preserves the current deployment, restores the backup, and requires remote container + real LAN DNS + LAN web health. Failure attempts restoration of the prior state.", css=("sl-caption", "sl-muted")))
        body.append(ui.button("Review verified rollback…", self.rollback_unraid, primary=True))
        page.append(expander)
        self.add_page("unraid", "unRAID server", "network-server-symbolic", page)

    def _invalidate_assessment(self, *_args):
        if not self.demo:
            self.assessment = None

    def _invalidate_unraid_assessment(self, *_args):
        if not self.demo:
            self.unraid_assessment = None

    def _values(self):
        try:
            return valid_network(self.lan_ip.get_text().strip(), self.network.get_text().strip())
        except Exception as exc:
            self.notify("LAN address needs attention", str(exc))
            return None

    def _unraid_values(self):
        target = self.unraid_target.get_text().strip()
        if not re.fullmatch(r"(?:[A-Za-z_][A-Za-z0-9._-]{0,63}@)?[A-Za-z0-9][A-Za-z0-9.-]{0,253}", target) or any(part in target for part in ("..", ".-", "-.", "@-", "@.")):
            self.notify("unRAID SSH login not accepted", "Use root@server.local or root@IP-address, without options or shell characters.")
            return None
        try:
            ip, network = valid_network(self.unraid_ip.get_text().strip(), self.unraid_network.get_text().strip())
            return target, ip, network
        except Exception as exc:
            self.notify("unRAID LAN address needs attention", str(exc))
            return None

    def assess(self):
        values = self._values()
        if values:
            self.run(self.backend.assess(*values), "assess")

    def assess_unraid(self):
        values = self._unraid_values()
        if values:
            self.run(self.backend.unraid_assess(*values, self.unraid_reserved.get_active(), self.unraid_always_on.get_active()), "unraid-assess")

    @staticmethod
    def _assessment_lines(report, unraid=False):
        lines = ["SUITABLE FOR REVIEW" if report["ok"] else "NOT READY — installation is blocked", ""]
        lines.append("Ports: " + ", ".join(f"{name} {'free' if free else 'CONFLICT'}" for name, free in report["ports"].items()))
        if unraid:
            lines.append(f"Measured: {report.get('memory_mb', 0)} MiB RAM • {report.get('free_gb', 0)} GiB free on /mnt/user")
        else:
            lines.append(f"Resources: {report.get('memory_mb', 0)} MiB RAM • {report.get('free_gb', 0)} GiB free • {report.get('architecture', 'unknown')}")
        lines.append(report.get("docker", "Docker status unknown"))
        lines.extend("BLOCKER: " + item for item in report.get("blockers", []))
        lines.extend("WARNING: " + item for item in report.get("warnings", []))
        return "\n\n".join(lines)

    def _render_assessment(self):
        if self.assessment is not None:
            set_text(self.assessment_text, self._assessment_lines(self.assessment))

    def _render_unraid_assessment(self):
        if self.unraid_assessment is not None:
            set_text(self.unraid_assessment_text, self._assessment_lines(self.unraid_assessment, True))

    def _install_review(self, summary, prevent_sleep, callback):
        power = ("\n\nPower choice: while AC reports plugged in, a visible systemd service inhibits sleep and logind lid actions. On battery it releases. This increases power use; test exact hardware behavior." if prevent_sleep else
                 "\n\nNo sleep setting will be changed. If this computer sleeps or its lid closes, home DNS can stop.")
        self.review("Review whole-home Pi-hole installation", summary + power, ("Confirm",), callback,
                    secret_label="Admin password — generated locally, or replace it (12–256 characters)",
                    initial_secret=generate_password(), password_policy=True, generate_secret=generate_password)

    def install(self):
        values = self._values()
        if not values:
            return
        if self.assessment is None or not self.assessment.get("ok"):
            self.notify("Assess first", "Run the read-only assessment for this exact IP/network and resolve every blocker first.")
            return
        if not self.always_on.get_active() or not self.reserved.get_active():
            self.notify("Two manual checks remain", "Confirm both always-on availability and the router/static address reservation. The app cannot prove those for you.")
            return
        ip, network = values
        prevent_sleep = self.prevent_sleep.get_active()
        summary = f"Install official Pi-hole {PIHOLE_VERSION} at the verified registry digest on {ip} ({network}).\n\nDocker will publish DNS 53/TCP+UDP and web 80/TCP only on this private LAN IP. No WAN port, internet forwarding or UPnP rule is configured. The pinned image will be pulled only if the exact image is not already local.\n\nThe engine rechecks ports and requires real DNS and LAN web responses before success. Installation alone does not change device or router DNS."
        def begin(password):
            self.one_time_password = password
            self.run(self.backend.install(ip, network, self.timezone.get_text().strip(), prevent_sleep, password), "install")
        self._install_review(summary, prevent_sleep, begin)

    def install_unraid(self):
        values = self._unraid_values()
        if not values:
            return
        if self.unraid_assessment is None or not self.unraid_assessment.get("ok"):
            self.notify("Assess unRAID first", "Run preflight for this exact target/IP/network with both manual checks ticked, then resolve every blocker.")
            return
        target, ip, network = values
        summary = f"Install official Pi-hole {PIHOLE_VERSION} at the verified registry digest on existing unRAID server {target}, LAN {ip} ({network}).\n\nPreflight is repeated before any write. DNS and web bind only to the private LAN IP. No WAN forwarding, UPnP, rootless conversion or unRAID installation occurs. Any same-name existing container is a hard conflict.\n\nSuccess requires remote container + real LAN DNS + LAN web health, then a verified backup and another health check. A failed new install removes only its new container."
        def begin(password):
            self.one_time_password = password
            self.run(self.backend.unraid_install(target, ip, network, self.unraid_timezone.get_text().strip(), password), "unraid-install")
        self._install_review(summary, False, begin)

    def show_router_guide(self):
        choice = ROUTERS[self.router_choice.get_selected()] if self.router_choice.get_selected() != Gtk.INVALID_LIST_POSITION else "generic"
        set_text(self.router_text, router_guide(choice, self.lan_ip.get_text().strip()))

    def show_device_playbook(self):
        choice = DEVICES[self.device_choice.get_selected()]
        set_text(self.router_text, device_playbook(choice, self.lan_ip.get_text().strip()))
        self.activity_label.set_label("Guided playbook shown. Validate it on the real device and router; DNS visibility does not guarantee ad removal.")

    def show_router_blocking(self):
        warning = "OPTIONAL router firewall rules can break Chromecast, Samsung TV, VPNs, updates, work/school apps and DNS recovery. They cannot cover every encrypted-DNS path or same-domain ads and never guarantee all ads are blocked.\n\nThis shows a vendor-neutral rule plan only. It does not change your router. Confirm that you accept the breakage risk and will keep a way to disable the rules."
        def show(_secret):
            set_text(self.router_text, router_blocking_guide(self.lan_ip.get_text().strip()))
            self.activity_label.set_label("Advanced rule plan shown only after confirmation. Verify your router manual and recovery path.")
        self.review("Review optional DNS blocking — breakage warning", warning, ("Confirm",), show)

    def copy_router_guide(self):
        buffer = self.router_text.get_buffer()
        text = buffer.get_text(buffer.get_start_iter(), buffer.get_end_iter(), False)
        Gdk.Display.get_default().get_clipboard().set(text)
        self.activity_label.set_label("Guidance copied. Verify labels and rules against your exact model; no ad-blocking guarantee is made.")

    def open_admin(self):
        values = self._values()
        if values:
            webbrowser.open(f"http://{values[0]}/admin/")

    def test_dns(self):
        hostname = self.hostname.get_text().strip()
        if not re.fullmatch(r"(?:[A-Za-z0-9-]+\.)+[A-Za-z0-9-]+", hostname):
            self.notify("DNS name not accepted", "Use a simple name such as example.com.")
            return
        self.run(self.backend.spec("test-dns", ["--hostname", hostname], title="Real local DNS query", expected=("PIHOLE_DNS_TEST_OK",)), "dns")

    def health(self):
        self.run(self.backend.spec("health", title="Container + DNS + LAN web + power health", expected=("PIHOLE_HEALTH_OK",)), "health")

    def repair(self):
        self.review("Review Pi-hole repair", "Recreate the container from the saved pinned configuration, then require real DNS and LAN web health. No new image is selected and no router setting changes.", ("Confirm",), lambda _secret: self.run(self.backend.spec("repair", title="Repair and verify Pi-hole", expected=("PIHOLE_REPAIR_VERIFIED",)), "repair"))

    def backup(self):
        destination = self.backup_dir.get_text().strip()
        if destination:
            summary = "Stop Pi-hole briefly so its databases are consistent, create and hash-verify a root-only archive, restart it, and require full health. Home DNS can be unavailable during the stop. The password file is not included."
            self.review("Review backup with short DNS interruption", summary, ("Confirm",), lambda _secret: self.run(self.backend.spec("backup", ["--destination", destination], title="Verified consistent Pi-hole backup", expected=("PIHOLE_BACKUP_VERIFIED=",)), "backup"))

    def restore(self):
        def selected(path):
            summary = f"Verify {path}, create a fresh pre-restore backup, stop DNS, replace Pi-hole configuration, and require full health. Failure attempts restoration of the prior state. The current admin password is retained."
            self.review("Review Pi-hole restore", summary, ("RESTORE", "Confirm"), lambda _secret: self.run(self.backend.spec("restore", ["--archive", path], title="Verified Pi-hole restore with rollback", expected=("PIHOLE_RESTORE_VERIFIED",)), "restore"))
        choose_path(self, selected, folder=False, title="Choose a verified Pi-hole backup")

    def check_update(self):
        self.update_candidate = None
        self.update_button.set_sensitive(False)
        self.run(self.backend.spec("check-update", title="Fetch official latest release and registry digest", expected=("PIHOLE_UPDATE_JSON=",)), "update-check")

    def update(self):
        candidate = self.update_candidate
        if not candidate or not candidate.get("update_available"):
            return
        version, digest = candidate["version"], candidate["digest"]
        summary = f"Update from {candidate['current_version']} to exactly {version}\n{digest}\n\nRelease notes: {candidate['notes']}\n\nRead Docker and component notes first. The engine downloads the exact digest, creates a verified pre-update backup, recreates the container and requires real health. Failure attempts full image+configuration rollback. No future automatic update is enabled."
        self.review("Review exact Pi-hole update", summary, (f"UPDATE {version}", "Confirm"), lambda _secret: self.run(self.backend.spec("update", ["--version", version, "--digest", digest], title=f"Reviewed Pi-hole update to {version}", expected=("PIHOLE_UPDATE_VERIFIED=",)), "update"))

    def rollback(self):
        summary = "Restore the verified backup made immediately before the last reviewed update. This stops DNS, restores both prior image and configuration, and requires health. It is not a general undo for later manual changes."
        self.review("Review rollback to pre-update state", summary, ("ROLLBACK", "Confirm"), lambda _secret: self.run(self.backend.spec("rollback", title="Restore verified pre-update backup", expected=("PIHOLE_ROLLBACK_VERIFIED",)), "rollback"))

    def sleep_guard(self, enabled):
        summary = ("Enable a visible systemd guard only while an AC sensor reports plugged in. It inhibits sleep and logind lid actions, increases power use, and releases on battery. Test your exact laptop/desktop; firmware behavior is not guaranteed." if enabled else "Disable the AC-only sleep guard. Normal sleep and lid behavior returns; home DNS can stop when this host sleeps.")
        action = "sleep-enable" if enabled else "sleep-disable"
        marker = "PIHOLE_SLEEP_GUARD_ENABLED_VERIFIED" if enabled else "PIHOLE_SLEEP_GUARD_DISABLED_VERIFIED"
        self.review("Review sleep and power change", summary, ("Confirm",), lambda _secret: self.run(self.backend.spec(action, title="Change reviewed AC-only sleep guard", expected=(marker,)), "sleep"))

    def enable_dhcp(self):
        if not self.dhcp_ack.get_active():
            self.notify("Disable router DHCP first", "The app will not enable a second DHCP server. Disable and verify the router's DHCP first.")
            return
        if not self._values():
            return
        summary = f"Convert an existing healthy Pi-hole to host networking and enable its DHCP server. This can interrupt every device's address and DNS configuration.\n\nInterface: {self.dhcp_interface.get_text()}\nPool: {self.dhcp_start.get_text()} – {self.dhcp_end.get_text()}\nGateway: {self.dhcp_router.get_text()}\n\nThe engine validates the interface and addresses, makes a verified backup, and rolls back on failure."
        def begin(_secret):
            args = ["--interface", self.dhcp_interface.get_text().strip(), "--start", self.dhcp_start.get_text().strip(), "--end", self.dhcp_end.get_text().strip(), "--router", self.dhcp_router.get_text().strip(), "--router-dhcp-disabled", "I_DISABLED_ROUTER_DHCP", "--confirm", "ENABLE_PIHOLE_DHCP"]
            self.run(self.backend.spec("enable-dhcp", args, title="Advanced reviewed Pi-hole DHCP", expected=("PIHOLE_DHCP_ENABLED_VERIFIED",)), "dhcp")
        self.review("Advanced: exactly one DHCP server", summary, ("I DISABLED ROUTER DHCP", "ENABLE PIHOLE DHCP"), begin)

    def disable_dhcp(self):
        if not self.dhcp_restore_ack.get_active():
            self.notify("Restore router DHCP first", "Avoid zero DHCP servers: restore and verify the router's DHCP before disabling Pi-hole DHCP.")
            return
        summary = "Return Pi-hole to bridge-mode DNS-only after you restored the router's DHCP. A verified backup and health-based rollback are used. Renew one test device's lease after the change."
        self.review("Review return to DNS-only", summary, ("I RESTORED ROUTER DHCP", "Confirm"), lambda _secret: self.run(self.backend.spec("disable-dhcp", ["--router-dhcp-restored", "I_RESTORED_ROUTER_DHCP"], title="Return to DNS-only Pi-hole", expected=("PIHOLE_DHCP_DISABLED_VERIFIED",)), "dhcp"))

    def backup_unraid(self):
        values = self._unraid_values()
        if values:
            summary = "Stop the existing unRAID pihole container briefly, back up managed configuration or unmanaged inspect/data, verify remote hashes, restart it, and require health for a managed deployment. The admin password file is excluded. This does not resolve the container conflict or install anything."
            self.review("Review existing unRAID Pi-hole backup", summary, ("Confirm",), lambda _secret: self.run(self.backend.unraid_backup(values[0]), "unraid-backup"))

    def health_unraid(self):
        values = self._unraid_values()
        if values:
            self.run(self.backend.unraid_health(values[0], values[1]), "unraid-health")

    def rollback_unraid(self):
        values = self._unraid_values()
        archive = self.unraid_archive.get_text().strip()
        if not values or not archive:
            self.notify("Backup path required", "Enter the verified backup path returned on unRAID by the install or backup action.")
            return
        summary = f"Verify {archive}, stop DNS, preserve the current deployment, restore the backup, and require real LAN health. Failure attempts to restore and health-check the prior state. The current admin password is retained."
        self.review("Review unRAID Pi-hole rollback", summary, ("Confirm",), lambda _secret: self.run(self.backend.unraid_rollback(values[0], archive, values[1]), "unraid-rollback"))

    def _password_once(self, password):
        dialog = Adw.Dialog(title="Save your Pi-hole admin password now")
        dialog.set_content_width(620)
        dialog.set_content_height(340)
        toolbar = Adw.ToolbarView()
        toolbar.add_top_bar(Adw.HeaderBar())
        page = ui.page_box()
        for margin in (24,):
            page.set_margin_top(margin)
            page.set_margin_bottom(margin)
            page.set_margin_start(margin)
            page.set_margin_end(margin)
        page.append(ui.label("Shown once — save it somewhere private", css=("sl-title",)))
        page.append(ui.label("This is not your Linux password. Closing clears the app's copy; activity contains only [hidden]. Do not post it in chat, screenshots or router settings.", css=("sl-body",)))
        secret = entry(password, description="One-time Pi-hole admin password")
        secret.set_editable(False)
        page.append(secret)
        page.append(ui.button("Copy", lambda: Gdk.Display.get_default().get_clipboard().set(password)))
        def close():
            secret.set_text("")
            self.one_time_password = ""
            dialog.close()
        page.append(ui.button("I saved it — close and clear", close, primary=True))
        dialog.connect("closed", lambda _dialog: (secret.set_text(""), setattr(self, "one_time_password", "")))
        toolbar.set_content(page)
        dialog.set_child(toolbar)
        dialog.present(self)

    def _finished(self, result: OperationResult, output: str):
        kind = self.pending_kind
        super()._finished(result, output)
        if kind == "assess":
            match = re.search(r"^PIHOLE_ASSESSMENT_JSON=(.+)$", output, re.MULTILINE)
            if match:
                try:
                    self.assessment = json.loads(match.group(1))
                    self._render_assessment()
                except json.JSONDecodeError:
                    self.assessment = None
        elif kind == "unraid-assess":
            match = re.search(r"^PIHOLE_UNRAID_ASSESSMENT_JSON=(.+)$", output, re.MULTILINE)
            if match:
                try:
                    self.unraid_assessment = json.loads(match.group(1))
                    self._render_unraid_assessment()
                except json.JSONDecodeError:
                    self.unraid_assessment = None
        elif kind in {"install", "unraid-install"} and result.state == "verified" and self.one_time_password:
            password, self.one_time_password = self.one_time_password, ""
            self._password_once(password)
        elif kind in {"install", "unraid-install"} and result.state != "verified":
            self.one_time_password = ""
        elif kind == "update-check":
            match = re.search(r"^PIHOLE_UPDATE_JSON=(.+)$", output, re.MULTILINE)
            if match:
                try:
                    candidate = json.loads(match.group(1))
                    if candidate.get("update_available"):
                        self.update_candidate = candidate
                        self.update_button.set_sensitive(True)
                    else:
                        self.activity_label.set_label("The installed pinned image already matches the official latest release returned by the APIs.")
                except json.JSONDecodeError:
                    self.update_candidate = None
        elif kind == "update":
            self.update_candidate = None
            self.update_button.set_sensitive(False)
        if kind in {"unraid-install", "unraid-backup"}:
            match = re.search(r"(?:Verified rollback backup: |^PIHOLE_UNRAID_BACKUP_VERIFIED=)(/[^\s]+\.tar\.gz)", output, re.MULTILINE)
            if match:
                self.unraid_archive.set_text(match.group(1))
