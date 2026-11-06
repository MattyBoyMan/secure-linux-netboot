# shellcheck shell=bash
# Wizard page (comfort): children and visitors -> secure-linux-family (family filter, kids' accounts with
# app limits, guest account).
page_title() { echo "Children and visitors"; }
page_run() {
  . "$SL_ROOT/files/comfort/comfort-lib.sh"
  wz_is_done comfort-family && return 0
  local a
  a=$(wz_choice "Do children or visitors use this computer?

We can:
  - switch on a family filter that blocks adult and dangerous websites for everyone on this computer,
  - make a separate account for each child (they can't change the system, and you choose which apps they can use),
  - add a Guest account for visitors that wipes itself clean when they log out." \
    "Yes, children use it" "Only visitors (Guest account)" "No, just me")
  case $a in
    "Yes, children use it") "$SL_ROOT/bin/secure-linux-family" --wizard children ;;
    "Only visitors"*)       "$SL_ROOT/bin/secure-linux-family" --wizard guest ;;
    "No, just me")          cf_save_choice family_mode no ;;
    *) return 0 ;;
  esac
  wz_done comfort-family
  return 0
}
