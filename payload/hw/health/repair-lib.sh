# shellcheck shell=bash
# hw/health/repair-lib.sh (owner: hardware) - helpers for secure-linux-repair: which system are we in, finding and
# mounting the broken Fedora (btrfs layout), the "dry run" switch, backups, the SMART warning before any write.
# Sourced by bin/secure-linux-repair after lib.sh. Everything that changes something goes through rp_run / rp_run_t,
# so "--dry-run" can show exactly what would happen without doing any of it.
#
# Test hooks: SL_REPAIR_ENV (installed|systemrescue|fedora-live|anaconda-rescue|other-live), SL_TEST_OSRELEASE,
# SL_REPAIR_MNT (where the broken system is mounted), SL_TEST_SYSFS/SL_TEST_PROC.

RP_DRY=${RP_DRY:-0}
RP_TARGET=""            # "/" = the running system; otherwise the folder the broken system is mounted at
RP_MNT=${SL_REPAIR_MNT:-/mnt/sl-target}
RP_ROOTDEV=""; RP_SUBVOL=""
declare -a RP_OPENED=() RP_MOUNTED=()
RP_LOG=${SL_REPAIR_LOG:-}

rp_env() {   # installed | systemrescue | fedora-live | anaconda-rescue | other-live
  [ -n "${SL_REPAIR_ENV:-}" ] && { echo "$SL_REPAIR_ENV"; return; }
  local id name osr=${SL_TEST_OSRELEASE:-/etc/os-release}
  id=$(. "$osr" 2>/dev/null; echo "${ID:-}"); name=$(. "$osr" 2>/dev/null; echo "${NAME:-}")
  if [ -d /run/archiso ] || printf '%s' "$name" | grep -qi 'systemrescue'; then echo systemrescue; return; fi
  if [ -d /mnt/sysimage/etc ] && { [ -d /run/install ] || [ -e /run/anaconda ] || pgrep -x anaconda >/dev/null 2>&1; }; then echo anaconda-rescue; return; fi
  if [ -e /run/initramfs/live ] || [ -d /run/rootfsbase ] || grep -qE 'rd.live.image|rootfstype=overlay|archisobasedir' /proc/cmdline 2>/dev/null; then echo fedora-live; return; fi
  if [ -d "$SL_ETC" ] || [ -x /usr/local/bin/secure-linux-status ]; then echo installed; return; fi
  [ "$id" = fedora ] && { echo installed; return; }
  echo other-live
}
rp_efi_mode() { if [ -n "${SL_TEST_EFI:-}" ]; then echo "$SL_TEST_EFI"; elif [ -d /sys/firmware/efi ]; then echo uefi; else echo bios; fi; }
rp_env_name() {
  case "$1" in
    installed) echo "your installed Fedora (Secure Linux)" ;; systemrescue) echo "SystemRescue (from the USB stick)" ;;
    fedora-live) echo "a Fedora live system" ;; anaconda-rescue) echo "the Fedora installer's rescue mode" ;; *) echo "a live Linux system" ;;
  esac
}
rp_is_live() { [ "$(rp_env)" != installed ]; }
rp_t() { printf '%s' "${RP_TARGET:-/}"; }
rp_log() { [ -n "$RP_LOG" ] && printf '%s\n' "$*" >> "$RP_LOG"; return 0; }

# ---------------------------------------------------------------- doing things (or only showing them)
rp_run() {       # rp_run CMD ARGS...   run it (or print it in dry-run mode)
  rp_log "RUN $*"
  if [ "$RP_DRY" = 1 ]; then printf '  [dry run] would run: %s\n' "$*"; return 0; fi
  printf '  >> %s\n' "$*"; "$@"
}
rp_run_t() {     # rp_run_t CMD ARGS...   same, inside the system being repaired (chroot unless it is this one)
  local t; t=$(rp_t)
  if [ "$t" = / ]; then rp_run "$@"; return; fi
  rp_log "RUN(in $t) $*"
  if [ "$RP_DRY" = 1 ]; then printf '  [dry run] would run inside %s: %s\n' "$t" "$*"; return 0; fi
  printf '  >> (inside %s) %s\n' "$t" "$*"; chroot "$t" "$@"
}
rp_step() {      # rp_step "Title" "plain description"   -> 0 to go ahead (explicit yes); dry-run always goes ahead (nothing is changed)
  # RP_APPROVED=1: the whole plan was approved once already (by the Toolbox, or --approved), so there is no second "Go ahead?"
  printf '\n'
  if declare -F ui_h2 >/dev/null; then ui_h2 "$1"; else printf '== %s ==\n' "$1"; fi
  printf '%s\n' "$2"
  if [ "$RP_DRY" = 1 ]; then echo "(dry run: nothing will be changed)"; return 0; fi
  [ "${RP_APPROVED:-0}" = 1 ] && return 0
  slh_confirm "Go ahead with this step?"
}
rp_typed() {     # rp_typed WORD "warning"   -> 0 only if the exact word is typed (dry-run: shows the word, goes ahead)
  if [ "$RP_DRY" = 1 ]; then printf '\n%s\n(dry run: you would have to type  %s  to continue)\n' "$2" "$1"; return 0; fi
  # the Toolbox already collected the typed words and says so with --approved --approved-typed
  [ "${RP_APPROVED_TYPED:-0}" = 1 ] && [ "${RP_APPROVED:-0}" = 1 ] && return 0
  slh_typed "$1" "$2"
}
rp_need_cmd() {  # rp_need_cmd tool "package" -> 0 if present; otherwise explains and returns 1
  have "$1" && return 0
  echo "The tool '$1' is not available here${2:+ (package: $2)}. ${3:-}"
  return 1
}
rp_pause() { [ "$RP_DRY" = 1 ] && return 0; local x; slh_read x "Press Enter to continue. " || true; }

# ---------------------------------------------------------------- disks
rp_parent_disk() {   # /dev/sda3 -> /dev/sda ; /dev/mapper/x -> its underlying disk when lsblk knows it
  local d=$1 pk
  pk=$(lsblk -no PKNAME "$d" 2>/dev/null | head -n1)
  [ -n "$pk" ] && { printf '/dev/%s' "$pk"; return; }
  printf '%s' "$d"
}
rp_disk_label() {    # "/dev/sda (Samsung SSD 860, 465.8G)"
  local d=$1 m s
  m=$(lsblk -dno MODEL "$d" 2>/dev/null | sed 's/  */ /g; s/ $//'); s=$(lsblk -dno SIZE "$d" 2>/dev/null)
  printf '%s (%s, %s)' "$d" "${m:-unknown model}" "${s:-?}"
}
rp_smart_state() {   # ok | bad | unknown   for the disk behind DEV
  local disk out
  disk=$(rp_parent_disk "$1")
  have smartctl || { echo unknown; return; }
  out=$(smartctl -H -A "$disk" 2>&1)
  if printf '%s' "$out" | grep -qE 'FAILED|Critical Warning: *0x(0[1-9a-f]|[1-9a-f])'; then echo bad; return; fi
  if printf '%s' "$out" | awk '/Current_Pending_Sector|Offline_Uncorrectable|Reallocated_Sector_Ct/ { if ($10 + 0 > 0) bad = 1 } END { exit !bad }'; then echo bad; return; fi
  printf '%s' "$out" | grep -qE 'PASSED|SMART Health Status: OK|Critical Warning: *0x00' && echo ok || echo unknown
}
rp_smart_guard() {   # rp_smart_guard DEV -> 0 = fine to write; 1 = stop. A failing drive gets a loud warning first.
  local st; st=$(rp_smart_state "$1")
  case "$st" in
    bad)
      cat <<EOF

  !! WARNING: the drive $(rp_disk_label "$(rp_parent_disk "$1")") says it is FAILING (SMART).
  !! Repairs write to the drive. On a failing drive that can destroy files that could still be saved.
  !! Rescue your files FIRST (menu: Rescue my files), onto another drive. Only then repair.
EOF
      if [ "$RP_DRY" = 1 ]; then echo "  (dry run: you would have to type  I HAVE BACKED UP  to continue)"; return 0; fi
      slh_typed "I HAVE BACKED UP" "Type the words below only if your files are already safe somewhere else." ;;
    unknown) echo "  (Drive health could not be read for $(rp_parent_disk "$1"): smartctl missing, a USB bridge or no administrator rights. Be careful.)"; return 0 ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------- finding the Secure Linux stick and its scripts
slh_find_stick() {   # prints the folder that holds linux-setup/ (the Secure Linux USB stick)
  local d dev
  for d in "${SL_STICK:-}" /run/media/*/Ventoy /run/media/*/* /media/*/* /media/* /mnt/* /run/archiso/bootmnt /run/initramfs/live; do
    [ -n "$d" ] && [ -d "$d/linux-setup" ] && { echo "$d"; return 0; }
  done
  dev=$(lsblk -rpno NAME,LABEL 2>/dev/null | awk '$2=="Ventoy"{print $1; exit}'); [ -n "$dev" ] || dev=/dev/disk/by-label/Ventoy
  if [ -e "$dev" ] && [ "$RP_DRY" != 1 ]; then
    mkdir -p /mnt/sl-stick 2>/dev/null
    mountpoint -q /mnt/sl-stick 2>/dev/null || mount -o ro "$dev" /mnt/sl-stick 2>/dev/null
    [ -d /mnt/sl-stick/linux-setup ] && { echo /mnt/sl-stick; return 0; }
  fi
  return 1
}
rp_find_script() {   # rp_find_script forgot-login-password.sh -> path (stick or next to this kit), or nothing
  local n=$1 d s
  for d in "${SL_ROOT:-}/rescue" "${SL_ROOT:-}/../rescue" "$HLIB/../../rescue" ; do [ -r "$d/$n" ] && { echo "$d/$n"; return 0; }; done
  s=$(slh_find_stick) && [ -r "$s/linux-setup/rescue/$n" ] && { echo "$s/linux-setup/rescue/$n"; return 0; }
  return 1
}

# ---------------------------------------------------------------- the broken system: find it, unlock it, mount it
rp_lsblk() {   # rp_lsblk COL1,COL2,... [lsblk args] -> one line per device: val1|val2|...  (empty values stay empty, spaces in names are safe)
  local cols=$1; shift
  lsblk -P -p -o "$cols" "$@" 2>/dev/null | awk -v cols="$cols" '
    BEGIN { n = split(cols, c, ",") }
    { line = " " $0; out = ""
      for (i = 1; i <= n; i++) {
        v = ""
        if (match(line, " " c[i] "=\"[^\"]*\"")) v = substr(line, RSTART + length(c[i]) + 3, RLENGTH - length(c[i]) - 4)
        gsub(/\\x20/, " ", v)
        out = out (i > 1 ? "|" : "") v
      }
      print out }'
}
rp_luks_candidates() { lsblk -rpno NAME,FSTYPE 2>/dev/null | awk '$2=="crypto_LUKS"{print $1}'; }
rp_fs_candidates() {   # DEVICE|FSTYPE|SIZE|LABEL  for every partition that could hold a Linux root (incl. unlocked LUKS)
  rp_lsblk NAME,FSTYPE,SIZE,LABEL | awk -F'|' '$2=="btrfs"||$2=="ext4"||$2=="xfs"||$2=="f2fs"{print}'
}
rp_unlock_all() {   # offers to unlock each encrypted partition (cryptsetup asks for the passphrase itself)
  local dev n=0 name a
  for dev in $(rp_luks_candidates); do
    n=$((n + 1)); name="sl-repair-$n"
    lsblk -rno TYPE "$dev" 2>/dev/null | grep -q crypt && continue          # already open
    printf '\nThe partition %s is encrypted (LUKS). To repair it, it has to be unlocked with your DISK password (or recovery key).\n' "$dev"
    if [ "$RP_DRY" = 1 ]; then echo "  [dry run] would run: cryptsetup open $dev $name"; continue; fi
    slh_read a "Unlock $dev now? [y/N] " || return 1
    case "$(slh_lc "$a")" in y|yes) cryptsetup open "$dev" "$name" && RP_OPENED+=("$name") ;; esac
  done
}
rp_probe() {   # rp_probe DEV FSTYPE -> prints "subvol|PRETTY_NAME" if DEV holds a Linux root (mounted read-only for a moment)
  local dev=$1 fs=$2 p=/mnt/sl-probe sv name
  mkdir -p "$p"
  for sv in "" root; do
    umount "$p" 2>/dev/null
    if [ "$fs" = btrfs ] && [ -n "$sv" ]; then mount -o ro,subvol="$sv" "$dev" "$p" 2>/dev/null || continue
    elif [ -z "$sv" ]; then mount -o ro "$dev" "$p" 2>/dev/null || continue
    else continue; fi
    if [ -r "$p/etc/os-release" ]; then
      name=$(. "$p/etc/os-release" 2>/dev/null; echo "${PRETTY_NAME:-Linux}")
      umount "$p" 2>/dev/null; printf '%s|%s\n' "$sv" "$name"; return 0
    fi
  done
  umount "$p" 2>/dev/null; return 1
}
rp_mount_fstab_extras() {   # mount /boot, /boot/efi, /home ... of the broken system from ITS fstab (btrfs subvolumes included)
  local t=$1 src mp fs opts _a _b
  [ -r "$t/etc/fstab" ] || return 0
  while read -r src mp fs opts _a _b; do
    case "$src" in ''|'#'*) continue ;; esac
    case "$mp" in /boot|/boot/efi|/home|/var|/usr) ;; *) continue ;; esac
    case ",$opts," in *,noauto,*) continue ;; esac
    mountpoint -q "$t$mp" 2>/dev/null && continue
    if [ "$RP_DRY" = 1 ]; then printf '  [dry run] would run: mount -t %s -o %s %s %s\n' "$fs" "$opts" "$src" "$t$mp"; continue; fi
    mkdir -p "$t$mp"
    printf '  >> mount %s on %s\n' "$src" "$t$mp"
    mount -t "$fs" -o "$opts" "$src" "$t$mp" 2>/dev/null && RP_MOUNTED+=("$t$mp") || echo "     (could not mount $mp from $src; continuing)"
  done < "$t/etc/fstab"
}
rp_chroot_binds() {   # /dev /proc /sys /run and the EFI variables, so grub, dracut and efibootmgr work inside the chroot
  local t=$1 m
  for m in dev dev/pts proc sys run; do
    mountpoint -q "$t/$m" 2>/dev/null && continue
    if [ "$RP_DRY" = 1 ]; then printf '  [dry run] would run: mount --bind /%s %s/%s\n' "$m" "$t" "$m"; continue; fi
    mkdir -p "$t/$m"; mount --bind "/$m" "$t/$m" && RP_MOUNTED+=("$t/$m")
  done
  if { [ -d /sys/firmware/efi/efivars ] || [ -n "${SL_TEST_EFI:-}" ]; } && [ "$(rp_efi_mode)" = uefi ]; then
    if [ "$RP_DRY" = 1 ]; then printf '  [dry run] would run: mount --bind /sys/firmware/efi/efivars %s/sys/firmware/efi/efivars\n' "$t"
    else mkdir -p "$t/sys/firmware/efi/efivars"; mount --bind /sys/firmware/efi/efivars "$t/sys/firmware/efi/efivars" 2>/dev/null && RP_MOUNTED+=("$t/sys/firmware/efi/efivars"); fi
  fi
  # DNS inside the chroot (for dnf): the system's resolv.conf is usually a link into /run
  if [ "$RP_DRY" != 1 ] && { [ ! -s "$t/etc/resolv.conf" ] || [ -L "$t/etc/resolv.conf" ]; }; then
    mv -f "$t/etc/resolv.conf" "$t/etc/resolv.conf.sl-saved" 2>/dev/null; cp /etc/resolv.conf "$t/etc/resolv.conf" 2>/dev/null; RP_RESOLV_SAVED=1
  fi
}
rp_cleanup() {   # undo everything we mounted, in reverse order; lock what we unlocked
  local i m
  [ "${RP_DRY:-0}" = 1 ] && return 0
  if [ "${RP_RESOLV_SAVED:-0}" = 1 ] && [ -n "$RP_TARGET" ]; then rm -f "$RP_TARGET/etc/resolv.conf"; mv -f "$RP_TARGET/etc/resolv.conf.sl-saved" "$RP_TARGET/etc/resolv.conf" 2>/dev/null; fi
  sync
  for ((i = ${#RP_MOUNTED[@]} - 1; i >= 0; i--)); do umount "${RP_MOUNTED[i]}" 2>/dev/null || umount -l "${RP_MOUNTED[i]}" 2>/dev/null; done
  mountpoint -q "$RP_MNT" 2>/dev/null && umount "$RP_MNT" 2>/dev/null
  for m in "${RP_OPENED[@]:-}"; do [ -n "$m" ] && [ -e "/dev/mapper/$m" ] && cryptsetup close "$m" 2>/dev/null; done
  return 0
}

rp_target_ensure() {   # rp_target_ensure rw|ro  -> sets RP_TARGET; returns 1 if no Linux system could be found/chosen
  local mode=${1:-rw} env choice i n=0 dev fs size label info sv pretty opts
  [ -n "$RP_TARGET" ] && return 0
  env=$(rp_env)
  if [ "$env" = installed ] && [ -z "${RP_WANT_TARGET:-}" ]; then RP_TARGET=/; return 0; fi
  if [ -n "${RP_WANT_TARGET:-}" ]; then RP_TARGET=$RP_WANT_TARGET; return 0; fi
  if [ "$env" = anaconda-rescue ] && [ -r /mnt/sysimage/etc/os-release ]; then RP_TARGET=/mnt/sysimage; return 0; fi
  echo; echo "Looking for the Linux system to repair..."
  rp_unlock_all
  declare -a C_DEV=() C_FS=() C_SV=() C_NAME=()
  while IFS='|' read -r dev fs size label; do
    [ -n "$dev" ] || continue
    if [ "$RP_DRY" = 1 ]; then
      n=$((n + 1)); C_DEV[n]=$dev; C_FS[n]=$fs; C_SV[n]=$( [ "$fs" = btrfs ] && echo root ); C_NAME[n]="$fs ${size}${label:+, $label}"
    elif info=$(rp_probe "$dev" "$fs"); then
      n=$((n + 1)); C_DEV[n]=$dev; C_FS[n]=$fs; C_SV[n]=${info%%|*}; C_NAME[n]="${info#*|} on $dev ($fs, $size)"
    fi
  done < <(rp_fs_candidates)
  if [ "$n" -eq 0 ]; then
    echo "No Linux system was found on this computer's drives."
    echo "If the drive is encrypted, unlock it first (say yes when asked). If this PC only has Windows, use the Windows and data-rescue options instead."
    return 1
  fi
  choice=1
  if [ "$n" -gt 1 ]; then
    local def=1; for ((i = n; i >= 1; i--)); do [ "${C_FS[i]}" = btrfs ] && def=$i; done
    echo "More than one Linux system was found:"
    for ((i = 1; i <= n; i++)); do printf '  %d) %s\n' "$i" "${C_NAME[i]}"; done
    rp_ask choice "Which one do you want to repair? (number, Enter = $def) " "$def" || return 1
    choice=${choice:-$def}
    [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$n" ] || { echo "That wasn't one of the numbers. Nothing was changed."; return 1; }
  fi
  RP_ROOTDEV=${C_DEV[choice]}; RP_SUBVOL=${C_SV[choice]}
  opts=$mode; [ -n "$RP_SUBVOL" ] && opts="$opts,subvol=$RP_SUBVOL"
  echo "Using: ${C_NAME[choice]}  (opened $mode)"
  if [ "$mode" = rw ]; then rp_smart_guard "$RP_ROOTDEV" || return 1; fi
  if [ "$RP_DRY" = 1 ]; then printf '  [dry run] would run: mkdir -p %s\n  [dry run] would run: mount -o %s %s %s\n' "$RP_MNT" "$opts" "$RP_ROOTDEV" "$RP_MNT"
  else
    mkdir -p "$RP_MNT"
    mount -o "$opts" "$RP_ROOTDEV" "$RP_MNT" || { echo "Could not open the system. Nothing was changed."; return 1; }
    RP_MOUNTED+=("$RP_MNT")
  fi
  RP_TARGET=$RP_MNT
  rp_mount_fstab_extras "$RP_TARGET"
  [ "$mode" = rw ] && rp_chroot_binds "$RP_TARGET"
  return 0
}

# ---------------------------------------------------------------- backup before changes
rp_backup() {   # rp_backup "why" -> saves the boot-related files of the system being repaired, and a btrfs snapshot if snapper is there
  local t stamp dir
  t=$(rp_t); stamp=$(date +%Y%m%d-%H%M%S); dir="$t/var/lib/secure-linux/repair-backup"
  echo; echo "Safety copy first ($1)..."
  if [ "$RP_DRY" = 1 ]; then
    printf '  [dry run] would run: tar czf %s/boot-%s.tar.gz  etc/fstab etc/default/grub boot/grub2/grub.cfg boot/loader boot/efi/EFI\n' "$dir" "$stamp"
    have snapper && printf '  [dry run] would run: snapper -c root create -d "before secure-linux-repair"\n'
    return 0
  fi
  mkdir -p "$dir" 2>/dev/null
  ( cd "$t" && tar czf "$dir/boot-$stamp.tar.gz" etc/fstab etc/default/grub boot/grub2/grub.cfg boot/loader boot/efi/EFI 2>/dev/null ) \
    && echo "  Saved: ${dir#"${t%/}"}/boot-$stamp.tar.gz" || echo "  (could not save a copy of the boot files; continuing carefully)"
  if [ "$t" = / ] && have snapper && snapper list-configs 2>/dev/null | grep -q root; then
    snapper -c root create -d "before secure-linux-repair $stamp" >/dev/null 2>&1 && echo "  Snapshot created: before secure-linux-repair $stamp"
  fi
  return 0
}

# ---------------------------------------------------------------- asking (dry-run with SL_REPAIR_AUTO=1 takes the default)
rp_ask() {   # rp_ask VAR "prompt" [default]
  if [ "$RP_DRY" = 1 ] && [ -n "${SL_REPAIR_AUTO:-}" ]; then printf -v "$1" '%s' "${3:-}"; printf '%s[auto: %s]\n' "$2" "${3:-}"; return 0; fi
  slh_read "$1" "$2"
}
rp_dev_of_path() { findmnt -no SOURCE -T "$1" 2>/dev/null | head -n1; }
rp_size_bytes() { blockdev --getsize64 "$1" 2>/dev/null || lsblk -bdno SIZE "$1" 2>/dev/null | head -n1; }
rp_free_bytes() { df -P -B1 "$1" 2>/dev/null | awk 'NR==2{print $4}'; }
rp_list_partitions() {   # numbered list on stderr; fills RP_PART_DEV[] ; prints nothing on stdout
  local i=0 dev fs size label mp
  RP_PART_DEV=(); RP_PART_FS=(); RP_PART_MP=()
  printf '\n  %-3s %-16s %-12s %-9s %-14s %s\n' "No." "Drive/partition" "Type" "Size" "Name" "In use at" >&2
  while IFS='|' read -r dev fs size label mp; do
    [ -n "$dev" ] && [ -n "$fs" ] || continue
    case "$fs" in swap|linux_raid_member|LVM2_member|iso9660|squashfs) [ "$fs" = swap ] && continue ;; esac
    i=$((i + 1)); RP_PART_DEV[i]=$dev; RP_PART_FS[i]=$fs; RP_PART_MP[i]=$mp
    printf '  %-3s %-16s %-12s %-9s %-14s %s\n' "$i" "$dev" "$fs" "$size" "${label:--}" "${mp:--}" >&2
  done < <(rp_lsblk NAME,FSTYPE,SIZE,LABEL,MOUNTPOINT)
  RP_PART_N=$i
}
