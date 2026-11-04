# shellcheck shell=bash
# lib/sl-toolbox-more.sh (owner: ux) - the bigger flows of secure-linux-toolbox: rescue my files, Windows help,
# clean up, updates. Sourced by bin/secure-linux-toolbox after lib/sl-ui.sh and hw/health/lib.sh. Not a command.
# Principle ("minimal input"): detect first, ask only what cannot be detected, pre-select the recommended answer.
# Test hooks: SL_TB_ASSUME_MOUNTED=1 (treat SL_TB_SRC_MNT / SL_TB_DST_MNT as already opened), SL_TB_UPDATES=N, SL_TB_CLEAN_BYTES=N.

TB_SRC_MNT=${SL_TB_SRC_MNT:-/mnt/sl-source}
TB_DST_MNT=${SL_TB_DST_MNT:-/mnt/sl-destination}
declare -a TB_OPENED=() TB_MOUNTED=()

tb_root() {   # run a command as the administrator (pkexec on the desktop, sudo in a terminal)
  if slh_is_root; then "$@"
  elif [ -n "${SL_TB_ROOTCMD+x}" ]; then ${SL_TB_ROOTCMD} "$@"
  elif _ui_have pkexec && [ "$UI_MODE" = gui ]; then pkexec "$@"
  elif _ui_have sudo; then sudo "$@"
  elif _ui_have pkexec; then pkexec "$@"
  else "$@"; fi
}
tb_term() {   # run something that talks to the user in a terminal (own window when we are a desktop window)
  if [ "$UI_MODE" = gui ]; then
    if _ui_have secure-linux-terminal; then secure-linux-terminal --hold "$@"; else "$@"; fi
  else "$@"; fi
}
tb_human() { slh_human_bytes "${1:-0}"; }
tb_remember() { mkdir -p "$TB_STATE" 2>/dev/null; local f=$TB_STATE/answers; { grep -v "^$1=" "$f" 2>/dev/null; printf '%s=%s\n' "$1" "$2"; } > "$f.new" 2>/dev/null && mv -f "$f.new" "$f"; }
tb_recall() { local f=$TB_STATE/answers v=""; [ -r "$f" ] && v=$(sed -n "s/^$1=//p" "$f" | tail -n 1); printf '%s' "$v"; }

# ---------------------------------------------------------------- what kind of drive is this?
tb_kind() {   # tb_kind FSTYPE -> a plain-English name in TB_KIND, and TB_LOCKED=bitlocker|luks|""
  TB_LOCKED=""
  case "$1" in
    ntfs) TB_KIND="Windows drive" ;;
    BitLocker) TB_KIND="Windows drive (locked with BitLocker)"; TB_LOCKED=bitlocker ;;
    crypto_LUKS) TB_KIND="Linux drive (locked with a disk password)"; TB_LOCKED=luks ;;
    ext4|btrfs|xfs|f2fs) TB_KIND="Linux drive" ;;
    hfsplus) TB_KIND="Mac drive (older format)" ;;
    apfs) TB_KIND="Mac drive (newer format)" ;;
    exfat|vfat) TB_KIND="USB drive or memory card" ;;
    *) TB_KIND="Drive ($1)" ;;
  esac
}
tb_candidates() {   # fills D_DEV D_FS D_SIZE D_LABEL D_MP D_RM D_TRAN for every partition we could use
  D_DEV=(); D_FS=(); D_SIZE=(); D_LABEL=(); D_MP=(); D_RM=(); D_TRAN=(); D_N=0
  local dev fs size label mp rm tran type
  while IFS='|' read -r dev fs size label mp rm tran type; do
    [ -n "$dev" ] && [ -n "$fs" ] || continue
    case "$fs" in swap|iso9660|squashfs|linux_raid_member|LVM2_member|vfat_efi) continue ;; esac
    case "$label" in Ventoy|VTOYEFI|"SYSTEM_DRV"|"EFI") [ "$label" = SYSTEM_DRV ] || continue ;; esac
    [ "$type" = loop ] && continue
    D_DEV+=("$dev"); D_FS+=("$fs"); D_SIZE+=("$size"); D_LABEL+=("$label"); D_MP+=("$mp"); D_RM+=("$rm"); D_TRAN+=("$tran"); D_N=$((D_N + 1))
  done < <(rp_lsblk NAME,FSTYPE,SIZE,LABEL,MOUNTPOINT,RM,TRAN,TYPE)
}
tb_dev_name() {   # "Windows drive, 465.8G, 'OS'"
  tb_kind "${D_FS[$1]}"; printf '%s, %s%s' "$TB_KIND" "${D_SIZE[$1]}" "${D_LABEL[$1]:+, called \"${D_LABEL[$1]}\"}"
}
tb_is_source_fs() { case "$1" in ntfs|BitLocker|crypto_LUKS|ext4|btrfs|xfs|f2fs|hfsplus|apfs) return 0 ;; esac; return 1; }
tb_is_dest_fs() { case "$1" in exfat|ntfs|ext4|btrfs|xfs|vfat|f2fs) return 0 ;; esac; return 1; }

tb_cleanup_mounts() {
  local i
  sync
  for ((i = ${#TB_MOUNTED[@]} - 1; i >= 0; i--)); do tb_root umount "${TB_MOUNTED[i]}" >/dev/null 2>&1; done
  for i in "${TB_OPENED[@]:-}"; do [ -n "$i" ] && tb_root cryptsetup close "$i" >/dev/null 2>&1; done
  TB_MOUNTED=(); TB_OPENED=()
}
tb_open_dev() {   # tb_open_dev DEV FS RO|RW MOUNTPOINT -> opens (unlocks if needed) and mounts; sets TB_OPEN_DIR
  local dev=$1 fs=$2 mode=$3 mp=$4 name pw n=0 opts=$3 type=""
  TB_OPEN_DIR=""
  tb_kind "$fs"
  if [ -n "$TB_LOCKED" ]; then
    name="sl-box-$$-$RANDOM"
    while [ $n -lt 2 ]; do
      n=$((n + 1))
      if [ "$TB_LOCKED" = bitlocker ]; then
        ui_secret "This drive is locked with BitLocker (Windows' own drive lock). Type its password, or the long 48-digit recovery key. Only you can know this - we cannot get around it." || return 1
      else
        ui_secret "This drive is locked with your disk password (the one you type when the computer starts). Type it now." || return 1
      fi
      pw=$UI_REPLY
      [ -n "$pw" ] || return 1
      if [ "$TB_LOCKED" = bitlocker ]; then printf '%s' "$pw" | tb_root cryptsetup open --type bitlk --key-file=- "$dev" "$name" >/dev/null 2>&1 && break
      else printf '%s' "$pw" | tb_root cryptsetup open --key-file=- "$dev" "$name" >/dev/null 2>&1 && break; fi
      pw=""; [ $n -lt 2 ] && ui_say "That did not unlock the drive. Check the keyboard layout and Caps Lock, then try once more."
    done
    unset pw
    [ -e "/dev/mapper/$name" ] || [ -n "${SL_TB_ASSUME_MOUNTED:-}" ] || { ui_error "The drive stayed locked." "Find the password or recovery key (for BitLocker it is saved in your Microsoft account at account.microsoft.com/devices/recoverykey), then try again." "cryptsetup could not open $dev"; return 1; }
    TB_OPENED+=("$name"); dev=/dev/mapper/$name
  fi
  if [ -n "${SL_TB_ASSUME_MOUNTED:-}" ]; then TB_OPEN_DIR=$mp; return 0; fi
  case "$fs" in ntfs|BitLocker) type="-t ntfs3"; _ui_have ntfs-3g && type="-t ntfs-3g" ;; hfsplus) type="-t hfsplus" ;; apfs) type="-t apfs" ;; esac
  [ "$mode" = RO ] && opts=ro || opts=rw
  tb_root mkdir -p "$mp" >/dev/null 2>&1
  # shellcheck disable=SC2086
  if tb_root mount $type -o "$opts" "$dev" "$mp" >/dev/null 2>&1 || { [ "$opts" = ro ] && tb_root mount -o ro,norecovery "$dev" "$mp" >/dev/null 2>&1; }; then
    TB_MOUNTED+=("$mp"); TB_OPEN_DIR=$mp; return 0
  fi
  ui_error "We could not open the drive $dev." "If this is a Mac drive in the newer format (APFS), Linux cannot read it here: copy the files from the Mac itself. If Windows did not shut down properly, start Windows once and shut it down fully (hold Shift while choosing Shut down), then try again." "mount $dev failed"
  return 1
}

# ---------------------------------------------------------------- rescue my files
tb_user_folders() {   # tb_user_folders ROOTDIR -> prints folders worth saving (one per line)
  local r=$1 u f
  for u in "$r"/Users/* "$r"/home/* "$r"/Documents*; do
    [ -d "$u" ] || continue
    case "${u##*/}" in Public|Default|"Default User"|"All Users"|"Shared"|lost+found|Documents) [ "${u##*/}" = Documents ] || continue ;; esac
    if [ "${u##*/}" = Documents ]; then printf '%s\n' "$u"; continue; fi
    for f in Documents Desktop Pictures Music Videos Downloads OneDrive "My Documents" "My Pictures"; do [ -d "$u/$f" ] && printf '%s\n' "$u/$f"; done
  done
}
tb_rescue_files() {
  ui_push "Rescue my files"; ui_header "Rescue my files"
  local i src=-1 dst=-1 best=-1 n_src=0 n_dst=0 sdev sfs ddev dfs what folders=() total=0 free=0 stamp out f pct pid
  ui_say "We will copy your photos, documents and other files to a different drive. We do not change anything on the drive they come from, so this is safe to try."
  tb_cleanup_mounts
  ui_task "Looking for drives" tb_candidates
  # source: a drive that has files; destination: a different drive with room
  local -a SRC=() DST=()
  for ((i = 0; i < D_N; i++)); do
    tb_is_source_fs "${D_FS[i]}" && SRC+=("$i")
    tb_is_dest_fs "${D_FS[i]}" && [ "${D_MP[i]}" != / ] && DST+=("$i")
  done
  if [ -n "${SL_TB_ASSUME_MOUNTED:-}" ] && [ "${#SRC[@]}" -eq 0 ]; then ui_say "(test mode: using the prepared folders)"; sdev=test; sfs=ntfs; src=0; fi
  # the running system's own drive is not a "source" when we are on the installed system: its files are in the home folder
  if [ "${#SRC[@]}" -eq 0 ] && [ "$src" -lt 0 ]; then
    ui_error "We could not find a drive with files on it." "Check that the drive is plugged in properly and switched on, then choose Rescue my files again. If the drive makes clicking noises, switch it off and ask a helper: a failing drive needs special care." "no drives with files found"
    ui_pop; return 1
  fi
  if [ "$src" -lt 0 ]; then
    if [ "${#SRC[@]}" -eq 1 ]; then src=${SRC[0]}
    else
      local -a items=(); local last; last=$(tb_recall rescue_source)
      for i in "${SRC[@]}"; do items+=("$i|$(tb_dev_name "$i")|${D_DEV[i]}"); [ "$last" = "${D_DEV[i]}" ] && best=$i; done
      if [ "$best" -ge 0 ]; then src=$best; ui_say "Using the same drive as last time: $(tb_dev_name "$best")."
      else
        ui_say "More than one drive has files on it. Which one are your files on? (If you are not sure, pick the biggest Windows or Linux drive.)"
        ui_menu "Where are your files now?" "${items[@]}" || { ui_pop; return 1; }
        src=$UI_REPLY
      fi
    fi
    sdev=${D_DEV[src]}; sfs=${D_FS[src]}; tb_remember rescue_source "$sdev"
  fi
  [ "${D_RM[src]:-0}" = 1 ] && ui_say "Note: this drive is a USB drive. That is fine."
  if [ "$sdev" = test ] || tb_open_dev "$sdev" "$sfs" RO "$TB_SRC_MNT"; then :; else tb_cleanup_mounts; ui_pop; return 1; fi
  local root=$TB_OPEN_DIR
  mapfile -t folders < <(tb_user_folders "$root")
  if [ ${#folders[@]} -eq 0 ]; then
    ui_say "We could not see the usual folders (Documents, Pictures and so on), so we will copy everything on the drive."
    folders=("$root")
  fi
  ui_task "Working out how much there is to copy" bash -c 'du -sbc "$@" 2>/dev/null | tail -n 1 | cut -f1 > "$0"' "$TB_STATE/size.$$" "${folders[@]}"
  total=$(cat "$TB_STATE/size.$$" 2>/dev/null); rm -f "$TB_STATE/size.$$"; total=${total:-0}
  # destination
  for i in "${DST[@]}"; do
    [ "$i" = "$src" ] && continue
    case "${D_DEV[i]}" in "${sdev%[0-9]}"*) [ "${sdev%[0-9]}" != "$sdev" ] && continue ;; esac   # same physical drive as the source: no use as a safe copy
    n_dst=$((n_dst + 1))
  done
  if [ -n "${SL_TB_DST_DIR:-}" ]; then dst=-2; ddev=test
  elif [ $n_dst -eq 0 ]; then
    ui_error "We need a second drive to put the copy on." "Plug in a USB drive or an external hard drive with enough free space (about $(tb_human "$total")), wait ten seconds, then choose Rescue my files again. Nothing was copied or changed." "no destination drive"
    tb_cleanup_mounts; ui_pop; return 1
  else
    local -a ditems=() dlist=()
    for i in "${DST[@]}"; do
      [ "$i" = "$src" ] && continue
      case "${D_DEV[i]}" in "${sdev%[0-9]}"*) [ "${sdev%[0-9]}" != "$sdev" ] && continue ;; esac
      ditems+=("$i|$(tb_dev_name "$i")|${D_DEV[i]}"); dlist+=("$i")
    done
    local lastd; lastd=$(tb_recall rescue_destination); dst=-1
    for i in "${dlist[@]}"; do [ "$lastd" = "${D_DEV[i]}" ] && dst=$i; done
    if [ ${#dlist[@]} -eq 1 ]; then dst=${dlist[0]}
    elif [ "$dst" -ge 0 ]; then ui_say "Using the same drive as last time for the copy: $(tb_dev_name "$dst")."
    else ui_menu "Where should the copy go?" "${ditems[@]}" || { tb_cleanup_mounts; ui_pop; return 1; }; dst=$UI_REPLY; fi
    ddev=${D_DEV[dst]}; dfs=${D_FS[dst]}; tb_remember rescue_destination "$ddev"
  fi
  if [ -n "${SL_TB_DST_DIR:-}" ]; then TB_OPEN_DIR=$SL_TB_DST_DIR
  elif [ -n "${D_MP[dst]}" ] && [ "${D_MP[dst]}" != "-" ]; then TB_OPEN_DIR=${D_MP[dst]}
  else tb_open_dev "$ddev" "$dfs" RW "$TB_DST_MNT" || { tb_cleanup_mounts; ui_pop; return 1; }; fi
  local dest=$TB_OPEN_DIR
  free=$(df -P -B1 "$dest" 2>/dev/null | awk 'NR==2{print $4}'); free=${free:-0}
  if [ "$total" -gt 0 ] && [ "$free" -gt 0 ] && [ "$total" -gt "$free" ]; then
    ui_error "There is not enough room on that drive. The files need $(tb_human "$total") and it has $(tb_human "$free") free." "Use a bigger drive, or plug in a second drive and choose Rescue my files again. Nothing was copied." "free space too small"
    tb_cleanup_mounts; ui_pop; return 1
  fi
  stamp=$(date +%Y-%m-%d-%H%M); out="$dest/Rescued files $stamp"
  ui_header "Ready to copy your files"
  ui_table "What|Details" "Copy from|$( [ "$sdev" = test ] && echo 'the prepared drive' || tb_dev_name "$src")" "Copy to|$( [ "$dst" -ge 0 ] && tb_dev_name "$dst" || echo "your chosen folder")" "Folders|${#folders[@]} folder(s): Documents, Pictures, Desktop and so on" "Size|$(tb_human "$total") (room left: $(tb_human "$free"))" "New folder|Rescued files $stamp"
  ui_card ok "Nothing on your old drive changes" "How it works" "We only read from the old drive. Your files are copied into a new folder on the other drive. If the copy stops half way, you can run it again and it carries on where it stopped."
  if ! ui_yesno "Copy these files now?" y "Copy my files" "Not now"; then ui_say "Nothing was copied."; tb_cleanup_mounts; ui_pop; ui_wait; return 0; fi
  if [ "${TB_DRY:-0}" = 1 ]; then ui_say "[dry run] would copy ${#folders[@]} folder(s) into: $out"; tb_cleanup_mounts; ui_pop; ui_wait; return 0; fi
  mkdir -p "$out" 2>/dev/null || tb_root mkdir -p "$out"
  ui_progress_begin "Copying your files"
  local log=$TB_STATE/rescue-copy.log; : > "$log"
  local rc=0 base
  for f in "${folders[@]}"; do
    base=${f#"$root"}; base=${base#/}; [ -n "$base" ] || base=Everything
    mkdir -p "$out/$base" 2>/dev/null
    if _ui_have rsync; then
      tb_root rsync -rt --partial --ignore-errors --info=progress2 --no-inc-recursive "$f/" "$out/$base/" >> "$log" 2>&1 &
    else tb_root cp -a "$f/." "$out/$base/" >> "$log" 2>&1 & fi
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
      pct=$(tail -c 300 "$log" 2>/dev/null | tr '\r' '\n' | grep -o '[0-9]*%' | tail -n 1); ui_progress "${pct%\%}" "Copying ${f##*/}"; sleep 1
    done
    wait "$pid" || rc=$?
  done
  ui_progress 100 "Finished"; ui_progress_end
  sync
  tb_cleanup_mounts
  if [ $rc -eq 0 ] || [ $rc -eq 23 ] || [ $rc -eq 24 ]; then
    ui_banner ok "Your files are copied" "They are in the folder \"Rescued files $stamp\" on the other drive. It is safe to unplug both drives now."
    [ $rc -ne 0 ] && ui_say "A few files could not be read (they may be damaged). Everything else is copied. The list is saved in $log."
  else
    ui_error "The copy stopped early (code $rc)." "Run Rescue my files again: it carries on where it stopped. If it stops again, the drive may be failing. Switch it off and ask a helper." "rsync exit code $rc; see $log"
  fi
  TB_LOG+=("Rescued files: $out")
  ui_pop; ui_wait
}

# ---------------------------------------------------------------- Windows help (works on a PC that only has Windows)
tb_windows_help() {
  ui_push "Windows help"
  while :; do
    ui_header "Windows help"
    ui_menu "What do you need?" \
      "check|Check Windows' drive for errors|Safe look. Changes nothing" \
      "boot|Windows will not start|Steps that usually fix it" \
      "pw|I forgot my Windows password|Your own computer only" \
      "files|Rescue my files first|Copy them to another drive" \
      "install|Put Linux on this computer|How to install Secure Linux" || break
    case $UI_REPLY in
      check) tb_windows_check ;;
      boot) tb_windows_boot ;;
      pw) tb_password_notice && tb_term "$TB_REPAIR" --action windows ${TB_DRY_FLAG:-} ;;
      files) tb_rescue_files ;;
      install) ui_card info "Putting Linux on this computer" "How" "1. Restart the computer with the Secure Linux stick still plugged in." "Then" "2. In the stick's blue menu, choose SET UP THIS COMPUTER and follow the questions. Before you do, choose Rescue my files here so nothing is lost." "Keep Windows?" "The setup asks. You can keep Windows next to Linux (dual boot) or replace it." ; ui_wait ;;
    esac
  done
  ui_pop
}
tb_password_notice() {
  ui_card warn "Only for your own computer" "Please check" "Resetting a password is only for a computer that is yours, or that the owner has asked you to help with. Using it on someone else's computer without their say-so is against the law."
  ui_yesno "Is this your own computer, or do you have the owner's permission?" n "Yes, it is mine" "No"
}
tb_windows_check() {
  ui_push "Check Windows' drive"; ui_header "Check Windows' drive"
  tb_candidates
  local i n=0 dev out
  for ((i = 0; i < D_N; i++)); do
    [ "${D_FS[i]}" = ntfs ] || continue
    n=$((n + 1)); dev=${D_DEV[i]}
    if _ui_have ntfsfix; then
      out=$(tb_root ntfsfix --no-action "$dev" 2>&1)
      if printf '%s' "$out" | grep -qiE 'dirty|hibernat|fast restart|unclean'; then
        ui_traffic warn "$dev ($(tb_dev_name "$i"))" "Windows did not shut down fully, so the drive is marked 'needs checking'."
        ui_say "Best fix: start Windows, then open Command Prompt as administrator and type  chkdsk C: /f  and press Enter. Say Y if it asks to check at the next start, then restart. If Windows will not start, choose \"Windows will not start\" instead."
      else ui_traffic ok "$dev ($(tb_dev_name "$i"))" "No problems found"; fi
    else ui_traffic skip "$dev" "The checking tool (ntfsfix) is not on this stick. In Windows type  chkdsk C: /f"; fi
  done
  [ $n -eq 0 ] && ui_say "We did not find a Windows drive."
  ui_wait; ui_pop
}
tb_windows_boot() {
  ui_push "Windows will not start"; ui_header "Windows will not start"
  ui_card info "Try these in order" "1. Let Windows repair itself" "Switch on, and as soon as the Windows logo shows, hold the power button to switch off. Do this three times. Windows then opens its repair screen. Choose Troubleshoot, then Advanced options, then Startup Repair." \
    "2. Still stuck?" "On that same screen choose Command Prompt and type these, pressing Enter after each:  bootrec /fixmbr   bootrec /fixboot   bootrec /rebuildbcd" \
    "3. Want us to look?" "Choose \"Rescue my files first\" to save your photos and documents, then come back and use the repair menu for Windows."
  if ui_yesno "Open the Windows repair helper here now? (It only looks first and asks before it changes anything.)" n "Open it" "Not now"; then tb_term "$TB_REPAIR" --action windows ${TB_DRY_FLAG:-}; fi
  ui_pop
}

# ---------------------------------------------------------------- clean up and speed up
tb_clean_measure() {   # prints how many bytes a safe clean-up would free
  [ -n "${SL_TB_CLEAN_BYTES:-}" ] && { printf '%s' "$SL_TB_CLEAN_BYTES"; return 0; }
  local t=0 s d
  for d in "$HOME/.cache/thumbnails" /var/cache/libdnf5 /var/cache/dnf /var/cache/PackageKit; do
    [ -d "$d" ] || continue; s=$(du -sb "$d" 2>/dev/null | cut -f1); t=$((t + ${s:-0}))
  done
  printf '%s' "$t"
}
tb_clean_run() {
  rm -rf "$HOME"/.cache/thumbnails/* 2>/dev/null
  _ui_have dnf && tb_root dnf -y clean packages >/dev/null 2>&1
  _ui_have journalctl && tb_root journalctl --vacuum-time=14d >/dev/null 2>&1
  _ui_have flatpak && flatpak uninstall --unused -y >/dev/null 2>&1
  return 0
}
tb_clean_flow() {
  ui_push "Clean up and speed up"; ui_header "Clean up and speed up"
  local b; b=$(tb_clean_measure)
  if [ "${b:-0}" -lt 20000000 ]; then ui_banner ok "Nothing worth cleaning right now" "Your computer is tidy already."; ui_pop; ui_wait; return 0; fi
  ui_card ok "We can free about $(tb_human "$b")" "What we will clear" "Old picture previews, downloaded update files, old system logs (older than two weeks) and apps nobody uses any more." "Is it safe?" "Yes. Your own files, photos and documents are never touched. Everything cleared is rebuilt by the computer if it is needed again."
  if ui_yesno "Clean up now?" y "Clean up" "Not now"; then
    if [ "${TB_DRY:-0}" = 1 ]; then ui_say "[dry run] would clear previews, update downloads, old logs and unused apps."; else ui_task "Cleaning up" tb_clean_run; ui_banner ok "Done" "About $(tb_human "$b") was freed."; TB_LOG+=("Clean up: freed about $(tb_human "$b")"); fi
  fi
  ui_pop; ui_wait
}

# ---------------------------------------------------------------- updates
tb_updates_count() {   # prints the number of waiting updates (0 when unknown)
  [ -n "${SL_TB_UPDATES:-}" ] && { printf '%s' "$SL_TB_UPDATES"; return 0; }
  local n=0 o
  if _ui_have dnf; then o=$(timeout 90 dnf -q check-update 2>/dev/null | grep -cE '^[A-Za-z0-9_.+-]+\.[A-Za-z0-9_]+ +[0-9]'); n=$((n + ${o:-0})); fi
  if _ui_have flatpak; then o=$(timeout 60 flatpak remote-ls --updates 2>/dev/null | grep -c .); n=$((n + ${o:-0})); fi
  printf '%s' "$n"
}
tb_updates_run() {
  if _ui_have rpm-ostree && ! _ui_have dnf; then tb_root rpm-ostree upgrade; fi
  _ui_have dnf && tb_root dnf -y upgrade --refresh
  _ui_have flatpak && flatpak update -y --noninteractive
  return 0
}
tb_updates_flow() {
  ui_push "Updates"; ui_header "Updates"
  local n; ui_task "Checking for updates" bash -c 'true'; n=$(tb_updates_count)
  if [ "${n:-0}" -eq 0 ]; then ui_banner ok "Everything is up to date" "Updates fix security holes and bugs. Yours are all installed."; ui_pop; ui_wait; return 0; fi
  ui_card warn "$n update(s) are waiting" "What this means" "Newer versions of programs and the system are ready. They fix security holes and bugs." "What we will do" "Download and install them. Your files stay as they are. If a restart is needed we tell you; we never restart on our own."
  if ui_yesno "Install the updates now?" y "Install them" "Not now"; then
    if [ "${TB_DRY:-0}" = 1 ]; then ui_say "[dry run] would install $n update(s)."; else ui_task "Installing updates (this can take a few minutes)" tb_updates_run; TB_LOG+=("Updates: installed $n"); fi
  fi
  ui_pop; ui_wait
}
