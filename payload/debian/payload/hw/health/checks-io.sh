# shellcheck shell=bash
# hw/health/checks-io.sh (owner: hardware) - USB, keyboard, mouse/touchpad/touchscreen, sound, Bluetooth, camera,
# card readers, fingerprint reader, built-in sensors, printers/scanners, Thunderbolt/USB4.
# Sourced by bin/secure-linux-health after lib.sh. Needs MODE and INTERACTIVE from the caller.

# ---------------------------------------------------------------- input devices
slh_inputs() {   # prints  NAME|HANDLERS|EV|PROP|ABS|BUS  for every device in /proc/bus/input/devices
  local f=$SLH_PROC/bus/input/devices
  [ -r "$f" ] || return 0
  awk 'BEGIN{RS=""; FS="\n"}
  { name=""; h=""; ev=""; prop=""; abs=""; bus="";
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^I:/) { if (match($i, /Bus=[0-9a-fA-F]+/)) bus = substr($i, RSTART + 4, RLENGTH - 4) }
      if ($i ~ /^N: Name=/) { n = $i; sub(/^N: Name="/, "", n); sub(/"$/, "", n); name = n }
      if ($i ~ /^H: Handlers=/) { h = $i; sub(/^H: Handlers=/, "", h) }
      if ($i ~ /^B: EV=/) { ev = $i; sub(/^B: EV=/, "", ev) }
      if ($i ~ /^B: PROP=/) { prop = $i; sub(/^B: PROP=/, "", prop) }
      if ($i ~ /^B: ABS=/) { abs = $i; sub(/^B: ABS=/, "", abs) }
    }
    print name "|" h "|" ev "|" prop "|" abs "|" bus }' "$f"
}
slh_libinput_events() {   # slh_libinput_events SECONDS -> prints event names seen (needs root or the input group)
  have libinput || return 1
  slh_t "$(( $1 + 3 ))" libinput debug-events --show-keycodes 2>/dev/null &
  local pid=$!; sleep "$1"; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
}
slh_capture_events() {   # slh_capture_events SECONDS FILE   (SL_HEALTH_CAPTURE_SECS shortens it for tests)
  local secs=${SL_HEALTH_CAPTURE_SECS:-$1} pid
  slh_t "$(( secs + 3 ))" libinput debug-events --show-keycodes > "$2" 2>/dev/null &
  pid=$!; sleep "$secs"; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 0
}

chk_keyboard() {
  local n=0 name h kb="" line
  while IFS='|' read -r name h _; do
    case "$h" in *kbd*) ;; *) continue ;; esac
    case "$h" in *leds*) ;; *) continue ;; esac
    case "$name" in *Power\ Button*|*Sleep\ Button*|*Lid\ Switch*|*Video\ Bus*|*Consumer\ Control*|*System\ Control*|*hotkeys*|*PC\ Speaker*|*HDA*) continue ;; esac
    n=$((n + 1)); kb="$kb$name; "
  done < <(slh_inputs)
  if [ "$n" -eq 0 ]; then
    res keyboard NOT-PRESENT "No keyboard was found." "On a desktop, plug in a USB keyboard (or pair a Bluetooth one). If a laptop's built-in keyboard is missing here, the keyboard cable inside may be loose." ""
    return
  fi
  local st=OK msg="Keyboard found: ${kb%; }." todo=""
  if [ "$INTERACTIVE" = 1 ] && have libinput && slh_interactive_possible; then
    local ev; ev=$(mktemp)
    slh_info kbd_intro "Keyboard test: after you click OK, press about ten different keys in the next 8 seconds (letters, numbers, Space, Enter, Shift, arrows)."
    slh_capture_events 8 "$ev"
    local keys; keys=$(grep -c 'KEYBOARD_KEY.*pressed' "$ev" 2>/dev/null); keys=${keys:-0}
    local distinct; distinct=$(grep 'KEYBOARD_KEY.*pressed' "$ev" 2>/dev/null | sed -n 's/.*[ *]\(KEY_[A-Z0-9_]*\) (.*/\1/p' | sort -u | wc -l)
    rm -f "$ev"
    if [ "$keys" -eq 0 ]; then
      case "$(slh_ask keyboard_ok "No key presses were detected. Did you press keys? (If the test could not listen, answer Skip.)" "Yes, I pressed keys" "Skip")" in
        yes) st=WARN; msg="$msg No key presses reached the test."; todo="Needs administrator rights or the 'input' group to listen. Try: sudo secure-linux-health --part keyboard --full" ;;
        *) ;;
      esac
    else msg="$msg Test: $keys key presses, $distinct different keys were seen."; fi
  fi
  res keyboard "$st" "$msg" "$todo" ""
}

chk_pointer() {
  local name h ev prop abs bus found=0 tp="" mouse="" tpt="" ts="" tab="" pad_re='touchpad|trackpad|synaptics|etps/2|clickpad|glidepoint|elan[0-9a-f]+:[0-9a-f]+ mouse|sentelic|alps'
  while IFS='|' read -r name h ev prop abs bus; do
    local ln; ln=$(slh_lc "$name")
    case "$ln" in *hotkey*|*power\ button*|*lid\ switch*|*video\ bus*) continue ;; esac
    if printf '%s' "$ln" | grep -qE 'trackpoint|dualpoint stick|track point|pointing stick|ibm .*point'; then tpt="$tpt$name; "; found=1; continue; fi
    if printf '%s' "$ln" | grep -qE "$pad_re"; then tp="$tp$name; "; found=1; continue; fi
    if printf '%s' "$ln" | grep -qE 'wacom|tablet|\bpen\b|stylus|huion|xp-pen'; then
      case "$ln" in *pad|*"pad "*) ;; esac
      tab="$tab$name; "; found=1; continue
    fi
    if printf '%s' "$ln" | grep -qE 'touchscreen|touch screen|touch digitizer|goodix|hid-over-i2c.*touch|elan.*touchscreen|egalax|atmel maxtouch|ilitek'; then ts="$ts$name; "; found=1; continue; fi
    case "$h" in *mouse*) mouse="$mouse$name; "; found=1 ;; esac
  done < <(slh_inputs)
  if [ "$found" -eq 0 ]; then
    res pointer NOT-PRESENT "No mouse, touchpad or touchscreen was found." "On a desktop plug in a USB or Bluetooth mouse. The keyboard still works for everything meanwhile (Tab, Enter, arrows)." ""
    return
  fi
  [ -n "$tp" ] && res pointer:touchpad OK "Touchpad found: ${tp%; }." "" ""
  [ -n "$tpt" ] && res pointer:trackpoint OK "TrackPoint (pointing stick) found: ${tpt%; }." "" ""
  [ -n "$mouse" ] && res pointer:mouse OK "Mouse found: ${mouse%; }." "" ""
  [ -n "$ts" ] && res pointer:touchscreen OK "Touchscreen found: ${ts%; }." "" ""
  [ -n "$tab" ] && res pointer:tablet OK "Drawing tablet or pen found: ${tab%; }." "" ""
  if [ "$INTERACTIVE" = 1 ] && have libinput && slh_interactive_possible; then
    local ev; ev=$(mktemp)
    slh_info pointer_intro "Mouse and touchpad test: after you click OK you have 10 seconds. Move the pointer, click the buttons, scroll, and (touchpad) try two-finger scroll and a tap. Touchscreen: touch and drag."
    slh_capture_events 10 "$ev"
    local mot btn scr tch ges
    mot=$(grep -c 'POINTER_MOTION' "$ev" 2>/dev/null); btn=$(grep -c 'POINTER_BUTTON' "$ev" 2>/dev/null)
    scr=$(grep -cE 'POINTER_SCROLL|POINTER_AXIS' "$ev" 2>/dev/null); tch=$(grep -c 'TOUCH_DOWN' "$ev" 2>/dev/null); ges=$(grep -c 'GESTURE_' "$ev" 2>/dev/null)
    rm -f "$ev"
    if [ "${mot:-0}" -eq 0 ] && [ "${btn:-0}" -eq 0 ] && [ "${tch:-0}" -eq 0 ]; then
      res pointer:test SKIPPED "No pointer movement was seen. Either you did not touch it, or the test could not listen (needs administrator rights)." "Run again with sudo, and move the mouse during the 10 seconds." ""
    else
      local st=OK msg="Pointer test: ${mot:-0} moves, ${btn:-0} button presses, ${scr:-0} scrolls, ${tch:-0} touches, ${ges:-0} gesture events." todo=""
      if [ "${mot:-0}" -gt 0 ] && [ "${btn:-0}" -eq 0 ]; then
        case "$(slh_ask pointer_buttons "Movement worked, but no button presses were seen. Did you click?" "Yes, I clicked" "No, skip")" in
          yes) st=WARN; msg="$msg The buttons did not register."; todo="Check the touchpad's tap-to-click setting; a loose touchpad connector or a worn button needs repair." ;;
        esac
      fi
      res pointer:test "$st" "$msg" "$todo" ""
    fi
  fi
}

# ---------------------------------------------------------------- USB ports and hubs
chk_usb() {
  local ctl=0 s v d c drv roots=0 line
  while IFS='|' read -r s v d c drv; do case "$c" in 0c03*) ctl=$((ctl + 1)) ;; esac; done < <(slh_pci_list)
  for d in "$SLH_SYS"/bus/usb/devices/usb*; do [ -d "$d" ] && roots=$((roots + 1)); done
  if [ "$ctl" -eq 0 ] && [ "$roots" -eq 0 ]; then res usb NOT-PRESENT "No USB controller was found." "" ""; return; fi
  local devs=0 slow="" id vid pid prod man cls spd ver
  while IFS='|' read -r id vid pid prod man cls spd ver; do
    devs=$((devs + 1))
    local verm; verm=${ver%%.*}; verm=${verm// /}
    if [ -n "$verm" ] && [ "$verm" -ge 3 ] 2>/dev/null && [ -n "$spd" ] && slh_lt "$spd" 5000; then
      slow="$slow$id ($(slh_pretty_name "${prod:-$vid:$pid}") at ${spd} Mb/s); "
      res "usb:$id" WARN "$(slh_pretty_name "${prod:-$vid:$pid}") can do USB 3 speed but is only running at ${spd} Mb/s." \
          "Plug it into a blue (USB 3) port, directly into the computer rather than a hub, or try another cable." "speed=$spd version=$ver"
    fi
  done < <(slh_usb_list)
  local enumerr oc storm
  klog_n enumerr 'unable to enumerate USB device|device descriptor read/(64|all), error|device not accepting address|Cannot enable\. Maybe the USB cable is bad|disabled by hub'
  klog_n oc 'over-current condition|overcurrent|over-current change'
  klog_n storm 'usb [0-9.-]+: USB disconnect, device number'
  if [ "$oc" -gt 0 ]; then res usb:power FAIL "A USB port reported an over-current fault ($oc time(s)): something drew too much power or is shorted." "Unplug everything from USB. Try the devices one at a time; use a powered hub for hard drives. A port that always faults needs repair." "$(klog_grep 'over-current' 1)"
  elif [ "$enumerr" -ge 5 ]; then res usb:errors FAIL "USB devices failed to start $enumerr times (enumeration errors)." "Try another port and cable; avoid unpowered hubs. If all ports do it, update the BIOS and restart." "$(klog_grep 'enumerate|descriptor read' 2 | tr '\n' ';')"
  elif [ "$enumerr" -gt 0 ]; then res usb:errors WARN "A USB device failed to start $enumerr time(s) (cable or port trouble)." "Replug it into a different port with a different cable." "$(klog_grep 'enumerate|descriptor read' 1)"
  fi
  if [ "$storm" -ge 20 ]; then res usb:disconnects WARN "USB devices were unplugged/reconnected $storm times since start (a flaky cable, hub or port)." "Check cables and hubs; unplug devices one by one to find the culprit. Power-saving on USB can also cause this." ""; fi
  if [ "$devs" -eq 0 ] && [ "$enumerr" -eq 0 ]; then
    res usb OK "USB: $ctl controller(s), $roots root hub(s); nothing is plugged in at the moment." "Plug a device in and run again to test the port." ""
  else
    res usb OK "USB: $ctl controller(s), $devs device(s) attached${slow:+; slow: $slow}." "" ""
  fi
}

# ---------------------------------------------------------------- sound (speakers, headphones, microphone)
slh_peak() { od -An -v -td2 -w2 "$1" 2>/dev/null | awk '{v = ($1 < 0) ? -$1 : $1; if (v > m) m = v} END {printf "%d", 100 * m / 32768}'; }
chk_audio() {
  local cards=0 c cardlist="" sinks="" sources="" vol="" muted="" dummy=0 haveserver=0
  if [ -r "$SLH_PROC/asound/cards" ]; then
    cards=$(grep -cE '^ *[0-9]+ \[' "$SLH_PROC/asound/cards" 2>/dev/null); cardlist=$(grep -E '^ *[0-9]+ \[' "$SLH_PROC/asound/cards" | sed 's/^ *[0-9]* \[[^]]*\]: *//' | tr '\n' ';')
  else for c in "$SLH_SYS"/class/sound/card*; do [ -d "$c" ] && cards=$((cards + 1)); done; fi
  if [ "${cards:-0}" -eq 0 ]; then
    local pcisnd=0 s v d cl drv
    while IFS='|' read -r s v d cl drv; do case "$cl" in 0401*|0403*) pcisnd=$((pcisnd + 1)) ;; esac; done < <(slh_pci_list)
    if [ "$pcisnd" -gt 0 ]; then
      res audio FAIL "A sound chip is present but Linux has no sound device for it (driver or firmware missing)." "Install the sound firmware: sudo secure-linux-parts --install  (package alsa-sof-firmware on newer Intel laptops), then restart." "pci sound devices=$pcisnd"
    else res audio NOT-PRESENT "No sound card or speakers were found." "USB headphones or a USB sound adapter will work if you plug one in." ""; fi
    return
  fi
  # the sound server's view
  if have wpctl; then
    local st; st=$(wpctl status 2>/dev/null)
    if [ -n "$st" ]; then
      haveserver=1
      sinks=$(printf '%s\n' "$st" | awk '/Sinks:/{f=1;next} /Sources:|Filters:|Streams:|Video/{f=0} f && /[0-9]+\./{print}' | sed -E 's/^[^[:alnum:]]*//')
      sources=$(printf '%s\n' "$st" | awk '/Sources:/{f=1;next} /Filters:|Streams:|Video/{f=0} f && /[0-9]+\./{print}' | sed -E 's/^[^[:alnum:]]*//')
      printf '%s' "$sinks" | grep -qi 'dummy output\|auto_null' && [ "$(printf '%s\n' "$sinks" | grep -c .)" -le 1 ] && dummy=1
    fi
    vol=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null)
  elif have pactl; then
    haveserver=1; sinks=$(pactl list short sinks 2>/dev/null); sources=$(pactl list short sources 2>/dev/null | grep -v '\.monitor')
    printf '%s' "$sinks" | grep -qi 'auto_null' && dummy=1
    vol=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | head -n1); pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null | grep -qi yes && vol="$vol [MUTED]"
  else need wpctl "sound server status (volume, muted, outputs)" pipewire-utils; fi
  local sof; klog_n sof 'sof-audio-pci.*(error|failed)|sof.*firmware.*(failed|not found)|snd_hda_intel.*(no codecs|codec.*failed)|snd_soc.*(failed|error)'
  local st=OK msg="Sound: ${cardlist:+$cardlist }" todo=""
  if [ "$sof" -gt 0 ]; then st=WARN; msg="${msg}The sound hardware reported $sof error(s) at start-up (often missing firmware)."; todo="Install the sound firmware: sudo secure-linux-parts --install  (alsa-sof-firmware), then restart."; fi
  if [ "$dummy" = 1 ]; then st=FAIL; msg="${msg}The sound system only has a 'Dummy Output': it cannot use the real speakers."; todo="Restart the sound system: systemctl --user restart pipewire wireplumber. If that fails: sudo secure-linux-parts --install, then restart."; fi
  case "$vol" in *MUTED*) [ "$st" = OK ] && { st=WARN; todo="Speakers are muted: press the mute key, or click the speaker icon by the clock."; }; msg="${msg}The default output is muted." ;; esac
  case "$vol" in *"Volume: 0.00"*) [ "$st" = OK ] && { st=WARN; todo="The volume is at 0: turn it up (volume keys or the speaker icon)."; }; msg="${msg}The volume is at zero." ;; esac
  [ -n "$sinks" ] && [ "$dummy" = 0 ] && msg="${msg}Output devices: $(printf '%s\n' "$sinks" | wc -l)."
  [ "$haveserver" = 0 ] && msg="${msg}(sound server not running or not installed, so volume and outputs were not checked)"
  res audio "$st" "$msg" "$todo" "cards=$cards"
  # microphone presence
  local micn=0
  if have arecord; then micn=$(arecord -l 2>/dev/null | grep -c '^card'); fi
  [ -n "$sources" ] && micn=$(( micn > 0 ? micn : $(printf '%s\n' "$sources" | grep -c .) ))
  if [ "$micn" -gt 0 ]; then res audio:microphone OK "Microphone input found ($micn capture device(s))." "" ""
  elif have arecord || [ -n "$sources" ]; then res audio:microphone NOT-PRESENT "No microphone input found." "Plug in a headset or USB microphone; laptops have one built in, so check the privacy key (F4 on many models)." ""
  else need arecord "microphone test" alsa-utils; fi
  # interactive: speakers and mic
  if [ "$INTERACTIVE" = 1 ] && slh_interactive_possible; then
    local snd=/usr/share/sounds/freedesktop/stereo/complete.oga played=0
    slh_info audio_intro "Sound test: turn the volume up a little, then click OK. You will hear a short sound."
    if [ -f "$snd" ] && have pw-play; then pw-play "$snd" 2>/dev/null && played=1
    elif [ -f "$snd" ] && have paplay; then paplay "$snd" 2>/dev/null && played=1
    elif have speaker-test; then slh_t 5 speaker-test -t sine -f 660 -l 1 >/dev/null 2>&1; played=1; fi
    slh_scripted && played=1
    if [ "$played" = 1 ]; then
      case "$(slh_ask audio_speaker "Did you hear the sound? (If you have headphones plugged in, listen there.)" "Yes" "No")" in
        yes) res audio:speakers OK "You heard the test sound: the speakers/headphones work." "" "" ;;
        no) res audio:speakers FAIL "You did not hear the test sound." "Check the volume and mute. Plug in headphones to find out whether it is the speakers or the sound system. If headphones also fail, run this check without --full and read the Sound line." "" ;;
      esac
    else res audio:speakers SKIPPED "No program to play a test sound (pw-play, paplay or speaker-test) is installed." "Install: sudo secure-linux-parts --install" ""; fi
    if have arecord && [ "$micn" -gt 0 ]; then
      if [ "$(slh_ask audio_mic_intro "Microphone test: click Start, then say something for 3 seconds." "Start" "Skip")" = yes ]; then
        local raw lvl; raw=$(mktemp)
        slh_t 8 arecord -q -d 3 -f S16_LE -r 16000 -c 1 -t raw "$raw" 2>/dev/null
        lvl=$(slh_peak "$raw"); lvl=${lvl:-0}; rm -f "$raw"
        if [ "$lvl" -ge 3 ]; then res audio:mictest OK "The microphone picked up your voice (peak level ${lvl}%)." "" "peak=$lvl"
        else res audio:mictest FAIL "The microphone recorded almost nothing (peak level ${lvl}%)." "Check Sound settings > Input: the right microphone, not muted, level up. Laptops often have a mic-off key." "peak=$lvl"; fi
      fi
    fi
  fi
}

# ---------------------------------------------------------------- Bluetooth
chk_bluetooth() {
  local hci="" d usbbt=0 blocked="" r rf
  for d in "$SLH_SYS"/class/bluetooth/hci*; do [ -e "$d" ] && hci="$hci${d##*/} "; done
  while IFS='|' read -r _ _ _ _ _ cls _ _; do [ "$cls" = e0 ] && usbbt=$((usbbt + 1)); done < <(slh_usb_list)
  for r in "$SLH_SYS"/class/rfkill/rfkill*; do
    [ "$(slh_rd "$r/type")" = bluetooth ] || continue
    [ "$(slh_rd "$r/hard")" = 1 ] && blocked="$blocked hard"
    [ "$(slh_rd "$r/soft")" = 1 ] && blocked="$blocked soft"
  done
  if [ -z "$hci" ]; then
    if [ "$usbbt" -gt 0 ]; then res bluetooth FAIL "A Bluetooth adapter is plugged in but Linux has not set it up (driver or firmware missing)." "Install: sudo secure-linux-parts --install (bluez and the firmware), restart, and check again." "usb bluetooth class devices=$usbbt"
    else res bluetooth NOT-PRESENT "No Bluetooth adapter found." "A small USB Bluetooth adapter adds it to any computer." ""; fi
    return
  fi
  local st=OK msg="Bluetooth adapter found (${hci% })." todo="" n
  case "$blocked" in *hard*) st=FAIL; msg="$msg It is switched off by a hardware switch or the airplane-mode key."; todo="Press the airplane-mode/wireless key (often Fn+F2 or F12), or find the wireless switch on the side of the laptop." ;;
    *soft*) st=WARN; msg="$msg It is turned off by software."; todo="Turn it on in the Bluetooth settings, or run: rfkill unblock bluetooth" ;; esac
  klog_n n 'Bluetooth: hci[0-9]+: .*(failed|firmware|timeout|Opcode .* failed|command .* tx timeout)'
  if [ "$n" -gt 0 ] && [ "$st" = OK ]; then st=WARN; msg="$msg The adapter logged $n firmware/command error(s) at start."; todo="Update the firmware (sudo dnf upgrade linux-firmware), then restart. Cold-boot (shut down fully) if it stays broken."; fi
  if have bluetoothctl; then
    local sh; sh=$(slh_t 5 bluetoothctl show 2>/dev/null)
    if [ -n "$sh" ]; then
      printf '%s' "$sh" | grep -q 'Powered: no' && [ "$st" = OK ] && { st=WARN; msg="$msg It is powered off."; todo="Turn it on: bluetoothctl power on (or in Bluetooth settings)."; }
      local con; con=$(slh_t 5 bluetoothctl devices Connected 2>/dev/null | wc -l); [ "$con" -gt 0 ] && msg="$msg $con device(s) connected."
    fi
  else need bluetoothctl "Bluetooth status" bluez; fi
  have systemctl && ! systemctl is-active -q bluetooth 2>/dev/null && [ "$st" = OK ] && { st=WARN; msg="$msg The Bluetooth service is not running."; todo="Run: sudo systemctl enable --now bluetooth"; }
  res bluetooth "$st" "$msg" "$todo" "hci=$hci blocked=${blocked:-no}"
}

# ---------------------------------------------------------------- camera
chk_camera() {
  local v nodes="" capture="" idx name usbvid=0 cls
  for v in "$SLH_SYS"/class/video4linux/video*; do
    [ -d "$v" ] || continue
    idx=$(slh_rd "$v/index"); name=$(slh_rd "$v/name")
    nodes="$nodes${v##*/} "
    [ "${idx:-0}" = 0 ] && capture="$capture${v##*/}:$name;"
  done
  while IFS='|' read -r _ _ _ _ _ cls _ _; do [ "$cls" = ef ] && usbvid=$((usbvid + 1)); done < <(slh_usb_list)
  while IFS='|' read -r _ cls _ _; do [ "$cls" = 0e ] && usbvid=$((usbvid + 1)); done < <(slh_usb_ifaces)
  if [ -z "$nodes" ]; then
    if [ "$usbvid" -gt 0 ]; then res camera FAIL "A camera is plugged in but Linux has no video device for it (the uvcvideo driver did not start)." "Unplug and replug it; check 'dmesg' for uvcvideo. Some laptops have a camera on/off key or privacy switch." ""
    else res camera NOT-PRESENT "No camera found." "A USB webcam works if you plug one in. Laptop: check the camera on/off key (F10 on many ASUS models)." ""; fi
    return
  fi
  local st=OK msg="Camera found: ${capture:-$nodes}" todo="" n
  msg=${msg%;}; msg=${msg% }
  klog_n n 'uvcvideo.*(Failed|failed|error|timeout)'
  [ "$n" -gt 0 ] && { st=WARN; msg="$msg It logged $n error(s)."; todo="Replug it or restart. If it is the built-in camera and still fails, the camera switch or cable may be at fault."; }
  if [ "$INTERACTIVE" = 1 ] && slh_interactive_possible; then
    local dev=""; for v in "$SLH_SYS"/class/video4linux/video*; do [ "$(slh_rd "$v/index")" = 0 ] && { dev=$SLH_DEV/${v##*/}; break; }; done
    local tmp; tmp=$(mktemp -d)
    if [ -n "$dev" ] && [ -e "$dev" ] && have ffmpeg; then
      slh_info camera_intro "Camera test: look at the camera and click OK. One picture is taken and shown (it is not saved)."
      if slh_t 15 ffmpeg -loglevel error -f v4l2 -i "$dev" -frames:v 1 -y "$tmp/cam.jpg" 2>/dev/null && [ -s "$tmp/cam.jpg" ]; then
        have xdg-open && slh_gui_ok && { xdg-open "$tmp/cam.jpg" >/dev/null 2>&1 & }
        case "$(slh_ask camera_ok "Could you see yourself in the picture?" "Yes" "No")" in
          yes) msg="$msg The test picture worked." ;;
          no) st=FAIL; msg="$msg The test picture was not right."; todo="Check the camera on/off key or privacy shutter, then try the Camera app." ;;
        esac
      else st=FAIL; msg="$msg It could not take a picture."; todo="Another program may be using it; close video calls and try again. Check the camera key/shutter."; fi
    elif slh_scripted; then
      case "$(slh_ask camera_ok "Could you see yourself in the picture?" "Yes" "No")" in no) st=FAIL; msg="$msg The test picture was not right."; todo="Check the camera on/off key or privacy shutter." ;; esac
    fi
    rm -rf "$tmp"
  fi
  res camera "$st" "$msg" "$todo" "nodes=$nodes"
}

# ---------------------------------------------------------------- SD / memory card readers
chk_sdcard() {
  local m n=0 s v d c drv usbrd="" id vid pid prod man cls
  for m in "$SLH_SYS"/class/mmc_host/mmc*; do [ -d "$m" ] && n=$((n + 1)); done
  while IFS='|' read -r s v d c drv; do case "$drv" in sdhci-pci|rtsx_pci_sdmmc|rtsx_pci|ricoh_mmc|via-sdmmc|sdricoh_cs|tifm_7xx1|rtsx_usb_sdmmc) n=$((n + 1)) ;; esac; done < <(slh_pci_list)
  while IFS='|' read -r id vid pid prod man cls _ _; do printf '%s' "$(slh_lc "$prod")" | grep -qE 'card reader|sd reader|multi.?card|sdxc|microsd' && usbrd="$usbrd$prod; "; done < <(slh_usb_list)
  if [ "$n" -eq 0 ] && [ -z "$usbrd" ]; then res sdcard NOT-PRESENT "No SD/memory-card reader found." "" ""; return; fi
  local cards="" c2
  for c2 in "$SLH_SYS"/class/mmc_host/mmc*/mmc*:*; do [ -d "$c2" ] && cards="$cards$(slh_rd "$c2/type") $(slh_rd "$c2/name"); "; done
  local e; klog_n e 'mmc[0-9]+: .*(error -[0-9]+|timeout|card never left busy|cannot verify)|rtsx.*(error|timeout)'
  if [ "$e" -gt 0 ]; then res sdcard WARN "The card reader logged $e error(s) (a worn card, dirty contacts or a loose card)." "Reseat the card, clean the contacts, try a different card. If every card fails, the reader may be faulty." "$(klog_grep 'mmc[0-9]' 1)"
  elif [ -n "$cards" ]; then res sdcard OK "Card reader found, and a card is inserted: ${cards%; }. Drive speed and health are in the Storage lines." "" ""
  else res sdcard OK "Card reader found${usbrd:+ ($usbrd)}. No card inserted, so it was not tested." "Put a card in and run again." ""; fi
}

# ---------------------------------------------------------------- fingerprint reader
chk_fingerprint() {
  local found="" id vid pid prod man cls
  while IFS='|' read -r id vid pid prod man cls _ _; do
    if printf '%s %s' "$(slh_lc "$prod")" "$(slh_lc "$man")" | grep -qE 'finger|fprint|biometric|validity|authentec|egis|upek' || case "$vid" in 138a|27c6|1c7a|08ff|147e) true ;; *) false ;; esac; then
      found="$found$(slh_pretty_name "${prod:-$vid:$pid}") ($vid:$pid); "
    fi
  done < <(slh_usb_list)
  if [ -z "$found" ]; then res fingerprint NOT-PRESENT "No fingerprint reader found." "" ""; return; fi
  local st=OK msg="Fingerprint reader found: ${found%; }." todo=""
  if have fprintd-list; then
    local u; u=${SUDO_USER:-${USER:-root}}
    local o; o=$(slh_t 8 fprintd-list "$u" 2>&1)
    if printf '%s' "$o" | grep -qi 'No devices available'; then st=WARN; msg="$msg But the fingerprint software does not support this reader (yet)."; todo="Check the supported list at fprint.freedesktop.org/supported-devices.html; a newer libfprint may be needed (system updates bring it)."
    elif printf '%s' "$o" | grep -qi 'no fingerprints enrolled\|Fingerprints for user .*: *$'; then msg="$msg It works but no finger is registered for $u."; todo="Register one: Settings > Users > Fingerprint, or: fprintd-enroll"
    else msg="$msg The fingerprint software sees it and a finger is registered."; fi
  else st=WARN; msg="$msg The fingerprint software (fprintd) is not installed."; todo="Install it: sudo secure-linux-parts --install"; fi
  res fingerprint "$st" "$msg" "$todo" ""
}

# ---------------------------------------------------------------- built-in sensors (accelerometer, light, gyroscope)
chk_sensors() {
  local d n="" name found=0
  for d in "$SLH_SYS"/bus/iio/devices/iio:device*; do
    [ -d "$d" ] || continue
    name=$(slh_rd "$d/name"); found=1
    case "$name" in *accel*) n="$n screen-rotation sensor (accelerometer);" ;; *als*|*light*|*illum*) n="$n ambient light sensor (auto-brightness);" ;; *gyro*) n="$n gyroscope;" ;; *magn*|*compass*) n="$n compass;" ;; *incli*) n="$n tilt sensor;" ;; *) n="$n $name;" ;; esac
  done
  if [ "$found" = 0 ]; then res sensors NOT-PRESENT "No built-in motion or light sensors found (normal for desktops and most non-convertible laptops)." "" ""; return; fi
  if have systemctl && ! systemctl is-active -q iio-sensor-proxy 2>/dev/null && ! { have monitor-sensor && slh_t 3 monitor-sensor --accel 2>/dev/null | grep -q .; }; then
    res sensors WARN "Sensors found:${n%;} but the program that uses them (iio-sensor-proxy) is not running, so the screen won't rotate or auto-dim." "Install/start it: sudo secure-linux-parts --install" "$n"
  else res sensors OK "Sensors found:${n%;}." "" ""; fi
}

# ---------------------------------------------------------------- printers and scanners
chk_printers() {
  local prn=0 scn=0 id cls sub drv names="" vid pid prod man dcls
  while IFS='|' read -r id cls sub drv; do
    case "$cls" in 07) prn=$((prn + 1)); names="$names$id " ;; 06) scn=$((scn + 1)) ;; esac
  done < <(slh_usb_ifaces)
  local queues=0 lp=""
  if have lpstat; then lp=$(lpstat -p 2>/dev/null); queues=$(printf '%s\n' "$lp" | grep -c '^printer '); else need lpstat "printer queues" cups; fi
  local scanners=""
  if have scanimage; then scanners=$(slh_t 10 scanimage -L 2>/dev/null | grep -c "^device"); fi
  if [ "$prn" -eq 0 ] && [ "$scn" -eq 0 ] && [ "$queues" -eq 0 ] && [ "${scanners:-0}" -eq 0 ]; then
    res printers NOT-PRESENT "No printer or scanner found." "Plug in a USB printer or scanner (network printers are found automatically when you add a printer in Settings)." ""
    return
  fi
  if [ "$prn" -gt 0 ] || [ "$queues" -gt 0 ]; then
    local st=OK msg="" todo=""
    if [ "$queues" -gt 0 ]; then
      msg="$queues printer(s) set up."
      if printf '%s\n' "$lp" | grep -qiE 'disabled|stopped'; then st=WARN; msg="$msg At least one is disabled/stopped."; todo="Open Settings > Printers and resume it, or run: cupsenable PRINTERNAME. Often the printer is off, out of paper, or the cable is out."; fi
      have lpstat && lpstat -o 2>/dev/null | grep -q . && { [ "$st" = OK ] && st=WARN; msg="$msg There are jobs waiting in the queue."; todo="${todo:+$todo }Clear a stuck job with: cancel -a"; }
    elif [ "$prn" -gt 0 ]; then st=WARN; msg="A USB printer is plugged in but no printer is set up (or the printing system is not installed)."; todo="Install printing software: sudo secure-linux-parts --install. Then add it in Settings > Printers."; fi
    if have systemctl && [ "$prn$queues" != 00 ] && ! systemctl is-active -q cups.service 2>/dev/null && ! systemctl is-active -q cups.socket 2>/dev/null && have lpstat; then st=WARN; msg="$msg The printing service (CUPS) is not running."; todo="${todo:+$todo }Run: sudo systemctl enable --now cups.socket"; fi
    res printers:printer "$st" "$msg" "$todo" "usb printer interfaces=$prn queues=$queues"
  fi
  if [ "$scn" -gt 0 ] || [ "${scanners:-0}" -gt 0 ]; then
    if [ "${scanners:-0}" -gt 0 ]; then res printers:scanner OK "$scanners scanner(s) found and usable." "" ""
    elif have scanimage; then res printers:scanner WARN "A scanner is plugged in but the scanning software cannot use it yet." "Install scanner drivers: sudo secure-linux-parts --install (sane-backends; HP needs hplip). Then run: scanimage -L" ""
    else res printers:scanner WARN "A scanner is plugged in but the scanning software (SANE) is not installed." "Install it: sudo secure-linux-parts --install" ""; fi
  fi
}

# ---------------------------------------------------------------- Thunderbolt / USB4
chk_thunderbolt() {
  local present=0 d s v dv c drv dev unauth=""
  while IFS='|' read -r s v dv c drv; do case "$c" in 0c0340*) present=1 ;; esac; [ "$drv" = thunderbolt ] && present=1; done < <(slh_pci_list)
  for d in "$SLH_SYS"/bus/thunderbolt/devices/*; do [ -e "$d" ] && present=1; done
  [ "$present" = 0 ] && { res thunderbolt NOT-PRESENT "No Thunderbolt/USB4 ports found." "" ""; return; }
  local n=0
  for d in "$SLH_SYS"/bus/thunderbolt/devices/[0-9]*-[0-9]*; do
    [ -e "$d" ] || continue; n=$((n + 1))
    [ "$(slh_rd "$d/authorized")" = 0 ] && unauth="$unauth$(slh_rd "$d/device_name"); "
  done
  if [ -n "$unauth" ]; then res thunderbolt WARN "A Thunderbolt device is waiting for approval: ${unauth%; }." "Approve it in Settings > Thunderbolt, or run: boltctl enroll <uuid>. Only approve devices you plugged in yourself." "$n devices"
  else res thunderbolt OK "Thunderbolt/USB4 controller found; $n device(s) attached." "" ""; fi
}
