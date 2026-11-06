#!/usr/bin/env python3
"""Safety, discovery, manifest, and metadata primitives for the Flipper companion.

Only Python's standard library is used.  No function in this module assumes that
a removable drive belongs to a connected Flipper; the caller must choose it.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from typing import Any, Iterable, Mapping

# The companion and central release tool share the installed lib/ directory.
# Keep the import usable both from a checkout and /usr/local/lib/secure-linux.
_LIB_DIR = Path(__file__).resolve().parent.parent
if str(_LIB_DIR) not in sys.path:
    sys.path.insert(0, str(_LIB_DIR))
from release_manifest import (  # noqa: E402
    ReleaseError,
    installed_problems,
    load_canonical,
    sha256_bytes as release_sha256_bytes,
    source_problems,
)

SCHEMA_VERSION = 1
COMPANION_VERSION = "1.1.0"
DEFAULT_KIT_VERSION = "kit-2026-11-04-flipper-netboot"
KIT_VERSION_BASIS = "release.json"
ENCRYPTED_SUFFIXES = {".age", ".gpg", ".pgp"}
FLASH_ERASE_NOTICE = (
    "Staging is wiped only on a best-effort basis. Flash storage, SSDs, SD cards, "
    "and copy-on-write filesystems cannot be securely erased by overwriting files."
)


class CompanionError(RuntimeError):
    """A safe, user-facing failure."""


def atomic_replace(source: str | os.PathLike[str], destination: str | os.PathLike[str]) -> None:
    """Publish a fully staged item, tolerating brief Windows scanner locks.

    Only PermissionError is retried, for at most five seconds. Persistent
    permission failures and every other error still stop the operation safely.
    """
    deadline = time.monotonic() + 5.0
    while True:
        try:
            os.replace(source, destination)
            return
        except PermissionError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.05)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def repository_root(module_file: str | os.PathLike[str]) -> Path:
    module = Path(module_file).resolve()
    companion = module.parent
    checkout = module.parents[3]
    if companion == checkout / "linux" / "lib" / "flipper-companion":
        return checkout
    if companion.name == "flipper-companion" and companion.parent.name == "lib":
        installed = companion.parent.parent
        if installed.name == "secure-linux":
            return installed
        payload = installed / "lib" / "secure-linux"
        if payload.is_dir():
            return payload
    return checkout


def metadata_path(root: Path) -> Path:
    if root.name == "secure-linux" and root.parent.name == "lib":
        return root / "lib" / "flipper-companion" / "version.json"
    return root / "linux" / "lib" / "flipper-companion" / "version.json"


def default_pack(root: Path) -> Path:
    """Prefer the rendered pack, but fall back to its source without editing either."""
    rendered = root / "netboot" / "dist" / "flipper"
    source = root / "netboot" / "flipper"
    if (rendered / "apps_data" / "boot2flipper" / "config.b2f").is_file():
        return rendered
    return source


def sha256_file(path: Path, chunk_size: int = 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            block = handle.read(chunk_size)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def _atomic_json(path: Path, value: Mapping[str, Any], mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".flipper-json-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        atomic_replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def safe_relative(value: str) -> str:
    """Return a portable, normalized relative path or reject it.

    SD cards are normally FAT and the companion can also prepare mirrors on
    Windows.  Reject drive/ADS syntax and names Windows trims or reserves;
    otherwise a value such as ``C:/apps`` can alias a different destination
    when pathlib joins its ``C:`` component to a Windows root.
    """
    if not value or "\x00" in value or "\\" in value or value.endswith("/"):
        raise CompanionError("Paths must be non-empty POSIX-style relative paths without a trailing slash.")
    pure = PurePosixPath(value)
    if pure.is_absolute() or any(part in {"", ".", ".."} for part in pure.parts):
        raise CompanionError(f"Unsafe relative path: {value!r}")
    normalized = pure.as_posix()
    if normalized != value:
        raise CompanionError(f"Path is not normalized: {value!r}")
    reserved = {"CON", "PRN", "AUX", "NUL"} | {f"COM{i}" for i in range(1, 10)} | {f"LPT{i}" for i in range(1, 10)}
    for part in pure.parts:
        if ":" in part or part.endswith((" ", ".")) or part.split(".", 1)[0].upper() in reserved:
            raise CompanionError(f"Path is not portable to Windows/FAT: {value!r}")
    if any(part in {".", ".."} for part in Path(value).parts):
        raise CompanionError(f"Unsafe relative path: {value!r}")
    return normalized


def path_inside(root: Path, relative: str, *, allow_root: bool = False) -> Path:
    relative = relative.strip("/") if allow_root and relative.strip("/") == "" else safe_relative(relative)
    root = root.resolve()
    candidate = root.joinpath(*PurePosixPath(relative).parts) if relative else root
    current = root
    for part in PurePosixPath(relative).parts if relative else ():
        current = current / part
        if current.exists() and current.is_symlink():
            raise CompanionError(f"Symbolic links are not accepted: {current}")
    resolved = candidate.resolve(strict=False)
    try:
        resolved.relative_to(root)
    except ValueError as exc:
        raise CompanionError(f"Path escapes its selected root: {relative}") from exc
    return candidate


def ensure_distinct_trees(source: Path, destination: Path) -> None:
    source = source.resolve()
    destination = destination.resolve(strict=False)
    try:
        destination.relative_to(source)
    except ValueError:
        return
    raise CompanionError("The backup/output folder must not be inside the source SD tree.")


def _is_removable(node: Mapping[str, Any], inherited: bool = False) -> bool:
    return inherited or node.get("rm") is True or node.get("rm") == 1


def _mounts(node: Mapping[str, Any]) -> list[str]:
    values: list[str] = []
    many = node.get("mountpoints")
    if isinstance(many, list):
        values.extend(str(item) for item in many if item)
    one = node.get("mountpoint")
    if one:
        values.append(str(one))
    return list(dict.fromkeys(values))


def discover_sd_candidates(runner: Any = subprocess.run) -> list[dict[str, Any]]:
    """List mounted removable filesystems; never label one as certainly Flipper-owned."""
    try:
        result = runner(
            ["lsblk", "-J", "-p", "-o", "NAME,LABEL,SIZE,FSTYPE,RM,TRAN,MOUNTPOINT,MOUNTPOINTS"],
            check=True,
            capture_output=True,
            text=True,
        )
        data = json.loads(result.stdout)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError, TypeError) as exc:
        raise CompanionError("Could not inspect mounted drives with lsblk. Is util-linux installed?") from exc

    candidates: list[dict[str, Any]] = []

    def walk(node: Mapping[str, Any], removable: bool = False) -> None:
        removable = _is_removable(node, removable)
        for mount in _mounts(node):
            if removable:
                candidates.append({
                    "device": node.get("name") or "unknown",
                    "mount": mount,
                    "label": node.get("label") or "(no label)",
                    "size": node.get("size") or "unknown",
                    "filesystem": node.get("fstype") or "unknown",
                    "transport": node.get("tran") or "unknown",
                    "flipper_identity": "unverified; explicit selection required",
                })
        for child in node.get("children") or []:
            walk(child, removable)

    for block in data.get("blockdevices", []):
        walk(block)
    return candidates


def discover_flipper_usb(sys_root: Path | None = None) -> list[dict[str, Any]]:
    """Detect known Flipper USB IDs from sysfs, without opening the device."""
    root = sys_root or Path(os.environ.get("FLIPPER_COMPANION_SYS_ROOT", "/sys/bus/usb/devices"))
    if not root.is_dir():
        return []
    found: list[dict[str, Any]] = []
    for device in sorted(root.iterdir()):
        try:
            vendor = (device / "idVendor").read_text(encoding="ascii").strip().lower()
            product = (device / "idProduct").read_text(encoding="ascii").strip().lower()
        except (OSError, UnicodeError):
            continue
        if vendor != "0483" or product not in {"5740", "df11"}:
            continue

        def read_optional(name: str) -> str:
            try:
                return (device / name).read_text(encoding="utf-8").strip()
            except (OSError, UnicodeError):
                return ""

        manufacturer = read_optional("manufacturer")
        product_name = read_optional("product")
        # DF11 is a bootloader ID. Normal mode needs corroborating Flipper text;
        # this avoids calling every STM32 virtual COM device a Flipper.
        if product == "5740" and "flipper" not in (manufacturer + " " + product_name).lower():
            continue
        found.append({
            "sysfs": str(device),
            "vendor_id": vendor,
            "product_id": product,
            "manufacturer": manufacturer or "unknown",
            "product": product_name or "unknown",
            "mode": "DFU bootloader" if product == "df11" else "USB serial",
            "identity": (
                "Possible Flipper DFU; STM32 DFU IDs are not unique, so physical identity is unverified."
                if product == "df11" else "Flipper USB identification strings matched."
            ),
            "serial_present": bool(read_optional("serial")),
        })
    return found


def companion_status(root: Path, sys_root: Path | None = None, runner: Any = subprocess.run) -> dict[str, Any]:
    try:
        mounts = discover_sd_candidates(runner)
        sd_error = ""
    except CompanionError as exc:
        mounts = []
        sd_error = str(exc)
    metadata = load_metadata(root)
    return {
        "companion_version": COMPANION_VERSION,
        "kit_version": metadata.get("kit_version", "unknown"),
        "host": platform.system(),
        "flipper_usb": discover_flipper_usb(sys_root),
        "mounted_removable_candidates": mounts,
        "sd_detection_error": sd_error,
        "qflipper": shutil.which("qflipper") or shutil.which("qFlipper"),
        "qflipper_cli": shutil.which("qFlipper-cli") or shutil.which("qflipper-cli"),
        "dfu_util": shutil.which("dfu-util"),
        "age": shutil.which("age"),
        "gpg": shutil.which("gpg") or shutil.which("gpg2"),
        "ufbt": shutil.which("ufbt"),
        "note": "A mounted removable drive is only a candidate; its Flipper ownership is not proven.",
        "execution_note": "FAPs run on the Flipper, never as native Linux programs. qFlipper display/control depends on qFlipper and device support.",
        "erase_note": FLASH_ERASE_NOTICE,
    }


def linked_asset_paths(root: Path) -> list[Path]:
    pack = root / "netboot" / "flipper"
    if not pack.is_dir():
        raise CompanionError(f"Flipper source pack is missing: {pack}")
    files = [path for path in pack.rglob("*") if path.is_file()]
    workflow = root / "netboot" / "github-workflows" / "build-flipper-fap.yml"
    if workflow.is_file():
        files.append(workflow)
    return sorted(files)


def _release_for_refresh(root: Path, kit_version: str | None) -> tuple[dict[str, Any], bytes]:
    try:
        manifest, raw = load_canonical(root)
    except ReleaseError as exc:
        raise CompanionError(f"No current central release is available: {exc}") from exc
    problems = source_problems(root, manifest) + installed_problems(root, manifest, raw)
    if problems:
        raise CompanionError(
            "Cannot declare stale source current. Run secure-linux-release stamp first: " + "; ".join(problems)
        )
    release_id = manifest["release_id"]
    if kit_version is not None and kit_version.strip() != release_id:
        raise CompanionError(f"Manual kit labels cannot replace the central release ID ({release_id}).")
    return manifest, raw


def make_metadata(root: Path, kit_version: str | None = None) -> dict[str, Any]:
    manifest, canonical_raw = _release_for_refresh(root, kit_version)
    assets: dict[str, str] = {}
    for path in linked_asset_paths(root):
        assets[path.relative_to(root).as_posix()] = sha256_file(path)
    return {
        "schema_version": SCHEMA_VERSION,
        "companion_version": COMPANION_VERSION,
        "kit_version": manifest["release_id"],
        "kit_version_basis": KIT_VERSION_BASIS,
        "release_id": manifest["release_id"],
        "source_sha256": manifest["source"]["sha256"],
        "release_manifest_sha256": release_sha256_bytes(canonical_raw),
        "refreshed_at": utc_now(),
        "assets": assets,
        "refresh_instructions": "After reviewed payload changes, run: secure-linux-release stamp; regenerate affected USB/netboot/master outputs; then run: secure-linux-release check",
    }


def refresh_metadata(root: Path, kit_version: str | None = None) -> dict[str, Any]:
    metadata = make_metadata(root, kit_version)
    _atomic_json(metadata_path(root), metadata)
    return metadata


def load_metadata(root: Path) -> dict[str, Any]:
    try:
        with metadata_path(root).open(encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise CompanionError("Companion version metadata is missing or unreadable.") from exc
    if value.get("schema_version") != SCHEMA_VERSION:
        raise CompanionError("Unsupported companion metadata schema.")
    return value


def check_metadata(root: Path, check_source: bool = True) -> list[str]:
    metadata = load_metadata(root)
    problems: list[str] = []
    try:
        manifest, canonical_raw = load_canonical(root)
        if check_source:
            problems += source_problems(root, manifest)
            problems += installed_problems(root, manifest, canonical_raw)
        expected_release = {
            "kit_version": manifest["release_id"],
            "release_id": manifest["release_id"],
            "source_sha256": manifest["source"]["sha256"],
            "release_manifest_sha256": release_sha256_bytes(canonical_raw),
        }
        for key, expected_value in expected_release.items():
            if metadata.get(key) != expected_value:
                problems.append(f"Flipper release link has stale/mismatched {key}")
    except ReleaseError as exc:
        problems.append(str(exc))

    expected = metadata.get("assets") or {}
    current_paths = {path.relative_to(root).as_posix(): path for path in linked_asset_paths(root)}
    for name, old_hash in expected.items():
        path = current_paths.get(name)
        if path is None:
            problems.append(f"missing: {name}")
        elif not isinstance(old_hash, str) or sha256_file(path) != old_hash:
            problems.append(f"changed: {name}")
    for name in sorted(set(current_paths) - set(expected)):
        problems.append(f"untracked: {name}")
    return problems


def iter_source_files(source: Path, selection: Iterable[str] | None = None) -> tuple[list[str], list[str]]:
    """Return regular-file and empty-directory relative paths, rejecting links/special files."""
    source = source.resolve()
    if not source.is_dir():
        raise CompanionError(f"Source folder does not exist: {source}")
    roots: list[tuple[Path, str]] = []
    if selection:
        for item in sorted(set(selection)):
            relative = safe_relative(item)
            selected = path_inside(source, relative)
            if not selected.exists():
                raise CompanionError(f"Selected source path is missing: {relative}")
            roots.append((selected, relative))
    else:
        roots.append((source, ""))

    files: set[str] = set()
    directories: set[str] = set()
    nonempty_directories: set[str] = set()
    for selected, relative in roots:
        if selected.is_symlink():
            raise CompanionError(f"Symbolic links are not accepted: {selected}")
        if selected.is_file():
            files.add(relative)
            continue
        if not selected.is_dir():
            raise CompanionError(f"Only regular files and folders are supported: {relative}")
        for current, dirnames, filenames in os.walk(selected, followlinks=False):
            current_path = Path(current)
            for name in list(dirnames):
                child = current_path / name
                if child.is_symlink():
                    raise CompanionError(f"Symbolic links are not accepted: {child}")
                if not child.is_dir():
                    raise CompanionError(f"Special folders are not supported: {child}")
            current_relative = current_path.relative_to(source).as_posix()
            if current_relative != ".":
                directories.add(current_relative)
            if filenames or dirnames:
                nonempty_directories.add(current_relative)
            for name in filenames:
                child = current_path / name
                if child.is_symlink() or not child.is_file():
                    raise CompanionError(f"Only regular files are supported: {child}")
                files.add(child.relative_to(source).as_posix())
    empty = sorted(directories - nonempty_directories)
    return sorted(files), empty


def copy_file_verified(source: Path, destination: Path, expected_hash: str | None = None) -> str:
    """Atomically copy one regular file and verify the destination SHA-256."""
    if source.is_symlink() or not source.is_file():
        raise CompanionError(f"Not a regular source file: {source}")
    source_hash = expected_hash or sha256_file(source)
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".flipper-copy-", dir=destination.parent)
    try:
        with os.fdopen(fd, "wb") as output, source.open("rb") as input_handle:
            shutil.copyfileobj(input_handle, output, length=1024 * 1024)
            output.flush()
            os.fsync(output.fileno())
        copied_hash = sha256_file(Path(temporary))
        if copied_hash != source_hash:
            raise CompanionError(f"Copy verification failed for {source.name}; original left in place.")
        atomic_replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return source_hash


def require_plain_flipper_path(relative: str) -> None:
    suffix = PurePosixPath(relative).suffix.lower()
    if suffix in ENCRYPTED_SUFFIXES:
        raise CompanionError(
            "Encrypted payloads are for computer storage only. Decrypt to protected staging first; "
            "never copy one to the Flipper expecting it to run."
        )


def confirm_change(prompt: str, assume_yes: bool, input_function: Any = input) -> None:
    if assume_yes:
        return
    answer = input_function(prompt + " Type Confirm to proceed: ")
    if answer != "Confirm":
        raise CompanionError("Cancelled. No requested changes were made.")
