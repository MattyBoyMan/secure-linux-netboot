#!/usr/bin/env python3
"""Native GTK4/Libadwaita task views for USB Workshop."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess

from gui_tools_common import format_bytes, health_text
from gui_tools_gtk import (
    Gtk, advanced, card, choose_path, dropdown, entry, field, run_native,
    NativeOperationWindow, ui,
)
from usb_tools_gui import DEMO_DEVICES, FS_HELP


class USBWindow(NativeOperationWindow):
    app_title = "Secure Linux USB Workshop"
    app_subtitle = "Choose one task. Images come before recovery, repair or erasing."

    def __init__(self, application, backend, *, runner=None, demo=False, view="drives"):
        super().__init__(application, runner=runner, demo=demo)
        self.backend = backend
        self.devices = []
        home = Path.home()
        self.output_dir = entry(str(home / "USB-backups"), description="Folder for whole-disk safety images")
        self.image_path = entry(description="Verified safety image")
        self.recovery_output = entry(str(home / "Recovered-files"), description="Recovered files folder")
        self.recovery_tool = dropdown(("photorec", "testdisk"), description="Image recovery engine")
        self.partition = Gtk.SpinButton.new_with_range(1, 128, 1)
        self.partition.set_size_request(-1, ui.design.MIN_TARGET_PX)
        ui.accessible(self.partition, "Partition number on the disposable image copy")
        self.filesystem = dropdown(tuple(FS_HELP), description="New filesystem", on_change=self._filesystem_changed)
        self.label_entry = entry("SECURE-USB", description="New filesystem label")
        self.other_backup = ui.check_button("I already have another backup; explicitly allow --skip-image")
        ui.accessible(self.other_backup, "Use another backup instead of a new verified image")
        self.copy_mode = dropdown(("clone", "portable"), description="USB copy mode", on_change=self._copy_mode_changed)
        self.resume_mode = dropdown(("new", "resume", "restart"), description="What to do after an interrupted copy")
        self.store = entry(str(home / ".local/share/secure-linux/usb-master"), description="Private verified USB master storage")
        self.source_root = entry(description="Finished USB file tree for portable tools copy")
        self.ventoy = entry(description="Official Ventoy2Disk.sh path")
        self.selected_label = ui.label("No USB drive selected", css=("sl-caption",))
        self.fs_help = ui.label(FS_HELP["exfat"], css=("sl-caption", "sl-muted"))
        self.drive_choice = dropdown((), description="Removable whole USB drive", on_change=self._drive_changed)
        self._build_drives()
        self._build_fixer()
        self._build_creator()
        self.finish_pages(view)
        if demo:
            self.devices = [dict(row) for row in DEMO_DEVICES]
            self._populate()
            self.source_root.set_text("/media/SecureLinux")
            self.store.set_text("/home/demo/.local/share/secure-linux/usb-master")
            self.ventoy.set_text("/home/demo/Downloads/Ventoy2Disk.sh")
            self.image_path.set_text("/home/demo/USB-backups/verified-usb.img")
            self.output_dir.set_text("/home/demo/USB-backups")
            self.append_output("Preview only. No drives or servers are contacted.")
        else:
            self.refresh_drives()

    def _build_drives(self):
        page = ui.page_box()
        ui.add_heading(page, "Start with the whole USB drive", "Only removable whole disks listed by the existing creator are selectable. Fixed system disks and individual partitions are not offered.")
        select = card("1. Identify the drive", "Check its path, model and stable serial/WWN before moving to a task. Selecting a drive changes nothing.")
        field(select, "Removable whole USB drive", self.drive_choice)
        select.append(self.selected_label)
        select.append(ui.button("Refresh drives — read only", self.refresh_drives, primary=True))
        page.append(select)
        page.append(card("What the health labels mean", "SMART passed is an indication, not a guarantee. Unknown health stays unknown. Free space is descriptive; imaging and cloning still need enough destination capacity."))
        page.append(card("Low-level rescue remains available", "Boot rescue stays a text tool because a failed computer or live rescue environment may have no graphical desktop. This window does not replace that path."))
        self.add_page("drives", "Choose USB", "drive-removable-media-symbolic", page)

    def _path_row(self, parent, title, widget, folder, chooser_title):
        row = ui.responsive_row(spacing=12)
        row.append(widget)
        row.append(ui.button("Choose…", lambda: choose_path(self, widget.set_text, folder=folder, title=chooser_title)))
        field(parent, title, row)

    def _build_fixer(self):
        page = ui.page_box()
        ui.add_heading(page, "Protect the only copy first", "Diagnose without writes, create a verified whole-disk image, then recover from that image—not from the original USB.")
        inspect = card("Look before changing anything", "Diagnosis checks identity, capacity, filesystems and health. It never repairs or erases.")
        inspect.append(ui.button("Diagnose selected USB", self.diagnose, primary=True))
        page.append(inspect)
        image = card("1. Create a verified safety image", "Save every byte on another disk. Only a fresh source/image SHA-256 match receives verified metadata.")
        self._path_row(image, "Save images on another disk in", self.output_dir, True, "Choose safety-image folder")
        image.append(ui.button("Review whole-disk image", self.make_image, primary=True))
        page.append(image)
        recover = card("2. Recover files from the image", "The verified image is not changed. Recovery can be partial and never promises that every file was recovered.")
        self._path_row(recover, "Verified image", self.image_path, False, "Choose verified USB image")
        self._path_row(recover, "Recovered files folder", self.recovery_output, True, "Choose recovered-files folder")
        field(recover, "Recovery engine", self.recovery_tool)
        recover.append(ui.button("Review image-first recovery", self.recover))
        page.append(recover)
        repair_expander, repair_body = advanced("Advanced: repair a disposable image copy")
        repair_body.append(ui.label("The original USB and verified image stay unchanged. No automatic restore occurs.", css=("sl-body", "sl-muted")))
        field(repair_body, "Partition number", self.partition)
        repair_body.append(ui.button("Review scratch-copy repair", self.repair))
        page.append(repair_expander)
        format_expander, format_body = advanced("Advanced: format and erase the selected whole disk")
        format_body.append(ui.label("Destructive: two exact, case-sensitive confirmations are required. This is not a secure erase.", css=("sl-body",)))
        field(format_body, "Filesystem", self.filesystem)
        format_body.append(self.fs_help)
        field(format_body, "New label", self.label_entry)
        format_body.append(self.other_backup)
        format_body.append(ui.button("Review whole-disk format…", self.format, primary=True))
        page.append(format_expander)
        self.add_page("fixer", "Recover & repair", "drive-harddisk-symbolic", page)

    def _build_creator(self):
        page = ui.page_box()
        ui.add_heading(page, "Create installers with proof", "Save a finished USB once, then choose an exact clone or a portable tools copy. These are different outcomes.")
        master = card("1. Save or update the source master", "Reads the selected finished source USB; it does not erase it. An interrupted update is not published as current.")
        self._path_row(master, "Private master storage", self.store, True, "Choose private master storage")
        self._path_row(master, "Finished USB file tree (for portable copy)", self.source_root, True, "Choose finished USB file tree")
        master.append(ui.button("Review verified master capture", self.create_master, primary=True))
        page.append(master)
        copy = card("2. Copy to the selected destination USB", "The destination is overwritten in the engine's documented extent. Full read-back or every copied-file hash must pass before verification is reported.")
        field(copy, "Copy type", self.copy_mode, "Exact clone = full-device read-back. Portable tools = genuine Ventoy plus file hashes, not byte-for-byte identical.")
        self.ventoy_row = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self._path_row(self.ventoy_row, "Official Ventoy2Disk.sh", self.ventoy, False, "Choose official Ventoy2Disk.sh")
        copy.append(self.ventoy_row)
        field(copy, "After interruption", self.resume_mode, "Resume re-hashes retained content. Restart discards the partial attempt.")
        copy.append(ui.button("Review destination & copy…", self.copy, primary=True))
        page.append(copy)
        inspect_expander, inspect_body = advanced("Advanced: fit, full verification and durable receipt")
        for label, action in (("Measure minimum sizes", "measure"), ("Verify exact clone", "verify"), ("Read clone status", "status")):
            inspect_body.append(ui.button(label, lambda value=action: self.inspect_copy(value)))
        inspect_body.append(ui.label("A saved receipt is not fresh verification after another write or replug. Larger targets retain unverified space beyond an exact master.", css=("sl-caption", "sl-muted")))
        page.append(inspect_expander)
        self.add_page("creator", "Create & copy", "media-optical-symbolic", page)
        self._copy_mode_changed("clone")

    def _filesystem_changed(self, value):
        self.fs_help.set_label(FS_HELP[value])

    def _copy_mode_changed(self, value):
        if hasattr(self, "ventoy_row"):
            self.ventoy_row.set_visible(value == "portable")

    def _drive_changed(self, _value=None):
        drive = self.selected_drive(required=False)
        if drive:
            identity = drive.get("serial") or drive.get("wwn") or "No stable identity"
            self.selected_label.set_label(f"{drive['path']} — {drive.get('model', 'Unknown')} — {identity} — {format_bytes(drive.get('size'))} — {health_text(drive.get('health'))}")
        else:
            self.selected_label.set_label("No USB drive selected")

    def refresh_drives(self):
        try:
            self.devices = self.backend.list_devices()
            self._populate()
            self.activity_label.set_label(f"Found {len(self.devices)} removable whole USB drive(s). No write operation was run.")
        except (OSError, RuntimeError, ValueError, json.JSONDecodeError, subprocess.TimeoutExpired) as exc:
            self.notify("Drive list unavailable", f"Could not list USB drives. No operation was started.\n\n{exc}")

    def _populate(self):
        labels = [f"{row.get('path', '')} — {row.get('model') or 'Unknown model'} — {row.get('serial') or row.get('wwn') or 'No stable identity'}" for row in self.devices]
        self.drive_choice.set_model(Gtk.StringList.new(labels))
        self.drive_choice.set_selected(0 if labels else Gtk.INVALID_LIST_POSITION)
        self._drive_changed()

    def selected_drive(self, required=True):
        selected = self.drive_choice.get_selected()
        if selected == Gtk.INVALID_LIST_POSITION or selected >= len(self.devices):
            if required:
                self.notify("Choose a USB drive", "Go to Choose USB and select one listed whole USB drive.")
            return None
        return self.devices[selected]

    @staticmethod
    def _identity(drive):
        identity = str(drive.get("serial") or drive.get("wwn") or "")
        if not identity:
            raise ValueError("This drive has no serial or WWN. The existing engine refuses ambiguous destinations.")
        return identity

    def diagnose(self):
        drive = self.selected_drive()
        if drive:
            self.run(self.backend.diagnose(str(drive["path"])))

    def make_image(self):
        drive = self.selected_drive()
        if not drive or not self.output_dir.get_text().strip():
            return
        output = self.output_dir.get_text().strip()
        summary = f"Read every byte of {drive['path']} ({drive.get('model')}, {self._identity(drive)}) into {output}.\n\nThe destination must be another disk. Only a fresh source/image SHA-256 match receives verified metadata."
        self.review("Review safety image", summary, (), lambda _secret: self.run(self.backend.image(str(drive["path"]), output)))

    def recover(self):
        image, output = self.image_path.get_text().strip(), self.recovery_output.get_text().strip()
        if not image or not output:
            self.notify("Image and output needed", "Choose a verified image and a recovered-files folder on another disk.")
            return
        tool = ("photorec", "testdisk")[self.recovery_tool.get_selected()]
        summary = f"Recover from {image} into {output} using {tool}.\n\nThe verified image is not changed. Recovery can be partial and is never a claim that every file was recovered."
        self.review("Review image-first recovery", summary, (), lambda _secret: self.run(self.backend.recover(image, output, tool)))

    def repair(self):
        drive = self.selected_drive()
        image, output = self.image_path.get_text().strip(), self.recovery_output.get_text().strip()
        if not drive or not image or not output:
            self.notify("Drive, image and output needed", "Select the source drive, its verified image and a scratch-copy output folder.")
            return
        partition = self.partition.get_value_as_int()
        phrase = f"REPAIR PARTITION {partition}"
        summary = f"Check that {image} belongs to {drive['path']} ({self._identity(drive)}), then repair partition {partition} on a disposable copy in {output}.\n\nNo original-disk repair and no automatic restore occurs."
        self.review("Review scratch-copy repair", summary, (phrase,), lambda _secret: self.run(self.backend.repair(str(drive["path"]), image, output, partition)))

    def format(self):
        drive = self.selected_drive()
        if not drive:
            return
        path, serial = str(drive["path"]), self._identity(drive)
        image = self.image_path.get_text().strip()
        skip = self.other_backup.get_active()
        if not skip and not image:
            self.notify("Save an image first", "Create and choose a verified safety image first, or explicitly declare that you already have another backup.")
            return
        first, second = f"TARGET {path} {serial}", f"ERASE {path}"
        backup = "Use the declared existing backup; no new image is required." if skip else f"Require verified image: {image}"
        filesystem = tuple(FS_HELP)[self.filesystem.get_selected()]
        label = self.label_entry.get_text().strip()
        summary = f"ERASE THE WHOLE DRIVE {path}\nModel: {drive.get('model')}\nSerial/WWN: {serial}\nCapacity: {format_bytes(drive.get('size'))}\nNew filesystem: {filesystem}\n{backup}\n\nThis is not a secure erase. The engine rechecks identity and capacity before writing."
        self.review("Two exact erase confirmations", summary, (first, second), lambda _secret: self.run(self.backend.format(path, serial, filesystem, label, image, skip)))

    def create_master(self):
        drive = self.selected_drive()
        if not drive:
            return
        store, source_root = self.store.get_text().strip(), self.source_root.get_text().strip()
        summary = f"Read finished source {drive['path']} ({self._identity(drive)}) and save a compressed, read-only master in {store}.\n\nThe source is not erased. An interrupted update is not published as current."
        self.review("Review master capture", summary, (), lambda _secret: self.run(self.backend.create_master(str(drive["path"]), store, source_root)))

    def copy(self):
        drive = self.selected_drive()
        if not drive:
            return
        path, identity = str(drive["path"]), self._identity(drive)
        mode = ("clone", "portable")[self.copy_mode.get_selected()]
        resume = ("new", "resume", "restart")[self.resume_mode.get_selected()]
        store, ventoy = self.store.get_text().strip(), self.ventoy.get_text().strip()
        phrase = f"ERASE {identity}"
        kind = "Exact whole-device clone" if mode == "clone" else "Portable tools copy (not an exact clone)"
        summary = f"{kind}\n\nDestination: {path}\nModel: {drive.get('model')}\nSerial/WWN: {identity}\nCapacity: {format_bytes(drive.get('size'))}\nMaster: {store}\nInterruption choice: {resume}\n\nThe destination will be overwritten in the engine's documented extent. Nothing is verified until full read-back or every copied-file hash passes."
        self.review("Review USB destination", summary, (phrase,), lambda _secret: self.run(self.backend.copy(mode, path, identity, store, resume, ventoy)))

    def inspect_copy(self, action):
        drive = self.selected_drive()
        if drive:
            self.run(self.backend.inspect_copy(action, str(drive["path"]), self.store.get_text().strip()))
