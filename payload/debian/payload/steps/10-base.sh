#!/bin/bash
# 10-base.sh (Debian) - base system tools, firmware for this computer's chips, memory help for small PCs, Flathub.
# Apps are NOT installed here (40-apps.sh does that); only system tools.
# Sourced by setup.sh: never `exit`.
[ "$SL_MODE" = early ] && return 0

# Install only packages that exist in this Debian (a few differ between 12 and 13 and between 32/64-bit).
_b_have() { apt-cache policy "$1" 2>/dev/null | grep -q 'Candidate: [^(]'; }
_b_pkgs() {   # install the packages that exist in this Debian and are missing; unknown names are noted, not failures
  local missing=() want=() p
  for p in "$@"; do sl_pkg_installed "$p" || missing+=("$p"); done
  [ ${#missing[@]} -eq 0 ] && return 0          # nothing to do: no apt update, no network
  sl_apt_update
  for p in "${missing[@]}"; do
    if _b_have "$p"; then want+=("$p"); else echo "Note: package $p isn't available in this Debian; skipped."; fi
  done
  [ ${#want[@]} -gt 0 ] && sl_pkg_install --no-recommends "${want[@]}"
  return 0
}

sl_step "Updating the system"
if [ "$SL_MODE" = install ]; then
  sl_apt_update
  try apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
fi

sl_step "Base system tools"
_b_pkgs curl wget git unzip zip p7zip-full htop ncdu smartmontools pciutils usbutils iw wireless-regdb \
        xdg-utils xdg-user-dirs zenity libnotify-bin synaptic sudo ca-certificates python3 python3-tk python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 apt-transport-https \
        testdisk dosfstools exfatprogs ntfs-3g e2fsprogs xfsprogs btrfs-progs util-linux \
        qflipper dfu-util age gnupg
# i386 has no Flatpak apps worth having (Flathub is 64-bit only), so Flatpak is only for 64-bit PCs
[ "$(sl_arch)" = amd64 ] && _b_pkgs flatpak

sl_step "Firmware and drivers for this computer"
# Which chips are inside? (PCI vendor ids; no lspci needed.) Wi-Fi/graphics firmware is in Debian's non-free-firmware.
_b_fw=(firmware-misc-nonfree)
_b_vendors=" "
for _b_d in "$R"/sys/bus/pci/devices/*; do
  [ -r "$_b_d/vendor" ] || continue
  _b_v=$(tr 'A-F' 'a-f' < "$_b_d/vendor" | sed 's/^0x//'); _b_c=$(tr 'A-F' 'a-f' < "$_b_d/class" 2>/dev/null | sed 's/^0x//')
  case "$_b_c" in 02*|0280*) _b_vendors="$_b_vendors$_b_v-net " ;; 03*) _b_vendors="$_b_vendors$_b_v-gpu " ;; esac
done
case "$_b_vendors" in *8086-net*) _b_fw+=(firmware-iwlwifi) ;; esac
case "$_b_vendors" in *10ec-net*) _b_fw+=(firmware-realtek) ;; esac
case "$_b_vendors" in *168c-net*) _b_fw+=(firmware-atheros) ;; esac
case "$_b_vendors" in *14e4-net*) _b_fw+=(firmware-brcm80211) ;; esac
case "$_b_vendors" in *1002-gpu*) _b_fw+=(firmware-amd-graphics) ;; esac
case "$(awk -F': *' '/^vendor_id/{print $2; exit}' "${SL_PROC:-/proc}/cpuinfo" 2>/dev/null)" in
  GenuineIntel) _b_fw+=(intel-microcode) ;;
  AuthenticAMD) [ "$(sl_arch)" = amd64 ] && _b_fw+=(amd64-microcode) ;;
esac
_b_pkgs "${_b_fw[@]}"
# No internet during setup? Try the USB stick's offline firmware pool for whatever apt could not
# install. The helper prints a plain line per package and is a silent no-op when there is no pool (B1).
_b_still=()
for _b_p in "${_b_fw[@]}"; do sl_pkg_installed "$_b_p" || _b_still+=("$_b_p"); done
[ ${#_b_still[@]} -gt 0 ] && sl_offline_fw_install "${_b_still[@]}" || true
case "$_b_vendors" in *14e4-net*) echo "Note: some older Broadcom Wi-Fi chips need a driver Debian keeps in 'non-free' (broadcom-sta-dkms). If Wi-Fi is missing, use a cable or phone tethering and see the guide." ;; esac

# Little memory? Compressed memory ("zram") makes a small PC feel much less stuck.
_b_ram=$(sl_ram_mb)
if [ "${_b_ram:-0}" -gt 0 ] && [ "${_b_ram:-0}" -lt 2048 ]; then
  sl_step "Help for a computer with little memory (${_b_ram} MB)"
  _b_pkgs zram-tools
  SL_CHANGED=0
  sl_write_file "$R/etc/default/zramswap" <<'EOF'
# Secure Linux: compressed memory for small computers (zram-tools)
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
  [ "$SL_CHANGED" = 1 ] && try systemctl restart zramswap.service
  sl_enable zramswap.service
fi

if sl_flatpak_ok; then
  sl_step "Flathub app store"
  flatpak remotes --system 2>/dev/null | grep -q '^flathub' \
    || try flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
fi

unset _b_fw _b_vendors _b_d _b_v _b_c _b_ram _b_still _b_p
return 0
