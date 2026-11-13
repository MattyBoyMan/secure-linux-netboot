#!/usr/bin/env python3
"""Canonical Secure Linux release manifests and cross-surface coherence checks.

The release ID is derived from the current payload source, not from a hand-written
version label. Generated manifests are deliberately excluded from that source
snapshot so stamping is deterministic and cannot recurse into itself.
"""
from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import tempfile
from typing import Any, Mapping

SCHEMA_VERSION = 1
APPLICATION = "secure-linux-release"
HASH_RE = re.compile(r"^[0-9a-f]{64}$")
RELEASE_ID_RE = re.compile(r"^secure-linux-[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9a-f]{16}$")

CANONICAL = "release.json"
INSTALLED = "linux/release.json"
COMPANION = "linux/lib/flipper-companion/version.json"
DEBIAN_COMPANION = "debian/setup/lib/flipper-companion/version.json"
NETBOOT = "netboot/dist/release.json"

# Payload-producing source only. Tests, handovers, caches and generated output do
# not define a release. The guide's rendered HTML and the netboot installer's
# embedded hasher are included because both are shipped runtime inputs.
TOP_LEVEL_FILES = (
    "BUILD-USB.cmd",
    "README.md",
    "SAVE-APPS.cmd",
    "SAVE-THIS-PC.cmd",
    "backup-windows.ps1",
    "build-guide.ps1",
    "make-usb.ps1",
    "preflight-windows.ps1",
    "save-apps-mac.sh",
    "save-apps.ps1",
    "save-wifi.ps1",
    "setup.sh",
    "tests/sha512crypt.py",
)
SOURCE_DIRECTORIES = (
    "linux",
    "debian",
    "templates",
    "netboot",
    "guide",
    "setup-app",
    "setup-app-mac",
    "stick-theme",
    "offline-bundle",
)
EXCLUDED_FILES = {CANONICAL, INSTALLED, COMPANION, DEBIAN_COMPANION}
EXCLUDED_PREFIXES = (
    "netboot/dist/",
    "offline-bundle/dist/",
    "offline-bundle/.tools/",
)
EXCLUDED_DIRECTORY_NAMES = {".git", "__pycache__", ".debug", ".test-logs"}
# The offline payload itself is generated and can be many gigabytes. Its exact
# install-consumed package/hash records nevertheless define what will be installed,
# so include those JSON records while excluding payload bytes and local approvals,
# audit reports, acquisition logs and other generated state.
OFFLINE_METADATA_GLOBS = (
    "offline-bundle/dist/app-bundles/*/plan.json",
    "offline-bundle/dist/app-bundles/*/payloads.json",
    "offline-bundle/dist/app-bundles/*/manifests/*.json",
    "offline-bundle/dist/app-bundles/*/repositories/*/repository.json",
    "offline-bundle/dist/app-bundles/*/flatpak/*/flatpak-repository.json",
)
OFFLINE_METADATA_RE = re.compile(
    r"^offline-bundle/dist/app-bundles/[^/]+/(?:"
    r"(?:plan|payloads)\.json|manifests/[^/]+\.json|"
    r"repositories/[^/]+/repository\.json|flatpak/[^/]+/flatpak-repository\.json)$"
)


class ReleaseError(RuntimeError):
    """A safe, user-facing release coherence failure."""


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def json_bytes(value: Mapping[str, Any]) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".release-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def restore_records(previous: Mapping[Path, tuple[bytes, int] | None]) -> None:
    """Restore a record transaction, or raise if any record cannot be restored."""
    failures = []
    for path, saved in reversed(list(previous.items())):
        try:
            if saved is None:
                path.unlink(missing_ok=True)
            else:
                data, mode = saved
                atomic_write(path, data)
                os.chmod(path, mode)
        except OSError as exc:
            failures.append(f"{path}: {exc}")
    if failures:
        raise ReleaseError("release records could not be restored: " + "; ".join(failures))


def snapshot_records(paths) -> dict[Path, tuple[bytes, int] | None]:
    previous = {}
    for path in paths:
        previous[path] = (path.read_bytes(), path.stat().st_mode & 0o777) if path.exists() else None
    return previous


def _safe_relative(value: str) -> str:
    if not value or "\x00" in value or "\\" in value:
        raise ReleaseError(f"unsafe release source path: {value!r}")
    pure = PurePosixPath(value)
    if pure.is_absolute() or pure.as_posix() != value or any(part in {"", ".", ".."} for part in pure.parts):
        raise ReleaseError(f"unsafe release source path: {value!r}")
    return value


def _excluded(relative: str) -> bool:
    if OFFLINE_METADATA_RE.fullmatch(relative):
        return False
    if relative in EXCLUDED_FILES:
        return True
    if any(relative.startswith(prefix) for prefix in EXCLUDED_PREFIXES):
        return True
    if relative.startswith("offline-bundle/") and relative.endswith(".log"):
        return True
    return any(part in EXCLUDED_DIRECTORY_NAMES for part in PurePosixPath(relative).parts)


def source_snapshot(root: Path) -> dict[str, str]:
    """Hash every current regular payload-source file, rejecting silent omissions."""
    root = root.resolve()
    selected: list[Path] = []
    for name in TOP_LEVEL_FILES:
        path = root / name
        if path.exists():
            selected.append(path)
    for name in SOURCE_DIRECTORIES:
        path = root / name
        if not path.exists():
            continue
        for current, directories, filenames in os.walk(path):
            current_path = Path(current)
            relative_dir = current_path.relative_to(root).as_posix()
            directories[:] = sorted(
                name for name in directories
                if not _excluded(relative_dir + "/" + name + "/")
            )
            selected.extend(current_path / filename for filename in sorted(filenames))
    for pattern in OFFLINE_METADATA_GLOBS:
        selected.extend(sorted(root.glob(pattern)))

    files: dict[str, str] = {}
    for path in selected:
        if not path.is_file() and not path.is_symlink():
            continue
        relative = path.relative_to(root).as_posix()
        if _excluded(relative):
            continue
        _safe_relative(relative)
        if path.is_symlink() or not path.is_file():
            raise ReleaseError(f"release source must contain regular files only: {relative}")
        files[relative] = sha256_file(path)
    if not files:
        raise ReleaseError(f"no payload source files found under {root}")
    return files


def source_digest(files: Mapping[str, str]) -> str:
    digest = hashlib.sha256()
    for name in sorted(files):
        old_hash = files[name]
        _safe_relative(name)
        if not HASH_RE.fullmatch(old_hash):
            raise ReleaseError(f"invalid source hash for {name}")
        digest.update(name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(old_hash.encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def canonical_path(root: Path) -> Path:
    return root / CANONICAL


def installed_path(root: Path) -> Path:
    return root / INSTALLED


def netboot_path(root: Path) -> Path:
    return root / NETBOOT


def read_json(path: Path) -> tuple[dict[str, Any], bytes]:
    try:
        raw = path.read_bytes()
        value = json.loads(raw)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ReleaseError(f"release manifest is missing or unreadable: {path}") from exc
    if not isinstance(value, dict):
        raise ReleaseError(f"release manifest is not a JSON object: {path}")
    return value, raw


def validate_canonical(manifest: Mapping[str, Any]) -> None:
    if manifest.get("schema_version") != SCHEMA_VERSION or manifest.get("application") != APPLICATION:
        raise ReleaseError("unsupported or wrong-application release manifest")
    if not RELEASE_ID_RE.fullmatch(str(manifest.get("release_id", ""))):
        raise ReleaseError("release manifest has an invalid release ID")
    files = manifest.get("source", {}).get("files")
    if not isinstance(files, dict) or not files:
        raise ReleaseError("release manifest has no source file hashes")
    digest = source_digest(files)
    if manifest["source"].get("algorithm") != "sha256-paths-v1" or manifest["source"].get("sha256") != digest:
        raise ReleaseError("release manifest source digest does not match its file hashes")
    expected_suffix = digest[:16]
    if not str(manifest["release_id"]).endswith(expected_suffix):
        raise ReleaseError("release ID does not match the source digest")


def load_canonical(root: Path) -> tuple[dict[str, Any], bytes]:
    manifest, raw = read_json(canonical_path(root))
    validate_canonical(manifest)
    return manifest, raw


def installed_record(manifest: Mapping[str, Any], canonical_raw: bytes) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "application": APPLICATION,
        "release_id": manifest["release_id"],
        "source_sha256": manifest["source"]["sha256"],
        "release_manifest_sha256": sha256_bytes(canonical_raw),
    }


def validate_installed(record: Mapping[str, Any]) -> None:
    if record.get("schema_version") != SCHEMA_VERSION or record.get("application") != APPLICATION:
        raise ReleaseError("unsupported or wrong-application installed release record")
    if not RELEASE_ID_RE.fullmatch(str(record.get("release_id", ""))):
        raise ReleaseError("installed release record has an invalid release ID")
    for key in ("source_sha256", "release_manifest_sha256"):
        if not HASH_RE.fullmatch(str(record.get(key, ""))):
            raise ReleaseError(f"installed release record has an invalid {key}")
    if not str(record["release_id"]).endswith(record["source_sha256"][:16]):
        raise ReleaseError("installed release ID does not match its source digest")


def source_problems(root: Path, manifest: Mapping[str, Any] | None = None) -> list[str]:
    try:
        if manifest is None:
            manifest, _ = load_canonical(root)
        validate_canonical(manifest)
        current = source_snapshot(root)
    except ReleaseError as exc:
        return [str(exc)]
    expected = manifest["source"]["files"]
    problems: list[str] = []
    for name in sorted(set(expected) | set(current)):
        if name not in current:
            problems.append(f"source missing: {name}")
        elif name not in expected:
            problems.append(f"source untracked: {name}")
        elif expected[name] != current[name]:
            problems.append(f"source changed: {name}")
    if source_digest(current) != manifest["source"]["sha256"]:
        problems.append("source digest is stale; run secure-linux-release stamp")
    return problems


def _record_problems(record: Mapping[str, Any], manifest: Mapping[str, Any], canonical_raw: bytes, label: str) -> list[str]:
    try:
        validate_installed(record)
    except ReleaseError as exc:
        return [f"{label}: {exc}"]
    expected = installed_record(manifest, canonical_raw)
    problems = []
    for key in ("release_id", "source_sha256", "release_manifest_sha256"):
        if record.get(key) != expected[key]:
            problems.append(f"{label} has stale/mismatched {key}")
    return problems


def installed_problems(root: Path, manifest: Mapping[str, Any], canonical_raw: bytes, path: Path | None = None) -> list[str]:
    path = path or installed_path(root)
    try:
        record, _ = read_json(path)
    except ReleaseError as exc:
        return [f"installed copy: {exc}"]
    return _record_problems(record, manifest, canonical_raw, "installed copy")


def netboot_problems(manifest: Mapping[str, Any], canonical_raw: bytes, output_root: Path) -> list[str]:
    path = output_root / "release.json"
    try:
        record, _ = read_json(path)
    except ReleaseError as exc:
        return [f"netboot render: {exc}"]
    return _record_problems(record, manifest, canonical_raw, "netboot render")


def stamp(root: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    """Write canonical and installed records; companion refresh is orchestrated by the CLI."""
    root = root.resolve()
    previous_records = snapshot_records((canonical_path(root), installed_path(root)))
    try:
        files = source_snapshot(root)
        if source_snapshot(root) != files:
            raise ReleaseError("source changed during release stamping; no new release was written")
        digest = source_digest(files)
        previous_manifest: dict[str, Any] | None = None
        try:
            previous_manifest, _ = load_canonical(root)
        except ReleaseError:
            previous_manifest = None
        if previous_manifest and previous_manifest["source"]["sha256"] == digest and previous_manifest["source"]["files"] == files:
            created_at = previous_manifest["created_at"]
            release_id = previous_manifest["release_id"]
        else:
            created_at = utc_now()
            date = datetime.now(timezone.utc).strftime("%Y.%m.%d")
            release_id = f"secure-linux-{date}-{digest[:16]}"
        manifest = {
            "schema_version": SCHEMA_VERSION,
            "application": APPLICATION,
            "release_id": release_id,
            "created_at": created_at,
            "source": {
                "algorithm": "sha256-paths-v1",
                "sha256": digest,
                "file_count": len(files),
                "files": files,
            },
        }
        raw = json_bytes(manifest)
        record = installed_record(manifest, raw)
        atomic_write(canonical_path(root), raw)
        atomic_write(installed_path(root), json_bytes(record))
        return manifest, record
    except BaseException:
        restore_records(previous_records)
        raise


def capture_master_release(current_path: Path, source_path: Path, root: Path | None = None) -> dict[str, str]:
    """Bind a whole-USB master to the exact current installed release record.

    The source record must be explicitly selected from the mounted finished USB.
    When running in a source checkout, the canonical source is rechecked as well.
    """
    current, current_raw = read_json(current_path)
    source, source_raw = read_json(source_path)
    validate_installed(current)
    validate_installed(source)
    if root is not None and canonical_path(root).is_file():
        manifest, canonical_raw = load_canonical(root)
        problems = source_problems(root, manifest)
        problems += installed_problems(root, manifest, canonical_raw, current_path)
        if problems:
            raise ReleaseError("current kit is not release-coherent: " + "; ".join(problems))
        expected = installed_record(manifest, canonical_raw)
        if any(current.get(key) != expected[key] for key in expected):
            raise ReleaseError("current installed release record does not match the canonical manifest")
    if current_raw != source_raw:
        raise ReleaseError(
            "finished USB release record is stale or does not match the current kit; rebuild/render before creating a master"
        )
    return {
        "release_id": current["release_id"],
        "source_sha256": current["source_sha256"],
        "release_manifest_sha256": current["release_manifest_sha256"],
        "source_release_sha256": sha256_bytes(source_raw),
    }


def validate_master_release_block(release: Mapping[str, Any]) -> None:
    if not RELEASE_ID_RE.fullmatch(str(release.get("release_id", ""))):
        raise ReleaseError("master has no valid kit release ID")
    for key in ("source_sha256", "release_manifest_sha256", "source_release_sha256"):
        if not HASH_RE.fullmatch(str(release.get(key, ""))):
            raise ReleaseError(f"master has no valid {key}")


def master_problems(manifest: Mapping[str, Any], current_path: Path) -> list[str]:
    release = manifest.get("release")
    if not isinstance(release, dict):
        return ["master has no kit release linkage; recreate it from a current finished USB"]
    try:
        validate_master_release_block(release)
        current, current_raw = read_json(current_path)
        validate_installed(current)
    except ReleaseError as exc:
        return [str(exc)]
    problems = []
    for key in ("release_id", "source_sha256", "release_manifest_sha256"):
        if release.get(key) != current.get(key):
            problems.append(f"master is stale: {key} differs from the current release")
    if release.get("source_release_sha256") != sha256_bytes(current_raw):
        problems.append("master source release record differs from the current installed record")
    return problems
