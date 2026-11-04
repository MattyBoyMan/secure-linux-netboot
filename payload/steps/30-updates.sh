#!/bin/bash
# 30-updates.sh (owner: system) - automatic updates (A5, B10) and system snapshots (A6).
#   full  : Plasma Discover / PackageKit "offline updates" is the ONE updater: everything downloads by itself and
#           installs while the laptop restarts. dnf5-automatic is switched off (download-only config kept).
#           A daily system timer (secure-linux-offline-updates) prepares the same PackageKit offline update even
#           when nobody is logged in, so updates never depend on the Discover tray icon.
#   lite  : dnf5-automatic installs everything daily; restarts at 04:00 only if choice lite_auto_reboot=yes.
#   atomic: rpm-ostreed stages updates (AutomaticUpdatePolicy=stage); applied at the next restart.
# All: Flatpak apps daily (secure-linux-flatpak-update.timer, from files/system), firmware metadata (fwupd-refresh).
# Snapshots (full + lite on Btrfs): snapper with limits, a pre/post pair around every dnf transaction
# (libdnf5 actions plugin) and one before every install-on-restart. Snapshots cover the root subvolume only:
# nested subvolumes (/var/lib/flatpak, /usr/share/ollama, /swap) and /home are NOT rolled back with it.
# (Rolling back by switching the default subvolume leaves those nested subvolumes where they are.)
# "Updates waiting > 7 days for a restart"
# is raised by secure-linux-check (alert id updates-waiting).
# Sourced by setup.sh: never `exit`.
[ "$SL_MODE" = early ] && return 0

_sys_profile=$(sl_profile)
sl_is_atomic && _sys_profile=atomic

_sys_ini_set() {   # _sys_ini_set FILE GROUP KEY VALUE   set one key in an INI file, keep everything else
  local f=$1 g=$2 k=$3 v=$4 tmp
  mkdir -p "$(dirname "$f")"; [ -f "$f" ] || : > "$f"
  tmp=$(mktemp)
  awk -v g="[$g]" -v k="$k" -v v="$v" '
    function flush() { if (ing && !done) { print k "=" v; done=1 } }
    /^\[.*\]$/ { flush(); ing = ($0 == g); print; next }
    ing && $0 ~ "^[ \t]*" k "[ \t]*=" { if (!done) { print k "=" v; done=1 }; next }
    { print }
    END { flush(); if (!done) { print ""; print g; print k "=" v } }' "$f" > "$tmp"
  if cmp -s "$tmp" "$f"; then rm -f "$tmp"; else cat "$tmp" > "$f"; rm -f "$tmp"; echo "set [$g] $k=$v in $f"; fi
}

sl_step "Automatic updates"
case "$_sys_profile" in
  atomic)
    _sys_ini_set /etc/rpm-ostreed.conf Daemon AutomaticUpdatePolicy stage
    try systemctl reload rpm-ostreed
    sl_enable rpm-ostreed-automatic.timer
    ;;
  full)
    sl_dnf_install PackageKit dnf5-plugin-automatic
    # dnf5-automatic: download-only if anyone switches its timer back on; the timer itself stays off so
    # there is exactly one updater (PackageKit offline updates).
    sl_write_file /etc/dnf/automatic.conf <<'EOF'
# Secure Linux (full): Plasma Discover / PackageKit installs updates when the laptop restarts.
# dnf5-automatic is switched off; if re-enabled it only downloads.
[commands]
upgrade_type = default
download_updates = yes
apply_updates = no
reboot = never
EOF
    systemctl is-enabled -q dnf5-automatic.timer 2>/dev/null && try systemctl disable --now dnf5-automatic.timer
    # Discover: install updates on restart ("offline updates") and apply them automatically.
    # VERIFY (Plasma 6.4+): discoverrc [Software] UseOfflineUpdates (Fedora's kde-settings already sets it) and
    # PlasmaDiscoverUpdates [Global] UseUnattendedUpdates / RequiredNotificationInterval (seconds) are the keys
    # behind System Settings > Software Update ("Apply system updates: After restart", "Update frequency",
    # "Automatically"). Written to /etc/xdg so they are the defaults for every user.
    _sys_ini_set /etc/xdg/discoverrc Software UseOfflineUpdates true
    _sys_ini_set /etc/xdg/PlasmaDiscoverUpdates Global UseUnattendedUpdates true
    _sys_ini_set /etc/xdg/PlasmaDiscoverUpdates Global RequiredNotificationInterval 86400
    sl_enable secure-linux-offline-updates.timer
    ;;
  *)  # lite
    sl_dnf_install dnf5-plugin-automatic
    if [ "$(sl_choice_get lite_auto_reboot no)" = yes ]; then
      _sys_reboot=when-needed
    else
      _sys_reboot=never
    fi
    sl_write_file /etc/dnf/automatic.conf <<EOF
# Secure Linux (lite): install all updates every day.
# reboot: never = the health check reminds you to restart; when-needed = restart at 04:00 (choice lite_auto_reboot).
[commands]
upgrade_type = default
download_updates = yes
apply_updates = yes
reboot = $_sys_reboot
reboot_command = "shutdown -r 04:00 'Restarting at 4 am to finish installing updates'"
EOF
    sl_enable dnf5-automatic.timer
    systemctl is-enabled -q secure-linux-offline-updates.timer 2>/dev/null && try systemctl disable --now secure-linux-offline-updates.timer
    ;;
esac
sl_enable fwupd-refresh.timer      # firmware (BIOS, SSD) update information; offered in Discover / Status window

# ---------------------------------------------------------------- snapshots
if [ "$_sys_profile" != atomic ] && [ "$(findmnt -no FSTYPE / 2>/dev/null)" = btrfs ]; then
  sl_step "System snapshots (undo a bad update)"
  _sys_snap=(snapper libdnf5-plugin-actions)
  [ "$_sys_profile" = full ] && _sys_snap+=(btrfs-assistant)
  sl_dnf_install "${_sys_snap[@]}"
  if command -v snapper >/dev/null 2>&1; then
    snapper -c root get-config >/dev/null 2>&1 || try snapper -c root create-config /
    try snapper -c root set-config TIMELINE_CREATE=yes TIMELINE_CLEANUP=yes NUMBER_CLEANUP=yes \
      TIMELINE_LIMIT_HOURLY=6 TIMELINE_LIMIT_DAILY=7 TIMELINE_LIMIT_WEEKLY=2 TIMELINE_LIMIT_MONTHLY=2 \
      TIMELINE_LIMIT_YEARLY=0 NUMBER_LIMIT=20 FREE_LIMIT=0.2
    # pre/post snapshot around every dnf5 transaction (format: see `man libdnf5-actions`; VERIFY on F44)
    sl_install_file "$SL_ROOT/files/system/snapper.actions" /etc/dnf/libdnf5-plugins/actions.d/secure-linux-snapper.actions 0644
    sl_enable snapper-timeline.timer snapper-cleanup.timer
  fi
fi

unset _sys_profile _sys_reboot _sys_snap
return 0
