# shellcheck shell=bash
# Wizard page (comfort): Netflix / Disney+ / Stan need DRM (Widevine) in the browser -> choice drm=yes|no.
# The experience area applies it to LibreWolf's settings.
page_title() { echo "Netflix and streaming"; }
page_run() {
  . "$SL_ROOT/files/comfort/comfort-lib.sh"
  wz_is_done comfort-drm && return 0
  local a
  a=$(wz_choice "Do you watch Netflix, Disney+, Stan, Binge or similar in the browser?

These sites need a small closed-source add-on from Google (\"DRM\", to stop copying). LibreWolf has it switched off for privacy. Switching it on only matters on those sites.

Good to know: on Linux, browsers get up to 720p on Netflix and about 1080p on most others (the companies limit it, not your laptop). For the best picture on the TV, use the TV's own app." \
    "Yes, switch it on" "No, keep it off")
  case $a in
    Yes*) cf_save_choice drm yes
          wz_info "Switched on. Restart LibreWolf, then the first video asks to install the add-on once (\"Enable DRM\"): click Yes." ;;
    No*)  cf_save_choice drm no ;;
    *) return 0 ;;
  esac
  # experience's LibreWolf settings read choice drm: re-apply them now instead of at the next repair
  if [ -f "$SL_ROOT/files/experience/user-setup.sh" ]; then
    bash "$SL_ROOT/files/experience/user-setup.sh" librewolf-prefs "$(sl_choice_get librewolf_keep_cookies no)" >/dev/null 2>&1
  fi
  wz_done comfort-drm
  return 0
}
