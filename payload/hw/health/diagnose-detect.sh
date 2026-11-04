# shellcheck shell=bash
# hw/health/diagnose-detect.sh (owner: U2 diagnose) - the custom checks (fn:NAME in the knowledge base = dx_NAME here).
# Each returns 0 = the problem is present, 1 = it is not, 2 = could not check. They may set SD_DET (a short detail for the
# text), SD_ARGS (what the fix needs, found by detection), SD_CONF (high|medium|low) and call sd_ask when detection is
# ambiguous (the one plain question the person is asked). They only READ.

dx_esp_dir() {   # prints the folder the EFI system partition is mounted at in the system being checked
  printf '%s' "$(sd_path boot/efi)"
}
dx_efi_no_linux() {
  sd_load efibootmgr || return 2
  grep -qiE 'not supported|EFI variables are not' "$SD_F" && return 2
  grep -qE '^Boot[0-9A-Fa-f]{4}' "$SD_F" || return 2
  grep -iE '^Boot[0-9A-Fa-f]{4}' "$SD_F" | grep -qiE 'fedora|shim|grub|debian|ubuntu|linux|opensuse|arch|mint' && return 1
  return 0
}
dx_efi_win_first() {
  sd_load efibootmgr || return 2
  local first line
  first=$(sed -n 's/^BootOrder: *//p' "$SD_F" | head -n1 | cut -d, -f1)
  [ -n "$first" ] || return 1
  line=$(grep -iE "^Boot$first" "$SD_F" | head -n1)
  printf '%s' "$line" | grep -qi 'windows' || return 1
  grep -iE '^Boot[0-9A-Fa-f]{4}' "$SD_F" | grep -qiE 'fedora|shim|grub|debian|ubuntu' || return 1
  SD_ARGS=("$(grep -iE '^Boot[0-9A-Fa-f]{4}' "$SD_F" | grep -iE 'fedora|shim|grub|debian|ubuntu' | head -n1 | sed -E 's/^Boot([0-9A-Fa-f]{4}).*/\1/')")
  return 0
}
dx_esp_loader_missing() {
  local esp; esp=$(dx_esp_dir)
  [ -d "$esp/EFI" ] || return 2
  local d
  for d in fedora debian ubuntu; do [ -e "$esp/EFI/$d/shimx64.efi" ] || [ -e "$esp/EFI/$d/grubx64.efi" ] || [ -e "$esp/EFI/$d/shim.efi" ] && return 1; done
  [ -e "$esp/EFI/BOOT/BOOTX64.EFI" ] && [ ! -d "$esp/EFI/Microsoft" ] && return 1
  # some Linux was installed here if the root has a kernel
  compgen -G "$(sd_path boot)/vmlinuz*" >/dev/null || return 1
  return 0
}
dx_grub_cfg_missing() {
  compgen -G "$(sd_path boot)/vmlinuz*" >/dev/null || return 1
  [ -e "$(sd_path boot/loader/loader.conf)" ] && [ ! -d "$(sd_path boot/grub2)" ] && [ ! -d "$(sd_path boot/grub)" ] && return 1
  local fam; fam=$(sd_family)
  if [ "$fam" = debian ]; then [ -e "$(sd_path boot/grub/grub.cfg)" ] && return 1; [ -d "$(sd_path boot/grub)" ] || return 1; return 0; fi
  [ -e "$(sd_path boot/grub2/grub.cfg)" ] && return 1
  [ -d "$(sd_path boot/grub2)" ] || [ -d "$(sd_path boot/efi/EFI/fedora)" ] || return 1
  return 0
}
dx_grub_stub_missing() {
  local esp d; esp=$(dx_esp_dir)
  [ -d "$esp/EFI" ] || return 2
  for d in fedora debian ubuntu; do
    [ -d "$esp/EFI/$d" ] || continue
    [ -e "$esp/EFI/$d/shimx64.efi" ] || [ -e "$esp/EFI/$d/grubx64.efi" ] || continue
    [ -e "$esp/EFI/$d/grub.cfg" ] || { SD_DET="$d"; return 0; }
  done
  return 1
}
dx_initramfs_missing() {
  local f ver fam; fam=$(sd_family)
  for f in "$(sd_path boot)"/vmlinuz-*; do
    [ -e "$f" ] || continue
    ver=${f##*/vmlinuz-}; case "$ver" in *rescue*) continue ;; esac
    if [ "$fam" = debian ]; then [ -e "$(sd_path boot)/initrd.img-$ver" ] || { SD_DET=$ver; SD_ARGS=("$ver"); return 0; }
    else [ -e "$(sd_path boot)/initramfs-$ver.img" ] || { SD_DET=$ver; SD_ARGS=("$ver"); return 0; }; fi
  done
  return 1
}
dx_fstab_bad_uuid() {
  local f src mp fs opts a b u; f=$(sd_path etc/fstab)
  [ -r "$f" ] || return 1
  [ -d "$SLH_DEV/disk/by-uuid" ] || return 2
  while read -r src mp fs opts a b; do
    case "$src" in UUID=*) u=${src#UUID=} ;; *) continue ;; esac
    [ "$mp" = / ] && continue
    [ "$fs" = swap ] && continue
    case ",$opts," in *,noauto,*|*,nofail,*) continue ;; esac
    [ -e "$SLH_DEV/disk/by-uuid/$u" ] && continue
    SD_DET="the drive for $mp is missing"; SD_ARGS=("$mp"); return 0
  done < "$f"
  return 1
}
dx_crypttab_bad() {
  local f name src rest u; f=$(sd_path etc/crypttab)
  [ -r "$f" ] || return 1
  [ -d "$SLH_DEV/disk/by-uuid" ] || return 2
  while read -r name src rest; do
    case "$name" in ''|'#'*) continue ;; esac
    case "$src" in UUID=*) u=${src#UUID=} ;; *) continue ;; esac
    case "$rest" in *nofail*|*noauto*) continue ;; esac
    [ -e "$SLH_DEV/disk/by-uuid/$u" ] || { SD_DET="$name"; return 0; }
  done < "$f"
  return 1
}
dx_win_menu_missing() {
  sd_isuefi || return 1
  local esp cfg; esp=$(dx_esp_dir)
  [ -e "$esp/EFI/Microsoft/Boot/bootmgfw.efi" ] || return 1
  cfg=$(sd_path boot/grub2/grub.cfg); [ -e "$cfg" ] || cfg=$(sd_path boot/grub/grub.cfg)
  [ -r "$cfg" ] || return 1
  grep -qi 'windows' "$cfg" && return 1
  return 0
}
dx_bootmgr_gone() {
  sd_isuefi || return 1
  local esp; esp=$(dx_esp_dir)
  [ -d "$esp/EFI" ] || return 2
  [ -e "$esp/EFI/Microsoft/Boot/bootmgfw.efi" ] && return 1
  sd_load lsblk || return 2
  grep -qiE ' ntfs ' "$SD_F" || return 1
  return 0
}
dx_nvidia_unsigned() {
  sd_expr 'cmd:lspci~(VGA|3D|Display).*NVIDIA && !cmd:lsmod~^nvidia && env:secureboot'
  [ "$SD_R" = 0 ] || return "$SD_R"
  sd_expr 'cmd:klog~unsigned module|Key was rejected|module verification failed|Required key not available || cmd:mokkey~not enrolled|is not enrolled|no key'
  return "$SD_R"
}
dx_nvidia_module_missing() {
  sd_expr 'cmd:lspci~(VGA|3D|Display).*NVIDIA && !cmd:lsmod~^nvidia && !env:secureboot && glob:usr/src/akmods/*nvidia* || cmd:lspci~(VGA|3D|Display).*NVIDIA && !cmd:lsmod~^nvidia && !env:secureboot && glob:var/lib/dkms/nvidia*'
  return "$SD_R"
}
dx_rtc_dualboot() {
  sd_load lsblk || return 2
  local win=1
  grep -qiE ' ntfs ' "$SD_F" && win=0
  [ -e "$(dx_esp_dir)/EFI/Microsoft/Boot/bootmgfw.efi" ] && win=0
  [ "$win" = 0 ] || return 1
  sd_load ntpstate || return 2
  grep -q 'RTCInLocalTZ=no' "$SD_F" || return 1
  return 0
}
dx_usb_stick_bad() {
  sd_load klog || return 2
  local dev line
  while IFS= read -r line; do
    dev=$(printf '%s' "$line" | sed -nE 's/.*(on dev |\b)(sd[a-z]+).*/\2/p' | head -n1)
    [ -n "$dev" ] || continue
    [ "$(slh_rd "$SLH_SYS/block/$dev/removable")" = 1 ] && { SD_DET="$dev (a removable drive) reported read errors"; return 0; }
  done < <(grep -iE '(Buffer I/O error|I/O error|Medium Error).*(sd[a-z]+)' "$SD_F" | head -n 20)
  return 1
}
dx_regdom_unset() {
  sd_load iwreg || return 2
  grep -q 'country 00' "$SD_F" || return 1
  local c="" f
  for f in "$(sd_path usr/local/lib/secure-linux/build.conf)" "$(sd_path etc/secure-linux/build.conf)"; do
    [ -r "$f" ] && c=$(sed -n 's/^REGDOM=//p' "$f" | tr -d '"' | head -n1)
    [ -n "$c" ] && break
  done
  if [ -z "$c" ]; then
    local l; l=$(sed -n 's/^LANG=//p' "$(sd_path etc/locale.conf)" 2>/dev/null | head -n1)
    case "$l" in ??_??*) c=${l:3:2} ;; esac
  fi
  if [[ $c =~ ^[A-Z]{2}$ ]]; then SD_ARGS=("$c"); SD_DET="country $c"; return 0; fi
  SD_CONF=low
  sd_ask "Which country are you in? (This sets the Wi-Fi rules.)" AU AU NZ US GB CA IE ZA
  return 0
}
dx_not_charging() {
  local b ac st cap online=0
  for ac in "$SLH_SYS"/class/power_supply/AC*/online "$SLH_SYS"/class/power_supply/ADP*/online; do [ -r "$ac" ] && [ "$(slh_rd "$ac")" = 1 ] && online=1; done
  [ "$online" = 1 ] || return 1
  for b in "$SLH_SYS"/class/power_supply/BAT*; do
    [ -r "$b/status" ] || continue
    st=$(slh_rd "$b/status"); cap=$(slh_rd "$b/capacity")
    [ "$st" = "Not charging" ] || continue
    [ -n "$(sd_choice battery_limit)" ] && continue
    [ "${cap:-100}" -lt 90 ] 2>/dev/null && { SD_DET="The battery is at ${cap}% but is not charging."; return 0; }
  done
  return 1
}
dx_audio_wrong_output() {
  sd_load wpstatus || return 2
  local def n cands
  def=$(awk '/Sinks:/{s=1;next} /Sources:|Filters:|Streams:/{s=0} s && /\*/ { sub(/^[^*]*\*[ ]*/, ""); sub(/^[0-9]+\. /, ""); sub(/ *\[vol.*/, ""); print; exit }' "$SD_F")
  [ -n "$def" ] || return 1
  printf '%s' "$def" | grep -qiE 'HDMI|DisplayPort|Dummy|Digital' || return 1
  cands=$(awk '/Sinks:/{s=1;next} /Sources:|Filters:|Streams:/{s=0} s && /[0-9]+\./ && !/\*/ { l=$0; sub(/^[^0-9]*/, "", l); id=l; sub(/\..*/, "", id); name=l; sub(/^[0-9]+\. /, "", name); sub(/ *\[vol.*/, "", name); if (name !~ /HDMI|DisplayPort|Dummy/) print id "|" name }' "$SD_F")
  n=$(printf '%s\n' "$cands" | grep -c .)
  [ "$n" -ge 1 ] || return 1
  SD_DET=$def
  if [ "$n" = 1 ]; then SD_ARGS=("${cands%%|*}"); SD_CONF=high
  else
    SD_CONF=low
    local -a ch=(); local line
    while IFS= read -r line; do ch+=("${line#*|}"); done <<< "$cands"
    sd_ask "Which one is your speakers or headphones?" "${ch[0]}" "${ch[@]}"
  fi
  return 0
}
dx_bt_hsp() {
  sd_load pactlcards || return 2
  local card
  card=$(awk '/^[ \t]*Name: /{n=$2} /Active Profile: (headset-head-unit|handsfree_head_unit|headset_head_unit)/ && n ~ /bluez/ {print n; exit}' "$SD_F")
  [ -n "$card" ] || return 1
  SD_ARGS=("$card"); SD_DET=$card
  return 0
}
dx_hidpi_unscaled() {
  local m f u cfg
  u=$(sd_user); [ -n "$u" ] || return 1
  for f in "$SLH_SYS"/class/drm/card*-*/modes; do
    [ -r "$f" ] || continue
    [ "$(slh_rd "$(dirname "$f")/status")" = connected ] || continue
    m=$(head -n1 "$f")
    case "$m" in 3840x2160|2880x1800|2560x1600|3200x1800|3456x2160|2880x1620) ;; *) continue ;; esac
    cfg=$(sd_path "home/$u/.config/kwinoutputconfig.json")
    [ -r "$cfg" ] || return 2
    grep -qE '"scale" *: *1(\.0*)?[,} ]' "$cfg" && { SD_DET=$m; return 0; }
  done
  return 1
}
dx_ext_monitor_off() {
  local f n=0 off=""
  for f in "$SLH_SYS"/class/drm/card*-*; do
    [ -r "$f/status" ] || continue
    [ "$(slh_rd "$f/status")" = connected ] || continue
    n=$((n + 1))
    [ "$(slh_rd "$f/enabled")" = disabled ] && off=${f##*/}
  done
  [ "$n" -ge 2 ] && [ -n "$off" ] && { SD_DET=$off; return 0; }
  return 1
}
dx_keymap_mismatch() {
  sd_load localectl || return 2
  local vc x
  vc=$(sed -n 's/^ *VC Keymap: *//p' "$SD_F" | head -n1); x=$(sed -n 's/^ *X11 Layout: *//p' "$SD_F" | head -n1)
  [ -n "$vc" ] && [ -n "$x" ] && [ "$vc" != "(unset)" ] && [ "$x" != "(unset)" ] || return 1
  x=${x%%,*}
  [ "${vc:0:2}" = "${x:0:2}" ] && return 1
  SD_DET="console: $vc, desktop: $x"; SD_ARGS=("$x")
  return 0
}
dx_printer_usb() {
  local line c
  while IFS='|' read -r _ c _ _; do [ "$c" = 07 ] && return 0; done < <(slh_usb_ifaces)
  return 1
}
dx_repos_disabled() {
  local f id
  for f in "$(sd_path etc/yum.repos.d)"/fedora.repo "$(sd_path etc/yum.repos.d)"/fedora-updates.repo; do
    [ -r "$f" ] || continue
    id=$(awk '/^\[/{sec=$0} /^enabled *= *0/ && (sec=="[fedora]" || sec=="[updates]") {print sec; exit}' "$f")
    [ -n "$id" ] && { SD_DET="$id in ${f##*/}"; return 0; }
  done
  return 1
}
dx_repos_failing() {
  local f; for f in "$(sd_path var/log/dnf5.log)" "$(sd_path var/log/dnf.log)" "$(sd_path var/log/hawkey.log)"; do
    [ -r "$f" ] || continue
    tail -n 300 "$f" | grep -qiE 'Failed to download metadata|Cannot download repomd|GPG check FAILED|Curl error|Cannot prepare internal mirrorlist' && { SD_DET=$(tail -n 300 "$f" | grep -iE 'Failed to download metadata|Cannot download repomd|GPG check FAILED|Curl error' | tail -n1); return 0; }
    return 1
  done
  return 1
}
dx_scan_overdue() {
  compgen -G "$(sd_path usr/bin/clamscan)" >/dev/null || return 1
  local f; f=$(sd_path var/lib/secure-linux/health/last-malware-scan)
  [ -e "$f" ] || return 0
  sd_age_days var/lib/secure-linux/health/last-malware-scan || return 1
  [ "$SD_V" -ge 60 ]
}
dx_sudo_broken() {
  local u g f
  sd_expr 'cmd:visudo~\[rc=[1-9]'
  [ "$SD_R" = 0 ] && { SD_DET="The sudo settings file has an error."; return 0; }
  u=$(sd_user); [ -n "$u" ] || return 1
  f=$(sd_path etc/group); [ -r "$f" ] || return 2
  for g in wheel sudo; do
    grep -qE "^$g:[^:]*:[^:]*:(.*,)?$u(,.*)?$" "$f" && return 1
  done
  grep -qE '^(wheel|sudo):' "$f" || return 1
  SD_DET="$u is not allowed to make administrator changes"; SD_ARGS=("$u")
  return 0
}
dx_home_root_owned() {
  sd_load rootowned || return 2
  [ -s "$SD_F" ] || return 1
  local first; first=$(grep -m1 '[^[:space:]]' "$SD_F")   # a file with only blank lines means "nothing found"
  [ -n "$first" ] || return 1
  SD_DET="Files such as ${first##*/} in the home folder belong to the administrator."
  SD_ARGS=("$(sd_user)")
  return 0
}
dx_ha_token_perms() {
  local f p
  f=$(sd_choice ha_token_file /etc/secure-linux/ha-token); f=$(sd_path "$f")
  [ -e "$f" ] || return 1
  p=$(stat -c %a "$f" 2>/dev/null) || return 2
  [ "${#p}" -ge 3 ] || return 1
  [ "${p: -2}" = 00 ] && return 1
  SD_DET="permissions $p"; return 0
}

# ---------------------------------------------------------------- which Linux system is the one to check (rescue / live)
SD_NTARGETS=0; SD_TARGET_CHOICES=""; SD_TARGET_DEFAULT=""; SD_TARGET_ONE_DEV=""
sd_find_targets() {   # lists the Linux root candidates; one -> use it; several -> one plain question
  SD_NTARGETS=0; SD_TARGET_CHOICES=""; SD_TARGET_DEFAULT=""; SD_TARGET_ONE_DEV=""
  sd_load lsblkfs || return 0
  local line dev fs size label mp first="" out="" n=0 pick=""
  while IFS= read -r line; do
    dev=$(sed -n 's/.*NAME="\([^"]*\)".*/\1/p' <<< "$line"); fs=$(sed -n 's/.*FSTYPE="\([^"]*\)".*/\1/p' <<< "$line")
    size=$(sed -n 's/.*SIZE="\([^"]*\)".*/\1/p' <<< "$line"); label=$(sed -n 's/.*LABEL="\([^"]*\)".*/\1/p' <<< "$line"); mp=$(sed -n 's/.*MOUNTPOINT="\([^"]*\)".*/\1/p' <<< "$line")
    case "$fs" in btrfs|ext4|xfs|f2fs) ;; *) continue ;; esac
    case "$mp" in /|/run/*|/boot*|/usr*|/var*) continue ;; esac
    n=$((n + 1))
    out="${out:+$out$US}$dev ($fs, $size${label:+, $label})"
    [ -z "$first" ] && first="$dev ($fs, $size${label:+, $label})"
    [ -z "$pick" ] && [ "$fs" = btrfs ] && pick="$dev ($fs, $size${label:+, $label})"
    [ "$n" = 1 ] && SD_TARGET_ONE_DEV=$dev
  done < "$SD_F"
  SD_NTARGETS=$n
  if [ "$n" -gt 1 ]; then SD_TARGET_CHOICES=$out; SD_TARGET_DEFAULT=${pick:-$first}; fi
  return 0
}
sd_use_target() {   # sd_use_target DEVICE : open it read-only (a fixture keeps its fake root)
  local dev=$1 m
  [ -n "$SD_FIX" ] && { SD_HAVE_TARGET=1; return 0; }
  slh_is_root || { sd_limited "the installed system (needs administrator rights to open it for reading)"; return 1; }
  m=$SD_TMP/target; mkdir -p "$m"
  if mount -o ro "$dev" "$m" 2>/dev/null && [ -r "$m/etc/os-release" ]; then :
  else umount "$m" 2>/dev/null; mount -o ro,subvol=root "$dev" "$m" 2>/dev/null || { sd_limited "the system on $dev (could not be opened)"; return 1; }; fi
  SD_MOUNTED=$m; SD_ROOT=$m; SD_HAVE_TARGET=1
  # /boot and the EFI partition from its own drive list, read-only
  local src mp fs opts
  while read -r src mp fs opts _ _; do case "$mp" in /boot|/boot/efi) mount -o ro "$src" "$m$mp" 2>/dev/null ;; esac; done < <(grep -vE '^\s*#' "$m/etc/fstab" 2>/dev/null | sed 's/^UUID=/\/dev\/disk\/by-uuid\//')
  return 0
}
