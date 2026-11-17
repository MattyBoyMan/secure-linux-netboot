#!/usr/bin/env python3
"""Headless command adapter and lazy native entry for Secure Linux USB Workshop.

No disk discovery, imaging, recovery, partitioning, formatting or copying is
implemented here. Every operation is delegated to the established engines.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
from typing import Any, Sequence

from gui_tools_common import CommandSpec, OperationResult

FS_HELP = {
    "fat32": "FAT32: broad compatibility. Works on large USB disks here, but one file cannot exceed 4 GiB minus 1 byte (4,294,967,295 bytes).",
    "exfat": "exFAT: recommended for large files and exchange between Windows, macOS and Linux. No 4 GiB single-file limit.",
    "ntfs": "NTFS: best for Windows and large files. macOS may need extra software to write it; Windows chkdsk is still recommended after formatting.",
    "ext4": "ext4: best for Linux, with Linux permissions and journaling. Windows and macOS need extra software to use it.",
}
# The main window's "My saved master..." button starts exactly this (the launcher needs no administrator step;
# the saved-master window asks for the password itself, through secure-linux-master-sync).
MASTER_PANEL_ARGV = ["secure-linux-usb-creator-gui", "--master-panel"]
# Whose settings a Portable tools copy carries (the drive builder's --personal), and how deeply a drive is tested.
REFRESH_PARTS = ("fedora", "rescue", "ventoy", "offline", "flipper", "netboot")
PERSONAL_CHOICES = ("mine", "none", "other")
TEST_DEPTHS = ("quick", "full")
# Tools written in Python (they are started with this Python on a test machine that has no executable bit).
PYTHON_TOOLS = ("secure-linux-usb-creator", "secure-linux-usb-multi", "secure-linux-drive-test")
COPY_VARIANTS = ("", "full", "online-only")
# Where this computer keeps its own offline app collection (the drive builder adds it to a full copy).
APP_COLLECTION_DIR = Path("/var/cache/secure-linux/offline/app-bundles")
APP_FOLDER_IN_MASTER = "linux-setup/offline/app-bundles/"
NO_MASTER_WORDS = ("There is no saved master that can be read in that folder, so no drive can be made yet. "
                   "Choose the private master storage folder, or save a master first. Nothing was changed.")
DEMO_DEVICES = [
    {"path": "/dev/demo-source", "model": "Secure Linux finished USB", "serial": "DEMO-SOURCE-001", "wwn": "",
     "size": 64_000_000_000, "free_bytes": 18_000_000_000, "health": True, "mountpoints": []},
    {"path": "/dev/demo-target", "model": "USB 3.2 flash drive", "serial": "DEMO-TARGET-002", "wwn": "",
     "size": 128_000_000_000, "free_bytes": 121_000_000_000, "health": None, "mountpoints": []},
]


class USBBackend:
    """Fixed command adapter. Tests can inject mock-devices without real hardware."""

    def __init__(self, root: Path | None = None, mock_devices: Path | None = None):
        default_root = Path(__file__).resolve().parent.parent
        self.root = root or Path(os.environ.get("SL_ROOT", str(default_root)))
        installed = Path("/usr/local/bin")
        self.bin_dir = self.root / "bin" if (self.root / "bin" / "secure-linux-usb-creator").is_file() else installed
        self.mock_devices = mock_devices

    def _base(self, name: str) -> list[str]:
        path = self.bin_dir / name
        if os.name == "nt":
            if name in PYTHON_TOOLS:
                return [sys.executable, str(path)]
            return [os.environ.get("BASH", "bash"), str(path)]
        return [str(path)]

    def _mock(self) -> list[str]:
        return ["--mock-devices", str(self.mock_devices)] if self.mock_devices else []

    def list_devices(self) -> list[dict[str, Any]]:
        result = subprocess.run(
            [*_base_safe(self._base("secure-linux-usb-creator")), "list", "--json", *self._mock()],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", errors="replace", timeout=45, check=False, shell=False,
        )
        if result.returncode != 0:
            raise RuntimeError((result.stderr or result.stdout or "Drive listing failed").strip())
        payload = json.loads(result.stdout)
        rows = payload.get("devices")
        if not isinstance(rows, list):
            raise RuntimeError("The drive list did not contain a devices list")
        return [row for row in rows if isinstance(row, dict) and row.get("path")]

    def diagnose(self, device: str) -> CommandSpec:
        return CommandSpec([*self._base("secure-linux-usb-fixer"), "diagnose", "--device", device, "--non-interactive"],
                           "Read-only USB diagnosis")

    def image(self, device: str, output: str) -> CommandSpec:
        return CommandSpec([*self._base("secure-linux-usb-fixer"), "image", "--device", device,
                            "--output-dir", output, "--non-interactive"],
                           "Whole-disk safety image with fresh SHA-256 verification",
                           expected=("IMAGE COMPLETE AND VERIFIED",), verified_label="Safety image complete and verified.")

    def recover(self, image: str, output: str, tool: str) -> CommandSpec:
        if tool not in {"photorec", "testdisk"}:
            raise ValueError("Unknown recovery engine")
        return CommandSpec([*self._base("secure-linux-usb-fixer"), "recover", "--image", image,
                            "--output-dir", output, "--recovery-tool", tool, "--non-interactive"],
                           f"Recover files from the verified image using {tool}")

    def repair(self, device: str, image: str, output: str, partition: int) -> CommandSpec:
        phrase = f"REPAIR PARTITION {partition}"
        return CommandSpec([*self._base("secure-linux-usb-fixer"), "repair", "--device", device,
                            "--image", image, "--partition", str(partition), "--output-dir", output,
                            "--confirm-repair", phrase, "--non-interactive"],
                           "Repair a disposable copy, never the original USB or verified image",
                           expected=("REPAIR FINISHED AND READ-BACK CHECK PASSED",),
                           verified_label="The disposable image repair passed its read-back check; no automatic restore occurred.")

    def repair_drive(self, device: str, identity: str) -> CommandSpec:
        """Check and repair the files on a built Secure Linux drive (the fixer's repair-drive action).

        The fixer keeps its own typed confirmation: no --confirm-target and no --non-interactive are passed, so it
        asks for 'TARGET <disk> <serial>' itself. The reviewed phrase is typed by the person in the review window
        and is handed to the fixer's question; the fixer still compares it and refuses anything else.
        """
        if not identity:
            raise ValueError("This drive has no serial or WWN. The existing engine refuses ambiguous destinations.")
        return CommandSpec([*self._base("secure-linux-usb-fixer"), "repair-drive", "--device", device],
                           "Check and repair this drive's files",
                           input_text=f"TARGET {device} {identity}\n")

    def master_panel_command(self) -> list[str]:
        """Command words for the "My saved master..." window (argv is exactly MASTER_PANEL_ARGV)."""
        return list(MASTER_PANEL_ARGV)

    def format(self, device: str, serial: str, filesystem: str, label: str,
               image: str = "", skip_image: bool = False) -> CommandSpec:
        argv = [*self._base("secure-linux-usb-fixer"), "format", "--device", device,
                "--filesystem", filesystem, "--label", label,
                "--confirm-target", f"TARGET {device} {serial}",
                "--confirm-erase", f"ERASE {device}", "--non-interactive"]
        if skip_image:
            argv.append("--skip-image")
        else:
            if not image:
                raise ValueError("A verified image is required unless another backup is explicitly declared")
            argv.extend(("--image", image))
        return CommandSpec(argv, "Format the reviewed whole USB disk", expected=("FORMAT COMPLETED",),
                           verified_label="Formatting completed and the existing engine finished its result checks.")

    def create_master(self, source: str, store: str, source_root: str = "") -> CommandSpec:
        argv = [*self._base("secure-linux-usb-creator"), "create", "--store", store,
                "--source", source, "--non-interactive", *self._mock()]
        if source_root:
            argv.extend(("--source-root", source_root))
        return CommandSpec(argv, "Save or update the verified read-only USB master",
                           expected=("SAVED MASTER VERIFIED",), verified_label="Saved master verified and published.")

    def copy(self, mode: str, target: str, identity: str, store: str,
             resume: str = "new", ventoy: str = "", *, personal: str = "mine", person_file: str = "",
             never_check_online: bool = False, test_drive: str = "", variant: str = "") -> CommandSpec:
        """One destination drive. personal / person_file / never_check_online / test_drive are Portable-copy options.

        The person file is only passed by its path. It is never opened here: the drive builder reads it, and it
        uses only the values written in it (nothing is made up).
        """
        if mode not in {"clone", "portable"}:
            raise ValueError("Unknown copy mode")
        if variant not in COPY_VARIANTS:
            raise ValueError("The copy is a full copy or an online-only copy")
        if variant and mode != "portable":
            raise ValueError("Only a Portable tools copy has a full or online-only choice")
        if resume not in {"new", "resume", "restart"}:
            raise ValueError("Unknown interruption mode")
        if personal not in PERSONAL_CHOICES:
            raise ValueError("Choose whose settings the copy carries: mine, none or other")
        if test_drive and test_drive not in TEST_DEPTHS:
            raise ValueError("The drive test is quick or full")
        if mode == "clone" and (personal != "mine" or person_file or never_check_online or test_drive):
            raise ValueError("An exact clone always carries exactly what the saved master holds. "
                             "Choose a Portable tools copy to change whose settings it carries")
        if personal == "other" and not person_file:
            raise ValueError("A copy for another person needs their settings file")
        if person_file and personal != "other":
            raise ValueError("A settings file is used only for a copy made for another person")
        if person_file.startswith("-"):
            raise ValueError("The settings file path is not valid")
        if test_drive and resume == "resume":
            raise ValueError("A drive test erases the drive, so it cannot be combined with resume")
        argv = [*self._base("secure-linux-usb-creator"), mode, "--store", store,
                "--target", target, "--confirm", f"ERASE {identity}", "--non-interactive", *self._mock()]
        if mode == "portable":
            if not ventoy:
                raise ValueError("The official Ventoy2Disk.sh path is required")
            argv.extend(("--ventoy-installer", ventoy, "--personal", personal))
            if person_file:
                argv.extend(("--person-file", person_file))
            if variant:
                argv.extend(("--variant", variant))
            if never_check_online:
                argv.append("--never-check-online")
            if test_drive:
                argv.extend(("--test-drive", test_drive))
        if resume != "new":
            argv.append(f"--{resume}")
        marker = "VERIFIED CLONE" if mode == "clone" else "VERIFIED PORTABLE TOOLS COPY"
        label = "Exact whole-device clone" if mode == "clone" else "Portable tools copy (not an exact clone)"
        return CommandSpec(argv, label, expected=(marker,), verified_label=f"{label} finished with the engine's full verification.")

    def test_drive(self, device: str, identity: str, quick: bool = False) -> CommandSpec:
        """Test a new drive (C6). This erases the drive; the engine checks the typed words 'TEST <serial>' itself."""
        if not identity:
            raise ValueError("This drive has no serial or WWN. The existing engine refuses ambiguous destinations.")
        if not device or device.startswith("-"):
            raise ValueError("The drive path is not valid")
        argv = [*self._base("secure-linux-drive-test"), "--device", device, "--confirm", f"TEST {identity}", *self._mock()]
        if quick:
            argv.append("--quick")
        return CommandSpec(argv, "Test a new drive: is it really as big as it says?",
                           expected=("DRIVE TEST PASSED:",), verified_label="The drive test passed. The drive is as big as it says.")

    def copy_several(self, mode: str, targets: Sequence[tuple[str, str]], store: str, ventoy: str = "",
                     restart: bool = False) -> CommandSpec:
        """Several destination drives at once (C6): one --target and its own --confirm per drive, in order."""
        if mode not in {"clone", "portable"}:
            raise ValueError("Unknown copy mode")
        if not targets:
            raise ValueError("Choose at least one destination drive")
        paths, identities = set(), set()
        for path, identity in targets:
            if not identity:
                raise ValueError("A drive has no serial or WWN. The existing engine refuses ambiguous destinations.")
            if not path or path.startswith("-"):
                raise ValueError("A drive path is not valid")
            if path in paths or identity in identities:
                raise ValueError("The same drive was chosen twice")
            paths.add(path)
            identities.add(identity)
        argv = [*self._base("secure-linux-usb-multi"), "--store", store, "--mode", mode]
        for path, identity in targets:
            argv.extend(("--target", path, "--confirm", f"ERASE {identity}"))
        if mode == "portable":
            if not ventoy:
                raise ValueError("The official Ventoy2Disk.sh path is required")
            argv.extend(("--ventoy-installer", ventoy))
        if restart:
            argv.append("--restart")
        argv.extend(self._mock())
        label = "Exact whole-device clones" if mode == "clone" else "Portable tools copies (not exact clones)"
        return CommandSpec(argv, f"{label} on {len(targets)} drives at once", expected=("ALL DRIVES VERIFIED",),
                           verified_label="Every drive was made and passed its full check.")

    def master_undo(self, store: str) -> CommandSpec:
        """Go back to the previous saved master (C17). The newer one is kept, so running it again switches back."""
        if not store or store.startswith("-"):
            raise ValueError("Choose the folder that holds the saved master")
        return CommandSpec([*self._base("secure-linux-usb-creator"), "master-undo", "--store", store],
                           "Go back to the previous saved master",
                           expected=("MASTER UNDONE",), verified_label="The previous saved master is current again.")

    def inspect_copy(self, action: str, target: str, store: str) -> CommandSpec:
        if action not in {"measure", "verify", "status"}:
            raise ValueError("Unknown inspection")
        argv = [*self._base("secure-linux-usb-creator"), action, "--store", store,
                "--target", target, *self._mock()]
        expected = ("not merely a sampled check",) if action == "verify" else ()
        return CommandSpec(argv, f"Read-only copy {action}", expected=expected,
                           verified_label="Full read-back verification passed.")

    def master_variant(self, store: str, collection_dir: Path | None = None) -> tuple[str, str]:
        """Which Portable copy fits this saved master: ("full" | "online-only" | "", plain words).

        A master saved on an installed computer is kept without the offline app collection. A full copy of it is
        refused unless this computer has its own collection to add, so the window asks for the online-only copy
        (apps then install with internet). An unreadable master gives "" and a plain message; nothing is guessed.
        """
        try:
            if not store or store.startswith("-"):
                raise ValueError("no store")
            base = Path(store)
            master_id = (base / "current").read_text(encoding="ascii").strip()
            if not master_id or "/" in master_id or "\\" in master_id or master_id.startswith("."):
                raise ValueError("bad id")
            manifest = json.loads((base / "generations" / master_id / "manifest.json").read_text(encoding="utf-8"))
            portable = manifest["portable"]
            files = portable["files"]
            if not isinstance(files, list):
                raise ValueError("bad files")
        except (OSError, ValueError, KeyError, TypeError, UnicodeDecodeError):
            return "", NO_MASTER_WORDS
        if portable.get("captured_variant") != "online-only":
            return "full", "This copy carries the apps that are saved in the master."
        if any(isinstance(row, dict) and str(row.get("path", "")).startswith(APP_FOLDER_IN_MASTER) for row in files):
            return "full", "This copy carries the apps that are saved in the master."
        folder = APP_COLLECTION_DIR if collection_dir is None else collection_dir
        if (Path(folder) / "current.json").is_file():
            return "full", "This copy carries the apps from this computer's own collection."
        return "online-only", ("This saved master has no apps stored in it, so this copy has none either. "
                               "The apps install from the internet when the drive is used.")

    def refresh_master(self, store: str, only: str = "") -> CommandSpec:
        """C9: bring the big files of the saved master up to date (a new saved master; the old one is kept)."""
        if not store or store.startswith("-"):
            raise ValueError("Choose the folder that holds the saved master")
        argv = [*self._base("secure-linux-usb-creator"), "refresh-master", "--store", store, "--yes"]
        if only:
            if any(part not in REFRESH_PARTS for part in only.split(",")):
                raise ValueError("Unknown part to refresh")
            argv.extend(("--only", only))
        return CommandSpec(argv, "Refresh the big files in the saved master",
                           expected=("MASTER REFRESHED", "MASTER ALREADY CURRENT"),
                           verified_label="The saved master has its big files up to date. Drives made earlier are not changed.")

    def live_addon(self, store: str) -> CommandSpec:
        """C9: add the try-without-installing live image to the saved master (checked against Fedora's signed list)."""
        if not store or store.startswith("-"):
            raise ValueError("Choose the folder that holds the saved master")
        return CommandSpec([*self._base("secure-linux-usb-creator"), "live-addon", "--store", store],
                           "Add try-without-installing to the saved master",
                           expected=("LIVE MODE ADDED TO MASTER", "LIVE MODE ALREADY IN MASTER"),
                           verified_label="Try-without-installing is in the saved master. New drives made from it can start without installing.")


def honest_result(spec: CommandSpec | None, result: OperationResult) -> OperationResult:
    """Plain words for a drive that was not made. The tool saying nothing and exiting 0 is never a success."""
    if spec is None or not spec.expected:
        return result
    if result.state == "unverified":
        return OperationResult("unverified", result.returncode, False,
                               "The drive was NOT made. The drive builder stopped without saying it worked, "
                               "so do not use this drive. Read the lines above, then try again.")
    if result.state == "failed":
        return OperationResult("failed", result.returncode, False,
                               f"The drive was NOT made (the tool stopped with status {result.returncode}). "
                               "Read the lines above, then try again. Nothing is claimed as done.")
    return result


def _base_safe(base: list[str]) -> list[str]:
    return list(base)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Secure Linux USB Workshop")
    parser.add_argument("--demo", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--view", choices=("drives", "fixer", "creator"), default="drives")
    parser.add_argument("--mock-devices", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    from usb_tools_gtk import USBWindow, run_native
    return run_native(USBWindow, "org.securelinux.USBWorkshop", [sys.argv[0]],
                      backend=USBBackend(mock_devices=args.mock_devices), demo=args.demo, view=args.view)


if __name__ == "__main__":
    raise SystemExit(main())
