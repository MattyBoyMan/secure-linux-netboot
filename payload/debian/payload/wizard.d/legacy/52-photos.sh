# shellcheck shell=bash
# Wizard page (comfort): Google Takeout (Google Photos) -> Immich with immich-go (installed by experience).
page_title() { echo "Move your Google Photos to Immich"; }
page_run() {
  . "$SL_ROOT/files/comfort/comfort-lib.sh"
  wz_is_done comfort-photos && return 0
  [ "$(sl_profile)" = full ] || return 0   # the photo uploader is installed on the full profile only
  local a url src key keyfile M=$SL_ROOT/bin/secure-linux-migrate dl f
  if ! cf_have immich-go; then
    wz_info "The photo uploader (immich-go) isn't installed yet. Setup may still be finishing, or it was offline when it ran. Open this again later from \"Bring My Stuff from Windows\"; nothing has changed."
    return 0
  fi
  url=$(cf_immich_url)
  a=$(cf_ask3 "Move your Google Photos into Immich, your own photo server?

Immich (at $url) is like Google Photos, but on your home server. You'll need:
  - your Google Takeout download of Google Photos (one or more .zip files, or the unzipped folder),
  - about 10 minutes now; the upload itself can take hours and runs in a window by itself.

Albums, dates and places come across. Nothing is deleted from Google." "Yes, move my photos")
  case $a in never) wz_done comfort-photos; return 0 ;; later) return 0 ;; esac

  dl=$(xdg-user-dir DOWNLOAD 2>/dev/null || echo "$HOME/Downloads")
  src=""
  for f in "$dl"/takeout-*.zip "$dl"/Takeout; do [ -e "$f" ] && { src=$dl; break; }; done
  [ -z "$src" ] && src=$(cf_find_backup)
  src=$(wz_input "Where is your Google Takeout? Type or paste the folder that holds the takeout-....zip files (or the unzipped \"Takeout\" folder).

Don't have it yet? Go to takeout.google.com, click \"Deselect all\", tick only \"Google Photos\", choose .zip and 50 GB files, and come back when the download is ready." "${src:-$dl}")
  [ -n "$src" ] && [ -e "$src" ] || { wz_info "We couldn't find that. We'll ask again next time."; return 0; }
  # immich-go takes the zip files themselves, or the folder
  local args=() z
  for z in "$src"/takeout-*.zip "$src"/Takeout-*.zip; do [ -f "$z" ] && args+=("$z"); done
  [ ${#args[@]} -gt 0 ] || args=("$src")

  wz_info "Now an Immich \"API key\" (a password just for this upload):
  1. Immich opens in your browser. Sign in.
  2. Click your profile picture (top right) > \"Account Settings\" > \"API Keys\" > \"New API Key\".
  3. Name it \"laptop\", leave all permissions ticked, click Create, and copy the key.
Then come back here and paste it. (When the upload is finished, delete this key again in the same place.)"
  wz_open "$url"
  key=$(wz_input "Paste your Immich API key here:")
  key=$(printf '%s' "$key" | tr -d '[:space:]')
  [ -n "$key" ] || { wz_info "No key, no problem: we'll ask again next time."; return 0; }
  keyfile=${XDG_RUNTIME_DIR:-/tmp}/secure-linux-immich-key
  ( umask 077; printf '%s' "$key" > "$keyfile" )

  wz_info "First a TEST RUN: it reads your Takeout and shows what it would upload, without uploading anything. A window opens; read the summary at the end (how many photos and albums it found), then close it."
  cf_terminal "$M" immich --dry-run "${args[@]}"
  if wz_yesno "Did the test run find your photos (a number of photos and albums in the summary)?"; then
    wz_info "Starting the real upload in its own window. It can take hours for a big library: keep the laptop plugged in and on your home Wi-Fi. If it stops, run it again from \"Bring My Stuff from Windows\": photos already uploaded are skipped."
    cf_terminal "$M" immich "${args[@]}" &
    wz_done comfort-photos
  else
    rm -f "$keyfile"
    wz_info "Let's not upload yet. Common causes: the zip files are still downloading, or the key was copied only partly. We'll ask again next time."
  fi
  return 0
}
