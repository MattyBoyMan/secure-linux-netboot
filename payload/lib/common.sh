#!/bin/bash
# Shared helpers for setup steps and helper commands. Source it; don't run it.
# Safe to source more than once.
[ -n "${SL_COMMON_LOADED:-}" ] && return 0
SL_COMMON_LOADED=1

SL_ROOT=${SL_ROOT:-/usr/local/lib/secure-linux}
# The system folders can be redirected by tests (and only by tests): export SL_ETC / SL_STATE / SL_LOGDIR /
# SL_FAILS before sourcing this file. On a real machine nothing sets them, so the defaults below are used.
SL_ETC=${SL_ETC:-/etc/secure-linux}
SL_STATE=${SL_STATE:-/var/lib/secure-linux}
SL_LOGDIR=${SL_LOGDIR:-/var/log/secure-linux}
SL_FAILS=${SL_FAILS:-$SL_LOGDIR/failures.log}
SL_MODE=${SL_MODE:-install}

# ---------------------------------------------------------------- CPU architecture (Intel/AMD vs Apple Silicon)
# sl_arch prints x86_64 | aarch64 | i686 | ... (arm64 -> aarch64, amd64 -> x86_64, i386..i586 -> i686).
# Tests set SL_TEST_ARCH to pretend to be another machine; a real machine never sets it.
sl_arch() {
  local a=${SL_TEST_ARCH:-$(uname -m 2>/dev/null)}
  case "$a" in
    amd64|x86_64) echo x86_64 ;;
    arm64|aarch64|aarch64_be) echo aarch64 ;;
    i[3-6]86) echo i686 ;;
    *) echo "${a:-unknown}" ;;
  esac
}
sl_is_x86_64() { [ "$(sl_arch)" = x86_64 ]; }
sl_is_arm() { case "$(sl_arch)" in aarch64|arm*) return 0 ;; *) return 1 ;; esac; }   # Apple Silicon, Raspberry Pi...
sl_ram_gb() {      # whole GB of RAM (rounded down; tests may set SL_TEST_RAM_GB)
  [ -n "${SL_TEST_RAM_GB:-}" ] && { echo "$SL_TEST_RAM_GB"; return 0; }
  awk '/^MemTotal:/ {print int($2/1048576); f=1} END {if (!f) print 0}' "${SL_TEST_PROC:-/proc}/meminfo" 2>/dev/null
}

# ---------------------------------------------------------------- identity / settings
sl_build_get() {   # sl_build_get KEY [default]   (from build.conf written by the USB builder)
  local v=""
  [ -f "$SL_ROOT/build.conf" ] && v=$(sed -n "s/^$1=//p" "$SL_ROOT/build.conf" | tail -1)
  printf '%s' "${v:-${2:-}}"
}
sl_profile() { cat "$SL_ETC/profile" 2>/dev/null || echo full; }
sl_user()    { cat "$SL_ETC/user" 2>/dev/null || sl_build_get SL_USER; }
sl_user_home() { getent passwd "$(sl_user)" | cut -d: -f6; }

sl_choice_get() {  # sl_choice_get key [default]
  local v=""
  [ -f "$SL_ETC/choices" ] && v=$(sed -n "s/^$1=//p" "$SL_ETC/choices" | tail -1)
  printf '%s' "${v:-${2:-}}"
}
sl_choice_set() {  # sl_choice_set key value   (root only)
  mkdir -p "$SL_ETC"; touch "$SL_ETC/choices"
  sed -i "/^$1=/d" "$SL_ETC/choices"
  printf '%s=%s\n' "$1" "$2" >> "$SL_ETC/choices"
}

# ---------------------------------------------------------------- running things
try() {            # try cmd args...   run, log, record failure, never abort
  echo ">> $*"
  "$@"; local rc=$?
  [ $rc -ne 0 ] && echo "FAILED ($rc): $*" | tee -a "$SL_FAILS" >&2
  return $rc
}
sl_step() {        # sl_step "What is happening"   (progress for the welcome screen)
  # The number is the current step FILE (set by setup.sh), so several sl_step calls in one file share it
  echo; echo "=== [${SL_STEP_N:-?}/${SL_STEP_TOTAL:-?}] $* ==="
  mkdir -p "$SL_STATE"
  printf '%s|%s|%s\n' "${SL_STEP_N:-?}" "${SL_STEP_TOTAL:-?}" "$*" > "$SL_STATE/progress"
}
sl_is_atomic() { [ "$(sl_profile)" = atomic ] || [ -e /run/ostree-booted ]; }
sl_online() { curl -fsS --max-time 10 -o /dev/null https://dl.flathub.org 2>/dev/null; }

# ---------------------------------------------------------------- deliberate skips (not failures)
# An app with no build for this computer (for example x86-only programs on an Apple Silicon Mac) is SKIPPED, not
# failed: it never goes into failures.log. Each skip is written once to $SL_STATE/skipped-apps, one line "app|reason".
sl_skip_app() {    # sl_skip_app APP "plain-English reason"
  local f="$SL_STATE/skipped-apps"
  echo "Skipping $1: $2"
  mkdir -p "$SL_STATE"
  grep -q -F -x -e "$1|$2" "$f" 2>/dev/null && return 0
  { awk -F'|' -v a="$1" '$1 != a' "$f" 2>/dev/null; printf '%s|%s\n' "$1" "$2"; } > "$f.new"
  mv -f "$f.new" "$f"; chmod 644 "$f"
}
sl_unskip_app() {  # sl_unskip_app APP   it installed after all (for example a later repair run)
  local f="$SL_STATE/skipped-apps"
  [ -f "$f" ] || return 0
  awk -F'|' -v a="$1" '$1 != a' "$f" > "$f.new"; mv -f "$f.new" "$f"
}
# sl_flatpak_has_build APP   true if Flathub has a build of APP for this computer. Always true on x86_64 (unchanged
# behaviour). On ARM: asks Flathub when online, otherwise uses a short list of apps known to be x86-only.
SL_FLATPAK_X86_ONLY="com.valvesoftware.Steam com.heroicgameslauncher.hgl net.davidotek.pupgui2 com.usebottles.bottles org.upscayl.Upscayl org.signal.Signal net.cozic.joplin_desktop io.ente.auth"
sl_flatpak_has_build() {
  sl_is_arm || return 0
  if [ "${SL_FLATPAK_ONLINE:-}" = "" ]; then
    if sl_online; then SL_FLATPAK_ONLINE=yes; else SL_FLATPAK_ONLINE=no; fi   # asked once per run
  fi
  if [ "$SL_FLATPAK_ONLINE" = yes ]; then
    flatpak remote-info --arch=aarch64 flathub "$1" >/dev/null 2>&1
  else
    case " $SL_FLATPAK_X86_ONLY " in *" $1 "*) return 1 ;; *) return 0 ;; esac
  fi
}

# ---------------------------------------------------------------- installing (idempotent)
sl_dnf_install() { # sl_dnf_install pkg...   installs only missing packages
  sl_is_atomic && { echo "skip (atomic): dnf install $*"; return 0; }
  local missing=() p
  for p in "$@"; do rpm -q "$p" >/dev/null 2>&1 || rpm -q --whatprovides "$p" >/dev/null 2>&1 || missing+=("$p"); done
  [ ${#missing[@]} -eq 0 ] && return 0
  try dnf -y install "${missing[@]}"
}
sl_flatpak_install() { # sl_flatpak_install app-id...   system-wide from Flathub, only missing ones
  local id rc=0
  for id in "$@"; do
    flatpak info --system "$id" >/dev/null 2>&1 && continue
    try flatpak install -y --noninteractive --system flathub "$id" || rc=1
  done
  return $rc
}
sl_enable() {      # sl_enable unit...   enable (and start, unless in the installer chroot)
  if [ "$SL_MODE" = early ]; then try systemctl enable "$@"; else try systemctl enable --now "$@"; fi
}

# ---------------------------------------------------------------- files (respect user edits)
# sl_write_file PATH [MODE] < content
# Writes content if it differs. In repair mode, a file the user edited since we last wrote it is left alone
# (a copy of ours is saved next to it as PATH.secure-linux-new).
sl_write_file() {
  local path=$1 mode=${2:-0644} tmp sumf new old last
  tmp=$(mktemp); cat > "$tmp"
  sumf="$SL_STATE/written/$(printf '%s' "$path" | md5sum | cut -d' ' -f1)"
  mkdir -p "$SL_STATE/written" "$(dirname "$path")"
  new=$(md5sum < "$tmp" | cut -d' ' -f1)
  if [ -f "$path" ]; then
    old=$(md5sum < "$path" | cut -d' ' -f1)
    [ "$old" = "$new" ] && { rm -f "$tmp"; echo "$new" > "$sumf"; return 0; }
    last=$(cat "$sumf" 2>/dev/null)
    if [ "$SL_MODE" = repair ] && [ -n "$last" ] && [ "$old" != "$last" ]; then
      echo "keep user-edited $path (ours saved as $path.secure-linux-new)"
      install -m "$mode" "$tmp" "$path.secure-linux-new"; rm -f "$tmp"; return 0
    fi
  fi
  install -m "$mode" "$tmp" "$path"; rm -f "$tmp"; echo "$new" > "$sumf"
  return 0
}
sl_install_file() { # sl_install_file SRC DEST [MODE]   (same rules as sl_write_file)
  sl_write_file "$2" "${3:-0644}" < "$1"
}

# ---------------------------------------------------------------- alerts / events
sl_alert() {       # sl_alert id "Title" "Message" ["Action hint"]   create/refresh an active alert
  mkdir -p "$SL_STATE/alerts.d"
  printf '%s\n%s\n%s\n' "$2" "$3" "${4:-}" > "$SL_STATE/alerts.d/$1"; chmod 644 "$SL_STATE/alerts.d/$1"
}
sl_clear() { rm -f "$SL_STATE/alerts.d/$1"; }   # sl_clear id   the problem is gone
sl_event() {       # sl_event id "Title" "Message"   one-off notice, shown once per user
  mkdir -p "$SL_STATE/events.d"
  printf '%s\n%s\n' "$2" "$3" > "$SL_STATE/events.d/$1"; chmod 644 "$SL_STATE/events.d/$1"
}

# ---------------------------------------------------------------- desktop helpers
sl_user_run() {    # sl_user_run CMD...   run as the main user inside their desktop session (if logged in)
  local u uid; u=$(sl_user); uid=$(id -u "$u" 2>/dev/null) || return 1
  sudo -u "$u" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" XDG_RUNTIME_DIR="/run/user/$uid" "$@"
}
