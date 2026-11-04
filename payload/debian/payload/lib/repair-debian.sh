# shellcheck shell=bash
# lib/repair-debian.sh (Debian) - the Debian versions of the repair actions of secure-linux-repair.
# Sourced by bin/secure-linux-repair AFTER the shared libraries (linux/hw/health/lib.sh, repair-*.sh), so every function here
# replaces the Fedora one of the same name. What the Fedora actions assume and what is different on this Debian setup:
#   Fedora: btrfs, grub2-mkconfig /boot/grub2/grub.cfg, dracut, grubby, dnf, snapper, SELinux
#   Debian: ext4 inside LVM inside LUKS (preseed), update-grub /boot/grub/grub.cfg, initramfs-tools (update-initramfs),
#           grub-set-default, apt/dpkg, LVM snapshots (secure-linux-snapshot), no SELinux
# Everything that changes something goes through rp_step (explicit yes) and rp_run / rp_run_t (shown, and only printed in a dry run).
# Actions that did not need changing (data rescue, disk clone, wipe, hardware check, factory reset) stay the shared ones.

# ---------------------------------------------------------------- environment wording
rp_env_name() {
  case "$1" in
    installed) echo "your installed Debian (Secure Linux)" ;; systemrescue) echo "SystemRescue (from the USB stick)" ;;
    fedora-live) echo "a live Linux system" ;; anaconda-rescue) echo "a rescue shell" ;; *) echo "a live Linux system" ;;
  esac
}
online_ok() {
  case "${SL_PARTS_ONLINE:-}" in yes) return 0 ;; no) return 1 ;; esac
  curl -fsS --max-time 8 -o /dev/null https://deb.debian.org/debian/ 2>/dev/null || ping -c1 -W3 1.1.1.1 >/dev/null 2>&1
}

# ---------------------------------------------------------------- unlock: LUKS first, then the LVM volumes inside it
if ! declare -F rp_unlock_all_shared >/dev/null; then
  eval "$(declare -f rp_unlock_all | sed '1s/rp_unlock_all/rp_unlock_all_shared/')"
fi
rp_unlock_all() {
  rp_unlock_all_shared "$@"
  # Debian's disk is LUKS > LVM > ext4: the logical volumes only appear after the volume group is switched on
  if command -v vgchange >/dev/null 2>&1; then
    if [ "$RP_DRY" = 1 ]; then echo "  [dry run] would run: vgchange -ay   (switches on the logical volumes inside the unlocked disk)"
    else echo "  >> vgchange -ay"; vgchange -ay >/dev/null 2>&1; command -v udevadm >/dev/null 2>&1 && udevadm settle 2>/dev/null; fi
  fi
}

# ---------------------------------------------------------------- safety copy before changes
rp_backup() {   # rp_backup "why"
  local t stamp dir
  t=$(rp_t); stamp=$(date +%Y%m%d-%H%M%S); dir="$t/var/lib/secure-linux/repair-backup"
  echo; echo "Safety copy first ($1)..."
  if [ "$RP_DRY" = 1 ]; then
    printf '  [dry run] would run: tar czf %s/boot-%s.tar.gz  etc/fstab etc/crypttab etc/default/grub boot/grub boot/efi/EFI\n' "$dir" "$stamp"
    command -v secure-linux-snapshot >/dev/null 2>&1 && printf '  [dry run] would run: secure-linux-snapshot create --reason "before secure-linux-repair"\n'
    return 0
  fi
  mkdir -p "$dir" 2>/dev/null
  ( cd "$t" && tar czf "$dir/boot-$stamp.tar.gz" etc/fstab etc/crypttab etc/default/grub boot/grub boot/efi/EFI 2>/dev/null ) \
    && echo "  Saved: ${dir#"${t%/}"}/boot-$stamp.tar.gz" || echo "  (could not save a copy of the boot files; continuing carefully)"
  if [ "$t" = / ] && command -v secure-linux-snapshot >/dev/null 2>&1; then
    secure-linux-snapshot create --reason "before secure-linux-repair $stamp" 2>&1 | sed 's/^/  /'
  fi
  return 0
}

# ---------------------------------------------------------------- find out what is wrong
act_diagnose() {
  local T efi out line sev act txt rec="" vm=0 ver s tag i src mp fs opts _a _b uuid
  echo; echo "=== Finding out what is wrong (this only looks; it changes nothing) ==="
  efi=$(rp_efi_mode)
  echo "Start-up mode of this computer: $efi.  Running from: $(rp_env_name "$(rp_env)")."
  if ! rp_target_ensure ro; then echo "(No Linux system could be opened, so only the hardware was checked.)"; fi
  T=$(rp_t)
  FIND=()
  # --- firmware boot entries
  if [ "$efi" = uefi ] && have efibootmgr; then
    out=$(efibootmgr 2>&1)
    if printf '%s' "$out" | grep -qi 'not supported'; then find_add 3 boot "The firmware's start-up entries can't be read from here."
    else
      printf '%s\n' "$out" | grep -qiE 'debian|shim|grub' || find_add 1 boot "The computer's firmware has no start-up entry for Debian, so it does not know where to start from. (Often after a BIOS reset, a new drive, or Windows overwriting the list.)"
      printf '%s\n' "$out" | sed -n 's/^BootOrder: *//p' | head -n1 | tr ',' '\n' | head -n1 | while read -r first; do
        printf '%s\n' "$out" | grep -E "^Boot$first" | grep -qi 'windows' && echo "WINFIRST"; done | grep -q WINFIRST && find_add 3 windows "The firmware starts Windows first, not Debian. (Choose Debian in the firmware boot menu, or fix the order in the Windows menu.)"
    fi
  elif [ "$efi" = uefi ]; then find_add 3 boot "efibootmgr is not available here, so the firmware entries were not checked."; fi
  # --- files the boot needs
  if [ -d "$T/boot" ]; then
    for line in "$T"/boot/vmlinuz-*; do
      [ -e "$line" ] || continue
      vm=$((vm + 1)); ver=${line##*/vmlinuz-}
      [ -e "$T/boot/initrd.img-$ver" ] || find_add 1 boot "Kernel $ver has no start-up image (initramfs). It cannot start. (The boot repair rebuilds it.)"
    done
    [ "$vm" -eq 0 ] && find_add 1 kernel "No kernel files were found in /boot. Either /boot is not mounted here, or the kernel files are gone."
    [ -e "$T/boot/grub/grub.cfg" ] || find_add 1 boot "The boot menu file (/boot/grub/grub.cfg) is missing."
    if [ "$efi" = uefi ] && [ -d "$T/boot/efi" ]; then
      [ -e "$T/boot/efi/EFI/debian/shimx64.efi" ] || [ -e "$T/boot/efi/EFI/debian/grubx64.efi" ] || [ -e "$T/boot/efi/EFI/debian/grubia32.efi" ] || [ -e "$T/boot/efi/EFI/BOOT/BOOTX64.EFI" ] \
        || find_add 1 boot "The boot loader program (GRUB/shim) is missing from the EFI system partition."
    fi
  fi
  # --- crypttab / fstab pointing at drives that are not there
  if [ -r "$T/etc/crypttab" ]; then
    while read -r src mp fs opts; do
      case "$src" in ''|'#'*) continue ;; esac
      case "$mp" in UUID=*) uuid=${mp#UUID=}
        if [ ! -e "/dev/disk/by-uuid/$uuid" ] && [ -z "$(blkid -U "$uuid" 2>/dev/null)" ]; then
          find_add 1 boot "The encrypted disk '$src' listed in /etc/crypttab (UUID $uuid) is not on this computer. The start-up waits for it and then stops."
        fi ;; esac
    done < "$T/etc/crypttab"
  fi
  if [ -r "$T/etc/fstab" ]; then
    while read -r src mp fs opts _a _b; do
      case "$src" in UUID=*) uuid=${src#UUID=} ;; *) continue ;; esac
      case ",$opts," in *,noauto,*|*,nofail,*) continue ;; esac
      [ "$fs" = swap ] && continue
      if [ ! -e "/dev/disk/by-uuid/$uuid" ] && [ -z "$(blkid -U "$uuid" 2>/dev/null)" ]; then
        find_add 1 boot "The file that lists drives (/etc/fstab) points to a drive that isn't there (UUID $uuid for $mp). That makes the computer stop in 'emergency mode'."
      fi
    done < "$T/etc/fstab"
  fi
  # --- what the previous start-up complained about
  local jl=""
  if have journalctl; then
    if [ "$T" = / ]; then jl=$(journalctl -b -1 -p err --no-pager -q 2>/dev/null | head -n 400)
    elif [ -d "$T/var/log/journal" ]; then jl=$(journalctl -D "$T/var/log/journal" -b -1 -p err --no-pager -q 2>/dev/null | head -n 400); fi
  fi
  if [ -n "$jl" ]; then
    printf '%s\n' "$jl" | grep -qiE 'I/O error|EXT4-fs error|XFS.*(corrupt|error)|nvme.*timeout|ata[0-9.]+.*failed command' && find_add 1 data "The last start-up logged disk errors. Rescue your files first, then check the disk."
    printf '%s\n' "$jl" | grep -qiE 'amdgpu.*(timeout|failed|ERROR)|NVRM|nouveau.*(fail|error)|i915.*(ERROR|GPU HANG)|Failed to start .*(Display Manager|lightdm|gdm)' && find_add 2 gpu "The last start-up had graphics errors (that fits a black or frozen screen)."
    printf '%s\n' "$jl" | grep -qiE 'Dependency failed for|Failed to mount|Timed out waiting for device' && find_add 1 boot "A drive could not be mounted at start-up (see 'emergency mode')."
    printf '%s\n' "$jl" | grep -qiE 'dpkg.*(error|corrupt)|apt.*(error|failed)' && find_add 2 packages "The software database logged errors."
  fi
  # --- right now
  if have dmesg && dmesg 2>/dev/null | grep -qiE 'I/O error, dev|Buffer I/O error'; then find_add 1 data "The kernel is reporting drive read/write errors right now."; fi
  out=$(df -P "$T" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
  [ -n "$out" ] && [ "$out" -ge 97 ] 2>/dev/null && find_add 1 fs "The system drive is ${out}% full. Programs can't start or save. Free space (empty the bin, remove old downloads, delete old snapshots)."
  if have smartctl; then
    for line in $(lsblk -dpno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'); do
      [ "$(rp_smart_state "$line")" = bad ] && find_add 1 data "$(rp_disk_label "$line") says it is failing (SMART). Rescue files first."
    done
  fi
  # --- software database: an update that stopped half-way
  if [ -n "$(ls -A "$T/var/lib/dpkg/updates" 2>/dev/null)" ]; then
    find_add 1 packages "An update stopped half-way (dpkg was interrupted). Finish it with 'Repair software'."
  fi
  if [ "$T" = / ]; then
    if have nmcli && [ "$(nmcli -t -f STATE general 2>/dev/null)" != connected ]; then find_add 2 network "The computer is not connected to the internet."; fi
    have rfkill && rfkill list 2>/dev/null | grep -q 'blocked: yes' && find_add 2 network "Wi-Fi or Bluetooth is switched off (airplane mode)."
    have dpkg && [ -n "$(dpkg --audit 2>/dev/null)" ] && find_add 1 packages "Some programs are only half-installed (dpkg --audit lists them)."
    have mokutil && mokutil --sb-state 2>/dev/null | grep -qi enabled && [ -f /var/lib/dkms/mok.pub ] && ! mokutil --test-key /var/lib/dkms/mok.pub 2>&1 | grep -qi 'already enrolled' \
      && find_add 2 gpu "Secure Boot is blocking an extra driver (NVIDIA or Broadcom) because its key was never approved. Run: sudo secure-linux-drivers enroll-key, restart, and approve it on the blue screen."
  fi
  # --- Windows next door?
  if lsblk -rno FSTYPE 2>/dev/null | grep -qiE '^ntfs$|^BitLocker$'; then find_add 3 windows "Windows (NTFS) partitions are on this computer's drives."; fi
  # --- report (same wording as the shared tool)
  echo
  if [ ${#FIND[@]} -eq 0 ]; then
    echo "I found nothing obviously wrong with the start-up, the drives or the boot files."
    echo "If something still misbehaves, run 'Check the health of every part' (hardware) or tell me the symptom:"
    echo "  - black screen -> Black or garbled screen;  - no internet -> Fix Wi-Fi;  - app won't install -> Repair software."
    RP_REC=health; return 0
  fi
  echo "WHAT I FOUND (most serious first):"
  for sev in 1 2 3; do
    for line in "${FIND[@]}"; do
      IFS='|' read -r s act txt <<< "$line"
      [ "$s" = "$sev" ] || continue
      [ -n "$rec" ] || [ "$sev" = 3 ] || rec=$act
      case "$sev" in 1) tag="[SERIOUS]" ;; 2) tag="[FIX]    " ;; *) tag="[NOTE]   " ;; esac
      printf '  %s %s\n             -> menu item: %s\n' "$tag" "$txt" "$(rp_action_label "$act")"
    done
  done
  [ -n "$rec" ] || rec=$(printf '%s\n' "${FIND[0]}" | cut -d'|' -f2)
  RP_REC=$rec
  echo
  if printf '%s\n' "${FIND[@]}" | grep -q '^1|data|'; then
    echo "RECOMMENDED NEXT STEP: rescue your files first ($(rp_action_label data)), THEN repair. Repairs write to the drive."
    RP_REC=data
  else
    echo "RECOMMENDED NEXT STEP: $(rp_action_label "$rec")   (secure-linux-repair --action $rec)"
  fi
  return 0
}

# ---------------------------------------------------------------- boot repair
rp_boot_pkgs() {   # the boot loader packages for this computer (UEFI 64-bit, UEFI 32-bit, or old BIOS)
  local efi=$1
  if [ "$efi" = uefi ]; then
    if [ -d /sys/firmware/efi/fw_platform_size ] || [ -r /sys/firmware/efi/fw_platform_size ]; then
      [ "$(cat /sys/firmware/efi/fw_platform_size 2>/dev/null)" = 32 ] && { echo "grub-efi-ia32 grub-efi-ia32-bin grub-common"; return; }
    fi
    echo "grub-efi-amd64 grub-efi-amd64-bin grub-efi-amd64-signed shim-signed grub-common"
  else echo "grub-pc grub-pc-bin grub-common"; fi
}
act_boot() {
  local T efi=bios esp espdisk espnum pk bdisk
  echo; echo "=== Computer won't start: repair the boot loader ==="
  echo "This reinstalls the start-up program (GRUB), rebuilds the boot menu and boot images, and fixes the list of drives."
  echo "Every step shows what it does and waits for your yes. A safety copy of the boot files is made first."
  efi=$(rp_efi_mode)
  rp_target_ensure rw || return 1
  T=$(rp_t)
  rp_backup "boot repair"
  rp_step "1. Check the list of drives (fstab)" "Looks for entries that point at drives that are not there, the usual cause of 'emergency mode'." && rp_fix_fstab
  pk=$(rp_boot_pkgs "$efi")
  if rp_step "2. Put the boot loader files back (needs internet)" "Reinstalls the Debian start-up packages: $pk (this restores /boot/efi/EFI/debian or the old BIOS start-up code)."; then
    if [ "$RP_DRY" = 1 ] || online_ok; then
      # shellcheck disable=SC2086
      rp_run_t apt-get -y install --reinstall $pk
    else echo "No internet connection: skipped. Connect (cable or phone tethering) and run this step again."; fi
  fi
  if rp_step "3. Rebuild the boot menu" "Runs update-grub, which writes /boot/grub/grub.cfg from the kernels that are installed."; then
    rp_run_t update-grub
  fi
  if rp_step "4. Rebuild the start-up images (initramfs) of every kernel" "Runs update-initramfs -u -k all. This takes a minute or two and fixes 'unable to mount root' / 'cryptsetup: waiting for device' after a failed update. (Needs /etc/crypttab to be right: step 1.)"; then
    rp_run_t update-initramfs -u -k all
  fi
  if [ "$efi" = uefi ]; then
    esp=$(rp_find_esp)
    if [ -z "$esp" ]; then echo; echo "No EFI system partition was found, so the firmware entry can't be created. (Is this a very old BIOS-only computer, or was the drive re-partitioned?)"
    else
      espdisk=$(rp_parent_disk "$esp"); espnum=$(cat "/sys/class/block/${esp##*/}/partition" 2>/dev/null)
      if have efibootmgr && efibootmgr 2>/dev/null | grep -qi 'debian'; then echo; echo "The firmware already has a Debian start-up entry: no change needed."
      elif rp_step "5. Add Debian to the firmware's start-up list" "Runs grub-install, which writes the loader to the EFI partition ($esp, disk $espdisk, partition ${espnum:-?}) and creates the entry 'debian'."; then
        if [ "$(cat /sys/firmware/efi/fw_platform_size 2>/dev/null)" = 32 ]; then rp_run_t grub-install --target=i386-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck
        else rp_run_t grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck; fi
      fi
    fi
  else
    bdisk=$(rp_parent_disk "${RP_ROOTDEV:-/dev/sda1}")
    case "$bdisk" in /dev/mapper/*|/dev/dm-*) bdisk=$(lsblk -no PKNAME -s "${RP_ROOTDEV:-/dev/sda1}" 2>/dev/null | tail -n1); [ -n "$bdisk" ] && bdisk=/dev/$bdisk ;; esac
    if rp_step "5. Write GRUB to the start of the drive (old BIOS computers)" "Runs grub-install on ${bdisk:-the drive that holds /boot}."; then rp_run_t grub-install "${bdisk:-/dev/sda}"; fi
  fi
  echo; echo "Done with the steps you chose. Restart the computer and take the USB stick out. If it still doesn't start, run"
  echo "'Find out what is wrong' again or 'Check and repair a disk' (the file system itself may be damaged)."
  return 0
}

# ---------------------------------------------------------------- older kernel
act_kernel() {
  local T cur k n=0 choice i g
  echo; echo "=== Start with an older kernel ==="
  echo "If the newest update made the computer unstable, you can start with the previous kernel."
  echo "Quick way (no tools needed): restart, hold Shift (BIOS) or tap Esc (UEFI) at start-up, choose 'Advanced options for Debian GNU/Linux'"
  echo "and pick an older kernel in the GRUB menu."
  rp_target_ensure rw || return 1
  T=$(rp_t)
  declare -a KV=()
  for k in $(ls -1 "$T"/boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V -r); do n=$((n + 1)); KV[n]=$k; done
  if [ "$n" -eq 0 ] && [ "$RP_DRY" != 1 ]; then echo "No kernels found in $T/boot."; return 1; fi
  [ "$RP_DRY" = 1 ] && [ "$n" -eq 0 ] && { KV[1]="6.12.41-amd64"; KV[2]="6.12.38-amd64"; n=2; }
  cur=$(sed -n 's/^GRUB_DEFAULT=//p' "$T/etc/default/grub" 2>/dev/null | head -n1 | tr -d '"')
  echo; echo "Kernels installed (newest first):"
  for ((i = 1; i <= n; i++)); do printf '  %d) %s\n' "$i" "${KV[i]}"; done
  [ -n "$cur" ] && echo "(Boot menu default now: $cur)"
  if [ "$n" -lt 2 ]; then echo "Only one kernel is installed, so there is nothing older to go back to."
    if rp_step "Reinstall the kernel instead" "Runs: apt-get install --reinstall on the installed kernel package (needs internet), then rebuilds the start-up images."; then
      rp_run_t apt-get -y install --reinstall "linux-image-${KV[1]}"; rp_run_t update-initramfs -u -k all; rp_run_t update-grub
    fi
    return 0
  fi
  if [ "$RP_DRY" = 1 ]; then choice=2; else slh_read choice "Which one should start by default? (number, Enter = cancel) " || return 1; fi
  [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$n" ] || { echo "Cancelled. Nothing was changed."; return 0; }
  k=${KV[choice]}
  g="Advanced options for Debian GNU/Linux>Debian GNU/Linux, with Linux $k"
  if rp_step "Start with kernel $k by default" "Sets GRUB_DEFAULT=saved in /etc/default/grub (a copy is kept as grub.secure-linux-bak), runs update-grub and grub-set-default \"$g\". You can go back with: grub-set-default 0 . Nothing is deleted."; then
    if [ "$RP_DRY" = 1 ]; then echo "  [dry run] would edit $T/etc/default/grub"
    else
      cp -n "$T/etc/default/grub" "$T/etc/default/grub.secure-linux-bak" 2>/dev/null
      if grep -q '^GRUB_DEFAULT=' "$T/etc/default/grub"; then sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' "$T/etc/default/grub"; else echo 'GRUB_DEFAULT=saved' >> "$T/etc/default/grub"; fi
    fi
    rp_run_t update-grub
    rp_run_t grub-set-default "$g"
  fi
  if [ ! -e "$T/boot/initrd.img-$k" ] && [ "$RP_DRY" != 1 ] && rp_step "Rebuild the start-up image for $k" "That kernel has no initramfs, so it could not start. Runs: update-initramfs -c -k $k."; then
    rp_run_t update-initramfs -c -k "$k"
  fi
  echo; echo "If you want to REMOVE the bad kernel later (after the older one works): sudo apt remove linux-image-<version>"
  return 0
}

# ---------------------------------------------------------------- black / garbled screen
act_gpu() {
  local T gpu="" u g
  echo; echo "=== Black or garbled screen: safe graphics ==="
  echo "Quick fix right now (no tools): restart. When the GRUB menu appears, press e, find the line starting with  linux,"
  echo "add the word  nomodeset  at the end, and press Ctrl+X. That starts with basic graphics so you can get in."
  echo "Text console on a running system: press Ctrl+Alt+F3 and log in."
  rp_target_ensure rw || return 1
  T=$(rp_t)
  have lspci && gpu=$(lspci -nn 2>/dev/null | grep -iE 'vga|3d|display' | head -n 3)
  [ -n "$gpu" ] && { echo; echo "Graphics hardware here:"; printf '%s\n' "$gpu" | sed 's/^/  /'; }
  if printf '%s' "$gpu" | grep -qi nvidia; then
    echo; echo "NVIDIA card: the usual causes are (1) the driver is waiting for the Secure Boot key (run secure-linux-drivers enroll-key,"
    echo "restart, approve the key), (2) a new kernel without a built driver yet (run: sudo dpkg-reconfigure nvidia-kernel-dkms)."
  fi
  g="$T/etc/default/grub"
  if rp_step "1. Basic graphics for every start (safe mode)" "Adds nomodeset to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub (a copy is kept as grub.secure-linux-bak) and runs update-grub. Screen works at low speed everywhere; undo by removing the word again."; then
    if [ "$RP_DRY" = 1 ]; then echo "  [dry run] would add nomodeset to $g"
    else
      cp -n "$g" "$g.secure-linux-bak" 2>/dev/null
      grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=.*nomodeset' "$g" || sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 nomodeset"/' "$g"
    fi
    rp_run_t update-grub
  fi
  if printf '%s' "$gpu" | grep -qi nvidia && rp_step "2. Go back to the open-source NVIDIA driver (nouveau)" "Removes the NVIDIA packages (nvidia-driver and friends; your files are not touched), tells Secure Linux to keep nouveau (secure-linux-choice set nvidia_driver nouveau) and rebuilds the start-up images. Reinstall later with: sudo secure-linux-drivers nvidia."; then
    rp_run_t apt-get -y purge 'nvidia-*' 'libnvidia-*' 'xserver-xorg-video-nvidia*'
    if [ "$T" = / ] && have secure-linux-choice; then rp_run secure-linux-choice set nvidia_driver nouveau; fi
    rp_run_t update-initramfs -u -k all
  fi
  if [ "$T" = / ] || [ -d "$T/home" ]; then
    for u in $(ls -1 "$T/home" 2>/dev/null | head -n 5); do
      if [ -e "$T/home/$u/.config/xfce4/xfconf/xfce-perchannel-xml/displays.xml" ] && rp_step "3. Forget the saved screen layout of $u" "Renames ~/.config/xfce4/xfconf/xfce-perchannel-xml/displays.xml (Xfce's saved resolution and monitor layout) to .bak. A wrong saved layout can give a black screen."; then
        rp_run mv "$T/home/$u/.config/xfce4/xfconf/xfce-perchannel-xml/displays.xml" "$T/home/$u/.config/xfce4/xfconf/xfce-perchannel-xml/displays.xml.bak"
      fi
    done
  fi
  echo; echo "Restart to test. Still wrong? Try 'Start with an older kernel', and run the hardware check (graphics lines)."
  return 0
}

# ---------------------------------------------------------------- snapshots (LVM snapshots made before updates)
act_snapshot() {
  local T choice list
  echo; echo "=== Go back to an earlier snapshot ==="
  echo "Secure Linux takes a snapshot (a frozen copy of the system part of the disk) before updates. Going back undoes a bad update."
  echo "Your documents in /home are not part of a system snapshot and are not changed."
  rp_target_ensure rw || return 1
  T=$(rp_t)
  if ! command -v lvs >/dev/null 2>&1; then echo "The disk-pool tools (lvm2) are not available here, so snapshots can't be listed."; return 1; fi
  if [ "$T" = / ] && command -v secure-linux-snapshot >/dev/null 2>&1; then
    rp_run secure-linux-snapshot list
    if [ "$RP_DRY" = 1 ]; then echo "  [dry run] would run: secure-linux-snapshot rollback   (asks which snapshot, then a typed confirmation)"; return 0; fi
    rp_step "Go back to a snapshot" "Runs: secure-linux-snapshot rollback . It shows the snapshots, asks which one, and needs you to type ROLL BACK. The change happens at the next restart; a safety copy is kept." || return 0
    secure-linux-snapshot rollback
    return 0
  fi
  # from a rescue system: the volumes are open here, so use the LVM tools directly
  list=$(rp_run lvs --noheadings -o vg_name,lv_name,lv_size,origin,snap_percent -S 'lv_name=~^sl-snap-' 2>&1)
  printf '%s\n' "$list"
  if [ "$RP_DRY" = 1 ]; then choice="vg/sl-snap-EXAMPLE"; else
    printf '%s' "$list" | grep -q sl-snap- || { echo "There are no snapshots to go back to."; return 0; }
    slh_read choice "Type the snapshot as vgname/sl-snap-NAME (Enter = cancel): " || return 1
  fi
  [ -n "$choice" ] || { echo "Cancelled. Nothing was changed."; return 0; }
  case "$choice" in */sl-snap-*) ;; *) echo "That is not one of the Secure Linux snapshots. Nothing was changed."; return 0 ;; esac
  rp_backup "snapshot rollback"
  if rp_typed "ROLL BACK" "This puts the system part of the disk back to how it was at the snapshot ($choice). Files you saved in /home stay. Anything installed or changed in the system since then is undone."; then
    rp_run mkdir -p "$T/boot"
    rp_run sh -c "echo '$choice' > '$T/boot/secure-linux-rollback-pending'"
    rp_run lvconvert --merge "$choice"
    echo "The change happens when the computer restarts (the first start after it takes a little longer, and one more restart finishes the job)."
  fi
  return 0
}

# ---------------------------------------------------------------- software (dpkg, apt, flatpak)
act_packages() {
  local T last pk
  echo; echo "=== Repair software ==="
  echo "Fixes a stopped or half-finished update, broken downloads and damaged program files."
  rp_target_ensure rw || return 1
  T=$(rp_t)
  if [ -e "$T/var/lib/dpkg/lock-frontend" ] && command -v fuser >/dev/null 2>&1 && fuser "$T/var/lib/dpkg/lock-frontend" >/dev/null 2>&1; then
    echo "Another program is installing software right now (the automatic updates). Wait a few minutes and run this again."; return 0
  fi
  rp_step "1. Finish a stopped installation" "Runs: dpkg --configure -a . Finishes packages that were unpacked but not set up (the usual result of a power cut during an update)." && rp_run_t dpkg --configure -a
  rp_step "2. Fix broken dependencies" "Runs: apt-get -f install . Installs or removes only what is needed to make the installed packages agree with each other. Needs internet if something has to be downloaded." && rp_run_t apt-get -y -f install
  rp_step "3. Throw away downloaded package lists and start fresh" "Runs: apt-get clean, removes the package lists, then apt-get update. Needs internet. Fixes 'Hash Sum mismatch' / 'GPG error' / 'file has unexpected size' errors." && { rp_run_t apt-get clean; rp_run_t sh -c 'rm -rf /var/lib/apt/lists/*'; rp_run_t apt-get update; }
  rp_step "4. Look for broken dependencies (only looks)" "Runs: apt-get check - only reports (changes nothing)." && rp_run_t apt-get check
  if rp_step "5. Finish updating" "Runs: apt-get full-upgrade . First a preview (nothing is installed), then you decide. It never removes your files in /home."; then
    rp_run_t apt-get -s full-upgrade
    if [ "$RP_DRY" = 1 ] || slh_confirm "Apply that for real?"; then rp_run_t apt-get -y full-upgrade; fi
  fi
  if rp_step "6. Undo the last software installation" "Looks in /var/log/apt/history.log for the last thing that was INSTALLED and offers to remove exactly those packages (shown first, then asks again). Use it only if that install caused the trouble."; then
    last=$(awk '/^Start-Date/ { blk = "" } /^Install:/ { blk = $0 } END { print blk }' "$T/var/log/apt/history.log" 2>/dev/null)
    pk=$(printf '%s' "$last" | sed 's/^Install: //; s/ ([^)]*)//g; s/, / /g')
    if [ -z "$pk" ]; then echo "No earlier installation was found in the log."
    else
      echo "The last installation added: $pk"
      if [ "$RP_DRY" = 1 ] || slh_confirm "Remove these packages?"; then
        # shellcheck disable=SC2086
        rp_run_t apt-get -y remove $pk
      fi
    fi
  fi
  if rp_step "7. Check program files for damage (only looks)" "Runs: dpkg --verify - lists files that differ from what their package shipped (settings you changed show as 'c' and are normal)." ; then
    rp_run_t dpkg --verify
    echo "To put back a damaged program: sudo apt install --reinstall PACKAGE   (find the package with: dpkg -S /path/to/file)."
  fi
  if rp_step "8. Repair Flatpak apps" "Runs: flatpak repair --system  (and --user for your own apps). Needs internet if files are missing. Only on 64-bit computers." ; then
    if command -v flatpak >/dev/null 2>&1; then rp_run_t flatpak repair --system; [ "$T" = / ] && rp_run flatpak repair --user
    else echo "Flatpak isn't installed on this computer (32-bit computers have none)."; fi
  fi
  return 0
}

# ---------------------------------------------------------------- network
act_network() {
  local env con fw
  env=$(rp_env)
  echo; echo "=== Fix Wi-Fi / internet ==="
  fw=$(dpkg-query -W -f='${Package}\n' 'firmware-*' 2>/dev/null | tr '\n' ' ')
  if [ "$env" != installed ]; then
    echo "You are in a rescue system. The network of the INSTALLED computer can only be repaired once it starts."
    echo "From here you can reinstall the Wi-Fi firmware inside the installed system (needs a working connection in this rescue system:"
    echo "plug in a cable, or use  nmtui  to join Wi-Fi)."
    rp_target_ensure rw || return 1
    # shellcheck disable=SC2086
    rp_step "Reinstall the Wi-Fi firmware" "Runs inside the installed system: apt-get install --reinstall ${fw:-firmware-linux-free firmware-misc-nonfree}" && rp_run_t apt-get -y install --reinstall ${fw:-firmware-linux-free firmware-misc-nonfree}
    return 0
  fi
  echo "What I can see:"; have nmcli && rp_run nmcli -t general status; have rfkill && rp_run rfkill list
  rp_step "1. Switch Wi-Fi and Bluetooth on (airplane mode)" "Runs: rfkill unblock all . A hardware switch or the airplane-mode key must also be on." && rp_run rfkill unblock all
  rp_step "2. Restart the network service" "Runs: systemctl restart NetworkManager . The connection drops for a few seconds." && rp_run systemctl restart NetworkManager
  if rp_step "3. Clear the name-lookup cache (DNS)" "Runs: resolvectl flush-caches and restarts systemd-resolved. Fixes 'connected but no websites open'."; then
    rp_run resolvectl flush-caches; rp_run systemctl restart systemd-resolved
  fi
  if rp_step "4. Reinstall the Wi-Fi/network firmware and drivers" "Runs: apt-get install --reinstall ${fw:-firmware-linux-free firmware-misc-nonfree} (needs internet: use a cable or phone USB tethering), then secure-linux-drivers install. Restart afterwards."; then
    # shellcheck disable=SC2086
    rp_run apt-get -y install --reinstall ${fw:-firmware-linux-free firmware-misc-nonfree}
    have secure-linux-drivers && rp_run secure-linux-drivers install
  fi
  if have nmcli && rp_step "5. Forget ONE saved network and join it again" "Shows your saved networks; you pick one; it is deleted (the Wi-Fi password is forgotten, you type it again)."; then
    if [ "$RP_DRY" != 1 ]; then nmcli -t -f NAME,TYPE connection show | sed 's/^/   /'; fi
    rp_ask con "Name of the network to forget (Enter = skip): " "ExampleNetwork" || true
    [ -n "$con" ] && rp_run nmcli connection delete "$con"
  fi
  if rp_typed "FORGET ALL NETWORKS" "LAST RESORT: removes ALL saved network settings (Wi-Fi passwords, VPNs). Backups are kept in /root/secure-linux-network-backup."; then
    rp_run mkdir -p /root/secure-linux-network-backup
    rp_run cp -a /etc/NetworkManager/system-connections/. /root/secure-linux-network-backup/
    rp_run find /etc/NetworkManager/system-connections -type f -name '*.nmconnection' -delete
    rp_run systemctl restart NetworkManager
  fi
  echo; echo "Test:"; rp_run ping -c1 -W3 1.1.1.1; rp_run getent hosts deb.debian.org
  return 0
}

# ---------------------------------------------------------------- Windows on the same computer
act_windows() {
  local choice dev fs size label mp g esp disk num
  echo; echo "=== Windows on this computer ==="
  echo "  1) Find Windows and show its state"
  echo "  2) Put Windows back in the Debian start-up menu (os-prober)"
  echo "  3) Put 'Windows Boot Manager' back in the firmware's start-up list"
  echo "  4) Forgotten LOCAL Windows password (your own computer only)"
  echo "  5) Windows itself won't start: what to do (Windows repair guidance)"
  rp_ask choice "Choose 1-5 (Enter = cancel): " 1 || return 0
  case "$choice" in
    1)
      if [ -z "$(rp_ntfs_partitions)" ]; then echo "No Windows (NTFS) or BitLocker partitions were found."; return 0; fi
      while IFS='|' read -r dev fs size label; do
        echo; echo "$dev  ($fs, $size${label:+, $label})"
        if [ "$fs" = BitLocker ]; then echo "   Protected by BitLocker: Secure Linux does not touch it without the 48-digit recovery key (from account.microsoft.com/devices/recoverykey, or your IT admin)."; continue; fi
        mp=/mnt/sl-win-probe
        if [ "$RP_DRY" = 1 ]; then echo "  [dry run] would run: mount -t ntfs3 -o ro $dev $mp"; continue; fi
        mkdir -p "$mp"
        if mount -t ntfs3 -o ro "$dev" "$mp" 2>/dev/null || ntfs-3g -o ro "$dev" "$mp" 2>/dev/null; then
          if [ -d "$mp/Windows/System32" ]; then echo "   Windows system folder found."
            [ -e "$mp/hiberfil.sys" ] && echo "   Note: Windows is hibernated or uses Fast Startup. Start Windows and shut down fully (hold Shift while clicking Shut down) before changing anything from Linux."
          else echo "   Data partition (no Windows system folder)."; fi
          umount "$mp" 2>/dev/null
        else echo "   Could not open it read-only (damaged, or Windows left it locked). Windows' own check (chkdsk /f) can fix that."; fi
      done < <(rp_ntfs_partitions) ;;
    2)
      rp_target_ensure rw || return 1
      rp_backup "adding Windows to the start-up menu"
      rp_step "1. Install the detector" "Runs: apt-get install os-prober (needs internet if it is not there yet)." && rp_run_t apt-get -y install os-prober
      g="$(rp_t)/etc/default/grub"
      if rp_step "2. Switch the detector on in the boot menu settings" "Sets GRUB_DISABLE_OS_PROBER=false in /etc/default/grub (a copy is saved as grub.secure-linux-bak). Newer GRUB versions switch it off by default."; then
        if [ "$RP_DRY" = 1 ]; then echo "  [dry run] would edit $g"
        else
          cp -n "$g" "$g.secure-linux-bak" 2>/dev/null
          if grep -q '^#\?GRUB_DISABLE_OS_PROBER' "$g"; then sed -i 's/^#\?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' "$g"; else echo 'GRUB_DISABLE_OS_PROBER=false' >> "$g"; fi
        fi
      fi
      rp_step "3. Rebuild the boot menu" "Runs: update-grub . Look for the lines 'Found Windows Boot Manager'." && rp_run_t update-grub
      echo "With Secure Boot on, Windows still starts from the GRUB menu in most cases. If it doesn't, use the firmware boot menu (F12/Esc) and choose Windows Boot Manager." ;;
    3)
      rp_target_ensure rw || return 1
      have efibootmgr || { echo "efibootmgr is not available here."; return 1; }
      if efibootmgr 2>/dev/null | grep -qi 'windows boot manager'; then echo "The firmware already lists Windows Boot Manager."; return 0; fi
      esp=$(rp_find_esp); [ -n "$esp" ] || { echo "No EFI system partition found."; return 1; }
      disk=$(rp_parent_disk "$esp"); num=$(cat "/sys/class/block/${esp##*/}/partition" 2>/dev/null)
      if rp_step "Add 'Windows Boot Manager'" "Creates the entry for $esp (disk $disk, partition ${num:-?}) pointing at \EFI\Microsoft\Boot\bootmgfw.efi - only works if that file really exists there."; then
        rp_run efibootmgr -c -d "$disk" -p "${num:-1}" -L "Windows Boot Manager" -l '\EFI\Microsoft\Boot\bootmgfw.efi'
      fi ;;
    4) win_password_reset ;;
    5)
      cat <<'EOT'

  Windows won't start. Linux cannot repair Windows' own start-up files, but Windows can, from a Windows install USB:
    1. On a working Windows PC, make a Windows install USB with Microsoft's "Media Creation Tool" (microsoft.com/software-download).
    2. Start the broken PC from it (boot menu: F12 / Esc), choose your language, then "Repair your computer" (bottom left).
    3. Troubleshoot > Advanced options > "Startup Repair". If that fails, open "Command Prompt" and type, one at a time:
         bootrec /fixmbr
         bootrec /fixboot
         bootrec /scanos
         bootrec /rebuildbcd
    4. A drive with errors: in the same Command Prompt run  chkdsk C: /f
  Your files can be copied off first with the "Rescue my files" menu item here (works on Windows drives; BitLocker needs its recovery key).
EOT
      ;;
    *) echo "Cancelled." ;;
  esac
  return 0
}

# ---------------------------------------------------------------- file-system check (ext4 inside LVM inside LUKS)
if ! declare -F act_fs_shared >/dev/null; then
  eval "$(declare -f act_fs | sed '1s/act_fs/act_fs_shared/')"
fi
act_fs() {
  if [ "$(rp_env)" = installed ]; then
    echo; echo "=== Check and repair a disk or file system ==="
    echo "You are running from this computer's own drive, so its main partitions can't be repaired while they are in use."
    echo "This computer's disk is LUKS (encrypted) > LVM > ext4. To repair the main drive: restart from the Secure Linux USB stick (SystemRescue),"
    echo "run this tool again, say yes when it offers to unlock the disk, and pick the volume (named like /dev/mapper/...-root)."
    if rp_step "Ask the file system to check itself at the next start" "Runs: tune2fs -C 100 on the root volume (and sets its check count to 'now due'), so the computer checks it by itself while starting. Takes a few minutes. Nothing else changes."; then
      local rootdev; rootdev=$(findmnt -no SOURCE / 2>/dev/null)
      case "$rootdev" in /dev/*) rp_run tune2fs -c 1 "$rootdev"; rp_run tune2fs -C 100 "$rootdev" ;; *) echo "(Could not tell which volume holds the system.)" ;; esac
      echo "Restart to start the check. Afterwards undo the forced check with: sudo tune2fs -c -1 $rootdev"
    fi
    echo "(Other drives can be checked below.)"
  fi
  [ "$(rp_env)" = installed ] || rp_unlock_all     # unlock the disk and switch on its logical volumes, so they are in the list
  SL_REPAIR_ENV=other-live act_fs_shared
}

# ---------------------------------------------------------------- forgotten Linux password
act_password() {
  local u
  echo; echo "=== Forgot my Linux login password ==="
  if [ "$(rp_env)" = installed ]; then
    echo "You are logged in right now, so you can change a password without the old one if you are an administrator:"
    echo "    sudo passwd YOURNAME"
    echo "If you are locked OUT (cannot log in at all), restart from the Secure Linux USB stick, choose SystemRescue, and run this tool again."
    echo "You will need your DISK password (the one asked at power-on) or the disk recovery key. Nobody can reset THAT one."
    return 0
  fi
  rp_target_ensure rw || return 1
  rp_ask u "Account to give a new password (Enter = cancel): " "matt" || return 0
  [ -n "$u" ] || { echo "Cancelled. Nothing was changed."; return 0; }
  printf '%s' "$u" | grep -qE '^[a-z_][a-z0-9_-]{0,30}$' || { echo "That isn't a valid account name. Nothing was changed."; return 0; }
  rp_step "Set a new password for $u" "Runs: passwd $u inside the opened system. You type the new password twice (nothing shows on screen while you type). Debian has no extra labelling step to wait for." || return 0
  rp_run_t passwd "$u"
  return 0
}

# ---------------------------------------------------------------- virus scan (only the "how to get the tools" wording differs)
if ! declare -F act_malware_shared >/dev/null; then
  eval "$(declare -f act_malware | sed '1s/act_malware/act_malware_shared/')"
fi
act_malware() {
  if ! have clamscan && ! have rkhunter; then
    echo; echo "=== Scan for viruses and rootkits ==="
    echo "Neither ClamAV (clamscan) nor rkhunter is available here."
    echo "  Installed Debian: sudo apt install clamav rkhunter     SystemRescue: ClamAV is included in newer versions (VERIFY)."
    echo "  (This computer's own weekly scan is 'secure-linux-scan'; see Secure Linux Status.)"
    return 1
  fi
  act_malware_shared
}
