# shellcheck shell=bash
# hw/health/diagnose-auto.sh (owner: U2 diagnose) - the "fix the safe things for me" timer.
# Only runs when the person chose it once:  secure-linux-choice set auto_fix_safe yes   (default: no).
# It applies ONLY fixes whose safe_level is "safe", that need no answer from the person, and never when:
#   - the computer is on battery below 30%,        - an update or install is running (or waiting for a restart),
#   - a drive says it is failing (then it only tells the person to back up),    - the profile is atomic and the fix needs dnf.
# Every fix writes an event "I fixed X for you" with what was done and how to undo it. Needs the plan code and the repair libraries.

SD_AUTO_PKG_ACTIONS=" fix-pkg-repair fix-update-system fix-autoremove fix-old-kernels fix-firmware-reinstall fix-drivers-install fix-gpu-userland fix-sane fix-zram fix-rpmdb fix-kernel-reinstall fix-repos-enable "

sd_auto_guard() {   # prints the plain reason NOT to run now; prints nothing if it is fine to run
  local b st cap
  for b in "$SLH_SYS"/class/power_supply/BAT*; do
    [ -r "$b/status" ] || continue
    st=$(slh_rd "$b/status"); cap=$(slh_rd "$b/capacity")
    if [ "$st" = Discharging ] && [ "${cap:-100}" -lt 30 ] 2>/dev/null; then echo "the computer is on battery at ${cap}%"; return 0; fi
  done
  if declare -F fx_pkg_idle >/dev/null; then
    local why; why=$(fx_pkg_idle 2>&1) || { echo "$why"; return 0; }
  fi
  return 0
}
sd_auto_profile() { local p; p=$(slh_rd "$(sd_path etc/secure-linux/profile)"); printf '%s' "${p:-full}"; }

sd_auto_fix_safe() {
  local log=${SL_AUTO_LOG:-/var/log/secure-linux/auto-fix.log} today k o fixed=0 failed=0 why prof
  printf -v today '%(%Y%m%d)T' -1
  if [ "$(sd_choice auto_fix_safe no)" != yes ]; then echo "Automatic safe fixes are off (auto_fix_safe is not yes). Nothing done."; return 0; fi
  slh_is_root || { echo "Automatic fixes need administrator rights."; return 1; }
  why=$(sd_auto_guard)
  if [ -n "$why" ]; then echo "Not now: $why. I will try again later."; return 0; fi
  prof=$(sd_auto_profile)
  mkdir -p "$(dirname "$log")" 2>/dev/null
  sd_init_env
  SD_MODE=full; SD_AUTOPILOT=1
  sd_health_start
  sd_collect ""
  sd_correlate
  sd_plan_build
  if [ "$P_BACKUP" = 1 ]; then
    echo "A drive looks unhealthy, so I will not change anything automatically. Please back up your files first."
    slh_event "diag-backup-first" "Back up your files" "A drive is reporting problems. Automatic fixes are paused until your files are safe. Open Repair this computer and choose Rescue my files." 2>/dev/null
    return 0
  fi
  for o in $(sd_plan_order); do
    k=$o
    [ "${P_ISS[k]}" -ge 0 ] || continue
    local -a F=(); IFS=$US read -r -a F <<< "${KB[${I_IDX[${P_ISS[k]}]}]}"
    [ "${F[10]}" = safe ] || continue
    [ -z "${I_ASKQ[${P_ISS[k]}]:-}" ] || continue
    case "${P_ACT[k]}" in fix-*) ;; *) continue ;; esac
    if [ "$prof" = atomic ]; then case "$SD_AUTO_PKG_ACTIONS" in *" ${P_ACT[k]} "*) continue ;; esac; fi
    why=$(sd_auto_guard); [ -n "$why" ] && { echo "Stopping: $why."; break; }
    local -a av=(); [ -n "${P_ARGS[k]}" ] && IFS=$US read -r -a av <<< "${P_ARGS[k]}"
    local out title; title=$(sd_tpl "${F[7]}")
    RP_DRY=0; export RP_FIX_PREAPPROVED=1
    if out=$(rp_fix_run "${P_ACT[k]}" ${av[@]+"${av[@]}"} 2>&1); then
      printf '%s\n%s\n' "== ${P_ACT[k]} ==" "$out" >> "$log" 2>/dev/null
      if printf '%s' "$out" | grep -q '^FIXED:'; then
        fixed=$((fixed + 1))
        slh_event "diag-fixed-${P_ID[k]}-$today" "I fixed something for you: $title" "$(sd_tpl "${F[14]}") If you want to undo it: ${F[16]} Details are in $log." 2>/dev/null
        echo "Fixed: $title"
      fi
    else
      failed=$((failed + 1)); printf '%s\n%s\n' "== ${P_ACT[k]} (did not work) ==" "$out" >> "$log" 2>/dev/null
      echo "Could not fix: $title"
    fi
  done
  echo "Automatic safe fixes: $fixed fixed, $failed could not be fixed."
  return 0
}
