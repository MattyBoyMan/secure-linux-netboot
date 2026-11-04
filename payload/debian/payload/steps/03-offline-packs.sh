#!/bin/bash
# 03-offline-packs.sh (Debian) - finish copying the USB stick's offline fix-packs (ClamAV virus list, Debian firmware
# pools) when the installer could not: d-i often cannot read the stick's exFAT partition, so late.sh then leaves the
# marker var/lib/secure-linux/offline-packs-pending. Retried by every setup/repair run while the marker exists.
# Best-effort; never fails the setup. Sourced by setup.sh: never `exit`.
[ "$SL_MODE" = early ] && return 0
_marker=$SL_STATE/offline-packs-pending
[ -f "$_marker" ] || { unset _marker; return 0; }

sl_step "Offline fix-packs from the USB stick"
_op_mnt=/mnt/sl-offline-stick
_op_done=0; _op_present=0
mkdir -p "$_op_mnt"
if ! grep -q " $_op_mnt " /proc/mounts 2>/dev/null; then
  for _op_dev in /dev/disk/by-label/Ventoy; do
    [ -b "$_op_dev" ] || continue
    _op_present=1
    mount -o ro "$_op_dev" "$_op_mnt" 2>/dev/null || mount -t exfat -o ro "$_op_dev" "$_op_mnt" 2>/dev/null || continue
    break
  done
fi
if grep -q " $_op_mnt " /proc/mounts 2>/dev/null && [ -d "$_op_mnt/linux-setup/offline" ]; then
  _op_present=1
  mkdir -p "$R/var/cache/secure-linux/offline"
  if cp -a "$_op_mnt/linux-setup/offline/." "$R/var/cache/secure-linux/offline/" 2>/dev/null; then
    _op_done=1
    rm -f "$_marker"
    echo "Offline fix-packs copied from the USB stick (virus list and firmware, for use without the internet)."
  fi
fi
umount "$_op_mnt" 2>/dev/null
# Stay quiet when the stick simply is not plugged in (the usual case after the install); only warn when it IS here
# but the copy failed.
if [ "$_op_done" = 0 ] && [ "$_op_present" = 1 ]; then
  echo "Note: the USB stick is plugged in but the offline fix-packs could not be copied. This is retried at the next setup or repair."
fi
unset _marker _op_mnt _op_done _op_present _op_dev
return 0
