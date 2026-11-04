#!/bin/sh
# hw/compat-check-min.sh (owner: hardware) - the small, POSIX-sh compatibility check for installers WITHOUT bash:
# the Debian installer (busybox ash, e.g. from preseed "d-i preseed/early_command"). Same decision rules and
# the same machine-readable lines as compat-check.sh --installer, but a much shorter report.
#
#   sh compat-check-min.sh [--fixture DIR]
#
# Prints a short plain-ASCII report, then:
#   HW_STATUS=OK|NOTES|UNSUPPORTED     relative to the DEBIAN path (UNSUPPORTED = below Debian's minimums)
#   HW_DISTRO=fedora|fedora-min|fedora-t2|asahi|debian-lite|debian-i386|unsupported   (the best Linux for this computer)
#   HW_DISTRO_REASON=<one line>
#   HW_PROFILE=lite                    (the Debian paths always use the light desktop)
#   HW_NEEDS_WIRED=0|1                 Wi-Fi needs a non-free driver/firmware that d-i may not have
#   HW_NVIDIA=none|modern|580xx|legacy
# Always exits 0. Needs only: sh (busybox ash is fine), cat, grep, sed, awk, tr, head, uname.

R=""
while [ $# -gt 0 ]; do
  case "$1" in --fixture) R=${2%/}; shift ;; esac
  shift
done

rd() { [ -r "$R$1" ] && head -n 1 "$R$1" 2>/dev/null | tr -d '\000' | sed 's/[[:space:]]*$//'; }
if [ -n "$R" ]; then ARCH=$(rd /uname-m); ARCH=${ARCH:-x86_64}; else ARCH=$(uname -m); fi
FLAGS=" $(awk -F': *' '/^flags/{print $2; exit}' "$R/proc/cpuinfo" 2>/dev/null) "
MODEL=$(awk -F': *' '/^model name/{print $2; exit}' "$R/proc/cpuinfo" 2>/dev/null)
KB=$(awk '/^MemTotal:/{print $2; exit}' "$R/proc/meminfo" 2>/dev/null); KB=${KB:-0}
RAM=$((KB / 1024))
RAM_GB=$(awk -v m="$RAM" 'BEGIN { printf "%.1f", m / 1024 }')
VENDOR=$(rd /sys/class/dmi/id/sys_vendor); PRODUCT=$(rd /sys/class/dmi/id/product_name)
has() { case "$FLAGS" in *" $1 "*) return 0 ;; esac; return 1; }

# PCI scan: "vendor:device:class" per device, lower case, no 0x
PCI=""
for d in "$R"/sys/bus/pci/devices/*; do
  [ -r "$d/vendor" ] || continue
  v=$(tr 'A-F' 'a-f' < "$d/vendor" | sed 's/^0x//'); dv=$(tr 'A-F' 'a-f' < "$d/device" | sed 's/^0x//')
  c=$(tr 'A-F' 'a-f' < "$d/class" | sed 's/^0x//')
  PCI="$PCI $v:$dv:$c"
done

T2=no AS=no
case "$ARCH" in aarch64|arm*) grep -q 'apple,' "$R/proc/device-tree/compatible" 2>/dev/null && AS=yes ;; esac
case "$VENDOR" in Apple*)
  case "$PCI" in *" 106b:1801:"*|*" 106b:1802:"*) T2=yes ;; esac
  case "$PRODUCT" in MacBookPro15,*|MacBookPro16,*|MacBookAir8,*|MacBookAir9,1|Macmini8,1|iMac20,*|iMacPro1,1|MacPro7,1) T2=yes ;; esac ;;
esac

# NVIDIA generation (same id thresholds as detect.sh: >= 1e00 modern, >= 1340 580xx, else legacy)
NV=none
for p in $PCI; do
  case "$p" in
    10de:*:03*) id=$(echo "$p" | cut -d: -f2); n=$(printf '%d' "0x$id" 2>/dev/null || echo 0)
      if [ "$n" -ge 7680 ]; then NV=modern; elif [ "$n" -ge 4928 ]; then NV=580xx; else NV=legacy; fi ;;
  esac
done
# Wi-Fi that needs non-free bits (Broadcom wl / b43 chips)
WIRED=0
for p in $PCI; do
  case "$p" in
    14e4:4311:*|14e4:4312:*|14e4:4315:*|14e4:4328:*|14e4:4329:*|14e4:432a:*|14e4:432b:*|14e4:432c:*|14e4:432d:*|\
    14e4:4331:*|14e4:4358:*|14e4:4359:*|14e4:4360:*|14e4:4365:*|14e4:43a0:*|14e4:43b1:*|14e4:43b2:*|\
    14e4:4301:*|14e4:4306:*|14e4:4307:*|14e4:4318:*|14e4:4319:*|14e4:4320:*|14e4:4324:*|14e4:4325:*) WIRED=1 ;;
  esac
done

STATUS=OK NOTES=""
note() { NOTES="$NOTES
  [NOTE] $1"; [ "$STATUS" = OK ] && STATUS=NOTES; }
DISTRO=fedora REASON="64-bit Intel/AMD PC with $RAM_GB GB memory: Fedora, the normal path"
case "$ARCH" in
  aarch64|arm*)
    if [ $AS = yes ]; then DISTRO=asahi; REASON="Apple Silicon Mac: Fedora Asahi Remix, installed from macOS"
    else DISTRO=unsupported; REASON="ARM computer that is not an Apple Silicon Mac"; fi
    STATUS=UNSUPPORTED ;;
  *)
    if has lm; then
      if [ "$RAM" -lt 480 ]; then DISTRO=unsupported; REASON="only $RAM_GB GB memory: below the 512 MB minimum"; STATUS=UNSUPPORTED
      elif [ "$RAM" -lt 1700 ]; then DISTRO=debian-lite; REASON="64-bit PC with only $RAM_GB GB memory: Fedora needs 2 GB; Debian 13 with a light desktop fits"
      elif [ $T2 = yes ]; then DISTRO=fedora-t2; REASON="Intel Mac with T2 chip: Fedora plus the t2linux kernel"
      elif [ "$RAM" -lt 3000 ]; then DISTRO=fedora-min; REASON="Fedora runs here, but the desktop needs to be the light one (LXQt) so your apps have room to breathe. The installer will use simple text screens."
      fi
    elif has cmov; then
      if [ "$RAM" -lt 480 ]; then DISTRO=unsupported; REASON="32-bit PC with only $RAM_GB GB memory: below Debian's 512 MB minimum"; STATUS=UNSUPPORTED
      else DISTRO=debian-i386; REASON="32-bit-only processor: Debian 12 (32-bit) is supported until June 2028"; fi
    else
      DISTRO=unsupported; REASON="processor older than i686: no current Linux distribution supports it"; STATUS=UNSUPPORTED
    fi ;;
esac
[ "$RAM" -ge 480 ] && [ "$RAM" -lt 900 ] && note "Only $RAM_GB GB memory: the installer uses its low-memory mode; expect a slow desktop."
[ $WIRED = 1 ] && note "Broadcom Wi-Fi needs a non-free driver: use Ethernet or phone USB tethering to install."
[ "$NV" = legacy ] && note "Older NVIDIA graphics: the open-source driver (nouveau) is used."
[ $T2 = yes ] && note "T2 Mac: built-in keyboard/trackpad need the t2linux kernel; use a USB keyboard."

echo "  Compatibility check: $VENDOR $PRODUCT"
echo "  Processor: ${MODEL:-$ARCH}   Memory: $RAM_GB GB"
[ -n "$NOTES" ] && printf '%s\n' "$NOTES" | sed '1d'
echo "  Best Linux for this computer: $DISTRO ($REASON)"
case "$DISTRO" in
  fedora|fedora-t2) echo "  This computer can run the main (Fedora) setup: restart and choose it in the USB menu." ;;
  fedora-min) echo "  This computer can run the main (Fedora) setup with its lightest desktop: restart and choose the Fedora entry in the USB menu." ;;
  asahi) echo "  Install Fedora Asahi Remix from macOS instead (see linux-setup/asahi/README.md)." ;;
esac
echo "HW_STATUS=$STATUS"
echo "HW_DISTRO=$DISTRO"
echo "HW_DISTRO_REASON=$REASON"
echo "HW_PROFILE=lite"
echo "HW_NEEDS_WIRED=$WIRED"
echo "HW_NVIDIA=$NV"
exit 0
