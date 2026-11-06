#!/usr/bin/env python3
"""Toolkit-independent command contracts for Secure Linux graphical tools.

The native GTK views delegate every operation to these fixed argument vectors.
Secrets travel only over standard input and are redacted from streamed output.
This module deliberately has no GUI dependency so backend safety tests remain
headless and importable on systems without GTK4/Libadwaita.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import os
import queue
import re
import subprocess
import threading
from typing import Callable, Iterable, Sequence

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\r")
PERCENT_RE = re.compile(r"(?<!\d)(\d{1,3})%")
ETA_RE = re.compile(r"ETA:\s*([^,\n]+)", re.IGNORECASE)


def format_bytes(value: object) -> str:
    try:
        number = int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return "Unknown"
    units = ("B", "KiB", "MiB", "GiB", "TiB", "PiB")
    amount = float(number)
    for unit in units:
        if abs(amount) < 1024 or unit == units[-1]:
            return f"{amount:.0f} {unit}" if unit == "B" else f"{amount:.1f} {unit}"
        amount /= 1024
    return f"{number} bytes"


def health_text(value: object) -> str:
    if value is True:
        return "SMART passed*"
    if value is False:
        return "Attention"
    return "Unknown"


def redact(text: str, secrets: Iterable[str]) -> str:
    answer = ANSI_RE.sub("", text)
    for secret in secrets:
        if secret and secret != "Confirm":
            answer = answer.replace(secret, "[hidden]")
    return answer


def exact_review_valid(values: Sequence[str], phrases: Sequence[str], secret: str = "",
                       secret_required: bool = False, password_policy: bool = False) -> bool:
    """Validate review input without retaining secrets or importing a toolkit."""
    if len(values) != len(phrases) or any(value != phrase for value, phrase in zip(values, phrases)):
        return False
    if password_policy:
        return 12 <= len(secret) <= 256 and bool(secret.strip()) and not any(c in secret for c in "\r\n\x00")
    if secret_required:
        return 0 < len(secret) <= 8192
    return True


@dataclass
class CommandSpec:
    """One reviewed backend invocation; input_text is never displayed."""

    argv: list[str]
    title: str
    input_text: str | None = None
    secrets: list[str] = field(default_factory=list)
    expected: tuple[str, ...] = ()
    success_label: str = "The existing tool finished successfully."
    verified_label: str = "Verified by the existing tool."
    remote: bool = False

    def __post_init__(self) -> None:
        if not self.argv or any(not isinstance(part, str) or not part for part in self.argv):
            raise ValueError("A fixed, nonempty argument vector is required")
        if any("\x00" in part for part in self.argv):
            raise ValueError("NUL is not valid in a command argument")


@dataclass
class OperationResult:
    state: str
    returncode: int
    verified: bool
    message: str


def classify_result(spec: CommandSpec, returncode: int, output: str, cancelled: bool = False) -> OperationResult:
    """Never turn a zero exit, cancellation or missing receipt into verification."""
    if cancelled:
        return OperationResult("interrupted", returncode, False,
                               "Interrupted. Treat the result as incomplete or unverified; use the engine's resume or restart choice.")
    if returncode != 0:
        return OperationResult("failed", returncode, False,
                               f"The existing tool stopped with status {returncode}. Read its output; no success is claimed.")
    if spec.expected and not any(marker in output for marker in spec.expected):
        return OperationResult("unverified", returncode, False,
                               "The tool exited zero but did not return its expected verified-result marker. Treat this as UNVERIFIED.")
    if spec.remote:
        return OperationResult("completed", returncode, False,
                               "The remote command exited zero. Review the server's own output above; this is not independent verification.")
    if spec.expected:
        return OperationResult("verified", returncode, True, spec.verified_label)
    return OperationResult("completed", returncode, False, spec.success_label)


class CommandRunner:
    """Background subprocess adapter with line progress and honest cancellation."""

    def __init__(self, events: queue.Queue, popen: Callable = subprocess.Popen):
        self.events = events
        self.popen = popen
        self.process: subprocess.Popen | None = None
        self.spec: CommandSpec | None = None
        self.cancelled = False
        self.output: list[str] = []

    @property
    def busy(self) -> bool:
        return self.process is not None

    def start(self, spec: CommandSpec) -> None:
        if self.busy:
            raise RuntimeError("Another operation is still running")
        self.spec = spec
        self.cancelled = False
        self.output = []
        environment = os.environ.copy()
        environment.update(PYTHONUNBUFFERED="1", NO_COLOR="1", TERM="dumb")
        try:
            self.process = self.popen(
                spec.argv,
                stdin=subprocess.PIPE if spec.input_text is not None else subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
                env=environment,
                shell=False,
            )
        except OSError as exc:
            self.process = None
            self.events.put(("finished", classify_result(spec, 127, str(exc)), str(exc)))
            return
        threading.Thread(target=self._feed_stdin, daemon=True).start()
        threading.Thread(target=self._read_output, daemon=True).start()
        self.events.put(("started", spec.title, ""))

    def _feed_stdin(self) -> None:
        process, spec = self.process, self.spec
        if process is None or spec is None or spec.input_text is None or process.stdin is None:
            return
        try:
            process.stdin.write(spec.input_text)
            process.stdin.close()
        except (BrokenPipeError, OSError):
            pass
        finally:
            spec.input_text = None

    def _read_output(self) -> None:
        process, spec = self.process, self.spec
        if process is None or spec is None or process.stdout is None:
            return
        try:
            for raw in process.stdout:
                clean = redact(raw.rstrip("\n"), spec.secrets)
                self.output.append(clean)
                self.events.put(("output", clean, ""))
                percent = None
                match = PERCENT_RE.search(clean)
                if match:
                    percent = max(0, min(100, int(match.group(1))))
                eta = ETA_RE.search(clean)
                self.events.put(("progress", percent, eta.group(1).strip() if eta else ""))
            returncode = process.wait()
        except OSError as exc:
            returncode = process.poll() if process.poll() is not None else 1
            self.output.append(str(exc))
        finally:
            try:
                process.stdout.close()
            except OSError:
                pass
            if process.stdin is not None and not process.stdin.closed:
                try:
                    process.stdin.close()
                except OSError:
                    pass
        result = classify_result(spec, returncode, "\n".join(self.output), self.cancelled)
        self.events.put(("finished", result, "\n".join(self.output)))
        self.process = None
        self.spec = None

    def cancel(self) -> bool:
        if self.process is None or self.process.poll() is not None:
            return False
        self.cancelled = True
        self.events.put(("output", "Cancellation requested. Waiting for the existing tool to stop; the result is not verified.", ""))
        try:
            self.process.terminate()
        except OSError:
            pass
        return True


def launcher_module(app: str, argv: Sequence[str] | None = None) -> int:
    """Import only the requested frontend after the launcher's GTK check."""
    if app == "usb":
        from usb_tools_gui import main
    elif app == "home":
        from home_server_gui import main
    else:
        raise ValueError(f"Unknown graphical application: {app}")
    return main(list(argv or ()))


__all__ = [
    "CommandRunner", "CommandSpec", "OperationResult", "classify_result",
    "exact_review_valid", "format_bytes", "health_text", "launcher_module", "redact",
]
