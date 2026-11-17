# shellcheck shell=bash
# 53-device-extras: phones, maker boards, 3D printers, radio sticks, computer lights, game streaming and one mouse for two
# computers (ideas 73, 74, 75, 76). Sourced by setup.sh. Owned by: apps-everyday. Safe to run again (repair).
#   Always: the udev rules that let the logged-in person use an Android phone and common maker boards with no password and
#   no group, and the phone helpers (adb, iPhone tools). Only when the matching app is installed: the rule and the home
#   network ports Sunshine needs, the home network port Input Leap needs, and what OpenRGB needs.
#   The apps themselves come from the App Library (apps.d/60-everyday-makers.tsv); this step never installs them. An app added
#   later through Optional apps gets its ports and rules the next time setup or repair runs.
#   Sunshine's own settings page (port 47990) is reached on this computer at https://localhost:47990 and is NOT opened to the network.
#   Ports are opened ONLY in firewalld's "home" zone, so a computer on a cafe or hotel network stays closed.
[ "$SL_MODE" = early ] && return 0
sl_step "Setting up phones, maker boards and other devices"
_dx53_r=${SL_TEST_SYSROOT:-}
_dx53_src="$SL_ROOT/files/devices/udev"
_dx53_rules="$_dx53_r/etc/udev/rules.d"
_dx53_changed=0
_dx53_has_app() { flatpak info --system "$1" >/dev/null 2>&1; }
_dx53_rule() {   # _dx53_rule NAME   put one rule file in place (only counts as a change when the file differs)
  [ -f "$_dx53_src/$1" ] || { echo "FAILED: the device rule $1 is missing from the kit" | tee -a "$SL_FAILS" >&2; return 1; }
  if ! cmp -s "$_dx53_src/$1" "$_dx53_rules/$1" 2>/dev/null; then _dx53_changed=1; fi
  sl_install_file "$_dx53_src/$1" "$_dx53_rules/$1" 0644 \
    || echo "FAILED: install the device rule $1" | tee -a "$SL_FAILS" >&2
}
_dx53_ports() {  # _dx53_ports PORT/proto...   open them in the "home" zone only
  command -v firewall-cmd >/dev/null 2>&1 || { echo "No firewall program found; the ports are not changed."; return 0; }
  local p
  for p in "$@"; do
    firewall-cmd --permanent --zone=home --query-port="$p" >/dev/null 2>&1 \
      || try firewall-cmd --permanent --zone=home --add-port="$p"
    firewall-cmd --zone=home --query-port="$p" >/dev/null 2>&1 \
      || try firewall-cmd --zone=home --add-port="$p"
  done
}

# Phone helpers: adb for Android, libimobiledevice for iPhone (usbmuxd is added by the comfort step too). Online first, then
# the verified drive copy. Atomic computers cannot add packages here; the phone tool then says plainly what is missing.
_dx53_pkgs() {   # _dx53_pkgs LABEL pkg...   add only what is missing; offline with no drive copy it waits quietly (never a failure)
  local label=$1 p missing=(); shift
  sl_is_atomic && return 0
  for p in "$@"; do rpm -q "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if [ ${#missing[@]} -eq 0 ]; then sl_unskip_app "$label"; return 0; fi
  if sl_online || command -v secure-linux-offline-bundle >/dev/null 2>&1; then
    if sl_dnf_install "${missing[@]}"; then sl_unskip_app "$label"
    else echo "The $label could not be added this time. Secure Linux will try again in the next repair."; fi
  else
    sl_skip_app "$label" "Will install when this computer is online"
  fi
  return 0
}
_dx53_pkgs "Phone helper programs" android-tools libimobiledevice-utils usbmuxd

_dx53_rule 70-secure-linux-android.rules
_dx53_rule 70-secure-linux-makers.rules

if _dx53_has_app dev.lizardbyte.app.Sunshine; then
  echo "Sunshine is installed: allowing it to make a virtual keyboard and mouse, and opening its ports on the home network only."
  _dx53_rule 70-secure-linux-uinput.rules
  sl_write_file "$_dx53_r/etc/modules-load.d/secure-linux-uinput.conf" 0644 <<'EOF'
# Secure Linux: Sunshine (game streaming) needs the virtual keyboard and mouse driver. Written by steps/53-device-extras.sh.
uinput
EOF
  [ -z "$_dx53_r" ] && { try modprobe uinput; }
  _dx53_ports 47984/tcp 47989/tcp 48010/tcp 47998/udp 47999/udp 48000/udp 48002/udp 48010/udp
fi

if _dx53_has_app io.github.input_leap.input-leap; then
  echo "Input Leap is installed: opening its port on the home network only."
  _dx53_ports 24800/tcp
fi

if _dx53_has_app org.openrgb.OpenRGB; then
  echo "OpenRGB is installed: adding its device rules."
  _dx53_pkgs "OpenRGB device rules" openrgb-udev-rules
  sl_write_file "$_dx53_r/etc/modules-load.d/secure-linux-openrgb.conf" 0644 <<'EOF'
# Secure Linux: OpenRGB talks to memory and motherboard lights through the i2c-dev driver. Written by steps/53-device-extras.sh.
i2c-dev
EOF
  [ -z "$_dx53_r" ] && { try modprobe i2c-dev; }
fi

if [ "$_dx53_changed" = 1 ] && [ -z "$_dx53_r" ] && command -v udevadm >/dev/null 2>&1; then
  udevadm control --reload >/dev/null 2>&1
  udevadm trigger --subsystem-match=usb --subsystem-match=tty --action=add >/dev/null 2>&1
fi
unset _dx53_r _dx53_src _dx53_rules _dx53_changed
unset -f _dx53_has_app _dx53_rule _dx53_ports _dx53_pkgs
return 0
