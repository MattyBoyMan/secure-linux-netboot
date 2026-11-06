#!/usr/bin/env python3
"""One accessible, scrollable screen for the five-screen Secure Linux wizard.

The screen specification and all answers travel over stdin/stdout. Passwords are
never command-line arguments, files, log messages or review text. The scripted
mode uses defaults, with optional per-screen JSON fixtures for journey tests.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import sys
from typing import Any

RECOMMENDED = ("firewall", "opensnitch", "dns", "updates", "clamav", "fail2ban", "screen_lock")
SECURITY_LABELS = {
    "firewall": "Firewall", "opensnitch": "App network protection", "dns": "Secure DNS",
    "vpn": "VPN private mode", "updates": "Automatic security updates", "clamav": "Weekly virus scans",
    "usbguard": "USBGuard (advanced; can block devices)", "fail2ban": "Login protection",
    "screen_lock": "Automatic screen lock", "auditd": "Security audit log",
}


def field(kind: str, name: str, label: str, default: Any = None, **extra: Any) -> dict[str, Any]:
    answer = {"type": kind, "name": name, "label": label, "default": default}
    answer.update(extra)
    return answer


def options(values: list[tuple[str, str]]) -> list[dict[str, str]]:
    return [{"value": value, "label": label} for value, label in values]


def build_spec(key: str, context: dict[str, Any], values: dict[str, Any], review: str) -> dict[str, Any]:
    profile = context.get("profile", "full")
    profile_name = {"full": "Full desktop (recommended for this computer)", "atomic": "Atomic desktop", "lite": "Light desktop"}.get(profile, profile)
    fields: list[dict[str, Any]] = []
    title = ""
    text = ""
    confirm = "Next"
    if key == "system":
        title = "1 of 5 — Your recommended setup"
        text = "The automatic scan is complete. These safe steps are pre-ticked; untick any you do not want. Nothing changes until the final Confirm."
        fields = [
            field("info", "recommendation", "Recommended system", profile_name),
            field("info", "scan", "Scan summary", context.get("scan_summary", "Your hardware and existing settings were checked automatically.")),
            field("info", "encryption", "Disk encryption and installer safety", context.get("encryption", "Encryption, backup checks and any disk/erase decision remain explicit installer gates. This wizard never selects or erases a disk.")),
            field("checklist", "steps", "Set up for me", ["browser", "apps", "security", "backup", "recovery"], options=[
                ("browser", "Private browser and sensible desktop settings"),
                ("apps", "Recommended applications and app gap-fill"),
                ("security", "Recommended protection (customise on the next screens)"),
                ("backup", "Backup choices and a reminder when no backup is configured"),
                ("recovery", "Disk recovery key when this disk is encrypted"),
                ("battery", "Battery charge limit when this hardware supports it"),
                ("hardware", "Automatic hardware health check"),
            ]),
        ]
    elif key == "identity":
        title = "2 of 5 — You, Wi-Fi and passwords"
        text = "Your login already exists. Leave the password fields blank to keep its current password. Optional migrations are off by default."
        wifi = [("skip", "Leave Wi-Fi unchanged")]
        if context.get("ssid"):
            wifi.insert(0, ("home", f"Trust “{context['ssid']}” as my home Wi-Fi"))
        if context.get("wifi_saved"):
            wifi.insert(0, ("saved", "Import all Wi-Fi networks saved from Windows"))
        fields = [
            field("text", "full_name", "Your name", context.get("full_name", context.get("login", "")), required=True),
            field("text", "login", "Login name", context.get("login", ""), readonly=True,
                  help="The active login is kept: renaming a signed-in account could damage its session."),
            field("password", "password", "New login password (optional; at least 6 characters)", ""),
            field("password", "password_confirm", "Type the new password again", ""),
            field("radio", "wifi_mode", "Wi-Fi", "home" if context.get("ssid") else ("saved" if context.get("wifi_saved") else "skip"), options=wifi),
            field("password", "wifi_pin", "PIN for the saved Windows Wi-Fi record (only if it has one)", "",
                  help="Used only in memory to open the existing protected Wi-Fi record; never written to a journal."),
            field("radio", "password_manager", "Optional saved-password migration", "none", options=[
                ("none", "Skip — available later under Move My Passwords"),
                ("bitwarden", "Prepare Bitwarden migration"),
                ("keepassxc", "Install KeePassXC (no cloud)"),
            ]),
            field("text", "password_csv", "Optional exported password CSV path", "",
                  help="The file is not read or copied by this wizard. Import and deletion remain confirmed in the password tool."),
            field("check", "bookmarks", "Import bookmarks from the Windows backup", False),
        ]
    elif key == "apps":
        title = "3 of 5 — Applications and protection"
        text = "Choose familiar apps and a protection level. Every recommended app and protection switch can be unticked; manual unticks are shown as Custom and listed again in the review."
        fields = [
            field("radio", "email_client", "Email", "thunderbird", options=[
                ("thunderbird", "Thunderbird (recommended)"), ("betterbird", "Betterbird"), ("none", "No desktop email app"),
            ]),
            field("radio", "office", "Office documents", "libreoffice", options=[
                ("libreoffice", "LibreOffice (already recommended)"), ("onlyoffice", "Add OnlyOffice"), ("both", "Use both"),
            ]),
            field("radio", "notes_app", "Notes", "joplin", options=[
                ("joplin", "Joplin"), ("obsidian", "Obsidian"), ("both", "Both"),
            ]),
        ]
        recommendations = context.get("app_recommendations", [])
        if recommendations:
            fields.append(field("checklist", "extra_apps", "Apps found by the automatic old-app scan", [x["id"] for x in recommendations],
                                options=[(x["id"], x["label"]) for x in recommendations]))
        else:
            fields.append(field("info", "app_scan", "Old-app gap-fill", context.get("app_scan_message", "No unread old-app list was found. The automatic gap-fill remains available later; nothing is hidden in a bundle.")))
        if context.get("app_gaps"):
            fields.append(field("info", "app_gaps", "Honest gaps (no replacement is claimed)", "\n".join(context["app_gaps"])))
        fields.extend([
            field("radio", "security_profile", "Protection level", "recommended", options=[
                ("recommended", "Recommended — everyday protection"),
                ("stricter", "Stricter — also VPN private mode and audit log"),
                ("custom", "Custom — keep current settings, then untick or tick below"),
            ]),
            field("checklist", "security", "Protection switches (untick anything you do not want)",
                  [name for name in RECOMMENDED if name in context.get("security_features", RECOMMENDED)],
                  options=[(name, SECURITY_LABELS[name]) for name in context.get("security_features", RECOMMENDED)],
                  profile_field="security_profile"),
            field("radio", "backup_target", "Backup destination", "usb", options=[
                ("usb", "USB drive (simplest)"), ("server", "Home server"), ("later", "Not now — keep the backup reminder"),
            ]),
        ])
    elif key == "extras":
        title = "4 of 5 — Optional extras"
        text = "This screen is safe to skip. Expand only if you want home/server, AI, Flipper, migration or advanced extras. Every skipped item remains available after installation."
        docker_options = [("no", "Do not install Docker")]
        if context.get("docker_ok"):
            docker_options.insert(0, ("yes", "Install Docker after re-checking the hardware gate"))
        fields = [
            field("check", "extras_open", "Show optional extras", False),
            field("radio", "home_assistant", "Home / smart home", "none", when="extras_open", options=[
                ("none", "Skip Home Assistant"), ("existing", "Connect an existing Home Assistant"),
                ("practice", "Prepare a private practice copy"), ("guided", "Open guided server setup later"),
            ]),
            field("text", "ha_url", "Home Assistant address (existing server only)", context.get("ha_url", "http://homeassistant.local:8123"), when="extras_open"),
            field("check", "local_ai", "Download private on-device AI models (large download)", False, when="extras_open"),
            field("check", "flipper", "Open Flipper Zero Backup & Files after setup", False, when="extras_open"),
            field("radio", "docker", "Home server / Docker", "no", when="extras_open", options=options(docker_options),
                  help=context.get("docker_reason", "Docker is optional and its hardware gate is checked again before installation.")),
            field("check", "fleet", "Join an existing home fleet (optional; stand-alone is the default)", False, when="extras_open"),
            field("checklist", "meetings", "Calls and chat", [], when="extras_open", options=[
                ("vesktop", "Discord (Vesktop)"), ("teams", "Microsoft Teams web app"), ("zoom", "Zoom web app"),
            ]),
            field("checklist", "accessibility", "Accessibility", [], when="extras_open", options=[
                ("orca", "Screen reader"), ("dyslexia", "OpenDyslexic font"), ("captions", "Offline live captions"),
            ]),
            field("radio", "display_scale", "Display size", "100", when="extras_open", options=[
                ("100", "100%"), ("125", "125%"), ("150", "150%"), ("175", "175%"), ("200", "200%"),
            ]),
            field("radio", "hibernate", "Lid / hibernation", "no", when="extras_open", options=[
                ("no", "Keep current safe sleep behaviour"), ("on-lid", "Hibernate when lid closes"),
                ("sleep-then-hibernate", "Sleep first, then hibernate"),
            ]),
            field("check", "drm", "Enable streaming DRM in LibreWolf", False, when="extras_open"),
            field("check", "game_saves", "Install Ludusavi for game-save backups", False, when="extras_open"),
            field("check", "android_dev", "Install Android Studio and phone developer tools", False, when="extras_open"),
            field("check", "conda", "Install Conda and recreate exported environments", False, when="extras_open"),
            field("radio", "matlab", "MATLAB", "none", when="extras_open", options=[
                ("none", "Neither"), ("octave", "GNU Octave"), ("official", "Official MATLAB"), ("both", "Both"),
            ]),
            field("check", "extras_tools", "Install the advanced tools pack", False, when="extras_open"),
            field("check", "extras_apps", "Install everyday extra apps", False, when="extras_open"),
            field("check", "onedrive", "Copy OneDrive files without deleting the cloud copy", False, when="extras_open"),
            field("check", "photos", "Open the Google Photos to Immich migration tool", False, when="extras_open"),
            field("check", "printer", "Open printer setup", False, when="extras_open"),
            field("check", "emergency", "Create an emergency recovery kit", False, when="extras_open"),
            field("check", "family", "Set up family / visitor accounts", False, when="extras_open"),
            field("check", "tips", "Show one short beginner tip each day for two weeks", False, when="extras_open"),
        ]
    elif key == "review":
        title = "5 of 5 — Review everything"
        text = "Nothing has changed yet. Read every selected step and every reduction. Confirm starts the enabled steps; Back changes answers; closing cancels the whole setup. There is no countdown."
        fields = [field("info", "review", "Complete review", review),
                  field("check", "confirm", "I have reviewed the steps above, including anything switched off", False)]
        confirm = "Confirm & set up"
    else:
        raise ValueError(f"unknown screen: {key}")

    # Debian exposes only routes its own helpers can really apply. Fedora's full optional
    # catalogue is unchanged; unsupported choices are not shown and can never become no-ops.
    if context.get("distro") == "debian":
        if key == "system":
            steps = next(item for item in fields if item["name"] == "steps")
            steps["options"] = options([opt for opt in steps["options"] if opt[0] != "battery"])
        elif key == "identity":
            wifi = next(item for item in fields if item["name"] == "wifi_mode")
            wifi["options"] = options([opt for opt in wifi["options"] if opt[0] != "home"])
            wifi["default"] = "saved" if context.get("wifi_saved") else "skip"
            fields = [item for item in fields if item["name"] not in {"password_manager", "password_csv", "bookmarks"}]
            text = "Your login already exists. Leave the password fields blank to keep its current password. Wi-Fi import is optional."
        elif key == "apps":
            fields = [item for item in fields if item["name"] not in {"email_client", "office", "notes_app"}]
            fields.insert(0, field("info", "included_apps", "Included everyday apps",
                                   "Firefox / LibreWolf, Thunderbird, LibreOffice (or lighter office apps on low-memory PCs), VLC and Bitwarden are selected by the Debian setup."))
            text = "Review optional old-app additions, backups and protection. Every protection switch can be unticked; reductions appear again in the review."
        elif key == "extras":
            supported = {"extras_open", "home_assistant", "ha_url", "docker", "fleet"}
            fields = [item for item in fields if item["name"] in supported]
            home = next(item for item in fields if item["name"] == "home_assistant")
            home["options"] = options([opt for opt in home["options"] if opt[0] != "practice"])
            text = "This screen is safe to skip. Expand it only for Home Assistant, Docker or an existing home fleet. Other Debian tools remain available in their own guides."

    for item in fields:
        name = item["name"]
        if name in values and item["type"] not in {"info", "password"}:
            item["default"] = values[name]
    return {"key": key, "title": title, "text": text, "confirm": confirm,
            "back": key != "system", "fields": fields}


def defaults(spec: dict[str, Any]) -> dict[str, Any]:
    result = {}
    for item in spec["fields"]:
        if item["type"] != "info":
            result[item["name"]] = item.get("default")
    return result


def scripted(spec: dict[str, Any]) -> dict[str, Any] | None:
    if not os.environ.get("SL_WIZARD_ANSWERS"):
        return None
    answer = defaults(spec)
    if spec["key"] == "review":
        answer["confirm"] = True  # scripted journeys explicitly exercise the apply phase
    fixture_dir = os.environ.get("SL_WIZARD_ANSWER_DIR")
    mode = "defaults"
    if fixture_dir:
        fixture = Path(fixture_dir) / f"{spec['key']}.json"
        if fixture.is_file():
            override = json.loads(fixture.read_text(encoding="utf-8"))
            if override.get("__action") in {"cancel", "back"}:
                return override
            answer.update(override)
            mode = "fixture"
    print(f"UI[{spec['key']}] -> {mode}", file=sys.stderr)
    return answer


def terminal(spec: dict[str, Any]) -> dict[str, Any]:
    answer = defaults(spec)
    print(f"\n=== {spec['title']} ===\n{spec['text']}")
    for item in spec["fields"]:
        if item["type"] == "info":
            print(f"\n{item['label']}:\n{item['default']}")
        elif item["type"] == "checklist":
            print(f"\n{item['label']}: {', '.join(item.get('default') or []) or 'none'}")
            for opt in item.get("options", []):
                print(f"  {opt['value']}: {opt['label']}")
        elif item["type"] == "radio":
            print(f"\n{item['label']}: {item.get('default')}")
            for opt in item.get("options", []):
                print(f"  {opt['value']}: {opt['label']}")
        elif item["type"] != "password":
            print(f"\n{item['label']}: {item.get('default') or ''}")
    print("\nPress Enter to accept this screen, B for Back, E to edit non-secret fields, or Q to cancel.")
    choice = input("> ").strip().lower()
    if choice == "q":
        return {"__action": "cancel"}
    if choice == "b" and spec["back"]:
        return {"__action": "back"}
    if choice == "e":
        import getpass
        for item in spec["fields"]:
            kind, name = item["type"], item["name"]
            if kind == "info" or item.get("readonly"):
                continue
            if kind == "password":
                value = getpass.getpass(f"{item['label']} [blank keeps current]: ")
            else:
                value = input(f"{item['label']} [{answer.get(name) or ''}]: ").strip()
                if not value:
                    continue
                if kind == "check":
                    value = value.lower() in {"1", "yes", "y", "true", "on"}
                elif kind == "checklist":
                    value = [x.strip() for x in value.split(",") if x.strip()]
            answer[name] = value
    return answer


def graphical(spec: dict[str, Any]) -> dict[str, Any]:
    import tkinter as tk
    from tkinter import messagebox, ttk

    root = tk.Tk()
    root.title(spec["title"])
    root.geometry("860x760")
    root.minsize(640, 520)
    result: dict[str, Any] = {"__action": "cancel"}
    variables: dict[str, Any] = {}
    frames: dict[str, Any] = {}
    checks: dict[str, list[tuple[str, Any]]] = {}

    style = ttk.Style(root)
    if "clam" in style.theme_names():
        style.theme_use("clam")
    root.columnconfigure(0, weight=1)
    root.rowconfigure(2, weight=1)
    ttk.Label(root, text=spec["title"], font=("TkDefaultFont", 18, "bold"), wraplength=800).grid(row=0, column=0, sticky="ew", padx=24, pady=(22, 5))
    ttk.Label(root, text=spec["text"], wraplength=800, justify="left").grid(row=1, column=0, sticky="ew", padx=24, pady=(0, 14))

    canvas = tk.Canvas(root, highlightthickness=0)
    scroll = ttk.Scrollbar(root, orient="vertical", command=canvas.yview)
    body = ttk.Frame(canvas, padding=24)
    window = canvas.create_window((0, 0), window=body, anchor="nw")
    canvas.configure(yscrollcommand=scroll.set)
    canvas.grid(row=2, column=0, sticky="nsew", padx=(10, 0))
    scroll.grid(row=2, column=1, sticky="ns")
    body.columnconfigure(0, weight=1)
    body.bind("<Configure>", lambda _e: canvas.configure(scrollregion=canvas.bbox("all")))
    canvas.bind("<Configure>", lambda e: canvas.itemconfigure(window, width=e.width))
    canvas.bind("<Button-4>", lambda _e: canvas.yview_scroll(-2, "units"))
    canvas.bind("<Button-5>", lambda _e: canvas.yview_scroll(2, "units"))
    canvas.bind("<MouseWheel>", lambda e: canvas.yview_scroll(-1 if e.delta > 0 else 1, "units"))

    def refresh_visibility() -> None:
        for item in spec["fields"]:
            when = item.get("when")
            if when and when in variables and not variables[when].get():
                frames[item["name"]].grid_remove()
            else:
                frames[item["name"]].grid()

    def profile_changed() -> None:
        profile = variables.get("security_profile")
        if not profile or "security" not in checks:
            return
        selected = set(RECOMMENDED)
        if profile.get() == "stricter":
            selected.update(("vpn", "auditd"))
        elif profile.get() == "custom":
            return
        for name, var in checks["security"]:
            var.set(name in selected)

    for row, item in enumerate(spec["fields"]):
        kind, name = item["type"], item["name"]
        frame = ttk.LabelFrame(body, text=item["label"], padding=12)
        frame.grid(row=row, column=0, sticky="ew", pady=5)
        frame.columnconfigure(0, weight=1)
        frames[name] = frame
        if kind == "info":
            label = ttk.Label(frame, text=str(item.get("default") or ""), wraplength=730, justify="left")
            label.grid(row=0, column=0, sticky="ew")
        elif kind in {"text", "password"}:
            var = tk.StringVar(value=str(item.get("default") or ""))
            variables[name] = var
            entry = ttk.Entry(frame, textvariable=var, show="•" if kind == "password" else "")
            entry.grid(row=0, column=0, sticky="ew")
            if item.get("readonly"):
                entry.state(["readonly"])
        elif kind == "check":
            var = tk.BooleanVar(value=bool(item.get("default")))
            variables[name] = var
            ttk.Checkbutton(frame, text="Enabled", variable=var, command=refresh_visibility).grid(row=0, column=0, sticky="w")
        elif kind == "radio":
            var = tk.StringVar(value=str(item.get("default") or ""))
            variables[name] = var
            for index, opt in enumerate(item.get("options", [])):
                ttk.Radiobutton(frame, text=opt["label"], value=opt["value"], variable=var,
                                command=profile_changed if name == "security_profile" else None).grid(row=index, column=0, sticky="w")
        elif kind == "checklist":
            initial = set(item.get("default") or [])
            checks[name] = []
            for index, opt in enumerate(item.get("options", [])):
                var = tk.BooleanVar(value=opt["value"] in initial)
                checks[name].append((opt["value"], var))
                command = None
                if name == "security":
                    def command() -> None:
                        if "security_profile" in variables:
                            variables["security_profile"].set("custom")
                ttk.Checkbutton(frame, text=opt["label"], variable=var, command=command).grid(row=index, column=0, sticky="w")
        if item.get("help"):
            ttk.Label(frame, text=item["help"], wraplength=730, justify="left", foreground="#526575").grid(row=100, column=0, sticky="ew", pady=(7, 0))

    buttons = ttk.Frame(root, padding=18)
    buttons.grid(row=3, column=0, columnspan=2, sticky="ew")
    buttons.columnconfigure(1, weight=1)

    def collect() -> dict[str, Any] | None:
        answer: dict[str, Any] = {}
        for item in spec["fields"]:
            kind, name = item["type"], item["name"]
            if kind == "info":
                continue
            if kind == "checklist":
                answer[name] = [value for value, var in checks[name] if var.get()]
            else:
                answer[name] = variables[name].get()
        if answer.get("password") != answer.get("password_confirm"):
            messagebox.showerror("Passwords do not match", "Type the same new password twice, or leave both blank.", parent=root)
            return None
        if answer.get("password") and len(answer["password"]) < 6:
            messagebox.showerror("Password too short", "Use at least 6 characters, or leave both fields blank.", parent=root)
            return None
        if not answer.get("full_name", "ok"):
            messagebox.showerror("Name needed", "Enter your name, or close the wizard to cancel.", parent=root)
            return None
        if spec["key"] == "review" and not answer.get("confirm"):
            messagebox.showinfo("Review required", "Tick the review confirmation only after reading every step.", parent=root)
            return None
        return answer

    def accept() -> None:
        nonlocal result
        value = collect()
        if value is not None:
            result = value
            root.destroy()

    def back() -> None:
        nonlocal result
        result = {"__action": "back"}
        root.destroy()

    ttk.Button(buttons, text="Cancel", command=root.destroy).grid(row=0, column=0, sticky="w")
    if spec["back"]:
        ttk.Button(buttons, text="Back", command=back).grid(row=0, column=1, sticky="e", padx=8)
    ttk.Button(buttons, text=spec["confirm"], command=accept).grid(row=0, column=2, sticky="e")
    root.protocol("WM_DELETE_WINDOW", root.destroy)
    refresh_visibility()
    root.mainloop()
    return result


def main() -> int:
    key = sys.argv[1]
    context = json.loads(os.environ.get("SL_WIZARD_CONTEXT", "{}"))
    values = json.loads(os.environ.get("SL_WIZARD_VALUES", "{}"))
    spec = build_spec(key, context, values, os.environ.get("SL_WIZARD_REVIEW", ""))
    answer = scripted(spec)
    if answer is None:
        if os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"):
            try:
                answer = graphical(spec)
            except Exception as exc:
                print(f"Graphical screen unavailable ({type(exc).__name__}); using the terminal screen.", file=sys.stderr)
                answer = terminal(spec)
        else:
            answer = terminal(spec)
    print(json.dumps(answer, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
