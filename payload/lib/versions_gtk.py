#!/usr/bin/env python3
"""GTK4/Libadwaita window for the Versions screen. It only shows what versions_model.py found and presses the
buttons the model lists; every command, every sentence and every safety rule lives in the model.
Matt's words only: no picture of Matt is used (plan question Q7 is still open)."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import threading

HERE = Path(__file__).resolve().parent
LIB_DIRS = [HERE, Path("/usr/local/lib/secure-linux/lib")]


def _load(name: str, filename: str):
    for folder in LIB_DIRS:
        path = folder / filename
        if path.is_file():
            spec = importlib.util.spec_from_file_location(name, path)
            module = importlib.util.module_from_spec(spec)
            sys.modules[name] = module
            assert spec.loader is not None
            spec.loader.exec_module(module)
            return module
    raise ImportError(f"cannot find {filename}")


model = _load("secure_linux_versions_model", "versions_model.py")
ui = _load("secure_linux_ui_gtk", "secure-ui-gtk.py")
Gtk = ui.Gtk
GLib = ui.GLib

STATE_PILL = {
    "current": ("UP TO DATE", "on"),
    "behind": ("OLDER", "off"),
    "different": ("DIFFERENT", "info"),
    "ahead": ("NEWER", "info"),
    "newer": ("NEWER READY", "info"),
    "missing": ("NONE", "info"),
    "unknown": ("NOT KNOWN", "info"),
    "info": ("INFO", "info"),
}


class VersionsWindow(ui.SecureShell):
    def __init__(self, application, controller):
        super().__init__(application, model.WORDS["title"], model.WORDS["subtitle"])
        self.controller = controller
        self.busy = False
        self.page = None
        self.action_buttons = {}
        self._build()

    def _build(self):
        page = ui.page_box()
        ui.add_heading(page, model.WORDS["title"], model.WORDS["subtitle"])
        snapshot = self.controller.snapshot
        self.headline = ui.label(snapshot.headline, css=("sl-section-title",))
        page.append(self.headline)
        self.rows_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        page.append(self.rows_box)
        page.append(ui.label("Settings", css=("sl-section-title",)))
        self.settings_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        page.append(self.settings_box)
        page.append(ui.label("What would you like to do?", css=("sl-section-title",)))
        self.actions_box = ui.flow_box()
        page.append(self.actions_box)
        self.status_label = ui.label("", css=("sl-caption",))
        page.append(self.status_label)
        self.add_page("versions", "Versions", "software-update-available-symbolic", page)
        self.navigate("versions")
        self._fill()

    def _fill(self):
        snapshot = self.controller.snapshot
        self.headline.set_label(snapshot.headline)
        for box in (self.rows_box, self.settings_box):
            child = box.get_first_child()
            while child is not None:
                following = child.get_next_sibling()
                box.remove(child)
                child = following
        for row in snapshot.rows:
            card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
            card.add_css_class("sl-status-card")
            head = ui.responsive_row(spacing=12)
            title = ui.label(row.title, css=("sl-card-title",))
            title.set_hexpand(True)
            head.append(title)
            text, kind = STATE_PILL.get(row.state, STATE_PILL["info"])
            pill = ui.status_pill(text, kind)
            head.append(pill)
            card.append(head)
            for line in row.lines:
                card.append(ui.label(line, css=("sl-body", "sl-muted")))
            ui.accessible(card, row.title, " ".join(row.lines))
            self.rows_box.append(card)
        for line in model.settings_lines(snapshot.settings):
            self.settings_box.append(ui.label(line, css=("sl-body",)))
        child = self.actions_box.get_first_child()
        while child is not None:
            following = child.get_next_sibling()
            self.actions_box.remove(child)
            child = following
        self.action_buttons = {}
        for action in snapshot.actions:
            card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
            card.add_css_class("sl-task-card")
            card.append(ui.label(action.label, css=("sl-card-title",)))
            card.append(ui.label(action.explain if action.enabled else action.disabled_why, css=("sl-body", "sl-muted")))
            press = ui.button(action.label, lambda key=action.key: self._pressed(key), primary=(action.key == "update_now"),
                              name=f"{action.label}: {action.explain}")
            press.set_sensitive(action.enabled and not self.busy)
            press.set_halign(Gtk.Align.START)
            card.append(press)
            self.actions_box.append(card)
            self.action_buttons[action.key] = press

    def _pressed(self, key):
        if self.busy:
            return
        action = self.controller.action(key)
        if action is None:
            return
        if action.confirm:
            ui.review_dialog(self, action.confirm, lambda: self._run(key))
        else:
            self._run(key)

    def _run(self, key):
        self.busy = True
        self.status_label.set_label("Working. You can keep this window open.")
        for press in self.action_buttons.values():
            press.set_sensitive(False)
        threading.Thread(target=self._worker, args=(key,), daemon=True).start()

    def _worker(self, key):
        result = self.controller.press(key)
        ui.idle(self._finished, key, result)

    def _finished(self, key, result):
        self.busy = False
        self.status_label.set_label("")
        action = self.controller.action(key)
        label = action.label if action else "Versions"
        self._fill()
        if key not in ("whats_new", "explain") or not result.ok:
            ui.message_dialog(self, label, result.text)


def main(argv=None) -> int:
    controller = model.Controller()
    def build(application):
        return VersionsWindow(application, controller)
    return ui.run_application("org.securelinux.Versions", build, [sys.argv[0]])


if __name__ == "__main__":
    raise SystemExit(main())
