# shellcheck shell=bash
# wz-fallback.sh (comfort): the wz_* page helpers for running a wizard.d page OUTSIDE the welcome wizard
# (e.g. "secure-linux-migrate page passwords" from the app menu). Each helper is defined only if the welcome
# hasn't defined it already, so inside the wizard the real ones are used.
# Built on experience's ui_* dialogs (kdialog on KDE, zenity on Xfce, text in a terminal).
# shellcheck source=../experience/exp-lib.sh
[ -f "$SL_ROOT/files/experience/exp-lib.sh" ] && . "$SL_ROOT/files/experience/exp-lib.sh"
UI_TITLE=${UI_TITLE:-"Secure Linux"}
# Scripted answers (tests) are keyed PAGE_N (N counts the dialogs a page shows). The wz_* helpers are often
# called inside $( ), so the counter lives in a file shared through the parent shell's PID.
_WZ_CF=${TMPDIR:-/tmp}/secure-linux-wz-$$; rm -f "$_WZ_CF"
_wz_key() {
  [ -n "${SL_WIZARD_ANSWERS:-}" ] || { echo "${WZ_PAGE:-comfort}"; return; }
  local n; n=$(( $(cat "$_WZ_CF" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$_WZ_CF"
  echo "${WZ_PAGE:-comfort}_$n"
}
_wz_have_ui() { declare -F ui_info >/dev/null; }

declare -F wz_info >/dev/null || wz_info() {
  if _wz_have_ui; then ui_info "$(_wz_key)" "$1"; else printf '\n%s\n' "$1"; read -rp "Press Enter to continue. " _; fi
}
declare -F wz_yesno >/dev/null || wz_yesno() {
  local a
  if _wz_have_ui; then a=$(ui_ask "$(_wz_key)" "$1"); else read -rp "$1 [y/n] " a; case $a in y*|Y*) a=yes ;; esac; fi
  [ "$a" = yes ]
}
declare -F wz_choice >/dev/null || wz_choice() {
  local q=$1 a i=0 args=(); shift
  for a in "$@"; do i=$((i + 1)); args+=("$i" "$a"); done
  if _wz_have_ui; then a=$(ui_choose "$(_wz_key)" "$q" "${args[@]}")
  else printf '\n%s\n' "$q"; i=0; for a in "$@"; do i=$((i + 1)); printf '  %s) %s\n' "$i" "$a"; done; read -rp "Number: " a; fi
  [[ $a =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le $# ] && { printf '%s' "${!a}"; return 0; }
  # some dialogs return the label itself
  for i in "$@"; do [ "$i" = "$a" ] && { printf '%s' "$a"; return 0; }; done
  return 0
}
declare -F wz_input >/dev/null || wz_input() {
  if _wz_have_ui; then ui_input "$(_wz_key)" "$1" "${2:-}"; else local a; read -rp "$1 " a; echo "${a:-${2:-}}"; fi
}
declare -F wz_open >/dev/null || wz_open() {
  [ -n "${SL_WIZARD_ANSWERS:-}" ] && { echo "OPEN: $1"; return 0; }
  command -v xdg-open >/dev/null 2>&1 && { xdg-open "$1" >/dev/null 2>&1 & }
  return 0
}
declare -F wz_root >/dev/null || wz_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else pkexec "$@"; fi
}
declare -F wz_done >/dev/null || wz_done() {
  local f=$HOME/.local/state/secure-linux/wizard-pages-comfort
  mkdir -p "${f%/*}"; grep -qx "$1" "$f" 2>/dev/null || echo "$1" >> "$f"
}
declare -F wz_is_done >/dev/null || wz_is_done() {
  [ "${WZ_FORCE:-0}" = 1 ] && return 1
  grep -qx "$1" "$HOME/.local/state/secure-linux/wizard-pages-comfort" 2>/dev/null
}
