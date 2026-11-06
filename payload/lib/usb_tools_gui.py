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
from typing import Any

from gui_tools_common import CommandSpec

FS_HELP = {
    "fat32": "FAT32: broad compatibility. Works on large USB disks here, but one file cannot exceed 4 GiB minus 1 byte (4,294,967,295 bytes).",
    "exfat": "exFAT: recommended for large files and exchange between Windows, macOS and Linux. No 4 GiB single-file limit.",
    "ntfs": "NTFS: best for Windows and large files. macOS may need extra software to write it; Windows chkdsk is still recommended after formatting.",
    "ext4": "ext4: best for Linux, with Linux permissions and journaling. Windows and macOS need extra software to use it.",
}
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
            if name == "secure-linux-usb-creator":
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
             resume: str = "new", ventoy: str = "") -> CommandSpec:
        if mode not in {"clone", "portable"}:
            raise ValueError("Unknown copy mode")
        if resume not in {"new", "resume", "restart"}:
            raise ValueError("Unknown interruption mode")
        argv = [*self._base("secure-linux-usb-creator"), mode, "--store", store,
                "--target", target, "--confirm", f"ERASE {identity}", "--non-interactive", *self._mock()]
        if mode == "portable":
            if not ventoy:
                raise ValueError("The official Ventoy2Disk.sh path is required")
            argv.extend(("--ventoy-installer", ventoy))
        if resume != "new":
            argv.append(f"--{resume}")
        marker = "VERIFIED CLONE" if mode == "clone" else "VERIFIED PORTABLE TOOLS COPY"
        label = "Exact whole-device clone" if mode == "clone" else "Portable tools copy (not an exact clone)"
        return CommandSpec(argv, label, expected=(marker,), verified_label=f"{label} finished with the engine's full verification.")

    def inspect_copy(self, action: str, target: str, store: str) -> CommandSpec:
        if action not in {"measure", "verify", "status"}:
            raise ValueError("Unknown inspection")
        argv = [*self._base("secure-linux-usb-creator"), action, "--store", store,
                "--target", target, *self._mock()]
        expected = ("not merely a sampled check",) if action == "verify" else ()
        return CommandSpec(argv, f"Read-only copy {action}", expected=expected,
                           verified_label="Full read-back verification passed.")


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
