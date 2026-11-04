# shellcheck shell=bash
# hw/health/diagnose-plan.sh (owner: U2 diagnose) - turns the problems found into ONE ordered plan the person approves once.
# Order: back up files first, then disk repair, then get online/prepare software, then start-up repair, then software and
# drivers, then settings, then tidy-up. Needs diagnose-lib.sh.

sd_phase() {   # sd_phase ACTION -> number (the order of the plan)
  case "$1" in
    data|fix-backup-files) echo 0 ;;
    fs|fix-btrfs-scrub|fix-btrfs-balance|fix-trim) echo 10 ;;
    fix-nm-start|fix-rfkill|fix-vpn-killswitch-off|fix-wifi-country|fix-dns-flush|fix-mtu|fix-ipv6-off|fix-time-sync|fix-rpmdb|fix-repos-enable|fix-faillock-reset|fix-sudo-repair|fix-home-perms|fix-bluetooth-start) echo 20 ;;
    boot|fix-efi-entry|fix-efi-order|fix-grub-cfg|fix-grub-windows|fix-fstab-nofail|fix-initramfs|fix-kernel-reinstall|kernel|gpu|fix-mok-enroll|fix-nomodeset-remove|fix-plymouth-off|fix-rtc-local|fix-nvidia-rebuild|fix-wait-online) echo 30 ;;
    packages|fix-pkg-repair|fix-update-system|fix-firmware-reinstall|fix-gpu-userland|fix-drivers-install|fix-flatpak-repair|fix-fwupd-update|fix-sane|fix-recovery-key) echo 40 ;;
    fix-free-space|fix-old-kernels|fix-snapshots-trim|fix-autoremove) echo 60 ;;
    *) echo 50 ;;
  esac
}
sd_phase_name() {
  case "$1" in
    0) echo "Back up your files" ;; 10) echo "Check and repair the disk" ;; 20) echo "Get online and prepare the software" ;;
    30) echo "Repair the start-up" ;; 40) echo "Software and drivers" ;; 50) echo "Settings and services" ;; *) echo "Tidy up" ;;
  esac
}
sd_minutes() {   # "~5 min" -> 5 ; "~1 hour" -> 60
  case "$1" in
    *hour*) echo 60 ;;
    *) local n; n=${1//[^0-9]/}; echo "${n:-1}" ;;
  esac
}

declare -a P_ID=() P_ACT=() P_ARGS=() P_PH=() P_IMP=() P_ISS=() P_BLOCKED=()
P_N=0; P_BACKUP=0
declare -a P_SKIP=()
sd_plan_build() {   # fills P_*; uses the kept issues (call after sd_collect + sd_correlate)
  local i F act args key seen=" " ph
  P_N=0; P_ID=(); P_ACT=(); P_ARGS=(); P_PH=(); P_IMP=(); P_ISS=(); P_BLOCKED=(); P_SKIP=(); P_BACKUP=0
  local needb=0
  for i in $(sd_sorted); do
    local -a F=(); IFS=$US read -r -a F <<< "${KB[${I_IDX[i]}]}"
    case "${F[20]}" in *hwfail*|*backup*) needb=1 ;; esac
  done
  if [ "$needb" = 1 ]; then
    P_ID[P_N]=backup-first; P_ACT[P_N]=fix-backup-files; P_ARGS[P_N]=""; P_PH[P_N]=0; P_IMP[P_N]=1000; P_ISS[P_N]=-1; P_BLOCKED[P_N]=0; P_N=$((P_N + 1)); P_BACKUP=1
  fi
  for i in $(sd_sorted); do
    local -a F=(); IFS=$US read -r -a F <<< "${KB[${I_IDX[i]}]}"
    act=${F[12]}
    if [ "${F[11]}" != yes ] || [ -z "$act" ] || [ "$act" = "-" ]; then P_SKIP+=("$i"); continue; fi
    args=${I_ARGS[i]}; [ -n "$args" ] || { args=${F[13]// /$US}; [ "$args" = "-" ] && args=""; }
    key="$act|$args"
    case "$seen" in *" $key "*) continue ;; esac
    seen="$seen$key "
    ph=$(sd_phase "$act")
    P_ID[P_N]=${I_ID[i]}; P_ACT[P_N]=$act; P_ARGS[P_N]=$args; P_PH[P_N]=$ph; P_IMP[P_N]=${I_IMP[i]}; P_ISS[P_N]=$i
    P_BLOCKED[P_N]=0; [ "$P_BACKUP" = 1 ] && [ "$ph" -gt 0 ] && P_BLOCKED[P_N]=1
    P_N=$((P_N + 1))
  done
}
sd_plan_order() {   # prints step indexes in plan order
  local k
  for ((k = 0; k < P_N; k++)); do printf '%05d|%05d|%s|%s\n' "${P_PH[k]}" $((99999 - ${P_IMP[k]})) "${P_ID[k]}" "$k"; done | sort | cut -d'|' -f4
}
sd_step_risk() { case "$1" in risky) echo 3 ;; asks) echo 2 ;; *) echo 1 ;; esac; }
sd_plan_stats() {   # sets PL_MIN PL_RISK PL_REBOOT PL_NASK
  local k F; PL_MIN=0; PL_RISK=1; PL_REBOOT=false; PL_NASK=0
  for ((k = 0; k < P_N; k++)); do
    if [ "${P_ISS[k]}" -lt 0 ]; then PL_MIN=$((PL_MIN + 10)); [ -n "$(sd_backup_dest_json | grep question)" ] && PL_NASK=$((PL_NASK + 1)); continue; fi
    local -a F=(); IFS=$US read -r -a F <<< "${KB[${I_IDX[${P_ISS[k]}]}]}"
    PL_MIN=$((PL_MIN + $(sd_minutes "${F[17]}")))
    local r; r=$(sd_step_risk "${F[10]}"); [ "$r" -gt "$PL_RISK" ] && PL_RISK=$r
    [[ ${F[20]} == *reboot* ]] && PL_REBOOT=true
    [ -n "${I_ASKQ[${P_ISS[k]}]:-}" ] && PL_NASK=$((PL_NASK + 1))
  done
}
sd_plan_json() {
  local k first=1 s F dep prev_ph=-1 last_ph=-1 n=0
  sd_plan_stats
  local risk=safe; [ "$PL_RISK" = 2 ] && risk=asks; [ "$PL_RISK" = 3 ] && risk=risky
  printf '{\n  "mode": "%s",\n  "steps": [\n' "$([ "$SD_AUTOPILOT" = 1 ] && echo autopilot || echo plan)"
  local -a order=(); local o
  for o in $(sd_plan_order); do order+=("$o"); done
  local -A phids=()
  for k in "${order[@]:-}"; do
    [ -n "$k" ] || continue
    n=$((n + 1))
    [ "$first" = 1 ] || printf ',\n'; first=0
    ph=${P_PH[k]}
    dep=""
    if [ "$ph" != "$last_ph" ]; then prev_ph=$last_ph; last_ph=$ph; fi
    [ "$prev_ph" -ge 0 ] && dep=${phids[$prev_ph]:-}
    phids[$ph]="${phids[$ph]:+${phids[$ph]}$US}${P_ID[k]}"
    local title summary safe backup tm ask="null" reb=false conf=high
    if [ "${P_ISS[k]}" -lt 0 ]; then
      title="Copy your files to another drive"; summary="Copy your documents, photos and settings to another drive. Nothing is changed on the drive that is failing."; safe=safe; backup="This IS the backup."; tm="~10 min"
      ask=$(sd_backup_dest_json)
    else
      local -a F=(); sd_fields "${P_ISS[k]}"
      title=$(sd_tpl "${F[7]}"); summary=$(sd_tpl "${F[14]}"); safe=${F[10]}; backup=$(sd_tpl "${F[15]}"); tm=${F[17]}
      ask=$(sd_needs_input_json "${P_ISS[k]}"); conf=${I_CONF[${P_ISS[k]}]}; [[ ${F[20]} == *reboot* ]] && reb=true
    fi
    printf '    {"order":%d,"phase":%d,"phase_name":"%s","id":"%s","title":"%s","fix_action":"%s","fix_args":%s,"summary":"%s","safe_level":"%s","backup_first":"%s","time_estimate":"%s","needs_input":%s,"confidence":"%s","depends_on":%s,"blocked_until_backup":%s,"reboot_needed":%s}' \
      "$n" "$ph" "$(sd_phase_name "$ph")" "$(sd_je "${P_ID[k]}")" "$(sd_je "$title")" "${P_ACT[k]}" "$(sd_json_arr "${P_ARGS[k]}")" "$(sd_je "$summary")" "$safe" "$(sd_je "$backup")" "$(sd_je "$tm")" "$ask" "$conf" "$(sd_json_arr "$dep")" "$([ "${P_BLOCKED[k]}" = 1 ] && echo true || echo false)" "$reb"
  done
  printf '\n  ],\n  "needs_input": ['
  first=1
  for k in "${order[@]:-}"; do
    [ -n "$k" ] || continue
    local a
    if [ "${P_ISS[k]}" -lt 0 ]; then a=$(sd_backup_dest_json); else a=$(sd_needs_input_json "${P_ISS[k]}"); fi
    [ "$a" = null ] && continue
    [ "$first" = 1 ] || printf ', '; first=0
    printf '{"step":"%s",%s' "$(sd_je "${P_ID[k]}")" "${a#\{}"
  done
  printf '],\n  "manual": ['
  first=1
  for i in "${P_SKIP[@]:-}"; do
    [ -n "$i" ] || continue
    local -a F=(); sd_fields "$i"
    [ "$first" = 1 ] || printf ', '; first=0
    printf '{"id":"%s","title":"%s","do_this_yourself":"%s"}' "$(sd_je "${I_ID[i]}")" "$(sd_je "$(sd_tpl "${F[7]}")")" "$(sd_je "$(sd_tpl "${F[19]}")")"
  done
  printf '],\n  "approval": {"steps": %d, "total_time": "~%d min", "highest_risk": "%s", "backup_included": %s, "restart_needed": %s, "questions": %d,\n    "summary": "%s"}\n}\n' \
    "$P_N" "$PL_MIN" "$risk" "$([ "$P_BACKUP" = 1 ] && echo true || echo false)" "$PL_REBOOT" "$PL_NASK" "$(sd_je "$(sd_plan_summary_text)")"
}
sd_plan_summary_text() {
  if [ "$P_N" = 0 ]; then printf 'There is nothing I need to fix.'; return; fi
  printf 'I will do %d step(s)%s, about %d minutes in total.' "$P_N" "$([ "$P_BACKUP" = 1 ] && echo ', starting by copying your files to a safe place')" "$PL_MIN"
  [ "$PL_REBOOT" = true ] && printf ' A restart is needed at the end.'
  [ "$PL_NASK" -gt 0 ] && printf ' I need %d quick answer(s) first.' "$PL_NASK"
}
sd_plan_text() {
  local k n=0 o ph last=-1
  sd_plan_stats
  if [ "$P_N" = 0 ]; then echo "Nothing needs fixing automatically."; else
    echo "Here is the plan. You approve it once; I do the steps in this order:"
  fi
  for o in $(sd_plan_order); do
    k=$o; n=$((n + 1)); ph=${P_PH[k]}
    [ "$ph" != "$last" ] && { echo; echo "== $(sd_phase_name "$ph") =="; last=$ph; }
    if [ "${P_ISS[k]}" -lt 0 ]; then echo "  $n. Copy your files to another drive (this comes first, because a drive is failing)"; continue; fi
    local -a F=(); sd_fields "${P_ISS[k]}"
    echo "  $n. $(sd_tpl "${F[7]}")"
    echo "     $(sd_tpl "${F[14]}")  [${F[17]}; ${F[10]}]"
    [ -n "${I_ASKQ[${P_ISS[k]}]:-}" ] && echo "     I need one answer: ${I_ASKQ[${P_ISS[k]}]:-}"
  done
  echo; sd_plan_summary_text; echo
  if [ ${#P_SKIP[@]} -gt 0 ]; then
    echo; echo "These need you (I cannot do them for you):"
    local i; for i in "${P_SKIP[@]}"; do local -a F=(); sd_fields "$i"; echo " - $(sd_tpl "${F[7]}"): $(sd_tpl "${F[19]}")"; done
  fi
}

# ---------------------------------------------------------------- doing the plan (after the person approved it ONCE)
# sd_plan_apply [dry]  ; answers come from SD_ANSWERS (assoc: step id -> answer). Needs the repair libraries loaded.
sd_plan_apply() {
  local o k n=0 ok=0 bad=0 skipped=0 backup_done=0 act args
  for o in $(sd_plan_order); do
    k=$o; n=$((n + 1)); act=${P_ACT[k]}
    local q=""
    if [ "${P_ISS[k]}" -lt 0 ]; then q=$(sd_backup_dest_json); [ "$q" = null ] && q=""
    elif [ -n "${I_ASKQ[${P_ISS[k]}]:-}" ]; then q=${I_ASKQ[${P_ISS[k]}]:-}; fi
    local ans=${SD_ANSWERS[${P_ID[k]}]:-}
    if [ -n "$q" ] && [ -z "$ans" ]; then echo "Step $n (${P_ID[k]}): waiting for your answer, skipped for now."; skipped=$((skipped + 1)); continue; fi
    if [ "${P_BLOCKED[k]}" = 1 ] && [ "$backup_done" != 1 ] && [ "$RP_DRY" != 1 ]; then
      echo "Step $n (${P_ID[k]}): not done, because your files have not been backed up yet."; skipped=$((skipped + 1)); continue
    fi
    local -a av=(); [ -n "${P_ARGS[k]}" ] && IFS=$US read -r -a av <<< "${P_ARGS[k]}"
    [ -n "$ans" ] && av=("$ans")
    echo; echo "=== Step $n of $P_N: ${P_ID[k]} ($act) ==="
    if rp_fix_run "$act" "${av[@]}"; then
      ok=$((ok + 1)); [ "$act" = fix-backup-files ] && backup_done=1
    else bad=$((bad + 1)); [ "$act" = fix-backup-files ] && backup_done=0; fi
  done
  echo; echo "Plan finished: $ok done, $bad could not be fixed, $skipped waiting for you."
  [ "$bad" = 0 ]
}
