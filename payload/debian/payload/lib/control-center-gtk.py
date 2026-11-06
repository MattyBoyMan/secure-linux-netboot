#!/usr/bin/env python3
"""GTK4/Libadwaita view for control-center.py; no direct system mutations."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent

def load_ui():
    spec = importlib.util.spec_from_file_location("secure_linux_ui_gtk", HERE / "secure-ui-gtk.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


ui = load_ui()
Gtk = ui.Gtk
GLib = ui.GLib


class ControlCenterWindow(ui.SecureShell):
    def __init__(self, application, controller, model):
        super().__init__(application, "Secure Linux Control Centre", "Clear choices. Every change is checked.", demo=controller.demo)
        self.controller = controller
        self.model = model
        self._syncing = False
        self.switches = {}
        self.state_labels = {}
        self.preset_buttons = {}
        self.feature_rows = {}
        self._build_protection()
        self._build_status()
        self._build_tools()
        self.navigate("protection")
        self._sync_all()
        self.connect("close-request", self._close_request)
        GLib.timeout_add(100, self._tick)

    def _build_protection(self):
        page = ui.page_box()
        ui.add_heading(page, "Protection, without surprises", "Safe steps are preselected. Adjust anything, then review every change before it happens.")
        page.append(ui.label("Choose your protection level", css=("sl-section-title",)))
        presets = ui.responsive_row(spacing=12, homogeneous=True)
        preset_info = [
            ("recommended", "Recommended", "Everyday protection. VPN and USB rules stay unchanged."),
            ("stricter", "Stricter", "Also connects your configured VPN and enables the audit log."),
            ("custom", "Custom", "Keep current choices and adjust individual switches."),
        ]
        group = None
        for key, title, detail in preset_info:
            card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
            card.add_css_class("sl-status-card")
            radio = Gtk.CheckButton(label=title)
            radio.set_size_request(-1, ui.design.MIN_TARGET_PX)
            if group:
                radio.set_group(group)
            group = radio
            ui.accessible(radio, title, detail)
            radio.connect("toggled", lambda widget, selected=key: self._preset_toggled(widget, selected))
            card.append(radio)
            card.append(ui.label(detail, css=("sl-caption",)))
            presets.append(card)
            self.preset_buttons[key] = radio
        page.append(presets)
        page.append(ui.label("Protection switches", css=("sl-section-title",)))
        for key in self.model.FEATURE_ORDER[:10]:
            page.append(self._feature_row(key))
        self.activity_label = ui.label(self.controller.activity.get(), css=("sl-caption",))
        page.append(self.activity_label)
        actions = ui.responsive_row(spacing=12)
        refresh = ui.button("Refresh (F5)", self.controller.refresh)
        self.review_button = ui.button("Review changes (Alt+R)", self._review, primary=True)
        actions.append(refresh)
        actions.append(self.review_button)
        page.append(actions)
        page.append(ui.label("Nothing changes when you move a switch. The Confirm screen comes next. There is no countdown.", css=("sl-caption",)))
        self.add_page("protection", "Protection", "security-high-symbolic", page)

    def _feature_row(self, key):
        info = self.model.FEATURES[key]
        row = ui.responsive_row(spacing=16)
        row.add_css_class("sl-status-card")
        copy = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, hexpand=True)
        copy.append(ui.label(info["title"], css=("sl-card-title",)))
        copy.append(ui.label(info["summary"], css=("sl-body", "sl-muted")))
        copy.append(ui.label(info["why"], css=("sl-caption",)))
        row.append(copy)
        state = ui.status_pill()
        row.append(state)
        self.state_labels[key] = state
        switch = Gtk.Switch()
        switch.set_size_request(52, ui.design.MIN_TARGET_PX)
        switch.set_valign(Gtk.Align.CENTER)
        ui.accessible(switch, f"{info['title']} enabled", info["summary"])
        switch.connect("notify::active", lambda widget, _param, selected=key: self._switch_changed(widget, selected))
        row.append(switch)
        self.switches[key] = switch
        self.feature_rows[key] = row
        return row

    def _build_status(self):
        page = ui.page_box()
        ui.add_heading(page, "Hardware, encryption & app access", "These items need care. The centre explains what is possible instead of offering unsafe one-click promises.")
        grid = ui.flow_box()
        for key in self.model.FEATURE_ORDER[10:]:
            info = self.model.FEATURES[key]
            card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
            card.add_css_class("sl-status-card")
            header = ui.responsive_row(spacing=12)
            title = ui.label(info["title"], css=("sl-card-title",))
            title.set_hexpand(True)
            header.append(title)
            state = ui.status_pill()
            header.append(state)
            self.state_labels[key] = state
            card.append(header)
            card.append(ui.label(info["summary"], css=("sl-body", "sl-muted")))
            card.append(ui.label(info["why"], css=("sl-caption",)))
            if key == "flatpak_permissions":
                card.append(ui.button("Review permissions in Flatseal", lambda: self.controller.launch_tool("flatseal")))
            elif key == "docker_rootless":
                card.append(ui.button("Open rootless Docker setup", lambda: self.controller.launch_tool("home_server")))
            elif key == "disk_encryption":
                card.append(ui.button("Open disk recovery-key wizard", lambda: self.controller.launch_tool("recovery_key")))
            grid.append(card)
        page.append(grid)
        page.append(ui.label("Checks and specialist setup", css=("sl-section-title",)))
        actions = ui.flow_box()
        actions.append(ui.task_card("Run ClamAV scan now", "Run the existing scan. No files are deleted by this action.", "Start scan", self.controller.scan_now, icon="system-search-symbolic"))
        actions.append(ui.task_card("Secure Linux Status & Fixes", "Open the existing guided status and repair tool.", "Open Status & Fixes", lambda: self.controller.launch_tool("status"), icon="utilities-system-monitor-symbolic"))
        actions.append(ui.task_card("Set up VPN", "Use the existing beginner wizard and your current provider configuration.", "Open VPN setup", lambda: self.controller.launch_tool("vpn_setup"), icon="network-vpn-symbolic"))
        page.append(actions)
        page.append(ui.label("Low-level recovery intentionally opens a terminal. Physical disks are never selected or changed by this centre.", css=("sl-caption",)))
        recovery = ui.button("Open low-level recovery (terminal)", lambda: self.controller.launch_tool("recovery"))
        recovery.set_halign(Gtk.Align.START)
        page.append(recovery)
        self.add_page("status", "Status & Advanced", "drive-harddisk-symbolic", page)

    def _build_tools(self):
        page = ui.page_box()
        ui.add_heading(page, "Your beginner tools, in one place", "These buttons open existing Secure Linux tools. They keep their own safety checks and explanations.")
        tools = [
            ("backup", "Back up my files", "Choose a USB drive or home-server backup.", "document-save-symbolic"),
            ("finish", "Finish setting up", "Return to the friendly finishing checklist.", "view-list-symbolic"),
            ("apps", "Install or finish apps", "Choose the apps you want to keep.", "system-software-install-symbolic"),
            ("flipper", "Flipper Zero Backup & Files", "Open the existing graphical Flipper companion.", "drive-removable-media-symbolic"),
            ("usb_creator", "Create a Secure Linux USB", "Use the existing USB creator and its checks.", "drive-removable-media-symbolic"),
            ("usb_fixer", "Fix a USB drive", "Open the existing guided USB fixer.", "drive-harddisk-symbolic"),
            ("home_server", "Home & Server Helper", "Photos, files, containers and rootless Docker.", "network-server-symbolic"),
            ("guide", "Read the START-HERE guide", "Open the offline beginner guide.", "help-browser-symbolic"),
        ]
        grid = ui.flow_box()
        for key, title, detail, icon in tools:
            grid.append(ui.task_card(title, detail, "Open tool", lambda selected=key: self.controller.launch_tool(selected), icon=icon))
        page.append(grid)
        self.add_page("tools", "Beginner Tools", "applications-system-symbolic", page)

    def _preset_toggled(self, widget, key):
        if self._syncing or not widget.get_active():
            return
        self.controller.preset.set(key)
        self.controller.preset_changed()
        self._sync_values()
        self._sync_activity()

    def _switch_changed(self, widget, key):
        if self._syncing:
            return
        self.controller.values[key].set(widget.get_active())
        warning = self.controller.manual_toggle(key)
        self._sync_preset()
        self._sync_activity()
        if warning:
            ui.message_dialog(self, "USB devices can be blocked", warning)

    def _sync_preset(self):
        for key, widget in self.preset_buttons.items():
            widget.set_active(key == self.controller.preset.get())

    def _sync_values(self):
        self._syncing = True
        try:
            for key, widget in self.switches.items():
                status = self.controller.statuses.get(key)
                widget.set_sensitive(bool(status and status.manageable and not self.controller.busy))
                widget.set_active(bool(self.controller.values[key].get()))
        finally:
            self._syncing = False
        self._sync_preset()

    def _sync_statuses(self):
        for key, widget in self.state_labels.items():
            status = self.controller.statuses.get(key)
            if not status:
                continue
            if status.is_on or status.state == "available":
                text, style = ("ON" if status.is_on else "AVAILABLE"), "sl-status-on"
            elif status.state in {"off", "not-installed", "unavailable"}:
                text, style = ("OFF" if status.state == "off" else "NOT AVAILABLE"), "sl-status-off"
            else:
                text, style = status.state.upper(), "sl-status-info"
            widget.set_label(text)
            for name in ("sl-status-on", "sl-status-off", "sl-status-info"):
                widget.remove_css_class(name)
            widget.add_css_class(style)
            ui.accessible(widget, f"{self.model.FEATURES[key]['title']} current status: {text}")

    def _sync_activity(self):
        self.activity_label.set_label(self.controller.activity.get())
        self.review_button.set_sensitive(self.controller.review_enabled and not self.controller.busy)

    def _sync_all(self):
        self._sync_statuses()
        self._sync_values()
        self._sync_activity()

    def _review(self):
        try:
            plan = self.controller.review()
        except self.model.PlanError as exc:
            ui.message_dialog(self, "This change is not available", str(exc))
            return
        if plan is None:
            return
        if not plan:
            ui.message_dialog(self, "Nothing to change", self.model.review_text(plan))
            return
        ui.review_dialog(self, self.model.review_text(plan), lambda: self._start_apply(plan))

    def _start_apply(self, plan):
        self.controller.start_apply(plan)
        self._sync_all()

    def _tick(self):
        events = self.controller.process_events()
        for kind, payload, error in events:
            if kind == "status" and error:
                ui.message_dialog(self, "Could not check this computer", error)
            elif kind == "applied":
                if error:
                    ui.message_dialog(self, "The apply step failed", error + "\n\nRefresh before trying again.")
                else:
                    ui.message_dialog(self, "Setting results", self.controller.report_text(payload))
            elif kind == "scan":
                title = "ClamAV scan" if payload.get("ok") else "ClamAV scan did not finish"
                ui.message_dialog(self, title, payload.get("detail", "No detail was supplied."))
        self._sync_all()
        return True

    def _key_pressed(self, controller, keyval, keycode, state):
        if keyval == ui.Gdk.KEY_F5:
            self.controller.refresh()
            self._sync_all()
            return True
        if keyval == ui.Gdk.KEY_r and state & ui.Gdk.ModifierType.ALT_MASK:
            self._review()
            return True
        return super()._key_pressed(controller, keyval, keycode, state)

    def _close_request(self, _window):
        if self.controller.busy:
            ui.message_dialog(self, "Please wait", "A system operation is still finishing. Keep this window open until its result appears.")
            return True
        return False


def ui_report_text(report):
    """Avoid importing the controller again; preserve the same report contract."""
    lines = [report.headline, ""]
    for result in report.results:
        mark = "VERIFIED" if result.ok and result.verified else "FAILED"
        lines.append(f"{mark} — {result.feature}")
        lines.append(f"  Wanted: {'on' if result.desired else 'off'}; found: {result.state}")
        lines.append(f"  {result.detail}")
        if result.rollback_attempted:
            lines.append(f"  Immediate rollback: {'succeeded' if result.rollback_ok else 'failed or incomplete'}")
    if report.rollback_results:
        lines.append("\nROLLBACK OF EARLIER CHANGES")
        for result in report.rollback_results:
            mark = "RESTORED" if result.ok and result.verified else "ROLLBACK FAILED"
            lines.append(f"{mark} — {result.feature}: {result.detail}")
    lines.append("\nNo password or secret is included in this report.")
    return "\n".join(lines)
