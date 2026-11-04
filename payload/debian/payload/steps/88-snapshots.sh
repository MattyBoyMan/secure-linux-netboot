#!/bin/bash
# 88-snapshots.sh (Debian) - automatic system snapshots before updates (LVM snapshots of the root volume), see bin/secure-linux-snapshot.
# This step runs near the END of setup, on purpose: the apt hook that takes a snapshot before packages change is installed last,
# so the setup's own installs (gigabytes of apps) don't fill a snapshot.
# Choice: snapshots (yes|no, default yes). Sourced by setup.sh: never `exit`.
[ "$SL_MODE" = early ] && return 0

sl_step "System snapshots before updates"
sl_pkg_installed lvm2 || sl_pkg_install --no-recommends lvm2
if [ "$(sl_choice_get snapshots yes)" = no ]; then
  rm -f "$R/etc/apt/apt.conf.d/50secure-linux-snapshot"
  echo "System snapshots are switched off by choice."
else
  sl_write_file "$R/etc/apt/apt.conf.d/50secure-linux-snapshot" <<'EOT'
// Secure Linux: take a system snapshot (LVM) before packages change. It can never stop an update: any problem is ignored.
// At most one per 2 days, 2 kept, 14 days at most. See: secure-linux-snapshot --help
DPkg::Pre-Invoke { "if [ -x /usr/local/bin/secure-linux-snapshot ]; then /usr/local/bin/secure-linux-snapshot create --auto --quiet || true; fi"; };
EOT
  case "$("$SL_ROOT/bin/secure-linux-snapshot" status 2>/dev/null | cut -d'|' -f1)" in
    unavailable) echo "Note: snapshots are not available on this computer: $("$SL_ROOT/bin/secure-linux-snapshot" status 2>/dev/null | cut -d'|' -f2)." ;;
  esac
fi
return 0
