#!/bin/bash
# The Complete Secure Linux Package (Debian fallback for weak / old PCs): sets up (or repairs) this computer.
# Same commands and contracts as the Fedora setup (linux/setup.sh). Safe to re-run.
#   sudo /usr/local/lib/secure-linux/setup.sh                 first-time setup (user from /etc/secure-linux)
#   sudo /usr/local/lib/secure-linux/setup.sh --repair        re-check everything, only fix what's missing or broken
#   sudo /usr/local/lib/secure-linux/setup.sh --early         (installer only) put helpers and timers in place
#   sudo .../setup.sh --user NAME                             override (a machine not installed from the USB)
#   sudo .../setup.sh --resume | --fresh                     explicit interrupted-setup decision
# No pipefail on purpose: steps use `cmd | grep -q` checks, which pipefail turns into false failures
set -u
SL_ROOT=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
export SL_ROOT SL_MODE=install
USER_ARG="" RECOVERY_REQUEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repair) SL_MODE=repair ;;
    --early) SL_MODE=early ;;
    --resume) RECOVERY_REQUEST=resume ;;
    --fresh) RECOVERY_REQUEST=fresh ;;
    --profile) [ "${2:-lite}" = lite ] || echo "Note: the Debian setup only has the lite profile; using lite."; shift ;;
    --user) USER_ARG=${2:-}; shift ;;
    full|lite|atomic) ;;                          # old style profile argument: always lite on Debian
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) [ -z "$USER_ARG" ] && id "$1" >/dev/null 2>&1 && USER_ARG=$1 ;;
  esac
  shift
done
# shellcheck source=lib/common.sh
. "$SL_ROOT/lib/common.sh"
# shellcheck source=lib/recovery.sh
. "$SL_ROOT/lib/recovery.sh"
SL_FIRSTBOOT_DONE=${SL_FIRSTBOOT_DONE:-$R/var/lib/secure-linux/firstboot.done}

if [ -z "$SL_SYSROOT" ] && [ "$(id -u)" -ne 0 ]; then echo "Run with sudo." >&2; exit 1; fi
mkdir -p "$SL_ETC" "$SL_STATE" "$SL_LOGDIR"
echo lite > "$SL_ETC/profile"
[ -f "$SL_ETC/distro" ] || sl_distro > "$SL_ETC/distro"
[ -n "$USER_ARG" ] && echo "$USER_ARG" > "$SL_ETC/user"
[ -f "$SL_ETC/user" ] || sl_build_get SL_USER > "$SL_ETC/user"
SL_PROFILE=lite; SL_USER=$(sl_user); SL_DISTRO=$(sl_distro); export SL_PROFILE SL_USER SL_DISTRO
id "$SL_USER" >/dev/null 2>&1 || { echo "Unknown user '$SL_USER'. Use --user NAME." >&2; exit 1; }

# EOF is not consent. In particular, the first-start service cannot silently
# resume an interrupted setup: it leaves a retryable journal and exits 75.
if [ "$SL_MODE" != early ]; then
  rm -f "$SL_FIRSTBOOT_DONE"
  if [ "$RECOVERY_REQUEST" = fresh ]; then
    sl_recovery_reset
    sl_recovery_new "$SL_MODE" || { echo "Could not start a durable setup journal." >&2; exit 1; }
  elif [ -e "$SL_RECOVERY_JOURNAL" ]; then
    if [ -z "$RECOVERY_REQUEST" ]; then
      echo "A previous Secure Linux setup was interrupted."
      echo "Type R to Resume with checkpoint checks, or F for a Fresh setup restart. There is no timed default."
      while true; do
        printf 'Resume or Fresh start? [R/F] '
        IFS= read -r RECOVERY_DECISION || {
          echo; echo "No choice was made. Run setup.sh --resume or setup.sh --fresh when ready." >&2
          exit 75
        }
        case "$RECOVERY_DECISION" in
          [Rr]|Resume|resume) RECOVERY_REQUEST=resume; break ;;
          [Ff]|Fresh|fresh) RECOVERY_REQUEST=fresh; break ;;
        esac
      done
    fi
    if [ "$RECOVERY_REQUEST" = resume ]; then
      sl_recovery_load || {
        echo "$SL_RECOVERY_REASON" >&2
        echo "Resume is unsafe with this journal. Choose Fresh start (setup.sh --fresh)." >&2
        exit 2
      }
    else
      sl_recovery_reset
      sl_recovery_new "$SL_MODE" || { echo "Could not start a durable setup journal." >&2; exit 1; }
    fi
  else
    sl_recovery_new "$SL_MODE" || { echo "Could not start a durable setup journal." >&2; exit 1; }
  fi
fi

if [ "$SL_MODE" = repair ] && [ -f "$SL_FAILS" ]; then
  mv "$SL_FAILS" "$SL_FAILS.previous"
fi
: > "$SL_FAILS"
[ "$SL_MODE" = early ] || exec > >(tee -a "$SL_LOGDIR/setup.log") 2>&1

STEPS=("$SL_ROOT"/steps/*.sh)
SL_STEP_TOTAL=${#STEPS[@]}; SL_STEP_N=0; export SL_STEP_TOTAL
echo "=== Secure Linux (Debian) setup: mode=$SL_MODE distro=$SL_DISTRO user=$SL_USER $(date) ==="
for step in "${STEPS[@]}"; do
  SL_STEP_N=$((SL_STEP_N + 1))
  step_name=$(basename "$step")
  if [ "$SL_MODE" != early ] && sl_recovery_should_skip "$step_name" "$step"; then
    echo "SKIP $step_name: script and artifact checks passed."
    continue
  elif [ "$SL_MODE" != early ]; then
    echo "RESTART $step_name: $SL_RECOVERY_REASON"
    sl_recovery_stage_running "$step_name" "$step" || {
      echo "FAILED: could not journal $step_name" | tee -a "$SL_FAILS" >&2
      break
    }
  fi
  SL_STAGE_SKIPPABLE=0
  before_failures=$(awk 'NF {n++} END {print n+0}' "$SL_FAILS")
  # shellcheck disable=SC1090
  if . "$step"; then step_rc=0; else step_rc=$?; fi
  after_failures=$(awk 'NF {n++} END {print n+0}' "$SL_FAILS")
  if [ "$step_rc" -ne 0 ] && [ "$after_failures" -eq "$before_failures" ]; then
    echo "FAILED: step $step_name returned an error" | tee -a "$SL_FAILS"
  fi
  if [ "$SL_MODE" != early ] && [ -n "$SL_RECOVERY_CURRENT_STAGE" ]; then
    if [ "$step_rc" -eq 0 ] && [ "$after_failures" -eq "$before_failures" ]; then
      policy=restart-only; [ "$SL_STAGE_SKIPPABLE" = 1 ] && policy=idempotent
      sl_recovery_stage_completed "$step_name" "$policy" || {
        echo "FAILED: could not checkpoint $step_name" | tee -a "$SL_FAILS" >&2
        break
      }
    else
      sl_recovery_stage_failed "$step_name" || {
        echo "FAILED: could not preserve retry state for $step_name" | tee -a "$SL_FAILS" >&2
        break
      }
    fi
  fi
done

if [ -s "$SL_FAILS" ]; then
  rm -f "$SL_FIRSTBOOT_DONE"
  [ "$SL_MODE" = early ] || sl_recovery_mark_run_failed
  [ "$SL_MODE" = early ] || printf 'failed|%s/%s|Setup incomplete; choose Resume or Fresh start on the next launch\n' "$SL_STEP_N" "$SL_STEP_TOTAL" | sl_recovery_atomic_write "$SL_STATE/progress" 0644
  echo "=== setup incomplete: $(date). Failures: $(awk 'NF {n++} END {print n+0}' "$SL_FAILS") ==="
  exit 1
fi

if [ "$SL_MODE" != early ]; then
  printf 'complete\n' | sl_recovery_atomic_write "$SL_FIRSTBOOT_DONE" 0644 || {
    echo "Setup succeeded, but the completion marker could not be saved; it will be retried." >&2
    sl_recovery_mark_run_failed
    exit 1
  }
  printf 'done|done|Setup finished\n' | sl_recovery_atomic_write "$SL_STATE/progress" 0644
  sl_recovery_finish
  echo "=== done: $(date). Failures: 0 ==="
fi
exit 0
