#!/bin/bash
# Secure Linux (Debian): glue that lets the SHARED tools from linux/bin (written for Fedora) run on Debian without editing them.
# Source it from a Debian wrapper in bin/. Safe to source more than once.
#
# Why this exists: secure-linux-parts decides "is this Fedora?" from /etc/os-release and installs with the Fedora package tools.
# The shared script has no switch for another distribution, so the wrapper
#   1. sets SL_PARTS_MAP (the Debian package map, supported by the shared script),
#   2. puts two tiny stand-in commands (rpm, dnf) first in PATH that answer with apt/dpkg instead,
#   3. gives it a stand-in os-release through SL_TEST_OSRELEASE (a hook the shared script reads),
# all only for the one child process. Nothing on the system is changed. The exact upstream change that would make this
# unnecessary is written in docs/run/handover-C2-*.md (FINDINGS).
[ -n "${SL_COMPAT_LOADED:-}" ] && return 0
SL_COMPAT_LOADED=1

SL_ROOT=${SL_ROOT:-/usr/local/lib/secure-linux}

sl_shared() {   # sl_shared NAME -> path of the shared (Fedora-written) tool, or nothing
  local n=$1 d
  for d in "${SL_SHARED:-}" "$SL_ROOT/shared" "$SL_ROOT/linux/bin"; do
    [ -n "$d" ] && [ -f "$d/$n" ] && { printf '%s' "$d/$n"; return 0; }
  done
  return 1
}
sl_need_shared() {   # sl_need_shared NAME -> prints the path; or a plain message and exit 1
  local p; p=$(sl_shared "$1") && { printf '%s' "$p"; return 0; }
  echo "This part of Secure Linux ($1) isn't installed on this computer yet." >&2
  echo "Open 'Secure Linux Status & Fixes' and choose 'Repair setup', then try again." >&2
  exit 1
}
sl_elevate_self() {   # sl_elevate_self SELF ARGS...  re-run the WRAPPER as root (so its environment is rebuilt as root)
  local self=$1; shift
  [ "$(id -u)" -eq 0 ] && return 0
  if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v pkexec >/dev/null 2>&1; then exec pkexec "$self" "$@"; fi
  if command -v sudo >/dev/null 2>&1; then exec sudo "$self" "$@"; fi
  command -v pkexec >/dev/null 2>&1 && exec pkexec "$self" "$@"
  echo "This needs administrator rights: run it with sudo." >&2; exit 1
}

# ---------------------------------------------------------------- stand-ins for the Fedora package tools
sl_compat_shims() {   # sl_compat_shims DIR   writes DIR/rpm and DIR/dnf
  local d=$1
  mkdir -p "$d" || return 1
  cat > "$d/rpm" <<'EOF'
#!/bin/bash
# stand-in for "rpm -q NAME" and "rpm -q --whatprovides NAME" on Debian (answers from dpkg)
[ "${1:-}" = -q ] || exit 1
shift
[ "${1:-}" = --whatprovides ] && { shift; p=${1:-}; dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' && exit 0; command -v "$p" >/dev/null 2>&1 && exit 0; exit 1; }
p=${1:-}
dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed'
EOF
  cat > "$d/dnf" <<'EOF'
#!/bin/bash
# stand-in for "dnf -y install --skip-unavailable PKG..." on Debian: installs, with apt, the packages that exist
[ "${1:-}" = -y ] && shift
[ "${1:-}" = install ] || { echo "This stand-in only installs packages." >&2; exit 1; }
shift
# Offline fallback (the wrapper sets SL_PARTS_OFFLINE=1 and SL_OFFLINE_FW_DIR when there is no internet): firmware
# .deb files from the USB stick's offline pool, installed with dpkg. Anything not in the pool waits for the internet.
if [ "${SL_PARTS_OFFLINE:-}" = 1 ] && [ -n "${SL_OFFLINE_FW_DIR:-}" ]; then
  # The shared pool helper does the find + dpkg + plain-English reporting, and returns 1 when nothing was
  # installed (B1+B8, 2026-11-04: the inline version used to exit 0 even when a package was not in the
  # pool, so the caller believed a missing firmware package had been installed).
  . "${SL_ROOT:-/usr/local/lib/secure-linux}/lib/common.sh"
  rc=0
  for a in "$@"; do
    case "$a" in -*) continue ;; esac
    sl_offline_fw_install "$a" || rc=1
  done
  exit $rc
fi
want=()
for a in "$@"; do
  case "$a" in -*) continue ;; esac
  if apt-cache policy "$a" 2>/dev/null | grep -q 'Candidate: [^(]'; then want+=("$a"); else echo "Not in this Debian: $a (skipped)"; fi
done
[ ${#want[@]} -eq 0 ] && exit 0
export DEBIAN_FRONTEND=noninteractive
apt-get update -q >/dev/null 2>&1 || true
apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install "${want[@]}" && exit 0
rc=0
for a in "${want[@]}"; do   # one broken package must not block the rest
  apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install "$a" || rc=1
done
exit $rc
EOF
  chmod +x "$d/rpm" "$d/dnf"
}
sl_compat_osrelease() {   # sl_compat_osrelease FILE   an os-release the shared parts tool accepts as "a system it can install on"
  printf 'NAME="Debian GNU/Linux (via Secure Linux)"\nID=fedora\nID_LIKE=debian\n' > "$1"
}
sl_say_debian() {   # filter: the shared tools' wording is Fedora's; this is Debian
  sed -e "s/Fedora's own repositories (and RPM Fusion, which Secure Linux already uses)/Debian's own archive/" \
      -e "s/Fedora's own repositories/Debian's own archive/g" \
      -e 's/this Fedora release/this Debian release/g' \
      -e 's/Fedora/Debian/g' \
      -e 's/RPM Fusion/Debian non-free/g'
}
sl_online_deb() { curl -fsS --max-time 8 -o /dev/null https://deb.debian.org/debian/ 2>/dev/null; }
