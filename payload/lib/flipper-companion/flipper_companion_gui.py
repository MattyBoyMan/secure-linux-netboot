#!/usr/bin/env python3
"""Native GTK4/Libadwaita view for the full Flipper Zero companion.

The headless controller owns operation state and explicit worker prompts. The
existing backend modules remain the only device and filesystem safety authority.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path
import sys

from flipper_companion_controller import APP_NAME, BUTTON_ACTIONS, COMPANION_VERSION, CompanionError, FlipperController

HERE = Path(__file__).resolve().parent
UI_PATH = HERE.parent / "secure-ui-gtk.py"


def load_ui():
    spec = importlib.util.spec_from_file_location("secure_linux_ui_gtk", UI_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


ui = load_ui()
Gtk = ui.Gtk
GLib = ui.GLib


CHOOSERS = {
    "browse_sd": ("action_browse_sd", "Choose the mounted Flipper SD folder", "folder"),
    "browse_work": ("action_browse_work", "Choose RogueMaster release work folder", "folder"),
    "browse_backup_dir": ("action_browse_backup_dir", "Choose computer backup destination", "folder"),
    "browse_backup_dir_2": ("action_browse_backup_dir", "Choose computer backup destination", "folder"),
    "browse_release": ("action_browse_release", "Choose cached RogueMaster release folder", "folder"),
    "browse_release_2": ("action_browse_release", "Choose cached RogueMaster release folder", "folder"),
    "browse_stock_work": ("action_browse_stock_work", "Choose official stock work folder", "folder"),
    "browse_stock_dir": ("action_browse_stock_dir", "Choose verified stock release folder", "folder"),
    "browse_stock_journal": ("action_browse_stock_journal", "Choose stock rollback journal", "file"),
    "browse_fbt": ("action_browse_fbt", "Choose firmware source folder containing fbt", "folder"),
    "browse_animation_output": ("action_browse_animation_output", "Choose new custom animation output folder", "folder"),
    "browse_computer_dir": ("action_browse_computer_dir", "Choose computer SD mirror folder", "folder"),
    "choose_sources": ("action_choose_sources", "Choose reviewed FAP, BadUSB, or data files", "files"),
    "choose_source_folder": ("action_choose_source_folder", "Choose reviewed source folder", "folder"),
}


class ReviewDialog:
    """Explicit, timeless operation review; dismissal always means Cancel."""
    def __init__(self, window, request) -> None:
        self.request = request
        self.dialog = ui.Adw.Dialog(title="Review before continuing")
        self.dialog.set_content_width(720)
        self.dialog.set_content_height(640)
        toolbar = ui.Adw.ToolbarView()
        header = ui.Adw.HeaderBar()
        header.set_title_widget(ui.Adw.WindowTitle(title="Review exactly what will happen", subtitle="Nothing has been applied"))
        toolbar.add_top_bar(header)
        page = ui.page_box()
        for margin in (24,):
            page.set_margin_top(margin)
            page.set_margin_bottom(margin)
            page.set_margin_start(margin)
            page.set_margin_end(margin)
        page.append(ui.label(request.prompt, css=("sl-card-title",)))
        scroll = Gtk.ScrolledWindow(hexpand=True, vexpand=True)
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        text = Gtk.TextView(editable=False, cursor_visible=False, wrap_mode=Gtk.WrapMode.WORD)
        text.get_buffer().set_text(request.review or "The backend supplied no additional review detail.")
        text.add_css_class("sl-review-text")
        ui.accessible(text, "Operation review", request.review[:240])
        scroll.set_child(text)
        page.append(scroll)
        page.append(ui.label("Nothing continues until you choose Confirm. There is no countdown.", css=("sl-caption",)))
        actions = ui.dialog_row(self.dialog, homogeneous=True)
        actions.add_css_class("sl-dialog-actions")
        cancel = ui.button("Cancel — change nothing", self.cancel)
        confirm = ui.button("Confirm", self.accept, primary=True)
        actions.append(cancel)
        actions.append(confirm)
        page.append(actions)
        toolbar.set_content(page)
        self.dialog.set_child(toolbar)
        self.dialog.connect("closed", self._closed)
        self.dialog.present(window)
        cancel.grab_focus()

    def accept(self) -> None:
        self.request.finish(True)
        self.dialog.close()
    def cancel(self) -> None:
        self.request.finish(False)
        self.dialog.close()
    def _closed(self, _dialog) -> None:
        self.request.finish(False)


class PassphraseDialog:
    """Masked secret input; clear the native buffer on every exit path."""
    def __init__(self, window, request) -> None:
        self.request = request
        self.dialog = ui.Adw.Dialog(title="Private backup passphrase")
        self.dialog.set_content_width(520)
        self.dialog.set_content_height(360)
        page = ui.page_box()
        for margin in (24,):
            page.set_margin_top(margin)
            page.set_margin_bottom(margin)
            page.set_margin_start(margin)
            page.set_margin_end(margin)
        page.append(ui.label(request.prompt.replace(" (not shown): ", ""), css=("sl-section-title",)))
        page.append(ui.label("Passphrases are hidden and are never written to the activity log.", css=("sl-body", "sl-muted")))
        self.entry = Gtk.PasswordEntry()
        self.entry.set_show_peek_icon(False)
        self.entry.set_size_request(-1, ui.design.MIN_TARGET_PX)
        ui.accessible(self.entry, "Passphrase, hidden", "Secret input; never logged or displayed")
        self.entry.connect("activate", lambda _entry: self.accept())
        page.append(self.entry)
        actions = ui.dialog_row(self.dialog, homogeneous=True)
        cancel = ui.button("Cancel", self.cancel)
        accept = ui.button("Use passphrase", self.accept, primary=True)
        actions.append(cancel)
        actions.append(accept)
        page.append(actions)
        self.dialog.set_child(page)
        self.dialog.connect("closed", self._closed)
        self.dialog.present(window)
        self.entry.grab_focus()

    def accept(self) -> None:
        value = self.entry.get_text()
        self.entry.set_text("")
        self.request.finish(value)
        self.dialog.close()
    def cancel(self) -> None:
        self.entry.set_text("")
        self.request.finish("")
        self.dialog.close()
    def _closed(self, _dialog) -> None:
        self.entry.set_text("")
        self.request.finish("")


class FlipperWindow(ui.SecureShell):
    def __init__(self, application, controller: FlipperController) -> None:
        super().__init__(application, APP_NAME, f"Secure Linux companion {COMPANION_VERSION} · clear reviews, verified copies", demo=controller.demo)
        self.controller = controller
        self.buttons = {}
        self.entries = {}
        self.value_labels = {}
        self.dropdowns = {}
        self.toggles = {}
        self.text_values = {}
        self._syncing = False
        self._activity_version = -1
        self._stock_signature = None
        self.stock_options = []
        self.active_dialog = None
        self._build_status()
        self._build_backup()
        self._build_personalise()
        self._build_tools()
        self._build_progress()
        self.navigate("status")
        self._sync_all()
        self.connect("close-request", self._close_request)
        GLib.timeout_add(100, self._tick)

    def _heading(self, title, subtitle):
        page = ui.page_box()
        ui.add_heading(page, title, subtitle)
        return page

    def _card(self, parent, title, description="", *, online=False):
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        card.add_css_class("sl-status-card")
        top = ui.responsive_row(spacing=12)
        heading = ui.label(title, css=("sl-card-title",))
        heading.set_hexpand(True)
        top.append(heading)
        top.append(ui.status_pill("INTERNET REQUIRED" if online else "WORKS OFFLINE", "info"))
        card.append(top)
        if description:
            card.append(ui.label(description, css=("sl-body", "sl-muted")))
        parent.append(card)
        return card

    def _button(self, parent, key, text, *, primary=False):
        callback = (lambda: self._choose(key)) if key in CHOOSERS or key == "browse_backup" else (lambda: self._guard(key))
        button = ui.button(text, callback, primary=primary, name=text)
        self.buttons[key] = button
        parent.append(button)
        return button

    def _button_row(self, parent):
        row = ui.flow_box()
        row.set_max_children_per_line(2)
        parent.append(row)
        return row

    def _entry(self, parent, label, variable, name=None):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, hexpand=True)
        box.append(ui.label(label, css=("sl-caption",)))
        entry = Gtk.Entry(hexpand=True)
        entry.set_width_chars(1)
        entry.set_size_request(-1, ui.design.MIN_TARGET_PX)
        entry.set_text(str(variable.get()))
        ui.accessible(entry, name or label, "Type a value; available chooser buttons never guess a device")
        entry.connect("changed", lambda widget: self._entry_changed(widget, variable))
        box.append(entry)
        parent.append(box)
        self.entries[id(variable)] = entry
        return entry

    def _path_row(self, parent, label, variable, key):
        row = ui.responsive_row(spacing=10)
        self._entry(row, label, variable)
        choose = self._button(row, key, "Choose…")
        choose.set_valign(Gtk.Align.END)
        parent.append(row)

    def _dropdown(self, parent, label, variable, values):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        box.append(ui.label(label, css=("sl-caption",)))
        dropdown = Gtk.DropDown.new_from_strings(values)
        dropdown.set_size_request(-1, ui.design.MIN_TARGET_PX)
        dropdown.set_selected(values.index(variable.get()))
        ui.accessible(dropdown, label)
        dropdown.connect("notify::selected", lambda widget, _param: self._dropdown_changed(widget, variable, values))
        box.append(dropdown)
        parent.append(box)
        self.dropdowns[id(variable)] = (dropdown, values)
        return dropdown

    def _check(self, parent, label, variable, description=""):
        check = ui.check_button(label, active=bool(variable.get()))
        check.set_size_request(-1, ui.design.MIN_TARGET_PX)
        ui.accessible(check, label, description)
        check.connect("toggled", lambda widget: self._toggle_changed(widget, variable))
        parent.append(check)
        self.toggles[id(variable)] = check
        return check

    def _text_editor(self, parent, name, variable, height=150):
        scroll = Gtk.ScrolledWindow(hexpand=True)
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_min_content_height(height)
        view = Gtk.TextView(wrap_mode=Gtk.WrapMode.WORD)
        view.get_buffer().set_text(str(variable.get()))
        view.add_css_class("sl-review-text")
        ui.accessible(view, name, "Multi-line text editor")
        view.get_buffer().connect("changed", lambda buffer: self._text_changed(buffer, variable))
        scroll.set_child(view)
        parent.append(scroll)
        self.text_values[id(variable)] = view
        return view

    def _value_label(self, parent, variable, css=("sl-body",)):
        widget = ui.label(str(variable.get()), css=css)
        parent.append(widget)
        self.value_labels[id(variable)] = widget
        return widget

    def _build_status(self):
        page = self._heading("Device and RogueMaster updates", "See genuine device-reported fields, then download, review, install and verify. SD candidates are never assumed to be Flipper-owned.")
        connection = self._card(page, "Connection choices", "Choose the mounted SD folder explicitly. Serial port is optional; leave it blank for official automatic selection.")
        self._path_row(connection, "Flipper SD folder", self.controller.sd_var, "browse_sd")
        row = ui.responsive_row(spacing=10)
        self._entry(row, "Serial port (optional)", self.controller.serial_var, "Flipper serial port, optional")
        refresh = self._button(row, "refresh_status", "Refresh device & drives", primary=True)
        refresh.set_valign(Gtk.Align.END)
        connection.append(row)
        status = self._card(page, "Device and computer status", "USB identity, mounted removable candidates and installed helper tools are reported separately.")
        for variable in (self.controller.status_summary_var, self.controller.usb_var, self.controller.mounts_var, self.controller.tools_var):
            self._value_label(status, variable)
        check = self._card(page, "Check RogueMaster Update", "Reads official latest-release metadata and actual device DEV-INFO. Different version schemes are not guessed into an update claim.", online=True)
        for label, variable in (
            ("Device firmware version", self.controller.device_version_var),
            ("Device firmware build date", self.controller.device_build_var),
            ("Latest stable version", self.controller.latest_version_var),
            ("Latest stable release date", self.controller.latest_release_var),
        ):
            check.append(ui.label(label, css=("sl-caption",)))
            self._value_label(check, variable, ("sl-body", "sl-card-title"))
        self._value_label(check, self.controller.update_assessment_var, ("sl-body", "sl-muted"))
        self._button(check, "check_update", "Check RogueMaster Update (online)", primary=True)
        install = self._card(page, "Download and Install Latest RogueMaster Update", "Verified official TGZ → full SD backup → qFlipper Install from file. Progress is measured; 100% appears only after firmware and every SD resource verify.", online=True)
        self._path_row(install, "Release download/work folder", self.controller.work_var, "browse_work")
        self._path_row(install, "Full-backup destination", self.controller.backup_dir_var, "browse_backup_dir")
        self._dropdown(install, "If existing resources differ", self.controller.conflict_var, ["abort", "replace"])
        self._button(install, "download_install", "Review, Download and Install (online)", primary=True)
        verify = self._card(page, "Finish and verify an installed update", "Reconnect the updated Flipper and mounted SD, then verify the selected cached release. Firmware and SD checks are independent.")
        self._path_row(verify, "Cached release folder", self.controller.release_var, "browse_release")
        buttons = self._button_row(verify)
        self._button(buttons, "verify_update", "Verify firmware and SD", primary=True)
        self._button(buttons, "resume_update", "Resume cached update (offline)")
        self.add_page("status", "Device", "drive-removable-media-symbolic", page)

    def _build_backup(self):
        page = self._heading("Verified backup and restore", "Full backups include a complete SHA-256 manifest. Restores preserve unrelated files and require a safety backup before differing files are replaced.")
        backup = self._card(page, "Create a full backup", "Save to this computer. Encryption uses the installed age or GnuPG backend; passphrases travel only through its protected input channel.")
        self._path_row(backup, "Computer backup destination", self.controller.backup_dir_var, "browse_backup_dir_2")
        self._check(backup, "Encrypted private backup (age or GnuPG)", self.controller.encrypted_var, "Uses a masked passphrase; plain backup is used when switched off")
        self._button(backup, "create_backup", "Create and verify full backup", primary=True)
        verify = self._card(page, "Verify or restore a backup", "Choose a plain backup folder or an encrypted .age/.gpg/.pgp file. Verification re-reads every payload hash.")
        row = ui.responsive_row(spacing=10)
        self._entry(row, "Backup folder or encrypted file", self.controller.backup_path_var)
        choose = self._button(row, "browse_backup", "Choose…")
        choose.set_valign(Gtk.Align.END)
        verify.append(row)
        buttons = self._button_row(verify)
        self._button(buttons, "verify_backup", "Verify every backup hash")
        self._button(buttons, "restore_backup", "Review and restore to selected SD", primary=True)
        verify.append(ui.label("The full-backup destination above is also used for the required pre-restore safety backup.", css=("sl-caption",)))
        self.add_page("backup", "Backups", "document-save-symbolic", page)

    def _build_personalise(self):
        page = self._heading("Animations, apps and favourites", "Build or select genuine resources, review local files, and keep verified backups before every write.")
        stock = self._card(page, "Download genuine stock resources", "Uses the official Flipper Devices directory and SHA-256 metadata. The device version is used unless an official version is entered.", online=True)
        self._path_row(stock, "Stock download/work folder", self.controller.stock_work_var, "browse_stock_work")
        self._entry(stock, "Official version (optional)", self.controller.stock_version_var)
        self._button(stock, "download_stock", "Download and verify stock resources (online)", primary=True)
        select = self._card(page, "Select and restore stock animations", "Preview cached genuine resources offline, select one or more animations, then confirm a full SD backup and restore.")
        self._path_row(select, "Verified stock release folder", self.controller.stock_dir_var, "browse_stock_dir")
        self._button(select, "preview_stock", "Load animation list and previews (offline)")
        self.stock_list = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        select.append(self.stock_list)
        self._button(select, "restore_stock", "Restore selected stock animations", primary=True)
        custom = self._card(page, "Build custom animations", "Requires a compatible firmware source tree with genuine frame_N.png assets. The real fbt dolphin_ext target may fetch its own toolchain dependencies.")
        self._path_row(custom, "Firmware/fbt source folder", self.controller.fbt_var, "browse_fbt")
        self._path_row(custom, "New computer output folder", self.controller.animation_output_var, "browse_animation_output")
        buttons = self._button_row(custom)
        self._button(buttons, "preview_custom", "Preview custom PNG assets")
        self._button(buttons, "build_custom", "Build custom animations with fbt", primary=True)
        install = self._card(page, "Install FAP or BadUSB files", "FAPs accept only .fap; BadUSB accepts reviewed .txt scripts. No file is executed on this computer.")
        choices = ui.responsive_row(spacing=12)
        self._dropdown(choices, "Type", self.controller.kind_var, ["fap", "badusb", "data"])
        self._dropdown(choices, "Save to", self.controller.destination_var, ["sd", "computer", "both"])
        install.append(choices)
        self._value_label(install, self.controller.sources_var, ("sl-caption",))
        sources = self._button_row(install)
        self._button(sources, "choose_sources", "Add files…")
        self._button(sources, "choose_source_folder", "Add folder…")
        self._entry(install, "FAP app folder", self.controller.app_folder_var)
        self._entry(install, "Data SD-relative folder", self.controller.data_dest_var)
        self._path_row(install, "Computer mirror folder", self.controller.computer_dir_var, "browse_computer_dir")
        self._button(install, "install_files", "Review and install selected files", primary=True)
        favourites = self._card(page, "Favourites", "One existing /any/... data or script path per line. A full SD backup is made before favorites.txt changes.")
        self._text_editor(favourites, "Favourite /any/... paths", self.controller.favourites_var)
        self._button(favourites, "save_favourites", "Back up and save favourites", primary=True)
        apps = self._card(page, "Curate key apps", "One assignment per line: Category | apps/source/app.fap. Copies are hash-verified and originals remain. Internal RogueMaster keybinds are not modified.")
        self._text_editor(apps, "Key app category and SD FAP assignments", self.controller.apps_var)
        self._button(apps, "organise_apps", "Back up and copy key apps", primary=True)
        self.add_page("personalise", "Personalise", "applications-graphics-symbolic", page)

    def _build_tools(self):
        page = self._heading("Recovery, tools and activity", "Resume cached work, restore journaled backups, inspect read-only, or open the official qFlipper interface at a larger scale.")
        recovery = self._card(page, "Update recovery and rollback", "Rollback restores SD files from the original verified backup. It does not claim to roll back internal firmware; additions after the backup may remain.")
        self._path_row(recovery, "Cached release folder", self.controller.release_var, "browse_release_2")
        buttons = self._button_row(recovery)
        self._button(buttons, "resume_update_2", "Resume cached update (offline)")
        self._button(buttons, "rollback_update", "Review and roll back SD update", primary=True)
        stock = self._card(page, "Stock animation rollback", "Uses a genuine stock-restoration journal. Only unchanged companion-added files can be removed; firmware is not rolled back.")
        self._path_row(stock, "Stock rollback journal", self.controller.stock_journal_var, "browse_stock_journal")
        self._button(stock, "rollback_stock", "Review stock animation rollback")
        qflipper = self._card(page, "qFlipper on a larger computer screen", "Launches the installed official GUI with QT_SCALE_FACTOR. Screen streaming and control depend on qFlipper and device support.")
        row = ui.responsive_row(spacing=12)
        scale = Gtk.SpinButton.new_with_range(0.5, 4.0, 0.25)
        scale.set_digits(2)
        scale.set_value(float(self.controller.scale_var.get()))
        scale.set_size_request(-1, ui.design.MIN_TARGET_PX)
        ui.accessible(scale, "qFlipper display scale", "Between 0.5 and 4.0; default 1.5")
        scale.connect("value-changed", lambda widget: self.controller.scale_var.set(widget.get_value()))
        row.append(scale)
        self._check(row, "Use Flatpak qFlipper", self.controller.flatpak_var, "Otherwise use the installed native qFlipper")
        qflipper.append(row)
        self.buttons["scale"] = scale
        self._button(qflipper, "qflipper", "Launch qFlipper larger", primary=True)
        tools = self._card(page, "Read-only inspection and files", "DFU inspection runs only the backend's read-only device listing. No firmware flash or erase is performed.")
        buttons = self._button_row(tools)
        self._button(buttons, "dfu_check", "Inspect DFU devices (read-only)")
        self._button(buttons, "open_sd", "Open selected SD in file manager")
        activity = self._card(page, "Activity and verification details", "Backend reviews and verified results appear here. Passphrases, raw device UIDs and external crypto-tool output are never logged.")
        scroll = Gtk.ScrolledWindow(hexpand=True)
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_min_content_height(320)
        self.log_text = Gtk.TextView(editable=False, cursor_visible=False, wrap_mode=Gtk.WrapMode.WORD)
        self.log_text.add_css_class("sl-review-text")
        ui.accessible(self.log_text, "Activity log, read only", "Backend operation reviews and verified results; no passphrases")
        scroll.set_child(self.log_text)
        activity.append(scroll)
        self._button(activity, "clear_activity", "Clear activity view")
        page.append(ui.label("Advanced CLI fallback only: secure-linux-flipper --help", css=("sl-caption",)))
        self.add_page("tools", "Tools", "applications-system-symbolic", page)

    def _build_progress(self):
        footer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        footer.add_css_class("sl-status-card")
        for margin in (16,):
            footer.set_margin_top(margin)
            footer.set_margin_bottom(margin)
            footer.set_margin_start(margin)
            footer.set_margin_end(margin)
        top = ui.responsive_row(spacing=12)
        self.progress_top = top
        self.operation_label = ui.label(self.controller.operation_var.get(), css=("sl-card-title",))
        self.operation_label.set_hexpand(True)
        top.append(self.operation_label)
        self.cancel_button = ui.button("Cancel operation", self._cancel)
        self.buttons["cancel"] = self.cancel_button
        top.append(self.cancel_button)
        footer.append(top)
        self.progress = Gtk.ProgressBar()
        self.progress.set_size_request(-1, 12)
        ui.accessible(self.progress, "Measured operation progress", "Percentages and ETA come only from backend measurements and matching per-device history")
        footer.append(self.progress)
        self.progress_label = ui.label(self.controller.progress_var.get(), css=("sl-body",))
        self.eta_label = ui.label("", css=("sl-caption",))
        footer.append(self.progress_label)
        footer.append(self.eta_label)
        outer = self.bottom_nav.get_parent()
        body = self.stack.get_parent()
        outer.insert_child_after(footer, body)
        self._set_compact(self._compact)

    def _set_compact(self, compact):
        super()._set_compact(compact)
        if hasattr(self, "progress_top"):
            self.progress_top.set_orientation(Gtk.Orientation.VERTICAL if compact else Gtk.Orientation.HORIZONTAL)

    def _entry_changed(self, widget, variable):
        if not self._syncing:
            variable.set(widget.get_text())
    def _dropdown_changed(self, widget, variable, values):
        if not self._syncing:
            variable.set(values[widget.get_selected()])
    def _toggle_changed(self, widget, variable):
        if not self._syncing:
            variable.set(widget.get_active())
    def _text_changed(self, buffer, variable):
        if not self._syncing:
            variable.set(buffer.get_text(buffer.get_start_iter(), buffer.get_end_iter(), False))

    def _guard(self, key):
        try:
            self.controller.invoke(key)
        except CompanionError as exc:
            self.controller.operation_var.set("Stopped safely — nothing new was started")
            self.controller._log(f"Stopped safely: {exc}")
            ui.message_dialog(self, "Review the selection", str(exc))
        except ValueError as exc:
            self.controller.operation_var.set("Check the entered value")
            ui.message_dialog(self, "Check the entered value", str(exc))
        self._sync_all()

    def _choose(self, key):
        if key == "browse_backup":
            self._choose_backup()
            return
        method, title, kind = CHOOSERS[key]
        chooser = Gtk.FileDialog()
        chooser.set_title(title)
        if kind == "folder":
            chooser.select_folder(self, None, lambda dialog, result: self._chosen_folder(dialog, result, method))
        elif kind == "files":
            chooser.open_multiple(self, None, lambda dialog, result: self._chosen_files(dialog, result, method))
        else:
            chooser.open(self, None, lambda dialog, result: self._chosen_file(dialog, result, method))

    def _choose_backup(self):
        dialog = ui.Adw.Dialog(title="Choose backup type")
        dialog.set_content_width(520)
        dialog.set_content_height(320)
        page = ui.page_box()
        for margin in (24,):
            page.set_margin_top(margin)
            page.set_margin_bottom(margin)
            page.set_margin_start(margin)
            page.set_margin_end(margin)
        page.append(ui.label("Choose an encrypted backup file or a plain verified backup folder.", css=("sl-body",)))
        actions = ui.dialog_row(dialog, homogeneous=True)
        for text, kind in (("Encrypted file…", "file"), ("Plain folder…", "folder")):
            def begin(_button, selected=kind):
                dialog.close()
                chooser = Gtk.FileDialog()
                chooser.set_title("Choose backup")
                callback = lambda native, result: self._chosen_folder(native, result, "action_browse_backup") if selected == "folder" else self._chosen_file(native, result, "action_browse_backup")
                if selected == "folder":
                    chooser.select_folder(self, None, callback)
                else:
                    chooser.open(self, None, callback)
            actions.append(ui.button(text, begin, primary=(kind == "file")))
        actions.append(ui.button("Cancel", dialog.close))
        dialog.set_child(page)
        dialog.present(self)

    def _chosen_folder(self, dialog, result, method):
        try:
            chosen = dialog.select_folder_finish(result)
        except Exception:
            return
        if chosen and chosen.get_path():
            getattr(self.controller, method)(chosen.get_path())
            self._sync_all()

    def _chosen_file(self, dialog, result, method):
        try:
            chosen = dialog.open_finish(result)
        except Exception:
            return
        if chosen and chosen.get_path():
            getattr(self.controller, method)(chosen.get_path())
            self._sync_all()

    def _chosen_files(self, dialog, result, method):
        try:
            chosen = dialog.open_multiple_finish(result)
        except Exception:
            return
        paths = [item.get_path() for item in chosen if item.get_path()] if chosen is not None else []
        if paths:
            getattr(self.controller, method)(paths)
            self._sync_all()

    def _sync_stock(self):
        signature = tuple((item.get("name"), item.get("frame_count"), item.get("visual_preview_status")) for item in self.controller.stock_previews)
        if signature != self._stock_signature:
            while True:
                child = self.stock_list.get_first_child()
                if child is None:
                    break
                self.stock_list.remove(child)
            self.stock_options = []
            for item in self.controller.stock_previews:
                name = str(item["name"])
                toggle = ui.check_button(f"{name} — {item['frame_count']} frames — {item['visual_preview_status']}")
                toggle.set_size_request(-1, ui.design.MIN_TARGET_PX)
                ui.accessible(toggle, f"Select stock animation {name}")
                toggle.connect("toggled", self._stock_changed)
                self.stock_list.append(toggle)
                self.stock_options.append((name, toggle))
            self._stock_signature = signature
        selected = set(self.controller.selected_stock_names.get())
        for name, toggle in self.stock_options:
            toggle.set_active(name in selected)

    def _stock_changed(self, _toggle):
        if not self._syncing:
            self.controller.selected_stock_names.set([name for name, toggle in self.stock_options if toggle.get_active()])

    def _sync_all(self):
        self._syncing = True
        try:
            variables = list(vars(self.controller).values())
            for key, entry in self.entries.items():
                variable = next(value for value in variables if id(value) == key)
                if entry.get_text() != str(variable.get()):
                    entry.set_text(str(variable.get()))
            for key, (dropdown, values) in self.dropdowns.items():
                variable = next(value for value in vars(self.controller).values() if id(value) == key)
                selected = values.index(variable.get()) if variable.get() in values else 0
                if dropdown.get_selected() != selected:
                    dropdown.set_selected(selected)
            for key, toggle in self.toggles.items():
                variable = next(value for value in vars(self.controller).values() if id(value) == key)
                toggle.set_active(bool(variable.get()))
            for key, view in self.text_values.items():
                variable = next(value for value in vars(self.controller).values() if id(value) == key)
                buffer = view.get_buffer()
                text = buffer.get_text(buffer.get_start_iter(), buffer.get_end_iter(), False)
                if text != str(variable.get()):
                    buffer.set_text(str(variable.get()))
            for key, label in self.value_labels.items():
                variable = next(value for value in vars(self.controller).values() if id(value) == key)
                label.set_label(str(variable.get()))
            self._sync_stock()
        finally:
            self._syncing = False
        for key, button in self.buttons.items():
            if key not in {"cancel", "scale"}:
                button.set_sensitive(not self.controller.busy)
        self.cancel_button.set_sensitive(self.controller.busy)
        self.operation_label.set_label(self.controller.operation_var.get())
        self.progress_label.set_label(self.controller.progress_var.get())
        self.eta_label.set_label(self.controller.eta_var.get())
        self.progress.set_fraction(max(0.0, min(1.0, self.controller.progress_value / 100.0)))
        if self._activity_version != self.controller.activity_version:
            self.log_text.get_buffer().set_text(self.controller.activity_text)
            self._activity_version = self.controller.activity_version

    def _present_request(self, request):
        if request.kind == "confirm":
            dialog = ReviewDialog(self, request)
        else:
            dialog = PassphraseDialog(self, request)
        self.active_dialog = dialog
        dialog.dialog.connect("closed", lambda _native: setattr(self, "active_dialog", None))

    def _cancel(self):
        self.controller.action_cancel()
        if self.active_dialog is not None:
            self.active_dialog.dialog.close()
        self._sync_all()

    def _tick(self):
        self.controller.poll_timing()
        for kind, payload in self.controller.process_events():
            if kind == "request":
                self._present_request(payload)
            elif kind == "error":
                ui.message_dialog(self, "Operation stopped safely", payload)
            elif kind == "close":
                self.destroy()
        self._sync_all()
        if self.controller.busy and self.controller.progress_mode == "indeterminate":
            self.progress.pulse()
        return True

    def _close_request(self, _window):
        busy = self.controller.request_close()
        if busy and self.active_dialog is not None:
            self.active_dialog.dialog.close()
        self._sync_all()
        return busy

    def _key_pressed(self, controller, keyval, keycode, state):
        if keyval == ui.Gdk.KEY_F5:
            self._guard("refresh_status")
            return True
        return super()._key_pressed(controller, keyval, keycode, state)


def main(demo: bool = False) -> int:
    def build(application):
        return FlipperWindow(application, FlipperController(demo=demo))
    return ui.run_application("org.securelinux.FlipperCompanion", build, [sys.argv[0]])
