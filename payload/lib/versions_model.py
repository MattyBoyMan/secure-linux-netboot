#!/usr/bin/env python3
"""The facts and words behind the Versions screen. No window code lives here.

Four rows: this computer, its saved master, a plugged-in drive's passport, and GitHub (the last answer only).
Reading never uses the network and never needs a password. Buttons run the kit's own tools; the tools that
need administrator rights ask for them themselves (pkexec and their own policy), so nothing here elevates.

  secure-linux-versions --text      print the screen as plain text
  secure-linux-versions --json      print the same facts as JSON

Settings for tests: SL_ROOT (kit folder), SL_KIT_UPDATE_CONF, SL_KIT_UPDATE_HOLD, SL_MASTER_STATUS,
SL_VERSIONS_DRIVE_ROOTS (folders that hold plugged-in drives, separated by ":").
Matt's words only. Matt's pictures stay out until the owner says yes (plan question Q7).
"""
from __future__ import annotations

import datetime
import glob
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Sequence, Tuple

MATT_PICTURES = False   # Q7: no picture of Matt is shown or shipped until the owner says yes.

DEFAULT_TREE = "/usr/local/lib/secure-linux"
DEFAULT_CONF = "/etc/secure-linux/kit-update.conf"
DEFAULT_HOLD = "/var/lib/secure-linux/kit-update-hold.json"
DEFAULT_MASTER_STATUS = "/var/lib/secure-linux/usb-master-status"
DEFAULT_DRIVE_ROOTS = ("/run/media", "/media", "/mnt")
PASSPORT_NAME = "SECURE-LINUX-DRIVE-PASSPORT.json"
PASSPORT_MAX_BYTES = 16384

PRIVACY_TEXT = ("The check sends no personal details. GitHub sees this computer's internet address, "
                "like any website.")

# Every sentence Matt says is here, so one test can read all of them.
WORDS: Dict[str, str] = {
    "title": "Versions and updates",
    "subtitle": "See which release is on this computer, on your saved master, and on a drive.",
    "intro": "Matt: I keep an eye on the releases for you. Here is where everything stands.",
    "all_good": "Matt: Everything is up to date. There is nothing to do.",
    "newer_ready": "Matt: A newer release is ready. Choose Update now and I will install it safely.",
    "master_behind": "Matt: Your saved master is on an older release. Update now brings this computer up to date, and the master follows.",
    "drive_behind": "Matt: A plugged-in drive is on an older release. Open Create a Secure Linux USB when you want it refreshed.",
    "held": "Matt: You went back to an earlier release. I will leave the newer one alone until an even newer release comes out.",
    "offline_by_choice": "Matt: You chose never to check online. I only use the copy on this computer or on a drive.",
    "testing": "Matt: You are on the testing channel. New releases reach you a little earlier than everyone else.",
    "not_checked": "Matt: I have not looked for a newer release yet. Update now checks and installs it.",
    "no_status": "Matt: This computer's release is not recorded yet. Update now will check and record it.",
    "row_computer": "This computer",
    "row_master": "Your saved master",
    "row_drive": "A plugged-in drive",
    "row_github": "GitHub (the newest release)",
    "computer_unknown": "This computer's release is not recorded yet.",
    "master_none": "No saved master on this computer yet.",
    "master_hint": "Open Create a Secure Linux USB to make one.",
    "drive_none": "No Secure Linux drive is plugged in.",
    "drive_check_ok": "Its last check passed.",
    "drive_check_failed": "Its last check did not pass. Open Fix a USB drive to look at it.",
    "drive_unreadable": "A drive is plugged in, but its passport could not be read.",
    "gh_current": "Nothing newer is published.",
    "gh_available": "A newer release is published and waiting.",
    "gh_updated": "The newest release is installed.",
    "gh_offline": "The last look found no internet. Nothing needs fixing.",
    "gh_online_off": "Never check online is on, so I have not looked.",
    "gh_never": "I have not looked yet.",
    "gh_refused": "A newer release was not installed because its checks did not pass. This computer is fine.",
    "gh_held": "A newer release is on hold because you went back.",
    "gh_clock": "The computer's clock looks off, so I did not trust the answer.",
    "gh_other": "No new answer yet.",
    "gh_too_big": "A newer release is waiting. It is a large download, so it was not fetched by itself. Choose Update now when you are on a good connection.",
    "gh_damaged": "Some Secure Linux files on this computer are damaged. Update now puts them back and checks them.",
    "gh_repaired": "Some damaged Secure Linux files were put back and checked.",
    "gh_check_stuck": "The newest update did not pass its safety check and could not be undone. Your files are safe, and the next update fixes this.",
    "gh_check_undone": "The newest update did not pass its safety check, so this computer went straight back to the release it had before.",
    "gh_undone": "You went back to the earlier release. The newer one waits until an even newer release comes out.",
    "gh_busy": "Another update was running at the last look. I look again later by myself.",
    "damaged": "Matt: Some Secure Linux files on this computer are damaged. Choose Update now and I will put them back safely.",
    "check_stuck": "Matt: The newest update did not pass its safety check. Your files are safe. To fix it now, open Secure Linux Status & Fixes and choose Repair setup.",
    "check_undone": "Matt: The newest update did not pass its safety check, so I put back the release you had before. Nothing to do now.",
    "signed_on": "Every update is checked against the Secure Linux signature before it is installed.",
    "signed_off": "Signature checking is not switched on yet. Every file is still checked one by one.",
    "undo_yes": "You can go back to the release before the last update.",
    "undo_no": "There is no earlier release to go back to yet.",
    "settings_online_yes": "Checking online: on.",
    "settings_online_no": "Checking online: never. " + PRIVACY_TEXT,
    "settings_auto_yes": "Installing by itself: on.",
    "settings_auto_no": "Installing by itself: off. I tell you when a release is ready.",
    "settings_channel_stable": "Channel: stable.",
    "settings_channel_testing": "Channel: testing.",
    "settings_mirror_yes": "A home-server copy of the releases is set up.",
    "busy": "Another update is running. Try again in a few minutes.",
    "done": "Done.",
    "unfinished": "That did not finish. Try again in a few minutes. If it keeps happening, open Secure Linux Status & Fixes and choose Repair setup.",
    "not_installed": "This tool is not installed on this computer yet.",
    "cancelled": "Nothing was changed.",
    "opened": "Opened in its own window.",
}

# Buttons: key, label, command, confirm text (None = no question first), what it does for the person.
CONFIRM_UPDATE = ("I will install system and app updates, and Secure Linux's own files if a newer release is ready. "
                  "Nothing of yours is deleted. You may be asked for your password.")
CONFIRM_UNDO = ("I will put back the files from before the last update. Your own files are not touched. "
                "I will not install that update again until a newer release comes out.")
CONFIRM_TESTING = ("The testing channel gets new releases a little earlier, before they are called stable. "
                   "Every release is still checked file by file. You can go back to stable at any time.")
CONFIRM_STABLE = "I will go back to the stable channel. You get releases when they are called stable."
CONFIRM_ONLINE_ON = "I will check for new releases again. " + PRIVACY_TEXT


@dataclass(frozen=True)
class Action:
    key: str
    label: str
    argv: Tuple[str, ...]
    explain: str
    confirm: Optional[str] = None
    enabled: bool = True
    disabled_why: str = ""
    window: bool = False     # the tool opens its own window: start it and do not wait
    timeout: int = 300


@dataclass
class Row:
    key: str
    title: str
    release_id: str
    date_text: str
    state: str      # current | behind | ahead | different | unknown | missing | info
    lines: List[str] = field(default_factory=list)


@dataclass
class Snapshot:
    rows: List[Row]
    headline: str
    settings: Dict[str, object]
    actions: List[Action]
    notes: List[str] = field(default_factory=list)

    def as_dict(self) -> dict:
        return {
            "headline": self.headline,
            "rows": [{"key": r.key, "title": r.title, "release_id": r.release_id, "date": r.date_text,
                      "state": r.state, "lines": list(r.lines)} for r in self.rows],
            "settings": dict(self.settings),
            "actions": [{"key": a.key, "label": a.label, "argv": list(a.argv), "enabled": a.enabled} for a in self.actions],
        }


@dataclass
class ActionResult:
    ok: bool
    text: str
    rc: int = 0


# ---------------------------------------------------------------- small helpers

RELEASE_ID_RE = re.compile(r"^[A-Za-z0-9._+~-]{1,64}$")
DATE_RE = re.compile(r"(\d{4})\.(\d{2})\.(\d{2})")
MONTHS = ("January", "February", "March", "April", "May", "June", "July", "August",
          "September", "October", "November", "December")
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def release_date(release_id: str) -> Optional[Tuple[int, int, int]]:
    found = DATE_RE.search(release_id or "")
    if not found:
        return None
    y, m, d = (int(x) for x in found.groups())
    return (y, m, d) if 1 <= m <= 12 and 1 <= d <= 31 else None


def friendly_release(release_id: str) -> str:
    when = release_date(release_id)
    if when:
        return f"{when[2]} {MONTHS[when[1] - 1]} {when[0]}"
    return release_id[:40] if release_id else ""


def friendly_time(text: str) -> str:
    try:
        stamp = datetime.datetime.fromisoformat(str(text).replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return ""
    return f"{stamp.day} {MONTHS[stamp.month - 1]} {stamp.year}"


def compare(release_id: str, reference: str) -> str:
    """How `release_id` stands against the reference release: current, behind, ahead, different or unknown."""
    if not release_id or not reference:
        return "unknown"
    if release_id == reference:
        return "current"
    a, b = release_date(release_id), release_date(reference)
    if a and b:
        if a < b:
            return "behind"
        if a > b:
            return "ahead"
    return "different"


def read_json_file(path: Path, limit: int = 1_000_000) -> dict:
    """A small JSON object from a plain file, or {}.

    The file is opened without following a link at its own name and without waiting on a pipe or device, its
    type and size come from the opened file itself, and never more than `limit` bytes are read, whatever size
    it reported (a drive's passport can be a link to /dev/zero or another huge file)."""
    flags = (os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
             | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOCTTY", 0))
    try:
        handle = os.open(str(path), flags)
    except (OSError, ValueError):
        return {}
    try:
        info = os.fstat(handle)
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            return {}
        chunks: List[bytes] = []
        total = 0
        while total <= limit:
            chunk = os.read(handle, limit + 1 - total)
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        if total > limit:
            return {}
        data = json.loads(b"".join(chunks).decode("utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError, UnicodeError, MemoryError):
        return {}
    finally:
        os.close(handle)


def parse_conf(path: Path) -> Dict[str, str]:
    answer: Dict[str, str] = {}
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return answer
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        answer[key.strip()] = value.strip()
    return answer


def clean_output(text: str, keep: int = 1500) -> str:
    text = ANSI_RE.sub("", text or "").replace("\r", "")
    lines = [line.rstrip() for line in text.splitlines() if line.strip()]
    joined = "\n".join(lines)
    return joined[-keep:] if len(joined) > keep else joined


# ---------------------------------------------------------------- the system, in one small place

class System:
    """Everything that touches the computer. Tests give the controller a fake with the same four methods."""

    def __init__(self, tree: Optional[str] = None):
        self.tree = Path(tree or os.environ.get("SL_ROOT") or DEFAULT_TREE)
        here = Path(__file__).resolve().parent
        self.bin_dirs = [Path("/usr/local/bin"), self.tree / "bin", here.parent / "bin"]

    def resolve(self, name: str) -> Optional[str]:
        for folder in self.bin_dirs:
            candidate = folder / name
            if candidate.is_file() and os.access(candidate, os.X_OK):
                return str(candidate)
        return shutil.which(name)

    def run(self, argv: Sequence[str], timeout: int = 300) -> Tuple[int, str, str]:
        try:
            done = subprocess.run(list(argv), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, errors="replace",
                                  timeout=timeout, check=False)
        except subprocess.TimeoutExpired:
            return 124, "", "timed out"
        except OSError as exc:
            return 127, "", str(exc)
        return done.returncode, done.stdout, done.stderr

    def spawn(self, argv: Sequence[str]) -> bool:
        try:
            subprocess.Popen(list(argv), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
            return True
        except OSError:
            return False


# ---------------------------------------------------------------- reading the four rows

@dataclass
class Sources:
    tree: Path
    conf: Path
    hold: Path
    master_status: Path
    drive_roots: Tuple[str, ...]

    @classmethod
    def from_env(cls, tree: Optional[str] = None) -> "Sources":
        env = os.environ
        roots = env.get("SL_VERSIONS_DRIVE_ROOTS")
        return cls(
            tree=Path(tree or env.get("SL_ROOT") or DEFAULT_TREE),
            conf=Path(env.get("SL_KIT_UPDATE_CONF", DEFAULT_CONF)),
            hold=Path(env.get("SL_KIT_UPDATE_HOLD", DEFAULT_HOLD)),
            master_status=Path(env.get("SL_MASTER_STATUS", DEFAULT_MASTER_STATUS)),
            drive_roots=tuple(r for r in roots.split(":") if r) if roots is not None else DEFAULT_DRIVE_ROOTS,
        )


def run_json(system, name: str, args: Sequence[str]) -> dict:
    exe = system.resolve(name)
    if not exe:
        return {}
    rc, out, _err = system.run([exe, *args], 60)
    try:
        data = json.loads(out)
    except (ValueError, TypeError):
        return {}
    return data if isinstance(data, dict) else {}


def read_settings(sources: Sources, status: dict) -> Dict[str, object]:
    conf = parse_conf(sources.conf)
    online = conf.get("online")
    if online in ("yes", "no"):
        online_value = online == "yes"
    elif isinstance(status.get("online"), bool):
        online_value = bool(status["online"])
    else:
        online_value = True
    channel = conf.get("channel") if conf.get("channel") in ("stable", "testing") else "stable"
    auto = conf.get("auto_apply") != "no"
    held = str(read_json_file(sources.hold).get("release_id", ""))
    if not RELEASE_ID_RE.fullmatch(held):
        held = ""
    return {"online": online_value, "auto_apply": auto, "channel": channel,
            "mirror": bool(conf.get("mirror")), "held_release": held}


def computer_row(sources: Sources, status: dict, settings: dict) -> Row:
    release = str(status.get("release_id") or "")
    if not release:
        release = str(read_json_file(sources.tree / "release.json").get("release_id") or "")
    if not RELEASE_ID_RE.fullmatch(release):
        release = ""
    row = Row("computer", WORDS["row_computer"], release, friendly_release(release), "current" if release else "unknown")
    if not release:
        row.lines.append(WORDS["computer_unknown"])
        return row
    row.lines.append(f"Release of {row.date_text}.")
    applied = friendly_time(str(status.get("applied_at") or ""))
    if applied:
        row.lines.append(f"Installed on {applied}.")
    if "signed_mode" in status:
        row.lines.append(WORDS["signed_on"] if status.get("signed_mode") else WORDS["signed_off"])
    if "undo_available" in status:
        row.lines.append(WORDS["undo_yes"] if status.get("undo_available") else WORDS["undo_no"])
    if settings.get("held_release"):
        row.lines.append(f"On hold: the release of {friendly_release(str(settings['held_release']))}.")
    return row


def master_row(sources: Sources, reference: str) -> Row:
    release = ""
    files_only = ""
    try:
        text = sources.master_status.read_text(encoding="ascii", errors="replace")[:2000]
    except OSError:
        text = ""
    for raw in text.splitlines():
        key, _, value = raw.partition(":")
        if key.strip() == "Release" and RELEASE_ID_RE.fullmatch(value.strip()):
            release = value.strip()
        elif key.strip() == "Files only":
            files_only = value.strip()
    if not release:
        row = Row("master", WORDS["row_master"], "", "", "missing")
        row.lines += [WORDS["master_none"], WORDS["master_hint"]]
        return row
    state = compare(release, reference)
    row = Row("master", WORDS["row_master"], release, friendly_release(release), state)
    row.lines.append(f"Release of {row.date_text}.")
    if files_only == "yes":
        row.lines.append("It holds the kit's files only, without the big downloads.")
    row.lines.append(state_line(state, "master"))
    return row


def state_line(state: str, what: str) -> str:
    if state == "current":
        return "It matches this computer."
    if state == "behind":
        return "It is older than this computer."
    if state == "ahead":
        return "It is newer than this computer. Update now brings this computer up to it."
    if state == "different":
        return "It is a different build of the same day."
    return "I cannot compare it yet."


def find_passports(sources: Sources) -> List[Path]:
    seen: List[Path] = []
    for root in sources.drive_roots:
        for pattern in (f"{root}/*/{PASSPORT_NAME}", f"{root}/*/*/{PASSPORT_NAME}"):
            for found in sorted(glob.glob(pattern)):
                path = Path(found)
                if path not in seen and path.is_file():
                    seen.append(path)
    return seen[:8]


def drive_rows(sources: Sources, reference: str) -> List[Row]:
    rows: List[Row] = []
    for path in find_passports(sources):
        label = path.parent.name[:40] or "drive"
        data = read_json_file(path, PASSPORT_MAX_BYTES)
        release = str(data.get("release_id") or "")
        if not data or not RELEASE_ID_RE.fullmatch(release):
            row = Row("drive", WORDS["row_drive"], "", "", "unknown")
            row.lines += [f"Drive {label}.", WORDS["drive_unreadable"]]
            rows.append(row)
            continue
        state = compare(release, reference)
        row = Row("drive", WORDS["row_drive"], release, friendly_release(release), state)
        row.lines.append(f"Drive {label}: release of {row.date_text}.")
        made = friendly_time(str(data.get("made_at") or ""))
        if made:
            row.lines.append(f"Made on {made}.")
        row.lines.append(WORDS["drive_check_ok"] if data.get("check") == "passed" else WORDS["drive_check_failed"])
        row.lines.append(state_line(state, "drive"))
        rows.append(row)
    if not rows:
        row = Row("drive", WORDS["row_drive"], "", "", "missing")
        row.lines.append(WORDS["drive_none"])
        rows.append(row)
    return rows


# The last answer, as secure-linux-kit-update records it (status --json "last_result") or as the automatic
# update records it (secure-linux-kit-update-auto status "result"); both names of the same answer are listed.
GITHUB_WORDS: Dict[str, str] = {
    "current": "gh_current", "available": "gh_available", "updated": "gh_updated", "offline": "gh_offline",
    "online-off": "gh_online_off", "never-checked": "gh_never", "refused": "gh_refused",
    "check-failed": "gh_refused", "held": "gh_held", "clock-wrong": "gh_clock", "too-big": "gh_too_big",
    "damaged": "gh_damaged", "repaired": "gh_repaired", "check-failed-installed": "gh_check_stuck",
    "check-stuck": "gh_check_stuck", "rolled-back": "gh_check_undone", "check-undone": "gh_check_undone",
    "undone": "gh_undone", "busy": "gh_busy",
}
# Answers that need the person (or tell them what just happened) lead the screen's first sentence.
GITHUB_HEADLINES = {"gh_check_stuck": "check_stuck", "gh_damaged": "damaged", "gh_check_undone": "check_undone"}

NEWER_RE = re.compile(r"a newer release is published \(([A-Za-z0-9._+~-]{1,64})[;)]")


def github_row(status: dict, auto: dict, settings: dict, reference: str) -> Row:
    result = str(status.get("last_result") or "")
    if result in ("", "not-recorded", "never-checked"):
        result = str(auto.get("result") or "never-checked")
    if not settings.get("online", True):
        result = "online-off"
    row = Row("github", WORDS["row_github"], "", "", "info")
    key = GITHUB_WORDS.get(result, "gh_other")
    row.state = {"current": "current", "updated": "current", "repaired": "current", "available": "newer",
                 "too-big": "newer"}.get(result, "info")
    found = NEWER_RE.search(str(auto.get("detail") or ""))
    if result in ("available", "too-big") and found:
        row.release_id = found.group(1)
        row.date_text = friendly_release(row.release_id)
        row.lines.append(f"Newest release: {row.date_text}.")
    message = auto.get("message")
    if (key == "gh_other" and isinstance(message, str) and message.strip() and len(message) <= 400
            and message.isprintable()):
        row.lines.append(message.strip())     # the automatic update's own plain sentence for an answer not listed
    else:
        row.lines.append(WORDS[key])
    when = friendly_time(str(auto.get("checked_at") or ""))
    if when and result != "online-off":
        row.lines.append(f"Last looked on {when}.")
    return row


# ---------------------------------------------------------------- buttons

def build_actions(status: dict, settings: dict) -> List[Action]:
    undo_ok = bool(status.get("undo_available"))
    actions = [
        Action("update_now", "Update now", ("secure-linux-update-now",),
               "Install system and app updates, and Secure Linux's own files if a newer release is ready.",
               confirm=CONFIRM_UPDATE, timeout=3600),
        Action("undo", "Undo last update", ("secure-linux-kit-update-auto", "undo"),
               "Go back to the release from before the last update.",
               confirm=CONFIRM_UNDO, enabled=undo_ok, disabled_why=WORDS["undo_no"]),
        Action("whats_new", "What changed", ("secure-linux-whats-new", "--gui"),
               "Read a short note about what the last update changed.", window=True),
        Action("explain", "Explain this update", ("secure-linux-explain", "--update"),
               "Matt explains the last update in plain words, using only its notes.", window=True),
    ]
    if settings.get("online", True):
        actions.append(Action("never_online", "Never check online",
                              ("secure-linux-kit-update-auto", "set", "--online", "no"),
                              PRIVACY_TEXT, confirm=PRIVACY_TEXT))
    else:
        actions.append(Action("check_online", "Check online again",
                              ("secure-linux-kit-update-auto", "set", "--online", "yes"),
                              "Let this computer look for new releases again.", confirm=CONFIRM_ONLINE_ON))
    if settings.get("channel") == "testing":
        actions.append(Action("stable_channel", "Back to the stable channel",
                              ("secure-linux-kit-update-auto", "set", "--channel", "stable"),
                              "Get releases when they are called stable.", confirm=CONFIRM_STABLE))
    else:
        actions.append(Action("testing_channel", "Testing channel",
                              ("secure-linux-kit-update-auto", "set", "--channel", "testing"),
                              "Get new releases a little earlier.", confirm=CONFIRM_TESTING))
    if settings.get("held_release"):   # "Try it again": the release the person went back from, after all
        actions.append(Action("retry_held", "Try it again", ("secure-linux-kit-update-auto", "retry"), "Install the release you went back from after all.", confirm="Install the release you went back from after all? Every file is checked, exactly like a normal update. Your own files are not touched.", timeout=3600))
    return actions


def headline_for(rows: List[Row], settings: dict, status: dict) -> str:
    computer = next((r for r in rows if r.key == "computer"), None)
    github = next((r for r in rows if r.key == "github"), None)
    master = next((r for r in rows if r.key == "master"), None)
    drives = [r for r in rows if r.key == "drive"]
    if computer is None or not computer.release_id:
        return WORDS["no_status"]
    answers = set(github.lines) if github is not None else set()
    for key, headline in GITHUB_HEADLINES.items():
        if WORDS[key] in answers:
            return WORDS[headline]
    if settings.get("held_release"):
        return WORDS["held"]
    if github is not None and github.state == "newer":
        return WORDS["newer_ready"]
    if not settings.get("online", True):
        return WORDS["offline_by_choice"]
    if master is not None and master.state in ("behind", "different"):
        return WORDS["master_behind"]
    if any(d.state in ("behind", "different") for d in drives):
        return WORDS["drive_behind"]
    if settings.get("channel") == "testing":
        return WORDS["testing"]
    last = str(status.get("last_result") or "")
    if last in ("", "not-recorded", "never-checked") and github is not None and github.lines and github.lines[0] == WORDS["gh_never"]:
        return WORDS["not_checked"]
    return WORDS["all_good"]


def collect(system=None, sources: Optional[Sources] = None) -> Snapshot:
    system = system or System()
    sources = sources or Sources.from_env()
    status = run_json(system, "secure-linux-kit-update", ["status", "--tree", str(sources.tree), "--json"])
    auto = run_json(system, "secure-linux-kit-update-auto", ["status"])
    settings = read_settings(sources, status)
    computer = computer_row(sources, status, settings)
    rows = [computer, master_row(sources, computer.release_id)]
    rows += drive_rows(sources, computer.release_id)
    rows.append(github_row(status, auto, settings, computer.release_id))
    return Snapshot(rows=rows, headline=headline_for(rows, settings, status), settings=settings,
                    actions=build_actions(status, settings))


def settings_lines(settings: dict) -> List[str]:
    lines = [WORDS["settings_online_yes"] if settings.get("online", True) else WORDS["settings_online_no"],
             WORDS["settings_auto_yes"] if settings.get("auto_apply", True) else WORDS["settings_auto_no"],
             WORDS["settings_channel_testing"] if settings.get("channel") == "testing" else WORDS["settings_channel_stable"]]
    if settings.get("mirror"):
        lines.append(WORDS["settings_mirror_yes"])
    return lines


# ---------------------------------------------------------------- running a button

class Controller:
    """What the window calls. Headless, so tests can press every button."""

    def __init__(self, system=None, sources: Optional[Sources] = None):
        self.system = system or System()
        self.sources = sources or Sources.from_env()
        self.snapshot = collect(self.system, self.sources)

    def refresh(self) -> Snapshot:
        self.snapshot = collect(self.system, self.sources)
        return self.snapshot

    def action(self, key: str) -> Optional[Action]:
        return next((a for a in self.snapshot.actions if a.key == key), None)

    def press(self, key: str) -> ActionResult:
        action = self.action(key)
        if action is None:
            return ActionResult(False, WORDS["cancelled"], 2)
        if not action.enabled:
            return ActionResult(False, action.disabled_why or WORDS["cancelled"], 2)
        exe = self.system.resolve(action.argv[0])
        if not exe:
            return ActionResult(False, WORDS["not_installed"], 127)
        argv = [exe, *action.argv[1:]]
        if action.window:
            started = self.system.spawn(argv)
            return ActionResult(started, WORDS["opened"] if started else WORDS["not_installed"], 0 if started else 127)
        rc, out, err = self.system.run(argv, action.timeout)
        text = clean_output(out) or clean_output(err)
        self.refresh()
        if rc == 0:
            return ActionResult(True, text or WORDS["done"], 0)
        if rc == 75:
            return ActionResult(False, WORDS["busy"], 75)
        if rc in (126, 127) and not text:
            return ActionResult(False, WORDS["cancelled"], rc)
        return ActionResult(False, (text + "\n\n" if text else "") + WORDS["unfinished"], rc)


# ---------------------------------------------------------------- plain text view

def render_text(snapshot: Snapshot) -> str:
    out = [WORDS["title"], "", snapshot.headline, ""]
    for row in snapshot.rows:
        out.append(row.title)
        out += ["  " + line for line in row.lines]
        out.append("")
    out.append("Settings")
    out += ["  " + line for line in settings_lines(snapshot.settings)]
    out.append("")
    out.append("Buttons: " + ", ".join(a.label for a in snapshot.actions))
    return "\n".join(out) + "\n"


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args and args[0] in ("-h", "--help", "help"):
        print(__doc__.strip().split("\n\n")[0])
        print("  secure-linux-versions --text      print the screen as plain text")
        print("  secure-linux-versions --json      print the same facts as JSON")
        return 0
    snapshot = collect()
    if "--json" in args:
        print(json.dumps(snapshot.as_dict(), indent=2, sort_keys=True))
    else:
        sys.stdout.write(render_text(snapshot))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
