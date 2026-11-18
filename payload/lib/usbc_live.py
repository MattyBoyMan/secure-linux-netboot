"""Drive-builder add-on (contracts C9, C17): run Secure Linux live from the drive, and keep your files on it.

  secure-linux-usb-creator live-addon --store S --iso FILE --checksum FILE [--keys FILE ...] [--persistence-size 8G]
  secure-linux-usb-creator live-addon --store S [--download] [--fedora-version N] [--keys FILE ...]
        Adds Fedora's KDE Live image to the saved master: "LIVE MODE ADDED TO MASTER".
        The image is checked against Fedora's signed CHECKSUM file with gpgv first. Only the part of that file the
        signature covers is ever read. The keys are the Fedora keys this computer already trusts
        (/etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-*-primary, from the fedora-gpg-keys package) unless --keys names others.
        The result is a new saved master that shares every other file with the current one (that one is kept, so
        master-undo goes back). Free space is checked first; it holds the store lock (contract C4).
        Works offline with --iso and --checksum (files you already have), or online with --download.

  secure-linux-usb-creator live-menu --drive FOLDER --out FOLDER2 [--nomad-root FOLDER3]
        Reads a drive that already exists and writes the start menu it should have (ventoy.json), plus
        START-NOMAD.sh when the drive carries the NOMAD offline library, into FOLDER2 only. It never writes to the
        drive: FOLDER2 must be outside it. Copying the result onto a drive is a separate, checked step.

After every verified Portable tools copy (after_copy), when the saved master holds the live image:
  - the drive's own start menu (ventoy/ventoy.json, a per-drive file) gets "Try Secure Linux without installing
    (keeps your files on this drive)" right after the main setup entry;
  - the space that keeps your files (persistence/secure-linux-live.dat, default 8 GB) is made for this drive only,
    after a free-space check, and never when there is no room (the menu then says nothing is kept);
  - an existing saved-changes file is never created again, changed or read in full;
  - the drive's file list and passport are brought up to date for the changed start menu.
The saved-changes file is never put in a saved master: live-addon leaves any such file out.

Facts about Ventoy that only a real start of a computer can prove (kept as named constants, see the notes):
  PERSISTENCE_LABEL, MENU_CLASS and that an image_list entry outside /ISO shows in the menu.
"""

import base64
import datetime
import glob
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import types
import urllib.parse
import urllib.request
import uuid

COMMANDS = ("live-addon", "live-menu")
NO_DEVICE_COMMANDS = COMMANDS            # the saved master's folder and plain folders only, never a raw drive

LIVE_DIR = "ISO/live"
LIVE_RECORD = LIVE_DIR + "/secure-linux-live.json"
PERSISTENCE_PATH = "persistence/secure-linux-live.dat"
# Ventoy persistence plug-in: the file is an ext4 file system whose label tells the live system to use it.
# "vtoycow" is the label believed right for Fedora-style live systems. It was NOT checked against Ventoy's
# documentation or a real start of a computer yet (P28a notes, OPEN 2): check it there before relying on it.
PERSISTENCE_LABEL = "vtoycow"
PERSISTENCE_FS = "ext4"
DEFAULT_PERSISTENCE = 8 * 1024 ** 3
MIN_PERSISTENCE = 16 * 1024 ** 2
MAX_PERSISTENCE = 256 * 1024 ** 3
PERSISTENCE_ROOM = 256 * 1024 ** 2       # left free on the drive after the saved-changes file is made
MASTER_ROOM = 64 * 1024 ** 2             # left free next to the saved master after the live image is added
DOWNLOAD_GUESS = 4 * 1024 ** 3           # a Fedora KDE Live image is about 2.7 GB; asked for before a download
MAX_CHECKSUM = 1024 * 1024
MAX_KEY_FILE = 1024 * 1024
GPGV_TIMEOUT = 120
EXT_MAGIC_OFFSET = 1024 + 0x38
EXT_LABEL_OFFSET = 1024 + 0x78
MENU_CLASS = "sl-install"                # an icon the drive's menu design already has (stick-theme/icons)

FEDORA_KEY_GLOB = "/etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-*-primary"
FEDORA_RELEASES = "https://download.fedoraproject.org/pub/fedora/linux/releases/{version}/KDE/x86_64/iso/"

LIVE_ALIAS = "Try Secure Linux without installing (keeps your files on this drive)"
LIVE_ALIAS_NOTHING_KEPT = "Try Secure Linux without installing (nothing is kept after switching off)"
LIVE_TIP = "Runs from this drive. Nothing on this computer changes. F6: start normally."
# The saved-changes space (persistence/secure-linux-live.dat) is a plain ext4 file: it is not locked (X5anywhere F10).
LIVE_NOT_LOCKED = "Files you keep are not locked."
LIVE_TIP_KEPT = "Runs from this drive. Nothing on this computer changes. " + LIVE_NOT_LOCKED + " F6: start normally."
PERSISTENCE_NOT_LOCKED_NOTE = ("Live mode: the files you keep there are NOT locked with a password: anyone who has this "
                               "drive can read them. Keep private papers on an installed Secure Linux computer, whose "
                               "home folder is locked.")
NOMAD_ALIAS = "Start from this drive without installing (NOMAD offline library)"
NOMAD_TIP = "Then open the drive's SecureLinux-NOMAD folder and run start-nomad.sh. Nothing on this computer changes."
NOMAD_FOLDER = "SecureLinux-NOMAD"
NOMAD_BOOT = NOMAD_FOLDER + "/boot"
NOMAD_FINDER = "START-NOMAD.sh"
OUR_ALIASES = (LIVE_ALIAS, LIVE_ALIAS_NOTHING_KEPT, NOMAD_ALIAS)

PERSISTENCE_GLOBS = (re.compile(r"^persistence/", re.I), re.compile(r"(^|/)[^/]*persistence[^/]*\.(dat|img)$", re.I))
SIGNED_LINE = re.compile(r"^SHA256 \(([^()/\\]+)\) = ([0-9a-fA-F]{64})$")
GNU_LINE = re.compile(r"^([0-9a-fA-F]{64}) [ *]([^/\\]+)$")
SIZE_RE = re.compile(r"^\s*([0-9]+(?:\.[0-9]+)?)\s*([KMGT]?)(?:i?B)?\s*$", re.I)
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
ISO_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*\.iso$")

NEEDS_ADMIN = ("the saved master belongs to the administrator. Run this again as administrator, for example: "
               "sudo secure-linux-usb-creator {command} --store {store}. Nothing was changed.")

# The live system started from the drive runs this to find the NOMAD offline library on any plugged-in drive.
START_NOMAD_SCRIPT = r"""#!/bin/sh
# START-NOMAD.sh - start the NOMAD offline library from the live system (Secure Linux drive).
# Use: open a terminal and type   sh START-NOMAD.sh   (it asks for administrator rights itself).
# It looks for the SecureLinux-NOMAD folder on every plugged-in USB drive, opens a USB drive that is not open yet,
# and starts start-nomad.sh from there. It never opens or changes this computer's own disks.
set -u
say() { printf '%s\n' "$*"; }
case "${1:-}" in
  -h|--help)
    say "START-NOMAD.sh: finds the NOMAD offline library on a plugged-in drive and starts it."
    say "Then open Firefox and go to http://localhost:8080 . To stop it before switching off: sh START-NOMAD.sh --stop"
    exit 0 ;;
esac
if [ "$(id -u)" -ne 0 ]; then
  say "Starting NOMAD needs administrator rights. On the live system just press Enter if a password is asked."
  exec sudo sh "$0" "$@"
fi
find_nomad() {
  for dir in ${SL_NOMAD_SEARCH_DIRS:-/run/media/*/* /media/*/* /media/* /mnt/*}; do
    if [ -f "$dir/SecureLinux-NOMAD/start-nomad.sh" ]; then
      printf '%s\n' "$dir/SecureLinux-NOMAD"
      return 0
    fi
  done
  return 1
}
found=$(find_nomad) || found=""
if [ -z "$found" ] && [ -z "${SL_NOMAD_SEARCH_DIRS:-}" ] && command -v udisksctl >/dev/null 2>&1; then
  say "Opening the plugged-in USB drives to look for NOMAD..."
  for disk in $(lsblk -dnrpo NAME,TRAN 2>/dev/null | awk '$2 == "usb" { print $1 }'); do
    for part in $(lsblk -nrpo NAME,TYPE,MOUNTPOINT "$disk" 2>/dev/null | awk '$2 == "part" && $3 == "" { print $1 }'); do
      udisksctl mount --no-user-interaction -b "$part" >/dev/null 2>&1 || true
    done
  done
  found=$(find_nomad) || found=""
fi
if [ -z "$found" ]; then
  say "NOMAD was not found on any plugged-in drive."
  say "If NOMAD is on the drive this live system started from, that part of the drive is in use by the live system."
  say "Plug in the other drive that carries SecureLinux-NOMAD and run this again. Nothing was changed."
  exit 1
fi
cd "$found" || exit 1
# The drive's checked starter (beside this folder) checks every file's fingerprint first and keeps NOMAD's saved data
# locked with a passphrase. When the drive has it, NOMAD is started and stopped through it.
if [ -f ../START-NOMAD-LINUX.sh ] && [ -f ../NOMAD-ANYWHERE/nomad-anywhere-common.sh ]; then
  if [ "${1:-}" = "--stop" ]; then
    shift
    say "Stopping NOMAD in $found and locking its saved data again..."
    exec bash ../START-NOMAD-LINUX.sh stop "$@"
  fi
  say "Found NOMAD in $found. It checks the drive's files first, then asks for the passphrase that locks NOMAD's saved data."
  exec bash ../START-NOMAD-LINUX.sh full "$@"
fi
if [ "${1:-}" = "--stop" ]; then
  shift
  say "Stopping NOMAD in $found ..."
  exec bash ./stop-nomad.sh "$@"
fi
say "Found NOMAD in $found. Starting it (the first start can take 5 to 15 minutes)..."
exec bash ./start-nomad.sh "$@"
"""


# ---- registration (contract C17) ---------------------------------------------------------------------------

def register(subparsers):
    addon = subparsers.add_parser(
        "live-addon",
        help="add Fedora's KDE Live image to the saved master, so drives made from it can run Secure Linux "
             "without installing (checked against Fedora's signed checksum first)",
    )
    addon.add_argument("--store", required=True, help="master store containing current and generations")
    source = addon.add_mutually_exclusive_group()
    source.add_argument("--iso", help="a Fedora Live image you already have (works with no internet)")
    source.add_argument("--download", action="store_true",
                        help="download Fedora's KDE Live image and its CHECKSUM (the default without --iso)")
    addon.add_argument("--checksum", help="with --iso: Fedora's signed CHECKSUM file for that image")
    addon.add_argument("--fedora-version", help="with --download: Fedora release number (default: this computer's)")
    addon.add_argument("--url", help="with --download: the folder to download from (https only; default: Fedora's)")
    addon.add_argument("--keys", action="append", default=[],
                       help="Fedora's own signing key file (default: the Fedora keys this computer already trusts, "
                            + FEDORA_KEY_GLOB + "); can be given more than once")
    addon.add_argument("--persistence-size", default="8G",
                       help="space each drive gets to keep your files in live mode (default 8G; at least 16M)")
    menu = subparsers.add_parser(
        "live-menu",
        help="show the start menu an existing drive should have for live mode and NOMAD; writes it to --out "
             "only, never to the drive",
    )
    menu.add_argument("--drive", required=True, help="the drive's top folder (read only)")
    menu.add_argument("--out", required=True, help="a folder outside the drive for the new ventoy.json")
    menu.add_argument("--nomad-root", help="the top folder of another part of the drive that holds SecureLinux-NOMAD")
    return list(COMMANDS)


def run(args, api):
    if args.command == "live-menu":
        return live_menu(args, api)
    return live_addon(args, api)


# ---- small helpers -------------------------------------------------------------------------------------------

def _engine(api):
    """The drive builder's own helpers: the same code that makes and checks every saved master and drive."""
    space = getattr(api.load_master, "__globals__", None) or {}
    wanted = ("read_manifest", "validate_manifest", "atomic_write", "atomic_replace", "json_data", "sha256_bytes",
              "hash_file", "utc_now", "fsync_directory", "writable_tree_for_removal", "template_record",
              "write_checked_file", "passport_text")
    missing = [name for name in wanted if not callable(space.get(name))]
    if missing:
        raise api.CreatorError("this drive builder is missing parts this add-on needs. Update Secure Linux, "
                               "then try again. Nothing was changed.")
    engine = types.SimpleNamespace(**{name: space[name] for name in wanted})
    # Fz4: the ordered parallel hasher; an older drive builder without it is checked one file at a time.
    engine.hash_files_parallel = space.get("hash_files_parallel") if callable(space.get("hash_files_parallel")) else None
    engine.write_master_status = space.get("write_master_status") if callable(space.get("write_master_status")) else None
    engine.files_only = space.get("FILES_ONLY_KIND", "files-only")
    engine.schema = space.get("SCHEMA", 1)
    engine.app = space.get("APP", api.app)
    engine.version = space.get("VERSION", api.version)
    engine.drive_files_list = space.get("DRIVE_FILES_LIST", "linux-setup/SECURE-LINUX-DRIVE-FILES.json")
    engine.passport_json = space.get("PASSPORT_JSON", "SECURE-LINUX-DRIVE-PASSPORT.json")
    engine.passport_txt = space.get("PASSPORT_TXT", "SECURE-LINUX-DRIVE-PASSPORT.txt")
    return engine


def _verification_error(api):
    return getattr(api, "VerificationError", api.CreatorError)


def parse_size(text):
    match = SIZE_RE.fullmatch(str(text or ""))
    if not match:
        raise ValueError(f"{text!r} is not a size such as 8G or 512M")
    number = float(match.group(1))
    unit = match.group(2).upper()
    value = int(number * {"": 1, "K": 1024, "M": 1024 ** 2, "G": 1024 ** 3, "T": 1024 ** 4}[unit])
    return value - value % (1024 * 1024)           # Ventoy wants whole megabytes


def human(number):
    value = float(number)
    for unit in ("bytes", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            return f"{int(value)} bytes" if unit == "bytes" else f"{value:.1f} {unit}"
        value /= 1024
    return f"{number} bytes"


def is_persistence(path):
    return any(regex.search(path) for regex in PERSISTENCE_GLOBS)


def is_live_image(path):
    return path.lower().startswith(LIVE_DIR.lower() + "/") and path.lower().endswith(".iso") and path.count("/") == 2


def _mock(args):
    return bool(getattr(args, "mock_devices", None))


def _mock_value(name, args):
    """Test-only settings work only with the drive builder's own test switch (--mock-devices), never otherwise."""
    return os.environ.get(name) if _mock(args) else None


# ---- Fedora's signed CHECKSUM ----------------------------------------------------------------------------------

def dearmor_keys(raw, what):
    """OpenPGP public keys as binary packets (gpgv reads only those). Armored or binary key files are accepted; a
    private key is refused in either form."""
    if raw[:1] and raw[0] & 0x80:
        return refuse_private_packets(raw, what)
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
    return refuse_private_packets(out, what)


def trusted_key_files(args):
    if args.keys:
        return [Path(path).expanduser() for path in args.keys]
    return [Path(path) for path in sorted(glob.glob(FEDORA_KEY_GLOB))]


def gpgv_program():
    for name in ("gpgv", "gpgv2"):
        found = shutil.which(name)
        if found:
            return found
    return None


def verify_signed_checksum(checksum_path, key_files, api):
    """(the signed text only, signing key fingerprint). Anything outside the signature is never returned."""
    refuse = _verification_error(api)
    program = gpgv_program()
    if not program:
        raise api.CreatorError("the signature checker (gpgv, part of gnupg2) is not installed on this computer, so "
                               "the live image cannot be checked. Install gnupg2, then try again. Nothing was changed.")
    if not key_files:
        raise api.CreatorError("Fedora's signing keys were not found on this computer (" + FEDORA_KEY_GLOB + "). "
                               "Give Fedora's key file with --keys, then try again. Nothing was changed.")
    keyring = b""
    for path in key_files:
        try:
            if path.stat().st_size > MAX_KEY_FILE:
                raise ValueError(f"{path.name} is larger than any key file")
            keyring += dearmor_keys(path.read_bytes(), path.name)
        except (OSError, ValueError) as exc:
            raise api.CreatorError(f"the key file {path} cannot be used ({exc}). Nothing was changed.") from exc
    try:
        data = Path(checksum_path).read_bytes()
    except OSError as exc:
        raise api.CreatorError(f"the CHECKSUM file {checksum_path} cannot be read. Nothing was changed.") from exc
    if len(data) > MAX_CHECKSUM or b"-----BEGIN PGP SIGNED MESSAGE-----" not in data:
        raise refuse("the CHECKSUM file is not signed by Fedora, so the live image was not added. Nothing was changed.")
    work = Path(tempfile.mkdtemp(prefix="sl-live-check-"))
    try:
        (work / "home").mkdir(mode=0o700)
        (work / "trusted.gpg").write_bytes(keyring)
        (work / "CHECKSUM").write_bytes(data)
        # Relative names with cwd=work: no Windows or Linux path ever reaches gpgv's own path handling.
        try:
            result = subprocess.run(
                [program, "--homedir", "home", "--status-fd", "1", "--keyring", "./trusted.gpg",
                 "--output", "signed.txt", "CHECKSUM"],
                cwd=work, capture_output=True, text=True, timeout=GPGV_TIMEOUT,
                env={**os.environ, "LC_ALL": "C", "LANG": "C"})
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise api.CreatorError(f"the signature checker could not run ({type(exc).__name__}). "
                                   "Nothing was changed.") from exc
        codes = [line.split()[1:] for line in result.stdout.splitlines() if line.startswith("[GNUPG:] ")]
        names = {fields[0] for fields in codes if fields}
        valid = [fields for fields in codes if fields and fields[0] == "VALIDSIG" and len(fields) >= 10]
        bad = names & {"BADSIG", "ERRSIG", "EXPSIG", "EXPKEYSIG", "REVKEYSIG", "NO_PUBKEY", "FAILURE"}
        signed = work / "signed.txt"
        if result.returncode != 0 or bad or not valid or "GOODSIG" not in names or not signed.is_file():
            raise refuse("the CHECKSUM file's signature is not a good signature by a trusted Fedora key, so the "
                         "live image was not added. Nothing was changed.")
        return signed.read_bytes().decode("utf-8", "replace"), valid[0][-1].upper()
    finally:
        shutil.rmtree(work, ignore_errors=True)


def signed_hashes(text):
    """name -> SHA-256 from the signed text: Fedora's 'SHA256 (name) = hash' lines (and 'hash  name' lines)."""
    found = {}
    for line in text.replace("\r\n", "\n").split("\n"):
        line = line.strip()
        match = SIGNED_LINE.fullmatch(line)
        if match:
            found[match.group(1)] = match.group(2).lower()
            continue
        match = GNU_LINE.fullmatch(line)
        if match:
            found[match.group(2).strip()] = match.group(1).lower()
    return found


def pick_live_image(hashes, wanted=None):
    if wanted:
        if wanted not in hashes:
            return None
        return wanted
    live = sorted(name for name in hashes if name.lower().endswith(".iso") and "live" in name.lower())
    if len(live) > 1:
        live = [name for name in live if "kde" in name.lower()] or live
    return live[0] if len(live) == 1 else None


# ---- live-addon ----------------------------------------------------------------------------------------------

def _check_store(store, command, api):
    try:
        names = os.listdir(store)
    except FileNotFoundError as exc:
        raise api.CreatorError(f"there is no saved master in {store}. Nothing was changed.") from exc
    except PermissionError as exc:
        raise api.CreatorError(NEEDS_ADMIN.format(command=command, store=store)) from exc
    except OSError as exc:
        raise api.CreatorError(f"the saved master folder {store} cannot be read. Nothing was changed.") from exc
    if "generations" not in names or "current" not in names:
        raise api.CreatorError(f"there is no saved master in {store} yet. Nothing was changed.")


def live_addon(args, api):
    store = os.path.abspath(args.store)
    try:
        persistence = parse_size(args.persistence_size)
    except ValueError as exc:
        raise api.CreatorError(f"--persistence-size: {exc}. Nothing was changed.") from exc
    if not MIN_PERSISTENCE <= persistence <= MAX_PERSISTENCE:
        raise api.CreatorError("--persistence-size must be between 16M and 256G. Nothing was changed.")
    if args.iso and not args.checksum:
        raise api.CreatorError("--iso needs Fedora's signed CHECKSUM file too (--checksum). Nothing was changed.")
    engine = _engine(api)
    _check_store(store, args.command, api)
    try:
        with api.store_lock(store, True):
            return _live_addon_locked(store, args, api, engine, persistence)
    except PermissionError as exc:
        raise api.CreatorError(NEEDS_ADMIN.format(command=args.command, store=store)) from exc


def _live_addon_locked(store, args, api, engine, persistence):
    _, old_id, old_root, manifest = engine.read_manifest(store)
    portable = manifest.get("portable")
    if not portable:
        raise api.CreatorError("this saved master holds no file tree; save a new master from a finished drive first. "
                               "Nothing was changed.")
    download_dir = None
    try:
        if not args.iso:
            download_dir = Path(store) / (".live-download-" + uuid.uuid4().hex[:12])
            iso_path, checksum_path = download_live(args, api, download_dir, store)
        else:
            iso_path, checksum_path = Path(args.iso).expanduser(), Path(args.checksum).expanduser()
            if not iso_path.is_file() or iso_path.is_symlink():
                raise api.CreatorError(f"the live image {iso_path} is not there. Nothing was changed.")
        name = iso_path.name
        if not ISO_NAME_RE.fullmatch(name):
            raise api.CreatorError(f"the live image's name {name!r} is not a plain file name. Nothing was changed.")
        text, fingerprint = verify_signed_checksum(checksum_path, trusted_key_files(args), api)
        hashes = signed_hashes(text)
        if name not in hashes:
            raise _verification_error(api)(f"Fedora's signed CHECKSUM does not list {name}, so it was not added. "
                                           "Nothing was changed.")
        expected = hashes[name]
        relative = f"{LIVE_DIR}/{name}"
        entries = {entry["path"]: entry for entry in portable["files"]}
        record = live_record(relative, expected, iso_path.stat().st_size, fingerprint, checksum_path.name, persistence,
                             engine)
        have = entries.get(relative)
        have_record = _master_record(old_root, entries)
        if (have and have["sha256"] == expected and isinstance(have_record, dict)
                and have_record.get("persistence_bytes") == persistence):
            api.say(f"LIVE MODE ALREADY IN MASTER: {name} (checked against Fedora's signed checksum).")
            return 0
        size = iso_path.stat().st_size
        if not api.free_space_ok(store, size + MASTER_ROOM):
            raise api.CreatorError(f"there is not enough free space next to the saved master for the live image "
                                   f"({human(size)} plus a little room). Free up some space, then try again. "
                                   "Nothing was changed.")
        return publish(store, old_id, old_root, manifest, iso_path, relative, expected, record, api, engine)
    finally:
        if download_dir is not None:
            shutil.rmtree(download_dir, ignore_errors=True)


def live_record(relative, sha256, size, fingerprint, checksum_name, persistence, engine):
    return {
        "schema": 1,
        "image": relative,
        "sha256": sha256,
        "size": size,
        "checked_with": f"Fedora's signed {checksum_name}",
        "signed_by": fingerprint,
        "persistence_bytes": persistence,
        "persistence_file": PERSISTENCE_PATH,
        "added_at": engine.utc_now(),
    }


def _master_record(root, entries):
    if LIVE_RECORD not in entries:
        return None
    try:
        return json.loads((Path(root) / "payload" / LIVE_RECORD).read_bytes())
    except (OSError, ValueError):
        return None


def _copy_hashed(source, destination):
    digest = hashlib.sha256()
    count = 0
    with open(source, "rb") as incoming, open(destination, "xb") as outgoing:
        while True:
            data = incoming.read(1024 * 1024)
            if not data:
                break
            outgoing.write(data)
            digest.update(data)
            count += len(data)
        outgoing.flush()
        os.fsync(outgoing.fileno())
    return count, digest.hexdigest()


def publish(store, old_id, old_root, manifest, iso_path, relative, expected, record, api, engine):
    """A new saved master: every file of the current one shared (hard link), plus the checked live image."""
    portable = manifest["portable"]
    old_payload = Path(old_root) / "payload"
    master_id = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S") + "-" + uuid.uuid4().hex[:12]
    generations = os.path.join(store, "generations")
    staging = os.path.join(generations, ".building-" + master_id)
    final = os.path.join(generations, master_id)
    os.mkdir(staging, mode=0o700)
    published = False
    left_out = []
    try:
        payload = Path(staging) / "payload"
        kept = []
        todo = []
        for entry in portable["files"]:
            path = entry["path"]
            if is_persistence(path):
                left_out.append(path)          # one drive's saved changes never go into a saved master
                continue
            if is_live_image(path) or path == LIVE_RECORD:
                continue                        # an older live image is replaced by the new one
            todo.append(entry)
        # Fz5: every kept file is checked first-to-last in list order, several at once (the same ordered helper the
        # drive builder uses); the first damaged or unreadable file stops everything, as before.
        if engine.hash_files_parallel:
            hashed = engine.hash_files_parallel((old_payload / entry["path"], entry["size"]) for entry in todo)
        else:
            hashed = (engine.hash_file(old_payload / entry["path"], entry["size"]) for entry in todo)
        for entry, (size, digest) in zip(todo, hashed):
            path = entry["path"]
            source = old_payload / path
            if size != entry["size"] or digest != entry["sha256"]:
                raise _verification_error(api)(f"a file of the saved master failed its check, so nothing was "
                                               f"changed: {path}")
            destination = payload / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            try:
                os.link(source, destination)   # shared with the current saved master: no time, no space
            except OSError:
                if not api.free_space_ok(store, entry["size"] + MASTER_ROOM):
                    raise api.CreatorError("there is not enough free space next to the saved master. "
                                           "Nothing was changed.")
                shutil.copyfile(source, destination)
            kept.append(dict(entry))
        destination = payload / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        api.say(f"Copying the checked live image into the saved master ({human(iso_path.stat().st_size)})...")
        size, digest = _copy_hashed(iso_path, destination)
        if digest != expected:
            raise _verification_error(api)("the live image does not match Fedora's signed checksum, so it was not "
                                           "added. Nothing was changed.")
        record = dict(record, size=size)
        record_raw = (json.dumps(record, indent=2, sort_keys=True) + "\n").encode("utf-8")
        (payload / LIVE_RECORD).write_bytes(record_raw)
        files = kept + [{"path": relative, "size": size, "sha256": digest},
                        {"path": LIVE_RECORD, "size": len(record_raw), "sha256": engine.sha256_bytes(record_raw)}]
        files.sort(key=lambda entry: entry["path"])
        new_portable = dict(portable)
        new_portable.update({"file_count": len(files), "payload_bytes": sum(entry["size"] for entry in files),
                             "files": files})
        source = manifest.get("source") if isinstance(manifest.get("source"), dict) else {}
        new_manifest = {
            "schema_version": engine.schema,
            "application": engine.app,
            "tool_version": engine.version,
            "kind": engine.files_only,
            "master_id": master_id,
            "created_at": engine.utc_now(),
            "release": manifest["release"],
            "source": {"kind": engine.files_only, "updated_from_master": old_id,
                       "variant": portable.get("captured_variant", source.get("variant", "full")),
                       "added": "live mode"},
            "portable": new_portable, **engine.template_record(manifest),
        }
        engine.validate_manifest(new_manifest)
        raw = engine.json_data(new_manifest)
        engine.atomic_write(os.path.join(staging, "manifest.json"), raw, 0o400)
        engine.atomic_write(os.path.join(staging, "manifest.sha256"),
                            (engine.sha256_bytes(raw) + "  manifest.json\n").encode(), 0o400)
        engine.fsync_directory(staging)
        for base, directories, names in os.walk(staging):
            for name in names:
                os.chmod(os.path.join(base, name), 0o400)
            for name in directories:
                os.chmod(os.path.join(base, name), 0o500)
        engine.atomic_replace(staging, final)
        os.chmod(final, 0o500)
        engine.fsync_directory(generations)
        engine.atomic_write(os.path.join(store, "current"), (master_id + "\n").encode(), 0o600)
        published = True
        if engine.write_master_status:
            engine.write_master_status(store, new_manifest)
        api.say("")
        api.say("LIVE MODE ADDED TO MASTER")
        api.say(f"New saved master: {master_id}. Live image: {relative} (checked against Fedora's signed checksum, "
                f"key {record['signed_by']}).")
        api.say(f"Every drive made from it gets the menu line \"{LIVE_ALIAS}\" and its own "
                f"{human(record['persistence_bytes'])} space for your files when the drive has room.")
        api.say(f"Every other file is shared with the previous saved master ({old_id}), which is kept: "
                "master-undo goes back to it.")
        if manifest.get("kind") != engine.files_only:
            api.say("Note: the new saved master holds the drive's files only, so it makes Portable tools copies. "
                    "Exact whole-drive clones are still made from the previous saved master.")
        if left_out:
            api.say(f"Left out: {len(left_out)} saved-changes file(s) of one drive ({', '.join(left_out)}). "
                    "One person's saved changes never go into a saved master.")
        return 0
    finally:
        if not published and os.path.isdir(staging):
            engine.writable_tree_for_removal(staging)
            shutil.rmtree(staging, ignore_errors=True)
            for base, _, names in os.walk(old_root):     # a shared file carries one permission for both
                for name in names:
                    try:
                        os.chmod(os.path.join(base, name), 0o400)
                    except OSError:
                        pass


# ---- download (online) ----------------------------------------------------------------------------------------

def fetch(url, limit):
    """Bytes of a small https file (an index page or a CHECKSUM)."""
    with urllib.request.urlopen(url, timeout=60) as response:
        if not response.geturl().startswith("https://"):
            raise ValueError("the download left https")
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError("the file is larger than expected")
    return data


def fetch_to(url, path, limit, say):
    with urllib.request.urlopen(url, timeout=60) as response, open(path, "xb") as out:
        if not response.geturl().startswith("https://"):
            raise ValueError("the download left https")
        count = 0
        step = 256 * 1024 * 1024
        shown = step
        while True:
            data = response.read(1024 * 1024)
            if not data:
                break
            count += len(data)
            if count > limit:
                raise ValueError("the download is larger than any live image")
            out.write(data)
            if count >= shown:
                say(f"  downloaded {human(count)} ...")
                shown += step
        out.flush()
        os.fsync(out.fileno())
    return count


def fedora_version(args):
    if args.fedora_version:
        if not re.fullmatch(r"[0-9]{2,3}", str(args.fedora_version)):
            raise ValueError("--fedora-version is a number such as 45")
        return str(args.fedora_version)
    try:
        fields = dict(line.split("=", 1) for line in Path("/etc/os-release").read_text().splitlines() if "=" in line)
    except OSError:
        fields = {}
    if fields.get("ID", "").strip('"') == "fedora" and re.fullmatch(r"[0-9]{2,3}", fields.get("VERSION_ID", "").strip('"')):
        return fields["VERSION_ID"].strip('"')
    raise ValueError("this computer's Fedora version is not known; give --fedora-version, for example 45")


def index_names(html):
    names = []
    for href in re.findall(r'href="([^"?#]+)"', html):
        name = urllib.parse.unquote(href.rstrip("/").rsplit("/", 1)[-1])
        if name and name not in names:
            names.append(name)
    return names


def download_live(args, api, folder, store, opener=None):
    """Download Fedora's CHECKSUM and its live image over https into a folder next to the saved master."""
    get, get_to = (opener or (fetch, fetch_to))
    try:
        base = args.url or FEDORA_RELEASES.format(version=fedora_version(args))
    except ValueError as exc:
        raise api.CreatorError(f"{exc}. Nothing was changed.") from exc
    if not base.startswith("https://"):
        raise api.CreatorError("--url must start with https://. Nothing was changed.")
    base = base if base.endswith("/") else base + "/"
    if not api.free_space_ok(store, DOWNLOAD_GUESS + MASTER_ROOM):
        raise api.CreatorError(f"there is not enough free space next to the saved master to download the live image "
                               f"(about {human(DOWNLOAD_GUESS)} is needed). Free up some space, then try again. "
                               "Nothing was changed.")
    folder.mkdir(mode=0o700)
    try:
        listing = get(base, MAX_CHECKSUM).decode("utf-8", "replace")
        sums = [name for name in index_names(listing) if name.endswith("CHECKSUM")]
        if len(sums) != 1:
            raise ValueError("Fedora's download folder does not hold exactly one CHECKSUM file")
        checksum = folder / sums[0]
        checksum.write_bytes(get(base + urllib.parse.quote(sums[0]), MAX_CHECKSUM))
        text, _ = verify_signed_checksum(checksum, trusted_key_files(args), api)
        name = pick_live_image(signed_hashes(text))
        if not name or not ISO_NAME_RE.fullmatch(name):
            raise ValueError("Fedora's signed CHECKSUM names no single live image")
        api.say(f"Downloading {name} from {base} (checked against the signed CHECKSUM afterwards)...")
        iso = folder / name
        get_to(base + urllib.parse.quote(name), iso, 16 * 1024 ** 3, api.say)
        return iso, checksum
    except (OSError, ValueError) as exc:
        raise api.CreatorError(f"the live image could not be downloaded ({exc}). Nothing was changed. "
                               "Without internet, use --iso and --checksum with files you already have.") from exc


# ---- the start menu (ventoy.json) ------------------------------------------------------------------------------

def _entries(config, key):
    value = config.get(key)
    return value if isinstance(value, list) else None


def _set_alias(config, image, alias):
    aliases = _entries(config, "menu_alias")
    if aliases is None:
        aliases = config["menu_alias"] = []
    for item in aliases:
        if isinstance(item, dict) and item.get("image") == image:
            if item.get("alias") in OUR_ALIASES or not item.get("alias"):
                item["alias"] = alias
            return
    aliases.append({"image": image, "alias": alias})


def _set_tip(config, image, tip):
    tips_block = config.get("menu_tip")
    if not isinstance(tips_block, dict):
        tips_block = config["menu_tip"] = {"tips": []}
    tips = tips_block.get("tips")
    if not isinstance(tips, list):
        tips = tips_block["tips"] = []
    if not any(isinstance(item, dict) and item.get("image") == image for item in tips):
        tips.append({"image": image, "tip": tip})


def _set_class(config, image):
    classes = _entries(config, "menu_class")
    if classes is None:
        return                                     # the drive's menu has no pictures; nothing to match
    key = Path(image).stem
    if not any(isinstance(item, dict) and item.get("key") == key for item in classes):
        classes.append({"key": key, "class": MENU_CLASS})


def _search_root(config):
    for item in _entries(config, "control") or []:
        if isinstance(item, dict) and "VTOY_DEFAULT_SEARCH_ROOT" in item:
            return str(item["VTOY_DEFAULT_SEARCH_ROOT"])
    return None


def _shows(config, image):
    """Can this image show in the menu at all? (image_list names it, or no list and it is under the search root)"""
    listed = _entries(config, "image_list")
    if listed is not None:
        return True
    root = _search_root(config)
    return root is None or image.startswith(root.rstrip("/") + "/")


def plan_menu(config, live_image=None, persistence=None, nomad_images=()):
    """The drive's ventoy.json with the live entries added (a new dict) and plain notes. Running it twice changes
    nothing more. Never removes an entry the drive already has."""
    config = json.loads(json.dumps(config if isinstance(config, dict) else {}))
    notes = []
    images = []
    if live_image:
        images.append((live_image, LIVE_ALIAS if persistence else LIVE_ALIAS_NOTHING_KEPT,
                       LIVE_TIP_KEPT if persistence else LIVE_TIP))
    for image in nomad_images:
        images.append((image, NOMAD_ALIAS, NOMAD_TIP))
    listed = _entries(config, "image_list")
    place = 1 if listed else 0
    for image, alias, tip in images:
        if not _shows(config, image):
            notes.append(f"{image} cannot show in this drive's start menu: the menu only looks in "
                         f"{_search_root(config)}. Copy that file into the drive's ISO/live/ folder, then run "
                         "this again.")
            continue
        if listed is not None:
            if image in listed:
                place = listed.index(image) + 1
            else:
                listed.insert(min(place, len(listed)), image)
                place = listed.index(image) + 1
        _set_alias(config, image, alias)
        _set_tip(config, image, tip)
        _set_class(config, image)
    if live_image and persistence:
        entries = _entries(config, "persistence")
        if entries is None:
            entries = config["persistence"] = []
        if not any(isinstance(item, dict) and item.get("image") == live_image for item in entries):
            entries.append({"image": live_image, "backend": "/" + persistence, "autosel": 1})
    return config, notes


def menu_bytes(config):
    return (json.dumps(config, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def read_menu(path):
    data = Path(path).read_bytes()
    value = json.loads(data.decode("utf-8-sig"))
    if not isinstance(value, dict):
        raise ValueError("the start menu file is not a JSON object")
    return value


def find_nomad_images(root):
    folder = Path(root) / NOMAD_BOOT
    try:
        names = sorted(path.name for path in folder.iterdir() if path.is_file() and not path.is_symlink())
    except OSError:
        return []
    return ["/" + NOMAD_BOOT + "/" + name for name in names
            if name.lower().endswith(".iso") and "live" in name.lower() and ISO_NAME_RE.fullmatch(name)]


def find_live_images(root):
    folder = Path(root) / LIVE_DIR
    try:
        names = sorted(path.name for path in folder.iterdir() if path.is_file() and not path.is_symlink())
    except OSError:
        return []
    return ["/" + LIVE_DIR + "/" + name for name in names if name.lower().endswith(".iso") and ISO_NAME_RE.fullmatch(name)]


# ---- live-menu (an existing drive; output to a folder outside it) ----------------------------------------------

def _inside(child, parent):
    try:
        Path(child).resolve().relative_to(Path(parent).resolve())
        return True
    except ValueError:
        return False


def live_menu(args, api):
    drive = Path(args.drive).expanduser()
    out = Path(args.out).expanduser()
    if not (drive / "ventoy" / "ventoy.json").is_file():
        raise api.CreatorError(f"{drive} is not the top of a Secure Linux drive (it has no ventoy/ventoy.json). "
                               "Nothing was written.")
    if _inside(out, drive) or _inside(drive, out):
        raise api.CreatorError("--out must be a folder outside the drive: this command never writes to a drive. "
                               "Nothing was written.")
    try:
        config = read_menu(drive / "ventoy" / "ventoy.json")
    except (OSError, ValueError) as exc:
        raise api.CreatorError(f"the drive's start menu (ventoy/ventoy.json) cannot be read ({exc}). "
                               "Nothing was written.") from exc
    lives = find_live_images(drive)
    live = lives[-1] if lives else None
    persistence = PERSISTENCE_PATH if live and (drive / PERSISTENCE_PATH).is_file() else None
    nomads = find_nomad_images(drive)
    new, notes = plan_menu(config, live, persistence, nomads)
    elsewhere = []
    if args.nomad_root:
        other = Path(args.nomad_root).expanduser()
        if other.resolve() != drive.resolve():
            elsewhere = [image for image in find_nomad_images(other)]
    out.mkdir(parents=True, exist_ok=True)
    (out / "ventoy.json").write_bytes(menu_bytes(new))
    has_nomad = bool(nomads) or bool(elsewhere) or (drive / NOMAD_FOLDER / "start-nomad.sh").is_file()
    if has_nomad:
        script = out / NOMAD_FINDER
        script.write_bytes(START_NOMAD_SCRIPT.encode("utf-8"))
        try:
            os.chmod(script, 0o755)
        except OSError:
            pass
    api.say(f"Start menu for {drive} written to {out / 'ventoy.json'} (the drive itself was not changed).")
    if live:
        api.say(f"  Live mode: {live} - \"{LIVE_ALIAS if persistence else LIVE_ALIAS_NOTHING_KEPT}\"")
    for image in nomads:
        if not any(image in note for note in notes):
            api.say(f"  NOMAD: {image} - \"{NOMAD_ALIAS}\"")
    if not live and not nomads:
        api.say("  This drive holds no live image yet, so the start menu stays as it is. Add one to the saved "
                "master with live-addon, or put a Fedora Live image in the drive's ISO/live/ folder.")
    for note in notes:
        api.say("  Note: " + note)
    for image in elsewhere:
        api.say(f"  Note: NOMAD's live system {image} is on another part of the drive ({args.nomad_root}). "
                "The start menu can only start files on its own part. Copy that file into this drive's ISO/live/ "
                "folder, then run this again; the live system then finds NOMAD with START-NOMAD.sh.")
    if has_nomad:
        api.say(f"  {NOMAD_FINDER} written to {out}: put it at the top of the drive. In the live system it finds "
                "NOMAD on any plugged-in drive and starts it.")
    return 0


# ---- after a verified Portable tools copy (contract C17 after_copy) ----------------------------------------------

def _drive_live_image(target_root, manifest):
    files = (manifest.get("portable") or {}).get("files") or []
    images = sorted(entry["path"] for entry in files if isinstance(entry, dict) and is_live_image(entry.get("path", "")))
    images = [path for path in images if (Path(target_root) / path).is_file()]
    return images[-1] if images else None


def _persistence_size(target_root):
    try:
        record = json.loads((Path(target_root) / LIVE_RECORD).read_bytes())
        size = int(record.get("persistence_bytes", DEFAULT_PERSISTENCE))
    except (OSError, ValueError, TypeError, AttributeError):
        return DEFAULT_PERSISTENCE
    return size if MIN_PERSISTENCE <= size <= MAX_PERSISTENCE else DEFAULT_PERSISTENCE


def _mkfs_command(args):
    mock = _mock_value("SL_USBC_MOCK_LIVE_MKFS", args)
    if mock:
        return [sys.executable, mock] if mock.endswith(".py") else [mock]
    for candidate in (shutil.which("mkfs.ext4"), "/usr/sbin/mkfs.ext4", "/sbin/mkfs.ext4"):
        if candidate and os.path.isfile(candidate):
            return [candidate]
    return None


def _room(target_root, needed, args, api):
    mock = _mock_value("SL_USBC_MOCK_LIVE_FREE_BYTES", args)
    if mock is not None:
        return int(mock) >= needed
    return api.free_space_ok(target_root, needed)


def is_ext_with_label(path, label):
    try:
        with open(path, "rb") as handle:
            handle.seek(EXT_MAGIC_OFFSET)
            magic = handle.read(2)
            handle.seek(EXT_LABEL_OFFSET)
            name = handle.read(16)
    except OSError:
        return False
    return magic == b"\x53\xef" and name.rstrip(b"\x00") == label.encode("ascii")


def make_persistence(target_root, size, args, api):
    """Make this drive's saved-changes file. Returns True when it is there (made now or already there)."""
    final = Path(target_root) / PERSISTENCE_PATH
    if final.exists() or final.is_symlink():
        api.say(f"Live mode: this drive already has its space for your files ({PERSISTENCE_PATH}); it was kept "
                "exactly as it is.")
        api.say(PERSISTENCE_NOT_LOCKED_NOTE)
        return final.is_file() and not final.is_symlink()
    if not _room(target_root, size + PERSISTENCE_ROOM, args, api):
        api.say(f"Live mode: this drive has no room for the {human(size)} space that keeps your files, so "
                "\"Try Secure Linux without installing\" forgets changes when the computer is switched off. "
                "Everything else on this drive is ready.")
        return False
    command = _mkfs_command(args)
    if not command:
        api.say("Live mode: this computer cannot make the space that keeps your files (mkfs.ext4, part of "
                "e2fsprogs, is not installed), so live mode on this drive forgets changes when switched off.")
        return False
    final.parent.mkdir(parents=True, exist_ok=True)
    part = final.with_name("." + final.name + ".part")
    try:
        if part.exists() or part.is_symlink():
            part.unlink()                  # an unfinished file from a stopped copy: never used, never booted
        with open(part, "xb") as handle:
            handle.truncate(size)
            handle.flush()
            os.fsync(handle.fileno())
        result = subprocess.run(command + ["-q", "-F", "-t", PERSISTENCE_FS, "-L", PERSISTENCE_LABEL, str(part)],
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=1800)
        if result.returncode != 0 or not is_ext_with_label(part, PERSISTENCE_LABEL):
            raise OSError("the file system could not be made in it")
        os.replace(part, final)
    except (OSError, subprocess.TimeoutExpired) as exc:
        try:
            part.unlink()
        except OSError:
            pass
        api.say(f"Live mode: the space that keeps your files could not be made on this drive ({exc}). Live mode "
                "forgets changes when switched off. Everything else on this drive is ready.")
        return False
    api.say(f"Live mode: made this drive's own {human(size)} space for your files ({PERSISTENCE_PATH}).")
    api.say(PERSISTENCE_NOT_LOCKED_NOTE)
    return True


def _refresh_drive_list(target_root, menu_raw, api, engine):
    """The drive's file list and passport (C3) were written before this add-on ran: bring the menu's hash up to date."""
    root = Path(target_root)
    listing_path = root / engine.drive_files_list
    passport_path = root / engine.passport_json
    if not listing_path.is_file() or not passport_path.is_file():
        return
    listing = json.loads(listing_path.read_bytes())
    menu = {"sha256": engine.sha256_bytes(menu_raw), "size": len(menu_raw)}
    for group in ("per_drive", "shared"):
        if "ventoy/ventoy.json" in listing.get(group, {}):
            listing[group]["ventoy/ventoy.json"] = menu
    listing_raw = engine.json_data(listing)
    engine.write_checked_file(listing_path, listing_raw)
    passport = json.loads(passport_path.read_bytes())
    passport["list_sha256"] = engine.sha256_bytes(listing_raw)
    engine.write_checked_file(passport_path, engine.json_data(passport))
    engine.write_checked_file(root / engine.passport_txt, engine.passport_text(passport).encode("utf-8"))


def after_copy(target_root, manifest, args, api):
    """After a verified copy: live mode on this drive when the saved master holds the live image. Otherwise silent."""
    root = Path(target_root)
    live = _drive_live_image(root, manifest)
    nomads = find_nomad_images(root)
    if not live and not nomads:
        return
    engine = _engine(api)
    menu_path = root / "ventoy" / "ventoy.json"
    try:
        config = read_menu(menu_path)
    except (OSError, ValueError):
        api.say("Live mode: this drive's start menu (ventoy/ventoy.json) could not be read, so live mode was not "
                "added. The drive itself is verified and works as before.")
        return
    persistence = None
    if live and make_persistence(root, _persistence_size(root), args, api):
        persistence = PERSISTENCE_PATH
    new, notes = plan_menu(config, "/" + live if live else None, persistence, nomads)
    raw = menu_bytes(new)
    if raw != menu_path.read_bytes():
        engine.write_checked_file(menu_path, raw)
        _refresh_drive_list(root, raw, api, engine)
    if nomads:
        engine.write_checked_file(root / NOMAD_FINDER, START_NOMAD_SCRIPT.encode("utf-8"))
    for note in notes:
        api.say("Live mode note: " + note)
    if live:
        api.say(f"LIVE MODE ON THIS DRIVE: the start menu has \"{LIVE_ALIAS if persistence else LIVE_ALIAS_NOTHING_KEPT}\".")


def refuse_private_packets(data: bytes, what: str) -> bytes:
    """Walk every OpenPGP packet of a binary key file. A secret-key or secret-subkey packet (tags 5 and 7) is refused,
    in binary files too, and so is anything that is not a whole run of packets. Copied from bigfile_fetch (Fz3, C6 F4)
    and kept at the end of this file so line numbers named elsewhere move as little as possible."""
    position, end = 0, len(data)
    while position < end:
        header = data[position]
        if not header & 0x80:
            raise ValueError(f"{what} is not a public key file")
        position += 1
        if header & 0x40:                                   # new packet format
            tag = header & 0x3F
            if tag in (5, 7):
                raise ValueError(f"{what} holds a private key; only public keys are used")
            while True:
                if position >= end:
                    raise ValueError(f"{what} is not a public key file")
                first = data[position]
                partial = False
                if first < 192:
                    length, position = first, position + 1
                elif first < 224:
                    if position + 2 > end:
                        raise ValueError(f"{what} is not a public key file")
                    length, position = ((first - 192) << 8) + data[position + 1] + 192, position + 2
                elif first == 255:
                    if position + 5 > end:
                        raise ValueError(f"{what} is not a public key file")
                    length, position = int.from_bytes(data[position + 1:position + 5], "big"), position + 5
                else:
                    length, position, partial = 1 << (first & 0x1F), position + 1, True
                position += length
                if position > end:
                    raise ValueError(f"{what} is not a public key file")
                if not partial:
                    break
        else:                                               # old packet format
            tag, kind = (header >> 2) & 0x0F, header & 0x03
            if tag in (5, 7):
                raise ValueError(f"{what} holds a private key; only public keys are used")
            if kind == 3:                                   # "indeterminate length" never appears in a key file
                raise ValueError(f"{what} is not a public key file")
            size = (1, 2, 4)[kind]
            if position + size > end:
                raise ValueError(f"{what} is not a public key file")
            length = int.from_bytes(data[position:position + size], "big")
            position += size + length
            if position > end:
                raise ValueError(f"{what} is not a public key file")
    return data
