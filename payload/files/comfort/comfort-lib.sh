# shellcheck shell=bash
# Shared helpers for the "comfort" area: steps 45/75, helpers secure-linux-migrate/-emergency-kit/-tips/
# -explain/-family and the wizard.d pages. Source AFTER lib/common.sh. Owned by: comfort.
#
# Test hooks (tests/comfort/run.sh only, never set on a real machine):
#   SL_TEST_SYSROOT   prefix for every absolute system path we write (/etc, /usr, /var)
#   CF_TEST_NOW       fixed "today" (YYYY-MM-DD) for the tips and care calendar
[ -n "${SL_CF_LOADED:-}" ] && return 0
SL_CF_LOADED=1

CF_R=${SL_TEST_SYSROOT:-}
if [ -n "$CF_R" ]; then
  SL_ETC=$CF_R/etc/secure-linux; SL_STATE=$CF_R/var/lib/secure-linux
  SL_LOGDIR=$CF_R/var/log/secure-linux; SL_FAILS=$SL_LOGDIR/failures.log
fi
CF_FILES=$SL_ROOT/files/comfort
CF_GUIDE=$CF_R/usr/share/secure-linux/START-HERE.html
CF_USTATE=${HOME:-/root}/.local/state/secure-linux
CF_IMMICH_DEFAULT=http://10.0.30.42:8080

# Choice keys the comfort area owns, and the values allowed for each (checked before saving as root).
# A value may be a comma list for the "list" keys.
cf_key_allowed() {   # cf_key_allowed KEY VALUE
  local k=$1 v=$2 item
  case $k in
    office)          [[ $v =~ ^(libreoffice|onlyoffice)$ ]] ;;
    notes_app)       [[ $v =~ ^(joplin|obsidian|both)$ ]] ;;
    matlab)          [[ $v =~ ^(none|octave|official|both)$ ]] ;;
    email_client)    [[ $v =~ ^(thunderbird|betterbird|none)$ ]] ;;
    backup_gui)      [[ $v =~ ^(deja-dup|none)$ ]] ;;
    disk_usage)      [[ $v =~ ^(baobab|none)$ ]] ;;
    disk_utility)    [[ $v =~ ^(gnome-disks|none)$ ]] ;;
    keepassxc)       [[ $v =~ ^(yes|no)$ ]] ;;
    conda|android_dev|game_saves|extras_tools|extras_apps|family_mode|guest_account|tips|drm)
                     [[ $v =~ ^(yes|no)$ ]] ;;
    fleet|fleet_screen)
                     [[ $v =~ ^(yes|no)$ ]] ;;                    # home fleet enrolment (wizard page 85)
    fleet_method)    [[ $v =~ ^(network|usb)$ ]] ;;
    meetings)        for item in ${v//,/ }; do [[ $item =~ ^(vesktop|teams|zoom|none)$ ]] || return 1; done ;;
    accessibility)   for item in ${v//,/ }; do [[ $item =~ ^(orca|dyslexia|captions|none)$ ]] || return 1; done ;;
    display_scale)   [[ $v =~ ^(100|125|150|175|200)$ ]] ;;
    hibernate)       [[ $v =~ ^(no|on-lid|sleep-then-hibernate)$ ]] ;;   # system owns it; fallback only
    *) return 1 ;;
  esac
}

cf_have() { command -v "$1" >/dev/null 2>&1; }
cf_today() { if [ -n "${CF_TEST_NOW:-}" ]; then echo "$CF_TEST_NOW"; else date +%F; fi; }

cf_desktop() {   # kde | xfce | other
  case "${XDG_CURRENT_DESKTOP:-}${DESKTOP_SESSION:-}" in
    *KDE*|*plasma*) echo kde ;; *XFCE*|*xfce*) echo xfce ;;
    *) if cf_have plasmashell; then echo kde; elif cf_have xfce4-session; then echo xfce; else echo other; fi ;;
  esac
}

cf_notify() {    # cf_notify "Title" "Message" [icon]
  if [ -n "${CF_TEST_LOG:-}" ]; then echo "NOTIFY: $1 | $2" >> "$CF_TEST_LOG"; return 0; fi
  cf_have notify-send && notify-send -a "Secure Linux" -i "${3:-dialog-information}" "$1" "$2" 2>/dev/null
  return 0
}

cf_open() {      # cf_open URL_or_file   (the wizard's wz_open when it exists)
  if declare -F wz_open >/dev/null; then wz_open "$1"; return; fi
  cf_have xdg-open && xdg-open "$1" >/dev/null 2>&1 &
  return 0
}

cf_terminal() {  # cf_terminal CMD...   run where the user can watch it, keep the window open at the end
  if [ -n "${CF_NO_TERMINAL:-}" ]; then "$@"; return; fi
  if cf_have secure-linux-terminal; then secure-linux-terminal --hold "$@"
  elif cf_have konsole; then konsole --hold -e "$@"
  elif cf_have xfce4-terminal; then xfce4-terminal --hold -x "$@"
  else "$@"; fi
}

# Save a system choice. Uses the experience helper when it exists; otherwise our own (same file, same rules).
cf_save_choice() {   # cf_save_choice KEY VALUE
  local sc=$SL_ROOT/bin/secure-linux-choice
  if [ -x "$sc" ]; then
    if declare -F wz_root >/dev/null; then wz_root "$sc" set "$1" "$2"; else pkexec "$sc" set "$1" "$2"; fi
  else
    if declare -F wz_root >/dev/null; then wz_root "$SL_ROOT/bin/secure-linux-migrate" choice "$1" "$2"
    else "$SL_ROOT/bin/secure-linux-migrate" choice "$1" "$2"; fi
  fi
}

# Where is the Windows backup? Prints the folder (the one that holds MANIFEST.txt), or nothing.
cf_find_backup() {
  local d u=${USER:-$(id -un)}
  for d in "$CF_USTATE/windows-backup" ; do
    [ -f "$d" ] && { d=$(cat "$d"); [ -d "$d" ] && { echo "$d"; return 0; }; }
  done
  for d in "$CF_R/run/media/$u"/*/ZenbookBackup* "$CF_R/run/media/$u"/*/*/ZenbookBackup* "$CF_R/media/$u"/*/ZenbookBackup* \
           "$HOME"/ZenbookBackup* "$HOME/Windows-Backup"; do
    [ -d "$d" ] && { echo "$d"; return 0; }
  done
  return 1
}
cf_remember_backup() { mkdir -p "$CF_USTATE"; printf '%s\n' "$1" > "$CF_USTATE/windows-backup"; }

# Wait for a new file matching a glob to appear in a folder. Prints its path.
#   cf_wait_for_file DIR 'GLOB' TIMEOUT_SECONDS [SINCE_FILE]
# Only files newer than SINCE_FILE count (default: from now). Uses inotifywait when present, else polling.
cf_wait_for_file() {
  local dir=$1 glob=$2 timeout=${3:-900} since=${4:-} own="" start f newest s1 s2
  if [ -z "$since" ]; then since=$(mktemp); own=1; touch -d '-5 seconds' "$since" 2>/dev/null || touch "$since"; fi
  start=$(date +%s)
  while :; do
    newest=""
    for f in "$dir"/$glob; do
      [ -f "$f" ] || continue
      case $f in *.part|*.crdownload) continue ;; esac
      [ "$f" -nt "$since" ] || continue
      [ -n "$newest" ] && [ ! "$f" -nt "$newest" ] && continue
      newest=$f
    done
    if [ -n "$newest" ]; then
      # wait until the browser has finished writing it (same size twice in a row)
      s1=$(stat -c %s "$newest" 2>/dev/null); sleep "${CF_POLL:-2}"; s2=$(stat -c %s "$newest" 2>/dev/null)
      if [ -n "$s1" ] && [ "$s1" = "$s2" ] && [ ! -e "$newest.part" ]; then
        [ -n "$own" ] && rm -f "$since"; echo "$newest"; return 0
      fi
    fi
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then [ -n "$own" ] && rm -f "$since"; return 1; fi
    if cf_have inotifywait && [ -z "${CF_POLL:-}" ]; then
      inotifywait -q -t 10 -e close_write -e moved_to "$dir" >/dev/null 2>&1
    else
      sleep "${CF_POLL:-3}"
    fi
  done
}

# Securely remove a file. On an SSD shred can't promise the old blocks are gone; the encrypted disk is
# the real protection. Prints nothing; returns shred's status.
cf_shred() {
  [ -f "$1" ] || return 0
  if cf_have shred; then shred -u -z -n 1 "$1"; else rm -f "$1"; fi
}

# The Immich address: the user's choice immich_url, else build.conf IMMICH_URL, else the owner's server
cf_immich_url() {
  local u; u=$(sl_choice_get immich_url)
  [ -n "$u" ] || u=$(sl_build_get IMMICH_URL)
  printf '%s' "${u:-$CF_IMMICH_DEFAULT}"
}

# The internal laptop panel's width in pixels (from the kernel; works before and during a session)
cf_panel_width() {
  local f m sys=${SL_TEST_SYSFS:-/sys}
  for f in "$sys"/class/drm/card*-eDP-*/modes "$sys"/class/drm/card*-LVDS-*/modes "$sys"/class/drm/card*-DSI-*/modes; do
    [ -s "$f" ] || continue
    m=$(head -1 "$f"); echo "${m%%x*}"; return 0
  done
  return 1
}

# Write one KDE config value (kwriteconfig6, or kwriteconfig5 on older Plasma). Groups may be nested:
#   cf_kconf FILE "Group1/Group2" KEY VALUE [type]
cf_kconf() {
  local file=$1 key=$3 val=$4 type=${5:-} tool args=() g parts=()
  tool=$(command -v kwriteconfig6 || command -v kwriteconfig5) || return 1
  IFS=/ read -ra parts <<< "$2"; for g in "${parts[@]}"; do args+=(--group "$g"); done
  [ -n "$type" ] && args+=(--type "$type")
  "$tool" --file "$file" "${args[@]}" --key "$key" "$val"
}
cf_kread() {   # cf_kread FILE "Group1/Group2" KEY
  local tool args=() g parts=()
  tool=$(command -v kreadconfig6 || command -v kreadconfig5) || return 1
  IFS=/ read -ra parts <<< "$2"; for g in "${parts[@]}"; do args+=(--group "$g"); done
  "$tool" --file "$1" "${args[@]}" --key "$3"
}
# Tell running KDE apps that mouse/touchpad (3,0) or other settings changed
cf_kde_notify() {
  cf_have dbus-send || return 0
  dbus-send --session --type=signal /KGlobalSettings org.kde.KGlobalSettings.notifyChange "int32:${1:-3}" "int32:${2:-0}" 2>/dev/null
  return 0
}
cf_kwin_reconfigure() {
  cf_have dbus-send || return 0
  dbus-send --session --type=method_call --dest=org.kde.KWin /KWin org.kde.KWin.reconfigure 2>/dev/null
  return 0
}

# Ask a three-way question with the wizard helpers: prints yes | later | never
#   cf_ask3 "Question" "Yes label"
cf_ask3() {
  local a yes=${2:-"Yes, let us do it"}
  a=$(wz_choice "$1" "$yes" "Not now (ask me next time)" "No thanks")
  case $a in
    "$yes") echo yes ;;
    "No thanks") echo never ;;
    *) echo later ;;
  esac
}

# ---------------------------------------------------------------- web apps (Teams, Zoom, Microsoft 365, Discord on lite)
# A "web app" is a menu entry that opens a website in its own window with no browser bars. We use a
# Chromium-based browser in app mode when one is there (Ungoogled Chromium is installed on the full
# profile); otherwise a new LibreWolf window. The menu entry runs `secure-linux-migrate webapp-open URL`,
# so it keeps working if the browser installed changes later.
cf_webapp_open() {   # cf_webapp_open URL
  local b url=$1
  case $url in https://*) ;; *) echo "Only https:// addresses can be opened as web apps." >&2; return 2 ;; esac
  if cf_have flatpak && flatpak info io.github.ungoogled_software.ungoogled_chromium >/dev/null 2>&1; then
    exec flatpak run io.github.ungoogled_software.ungoogled_chromium --app="$url"
  fi
  for b in chromium chromium-browser; do
    cf_have "$b" && exec "$b" --app="$url"
  done
  if cf_have flatpak && flatpak info io.gitlab.librewolf-community >/dev/null 2>&1; then
    exec flatpak run io.gitlab.librewolf-community --new-window "$url"
  fi
  exec xdg-open "$url"
}
cf_webapp_entry() {  # cf_webapp_entry "Name" "Comment" URL icon "Category;" "keywords;"   prints a .desktop file
  printf '[Desktop Entry]
Type=Application
Name=%s
Comment=%s
Exec=%s webapp-open %s
Icon=%s
Categories=%s
Keywords=%s
StartupWMClass=%s
'     "$1" "$2" "$SL_ROOT/bin/secure-linux-migrate" "$3" "$4" "$5" "${6:-}" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '-')"
}
cf_webapp_system() {   # cf_webapp_system SLUG "Name" "Comment" URL icon "Category;" "keywords;"   (root; step use)
  cf_webapp_entry "$2" "$3" "$4" "$5" "$6" "${7:-}" | sl_write_file "$CF_R/usr/share/applications/secure-linux-web-$1.desktop"
}
