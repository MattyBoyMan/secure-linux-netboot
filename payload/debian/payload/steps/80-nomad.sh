# shellcheck shell=bash
# 80-nomad (Debian): Project NOMAD (offline library, maps, private AI) ready when the computer can run it.
# Twin of linux/steps/80-nomad.sh: the same tool (lib/nomad, identical files) and the same numbers:
#   processor x86_64 (amd64) | memory at least 3584 MB (7168 MB turns the AI on) | not a virtual machine
#   at least 2 processor cores | at least 10 GB free disk   (why: see linux/steps/80-nomad.sh)
# The Debian entries are meant for small or 32-bit computers, so most of them get the plain "not suited" sentence
# and keep NOMAD in the App Library (library only). A capable one gets "NOMAD Offline Library" in the app menu;
# it starts from the drive's SecureLinux-NOMAD folder with no internet, or downloads the same pinned apps once.
# Docker (step 79) or Podman is used; Podman and nftables are added when missing and online.
# Nothing here opens a port, and this step never fails the setup.
[ "$SL_MODE" = early ] && return 0

_nomad80() {
  local lib="$SL_ROOT/lib/nomad"
  if [ ! -f "$lib/secure-linux-nomad" ] || [ ! -f "$lib/start-nomad.sh" ]; then
    echo "NOMAD: its files are not in this copy of Secure Linux; skipped (nothing else is affected)."
    return 0
  fi
  sl_step "Getting NOMAD ready (offline library, maps and private AI)"
  install -d -m 0755 "$R/usr/local/bin"
  printf '#!/bin/bash\n# Secure Linux: NOMAD offline library. The tool itself: %s/secure-linux-nomad\nexec bash %s/secure-linux-nomad "$@"\n' \
    "$lib" "$lib" | sl_write_file "$R/usr/local/bin/secure-linux-nomad" 0755
  NOMAD_PKG=apt NOMAD_STATE_DIR="$SL_STATE" NOMAD_APPS_DIR="$R/usr/local/share/applications" \
    bash "$lib/secure-linux-nomad" setup --auto \
    || echo "NOMAD: the set-up check did not finish; it stays available in the App Library."
  return 0
}
_nomad80
unset -f _nomad80
return 0
