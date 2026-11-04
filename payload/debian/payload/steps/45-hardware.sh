#!/bin/bash
# 45-hardware.sh (Debian) - software for the hardware that is here (secure-linux-parts: disc burning, scanners, printers,
# Bluetooth, fingerprint ...), the hot-plug rule for new devices, and the weekly hardware health check timer (installed by 00-early).
# Install mode installs once; repair mode only puts back what this tool installed earlier and that went missing.
# Choice: parts_autoinstall (yes|no) controls the hot-plug installs. Sourced by setup.sh: never `exit`.
[ "$SL_MODE" = early ] && return 0

sl_step "Software for the hardware in this computer"
SL_CHANGED=0
sl_install_file "$SL_ROOT/files/hardware/udev/90-secure-linux-parts.rules" "$R/etc/udev/rules.d/90-secure-linux-parts.rules" 0644
[ "$SL_CHANGED" = 1 ] && udevadm control --reload 2>/dev/null
_h_parts=$SL_ROOT/bin/secure-linux-parts
if [ ! -x "$_h_parts" ]; then
  echo "Note: secure-linux-parts is not in this setup; hardware software is not installed."
elif ! SL_ROOT=$SL_ROOT "$_h_parts" --help >/dev/null 2>&1; then
  echo "Note: the shared hardware tool is not in this setup yet (run Repair setup after the next USB stick update)."
else
  _h_lst=$SL_STATE/parts/installed.list
  if [ "$SL_MODE" = install ] && [ ! -f "$SL_STATE/parts/report.txt" ]; then
    try "$_h_parts" --install --no-drivers --quiet
  elif [ -s "$_h_lst" ]; then
    _h_gone=0; while read -r _h_p; do [ -n "$_h_p" ] && ! sl_pkg_installed "$_h_p" && _h_gone=1; done < "$_h_lst"
    [ "$_h_gone" = 1 ] && try "$_h_parts" --reassert --quiet
  fi
fi
unset _h_parts _h_lst _h_gone _h_p
return 0
