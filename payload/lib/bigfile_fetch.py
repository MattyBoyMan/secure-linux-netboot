"""Big-file downloads for Secure Linux (package P33a; ideas 8, 23, 24, 25).

Used by the drive builder's refresh step (P33b) for the Fedora image, the rescue tools, Ventoy, the offline app
collection and similar large files. Standard library only; gpgv (part of gnupg2) checks signed checksum files.

What it promises:
  - Size first (idea 24): plan() works out what must be downloaded and how many bytes that is, before one byte of a
    big file is fetched. run() refuses a plan that is larger than the limit it is given, or than the free space.
  - Only when changed (ideas 8, 23): a file already here with the expected SHA-256 is kept and never downloaded.
  - Resuming and parallel (idea 25): several files are fetched at the same time (one connection per file). A file
    cut short continues where it stopped (HTTP Range), also in a later run: the half-finished part is kept under its
    expected SHA-256 in FOLDER/.bigfetch-parts/.
  - Nothing unchecked is ever kept: every file must match its expected SHA-256 (and size, when known) before it gets
    its final name. A file that does not match is deleted and reported; an older good copy is left as it was.
  - https only. A redirect that leaves https is refused. (Tests may allow plain http to named loopback hosts through
    the constructor; nothing else can.)

Where the expected SHA-256 comes from (each "scheme" returns {name: Expected}):
  fedora_checksum(data, key_files)          Fedora's clear-signed CHECKSUM, checked with gpgv; only the signed text.
  sha256sums(data, key_files, signature)    SHA256SUMS-style files (GNU "hash  name" or BSD "SHA256 (name) = hash"),
                                            clear-signed, with a detached signature, or (when allowed) unsigned.
  ventoy_checksums(data, names)             Ventoy's release checksum file (not signed by Ventoy): the named assets.
  offline_collection(bundle)                The offline app collection's approved plan (plan.json whose SHA-256 is
                                            the one in approval.json, written by offline_bundle.py).
  c1_list(release, sig, files, sig, keys)   The kit's signed release and file list (contract C1), checked by
                                            secure-linux-release-verify with the keys of the LOCAL kit.
Each Expected records how it was trusted (TRUST_*), so a caller can say it plainly. Signing keys are always files on
this computer, never something downloaded.
"""

from __future__ import annotations

import base64
import concurrent.futures
import dataclasses
import errno
import hashlib
import http.client
import importlib.machinery
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tempfile
import threading
import types
import urllib.error
import urllib.parse
import urllib.request

TRUST_SIGNED = "signed"                    # the checksum was signed by a key this computer already trusts
TRUST_HTTPS = "https-only"                 # the checksum came over https from the publisher; nobody signed it
TRUST_APPROVED = "approved-plan"           # the offline collection's plan, approved by its exact SHA-256
TRUST_NOT_SET_UP = "signing-not-set-up"    # a kit file list while release signing is not set up yet (bridge mode)

TRUST_WORDS = {
    TRUST_SIGNED: "checked against a signed checksum list",
    TRUST_HTTPS: "checked against the publisher's checksum list (downloaded over https; it is not signed)",
    TRUST_APPROVED: "checked against the approved list of the offline app collection",
    TRUST_NOT_SET_UP: "checked against the kit's file list (release signing is not set up yet)",
}

USER_AGENT = "secure-linux-bigfile-fetch"
PARTS_FOLDER = ".bigfetch-parts"
WORKERS = 3                                # files fetched at the same time
TRIES = 5                                  # connections per file before giving up (each continues the last)
TIMEOUT = 60                               # seconds without an answer before a connection counts as broken
CHUNK = 1024 * 1024
UNKNOWN_SIZE_LIMIT = 64 * 1024 ** 3        # never more than this for a file whose size is not known first
ROOM = 256 * 1024 ** 2                     # always left free in the folder after the downloads
MAX_SMALL = 4 * 1024 * 1024                # a checksum list, signature or index page
MAX_KEY_FILE = 1024 * 1024
GPGV_TIMEOUT = 120
PROGRESS_STEP = 256 * 1024 ** 2
STRONG_HASHES = {"8", "9", "10", "11"}     # SHA-256, SHA-384, SHA-512, SHA-224 (never MD5 or SHA-1)

HASH_RE = re.compile(r"^[0-9a-f]{64}$")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+~-]{0,254}$")
BSD_LINE = re.compile(r"^SHA256 ?\((.+)\) ?= ?([0-9a-fA-F]{64})$")
GNU_LINE = re.compile(r"^([0-9a-fA-F]{64}) [ *](.+)$")
SIZE_LINE = re.compile(r"^# (.+): ([0-9]{1,15}) bytes$")        # Fedora: "# NAME: N bytes" in the signed text
DISK_FULL = {code for code in (errno.ENOSPC, getattr(errno, "EDQUOT", None)) if code is not None}
CONTENT_RANGE = re.compile(r"^\s*bytes\s+([0-9]+)-([0-9]+)/([0-9]+|\*)\s*$")
SIGNED_HEAD = b"-----BEGIN PGP SIGNED MESSAGE-----"


class FetchError(Exception):
    """A plain-English reason something could not be downloaded. Nothing unchecked was kept."""


class Refused(FetchError):
    """A checksum, signature or size did not match: the file (or list) was refused."""


@dataclasses.dataclass(frozen=True)
class Expected:
    name: str                      # the publisher's file name (or the kit-relative path for C1 lists)
    sha256: str
    size: int | None = None
    trust: str = TRUST_HTTPS
    url: str | None = None         # when the scheme knows where the file lives (offline collection)
    relative: str | None = None    # where the scheme wants it stored (offline collection: its pool path)


@dataclasses.dataclass
class Job:
    expected: Expected
    url: str
    target: Path
    part: Path
    action: str                    # "keep" (already here, unchanged), "download" or "resume"
    size: int | None               # bytes of the whole file, when known before the download
    have: int = 0                  # bytes already in the half-finished part

    @property
    def remaining(self) -> int | None:
        if self.action == "keep":
            return 0
        return None if self.size is None else max(self.size - self.have, 0)


@dataclasses.dataclass
class Plan:
    folder: Path
    jobs: list[Job]

    @property
    def to_fetch(self) -> list[Job]:
        return [job for job in self.jobs if job.action != "keep"]

    @property
    def kept(self) -> list[Job]:
        return [job for job in self.jobs if job.action == "keep"]

    @property
    def unknown_sizes(self) -> list[Job]:
        return [job for job in self.to_fetch if job.size is None]

    @property
    def download_bytes(self) -> int:
        """Bytes still to download (files whose size is not known count as 0; see unknown_sizes). The same bytes
        under two names are downloaded once, so they count once."""
        seen: dict[str, int] = {}
        for job in self.to_fetch:
            seen.setdefault(job.expected.sha256, job.remaining or 0)
        return sum(seen.values())

    @property
    def space_bytes(self) -> int:
        """Bytes the downloads take up in the folder: every name counts, also a copy of bytes downloaded once."""
        return sum(job.remaining or 0 for job in self.to_fetch)

    def describe(self) -> list[str]:
        """Plain lines to show before anything is downloaded."""
        lines = []
        if not self.to_fetch:
            lines.append(f"Everything is up to date ({len(self.kept)} file(s) unchanged). Nothing to download.")
            return lines
        lines.append(f"To download: {human(self.download_bytes)} in {len(self.to_fetch)} file(s); "
                     f"{len(self.kept)} file(s) unchanged and kept.")
        for job in self.to_fetch:
            size = "size not known yet" if job.size is None else human(job.size)
            more = f", {human(job.have)} already here from last time" if job.action == "resume" else ""
            lines.append(f"  {job.expected.name}: {size}{more}")
        return lines


@dataclasses.dataclass
class Report:
    done: list[Job]
    kept: list[Job]
    failed: list[tuple[Job, str]]
    downloaded_bytes: int = 0

    @property
    def ok(self) -> bool:
        return not self.failed


# ---- small helpers --------------------------------------------------------------------------------------------------

def human(number: int | None) -> str:
    if number is None:
        return "an unknown size"
    value = float(number)
    for unit in ("bytes", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            return f"{int(value)} bytes" if unit == "bytes" else f"{value:.1f} {unit}"
        value /= 1024
    return f"{number} bytes"


def safe_name(name: str) -> str:
    """A file name from a checksum list: one plain name, never a path."""
    if not isinstance(name, str) or not NAME_RE.fullmatch(name) or name in (".", ".."):
        raise Refused(f"the checksum list names a file in a form that is never used ({name!r}), so it was refused")
    return name


def safe_relative(relative: str) -> PurePosixPath:
    """A relative path below the download folder: plain names separated by '/', never '..' or absolute."""
    if not isinstance(relative, str) or not relative or relative.startswith("/") or "\\" in relative:
        raise Refused(f"the path {relative!r} is not a plain path inside the download folder, so it was refused")
    parts = relative.split("/")
    for part in parts:
        if part in ("", ".", "..") or not NAME_RE.fullmatch(part):
            raise Refused(f"the path {relative!r} is not a plain path inside the download folder, so it was refused")
    return PurePosixPath(*parts)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            block = handle.read(CHUNK)
            if not block:
                return digest.hexdigest()
            digest.update(block)


def is_plain_file(path: Path) -> bool:
    try:
        return stat.S_ISREG(os.lstat(path).st_mode)
    except OSError:
        return False


def no_links_below(folder: Path, path: Path) -> None:
    """Refuse when any step from folder down to path (folder itself included) is a symbolic link."""
    step = Path(folder)
    steps = [step]
    for part in Path(path).relative_to(folder).parts:
        step = step / part
        steps.append(step)
    for step in steps:
        if os.path.islink(step):
            raise FetchError(f"{step.name} is a link, so nothing was downloaded there")


def check_hash(value: object, what: str) -> str:
    if not isinstance(value, str) or not HASH_RE.fullmatch(value.lower()):
        raise Refused(f"{what} has no valid SHA-256, so it was refused")
    return value.lower()


# ---- checksum lists ------------------------------------------------------------------------------------------------

def parse_checksum_lines(text: str) -> dict[str, str]:
    """name -> SHA-256 from GNU ("hash  name", "hash *name") and BSD ("SHA256 (name) = hash") lines. Lines for other
    hash kinds, comments and names that are not one plain file name are left out. A name listed twice with two
    different hashes is refused (nobody can say which one is right)."""
    found: dict[str, str] = {}
    for line in text.replace("\r\n", "\n").split("\n"):
        line = line.strip()
        match = BSD_LINE.fullmatch(line)
        if match:
            name, digest = match.group(1), match.group(2)
        else:
            match = GNU_LINE.fullmatch(line)
            if not match:
                continue
            digest, name = match.group(1), match.group(2).strip()
        if name.startswith("./"):
            name = name[2:]
        if not NAME_RE.fullmatch(name):
            continue
        digest = digest.lower()
        if found.get(name, digest) != digest:
            raise Refused(f"the checksum list gives two different SHA-256 values for {name}, so it was refused")
        found[name] = digest
    return found


def parse_checksum_sizes(text: str) -> dict[str, int]:
    """name -> size in bytes from Fedora's comment lines ("# NAME: N bytes"). Only ever called on signed text. A name
    given two different sizes is refused."""
    found: dict[str, int] = {}
    for line in text.replace("\r\n", "\n").split("\n"):
        match = SIZE_LINE.fullmatch(line.strip())
        if not match or not NAME_RE.fullmatch(match.group(1)):
            continue
        name, size = match.group(1), int(match.group(2))
        if found.get(name, size) != size:
            raise Refused(f"the checksum list gives two different sizes for {name}, so it was refused")
        found[name] = size
    return found


def dearmor_keys(raw: bytes, what: str) -> bytes:
    """OpenPGP public keys as binary packets (gpgv reads only those). Armored or binary key files are accepted."""
    if raw[:1] and raw[0] & 0x80:
        return raw
    text = raw.decode("ascii", "replace").replace("\r\n", "\n")
    if "PRIVATE KEY" in text:
        raise ValueError(f"{what} holds a private key; only public keys are used")
    blocks = re.findall(r"-----BEGIN PGP PUBLIC KEY BLOCK-----\n(.*?)-----END PGP PUBLIC KEY BLOCK-----", text, re.S)
    if not blocks:
        raise ValueError(f"{what} is not a public key file")
    out = b""
    for block in blocks:
        head, separator, body = block.partition("\n\n")
        if not separator:
            body = head if ":" not in head.split("\n", 1)[0] else ""
        lines = [line.strip() for line in body.split("\n") if line.strip() and not line.strip().startswith("=")]
        try:
            out += base64.b64decode("".join(lines), validate=True)
        except ValueError as exc:
            raise ValueError(f"{what} is damaged") from exc
    if not out or not out[0] & 0x80:
        raise ValueError(f"{what} is damaged")
    return out


def gpgv_program() -> str | None:
    for name in ("gpgv", "gpgv2"):
        found = shutil.which(name)
        if found:
            return found
    return None


def gpgv_check(data: bytes, signature: bytes | None, key_files: list[Path] | tuple[Path, ...], what: str) -> bytes:
    """The bytes a good signature covers: for a clear-signed file only the signed text (gpgv's own output), for a
    detached signature exactly `data`. Keys are files on this computer. Anything else raises Refused."""
    program = gpgv_program()
    if not program:
        raise FetchError("the signature checker (gpgv, part of gnupg2) is not installed on this computer, so "
                         f"{what} cannot be checked. Install gnupg2, then try again. Nothing was downloaded.")
    if not key_files:
        raise FetchError(f"no signing key was given for {what}, so it cannot be checked. Nothing was downloaded.")
    keyring = b""
    for path in key_files:
        path = Path(path)
        try:
            if path.stat().st_size > MAX_KEY_FILE:
                raise ValueError(f"{path.name} is larger than any key file")
            keyring += dearmor_keys(path.read_bytes(), path.name)
        except (OSError, ValueError) as exc:
            raise FetchError(f"the key file {path.name} cannot be used ({exc}). Nothing was downloaded.") from exc
    if len(data) > MAX_SMALL or (signature is not None and len(signature) > MAX_SMALL):
        raise Refused(f"{what} is larger than any checksum list, so it was refused")
    clear = signature is None
    if clear and (data.count(SIGNED_HEAD) != 1):
        raise Refused(f"{what} is not signed, so it was refused")
    work = Path(tempfile.mkdtemp(prefix="sl-bigfetch-check-"))
    try:
        (work / "home").mkdir(mode=0o700)
        (work / "trusted.gpg").write_bytes(keyring)
        (work / "data").write_bytes(data)
        # Relative names with cwd=work: no Windows or Linux path ever reaches gpgv's own path handling.
        command = [program, "--homedir", "home", "--status-fd", "1", "--keyring", "./trusted.gpg"]
        if clear:
            command += ["--output", "signed.txt", "data"]
        else:
            (work / "data.sig").write_bytes(signature)
            command += ["data.sig", "data"]
        try:
            result = subprocess.run(command, cwd=work, capture_output=True, text=True, timeout=GPGV_TIMEOUT,
                                    env={**os.environ, "LC_ALL": "C", "LANG": "C"})
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise FetchError(f"the signature checker could not run ({type(exc).__name__}). "
                             "Nothing was downloaded.") from exc
        codes = [line.split()[1:] for line in result.stdout.splitlines() if line.startswith("[GNUPG:] ")]
        names = {fields[0] for fields in codes if fields}
        valid = [fields for fields in codes if fields and fields[0] == "VALIDSIG" and len(fields) >= 10]
        bad = names & {"BADSIG", "ERRSIG", "EXPSIG", "EXPKEYSIG", "REVKEYSIG", "NO_PUBKEY", "FAILURE"}
        weak = [fields for fields in valid if fields[8] not in STRONG_HASHES]
        signed = work / "signed.txt"
        if result.returncode != 0 or bad or not valid or weak or "GOODSIG" not in names \
                or (clear and not signed.is_file()):
            raise Refused(f"{what} does not carry a good signature by a trusted key, so it was refused. "
                          "Nothing was downloaded.")
        return signed.read_bytes() if clear else data
    finally:
        shutil.rmtree(work, ignore_errors=True)


def _expected_from(hashes: dict[str, str], trust: str, sizes: dict[str, int] | None = None) -> dict[str, Expected]:
    sizes = sizes or {}
    return {name: Expected(name=name, sha256=digest, size=sizes.get(name), trust=trust)
            for name, digest in hashes.items()}


def _expected_from_signed(signed: bytes) -> dict[str, Expected]:
    """Hashes and (when the list gives them) sizes, both only from the text a good signature covers."""
    text = signed.decode("utf-8", "replace")
    return _expected_from(parse_checksum_lines(text), TRUST_SIGNED, parse_checksum_sizes(text))


def fedora_checksum(data: bytes, key_files) -> dict[str, Expected]:
    """Fedora's clear-signed CHECKSUM file. Only the text the signature covers is ever read."""
    signed = gpgv_check(data, None, list(key_files), "Fedora's CHECKSUM file")
    return _expected_from_signed(signed)


def sha256sums(data: bytes, key_files=(), signature: bytes | None = None, require_signed: bool = True,
               what: str = "the checksum list") -> dict[str, Expected]:
    """A SHA256SUMS-style list. Clear-signed or with a detached signature: checked with gpgv and the given keys.
    Unsigned: only when require_signed is False (then every entry is marked TRUST_HTTPS)."""
    if signature is not None or SIGNED_HEAD in data:
        signed = gpgv_check(data, signature, list(key_files), what)
        return _expected_from_signed(signed)
    if require_signed:
        raise Refused(f"{what} is not signed, so it was refused. Nothing was downloaded.")
    if len(data) > MAX_SMALL:
        raise Refused(f"{what} is larger than any checksum list, so it was refused")
    return _expected_from(parse_checksum_lines(data.decode("utf-8", "replace")), TRUST_HTTPS)


def ventoy_checksums(data: bytes, names) -> dict[str, Expected]:
    """Ventoy's release checksum file (Ventoy does not sign it; it comes over https with the release). Only the named
    release files are taken; each must be listed exactly once."""
    hashes = parse_checksum_lines(data.decode("utf-8", "replace")) if len(data) <= MAX_SMALL else None
    if hashes is None:
        raise Refused("Ventoy's checksum list is larger than any checksum list, so it was refused")
    out = {}
    for name in names:
        safe_name(name)
        if name not in hashes:
            raise Refused(f"Ventoy's checksum list does not name {name}, so it was not downloaded")
        out[name] = Expected(name=name, sha256=hashes[name], trust=TRUST_HTTPS)
    return out


def offline_collection(bundle: Path) -> dict[str, Expected]:
    """The offline app collection's approved plan (offline_bundle.py): plan.json is only used when approval.json
    names its exact SHA-256 and it is within its budget. Each file keeps its planned size and its pool path."""
    bundle = Path(bundle)
    try:
        raw = (bundle / "plan.json").read_bytes()
        approval = json.loads((bundle / "approval.json").read_text(encoding="utf-8"))
        plan = json.loads(raw.decode("utf-8"))
    except (OSError, ValueError, UnicodeDecodeError) as exc:
        raise Refused("the offline app collection has no readable approved plan, so nothing was downloaded") from exc
    if not isinstance(approval, dict) or approval.get("plan_sha256") != hashlib.sha256(raw).hexdigest():
        raise Refused("the offline app collection's plan changed after it was approved, so nothing was downloaded")
    if not isinstance(plan, dict) or plan.get("within_budget") is not True:
        raise Refused("the offline app collection's plan is over its size budget, so nothing was downloaded")
    entries = plan.get("direct_payloads")
    if not isinstance(entries, list):
        raise Refused("the offline app collection's plan lists no files, so nothing was downloaded")
    out: dict[str, Expected] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise Refused("the offline app collection's plan has a damaged entry, so nothing was downloaded")
        name = safe_name(entry.get("filename"))
        digest = check_hash(entry.get("sha256"), name)
        size = entry.get("bytes")
        if not isinstance(size, int) or isinstance(size, bool) or size < 0:
            raise Refused(f"the offline app collection's plan gives no size for {name}, so nothing was downloaded")
        url = entry.get("url")
        if not isinstance(url, str) or not url.startswith("https://"):
            raise Refused(f"the offline app collection's plan has no https address for {name}")
        key = str(entry.get("id") or name)
        if key in out:
            raise Refused(f"the offline app collection's plan lists {key} twice, so nothing was downloaded")
        out[key] = Expected(name=name, sha256=digest, size=size, trust=TRUST_APPROVED, url=url,
                            relative=f"pool/sha256/{digest[:2]}/{digest}")
    return out


def load_release_verifier(path: Path | None = None):
    """secure-linux-release-verify (contract C1), loaded the way secure-linux-kit-update loads it."""
    here = Path(__file__).resolve().parent
    candidates = [Path(path)] if path else [here.parent / "bin" / "secure-linux-release-verify",
                                            Path("/usr/local/bin/secure-linux-release-verify")]
    for verifier in candidates:
        if verifier.is_file():
            loader = importlib.machinery.SourceFileLoader("sl_release_verify_for_bigfetch", str(verifier))
            module = types.ModuleType(loader.name)
            module.__file__ = str(verifier)
            loader.exec_module(module)
            return module
    raise FetchError("the release signature checker (secure-linux-release-verify) is missing, so the kit's file "
                     "list cannot be checked. Nothing was downloaded.")


def c1_list(release_raw: bytes | None, release_sig: bytes | None, list_raw: bytes | None, list_sig: bytes | None,
            keys_dir: Path, verifier=None, allow_not_set_up: bool = False) -> dict[str, Expected]:
    """The kit's own signed release record and file list (C1): path -> Expected, with the sizes when the list has
    them. keys_dir is the LOCAL kit's key folder. While release signing is not set up yet the list is refused unless
    allow_not_set_up is True (then every entry is marked TRUST_NOT_SET_UP, never TRUST_SIGNED)."""
    checker = verifier or load_release_verifier()
    if list_raw is None:
        raise Refused("the kit's file list is missing, so nothing was downloaded")
    verdict = checker.verify_release(release_raw, release_sig, list_raw, list_sig, Path(keys_dir),
                                     source="the kit's release")
    if verdict.state == checker.VERIFIED:
        trust = TRUST_SIGNED
    elif verdict.state == checker.NOT_SET_UP and allow_not_set_up:
        trust = TRUST_NOT_SET_UP
    elif verdict.state == checker.NOT_SET_UP:
        raise Refused("release signing is not set up yet, so the kit's file list cannot be trusted for big files. "
                      "Nothing was downloaded.")
    else:
        raise Refused(f"the kit's file list was refused: {verdict.message}. Nothing was downloaded.")
    try:
        listing = json.loads(list_raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        raise Refused("the kit's file list cannot be read, so nothing was downloaded") from exc
    files = listing.get("files") if isinstance(listing, dict) else None
    sizes = listing.get("sizes", {}) if isinstance(listing, dict) else {}
    if not isinstance(files, dict) or not isinstance(sizes, dict):
        raise Refused("the kit's file list is in a form this version does not understand")
    out = {}
    for relative, digest in files.items():
        safe_relative(relative)
        size = sizes.get(relative)
        if size is not None and (not isinstance(size, int) or isinstance(size, bool) or size < 0):
            raise Refused(f"the kit's file list gives an impossible size for {relative}")
        out[relative] = Expected(name=relative, sha256=check_hash(digest, relative), size=size, trust=trust,
                                 relative=relative)
    return out


# ---- the downloader -----------------------------------------------------------------------------------------------

class _Restart(Exception):
    """The server sent the whole file (or refused the range): start this file again from its first byte."""


class Fetcher:
    """Plans and runs big downloads. allow_http_hosts is for tests only: plain http to exactly those loopback hosts."""

    def __init__(self, workers: int = WORKERS, tries: int = TRIES, timeout: float = TIMEOUT,
                 allow_http_hosts=(), say=None, room: int = ROOM):
        self.workers = max(1, int(workers))
        self.tries = max(1, int(tries))
        self.timeout = timeout
        self.allow_http_hosts = frozenset(host for host in allow_http_hosts
                                          if host in ("127.0.0.1", "localhost", "::1"))
        self.room = room
        self._say = say or (lambda text: None)
        self._lock = threading.Lock()
        fetcher = self

        class Redirects(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):
                fetcher.check_url(newurl, "a redirect")
                return super().redirect_request(req, fp, code, msg, headers, newurl)

        self._opener = urllib.request.build_opener(Redirects())

    # -- addresses
    def check_url(self, url: str, what: str = "the address") -> str:
        parts = urllib.parse.urlsplit(url or "")
        if parts.scheme == "https" and parts.hostname:
            return url
        if parts.scheme == "http" and parts.hostname in self.allow_http_hosts:
            return url
        raise FetchError(f"{what} does not use https ({_shown(url)}), so nothing was downloaded from it")

    def say(self, text: str) -> None:
        with self._lock:
            self._say(text)

    def _open(self, url: str, headers: dict | None = None, method: str = "GET"):
        self.check_url(url)
        request = urllib.request.Request(url, method=method, headers={
            "User-Agent": USER_AGENT, "Accept-Encoding": "identity", **(headers or {})})
        response = self._opener.open(request, timeout=self.timeout)
        try:
            self.check_url(response.geturl(), "a redirect")
        except FetchError:
            response.close()
            raise
        return response

    def get_small(self, url: str, limit: int = MAX_SMALL) -> bytes:
        """A small file such as a checksum list, a signature or an index page."""
        try:
            with self._open(url) as response:
                data = response.read(limit + 1)
        except FetchError:
            raise
        except (urllib.error.URLError, OSError, http.client.HTTPException) as exc:
            raise FetchError(f"{_shown(url)} could not be downloaded ({_reason(exc)}). Nothing was changed.") from exc
        if len(data) > limit:
            raise Refused(f"{_shown(url)} is larger than expected, so it was refused")
        return data

    def size_of(self, url: str) -> int | None:
        """The size the server announces, without downloading the file (HEAD). None when it does not say."""
        try:
            with self._open(url, method="HEAD") as response:
                length = response.headers.get("Content-Length")
        except FetchError:
            raise
        except urllib.error.HTTPError as exc:
            exc.close()
            if exc.code in (404, 410):
                raise FetchError(f"{_shown(url)} is not there (it may have been replaced by a newer version). "
                                 "Nothing was downloaded.") from exc
            return None
        except (urllib.error.URLError, OSError, http.client.HTTPException):
            return None
        if length is not None and length.strip().isdigit():
            return int(length.strip())
        return None

    # -- size first
    def plan(self, items, folder: Path) -> Plan:
        """items: (Expected, url) pairs (url None: the Expected's own). Nothing big is downloaded here; a file whose
        size is not in its checksum list is asked for with HEAD."""
        folder = Path(folder)
        folder.mkdir(parents=True, exist_ok=True)
        parts = folder / PARTS_FOLDER
        no_links_below(folder, parts)
        jobs: list[Job] = []
        targets: set[Path] = set()
        for expected, url in items:
            url = self.check_url(url or expected.url or "", f"the address of {expected.name}")
            digest = check_hash(expected.sha256, expected.name)
            relative = safe_relative(expected.relative) if expected.relative else PurePosixPath(safe_name(expected.name))
            target = folder.joinpath(*relative.parts)
            if target in targets:
                raise FetchError(f"{relative} is asked for twice, so nothing was downloaded")
            targets.add(target)
            no_links_below(folder, target)
            part = parts / (digest + ".part")
            size = expected.size
            if os.path.lexists(target):
                if not is_plain_file(target):
                    raise FetchError(f"{relative} is not a plain file, so nothing was downloaded")
                current = os.lstat(target).st_size
                if (size is None or current == size) and sha256_file(target) == digest:
                    jobs.append(Job(expected, url, target, part, "keep", current))
                    continue
            have = os.lstat(part).st_size if is_plain_file(part) else 0
            if size is None:
                size = self.size_of(url)
            if size is not None and have > size:
                have = 0                                   # cannot belong to this file; started again in run()
            jobs.append(Job(expected, url, target, part, "resume" if have else "download", size, have))
        return Plan(folder, jobs)

    # -- the downloads
    def run(self, plan: Plan, max_download_bytes: int | None = None) -> Report:
        """Download what the plan needs. Refused before any download when the plan is larger than
        max_download_bytes, when a size is not known while a limit is set, or when the free space is too small."""
        fetch = plan.to_fetch
        if max_download_bytes is not None:
            if plan.unknown_sizes:
                raise FetchError(f"the size of {plan.unknown_sizes[0].expected.name} is not known before the "
                                 "download, so it cannot be kept under your limit. Nothing was downloaded.")
            if plan.download_bytes > max_download_bytes:
                raise FetchError(f"this needs {human(plan.download_bytes)} of downloads, more than the "
                                 f"{human(max_download_bytes)} you allowed. Nothing was downloaded.")
        if fetch:
            need = plan.space_bytes + self.room
            free = shutil.disk_usage(plan.folder).free
            if free < need:
                raise FetchError(f"there is not enough free space for the downloads ({human(need)} is needed, "
                                 f"{human(free)} is free). Free up some space, then try again. Nothing was downloaded.")
            (plan.folder / PARTS_FOLDER).mkdir(mode=0o700, exist_ok=True)
            no_links_below(plan.folder, plan.folder / PARTS_FOLDER)
        report = Report(done=[], kept=list(plan.kept), failed=[])
        for job in plan.kept:
            _remove(job.part)                                # a leftover part of a file that is already complete
        first: dict[str, Job] = {}
        copies: list[Job] = []
        for job in fetch:                                    # the same bytes under two names: downloaded once
            if job.expected.sha256 in first:
                copies.append(job)
            else:
                first[job.expected.sha256] = job
        with concurrent.futures.ThreadPoolExecutor(max_workers=self.workers) as pool:
            futures = {pool.submit(self._one, job): job for job in first.values()}
            for future in concurrent.futures.as_completed(futures):
                job = futures[future]
                try:
                    report.downloaded_bytes += future.result()
                    report.done.append(job)
                except FetchError as exc:
                    report.failed.append((job, str(exc)))
                except Exception as exc:                     # never let one file stop the others' report
                    report.failed.append((job, f"{job.expected.name} could not be downloaded ({_reason(exc)}). "
                                               "Nothing was changed."))
        for job in copies:
            source = first[job.expected.sha256]
            if source not in report.done:
                report.failed.append((job, f"{job.expected.name} could not be downloaded (the same file under the "
                                           f"name {source.expected.name} failed). Nothing was changed."))
                continue
            try:
                self._copy_checked(source.target, job)
                report.done.append(job)
            except FetchError as exc:
                report.failed.append((job, str(exc)))
        return report

    def _copy_checked(self, source: Path, job: Job) -> None:
        temporary = job.target.with_name(job.target.name + ".bigfetch-copy")
        try:
            job.target.parent.mkdir(parents=True, exist_ok=True)
            no_links_below(Path(os.path.commonpath([source, job.target])), job.target)
            _remove(temporary)
            shutil.copyfile(source, temporary)
            if sha256_file(temporary) != job.expected.sha256:
                raise Refused(f"{job.expected.name} did not match its checksum, so it was deleted and not used. "
                              "Nothing was changed.")
            os.replace(temporary, job.target)
        except OSError as exc:
            raise FetchError(f"{job.expected.name} could not be written ({_reason(exc)}). Nothing was changed.") from exc
        finally:
            _remove(temporary)

    def _one(self, job: Job) -> int:
        """One file: continue or start its part, check it, give it its final name. Returns the bytes downloaded."""
        downloaded = 0
        for _ in range(2):
            resumed, count, digest = self._transfer(job)
            downloaded += count
            size = os.lstat(job.part).st_size
            if job.size is not None and size != job.size:
                _remove(job.part)
                raise Refused(f"{job.expected.name} arrived with the wrong size, so it was deleted and not used. "
                              "Nothing was changed.")
            if digest == job.expected.sha256:
                job.target.parent.mkdir(parents=True, exist_ok=True)
                no_links_below(Path(os.path.commonpath([job.part, job.target])), job.target)
                os.replace(job.part, job.target)
                _sync_folder(job.target.parent)
                self.say(f"{job.expected.name}: downloaded and {TRUST_WORDS.get(job.expected.trust, 'checked')}.")
                return downloaded
            _remove(job.part)
            if not resumed:
                break
            self.say(f"{job.expected.name}: the continued download did not match; starting it again from the start.")
        raise Refused(f"{job.expected.name} did not match its checksum, so it was deleted and not used. "
                      "Nothing was changed.")

    def _transfer(self, job: Job) -> tuple[bool, int, str]:
        """Fill job.part up to the whole file, hashing as it goes. Returns (whether earlier bytes were continued,
        bytes downloaded now, SHA-256 of the whole part)."""
        limit = job.size if job.size is not None else UNKNOWN_SIZE_LIMIT
        resumed = False
        count = 0
        problem: BaseException | None = None
        shown = PROGRESS_STEP
        hasher, hashed = None, -1
        for _ in range(self.tries):
            if os.path.lexists(job.part) and not is_plain_file(job.part):
                raise FetchError(f"the half-finished download of {job.expected.name} is not a plain file. "
                                 "Nothing was changed.")
            have = os.lstat(job.part).st_size if is_plain_file(job.part) else 0
            if have > limit:
                _truncate(job.part)
                have = 0
            if hashed != have:                              # what is in the part, hashed once (then as it grows)
                hasher, hashed = _hash_prefix(job.part, have), have
            if job.size is not None and have == job.size:
                if not os.path.lexists(job.part):           # an empty file: nothing to download, but it must exist
                    os.close(os.open(job.part, os.O_WRONLY | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600))
                return resumed, count, hasher.hexdigest()
            headers = {"Range": f"bytes={have}-"} if have else {}
            try:
                with self._open(job.url, headers) as response:
                    status = getattr(response, "status", 200)
                    start = _range_start(response)
                    if status == 206 and start != have:
                        raise _Restart()                    # a part of the file this download did not ask for
                    if status not in (200, 206):
                        raise _Restart()
                    if status == 200 and have:              # the server sends the whole file again
                        _truncate(job.part)
                        have = 0
                        hasher, hashed = hashlib.sha256(), 0
                    resumed = resumed or bool(have)
                    length = response.headers.get("Content-Length")
                    total = have + int(length.strip()) if length is not None and length.strip().isdigit() else None
                    if total is not None and total > limit:
                        raise Refused(f"{job.expected.name} is larger than expected, so it was not downloaded. "
                                      "Nothing was changed.")
                    flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0) \
                        | getattr(os, "O_BINARY", 0)
                    descriptor = os.open(job.part, flags, 0o600)
                    with os.fdopen(descriptor, "ab") as out:
                        while True:
                            block = response.read(CHUNK)
                            if not block:
                                break
                            if have + len(block) > limit:
                                raise Refused(f"{job.expected.name} is larger than expected, so it was deleted. "
                                              "Nothing was changed.")
                            out.write(block)
                            hasher.update(block)
                            have += len(block)
                            hashed = have
                            count += len(block)
                            if count >= shown:
                                self.say(f"  {job.expected.name}: {human(have)} of {human(job.size)} ...")
                                shown += PROGRESS_STEP
                        out.flush()
                        os.fsync(out.fileno())
                    if (total is not None and have < total) or (job.size is not None and have < job.size):
                        problem = ConnectionError("the connection broke off before the whole file arrived")
                        continue
                    return resumed, count, hasher.hexdigest()
            except _Restart:
                _truncate(job.part)
                problem = ConnectionError("the server started the file again")
                continue
            except Refused:
                _remove(job.part)
                raise
            except urllib.error.HTTPError as exc:
                exc.close()
                if exc.code == 416 and have:
                    _truncate(job.part)                     # the bytes kept here no longer fit: start again
                    problem = exc
                    continue
                if exc.code in (404, 410):
                    raise FetchError(f"{job.expected.name} is no longer at its address (it may have been replaced "
                                     "by a newer version). Nothing was changed.") from exc
                if exc.code < 500 and exc.code != 429:
                    raise FetchError(f"{job.expected.name} could not be downloaded (the server said {exc.code}). "
                                     "Nothing was changed.") from exc
                problem = exc
            except FetchError:
                raise
            except (urllib.error.URLError, OSError, TimeoutError, http.client.HTTPException) as exc:
                if isinstance(exc, OSError) and exc.errno in DISK_FULL:
                    raise FetchError(f"the drive ran out of free space while {job.expected.name} was downloading. "
                                     "What arrived is kept, so the next try continues where it stopped. Free up "
                                     "some space, then try again. Nothing was changed.") from exc
                problem = exc                               # cut short: the next try continues from what arrived
        raise FetchError(f"{job.expected.name} could not be downloaded completely ({_reason(problem)}). What "
                         "arrived is kept, so the next try continues where it stopped. Nothing was changed.")


def _hash_prefix(path: Path, length: int):
    digest = hashlib.sha256()
    if length:
        with open(path, "rb") as handle:
            left = length
            while left:
                block = handle.read(min(CHUNK, left))
                if not block:
                    raise FetchError(f"the half-finished download {path.name} changed while it was read")
                digest.update(block)
                left -= len(block)
    return digest


def _range_start(response) -> int | None:
    headers = getattr(response, "headers", None)
    match = CONTENT_RANGE.match((headers.get("Content-Range", "") if headers is not None else "") or "")
    return int(match.group(1)) if match else None


def _truncate(path: Path) -> None:
    if os.path.lexists(path):
        if not is_plain_file(path):
            raise FetchError(f"{path.name} is not a plain file")
        with open(path, "r+b") as handle:
            handle.truncate(0)


def _remove(path: Path) -> None:
    try:
        if os.path.lexists(path):
            os.unlink(path)
    except OSError:
        pass


def _sync_folder(folder: Path) -> None:
    try:
        descriptor = os.open(folder, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(descriptor)
    except OSError:
        pass
    finally:
        os.close(descriptor)


def _shown(url: str) -> str:
    """An address as it may be shown: no user name, password or query (they can hold secrets)."""
    try:
        parts = urllib.parse.urlsplit(url or "")
        host = parts.hostname or ""
        if parts.port:
            host += f":{parts.port}"
        return urllib.parse.urlunsplit((parts.scheme, host, parts.path, "", ""))
    except ValueError:
        return "the address"


def _reason(exc: BaseException | None) -> str:
    if isinstance(exc, OSError) and exc.errno in DISK_FULL:
        return "the drive has no free space left; free up some space, then try again"
    if isinstance(exc, PermissionError):
        return "this computer did not allow the file to be written there"
    if isinstance(exc, urllib.error.HTTPError):
        return f"the server said {exc.code}"
    if isinstance(exc, (TimeoutError,)) or "timed out" in str(exc):
        return "the connection timed out"
    if isinstance(exc, (urllib.error.URLError, OSError, http.client.HTTPException, ConnectionError)):
        return "the connection broke off or could not be made"
    return type(exc).__name__ if exc is not None else "unknown problem"
