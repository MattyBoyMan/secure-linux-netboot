# shellcheck shell=bash
# Wizard page (comfort): daily tips for the first two weeks (opt-out) + the printable shortcut poster.
page_title() { echo "Daily tips"; }
page_run() {
  . "$SL_ROOT/files/comfort/comfort-lib.sh"
  wz_is_done comfort-tips && return 0
  local a T=$SL_ROOT/bin/secure-linux-tips
  a=$(wz_choice "For the next two weeks, would you like one short tip a day? Each shows how to do something you know from Windows (like Win+E for Files), as a small notification. They stop by themselves after 14 days.

There's also a one-page keyboard-shortcut poster you can print." \
    "Yes, tips please" "Yes, and show me the poster" "No tips, thanks")
  case $a in
    "Yes, tips please") "$T" --on >/dev/null 2>&1 ;;
    "Yes, and show me the poster") "$T" --on >/dev/null 2>&1; "$T" --poster >/dev/null 2>&1 & ;;
    "No tips, thanks") "$T" --off >/dev/null 2>&1 ;;
    *) return 0 ;;
  esac
  wz_done comfort-tips
  return 0
}
