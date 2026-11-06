#!/usr/bin/env python3
"""Dependency-checked entry point for native GTK4/Libadwaita frontends."""
from __future__ import annotations

import argparse
import subprocess
import sys


def graphical_error(title: str, detail: str) -> None:
    text = (f"{title} could not open its graphical window.\n\n{detail}\n\n"
            "Install python3-gobject, gtk4 and libadwaita on Fedora, or python3-gi, "
            "gir1.2-gtk-4.0 and gir1.2-adw-1 on Debian, then try again. "
            "Nothing was changed, erased, installed or contacted.")
    for command in (["zenity", "--error", "--no-markup", f"--title={title}", "--width=560", "--text=" + text],
                    ["kdialog", "--title", title, "--error", text]):
        try:
            subprocess.run(command, stdin=subprocess.DEVNULL, timeout=20, check=False)
            return
        except (OSError, subprocess.TimeoutExpired):
            continue
    print(text, file=sys.stderr)


def check_native(title: str) -> bool:
    try:
        import gi
        gi.require_version("Gtk", "4.0")
        gi.require_version("Adw", "1")
        from gi.repository import Adw, Gtk  # noqa: F401
        return True
    except (ImportError, ModuleNotFoundError, ValueError) as exc:
        graphical_error(title, f"The native GTK4/Libadwaita graphical toolkit is unavailable ({exc}).")
        return False


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--app", choices=("usb", "home"), required=True)
    args, remaining = parser.parse_known_args()
    title = "Secure Linux USB Workshop" if args.app == "usb" else "Home & Server Studio"
    if not check_native(title):
        return 1
    if args.app == "usb":
        from usb_tools_gui import main as gui_main
    else:
        from home_server_gui import main as gui_main
    return gui_main(remaining)


if __name__ == "__main__":
    raise SystemExit(main())
