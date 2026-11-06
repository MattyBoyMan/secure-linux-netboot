#!/usr/bin/env python3
"""Build, verify, stage and install Secure Linux offline application bundles.

Only Python's standard library is required for planning, direct release downloads,
verification and installation. Distribution repositories must be acquired on a
matching Fedora or Debian host; Flatpak USB repositories require Flatpak.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import fnmatch
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

SCHEMA = "secure-linux.offline-bundle.v1"
PLAN_SCHEMA = "secure-linux.offline-plan.v1"
REPO_SCHEMA = "secure-linux.offline-repository.v1"
FLATPAK_SCHEMA = "secure-linux.offline-flatpak-repository.v1"
USER_AGENT = "Secure-Linux-Offline-Bundle/1.0"
MAX_METADATA_BYTES = 16 * 1024 * 1024
CHUNK = 1024 * 1024


class BundleError(RuntimeError):
    pass


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")


def atomic_write(path: Path, data: bytes, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def write_json(path: Path, value: object) -> None:
    atomic_write(path, json_bytes(value))


def load_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise BundleError(f"Cannot read valid JSON from {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise BundleError(f"Expected a JSON object in {path}")
    return value


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            block = handle.read(CHUNK)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def safe_path(root: Path, relative: str) -> Path:
    if not isinstance(relative, str) or not relative or "\\" in relative:
        raise BundleError(f"Unsafe bundle path: {relative!r}")
    pure = PurePosixPath(relative)
    if pure.is_absolute() or ".." in pure.parts or "." in pure.parts:
        raise BundleError(f"Unsafe bundle path: {relative!r}")
    root_resolved = root.resolve()
    result = root.joinpath(*pure.parts)
    resolved = result.resolve(strict=False)
    if resolved != root_resolved and root_resolved not in resolved.parents:
        raise BundleError(f"Bundle path escapes its root: {relative!r}")
    if result.is_symlink():
        raise BundleError(f"Symbolic links are not accepted as payloads: {relative!r}")
    return result


def request_bytes(url: str, limit: int = MAX_METADATA_BYTES, attempts: int = 3) -> bytes:
    headers = {"User-Agent": USER_AGENT, "Accept": "application/vnd.github+json, application/octet-stream, */*"}
    token = os.environ.get("GITHUB_TOKEN")
    if token and "api.github.com" in url:
        headers["Authorization"] = f"Bearer {token}"
    last_error: Exception | None = None
    for attempt in range(attempts):
        try:
            request = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(request, timeout=60) as response:
                length = response.headers.get("Content-Length")
                if length and int(length) > limit:
                    raise BundleError(f"Metadata exceeds {limit} bytes: {url}")
                data = response.read(limit + 1)
                if len(data) > limit:
                    raise BundleError(f"Metadata exceeds {limit} bytes: {url}")
                return data
        except (urllib.error.URLError, TimeoutError, OSError, BundleError) as exc:
            last_error = exc
            if attempt + 1 < attempts:
                time.sleep(2 ** attempt)
    raise BundleError(f"Download failed after {attempts} attempts: {url}: {last_error}")


def github_latest(repository: str) -> dict:
    url = f"https://api.github.com/repos/{repository}/releases/latest"
    try:
        result = json.loads(request_bytes(url))
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise BundleError(f"Invalid GitHub release metadata for {repository}: {exc}") from exc
    if not isinstance(result, dict) or not result.get("tag_name"):
        raise BundleError(f"No latest release is available for {repository}")
    return result


def asset_arch(name: str) -> str | None:
    lower = name.lower()
    if re.search(r"(aarch64|arm64)", lower):
        return "aarch64"
    if re.search(r"(x86_64|amd64|x64)", lower):
        return "x86_64"
    return None


def asset_format(name: str) -> str | None:
    lower = name.lower()
    if lower.endswith(".tar.gz"):
        return "tar.gz"
    if lower.endswith(".rpm"):
        return "rpm"
    if lower.endswith(".deb"):
        return "deb"
    if lower.endswith(".appimage"):
        return "AppImage"
    return None


def checksum_asset(assets: list[dict], component: str) -> dict | None:
    patterns = ["checksums.txt"] if component == "immich-go" else ["sha256sums", "sha256sums.txt"]
    for asset in assets:
        if asset.get("name", "").lower() in patterns:
            return asset
    return None


def checksum_from_text(data: bytes, filename: str) -> str | None:
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        return None
    for line in text.splitlines():
        match = re.match(r"^([0-9a-fA-F]{64})\s+[*]?(.+?)\s*$", line)
        if not match:
            continue
        candidate = match.group(2).strip().removeprefix("./")
        if candidate == filename:
            return match.group(1).lower()
    return None


def bundle_dir_from_args(args: argparse.Namespace) -> Path:
    return Path(args.bundle).expanduser().resolve()


def source_config(path: Path) -> dict:
    config = load_json(path)
    if config.get("schema") != "secure-linux.offline-sources.v1":
        raise BundleError("Unsupported sources.json schema")
    budget = config["budget"]
    calculated = budget["nominal_usb_bytes"] - budget["reserved_existing_usb_bytes"] - budget["reserved_headroom_bytes"]
    if calculated != budget["maximum_bundle_bytes"] or calculated <= 0:
        raise BundleError("The configured USB budget is inconsistent")
    return config


def target_release(config: dict, distro: str, arch: str) -> str:
    target = config["targets"][distro]
    return str(target.get("releases", {}).get(arch, target["release"]))


def profile_packages(profile: dict, arch: str) -> list[str]:
    packages = list(profile["packages"])
    if profile["distro"] == "debian" and arch == "i386":
        packages = [package for package in packages if package != "flatpak"]
    return packages


def profile_flatpaks(profile: dict, arch: str) -> list[str]:
    if profile["distro"] == "debian" and arch == "i386":
        return []
    return list(profile["flatpaks"])


def acquisition_gap(profile_name: str, profile: dict, arch: str, kind: str, config: dict) -> dict:
    distro = profile["distro"]
    release = target_release(config, distro, arch)
    if kind == "flatpak":
        return {
            "id": f"{profile_name}-{arch}-flatpak",
            "profile": profile_name,
            "arch": arch,
            "kind": kind,
            "status": "requires-acquisition",
            "reason": f"A real Flatpak USB repository with apps, runtimes and related refs must be created on a matching {distro} {release} {arch} host; no app is claimed from its ID alone.",
            "command": f"python3 offline_bundle.py acquire-flatpak --bundle BUNDLE --profile {profile_name} --arch {arch}",
        }
    tool = "dnf download --resolve --alldeps plus rpm and createrepo_c" if distro == "fedora" else "apt-get download-only resolution plus dpkg-deb"
    return {
        "id": f"{profile_name}-{arch}-system",
        "profile": profile_name,
        "arch": arch,
        "kind": "system",
        "status": "requires-matching-host",
        "reason": f"A real dependency-complete {profile['package_kind'].upper()} repository requires {tool} on {distro} {release} {arch}. Package names are requirements, not cached payloads.",
        "command": f"python3 offline_bundle.py acquire-system --bundle BUNDLE --profile {profile_name} --arch {arch}",
    }


def make_plan(config: dict) -> dict:
    entries: list[dict] = []
    gaps: list[dict] = [dict(item) for item in config.get("gaps", [])]
    direct = config["direct_releases"]
    art = direct["artcraft"]
    release_jobs = [("artcraft", repo, art) for repo in art["repositories"]]
    release_jobs.append(("immich-go", direct["immich-go"]["repository"], direct["immich-go"]))
    for component, repository, settings in release_jobs:
        try:
            release = github_latest(repository)
        except BundleError as exc:
            gaps.append({"id": f"release-{repository}", "status": "resolution-failed", "reason": str(exc)})
            continue
        assets = release.get("assets") or []
        sums = checksum_asset(assets, component)
        for fmt in settings["formats"]:
            for arch in settings["arches"]:
                component_name = "immich-go" if component == "immich-go" else repository.split("/", 1)[1]
                expected_arch = arch
                candidates = [
                    asset for asset in assets
                    if asset_format(asset.get("name", "")) == fmt
                    and asset_arch(asset.get("name", "")) == expected_arch
                    and (component != "immich-go" or asset.get("name", "").startswith("immich-go_Linux_"))
                ]
                entry_id = f"{component}/{component_name}/{fmt}/{arch}"
                if len(candidates) != 1:
                    gaps.append({
                        "id": entry_id,
                        "status": "unavailable" if not candidates else "ambiguous",
                        "reason": f"{repository} {release['tag_name']} has {len(candidates)} suitable {fmt} assets for {arch}; exactly one is required.",
                    })
                    continue
                asset = candidates[0]
                api_digest = asset.get("digest") or ""
                expected = api_digest[7:].lower() if api_digest.startswith("sha256:") else ""
                verification = {"github_api_digest": api_digest or None}
                if sums:
                    verification["release_checksum_url"] = sums["browser_download_url"]
                if not expected and sums:
                    try:
                        expected = checksum_from_text(request_bytes(sums["browser_download_url"]), asset["name"]) or ""
                    except BundleError as exc:
                        gaps.append({"id": entry_id + "-checksum", "status": "resolution-failed", "reason": str(exc)})
                if not re.fullmatch(r"[0-9a-f]{64}", expected):
                    gaps.append({
                        "id": entry_id,
                        "status": "unverifiable",
                        "reason": "Neither the GitHub asset digest nor the release checksum file supplied a SHA-256; the payload was not planned.",
                    })
                    continue
                entries.append({
                    "id": entry_id,
                    "component": component,
                    "name": component_name,
                    "repository": repository,
                    "version": release["tag_name"],
                    "release_id": release.get("id"),
                    "source_url": release.get("html_url"),
                    "url": asset["browser_download_url"],
                    "filename": asset["name"],
                    "format": fmt,
                    "arch": arch,
                    "bytes": int(asset["size"]),
                    "sha256": expected,
                    "license": settings["license"],
                    "verification": verification,
                    "possibly_outdated": True,
                    "required": True,
                })
    entries.sort(key=lambda item: item["id"])
    total = sum(item["bytes"] for item in entries)
    profiles: dict[str, dict] = {}
    for profile_name, profile in config["profiles"].items():
        distro = profile["distro"]
        profiles[profile_name] = {"arches": {}}
        for arch in config["targets"][distro]["arches"]:
            flatpaks = profile_flatpaks(profile, arch)
            gaps_for_arch = [acquisition_gap(profile_name, profile, arch, "system", config)]
            if flatpaks:
                gaps_for_arch.append(acquisition_gap(profile_name, profile, arch, "flatpak", config))
            profiles[profile_name]["arches"][arch] = {
                "packages": profile_packages(profile, arch),
                "flatpaks": flatpaks,
                "direct_components": profile["direct_components"] if arch in ("x86_64", "aarch64") else [],
                "gaps": gaps_for_arch,
            }
    return {
        "schema": PLAN_SCHEMA,
        "bundle_version": config["bundle_version"],
        "created_utc": utc_now(),
        "possibly_outdated": True,
        "budget": dict(config["budget"]),
        "planned_payload_bytes": total,
        "planned_payload_files": len(entries),
        "within_budget": total <= config["budget"]["maximum_bundle_bytes"],
        "direct_payloads": entries,
        "profiles": profiles,
        "gaps": gaps,
        "notes": [
            "This plan contains release metadata only until fetch populates and verifies payloads.",
            "All cached versions are possibly outdated; use normal online updates after installation.",
            "The budget reserves existing USB content and free-space headroom before any large download.",
        ],
    }


def load_plan(bundle: Path) -> tuple[dict, str]:
    plan_path = bundle / "plan.json"
    raw = plan_path.read_bytes()
    plan = load_json(plan_path)
    if plan.get("schema") != PLAN_SCHEMA:
        raise BundleError("Unsupported or missing plan.json")
    return plan, sha256_bytes(raw)


def require_approval(bundle: Path) -> tuple[dict, str]:
    plan, plan_hash = load_plan(bundle)
    approval = load_json(bundle / "approval.json")
    if approval.get("plan_sha256") != plan_hash:
        raise BundleError("The plan changed after approval, or approval.json is missing")
    if not plan.get("within_budget"):
        raise BundleError("Refusing an over-budget plan")
    return plan, plan_hash


def command_plan(args: argparse.Namespace) -> int:
    config = source_config(Path(args.sources).resolve())
    output = Path(args.output).expanduser().resolve()
    bundle = output / "app-bundles" / config["bundle_version"]
    if (bundle / "approval.json").exists():
        raise BundleError("Refusing to replace an approved plan; choose a new output directory")
    plan = make_plan(config)
    bundle.mkdir(parents=True, exist_ok=True)
    write_json(bundle / "plan.json", plan)
    write_json(bundle / "gaps.json", {"schema": SCHEMA, "bundle_version": plan["bundle_version"], "gaps": plan["gaps"]})
    _, plan_hash = load_plan(bundle)
    print(f"Plan: {bundle / 'plan.json'}")
    print(f"SHA-256: {plan_hash}")
    print(f"Direct payloads: {plan['planned_payload_files']} files, {plan['planned_payload_bytes']} bytes")
    print(f"Budget allowance: {plan['budget']['maximum_bundle_bytes']} bytes; within budget: {plan['within_budget']}")
    print(f"Resolution gaps: {len(plan['gaps'])} (see gaps.json)")
    print("Inspect plan.json, then approve this exact hash with the approve command before fetching.")
    return 0 if plan["within_budget"] else 2


def command_approve(args: argparse.Namespace) -> int:
    bundle = bundle_dir_from_args(args)
    plan, plan_hash = load_plan(bundle)
    if args.sha256.lower() != plan_hash:
        raise BundleError(f"Approval hash does not match plan.json (actual {plan_hash})")
    if not plan.get("within_budget"):
        raise BundleError("Refusing to approve an over-budget plan")
    write_json(bundle / "approval.json", {
        "schema": SCHEMA,
        "bundle_version": plan["bundle_version"],
        "plan_sha256": plan_hash,
        "approved_utc": utc_now(),
        "planned_payload_bytes": plan["planned_payload_bytes"],
        "maximum_bundle_bytes": plan["budget"]["maximum_bundle_bytes"],
    })
    print(f"Approved exact plan {plan_hash}")
    return 0


def pool_path(bundle: Path, expected_hash: str) -> tuple[str, Path]:
    relative = f"pool/sha256/{expected_hash[:2]}/{expected_hash}"
    return relative, safe_path(bundle, relative)


def download_payload(bundle: Path, entry: dict) -> dict:
    relative, destination = pool_path(bundle, entry["sha256"])
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + f".part-{os.getpid()}")
    try:
        if destination.exists():
            if not destination.is_file() or destination.stat().st_size != entry["bytes"] or sha256_file(destination) != entry["sha256"]:
                raise BundleError(f"Existing pool object is corrupt: {entry['id']}")
        else:
            headers = {"User-Agent": USER_AGENT, "Accept": "application/octet-stream"}
            with urllib.request.urlopen(urllib.request.Request(entry["url"], headers=headers), timeout=120) as response, temporary.open("wb") as output:
                total = 0
                while True:
                    block = response.read(CHUNK)
                    if not block:
                        break
                    total += len(block)
                    if total > entry["bytes"]:
                        raise BundleError(f"Payload exceeds planned size: {entry['id']}")
                    output.write(block)
                output.flush()
                os.fsync(output.fileno())
            if total != entry["bytes"]:
                raise BundleError(f"Size mismatch for {entry['id']}: expected {entry['bytes']}, received {total}")
            actual = sha256_file(temporary)
            if actual != entry["sha256"]:
                raise BundleError(f"SHA-256 mismatch for {entry['id']}: expected {entry['sha256']}, received {actual}")
            os.replace(temporary, destination)
        verification = dict(entry.get("verification") or {})
        checksum_url = verification.get("release_checksum_url")
        if checksum_url:
            checksum = checksum_from_text(request_bytes(checksum_url), entry["filename"])
            if checksum != entry["sha256"]:
                raise BundleError(f"Release SHA256SUMS mismatch or missing entry for {entry['id']}")
            verification["release_checksum_sha256"] = checksum
            verification["release_checksum_verified"] = True
        verification["github_api_digest_verified"] = True
        record = dict(entry)
        record.pop("url", None)
        record.update({
            "path": relative,
            "populated": True,
            "fetched_utc": utc_now(),
            "verification": verification,
        })
        return record
    finally:
        if temporary.exists():
            temporary.unlink()


def repo_relative(config: dict, profile_name: str, arch: str) -> str:
    profile = config["profiles"][profile_name]
    distro = profile["distro"]
    release = target_release(config, distro, arch)
    return f"repositories/{distro}-{release}-{arch}"


def flatpak_relative(profile_name: str, arch: str) -> str:
    return f"flatpak/{profile_name}-{arch}"


def read_repository(bundle: Path, relative: str) -> dict | None:
    path = safe_path(bundle, relative) / "repository.json"
    return load_json(path) if path.is_file() else None


def read_flatpak_repository(bundle: Path, relative: str) -> dict | None:
    path = safe_path(bundle, relative) / "flatpak-repository.json"
    return load_json(path) if path.is_file() else None


def direct_expected(plan: dict, profile_name: str, arch: str) -> list[dict]:
    profile = plan["profiles"][profile_name]["arches"][arch]
    components = set(profile["direct_components"])
    return [entry for entry in plan["direct_payloads"] if entry["component"] in components and entry["arch"] == arch and (entry["component"] != "artcraft" or entry["format"] == "rpm")]


def build_manifests(bundle: Path, config: dict, plan: dict, direct_records: list[dict]) -> list[Path]:
    by_id = {record["id"]: record for record in direct_records}
    paths: list[Path] = []
    for profile_name, profile in config["profiles"].items():
        for arch in config["targets"][profile["distro"]]["arches"]:
            expected = direct_expected(plan, profile_name, arch)
            direct_present = [by_id[item["id"]] for item in expected if item["id"] in by_id]
            repo_rel = repo_relative(config, profile_name, arch)
            repository = read_repository(bundle, repo_rel)
            fp_rel = flatpak_relative(profile_name, arch)
            flatpak_repo = read_flatpak_repository(bundle, fp_rel)
            expected_fp = profile_flatpaks(profile, arch)
            manifest = {
                "schema": SCHEMA,
                "bundle_version": plan["bundle_version"],
                "profile": profile_name,
                "distro": profile["distro"],
                "distro_release": target_release(config, profile["distro"], arch),
                "arch": arch,
                "generated_utc": utc_now(),
                "possibly_outdated": True,
                "package_kind": profile["package_kind"],
                "requested_packages": profile_packages(profile, arch),
                "system_repository": {
                    "path": repo_rel,
                    "metadata": "repodata/repomd.xml" if profile["distro"] == "fedora" else "Packages.gz",
                    "populated": repository is not None,
                    "complete": bool(repository and repository.get("complete")),
                    "package_records": repository.get("packages", []) if repository else [],
                    "gpg_keys": repository.get("gpg_keys", []) if repository else [],
                },
                "requested_flatpaks": expected_fp,
                "flatpak_repository": {
                    "path": fp_rel,
                    "populated": flatpak_repo is not None,
                    "complete": bool(flatpak_repo and flatpak_repo.get("complete")),
                    "refs": flatpak_repo.get("refs", []) if flatpak_repo else [],
                    "files": flatpak_repo.get("files", []) if flatpak_repo else [],
                },
                "components": {},
                "complete": False,
            }
            for component in profile["direct_components"] if arch in ("x86_64", "aarch64") else []:
                wanted = [item for item in expected if item["component"] == component]
                present = [by_id[item["id"]] for item in wanted if item["id"] in by_id]
                manifest["components"][component] = {
                    "required_payloads": [item["id"] for item in wanted],
                    "payloads": present,
                    "complete": len(present) == len(wanted) and bool(wanted),
                    "possibly_outdated": True,
                }
            direct_complete = all(manifest["components"][component]["complete"] for component in manifest["components"])
            fp_complete = not expected_fp or manifest["flatpak_repository"]["complete"]
            manifest["complete"] = direct_complete and fp_complete and manifest["system_repository"]["complete"]
            path = bundle / "manifests" / f"{profile_name}-{arch}.json"
            write_json(path, manifest)
            paths.append(path)
    write_json(bundle / "payloads.json", {
        "schema": SCHEMA,
        "bundle_version": plan["bundle_version"],
        "possibly_outdated": True,
        "direct_payloads": direct_records,
        "note": "Only files that exist and passed SHA-256 verification are listed as populated. System and Flatpak payload records live in their repository metadata and profile manifests.",
    })
    return paths


def current_gaps(bundle: Path, config: dict, plan: dict, direct_records: list[dict], fetch_errors: list[str] | None = None) -> dict:
    gaps = [dict(item) for item in plan.get("gaps", [])]
    by_id = {record["id"] for record in direct_records}
    for entry in plan["direct_payloads"]:
        if entry["id"] not in by_id:
            gaps.append({
                "id": entry["id"], "status": "not-populated", "format": entry["format"], "arch": entry["arch"],
                "reason": "The approved payload has not been downloaded and verified; it is not listed as installed or bundled.",
            })
    for profile_name, profile in config["profiles"].items():
        for arch in config["targets"][profile["distro"]]["arches"]:
            if read_repository(bundle, repo_relative(config, profile_name, arch)) is None:
                gaps.append(acquisition_gap(profile_name, profile, arch, "system", config))
            expected_fp = profile_flatpaks(profile, arch)
            if expected_fp and read_flatpak_repository(bundle, flatpak_relative(profile_name, arch)) is None:
                gaps.append(acquisition_gap(profile_name, profile, arch, "flatpak", config))
    if fetch_errors:
        gaps.extend({"id": f"fetch-error-{index + 1}", "status": "fetch-failed", "reason": error} for index, error in enumerate(fetch_errors))
    result = {"schema": SCHEMA, "bundle_version": plan["bundle_version"], "generated_utc": utc_now(), "gaps": gaps}
    write_json(bundle / "gaps.json", result)
    return result


def command_fetch(args: argparse.Namespace) -> int:
    bundle = bundle_dir_from_args(args)
    plan, _ = require_approval(bundle)
    config = source_config(Path(args.sources).resolve())
    if config["bundle_version"] != plan["bundle_version"]:
        raise BundleError("sources.json and plan.json use different bundle versions")
    entries = plan["direct_payloads"]
    if args.component:
        entries = [entry for entry in entries if entry["component"] == args.component]
    if args.repository:
        repositories = set(args.repository)
        entries = [entry for entry in entries if entry["repository"] in repositories]
    if not entries:
        raise BundleError("No planned payloads match the requested fetch filter")
    existing_path = bundle / "payloads.json"
    existing = load_json(existing_path).get("direct_payloads", []) if existing_path.is_file() else []
    selected_ids = {entry["id"] for entry in entries}
    records_by_id = {record["id"]: record for record in existing if record.get("id") not in selected_ids}
    errors: list[str] = []
    workers = max(1, min(args.workers, 8))
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {executor.submit(download_payload, bundle, entry): entry for entry in entries}
        for future in concurrent.futures.as_completed(futures):
            entry = futures[future]
            try:
                record = future.result()
                records_by_id[record["id"]] = record
                print(f"Verified {entry['id']} ({entry['bytes']} bytes)")
            except Exception as exc:
                errors.append(f"{entry['id']}: {exc}")
                print(f"FAILED {entry['id']}: {exc}", file=sys.stderr)
    records = sorted(records_by_id.values(), key=lambda item: item["id"])
    build_manifests(bundle, config, plan, records)
    current_gaps(bundle, config, plan, records, errors)
    generate_report(bundle, config, plan)
    selected_complete = selected_ids.issubset(records_by_id)
    print(f"Populated {len(records)}/{len(plan['direct_payloads'])} direct payloads overall; {len(errors)} fetch failures in this group")
    return 1 if errors or not selected_complete else 0


def verify_record(bundle: Path, record: dict) -> Path:
    if not record.get("populated"):
        raise BundleError(f"Manifest-only item is not installable: {record.get('id', '<unknown>')}")
    for field in ("path", "sha256", "bytes"):
        if field not in record:
            raise BundleError(f"Incomplete payload record {record.get('id', '<unknown>')}: missing {field}")
    path = safe_path(bundle, record["path"])
    if not path.is_file():
        raise BundleError(f"Missing payload: {record.get('id')} ({record['path']})")
    size = path.stat().st_size
    if size != record["bytes"]:
        raise BundleError(f"Size mismatch for {record.get('id')}: expected {record['bytes']}, found {size}")
    actual = sha256_file(path)
    if actual != record["sha256"]:
        raise BundleError(f"SHA-256 mismatch for {record.get('id')}: expected {record['sha256']}, found {actual}")
    return path


def load_manifest(bundle: Path, profile: str, arch: str) -> dict:
    manifest = load_json(bundle / "manifests" / f"{profile}-{arch}.json")
    if manifest.get("schema") != SCHEMA or manifest.get("profile") != profile:
        raise BundleError("Invalid profile manifest")
    if manifest.get("arch") != arch:
        raise BundleError(f"Architecture mismatch: requested {arch}, manifest is {manifest.get('arch')}")
    return manifest


def capability_name(value: str) -> str:
    value = value.strip()
    value = re.sub(r"\s*\([^)]*\)\s*$", "", value)
    value = re.split(r"\s*(?:>=|<=|=>|=<|=|>|<)\s*", value, maxsplit=1)[0]
    return value.strip().split(":", 1)[0] if value.strip().startswith("rpmlib(") is False else value.strip()


def requirement_names(value: str, distro: str) -> list[str]:
    if distro == "debian":
        alternatives = []
        for alternative in value.split("|"):
            name = alternative.strip()
            name = re.sub(r"\s*\([^)]*\)", "", name)
            name = re.sub(r"\s*\[[^]]*\]", "", name)
            name = re.sub(r":(?:any|native)$", "", name)
            if name:
                alternatives.append(name.strip())
        return alternatives
    return [capability_name(value)] if capability_name(value) else []


def resolve_repository(repository: dict, requested: list[str], distro: str) -> list[dict]:
    records = repository.get("packages") or []
    if not records:
        raise BundleError("The system repository has no populated package records")
    by_name: dict[str, list[dict]] = {}
    providers: dict[str, list[dict]] = {}
    for record in records:
        name = record.get("name", "")
        by_name.setdefault(name, []).append(record)
        providers.setdefault(name, []).append(record)
        for provided in record.get("provides", []) or []:
            providers.setdefault(capability_name(provided), []).append(record)
    selected: dict[str, dict] = {}
    queue = list(requested)
    while queue:
        requirement = queue.pop(0)
        alternatives = requirement_names(requirement, distro)
        candidates: list[dict] = []
        for alternative in alternatives:
            candidates = by_name.get(alternative) or providers.get(alternative) or []
            if candidates:
                break
        if not candidates:
            raise BundleError(f"No cached package provides required item: {requirement}")
        candidates = sorted(candidates, key=lambda item: (item.get("name") != alternatives[0], item.get("version", ""), item.get("release", "")), reverse=True)
        record = candidates[0]
        identity = record.get("id") or record.get("sha256")
        if identity in selected:
            continue
        selected[identity] = record
        dependencies = list(record.get("requires", []) or [])
        if distro == "debian":
            for field in ("pre_depends", "depends"):
                value = record.get(field, "") or ""
                dependencies.extend(part.strip() for part in value.split(",") if part.strip())
        queue.extend(dependency for dependency in dependencies if not dependency.strip().startswith("rpmlib("))
    return list(selected.values())


def verify_flatpak_files(bundle: Path, repository: dict) -> None:
    if not repository.get("complete"):
        raise BundleError("Flatpak repository metadata marks it incomplete")
    files = repository.get("files") or []
    refs = repository.get("refs") or []
    if not files or not refs:
        raise BundleError("Flatpak repository metadata has no files or refs")
    if not any(ref.startswith("runtime/") for ref in refs):
        raise BundleError("Flatpak repository is incomplete: no runtime refs were recorded")
    base_relative = repository["path"]
    base = safe_path(bundle, base_relative)
    config_file = base / "config"
    if not config_file.is_file():
        raise BundleError("Flatpak repository is incomplete: config is missing")
    for record in files:
        verify_record(bundle, record)
    for app in repository.get("requested_apps", []):
        app_ref = f"app/{app}/" 
        if not any(ref.startswith(app_ref) for ref in refs):
            raise BundleError(f"Flatpak repository has no ref for requested app {app}")


def selection(bundle: Path, profile: str, arch: str, kind: str, packages: list[str]) -> tuple[dict, list[dict], dict | None]:
    manifest = load_manifest(bundle, profile, arch)
    if kind in ("artcraft", "immich-go"):
        component = manifest.get("components", {}).get(kind)
        if not component:
            raise BundleError(f"{kind} is not selected by profile {profile}")
        required = component.get("required_payloads") or []
        records = component.get("payloads") or []
        by_id = {record.get("id"): record for record in records}
        missing = [item for item in required if item not in by_id]
        if missing or not required:
            raise BundleError(f"{kind} is incomplete; missing populated payloads: {', '.join(missing) or 'all'}")
        ordered = [by_id[item] for item in required]
        for record in ordered:
            if record.get("arch") != arch:
                raise BundleError(f"Wrong architecture in {record.get('id')}: {record.get('arch')} != {arch}")
            verify_record(bundle, record)
        return manifest, ordered, None
    if kind == "system":
        info = manifest.get("system_repository") or {}
        if not info.get("populated") or not info.get("complete"):
            raise BundleError(f"The {profile} {arch} system repository is manifest-only or incomplete")
        repository = load_json(safe_path(bundle, info["path"]) / "repository.json")
        if repository.get("schema") != REPO_SCHEMA or not repository.get("complete"):
            raise BundleError("System repository metadata is missing, unsupported or incomplete")
        if repository.get("arch") != arch or repository.get("distro") != manifest.get("distro") or str(repository.get("distro_release")) != str(manifest.get("distro_release")):
            raise BundleError("System repository distro, release or architecture does not match the selected profile")
        metadata = safe_path(safe_path(bundle, info["path"]), info["metadata"])
        if not metadata.is_file():
            raise BundleError(f"System repository dependency metadata is missing: {info['metadata']}")
        requested = packages or manifest.get("requested_packages") or []
        if not requested:
            raise BundleError("No system packages were requested")
        records = resolve_repository(repository, requested, manifest["distro"])
        for record in records:
            if record.get("arch") not in (arch, "noarch", "all", "any"):
                raise BundleError(f"Wrong package architecture for {record.get('id')}: {record.get('arch')}")
            verify_record(bundle, record)
        return manifest, records, repository
    if kind == "flatpak":
        info = manifest.get("flatpak_repository") or {}
        if not info.get("populated") or not info.get("complete"):
            raise BundleError(f"The {profile} {arch} Flatpak repository is manifest-only or incomplete")
        repository = load_json(safe_path(bundle, info["path"]) / "flatpak-repository.json")
        if repository.get("schema") != FLATPAK_SCHEMA or repository.get("arch") != arch:
            raise BundleError("Flatpak repository metadata or architecture is invalid")
        verify_flatpak_files(bundle, repository)
        return manifest, [], repository
    raise BundleError(f"Unknown installation kind: {kind}")


def command_verify(args: argparse.Namespace) -> int:
    bundle = bundle_dir_from_args(args)
    require_approval(bundle)
    if args.profile:
        if not args.arch:
            raise BundleError("--arch is required with --profile")
        kinds = ["system", "flatpak", "artcraft", "immich-go"] if args.kind == "all" else [args.kind]
        failures = []
        for kind in kinds:
            try:
                manifest = load_manifest(bundle, args.profile, args.arch)
                if kind in ("artcraft", "immich-go") and kind not in manifest.get("components", {}):
                    continue
                if kind == "flatpak" and not manifest.get("requested_flatpaks"):
                    continue
                selection(bundle, args.profile, args.arch, kind, args.packages)
                print(f"Verified {args.profile} {args.arch} {kind}")
            except BundleError as exc:
                failures.append(str(exc))
                print(f"FAILED: {exc}", file=sys.stderr)
        return 1 if failures else 0
    plan = load_plan(bundle)[0]
    failures = []
    for entry in plan["direct_payloads"]:
        try:
            record = dict(entry)
            record.update({"path": pool_path(bundle, entry["sha256"])[0], "populated": True})
            verify_record(bundle, record)
        except BundleError as exc:
            if not args.allow_incomplete:
                failures.append(str(exc))
    for metadata in bundle.glob("repositories/*/repository.json"):
        repository = load_json(metadata)
        for record in repository.get("packages", []):
            try:
                verify_record(bundle, record)
            except BundleError as exc:
                failures.append(str(exc))
    for metadata in bundle.glob("flatpak/*/flatpak-repository.json"):
        try:
            verify_flatpak_files(bundle, load_json(metadata))
        except BundleError as exc:
            failures.append(str(exc))
    for failure in failures:
        print(f"FAILED: {failure}", file=sys.stderr)
    if not failures:
        print("All populated payloads passed size and SHA-256 verification" + ("; incomplete items were allowed" if args.allow_incomplete else ""))
    return 1 if failures else 0


def executable(env_name: str, normal_name: str) -> str:
    configured = os.environ.get(env_name)
    if configured:
        return configured
    found = shutil.which(normal_name)
    if not found:
        raise BundleError(f"Required installer is not available: {normal_name}")
    return found


def run_command(command: list[str]) -> None:
    print(">> " + " ".join(command))
    result = subprocess.run(command, check=False)
    if result.returncode:
        raise BundleError(f"Installer exited with status {result.returncode}")


def install_immich(bundle: Path, record: dict) -> None:
    payload = verify_record(bundle, record)
    destination = Path(os.environ.get("SL_OFFLINE_IMMICH_DEST", "/usr/local/bin/immich-go"))
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + f".tmp-{os.getpid()}")
    try:
        with tarfile.open(payload, "r:gz") as archive:
            members = [member for member in archive.getmembers() if member.name.removeprefix("./") == "immich-go"]
            if len(members) != 1 or not members[0].isreg():
                raise BundleError("immich-go archive must contain exactly one regular immich-go executable")
            source = archive.extractfile(members[0])
            if source is None:
                raise BundleError("Cannot read immich-go from its archive")
            with source, temporary.open("wb") as output:
                shutil.copyfileobj(source, output, CHUNK)
        os.chmod(temporary, 0o755)
        os.replace(temporary, destination)
    finally:
        if temporary.exists():
            temporary.unlink()
    print(f"Installed cached, possibly outdated immich-go to {destination}")


def command_install(args: argparse.Namespace) -> int:
    bundle = bundle_dir_from_args(args)
    require_approval(bundle)
    kind = args.kind
    manifest, records, repository = selection(bundle, args.profile, args.arch, kind, args.packages)
    paths = [str(verify_record(bundle, record)) for record in records]
    if kind == "immich-go":
        if len(records) != 1:
            raise BundleError("Exactly one immich-go archive is required")
        install_immich(bundle, records[0])
        return 0
    if kind == "flatpak":
        assert repository is not None
        flatpak = executable("SL_OFFLINE_FLATPAK", "flatpak")
        repo_path = str(safe_path(bundle, repository["path"]))
        remote = "secure-linux-offline-bundle"
        apps = args.packages or repository.get("requested_apps") or []
        if not apps:
            raise BundleError("No Flatpak app IDs were requested")
        run_command([flatpak, "--system", "remote-add", "--if-not-exists", "--no-gpg-verify", remote, repo_path])
        try:
            run_command([flatpak, "--system", "install", "--noninteractive", "-y", remote] + apps)
        finally:
            subprocess.run([flatpak, "--system", "remote-delete", remote], check=False)
        print("Installed from the verified local Flatpak USB repository; cached versions are possibly outdated")
        return 0
    if manifest["package_kind"] == "rpm":
        if repository is not None:
            rpm = executable("SL_OFFLINE_RPM", "rpm")
            for key in repository.get("gpg_keys", []):
                key_path = safe_path(bundle, key)
                if not key_path.is_file():
                    raise BundleError(f"Missing RPM signing key: {key}")
                run_command([rpm, "--import", str(key_path)])
        dnf = executable("SL_OFFLINE_DNF", "dnf")
        run_command([dnf, "-y", "--disablerepo=*", "install"] + paths)
    elif manifest["package_kind"] == "deb":
        apt = executable("SL_OFFLINE_APT_GET", "apt-get")
        run_command([
            apt, "-y", "-q", "--no-download",
            "-o", "Dir::Etc::sourcelist=/dev/null", "-o", "Dir::Etc::sourceparts=-",
            "-o", "Acquire::Retries=0", "-o", "Dpkg::Options::=--force-confdef",
            "-o", "Dpkg::Options::=--force-confold", "install",
        ] + paths)
    else:
        raise BundleError("Unsupported package kind")
    print(f"Installed {kind} from verified local payloads; cached versions are possibly outdated")
    return 0


def payload_size_report(bundle: Path, plan: dict) -> dict:
    categories = {"direct_pool": bundle / "pool", "system_repositories": bundle / "repositories", "flatpak_repositories": bundle / "flatpak"}
    result_categories = {}
    all_paths: set[Path] = set()
    for name, directory in categories.items():
        files = [path for path in directory.rglob("*") if path.is_file() and not path.is_symlink()] if directory.is_dir() else []
        size = sum(path.stat().st_size for path in files)
        result_categories[name] = {"files": len(files), "bytes": size}
        all_paths.update(files)
    total_bytes = sum(path.stat().st_size for path in all_paths)
    return {
        "schema": SCHEMA,
        "bundle_version": plan["bundle_version"],
        "generated_utc": utc_now(),
        "possibly_outdated": True,
        "categories": result_categories,
        "total_payload_files": len(all_paths),
        "total_payload_bytes": total_bytes,
        "planned_direct_files": plan["planned_payload_files"],
        "planned_direct_bytes": plan["planned_payload_bytes"],
        "budget": plan["budget"],
        "within_budget": total_bytes <= plan["budget"]["maximum_bundle_bytes"],
        "counting_rule": "Regular payload/repository files only, counted once by relative path. Manifests, plans, reports and temporary files are excluded; logical bytes are reported rather than filesystem allocation.",
    }


def generate_report(bundle: Path, config: dict, plan: dict) -> dict:
    report = payload_size_report(bundle, plan)
    write_json(bundle / "size-report.json", report)
    direct_records = []
    payloads_path = bundle / "payloads.json"
    if payloads_path.is_file():
        direct_records = load_json(payloads_path).get("direct_payloads", [])
    lines = [
        f"# Secure Linux offline application bundle {plan['bundle_version']}",
        "",
        "**Cached versions are possibly outdated. After installation, use the normal dnf, apt, Flatpak and outside-app update mechanisms.**",
        "",
        "This bundle distinguishes real, hash-verified payloads from acquisition requirements. A package name, Flatpak ID, plan entry or gap is never an installed/bundled payload.",
        "",
        "## Actual populated payload content",
        "",
        f"- Direct release payloads: {len(direct_records)} of {plan['planned_payload_files']} planned; {report['categories']['direct_pool']['bytes']} bytes currently in the content-addressed pool.",
        f"- System repository files: {report['categories']['system_repositories']['files']}; {report['categories']['system_repositories']['bytes']} bytes.",
        f"- Flatpak repository files: {report['categories']['flatpak_repositories']['files']}; {report['categories']['flatpak_repositories']['bytes']} bytes.",
        f"- Total regular payload/repository files: {report['total_payload_files']}; {report['total_payload_bytes']} logical bytes.",
        f"- USB cache allowance: {plan['budget']['maximum_bundle_bytes']} bytes; within budget: {report['within_budget']}.",
        "",
        "The 64 GB budget is decimal (64,000,000,000 bytes), with 20,000,000,000 bytes reserved for existing ISOs/rescue/firmware content and 6,000,000,000 bytes headroom.",
        "",
        "## Profile status",
        "",
        "| Profile | Architecture | System packages | Flatpaks | Direct releases | Complete |",
        "|---|---|---|---|---|---|",
    ]
    for profile_name, profile in config["profiles"].items():
        for arch in config["targets"][profile["distro"]]["arches"]:
            path = bundle / "manifests" / f"{profile_name}-{arch}.json"
            if not path.is_file():
                continue
            manifest = load_json(path)
            system = "verified metadata present" if manifest["system_repository"]["complete"] else "gap: acquisition required"
            fp = "verified repository present" if manifest["flatpak_repository"]["complete"] else ("not requested" if not manifest["requested_flatpaks"] else "gap: acquisition required")
            components = manifest["components"]
            direct = "not requested" if not components else ", ".join(f"{name}: {'populated' if value['complete'] else 'incomplete'}" for name, value in components.items())
            lines.append(f"| {profile_name} | {arch} | {system} | {fp} | {direct} | {manifest['complete']} |")
    lines += [
        "",
        "See `gaps.json` for every unavailable or not-yet-acquired item, `size-report.json` for independent byte counts, and `manifests/` for exact versions, licenses, source URLs, hashes and verification provenance.",
        "",
        "## Offline use",
        "",
        "Run `offline_bundle.py verify --bundle BUNDLE --allow-incomplete` before staging. During installation, select only a populated component. Missing dependencies, corrupt files, missing repository metadata and architecture mismatches fail before a package manager is invoked.",
        "",
        "Stage into the existing USB builder's expected directory with `offline_bundle.py stage --bundle BUNDLE --stage <OutDir>/offline-packs`. The existing builder copies this as `linux-setup/offline`; no USB writer is modified here.",
        "",
    ]
    atomic_write(bundle / "README.md", "\n".join(lines).encode("utf-8"))
    return report


def command_report(args: argparse.Namespace) -> int:
    bundle = bundle_dir_from_args(args)
    plan, _ = load_plan(bundle)
    config = source_config(Path(args.sources).resolve())
    report = generate_report(bundle, config, plan)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["within_budget"] else 2


def host_os_release() -> dict[str, str]:
    result = {}
    for line in Path("/etc/os-release").read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            result[key] = value.strip().strip('"')
    return result


def require_matching_host(config: dict, profile_name: str, arch: str) -> dict:
    if platform.system() != "Linux":
        raise BundleError("Distribution acquisition must run on a matching Linux host")
    profile = config["profiles"][profile_name]
    distro = profile["distro"]
    release = target_release(config, distro, arch)
    os_release = host_os_release()
    if os_release.get("ID") != distro or os_release.get("VERSION_ID") != release:
        raise BundleError(f"Host must be {distro} {release}; found {os_release.get('ID')} {os_release.get('VERSION_ID')}")
    machine = platform.machine().lower()
    expected_machine = {"amd64": "x86_64", "i386": "i686"}.get(arch, arch)
    if machine != expected_machine and not (arch == "i386" and machine in ("i386", "i686")):
        raise BundleError(f"Host architecture {machine} does not match requested {arch}")
    if arch not in config["targets"][distro]["arches"]:
        raise BundleError(f"Unsupported target architecture {arch}")
    return profile


def require_tools(names: list[str]) -> None:
    missing = [name for name in names if not shutil.which(name)]
    if missing:
        raise BundleError("Missing acquisition tools: " + ", ".join(missing))


def store_system_file(bundle: Path, source: Path, repository_dir: Path, subdir: str) -> tuple[str, str, int]:
    digest = sha256_file(source)
    size = source.stat().st_size
    pool_rel, pooled = pool_path(bundle, digest)
    pooled.parent.mkdir(parents=True, exist_ok=True)
    if not pooled.exists():
        shutil.copy2(source, pooled)
    if pooled.stat().st_size != size or sha256_file(pooled) != digest:
        raise BundleError(f"Failed to store a verified system payload: {source}")
    destination = repository_dir / subdir / source.name
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        destination.unlink()
    try:
        os.link(pooled, destination)
    except OSError:
        shutil.copy2(pooled, destination)
    relative = destination.relative_to(bundle).as_posix()
    return relative, digest, size


def rpm_metadata(path: Path) -> dict:
    fields = subprocess.check_output([
        "rpm", "-qp", "--qf", "%{NAME}\\n%{VERSION}\\n%{RELEASE}\\n%{ARCH}\\n%{LICENSE}\\n%{URL}\\n", str(path)
    ], text=True).splitlines()
    if len(fields) < 6:
        raise BundleError(f"Cannot extract RPM metadata from {path}")
    requires = subprocess.check_output(["rpm", "-qp", "--requires", str(path)], text=True).splitlines()
    provides = subprocess.check_output(["rpm", "-qp", "--provides", str(path)], text=True).splitlines()
    return {"name": fields[0], "version": fields[1], "release": fields[2], "arch": fields[3], "license": fields[4], "source_url": fields[5], "requires": requires, "provides": provides}


def acquire_fedora(bundle: Path, config: dict, profile_name: str, arch: str, profile: dict) -> None:
    require_tools(["dnf", "rpm", "createrepo_c"])
    repo_rel = repo_relative(config, profile_name, arch)
    repo_dir = safe_path(bundle, repo_rel)
    release = target_release(config, "fedora", arch)
    with tempfile.TemporaryDirectory(prefix="secure-linux-rpms-") as temporary:
        temp = Path(temporary)
        packages = sorted(set(config["profiles"]["fedora-full"]["packages"] + config["profiles"]["fedora-lite"]["packages"]))
        run_command(["dnf", "download", "--resolve", "--alldeps", "--destdir", str(temp)] + packages)
        rpms = sorted(temp.glob("*.rpm"))
        if not rpms:
            raise BundleError("dnf download produced no RPM payloads")
        records = []
        for path in rpms:
            relative, digest, size = store_system_file(bundle, path, repo_dir, "packages")
            metadata = rpm_metadata(path)
            if metadata["arch"] not in (arch, "noarch"):
                raise BundleError(f"Downloaded wrong RPM architecture: {path.name} ({metadata['arch']})")
            records.append({
                "id": f"rpm/{metadata['name']}/{metadata['version']}-{metadata['release']}/{metadata['arch']}",
                "kind": "rpm", **metadata, "path": relative, "bytes": size, "sha256": digest,
                "populated": True, "possibly_outdated": True,
                "verification": {"sha256": digest, "provenance": "dnf download from the matching host's enabled, signed Fedora repositories"},
            })
        repo_dir.mkdir(parents=True, exist_ok=True)
        run_command(["createrepo_c", "--quiet", str(repo_dir)])
        keys = []
        key_dir = repo_dir / "gpg-keys"
        for key in sorted(Path("/etc/pki/rpm-gpg").glob("*")):
            if key.is_file():
                key_dir.mkdir(parents=True, exist_ok=True)
                destination = key_dir / key.name
                shutil.copy2(key, destination)
                keys.append(destination.relative_to(bundle).as_posix())
        if not keys:
            raise BundleError("No RPM GPG keys were copied; refusing to mark the repository complete")
        repository = {
            "schema": REPO_SCHEMA, "kind": "rpm", "distro": "fedora", "distro_release": release,
            "arch": arch, "path": repo_rel, "created_utc": utc_now(), "possibly_outdated": True,
            "complete": True, "metadata": "repodata/repomd.xml", "packages": records, "gpg_keys": keys,
        }
        write_json(repo_dir / "repository.json", repository)


def acquire_debian(bundle: Path, config: dict, profile_name: str, arch: str, profile: dict) -> None:
    require_tools(["apt-get", "dpkg-deb"])
    repo_rel = repo_relative(config, profile_name, arch)
    repo_dir = safe_path(bundle, repo_rel)
    release = target_release(config, "debian", arch)
    with tempfile.TemporaryDirectory(prefix="secure-linux-debs-") as temporary:
        temp = Path(temporary)
        archives = temp / "archives"
        (archives / "partial").mkdir(parents=True)
        status = temp / "status"
        status.touch()
        packages = profile_packages(profile, arch)
        run_command([
            "apt-get", "-y", "--download-only", "--no-install-recommends", "-o", "Debug::NoLocking=1",
            "-o", f"Dir::State::status={status}", "-o", f"Dir::Cache::archives={archives}",
            "-o", f"APT::Architecture={arch}", "install",
        ] + packages)
        debs = sorted(archives.glob("*.deb"))
        if not debs:
            raise BundleError("apt-get download-only produced no DEB payloads")
        records = []
        package_stanzas = []
        for path in debs:
            relative, digest, size = store_system_file(bundle, path, repo_dir, "pool")
            control = subprocess.check_output(["dpkg-deb", "-f", str(path)], text=True)
            fields = {}
            current = None
            for line in control.splitlines():
                if line[:1].isspace() and current:
                    fields[current] += "\n" + line
                elif ":" in line:
                    current, value = line.split(":", 1)
                    fields[current] = value.strip()
            name = fields.get("Package", "")
            package_arch = fields.get("Architecture", "")
            if not name or package_arch not in (arch, "all"):
                raise BundleError(f"Invalid or wrong-architecture DEB: {path.name}")
            stanza = control.rstrip() + f"\nFilename: pool/{path.name}\nSize: {size}\nSHA256: {digest}\n"
            package_stanzas.append(stanza)
            records.append({
                "id": f"deb/{name}/{fields.get('Version', '')}/{package_arch}", "kind": "deb", "name": name,
                "version": fields.get("Version", ""), "arch": package_arch,
                "license": "Not expressed in DEB control metadata; consult the package's installed copyright file",
                "source_url": fields.get("Homepage"), "pre_depends": fields.get("Pre-Depends", ""),
                "depends": fields.get("Depends", ""), "provides": fields.get("Provides", "").split(",") if fields.get("Provides") else [],
                "path": relative, "bytes": size, "sha256": digest, "populated": True, "possibly_outdated": True,
                "verification": {"sha256": digest, "provenance": "apt-get download-only from the matching host's configured, signed Debian repositories"},
            })
        repo_dir.mkdir(parents=True, exist_ok=True)
        packages_bytes = ("\n".join(package_stanzas) + "\n").encode("utf-8")
        atomic_write(repo_dir / "Packages", packages_bytes)
        with (repo_dir / "Packages").open("rb") as source, (repo_dir / "Packages.gz").open("wb") as raw:
            with gzip.GzipFile(filename="Packages", mode="wb", fileobj=raw, mtime=0) as compressed:
                shutil.copyfileobj(source, compressed)
        repository = {
            "schema": REPO_SCHEMA, "kind": "deb", "distro": "debian", "distro_release": release,
            "arch": arch, "path": repo_rel, "created_utc": utc_now(), "possibly_outdated": True,
            "complete": True, "metadata": "Packages.gz", "packages": records, "gpg_keys": [],
        }
        write_json(repo_dir / "repository.json", repository)


def command_acquire_system(args: argparse.Namespace) -> int:
    bundle = bundle_dir_from_args(args)
    plan, _ = require_approval(bundle)
    config = source_config(Path(args.sources).resolve())
    if args.profile not in config["profiles"]:
        raise BundleError(f"Unknown profile {args.profile}")
    profile = require_matching_host(config, args.profile, args.arch)
    if profile["distro"] == "fedora":
        acquire_fedora(bundle, config, args.profile, args.arch, profile)
    else:
        acquire_debian(bundle, config, args.profile, args.arch, profile)
    records = load_json(bundle / "payloads.json").get("direct_payloads", []) if (bundle / "payloads.json").is_file() else []
    build_manifests(bundle, config, plan, records)
    current_gaps(bundle, config, plan, records)
    generate_report(bundle, config, plan)
    print(f"Acquired real {args.profile} {args.arch} system payloads and dependency metadata")
    return 0


def command_acquire_flatpak(args: argparse.Namespace) -> int:
    bundle = bundle_dir_from_args(args)
    plan, _ = require_approval(bundle)
    config = source_config(Path(args.sources).resolve())
    if args.profile not in config["profiles"]:
        raise BundleError(f"Unknown profile {args.profile}")
    profile = require_matching_host(config, args.profile, args.arch)
    apps = profile_flatpaks(profile, args.arch)
    if not apps:
        raise BundleError("This profile/architecture requests no Flatpaks")
    require_tools(["flatpak", "ostree"])
    repo_rel = flatpak_relative(args.profile, args.arch)
    repo_dir = safe_path(bundle, repo_rel)
    if repo_dir.exists():
        raise BundleError(f"Refusing to overwrite an existing Flatpak repository: {repo_dir}")
    run_command(["flatpak", "--user", "install", "--noninteractive", "-y", "flathub"] + apps)
    repo_dir.parent.mkdir(parents=True, exist_ok=True)
    run_command(["flatpak", "--user", "create-usb", str(repo_dir)] + apps)
    refs = subprocess.check_output(["ostree", "refs", f"--repo={repo_dir}"], text=True).splitlines()
    files = []
    for path in sorted(repo_dir.rglob("*")):
        if path.is_file() and path.name != "flatpak-repository.json":
            relative = path.relative_to(bundle).as_posix()
            files.append({"id": f"flatpak-file/{relative}", "path": relative, "bytes": path.stat().st_size, "sha256": sha256_file(path), "populated": True})
    repository = {
        "schema": FLATPAK_SCHEMA, "path": repo_rel, "profile": args.profile, "arch": args.arch,
        "created_utc": utc_now(), "possibly_outdated": True, "complete": bool(refs and files),
        "requested_apps": apps, "refs": refs, "files": files,
        "verification": {"provenance": "flatpak create-usb includes apps, runtimes and related refs; every repository file is SHA-256 listed"},
    }
    write_json(repo_dir / "flatpak-repository.json", repository)
    records = load_json(bundle / "payloads.json").get("direct_payloads", []) if (bundle / "payloads.json").is_file() else []
    build_manifests(bundle, config, plan, records)
    current_gaps(bundle, config, plan, records)
    generate_report(bundle, config, plan)
    print(f"Acquired Flatpak USB repository with {len(refs)} refs and {len(files)} verified files")
    return 0


def command_stage(args: argparse.Namespace) -> int:
    bundle = bundle_dir_from_args(args)
    require_approval(bundle)
    stage = Path(args.stage).expanduser().resolve()
    if not stage.name == "offline-packs":
        raise BundleError("--stage must explicitly name the USB builder's offline-packs directory")
    if stage == bundle or stage in bundle.parents or bundle in stage.parents:
        raise BundleError("Stage and bundle directories must not contain one another")
    destination = stage / "app-bundles" / bundle.name
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(bundle, destination, dirs_exist_ok=True, symlinks=False)
    write_json(stage / "app-bundles" / "current.json", {"schema": SCHEMA, "bundle_version": bundle.name, "path": f"app-bundles/{bundle.name}", "possibly_outdated": True})
    print(f"Staged {destination}; the existing USB builder will copy it to linux-setup/offline")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources", default=str(Path(__file__).with_name("sources.json")), help="source configuration JSON")
    sub = parser.add_subparsers(dest="command", required=True)
    plan = sub.add_parser("plan", help="resolve release metadata and sizes without downloading payloads")
    plan.add_argument("--output", default=str(Path(__file__).with_name("dist")), help="dist directory")
    plan.set_defaults(function=command_plan)
    for name, help_text, function in [
        ("approve", "approve an exact plan SHA-256", command_approve),
        ("fetch", "download approved direct release payloads", command_fetch),
        ("verify", "verify populated payloads and selected installation content", command_verify),
        ("install", "install a verified component with network access disabled", command_install),
        ("report", "recount real payload files and bytes", command_report),
        ("acquire-system", "acquire RPM/DEB payloads on a matching distro host", command_acquire_system),
        ("acquire-flatpak", "create a real Flatpak USB repository on a matching host", command_acquire_flatpak),
        ("stage", "copy a bundle to an explicit offline-packs staging directory", command_stage),
    ]:
        command = sub.add_parser(name, help=help_text)
        command.add_argument("--bundle", required=True, help="versioned app-bundles/VERSION directory")
        command.set_defaults(function=function)
        if name == "approve":
            command.add_argument("--sha256", required=True)
        if name == "fetch":
            command.add_argument("--workers", type=int, default=4)
            command.add_argument("--component", choices=["artcraft", "immich-go"])
            command.add_argument("--repository", action="append", help="fetch only this owner/repository; repeatable")
        if name in ("verify", "install"):
            command.add_argument("--profile", choices=["fedora-full", "fedora-lite", "debian-lite"])
            command.add_argument("--arch")
            command.add_argument("--kind", choices=["all", "system", "flatpak", "artcraft", "immich-go"] if name == "verify" else ["system", "flatpak", "artcraft", "immich-go"], default="all" if name == "verify" else "system")
            command.add_argument("--packages", nargs="*", default=[])
        if name == "verify":
            command.add_argument("--allow-incomplete", action="store_true")
        if name in ("acquire-system", "acquire-flatpak"):
            command.add_argument("--profile", required=True, choices=["fedora-full", "fedora-lite", "debian-lite"])
            command.add_argument("--arch", required=True)
        if name == "stage":
            command.add_argument("--stage", required=True, help="explicit <OutDir>/offline-packs path")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.function(args))
    except BundleError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("Interrupted; no partial download is treated as a payload", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
