# shellcheck shell=bash
# 80-nomad: Project NOMAD (offline library, maps, private AI) ready on every computer that can run it.
# Used by the full and the lite Fedora setup (the same steps folder; the atomic desktop too).
# Debian twin: debian/setup/steps/80-nomad.sh (same tool, same numbers).
#
# What "can run it" means - the numbers and why (upstream Project NOMAD README "Device Requirements"):
#   processor  x86_64 only                  the pinned NOMAD apps are built for normal PC processors
#   memory     at least 3584 MB             upstream minimum 4 GB; a "4 GB" computer reports about 3.7-3.9 GB
#              7168 MB or more: AI on       the starter AI model (llama3.2 3B, about 2 GB) needs about its size in memory
#   machine    not a virtual machine        upstream does not support virtual machines for the full NOMAD
#   cores      at least 2                   upstream minimum: a dual-core processor
#   free disk  at least 10 GB               upstream: "plan for 10 GB to install comfortably"
# Memory, processor and virtual machine are checked by start-nomad.sh (MIN_RAM_MB, AI_RAM_MB), cores and disk by
# secure-linux-nomad (MIN_CPUS, MIN_FREE_GB): one place for each number, tests/nomad checks they match this list.
#
# Can run it: the app menu gets "NOMAD Offline Library". With the Secure Linux drive plugged in it starts from the
# drive's SecureLinux-NOMAD folder with NO internet; without the drive it downloads the same pinned apps once.
# Podman (and nftables for the privacy rule) are added when missing and the computer is online.
# Cannot run it: one plain sentence says why; NOMAD stays available in the App Library (library only on small PCs).
# Nothing here opens a port: NOMAD only ever starts when the person starts it, private to this computer by default.
# This step never fails the setup: no drive, no internet or a too-small computer are normal, not errors.
[ "$SL_MODE" = early ] && return 0

_nomad80() {
  local lib="$SL_ROOT/lib/nomad" root=${SL_TEST_SYSROOT:-}
  if [ ! -f "$lib/secure-linux-nomad" ] || [ ! -f "$lib/start-nomad.sh" ]; then
    echo "NOMAD: its files are not in this copy of Secure Linux; skipped (nothing else is affected)."
    return 0
  fi
  sl_step "Getting NOMAD ready (offline library, maps and private AI)"
  # The command in the menu is a two-line starter; the real tool stays in $lib, so updates of the kit reach it.
  install -d -m 0755 "$root/usr/local/bin"
  printf '#!/bin/bash\n# Secure Linux: NOMAD offline library. The tool itself: %s/secure-linux-nomad\nexec bash %s/secure-linux-nomad "$@"\n' \
    "$lib" "$lib" | sl_write_file "$root/usr/local/bin/secure-linux-nomad" 0755
  NOMAD_PKG=dnf NOMAD_STATE_DIR="$SL_STATE" NOMAD_APPS_DIR="$root/usr/local/share/applications" \
    bash "$lib/secure-linux-nomad" setup --auto \
    || echo "NOMAD: the set-up check did not finish; it stays available in the App Library."
  return 0
}
_nomad80
unset -f _nomad80
return 0
