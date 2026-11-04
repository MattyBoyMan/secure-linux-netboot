# shellcheck shell=bash
# 76-homeassistant: Home Assistant on the desktop. Sourced by setup.sh. Owned by: homeassistant (Job L).
#
# What this installs (Home Assistant itself is SERVER software and lives on your home server; this laptop gets a window):
#   all profiles   the "Home Assistant" menu entry (installed by 00-early from files/homeassistant/applications/;
#                  re-asserted here) that opens ha_url (default http://homeassistant.local:8123) in an app-style
#                  window through secure-linux-ha, the help/lessons entry, and the helper commands.
#   full + atomic  Butler (Flathub com.cassidyjames.butler): a small native window for a Home Assistant dashboard.
#   full           tools: git, yamllint, python3-pyyaml, avahi-tools, nss-mdns, (hass-cli via pipx); esphome via pipx only if
#                  the choice ha_esphome=yes.
#   full + atomic  choice ha_local=yes: a rootless-Podman "try it" Home Assistant bound to 127.0.0.1, OFF until started.
# Choice keys read: ha_url, ha_local, ha_esphome. Nothing is downloaded from outside Fedora/Flathub/PyPI; no secrets are stored.
[ "$SL_MODE" = early ] && return 0
. "$SL_ROOT/files/homeassistant/ha-lib.sh"

# run a command as the main user with their HOME (pipx and Podman Quadlet are per-user)
_ha76_as_user() {
  local u uid h; u=$(sl_user); uid=$(id -u "$u" 2>/dev/null) || return 1; h=$(sl_user_home)
  [ -n "$h" ] || return 1
  if [ "$(id -un 2>/dev/null)" = "$u" ]; then HOME="$h" "$@"; return; fi
  local env=(HOME="$h" USER="$u" LOGNAME="$u" SL_ROOT="$SL_ROOT")
  [ -S "/run/user/$uid/bus" ] && env+=(DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" XDG_RUNTIME_DIR="/run/user/$uid")
  [ -n "${SL_TEST_SYSROOT:-}" ] && env+=(SL_TEST_SYSROOT="$SL_TEST_SYSROOT")
  runuser -u "$u" -- env "${env[@]}" "$@"
}

# pipx tool for the main user, only if missing. Pinned PyPI names; VERIFY on Fedora 44 that pipx can build them.
_ha76_pipx() {   # _ha76_pipx command-name package
  local cmd=$1 pkg=$2 h; h=$(sl_user_home)
  [ -x "$h/.local/bin/$cmd" ] && return 0
  sl_online || { echo "Skipping $pkg for now: no internet (the next repair will try again)."; return 0; }
  try _ha76_as_user pipx install --quiet "$pkg"
}

_ha76() {
  sl_step "Setting up Home Assistant (menu entry, tools, practice copy)"
  local apps=/usr/share/applications
  sl_is_atomic && apps=/usr/local/share/applications
  local f
  # 1. menu entries: normally put in place by 00-early; make sure they are there (repair mode keeps user edits)
  for f in "$SL_ROOT"/files/homeassistant/applications/*.desktop; do
    [ -f "$f" ] && sl_install_file "$f" "${SL_TEST_SYSROOT:-}$apps/$(basename "$f")" 0644
  done

  # 2. lite: the menu entry is enough (it uses whatever browser is installed)
  [ "$SL_PROFILE" = lite ] && return 0

  # 3. a native window for the dashboard (Flathub, GPL-3.0, network + display only)
  if ! sl_is_arm || sl_flatpak_has_build "$HA_BUTLER"; then
    sl_flatpak_install "$HA_BUTLER"
  else
    sl_skip_app "$HA_BUTLER" "Flathub has no version of this app for this type of computer"
  fi

  # 4. tools (Fedora packages and pipx); the atomic profile has no dnf, so only Flatpaks and the Podman copy there
  if ! sl_is_atomic; then
    sl_dnf_install git yamllint python3-pyyaml avahi-tools nss-mdns python3-bcrypt
    sl_dnf_install pipx
    _ha76_pipx hass-cli homeassistant-cli
    [ "$(sl_choice_get ha_esphome no)" = yes ] && _ha76_pipx esphome esphome
  fi

  # 5. the "try it on this laptop" copy: set up only when asked for (ha_local=yes). It never starts by itself.
  if [ "$(sl_choice_get ha_local no)" = yes ]; then
    if command -v podman >/dev/null 2>&1 || ! sl_is_atomic && sl_dnf_install podman; then
      try _ha76_as_user "$SL_ROOT/bin/secure-linux-ha" local enable
    fi
  fi
  return 0
}
_ha76
unset -f _ha76 _ha76_as_user _ha76_pipx
return 0
