#!/usr/bin/env python3
"""Toolkit-independent controller for the graphical Flipper companion.

All firmware, SD-card, backup, encryption, verification, recovery and timing
safety decisions remain in the existing backend modules. This controller only
coordinates values, workers, explicit prompts and redacted presentation state.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import queue
import threading
from typing import Any, Callable
from urllib.request import urlopen

from flipper_companion_advanced import download_and_install_latest, verify_installed_update
from flipper_companion_backup import create_backup, create_encrypted_backup, restore_backup, restore_encrypted_backup, verify_backup
from flipper_companion_core import COMPANION_VERSION, CompanionError, companion_status, repository_root
from flipper_companion_device import check_for_roguemaster_update, read_device_info
from flipper_companion_operations import apply_install_plan, launch_qflipper, make_install_plan, open_sd_file_manager
from flipper_companion_resources import (
    build_custom_animations, organise_favourites, organise_key_apps, prepare_stock_resources,
    preview_animations, restore_stock_animations, rollback_stock_animations,
)
from flipper_companion_roguemaster import check_dfu, resume_update, rollback_release
from flipper_companion_timing import TimingStore, UpdateTiming

APP_NAME = "Flipper Zero Backup & Files"
ROOT = Path(os.environ.get("SECURE_LINUX_KIT_ROOT", str(repository_root(__file__)))).expanduser()
DATA_HOME = Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local" / "share")))
APP_DATA = DATA_HOME / "secure-linux-flipper"
DEFAULT_TIMING = APP_DATA / "timing"
DEFAULT_STAGING = APP_DATA / "protected-staging"

BUTTON_ACTIONS = {
    "browse_sd": "action_browse_sd", "refresh_status": "action_refresh_status",
    "browse_work": "action_browse_work", "browse_backup_dir": "action_browse_backup_dir",
    "check_update": "action_check_update", "download_install": "action_download_install",
    "browse_release": "action_browse_release", "verify_update": "action_verify_update",
    "resume_update": "action_resume_update", "browse_backup_dir_2": "action_browse_backup_dir",
    "create_backup": "action_create_backup", "browse_backup": "action_browse_backup",
    "verify_backup": "action_verify_backup", "restore_backup": "action_restore_backup",
    "browse_stock_work": "action_browse_stock_work", "download_stock": "action_download_stock",
    "browse_stock_dir": "action_browse_stock_dir", "preview_stock": "action_preview_stock",
    "restore_stock": "action_restore_stock", "browse_fbt": "action_browse_fbt",
    "browse_animation_output": "action_browse_animation_output", "preview_custom": "action_preview_custom",
    "build_custom": "action_build_custom", "choose_sources": "action_choose_sources",
    "choose_source_folder": "action_choose_source_folder", "browse_computer_dir": "action_browse_computer_dir",
    "install_files": "action_install_files", "save_favourites": "action_save_favourites",
    "organise_apps": "action_organise_apps", "browse_release_2": "action_browse_release",
    "resume_update_2": "action_resume_update", "rollback_update": "action_rollback_update",
    "browse_stock_journal": "action_browse_stock_journal", "rollback_stock": "action_rollback_stock",
    "qflipper": "action_qflipper", "dfu_check": "action_dfu_check", "open_sd": "action_open_sd",
    "clear_activity": "action_clear_activity", "cancel": "action_cancel",
}


class Value:
    """Tiny observable-value analogue; views explicitly synchronize from it."""
    def __init__(self, value: Any) -> None:
        self.value = value
    def get(self) -> Any:
        return self.value
    def set(self, value: Any) -> None:
        self.value = value


def _safe_result(value: Any) -> Any:
    """Remove secret-shaped fields before a result can reach the activity view."""
    if isinstance(value, dict):
        cleaned = {}
        for key, item in value.items():
            if any(word in str(key).casefold() for word in ("passphrase", "password", "secret", "_hardware_uid")):
                cleaned[str(key)] = "[not displayed]"
            else:
                cleaned[str(key)] = _safe_result(item)
        return cleaned
    if isinstance(value, (list, tuple)):
        return [_safe_result(item) for item in value]
    if isinstance(value, Path):
        return str(value)
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    return str(value)


def _format_seconds(seconds: int) -> str:
    if seconds < 60:
        return f"{seconds} sec"
    minutes, remaining = divmod(seconds, 60)
    if minutes < 60:
        return f"{minutes} min {remaining} sec" if remaining else f"{minutes} min"
    hours, minutes = divmod(minutes, 60)
    return f"{hours} hr {minutes} min"


class ObservableUpdateTiming:
    """Thread-safe observer around the backend's real timing operation."""
    def __init__(self, operation: UpdateTiming, owner: "ObservableTimingStore") -> None:
        self._operation = operation
        self._owner = owner
    def __getattr__(self, name: str) -> Any:
        return getattr(self._operation, name)
    def _call(self, name: str, *args: Any, **kwargs: Any) -> Any:
        with self._owner.lock:
            result = getattr(self._operation, name)(*args, **kwargs)
            snapshot = self._operation.snapshot()
        self._owner.notify(snapshot)
        return result
    def begin(self, *args: Any, **kwargs: Any) -> Any: return self._call("begin", *args, **kwargs)
    def progress(self, *args: Any, **kwargs: Any) -> Any: return self._call("progress", *args, **kwargs)
    def finish(self, *args: Any, **kwargs: Any) -> Any: return self._call("finish", *args, **kwargs)
    def external(self, *args: Any, **kwargs: Any) -> Any: return self._call("external", *args, **kwargs)
    def fail(self, *args: Any, **kwargs: Any) -> Any: return self._call("fail", *args, **kwargs)
    def complete(self, *args: Any, **kwargs: Any) -> Any: return self._call("complete", *args, **kwargs)
    def snapshot(self) -> dict[str, Any]:
        with self._owner.lock:
            return self._operation.snapshot()


class ObservableTimingStore(TimingStore):
    """Reuse TimingStore while exposing only its genuine measured snapshots."""
    def __init__(self, *args: Any, listener: Callable[[dict[str, Any]], None], **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self.listener = listener
        self.lock = threading.RLock()
        self.active: ObservableUpdateTiming | None = None
    def notify(self, snapshot: dict[str, Any]) -> None:
        self.listener(snapshot)
    def start(self, hardware_uid: str, release_tag: str) -> ObservableUpdateTiming:
        with self.lock:
            self.active = ObservableUpdateTiming(super().start(hardware_uid, release_tag), self)
            return self.active
    def resume(self, hardware_uid: str) -> ObservableUpdateTiming:
        with self.lock:
            self.active = ObservableUpdateTiming(super().resume(hardware_uid), self)
            return self.active
    def snapshot(self) -> dict[str, Any] | None:
        with self.lock:
            return self.active.snapshot() if self.active is not None else None


class CancelAwareOpener:
    """Cancel only between network reads; the backend still cleans partial files."""
    def __init__(self, cancel: threading.Event, opener: Any = urlopen) -> None:
        self.cancel = cancel
        self.opener = opener
    def _check(self) -> None:
        if self.cancel.is_set():
            raise CompanionError("Cancellation requested; stopped at a safe download boundary.")
    def __call__(self, request: Any, timeout: int) -> "CancelAwareResponse":
        self._check()
        return CancelAwareResponse(self.opener(request, timeout=timeout), self.cancel)


class CancelAwareResponse:
    def __init__(self, response: Any, cancel: threading.Event) -> None:
        self.response = response
        self.cancel = cancel
    def __enter__(self) -> "CancelAwareResponse":
        self.response.__enter__()
        return self
    def __exit__(self, *args: Any) -> Any:
        return self.response.__exit__(*args)
    def geturl(self) -> str:
        return self.response.geturl()
    def read(self, size: int = -1) -> bytes:
        if self.cancel.is_set():
            raise CompanionError("Cancellation requested; stopped at a safe download boundary.")
        data = self.response.read(size)
        if self.cancel.is_set():
            raise CompanionError("Cancellation requested; stopped at a safe download boundary.")
        return data


class CompanionBackend:
    """Thin API adapter; all safety behavior stays in the existing modules."""
    def status(self, root: Path) -> dict[str, Any]: return companion_status(root)
    def check_update(self, sd: Path, store: TimingStore, serial: str | None) -> dict[str, Any]:
        return check_for_roguemaster_update(sd, store, serial_port=serial, opener=urlopen)
    def download_install(self, **kwargs: Any) -> dict[str, Any]: return download_and_install_latest(**kwargs)
    def verify_update(self, **kwargs: Any) -> dict[str, Any]: return verify_installed_update(**kwargs)
    def create_backup(self, *args: Any, **kwargs: Any) -> Path: return create_backup(*args, **kwargs)
    def create_encrypted_backup(self, *args: Any, **kwargs: Any) -> Path: return create_encrypted_backup(*args, **kwargs)
    def verify_backup(self, backup: Path) -> dict[str, Any]: return verify_backup(backup)
    def restore_backup(self, *args: Any, **kwargs: Any) -> dict[str, Any]: return restore_backup(*args, **kwargs)
    def restore_encrypted_backup(self, *args: Any, **kwargs: Any) -> dict[str, Any]: return restore_encrypted_backup(*args, **kwargs)
    def read_device_info(self, serial: str | None) -> dict[str, Any]: return read_device_info(serial_port=serial)
    def prepare_stock(self, **kwargs: Any) -> Path: return prepare_stock_resources(**kwargs)
    def preview_animations(self, resources: Path, names: list[str] | None = None) -> list[dict[str, Any]]:
        return preview_animations(resources, names)
    def restore_stock(self, *args: Any, **kwargs: Any) -> dict[str, Any]: return restore_stock_animations(*args, **kwargs)
    def rollback_stock(self, *args: Any, **kwargs: Any) -> dict[str, Any]: return rollback_stock_animations(*args, **kwargs)
    def build_custom(self, *args: Any, **kwargs: Any) -> dict[str, Any]: return build_custom_animations(*args, **kwargs)
    def favourites(self, *args: Any, **kwargs: Any) -> dict[str, Any]: return organise_favourites(*args, **kwargs)
    def key_apps(self, *args: Any, **kwargs: Any) -> dict[str, Any]: return organise_key_apps(*args, **kwargs)
    def install(self, sources: list[Path], **kwargs: Any) -> dict[str, Any]:
        items = make_install_plan(sources, kind=kwargs.pop("kind"), destination=kwargs.pop("destination"), app_folder=kwargs.pop("app_folder"))
        return apply_install_plan(items, **kwargs)
    def qflipper(self, *args: Any, **kwargs: Any) -> list[str]: return launch_qflipper(*args, **kwargs)
    def open_sd(self, *args: Any, **kwargs: Any) -> list[str]: return open_sd_file_manager(*args, **kwargs)
    def resume_update(self, *args: Any, **kwargs: Any) -> dict[str, Any]: return resume_update(*args, **kwargs)
    def rollback_release(self, *args: Any, **kwargs: Any) -> dict[str, Any]: return rollback_release(*args, **kwargs)
    def dfu_check(self, *args: Any, **kwargs: Any) -> dict[str, Any]: return check_dfu(*args, **kwargs)


class WorkerRequest:
    """A main-thread dialog request with no timeout or implicit approval."""
    def __init__(self, kind: str, prompt: str, review: str = "") -> None:
        self.kind = kind
        self.prompt = prompt
        self.review = review
        self.event = threading.Event()
        self.response: Any = None
    def finish(self, response: Any) -> None:
        if not self.event.is_set():
            self.response = response
            self.event.set()


class FlipperController:
    def __init__(self, backend: CompanionBackend | None = None, *, demo: bool = False) -> None:
        self.backend = backend or CompanionBackend()
        self.demo = demo
        self.events: queue.Queue[tuple[Any, ...]] = queue.Queue()
        self.busy = False
        self.cancel = threading.Event()
        self.close_requested = False
        self.current_thread: threading.Thread | None = None
        self.current_request: WorkerRequest | None = None
        self._review_lines: list[str] = []
        self._review_lock = threading.Lock()
        self._timing_store: ObservableTimingStore | None = None
        self._last_timing: dict[str, Any] | None = None
        self._alive = True
        self.install_sources: list[Path] = []
        self.stock_previews: list[dict[str, Any]] = []
        self.log_lines: list[str] = []
        self.activity_version = 0
        self._variables()
        if demo:
            self._load_demo()
        else:
            self.action_refresh_status()

    def _variables(self) -> None:
        home = Path.home()
        values = {
            "sd_var": "", "serial_var": "", "work_var": str(APP_DATA / "releases"),
            "backup_dir_var": str(home / "Documents" / "Flipper backups"), "release_var": "",
            "conflict_var": "abort", "backup_path_var": "", "encrypted_var": True,
            "stock_work_var": str(APP_DATA / "stock"), "stock_version_var": "", "stock_dir_var": "",
            "stock_journal_var": "", "fbt_var": "", "animation_output_var": str(APP_DATA / "custom-animations"),
            "kind_var": "fap", "app_folder_var": "USB", "data_dest_var": "scripts", "destination_var": "sd",
            "computer_dir_var": str(home / "Documents" / "Flipper SD copy"), "sources_var": "No source files selected",
            "scale_var": 1.5, "flatpak_var": False, "operation_var": "Ready — local features work offline",
            "progress_var": "No operation running", "eta_var": "",
            "status_summary_var": "Device status has not been read yet.", "usb_var": "USB: not checked",
            "mounts_var": "SD candidates: not checked", "tools_var": "",
            "device_version_var": "Unavailable — check not run", "device_build_var": "Unavailable — check not run",
            "latest_version_var": "Unavailable — online check not run", "latest_release_var": "Unavailable — online check not run",
            "update_assessment_var": "No update claim is made without device evidence.",
            "favourites_var": "", "apps_var": "", "selected_stock_names": [],
        }
        for name, value in values.items():
            setattr(self, name, Value(value))
        self.progress_value = 0.0
        self.progress_mode = "determinate"

    def invoke(self, key: str, *args: Any, **kwargs: Any) -> Any:
        if key not in BUTTON_ACTIONS:
            raise KeyError(key)
        return getattr(self, BUTTON_ACTIONS[key])(*args, **kwargs)

    # Native views present choosers; headless tests can supply the chosen value.
    @staticmethod
    def _chosen(variable: Value, chosen: str | os.PathLike[str] | None) -> bool:
        if chosen is None:
            return False
        variable.set(str(chosen))
        return True
    def action_browse_sd(self, chosen=None) -> bool: return self._chosen(self.sd_var, chosen)
    def action_browse_work(self, chosen=None) -> bool: return self._chosen(self.work_var, chosen)
    def action_browse_backup_dir(self, chosen=None) -> bool: return self._chosen(self.backup_dir_var, chosen)
    def action_browse_release(self, chosen=None) -> bool: return self._chosen(self.release_var, chosen)
    def action_browse_backup(self, chosen=None) -> bool: return self._chosen(self.backup_path_var, chosen)
    def action_browse_stock_work(self, chosen=None) -> bool: return self._chosen(self.stock_work_var, chosen)
    def action_browse_stock_dir(self, chosen=None) -> bool: return self._chosen(self.stock_dir_var, chosen)
    def action_browse_stock_journal(self, chosen=None) -> bool: return self._chosen(self.stock_journal_var, chosen)
    def action_browse_fbt(self, chosen=None) -> bool: return self._chosen(self.fbt_var, chosen)
    def action_browse_animation_output(self, chosen=None) -> bool: return self._chosen(self.animation_output_var, chosen)
    def action_browse_computer_dir(self, chosen=None) -> bool: return self._chosen(self.computer_dir_var, chosen)
    def action_choose_sources(self, chosen=()) -> bool:
        if not chosen:
            return False
        self.install_sources.extend(Path(item) for item in chosen)
        self._show_sources()
        return True
    def action_choose_source_folder(self, chosen=None) -> bool:
        if chosen is None:
            return False
        self.install_sources.append(Path(chosen))
        self._show_sources()
        return True
    def _show_sources(self) -> None:
        self.sources_var.set("; ".join(str(item) for item in self.install_sources))

    def _required(self, variable: Value, label: str) -> Path:
        value = str(variable.get()).strip()
        if not value:
            raise CompanionError(f"Choose {label} first.")
        return Path(value).expanduser()
    def _sd(self) -> Path: return self._required(self.sd_var, "the explicit Flipper SD folder")
    def _serial(self) -> str | None: return str(self.serial_var.get()).strip() or None
    def _backup_dir(self) -> Path: return self._required(self.backup_dir_var, "a computer backup destination")
    def _release(self) -> Path: return self._required(self.release_var, "the cached release folder")
    def _store(self) -> ObservableTimingStore:
        store = ObservableTimingStore(DEFAULT_TIMING, listener=lambda snapshot: self.events.put(("timing", snapshot)))
        self._timing_store = store
        return store

    def action_refresh_status(self) -> None:
        if self.demo:
            return
        self._run_async("Read device and drive status", lambda: self.backend.status(ROOT), self._render_status)

    def _render_status(self, status: dict[str, Any]) -> None:
        devices = status.get("flipper_usb") or []
        mounts = status.get("mounted_removable_candidates") or []
        self.status_summary_var.set(f"Companion {status.get('companion_version', COMPANION_VERSION)}  •  kit {status.get('kit_version', 'unknown')}  •  {status.get('host', 'unknown')}")
        self.usb_var.set("USB:\n" + "\n".join(f"• {item.get('product')} — {item.get('mode')}\n  {item.get('identity')}" for item in devices) if devices else "USB: no known/possible Flipper detected. Check the data cable and permissions; no connection is claimed.")
        self.mounts_var.set("Mounted removable candidates (ownership unverified):\n" + "\n".join(f"• {item.get('mount')} — {item.get('label')}, {item.get('size')}, {item.get('filesystem')}" for item in mounts) if mounts else "SD candidates: none detected. Insert and mount the card, then choose its folder explicitly.")
        self.tools_var.set("Tools: " + "  •  ".join(f"{name}: {status.get(name) or 'not found'}" for name in ("qflipper", "dfu_util", "age", "gpg", "ufbt")))

    def action_check_update(self) -> None:
        sd, serial = self._sd(), self._serial()
        self._run_async("Check RogueMaster Update (online)", lambda: self.backend.check_update(sd, self._store(), serial), self._render_update_check)

    def _render_update_check(self, result: dict[str, Any]) -> None:
        device, latest = result.get("device") or {}, result.get("latest_stable") or {}
        self.device_version_var.set(device.get("firmware_version") or "Unavailable — device DEV-INFO not read")
        self.device_build_var.set(device.get("firmware_build_date") or "Unavailable — device DEV-INFO not read")
        self.latest_version_var.set(latest.get("tag") or "Unavailable")
        self.latest_release_var.set(latest.get("release_date") or "Unavailable")
        self.update_assessment_var.set(result.get("assessment") or "No update claim is available.")

    def action_download_install(self) -> None:
        sd, work, backup, serial, conflict = self._sd(), self._required(self.work_var, "a release download/work folder"), self._backup_dir(), self._serial(), self.conflict_var.get()
        def operation():
            return self.backend.download_install(work_dir=work, sd=sd, backup_dir=backup, timing_store=self._store(), serial_port=serial,
                opener=CancelAwareOpener(self.cancel), resource_conflict=conflict, root=ROOT,
                reporter=self._worker_report, input_function=self._worker_confirm)
        def done(result):
            self.release_var.set(str(result.get("release_dir") or ""))
            self.operation_var.set("qFlipper opened — choose Install from file, then return to verify")
        self._run_async("Download and Install Latest RogueMaster (online)", operation, done)

    def action_verify_update(self) -> None:
        release, sd, serial = self._release(), self._sd(), self._serial()
        self._run_async("Verify firmware and every SD resource", lambda: self.backend.verify_update(
            release_dir=release, sd=sd, timing_store=self._store(), serial_port=serial, reporter=self._worker_report))

    def action_create_backup(self) -> None:
        sd, destination, encrypted = self._sd(), self._backup_dir(), self.encrypted_var.get()
        def operation():
            if encrypted:
                return self.backend.create_encrypted_backup(sd, destination, staging_root=DEFAULT_STAGING, root=ROOT,
                    reporter=self._worker_report, passphrase_reader=self._worker_secret)
            return self.backend.create_backup(sd, destination, root=ROOT, reporter=self._worker_report)
        self._run_async("Create and verify encrypted full backup" if encrypted else "Create and verify full backup", operation)

    def action_verify_backup(self) -> None:
        backup = self._required(self.backup_path_var, "a backup folder")
        self._run_async("Verify every backup payload hash", lambda: self.backend.verify_backup(backup))

    def action_restore_backup(self) -> None:
        backup, sd, safety = self._required(self.backup_path_var, "a backup folder or encrypted file"), self._sd(), self._backup_dir()
        if backup.suffix.lower() in {".age", ".gpg", ".pgp"}:
            operation = lambda: self.backend.restore_encrypted_backup(backup, sd, safety_backup=safety, staging_root=DEFAULT_STAGING, root=ROOT,
                reporter=self._worker_report, passphrase_reader=self._worker_secret, input_function=self._worker_confirm)
        else:
            operation = lambda: self.backend.restore_backup(backup, sd, safety_backup=safety, root=ROOT,
                reporter=self._worker_report, input_function=self._worker_confirm)
        self._run_async("Review and restore verified backup", operation)

    def action_download_stock(self) -> None:
        work, version, serial = self._required(self.stock_work_var, "a stock work folder"), str(self.stock_version_var.get()).strip() or None, self._serial()
        def operation():
            device = self.backend.read_device_info(serial)
            return self.backend.prepare_stock(work_dir=work, device=device, version=version, opener=urlopen)
        self._run_async("Download and verify official stock resources (online)", operation, lambda result: self.stock_dir_var.set(str(result)))

    def action_preview_stock(self) -> None:
        stock = self._required(self.stock_dir_var, "a verified stock release folder")
        self._run_async("Preview genuine stock animations (offline)", lambda: self.backend.preview_animations(stock / "resources"), self._render_stock_previews)

    def _render_stock_previews(self, previews: list[dict[str, Any]]) -> None:
        self.stock_previews = previews
        self.selected_stock_names.set([])

    def action_restore_stock(self) -> None:
        stock, sd, backup = self._required(self.stock_dir_var, "a verified stock release folder"), self._sd(), self._backup_dir()
        selected = list(self.selected_stock_names.get())
        if not selected:
            raise CompanionError("Load the stock previews and select at least one animation.")
        serial = self._serial()
        def operation():
            device = self.backend.read_device_info(serial)
            return self.backend.restore_stock(stock, sd, device, animations=selected, backup_dir=backup, root=ROOT,
                reporter=self._worker_report, input_function=self._worker_confirm)
        self._run_async("Restore selected genuine stock animations", operation)

    def action_preview_custom(self) -> None:
        fbt = self._required(self.fbt_var, "the firmware/fbt source folder")
        self._run_async("Preview custom animation PNG assets", lambda: self.backend.preview_animations(fbt / "assets" / "dolphin" / "external"))

    def action_build_custom(self) -> None:
        fbt, output = self._required(self.fbt_var, "the firmware/fbt source folder"), self._required(self.animation_output_var, "a new custom animation output folder")
        self._run_async("Build custom animations with real fbt", lambda: self.backend.build_custom(fbt, output, reporter=self._worker_report))

    def _targets(self) -> list[tuple[str, Path]]:
        destination, targets = self.destination_var.get(), []
        if destination in {"sd", "both"}: targets.append(("sd", self._sd()))
        if destination in {"computer", "both"}: targets.append(("computer", self._required(self.computer_dir_var, "a computer mirror folder")))
        return targets

    def action_install_files(self) -> None:
        if not self.install_sources:
            raise CompanionError("Choose at least one FAP, BadUSB, data file, or folder.")
        sources, kind = list(self.install_sources), self.kind_var.get()
        app_folder, data_dest = str(self.app_folder_var.get()).strip() or None, str(self.data_dest_var.get()).strip() or None
        targets, safety = self._targets(), self._backup_dir()
        self._run_async("Review and install verified local files", lambda: self.backend.install(sources, kind=kind,
            destination=data_dest, app_folder=app_folder, targets=targets, safety_backup=safety, root=ROOT,
            reporter=self._worker_report, input_function=self._worker_confirm))

    def action_save_favourites(self) -> None:
        entries = [line.strip() for line in str(self.favourites_var.get()).splitlines() if line.strip()]
        if not entries:
            raise CompanionError("Enter at least one existing /any/... favourite path.")
        sd, backup = self._sd(), self._backup_dir()
        self._run_async("Back up and save favourites", lambda: self.backend.favourites(sd, entries, backup_dir=backup,
            root=ROOT, reporter=self._worker_report, input_function=self._worker_confirm))

    def action_organise_apps(self) -> None:
        assignments: dict[str, list[str]] = {}
        for line in str(self.apps_var.get()).splitlines():
            if not line.strip(): continue
            if "|" not in line:
                raise CompanionError("Use one 'Category | apps/source/app.fap' assignment per line.")
            category, source = (item.strip() for item in line.split("|", 1))
            assignments.setdefault(category, []).append(source)
        if not assignments:
            raise CompanionError("Enter at least one key-app assignment.")
        sd, backup = self._sd(), self._backup_dir()
        self._run_async("Back up and copy key apps", lambda: self.backend.key_apps(sd, assignments, backup_dir=backup,
            root=ROOT, reporter=self._worker_report, input_function=self._worker_confirm))

    def action_resume_update(self) -> None:
        release, sd, backup, conflict = self._release(), self._sd(), self._backup_dir(), self.conflict_var.get()
        self._run_async("Resume cached RogueMaster update (offline)", lambda: self.backend.resume_update(release, sd,
            resource_conflict=conflict, backup_dir=backup, root=ROOT, reporter=self._worker_report, input_function=self._worker_confirm))

    def action_rollback_update(self) -> None:
        release, sd, safety = self._release(), self._sd(), self._backup_dir()
        self._run_async("Roll back SD from verified original backup", lambda: self.backend.rollback_release(release, sd,
            safety_backup=safety, root=ROOT, reporter=self._worker_report, input_function=self._worker_confirm))

    def action_rollback_stock(self) -> None:
        journal, sd, safety = self._required(self.stock_journal_var, "a stock rollback journal"), self._sd(), self._backup_dir()
        self._run_async("Roll back selected stock animations", lambda: self.backend.rollback_stock(journal, sd,
            safety_backup=safety, root=ROOT, reporter=self._worker_report, input_function=self._worker_confirm))

    def action_qflipper(self) -> None:
        scale, flatpak = float(self.scale_var.get()), self.flatpak_var.get()
        self._run_async("Launch official qFlipper larger", lambda: self.backend.qflipper(scale=scale,
            use_flatpak=flatpak, reporter=self._worker_report, input_function=self._worker_confirm))

    def action_open_sd(self) -> None:
        sd = self._sd()
        self._run_async("Open selected SD in desktop file manager", lambda: self.backend.open_sd(sd, reporter=self._worker_report))

    def action_dfu_check(self) -> None:
        self._run_async("Read-only DFU inspection", lambda: self.backend.dfu_check(reporter=self._worker_report, input_function=self._worker_confirm))

    def action_clear_activity(self) -> None:
        self.log_lines = []
        self.activity_version += 1

    def _run_async(self, name: str, function: Callable[[], Any], on_success: Callable[[Any], None] | None = None) -> None:
        if self.busy:
            raise CompanionError("Another operation is still running. Wait for it to stop before starting another.")
        self.busy = True
        self.cancel.clear()
        self.close_requested = False
        self._timing_store = None
        self._last_timing = None
        with self._review_lock:
            self._review_lines = []
        self.operation_var.set(name)
        self.progress_var.set("Working — no percentage is claimed until the backend reports measured progress")
        self.eta_var.set("")
        self.progress_mode, self.progress_value = "indeterminate", 0.0
        self._log(f"Started: {name}")
        def work() -> None:
            try:
                result = function()
            except CompanionError as exc:
                self.events.put(("error", str(exc)))
            except Exception as exc:
                # Unexpected backend/tool output may contain sensitive material.
                self.events.put(("error", f"Unexpected {type(exc).__name__}. No completion is claimed; review the backend state safely."))
            else:
                self.events.put(("done", result, on_success))
        self.current_thread = threading.Thread(target=work, name="flipper-companion-operation", daemon=True)
        self.current_thread.start()

    def _worker_report(self, message: str) -> None:
        if self.cancel.is_set():
            raise CompanionError("Cancellation requested; stopped at the next safe backend boundary.")
        with self._review_lock:
            self._review_lines.append(str(message))
        self.events.put(("log", str(message)))

    def _worker_confirm(self, prompt: str) -> str:
        with self._review_lock:
            review = "\n".join(self._review_lines[-120:])
        request = WorkerRequest("confirm", prompt, review)
        self.current_request = request
        self.events.put(("request", request))
        request.event.wait()
        if self.cancel.is_set() or request.response is not True:
            return "Cancelled"
        return "Confirm"

    def _worker_secret(self, prompt: str) -> str:
        request = WorkerRequest("secret", prompt)
        self.current_request = request
        self.events.put(("request", request))
        request.event.wait()
        if self.cancel.is_set():
            request.response = ""
            return ""
        answer = str(request.response or "")
        request.response = ""
        return answer

    def process_events(self) -> list[tuple[str, Any]]:
        answer = []
        if not self._alive:
            return answer
        while True:
            try:
                event = self.events.get_nowait()
            except queue.Empty:
                break
            kind = event[0]
            if kind == "log":
                self._log(event[1])
            elif kind == "timing":
                self._last_timing = event[1]
                self._render_timing(event[1])
            elif kind == "done":
                result, callback = event[1], event[2]
                self._log(json.dumps(_safe_result(result), indent=2, sort_keys=True, default=str))
                self._finish_operation("Finished — review the verified result")
                if callback is not None:
                    callback(result)
                answer.append(("done", result))
                if self.close_requested:
                    answer.append(("close", None))
            elif kind == "error":
                self._log(f"Stopped safely: {event[1]}")
                self._finish_operation("Stopped safely — no completion is claimed", error=event[1])
                answer.append(("error", event[1]))
                if self.close_requested:
                    answer.append(("close", None))
            else:
                answer.append((kind, event[1]))
        return answer

    def _finish_operation(self, message: str, *, error: str | None = None) -> None:
        self.busy = False
        self.operation_var.set(message)
        self.progress_mode = "determinate"
        if error:
            self.progress_var.set(error)
            self.eta_var.set("")
        elif self._last_timing is None:
            self.progress_value = 0.0
            self.progress_var.set("Backend operation finished; see Activity for its verified result")
        self.current_thread = None
        self.current_request = None

    def poll_timing(self) -> None:
        store = self._timing_store
        if store is None:
            return
        try:
            snapshot = store.snapshot()
            if snapshot is not None:
                self._last_timing = snapshot
                self._render_timing(snapshot)
        except CompanionError:
            pass

    def _render_timing(self, snapshot: dict[str, Any]) -> None:
        if snapshot.get("overall_percent") == 100:
            self.progress_mode, self.progress_value = "determinate", 100.0
            self.progress_var.set("Overall: 100% — firmware and every SD resource verified")
            self.eta_var.set("Verified update added to this computer/device timing history")
            return
        phases = snapshot.get("phases") or {}
        active_name = next((name for name, record in phases.items() if record.get("status") == "running"), None)
        if active_name is None:
            active_name = next((name for name in ("copy", "download") if phases.get(name, {}).get("status") == "external-unmeasured"), None)
        if active_name is None:
            return
        record = phases[active_name]
        percent = record.get("percent")
        if isinstance(percent, (int, float)) and not isinstance(percent, bool):
            self.progress_mode, self.progress_value = "determinate", float(percent)
            self.progress_var.set(f"{active_name.capitalize()}: {percent:.1f}% measured  •  overall remains unverified")
        else:
            self.progress_mode = "indeterminate"
            self.progress_var.set(f"{active_name.capitalize()}: in progress — measured byte/file percentage unavailable; overall unverified")
        eta = record.get("eta")
        if eta:
            low, high = _format_seconds(int(eta["low_seconds"])), _format_seconds(int(eta["high_seconds"]))
            self.eta_var.set(f"Estimated remaining: {low}–{high}  •  from {eta['sample_count']} previous verified update(s) on this computer/device")
        else:
            self.eta_var.set("ETA unavailable until matching successful history exists on this computer/device")

    def action_cancel(self) -> None:
        if not self.busy:
            return
        self.cancel.set()
        self.operation_var.set("Cancellation requested — waiting for a safe backend boundary")
        self.progress_var.set("Do not unplug the Flipper or SD card; already-copied files are not rolled back")
        request = self.current_request
        if request is not None:
            request.finish(False if request.kind == "confirm" else "")

    def request_close(self) -> bool:
        """Return True when the native window must remain open for safe cleanup."""
        if self.busy:
            self.close_requested = True
            self.action_cancel()
            self.operation_var.set("Closing after the current operation reaches a safe boundary…")
            return True
        self._alive = False
        return False

    def _log(self, message: str) -> None:
        self.log_lines.append(str(message).rstrip())
        self.activity_version += 1

    @property
    def activity_text(self) -> str:
        return "\n".join(self.log_lines) + ("\n" if self.log_lines else "")

    def _load_demo(self) -> None:
        self.sd_var.set("/media/matthew/FLIPPER")
        self.release_var.set(str(APP_DATA / "releases" / "RM0424-1200"))
        self.stock_dir_var.set(str(APP_DATA / "stock" / "1.0.1"))
        self.backup_path_var.set(str(Path.home() / "Documents" / "Flipper backups" / "flipper-20261105T120000Z"))
        self.favourites_var.set("/any/nfc/front-door.nfc\n/any/subghz/garage.sub")
        self.apps_var.set("USB | apps/USB/boot2flipper.fap")
        self._render_status({
            "companion_version": COMPANION_VERSION, "kit_version": "secure-linux-preview", "host": "Linux",
            "flipper_usb": [{"product": "Flipper Zero", "mode": "USB serial", "identity": "Flipper USB identification strings matched."}],
            "mounted_removable_candidates": [{"mount": "/media/matthew/FLIPPER", "label": "FLIPPER", "size": "32G", "filesystem": "vfat"}],
            "qflipper": "/usr/bin/qflipper", "dfu_util": "/usr/bin/dfu-util", "age": "/usr/bin/age", "gpg": "/usr/bin/gpg", "ufbt": None,
        })
        self._render_update_check({
            "device": {"firmware_version": "RM0424-1200", "firmware_build_date": "24-04-2026"},
            "latest_stable": {"tag": "RM0424-1200", "release_date": "2026-04-24T12:00:00Z"},
            "assessment": "The device-reported firmware version exactly matches the latest stable tag.",
        })
        self._render_stock_previews([{"name": "L1_Flipper", "frame_count": 8, "visual_preview_status": "matching source PNG frames"}])
        self._log("Preview only: no device, network, or filesystem operation has been run.")
