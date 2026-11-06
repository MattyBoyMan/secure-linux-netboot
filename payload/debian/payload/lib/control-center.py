#!/usr/bin/env python3
"""Secure Linux Control Centre controller and native GTK application entry point.

The existing model and system adapter remain the only safety/apply authorities.
This module is importable without GTK for mocked regression tests.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
from typing import Dict, Optional

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
MODEL_PATH = HERE / "control-center-model.py"
spec = importlib.util.spec_from_file_location("secure_linux_control_center_model", MODEL_PATH)
model = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = model
spec.loader.exec_module(model)

APP_NAME = "Secure Linux Control Centre"
BACKEND = Path(os.environ.get("SL_CC_BACKEND", str(HERE / "control-center-backend.py")))
BIN = Path(os.environ.get("SL_CC_BIN", "/usr/local/bin"))


class SubprocessBackend:
    """The only bridge between the GUI model and the live system adapter."""
    def __init__(self, executable: Path = BACKEND):
        self.executable = executable

    def _call(self, *args: str) -> dict:
        try:
            result = subprocess.run(
                [sys.executable, str(self.executable), *args],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                errors="replace",
                check=False,
            )
        except OSError as exc:
            return {"ok": False, "verified": False, "detail": str(exc)}
        try:
            payload = json.loads(result.stdout)
        except (json.JSONDecodeError, TypeError):
            detail = (result.stderr or result.stdout or "The system helper returned no readable answer.").strip()
            if result.returncode in {1, 126, 127} and not detail:
                detail = "Administrator permission was cancelled or unavailable. Nothing was applied."
            return {"ok": False, "verified": False, "detail": detail[:3500]}
        if isinstance(payload, dict):
            return payload
        return {"ok": False, "verified": False, "detail": "The system helper returned an unexpected answer."}

    def statuses(self) -> Dict[str, model.FeatureStatus]:
        payload = self._call("status")
        if "features" not in payload:
            raise RuntimeError(payload.get("detail", "Could not read the computer's security status."))
        answer = {}
        for key in model.FEATURE_ORDER:
            raw = payload["features"].get(key, {})
            answer[key] = model.FeatureStatus(
                feature=key,
                state=str(raw.get("state", "unknown")),
                detail=str(raw.get("detail", "No detail supplied.")),
                supported=bool(raw.get("supported", False)),
                manageable=bool(raw.get("manageable", False)),
                can_disable=bool(raw.get("can_disable", False)),
                reversible=bool(raw.get("reversible", True)),
            )
        return answer

    def apply(self, change: model.PlannedChange) -> model.OperationResult:
        raw = self._call("apply", change.feature, "on" if change.desired else "off")
        return model.OperationResult(
            feature=change.feature,
            desired=change.desired,
            ok=bool(raw.get("ok", False)),
            verified=bool(raw.get("verified", False)),
            detail=str(raw.get("detail", "No result was supplied.")),
            state=str(raw.get("state", "unknown")),
            rollback_supported=bool(raw.get("rollback_supported", change.reversible)),
            rollback_attempted=bool(raw.get("rollback_attempted", False)),
            rollback_ok=raw.get("rollback_ok"),
        )

    def scan_now(self) -> dict:
        return self._call("scan-now")


class Value:
    """Small observable-value analogue used by the headless controller tests."""
    def __init__(self, value):
        self.value = value
    def get(self):
        return self.value
    def set(self, value):
        self.value = value


class ControlCenterController:
    def __init__(self, backend=None, demo: bool = False, on_message=None):
        self.backend = backend or SubprocessBackend()
        self.demo = demo
        self.on_message = on_message
        self.statuses: Dict[str, model.FeatureStatus] = {}
        self.values: Dict[str, Value] = {key: Value(False) for key in model.FEATURE_ORDER[:10]}
        self.preset = Value("recommended")
        self.setting_preset = False
        self.busy = False
        self.review_enabled = False
        self.events: queue.Queue = queue.Queue()
        self.last_report: Optional[model.ApplyReport] = None
        self.activity = Value("Preview data only. No live settings were read or changed." if demo else "Checking your computer…")
        if demo:
            self._load_demo()
        else:
            self.refresh()

    def message(self, title: str, text: str) -> None:
        if self.on_message:
            self.on_message(title, text)

    def _load_demo(self):
        states = {
            "firewall": ("on", True, True), "opensnitch": ("on", True, True), "dns": ("encrypted", True, True),
            "vpn": ("off", True, True), "updates": ("on", True, True), "clamav": ("on", True, True),
            "usbguard": ("off", True, True), "fail2ban": ("on", True, True), "screen_lock": ("off", True, True),
            "auditd": ("off", True, True), "secure_boot": ("on", True, False), "disk_encryption": ("on", True, False),
            "flatpak_permissions": ("available", True, False), "docker_rootless": ("off", True, False),
        }
        self.statuses = {
            key: model.FeatureStatus(key, state=value[0], detail=model.FEATURES[key]["summary"], supported=value[1],
                                     manageable=value[2], can_disable=key not in {"auditd", "secure_boot", "disk_encryption"},
                                     reversible=key not in {"secure_boot", "disk_encryption"})
            for key, value in states.items()
        }
        self._show_statuses()
        self.review_enabled = False
        self.activity.set("Preview data only. No live settings were read or changed.")

    def _show_statuses(self):
        self.setting_preset = True
        try:
            values = model.preset_values(self.preset.get(), self.statuses)
            for key, value in values.items():
                if key in self.values:
                    self.values[key].set(bool(value))
        finally:
            self.setting_preset = False
        self.busy = False
        self.review_enabled = bool(self.statuses) and not self.demo
        self._update_activity()

    def preset_changed(self):
        if self.setting_preset or not self.statuses:
            return
        values = model.preset_values(self.preset.get(), self.statuses)
        self.setting_preset = True
        try:
            for key, value in values.items():
                if key in self.values:
                    self.values[key].set(bool(value))
        finally:
            self.setting_preset = False
        self._update_activity()

    def manual_toggle(self, key: str) -> str | None:
        if self.setting_preset:
            return None
        self.preset.set("custom")
        self._update_activity()
        if key == "usbguard" and self.values[key].get():
            return (
                "USBGuard uses the policy already on this computer. A wrong policy can block a keyboard, mouse or USB storage.\n\n"
                "It is never preselected. Review this change carefully and keep another way to sign in."
            )
        return None

    def _update_activity(self):
        if self.busy or not self.statuses:
            return
        try:
            desired = {k: v.get() for k, v in self.values.items() if self.statuses[k].manageable}
            count = len(model.build_plan(self.statuses, desired))
        except model.PlanError:
            count = 0
        self.activity.set(f"{count} change(s) ready to review. Nothing has been applied.")

    def refresh(self):
        if self.busy or self.demo:
            return
        self.busy = True
        self.review_enabled = False
        self.activity.set("Checking current settings… You can keep this window open.")
        threading.Thread(target=self._refresh_worker, daemon=True).start()

    def _refresh_worker(self):
        try:
            self.events.put(("status", self.backend.statuses(), None))
        except Exception as exc:
            self.events.put(("status", None, str(exc)))

    def review(self):
        if self.busy or self.demo or not self.statuses:
            return None
        desired = {key: var.get() for key, var in self.values.items() if self.statuses[key].manageable}
        return model.build_plan(self.statuses, desired)

    def start_apply(self, plan):
        self.busy = True
        self.review_enabled = False
        self.activity.set(f"Applying and checking {len(plan)} change(s)… Please wait.")
        threading.Thread(target=self._apply_worker, args=(plan,), daemon=True).start()

    def _apply_worker(self, plan):
        try:
            self.events.put(("applied", model.apply_with_rollback(self.backend, plan), None))
        except Exception as exc:
            self.events.put(("applied", None, str(exc)))

    def process_events(self):
        """Drain worker events. Native views decide how to present each result."""
        events = []
        while True:
            try:
                kind, payload, error = self.events.get_nowait()
            except queue.Empty:
                break
            self.busy = False
            if kind == "status":
                if error:
                    self.review_enabled = False
                    self.activity.set("Status check failed. No changes were made.")
                else:
                    self._show_statuses()
            elif kind == "applied":
                if error:
                    self.activity.set("Apply failed unexpectedly. Refresh to check the current state.")
                else:
                    self.last_report = payload
                    self.refresh()
            elif kind == "scan":
                self.activity.set(payload.get("detail", "Scan finished."))
                self.review_enabled = bool(self.statuses) and not self.demo
            events.append((kind, payload, error))
        return events

    def scan_now(self):
        if self.busy or self.demo:
            return
        self.busy = True
        self.review_enabled = False
        self.activity.set("Running the existing ClamAV scan… This can take a while; no files are deleted.")
        def worker():
            self.events.put(("scan", self.backend.scan_now(), None))
        threading.Thread(target=worker, daemon=True).start()

    def _helper(self, name: str) -> Optional[str]:
        installed = BIN / name
        if installed.is_file() and os.access(installed, os.X_OK):
            return str(installed)
        local = ROOT / "bin" / name
        if local.is_file() and os.access(local, os.X_OK):
            return str(local)
        from shutil import which
        return which(name)

    def launch_tool(self, key: str):
        if self.demo:
            self.message("Preview", f"This would open: {key}. No tool was launched.")
            return
        mapping = {
            "backup": ("secure-linux-welcome", ["--page", "backup"]),
            "finish": ("secure-linux-finish", ["--gui"]),
            "apps": ("secure-linux-finish", ["--gui", "apps"]),
            "flipper": ("secure-linux-flipper", []),
            "usb_creator": ("secure-linux-usb-creator-gui", []),
            "usb_fixer": ("secure-linux-usb-fixer-gui", []),
            "home_server": ("secure-linux-home-server-gui", []),
            "guide": ("secure-linux-guide", []),
            "status": ("secure-linux-status-gui", []),
            "vpn_setup": ("secure-linux-welcome", ["--page", "vpn"]),
            "recovery_key": ("secure-linux-welcome", ["--page", "recovery"]),
            "flatseal": ("flatseal", []),
            "recovery": ("secure-linux-terminal", ["secure-linux-repair"]),
        }
        if key not in mapping:
            return
        name, args = mapping[key]
        executable = self._helper(name)
        if key == "flatseal" and not executable and self._helper("flatpak"):
            executable, args = self._helper("flatpak"), ["run", "com.github.tchx84.Flatseal"]
        if key == "guide" and not executable:
            guide = Path("/usr/share/secure-linux/START-HERE.html")
            opener = self._helper("xdg-open")
            executable, args = (opener, [str(guide)]) if opener and guide.exists() else (None, [])
        if not executable:
            self.message("This tool is not installed", f"Could not find {name}. No other program was substituted.")
            return
        try:
            subprocess.Popen([executable, *args], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
            self.activity.set(f"Opened {name}. This window stays available.")
        except OSError as exc:
            self.message("Could not open the tool", str(exc))


ControlCenterApp = ControlCenterController


def report_text(report: model.ApplyReport) -> str:
    lines = [report.headline, ""]
    for result in report.results:
        mark = "VERIFIED" if result.ok and result.verified else "FAILED"
        lines.append(f"{mark} — {model.FEATURES[result.feature]['title']}")
        lines.append(f"  Wanted: {'on' if result.desired else 'off'}; found: {result.state}")
        lines.append(f"  {result.detail}")
        if result.rollback_attempted:
            lines.append(f"  Immediate rollback: {'succeeded' if result.rollback_ok else 'failed or incomplete'}")
    if report.rollback_results:
        lines.append("\nROLLBACK OF EARLIER CHANGES")
        for result in report.rollback_results:
            mark = "RESTORED" if result.ok and result.verified else "ROLLBACK FAILED"
            lines.append(f"{mark} — {model.FEATURES[result.feature]['title']}: {result.detail}")
    lines.append("\nNo password or secret is included in this report.")
    return "\n".join(lines)


def load_native_module():
    path = HERE / "control-center-gtk.py"
    native_spec = importlib.util.spec_from_file_location("secure_linux_control_center_gtk", path)
    native = importlib.util.module_from_spec(native_spec)
    sys.modules[native_spec.name] = native
    assert native_spec.loader is not None
    native_spec.loader.exec_module(native)
    return native


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=APP_NAME)
    parser.add_argument("--demo", action="store_true", help="show read-only example data; never read or change the live system")
    args = parser.parse_args(argv)
    controller_box = {}
    def message(title, text):
        window = controller_box.get("window")
        if window:
            controller_box["native"].ui.message_dialog(window, title, text)
    try:
        native = load_native_module()
    except (ImportError, ValueError) as exc:
        design_spec = importlib.util.spec_from_file_location("secure_linux_ui_error", HERE / "secure-ui.py")
        design = importlib.util.module_from_spec(design_spec)
        assert design_spec.loader is not None
        design_spec.loader.exec_module(design)
        print(f"{design.gtk_dependency_error()}\n{exc}", file=sys.stderr)
        return 1
    controller = ControlCenterController(demo=args.demo, on_message=message)
    controller.report_text = report_text
    controller_box["native"] = native
    def build(application):
        window = native.ControlCenterWindow(application, controller, model)
        controller_box["window"] = window
        return window
    return native.ui.run_application("org.securelinux.ControlCentre", build, [sys.argv[0]])


if __name__ == "__main__":
    raise SystemExit(main())
