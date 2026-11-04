# shellcheck shell=bash
# 40-apps-common: apps on EVERY profile (full, lite, atomic). Sourced by setup.sh. Owned by: experience.
# Idempotent: sl_dnf_install / sl_flatpak_install only install what is missing.
[ "$SL_MODE" = early ] && return 0
. "$SL_ROOT/files/experience/exp-lib.sh"

_exp40() {
  sl_step "Installing your everyday apps"
  local u; u=$(sl_user)

  exp_substep "Installing browsers, password manager and file sharing"
  #   LibreWolf (private Firefox), Tor Browser, Bitwarden, LocalSend (send files to phones),
  #   Mission Center (Task Manager), Flatseal (app permissions)
  sl_flatpak_install \
    io.gitlab.librewolf-community \
    org.torproject.torbrowser-launcher \
    com.bitwarden.desktop \
    org.localsend.localsend_app \
    io.missioncenter.MissionCenter \
    com.github.tchx84.Flatseal

  if sl_is_atomic; then
    # Fedora Atomic: no dnf. Everything as flatpaks (KDE Connect is already part of Kinoite).
    exp_substep "Installing office, video player and file sync (atomic)"
    sl_flatpak_install org.videolan.VLC org.libreoffice.LibreOffice com.github.zocker_160.SyncThingy
    return 0
  fi

  exp_substep "Installing office, video player and small tools"
  #   vlc: plays everything; solaar: Logitech mice/keyboards; the rest are terminal tools the guide explains
  sl_dnf_install vlc syncthing solaar htop btop fastfetch fzf ripgrep bat zoxide
  # Logitech receivers (e.g. MX Ergo) usable without admin rights: udev rules (#20). Fedora splits
  # them into solaar-udev; VERIFY the package name on Fedora 44 (older builds shipped them in solaar).
  if ! rpm -q solaar-udev >/dev/null 2>&1 && ! ls /usr/lib/udev/rules.d/*logitech*.rules >/dev/null 2>&1; then
    if dnf -q info solaar-udev >/dev/null 2>&1; then sl_dnf_install solaar-udev
    else echo "Note: no solaar-udev package; Logitech devices may need: sudo solaar"; fi
  fi
  if [ "$SL_PROFILE" = lite ]; then
    # Old PCs: Writer + Calc only (the full suite is heavy); GNOME Software is the app store on Xfce
    sl_dnf_install libreoffice-writer libreoffice-calc gnome-software
    # Cockpit: manage this PC from the laptop's browser (https://<this-pc>:9090), home network only
    exp_substep "Setting up remote management (Cockpit)"
    sl_dnf_install cockpit
    sl_enable cockpit.socket
    if command -v firewall-cmd >/dev/null 2>&1; then
      firewall-cmd --permanent --zone=home --query-service=cockpit >/dev/null 2>&1 \
        || try firewall-cmd --permanent --zone=home --add-service=cockpit
      firewall-cmd --zone=home --query-service=cockpit >/dev/null 2>&1 \
        || try firewall-cmd --zone=home --add-service=cockpit
    fi
    # Email: the choice made in the welcome wizard ("Apps you used before"). Only a recorded, valid
    # choice installs anything; step 45 re-asserts the same choice on repair runs.
    _exp40_email=$(sl_choice_get email_client)
    if [ -n "$_exp40_email" ]; then
      . "$SL_ROOT/files/comfort/comfort-lib.sh"     # for cf_key_allowed
      if cf_key_allowed email_client "$_exp40_email"; then
        exp_substep "Installing the email app you chose"
        case "$_exp40_email" in
          thunderbird)
            if ! flatpak info --system org.mozilla.Thunderbird >/dev/null 2>&1 && ! rpm -q thunderbird >/dev/null 2>&1; then
              sl_flatpak_install org.mozilla.Thunderbird || sl_dnf_install thunderbird
            fi ;;
          betterbird) sl_flatpak_install eu.betterbird.Betterbird ;;
        esac
      fi
    fi
    unset _exp40_email
  else
    # Full: the whole LibreOffice suite, Discover with Flatpak support, KDE Connect (phone link).
    # KDE Connect is full-only (A18): too heavy for old Xfce PCs.
    sl_dnf_install libreoffice plasma-discover-flatpak kde-connect
  fi

  # Syncthing runs in the background for the main user (settings page: http://localhost:8384)
  exp_substep "Starting Syncthing for $u"
  systemctl is-enabled --quiet "syncthing@$u.service" 2>/dev/null && systemctl is-active --quiet "syncthing@$u.service" 2>/dev/null \
    || sl_enable "syncthing@$u.service"
  return 0
}
_exp40; unset -f _exp40
return 0
