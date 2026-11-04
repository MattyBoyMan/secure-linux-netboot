# shellcheck shell=bash
# Wizard page (comfort): optional extras - tools pack (full) and everyday extras incl. RustDesk.
page_title() { echo "Handy extras"; }
page_run() {
  . "$SL_ROOT/files/comfort/comfort-lib.sh"
  wz_is_done comfort-extras && return 0
  local todo=() M=$SL_ROOT/bin/secure-linux-migrate
  if [ "$(sl_profile)" = full ]; then
    if wz_yesno "Add the free \"tools pack\"? (about 1.5 GB)
  - Speech Note: type by talking, read text aloud and translate, all offline on this laptop.
  - NormCap and Frog: grab the text out of any picture or screenshot (like Windows' Text Extractor).
  - PDF Arranger: merge, split, reorder and rotate PDF pages.
  - OCRmyPDF: makes scanned PDFs searchable (the guide shows how).
  - Metadata Cleaner: removes hidden details (location, camera, author) from photos and documents before you share them."; then
      todo+=(extras_tools=yes)
    else cf_save_choice extras_tools no; fi
  fi
  if wz_yesno "Add some everyday extras?
  - Organic Maps: offline maps and directions, no tracking.
  - Foliate and Calibre: read and organise e-books.
  - RustDesk: help family members with their computer from here (they see a code, you connect).

About RustDesk and privacy: by default, connections are set up through RustDesk's public server (the screen itself is encrypted end to end). You can run your own RustDesk server on your home server so nothing goes through anyone else: the guide's RustDesk page shows how."; then
    todo+=(extras_apps=yes)
  else cf_save_choice extras_apps no; fi
  if [ ${#todo[@]} -gt 0 ]; then
    wz_info "Installing now; your password is asked once. The apps appear in the menu over the next few minutes."
    wz_root "$M" install "${todo[@]}"
  fi
  wz_done comfort-extras
  return 0
}
