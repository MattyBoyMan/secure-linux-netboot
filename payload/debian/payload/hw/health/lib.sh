# shellcheck shell=bash
# hw/health/lib.sh (owner: hardware) - shared helpers for secure-linux-health, -repair, -parts and
# rescue/secure-linux-rescue.sh. Source it; do not run it.
#
# It must work on THREE kinds of system: the installed Fedora, a SystemRescue / live shell (no
# /usr/local/lib/secure-linux, maybe no root, maybe no network) and the Fedora installer's rescue shell.
# So: no dependency on lib/common.sh (used when present), bash 4+, coreutils, sed, awk, grep only.
#
# Test hooks (never set on a real machine):
#   SL_TEST_SYSFS / SL_TEST_PROC / SL_TEST_DEV   replace /sys /proc /dev      SL_STATE  state folder
#   SL_HEALTH_ANSWERS or SL_WIZARD_ANSWERS       "key=value,key=value" answers for dialogs (nothing is shown)
[ -n "${SLH_LIB_LOADED:-}" ] && return 0
SLH_LIB_LOADED=1

SLH_SYS=${SL_TEST_SYSFS:-/sys}
SLH_PROC=${SL_TEST_PROC:-/proc}
SLH_DEV=${SL_TEST_DEV:-/dev}
SL_STATE=${SL_STATE:-/var/lib/secure-linux}
SL_ETC=${SL_ETC:-/etc/secure-linux}

have() { command -v "$1" >/dev/null 2>&1; }
# No forks in the helpers below: this tool must also be fast on a very old computer.
slh_is_root() { [ "${SL_TEST_UID:-${EUID:-0}}" = 0 ]; }
slh_rd() { local v=""; if [ -r "$1" ]; then IFS= read -r v < "$1" 2>/dev/null; fi; v=${v%$'\r'}; v=${v%"${v##*[![:space:]]}"}; printf '%s' "$v"; }
slh_rdv() { local __v=""; if [ -r "$2" ]; then IFS= read -r __v < "$2" 2>/dev/null; fi; __v=${__v%$'\r'}; __v=${__v%"${__v##*[![:space:]]}"}; printf -v "$1" '%s' "$__v"; }   # slh_rdv VAR FILE
sysrd() { slh_rd "$SLH_SYS/$1"; }                       # sysrd class/dmi/id/sys_vendor
slh_num() { local v=${1:-}; v=${v//[^0-9.-]/}; printf '%s' "${v:-0}"; }
_slh_i() { local v=${1:-} neg=""; v=${v//[^0-9.-]/}; v=${v%%.*}; case "$v" in -*) neg=-; v=${v#-} ;; esac; v=${v//-/}; while [ "${v#0}" != "$v" ] && [ -n "${v#0}" ]; do v=${v#0}; done; _I=$(( ${neg}${v:-0} )); }
slh_ge() { local a; _slh_i "$1"; a=$_I; _slh_i "$2"; (( a >= _I )); }     # integer part compare: slh_ge A B  (A >= B)
slh_gt() { local a; _slh_i "$1"; a=$_I; _slh_i "$2"; (( a > _I )); }
slh_lt() { local a; _slh_i "$1"; a=$_I; _slh_i "$2"; (( a < _I )); }
slh_t() { local s=$1; shift; if have timeout; then timeout "$s" "$@"; else "$@"; fi; }   # slh_t SECONDS cmd...
slh_lc() { printf '%s' "${1,,}"; }
slh_drv() {   # slh_drv PATH -> driver name from a driver symlink (a plain file holds the name in test fixtures)
  local p=$1; [ -e "$p" ] || return 0
  if [ -L "$p" ]; then basename "$(readlink -f "$p" 2>/dev/null)"; elif [ -f "$p" ]; then slh_rd "$p"; fi
}
slh_trim() { local v=$1; v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}; printf '%s' "$v"; }
slh_human_bytes() {   # bytes -> "238 GB" / "1.8 TB" (decimal, like the drive's label)
  awk -v b="$(slh_num "$1")" 'BEGIN{ if (b>=1e12) printf "%.1f TB", b/1e12; else if (b>=1e9) printf "%d GB", b/1e9+0.5; else if (b>=1e6) printf "%d MB", b/1e6+0.5; else printf "%d bytes", b }'
}
slh_escv() {   # slh_escv VALUE -> ESC : JSON string escape (no surrounding quotes), without forks
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/ }; s=${s//$'\r'/ }; s=${s//$'\t'/ }
  s=${s//[$'\001'-$'\010'$'\013'$'\014'$'\016'-$'\037']/}
  ESC=$s
}
slh_esc() { slh_escv "$1"; printf '%s' "$ESC"; }
slh_date() { local f=${1#+}; printf "%($f)T" -1; }   # slh_date '+%Y-%m-%d' (bash builtin, no fork)
slh_pretty_name() { local v=${1//_/ }; while [[ $v == *"  "* ]]; do v=${v//  / }; done; v=${v# }; v=${v% }; printf '%s' "$v"; }

# ---------------------------------------------------------------- results
# res PART[:ITEM] STATUS "what it means" ["what to do"] ["technical detail"]
# STATUS: OK | WARN | FAIL | NOT-PRESENT | SKIPPED   (SKIPPED = could not be checked: tool missing / needs admin / needs you)
SLH_N=0
declare -a R_PART=() R_ITEM=() R_STATUS=() R_MEANING=() R_TODO=() R_DETAIL=()
SLH_ITEM_FILTER=""
res() {
  local p=${1%%:*} i="" st=$2
  case "$1" in *:*) i=${1#*:} ;; esac
  if [ -n "$SLH_ITEM_FILTER" ] && [ "$p" = "${SLH_ITEM_FILTER%%:*}" ] && [ "$i" != "${SLH_ITEM_FILTER#*:}" ]; then return 0; fi
  case "$st" in OK|WARN|FAIL|NOT-PRESENT|SKIPPED) ;; *) st=SKIPPED ;; esac
  R_PART[SLH_N]=$p; R_ITEM[SLH_N]=$i; R_STATUS[SLH_N]=$st
  R_MEANING[SLH_N]=$3; R_TODO[SLH_N]=${4:-}; R_DETAIL[SLH_N]=${5:-}
  SLH_N=$((SLH_N + 1))
  return 0
}
declare -A SLH_MISSING=()    # tool -> "what it is for|fedora package"
declare -a SLH_LIMITED=()    # plain-English notes about checks that were limited (no admin rights, ...)
need() {   # need TOOL "what it is used for" "fedora package"   true if present; otherwise remembers what is missing
  have "$1" && return 0
  SLH_MISSING[$1]="$2|${3:-$1}"
  return 1
}
limited() { local x; for x in "${SLH_LIMITED[@]:-}"; do [ "$x" = "$1" ] && return 0; done; SLH_LIMITED+=("$1"); }
needroot() {   # needroot "what" -> true if root; otherwise remembers that this check is limited
  slh_is_root && return 0
  limited "$1 (needs administrator rights: run again with sudo, or add --elevate)"
  return 1
}

# ---------------------------------------------------------------- kernel log (read once)
SLH_KLOG=""
slh_klog_load() {   # SLH_KLOG = file with the kernel messages of this boot (empty if unreadable)
  [ -n "$SLH_KLOG" ] && return 0
  SLH_KLOG=${TMPD:-${TMPDIR:-/tmp}}/slh-klog.$
  : > "$SLH_KLOG"
  if have dmesg && dmesg > "$SLH_KLOG" 2>/dev/null && [ -s "$SLH_KLOG" ]; then return 0; fi
  if have journalctl && slh_t 20 journalctl -k -b --no-pager -q > "$SLH_KLOG" 2>/dev/null && [ -s "$SLH_KLOG" ]; then return 0; fi
  limited "kernel messages could not be read (needs administrator rights)"
  return 0
}
klog_count() { slh_klog_load; local n; n=$(grep -ciE "$1" "$SLH_KLOG" 2>/dev/null); printf '%s' "${n:-0}"; }
klog_n() { slh_klog_load; local __n; __n=$(grep -ciE "$2" "$SLH_KLOG" 2>/dev/null); printf -v "$1" '%s' "${__n:-0}"; }   # klog_n VAR REGEX  (no extra subshell)
klog_grep() { slh_klog_load; grep -iE "$1" "$SLH_KLOG" 2>/dev/null | head -n "${2:-3}"; }

# ---------------------------------------------------------------- temperatures (sysfs only: works without lm_sensors)
slh_temps() {   # prints  LABEL|degC|crit_degC|source   for every hwmon temp input and thermal zone
  local f d n label crit v c nm t
  for f in "$SLH_SYS"/class/hwmon/hwmon*/temp*_input; do
    [ -r "$f" ] || continue
    d=${f%/*}; n=${f##*/}; n=${n%_input}
    slh_rdv v "$f"; [ -n "$v" ] || continue
    slh_rdv label "$d/${n}_label"; [ -n "$label" ] || label=$n
    slh_rdv crit "$d/${n}_crit"; [ -n "$crit" ] && crit=$(( crit / 1000 ))
    slh_rdv nm "$d/name"
    printf '%s|%s|%s|hwmon:%s
' "$label" "$(( v / 1000 ))" "${crit:-}" "$nm"
  done
  for d in "$SLH_SYS"/class/thermal/thermal_zone*; do
    [ -r "$d/temp" ] || continue
    slh_rdv v "$d/temp"; [ -n "$v" ] || continue
    crit=""
    for f in "$d"/trip_point_*_type; do [ -r "$f" ] || continue; slh_rdv t "$f"; [ "$t" = critical ] && slh_rdv crit "${f%_type}_temp"; done
    [ -n "$crit" ] && crit=$(( crit / 1000 ))
    slh_rdv t "$d/type"
    printf '%s|%s|%s|zone:%s
' "$t" "$(( v / 1000 ))" "${crit:-}" "${d##*/}"
  done
}

# ---------------------------------------------------------------- PCI / USB discovery (sysfs first; lspci / lsusb only for names)
slh_pci_list() {   # prints  SLOT|VENDOR|DEVICE|CLASS|DRIVER   (hex lower case, class = 6 digits)
  local d s v dv c drv
  for d in "$SLH_SYS"/bus/pci/devices/*; do
    [ -d "$d" ] || continue
    s=${d##*/}; slh_rdv v "$d/vendor"; slh_rdv dv "$d/device"; slh_rdv c "$d/class"
    v=${v#0x}; dv=${dv#0x}; c=${c#0x}
    drv=$(slh_drv "$d/driver")
    printf '%s|%s|%s|%s|%s
' "$s" "${v,,}" "${dv,,}" "${c,,}" "$drv"
  done
}
slh_pci_name() {   # slh_pci_name SLOT VENDOR DEVICE -> "Intel Corporation Wi-Fi 6 AX201" (lspci if there, else the ids)
  local n=""
  if have lspci; then n=$(lspci -s "$1" 2>/dev/null | head -n1 | sed 's/^[^ ]* [^:]*: //'); fi
  [ -n "$n" ] || n="device $2:$3 at $1"
  printf '%s' "$n"
}
slh_usb_list() {   # prints  BUSID|VID|PID|PRODUCT|MANUFACTURER|DEVCLASS|SPEED|VERSION   for every USB device (not root hubs)
  local d id a b p m c sp ve
  for d in "$SLH_SYS"/bus/usb/devices/*; do
    [ -r "$d/idVendor" ] || continue
    id=${d##*/}
    case "$id" in usb*) continue ;; esac
    slh_rdv a "$d/idVendor"; slh_rdv b "$d/idProduct"; slh_rdv p "$d/product"; slh_rdv m "$d/manufacturer"; slh_rdv c "$d/bDeviceClass"; slh_rdv sp "$d/speed"; slh_rdv ve "$d/version"
    printf '%s|%s|%s|%s|%s|%s|%s|%s
' "$id" "$a" "$b" "$p" "$m" "$c" "$sp" "$ve"
  done
}
slh_usb_ifaces() {   # prints  BUSID|CLASS|SUBCLASS|DRIVER  for every USB interface
  local d drv c sc
  for d in "$SLH_SYS"/bus/usb/devices/*:*; do
    [ -r "$d/bInterfaceClass" ] || continue
    drv=$(slh_drv "$d/driver"); slh_rdv c "$d/bInterfaceClass"; slh_rdv sc "$d/bInterfaceSubClass"
    printf '%s|%s|%s|%s
' "${d##*/}" "$c" "$sc" "$drv"
  done
}
slh_chassis() {   # laptop | desktop | other  (DMI chassis type)
  case "$(sysrd class/dmi/id/chassis_type)" in 8|9|10|11|14|30|31|32) echo laptop ;; 3|4|5|6|7|13|15|16|17|23|24|35|36) echo desktop ;; *) echo other ;; esac
}

# ---------------------------------------------------------------- state / output folders
slh_state_dir() {   # where reports go: the system folder if writable, else the user's, else /tmp
  local d=${SL_HEALTH_DIR:-}
  if [ -z "$d" ]; then
    d=$SL_STATE/health
    if ! { mkdir -p "$d" 2>/dev/null && [ -w "$d" ]; }; then
      d=${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/secure-linux/health
      if ! { mkdir -p "$d" 2>/dev/null && [ -w "$d" ]; }; then d=${TMPDIR:-/tmp}/secure-linux-health; mkdir -p "$d" 2>/dev/null; fi
    fi
  else mkdir -p "$d" 2>/dev/null; fi
  printf '%s' "$d"
}
slh_alert() {   # slh_alert id "Title" "Message" ["Action"]   same 3-line format as lib/common.sh sl_alert
  [ -d "$SL_STATE/alerts.d" ] && [ -w "$SL_STATE/alerts.d" ] || { [ -d "$SL_STATE" ] && [ -w "$SL_STATE" ] && mkdir -p "$SL_STATE/alerts.d" 2>/dev/null; } || return 1
  printf '%s\n%s\n%s\n' "$2" "$3" "${4:-}" > "$SL_STATE/alerts.d/$1" 2>/dev/null && chmod 644 "$SL_STATE/alerts.d/$1" 2>/dev/null
}
slh_alert_clear() { rm -f "$SL_STATE/alerts.d/$1" 2>/dev/null; }
slh_event() {
  [ -d "$SL_STATE" ] && [ -w "$SL_STATE" ] || return 1
  mkdir -p "$SL_STATE/events.d" 2>/dev/null
  printf '%s\n%s\n' "$2" "$3" > "$SL_STATE/events.d/$1" 2>/dev/null && chmod 644 "$SL_STATE/events.d/$1" 2>/dev/null
}

# ---------------------------------------------------------------- dialogs: kdialog / zenity / whiptail / dialog / plain text
SLH_TITLE=${SLH_TITLE:-"Secure Linux"}
slh_gui_ok() { [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; }
slh_scripted() { [ -n "${SL_HEALTH_ANSWERS:-}${SL_WIZARD_ANSWERS:-}" ]; }
_slh_auto() {   # _slh_auto KEY -> the scripted answer (or "skip"); returns 1 if not in scripted mode
  slh_scripted || return 1
  local a; a=$(printf ',%s,' "${SL_HEALTH_ANSWERS:-}${SL_HEALTH_ANSWERS:+,}${SL_WIZARD_ANSWERS:-}" | sed -n "s/.*,$1=\([^,]*\),.*/\1/p" | head -n1)
  printf '%s' "${a:-skip}"
}
slh_ui_tool() {   # kdialog | zenity | whiptail | dialog | tty | none
  [ -n "${SLH_UI:-}" ] && { echo "$SLH_UI"; return; }
  if slh_gui_ok; then
    case "${XDG_CURRENT_DESKTOP:-}" in *KDE*) have kdialog && { echo kdialog; return; } ;; esac
    have zenity && { echo zenity; return; }
    have kdialog && { echo kdialog; return; }
  fi
  if [ -t 0 ] && [ -t 1 ]; then
    have whiptail && { echo whiptail; return; }
    have dialog && { echo dialog; return; }
    echo tty; return
  fi
  echo none
}
slh_interactive_possible() { slh_scripted || [ "$(slh_ui_tool)" != none ]; }
slh_info() {   # slh_info KEY "text"
  local a; if a=$(_slh_auto "$1"); then return 0; fi
  case "$(slh_ui_tool)" in
    kdialog) kdialog --title "$SLH_TITLE" --msgbox "$2" ;;
    zenity) zenity --info --no-markup --title="$SLH_TITLE" --width=480 --text="$2" ;;
    whiptail) whiptail --title "$SLH_TITLE" --msgbox "$2" 18 72 ;;
    dialog) dialog --title "$SLH_TITLE" --msgbox "$2" 18 72; clear ;;
    tty) printf '\n%s\n' "$2"; read -rp "Press Enter to continue. " _ ;;
    *) printf '%s\n' "$2" ;;
  esac
  return 0
}
slh_ask() {   # slh_ask KEY "question" [yes-label] [no-label] -> prints yes | no | skip
  local a yes=${3:-Yes} no=${4:-No}
  if a=$(_slh_auto "$1"); then printf '%s' "$a"; return 0; fi
  case "$(slh_ui_tool)" in
    kdialog) kdialog --title "$SLH_TITLE" --yes-label "$yes" --no-label "$no" --yesno "$2" && echo yes || echo no ;;
    zenity) zenity --question --no-markup --title="$SLH_TITLE" --width=480 --ok-label="$yes" --cancel-label="$no" --text="$2" && echo yes || echo no ;;
    whiptail) whiptail --title "$SLH_TITLE" --yes-button "$yes" --no-button "$no" --yesno "$2" 18 72 && echo yes || echo no ;;
    dialog) dialog --title "$SLH_TITLE" --yes-label "$yes" --no-label "$no" --yesno "$2" 18 72 && echo yes || echo no; clear ;;
    tty) local r; printf '\n%s\n' "$2" >&2; read -rp "[$yes = y / $no = n / skip = s] > " r; case "$r" in [Yy]*) echo yes ;; [Nn]*) echo no ;; *) echo skip ;; esac ;;
    *) echo skip ;;
  esac
}
slh_show_file() {   # slh_show_file "Title" FILE   scrollable text
  case "$(slh_ui_tool)" in
    kdialog) kdialog --title "$1" --textbox "$2" 720 520 ;;
    zenity) zenity --text-info --title="$1" --width=720 --height=520 --filename="$2" ;;
    whiptail) whiptail --title "$1" --scrolltext --textbox "$2" 22 76 ;;
    dialog) dialog --title "$1" --textbox "$2" 22 76; clear ;;
    *) cat "$2" ;;
  esac
}

# ---------------------------------------------------------------- plain-text prompts for the repair tools (stdin)
# These never decide for the user: no timeouts, default is always "no".
slh_say() { printf '%s\n' "$*"; }
slh_read() {   # slh_read VAR "prompt"  -> reads one line from stdin; returns 1 at end of input
  local __v
  printf '%s' "$2" >&2   # printed here (not by read -p) so the question also shows when input is piped or logged
  if ! IFS= read -r __v; then echo; return 1; fi
  printf -v "$1" '%s' "$__v"
}
# The shared look and feel (lib/sl-ui.sh) is used when it can be found; without it the plain versions below still work.
if ! declare -F ui_header >/dev/null; then
  for _slh_c in "${SL_ROOT:-/usr/local/lib/secure-linux}/lib/sl-ui.sh" "${BASH_SOURCE[0]%/*}/../../lib/sl-ui.sh"; do
    [ -r "$_slh_c" ] && { . "$_slh_c"; break; }
  done
fi
slh_confirm() {   # slh_confirm "question"  -> 0 only for an explicit y / yes (anything else, or end of input, means no)
  local a
  if declare -F ui_hint >/dev/null; then
    _ui_ensure; _ui_q slh_confirm; printf '\n%s\n' "$1"; ui_hint "Type y for yes. Anything else means no, and nothing changes."
    _ui_read a "Your answer [n]: " || return 1
  else slh_read a "$1 [y/N] " || return 1; fi
  case "$(slh_lc "$a")" in y|yes) return 0 ;; *) return 1 ;; esac
}
slh_typed() {   # slh_typed "WORD" "why" -> 0 only if the user types WORD exactly
  local a
  if declare -F ui_hint >/dev/null; then
    _ui_ensure; _ui_q slh_typed; printf '%s\n' "$2"; ui_hint "To go ahead, type the words exactly as shown. Anything else cancels and changes nothing."
    _ui_read a "Type  $1  to go ahead: " || return 1
  else slh_say "$2"; slh_read a "Type  $1  to go ahead (anything else cancels): " || return 1; fi
  [ "$a" = "$1" ]
}
slh_menu() {   # slh_menu "Title" "key|Label" ... -> prints the chosen key (reads a number from stdin); empty = quit
  local title=$1; shift
  local i=1 entry a keys=()
  { printf '\n=== %s ===\n' "$title"
    for entry in "$@"; do printf ' %2d) %s\n' "$i" "${entry#*|}"; keys[i]=${entry%%|*}; i=$((i + 1)); done
    printf '  0) Quit\n'; } >&2
  slh_read a "Choose a number: " || { echo ""; return 0; }
  if [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -lt "$i" ]; then echo "${keys[a]}"; else echo ""; fi
}
