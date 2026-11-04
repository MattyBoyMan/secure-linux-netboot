#!/bin/bash
# first-login.sh (comfort): per-user settings, run by the autostart entry secure-linux-comfort.desktop at
# every login. Each part runs ONCE per user (a mark in ~/.local/state/secure-linux/comfort/), except the
# searchable guide, which is refreshed when the guide itself is updated.
#   Screen scaling 150% on the 2.5K laptop screen (full/KDE, panel >= 2560 px wide), cursor size 30
#   Touchpad like Windows (KDE; lite gets a system-wide X11 setting from step 75)
#   Australian formats and spell-check on KDE
#   ~/Documents/Secure Linux Guide/ (Markdown copy of START-HERE for the app-launcher search)
#   Daily tips: start the 14-day series
#   first-login.sh --force PART   run one part again (scale touchpad formats guide tips)
set -uo pipefail
SL_ROOT=${SL_ROOT:-/usr/local/lib/secure-linux}
. "$SL_ROOT/lib/common.sh"
. "$SL_ROOT/files/comfort/comfort-lib.sh"

MARKS=$CF_USTATE/comfort
mkdir -p "$MARKS"
FORCE=""
[ "${1:-}" = --force ] && FORCE=${2:-}
once() {   # once PART CMD...   run CMD unless PART is done; mark it done when CMD succeeds
  local part=$1; shift
  [ -e "$MARKS/$part" ] && [ "$FORCE" != "$part" ] && return 0
  "$@" && date +%F > "$MARKS/$part"
  return 0
}
DESK=$(cf_desktop)
PROFILE=$(sl_profile)

# ---------------------------------------------------------------- screen scaling (KDE Plasma 6)
# kscreen-doctor -j lists outputs (name, connected, enabled, scale, currentModeId, modes[].size.width).
# The laptop's own panel is eDP-* (LVDS-*/DSI-* on other machines).
internal_output() {
  kscreen-doctor -j 2>/dev/null | python3 -c '
import json, sys
try:
    cfg = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
for o in cfg.get("outputs", []):
    name = o.get("name", "")
    if o.get("connected") and o.get("enabled", True) and name.split("-")[0] in ("eDP", "LVDS", "DSI"):
        width = 0
        for m in o.get("modes", []):
            if str(m.get("id")) == str(o.get("currentModeId")):
                width = int((m.get("size") or {}).get("width", 0))
        print(name, width, o.get("scale", 1))
        sys.exit(0)
sys.exit(1)'
}
do_scale() {
  [ "$PROFILE" = full ] && [ "$DESK" = kde ] || return 0
  cf_have kscreen-doctor || return 1          # Plasma not ready yet: try again next login
  local name width scale want pct
  read -r name width scale < <(internal_output) || return 0   # no laptop panel (desktop PC): nothing to do
  [ -n "$name" ] || return 0
  [ "${width:-0}" -ge 2560 ] 2>/dev/null || { width=$(cf_panel_width); [ "${width:-0}" -ge 2560 ] || return 0; }
  pct=$(cat "$HOME/.config/secure-linux/display-scale" 2>/dev/null); pct=${pct:-150}
  want=$(awk -v p="$pct" 'BEGIN{printf "%g", p/100}')
  if [ "$scale" != "$want" ]; then
    kscreen-doctor "output.$name.scale.$want" >/dev/null 2>&1 || return 1
  fi
  # Bigger cursor to match (applies from the next login). Legacy X11 apps keep Plasma 6's default
  # "Apply scaling themselves", so they stay sharp; we don't change it.
  cf_kconf kcminputrc Mouse cursorSize 30
  return 0
}

# ---------------------------------------------------------------- touchpad (KDE)
# KWin reads kcminputrc [Libinput][Defaults][Touchpad] for every touchpad, then per-device groups
# [Libinput][vendor][product][name] (decimal ids). We write both so it works even if the device
# group already exists. ClickMethod 2 = "clickfinger": click with two fingers = right click.
touchpad_devices() {   # prints "vendor_dec product_dec name" for each touchpad the kernel knows
  local devs=${CF_TEST_INPUT_DEVICES:-/proc/bus/input/devices}
  [ -r "$devs" ] || return 0
  awk '
    /^I:/ { v=""; p=""; for (i=1;i<=NF;i++) { if ($i ~ /^Vendor=/) v=substr($i,8); if ($i ~ /^Product=/) p=substr($i,9) } }
    /^N: Name=/ { n=$0; sub(/^N: Name="/,"",n); sub(/"$/,"",n) }
    /^$/ { if (n ~ /[Tt]ouchpad/) printf "%d %d %s\n", strtonum("0x" v), strtonum("0x" p), n; n="" }
    END { if (n ~ /[Tt]ouchpad/) printf "%d %d %s\n", strtonum("0x" v), strtonum("0x" p), n }' "$devs" 2>/dev/null
}
tp_write() {   # tp_write "Group/path"
  cf_kconf kcminputrc "$1" TapToClick true
  cf_kconf kcminputrc "$1" ClickMethod 2
  cf_kconf kcminputrc "$1" DisableWhileTyping true
  cf_kconf kcminputrc "$1" NaturalScroll true
}
do_touchpad() {
  [ "$DESK" = kde ] || return 0
  cf_have kwriteconfig6 || cf_have kwriteconfig5 || return 1
  tp_write "Libinput/Defaults/Touchpad"
  local v p n
  while read -r v p n; do
    [ -n "$n" ] && tp_write "Libinput/$v/$p/$n"
  done < <(touchpad_devices)
  cf_kde_notify 3 0
  return 0
}

# ---------------------------------------------------------------- formats and spelling (KDE)
do_formats() {
  [ "$DESK" = kde ] || return 0
  cf_have kwriteconfig6 || cf_have kwriteconfig5 || return 1
  local sys_lang; sys_lang=$(sed -n 's/^LANG="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$CF_R/etc/locale.conf" 2>/dev/null)
  case ${sys_lang:-en_AU.UTF-8} in
    en_AU*)
      # Dates (2/11/2026), dollars and A4 the Australian way; British spelling for the menus (there is
      # no separate Australian translation) - only if the user hasn't chosen something themselves.
      [ -z "$(cf_kread plasma-localerc Formats LANG 2>/dev/null)" ] && cf_kconf plasma-localerc Formats LANG en_AU.UTF-8
      [ -z "$(cf_kread plasma-localerc Translations LANGUAGE 2>/dev/null)" ] && cf_kconf plasma-localerc Translations LANGUAGE "en_AU:en_GB:en_US"
      mkdir -p "$HOME/.config/KDE"
      [ -z "$(cf_kread KDE/Sonnet.conf General defaultLanguage 2>/dev/null)" ] && cf_kconf KDE/Sonnet.conf General defaultLanguage en_AU
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------- searchable guide
do_guide() {
  [ -f "$CF_GUIDE" ] || return 1               # guide not installed yet: try next login
  cf_have python3 || return 1
  local docs out stamp
  docs=$(xdg-user-dir DOCUMENTS 2>/dev/null); [ -n "$docs" ] && [ "$docs" != "$HOME" ] || docs=$HOME/Documents
  out="$docs/Secure Linux Guide"; stamp=$MARKS/guide-stamp
  if [ -e "$stamp" ] && [ ! "$CF_GUIDE" -nt "$stamp" ] && [ "$FORCE" != guide ] && [ -d "$out" ]; then return 0; fi
  mkdir -p "$out"
  python3 "$CF_FILES/guide2md.py" "$CF_GUIDE" "$out" --link-base "file:///usr/share/secure-linux/START-HERE.html" >/dev/null || return 1
  touch "$stamp"
}

# ---------------------------------------------------------------- tips
do_tips() {
  cf_have secure-linux-tips || [ -x "$SL_ROOT/bin/secure-linux-tips" ] || return 1
  "$SL_ROOT/bin/secure-linux-tips" --init >/dev/null 2>&1
}

[ -n "${CF_FIRST_LOGIN_DELAY:-}" ] || sleep 5   # let Plasma finish starting
once scale do_scale
once touchpad do_touchpad
once formats do_formats
do_guide
case "${USER:-}" in guest) ;; *) once tips do_tips ;; esac
exit 0
