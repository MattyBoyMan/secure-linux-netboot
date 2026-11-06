#!/usr/bin/env python3
"""Explicit advanced RogueMaster install hand-off and verified completion."""
from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
from typing import Any, Callable
from urllib.request import urlopen

from flipper_companion_core import CompanionError, path_inside, sha256_file
from flipper_companion_device import firmware_matches_release, public_device_info, read_device_info
from flipper_companion_roguemaster import (
    _verify_cached,
    check_release,
    prepare_release,
    update_release,
)
from flipper_companion_timing import TimingStore, UpdateTiming

Reporter = Callable[[str], None]


def _silent(_: str) -> None:
    return None


def download_and_install_latest(
    *,
    work_dir: Path,
    sd: Path,
    backup_dir: Path,
    timing_store: TimingStore,
    serial_port: str | None = None,
    proto_factory: Callable[..., Any] | None = None,
    opener: Any = urlopen,
    resource_conflict: str = "abort",
    yes: bool = False,
    root: Path | None = None,
    reporter: Reporter = _silent,
    input_function: Any = input,
    which: Callable[[str], str | None] = shutil.which,
    popen: Any = subprocess.Popen,
) -> dict[str, Any]:
    """Download/verify, back up, and open the only researched local-TGZ GUI route."""
    before = read_device_info(serial_port=serial_port, proto_factory=proto_factory)
    selected = check_release("stable", opener=opener)
    timing = timing_store.start(before["_hardware_uid"], selected["tag_name"])
    timing.begin("download", total=selected["asset_size"], note="Official immutable GitHub asset size/SHA-256 metadata")

    def progress(completed: int, total: int, status: str) -> None:
        timing.progress("download", completed, total)
        if status == "cached":
            timing.state["phases"]["download"]["note"] = "Verified cached bytes; no new download was needed"

    try:
        release_dir = prepare_release(work_dir, opener=opener, reporter=reporter, progress=progress)
        timing.finish("download")
    except Exception:
        timing.fail("download", "Download/cache verification did not complete; no success was recorded.")
        raise
    timing.external(
        "copy",
        "qFlipper GUI performs the package transfer; the researched interface exposes no reliable host byte progress for that transfer.",
    )

    def before_launch() -> None:
        timing.begin("flash", note="External qFlipper GUI; indeterminate until post-update device verification")

    try:
        launched = update_release(
            release_dir,
            sd,
            method="qflipper",
            resource_conflict=resource_conflict,
            yes=yes,
            root=root,
            backup_dir=backup_dir,
            reporter=reporter,
            input_function=input_function,
            which=which,
            popen=popen,
            _before_launch=before_launch,
        )
    except Exception:
        if timing.state.get("active_phase") == "flash":
            timing.fail("flash", "qFlipper did not launch; no flash or completion is claimed.")
        raise
    reporter("In qFlipper, choose Install from file and select the verified package.tgz shown below.")
    reporter("Do not run no-argument qFlipper-cli: its default update can select official stock firmware.")
    reporter("Do not substitute firmware.dfu or dfu-util -D: Core1-only flashing is not a complete RogueMaster update.")
    reporter("If qFlipper asks for a device reboot/button action, follow its prompt. Recovery button sequences are not normal updates.")
    return {
        "workflow": "Download and Install Latest RogueMaster Update for Flipper Device",
        "status": "awaiting-user-qflipper",
        "release_dir": str(release_dir),
        "archive": launched["archive"],
        "device": public_device_info(before, timing_store),
        "flash_performed": False,
        "update_complete": False,
        "next_step": "Complete Install from file in qFlipper, reconnect the updated Flipper and mounted SD, then run rm-verify with this release directory and SD.",
        "timing": timing.snapshot(),
    }


def verify_installed_update(
    *,
    release_dir: Path,
    sd: Path,
    timing_store: TimingStore,
    serial_port: str | None = None,
    proto_factory: Callable[..., Any] | None = None,
    reporter: Reporter = _silent,
) -> dict[str, Any]:
    """Record 100% only when device identity/release and every SD resource match."""
    release_dir = release_dir.expanduser().resolve()
    sd = sd.expanduser().resolve()
    state = _verify_cached(release_dir)
    after = read_device_info(serial_port=serial_port, proto_factory=proto_factory)
    timing = timing_store.resume(after["_hardware_uid"])
    if timing.state.get("release_tag") != state["release"].get("tag_name"):
        raise CompanionError("The unfinished timing operation belongs to a different release.")
    if timing.state.get("active_phase") != "flash":
        flash_status = timing.state["phases"]["flash"].get("status")
        verify_status = timing.state["phases"]["verify"].get("status")
        retryable = (
            timing.state.get("active_phase") is None
            and flash_status in {"failed", "complete"}
            and verify_status == "failed"
            and timing.state.get("complete") is not True
        )
        if not retryable:
            raise CompanionError("This update is not awaiting post-qFlipper verification; no completion state was changed.")
        timing.begin("flash", note="Rechecking the same qFlipper-launched update after a failed verification")
    firmware_ok, firmware_reasons = firmware_matches_release(after, state["release"])
    timing.finish(
        "flash",
        status="complete" if firmware_ok else "failed",
        note="Device firmware evidence matched the selected release." if firmware_ok else "; ".join(firmware_reasons),
    )
    timing.begin("verify", total=2, note="Independent firmware and SD-resource integrity checks")
    timing.progress("verify", 1, 2)
    mismatches: list[str] = []
    for record in state["resource_files"]:
        relative = record["path"]
        try:
            destination = path_inside(sd, relative)
            if not destination.is_file() or destination.is_symlink() or destination.stat().st_size != record["size"]:
                mismatches.append(relative)
            elif sha256_file(destination) != record["sha256"]:
                mismatches.append(relative)
        except CompanionError:
            mismatches.append(relative)
    sd_ok = not mismatches
    timing.progress("verify", 2, 2)
    timing.finish("verify", status="complete" if firmware_ok and sd_ok else "failed")
    timing.complete(firmware_verified=firmware_ok, sd_verified=sd_ok)
    success = firmware_ok and sd_ok
    if success:
        reporter("Firmware and every SD resource are verified. Overall progress is now 100%; timing history was updated.")
    else:
        reporter("Verification failed. Overall progress remains indeterminate and no successful timing history was recorded.")
    return {
        "workflow": "Verify RogueMaster Firmware and SD Update",
        "status": "verified" if success else "verification-failed",
        "firmware_verified": firmware_ok,
        "firmware_reasons": firmware_reasons,
        "sd_verified": sd_ok,
        "sd_mismatches": mismatches,
        "device": public_device_info(after, timing_store),
        "update_complete": success,
        "timing": timing.snapshot(),
    }
