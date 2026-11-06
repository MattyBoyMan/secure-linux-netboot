# shellcheck shell=bash
# Wizard page (comfort): printable emergency kit + two-step login checklist (secure-linux-emergency-kit).
page_title() { echo "Your emergency kit"; }
page_run() {
  . "$SL_ROOT/files/comfort/comfort-lib.sh"
  wz_is_done comfort-emergency && return 0
  local a
  a=$(cf_ask3 "Make your emergency kit?

It's a page you print and keep somewhere safe (with your passport, for example). It lists WHERE your important recovery codes are kept - your Bitwarden master password hint, the disk recovery key, your Ente Auth recovery phrase and so on - plus this laptop's serial number. You fill in the blanks with a pen; nothing secret is typed into the computer.

It also has a checklist for switching on two-step login (Google, Microsoft, Steam, Discord ...) and for checking whether your email address showed up in a data breach." "Yes, make my kit")
  case $a in never) wz_done comfort-emergency; return 0 ;; later) return 0 ;; esac
  "$SL_ROOT/bin/secure-linux-emergency-kit" --open >/dev/null 2>&1 &
  wz_info "Your kit opens in the browser. Print it (Ctrl+P) and fill it in by hand. A copy is saved in Documents as \"Emergency Kit.html\".

Make a new one any time from the app menu: \"Emergency Kit\"."
  wz_done comfort-emergency
  return 0
}
