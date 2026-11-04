# shellcheck shell=bash
# hw/health/checks-core.sh (owner: hardware) - processor, memory, storage, file systems, optical drives.
# Sourced by bin/secure-linux-health after lib.sh. Each chk_* finds the hardware by itself (from /sys, /proc and
# the tools' own output) and records results with res(). Variables set by the caller: MODE (quick|standard|full),
# INTERACTIVE (0|1). Nothing here writes to a disk; the only "heavy" things are in --full mode (stress-ng, memtester,
# SMART short self-test, reading from the drives).

# ---------------------------------------------------------------- CPU
chk_cpu() {
  local ci=$SLH_PROC/cpuinfo model cores vendor mc maxt label crit thr v n vul l
  if [ ! -r "$ci" ]; then res cpu SKIPPED "Could not read the processor information." "" "no $ci"; return; fi
  model=$(awk -F': *' '/^model name/{print $2; exit}' "$ci"); [ -n "$model" ] || model=$(awk -F': *' '/^(Hardware|Model|cpu model)/{print $2; exit}' "$ci")
  [ -n "$model" ] || model="processor"
  cores=$(grep -c '^processor' "$ci" 2>/dev/null); vendor=$(awk -F': *' '/^vendor_id/{print $2; exit}' "$ci")
  mc=$(awk -F': *' '/^microcode/{print $2; exit}' "$ci")
  # temperature: hottest processor sensor
  maxt=0; label=""
  while IFS='|' read -r l v crit _; do
    case "$(slh_lc "$l")" in *tctl*|*tdie*|*package*|*core*|*cpu*|*k10temp*|*x86_pkg*|*soc*) ;; *) continue ;; esac
    [ "$v" -gt "$maxt" ] 2>/dev/null && { maxt=$v; label=$l; }
  done < <(slh_temps)
  thr=0
  for v in "$SLH_SYS"/devices/system/cpu/cpu*/thermal_throttle/*_throttle_count; do
    [ -r "$v" ] && thr=$((thr + $(slh_num "$(slh_rd "$v")")))
  done
  # known unfixed CPU security weaknesses
  vul=""
  for v in "$SLH_SYS"/devices/system/cpu/vulnerabilities/*; do
    [ -r "$v" ] || continue
    case "$(slh_rd "$v")" in Vulnerable*) vul="$vul ${v##*/}" ;; esac
  done
  res cpu OK "Processor: $model, ${cores:-?} thread(s)." "" "vendor=${vendor:-?}"
  klog_n n 'Machine check events logged|mce: \[Hardware Error\]|Machine Check Exception'
  if [ "$n" -gt 0 ]; then
    res cpu:errors FAIL "The processor or memory reported $n hardware error(s) (\"machine check\") since the computer started." \
        "Back up your files. Run the memory test (Memtest86+ on the Secure Linux stick). If it repeats, the processor, memory or motherboard may be faulty." "$(klog_grep 'Machine check|mce:' 2 | tr '\n' ';')"
  elif have ras-mc-ctl && slh_is_root && ras-mc-ctl --summary 2>/dev/null | grep -qiE 'errors?: *[1-9]'; then
    res cpu:errors WARN "The error logger (rasdaemon) has recorded hardware errors." "Run: ras-mc-ctl --errors   and keep a copy of the output." ""
  else
    res cpu:errors OK "No processor hardware errors have been logged since the computer started." "" ""
  fi
  if [ "$maxt" -ge 95 ] 2>/dev/null; then
    res cpu:temperature FAIL "The processor is dangerously hot (${maxt} C, $label). It will slow itself down or shut off." \
        "Switch off and clean the vents and fan with compressed air. On a laptop, use it on a hard flat surface. If it stays this hot, the fan or heat-paste needs replacing." "$label=${maxt}C"
  elif [ "$maxt" -ge 85 ] 2>/dev/null; then
    res cpu:temperature WARN "The processor is running hot (${maxt} C, $label)." "Clean the vents and fan; check nothing blocks the air flow. Hot while idle usually means dust or dried-out heat-paste." "$label=${maxt}C"
  elif [ "$maxt" -gt 0 ] 2>/dev/null; then
    res cpu:temperature OK "Processor temperature is fine (${maxt} C)." "" "$label=${maxt}C"
  else
    res cpu:temperature SKIPPED "No processor temperature sensor was found (normal in a virtual machine)." "" ""
  fi
  if [ "$thr" -gt 0 ]; then
    res cpu:throttling WARN "The processor has slowed itself down to cool off $thr time(s) since start." "Clean the vents and fan; check the power mode is not stuck on 'performance' with a weak charger." "count=$thr"
  else
    res cpu:throttling OK "The processor has not had to slow down because of heat." "" ""
  fi
  if [ -n "$vul" ]; then
    res cpu:security WARN "This processor model has known security weaknesses that are not fully fixed in software:${vul}." "Install updates (Secure Linux does this automatically) and make sure the BIOS is up to date; see fwupd below." "$vul"
  fi
  if [ -n "$mc" ]; then res cpu:microcode OK "Processor microcode (built-in fixes) is loaded: revision $mc." "" "$mc"
  elif [ "$(slh_lc "${vendor:-}")" = genuineintel ] || [ "$(slh_lc "${vendor:-}")" = authenticamd ]; then
    res cpu:microcode WARN "Could not see the processor's microcode revision." "Install the microcode package (Secure Linux's driver step does this): sudo secure-linux-drivers install" ""
  fi
  if [ "$MODE" = full ]; then
    if need stress-ng "processor stress test" stress-ng; then
      local out rc pk=0 pid
      out=$(mktemp)
      slh_t 60 stress-ng --cpu 0 --cpu-method matrixprod --verify --timeout "${SL_HEALTH_STRESS_SECS:-20}s" --metrics-brief > "$out" 2>&1 &
      pid=$!
      while kill -0 "$pid" 2>/dev/null; do
        while IFS='|' read -r l v _; do [ "$v" -gt "$pk" ] 2>/dev/null && pk=$v; done < <(slh_temps)
        sleep 2
      done
      wait "$pid"; rc=$?
      if [ $rc -ne 0 ] && grep -qiE 'verify|mismatch|fail' "$out"; then
        res cpu:stress FAIL "The processor made a calculation mistake under load. That means faulty hardware or overheating." "Do not trust this computer with important work. Check cooling, then test the memory (Memtest86+). If it repeats, the processor or board needs repair." "$(tail -n 3 "$out" | tr '\n' ';')"
      elif [ $rc -ne 0 ]; then
        res cpu:stress WARN "The processor stress test stopped early (code $rc)." "Check the temperature; if the computer shut down or froze, it is overheating or the power supply is weak." "$(tail -n 2 "$out" | tr '\n' ';')"
      elif [ "$pk" -ge 95 ]; then
        res cpu:stress FAIL "Passed the calculation test but reached ${pk} C under load." "Clean the vents and fan. Replace the heat-paste if it stays this hot." "peak=${pk}C"
      elif [ "$pk" -ge 90 ]; then
        res cpu:stress WARN "Passed the calculation test but got very hot under load (${pk} C)." "Clean the vents and fan." "peak=${pk}C"
      else
        res cpu:stress OK "Passed a ${SL_HEALTH_STRESS_SECS:-20}-second stress test with correct results${pk:+ (peak ${pk} C)}." "" "peak=${pk}C"
      fi
      rm -f "$out"
    else res cpu:stress SKIPPED "Stress test skipped: stress-ng is not installed." "Install it with: sudo secure-linux-parts --install" ""; fi
  fi
}

# ---------------------------------------------------------------- RAM
chk_ram() {
  local mt kb ma ecc="" ce=0 ue=0 f d dimms="" nd=0 empty=0 oom size_mb free_mb
  kb=$(awk '/^MemTotal:/{print $2; exit}' "$SLH_PROC/meminfo" 2>/dev/null); ma=$(awk '/^MemAvailable:/{print $2; exit}' "$SLH_PROC/meminfo" 2>/dev/null)
  if [ -z "$kb" ]; then res ram SKIPPED "Could not read the memory size." "" ""; return; fi
  mt=$(awk -v k="$kb" 'BEGIN{printf "%.1f", k/1048576}')
  if needroot "memory sticks (dmidecode)" && need dmidecode "memory stick details" dmidecode; then
    local dm; dm=$(dmidecode -t memory 2>/dev/null)
    nd=$(printf '%s\n' "$dm" | grep -cE '^[[:space:]]*Size: [0-9]')
    empty=$(printf '%s\n' "$dm" | grep -cE '^[[:space:]]*Size: No Module')
    ecc=$(printf '%s\n' "$dm" | awk -F': ' '/Error Correction Type/{print $2; exit}')
    dimms=$(printf '%s\n' "$dm" | awk -F': ' '/^[[:space:]]*Size: [0-9]/{s=$2} /^[[:space:]]*Speed: [0-9]/{print s " @ " $2}' | tr '\n' ';')
  fi
  for d in "$SLH_SYS"/devices/system/edac/mc/mc*; do
    [ -d "$d" ] || continue
    ce=$((ce + $(slh_num "$(slh_rd "$d/ce_count")"))); ue=$((ue + $(slh_num "$(slh_rd "$d/ue_count")")))
    [ -z "$ecc" ] && ecc="EDAC"
  done
  if [ "$ue" -gt 0 ]; then
    res ram:errors FAIL "Memory reported $ue uncorrectable error(s) (EDAC). The memory is faulty." "Back up now. Replace the memory stick (test one at a time with Memtest86+ from the Secure Linux stick)." "ue=$ue ce=$ce"
  elif [ "$ce" -gt 0 ]; then
    res ram:errors WARN "Memory corrected $ce error(s) by itself (ECC). A stick may be starting to fail." "Keep an eye on it: if the number grows, replace the stick. Run Memtest86+ from the Secure Linux stick." "ce=$ce"
  elif [ -d "$SLH_SYS/devices/system/edac/mc" ]; then
    res ram:errors OK "Error-correcting memory (ECC) has not logged any errors." "" ""
  fi
  klog_n n 'EDAC .*(CE|UE|error)|memory failure|Hardware error.*memory|MCE.*memory'
  [ "$n" -gt 0 ] && [ "$ce" -eq 0 ] && [ "$ue" -eq 0 ] && res ram:kernel WARN "The kernel log mentions $n memory error message(s)." "Run Memtest86+ from the Secure Linux stick (boot menu). A full test takes an hour or more." "$(klog_grep 'EDAC|memory failure' 2 | tr '\n' ';')"
  klog_n oom 'Out of memory: Killed|oom-kill|invoked oom-killer'
  if [ "$oom" -gt 0 ]; then
    res ram:pressure WARN "The computer ran out of memory $oom time(s) since start and had to close programs." "Close programs you are not using, or add more memory. Secure Linux uses compressed memory (zram) to help." "oom=$oom"
  fi
  if [ "$ecc" ] && [ "$ecc" != None ] && [ "$ecc" != "EDAC" ]; then ecc=" (error-correcting: $ecc)"; elif [ "$ecc" = EDAC ]; then ecc=" (error-correcting)"; else ecc=""; fi
  if [ "$nd" -eq 1 ] && [ "$empty" -ge 1 ]; then
    res ram:channels OK "Only one memory stick is fitted and there is a free slot." "Adding a second matching stick usually makes graphics and everything else noticeably faster." "$dimms"
  fi
  if [ "$MODE" = full ]; then
    if need memtester "memory test on free memory" memtester; then
      free_mb=$(awk -v k="${ma:-0}" 'BEGIN{printf "%d", k/1024}'); size_mb=$((free_mb / 4)); [ "$size_mb" -gt 512 ] && size_mb=512
      if [ "$size_mb" -lt 16 ]; then res ram:test SKIPPED "Not enough free memory for a quick memory test." "Close programs and try again, or use Memtest86+ from the stick." ""
      else
        local out rc; out=$(mktemp)
        slh_t 900 memtester "${size_mb}M" 1 > "$out" 2>&1; rc=$?
        if [ $rc -eq 0 ]; then res ram:test OK "A quick pass over ${size_mb} MB of free memory found no errors." "For a complete test of ALL memory, restart and choose Memtest86+ in the Secure Linux stick's menu." ""
        elif grep -qi 'mlock\|permission' "$out"; then res ram:test SKIPPED "The quick memory test needs administrator rights to lock memory." "Run again with sudo." ""
        else res ram:test FAIL "The quick memory test found errors (memtester code $rc). The memory is faulty." "Replace the memory (test one stick at a time with Memtest86+ from the stick)." "$(grep -iE 'FAIL|error' "$out" | head -n 3 | tr '\n' ';')"; fi
        rm -f "$out"
      fi
    else res ram:test SKIPPED "Quick memory test skipped: memtester is not installed." "Install it with: sudo secure-linux-parts --install" ""; fi
  fi
  res ram OK "Memory: ${mt} GB${ecc}. A complete memory test needs a restart: use Memtest86+ from the Secure Linux stick's boot menu." "" "$dimms"
}

# ---------------------------------------------------------------- storage helpers
slh_disk_kind() {   # slh_disk_kind NAME -> nvme | sd | emmc | usb | hdd | ssd
  local n=$1 p="$SLH_SYS/block/$1" t
  case "$n" in
    nvme*) echo nvme; return ;;
    mmcblk*) t=$(slh_rd "$p/device/type"); [ "$t" = SD ] && echo sd || echo emmc; return ;;
  esac
  case "$(readlink -f "$p" 2>/dev/null)" in */usb[0-9]*) echo usb; return ;; esac
  [ "$(slh_rd "$p/removable")" = 1 ] && { echo usb; return; }
  [ "$(slh_rd "$p/queue/rotational")" = 1 ] && echo hdd || echo ssd
}
slh_kind_word() { case "$1" in nvme) echo "NVMe SSD" ;; sd) echo "SD card" ;; emmc) echo "built-in flash storage (eMMC)" ;; usb) echo "USB drive or stick" ;; hdd) echo "hard disk (HDD)" ;; *) echo "SSD" ;; esac; }
slh_speed_read() {   # slh_speed_read DEVICE MB -> MB/s (integer) | ERR | NOACCESS
  local dev=$1 mb=$2 out line v u
  [ -r "$dev" ] || { echo NOACCESS; return; }
  out=$(slh_t 60 dd if="$dev" of=/dev/null bs=1M count="$mb" iflag=direct 2>&1) || out=$(slh_t 60 dd if="$dev" of=/dev/null bs=1M count="$mb" 2>&1)
  case "$out" in *"Input/output error"*) echo ERR; return ;; esac
  line=$(printf '%s\n' "$out" | tail -n 1)
  v=$(printf '%s' "$line" | sed -n 's/.*, \([0-9.,]*\) \([kMG]\)B\/s.*/\1/p' | tr -d ','); u=$(printf '%s' "$line" | sed -n 's/.*, [0-9.,]* \([kMG]\)B\/s.*/\1/p')
  [ -n "$v" ] || { echo ERR; return; }
  case "$u" in G) awk -v v="$v" 'BEGIN{printf "%d", v*1000}' ;; k) awk -v v="$v" 'BEGIN{printf "%d", v/1000}' ;; *) awk -v v="$v" 'BEGIN{printf "%d", v}' ;; esac
}
slh_smart_fields() {   # parse smartctl / nvme-cli text on stdin into  key=value  lines
  awk '
    /SMART overall-health self-assessment test result:/ {print "health=" $NF}
    /SMART Health Status:/ {print "health=" $NF}
    /^Critical Warning:/ {print "crit=" $NF}
    /^critical_warning/ {gsub(/[[:space:]]/,""); split($0,a,":"); print "crit=" a[2]}
    /^Available Spare:/ {gsub(/%/,""); print "spare=" $NF}
    /^available_spare[[:space:]]*:/ {gsub(/[%[:space:]]/,""); split($0,a,":"); print "spare=" a[2]}
    /^Available Spare Threshold:/ {gsub(/%/,""); print "spare_thr=" $NF}
    /^available_spare_threshold/ {gsub(/[%[:space:]]/,""); split($0,a,":"); print "spare_thr=" a[2]}
    /^Percentage Used:/ {gsub(/%/,""); print "used=" $NF}
    /^percentage_used/ {gsub(/[%[:space:]]/,""); split($0,a,":"); print "used=" a[2]}
    /^Media and Data Integrity Errors:/ {gsub(/,/,""); print "media_err=" $NF}
    /^media_errors/ {gsub(/[[:space:]]/,""); split($0,a,":"); print "media_err=" a[2]}
    /^Temperature:/ {print "temp=" $2}
    /^temperature[[:space:]]*:/ {split($0,a,":"); t=a[2]; gsub(/^[[:space:]]+/,"",t); split(t,b," "); print "temp=" b[1]}
    /^Power On Hours:/ {gsub(/,/,""); print "poh=" $NF}
    /^power_on_hours/ {gsub(/[[:space:],]/,""); split($0,a,":"); print "poh=" a[2]}
    /^Device Model:|^Model Number:|^Product:/ {sub(/^[^:]*:[[:space:]]*/,""); print "model=" $0}
    /^ *5 Reallocated_Sector_Ct/ {print "realloc=" $10}
    /^ *187 Reported_Uncorrect/ {print "uncorrect=" $10}
    /^ *197 Current_Pending_Sector/ {print "pending=" $10}
    /^ *198 Offline_Uncorrectable/ {print "offline_unc=" $10}
    /^ *199 UDMA_CRC_Error_Count/ {print "crc=" $10}
    /^ *9 Power_On_Hours/ {print "poh=" $10}
    /^ *19[04] (Temperature|Airflow)/ {print "temp=" $10}
    /^ *(177 Wear_Leveling_Count|231 SSD_Life_Left|233 Media_Wearout_Indicator|202 Percent_Lifetime_Remain)/ {print "life=" $4}
  '
}
slh_smart_load() {   # slh_smart_load "text" -> sets the caller's health, crit, spare, ... variables (no eval)
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      health|crit|spare|spare_thr|used|media_err|temp|poh|realloc|uncorrect|pending|offline_unc|crc|life) printf -v "$k" '%s' "$v" ;;
    esac
  done < <(printf '%s\n' "$1" | slh_smart_fields)
}
slh_nvme_crit_text() {   # decode the NVMe critical-warning bit field into words
  local c=$(( $1 )) t=""
  [ $((c & 1)) -ne 0 ] && t="$t spare space low;"
  [ $((c & 2)) -ne 0 ] && t="$t temperature out of range;"
  [ $((c & 4)) -ne 0 ] && t="$t reliability degraded;"
  [ $((c & 8)) -ne 0 ] && t="$t now read-only;"
  [ $((c & 16)) -ne 0 ] && t="$t backup power failed;"
  printf '%s' "${t:- unknown}"
}

# ---------------------------------------------------------------- storage (one result per drive)
chk_storage() {
  local b name p kind kw size model dev found=0 rm_slot=0 smart out health="" crit spare spare_thr used media_err temp poh realloc pending offline_unc uncorrect crc life
  for b in "$SLH_SYS"/block/*; do
    name=${b##*/}
    case "$name" in loop*|ram*|zram*|dm-*|md*|sr*|fd*|nbd*|nvme*c*n*) continue ;; esac
    [ -d "$b" ] || continue
    size=$(slh_num "$(slh_rd "$b/size")"); size=$((size * 512))
    if [ "$size" -le 0 ]; then rm_slot=$((rm_slot + 1)); continue; fi      # empty card-reader slot
    found=$((found + 1))
    kind=$(slh_disk_kind "$name"); kw=$(slh_kind_word "$kind"); dev=$SLH_DEV/$name
    model=$(slh_rd "$b/device/model"); [ -n "$model" ] || model=$(slh_rd "$b/device/name"); model=$(slh_pretty_name "${model:-unknown model}")
    local label="$name: $model, $(slh_human_bytes "$size") $kw"
    health=""; crit=""; spare=""; spare_thr=""; used=""; media_err=""; temp=""; poh=""; realloc=""; pending=""; offline_unc=""; uncorrect=""; crc=""; life=""
    smart=none
    # --- SMART: nvme-cli for NVMe (wear, spare, critical warning), smartctl for everything else (and as the NVMe fallback)
    if ! slh_is_root; then
      limited "drive health (SMART) of $name (needs administrator rights: run again with sudo, or add --elevate)"; smart=noroot
    fi
    if [ "$smart" = none ] && [ "$kind" = nvme ] && have nvme; then
      out=$(nvme smart-log "/dev/${name%n[0-9]*}" 2>/dev/null)
      if [ -n "$out" ]; then smart=nvme; slh_smart_load "$out"; fi
    fi
    if [ "$smart" = none ] && have smartctl; then
      out=$(slh_t 30 smartctl -H -A -i "/dev/$name" 2>/dev/null)
      if printf '%s' "$out" | grep -qiE 'SMART overall-health|SMART Health Status|Critical Warning'; then
        smart=smartctl; slh_smart_load "$out"
      elif printf '%s' "$out" | grep -qiE 'Unknown USB bridge|Unsupported|SMART support is: Unavailable|Operation not supported'; then smart=unsupported; fi
    elif [ "$smart" = none ]; then need smartctl "drive health (SMART)" smartmontools; smart=notool; fi
    local st=OK msg="" todo="" det="smart=$smart"
    # --- verdict from SMART
    if [ "$smart" = smartctl ] || [ "$smart" = nvme ]; then
      det="$det health=${health:-?} temp=${temp:-?} poh=${poh:-?}"
      if [ "${health:-PASSED}" = FAILED ] || [ "${health:-OK}" = FAILED! ]; then
        st=FAIL; msg="The drive says it is failing its own health test."; todo="Back up everything NOW (Secure Linux Backup, or the data-rescue option in secure-linux-repair). Then replace the drive."
      fi
      if [ -n "${crit:-}" ] && [ $((crit)) -ne 0 ] 2>/dev/null; then
        st=FAIL; msg="The SSD reports a critical warning:$(slh_nvme_crit_text "$crit")"; todo="Back up everything NOW and replace the SSD."
      fi
      if [ -n "${spare:-}" ] && [ -n "${spare_thr:-}" ] && slh_lt "$spare" "$spare_thr" && [ "$st" != FAIL ]; then
        st=FAIL; msg="The SSD has almost no spare space left (${spare}% left, limit ${spare_thr}%)."; todo="Back up everything NOW and replace the SSD."
      fi
      if [ -n "${used:-}" ] && slh_ge "$used" 100 && [ "$st" != FAIL ]; then
        st=WARN; msg="The SSD has used ${used}% of its rated lifetime."; todo="It may keep working, but plan to replace it and keep your backups up to date."
      elif [ -n "${used:-}" ] && slh_ge "$used" 90 && [ "$st" = OK ]; then
        st=WARN; msg="The SSD has used ${used}% of its rated lifetime."; todo="Plan to replace it soon; keep your backups up to date."
      fi
      if [ -n "${life:-}" ] && slh_lt "$life" 11 && [ "$st" = OK ]; then st=FAIL; msg="The SSD reports only ${life}% of its life left."; todo="Back up now and replace it."
      elif [ -n "${life:-}" ] && slh_lt "$life" 21 && [ "$st" = OK ]; then st=WARN; msg="The SSD reports ${life}% of its life left."; todo="Plan to replace it soon."; fi
      if [ -n "${pending:-}" ] && slh_gt "$pending" 0 && [ "$st" != FAIL ]; then st=FAIL; msg="The drive has ${pending} sector(s) it cannot read reliably (pending)."; todo="Back up NOW. A drive with unreadable sectors usually keeps getting worse."; fi
      if [ -n "${offline_unc:-}" ] && slh_gt "$offline_unc" 0 && [ "$st" != FAIL ]; then st=FAIL; msg="The drive has ${offline_unc} uncorrectable sector(s)."; todo="Back up NOW and replace the drive."; fi
      if [ -n "${realloc:-}" ] && slh_ge "$realloc" 100 && [ "$st" != FAIL ]; then st=FAIL; msg="The drive has re-mapped ${realloc} damaged sectors."; todo="Back up NOW and replace the drive."
      elif [ -n "${realloc:-}" ] && slh_gt "$realloc" 0 && [ "$st" = OK ]; then st=WARN; msg="The drive has re-mapped ${realloc} damaged sector(s)."; todo="Back up soon. If the number keeps growing, replace the drive."; fi
      if [ -n "${media_err:-}" ] && slh_gt "$media_err" 0 && [ "$st" = OK ]; then st=WARN; msg="The SSD logged ${media_err} data-integrity error(s)."; todo="Back up soon and keep an eye on it."; fi
      if [ -n "${uncorrect:-}" ] && slh_gt "$uncorrect" 0 && [ "$st" = OK ]; then st=WARN; msg="The drive reported ${uncorrect} uncorrectable read error(s)."; todo="Back up soon."; fi
      if [ -n "${crc:-}" ] && slh_gt "$crc" 0 && [ "$st" = OK ]; then st=WARN; msg="The connection to the drive had ${crc} transfer error(s) (usually a bad cable)."; todo="Re-seat or replace the SATA cable."; fi
      if [ -n "${temp:-}" ]; then
        if slh_ge "$temp" 85 && [ "$st" != FAIL ]; then st=FAIL; msg="The drive is dangerously hot (${temp} C)."; todo="Switch off and let it cool. Check the fans and air flow."
        elif slh_ge "$temp" 70 && [ "$st" = OK ]; then st=WARN; msg="The drive is hot (${temp} C)."; todo="Check the fans and air flow."; fi
      fi
      [ "$st" = OK ] && msg="SMART health test passed${temp:+, ${temp} C}${poh:+, ${poh} hours powered on}${used:+, ${used}% of lifetime used}."
    else
      case "$smart" in
        unsupported) msg="This $kw does not report health data (normal for USB sticks and SD cards)." ;;
        noroot) st=SKIPPED; msg="Health data (SMART) needs administrator rights."; todo="Run again with sudo (or add --elevate)." ;;
        notool) st=SKIPPED; msg="Health data (SMART) is not available because smartctl is not installed."; todo="Install it: sudo secure-linux-parts --install   (package: smartmontools)" ;;
        *) msg="No SMART health data could be read from this drive." ;;
      esac
    fi
    # --- read speed sanity (non-destructive; reads the first part of the drive only)
    local mb=0 sp="" low=0
    [ "$MODE" = standard ] && mb=64; [ "$MODE" = full ] && mb=512
    if [ "$mb" -gt 0 ]; then
      sp=$(slh_speed_read "$dev" "$mb")
      case "$sp" in
        NOACCESS) det="$det speed=noaccess"; limited "read speed of $name (needs administrator rights)" ;;
        ERR) st=FAIL; msg="Reading from this drive failed (input/output error). $msg"; todo="Back up what you can NOW (data rescue in secure-linux-repair). The drive or its cable is failing."; det="$det speed=ERR" ;;
        *)
          det="$det speed=${sp}MB/s"
          case "$kind" in nvme) low=300 ;; ssd) low=100 ;; hdd) low=25 ;; usb) low=8 ;; sd) low=5 ;; *) low=10 ;; esac
          if slh_lt "$sp" "$low"; then
            [ "$st" = OK ] && { st=WARN; todo="A very slow drive makes everything feel slow. Check the cable/port; for a USB stick try a USB 3 port; a slow HDD may be failing."; }
            msg="$msg It reads slowly (${sp} MB/s; a healthy $kw does at least ${low})."
          else msg="$msg Read speed ${sp} MB/s is fine."; fi ;;
      esac
    fi
    res "storage:$name" "$st" "$label: $msg" "$todo" "$det"
    # --- self-test (full mode only): the drive tests itself; reading the result is safe
    if [ "$MODE" = full ] && [ "$smart" = smartctl ] && [ "$kind" != usb ]; then
      slh_t 20 smartctl -t short "/dev/$name" >/dev/null 2>&1
      local i=0 sc
      while [ $i -lt "${SL_HEALTH_SELFTEST_WAIT:-30}" ]; do
        sc=$(smartctl -c "/dev/$name" 2>/dev/null); printf '%s' "$sc" | grep -qi 'in progress' || break
        sleep 5; i=$((i + 1))
      done
      if smartctl -l selftest "/dev/$name" 2>/dev/null | grep -qiE 'Completed: read failure|Completed: unknown failure|Completed: electrical|Completed: servo'; then
        res "storage:$name-selftest" FAIL "$name: the drive's own self-test found a read failure." "Back up NOW and replace the drive." "smartctl -l selftest"
      else res "storage:$name-selftest" OK "$name: the drive's own short self-test passed (or has no failures logged)." "" ""; fi
    fi
  done
  if [ "$found" -eq 0 ]; then res storage NOT-PRESENT "No internal drive, USB drive or SD card with a size was found." "If this computer should have a drive, check the BIOS shows it; the cable may be loose." ""; return; fi
  # kernel-reported I/O trouble, per device and for the SATA links
  local n d
  for b in "$SLH_SYS"/block/*; do
    name=${b##*/}; case "$name" in loop*|ram*|zram*|dm-*|md*|sr*|fd*|nbd*|nvme*c*n*) continue ;; esac
    klog_n n "I/O error, dev $name|Buffer I/O error on dev $name|nvme.*$name.*(timeout|I/O error)|$name: .*unrecoverable"
    if [ "$n" -gt 0 ]; then res "storage:$name-io" FAIL "$name: the kernel logged $n input/output error(s) on this drive." "Back up NOW. Re-seat the cable; if errors continue the drive is failing." "$(klog_grep "dev $name" 2 | tr '\n' ';')"; fi
  done
  klog_n n 'ata[0-9.]+: .*(failed command|exception Emask|SError:|hard resetting link|link is slow)'
  if [ "$n" -gt 0 ]; then res storage:links WARN "The SATA drive connection reported $n error(s) or resets since start." "Re-seat or replace the SATA cable; if a drive is also listed as failing above, back up first." "$(klog_grep 'ata[0-9]+' 2 | tr '\n' ';')"; fi
  klog_n n 'nvme nvme[0-9]+: (I/O [0-9]+ QID [0-9]+ timeout|controller is down|Device not ready|failed to set APST)'
  if [ "$n" -gt 0 ]; then res storage:nvme-link WARN "The NVMe SSD had $n timeout/controller message(s) since start." "Update the BIOS and the SSD firmware (fwupd). On some laptops adding the kernel option nvme_core.default_ps_max_latency_us=0 fixes vanishing SSDs." "$(klog_grep 'nvme nvme' 2 | tr '\n' ';')"; fi
  [ "$rm_slot" -gt 0 ] && res storage:card-slots OK "$rm_slot empty card-reader slot(s) found (no card inserted)." "" ""
}

# ---------------------------------------------------------------- file systems
chk_filesystem() {
  local seen=0 line mp fs pct bad=0 dev opts
  if [ -r "$SLH_PROC/mounts" ]; then
    while read -r dev mp fs opts _; do
      case "$fs" in ext4|ext3|xfs|btrfs|f2fs|vfat|exfat|ntfs|ntfs3|fuseblk) ;; *) continue ;; esac
      case "$mp" in /boot/efi|/run/*|/proc*|/sys*) ;; esac
      seen=$((seen + 1))
      case ",$opts," in *,ro,*) [ "$mp" = / ] && { res "filesystem:ro-root" FAIL "The main system disk is mounted read-only. The kernel does that after finding disk errors." "Restart. If it comes back read-only, use secure-linux-repair > Repair a disk; back up first." "$dev $mp $opts"; bad=1; } ;; esac
      if [ "$fs" = btrfs ] && have btrfs && slh_is_root && [ "$MODE" != quick ]; then
        local st; st=$(btrfs device stats "$mp" 2>/dev/null | awk '$2+0 > 0 {print $1 "=" $2}' | tr '\n' ' ')
        if [ -n "$st" ]; then res "filesystem:btrfs-$(printf '%s' "$mp" | tr '/' '_')" FAIL "Btrfs counted disk errors on $mp: $st." "Back up, then run: sudo btrfs scrub start -B $mp  (or secure-linux-repair > Repair a disk). Replace the drive if errors continue." "$st"; bad=1
        else res "filesystem:btrfs-$(printf '%s' "$mp" | tr '/' '_')" OK "Btrfs on $mp has counted no disk errors." "" ""; fi
      fi
    done < "$SLH_PROC/mounts"
  fi
  if [ "$seen" -eq 0 ]; then res filesystem NOT-PRESENT "No mounted disk file systems (a live system running from memory?)." "" ""; fi
  # space
  if have df; then
    while read -r _ _ _ _ pct mp; do
      pct=${pct%\%}; [ -n "$pct" ] || continue
      case "$mp" in /|/home|/var) ;; *) continue ;; esac
      if slh_ge "$pct" 97; then res "filesystem:space-$(printf '%s' "$mp" | tr '/' '_')" FAIL "$mp is ${pct}% full. Programs may fail to save or start." "Free space now: empty the bin, remove old downloads, run 'secure-linux-status'. Btrfs snapshots can also use space." "${pct}%"; bad=1
      elif slh_ge "$pct" 90; then res "filesystem:space-$(printf '%s' "$mp" | tr '/' '_')" WARN "$mp is ${pct}% full." "Free some space soon." "${pct}%"; fi
    done < <(df -P 2>/dev/null | tail -n +2)
  fi
  local n; klog_n n 'EXT4-fs error|XFS .*(Corruption|corrupt|metadata I/O error)|BTRFS (error|critical)|F2FS-fs.*(error|Corrupted)|FAT-fs.*(error|corrupt)|exFAT-fs.*error|NTFS.*(error|corrupt)'
  if [ "$n" -gt 0 ]; then res filesystem:kernel FAIL "The kernel logged $n file-system error message(s) since start." "Back up, then use secure-linux-repair > Repair a disk (it runs the right checker for each type)." "$(klog_grep 'EXT4-fs error|BTRFS|XFS|F2FS|FAT-fs' 2 | tr '\n' ';')"; bad=1; fi
  if [ -r "$SLH_PROC/mdstat" ] && grep -qE '^md[0-9]+' "$SLH_PROC/mdstat" 2>/dev/null; then
    if grep -qE '\[[U_]*_[U_]*\]' "$SLH_PROC/mdstat"; then res filesystem:raid FAIL "A software RAID is degraded (a member drive is missing or failed)." "Replace the failed drive and re-add it: see 'mdadm --detail /dev/md0'." "$(grep -E '^md|blocks' "$SLH_PROC/mdstat" | head -n 2 | tr '\n' ';')"
    else res filesystem:raid OK "Software RAID is healthy." "" ""; fi
  fi
  [ "$bad" = 0 ] && [ "$seen" -gt 0 ] && res filesystem OK "File systems are mounted normally with no errors reported." "" ""
  return 0
}

# ---------------------------------------------------------------- CD / DVD / Blu-ray
chk_optical() {
  local d name found=0 dev vendor model prop caps="" media="" can_burn=0 info=$SLH_PROC/sys/dev/cdrom/info
  for d in "$SLH_SYS"/block/sr*; do
    [ -d "$d" ] || continue
    found=$((found + 1)); name=${d##*/}; dev=$SLH_DEV/$name
    vendor=$(slh_rd "$d/device/vendor"); model=$(slh_rd "$d/device/model")
    local label; label=$(slh_pretty_name "$vendor $model"); [ -n "$label" ] || label=$name
    caps=""; media=""; can_burn=0
    # what it can read and write: the kernel's own table first, udev's tags (which include Blu-ray) second
    if [ -r "$info" ]; then
      caps=$(awk -v n="$name" '
        /^drive name:/ { for (i = 3; i <= NF; i++) if ($i == n) c = i - 2; next }
        /^Can / && c { lab = $0; sub(/:.*/, "", lab); sub(/^Can /, "", lab); vals = $0; sub(/^[^:]*:[ 	]*/, "", vals); split(vals, w, /[ 	]+/); if (w[c] == 1) print lab }
      ' "$info" | grep -E '^(write|read) (CD|DVD)')
    fi
    if have udevadm; then
      prop=$(udevadm info --query=property --name="$dev" 2>/dev/null)
      printf '%s\n' "$prop" | grep -q '^ID_CDROM_BD=1' && caps="$caps
read Blu-ray"
      printf '%s\n' "$prop" | grep -qE '^ID_CDROM_BD_R=1|^ID_CDROM_BD_RE=1' && caps="$caps
write Blu-ray"
      printf '%s\n' "$prop" | grep -qE '^ID_CDROM_(CD_R|CD_RW|DVD_R|DVD_RW|DVD_RAM|DVD_PLUS_R|DVD_PLUS_RW)=1' && can_burn=1
      printf '%s\n' "$prop" | grep -q '^ID_CDROM_MEDIA=1' && media=$(printf '%s\n' "$prop" | sed -n 's/^ID_CDROM_MEDIA_STATE=//p')
      [ -n "$media" ] || { printf '%s\n' "$prop" | grep -q '^ID_CDROM_MEDIA=1' && media=complete; }
    fi
    printf '%s\n' "$caps" | grep -qiE 'write (CD|DVD)' && can_burn=1
    if need xorriso "burn-ability report for the disc drive" xorriso && [ -e "$dev" ] && [ -r "$dev" ]; then
      xorriso -outdev "$dev" -list_profiles all 2>/dev/null | grep -qiE 'Profile: .*(CD-R|DVD-R|DVD\+R|BD-R)' && can_burn=1
    fi
    caps=$(printf '%s\n' "$caps" | sed '/^$/d' | tr '\n' ',' | sed 's/,$//; s/,/, /g')
    local st=OK msg todo="" det="caps=$caps media=${media:-none}"
    msg="Disc drive found: $label. Reads/writes: ${caps:-unknown}."
    # read a disc if one is inside
    if [ -n "$media" ] && [ "$media" != blank ]; then
      if [ -r "$dev" ]; then
        local sp; sp=$(slh_speed_read "$dev" 8)
        case "$sp" in
          ERR) st=FAIL; msg="$msg The disc inside could not be read."; todo="Wipe the disc gently with a soft cloth (centre outward) and try again. If other discs also fail, the drive's laser is worn out; a USB DVD drive is cheap." ;;
          NOACCESS) ;;
          *) msg="$msg Read the disc in it OK (${sp} MB/s)." ;;
        esac
      else limited "reading the disc in $name (needs administrator rights)"; fi
    elif [ "$media" = blank ]; then msg="$msg A blank disc is inside (ready to burn)."
    else msg="$msg No disc inside, so reading was not tested: put one in and run again."; fi
    # burning software
    if [ "$can_burn" = 1 ]; then
      if have k3b || have xfburn || have brasero || have xorriso || have growisofs; then
        if have k3b || have xfburn || have brasero; then msg="$msg Can burn discs; burning program is installed."
        else msg="$msg Can burn discs (command-line tools only)."; [ "$st" = OK ] && { st=WARN; todo="Install a burning program: sudo secure-linux-parts --install   (K3b on KDE, Xfburn on Xfce)"; }; fi
      else [ "$st" = OK ] && { st=WARN; msg="$msg Can burn discs, but no burning software is installed."; todo="Install it: sudo secure-linux-parts --install   (K3b on KDE, Xfburn on Xfce)"; }; fi
    fi
    res "optical:$name" "$st" "$msg" "$todo" "$det"
    if [ "$INTERACTIVE" = 1 ] && [ -e "$dev" ] && have eject; then
      if [ "$(slh_ask optical_tray "Test the disc drive tray? The tray will open and close again. Remove any disc first." "Test tray" "Skip")" = yes ]; then
        eject "$dev" 2>/dev/null; sleep 2
        local a; a=$(slh_ask optical_tray_open "Did the tray open?" "Yes" "No")
        eject -t "$dev" 2>/dev/null; sleep 2
        case "$a" in
          yes) res "optical:$name-tray" OK "The tray opens and closes." "" "" ;;
          no) res "optical:$name-tray" FAIL "The tray did not open." "Press the eject button on the drive. Tray still stuck: straighten a paperclip and push it into the small hole next to the tray to release it. Belt may be worn." "" ;;
        esac
      fi
    fi
  done
  [ "$found" -eq 0 ] && res optical NOT-PRESENT "No CD/DVD/Blu-ray drive found. Not needed on most modern computers." "A USB disc drive works too: plug it in and run this check again." ""
  return 0
}
