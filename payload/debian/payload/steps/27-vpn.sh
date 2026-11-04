#!/bin/bash
# 27-vpn.sh (Debian) - VPN choices, per computer type (the same secure-linux-vpn commands as the Fedora setup):
#   WireGuard (wireguard-tools)  every computer: WireGuard is part of Linux itself; NetworkManager imports .conf files
#   NordVPN                      64-bit (amd64). NordVPN's own Debian repository (repo.nordvpn.com) lists a 32-bit build too, but
#                                NordVPN does not officially support 32-bit; it is skipped on i386 unless choice nordvpn_i386=yes
#   Cloudflare WARP              64-bit only (Cloudflare publishes amd64 and arm64), and only if the person chose warp=yes
# Choices: nordvpn (yes|no, default yes on 64-bit), nordvpn_i386 (yes), warp (yes). Sourced by setup.sh: never `exit`.
[ "$SL_MODE" = early ] && return 0

_v_have() { apt-cache policy "$1" 2>/dev/null | grep -q 'Candidate: [^(]'; }
_v_pkgs() {
  local missing=() p
  for p in "$@"; do sl_pkg_installed "$p" || missing+=("$p"); done
  [ ${#missing[@]} -eq 0 ] && return 0
  sl_apt_update
  local want=(); for p in "${missing[@]}"; do if _v_have "$p"; then want+=("$p"); else echo "Note: package $p isn't available in this Debian; skipped."; fi; done
  [ ${#want[@]} -gt 0 ] && sl_pkg_install --no-recommends "${want[@]}"
  return 0
}
_v_repo() {   # _v_repo NAME KEYURL "deb line using @KEY@" -> key + source file; forces an apt update when the source changed
  local name=$1 url=$2 line=$3 key=$R/usr/share/keyrings/$1-archive.asc
  mkdir -p "$R/usr/share/keyrings"
  [ -s "$key" ] || try curl -fsSL "$url" -o "$key"
  SL_CHANGED=0
  sl_write_file "$R/etc/apt/sources.list.d/$name.list" <<EOT
${line//@KEY@//usr/share/keyrings/$name-archive.asc}
EOT
  if [ "$SL_CHANGED" = 1 ]; then SL_APT_UPDATED=""; fi
  return 0
}

sl_step "VPN: WireGuard"
_v_pkgs wireguard-tools qrencode

_v_arch=$(sl_arch)
_v_nord=$(sl_choice_get nordvpn yes)
if [ "$_v_arch" != amd64 ] && [ "$(sl_choice_get nordvpn_i386 no)" != yes ]; then
  echo "Note: NordVPN and Cloudflare WARP are not set up on a 32-bit computer (NordVPN doesn't officially support it, WARP has no 32-bit version). WireGuard works: secure-linux-vpn available."
  _v_nord=no
fi
if [ "$_v_nord" = yes ]; then
  sl_step "VPN: NordVPN"
  if ! sl_pkg_installed nordvpn; then
    if sl_online; then
      _v_repo nordvpn https://repo.nordvpn.com/gpg/nordvpn_public.asc "deb [signed-by=@KEY@] https://repo.nordvpn.com/deb/nordvpn/debian stable main"
      sl_apt_update
      _v_pkgs nordvpn
    else
      echo "FAILED: NordVPN (offline); it installs at the next repair" | tee -a "$SL_FAILS" >&2
    fi
  fi
  if sl_pkg_installed nordvpn; then
    _v_user=$(sl_user)
    if getent group nordvpn >/dev/null 2>&1 && [ -n "$_v_user" ] && ! id -nG "$_v_user" 2>/dev/null | grep -qw nordvpn; then
      try usermod -aG nordvpn "$_v_user"
    fi
    systemctl cat nordvpnd.socket >/dev/null 2>&1 && sl_enable nordvpnd.socket
    systemctl cat nordvpnd.service >/dev/null 2>&1 && sl_enable nordvpnd.service
    [ -x "$SL_ROOT/bin/secure-linux-vpn" ] && "$SL_ROOT/bin/secure-linux-vpn" _apply
  fi
fi

if [ "$(sl_choice_get warp no)" = yes ]; then
  if [ "$_v_arch" != amd64 ]; then
    echo "Note: Cloudflare WARP has no 32-bit version, so it is not installed."
  elif ! sl_pkg_installed cloudflare-warp; then
    sl_step "VPN: Cloudflare WARP"
    if sl_online; then
      _v_repo cloudflare-warp https://pkg.cloudflareclient.com/pubkey.gpg "deb [arch=amd64 signed-by=@KEY@] https://pkg.cloudflareclient.com/ $(. "$R/etc/os-release" 2>/dev/null; echo "${VERSION_CODENAME:-bookworm}") main"
      sl_apt_update
      _v_pkgs cloudflare-warp
    else
      echo "FAILED: Cloudflare WARP (offline); it installs at the next repair" | tee -a "$SL_FAILS" >&2
    fi
  fi
  if sl_pkg_installed cloudflare-warp && systemctl cat warp-svc.service >/dev/null 2>&1; then sl_enable warp-svc.service; fi
fi
unset _v_arch _v_nord _v_user
return 0
