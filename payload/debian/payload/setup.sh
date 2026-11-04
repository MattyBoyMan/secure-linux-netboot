#!/bin/bash
# The Complete Secure Linux Package (Debian fallback for weak / old PCs): sets up (or repairs) this computer.
# Same commands and contracts as the Fedora setup (linux/setup.sh). Safe to re-run.
#   sudo /usr/local/lib/secure-linux/setup.sh                 first-time setup (user from /etc/secure-linux)
#   sudo /usr/local/lib/secure-linux/setup.sh --repair        re-check everything, only fix what's missing or broken
#   sudo /usr/local/lib/secure-linux/setup.sh --early         (installer only) put helpers and timers in place
#   sudo .../setup.sh --user NAME                             override (a machine not installed from the USB)
# No pipefail on purpose: steps use `cmd | grep -q` checks, which pipefail turns into false failures
set -u
SL_ROOT=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
export SL_ROOT SL_MODE=install
USER_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repair) SL_MODE=repair ;;
    --early) SL_MODE=early ;;
    --profile) [ "${2:-lite}" = lite ] || echo "Note: the Debian setup only has the lite profile; using lite."; shift ;;
    --user) USER_ARG=$2; shift ;;
    full|lite|atomic) ;;                          # old style profile argument: always lite on Debian
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) [ -z "$USER_ARG" ] && id "$1" >/dev/null 2>&1 && USER_ARG=$1 ;;
  esac
  shift
done
# shellcheck source=lib/common.sh
. "$SL_ROOT/lib/common.sh"

if [ -z "$SL_SYSROOT" ] && [ "$(id -u)" -ne 0 ]; then echo "Run with sudo." >&2; exit 1; fi
mkdir -p "$SL_ETC" "$SL_STATE" "$SL_LOGDIR"
echo lite > "$SL_ETC/profile"
[ -f "$SL_ETC/distro" ] || sl_distro > "$SL_ETC/distro"
[ -n "$USER_ARG" ] && echo "$USER_ARG" > "$SL_ETC/user"
[ -f "$SL_ETC/user" ] || sl_build_get SL_USER > "$SL_ETC/user"
SL_PROFILE=lite; SL_USER=$(sl_user); SL_DISTRO=$(sl_distro); export SL_PROFILE SL_USER SL_DISTRO
id "$SL_USER" >/dev/null 2>&1 || { echo "Unknown user '$SL_USER'. Use --user NAME." >&2; exit 1; }

# Failures list: repair keeps the previous one so it can retry those items; install starts fresh
[ "$SL_MODE" = install ] && : > "$SL_FAILS"
[ "$SL_MODE" = repair ] && [ -f "$SL_FAILS" ] && mv "$SL_FAILS" "$SL_FAILS.previous" && : > "$SL_FAILS"
[ -f "$SL_FAILS" ] || : > "$SL_FAILS"
[ "$SL_MODE" = early ] || exec > >(tee -a "$SL_LOGDIR/setup.log") 2>&1

STEPS=("$SL_ROOT"/steps/*.sh)
SL_STEP_TOTAL=${#STEPS[@]}; SL_STEP_N=0; export SL_STEP_TOTAL
echo "=== Secure Linux (Debian) setup: mode=$SL_MODE distro=$SL_DISTRO user=$SL_USER $(date) ==="
for step in "${STEPS[@]}"; do
  SL_STEP_N=$((SL_STEP_N + 1))
  # shellcheck disable=SC1090
  . "$step" || echo "FAILED: step $(basename "$step") returned an error" | tee -a "$SL_FAILS"
done
[ "$SL_MODE" = early ] || echo "=== done: $(date). Failures: $(grep -c . "$SL_FAILS") ==="
exit 0
