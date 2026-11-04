# shellcheck shell=bash
# 45-migration: everything needed to bring your life over from Windows. Owned by: comfort.
#   Automatic: OneDrive copier (rclone), Office-compatible fonts (+ Aptos -> Carlito), file-watch tool for
#   the password import, uv (Python, full), printer extras (ipp-usb, HP driver).
#   From wizard choices (secure-linux-migrate install KEY=VALUE saves them; this step re-asserts them in
#   repair mode): office, notes_app, conda, matlab, android_dev, game_saves, email_client, keepassxc,
#   backup_gui, disk_usage, disk_utility (the last three are lite-only; the full profile has Pika Backup
#   and Filelight already).
# Idempotent; SL_MODE early -> nothing; atomic -> Flatpaks only.
[ "$SL_MODE" = early ] && return 0
. "$SL_ROOT/files/comfort/comfort-lib.sh"
: "${SL_PROFILE:=$(sl_profile)}"

# Install packages one at a time: one name missing from the repositories (they change between Fedora
# releases) must not stop the others. A failure is still recorded by sl_dnf_install/try.
_cf45_each() { local p; for p in "$@"; do sl_dnf_install "$p"; done; }

# Fontconfig: documents written in Microsoft's fonts open with look-alike free fonts.
# Carlito = Calibri and Caladea = Cambria are METRIC-COMPATIBLE (same letter widths: line and page breaks
# stay put). Aptos (the new Office default since 2024) has no free twin; Carlito is the closest look, but
# text may run slightly longer or shorter.
_cf45_fontconfig() {
  sl_write_file "$CF_R/etc/fonts/conf.d/30-secure-linux-office-fonts.conf" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<!-- Secure Linux (comfort): free stand-ins for Microsoft Office fonts.
     Calibri/Cambria are handled by the Carlito/Caladea packages themselves (metric-compatible).
     Aptos has no metric-compatible free font: Carlito is the closest look. -->
<fontconfig>
  <alias binding="same"><family>Aptos</family><prefer><family>Carlito</family></prefer></alias>
  <alias binding="same"><family>Aptos Display</family><prefer><family>Carlito</family></prefer></alias>
  <alias binding="same"><family>Aptos Narrow</family><prefer><family>Carlito</family></prefer></alias>
  <alias binding="same"><family>Calibri</family><prefer><family>Carlito</family></prefer></alias>
  <alias binding="same"><family>Cambria</family><prefer><family>Caladea</family></prefer></alias>
</fontconfig>
EOF
}

# adb/fastboot for every Android phone (USB interface class ff/42/01 = adb, ff/42/03 = fastboot):
# the logged-in user gets access (uaccess), nobody else.
_cf45_android_udev() {
  sl_write_file "$CF_R/etc/udev/rules.d/51-secure-linux-android.rules" <<'EOF'
# Secure Linux (comfort): let the person at the keyboard use adb / fastboot with any Android phone
SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ENV{ID_USB_INTERFACES}=="*:ff4201:*", TAG+="uaccess"
SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ENV{ID_USB_INTERFACES}=="*:ff4203:*", TAG+="uaccess"
EOF
  [ -z "$CF_R" ] && cf_have udevadm && udevadm control --reload 2>/dev/null
  return 0
}

# Déjà Dup (lite only, choice backup_gui): its default target is a folder on a USB drive or another
# computer at home over SSH. A system-wide default makes sure the first suggested target is never a
# third-party cloud service.
_cf45_dejadup_defaults() {
  sl_write_file "$CF_R/etc/dconf/db/local.d/01-secure-linux-backup" <<'EOF'
# Secure Linux (comfort): the backup app suggests a local folder first (USB drive; SSH to another
# computer at home works too). No online accounts are set up for you.
[org/gnome/DejaDup]
backend='local'
EOF
  [ -z "$CF_R" ] && cf_have dconf && try dconf update
  return 0
}

# Install what one migration choice needs (also used by secure-linux-migrate install)
_cf45_apply() {   # _cf45_apply KEY VALUE
  local k=$1 v=$2 u; u=$(sl_user)
  case "$k=$v" in
    office=onlyoffice) [ "$SL_PROFILE" = lite ] || sl_flatpak_install org.onlyoffice.desktopeditors ;;   # too heavy for old PCs
    notes_app=obsidian|notes_app=both) [ "$SL_PROFILE" = lite ] || sl_flatpak_install md.obsidian.Obsidian ;;
    conda=yes) sl_is_atomic || sl_dnf_install conda ;;
    matlab=octave|matlab=both)
      # VERIFY on Flathub: org.octave.Octave
      if sl_is_atomic; then sl_flatpak_install org.octave.Octave; else sl_dnf_install octave; fi ;;
    email_client=thunderbird)
      # The Flatpak first (sandboxed, updated by Flathub); the Fedora rpm is the fallback (and the only
      # option where Flatpak is not usable). VERIFY on Flathub: org.mozilla.Thunderbird
      if sl_is_atomic; then sl_flatpak_install org.mozilla.Thunderbird
      elif ! flatpak info --system org.mozilla.Thunderbird >/dev/null 2>&1 && ! rpm -q thunderbird >/dev/null 2>&1; then
        sl_flatpak_install org.mozilla.Thunderbird || sl_dnf_install thunderbird
      fi ;;
    email_client=betterbird) sl_flatpak_install eu.betterbird.Betterbird ;;   # VERIFY on Flathub: eu.betterbird.Betterbird
    keepassxc=yes)
      # KeePassXC: passwords in one encrypted file on this PC, no account anywhere. VERIFY on Flathub: org.keepassxc.KeePassXC
      if sl_is_atomic; then sl_flatpak_install org.keepassxc.KeePassXC; else sl_dnf_install keepassxc; fi ;;
    backup_gui=deja-dup)
      [ "$SL_PROFILE" = lite ] || return 0     # the full profile already has Pika Backup
      sl_is_atomic || { sl_dnf_install deja-dup; _cf45_dejadup_defaults; } ;;
    disk_usage=baobab)
      [ "$SL_PROFILE" = lite ] || return 0     # the full profile already has Filelight
      sl_is_atomic || sl_dnf_install baobab ;;
    disk_utility=gnome-disks)
      [ "$SL_PROFILE" = lite ] || return 0     # format/wipe USB sticks and check drive health on Xfce
      sl_is_atomic || sl_dnf_install gnome-disk-utility ;;
    android_dev=yes)
      [ "$SL_PROFILE" = full ] || return 0     # Android Studio needs a modern PC (8 GB+ RAM)
      sl_flatpak_install com.google.AndroidStudio     # VERIFY on Flathub: com.google.AndroidStudio
      sl_is_atomic || sl_dnf_install android-tools
      _cf45_android_udev
      # Android emulator speed: /dev/kvm. Fedora already opens it to logged-in users; the group is a
      # belt-and-braces for tools that check membership.
      getent group kvm >/dev/null 2>&1 && ! id -nG "$u" 2>/dev/null | grep -qw kvm && try usermod -aG kvm "$u"
      ;;
    game_saves=yes) sl_flatpak_install com.github.mtkennerly.ludusavi ;;
  esac
  return 0
}

_cf45() {
  sl_step "Getting ready to bring your files, passwords and apps over from Windows"

  if ! sl_is_atomic; then
    # rclone: OneDrive copier. inotify-tools: notices the password export arriving in Downloads.
    # Fonts: Calibri/Cambria look-alikes (metric-compatible) + Liberation (Arial/Times/Courier).
    _cf45_each rclone inotify-tools google-carlito-fonts google-crosextra-caladea-fonts liberation-fonts
    _cf45_fontconfig
    [ -z "$CF_R" ] && cf_have fc-cache && fc-cache -s >/dev/null 2>&1

    # Printers: experience installs cups, ipp-usb, sane-airscan and the scan app. We add HP's driver
    # (many family printers are HP; most newer ones also work driverless) and the classic printer tool on
    # lite. ipp-usb is listed again on purpose (no-op when present).
    _cf45_each ipp-usb hplip
    [ "$SL_PROFILE" = lite ] && _cf45_each system-config-printer

    # Python: uv makes Python projects and virtual environments fast and simple (full only)
    [ "$SL_PROFILE" = full ] && _cf45_each uv
  fi

  # Choices made in the wizard (unset = not chosen yet: nothing to do)
  local k v
  for k in office notes_app conda matlab android_dev game_saves email_client keepassxc backup_gui disk_usage disk_utility; do
    v=$(sl_choice_get "$k")
    [ -n "$v" ] && _cf45_apply "$k" "$v"
  done
  return 0
}

# secure-linux-migrate sources this file with CF45_LIB_ONLY=1 to reuse _cf45_apply
if [ -z "${CF45_LIB_ONLY:-}" ]; then
  _cf45; unset -f _cf45 _cf45_apply _cf45_fontconfig _cf45_android_udev _cf45_each _cf45_dejadup_defaults
fi
return 0
