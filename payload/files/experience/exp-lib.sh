# shellcheck shell=bash
# Shared helpers for the "experience" steps (40/50/60/70) and helpers (welcome, battery, hwtest, fleet, ai,
# backup-check). Source AFTER lib/common.sh. Owned by: experience.
#
# Test hooks (used only by tests/experience/run.sh, never set on a real machine):
#   SL_TEST_SYSROOT   prefix for every absolute system path we write (/etc, /var, /usr, /run)
#   SL_TEST_SYSFS     replaces /sys (battery, backlight)
#   SL_WIZARD_ANSWERS answers for dialogs, "key=value,key=value" (see ui_* below); no dialogs are shown
[ -n "${SL_EXP_LOADED:-}" ] && return 0
SL_EXP_LOADED=1

SL_R=${SL_TEST_SYSROOT:-}
if [ -n "$SL_R" ]; then
  SL_ETC=$SL_R/etc/secure-linux; SL_STATE=$SL_R/var/lib/secure-linux
  SL_LOGDIR=$SL_R/var/log/secure-linux; SL_FAILS=$SL_LOGDIR/failures.log
fi
SL_SYS=${SL_TEST_SYSFS:-/sys}
SL_PROC=${SL_TEST_PROC:-/proc}
SL_RUN=$SL_R/run/secure-linux
SL_EXP=$SL_ROOT/files/experience
SL_BIN=$SL_ROOT/bin              # our helpers, also installed to /usr/local/bin by 00-early.sh

exp_is_root() { [ "$(id -u)" -eq 0 ]; }
# exp_elevate "$@"   re-run this helper as root through pkexec (password asked once, see our polkit policy)
# (prefers the /usr/local/bin copy: that is the path our polkit policy names, so the password is remembered)
exp_elevate() {
  exp_is_root && return 0
  local self="/usr/local/bin/$(basename "$0")"; [ -x "$self" ] || self=$(readlink -f "$0")
  exec pkexec "$self" "$@"
}

# Progress text for the welcome screen WITHOUT advancing the step counter (one sl_step per step file
# keeps "step N of TOTAL" honest).
exp_substep() {
  echo "--- $*"
  mkdir -p "$SL_STATE" 2>/dev/null
  printf '%s|%s|%s\n' "${SL_STEP_N:-0}" "${SL_STEP_TOTAL:-?}" "$*" > "$SL_STATE/progress" 2>/dev/null || true
}

# exp_as_user CMD...   run as the main user with their HOME (and their desktop bus if logged in)
exp_as_user() {
  local u uid h; u=$(sl_user); uid=$(id -u "$u" 2>/dev/null) || return 1; h=$(sl_user_home)
  if [ "$(id -un 2>/dev/null)" = "$u" ]; then "$@"; return; fi
  local env=(HOME="$h" USER="$u" LOGNAME="$u")
  [ -S "/run/user/$uid/bus" ] && env+=(DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" XDG_RUNTIME_DIR="/run/user/$uid")
  runuser -u "$u" -- env "${env[@]}" "$@"
}

exp_desktop() {   # kde | xfce | other
  case "${XDG_CURRENT_DESKTOP:-}${DESKTOP_SESSION:-}" in
    *KDE*|*plasma*) echo kde ;; *XFCE*|*xfce*) echo xfce ;;
    *) if command -v kdialog >/dev/null 2>&1; then echo kde; elif command -v xfce4-session >/dev/null 2>&1; then echo xfce; else echo other; fi ;;
  esac
}

exp_notify() {    # exp_notify "Title" "Message" [icon]
  [ -n "${SL_WIZARD_ANSWERS:-}" ] && { echo "NOTIFY: $1 | $2"; return 0; }
  command -v notify-send >/dev/null 2>&1 && notify-send -a "Secure Linux" -i "${3:-security-high}" "$1" "$2" 2>/dev/null
  return 0
}

# Latest GitHub release asset URL:  exp_github_asset owner/repo 'regex-for-file-name'
exp_github_asset() {
  curl -fsSL --max-time 30 "https://api.github.com/repos/$1/releases/latest" \
    | grep -oE '"browser_download_url": *"[^"]*"' | grep -oE 'https://[^"]+' | grep -E "$2" | head -1
}
# exp_verify_sha256 FILE SUMS_FILE NAME   true if SUMS_FILE lists NAME with FILE's sha256
exp_verify_sha256() {
  local want got
  want=$(awk -v n="$3" '{f=$2; sub(/^\*/,"",f)} f==n {print $1; exit}' "$2")
  got=$(sha256sum "$1" | cut -d' ' -f1)
  [ -n "$want" ] && [ "$want" = "$got" ]
}

# Battery with a settable charge limit (asus-wmi on the Zenbook): prints the sysfs file, or fails
exp_battery_file() {
  local f
  for f in "$SL_SYS"/class/power_supply/BAT*/charge_control_end_threshold; do
    [ -e "$f" ] && { echo "$f"; return 0; }
  done
  return 1
}
exp_on_ac() {     # true if plugged in (or no battery at all)
  local f found=0
  for f in "$SL_SYS"/class/power_supply/*/online; do
    [ -e "$f" ] || continue
    case "$(cat "$(dirname "$f")/type" 2>/dev/null)" in Mains|USB*) found=1; [ "$(cat "$f")" = 1 ] && return 0 ;; esac
  done
  [ $found = 0 ]
}
exp_metered() {   # true if NetworkManager says the connection is metered (phone hotspot etc.)
  command -v nmcli >/dev/null 2>&1 || return 1
  nmcli -t -f GENERAL.METERED device show 2>/dev/null | grep -q ':yes'
}
exp_power_saver() { command -v powerprofilesctl >/dev/null 2>&1 && [ "$(powerprofilesctl get 2>/dev/null)" = power-saver ]; }

# ---------------------------------------------------------------- dialogs (kdialog on KDE, zenity on Xfce)
# Every dialog has a KEY. With SL_WIZARD_ANSWERS="key=value,..." the answer is taken from there (missing
# key = skip) and nothing is shown: that is how the tests drive the wizard and the hardware check.
UI_TITLE=${UI_TITLE:-"Secure Linux"}
UI_ICON=${UI_ICON:-security-high}
_ui_auto() {      # _ui_auto KEY -> prints the scripted answer; returns 1 if not in scripted mode
  [ -n "${SL_WIZARD_ANSWERS:-}" ] || return 1
  local a; a=$(printf ',%s,' "$SL_WIZARD_ANSWERS" | sed -n "s/.*,$1=\([^,]*\),.*/\1/p")
  echo "UI[$1] -> ${a:-skip}" >&2
  printf '%s' "${a:-skip}"
}
_ui_tool() {
  if [ -n "${UI_TOOL:-}" ]; then echo "$UI_TOOL"
  elif [ "$(exp_desktop)" = kde ] && command -v kdialog >/dev/null 2>&1; then echo kdialog
  elif command -v zenity >/dev/null 2>&1; then echo zenity
  elif command -v kdialog >/dev/null 2>&1; then echo kdialog
  else echo tty; fi
}
ui_info() {       # ui_info KEY "text"
  _ui_auto "$1" >/dev/null && return 0
  case $(_ui_tool) in
    kdialog) kdialog --title "$UI_TITLE" --icon "$UI_ICON" --msgbox "$2" ;;
    zenity)  zenity --info --title="$UI_TITLE" --icon-name="$UI_ICON" --width=480 --text="$2" ;;
    *) printf '\n%s\n' "$2"; read -rp "Press Enter to continue. " _ ;;
  esac
  return 0
}
ui_ask() {        # ui_ask KEY "text" [yes-label] [no-label]   prints yes | no | skip
  local a rc out
  if a=$(_ui_auto "$1"); then echo "$a"; return 0; fi
  case $(_ui_tool) in
    kdialog) kdialog --title "$UI_TITLE" --icon "$UI_ICON" --yes-label "${3:-Yes}" --no-label "${4:-No}" \
               --cancel-label "Skip for now" --yesnocancel "$2"; rc=$?
             case $rc in 0) echo yes ;; 1) echo no ;; *) echo skip ;; esac ;;
    zenity)  out=$(zenity --question --title="$UI_TITLE" --icon-name="$UI_ICON" --width=480 --text="$2" \
               --ok-label="${3:-Yes}" --cancel-label="${4:-No}" --extra-button="Skip for now"); rc=$?
             if [ $rc = 0 ]; then echo yes; elif [ "$out" = "Skip for now" ] || [ $rc -gt 1 ]; then echo skip; else echo no; fi ;;
    *) printf '\n%s\n' "$2"; read -rp "[y]es / [n]o / [s]kip: " a
       case $a in y*|Y*) echo yes ;; n*|N*) echo no ;; *) echo skip ;; esac ;;
  esac
}
ui_choose() {     # ui_choose KEY "text" tag "label" tag "label" ...   prints the chosen tag, or skip
  local key=$1 text=$2 a; shift 2
  if a=$(_ui_auto "$key"); then echo "$a"; return 0; fi
  local args=() first=on
  case $(_ui_tool) in
    kdialog) while [ $# -ge 2 ]; do args+=("$1" "$2" "$first"); first=off; shift 2; done
             a=$(kdialog --title "$UI_TITLE" --icon "$UI_ICON" --radiolist "$text" "${args[@]}") || a=skip ;;
    zenity)  first=TRUE; while [ $# -ge 2 ]; do args+=("$first" "$1" "$2"); first=FALSE; shift 2; done
             a=$(zenity --list --radiolist --title="$UI_TITLE" --width=560 --height=360 --text="$text" \
                   --column="" --column="tag" --column="Choice" --hide-column=2 --print-column=2 "${args[@]}") || a=skip ;;
    *) printf '\n%s\n' "$text"; while [ $# -ge 2 ]; do printf '  %s) %s\n' "$1" "$2"; shift 2; done
       read -rp "Type your choice: " a ;;
  esac
  echo "${a:-skip}"
}
ui_input() {      # ui_input KEY "text" [default]   prints the text, empty if cancelled
  local a
  if a=$(_ui_auto "$1"); then [ "$a" = skip ] && a=""; echo "$a"; return 0; fi
  case $(_ui_tool) in
    kdialog) kdialog --title "$UI_TITLE" --inputbox "$2" "${3:-}" ;;
    zenity)  zenity --entry --title="$UI_TITLE" --width=480 --text="$2" --entry-text="${3:-}" ;;
    *) read -rp "$2 " a; echo "${a:-${3:-}}" ;;
  esac
}
ui_password() {   # ui_password KEY "text"   prints the password, empty if cancelled
  local a
  if a=$(_ui_auto "$1"); then [ "$a" = skip ] && a=""; echo "$a"; return 0; fi
  case $(_ui_tool) in
    kdialog) kdialog --title "$UI_TITLE" --password "$2" ;;
    zenity)  zenity --entry --hide-text --title="$UI_TITLE" --width=480 --text="$2" ;;
    *) read -rsp "$2 " a; echo >&2; echo "$a" ;;
  esac
}
# ui_terminal CMD...   run a command where the user can watch it (Konsole / Xfce Terminal), wait for it
ui_terminal() {
  if [ -n "${SL_WIZARD_ANSWERS:-}" ]; then "$@"; return; fi
  if command -v secure-linux-terminal >/dev/null 2>&1; then secure-linux-terminal --hold "$@"
  elif command -v konsole >/dev/null 2>&1; then konsole --hold -e "$@"
  elif command -v xfce4-terminal >/dev/null 2>&1; then xfce4-terminal --hold -x "$@"
  else "$@"; fi
}
