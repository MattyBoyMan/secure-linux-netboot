# shellcheck shell=bash
# Wizard page (comfort): how big things look on the 2.5K 14" screen (KDE, full profile, laptop panel only).
page_title() { echo "Screen size"; }
page_run() {
  . "$SL_ROOT/files/comfort/comfort-lib.sh"
  wz_is_done comfort-display && return 0
  [ "$(sl_profile)" = full ] && [ "$(cf_desktop)" = kde ] || return 0
  local w a pct cur
  w=$(cf_panel_width) || return 0
  [ "${w:-0}" -ge 2560 ] || { wz_done comfort-display; return 0; }
  cur=$(cat "$HOME/.config/secure-linux/display-scale" 2>/dev/null); cur=${cur:-150}
  a=$(wz_choice "How big should things look on the screen?

Your laptop has a sharp 2.5K screen, so we've set it to 150% (like Windows' recommended setting). Pick another size if text feels too small or too big. You can change it any time in System Settings > Display & Monitor > Scale." \
    "125% (more fits on screen)" "150% (recommended)" "175% (bigger)" "200% (biggest)" "Keep it as it is ($cur%)")
  case $a in
    125*) pct=125 ;; 150*) pct=150 ;; 175*) pct=175 ;; 200*) pct=200 ;;
    Keep*) wz_done comfort-display; return 0 ;;
    *) return 0 ;;
  esac
  mkdir -p "$HOME/.config/secure-linux"; echo "$pct" > "$HOME/.config/secure-linux/display-scale"
  CF_FIRST_LOGIN_DELAY=0 bash "$SL_ROOT/files/comfort/first-login.sh" --force scale >/dev/null 2>&1
  wz_info "Done: the screen is now at $pct%. Some apps that were already open look right after you restart them."
  wz_done comfort-display
  return 0
}
