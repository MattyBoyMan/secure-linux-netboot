# shellcheck shell=bash
# Wizard page (comfort): the small comforts the setup already did for you - USB drives from friends, iPhones,
# external monitor brightness, Bluetooth headphone quality, Windows-like touchpad, Australian spelling and
# A4 paper. Nothing to decide: it explains what you got and where to look if something doesn't work.
page_title() { echo "Drives, iPhones, monitors and headphones"; }
page_run() {
  . "$SL_ROOT/files/comfort/comfort-lib.sh"
  wz_is_done comfort-devices && return 0
  local a M=$SL_ROOT/bin/secure-linux-migrate txt
  wz_info "Already done for you, so things just work:

  - USB drives from friends (exFAT and Windows NTFS drives) open like normal, and zip, 7z and rar files open too.
  - iPhone: plug it in, tap \"Trust\" on the phone, and its photos and files appear in the file manager.
  - External monitor brightness: the brightness slider works on most monitors (it talks to the monitor over the cable).
  - Bluetooth headphones can use the better sound formats (LDAC, AAC) when they support them.
  - The touchpad works like on Windows: tap to click, two-finger click for right-click, and it ignores your palm while you type.
  - Australian English: dates like 3/11/2026, dollars, A4 paper, and English (Australia) spell-check.

Nothing to set up. If one of these doesn't work for you, the next screen can show what is installed."
  a=$(wz_choice "Would you like to see what is ready on this computer?" "Yes, show me" "No, I'm happy")
  case $a in
    Yes*)
      txt=$("$M" devices 2>&1)
      wz_info "$txt

If an iPhone or monitor misbehaves, search the guide for \"iPhone\" or \"monitor brightness\" (Search the guide, in this same menu)." ;;
    "") return 0 ;;
  esac
  wz_done comfort-devices
  return 0
}
