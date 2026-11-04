#!/bin/bash
# 05-wifi.sh (Debian) - Wi-Fi networks carried over from Windows (save-wifi.ps1 -> installer setup screen).
#   /var/lib/secure-linux/wifi-staged   networks the person chose in the installer (plain): turned into saved
#                                       NetworkManager connections here (works in the installer chroot too)
#   /var/lib/secure-linux/wifi-record   networks protected with a PIN: the installer could not open them, so the
#                                       person is reminded (alert wifi-import) and opens them with secure-linux-wifi-import
# Runs in every mode. Idempotent: the staged file is removed once the connections exist.
# Sourced by setup.sh: never `exit`.

_w_py=$SL_ROOT/sl-wifi.py
_w_dest=$R/etc/NetworkManager/system-connections
if [ -s "$SL_STATE/wifi-staged" ] || [ -s "$SL_STATE/wifi-record" ]; then
  sl_step "Wi-Fi networks from your Windows"
fi
if [ -s "$SL_STATE/wifi-staged" ]; then
  if command -v python3 >/dev/null 2>&1 && [ -f "$_w_py" ]; then
    mkdir -p "$_w_dest"; chmod 700 "$_w_dest"
    if try python3 "$_w_py" keyfiles "$SL_STATE/wifi-staged" "$_w_dest"; then
      rm -f "$SL_STATE/wifi-staged"
      [ "$SL_MODE" = early ] || { command -v nmcli >/dev/null 2>&1 && try nmcli connection reload; }
    fi
  elif [ "$SL_MODE" != early ]; then
    echo "FAILED: Wi-Fi import (python3 or sl-wifi.py is missing)" | tee -a "$SL_FAILS" >&2
  fi
fi
if [ -s "$SL_STATE/wifi-record" ] || [ -s "$SL_STATE/wifi-staged" ]; then
  sl_alert wifi-import "Add your saved Wi-Fi networks" \
    "Wi-Fi networks from your old Windows are ready to add to this computer." \
    "Open 'Secure Linux Status & Fixes' and choose 'Add my saved Wi-Fi networks'."
else
  sl_clear wifi-import
fi
unset _w_py _w_dest
return 0
