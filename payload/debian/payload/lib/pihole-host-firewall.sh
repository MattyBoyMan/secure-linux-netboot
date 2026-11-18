# Home ad blocker (secure-linux-pihole home-*): the firewall part of the scripts it sends to the machine that runs
# Pi-hole (this computer, a home server or a Raspberry Pi). This file is never run on its own: the launcher copies it
# into the setup and removal scripts. It opens DNS (port 53, tcp and udp) and the Pi-hole web page (port 80, tcp)
# to the home network only, with ufw (the firewall of Debian, Raspberry Pi OS and Ubuntu), every rule marked
# "sl-pihole", and closes them again on home-remove. This is the Debian kit's copy: it uses Debian's own firewall
# tool only. A machine that uses firewalld instead gets plain words on what to open there.
SL_FW_PORTS='53/tcp 53/udp 80/tcp'
SL_FW_NOTE=${SL_FW_NOTE:-/opt/secure-linux-pihole/firewall-network}   # the home network ufw was opened to
sl_ufw_open() { # sl_ufw_open HOME-NETWORK
  printf '%s\n' "$1" > "$SL_FW_NOTE" 2>/dev/null || true
  for pp in $SL_FW_PORTS; do ufw allow from "$1" to any port "${pp%/*}" proto "${pp#*/}" comment sl-pihole >/dev/null || true; done
}
sl_ufw_close() { # the rules made at setup, then any other rule still marked sl-pihole (highest number first)
  net=$(cat "$SL_FW_NOTE" 2>/dev/null || true)
  case "$net" in
    *[!0-9./]*|'') : ;;
    *) for pp in $SL_FW_PORTS; do ufw delete allow from "$net" to any port "${pp%/*}" proto "${pp#*/}" >/dev/null 2>&1 || true; done ;;
  esac
  for n in $(ufw status numbered 2>/dev/null | sed -n 's/^\[ *\([0-9][0-9]*\)\].*# sl-pihole[[:space:]]*$/\1/p' | sort -rn); do
    ufw --force delete "$n" >/dev/null 2>&1 || true
  done
  rm -f "$SL_FW_NOTE" 2>/dev/null || true
}
sl_fw_open() { # sl_fw_open HOME-NETWORK (for example 192.168.1.0/24)
  if command -v ufw >/dev/null 2>&1; then
    sl_ufw_open "$1"
  elif systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "This machine uses firewalld. In its home zone, open ports 53 (tcp and udp) and 80 (tcp) for $1 yourself,"
    echo "otherwise the devices at home cannot reach Pi-hole."
  else
    echo "No firewall program was found on this machine, so there was nothing to open."
  fi
}
sl_fw_close() {
  if command -v ufw >/dev/null 2>&1; then
    sl_ufw_close
  elif systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "This machine uses firewalld. You can close ports 53 and 80 in its home zone again yourself."
  fi
}
