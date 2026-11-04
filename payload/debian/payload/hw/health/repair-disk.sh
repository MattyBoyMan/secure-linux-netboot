# shellcheck shell=bash
# hw/health/repair-disk.sh (owner: hardware) - secure-linux-repair: file-system repair, rescuing files from a failing drive,
# cloning a drive, virus scan. Needs repair-lib.sh. Nothing here writes to a drive without showing what it will do and
# getting an explicit yes (typed words for the dangerous ones). VERIFY comments mark tool options not tried on a real Fedora 44.

rp_pick_partition() {   # rp_pick_partition "question" -> sets RP_PICK (device) and RP_PICK_FS; returns 1 if cancelled
  local c
  RP_PICK=""; RP_PICK_FS=""
  rp_list_partitions
  if [ "${RP_PART_N:-0}" -eq 0 ]; then echo "No drives or partitions with a file system were found."; return 1; fi
  rp_ask c "$1 (number, Enter = cancel): " 1 || return 1
  [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "$RP_PART_N" ] || { echo "Cancelled. Nothing was changed."; return 1; }
  RP_PICK=${RP_PART_DEV[c]}; RP_PICK_FS=${RP_PART_FS[c]}; RP_PICK_MP=${RP_PART_MP[c]}
  return 0
}

# ---------------------------------------------------------------- check and repair one file system
act_fs() {
  local dev fs name n=0
  echo; echo "=== Check and repair a disk or file system ==="
  echo "First it only LOOKS (nothing is changed). Repairs come second, each with your yes. If a drive is failing or you are"
  echo "not sure, rescue your files first (menu: Rescue my files) - repairing a dying drive can make it worse."
  if [ "$(rp_env)" = installed ]; then
    echo; echo "You are running from this computer's own drive, so its main partitions can't be repaired while they are in use."
    if rp_step "Check the main drive's data (Btrfs scrub)" "Runs: btrfs scrub start -B /  . It reads everything and verifies the checksums; it repairs damage only if a good second copy exists. Safe on a running system, takes a few minutes."; then
      have btrfs && rp_run btrfs scrub start -B / || echo "(btrfs tools missing or / is not Btrfs)"
    fi
    echo "For a full repair: restart from the Secure Linux USB stick (SystemRescue) and run this tool again."
  fi
  rp_pick_partition "Which partition do you want to check?" || return 0
  dev=$RP_PICK; fs=$RP_PICK_FS
  if [ "$fs" = crypto_LUKS ]; then
    echo "$dev is encrypted. It has to be unlocked with your disk password (or recovery key) first."
    name="sl-fs-$$"
    if [ "$RP_DRY" = 1 ]; then echo "  [dry run] would run: cryptsetup open $dev $name"; dev=/dev/mapper/$name; fs=btrfs
    elif cryptsetup open "$dev" "$name"; then RP_OPENED+=("$name"); dev=/dev/mapper/$name; fs=$(lsblk -no FSTYPE "$dev" 2>/dev/null | head -n1)
    else echo "Could not unlock it. Nothing was changed."; return 0; fi
  fi
  if [ "$fs" = BitLocker ]; then
    echo "$dev is protected by Windows BitLocker. Secure Linux never touches a BitLocker drive without its recovery key,"
    echo "and repairs belong to Windows (chkdsk). Nothing was changed."; return 0
  fi
  if [ -n "${RP_PICK_MP:-}" ] && [ "$RP_PICK_MP" != - ] && [ "$RP_DRY" != 1 ]; then
    echo "$dev is in use at $RP_PICK_MP."
    if rp_step "Unmount it first" "Runs: umount $RP_PICK_MP"; then rp_run umount "$RP_PICK_MP" || { echo "It is busy and can't be released. Restart from the rescue stick."; return 0; }; else return 0; fi
  fi
  case "$fs" in
    ext2|ext3|ext4)
      echo; echo "-- Looking only (no changes):"; rp_run e2fsck -fn "$dev"
      if rp_step "Repair $dev ($fs)" "Runs: e2fsck -f -p  - fixes only what is safe to fix automatically."; then
        rp_smart_guard "$dev" || return 0
        rp_run e2fsck -f -p "$dev"; local rc=$?
        if [ $rc -ge 4 ] && [ "$RP_DRY" != 1 ] && rp_step "More serious repair" "The safe repair was not enough. Runs: e2fsck -f -y  - answers 'yes' to every fix, which can remove damaged files."; then rp_run e2fsck -f -y "$dev"; fi
      fi ;;
    xfs)
      echo; echo "-- Looking only (no changes):"; rp_run xfs_repair -n "$dev"
      if rp_step "Repair $dev (xfs)" "Runs: xfs_repair"; then
        rp_smart_guard "$dev" || return 0
        rp_run xfs_repair "$dev" || { rp_typed "ZERO LOG" "xfs_repair says the journal is dirty. Clearing it (xfs_repair -L) can lose the very latest changes (the last few seconds before the crash). Mounting and unmounting once normally fixes this; try that first if you can." && rp_run xfs_repair -L "$dev"; }
      fi ;;
    btrfs)
      echo; echo "-- Looking only (no changes):"; rp_run btrfs check --readonly "$dev"
      if rp_step "Try the gentle options first" "Runs: btrfs rescue zero-log  (fixes a damaged log after a power cut; only the unwritten last moments are lost)."; then
        rp_smart_guard "$dev" || return 0
        rp_run btrfs rescue zero-log "$dev"
      fi
      echo "If it still won't mount, you can often still copy files off with:  mount -o ro,usebackuproot $dev /mnt/x   (menu: Rescue my files)."
      if rp_typed "REPAIR BTRFS" "LAST RESORT: btrfs check --repair can make a damaged Btrfs worse. Do it only after your files are copied elsewhere (or you accept losing them)."; then
        rp_run btrfs check --repair "$dev"
      fi ;;
    f2fs) echo; rp_run fsck.f2fs -f "$dev"; rp_step "Repair $dev (f2fs)" "Runs: fsck.f2fs -f -a  (VERIFY options)" && { rp_smart_guard "$dev" || return 0; rp_run fsck.f2fs -f -a "$dev"; } ;;
    exfat) echo; rp_run fsck.exfat "$dev"; rp_step "Repair $dev (exFAT)" "Runs: fsck.exfat -p  (fixes what is safe to fix)." && { rp_smart_guard "$dev" || return 0; rp_run fsck.exfat -p "$dev"; } ;;
    vfat) echo; rp_run fsck.fat -n "$dev"; rp_step "Repair $dev (FAT)" "Runs: fsck.fat -a  (automatic repair; lost chains are kept as files named FSCK0000.REC)." && { rp_smart_guard "$dev" || return 0; rp_run fsck.fat -a "$dev"; } ;;
    ntfs|ntfs3|ntfsfix)
      echo; echo "NTFS (Windows) can only be repaired lightly from Linux."
      if rp_step "Clear the 'dirty' flag and fix small problems" "Runs: ntfsfix -d  . This lets Windows start its own full check (chkdsk) at the next start. For a real repair run  chkdsk /f  in Windows."; then
        rp_smart_guard "$dev" || return 0
        rp_run ntfsfix -d "$dev"
      fi ;;
    *) echo "The file system type '$fs' isn't one this tool repairs (supported: ext4, xfs, btrfs, f2fs, exFAT, FAT, NTFS-light)." ;;
  esac
  return 0
}

# ---------------------------------------------------------------- rescue files
rp_mount_ro() {   # rp_mount_ro DEV -> prints the folder it is mounted at (read-only)
  local dev=$1 fs mp
  mp=$(lsblk -no MOUNTPOINT "$dev" 2>/dev/null | head -n1)
  [ -n "$mp" ] && { printf '%s' "$mp"; return 0; }
  fs=$(lsblk -no FSTYPE "$dev" 2>/dev/null | head -n1)
  mp=/mnt/sl-src
  if [ "$RP_DRY" = 1 ]; then echo "  [dry run] would run: mount -o ro $dev $mp" >&2; printf '%s' "$mp"; return 0; fi
  mkdir -p "$mp" 2>/dev/null
  case "$fs" in
    BitLocker) echo "$dev is protected by BitLocker: it needs its 48-digit recovery key (not available from here without 'dislocker')." >&2; return 1 ;;
    ntfs) mount -t ntfs3 -o ro "$dev" "$mp" 2>/dev/null || ntfs-3g -o ro "$dev" "$mp" 2>/dev/null || return 1 ;;
    btrfs) mount -o ro,subvol=root "$dev" "$mp" 2>/dev/null || mount -o ro "$dev" "$mp" 2>/dev/null || mount -o ro,usebackuproot "$dev" "$mp" 2>/dev/null || return 1 ;;
    *) mount -o ro "$dev" "$mp" 2>/dev/null || return 1 ;;
  esac
  RP_MOUNTED+=("$mp"); printf '%s' "$mp"
}
act_data() {
  local choice src dest srcdir bytes free sdev ddev
  echo; echo "=== Rescue my files ==="
  echo "Copying FIRST, repairing LATER: it is the safe order. Nothing is written to the drive you copy FROM."
  echo "You need a second drive with enough free space (a USB hard drive or stick that is NOT the Secure Linux stick if you can)."
  if [ "$(rp_env)" = installed ]; then echo "Tip: you are on the running computer. For a drive that is failing, copying from the rescue stick (SystemRescue) is safer."; fi
  echo
  echo "  1) Copy my files to another drive (folders, photos, documents)"
  echo "  2) Make a complete image of a failing drive (ddrescue, retries bad parts)"
  echo "  3) Get back deleted files or a lost partition (PhotoRec / TestDisk)"
  echo "  4) Look at the health of the drives first"
  rp_ask choice "Choose 1-4 (Enter = cancel): " 1 || return 0
  case "$choice" in
    4) have smartctl || { echo "smartctl is not available here."; return 0; }
       for sdev in $(lsblk -dpno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'); do
         echo; echo "$(rp_disk_label "$sdev")"; rp_run smartctl -H -A "$sdev"
       done ;;
    1)
      rp_pick_partition "Which drive/partition are your files on?" || return 0
      sdev=$RP_PICK
      srcdir=$(rp_mount_ro "$sdev") || { echo "Could not open $sdev read-only. For an encrypted drive unlock it first (Check and repair a disk can unlock it); for BitLocker use Windows or the recovery key."; return 0; }
      echo "Opened read-only at $srcdir."
      rp_ask src "Folder to copy FROM [$srcdir]: " "$srcdir" || return 0; src=${src:-$srcdir}
      rp_ask dest "Folder to copy TO, on ANOTHER drive (e.g. /run/media/you/MyDisk/rescue): " "/mnt/sl-rescue-copy" || return 0
      [ -n "$dest" ] || { echo "Cancelled."; return 0; }
      if [ "$RP_DRY" != 1 ]; then
        mkdir -p "$dest" 2>/dev/null || { echo "Can't create $dest."; return 0; }
        ddev=$(rp_dev_of_path "$dest"); [ -n "$ddev" ] && [ "$ddev" = "$(rp_dev_of_path "$src")" ] && { echo "That is the same drive as the source. Pick a folder on a different drive. Nothing was copied."; return 0; }
        bytes=$(du -sb "$src" 2>/dev/null | cut -f1); free=$(rp_free_bytes "$dest")
        if [ -n "$bytes" ] && [ -n "$free" ] && [ "$bytes" -gt "$free" ]; then echo "Not enough room: the files need $(slh_human_bytes "$bytes"), the destination has $(slh_human_bytes "$free") free."; return 0; fi
      fi
      if rp_step "Copy the files" "Copies everything in $src to $dest with rsync. Files that can't be read are skipped and listed; copying carries on. Nothing in $src is changed or deleted."; then
        rp_run rsync -aHAX --info=progress2 --partial "$src"/ "$dest"/
        echo "When it finishes, open a few files in $dest to check they work before you repair or erase anything."
      fi ;;
    2)
      have ddrescue || { echo "ddrescue is not available here (package: ddrescue). Install it, or use SystemRescue, which has it."; return 0; }
      rp_pick_partition "Which drive/partition is failing? (the image is a copy of exactly this)" || return 0
      sdev=$RP_PICK
      rp_ask dest "Image file to create, on ANOTHER drive with enough room (e.g. /run/media/you/MyDisk/rescue.img): " "/mnt/sl-rescue-copy/rescue.img" || return 0
      [ -n "$dest" ] || { echo "Cancelled."; return 0; }
      if [ "$RP_DRY" != 1 ]; then
        ddev=$(rp_dev_of_path "$(dirname "$dest")"); [ -n "$ddev" ] && [ "$(rp_parent_disk "$ddev")" = "$(rp_parent_disk "$sdev")" ] && { echo "The image would go on the SAME physical drive. Pick another drive. Nothing was changed."; return 0; }
        bytes=$(rp_size_bytes "$sdev"); free=$(rp_free_bytes "$(dirname "$dest")")
        [ -n "$bytes" ] && [ -n "$free" ] && [ "$bytes" -gt "$free" ] && { echo "Not enough room for the image: $(slh_human_bytes "$bytes") needed, $(slh_human_bytes "$free") free."; return 0; }
      fi
      if rp_step "Image $sdev to $dest" "Pass 1 copies the easy parts quickly (ddrescue -n), pass 2 goes back for the bad parts with retries (ddrescue -d -r3). Progress is saved in $dest.map, so you can stop (Ctrl+C) and continue later by running the same thing again. Reads $sdev only."; then
        rp_run ddrescue -f -n "$sdev" "$dest" "$dest.map"
        rp_run ddrescue -f -d -r3 "$sdev" "$dest" "$dest.map"
        echo "Then look inside the image:  losetup -fP --show $dest ; mount -o ro /dev/loopXp1 /mnt/x   (or run Check and repair on the IMAGE, never on the failing drive)."
      fi ;;
    3)
      have photorec || have testdisk || { echo "PhotoRec/TestDisk are not available here (package: testdisk). SystemRescue has them."; return 0; }
      rp_pick_partition "Where were the files? (the drive/partition to search; it is only read)" || return 0
      sdev=$RP_PICK
      rp_ask dest "Folder to save found files in, on a DIFFERENT drive: " "/mnt/sl-rescue-copy" || return 0
      [ -n "$dest" ] || { echo "Cancelled."; return 0; }
      if [ "$RP_DRY" != 1 ]; then ddev=$(rp_dev_of_path "$dest"); [ -n "$ddev" ] && [ "$(rp_parent_disk "$ddev")" = "$(rp_parent_disk "$sdev")" ] && { echo "Saving onto the same drive would overwrite the files you are trying to recover. Pick another drive."; return 0; }; fi
      if rp_step "Search $sdev for deleted files" "Runs PhotoRec (menu-driven): it reads $sdev and writes the files it finds into $dest/recovered. File NAMES are usually lost, but the contents come back. For a deleted PARTITION use TestDisk instead (testdisk $sdev)."; then
        [ "$RP_DRY" = 1 ] || mkdir -p "$dest/recovered"
        rp_run photorec /d "$dest/recovered/" "$sdev"
      fi ;;
    *) echo "Cancelled." ;;
  esac
  return 0
}

# ---------------------------------------------------------------- clone / back up a whole drive
act_clone() {
  local src dst ssz dsz sm dm img
  echo; echo "=== Back up or clone a whole drive ==="
  echo "For a complete, compressed backup image, the Clonezilla entry on the Secure Linux USB stick's boot menu is the easiest and"
  echo "safest tool (restart, choose Clonezilla, follow its questions). This menu is for a straight copy of one drive onto another."
  rp_pick_partition "Which drive do you want to COPY FROM? (pick any partition of it)" || return 0
  src=$(rp_parent_disk "$RP_PICK")
  rp_pick_partition "Which drive do you want to COPY TO? (ALL its contents will be replaced!) Pick any partition of it" || return 0
  dst=$(rp_parent_disk "$RP_PICK")
  if [ "$src" = "$dst" ]; then echo "Source and destination are the same drive. Nothing was done."; return 0; fi
  if lsblk -no MOUNTPOINT "$dst" 2>/dev/null | grep -q . && [ "$RP_DRY" != 1 ]; then echo "$dst has partitions in use. Unmount them first (or restart from the rescue stick). Nothing was done."; return 0; fi
  ssz=$(rp_size_bytes "$src"); dsz=$(rp_size_bytes "$dst")
  if [ "$RP_DRY" != 1 ] && [ -n "$ssz" ] && [ -n "$dsz" ] && [ "$dsz" -lt "$ssz" ]; then echo "The destination ($(slh_human_bytes "$dsz")) is smaller than the source ($(slh_human_bytes "$ssz")). A straight copy will not fit. Use Clonezilla (it can copy only the used parts)."; return 0; fi
  sm=$(rp_disk_label "$src"); dm=$(rp_disk_label "$dst")
  cat <<EOF

  COPY FROM : $sm
  COPY TO   : $dm      <-- everything on this drive will be ERASED
EOF
  rp_smart_guard "$src" || return 0
  rp_typed "CLONE $(basename "$src") TO $(basename "$dst")" "Check the two drives above very carefully. There is no undo." || { echo "Not confirmed. Nothing was changed."; return 0; }
  if have ddrescue; then rp_run ddrescue -f "$src" "$dst" "/root/clone-$(basename "$src").map"
  else rp_run dd if="$src" of="$dst" bs=4M conv=fsync,noerror,sync status=progress; fi
  rp_run sync
  echo "Done. Before you rely on the copy, open the destination and look at some files."
  return 0
}

# ---------------------------------------------------------------- virus / rootkit scan
act_malware() {
  local T dbdir stick scanpath ans
  echo; echo "=== Scan for viruses and rootkits ==="
  echo "Looks only: nothing is deleted or moved. Anything found is listed and you decide."
  rp_target_ensure ro || return 1
  T=$(rp_t)
  if ! have clamscan && ! have rkhunter; then
    echo "Neither ClamAV (clamscan) nor rkhunter is available here."
    echo "  Installed Fedora: sudo dnf install clamav clamav-update rkhunter     SystemRescue: ClamAV is included in newer versions (VERIFY)."
    return 1
  fi
  if have clamscan; then
    dbdir=${SL_CLAMAV_DB:-}
    stick=$(slh_find_stick 2>/dev/null) && [ -z "$dbdir" ] && [ -d "$stick/linux-setup/clamav-db" ] && dbdir="$stick/linux-setup/clamav-db"
    if online_ok && have freshclam && [ "$RP_DRY" != 1 ]; then echo "Updating the virus definitions (online)..."; freshclam 2>/dev/null || echo "(update failed; using the definitions already here)"
    elif [ -z "$dbdir" ] && ! ls /var/lib/clamav/*.c[lv]d >/dev/null 2>&1 && [ "$RP_DRY" != 1 ]; then
      echo "There are no virus definitions here and no internet. Offline option: on another computer download main.cvd, daily.cvd and bytecode.cvd from"
      echo "https://database.clamav.net/ into a folder named  clamav-db  in the linux-setup folder on the stick, then run this again."
    fi
    scanpath="$T"; [ "$T" = / ] && scanpath=/home
    rp_ask ans "Folder to scan [$scanpath] (Enter = that): " "$scanpath" || return 0; scanpath=${ans:-$scanpath}
    if rp_step "ClamAV scan of $scanpath" "Runs: clamscan --recursive --infected${dbdir:+ --database=$dbdir} (read-only). It can take a long time on a big drive."; then
      rp_run clamscan --recursive --infected --log="${SL_REPAIR_SCANLOG:-/tmp/secure-linux-clamscan.log}" ${dbdir:+--database="$dbdir"} "$scanpath"
      echo "A list of infected files is in ${SL_REPAIR_SCANLOG:-/tmp/secure-linux-clamscan.log}. Nothing was removed."
    fi
  fi
  if have rkhunter && [ "$T" = / ]; then
    if rp_step "rkhunter (looks for rootkits on THIS running system)" "Runs: rkhunter --check --sk --rwo . 'Warnings' are often harmless (changed config files); look them up before you act."; then rp_run rkhunter --check --sk --rwo --nocolors; fi
  elif have rkhunter; then echo "rkhunter checks a running system, so it can't scan the broken system from here. Boot it and run this tool there."; fi
  return 0
}


# ====================================================================================================================
# U2: disk-related automatic fixes (see the note in repair-boot.sh). fx_backup_files IS the backup, so it is the one fix
# that is allowed on a drive that says it is failing. It only ever READS the drive it copies from.
# ====================================================================================================================

fx_fstype_of() { lsblk -no FSTYPE "$1" 2>/dev/null | head -n1; }
fx_dest_mount() {   # fx_dest_mount DEST -> prints a writable folder for the copy; DEST may be a folder or a drive (opened if needed)
  local d=$1 fs mp
  if [ -d "$d" ]; then printf '%s' "$d"; return 0; fi
  [ -b "$d" ] || [ -n "${SL_FIX_FAKE_BLOCK:-}" ] || return 1
  fs=$(fx_fstype_of "$d")
  case "$fs" in BitLocker|crypto_LUKS) echo "The drive $d is locked ($fs). I will not open it without your key." >&2; return 2 ;; esac
  mp=$(findmnt -no TARGET "$d" 2>/dev/null | head -n1)
  if [ -z "$mp" ]; then
    mp=/mnt/sl-backup
    if [ "$RP_DRY" = 1 ]; then printf '  [dry run] would run: mount %s %s\n' "$d" "$mp" >&2; printf '%s' "$mp"; return 0; fi
    mkdir -p "$mp"; mount "$d" "$mp" 2>/dev/null || return 1
    RP_MOUNTED+=("$mp")
  fi
  printf '%s' "$mp"
}
fx_backup_files() {
  local dest=${1:-} T src mp out stamp need free
  [ -n "$dest" ] || { echo "I need to know where to copy your files (a USB drive or another disk)."; return 1; }
  T=$(rp_t); src="$T/home"
  [ -d "$src" ] || { echo "There is no /home folder to copy in the system being checked."; return 1; }
  mp=$(fx_dest_mount "$dest") || { echo "I could not open $dest for writing."; return 1; }
  case "$mp" in "$T"|"$T"/*) echo "The copy must go to a DIFFERENT drive than the one being rescued."; return 1 ;; esac
  stamp=$(date +%Y%m%d); out="$mp/secure-linux-backup-$stamp"
  need=$(du -sk "$src" 2>/dev/null | awk '{print $1}'); free=$(df -Pk "$mp" 2>/dev/null | awk 'NR==2{print $4}')
  if [ "$RP_DRY" != 1 ] && [ -n "$need" ] && [ -n "$free" ] && [ "$free" -lt "$need" ]; then echo "There is not enough room on $dest: it needs about $((need / 1024)) MB, it has $((free / 1024)) MB."; return 1; fi
  have rsync || { echo "rsync is not available here (package: rsync)."; return 1; }
  rp_run mkdir -p "$out"
  rp_run rsync -a --ignore-errors --exclude='.cache/' --exclude='.local/share/Trash/' "$src/" "$out/home/"
  [ -d "$T/etc/NetworkManager/system-connections" ] && rp_run rsync -a "$T/etc/NetworkManager/system-connections/" "$out/network-connections/"
  [ "$RP_DRY" = 1 ] && return 0
  rsync -a --dry-run --exclude='.cache/' --exclude='.local/share/Trash/' "$src/" "$out/home/" 2>/dev/null | grep -q . && { echo "Some files could not be copied (they may be unreadable). The rest is saved in $out."; return 0; }
  RP_FIX_BACKED_UP=1; export RP_FIX_BACKED_UP
  echo "Your files are saved in $out"
}
fxv_backup_files() { [ "${RP_FIX_BACKED_UP:-}" = 1 ]; }
fx_btrfs_scrub() {
  have btrfs || { echo "btrfs tools are not available."; return 1; }
  rp_run btrfs scrub start "$(rp_t)"
}
fxv_btrfs_scrub() { btrfs scrub status "$(rp_t)" 2>/dev/null | grep -qiE 'running|started|finished'; }
fx_btrfs_balance() {
  have btrfs || { echo "btrfs tools are not available."; return 1; }
  rp_run btrfs balance start -dusage=10 -musage=5 "$(rp_t)"
}
fx_trim() {
  fx_target_rw || return 1
  rp_run_t systemctl enable --now fstrim.timer
  [ "$(rp_t)" = / ] && rp_run fstrim -av
  return 0
}
fx_free_space() {
  local T; T=$(rp_t)
  fx_target_rw || return 1
  if [ "$(sd_family)" = debian ]; then rp_run_t apt-get clean; else rp_run_t dnf clean all; fi
  have journalctl && [ "$T" = / ] && rp_run journalctl --vacuum-size=200M
  [ "$T" = / ] && have flatpak && rp_run flatpak uninstall --unused -y
  if compgen -G "$T/var/lib/systemd/coredump/*" >/dev/null; then rp_run find "$T/var/lib/systemd/coredump" -type f -delete; fi
  return 0
}
fx_zram() {
  fx_target_rw || return 1
  if [ "$(sd_family)" = debian ]; then rp_run_t apt-get install -y systemd-zram-generator; else rp_run_t dnf -y install zram-generator-defaults; fi
  local f; f="$(rp_t)/etc/systemd/zram-generator.conf"
  if [ ! -e "$f" ] && [ ! -e "$(rp_t)/usr/lib/systemd/zram-generator.conf" ]; then
    if [ "$RP_DRY" = 1 ]; then echo "  [dry run] would write $f (one compressed memory area, half of the memory, at most 4 GB)"
    else mkdir -p "$(dirname "$f")"; printf '[zram0]\nzram-size = min(ram / 2, 4096)\n' > "$f"; fi
  fi
  if [ "$(rp_t)" = / ]; then rp_run systemctl daemon-reload; rp_run systemctl start systemd-zram-setup@zram0.service; fi
}
fx_snapshots_trim() {
  have snapper || { echo "snapper is not available."; return 1; }
  rp_run_t snapper -c root cleanup number
  rp_run_t snapper -c root cleanup timeline
}
