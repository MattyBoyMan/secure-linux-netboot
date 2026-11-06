#!/usr/bin/env python3
"""Verified backups, conservative restore, and encrypted private backups."""
from __future__ import annotations

import getpass
import json
import os
from pathlib import Path, PurePosixPath
import secrets
import shutil
import subprocess
import tarfile
import tempfile
from datetime import datetime, timezone
from typing import Any, Callable, Iterable

from flipper_companion_core import (
    COMPANION_VERSION,
    FLASH_ERASE_NOTICE,
    SCHEMA_VERSION,
    CompanionError,
    _atomic_json,
    atomic_replace,
    confirm_change,
    copy_file_verified,
    ensure_distinct_trees,
    iter_source_files,
    load_metadata,
    path_inside,
    safe_relative,
    sha256_file,
    utc_now,
)

Reporter = Callable[[str], None]


def _silent(_: str) -> None:
    return None


def _backup_id() -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return f"flipper-{stamp}-{secrets.token_hex(4)}"


def create_backup(
    source: Path,
    destination: Path,
    *,
    selection: Iterable[str] | None = None,
    root: Path | None = None,
    reporter: Reporter = _silent,
) -> Path:
    """Copy a full tree or selected paths, then verify every copied file."""
    source = source.expanduser().resolve()
    destination = destination.expanduser().resolve(strict=False)
    if not source.is_dir():
        raise CompanionError(f"Backup source is not a folder: {source}")
    ensure_distinct_trees(source, destination)
    selection_list = list(selection) if selection is not None else None
    files, empty_directories = iter_source_files(source, selection_list)
    selected = sorted(set(selection_list or []))
    for item in selected:
        safe_relative(item)
    destination.mkdir(parents=True, exist_ok=True)
    backup_id = _backup_id()
    staging = Path(tempfile.mkdtemp(prefix=".flipper-backup-staging-", dir=destination))
    final = destination / backup_id
    try:
        payload = staging / "files"
        payload.mkdir()
        records: list[dict[str, Any]] = []
        for relative in files:
            source_file = path_inside(source, relative)
            before = source_file.stat()
            expected = sha256_file(source_file)
            target = path_inside(payload, relative)
            copied = copy_file_verified(source_file, target, expected)
            after = source_file.stat()
            if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                raise CompanionError(f"Source changed during backup: {relative}. Backup aborted.")
            records.append({
                "path": relative,
                "size": after.st_size,
                "sha256": copied,
                "mode": after.st_mode & 0o777,
                "mtime_ns": after.st_mtime_ns,
            })
        for relative in empty_directories:
            path_inside(payload, relative).mkdir(parents=True, exist_ok=True)
        kit_version = "not-recorded"
        if root is not None:
            try:
                kit_version = str(load_metadata(root).get("kit_version", "unknown"))
            except CompanionError:
                kit_version = "unknown"
        manifest = {
            "schema_version": SCHEMA_VERSION,
            "backup_id": backup_id,
            "created_at": utc_now(),
            "companion_version": COMPANION_VERSION,
            "kit_version": kit_version,
            "source": str(source),
            "scope": "full" if selection is None else "selected",
            "selection": selected,
            "complete_file_manifest": True,
            "file_count": len(records),
            "total_bytes": sum(item["size"] for item in records),
            "files": records,
            "empty_directories": empty_directories,
            "hash_algorithm": "sha256",
            "restore_policy": "No deletion; differing existing files require a safety backup and Confirm.",
        }
        _atomic_json(staging / "manifest.json", manifest)
        digest = sha256_file(staging / "manifest.json")
        (staging / "manifest.sha256").write_text(f"{digest}  manifest.json\n", encoding="ascii")
        # Re-read the staged copy before making it visible as a completed backup.
        verify_backup(staging)
        atomic_replace(staging, final)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    reporter(f"Verified backup: {final} ({len(files)} files).")
    reporter(
        "This plain backup is not encrypted. Anyone who can read its folder or storage device may read its contents; "
        "use backup --private for sensitive files."
    )
    return final


def _read_manifest(backup: Path) -> dict[str, Any]:
    try:
        expected_digest = (backup / "manifest.sha256").read_text(encoding="ascii").split()[0]
        if sha256_file(backup / "manifest.json") != expected_digest:
            raise CompanionError("Backup manifest checksum does not match.")
        with (backup / "manifest.json").open(encoding="utf-8") as handle:
            manifest = json.load(handle)
    except CompanionError:
        raise
    except (OSError, ValueError, IndexError, json.JSONDecodeError) as exc:
        raise CompanionError("Backup manifest or its checksum is missing/unreadable.") from exc
    if manifest.get("schema_version") != SCHEMA_VERSION or not manifest.get("complete_file_manifest"):
        raise CompanionError("Unsupported or incomplete backup manifest.")
    records = manifest.get("files")
    if not isinstance(records, list):
        raise CompanionError("Backup file manifest is invalid.")
    paths: set[str] = set()
    for record in records:
        if not isinstance(record, dict):
            raise CompanionError("Backup file record is invalid.")
        relative = safe_relative(str(record.get("path", "")))
        if relative in paths:
            raise CompanionError(f"Duplicate backup path: {relative}")
        paths.add(relative)
        digest = str(record.get("sha256", ""))
        if len(digest) != 64 or any(char not in "0123456789abcdef" for char in digest):
            raise CompanionError(f"Invalid SHA-256 for {relative}")
    if manifest.get("file_count") != len(records):
        raise CompanionError("Backup file count does not match its manifest.")
    return manifest


def verify_backup(backup: Path) -> dict[str, Any]:
    backup = backup.expanduser().resolve()
    manifest = _read_manifest(backup)
    payload = backup / "files"
    if not payload.is_dir():
        raise CompanionError("Backup payload folder is missing.")
    actual_files, _ = iter_source_files(payload)
    expected_files = [record["path"] for record in manifest["files"]]
    if set(actual_files) != set(expected_files):
        missing = sorted(set(expected_files) - set(actual_files))
        extra = sorted(set(actual_files) - set(expected_files))
        raise CompanionError(f"Backup payload differs from manifest (missing={missing}, unexpected={extra}).")
    for record in manifest["files"]:
        path = path_inside(payload, record["path"])
        if path.stat().st_size != record["size"] or sha256_file(path) != record["sha256"]:
            raise CompanionError(f"Backup verification failed: {record['path']}")
    for relative in manifest.get("empty_directories") or []:
        empty = path_inside(payload, safe_relative(relative))
        if not empty.is_dir() or any(empty.iterdir()):
            raise CompanionError(f"Backup empty-directory manifest does not match: {relative}")
    return manifest


def restore_backup(
    backup: Path,
    target: Path,
    *,
    safety_backup: Path | None,
    yes: bool = False,
    root: Path | None = None,
    reporter: Reporter = _silent,
    input_function: Any = input,
) -> dict[str, Any]:
    """Restore only manifest files; never delete unrelated RogueMaster content."""
    backup = backup.expanduser().resolve()
    target = target.expanduser().resolve()
    if not target.is_dir():
        raise CompanionError(f"Restore target is not a mounted folder: {target}")
    manifest = verify_backup(backup)
    payload = backup / "files"
    conflicts: list[str] = []
    for record in manifest["files"]:
        destination = path_inside(target, record["path"])
        if destination.exists() and not destination.is_file():
            raise CompanionError(f"Restore target is not a regular file: {record['path']}")
        if destination.is_file() and sha256_file(destination) != record["sha256"]:
            conflicts.append(record["path"])
    if conflicts and safety_backup is None:
        raise CompanionError(
            "Restore would replace existing files. Choose --safety-backup FOLDER so the current SD can be saved first."
        )
    reporter(f"Restore review: {len(manifest['files'])} files; {len(conflicts)} differing existing files.")
    reporter("No files outside the backup manifest will be deleted.")
    if conflicts:
        reporter("A complete pre-restore safety backup will be made before any replacement.")
    reporter(
        "Keep the SD card and computer connected until completion. Power loss can leave a partial restore; "
        "already-copied files are not rolled back, so rerun and verify after an interruption."
    )
    confirm_change("Review the paths and backup above.", yes, input_function)
    safety_path: Path | None = None
    if conflicts:
        safety_path = create_backup(target, safety_backup.expanduser(), root=root, reporter=reporter)
        # A restore requested during backup creation must still leave the target unchanged.
        verify_backup(safety_path)
    restored = 0
    unchanged = 0
    for record in manifest["files"]:
        source = path_inside(payload, record["path"])
        destination = path_inside(target, record["path"])
        if destination.is_file() and sha256_file(destination) == record["sha256"]:
            unchanged += 1
            continue
        copy_file_verified(source, destination, record["sha256"])
        if sha256_file(destination) != record["sha256"]:
            raise CompanionError(f"Post-restore verification failed: {record['path']}")
        restored += 1
    for relative in manifest.get("empty_directories") or []:
        path_inside(target, relative).mkdir(parents=True, exist_ok=True)
    result = {
        "restored": restored,
        "unchanged": unchanged,
        "safety_backup": str(safety_path) if safety_path else None,
        "deleted": 0,
    }
    reporter(f"Verified restore complete: {restored} restored, {unchanged} unchanged, 0 deleted.")
    reporter("Use the operating system's safe-eject action before removing the SD card; do not unplug during a restore.")
    return result


def protected_staging_root(path: Path) -> Path:
    path = path.expanduser()
    if path.exists() and path.is_symlink():
        raise CompanionError("Protected staging root must not be a symbolic link.")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path, 0o700)
    return path.resolve()


def best_effort_wipe_tree(path: Path, reporter: Reporter = _silent) -> None:
    """Overwrite normal files where practical, then remove the unique staging tree."""
    if not path.exists() or path.is_symlink():
        return
    for current, directories, files in os.walk(path, topdown=False, followlinks=False):
        for name in files:
            item = Path(current) / name
            try:
                if item.is_symlink() or not item.is_file():
                    item.unlink(missing_ok=True)
                    continue
                size = item.stat().st_size
                with item.open("r+b", buffering=0) as handle:
                    remaining = size
                    while remaining:
                        block = secrets.token_bytes(min(1024 * 1024, remaining))
                        handle.write(block)
                        remaining -= len(block)
                    handle.flush()
                    os.fsync(handle.fileno())
                item.unlink()
            except OSError:
                # Removal is still attempted below; no claim of guaranteed erasure.
                try:
                    item.unlink()
                except OSError:
                    pass
        for name in directories:
            try:
                (Path(current) / name).rmdir()
            except OSError:
                pass
    try:
        path.rmdir()
    except OSError:
        pass
    reporter(FLASH_ERASE_NOTICE)


def _choose_crypto(tool: str, which: Callable[[str], str | None] = shutil.which) -> tuple[str, str]:
    if tool == "auto":
        tool = "age" if which("age") else "gpg" if (which("gpg") or which("gpg2")) else ""
    if not tool:
        raise CompanionError(
            "No supported encryption tool found. Install age or GnuPG using your distribution's trusted packages."
        )
    if tool == "age":
        executable = which("age")
    elif tool == "gpg":
        executable = which("gpg") or which("gpg2")
    else:
        raise CompanionError("Encryption tool must be auto, age, or gpg.")
    if not executable:
        raise CompanionError(
            "No supported encryption tool found. Install age or GnuPG using your distribution's trusted packages."
        )
    return tool, executable


def _read_new_passphrase(reader: Callable[[str], str]) -> str:
    first = reader("New encryption passphrase (not shown): ")
    second = reader("Repeat encryption passphrase (not shown): ")
    if not first:
        raise CompanionError("Encryption passphrase must not be empty.")
    if first != second:
        raise CompanionError("Passphrases did not match. Nothing was encrypted.")
    return first


def _run_crypto(
    tool: str,
    executable: str,
    *,
    decrypt: bool,
    source: Path,
    output: Path,
    passphrase: str,
    runner: Any,
) -> None:
    """Secrets travel only over stdin, never argv, environment, files, or logs."""
    if tool == "age":
        command = [executable, "-d", "-o", str(output), str(source)] if decrypt else [
            executable, "-p", "-o", str(output), str(source)
        ]
        secret_input = passphrase + "\n"
    else:
        command = [executable, "--batch", "--yes", "--pinentry-mode", "loopback", "--passphrase-fd", "0"]
        command += ["--decrypt", "--output", str(output), str(source)] if decrypt else [
            "--symmetric", "--cipher-algo", "AES256", "--output", str(output), str(source)
        ]
        secret_input = passphrase + "\n"
    try:
        result = runner(command, input=secret_input, text=True, capture_output=True, check=False)
    except OSError as exc:
        raise CompanionError(f"Could not start {tool}. No encrypted output was completed.") from exc
    if result.returncode != 0 or not output.is_file():
        output.unlink(missing_ok=True)
        # Do not relay tool output: some wrappers/pinentry helpers can echo input.
        raise CompanionError(f"{tool} failed with exit code {result.returncode}. No passphrase or tool output was logged.")


def create_encrypted_backup(
    source: Path,
    destination: Path,
    *,
    selection: Iterable[str] | None = None,
    tool: str = "auto",
    staging_root: Path,
    root: Path | None = None,
    reporter: Reporter = _silent,
    runner: Any = subprocess.run,
    passphrase_reader: Callable[[str], str] = getpass.getpass,
    which: Callable[[str], str | None] = shutil.which,
) -> Path:
    source = source.expanduser().resolve()
    destination = destination.expanduser().resolve(strict=False)
    ensure_distinct_trees(source, destination)
    ensure_distinct_trees(source, staging_root.expanduser())
    chosen, executable = _choose_crypto(tool, which)
    passphrase = _read_new_passphrase(passphrase_reader)
    # age passphrase encryption confirms on a terminal; when scripted through stdin,
    # supply the confirmation too. GPG consumes only the first line in loopback mode.
    crypto_passphrase = passphrase + ("\n" + passphrase if chosen == "age" else "")
    protected = protected_staging_root(staging_root)
    work = Path(tempfile.mkdtemp(prefix="flipper-private-", dir=protected))
    try:
        plain = create_backup(source, work / "plain", selection=selection, root=root, reporter=reporter)
        archive = work / "private-backup.tar"
        with tarfile.open(archive, "w") as tar:
            tar.add(plain, arcname=plain.name, recursive=True)
        destination.mkdir(parents=True, exist_ok=True)
        suffix = ".age" if chosen == "age" else ".gpg"
        output = destination / f"{plain.name}.tar{suffix}"
        if output.exists():
            raise CompanionError(f"Encrypted output already exists; refusing to overwrite: {output}")
        # The ciphertext temporary lives beside its final output so os.replace is
        # atomic even when plaintext staging and the destination are on disks.
        temporary = destination / f".{output.name}.{secrets.token_hex(4)}.tmp"
        _run_crypto(
            chosen, executable, decrypt=False, source=archive, output=temporary,
            passphrase=crypto_passphrase, runner=runner,
        )
        atomic_replace(temporary, output)
        reporter(f"Encrypted private backup created: {output}")
        reporter("Keep this encrypted file on the computer; it is not a Flipper-executable payload.")
        return output
    finally:
        best_effort_wipe_tree(work, reporter)


def _extract_tar_protected(archive: Path, destination: Path) -> Path:
    """Validate the whole archive before writing any plaintext.

    Validation is deliberately separate from extraction: an invalid second
    root, duplicate destination, or unsafe later member must not leave a
    partially extracted tree that could be mistaken for a usable backup.
    """
    roots: set[str] = set()
    seen: set[str] = set()
    try:
        with tarfile.open(archive, "r") as tar:
            members = tar.getmembers()
            for member in members:
                pure = PurePosixPath(member.name)
                if pure.is_absolute() or not pure.parts:
                    raise CompanionError("Encrypted archive contains an unsafe path.")
                relative = safe_relative(pure.as_posix().rstrip("/") if member.isdir() else pure.as_posix())
                if relative in seen:
                    raise CompanionError(f"Encrypted archive contains a duplicate path: {relative}")
                seen.add(relative)
                if member.issym() or member.islnk() or not (member.isfile() or member.isdir()):
                    raise CompanionError("Encrypted archive contains links or special files; restore refused.")
                roots.add(pure.parts[0])
            if len(roots) != 1:
                raise CompanionError("Encrypted backup must contain exactly one backup folder.")
            for member in members:
                relative = safe_relative(PurePosixPath(member.name).as_posix().rstrip("/") if member.isdir() else member.name)
                target = path_inside(destination, relative)
                if member.isdir():
                    if target.exists() and not target.is_dir():
                        raise CompanionError(f"Encrypted archive directory collides with a file: {relative}")
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    if target.exists():
                        raise CompanionError(f"Encrypted archive file collides with another entry: {relative}")
                    source = tar.extractfile(member)
                    if source is None:
                        raise CompanionError("Encrypted archive file could not be read.")
                    with source, target.open("xb") as output:
                        shutil.copyfileobj(source, output)
    except CompanionError:
        raise
    except (OSError, tarfile.TarError) as exc:
        raise CompanionError("Encrypted backup archive is unreadable or unsafe; restore refused.") from exc
    return path_inside(destination, next(iter(roots)))


def restore_encrypted_backup(
    encrypted: Path,
    target: Path,
    *,
    safety_backup: Path | None,
    staging_root: Path,
    tool: str = "auto",
    yes: bool = False,
    root: Path | None = None,
    reporter: Reporter = _silent,
    runner: Any = subprocess.run,
    passphrase_reader: Callable[[str], str] = getpass.getpass,
    which: Callable[[str], str | None] = shutil.which,
    input_function: Any = input,
) -> dict[str, Any]:
    encrypted = encrypted.expanduser().resolve()
    target = target.expanduser().resolve()
    if encrypted.suffix.lower() not in {".age", ".gpg", ".pgp"}:
        raise CompanionError("Choose an .age, .gpg, or .pgp encrypted backup.")
    ensure_distinct_trees(target, staging_root.expanduser())
    chosen = tool
    if chosen == "auto":
        chosen = "age" if encrypted.suffix.lower() == ".age" else "gpg"
    chosen, executable = _choose_crypto(chosen, which)
    passphrase = passphrase_reader("Decryption passphrase (not shown): ")
    if not passphrase:
        raise CompanionError("Decryption passphrase must not be empty.")
    protected = protected_staging_root(staging_root)
    work = Path(tempfile.mkdtemp(prefix="flipper-private-restore-", dir=protected))
    try:
        archive = work / "decrypted.tar"
        _run_crypto(
            chosen, executable, decrypt=True, source=encrypted, output=archive,
            passphrase=passphrase, runner=runner,
        )
        unpacked = work / "unpacked"
        unpacked.mkdir()
        plain = _extract_tar_protected(archive, unpacked)
        reporter("Decryption succeeded only inside the protected computer staging folder.")
        return restore_backup(
            plain, target, safety_backup=safety_backup, yes=yes, root=root,
            reporter=reporter, input_function=input_function,
        )
    finally:
        best_effort_wipe_tree(work, reporter)
