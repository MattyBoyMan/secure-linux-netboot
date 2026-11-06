#!/usr/bin/env python3
"""Genuine stock dolphin resources, real fbt builds, and SD organisation."""
from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import tempfile
from typing import Any, Callable, Iterable
from urllib.parse import urlparse
from urllib.request import Request, urlopen

from flipper_companion_backup import create_backup, restore_backup, verify_backup
from flipper_companion_core import (
    CompanionError,
    _atomic_json,
    atomic_replace,
    confirm_change,
    copy_file_verified,
    iter_source_files,
    path_inside,
    safe_relative,
    sha256_file,
    utc_now,
)
from flipper_companion_roguemaster import _file_records, _validate_resources

STOCK_DIRECTORY = "https://update.flipperzero.one/firmware/directory.json"
STOCK_HOST = "update.flipperzero.one"
SCHEMA_VERSION = 1
MAX_JSON = 8 * 1024 * 1024
MAX_ARCHIVE = 64 * 1024 * 1024
MAX_EXTRACTED = 512 * 1024 * 1024
MAX_MEMBERS = 100_000
FAVOURITE_SUFFIXES = {".nfc", ".sub", ".ir", ".rfid", ".ibtn", ".txt"}
Reporter = Callable[[str], None]


def _silent(_: str) -> None:
    return None


def _check_url(url: str) -> None:
    parsed = urlparse(url)
    if (
        parsed.scheme != "https"
        or (parsed.hostname or "").lower().rstrip(".") != STOCK_HOST
        or parsed.username
        or parsed.password
        or parsed.port not in {None, 443}
    ):
        raise CompanionError("Refusing a nonofficial or non-HTTPS stock-resource URL.")


def _read_limited(response: Any, limit: int) -> bytes:
    data = response.read(limit + 1)
    if len(data) > limit:
        raise CompanionError("Official stock metadata exceeds the safe size limit.")
    return data


def _fetch_json(url: str, opener: Any) -> dict[str, Any]:
    _check_url(url)
    try:
        request = Request(url, headers={"User-Agent": "secure-linux-flipper"})
        with opener(request, timeout=60) as response:
            final = response.geturl() if hasattr(response, "geturl") else url
            _check_url(final)
            value = json.loads(_read_limited(response, MAX_JSON).decode("utf-8"))
    except CompanionError:
        raise
    except (OSError, ValueError, UnicodeError, json.JSONDecodeError) as exc:
        raise CompanionError("Could not retrieve valid official stock firmware metadata.") from exc
    if not isinstance(value, dict):
        raise CompanionError("Official stock firmware metadata has an invalid shape.")
    return value


def _digest(value: Any) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", value):
        raise CompanionError("Official stock asset has no valid SHA-256 digest.")
    return value.lower()


def select_stock_release(directory: dict[str, Any], version: str | None = None) -> dict[str, Any]:
    channels = directory.get("channels")
    if not isinstance(channels, list):
        raise CompanionError("Official stock directory has no channels.")
    stable = next((item for item in channels if isinstance(item, dict) and item.get("id") == "release"), None)
    versions = stable.get("versions") if stable else None
    if not isinstance(versions, list) or not versions:
        raise CompanionError("Official stable stock channel has no versions.")
    selected = None
    for candidate in versions:
        if isinstance(candidate, dict) and (version is None or candidate.get("version") == version):
            selected = candidate
            break
    if selected is None:
        raise CompanionError("The requested stock version is not present in the official stable directory; no substitute was chosen.")
    name = selected.get("version")
    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,100}", name):
        raise CompanionError("Official stock release version is invalid.")
    files = selected.get("files")
    if not isinstance(files, list):
        raise CompanionError("Official stock release has no files.")
    assets: dict[str, dict[str, Any]] = {}
    for kind in ("resources_tgz", "full_json"):
        candidates = [item for item in files if isinstance(item, dict) and item.get("type") == kind and item.get("target") == "f7"]
        if len(candidates) != 1:
            raise CompanionError(f"Expected one official f7 {kind} asset.")
        asset = candidates[0]
        url = asset.get("url")
        if not isinstance(url, str):
            raise CompanionError("Official stock asset URL is missing.")
        _check_url(url)
        assets[kind] = {"url": url, "sha256": _digest(asset.get("sha256")), "target": "f7", "type": kind}
    timestamp = selected.get("timestamp")
    if isinstance(timestamp, bool) or not isinstance(timestamp, int) or timestamp < 0:
        raise CompanionError("Official stock release timestamp is invalid.")
    return {
        "version": name,
        "timestamp": timestamp,
        "release_date": datetime.fromtimestamp(timestamp, timezone.utc).isoformat(),
        "assets": assets,
        "source": STOCK_DIRECTORY,
        "authentication": "Authenticated HTTPS and official directory SHA-256; not a separate publisher-signature verification.",
    }


def _download(url: str, expected_hash: str, destination: Path, opener: Any) -> None:
    _check_url(url)
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".stock-download-", dir=destination.parent)
    digest = hashlib.sha256()
    size = 0
    try:
        with os.fdopen(fd, "wb") as output:
            try:
                with opener(Request(url, headers={"User-Agent": "secure-linux-flipper"}), timeout=60) as response:
                    final = response.geturl() if hasattr(response, "geturl") else url
                    _check_url(final)
                    while True:
                        block = response.read(1024 * 1024)
                        if not block:
                            break
                        size += len(block)
                        if size > MAX_ARCHIVE:
                            raise CompanionError("Official stock asset exceeds the safe download limit.")
                        digest.update(block)
                        output.write(block)
                output.flush()
                os.fsync(output.fileno())
            except CompanionError:
                raise
            except OSError as exc:
                raise CompanionError("Official stock asset download failed.") from exc
        if digest.hexdigest() != expected_hash:
            raise CompanionError("Official stock asset SHA-256 does not match the directory metadata.")
        atomic_replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def assess_stock_compatibility(device: dict[str, Any], release: dict[str, Any], full_json: dict[str, Any]) -> tuple[bool, list[str]]:
    """Require device evidence for the exact official build; never infer RM compatibility."""
    reasons: list[str] = []
    origin = (device.get("firmware_origin_fork") or "").casefold()
    origin_git = (device.get("firmware_origin_git") or "").lower()
    if origin != "official" or "github.com/flipperdevices/flipperzero-firmware" not in origin_git:
        reasons.append("Device origin is not the official Flipper Devices firmware; RogueMaster/stock API equivalence is not proven.")
    if device.get("firmware_version") != release["version"] or full_json.get("firmware_branch") != release["version"]:
        reasons.append("Device-reported version and official package branch do not exactly match.")
    if str(device.get("hardware_target")) != "7" or full_json.get("firmware_target") != 7:
        reasons.append("Device and official package hardware targets do not match target 7.")
    if not device.get("firmware_api_major") or not device.get("firmware_api_minor") and device.get("firmware_api_minor") != "0":
        reasons.append("Device-reported firmware API major/minor is unavailable.")
    if not device.get("firmware_build_date") or device.get("firmware_build_date") != full_json.get("firmware_build_date"):
        reasons.append("Device and official package build dates do not exactly match.")
    return not reasons, reasons


def _extract_resources(archive: Path, destination: Path) -> None:
    temporary = Path(tempfile.mkdtemp(prefix=".stock-extract-", dir=destination.parent))
    total = 0
    seen: set[str] = set()
    folded: set[str] = set()
    try:
        with tarfile.open(archive, "r:*") as tar:
            members = tar.getmembers()
            if len(members) > MAX_MEMBERS:
                raise CompanionError("Stock archive contains too many entries.")
            for member in members:
                name = member.name
                if "\\" in name or "\x00" in name:
                    raise CompanionError("Stock archive contains an unsafe path.")
                directory = name.endswith("/")
                stripped = name.rstrip("/") if directory else name
                if stripped == "resources":
                    if not member.isdir():
                        raise CompanionError("Stock archive resources root is invalid.")
                    continue
                if not stripped.startswith("resources/"):
                    raise CompanionError("Stock resource archive contains content outside its resources/ root.")
                relative = safe_relative(stripped[len("resources/"):])
                if relative in seen or relative.casefold() in folded:
                    raise CompanionError("Stock archive contains duplicate/case-colliding paths.")
                seen.add(relative)
                folded.add(relative.casefold())
                if member.issym() or member.islnk() or not (member.isfile() or member.isdir()):
                    raise CompanionError("Stock archive links and special files are refused.")
                target = path_inside(temporary, relative)
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                total += member.size
                if member.size < 0 or total > MAX_EXTRACTED:
                    raise CompanionError("Stock archive expands beyond the safe limit.")
                target.parent.mkdir(parents=True, exist_ok=True)
                source = tar.extractfile(member)
                if source is None:
                    raise CompanionError("Stock archive file is unreadable.")
                with source, target.open("xb") as output:
                    shutil.copyfileobj(source, output, length=1024 * 1024)
                if target.stat().st_size != member.size:
                    raise CompanionError("Stock archive extracted size mismatch.")
        atomic_replace(temporary, destination)
    except CompanionError:
        raise
    except (OSError, tarfile.TarError) as exc:
        raise CompanionError("Official stock resource archive is unreadable or unsafe.") from exc
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def prepare_stock_resources(
    work_dir: Path,
    device: dict[str, Any],
    *,
    version: str | None = None,
    opener: Any = urlopen,
    require_compatible: bool = False,
) -> Path:
    directory = _fetch_json(STOCK_DIRECTORY, opener)
    release = select_stock_release(directory, version or device.get("firmware_version"))
    destination = work_dir.expanduser().resolve(strict=False) / release["version"]
    if destination.exists() and any(destination.iterdir()):
        raise CompanionError("Stock work directory is nonempty; choose a new directory rather than mixing releases.")
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / "resources.tgz"
    metadata_path = destination / "full.json"
    try:
        _download(release["assets"]["resources_tgz"]["url"], release["assets"]["resources_tgz"]["sha256"], archive, opener)
        _download(release["assets"]["full_json"]["url"], release["assets"]["full_json"]["sha256"], metadata_path, opener)
        try:
            full_json = json.loads(metadata_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise CompanionError("Official full firmware metadata is invalid.") from exc
        if not isinstance(full_json, dict):
            raise CompanionError("Official full firmware metadata has an invalid shape.")
        compatible, reasons = assess_stock_compatibility(device, release, full_json)
        if require_compatible and not compatible:
            raise CompanionError("Stock restoration compatibility was not proven: " + " ".join(reasons))
        resources = destination / "resources"
        _extract_resources(archive, resources)
        resource_manifest = _validate_resources(resources)
        state = {
            "schema_version": SCHEMA_VERSION,
            "created_at": utc_now(),
            "release": release,
            "full_json": full_json,
            "resource_manifest": resource_manifest,
            "resource_files": _file_records(resources),
            "compatibility_at_download": compatible,
            "compatibility_reasons": reasons,
            "compatibility_note": "Download-time assessment is informational only; restoration re-reads and reassesses the actual device.",
        }
        _atomic_json(destination / "stock.json", state)
    except Exception:
        shutil.rmtree(destination, ignore_errors=True)
        raise
    return destination


def _load_stock(stock_dir: Path) -> dict[str, Any]:
    try:
        state = json.loads((stock_dir / "stock.json").read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise CompanionError("Stock resource journal is missing or invalid.") from exc
    if not isinstance(state, dict) or state.get("schema_version") != SCHEMA_VERSION:
        raise CompanionError("Unsupported stock resource journal.")
    for record in state.get("resource_files") or []:
        source = path_inside(stock_dir / "resources", record["path"])
        if not source.is_file() or sha256_file(source) != record["sha256"]:
            raise CompanionError(f"Cached stock resource verification failed: {record['path']}")
    return state


def _flipper_fields(path: Path) -> list[tuple[str, str]]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        raise CompanionError(f"Animation metadata is unreadable: {path}") from exc
    fields: list[tuple[str, str]] = []
    for line in lines:
        if not line.strip() or ":" not in line:
            continue
        key, value = line.split(":", 1)
        fields.append((key.strip(), value.strip()))
    return fields


def _dolphin_directory(resources: Path) -> Path:
    """Accept an SD resource root or fbt's direct dolphin source/output folder."""
    return resources if (resources / "manifest.txt").is_file() else resources / "dolphin"


def _manifest_entries(resources: Path) -> list[dict[str, str]]:
    dolphin = _dolphin_directory(resources)
    manifest = dolphin / "manifest.txt"
    fields = _flipper_fields(manifest)
    if len(fields) < 2 or fields[:2] != [("Filetype", "Flipper Animation Manifest"), ("Version", "1")]:
        raise CompanionError("Dolphin manifest header/version is unsupported.")
    entries: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    expected = ("Name", "Min butthurt", "Max butthurt", "Min level", "Max level", "Weight")
    for key, value in fields[2:]:
        if key == "Name":
            if current is not None:
                entries.append(current)
            current = {}
        if current is None or key not in expected or key in current:
            raise CompanionError("Dolphin manifest entry is malformed.")
        current[key] = value
    if current is not None:
        entries.append(current)
    if not entries:
        raise CompanionError("Dolphin manifest has no animations.")
    names: set[str] = set()
    for entry in entries:
        if set(entry) != set(expected):
            raise CompanionError("Dolphin manifest entry is incomplete.")
        name = entry["Name"]
        if PurePosixPath(name).name != name or name in names:
            raise CompanionError("Dolphin manifest has an unsafe or duplicate animation name.")
        safe_relative("dolphin/" + name + "/meta.txt")
        if not (dolphin / name / "meta.txt").is_file():
            raise CompanionError(f"Dolphin animation metadata is missing: {name}")
        names.add(name)
    return entries


def preview_animations(resources: Path, names: Iterable[str] | None = None) -> list[dict[str, Any]]:
    selected = set(names or [])
    dolphin = _dolphin_directory(resources)
    previews: list[dict[str, Any]] = []
    for entry in _manifest_entries(resources):
        name = entry["Name"]
        if selected and name not in selected:
            continue
        folder = dolphin / name
        meta = dict(_flipper_fields(folder / "meta.txt"))
        if meta.get("Filetype") != "Flipper Animation" or meta.get("Version") != "1":
            raise CompanionError(f"Unsupported animation meta header: {name}")
        frames = sorted(path.name for path in folder.iterdir() if path.is_file() and re.fullmatch(r"frame_\d+\.(?:bm|png)", path.name))
        if not frames:
            raise CompanionError(f"Animation has no supported frame files: {name}")
        source_pngs = [str(folder / frame) for frame in frames if frame.endswith(".png")]
        previews.append({
            "name": name,
            "manifest": entry,
            "meta": meta,
            "frame_count": len(frames),
            "visual_preview": source_pngs,
            "visual_preview_status": "matching source PNG frames" if source_pngs else "metadata only; no verified .bm visual decoder is bundled",
        })
    if selected and selected != {item["name"] for item in previews}:
        raise CompanionError("One or more selected animations do not exist in the genuine resource manifest.")
    return previews


def _atomic_bytes(destination: Path, data: bytes) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".animation-manifest-", dir=destination.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        if sha256_file(Path(temporary)) != hashlib.sha256(data).hexdigest():
            raise CompanionError("Generated manifest verification failed.")
        atomic_replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def restore_stock_animations(
    stock_dir: Path,
    sd: Path,
    device: dict[str, Any],
    *,
    animations: Iterable[str],
    backup_dir: Path,
    yes: bool = False,
    root: Path | None = None,
    reporter: Reporter = _silent,
    input_function: Any = input,
) -> dict[str, Any]:
    stock_dir = stock_dir.expanduser().resolve()
    sd = sd.expanduser().resolve()
    state = _load_stock(stock_dir)
    compatible, reasons = assess_stock_compatibility(device, state["release"], state["full_json"])
    if not compatible:
        raise CompanionError("Stock restoration refused: " + " ".join(reasons))
    selected = list(dict.fromkeys(animations))
    if not selected:
        raise CompanionError("Select at least one genuine stock animation.")
    previews = preview_animations(stock_dir / "resources", selected)
    selected_names = set(selected)
    existing_entries: list[dict[str, str]] = []
    if (sd / "dolphin" / "manifest.txt").is_file():
        existing_entries = [entry for entry in _manifest_entries(sd) if entry["Name"] not in selected_names]
    for preview in previews:
        reporter(json.dumps(preview, indent=2, sort_keys=True))
    reporter("Visual preview is limited to genuine matching PNG sources; compiled .bm frames receive metadata-only preview.")
    reporter("Only selected SD dolphin animations and the merged external manifest change. Internal/blocking splash screens are firmware-compiled and are not restored by this workflow.")
    backup = create_backup(sd, backup_dir, root=root, reporter=reporter)
    verify_backup(backup)
    confirm_change("Confirm the selected stock animations, exact SD path, preview, and full backup.", yes, input_function)
    copied: list[dict[str, str]] = []
    added: list[dict[str, str]] = []
    resources = stock_dir / "resources"
    for preview in previews:
        name = preview["name"]
        files, _ = iter_source_files(resources / "dolphin" / name)
        for relative in files:
            destination_relative = f"dolphin/{name}/{relative}"
            source = path_inside(resources, destination_relative)
            destination = path_inside(sd, destination_relative)
            existed = destination.exists()
            digest = copy_file_verified(source, destination)
            record = {"path": destination_relative, "sha256": digest}
            copied.append(record)
            if not existed:
                added.append(record)
    selected_entries = [entry for entry in _manifest_entries(resources) if entry["Name"] in selected]
    lines = ["Filetype: Flipper Animation Manifest", "Version: 1", ""]
    for entry in existing_entries + selected_entries:
        for key in ("Name", "Min butthurt", "Max butthurt", "Min level", "Max level", "Weight"):
            lines.append(f"{key}: {entry[key]}")
        lines.append("")
    manifest_data = ("\n".join(lines)).encode("utf-8")
    if not (sd / "dolphin" / "manifest.txt").exists():
        added.append({"path": "dolphin/manifest.txt", "sha256": hashlib.sha256(manifest_data).hexdigest()})
    _atomic_bytes(sd / "dolphin" / "manifest.txt", manifest_data)
    journal = {
        "schema_version": SCHEMA_VERSION,
        "created_at": utc_now(),
        "stock_version": state["release"]["version"],
        "backup": str(backup),
        "selected": selected,
        "copied": copied,
        "companion_added_files": added,
        "deleted": 0,
        "firmware_changed": False,
    }
    journal_path = stock_dir / "restorations" / (backup.name + ".json")
    _atomic_json(journal_path, journal)
    return {
        "status": "stock-animations-restored",
        "selected": selected,
        "copied": len(copied),
        "backup": str(backup),
        "rollback_journal": str(journal_path),
        "custom_files_deleted": 0,
        "firmware_or_internal_screen_changed": False,
    }


def rollback_stock_animations(
    journal_path: Path,
    sd: Path,
    *,
    safety_backup: Path,
    yes: bool = False,
    root: Path | None = None,
    reporter: Reporter = _silent,
    input_function: Any = input,
) -> dict[str, Any]:
    try:
        journal = json.loads(journal_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise CompanionError("Stock rollback journal is invalid.") from exc
    if journal.get("schema_version") != SCHEMA_VERSION:
        raise CompanionError("Unsupported stock rollback journal.")
    backup = Path(journal["backup"])
    verify_backup(backup)
    result = restore_backup(backup, sd, safety_backup=safety_backup, yes=yes, root=root, reporter=reporter, input_function=input_function)
    removed: list[str] = []
    retained: list[str] = []
    for record in journal.get("companion_added_files") or []:
        relative = safe_relative(record["path"])
        path = path_inside(sd, relative)
        if path.is_file() and not path.is_symlink() and sha256_file(path) == record["sha256"]:
            path.unlink()
            removed.append(relative)
        elif path.exists():
            retained.append(relative)
    for current, directories, files in os.walk(sd / "dolphin", topdown=False):
        folder = Path(current)
        if folder != sd / "dolphin":
            try:
                folder.rmdir()
            except OSError:
                pass
    return {**result, "companion_added_files_removed": removed, "changed_added_files_retained": retained, "firmware_rolled_back": False}


def build_custom_animations(
    fbt_root: Path,
    output: Path,
    *,
    runner: Any = subprocess.run,
    reporter: Reporter = _silent,
) -> dict[str, Any]:
    """Run the real source tree's fbt dolphin_ext target and require new output."""
    fbt_root = fbt_root.expanduser().resolve()
    output = output.expanduser().resolve(strict=False)
    try:
        output.relative_to(fbt_root)
        raise CompanionError("Custom animation output must be outside the firmware source/build tree.")
    except ValueError:
        pass
    source = fbt_root / "assets" / "dolphin" / "external"
    fbt = next((path for path in (fbt_root / "fbt", fbt_root / "fbt.cmd") if path.is_file()), None)
    if fbt is None or not (fbt_root / "scripts" / "assets.py").is_file() or not (fbt_root / "scripts" / "flipper" / "assets" / "dolphin.py").is_file():
        raise CompanionError("A compatible source tree with fbt and official dolphin asset tooling is required; no custom build was attempted.")
    previews = preview_animations(source)
    for preview in previews:
        if not preview["visual_preview"]:
            raise CompanionError("Custom animation source must contain genuine matching frame_N.png files; fbt input was not inferred from .bm files.")
    build = fbt_root / "build"
    before = {str(path): sha256_file(path) for path in build.rglob("*") if path.is_file() and path.suffix in {".bm", ".txt"}} if build.exists() else {}
    command = [str(fbt), "dolphin_ext"]
    reporter("Running the reviewed source tree's real fbt dolphin_ext target; dependencies may be fetched by that toolchain.")
    try:
        result = runner(command, cwd=fbt_root, check=False, capture_output=True, text=True)
    except OSError as exc:
        raise CompanionError("Could not start fbt; custom animation build dependencies are unavailable.") from exc
    if result.returncode != 0:
        raise CompanionError(f"fbt dolphin_ext exited {result.returncode}; no successful custom animation build is claimed.")
    candidates: list[Path] = []
    if build.exists():
        for manifest in build.rglob("manifest.txt"):
            folder = manifest.parent
            if not list(folder.glob("*/frame_*.bm")):
                continue
            changed = False
            for path in folder.rglob("*"):
                if path.is_file() and path.suffix in {".bm", ".txt"}:
                    key = str(path)
                    if key not in before or before[key] != sha256_file(path):
                        changed = True
                        break
            if changed:
                candidates.append(folder)
    if len(candidates) != 1:
        raise CompanionError("fbt finished but exactly one new/changed dolphin output could not be established; stale output is not accepted.")
    generated = candidates[0]
    preview_animations(generated)
    if output.exists() and any(output.iterdir()):
        raise CompanionError("Custom animation output is nonempty; choose a new folder.")
    output.mkdir(parents=True, exist_ok=True)
    files, _ = iter_source_files(generated)
    for relative in files:
        copy_file_verified(path_inside(generated, relative), path_inside(output, relative))
    return {
        "status": "custom-animations-built",
        "command": command,
        "output": str(output),
        "animations": [item["name"] for item in preview_animations(output)],
        "file_count": len(files),
        "compatibility": "Build output only. Exact installed-firmware/source commit and API compatibility still require separate device/source verification.",
        "flash_or_sd_write_performed": False,
    }


def organise_favourites(
    sd: Path,
    entries: Iterable[str],
    *,
    backup_dir: Path,
    yes: bool = False,
    root: Path | None = None,
    reporter: Reporter = _silent,
    input_function: Any = input,
) -> dict[str, Any]:
    sd = sd.expanduser().resolve()
    normalised: list[str] = []
    for entry in entries:
        if not isinstance(entry, str) or not entry.startswith("/any/") or len(entry) > 512:
            raise CompanionError("Favourites must be existing /any/... paths, not arbitrary commands or app names.")
        relative = safe_relative(entry[len("/any/"):])
        if PurePosixPath(relative).suffix.lower() not in FAVOURITE_SUFFIXES:
            raise CompanionError("This favourites writer accepts only researched data/script formats; arbitrary FAP favourites are not assumed.")
        if not path_inside(sd, relative).is_file() or path_inside(sd, relative).is_symlink():
            raise CompanionError(f"Favourite target does not exist on the selected SD: {entry}")
        normalised.append("/any/" + relative)
    normalised = list(dict.fromkeys(normalised))
    if not normalised or len(normalised) > 64:
        raise CompanionError("Choose between 1 and 64 favourites.")
    reporter("Favourites preview (newline-separated /any/... entries):")
    for entry in normalised:
        reporter("  " + entry)
    backup = create_backup(sd, backup_dir, root=root, reporter=reporter)
    verify_backup(backup)
    confirm_change("Confirm these favourites, exact SD path, and full backup.", yes, input_function)
    data = ("\n".join(normalised) + "\n").encode("utf-8")
    _atomic_bytes(sd / "favorites.txt", data)
    return {
        "status": "favourites-organised",
        "favourites": normalised,
        "backup": str(backup),
        "mechanism": "Firmware-supported /ext/favorites.txt with existing /any/... data/script targets",
        "fap_support_assumed": False,
        "rollback": "Restore the full backup with the companion's verified restore workflow.",
    }


def organise_key_apps(
    sd: Path,
    assignments: dict[str, Iterable[str]],
    *,
    backup_dir: Path,
    yes: bool = False,
    root: Path | None = None,
    reporter: Reporter = _silent,
    input_function: Any = input,
) -> dict[str, Any]:
    """Copy reviewed FAPs into curated folders; originals are never deleted."""
    sd = sd.expanduser().resolve()
    plan: list[tuple[str, str, str]] = []
    for category, sources in assignments.items():
        category = safe_relative(category)
        if "/" in category or category in {".", ".."}:
            raise CompanionError("App category must be one safe folder name.")
        for source_relative in sources:
            source_relative = safe_relative(source_relative)
            if PurePosixPath(source_relative).suffix.lower() != ".fap":
                raise CompanionError("Curated key-app organisation accepts only .fap files.")
            source = path_inside(sd, source_relative)
            if not source.is_file() or source.is_symlink():
                raise CompanionError(f"Key app is missing: {source_relative}")
            destination = f"apps/{category}/{PurePosixPath(source_relative).name}"
            plan.append((source_relative, destination, sha256_file(source)))
    if not plan:
        raise CompanionError("Choose at least one FAP/category assignment.")
    if len({item[1].casefold() for item in plan}) != len(plan):
        raise CompanionError("Two key apps map to the same curated destination.")
    for source, destination, digest in plan:
        reporter(f"  {digest}  {source} -> {destination} (original preserved)")
    backup = create_backup(sd, backup_dir, root=root, reporter=reporter)
    verify_backup(backup)
    confirm_change("Confirm curated app copies, exact SD path, and full backup; originals remain.", yes, input_function)
    for _, destination, digest in plan:
        source_relative = next(item[0] for item in plan if item[1] == destination)
        copy_file_verified(path_inside(sd, source_relative), path_inside(sd, destination), digest)
    return {
        "status": "key-apps-copied-to-curated-folders",
        "copies": [{"source": source, "destination": destination, "sha256": digest} for source, destination, digest in plan],
        "originals_deleted": 0,
        "backup": str(backup),
        "keybind_note": "RogueMaster desktop keybinds live in internal /int/.desktop_keybinds.txt, not on SD. Configure them through RogueMaster CFW Settings; this SD workflow does not fake that internal write.",
        "qflipper_note": "Curated /ext/apps/<category>/ folders and /ext/favorites.txt are accessible through qFlipper's file manager.",
    }


def accessibility_recommendations() -> dict[str, Any]:
    return {
        "qflipper_scale": 1.5,
        "launch_command": "secure-linux-flipper qflipper --scale 1.5",
        "safe_features": [
            "Use qFlipper screen streaming and remote control instead of patching Flipper apps.",
            "qFlipper 1.3 provides keyboard navigation, lefty mode, font antialiasing, and DPI improvements; availability depends on the installed qFlipper version/platform.",
            "Keep the companion's explicit text previews, confirmations, and unavailable-field labels.",
        ],
        "not_performed": "No firmware app binaries, fonts, display settings, or accessibility services were modified.",
    }
