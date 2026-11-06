#!/usr/bin/env python3
"""Native GTK4/Libadwaita primitives for the Secure Linux 2026 interface.

No sockets, web views, telemetry, or localhost service are created. System work
stays in each application's existing fixed-argv backend/controller.
"""
from __future__ import annotations

from pathlib import Path
import sys
from typing import Callable, Iterable

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, GLib, Gtk  # noqa: E402

HERE = Path(__file__).resolve().parent


def load_design_module():
    """Load the hyphenated toolkit-independent module beside this file."""
    import importlib.util
    path = HERE / "secure-ui.py"
    spec = importlib.util.spec_from_file_location("secure_linux_ui_tokens", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


design = load_design_module()


def accessible(widget: Gtk.Widget, name: str, description: str | None = None) -> Gtk.Widget:
    properties = [Gtk.AccessibleProperty.LABEL]
    values = [design.accessible_label(name)]
    if description:
        properties.append(Gtk.AccessibleProperty.DESCRIPTION)
        values.append(description)
    widget.update_property(properties, values)
    widget.set_tooltip_text(name)
    return widget


def label(text: str, *, css: Iterable[str] = (), wrap: bool = True, xalign: float = 0) -> Gtk.Label:
    widget = Gtk.Label(label=text, xalign=xalign, wrap=wrap)
    widget.set_wrap_mode(2)  # Pango.WrapMode.WORD_CHAR: long paths cannot force horizontal scroll.
    for name in css:
        widget.add_css_class(name)
    return widget


def button(text: str, callback: Callable | None = None, *, primary: bool = False, name: str | None = None) -> Gtk.Button:
    widget = Gtk.Button(label=text, hexpand=False)
    caption = label(text, wrap=len(text) > 20, xalign=0.5)
    if len(text) > 20:
        caption.set_width_chars(1)
        caption.set_max_width_chars(32)
    caption.set_justify(Gtk.Justification.CENTER)
    widget.set_child(caption)
    widget.set_size_request(design.MIN_TARGET_PX, design.MIN_TARGET_PX)
    widget.set_cursor_from_name("pointer")
    if primary:
        widget.add_css_class("suggested-action")
    accessible(widget, name or text)
    if callback:
        widget.connect("clicked", lambda _button: callback())
    return widget


def check_button(text: str, *, active: bool = False) -> Gtk.CheckButton:
    widget = Gtk.CheckButton(active=active)
    caption = label(text)
    caption.set_width_chars(1)
    caption.set_max_width_chars(32)
    caption.set_hexpand(True)
    widget.set_child(caption)
    widget.set_size_request(-1, design.MIN_TARGET_PX)
    return widget


def symbolic_icon(name: str, size: int = 22) -> Gtk.Image:
    image = Gtk.Image.new_from_icon_name(name)
    image.set_pixel_size(size)
    image.set_accessible_role(Gtk.AccessibleRole.PRESENTATION)
    return image


def status_pill(text: str = "CHECKING", kind: str = "info") -> Gtk.Label:
    widget = label(text, css=("sl-pill", f"sl-status-{kind}"), wrap=False)
    return accessible(widget, f"Current status: {text}")


def install_base_styles(window: Gtk.Widget) -> None:
    if getattr(window, "_sl_base_styles", False):
        return
    provider = Gtk.CssProvider()
    provider.load_from_path(str(HERE / "secure-ui.css"))
    Gtk.StyleContext.add_provider_for_display(
        window.get_display(), provider, Gtk.STYLE_PROVIDER_PRIORITY_USER
    )
    window._sl_base_styles = True


def set_appearance(window: Gtk.Widget, mode: str) -> None:
    """Apply local light/dark/high-contrast tokens through native CSS providers."""
    install_base_styles(window)
    for provider in getattr(window, "_sl_theme_providers", []):
        Gtk.StyleContext.remove_provider_for_display(
            window.get_display(), provider
        )
    window._sl_theme_providers = []
    window.remove_css_class("sl-high-contrast")
    manager = Adw.StyleManager.get_default()
    filename = None
    if mode == "dark":
        manager.set_color_scheme(Adw.ColorScheme.FORCE_DARK)
        filename = "secure-ui-dark.css"
    elif mode == "high-contrast":
        manager.set_color_scheme(Adw.ColorScheme.FORCE_LIGHT)
        filename = "secure-ui-high-contrast.css"
        window.add_css_class("sl-high-contrast")
    else:
        manager.set_color_scheme(Adw.ColorScheme.FORCE_LIGHT)
    if filename:
        provider = Gtk.CssProvider()
        provider.load_from_path(str(HERE / filename))
        Gtk.StyleContext.add_provider_for_display(
            window.get_display(), provider, Gtk.STYLE_PROVIDER_PRIORITY_USER + 1
        )
        window._sl_theme_providers.append(provider)


def appearance_menu(window: Gtk.Widget) -> Gtk.MenuButton:
    popover = Gtk.Popover()
    choices = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
    choices.set_margin_top(8)
    choices.set_margin_bottom(8)
    choices.set_margin_start(8)
    choices.set_margin_end(8)
    for text, mode in (("Light", "light"), ("Dark", "dark"), ("High contrast", "high-contrast")):
        def choose(selected=mode):
            set_appearance(window, selected)
            popover.popdown()
        choices.append(button(text, choose))
    popover.set_child(choices)
    menu = Gtk.MenuButton(label="Appearance", popover=popover)
    menu.set_size_request(-1, design.MIN_TARGET_PX)
    accessible(menu, "Appearance", "Choose light, dark or high contrast")
    return menu


def page_box() -> Gtk.Box:
    page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=20)
    page.add_css_class("secure-linux")
    return page


def add_heading(page: Gtk.Box, title: str, description: str) -> None:
    page.append(label(title, css=("sl-title",)))
    description_label = label(description, css=("sl-body", "sl-muted"))
    description_label.set_max_width_chars(72)
    page.append(description_label)


def task_card(title: str, description: str, action: str, callback: Callable, *, icon: str = "system-run-symbolic") -> Gtk.Box:
    """One task surface, with no nested cards or decorative accent strip."""
    card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
    card.add_css_class("sl-task-card")
    card.set_hexpand(True)
    image = symbolic_icon(icon)
    image.add_css_class("sl-accent")
    image.set_halign(Gtk.Align.START)
    card.append(image)
    card.append(label(title, css=("sl-card-title",)))
    detail = label(description, css=("sl-body", "sl-muted"))
    detail.set_max_width_chars(52)
    card.append(detail)
    action_button = button(action, callback, name=f"{action}: {title}")
    action_button.set_halign(Gtk.Align.START)
    card.append(action_button)
    return card


def flow_box() -> Gtk.FlowBox:
    flow = Gtk.FlowBox()
    flow.set_selection_mode(Gtk.SelectionMode.NONE)
    flow.set_column_spacing(20)
    flow.set_row_spacing(20)
    flow.set_min_children_per_line(1)
    flow.set_max_children_per_line(2)
    flow.set_homogeneous(True)
    flow.set_valign(Gtk.Align.START)
    return flow


def responsive_row(*, spacing: int = 12, homogeneous: bool = False) -> Gtk.Box:
    """Horizontal on wide screens, stacked by the shell in compact mode."""
    row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=spacing, homogeneous=homogeneous)
    row._secure_responsive_row = True
    return row


def dialog_row(dialog: Adw.Dialog, *, spacing: int = 12, homogeneous: bool = False) -> Gtk.Box:
    """Dialog-local row that stacks before its actions can be clipped."""
    row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=spacing, homogeneous=homogeneous)
    dialog.set_size_request(320, 320)
    breakpoint = Adw.Breakpoint.new(Adw.BreakpointCondition.parse("max-width: 480sp"))
    breakpoint.connect("apply", lambda _bp: row.set_orientation(Gtk.Orientation.VERTICAL))
    breakpoint.connect("unapply", lambda _bp: row.set_orientation(Gtk.Orientation.HORIZONTAL))
    dialog.add_breakpoint(breakpoint)
    return row


class SecureShell(Adw.ApplicationWindow):
    """Responsive native shell: sidebar above 720sp, bottom navigation below it."""

    def __init__(self, application: Adw.Application, title: str, subtitle: str, *, demo: bool = False):
        super().__init__(application=application, title=title)
        GLib.set_application_name(title)
        self.set_default_size(1180, 800)
        self.set_size_request(360, 520)
        self.add_css_class("secure-linux")
        self.demo = demo
        self._nav_buttons: dict[str, list[Gtk.ToggleButton]] = {}
        self._nav_order: list[str] = []
        self._pages: list[Gtk.Box] = []
        self._navigating = False
        self._compact = False
        install_base_styles(self)

        toolbar = Adw.ToolbarView()
        header = Adw.HeaderBar()
        header.set_title_widget(Adw.WindowTitle(title=title, subtitle=subtitle))
        self.privacy = status_pill("PREVIEW · READ ONLY" if demo else "OFFLINE · NO TELEMETRY", "info")
        self.privacy.add_css_class("sl-privacy")
        header.pack_end(appearance_menu(self))
        header.pack_end(self.privacy)
        toolbar.add_top_bar(header)

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        body = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        self.sidebar = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.sidebar.add_css_class("sl-sidebar")
        self.sidebar.set_size_request(232, -1)
        self.sidebar.set_margin_top(24)
        self.sidebar.set_margin_bottom(24)
        self.sidebar.set_margin_start(16)
        self.sidebar.set_margin_end(16)
        self.sidebar_nav = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.sidebar.append(self.sidebar_nav)
        body.append(self.sidebar)

        self.stack = Gtk.Stack(hexpand=True, vexpand=True)
        self.stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
        settings = Gtk.Settings.get_default()
        self.stack.set_transition_duration(design.motion_duration_ms(settings.get_property("gtk-enable-animations")))
        body.append(self.stack)
        outer.append(body)
        body.set_vexpand(True)

        self.bottom_nav = Gtk.FlowBox(selection_mode=Gtk.SelectionMode.NONE,
                                      min_children_per_line=1, max_children_per_line=3,
                                      column_spacing=4, row_spacing=4, homogeneous=True)
        self.bottom_nav.add_css_class("sl-sidebar")
        self.bottom_nav.set_margin_top(8)
        self.bottom_nav.set_margin_bottom(8)
        self.bottom_nav.set_margin_start(8)
        self.bottom_nav.set_margin_end(8)
        self.bottom_nav.set_visible(False)
        outer.append(self.bottom_nav)
        toolbar.set_content(outer)
        self.set_content(toolbar)

        breakpoint = Adw.Breakpoint.new(Adw.BreakpointCondition.parse("max-width: 720sp"))
        breakpoint.connect("apply", lambda _bp: self._set_compact(True))
        breakpoint.connect("unapply", lambda _bp: self._set_compact(False))
        self.add_breakpoint(breakpoint)
        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self._key_pressed)
        self.add_controller(keys)

    def _key_pressed(self, _controller, keyval, _keycode, state):
        if keyval == Gdk.KEY_q and state & Gdk.ModifierType.CONTROL_MASK:
            self.close()
            return True
        return False

    def _set_compact(self, compact: bool) -> None:
        self._compact = compact
        self.sidebar.set_visible(not compact)
        self.bottom_nav.set_visible(compact)
        self.privacy.set_visible(not compact)
        for page in self._pages:
            margin = 16 if compact else 32
            page.set_margin_top(margin)
            page.set_margin_bottom(margin)
            page.set_margin_start(margin)
            page.set_margin_end(margin)
            for flow in page._secure_flows:
                flow.set_max_children_per_line(1 if compact else 2)
            for row in page._secure_rows:
                row.set_orientation(Gtk.Orientation.VERTICAL if compact else Gtk.Orientation.HORIZONTAL)

    def add_navigation(self, key: str, title: str, icon: str) -> None:
        first = self._nav_order[0] if self._nav_order else None
        group = self._nav_buttons[first][0] if first else None
        for parent, compact in ((self.sidebar_nav, False), (self.bottom_nav, True)):
            toggle = Gtk.ToggleButton()
            toggle.set_cursor_from_name("pointer")
            toggle.set_size_request(-1, design.MIN_TARGET_PX)
            toggle.add_css_class("sl-nav-button")
            if group:
                toggle.set_group(group)
            content = Gtk.Box(
                orientation=Gtk.Orientation.VERTICAL if compact else Gtk.Orientation.HORIZONTAL,
                spacing=4 if compact else 12,
                halign=Gtk.Align.CENTER if compact else Gtk.Align.START,
            )
            content.append(symbolic_icon(icon, 20))
            navigation_label = label(title, wrap=compact, xalign=0.5 if compact else 0)
            if compact:
                navigation_label.set_width_chars(1)
                navigation_label.set_max_width_chars(10)
                navigation_label.set_justify(Gtk.Justification.CENTER)
            content.append(navigation_label)
            toggle.set_child(content)
            accessible(toggle, title, f"Open {title}")
            toggle.connect("toggled", lambda widget, selected=key: self._nav_toggled(widget, selected))
            parent.append(toggle)
            self._nav_buttons.setdefault(key, []).append(toggle)
        self._nav_order.append(key)
        if len(self._nav_order) == 1:
            self._nav_buttons[key][0].set_active(True)

    def _nav_toggled(self, widget: Gtk.ToggleButton, key: str) -> None:
        if widget.get_active() and not self._navigating:
            self.navigate(key)

    def navigate(self, key: str) -> None:
        if key not in self._nav_buttons:
            raise KeyError(key)
        self._navigating = True
        try:
            self.stack.set_visible_child_name(key)
            for name, widgets in self._nav_buttons.items():
                for widget in widgets:
                    widget.set_active(name == key)
        finally:
            self._navigating = False

    def add_page(self, key: str, title: str, icon: str, page: Gtk.Box) -> None:
        flows = []
        rows = []
        def collect_layout(widget):
            if isinstance(widget, Gtk.FlowBox):
                flows.append(widget)
            if getattr(widget, "_secure_responsive_row", False):
                rows.append(widget)
            child = widget.get_first_child()
            while child is not None:
                collect_layout(child)
                child = child.get_next_sibling()
        collect_layout(page)
        page._secure_flows = flows
        page._secure_rows = rows
        for flow in flows:
            flow.set_max_children_per_line(1 if self._compact else 2)
        for row in rows:
            row.set_orientation(Gtk.Orientation.VERTICAL if self._compact else Gtk.Orientation.HORIZONTAL)
        margin = 16 if self._compact else 32
        page.set_margin_top(margin)
        page.set_margin_bottom(margin)
        page.set_margin_start(margin)
        page.set_margin_end(margin)
        self._pages.append(page)
        clamp = Adw.Clamp(maximum_size=1180, tightening_threshold=720)
        clamp.set_child(page)
        scroll = Gtk.ScrolledWindow(hexpand=True, vexpand=True)
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_child(clamp)
        self.stack.add_named(scroll, key)
        self.add_navigation(key, title, icon)


def message_dialog(parent: Gtk.Widget, title: str, body: str) -> Adw.Dialog:
    dialog = Adw.Dialog(title=title)
    dialog.set_content_width(560)
    dialog.set_content_height(360)
    toolbar = Adw.ToolbarView()
    bar = Adw.HeaderBar()
    bar.set_title_widget(Adw.WindowTitle(title=title))
    toolbar.add_top_bar(bar)
    box = page_box()
    for margin in (24,):
        box.set_margin_top(margin)
        box.set_margin_bottom(margin)
        box.set_margin_start(margin)
        box.set_margin_end(margin)
    text = label(body, css=("sl-body",))
    text.set_max_width_chars(66)
    box.append(text)
    close = button("Close", dialog.close, primary=True)
    close.set_halign(Gtk.Align.END)
    box.append(close)
    toolbar.set_content(box)
    dialog.set_child(toolbar)
    dialog.present(parent)
    return dialog


def review_dialog(parent: Gtk.Widget, review_text: str, on_confirm: Callable) -> Adw.Dialog:
    """Explicit review with repaired 24px outer/16px inner/action spacing."""
    dialog = Adw.Dialog(title="Review and confirm")
    dialog.set_content_width(680)
    dialog.set_content_height(640)
    toolbar = Adw.ToolbarView()
    bar = Adw.HeaderBar()
    bar.set_title_widget(Adw.WindowTitle(title="Review every change", subtitle="Nothing has been applied"))
    toolbar.add_top_bar(bar)
    frame = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
    for margin in (24,):
        frame.set_margin_top(margin)
        frame.set_margin_bottom(margin)
        frame.set_margin_start(margin)
        frame.set_margin_end(margin)
    frame.add_css_class("sl-review")

    scroll = Gtk.ScrolledWindow(hexpand=True, vexpand=True)
    scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
    scroll.set_min_content_height(260)
    text = Gtk.TextView(editable=False, cursor_visible=False, wrap_mode=Gtk.WrapMode.WORD)
    text.get_buffer().set_text(review_text)
    text.add_css_class("sl-review-text")
    for side in ("top", "bottom", "left", "right"):
        getattr(text, f"set_{side}_margin")(16)
    text.set_pixels_above_lines(4)
    text.set_pixels_below_lines(4)
    accessible(text, "Changes to review", review_text[:240])
    scroll.set_child(text)
    frame.append(scroll)

    actions = dialog_row(dialog, homogeneous=True)
    actions.add_css_class("sl-dialog-actions")
    cancel = button("Cancel — change nothing", dialog.close)
    confirm = button("Confirm these changes", primary=True)
    def confirm_and_close():
        dialog.close()
        on_confirm()
    confirm.connect("clicked", lambda _button: confirm_and_close())
    actions.append(cancel)
    actions.append(confirm)
    frame.append(actions)
    toolbar.set_content(frame)
    dialog.set_child(toolbar)
    dialog.present(parent)
    confirm.grab_focus()  # Focus is not consent: Enter is still an explicit user action.
    return dialog


def run_application(application_id: str, build_window: Callable[[Adw.Application], SecureShell], argv: list[str]) -> int:
    app = Adw.Application(application_id=application_id)
    def activate(application):
        window = build_window(application)
        window.present()
    app.connect("activate", activate)
    return app.run(argv)


def idle(callback: Callable, *args) -> None:
    """Marshal worker results onto GTK's main loop; return False to run once."""
    GLib.idle_add(lambda: (callback(*args), False)[1])
