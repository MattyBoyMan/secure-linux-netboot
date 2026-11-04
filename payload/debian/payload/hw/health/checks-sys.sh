# shellcheck shell=bash
# hw/health/checks-sys.sh (owner: hardware) - screen, graphics, Wi-Fi, Ethernet, battery, charger, fans and
# temperatures, TPM, firmware updates, BIOS, kernel health, and "devices without a driver".
# Sourced by bin/secure-linux-health after lib.sh. Needs MODE and INTERACTIVE from the caller.

# ---------------------------------------------------------------- screen
slh_edid_info() {   # slh_edid_info FILE -> "MAKER|Monitor name|width_cm|height_cm" from the EDID block
  local f=$1 hex b i name="" mf="" w h
  [ -s "$f" ] || return 1
  hex=$(od -An -v -tx1 -w128 "$f" 2>/dev/null | head -n1)
  # shellcheck disable=SC2206
  b=($hex)
  [ "${#b[@]}" -ge 60 ] || return 1
  local v=$(( (0x${b[8]} << 8) | 0x${b[9]} ))
  mf=$(printf "\\x$(printf '%02x' $(( ((v >> 10) & 31) + 64 )))\\x$(printf '%02x' $(( ((v >> 5) & 31) + 64 )))\\x$(printf '%02x' $(( (v & 31) + 64 )))")
  w=$((0x${b[21]})); h=$((0x${b[22]}))
  for i in 54 72 90 108; do
    if [ "${b[i]}" = 00 ] && [ "${b[i+1]}" = 00 ] && [ "${b[i+2]}" = 00 ] && [ "${b[i+3]}" = fc ]; then
      local k; for ((k = i + 5; k < i + 18; k++)); do [ "${b[k]}" = 0a ] && break; name="$name$(printf "\\x${b[k]}")"; done
      break
    fi
  done
  printf '%s|%s|%s|%s\n' "$mf" "$(slh_trim "$name")" "$w" "$h"
}
slh_colour_test() {   # full-screen solid colours, to look for stuck or dead pixels; works in a terminal or on a text console
  local script c
  script='for c in 47 40 41 42 44; do printf "\033[%sm\033[2J\033[H" "$c"; read -rsn1 -p "" _ </dev/tty 2>/dev/null || read -r _; done; printf "\033[0m\033[2J\033[H"'
  if slh_gui_ok && have konsole; then konsole --fullscreen -e bash -c "$script"
  elif slh_gui_ok && have xfce4-terminal; then xfce4-terminal --fullscreen -x bash -c "$script"
  elif slh_gui_ok && have xterm; then xterm -fullscreen -e bash -c "$script"
  else bash -c "$script"; fi
}

chk_display() {
  local c any=0 ext_total=0 ext_conn=0 intl_conn=0 intl_total=0 name stt mode edidinfo exts="" msg
  for c in "$SLH_SYS"/class/drm/card*-*; do
    [ -d "$c" ] || continue
    any=1; name=${c##*/}; name=${name#card*-}
    stt=$(slh_rd "$c/status"); mode=$(head -n1 "$c/modes" 2>/dev/null)
    case "$name" in
      eDP*|LVDS*|DSI*) intl_total=$((intl_total + 1))
        if [ "$stt" = connected ]; then
          intl_conn=$((intl_conn + 1)); edidinfo=$(slh_edid_info "$c/edid" 2>/dev/null)
          local en; en=$(printf '%s' "$edidinfo" | cut -d'|' -f1,2 | tr '|' ' ')
          msg="Built-in screen ($name)${en:+: $en}${mode:+, $mode}."
          local px=${mode%%x*}; px=${px//[^0-9]/}
          [ -n "$px" ] && [ "$px" -ge 2560 ] 2>/dev/null && msg="$msg High-resolution screen: if text looks tiny, set Settings > Display > Scale to 150% or 200%."
          res "display:$name" OK "$msg" "" "$edidinfo"
        else res "display:$name" FAIL "The built-in screen ($name) is not detected." "Plug in an external monitor to confirm the graphics work. If only the built-in screen is dark, the screen cable inside may be loose (a repair job)." ""; fi ;;
      *) ext_total=$((ext_total + 1))
        if [ "$stt" = connected ]; then
          ext_conn=$((ext_conn + 1)); edidinfo=$(slh_edid_info "$c/edid" 2>/dev/null)
          exts="$exts$name${mode:+ ($mode)}; "
          res "display:$name" OK "External screen on $name${mode:+: $mode}${edidinfo:+ ($(printf '%s' "$edidinfo" | cut -d'|' -f1,2 | tr '|' ' '))}." "" "$edidinfo"
        fi ;;
    esac
  done
  if [ "$any" = 0 ]; then
    if [ -d "$SLH_SYS/class/drm" ] || [ "$(slh_chassis)" != other ]; then res display NOT-PRESENT "No display connections found (no working graphics driver, or a computer without a screen)." "If this computer has a screen, check Graphics below." ""
    else res display NOT-PRESENT "No display connections found." "" ""; fi
    return
  fi
  local b bl cur max pct
  for b in "$SLH_SYS"/class/backlight/*; do
    [ -d "$b" ] || continue
    cur=$(slh_rd "$b/brightness"); max=$(slh_rd "$b/max_brightness")
    if [ -n "$max" ] && [ "${max:-0}" -gt 0 ] 2>/dev/null; then
      pct=$(( ${cur:-0} * 100 / max ))
      if [ "${cur:-0}" -eq 0 ]; then res "display:backlight-${b##*/}" WARN "Screen brightness is set to zero (${b##*/}): the screen may look black but is on." "Press the brightness-up key, or run: brightnessctl set 50%" "$cur/$max"
      else res "display:backlight-${b##*/}" OK "Brightness control works (${b##*/}, now ${pct}%)." "" "$cur/$max"; fi
    fi
  done
  [ "$ext_total" -gt 0 ] && [ "$ext_conn" -eq 0 ] && res display:ports OK "$ext_total external video port(s) found (HDMI/DisplayPort/USB-C); none has a screen plugged in, so they were not tested." "Plug a screen in and run again to test a port." ""
  if [ "$INTERACTIVE" = 1 ] && slh_interactive_possible && [ "$(slh_ask display_test "Dead-pixel test: the screen will fill with white, black, red, green and blue in turn. Look for dots or lines that don't change. Press any key to go to the next colour." "Start" "Skip")" = yes ]; then
    slh_scripted || slh_colour_test
    case "$(slh_ask display_ok "Did the whole screen change colour evenly, with no stuck dots, lines or dark patches?" "Looked fine" "I saw a problem")" in
      yes) res display:pixels OK "You saw no stuck or dead pixels, lines or patches." "" "" ;;
      no) res display:pixels FAIL "You saw a screen defect (dead/stuck pixels, lines or dark patches)." "A few stuck pixels are normal wear and cannot be fixed by software. Lines or large patches mean the screen or its cable is failing: ask a repair shop. Check warranty first." "" ;;
    esac
  fi
}

# ---------------------------------------------------------------- graphics cards
slh_gpu_vendor() { case "$1" in 10de) echo NVIDIA ;; 1002|1022) echo AMD ;; 8086) echo Intel ;; 15ad) echo VMware ;; 1af4|1b36) echo virtio ;; 1a03) echo ASPEED ;; 5143|17cb) echo Qualcomm ;; *) echo "vendor $1" ;; esac; }
chk_graphics() {
  local s v dv cl drv n=0 first=1 vk="" gl="" va=""
  while IFS='|' read -r s v dv cl drv; do
    case "$cl" in 0300*|0302*|0380*) ;; *) continue ;; esac
    n=$((n + 1))
    local vend name st=OK msg todo="" det="slot=$s ids=$v:$dv driver=${drv:-none}"
    vend=$(slh_gpu_vendor "$v"); name=$(slh_pci_name "$s" "$v" "$dv")
    msg="$vend graphics ($name), driver: ${drv:-none}."
    case "$drv" in
      "") st=FAIL; msg="$vend graphics ($name) has no driver loaded: only basic, slow graphics are used."; todo="Run: sudo secure-linux-drivers install   (then restart). If it keeps failing, check the Secure Boot driver key (secure-linux-drivers status)." ;;
      simpledrm|simple-framebuffer|efifb|vesafb|vga16fb) st=WARN; msg="$vend graphics ($name) is using a basic fallback driver ($drv): slow, and no 3D."; todo="Run: sudo secure-linux-drivers install   (then restart)." ;;
      nouveau)
        if [ "$v" = 10de ] && [ -r "${SL_ROOT:-/usr/local/lib/secure-linux}/hw/detect.sh" ]; then
          local cls; cls=$( (HW_ROOT=""; . "${SL_ROOT:-/usr/local/lib/secure-linux}/hw/detect.sh"; hw_nvidia_class "$dv") 2>/dev/null)
          case "$cls" in modern|580xx) st=WARN; msg="$vend graphics ($name) uses the open-source driver (nouveau); NVIDIA's own driver would be much faster for games and video."; todo="Run: sudo secure-linux-drivers install  (needs internet; with Secure Boot on you approve a key once at restart)." ;;
            *) msg="$vend graphics ($name): open-source driver (nouveau). This older card is only supported by it, which is the best choice." ;; esac
        else msg="$vend graphics ($name): open-source driver (nouveau)."; fi ;;
    esac
    # temperature
    local t="" h
    for h in "$SLH_SYS"/bus/pci/devices/$s/hwmon/hwmon*/temp1_input; do [ -r "$h" ] && t=$(awk -v c="$(slh_rd "$h")" 'BEGIN{printf "%d", c/1000}'); done
    if [ "$drv" = nvidia ] && have nvidia-smi; then
      local o; o=$(slh_t 10 nvidia-smi --query-gpu=temperature.gpu,driver_version --format=csv,noheader 2>&1)
      if [ $? -ne 0 ] || printf '%s' "$o" | grep -qi 'failed\|unable\|NVIDIA-SMI has failed'; then st=FAIL; msg="$msg The NVIDIA driver is loaded but cannot talk to the card."; todo="Restart. If it persists: sudo secure-linux-drivers reinstall"
      else t=$(printf '%s' "$o" | cut -d, -f1 | tr -d ' '); det="$det nvidia-driver=$(printf '%s' "$o" | cut -d, -f2 | tr -d ' ')"; fi
    elif [ "$v" = 10de ] && [ "$drv" != nvidia ] && [ "$drv" != nouveau ] && [ -n "$drv" ]; then :; fi
    if [ -n "$t" ]; then
      det="$det temp=${t}C"
      if slh_ge "$t" 95; then st=FAIL; msg="$msg It is dangerously hot (${t} C)."; todo="Switch off and clean the fans/vents. Check the graphics card fans spin."
      elif slh_ge "$t" 85 && [ "$st" = OK ]; then st=WARN; msg="$msg It is hot (${t} C)."; todo="Clean the fans and vents; improve air flow."
      else msg="$msg Temperature ${t} C."; fi
    fi
    res "graphics:$s" "$st" "$msg" "$todo" "$det"
    first=0
  done < <(slh_pci_list)
  if [ "$n" -eq 0 ]; then
    if [ -d "$SLH_SYS/class/drm" ] && ls "$SLH_SYS"/class/drm/card* >/dev/null 2>&1; then res graphics OK "Graphics are built into the processor/board (no separate PCI graphics card listed)." "" ""
    else res graphics NOT-PRESENT "No graphics hardware found (a text-only or headless computer)." "" ""; fi
    return
  fi
  # what the graphics can do (skipped in --quick: these start programs that take a few seconds)
  [ "$MODE" = quick ] && return
  if have vulkaninfo; then
    vk=$(slh_t 20 vulkaninfo --summary 2>&1)
    local nv; nv=$(printf '%s\n' "$vk" | grep -c 'deviceName')
    if [ "$nv" -gt 0 ]; then
      if printf '%s\n' "$vk" | grep -i 'deviceName' | grep -qiv 'llvmpipe'; then res graphics:vulkan OK "Vulkan (3D for games) works: $(printf '%s\n' "$vk" | sed -n 's/.*deviceName *= *//p' | head -n 2 | tr '\n' ';')" "" ""
      else res graphics:vulkan WARN "Vulkan only sees the software renderer (llvmpipe), so games won't use the graphics card." "Run: sudo secure-linux-drivers install" ""; fi
    else res graphics:vulkan WARN "Vulkan (3D for games) is not working." "Run: sudo secure-linux-drivers install   Then restart." "$(printf '%s' "$vk" | head -n 2 | tr '\n' ';')"; fi
  else need vulkaninfo "3D (Vulkan) check" vulkan-tools; fi
  if have glxinfo && slh_gui_ok; then
    gl=$(slh_t 15 glxinfo -B 2>/dev/null | sed -n 's/^OpenGL renderer string: *//p')
    case "$(slh_lc "$gl")" in
      *llvmpipe*|*softpipe*|*swrast*) res graphics:opengl WARN "OpenGL runs in software ($gl): the graphics card isn't being used for 3D, so the desktop and video are slower." "Run: sudo secure-linux-drivers install, then restart." "$gl" ;;
      "") ;;
      *) res graphics:opengl OK "OpenGL uses the graphics hardware: $gl." "" "" ;;
    esac
  elif ! have glxinfo; then need glxinfo "OpenGL check" mesa-demos; fi
  if have vainfo; then
    va=$(slh_t 15 vainfo 2>&1)
    local np; np=$(printf '%s\n' "$va" | grep -c 'VAProfile')
    if [ "$np" -gt 0 ]; then res graphics:video-decode OK "Hardware video decoding (VA-API) works: $np video format(s) supported. Videos use less battery." "" ""
    else res graphics:video-decode WARN "Hardware video decoding is not available, so the processor decodes video (hotter, more battery use)." "Install the video drivers: sudo secure-linux-drivers install. On Fedora, Intel needs intel-media-driver and AMD needs mesa-va-drivers-freeworld (both from RPM Fusion)." "$(printf '%s' "$va" | head -n 2 | tr '\n' ';')"; fi
  else need vainfo "video decoding check" libva-utils; fi
  local e; klog_n e 'amdgpu.*(ring .* timeout|GPU reset|failed to|\*ERROR\*)|i915.*(GPU HANG|\*ERROR\*)|xe .*(GT reset|error)|NVRM: Xid|nouveau.*(fifo|error|timeout)'
  [ "$e" -gt 0 ] && res graphics:errors WARN "The graphics driver logged $e error message(s) (freezes, resets or timeouts)." "Update the system, and restart. If the screen freezes, see secure-linux-repair > Graphics trouble." "$(klog_grep 'amdgpu|i915|NVRM|nouveau' 2 | tr '\n' ';')"
  return 0
}

# ---------------------------------------------------------------- Wi-Fi
chk_wifi() {
  local d found=0 n drv fwerr
  for d in "$SLH_SYS"/class/net/*; do
    [ -d "$d/wireless" ] || [ -d "$d/phy80211" ] || continue
    n=${d##*/}; found=$((found + 1))
    drv=$(slh_drv "$d/device/driver")
    local st=OK msg="Wi-Fi adapter $n (driver ${drv:-unknown})" todo="" state; state=$(slh_rd "$d/operstate")
    klog_n fwerr "(iwlwifi|mt79[0-9a-z]*e?|ath[0-9]+k?|brcmfmac|rtw[0-9a-z_]*|rtl[0-9a-z_]*|wlan[0-9]*).*(firmware.*(failed|error|timeout|not found)|Failed to (load|start)|probe .* failed|microcode SW error|Direct firmware load .* failed)"
    if [ "$fwerr" -gt 0 ]; then st=WARN; msg="$msg logged $fwerr firmware/driver error(s) at start-up."; todo="Update firmware: sudo dnf upgrade linux-firmware (or run sudo secure-linux-drivers install), restart. If Wi-Fi drops: see the Troubleshooting chapter."; fi
    if [ "$st" = OK ]; then msg="$msg is ready."; fi
    case "$state" in up) msg="$msg Connected." ;; down) msg="$msg Not connected." ;; esac
    if have iw && [ "$state" = up ]; then
      local sig; sig=$(iw dev "$n" link 2>/dev/null | sed -n 's/.*signal: *\(-[0-9]*\).*/\1/p' | head -n1)
      if [ -n "$sig" ]; then
        msg="$msg Signal ${sig} dBm."
        if slh_lt "$sig" -75 && [ "$st" = OK ]; then st=WARN; todo="The signal is weak: move closer to the router or add a Wi-Fi extender."; fi
      fi
    fi
    local rfk=""; for r in "$SLH_SYS"/class/rfkill/rfkill*; do [ "$(slh_rd "$r/type")" = wlan ] || continue; [ "$(slh_rd "$r/hard")" = 1 ] && rfk=hard; [ "$(slh_rd "$r/soft")" = 1 ] && [ -z "$rfk" ] && rfk=soft; done
    case "$rfk" in hard) st=FAIL; msg="$msg Wi-Fi is switched off by a hardware switch or the airplane-mode key."; todo="Press the airplane-mode/wireless key (often Fn+F2) or flip the wireless switch." ;;
      soft) st=WARN; msg="$msg Wi-Fi is switched off by software (airplane mode)."; todo="Turn Wi-Fi on in the network menu, or run: rfkill unblock wifi" ;; esac
    res "wifi:$n" "$st" "$msg" "$todo" "driver=${drv:-none} operstate=$state"
  done
  if [ "$found" -eq 0 ]; then
    local s v dv cl dr p=0
    while IFS='|' read -r s v dv cl dr; do case "$cl" in 0280*) p=$((p + 1)) ;; esac; done < <(slh_pci_list)
    if [ "$p" -gt 0 ]; then res wifi FAIL "A wireless chip is present but Linux has no Wi-Fi adapter for it (driver or firmware missing)." "Use a cable (or phone USB tethering), then run: sudo secure-linux-drivers install   and restart. Broadcom chips need an extra driver (see docs/COMPATIBILITY.md)." ""
    else res wifi NOT-PRESENT "No Wi-Fi adapter found." "A cheap USB Wi-Fi dongle adds it to any computer." ""; fi
  fi
}

# ---------------------------------------------------------------- Ethernet
chk_ethernet() {
  local d n found=0 spd dup car drv rx rxe
  for d in "$SLH_SYS"/class/net/*; do
    n=${d##*/}
    case "$n" in lo|virbr*|docker*|veth*|br-*|tun*|tap*|bond*|vnet*|wwan*) continue ;; esac
    [ -d "$d/wireless" ] || [ -d "$d/phy80211" ] && continue
    [ -e "$d/device" ] || continue
    [ "$(slh_rd "$d/type")" = 1 ] || continue
    found=$((found + 1))
    drv=$(slh_drv "$d/device/driver")
    car=$(slh_rd "$d/carrier"); spd=$(slh_rd "$d/speed"); dup=$(slh_rd "$d/duplex")
    local st=OK msg="Ethernet port $n (driver ${drv:-unknown})" todo=""
    if [ "$car" = 1 ]; then
      msg="$msg: cable connected"
      if [ -n "$spd" ] && [ "$spd" != "-1" ]; then
        msg="$msg at ${spd} Mb/s${dup:+, $dup duplex}"
        if slh_le_100 "$spd"; then st=WARN; todo="Only ${spd} Mb/s: a gigabit port normally links at 1000. Try another cable (Cat5e or better) or router port; a damaged cable is the usual cause."; fi
        [ "$dup" = half ] && { st=WARN; todo="Half duplex means a bad cable or an old switch. Try another cable/port."; }
      fi
    else msg="$msg: no cable plugged in (or the other end is off)"; fi
    rx=$(slh_num "$(slh_rd "$d/statistics/rx_packets")"); rxe=$(( $(slh_num "$(slh_rd "$d/statistics/rx_errors")") + $(slh_num "$(slh_rd "$d/statistics/rx_crc_errors")") ))
    if [ "$rx" -gt 1000 ] && [ $((rxe * 100)) -gt "$rx" ]; then st=WARN; msg="$msg; ${rxe} receive errors out of ${rx} packets"; todo="Many errors: replace the cable and try another router port."; fi
    res "ethernet:$n" "$st" "$msg." "$todo" "carrier=$car speed=$spd duplex=$dup driver=${drv:-none}"
  done
  if [ "$found" -eq 0 ]; then
    local s v dv cl dr p=0
    while IFS='|' read -r s v dv cl dr; do case "$cl" in 0200*) p=$((p + 1)) ;; esac; done < <(slh_pci_list)
    if [ "$p" -gt 0 ]; then res ethernet FAIL "A network chip is present but Linux has no Ethernet port for it (driver missing)." "Use Wi-Fi or a USB network adapter, then run: sudo secure-linux-drivers install and restart." ""
    else res ethernet NOT-PRESENT "No Ethernet port found (normal for thin laptops; a USB network adapter adds one)." "" ""; fi
  fi
}
slh_le_100() { slh_ge 100 "$1"; }

# ---------------------------------------------------------------- battery and charger
chk_battery() {
  local b found=0 full design now cyc status cap lim tech name health st msg todo
  for b in "$SLH_SYS"/class/power_supply/*; do
    [ "$(slh_rd "$b/type")" = Battery ] || continue
    [ "$(slh_rd "$b/scope")" = Device ] && continue            # wireless mouse/keyboard batteries are not the computer's battery
    found=$((found + 1)); name=${b##*/}
    full=$(slh_rd "$b/energy_full"); design=$(slh_rd "$b/energy_full_design")
    [ -n "$full" ] || { full=$(slh_rd "$b/charge_full"); design=$(slh_rd "$b/charge_full_design"); }
    cyc=$(slh_rd "$b/cycle_count"); status=$(slh_rd "$b/status"); cap=$(slh_rd "$b/capacity"); lim=$(slh_rd "$b/charge_control_end_threshold"); [ -n "$lim" ] || lim=$(slh_rd "$b/charge_stop_threshold")
    tech=$(slh_rd "$b/technology")
    if [ "$(slh_rd "$b/present")" = 0 ]; then res "battery:$name" WARN "The battery is not detected (removed or its connector is loose)." "Re-seat the battery. If it is built in, a repair shop can check the connector." ""; continue; fi
    st=OK; todo=""
    if [ -n "$full" ] && [ -n "$design" ] && slh_gt "$design" 0; then
      health=$(awk -v f="$full" -v d="$design" 'BEGIN{printf "%d", 100*f/d}')
      msg="Battery $name: holds ${health}% of its original capacity"
      if [ "$health" -lt 50 ]; then st=FAIL; todo="The battery is worn out. Replace it (a repair shop or the maker's battery kit)."
      elif [ "$health" -lt 80 ]; then st=WARN; todo="The battery has lost a fair bit of capacity. It still works; plan a replacement. Setting a charge limit (secure-linux-battery) slows further wear."; fi
      msg="$msg${cyc:+, $cyc charge cycles}${cap:+, now at ${cap}%}${status:+ ($status)}${lim:+, charge limit ${lim}%}"
      if [ -n "$cyc" ] && slh_ge "$cyc" 1000 && [ "$st" = OK ]; then st=WARN; todo="More than 1000 charge cycles: batteries are typically worn by now."; fi
    else
      st=OK; msg="Battery $name found${cap:+, now at ${cap}%}${status:+ ($status)}; it does not report its capacity, so wear could not be judged"
    fi
    [ "$(slh_rd "$b/capacity_level")" = Critical ] && [ "$st" = OK ] && { st=WARN; msg="$msg; the level is critical"; todo="Plug in the charger."; }
    res "battery:$name" "$st" "$msg." "$todo" "health=${health:-?} cycles=${cyc:-?} status=$status tech=$tech"
  done
  if [ "$found" -eq 0 ]; then
    if [ "$(slh_chassis)" = laptop ]; then res battery WARN "This looks like a laptop but no battery was found." "If a battery is fitted, re-seat it; it may be dead or disconnected." ""
    else res battery NOT-PRESENT "No battery (normal for a desktop)." "" ""; fi
  fi
}
chk_ac() {
  local b online="" kinds="" bat_status="" has_bat=0 any=0
  for b in "$SLH_SYS"/class/power_supply/*; do
    case "$(slh_rd "$b/type")" in
      Mains|USB*|USB_C|USB_PD|USB_PD_DRP) any=1; kinds="$kinds$(slh_rd "$b/type") "; [ "$(slh_rd "$b/online")" = 1 ] && online=yes ;;
      Battery) [ "$(slh_rd "$b/scope")" = Device ] || { has_bat=1; bat_status=$(slh_rd "$b/status"); } ;;
    esac
  done
  if [ "$any" = 0 ]; then
    if [ "$has_bat" = 1 ]; then res ac WARN "A battery was found but no charger/power-adapter input is reported." "Check the charger connector. Some laptops only report power when it is plugged in." ""
    else res ac NOT-PRESENT "No power-adapter information (normal for a desktop computer)." "" ""; fi
    return
  fi
  if [ "$online" = yes ]; then
    if [ "$bat_status" = Discharging ]; then res ac WARN "The charger is plugged in, but the battery is still discharging: the charger gives less power than the computer uses." "Use the original charger (right wattage). Test with the cable and wall socket changed." "status=$bat_status"
    else res ac OK "The power adapter is connected${bat_status:+ (battery: $bat_status)}." "" ""; fi
  else res ac OK "Running on battery (power adapter not plugged in)." "" ""; fi
}

# ---------------------------------------------------------------- temperatures and fans
chk_thermal() {
  local l v crit src hot="" max=0 maxl="" n=0 fatal=""
  while IFS='|' read -r l v crit src; do
    [ -n "$v" ] || continue
    [ "$v" -gt -30 ] 2>/dev/null && [ "$v" -lt 150 ] 2>/dev/null || continue
    n=$((n + 1))
    [ "$v" -gt "$max" ] && { max=$v; maxl=$l; }
    if [ -n "$crit" ] && [ "$crit" -gt 0 ] 2>/dev/null && [ "$v" -ge $((crit - 5)) ]; then fatal="$fatal$l ${v}C (limit ${crit}C); "
    elif [ "$v" -ge 90 ]; then hot="$hot$l ${v}C; "; fi
  done < <(slh_temps)
  if [ "$n" -eq 0 ]; then res thermal:sensors NOT-PRESENT "No temperature sensors are reported (virtual machine or very simple hardware)." "" ""
  elif [ -n "$fatal" ]; then res thermal:sensors FAIL "Something is at its safety temperature limit: ${fatal%; }." "Switch off and cool down. Clean the vents and fan; check the fan spins." "$fatal"
  elif [ -n "$hot" ]; then res thermal:sensors WARN "Very hot: ${hot%; }." "Clean the vents and fan; check air flow." "$hot"
  else res thermal:sensors OK "$n temperature sensor(s); hottest is $maxl at ${max} C." "" ""; fi
  local f fans=0 stopped="" rpm
  for f in "$SLH_SYS"/class/hwmon/hwmon*/fan*_input; do
    [ -r "$f" ] || continue
    fans=$((fans + 1)); rpm=$(slh_num "$(slh_rd "$f")")
    [ "$rpm" -eq 0 ] && stopped="$stopped$(slh_rd "${f%/*}/name")/${f##*/}; "
  done
  if [ "$fans" -eq 0 ]; then res thermal:fans NOT-PRESENT "No fan speed sensors reported (fanless computer, or the fan isn't visible to Linux)." "If the computer gets hot and you can't hear a fan, install the fan driver for your model: sudo secure-linux-parts --install" ""
  elif [ -n "$stopped" ] && [ "$max" -ge 60 ]; then res thermal:fans FAIL "A fan reports 0 RPM while the computer is warm (${max} C): ${stopped%; }." "A stopped fan means overheating. Switch off, clean it, and check it spins freely. Replace the fan if it's seized." "$stopped"
  elif [ -n "$stopped" ]; then res thermal:fans OK "$fans fan(s); some are stopped, which is normal at low temperature (${max} C)." "" ""
  else res thermal:fans OK "$fans fan(s) spinning." "" ""; fi
}

# ---------------------------------------------------------------- TPM
chk_tpm() {
  local t="$SLH_SYS/class/tpm/tpm0" ver
  if [ ! -d "$t" ] && [ ! -e "$SLH_DEV/tpm0" ]; then
    res tpm NOT-PRESENT "No TPM (security chip) is visible. Many computers have one switched off in the BIOS (look for 'fTPM', 'PTT' or 'Security Device')." "Only needed for TPM disk unlocking; the computer works fine without." ""
    return
  fi
  ver=$(slh_rd "$t/tpm_version_major")
  if [ "$ver" = 2 ]; then
    local st=OK msg="TPM 2.0 security chip is working." todo=""
    [ -e "$SLH_DEV/tpmrm0" ] || { st=WARN; msg="$msg But the resource manager device is missing."; todo="Install: sudo secure-linux-parts --install (tpm2-tss)"; }
    if have tpm2_getcap && slh_is_root; then tpm2_getcap properties-variable 2>/dev/null | grep -q 'inLockout: *1' && { st=WARN; msg="$msg It is in lockout (too many wrong PIN tries)."; todo="Wait about 10 minutes, or reset the lockout in the BIOS."; }; fi
    res tpm "$st" "$msg" "$todo" "version=$ver"
  elif [ "$ver" = 1 ] || [ -z "$ver" ]; then res tpm WARN "The TPM is the old 1.2 type (or not readable). TPM disk unlocking needs TPM 2.0." "Nothing is wrong; just don't enable the TPM unlock option on this computer." "version=${ver:-?}"
  else res tpm OK "TPM present (version $ver)." "" ""; fi
}

# ---------------------------------------------------------------- firmware updates (read-only)
chk_fwupd() {
  if ! need fwupdmgr "firmware (BIOS and device) updates check" fwupd; then res fwupd SKIPPED "Firmware-update check skipped: fwupd is not installed." "Install: sudo secure-linux-parts --install" ""; return; fi
  local o; o=$(slh_t 40 fwupdmgr get-updates 2>&1)
  if printf '%s' "$o" | grep -qiE 'No updatable devices|No updates available|No upgrades for|Devices with no available firmware updates' && ! printf '%s' "$o" | grep -qiE 'Upgrade available|Update available|firmware updates available'; then
    res fwupd OK "No firmware updates are waiting for any part of this computer." "" ""
  elif printf '%s' "$o" | grep -qiE 'Upgrade available|Update available|updates available|New version'; then
    local dev; dev=$(printf '%s\n' "$o" | grep -E '^[^ ].*:$|^[A-Za-z0-9].*' | head -n 3 | tr '\n' ';')
    res fwupd WARN "Firmware updates are available (BIOS, SSD, touchpad, dock or similar)." "Install them: open Discover / Software > Updates, or run: sudo fwupdmgr update. Plug in the charger first and don't switch off." "$dev"
  elif printf '%s' "$o" | grep -qiE 'failed|error|could not|no network|unable'; then
    res fwupd SKIPPED "Could not check for firmware updates (no network or no update information yet)." "Connect to the internet and run: fwupdmgr refresh" "$(printf '%s' "$o" | head -n 1)"
  else res fwupd OK "No firmware updates reported." "" ""; fi
}

# ---------------------------------------------------------------- BIOS / firmware information
chk_bios() {
  local vend ver date prod sv bits fw=BIOS sb="" year now age
  vend=$(sysrd class/dmi/id/bios_vendor); ver=$(sysrd class/dmi/id/bios_version); date=$(sysrd class/dmi/id/bios_date)
  prod=$(sysrd class/dmi/id/product_name); sv=$(sysrd class/dmi/id/sys_vendor)
  [ -d "$SLH_SYS/firmware/efi" ] && fw=UEFI
  if [ "$fw" = UEFI ] && have mokutil; then sb=$(mokutil --sb-state 2>/dev/null | head -n1); fi
  if [ -z "$vend$ver$date" ]; then res bios SKIPPED "BIOS information is not available (a virtual machine, or Apple Silicon)." "" ""; return; fi
  year=$(printf '%s' "$date" | grep -oE '(19|20)[0-9]{2}' | tail -n1)
  now=$(slh_date +%Y); age=$(( ${now:-2026} - ${year:-${now:-2026}} ))
  local st=OK msg="$sv $prod: $fw ($vend) version $ver, dated $date${sb:+; $sb}." todo=""
  if [ "$age" -ge 10 ]; then st=WARN; msg="$msg The BIOS is about $age years old."; todo="Look for a BIOS update on the maker's support page (or with fwupd below); newer BIOS versions fix security holes and hardware bugs. Do this only with the charger plugged in."
  elif [ "$age" -ge 6 ]; then st=OK; msg="$msg (about $age years old; check the maker's site now and then)"; fi
  res bios "$st" "$msg" "$todo" "vendor=$vend version=$ver date=$date mode=$fw"
}

# ---------------------------------------------------------------- kernel health, crashes, failed services
chk_kernel() {
  local taint t bits="" bad="" note=""
  taint=$(slh_num "$(slh_rd "$SLH_PROC/sys/kernel/tainted")"); taint=${taint%%.*}
  if [ -r "$SLH_PROC/sys/kernel/tainted" ]; then
    t=$taint
    [ $((t & 16)) -ne 0 ] && bad="$bad a machine-check (hardware error) was reported;"
    [ $((t & 32)) -ne 0 ] && bad="$bad a bad memory page was seen;"
    [ $((t & 128)) -ne 0 ] && bad="$bad the kernel crashed (oops/bug) earlier;"
    [ $((t & 16384)) -ne 0 ] && bad="$bad a soft lockup (the processor got stuck) happened;"
    [ $((t & 1)) -ne 0 ] && note="$note a non-open-source driver is loaded (normal for NVIDIA);"
    [ $((t & 4096)) -ne 0 ] && note="$note an out-of-tree driver is loaded;"
    if [ -n "$bad" ]; then res kernel:taint FAIL "The kernel flagged trouble:${bad%;}." "Restart, and run the memory test (Memtest86+) and the health check again. If it repeats, hardware is faulty. Save a diagnostics file: secure-linux-diag." "taint=$taint"
    else res kernel:taint OK "The kernel reports no hardware or crash problems${note:+ (note:${note%;})}." "" "taint=$taint"; fi
  fi
  local oops; klog_n oops 'kernel BUG at|Oops:|general protection fault|Kernel panic|Call Trace:|BUG: unable to handle'
  if [ "$oops" -gt 0 ]; then res kernel:oops FAIL "The kernel logged $oops crash message(s) since start." "Save a diagnostics file (secure-linux-diag) and ask for help; note what you were doing. If it repeats, run the memory test." "$(klog_grep 'BUG|Oops|protection fault|panic' 2 | tr '\n' ';')"; fi
  local ps=0; [ -d "$SLH_SYS/fs/pstore" ] && ps=$(ls "$SLH_SYS/fs/pstore" 2>/dev/null | wc -l)
  [ "$ps" -gt 0 ] && res kernel:crashdump WARN "The computer left $ps crash record(s) from a previous crash." "Run: secure-linux-diag and keep the file; then clear them with: sudo rm /sys/fs/pstore/*" ""
  local c=0
  if have journalctl; then c=$(slh_t 20 journalctl -b -p crit --no-pager -q 2>/dev/null | grep -c .); fi
  if [ "${c:-0}" -gt 0 ]; then res kernel:journal WARN "The system log has $c critical message(s) since start." "Look at them with: journalctl -b -p crit   and save a diagnostics file (secure-linux-diag) if you want help." "$(slh_t 10 journalctl -b -p crit --no-pager -q 2>/dev/null | head -n 2 | cut -c1-160 | tr '\n' ';')"
  elif have journalctl; then res kernel:journal OK "No critical messages in the system log since start." "" ""; fi
  if have systemctl; then
    local failed; failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
    if [ -n "${failed// /}" ]; then res kernel:services WARN "Some services failed to start: ${failed}." "Try: sudo secure-linux-status (Repair). Details: systemctl status <name>" "$failed"
    else res kernel:services OK "All system services started normally." "" ""; fi
  fi
  firmerr=$(klog_grep 'Direct firmware load for [^ ]+ failed' 100 | sed -n 's/.*Direct firmware load for \([^ ]*\) failed.*/\1/p' | sort -u | head -n 8 | tr '\n' ' ')
  [ -n "${firmerr// /}" ] && res kernel:firmware WARN "Some hardware asked for firmware files that are missing: ${firmerr}." "Update the firmware package: sudo dnf upgrade linux-firmware (or sudo secure-linux-drivers install). Some are harmless (optional files)." "$firmerr"
  return 0
}

# ---------------------------------------------------------------- devices Linux has no driver for (anything else)
chk_unknown() {
  local s v d c drv n=0 list="" name
  while IFS='|' read -r s v d c drv; do
    [ -z "$drv" ] || continue
    case "$c" in 0604*|0600*|0601*|0680*|0805*|0b40*|0d11*|1180*|1101*|1000*|0880*|0c05*|0c80*|1080*|1100*|1200*|1300*) continue ;; esac       # bridges and chipset parts that need no driver
    case "$c" in 01*|02*|03*|04*|0c03*|0d*|0c0*) ;; *) continue ;; esac
    n=$((n + 1)); name=$(slh_pci_name "$s" "$v" "$d"); list="$list$name [$v:$d]; "
  done < <(slh_pci_list)
  local usbnodrv="" id cls sub drv2 vid
  while IFS='|' read -r id cls sub drv2; do
    [ -z "$drv2" ] || continue
    case "$cls" in 01|03|06|07|0e|e0|ff|0a|0b) ;; *) continue ;; esac
    case "$cls" in ff) continue ;; esac
    usbnodrv="$usbnodrv$id (class $cls); "
  done < <(slh_usb_ifaces)
  if [ "$n" -gt 0 ]; then res unknown:pci WARN "$n device(s) inside the computer have no driver: ${list%; }." "Run: sudo secure-linux-parts --check   to see what software they need, then --install. Some are optional parts and fine without a driver." "$list"; fi
  if [ -n "$usbnodrv" ]; then res unknown:usb WARN "Some USB devices have no driver: ${usbnodrv%; }." "Run: sudo secure-linux-parts --check   to see what software they need." "$usbnodrv"; fi
  [ "$n" -eq 0 ] && [ -z "$usbnodrv" ] && res unknown OK "Every device that needs a driver has one." "" ""
  return 0
}
