# shellcheck shell=bash
# lib/sl-ui.sh - the ONE shared look and feel for every Secure Linux tool (owner: ux).
# Source it, do not run it:   . "$SL_ROOT/lib/sl-ui.sh"
#
# Three renderers, chosen automatically (see ../docs/notes/ux-style-guide.md):
#   gui    kdialog (KDE) or zenity (everything else): windows with large text and progress bars
#   rich   colour terminal: traffic-light colours, calm blue accents, box drawing (ASCII fallback on the Linux console),
#          progress bars, spinner, check marks. Needs 60+ columns (designed for 80x24 and up).
#   plain  no colour, no boxes, numbered questions: for ssh, pipes, scripts, screen readers
#
# How to use it (every function sets UI_REPLY when it returns an answer; never call them inside $( ) - the screen
# is drawn on stdout):
#   ui_header "Title"                       clear screen, show "Secure Linux" bar and "You are here: A > B"
#   ui_push "Name" / ui_pop                 breadcrumb steps
#   ui_banner ok|info|warn|fail "Big headline" ["small line"]
#   ui_card  ok|info|warn|fail "Title" "What this means" "text" "Why it matters" "text" ...
#   ui_traffic ok|info|warn|fail|skip "Label" ["detail"]
#   ui_say "text"      ui_h2 "Heading"      ui_list "item" ...      ui_table "A|B" "r1a|r1b" ...
#   ui_info "text"                          message that waits for Enter
#   ui_yesno "Question" [y|n] [yes-label] [no-label]    rc 0 = yes, 1 = no / back (default no)
#   ui_menu "Title" "key|Label|one-line help" ...        UI_REPLY = key; rc 1 = back (q). Never more than 7 on a page.
#   ui_choice "Question" "Label 1" "Label 2" ...         UI_REPLY = number
#   ui_input "Question" [default]   ui_secret "Question"   ui_typed "WORD" "why"   ui_wait
#   ui_progress_begin "Title"; ui_progress 40 "text"; ui_progress_end
#   ui_steps "done|Checked drives" "doing|Checking memory" "todo|..."     ui_task "Label" cmd args...
#   ui_error "What happened" "What to do next" ["technical detail"]      ui_text_file "Title" FILE
# Test and accessibility switches (environment):
#   SL_UI=gui|rich|plain|auto   SL_UI_SIZE=COLSxROWS   SL_UI_ASCII=1   SL_UI_UNICODE=1   SL_UI_THEME=contrast
#   NO_COLOR=1   TERM=dumb   SL_UI_TTY=0|1 (pretend)   SL_UI_FORCE_COLOR=1 (wins over NO_COLOR)
#   SL_ACCESSIBLE=1 / SL_UI_PLAIN=1 (plain mode)
#   Preferences file (~/.config/secure-linux/ui): mode=plain|rich|gui, theme=contrast, ascii=1
# The source is plain ASCII on purpose; the box and tick characters are built from bytes.

[ -n "${SLUI_LOADED:-}" ] && return 0
SLUI_LOADED=1
UI_APP=${UI_APP:-"Secure Linux"}
UI_REPLY=""
UI_MODE=""
declare -a UI_CRUMBS=() UI_LINES=() UI_STEP_STATE=() UI_STEP_TEXT=()
UI_GBUF=""
UI_MENU_BACK=${UI_MENU_BACK:-"Go back"}
UI_MENU_DEFAULT=${UI_MENU_DEFAULT:-1}      # 1 = Enter picks the first item, 0 = Enter asks again
UC_RST=""; UC_BOLD=""; UC_OK=""; UC_WARN=""; UC_FAIL=""; UC_BLUE=""; UC_DIM=""; UC_HDR=""; UC_EDGE=""

_ui_have() { command -v "$1" >/dev/null 2>&1; }
# every question that needs a decision is counted (tests assert how few we ask): set SL_UI_QLOG=file
UI_ASKED=0
_ui_q() { UI_ASKED=$((UI_ASKED + 1)); [ -n "${SL_UI_QLOG:-}" ] && printf '%s\n' "$1" >> "$SL_UI_QLOG"; return 0; }

# ---------------------------------------------------------------- choosing the renderer
_ui_gui_pick() {   # sets UI_GUI to kdialog | zenity ; false when there is no desktop or no tool
  UI_GUI=""
  [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || return 1
  case "${XDG_CURRENT_DESKTOP:-}" in *KDE*) _ui_have kdialog && { UI_GUI=kdialog; return 0; } ;; esac
  _ui_have zenity && { UI_GUI=zenity; return 0; }
  _ui_have kdialog && { UI_GUI=kdialog; return 0; }
  return 1
}
ui_init() {
  local want=${SL_UI:-auto} cols=80 rows=24 t=${TERM:-} loc tty=0 k v sz pm="" pt="" pa=""
  UI_PREF=${SL_UI_PREF:-${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/secure-linux/ui}
  if [ -r "$UI_PREF" ]; then
    while IFS='=' read -r k v; do case $k in mode) pm=$v ;; theme) pt=$v ;; ascii) pa=$v ;; esac; done < "$UI_PREF"
  fi
  [ "$want" = auto ] && [ -n "$pm" ] && want=$pm
  if [ -n "${SL_UI_SIZE:-}" ]; then cols=${SL_UI_SIZE%x*}; rows=${SL_UI_SIZE#*x}
  else
    if [ -t 1 ]; then
      sz=$(stty size </dev/tty 2>/dev/null) && { rows=${sz% *}; cols=${sz#* }; }
    fi
    [ -n "${COLUMNS:-}" ] && [ -z "${sz:-}" ] && cols=$COLUMNS
    [ -n "${LINES:-}" ] && [ -z "${sz:-}" ] && rows=$LINES
  fi
  case $cols in ''|*[!0-9]*) cols=80 ;; esac; case $rows in ''|*[!0-9]*) rows=24 ;; esac
  [ -t 0 ] && [ -t 1 ] && tty=1
  [ -n "${SL_UI_TTY:-}" ] && tty=$SL_UI_TTY
  UI_TTY=$tty
  UI_GUI=""
  case $want in
    gui)   if _ui_gui_pick; then UI_MODE=gui; elif [ $tty = 1 ]; then UI_MODE=rich; else UI_MODE=plain; fi ;;
    rich)  UI_MODE=rich ;;
    plain) UI_MODE=plain ;;
    *)     if [ -n "${SL_UI_PLAIN:-}${SL_ACCESSIBLE:-}" ]; then UI_MODE=plain
           elif [ $tty = 1 ]; then case $t in ''|dumb) UI_MODE=plain ;; *) UI_MODE=rich ;; esac
           elif _ui_gui_pick; then UI_MODE=gui
           else UI_MODE=plain; fi ;;
  esac
  [ "$UI_MODE" = rich ] && [ "$cols" -lt 60 ] && UI_MODE=plain
  [ "$UI_MODE" = gui ] && [ -z "$UI_GUI" ] && _ui_gui_pick
  # box characters: ASCII fallback on the Linux console / old terminals / when the language is not UTF-8
  UI_UNI=0; loc="${LC_ALL:-} ${LC_CTYPE:-} ${LANG:-}"
  case "${loc,,}" in *utf-8*|*utf8*) UI_UNI=1 ;; esac
  case $t in linux|dumb|vt100|vt220|ansi|'') UI_UNI=0 ;; esac
  [ -n "${SL_UI_UNICODE:-}" ] && UI_UNI=1
  [ "$UI_MODE" = gui ] && UI_UNI=1
  { [ -n "${SL_UI_ASCII:-}" ] || [ "$pa" = 1 ] || [ "$UI_MODE" = plain ]; } && UI_UNI=0
  UI_THEME=normal; { [ "${SL_UI_THEME:-}" = contrast ] || [ "$pt" = contrast ]; } && UI_THEME=contrast
  UI_COLOR=0
  # SL_UI_FORCE_COLOR=1 is an explicit "force it" switch: it wins over an ambient NO_COLOR, TERM=dumb and not-a-tty.
  if [ "$UI_MODE" = rich ]; then
    if [ -n "${SL_UI_FORCE_COLOR:-}" ]; then UI_COLOR=1
    elif [ -z "${NO_COLOR:-}" ] && [ "$t" != dumb ] && [ -t 1 ]; then UI_COLOR=1; fi
  fi
  UI_CLEAR=0; [ "$UI_MODE" = rich ] && [ -t 1 ] && [ -z "${SL_UI_NOCLEAR:-}" ] && UI_CLEAR=1
  UI_COLS=$cols; UI_ROWS=$rows
  UI_W=$((cols - 1)); [ "$UI_W" -gt 100 ] && UI_W=100
  UI_ROOMY=0; [ "$rows" -ge 34 ] && UI_ROOMY=1
  if [ "$UI_MODE" = rich ]; then UI_IW=$((UI_W - 4)); else UI_IW=$UI_W; [ "$UI_IW" -gt 76 ] && UI_IW=76; fi
  _ui_symbols; _ui_palette
}
ui_reinit() { UI_MODE=""; ui_init; }
_ui_ensure() { [ -n "$UI_MODE" ] || ui_init; }
ui_mode() { _ui_ensure; printf '%s' "$UI_MODE"; }

# ui_prefer_gui: use real windows whenever a desktop session is running and a dialog program
# (kdialog / zenity) exists - even when the tool was started from a terminal. Explicit choices always
# win: SL_UI=..., the saved preference file (Toolbox > Easier to read), and the screen-reader switch.
# Call BEFORE ui_init. (Owner's rule, 2026-11-03: "as pretty as can be, not like command lines".)
ui_prefer_gui() {
  [ "$(id -u)" = 0 ] && return 0   # root (installer, setup, pkexec helpers) always gets text renderers (L7)
  [ -n "${SL_UI:-}${SL_ACCESSIBLE:-}${SL_UI_PLAIN:-}" ] && return 0
  local pref=${SL_UI_PREF:-${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/secure-linux/ui}
  if [ -r "$pref" ] && grep -q '^mode=' "$pref" 2>/dev/null; then return 0; fi
  _ui_gui_pick || return 0
  SL_UI=gui
}

_ui_symbols() {
  if [ "$UI_UNI" = 1 ]; then
    S_H=$'\xe2\x94\x80'; S_V=$'\xe2\x94\x82'; S_TL=$'\xe2\x94\x8c'; S_TR=$'\xe2\x94\x90'; S_BL=$'\xe2\x94\x94'; S_BR=$'\xe2\x94\x98'
    S_DH=$'\xe2\x95\x90'; S_DV=$'\xe2\x95\x91'; S_DTL=$'\xe2\x95\x94'; S_DTR=$'\xe2\x95\x97'; S_DBL=$'\xe2\x95\x9a'; S_DBR=$'\xe2\x95\x9d'
    S_OK=$'\xe2\x9c\x94'; S_WARN=$'\xe2\x96\xb2'; S_FAIL=$'\xe2\x9c\x96'; S_INFO=$'\xe2\x97\x8f'; S_TODO=$'\xe2\x97\x8b'; S_DOING=$'\xe2\x96\xb6'; S_SKIP='-'
    S_ARR='>'; S_BUL=$'\xe2\x80\xa2'; S_FULL=$'\xe2\x96\x88'; S_EMP=$'\xe2\x96\x91'; UI_SYMW=1
    UI_SPIN=($'\xe2\xa0\x8b' $'\xe2\xa0\x99' $'\xe2\xa0\xb9' $'\xe2\xa0\xb8' $'\xe2\xa0\xbc' $'\xe2\xa0\xb4' $'\xe2\xa0\xa6' $'\xe2\xa0\xa7' $'\xe2\xa0\x87' $'\xe2\xa0\x8f')
  else
    S_H='-'; S_V='|'; S_TL='+'; S_TR='+'; S_BL='+'; S_BR='+'; S_DH='='; S_DV='|'; S_DTL='+'; S_DTR='+'; S_DBL='+'; S_DBR='+'
    S_OK='[OK]'; S_WARN='[!!]'; S_FAIL='[XX]'; S_INFO='[ i]'; S_TODO='[  ]'; S_DOING='[..]'; S_SKIP='[--]'
    S_ARR='>'; S_BUL='*'; S_FULL='#'; S_EMP='-'; UI_SYMW=4
    UI_SPIN=('|' '/' '-' '\')
  fi
}
_ui_palette() {
  UC_RST=""; UC_BOLD=""; UC_OK=""; UC_WARN=""; UC_FAIL=""; UC_BLUE=""; UC_DIM=""; UC_HDR=""
  [ "$UI_COLOR" = 1 ] || return 0
  local e=$'\e['
  UC_RST="${e}0m"; UC_BOLD="${e}1m"
  if [ "$UI_THEME" = contrast ]; then
    UC_OK="${e}1;92m"; UC_WARN="${e}1;93m"; UC_FAIL="${e}1;91m"; UC_BLUE="${e}1;96m"; UC_DIM=""; UC_HDR="${e}1;30;47m"
  else
    UC_OK="${e}1;32m"; UC_WARN="${e}1;33m"; UC_FAIL="${e}1;31m"; UC_DIM="${e}90m"; UC_HDR="${e}1;37;44m"
    case "${TERM:-}" in *256color*) UC_BLUE="${e}38;5;75m" ;; *) UC_BLUE="${e}1;34m" ;; esac
  fi
}

# ---------------------------------------------------------------- small helpers (no forks)
_ui_rep() { local n=$2; if [ "$n" -le 0 ]; then UI_R=""; return 0; fi; printf -v UI_R '%*s' "$n" ''; UI_R=${UI_R// /$1}; }
_ui_sevc() { case "${1:-info}" in ok) UI_SC=$UC_OK ;; warn) UI_SC=$UC_WARN ;; fail) UI_SC=$UC_FAIL ;; *) UI_SC=$UC_BLUE ;; esac; }
_ui_sym() { case "${1:-info}" in ok) UI_SY=$S_OK ;; warn) UI_SY=$S_WARN ;; fail) UI_SY=$S_FAIL ;; skip) UI_SY=$S_SKIP ;; todo) UI_SY=$S_TODO ;; doing) UI_SY=$S_DOING ;; *) UI_SY=$S_INFO ;; esac; }
_ui_word() { case "${1:-info}" in ok) UI_WD="Healthy" ;; warn) UI_WD="Attention" ;; fail) UI_WD="Problem" ;; skip) UI_WD="Skipped" ;; *) UI_WD="Note" ;; esac; }
_ui_wrap() {   # _ui_wrap WIDTH TEXT -> UI_LINES (word wrap; keeps blank lines, indentation and bullet hanging indents)
  local w=$1 text=$2 para lead body hang line cand word chunk n empty
  local -a words
  UI_LINES=(); [ "$w" -lt 12 ] && w=12
  while IFS= read -r para || [ -n "$para" ]; do
    if [ -z "${para//[[:space:]]/}" ]; then UI_LINES+=(""); continue; fi
    lead=${para%%[![:space:]]*}; body=${para#"$lead"}; hang=$lead
    case $body in
      "- "*|"* "*) hang="$lead  " ;;
      [0-9]". "*|[0-9]") "*) hang="$lead   " ;;
      [0-9][0-9]". "*|[0-9][0-9]") "*) hang="$lead    " ;;
    esac
    line=$lead; empty=1
    read -ra words <<< "$body"
    for word in "${words[@]}"; do
      if [ $empty = 1 ]; then cand="$line$word"; else cand="$line $word"; fi
      if [ ${#cand} -le "$w" ]; then line=$cand; empty=0; continue; fi
      if [ $empty = 0 ]; then UI_LINES+=("$line"); line=$hang; empty=1; cand="$line$word"; fi
      while [ ${#cand} -gt "$w" ]; do   # one word longer than a line: cut it
        n=$((w - ${#line})); chunk=${word:0:n}; UI_LINES+=("$line$chunk"); word=${word:n}; line=$hang; cand="$line$word"
      done
      line=$cand; empty=0
    done
    UI_LINES+=("$line")
  done <<< "$text"
}

# ---------------------------------------------------------------- GUI plumbing (kdialog / zenity)
_ui_g_add() { UI_GBUF+="$1"$'\n'; }
_ui_g_take() { UI_GBODY=${UI_GBUF%$'\n'}; UI_GBUF=""; }
_ui_gesc() { local s=$1; s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; printf '%s' "$s"; }
_ui_g_msg() {   # _ui_g_msg SEV BODY
  local sev=$1 body=$2 kind=--info
  case "$UI_GUI" in
    kdialog) case $sev in fail) kdialog --title "$UI_APP" --error "$body" ;; warn) kdialog --title "$UI_APP" --sorry "$body" ;; *) kdialog --title "$UI_APP" --msgbox "$body" ;; esac ;;
    *) case $sev in fail) kind=--error ;; warn) kind=--warning ;; esac
       zenity "$kind" --title="$UI_APP" --width=640 --text="<span size='large'>$(_ui_gesc "$body")</span>" ;;
  esac
}
_ui_g_ask() {   # _ui_g_ask BODY YES NO -> rc 0 yes
  case "$UI_GUI" in
    kdialog) kdialog --title "$UI_APP" --yes-label "$2" --no-label "$3" --yesno "$1" ;;
    *) zenity --question --title="$UI_APP" --width=640 --ok-label="$2" --cancel-label="$3" --text="<span size='large'>$(_ui_gesc "$1")</span>" ;;
  esac
}

# ---------------------------------------------------------------- screen furniture
ui_push() { UI_CRUMBS+=("$1"); }
ui_pop() { [ ${#UI_CRUMBS[@]} -gt 0 ] && unset 'UI_CRUMBS[${#UI_CRUMBS[@]}-1]'; UI_CRUMBS=("${UI_CRUMBS[@]}"); return 0; }
_ui_crumbs() { local c out="" sep=" $S_ARR "; for c in "${UI_CRUMBS[@]:-}"; do [ -n "$c" ] && out="${out:+$out$sep}$c"; done; UI_CR=$out; }
ui_logo() {
  _ui_ensure
  [ "$UI_MODE" = rich ] && [ "$UI_ROOMY" = 1 ] || return 0
  printf '%s     .-----.\n     | [+] |   %sSecure Linux Toolbox%s\n     \\     /   %sCheck it. Fix it. Rescue it.%s\n      %s---%s\n%s' "$UC_BLUE" "$UC_BOLD" "$UC_BLUE" "$UC_DIM" "$UC_BLUE" "'" "'" "$UC_RST"
}
ui_header() {   # ui_header "Title"  (clears the screen on a real terminal)
  _ui_ensure
  local title=$1 line1 line2 cr
  if [ "$UI_MODE" = gui ]; then UI_GBUF=""; _ui_g_add "$title"; _ui_g_add ""; return 0; fi
  [ "$UI_CLEAR" = 1 ] && printf '\033[H\033[2J\033[3J'
  _ui_crumbs; cr=$UI_CR
  line1="$UI_APP"; [ -n "$title" ] && line1="$UI_APP  $S_ARR  $title"
  line2="You are here: ${cr:-$title}"; [ ${#UI_CRUMBS[@]} -gt 0 ] && line2="$line2     (q = go back)"
  if [ "$UI_MODE" = rich ]; then
    local iw=$((UI_W - 4)) l
    [ ${#line1} -gt $iw ] && line1="${line1:0:$((iw - 3))}..."; [ ${#line2} -gt $iw ] && line2="${line2:0:$((iw - 3))}..."
    _ui_rep "$S_DH" $((UI_W - 2)); printf '%s%s%s%s%s\n' "$UC_HDR" "$S_DTL" "$UI_R" "$S_DTR" "$UC_RST"
    for l in "$line1" "$line2"; do
      _ui_rep ' ' $((iw - ${#l})); printf '%s%s %s%s %s%s\n' "$UC_HDR" "$S_DV" "$l" "$UI_R" "$S_DV" "$UC_RST"
    done
    _ui_rep "$S_DH" $((UI_W - 2)); printf '%s%s%s%s%s\n' "$UC_HDR" "$S_DBL" "$UI_R" "$S_DBR" "$UC_RST"
  else
    printf '\n== %s ==\n%s\n' "$line1" "$line2"
  fi
}
ui_hint() {   # a calm grey hint line (how to go back, what Enter does)
  _ui_ensure
  if [ "$UI_MODE" = gui ]; then return 0; fi
  _ui_wrap "$UI_IW" "$1"
  local l; for l in "${UI_LINES[@]}"; do printf '%s%s%s\n' "$UC_DIM" "$l" "$UC_RST"; done
}
ui_blank() { _ui_ensure; [ "$UI_MODE" = gui ] && { _ui_g_add ""; return 0; }; printf '\n'; }
ui_hr() { _ui_ensure; [ "$UI_MODE" = rich ] || return 0; _ui_rep "$S_H" "$UI_W"; printf '%s%s%s\n' "$UC_DIM" "$UI_R" "$UC_RST"; }

# one row inside a card. RAW may contain colour codes; LEN is its visible length.
_ui_rowr() {
  local len=$1 raw=$2
  if [ "$UI_MODE" = rich ]; then
    _ui_rep ' ' $((UI_W - 4 - len))
    printf '%s%s%s %s%s %s%s%s\n' "$UC_EDGE" "$S_V" "$UC_RST" "$raw" "$UI_R" "$UC_EDGE" "$S_V" "$UC_RST"
  else printf '%s\n' "$raw"; fi
}
_ui_text_rows() {   # _ui_text_rows TEXT [INDENT] [COLOUR]
  local text=$1 ind=${2:-0} col=${3:-} l pad="" i
  for ((i = 0; i < ind; i++)); do pad+=" "; done
  _ui_wrap $((UI_IW - ind)) "$text"
  for l in "${UI_LINES[@]}"; do _ui_rowr $((ind + ${#l})) "$pad$col$l${col:+$UC_RST}"; done
}
_ui_top() {   # _ui_top SEV TITLE
  local sev=$1 title=${2:-} vis
  _ui_sevc "$sev"; UC_EDGE=$UI_SC; _ui_sym "$sev"
  if [ "$UI_MODE" = rich ]; then
    local sym="" symc=""
    case $sev in ok|warn|fail|info) sym=$UI_SY ;; esac
    [ ${#title} -gt $((UI_W - 10)) ] && title="${title:0:$((UI_W - 13))}..."
    if [ -n "$title" ] || [ -n "$sym" ]; then
      vis=$((${#title} + (${#sym} > 0 ? UI_SYMW + 1 : 0)))
      _ui_rep "$S_H" $((UI_W - 5 - vis))
      printf '%s%s%s %s%s%s%s%s %s%s%s\n' "$UC_EDGE" "$S_TL" "$S_H" "$UC_BOLD" "${sym:+$sym }" "$title" "$UC_RST" "$UC_EDGE" "$UI_R" "$S_TR" "$UC_RST"
    else _ui_rep "$S_H" $((UI_W - 2)); printf '%s%s%s%s%s\n' "$UC_EDGE" "$S_TL" "$UI_R" "$S_TR" "$UC_RST"; fi
  else
    _ui_word "$sev"; printf '\n== %s%s ==\n' "$title" "$( [ "$sev" = info ] || [ "$sev" = skip ] || echo " ($UI_WD)")"
  fi
}
_ui_bottom() {
  if [ "$UI_MODE" = rich ]; then _ui_rep "$S_H" $((UI_W - 2)); printf '%s%s%s%s%s\n' "$UC_EDGE" "$S_BL" "$UI_R" "$S_BR" "$UC_RST"; else printf '\n'; fi
}

ui_banner() {   # ui_banner SEV "Big headline" ["smaller line"]
  _ui_ensure
  local sev=$1 head=$2 sub=${3:-}
  if [ "$UI_MODE" = gui ]; then _ui_sym "$sev"; _ui_g_add "$UI_SY  $head"; [ -n "$sub" ] && _ui_g_add "$sub"; _ui_g_add ""; return 0; fi
  _ui_sevc "$sev"; _ui_sym "$sev"; _ui_word "$sev"
  if [ "$UI_MODE" = rich ]; then
    UC_EDGE=$UI_SC; local sc=$UI_SC sy=$UI_SY
    _ui_top none ""
    _ui_rowr $((UI_SYMW + 2 + ${#head})) "$sc$sy  $head$UC_RST"
    [ -n "$sub" ] && _ui_text_rows "$sub" $((UI_SYMW + 2)) "$UC_DIM"
    _ui_bottom
  else
    printf '\n%s: %s\n' "$UI_WD" "$head"; [ -n "$sub" ] && { _ui_wrap "$UI_IW" "$sub"; local l; for l in "${UI_LINES[@]}"; do printf '%s\n' "$l"; done; }
  fi
}
ui_card() {   # ui_card SEV "Title" ["Label" "text"]...
  _ui_ensure
  local sev=$1 title=$2 label text first=1; shift 2
  if [ "$UI_MODE" = gui ]; then
    _ui_sym "$sev"; _ui_g_add "$UI_SY  $title"
    while [ $# -ge 2 ]; do [ -n "$2" ] && { _ui_g_add ""; _ui_g_add "$1"; _ui_g_add "$2"; }; shift 2; done
    _ui_g_add ""; return 0
  fi
  _ui_top "$sev" "$title"
  while [ $# -ge 2 ]; do
    label=$1; text=$2; shift 2
    [ -n "$text" ] || continue
    [ $first = 0 ] && [ "$UI_ROOMY" = 1 ] && _ui_rowr 0 ""
    if [ -n "$label" ]; then _ui_rowr ${#label} "$UC_BOLD$label$UC_RST"; _ui_text_rows "$text" 2; else _ui_text_rows "$text" 0; fi
    first=0
  done
  _ui_bottom
}
ui_say() {   # a paragraph (word-wrapped)
  _ui_ensure
  if [ "$UI_MODE" = gui ]; then _ui_g_add "$1"; _ui_g_add ""; return 0; fi
  local l; _ui_wrap $((UI_IW - 2)) "$1"
  for l in "${UI_LINES[@]}"; do printf '  %s\n' "$l"; done
}
ui_h2() {
  _ui_ensure
  if [ "$UI_MODE" = gui ]; then _ui_g_add "$1"; return 0; fi
  printf '\n%s%s%s%s\n' "$UC_BLUE" "$UC_BOLD" "$1" "$UC_RST"
}
ui_list() {   # bullets
  _ui_ensure
  local it l first
  for it in "$@"; do
    if [ "$UI_MODE" = gui ]; then _ui_g_add "  - $it"; continue; fi
    _ui_wrap $((UI_IW - 4)) "$it"; first=1
    for l in "${UI_LINES[@]}"; do
      if [ $first = 1 ]; then printf '  %s%s%s %s\n' "$UC_BLUE" "$S_BUL" "$UC_RST" "$l"; first=0; else printf '    %s\n' "$l"; fi
    done
  done
}
ui_traffic() {   # ui_traffic SEV "Label" ["detail"]   one status row
  _ui_ensure
  local sev=$1 label=$2 detail=${3:-} wd line
  _ui_sym "$sev"; _ui_word "$sev"; _ui_sevc "$sev"; wd=$UI_WD
  if [ "$UI_MODE" = gui ]; then _ui_g_add "$UI_SY  $wd:  $label${detail:+  -  $detail}"; return 0; fi
  if [ "$UI_MODE" = rich ]; then
    printf '  %s%s  %-10s%s %s%s%s\n' "$UI_SC" "$UI_SY" "$wd" "$UC_RST" "$UC_BOLD" "$label" "$UC_RST"
    if [ -n "$detail" ]; then _ui_wrap $((UI_IW - 4 - UI_SYMW - 12 + 2)) "$detail"; local l pad; _ui_rep ' ' $((UI_SYMW + 14)); pad=$UI_R
      for l in "${UI_LINES[@]}"; do printf '%s%s%s%s\n' "$pad" "$UC_DIM" "$l" "$UC_RST"; done; fi
  else
    line="$wd: $label"; [ -n "$detail" ] && line="$line - $detail"
    _ui_wrap "$UI_IW" "$line"; local l; for l in "${UI_LINES[@]}"; do printf '%s\n' "$l"; done
  fi
}
ui_table() {   # ui_table "Head A|Head B" "a1|b1" "a2|b2" ...   aligned; long cells wrap
  _ui_ensure
  local -a W=() R=(); local nc=0 r c cell row n l maxl avail total i
  local -a cells
  if [ "$UI_MODE" = gui ]; then for r in "$@"; do _ui_g_add "  ${r//|/   |   }"; done; _ui_g_add ""; return 0; fi
  for r in "$@"; do
    IFS='|' read -ra cells <<< "$r"; n=${#cells[@]}; [ "$n" -gt "$nc" ] && nc=$n
    for ((c = 0; c < n; c++)); do [ ${#cells[c]} -gt "${W[c]:-0}" ] && W[c]=${#cells[c]}; done
  done
  [ "$nc" -gt 0 ] || return 0
  avail=$((UI_IW - 2 - 2 * (nc - 1)))
  while :; do
    total=0; for ((c = 0; c < nc; c++)); do total=$((total + ${W[c]:-0})); done
    [ "$total" -le "$avail" ] && break
    maxl=0; l=0; for ((c = 0; c < nc; c++)); do [ "${W[c]:-0}" -gt "$maxl" ] && { maxl=${W[c]}; l=$c; }; done
    [ "$maxl" -le 8 ] && break
    W[l]=$((W[l] - 1))
  done
  local head=1 nlines line out cellw
  for r in "$@"; do
    IFS='|' read -ra cells <<< "$r"
    local -a CL=(); nlines=1
    for ((c = 0; c < nc; c++)); do
      _ui_wrap "${W[c]:-8}" "${cells[c]:-}"; CL[c]=$(printf '%s\n' "${UI_LINES[@]}")
      n=${#UI_LINES[@]}; [ "$n" -gt "$nlines" ] && nlines=$n
    done
    for ((i = 1; i <= nlines; i++)); do
      out="  "
      for ((c = 0; c < nc; c++)); do
        cell=$(printf '%s\n' "${CL[c]}" | sed -n "${i}p"); cellw=${W[c]:-8}
        if [ $head = 1 ]; then out+="$UC_BOLD"; fi
        printf -v line '%-*s' "$cellw" "$cell"; out+="$line"; [ $head = 1 ] && out+="$UC_RST"
        [ "$c" -lt $((nc - 1)) ] && out+="  "
      done
      printf '%s\n' "${out%"${out##*[![:space:]]}"}"
    done
    if [ $head = 1 ]; then head=0; _ui_rep "$S_H" $((UI_IW - 2)); printf '  %s%s%s\n' "$UC_DIM" "$UI_R" "$UC_RST"; fi
  done
}
ui_steps() {   # ui_steps "state|text" ...  state = done|doing|todo|fail|warn|skip
  _ui_ensure
  local e st tx sev
  for e in "$@"; do
    st=${e%%|*}; tx=${e#*|}
    case $st in done) sev=ok ;; fail) sev=fail ;; warn) sev=warn ;; skip) sev=skip ;; doing) sev=doing ;; *) sev=todo ;; esac
    _ui_sym "$sev"; _ui_sevc "$sev"; [ "$sev" = todo ] || [ "$sev" = skip ] && UI_SC=$UC_DIM; [ "$sev" = doing ] && UI_SC=$UC_BLUE
    if [ "$UI_MODE" = gui ]; then _ui_g_add "$UI_SY  $tx"; continue; fi
    if [ "$UI_MODE" = rich ]; then printf '  %s%s%s %s\n' "$UI_SC" "$UI_SY" "$UC_RST" "$tx"; else printf '  %s %s\n' "$UI_SY" "$tx"; fi
  done
}

# ---------------------------------------------------------------- reading answers
_ui_read() {   # _ui_read VAR "prompt"  -> rc 1 at end of input
  local __v
  [ "$UI_MODE" = rich ] && printf '%s' "$UC_BOLD"
  printf '%s' "$2"
  [ "$UI_MODE" = rich ] && printf '%s' "$UC_RST"
  if ! IFS= read -r __v; then printf '\n'; printf -v "$1" '%s' ""; return 1; fi
  [ -t 0 ] || printf '\n'    # a piped answer is not echoed by a terminal: end the line ourselves
  __v=${__v%$'\r'}; printf -v "$1" '%s' "$__v"
}
_ui_lc() { UI_LCV=${1,,}; UI_LCV=${UI_LCV#"${UI_LCV%%[![:space:]]*}"}; UI_LCV=${UI_LCV%"${UI_LCV##*[![:space:]]}"}; }

ui_wait() {   # ui_wait ["message"]
  _ui_ensure
  local m=${1:-"Press Enter to continue."}
  if [ "$UI_MODE" = gui ]; then _ui_g_take; [ -n "$UI_GBODY" ] && _ui_g_msg info "$UI_GBODY"; return 0; fi
  printf '\n'; local x; _ui_read x "$m "; return 0
}
ui_info() {   # ui_info "text" ["Title"]
  _ui_ensure
  local text=$1 title=${2:-}
  if [ "$UI_MODE" = gui ]; then _ui_g_add "$text"; _ui_g_take; _ui_g_msg info "$UI_GBODY"; return 0; fi
  ui_card info "${title:-Good to know}" "" "$text"
  ui_wait "Press Enter to carry on."
}
ui_yesno() {   # ui_yesno "Question" [default y|n] [yes label] [no label] -> rc 0 yes, 1 no or back
  _ui_ensure; _ui_q ui_yesno
  local q=$1 def=${2:-n} yes=${3:-Yes} no=${4:-No} a hint
  if [ "$UI_MODE" = gui ]; then _ui_g_add "$q"; _ui_g_take; _ui_g_ask "$UI_GBODY" "$yes" "$no"; return $?; fi
  ui_say "$q"
  hint="Type y for \"$yes\" or n for \"$no\", then press Enter.  q = go back (same as no)."
  printf '\n'; ui_hint "$hint"
  while :; do
    _ui_read a "Your answer [$def]: " || return 1
    _ui_lc "$a"; a=$UI_LCV; [ -z "$a" ] && a=$def
    case $a in y|yes|yeah|ok) UI_REPLY=yes; return 0 ;; n|no|nope|q|quit|back|b|0) UI_REPLY=no; return 1 ;; esac
    ui_say "Please type y for yes or n for no."
  done
}
ui_input() {   # ui_input "Question" [default] -> UI_REPLY
  _ui_ensure; _ui_q ui_input
  local q=$1 def=${2:-} a
  UI_REPLY=""
  if [ "$UI_MODE" = gui ]; then
    _ui_g_add "$q"; _ui_g_take
    case "$UI_GUI" in kdialog) a=$(kdialog --title "$UI_APP" --inputbox "$UI_GBODY" "$def") || return 1 ;; *) a=$(zenity --entry --title="$UI_APP" --width=560 --text="$UI_GBODY" --entry-text="$def") || return 1 ;; esac
    UI_REPLY=$a; return 0
  fi
  ui_say "$q"
  if [ -n "$def" ]; then ui_hint "Press Enter to accept \"$def\", or type something else."; else ui_hint "Type your answer and press Enter. Leave it empty to go back."; fi
  _ui_read a "> " || return 1
  [ -z "$a" ] && a=$def
  UI_REPLY=$a; [ -n "$a" ]
}
ui_secret() {   # ui_secret "Question" -> UI_REPLY (nothing is shown while typing)
  _ui_ensure; _ui_q ui_secret
  local q=$1 a
  UI_REPLY=""
  if [ "$UI_MODE" = gui ]; then
    _ui_g_add "$q"; _ui_g_take
    case "$UI_GUI" in kdialog) a=$(kdialog --title "$UI_APP" --password "$UI_GBODY") || return 1 ;; *) a=$(zenity --entry --hide-text --title="$UI_APP" --width=560 --text="$UI_GBODY") || return 1 ;; esac
    UI_REPLY=$a; return 0
  fi
  ui_say "$q"; ui_hint "Nothing shows while you type. That is normal. Press Enter when done."
  printf '> '
  if ! IFS= read -rs a; then printf '\n'; return 1; fi
  printf '\n'; UI_REPLY=${a%$'\r'}; return 0
}
ui_typed() {   # ui_typed "WORD" "why" -> rc 0 only when WORD is typed exactly. Anything else cancels.
  _ui_ensure; _ui_q ui_typed
  local word=$1 why=$2 a
  if [ "$UI_MODE" = gui ]; then
    _ui_g_add "$why"; _ui_g_add ""; _ui_g_add "To go ahead, type:  $word"; _ui_g_take
    case "$UI_GUI" in kdialog) a=$(kdialog --title "$UI_APP" --inputbox "$UI_GBODY") || return 1 ;; *) a=$(zenity --entry --title="$UI_APP" --width=560 --text="$UI_GBODY") || return 1 ;; esac
    [ "$a" = "$word" ]; return $?
  fi
  ui_card warn "Please read this first" "Why we are asking you to type" "$why"
  ui_hint "Type the words exactly as shown. Press Enter on its own to cancel."
  _ui_read a "Type  $word  to go ahead: " || return 1
  [ "$a" = "$word" ]
}
ui_menu() {   # ui_menu "Title" "key|Label|help" ...   -> UI_REPLY = key ; rc 1 = back. Max 7 lines on screen.
  _ui_ensure; _ui_q ui_menu
  local title=$1; shift
  local -a K=() L=() H=(); local e n=0 i
  for e in "$@"; do K[n]=${e%%|*}; e=${e#*|}; L[n]=${e%%|*}; if [[ $e == *"|"* ]]; then H[n]=${e#*|}; else H[n]=""; fi; n=$((n + 1)); done
  UI_REPLY=""
  [ "$n" -gt 0 ] || return 1
  if [ "$UI_MODE" = gui ]; then _ui_menu_gui "$title"; return $?; fi
  local per=7 page=0 pages=1 start end shown lw maxl line a idx pad back=${UI_MENU_BACK:-"Go back"} bad=0
  [ "$n" -gt 7 ] && { per=6; pages=$(((n + per - 1) / per)); }
  while :; do
    start=$((page * per)); end=$((start + per)); [ "$end" -gt "$n" ] && end=$n
    printf '\n'
    [ "$UI_MODE" = rich ] && printf '%s%s%s\n' "$UC_BOLD" "$title" "$UC_RST" || printf '%s\n' "$title"
    maxl=0; for ((i = start; i < end; i++)); do [ ${#L[i]} -gt "$maxl" ] && maxl=${#L[i]}; done
    [ "$maxl" -gt 30 ] && maxl=30
    shown=0
    for ((i = start; i < end; i++)); do
      shown=$((shown + 1))
      _ui_menu_item "$shown" "${L[i]}" "${H[i]}" "$maxl"
    done
    if [ "$pages" -gt 1 ]; then shown=$((shown + 1)); _ui_menu_item 7 "More choices (page $((page + 1)) of $pages)" "See the next ones" "$maxl"; fi
    if [ "$UI_MODE" = rich ]; then printf '  %sq%s)  %s%s%s\n' "$UC_BLUE" "$UC_RST" "$UC_DIM" "$back" "$UC_RST"; else printf '  q. %s\n' "$back"; fi
    printf '\n'
    ui_hint "Type a number, then press Enter.  q = $(printf '%s' "${back,,}").  Ctrl+C stops."
    local dflt=""; [ "$UI_MENU_DEFAULT" = 1 ] && dflt=1
    _ui_read a "Your choice${dflt:+ [$dflt]}: " || { UI_REPLY=""; return 1; }
    _ui_lc "$a"; a=$UI_LCV; [ -z "$a" ] && a=$dflt
    case $a in q|quit|back|0|exit) UI_REPLY=""; return 1 ;; esac
    if [[ $a =~ ^[0-9]+$ ]]; then
      if [ "$pages" -gt 1 ] && [ "$a" -eq 7 ]; then page=$(((page + 1) % pages)); continue; fi
      idx=$((start + a - 1))
      if [ "$a" -ge 1 ] && [ "$idx" -lt "$end" ]; then UI_REPLY=${K[idx]}; return 0; fi
    else
      for ((i = 0; i < n; i++)); do [ "${K[i]}" = "$a" ] && { UI_REPLY=${K[i]}; return 0; }; done
    fi
    ui_say "That is not one of the choices. Please type a number from the list, or q to go back."
  done
}
_ui_menu_item() {   # _ui_menu_item NUMBER LABEL HELP LABELWIDTH
  local num=$1 label=$2 help=$3 lw=$4 line
  if [ "$UI_MODE" = rich ]; then
    if [ "$UI_ROOMY" = 1 ]; then
      printf '\n  %s%s%s)  %s%s%s\n' "$UC_BLUE" "$num" "$UC_RST" "$UC_BOLD" "$label" "$UC_RST"
      [ -n "$help" ] && printf '      %s%s%s\n' "$UC_DIM" "$help" "$UC_RST"
    elif [ $((6 + lw + 2 + ${#help})) -le "$UI_W" ] && [ ${#label} -le 30 ]; then
      printf -v line '%-*s' "$lw" "$label"
      printf '  %s%s%s)  %s%s%s  %s%s%s\n' "$UC_BLUE" "$num" "$UC_RST" "$UC_BOLD" "$line" "$UC_RST" "$UC_DIM" "$help" "$UC_RST"
    else
      printf '  %s%s%s)  %s%s%s\n' "$UC_BLUE" "$num" "$UC_RST" "$UC_BOLD" "$label" "$UC_RST"
      if [ -n "$help" ]; then _ui_wrap $((UI_W - 6)) "$help"; local l; for l in "${UI_LINES[@]}"; do printf '      %s%s%s\n' "$UC_DIM" "$l" "$UC_RST"; done; fi
    fi
  else
    line="$num. $label"; [ -n "$help" ] && line="$line - $help"
    _ui_wrap "$UI_IW" "$line"; local l; for l in "${UI_LINES[@]}"; do printf '%s\n' "$l"; done
  fi
}
_ui_menu_gui() {   # uses K L H n from ui_menu
  local title=$1 i out
  _ui_g_add "$title"; _ui_g_take
  case "$UI_GUI" in
    kdialog)
      local -a args=()
      for ((i = 0; i < n; i++)); do args+=("${K[i]}" "${L[i]}${H[i]:+  -  ${H[i]}}"); done
      out=$(kdialog --title "$UI_APP" --menu "$UI_GBODY" "${args[@]}") || return 1 ;;
    *)
      local -a args=()
      for ((i = 0; i < n; i++)); do args+=("${K[i]}" "${L[i]}" "${H[i]}"); done
      out=$(zenity --list --title="$UI_APP" --width=760 --height=560 --text="<span size='large'>$(_ui_gesc "$UI_GBODY")</span>" \
            --column=Key --column="What would you like to do?" --column="About it" --hide-column=1 --print-column=1 \
            --ok-label="Choose" --cancel-label="${UI_MENU_BACK:-Go back}" "${args[@]}") || return 1 ;;
  esac
  out=${out%%|*}; [ -n "$out" ] || return 1
  UI_REPLY=$out; return 0
}
ui_choice() {   # ui_choice "Question" "Label 1" "Label 2" ... -> UI_REPLY = number (1-based)
  local q=$1 i=0 a; shift
  local -a items=()
  for a in "$@"; do i=$((i + 1)); items+=("$i|$a"); done
  ui_menu "$q" "${items[@]}"
}

# ---------------------------------------------------------------- progress, steps, tasks
UI_PB=""; UI_PB_LAST=-1
ui_progress_begin() {   # ui_progress_begin "Title"
  _ui_ensure
  UI_PB_LAST=-1; UI_PB=""
  case "$UI_MODE" in
    gui)
      if [ "$UI_GUI" = kdialog ]; then
        UI_QDBUS=""; local q; for q in qdbus6 qdbus-qt6 qdbus; do _ui_have "$q" && { UI_QDBUS=$q; break; }; done
        UI_PB=$(kdialog --title "$UI_APP" --progressbar "$1" 100 2>/dev/null)
      else
        UI_PBFIFO=$(mktemp -u "${TMPDIR:-/tmp}/slui-pb.XXXXXX"); mkfifo "$UI_PBFIFO" 2>/dev/null
        zenity --progress --title="$UI_APP" --width=560 --text="$1" --percentage=0 --auto-close --no-cancel < "$UI_PBFIFO" 2>/dev/null &
        UI_PBPID=$!; exec 8> "$UI_PBFIFO"; UI_PB=zenity
      fi ;;
    *) ui_hint "Please wait. This is safe to stop with Ctrl+C: nothing is left half-done."; [ "$UI_MODE" = rich ] && [ "$UI_TTY" = 1 ] && printf '\033[?25l' ;;
  esac
}
_ui_bar() {   # _ui_bar PERCENT WIDTH -> UI_BAR
  local p=$1 w=$2 f; [ "$p" -gt 100 ] && p=100; [ "$p" -lt 0 ] && p=0
  f=$((p * w / 100)); _ui_rep "$S_FULL" "$f"; local a=$UI_R; _ui_rep "$S_EMP" $((w - f)); UI_BAR="$a$UI_R"
}
ui_progress() {   # ui_progress PERCENT "what is happening"
  _ui_ensure
  local p=${1:-0} txt=${2:-} bw
  p=${p%%.*}; case $p in ''|*[!0-9]*) p=0 ;; esac
  case "$UI_MODE" in
    gui)
      if [ "$UI_GUI" = kdialog ] && [ -n "$UI_PB" ] && [ -n "${UI_QDBUS:-}" ]; then
        "$UI_QDBUS" $UI_PB Set "" value "$p" >/dev/null 2>&1; "$UI_QDBUS" $UI_PB setLabelText "$txt" >/dev/null 2>&1
      elif [ -n "$UI_PB" ]; then printf '%s\n# %s\n' "$p" "$txt" >&8 2>/dev/null; fi ;;
    rich)
      bw=$((UI_W - 12)); [ "$bw" -gt 50 ] && bw=50; _ui_bar "$p" "$bw"
      if [ "$UI_TTY" = 1 ] && [ -t 1 ]; then
        printf '\r\033[K  %s%s%s %3d%%  %s' "$UC_BLUE" "$UI_BAR" "$UC_RST" "$p" "${txt:0:$((UI_W - bw - 12))}"
      elif [ "$p" != "$UI_PB_LAST" ]; then printf '  %s%s%s %3d%%  %s\n' "$UC_BLUE" "$UI_BAR" "$UC_RST" "$p" "$txt"; fi ;;
    *) [ "$p" != "$UI_PB_LAST" ] && printf 'Progress: %s percent. %s\n' "$p" "$txt" ;;
  esac
  UI_PB_LAST=$p
}
ui_progress_end() {
  case "$UI_MODE" in
    gui) if [ "$UI_GUI" = kdialog ]; then [ -n "$UI_PB" ] && [ -n "${UI_QDBUS:-}" ] && "$UI_QDBUS" $UI_PB close >/dev/null 2>&1
         elif [ -n "$UI_PB" ]; then printf '100\n' >&8 2>/dev/null; exec 8>&-; wait "${UI_PBPID:-0}" 2>/dev/null; rm -f "${UI_PBFIFO:-}"; fi ;;
    rich) if [ "$UI_TTY" = 1 ] && [ -t 1 ]; then printf '\n\033[?25h'; fi ;;
  esac
  UI_PB=""
}
ui_cleanup() { [ -t 1 ] && printf '\033[?25h'; return 0; }
UI_TASK_RC=0; UI_TASK_LOG=""
ui_task() {   # ui_task "Label" cmd args... : runs it with a spinner, hides its noise (kept in $UI_TASK_LOG), prints a tick or a cross
  _ui_ensure
  local label=$1 rc spid="" i=0 sev; shift
  UI_TASK_LOG=$(mktemp "${TMPDIR:-/tmp}/slui-task.XXXXXX" 2>/dev/null || echo /dev/null)
  if [ "$UI_MODE" = rich ] && [ "$UI_TTY" = 1 ] && [ -t 1 ] && [ -z "${SL_UI_NOSPIN:-}" ]; then
    printf '\033[?25l'
    ( while :; do printf '\r  %s%s%s %s' "$UC_BLUE" "${UI_SPIN[i % ${#UI_SPIN[@]}]}" "$UC_RST" "$label"; i=$((i + 1)); sleep 0.12; done ) &
    spid=$!
  elif [ "$UI_MODE" = gui ] && [ "$UI_GUI" = zenity ]; then
    ( zenity --progress --pulsate --no-cancel --auto-close --title="$UI_APP" --width=560 --text="$label" < <(sleep 3600) >/dev/null 2>&1 ) &
    spid=$!
  elif [ "$UI_MODE" != gui ]; then printf '  %s %s ...\n' "$( [ "$UI_MODE" = rich ] && echo "$S_DOING" || echo "Working on:")" "$label"; fi
  "$@" > "$UI_TASK_LOG" 2>&1 < /dev/null; rc=$?
  if [ -n "$spid" ]; then kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null; pkill -P "$spid" 2>/dev/null; fi
  UI_TASK_RC=$rc
  sev=ok; [ "$rc" -ne 0 ] && sev=fail
  if [ "$UI_MODE" = rich ]; then
    [ "$UI_TTY" = 1 ] && [ -t 1 ] && printf '\r\033[K\033[?25h'
    _ui_sym "$sev"; _ui_sevc "$sev"; printf '  %s%s%s %s\n' "$UI_SC" "$UI_SY" "$UC_RST" "$label"
  elif [ "$UI_MODE" = plain ]; then
    if [ "$rc" -eq 0 ]; then printf '  Done: %s\n' "$label"; else printf '  Did not finish: %s\n' "$label"; fi
  fi
  return "$rc"
}
ui_step_begin() {   # ui_step_begin "text"  /  ui_step_end ok|warn|fail|skip ["note"]
  _ui_ensure; UI_STEP_NOW=$1
  [ "$UI_MODE" = gui ] && return 0
  if [ "$UI_MODE" = rich ]; then _ui_sym doing; printf '  %s%s%s %s ...' "$UC_BLUE" "$UI_SY" "$UC_RST" "$1"; [ "$UI_TTY" = 1 ] && [ -t 1 ] || printf '\n'
  else printf '  Working on: %s ...\n' "$1"; fi
}
ui_step_end() {
  local sev=${1:-ok} note=${2:-}
  _ui_ensure
  if [ "$UI_MODE" = gui ]; then _ui_sym "$sev"; _ui_g_add "$UI_SY  $UI_STEP_NOW${note:+ - $note}"; return 0; fi
  _ui_sym "$sev"; _ui_word "$sev"; _ui_sevc "$sev"
  if [ "$UI_MODE" = rich ]; then
    [ "$UI_TTY" = 1 ] && [ -t 1 ] && printf '\r\033[K'
    printf '  %s%s%s %s%s\n' "$UI_SC" "$UI_SY" "$UC_RST" "$UI_STEP_NOW" "${note:+  ($note)}"
  else printf '  %s: %s%s\n' "$UI_WD" "$UI_STEP_NOW" "${note:+ ($note)}"; fi
}

# ---------------------------------------------------------------- errors, files
ui_error() {   # ui_error "What happened" "What to do next" ["technical detail for a helper"]
  _ui_ensure
  local what=$1 next=$2 tech=${3:-}
  if [ "$UI_MODE" = gui ]; then
    _ui_g_add "Something did not work. Your files are safe."; _ui_g_add ""; _ui_g_add "$what"; _ui_g_add ""; _ui_g_add "What to do next:"; _ui_g_add "$next"
    [ -n "$tech" ] && { _ui_g_add ""; _ui_g_add "For a helper: $tech"; }
    _ui_g_take; _ui_g_msg fail "$UI_GBODY"; return 0
  fi
  ui_card fail "That did not work, and nothing was harmed" "What happened" "$what" "What to do next" "$next" "For a helper (you can ignore this)" "$tech"
  ui_wait
}
ui_text_file() {   # ui_text_file "Title" FILE : a scrollable view of a text file
  _ui_ensure
  local title=$1 f=$2
  [ -r "$f" ] || { ui_say "(Nothing to show: $f is missing.)"; return 1; }
  case "$UI_MODE" in
    gui) case "$UI_GUI" in kdialog) kdialog --title "$title" --textbox "$f" 760 560 ;; *) zenity --text-info --title="$title" --width=760 --height=560 --filename="$f" ;; esac ;;
    *)   if [ "$UI_MODE" = rich ] && [ "$UI_TTY" = 1 ] && [ -t 1 ] && _ui_have less; then less -R -- "$f"
         else ui_h2 "$title"; cat "$f"; fi
         ui_hint "That is the end. Press Enter to go back."; local x; _ui_read x "" ;;
  esac
}
