# shellcheck shell=bash
# hw/health/repair-boot.sh (owner: hardware) - secure-linux-repair: find the cause (--auto-diagnose), repair the boot loader,
# older kernels, graphics trouble, snapshots. Needs repair-lib.sh. Written for the Fedora btrfs layout
# (subvolumes root + home, ext4 /boot, FAT /boot/efi, GRUB with the kernel entries in /boot/loader/entries).
# VERIFY comments mark command details that could not be tried on a real Fedora 44 here.

FIND=()
find_add() { FIND+=("$1|$2|$3"); }       # SEVERITY (1 = serious, 2 = worth fixing, 3 = just so you know) | action | text
rp_action_label() {
  case "$1" in
    diagnose) echo "Find out what is wrong" ;; health) echo "Check the health of every part" ;; data) echo "Rescue my files" ;;
    boot) echo "Computer won't start: repair the boot loader" ;; fs) echo "Check and repair a disk" ;; snapshot) echo "Go back to an earlier snapshot" ;;
    kernel) echo "Start with an older kernel" ;; gpu) echo "Black or garbled screen: safe graphics" ;; packages) echo "Repair software" ;;
    network) echo "Fix Wi-Fi / internet" ;; windows) echo "Windows on this computer" ;; password) echo "Forgot my Linux login password" ;;
    malware) echo "Scan for viruses" ;; clone) echo "Back up or clone a whole drive" ;; factory) echo "Reset to factory state" ;; wipe) echo "Wipe before selling" ;;
    *) echo "$1" ;;
  esac
}

# ---------------------------------------------------------------- --auto-diagnose
act_diagnose() {
  local T efi="bios" out n line sev act txt rec="" mode=ro i
  echo; echo "=== Finding out what is wrong (this only looks; it changes nothing) ==="
  efi=$(rp_efi_mode)
  echo "Start-up mode of this computer: $efi.  Running from: $(rp_env_name "$(rp_env)")."
  [ "$(rp_env)" = installed ] && mode=ro
  if ! rp_target_ensure ro; then echo "(No Linux system could be opened, so only the hardware was checked.)"; fi
  T=$(rp_t)
  FIND=()
  # --- firmware boot entries
  if [ "$efi" = uefi ] && have efibootmgr; then
    out=$(efibootmgr 2>&1)
    if printf '%s' "$out" | grep -qi 'not supported'; then find_add 3 boot "The firmware's start-up entries can't be read from here."
    else
      printf '%s\n' "$out" | grep -qiE 'fedora|shim|grub' || find_add 1 boot "The computer's firmware has no start-up entry for Fedora, so it does not know where to start from. (Often after a BIOS reset, a new drive, or Windows overwriting the list.)"
      printf '%s\n' "$out" | sed -n 's/^BootOrder: *//p' | head -n1 | tr ',' '\n' | head -n1 | while read -r first; do
        printf '%s\n' "$out" | grep -E "^Boot$first" | grep -qi 'windows' && echo "WINFIRST"; done | grep -q WINFIRST && find_add 3 windows "The firmware starts Windows first, not Fedora. (Choose Fedora in the firmware boot menu, or fix the order in the Windows menu.)"
    fi
  elif [ "$efi" = uefi ]; then find_add 3 boot "efibootmgr is not available here, so the firmware entries were not checked."; fi
  # --- files the boot needs (only when the broken system is open)
  if [ -d "$T/boot" ] && [ "$T" != / ] || [ "$T" = / ]; then
    local vm=0 ver
    for line in "$T"/boot/vmlinuz-*; do
      [ -e "$line" ] || continue
      vm=$((vm + 1)); ver=${line##*/vmlinuz-}
      [ -e "$T/boot/initramfs-$ver.img" ] || find_add 1 kernel "Kernel $ver has no start-up image (initramfs). It cannot start."
    done
    [ "$vm" -eq 0 ] && find_add 1 kernel "No kernel files were found in /boot. Either /boot is not mounted here, or the kernel files are gone."
    [ -e "$T/boot/grub2/grub.cfg" ] || find_add 1 boot "The boot menu file (/boot/grub2/grub.cfg) is missing."
    if [ "$efi" = uefi ]; then
      [ -e "$T/boot/efi/EFI/fedora/shimx64.efi" ] || [ -e "$T/boot/efi/EFI/fedora/shim.efi" ] || find_add 1 boot "The boot loader program (shim) is missing from the EFI system partition."
    fi
  fi
  # --- fstab pointing at drives that are not there
  if [ -r "$T/etc/fstab" ]; then
    local src mp fs opts _a _b uuid
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
    printf '%s\n' "$jl" | grep -qiE 'I/O error|EXT4-fs error|BTRFS.*(error|corrupt)|XFS.*(corrupt|error)|nvme.*timeout|ata[0-9.]+.*failed command' && find_add 1 data "The last start-up logged disk errors. Rescue your files first, then check the disk."
    printf '%s\n' "$jl" | grep -qiE 'amdgpu.*(timeout|failed|ERROR)|NVRM|nouveau.*(fail|error)|i915.*(ERROR|GPU HANG)|Failed to start .*(Display Manager|sddm|gdm|lightdm)' && find_add 2 gpu "The last start-up had graphics errors (that fits a black or frozen screen)."
    printf '%s\n' "$jl" | grep -qiE 'Dependency failed for|Failed to mount|Timed out waiting for device' && find_add 1 boot "A drive could not be mounted at start-up (see 'emergency mode')."
    printf '%s\n' "$jl" | grep -qiE 'rpm.*(error|corrupt)|dnf.*(error|failed)' && find_add 2 packages "The software database logged errors."
  fi
  # --- right now
  if have dmesg && dmesg 2>/dev/null | grep -qiE 'I/O error, dev|Buffer I/O error'; then find_add 1 data "The kernel is reporting drive read/write errors right now."; fi
  if [ "$T" != / ] || true; then
    out=$(df -P "$T" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
    [ -n "$out" ] && [ "$out" -ge 97 ] 2>/dev/null && find_add 1 fs "The system drive is ${out}% full. Programs can't start or save. Free space (empty the bin, remove old downloads, delete old snapshots)."
  fi
  if have smartctl; then
    for line in $(lsblk -dpno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'); do
      [ "$(rp_smart_state "$line")" = bad ] && find_add 1 data "$(rp_disk_label "$line") says it is failing (SMART). Rescue files first."
    done
  fi
  if [ "$T" = / ]; then
    if have nmcli && [ "$(nmcli -t -f STATE general 2>/dev/null)" != connected ]; then find_add 2 network "The computer is not connected to the internet."; fi
    have rfkill && rfkill list 2>/dev/null | grep -q 'blocked: yes' && find_add 2 network "Wi-Fi or Bluetooth is switched off (airplane mode)."
    have rpm && ! rpm -q rpm >/dev/null 2>&1 && find_add 1 packages "The software database (rpm) can't be read."
    if have mokutil && mokutil --sb-state 2>/dev/null | grep -qi enabled && [ -f /etc/pki/akmods/certs/public_key.der ] && ! mokutil --test-key /etc/pki/akmods/certs/public_key.der 2>&1 | grep -qi 'already enrolled'; then
      find_add 2 gpu "Secure Boot is blocking the graphics driver because its key was never approved. Run: sudo secure-linux-drivers enroll-key, restart, and approve it on the blue screen."
    fi
  elif [ -r "$T/var/lib/rpm/rpmdb.sqlite" ] && have rpm && ! rpm --root="$T" -q rpm >/dev/null 2>&1; then find_add 1 packages "The software database (rpm) of the broken system can't be read."; fi
  [ -e "$T/.autorelabel" ] && find_add 3 password "A security-label rebuild is pending; the next start takes a few extra minutes (normal after a password reset)."
  # --- Windows next door?
  if lsblk -rno FSTYPE 2>/dev/null | grep -qiE '^ntfs$|^BitLocker$'; then find_add 3 windows "Windows (NTFS) partitions are on this computer's drives."; fi
  # --- report
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
  # a failing drive always comes before any repair
  if printf '%s\n' "${FIND[@]}" | grep -q '^1|data|'; then
    echo "RECOMMENDED NEXT STEP: rescue your files first ($(rp_action_label data)), THEN repair. Repairs write to the drive."
    RP_REC=data
  else
    echo "RECOMMENDED NEXT STEP: $(rp_action_label "$rec")   (secure-linux-repair --action $rec)"
  fi
  return 0
}

# ---------------------------------------------------------------- fstab (a drive that is not there stops the start-up)
rp_fix_fstab() {
  local T f bak src mp fs opts a b uuid n=0 cand proposal="" lineno=0 changed=0 tmp
  T=$(rp_t); f="$T/etc/fstab"
  [ -r "$f" ] || { echo "No /etc/fstab found in the system being repaired."; return 0; }
  tmp=$(mktemp); cp "$f" "$tmp"
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    case "$line" in ''|'#'*) continue ;; esac
    read -r src mp fs opts a b <<< "$line"
    case "$src" in UUID=*) uuid=${src#UUID=} ;; *) continue ;; esac
    [ "$fs" = swap ] && continue
    case ",$opts," in *,noauto,*|*,nofail,*) continue ;; esac
    [ -e "/dev/disk/by-uuid/$uuid" ] || [ -n "$(blkid -U "$uuid" 2>/dev/null)" ] && continue
    n=$((n + 1))
    echo; echo "fstab line $lineno: $mp ($fs) refers to UUID $uuid, which does not exist on this computer."
    if [ "$mp" = / ]; then
      echo "  This is the main system partition. Do NOT guess: the boot loader's configuration (next steps) usually fixes this."
      continue
    fi
    cand=$(rp_lsblk NAME,FSTYPE,UUID | awk -F'|' -v t="$fs" '$2==t && $3!="" {print $3}' | while read -r u; do grep -q "UUID=$u" "$f" || echo "$u"; done | head -n 2)
    if [ "$(printf '%s\n' "$cand" | grep -c .)" -eq 1 ]; then
      echo "  A $fs partition that is not used in fstab exists with UUID $cand."
      if rp_step "Point $mp at that partition" "Replace UUID=$uuid by UUID=$cand on line $lineno."; then
        sed -i "${lineno}s/UUID=$uuid/UUID=$cand/" "$tmp"; changed=1
      fi
    else
      if rp_step "Let the computer start without $mp" "Add the options  nofail,x-systemd.device-timeout=5s  to line $lineno, so a missing drive no longer stops the start-up (the folder just stays empty)."; then
        sed -i "${lineno}s/$opts/$opts,nofail,x-systemd.device-timeout=5s/" "$tmp"; changed=1
      fi
    fi
  done < "$f"
  [ "$n" -eq 0 ] && { echo "fstab is fine: every drive it lists exists."; rm -f "$tmp"; return 0; }
  if [ "$changed" = 1 ]; then
    bak="$f.secure-linux-bak-$(date +%Y%m%d-%H%M%S)"
    echo; echo "New fstab (differences):"; diff "$f" "$tmp" | sed 's/^/    /'
    if [ "$RP_DRY" = 1 ]; then printf '  [dry run] would run: cp %s %s\n  [dry run] would run: install -m 644 <new fstab> %s\n' "$f" "$bak" "$f"
    else cp "$f" "$bak" && install -m 644 "$tmp" "$f" && echo "Saved. The old file is kept as ${bak#"${T%/}"}."; fi
  fi
  rm -f "$tmp"; return 0
}

# ---------------------------------------------------------------- boot repair
rp_find_esp() {   # prints the EFI system partition device
  local dev
  dev=$(rp_lsblk NAME,PARTTYPE | awk -F'|' 'tolower($2)=="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"{print $1; exit}')
  [ -n "$dev" ] || dev=$(rp_lsblk NAME,FSTYPE,PARTFLAGS | awk -F'|' '$2=="vfat" && $3 ~ /boot|esp/ {print $1; exit}')
  printf '%s' "$dev"
}
act_boot() {
  local T efi=bios esp espdisk espnum
  echo; echo "=== Computer won't start: repair the boot loader ==="
  echo "This reinstalls the start-up program (GRUB), rebuilds the boot menu and boot images, and fixes the list of drives."
  echo "Every step shows what it does and waits for your yes. A safety copy of the boot files is made first."
  efi=$(rp_efi_mode)
  rp_target_ensure rw || return 1
  T=$(rp_t)
  rp_backup "boot repair"
  # 1. drive list
  rp_step "1. Check the list of drives (fstab)" "Looks for entries that point at drives that are not there, the usual cause of 'emergency mode'." && rp_fix_fstab
  # 2. packages
  if [ "$efi" = uefi ]; then
    if rp_step "2. Put the boot loader files back (needs internet)" "Reinstalls the Fedora start-up packages: shim-x64 grub2-efi-x64 grub2-efi-x64-modules grub2-common grub2-tools (this restores /boot/efi/EFI/fedora)."; then
      if [ "$RP_DRY" = 1 ] || online_ok; then rp_run_t dnf -y reinstall shim-x64 grub2-efi-x64 grub2-efi-x64-modules grub2-common grub2-tools
      else echo "No internet connection: skipped. Connect (cable or phone tethering) and run this step again."; fi
    fi
  fi
  # 3. grub.cfg
  if rp_step "3. Rebuild the boot menu" "Runs grub2-mkconfig to write /boot/grub2/grub.cfg from the kernels that are installed. (Fedora uses this one file for both UEFI and old BIOS. VERIFY on Fedora 44.)"; then
    rp_run_t grub2-mkconfig -o /boot/grub2/grub.cfg
  fi
  # 4. initramfs
  if rp_step "4. Rebuild the start-up images (initramfs) of every kernel" "Runs dracut --force --regenerate-all. This takes a minute or two and fixes 'unable to mount root' after a failed update."; then
    rp_run_t dracut --force --regenerate-all
  fi
  # 5. firmware entry / BIOS install
  if [ "$efi" = uefi ]; then
    esp=$(rp_find_esp)
    if [ -z "$esp" ]; then echo; echo "No EFI system partition was found, so the firmware entry can't be created. (Is this a very old BIOS-only computer, or was the drive re-partitioned?)"
    else
      espdisk=$(rp_parent_disk "$esp"); espnum=$(cat "/sys/class/block/${esp##*/}/partition" 2>/dev/null)
      if have efibootmgr && efibootmgr 2>/dev/null | grep -qi 'fedora'; then echo; echo "The firmware already has a Fedora start-up entry: no change needed."
      elif rp_step "5. Add Fedora to the firmware's start-up list" "Creates the entry 'Fedora' for $esp (disk $espdisk, partition ${espnum:-?}) pointing at \\EFI\\fedora\\shimx64.efi (the Secure Boot-signed loader)."; then
        rp_run_t efibootmgr -c -d "$espdisk" -p "${espnum:-1}" -L "Fedora" -l '\EFI\fedora\shimx64.efi'
      fi
    fi
  else
    local bdisk; bdisk=$(rp_parent_disk "${RP_ROOTDEV:-/dev/sda1}")
    if rp_step "5. Write GRUB to the start of the drive (old BIOS computers)" "Runs grub2-install on $bdisk."; then rp_run_t grub2-install "$bdisk"; fi
  fi
  echo; echo "Done with the steps you chose. Restart the computer and take the USB stick out. If it still doesn't start, run"
  echo "'Find out what is wrong' again or 'Check and repair a disk' (the file system itself may be damaged)."
  return 0
}
online_ok() {
  case "${SL_PARTS_ONLINE:-}" in yes) return 0 ;; no) return 1 ;; esac
  curl -fsS --max-time 8 -o /dev/null https://mirrors.fedoraproject.org/ 2>/dev/null || ping -c1 -W3 1.1.1.1 >/dev/null 2>&1
}

# ---------------------------------------------------------------- older kernel
act_kernel() {
  local T cur list k n=0 choice i
  echo; echo "=== Start with an older kernel ==="
  echo "If the newest update made the computer unstable, you can start with the previous kernel."
  echo "Quick way (no tools needed): restart, hold Shift (BIOS) or tap Esc (UEFI) at start-up, choose 'Advanced options'"
  echo "and pick an older kernel in the GRUB menu."
  rp_target_ensure rw || return 1
  T=$(rp_t)
  declare -a KV=()
  for k in $(ls -1 "$T"/boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V -r); do case "$k" in *rescue*) ;; *) n=$((n + 1)); KV[n]=$k ;; esac; done
  if [ "$n" -eq 0 ] && [ "$RP_DRY" != 1 ]; then echo "No kernels found in $T/boot."; return 1; fi
  [ "$RP_DRY" = 1 ] && [ "$n" -eq 0 ] && { KV[1]="6.17.4-300.fc44.x86_64"; KV[2]="6.17.2-300.fc44.x86_64"; n=2; }
  cur=$(grubby --default-kernel 2>/dev/null | sed 's|.*/vmlinuz-||')
  echo; echo "Kernels installed (newest first):"
  for ((i = 1; i <= n; i++)); do printf '  %d) %s%s\n' "$i" "${KV[i]}" "$( [ "${KV[i]}" = "$cur" ] && echo '   <- starts by default' )"; done
  if [ "$n" -lt 2 ]; then echo "Only one kernel is installed, so there is nothing older to go back to."
    if rp_step "Reinstall the kernel instead" "Runs: dnf reinstall kernel-core kernel-modules (needs internet), then rebuilds the start-up images."; then
      rp_run_t dnf -y reinstall kernel-core kernel-modules kernel; rp_run_t dracut --force --regenerate-all
    fi
    return 0
  fi
  if [ "$RP_DRY" = 1 ]; then choice=2; else slh_read choice "Which one should start by default? (number, Enter = cancel) " || return 1; fi
  [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$n" ] || { echo "Cancelled. Nothing was changed."; return 0; }
  k=${KV[choice]}
  if rp_step "Start with kernel $k by default" "Runs: grubby --set-default /boot/vmlinuz-$k. You can change it back the same way. Nothing is deleted."; then
    rp_run_t grubby --set-default "/boot/vmlinuz-$k"
  fi
  if [ ! -e "$T/boot/initramfs-$k.img" ] && [ "$RP_DRY" != 1 ] && rp_step "Rebuild the start-up image for $k" "That kernel has no initramfs, so it could not start. Runs: dracut --force /boot/initramfs-$k.img $k."; then
    rp_run_t dracut --force "/boot/initramfs-$k.img" "$k"
  fi
  echo; echo "If you want to REMOVE the bad kernel later (after the older one works): sudo dnf remove kernel-core-<version>"
  return 0
}

# ---------------------------------------------------------------- black / garbled screen
act_gpu() {
  local T
  echo; echo "=== Black or garbled screen: safe graphics ==="
  echo "Quick fix right now (no tools): restart. When the GRUB menu appears, press e, find the line starting with  linux,"
  echo "add the word  nomodeset  at the end, and press Ctrl+X. That starts with basic graphics so you can get in."
  echo "Text console on a running system: press Ctrl+Alt+F3 and log in."
  rp_target_ensure rw || return 1
  T=$(rp_t)
  local gpu=""; have lspci && gpu=$(lspci -nn 2>/dev/null | grep -iE 'vga|3d|display' | head -n 3)
  [ -n "$gpu" ] && { echo; echo "Graphics hardware here:"; printf '%s\n' "$gpu" | sed 's/^/  /'; }
  if printf '%s' "$gpu" | grep -qi nvidia; then
    echo; echo "NVIDIA card: the usual causes are (1) the driver is waiting for the Secure Boot key (run secure-linux-drivers enroll-key,"
    echo "restart, approve the key), (2) a new kernel without a built driver yet (run secure-linux-drivers reinstall)."
  fi
  if rp_step "1. Basic graphics for every start (safe mode)" "Runs: grubby --update-kernel=ALL --args=nomodeset. Screen works at low speed everywhere; undo later with: grubby --update-kernel=ALL --remove-args=nomodeset."; then
    rp_run_t grubby --update-kernel=ALL --args=nomodeset
  fi
  if printf '%s' "$gpu" | grep -qi nvidia && rp_step "2. Go back to the open-source NVIDIA driver (nouveau)" "Removes NVIDIA's blacklisting of nouveau from the boot options and tells Secure Linux to keep nouveau: grubby --remove-args, secure-linux-choice set nvidia_driver nouveau. The NVIDIA packages stay installed (remove them with step 3 if you want)."; then
    rp_run_t grubby --update-kernel=ALL --remove-args="rd.driver.blacklist=nouveau modprobe.blacklist=nouveau nvidia-drm.modeset=1"
    if [ -x "$T/usr/local/bin/secure-linux-choice" ] || [ "$T" = / ] && have secure-linux-choice; then rp_run_t secure-linux-choice set nvidia_driver nouveau; fi
    rp_run_t dracut --force --regenerate-all
  fi
  if printf '%s' "$gpu" | grep -qi nvidia && rp_step "3. Remove the NVIDIA driver packages (needs no internet)" "Runs: dnf remove akmod-nvidia xorg-x11-drv-nvidia (and the 580xx variants). Your files are not touched. Reinstall later with: sudo secure-linux-drivers install."; then
    rp_run_t dnf -y remove 'akmod-nvidia*' 'xorg-x11-drv-nvidia*' 'kmod-nvidia*'
    rp_run_t dracut --force --regenerate-all
  fi
  if [ "$T" = / ] || [ -d "$T/home" ]; then
    local u
    for u in $(ls -1 "$T/home" 2>/dev/null | head -n 5); do
      if [ -e "$T/home/$u/.config/kwinoutputconfig.json" ] && rp_step "4. Forget the saved screen layout of $u" "Renames ~/.config/kwinoutputconfig.json (KDE's saved resolution and monitor layout) to .bak. A wrong saved layout can give a black screen."; then
        rp_run mv "$T/home/$u/.config/kwinoutputconfig.json" "$T/home/$u/.config/kwinoutputconfig.json.bak"
      fi
    done
  fi
  echo; echo "Restart to test. Still wrong? Try 'Start with an older kernel', and run the hardware check (graphics lines)."
  return 0
}

# ---------------------------------------------------------------- snapshots
act_snapshot() {
  local T n choice
  echo; echo "=== Go back to an earlier snapshot ==="
  echo "Secure Linux takes snapshots (frozen copies of the system) before updates. Going back undoes a bad update."
  echo "Your documents in /home are not part of a system snapshot and are not changed."
  rp_target_ensure rw || return 1
  T=$(rp_t)
  if ! have snapper; then
    echo "The snapshot tool (snapper) is not available here."
    if [ "$T" != / ]; then
      echo "From a rescue system you can see snapshots by hand:  mount -o subvolid=5 $RP_ROOTDEV /mnt/top ; ls /mnt/top/root/.snapshots"
    fi
    return 1
  fi
  local list; list=$(rp_run_t snapper -c root list 2>&1)
  if [ "$RP_DRY" != 1 ]; then
    printf '%s\n' "$list" | tail -n 25
    if ! printf '%s' "$list" | grep -qE '^ *[0-9]+'; then echo "There are no snapshots to go back to."; return 0; fi
  else printf '%s\n' "$list"; fi
  if [ "$RP_DRY" = 1 ]; then choice=5; else slh_read choice "Snapshot number to go back to (Enter = cancel): " || return 1; fi
  [[ "$choice" =~ ^[0-9]+$ ]] || { echo "Cancelled. Nothing was changed."; return 0; }
  echo; echo "What would change (files differing between snapshot $choice and now):"
  rp_run_t snapper -c root status "$choice..0" | head -n 40
  rp_backup "snapshot rollback"
  if rp_step "Undo the changes since snapshot $choice" "Runs: snapper -c root undochange $choice..0 . Files changed since then are put back as they were; files added since then are removed. A new snapshot of 'now' is kept first, so you can undo this too (VERIFY on Fedora 44)."; then
    rp_run_t snapper -c root create -d "before rollback to $choice"
    rp_run_t snapper -c root undochange "$choice..0"
    rp_run_t dracut --force --regenerate-all
    echo "Restart now. If the computer still misbehaves, try an earlier snapshot number."
  fi
  return 0
}


# ====================================================================================================================
# U2: automatic fixes for the problems secure-linux-diagnose finds (hw/health/kb). Run through rp_fix_run (repair-misc.sh):
# it checks the problem is really there, explains, backs up, asks (unless the whole plan was approved once), applies,
# checks the result and says "fixed" or "could not fix, here is what to do next". Every fix is safe to run twice.
# Functions fx_NAME (fix-NAME with - as _) get the detected arguments as $@. They change things only through rp_run /
# rp_run_t, so --dry-run shows exactly what would happen. None of them touches a BitLocker or LUKS volume.
# ====================================================================================================================

fx_pm() { case "$(sd_family)" in debian) echo apt ;; *) echo dnf ;; esac; }   # which package manager the checked system uses
fx_target_rw() {   # a system opened read-only for checking must be opened read-write before a repair changes it
  local T; T=$(rp_t); [ "$T" = / ] && return 0
  if findmnt -no OPTIONS "$T" 2>/dev/null | grep -qE '(^|,)ro(,|$)'; then rp_run mount -o remount,rw "$T" || return 1; fi
  rp_chroot_binds "$T"
  return 0
}
fx_efi_label() { case "$(sd_family)" in debian) echo "Debian" ;; *) echo "Fedora" ;; esac; }
fx_efi_loader() { case "$(sd_family)" in debian) echo '\EFI\debian\shimx64.efi' ;; *) echo '\EFI\fedora\shimx64.efi' ;; esac; }

fx_efi_entry() {
  have efibootmgr || { echo "The tool efibootmgr is not available here (package: efibootmgr)."; return 1; }
  [ "$(rp_efi_mode)" = uefi ] || { echo "There is no EFI start-up list to change: this computer starts in the old BIOS way."; return 0; }
  local esp disk num
  esp=$(rp_find_esp); [ -n "$esp" ] || { echo "I could not find the EFI start-up partition."; return 1; }
  disk=$(rp_parent_disk "$esp"); num=$(cat "/sys/class/block/${esp##*/}/partition" 2>/dev/null)
  fxb_text efibootmgr-before.txt "$(efibootmgr -v 2>&1)"
  rp_run efibootmgr -c -d "$disk" -p "${num:-1}" -L "$(fx_efi_label)" -l "$(fx_efi_loader)"
}
fx_efi_order() {
  have efibootmgr || { echo "The tool efibootmgr is not available here."; return 1; }
  local first=${1:-} cur rest
  [ -n "$first" ] || { echo "I do not know which entry is Linux."; return 1; }
  cur=$(efibootmgr 2>/dev/null | sed -n 's/^BootOrder: *//p' | head -n1)
  fxb_text efibootmgr-before.txt "$(efibootmgr -v 2>&1)"
  rest=$(printf '%s' "$cur" | tr ',' '\n' | grep -vi "^$first$" | paste -sd, -)
  rp_run efibootmgr -o "$first${rest:+,$rest}"
}
fx_grub_cfg() {
  fxb etc/default/grub boot/grub2/grub.cfg boot/grub/grub.cfg
  fx_target_rw || return 1
  if [ "$(sd_family)" = debian ]; then rp_run_t update-grub; else rp_run_t grub2-mkconfig -o /boot/grub2/grub.cfg; fi
}
fx_grub_windows() {
  local T f; T=$(rp_t); f="$T/etc/default/grub"
  [ -e "$f" ] || { echo "There is no /etc/default/grub here."; return 1; }
  fxb etc/default/grub boot/grub2/grub.cfg boot/grub/grub.cfg
  fx_target_rw || return 1
  if grep -q '^GRUB_DISABLE_OS_PROBER' "$f"; then rp_run sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' "$f"
  else if [ "$RP_DRY" = 1 ]; then echo "  [dry run] would add GRUB_DISABLE_OS_PROBER=false to $f"; else printf '\nGRUB_DISABLE_OS_PROBER=false\n' >> "$f"; fi; fi
  if [ "$(sd_family)" = debian ]; then rp_run_t update-grub; else rp_run_t grub2-mkconfig -o /boot/grub2/grub.cfg; fi
}
fx_fstab_nofail() {
  local T f tmp mp n=0 line; T=$(rp_t); f="$T/etc/fstab"
  [ -r "$f" ] || { echo "No /etc/fstab found."; return 1; }
  fxb etc/fstab
  local -a mps=("$@"); [ ${#mps[@]} -gt 0 ] || { echo "I do not know which drive is missing."; return 1; }
  for mp in "${mps[@]}"; do
    [ "$mp" = / ] && { echo "I will not change the line for the main system drive (/)."; continue; }
    if [ "$RP_DRY" = 1 ]; then echo "  [dry run] would add nofail,x-systemd.device-timeout=5s to the fstab line for $mp"; n=$((n + 1)); continue; fi
    tmp=$(mktemp); cp "$f" "$tmp"
    awk -v mp="$mp" 'BEGIN{OFS="\t"} $0 !~ /^[ \t]*#/ && $2==mp && $4 !~ /nofail/ { $4 = $4 ",nofail,x-systemd.device-timeout=5s" } {print}' "$f" > "$tmp" && install -m 644 "$tmp" "$f" && n=$((n + 1))
    rm -f "$tmp"
  done
  [ "$n" -gt 0 ]
}
fx_initramfs() {
  fxb_list boot
  fx_target_rw || return 1
  if [ "$(sd_family)" = debian ]; then rp_run_t update-initramfs -c -k all; else rp_run_t dracut --force --regenerate-all; fi
}
fx_kernel_reinstall() {
  online_ok || { echo "There is no internet connection, so I cannot download the files. Connect a cable or tether a phone, then run this again."; return 1; }
  fxb etc/fstab etc/default/grub
  fx_target_rw || return 1
  if [ "$(sd_family)" = debian ]; then rp_run_t apt-get install -y --reinstall linux-image-amd64
  else rp_run_t dnf -y reinstall kernel-core kernel-modules kernel || rp_run_t dnf -y install kernel; rp_run_t dracut --force --regenerate-all; fi
}
fx_mok_enroll() {
  fx_need_running "approving the driver key" || return 2
  have secure-linux-drivers || { echo "secure-linux-drivers is not installed."; return 1; }
  echo "You will choose a one-time password now. After the restart a blue screen appears: choose Enroll MOK, then Continue, then type that password."
  rp_run secure-linux-drivers enroll-key
}
fx_nomodeset_remove() {
  fxb etc/default/grub
  fx_target_rw || return 1
  if have grubby || [ "$(rp_t)" != / ]; then rp_run_t grubby --update-kernel=ALL --remove-args=nomodeset
  else rp_run sed -i 's/ nomodeset//' "$(rp_t)/etc/default/grub"; rp_run_t update-grub; fi
}
fx_plymouth_off() {
  fxb etc/default/grub
  fx_target_rw || return 1
  if have grubby || [ "$(rp_t)" != / ]; then rp_run_t grubby --update-kernel=ALL --remove-args="rhgb splash"
  else rp_run sed -i 's/ splash//' "$(rp_t)/etc/default/grub"; rp_run_t update-grub; fi
}
fx_rtc_local() {
  fx_need_running "changing the clock mode" || return 2
  rp_run timedatectl set-local-rtc 1 --adjust-system-clock
}
fx_nvidia_rebuild() {
  fx_need_running "rebuilding the NVIDIA driver" || return 2
  if have secure-linux-drivers; then rp_run secure-linux-drivers reinstall
  else rp_run akmods --force --rebuild; rp_run dracut --force --regenerate-all; fi
}
fx_wait_online() {
  fx_target_rw || return 1
  rp_run_t systemctl disable NetworkManager-wait-online.service
}
fx_old_kernels() {
  fxb_text installed-kernels.txt "$(ls -1 "$(rp_t)"/boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||')"
  fx_target_rw || return 1
  if [ "$(sd_family)" = debian ]; then rp_run_t apt-get -y autoremove --purge
  else rp_run_t dnf -y remove --oldinstallonly --setopt=installonly_limit=2 kernel-core; fi
}
