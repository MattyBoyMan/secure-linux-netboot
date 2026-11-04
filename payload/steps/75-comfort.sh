# shellcheck shell=bash
# 75-comfort: first-week comfort. Owned by: comfort.
#   Automatic: Australian English (British spelling UI, en_AU spell-check, A4 paper), friends' devices
#   (exFAT/NTFS drives, 7-Zip, iPhone files), external-monitor brightness (ddcutil), better Bluetooth
#   audio codecs, Windows-like touchpad on lite (X11), a high-contrast colour scheme (full).
#   Per-user settings (screen scaling, touchpad on KDE, formats, searchable guide, tips) are applied at each
#   user's first login by files/comfort/first-login.sh (autostart), because KDE settings live per user.
#   From wizard choices (re-asserted in repair mode): meetings, accessibility, extras_tools, extras_apps,
#   guest_account, family_mode.
[ "$SL_MODE" = early ] && return 0
. "$SL_ROOT/files/comfort/comfort-lib.sh"
: "${SL_PROFILE:=$(sl_profile)}"
_cf75_each() { local p; for p in "$@"; do sl_dnf_install "$p"; done; }   # one missing package must not stop the rest

_cf75_apply() {   # _cf75_apply KEY VALUE   (also used by secure-linux-migrate install)
  local k=$1 v=$2 item
  case $k in
    meetings)
      for item in ${v//,/ }; do
        case $item in
          vesktop)
            # Discord with Wayland screen sharing + sound. Vesktop is an Electron app (heavy): old PCs get
            # Discord's website as an app window instead.
            if [ "${SL_PROFILE:-$(sl_profile)}" = lite ]; then
              cf_webapp_system discord "Discord (web)" "Discord in its own window" https://discord.com/app discord "Network;Chat;" "chat;voice;"
            else sl_flatpak_install dev.vencord.Vesktop; fi ;;
          # Teams and Zoom are used as web apps: their websites work well here, need no extra software and
          # get no access to the rest of the computer beyond the browser's own limits.
          teams) cf_webapp_system teams "Microsoft Teams (web)" "Teams for school or work, in its own window" https://teams.microsoft.com \n                   microsoft-teams "Network;VideoConference;" "teams;meeting;call;" ;;
          zoom)  cf_webapp_system zoom "Zoom (web)" "Join Zoom meetings in your browser" https://app.zoom.us/wc \n                   video-x-generic "Network;VideoConference;" "zoom;meeting;call;" ;;
        esac
      done ;;
    accessibility)
      for item in ${v//,/ }; do
        case $item in
          orca)     sl_is_atomic || _cf75_each orca speech-dispatcher-espeak-ng ;;
          dyslexia) sl_is_atomic || _cf75_each opendyslexic-fonts ;;   # VERIFY package name on Fedora
          captions) [ "${SL_PROFILE:-$(sl_profile)}" = lite ] || sl_flatpak_install net.sapples.LiveCaptions ;;   # speech models: too heavy for old PCs
        esac
      done ;;
    extras_tools)
      [ "$v" = yes ] || return 0
      [ "${SL_PROFILE:-$(sl_profile)}" = lite ] && return 0     # Speech Note's AI models are too heavy for old PCs
      # Speech Note (offline dictation/translation), NormCap + Frog (copy text out of a screenshot),
      # PDF Arranger (merge/split/rotate pages), Metadata Cleaner (strip hidden info before sharing)
      sl_flatpak_install net.mkiol.SpeechNote com.github.dynobo.normcap com.github.tenderowl.frog \
        com.github.jeromerobert.pdfarranger fr.romainvigier.MetadataCleaner
      sl_is_atomic || _cf75_each ocrmypdf ;;     # no Flatpak for it: atomic skips
    extras_apps)
      [ "$v" = yes ] || return 0
      # Organic Maps (offline maps), Foliate (e-books), Calibre (e-book library), RustDesk (help family).
      # Old PCs (lite) get only the light ones: Foliate and RustDesk.
      if [ "${SL_PROFILE:-$(sl_profile)}" = lite ]; then
        sl_flatpak_install com.github.johnfactotum.Foliate com.rustdesk.RustDesk
      else
        sl_flatpak_install app.organicmaps.desktop com.github.johnfactotum.Foliate com.calibre_ebook.calibre com.rustdesk.RustDesk
      fi ;;
    guest_account)
      [ "$v" = yes ] && try "$SL_ROOT/bin/secure-linux-family" guest-setup --quiet ;;
    family_mode)
      # Parental Controls (malcontent): per-child app limits, enforced by Flatpak for Flatpak apps
      [ "$v" = yes ] && ! sl_is_atomic && _cf75_each malcontent-control ;;
  esac
  return 0
}

_cf75_locale() {
  sl_is_atomic || _cf75_each langpacks-en_AU langpacks-en_GB hunspell-en-AU hunspell-en-GB   # VERIFY package names
  # A4 paper: libpaper (used by many print tools) reads /etc/papersize; glibc apps read LC_PAPER.
  sl_write_file "$CF_R/etc/papersize" <<<"a4"
  local lc="$CF_R/etc/locale.conf"
  if [ -f "$lc" ] && ! grep -q '^LC_PAPER=' "$lc" && ! grep -qE '^LANG="?en_(AU|GB|NZ)' "$lc"; then
    echo 'LC_PAPER="en_AU.UTF-8"' >> "$lc"      # only when the system language isn't already A4-based
  fi
  return 0
}

_cf75_devices() {
  sl_is_atomic && return 0
  # Friends' USB drives (exFAT, NTFS), every archive type (7-Zip), iPhone photos and files (ifuse,
  # usbmuxd, libimobiledevice-utils; iPhone USB tethering works through usbmuxd + the ipheth driver).
  _cf75_each exfatprogs ntfs-3g ntfsprogs 7zip usbmuxd ifuse libimobiledevice-utils
  # External monitor brightness: ddcutil ships a udev rule (uaccess on /dev/i2c-*) and loads i2c-dev,
  # so no group is needed. Plasma 6's brightness slider uses it for external screens.
  _cf75_each ddcutil
  # Better Bluetooth headphones: PipeWire's LDAC and AAC codec plugins need these libraries.
  _cf75_each libldac fdk-aac-free     # VERIFY package names on Fedora
  return 0
}

# Xfce (lite) runs on X11: one system-wide libinput snippet gives every touchpad Windows-like behaviour.
# (KDE stores it per user: first-login.sh does that.)
_cf75_touchpad_x11() {
  [ "$SL_PROFILE" = lite ] || return 0
  sl_write_file "$CF_R/etc/X11/xorg.conf.d/40-secure-linux-touchpad.conf" <<'EOF'
# Secure Linux (comfort): touchpads behave like on Windows.
# Tap to click, two-finger tap or click = right click, no stray clicks while typing, natural scrolling.
Section "InputClass"
    Identifier "secure-linux touchpad"
    MatchIsTouchpad "on"
    MatchDriver "libinput"
    Option "Tapping" "on"
    Option "ClickMethod" "clickfinger"
    Option "DisableWhileTyping" "on"
    Option "NaturalScrolling" "true"
EndSection
EOF
}

_cf75() {
  sl_step "Making the desktop comfortable: language, touchpad, devices and accessibility"
  _cf75_locale
  _cf75_devices
  _cf75_touchpad_x11
  if [ "$SL_PROFILE" != lite ]; then
    sl_install_file "$CF_FILES/SecureLinuxHighContrast.colors" "$CF_R/usr/share/color-schemes/SecureLinuxHighContrast.colors"
  fi
  # The guide's printable shortcut poster and emergency-kit template live in $CF_FILES; nothing to copy.

  local k v
  for k in meetings accessibility extras_tools extras_apps guest_account family_mode; do
    v=$(sl_choice_get "$k")
    [ -n "$v" ] && _cf75_apply "$k" "$v"
  done
  return 0
}

if [ -z "${CF75_LIB_ONLY:-}" ]; then
  _cf75; unset -f _cf75 _cf75_apply _cf75_locale _cf75_devices _cf75_touchpad_x11 _cf75_each
fi
return 0
