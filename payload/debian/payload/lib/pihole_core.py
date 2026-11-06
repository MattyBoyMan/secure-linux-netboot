#!/usr/bin/env python3
"""Secure Linux Pi-hole engine.

Standard-library-only, rootful-Docker deployment with a pinned official image.
The GUI supplies reviewed arguments; secrets arrive only on standard input.
No function in this module downloads or executes a native installer script.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import http.client
import ipaddress
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import secrets as random_secrets
import shutil
import socket
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
from typing import Callable, Iterable
from urllib.request import Request, urlopen

PIHOLE_VERSION = "2026.10.1"
PIHOLE_DIGEST = "sha256:30f803ad5dd60ff96cc0a63008a2e9271af481c1b0399a182192b2e91152c1f9"
PIHOLE_IMAGE = f"pihole/pihole:{PIHOLE_VERSION}@{PIHOLE_DIGEST}"
STATE_DEFAULT = Path("/var/lib/secure-linux/pihole")
RELEASE_API = "https://api.github.com/repos/pi-hole/docker-pi-hole/releases/latest"
REGISTRY_TAG_API = "https://hub.docker.com/v2/repositories/pihole/pihole/tags/"
RELEASE_NOTES = "https://github.com/pi-hole/docker-pi-hole/releases"
SOURCES = (
    "https://pi-hole.net/",
    "https://docs.pi-hole.net/docker/",
    "https://docs.pi-hole.net/docker/configuration/",
    "https://docs.pi-hole.net/docker/upgrading/",
    "https://docs.pi-hole.net/docker/dhcp/",
    "https://docs.pi-hole.net/main/prerequisites/",
    "https://docs.pi-hole.net/main/post-install/",
    "https://docs.pi-hole.net/ftldns/interfaces/",
    "https://docs.pi-hole.net/ftldns/configfile/",
    "https://docs.pi-hole.net/routers/asus/",
    "https://docs.pi-hole.net/routers/fritzbox/",
    "https://docs.pi-hole.net/routers/opnsense/",
    "https://docs.pi-hole.net/routers/tp-link/",
    "https://github.com/pi-hole/docker-pi-hole/releases/tag/2026.10.1",
    REGISTRY_TAG_API + PIHOLE_VERSION,
)
VERSION_RE = re.compile(r"^20[0-9]{2}\.(?:0[1-9]|1[0-2])\.[0-9]+$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
TZ_RE = re.compile(r"^[A-Za-z_]+(?:/[A-Za-z0-9_+.-]+){1,3}$")


class PiHoleError(RuntimeError):
    """An operation did not complete and must not be presented as success."""


@dataclass
class Reply:
    returncode: int
    output: str


Runner = Callable[..., Reply]


def command(argv: Iterable[str], *, timeout: int = 120, input_text: str | None = None) -> Reply:
    args = [str(part) for part in argv]
    try:
        result = subprocess.run(
            args,
            input=input_text,
            stdin=subprocess.DEVNULL if input_text is None else None,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            check=False,
            shell=False,
        )
        return Reply(result.returncode, result.stdout or "")
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout or ""
        if isinstance(output, bytes):
            output = output.decode("utf-8", "replace")
        return Reply(124, output + f"\nTimed out after {timeout} seconds.")
    except OSError as exc:
        return Reply(127, str(exc))


def require_ok(reply: Reply, action: str) -> Reply:
    if reply.returncode != 0:
        raise PiHoleError(f"{action} failed (status {reply.returncode}).\n{reply.output.strip()}")
    return reply


def valid_network(lan_ip: str, cidr: str) -> tuple[str, str]:
    try:
        address = ipaddress.IPv4Address(lan_ip)
        network = ipaddress.IPv4Network(cidr, strict=True)
    except ipaddress.AddressValueError as exc:
        raise PiHoleError(f"Use a valid private IPv4 address and network: {exc}") from exc
    except ipaddress.NetmaskValueError as exc:
        raise PiHoleError(f"Use a valid IPv4 network such as 192.168.1.0/24: {exc}") from exc
    if not address.is_private or address.is_loopback or address.is_link_local or address.is_multicast:
        raise PiHoleError("The Pi-hole address must be a private, non-loopback LAN IPv4 address.")
    if address not in network or address in {network.network_address, network.broadcast_address}:
        raise PiHoleError("The Pi-hole address must be a usable host address inside the entered LAN network.")
    if network.prefixlen < 8 or network.prefixlen > 30:
        raise PiHoleError("Use a LAN prefix between /8 and /30.")
    return str(address), str(network)


def valid_timezone(value: str) -> str:
    if not TZ_RE.fullmatch(value) or ".." in value:
        raise PiHoleError("Use an IANA timezone such as Australia/Sydney.")
    try:
        from zoneinfo import ZoneInfo
        ZoneInfo(value)
    except Exception as exc:
        raise PiHoleError(f"Timezone '{value}' is not available on this computer.") from exc
    return value


def valid_image(version: str, digest: str) -> str:
    if not VERSION_RE.fullmatch(version) or not DIGEST_RE.fullmatch(digest):
        raise PiHoleError("A dated Pi-hole release and an exact lowercase sha256 registry digest are required.")
    return f"pihole/pihole:{version}@{digest}"


def validate_password(password: str) -> str:
    if not 12 <= len(password) <= 256 or "\n" in password or "\r" in password or "\x00" in password:
        raise PiHoleError("Use an admin password of 12–256 characters without newlines or NUL.")
    if not password.strip():
        raise PiHoleError("The admin password cannot be only whitespace.")
    return password


def generate_password() -> str:
    return random_secrets.token_urlsafe(18)


def atomic_write(path: Path, text: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    tmp = Path(temporary)
    try:
        if hasattr(os, "fchmod"):
            os.fchmod(fd, mode)
        else:
            # Native Windows preview/tests have no fchmod; Linux always takes
            # the branch above and enforces the requested owner-only mode.
            os.chmod(tmp, mode)
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
        os.chmod(path, mode)
    except Exception:
        try:
            os.close(fd)
        except OSError:
            pass
        tmp.unlink(missing_ok=True)
        raise


def yaml_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def compose_text(config: dict, image: str | None = None) -> str:
    lan_ip, network = valid_network(config["lan_ip"], config["network"])
    timezone_name = valid_timezone(config["timezone"])
    image = image or config["image"]
    dhcp = bool(config.get("dhcp"))
    lines = [
        "# Secure Linux Pi-hole. Reviewed rootful Docker deployment; LAN only.",
        "services:",
        "  pihole:",
        "    container_name: pihole",
        f"    image: {image}",
    ]
    if dhcp:
        for key in ("interface", "dhcp_start", "dhcp_end", "dhcp_router"):
            if not config.get(key):
                raise PiHoleError("Advanced DHCP needs an interface, pool start/end and router address.")
        start = ipaddress.IPv4Address(config["dhcp_start"])
        end = ipaddress.IPv4Address(config["dhcp_end"])
        router = ipaddress.IPv4Address(config["dhcp_router"])
        lan_network = ipaddress.IPv4Network(network)
        if not all(item in lan_network for item in (start, end, router)) or int(start) > int(end):
            raise PiHoleError("DHCP pool and router must be valid, ordered addresses inside the LAN network.")
        if lan_ip in {str(start), str(end)} or int(start) <= int(ipaddress.IPv4Address(lan_ip)) <= int(end):
            raise PiHoleError("The Pi-hole's reserved address cannot be inside the DHCP pool.")
        lines += ["    network_mode: host"]
    else:
        lines += [
            "    ports:",
            f"      - {yaml_quote(f'{lan_ip}:53:53/tcp')}",
            f"      - {yaml_quote(f'{lan_ip}:53:53/udp')}",
            f"      - {yaml_quote(f'{lan_ip}:80:80/tcp')}",
        ]
    web_port = f"{lan_ip}:80" if dhcp else "80"
    listening = "LOCAL" if dhcp else "ALL"
    lines += [
        "    environment:",
        f"      TZ: {yaml_quote(timezone_name)}",
        "      WEBPASSWORD_FILE: pihole_webpasswd",
        f"      FTLCONF_dns_listeningMode: {yaml_quote(listening)}",
        "      FTLCONF_dns_upstreams: '1.1.1.1;9.9.9.9'",
        f"      FTLCONF_webserver_port: {yaml_quote(web_port)}",
        f"      FTLCONF_webserver_acl: {yaml_quote('+' + network + ',+127.0.0.1')}",
        f"      FTLCONF_dhcp_active: {yaml_quote('true' if dhcp else 'false')}",
    ]
    if dhcp:
        lines += [
            f"      FTLCONF_dhcp_start: {yaml_quote(str(start))}",
            f"      FTLCONF_dhcp_end: {yaml_quote(str(end))}",
            f"      FTLCONF_dhcp_router: {yaml_quote(str(router))}",
        ]
    lines += [
        "    volumes:",
        "      - './etc-pihole:/etc/pihole'",
        "    restart: unless-stopped",
        "    secrets:",
        "      - pihole_webpasswd",
    ]
    if dhcp:
        lines += ["    cap_add:", "      - NET_ADMIN"]
    lines += [
        "secrets:",
        "  pihole_webpasswd:",
        "    file: ./admin-password",
        "",
    ]
    return "\n".join(lines)


def probe_port(host: str, port: int, kind: str) -> bool:
    """Return True only when a temporary bind succeeds; never change a service."""
    family = socket.AF_INET
    socket_type = socket.SOCK_STREAM if kind == "tcp" else socket.SOCK_DGRAM
    try:
        with socket.socket(family, socket_type) as sock:
            sock.bind((host, port))
            if kind == "tcp":
                sock.listen(1)
        return True
    except OSError:
        return False


def dns_query(server: str, hostname: str = "example.com", timeout: float = 3.0) -> tuple[bool, str]:
    """Perform a real UDP DNS request and validate its matching response header."""
    if not re.fullmatch(r"(?:[A-Za-z0-9-]+\.)+[A-Za-z0-9-]+", hostname):
        return False, "Use a simple DNS name such as example.com."
    identifier = random_secrets.randbelow(65536)
    question = b"".join(bytes((len(part),)) + part.encode("ascii") for part in hostname.split(".")) + b"\x00"
    packet = struct.pack("!HHHHHH", identifier, 0x0100, 1, 0, 0, 0) + question + struct.pack("!HH", 1, 1)
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(timeout)
            sock.sendto(packet, (server, 53))
            response, source = sock.recvfrom(4096)
        if source[0] != server or len(response) < 12:
            return False, "The DNS response came from an unexpected address or was too short."
        rid, flags, questions, answers, _, _ = struct.unpack("!HHHHHH", response[:12])
        if rid != identifier or not flags & 0x8000 or questions != 1:
            return False, "The DNS response did not match the request."
        rcode = flags & 0xF
        if rcode != 0:
            return False, f"Pi-hole answered with DNS error code {rcode}."
        return True, f"Valid DNS response from {server}: {answers} answer record(s)."
    except OSError as exc:
        return False, f"No valid DNS response from {server}: {exc}"


def default_lan_ip() -> str:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(("192.0.2.1", 53))  # Route lookup only; UDP sends no packet here.
            value = sock.getsockname()[0]
        ipaddress.IPv4Address(value)
        return value
    except OSError:
        return "192.168.1.20"


def network_for(ip: str) -> str:
    return str(ipaddress.IPv4Network(f"{ip}/24", strict=False))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_members(archive: tarfile.TarFile) -> list[tarfile.TarInfo]:
    members = archive.getmembers()
    for member in members:
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or not (member.isfile() or member.isdir()):
            raise PiHoleError(f"Unsafe or unsupported backup member: {member.name}")
    return members


def verify_backup(path: Path) -> dict:
    try:
        with tarfile.open(path, "r:gz") as archive:
            members = safe_members(archive)
            names = {member.name for member in members if member.isfile()}
            if "MANIFEST.json" not in names:
                raise PiHoleError("The backup has no integrity manifest.")
            manifest_file = archive.extractfile("MANIFEST.json")
            if manifest_file is None:
                raise PiHoleError("The backup integrity manifest cannot be read.")
            manifest = json.loads(manifest_file.read().decode("utf-8"))
            expected = manifest.get("files")
            if not isinstance(expected, dict) or not expected:
                raise PiHoleError("The backup integrity manifest is invalid.")
            required = {"compose.yaml", "deployment.json"}
            if not required.issubset(expected):
                raise PiHoleError("The backup is missing deployment configuration.")
            if names != set(expected) | {"MANIFEST.json"}:
                raise PiHoleError("The backup contents do not match its file manifest.")
            for name, wanted in expected.items():
                if not isinstance(wanted, str) or not re.fullmatch(r"[0-9a-f]{64}", wanted):
                    raise PiHoleError("The backup contains an invalid hash.")
                extracted = archive.extractfile(name)
                if extracted is None or hashlib.sha256(extracted.read()).hexdigest() != wanted:
                    raise PiHoleError(f"Backup verification failed for {name}.")
            config = manifest["deployment"]
            if not isinstance(config, dict):
                raise PiHoleError("The backup deployment metadata is invalid.")
            valid_image(config["version"], config["digest"])
            if config["image"] != valid_image(config["version"], config["digest"]):
                raise PiHoleError("The backup image identity is inconsistent.")
            return manifest
    except (OSError, tarfile.TarError, json.JSONDecodeError, KeyError, UnicodeDecodeError) as exc:
        raise PiHoleError(f"Backup verification failed: {exc}") from exc


def ac_online(sys_root: Path = Path("/sys/class/power_supply")) -> bool:
    supplies = list(sys_root.glob("*/online"))
    readings = []
    for online in supplies:
        try:
            kind = online.with_name("type").read_text(encoding="utf-8").strip()
            if kind in {"Mains", "USB", "USB_C", "USB_PD"}:
                readings.append(online.read_text(encoding="utf-8").strip() == "1")
        except OSError:
            continue
    if not readings:
        raise PiHoleError("No AC power sensor was found; the while-plugged-in sleep guard cannot run safely.")
    return any(readings)


def router_guide(choice: str, lan_ip: str) -> str:
    common = (
        f"Pi-hole host: {lan_ip}. Reserve this exact address for this computer in the router's DHCP reservation/address reservation settings, or configure a static address outside the DHCP pool. Do both only according to the router maker's instructions.\n\n"
        "Devices use Pi-hole only after they receive it as DNS from the router (recommended), or after you set DNS on each device. Reconnect Wi-Fi or renew the DHCP lease after saving. Keep the router as the gateway; this changes DNS, not internet routing.\n"
    )
    guides = {
        "generic": common + (
            "\nCommon router pattern: open the router admin page → LAN/DHCP settings → DNS server → enter only the Pi-hole IPv4 address (or a second Pi-hole if you actually run one). Save, then reconnect devices. If the router accepts DNS only under WAN/Internet, read its manual: that can hide individual clients and can create a DNS loop if Pi-hole forwards back to the router.\n\n"
            "Router brands and firmware differ; these labels are not a promise about your model. Check IPv6 DNS/Router Advertisement settings too, because devices may otherwise bypass an IPv4-only change. Official overview: https://docs.pi-hole.net/main/post-install/"
        ),
        "asus": common + (
            "\nASUS pattern: use LAN/DHCP DNS so clients query Pi-hole directly and remain individually visible. Pi-hole's official ASUS note recommends LAN rather than WAN DNS. Do not combine WAN-to-Pi-hole forwarding with conditional forwarding back to the router; that can loop. Model firmware varies; ASUS's linked FAQ is the model-specific reference. Source: https://docs.pi-hole.net/routers/asus/"
        ),
        "tplink": common + (
            "\nTP-Link/Deco pattern: follow TP-Link's official router-or-Deco FAQ linked by Pi-hole, then enter the reserved Pi-hole address in the DHCP DNS setting offered by your model. Archer and Deco interfaces differ; do not assume the same menu or app exists. Source: https://docs.pi-hole.net/routers/tp-link/"
        ),
        "fritzbox": common + (
            "\nFRITZ!Box pattern: enable Advanced view, then Home Network → Network → Network Settings → IP Addresses → IPv4 Configuration/Home Network, and set Local DNS server to Pi-hole. Reconnect clients to renew leases. For guest Wi-Fi, Pi-hole may need to be the router's upstream instead; then clients appear as the router. Avoid router↔Pi-hole forwarding loops. Source: https://docs.pi-hole.net/routers/fritzbox/"
        ),
        "opnsense": common + (
            "\nOPNsense pattern: Services → ISC DHCPv4 → the LAN interface → DNS servers; enter Pi-hole. Also review Interfaces and Services → Router Advertisement for IPv6 DNS. Reconnect clients. Your OPNsense version and DHCP backend may use different labels. Source: https://docs.pi-hole.net/routers/opnsense/"
        ),
        "per-device": common + (
            "\nIf the router cannot hand out custom DNS, set the Pi-hole IPv4 address manually in each device's Wi-Fi/network DNS settings. This affects only that device and must be repeated for other networks if the device uses automatic DNS elsewhere. Keep an automatic-DNS note for recovery. Do not set the Pi-hole host's own DNS to Pi-hole unless you accept that a Pi-hole failure can break host DNS and online repair."
        ),
    }
    if choice not in guides:
        raise PiHoleError("Unknown router guidance choice.")
    return guides[choice]


def device_playbook(choice: str, lan_ip: str) -> str:
    """Guided verification, not a claim that every device honors DHCP DNS."""
    valid_network(lan_ip, network_for(lan_ip))
    common = (
        f"Pi-hole address to test: {lan_ip}\n\n"
        "Before: confirm Pi-hole's own real DNS test passes and reserve its address. During: keep this device on the same LAN, reconnect Wi-Fi after the DNS change, then watch Pi-hole > Query Log while opening a few apps and websites. "
        "After: confirm this client's queries appear, compare behavior with automatic DNS restored, and keep the recovery steps. A query-log entry proves DNS visibility, not removal of every ad.\n\n"
        "Limits: apps can use hard-coded DNS, DNS over TLS/HTTPS or a VPN and bypass router/client DNS. Ads and wanted content delivered from the same domain often cannot be separated by DNS. Menu names vary by model and software version; never promise all ads will disappear.\n"
    )
    guides = {
        "samsung": (
            "Samsung TV guided client test\n"
            "1. Recommended: leave the TV on automatic network settings and give Pi-hole as DNS through the router's LAN/DHCP settings. Reconnect the TV or power-cycle it normally, then renew its lease.\n"
            "2. If testing only this TV, open Settings > General > Network > Network Status > IP Settings (labels vary). Choose manual DNS and enter only " + lan_ip + "; record the prior automatic/DNS values first. Do not change the gateway to Pi-hole.\n"
            "3. Reconnect, open several apps, and match the TV's client address in Query Log. Restore automatic DNS if apps, updates or streaming break.\n\n"
        ),
        "chromecast": (
            "Chromecast / Google TV guided client test\n"
            "1. Recommended: use router LAN/DHCP DNS rather than assuming a manual-DNS menu exists. Save, reconnect the Chromecast, and reboot it from its system menu so the lease and cached connections are refreshed.\n"
            "2. If your exact Google TV model offers per-network manual DNS, record the current settings, enter " + lan_ip + " only for the home Wi-Fi network, and keep the normal router as gateway. Some models require static IP settings; follow the maker's exact UI rather than guessing.\n"
            "3. Cast and open several apps while checking Query Log for this client. Hard-coded Google DNS, encrypted DNS, VPNs and IPv6 can bypass the test; restore automatic DNS if casting or apps break.\n\n"
        ),
    }
    if choice not in guides:
        raise PiHoleError("Unknown device test playbook.")
    return guides[choice] + common


def router_blocking_guide(lan_ip: str) -> str:
    """A vendor-neutral optional rule plan; the app never applies router rules."""
    valid_network(lan_ip, network_for(lan_ip))
    return (
        "OPTIONAL ADVANCED ROUTER DNS BLOCKING — BREAKAGE WARNING\n\n"
        "Only implement this after the router and one client pass ordinary DHCP DNS tests. Blocking or redirecting DNS can break Chromecast, Samsung TV, VPNs, work/school apps, updates, captive portals and recovery. It does not block DNS-over-HTTPS, all VPNs, same-domain ads or every advertisement. Keep a documented way to disable the rules immediately.\n\n"
        f"Vendor-neutral firewall rule plan for your exact router manual (this app changes nothing):\n"
        f"1. ALLOW LAN clients -> {lan_ip}, destination 53/TCP and 53/UDP.\n"
        f"2. ALLOW {lan_ip} -> your chosen upstream DNS servers on 53/TCP+UDP (and only any other DNS service you intentionally use).\n"
        "3. AFTER those allows, BLOCK other LAN clients -> any other destination on 53/TCP+UDP. Optionally block 853/TCP (DNS-over-TLS) only if you accept the extra breakage risk.\n"
        "4. Do not add a NAT redirect until you understand the router's hairpin/IPv6 behavior; redirects can create loops and hide the real client. Review IPv6 separately or bypass remains possible.\n"
        "5. Save only in the router UI, then test one Samsung TV or Chromecast and ordinary devices. Remove the rules immediately if anything breaks.\n\n"
        "There is no universal router rule syntax and no guarantee of complete DNS control or ad blocking."
    )


LIMITATIONS = (
    "Pi-hole filters DNS requests; it cannot remove every advertisement. Ads served from the same domain as wanted content (including many video/social-media ads) cannot be separated safely by DNS alone.\n\n"
    "Some Chromecast/Google TV and Samsung devices/apps may use hard-coded DNS or encrypted DNS and ignore router DNS. This app does not block or hijack their traffic. Router firewall/redirect rules are advanced, model-specific, can break devices, and are not changed here.\n\n"
    "The Pi-hole computer must be awake and connected whenever other devices need DNS. Sleep, shutdown, lid actions, Wi-Fi drops, Docker failure or a changed host IP can interrupt name resolution for the whole home. A laptop on battery is not a reliable always-on server.\n\n"
    "The web admin is bound to the selected private LAN address and restricted by a LAN ACL. No port forwarding, UPnP rule or internet exposure is configured. Your router and firewall still need their normal security settings.\n\n"
    "There is no universal router interface and no guarantee all ads disappear. Test several websites and devices, and know how to restore automatic DNS if you need to recover."
)


class Engine:
    def __init__(self, state: Path | None = None, runner: Runner = command, sys_root: Path | None = None):
        self.state = state or Path(os.environ.get("SL_PIHOLE_STATE", str(STATE_DEFAULT)))
        self.runner = runner
        self.sys_root = sys_root or Path(os.environ.get("SL_PIHOLE_SYSROOT", "/"))
        self.sleep = time.sleep

    @property
    def compose(self) -> Path:
        return self.state / "compose.yaml"

    @property
    def deployment(self) -> Path:
        return self.state / "deployment.json"

    def config(self) -> dict:
        try:
            config = json.loads(self.deployment.read_text(encoding="utf-8"))
            valid_network(config["lan_ip"], config["network"])
            valid_image(config["version"], config["digest"])
            if config["image"] != valid_image(config["version"], config["digest"]):
                raise PiHoleError("Saved image identity is inconsistent.")
            return config
        except (OSError, json.JSONDecodeError, KeyError) as exc:
            raise PiHoleError(f"No readable Secure Linux Pi-hole deployment was found: {exc}") from exc

    def save_config(self, config: dict, destination: Path | None = None) -> None:
        atomic_write(destination or self.deployment, json.dumps(config, indent=2, sort_keys=True) + "\n", 0o600)

    def compose_command(self, *args: str, timeout: int = 120) -> Reply:
        return self.runner(
            ["docker", "compose", "--project-directory", str(self.state), "-f", str(self.compose), *args],
            timeout=timeout,
        )

    def image_present(self, image: str) -> bool:
        reply = self.runner(["docker", "image", "inspect", image], timeout=30)
        if reply.returncode != 0:
            return False
        try:
            details = json.loads(reply.output)[0]
            repo_digests = details.get("RepoDigests") or []
            digest = image.split("@", 1)[1]
            return any(value.endswith("@" + digest) for value in repo_digests)
        except (json.JSONDecodeError, IndexError, KeyError, TypeError):
            # A local image loaded by digest can have an empty RepoDigests list.
            # Inspect by exact digest as a second identity check, never assume success.
            digest = image.split("@", 1)[1]
            retry = self.runner(["docker", "image", "inspect", "pihole/pihole@" + digest], timeout=30)
            return retry.returncode == 0

    def ensure_image(self, image: str) -> None:
        if self.image_present(image):
            return
        reply = self.runner(["docker", "pull", image], timeout=600)
        if reply.returncode != 0:
            raise PiHoleError(
                "The pinned Pi-hole image is not available locally and could not be downloaded. "
                "If this computer is offline, import the separately verified offline image first. "
                "No container was started.\n" + reply.output.strip()
            )
        if not self.image_present(image):
            raise PiHoleError("Docker returned from the pull but the exact pinned image identity is not present. No success is claimed.")

    def assess(self, lan_ip: str, network: str) -> dict:
        blockers: list[str] = []
        warnings: list[str] = []
        ports: dict[str, bool] = {}
        try:
            valid_network(lan_ip, network)
        except PiHoleError as exc:
            blockers.append(str(exc))
        for kind, port in (("udp", 53), ("tcp", 53), ("tcp", 80)):
            available = probe_port(lan_ip, port, kind)
            ports[f"{port}/{kind}"] = available
            if not available:
                blockers.append(f"{lan_ip}:{port}/{kind} is unavailable or already in use. Stop/reconfigure the conflicting DNS/web service or choose another suitable host; this app will not kill it.")
        memory_mb = 0
        try:
            text = (self.sys_root / "proc/meminfo").read_text(encoding="utf-8")
            match = re.search(r"^MemTotal:\s+(\d+) kB", text, re.MULTILINE)
            memory_mb = int(match.group(1)) // 1024 if match else 0
        except OSError:
            pass
        free_gb = int(shutil.disk_usage(self.sys_root or Path("/")).free / (1024 ** 3))
        if memory_mb and memory_mb < 1024:
            blockers.append(f"Only {memory_mb} MiB RAM was detected; at least 1 GiB is a practical minimum for this Docker-based option.")
        elif memory_mb and memory_mb < 2048:
            warnings.append(f"{memory_mb} MiB RAM is tight for a desktop plus Docker; a small always-on dedicated computer may be more reliable.")
        if free_gb < 2:
            blockers.append(f"Only {free_gb} GiB storage is free; at least 2 GiB is required for the image, logs and backups.")
        elif free_gb < 5:
            warnings.append(f"{free_gb} GiB free storage is limited; keep backups on another drive.")
        docker = shutil.which("docker")
        docker_detail = "Docker was not found."
        compose_ok = False
        if not docker:
            blockers.append("Rootful Docker with the Compose plugin is required. Enable Secure Linux's existing Docker option, then assess again; this app does not add docker-group membership or install rootless Docker.")
        else:
            info = self.runner(["docker", "info", "--format", "{{.ServerVersion}}"], timeout=12)
            compose = self.runner(["docker", "compose", "version", "--short"], timeout=12)
            compose_ok = compose.returncode == 0
            if info.returncode == 0:
                docker_detail = f"Rootful Docker server {info.output.strip()} is reachable."
            else:
                docker_detail = "Docker is installed, but this user cannot query the rootful daemon without administrator approval. Install will verify it again."
                warnings.append(docker_detail)
            if not compose_ok:
                blockers.append("The Docker Compose plugin is missing or unavailable; install/repair Secure Linux Docker first.")
        architecture = platform.machine().lower()
        if architecture not in {"x86_64", "amd64", "aarch64", "arm64", "i386", "i686", "armv7l", "riscv64"}:
            blockers.append(f"The pinned multi-architecture image does not list support for this architecture: {architecture or 'unknown'}.")
        battery = any(self.sys_root.glob("sys/class/power_supply/BAT*"))
        model = ""
        try:
            model = (self.sys_root / "sys/devices/virtual/dmi/id/product_name").read_text(encoding="utf-8").strip()
        except OSError:
            pass
        if battery:
            warnings.append("Laptop detected: sleep, lid closing and battery power can take the whole home's DNS offline. Keep the laptop plugged in; choose the visible while-plugged-in sleep guard only if you accept its power impact and test lid behavior.")
        if "zenbook" in model.lower():
            warnings.append(f"Zenbook reported ({model}): specifically test sleep, lid-close and power-source changes before relying on this host.")
        warnings.append("This assessment cannot prove the computer will stay awake or that the router reservation is configured; both need your explicit attention.")
        return {
            "ok": not blockers,
            "blockers": blockers,
            "warnings": warnings,
            "ports": ports,
            "memory_mb": memory_mb,
            "free_gb": free_gb,
            "docker": docker_detail,
            "compose": compose_ok,
            "architecture": architecture,
            "battery": battery,
            "model": model,
            "always_on_required": True,
        }

    def health(self, hostname: str = "example.com") -> dict:
        config = self.config()
        running = self.runner(["docker", "inspect", "--format", "{{.State.Running}}", "pihole"], timeout=20)
        container_ok = running.returncode == 0 and running.output.strip() == "true"
        dns_ok, dns_detail = (False, "Container is not running; DNS was not queried.")
        web_ok, web_detail = False, "Container is not running; web admin was not queried."
        if container_ok:
            dns_ok, dns_detail = dns_query(config["lan_ip"], hostname)
            try:
                connection = http.client.HTTPConnection(config["lan_ip"], 80, timeout=4)
                connection.request("GET", "/admin/", headers={"Host": "pi.hole"})
                response = connection.getresponse()
                response.read(2048)
                web_ok = response.status in {200, 301, 302, 303, 307, 308}
                web_detail = f"Web admin returned HTTP {response.status} on the LAN address."
                connection.close()
            except (OSError, http.client.HTTPException) as exc:
                web_detail = f"Web admin did not answer on the LAN address: {exc}"
        power_ok, power_detail = True, "While-plugged-in sleep guard was not selected."
        if config.get("prevent_sleep"):
            power = self.runner(["systemctl", "is-active", "--quiet", "secure-linux-pihole-awake.service"], timeout=15)
            power_ok = power.returncode == 0
            power_detail = "While-plugged-in sleep guard is active." if power_ok else "The selected sleep guard is not active; automatic sleep protection is not verified."
        ok = container_ok and dns_ok and web_ok and power_ok
        return {
            "ok": ok,
            "container": container_ok,
            "dns": dns_ok,
            "web": web_ok,
            "power": power_ok,
            "detail": "\n".join((dns_detail, web_detail, power_detail)),
            "url": f"http://{config['lan_ip']}/admin/",
        }

    def wait_health(self, attempts: int = 12, delay: float = 5.0) -> dict:
        last: dict = {"ok": False, "detail": "Health check did not run."}
        for _ in range(attempts):
            last = self.health()
            if last["ok"]:
                return last
            self.sleep(delay)
        raise PiHoleError("Pi-hole did not pass container, real DNS and LAN web health checks.\n" + last["detail"])

    def configure_sleep_guard(self, enabled: bool) -> None:
        unit_path = self.sys_root / "etc/systemd/system/secure-linux-pihole-awake.service"
        if not enabled:
            if unit_path.exists():
                require_ok(self.runner(["systemctl", "disable", "--now", "secure-linux-pihole-awake.service"], timeout=30), "Disabling the sleep guard")
                unit_path.unlink()
            return
        if self.sys_root != Path("/"):
            # Tests can inspect the exact unit without starting a host service.
            unit_path.parent.mkdir(parents=True, exist_ok=True)
            unit_path.write_text(self.sleep_unit(), encoding="utf-8")
            return
        # Fail before writing if the machine cannot distinguish AC from battery.
        ac_online(self.sys_root / "sys/class/power_supply")
        atomic_write(unit_path, self.sleep_unit(), 0o644)
        require_ok(self.runner(["systemctl", "daemon-reload"], timeout=30), "Reloading systemd")
        require_ok(self.runner(["systemctl", "enable", "--now", "secure-linux-pihole-awake.service"], timeout=30), "Enabling the reviewed sleep guard")
        active = self.runner(["systemctl", "is-active", "--quiet", "secure-linux-pihole-awake.service"], timeout=15)
        require_ok(active, "Verifying the sleep guard")

    @staticmethod
    def sleep_unit() -> str:
        return (
            "[Unit]\nDescription=Secure Linux Pi-hole AC-only sleep and lid guard\n"
            "After=network-online.target docker.service\nWants=network-online.target\n\n"
            "[Service]\nType=simple\nExecStart=/usr/local/bin/secure-linux-pihole --privileged power-guard\n"
            "Restart=on-failure\nRestartSec=10\nNoNewPrivileges=true\n\n"
            "[Install]\nWantedBy=multi-user.target\n"
        )

    def install(self, config: dict, password: str) -> None:
        validate_password(password)
        valid_network(config["lan_ip"], config["network"])
        valid_timezone(config["timezone"])
        valid_image(config["version"], config["digest"])
        if self.compose.exists():
            raise PiHoleError("A Secure Linux Pi-hole deployment already exists. Use Health, Backup or a reviewed update instead of replacing it.")
        existing = self.runner(["docker", "container", "inspect", "pihole"], timeout=20)
        if existing.returncode == 0:
            raise PiHoleError("A container named 'pihole' already exists but is not managed by this app. It will not be adopted, stopped or replaced; assess it manually first.")
        assessment = self.assess(config["lan_ip"], config["network"])
        if not assessment["ok"]:
            raise PiHoleError("Host suitability checks failed; nothing was started.\n- " + "\n- ".join(assessment["blockers"]))
        self.ensure_image(config["image"])
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.state, 0o700)
        (self.state / "etc-pihole").mkdir(mode=0o700, exist_ok=True)
        atomic_write(self.state / "admin-password", password + "\n", 0o600)
        self.save_config(config)
        atomic_write(self.compose, compose_text(config), 0o600)
        require_ok(self.compose_command("up", "-d", timeout=180), "Starting Pi-hole")
        health = self.wait_health()
        if config.get("prevent_sleep"):
            self.configure_sleep_guard(True)
            health = self.wait_health(attempts=1, delay=0)
        print("PIHOLE_INSTALL_VERIFIED")
        print(f"Admin URL (LAN only): {health['url']}")
        print("Admin password (shown once): " + password)
        print("Next: reserve the host address and follow the router tab. Devices do not use Pi-hole until their DNS changes.")

    def _staging_copy(self, staging: Path) -> dict:
        config = self.config()
        shutil.copy2(self.compose, staging / "compose.yaml")
        shutil.copy2(self.deployment, staging / "deployment.json")
        source = self.state / "etc-pihole"
        if not source.is_dir():
            raise PiHoleError("The persistent Pi-hole configuration directory is missing.")
        for item in source.rglob("*"):
            if item.is_symlink():
                raise PiHoleError(f"Refusing to back up a symbolic link in Pi-hole data: {item}")
        shutil.copytree(source, staging / "etc-pihole", dirs_exist_ok=True)
        files: dict[str, str] = {}
        for item in sorted(staging.rglob("*")):
            if item.is_file():
                files[item.relative_to(staging).as_posix()] = sha256_file(item)
        manifest = {
            "format": 1,
            "created_utc": datetime.now(timezone.utc).isoformat(),
            "image": config["image"],
            "files": files,
            "deployment": config,
            "password_included": False,
        }
        atomic_write(staging / "MANIFEST.json", json.dumps(manifest, indent=2, sort_keys=True) + "\n", 0o600)
        return manifest

    def backup(self, destination: Path | None = None) -> Path:
        self.config()
        destination = destination or self.state / "backups"
        destination.mkdir(parents=True, exist_ok=True)
        if not destination.is_dir():
            raise PiHoleError("The backup destination is not a directory.")
        name = "pihole-backup-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + random_secrets.token_hex(3)
        final = destination / (name + ".tar.gz")
        staging = Path(tempfile.mkdtemp(prefix=".backup-staging-", dir=self.state))
        temporary = destination / ("." + name + ".tmp")
        stopped = False
        try:
            require_ok(self.compose_command("stop", timeout=90), "Stopping Pi-hole for a consistent backup")
            stopped = True
            self._staging_copy(staging)
            with tarfile.open(temporary, "w:gz") as archive:
                for item in sorted(staging.rglob("*")):
                    archive.add(item, arcname=item.relative_to(staging).as_posix(), recursive=False)
            os.chmod(temporary, 0o600)
            verify_backup(temporary)
            os.replace(temporary, final)
            os.chmod(final, 0o600)
        finally:
            if stopped:
                restart = self.compose_command("up", "-d", timeout=120)
                if restart.returncode != 0:
                    raise PiHoleError("The backup operation ended but Pi-hole could not be restarted. DNS may be offline.\n" + restart.output)
        self.wait_health()
        verify_backup(final)
        print("PIHOLE_BACKUP_VERIFIED=" + str(final))
        print("The archive was hash-verified and Pi-hole passed health checks after restart. The admin password file is not included; restore on this host keeps the existing password.")
        return final

    def restore(self, archive_path: Path, pre_backup: bool = True) -> None:
        archive_path = archive_path.resolve()
        verify_backup(archive_path)
        self.config()
        if pre_backup:
            print("Creating a verified pre-restore backup first.")
            self.backup()
        self._restore_verified(archive_path)
        print("PIHOLE_RESTORE_VERIFIED")
        print("The restored deployment passed real DNS and LAN web checks. The existing admin password was retained.")

    def _restore_verified(self, archive_path: Path) -> None:
        manifest = verify_backup(archive_path)
        restored_config = manifest["deployment"]
        self.ensure_image(restored_config["image"])
        staging = Path(tempfile.mkdtemp(prefix=".restore-staging-", dir=self.state))
        previous = Path(tempfile.mkdtemp(prefix=".restore-previous-", dir=self.state))
        stopped = False
        try:
            with tarfile.open(archive_path, "r:gz") as archive:
                safe_members(archive)
                archive.extractall(staging)
            require_ok(self.compose_command("stop", timeout=90), "Stopping Pi-hole for restore")
            stopped = True
            for name in ("etc-pihole", "compose.yaml", "deployment.json"):
                current = self.state / name
                if current.exists():
                    os.replace(current, previous / name)
                os.replace(staging / name, current)
            os.chmod(self.compose, 0o600)
            os.chmod(self.deployment, 0o600)
            up = self.compose_command("up", "-d", timeout=180)
            if up.returncode != 0:
                raise PiHoleError("Restored container could not start.\n" + up.output)
            self.wait_health()
        except Exception as original:
            rollback_detail = "No rollback was possible; inspect the preserved files immediately."
            try:
                self.compose_command("stop", timeout=60)
                for name in ("etc-pihole", "compose.yaml", "deployment.json"):
                    current = self.state / name
                    if current.exists():
                        if current.is_dir():
                            shutil.rmtree(current)
                        else:
                            current.unlink()
                    if (previous / name).exists():
                        os.replace(previous / name, current)
                if self.compose.exists():
                    self.compose_command("up", "-d", timeout=120)
                    self.wait_health(attempts=4, delay=2)
                    rollback_detail = "The previous deployment was restored and passed health checks."
            except Exception as rollback:
                rollback_detail = f"Rollback also failed: {rollback}"
            raise PiHoleError(f"Restore failed: {original}\n{rollback_detail}") from original
        finally:
            shutil.rmtree(staging, ignore_errors=True)
            shutil.rmtree(previous, ignore_errors=True)

    def check_update(self) -> dict:
        current = self.config()
        try:
            request = Request(RELEASE_API, headers={"Accept": "application/vnd.github+json", "User-Agent": "Secure-Linux-Pi-hole/1"})
            with urlopen(request, timeout=20) as response:
                release = json.load(response)
            version = release["tag_name"]
            notes_url = release["html_url"]
            if not notes_url.startswith("https://github.com/pi-hole/docker-pi-hole/releases/tag/"):
                raise PiHoleError("The release API returned an unexpected notes address.")
            valid_image(version, PIHOLE_DIGEST)  # Validate version shape; digest below is tag-specific.
            with urlopen(Request(REGISTRY_TAG_API + version, headers={"User-Agent": "Secure-Linux-Pi-hole/1"}), timeout=20) as response:
                tag = json.load(response)
            digest = tag["digest"]
            image = valid_image(version, digest)
            if tag.get("name") != version:
                raise PiHoleError("Docker Hub returned a different tag name.")
        except (OSError, json.JSONDecodeError, KeyError, TypeError) as exc:
            raise PiHoleError(f"Could not verify the latest official release and registry digest: {exc}") from exc
        result = {
            "current_version": current["version"],
            "current_digest": current["digest"],
            "version": version,
            "digest": digest,
            "image": image,
            "notes": notes_url,
            "update_available": image != current["image"],
        }
        print("PIHOLE_UPDATE_JSON=" + json.dumps(result, sort_keys=True))
        print("Read the Docker and component release notes before updating. The update action creates a verified backup and attempts full rollback on health failure.")
        return result

    def update(self, version: str, digest: str) -> None:
        current = self.config()
        image = valid_image(version, digest)
        if image == current["image"]:
            raise PiHoleError("The requested image is already installed; no update was performed.")
        self.ensure_image(image)
        backup_path = self.backup()
        atomic_write(self.state / "compose.previous.yaml", self.compose.read_text(encoding="utf-8"), 0o600)
        atomic_write(self.state / "deployment.previous.json", self.deployment.read_text(encoding="utf-8"), 0o600)
        updated = dict(current, version=version, digest=digest, image=image)
        try:
            self.save_config(updated)
            atomic_write(self.compose, compose_text(updated), 0o600)
            require_ok(self.compose_command("up", "-d", timeout=180), "Starting the reviewed Pi-hole update")
            self.wait_health()
        except Exception as original:
            try:
                self._restore_verified(backup_path)
                rollback = "The prior image and configuration were restored and passed health checks."
            except Exception as exc:
                rollback = f"AUTOMATIC ROLLBACK FAILED: {exc}"
            raise PiHoleError(f"Update failed; no update success is claimed: {original}\n{rollback}") from original
        atomic_write(self.state / "rollback.json", json.dumps({"backup": str(backup_path), "from": current["image"], "to": image}) + "\n", 0o600)
        print("PIHOLE_UPDATE_VERIFIED=" + image)
        print("The reviewed image passed real DNS and LAN web checks. A verified pre-update backup and explicit Rollback action remain available.")

    def rollback(self) -> None:
        marker = self.state / "rollback.json"
        try:
            data = json.loads(marker.read_text(encoding="utf-8"))
            backup_path = Path(data["backup"])
        except (OSError, json.JSONDecodeError, KeyError) as exc:
            raise PiHoleError("No reviewed pre-update rollback backup is available.") from exc
        self._restore_verified(backup_path)
        marker.unlink(missing_ok=True)
        print("PIHOLE_ROLLBACK_VERIFIED")
        print("The pre-update image and configuration passed health checks.")

    def repair(self) -> None:
        config = self.config()
        self.ensure_image(config["image"])
        require_ok(self.compose_command("up", "-d", timeout=180), "Repairing the Pi-hole container")
        health = self.wait_health()
        print("PIHOLE_REPAIR_VERIFIED")
        print(health["detail"])

    def set_dhcp(self, enabled: bool, *, interface: str = "", start: str = "", end: str = "", router: str = "") -> None:
        current = self.config()
        if enabled:
            if not re.fullmatch(r"[A-Za-z0-9_.-]{1,15}", interface):
                raise PiHoleError("Use a real Linux interface name such as wlp0s20f3; no shell characters are accepted.")
            interfaces = {item.name for item in (self.sys_root / "sys/class/net").iterdir()} if (self.sys_root / "sys/class/net").is_dir() else set()
            if interface not in interfaces:
                raise PiHoleError(f"Interface '{interface}' was not found on this host.")
            current.update(dhcp=True, interface=interface, dhcp_start=start, dhcp_end=end, dhcp_router=router)
        else:
            current.update(dhcp=False, interface="", dhcp_start="", dhcp_end="", dhcp_router="")
        # Validate before interrupting a healthy deployment.
        compose_text(current)
        backup_path = self.backup()
        try:
            self.save_config(current)
            atomic_write(self.compose, compose_text(current), 0o600)
            require_ok(self.compose_command("up", "-d", timeout=180), "Applying the reviewed DHCP mode")
            self.wait_health()
        except Exception as original:
            try:
                self._restore_verified(backup_path)
                detail = "The previous DNS-only deployment was restored and verified."
            except Exception as rollback:
                detail = f"Rollback failed: {rollback}"
            raise PiHoleError(f"DHCP change failed: {original}\n{detail}") from original
        print("PIHOLE_DHCP_ENABLED_VERIFIED" if enabled else "PIHOLE_DHCP_DISABLED_VERIFIED")
        print("Only one DHCP server should be active on this LAN. Verify the router setting and renew one test device's lease before changing other devices.")

    def export_image(self, destination: Path) -> Path:
        config = self.config() if self.deployment.exists() else {"image": PIHOLE_IMAGE, "version": PIHOLE_VERSION, "digest": PIHOLE_DIGEST}
        image = config["image"]
        self.ensure_image(image)
        destination.mkdir(parents=True, exist_ok=True)
        if not destination.is_dir():
            raise PiHoleError("The image export destination is not a directory.")
        final = destination / f"pihole-{config['version']}-{config['digest'].split(':', 1)[1][:12]}.tar"
        temporary = destination / ("." + final.name + ".tmp")
        try:
            require_ok(self.runner(["docker", "save", "--output", str(temporary), image], timeout=600), "Exporting the pinned Docker image")
            if not temporary.is_file() or temporary.stat().st_size < 1024:
                raise PiHoleError("Docker did not produce a plausible image archive.")
            with tarfile.open(temporary, "r:") as archive:
                if "manifest.json" not in archive.getnames():
                    raise PiHoleError("The Docker image archive has no manifest.json.")
            digest = sha256_file(temporary)
            os.replace(temporary, final)
            metadata = {
                "format": 1,
                "image": image,
                "version": config["version"],
                "registry_digest": config["digest"],
                "archive": final.name,
                "archive_sha256": digest,
                "archive_bytes": final.stat().st_size,
                "load_command": f"docker load --input {final.name}",
                "note": "Handoff only; the active offline-bundle was not modified. Verify archive_sha256 before docker load.",
            }
            atomic_write(final.with_suffix(".json"), json.dumps(metadata, indent=2, sort_keys=True) + "\n", 0o600)
            atomic_write(final.with_suffix(".sha256"), f"{digest}  {final.name}\n", 0o600)
        finally:
            temporary.unlink(missing_ok=True)
        print("PIHOLE_IMAGE_EXPORT_VERIFIED=" + str(final))
        print("SHA256=" + digest)
        return final


def power_guard(engine: Engine, poll_seconds: int = 20) -> int:
    """Hold an explicit sleep/lid inhibitor only while an AC sensor reports online."""
    process: subprocess.Popen | None = None
    try:
        while True:
            try:
                plugged = ac_online(engine.sys_root / "sys/class/power_supply")
            except PiHoleError as exc:
                print(str(exc), file=sys.stderr, flush=True)
                return 1
            if plugged and (process is None or process.poll() is not None):
                process = subprocess.Popen([
                    "systemd-inhibit",
                    "--what=sleep:handle-lid-switch",
                    "--mode=block",
                    "--why=Pi-hole DNS host is plugged in; reviewed AC-only guard",
                    "/bin/sleep", "infinity",
                ])
                print("AC online: sleep and logind lid actions are inhibited. Display/firmware behavior can still vary.", flush=True)
            elif not plugged and process is not None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                process = None
                print("AC removed: sleep inhibitor released. Pi-hole host may sleep; home DNS can stop.", flush=True)
            time.sleep(poll_seconds)
    except KeyboardInterrupt:
        return 0
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
