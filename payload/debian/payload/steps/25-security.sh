#!/bin/bash
# 25-security.sh (Debian) - AppArmor, and remote login protection (SSH + fail2ban) on the home network only.
# The Fedora setup's NordVPN, WARP and OpenSnitch are NOT part of the Debian fallback (old, small PCs).
# Sourced by setup.sh: no exit, use return.
[ "$SL_MODE" = early ] && return 0
SECF=$SL_ROOT/files/security

sl_step "AppArmor (limits what a hacked program can touch)"
sl_pkg_install --no-recommends apparmor
sl_enable apparmor.service

# ---------------------------------------------------------------- USB device control + security event log
sl_step "USB device control and security event logging"
sl_enable secure-linux-security-audit.timer
if [ "$(sl_choice_get usbguard yes)" = no ]; then
  echo "USBGuard is switched off by your saved choice; the security report keeps that choice visible."
  systemctl -q is-enabled usbguard.service 2>/dev/null && try systemctl disable --now usbguard.service
else
  sl_pkg_install --no-recommends usbguard
  sl_install_file "$SECF/usbguard-daemon.conf" "$R/etc/usbguard/usbguard-daemon.conf" 0600
  # Preserve devices already attached (including the install keyboard and disk); block only newly inserted ones.
  if [ ! -s "$R/etc/usbguard/rules.conf" ]; then
    _s_usb_rules=$(mktemp)
    if usbguard generate-policy > "$_s_usb_rules" 2>/dev/null && [ -s "$_s_usb_rules" ]; then
      install -D -m 0600 "$_s_usb_rules" "$R/etc/usbguard/rules.conf"
    else
      echo "FAILED: couldn't create USBGuard's initial allowed-device list; not enabling a blank block-everything policy" | tee -a "$SL_FAILS" >&2
    fi
    rm -f "$_s_usb_rules"
    unset _s_usb_rules
  fi
  [ -s "$R/etc/usbguard/rules.conf" ] && sl_enable usbguard.service
fi
sl_pkg_install --no-recommends auditd
sl_install_file "$SECF/secure-linux.rules" "$R/etc/audit/rules.d/secure-linux.rules" 0600
sl_enable auditd.service

# ---------------------------------------------------------------- SSH (older PCs: reachable from the home network only)
if [ "$(sl_choice_get ssh_server yes)" = yes ]; then
  sl_step "Remote login protection (SSH, fail2ban)"
  sl_pkg_install --no-recommends openssh-server fail2ban python3-systemd
  sl_install_file "$SECF/ssh/40-secure-linux.conf" "$R/etc/ssh/sshd_config.d/40-secure-linux.conf" 0600
  if command -v sshd >/dev/null 2>&1 && ! sshd -t 2>/dev/null; then
    echo "FAILED: SSH settings test failed; removing ours so SSH keeps working" | tee -a "$SL_FAILS"
    rm -f "$R/etc/ssh/sshd_config.d/40-secure-linux.conf"
  fi
  sl_install_file "$SECF/ssh/fail2ban-sshd.local" "$R/etc/fail2ban/jail.d/sshd.local" 0644
  sl_enable ssh.service
  try systemctl reload-or-restart ssh.service
  sl_enable fail2ban.service
  # SSH is only allowed from the home network (build.conf HOME_SUBNET), or from private address ranges
  _s_net=$(sl_build_get HOME_SUBNET)
  if printf '%s' "$_s_net" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$'; then
    sl_ufw_allow_from "$_s_net" 22/tcp
  else
    for _s_net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do sl_ufw_allow_from "$_s_net" 22/tcp; done
  fi
fi
unset _s_net
return 0
