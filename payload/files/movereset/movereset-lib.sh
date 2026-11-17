# shellcheck shell=bash
# movereset-lib.sh - shared parts of "Move my setup" (bin/secure-linux-move-setup) and "Reset this computer, keep my
# files" (bin/secure-linux-reset). Sourced after lib/common.sh, never run on its own. Owned by: movereset (P27).
#   Lists (files/movereset/*.list, one path per line, relative to the home folder; # starts a comment):
#     never-touch.list     never moved aside by a reset and never packed for a move (keys, passwords, browsers,
#                          messages, email, sync pairings, the backup key, your own folders of files)
#     reset-settings.list  desktop look and behaviour that a settings reset moves aside (never deletes)
#     move-settings.list   look-only settings that "Move my setup" carries; mr_stage_setting cleans them
#   The reset point (written once, by steps/96-reset-point.sh at the first successful setup, never rewritten):
#     /var/lib/secure-linux/movereset/reset-point/{created,origin,profile,release,flatpak-apps.txt,
#     app-library.list} and rpm-user.txt (or rpm-unknown when the list could not be read).

MR_FILES=${MR_FILES:-$SL_ROOT/files/movereset}
MR_STATE=$SL_STATE/movereset                          # administrator-owned: reset point and reset records
MR_POINT=$MR_STATE/reset-point
MR_USTATE=${HOME:-/nonexistent}/.local/state/secure-linux/movereset   # the person's own: requests, staged settings
MR_FOLDER_KEYS="Desktop Documents Downloads Music Pictures Videos"   # the folders of files a move can carry

mr_say() { printf '%s\n' "$*"; }
mr_die() { printf '%s\n' "$1" >&2; exit "${2:-1}"; }
mr_have() { command -v "$1" >/dev/null 2>&1; }
mr_stamp() { printf '%s' "${MR_STAMP:-$(date '+%Y%m%d-%H%M%S')}"; }   # MR_STAMP: tests only

mr_list() {   # mr_list NAME   -> the entries of files/movereset/NAME.list (comments, blank lines and bad lines dropped)
  local line
  [ -f "$MR_FILES/$1.list" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line%"${line##*[![:space:]]}"}
    line=${line#"${line%%[![:space:]]*}"}
    [ -n "$line" ] || continue
    mr_safe_rel "$line" && printf '%s\n' "$line"
  done < "$MR_FILES/$1.list"
}

mr_safe_rel() {   # mr_safe_rel PATH   -> true for a plain relative path: no "..", ".", empty parts, leading "/",
                  # backslash or control characters; at most 1024 bytes
  local p=$1 part parts=()
  [ -n "$p" ] && [ "${#p}" -le 1024 ] || return 1
  case "$p" in /*|*\\*) return 1 ;; esac
  [[ "$p" == *[[:cntrl:]]* ]] && return 1
  IFS=/ read -r -a parts <<< "$p"
  [ "${#parts[@]}" -gt 0 ] || return 1
  case "$p" in */) return 1 ;; esac
  for part in "${parts[@]}"; do
    case "$part" in ""|.|..) return 1 ;; esac
  done
  return 0
}

mr_under() {   # mr_under PATH ENTRY   -> true when PATH is ENTRY or lies inside the folder ENTRY
  [ "$1" = "$2" ] && return 0
  case "$1" in "$2"/*) return 0 ;; esac
  return 1
}

mr_never() {   # mr_never PATH   -> true when PATH is, lies inside, or holds a never-touch entry
  local e
  while IFS= read -r e; do
    mr_under "$1" "$e" && return 0
    mr_under "$e" "$1" && return 0
  done < <(mr_list never-touch)
  return 1
}

mr_listed() {   # mr_listed LISTNAME PATH   -> true when PATH is an entry of the list or lies inside a folder entry
  local e
  while IFS= read -r e; do mr_under "$2" "$e" && return 0; done < <(mr_list "$1")
  return 1
}

mr_flatpak_id_ok() { printf '%s' "$1" | grep -qE '^[A-Za-z0-9_][A-Za-z0-9_-]*([.][A-Za-z0-9_-]+){2,}$'; }   # 90-finish.sh's rule, no leading "-"
mr_pkg_ok() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,99}$ ]]; }
mr_applib_id_ok() { [[ "$1" =~ ^[a-z0-9][a-z0-9._+-]{0,63}$ ]]; }

mr_free_kb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4+0}'; }   # free space (KB) where folder $1 lives
mr_size_kb() { [ $# -gt 0 ] || { echo 0; return 0; }; du -sk "$@" 2>/dev/null | awk '{s+=$1} END {print s+0}'; }

mr_in_rollback_session() {   # true while the computer runs an "earlier day" from the boot menu (X2a boot rollback)
  local t
  for t in $(cat "${MR_CMDLINE:-/proc/cmdline}" 2>/dev/null); do
    case "$t" in rd.securelinux.rollback=?*) return 0 ;; esac
  done
  return 1
}

mr_user_folder() {   # mr_user_folder KEY   -> this person's folder for Desktop|Documents|Downloads|Music|Pictures|Videos
  local key=$1 xdg d
  case "$key" in
    Desktop) xdg=DESKTOP ;; Documents) xdg=DOCUMENTS ;; Downloads) xdg=DOWNLOAD ;;
    Music) xdg=MUSIC ;; Pictures) xdg=PICTURES ;; Videos) xdg=VIDEOS ;; *) return 1 ;;
  esac
  d=""
  mr_have xdg-user-dir && d=$(xdg-user-dir "$xdg" 2>/dev/null)
  case "$d" in "$HOME"/?*) ;; *) d=$HOME/$key ;; esac     # never the home folder itself, never outside it
  printf '%s' "$d"
}

# ---------------------------------------------------------------- what is on this computer now
mr_flatpaks_now() {   # system-wide app store apps (ids), sorted; fails when the list could not be read
  local out
  mr_have flatpak || return 0
  out=$(flatpak list --system --app --columns=application 2>/dev/null) || return 1
  printf '%s\n' "$out" | while IFS= read -r id; do mr_flatpak_id_ok "$id" && printf '%s\n' "$id"; done | sort -u
}
mr_rpms_now() {   # names of the programs installed on purpose (not only as a part of another), sorted
  local out
  mr_have dnf || return 1
  out=$(dnf repoquery --userinstalled --queryformat '%{name}\n' 2>/dev/null) || return 1
  printf '%s\n' "$out" | sed 's/\\n$//' | while IFS= read -r p; do mr_pkg_ok "$p" && printf '%s\n' "$p"; done | sort -u
}

# ---------------------------------------------------------------- the reset point
mr_point_exists() { [ -f "$MR_POINT/created" ] && [ -f "$MR_POINT/flatpak-apps.txt" ]; }
mr_point_date() { sed -n '1p' "$MR_POINT/created" 2>/dev/null; }

mr_make_point() {   # mr_make_point ORIGIN   write the reset point once. 0 made, 2 one exists already, 1 not now
  local origin=$1 tmp fl rp
  mr_point_exists && return 2
  [ -e "$MR_POINT" ] && return 2
  mkdir -p "$MR_STATE" || return 1
  chmod 0755 "$MR_STATE" 2>/dev/null
  fl=$(mr_flatpaks_now) || { echo "The list of app store apps could not be read, so no reset point was made this time."; return 1; }
  tmp=$MR_STATE/.reset-point.new
  rm -rf "$tmp"; mkdir -p "$tmp" || return 1
  date '+%Y-%m-%d %H:%M' > "$tmp/created"
  printf '%s\n' "$origin" > "$tmp/origin"
  sl_profile > "$tmp/profile"
  sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SL_ROOT/release.json" 2>/dev/null | head -n 1 > "$tmp/release"
  if [ -n "$fl" ]; then printf '%s\n' "$fl" > "$tmp/flatpak-apps.txt"; else : > "$tmp/flatpak-apps.txt"; fi
  if ! sl_is_atomic && rp=$(mr_rpms_now) && [ -n "$rp" ]; then
    printf '%s\n' "$rp" > "$tmp/rpm-user.txt"
  else
    : > "$tmp/rpm-unknown"
  fi
  if [ -f "$SL_ETC/app-library.list" ]; then cp "$SL_ETC/app-library.list" "$tmp/app-library.list"; else : > "$tmp/app-library.list"; fi
  chmod 0644 "$tmp"/* 2>/dev/null; chmod 0755 "$tmp"
  mv "$tmp" "$MR_POINT" || { rm -rf "$tmp"; return 1; }
  return 0
}

mr_added_flatpaks() {   # app store apps on this computer now that were not there at the reset point
  local now
  now=$(mr_flatpaks_now) || return 1
  [ -n "$now" ] || return 0
  printf '%s\n' "$now" | grep -vxF -f "$MR_POINT/flatpak-apps.txt"   # an empty first-day list: every app is added
  return 0
}

MR_PROTECTED_RPMS='^(kernel.*|systemd.*|dnf.*|libdnf.*|rpm.*|glibc.*|shim.*|grub2.*|sudo|polkit.*|selinux-policy.*|cryptsetup.*|NetworkManager.*|firewalld.*|dracut.*|flatpak.*|snapper.*|btrfs-progs|bash|coreutils|util-linux.*|fedora-release.*|fedora-repos.*|plasma-.*|kde-.*|sddm.*)$'
mr_added_rpms() {   # programs installed on purpose since the reset point (never the protected core of the system)
  local now
  [ -f "$MR_POINT/rpm-user.txt" ] || return 1
  now=$(mr_rpms_now) || return 1
  printf '%s\n' "$now" | grep -vxF -f "$MR_POINT/rpm-user.txt" | grep -vE "$MR_PROTECTED_RPMS"
  return 0
}

mr_join() { tr '\n' ' ' | sed 's/ *$//'; }   # one line of words from a list

# ---------------------------------------------------------------- moved settings: what is never brought in
# A moved setup may come from anywhere (a drive someone hands you), so every settings file is cleaned before it is
# staged. The rule is about a CLASS, not a list of known bad keys: nothing that makes the desktop start a program,
# load a library or plug-in, make a D-Bus call, or read a file a person or a drive can change is brought in.
#   1. Groups left out whole (and every line in them, until the next proper group line): a group whose name has a
#      word of MR_GROUP_WORDS - kwinrc [Wayland] (InputMethod= is a .desktop file KWin starts at every login) and
#      [Xwayland], kwinrc [ModifierOnlyShortcuts] (a D-Bus call on a key press), [Script-*] (KWin script settings),
#      powerdevilrc [*][RunScript] (commands run on power events), katerc [lspclient] (language-server programs and
#      their config file), [Konsole] (RunPrefix), [BuildConfig]. A group line that is not one proper "[name]..."
#      line, or holds a backslash (an escaped name) or a control character, also starts a left-out stretch.
#   2. Keys left out: a key whose name has a word of MR_RUN_WORDS anywhere in it, spaces allowed ("Shell Command",
#      kdeglobals TerminalApplication=/TerminalService=/BrowserApplication=, kwinrc library=, gtk-modules=,
#      gtk-im-module=, gtk-print-preview-command=, okularpartrc ExternalEditorCommand=, Kate's *CommandLines=,
#      and Kate's RunPrefix= and ServerConfiguration= even outside their own groups);
#      a key with "$" ([$e] expansion marks) or a backslash (KConfig reads \x41 escapes in key names); a pinned
#      launcher or favourite that points at a file.
#   3. Values left out: a value with "$" (KConfig expands $HOME in path entries even without [$e]), "~" or any
#      backslash (KConfig reads \s, \t and \x41 escapes), a file: address that is not this computer, and any
#      address other than http(s):// and KDE's preferred:// app names (smb://, sftp://, desktop:/, applications:/).
#      Then the value is cut at "," and ";" and every piece holding a "/" must, as a whole, be one of two shapes: a
#      path under /usr, /opt, /etc or /var/lib/flatpak with no space, ":", ".." or "%" in it; or a plain word path
#      such as a time zone (Europe/London: letters, digits, _ + - only) that does not start in a folder a move
#      brings (Desktop, Documents, Downloads, Music, Pictures, Videos, Public, Templates). Anything else - a path in
#      the home folder, on a drive or in /tmp, a second path after a space, a program with its arguments - is left
#      out. Pictures are the one exception, and only for a picture setting (a key named like MR_PICTURE_KEYS whose
#      every path ends in a picture extension): wallpapers come along.
#   4. Other lines: a line naming a .desktop file by path (a bookmark) and a line with a control character are left
#      out; a line that runs on to the next (ends in a backslash) leaves the whole file out.
#   Kept on purpose: plug-in and theme ids (plugin=, widgetStyle=, Theme=, LookAndFeelPackage=: they only name what
#   is already installed on this computer, never a file from the moved setup), app ids (applications:x.desktop,
#   preferred://browser), web addresses, and plain words, numbers, colours and fonts.
# Xfce's XML files are kept only when every line is one of the one-line shapes xfconf itself writes (anything else -
# other quotes, a setting split over lines, entities, comments - and the whole file is left out); then a setting
# whose name has a run word, or whose value fails rule 3, is dropped, and a file where such a setting holds other
# settings is left out whole. GNOME keeps its settings in dconf, which a move never carries (move-settings.list).
MR_RUN_WORDS='exec|command|cmd|application|program|executable|script|shell|module|service|library|inputmethod|runprefix|serverconfig'
MR_GROUP_WORDS="$MR_RUN_WORDS|wayland|modifieronlyshortcuts|lspclient|konsole|build|externaltool|environment|autostart"
MR_PICTURE_KEYS='image|wallpaper|picture|background|backdrop'
MR_XML_SHAPES=(-e '^<\?xml version="1\.0" encoding="UTF-8"\?>$' -e '^[[:space:]]*$'
  -e '^<channel name="[A-Za-z0-9_.-]+" version="1\.0">$' -e '^</channel>$'
  -e '^[[:space:]]*<property name="[A-Za-z0-9_.-]+" type="[a-z0-9]+"( value="[^"<>&]*")?/?>$'
  -e '^[[:space:]]*</property>$' -e '^[[:space:]]*<value type="[a-z0-9]+" value="[^"<>&]*"/>$')
# The awk program behind mr_stage_setting (rules 1-4). Its "$" signs are awk's own.
# shellcheck disable=SC2016
MR_FILTER_AWK='
function bad_piece(p, pic) {
  sub(/^[ \t"'"'"'(]+/, "", p); sub(/[ \t"'"'"')]+$/, "", p)
  if (p !~ /\//) return 0
  if (p ~ /%/ || p ~ /(^|\/)\.\.?(\/|$)/) return 1
  if (substr(p, 1, 1) == "/") {
    sub(/^\/+/, "/", p)
    if (p ~ /^\/(usr|opt|etc|var\/lib\/flatpak)\/[^ \t:]*$/) return 0
    if (pic && p ~ /^\/[^:]*\.(jpe?g|png|svgz?|webp|avif|jxl|bmp|gif|heic|heif|tiff?|xpm|ico)$/) return 0
    return 1
  }
  if (p !~ /^[a-z0-9_+-]+(\/[a-z0-9_+-]+)+\/?$/) return 1
  if (p ~ /^(desktop|documents|downloads|music|pictures|videos|public|templates)\//) return 1
  return 0
}
function bad_value(key, v,    t, n, i, part, pic) {
  t = tolower(v); pic = (tolower(key) ~ PICS)
  if (t ~ /[$~]/ || index(t, "\\")) return 1
  gsub(/file:\/\/localhost\//, "file:///", t)
  if (t ~ /file:\/\/[^\/]/ || t ~ /file:([^\/]|$)/) return 1
  gsub(/file:\/+/, "/", t)
  gsub(/(https?|preferred):\/\/[^ \t,;"'"'"')]*/, " ", t)
  if (t ~ /[a-z0-9+.-]:\/\//) return 1
  n = split(t, part, /[,;]/)
  for (i = 1; i <= n; i++) if (bad_piece(part[i], pic)) return 1
  return 0
}
BEGIN { drop = 0; status = 0; cur = "" }
{
  line = $0; sub(/\r$/, "", line)
  if (line ~ /\\$/) { status = 3; exit }
  if (MODE == "xml") {
    nm = ""; self = (line ~ /\/>[ \t]*$/)
    if (match(line, /name="[^"]*"/)) {
      nm = substr(line, RSTART + 6, RLENGTH - 7)
      if (tolower(nm) ~ WORDS) { if (self) next; status = 3; exit }
      if (line ~ /<property / && !self) cur = nm
    }
    if (match(line, /value="[^"]*"/) && bad_value(nm != "" ? nm : cur, substr(line, RSTART + 7, RLENGTH - 8))) {
      if (self) next
      status = 3; exit
    }
    print $0; next
  }
  if (line ~ /^[ \t]*\[/) {
    if (line ~ /[\001-\010\013-\037\177]/ || line !~ /^[ \t]*(\[[^]\\]*\])+[ \t]*$/ || tolower(line) ~ GRPW) { drop = 1; next }
    drop = 0; print $0; next
  }
  if (drop || line ~ /[\001-\010\013-\037\177]/) next
  eq = index(line, "=")
  if (eq == 0) { if (tolower(line) ~ /\/[^,;]*\.desktop/) next; print $0; next }
  key = tolower(substr(line, 1, eq - 1)); val = substr(line, eq + 1)
  if (key ~ /[\\$]/ || key ~ WORDS) next
  if (key ~ /^[ \t]*(launchers|favorites)/ && tolower(val) ~ /file:/) next
  if (bad_value(key, val)) next
  print $0
}
END { exit status }'
mr_stage_setting() {   # mr_stage_setting SRC DEST   -> 0: DEST is SRC cleaned as above; 1: SRC is left out
  local mode=ini
  case "$1" in
    *.xml) grep -a -q -v -E "${MR_XML_SHAPES[@]}" "$1" && return 1          # a line of another shape: fail closed
           mode=xml ;;
  esac
  # 0: cleaned (an empty result only means every line was left out); anything else: the file is left out
  LC_ALL=C awk -v MODE="$mode" -v WORDS="$MR_RUN_WORDS" -v GRPW="$MR_GROUP_WORDS" -v PICS="$MR_PICTURE_KEYS" \
    "$MR_FILTER_AWK" "$1" > "$2" || return 1
}

mr_hold_window() {   # from the menu: keep the window open at the end, so the result (or why nothing changed) can be
                     # read. Only when a person is at a terminal (MR_HOLD=1 or 0 forces it on or off: tests only).
  local x
  case "${MR_HOLD:-auto}" in 1) ;; auto) [ -t 0 ] && [ -t 1 ] || return 0 ;; *) return 0 ;; esac
  printf '\n%s' "Press Enter to close this window. "
  IFS= read -r x || true
  return 0
}
