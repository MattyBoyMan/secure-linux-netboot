#!/bin/bash
# Secure Linux (Debian fallback): shared helpers for setup steps and helper commands. Source it; don't run it.
# Same function names and state paths as the Fedora linux/lib/common.sh, so helpers written for Fedora that
# only use these (secure-linux-notify, -status-gui, -terminal) work here unchanged. Package helpers use apt.
# SL_SYSROOT (tests only): prefix put in front of every system path. Always empty on a real machine.
# Safe to source more than once.
[ -n "${SL_COMMON_LOADED:-}" ] && return 0
SL_COMMON_LOADED=1

SL_SYSROOT=${SL_SYSROOT:-}
R=$SL_SYSROOT
SL_ROOT=${SL_ROOT:-/usr/local/lib/secure-linux}
SL_ETC=$R/etc/secure-linux
SL_STATE=$R/var/lib/secure-linux
SL_LOGDIR=$R/var/log/secure-linux
SL_FAILS=$SL_LOGDIR/failures.log
SL_MODE=${SL_MODE:-install}
SL_GUIDE=/usr/share/secure-linux/START-HERE.html

# ---------------------------------------------------------------- identity / settings
sl_build_get() {   # sl_build_get KEY [default]   (from build.conf written by the USB builder)
  local v=""
  [ -f "$SL_ROOT/build.conf" ] && v=$(sed -n "s/^$1=//p" "$SL_ROOT/build.conf" | tail -1)
  printf '%s' "${v:-${2:-}}"
}
sl_profile() { cat "$SL_ETC/profile" 2>/dev/null || echo lite; }      # Debian is always the "lite" profile
sl_user()    { cat "$SL_ETC/user" 2>/dev/null || sl_build_get SL_USER; }
sl_user_home() { getent passwd "$(sl_user)" | cut -d: -f6; }
sl_arch()    { dpkg --print-architecture 2>/dev/null || echo amd64; }
sl_distro()  {   # debian-lite (64-bit, Debian 13) or debian-i386 (32-bit, Debian 12)
  local d; d=$(cat "$SL_ETC/distro" 2>/dev/null)
  case "$d" in debian-lite|debian-i386) echo "$d" ;; *) [ "$(sl_arch)" = i386 ] && echo debian-i386 || echo debian-lite ;; esac
}
sl_debian_major() { cut -d. -f1 "$R/etc/debian_version" 2>/dev/null | tr -cd '0-9'; }
sl_desktop() {   # xfce | lxqt | icewm   (chosen by the installer from the memory size; saved in choices)
  local d; d=$(sl_choice_get desktop)
  case "$d" in xfce|lxqt|icewm) echo "$d"; return ;; esac
  if [ -x "$R/usr/bin/xfce4-session" ]; then echo xfce; elif [ -x "$R/usr/bin/startlxqt" ]; then echo lxqt; else echo icewm; fi
}
sl_ram_mb() { awk '/MemTotal/ { printf "%d", $2 / 1024 }' "${SL_PROC:-/proc}/meminfo" 2>/dev/null; }

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
  echo; echo "=== [${SL_STEP_N:-?}/${SL_STEP_TOTAL:-?}] $* ==="
  mkdir -p "$SL_STATE"
  printf '%s|%s|%s\n' "${SL_STEP_N:-?}" "${SL_STEP_TOTAL:-?}" "$*" > "$SL_STATE/progress"
}
sl_is_atomic() { return 1; }
sl_online() { curl -fsS --max-time 10 -o /dev/null https://deb.debian.org/debian/ 2>/dev/null; }

# ---------------------------------------------------------------- installing (idempotent)
export DEBIAN_FRONTEND=noninteractive
SL_APT_UPDATED=""
sl_pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
sl_apt_update() {  # once per run, and only when something is about to be installed
  [ -n "$SL_APT_UPDATED" ] && return 0
  SL_APT_UPDATED=1
  try apt-get update -q
}
_sl_apt_get() { apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"; }
# sl_pkg_install [--no-recommends] pkg...   installs only missing packages; one unknown or broken package name
# doesn't block the rest (they are retried one by one and each failure is recorded)
sl_pkg_install() {
  local rec=() missing=() p
  [ "${1:-}" = --no-recommends ] && { rec=(--no-install-recommends); shift; }
  for p in "$@"; do sl_pkg_installed "$p" || missing+=("$p"); done
  [ ${#missing[@]} -eq 0 ] && return 0
  sl_apt_update
  echo ">> apt-get install ${rec[*]} ${missing[*]}"
  _sl_apt_get install "${rec[@]}" "${missing[@]}" && return 0
  local rc=0
  for p in "${missing[@]}"; do
    sl_pkg_installed "$p" && continue
    _sl_apt_get install "${rec[@]}" "$p" || { echo "FAILED: package $p could not be installed" | tee -a "$SL_FAILS" >&2; rc=1; }
  done
  return $rc
}
sl_dnf_install() { sl_pkg_install "$@"; }      # name used by helpers shared with the Fedora setup
sl_flatpak_ok() { [ "$(sl_arch)" = amd64 ] && command -v flatpak >/dev/null 2>&1; }   # Flathub has no i386 apps
sl_flatpak_install() { # sl_flatpak_install app-id...   system-wide from Flathub, only missing ones
  local id rc=0
  sl_flatpak_ok || { echo "skip (no Flatpak on this computer): $*"; return 0; }
  for id in "$@"; do
    flatpak info --system "$id" >/dev/null 2>&1 && continue
    try flatpak install -y --noninteractive --system flathub "$id" || rc=1
  done
  return $rc
}
sl_enable() {      # sl_enable unit...   enable (and start, unless in the installer chroot)
  local u
  for u in "$@"; do
    if [ "$SL_MODE" = early ]; then
      systemctl is-enabled -q "$u" 2>/dev/null || try systemctl enable "$u"
    else
      { systemctl is-enabled -q "$u" 2>/dev/null && systemctl is-active -q "$u" 2>/dev/null; } || try systemctl enable --now "$u"
    fi
  done
}

# ---------------------------------------------------------------- files (respect user edits)
# sl_write_file PATH [MODE] < content      (PATH already includes $R when it is a system path)
# Writes content if it differs. In repair mode, a file the user edited since we last wrote it is left alone
# (a copy of ours is saved next to it as PATH.secure-linux-new).
sl_write_file() {
  local path=$1 mode=${2:-0644} tmp sumf new old last
  tmp=$(mktemp); cat > "$tmp"
  sumf="$SL_STATE/written/$(printf '%s' "${path#"$R"}" | md5sum | cut -d' ' -f1)"
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
  echo "write $path"
  install -m "$mode" "$tmp" "$path"; rm -f "$tmp"; echo "$new" > "$sumf"
  SL_CHANGED=1
  return 0
}
sl_install_file() { # sl_install_file SRC DEST [MODE]   (same rules as sl_write_file)
  sl_write_file "$2" "${3:-0644}" < "$1"
}

# ---------------------------------------------------------------- alerts / events (same files as Fedora)
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

# ---------------------------------------------------------------- support dates (honest end-of-life)
# Debian 12 "bookworm": regular security support ended 2026-06-10; Debian LTS runs 2026-06-11 to 2028-06-30, listed for
# i386 and amd64 (https://wiki.debian.org/LTS, schedule last updated 2026-08-31, checked 2026-11-03).
# Debian 13 "trixie": regular security support to about 2028-08-09, then LTS to 2030-06-30 (same page).
sl_support_end() { case "$(sl_debian_major)" in 12) echo 2028-06-30 ;; 13) echo 2030-06-30 ;; *) echo "" ;; esac; }
sl_is_i386() { [ "$(sl_arch)" = i386 ]; }

# ---------------------------------------------------------------- offline fix-packs (from the USB stick)
# sl_offline_fw_dir -> the offline firmware pool for this Debian release (copied from the stick by late.sh /
# 03-offline-packs.sh), or nothing. The .deb files come from Debian's own non-free firmware zip (SHA-512 checked
# by the USB builder).
sl_offline_fw_dir() {
  local d=$R/var/cache/secure-linux/offline/debian-$(sl_debian_major)-firmware
  [ -d "$d" ] || return 1
  find "$d" -maxdepth 3 -name 'firmware-*.deb' 2>/dev/null | grep -q . || return 1
  printf '%s' "$d"
}
# sl_offline_fw_install PKG...  offline fallback: install firmware .debs from the stick's pool with dpkg -i.
# Prints a plain line per package; returns 0 when at least one was installed.
sl_offline_fw_install() {
  local dir pkg f rc=1
  dir=$(sl_offline_fw_dir) || return 1
  for pkg in "$@"; do
    case "$pkg" in firmware-*) ;; *) continue ;; esac
    f=$(find "$dir" -maxdepth 3 -name "${pkg}_*.deb" 2>/dev/null | sort | tail -n1)
    [ -n "$f" ] || { echo "Not in the USB stick's offline pool: $pkg (needs the internet; retried at the next repair)"; continue; }
    if dpkg -i "$f" >/dev/null 2>&1 && sl_pkg_installed "$pkg"; then
      echo "Installed from the USB stick's offline pool: $pkg"
      rc=0
    else
      echo "Could not install from the offline pool: $pkg"
    fi
  done
  return $rc
}
# Seed ClamAV's virus list from the stick's offline pack when no database was ever downloaded, so the first scan
# works before (or without) an online update. Silent no-op when there is nothing to do.
sl_seed_clamav_db() {
  local src=$R/var/cache/secure-linux/offline/clamav dst=$R/var/lib/clamav
  [ -f "$src/main.cvd" ] || return 0
  [ ! -e "$dst/main.cvd" ] && [ ! -e "$dst/main.cld" ] || return 0
  mkdir -p "$dst"
  cp "$src"/*.cvd "$dst/" 2>/dev/null || return 1
  id clamav >/dev/null 2>&1 && chown -R clamav:clamav "$dst" 2>/dev/null
  echo "Virus list copied from the USB stick's offline pack (it updates itself once you are online)."
  return 0
}

# ---------------------------------------------------------------- firewall helper (ufw)
# sl_ufw_allow_from SOURCE PORT/PROTO   allow incoming from one address range only (skips if the rule exists)
sl_ufw_allow_from() {
  local src=$1 pp=$2 port proto
  port=${pp%/*}; proto=${pp#*/}
  command -v ufw >/dev/null 2>&1 || return 0
  ufw show added 2>/dev/null | grep -qF "ufw allow from $src to any port $port proto $proto" && return 0
  try ufw allow from "$src" to any port "$port" proto "$proto"
}
