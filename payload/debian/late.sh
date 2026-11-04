#!/bin/sh
# Secure Linux (Debian fallback): the last step of the Debian install (preseed/late_command). POSIX sh.
# Puts the Secure Linux setup into the new system, so helpers, timers and the first-start setup are ready.
# Nothing here needs the internet: the apps are installed later, on the first start, once online.
#
# Inputs (from the Ventoy injection archive, unpacked at /sl in the installer):
#   /sl/payload/            the whole debian/setup folder, plus the shared helpers (see INTEGRATION.md)
#   /sl/START-HERE.html     (optional) the beginner's guide
# Inputs from the setup screen: $SL_ST (default /tmp/sl-screen): choices, distro, wifi-selected, wifi-record
# Test switches: SL_TARGET (default /target), SL_INTARGET (default in-target).

SL=${SL_DIR:-/sl}
ST=${SL_ST:-/tmp/sl-screen}
TGT=${SL_TARGET:-/target}
IT=${SL_INTARGET:-in-target}
DEST=$TGT/usr/local/lib/secure-linux
umask 022

[ -d "$SL/payload" ] || { echo "Secure Linux: no payload in $SL; installing plain Debian."; exit 0; }

mkdir -p "$DEST" "$TGT/etc/secure-linux" "$TGT/var/lib/secure-linux" "$TGT/var/log/secure-linux"
cp -a "$SL/payload/." "$DEST/"
chmod 0755 "$DEST/setup.sh" 2>/dev/null
chmod 0755 "$DEST"/bin/* 2>/dev/null

echo lite > "$TGT/etc/secure-linux/profile"
# The login name is the first normal user the installer created
USERNAME=$(awk -F: '$3 == 1000 { print $1; exit }' "$TGT/etc/passwd")
[ -n "$USERNAME" ] && echo "$USERNAME" > "$TGT/etc/secure-linux/user"
DISTRO=$(cat "$ST/distro" 2>/dev/null); [ -n "$DISTRO" ] && echo "$DISTRO" > "$TGT/etc/secure-linux/distro"
touch "$TGT/etc/secure-linux/choices"
[ -s "$ST/choices" ] && cat "$ST/choices" >> "$TGT/etc/secure-linux/choices"
chmod 0644 "$TGT/etc/secure-linux/profile" "$TGT/etc/secure-linux/user" "$TGT/etc/secure-linux/distro" "$TGT/etc/secure-linux/choices" 2>/dev/null

# The beginner's guide
if [ -f "$SL/START-HERE.html" ]; then
  mkdir -p "$TGT/usr/share/secure-linux"
  cp "$SL/START-HERE.html" "$TGT/usr/share/secure-linux/START-HERE.html"
  chmod 0644 "$TGT/usr/share/secure-linux/START-HERE.html"
fi

# Wi-Fi networks from Windows: kept private (root only) until the setup turns them into saved connections
umask 077
if [ -s "$ST/wifi-selected" ]; then cp "$ST/wifi-selected" "$TGT/var/lib/secure-linux/wifi-staged"; fi
if [ -s "$ST/wifi-record" ]; then cp "$ST/wifi-record" "$TGT/var/lib/secure-linux/wifi-record"; fi
[ -f "$SL/sl-wifi.py" ] && cp "$SL/sl-wifi.py" "$DEST/sl-wifi.py"
umask 022

# Helpers, timers, menu entries and the first-start service (installer mode: no network, no running systemd)
if [ -x "$DEST/setup.sh" ]; then
  "$IT" /usr/local/lib/secure-linux/setup.sh --early || echo "setup.sh --early reported a problem (the first start repeats everything)"
fi

# Offline fix-packs from the USB stick (ClamAV virus list, Debian firmware pools for computers with no internet).
# Best-effort: d-i often cannot read the stick's exFAT partition; then a marker asks the first-boot setup to retry
# (debian/setup/steps/03-offline-packs.sh). Never part of the injection archive (RAM limits on 256 MB-1 GB machines).
OFFDEST=$TGT/var/cache/secure-linux/offline
mkdir -p "$OFFDEST" "$TGT/var/lib/secure-linux"
off_mnt=/tmp/sl-stick
off_done=0
mkdir -p "$off_mnt"
if ! grep -q " $off_mnt " /proc/mounts 2>/dev/null; then
  for dev in /dev/disk/by-label/Ventoy; do
    [ -b "$dev" ] || continue
    mount -o ro "$dev" "$off_mnt" 2>/dev/null || mount -t exfat -o ro "$dev" "$off_mnt" 2>/dev/null || continue
    break
  done
fi
if grep -q " $off_mnt " /proc/mounts 2>/dev/null && [ -d "$off_mnt/linux-setup/offline" ]; then
  # B4 (2026-11-04): skip the other Debian release's firmware pool (dead weight on a small disk),
  # check there is room before copying, and say so when the copy fails instead of failing silently.
  off_need=$(du -sk "$off_mnt/linux-setup/offline" 2>/dev/null | awk '{print $1}')
  off_free=$(df -k "$OFFDEST" 2>/dev/null | awk 'END {print $4}')
  case "$off_need" in ''|*[!0-9]*) off_need=0 ;; esac
  case "$off_free" in ''|*[!0-9]*) off_free=0 ;; esac
  off_skip=""
  case "$DISTRO" in   # unknown -> copy both pools (the old behaviour)
    debian-lite) off_skip=debian-12-firmware ;;   # debian-lite is Debian 13
    debian-i386) off_skip=debian-13-firmware ;;   # debian-i386 is Debian 12
  esac
  if [ "$off_free" -gt 0 ] && [ "$off_need" -gt "$off_free" ]; then
    echo "Secure Linux: not enough room for the stick's offline fix-packs (need ${off_need}K, have ${off_free}K); the first start retries."
  else
    off_done=1
    for off_e in "$off_mnt/linux-setup/offline/"*; do
      [ -e "$off_e" ] || continue
      [ -n "$off_skip" ] && [ "${off_e##*/}" = "$off_skip" ] && continue
      off_err=$(cp -a "$off_e" "$OFFDEST/" 2>&1) || { echo "Secure Linux: could not copy ${off_e##*/} from the stick: $off_err"; off_done=0; }
    done
  fi
fi
umount "$off_mnt" 2>/dev/null
if [ "$off_done" != 1 ]; then
  echo "Secure Linux: the USB stick's offline fix-packs could not be copied here (the first start retries)."
  : > "$TGT/var/lib/secure-linux/offline-packs-pending"
fi

# Belt and braces: the installer's own record of answers must not keep the encryption passphrase
rm -rf "$TGT/var/log/installer/cdebconf" 2>/dev/null
rm -f "$TGT/var/cache/debconf/passwords.dat" 2>/dev/null
exit 0
