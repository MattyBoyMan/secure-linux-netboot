#!/usr/bin/env python3
"""Native GTK4/Libadwaita task views for USB Workshop."""
from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess

from gui_tools_common import format_bytes, health_text
from gui_tools_gtk import (
    Gtk, advanced, card, check, choose_path, dropdown, entry, field, run_native,
    NativeOperationWindow, ui,
)
from usb_tools_gui import DEMO_DEVICES, FS_HELP, PERSONAL_CHOICES, honest_result

MASTER_PANEL = "secure-linux-usb-creator-gui"
# Same order as PERSONAL_CHOICES (mine, none, other). Plain words for the person making the copy.
PERSONAL_LABELS = (
    "My own settings, as saved on this computer",
    "Nobody's settings: the person types their own name and password when they install",
    "Another person: only what their settings file says",
)
PERSONAL_WORDS = {
    "mine": "your own settings, as saved",
    "none": "nobody's settings (the person types their own name and password when they install)",
    "other": "another person's settings, only what their settings file says",
}
TEST_FIRST_LABELS = ("No, copy straight away", "Yes, a quick test first (checks spots all over)",
                     "Yes, a full test first (checks every part, takes longer)")
TEST_DEPTH_LABELS = ("Full test: checks every part (takes longer)", "Quick test: checks spots all over")


def master_panel_available() -> bool:
    """The "My saved master" window comes with the newer drive-builder launcher; older launchers lack it."""
    launcher = shutil.which(MASTER_PANEL)
    try:
        return bool(launcher) and b"--master-panel" in Path(launcher).read_bytes()
    except OSError:
        return False


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
        self.personal_choice = dropdown(PERSONAL_LABELS, description="Whose settings go on the copy",
                                        on_change=self._personal_changed)
        self.person_file = entry(description="Settings file for the other person")
        self.never_online = check("Never check online for updates on computers set up from this drive")
        self.test_first = dropdown(TEST_FIRST_LABELS, description="Test the drive before copying to it")
        self.test_depth = dropdown(TEST_DEPTH_LABELS, description="How carefully to test the new drive")
        self.multi_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.multi_checks = []
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
        files = card("Check and repair this drive's files", "For a finished Secure Linux drive. It lists the files that are missing or damaged and copies back only those. Nothing is erased or formatted.")
        files.append(ui.button("Check and repair this drive's files…", self.repair_drive_files))
        page.append(files)
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
        master.append(ui.label("Undo the last master update: the newer saved master is kept, so you can switch back.", css=("sl-caption", "sl-muted")))
        master.append(ui.button("Undo the last master update…", self.undo_master))
        master.append(ui.label("Bring the big files in the saved master up to date. This can download several gigabytes. Free space is checked first, and the older saved master is kept.", css=("sl-caption", "sl-muted")))
        master.append(ui.button("Refresh big files…", self.refresh_big_files))
        master.append(ui.label("Let drives made from the saved master start Secure Linux without installing it. This downloads Fedora's live image and checks it against Fedora's signed list.", css=("sl-caption", "sl-muted")))
        master.append(ui.button("Add try-without-installing…", self.add_live_mode))
        if master_panel_available():
            master.append(ui.button("My saved master…", self.open_master_panel))
        page.append(master)
        copy = card("2. Copy to the selected destination USB", "The destination is overwritten in the engine's documented extent. Full read-back or every copied-file hash must pass before verification is reported.")
        field(copy, "Copy type", self.copy_mode, "Exact clone = full-device read-back. Portable tools = genuine Ventoy plus file hashes, not byte-for-byte identical.")
        self.portable_options = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        field(self.portable_options, "Whose settings go on the copy", self.personal_choice,
              "Choose Nobody's settings or Another person before you give a drive to someone else. Your name, password and home network details are then left off the drive.")
        self.person_row = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self._path_row(self.person_row, "Settings file for the other person", self.person_file, False, "Choose the other person's settings file")
        self.portable_options.append(self.person_row)
        self.portable_options.append(self.never_online)
        field(self.portable_options, "Test the drive first", self.test_first,
              "A test erases the drive. It finds drives that say they are bigger than they are.")
        copy.append(self.portable_options)
        self.ventoy_row = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self._path_row(self.ventoy_row, "Official Ventoy2Disk.sh", self.ventoy, False, "Choose official Ventoy2Disk.sh")
        copy.append(self.ventoy_row)
        field(copy, "After interruption", self.resume_mode, "Resume re-hashes retained content. Restart discards the partial attempt.")
        copy.append(ui.button("Review destination & copy…", self.copy, primary=True))
        page.append(copy)
        test = card("Test a new drive", "Find out whether a new drive is really as big as it says and keeps what is written to it. This erases everything on the selected drive.")
        field(test, "How to test", self.test_depth)
        test.append(ui.button("Test a new drive…", self.test_new_drive))
        page.append(test)
        several = card("Copy to several drives", "Tick two or more drives. They are all made at the same time from the saved master, and each one is checked. These drives always carry your own settings.")
        several.append(self.multi_box)
        several.append(ui.button("Copy to several drives…", self.copy_several))
        page.append(several)
        inspect_expander, inspect_body = advanced("Advanced: fit, full verification and durable receipt")
        for label, action in (("Measure minimum sizes", "measure"), ("Verify exact clone", "verify"), ("Read clone status", "status")):
            inspect_body.append(ui.button(label, lambda value=action: self.inspect_copy(value)))
        inspect_body.append(ui.label("A saved receipt is not fresh verification after another write or replug. Larger targets retain unverified space beyond an exact master.", css=("sl-caption", "sl-muted")))
        page.append(inspect_expander)
        self.add_page("creator", "Create & copy", "media-optical-symbolic", page)
        self._copy_mode_changed("clone")
        self._personal_changed()

    def _filesystem_changed(self, value):
        self.fs_help.set_label(FS_HELP[value])

    def _copy_mode_changed(self, value):
        if hasattr(self, "ventoy_row"):
            self.ventoy_row.set_visible(value == "portable")
        if hasattr(self, "portable_options"):
            self.portable_options.set_visible(value == "portable")

    def _personal_changed(self, _value=None):
        if hasattr(self, "person_row"):
            self.person_row.set_visible(self.personal_choice.get_selected() == PERSONAL_CHOICES.index("other"))

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
        self._fill_several()

    def _fill_several(self):
        """One tick box per listed drive, for "Copy to several drives". Ticking changes nothing by itself."""
        child = self.multi_box.get_first_child()
        while child is not None:
            self.multi_box.remove(child)
            child = self.multi_box.get_first_child()
        self.multi_checks = []
        for row in self.devices:
            identity = row.get("serial") or row.get("wwn") or "No stable identity"
            box = check(f"{row.get('path', '')} — {row.get('model') or 'Unknown model'} — {identity} — {format_bytes(row.get('size'))}")
            self.multi_box.append(box)
            self.multi_checks.append((row, box))

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

    def repair_drive_files(self):
        drive = self.selected_drive()
        if not drive:
            return
        path = str(drive["path"])
        try:
            identity = self._identity(drive)
        except ValueError as exc:
            self.notify("This drive cannot be checked", f"{exc}\n\nNothing was changed.")
            return
        phrase = f"TARGET {path} {identity}"
        summary = f"Check the files on the Secure Linux drive {path} ({drive.get('model')}, {identity}).\n\nOnly files that are missing or damaged are copied back, and each one is checked afterwards. Nothing is erased or formatted. The repair tool asks for the same words itself before it changes anything."
        self.review("Check and repair this drive's files", summary, (phrase,), lambda _secret: self.run(self.backend.repair_drive(path, identity)))

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
        portable = mode == "portable"
        personal = PERSONAL_CHOICES[self.personal_choice.get_selected()] if portable else "mine"
        person_file = self.person_file.get_text().strip() if personal == "other" else ""
        never_online = portable and self.never_online.get_active()
        test_depth = ("", "quick", "full")[self.test_first.get_selected()] if portable else ""
        phrase = f"ERASE {identity}"
        variant, variant_words = "", ""
        if portable:
            variant, variant_words = self._copy_variant(store)
            if not variant:
                return
        try:
            spec = self.backend.copy(mode, path, identity, store, resume, ventoy, personal=personal,
                                     person_file=person_file, never_check_online=never_online, test_drive=test_depth,
                                     variant=variant)
        except ValueError as exc:
            self.notify("Check the copy choices", f"{exc}\n\nNothing was changed.")
            return
        kind = "Exact whole-device clone" if mode == "clone" else "Portable tools copy (not an exact clone)"
        settings = f"Settings on the copy: {PERSONAL_WORDS[personal]}\n{variant_words}\n" if portable else ""
        extras = ("Computers set up from this drive never check online for updates.\n" if never_online else "") + \
                 (f"The drive is tested first ({test_depth}). The test erases it.\n" if test_depth else "")
        summary = f"{kind}\n\nDestination: {path}\nModel: {drive.get('model')}\nSerial/WWN: {identity}\nCapacity: {format_bytes(drive.get('size'))}\nMaster: {store}\nInterruption choice: {resume}\n{settings}{extras}\nThe destination will be overwritten in the engine's documented extent. Nothing is verified until full read-back or every copied-file hash passes."
        self.review("Review USB destination", summary, (phrase,), lambda _secret: self.run(spec))

    def inspect_copy(self, action):
        drive = self.selected_drive()
        if drive:
            self.run(self.backend.inspect_copy(action, str(drive["path"]), self.store.get_text().strip()))

    def _copy_variant(self, store):
        """Which Portable tools copy fits the saved master ("full" or "online-only") and its plain words. When none
        fits, the person is told why and ("", words) comes back."""
        variant, words = self.backend.master_variant(store)
        if not variant:
            self.notify("No copy fits yet", words)
        return variant, words

    def copy_several(self):
        mode = ("clone", "portable")[self.copy_mode.get_selected()]
        chosen = [row for row, box in self.multi_checks if box.get_active()]
        if len(chosen) < 2:
            self.notify("Choose at least two drives", "Tick two or more drives under Copy to several drives. To make one drive, use Review destination & copy.")
            return
        personal = PERSONAL_CHOICES[self.personal_choice.get_selected()] if mode == "portable" else "mine"
        if personal != "mine":
            self.notify("Several drives carry your own settings", "To make a drive for someone else, copy to one drive at a time. Nothing was changed.")
            return
        store, ventoy = self.store.get_text().strip(), self.ventoy.get_text().strip()
        # Review R1 (P34): the same full or online-only choice as a one-drive Portable tools copy
        variant, variant_words = "", ""
        if mode == "portable":
            variant, variant_words = self._copy_variant(store)
            if not variant:
                return
        try:
            targets = [(str(row["path"]), self._identity(row)) for row in chosen]
            spec = self.backend.copy_several(mode, targets, store, ventoy, variant=variant)
        except ValueError as exc:
            self.notify("These drives cannot be copied to", f"{exc}\n\nNothing was changed.")
            return
        phrases = tuple(f"ERASE {identity}" for _path, identity in targets)
        kind = "Exact whole-device clones" if mode == "clone" else "Portable tools copies (not exact clones)"
        listing = "\n".join(f"- {row['path']} ({row.get('model')}, {identity}, {format_bytes(row.get('size'))})" for row, (_path, identity) in zip(chosen, targets))
        summary = f"{kind} on {len(targets)} drives at the same time\n\n{listing}\n\nMaster: {store}\nSettings on the copies: your own settings, as saved\n{variant_words + chr(10) if variant_words else ''}\nEVERY LISTED DRIVE IS ERASED. Nothing is written until all the drives pass their safety checks. Type each drive's words below."
        self.review("Review several drives", summary, phrases, lambda _secret: self.run(spec))

    def test_new_drive(self):
        drive = self.selected_drive()
        if not drive:
            return
        path = str(drive["path"])
        try:
            identity = self._identity(drive)
        except ValueError as exc:
            self.notify("This drive cannot be tested", f"{exc}\n\nNothing was changed.")
            return
        quick = self.test_depth.get_selected() == 1
        phrase = f"TEST {identity}"
        spec = self.backend.test_drive(path, identity, quick=quick)
        depth = "A quick test checks spots all over the drive." if quick else "A full test checks every part of the drive and takes longer."
        summary = f"Test a new drive\n\nDrive: {path}\nModel: {drive.get('model')}\nSerial/WWN: {identity}\nCapacity it claims: {format_bytes(drive.get('size'))}\n\n{depth}\nTHIS ERASES EVERYTHING ON THE DRIVE. Afterwards it must be set up again before you use it."
        self.review("Review drive test", summary, (phrase,), lambda _secret: self.run(spec))

    def undo_master(self):
        store = self.store.get_text().strip()
        if not store:
            self.notify("Choose the saved master folder", "Choose the private master storage folder first. Nothing was changed.")
            return
        phrase = "UNDO MASTER"
        spec = self.backend.master_undo(store)
        summary = f"Go back to the previous saved master in {store}.\n\nNew drives will be made from the earlier saved master again. It is checked file by file first. The newer saved master is kept, so you can run this again to switch back. No drive is changed."
        self.review("Review master undo", summary, (phrase,), lambda _secret: self.run(spec))

    def open_master_panel(self):
        if self.demo:
            self.append_output("Preview only. The saved master window is not opened.")
            return
        try:
            subprocess.Popen(self.backend.master_panel_command())
        except OSError as exc:
            self.notify("Saved master window unavailable", f"Could not open the saved master window. Nothing was changed.\n\n{exc}")

    def run(self, spec, pending=""):
        self._spec_for_result = spec
        return super().run(spec, pending)

    def _finished(self, result, output):
        # A drive builder that exits 0 without saying the drive was made is shown as NOT made, in plain words.
        super()._finished(honest_result(getattr(self, "_spec_for_result", None), result), output)

    def refresh_big_files(self):
        store = self.store.get_text().strip()
        try:
            spec = self.backend.refresh_master(store)
        except ValueError:
            self.notify("Choose the saved master folder", "Choose the private master storage folder first. Nothing was changed.")
            return
        phrase = "REFRESH BIG FILES"
        summary = f"Bring the big files in the saved master in {store} up to date.\n\nThis can download several gigabytes. Free space is checked first. Every download is checked before it is used. The older saved master is kept, so you can go back with the undo button. No drive is changed, and drives made earlier keep what they have."
        self.review("Review big file refresh", summary, (phrase,), lambda _secret: self.run(spec))

    def add_live_mode(self):
        store = self.store.get_text().strip()
        try:
            spec = self.backend.live_addon(store)
        except ValueError:
            self.notify("Choose the saved master folder", "Choose the private master storage folder first. Nothing was changed.")
            return
        phrase = "ADD LIVE MODE"
        summary = f"Add try-without-installing to the saved master in {store}.\n\nThis downloads Fedora's live image (several gigabytes) and checks it against Fedora's signed list before it is used. Drives made from the saved master after this can start Secure Linux without installing it. No drive is changed now."
        self.review("Review try-without-installing", summary, (phrase,), lambda _secret: self.run(spec))
