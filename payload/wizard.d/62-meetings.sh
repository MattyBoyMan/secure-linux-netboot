# shellcheck shell=bash
# Wizard page (comfort): video calls - Vesktop (Discord with screen sharing), Teams and Zoom as web apps.
page_title() { echo "Video calls and chat"; }
page_run() {
  . "$SL_ROOT/files/comfort/comfort-lib.sh"
  wz_is_done comfort-meetings && return 0
  local list=() M=$SL_ROOT/bin/secure-linux-migrate
  wz_yesno "Install apps for video calls and chat? We'll ask about Discord, Teams and Zoom one by one.

(Signal is already installed for private messages.)" || { wz_done comfort-meetings; return 0; }
  wz_yesno "Discord? We install \"Vesktop\": your normal Discord account, but screen sharing with sound works properly on this desktop (the official Discord app struggles with it)." && list+=(vesktop)
  wz_yesno "Microsoft Teams (for uni or work)? Teams opens in its own app window here (it's the Teams website underneath, so there's nothing extra to keep up to date). Sign in with your school or work account." && list+=(teams)
  wz_yesno "Zoom? Zoom also runs in its own app window here (the Zoom website), so you can join meetings without installing anything extra." && list+=(zoom)
  if [ ${#list[@]} -eq 0 ]; then cf_save_choice meetings none; wz_done comfort-meetings; return 0; fi
  local joined; joined=$(IFS=,; echo "${list[*]}")
  wz_root "$M" install "meetings=$joined"
  wz_info "Installed: ${list[*]}. They're in the app menu. The first time you share your screen, the desktop asks which screen or window to share: that's normal and keeps you in control."
  wz_done comfort-meetings
  return 0
}
