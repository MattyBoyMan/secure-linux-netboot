#!/bin/bash
# hw/detect.sh (owner: hardware) - hardware detection for The Complete Secure Linux Package.
#
# Pure bash + coreutils/sed/awk/grep (no od, no mapfile). NO dependency on lib/common.sh: it also runs inside the Fedora
# installer's %pre, on a live system, and on the installed machine.
#
#   . hw/detect.sh            then call hw_cpu, hw_ram, hw_firmware, hw_dmi, hw_mac, hw_gpus, hw_wifi,
#                             hw_ethernet, hw_storage, hw_battery (or hw_all). Each prints key=value lines.
#   bash hw/detect.sh [--fixture DIR]     prints everything (hw_all)
#   hw_get KEY                prints one value from hw_all (cached per shell)
#
# HW_ROOT (or --fixture DIR) is put in front of every /sys and /proc path, so tests can use a fake tree.
# In a fixture, the machine type comes from DIR/uname-m (default x86_64).
# Values never contain newlines; they may contain spaces. Parse with:  while IFS='=' read -r k v; do ...; done

HW_ROOT=${HW_ROOT:-}

_hw_read() { local v=""; [ -r "$HW_ROOT$1" ] && v=$(tr -d '\0' < "$HW_ROOT$1" 2>/dev/null | head -n1); v=${v%"${v##*[![:space:]]}"}; printf '%s' "$v"; }
# _hw_efibyte FILE: the value byte of a boolean EFI variable (4 attribute bytes, then 0 or 1) -> 0 / 1 / ""
# (no od: only head/tail/tr, which every installer image has)
_hw_efibyte() { tail -c 1 "$1" 2>/dev/null | tr '\000\001' '01' | tr -cd '01'; }
_hw_hex()  { local v; v=$(_hw_read "$1"); v=${v#0x}; printf '%s' "$v" | tr 'A-F' 'a-f'; }

hw_arch() {   # machine type: x86_64, i686, aarch64 ...
  if [ -n "$HW_ROOT" ]; then
    local a; a=$(_hw_read /uname-m); printf '%s' "${a:-x86_64}"
  else
    uname -m 2>/dev/null || echo unknown
  fi
}

# ---------------------------------------------------------------- CPU
hw_cpu() {
  local arch flags vendor model level=0 lm=no cores
  arch=$(hw_arch)
  vendor=$(awk -F': *' '/^vendor_id/{print $2; exit}' "$HW_ROOT/proc/cpuinfo" 2>/dev/null)
  model=$(awk -F': *' '/^model name/{print $2; exit}' "$HW_ROOT/proc/cpuinfo" 2>/dev/null)
  flags=" $(awk -F': *' '/^flags/{print $2; exit}' "$HW_ROOT/proc/cpuinfo" 2>/dev/null) "
  cores=$(grep -c '^processor' "$HW_ROOT/proc/cpuinfo" 2>/dev/null)
  case "$vendor" in
    GenuineIntel) vendor=intel ;; AuthenticAMD|HygonGenuine) vendor=amd ;;
    "") case "$arch" in aarch64|arm*) vendor=arm ;; *) vendor=unknown ;; esac ;;
    *) vendor=other ;;
  esac
  case "$flags" in *" lm "*) lm=yes ;; esac
  # x86-64 microarchitecture levels (psABI): v1 = lm cmov cx8 fpu fxsr mmx syscall sse2
  _hw_has() { local f; for f in "$@"; do case "$flags" in *" $f "*) ;; *) return 1 ;; esac; done; return 0; }
  if [ "$lm" = yes ]; then
    level=1
    _hw_has cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3 && level=2
    [ $level = 2 ] && _hw_has avx avx2 bmi1 bmi2 f16c fma abm movbe xsave && level=3
    [ $level = 3 ] && _hw_has avx512f avx512bw avx512cd avx512dq avx512vl && level=4
  fi
  unset -f _hw_has
  [ -z "$model" ] && model=$(awk -F': *' '/^(Hardware|CPU part)/{print $2; exit}' "$HW_ROOT/proc/cpuinfo" 2>/dev/null)
  echo "cpu_arch=$arch"
  echo "cpu_vendor=$vendor"
  echo "cpu_model=$model"
  echo "cpu_cores=${cores:-0}"
  echo "cpu_64bit=$lm"
  echo "cpu_x86_level=$level"
}

# ---------------------------------------------------------------- memory
hw_ram() {
  local kb; kb=$(awk '/^MemTotal:/{print $2; exit}' "$HW_ROOT/proc/meminfo" 2>/dev/null)
  kb=${kb:-0}
  echo "ram_mb=$((kb / 1024))"
  echo "ram_gb=$(( (kb + 524288) / 1048576 ))"     # rounded, as the setup screen shows it
}

# ---------------------------------------------------------------- firmware / Secure Boot
hw_firmware() {
  local fw=bios bits="" sb=off sm="" f b
  if [ -d "$HW_ROOT/sys/firmware/efi" ]; then
    fw=uefi
    bits=$(_hw_read /sys/firmware/efi/fw_platform_size)
    sb=unknown
    # efivar: 4 bytes of attributes, then the value byte (1 = Secure Boot enforcing)
    for f in "$HW_ROOT"/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d0-aa0d-00e098032b8c; do
      [ -r "$f" ] || continue
      b=$(_hw_efibyte "$f")
      case "$b" in 1) sb=on ;; 0) sb=off ;; esac
    done
    for f in "$HW_ROOT"/sys/firmware/efi/efivars/SetupMode-8be4df61-93ca-11d0-aa0d-00e098032b8c; do
      [ -r "$f" ] || continue
      b=$(_hw_efibyte "$f")
      case "$b" in 1) sm=yes ;; 0) sm=no ;; esac
    done
    # Fall back to mokutil on a real system (not in fixtures)
    if [ "$sb" = unknown ] && [ -z "$HW_ROOT" ] && command -v mokutil >/dev/null 2>&1; then
      case "$(mokutil --sb-state 2>/dev/null)" in *nabled*) sb=on ;; *isabled*) sb=off ;; esac
    fi
    # (Intel Macs have no SecureBoot variable at all: Apple's own scheme; T2 Macs enforce it in the T2 -> unknown)
  fi
  echo "firmware=$fw"
  echo "efi_bits=${bits:-}"
  echo "secure_boot=$sb"
  echo "setup_mode=$sm"
}

# ---------------------------------------------------------------- DMI (maker / model)
hw_dmi() {
  local vendor product family version ct kind
  vendor=$(_hw_read /sys/class/dmi/id/sys_vendor)
  product=$(_hw_read /sys/class/dmi/id/product_name)
  family=$(_hw_read /sys/class/dmi/id/product_family)
  version=$(_hw_read /sys/class/dmi/id/product_version)
  ct=$(_hw_read /sys/class/dmi/id/chassis_type)
  case "$ct" in
    8|9|10|11|14|30|31|32) kind=laptop ;;     # portable, laptop, notebook, hand held, sub notebook, tablet, convertible, detachable
    3|4|5|6|7|13|15|16|35|36) kind=desktop ;;
    "") kind=unknown ;;
    *) kind=other ;;
  esac
  local short
  case "$(printf '%s' "$vendor" | tr 'a-z' 'A-Z')" in
    APPLE*) short=apple ;; DELL*) short=dell ;; TOSHIBA*|DYNABOOK*) short=toshiba ;; LENOVO*) short=lenovo ;;
    HP|HEWLETT*) short=hp ;; ASUS*) short=asus ;; MICROSOFT*) short=microsoft ;; ACER*) short=acer ;;
    GOOGLE*) short=google ;; MSI*|MICRO-STAR*) short=msi ;; SAMSUNG*) short=samsung ;; FRAMEWORK*) short=framework ;;
    "") short=unknown ;; *) short=other ;;
  esac
  echo "dmi_vendor=$vendor"
  echo "dmi_maker=$short"
  echo "dmi_product=$product"
  echo "dmi_family=$family"
  echo "dmi_version=$version"
  echo "dmi_chassis_type=$ct"
  echo "dmi_chassis=$kind"
}

# ---------------------------------------------------------------- PCI helpers
# _hw_pci CLASSPREFIX  ->  "slot vendor device class boot_vga" per matching device (hex, no 0x)
_hw_pci() {
  local d cls v dev bv
  for d in "$HW_ROOT"/sys/bus/pci/devices/*; do
    [ -r "$d/class" ] || continue
    cls=$(tr 'A-F' 'a-f' < "$d/class"); cls=${cls#0x}; cls=${cls%%[[:space:]]*}
    case "$cls" in "$1"*) ;; *) continue ;; esac
    v=$(tr 'A-F' 'a-f' < "$d/vendor" 2>/dev/null); v=${v#0x}; v=${v%%[[:space:]]*}
    dev=$(tr 'A-F' 'a-f' < "$d/device" 2>/dev/null); dev=${dev#0x}; dev=${dev%%[[:space:]]*}
    bv=$(cat "$d/boot_vga" 2>/dev/null); bv=${bv%%[[:space:]]*}
    printf '%s %s %s %s %s\n' "${d##*/}" "$v" "$dev" "$cls" "${bv:-0}"
  done
}
_hw_pci_has() {   # _hw_pci_has VENDOR DEVICE
  local d v dev
  for d in "$HW_ROOT"/sys/bus/pci/devices/*; do
    [ -r "$d/vendor" ] || continue
    v=$(tr 'A-F' 'a-f' < "$d/vendor"); v=${v#0x}; v=${v%%[[:space:]]*}
    dev=$(tr 'A-F' 'a-f' < "$d/device" 2>/dev/null); dev=${dev#0x}; dev=${dev%%[[:space:]]*}
    [ "$v" = "$1" ] && [ "$dev" = "$2" ] && return 0
  done
  return 1
}

# ---------------------------------------------------------------- Macs
# T2 = Apple PCI 106b:1801 (T2 bridge / BCE, driven by the out-of-tree apple-bce driver) and 106b:1802
# (T2 Secure Enclave). The model table below catches T2 Macs whose BCE is hidden.
_hw_t2_model() {
  case "$1" in
    MacBookPro15,*|MacBookPro16,*|MacBookAir8,*|MacBookAir9,1|Macmini8,1|iMac20,*|iMacPro1,1|MacPro7,1) return 0 ;;
  esac
  return 1
}
hw_mac() {
  local vendor product arch compat kind=none t2=no fth=no
  vendor=$(_hw_read /sys/class/dmi/id/sys_vendor)
  product=$(_hw_read /sys/class/dmi/id/product_name)
  arch=$(hw_arch)
  compat=""; [ -r "$HW_ROOT/proc/device-tree/compatible" ] && compat=$(tr '\0' ' ' < "$HW_ROOT/proc/device-tree/compatible")
  case "$arch:$compat" in
    aarch64:*apple,*) kind=apple-silicon; product=$(_hw_read /proc/device-tree/model) ;;
  esac
  if [ "$kind" = none ]; then
    case "$vendor" in
      Apple*)
        if _hw_pci_has 106b 1801 || _hw_pci_has 106b 1802 || _hw_t2_model "$product"; then kind=intel-t2; t2=yes
        else kind=intel; fi ;;
    esac
  fi
  # FaceTime HD (PCIe, Broadcom 14e4:1570): MacBooks ~2013-2017. Needs the out-of-tree facetimehd driver.
  [ "$kind" = intel ] && _hw_pci_has 14e4 1570 && fth=yes
  local is=no; [ "$kind" != none ] && is=yes
  echo "is_mac=$is"
  echo "mac_kind=$kind"
  echo "mac_model=$( [ "$is" = yes ] && printf '%s' "$product")"
  echo "mac_t2=$t2"
  echo "mac_facetimehd=$fth"
}

# ---------------------------------------------------------------- NVIDIA generations (by PCI device id)
# Best effort, from NVIDIA's device-id ranges (each chip family got its own block of ids):
#   >= 0x1e00            Turing (GTX 16 / RTX 20) and newer: Ampere, Ada, Hopper, Blackwell -> akmod-nvidia
#   0x1340 .. 0x1dff     Maxwell (GTX 750/900), Pascal (GTX 10), Volta -> akmod-nvidia-580xx (last branch for them)
#   <  0x1340            Kepler (GTX 600/700), Fermi (400/500), Tesla (8/9/200/300) and older -> nouveau
# The authoritative list is supported-gpus.json in NVIDIA's driver README; edge cases are listed in hw_nvidia_family.
hw_nvidia_class() {   # hw_nvidia_class DEVICEID(hex) -> modern | 580xx | legacy
  local d=$((16#${1:-0}))
  if [ $d -ge $((16#1e00)) ]; then echo modern
  elif [ $d -ge $((16#1340)) ]; then echo 580xx
  else echo legacy; fi
}
hw_nvidia_family() {  # hw_nvidia_family DEVICEID(hex) -> chip family name (for messages)
  local d=$((16#${1:-0}))
  if   [ $d -ge $((16#2b80)) ] && [ $d -le $((16#2fff)) ]; then echo Blackwell
  elif [ $d -ge $((16#2680)) ] && [ $d -le $((16#28ff)) ]; then echo "Ada Lovelace"
  elif [ $d -ge $((16#2300)) ] && [ $d -le $((16#233f)) ]; then echo Hopper
  elif [ $d -ge $((16#2080)) ] && [ $d -le $((16#25ff)) ]; then echo Ampere
  elif [ $d -ge $((16#1e00)) ] && [ $d -le $((16#21ff)) ]; then echo Turing
  elif [ $d -ge $((16#1e00)) ]; then echo "Turing or newer"
  elif [ $d -ge $((16#1d80)) ]; then echo Volta
  elif [ $d -ge $((16#1b00)) ] || { [ $d -ge $((16#15f0)) ] && [ $d -le $((16#15ff)) ]; }; then echo Pascal
  elif [ $d -ge $((16#1340)) ]; then echo Maxwell
  elif { [ $d -ge $((16#0fc0)) ] && [ $d -le $((16#103f)) ]; } || { [ $d -ge $((16#1180)) ] && [ $d -le $((16#11ff)) ]; } \
       || { [ $d -ge $((16#1280)) ] && [ $d -le $((16#12ff)) ]; }; then echo Kepler
  elif [ $d -ge $((16#1140)) ] && [ $d -le $((16#117f)) ]; then echo "Fermi/Kepler"
  elif { [ $d -ge $((16#06c0)) ] && [ $d -le $((16#06df)) ]; } || { [ $d -ge $((16#0dc0)) ] && [ $d -le $((16#0dff)) ]; } \
       || { [ $d -ge $((16#0e20)) ] && [ $d -le $((16#0e3f)) ]; } || { [ $d -ge $((16#0f00)) ] && [ $d -le $((16#0f3f)) ]; } \
       || { [ $d -ge $((16#1040)) ] && [ $d -le $((16#10bf)) ]; } || { [ $d -ge $((16#1200)) ] && [ $d -le $((16#127f)) ]; }; then echo Fermi
  else echo "Tesla or older"; fi
}

# ---------------------------------------------------------------- graphics
hw_gpus() {
  local n=0 nv=no nvid="" nvclass=none nvfam="" amd=no intel=no other=no slot v dev cls bv names=""
  while read -r slot v dev cls bv; do
    [ -n "$slot" ] || continue
    n=$((n + 1))
    echo "gpu_$n=$v:$dev:$cls:$slot:$bv"
    case "$v" in
      10de) nv=yes; [ -z "$nvid" ] && nvid=$dev ;;
      1002) amd=yes ;;
      8086) intel=yes ;;
      *) other=yes ;;
    esac
  done < <(_hw_pci 03)
  if [ -n "$nvid" ]; then nvclass=$(hw_nvidia_class "$nvid"); nvfam=$(hw_nvidia_family "$nvid"); fi
  local hybrid=no
  [ $n -ge 2 ] && hybrid=yes
  echo "gpu_count=$n"
  echo "gpu_nvidia=$nv"
  echo "gpu_amd=$amd"
  echo "gpu_intel=$intel"
  echo "gpu_other=$other"
  echo "nvidia_id=$nvid"
  echo "nvidia_class=$nvclass"
  echo "nvidia_family=$nvfam"
  echo "gpu_multi=$hybrid"
}

# ---------------------------------------------------------------- Wi-Fi
# Broadcom: which driver a chip needs (VERIFY list against the Arch wiki "Broadcom wireless" table).
#   builtin  brcmfmac/brcmsmac in the Fedora kernel + linux-firmware: nothing to install
#   wl       Broadcom's own driver: akmod-wl (RPM Fusion nonfree)
#   b43      only the old b43 driver works: firmware must be cut with b43-fwcutter (manual)
hw_broadcom_driver() {
  case "$1" in
    43a3|43ba|43bb|43bc|43ec|43dc|4464|4488|4425|4433|4415|43ef|4354|4355) echo builtin ;;   # brcmfmac
    4357|4727|4353) echo builtin ;;                                                           # brcmsmac (43225, 4313, 43224)
    4311|4312|4315|4328|4329|432a|432b|432c|432d|4331|4358|4359|4360|4365|43a0|43b1|43b2) echo wl ;;
    4301|4306|4307|4318|4319|4320|4324|4325) echo b43 ;;
    *) echo unknown ;;
  esac
}
hw_wifi() {
  local n=0 slot v dev cls bv kind="" bdrv=none needs=no ids=""
  while read -r slot v dev cls bv; do
    [ -n "$slot" ] || continue
    n=$((n + 1)); ids="$ids $v:$dev"
    echo "wifi_$n=$v:$dev"
    case "$v" in
      14e4) kind=${kind:-broadcom}; bdrv=$(hw_broadcom_driver "$dev"); case "$bdrv" in wl|b43|unknown) needs=yes ;; esac ;;
      8086) kind=${kind:-intel} ;;
      14c3) kind=${kind:-mediatek} ;;
      10ec) kind=${kind:-realtek} ;;
      168c|17cb) kind=${kind:-atheros} ;;
      *) kind=${kind:-other} ;;
    esac
  done < <(_hw_pci 0280)
  # Wi-Fi that isn't on PCI (USB adapters, SDIO): only visible once a driver is loaded
  local w nonpci=no
  for w in "$HW_ROOT"/sys/class/net/*/wireless; do [ -d "$w" ] && nonpci=yes; done
  [ $n -eq 0 ] && [ "$nonpci" = yes ] && kind=other
  echo "wifi_count=$n"
  echo "wifi_vendor=${kind:-none}"
  echo "wifi_broadcom_driver=$bdrv"
  echo "wifi_needs_driver=$needs"
  echo "wifi_ids=${ids# }"
}

# ---------------------------------------------------------------- wired network
hw_ethernet() {
  local n=0 slot v dev cls bv kind=""
  while read -r slot v dev cls bv; do
    [ -n "$slot" ] || continue
    n=$((n + 1))
    case "$v" in 10ec) kind=${kind:-realtek} ;; 8086) kind=${kind:-intel} ;; 14e4) kind=${kind:-broadcom} ;; 1969) kind=${kind:-atheros} ;; *) kind=${kind:-other} ;; esac
  done < <(_hw_pci 0200)
  echo "eth_count=$n"
  echo "eth_vendor=${kind:-none}"
}

# ---------------------------------------------------------------- drives
hw_storage() {
  local d n=0 name rot kind size gb nvme=no ssd=no hdd=no
  for d in "$HW_ROOT"/sys/block/*; do
    [ -d "$d" ] || continue
    name=${d##*/}
    case "$name" in loop*|ram*|zram*|sr*|fd*|dm-*|md*|nbd*|mmcblk*boot*|mmcblk*rpmb) continue ;; esac
    [ "$(_hw_read "/sys/block/$name/removable")" = 1 ] && continue
    readlink -f "$d/device" 2>/dev/null | grep -q '/usb' && continue
    size=$(_hw_read "/sys/block/$name/size"); size=${size:-0}
    gb=$((size / 2097152))
    [ "$gb" -ge 1 ] || continue
    rot=$(_hw_read "/sys/block/$name/queue/rotational")
    case "$name" in
      nvme*) kind=nvme; nvme=yes ;;
      mmcblk*) kind=emmc ;;
      *) if [ "$rot" = 1 ]; then kind=hdd; hdd=yes; else kind=ssd; ssd=yes; fi ;;
    esac
    n=$((n + 1))
    echo "disk_$n=$name:$kind:$gb"
  done
  echo "disk_count=$n"
  echo "disk_nvme=$nvme"
  echo "disk_ssd=$ssd"
  echo "disk_hdd=$hdd"
}

# ---------------------------------------------------------------- battery
hw_battery() {
  local p has=no
  for p in "$HW_ROOT"/sys/class/power_supply/*; do
    [ "$(_hw_read "/sys/class/power_supply/${p##*/}/type")" = Battery ] || continue
    [ "$(_hw_read "/sys/class/power_supply/${p##*/}/scope")" = Device ] && continue   # mouse / keyboard batteries
    has=yes
  done
  echo "battery=$has"
}

# ---------------------------------------------------------------- everything
hw_all() {
  hw_cpu; hw_ram; hw_firmware; hw_dmi; hw_mac; hw_gpus; hw_wifi; hw_ethernet; hw_storage; hw_battery
  # A laptop (battery or laptop chassis) with two graphics chips = switchable / hybrid graphics (Optimus etc.)
  local multi bat ch
  multi=$(hw_gpus | sed -n 's/^gpu_multi=//p'); bat=$(hw_battery | sed -n 's/^battery=//p'); ch=$(hw_dmi | sed -n 's/^dmi_chassis=//p')
  if [ "$multi" = yes ] && { [ "$bat" = yes ] || [ "$ch" = laptop ]; }; then echo "hybrid=yes"; else echo "hybrid=no"; fi
}

HW_CACHE=""
hw_get() {   # hw_get KEY   (runs hw_all once per shell)
  [ -n "$HW_CACHE" ] || HW_CACHE=$(hw_all)
  printf '%s\n' "$HW_CACHE" | sed -n "s/^$1=//p" | head -n1
}

# Run directly: print everything
# (compat-check.sh carries a verbatim copy of this file and sets HW_EMBEDDED=1)
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ -z "${HW_EMBEDDED:-}" ]; then
  while [ $# -gt 0 ]; do
    case "$1" in
      --fixture) HW_ROOT=${2%/}; shift ;;
      -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    esac
    shift
  done
  hw_all
fi
