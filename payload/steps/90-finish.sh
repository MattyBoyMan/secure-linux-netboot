#!/bin/bash
# 90-finish.sh (owner: system) - setup report on the Desktop, "setup finished" event, first health check.
# Sourced by setup.sh: never `exit`.
[ "$SL_MODE" = early ] && return 0

_sys_profile=$(sl_profile); sl_is_atomic && _sys_profile=atomic
sl_step "Finishing: report and first health check"

# ClamAV is installed by the experience steps (which run before this one): let the confined ClamAV domain
# (clamd, ClamTk scans) read the whole system. VERIFY: boolean name in the Fedora 44 SELinux policy.
if command -v clamscan >/dev/null 2>&1 && command -v getsebool >/dev/null 2>&1 \
   && getsebool antivirus_can_scan_system 2>/dev/null | grep -q -- '--> off'; then
  try setsebool -P antivirus_can_scan_system 1
fi

_sys_u=$(sl_user); _sys_home=$(sl_user_home)
_sys_desk=$(sudo -u "$_sys_u" xdg-user-dir DESKTOP 2>/dev/null)
{ [ -n "$_sys_desk" ] && [ "$_sys_desk" != "$_sys_home" ]; } || _sys_desk="$_sys_home/Desktop"
install -d -o "$_sys_u" -g "$_sys_u" "$_sys_desk" 2>/dev/null || mkdir -p "$_sys_desk"
_sys_report="$_sys_desk/SETUP-REPORT.txt"

# Repair: reinstall Flatpak apps the user had (list kept by the backup check in ~/.config/secure-linux/apps.txt,
# so it also travels to a new machine through the backups)
_sys_apps_list="$_sys_home/.config/secure-linux/apps.txt"
if [ "$SL_MODE" = repair ] && [ -f "$_sys_apps_list" ] && command -v flatpak >/dev/null 2>&1; then
  _sys_missing=()
  while read -r _sys_id; do
    case "$_sys_id" in ''|'#'*) continue ;; esac
    printf '%s' "$_sys_id" | grep -qE '^[A-Za-z0-9_-]+([.][A-Za-z0-9_-]+){2,}$' || continue
    flatpak info "$_sys_id" >/dev/null 2>&1 || _sys_missing+=("$_sys_id")
  done < "$_sys_apps_list"
  if [ ${#_sys_missing[@]} -gt 0 ]; then
    sl_step "Reinstalling your apps (${#_sys_missing[@]})"
    sl_online && sl_flatpak_install "${_sys_missing[@]}"
  fi
fi
# Run the final checks before claiming success in the report, event or progress.
if [ -x /usr/local/bin/secure-linux-check ]; then
  try /usr/local/bin/secure-linux-check
elif [ -x "$SL_ROOT/bin/secure-linux-check" ]; then
  try "$SL_ROOT/bin/secure-linux-check"
fi
_sys_nfail=0; [ -s "$SL_FAILS" ] && _sys_nfail=$(grep -c . "$SL_FAILS")
_sys_sec_bad=0
[ -s "$SL_STATE/checks" ] && _sys_sec_bad=$(awk -F'|' '$1 ~ /^security-/ && $2 == "bad" {n++} END {print n+0}' "$SL_STATE/checks")

case "$_sys_profile" in
  full)   _sys_updates="All updates (system, apps and firmware information) download by themselves every day.
    The laptop installs them when you restart it - nothing changes while you work.
    A notification reminds you to restart; after 7 days it asks more firmly." ;;
  atomic) _sys_updates="All updates download by themselves and are applied when you restart.
    The previous version stays in the start menu, so a bad update can always be undone." ;;
  *)      if [ "$(sl_choice_get lite_auto_reboot no)" = yes ]; then
            _sys_updates="All updates install by themselves every day. When an update needs a restart,
    the computer restarts at 4 am by itself."
          else
            _sys_updates="All updates install by themselves every day. When one needs a restart,
    a notification tells you (restart when it suits you)."
          fi ;;
esac

{
  echo "THE COMPLETE SECURE LINUX PACKAGE - setup report"
  echo "Finished: $(date '+%A %d %B %Y, %H:%M')      Setup type: $_sys_profile      Mode: $SL_MODE"
  echo
  if [ "$_sys_nfail" -eq 0 ] && [ "$_sys_sec_bad" -eq 0 ]; then
    echo "PROBLEMS: none. Everything installed and every required security control passed."
  else
    echo "PROBLEMS: $_sys_nfail setup item(s) didn't finish; $_sys_sec_bad security control(s) failed verification."
    echo "  This computer is NOT marked secure/ready. Retry: open 'Secure Linux Status & Fixes' and choose 'Repair setup'."
    echo "  Security report: run 'secure-linux-security-audit report'."
    echo "  The setup items:"
    sed 's/^/    /' "$SL_FAILS"
    echo "  Failed security checks:"
    awk -F'|' '$1 ~ /^security-/ && $2 == "bad" {print "    " $3 ": " $4}' "$SL_STATE/checks"
  fi
  echo
  echo "NEXT STEP"
  echo "  The Welcome wizard opens by itself after you log in (or find 'Welcome' in the app menu)."
  echo "  It walks you through the few choices that are yours to make: your VPN, your browser,"
  echo "  backups, your disk recovery key and more. No typing of commands needed."
  echo
  echo "WHAT LOOKS AFTER ITSELF (you don't need to do anything)"
  echo "  - Updates: $_sys_updates"
  echo "  - Health check every 6 hours. Anything that needs you appears as a notification in"
  echo "    plain English, with a button that opens 'Secure Linux Status & Fixes'."
  echo "  - Firewall: blocks connections from outside, except your own devices' sync apps."
  if [ "$_sys_profile" != atomic ] && command -v snapper >/dev/null 2>&1; then
    echo "  - Undo points (snapshots) before every update and every hour: a bad update can be undone"
    [ "$_sys_profile" = full ] && echo "    in Btrfs Assistant." || echo "    from the boot menu."
  fi
  command -v clamscan >/dev/null 2>&1 && \
    echo "  - Antivirus: a weekly scan of Downloads and Desktop (it never deletes anything; findings appear in the Status window)."
  echo "  - Disk health: the SSD is watched and checked monthly; you are told early if it wears out."
  echo
  echo "IF SOMETHING ISN'T RIGHT"
  echo "  - Open 'Secure Linux Status & Fixes' from the app menu: green = fine, red = pick it and press 'Fix it'."
  echo "  - 'Create Diagnostics File' in the app menu saves a zip for whoever helps you (no passwords inside)."
  echo "  - The START-HERE guide in the app menu explains everything."
  echo
  echo "Full setup log (for helpers): $SL_LOGDIR/setup.log"
} > "$_sys_report"
chown "$_sys_u:" "$_sys_report" 2>/dev/null; chmod 0644 "$_sys_report"

mkdir -p "$SL_STATE"
if [ "$SL_MODE" = install ]; then
  if [ "$_sys_nfail" -eq 0 ] && [ "$_sys_sec_bad" -eq 0 ]; then
    sl_event setup-finished "Setup finished" "Everything is installed and required security checks passed. Your report is on the Desktop."
    printf 'done|done|Setup finished\n' > "$SL_STATE/progress"
  else
    sl_event setup-finished "Setup needs attention" \
      "$_sys_nfail setup item(s) and $_sys_sec_bad failed security control(s) need attention. The computer is not marked secure/ready."
    printf 'failed|done|Setup incomplete; retry is required\n' > "$SL_STATE/progress"
  fi
else
  sl_event "repair-$(date +%Y%m%d-%H%M)" "Repair finished" \
    "$( [ "$_sys_nfail" -eq 0 ] && [ "$_sys_sec_bad" -eq 0 ] && echo "Everything is in order again." || echo "$_sys_nfail setup item(s) and $_sys_sec_bad failed security control(s) still need attention; see SETUP-REPORT.txt.")"
fi

# One-time notice if firmware (BIOS, SSD, other parts) can be updated; flashing is always the user's decision.
if [ "$SL_MODE" = install ] && [ -x /usr/local/bin/secure-linux-firmware ]; then
  timeout 300 /usr/local/bin/secure-linux-firmware check || echo "firmware check skipped"
fi

unset _sys_profile _sys_u _sys_home _sys_desk _sys_report _sys_nfail _sys_updates _sys_apps_list _sys_missing _sys_id _sys_sec_bad
return 0
