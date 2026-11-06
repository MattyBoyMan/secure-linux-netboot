#!/usr/bin/env python3
"""Headless command adapter and lazy native entry for Home & Server Studio.

Remote work is never simulated. SSH, web, GraphQL, Docker and Home Assistant
commands run only through the established helpers after graphical review.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit

from gui_tools_common import CommandSpec

TARGET_RE = re.compile(r"^(?:[A-Za-z_][A-Za-z0-9._-]{0,63}@)?[A-Za-z0-9][A-Za-z0-9.-]{0,253}$")
CONTAINER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
SERVER_ACTIONS = {
    "Install Home Assistant Container": "ha-install",
    "Set up Home Assistant backups": "ha-backup",
    "Update Home Assistant safely": "ha-update",
    "Set up Mosquitto": "ha-mosquitto",
    "Add Home Assistant to Caddy": "ha-caddy",
    "Restrict the firewall to LAN": "ha-firewall",
    "Harden the Home Assistant host": "ha-harden",
    "Set up the fleet server": "setup-fleet",
    "Install Caddy": "caddy",
    "Set up server backups": "backup",
    "Back up Immich": "immich-backup",
}


def valid_url(value: str) -> bool:
    try:
        parsed = urlsplit(value)
        hostname = parsed.hostname or ""
        return (parsed.scheme in {"http", "https"}
                and bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]{0,253}", hostname))
                and parsed.username is None and parsed.password is None
                and parsed.path in {"", "/"} and not parsed.query and not parsed.fragment
                and (parsed.port is None or 1 <= parsed.port <= 65535)
                and not any(part in value for part in ("..", ".-", "-.", " ")))
    except ValueError:
        return False


def valid_target(value: str) -> bool:
    return bool(TARGET_RE.fullmatch(value)) and not any(part in value for part in ("..", ".-", "-.", "@-", "@."))


class HomeBackend:
    def __init__(self, root: Path | None = None):
        default_root = Path(__file__).resolve().parent.parent
        self.root = root or Path(os.environ.get("SL_ROOT", str(default_root)))
        self.bin_dir = self.root / "bin" if (self.root / "bin" / "secure-linux-home-server").is_file() else Path("/usr/local/bin")

    def _base(self, name: str) -> list[str]:
        path = self.bin_dir / name
        return [os.environ.get("BASH", "bash"), str(path)] if os.name == "nt" else [str(path)]

    def spec(self, name: str, args: list[str], title: str, confirm: bool = False,
             secret: str = "", remote: bool = False, expected: tuple[str, ...] = ()) -> CommandSpec:
        input_text = None
        secrets: list[str] = []
        if confirm:
            input_text = "Confirm\n"
        if secret:
            input_text = (input_text or "") + secret + "\n"
            secrets.append(secret)
        return CommandSpec([*self._base(name), *args], title, input_text=input_text,
                           secrets=secrets, remote=remote, expected=expected,
                           success_label="The existing helper finished; read its output above.",
                           verified_label="The existing helper returned its expected answer.")

    def choice_url(self, url: str) -> CommandSpec:
        return self.spec("secure-linux-choice", ["set", "ha_url", url], "Save the Home Assistant address")

    def ha(self, action: list[str], title: str, confirm: bool = False,
           secret: str = "", remote: bool = False) -> CommandSpec:
        return self.spec("secure-linux-ha", action, title, confirm=confirm, secret=secret, remote=remote)

    def ha_security_api(self) -> CommandSpec:
        return self.spec("secure-linux-ha-secure", ["--check", "--api"], "Read-only Home Assistant API security check", remote=True)

    def server_copy(self, target: str) -> CommandSpec:
        return self.spec("secure-linux-home-server", ["server", "copy", target],
                         "Copy the existing server kit over SSH", confirm=True, remote=True)

    def server_run(self, target: str, action: str) -> CommandSpec:
        return self.spec("secure-linux-home-server", ["server", "run", target, action],
                         f"Run reviewed server action {action}", confirm=True, remote=True)

    def unraid_web(self, url: str) -> CommandSpec:
        return self.spec("secure-linux-home-server", ["unraid", "web", url],
                         "Open the external unRAID web interface", remote=True)

    def unraid_status(self, target: str) -> CommandSpec:
        return self.spec("secure-linux-home-server", ["unraid", "status", target],
                         "Read external unRAID status over SSH", remote=True)

    def unraid_container(self, action: str, target: str, container: str) -> CommandSpec:
        return self.spec("secure-linux-home-server", ["unraid", action, target, container],
                         f"{action.title()} {container} on the external unRAID server", confirm=True, remote=True)

    def unraid_token(self, url: str, token: str) -> CommandSpec:
        return self.spec("secure-linux-home-server", ["unraid", "token-save", url],
                         "Privately save the external unRAID API token", confirm=True, secret=token, remote=True)

    def unraid_api(self, url: str) -> CommandSpec:
        args = ["unraid", "api-test"] + ([url] if url else [])
        return self.spec("secure-linux-home-server", args,
                         "Read-only unRAID GraphQL schema test", remote=True, expected=("queryType", "__schema"))

    def rootless(self) -> CommandSpec:
        return self.spec("secure-linux-home-server", ["docker", "rootless"],
                         "Set up per-user rootless Docker", confirm=True, remote=False)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Home & Server Studio")
    parser.add_argument("--demo", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--tab", "--view", dest="view", choices=("home", "server", "unraid", "docker"), default="home")
    parser.add_argument("--action", choices=("", "status"), default="", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    from home_server_gtk import HomeServerWindow, run_native
    return run_native(HomeServerWindow, "org.securelinux.HomeServerStudio", [sys.argv[0]],
                      backend=HomeBackend(), demo=args.demo, view=args.view, action=args.action)


if __name__ == "__main__":
    raise SystemExit(main())
