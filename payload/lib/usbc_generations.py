"""Drive-builder add-on (contract C17): go back to the previous saved master, and remove older saved masters.

  secure-linux-usb-creator master-undo  --store S   the previous saved master becomes the one new drives are made from
  secure-linux-usb-creator master-prune --store S   keep only the current saved master and the one before it

Both commands check free space first and hold the store lock (exclusive, contract C4), so no drive is being made
from the saved master while it changes. A saved master is checked file by file before it is trusted: undo checks
the one it goes back to, pruning checks the current one before it removes anything. The current and the previous
saved master are never removed. Neither command opens a drive.

Which one is "previous":
  1. right after an undo, the one that was current before it (so undo again switches back: back and forth);
  2. otherwise the saved master the current one was updated from (sync-master);
  3. otherwise the newest saved master made before the current one.
"""

import json
import os
from pathlib import Path
import re
import types

COMMANDS = ("master-undo", "master-prune")
NO_DEVICE_COMMANDS = COMMANDS          # both work on the saved master's folder only, never on a drive
UNDO_RECORD = "master-undo.json"
PRUNING_PREFIX = ".pruning-"
MIN_FREE_BYTES = 16 * 1024 * 1024
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")

FULL_DISK = ("there is not enough free space on this computer to do this safely (at least 16 MB is needed next to "
             "the saved master). Free up some space, for example by emptying the bin, then try again. "
             "Nothing was changed.")
NEEDS_ADMIN = ("the saved master belongs to the administrator. Run this again as administrator, for example: "
               "sudo secure-linux-usb-creator {command} --store {store}. Nothing was changed.")


def register(subparsers):
    undo = subparsers.add_parser(
        "master-undo",
        help="go back to the previous saved master (it is checked file by file first; the newer one is kept, "
             "so running it again switches back)",
    )
    undo.add_argument("--store", required=True, help="master store containing current and generations")
    undo.add_argument("--current-release",
                      help="this computer's release.json (default: the copy beside this tool); only used to say "
                           "whether the saved master still matches this computer")
    prune = subparsers.add_parser(
        "master-prune",
        help="remove older saved masters to free space: keeps the current one (checked file by file first) "
             "and the one before it",
    )
    prune.add_argument("--store", required=True, help="master store containing current and generations")
    return list(COMMANDS)


def run(args, api):
    store = os.path.abspath(args.store)
    engine = _engine(api)
    _check_store(store, args.command, api)
    if not api.free_space_ok(store, MIN_FREE_BYTES):
        raise api.CreatorError(FULL_DISK)
    try:
        with api.store_lock(store, True):
            if args.command == "master-undo":
                return master_undo(store, args, api, engine)
            return master_prune(store, api, engine)
    except PermissionError as exc:
        raise api.CreatorError(NEEDS_ADMIN.format(command=args.command, store=store)) from exc


# ---- helpers ---------------------------------------------------------------------------------------------------

def _engine(api):
    """The drive builder's own checks: the same code that checks a saved master before every copy."""
    space = getattr(api.load_master, "__globals__", None) or {}
    wanted = ("read_manifest", "verify_master_payload", "atomic_write")
    if not all(callable(space.get(name)) for name in wanted):
        raise api.CreatorError("this drive builder is missing parts this add-on needs. Update Secure Linux, "
                               "then try again. Nothing was changed.")
    status = space.get("write_master_status")
    return types.SimpleNamespace(
        read_manifest=space["read_manifest"],
        verify_master_payload=space["verify_master_payload"],
        atomic_write=space["atomic_write"],
        write_master_status=status if callable(status) else None,
        default_release=space.get("DEFAULT_CURRENT_RELEASE"),
        fsync_directory=space.get("fsync_directory") if callable(space.get("fsync_directory")) else (lambda path: None),
    )


def _verification_error(api):
    return getattr(api, "VerificationError", api.CreatorError)


def _check_store(store, command, api):
    try:
        names = os.listdir(store)
    except FileNotFoundError as exc:
        raise api.CreatorError(f"there is no saved master in {store}. Nothing was changed.") from exc
    except PermissionError as exc:
        raise api.CreatorError(NEEDS_ADMIN.format(command=command, store=store)) from exc
    except OSError as exc:
        raise api.CreatorError(f"the saved master folder {store} cannot be read ({exc.strerror or exc}). "
                               "Nothing was changed.") from exc
    if "generations" not in names or "current" not in names:
        raise api.CreatorError(f"there is no saved master in {store} yet. Nothing was changed.")


def _read_current(store, api):
    try:
        text = Path(store, "current").read_text(encoding="ascii").strip()
    except PermissionError:
        raise
    except (OSError, UnicodeError) as exc:
        raise api.CreatorError("no saved master is selected, so there is nothing to change. Nothing was changed.") from exc
    if not ID_RE.fullmatch(text) or not os.path.isdir(os.path.join(store, "generations", text)):
        raise _verification_error(api)("the saved master's pointer names no saved master on this computer. "
                                       "Nothing was changed.")
    return text


def _raw_manifest(store, name):
    """The manifest as JSON, for ordering and naming only (never trusted for a decision about content)."""
    try:
        with open(os.path.join(store, "generations", name, "manifest.json"), "rb") as handle:
            value = json.loads(handle.read())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def _generations(store):
    """Every complete saved master: name -> sort key (made at, name). Hidden folders are never listed."""
    base = os.path.join(store, "generations")
    found = {}
    for name in os.listdir(base):
        path = os.path.join(base, name)
        if ID_RE.fullmatch(name) and os.path.isdir(path) and not os.path.islink(path):
            found[name] = (str(_raw_manifest(store, name).get("created_at", "")), name)
    return found


def _read_record(store):
    try:
        with open(os.path.join(store, UNDO_RECORD), "rb") as handle:
            value = json.loads(handle.read())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def previous_generation(store, current, generations):
    record = _read_record(store)
    candidate = record.get("previous")
    if record.get("current") == current and candidate in generations and candidate != current:
        return candidate
    source = _raw_manifest(store, current).get("source")
    candidate = source.get("updated_from_master") if isinstance(source, dict) else None
    if candidate in generations and candidate != current:
        return candidate
    older = sorted((key for name, key in generations.items() if name != current and key < generations[current]))
    return older[-1][1] if older else None


def _verify(store, name, api, engine):
    api.say(f"Checking the saved master {name} file by file. This can take a few minutes...")
    try:
        _, _, root, manifest = engine.read_manifest(store, name)
        engine.verify_master_payload(root, manifest, True)
    except OSError as exc:
        raise _verification_error(api)(f"a file of saved master {name} cannot be read ({exc.strerror or exc})") from exc
    return root, manifest


def _release_id(manifest):
    release = manifest.get("release") if isinstance(manifest, dict) else None
    return str(release.get("release_id", "unknown")) if isinstance(release, dict) else "unknown"


def _human(number):
    value = float(number)
    for unit in ("bytes", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            return f"{int(value)} bytes" if unit == "bytes" else f"{value:.1f} {unit}"
        value /= 1024
    return f"{number} bytes"


# ---- master-undo -----------------------------------------------------------------------------------------------

def master_undo(store, args, api, engine):
    current = _read_current(store, api)
    generations = _generations(store)
    previous = previous_generation(store, current, generations)
    if previous is None:
        raise api.CreatorError("there is no earlier saved master on this computer to go back to. Nothing was changed.")
    try:
        _, manifest = _verify(store, previous, api, engine)
    except api.CreatorError as exc:
        raise _verification_error(api)(f"the earlier saved master ({previous}) did not pass its check, so the saved "
                                       f"master was not changed: {exc}") from exc
    was = _release_id(_raw_manifest(store, current))
    # The record goes first: if the computer stops before the switch, the record names a switch that never
    # happened and is ignored, because its "current" is not the store's current.
    record = {"schema": 1, "current": previous, "previous": current}
    engine.atomic_write(os.path.join(store, UNDO_RECORD), (json.dumps(record, sort_keys=True) + "\n").encode(), 0o600)
    engine.atomic_write(os.path.join(store, "current"), (previous + "\n").encode("ascii"), 0o600)
    engine.fsync_directory(store)
    if engine.write_master_status:
        engine.write_master_status(store, manifest)
    api.say("")
    api.say(f"MASTER UNDONE: new drives are made from the earlier saved master again ({previous}).")
    api.say(f"Kit release: {_release_id(manifest)} (was {was})")
    api.say(f"The newer saved master ({current}) is kept. Run master-undo again to switch back to it.")
    _say_release_match(manifest, args, api, engine)
    return 0


def _say_release_match(manifest, args, api, engine):
    """A plain note when the saved master no longer matches the release this computer runs."""
    try:
        import release_manifest
        chosen = getattr(args, "current_release", None)
        path = Path(chosen).expanduser().resolve() if chosen else engine.default_release
        if not path:
            return
        if not release_manifest.master_problems(manifest, Path(path)):
            return
        running, _ = release_manifest.read_json(Path(path))
        api.say(f"Note: this computer runs Secure Linux {running.get('release_id', 'unknown')}, and the saved master "
                f"is now {_release_id(manifest)}. New drives are only made from a saved master that matches this "
                "computer. So also undo this computer's last update, or run master-undo again to switch back.")
    except Exception:       # only a note; the switch itself is already done and checked
        return


# ---- master-prune ----------------------------------------------------------------------------------------------

def master_prune(store, api, engine):
    current = _read_current(store, api)
    generations = _generations(store)
    previous = previous_generation(store, current, generations)
    keep = [name for name in (current, previous) if name]
    base = os.path.join(store, "generations")
    remove = sorted(name for name in generations if name not in keep)
    leftovers = sorted(name for name in os.listdir(base)
                       if name.startswith(PRUNING_PREFIX) and os.path.isdir(os.path.join(base, name))
                       and not os.path.islink(os.path.join(base, name)))
    kept_text = (f"the current saved master ({current}) and the one before it ({previous}), so you can still go back once"
                 if previous else f"the current saved master ({current})")
    if not remove and not leftovers:
        api.say(f"NOTHING TO REMOVE: only {kept_text} are kept." if previous else f"NOTHING TO REMOVE: only {kept_text} is kept.")
        return 0
    try:
        _verify(store, current, api, engine)
    except api.CreatorError as exc:
        raise _verification_error(api)(f"the current saved master ({current}) did not pass its check, so no older "
                                       f"saved master was removed: {exc}") from exc
    kept_files = _inodes([os.path.join(base, name) for name in keep])
    counted = set()
    freed = 0
    removed = []
    problems = []
    for name in remove:
        path = os.path.join(base, name)
        freed += _unshared_bytes(path, kept_files, counted)
        hidden = os.path.join(base, PRUNING_PREFIX + name)
        try:
            _hide(path, hidden)
        except OSError:
            problems.append(name)
            continue
        removed.append(name)
        leftovers.append(PRUNING_PREFIX + name)
    engine.fsync_directory(base)
    put_back = False
    for name in leftovers:
        try:
            put_back = _remove_tree(os.path.join(base, name)) or put_back
        except OSError:
            problems.append(name[len(PRUNING_PREFIX):] if name.startswith(PRUNING_PREFIX) else name)
    engine.fsync_directory(base)
    if put_back:
        _read_only_again([os.path.join(base, name) for name in keep])
    api.say("")
    if removed:
        plural = "saved master" if len(removed) == 1 else "saved masters"
        api.say(f"MASTER PRUNED: removed {len(removed)} older {plural} and freed about {_human(freed)}.")
    else:
        api.say("MASTER PRUNED: left-over parts of older saved masters were removed.")
    api.say(f"Kept: {kept_text}.")
    if problems:
        api.say(f"PRUNE NOT FINISHED: {len(problems)} older saved master(s) could not be removed completely "
                f"({', '.join(sorted(set(problems)))}). They are hidden and are removed the next time. "
                "The current saved master and the one before it are untouched.")
        return 1
    return 0


def _inodes(folders):
    found = set()
    for folder in folders:
        for base, _, names in os.walk(folder):
            for name in names:
                try:
                    info = os.lstat(os.path.join(base, name))
                except OSError:
                    continue
                if info.st_ino:
                    found.add((info.st_dev, info.st_ino))
    return found


def _unshared_bytes(folder, kept, counted):
    """Bytes that really come free: files that no kept saved master shares (each shared file counted once)."""
    total = 0
    for base, _, names in os.walk(folder):
        for name in names:
            try:
                info = os.lstat(os.path.join(base, name))
            except OSError:
                continue
            if info.st_ino:
                key = (info.st_dev, info.st_ino)
                if key in kept or key in counted:
                    continue
                counted.add(key)
                total += info.st_size
            elif info.st_nlink == 1:
                total += info.st_size
    return total


def _hide(path, hidden):
    """One rename takes a saved master out of use at once, so a stop half-way never leaves half a master listed."""
    if os.path.lexists(hidden):
        raise FileExistsError(hidden)
    try:
        os.rename(path, hidden)
    except PermissionError:
        os.chmod(path, 0o700)
        try:
            os.rename(path, hidden)
        except OSError:
            os.chmod(path, 0o500)
            raise


def _remove_tree(path):
    """Remove a hidden old saved master. Folders are made writable; a file only when the system insists on it.

    Returns True when a file's permission had to be changed: a file shared with a kept saved master carries one
    permission for both, so the kept ones are then put back to read-only.
    """
    for base, directories, _ in os.walk(path):
        for name in [None] + directories:
            folder = base if name is None else os.path.join(base, name)
            if not os.path.islink(folder):
                os.chmod(folder, 0o700)
    changed = False
    for base, directories, names in os.walk(path, topdown=False):
        for name in names:
            changed = _unlink(os.path.join(base, name)) or changed
        for name in directories:
            folder = os.path.join(base, name)
            if os.path.islink(folder):
                os.unlink(folder)
            else:
                os.rmdir(folder)
    os.rmdir(path)
    return changed


def _unlink(path):
    try:
        os.unlink(path)
        return False
    except PermissionError:
        if os.path.islink(path):
            raise
        os.chmod(path, 0o600)
        os.unlink(path)
        return True


def _read_only_again(folders):
    for folder in folders:
        for base, _, names in os.walk(folder):
            for name in names:
                path = os.path.join(base, name)
                try:
                    if not os.path.islink(path) and os.stat(path).st_mode & 0o222:
                        os.chmod(path, 0o400)
                except OSError:
                    pass
