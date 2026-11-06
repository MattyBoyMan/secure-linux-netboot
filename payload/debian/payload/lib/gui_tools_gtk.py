#!/usr/bin/env python3
"""Shared GTK4/Libadwaita task views and exact review gates.

This is presentation only. Engine commands, validation, verification and remote
behaviour remain in gui_tools_common and each application's backend adapter.
"""
from __future__ import annotations

import importlib.util
import queue
from pathlib import Path
import sys
from typing import Callable, Sequence

from gi.repository import Pango
from gui_tools_common import CommandRunner, CommandSpec, OperationResult, exact_review_valid

HERE = Path(__file__).resolve().parent


def load_ui():
    spec = importlib.util.spec_from_file_location("secure_linux_ui_gtk_tools", HERE / "secure-ui-gtk.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


ui = load_ui()
Adw = ui.Adw
Gdk = ui.Gdk
GLib = ui.GLib
Gtk = ui.Gtk


def card(title: str, description: str = "") -> Gtk.Box:
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
    box.add_css_class("sl-status-card")
    box.append(ui.label(title, css=("sl-card-title",)))
    if description:
        box.append(ui.label(description, css=("sl-body", "sl-muted")))
    return box


def advanced(title: str = "Advanced settings and technical details") -> tuple[Gtk.Expander, Gtk.Box]:
    expander = Gtk.Expander(label=title, expanded=False)
    caption = ui.label(title)
    caption.set_width_chars(1)
    caption.set_max_width_chars(32)
    caption.set_hexpand(True)
    expander.set_label_widget(caption)
    expander.set_size_request(-1, ui.design.MIN_TARGET_PX)
    ui.accessible(expander, title, "Collapsed by default. Expand only when you need advanced controls.")
    body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
    body.set_margin_top(12)
    expander.set_child(body)
    return expander, body


def entry(text: str = "", *, description: str = "", secret: bool = False,
          on_change: Callable[[str], None] | None = None) -> Gtk.Entry:
    widget = Gtk.Entry(text=text, hexpand=True)
    widget.set_width_chars(1)
    widget.set_size_request(-1, ui.design.MIN_TARGET_PX)
    if secret:
        widget.set_visibility(False)
    if on_change:
        widget.connect("changed", lambda item: on_change(item.get_text()))
    ui.accessible(widget, description or "Text value", description)
    return widget


def field(parent: Gtk.Box, title: str, widget: Gtk.Widget, description: str = "") -> None:
    row = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    row.append(ui.label(title, css=("sl-caption",)))
    row.append(widget)
    if description:
        row.append(ui.label(description, css=("sl-caption", "sl-muted")))
    parent.append(row)


def dropdown(values: Sequence[str], *, description: str, on_change: Callable[[str], None] | None = None) -> Gtk.DropDown:
    widget = Gtk.DropDown.new_from_strings(list(values))
    factory = Gtk.SignalListItemFactory()
    def setup(_factory, item):
        item.set_child(Gtk.Label(xalign=0, ellipsize=Pango.EllipsizeMode.END,
                                 width_chars=1, hexpand=True))
    def bind(_factory, item):
        item.get_child().set_label(item.get_item().get_string())
    factory.connect("setup", setup)
    factory.connect("bind", bind)
    widget.set_factory(factory)
    widget.set_size_request(-1, ui.design.MIN_TARGET_PX)
    widget.set_hexpand(True)
    ui.accessible(widget, description)
    if on_change:
        def changed(item, _param):
            selected = item.get_selected()
            if selected != Gtk.INVALID_LIST_POSITION and selected < len(values):
                on_change(values[selected])
        widget.connect("notify::selected", changed)
    return widget


def check(text: str, *, description: str = "") -> Gtk.CheckButton:
    widget = ui.check_button(text)
    widget.set_size_request(-1, ui.design.MIN_TARGET_PX)
    ui.accessible(widget, text, description)
    return widget


def text_view(text: str = "", *, height: int = 180, name: str = "Details") -> tuple[Gtk.ScrolledWindow, Gtk.TextView]:
    scroll = Gtk.ScrolledWindow(hexpand=True, vexpand=False)
    scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
    scroll.set_min_content_height(height)
    view = Gtk.TextView(editable=False, cursor_visible=False, wrap_mode=Gtk.WrapMode.WORD_CHAR)
    view.add_css_class("sl-review-text")
    for side in ("top", "bottom", "left", "right"):
        getattr(view, f"set_{side}_margin")(16)
    view.get_buffer().set_text(text)
    ui.accessible(view, name)
    scroll.set_child(view)
    return scroll, view


def set_text(view: Gtk.TextView, text: str) -> None:
    view.get_buffer().set_text(text)


def actions(*widgets: Gtk.Widget) -> Gtk.Box:
    box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
    for widget in widgets:
        box.append(widget)
    return box


def choose_path(parent: Gtk.Widget, callback: Callable[[str], None], *, folder: bool,
                title: str) -> Gtk.FileDialog:
    chooser = Gtk.FileDialog()
    chooser.set_title(title)
    chooser.set_modal(True)

    def finished(dialog, result):
        try:
            selected = dialog.select_folder_finish(result) if folder else dialog.open_finish(result)
        except Exception:
            return
        if selected is not None and selected.get_path():
            callback(selected.get_path())

    if folder:
        chooser.select_folder(parent.get_root(), None, finished)
    else:
        chooser.open(parent.get_root(), None, finished)
    return chooser


class NativeReviewDialog(Adw.Dialog):
    """Non-blocking modal review; cancellation and dismissal never call back."""

    def __init__(self, parent: Gtk.Widget, title: str, summary: str,
                 phrases: Sequence[str], callback: Callable[[str], None], *,
                 secret_label: str = "", initial_secret: str = "",
                 password_policy: bool = False, generate_secret: Callable[[], str] | None = None):
        super().__init__(title=title)
        self.set_content_width(700)
        self.set_content_height(700 if secret_label else 610)
        self.callback = callback
        self.phrases = tuple(phrases)
        self.accepted = False
        self.password_policy = password_policy
        toolbar = Adw.ToolbarView()
        header = Adw.HeaderBar()
        header.set_title_widget(Adw.WindowTitle(title=title, subtitle="Nothing has happened yet"))
        toolbar.add_top_bar(header)
        page = ui.page_box()
        for margin in (24,):
            page.set_margin_top(margin)
            page.set_margin_bottom(margin)
            page.set_margin_start(margin)
            page.set_margin_end(margin)
        scroll_body, summary_view = text_view(summary, height=190, name="Action to review")
        page.append(scroll_body)
        self.entries: list[Gtk.Entry] = []
        for index, phrase in enumerate(self.phrases, 1):
            phrase_entry = entry(description=f"Exact confirmation: {phrase}", on_change=lambda _text: self._check())
            self.entries.append(phrase_entry)
            field(page, f"Step {index}: type exactly  {phrase}", phrase_entry)
        self.secret_entry = None
        if secret_label:
            secret_row = ui.dialog_row(self)
            self.secret_entry = entry(initial_secret, description=secret_label, secret=True, on_change=lambda _text: self._check())
            secret_row.append(self.secret_entry)
            if generate_secret:
                secret_row.append(ui.button("Generate another", lambda: self._regenerate(generate_secret)))
            field(page, secret_label, secret_row,
                  "Hidden by default. Sent only through standard input; never added to command arguments or activity output.")
            show = check("Show the secret in this private review")
            show.connect("toggled", lambda item: self.secret_entry.set_visibility(item.get_active()))
            page.append(show)
        self.hint = ui.label("Cancel is safe. There is no countdown.", css=("sl-caption", "sl-muted"))
        page.append(self.hint)
        buttons = ui.dialog_row(self, homogeneous=True)
        cancel = ui.button("Cancel — change nothing", self.close)
        self.confirm = ui.button("Confirm reviewed action", primary=True)
        if any("ERASE" in phrase or "RESTORE" in phrase or "ROLLBACK" in phrase for phrase in self.phrases):
            self.confirm.add_css_class("destructive-action")
        self.confirm.set_sensitive(False)
        self.confirm.connect("clicked", lambda _button: self._accept())
        buttons.append(cancel)
        buttons.append(self.confirm)
        for margin in (24,):
            buttons.set_margin_start(margin)
            buttons.set_margin_end(margin)
            buttons.set_margin_bottom(margin)
        toolbar.add_bottom_bar(buttons)
        scroller = Gtk.ScrolledWindow(hexpand=True, vexpand=True)
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroller.set_min_content_height(240)
        scroller.set_child(page)
        toolbar.set_content(scroller)
        self.set_child(toolbar)
        self.connect("closed", self._closed)
        self.present(parent)
        (self.entries[0] if self.entries else self.secret_entry or self.confirm).grab_focus()
        self._check()

    def _regenerate(self, generator):
        self.secret_entry.set_text(generator())
        self._check()

    def _check(self):
        secret = self.secret_entry.get_text() if self.secret_entry is not None else ""
        valid = exact_review_valid(
            [item.get_text() for item in self.entries], self.phrases, secret,
            secret_required=self.secret_entry is not None,
            password_policy=self.password_policy,
        )
        self.confirm.set_sensitive(valid)

    def _accept(self):
        self._check()
        if not self.confirm.get_sensitive() or self.accepted:
            return
        self.accepted = True
        secret = self.secret_entry.get_text() if self.secret_entry is not None else ""
        if self.secret_entry is not None:
            self.secret_entry.set_text("")
        self.close()
        self.callback(secret)

    def _closed(self, _dialog):
        if self.secret_entry is not None:
            self.secret_entry.set_text("")


class NativeOperationWindow(ui.SecureShell):
    """Shared native activity view; subclasses add task pages then finish_pages."""

    app_title = "Secure Linux tool"
    app_subtitle = "Existing engines, clear reviews and honest results."
    application_id = "org.securelinux.Tool"

    def __init__(self, application, *, runner=None, demo=False):
        super().__init__(application, self.app_title, self.app_subtitle, demo=demo)
        self.events = queue.Queue()
        self.runner = runner or CommandRunner(self.events)
        self.last_result = None
        self.pending_kind = ""
        self.output_lines = []
        self.allow_close = False
        self.connect("close-request", self._close_request)

    def finish_pages(self, initial: str):
        page = ui.page_box()
        ui.add_heading(page, "Activity and results", "Engine output appears here after you explicitly approve an action. Secrets are redacted.")
        self.activity_label = ui.label("Ready. Choose a task.", css=("sl-card-title",))
        page.append(self.activity_label)
        self.progress = Gtk.ProgressBar(show_text=True)
        self.progress.set_size_request(-1, ui.design.MIN_TARGET_PX)
        ui.accessible(self.progress, "Operation progress")
        page.append(self.progress)
        self.cancel_button = ui.button("Stop current operation", self.cancel)
        self.cancel_button.set_sensitive(False)
        self.cancel_button.set_halign(Gtk.Align.START)
        page.append(self.cancel_button)
        scroll, self.output_view = text_view("No operation has run. Read-only inspection never means erase.\n", height=300, name="Redacted engine activity")
        page.append(scroll)
        page.append(ui.button("Clear activity", self.clear_output))
        self.add_page("activity", "Activity", "utilities-terminal-symbolic", page)
        self.navigate(initial)
        GLib.timeout_add(100, self._poll)

    def review(self, title: str, summary: str, phrases: Sequence[str], callback: Callable[[str], None], **kwargs):
        return NativeReviewDialog(self, title, summary, phrases, callback, **kwargs)

    def notify(self, title: str, detail: str):
        return ui.message_dialog(self, title, detail)

    def append_output(self, text: str):
        self.output_lines.append(text)
        set_text(self.output_view, "\n".join(self.output_lines))

    def clear_output(self):
        self.output_lines = []
        set_text(self.output_view, "")

    def run(self, spec: CommandSpec, pending: str = "") -> bool:
        if self.demo:
            self.notify("Preview only", "No engine, drive, network or server command can run in preview mode.")
            return False
        if self.runner.busy:
            self.notify("Operation already running", "Wait for the current engine result before starting another task.")
            return False
        self.last_result = None
        self.pending_kind = pending
        self.activity_label.set_label(f"Running: {spec.title}")
        self.progress.set_fraction(0)
        self.progress.set_text("Working — no verification yet")
        self.progress.set_show_text(True)
        self.progress.remove_css_class("sl-verified")
        self.progress.pulse()
        self.cancel_button.set_sensitive(True)
        self.runner.start(spec)
        self.navigate("activity")
        return True

    def cancel(self):
        if not self.runner.cancel():
            self.activity_label.set_label("No running operation to stop.")

    def _poll(self):
        try:
            while True:
                kind, value, detail = self.events.get_nowait()
                if kind == "started":
                    self.append_output(f"\n=== {value} ===")
                elif kind == "output":
                    self.append_output(str(value))
                elif kind == "progress":
                    if value is None:
                        self.progress.pulse()
                    else:
                        self.progress.set_fraction(value / 100)
                        self.progress.set_text(f"{value}%" + (f" — ETA {detail}" if detail else ""))
                elif kind == "finished":
                    self._finished(value, detail)
        except queue.Empty:
            pass
        return True

    def _finished(self, result: OperationResult, output: str):
        self.last_result = result
        self.cancel_button.set_sensitive(False)
        self.activity_label.set_label(result.message)
        self.append_output(f"RESULT: {result.state.upper()} — {result.message}")
        self.progress.set_text(result.state.upper())
        if result.state == "verified":
            self.progress.set_fraction(1)
        self.pending_kind = ""

    def _close_request(self, _window):
        if self.allow_close or not self.runner.busy:
            return False
        def confirmed(_secret):
            self.allow_close = True
            self.runner.cancel()
            self.close()
        self.review("Stop before closing?",
            "An operation is still running. Closing requests cancellation. Any copy, repair or remote change may be incomplete and unverified.",
            ("Confirm",), confirmed)
        return True


def run_native(window_type, application_id: str, argv: list[str], **kwargs) -> int:
    return ui.run_application(application_id, lambda app: window_type(app, **kwargs), argv)
