# shellcheck shell=bash
# 70-desktop: default browser, LibreWolf preset, Syncthing home-only, printers/scanners, and the
# plumbing the welcome wizard and backup check need. Owned by: experience.
[ "$SL_MODE" = early ] && return 0
. "$SL_ROOT/files/experience/exp-lib.sh"

# _exp70_xfconf_default CHANNEL XML-BODY   system-wide Xfce default, only if the distro ships none
_exp70_xfconf_default() {
  local f="$SL_R/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/$1.xml"
  [ -f "$f" ] && ! grep -q 'Secure Linux' "$f" && { echo "keep existing $f"; return 0; }
  printf '<?xml version="1.0" encoding="UTF-8"?>
<!-- Secure Linux: screen lock defaults -->
<channel name="%s" version="1.0">
%s
</channel>
' "$1" "$2"     | sl_write_file "$f"
}

_exp70() {
  sl_step "Setting up your browser, printing and file sync"
  local u; u=$(sl_user)

  # Password asked once per few minutes for our helpers (pkexec), instead of at every single step
  sl_install_file "$SL_EXP/org.securelinux.experience.policy" "$SL_R/usr/share/polkit-1/actions/org.securelinux.experience.policy"

  # Backup alerts written by the user's own backup check (a user process can't write alerts.d).
  # Format = alerts.d (line 1 title, 2 message, 3 action hint). secure-linux-notify/-status may read it.
  mkdir -p "$SL_STATE/user-alerts/$u"; chmod 0755 "$SL_STATE/user-alerts" "$SL_STATE/user-alerts/$u"
  chown "$u:" "$SL_STATE/user-alerts/$u" 2>/dev/null

  exp_substep "Setting your web browser"
  # LibreWolf is the default browser (choice default_browser, default librewolf); Firefox stays installed
  # as a fallback for the odd site that only works there.
  try exp_as_user bash "$SL_EXP/user-setup.sh" browser "$(sl_choice_get default_browser librewolf)"
  try exp_as_user bash "$SL_EXP/user-setup.sh" librewolf-prefs "$(sl_choice_get librewolf_keep_cookies no)"

  exp_substep "Locking the screen when you're away"
  # Lock after 5 minutes idle and on wake from sleep / lid close (#25). System defaults for every user,
  # plus the main user's own settings (KDE; on Xfce the welcome wizard sets them inside the session).
  if [ "$SL_PROFILE" = lite ]; then
    sl_dnf_install xfce4-screensaver
    _exp70_xfconf_default xfce4-screensaver '  <property name="saver" type="empty">
    <property name="enabled" type="bool" value="true"/>
    <property name="idle-activation" type="empty">
      <property name="enabled" type="bool" value="true"/>
      <property name="delay" type="int" value="5"/>
    </property>
  </property>
  <property name="lock" type="empty">
    <property name="enabled" type="bool" value="true"/>
    <property name="saver-activation" type="empty">
      <property name="enabled" type="bool" value="true"/>
      <property name="delay" type="int" value="0"/>
    </property>
  </property>'
    _exp70_xfconf_default xfce4-power-manager '  <property name="xfce4-power-manager" type="empty">
    <property name="lock-screen-suspend-hibernate" type="bool" value="true"/>
  </property>'
  else
    sl_write_file "$SL_R/etc/xdg/kscreenlockerrc" <<'EOF'
# Secure Linux: lock the screen after 5 minutes and when waking from sleep (users can change it in
# System Settings > Screen Locking)
[Daemon]
Autolock=true
LockOnResume=true
Timeout=5
EOF
    try exp_as_user bash "$SL_EXP/user-setup.sh" screenlock
    # KDE Connect announces a device name to phones on the network: "Laptop" instead of the hostname
    [ "$SL_PROFILE" = full ] && try exp_as_user bash "$SL_EXP/user-setup.sh" kdeconnect-name
  fi

  if ! sl_is_atomic; then
    exp_substep "Setting up printers and scanners"
    # Driverless printing/scanning (AirPrint/eSCL/WSD): most printers from the last 10 years just work
    sl_dnf_install cups ipp-usb sane-airscan
    if [ "$SL_PROFILE" = lite ]; then sl_dnf_install simple-scan system-config-printer
    else sl_dnf_install skanpage; fi
    systemctl is-enabled --quiet cups.socket 2>/dev/null || sl_enable cups.socket

    exp_substep "Keeping Syncthing inside your home network"
    # syncthing_lan_only=yes (default): no global discovery, no relays, no NAT punching = files only
    # travel between your own devices on the same network (or over the VPN's Meshnet).
    try exp_as_user bash "$SL_EXP/user-setup.sh" syncthing-lan "$(sl_choice_get syncthing_lan_only yes)"
  fi
  return 0
}
_exp70; unset -f _exp70 _exp70_xfconf_default
return 0
