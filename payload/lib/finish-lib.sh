# shellcheck shell=bash
# secure-linux-finish library. Source after lib/common.sh and files/comfort/comfort-lib.sh.
# All questions default to no. No passwords are read, stored, logged or passed on a command line.
# Test-only hooks: SL_FINISH_MIGRATE, SL_FINISH_STATUS, SL_FINISH_OPEN_LOG, SL_FINISH_MEDIA_ROOT,
# SL_FINISH_STATE_DIR and SL_FINISH_FULL_NAME. They redirect commands or state; they never bypass validation.

FINISH_STATE_DIR=${SL_FINISH_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/secure-linux/finish}
FINISH_MIGRATE=${SL_FINISH_MIGRATE:-$SL_ROOT/bin/secure-linux-migrate}
FINISH_STATUS=${SL_FINISH_STATUS:-$SL_ROOT/bin/secure-linux-status}
FINISH_FULL_NAME=${SL_FINISH_FULL_NAME:-}
FINISH_EMAIL=""
FINISH_CSV_PATH=""
FINISH_DONE=()
FINISH_LEFT=()
FINISH_SKIPPED=()

# Optional native-dialog frontend. The established functions still produce their
# normal instructions and validation messages; in GUI mode those messages are
# carried into the next dialog instead of a hidden terminal. No prompt is bypassed.
FINISH_GUI=0
FINISH_GUI_TOOL=""
FINISH_GUI_LOG=""
FINISH_GUI_TEXT=""

finish_gui_init() {
  [ "${SL_FINISH_UI:-}" = gui ] || return 0
  if [ -n "${UI_TOOL:-}" ]; then FINISH_GUI_TOOL=$UI_TOOL
  elif command -v zenity >/dev/null 2>&1; then FINISH_GUI_TOOL=zenity
  elif command -v kdialog >/dev/null 2>&1; then FINISH_GUI_TOOL=kdialog
  else echo "The graphical finishing tool needs zenity or kdialog. Nothing was changed." >&2; return 1
  fi
  FINISH_GUI_LOG=$(mktemp "${TMPDIR:-/tmp}/secure-linux-finish.XXXXXX") || return 1
  exec 3>&1 4>&2
  exec >"$FINISH_GUI_LOG" 2>&1
  FINISH_GUI=1
  trap finish_gui_cleanup EXIT
}

finish_gui_cleanup() {
  local rc=$?
  trap - EXIT
  [ "$FINISH_GUI" = 1 ] && exec 1>&3 2>&4
  [ -n "$FINISH_GUI_LOG" ] && rm -f "$FINISH_GUI_LOG"
  return "$rc"
}

finish_gui_take() {
  FINISH_GUI_TEXT=""
  [ "$FINISH_GUI" = 1 ] && [ -f "$FINISH_GUI_LOG" ] || return 0
  FINISH_GUI_TEXT=$(cat "$FINISH_GUI_LOG")
  : > "$FINISH_GUI_LOG"
}

finish_gui_question() {   # finish_gui_question yesno|input|menu QUESTION [DEFAULT] [OPTION...]
  local kind=$1 q=$2 def=${3:-} text a
  shift 3 2>/dev/null || shift $#
  finish_gui_take
  text=${FINISH_GUI_TEXT:+$FINISH_GUI_TEXT

}$q
  FINISH_REPLY=""
  case "$kind:$FINISH_GUI_TOOL" in
    yesno:kdialog)
      kdialog --title "Finish setting up your computer" --yes-label "Yes" --no-label "No" --yesno "$text"
      return $? ;;
    yesno:zenity)
      zenity --question --no-markup --title="Finish setting up your computer" --width=680 \
        --ok-label="Yes" --cancel-label="No" --text="$text"
      return $? ;;
    input:kdialog)
      a=$(kdialog --title "Finish setting up your computer" --inputbox "$text" "$def") || return 1
      FINISH_REPLY=${a:-$def} ;;
    input:zenity)
      a=$(zenity --entry --title="Finish setting up your computer" --width=620 --text="$text" --entry-text="$def") || return 1
      FINISH_REPLY=${a:-$def} ;;
    menu:kdialog)
      local i=0 option args=()
      for option in "$@"; do i=$((i + 1)); args+=("$i" "$option"); done
      a=$(kdialog --title "Finish setting up your computer" --menu "$text" "${args[@]}") || return 1
      case $a in *[!0-9]*|'') return 1 ;; esac
      [ "$a" -ge 1 ] && [ "$a" -le "$#" ] || return 1
      eval "FINISH_REPLY=\${$a}" ;;
    menu:zenity)
      local i=0 option args=()
      for option in "$@"; do i=$((i + 1)); args+=("$i) $option"); done
      a=$(zenity --list --no-markup --title="Finish setting up your computer" --width=820 --height=520 \
        --text="$text" --column="What would you like to do?" --ok-label="Choose" --cancel-label="Cancel / skip" \
        "${args[@]}") || return 1
      a=${a%%)*}
      case $a in *[!0-9]*|'') return 1 ;; esac
      [ "$a" -ge 1 ] && [ "$a" -le "$#" ] || return 1
      eval "FINISH_REPLY=\${$a}" ;;
  esac
  return 0
}

finish_gui_show_file() {
  local file=$1 display
  finish_gui_take
  display=$(mktemp "${TMPDIR:-/tmp}/secure-linux-finish-summary.XXXXXX") || return 1
  [ -z "$FINISH_GUI_TEXT" ] || printf '%s\n\n' "$FINISH_GUI_TEXT" > "$display"
  cat "$file" >> "$display"
  if [ "$FINISH_GUI_TOOL" = kdialog ]; then
    kdialog --title "Your finishing summary" --textbox "$display" 820 580
  else
    zenity --text-info --title="Your finishing summary" --width=820 --height=580 --filename="$display"
  fi
  rm -f "$display"
}

finish_init() {
  mkdir -p "$FINISH_STATE_DIR"
  touch "$FINISH_STATE_DIR/state"
}

finish_record() {   # finish_record done|left|skipped TEXT (one copy of each line)
  local kind=$1 text=$2 item
  case $kind in
    done)
      for item in "${FINISH_DONE[@]:-}"; do [ "$item" = "$text" ] && return 0; done
      FINISH_DONE+=("$text") ;;
    left)
      for item in "${FINISH_LEFT[@]:-}"; do [ "$item" = "$text" ] && return 0; done
      FINISH_LEFT+=("$text") ;;
    skipped)
      for item in "${FINISH_SKIPPED[@]:-}"; do [ "$item" = "$text" ] && return 0; done
      FINISH_SKIPPED+=("$text") ;;
  esac
}

finish_note_state() {   # a record for our own use; never used to hide a needed manual step
  local key=$1 value=$2
  case $key in *[!A-Za-z0-9_.-]*|'') return 1 ;; esac
  sed -i "/^$key=/d" "$FINISH_STATE_DIR/state" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$value" >> "$FINISH_STATE_DIR/state"
}

finish_summary() {
  local item
  {
    printf '\n============================================================\n'
    printf 'Your finishing summary\n'
    printf '============================================================\n'
    printf '\nSet up or started for you:\n'
    if [ ${#FINISH_DONE[@]} -eq 0 ]; then printf '  - Nothing yet.\n'; else
      for item in "${FINISH_DONE[@]}"; do printf '  - %s\n' "$item"; done
    fi
    printf '\nStill needs you (one short job at a time):\n'
    if [ ${#FINISH_LEFT[@]} -eq 0 ]; then printf '  - Nothing. You are all caught up.\n'; else
      for item in "${FINISH_LEFT[@]}"; do printf '  - %s\n' "$item"; done
    fi
    if [ ${#FINISH_SKIPPED[@]} -gt 0 ]; then
      printf '\nSkipped (run secure-linux-finish again any time):\n'
      for item in "${FINISH_SKIPPED[@]}"; do printf '  - %s\n' "$item"; done
    fi
    printf '\nNothing signs in, pairs, deletes or replaces files without your say-so.\n'
  } > "$FINISH_STATE_DIR/last-summary.txt"
  if [ "$FINISH_GUI" = 1 ]; then finish_gui_show_file "$FINISH_STATE_DIR/last-summary.txt"
  else cat "$FINISH_STATE_DIR/last-summary.txt"
  fi
}

finish_input() {   # finish_input QUESTION [DEFAULT] -> FINISH_REPLY
  local q=$1 def=${2:-}
  if [ "$FINISH_GUI" = 1 ]; then finish_gui_question input "$q" "$def"; return $?; fi
  printf '\n%s' "$q"
  [ -n "$def" ] && printf ' [%s]' "$def"
  printf ': '
  FINISH_REPLY=""
  read -r FINISH_REPLY || FINISH_REPLY=""
  [ -n "$FINISH_REPLY" ] || FINISH_REPLY=$def
}

finish_yesno() {   # deliberately no affirmative default
  local q=$1 a
  if [ "$FINISH_GUI" = 1 ]; then finish_gui_question yesno "$q" ""; return $?; fi
  printf '\n%s [y/N] ' "$q"
  read -r a || a=""
  case $a in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

finish_menu() {   # finish_menu QUESTION OPTION... -> FINISH_REPLY; empty means cancel
  local q=$1 n=0 i a
  shift
  if [ "$FINISH_GUI" = 1 ]; then finish_gui_question menu "$q" "" "$@"; return 0; fi
  # Prompts belong on stderr: callers may safely capture a helper's single return value.
  printf '\n%s\n' "$q" >&2
  for i in "$@"; do n=$((n + 1)); printf '  %d) %s\n' "$n" "$i" >&2; done
  printf '  q) Cancel / skip\nChoose: ' >&2
  read -r a || a=""
  case $a in
    ''|q|Q) FINISH_REPLY="" ;;
    *[!0-9]*) FINISH_REPLY="" ;;
    *) if [ "$a" -ge 1 ] && [ "$a" -le "$n" ]; then eval "FINISH_REPLY=\${$a}"; else FINISH_REPLY=""; fi ;;
  esac
}

finish_have() { command -v "$1" >/dev/null 2>&1; }

finish_spawn() {   # launch a visible app; never wait for its sign-in or window
  if [ -n "${SL_FINISH_OPEN_LOG:-}" ]; then
    {
      printf '%s' "$1"
      shift
      printf ' %q' "$@"
      printf '\n'
    } >> "$SL_FINISH_OPEN_LOG"
    return 0
  fi
  "$@" </dev/null >/dev/null 2>&1 &
  return 0
}

finish_open() {
  if [ -n "${SL_FINISH_OPEN_LOG:-}" ]; then printf 'xdg-open %q\n' "$1" >> "$SL_FINISH_OPEN_LOG"; return 0; fi
  finish_have xdg-open || { printf 'Open this address yourself: %s\n' "$1"; return 1; }
  xdg-open "$1" </dev/null >/dev/null 2>&1 &
  return 0
}

finish_flatpak_has() { flatpak info --system "$1" >/dev/null 2>&1 || flatpak info "$1" >/dev/null 2>&1; }

finish_launch() {   # finish_launch FLATPAK_ID NATIVE_COMMAND [APP ARGUMENTS...]
  local id=$1 native=$2
  shift 2
  if finish_have flatpak && finish_flatpak_has "$id"; then finish_spawn flatpak run "$id" "$@"
  elif finish_have "$native"; then finish_spawn "$native" "$@"
  elif finish_have gtk-launch; then finish_spawn gtk-launch "$id"
  else return 1
  fi
}

finish_user_dir() {   # finish_user_dir XDG_NAME FALLBACK -> an absolute, usable folder name
  local d=""
  finish_have xdg-user-dir && d=$(xdg-user-dir "$1" 2>/dev/null)
  [ -n "$d" ] && [ "$d" != "$HOME" ] || d=$HOME/$2
  case $d in /*) ;; *) return 1 ;; esac
  [ "$d" != / ] || return 1
  printf '%s' "$d"
}

finish_is_backup() { [ -d "$1" ] && [ -f "$1/MANIFEST.txt" ] && [ -f "$1/BACKUP-INDEX.tsv" ]; }

finish_find_backup() {
  local d u=${USER:-$(id -un)} roots=()
  [ -n "${SL_FINISH_MEDIA_ROOT:-}" ] && roots+=("$SL_FINISH_MEDIA_ROOT")
  roots+=("/run/media/$u" "/media/$u" "$HOME")
  if [ -f "$HOME/.local/state/secure-linux/windows-backup" ]; then
    d=$(cat "$HOME/.local/state/secure-linux/windows-backup")
    finish_is_backup "$d" && { printf '%s\n' "$d"; return 0; }
  fi
  local root
  for root in "${roots[@]}"; do
    for d in "$root"/ZenbookBackup* "$root"/*/ZenbookBackup* "$root"/*/*/ZenbookBackup*; do
      finish_is_backup "$d" && { printf '%s\n' "$d"; return 0; }
    done
  done
  return 1
}

finish_conflict_count() {   # count files or links already present, including broken links
  local src=$1 dest=$2 f rel n=0
  [ -d "$src" ] && [ -d "$dest" ] || { echo 0; return; }
  while IFS= read -r -d '' f; do
    rel=${f#"$src"/}
    { [ -e "$dest/$rel" ] || [ -L "$dest/$rel" ]; } && n=$((n + 1))
  done < <(find "$src" \( -type f -o -type l \) -print0 2>/dev/null)
  echo "$n"
}

finish_conflict_policy() {   # -> keep|replace|skip; never replaces by default
  finish_menu "Some names are already in your home folder. What should I do when a file already exists?" \
    "Keep my existing files (recommended; add only missing files)" \
    "Replace the existing files with the backup copies" \
    "Skip this copy"
  case $FINISH_REPLY in
    Keep*) printf 'keep' ;;
    Replace*) printf 'replace' ;;
    *) printf 'skip' ;;
  esac
}

finish_copy_tree() {   # finish_copy_tree SOURCE DEST keep|replace; source links stay links
  local src=$1 dest=$2 policy=$3
  [ -d "$src" ] || return 1
  [ ! -L "$dest" ] || { printf 'Refusing to copy into a linked folder: %s\n' "$dest" >&2; return 1; }
  mkdir -p "$dest" || return 1
  case $policy in
    keep) cp -a --no-clobber "$src"/. "$dest"/ 2>/dev/null || cp -an "$src"/. "$dest"/ ;;
    replace) cp -a "$src"/. "$dest"/ ;;
    *) return 2 ;;
  esac
}

finish_restore_backup() {
  local backup=${1:-}
  [ -n "$backup" ] || backup=$(finish_find_backup)
  if ! finish_is_backup "$backup"; then
    printf 'That is not a Secure Linux backup: MANIFEST.txt and BACKUP-INDEX.tsv must both be there.\n' >&2
    finish_record left "Restore files: plug in the backup drive, then run 'secure-linux-finish restore'."
    return 1
  fi
  cf_remember_backup "$backup"
  local keys=(Documents Desktop Pictures Downloads Videos Music Code Games)
  local srcs=() dests=() found=() conflicts=() k s d xdg n i total=0 policy=keep rc=0
  for k in "${keys[@]}"; do
    s=$backup/$k
    [ -d "$s" ] || continue
    case $k in
      Documents|Desktop|Pictures|Downloads|Videos|Music) d=$(finish_user_dir "${k^^}" "$k") || continue ;;
      *) d=$HOME/$k ;;
    esac
    srcs+=("$s"); dests+=("$d"); found+=("$k")
    n=$(finish_conflict_count "$s" "$d"); conflicts+=("$n"); total=$((total + n))
  done
  [ ${#found[@]} -gt 0 ] || { finish_record left "Restore files: no standard personal folders were found in $backup."; return 1; }
  printf '\nI found this backup: %s\n\nThese folders will be copied home:\n' "$backup"
  for i in "${!found[@]}"; do
    printf '  %-10s -> %s' "${found[$i]}" "${dests[$i]}"
    [ "${conflicts[$i]}" -gt 0 ] && printf '  (%s existing name(s) kept unless you choose otherwise)' "${conflicts[$i]}"
    printf '\n'
  done
  printf '\nBrowser settings, Wi-Fi files and private keys are not part of this general copy.\n'
  if ! finish_yesno "Copy these folders now?"; then
    finish_record skipped "Restore personal folders from the backup."
    return 0
  fi
  if [ "$total" -gt 0 ]; then
    policy=$(finish_conflict_policy)
    if [ "$policy" = skip ]; then finish_record skipped "Restore personal folders (existing files were left alone)."; return 0; fi
  fi
  for i in "${!found[@]}"; do
    k=${found[$i]}
    if finish_copy_tree "${srcs[$i]}" "${dests[$i]}" "$policy"; then
      printf 'Copied %s (%s).\n' "$k" "$([ "$policy" = keep ] && echo 'existing files kept' || echo 'backup copies approved')"
      finish_record done "$k restored to ${dests[$i]} ($([ "$policy" = keep ] && echo 'existing files kept' || echo 'backup copies approved'))."
      finish_note_state "restored.$k" done
    else
      printf 'Could not finish copying %s. Nothing on the backup drive was changed.\n' "$k" >&2
      finish_record left "$k: run 'secure-linux-finish restore $backup' again; check the error above."
      rc=1
    fi
  done
  return "$rc"
}

finish_pick_dir() {   # numbered folder picker, plus a typed path; FINISH_REPLY is a directory or empty
  local q=$1 root d n=0 a text
  shift
  FINISH_REPLY=""
  if [ "$FINISH_GUI" = 1 ]; then
    finish_gui_take
    if [ -n "$FINISH_GUI_TEXT" ]; then
      if [ "$FINISH_GUI_TOOL" = kdialog ]; then
        kdialog --title "Finish setting up your computer" --msgbox "$FINISH_GUI_TEXT"
      else
        zenity --info --no-markup --title="Finish setting up your computer" --width=620 --text="$FINISH_GUI_TEXT"
      fi
    fi
    if [ "$FINISH_GUI_TOOL" = kdialog ]; then
      a=$(kdialog --title "$q" --getexistingdirectory "$HOME") || return 1
    else
      a=$(zenity --file-selection --directory --title="$q" --filename="$HOME/") || return 1
    fi
    [ -d "$a" ] || return 1
    FINISH_REPLY=$a
    return 0
  fi
  local dirs=()
  for root in "$@"; do
    [ -d "$root" ] || continue
    for d in "$root"/*; do [ -d "$d" ] && dirs+=("$d"); done
  done
  printf '\n%s\n' "$q"
  for d in "${dirs[@]}"; do n=$((n + 1)); printf '  %d) %s\n' "$n" "$d"; done
  printf '  p) Type a folder path\n  q) Cancel / skip\nChoose: '
  read -r a || a=""
  FINISH_REPLY=""
  case $a in
    q|Q|'') return 1 ;;
    p|P)
      finish_input "Type the folder path (in Files, Ctrl+L shows it)" ""
      [ -d "$FINISH_REPLY" ] || { printf 'No such folder: %s\n' "$FINISH_REPLY"; FINISH_REPLY=""; return 1; }
      ;;
    *[!0-9]*) return 1 ;;
    *) [ "$a" -ge 1 ] && [ "$a" -le "$n" ] || return 1; FINISH_REPLY=${dirs[$((a - 1))]} ;;
  esac
  return 0
}

finish_copy_extra() {
  local src=${1:-} base dest policy=keep n
  if [ -z "$src" ]; then
    finish_pick_dir "Pick a folder to copy into Home > Transferred. Nothing is moved or deleted." \
      "${SL_FINISH_MEDIA_ROOT:-/run/media/${USER:-$(id -un)}}" "/media/${USER:-$(id -un)}" "$HOME" || {
      finish_record skipped "Copy an extra folder."
      return 0
    }
    src=$FINISH_REPLY
  fi
  [ -d "$src" ] || { printf 'No such folder: %s\n' "$src" >&2; return 1; }
  case ${src%/} in /|"$HOME"|"$HOME/Transferred") printf 'Choose one ordinary folder, not your whole home or transfer folder.\n' >&2; return 1 ;; esac
  base=$(basename "$src")
  case $base in ''|.|..) return 1 ;; esac
  dest=$HOME/Transferred/$base
  n=$(finish_conflict_count "$src" "$dest")
  printf '\n%s\n  -> %s\nExisting files are kept unless you explicitly choose replacement.\n' "$src" "$dest"
  finish_yesno "Copy this folder?" || { finish_record skipped "Copy the extra folder $base."; return 0; }
  if [ "$n" -gt 0 ]; then policy=$(finish_conflict_policy); [ "$policy" = skip ] && return 0; fi
  if finish_copy_tree "$src" "$dest" "$policy"; then
    finish_record done "Extra folder copied to $dest (existing files $([ "$policy" = keep ] && echo kept || echo replaced))."
  else
    finish_record left "Extra folder $base: the copy did not finish; try it again."
    return 1
  fi
}

finish_browser_bookmarks() {
  local backup=${1:-} out
  [ -n "$backup" ] || backup=$(finish_find_backup)
  if [ -n "$backup" ]; then
    out=$("$FINISH_MIGRATE" bookmarks "$backup" 2>/dev/null | tail -1)
  fi
  [ -n "${out:-}" ] && [ -f "$out" ] || out=$(finish_user_dir DOCUMENTS Documents)/"Bookmarks from Windows.html"
  if [ ! -f "$out" ]; then
    finish_record left "Bookmarks: export an HTML file from your old browser, then choose Import Bookmarks from HTML in LibreWolf."
  else
    printf '\nYour bookmark file is: %s\n' "$out"
  fi
  finish_launch io.gitlab.librewolf-community librewolf about:library || {
    finish_record left "Bookmarks: open LibreWolf, press Ctrl+Shift+O, then Import and Backup > Import Bookmarks from HTML."
    return 1
  }
  printf '\nIn LibreWolf: click Import and Backup, then Import Bookmarks from HTML. Pick the file above.\n'
  finish_record left "Bookmarks: in LibreWolf's Library, click Import and Backup > Import Bookmarks from HTML${out:+; choose $out}."
}

finish_pick_csv() {   # graphical, cancellable file choice; FINISH_REPLY is an existing file or empty
  local q=$1 def=$2 a text
  FINISH_REPLY=""
  finish_gui_take
  text=${FINISH_GUI_TEXT:+$FINISH_GUI_TEXT

}$q
  if [ "$FINISH_GUI_TOOL" = kdialog ]; then
    [ -z "$text" ] || kdialog --title "Finish setting up your computer" --msgbox "$text"
    a=$(kdialog --title "$q" --getopenfilename "${def%/*}" '*.csv') || return 1
  else
    [ -z "$text" ] || zenity --info --no-markup --title="Finish setting up your computer" --width=620 --text="$text"
    a=$(zenity --file-selection --title="$q" --filename="$def" --file-filter='Password CSV files | *.csv' --file-filter='All files | *') || return 1
  fi
  [ -f "$a" ] || return 1
  FINISH_REPLY=$a
}

finish_passwords() {
  local marker csv manager dl
  dl=$(finish_user_dir DOWNLOAD Downloads)
  printf '\nThe password CSV contains every exported password in plain text. Do not email it or copy it to a stick.\n'
  printf 'Google Password Manager opens at its settings. Sign in yourself, click Export passwords, then Export.\n'
  finish_open "https://passwords.google.com/options"
  if [ "$FINISH_GUI" = 1 ]; then
    if ! finish_pick_csv "Choose the exported password CSV" "$dl/Google Passwords.csv"; then
      finish_record skipped "Passwords: choose the exported CSV when it is ready."
      return 0
    fi
    csv=$FINISH_REPLY
  else
    marker=$(mktemp)
    if ! finish_input "Press Enter after the CSV has downloaded" ""; then
      rm -f "$marker"
      finish_record skipped "Passwords: wait for the exported CSV."
      return 0
    fi
    csv=$("$FINISH_MIGRATE" wait-csv 900 "$marker")
    rm -f "$marker"
  fi
  if [ -z "$csv" ] || [ ! -f "$csv" ]; then
    finish_record left "Passwords: put the exported CSV in $dl, then run 'secure-linux-finish stuff' again."
    return 1
  fi
  FINISH_CSV_PATH=$csv
  printf '\nFound the exported file: %s\n' "$csv"
  finish_menu "Which password manager are you using?" "Bitwarden" "KeePassXC (no cloud)" "Skip for now"
  manager=$FINISH_REPLY
  case $manager in
    Bitwarden)
      finish_launch com.bitwarden.desktop bitwarden
      printf 'In Bitwarden: File > Import data > Chrome (csv), then pick the file above and Import data.\n' ;;
    KeePassXC*)
      finish_launch org.keepassxc.KeePassXC keepassxc
      printf 'In KeePassXC: create or open your database, then Database > Import > Chrome (csv), and pick the file above.\n' ;;
    *) finish_record skipped "Import the password CSV (the file has NOT been deleted)."; return 0 ;;
  esac
  if finish_yesno "Can you see your passwords in the password manager now? Only say yes after checking."; then
    if "$FINISH_MIGRATE" shred "$csv"; then
      FINISH_CSV_PATH=""
      finish_record done "Passwords imported by you; the plain-text CSV was securely removed."
      printf 'The CSV was removed. SSDs can retain unreachable old blocks; your encrypted disk protects those leftovers.\n'
    else
      finish_record left "Password CSV: import finished, but removal failed. Run: secure-linux-migrate shred '$csv'"
      return 1
    fi
  else
    finish_record left "Passwords: finish the import, then rerun this flow. The CSV is still at $csv."
    printf 'The CSV has NOT been deleted. Keep it private and do not leave it there longer than needed.\n'
  fi
}

finish_stuff() {
  local backup
  backup=$(finish_find_backup)
  if [ -n "$backup" ]; then
    printf '\nA Secure Linux backup is plugged in: %s\n' "$backup"
    finish_yesno "Bring your Documents, Pictures and other personal folders across now?" && finish_restore_backup "$backup"
    finish_yesno "Prepare your old browser bookmarks for LibreWolf?" && finish_browser_bookmarks "$backup"
  else
    finish_record left "Backup restore: plug in the drive containing MANIFEST.txt and BACKUP-INDEX.tsv, then choose this flow again."
  fi
  finish_yesno "Move an exported browser-password CSV into your password manager?" && finish_passwords
  finish_yesno "Copy another folder into Home > Transferred?" && finish_copy_extra
  finish_summary
}

# ---------------------------------------------------------------- choice export / import
# Export filter (deliberately defence in depth):
#   1. the key AND its complete value must pass comfort-lib's cf_key_allowed allow-list;
#   2. credential-like names are denied before that allow-list is consulted;
#   3. the JSON importer repeats both checks for every entry before any install command runs.
# Consequently Wi-Fi profiles/passwords, password hashes, private keys, API/session tokens and unknown
# choices never leave the machine. This is not a general /etc/secure-linux/choices backup.
finish_secret_key() {
  local k=${1,,}
  case $k in
    *password*|*passwd*|*passphrase*|*secret*|*token*|*credential*|*private*key*|*apikey*|*api_key*|\
    *hash*|*salt*|*wifi*|*ssid*|*ssh*|*cookie*|*session*|*auth*|*certificate*|*cert_key*) return 0 ;;
  esac
  return 1
}

finish_choices_export() {
  local folder=${1:-} out tmp k v rest n=0 denied=0 rejected=0
  [ -n "$folder" ] || folder=$(finish_user_dir DOCUMENTS Documents)
  [ -d "$folder" ] || { printf 'Choose an existing folder for the choices file.\n' >&2; return 1; }
  [ -w "$folder" ] || { printf 'That folder is not writable: %s\n' "$folder" >&2; return 1; }
  out=$folder/secure-linux-choices.json
  tmp=$(mktemp "$folder/.secure-linux-choices.XXXXXX") || return 1
  declare -A safe=()
  if [ -f "$SL_ETC/choices" ]; then
    while IFS='=' read -r k v rest; do
      [ -n "$k" ] || continue
      case $k in *[!A-Za-z0-9_]*|'#'*) rejected=$((rejected + 1)); continue ;; esac
      [ -z "${rest:-}" ] || { rejected=$((rejected + 1)); continue; }
      if finish_secret_key "$k"; then denied=$((denied + 1)); continue; fi
      if cf_key_allowed "$k" "$v"; then safe[$k]=$v; else rejected=$((rejected + 1)); fi
    done < "$SL_ETC/choices"
  fi
  for k in "${!safe[@]}"; do printf '%s\t%s\n' "$k" "${safe[$k]}"; done | sort > "$FINISH_STATE_DIR/export-safe.tsv"
  python3 - "$FINISH_STATE_DIR/export-safe.tsv" "$tmp" <<'PY'
import json, sys
choices = {}
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        key, value = line.rstrip("\n").split("\t", 1)
        choices[key] = value
with open(sys.argv[2], "w", encoding="utf-8", newline="\n") as fh:
    json.dump({"format": "secure-linux-choices", "version": 1, "choices": choices}, fh,
              sort_keys=True, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
  chmod 600 "$tmp" 2>/dev/null || true
  n=${#safe[@]}
  if [ "$n" -eq 0 ]; then rm -f "$tmp"; printf 'No safe app or comfort choices were found to export.\n'; return 1; fi
  if [ -f "$out" ] && cmp -s "$tmp" "$out"; then
    rm -f "$tmp"; finish_record done "Choices already exported to $out ($n safe choices; no secrets)."; printf '%s\n' "$out"; return 0
  fi
  if [ -e "$out" ]; then
    finish_yesno "Replace the older choices file at $out?" || { rm -f "$tmp"; finish_record skipped "Replace the older choices export."; return 0; }
  fi
  if ! mv -f "$tmp" "$out"; then rm -f "$tmp"; return 1; fi
  printf 'Exported %s safe choice(s) to %s\n' "$n" "$out"
  printf 'Excluded %s secret-looking and %s unknown or unsafe entr(ies). No credentials were exported.\n' "$denied" "$rejected"
  finish_record done "Choices exported to $out ($n safe choices; no secrets)."
  printf '%s\n' "$out"
}

finish_choices_import() {
  local file=${1:-} rows k v rest kv
  [ -f "$file" ] || { printf 'No such choices file: %s\n' "$file" >&2; return 1; }
  [ "$(stat -c %s "$file" 2>/dev/null || echo 9999999)" -le 1048576 ] || { printf 'That choices file is too large.\n' >&2; return 1; }
  rows=$(mktemp "$FINISH_STATE_DIR/import.XXXXXX") || return 1
  if ! python3 - "$file" "$rows" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
if not isinstance(data, dict) or data.get("format") != "secure-linux-choices" or data.get("version") != 1:
    raise SystemExit("Not a Secure Linux choices file (format/version mismatch).")
choices = data.get("choices")
if not isinstance(choices, dict):
    raise SystemExit("The choices member must be an object.")
with open(sys.argv[2], "w", encoding="utf-8", newline="\n") as out:
    for key, value in choices.items():
        if not isinstance(key, str) or not isinstance(value, str) or "\n" in key + value or "\t" in key + value:
            raise SystemExit("Every choice must be a simple key and string value.")
        out.write(key + "\t" + value + "\n")
PY
  then rm -f "$rows"; printf 'That choices file is damaged or has the wrong format. Nothing was changed.\n' >&2; return 1; fi
  local args=() count=0 bad=0
  while IFS=$'\t' read -r k v rest; do
    [ -n "$k" ] || continue
    [ -z "${rest:-}" ] || { printf 'Refusing malformed entry for %s.\n' "$k" >&2; bad=1; continue; }
    if finish_secret_key "$k"; then printf 'Refusing secret-looking choice key: %s\n' "$k" >&2; bad=1; continue; fi
    if ! cf_key_allowed "$k" "$v"; then printf 'Refusing unknown or unsafe choice: %s\n' "$k" >&2; bad=1; continue; fi
    args+=("$k=$v"); count=$((count + 1))
  done < "$rows"
  rm -f "$rows"
  if [ "$bad" -ne 0 ]; then printf 'Import stopped before anything changed. Fix or remove every refused entry.\n' >&2; return 2; fi
  [ "$count" -gt 0 ] || { printf 'There are no choices to import.\n'; return 1; }
  printf "\nThese validated choices will be applied through the kit's normal installer:\n"
  for kv in "${args[@]}"; do printf '  %s\n' "$kv"; done
  finish_yesno "Apply these $count choices now?" || { finish_record skipped "Import choices from $file."; return 0; }
  if "$FINISH_MIGRATE" install "${args[@]}"; then
    finish_record done "Imported $count choices through secure-linux-migrate; requested apps and settings were applied."
    finish_note_state choices-imported "$count"
  else
    finish_record left "Choices import: the normal installer could not finish. Run 'secure-linux-finish import $file' again."
    return 1
  fi
}

# ---------------------------------------------------------------- app finishing
finish_identity() {   # finish_identity yes|no (ask for an email too); never asks for a password
  local gecos=""
  if [ -z "$FINISH_FULL_NAME" ]; then
    gecos=$(getent passwd "${USER:-$(id -un)}" 2>/dev/null | cut -d: -f5 | cut -d, -f1)
    finish_input "Your name as it should appear in email and documents" "$gecos"
    FINISH_FULL_NAME=$FINISH_REPLY
  fi
  [ -n "$FINISH_FULL_NAME" ] || FINISH_FULL_NAME=${USER:-User}
  if [ "$1" = yes ] && [ -z "$FINISH_EMAIL" ]; then
    finish_input "Your email address (only used to prefill account setup)" ""
    FINISH_EMAIL=$FINISH_REPLY
  fi
  if [ "$1" = yes ] && [[ ! $FINISH_EMAIL =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    printf 'That does not look like an email address. Nothing was saved; type it in Thunderbird instead.\n'
    FINISH_EMAIL=""
    return 1
  fi
  return 0
}

finish_email_prefill() {   # documented Thunderbird identity preferences; never creates an account or stores a password
  local id=$1 root prof="" base
  for base in "$HOME/.var/app/$id/.thunderbird" "$HOME/.thunderbird"; do
    [ -f "$base/profiles.ini" ] && { root=$base; break; }
  done
  [ -n "$root" ] || return 1
  prof=$(python3 - "$root" <<'PY'
import configparser, os, sys
root = sys.argv[1]
p = configparser.ConfigParser()
p.read(os.path.join(root, "profiles.ini"), encoding="utf-8")
sections = [s for s in p.sections() if s.startswith("Profile")]
sections.sort(key=lambda s: p.get(s, "Default", fallback="0") != "1")
for s in sections:
    path = p.get(s, "Path", fallback="")
    if not path:
        continue
    full = path if os.path.isabs(path) else os.path.join(root, path)
    if p.get(s, "IsRelative", fallback="1") == "1":
        full = os.path.normpath(os.path.join(root, path))
    if os.path.commonpath([os.path.abspath(full), os.path.abspath(root)]) == os.path.abspath(root):
        print(full)
        break
PY
)
  [ -n "$prof" ] && [ -d "$prof" ] || return 1
  python3 - "$prof/user.js" "$FINISH_FULL_NAME" "$FINISH_EMAIL" <<'PY'
import os, sys
path, name, email = sys.argv[1:]
wanted = {
    "mail.identity.id1.fullName": name,
    "mail.identity.id1.useremail": email,
}
lines = []
if os.path.exists(path):
    with open(path, encoding="utf-8") as fh:
        lines = [line for line in fh if not any('"' + key + '"' in line for key in wanted)]
def js(value):
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\r", "").replace("\n", "")
for key, value in wanted.items():
    lines.append('user_pref("' + key + '", "' + js(value) + '");\n')
tmp = path + ".secure-linux-finish.tmp"
with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
    fh.writelines(lines)
os.replace(tmp, path)
PY
}

finish_app_available() {
  local app=$1 id native
  case $app in
    email) if [ "$(sl_choice_get email_client thunderbird)" = betterbird ]; then id=eu.betterbird.Betterbird; native=betterbird; else id=org.mozilla.Thunderbird; native=thunderbird; fi ;;
    bitwarden) id=com.bitwarden.desktop; native=bitwarden ;;
    keepassxc) id=org.keepassxc.KeePassXC; native=keepassxc ;;
    syncthing) [ -f "$HOME/.local/state/syncthing/config.xml" ] || [ -f "$HOME/.config/syncthing/config.xml" ]; return ;;
    kdeconnect) id=org.kde.kdeconnect; native=kdeconnect-app ;;
    signal) id=org.signal.Signal; native=signal-desktop ;;
    joplin) id=net.cozic.joplin_desktop; native=joplin-desktop ;;
    libreoffice) id=org.libreoffice.LibreOffice; native=libreoffice ;;
    librewolf) id=io.gitlab.librewolf-community; native=librewolf ;;
    ente) id=io.ente.auth; native=ente-auth ;;
    backup) id=org.gnome.World.PikaBackup; native=deja-dup ;;
    steam) id=com.valvesoftware.Steam; native=steam ;;
    flatseal) id=com.github.tchx84.Flatseal; native=flatseal ;;
    *) return 1 ;;
  esac
  { finish_have flatpak && finish_flatpak_has "$id"; } || finish_have "$native"
}

finish_app_email() {
  local id=org.mozilla.Thunderbird native=thunderbird
  [ "$(sl_choice_get email_client thunderbird)" = betterbird ] && { id=eu.betterbird.Betterbird; native=betterbird; }
  finish_identity yes || true
  if [ -n "$FINISH_EMAIL" ] && finish_email_prefill "$id"; then
    finish_record done "Thunderbird/Betterbird: your display name and email were prefilled (no password was touched)."
  else
    finish_record left "Email: type your name and email in Account Setup; automatic prefill needs an existing Thunderbird profile."
  fi
  if finish_launch "$id" "$native" -new-account; then
    printf '\nAccount Setup opens in your email app. Check your name and email, then complete the sign-in yourself.\n'
    finish_record left "Email: finish Account Setup and sign in yourself; the kit never sees your email password."
  else
    finish_record left "Email: open Thunderbird/Betterbird > Account Settings > Account Actions > Add Mail Account."
  fi
}

finish_app_bitwarden() {
  local csv=${FINISH_CSV_PATH:-$(finish_user_dir DOWNLOAD Downloads)/Google Passwords.csv}
  finish_launch com.bitwarden.desktop bitwarden || { finish_record left "Bitwarden: open it, sign in, then File > Import data."; return 1; }
  printf '\nBitwarden opens now. Sign in yourself. Then File > Import data > Chrome (csv).\nCSV: %s\n' "$csv"
  finish_record left "Bitwarden: sign in, then File > Import data > Chrome (csv); choose $csv. Delete the CSV only after checking the import."
}

finish_app_keepassxc() {
  local csv=${FINISH_CSV_PATH:-$(finish_user_dir DOWNLOAD Downloads)/Google Passwords.csv}
  finish_launch org.keepassxc.KeePassXC keepassxc || { finish_record left "KeePassXC: create/open a database, then Database > Import."; return 1; }
  printf '\nKeePassXC opens now. Create or open your database, then Database > Import > Chrome (csv).\nCSV: %s\n' "$csv"
  finish_record left "KeePassXC: create your local database, import $csv as Chrome (csv), then remove the CSV after checking."
}

finish_app_syncthing() {
  finish_open "http://127.0.0.1:8384/" || { finish_record left "Syncthing: open http://127.0.0.1:8384 and Add Remote Device."; return 1; }
  printf '\nOn the other device, open Syncthing and find Show ID / Identification. Here click Add Remote Device and enter or scan that ID.\n'
  printf 'Accept the device on the other side too. Sharing a folder is a separate choice. Internet relay and discovery are off; home-network sync stays local.\n'
  finish_record left "Syncthing: Add Remote Device, enter the other device's ID, accept it there, then share only the folders you choose."
}

finish_app_kdeconnect() {
  finish_launch org.kde.kdeconnect kdeconnect-app || finish_spawn kdeconnect-settings || {
    finish_record left "KDE Connect: install it on your Android phone, connect both to home Wi-Fi, then pair from either device."
    return 1
  }
  printf '\nOn your Android phone: install KDE Connect, join the same home Wi-Fi, open it and tap this computer > Pair. Accept the pair request here.\n'
  finish_record left "KDE Connect: on the phone, join home Wi-Fi, select this PC > Pair, then accept here."
}

finish_app_signal() {
  finish_launch org.signal.Signal signal-desktop || { finish_record left "Signal: open it and scan its linking QR code from Signal on your phone."; return 1; }
  printf '\nOn your phone: Signal > Settings > Linked devices > Link new device (the + button). Scan the QR code shown on this PC. Your Signal account stays on your phone.\n'
  finish_record left "Signal: on the phone choose Settings > Linked devices > Link new device, then scan this PC's QR code."
}

finish_app_joplin() {
  local stage=$FINISH_STATE_DIR/Notes notes=$HOME/Vaults/Notes
  mkdir -p "$stage"
  if [ ! -f "$stage/Welcome.md" ]; then
    cat > "$stage/Welcome.md" <<'EOF'
# Welcome to your notes

This folder is your first notebook. Keep ordinary Markdown notes here.
In Joplin, choose File > Import > MD - Markdown (Directory) and select this folder.
EOF
  fi
  if finish_yesno "Do you use Syncthing and want this notes folder shared on your home network?"; then
    if "$FINISH_MIGRATE" vault "$stage" Notes; then
      finish_record done "Joplin: a Notes notebook folder was created at $notes and offered to Syncthing (home network only)."
    else
      mkdir -p "$notes"; cp -an "$stage"/. "$notes"/ 2>/dev/null || true
      finish_record left "Joplin notes: the folder is at $notes, but Syncthing needs Add Folder > $notes manually."
    fi
  else
    mkdir -p "$notes"; cp -an "$stage"/. "$notes"/ 2>/dev/null || true
    finish_record done "Joplin: a first notebook folder was created at $notes (not shared)."
  fi
  finish_launch net.cozic.joplin_desktop joplin-desktop || true
  printf '\nIn Joplin: File > Import > MD - Markdown (Directory), choose %s. Joplin calls the imported folder a notebook.\n' "$notes"
  finish_record left "Joplin: File > Import > MD - Markdown (Directory), then choose $notes to create your first notebook."
}

finish_lo_write() {   # one documented LibreOffice profile; no templates, macros or accounts are changed
  local file=$1
  python3 - "$file" "$FINISH_FULL_NAME" <<'PY'
import os, sys
import xml.etree.ElementTree as ET
path, full_name = sys.argv[1:]
first, last = (full_name.strip().split(" ", 1) + [""])[:2]
initials = "".join(part[0] for part in full_name.split() if part)[:5]
OOR = "http://openoffice.org/2001/registry"
XS = "http://www.w3.org/2001/XMLSchema"
XSI = "http://www.w3.org/2001/XMLSchema-instance"
ET.register_namespace("oor", OOR)
ET.register_namespace("xs", XS)
ET.register_namespace("xsi", XSI)
os.makedirs(os.path.dirname(path), exist_ok=True)
if os.path.exists(path):
    tree = ET.parse(path)
    root = tree.getroot()
else:
    root = ET.Element("{%s}items" % OOR)
    tree = ET.ElementTree(root)
def put(group, prop_name, value):
    item = None
    for candidate in root.findall("{%s}item" % OOR):
        if candidate.get("{%s}path" % OOR) == group:
            item = candidate
            break
    if item is None:
        item = ET.SubElement(root, "{%s}item" % OOR, {"{%s}path" % OOR: group})
    prop = None
    for candidate in item.findall("{%s}prop" % OOR):
        if candidate.get("{%s}name" % OOR) == prop_name:
            prop = candidate
            break
    if prop is None:
        prop = ET.SubElement(item, "{%s}prop" % OOR)
    prop.set("{%s}name" % OOR, prop_name)
    prop.set("{%s}op" % OOR, "fuse")
    for child in list(prop):
        prop.remove(child)
    node = ET.SubElement(prop, "{%s}value" % OOR)
    node.text = value
put("/org.openoffice.UserProfile/Data", "givenname", first)
put("/org.openoffice.UserProfile/Data", "sn", last)
put("/org.openoffice.UserProfile/Data", "initials", initials)
base = "/org.openoffice.Setup/Office/Factories/org.openoffice.Setup:Factory"
for doc_type, filter_name in [
    ("com.sun.star.text.TextDocument", "MS Word 2007 XML"),
    ("com.sun.star.sheet.SpreadsheetDocument", "Calc MS Excel 2007 XML"),
    ("com.sun.star.presentation.PresentationDocument", "Impress MS PowerPoint 2007 XML"),
]:
    put(base + "['" + doc_type + "']", "ooSetupFactoryDefaultFilter", filter_name)
tmp = path + ".secure-linux-finish.tmp"
tree.write(tmp, encoding="UTF-8", xml_declaration=True)
if os.path.exists(path):
    import filecmp, shutil
    if filecmp.cmp(path, tmp, shallow=False):
        os.unlink(tmp)
        raise SystemExit(0)
    backup = path + ".before-secure-linux-finish"
    if not os.path.exists(backup):
        shutil.copy2(path, backup)
os.replace(tmp, path)
PY
}

finish_app_libreoffice() {
  if finish_have pgrep && pgrep -f 'soffice.bin' >/dev/null 2>&1; then
    finish_record left "LibreOffice: close every LibreOffice window, then run 'secure-linux-finish apps' to save your name and formats safely."
    return 1
  fi
  finish_identity no
  local paths=() p rc=0
  if finish_have flatpak && finish_flatpak_has org.libreoffice.LibreOffice; then
    paths+=("$HOME/.var/app/org.libreoffice.LibreOffice/.config/libreoffice/4/user/registrymodifications.xcu")
  else
    paths+=("$HOME/.config/libreoffice/4/user/registrymodifications.xcu")
  fi
  for p in "${paths[@]}"; do finish_lo_write "$p" || rc=1; done
  if [ "$rc" -eq 0 ]; then
    finish_record done "LibreOffice: document author set to $FINISH_FULL_NAME; new Word, Excel and PowerPoint documents default to Microsoft formats for easy sharing."
    printf '\nLibreOffice will put your name on new documents. Word, Excel and PowerPoint now save in Microsoft formats by default, so other people can open what you share. Open Document formats remain available in Save As.\n'
  else
    finish_record left "LibreOffice: its settings file could not be updated. Close LibreOffice and try again; no damaged file was replaced."
    return 1
  fi
}

finish_app_librewolf() {
  local backup
  backup=$(finish_find_backup)
  finish_browser_bookmarks "$backup"
}

finish_app_ente() {
  finish_launch io.ente.auth ente-auth || { finish_record left "Ente Auth: open it, then import your old authenticator."; return 1; }
  printf '\nIn Google Authenticator on your phone: menu > Transfer accounts > Export accounts, choose the accounts and show the QR code.\n'
  printf 'In Ente Auth here: Settings > Import > Google Authenticator, then scan the QR code. Check every code before removing the old app. Exporting exposes 2FA secrets to the camera on purpose; keep the screen private.\n'
  finish_record left "Ente Auth: Google Authenticator > Transfer accounts > Export accounts; in Ente choose Import > Google Authenticator and scan the QR."
}

finish_app_backup() {
  local target="" id=org.gnome.World.PikaBackup native=deja-dup
  if finish_pick_dir "Pick the drive for your first backup. The app will ask you for a new backup password." \
    "${SL_FINISH_MEDIA_ROOT:-/run/media/${USER:-$(id -un)}}" "/media/${USER:-$(id -un)}"; then target=$FINISH_REPLY; fi
  finish_launch "$id" "$native" || { finish_record left "First backup: open Pika Backup or Deja Dup and choose Setup Backup."; return 1; }
  printf '\nIn the backup app: Setup Backup > Location on Disk${target:+ > %s}. Choose a new backup password and store it in your password manager.\n' "$target"
  printf 'Select your home folder, then Back Up Now. Daily backups run only after you switch on the schedule and the drive is available.\n'
  finish_record left "First backup: in Pika/Deja Dup choose Setup Backup > Location on Disk${target:+ > $target}; set a backup password, then Back Up Now."
}

finish_app_steam() {
  finish_launch com.valvesoftware.Steam steam || { finish_record left "Steam: open it and sign in to your own Steam account."; return 1; }
  printf '\nSteam opens now. Sign in yourself and approve Steam Guard if asked. Cloud-enabled games download their saves after you install and start them.\n'
  finish_record left "Steam: sign in yourself, then install a game once so Steam Cloud can restore its saves."
}

finish_app_flatseal() {
  finish_launch com.github.tchx84.Flatseal flatseal || { finish_record left "Flatseal: open it only to review permissions for an app you understand."; return 1; }
  printf '\nFlatseal opens now. Pick one Flatpak app to inspect its permissions. Do not switch something off just to tidy the list; an app may need it. Change nothing unless you know why.\n'
  finish_record left "Flatseal: review one app at a time; do not remove permissions unless you understand what that app needs."
}

finish_app_offer() {
  local app=$1 explanation=$2
  finish_app_available "$app" || return 0
  printf '\n%s\n' "$explanation"
  if finish_yesno "Set up $app now?"; then
    "finish_app_$app"
  else
    finish_record skipped "$app: $explanation"
  fi
}

finish_apps() {
  finish_app_offer email "Thunderbird / Betterbird: open mail account setup and prefill your name and email where the profile supports it."
  finish_app_offer bitwarden "Bitwarden: open the app and show exactly where to import your exported password CSV."
  finish_app_offer keepassxc "KeePassXC: use the same CSV in an encrypted, no-cloud password file on this PC."
  finish_app_offer syncthing "Syncthing: link another computer or phone; syncing stays on your home network."
  finish_app_offer kdeconnect "KDE Connect: pair an Android phone for notifications, file sharing and remote input."
  finish_app_offer signal "Signal: link this computer to the Signal account already on your phone."
  finish_app_offer joplin "Joplin: make a first notebook folder and optionally share it through Syncthing."
  finish_app_offer libreoffice "LibreOffice: put your name on documents and save in Microsoft formats by default for easy sharing."
  finish_app_offer librewolf "LibreWolf: open the bookmark library and bring in the HTML file from your old browser."
  finish_app_offer ente "Ente Auth: move two-factor login codes from Google Authenticator using its export QR code."
  finish_app_offer backup "Pika Backup / Deja Dup: make your first encrypted backup to a drive you choose."
  finish_app_offer steam "Steam: open the sign-in and explain where cloud game saves come from."
  finish_app_offer flatseal "Flatseal (only because you asked): inspect Flatpak app permissions without changing them automatically."
  finish_summary
}

# ---------------------------------------------------------------- ongoing care
finish_care_printout() {
  local file tmp
  file=$(finish_user_dir DOCUMENTS Documents)/"Looking after your computer.txt"
  mkdir -p "${file%/*}"
  tmp=$(mktemp "$FINISH_STATE_DIR/care.XXXXXX") || return 1
  cat > "$tmp" <<'EOF'
LOOKING AFTER YOUR COMPUTER - one page to keep

Already working for you
-----------------------
- System security updates are checked every day. A notice tells you when a restart is needed.
- Flatpak apps are checked and updated every day.
- Secure Linux checks the computer after start-up and every six hours. Open Secure Linux Status & Fixes to see the results.
- On a Btrfs system, snapshots provide undo points and a monthly data check looks for storage damage.
- The weekly virus scan looks at Downloads and Desktop. Nothing suspicious is deleted automatically.

Your small jobs
---------------
1. Restart when the computer asks. Save your work first. This tool never restarts the computer for you.
2. Keep backups on a separate drive. Plug it in and open Pika Backup (or Deja Dup). A backup on the same disk is not enough.
3. Once a month, open Secure Linux Toolbox > Look after my computer. Read each proposed fix before saying yes.
4. If something seems wrong, open Secure Linux Status & Fixes. Use the established safe fix shown there, or save a diagnostics report and ask for help.
5. Keep your disk recovery key and backup password somewhere safe and separate from the laptop.

Useful commands
---------------
secure-linux-finish          Finish files, apps, choices and care
secure-linux-status          See health and the established safe fixes
secure-linux-toolbox         Check and look after the computer

No account is signed in and no fix is run by this printout.
EOF
  if [ -f "$file" ] && cmp -s "$tmp" "$file"; then rm -f "$tmp"
  else
    [ -f "$file" ] && [ ! -e "$file.before-secure-linux-finish" ] && cp -p "$file" "$file.before-secure-linux-finish"
    mv -f "$tmp" "$file"
  fi
  printf '%s\n' "$file"
}

finish_care() {
  local printout rc=0
  printout=$(finish_care_printout) || { finish_record left "Care sheet: it could not be written in Documents."; return 1; }
  finish_record done "One-page care sheet saved to $printout."
  printf "\nThe care sheet is here: %s\n\nNow I will run the kit's normal health refresh, then show its status. This only checks; it does not apply fixes.\n" "$printout"
  if [ -x "$FINISH_STATUS" ] || finish_have secure-linux-status; then
    "$FINISH_STATUS" --refresh || { printf 'The refresh did not finish; the results below may be older.\n' >&2; rc=1; }
    "$FINISH_STATUS" --text || rc=1
    if finish_yesno "Open Secure Linux Status & Fixes now to review any established safe fixes?"; then
      "$FINISH_STATUS" || rc=1
    else
      finish_record left "Computer care: open 'Secure Linux Status & Fixes' whenever you want to review safe fixes."
    fi
  else
    finish_record left "Computer care: secure-linux-status is missing; run the kit's repair setup before relying on health results."
    return 1
  fi
  [ "$rc" -eq 0 ] || finish_record left "Computer care: the status check did not finish cleanly; try again from Secure Linux Status & Fixes."
  finish_summary
  return "$rc"
}

finish_main_menu() {
  local a
  while :; do
    finish_menu "What would you like to finish today?" \
      "Bring over the rest of my stuff" \
      "Set up my apps for me" \
      "Use my choices on a new computer" \
      "Keep everything running" \
      "Show my finishing summary"
    case $FINISH_REPLY in
      Bring*) finish_stuff ;;
      Set*) finish_apps ;;
      Use*)
        finish_menu "Choices contain app and comfort settings only - never passwords, Wi-Fi, keys or tokens." \
          "Export this PC's safe choices" "Import choices on this PC"
        if [[ $FINISH_REPLY = Export* ]]; then
          if finish_input "Folder for secure-linux-choices.json" "$(finish_user_dir DOCUMENTS Documents)" && [ -n "$FINISH_REPLY" ]; then
            finish_choices_export "$FINISH_REPLY"
          else
            finish_record skipped "Export this PC's safe choices."
          fi
        elif [[ $FINISH_REPLY = Import* ]]; then
          if finish_input "Full path to secure-linux-choices.json" "" && [ -n "$FINISH_REPLY" ]; then
            finish_choices_import "$FINISH_REPLY"
          else
            finish_record skipped "Import choices on this PC."
          fi
        fi
        finish_summary ;;
      Keep*) finish_care ;;
      Show*) finish_summary ;;
      *) if [ "$FINISH_GUI" = 1 ] || [ ${#FINISH_DONE[@]} -gt 0 ] || [ ${#FINISH_LEFT[@]} -gt 0 ]; then finish_summary; fi; return 0 ;;
    esac
  done
}
