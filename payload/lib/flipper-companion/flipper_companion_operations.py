#!/usr/bin/env python3
"""Reviewed install/prepare/build and desktop integration workflows."""
from __future__ import annotations

import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
from dataclasses import dataclass
from typing import Any, Callable, Iterable

from flipper_companion_backup import create_backup
from flipper_companion_core import (
    CompanionError,
    confirm_change,
    copy_file_verified,
    default_pack,
    iter_source_files,
    path_inside,
    require_plain_flipper_path,
    safe_relative,
    sha256_file,
)

Reporter = Callable[[str], None]


def _silent(_: str) -> None:
    return None


@dataclass(frozen=True)
class InstallItem:
    source: Path
    relative: str
    sha256: str


def _item(source: Path, relative: str) -> InstallItem:
    relative = safe_relative(relative)
    require_plain_flipper_path(relative)
    return InstallItem(source=source, relative=relative, sha256=sha256_file(source))


def _collect(source: Path, destination_directory: str) -> list[InstallItem]:
    source = source.expanduser()
    if source.is_symlink() or not source.exists():
        raise CompanionError(f"Install source is missing or is a symbolic link: {source}")
    source = source.resolve()
    destination_directory = safe_relative(destination_directory)
    if source.is_file():
        return [_item(source, f"{destination_directory}/{source.name}")]
    if not source.is_dir():
        raise CompanionError(f"Install source is not a regular file/folder: {source}")
    files, _ = iter_source_files(source)
    return [
        _item(path_inside(source, relative), f"{destination_directory}/{source.name}/{relative}")
        for relative in files
    ]


def make_install_plan(
    sources: Iterable[Path],
    *,
    kind: str,
    destination: str | None,
    app_folder: str | None,
) -> list[InstallItem]:
    sources = list(sources)
    if not sources:
        raise CompanionError("Choose at least one source file or folder.")
    if kind == "fap":
        if not app_folder:
            raise CompanionError("For custom FAPs choose --app-folder (for example USB or Games).")
        base = f"apps/{safe_relative(app_folder)}"
    elif kind == "badusb":
        base = "badusb"
    elif kind == "data":
        if not destination:
            raise CompanionError("For scripts/automations/data choose --dest as the reviewed SD folder.")
        base = safe_relative(destination)
    else:
        raise CompanionError("Install kind must be fap, badusb, or data.")
    items: list[InstallItem] = []
    for source in sources:
        items.extend(_collect(source, base))
    destinations: set[str] = set()
    for item in items:
        if item.relative in destinations:
            raise CompanionError(f"Two sources map to the same destination: {item.relative}")
        destinations.add(item.relative)
        suffix = PurePosixPath(item.relative).suffix.lower()
        if kind == "fap" and suffix != ".fap":
            raise CompanionError("The fap workflow accepts only .fap files. Use data for supporting files.")
        if kind == "badusb" and suffix != ".txt":
            raise CompanionError("The BadUSB workflow accepts reviewed .txt scripts only.")
    return sorted(items, key=lambda entry: entry.relative)


def apply_install_plan(
    items: list[InstallItem],
    targets: list[tuple[str, Path]],
    *,
    safety_backup: Path | None,
    yes: bool,
    root: Path | None,
    reporter: Reporter,
    input_function: Any = input,
) -> dict[str, Any]:
    if not items:
        raise CompanionError("There are no files to install.")
    if not targets:
        raise CompanionError("Choose SD, computer, or both as a destination.")
    targets = [(label, path.expanduser().resolve(strict=False)) for label, path in targets]
    conflicts: dict[str, list[str]] = {}
    unchanged: dict[str, int] = {label: 0 for label, _ in targets}
    reporter("Install review (SHA-256 is calculated before any write):")
    for item in items:
        reporter(f"  {item.sha256}  {item.relative}")
    for label, target_root in targets:
        target_root = target_root.expanduser()
        if label == "sd" and not target_root.is_dir():
            raise CompanionError("The selected SD mount is not available. Detection never guesses a mount.")
        current_conflicts: list[str] = []
        for item in items:
            destination = path_inside(target_root, item.relative)
            if destination.exists() and not destination.is_file():
                raise CompanionError(f"Destination is not a regular file: {destination}")
            if destination.is_file():
                if sha256_file(destination) == item.sha256:
                    unchanged[label] += 1
                else:
                    current_conflicts.append(item.relative)
        if current_conflicts:
            conflicts[label] = current_conflicts
        reporter(f"  {label}: {target_root} — {len(current_conflicts)} differing existing files.")
    if conflicts and safety_backup is None:
        raise CompanionError("Existing files differ. Choose --safety-backup FOLDER; overwrite is never backup-free.")
    reporter("Existing unrelated RogueMaster files are preserved. No files are deleted.")
    reporter(
        "Keep the SD card and computer connected until completion. Power loss can leave a partial install across "
        "destinations; copied files are not rolled back, so rerun and verify after an interruption."
    )
    confirm_change("Review every source, destination, and conflict above.", yes, input_function)

    safety_paths: dict[str, str] = {}
    # Complete every required safety backup before writing to either destination.
    for label, target_root in targets:
        if label in conflicts:
            backup_root = safety_backup.expanduser() / label
            saved = create_backup(
                target_root.expanduser(), backup_root, selection=conflicts[label], root=root, reporter=reporter
            )
            safety_paths[label] = str(saved)
    copied: dict[str, int] = {label: 0 for label, _ in targets}
    for label, target_root in targets:
        target_root.mkdir(parents=True, exist_ok=True)
        for item in items:
            destination = path_inside(target_root, item.relative)
            if destination.is_file() and sha256_file(destination) == item.sha256:
                continue
            copy_file_verified(item.source, destination, item.sha256)
            if sha256_file(destination) != item.sha256:
                raise CompanionError(f"Install verification failed: {destination}")
            copied[label] += 1
        reporter(f"Verified {label} install: {copied[label]} copied, {unchanged[label]} unchanged.")
    return {"copied": copied, "unchanged": unchanged, "safety_backups": safety_paths, "deleted": 0}


def validate_fap(path: Path) -> None:
    size = path.stat().st_size
    if not 1024 <= size <= 16 * 1024 * 1024:
        raise CompanionError("FAP size is outside the 1 KiB–16 MiB sanity range. Compatibility is not inferred.")


def validate_ipxe(path: Path, kind: str) -> None:
    size = path.stat().st_size
    if not 65536 <= size <= 16 * 1024 * 1024:
        raise CompanionError("iPXE file size is outside the 64 KiB–16 MiB sanity range.")
    with path.open("rb") as handle:
        if kind == "efi":
            signature = handle.read(2)
            valid = signature == b"MZ"
        else:
            handle.seek(514)
            signature = handle.read(4)
            valid = signature == b"HdrS"
    if not valid:
        raise CompanionError(f"iPXE {kind} signature check failed; file was not installed.")


def make_prepare_plan(
    pack: Path,
    *,
    fap: Path | None,
    ipxe_efi: Path | None,
    ipxe_lkrn: Path | None,
) -> tuple[list[InstallItem], list[str]]:
    pack = pack.expanduser().resolve()
    items: list[InstallItem] = []
    notes: list[str] = []
    for folder in ("apps_data", "badusb"):
        source_folder = pack / folder
        if not source_folder.is_dir():
            raise CompanionError(f"Flipper pack is incomplete; missing {source_folder}")
        files, _ = iter_source_files(source_folder)
        for relative in files:
            items.append(_item(path_inside(source_folder, relative), f"{folder}/{relative}"))
    config = pack / "apps_data" / "boot2flipper" / "config.b2f"
    if not config.is_file():
        raise CompanionError("Boot2Flipper config.b2f is missing from the selected pack.")
    if fap:
        fap = fap.expanduser().resolve()
        validate_fap(fap)
        items.append(_item(fap, "apps/USB/boot2flipper.fap"))
    else:
        notes.append(
            "boot2flipper.fap was not supplied. Build it with build-fap or use the kit's documented GitHub workflow; no release is assumed."
        )
    if ipxe_efi:
        ipxe_efi = ipxe_efi.expanduser().resolve()
        validate_ipxe(ipxe_efi, "efi")
        items.append(_item(ipxe_efi, "apps_data/boot2flipper/ipxe/ipxe.efi"))
    else:
        notes.append("ipxe.efi not supplied; obtain it from https://boot.ipxe.org/x86_64-efi/ipxe.efi and verify it.")
    if ipxe_lkrn:
        ipxe_lkrn = ipxe_lkrn.expanduser().resolve()
        validate_ipxe(ipxe_lkrn, "lkrn")
        items.append(_item(ipxe_lkrn, "apps_data/boot2flipper/ipxe/ipxe.lkrn"))
    else:
        notes.append("ipxe.lkrn not supplied; obtain it from https://boot.ipxe.org/x86_64-pcbios/ipxe.lkrn and verify it.")
    notes.append("Signature/size checks are sanity checks, not proof of RogueMaster compatibility or upstream authenticity.")
    return items, notes


def prepare_flipper(
    root: Path,
    *,
    pack: Path | None,
    fap: Path | None,
    ipxe_efi: Path | None,
    ipxe_lkrn: Path | None,
    targets: list[tuple[str, Path]],
    safety_backup: Path | None,
    yes: bool,
    reporter: Reporter = _silent,
    input_function: Any = input,
) -> dict[str, Any]:
    items, notes = make_prepare_plan(pack or default_pack(root), fap=fap, ipxe_efi=ipxe_efi, ipxe_lkrn=ipxe_lkrn)
    for note in notes:
        reporter(note)
    return apply_install_plan(
        items, targets, safety_backup=safety_backup, yes=yes, root=root,
        reporter=reporter, input_function=input_function,
    )


TOOLCHAIN_HELP = """No compatible local FAP toolchain was found.
ufbt option: install ufbt from the official Flipper Devices project, then run this command in an app folder containing application.fam:
  python3 -m pip install --user ufbt
RogueMaster option: clone RogueMaster/flipperzero-firmware-wPlugins recursively, put the app in applications_user/APP_NAME, and select --tool fbt --fbt-root FIRMWARE --app-name APP_NAME.
The toolchain may download dependencies. A successful build proves only that the selected toolchain built the FAP; it does not prove compatibility with every RogueMaster release."""


def toolchain_status(root: Path, which: Callable[[str], str | None] = shutil.which) -> dict[str, Any]:
    return {
        "ufbt": which("ufbt"),
        "fbt": str(root / "fbt") if (root / "fbt").is_file() else None,
        "help": TOOLCHAIN_HELP,
    }


def _new_artifacts(folder: Path, name: str | None, before: dict[Path, tuple[int, int]]) -> list[Path]:
    candidates: list[Path] = []
    if not folder.exists():
        return candidates
    for path in folder.rglob("*.fap"):
        if name and path.name != name:
            continue
        if not path.is_file() or path.is_symlink():
            continue
        stat = path.stat()
        marker = (stat.st_mtime_ns, stat.st_size)
        if before.get(path) != marker:
            candidates.append(path)
    return sorted(candidates)


def _snapshot(folder: Path) -> dict[Path, tuple[int, int]]:
    if not folder.exists():
        return {}
    return {
        path: (path.stat().st_mtime_ns, path.stat().st_size)
        for path in folder.rglob("*.fap") if path.is_file() and not path.is_symlink()
    }


def build_fap(
    source: Path,
    output: Path,
    *,
    tool: str,
    fbt_root: Path | None,
    app_name: str | None,
    safety_backup: Path | None,
    yes: bool,
    root: Path | None,
    reporter: Reporter = _silent,
    runner: Any = subprocess.run,
    which: Callable[[str], str | None] = shutil.which,
    input_function: Any = input,
) -> Path:
    source = source.expanduser().resolve()
    output = output.expanduser().resolve(strict=False)
    if not source.is_dir():
        raise CompanionError(f"FAP source folder does not exist: {source}")
    chosen = tool
    ufbt = which("ufbt")
    if chosen == "auto":
        chosen = "ufbt" if ufbt else "fbt" if fbt_root and (fbt_root / "fbt").is_file() else ""
    if chosen not in {"ufbt", "fbt"}:
        raise CompanionError(TOOLCHAIN_HELP)
    if chosen == "ufbt":
        if not ufbt:
            raise CompanionError(TOOLCHAIN_HELP)
        command = [ufbt]
        cwd = source
        search = source
        artifact_name: str | None = None
        if not (source / "application.fam").is_file():
            raise CompanionError("ufbt source must contain application.fam; no compatibility has been assumed.")
    else:
        if not fbt_root or not app_name or not re.fullmatch(r"[A-Za-z0-9_]+", app_name):
            raise CompanionError("fbt requires --fbt-root and a simple --app-name matching the firmware target.")
        fbt_root = fbt_root.expanduser().resolve()
        expected_source = fbt_root / "applications_user" / app_name
        if source != expected_source:
            raise CompanionError(
                f"For fbt, place the reviewed source at {expected_source}; the companion will not silently modify the firmware tree."
            )
        fbt = fbt_root / "fbt"
        if not fbt.is_file():
            raise CompanionError(TOOLCHAIN_HELP)
        command = [str(fbt), f"fap_{app_name}"]
        cwd = fbt_root
        search = fbt_root / "build"
        artifact_name = f"{app_name}.fap"
    output.parent.mkdir(parents=True, exist_ok=True)
    reporter(f"Build review: {' '.join(command)} (working folder {cwd})")
    reporter("The installed toolchain may fetch its own dependencies. Nothing will be published by this companion.")
    confirm_change("Confirm this local build and output folder.", yes, input_function)
    before = _snapshot(search)
    try:
        result = runner(command, cwd=cwd, check=False)
    except OSError as exc:
        raise CompanionError("Could not start the selected FAP toolchain.") from exc
    if result.returncode != 0:
        raise CompanionError(f"FAP toolchain failed with exit code {result.returncode}; no app will be installed.")
    artifacts = _new_artifacts(search, artifact_name, before)
    if len(artifacts) != 1:
        raise CompanionError(
            f"Expected exactly one newly built FAP, found {len(artifacts)}. No compatibility or output has been invented."
        )
    artifact = artifacts[0]
    validate_fap(artifact)
    output.mkdir(parents=True, exist_ok=True)
    destination = output / artifact.name
    if destination.exists():
        if sha256_file(destination) == sha256_file(artifact):
            reporter(f"Build output already matches: {destination}")
            return destination
        if safety_backup is None:
            raise CompanionError("Build output differs. Choose --safety-backup FOLDER before allowing replacement.")
        create_backup(output, safety_backup.expanduser(), selection=[destination.name], root=root, reporter=reporter)
    copy_file_verified(artifact, destination)
    reporter(f"Built and verified: {destination}")
    reporter("Build success is not proof of compatibility with the connected Flipper's exact RogueMaster version.")
    return destination


def launch_qflipper(
    *,
    scale: float,
    use_flatpak: bool = False,
    yes: bool = False,
    reporter: Reporter = _silent,
    which: Callable[[str], str | None] = shutil.which,
    popen: Any = subprocess.Popen,
    input_function: Any = input,
) -> list[str]:
    if not 0.5 <= scale <= 4.0:
        raise CompanionError("qFlipper scale must be between 0.5 and 4.0.")
    if use_flatpak:
        flatpak = which("flatpak")
        if not flatpak:
            raise CompanionError("Flatpak is not installed. Install qFlipper from its official package first.")
        command = [flatpak, "run", "one.flipper.qFlipper"]
    else:
        executable = which("qflipper") or which("qFlipper")
        if not executable:
            raise CompanionError(
                "qFlipper was not found. Install the official qFlipper package, or use --flatpak if its Flatpak is installed."
            )
        command = [executable]
    reporter(f"qFlipper launch review: {' '.join(command)}")
    reporter("Launching qFlipper never proves that firmware was flashed; verify completion in qFlipper and on the Flipper.")
    confirm_change("Confirm launching the installed official qFlipper GUI.", yes, input_function)
    environment = os.environ.copy()
    environment["QT_SCALE_FACTOR"] = str(scale)
    try:
        # No timeout: the companion must not kill a hardware tool during device work.
        popen(command, env=environment)
    except OSError as exc:
        raise CompanionError("qFlipper could not be launched. Check its official installation.") from exc
    reporter(f"qFlipper launched with QT_SCALE_FACTOR={scale}; flash_performed=false.")
    reporter("Use qFlipper's screen/control features only if your qFlipper version and connected device support them.")
    reporter("Ordinary FAPs execute on the Flipper itself, not as native Linux applications.")
    return command


def open_sd_file_manager(
    mount: Path,
    *,
    reporter: Reporter = _silent,
    which: Callable[[str], str | None] = shutil.which,
    popen: Any = subprocess.Popen,
) -> list[str]:
    mount = mount.expanduser().resolve()
    if not mount.is_dir():
        raise CompanionError("The explicitly selected SD mount is not available.")
    for executable, extra in (("xdg-open", []), ("gio", ["open"]), ("dolphin", []), ("nautilus", [])):
        path = which(executable)
        if path:
            command = [path] + extra + [str(mount)]
            try:
                popen(command)
            except OSError as exc:
                raise CompanionError("The desktop file manager could not be opened.") from exc
            reporter(f"Opened the selected SD folder on the larger computer screen: {mount}")
            return command
    raise CompanionError("No supported desktop file manager was found. Open the printed SD path in your file manager.")
