#!/usr/bin/env python3
"""Pseudonymous, atomic update timing profiles and honest phase progress."""
from __future__ import annotations

import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import statistics
import time
from typing import Any, Callable
import uuid

from flipper_companion_core import CompanionError, _atomic_json, safe_relative, utc_now

PHASES = ("download", "copy", "flash", "verify")
SCHEMA_VERSION = 1
MAX_HISTORY = 3
_ID = re.compile(r"(?:computer|device)-[0-9a-f-]{16,64}\Z")


def _phase_record() -> dict[str, Any]:
    return {
        "status": "pending",
        "seconds": 0.0,
        "started_at": None,
        "completed": None,
        "total": None,
        "percent": None,
        "note": None,
    }


class TimingStore:
    """Keep each computer/device pair independent without storing a raw UID."""

    def __init__(
        self,
        root: Path,
        *,
        clock: Callable[[], float] = time.time,
        uuid_factory: Callable[[], Any] = uuid.uuid4,
        token_factory: Callable[[int], str] = secrets.token_hex,
    ) -> None:
        self.root = root.expanduser().resolve(strict=False)
        self.clock = clock
        self.uuid_factory = uuid_factory
        self.token_factory = token_factory
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            os.chmod(self.root, 0o700)
        except OSError:
            pass
        self.identity_path = self.root / "identity.json"
        if self.identity_path.exists():
            self.identity = self._read(self.identity_path)
        else:
            self.identity = {
                "schema_version": SCHEMA_VERSION,
                "computer_id": "computer-" + str(uuid_factory()),
                "pseudonym_salt": token_factory(32),
                "privacy": "Random computer ID and local HMAC device pseudonyms; no hostname, raw UID, paths, or secrets in update history.",
            }
            _atomic_json(self.identity_path, self.identity)
        if self.identity.get("schema_version") != SCHEMA_VERSION:
            raise CompanionError("Unsupported timing identity schema.")
        if not _ID.fullmatch(str(self.identity.get("computer_id", ""))):
            raise CompanionError("Invalid pseudonymous computer identity.")
        try:
            self.salt = bytes.fromhex(str(self.identity["pseudonym_salt"]))
        except (KeyError, ValueError) as exc:
            raise CompanionError("Invalid device pseudonym salt.") from exc
        if len(self.salt) != 32:
            raise CompanionError("Invalid device pseudonym salt length.")
        self.computer_id = str(self.identity["computer_id"])

    @staticmethod
    def _read(path: Path) -> dict[str, Any]:
        try:
            with path.open(encoding="utf-8") as handle:
                value = json.load(handle)
        except (OSError, json.JSONDecodeError) as exc:
            raise CompanionError(f"Timing metadata is missing or invalid: {path}") from exc
        if not isinstance(value, dict):
            raise CompanionError("Timing metadata has an invalid shape.")
        return value

    def device_id(self, hardware_uid: str) -> str:
        if not isinstance(hardware_uid, str) or not 1 <= len(hardware_uid) <= 256:
            raise CompanionError("The device did not report a usable hardware UID.")
        if any(ord(char) < 32 for char in hardware_uid):
            raise CompanionError("The device hardware UID contains control characters.")
        digest = hmac.new(self.salt, hardware_uid.encode("utf-8"), hashlib.sha256).hexdigest()
        return "device-" + digest[:32]

    def _validate_ids(self, device_id: str) -> None:
        if not _ID.fullmatch(self.computer_id) or not _ID.fullmatch(device_id):
            raise CompanionError("Invalid pseudonymous timing profile identity.")

    def _profile_path(self, device_id: str) -> Path:
        self._validate_ids(device_id)
        return self.root / "profiles" / safe_relative(self.computer_id) / (device_id + ".json")

    def _active_path(self, device_id: str) -> Path:
        self._validate_ids(device_id)
        return self.root / "active" / safe_relative(self.computer_id) / (device_id + ".json")

    def profile(self, device_id: str) -> dict[str, Any]:
        path = self._profile_path(device_id)
        if not path.exists():
            return {
                "schema_version": SCHEMA_VERSION,
                "computer_id": self.computer_id,
                "device_id": device_id,
                "successful_updates": [],
            }
        value = self._read(path)
        if (
            value.get("schema_version") != SCHEMA_VERSION
            or value.get("computer_id") != self.computer_id
            or value.get("device_id") != device_id
            or not isinstance(value.get("successful_updates"), list)
        ):
            raise CompanionError("Timing profile identity or schema is invalid.")
        return value

    def start(self, hardware_uid: str, release_tag: str) -> "UpdateTiming":
        device_id = self.device_id(hardware_uid)
        active_path = self._active_path(device_id)
        if active_path.exists():
            raise CompanionError("This computer/device pair already has an unfinished update; verify or cancel it first.")
        state = {
            "schema_version": SCHEMA_VERSION,
            "operation_id": str(self.uuid_factory()),
            "computer_id": self.computer_id,
            "device_id": device_id,
            "release_tag": release_tag,
            "created_at": utc_now(),
            "phases": {phase: _phase_record() for phase in PHASES},
            "active_phase": None,
            "firmware_verified": False,
            "sd_verified": False,
            "complete": False,
        }
        operation = UpdateTiming(self, state, active_path)
        operation.save()
        return operation

    def resume(self, hardware_uid: str) -> "UpdateTiming":
        device_id = self.device_id(hardware_uid)
        path = self._active_path(device_id)
        if not path.exists():
            raise CompanionError("No unfinished update timing operation exists for this computer/device pair.")
        state = self._read(path)
        if (
            state.get("schema_version") != SCHEMA_VERSION
            or state.get("computer_id") != self.computer_id
            or state.get("device_id") != device_id
            or set(state.get("phases") or {}) != set(PHASES)
        ):
            raise CompanionError("Unfinished update timing metadata is invalid.")
        return UpdateTiming(self, state, path)

    def eta(self, device_id: str, phase: str, elapsed: float = 0.0) -> dict[str, Any] | None:
        if phase not in PHASES:
            raise CompanionError("Unknown update phase.")
        samples = [
            float(record["phases"][phase])
            for record in self.profile(device_id)["successful_updates"][-MAX_HISTORY:]
            if isinstance(record.get("phases"), dict)
            and isinstance(record["phases"].get(phase), (int, float))
            and not isinstance(record["phases"].get(phase), bool)
            and record["phases"][phase] >= 0
        ]
        if not samples:
            return None
        return {
            "low_seconds": int(round(max(0.0, min(samples) - elapsed))),
            "high_seconds": int(round(max(0.0, max(samples) - elapsed))),
            "median_seconds": int(round(max(0.0, statistics.median(samples) - elapsed))),
            "sample_count": len(samples),
            "basis": "Last 1–3 fully firmware-and-SD-verified updates on this computer/device pair; actual remaining time varies.",
        }


class UpdateTiming:
    def __init__(self, store: TimingStore, state: dict[str, Any], path: Path) -> None:
        self.store = store
        self.state = state
        self.path = path

    @property
    def device_id(self) -> str:
        return str(self.state["device_id"])

    def save(self) -> None:
        self.state["updated_at"] = utc_now()
        _atomic_json(self.path, self.state)

    def begin(self, phase: str, *, total: int | None = None, note: str | None = None) -> None:
        if phase not in PHASES:
            raise CompanionError("Unknown update phase.")
        if self.state["complete"]:
            raise CompanionError("The update timing operation is already complete.")
        if self.state.get("active_phase") is not None:
            raise CompanionError(f"Phase {self.state['active_phase']} is still active.")
        record = self.state["phases"][phase]
        if total is not None and (isinstance(total, bool) or not isinstance(total, int) or total < 0):
            raise CompanionError("Phase total must be a nonnegative integer or unknown.")
        record["status"] = "running"
        record["started_at"] = self.store.clock()
        record["total"] = total
        record["completed"] = 0 if total is not None else None
        record["percent"] = 0.0 if total and total > 0 else None
        record["note"] = note
        self.state["active_phase"] = phase
        self.save()

    def progress(self, phase: str, completed: int, total: int | None = None) -> None:
        record = self.state["phases"][phase]
        if self.state.get("active_phase") != phase:
            raise CompanionError(f"Phase {phase} is not active.")
        if isinstance(completed, bool) or not isinstance(completed, int) or completed < 0:
            raise CompanionError("Measured phase progress must be a nonnegative integer.")
        if total is not None:
            record["total"] = total
        known_total = record.get("total")
        if known_total is not None and completed > known_total:
            raise CompanionError("Measured phase progress exceeds its declared total.")
        record["completed"] = completed
        record["percent"] = round(100.0 * completed / known_total, 1) if known_total else None
        self.save()

    def finish(self, phase: str, *, status: str = "complete", note: str | None = None) -> None:
        record = self.state["phases"][phase]
        if self.state.get("active_phase") != phase or record.get("started_at") is None:
            raise CompanionError(f"Phase {phase} is not active.")
        elapsed = max(0.0, self.store.clock() - float(record["started_at"]))
        record["seconds"] = round(float(record.get("seconds") or 0.0) + elapsed, 3)
        record["started_at"] = None
        record["status"] = status
        record["note"] = note
        if status == "complete" and record.get("total") is not None:
            record["completed"] = record["total"]
            record["percent"] = 100.0
        self.state["active_phase"] = None
        self.save()

    def external(self, phase: str, note: str) -> None:
        if phase not in PHASES or self.state.get("active_phase") is not None:
            raise CompanionError("Cannot mark an external phase while another phase is active.")
        record = self.state["phases"][phase]
        record.update({"status": "external-unmeasured", "seconds": None, "started_at": None,
                       "completed": None, "total": None, "percent": None, "note": note})
        self.save()

    def fail(self, phase: str, note: str) -> None:
        if self.state.get("active_phase") == phase:
            self.finish(phase, status="failed", note=note)
        else:
            self.state["phases"][phase]["status"] = "failed"
            self.state["phases"][phase]["note"] = note
            self.save()

    def complete(self, *, firmware_verified: bool, sd_verified: bool) -> None:
        self.state["firmware_verified"] = firmware_verified is True
        self.state["sd_verified"] = sd_verified is True
        self.state["complete"] = firmware_verified is True and sd_verified is True
        self.save()
        if not self.state["complete"]:
            return
        durations = {
            phase: self.state["phases"][phase].get("seconds")
            for phase in PHASES
            if isinstance(self.state["phases"][phase].get("seconds"), (int, float))
        }
        profile = self.store.profile(self.device_id)
        profile["successful_updates"].append({
            "operation_id": self.state["operation_id"],
            "release_tag": self.state["release_tag"],
            "computer_recorded_at": utc_now(),
            "phases": durations,
            "firmware_verified": True,
            "sd_verified": True,
        })
        profile["successful_updates"] = profile["successful_updates"][-MAX_HISTORY:]
        _atomic_json(self.store._profile_path(self.device_id), profile)
        self.path.unlink()

    def snapshot(self) -> dict[str, Any]:
        phases: dict[str, Any] = {}
        for phase in PHASES:
            record = dict(self.state["phases"][phase])
            started = record.get("started_at")
            elapsed = float(record.get("seconds") or 0.0)
            if started is not None:
                elapsed += max(0.0, self.store.clock() - float(started))
            record["elapsed_seconds"] = round(elapsed, 1) if record.get("seconds") is not None else None
            record.pop("started_at", None)
            record["eta"] = self.store.eta(self.device_id, phase, elapsed)
            phases[phase] = record
        complete = self.state.get("complete") is True and self.state.get("firmware_verified") is True and self.state.get("sd_verified") is True
        return {
            "computer_id": self.state["computer_id"],
            "device_id": self.state["device_id"],
            "release_tag": self.state["release_tag"],
            "phases": phases,
            "overall_percent": 100 if complete else None,
            "progress_kind": "complete" if complete else "indeterminate-until-firmware-and-SD-verification",
            "firmware_verified": self.state.get("firmware_verified") is True,
            "sd_verified": self.state.get("sd_verified") is True,
            "eta_note": "ETA is unavailable without successful matching history; phase percentages use only measured totals.",
        }
