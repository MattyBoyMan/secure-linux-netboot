#!/usr/bin/env python3
"""Verified, resumable RogueMaster release and SD-update workflows.

Only official RogueMaster release assets are accepted.  The GitHub API digest
authenticates the downloaded asset; it is not a publisher signature.  No
function here talks to a Flipper directly or claims that a flash succeeded.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import tempfile
from typing import Any, Callable
from urllib.parse import urlparse
from urllib.request import Request, urlopen
import zlib

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
from flipper_companion_operations import launch_qflipper

RELEASE_API = "https://api.github.com/repos/RogueMaster/flipperzero-firmware-wPlugins/releases/latest"
BRANCH_API = "https://api.github.com/repos/RogueMaster/flipperzero-firmware-wPlugins/branches/420"
STATE_NAME = "state.json"
METADATA_NAME = "release.json"
ARCHIVE_NAME = "package.tgz"
SCHEMA_VERSION = 1
MAX_METADATA_BYTES = 2 * 1024 * 1024
MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
MAX_EXTRACTED_BYTES = 2 * 1024 * 1024 * 1024
MAX_MEMBERS = 100_000
ASSET_HOSTS = {
    "github.com",
    "release-assets.githubusercontent.com",
    "objects.githubusercontent.com",
    "objects-origin.githubusercontent.com",
}
Reporter = Callable[[str], None]


def _silent(_: str) -> None:
    return None


def _https_host(url: str, allowed: set[str]) -> str:
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower().rstrip(".")
    if parsed.scheme != "https" or parsed.username or parsed.password or host not in allowed:
        raise CompanionError(f"Refusing an unapproved or non-HTTPS URL: {url}")
    if parsed.port not in {None, 443}:
        raise CompanionError("Refusing a nonstandard network port for RogueMaster downloads.")
    return host


def _request(url: str) -> Request:
    return Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "secure-linux-flipper"})


def _read_response(response: Any, limit: int) -> bytes:
    data = response.read(limit + 1)
    if len(data) > limit:
        raise CompanionError("The official response exceeded the permitted size.")
    return data


def _fetch_json(url: str, opener: Any) -> dict[str, Any]:
    _https_host(url, {"api.github.com"})
    try:
        with opener(_request(url), timeout=60) as response:
            final_url = response.geturl() if hasattr(response, "geturl") else url
            _https_host(final_url, {"api.github.com"})
            raw = _read_response(response, MAX_METADATA_BYTES)
        value = json.loads(raw.decode("utf-8"))
    except CompanionError:
        raise
    except (OSError, ValueError, UnicodeError, json.JSONDecodeError) as exc:
        raise CompanionError("Could not retrieve valid official RogueMaster metadata.") from exc
    if not isinstance(value, dict):
        raise CompanionError("Official RogueMaster metadata has an unexpected shape.")
    return value


def _sha256_digest(value: Any) -> str:
    if not isinstance(value, str) or not value.startswith("sha256:"):
        raise CompanionError("The selected official asset has no GitHub API SHA-256 digest; update refused.")
    digest = value[7:].lower()
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise CompanionError("The selected official asset has an invalid GitHub API SHA-256 digest.")
    return digest


def select_stable_asset(release: dict[str, Any]) -> dict[str, Any]:
    """Validate latest-release metadata and select its complete TGZ bundle."""
    if release.get("draft") is not False or release.get("prerelease") is not False:
        raise CompanionError("Only a public, non-draft, stable RogueMaster release is accepted.")
    tag = release.get("tag_name")
    if not isinstance(tag, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,100}", tag):
        raise CompanionError("The official release has an invalid tag.")
    assets = release.get("assets")
    if not isinstance(assets, list):
        raise CompanionError("The official release has no asset list.")
    candidates = [item for item in assets if isinstance(item, dict) and item.get("name") == f"{tag}.tgz"]
    if not candidates:
        candidates = [item for item in assets if isinstance(item, dict) and str(item.get("name", "")).endswith(".tgz")]
    if len(candidates) != 1:
        raise CompanionError("Expected exactly one complete RogueMaster TGZ release asset.")
    asset = candidates[0]
    name = asset.get("name")
    url = asset.get("browser_download_url")
    size = asset.get("size")
    if not isinstance(name, str) or Path(name).name != name or not name.endswith(".tgz"):
        raise CompanionError("The official release asset name is unsafe.")
    if not isinstance(url, str):
        raise CompanionError("The official release asset has no download URL.")
    _https_host(url, ASSET_HOSTS)
    if not isinstance(size, int) or isinstance(size, bool) or not 0 < size <= MAX_ARCHIVE_BYTES:
        raise CompanionError("The official release asset has an invalid size.")
    digest = _sha256_digest(asset.get("digest"))
    signature_found = any(
        isinstance(item, dict) and str(item.get("name", "")).lower().endswith((".sig", ".asc", ".sign"))
        for item in assets
    )
    return {
        "release_id": release.get("id"),
        "tag_name": tag,
        "name": release.get("name") if isinstance(release.get("name"), str) else tag,
        "published_at": release.get("published_at"),
        "asset_id": asset.get("id"),
        "asset_name": name,
        "asset_size": size,
        "asset_sha256": digest,
        "asset_url": url,
        "source_api": RELEASE_API,
        "authentication": "HTTPS plus the immutable GitHub API asset SHA-256 digest; no publisher signature is claimed.",
        "publisher_signature_found": signature_found,
        "channel": "stable",
    }


def check_release(channel: str = "stable", *, opener: Any = urlopen) -> dict[str, Any]:
    if channel == "stable":
        return select_stable_asset(_fetch_json(RELEASE_API, opener))
    if channel != "moving-head":
        raise CompanionError("Channel must be stable or moving-head.")
    branch = _fetch_json(BRANCH_API, opener)
    commit = branch.get("commit")
    if not isinstance(commit, dict) or not isinstance(commit.get("sha"), str):
        raise CompanionError("The official moving-head metadata has no commit SHA.")
    verification = commit.get("verification") if isinstance(commit.get("verification"), dict) else {}
    return {
        "channel": "moving-head",
        "branch": "420",
        "head_sha": commit["sha"],
        "commit_verified": verification.get("verified") is True,
        "verification_reason": verification.get("reason"),
        "automatic_update_allowed": False,
        "risk": (
            "The 420 branch is a mutable source branch, not an immutable firmware release. "
            "Review and build source separately; the companion will not download source and call it a firmware update."
        ),
        "source_api": BRANCH_API,
    }


def _download_asset(
    metadata: dict[str, Any],
    archive: Path,
    opener: Any,
    progress: Callable[[int, int, str], None] | None = None,
) -> None:
    url = metadata["asset_url"]
    _https_host(url, ASSET_HOSTS)
    archive.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".roguemaster-download-", dir=archive.parent)
    digest = hashlib.sha256()
    size = 0
    try:
        with os.fdopen(fd, "wb") as output:
            try:
                with opener(_request(url), timeout=60) as response:
                    final_url = response.geturl() if hasattr(response, "geturl") else url
                    _https_host(final_url, ASSET_HOSTS)
                    while True:
                        block = response.read(1024 * 1024)
                        if not block:
                            break
                        size += len(block)
                        if size > metadata["asset_size"] or size > MAX_ARCHIVE_BYTES:
                            raise CompanionError("Download exceeds the official asset size; download refused.")
                        digest.update(block)
                        output.write(block)
                        if progress is not None:
                            progress(size, metadata["asset_size"], "downloading")
                output.flush()
                os.fsync(output.fileno())
            except CompanionError:
                raise
            except OSError as exc:
                raise CompanionError("The official RogueMaster asset download failed.") from exc
        if size != metadata["asset_size"] or digest.hexdigest() != metadata["asset_sha256"]:
            raise CompanionError("Downloaded asset size or SHA-256 does not match official GitHub metadata.")
        atomic_replace(temporary, archive)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _member_relative(name: str, *, resource: bool = False) -> str | None:
    if "\x00" in name or "\\" in name:
        raise CompanionError("Archive contains an unsafe path.")
    if resource and name == "/":
        return None
    if resource and name.startswith("/"):
        name = name[1:]
        if not name or name.startswith("/"):
            raise CompanionError("Resource archive contains an unsafe absolute path.")
    directory = name.endswith("/")
    name = name.rstrip("/") if directory else name
    if not name:
        return None
    return safe_relative(name)


def _validate_tar_members(tar: tarfile.TarFile, *, resource: bool = False) -> list[tuple[tarfile.TarInfo, str | None]]:
    members = tar.getmembers()
    if len(members) > MAX_MEMBERS:
        raise CompanionError("Archive contains too many entries.")
    seen: set[str] = set()
    folded: set[str] = set()
    total = 0
    validated: list[tuple[tarfile.TarInfo, str | None]] = []
    for member in members:
        relative = _member_relative(member.name, resource=resource)
        if relative is None:
            if member.isdir():
                continue
            raise CompanionError("Archive root is not a regular file/directory entry.")
        if relative in seen or relative.casefold() in folded:
            raise CompanionError(f"Archive contains a duplicate/case-colliding path: {relative}")
        seen.add(relative)
        folded.add(relative.casefold())
        if member.issym() or member.islnk() or not (member.isfile() or member.isdir()):
            raise CompanionError("Archive links and special files are refused.")
        if member.isfile():
            if member.size < 0:
                raise CompanionError("Archive contains an invalid file size.")
            total += member.size
            if total > MAX_EXTRACTED_BYTES:
                raise CompanionError("Archive expands beyond the permitted size.")
        validated.append((member, relative))
    # A file cannot also be an implicit parent of another member.
    files = {relative for member, relative in validated if member.isfile()}
    for _, relative in validated:
        if relative is None:
            continue
        parts = PurePosixPath(relative).parts
        for index in range(1, len(parts)):
            parent = PurePosixPath(*parts[:index]).as_posix()
            if parent in files:
                raise CompanionError(f"Archive file/directory collision: {parent}")
    return validated


def _extract_tar(archive: Path, destination: Path, *, resource: bool = False) -> None:
    if destination.exists():
        raise CompanionError(f"Extraction destination already exists: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=".roguemaster-extract-", dir=destination.parent))
    try:
        with tarfile.open(archive, "r:*") as tar:
            validated = _validate_tar_members(tar, resource=resource)
            for member, relative in validated:
                if relative is None:
                    continue
                target = path_inside(temporary, relative)
                if member.isdir():
                    if target.exists() and not target.is_dir():
                        raise CompanionError(f"Archive directory collision: {relative}")
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                source = tar.extractfile(member)
                if source is None:
                    raise CompanionError(f"Archive file cannot be read: {relative}")
                with source, target.open("xb") as output:
                    shutil.copyfileobj(source, output, length=1024 * 1024)
                if target.stat().st_size != member.size:
                    raise CompanionError(f"Extracted size mismatch: {relative}")
        atomic_replace(temporary, destination)
    except CompanionError:
        raise
    except (OSError, tarfile.TarError) as exc:
        raise CompanionError("RogueMaster archive is unreadable or unsafe.") from exc
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def _single_bundle_root(bundle: Path) -> Path:
    entries = list(bundle.iterdir())
    if len(entries) != 1 or not entries[0].is_dir() or entries[0].is_symlink():
        raise CompanionError("The update archive must contain exactly one bundle directory.")
    return entries[0]


def parse_update_fuf(bundle_root: Path) -> dict[str, Any]:
    manifest = bundle_root / "update.fuf"
    if not manifest.is_file() or manifest.is_symlink():
        raise CompanionError("The RogueMaster bundle has no regular update.fuf.")
    try:
        lines = manifest.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        raise CompanionError("update.fuf is unreadable.") from exc
    fields: dict[str, str] = {}
    for line in lines:
        if not line.strip() or ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        if key in fields:
            raise CompanionError(f"Duplicate update.fuf field: {key}")
        fields[key] = value.strip()
    if fields.get("Version") != "2" or fields.get("Target") != "7":
        raise CompanionError("update.fuf must be version 2 and target Flipper Zero target 7.")
    required = ("Loader", "Firmware", "Resources")
    for key in required:
        if not fields.get(key):
            raise CompanionError(f"update.fuf is missing required {key}.")
    references: dict[str, str] = {}
    for key in ("Loader", "Firmware", "Radio", "Resources", "Splashscreen"):
        value = fields.get(key)
        if not value:
            continue
        relative = safe_relative(value)
        referenced = path_inside(bundle_root, relative)
        if not referenced.is_file() or referenced.is_symlink():
            raise CompanionError(f"update.fuf referenced file is missing: {value}")
        references[key] = relative
    for stem, key in (("Loader", "Loader"), ("Radio", "Radio")):
        field = fields.get(f"{stem} CRC")
        if field and key in references:
            try:
                expected_bytes = bytes.fromhex(field)
            except ValueError as exc:
                raise CompanionError(f"Invalid {stem} CRC in update.fuf.") from exc
            if len(expected_bytes) != 4:
                raise CompanionError(f"Invalid {stem} CRC in update.fuf.")
            actual = zlib.crc32(path_inside(bundle_root, references[key]).read_bytes()) & 0xFFFFFFFF
            if actual.to_bytes(4, "little") != expected_bytes:
                raise CompanionError(f"{stem} CRC32 does not match update.fuf.")
    if references["Resources"] not in {"resources.tar", "resources.tar.gz"}:
        raise CompanionError("update.fuf names an unsupported resource archive.")
    return {"version": 2, "target": 7, "references": references, "fields": fields}


def _validate_resources(resources: Path) -> dict[str, Any]:
    manifest = resources / "Manifest"
    if not manifest.is_file() or manifest.is_symlink():
        raise CompanionError("Resource archive has no regular Manifest.")
    try:
        lines = manifest.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        raise CompanionError("Resource Manifest is unreadable.") from exc
    records: dict[str, tuple[str, int]] = {}
    for line in lines:
        if not line.startswith("F:"):
            continue
        parts = line.split(":", 3)
        if len(parts) != 4 or not re.fullmatch(r"[0-9a-fA-F]{32}", parts[1]) or not parts[2].isdigit():
            raise CompanionError("Resource Manifest contains an invalid file record.")
        relative = safe_relative(parts[3])
        if relative in records or relative.casefold() in {item.casefold() for item in records}:
            raise CompanionError(f"Duplicate resource Manifest path: {relative}")
        records[relative] = (parts[1].lower(), int(parts[2]))
    if not records:
        raise CompanionError("Resource Manifest contains no files.")
    for relative, (expected_md5, expected_size) in records.items():
        path = path_inside(resources, relative)
        if not path.is_file() or path.is_symlink():
            raise CompanionError(f"Resource Manifest file is missing: {relative}")
        digest = hashlib.md5()
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
        if path.stat().st_size != expected_size or digest.hexdigest() != expected_md5:
            raise CompanionError(f"Resource Manifest size/MD5 mismatch: {relative}")
    return {"file_count": len(records), "compatibility_hash": "MD5 (upstream Manifest only; not asset authentication)"}


def _file_records(root: Path) -> list[dict[str, Any]]:
    files, _ = iter_source_files(root)
    return [{"path": relative, "size": path_inside(root, relative).stat().st_size,
             "sha256": sha256_file(path_inside(root, relative))} for relative in files]


def _load_json(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise CompanionError(f"Required metadata is missing or invalid: {path}") from exc
    if not isinstance(value, dict):
        raise CompanionError(f"Metadata has an invalid shape: {path}")
    return value


def _write_state(release_dir: Path, state: dict[str, Any]) -> None:
    state["updated_at"] = utc_now()
    _atomic_json(release_dir / STATE_NAME, state)


def _verify_cached(release_dir: Path) -> dict[str, Any]:
    state = _load_json(release_dir / STATE_NAME)
    if state.get("schema_version") != SCHEMA_VERSION:
        raise CompanionError("Unsupported or missing RogueMaster update journal.")
    archive = release_dir / ARCHIVE_NAME
    metadata = state.get("release")
    if not isinstance(metadata, dict) or not archive.is_file():
        raise CompanionError("Cached release journal/archive is incomplete.")
    if archive.stat().st_size != metadata.get("asset_size") or sha256_file(archive) != metadata.get("asset_sha256"):
        raise CompanionError("Cached release archive no longer matches its verified SHA-256/size.")
    for folder, key in (("bundle", "bundle_files"), ("resources", "resource_files")):
        root = release_dir / folder
        records = state.get(key)
        if not root.is_dir() or not isinstance(records, list):
            raise CompanionError(f"Cached {folder} extraction is incomplete.")
        actual = {record["path"]: record for record in _file_records(root)}
        expected = {record.get("path"): record for record in records if isinstance(record, dict)}
        if set(actual) != set(expected):
            raise CompanionError(f"Cached {folder} files differ from the journal.")
        for relative, record in expected.items():
            if actual[relative]["sha256"] != record.get("sha256") or actual[relative]["size"] != record.get("size"):
                raise CompanionError(f"Cached {folder} verification failed: {relative}")
    return state


def prepare_release(
    work_dir: Path,
    *,
    opener: Any = urlopen,
    reporter: Reporter = _silent,
    progress: Callable[[int, int, str], None] | None = None,
) -> Path:
    """Download and fully validate a stable release without touching an SD card."""
    selected = select_stable_asset(_fetch_json(RELEASE_API, opener))
    work_dir = work_dir.expanduser().resolve(strict=False)
    release_dir = work_dir / selected["tag_name"]
    if (release_dir / STATE_NAME).exists():
        state = _verify_cached(release_dir)
        if state["release"].get("asset_sha256") != selected["asset_sha256"]:
            raise CompanionError("Cached release does not match the selected official asset.")
        if progress is not None:
            progress(selected["asset_size"], selected["asset_size"], "cached")
        reporter(f"Verified cached release: {release_dir}")
        return release_dir
    if release_dir.exists() and any(release_dir.iterdir()):
        raise CompanionError("Release work folder is nonempty but has no valid journal; choose another folder.")
    release_dir.mkdir(parents=True, exist_ok=True)
    archive = release_dir / ARCHIVE_NAME
    _download_asset(selected, archive, opener, progress)
    _atomic_json(release_dir / METADATA_NAME, selected)
    bundle = release_dir / "bundle"
    resources = release_dir / "resources"
    try:
        _extract_tar(archive, bundle)
        root = _single_bundle_root(bundle)
        if root.name != selected["tag_name"]:
            raise CompanionError("Bundle root does not match the official release tag.")
        update = parse_update_fuf(root)
        resource_archive = path_inside(root, update["references"]["Resources"])
        _extract_tar(resource_archive, resources, resource=True)
        resource_manifest = _validate_resources(resources)
        state = {
            "schema_version": SCHEMA_VERSION,
            "created_at": utc_now(),
            "release": selected,
            "bundle_root": root.name,
            "update_fuf": update,
            "resource_manifest": resource_manifest,
            "bundle_files": _file_records(bundle),
            "resource_files": _file_records(resources),
            "backup": None,
            "inventory": None,
            "sd_path": None,
            "method": None,
            "operations": {
                "resources": {"copied": [], "kept": [], "complete": False},
                "package": {"copied": [], "complete": False},
            },
        }
        _write_state(release_dir, state)
    except Exception:
        # A partial cache must never be mistaken for a resumable verified release.
        if not (release_dir / STATE_NAME).exists():
            shutil.rmtree(release_dir, ignore_errors=True)
        raise
    reporter(f"Verified official RogueMaster {selected['tag_name']} in {release_dir}")
    reporter(
        "The SHA-256 came from GitHub release metadata; a signature asset is present but is not verified by this companion."
        if selected["publisher_signature_found"] else
        "The SHA-256 came from GitHub release metadata; no publisher signature asset was found or claimed."
    )
    return release_dir


def _category(relative: str) -> str:
    pure = PurePosixPath(relative)
    lower = relative.lower()
    parts = [part.lower() for part in pure.parts]
    suffix = pure.suffix.lower()
    if parts[0] == "apps" and suffix in {".fap", ".fal"}:
        return "applications_fap_fal"
    if parts[0] == "badusb":
        return "badusb"
    if parts[0] in {"scripts", "script"} or suffix in {".js", ".py", ".sh"}:
        return "scripts"
    for name in ("apps_data", "apps_assets", "apps_manifest", "subghz", "infrared", "nfc", "ibutton"):
        if parts[0] == name:
            return name
    if parts[0] in {"lfrfid", "rfid"}:
        return "lfrfid_rfid"
    if pure.name.lower() == "favorites.txt" or any(part in {"profiles", "profile", "settings"} for part in parts):
        return "favourites_profiles_settings"
    if parts[0] in {"dolphin", "asset_packs"}:
        return "dolphin_asset_packs"
    return "other"


def create_inventory(sd: Path, destination: Path | None = None, resource_records: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    files, _ = iter_source_files(sd)
    release_hashes = {record["path"]: record["sha256"] for record in resource_records or []}
    records = []
    counts: dict[str, int] = {}
    for relative in files:
        path = path_inside(sd, relative)
        digest = sha256_file(path)
        category = _category(relative)
        counts[category] = counts.get(category, 0) + 1
        if resource_records is None:
            comparison = "not_compared"
        elif relative not in release_hashes:
            comparison = "not_in_release"
        elif release_hashes[relative] == digest:
            comparison = "same_as_release"
        else:
            comparison = "differs_from_release"
        records.append({"path": relative, "size": path.stat().st_size, "sha256": digest,
                        "category": category, "release_comparison": comparison})
    inventory = {
        "schema_version": SCHEMA_VERSION,
        "created_at": utc_now(),
        "source_sd": str(sd.resolve()),
        "file_count": len(records),
        "categories": counts,
        "origin_note": "Path categories are organizational only. Stock and custom files can share paths; custom origin cannot be known.",
        "comparison_note": "Release comparison covers extracted SD resources only and does not prove file origin.",
        "files": records,
    }
    if destination is not None:
        _atomic_json(destination, inventory)
    return inventory


def _resource_plan(sd: Path, release_dir: Path, state: dict[str, Any], policy: str) -> dict[str, list[str]]:
    if policy not in {"abort", "keep", "replace"}:
        raise CompanionError("Resource conflict policy must be abort, keep, or replace.")
    plan = {"new": [], "same": [], "different": []}
    for record in state["resource_files"]:
        relative = safe_relative(record["path"])
        destination = path_inside(sd, relative)
        if destination.exists() and (not destination.is_file() or destination.is_symlink()):
            raise CompanionError(f"SD resource destination is not a regular file: {relative}")
        if not destination.exists():
            plan["new"].append(relative)
        elif sha256_file(destination) == record["sha256"]:
            plan["same"].append(relative)
        else:
            plan["different"].append(relative)
    if plan["different"] and policy == "abort":
        raise CompanionError(
            "Existing SD resources differ from the release. Nothing was changed. Review the inventory and explicitly "
            "choose replace for a full update, or keep/replace for an asset-only merge. Differing: "
            + ", ".join(plan["different"][:20])
        )
    return plan


def _ensure_original_backup(
    sd: Path,
    release_dir: Path,
    state: dict[str, Any],
    *,
    yes: bool,
    root: Path | None,
    backup_dir: Path | None,
    reporter: Reporter,
    input_function: Any,
) -> Path:
    if state.get("backup"):
        backup = Path(state["backup"])
        verify_backup(backup)
        if state.get("sd_path") != str(sd.resolve()):
            raise CompanionError("The selected SD differs from the path recorded in the original update journal.")
        return backup
    reporter("A complete SHA-256-verified SD backup and categorized inventory are required before the first SD write.")
    reporter("The inventory cannot prove whether a file is custom; stock and custom files may share the same path.")
    confirm_change("Confirm this exact SD path and the reviewed update/backup plan.", yes, input_function)
    backup = create_backup(sd, (backup_dir or release_dir / "backups").expanduser(), root=root, reporter=reporter)
    verify_backup(backup)
    inventory_path = release_dir / "inventory.json"
    create_inventory(sd, inventory_path, state["resource_files"])
    state["backup"] = str(backup.resolve())
    state["inventory"] = str(inventory_path.resolve())
    state["sd_path"] = str(sd.resolve())
    _write_state(release_dir, state)
    reporter(f"Original pre-update backup: {backup}")
    reporter(f"Categorized SD inventory: {inventory_path}")
    return backup


def _original_records(backup: Path) -> dict[str, dict[str, Any]]:
    manifest = verify_backup(backup)
    return {record["path"]: record for record in manifest["files"]}


def _needs_copy(destination: Path, relative: str, expected_hash: str, originals: dict[str, dict[str, Any]]) -> bool:
    if destination.exists() and (not destination.is_file() or destination.is_symlink()):
        raise CompanionError(f"SD destination is not a regular file: {relative}")
    if destination.is_file() and sha256_file(destination) == expected_hash:
        return False
    original = originals.get(relative)
    if original is None:
        if destination.exists():
            raise CompanionError(f"SD file appeared after the original backup; resume refused: {relative}")
        return True
    if destination.is_file() and sha256_file(destination) == original["sha256"]:
        return True
    raise CompanionError(f"SD file changed outside the journaled update; resume refused: {relative}")


def merge_resources(
    release_dir: Path,
    sd: Path,
    *,
    conflict: str = "abort",
    yes: bool = False,
    root: Path | None = None,
    backup_dir: Path | None = None,
    reporter: Reporter = _silent,
    input_function: Any = input,
    _state: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Merge only extracted SD resources; firmware/update files are never copied."""
    release_dir = release_dir.expanduser().resolve()
    sd = sd.expanduser().resolve()
    if not sd.is_dir():
        raise CompanionError("The explicitly selected SD mount is unavailable.")
    state = _state or _verify_cached(release_dir)
    plan = _resource_plan(sd, release_dir, state, conflict)
    reporter(f"Resource review: {len(plan['new'])} new, {len(plan['same'])} matching, {len(plan['different'])} differing.")
    if conflict == "keep" and plan["different"]:
        reporter("Differing existing resources will be kept. This policy is available only for asset-only merging.")
    if conflict == "replace" and plan["different"]:
        reporter("Differing existing resources will be replaced only after the original full-SD backup is verified.")
    backup = _ensure_original_backup(
        sd, release_dir, state, yes=yes, root=root, backup_dir=backup_dir, reporter=reporter, input_function=input_function,
    )
    originals = _original_records(backup)
    operation = state["operations"]["resources"]
    copied = set(operation.get("copied") or [])
    kept = set(operation.get("kept") or [])
    for record in state["resource_files"]:
        relative = safe_relative(record["path"])
        destination = path_inside(sd, relative)
        current_differs = destination.is_file() and sha256_file(destination) != record["sha256"]
        if conflict == "keep" and current_differs:
            original = originals.get(relative)
            if original is None or sha256_file(destination) != original["sha256"]:
                raise CompanionError(f"A kept resource changed outside the update journal: {relative}")
            kept.add(relative)
            operation["kept"] = sorted(kept)
            _write_state(release_dir, state)
            continue
        if not _needs_copy(destination, relative, record["sha256"], originals):
            continue
        copy_file_verified(path_inside(release_dir / "resources", relative), destination, record["sha256"])
        copied.add(relative)
        operation["copied"] = sorted(copied)
        _write_state(release_dir, state)
    for record in state["resource_files"]:
        relative = record["path"]
        if relative in kept:
            continue
        if sha256_file(path_inside(sd, relative)) != record["sha256"]:
            raise CompanionError(f"Resource post-verification failed: {relative}")
    operation["complete"] = True
    _write_state(release_dir, state)
    reporter("Resource merge verified. No firmware was flashed and no unrelated files were deleted.")
    return {"resources_complete": True, "copied_total": len(copied), "kept_total": len(kept),
            "deleted": 0, "flash_performed": False}


def _package_conflicts(sd: Path, bundle_root: Path, state: dict[str, Any]) -> list[str]:
    final = path_inside(sd, f"update/{state['bundle_root']}")
    conflicts = []
    for record in state["bundle_files"]:
        relative = safe_relative(record["path"])
        if not relative.startswith(state["bundle_root"] + "/"):
            raise CompanionError("Bundle journal contains a file outside its bundle root.")
        inner = relative[len(state["bundle_root"]) + 1:]
        destination = path_inside(final, inner)
        if destination.exists() and (not destination.is_file() or destination.is_symlink()):
            raise CompanionError(f"Existing update package destination is not a regular file: {relative}")
        if destination.is_file() and sha256_file(destination) != record["sha256"]:
            conflicts.append(relative)
    return conflicts


def stage_package(
    release_dir: Path,
    sd: Path,
    *,
    conflict: str,
    reporter: Reporter,
    _state: dict[str, Any],
) -> dict[str, Any]:
    """Stage the genuine complete bundle, with a journal entry after every file."""
    state = _state
    operation = state["operations"]["package"]
    copied = set(operation.get("copied") or [])
    update_root = path_inside(sd, "update")
    update_root.mkdir(parents=True, exist_ok=True)
    staging = update_root / ".secure-linux-roguemaster-staging"
    final = update_root / state["bundle_root"]
    if staging.exists() and staging.is_symlink():
        raise CompanionError("Companion package staging path is a symbolic link; resume refused.")
    if final.exists() and (not final.is_dir() or final.is_symlink()):
        raise CompanionError("Final update bundle path is not a regular directory.")
    if not staging.exists() and not final.exists():
        staging.mkdir()
    originals = _original_records(Path(state["backup"]))
    for record in state["bundle_files"]:
        relative = safe_relative(record["path"])
        inner = relative[len(state["bundle_root"]) + 1:]
        # Reconcile the staging copy first. It is companion-owned and disposable.
        staged = path_inside(staging, inner) if staging.exists() else None
        if staged is not None and (not staged.is_file() or sha256_file(staged) != record["sha256"]):
            copy_file_verified(path_inside(release_dir / "bundle", relative), staged, record["sha256"])
        elif staged is None and not final.exists():
            raise CompanionError("Package staging disappeared unexpectedly; resume refused.")
        copied.add(relative)
        operation["copied"] = sorted(copied)
        _write_state(release_dir, state)
    if not final.exists():
        for record in state["bundle_files"]:
            inner = record["path"][len(state["bundle_root"]) + 1:]
            if sha256_file(path_inside(staging, inner)) != record["sha256"]:
                raise CompanionError("Package staging verification failed before atomic rename.")
        atomic_replace(staging, final)
    else:
        # Existing bundles are compared and merged, never wiped. This preserves extras.
        for record in state["bundle_files"]:
            inner = record["path"][len(state["bundle_root"]) + 1:]
            destination = path_inside(final, inner)
            original_relative = f"update/{state['bundle_root']}/{inner}"
            if _needs_copy(destination, original_relative, record["sha256"], originals):
                copy_file_verified(path_inside(release_dir / "bundle", record["path"]), destination, record["sha256"])
    for record in state["bundle_files"]:
        inner = record["path"][len(state["bundle_root"]) + 1:]
        if sha256_file(path_inside(final, inner)) != record["sha256"]:
            raise CompanionError("Final on-SD package verification failed.")
    if staging.exists():
        # This exact fixed-name directory is created and journaled by the companion.
        shutil.rmtree(staging)
    operation["complete"] = True
    _write_state(release_dir, state)
    reporter(f"Complete verified bundle staged at {final}")
    reporter("On the Flipper, open the file browser and run this bundle's update.fuf. Keep power connected until it finishes.")
    reporter("Device-side firmware/radio/resource behavior is outside host control; staging is not a completed flash.")
    return {"package_complete": True, "package_path": str(final), "flash_performed": False, "deleted": 0}


def update_release(
    release_dir: Path,
    sd: Path,
    *,
    method: str = "stage",
    resource_conflict: str = "abort",
    yes: bool = False,
    root: Path | None = None,
    backup_dir: Path | None = None,
    reporter: Reporter = _silent,
    input_function: Any = input,
    which: Callable[[str], str | None] = shutil.which,
    popen: Any = subprocess.Popen,
    _state: dict[str, Any] | None = None,
    _before_launch: Callable[[], None] | None = None,
) -> dict[str, Any]:
    if method not in {"stage", "qflipper"}:
        raise CompanionError("Update method must be stage or qflipper.")
    if resource_conflict not in {"abort", "replace"}:
        raise CompanionError("Full updates allow resource-conflict abort or replace, not keep.")
    release_dir = release_dir.expanduser().resolve()
    sd = sd.expanduser().resolve()
    if not sd.is_dir():
        raise CompanionError("The explicitly selected SD mount is unavailable.")
    state = _state or _verify_cached(release_dir)
    previous_method = state.get("method")
    operations_started = any(state["operations"][name].get("copied") for name in ("resources", "package"))
    if previous_method and previous_method != method and operations_started:
        raise CompanionError("Cannot switch update method after journaled SD writes; resume the original method.")
    plan = _resource_plan(sd, release_dir, state, resource_conflict)
    reporter(f"Full update resource review: {len(plan['new'])} new, {len(plan['same'])} matching, {len(plan['different'])} differing.")
    package_conflicts = _package_conflicts(sd, path_inside(release_dir / "bundle", state["bundle_root"]), state)
    if package_conflicts and resource_conflict == "abort":
        raise CompanionError("Existing on-SD update package files differ; nothing changed. Use replace after review.")
    reporter("RogueMaster's README suggests deleting /ext/apps before updates; this companion never does that.")
    reporter("A full backup is made first. Custom files not touched by the package are preserved by host-side operations.")
    reporter("The device updater may process its resource manifest and overwrite differing stock files; that is not host-transactional.")
    state["method"] = method
    _ensure_original_backup(
        sd, release_dir, state, yes=yes, root=root, backup_dir=backup_dir, reporter=reporter, input_function=input_function,
    )
    _write_state(release_dir, state)
    if method == "qflipper":
        reporter("After launch, in qFlipper choose Install from file and select the verified package.tgz in this release folder.")
        reporter("Wait for qFlipper and the Flipper to report completion. Launch or exit status cannot prove a flash.")
        if _before_launch is not None:
            _before_launch()
        launch_qflipper(scale=1.5, yes=yes, reporter=reporter, which=which, popen=popen, input_function=input_function)
        state["operations"]["qflipper_launched"] = True
        _write_state(release_dir, state)
        return {"status": "qflipper-launched", "archive": str(release_dir / ARCHIVE_NAME),
                "flash_performed": False, "deleted": 0}
    resources = merge_resources(
        release_dir, sd, conflict=resource_conflict, yes=yes, root=root, backup_dir=backup_dir, reporter=reporter,
        input_function=input_function, _state=state,
    )
    package = stage_package(release_dir, sd, conflict=resource_conflict, reporter=reporter, _state=state)
    return {"status": "staged", **resources, **package, "firmware_flashed_by_companion": False}


def resume_update(release_dir: Path, sd: Path, **kwargs: Any) -> dict[str, Any]:
    """Resume entirely from cache; even without --offline this performs no network I/O."""
    release_dir = release_dir.expanduser().resolve()
    state = _verify_cached(release_dir)
    if not state.get("backup"):
        raise CompanionError("No original pre-update backup is journaled; run rm-update or rm-assets first.")
    kwargs.setdefault("method", state.get("method") or "stage")
    return update_release(release_dir, sd, _state=state, **kwargs)


def resume_assets(release_dir: Path, sd: Path, **kwargs: Any) -> dict[str, Any]:
    release_dir = release_dir.expanduser().resolve()
    state = _verify_cached(release_dir)
    if not state.get("backup"):
        raise CompanionError("No original pre-update backup is journaled; run rm-assets first.")
    return merge_resources(release_dir, sd, _state=state, **kwargs)


def rollback_release(
    release_dir: Path,
    sd: Path,
    *,
    safety_backup: Path,
    yes: bool = False,
    root: Path | None = None,
    reporter: Reporter = _silent,
    input_function: Any = input,
) -> dict[str, Any]:
    release_dir = release_dir.expanduser().resolve()
    state = _verify_cached(release_dir)
    if not state.get("backup"):
        raise CompanionError("No original pre-update backup is available for rollback.")
    backup = Path(state["backup"])
    verify_backup(backup)
    reporter("Rollback restores SD files from the original verified backup and never deletes unrelated additions.")
    reporter("Files added after that backup may remain. Internal firmware/radio cannot be rolled back by an SD restore.")
    result = restore_backup(
        backup, sd, safety_backup=safety_backup, yes=yes, root=root, reporter=reporter, input_function=input_function,
    )
    return {**result, "sd_rollback": True, "firmware_rolled_back": False,
            "firmware_note": "To change firmware back, stage/install a prior official verified package through the same update path."}


def check_dfu(
    *,
    yes: bool = False,
    reporter: Reporter = _silent,
    which: Callable[[str], str | None] = shutil.which,
    runner: Any = subprocess.run,
    input_function: Any = input,
) -> dict[str, Any]:
    executable = which("dfu-util")
    if not executable:
        raise CompanionError("dfu-util was not found. Install it from trusted distribution packages for read-only DFU inspection.")
    command = [executable, "-l"]
    reporter("Read-only recovery inspection: dfu-util -l. This does not flash or erase firmware.")
    confirm_change("Confirm read-only DFU device listing.", yes, input_function)
    try:
        # Deliberately no timeout: hardware tools must not be killed by the companion.
        result = runner(command, check=False, capture_output=True, text=True)
    except OSError as exc:
        raise CompanionError("Could not start dfu-util for read-only inspection.") from exc
    output = {"command": command, "returncode": result.returncode, "stdout": result.stdout,
              "stderr": result.stderr, "ok": result.returncode == 0, "flash_performed": False}
    if result.returncode != 0:
        reporter(f"dfu-util exited {result.returncode}; no DFU device availability or flash success is claimed.")
    return output
