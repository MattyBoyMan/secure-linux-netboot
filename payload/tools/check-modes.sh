#!/bin/bash
# check-modes.sh - lists every script in the kit that starts with a "#!" line but is NOT marked executable.
#   bash linux/tools/check-modes.sh                 check the folder this script lives in (linux/)
#   bash linux/tools/check-modes.sh DIR             check another copy of linux/
#   bash linux/tools/check-modes.sh --tar FILE      check the modes INSIDE a packed secure-linux.tar.gz (what the
#                                                   installed computer will really get)
#   bash linux/tools/check-modes.sh --fix           also run chmod +x on what it finds (folder mode only)
# Looks at: bin/, rescue/, server/ (with sub-folders), files/**/*.sh, steps/, plus setup.sh, hw/, wizard.d/, asahi/, tools/.
# Exit 0 = nothing missing, 1 = something lacks the executable bit (or can't be checked).
# NOTE: on Windows, exFAT/NTFS drives (the USB stick, D:) report every file as 755, so a folder check there proves
# nothing. Use --tar on the built archive, or run this on Linux (for example inside the unpacked /usr/local/lib/secure-linux).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd); TAR=""; FIX=no
while [ $# -gt 0 ]; do
  case $1 in
    --tar) TAR=${2:-}; shift ;;
    --fix) FIX=yes ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "I don't know '$1'. Try --help." >&2; exit 2 ;;
    *) ROOT=$(cd "$1" && pwd) || exit 2 ;;
  esac; shift
done

# Which relative paths we care about (checked after unpacking for --tar)
wanted() {
  case $1 in
    bin/*|rescue/*|server/*|steps/*|hw/*|wizard.d/*|asahi/*|tools/*|setup.sh) return 0 ;;
    files/*.sh|files/*/*.sh|files/*/*/*.sh|files/*/*/*/*.sh) return 0 ;;
  esac
  return 1
}
has_shebang() { [ "$(head -c2 "$1" 2>/dev/null)" = '#!' ]; }

missing=0; checked=0
report() { printf '  not executable: %s\n' "$1"; missing=$((missing + 1)); }

if [ -n "$TAR" ]; then
  [ -f "$TAR" ] || { echo "No such archive: $TAR" >&2; exit 2; }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/sl-modes.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
  tar -xzf "$TAR" -C "$tmp" 2>/dev/null || { echo "Could not unpack $TAR" >&2; exit 2; }
  # the mode column of the listing ("-rwxr-xr-x" ...) and the name (last field) of every file entry
  while IFS= read -r line; do
    perms=${line%% *}; name=${line##* }; name=${name#./}
    case $perms in -*) ;; *) continue ;; esac
    wanted "$name" || continue
    [ -f "$tmp/$name" ] && has_shebang "$tmp/$name" || continue
    checked=$((checked + 1))
    case ${perms:3:1}${perms:6:1}${perms:9:1} in *x*) ;; *) report "$name  ($perms)" ;; esac
  done < <(tar -tvzf "$TAR" 2>/dev/null)
else
  while IFS= read -r f; do
    rel=${f#"$ROOT"/}
    wanted "$rel" || continue
    has_shebang "$f" || continue
    checked=$((checked + 1))
    if [ ! -x "$f" ]; then
      report "$rel"
      [ $FIX = yes ] && chmod +x "$f" && echo "    fixed"
    fi
  done < <(find "$ROOT" -type f ! -path '*/.git/*' | sort)
fi

if [ $missing -eq 0 ]; then echo "All $checked scripts that start with #! are executable."; exit 0; fi
echo "$missing of $checked scripts lack the executable bit."
echo "Why it matters: bin/* and setup.sh are chmod 0755 after unpacking (fedora.ks, install-on-existing-fedora.sh); anything else"
echo "that is run directly (not with 'bash FILE') needs the bit in the archive. rescue/ and server/ go to the stick, where the"
echo "documented way to start them is 'sudo bash FILE'."
exit 1
