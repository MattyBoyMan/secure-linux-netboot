#!/usr/bin/env python3
"""My Computer Activity — offline, read-only graphical dashboard."""

from pathlib import Path
import argparse
import os
import subprocess
import sys


def _module_path() -> Path:
    here = Path(__file__).resolve()
    candidates = [
        here.parent.parent / "lib",                         # source tree
        Path("/usr/local/lib/secure-linux/lib"),          # installed kit
        Path(os.environ.get("SL_ROOT", "/nonexistent")) / "lib",
    ]
    for candidate in candidates:
        if (candidate / "activity.py").is_file() and (candidate / "activity_gui.py").is_file():
            return candidate
    return candidates[0]


def _graphical_dependency_error(message: str) -> None:
    """Keep the primary interface graphical when native packages are unavailable."""
    text = (
        "My Computer Activity could not open its graphical window.\n\n"
        + message
        + "\n\nNothing was changed, collected or sent anywhere. "
        + "Install python3-gobject, gtk4 and libadwaita on Fedora, or python3-gi, "
        + "gir1.2-gtk-4.0 and gir1.2-adw-1 on Debian, then try again."
    )
    for command in (["zenity", "--error", "--no-markup", "--title=My Computer Activity", "--width=520", "--text=" + text],
                    ["kdialog", "--title", "My Computer Activity", "--error", text]):
        try:
            subprocess.run(command, stdin=subprocess.DEVNULL, timeout=20, check=False)
            return
        except (OSError, subprocess.TimeoutExpired):
            continue
    print(text, file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description="Offline, read-only My Computer Activity graphical dashboard")
    parser.add_argument("--demo", action="store_true", help=argparse.SUPPRESS)  # visual-test fixture only
    args = parser.parse_args()
    library = _module_path()
    if str(library) not in sys.path:
        sys.path.insert(0, str(library))
    try:
        from activity_gui import main as gui_main
    except (ImportError, ModuleNotFoundError, ValueError) as exc:
        _graphical_dependency_error(f"The native GTK4/Libadwaita toolkit is unavailable ({exc}).")
        return 1
    try:
        return gui_main(demo=args.demo)
    except Exception as exc:
        # Native initialization errors (for example no desktop display) stay honest.
        if exc.__class__.__module__.startswith("gi"):
            _graphical_dependency_error(f"No graphical desktop is available ({exc}).")
            return 1
        raise


if __name__ == "__main__":
    raise SystemExit(main())
