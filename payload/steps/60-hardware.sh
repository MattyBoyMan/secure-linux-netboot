# shellcheck shell=bash
# 60-hardware: battery charge limit, tools for the first-login hardware check. Owned by: experience.
# The boot unit secure-linux-battery.service is installed/enabled by 00-early.sh from files/experience.
#
# Known Zenbook UM3402YA kernel options, documented in the guide but NOT applied (only if problems appear):
#   mt7921e.disable_aspm=1                    MT7922 Wi-Fi drops or slow resume
#   nvme_core.default_ps_max_latency_us=0     WD SN770 disappearing after suspend (costs some battery)
[ "$SL_MODE" = early ] && return 0
. "$SL_ROOT/files/experience/exp-lib.sh"

# tuned-ppd (Fedora 41+ replaced power-profiles-daemon): /etc/tuned/ppd.conf maps the PPD profiles
# (power-saver / balanced / performance) to TuneD profiles, with a [battery] section used on battery.
# We set "balanced" on battery to TuneD's powersave profile (choice power_battery_saver=yes, default),
# or back to Fedora's balanced-battery (no). VERIFY ppd.conf format on Fedora 44 (tuned >= 2.23).
_exp60_ppd() {
  local f="$SL_R/etc/tuned/ppd.conf" val new
  [ -f "$f" ] || return 1
  if [ "$(sl_choice_get power_battery_saver yes)" = yes ]; then val=powersave; else val=balanced-battery; fi
  new=$(awk -v v="$val" '
    /^\[/ { if (insec && !done) { print "balanced=" v; done = 1 }
            insec = ($0 == "[battery]"); print; next }
    insec && /^balanced[ 	]*=/ { if (!done) { print "balanced=" v; done = 1 }; next }
    { print }
    END { if (!done) { if (!insec) { print ""; print "[battery]" }; print "balanced=" v } }' "$f")
  if [ "$new" != "$(cat "$f")" ]; then
    printf '%s\n' "$new" > "$f"; echo "tuned-ppd: on battery, Balanced now uses TuneD '$val'"
    try systemctl try-restart tuned-ppd.service
  fi
  return 0
}

_exp60() {
  sl_step "Checking the laptop hardware"
  local u; u=$(sl_user)

  if ! sl_is_atomic; then
    exp_substep "Installing hardware check tools"
    #   iw: Wi-Fi band; alsa-utils: microphone test; v4l-utils: webcam; pipewire-utils: pw-play/wpctl
    sl_dnf_install iw alsa-utils v4l-utils pipewire-utils
  fi

  # Results of secure-linux-hwtest (run by the user) are read by secure-linux-diag: user-writable file.
  mkdir -p "$SL_STATE"
  [ -f "$SL_STATE/hwtest.txt" ] || : > "$SL_STATE/hwtest.txt"
  chown "$u:" "$SL_STATE/hwtest.txt" 2>/dev/null; chmod 0644 "$SL_STATE/hwtest.txt"

  # AMD P-State in "active" mode (EPP) lets the Ryzen pick its own speed: cooler, longer battery (#38).
  # Fedora's kernel normally uses it already; only if not, ask for it on the kernel command line.
  if [ "$SL_PROFILE" = full ] && [ "$(sl_choice_get power_tuning yes)" = yes ] && grep -q AuthenticAMD "$SL_PROC/cpuinfo" 2>/dev/null; then
    local st; st=$(cat "$SL_SYS/devices/system/cpu/amd_pstate/status" 2>/dev/null)
    if [ "$st" = active ]; then echo "AMD P-State: active (EPP)"
    elif grep -qw 'amd_pstate=active' "$SL_PROC/cmdline" 2>/dev/null || grubby --info=DEFAULT 2>/dev/null | grep -q 'amd_pstate=active'; then
      echo "AMD P-State: active mode requested; takes effect after a restart (status now: ${st:-not loaded})"
    elif command -v grubby >/dev/null 2>&1; then
      exp_substep "Turning on the processor's power saving (AMD P-State)"
      try grubby --update-kernel=ALL --args=amd_pstate=active && sl_event amd-pstate "Restart for better battery life" "A processor power-saving setting was switched on. It starts working after your next restart."
    fi
  fi

  if exp_battery_file >/dev/null; then
    exp_substep "Setting up battery care"
    # Power profile on battery vs plugged in: tuned-ppd's own battery mapping, or (older systems with
    # power-profiles-daemon) our udev rule calls "secure-linux-battery ac-changed".
    _exp60_ppd || echo "No tuned-ppd: battery/AC power profile switching handled by secure-linux-battery ac-changed"
    local rules="$SL_R/etc/udev/rules.d/90-secure-linux-battery.rules"
    if ! cmp -s "$SL_EXP/90-secure-linux-battery.rules" "$rules"; then
      sl_install_file "$SL_EXP/90-secure-linux-battery.rules" "$rules"
      command -v udevadm >/dev/null 2>&1 && try udevadm control --reload
    fi
    # Re-apply a saved limit now (the wizard asks the question; nothing is chosen for the user here).
    "$SL_BIN/secure-linux-battery" apply
  fi
  return 0
}
_exp60; unset -f _exp60 _exp60_ppd
return 0
