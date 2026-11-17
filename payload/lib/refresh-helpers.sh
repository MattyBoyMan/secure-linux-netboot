#!/bin/bash
# refresh-helpers.sh: after a Secure Linux update (or going back), put the new helpers, menu entries, timers and
# password prompts in place, exactly as setup installs them, and switch on any new timers.
#   bash /usr/local/lib/secure-linux/lib/refresh-helpers.sh      (root; run by secure-linux-kit-update-auto)
# It runs only steps/00-early.sh, in repair mode: a file that was changed on this computer is kept (ours is saved
# beside it as .secure-linux-new). setup.sh is never run again here, so setup's own records stay as they are:
# the failure list, the setup journal and the "setup finished" marker are never touched.
# Exit 0 = everything is in place. Exit 1 = something could not be installed (one alert asks for "Repair setup").
# Tests: SL_TEST_SYSROOT puts a prefix in front of every install path (same as 00-early.sh); SL_ETC, SL_STATE and
# SL_LOGDIR redirect setup's folders (same as common.sh).
set -u
SL_ROOT=${SL_ROOT:-/usr/local/lib/secure-linux}
case "${1:-}" in -h|--help) sed -n '2,10p' "$0"; exit 0 ;; esac

# shellcheck source=common.sh
. "$SL_ROOT/lib/common.sh" || { echo "The Secure Linux helpers library is missing; nothing was changed." >&2; exit 1; }
SL_MODE=repair
# A private failure list, set AFTER common.sh so setup's real list ($SL_LOGDIR/failures.log) is never written.
SL_FAILS=$(mktemp "${TMPDIR:-/tmp}/sl-refresh-helpers.XXXXXX") || { echo "No room for a temporary file; nothing was changed." >&2; exit 1; }
trap 'rm -f "$SL_FAILS"' EXIT
# setup's progress line belongs to the welcome screen; this is not a setup run, so only print the step.
sl_step() { echo "=== $* ==="; }

# 00-early.sh is sourced unchanged. It installs bin/, menu entries, autostart entries, systemd units and polkit
# files, runs `systemctl daemon-reload` once (not in the installer chroot) and then enables and starts the units
# listed in files/*/enable-system.list.
# shellcheck source=../steps/00-early.sh
. "$SL_ROOT/steps/00-early.sh"

if [ -s "$SL_FAILS" ]; then
  sed 's/^/  /' "$SL_FAILS" >&2
  sl_alert kit-helpers-refresh "Some new helpers could not be installed" \
    "Some new helpers could not be installed. Choose 'Repair setup' to fix it." \
    "Open 'Secure Linux Status & Fixes' and choose 'Repair setup'."
  exit 1
fi
sl_clear kit-helpers-refresh
echo "The new Secure Linux helpers are in place."
exit 0
