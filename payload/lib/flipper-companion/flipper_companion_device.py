#!/usr/bin/env python3
"""Official-protobuf device reporting and SD resource-date inspection."""
from __future__ import annotations

from datetime import datetime, timezone
import importlib
import json
from pathlib import Path
import re
from typing import Any, Callable

from flipper_companion_core import CompanionError, path_inside
from flipper_companion_roguemaster import check_release
from flipper_companion_timing import TimingStore

MAX_MANIFEST_BYTES = 8 * 1024 * 1024
FIELD_MAP = {
    "firmware.version": "firmware_version",
    "firmware.build.date": "firmware_build_date",
    "firmware.commit": "firmware_commit",
    "firmware.api.major": "firmware_api_major",
    "firmware.api.minor": "firmware_api_minor",
    "firmware.origin.fork": "firmware_origin_fork",
    "firmware.origin.git": "firmware_origin_git",
    "hardware.target": "hardware_target",
}


def _default_proto_factory(**kwargs: Any) -> Any:
    try:
        module = importlib.import_module("flipperzero_protobuf.flipper_proto")
        factory = getattr(module, "FlipperProto")
    except (ImportError, AttributeError) as exc:
        raise CompanionError(
            "Device-reported fields require the optional official flipperzero_protobuf_py package and a USB connection. "
            "They are unavailable; computer journals are not a substitute."
        ) from exc
    return factory(**kwargs)


def _clean(value: Any) -> str | None:
    if value is None or isinstance(value, (dict, list, tuple, bytes)):
        return None
    text = str(value).strip()
    if not text:
        return None
    text = "".join(char for char in text if ord(char) >= 32 and char != "\x7f")
    return text[:512] or None


def read_device_info(
    *,
    serial_port: str | None = None,
    proto_factory: Callable[..., Any] | None = None,
) -> dict[str, Any]:
    """Read official DEV-INFO fields; the private UID is never for display/storage."""
    factory = proto_factory or _default_proto_factory
    kwargs = {"serial_port": serial_port} if serial_port else {}
    try:
        proto = factory(**kwargs)
    except CompanionError:
        raise
    except Exception as exc:
        raise CompanionError("Could not open the Flipper protobuf connection; device fields are unavailable.") from exc
    try:
        raw = proto.rpc_device_info()
    except Exception as exc:
        raise CompanionError("Could not read device DEV-INFO; device fields are unavailable.") from exc
    finally:
        close = getattr(proto, "close", None)
        if callable(close):
            close()
    if not isinstance(raw, dict):
        raise CompanionError("Device DEV-INFO returned an unexpected shape.")
    result = {public: _clean(raw.get(official)) for official, public in FIELD_MAP.items()}
    uid = _clean(raw.get("hardware.uid"))
    if not uid:
        raise CompanionError("Device DEV-INFO has no hardware.uid; a pseudonymous timing profile cannot be selected.")
    result["_hardware_uid"] = uid
    result["device_update_timestamp"] = None
    result["device_update_timestamp_note"] = (
        "Unavailable: official DEV-INFO exposes a firmware build date, not a true last-update timestamp."
    )
    result["source"] = "Device-reported official protobuf rpc_device_info/DEV-INFO"
    return result


def public_device_info(report: dict[str, Any], store: TimingStore | None = None) -> dict[str, Any]:
    public = {key: value for key, value in report.items() if key != "_hardware_uid"}
    if store is not None:
        public["device_id"] = store.device_id(report["_hardware_uid"])
        public["computer_id"] = store.computer_id
    return public


def read_sd_resource_date(sd: Path) -> dict[str, Any]:
    sd = sd.expanduser().resolve()
    manifest = path_inside(sd, "Manifest")
    if not manifest.is_file() or manifest.is_symlink():
        return {
            "resource_timestamp": None,
            "resource_date": None,
            "status": "unavailable",
            "source": "SD /ext/Manifest T field (resource date only, not device update time)",
        }
    if manifest.stat().st_size > MAX_MANIFEST_BYTES:
        raise CompanionError("SD resource Manifest is too large to inspect safely.")
    try:
        lines = manifest.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        raise CompanionError("SD resource Manifest is unreadable.") from exc
    values = [line[2:].strip() for line in lines if line.startswith("T:")]
    if len(values) != 1 or not values[0].isdigit():
        return {
            "resource_timestamp": None,
            "resource_date": None,
            "status": "unavailable",
            "source": "SD /ext/Manifest T field (resource date only, not device update time)",
        }
    timestamp = int(values[0])
    try:
        iso = datetime.fromtimestamp(timestamp, timezone.utc).isoformat()
    except (OverflowError, OSError, ValueError):
        iso = None
    return {
        "resource_timestamp": timestamp,
        "resource_date": iso,
        "status": "available" if iso else "unavailable",
        "source": "Device SD /ext/Manifest T field; resource build date, not a device update timestamp",
    }


def check_for_roguemaster_update(
    sd: Path,
    timing_store: TimingStore,
    *,
    serial_port: str | None = None,
    proto_factory: Callable[..., Any] | None = None,
    opener: Any,
) -> dict[str, Any]:
    """Show latest metadata and genuine device/SD values without version guessing."""
    latest = check_release("stable", opener=opener)
    try:
        private = read_device_info(serial_port=serial_port, proto_factory=proto_factory)
        device = public_device_info(private, timing_store)
        device_status = "available"
        device_error = None
    except CompanionError as exc:
        private = None
        device = {public: None for public in FIELD_MAP.values()}
        device.update({
            "device_update_timestamp": None,
            "device_update_timestamp_note": "Unavailable: no device DEV-INFO was read; no computer timestamp is substituted.",
            "source": "unavailable",
        })
        device_status = "unavailable"
        device_error = str(exc)
    resource = read_sd_resource_date(sd)
    installed = device.get("firmware_version")
    matches = installed == latest["tag_name"] if installed else None
    return {
        "workflow": "Check for RogueMaster Update",
        "device_status": device_status,
        "device_error": device_error,
        "device": device,
        "sd_resource": resource,
        "latest_stable": {
            "tag": latest["tag_name"],
            "release_date": latest.get("published_at"),
            "source": latest["source_api"],
        },
        "installed_matches_latest_tag": matches,
        "update_available": False if matches is True else None,
        "assessment": (
            "The device-reported firmware version exactly matches the latest stable tag."
            if matches is True else
            "A newer/older ordering cannot be proven from different firmware/tag schemes; review the displayed latest stable release. No update claim is inferred from computer records."
        ),
        "timing": {
            "computer_id": timing_store.computer_id,
            "history": (
                timing_store.profile(timing_store.device_id(private["_hardware_uid"]))["successful_updates"]
                if private is not None else []
            ),
        },
    }


def firmware_matches_release(device: dict[str, Any], release: dict[str, Any]) -> tuple[bool, list[str]]:
    reasons: list[str] = []
    version = device.get("firmware_version")
    commit = (device.get("firmware_commit") or "").lower()
    tag = str(release.get("tag_name") or "")
    exact_version = bool(version and version == tag)
    tag_commit = re.search(r"-([0-9a-fA-F]{8,40})$", tag)
    exact_commit = bool(tag_commit and commit and commit.startswith(tag_commit.group(1).lower()))
    if not (exact_version or exact_commit):
        reasons.append("Device firmware version/commit does not prove the selected release tag.")
    origin = (device.get("firmware_origin_fork") or "").casefold()
    if "rogue" not in origin:
        reasons.append("Device firmware origin is not reported as RogueMaster.")
    if str(device.get("hardware_target")) != "7":
        reasons.append("Device hardware target is not reported as 7.")
    return not reasons, reasons


def parse_json_file(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise CompanionError(f"JSON metadata is invalid: {path}") from exc
    if not isinstance(value, dict):
        raise CompanionError("JSON metadata must be an object.")
    return value
