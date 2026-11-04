#!/bin/bash
# hw/compat-check.sh (owner: hardware) - "Will The Complete Secure Linux Package work on this computer,
# and which Linux should it get?"
#
#   bash compat-check.sh [--installer] [--fixture DIR] [--ascii] [--brief] [--export FILE]
#
#   --installer     for the Fedora installer's %pre: plain ASCII report, then these machine-readable lines
#                   (the installer hides them):  HW_STATUS=OK|NOTES|UNSUPPORTED  HW_PROFILE=full|lite
#                   HW_TEXT_INSTALL=0|1  HW_DISTRO=<see below>  HW_DISTRO_REASON=<one line>. Always exits 0.
#   --fixture DIR   read a fake /sys + /proc tree (tests) instead of this computer
#   --ascii         [ OK ] [NOTE] [ NO ] instead of the check-mark symbols (Linux text console fonts lack them)
#   --brief         only the notes, problems and the verdict
#   --export FILE   also write shell variables (HW_VERDICT, HW_STATUS, HW_PROFILE_SUGGEST, HW_TEXT_INSTALL,
#                   HW_DISTRO, HW_BLOCKERS, HW_BLOCKER_TEXT, HW_ASK_CONTINUE, HW_NEEDS_WIRED, ...)
#
# HW_DISTRO: fedora (this USB's normal path) | fedora-min (this USB's Fedora with the light LXQt desktop:
# a 64-bit PC with about 2-3 GB memory stays in the Fedora family) | fedora-t2 (Fedora + t2linux kernel,
# T2 Macs) | asahi (Apple Silicon: Fedora Asahi Remix, installed from macOS) | debian-lite (64-bit PC under
# ~1.7 GB of reported memory: Debian 13 amd64, light desktop) | debian-i386 (32-bit-only PC: Debian 12 i386)
# | unsupported (below Debian's minimums).
#
# Exit code (without --installer): 0 = GOOD, 1 = WORKS WITH NOTES, 2 = NOT SUPPORTED BY THIS USB('s Fedora), 3 = error.
# Self-contained (the installer embeds only this file): Bash 4+, coreutils, sed, awk, grep. No od, no mapfile.
# The block between "BEGIN detect.sh" and "END detect.sh" is a verbatim copy of hw/detect.sh
# (tests/hardware/sync-compat.sh refreshes it; tests/hardware/run.sh fails if they differ).
# For the Debian installer (busybox ash) use hw/compat-check-min.sh instead.

ASCII=0 BRIEF=0 EXPORT="" FIXTURE="" INSTALLER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --installer) INSTALLER=1; ASCII=1 ;;
    --fixture) FIXTURE=${2%/}; shift ;;
    --ascii) ASCII=1 ;;
    --brief) BRIEF=1 ;;
    --export) EXPORT=$2; shift ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 3 ;;
  esac
  shift
done
HW_ROOT=$FIXTURE
HW_EMBEDDED=1

# ======================================================================= BEGIN detect.sh
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
# ======================================================================= END detect.sh

declare -A H
while IFS='=' read -r k v; do [ -n "$k" ] && H[$k]=$v; done < <(hw_all)
g() { printf '%s' "${H[$1]:-}"; }

if [ $ASCII = 1 ]; then S_OK='[ OK ]'; S_NOTE='[NOTE]'; S_NO='[ NO ]'; S_INFO='[INFO]'
else S_OK='✓'; S_NOTE='⚠'; S_NO='✗'; S_INFO='•'; fi

LINES=() NOTES=0 BLOCKERS=0 BLOCKER_TEXT="" ASK=0 WIRED=0 ASAHI=0 TEXT=0 PROFILE=full WHY=""
_add() {   # _add ok|note|no|info "first line" ["more lines"...]
  local kind=$1 sym l; shift
  case "$kind" in ok) sym=$S_OK ;; note) sym=$S_NOTE; NOTES=$((NOTES + 1)) ;; no) sym=$S_NO; BLOCKERS=$((BLOCKERS + 1)) ;; *) sym=$S_INFO ;; esac
  [ "$kind" = no ] && BLOCKER_TEXT="${BLOCKER_TEXT:+$BLOCKER_TEXT; }$1"
  if [ $BRIEF = 1 ] && { [ "$kind" = ok ] || [ "$kind" = info ]; }; then return 0; fi
  LINES+=("  $sym $1")
  shift
  for l in "$@"; do LINES+=("      $l"); done
}

ARCH=$(g cpu_arch) MACK=$(g mac_kind) SB=$(g secure_boot) RAM=$(g ram_mb) LEVEL=$(g cpu_x86_level)
MAKER=$(g dmi_maker) PRODUCT=$(g dmi_product) FAMILY=$(g dmi_family)
RAM=${RAM:-0}; LEVEL=${LEVEL:-0}
RAM_GB=$(awk -v m="$RAM" 'BEGIN { printf "%.1f", m / 1024 }')
CPUFLAGS=" $(awk -F': *' '/^flags/{print $2; exit}' "$HW_ROOT/proc/cpuinfo" 2>/dev/null) "
NEEDS_KEY=0   # a driver built on this computer (NVIDIA, Broadcom wl) + Secure Boot on = approve a key once

# ---------------------------------------------------------------- which Linux (HW_DISTRO)
# Fedora 44/45 x86_64 runs on any 64-bit x86 CPU (baseline x86-64-v1) with 2 GB+. Below that, Debian.
# Memory bands (kernel-visible MB, with margins because shared-GPU machines under-report):
# under 480: unsupported; 480-1699: debian-lite; 1700-2999: fedora-min (Fedora, light LXQt desktop);
# 3000+: fedora (the desktop tier, full or lite, is chosen separately below).
# Debian 13 has no 32-bit PC (i386) installer or kernel; Debian 12 i386 has LTS until 30 June 2028.
DISTRO=fedora REASON="64-bit Intel/AMD PC with ${RAM_GB} GB memory: Fedora, the normal path"
case "$ARCH" in
  aarch64|arm64|arm*)
    if [ "$MACK" = apple-silicon ]; then DISTRO=asahi; REASON="Apple Silicon Mac: Fedora Asahi Remix, installed from macOS"
    else DISTRO=unsupported; REASON="ARM computer that is not an Apple Silicon Mac"; fi ;;
  *)
    if [ "$(g cpu_64bit)" = yes ]; then
      if [ "$RAM" -lt 480 ]; then DISTRO=unsupported; REASON="only ${RAM_GB} GB memory: below what any current desktop Linux needs (512 MB)"
      elif [ "$RAM" -lt 1700 ]; then DISTRO=debian-lite; REASON="64-bit PC with only ${RAM_GB} GB memory: Fedora needs 2 GB; Debian 13 with a light desktop fits"
      elif [ "$MACK" = intel-t2 ]; then DISTRO=fedora-t2; REASON="Intel Mac with T2 chip: Fedora plus the t2linux kernel for its keyboard, trackpad, Wi-Fi and sound"
      elif [ "$RAM" -lt 3000 ]; then DISTRO=fedora-min; REASON="Fedora runs here, but the desktop needs to be the light one (LXQt) so your apps have room to breathe. The installer will use simple text screens."
      fi
    else
      case "$CPUFLAGS" in
        *" cmov "*)
          if [ "$RAM" -lt 480 ]; then DISTRO=unsupported; REASON="32-bit PC with only ${RAM_GB} GB memory: below Debian's 512 MB minimum"
          else DISTRO=debian-i386; REASON="32-bit-only processor: Fedora is 64-bit only; Debian 12 (32-bit) is supported until June 2028"; fi ;;
        *) DISTRO=unsupported; REASON="processor older than a Pentium Pro/II (i686): no current Linux distribution supports it" ;;
      esac
    fi ;;
esac

# ---------------------------------------------------------------- processor
case "$ARCH" in
  aarch64|arm64|arm*)
    if [ "$MACK" = apple-silicon ]; then
      ASAHI=1
      _add no "Apple Silicon Mac ($(g mac_model)): this USB stick can't start it." \
        "It only starts PCs with Intel or AMD processors. Instead, install Fedora Asahi Remix" \
        "from macOS (Terminal: curl https://alx.sh | sh), then run this package's setup on it." \
        "Guide: linux-setup/asahi/README.md on this stick."
    else
      _add no "ARM processor ($ARCH): this USB stick only starts Intel/AMD (x86-64) PCs."
    fi ;;
  *)
    if [ "$(g cpu_64bit)" != yes ]; then
      _add no "32-bit processor ($(g cpu_model)): Fedora needs a 64-bit (x86-64) processor."
    else
      _add ok "64-bit processor: $(g cpu_model) (x86-64-v$LEVEL)"
      [ "$LEVEL" -le 1 ] && _add info "Very old processor: it works, but some apps will be slow. LITE suggested."
    fi ;;
esac

# ---------------------------------------------------------------- memory
if [ "$RAM" -lt 1700 ]; then
  _add no "Memory: $RAM_GB GB. Fedora needs at least 2 GB (4 GB or more recommended)."
  TEXT=1
elif [ "$RAM" -lt 3000 ]; then
  _add note "Memory: $RAM_GB GB: enough for the lightest setup (LXQt desktop). The installer runs in its" \
    "simpler text mode (uses less memory). Web pages with many tabs will be slow."
  TEXT=1
elif [ "$RAM" -lt 4600 ]; then
  _add note "Memory: $RAM_GB GB: LITE setup recommended; the installer runs in text mode to be safe."
  TEXT=1
elif [ "$RAM" -lt 7000 ]; then
  _add ok "Memory: $RAM_GB GB (LITE suggested: FULL needs 8 GB)"
else
  _add ok "Memory: $RAM_GB GB"
fi
if [ "$RAM" -lt 7000 ]; then PROFILE=lite; WHY="$RAM_GB GB memory"; fi
if [ "$LEVEL" -le 1 ] && [ "$ARCH" = x86_64 ]; then PROFILE=lite; WHY="${WHY:+$WHY, }very old processor"; fi
[ $ASAHI = 1 ] && { PROFILE=full; WHY="Fedora Asahi Remix (KDE)"; TEXT=0; }

# ---------------------------------------------------------------- start-up firmware / Secure Boot
if [ $ASAHI = 0 ]; then
  if [ "$(g firmware)" = uefi ]; then
    if [ "$(g efi_bits)" = 32 ]; then
      _add note "32-bit UEFI firmware with a 64-bit processor: this stick may not start." \
        "If it doesn't, switch the firmware to Legacy/CSM boot (if it has that option)."
    else
      _add ok "UEFI start-up firmware"
    fi
    case "$SB" in
      on)  _add ok "Secure Boot is on: fine, Fedora is signed (keep it on)" ;;
      off) _add ok "Secure Boot is off: fine (you can switch it on after installing)" ;;
    esac
  else
    _add ok "Legacy BIOS start-up (no UEFI): fine, Fedora installs the classic way"
  fi
fi

# ---------------------------------------------------------------- Macs and makers
case "$MACK" in
  intel-t2)
    ASK=1; WIRED=1
    _add note "Mac with Apple's T2 chip ($(g mac_model)): Fedora installs, then setup adds the" \
      "t2linux kernel so the built-in keyboard, trackpad, Touch Bar and sound work. Until then" \
      "use a USB keyboard + mouse and a wired connection (USB Ethernet or phone USB tethering)." \
      "Wi-Fi needs Apple's firmware: BEFORE erasing macOS, run get-apple-firmware.sh from this" \
      "stick (linux-setup/linux/hw/mac) in macOS Terminal. Needed in macOS Recovery > Startup Security" \
      "Utility: 'No Security' + 'Allow booting from external media'. You can cancel and keep macOS." ;;
  intel)
    _add ok "Intel Mac ($(g mac_model)): supported. Function keys are set to work like a PC's" \
      "(press Fn for brightness/volume) and fan control (mbpfan) is added for MacBooks."
    [ "$(g mac_facetimehd)" = yes ] && _add note "The built-in FaceTime HD camera needs a driver Fedora doesn't include," \
      "so it won't work (a USB webcam will). docs/COMPATIBILITY.md has the optional manual steps."
    ;;
esac
case "$MAKER" in
  toshiba) _add info "Toshiba: hotkeys, backlight and Bluetooth switch use Fedora's built-in toshiba_acpi driver." ;;
  dell)    _add info "Dell: keyboard light and hotkeys use Fedora's built-in dell-laptop driver." ;;
  lenovo)  _add info "Lenovo: ThinkPad buttons, keyboard light and battery charge limits work out of the box." ;;
  microsoft)
    _add note "Microsoft Surface: the touch screen, pen, cameras and some keyboard covers need the" \
      "linux-surface kernel (not included). Use a USB keyboard if the cover doesn't respond." ;;
  google)
    _add note "Chromebook: only works with custom UEFI firmware (MrChromebox). Speakers and" \
      "microphone often don't work; check the model on docs.mrchromebox.tech first." ;;
esac

# ---------------------------------------------------------------- graphics
NV=$(g nvidia_class) NVF=$(g nvidia_family)
case "$NV" in
  modern)
    _add note "NVIDIA $NVF graphics: NVIDIA's driver installs by itself during setup" \
      "(until then the open-source driver is used: it works, but games are slow)."
    NEEDS_KEY=1 ;;
  580xx)
    _add note "NVIDIA $NVF graphics: NVIDIA's 580 driver series (the last one for this card)" \
      "installs by itself during setup."
    NEEDS_KEY=1 ;;
  legacy)
    _add note "NVIDIA $NVF graphics (older card): uses the built-in open-source driver (nouveau)." \
      "Desktop and video work; 3D games are slow. NVIDIA's own driver doesn't support" \
      "this card on current Fedora." ;;
esac
[ "$(g gpu_amd)" = yes ] && _add ok "AMD Radeon graphics: works out of the box"
[ "$(g gpu_intel)" = yes ] && _add ok "Intel graphics: works out of the box"
[ "$(g hybrid)" = yes ] && _add ok "Two graphics chips (switchable): apps use the power-saving one; for games," \
  "right-click the app > 'Launch using Dedicated Graphics Card'."

# ---------------------------------------------------------------- network
WV=$(g wifi_vendor) BDRV=$(g wifi_broadcom_driver) ETH=$(g eth_count)
if [ "$MACK" != intel-t2 ] && [ $ASAHI = 0 ]; then
  case "$WV:$BDRV" in
    broadcom:wl)
      _add note "Broadcom Wi-Fi ($(g wifi_ids)): works after setup installs Broadcom's driver." \
        "During the installation itself use Ethernet or phone USB tethering."
      WIRED=1; NEEDS_KEY=1 ;;
    broadcom:b43)
      _add note "Old Broadcom Wi-Fi ($(g wifi_ids)): needs firmware that can't be included." \
        "Use Ethernet; docs/COMPATIBILITY.md shows the one-time b43-fwcutter step."
      WIRED=1 ;;
    broadcom:unknown)
      _add note "Broadcom Wi-Fi chip not in our list ($(g wifi_ids)): it may need an extra driver." \
        "Use Ethernet or phone USB tethering during the installation."
      WIRED=1 ;;
    broadcom:builtin) _add ok "Wi-Fi: Broadcom (driver built into Fedora)" ;;
    intel:*)    _add ok "Wi-Fi: Intel (works out of the box)" ;;
    mediatek:*) _add ok "Wi-Fi: MediaTek (works out of the box)" ;;
    realtek:*)  _add ok "Wi-Fi: Realtek (works out of the box)" ;;
    atheros:*)  _add ok "Wi-Fi: Qualcomm Atheros (works out of the box)" ;;
    other:*)    _add info "Wi-Fi: present (unknown make: check it after installing)" ;;
    none:*)     _add info "No built-in Wi-Fi found" ;;
  esac
  if [ "${ETH:-0}" -gt 0 ]; then _add ok "Ethernet port: $(g eth_vendor)"
  elif [ $WIRED = 1 ]; then
    _add info "No Ethernet port: plug in your phone by USB and turn on 'USB tethering', or use a USB Ethernet adapter."
  fi
  if [ "$WV" = none ] && [ "${ETH:-0}" = 0 ]; then
    _add note "No Wi-Fi or Ethernet found: installing needs internet (phone USB tethering works)."
    WIRED=1
  fi
fi
if [ $NEEDS_KEY = 1 ] && [ "$SB" = on ]; then
  _add note "Secure Boot + a driver built on this computer: once, after setup, a blue 'MOK management'" \
    "screen appears at restart. Choose Enroll MOK > Continue > Yes, type the one-time code" \
    "Secure Linux shows you, then Reboot. (Skip it and the driver stays off; nothing breaks.)"
fi

# ---------------------------------------------------------------- drives
DISKS=$(g disk_count) BIG=0
for ((i = 1; i <= ${DISKS:-0}; i++)); do
  IFS=: read -r dn dk dg <<< "$(g "disk_$i")"
  case "$dk" in nvme) kt="NVMe SSD" ;; ssd) kt="SSD" ;; hdd) kt="hard disk (slower than an SSD)" ;; emmc) kt="eMMC (slow)" ;; *) kt=$dk ;; esac
  [ "${dg:-0}" -ge 16 ] && BIG=$((BIG + 1))
  _add ok "Drive: $dn, $dg GB $kt"
done
if [ $ASAHI = 0 ] && [ "$BIG" -eq 0 ]; then _add no "No internal drive of 16 GB or more: there is nowhere to install."; DISTRO=unsupported; REASON="no internal drive of 16 GB or more"; fi
[ "${DISKS:-0}" -gt 1 ] && _add info "Several drives: the installer asks which ONE to erase; the others are not touched."

# ---------------------------------------------------------------- power
if [ "$(g battery)" = yes ]; then
  if [ "$SB" = on ]; then
    _add info "Battery: sleep (lid close) works. Hibernate is optional and needs Secure Boot off" \
      "(Secure Boot blocks it); the welcome screen explains the choice."
  else
    _add info "Battery: sleep (lid close) works; hibernate can be switched on from the welcome screen."
  fi
fi

# ---------------------------------------------------------------- verdict
if [ $BLOCKERS -gt 0 ]; then VERDICT=unsupported; VTEXT="NOT SUPPORTED BY THIS USB"; STATUS=UNSUPPORTED
elif [ $NOTES -gt 0 ]; then VERDICT=notes; VTEXT="WORKS WITH NOTES"; STATUS=NOTES
else VERDICT=good; VTEXT="GOOD"; STATUS=OK; fi
[ -n "$WHY" ] || WHY="$RAM_GB GB memory"

NAME="$(g dmi_vendor) $PRODUCT"
if [ -n "$FAMILY" ] && [ "$FAMILY" != "$PRODUCT" ]; then
  case "$FAMILY" in *"To be filled"*|*"Default string"*|*_*) ;; *) NAME="$NAME ($FAMILY)" ;; esac
fi
[ $ASAHI = 1 ] && NAME=$(g mac_model)

case "$DISTRO" in
  fedora|fedora-min) PARA="" ;;
  fedora-t2) PARA="This Mac gets Fedora plus the community t2linux kernel (added automatically during setup), so its built-in keyboard, trackpad, Touch Bar, sound and (with the firmware saved from macOS) Wi-Fi work. The apps and settings are the same as on any other computer." ;;
  asahi)     PARA="Apple Silicon Macs get Fedora Asahi Remix, the official Fedora build for these Macs. It is installed from macOS next to it (no USB stick), and then this package's setup.sh gives it the same apps and settings, except a few that only exist for Intel/AMD PCs (see linux-setup/asahi/README.md)." ;;
  debian-lite) PARA="This computer has too little memory for Fedora. Restart, and in the USB menu choose the Debian entry for older PCs: it installs Debian 13 with a light desktop and the same security settings, with fewer apps." ;;
  debian-i386) PARA="This computer's processor is 32-bit only, and Fedora is 64-bit only. Restart, and in the USB menu choose the Debian (32-bit) entry: it installs Debian 12 for 32-bit PCs (security updates until June 2028) with a light desktop and the same security settings, with fewer apps." ;;
  unsupported) PARA="Sorry: this computer is below what current Linux distributions support ($REASON)." ;;
esac

echo "  Compatibility check: ${NAME# }"
echo
printf '%s\n' "${LINES[@]}"
echo
echo "  Verdict: $VTEXT"
if [ "$DISTRO" = fedora-min ]; then echo "  Recommended setup: MIN (LXQt, essential apps)  [$WHY]"
elif [ "$DISTRO" = fedora ] || [ "$DISTRO" = fedora-t2 ] || [ "$DISTRO" = asahi ]; then
  if [ "$PROFILE" = full ]; then echo "  Recommended setup: FULL (KDE Plasma, every app)  [$WHY]"
  else echo "  Recommended setup: LITE (Xfce, essential apps)  [$WHY]"; fi
fi
if [ -n "$PARA" ]; then
  echo
  printf '%s\n' "$PARA" | fold -s -w 76 | sed 's/^/  /; s/ *$//'
fi

if [ $INSTALLER = 1 ]; then
  echo "HW_STATUS=$STATUS"
  echo "HW_PROFILE=$PROFILE"
  echo "HW_TEXT_INSTALL=$TEXT"
  echo "HW_DISTRO=$DISTRO"
  echo "HW_DISTRO_REASON=$REASON"
fi

if [ -n "$EXPORT" ]; then
  q() { printf "%s=%q\n" "$1" "$2"; }
  {
    q HW_VERDICT "$VERDICT"
    q HW_STATUS "$STATUS"
    q HW_VERDICT_TEXT "$VTEXT"
    q HW_PROFILE_SUGGEST "$PROFILE"
    q HW_PROFILE_WHY "$WHY"
    q HW_TEXT_INSTALL "$TEXT"
    q HW_DISTRO "$DISTRO"
    q HW_DISTRO_REASON "$REASON"
    q HW_BLOCKERS "$BLOCKERS"
    q HW_BLOCKER_TEXT "$BLOCKER_TEXT"
    q HW_NOTES "$NOTES"
    q HW_ASK_CONTINUE "$ASK"
    q HW_NEEDS_WIRED "$WIRED"
    q HW_ASAHI "$ASAHI"
    q HW_T2 "$( [ "$MACK" = intel-t2 ] && echo 1 || echo 0)"
    q HW_SECURE_BOOT "$SB"
    q HW_NEEDS_MOK "$( [ $NEEDS_KEY = 1 ] && [ "$SB" = on ] && echo 1 || echo 0)"
    q HW_NVIDIA "$NV"
    q HW_FIRMWARE "$(g firmware)"
    q HW_RAM_MB "$RAM"
  } > "$EXPORT"
fi

[ $INSTALLER = 1 ] && exit 0
case $VERDICT in good) exit 0 ;; notes) exit 1 ;; *) exit 2 ;; esac
