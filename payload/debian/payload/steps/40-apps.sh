#!/bin/bash
# 40-apps.sh (Debian) - everyday apps for the lite setup: browser, office, video player, email, password manager.
# Chosen for small and old computers: nothing heavy is added when memory is short.
#   browser   Firefox ESR (from Debian, updated by Debian's security team); on 64-bit PCs also LibreWolf (a privacy-first
#             Firefox) from its own signed repository, set up with Debian's "extrepo" tool, unless default_browser=firefox
#   office    LibreOffice Writer + Calc (+ Impress with 1 GB or more of memory); below 1 GB: AbiWord + Gnumeric (much lighter)
#   video     VLC        email  Thunderbird        passwords  Bitwarden: the desktop app as a Flatpak ONLY with 1.5 GB+ of
#             memory on a 64-bit PC; otherwise use the Bitwarden browser extension (much lighter, the guide shows how)
#   sync      Syncthing, with the same home-network-only defaults as the Fedora setup (no global discovery, relays
#             or NAT punching; the firewall lets it in from home networks only)
#   chosen    from the welcome questions (secure-linux-choice): backup_gui=deja-dup, disk_usage=baobab
#             (ncdu is already installed by 10-base), disk_utility=gnome-disks. Unset = nothing is installed.
# Sourced by setup.sh: never `exit`.
[ "$SL_MODE" = early ] && return 0

_a_have() { apt-cache policy "$1" 2>/dev/null | grep -q 'Candidate: [^(]'; }
_a_pkgs() {   # install the packages that exist in this Debian and are missing; unknown names are noted, not failures
  local missing=() want=() p
  for p in "$@"; do sl_pkg_installed "$p" || missing+=("$p"); done
  [ ${#missing[@]} -eq 0 ] && return 0          # nothing to do: no apt update, no network
  sl_apt_update
  for p in "${missing[@]}"; do
    if _a_have "$p"; then want+=("$p"); else echo "Note: package $p isn't available in this Debian; skipped."; fi
  done
  [ ${#want[@]} -gt 0 ] && sl_pkg_install --no-recommends "${want[@]}"
  return 0
}
_a_ram=$(sl_ram_mb); _a_ram=${_a_ram:-0}

# Create the user's Syncthing settings without starting anything (works offline), then make them
# home-network only: no global discovery, no relays, no NAT punching (the same defaults the Fedora
# setup applies). Settings the user already has are kept except those three options.
_a_syncthing_lan() {
  local u=$1 h cfg=""
  [ -n "$u" ] || return 0
  h=$(getent passwd "$u" 2>/dev/null | cut -d: -f6); [ -n "$h" ] || return 0
  for cfg in "$R$h/.local/state/syncthing/config.xml" "$R$h/.config/syncthing/config.xml"; do
    [ -f "$cfg" ] && break; cfg=""
  done
  if [ -z "$cfg" ] && [ "$SL_MODE" != early ]; then
    sudo -u "$u" syncthing generate --config="$R$h/.config/syncthing" >/dev/null 2>&1
    cfg=$R$h/.config/syncthing/config.xml; [ -f "$cfg" ] || cfg=""
  fi
  if [ -z "$cfg" ]; then
    echo "Note: Syncthing has no settings file yet; home-network-only will be applied at the next repair."
    return 0
  fi
  sed -i -e 's:<globalAnnounceEnabled>true</globalAnnounceEnabled>:<globalAnnounceEnabled>false</globalAnnounceEnabled>:' \
         -e 's:<relaysEnabled>true</relaysEnabled>:<relaysEnabled>false</relaysEnabled>:' \
         -e 's:<natEnabled>true</natEnabled>:<natEnabled>false</natEnabled>:' "$cfg"
  echo "Syncthing: home network only (no global discovery, relays or NAT punching)."
}

sl_step "Web browser"
_a_pkgs firefox-esr
_a_browser=$(sl_choice_get default_browser librewolf)
if [ "$(sl_arch)" = amd64 ] && [ "$_a_browser" != firefox ]; then
  if ! sl_pkg_installed librewolf; then
    if sl_online; then
      _a_pkgs extrepo
      if command -v extrepo >/dev/null 2>&1; then
        try extrepo enable librewolf
        SL_APT_UPDATED=""; sl_apt_update
        _a_pkgs librewolf
      fi
    else
      echo "FAILED: LibreWolf (offline); Firefox ESR is the browser until the next repair" | tee -a "$SL_FAILS" >&2
    fi
  fi
fi
# Which one opens links: LibreWolf if installed and wanted, else Firefox ESR (system-wide default; each person can change it)
if sl_pkg_installed librewolf && [ "$_a_browser" != firefox ]; then _a_desktop=librewolf.desktop; else _a_desktop=firefox-esr.desktop; fi
sl_write_file "$R/etc/xdg/mimeapps.list" <<EOF
[Default Applications]
text/html=$_a_desktop
x-scheme-handler/http=$_a_desktop
x-scheme-handler/https=$_a_desktop
EOF

sl_step "Office, video, email"
_a_pkgs vlc thunderbird fonts-liberation fonts-crosextra-carlito fonts-crosextra-caladea hunspell-en-au
if [ "$_a_ram" -ge 1000 ] || [ "$_a_ram" -eq 0 ]; then
  _a_pkgs libreoffice-writer libreoffice-calc libreoffice-impress libreoffice-gtk3 libreoffice-l10n-en-gb
else
  echo "Note: only $_a_ram MB of memory, so the light office apps AbiWord and Gnumeric are installed instead of LibreOffice."
  _a_pkgs abiword gnumeric
fi

sl_step "Password manager"
if sl_flatpak_ok && [ "$_a_ram" -ge 1500 ]; then
  sl_flatpak_install com.bitwarden.desktop
else
  echo "Note: the Bitwarden desktop app is not installed (it needs 64-bit and about 1.5 GB of memory; this computer has ${_a_ram} MB)."
  echo "      Use the Bitwarden extension in the browser instead: it is light and does the same job."
fi

sl_step "File sync (Syncthing)"
# Same as the Fedora setup: folders stay in sync between your own devices, and inside the home network only.
_a_pkgs syncthing
if sl_pkg_installed syncthing; then
  _a_user=$(sl_user)
  [ -n "$_a_user" ] && sl_enable "syncthing@${_a_user}.service"
  # Firewall: Syncthing can be reached from home networks only (matches the Fedora "home" zone).
  for _a_net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
    sl_ufw_allow_from "$_a_net" 22000/tcp
    sl_ufw_allow_from "$_a_net" 22000/udp
    sl_ufw_allow_from "$_a_net" 21027/udp
  done
  _a_syncthing_lan "$_a_user"
fi

sl_step "Extras chosen in the welcome questions"
# Saved with secure-linux-choice (the "Apps you used before" page). Nothing here is installed unless it
# was chosen; "Repair setup" applies the same choices, so a choice made while offline takes effect later.
case "$(sl_choice_get backup_gui)" in
  deja-dup)
    _a_pkgs deja-dup
    # The backup app suggests a folder first (a USB drive, or SSH to another computer at home).
    # No online account is ever set up or suggested.
    sl_write_file "$R/etc/dconf/db/local.d/01-secure-linux-backup" <<'EOF'
# Secure Linux: the backup app (Deja Dup) suggests a local folder first (USB drive; SSH to another
# computer at home works too). No online accounts are set up for you.
[org/gnome/DejaDup]
backend='local'
EOF
    [ -z "$R" ] && command -v dconf >/dev/null 2>&1 && try dconf update
    ;;
esac
case "$(sl_choice_get disk_usage)" in
  baobab) _a_pkgs baobab ;;    # ncdu (the terminal version) is already installed by 10-base
esac
case "$(sl_choice_get disk_utility)" in
  gnome-disks) _a_pkgs gnome-disk-utility ;;   # format/wipe USB sticks and check drive health on Xfce
esac
unset _a_ram _a_browser _a_desktop _a_user _a_net
return 0
