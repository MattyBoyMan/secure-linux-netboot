#!/bin/bash
# 25-security.sh (owner: security): disk-encryption checks, SSH protection (older PCs), NordVPN,
# Cloudflare WARP + cloudflared, and network protection (OpenSnitch app firewall, on by default on full).
# Sourced by setup.sh: no exit, use return.
[ "$SL_MODE" = early ] && return 0
. "$SL_ROOT/files/security/lib-security.sh"
SECF=$SL_ROOT/files/security
SEC_USER=$(sl_user)

# ---------------------------------------------------------------- disk encryption + Secure Boot
sl_step "Disk encryption safety checks"
sl_dnf_install cryptsetup qrencode libfido2 tpm2-tss mokutil openssl
if luks_dev=$(sec_luks_dev); then
  if sec_luks_has "$luks_dev" recovery; then
    sl_clear luks-recovery-key
    [ "$(sl_choice_get recovery_key_done no)" = yes ] || sl_choice_set recovery_key_done yes
  else
    sl_alert luks-recovery-key "Make a spare key for your disk" \
      "If you ever forget your disk password, everything on this computer is lost. A recovery key prevents that and takes 2 minutes." \
      "Run: secure-linux-recovery-key   (or choose 'Make a disk recovery key' in Secure Linux Status)"
  fi
else
  sl_clear luks-recovery-key
  echo "No encrypted (LUKS) disk found; skipping the recovery key check."
fi
# Ventoy key removal scheduled before the last restart: confirm it's gone
[ "$(sl_choice_get mok_removed no)" = pending ] && "$SL_ROOT/bin/secure-linux-mok-remove" check

# ---------------------------------------------------------------- SSH (older PCs only)
if [ "$SL_PROFILE" = lite ] && ! sl_is_atomic; then
  sl_step "SSH remote login protection"
  sl_dnf_install openssh-server fail2ban
  # The old single-script setup used this name; same settings now live in 40-secure-linux.conf
  [ -f "$SEC_PREFIX/etc/ssh/sshd_config.d/50-hardening.conf" ] && try rm -f "$SEC_PREFIX/etc/ssh/sshd_config.d/50-hardening.conf"
  sl_install_file "$SECF/ssh/40-secure-linux.conf" "$SEC_PREFIX/etc/ssh/sshd_config.d/40-secure-linux.conf" 0600
  if command -v sshd >/dev/null 2>&1 && ! sshd -t 2>/dev/null; then
    echo "FAILED: SSH settings test failed; removing ours so SSH keeps working" | tee -a "$SL_FAILS"
    rm -f "$SEC_PREFIX/etc/ssh/sshd_config.d/40-secure-linux.conf"
  fi
  sl_install_file "$SECF/ssh/fail2ban-sshd.local" "$SEC_PREFIX/etc/fail2ban/jail.d/sshd.local" 0644
  sl_enable sshd.service
  try systemctl reload-or-restart sshd.service
  sl_enable fail2ban.service
  # SSH is only allowed in the firewall's home zone (20-network.sh)
fi

# ---------------------------------------------------------------- NordVPN
sl_step "NordVPN"
if sl_is_atomic; then
  echo "Note: NordVPN isn't installed on the atomic setup (no system packages there). Use the NordVPN website guide if needed."
else
  if ! rpm -q nordvpn >/dev/null 2>&1; then
    if ! rpm -q nordvpn-release >/dev/null 2>&1; then
      try rpm --import https://repo.nordvpn.com/gpg/nordvpn_public.asc
      try dnf -y install https://repo.nordvpn.com/yum/nordvpn/centos/noarch/Packages/n/nordvpn-release-1.0.0-1.noarch.rpm
    fi
  fi
  if sl_is_arm; then
    # Apple Silicon / ARM: NordVPN's repository may have no ARM build. Ask first; never record a failure for "not offered".
    if rpm -q nordvpn >/dev/null 2>&1; then sl_unskip_app NordVPN
    elif dnf -q list --available nordvpn >/dev/null 2>&1; then sl_dnf_install nordvpn && sl_unskip_app NordVPN
    else sl_skip_app NordVPN "NordVPN doesn't offer a version for this type of computer (Apple Silicon / ARM). Everything else keeps working"
    fi
    if [ "$SL_PROFILE" = full ]; then
      if rpm -q nordvpn-gui >/dev/null 2>&1; then sl_unskip_app nordvpn-gui
      elif dnf -q list --available nordvpn-gui >/dev/null 2>&1; then dnf -y install nordvpn-gui || echo "Note: NordVPN window app not available; the command line and Secure Linux VPN still work."
      else sl_skip_app nordvpn-gui "the NordVPN window app doesn't offer a version for this type of computer (Apple Silicon / ARM)"
      fi
    fi
  else
  sl_dnf_install nordvpn
  [ "$SL_PROFILE" = full ] && { rpm -q nordvpn-gui >/dev/null 2>&1 || dnf -y install nordvpn-gui || echo "Note: NordVPN window app not available; the command line and Secure Linux VPN still work."; }
  fi
  if getent group nordvpn >/dev/null 2>&1 && [ -n "$SEC_USER" ] && ! id -nG "$SEC_USER" 2>/dev/null | grep -w nordvpn >/dev/null; then
    try usermod -aG nordvpn "$SEC_USER"
  fi
  systemctl cat nordvpnd.socket >/dev/null 2>&1 && sl_enable nordvpnd.socket
  systemctl cat nordvpnd.service >/dev/null 2>&1 && sl_enable nordvpnd.service
  # Signed in already (repair run)? Re-apply LAN discovery, home subnet, saved kill switch choice. Never connects.
  command -v nordvpn >/dev/null 2>&1 && "$SL_ROOT/bin/secure-linux-vpn" _apply
fi

# ---------------------------------------------------------------- Cloudflare WARP + cloudflared (laptop)
if [ "$SL_PROFILE" = full ] && ! sl_is_atomic; then
  sl_step "Cloudflare WARP and Tunnel client"
  [ -f "$SEC_PREFIX/etc/yum.repos.d/cloudflare-warp.repo" ] || \
    try bash -c "curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo > '$SEC_PREFIX/etc/yum.repos.d/cloudflare-warp.repo'"
  [ -f "$SEC_PREFIX/etc/yum.repos.d/cloudflared.repo" ] || \
    try bash -c "curl -fsSL https://pkg.cloudflare.com/cloudflared.repo > '$SEC_PREFIX/etc/yum.repos.d/cloudflared.repo'"
  if sl_is_arm; then
    # ARM: install only what the repositories really offer; say plainly what is missing (no failure recorded)
    _sec_cf_ok=()
    for _sec_cf in cloudflare-warp cloudflared; do
      if rpm -q "$_sec_cf" >/dev/null 2>&1; then sl_unskip_app "$_sec_cf"
      elif dnf -q list --available "$_sec_cf" >/dev/null 2>&1; then _sec_cf_ok+=("$_sec_cf")
      else sl_skip_app "$_sec_cf" "Cloudflare doesn't offer $_sec_cf for this type of computer (Apple Silicon / ARM)"
      fi
    done
    [ ${#_sec_cf_ok[@]} -gt 0 ] && sl_dnf_install "${_sec_cf_ok[@]}"
    unset _sec_cf _sec_cf_ok
  else
  sl_dnf_install cloudflare-warp cloudflared
  fi
  if systemctl cat warp-svc.service >/dev/null 2>&1; then
    if [ "$(sl_choice_get warp no)" = yes ]; then
      sl_enable warp-svc.service
    else
      # Installed but off until you choose Cloudflare WARP (never alongside NordVPN)
      if systemctl -q is-enabled warp-svc.service 2>/dev/null || systemctl -q is-active warp-svc.service 2>/dev/null; then
        try systemctl disable --now warp-svc.service
      fi
    fi
  fi
fi

# ---------------------------------------------------------------- Network protection (OpenSnitch)
# ON by default on the full profile (asks once per new app; block lists for dangerous sites). On lite it is only the
# quiet background part, and only with 3 GB of memory or more (install.sh checks). Not on atomic.
sl_step "Network protection (OpenSnitch)"
if sl_is_atomic; then
  echo "Note: network protection (OpenSnitch) isn't offered on the atomic setup."
elif [ "$(sl_choice_get opensnitch yes)" = no ]; then
  # Switched off on purpose (secure-linux-choice set opensnitch no). Whatever is installed is left as it is.
  echo "Network protection (OpenSnitch) is switched off by choice; leaving it as it is."
else
  try bash "$SECF/opensnitch/install.sh"
fi
return 0
