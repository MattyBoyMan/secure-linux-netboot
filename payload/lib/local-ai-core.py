#!/usr/bin/env python3
"""Secure Linux local AI: fixed catalog, hardware gates and verified local engines.

Standard library only.  This module never downloads during import, scan, list or
status.  Network access is confined to an explicitly confirmed pinned download.
"""
from __future__ import annotations

import ctypes
import dataclasses
import datetime as _datetime
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request
import uuid

GIB = 1024 ** 3
MIB = 1024 ** 2
COLIBRI_COMMIT = "0a5504a1dc64f86fcd0fe7db298b0448c730e7e6"
COLIBRI_ARCHIVE_SIZE = 15_032_099
COLIBRI_ARCHIVE_SHA256 = "eaaf3336fa65d29dc5190cfa83cd59df948f10213f14fe5347c21845f4e834e1"
COLIBRI_URL = f"https://github.com/JustVugg/colibri/archive/{COLIBRI_COMMIT}.tar.gz"
COLIBRI_LICENSE = "Apache-2.0 (engine); model licenses are separate"
OLLAMA_URL = "http://127.0.0.1:11434"
COLIBRI_URL_LOCAL = "http://127.0.0.1:8001"
MAX_ARCHIVE_MEMBERS = 5000
MAX_ARCHIVE_UNPACKED = 512 * MIB


class LocalAIError(RuntimeError):
    """Base error with a beginner-readable message."""


class ConfirmationRequired(LocalAIError):
    pass


class SafetyError(LocalAIError):
    pass


class VerificationError(LocalAIError):
    pass


class OfflineError(LocalAIError):
    pass


@dataclasses.dataclass(frozen=True)
class ModelSpec:
    id: str
    name: str
    family: str
    parameters: str
    quantization: str
    repo: str
    revision: str
    filename: str
    size: int
    sha256: str
    license: str
    engines: tuple
    coding_specialist: bool = True
    fewer_refusals: bool = False
    description: str = ""

    @property
    def url(self) -> str:
        # Catalog values are validated before this URL is used.
        return (f"https://huggingface.co/{self.repo}/resolve/{self.revision}/"
                f"{urllib.parse.quote(self.filename)}")

    @property
    def ollama_tag(self) -> str:
        return f"secure-ai/{self.id}:q4_k_m"


MODELS = (
    ModelSpec(
        "qwen25-coder-1_5b", "Qwen2.5 Coder 1.5B", "Qwen2.5-Coder", "1.5B",
        "Q4_K_M", "Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF",
        "f86cb2c1fa58255f8052cc32aeede1b7482d4361",
        "qwen2.5-coder-1.5b-instruct-q4_k_m.gguf", 1_117_320_768,
        "cc324af070c2ecbfd324a30884d2f951a7ff756aba85cb811a6ec436933bb046",
        "Apache-2.0", ("ollama",),
        description="Small coding assistant for modest machines; expect limited reasoning."),
    ModelSpec(
        "qwen25-coder-7b", "Qwen2.5 Coder 7B", "Qwen2.5-Coder", "7B",
        "Q4_K_M", "Qwen/Qwen2.5-Coder-7B-Instruct-GGUF",
        "13fb94bfda8c8cf22497dc57b78f391a9acb426a",
        "qwen2.5-coder-7b-instruct-q4_k_m.gguf", 4_683_073_536,
        "509287f78cb4d4cf6b3843734733b914b2c158e43e22a7f4bf5e963800894d3c",
        "Apache-2.0", ("ollama",),
        description="Balanced general coding model; review generated code before running it."),
    ModelSpec(
        "qwen25-coder-14b", "Qwen2.5 Coder 14B", "Qwen2.5-Coder", "14B",
        "Q4_K_M", "Qwen/Qwen2.5-Coder-14B-Instruct-GGUF",
        "d0a692ef765eefbf2fabb130b3cb2e8917e3d225",
        "qwen2.5-coder-14b-instruct-q4_k_m.gguf", 8_988_110_272,
        "c1e659736d89ac1065fb495330fb824d94001974a4bfa78e7270e43476a8d940",
        "Apache-2.0", ("ollama",),
        description="Larger coding model for machines with more memory and storage."),
    ModelSpec(
        "qwen25-coder-7b-fewer-refusals", "Qwen2.5 Coder 7B — fewer refusals",
        "Qwen2.5-Coder abliterated", "7B", "Q4_K_M",
        "bartowski/Qwen2.5-Coder-7B-Instruct-abliterated-GGUF",
        "a416f57ecabe9841551055493e6945895e54e135",
        "Qwen2.5-Coder-7B-Instruct-abliterated-Q4_K_M.gguf", 4_683_074_400,
        "fdf02c16fb654ff60b2c30f1e91573ebc603a7084df3449df89120dca2b18170",
        "Apache-2.0 (model card)", ("ollama",), fewer_refusals=True,
        description="Community refusal-reduced derivative; not a quality or safety upgrade."),
    ModelSpec(
        "qwen3-coder-30b-a3b", "Qwen3 Coder 30B-A3B", "Qwen3-Coder MoE",
        "30.5B total / 3.3B active", "Q4_K_M",
        "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF",
        "b17cb02dd882d5b6ab62fc777ad2995f19668350",
        "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf", 18_556_689_568,
        "fadc3e5f8d42bf7e894a785b05082e47daee4df26680389817e2093056f088ad",
        "Apache-2.0 (model card)", ("ollama", "colibri"),
        description="Large mixture-of-experts coding model; SSD and RAM sensitive, with costly long-context prefill."),
    ModelSpec(
        "qwen36-35b-a3b", "Qwen3.6 35B-A3B", "Qwen3.6 hybrid MoE",
        "35B total / 3B active", "UD-IQ4_XS",
        "unsloth/Qwen3.6-35B-A3B-GGUF",
        "a483e9e6cbd595906af30beda3187c2663a1118c",
        "Qwen3.6-35B-A3B-UD-IQ4_XS.gguf", 17_730_509_792,
        "649d7508507b84638732c4f52c24c8b15843c6dca2f3ff793ae07c14a67ebbb3",
        "Apache-2.0 (model card)", ("colibri",), coding_specialist=False,
        description="Large general hybrid MoE that can help with code; upstream suggests about 30 GB RAM for comfortable expert caching and NVMe storage."),
    ModelSpec(
        "qwen3-4b-fewer-refusals", "Qwen3 4B — fewer refusals",
        "Qwen3 abliterated", "4B", "Q4_K_M",
        "mradermacher/Huihui-Qwen3-4B-Instruct-2507-abliterated-GGUF",
        "c9e90669eeb205d5af35c28a3e9983fc9293c2ec",
        "Huihui-Qwen3-4B-Instruct-2507-abliterated.Q4_K_M.gguf", 2_497_281_312,
        "b1324e2f1bd2e0610d591f54f93e38d90b187f69d1f215f4cace349eade678d7",
        "Apache-2.0 (model card)", ("ollama", "colibri"),
        coding_specialist=False, fewer_refusals=True,
        description="General model that can help with code; not a coding-specialist quality claim."),
)
MODEL_BY_ID = {m.id: m for m in MODELS}

# Conservative wrapper gates, not upstream throughput claims.  Available memory
# is checked separately so a machine can be feasible but currently "tight".
RAM_GATES = {
    "qwen25-coder-1_5b": {"ollama": (4, 8)},
    "qwen25-coder-7b": {"ollama": (8, 16)},
    "qwen25-coder-14b": {"ollama": (16, 32)},
    "qwen25-coder-7b-fewer-refusals": {"ollama": (8, 16)},
    "qwen3-coder-30b-a3b": {"ollama": (32, 48), "colibri": (12, 24)},
    "qwen36-35b-a3b": {"colibri": (24, 32)},
    "qwen3-4b-fewer-refusals": {"ollama": (8, 16), "colibri": (8, 16)},
}


@dataclasses.dataclass
class Hardware:
    cpu_model: str
    architecture: str
    logical_cpus: int
    ram_total: int
    ram_available: int
    gpus: list
    storage_path: str
    storage_total: int
    storage_free: int
    platform: str


@dataclasses.dataclass(frozen=True)
class AIPaths:
    base: Path
    cache: Path
    runtime: Path

    @classmethod
    def default(cls) -> "AIPaths":
        home = Path.home()
        return cls(
            Path(os.environ.get("SECURE_LINUX_AI_HOME", home / ".local/share/secure-linux/local-ai")),
            Path(os.environ.get("SECURE_LINUX_AI_CACHE", home / ".cache/secure-linux/local-ai")),
            Path(os.environ.get("SECURE_LINUX_AI_RUNTIME", home / ".local/share/secure-linux/local-ai/run")),
        )

    @property
    def models(self) -> Path:
        return self.base / "models"

    @property
    def engines(self) -> Path:
        return self.base / "engines"

    @property
    def colibri_models(self) -> Path:
        return self.base / "colibri-models"

    @property
    def sessions(self) -> Path:
        return self.base / "sessions"

    @property
    def benchmarks(self) -> Path:
        return self.base / "benchmarks"


def get_model(model_id: str) -> ModelSpec:
    if not isinstance(model_id, str) or model_id not in MODEL_BY_ID:
        raise SafetyError("Unknown model ID. Choose only an entry from the fixed catalog.")
    return MODEL_BY_ID[model_id]


def format_size(count: int) -> str:
    if count >= GIB:
        return f"{count / GIB:.1f} GiB"
    return f"{count / MIB:.0f} MiB"


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def scan_hardware(storage_path=None, proc_root="/proc", sys_root="/sys", platform_name=None) -> Hardware:
    """Read real host resources.  No benchmarks and no invented tok/s estimates."""
    paths = AIPaths.default()
    target = Path(storage_path or paths.base)
    try:
        target.mkdir(parents=True, exist_ok=True)
        disk = shutil.disk_usage(target)
        storage_total, storage_free = disk.total, disk.free
    except OSError:
        disk = shutil.disk_usage(Path.home())
        target = Path.home()
        storage_total, storage_free = disk.total, disk.free
    system = platform_name or platform.system()
    architecture = platform.machine() or "unknown"
    cpus = os.cpu_count() or 1
    gpus = []
    if system == "Linux":
        cpuinfo = _read_text(Path(proc_root) / "cpuinfo")
        match = re.search(r"^(?:model name|Hardware)\s*:\s*(.+)$", cpuinfo, re.MULTILINE)
        cpu = match.group(1).strip() if match else "Linux processor"
        meminfo = _read_text(Path(proc_root) / "meminfo")
        values = {k: int(v) * 1024 for k, v in re.findall(r"^(\w+):\s+(\d+)\s+kB$", meminfo, re.MULTILINE)}
        total = values.get("MemTotal", 0)
        available = values.get("MemAvailable", values.get("MemFree", 0))
        drm = Path(sys_root) / "class/drm"
        try:
            cards = sorted(drm.glob("card[0-9]"))
        except OSError:
            cards = []
        for card in cards:
            vendor = _read_text(card / "device/vendor").strip().lower()
            names = {"0x1002": "AMD", "0x1022": "AMD", "0x8086": "Intel", "0x10de": "NVIDIA"}
            gpus.append({"name": names.get(vendor, "GPU"), "vendor": vendor or "unknown", "device": card.name})
        if not gpus and shutil.which("lspci"):
            try:
                result = subprocess.run(["lspci", "-nn"], capture_output=True, text=True, timeout=5, check=False)
                for line in result.stdout.splitlines():
                    if re.search(r"VGA|3D controller|Display controller", line, re.I):
                        gpus.append({"name": line.strip(), "vendor": "PCI", "device": "detected"})
            except (OSError, subprocess.SubprocessError):
                pass
    elif system == "Windows":
        cpu = platform.processor() or "Windows processor"
        class MEMORYSTATUSEX(ctypes.Structure):
            _fields_ = [("length", ctypes.c_ulong), ("memory_load", ctypes.c_ulong),
                        ("total_phys", ctypes.c_ulonglong), ("avail_phys", ctypes.c_ulonglong),
                        ("total_page", ctypes.c_ulonglong), ("avail_page", ctypes.c_ulonglong),
                        ("total_virtual", ctypes.c_ulonglong), ("avail_virtual", ctypes.c_ulonglong),
                        ("avail_extended", ctypes.c_ulonglong)]
        memory = MEMORYSTATUSEX()
        memory.length = ctypes.sizeof(memory)
        if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(memory)):
            total, available = memory.total_phys, memory.avail_phys
        else:
            total = available = 0
        gpus = [{"name": "Windows graphics adapter (details available on Linux)", "vendor": "unknown", "device": "host"}]
    else:
        cpu = platform.processor() or platform.machine() or "Processor"
        total = available = 0
    return Hardware(cpu, architecture, cpus, total, available, gpus, str(target), storage_total, storage_free, system)


def required_disk(spec: ModelSpec, engine: str) -> int:
    if engine == "ollama":
        return 2 * spec.size + 2 * GIB  # verified GGUF + Ollama's own copy + reserve
    if engine == "colibri":
        return spec.size + GIB  # link-mode metadata + reserve
    raise SafetyError("Unknown engine.")


def assess_model(spec: ModelSpec, engine: str, hardware: Hardware, storage_free=None) -> dict:
    if engine not in ("ollama", "colibri"):
        raise SafetyError("Unknown engine.")
    if engine not in spec.engines:
        return {"engine": engine, "fit": "unsupported", "feasible": False,
                "reason": "This model architecture is not enabled for that engine.",
                "minimum_ram": None, "preferred_ram": None, "required_disk": required_disk(spec, engine)}
    minimum, preferred = RAM_GATES[spec.id][engine]
    needed = required_disk(spec, engine)
    free = hardware.storage_free if storage_free is None else storage_free
    total_gib = hardware.ram_total / GIB
    available_gib = hardware.ram_available / GIB
    if hardware.ram_total <= 0:
        fit, reason = "unknown", "Memory could not be detected; verify requirements before installing."
    elif total_gib < minimum:
        fit, reason = "insufficient_ram", f"Needs at least {minimum} GiB RAM; {total_gib:.1f} GiB detected."
    elif free < needed:
        fit, reason = "insufficient_disk", f"Needs {format_size(needed)} free for this engine; {format_size(free)} available."
    elif hardware.ram_available < minimum * GIB:
        fit, reason = "tight", f"Installed RAM fits, but only {available_gib:.1f} GiB is currently available. Close other apps."
    elif total_gib < preferred:
        fit, reason = "feasible", f"Feasible; {preferred} GiB RAM is preferred for a more comfortable margin."
    else:
        fit, reason = "recommended", f"Fits the conservative {preferred} GiB preferred-memory gate."
    return {"engine": engine, "fit": fit, "feasible": fit in ("recommended", "feasible", "tight"),
            "reason": reason, "minimum_ram": minimum, "preferred_ram": preferred,
            "required_disk": needed, "storage_free": free}


def recommend(hardware: Hardware, engine="ollama") -> dict:
    rows = [(m, assess_model(m, engine, hardware)) for m in MODELS if m.coding_specialist and not m.fewer_refusals]
    feasible = [(m, a) for m, a in rows if a["feasible"]]
    if not feasible:
        return {"model_id": None, "reason": "No catalog coding model passes the current RAM and disk gates."}
    # Prefer the smallest comfortable coding model; never label it a speed prediction.
    feasible.sort(key=lambda row: (row[1]["fit"] == "tight", row[0].size))
    model, assessment = feasible[0]
    return {"model_id": model.id, "name": model.name, "engine": engine, **assessment}


def _absolute(path: Path) -> Path:
    return Path(os.path.abspath(os.fspath(path)))


def ensure_private_dir(path: Path) -> Path:
    """Create a directory while rejecting symlinks in every existing path component."""
    path = _absolute(Path(path))
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current = current / part
        if current.is_symlink():
            raise SafetyError(f"Refusing symbolic-link directory: {current}")
        if current.exists():
            if not current.is_dir():
                raise SafetyError(f"Not a directory: {current}")
        else:
            current.mkdir(mode=0o700)
    try:
        os.chmod(path, 0o700)
    except OSError:
        pass
    return path


def safe_join(root: Path, *parts: str) -> Path:
    root = _absolute(root)
    result = root
    for part in parts:
        candidate = Path(part)
        if candidate.is_absolute() or not part or part in (".", "..") or "\\" in part:
            raise SafetyError("Unsafe absolute or traversal path.")
        if any(p in ("", ".", "..") for p in candidate.parts):
            raise SafetyError("Unsafe path component.")
        result = result / candidate
    try:
        _absolute(result).relative_to(root)
    except ValueError as exc:
        raise SafetyError("Path escapes its private storage directory.") from exc
    return result


def _assert_file_path(path: Path, allow_missing=True) -> None:
    path = _absolute(path)
    ensure_private_dir(path.parent)
    if path.is_symlink():
        raise SafetyError(f"Refusing symbolic-link file: {path}")
    if path.exists():
        mode = path.lstat().st_mode
        if not stat.S_ISREG(mode):
            raise SafetyError(f"Refusing non-regular file: {path}")
    elif not allow_missing:
        raise VerificationError(f"Missing file: {path}")


def _hash_fd(fd, expected_size=None) -> tuple:
    digest = hashlib.sha256()
    size = 0
    while True:
        chunk = os.read(fd, 1024 * 1024)
        if not chunk:
            break
        size += len(chunk)
        if expected_size is not None and size > expected_size:
            raise VerificationError("File exceeds the pinned size.")
        digest.update(chunk)
    return size, digest.hexdigest()


def verify_file(path: Path, size: int, sha256: str) -> dict:
    _assert_file_path(path, allow_missing=False)
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(os.fspath(path), flags)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise SafetyError("Verified content must be a regular file.")
        actual_size, actual_hash = _hash_fd(fd, size)
    finally:
        os.close(fd)
    if actual_size != size or actual_hash.lower() != sha256.lower():
        raise VerificationError("Pinned size or SHA-256 mismatch; file is not runnable.")
    return {"path": str(path), "size": size, "sha256": sha256.lower(), "verified": True}


def model_file(spec: ModelSpec, paths: AIPaths) -> Path:
    # Both spec fields and output path are checked, even though the catalog is static.
    if Path(spec.filename).name != spec.filename or any(x in spec.filename for x in ("/", "\\", "..")):
        raise SafetyError("Unsafe catalog model filename.")
    return safe_join(paths.models, spec.id, spec.filename)


def _atomic_json(path: Path, data: dict) -> None:
    ensure_private_dir(path.parent)
    _assert_file_path(path)
    temporary = path.parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    fd = os.open(os.fspath(temporary), os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists() or temporary.is_symlink():
            temporary.unlink()


def _open_output(path: Path, append: bool):
    _assert_file_path(path)
    flags = os.O_WRONLY | os.O_CREAT | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    flags |= os.O_APPEND if append else os.O_TRUNC
    fd = os.open(os.fspath(path), flags, 0o600)
    return os.fdopen(fd, "ab" if append else "wb", buffering=0)


def _validate_download_url(url: str, allow_insecure_loopback=False, redirect=False) -> None:
    parsed = urllib.parse.urlsplit(url)
    host = (parsed.hostname or "").lower()
    initial_hosts = {"huggingface.co", "github.com", "codeload.github.com"}
    # Hugging Face resolves pinned files to its official CDN/Xet domains. Do not
    # accept an arbitrary redirect host merely because the bytes hash correctly.
    redirect_hosts = {"objects.githubusercontent.com"}
    official_cdn = host.endswith(".hf.co") or host.endswith(".huggingface.co")
    if parsed.scheme == "https" and (host in initial_hosts or (redirect and (host in redirect_hosts or official_cdn))):
        return
    if allow_insecure_loopback and parsed.scheme == "http" and host == "127.0.0.1":
        return
    raise SafetyError("Download URL or redirect is not an approved HTTPS source.")


def verified_download(url: str, target: Path, expected_size: int, expected_sha256: str,
                      confirmed=False, offline=False, opener=None, progress=None,
                      allow_insecure_loopback=False) -> dict:
    """Resumable fixed-artifact download; only verified bytes reach `target`."""
    _validate_download_url(url, allow_insecure_loopback)
    target = _absolute(target)
    partial = target.parent / (target.name + ".part")
    if target.exists() or target.is_symlink():
        return verify_file(target, expected_size, expected_sha256)
    _assert_file_path(target)
    ensure_private_dir(target.parent)
    _assert_file_path(partial)
    offset = partial.stat().st_size if partial.exists() else 0
    if offset > expected_size:
        partial.unlink()
        offset = 0
    if offset == expected_size and offset > 0:
        try:
            result = verify_file(partial, expected_size, expected_sha256)
            os.replace(partial, target)
            return {"path": str(target), "size": expected_size, "sha256": expected_sha256, "verified": True, "resumed": True}
        except VerificationError:
            partial.unlink()
            offset = 0
    if offline:
        raise OfflineError("No verified cached copy is available offline; an unverified partial is not usable.")
    if not confirmed:
        raise ConfirmationRequired("Explicit confirmation is required before any network download.")
    opener = opener or urllib.request.build_opener()
    headers = {"User-Agent": "Secure-Linux-Local-AI/1.0", "Accept": "application/octet-stream"}
    if offset:
        headers["Range"] = f"bytes={offset}-"
    request = urllib.request.Request(url, headers=headers)
    response = opener.open(request, timeout=60)
    try:
        if hasattr(response, "geturl"):
            _validate_download_url(response.geturl(), allow_insecure_loopback, redirect=True)
        status = getattr(response, "status", None) or response.getcode()
        response_headers = getattr(response, "headers", {})
        if offset and status == 206:
            content_range = response_headers.get("Content-Range", "")
            match = re.fullmatch(r"bytes (\d+)-(\d+)/(\d+)", content_range)
            if not match or int(match.group(1)) != offset or int(match.group(3)) != expected_size:
                raise VerificationError("Server returned an invalid Content-Range for resume.")
        elif offset and status == 200:
            offset = 0  # Range ignored: restart safely, never append a full response.
        elif status not in (200, 206):
            raise LocalAIError(f"Download failed with HTTP {status}.")
        try:
            declared_length = int(response_headers.get("Content-Length", "0"))
        except (TypeError, ValueError):
            declared_length = 0
        digest = hashlib.sha256()
        total_written = offset
        received = 0
        if offset:
            flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
            fd = os.open(os.fspath(partial), flags)
            try:
                while True:
                    chunk = os.read(fd, 1024 * 1024)
                    if not chunk:
                        break
                    digest.update(chunk)
            finally:
                os.close(fd)
        # HTTPResponse.read(n) can raise IncompleteRead without returning its
        # partial bytes. read1 preserves those bytes in our resumable .part.
        reader = getattr(response, "read1", response.read)
        with _open_output(partial, append=bool(offset)) as output:
            while True:
                chunk = reader(min(1024 * 1024, expected_size - total_written + 1))
                if not chunk:
                    break
                received += len(chunk)
                total_written += len(chunk)
                if total_written > expected_size:
                    raise VerificationError("Download exceeds the pinned size.")
                output.write(chunk)
                digest.update(chunk)
                if progress:
                    progress(total_written, expected_size)
            output.flush()
            os.fsync(output.fileno())
        if declared_length and received < declared_length:
            raise LocalAIError("Connection ended early; verified-prefix partial was kept for resume.")
    except VerificationError:
        try:
            partial.unlink()
        except OSError:
            pass
        raise
    finally:
        response.close()
    if total_written != expected_size or digest.hexdigest().lower() != expected_sha256.lower():
        try:
            partial.unlink()
        except OSError:
            pass
        raise VerificationError("Downloaded bytes failed exact size or SHA-256 verification; partial was removed.")
    if target.exists() or target.is_symlink():
        raise SafetyError("Destination appeared during download; refusing to replace it.")
    os.replace(partial, target)
    return {"path": str(target), "size": expected_size, "sha256": expected_sha256,
            "verified": True, "resumed": bool(offset)}


def ollama_storage_path() -> Path | None:
    """Locate an existing Ollama blob volume without creating or changing it."""
    candidates = []
    configured = os.environ.get("OLLAMA_MODELS")
    if configured and Path(configured).is_absolute():
        candidates.append(Path(configured))
    candidates.extend((Path("/usr/share/ollama/.ollama/models"), Path("/var/lib/ollama/.ollama/models"),
                       Path.home() / ".ollama/models"))
    for candidate in candidates:
        if candidate.exists() and candidate.is_dir() and not candidate.is_symlink():
            return candidate
    return None


def download_model(model_id: str, paths=None, engine="ollama", confirmed=False, offline=False,
                   hardware=None, opener=None, progress=None, source_url=None,
                   allow_insecure_loopback=False) -> dict:
    spec = get_model(model_id)
    paths = paths or AIPaths.default()
    hardware = hardware or scan_hardware(paths.base)
    gate = assess_model(spec, engine, hardware)
    if not gate["feasible"]:
        raise LocalAIError(gate["reason"])
    if engine == "ollama":
        storage = ollama_storage_path()
        if storage is not None:
            free = shutil.disk_usage(storage).free
            if free < spec.size + GIB:
                raise LocalAIError(f"Ollama's storage volume {storage} needs {format_size(spec.size + GIB)} free; {format_size(free)} is available.")
    result = verified_download(source_url or spec.url, model_file(spec, paths), spec.size, spec.sha256,
                               confirmed, offline, opener, progress, allow_insecure_loopback)
    manifest = model_file(spec, paths).parent / "verified.json"
    _atomic_json(manifest, {"model_id": spec.id, "repo": spec.repo, "revision": spec.revision,
                            "license": spec.license, **result})
    return result


def runtime_environment(base=None) -> dict:
    """Scrub credentials and set offline/telemetry opt-outs for engine children."""
    env = dict(os.environ if base is None else base)
    sensitive_exact = {
        "HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "OPENAI_API_KEY", "ANTHROPIC_API_KEY",
        "GOOGLE_API_KEY", "GEMINI_API_KEY", "GITHUB_TOKEN", "GH_TOKEN", "COLI_API_KEY",
        "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AZURE_OPENAI_API_KEY",
    }
    for key in list(env):
        upper = key.upper()
        if upper in sensitive_exact or upper.endswith(("_API_KEY", "_SECRET", "_TOKEN", "_PASSWORD")):
            env.pop(key, None)
    for key in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy",
                "CLUSTER_WORKERS", "CLUSTER_COORDINATOR", "COLI_MODEL_MIRROR"):
        env.pop(key, None)
    env.update({
        "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1",
        "DO_NOT_TRACK": "1", "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost",
        "OLLAMA_HOST": "127.0.0.1:11434", "COLIBRI_BACKEND": COLIBRI_URL_LOCAL,
        "PYTHONDONTWRITEBYTECODE": "1",
    })
    return env


def ollama_installed() -> bool:
    return shutil.which("ollama") is not None


def import_ollama(model_id: str, paths=None, runner=subprocess.run) -> dict:
    spec = get_model(model_id)
    if "ollama" not in spec.engines:
        raise LocalAIError("This model is not enabled for Ollama.")
    if not ollama_installed():
        raise LocalAIError("Ollama is not installed. Fedora full setup provides it; Debian lite does not install it automatically.")
    paths = paths or AIPaths.default()
    verified = verify_file(model_file(spec, paths), spec.size, spec.sha256)
    directory = model_file(spec, paths).parent
    modelfile = directory / "Modelfile.secure-linux"
    content = (f"FROM {json.dumps(verified['path'])}\n"
               "PARAMETER num_ctx 8192\n")
    _assert_file_path(modelfile)
    temporary = directory / f".Modelfile.{uuid.uuid4().hex}.tmp"
    temporary.write_text(content, encoding="utf-8")
    os.replace(temporary, modelfile)
    result = runner(["ollama", "create", spec.ollama_tag, "-f", str(modelfile)],
                    env=runtime_environment(), capture_output=True, text=True, timeout=900, check=False)
    if result.returncode:
        raise LocalAIError("Ollama import failed; the verified GGUF was kept for retry. " + (result.stderr or "")[-800:])
    return {"model_id": spec.id, "engine": "ollama", "tag": spec.ollama_tag, "ready": True}


def install_model(model_id: str, engine="ollama", paths=None, confirmed=False, offline=False,
                  hardware=None, opener=None, progress=None) -> dict:
    paths = paths or AIPaths.default()
    downloaded = download_model(model_id, paths, engine, confirmed, offline, hardware, opener, progress)
    if engine == "ollama":
        return {"download": downloaded, "install": import_ollama(model_id, paths)}
    if engine == "colibri":
        return {"download": downloaded, "install": import_colibri(model_id, paths)}
    raise SafetyError("Unknown engine.")


def remove_model(model_id: str, engine="ollama", paths=None, confirmed=False, keep_file=False,
                 runner=subprocess.run) -> dict:
    if not confirmed:
        raise ConfirmationRequired("Confirm model removal explicitly.")
    spec = get_model(model_id)
    paths = paths or AIPaths.default()
    removed = []
    if engine == "ollama" and ollama_installed():
        result = runner(["ollama", "rm", spec.ollama_tag], env=runtime_environment(),
                        capture_output=True, text=True, timeout=120, check=False)
        if result.returncode:
            raise LocalAIError("Ollama model removal failed; local files were left untouched.")
        removed.append(spec.ollama_tag)
    if engine == "colibri":
        directory = safe_join(paths.colibri_models, spec.id)
        if directory.is_symlink():
            raise SafetyError("Refusing to remove a symbolic-link model directory.")
        if directory.exists():
            shutil.rmtree(directory)
            removed.append(str(directory))
    if not keep_file:
        target = model_file(spec, paths)
        for path in (target, target.parent / "verified.json", target.parent / "Modelfile.secure-linux"):
            if path.is_symlink():
                raise SafetyError("Refusing symbolic-link model content.")
        if target.exists():
            target.unlink()
            removed.append(str(target))
        for name in ("verified.json", "Modelfile.secure-linux"):
            path = target.parent / name
            if path.exists():
                path.unlink()
    return {"removed": removed, "verified_file_kept": keep_file}


def colibri_archive(paths=None) -> Path:
    return safe_join((paths or AIPaths.default()).cache, f"colibri-{COLIBRI_COMMIT}.tar.gz")


def download_colibri(paths=None, confirmed=False, offline=False, opener=None, progress=None) -> dict:
    paths = paths or AIPaths.default()
    return verified_download(COLIBRI_URL, colibri_archive(paths), COLIBRI_ARCHIVE_SIZE,
                             COLIBRI_ARCHIVE_SHA256, confirmed, offline, opener, progress)


def safe_extract_archive(archive: Path, destination: Path, expected_root=f"colibri-{COLIBRI_COMMIT}",
                         max_members=MAX_ARCHIVE_MEMBERS) -> Path:
    """Extract regular files/directories only, with traversal and resource caps."""
    _assert_file_path(archive, allow_missing=False)
    destination = ensure_private_dir(destination)
    members_count = 0
    unpacked = 0
    seen = set()
    with tarfile.open(archive, "r:gz") as bundle:
        for member in bundle:
            members_count += 1
            if members_count > max_members:
                raise SafetyError("Archive exceeds the member-count cap.")
            name = member.name
            pure = PurePosixPath(name)
            if (not name or name.startswith("/") or "\\" in name or ".." in pure.parts
                    or pure.parts[0] != expected_root or re.match(r"^[A-Za-z]:", name)):
                raise SafetyError("Archive contains an absolute, traversal, or unexpected path.")
            normalized = str(pure)
            if normalized in seen:
                raise SafetyError("Archive contains duplicate paths.")
            seen.add(normalized)
            output = destination.joinpath(*pure.parts)
            if member.isdir():
                ensure_private_dir(output)
                continue
            if not member.isfile():
                raise SafetyError("Archive links and special files are refused.")
            if member.size < 0:
                raise SafetyError("Invalid archive member size.")
            unpacked += member.size
            if unpacked > MAX_ARCHIVE_UNPACKED:
                raise SafetyError("Archive exceeds the unpacked-size cap.")
            ensure_private_dir(output.parent)
            fd = os.open(os.fspath(output), os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
            source = bundle.extractfile(member)
            if source is None:
                os.close(fd)
                raise SafetyError("Unreadable archive member.")
            remaining = member.size
            with os.fdopen(fd, "wb") as output_file:
                while remaining:
                    chunk = source.read(min(1024 * 1024, remaining))
                    if not chunk:
                        raise SafetyError("Truncated archive member.")
                    output_file.write(chunk)
                    remaining -= len(chunk)
            if member.mode & 0o111:
                os.chmod(output, 0o700)
    return destination / expected_root


def _current_release(paths: AIPaths) -> Path:
    current = paths.engines / "current"
    if current.is_symlink():
        target = os.readlink(current)
    elif os.name == "nt" and current.is_file():
        # Native Windows is a development/UI fallback only; the installed Linux
        # product always uses an atomic symlink. This avoids requiring a Windows
        # administrator privilege merely to run the recovery fixtures.
        target = current.read_text(encoding="utf-8").strip()
    else:
        raise LocalAIError("Colibri is not installed (no validated current release link).")
    release = _absolute(current.parent) / target
    release = Path(os.path.abspath(release))
    try:
        release.relative_to(_absolute(paths.engines / "releases"))
    except ValueError as exc:
        raise SafetyError("Current Colibri link escapes the release directory.") from exc
    manifest = release / "secure-linux-build.json"
    data = json.loads(_read_text(manifest) or "{}")
    if data.get("commit") != COLIBRI_COMMIT or not (release / "c/qwen36").is_file():
        raise VerificationError("Current Colibri release manifest or binary is invalid.")
    return release


def _switch_current(paths: AIPaths, release: Path) -> None:
    engines = ensure_private_dir(paths.engines)
    temporary = engines / f".current-{uuid.uuid4().hex}"
    if os.name == "nt":
        temporary.write_text(str(release), encoding="utf-8")
    else:
        temporary.symlink_to(release, target_is_directory=True)
    os.replace(temporary, engines / "current")


def colibri_install(paths=None, confirmed=False, offline=False, archive_path=None,
                    opener=None, runner=subprocess.run, progress=None, backend="cpu") -> dict:
    """Build qwen36 in staging; CPU and Vulkan releases stay independently reversible."""
    if not confirmed:
        raise ConfirmationRequired("Confirm the pinned Colibri source download and local build.")
    if backend not in ("cpu", "vulkan"):
        raise SafetyError("Colibri backend must be cpu or vulkan.")
    paths = paths or AIPaths.default()
    if shutil.which("make") is None:
        raise LocalAIError("GNU make is required. Install the distribution's make and C compiler packages; nothing is auto-installed.")
    if shutil.which("cc") is None and shutil.which("gcc") is None and shutil.which("clang") is None:
        raise LocalAIError("A C compiler (gcc or clang) is required; nothing is auto-installed.")
    if backend == "vulkan" and shutil.which("glslc") is None:
        raise LocalAIError("Vulkan builds need glslc and Vulkan development headers (Debian/Ubuntu: glslc and libvulkan-dev); nothing is auto-installed.")
    if archive_path:
        archive = _absolute(Path(archive_path))
        verify_file(archive, COLIBRI_ARCHIVE_SIZE, COLIBRI_ARCHIVE_SHA256)
    else:
        archive = colibri_archive(paths)
        download_colibri(paths, confirmed=True, offline=offline, opener=opener, progress=progress)
    staging = paths.engines / f".staging-{uuid.uuid4().hex}"
    ensure_private_dir(staging)
    old_release = None
    try:
        try:
            old_release = _current_release(paths)
        except LocalAIError:
            pass
        source = safe_extract_archive(archive, staging)
        log_path = paths.engines / f"build-{uuid.uuid4().hex[:10]}.log"
        _assert_file_path(log_path)
        build_flags = ["CUDA=0", "HIP=0", "VK=1" if backend == "vulkan" else "VK=0"]
        with log_path.open("xb") as log:
            result = runner(["make", "-C", str(source / "c"), "qwen36", *build_flags],
                            env=runtime_environment(), stdout=log, stderr=subprocess.STDOUT,
                            timeout=1800, check=False)
        if result.returncode or not (source / "c/qwen36").is_file():
            raise LocalAIError(f"Colibri qwen36 build failed; current release was not changed. See {log_path}")
        releases = ensure_private_dir(paths.engines / "releases")
        release = releases / f"{COLIBRI_COMMIT[:12]}-{backend}-{uuid.uuid4().hex[:10]}"
        # Keep the complete upstream layout intact: c/coli, shaders and sibling
        # modules must remain beside the qwen36 binary and project metadata.
        os.replace(source, release)
        os.chmod(release / "c/qwen36", 0o700)
        _atomic_json(release / "secure-linux-build.json", {
            "commit": COLIBRI_COMMIT, "archive_sha256": COLIBRI_ARCHIVE_SHA256,
            "backend": backend, "target": "qwen36", "license": COLIBRI_LICENSE,
            "built_at": _datetime.datetime.now(_datetime.timezone.utc).isoformat(),
        })
        _switch_current(paths, release)
        return {"installed": True, "commit": COLIBRI_COMMIT, "release": str(release),
                "backend": backend, "previous": str(old_release) if old_release else None,
                "experimental": True}
    except Exception:
        # Staging is private and newly created.  The prior current link is untouched.
        if staging.exists() and not staging.is_symlink():
            shutil.rmtree(staging, ignore_errors=True)
        raise
    finally:
        if staging.exists() and not staging.is_symlink():
            shutil.rmtree(staging, ignore_errors=True)


def colibri_releases(paths=None) -> list:
    paths = paths or AIPaths.default()
    root = paths.engines / "releases"
    if not root.exists():
        return []
    releases = []
    for release in root.iterdir():
        if release.is_symlink() or not release.is_dir():
            continue
        try:
            data = json.loads(_read_text(release / "secure-linux-build.json") or "{}")
            if data.get("commit") == COLIBRI_COMMIT and (release / "c/qwen36").is_file():
                releases.append(release)
        except (OSError, ValueError):
            continue
    return sorted(releases, key=lambda p: p.stat().st_mtime)


def colibri_rollback(paths=None, confirmed=False) -> dict:
    if not confirmed:
        raise ConfirmationRequired("Confirm rollback to the previous validated Colibri build.")
    paths = paths or AIPaths.default()
    current = _current_release(paths)
    releases = colibri_releases(paths)
    if current not in releases or releases.index(current) == 0:
        raise LocalAIError("No earlier valid Colibri build is available for rollback.")
    previous = releases[releases.index(current) - 1]
    _switch_current(paths, previous)
    return {"rolled_back": True, "from": str(current), "to": str(previous)}


def import_colibri(model_id: str, paths=None, runner=subprocess.run) -> dict:
    spec = get_model(model_id)
    if "colibri" not in spec.engines:
        raise LocalAIError("Colibri is enabled only for the catalog's compatible Qwen3 GGUFs; Qwen2.5-Coder remains Ollama-only.")
    paths = paths or AIPaths.default()
    release = _current_release(paths)
    verified = verify_file(model_file(spec, paths), spec.size, spec.sha256)
    output = safe_join(paths.colibri_models, spec.id)
    if output.is_symlink():
        raise SafetyError("Refusing symbolic-link Colibri model output.")
    if output.exists():
        marker = json.loads(_read_text(output / "secure-linux-model.json") or "{}")
        if marker.get("model_id") == spec.id and marker.get("sha256") == spec.sha256:
            return {"model_id": spec.id, "engine": "colibri", "model_dir": str(output), "ready": True}
        raise SafetyError("Colibri model output already exists without matching verification metadata.")
    ensure_private_dir(output.parent)
    result = runner([sys.executable, str(release / "c/coli"), "import", "--mode", "link",
                     "--out", str(output), verified["path"]], env=runtime_environment(),
                    capture_output=True, text=True, timeout=600, check=False)
    if result.returncode or not output.is_dir():
        # The output did not exist before this attempt, so partial metadata can
        # be removed safely; the separately verified GGUF is never deleted.
        if output.is_symlink():
            output.unlink()
        elif output.exists():
            shutil.rmtree(output)
        raise LocalAIError("Colibri GGUF import failed; partial metadata was cleaned and verified weights kept. " + (result.stderr or "")[-800:])
    _atomic_json(output / "secure-linux-model.json", {
        "model_id": spec.id, "sha256": spec.sha256, "gguf": verified["path"],
        "commit": COLIBRI_COMMIT, "mode": "link", "license": spec.license,
    })
    return {"model_id": spec.id, "engine": "colibri", "model_dir": str(output), "ready": True, "experimental": True}


def _pid_matches(pid: int, expected_coli: Path, proc_root="/proc") -> bool:
    try:
        raw = (Path(proc_root) / str(pid) / "cmdline").read_bytes()
        args = [part.decode("utf-8", "replace") for part in raw.split(b"\0") if part]
    except OSError:
        return False
    expected = os.path.abspath(expected_coli)
    return any(os.path.abspath(arg) == expected for arg in args) and "serve" in args


def _runtime_coli(paths: AIPaths) -> Path:
    """Return the exact server path recorded at launch, even after a rollback."""
    metadata = paths.runtime / "colibri-8001.json"
    if metadata.is_symlink():
        raise SafetyError("Refusing symbolic-link Colibri runtime metadata.")
    data = json.loads(_read_text(metadata) or "{}")
    coli = Path(os.path.abspath(data.get("coli", "")))
    try:
        coli.relative_to(_absolute(paths.engines / "releases"))
    except ValueError as exc:
        raise SafetyError("Recorded Colibri server path escapes validated releases.") from exc
    if coli.name != "coli" or coli.parent.name != "c" or coli.is_symlink() or not coli.is_file():
        raise SafetyError("Recorded Colibri server path is invalid.")
    return coli


def colibri_status(paths=None, proc_root="/proc") -> dict:
    paths = paths or AIPaths.default()
    try:
        release = _current_release(paths)
        installed = True
    except (LocalAIError, VerificationError, ValueError):
        release, installed = None, False
    pid_file = paths.runtime / "colibri-8001.pid"
    pid = None
    running = False
    if pid_file.exists() and not pid_file.is_symlink():
        try:
            pid = int(pid_file.read_text().strip())
            running = _pid_matches(pid, _runtime_coli(paths), proc_root)
        except (OSError, ValueError, LocalAIError):
            running = False
    build = json.loads(_read_text(release / "secure-linux-build.json") or "{}") if release else {}
    return {"installed": installed, "release": str(release) if release else None,
            "commit": COLIBRI_COMMIT, "backend": build.get("backend", "cpu"),
            "experimental": True, "running": running, "pid": pid if running else None,
            "endpoint": COLIBRI_URL_LOCAL if running else None,
            "archive_cached_verified": _archive_cache_state(paths)}


def _archive_cache_state(paths: AIPaths) -> bool:
    try:
        verify_file(colibri_archive(paths), COLIBRI_ARCHIVE_SIZE, COLIBRI_ARCHIVE_SHA256)
        return True
    except (OSError, LocalAIError):
        return False


def colibri_start(model_id: str, paths=None, popen=subprocess.Popen) -> dict:
    spec = get_model(model_id)
    paths = paths or AIPaths.default()
    status = colibri_status(paths)
    if status["running"]:
        return status
    release = _current_release(paths)
    model_dir = safe_join(paths.colibri_models, spec.id)
    marker = json.loads(_read_text(model_dir / "secure-linux-model.json") or "{}")
    if marker.get("model_id") != spec.id or marker.get("sha256") != spec.sha256:
        raise LocalAIError("Import this compatible model into Colibri first.")
    verify_file(model_file(spec, paths), spec.size, spec.sha256)
    ensure_private_dir(paths.runtime)
    log_path = paths.runtime / "colibri-8001.log"
    _assert_file_path(log_path)
    build = json.loads(_read_text(release / "secure-linux-build.json") or "{}")
    backend = build.get("backend", "cpu")
    environment = runtime_environment()
    if backend == "vulkan":
        environment.update({"COLI_VULKAN": "1", "COLI_NO_OMP_TUNE": "1"})
    command = [sys.executable, str(release / "c/coli"), "serve", "--model", str(model_dir),
               "--host", "127.0.0.1", "--port", "8001", "--model-id", spec.id,
               "--ctx", "8192", "--ngen", "1024", "--kv-slots", "4", "--max-queue", "2",
               "--queue-timeout", "600", "--gpu", "none"]
    with log_path.open("ab") as log:
        process = popen(command, cwd=release / "c", env=environment, stdin=subprocess.DEVNULL,
                        stdout=log, stderr=subprocess.STDOUT, start_new_session=(os.name == "posix"))
    _atomic_json(paths.runtime / "colibri-8001.json", {"pid": process.pid, "model_id": spec.id,
                                                       "backend": backend, "coli": str(release / "c/coli")})
    pid_path = paths.runtime / "colibri-8001.pid"
    _assert_file_path(pid_path)
    temporary = paths.runtime / f".pid-{uuid.uuid4().hex}"
    temporary.write_text(str(process.pid), encoding="ascii")
    os.replace(temporary, pid_path)
    return {"started": True, "pid": process.pid, "endpoint": COLIBRI_URL_LOCAL, "log": str(log_path)}


def colibri_stop(paths=None, proc_root="/proc", killer=os.kill) -> dict:
    paths = paths or AIPaths.default()
    pid_path = paths.runtime / "colibri-8001.pid"
    if pid_path.is_symlink():
        raise SafetyError("Refusing symbolic-link PID file.")
    if not pid_path.exists():
        return {"stopped": False, "reason": "Colibri is not running."}
    try:
        pid = int(pid_path.read_text().strip())
        expected_coli = _runtime_coli(paths)
    except ValueError as exc:
        raise SafetyError("Invalid Colibri PID file.") from exc
    except LocalAIError:
        return {"stopped": False, "reason": "No valid recorded Colibri server path; nothing was killed."}
    if not _pid_matches(pid, expected_coli, proc_root):
        pid_path.unlink()
        return {"stopped": False, "reason": "PID did not match the expected Colibri process; nothing was killed."}
    killer(pid, signal.SIGTERM)
    pid_path.unlink()
    return {"stopped": True, "pid": pid}


def _loopback_url(url: str, expected_port: int) -> None:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "http" or parsed.hostname != "127.0.0.1" or parsed.port != expected_port:
        raise SafetyError("Chat connections are restricted to the expected loopback endpoint.")


SESSION_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}\Z")
SESSION_MAX_BYTES = 512 * 1024
SESSION_MAX_MESSAGES = 80


def _session_file(session: str, paths: AIPaths) -> Path:
    if not isinstance(session, str) or not SESSION_ID.fullmatch(session):
        raise SafetyError("Session IDs use 1-64 letters, digits, underscores or hyphens.")
    ensure_private_dir(paths.sessions)
    return safe_join(paths.sessions, session + ".json")


def _load_session(model_id: str, engine: str, session: str, paths: AIPaths) -> list:
    path = _session_file(session, paths)
    if path.is_symlink():
        raise SafetyError("Refusing a symbolic-link chat session.")
    if not path.exists():
        return []
    data = json.loads(_read_text(path) or "{}")
    if data.get("schema") != 1 or data.get("model_id") != model_id or data.get("engine") != engine:
        raise SafetyError("This session belongs to another model or has an unsupported format.")
    messages = data.get("messages")
    if not isinstance(messages, list) or len(messages) > SESSION_MAX_MESSAGES:
        raise SafetyError("Chat session history is invalid or exceeds its retained-message bound.")
    for message in messages:
        if (not isinstance(message, dict) or message.get("role") not in ("user", "assistant")
                or not isinstance(message.get("content"), str) or set(message) != {"role", "content"}):
            raise SafetyError("Chat session contains an invalid message.")
    return messages


def clear_chat_session(model_id: str, engine: str, session: str, paths=None, confirmed=False) -> dict:
    if not confirmed:
        raise ConfirmationRequired("Confirm clearing this retained chat session.")
    spec = get_model(model_id)
    if engine not in spec.engines:
        raise SafetyError("This model is not enabled for that engine.")
    paths = paths or AIPaths.default()
    path = _session_file(session, paths)
    if path.is_symlink():
        raise SafetyError("Refusing a symbolic-link chat session.")
    existed = path.exists()
    if existed:
        _load_session(spec.id, engine, session, paths)
        path.unlink()
    return {"cleared": existed, "session": session, "model_id": spec.id, "engine": engine}


def chat(model_id: str, engine: str, prompt: str, paths=None, timeout=900, session=None) -> dict:
    spec = get_model(model_id)
    if not prompt.strip():
        raise LocalAIError("Enter a prompt first.")
    paths = paths or AIPaths.default()
    messages = _load_session(spec.id, engine, session, paths) if session else []
    messages.append({"role": "user", "content": prompt})
    if len(messages) >= SESSION_MAX_MESSAGES:
        raise LocalAIError("This session has no room for a complete user/assistant turn within its 80-message bound; clear it or start a new session. No history was truncated.")
    if engine == "ollama":
        url = OLLAMA_URL + "/api/chat"
        _loopback_url(url, 11434)
        payload = {"model": spec.ollama_tag, "messages": messages, "stream": False,
                   "keep_alive": "10m", "options": {"num_predict": 1024, "num_ctx": 8192}}
    elif engine == "colibri":
        url = COLIBRI_URL_LOCAL + "/v1/chat/completions"
        _loopback_url(url, 8001)
        payload = {"model": spec.id, "messages": messages, "stream": False, "max_tokens": 1024}
        if session:
            # Four server slots are available. A collision only loses reuse: exact
            # history is still resent and verified by the engine before generation.
            payload["cache_slot"] = int(hashlib.sha256(session.encode("utf-8")).hexdigest()[:8], 16) % 4
    else:
        raise SafetyError("Unknown engine.")
    encoded = json.dumps(payload).encode("utf-8")
    if session and len(encoded) > SESSION_MAX_BYTES:
        raise LocalAIError("This session no longer fits its 512 KiB storage bound; clear it or start a new session. No history was truncated.")
    request = urllib.request.Request(url, data=encoded, headers={"Content-Type": "application/json"}, method="POST")
    # Explicitly bypass ambient proxies, including proxies carrying credentials.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request, timeout=timeout) as response:
        data = json.loads(response.read().decode("utf-8"))
    try:
        if engine == "ollama":
            answer = data["message"]["content"]
        else:
            answer = data["choices"][0]["message"]["content"]
        if not isinstance(answer, str):
            raise TypeError("answer is not text")
    except (KeyError, IndexError, TypeError) as exc:
        raise LocalAIError("The local engine returned an unrecognized chat response.") from exc
    if session:
        retained = [*messages, {"role": "assistant", "content": answer}]
        if len(json.dumps(retained).encode("utf-8")) > SESSION_MAX_BYTES:
            raise LocalAIError("The answer exceeded the session storage bound. It was not retained; no earlier history was truncated.")
        _atomic_json(_session_file(session, paths), {
            "schema": 1, "model_id": spec.id, "engine": engine, "messages": retained,
            "updated_at": _datetime.datetime.now(_datetime.timezone.utc).isoformat(),
        })
    return {"model_id": spec.id, "engine": engine, "answer": answer, "endpoint": url,
            "session": session, "retained_messages": len(messages) + 1 if session else 0,
            "prefix_reuse": "exact history resent; engine reuse is best effort" if session else "not requested"}


def catalog_report(hardware=None, paths=None) -> list:
    hardware = hardware or scan_hardware((paths or AIPaths.default()).base)
    paths = paths or AIPaths.default()
    rows = []
    for spec in MODELS:
        target = model_file(spec, paths)
        cache_present = target.exists() and not target.is_symlink() and target.stat().st_size == spec.size
        row = {"id": spec.id, "name": spec.name, "family": spec.family, "parameters": spec.parameters,
               "quantization": spec.quantization, "size": spec.size, "size_label": format_size(spec.size),
               "license": spec.license, "repo": spec.repo, "revision": spec.revision,
               "coding_specialist": spec.coding_specialist, "fewer_refusals": spec.fewer_refusals,
               "description": spec.description, "cache_present_size_match": cache_present,
               "assessments": {engine: assess_model(spec, engine, hardware) for engine in spec.engines}}
        rows.append(row)
    return rows


def frontend_guidance() -> dict:
    return {
        "editor": "Fedora full setup includes VSCodium and Continue. Point its local provider at http://127.0.0.1:11434 and the secure-ai/... model tag.",
        "desktop": "Alpaca can use the existing local Ollama service when Ollama is installed.",
        "cli": "Use secure-linux-ai chat MODEL --engine ollama --prompt '...'. Aider or another OpenAI-compatible CLI may be configured manually for Colibri at http://127.0.0.1:8001/v1; no shell/agent tools are enabled here.",
        "privacy": "Chat requests from this app go only to 127.0.0.1. Offline and telemetry opt-out variables are set for child engines; this is not an OS-level network sandbox.",
        "coding_warning": "Generated code can be wrong or dangerous. Review it, keep backups, and never run suggested commands merely because a model produced them.",
        "performance": "No tokens/second is predicted. Long coding-agent prompts can spend substantial time in prefill, especially with large disk-streamed MoE models.",
    }
