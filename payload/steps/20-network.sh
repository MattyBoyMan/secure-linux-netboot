#!/bin/bash
# 20-network.sh (owner: security): encrypted DNS, network privacy, kernel hardening, Wi-Fi country,
# firewall zones for home vs away, and the network dispatcher. Applies to full, lite and atomic.
# Sourced by setup.sh: no exit, use return.
[ "$SL_MODE" = early ] && return 0
. "$SL_ROOT/files/security/lib-security.sh"
SECF=$SL_ROOT/files/security

# ---------------------------------------------------------------- encrypted DNS
sl_step "Encrypted DNS"
# Old single-script setup wrote this file with a global ~. that fights the VPN's DNS: replace it.
[ -f "$SEC_PREFIX/etc/systemd/resolved.conf.d/10-encrypted-dns.conf" ] && try rm -f "$SEC_PREFIX/etc/systemd/resolved.conf.d/10-encrypted-dns.conf"
[ -f "$SEC_PREFIX/etc/systemd/resolved.conf.d/10-encrypted-dns.conf.off" ] && try rm -f "$SEC_PREFIX/etc/systemd/resolved.conf.d/10-encrypted-dns.conf.off"
dns_before=$(cat "$SEC_DNS_CONF" "$SEC_DNS_FAMILY" 2>/dev/null | md5sum)
sl_install_file "$SECF/resolved/10-secure-linux-dns.conf" "$SEC_DNS_CONF" 0644
# Family filter chosen (secure-linux-dns family on): keep its drop-in in place on repair runs
[ "$(sl_choice_get family_dns no)" = yes ] && sl_install_file "$SECF/resolved/15-secure-linux-family.conf" "$SEC_DNS_FAMILY" 0644
sl_install_file "$SECF/polkit/org.securelinux.security.policy" "$SEC_PREFIX/usr/share/polkit-1/actions/org.securelinux.security.policy" 0644
if [ "$dns_before" != "$(cat "$SEC_DNS_CONF" "$SEC_DNS_FAMILY" 2>/dev/null | md5sum)" ]; then
  # reload keeps the per-connection DNS that NetworkManager and VPN apps set; restart only if reload isn't possible
  try systemctl reload-or-restart systemd-resolved
fi
# Fedora points /etc/resolv.conf at systemd-resolved; say so in the log if something changed that
if [ "$(readlink "$SEC_PREFIX/etc/resolv.conf" 2>/dev/null)" != ../run/systemd/resolve/stub-resolv.conf ] \
   && ! grep -q cloudflare-warp "$SEC_PREFIX/etc/resolv.conf" 2>/dev/null; then
  echo "Note: /etc/resolv.conf isn't the systemd-resolved stub; restoring it so encrypted DNS is used."
  try ln -sfn ../run/systemd/resolve/stub-resolv.conf "$SEC_PREFIX/etc/resolv.conf"
fi
try systemctl start --no-block secure-linux-dns-sync.path
try "$SL_ROOT/bin/secure-linux-dns" sync

# ---------------------------------------------------------------- network privacy + kernel hardening
sl_step "Network privacy and kernel hardening"
[ -f "$SEC_PREFIX/etc/NetworkManager/conf.d/90-privacy.conf" ] && try rm -f "$SEC_PREFIX/etc/NetworkManager/conf.d/90-privacy.conf"
nm_before=$(md5sum "$SEC_PREFIX/etc/NetworkManager/conf.d/90-secure-linux-privacy.conf" 2>/dev/null)
sl_install_file "$SECF/networkmanager/90-secure-linux-privacy.conf" "$SEC_PREFIX/etc/NetworkManager/conf.d/90-secure-linux-privacy.conf" 0644
# takes effect at the next connection; a reload doesn't drop the current one
[ "$nm_before" != "$(md5sum "$SEC_PREFIX/etc/NetworkManager/conf.d/90-secure-linux-privacy.conf" 2>/dev/null)" ] && try systemctl reload NetworkManager

[ -f "$SEC_PREFIX/etc/sysctl.d/90-hardening.conf" ] && try rm -f "$SEC_PREFIX/etc/sysctl.d/90-hardening.conf"
sl_install_file "$SECF/sysctl/90-secure-linux-hardening.conf" "$SEC_PREFIX/etc/sysctl.d/90-secure-linux-hardening.conf" 0644
try sysctl -q --load="$SEC_PREFIX/etc/sysctl.d/90-secure-linux-hardening.conf"

# Wi-Fi country (allowed channels and power). Applied from the next start; set now too where possible.
regdom=$(sl_build_get REGDOM AU | tr '[:lower:]' '[:upper:]')
printf '%s' "$regdom" | grep -E "^[A-Z]{2}$" >/dev/null || regdom=AU
printf '# Secure Linux: Wi-Fi country (build.conf REGDOM)\noptions cfg80211 ieee80211_regdom=%s\n' "$regdom" \
  | sl_write_file "$SEC_PREFIX/etc/modprobe.d/secure-linux-regdom.conf" 0644
command -v iw >/dev/null 2>&1 && iw reg set "$regdom" 2>/dev/null

# Avahi (local network names): never announce the computer model or a "workstation" record.
# Avahi is also stopped completely on networks that aren't home (dispatcher below).
AVAHI_CONF=$SEC_PREFIX/etc/avahi/avahi-daemon.conf
if [ -f "$AVAHI_CONF" ]; then
  for kv in publish-hinfo=no publish-workstation=no; do
    k=${kv%%=*}
    if grep -qE "^[[:space:]]*$k=" "$AVAHI_CONF"; then
      grep -qxE "[[:space:]]*$kv" "$AVAHI_CONF" || try sed -i -E "s/^[[:space:]]*$k=.*/$kv/" "$AVAHI_CONF"
    elif grep -q '^\[publish\]' "$AVAHI_CONF"; then
      try sed -i "/^\[publish\]/a $kv" "$AVAHI_CONF"
    else
      printf '\n[publish]\n%s\n' "$kv" >> "$AVAHI_CONF"
    fi
  done
fi

# ---------------------------------------------------------------- firewall: home vs away
sl_step "Firewall: home and away networks"
sec_fw() {   # firewall-cmd --permanent ... while firewalld runs, firewall-offline-cmd otherwise
  if firewall-cmd --state >/dev/null 2>&1; then firewall-cmd --permanent "$@"; else firewall-offline-cmd "$@"; fi
}
sec_fw_add() {   # sec_fw_add ZONE service|port VALUE   (only if missing)
  sec_fw --zone="$1" --query-"$2"="$3" >/dev/null 2>&1 || try sec_fw --zone="$1" --add-"$2"="$3"
}
sec_fw_del() {
  sec_fw --zone="$1" --query-"$2"="$3" >/dev/null 2>&1 && try sec_fw --zone="$1" --remove-"$2"="$3"
  return 0
}
if ! command -v firewall-cmd >/dev/null 2>&1; then
  sl_dnf_install firewalld
fi
if command -v firewall-cmd >/dev/null 2>&1; then
  sl_enable firewalld.service
  if [ "$(firewall-cmd --get-default-zone 2>/dev/null || firewall-offline-cmd --get-default-zone 2>/dev/null)" != public ]; then
    if firewall-cmd --state >/dev/null 2>&1; then try firewall-cmd --set-default-zone=public
    else try firewall-offline-cmd --set-default-zone=public; fi
  fi
  all_services=" $(sec_fw --get-services 2>/dev/null) "
  # Away (public): nothing comes in except IPv6 address set-up
  for s in $(sec_fw --zone=public --list-services 2>/dev/null); do
    [ "$s" = dhcpv6-client ] || sec_fw_del public service "$s"
  done
  for p in $(sec_fw --zone=public --list-ports 2>/dev/null); do sec_fw_del public port "$p"; done
  sec_fw_add public service dhcpv6-client
  # Home: phone apps, printers, local names (+ SSH on the older PCs)
  home_services="dhcpv6-client mdns ipp-client syncthing kdeconnect"
  [ "$SL_PROFILE" = lite ] && home_services="$home_services ssh"
  for s in $home_services; do
    if [[ "$all_services" == *" $s "* ]]; then sec_fw_add home service "$s"
    elif [ "$s" = kdeconnect ]; then sec_fw_add home port 1714-1764/tcp; sec_fw_add home port 1714-1764/udp
    fi
  done
  sec_fw_add home port 53317/tcp     # LocalSend
  sec_fw_add home port 53317/udp
  sec_fw_del home service samba-client
  [ "$SL_PROFILE" = lite ] || sec_fw_del home service ssh

  # Away: also stop this computer from ANNOUNCING itself (KDE Connect, LocalSend, Syncthing discovery, mDNS)
  pol=sl-quiet-away
  if ! sec_fw --get-policies 2>/dev/null | tr ' ' '\n' | grep -x "$pol" >/dev/null; then
    try sec_fw --new-policy="$pol"
  fi
  sec_fw --policy="$pol" --query-ingress-zone=HOST >/dev/null 2>&1 || try sec_fw --policy="$pol" --add-ingress-zone=HOST
  sec_fw --policy="$pol" --query-egress-zone=public >/dev/null 2>&1 || try sec_fw --policy="$pol" --add-egress-zone=public
  for r in 'port port="1714-1764" protocol="udp"' 'port port="1714-1764" protocol="tcp"' \
           'port port="53317" protocol="udp"' 'port port="53317" protocol="tcp"' \
           'port port="21027" protocol="udp"' 'port port="5353" protocol="udp"'; do
    rule="rule $r reject"
    sec_fw --policy="$pol" --query-rich-rule="$rule" >/dev/null 2>&1 || try sec_fw --policy="$pol" --add-rich-rule="$rule"
  done
  firewall-cmd --state >/dev/null 2>&1 && try firewall-cmd --reload
fi

# ---------------------------------------------------------------- home Wi-Fi + dispatcher
sl_step "Home network"
sl_install_file "$SECF/networkmanager/50-secure-linux" "$SEC_PREFIX/etc/NetworkManager/dispatcher.d/50-secure-linux" 0755
home_ssid=$(sl_choice_get home_ssid "$(sl_build_get HOME_WIFI_SSID)")
[ "$home_ssid" = - ] && home_ssid=""
if [ -n "$home_ssid" ] && command -v nmcli >/dev/null 2>&1; then
  while IFS=: read -r uuid ctype; do
    [ "$ctype" = 802-11-wireless ] || continue
    [ "$(nmcli -g 802-11-wireless.ssid connection show "$uuid" 2>/dev/null)" = "$home_ssid" ] || continue
    z=$(nmcli -g connection.zone connection show "$uuid" 2>/dev/null)
    if [ -z "$z" ]; then
      try nmcli connection modify "$uuid" connection.zone home
      dev=$(nmcli -g GENERAL.DEVICES connection show "$uuid" 2>/dev/null)
      [ -n "$dev" ] && nmcli device reapply "$dev" >/dev/null 2>&1
    fi
  done < <(nmcli -t -f UUID,TYPE connection show 2>/dev/null)
  [ "$(sl_choice_get home_ssid)" ] || sl_choice_set home_ssid "$home_ssid"
fi
"$SEC_PREFIX/etc/NetworkManager/dispatcher.d/50-secure-linux" "" refresh >/dev/null 2>&1
return 0
