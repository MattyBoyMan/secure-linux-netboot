#!/bin/bash
# 20-network.sh (Debian) - encrypted DNS, network privacy (random Wi-Fi addresses), kernel hardening,
# Wi-Fi country and the firewall (ufw). Same settings as the Fedora setup, with the Debian tools.
# Sourced by setup.sh: no exit, use return.
[ "$SL_MODE" = early ] && return 0
SECF=$SL_ROOT/files/security

# ---------------------------------------------------------------- encrypted DNS
sl_step "Encrypted DNS"
# systemd-resolved: part of "systemd" in Debian 12, its own package in Debian 13
if [ ! -x "$R/usr/lib/systemd/systemd-resolved" ] && [ ! -x "$R/lib/systemd/systemd-resolved" ]; then
  apt-cache policy systemd-resolved 2>/dev/null | grep -q 'Candidate: [^(]' && sl_pkg_install --no-recommends systemd-resolved
fi
sl_enable systemd-resolved.service
_n_before=$(cat "$R/etc/systemd/resolved.conf.d/10-secure-linux-dns.conf" "$R/etc/systemd/resolved.conf.d/15-secure-linux-family.conf" 2>/dev/null | md5sum)
sl_install_file "$SECF/resolved/10-secure-linux-dns.conf" "$R/etc/systemd/resolved.conf.d/10-secure-linux-dns.conf" 0644
[ "$(sl_choice_get family_dns no)" = yes ] && sl_install_file "$SECF/resolved/15-secure-linux-family.conf" "$R/etc/systemd/resolved.conf.d/15-secure-linux-family.conf" 0644
sl_install_file "$SECF/networkmanager/10-secure-linux-resolved.conf" "$R/etc/NetworkManager/conf.d/10-secure-linux-resolved.conf" 0644
if [ "$_n_before" != "$(cat "$R/etc/systemd/resolved.conf.d/10-secure-linux-dns.conf" "$R/etc/systemd/resolved.conf.d/15-secure-linux-family.conf" 2>/dev/null | md5sum)" ]; then
  try systemctl reload-or-restart systemd-resolved
fi
# Only point the system at systemd-resolved once it is running: never leave the computer without a working resolver
if systemctl is-active -q systemd-resolved 2>/dev/null; then
  if [ "$(readlink "$R/etc/resolv.conf" 2>/dev/null)" != /run/systemd/resolve/stub-resolv.conf ]; then
    echo "Note: pointing /etc/resolv.conf at systemd-resolved so encrypted DNS is used."
    try ln -sfn /run/systemd/resolve/stub-resolv.conf "$R/etc/resolv.conf"
    try systemctl reload-or-restart NetworkManager
  fi
else
  echo "FAILED: systemd-resolved isn't running; encrypted DNS is not active yet (the old DNS setup is untouched)" | tee -a "$SL_FAILS" >&2
fi

# ---------------------------------------------------------------- network privacy + kernel hardening
sl_step "Network privacy and kernel hardening"
_n_nm=$(md5sum "$R/etc/NetworkManager/conf.d/90-secure-linux-privacy.conf" 2>/dev/null)
sl_install_file "$SECF/networkmanager/90-secure-linux-privacy.conf" "$R/etc/NetworkManager/conf.d/90-secure-linux-privacy.conf" 0644
# takes effect at the next connection; a reload doesn't drop the current one
[ "$_n_nm" != "$(md5sum "$R/etc/NetworkManager/conf.d/90-secure-linux-privacy.conf" 2>/dev/null)" ] && try systemctl reload NetworkManager
sl_install_file "$SECF/sysctl/90-secure-linux-hardening.conf" "$R/etc/sysctl.d/90-secure-linux-hardening.conf" 0644
try sysctl -q --load="$R/etc/sysctl.d/90-secure-linux-hardening.conf"

# Wi-Fi country (allowed channels and power)
_n_reg=$(sl_build_get REGDOM AU | tr '[:lower:]' '[:upper:]')
printf '%s' "$_n_reg" | grep -E "^[A-Z]{2}$" >/dev/null || _n_reg=AU
printf '# Secure Linux: Wi-Fi country (build.conf REGDOM)\noptions cfg80211 ieee80211_regdom=%s\n' "$_n_reg" \
  | sl_write_file "$R/etc/modprobe.d/secure-linux-regdom.conf" 0644
command -v iw >/dev/null 2>&1 && iw reg set "$_n_reg" 2>/dev/null
printf 'REGDOMAIN=%s\n' "$_n_reg" | sl_write_file "$R/etc/default/regulatory" 0644

# ---------------------------------------------------------------- firewall (ufw)
sl_step "Firewall"
sl_pkg_install --no-recommends ufw
if command -v ufw >/dev/null 2>&1; then
  grep -q '^DEFAULT_INPUT_POLICY="DROP"' "$R/etc/default/ufw" 2>/dev/null || try ufw default deny incoming
  grep -q '^DEFAULT_OUTPUT_POLICY="ACCEPT"' "$R/etc/default/ufw" 2>/dev/null || try ufw default allow outgoing
  # Home only: names of printers and devices on the local network (mDNS) from private address ranges, nothing else
  for _n_net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do sl_ufw_allow_from "$_n_net" 5353/udp; done
  ufw status 2>/dev/null | grep -q '^Status: active' || try ufw --force enable
  sl_enable ufw.service
fi
unset _n_before _n_nm _n_reg _n_net
return 0
