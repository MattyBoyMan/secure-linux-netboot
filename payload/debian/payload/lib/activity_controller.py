#!/usr/bin/env python3
"""Headless controller for My Computer Activity.

Collection and redaction stay in activity.py. This module coordinates local
refresh, privacy review and the fixed graphical-tool entry points without GTK.
"""
from __future__ import annotations

import os
from pathlib import Path
import queue
import shutil
import subprocess
import threading
from typing import Any, Callable

from activity import ActivityCollector, demo_snapshot, redact_snapshot, report_html, report_text


# Fixed graphical entry points only. No arbitrary user-provided command is launched.
GUIDED_TOOLS = {
    "opensnitch": [["opensnitch-ui"]],
    "status": [["secure-linux-status-gui"]],
    "health": [["secure-linux-health", "--gui"]],
    "resources": [["missioncenter"], ["gnome-system-monitor"], ["plasma-systemmonitor"], ["flatpak", "run", "io.missioncenter.MissionCenter"]],
    "homeassistant": [["secure-linux-ha", "open"]],
    "backup": [["pika-backup"], ["flatpak", "run", "org.gnome.World.PikaBackup"]],
}

STATUS_WORDS = {
    "ok": "LOOKS GOOD",
    "info": "ACTIVITY",
    "warn": "NEEDS A LOOK",
    "bad": "NEEDS ATTENTION",
    "unknown": "UNAVAILABLE",
}


def filter_sections(snapshot: dict[str, Any], term: str) -> list[dict[str, Any]]:
    """Filter all visible card content without changing the collected snapshot."""
    needle = term.strip().casefold()
    sections = list(snapshot.get("sections", []))
    if not needle:
        return sections
    answer = []
    for section in sections:
        haystack = " ".join([
            str(section.get("title", "")), str(section.get("summary", "")),
            *(str(row.get("label", "")) + " " + str(row.get("value", "")) for row in section.get("rows", [])),
        ]).casefold()
        if needle in haystack:
            answer.append(section)
    return answer


def details_text(section: dict[str, Any]) -> str:
    lines = []
    rows = section.get("rows", [])
    if rows:
        for row in rows:
            lines.append(f"{row.get('label', 'Detail')}\n{row.get('value', 'Unavailable')}")
    else:
        lines.append("No detailed records are available.")
    notes = section.get("notes", [])
    if notes:
        lines.extend(["", *("• " + str(note) for note in notes)])
    return "\n\n".join(lines)


class ExportReviewController:
    """Privacy preview and the dashboard's only filesystem write operation."""

    def __init__(self, snapshot: dict[str, Any]) -> None:
        self.snapshot = snapshot
        self.usernames = True
        self.addresses = True
        self.tokens = True
        self.prepared: dict[str, Any] | None = None
        self.preview = ""
        self.warning = ""
        self.refresh_preview()

    def set_redaction(self, *, usernames: bool, addresses: bool, tokens: bool) -> None:
        self.usernames = usernames
        self.addresses = addresses
        self.tokens = tokens
        self.refresh_preview()

    def refresh_preview(self) -> None:
        self.prepared = redact_snapshot(
            self.snapshot,
            redact_usernames=self.usernames,
            redact_ips=self.addresses,
            redact_tokens=self.tokens,
        )
        self.preview = report_text(self.prepared)
        if self.usernames and self.addresses and self.tokens:
            self.warning = "Privacy defaults are on. Redaction reduces risk; please still read arbitrary log lines before sharing."
        else:
            self.warning = "Warning: one or more redactions are off. The preview may contain private names, addresses or secrets."

    def save(self, destination: str | os.PathLike[str]) -> Path:
        if self.prepared is None:
            raise ValueError("Prepare the privacy preview before saving.")
        path = Path(destination)
        # The user-selected destination is the dashboard's only write operation.
        with path.open("w", encoding="utf-8", newline="\n") as handle:
            handle.write(report_html(self.prepared))
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
        return path


class ActivityController:
    def __init__(self, collector: Any | None = None, demo: bool = False) -> None:
        self.collector = collector or ActivityCollector()
        self.demo = demo
        self.snapshot: dict[str, Any] = demo_snapshot() if demo else {"sections": [], "privacy": {"usernames": []}}
        self.filter = ""
        self.refreshing = False
        self.status_text = "Preparing a local read-only view…"
        self.events: queue.Queue[tuple[str, Any]] = queue.Queue()
        if demo:
            self.status_text = "EXAMPLE DATA — not this computer · " + str(self.snapshot.get("generated_at", "time unavailable"))

    @property
    def sections(self) -> list[dict[str, Any]]:
        return filter_sections(self.snapshot, self.filter)

    def set_snapshot(self, snapshot: dict[str, Any]) -> None:
        self.snapshot = snapshot
        stamp = snapshot.get("generated_at", "time unavailable")
        self.status_text = ("EXAMPLE DATA — not this computer · " if snapshot.get("demo") else "Last refreshed: ") + str(stamp)

    def refresh(self) -> bool:
        if self.refreshing or self.demo:
            return False
        self.refreshing = True
        self.status_text = "Reading local metadata… no network request is being made"

        def work() -> None:
            try:
                self.events.put(("ok", self.collector.collect()))
            except Exception as exc:
                self.events.put(("error", type(exc).__name__))

        threading.Thread(target=work, name="activity-local-refresh", daemon=True).start()
        return True

    def process_events(self) -> list[tuple[str, Any]]:
        """Drain completed worker results; a native view decides how to notify."""
        answer = []
        while True:
            try:
                kind, value = self.events.get_nowait()
            except queue.Empty:
                break
            self.refreshing = False
            if kind == "ok":
                self.set_snapshot(value)
            else:
                self.status_text = f"Refresh unavailable ({value}). Existing information was kept; nothing was invented."
            answer.append((kind, value))
        return answer

    def export_review(self) -> ExportReviewController:
        if not self.snapshot.get("sections"):
            raise ValueError("Wait for the first local refresh to finish, then review the report.")
        return ExportReviewController(self.snapshot)

    @staticmethod
    def guided_command(section: dict[str, Any], which: Callable[[str], Any] = shutil.which) -> list[str] | None:
        key = section.get("action", "status")
        candidates = GUIDED_TOOLS.get(key, GUIDED_TOOLS["status"])
        return next((list(args) for args in candidates if which(args[0])), None)

    def open_guided_tool(
        self,
        section: dict[str, Any],
        *,
        confirm: Callable[[str, str], bool],
        notify: Callable[[str, str], None],
        which: Callable[[str], Any] = shutil.which,
        popen: Callable[..., Any] = subprocess.Popen,
    ) -> bool:
        command = self.guided_command(section, which)
        if command is None:
            notify(
                "Tool not installed",
                "The existing graphical tool for this card is not installed. No substitute command was run and nothing was changed.",
            )
            return False
        name = str(section.get("action_label", "Open existing tool"))
        approved = confirm(
            "Open the existing control centre?",
            f"{name} will open in a separate window.\n\nThis dashboard stays read-only. Review each step there; changes require your explicit confirmation in that tool.",
        )
        if not approved:
            return False
        try:
            popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
                shell=False,
            )
        except OSError as exc:
            notify("Tool did not open", f"The existing tool could not be opened. Nothing was changed.\n\n{exc}")
            return False
        return True
