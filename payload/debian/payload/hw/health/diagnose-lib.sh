# shellcheck shell=bash
# hw/health/diagnose-lib.sh (owner: U2 diagnose) - the engine of secure-linux-diagnose.
# Source it after lib.sh; do not run it. It READS the system (files, command output, the hardware health report) and
# decides which problems from the knowledge base (kb/*.tsv) are present. It never changes anything.
#
# Test hooks (never set on a real machine):
#   SL_DIAG_FIXTURE=DIR   DIR/root = fake file tree (etc, boot, sys, proc), DIR/cmd/KEY = output of command KEY,
#                         DIR/health.json = output of secure-linux-health --json. No real command is run.
#   SL_TEST_UID           pretend to be root (0) or a normal user
#
# The knowledge base: one problem per line, 22 tab-separated columns (see kb/README.txt). The "detector" column is a small
# expression:   TERM && TERM || TERM     (&& binds tighter than ||; a leading ! negates a term)
#   cmd:KEY~REGEX[#N]    output of command KEY has at least N lines matching REGEX (default 1)
#   file:PATH[~REGEX[#N]] file exists (and matches). PATH starting with sys/ or proc/ means the live /sys and /proc
#   glob:PATTERN         some file matches (relative to the system being checked)
#   health:PART[:ITEM]=STATUS[,STATUS][~REGEX]   a result in the hardware health report (ITEM is a glob; !GLOB = does not match)
#   val:KEY OP N         a number (disk-use-root>=90); OP is >= <= > < == !=
#   env:NAME             uefi bios laptop desktop secureboot fedora debian installed rescue live root battery profile=lite ...
#   choice:KEY=VALUE     a saved Secure Linux choice (choice:KEY!=VALUE also; unset counts as empty)
#   fn:NAME              a custom check function dx_NAME (diagnose-detect.sh)
# Every term answers yes / no / "could not check" (tool missing, needs administrator rights). "Could not check" never
# raises a problem; it is listed so the person knows the check was limited.

[ -n "${SD_LIB_LOADED:-}" ] && return 0
SD_LIB_LOADED=1

SD_FIX=${SL_DIAG_FIXTURE:-}
SD_ROOT=${SD_ROOT:-/}
SD_MODE=quick
SD_AUTOPILOT=0
SD_TMP=""
declare -A SD_TXT=() SD_DFC=()
declare -A SD_DONE=() SD_LIMSEEN=() SD_VALC=() SD_ANSWERS=()
declare -a SD_LIM=() KB=() CORR_W=() CORR_L=() CORR_N=()
SD_F=""; SD_R=1; SD_DET=""; SD_HITEM=""; SD_CONF=high; SD_V=0
SD_ASK_Q=""; SD_ASK_DEF=""; declare -a SD_ASK_CH=() SD_ARGS=()
H_N=0; H_STATE=none        # none | ready | unavailable
declare -a H_PART=() H_ITEM=() H_ST=() H_MEAN=() H_TODO=()
US=$'\037'; RS=$'\036'

# ---------------------------------------------------------------- paths and small helpers
sd_pathv() {   # sd_pathv VAR rel/path : VAR = real path (sys/ and proc/ are the live ones; the rest is inside the system being checked). No fork.
  local p=${2#/} __r
  case "$p" in
    sys|sys/*) __r="$SLH_SYS${p#sys}" ;;
    proc|proc/*) __r="$SLH_PROC${p#proc}" ;;
    *) if [ "$SD_ROOT" = / ]; then __r="/$p"; else __r="${SD_ROOT%/}/$p"; fi ;;
  esac
  printf -v "$1" '%s' "$__r"
}
sd_path() { local __p; sd_pathv __p "$1"; printf '%s' "$__p"; }
sd_limited() {   # sd_limited "plain English": remember once
  [ -n "${SD_LIMSEEN[$1]:-}" ] && return 0
  SD_LIMSEEN[$1]=1; SD_LIM+=("$1")
}
sd_short() { local v=$1; v=${v//$'\t'/ }; v=${v//$'\r'/}; v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}; printf '%s' "${v:0:${2:-140}}"; }
sd_osr() {   # sd_osr KEY -> value from the checked system's os-release (read, never executed)
  local f; f=$(sd_path etc/os-release); [ -r "$f" ] || f=$(sd_path usr/lib/os-release)
  [ -r "$f" ] || return 0
  sed -n "s/^$1=//p" "$f" 2>/dev/null | head -n1 | tr -d '"'
}
SD_FAMILY=""; SD_ENVC=""
sd_init_env() {   # works out once: the distro family of the checked system and where we are running from
  local id="" like="" f l
  sd_pathv f etc/os-release; [ -r "$f" ] || sd_pathv f usr/lib/os-release
  if [ -r "$f" ]; then
    while IFS= read -r l; do case "$l" in ID=*) id=${l#ID=} ;; ID_LIKE=*) like=${l#ID_LIKE=} ;; esac; done < "$f"
    id=${id//\"/}; like=${like//\"/}
  fi
  case " $id $like " in *" fedora "*|*" rhel "*|*" centos "*) SD_FAMILY=fedora ;; *" debian "*|*" ubuntu "*) SD_FAMILY=debian ;; *) SD_FAMILY=other ;; esac
  if [ -n "${SL_DIAG_ENV:-}" ]; then SD_ENVC=$SL_DIAG_ENV
  else case "$(rp_env 2>/dev/null)" in installed) SD_ENVC=installed ;; systemrescue|anaconda-rescue) SD_ENVC=rescue ;; *) SD_ENVC=live ;; esac; fi
}
sd_family() { [ -n "$SD_FAMILY" ] || sd_init_env; printf '%s' "$SD_FAMILY"; }
sd_envclass() { [ -n "$SD_ENVC" ] || sd_init_env; printf '%s' "$SD_ENVC"; }
sd_choice() {   # sd_choice KEY [default]
  local f v=""; f=$(sd_path etc/secure-linux/choices)
  [ -r "$f" ] && v=$(sed -n "s/^$1=//p" "$f" | tail -n1)
  printf '%s' "${v:-${2:-}}"
}
sd_isuefi() { if [ -n "${SL_TEST_EFI:-}" ]; then [ "$SL_TEST_EFI" = uefi ]; else [ -d "$SLH_SYS/firmware/efi" ]; fi; }
sd_user() {   # the main user's login name
  local u; u=$(cat "$(sd_path etc/secure-linux/user)" 2>/dev/null | head -n1)
  [ -n "$u" ] || u=$(ls -1 "$(sd_path home)" 2>/dev/null | head -n1)
  printf '%s' "$u"
}

# ---------------------------------------------------------------- commands (key -> tool|where|plain label|seconds|command)
# where: any = also valid for a system mounted elsewhere (--root); run = only the running system. The command gets the root as $1.
sd_cmd_def() {
  case "$1" in
    klog)       echo 'dmesg|run|the kernel messages|10|dmesg 2>&1 || journalctl -k -b --no-pager -q 2>&1' ;;
    jerr)       echo 'journalctl|any|the system log|15|if [ "$1" = / ]; then journalctl -b -p err --no-pager -q 2>&1; else journalctl -D "$1/var/log/journal" -b -1 -p err --no-pager -q 2>&1; fi | head -n 800' ;;
    jprev)      echo 'journalctl|any|the log of the last start-up|15|if [ "$1" = / ]; then journalctl -b -1 -p warning --no-pager -q 2>&1; else journalctl -D "$1/var/log/journal" -b -1 -p warning --no-pager -q 2>&1; fi | head -n 1500' ;;
    efibootmgr) echo 'efibootmgr|any|the start-up list|6|efibootmgr -v 2>&1' ;;
    sbstate)    echo 'mokutil|any|the Secure Boot state|6|mokutil --sb-state 2>&1' ;;
    mokkey)     echo 'mokutil|run|the driver key|6|k=/etc/pki/akmods/certs/public_key.der; [ -f $k ] && mokutil --test-key $k 2>&1 || echo "no key file"' ;;
    lsblk)      echo 'lsblk|any|the list of drives|6|lsblk -rno NAME,TYPE,FSTYPE,RM,RO,MOUNTPOINT,SIZE,PKNAME 2>&1' ;;
    lsblkfs)    echo 'lsblk|any|the list of drives|6|lsblk -P -p -o NAME,FSTYPE,SIZE,LABEL,MOUNTPOINT 2>&1' ;;
    lsblkj)     echo 'lsblk|any|the list of drives|6|lsblk -rpno NAME,TYPE,FSTYPE,RM,SIZE,MODEL,TRAN 2>&1' ;;
    findmnt)    echo 'findmnt|run|the mounted drives|6|findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS 2>&1' ;;
    df)         echo 'df|any|how full the drives are|8|df -P 2>&1' ;;
    dfi)        echo 'df|any|how full the drives are (file count)|8|df -Pi 2>&1' ;;
    failed)     echo 'systemctl|run|the failed services|8|systemctl --failed --no-legend --plain 2>&1' ;;
    nmstate)    echo 'nmcli|run|the network state|6|nmcli -t -f STATE general 2>&1' ;;
    nmconn)     echo 'nmcli|run|the internet test|8|nmcli networking connectivity check 2>&1' ;;
    nmdev)      echo 'nmcli|run|the network devices|6|nmcli -t -f DEVICE,TYPE,STATE device 2>&1' ;;
    rfkill)     echo 'rfkill|run|the radio switches|6|rfkill list 2>&1' ;;
    dnstest)    echo 'getent|run|the name lookup test|5|getent hosts fedoraproject.org 2>&1; echo "[rc=$?]"' ;;
    pingip)     echo 'ping|run|the internet test|6|ping -c1 -W2 1.1.1.1 2>&1; echo "[rc=$?]"' ;;
    mtutest)    echo 'ping|run|the packet-size test|6|ping -c1 -W2 -M do -s 1472 1.1.1.1 2>&1; echo "[rc=$?]"' ;;
    ping6)      echo 'ping|run|the IPv6 test|6|ping -6 -c1 -W2 2606:4700:4700::1111 2>&1; echo "[rc=$?]"' ;;
    ipv6route)  echo 'ip|run|the IPv6 route|4|ip -6 route show default 2>&1' ;;
    iwreg)      echo 'iw|run|the Wi-Fi country|4|iw reg get 2>&1' ;;
    fwstate)    echo 'firewall-cmd|run|the firewall|6|firewall-cmd --state 2>&1' ;;
    ufwstate)   echo 'ufw|run|the firewall|6|ufw status 2>&1' ;;
    listen)     echo 'ss|run|the open network doors|6|ss -tln 2>&1' ;;
    timedate)   echo 'timedatectl|run|the clock settings|6|timedatectl show 2>&1' ;;
    rpmok)      echo 'rpm|any|the software list|8|rpm --root "$1" -q rpm 2>&1; echo "[rc=$?]"' ;;
    rpmdupes)   echo 'rpm|run|the software list|20|rpm -qa --qf "%{NAME}.%{ARCH}\n" 2>&1 | sort | uniq -d | head -n 20' ;;
    dpkgaudit)  echo 'dpkg|run|the software list|10|dpkg --audit 2>&1' ;;
    aptcheck)   echo 'apt-get|run|the software list|20|apt-get check 2>&1; echo "[rc=$?]"' ;;
    apthold)    echo 'apt-mark|run|held packages|6|apt-mark showhold 2>&1' ;;
    dnfcheck)   echo 'dnf|run|the software dependencies|60|dnf check 2>&1; echo "[rc=$?]"' ;;
    flatpakchk) echo 'flatpak|run|Flatpak apps|15|flatpak --system repair --dry-run 2>&1; echo "[rc=$?]"' ;;
    snapper)    echo 'snapper|run|the snapshots|10|snapper -c root list 2>&1' ;;
    btrfsusage) echo 'btrfs|run|the Btrfs usage|10|btrfs filesystem usage -b / 2>&1' ;;
    btrfsscrub) echo 'btrfs|run|the last Btrfs check|10|btrfs scrub status / 2>&1' ;;
    getenforce) echo 'getenforce|run|SELinux|4|getenforce 2>&1' ;;
    avc)        echo 'journalctl|run|security denials|15|journalctl -b -q --no-pager -g "avc: *denied" 2>&1 | tail -n 200' ;;
    authfail)   echo 'journalctl|run|failed sign-ins|15|journalctl -b -q --no-pager -g "Failed password|authentication failure" 2>&1 | tail -n 300' ;;
    analyze)    echo 'systemd-analyze|run|the start-up time|20|systemd-analyze 2>&1' ;;
    blame)      echo 'systemd-analyze|run|what slows the start-up|20|systemd-analyze blame 2>&1 | head -n 15' ;;
    wpvol)      echo 'wpctl|run|the sound volume|5|wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>&1' ;;
    wpmic)      echo 'wpctl|run|the microphone volume|5|wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>&1' ;;
    wpstatus)   echo 'wpctl|run|the sound devices|6|wpctl status 2>&1' ;;
    pactlcards) echo 'pactl|run|the sound cards|6|pactl list cards 2>&1' ;;
    lpstat)     echo 'lpstat|run|the printers|6|lpstat -t 2>&1' ;;
    lsusb)      echo 'lsusb|run|the USB devices|6|lsusb 2>&1' ;;
    boltctl)    echo 'boltctl|run|Thunderbolt|6|boltctl list 2>&1' ;;
    powerprof)  echo 'powerprofilesctl|run|the power mode|4|powerprofilesctl get 2>&1' ;;
    localectl)  echo 'localectl|run|the keyboard layout|4|localectl status 2>&1' ;;
    lspci)      echo 'lspci|run|the hardware list|8|lspci -nnk 2>&1' ;;
    lsmod)      echo 'lsmod|run|the loaded drivers|4|lsmod 2>&1' ;;
    modinfonv)  echo 'modinfo|run|the NVIDIA driver|6|modinfo -F version nvidia 2>&1; echo "[rc=$?]"' ;;
    pstop)      echo 'ps|run|running programs|6|ps -eo pid,pcpu,pmem,comm --sort=-pcpu 2>&1 | head -n 6' ;;
    pstopmem)   echo 'ps|run|running programs|6|ps -eo pid,pcpu,pmem,comm --sort=-pmem 2>&1 | head -n 4' ;;
    needsrestart) echo 'needs-restarting|run|pending restarts|15|needs-restarting -r 2>&1; echo "[rc=$?]"' ;;
    faillock)   echo 'faillock|run|failed sign-in locks|6|faillock 2>&1' ;;
    visudo)     echo 'visudo|any|the sudo settings|6|visudo -c -f "$1/etc/sudoers" 2>&1; echo "[rc=$?]"' ;;
    rootowned)  echo 'find|any|your home folder|15|find "$1/home" -maxdepth 3 -user root -not -path "*/.snapshots/*" 2>/dev/null | head -n 20' ;;
    jdisk)      echo 'journalctl|run|the size of the logs|6|journalctl --disk-usage 2>&1' ;;
    dnfcache)   echo 'du|any|the download cache|20|du -sm "$1/var/cache/dnf" "$1/var/cache/libdnf5" "$1/var/cache/apt" 2>/dev/null' ;;
    fstrim)     echo 'systemctl|run|the weekly SSD tidy-up|6|systemctl is-enabled fstrim.timer 2>&1; systemctl show fstrim.timer -p LastTriggerUSec 2>&1' ;;
    autoremove) echo 'dnf|run|unused packages|60|dnf --assumeno autoremove 2>&1 | grep -c "^ *Removing" ' ;;
    fwupd)      echo 'fwupdmgr|run|firmware updates|40|fwupdmgr get-updates --no-unreported-check 2>&1; echo "[rc=$?]"' ;;
    bluetoothd) echo 'systemctl|run|Bluetooth|4|systemctl is-active bluetooth 2>&1' ;;
    nmsvc)      echo 'systemctl|run|the network service|4|systemctl is-active NetworkManager 2>&1' ;;
    audiosvc)   echo 'systemctl|run|the sound service|4|systemctl --user is-active pipewire 2>&1' ;;
    cupssvc)    echo 'systemctl|run|the printing service|4|systemctl is-active cups 2>&1' ;;
    ntpstate)   echo 'timedatectl|run|the clock settings|6|timedatectl show -p NTPSynchronized -p NTP -p RTCInLocalTZ 2>&1' ;;
    vpnstate)   echo 'nordvpn|run|the VPN|8|nordvpn status 2>&1' ;;
    hacheck)    echo 'curl|run|the Home Assistant server|8|curl -fsS --max-time 5 -o /dev/null -w "%{http_code}" "$HA_URL" 2>&1; echo "[rc=$?]"' ;;
    *) return 1 ;;
  esac
}
# sd_load KEY -> output in $SD_F ; returns 0 ok, 126 needs administrator rights, 125 not valid for this --root, 127 tool missing
sd_load() {
  local k=$1 def tool where label tmo cmd rc out f first
  if [ -n "${SD_DONE[$k]:-}" ]; then SD_F="$SD_TMP/c.$k"; [ -n "$SD_FIX" ] && SD_F="$SD_FIX/cmd/$k"; return "${SD_DONE[$k]%%:*}"; fi
  if [ -n "$SD_FIX" ]; then
    f="$SD_FIX/cmd/$k"; SD_F=$f
    if [ ! -f "$f" ]; then SD_DONE[$k]=127; return 127; fi
    IFS= read -r first < "$f" 2>/dev/null
    case "$first" in '#rc=126') sd_limited "$(sd_cmd_def "$k" | cut -d'|' -f3) (needs administrator rights)"; SD_DONE[$k]=126; return 126 ;; '#rc='*) SD_DONE[$k]=${first#'#rc='}; return "${SD_DONE[$k]}" ;; esac
    SD_DONE[$k]=0; IFS= read -r -d '' SD_TXT[$k] < "$f"; return 0
  fi
  def=$(sd_cmd_def "$k") || { SD_DONE[$k]=127; return 127; }
  IFS='|' read -r tool where label tmo cmd <<< "$def"
  SD_F="$SD_TMP/c.$k"
  if [ "$where" = run ] && [ "$SD_ROOT" != / ]; then SD_DONE[$k]=125; return 125; fi
  have "$tool" || { SD_DONE[$k]=127; return 127; }
  export HA_URL; HA_URL=$(sd_choice ha_url http://homeassistant.local:8123)
  slh_t "$tmo" bash -c "$cmd" _ "$SD_ROOT" > "$SD_F" 2>&1
  rc=$?
  if grep -qiE 'permission denied|must be root|operation not permitted|you need to be root|not permitted|access denied|requires root|authentication is required' "$SD_F" 2>/dev/null && ! slh_is_root; then
    sd_limited "$label (needs administrator rights)"; SD_DONE[$k]=126; return 126
  fi
  [ "$rc" = 124 ] && sd_limited "$label (took too long, skipped)"
  SD_DONE[$k]=0; IFS= read -r -d '' SD_TXT[$k] < "$SD_F"; return 0
}
sd_cmd_text() { sd_load "$1" >/dev/null 2>&1 && cat "$SD_F" 2>/dev/null; }   # for the fix scripts: output of a key (empty if unavailable)

# ---------------------------------------------------------------- the hardware health report (from secure-linux-health --json)
SD_HEALTH_PID=""
sd_health_start() {   # start the (slow) health report in the background; sd_health_ready waits for it
  [ -n "$SD_FIX" ] && return 0
  local bin=${SD_HEALTH_BIN:-} mode=--quick c cache
  [ "$SD_MODE" = full ] && mode=--standard
  if [ -z "$bin" ]; then for c in "$SD_HERE/secure-linux-health" "$(command -v secure-linux-health 2>/dev/null)"; do [ -n "$c" ] && [ -x "$c" ] && { bin=$c; break; }; done; fi
  cache=$SL_STATE/health/latest.json
  if [ "$SD_MODE" = quick ] && [ -r "$cache" ] && [ -n "$(find "$cache" -mmin -360 2>/dev/null)" ]; then cp "$cache" "$SD_TMP/health.json" 2>/dev/null && return 0; fi
  [ -n "$bin" ] || return 0
  ( slh_t "$([ "$SD_MODE" = full ] && echo 240 || echo 45)" "$bin" "$mode" --json --no-save --no-interactive > "$SD_TMP/health.json" 2>/dev/null ) &
  SD_HEALTH_PID=$!
}
sd_health_ready() {   # 0 = H_* filled ; 2 = no hardware report available
  [ "$H_STATE" = ready ] && return 0
  [ "$H_STATE" = unavailable ] && return 2
  local f=$SD_TMP/health.json line p i s m t
  [ -n "$SD_FIX" ] && f=$SD_FIX/health.json
  if [ -n "$SD_HEALTH_PID" ]; then wait "$SD_HEALTH_PID" 2>/dev/null; SD_HEALTH_PID=""; fi
  if [ ! -s "$f" ]; then H_STATE=unavailable; sd_limited "the hardware health check (could not run here)"; return 2; fi
  H_N=0
  while IFS= read -r line; do
    case "$line" in *'"part": "'*) ;; *) continue ;; esac
    p=${line#*\"part\": \"}; p=${p%%\"*}
    i=${line#*\"item\": \"}; i=${i%%\"*}
    s=${line#*\"status\": \"}; s=${s%%\"*}
    m=${line#*\"meaning\": \"}; m=${m%%\", \"what_to_do\"*}
    t=${line#*\"what_to_do\": \"}; t=${t%%\", \"detail\"*}
    H_PART[H_N]=$p; H_ITEM[H_N]=$i; H_ST[H_N]=$s; H_MEAN[H_N]=$m; H_TODO[H_N]=$t; H_N=$((H_N + 1))
  done < "$f"
  H_STATE=ready
  if grep -q '"limited": \[".' "$f" 2>/dev/null && ! slh_is_root; then sd_limited "drive and memory details (the hardware check needs administrator rights)"; fi
  return 0
}

# ---------------------------------------------------------------- numbers (val:KEY)
sd_df_pct() {   # sd_df_pct KEY MOUNT -> SD_V = percent used of the mount (df -P / df -Pi output); no forks
  sd_load "$1" || return 2
  local l pct mp v="" n want=$2
  while IFS= read -r l; do
    set -- $l; n=$#; [ "$n" -ge 6 ] || continue
    mp=${!n}; pct=${@:n-1:1}
    [ "$mp" = "$want" ] && { v=${pct%\%}; break; }
  done <<< "${SD_TXT[$1]}"
  case "$v" in ''|*[!0-9]*) return 2 ;; esac
  SD_V=$v; return 0
}
sd_dur_secs() {   # "1min 12.5s" -> 72
  awk -v s="$1" 'BEGIN{ t=0; n=split(s,a," "); for(i=1;i<=n;i++){ v=a[i]; if (v ~ /min$/) t+=v*60; else if (v ~ /ms$/) t+=v/1000; else if (v ~ /s$/) t+=v+0; else if (v ~ /h$/) t+=v*3600 } printf "%d", t }'
}
sd_val() {   # sd_val KEY -> SD_V ; returns 2 if it cannot be worked out
  local k=$1 ov a b f line
  if [ -n "$SD_FIX" ]; then ov=SD_VAL_${k//-/_}; [ -n "${!ov:-}" ] && { SD_V=${!ov}; return 0; }; fi
  case "$k" in
    disk-use-root) sd_df_pct df /; return $? ;;
    disk-use-boot) sd_df_pct df /boot; return $? ;;
    disk-use-esp) sd_df_pct df /boot/efi; return $? ;;
    disk-use-home) sd_df_pct df /home; return $? ;;
    inode-use-root) sd_df_pct dfi /; return $? ;;
    mem-avail-pct) a=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{ if (t>0) printf "%d", a*100/t }' "$SLH_PROC/meminfo" 2>/dev/null); [ -n "$a" ] || return 2; SD_V=$a ;;
    ram-total-mb) a=$(awk '/^MemTotal:/{printf "%d", $2/1024}' "$SLH_PROC/meminfo" 2>/dev/null); [ -n "$a" ] || return 2; SD_V=$a ;;
    swap-total-mb) a=$(awk '/^SwapTotal:/{printf "%d", $2/1024}' "$SLH_PROC/meminfo" 2>/dev/null); [ -n "$a" ] || return 2; SD_V=$a ;;
    swap-used-pct) a=$(awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2} END{ if (t>0) printf "%d", (t-f)*100/t; else print 0 }' "$SLH_PROC/meminfo" 2>/dev/null); [ -n "$a" ] || return 2; SD_V=$a ;;
    kernels-count) a=0; for f in "$(sd_path boot)"/vmlinuz-*; do [ -e "$f" ] || continue; case "$f" in *rescue*) ;; *) a=$((a + 1)) ;; esac; done; SD_V=$a ;;
    boot-secs) sd_load analyze || return 2; a=$(sed -n 's/.*= *\(.*\)$/\1/p' "$SD_F" | head -n1); [ -n "$a" ] || return 2; SD_V=$(sd_dur_secs "$a") ;;
    wait-online-secs) sd_load blame || return 2; a=$(awk '/NetworkManager-wait-online|systemd-networkd-wait-online/{print $1; exit}' "$SD_F"); [ -n "$a" ] || { SD_V=0; return 0; }; SD_V=$(sd_dur_secs "$a") ;;
    journal-mb) sd_load jdisk || return 2; a=$(sed -n 's/.*take up \([0-9.]*\)\([KMGT]\).*/\1 \2/p' "$SD_F" | head -n1); [ -n "$a" ] || return 2
      SD_V=$(awk -v x="$a" 'BEGIN{ split(x,p," "); u=p[2]; v=p[1]; if(u=="K") v/=1024; else if(u=="G") v*=1024; else if(u=="T") v*=1048576; printf "%d", v }') ;;
    cache-mb) sd_load dnfcache || return 2; SD_V=$(awk '{s+=$1} END{printf "%d", s}' "$SD_F") ;;
    bat-health-pct) a=0; for f in "$SLH_SYS"/class/power_supply/BAT*; do [ -r "$f/energy_full_design" ] || [ -r "$f/charge_full_design" ] || continue
        local full des; full=$(slh_rd "$f/energy_full"); [ -n "$full" ] || full=$(slh_rd "$f/charge_full"); des=$(slh_rd "$f/energy_full_design"); [ -n "$des" ] || des=$(slh_rd "$f/charge_full_design")
        [ "${des:-0}" -gt 0 ] 2>/dev/null && { a=$((full * 100 / des)); break; }; done; [ "$a" -gt 0 ] || return 2; SD_V=$a ;;
    bat-charge-pct) a=""; for f in "$SLH_SYS"/class/power_supply/BAT*; do [ -r "$f/capacity" ] && { a=$(slh_rd "$f/capacity"); break; }; done; [ -n "$a" ] || return 2; SD_V=$a ;;
    cpu-temp) a=$(slh_temps 2>/dev/null | awk -F'|' 'tolower($1) !~ /nvme|composite|wifi|iwl|bat/ && $2+0>m {m=$2+0} END{print m+0}'); [ "${a:-0}" -gt 0 ] || return 2; SD_V=$a ;;
    uptime-days) a=$(awk '{printf "%d", $1/86400}' "$SLH_PROC/uptime" 2>/dev/null); [ -n "$a" ] || return 2; SD_V=$a ;;
    load-ratio) a=$(awk -v n="$(grep -c '^processor' "$SLH_PROC/cpuinfo" 2>/dev/null)" '{ if (n<1) n=1; printf "%d", $3*100/n }' "$SLH_PROC/loadavg" 2>/dev/null); [ -n "$a" ] || return 2; SD_V=$a ;;
    update-age-days) sd_age_days var/lib/dnf/history.sqlite usr/lib/sysimage/libdnf5/transaction_history.sqlite var/lib/apt/periodic/update-success-stamp var/log/apt/history.log || return 2 ;;
    scrub-age-days) sd_load btrfsscrub || return 2; a=$(sed -n 's/^Scrub started: *//p' "$SD_F" | head -n1)
      if [ -z "$a" ]; then grep -qi 'no stats available' "$SD_F" && { SD_V=9999; return 0; }; return 2; fi
      b=$(date -d "$a" +%s 2>/dev/null) || return 2; SD_V=$(( ($(date +%s) - b) / 86400 )) ;;
    snap-count) sd_load snapper || return 2; SD_V=$(grep -cE '^ *[0-9]+ ' "$SD_F") ;;
    btrfs-unalloc-mb) sd_load btrfsusage || return 2; a=$(sed -n 's/^ *Device unallocated: *\([0-9]*\).*/\1/p' "$SD_F" | head -n1); [ -n "$a" ] || return 2; SD_V=$((a / 1048576)) ;;
    failed-units) sd_load failed || return 2; SD_V=$(grep -c . "$SD_F") ;;
    autoremove-count) sd_load autoremove || return 2; SD_V=$(head -n1 "$SD_F" | tr -dc '0-9'); SD_V=${SD_V:-0} ;;
    auth-fail-count) sd_load authfail || return 2; SD_V=$(grep -c . "$SD_F") ;;
    avc-count) sd_load avc || return 2; SD_V=$(grep -c . "$SD_F") ;;
    cpu-top-pct) sd_load pstop || return 2; SD_V=$(awk 'NR==2{printf "%d", $2}' "$SD_F") ;;
    mem-top-pct) sd_load pstopmem || return 2; SD_V=$(awk 'NR==2{printf "%d", $3}' "$SD_F") ;;
    *) return 3 ;;
  esac
  return 0
}
sd_age_days() {   # sd_age_days PATH... -> SD_V = days since the first existing file changed
  local p f m
  for p in "$@"; do f=$(sd_path "$p"); [ -e "$f" ] || continue
    m=$(stat -c %Y "$f" 2>/dev/null) || continue
    SD_V=$(( ($(date +%s) - m) / 86400 )); return 0
  done
  return 2
}

# ---------------------------------------------------------------- environment words (env:NAME)
sd_env_is() {
  local n=$1 v
  case "$n" in
    uefi) sd_isuefi ;; bios) ! sd_isuefi ;;
    laptop) [ "$(slh_chassis)" = laptop ] ;; desktop) [ "$(slh_chassis)" = desktop ] ;;
    secureboot) sd_load sbstate; local rc=$?; [ $rc = 0 ] || return 2; grep -qi 'SecureBoot enabled' "$SD_F" ;;
    fedora|debian) [ "$SD_FAMILY" = "$n" ] ;;
    installed|rescue|live) [ "$SD_ENVC" = "$n" ] ;;
    root) slh_is_root ;;
    battery) local s; for s in "$SLH_SYS"/class/power_supply/AC*/online "$SLH_SYS"/class/power_supply/ADP*/online; do [ -r "$s" ] && { [ "$(slh_rd "$s")" = 0 ]; return; }; done; return 1 ;;
    profile=*) [ "$(slh_rd "$(sd_path etc/secure-linux/profile)")" = "${n#profile=}" ] ;;
    ssd) for v in "$SLH_SYS"/block/*/queue/rotational; do [ -r "$v" ] && [ "$(slh_rd "$v")" = 0 ] && return 0; done; return 1 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------- terms, expressions
sd_txt_match() {   # sd_txt_match TEXT REGEX N : at least N lines match (case-insensitive ERE). Sets SD_MLINE to the first match. No forks.
  local text=$1 re=$2 n=$3 l c=0
  SD_MLINE=""
  [ -n "$re" ] || re='.'
  shopt -s nocasematch
  while IFS= read -r l; do
    if [[ $l =~ $re ]]; then c=$((c + 1)); [ -z "$SD_MLINE" ] && SD_MLINE=$l; [ "$c" -ge "$n" ] && break; fi
  done <<< "$text"
  shopt -u nocasematch
  [ "$c" -ge "$n" ]
}
sd_set_det() {   # sd_set_det "line" : a short, tidy detail for the text
  local v=${1//$'\t'/ }
  v=${v//$'\r'/}; v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}
  SD_DET=${v:0:140}
}
sd_term() {   # sets SD_R: 0 yes, 1 no, 2 could not check ; SD_DET gets a short detail on a yes
  local t=$1 neg=0 kind rest key re="" n=1 f cnt rc line st items left pat hit i
  t=${t#"${t%%[![:space:]]*}"}; t=${t%"${t##*[![:space:]]}"}
  case "$t" in '!'*) neg=1; t=${t#!} ;; esac
  kind=${t%%:*}; rest=${t#*:}; SD_R=1
  case "$kind" in
    cmd)
      key=${rest%%'~'*}; [[ $rest == *'~'* ]] && re=${rest#*'~'}
      if [[ $re =~ ^(.*)#([0-9]+)$ ]]; then re=${BASH_REMATCH[1]}; n=${BASH_REMATCH[2]}; fi
      sd_load "$key"; rc=$?
      if [ $rc != 0 ]; then SD_R=2
      elif sd_txt_match "${SD_TXT[$key]}" "$re" "$n"; then SD_R=0; [ "$neg" = 0 ] && [ -z "$SD_DET" ] && sd_set_det "$SD_MLINE"; fi ;;
    file)
      key=${rest%%'~'*}; [[ $rest == *'~'* ]] && re=${rest#*'~'}
      if [[ $re =~ ^(.*)#([0-9]+)$ ]]; then re=${BASH_REMATCH[1]}; n=${BASH_REMATCH[2]}; fi
      sd_pathv f "$key"
      if [ ! -e "$f" ]; then SD_R=1
      elif [ ! -r "$f" ]; then SD_R=2; sd_limited "a protected file ($key; needs administrator rights)"
      elif [ -z "$re" ]; then SD_R=0
      else
        if [ -z "${SD_DFC[$f]+x}" ]; then local __t=""; IFS= read -r -d '' __t < "$f"; SD_DFC[$f]=$__t; fi
        if sd_txt_match "${SD_DFC[$f]}" "$re" "$n"; then SD_R=0; [ "$neg" = 0 ] && [ -z "$SD_DET" ] && sd_set_det "$SD_MLINE"; fi
      fi ;;
    glob)
      sd_pathv f "$rest"; if compgen -G "$f" >/dev/null 2>&1; then SD_R=0; else SD_R=1; fi ;;
    health)
      if ! sd_health_ready; then SD_R=2
      else
        re=""; [[ $rest == *'~'* ]] && { re=${rest#*'~'}; rest=${rest%%'~'*}; }
        st=${rest##*=}; left=${rest%=*}; items=""; case "$left" in *:*) items=${left#*:}; left=${left%%:*} ;; esac
        shopt -s nocasematch
        for ((i = 0; i < H_N; i++)); do
          [[ ${H_PART[i]} == "$left" ]] || continue
          case ",$st," in *",${H_ST[i]},"*) ;; *) continue ;; esac
          if [ -n "$items" ]; then
            case "$items" in '!'*) pat=${items#!}; [[ ${H_ITEM[i]} == $pat ]] && continue ;; *) pat=$items; [[ ${H_ITEM[i]} == $pat ]] || continue ;; esac
          fi
          if [ -n "$re" ] && ! [[ ${H_MEAN[i]} =~ $re ]]; then continue; fi
          SD_R=0; hit=$i; break
        done
        shopt -u nocasematch
        if [ "$SD_R" = 0 ] && [ "$neg" = 0 ]; then [ -z "$SD_DET" ] && SD_DET=${H_MEAN[hit]:0:200}; [ -z "$SD_HITEM" ] && SD_HITEM=${H_ITEM[hit]}; fi
      fi ;;
    val)
      local vre='^([a-z0-9-]+)(>=|<=|==|!=|>|<)(-?[0-9]+)$'
      if [[ $rest =~ $vre ]]; then
        key=${BASH_REMATCH[1]}; local op=${BASH_REMATCH[2]} want=${BASH_REMATCH[3]}
        if sd_val "$key"; then
          case "$op" in '>=') [ "$SD_V" -ge "$want" ] ;; '<=') [ "$SD_V" -le "$want" ] ;; '>') [ "$SD_V" -gt "$want" ] ;; '<') [ "$SD_V" -lt "$want" ] ;; '==') [ "$SD_V" -eq "$want" ] ;; '!=') [ "$SD_V" -ne "$want" ] ;; esac && { SD_R=0; [ "$neg" = 0 ] && [ -z "$SD_DET" ] && SD_DET="$SD_V"; }
        else SD_R=2; fi
      else SD_R=2; fi ;;
    env) sd_env_is "$rest"; rc=$?; case $rc in 0) SD_R=0 ;; 2) SD_R=2 ;; *) SD_R=1 ;; esac ;;
    choice)
      case "$rest" in *'!='*) key=${rest%%'!='*}; re=${rest#*'!='}; [ "$(sd_choice "$key")" != "$re" ] && SD_R=0 ;;
        *) key=${rest%%=*}; re=${rest#*=}; [ "$(sd_choice "$key")" = "$re" ] && SD_R=0 ;; esac ;;
    fn)
      if declare -F "dx_$rest" >/dev/null; then "dx_$rest"; rc=$?; case $rc in 0) SD_R=0 ;; 2) SD_R=2 ;; *) SD_R=1 ;; esac
      else SD_R=2; fi ;;
    *) SD_R=2 ;;
  esac
  if [ "$neg" = 1 ]; then case $SD_R in 0) SD_R=1 ;; 1) SD_R=0 ;; esac; fi
  return 0
}
sd_expr() {   # sets SD_R for a whole expression
  local e=$1 alt term any_unknown=0 ok res_and
  local -a alts=() terms=()
  e=${e// \|\| /$RS}
  IFS=$RS read -r -a alts <<< "$e"
  for alt in "${alts[@]}"; do
    alt=${alt// && /$RS}
    IFS=$RS read -r -a terms <<< "$alt"
    res_and=0
    for term in "${terms[@]}"; do
      sd_term "$term"
      if [ "$SD_R" = 1 ]; then res_and=1; break; elif [ "$SD_R" = 2 ]; then res_and=2; fi
    done
    if [ "$res_and" = 0 ]; then SD_R=0; return 0; fi
    [ "$res_and" = 2 ] && any_unknown=1
  done
  if [ "$any_unknown" = 1 ]; then SD_R=2; else SD_R=1; fi
}

# ---------------------------------------------------------------- knowledge base
# columns: 1 id 2 area 3 applies_to 4 cost 5 detector 6 severity 7 impact 8 title 9 what 10 why 11 safe_level 12 auto_fixable
# 13 fix_action 14 fix_args 15 fix_summary 16 backup_first 17 undo 18 time_estimate 19 learn_more 20 manual 21 flags 22 notes
SD_NCOL=22
sd_kb_load() {   # sd_kb_load DIR
  local d=$1 f line n=0
  KB=(); CORR_W=(); CORR_L=(); CORR_N=()
  for f in "$d"/*.tsv; do
    [ -r "$f" ] || continue
    case "${f##*/}" in correlate.tsv) continue ;; esac
    while IFS= read -r line; do
      case "$line" in ''|'#'*) continue ;; esac
      KB[${#KB[@]}]=${line//$'	'/$US}
    done < "$f"
  done
  if [ -r "$d/correlate.tsv" ]; then
    local w l nt
    while IFS=$'\t' read -r w l nt; do
      case "$w" in ''|'#'*) continue ;; esac
      CORR_W+=("$w"); CORR_L+=("$l"); CORR_N+=("$nt")
    done < "$d/correlate.tsv"
  fi
  return 0
}
sd_applies() {   # sd_applies "any+t,fedora" -> 0 if this problem is for the system being checked; SD_NEEDT=1 when it needs the installed system's files
  local a=$1 tok fam env hit=1; SD_NEEDT=0
  [ -n "$SD_FAMILY" ] || sd_init_env; fam=$SD_FAMILY; env=$SD_ENVC
  case ",$a," in *"+t"*) SD_NEEDT=1 ;; esac
  for tok in ${a//,/ }; do
    tok=${tok%+t}
    case "$tok" in
      any) hit=0 ;; fedora|debian) [ "$fam" = "$tok" ] && hit=0 ;;
      installed) [ "$env" = installed ] && hit=0 ;;
      rescue) [ "$env" = rescue ] && hit=0 ;; live) [ "$env" != installed ] && hit=0 ;;
    esac
  done
  return $hit
}
sd_ask() {   # sd_ask "plain question" default choice...   (a detector calls this when it cannot pick for the person)
  SD_ASK_Q=$1; SD_ASK_DEF=$2; shift 2; SD_ASK_CH=("$@")
}
sd_tpl() {   # fill {detail} {dev} {arg} in a text
  local s=$1 d=${SD_DET:-} a=${SD_ARGS[0]:-}
  d=$(sd_short "$d" 160)
  s=${s//\{detail\}/$d}; s=${s//\{dev\}/$a}; s=${s//\{arg\}/$a}
  printf '%s' "$s"
}

# one record per problem found
declare -a I_ID=() I_IDX=() I_SEV=() I_DET=() I_ARGS=() I_ASKQ=() I_ASKD=() I_ASKC=() I_CONF=() I_ALSO=() I_DROP=() I_IMP=()
I_N=0
sd_sevrank() { case "$1" in fail) echo 3 ;; warn) echo 2 ;; info) echo 1 ;; *) echo 0 ;; esac; }
sd_eval_entry() {   # sd_eval_entry INDEX -> 0 found (and recorded) / 1 not found / 2 could not check
  local -a F=()
  IFS=$US read -r -a F <<< "${KB[$1]}"
  local id=${F[0]} det=${F[4]} rule=${F[5]} sev esc lvl ex
  SD_DET=""; SD_HITEM=""; SD_CONF=high; SD_ASK_Q=""; SD_ASK_DEF=""; SD_ASK_CH=(); SD_ARGS=()
  sd_expr "$det"
  case $SD_R in 1) return 1 ;; 2) return 2 ;; esac
  sev=${rule%%;*}
  if [[ $rule == *';'* ]]; then
    esc=${rule#*;}; lvl=${esc%%=*}; ex=${esc#*=}
    local keepdet=$SD_DET keepitem=$SD_HITEM keepcnf=$SD_CONF keepq=$SD_ASK_Q keepd=$SD_ASK_DEF; local -a keepch=("${SD_ASK_CH[@]:-}") keepa=("${SD_ARGS[@]:-}")
    sd_expr "$ex"; [ "$SD_R" = 0 ] && sev=$lvl
    SD_DET=$keepdet; SD_HITEM=$keepitem; SD_CONF=$keepcnf; SD_ASK_Q=$keepq; SD_ASK_DEF=$keepd; SD_ASK_CH=("${keepch[@]:-}"); SD_ARGS=("${keepa[@]:-}")
    [ -z "${SD_ASK_CH[*]:-}" ] && SD_ASK_CH=()
    [ -z "${SD_ARGS[*]:-}" ] && SD_ARGS=()
  fi
  I_ID[I_N]=$id; I_IDX[I_N]=$1; I_SEV[I_N]=$sev; I_DET[I_N]=$SD_DET; I_IMP[I_N]=${F[6]:-50}
  I_ARGS[I_N]=$(IFS=$US; echo "${SD_ARGS[*]:-}"); I_CONF[I_N]=$SD_CONF
  I_ASKQ[I_N]=$SD_ASK_Q; I_ASKD[I_N]=$SD_ASK_DEF; I_ASKC[I_N]=$(IFS=$US; echo "${SD_ASK_CH[*]:-}")
  I_ALSO[I_N]=""; I_DROP[I_N]=0; I_N=$((I_N + 1))
  return 0
}
sd_collect() {   # sd_collect [ONLY_ID] : evaluates every problem that applies; fills I_*
  local i idx; local -a F=()
  I_N=0; I_ID=(); I_IDX=(); I_SEV=(); I_DET=(); I_ARGS=(); I_ASKQ=(); I_ASKD=(); I_ASKC=(); I_CONF=(); I_ALSO=(); I_DROP=(); I_IMP=()
  SD_NOTARGET=0; SD_CHECKED=0
  local pass
  for pass in 1 2; do
    for ((idx = 0; idx < ${#KB[@]}; idx++)); do
      IFS=$US read -r -a F <<< "${KB[idx]}"
      [ -n "${1:-}" ] && [ "${F[0]}" != "$1" ] && continue
      case "${F[20]}" in *maint*) [ "$SD_AUTOPILOT" = 1 ] || [ -n "${1:-}" ] || continue ;; esac
      case "${F[4]}" in *health:*) [ "$pass" = 2 ] || continue ;; *) [ "$pass" = 1 ] || continue ;; esac
      [ "$SD_MODE" = quick ] && [ "${F[3]}" = full ] && [ -z "${1:-}" ] && continue
      sd_applies "${F[2]}" || continue
      if [ "$SD_NEEDT" = 1 ] && [ "$SD_ENVC" != installed ] && [ "${SD_HAVE_TARGET:-0}" != 1 ]; then SD_NOTARGET=1; continue; fi
      SD_CHECKED=$((SD_CHECKED + 1))
      sd_eval_entry "$idx"
    done
  done
}
sd_correlate() {
  local k w l i j lw ids found
  for ((k = 0; k < ${#CORR_W[@]}; k++)); do
    w=${CORR_W[k]}; found=-1
    for ((i = 0; i < I_N; i++)); do [ "${I_ID[i]}" = "$w" ] && [ "${I_DROP[i]}" = 0 ] && found=$i; done
    [ "$found" -ge 0 ] || continue
    for l in ${CORR_L[k]//,/ }; do
      for ((j = 0; j < I_N; j++)); do
        if [ "${I_ID[j]}" = "$l" ] && [ "${I_DROP[j]}" = 0 ]; then
          I_DROP[j]=1
          local -a LF=(); IFS=$US read -r -a LF <<< "${KB[${I_IDX[j]}]}"
          I_ALSO[found]="${I_ALSO[found]:+${I_ALSO[found]}; }${LF[7]}"
        fi
      done
    done
  done
}
sd_pick_ask() { :; }
sd_sorted() {   # prints indexes of kept issues, most serious first
  local i
  for ((i = 0; i < I_N; i++)); do
    [ "${I_DROP[i]}" = 0 ] || continue
    printf '%s|%s|%s|%s\n' "$(sd_sevrank "${I_SEV[i]}")" "${I_IMP[i]}" "${I_ID[i]}" "$i"
  done | sort -t'|' -k1,1nr -k2,2nr -k3,3 | cut -d'|' -f4
}

# ---------------------------------------------------------------- the person's back-up card
SD_BACKUP_NOW=0
sd_need_backup() {   # any kept issue flagged hwfail ?
  local i; SD_BACKUP_NOW=0
  for ((i = 0; i < I_N; i++)); do
    [ "${I_DROP[i]}" = 0 ] || continue
    local -a F=(); IFS=$US read -r -a F <<< "${KB[${I_IDX[i]}]}"
    case "${F[20]}" in *hwfail*) SD_BACKUP_NOW=1; SD_BACKUP_WHY=${F[7]}; return 0 ;; esac
  done
  return 1
}

# ---------------------------------------------------------------- output
sd_je() { slh_escv "$1"; printf '%s' "$ESC"; }
sd_json_arr() {   # sd_json_arr "a<US>b" -> ["a","b"]
  local s=$1 first=1 x
  printf '['
  if [ -n "$s" ]; then
    local -a a=(); IFS=$US read -r -a a <<< "$s"
    for x in "${a[@]}"; do [ "$first" = 1 ] || printf ','; first=0; printf '"%s"' "$(sd_je "$x")"; done
  fi
  printf ']'
}
sd_needs_input_json() {   # sd_needs_input_json INDEX -> null or {...}
  local i=$1
  if [ -z "${I_ASKQ[i]}" ]; then printf 'null'; return; fi
  printf '{"question":"%s","choices":%s,"default":"%s"}' "$(sd_je "${I_ASKQ[i]}")" "$(sd_json_arr "${I_ASKC[i]}")" "$(sd_je "${I_ASKD[i]}")"
}
sd_fields() {   # sd_fields INDEX -> sets F[] (the KB row), ARGS (US-joined), TXT_* with the templates filled in
  local i=$1
  IFS=$US read -r -a F <<< "${KB[${I_IDX[i]}]}"
  SD_DET=${I_DET[i]}; SD_ARGS=(); [ -n "${I_ARGS[i]}" ] && IFS=$US read -r -a SD_ARGS <<< "${I_ARGS[i]}"
  A_JOIN=${I_ARGS[i]}; [ -n "$A_JOIN" ] || A_JOIN=${F[13]// /$US}
  [ "$A_JOIN" = "-" ] && A_JOIN=""
}
sd_json_issue() {
  local i=$1 af=false; local -a F=()
  sd_fields "$i"
  [ "${F[11]}" = yes ] && af=true
  local fa=${F[12]}; [ "$fa" = "-" ] && fa=""
  printf '{"id":"%s","severity":"%s","title":"%s","what":"%s","why":"%s","safe_level":"%s","auto_fixable":%s,"fix_action":"%s","fix_args":%s,"fix_summary":"%s","backup_first":"%s","time_estimate":"%s","learn_more":"%s"' \
    "$(sd_je "${I_ID[i]}")" "${I_SEV[i]}" "$(sd_je "$(sd_tpl "${F[7]}")")" "$(sd_je "$(sd_tpl "${F[8]}")")" "$(sd_je "$(sd_tpl "${F[9]}")")" "${F[10]}" "$af" "$(sd_je "$fa")" \
    "$(sd_json_arr "$A_JOIN")" "$(sd_je "$(sd_tpl "${F[14]}")")" "$(sd_je "$(sd_tpl "${F[15]}")")" "$(sd_je "${F[17]}")" "$(sd_je "${F[18]}")"
  printf ',"area":"%s","needs_input":%s,"confidence":"%s","manual":"%s","undo":"%s","detail":"%s","also_explains":"%s","urgent_backup":%s,"reboot_needed":%s}' \
    "$(sd_je "${F[1]}")" "$(sd_needs_input_json "$i")" "${I_CONF[i]}" "$(sd_je "$(sd_tpl "${F[19]}")")" "$(sd_je "${F[16]}")" "$(sd_je "$(sd_short "${I_DET[i]}" 200)")" "$(sd_je "${I_ALSO[i]}")" \
    "$([[ ${F[20]} == *hwfail* ]] && echo true || echo false)" "$([[ ${F[20]} == *reboot* ]] && echo true || echo false)"
}
sd_json_backup_card() {
  printf '{"id":"backup-now","severity":"fail","title":"Back up your files now","what":"A part of this computer that stores your files is failing (%s). It could stop working at any time.","why":"Everything you have not copied somewhere else could be lost. Copying files now is safe and does not change anything on the failing part.","safe_level":"safe","auto_fixable":false,"fix_action":"data","fix_args":[],"fix_summary":"Copy your documents, photos and settings to another drive or USB stick. Nothing is changed on the failing drive.","backup_first":"This IS the backup.","time_estimate":"depends on how many files","learn_more":"repair-guide.md: Rescue my files","area":"disks","needs_input":%s,"confidence":"high","manual":"Plug in a USB drive or external disk that is bigger than your files, then choose Rescue my files. Do not run repairs until the copy is finished.","undo":"","detail":"","also_explains":"","urgent_backup":true,"reboot_needed":false}' \
    "$(sd_je "$(sd_short "${SD_BACKUP_WHY:-a drive}" 80)")" "$(sd_backup_dest_json)"
}
sd_backup_dest_json() {   # where to copy to: pick by detection; ask only when there is more than one possible drive
  local -a cand=(); local line dev rm sz model
  if sd_load lsblkj; then
    while IFS= read -r line; do
      set -- $line; [ "${2:-}" = disk ] || continue
      dev=$1; local f rmv=""; shift 2
      for f in "$@"; do case "$f" in 0|1) rmv=$f; break ;; esac; done
      [ "$rmv" = 1 ] || continue
      cand+=("$dev")
    done < "$SD_F"
  fi
  case ${#cand[@]} in
    0) printf '{"question":"I could not see another drive to copy your files to. Please plug in a USB drive or external disk, then say Ready.","choices":["Ready"],"default":"Ready"}' ;;
    1) printf 'null' ;;
    *) local c first=1; printf '{"question":"Which drive should I copy your files to?","choices":['; for c in "${cand[@]}"; do [ $first = 1 ] || printf ','; first=0; printf '"%s"' "$(sd_je "$c")"; done; printf '],"default":"%s"}' "$(sd_je "${cand[0]}")" ;;
  esac
}
sd_json_limited() {
  local x first=1 list=""
  for x in "${SD_LIM[@]:-}"; do [ -n "$x" ] || continue; list="${list:+$list; }$x"; done
  [ -n "$list" ] || return 1
  printf '{"id":"diag-limited","severity":"info","title":"Some checks could not be done","what":"I could not look at: %s.","why":"Those checks need administrator rights, or a tool that is not installed here. Everything else was checked.","safe_level":"safe","auto_fixable":false,"fix_action":"","fix_args":[],"fix_summary":"Run the check again as administrator for the full picture.","backup_first":"Nothing is changed.","time_estimate":"~1 min","learn_more":"diagnose-guide.md","area":"general","needs_input":null,"confidence":"high","manual":"Run: sudo secure-linux-diagnose","undo":"","detail":"","also_explains":"","urgent_backup":false,"reboot_needed":false}' "$(sd_je "$list")"
}
sd_json_ok() {
  printf '{"id":"all-fine","severity":"ok","title":"Everything I checked looks fine","what":"I checked %s things and found no problems.","why":"Nothing needs your attention right now.","safe_level":"safe","auto_fixable":false,"fix_action":"","fix_args":[],"fix_summary":"Nothing to do.","backup_first":"Nothing is changed.","time_estimate":"","learn_more":"","area":"general","needs_input":null,"confidence":"high","manual":"","undo":"","detail":"","also_explains":"","urgent_backup":false,"reboot_needed":false}' "${SD_CHECKED:-0}"
}
sd_json_ambiguous_target() {
  [ -n "${SD_TARGET_CHOICES:-}" ] || return 1
  printf '{"id":"diag-which-system","severity":"info","title":"I found more than one Linux system","what":"There is more than one Linux system on this computer\x27s drives, and I need to know which one to check.","why":"Checking the wrong one could send you down the wrong repair.","safe_level":"safe","auto_fixable":false,"fix_action":"","fix_args":[],"fix_summary":"Pick the one you normally use.","backup_first":"Nothing is changed.","time_estimate":"~1 min","learn_more":"","area":"general","needs_input":{"question":"Which Linux system do you want me to check?","choices":%s,"default":"%s"},"confidence":"low","manual":"","undo":"","detail":"","also_explains":"","urgent_backup":false,"reboot_needed":false}' "$(sd_json_arr "$SD_TARGET_CHOICES")" "$(sd_je "${SD_TARGET_DEFAULT:-}")"
}

sd_emit_json() {   # all kept issues, one JSON array
  local i first=1 out=""
  printf '[\n'
  if sd_need_backup; then printf '  '; sd_json_backup_card; first=0; fi
  for i in $(sd_sorted); do [ "$first" = 1 ] || printf ',\n'; first=0; printf '  '; sd_json_issue "$i"; done
  if sd_json_ambiguous_target >/dev/null 2>&1; then [ "$first" = 1 ] || printf ',\n'; first=0; printf '  '; sd_json_ambiguous_target; fi
  if sd_json_limited >/dev/null 2>&1; then [ "$first" = 1 ] || printf ',\n'; first=0; printf '  '; sd_json_limited; fi
  [ "$first" = 1 ] && { printf '  '; sd_json_ok; }
  printf '\n]\n'
}
sd_emit_text() {
  local i n=0 total=0 w; local -a F=()
  for i in $(sd_sorted); do total=$((total + 1)); done
  echo "Secure Linux check-up ($SD_MODE check)"
  echo
  if sd_need_backup; then
    echo "!!  BACK UP YOUR FILES NOW"
    echo "    Something that stores your files is failing (${SD_BACKUP_WHY:-a drive}). Copy what matters to another drive or USB stick"
    echo "    before you do anything else: secure-linux-repair --action data    (nothing is changed on the failing drive)."
    echo
  fi
  if [ "$total" = 0 ]; then
    echo "Everything I checked looks fine (${SD_CHECKED:-0} checks). Nothing needs your attention."
  else
    echo "I found $total thing(s) worth knowing about, most important first:"
    for i in $(sd_sorted); do
      n=$((n + 1)); sd_fields "$i"
      case "${I_SEV[i]}" in fail) w="PROBLEM" ;; warn) w="NEEDS A LOOK" ;; *) w="FOR YOUR INFORMATION" ;; esac
      echo; echo "$n. [$w] $(sd_tpl "${F[7]}")"
      echo "   What is happening: $(sd_tpl "${F[8]}")"
      echo "   Why it matters:    $(sd_tpl "${F[9]}")"
      [ -n "${I_ALSO[i]}" ] && echo "   This also explains: ${I_ALSO[i]}"
      if [ "${F[11]}" = yes ] && [ "${F[12]}" != "-" ]; then
        echo "   What I can do:     $(sd_tpl "${F[14]}")"
        case "${F[10]}" in safe) echo "   How safe:          Safe. It can be undone and does not touch your files." ;; asks) echo "   How safe:          I will ask you before changing anything." ;; risky) echo "   How safe:          Risky. Please read what it says carefully; I will not go ahead without a clear yes." ;; esac
        [ -n "${F[15]}" ] && [ "${F[15]}" != "-" ] && echo "   Saved first:       $(sd_tpl "${F[15]}")"
        echo "   Time:              ${F[17]}"
        echo "   To do it:          secure-linux-repair --action ${F[12]}${A_JOIN:+ --arg ${A_JOIN//$US/ --arg }}"
        [ -n "${I_ASKQ[i]}" ] && echo "   I need one answer: ${I_ASKQ[i]}"
      else
        echo "   Do this yourself:  $(sd_tpl "${F[19]}")"
        [ "${F[12]}" != "-" ] && [ -n "${F[12]}" ] && echo "   Guided help:       secure-linux-repair --action ${F[12]}"
      fi
    done
  fi
  if [ ${#SD_LIM[@]} -gt 0 ]; then
    echo; echo "Some checks could not be done:"
    local x; for x in "${SD_LIM[@]}"; do echo " - $x"; done
    slh_is_root || echo "(Run again with sudo for the complete picture.)"
  fi
  if [ -n "${SD_TARGET_CHOICES:-}" ]; then
    echo; echo "I found more than one Linux system on this computer's drives. Which one do you want me to check?"
    local c; local -a tc=(); IFS=$US read -r -a tc <<< "$SD_TARGET_CHOICES"
    for c in "${tc[@]}"; do echo " - $c"; done
    echo "(Answer with: secure-linux-diagnose --auto-target --answer 'which-system=DEVICE'.  Suggested: ${SD_TARGET_DEFAULT:-the first one})"
  fi
  [ "${SD_NOTARGET:-0}" = 1 ] && { echo; echo "Note: this is a live/rescue system, so start-up and software checks need the installed system. Use: secure-linux-diagnose --root /mnt/..."; }
  return 0
}
