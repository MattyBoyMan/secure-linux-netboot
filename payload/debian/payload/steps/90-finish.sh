#!/bin/bash
# 90-finish.sh (Debian) - setup report on the Desktop, "setup finished" event, first health check.
# Sourced by setup.sh: never `exit`.
[ "$SL_MODE" = early ] && return 0

sl_step "Finishing: report and first health check"
_f_u=$(sl_user); _f_home=$(sl_user_home)
_f_desk=$(sudo -u "$_f_u" xdg-user-dir DESKTOP 2>/dev/null)
{ [ -n "$_f_desk" ] && [ "$_f_desk" != "$_f_home" ]; } || _f_desk="$_f_home/Desktop"
install -d -o "$_f_u" -g "$_f_u" "$_f_desk" 2>/dev/null || mkdir -p "$_f_desk"
_f_report="$_f_desk/SETUP-REPORT.txt"
_f_nfail=0; [ -s "$SL_FAILS" ] && _f_nfail=$(grep -c . "$SL_FAILS")
_f_end=$(sl_support_end)

if [ "$(sl_choice_get lite_auto_reboot no)" = yes ]; then
  _f_updates="All updates install by themselves every day. When an update needs a restart,
    the computer restarts at 4 am by itself."
else
  _f_updates="All updates install by themselves every day. When one needs a restart,
    a notification tells you (restart when it suits you)."
fi

{
  echo "THE COMPLETE SECURE LINUX PACKAGE (Debian) - setup report"
  echo "Finished: $(date '+%A %d %B %Y, %H:%M')      Computer type: $(sl_distro)      Mode: $SL_MODE"
  echo
  if [ "$_f_nfail" -eq 0 ]; then
    echo "PROBLEMS: none. Everything installed."
  else
    echo "PROBLEMS: $_f_nfail item(s) didn't finish (often just a brief internet hiccup)."
    echo "  To retry: open 'Secure Linux Status & Fixes' from the app menu and choose 'Repair setup'."
    echo "  The items:"
    sed 's/^/    /' "$SL_FAILS"
  fi
  echo
  echo "ABOUT THIS VERSION OF DEBIAN"
  echo "  This computer runs Debian $(sl_debian_major), chosen because this computer is small or old."
  [ -n "$_f_end" ] && echo "  Security updates are promised until $_f_end."
  if sl_is_i386; then
    echo
    echo "  PLEASE READ - 32-BIT COMPUTER"
    echo "  Web browsers are dropping 32-bit Linux. Debian still provides Firefox ESR for 32-bit today, but that can"
    echo "  stop before $_f_end. When it does, the browser (the part of the computer that meets the internet) no longer"
    echo "  gets security fixes. Until then: keep it updated (it does so by itself), and do banking and shopping on a"
    echo "  newer device once updates stop. There is no Flatpak/Flathub for 32-bit computers, so some newer apps are"
    echo "  not available. Another option for very old computers is antiX Linux (antixlinux.com): an idea only, it is"
    echo "  not installed or tested by this USB stick."
  fi
  echo
  echo "WHAT LOOKS AFTER ITSELF (you don't need to do anything)"
  echo "  - Updates: $_f_updates"
  echo "  - Health check every 6 hours. Anything that needs you appears as a notification in plain English,"
  echo "    with a button that opens 'Secure Linux Status & Fixes'."
  echo "  - Firewall: blocks connections from outside; the home network can reach this computer's remote login."
  echo "  - Private DNS: website lookups are encrypted. At a hotel or cafe, use 'Hotel / Cafe Wi-Fi Login' in the app menu."
  echo "  - Hardware health check every week (drive, memory, battery, fans ...): anything that needs a look is shown in Status."
  echo "  - Virus scan every week (ClamAV, computers with 1.5 GB of memory or more). Nothing is ever deleted; findings are listed."
  echo "  - System snapshot before updates (when the disk has spare room): 'Repair This Computer' can go back to one."
  echo "  - A reminder stays in Status until you have made a spare key (recovery key) for the encrypted disk."
  echo
  echo "WHAT THIS SETUP DOES NOT INCLUDE (compared with the main Fedora setup)"
  echo "  No app firewall (OpenSnitch), and no gaming, AI helper or art tools (too heavy for this kind of computer)."
  echo "  No VPN app is switched on for you: NordVPN is installed ready to use on 64-bit computers (secure-linux-vpn setup);"
  echo "  WireGuard works on every computer. A virus scanner needs 1.5 GB of memory; snapshots need spare room on the disk."
  echo "  Settings you can change are listed by:  secure-linux-choice --help"
  echo
  echo "IF SOMETHING ISN'T RIGHT"
  echo "  - Open 'Secure Linux Status & Fixes' from the app menu: green = fine, red = pick it and press 'Fix it'."
  echo "  - The START-HERE guide in the app menu explains everything."
  echo
  echo "Full setup log (for helpers): $SL_LOGDIR/setup.log"
} > "$_f_report"
chown "$_f_u:" "$_f_report" 2>/dev/null; chmod 0644 "$_f_report"

if [ "$SL_MODE" = install ]; then
  if [ "$_f_nfail" -eq 0 ]; then
    sl_event setup-finished "Setup finished" "Everything is installed. Your report is on the Desktop (SETUP-REPORT.txt)."
  else
    sl_event setup-finished "Setup finished (a few items need a retry)" \
      "$_f_nfail item(s) didn't install. Open 'Secure Linux Status & Fixes' and choose 'Repair setup'."
  fi
  if sl_is_i386; then
    sl_event i386-browser-warning "About web browsers on this 32-bit computer" \
      "Browsers are dropping 32-bit. Debian still updates Firefox ESR for now. Details are in SETUP-REPORT.txt on the Desktop."
  fi
else
  sl_event "repair-$(date +%Y%m%d-%H%M)" "Repair finished" \
    "$( [ "$_f_nfail" -eq 0 ] && echo "Everything is in order again." || echo "$_f_nfail item(s) still need attention; see SETUP-REPORT.txt on the Desktop.")"
fi

mkdir -p "$SL_STATE"
printf 'done|done|Setup finished\n' > "$SL_STATE/progress"

if [ -x /usr/local/bin/secure-linux-check ]; then
  try /usr/local/bin/secure-linux-check
elif [ -x "$SL_ROOT/bin/secure-linux-check" ]; then
  try "$SL_ROOT/bin/secure-linux-check"
fi
unset _f_u _f_home _f_desk _f_report _f_nfail _f_updates _f_end
return 0
