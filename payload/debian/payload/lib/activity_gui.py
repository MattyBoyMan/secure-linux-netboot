#!/usr/bin/env python3
"""Native GTK4/Libadwaita view for My Computer Activity."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
from typing import Any

from activity_controller import ActivityController, ExportReviewController, STATUS_WORDS, details_text

HERE = Path(__file__).resolve().parent


def load_ui():
    spec = importlib.util.spec_from_file_location("secure_linux_ui_gtk", HERE / "secure-ui-gtk.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


ui = load_ui()
Gtk = ui.Gtk
GLib = ui.GLib


def text_view(text: str, name: str, *, height: int = 180) -> Gtk.ScrolledWindow:
    scroll = Gtk.ScrolledWindow(hexpand=True)
    scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
    scroll.set_min_content_height(height)
    view = Gtk.TextView(editable=False, cursor_visible=False, wrap_mode=Gtk.WrapMode.WORD_CHAR)
    view.get_buffer().set_text(text)
    view.add_css_class("sl-review-text")
    for side in ("top", "bottom", "left", "right"):
        getattr(view, f"set_{side}_margin")(12)
    ui.accessible(view, name, "Read-only text; select and press Control+C to copy")
    scroll.set_child(view)
    scroll.text_view = view
    return scroll


class ExportDialog:
    """Modal privacy review. Saving happens only after an explicit destination."""

    def __init__(self, window: "ActivityWindow", review: ExportReviewController) -> None:
        self.window = window
        self.review = review
        self.dialog = ui.Adw.Dialog(title="Review privacy-safe activity report")
        self.dialog.set_content_width(780)
        self.dialog.set_content_height(720)
        toolbar = ui.Adw.ToolbarView()
        header = ui.Adw.HeaderBar()
        header.set_title_widget(ui.Adw.WindowTitle(title="Review before you share", subtitle="Nothing has been saved yet"))
        toolbar.add_top_bar(header)
        page = ui.page_box()
        for margin in (24,):
            page.set_margin_top(margin)
            page.set_margin_bottom(margin)
            page.set_margin_start(margin)
            page.set_margin_end(margin)
        page.append(ui.label("Check the preview, then choose exactly where to save the offline HTML report.", css=("sl-body", "sl-muted")))
        options = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        options.add_css_class("sl-status-card")
        options.append(ui.label("Privacy redaction — all on by default", css=("sl-card-title",)))
        self.toggles = {}
        for key, text in (
            ("usernames", "Redact account/user names and home-folder names"),
            ("addresses", "Redact IP and device addresses"),
            ("tokens", "Redact passwords, tokens and secrets"),
        ):
            toggle = ui.check_button(text, active=True)
            toggle.set_size_request(-1, ui.design.MIN_TARGET_PX)
            ui.accessible(toggle, text)
            toggle.connect("toggled", self._changed)
            options.append(toggle)
            self.toggles[key] = toggle
        page.append(options)
        self.warning = ui.label(review.warning, css=("sl-caption",))
        page.append(self.warning)
        self.preview = text_view(review.preview, "Privacy-safe report preview", height=300)
        self.preview.set_vexpand(True)
        page.append(self.preview)
        actions = ui.dialog_row(self.dialog, homogeneous=True)
        actions.add_css_class("sl-dialog-actions")
        cancel = ui.button("Cancel — save nothing", self.dialog.close)
        save = ui.button("Choose location & save…", self.save, primary=True)
        actions.append(cancel)
        actions.append(save)
        for margin in (24,):
            actions.set_margin_start(margin)
            actions.set_margin_end(margin)
            actions.set_margin_bottom(margin)
        toolbar.add_bottom_bar(actions)
        scroll = Gtk.ScrolledWindow(hexpand=True, vexpand=True)
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_min_content_height(320)
        scroll.set_child(page)
        toolbar.set_content(scroll)
        self.dialog.set_child(toolbar)
        self.dialog.present(window)
        cancel.grab_focus()

    def _changed(self, _widget) -> None:
        self.review.set_redaction(**{key: toggle.get_active() for key, toggle in self.toggles.items()})
        self.preview.text_view.get_buffer().set_text(self.review.preview)
        self.warning.set_label(self.review.warning)

    def save(self) -> None:
        chooser = Gtk.FileDialog()
        chooser.set_title("Save reviewed activity report")
        chooser.set_initial_name("my-computer-activity.html")
        chooser.save(self.window, None, self._save_finished)

    def _save_finished(self, chooser, result) -> None:
        try:
            selected = chooser.save_finish(result)
            if selected is None or not selected.get_path():
                return
            self.review.save(selected.get_path())
        except Exception as exc:
            # File/dialog errors contain no collected report content.
            ui.message_dialog(self.window, "Report not saved", f"The report could not be saved:\n{exc}")
            return
        self.dialog.close()
        ui.message_dialog(self.window, "Report saved", "The reviewed report was saved locally. No copy was uploaded or sent anywhere.")


class ActivityWindow(ui.SecureShell):
    def __init__(self, application, controller: ActivityController) -> None:
        super().__init__(application, "My Computer Activity", "Local, read-only and easy to review", demo=controller.demo)
        self.controller = controller
        self.cards = []
        self._build_overview()
        self._build_privacy()
        self.navigate("overview")
        self.render_cards()
        GLib.timeout_add(100, self._tick)
        if not controller.demo:
            controller.refresh()
            self._sync_refresh()

    def _build_overview(self) -> None:
        page = ui.page_box()
        ui.add_heading(page, "Your computer, in plain English", "Connections, background jobs and computer health — collected locally. Nothing here is changed or sent away.")
        badges = ui.flow_box()
        badges.set_column_spacing(8)
        badges.set_row_spacing(8)
        for text in ("LOCAL ONLY", "READ-ONLY", "NO CONTENT SNIFFING"):
            badges.append(ui.status_pill(text, "on"))
        page.append(badges)
        actions = ui.responsive_row(spacing=12)
        self.refresh_button = ui.button("Refresh (F5)", self.refresh, primary=True)
        self.export_button = ui.button("Review & export… (Ctrl+E)", self.export)
        actions.append(self.refresh_button)
        actions.append(self.export_button)
        page.append(actions)
        search = Gtk.SearchEntry()
        search.set_placeholder_text("Find activity, details or reported values")
        search.set_width_chars(1)
        search.set_size_request(-1, ui.design.MIN_TARGET_PX)
        search.set_hexpand(True)
        ui.accessible(search, "Find activity", "Filter cards by title, summary or detailed records")
        search.connect("search-changed", self._search_changed)
        page.append(search)
        self.card_grid = ui.flow_box()
        page.append(self.card_grid)
        self.empty_label = ui.label("Activity is being collected…", css=("sl-body", "sl-muted"))
        page.append(self.empty_label)
        self.status_label = ui.label(self.controller.status_text, css=("sl-caption",))
        page.append(self.status_label)
        page.append(ui.label("Changes require confirmation in the existing destination tool. This dashboard itself remains read-only.", css=("sl-caption",)))
        self.add_page("overview", "Activity", "utilities-system-monitor-symbolic", page)

    def _build_privacy(self) -> None:
        page = ui.page_box()
        ui.add_heading(page, "Private by design", "Understand what is collected and review every export before a file is written.")
        grid = ui.flow_box()
        for title, body in (
            ("Local metadata only", "The collector reads local connection metadata, service history and health sources. It does not inspect file contents for activity reporting."),
            ("Redaction comes first", "Account names, addresses, tokens and secrets are redacted by default. Turning any protection off produces a visible warning."),
            ("You choose the destination", "No report is uploaded or written during preview. Only the Save confirmation writes the reviewed offline HTML report."),
        ):
            card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
            card.add_css_class("sl-status-card")
            card.append(ui.label(title, css=("sl-card-title",)))
            card.append(ui.label(body, css=("sl-body", "sl-muted")))
            grid.append(card)
        page.append(grid)
        export = ui.button("Review privacy-safe export…", self.export, primary=True)
        export.set_halign(Gtk.Align.START)
        page.append(export)
        self.add_page("privacy", "Privacy & export", "security-high-symbolic", page)

    def _search_changed(self, widget) -> None:
        self.controller.filter = widget.get_text()
        self.render_cards()

    def _activity_card(self, section: dict[str, Any]):
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        card.add_css_class("sl-status-card")
        card.set_hexpand(True)
        status = section.get("status", "unknown")
        kind = "on" if status == "ok" else "off" if status in {"warn", "bad"} else "info"
        pill = ui.status_pill(STATUS_WORDS.get(status, "UNAVAILABLE"), kind)
        pill.set_halign(Gtk.Align.START)
        card.append(pill)
        card.append(ui.label(str(section.get("title", "Activity")), css=("sl-card-title",)))
        summary = ui.label(str(section.get("summary", "Unavailable")), css=("sl-body", "sl-muted"))
        summary.set_max_width_chars(52)
        card.append(summary)
        details = text_view(details_text(section), f"Details for {section.get('title', 'activity')}", height=180)
        details.set_visible(False)
        toggle = ui.button("Show details")
        toggle.set_halign(Gtk.Align.START)

        def toggle_details():
            visible = not details.get_visible()
            details.set_visible(visible)
            toggle.set_label("Hide details" if visible else "Show details")
            ui.accessible(toggle, f"{'Hide' if visible else 'Show'} details for {section.get('title', 'activity')}")

        toggle.connect("clicked", lambda _button: toggle_details())
        ui.accessible(toggle, f"Show details for {section.get('title', 'activity')}")
        card.append(toggle)
        card.append(details)
        card.append(ui.button(str(section.get("action_label", "Open existing tool")), lambda: self.open_tool(section), primary=True))
        card.section = section
        card.details = details
        card.toggle_button = toggle
        return card

    def render_cards(self) -> None:
        while True:
            child = self.card_grid.get_first_child()
            if child is None:
                break
            self.card_grid.remove(child)
        self.cards = []
        for section in self.controller.sections:
            card = self._activity_card(section)
            self.cards.append(card)
            self.card_grid.append(card)
        if self.controller.filter.strip() and not self.cards:
            self.empty_label.set_label("No cards match your search.")
        elif not self.cards:
            self.empty_label.set_label("Activity is being collected…")
        else:
            self.empty_label.set_label("")
        self.status_label.set_label(self.controller.status_text)

    def _sync_refresh(self) -> None:
        self.refresh_button.set_sensitive(not self.controller.refreshing)
        self.refresh_button.set_label("Collecting locally…" if self.controller.refreshing else "Refresh (F5)")
        self.status_label.set_label(self.controller.status_text)

    def refresh(self) -> None:
        self.controller.refresh()
        self._sync_refresh()

    def export(self) -> None:
        try:
            review = self.controller.export_review()
        except ValueError as exc:
            ui.message_dialog(self, "Nothing to export yet", str(exc))
            return
        ExportDialog(self, review)

    def open_tool(self, section: dict[str, Any]) -> None:
        def confirm(title, body):
            answer = {"approved": False}
            dialog = ui.Adw.Dialog(title=title)
            dialog.set_content_width(560)
            dialog.set_content_height(360)
            page = ui.page_box()
            for margin in (24,):
                page.set_margin_top(margin)
                page.set_margin_bottom(margin)
                page.set_margin_start(margin)
                page.set_margin_end(margin)
            page.append(ui.label(title, css=("sl-section-title",)))
            page.append(ui.label(body, css=("sl-body",)))
            actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12, homogeneous=True)
            cancel = ui.button("Cancel", dialog.close)
            approve = ui.button("Open tool", primary=True)
            actions.append(cancel)
            actions.append(approve)
            page.append(actions)
            dialog.set_child(page)
            approve.connect("clicked", lambda _button: (answer.update(approved=True), dialog.close()))
            dialog.connect("closed", lambda _dialog: answer.setdefault("approved", False))
            dialog.present(self)
            cancel.grab_focus()
            # The controller receives a callback; native confirmation is handled
            # before launch by this modal main-loop, never by a timer/default.
            loop = GLib.MainLoop()
            dialog.connect("closed", lambda _dialog: loop.quit())
            loop.run()
            return answer["approved"]

        self.controller.open_guided_tool(section, confirm=confirm, notify=lambda title, body: ui.message_dialog(self, title, body))

    def _tick(self) -> bool:
        events = self.controller.process_events()
        if any(kind == "ok" for kind, _value in events):
            self.render_cards()
        for kind, _value in events:
            if kind == "error":
                ui.message_dialog(self, "Refresh unavailable", "Some or all activity could not be collected. Existing cards were kept; no values were invented.")
        self._sync_refresh()
        return True

    def _key_pressed(self, controller, keyval, keycode, state):
        if keyval == ui.Gdk.KEY_F5:
            self.refresh()
            return True
        if keyval == ui.Gdk.KEY_e and state & ui.Gdk.ModifierType.CONTROL_MASK:
            self.export()
            return True
        return super()._key_pressed(controller, keyval, keycode, state)


def main(demo: bool = False) -> int:
    def build(application):
        return ActivityWindow(application, ActivityController(demo=demo))
    return ui.run_application("org.securelinux.ComputerActivity", build, [sys.argv[0]])
