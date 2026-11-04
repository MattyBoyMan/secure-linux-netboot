#!/bin/bash
# Shared helpers for the security helpers (secure-linux-dns, -vpn, -hotspot, -zone, -recovery-key, ...).
# Source it after lib/common.sh. Safe to source more than once.
[ -n "${SEC_LIB_LOADED:-}" ] && return 0
SEC_LIB_LOADED=1

# Root of the real filesystem. Always empty on a real machine (pkexec and sudo clear the environment);
# the test suite points it at a scratch folder.
SEC_PREFIX=${SL_SEC_PREFIX:-}
SEC_BIN=${SL_SEC_BIN:-/usr/local/bin}

SEC_RESOLVED_ETC=$SEC_PREFIX/etc/systemd/resolved.conf.d
SEC_RESOLVED_RUN=$SEC_PREFIX/run/systemd/resolved.conf.d
SEC_DNS_CONF=$SEC_RESOLVED_ETC/10-secure-linux-dns.conf      # encrypted DNS (installed by 20-network.sh)
SEC_DNS_FAMILY=$SEC_RESOLVED_ETC/15-secure-linux-family.conf # family filter on (secure-linux-dns family on)
SEC_DNS_VPN=$SEC_RESOLVED_RUN/50-secure-linux-vpn.conf       # exists while a VPN supplies DNS
SEC_DNS_OPEN=$SEC_RESOLVED_RUN/99-secure-linux-open.conf     # exists while paused for a Wi-Fi login page
SEC_CRYPTTAB=$SEC_PREFIX/etc/crypttab
SEC_DRACUT_DIR=$SEC_PREFIX/etc/dracut.conf.d
SEC_RUNSTATE=$SEC_PREFIX/run/secure-linux

# Names of VPN network interfaces whose DNS should win while they are up.
SEC_VPN_IFACES='^(nordlynx|nordtun|CloudflareWARP|tun[0-9]+|wg[0-9]+|proton[0-9]*|tailscale[0-9]+)$'

sec_self() { readlink -f "$0" 2>/dev/null || printf '%s' "$0"; }

# Is there someone at a keyboard? (SL_SEC_NO_TERMINAL=1 is for the test suite: answers come from stdin.)
sec_tty() { [ -n "${SL_SEC_NO_TERMINAL:-}" ] || { [ -t 0 ] && [ -t 1 ]; }; }

# Re-run this helper as root (pkexec shows the password box), keeping the arguments.
sec_need_root() {
  [ "$(id -u)" -eq 0 ] && return 0
  exec pkexec "$(sec_self)" "$@"
}

# Make sure we have a terminal for questions/passwords; otherwise reopen this helper in a terminal window.
sec_need_terminal() {
  sec_tty && return 0
  if command -v "$SEC_BIN/secure-linux-terminal" >/dev/null 2>&1 || [ -x "$SEC_BIN/secure-linux-terminal" ]; then
    exec "$SEC_BIN/secure-linux-terminal" "$(sec_self)" "$@"
  fi
  echo "Please run this from a terminal (Konsole on the laptop, Terminal on older PCs)." >&2
  exit 1
}

sec_has_display() { [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; }

# sec_ask "Question?" [default yes|no]   -> 0 for yes. Uses a window when there is a desktop, else the terminal.
sec_ask() {
  local q=$1 def=${2:-no} a
  if sec_has_display && [ "$(id -u)" -ne 0 ] && [ -z "${SL_SEC_NO_TERMINAL:-}" ]; then
    if command -v kdialog >/dev/null 2>&1; then kdialog --title "Secure Linux" --yesno "$q"; return $?; fi
    if command -v zenity >/dev/null 2>&1; then zenity --question --title="Secure Linux" --width=460 --text="$q"; return $?; fi
  fi
  if sec_tty; then
    while true; do
      if [ "$def" = yes ]; then read -rp "$q [Y/n] " a || a=""; a=${a:-y}; else read -rp "$q [y/N] " a || a=""; a=${a:-n}; fi
      case "$a" in [Yy]*) return 0 ;; [Nn]*) return 1 ;; esac
      echo "Please type y (yes) or n (no)."
      [ -t 0 ] || return 1    # answers from a file ran out
    done
  fi
  [ "$def" = yes ]
}

# sec_info "Title" "Message"   (window if possible, always also printed)
sec_info() {
  printf '\n%s\n%s\n\n' "$1" "$2"
  if sec_has_display && [ "$(id -u)" -ne 0 ] && ! sec_tty; then
    if command -v kdialog >/dev/null 2>&1; then kdialog --title "$1" --msgbox "$2"
    elif command -v zenity >/dev/null 2>&1; then zenity --info --title="$1" --width=460 --text="$2"; fi
  fi
  return 0
}

sec_pause() { sec_tty && read -rp "${1:-Press Enter to continue. }" _ ; return 0; }

# Set a saved choice; works as a normal user too (asks for the password once through pkexec).
sec_choice_set() {
  if [ "$(id -u)" -eq 0 ]; then sl_choice_set "$1" "$2"
  else pkexec "$SEC_BIN/secure-linux-vpn" _set-choice "$1" "$2"; fi
}

# ---------------------------------------------------------------- Secure Boot
# 0 if Secure Boot is switched on in the firmware right now
sec_sb_enabled() {
  local v
  if command -v mokutil >/dev/null 2>&1; then
    mokutil --sb-state 2>/dev/null | grep -i 'SecureBoot enabled' >/dev/null && return 0
    return 1
  fi
  v=$(od -An -t u1 "$SEC_PREFIX"/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c 2>/dev/null | awk '{print $NF}')
  [ "$v" = 1 ]
}
# 0 if Secure Boot features (Ventoy key removal, TPM PIN) apply: Secure Boot is on AND the user didn't choose "off"
# in the installer (choice secureboot_intent). Otherwise prints a friendly note and returns 1.
sec_sb_applies() {
  if [ "$(sl_choice_get secureboot_intent on)" = off ] || ! sec_sb_enabled; then
    echo "Not needed: Secure Boot is off on this computer (your choice). If you switch it on later in the BIOS, this becomes available."
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------- LUKS helpers
# The LUKS device that holds / (e.g. /dev/nvme0n1p3), or the first LUKS device on the machine.
sec_luks_dev() {
  local -; set +o pipefail   # steps run with pipefail; "| grep -q" / "| awk exit" must not fail
  local src dev
  src=$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*//')
  if [ -n "$src" ]; then
    dev=$(lsblk -rpsno NAME,FSTYPE "$src" 2>/dev/null | awk '$2=="crypto_LUKS"{print $1; exit}')
    [ -n "$dev" ] && { printf '%s\n' "$dev"; return 0; }
  fi
  dev=$(lsblk -rpno NAME,FSTYPE 2>/dev/null | awk '$2=="crypto_LUKS"{print $1; exit}')
  [ -n "$dev" ] && { printf '%s\n' "$dev"; return 0; }
  return 1
}
# The /etc/crypttab name for a LUKS device (luks-<uuid> on Fedora).
sec_luks_name() {
  local -; set +o pipefail   # steps run with pipefail; "| grep -q" / "| awk exit" must not fail
  local uuid; uuid=$(cryptsetup luksUUID "$1" 2>/dev/null)
  [ -n "$uuid" ] && awk -v u="$uuid" '$0 !~ /^[[:space:]]*#/ && ($2=="UUID="u || $2=="/dev/disk/by-uuid/"u) {print $1; exit}' "$SEC_CRYPTTAB" 2>/dev/null
}
# 0 if the LUKS device has an unlock method of this type (password, recovery, tpm2, fido2, pkcs11)
sec_luks_has() {
  local -; set +o pipefail   # steps run with pipefail; "| grep -q" / "| awk exit" must not fail
  local dev=$1 type=$2
  systemd-cryptenroll "$dev" 2>/dev/null | awk 'NR>1{print $2}' | grep -qx "$type" && return 0
  case "$type" in
    recovery) cryptsetup luksDump "$dev" 2>/dev/null | grep -q 'systemd-recovery' ;;
    tpm2)     cryptsetup luksDump "$dev" 2>/dev/null | grep -q 'systemd-tpm2' ;;
    fido2)    cryptsetup luksDump "$dev" 2>/dev/null | grep -q 'systemd-fido2' ;;
    *) return 1 ;;
  esac
}
# sec_crypttab_opt add|remove NAME OPTION     (e.g. add luks-1234 tpm2-device=auto)
sec_crypttab_opt() {
  local act=$1 name=$2 opt=$3 key tmp
  key=${opt%%=*}
  [ -f "$SEC_CRYPTTAB" ] || return 1
  tmp=$(mktemp)
  awk -v act="$act" -v name="$name" -v opt="$opt" -v key="$key" '
    $0 ~ /^[[:space:]]*#/ || $1 != name { print; next }
    {
      dev=$2; kf=($3=="" ? "none" : $3); o=($4=="" ? "" : $4)
      n=split(o, a, ","); out=""
      for (i=1; i<=n; i++) { split(a[i], kv, "="); if (kv[1]==key || a[i]=="") continue; out = out (out=="" ? "" : ",") a[i] }
      if (act=="add") out = out (out=="" ? "" : ",") opt
      if (out=="") out="none"
      print $1, dev, kf, out
    }' "$SEC_CRYPTTAB" > "$tmp"
  if cmp -s "$tmp" "$SEC_CRYPTTAB"; then rm -f "$tmp"; return 0; fi
  cp -p "$SEC_CRYPTTAB" "$SEC_CRYPTTAB.secure-linux-backup"
  cat "$tmp" > "$SEC_CRYPTTAB"; rm -f "$tmp"
}
# Rebuild the start-up image (initramfs) for every installed kernel.
sec_dracut_regen() {
  echo "Updating the start-up image (this takes a minute)..."
  dracut -f --regenerate-all
}
