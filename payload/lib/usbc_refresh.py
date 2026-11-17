"""Drive-builder add-on (contracts C9, C17): bring the big files of the saved master up to date, only when they changed.

  secure-linux-usb-creator refresh-master --store S [--only fedora,rescue,ventoy,offline,flipper,netboot]
                                          [--max-download-mb N] [--yes] [--fedora-version N] [--keys FILE ...]

What it looks at (each part is optional with --only; one part that fails never stops the others):
  fedora   the Fedora install image (ISO/Fedora-...-netinst-...iso), checked against Fedora's signed CHECKSUM file
           with Fedora keys this computer already trusts. It stays on the saved master's own Fedora version unless
           --fedora-version names another one.
  rescue   the rescue tools the saved master already has under ISO/tools/: SystemRescue, Clonezilla and Memtest86+
           (64-bit and 32-bit). A newer version replaces the older one; the start menu (ventoy/ventoy.json) is changed
           to match. Tools the saved master does not have are never added.
  ventoy   Ventoy's Linux package, checked against Ventoy's own checksum list, kept next to the saved master in
           <store>/ventoy-package/ (it is the program that prepares a drive; it is not copied onto drives).
  offline  the files of the offline app collection's approved plan that are missing or damaged in the saved master.
  flipper  the Flipper files and the network-install files: secure-linux-kit-update check|apply --set flipper|netboot
  netboot  checks them against the published release list (signed, once release signing is set up) in a working
           folder next to the saved master (<store>/.refresh-sets/); they go to linux-setup/flipper-sd-card/ and
           linux-setup/network-install/ on drives made from the saved master.

How it works:
  - Size first: every checksum list is read and the download size is shown BEFORE one byte of a big file is
    fetched. Without --yes nothing is downloaded and nothing changes: it shows what would change (and asks, when a
    person is at the keyboard). The Flipper and network-install files are only compared then (kit-update check).
  - Free space is checked first, through the drive builder's own check (a full copy of the saved master is counted
    when its file system cannot share files). --max-download-mb is one hard limit for everything the refresh
    downloads: the Flipper and network-install files fetched first count too.
  - Only when changed: a file whose SHA-256 already matches is never downloaded again. Downloads continue where they
    stopped (the half-finished parts are kept in <store>/.refresh-downloads/), also after a restart.
  - The result is ONE new saved master that shares (hard links) every unchanged file with the current one. The
    current one is kept, so master-undo goes back to it. Nothing is ever removed here: master-prune (P10c) is the
    only command that removes older saved masters, and it always keeps the current one and the one before it.
  - It holds the store lock (exclusive) for the whole run, so no drive is made from a saved master that is changing.
    After a new saved master is made (and the lock is let go), master-prune (P10c) runs once: it keeps the current
    saved master and the one before it, and removes older ones only after the current one passed its full check.
Prints "MASTER REFRESHED: <generation>" or "MASTER ALREADY CURRENT". Exit 0 when every chosen part is up to date,
1 when a part could not be brought up to date (said in plain words), 2 when the current saved master failed its
check, 75 when the saved master is busy with another job.
"""

import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import types
import urllib.parse
# dataclasses, datetime, glob, uuid and zipfile are imported where they are used: the drive builder loads every
# add-on at each start, so loading this one must stay cheap for the commands that never use it.

COMMANDS = ("refresh-master",)
NO_DEVICE_COMMANDS = COMMANDS            # the saved master's folder only, never a drive
PARTS = ("fedora", "rescue", "ventoy", "offline", "flipper", "netboot")

DOWNLOADS = ".refresh-downloads"         # in the store, outside generations: half-finished parts survive restarts
SETS_FOLDER = ".refresh-sets"            # in the store: the folders secure-linux-kit-update keeps up to date
VENTOY_FOLDER = "ventoy-package"         # in the store: the checked Ventoy package (not part of any drive)
VENTOY_RECORD = "current.json"
MASTER_ROOM = 64 * 1024 ** 2             # always left free next to the saved master
MIN_FREE = 16 * 1024 ** 2                # needed before anything at all is looked at
MIB = 1024 * 1024
MEMTEST_ENTRY = "memtest.iso"            # the image inside Memtest86+'s .iso.zip (as make-usb.ps1 uses it)
MAX_MEMTEST = 64 * 1024 ** 2
SET_DEST = {"flipper": "linux-setup/flipper-sd-card/", "netboot": "linux-setup/network-install/"}
SET_LABEL = {"flipper": "Flipper files", "netboot": "network-install files"}
OFFLINE_ROOT = "linux-setup/offline/app-bundles/"
OFFLINE_PLAN_SCHEMA = "secure-linux.offline-plan.v1"     # offline_bundle.py PLAN_SCHEMA
MENU = "ventoy/ventoy.json"
SYSRESCUE_CONFIGS = "ventoy/sysrescue/"

FEDORA_KEY_GLOB = "/etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-*-primary"
FEDORA_FOLDER = "https://dl.fedoraproject.org/pub/fedora/linux/releases/{version}/Everything/x86_64/iso/"
SYSRESCUE_PAGE = "https://www.system-rescue.org/Download/"
SYSRESCUE_FILES = "https://fastly-cdn.system-rescue.org/releases/{version}/"
CLONEZILLA_SUMS = "https://clonezilla.org/downloads/stable/data/CHECKSUMS.TXT"
CLONEZILLA_FILE = "https://sourceforge.net/projects/clonezilla/files/clonezilla_live_stable/{version}/{name}/download"
MEMTEST_LATEST = "https://api.github.com/repos/memtest86plus/memtest86plus/releases/latest"
MEMTEST_FILES = "https://memtest.org/download/v{version}/"
VENTOY_LATEST = "https://api.github.com/repos/ventoy/Ventoy/releases/latest"
VENTOY_FILES = "https://github.com/ventoy/Ventoy/releases/download/v{version}/"

FEDORA_RE = re.compile(r"^ISO/(Fedora-[A-Za-z]+-netinst-x86_64-([0-9]{2,3})-[0-9][0-9.]*\.iso)$")
VERSION = r"[0-9]+(?:\.[0-9]+)*"
TOOLS = {
    # id: (name shown, file name pattern in the saved master (group 1 = version), file name for a version)
    "systemrescue": ("SystemRescue", re.compile(rf"^ISO/tools/systemrescue-({VERSION})-amd64\.iso$"),
                     "systemrescue-{version}-amd64.iso"),
    "clonezilla": ("Clonezilla", re.compile(rf"^ISO/tools/clonezilla-live-({VERSION}-[0-9]+)-amd64\.iso$"),
                   "clonezilla-live-{version}-amd64.iso"),
    "memtest": ("Memtest86+", re.compile(rf"^ISO/tools/memtest86plus-({VERSION})\.iso$"),
                "memtest86plus-{version}.iso"),
    "memtest-i586": ("Memtest86+ 32-bit", re.compile(rf"^ISO/tools/memtest86plus-({VERSION})-i586\.iso$"),
                     "memtest86plus-{version}-i586.iso"),
}
MEMTEST_ZIP = {"memtest": "mt86plus_{version}_x86_64.iso.zip", "memtest-i586": "mt86plus_{version}_i586.iso.zip"}

NEEDS_ADMIN = ("the saved master belongs to the administrator. Run this again as administrator, for example: "
               "sudo secure-linux-usb-creator refresh-master --store {store}. Nothing was changed.")


class PartFailed(Exception):
    """One part could not be brought up to date; the others go on. The text is shown as it is."""


class Want:
    """A file the saved master should hold, from a checked list."""

    def __init__(self, part, master_path, expected, url, unpack=""):
        self.part = part
        self.master_path = master_path    # where it goes in the saved master (payload-relative), "" = Ventoy package
        self.expected = expected          # bigfile_fetch.Expected of the download (relative = place in DOWNLOADS)
        self.url = url
        self.unpack = unpack              # "memtest": the downloaded .zip holds the image (MEMTEST_ENTRY)
        self.unpacked = ()                # after unpacking: (image file, sha256, size)


class Part:
    def __init__(self, name):
        self.name = name
        self.wants = []                   # Want: files to fetch (unchanged ones are not here)
        self.removes = []                 # saved-master paths that go away
        self.renames = {}                 # "/old image" -> ("/new image", old version, new version)
        self.drop_rescue_configs = False
        self.copies = {}                  # saved-master path -> (file, sha256, size) (sets)
        self.lines = []                   # plain lines for the person
        self.changed = False
        self.pending = False              # a set that differs: kit-update apply runs after the person agreed


def relocated(expected, relative):
    """The same checked file, stored at `relative` in the download folder."""
    import dataclasses
    return dataclasses.replace(expected, relative=relative)


# ---- registration (contract C17) ---------------------------------------------------------------------------------

def register(subparsers):
    refresh = subparsers.add_parser(
        "refresh-master",
        help="bring the saved master's big files (Fedora image, rescue tools, Ventoy, offline apps, Flipper and "
             "network-install files) up to date, downloading only what changed; shows the size first",
    )
    refresh.add_argument("--store", required=True, help="master store containing current and generations")
    refresh.add_argument("--only", help="comma list of parts: " + ",".join(PARTS) + " (default: all)")
    refresh.add_argument("--max-download-mb", type=float,
                         help="never download more than this many MB (nothing is downloaded when more is needed)")
    refresh.add_argument("--yes", action="store_true",
                         help="download and change the saved master without asking (without it: show what would "
                              "change, and ask when you are at the keyboard)")
    refresh.add_argument("--fedora-version", help="move the Fedora install image to this Fedora release (a number)")
    refresh.add_argument("--keys", action="append", default=[],
                         help="Fedora's own signing key file (default: the Fedora keys this computer already "
                              "trusts, " + FEDORA_KEY_GLOB + "); can be given more than once")
    return list(COMMANDS)


def run(args, api):
    store = os.path.abspath(args.store)
    parts = chosen_parts(args.only, api)
    if args.max_download_mb is not None and not args.max_download_mb >= 0:
        raise api.CreatorError("--max-download-mb must be 0 or more. Nothing was changed.")
    if args.fedora_version is not None and not re.fullmatch(r"[0-9]{2,3}", str(args.fedora_version)):
        raise api.CreatorError("--fedora-version is a Fedora release number, such as 45. Nothing was changed.")
    engine = _engine(api)
    fetch = _fetch_module(api)
    _check_store(store, api)
    if not api.free_space_ok(store, MIN_FREE):
        raise api.CreatorError("there is not enough free space next to the saved master to do this safely (at "
                               "least 16 MB is needed). Free up some space, then try again. Nothing was changed.")
    try:
        with api.store_lock(store, True):
            code, new_id = refresh(store, parts, args, api, engine, fetch)
    except PermissionError as exc:
        raise api.CreatorError(NEEDS_ADMIN.format(store=store)) from exc
    if new_id:
        prune_after(store, api)
    return code


def prune_after(store, api):
    """P10c's own master-prune, run once after the lock is let go (never this add-on's own removal code)."""
    creator = (getattr(api.load_master, "__globals__", None) or {}).get("__file__")
    if not creator or not Path(creator).is_file():
        api.say("Note: older saved masters were kept (the drive builder could not be found to tidy them).")
        return
    try:
        done = subprocess.run([sys.executable, str(creator), "master-prune", "--store", store], capture_output=True,
                              text=True, timeout=7200, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as exc:
        api.say(f"Note: older saved masters were kept this time ({type(exc).__name__}).")
        return
    for line in done.stdout.splitlines():
        if line.strip():
            api.say(line)
    if done.returncode != 0:
        api.say("Note: older saved masters were kept this time. master-prune can be run again later.")


def chosen_parts(text, api):
    if not text:
        return list(PARTS)
    names = [name.strip().lower() for name in str(text).split(",") if name.strip()]
    unknown = [name for name in names if name not in PARTS]
    if unknown or not names:
        raise api.CreatorError(f"--only knows these parts: {', '.join(PARTS)} (not {', '.join(unknown) or 'empty'}). "
                               "Nothing was changed.")
    return [name for name in PARTS if name in names]


# ---- the drive builder's own helpers --------------------------------------------------------------------------------

def _engine(api):
    """The drive builder's own code that makes and checks every saved master (the same as usbc_live uses)."""
    space = getattr(api.load_master, "__globals__", None) or {}
    wanted = ("read_manifest", "validate_manifest", "atomic_write", "atomic_replace", "json_data", "sha256_bytes",
              "hash_file", "utc_now", "fsync_directory", "writable_tree_for_removal", "template_record")
    missing = [name for name in wanted if not callable(space.get(name))]
    if missing:
        raise api.CreatorError("this drive builder is missing parts this add-on needs. Update Secure Linux, "
                               "then try again. Nothing was changed.")
    engine = types.SimpleNamespace(**{name: space[name] for name in wanted})
    status = space.get("write_master_status")
    engine.write_master_status = status if callable(status) else None
    engine.files_only = space.get("FILES_ONLY_KIND", "files-only")
    engine.schema = space.get("SCHEMA", 1)
    engine.app = space.get("APP", api.app)
    engine.version = space.get("VERSION", api.version)
    return engine


def _fetch_module(api):
    here = Path(__file__).resolve().parent
    for folder in (here, Path("/usr/local/lib/secure-linux/lib")):
        if (folder / "bigfile_fetch.py").is_file() and str(folder) not in sys.path:
            sys.path.insert(0, str(folder))
    try:
        import bigfile_fetch
    except ImportError as exc:
        raise api.CreatorError("the big-file download part (bigfile_fetch.py) is missing. Update Secure Linux, then "
                               "try again. Nothing was changed.") from exc
    return bigfile_fetch


def _verification_error(api):
    return getattr(api, "VerificationError", api.CreatorError)


def _check_store(store, api):
    try:
        names = os.listdir(store)
    except FileNotFoundError as exc:
        raise api.CreatorError(f"there is no saved master in {store}. Nothing was changed.") from exc
    except PermissionError as exc:
        raise api.CreatorError(NEEDS_ADMIN.format(store=store)) from exc
    except OSError as exc:
        raise api.CreatorError(f"the saved master folder {store} cannot be read. Nothing was changed.") from exc
    if "generations" not in names or "current" not in names:
        raise api.CreatorError(f"there is no saved master in {store} yet. Nothing was changed.")


def _testing():
    return os.environ.get("SL_USBC_REFRESH_TEST") == "1"


def url(real):
    """The real address; in tests only (SL_USBC_REFRESH_TEST=1) the same path on a test server on this computer."""
    base = os.environ.get("SL_USBC_REFRESH_TEST_BASE", "") if _testing() else ""
    if not base:
        return real
    parts = urllib.parse.urlsplit(real)
    return base.rstrip("/") + "/" + parts.hostname + parts.path


def _version_key(text):
    return tuple(int(piece) for piece in re.split(r"[.-]", text) if piece.isdigit())


def human(number):
    value = float(number or 0)
    for unit in ("bytes", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            return f"{int(value)} bytes" if unit == "bytes" else f"{value:.1f} {unit}"
        value /= 1024
    return f"{number} bytes"


# ---- checksum lists in their real published forms (fixtures: tests/bigfiles/fixtures/) -----------------------------

def clonezilla_sha256_section(text):
    """Clonezilla's CHECKSUMS.TXT holds MD5, SHA-1, SHA-256, SHA-512, BLAKE2 and BLAKE3 sections ("### SHA256SUMS:").
    BLAKE3 values are 64 hex characters too, so only the SHA-256 section may be read."""
    sections = re.split(r"(?m)^###\s*", text.replace("\r\n", "\n"))
    found = [section for section in sections if re.match(r"SHA256SUMS:?\s*\n", section)]
    if len(found) != 1:
        raise PartFailed("Clonezilla's checksum list has no single SHA-256 section, so it was not used")
    return found[0].split("\n", 1)[1]


def memtest_sums_text(text, version):
    """Memtest86+'s sha256sum.txt names each file with its folder ("HASH  v9.00/mt86plus_9.00_x86_64.iso.zip").
    Only lines for that exact version folder are kept, without the folder, so the names are plain file names."""
    lines = []
    prefix = f"v{version}/"
    for line in text.replace("\r\n", "\n").split("\n"):
        match = re.fullmatch(r"([0-9a-fA-F]{64}) ([ *])(.+)", line.strip())
        if match and match.group(3).startswith(prefix):
            lines.append(f"{match.group(1)} {match.group(2)}{match.group(3)[len(prefix):]}")
    return "\n".join(lines) + "\n"


def newest_systemrescue(page):
    versions = set(re.findall(rf"systemrescue-({VERSION})-amd64\.iso", page))
    if not versions:
        raise PartFailed("SystemRescue's download page names no amd64 image, so SystemRescue was not checked")
    return max(versions, key=_version_key)


def index_names(html):
    names = []
    for href in re.findall(r'href="([^"?#]+)"', html):
        name = urllib.parse.unquote(href.rstrip("/").rsplit("/", 1)[-1])
        if name and name not in names:
            names.append(name)
    return names


def github_latest_version(fetcher, address, what):
    try:
        data = json.loads(fetcher.get_small(url(address), 1024 * 1024).decode("utf-8"))
        tag = data.get("tag_name") if isinstance(data, dict) else None
    except (ValueError, UnicodeDecodeError) as exc:
        raise PartFailed(f"{what}'s release page could not be read, so it was not checked") from exc
    if not isinstance(tag, str) or not re.fullmatch(rf"v?{VERSION}", tag):
        raise PartFailed(f"{what}'s newest release has a name this version does not understand ({tag!r})")
    return tag[1:] if tag.startswith("v") else tag


# ---- the refresh ----------------------------------------------------------------------------------------------------

def refresh(store, parts, args, api, engine, fetch):
    _, old_id, old_root, manifest = engine.read_manifest(store)
    portable = manifest.get("portable")
    if not portable:
        raise api.CreatorError("this saved master holds no file tree; save a new master from a finished drive first. "
                               "Nothing was changed.")
    entries = {entry["path"]: entry for entry in portable["files"]}
    downloads = Path(store) / DOWNLOADS
    fetcher = fetch.Fetcher(say=api.say, allow_http_hosts=("127.0.0.1",) if _testing() else ())
    api.say(f"Checking the saved master {old_id} against the published lists ({', '.join(parts)})...")
    results, failed = [], {}
    limit = None if args.max_download_mb is None else int(args.max_download_mb * MIB)
    spent = {}                          # label -> bytes the Flipper and network-install files brought in this run
    for name in parts:
        try:
            if name in SET_DEST:
                results.append(set_part(name, entries, store, args, api, apply=args.yes,
                                        max_mb=_left_mb(args, limit, spent), spent=spent))
            else:
                results.append(LOOKUPS[name](name, entries, old_root, args, fetcher, fetch, store))
        except (PartFailed, fetch.FetchError, OSError, ValueError) as exc:
            failed[name] = str(exc)
    jobs, owner = [], {}
    for part in list(results):
        if not part.wants:
            continue
        try:
            planned = fetcher.plan([(want.expected, want.url) for want in part.wants], downloads)
        except fetch.FetchError as exc:
            failed[part.name] = str(exc)
            results.remove(part)
            continue
        for job in planned.jobs:
            owner[id(job)] = part.name
        jobs.extend(planned.jobs)
    plan = fetch.Plan(downloads, jobs) if jobs else None
    for part in results:
        for line in part.lines:
            api.say(line)
    for name, reason in failed.items():
        api.say(f"NOT CHECKED: {name}: {reason}")
    changed = [part for part in results if part.changed]
    if not changed:
        return finish(None, old_id, [], [], failed, manifest, engine, api), None
    if plan is not None:
        for line in plan.describe():
            api.say(line)
        api.say("Every file is checked against its list before it is used.")
    fetching = plan is not None and bool(plan.to_fetch)
    allowance = None if limit is None else max(limit - sum(spent.values()), 0)
    copy_bytes = 0
    master_changes = [part for part in changed if part.name != "ventoy"]
    if master_changes and not _links_work(downloads):
        copy_bytes = _full_copy_bytes(entries, master_changes)
        api.say(f"This folder's file system cannot share files between saved masters, so the new saved master is a "
                f"full copy ({human(copy_bytes)}).")
    if fetching or copy_bytes:
        need = MASTER_ROOM + copy_bytes + ((plan.space_bytes + _unpack_room(plan, owner)) if fetching else 0)
        what = " and ".join(item for item in ("the downloads" if fetching else "",
                                              "a full copy of the saved master" if copy_bytes else "") if item)
        if not api.free_space_ok(store, need):
            raise api.CreatorError(f"there is not enough free space next to the saved master for {what} "
                                   f"({human(need)} is needed). Free up some space, then try again. "
                                   f"{_nothing_text(spent)}")
    if fetching and allowance is not None:
        if plan.unknown_sizes:
            raise api.CreatorError(f"the size of {plan.unknown_sizes[0].expected.name} is not known before the "
                                   "download, so it cannot be kept under your limit. "
                                   + ("The big files were not downloaded." if spent else "Nothing was downloaded."))
        if plan.download_bytes > allowance:
            left = f" ({human(allowance)} was left after the {_labels(spent)} came in)" if spent else ""
            raise api.CreatorError(f"this needs {human(plan.download_bytes)} of downloads, more than the "
                                   f"{args.max_download_mb:g} MB you allowed{left}. {_nothing_text(spent)}")
    if not agreed(args, plan, changed):
        api.say("")
        api.say("REFRESH NOT STARTED: nothing was downloaded and the saved master was not changed. "
                "To bring it up to date, run again with --yes.")
        return (1 if failed else 0), None
    downloaded = 0
    if fetching:
        try:
            report = fetcher.run(plan, allowance)
        except fetch.FetchError as exc:
            raise api.CreatorError(str(exc)) from exc
        downloaded = report.downloaded_bytes or 0
        for job, reason in report.failed:
            failed.setdefault(owner.get(id(job), "download"), reason)
    for index, part in enumerate(results):
        if part.pending and part.name not in failed:
            try:
                left = None if limit is None else limit - downloaded
                results[index] = set_part(part.name, entries, store, args, api, apply=True,
                                          max_mb=_left_mb(args, left, spent), spent=spent)
            except PartFailed as exc:
                failed[part.name] = str(exc)
    results = [part for part in results if part.name not in failed]
    for part in results:
        try:
            unpack_part(part, downloads, fetch)
        except PartFailed as exc:
            failed[part.name] = str(exc)
    results = [part for part in results if part.name not in failed]
    ventoy = [part for part in results if part.name == "ventoy" and part.changed]
    for part in ventoy:
        try:
            keep_ventoy_package(part, store, downloads, engine)
        except (PartFailed, OSError) as exc:
            failed["ventoy"] = str(exc)
    master_parts = [part for part in results if part.changed and part.name != "ventoy"]
    menu = None
    if master_parts:
        try:
            menu = new_menu(old_root, entries, master_parts)
        except PartFailed as exc:
            for part in master_parts:
                if part.renames:
                    failed[part.name] = str(exc)
            master_parts = [part for part in master_parts if not part.renames]
            menu = None
    new_id = publish(store, old_id, old_root, manifest, master_parts, menu, downloads, api, engine) \
        if master_parts else None
    tidy_downloads(downloads, plan, master_parts + [part for part in ventoy if "ventoy" not in failed], failed)
    return finish(new_id, old_id, master_parts, [part for part in ventoy if "ventoy" not in failed], failed,
                  manifest, engine, api), new_id


def finish(new_id, old_id, master_parts, ventoy, failed, manifest, engine, api):
    api.say("")
    if new_id:
        api.say(f"MASTER REFRESHED: {new_id}")
        api.say(f"Brought up to date: {', '.join(part.name for part in master_parts)}. Every other file is shared "
                f"with the previous saved master ({old_id}), which is kept: master-undo goes back to it, and "
                "master-prune removes older ones (it always keeps the current one and the one before it).")
        if any(part.drop_rescue_configs for part in master_parts):
            api.say("Note: SystemRescue now starts with its own menu. To open the Secure Linux rescue toolbox in it, "
                    "type the two lines in SecureLinux-Rescue/README.txt.")
        if manifest.get("kind") != engine.files_only:
            api.say("Note: the new saved master holds the drive's files only, so it makes Portable tools copies. "
                    f"Exact whole-drive clones can still be made from the previous saved master ({old_id}): go back "
                    "to it with master-undo. After the next refresh it may be removed (master-prune keeps only the "
                    "current saved master and the one before it), so make any exact clones before then.")
        api.say("Drives made earlier are not changed by this. New drives made from this saved master get the new "
                "files.")
        if any(part.renames for part in master_parts):
            api.say("A drive made earlier keeps its own start menu, so it still shows the older images until the "
                    "drive is made again from this saved master.")
    elif failed:
        api.say(f"MASTER NOT CHANGED: {old_id}")
    else:
        api.say(f"MASTER ALREADY CURRENT: {old_id}")
    for part in ventoy:
        api.say(part.lines[-1])
    for name, reason in failed.items():
        api.say(f"NOT REFRESHED: {name}: {reason}")
    return 1 if failed else 0


def agreed(args, plan, changed):
    if args.yes:
        return True
    # Only a person at a terminal is asked (a window or a script that runs this sees the sizes and passes --yes).
    # Both ends are checked: on some systems the "nothing" input device also counts as a terminal.
    if not (sys.stdin and sys.stdin.isatty() and sys.stdout and sys.stdout.isatty()):
        return False
    size = human(plan.download_bytes) if plan is not None and plan.to_fetch else "nothing more"
    names = ", ".join(part.name for part in changed)
    try:
        answer = input(f"Download {size} and update the saved master ({names}) now? "
                       "Type yes, or press Enter to skip: ")
    except EOFError:
        return False
    return answer.strip().lower() in ("y", "yes")


def _unpack_room(plan, owner):
    return sum(MAX_MEMTEST for job in plan.to_fetch if job.expected.relative.startswith("rescue/mt86plus_"))


def _labels(spent):
    return " and the ".join(sorted(spent))


def _nothing_text(spent):
    if not spent:
        return "Nothing was downloaded and nothing was changed."
    return (f"The big files were not downloaded and the saved master was not changed (the {_labels(spent)} kept "
            "next to it were brought up to date).")


def _left_mb(args, limit, spent):
    """What secure-linux-kit-update may still download (--max-download-mb), as text; None when there is no limit.
    The person's own value is passed as given until something was downloaded; after that only what is left
    (rounded down, so it is never more)."""
    if limit is None or args.max_download_mb is None:
        return None
    used = sum(spent.values())
    if used <= 0 and limit >= int(args.max_download_mb * MIB):
        return f"{args.max_download_mb:g}"
    left = max(limit - used, 0) / MIB
    return f"{math.floor(left * 1_000_000) / 1_000_000:.6f}".rstrip("0").rstrip(".") or "0"


def _links_work(downloads):
    """True when the saved master's file system can share one file between two names (hard links): then the new
    saved master costs only the new files. Tried with a small empty file in the download folder."""
    import uuid
    if os.path.islink(downloads):        # never written through a link (the download step refuses a linked folder too)
        return True
    downloads.mkdir(mode=0o700, exist_ok=True)
    first = downloads / f".link-test-{uuid.uuid4().hex}"
    second = first.with_name(first.name + "-2")
    try:
        with open(first, "xb"):
            pass
        try:
            os.link(first, second)
        except OSError:
            return False
        return True
    finally:
        _remove(second)
        _remove(first)


def _full_copy_bytes(entries, parts):
    """The space a new saved master takes when nothing can be shared: every file it keeps, plus the new ones."""
    replaced = {path for part in parts for path in part.removes}
    replaced |= {want.master_path for part in parts for want in part.wants}
    replaced |= {path for part in parts for path in part.copies}
    if any(part.drop_rescue_configs for part in parts):
        replaced |= {path for path in entries if path.startswith(SYSRESCUE_CONFIGS)}
    kept = sum(int(entry.get("size") or 0) for path, entry in entries.items() if path not in replaced)
    new = sum(MAX_MEMTEST if want.unpack else int(want.expected.size or 0) for part in parts for want in part.wants)
    new += sum(int(size or 0) for part in parts for (_, _, size) in part.copies.values())
    return kept + new


def _set_files(folder):
    """{relative path: (sha256, size)} of the files in a set's working folder (secure-linux-kit-update's own
    record left out); used to count what an apply brought in."""
    found = {}
    if not folder.is_dir() or folder.is_symlink():
        return found
    for base, directories, names in os.walk(folder):
        if Path(base) == folder:
            directories[:] = [name for name in directories if not name.startswith(".kit-update")]
        for name in names:
            path = Path(base) / name
            relative = path.relative_to(folder).as_posix()
            if relative.startswith(".kit-update") or path.is_symlink() or not path.is_file():
                continue
            digest, size = hashlib.sha256(), 0
            with open(path, "rb") as handle:
                for block in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(block)
                    size += len(block)
            found[relative] = (digest.hexdigest(), size)
    return found


# ---- one part each ----------------------------------------------------------------------------------------------------

def fedora_part(name, entries, old_root, args, fetcher, fetch, store):
    part = Part(name)
    have = [(path, FEDORA_RE.fullmatch(path)) for path in sorted(entries)]
    have = [(path, match) for path, match in have if match]
    if not have:
        part.lines.append("Fedora install image: this saved master has none, so there is nothing to check.")
        return part
    path, match = have[-1]
    version = str(args.fedora_version or match.group(2))
    import glob
    keys = [Path(key).expanduser() for key in args.keys] or [Path(key) for key in sorted(glob.glob(FEDORA_KEY_GLOB))]
    if not keys:
        raise PartFailed("Fedora's signing keys are not on this computer (package fedora-gpg-keys), so Fedora's "
                         "checksum list cannot be checked. Use --keys with Fedora's own key file")
    folder = url(FEDORA_FOLDER.format(version=version))
    listing = fetcher.get_small(folder).decode("utf-8", "replace")
    sums = [item for item in index_names(listing) if item.endswith("-CHECKSUM")]
    if len(sums) != 1:
        raise PartFailed(f"Fedora {version}'s download folder does not hold exactly one CHECKSUM file")
    signed = fetch.fedora_checksum(fetcher.get_small(folder + urllib.parse.quote(sums[0])), keys)
    images = sorted(item for item in signed if re.fullmatch(rf"Fedora-[A-Za-z]+-netinst-x86_64-{version}-[0-9.]+\.iso",
                                                            item))
    if len(images) != 1:
        raise PartFailed(f"Fedora {version}'s signed checksum list names no single install image")
    expected = signed[images[0]]
    target = "ISO/" + images[0]
    old = entries[path]
    if target == path and old["sha256"] == expected.sha256:
        part.lines.append(f"Fedora install image: {images[0]} is unchanged (matches Fedora's signed list).")
        return part
    part.changed = True
    part.wants.append(Want(name, target, relocated(expected, "fedora/" + images[0]),
                           folder + urllib.parse.quote(images[0])))
    if target != path:
        part.removes.append(path)
        part.renames["/" + path] = ("/" + target, match.group(2), version)
        part.lines.append(f"Fedora install image: {match.group(1)} -> {images[0]} (Fedora's signed list).")
    else:
        part.lines.append(f"Fedora install image: the saved copy of {images[0]} differs from Fedora's signed list, "
                          "so it is fetched again.")
    return part


def rescue_part(name, entries, old_root, args, fetcher, fetch, store):
    part = Part(name)
    found = {}
    for path in sorted(entries):
        for tool, (_, pattern, _) in TOOLS.items():
            match = pattern.fullmatch(path)
            if match:
                found.setdefault(tool, []).append((path, match.group(1)))
    if not found:
        part.lines.append("Rescue tools: this saved master has none, so there is nothing to check.")
        return part
    problems = []
    memtest_version = memtest_sums = None
    for tool in TOOLS:
        if tool not in found:
            continue
        label = TOOLS[tool][0]
        path, have = max(found[tool], key=lambda item: _version_key(item[1]))
        try:
            if tool == "systemrescue":
                version = newest_systemrescue(fetcher.get_small(url(SYSRESCUE_PAGE)).decode("utf-8", "replace"))
                file_name = TOOLS[tool][2].format(version=version)
                base = url(SYSRESCUE_FILES.format(version=version))
                listed = fetch.sha256sums(fetcher.get_small(base + file_name + ".sha256"), require_signed=False,
                                          what="SystemRescue's checksum file")
                source, unpack = file_name, ""
                address = base + file_name
            elif tool == "clonezilla":
                text = clonezilla_sha256_section(fetcher.get_small(url(CLONEZILLA_SUMS)).decode("utf-8", "replace"))
                listed = fetch.sha256sums(text.encode("utf-8"), require_signed=False,
                                          what="Clonezilla's checksum list")
                versions = [match.group(1) for match in
                            (re.fullmatch(rf"clonezilla-live-({VERSION}-[0-9]+)-amd64\.iso", item) for item in listed)
                            if match]
                if len(versions) != 1:
                    raise PartFailed("Clonezilla's checksum list names no single amd64 image")
                version = versions[0]
                file_name = source = TOOLS[tool][2].format(version=version)
                address = url(CLONEZILLA_FILE.format(version=version, name=file_name))
                unpack = ""
            else:
                if memtest_version is None:
                    memtest_version = github_latest_version(fetcher, MEMTEST_LATEST, "Memtest86+")
                    memtest_sums = fetcher.get_small(url(MEMTEST_FILES.format(version=memtest_version)) +
                                                     "sha256sum.txt").decode("utf-8", "replace")
                version = memtest_version
                file_name = TOOLS[tool][2].format(version=version)
                source = MEMTEST_ZIP[tool].format(version=version)
                listed = fetch.sha256sums(memtest_sums_text(memtest_sums, version).encode("utf-8"),
                                          require_signed=False, what="Memtest86+'s checksum list")
                address = url(MEMTEST_FILES.format(version=version)) + source
                unpack = "memtest"
            if source not in listed:
                raise PartFailed(f"{label}'s checksum list does not name {source}")
            if _version_key(version) < _version_key(have):
                part.lines.append(f"{label}: the saved {have} is newer than the published {version}; it is kept.")
                continue
            target = "ISO/tools/" + file_name
            same_name = target == path
            if same_name and (unpack or entries[path]["sha256"] == listed[source].sha256):
                part.lines.append(f"{label} {version}: unchanged.")
                continue
            part.changed = True
            part.wants.append(Want(name, target, relocated(listed[source], "rescue/" + source),
                                   address, unpack))
            if not same_name:
                part.removes.append(path)
                part.renames["/" + path] = ("/" + target, have, version)
                if tool == "systemrescue":
                    part.drop_rescue_configs = True
                part.lines.append(f"{label}: {have} -> {version} (to be checked against its publisher's checksum "
                                  "list, which comes over https and is not signed).")
            else:
                part.lines.append(f"{label} {version}: the saved copy differs from the publisher's list, so it is "
                                  "fetched again.")
        except (PartFailed, fetch.FetchError, ValueError) as exc:
            problems.append(f"{label}: {exc}")
    if problems and not part.wants:
        raise PartFailed("; ".join(problems))
    for problem in problems:
        part.lines.append(f"Not checked this time: {problem}")
    return part


def ventoy_part(name, entries, old_root, args, fetcher, fetch, store):
    part = Part(name)
    version = github_latest_version(fetcher, VENTOY_LATEST, "Ventoy")
    file_name = f"ventoy-{version}-linux.tar.gz"
    base = url(VENTOY_FILES.format(version=version))
    expected = fetch.ventoy_checksums(fetcher.get_small(base + "sha256.txt"), [file_name])[file_name]
    record = _read_json(Path(store) / VENTOY_FOLDER / VENTOY_RECORD)
    kept = Path(store) / VENTOY_FOLDER / file_name
    if (record.get("file") == file_name and record.get("sha256") == expected.sha256 and kept.is_file()
            and not kept.is_symlink() and fetch.sha256_file(kept) == expected.sha256):
        part.lines.append(f"Ventoy {version}: the package next to the saved master is unchanged.")
        return part
    part.changed = True
    part.wants.append(Want(name, "", relocated(expected, "ventoy/" + file_name), base + file_name))
    part.lines.append(f"Ventoy {version}: the package is fetched (checked against Ventoy's own checksum list, "
                      "downloaded over https; Ventoy does not sign it).")
    return part


def offline_part(name, entries, old_root, args, fetcher, fetch, store):
    part = Part(name)
    pointer = OFFLINE_ROOT + "current.json"
    if pointer not in entries:
        part.lines.append("Offline app collection: this saved master has none, so there is nothing to check.")
        return part
    current = _read_json(Path(old_root) / "payload" / pointer)
    version = current.get("bundle_version")
    if not isinstance(version, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", version):
        raise PartFailed("the offline app collection's current.json names no valid version")
    bundle = Path(old_root) / "payload" / OFFLINE_ROOT / version
    plan = _read_json(bundle / "plan.json")
    if plan.get("schema") != OFFLINE_PLAN_SCHEMA:
        raise PartFailed("the offline app collection's plan is in a form this version does not understand, so "
                         "nothing was downloaded for it")
    listed = fetch.offline_collection(bundle)
    prefix = OFFLINE_ROOT + version + "/"
    missing = 0
    for expected in listed.values():
        target = prefix + expected.relative
        if entries.get(target, {}).get("sha256") == expected.sha256:
            continue
        missing += 1
        part.wants.append(Want(name, target, relocated(expected, "offline/" + expected.relative),
                               url(expected.url)))
    part.changed = bool(missing)
    part.lines.append(f"Offline app collection {version}: {len(listed) - missing} file(s) unchanged, {missing} missing "
                      "or damaged" + (" (fetched again, checked against the approved plan)." if missing else "."))
    return part


LOOKUPS = {"fedora": fedora_part, "rescue": rescue_part, "ventoy": ventoy_part, "offline": offline_part}


def _read_json(path):
    try:
        with open(path, "rb") as handle:
            value = json.loads(handle.read(4 * 1024 * 1024))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


# ---- after the downloads ------------------------------------------------------------------------------------------

def unpack_part(part, downloads, fetch):
    """Memtest86+ comes as a .zip whose own SHA-256 was checked; the image inside is taken out (one named entry)."""
    import zipfile
    for want in part.wants:
        if want.unpack != "memtest":
            continue
        archive = downloads.joinpath(*PurePosixPath(want.expected.relative).parts)
        image = archive.with_name(PurePosixPath(want.master_path).name)
        if fetch.sha256_file(archive) != want.expected.sha256:
            raise PartFailed(f"{archive.name} changed after it was checked, so it was not used")
        try:
            with zipfile.ZipFile(archive) as bundle:
                matches = [info for info in bundle.infolist() if info.filename == MEMTEST_ENTRY]
                if len(matches) != 1 or matches[0].is_dir() or matches[0].file_size > MAX_MEMTEST:
                    raise PartFailed(f"{archive.name} does not hold one {MEMTEST_ENTRY} of a normal size")
                temporary = image.with_name(image.name + ".unpacking")
                count = 0
                digest = hashlib.sha256()
                with bundle.open(matches[0]) as incoming, open(temporary, "wb") as outgoing:
                    while True:
                        block = incoming.read(1024 * 1024)
                        if not block:
                            break
                        count += len(block)
                        if count > MAX_MEMTEST:
                            raise PartFailed(f"{archive.name} holds a larger {MEMTEST_ENTRY} than it says")
                        digest.update(block)
                        outgoing.write(block)
                    outgoing.flush()
                    os.fsync(outgoing.fileno())
                os.replace(temporary, image)
        except (zipfile.BadZipFile, OSError, RuntimeError) as exc:
            raise PartFailed(f"{archive.name} could not be opened ({type(exc).__name__})") from exc
        want.unpacked = (image, digest.hexdigest(), count)


def set_part(name, entries, store, args, api, apply=True, max_mb=None, spent=None):
    """secure-linux-kit-update keeps <store>/.refresh-sets/<name> up to date with every check of an update; the files
    its record names (each checked here again) become linux-setup/<...>/ in the saved master. Without apply only
    `check --set` runs (it changes nothing); a set that differs is marked pending and applied after agreement."""
    part = Part(name)
    label = SET_LABEL[name]
    work = Path(store) / SETS_FOLDER / name
    if work.is_symlink():
        raise PartFailed(f"the working folder for the {label} is a link, so it was not used")
    work.mkdir(parents=True, exist_ok=True)
    tool = kit_update_tool()
    if tool is None:
        raise PartFailed("secure-linux-kit-update is not on this computer, so the published list cannot be checked")
    command = [sys.executable, str(tool), "apply" if apply else "check", "--set", name, "--tree", str(work)]
    if apply and max_mb is not None:
        command += ["--max-download-mb", max_mb]          # only what is left of the person's limit (_left_mb)
    before = _set_files(work) if apply else {}
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=1800, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise PartFailed(f"secure-linux-kit-update could not run ({type(exc).__name__})") from exc
    finally:
        if apply and spent is not None:              # what this apply brought in counts against the limit
            brought = sum(size for relative, (digest, size) in _set_files(work).items()
                          if before.get(relative, ("",))[0] != digest)
            if brought:
                spent[label] = spent.get(label, 0) + brought
    lines = [line for line in done.stdout.splitlines() if line.startswith("KIT UPDATE:")]
    line = lines[-1] if lines else ""
    if done.returncode == 75:
        raise PartFailed(f"the {label} are busy with another update; try again in a few minutes")
    good = (" here were updated to " in line or " here already match the published release" in line
            or (": put back " in line and "damaged or missing" in line))
    if not apply and done.returncode == 0 and (" here differ from the published release" in line
                                               or " are damaged or missing" in line):
        part.changed = part.pending = True
        part.lines.append(f"The {label}: the published list differs from the copy kept next to the saved master "
                          "(the few small files are fetched after you agree).")
        return part
    signed = "signatures were checked" in line
    if done.returncode != 0 or not good:
        reason = line[len("KIT UPDATE:"):].strip() if line else (done.stderr.strip().splitlines() or ["no answer"])[-1]
        raise PartFailed(f"the {label} were not changed in the saved master ({reason})")
    record = _read_json(work / ".kit-update-set.json")
    listed = record.get("files")
    if record.get("set") != name or not isinstance(listed, dict) or not listed:
        raise PartFailed(f"the {label} came without their record, so they were not used")
    prefix = SET_DEST[name]
    wanted = {}
    for relative, digest in sorted(listed.items()):
        clean = PurePosixPath(relative)
        if (not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest) or clean.is_absolute()
                or ".." in clean.parts or "\\" in relative or relative.startswith(".kit-update")):
            raise PartFailed(f"the {label} list names a file in a form that is never used ({relative!r})")
        path = work.joinpath(*clean.parts)
        if path.is_symlink() or not path.is_file():
            raise PartFailed(f"{relative} of the {label} is missing after the update")
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != digest:
            raise PartFailed(f"{relative} of the {label} does not match the signed list"
                             + ("" if signed else " it should come with (here only the published list, because "
                                                  "release signing is not set up yet)") + ", so it was not used")
        wanted[prefix + clean.as_posix()] = (path, digest, len(data))
    have = {path: entry["sha256"] for path, entry in entries.items() if path.startswith(prefix)}
    if have == {path: value[1] for path, value in wanted.items()}:
        part.lines.append(f"The {label}: unchanged ({line[len('KIT UPDATE:'):].strip()})")
        return part
    part.changed = True
    part.copies = wanted
    part.removes = sorted(path for path in have if path not in wanted)
    api.say(f"The {label}: {len(wanted)} file(s) from the {'signed' if signed else 'published'} list go to {prefix} "
            "in the saved master.")
    return part


def kit_update_tool():
    if _testing() and os.environ.get("SL_USBC_REFRESH_TEST_KIT_UPDATE"):
        return Path(os.environ["SL_USBC_REFRESH_TEST_KIT_UPDATE"])
    here = Path(__file__).resolve().parent
    for path in (here.parent / "bin" / "secure-linux-kit-update",
                 Path("/usr/local/lib/secure-linux/bin/secure-linux-kit-update"),
                 Path("/usr/local/bin/secure-linux-kit-update")):
        if path.is_file():
            return path
    return None


def keep_ventoy_package(part, store, downloads, engine):
    """The checked package goes to <store>/ventoy-package/; the one before it is kept too, older ones go."""
    want = part.wants[0]
    folder = Path(store) / VENTOY_FOLDER
    if folder.is_symlink():
        raise PartFailed("the Ventoy package folder is a link, so it was not used")
    folder.mkdir(mode=0o700, exist_ok=True)
    source = downloads.joinpath(*PurePosixPath(want.expected.relative).parts)
    target = folder / want.expected.name
    size, digest = engine.hash_file(source)
    if digest != want.expected.sha256:
        raise PartFailed("the Ventoy package changed after it was checked, so it was not used")
    os.replace(source, target)
    previous = _read_json(folder / VENTOY_RECORD).get("file")
    record = {"schema": 1, "file": want.expected.name, "sha256": digest, "size": size,
              "checked_with": "Ventoy's own sha256.txt of the release (https; not signed)", "checked_at": engine.utc_now(),
              "previous": previous if previous != want.expected.name else None}
    engine.atomic_write(str(folder / VENTOY_RECORD), (json.dumps(record, indent=2, sort_keys=True) + "\n").encode(),
                        0o600)
    for item in folder.iterdir():
        if (item.name.startswith("ventoy-") and item.name.endswith("-linux.tar.gz")
                and item.name not in (want.expected.name, previous) and item.is_file() and not item.is_symlink()):
            item.unlink()
    part.lines.append(f"VENTOY PACKAGE READY: {target} (checked against Ventoy's own checksum list).")


# ---- the start menu --------------------------------------------------------------------------------------------------

def new_menu(old_root, entries, parts):
    """ventoy/ventoy.json with the renamed images, their titles' version numbers, and (for a new SystemRescue) without
    the start-up changes that were cut from the old image. None when nothing in it changes."""
    renames = {}
    for part in parts:
        renames.update(part.renames)
    drop = any(part.drop_rescue_configs for part in parts)
    if not renames and not drop:
        return None
    if MENU not in entries:
        return None
    try:
        raw = (Path(old_root) / "payload" / MENU).read_bytes()
        config = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        raise PartFailed("the saved master's start menu (ventoy/ventoy.json) cannot be read, so no image was "
                         "renamed") from exc
    if not isinstance(config, dict):
        raise PartFailed("the saved master's start menu (ventoy/ventoy.json) is in an unknown form")
    old_rescue = [old for old in renames if "/systemrescue-" in old]

    def swap(value):
        if isinstance(value, str):
            return renames[value][0] if value in renames else value
        if isinstance(value, list):
            return [swap(item) for item in value]
        if isinstance(value, dict):
            return {key: swap(item) for key, item in value.items()}
        return value

    if drop and isinstance(config.get("conf_replace"), list):
        kept = [item for item in config["conf_replace"]
                if not (isinstance(item, dict) and (item.get("image") in old_rescue
                                                    or str(item.get("new", "")).startswith("/" + SYSRESCUE_CONFIGS)))]
        if kept:
            config["conf_replace"] = kept
        else:
            del config["conf_replace"]
    config = swap(config)
    titles = {new: (old_version, new_version) for new, old_version, new_version in renames.values()}
    for item in config.get("menu_alias") or []:
        if isinstance(item, dict) and item.get("image") in titles and isinstance(item.get("alias"), str):
            old_version, new_version = titles[item["image"]]
            item["alias"] = re.sub(rf"(?<![0-9.]){re.escape(old_version)}(?![0-9.])", new_version, item["alias"])
    data = (json.dumps(config, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    return data if data != raw else None


# ---- the new saved master ---------------------------------------------------------------------------------------------

def publish(store, old_id, old_root, manifest, parts, menu, downloads, api, engine):
    """ONE new saved master: every unchanged file shared (hard link) with the current one, the checked new files
    added. The pointer moves only after everything is in place; the current one is never changed."""
    import datetime
    import uuid
    portable = manifest["portable"]
    old_payload = Path(old_root) / "payload"
    removes = {path for part in parts for path in part.removes}
    if parts and any(part.drop_rescue_configs for part in parts):
        removes |= {path for path in (entry["path"] for entry in portable["files"])
                    if path.startswith(SYSRESCUE_CONFIGS)}
    adds = {}
    for part in parts:
        for want in part.wants:
            if want.unpack:
                image, digest, size = want.unpacked
                adds[want.master_path] = (image, digest, size, True)
            else:
                source = downloads.joinpath(*PurePosixPath(want.expected.relative).parts)
                adds[want.master_path] = (source, want.expected.sha256, want.expected.size, True)
        for path, (source, digest, size) in part.copies.items():
            adds[path] = (source, digest, size, False)
    if menu is not None:
        adds[MENU] = (None, engine.sha256_bytes(menu), len(menu), False)
    master_id = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S") + "-" + uuid.uuid4().hex[:12]
    generations = os.path.join(store, "generations")
    staging = os.path.join(generations, ".building-" + master_id)
    final = os.path.join(generations, master_id)
    os.mkdir(staging, mode=0o700)
    published = False
    payload = Path(staging) / "payload"
    try:
        files = []
        for entry in portable["files"]:
            path = entry["path"]
            if path in removes or path in adds:
                continue
            source = old_payload / path
            size, digest = engine.hash_file(source, entry["size"])
            if size != entry["size"] or digest != entry["sha256"]:
                raise _verification_error(api)(f"a file of the saved master failed its check, so nothing was "
                                               f"changed: {path}")
            _link_or_copy(source, payload / path, entry["size"], store, api)
            files.append(dict(entry))
        for path, (source, digest, size, link) in sorted(adds.items()):
            destination = payload / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            if source is None:
                destination.write_bytes(menu)
            elif link:
                _link_or_copy(source, destination, os.stat(source).st_size, store, api)
            else:
                shutil.copyfile(source, destination)
            real_size, real = engine.hash_file(destination)
            if real != digest or (size is not None and real_size != size):
                raise _verification_error(api)(f"{path} does not match its checked list, so nothing was changed")
            files.append({"path": path, "size": real_size, "sha256": real})
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
                       "refreshed": [part.name for part in parts]},
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
        return master_id
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


def _link_or_copy(source, destination, size, store, api):
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.link(source, destination)         # shared: no time, no space
    except OSError:
        if not api.free_space_ok(store, size + MASTER_ROOM):
            raise api.CreatorError("there is not enough free space next to the saved master. Nothing was changed.")
        shutil.copyfile(source, destination)


def tidy_downloads(downloads, plan, done, failed):
    """Files that are now in the saved master (or the Ventoy folder) leave the download folder; parts of a failed
    download stay, so the next try continues. Parts of files no longer wanted go after a run where nothing failed.
    A name the system refuses to remove is left (it is never made writable: it may be shared with a saved master)."""
    if plan is None or not downloads.is_dir() or downloads.is_symlink():
        return
    names = {part.name for part in done}
    for job in plan.jobs:
        if job.expected.relative.split("/")[0] in names:
            _remove(job.target)
    for part in done:
        for want in part.wants:
            if want.unpacked:
                _remove(want.unpacked[0])
    if failed:
        return
    wanted = {job.expected.sha256 + ".part" for job in plan.jobs}
    folder = downloads / ".bigfetch-parts"
    if folder.is_dir() and not folder.is_symlink():
        for path in folder.iterdir():
            if path.name not in wanted:
                _remove(path)


def _remove(path):
    try:
        if os.path.lexists(path) and not os.path.isdir(path):
            os.unlink(path)
    except OSError:
        pass
