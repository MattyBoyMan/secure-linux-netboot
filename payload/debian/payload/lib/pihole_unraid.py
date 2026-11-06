#!/usr/bin/env python3
"""Reviewed Pi-hole deployment on an existing unRAID server over SSH.

unRAID is never installed here. Remote commands use BatchMode SSH and a root
login, never a password embedded in argv. The admin secret travels only over
standard input. Backups exclude that secret and are hash-checked remotely.
"""
from __future__ import annotations

from datetime import datetime, timezone
import http.client
import ipaddress
import json
import re
import secrets
import shlex
from pathlib import PurePosixPath

from pihole_core import (
    PIHOLE_IMAGE,
    PiHoleError,
    Reply,
    command,
    compose_text,
    dns_query,
    require_ok,
    valid_image,
    valid_network,
    validate_password,
    valid_timezone,
)

TARGET_RE = re.compile(r"^(?:[A-Za-z_][A-Za-z0-9._-]{0,63}@)?[A-Za-z0-9][A-Za-z0-9.-]{0,253}$")
REMOTE_STATE = PurePosixPath("/mnt/user/appdata/secure-linux/pihole")
REMOTE_BACKUPS = PurePosixPath("/mnt/user/appdata/secure-linux/pihole-backups")
BACKUP_RE = re.compile(r"^/mnt/user/appdata/secure-linux/pihole-backups/pihole-unraid-[0-9TZ-]+-[0-9a-f]{8}\.tar\.gz$")


def valid_target(value: str) -> bool:
    return bool(TARGET_RE.fullmatch(value)) and not any(part in value for part in ("..", ".-", "-.", "@-", "@."))


def _q(value: object) -> str:
    return shlex.quote(str(value))


def _port_busy(text: str, port: int) -> bool:
    return any(re.search(r"(?:^|\s)\S+:" + str(port) + r"\s", line) for line in text.splitlines())


class UnraidEngine:
    def __init__(self, target: str, runner=command):
        if not valid_target(target):
            raise PiHoleError("Use a simple unRAID SSH login such as root@tower.local; options and shell characters are not accepted.")
        self.target = target
        self.runner = runner
        self.state = REMOTE_STATE
        self.backups = REMOTE_BACKUPS

    def remote(self, script: str, *, input_text: str | None = None, timeout: int = 120) -> Reply:
        return self.runner(
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", self.target, script],
            input_text=input_text,
            timeout=timeout,
        )

    def assess(self, lan_ip: str, network: str, *, reserved: bool, always_on: bool) -> dict:
        blockers: list[str] = []
        warnings: list[str] = []
        try:
            valid_network(lan_ip, network)
        except PiHoleError as exc:
            blockers.append(str(exc))
        identity = self.remote("id -u", timeout=15)
        ssh_ok = identity.returncode == 0
        root_ok = ssh_ok and identity.output.strip() == "0"
        if not ssh_ok:
            blockers.append("SSH key login failed. Set up root SSH keys on the existing unRAID server; no password prompt is automated.")
        elif not root_ok:
            blockers.append("The unRAID SSH login must be root because this option manages the server's rootful Docker service.")
        info = self.remote("docker info --format '{{.ServerVersion}}'", timeout=20) if root_ok else Reply(1, "SSH not ready")
        compose = self.remote("docker compose version --short", timeout=20) if root_ok else Reply(1, "SSH not ready")
        docker_ok = info.returncode == 0 and compose.returncode == 0
        if not docker_ok:
            blockers.append("Docker and its Compose plugin must be reachable on unRAID. Enable/repair Docker there; this app does not convert unRAID to rootless Docker.")
        ports = {"53/udp": False, "53/tcp": False, "80/tcp": False}
        if root_ok:
            tcp = self.remote("ss -H -lnt", timeout=15)
            udp = self.remote("ss -H -lnu", timeout=15)
            if tcp.returncode or udp.returncode:
                blockers.append("Could not inspect unRAID listening ports with ss; installation will not guess that 53 or 80 is free.")
            else:
                ports = {
                    "53/udp": not _port_busy(udp.output, 53),
                    "53/tcp": not _port_busy(tcp.output, 53),
                    "80/tcp": not _port_busy(tcp.output, 80),
                }
                for name, free in ports.items():
                    if not free:
                        blockers.append(f"unRAID port {name} is already listening. Reconfigure the conflicting service; nothing is killed automatically.")
        memory_mb = 0
        if root_ok:
            memory = self.remote("cat /proc/meminfo", timeout=15)
            match = re.search(r"^MemTotal:\s+(\d+) kB", memory.output, re.MULTILINE)
            memory_mb = int(match.group(1)) // 1024 if match else 0
            if memory.returncode or not memory_mb:
                blockers.append("Could not measure unRAID memory.")
            elif memory_mb < 1024:
                blockers.append(f"Only {memory_mb} MiB RAM is available; at least 1 GiB is required for this option.")
            elif memory_mb < 2048:
                warnings.append("RAM is tight for unRAID plus Docker and other apps; measure actual use before relying on this host.")
        free_gb = 0
        if root_ok:
            disk = self.remote("df -Pk /mnt/user", timeout=15)
            lines = disk.output.splitlines()
            if disk.returncode == 0 and len(lines) >= 2:
                try:
                    free_gb = int(lines[-1].split()[3]) // (1024 * 1024)
                except (ValueError, IndexError):
                    free_gb = 0
            if free_gb < 2:
                blockers.append("Less than 2 GiB is free on /mnt/user, or storage could not be measured.")
            elif free_gb < 5:
                warnings.append("Free storage is limited; keep verified backups on another device as well.")
        existing = self.remote("docker container inspect pihole", timeout=20) if root_ok else Reply(1, "")
        existing_container = existing.returncode == 0
        managed = False
        if root_ok:
            managed = self.remote("test -f " + _q(self.state / "deployment.json"), timeout=15).returncode == 0
        if existing_container:
            blockers.append("A container named pihole already exists. Back it up with the explicit backup action and resolve the conflict manually; it is never adopted, stopped or replaced by Install.")
        if not reserved:
            blockers.append("Reserve the exact Pi-hole IP in the router (or use a supported static-IP setup) before installing.")
        if not always_on:
            blockers.append("Confirm that the unRAID server will remain awake and connected; sleeping or shutting it down interrupts home DNS.")
        warnings.append("Resource and port checks are a point-in-time assessment, not a promise of zero load, zero conflicts or uninterrupted DNS.")
        return {
            "ok": not blockers,
            "blockers": blockers,
            "warnings": warnings,
            "ssh": ssh_ok and root_ok,
            "docker": info.output.strip() if info.returncode == 0 else "Docker unavailable",
            "compose": compose.returncode == 0,
            "ports": ports,
            "memory_mb": memory_mb,
            "free_gb": free_gb,
            "existing_container": existing_container,
            "managed": managed,
            "reserved": reserved,
            "always_on": always_on,
            "target": self.target,
            "lan_ip": lan_ip,
            "network": network,
        }

    def ensure_image(self, image: str) -> None:
        inspect = "docker image inspect --format '{{json .RepoDigests}}' " + _q(image)
        present = self.remote(inspect, timeout=40)
        try:
            digests = json.loads(present.output) if present.returncode == 0 else []
        except json.JSONDecodeError:
            digests = []
        wanted = image.split("@", 1)[1]
        if present.returncode == 0 and any(str(item).endswith("@" + wanted) for item in digests):
            return
        require_ok(self.remote("docker pull " + _q(image), timeout=600), "Pulling the pinned official Pi-hole image on unRAID")
        verify = self.remote(inspect, timeout=40)
        try:
            digests = json.loads(verify.output) if verify.returncode == 0 else []
        except json.JSONDecodeError:
            digests = []
        if not any(str(item).endswith("@" + wanted) for item in digests):
            raise PiHoleError("The pulled image did not verify against the exact registry digest; no success is claimed.")

    def _write(self, name: str, content: str, mode: int = 600) -> None:
        path = self.state / name
        require_ok(self.remote("umask 077; cat > " + _q(path) + " && chmod " + str(mode) + " " + _q(path), input_text=content), "Writing " + name + " on unRAID")

    def health(self, lan_ip: str, hostname: str = "example.com") -> dict:
        running = self.remote("docker inspect --format '{{.State.Running}}' pihole", timeout=20)
        container_ok = running.returncode == 0 and running.output.strip() == "true"
        dns_ok, dns_detail = (False, "Remote container is not running; DNS was not queried.")
        web_ok, web_detail = False, "Remote container is not running; LAN web admin was not queried."
        if container_ok:
            dns_ok, dns_detail = dns_query(lan_ip, hostname)
            try:
                connection = http.client.HTTPConnection(lan_ip, 80, timeout=4)
                connection.request("GET", "/admin/", headers={"Host": "pi.hole"})
                response = connection.getresponse()
                response.read(2048)
                web_ok = response.status in {200, 301, 302, 303, 307, 308}
                web_detail = f"unRAID LAN web admin returned HTTP {response.status}."
                connection.close()
            except (OSError, http.client.HTTPException) as exc:
                web_detail = f"unRAID LAN web admin did not answer: {exc}"
        return {"ok": container_ok and dns_ok and web_ok, "container": container_ok, "dns": dns_ok, "web": web_ok,
                "detail": "\n".join((dns_detail, web_detail)), "url": f"http://{lan_ip}/admin/"}

    def wait_health(self, lan_ip: str, attempts: int = 12) -> dict:
        last: dict = {"ok": False, "detail": "Health did not run."}
        for _ in range(attempts):
            last = self.health(lan_ip)
            if last["ok"]:
                return last
        raise PiHoleError("unRAID Pi-hole did not pass container, real LAN DNS and LAN web checks.\n" + last["detail"])

    def install(self, config: dict, password: str, confirmation: str) -> None:
        if confirmation != "Confirm":
            raise PiHoleError("Type exactly Confirm in the graphical review. Nothing was sent to unRAID.")
        validate_password(password)
        lan_ip, network = valid_network(config["lan_ip"], config["network"])
        valid_timezone(config["timezone"])
        valid_image(config["version"], config["digest"])
        if config["image"] != PIHOLE_IMAGE:
            raise PiHoleError("The unRAID installer accepts only the reviewed pinned official image.")
        report = self.assess(lan_ip, network, reserved=True, always_on=True)
        if not report["ok"]:
            raise PiHoleError("unRAID preflight failed; no files or containers were changed.\n- " + "\n- ".join(report["blockers"]))
        self.ensure_image(config["image"])
        require_ok(self.remote("install -d -m 700 " + _q(self.state) + " " + _q(self.state / "etc-pihole") + " " + _q(self.backups)), "Creating private unRAID Pi-hole folders")
        self._write("compose.yaml", compose_text(config))
        self._write("deployment.json", json.dumps(config, indent=2, sort_keys=True) + "\n")
        self._write("admin-password", password + "\n")
        up = self.remote("cd " + _q(self.state) + " && docker compose --project-directory " + _q(self.state) + " -f compose.yaml up -d", timeout=180)
        if up.returncode:
            self.remote("cd " + _q(self.state) + " && docker compose -f compose.yaml down", timeout=120)
            raise PiHoleError("unRAID Pi-hole could not start. The new container was removed; pre-existing containers were untouched.\n" + up.output)
        try:
            health = self.wait_health(lan_ip)
            archive = self.backup(confirmation="Confirm")
            health = self.wait_health(lan_ip, attempts=1)
        except Exception as original:
            self.remote("cd " + _q(self.state) + " && docker compose -f compose.yaml down", timeout=120)
            raise PiHoleError(f"unRAID installation did not verify; the new container was removed. No existing container was replaced. {original}") from original
        print("PIHOLE_UNRAID_INSTALL_VERIFIED")
        print("Admin URL (LAN only): " + health["url"])
        print("Admin password (shown once): " + password)
        print("Verified rollback backup: " + str(archive))
        print("Reserve the address and test router/client DNS on real devices. Installation does not guarantee all ads are blocked or zero performance impact.")

    def _archive_from_staging(self, staging: PurePosixPath, final: PurePosixPath) -> None:
        commands = (
            "cd " + _q(staging) + " && find . -type f ! -name MANIFEST.sha256 -print0 | sort -z | xargs -0 sha256sum > MANIFEST.sha256 && "
            "tar -czf " + _q(final) + " -C " + _q(staging) + " . && "
            "gzip -t " + _q(final) + " && tar -tzf " + _q(final) + " >/dev/null && "
            "cd " + _q(staging) + " && sha256sum -c MANIFEST.sha256 >/dev/null && "
            "sha256sum " + _q(final) + " > " + _q(PurePosixPath(str(final) + ".sha256")) + " && "
            "printf '%s\\n' " + _q(final) + " > " + _q(self.backups / "latest-backup")
        )
        require_ok(self.remote(commands, timeout=300), "Creating and verifying the remote Pi-hole backup")
        self.remote("rm -rf -- " + _q(staging), timeout=60)
        print("PIHOLE_UNRAID_BACKUP_VERIFIED=" + str(final))

    def backup(self, confirmation: str) -> PurePosixPath:
        if confirmation != "Confirm":
            raise PiHoleError("Backup needs exact Confirm because DNS is stopped briefly. Nothing was changed.")
        existing = self.remote("docker container inspect pihole", timeout=20)
        if existing.returncode:
            raise PiHoleError("No existing pihole container was found to back up.")
        managed = self.remote("test -f " + _q(self.state / "deployment.json") + " -a -f " + _q(self.state / "compose.yaml"), timeout=15).returncode == 0
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + secrets.token_hex(4)
        staging = PurePosixPath("/tmp/secure-linux-pihole-" + stamp)
        final = self.backups / ("pihole-unraid-" + stamp + ".tar.gz")
        require_ok(self.remote("install -d -m 700 " + _q(staging) + " " + _q(self.backups)), "Preparing the unRAID backup")
        stopped = self.remote("docker stop pihole", timeout=90)
        require_ok(stopped, "Stopping Pi-hole for a consistent backup")
        try:
            if managed:
                require_ok(self.remote(
                    "cp -a " + _q(self.state / "compose.yaml") + " " + _q(self.state / "deployment.json") + " " + _q(self.state / "etc-pihole") + " " + _q(staging) + "/",
                    timeout=180), "Copying the managed Pi-hole configuration")
            else:
                require_ok(self.remote("docker inspect pihole > " + _q(staging / "docker-inspect.json")), "Saving unmanaged container metadata")
                mount = self.remote("docker inspect --format '{{range .Mounts}}{{if eq .Destination \"/etc/pihole\"}}{{.Source}}{{end}}{{end}}' pihole", timeout=20)
                source = mount.output.strip()
                if mount.returncode == 0 and source.startswith("/") and "\n" not in source and ".." not in PurePosixPath(source).parts:
                    require_ok(self.remote("cp -a " + _q(source) + " " + _q(staging / "etc-pihole"), timeout=180), "Copying the existing Pi-hole data mount")
                else:
                    require_ok(self.remote("docker export --output " + _q(staging / "container-rootfs.tar") + " pihole", timeout=300), "Exporting the unmanaged container filesystem")
                require_ok(self.remote("printf '%s\\n' 'Unmanaged container backup: inspect metadata plus /etc/pihole when mounted, otherwise container-rootfs.tar. No admin password is intentionally included.' > " + _q(staging / "METADATA.txt")), "Writing unmanaged backup metadata")
            self._archive_from_staging(staging, final)
        finally:
            restarted = self.remote("docker start pihole", timeout=120)
            if restarted.returncode:
                raise PiHoleError("Backup ended but the existing Pi-hole could not be restarted; DNS may be offline.\n" + restarted.output)
        if managed:
            config = json.loads(self.remote("cat " + _q(self.state / "deployment.json"), timeout=20).output)
            self.wait_health(config["lan_ip"], attempts=1)
        return final

    def rollback(self, archive: str, confirmation: str, lan_ip: str) -> None:
        if confirmation != "Confirm":
            raise PiHoleError("Rollback needs exact Confirm. Nothing was changed.")
        if not BACKUP_RE.fullmatch(archive):
            raise PiHoleError("Choose a backup inside the app's verified unRAID backup folder.")
        final = PurePosixPath(archive)
        staging = PurePosixPath("/tmp/secure-linux-pihole-rollback-" + secrets.token_hex(4))
        previous = PurePosixPath(str(staging) + "-previous")
        require_ok(self.remote(
            "install -d -m 700 " + _q(staging) + " " + _q(previous) + " && "
            "gzip -t " + _q(final) + " && "
            "! tar -tzf " + _q(final) + " | grep -Eq '(^/|(^|/)\\.\\.(/|$))' && "
            "! tar -tvzf " + _q(final) + " | grep -Ev '^[-d]' && "
            "tar -xzf " + _q(final) + " -C " + _q(staging) + " && "
            "cd " + _q(staging) + " && sha256sum -c MANIFEST.sha256 >/dev/null && "
            "test -f compose.yaml -a -f deployment.json -a -d etc-pihole && "
            "cp -a " + _q(self.state) + "/. " + _q(previous) + "/",
            timeout=300), "Verifying the rollback archive and preserving the current deployment")
        restore = (
            "cd " + _q(self.state) + " && docker compose -f compose.yaml down; "
            "rm -rf " + _q(self.state) + " && install -d -m 700 " + _q(self.state) + " && "
            "cp -a " + _q(staging) + "/compose.yaml " + _q(staging) + "/deployment.json " + _q(staging) + "/etc-pihole " + _q(self.state) + "/ && "
            "cp -a " + _q(previous) + "/admin-password " + _q(self.state) + "/admin-password && chmod 600 " + _q(self.state) + "/admin-password && "
            "cd " + _q(self.state) + " && docker compose --project-directory " + _q(self.state) + " -f compose.yaml up -d"
        )
        require_ok(self.remote(restore, timeout=240), "Restoring the verified unRAID Pi-hole backup")
        try:
            self.wait_health(lan_ip, attempts=1)
        except Exception as original:
            self.remote(
                "cd " + _q(self.state) + " && docker compose -f compose.yaml down; rm -rf " + _q(self.state) + " && cp -a " + _q(previous) + " " + _q(self.state) + " && cd " + _q(self.state) + " && docker compose -f compose.yaml up -d",
                timeout=240)
            try:
                self.wait_health(lan_ip, attempts=1)
                detail = "The previous deployment was restored and passed health checks."
            except Exception as rollback:
                detail = "Automatic restoration of the previous deployment also failed: " + str(rollback)
            raise PiHoleError(f"Rollback target failed health: {original}\n{detail}") from original
        finally:
            self.remote("rm -rf -- " + _q(staging) + " " + _q(previous), timeout=60)
        print("PIHOLE_UNRAID_ROLLBACK_VERIFIED")
        print("The verified backup passed remote container, real LAN DNS and LAN web health checks.")
