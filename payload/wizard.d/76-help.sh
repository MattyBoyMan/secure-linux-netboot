# shellcheck shell=bash
# Wizard page (comfort): finding help later - guide search and "Explain This Error" (private AI on this
# computer; plain guide search when the AI isn't there). Helper: secure-linux-explain.
page_title() { echo "Getting help later"; }
page_run() {
  . "$SL_ROOT/files/comfort/comfort-lib.sh"
  wz_is_done comfort-help && return 0
  local a q out E=$SL_ROOT/bin/secure-linux-explain
  a=$(wz_choice "Two ways to get help whenever you're stuck:

  1. Type what you want into the app launcher (the Meta key, then type): the guide is searchable, so \"printer\" or \"VPN\" finds the right page.
  2. Copy an error message you don't understand (select it, then Ctrl+C) and open \"Explain This Error\" from the menu. Your private AI, running on this computer only, explains it in plain English. If the AI isn't set up, it shows the matching guide pages instead.

Try the guide search now?" "Yes, search the guide" "Not now")
  case $a in
    Yes*)
      q=$(wz_input "What do you need help with? (for example: printer, wifi, backup)")
      if [ -n "$q" ]; then
        out=$("$E" --print --search "$q" 2>&1)
        wz_info "$out"
      fi ;;
    "") return 0 ;;
  esac
  wz_done comfort-help
  return 0
}
