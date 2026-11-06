#!/usr/bin/env python3
"""Pure GUI-independent logic for Secure Linux Control Centre.

No system command is run from this module.  The Tk view and the tests both use
these dataclasses, which keeps consent, review and rollback behaviour identical.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, Iterable, List, Mapping, Optional, Protocol


FEATURE_ORDER = (
    "firewall",
    "opensnitch",
    "dns",
    "vpn",
    "updates",
    "clamav",
    "usbguard",
    "fail2ban",
    "screen_lock",
    "auditd",
    "secure_boot",
    "disk_encryption",
    "flatpak_permissions",
    "docker_rootless",
)

FEATURES = {
    "firewall": {
        "title": "Firewall",
        "summary": "Blocks other devices from connecting to this computer without permission.",
        "why": "Keep this on, especially on public Wi-Fi. Turning it off makes network services easier to reach.",
    },
    "opensnitch": {
        "title": "App network protection (OpenSnitch)",
        "summary": "Watches apps making new network connections and uses the existing OpenSnitch rules.",
        "why": "The centre never invents firewall rules. It uses Secure Linux Netguard and the rules you already have.",
    },
    "dns": {
        "title": "Secure DNS",
        "summary": "Uses the existing encrypted DNS setup to protect internet address lookups.",
        "why": "Choosing off here is only a 15-minute pause for a hotel or cafe login page. It turns back on automatically.",
    },
    "vpn": {
        "title": "VPN private mode",
        "summary": "Connects the VPN you already configured through Secure Linux VPN.",
        "why": "A VPN needs an account and sign-in. It cannot be set up silently, and a failed connection is shown as a failure.",
    },
    "updates": {
        "title": "Automatic security updates",
        "summary": "Uses the update timer already provided for this Fedora or Debian setup.",
        "why": "Updates may need a restart to finish. The centre does not restart the computer for you.",
    },
    "clamav": {
        "title": "Weekly ClamAV scans",
        "summary": "Keeps the existing scheduled virus scan enabled. Scans never delete suspicious files.",
        "why": "ClamAV needs its virus list and enough memory. You can also start a scan from the results area.",
    },
    "usbguard": {
        "title": "USBGuard device policy",
        "summary": "Runs the existing USBGuard policy; it does not create or change device rules.",
        "why": "Warning: a wrong USB policy can block a keyboard, mouse or storage. It is never preselected.",
    },
    "fail2ban": {
        "title": "Fail2ban login protection",
        "summary": "Uses the existing Fail2ban rules to slow repeated remote login attempts.",
        "why": "This matters when SSH remote login is installed. It does not open SSH or add firewall rules.",
    },
    "screen_lock": {
        "title": "Automatic screen lock",
        "summary": "Asks for your login password when you return to the computer.",
        "why": "This is a per-user desktop setting. Other user accounts are not changed.",
    },
    "auditd": {
        "title": "Security audit log (auditd)",
        "summary": "Enables the existing audit service and its current rules.",
        "why": "Audit logs can use disk space and may record sensitive activity. This centre does not add audit rules.",
    },
    "secure_boot": {
        "title": "Secure Boot",
        "summary": "Shows the firmware Secure Boot state when the computer can report it.",
        "why": "Secure Boot is changed in the computer's firmware, usually with a restart. Linux cannot promise to enable it here.",
    },
    "disk_encryption": {
        "title": "Disk encryption",
        "summary": "Checks whether an encrypted LUKS disk is present.",
        "why": "Encrypting an unencrypted system disk is not a safe one-click operation. It can require backup, reinstall and a new password.",
    },
    "flatpak_permissions": {
        "title": "Flatpak app permissions",
        "summary": "Opens Flatseal so you can inspect the permissions of individual Flatpak apps.",
        "why": "Permissions are app-specific. The centre does not broadly reset or weaken them.",
    },
    "docker_rootless": {
        "title": "Docker rootless mode",
        "summary": "Checks the active Docker context and opens the existing Home & Server Helper for setup.",
        "why": "Rootless setup is per user. Existing rootful Docker is never disabled by this centre.",
    },
}

# None means "leave this alone". Presets therefore cannot silently disconnect a
# VPN, pause DNS or switch off a security service that the preset does not own.
RECOMMENDED = {
    "firewall": True,
    "opensnitch": True,
    "dns": True,
    "updates": True,
    "clamav": True,
    "fail2ban": True,
    "screen_lock": True,
}
STRICTER = dict(RECOMMENDED, vpn=True, auditd=True)
PRESETS = {"recommended": RECOMMENDED, "stricter": STRICTER, "custom": {}}


class PlanError(ValueError):
    """A requested plan would be unsupported or misleading."""


@dataclass(frozen=True)
class FeatureStatus:
    feature: str
    state: str = "unknown"
    detail: str = "Status is not available yet."
    supported: bool = False
    manageable: bool = False
    can_disable: bool = False
    reversible: bool = True

    @property
    def is_on(self) -> bool:
        return self.state in {"on", "encrypted", "family", "private", "home", "warp", "active", "enabled"}


@dataclass(frozen=True)
class PlannedChange:
    feature: str
    desired: bool
    before: str
    reversible: bool

    @property
    def title(self) -> str:
        return FEATURES[self.feature]["title"]

    @property
    def sentence(self) -> str:
        verb = "Turn on" if self.desired else "Turn off"
        if self.feature == "dns" and not self.desired:
            return "Pause Secure DNS for 15 minutes (it then turns back on)"
        return f"{verb}: {self.title}"


@dataclass
class OperationResult:
    feature: str
    desired: bool
    ok: bool
    verified: bool
    detail: str
    state: str = "unknown"
    rollback_supported: bool = True
    rollback_attempted: bool = False
    rollback_ok: Optional[bool] = None


@dataclass
class ApplyReport:
    results: List[OperationResult] = field(default_factory=list)
    rollback_results: List[OperationResult] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return bool(self.results) and all(r.ok and r.verified for r in self.results)

    @property
    def headline(self) -> str:
        if not self.results:
            return "Nothing was changed."
        if self.ok:
            return f"All {len(self.results)} chosen settings were applied and verified."
        successes = sum(r.ok and r.verified for r in self.results)
        failures = len(self.results) - successes
        text = f"{successes} setting(s) verified; {failures} failed."
        if self.rollback_results:
            undone = sum(r.ok and r.verified for r in self.rollback_results)
            text += f" {undone} earlier change(s) were rolled back."
            if undone != len(self.rollback_results):
                text += " Some rollback steps failed; read every line below."
        return text


def preset_values(preset: str, statuses: Mapping[str, FeatureStatus]) -> Dict[str, Optional[bool]]:
    """Return checkbox values, omitting unsupported and unmanaged features.

    USBGuard is deliberately never preselected. Informational cards never get a
    checkbox value. Current states are retained for features outside the preset.
    """
    if preset not in PRESETS:
        raise PlanError(f"Unknown preset: {preset}")
    values: Dict[str, Optional[bool]] = {}
    for key in FEATURE_ORDER:
        status = statuses.get(key, FeatureStatus(key))
        if not status.manageable:
            continue
        if key == "usbguard":
            # Never select it, but never silently switch off an existing policy.
            values[key] = status.is_on
        elif key in PRESETS[preset] and status.supported:
            values[key] = PRESETS[preset][key]
        else:
            values[key] = status.is_on if status.supported else False
    return values


def build_plan(statuses: Mapping[str, FeatureStatus], desired: Mapping[str, Optional[bool]]) -> List[PlannedChange]:
    """Validate consent choices and return only actual changes, in stable order."""
    unknown = set(desired) - set(FEATURE_ORDER)
    if unknown:
        raise PlanError(f"Unknown feature(s): {', '.join(sorted(unknown))}")
    plan: List[PlannedChange] = []
    for key in FEATURE_ORDER:
        if key not in desired or desired[key] is None:
            continue
        status = statuses.get(key)
        if status is None:
            raise PlanError(f"No current status is known for {FEATURES[key]['title']}. Refresh before applying.")
        want = bool(desired[key])
        if want == status.is_on:
            continue
        if not status.supported or not status.manageable:
            raise PlanError(f"{FEATURES[key]['title']} cannot be changed safely here: {status.detail}")
        if not want and not status.can_disable:
            raise PlanError(f"{FEATURES[key]['title']} cannot be turned off in this centre: {status.detail}")
        plan.append(PlannedChange(key, want, status.state, status.reversible))
    return plan


class Backend(Protocol):
    def apply(self, change: PlannedChange) -> OperationResult:
        ...


def apply_with_rollback(backend: Backend, plan: Iterable[PlannedChange]) -> ApplyReport:
    """Apply and verify every requested change; undo successful ones on failure.

    Each backend operation must verify itself and, where possible, clean up its
    own partial change. This second pass rolls back earlier successful changes.
    Non-reversible operations remain visible as honest partial success.
    """
    report = ApplyReport()
    successful: List[PlannedChange] = []
    for change in plan:
        result = backend.apply(change)
        report.results.append(result)
        if result.ok and result.verified:
            successful.append(change)
    if report.ok:
        return report
    for change in reversed(successful):
        if not change.reversible:
            continue
        inverse = PlannedChange(change.feature, not change.desired, change.before, change.reversible)
        rollback = backend.apply(inverse)
        rollback.rollback_attempted = True
        report.rollback_results.append(rollback)
    return report


def review_text(plan: Iterable[PlannedChange]) -> str:
    """Plain text for both the accessible review dialog and mocked UI tests."""
    items = list(plan)
    if not items:
        return "No changes are needed. Every selected item is already in the requested state."
    lines = ["Please review every change. Nothing happens until you press Confirm.", ""]
    for number, change in enumerate(items, 1):
        lines.append(f"{number}. {change.sentence}")
        if not change.desired:
            lines.append("   This reduces protection until you turn it back on.")
        if change.feature == "usbguard" and change.desired:
            lines.append("   USB devices may be blocked. Keep a recovery method available.")
        if not change.reversible:
            lines.append("   This operation cannot be rolled back automatically.")
    lines += [
        "",
        "An administrator prompt may appear. Your password is never stored or logged.",
        "Every attempted change is checked afterwards. Failures are shown honestly.",
    ]
    return "\n".join(lines)
