#!/bin/bash
# 35-protect.sh (Debian) - the protections that the Fedora setup has and the first Debian version lacked:
#   1. disk recovery key reminder (the encrypted disk should have a spare key; the alert stays until it is made and saved)
#   2. virus scanner: ClamAV with a weekly scan and an alert when something is found. ClamAV needs about 1.2 GB of memory to
#      load its virus list, so it is installed only with 1.5 GB or more; smaller computers get a plain note in Status instead
#      (secure-linux-choice set antivirus yes forces it on, set antivirus no keeps it off)
# Choices: antivirus (auto|yes|no, default auto). Sourced by setup.sh: never `exit`.
[ "$SL_MODE" = early ] && return 0

sl_step "Disk recovery key reminder"
if [ -x "$SL_ROOT/bin/secure-linux-recovery-key" ]; then
  "$SL_ROOT/bin/secure-linux-recovery-key" status --quiet --alert || true
fi

sl_step "Virus scanner (ClamAV)"
_p_ram=$(sl_ram_mb); _p_ram=${_p_ram:-0}
_p_av=$(sl_choice_get antivirus auto)
_p_want=no
case "$_p_av" in
  yes) _p_want=yes ;;
  no) _p_want=no ;;
  *) [ "$_p_ram" -ge 1500 ] && _p_want=yes ;;
esac
if [ "$_p_want" = yes ]; then
  if ! sl_pkg_installed clamav; then
    sl_apt_update
    sl_pkg_install --no-recommends clamav clamav-freshclam
  fi
  sl_pkg_installed clamav && sl_seed_clamav_db    # no database ever downloaded (offline): use the USB stick's pack
  sl_pkg_installed clamav-freshclam && sl_enable clamav-freshclam.service
  rm -f "$SL_STATE/av-skipped"
else
  # a plain note for Status (no alert): why there is no scanner here
  printf 'This computer has %s MB of memory; the virus scanner needs about 1.5 GB to load its list.\n' "$_p_ram" > "$SL_STATE/av-skipped"
  echo "Note: the virus scanner (ClamAV) is not installed: only $_p_ram MB of memory."
fi
unset _p_ram _p_av _p_want
return 0
