"""Drive-builder add-on (contract C17): lock this drive's personal settings with the Wi-Fi PIN.

  secure-linux-usb-creator seal-personal --store S [--home-password]

Your drives carry your own settings: your login (name and password hash), the personal values in build.conf
(your name, home Wi-Fi name, home network, home-server details) and, if you choose, your home-server password.
This command locks them inside ONE file on the drive, linux-setup/private/personal-settings.enc1, with the same
PIN / password that already locks your saved Wi-Fi networks (the same "enc1" lock made by save-wifi.ps1; no new
kind of encryption). Someone who finds the drive sees no login, no password hash and no home-server details.

At install time the setup screen asks for the PIN once (the same question as for the saved Wi-Fi networks). The
right PIN opens everything. A wrong or missing PIN never stops the install: it says so and asks for the login the
same way the network installer does (linux/lib/ks_account_step.py).

It works on the saved master (C4 store lock, exclusive). The saved master is checked file by file first, then a NEW
saved master is made with the locked files; every other file is shared with the one before. The earlier saved
master is kept (to go back to) and still holds the settings unlocked, inside the administrator-only folder.
Every drive made from the new saved master carries the locked settings. No drive is opened.

The PIN and the home-server password are typed by the owner (hidden). They are never taken from the command line,
never written to a log and never made up. --pin-stdin reads them from standard input instead (for tests and for
a calling program): line 1 the PIN, line 2 the home-server password (only with --home-password).

The changes themselves are one plain function, seal_files(), so the Windows drive maker can use them too.
"""

import base64
import datetime
import getpass
import gzip
import importlib.machinery
import importlib.util
import io
import os
from pathlib import Path
import re
import shutil
import sys
import tarfile
import types
import uuid

COMMANDS = ("seal-personal",)
NO_DEVICE_COMMANDS = COMMANDS          # works on the saved master's folder only, never on a drive

KS_PATH = "ventoy/script/secure-linux.ks"
SEALED_PATH = "linux-setup/private/personal-settings.enc1"
BUILD_CONF_PATHS = ("linux-setup/linux/build.conf", "linux-setup/kit/linux/build.conf")
WIFI_RECORDS_PATH = "linux-setup/wifi-networks.txt"
HASHER_PATHS = ("linux-setup/kit/tests/sha512crypt.py",)
MIN_FREE_BYTES = 16 * 1024 * 1024
# A 6-digit PIN can be guessed offline in hours from a lost drive (check C5 F2), so a NEW lock needs a passphrase of
# at least this many plain keyboard characters (make-usb.ps1 Test-LockPin and save-wifi.ps1 follow the same rule).
MIN_PIN = 10
PIN_RULE = ("use a passphrase of 10 or more plain English-keyboard characters, for example three or four short words "
            "(a short number PIN can be guessed by a computer in hours if the drive is ever lost). If your saved Wi-Fi "
            "networks use a shorter PIN, save them again with the new passphrase first (SAVE-THIS-PC.cmd). "
            "Nothing was changed.")

SEALED_MARK_OFF = "SL_SEALED=no"
SEALED_MARK_ON = "SL_SEALED=yes"
KS_PAYLOAD_BEGIN = "base64 -d > /tmp/secure-linux.tar.gz <<'SL_TGZ_END'\n"
KS_PAYLOAD_END = "\nSL_TGZ_END\n"
WIFI_PY_BEGIN = "cat > /tmp/sl-wifi.py <<'SLWIFI_PY_END'\n"
WIFI_PY_END = "\nSLWIFI_PY_END\n"
WIFI_RECORDS_BEGIN = "cat > /tmp/wifi-records.txt <<'WIFI_RECORDS_END'\n"
WIFI_RECORDS_END = "\nWIFI_RECORDS_END\n"
RENDERED_USER_RE = re.compile(r"^user --name=\S+ --gecos=.* --groups=wheel --iscrypted --password=\S+$", re.M)
BUILD_LINE_RE = re.compile(r"^([A-Z][A-Z0-9_]*)=(.*)$")

# The template's own lines that carry the login name after %pre (templates/fedora.ks), and what they become: the
# name comes from the setup screen's choices file, exactly as in the network installer (netboot/render-netboot.sh 7, 7b).
USER_NAME_SITES = (
    ("echo '__USERNAME__' > /etc/secure-linux/user",
     "# locked settings: the login name comes from the setup screen's choices file\n"
     "sed -n 's/^sl_username=//p' /etc/secure-linux/choices | head -n 1 > /etc/secure-linux/user\n"
     "[ -s /etc/secure-linux/user ] || echo owner > /etc/secure-linux/user"),
    ('  PASS_DEST="$SYSROOT/home/__USERNAME__/Documents/Import-These-Passwords"',
     '  SL_INSTALL_USER=$(sed -n \'s/^sl_username=//p\' "$SYSROOT/etc/secure-linux/choices" | head -n 1)\n'
     '  [ -n "$SL_INSTALL_USER" ] || SL_INSTALL_USER=owner\n'
     '  PASS_DEST="$SYSROOT/home/$SL_INSTALL_USER/Documents/Import-These-Passwords"'),
    ('''if [ -d /home/__USERNAME__/Documents/Import-These-Passwords ]; then
  chown -R __USERNAME__:__USERNAME__ /home/__USERNAME__/Documents/Import-These-Passwords
  restorecon -R /home/__USERNAME__/Documents/Import-These-Passwords 2>/dev/null
fi''',
     '''SL_INSTALL_USER=$(sed -n 's/^sl_username=//p' /etc/secure-linux/choices | head -n 1)
[ -n "$SL_INSTALL_USER" ] || SL_INSTALL_USER=owner
if [ -d "/home/$SL_INSTALL_USER/Documents/Import-These-Passwords" ]; then
  chown -R "$SL_INSTALL_USER:$SL_INSTALL_USER" "/home/$SL_INSTALL_USER/Documents/Import-These-Passwords"
  restorecon -R "/home/$SL_INSTALL_USER/Documents/Import-These-Passwords" 2>/dev/null
fi'''),
)

UNLOCKED_LOGIN_STEP = '''# ---------------------------------------------------------------- locked settings: your login
# seal-personal (linux/lib/usbc_seal.py) moved this drive's login into the locked settings. When the PIN opened
# them, /tmp/user.ks is already written and this step only says so. Otherwise (wrong or no PIN, or the locked
# file is missing) the login is asked right here, exactly as the network installer asks it.
if [ -s /tmp/user.ks ]; then
N=$((N + 1))
header "your login"
echo "   STEP $N of $TOTAL: your login"
echo
echo "   Your login was unlocked from this drive's locked settings."
sleep 2
else
'''

TOO_OLD = ("this saved master was made with an older Secure Linux kit, so its settings cannot be locked ({why}). "
           "Make the drive again with the current kit, save it as the master, then try again. Nothing was changed.")
NEEDS_ADMIN = ("the saved master belongs to the administrator. Run this again as administrator, for example: "
               "sudo secure-linux-usb-creator seal-personal --store {store}. Nothing was changed.")


class SealError(ValueError):
    """The drive's files are not the way this step expects. The message says what, in plain words."""


# ---- loading the drive's own helpers -----------------------------------------------------------------------------

def _between(text, begin, end, what):
    if text.count(begin) != 1:
        raise SealError(TOO_OLD.format(why="the installer script has no single " + what))
    start = text.index(begin) + len(begin)
    stop = text.find(end, start)
    if stop < 0:
        raise SealError(TOO_OLD.format(why="the installer script's " + what + " has no end"))
    return start, stop


def wifi_module(ks_text):
    """The installer's own sl-wifi.py (embedded in the installer script): the code that opens the lock at install time.

    Locking with exactly that code means the installer can always open what was locked."""
    start, stop = _between(ks_text, WIFI_PY_BEGIN, WIFI_PY_END, "Wi-Fi helper")
    source = ks_text[start:stop]
    module = types.ModuleType("secure_linux_sealed_wifi")
    module.__file__ = "<sl-wifi.py from the installer script>"
    exec(compile(source, module.__file__, "exec"), module.__dict__)   # noqa: S102 - the master's own verified code
    for name in ("encrypt", "decrypt", "seal_text", "parse_seal_text", "SEALED_CONF_KEYS"):
        if not hasattr(module, name):
            raise SealError(TOO_OLD.format(why="its Wi-Fi helper cannot lock settings yet"))
    return module


def account_step_module():
    """linux/lib/ks_account_step.py (P10b): the network installer's "your login" step."""
    path = Path(__file__).resolve().parent / "ks_account_step.py"
    if not path.is_file():
        raise SealError("the account step (linux/lib/ks_account_step.py) is missing beside this add-on, so a "
                        "wrong PIN could not ask for the login. Nothing was changed.")
    loader = importlib.machinery.SourceFileLoader("secure_linux_ks_account_step_for_seal", str(path))
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    sys.dont_write_bytecode = True
    loader.exec_module(module)
    return module


# ---- the changes, as one plain function ---------------------------------------------------------------------------

def _b64_wrap(data):
    encoded = base64.b64encode(data).decode("ascii")
    return "\n".join(encoded[index:index + 76] for index in range(0, len(encoded), 76))


def _blank_build_conf(text, keys):
    """(build.conf with the locked keys emptied, [(key, value)] in file order). Comments and other keys stay."""
    out, found, seen = [], [], set()
    newline = "\r\n" if "\r\n" in text else "\n"
    for line in text.replace("\r\n", "\n").split("\n"):
        match = BUILD_LINE_RE.match(line)
        if match and match.group(1) in keys:
            key = match.group(1)
            if key not in seen and match.group(2) != "":
                found.append((key, match.group(2)))
            seen.add(key)
            out.append(key + "=")
        else:
            out.append(line)
    return newline.join(out), found


def _repack_build_conf(archive_bytes, keys):
    """The packed Secure Linux folder with build.conf's locked keys emptied; every other member byte for byte."""
    members = []
    found = None
    try:
        with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode="r:gz") as archive:
            for member in archive.getmembers():
                name = member.name[2:] if member.name.startswith("./") else member.name
                parts = name.rstrip("/").split("/")
                if member.name.startswith("/") or ".." in parts or "\\" in member.name:
                    raise SealError("the installer script's packed files hold an unsafe path. Nothing was changed.")
                if member.isdir():
                    members.append((member, None))
                elif member.isfile():
                    handle = archive.extractfile(member)
                    data = handle.read() if handle else b""
                    if name == "build.conf":
                        if found is not None:
                            raise SealError("the installer script's packed files hold build.conf twice. Nothing was changed.")
                        text, found = _blank_build_conf(data.decode("utf-8"), keys)
                        data = text.encode("utf-8")
                    members.append((member, data))
                else:
                    raise SealError("the installer script's packed files hold a link or special file. Nothing was changed.")
    except (tarfile.TarError, OSError, EOFError, UnicodeDecodeError) as exc:
        raise SealError(f"the installer script's packed files could not be read ({exc}). Nothing was changed.") from exc
    if found is None:
        raise SealError("the installer script's packed files hold no build.conf. Nothing was changed.")
    packed = io.BytesIO()
    with gzip.GzipFile(fileobj=packed, mode="wb", mtime=0) as zipped:
        with tarfile.open(fileobj=zipped, mode="w", format=tarfile.GNU_FORMAT) as archive:
            for member, data in members:
                if data is None:
                    archive.addfile(member)
                else:
                    member.size = len(data)
                    archive.addfile(member, io.BytesIO(data))
    return packed.getvalue(), found


def _records_lines(files, ks_text):
    lines = []
    raw = files.get(WIFI_RECORDS_PATH)
    if raw:
        lines += raw.decode("utf-8", "replace").splitlines()
    if ks_text.count(WIFI_RECORDS_BEGIN) == 1:
        start = ks_text.index(WIFI_RECORDS_BEGIN) + len(WIFI_RECORDS_BEGIN)
        stop = ks_text.find(WIFI_RECORDS_END, start)
        if stop >= 0:
            lines += ks_text[start:stop].splitlines()
    return [line.strip().split("|") for line in lines if line.count("|") == 5]


def check_pin(files, ks_text, wifi, pin):
    """The passphrase must be long enough (MIN_PIN) and must open the Wi-Fi networks already locked on this drive,
    so ONE passphrase opens everything."""
    if not isinstance(pin, str) or len(pin) < MIN_PIN or not re.fullmatch(r"[\x20-\x7e]+", pin):
        raise SealError(PIN_RULE)
    # One record can be both in linux-setup/wifi-networks.txt and in the installer's records: count each machine
    # (serial and uuid) once, locked and plain alike. A machine's lock counts as opened when one of its records opens.
    locked, plain = {}, set()
    for parts in _records_lines(files, ks_text):
        if parts[4] == "enc1":
            locked.setdefault((parts[0], parts[1]), []).append(parts[5])
        elif parts[4] == "plain":
            plain.add((parts[0], parts[1]))
    opened = 0
    for blobs in locked.values():
        for blob in dict.fromkeys(blobs):
            try:
                wifi.decrypt(pin, base64.b64decode(blob))
            except (PermissionError, ValueError):
                continue
            opened += 1
            break
    if locked and not opened:
        raise SealError("that passphrase does not open the Wi-Fi networks saved on this drive. Use the same "
                        "passphrase, so one passphrase opens everything at install time. Nothing was changed.")
    return {"wifi_locked": len(locked), "wifi_opened": opened, "wifi_plain": len(plain)}


def seal_files(files, pin, home_password=None, hasher_py=None, account_step=None):
    """Lock one drive's personal settings. files: {drive path: bytes} (at least the installer script).

    Returns (changes, report): changes = {drive path: new bytes} (the installer script, each build.conf copy and the
    new locked file). Nothing is written here. Any surprise raises SealError and nothing is changed."""
    raw = files.get(KS_PATH)
    if raw is None:
        raise SealError("this saved master has no installer script (ventoy/script/secure-linux.ks). Nothing was changed.")
    try:
        ks = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise SealError("the installer script is not plain text. Nothing was changed.") from exc
    if "\r" in ks:
        raise SealError("the installer script has Windows line ends, so it cannot be changed safely. Nothing was changed.")
    if re.search(r"^" + re.escape(SEALED_MARK_ON) + r"$", ks, re.M):
        raise SealError("the settings on this saved master are already locked. Nothing was changed.")
    if len(re.findall(r"^" + re.escape(SEALED_MARK_OFF) + r"$", ks, re.M)) != 1:
        raise SealError(TOO_OLD.format(why="its installer has no place for locked settings"))
    wifi = wifi_module(ks)
    report = check_pin(files, ks, wifi, pin)

    # 1. the login line
    users = RENDERED_USER_RE.findall(ks)
    if len(users) != 1:
        raise SealError("the installer script does not hold exactly one login line, so it cannot be locked. "
                        "Nothing was changed.")
    user_line = users[0]
    name_match = re.match(r"^user --name=(\S+) ", user_line)
    name = name_match.group(1)
    step = account_step or account_step_module()
    template_user = step.ANCHOR_USER_LINE
    # 2. the build.conf values (the packed copy is the one the installer uses)
    keys = tuple(wifi.SEALED_CONF_KEYS)
    begin, end = _between(ks, KS_PAYLOAD_BEGIN, KS_PAYLOAD_END, "packed Secure Linux folder")
    try:
        archive = base64.b64decode("".join(ks[begin:end].split()), validate=True)
    except ValueError as exc:
        raise SealError("the installer script's packed files are not valid base64. Nothing was changed.") from exc
    archive, conf = _repack_build_conf(archive, keys)
    if home_password is not None and not any(key == "HOME_SHARE_PATH" for key, _ in conf):
        raise SealError("this drive has no home-server setting, so there is no home-server password to lock. "
                        "Nothing was changed.")
    # The locked text, checked by the installer's own code both ways before anything is changed.
    try:
        sealed_text = wifi.seal_text(user_line, conf, home_password)
        blob = wifi.encrypt(pin, sealed_text.encode("utf-8"))
        back = wifi.parse_seal_text(wifi.decrypt(pin, blob).decode("utf-8"))
    except ValueError as exc:
        raise SealError(f"these settings cannot be locked: {exc}. Nothing was changed.") from exc
    if back[0] != user_line or list(back[2]) != list(conf) or back[3] != home_password:
        raise SealError("the locked settings did not read back the same. Nothing was changed.")

    # 3. the installer script: no login, no name, no build.conf values; the login step asks only if the PIN failed
    text = ks[:begin] + _b64_wrap(archive) + ks[end:]
    text = text.replace(user_line + "\n", template_user + "\n", 1)
    for old, new in USER_NAME_SITES:
        rendered = old.replace("__USERNAME__", name)
        if text.count(rendered) != 1:
            raise SealError(TOO_OLD.format(why="its installer does not have the login-name lines this tool knows"))
        text = text.replace(rendered, new)
    try:
        text = step.apply_account_step(text)
    except step.AccountStepError as exc:
        raise SealError(TOO_OLD.format(why=str(exc))) from exc
    start = text.index(step.STEP_MARKER)
    stop = text.index(step.ANCHOR_PLAN, start)
    text = text[:start] + UNLOCKED_LOGIN_STEP + text[start:stop] + "fi\n\n" + text[stop:]
    if hasher_py is None:
        raise SealError("the password hasher (tests/sha512crypt.py) is not in this saved master, so a wrong PIN "
                        "could not ask for the login. Nothing was changed.")
    for line in hasher_py.split("\n"):
        if line.startswith("%") or line == "SHA512CRYPT_END":
            raise SealError("the password hasher has a line that would break the installer script. Nothing was changed.")
    if text.count("__SHA512CRYPT_PY__") != 1:
        raise SealError(TOO_OLD.format(why="the login step has no place for the password hasher"))
    text = text.replace("__SHA512CRYPT_PY__", hasher_py.rstrip("\n"))
    text = re.sub(r"^" + re.escape(SEALED_MARK_OFF) + r"$", SEALED_MARK_ON, text, count=1, flags=re.M)
    if user_line in text or ("/home/%s/" % name) in text or ("'%s'" % name) in text:
        raise SealError("the login name is still in the installer script after locking. Nothing was changed.")

    changes = {KS_PATH: text.encode("utf-8"), SEALED_PATH: (base64.b64encode(blob).decode("ascii") + "\n").encode("ascii")}
    for path in BUILD_CONF_PATHS:
        if path in files:
            try:
                conf_text, _ = _blank_build_conf(files[path].decode("utf-8"), keys)
            except UnicodeDecodeError as exc:
                raise SealError(f"{path} is not plain text. Nothing was changed.") from exc
            changes[path] = conf_text.encode("utf-8")
    report.update({"login": name, "settings": [key for key, _ in conf], "home_password": home_password is not None,
                   "home_wifi_in_installer": "home-wifi.nmconnection" in ks,
                   "debian": any(path.startswith("ventoy/script/debian-") for path in files)})
    return changes, report


# ---- the command ----------------------------------------------------------------------------------------------------

def sealed_template(template, account_step=None):
    """The installer TEMPLATE with the same changes seal_files() makes, its __NAME__ places kept (for the drive
    builder's copies for someone else: unrender_installer() on a locked installer). None when the template does not
    have the places this tool changes. The password hasher stays the __SHA512CRYPT_PY__ place."""
    if "\r" in template or len(re.findall(r"^" + re.escape(SEALED_MARK_OFF) + r"$", template, re.M)) != 1:
        return None
    step = account_step or account_step_module()
    if template.count(step.ANCHOR_USER_LINE + "\n") != 1:
        return None
    text = template
    for old, new in USER_NAME_SITES:
        if text.count(old) != 1:
            return None
        text = text.replace(old, new)
    try:
        text = step.apply_account_step(text)
    except step.AccountStepError:
        return None
    start = text.index(step.STEP_MARKER)
    stop = text.index(step.ANCHOR_PLAN, start)
    text = text[:start] + UNLOCKED_LOGIN_STEP + text[start:stop] + "fi\n\n" + text[stop:]
    if text.count("__SHA512CRYPT_PY__") != 1:
        return None
    return re.sub(r"^" + re.escape(SEALED_MARK_OFF) + r"$", SEALED_MARK_ON, text, count=1, flags=re.M)


def register(subparsers):
    seal = subparsers.add_parser(
        "seal-personal",
        help="lock your login, home-server details and other personal settings on the saved master with your "
             "Wi-Fi PIN; every drive made from it then asks for the PIN once at install time",
    )
    seal.add_argument("--store", required=True, help="master store containing current and generations")
    seal.add_argument("--home-password", action="store_true",
                      help="also lock your home-server password (typed now, hidden), so a new computer never asks for it")
    seal.add_argument("--pin-stdin", action="store_true",
                      help="read the PIN (and the home-server password) from standard input, one per line, "
                           "instead of asking; never put them on the command line")
    return list(COMMANDS)


def _engine(api):
    space = getattr(api.load_master, "__globals__", None) or {}
    wanted = ("read_manifest", "verify_master_payload", "atomic_write", "atomic_replace", "json_data", "sha256_bytes",
              "utc_now", "validate_manifest", "hash_file", "fsync_directory", "writable_tree_for_removal")
    if not all(callable(space.get(name)) for name in wanted):
        raise api.CreatorError("this drive builder is missing parts this add-on needs. Update Secure Linux, then "
                               "try again. Nothing was changed.")
    engine = types.SimpleNamespace(**{name: space[name] for name in wanted})
    status = space.get("write_master_status")
    engine.write_master_status = status if callable(status) else None
    return engine


def _secrets(args):
    """(PIN, home-server password or None), typed by the owner. Never from argv, never echoed, never logged."""
    if args.pin_stdin:
        lines = sys.stdin.read().split("\n")
        pin = lines[0].rstrip("\r") if lines else ""
        home = (lines[1].rstrip("\r") if len(lines) > 1 else "") if args.home_password else None
        return pin, home
    pin = getpass.getpass("Your passphrase, 10 or more characters (the one that locks your saved Wi-Fi networks): ")
    again = getpass.getpass("Type it again: ")
    if pin != again:
        raise SystemExit("seal-personal: the two PINs are not the same. Nothing was changed.")
    home = None
    if args.home_password:
        home = getpass.getpass("Your home-server password (it is locked on the drive, never shown): ")
    return pin, home


def run(args, api):
    store = os.path.abspath(args.store)
    engine = _engine(api)
    try:
        names = os.listdir(store)
    except FileNotFoundError as exc:
        raise api.CreatorError(f"there is no saved master in {store}. Nothing was changed.") from exc
    except PermissionError as exc:
        raise api.CreatorError(NEEDS_ADMIN.format(store=store)) from exc
    if "generations" not in names or "current" not in names:
        raise api.CreatorError(f"there is no saved master in {store} yet. Nothing was changed.")
    if not api.free_space_ok(store, MIN_FREE_BYTES):
        raise api.CreatorError("there is not enough free space on this computer to do this safely (at least 16 MB "
                               "is needed next to the saved master). Nothing was changed.")
    pin, home = _secrets(args)
    try:
        with api.store_lock(store, True):
            return seal_master(store, pin, home, api, engine)
    except PermissionError as exc:
        raise api.CreatorError(NEEDS_ADMIN.format(store=store)) from exc
    except SealError as exc:
        raise api.CreatorError(str(exc)) from exc
    finally:
        pin = home = None


def seal_master(store, pin, home, api, engine):
    store, old_id, old_root, manifest = engine.read_manifest(store)
    portable = manifest.get("portable")
    if not portable:
        raise api.CreatorError("this saved master holds no file tree; save a new master from a finished USB. "
                               "Nothing was changed.")
    api.say(f"Checking the saved master {old_id} file by file. This can take a few minutes...")
    engine.verify_master_payload(old_root, manifest, True)
    payload = Path(old_root) / "payload"
    entries = {entry["path"]: entry for entry in portable["files"]}
    wanted = (KS_PATH, WIFI_RECORDS_PATH) + BUILD_CONF_PATHS + tuple(path for path in entries
                                                                     if path.startswith("ventoy/script/debian-"))
    files = {path: (payload / path).read_bytes() for path in wanted if path in entries}
    if SEALED_PATH in entries:
        raise api.CreatorError("this saved master already holds locked settings. Nothing was changed.")
    hasher = None
    for path in HASHER_PATHS:
        if path in entries:
            hasher = (payload / path).read_bytes().decode("utf-8", "replace")
            break
    changes, report = seal_files(files, pin, home, hasher)

    master_id = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S") + "-" + uuid.uuid4().hex[:12]
    generations = os.path.join(store, "generations")
    staging = os.path.join(generations, ".building-" + master_id)
    final = os.path.join(generations, master_id)
    os.mkdir(staging, mode=0o700)
    published = False
    try:
        new_payload = Path(staging) / "payload"
        files_out = []
        total = 0
        for relative in sorted(set(entries) | set(changes)):
            destination = new_payload / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            if relative in changes:
                data = changes[relative]
                with open(destination, "xb") as handle:
                    handle.write(data)
                entry = {"path": relative, "size": len(data), "sha256": engine.sha256_bytes(data)}
            else:
                source = payload / relative
                try:
                    os.link(source, destination)       # shared with the previous saved master: no time, no space
                except OSError:
                    with open(source, "rb") as reader, open(destination, "xb") as writer:
                        while True:
                            block = reader.read(1024 * 1024)
                            if not block:
                                break
                            writer.write(block)
                entry = dict(entries[relative])
            size, digest = engine.hash_file(destination)
            if size != entry["size"] or digest != entry["sha256"]:
                raise api.VerificationError(f"a file of the new saved master did not read back the same: {relative}")
            files_out.append(entry)
            total += entry["size"]
        new_portable = dict(portable)
        new_portable.update({"files": files_out, "file_count": len(files_out), "payload_bytes": total})
        source = dict(manifest.get("source") or {})
        source.update({"updated_from_master": old_id, "personal_settings": "locked"})
        new_manifest = dict(manifest)
        new_manifest.update({"master_id": master_id, "created_at": engine.utc_now(), "source": source,
                             "portable": new_portable})
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
    finally:
        if not published and os.path.isdir(staging):
            engine.writable_tree_for_removal(staging)
            shutil.rmtree(staging, ignore_errors=True)
            for base, _, names in os.walk(old_root):
                for name in names:
                    try:
                        os.chmod(os.path.join(base, name), 0o400)
                    except OSError:
                        pass
    say = api.say
    say("")
    say(f"SETTINGS LOCKED: new saved master {master_id}")
    say(f"Locked with your PIN: your login ({report['login']}), "
        + (", ".join(report["settings"]) if report["settings"] else "no build.conf values")
        + (", your home-server password" if report["home_password"] else "") + ".")
    say("Every drive made from this saved master asks for the PIN once while installing. The right PIN opens "
        "everything; a wrong one never stops the install: it asks for the login instead.")
    say("The lock is only as strong as your PIN / password: a longer one, for example three or four words, is much "
        "harder to guess if a drive is ever lost.")
    if report["wifi_locked"]:
        say(f"The same passphrase opens the locked Wi-Fi networks of {report['wifi_opened']} of the "
            f"{report['wifi_locked']} computer(s) saved on this drive.")
    if report["wifi_opened"] < report["wifi_locked"]:
        say("Note: the other locked Wi-Fi record(s) use a different PIN. On those computers the install opens either "
            "the Wi-Fi networks or your settings, not both. Save their Wi-Fi again with this PIN (SAVE-THIS-PC.cmd) "
            "so one PIN opens everything.")
    if report["wifi_plain"]:
        say(f"Note: {report['wifi_plain']} Wi-Fi record(s) on this drive were saved WITHOUT a PIN and are not locked. "
            "Save them again with a PIN (SAVE-THIS-PC.cmd) to lock them.")
    if report["home_wifi_in_installer"]:
        say("Note: the home Wi-Fi password given when the drive was made is written into the installer script and is "
            "NOT locked by this step.")
    if report["debian"]:
        say("Note: the Debian install entries on this drive still carry your name and home settings; they are not "
            "locked by this step.")
    say(f"The earlier saved master ({old_id}) is kept so you can go back, and it still holds these settings "
        "unlocked inside the administrator-only folder.")
    return 0
