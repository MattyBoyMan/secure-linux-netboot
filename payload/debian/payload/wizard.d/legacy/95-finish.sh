# shellcheck shell=bash
# Final wizard offer (comfort): launch the guided post-install finishing tool. It asks its own separate
# yes for every restore, app, import or care action. "No thanks" only stops this offer; the command remains.
page_title() { echo "Finish setting up your computer"; }
page_run() {
  . "$SL_ROOT/files/comfort/comfort-lib.sh"
  wz_is_done finish && return 0
  local a
  a=$(cf_ask3 "Almost there. Would you like a guided final check of your own setup?

The finishing helper can:
- bring across the rest of your documents, photos and bookmarks;
- open each app at its setup screen, with plain-English steps;
- carry safe app choices to another Secure Linux computer (never passwords or keys);
- save a one-page care sheet and open the normal health checker.

It never signs in for you, never asks for your passwords, and never replaces your files without asking. You can skip every item and come back later by opening 'Finish Setting Up My Computer' in the app menu." "Yes, finish my setup")
  case $a in
    never) wz_done finish; return 0 ;;
    later) return 0 ;;
  esac
  if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && { command -v zenity >/dev/null 2>&1 || command -v kdialog >/dev/null 2>&1; }; then
    "$SL_ROOT/bin/secure-linux-finish" --gui
  else
    cf_terminal "$SL_ROOT/bin/secure-linux-finish"
  fi
  wz_done finish
  return 0
}
