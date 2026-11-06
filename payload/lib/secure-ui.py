#!/usr/bin/env python3
"""Toolkit-independent Secure Linux design tokens and accessibility contracts.

This module deliberately has no GTK import so packaging and controller tests can
run on build hosts. Native widgets live in secure-ui-gtk.py; the browser files
under design-preview are a static reference, never a production IPC surface.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
TOKEN_PATH = HERE / "secure-ui-tokens.json"
COMPACT_NAV_PX = 720
MIN_TARGET_PX = 44
MOTION_MS = 160


def tokens() -> dict[str, Any]:
    """Return the canonical local tokens; no network or user-state lookup."""
    return json.loads(TOKEN_PATH.read_text(encoding="utf-8"))


def navigation_mode(width: int) -> str:
    """Sidebar on roomy screens, bottom navigation at the shared breakpoint."""
    return "bottom" if width <= COMPACT_NAV_PX else "sidebar"


def motion_duration_ms(animations_enabled: bool = True) -> int:
    """Reduced-motion settings remove decorative transitions entirely."""
    return MOTION_MS if animations_enabled else 0


def accessible_label(text: str) -> str:
    """Reject icon-only or blank control names before they reach a widget."""
    cleaned = " ".join(text.split())
    if not cleaned:
        raise ValueError("Every interactive control needs a visible or accessible name.")
    return cleaned


def change_count_text(count: int) -> str:
    if count < 0:
        raise ValueError("A pending change count cannot be negative.")
    if not count:
        return "No changes ready"
    return f"{count} {'change' if count == 1 else 'changes'} ready to review. Nothing has been applied."


def _rgb(value: str) -> tuple[int, int, int]:
    value = value.removeprefix("#")
    if len(value) != 6:
        raise ValueError(f"Expected a six-digit colour, got {value!r}")
    return tuple(int(value[index:index + 2], 16) for index in (0, 2, 4))


def relative_luminance(value: str) -> float:
    channels = []
    for channel in _rgb(value):
        linear = channel / 255
        channels.append(linear / 12.92 if linear <= 0.04045 else ((linear + 0.055) / 1.055) ** 2.4)
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]


def contrast_ratio(foreground: str, background: str) -> float:
    first, second = sorted((relative_luminance(foreground), relative_luminance(background)), reverse=True)
    return (first + 0.05) / (second + 0.05)


def gtk_dependency_error() -> str:
    return (
        "The native GTK4/Libadwaita desktop packages are missing. Install "
        "python3-gobject, gtk4 and libadwaita on Fedora, or python3-gi, "
        "gir1.2-gtk-4.0 and gir1.2-adw-1 on Debian, then open this app again."
    )
