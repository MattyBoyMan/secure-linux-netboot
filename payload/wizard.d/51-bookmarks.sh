# shellcheck shell=bash
# Wizard page (comfort): Chrome / Edge / Firefox bookmarks from the Windows backup -> LibreWolf.
page_title() { echo "Bring your bookmarks"; }
page_run() {
  . "$SL_ROOT/files/comfort/comfort-lib.sh"
  wz_is_done comfort-bookmarks && return 0
  local a src out M=$SL_ROOT/bin/secure-linux-migrate
  a=$(cf_ask3 "Bring your bookmarks from Windows into LibreWolf?

Your Windows backup has your Chrome (and Edge/Firefox) bookmarks. We turn them into one file that LibreWolf can import, keeping your folders." "Yes, bring my bookmarks")
  case $a in never) wz_done comfort-bookmarks; return 0 ;; later) return 0 ;; esac

  src=$(cf_find_backup)
  if [ -z "$src" ]; then
    src=$(wz_input "Plug in the drive with your Windows backup (the folder is called ZenbookBackup-...). Then type or paste the folder's location here:

(In the Files app, open the folder, then press Ctrl+L and copy the address.)" "/run/media/$USER/")
    [ -n "$src" ] && [ -d "$src" ] || { wz_info "We couldn't find that folder. We'll ask again next time."; return 0; }
    cf_remember_backup "$src"
  fi
  out=$("$M" bookmarks "$src" 2>/dev/null | tail -1)
  if [ -z "$out" ] || [ ! -f "$out" ]; then
    wz_info "We didn't find any browser bookmarks in $src.

If you used Chrome's sync, you can also export them from Chrome on another computer: Chrome menu > Bookmarks and lists > Bookmark manager > the three dots > Export bookmarks. Then import that file the same way as below."
    return 0
  fi
  wz_info "Your bookmarks are ready: $out

Now in LibreWolf:
  1. Press Ctrl+Shift+O (the Library window opens).
  2. Click \"Import and Backup\" > \"Import Bookmarks from HTML...\".
  3. Pick the file above (it's in your Documents folder).

They appear under \"Other Bookmarks\", in a folder per browser, e.g. \"Chrome - Default\". Drag the ones you use most onto the bookmarks toolbar.

LibreWolf opens now."
  flatpak run io.gitlab.librewolf-community >/dev/null 2>&1 &
  wz_done comfort-bookmarks
  return 0
}
