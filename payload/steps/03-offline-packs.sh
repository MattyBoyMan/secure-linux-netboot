# shellcheck shell=bash
# Copy versioned offline application bundles and existing fix-packs from the Ventoy data partition.
# Best-effort and read-only on the stick; normal online installation remains the default.
[ "$SL_MODE" = early ] && return 0
_op_dest=${SL_R:-}/var/cache/secure-linux/offline
[ -f "$_op_dest/app-bundles/current.json" ] && { unset _op_dest; return 0; }

sl_step "Offline application and fix-pack cache"
_op_mnt=/mnt/sl-offline-stick
_op_present=0
_op_done=0
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
  mkdir -p "$_op_dest"
  if cp -a "$_op_mnt/linux-setup/offline/." "$_op_dest/" 2>/dev/null; then
    _op_done=1
    echo "Offline packs copied. Application versions are cached and possibly outdated; normal updates still apply."
  fi
fi
umount "$_op_mnt" 2>/dev/null
if [ "$_op_done" = 0 ] && [ "$_op_present" = 1 ]; then
  echo "Note: offline packs were present but could not be copied; online installation will still be tried."
fi
unset _op_dest _op_mnt _op_present _op_done _op_dev
return 0
