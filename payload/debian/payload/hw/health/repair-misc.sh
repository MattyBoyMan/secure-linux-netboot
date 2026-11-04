# shellcheck shell=bash
# hw/health/repair-misc.sh (owner: hardware) - secure-linux-repair: software repair, network, Windows on the same computer,
# forgotten Linux password, factory reset, hardware check, wipe. Needs repair-lib.sh and repair-boot.sh.
# VERIFY comments mark command details not tried on a real Fedora 44.

# ---------------------------------------------------------------- software (rpm, dnf, flatpak)
act_packages() {
  local T atomic=0
  echo; echo "=== Repair software ==="
  echo "Fixes a damaged package database, broken downloads, half-finished updates and damaged program files."
  rp_target_ensure rw || return 1
  T=$(rp_t)
  [ -e "$T/run/ostree-booted" ] || [ -e /run/ostree-booted ] && [ "$T" = / ] && atomic=1
  if [ "$atomic" = 1 ]; then
    echo "This is the image-based (atomic) edition. Its repairs are different:"
    rp_step "Show the state of the system image" "Runs: rpm-ostree status" && rp_run rpm-ostree status
    rp_step "Go back to the previous system image" "Runs: rpm-ostree rollback  (then restart). Your files are not touched." && rp_run rpm-ostree rollback
    rp_step "Clean up caches" "Runs: rpm-ostree cleanup -m" && rp_run rpm-ostree cleanup -m
    rp_step "Repair Flatpak apps" "Runs: flatpak repair --system" && rp_run flatpak repair --system
    return 0
  fi
  rp_step "1. Rebuild the package database" "Runs: rpm --rebuilddb  - fixes 'rpmdb: ... error' and 'database is locked' problems. Takes seconds." && rp_run_t rpm --rebuilddb
  rp_step "2. Throw away downloaded package lists and start fresh" "Runs: dnf clean all, then dnf makecache. Needs internet. Fixes 'repomd.xml signature' / 'metadata' errors." && { rp_run_t dnf clean all; rp_run_t dnf makecache; }
  rp_step "3. Look for broken dependencies" "Runs: dnf check - only reports (changes nothing)." && rp_run_t dnf check
  if rp_step "4. Make installed packages match the repositories" "Runs: dnf distro-sync --refresh --setopt=skip_if_unavailable=True . First a preview (nothing is installed), then you decide. It never removes your files in /home."; then
    rp_run_t dnf --setopt=skip_if_unavailable=True --refresh --assumeno distro-sync
    if [ "$RP_DRY" = 1 ] || slh_confirm "Apply that for real?"; then rp_run_t dnf -y --setopt=skip_if_unavailable=True --refresh distro-sync; fi
  fi
  if rp_step "5. Finish an update that stopped half-way" "Runs: dnf history list (shows the last actions), and: dnf -y --setopt=skip_if_unavailable=True upgrade --refresh  to finish." ; then
    rp_run_t dnf history list --reverse
    rp_run_t dnf -y --setopt=skip_if_unavailable=True upgrade --refresh
  fi
  if rp_step "6. Undo the last software change" "Runs: dnf history undo last  (only if the last install/update caused the trouble). Shows what it would do and asks again." ; then
    rp_run_t dnf history undo last
  fi
  if rp_step "7. Check program files for damage" "Runs: rpm -Va  - lists files that differ from what their package shipped (settings you changed show as 'c' and are normal). Only reports." ; then
    rp_run_t rpm -Va --nomtime --nosize
    echo "To put back a damaged program: sudo dnf reinstall PACKAGE   (find the package with: rpm -qf /path/to/file)."
  fi
  if rp_step "8. Repair Flatpak apps" "Runs: flatpak repair --system  (and --user for your own apps). Needs internet if files are missing." ; then
    rp_run_t flatpak repair --system
    [ "$T" = / ] && rp_run flatpak repair --user
  fi
  return 0
}

# ---------------------------------------------------------------- network
act_network() {
  local env con ans
  env=$(rp_env)
  echo; echo "=== Fix Wi-Fi / internet ==="
  if [ "$env" != installed ]; then
    echo "You are in a rescue system. The network of the INSTALLED computer can only be repaired once it starts."
    echo "From here you can reinstall the Wi-Fi firmware and remove broken saved networks inside the installed system (needs a working"
    echo "connection in this rescue system: plug in a cable, or use  nmtui  to join Wi-Fi)."
    rp_target_ensure rw || return 1
    rp_step "Reinstall the Wi-Fi firmware" "Runs inside the installed system: dnf reinstall linux-firmware" && rp_run_t dnf -y reinstall linux-firmware
    return 0
  fi
  echo "What I can see:"; have nmcli && rp_run nmcli -t general status; have rfkill && rp_run rfkill list
  rp_step "1. Switch Wi-Fi and Bluetooth on (airplane mode)" "Runs: rfkill unblock all . A hardware switch or the airplane-mode key must also be on." && rp_run rfkill unblock all
  rp_step "2. Restart the network service" "Runs: systemctl restart NetworkManager . The connection drops for a few seconds." && rp_run systemctl restart NetworkManager
  if rp_step "3. Clear the name-lookup cache (DNS)" "Runs: resolvectl flush-caches and restarts systemd-resolved. Fixes 'connected but no websites open'."; then
    rp_run resolvectl flush-caches; rp_run systemctl restart systemd-resolved
  fi
  if rp_step "4. Reinstall the Wi-Fi/network firmware and drivers" "Runs: dnf reinstall linux-firmware (needs internet: use a cable or phone USB tethering), then secure-linux-drivers install. Restart afterwards."; then
    rp_run dnf -y reinstall linux-firmware
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
  echo; echo "Test:"; rp_run ping -c1 -W3 1.1.1.1; rp_run getent hosts fedoraproject.org
  return 0
}

# ---------------------------------------------------------------- Windows on the same computer
rp_ntfs_partitions() { rp_lsblk NAME,FSTYPE,SIZE,LABEL | awk -F'|' '$2=="ntfs"||$2=="BitLocker"{print}'; }
act_windows() {
  local choice dev fs size label mp users
  echo; echo "=== Windows on this computer ==="
  echo "  1) Find Windows and show its state"
  echo "  2) Put Windows back in the Fedora start-up menu (os-prober)"
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
      rp_step "1. Install the detector" "Runs: dnf install os-prober (needs internet if it is not there yet)." && rp_run_t dnf -y install os-prober
      if rp_step "2. Switch the detector on in the boot menu settings" "Sets GRUB_DISABLE_OS_PROBER=false in /etc/default/grub (a copy is saved as grub.secure-linux-bak). Fedora switches it off by default."; then
        if [ "$RP_DRY" = 1 ]; then echo "  [dry run] would edit $(rp_t)/etc/default/grub"
        else
          local g; g="$(rp_t)/etc/default/grub"; cp -n "$g" "$g.secure-linux-bak" 2>/dev/null
          if grep -q '^GRUB_DISABLE_OS_PROBER' "$g"; then sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' "$g"; else echo 'GRUB_DISABLE_OS_PROBER=false' >> "$g"; fi
        fi
      fi
      rp_step "3. Rebuild the boot menu" "Runs: grub2-mkconfig -o /boot/grub2/grub.cfg . Look for the lines 'Found Windows Boot Manager'." && rp_run_t grub2-mkconfig -o /boot/grub2/grub.cfg
      echo "With Secure Boot on, Windows still starts from the GRUB menu in most cases. If it doesn't, use the firmware boot menu (F12/Esc) and choose Windows Boot Manager." ;;
    3)
      rp_target_ensure rw || return 1
      have efibootmgr || { echo "efibootmgr is not available here."; return 1; }
      if efibootmgr 2>/dev/null | grep -qi 'windows boot manager'; then echo "The firmware already lists Windows Boot Manager."; return 0; fi
      local esp disk num
      esp=$(rp_find_esp); [ -n "$esp" ] || { echo "No EFI system partition found."; return 1; }
      disk=$(rp_parent_disk "$esp"); num=$(cat "/sys/class/block/${esp##*/}/partition" 2>/dev/null)
      if rp_step "Add 'Windows Boot Manager'" "Creates the entry for $esp (disk $disk, partition ${num:-?}) pointing at \\EFI\\Microsoft\\Boot\\bootmgfw.efi - only works if that file really exists there."; then
        rp_run efibootmgr -c -d "$disk" -p "${num:-1}" -L "Windows Boot Manager" -l '\EFI\Microsoft\Boot\bootmgfw.efi'
      fi ;;
    4) win_password_reset ;;
    5)
      cat <<'EOF'

  Windows won't start. Linux cannot repair Windows' own start-up files, but Windows can, from a Windows install USB:
    1. On a working Windows PC, make a Windows install USB with Microsoft's "Media Creation Tool" (microsoft.com/software-download).
    2. Start the broken PC from it (boot menu: F12 / Esc), choose your language, then "Repair your computer" (bottom left).
    3. Troubleshoot > Advanced options > "Startup Repair". If that fails, open "Command Prompt" and type, one at a time:
         bootrec /fixmbr
         bootrec /fixboot
         bootrec /scanos
         bootrec /rebuildbcd
       (If  bootrec /fixboot  says "Access is denied":  bcdboot C:\Windows /s S: /f UEFI  after assigning S: to the small EFI partition with diskpart.)
    4. A drive with errors: in the same Command Prompt run  chkdsk C: /f
  Your files can be copied off first with the "Rescue my files" menu item here (works on Windows drives; BitLocker needs its recovery key).
EOF
      ;;
    *) echo "Cancelled." ;;
  esac
  return 0
}
win_password_reset() {
  local dev fs mp sam cfg users u bak ans
  cat <<'EOF'

  ##########################################################################
  # FORGOTTEN LOCAL WINDOWS PASSWORD - ONLY ON YOUR OWN COMPUTER           #
  #                                                                        #
  # This removes the password of a LOCAL Windows account on THIS computer. #
  # Use it only on a computer that is yours (or that you are allowed to    #
  # repair). Using it on someone else's computer without their permission  #
  # can be a crime.                                                        #
  #                                                                        #
  # It cannot reset a Microsoft account (the email-address login): for     #
  # that use  account.live.com/password/reset  on another device.          #
  # It never touches BitLocker drives: they need their 48-digit key.       #
  ##########################################################################
EOF
  rp_typed "THIS IS MY COMPUTER" "Type the words below to confirm this is your own computer." || { echo "Not confirmed. Nothing was changed."; return 0; }
  have chntpw || { echo "The tool chntpw is not available here (SystemRescue has it; on Fedora: sudo dnf install chntpw - VERIFY)."; return 1; }
  rp_list_partitions
  rp_ask dev "Type the Windows partition (e.g. /dev/sda3): " "/dev/sda3" || return 0
  [ -n "$dev" ] || { echo "Cancelled."; return 0; }
  fs=$(lsblk -no FSTYPE "$dev" 2>/dev/null | head -n1)
  if [ "$fs" = BitLocker ]; then echo "$dev is protected by BitLocker. Secure Linux does not touch it without the recovery key. Nothing was changed."; return 0; fi
  [ "$RP_DRY" = 1 ] || [ "$fs" = ntfs ] || { echo "$dev is not an NTFS (Windows) partition. Nothing was changed."; return 0; }
  mp=/mnt/sl-win
  if rp_step "Open the Windows partition for writing" "Runs: ntfs-3g $dev $mp . This fails safely if Windows is hibernated or uses Fast Startup (then start Windows and shut down fully first)."; then
    [ "$RP_DRY" = 1 ] || mkdir -p "$mp"
    rp_run ntfs-3g "$dev" "$mp" || { echo "Windows left the drive locked (Fast Startup/hibernation). Start Windows, shut down fully (Shift + Shut down), then try again."; return 1; }
  else return 0; fi
  cfg="$mp/Windows/System32/config"
  [ "$RP_DRY" = 1 ] || [ -d "$cfg" ] || cfg=$(find "$mp" -maxdepth 3 -ipath '*windows/system32/config' -type d 2>/dev/null | head -n1)
  [ "$RP_DRY" = 1 ] || [ -n "$cfg" ] || { echo "No Windows folder found on $dev."; rp_run umount "$mp"; return 1; }
  sam="$cfg/SAM"; bak=$(date +%Y%m%d-%H%M%S)
  if rp_step "Save a copy of the account database first" "Copies SAM and SYSTEM to SAM.secure-linux-bak-$bak and SYSTEM.secure-linux-bak-$bak in the same folder, so this can be undone."; then
    rp_run cp -p "$sam" "$sam.secure-linux-bak-$bak"; rp_run cp -p "$cfg/SYSTEM" "$cfg/SYSTEM.secure-linux-bak-$bak"
  else rp_run umount "$mp"; return 0; fi
  echo; echo "Accounts in this Windows:"; rp_run chntpw -l "$sam"
  rp_ask u "Type the account name to clear the password of: " "" || return 0
  [ -n "$u" ] || { echo "Cancelled."; rp_run umount "$mp"; return 0; }
  if rp_step "Clear the password of '$u'" "Runs: chntpw -u '$u' $sam . It is a menu: press 1 (Clear password), then  y  to save. Then Windows lets '$u' in without a password; set a new one in Windows straight away."; then
    rp_run chntpw -u "$u" "$sam"
  fi
  rp_run sync; rp_run umount "$mp"
  echo "Done. Remove the USB stick and start Windows. Log in to '$u' with an empty password and set a new one."
  return 0
}

# ---------------------------------------------------------------- forgotten Linux password
act_password() {
  local s
  echo; echo "=== Forgot my Linux login password ==="
  if [ "$(rp_env)" = installed ]; then
    echo "You are logged in right now, so you can change a password without the old one if you are an administrator:"
    echo "    sudo passwd YOURNAME"
    echo "If you are locked OUT (cannot log in at all), restart from the Secure Linux USB stick, choose SystemRescue, and run this tool again."
    echo "You will need your DISK password (the one asked at power-on) or the disk recovery key. Nobody can reset THAT one."
    return 0
  fi
  s=$(rp_find_script forgot-login-password.sh) || { echo "Could not find forgot-login-password.sh on the stick (linux-setup/rescue). Mount the stick and run it from there."; return 1; }
  echo "Using: $s"
  rp_step "Reset the login password" "Unlocks the disk (you type the DISK password), opens the Fedora system, lets you type a NEW password for the account you pick, and asks SELinux to re-label at the next start (a few extra minutes)." || return 0
  rp_run bash "$s"
  return 0
}

# ---------------------------------------------------------------- reset to factory state
act_factory() {
  local choice stamp u home
  echo; echo "=== Reset to factory state ==="
  echo "  1) Put Secure Linux's settings and services back (re-run the setup in repair mode; your files and programs stay)"
  echo "  2) Reset MY desktop settings (panels, themes, saved layouts) - kept in a backup folder, not deleted"
  echo "  3) Start completely fresh (reinstall from the USB stick)"
  rp_ask choice "Choose 1-3 (Enter = cancel): " 1 || return 0
  stamp=$(date +%Y%m%d-%H%M%S)
  case "$choice" in
    1)
      if [ "$(rp_env)" != installed ]; then echo "Run this from the installed computer (it has the setup scripts)."; return 0; fi
      if rp_step "Re-assert Secure Linux's configuration" "Runs: /usr/local/lib/secure-linux/setup.sh --repair . It re-checks every setting and service and only fixes what is missing or broken. Settings you edited by hand are kept."; then
        rp_run /usr/local/lib/secure-linux/setup.sh --repair
      fi ;;
    2)
      u=$(cat "$SL_ETC/user" 2>/dev/null); u=${u:-${SUDO_USER:-$USER}}
      home=$(getent passwd "$u" 2>/dev/null | cut -d: -f6); home=${home:-/home/$u}
      rp_typed "RESET SETTINGS" "This moves the desktop settings of '$u' ($home/.config and $home/.local/share/kscreen etc.) into $home/secure-linux-settings-backup-$stamp. Documents, photos and downloads are NOT touched. You will log in to a default desktop." || { echo "Not confirmed."; return 0; }
      rp_run mkdir -p "$home/secure-linux-settings-backup-$stamp"
      rp_run mv "$home/.config" "$home/secure-linux-settings-backup-$stamp/config"
      rp_run mv "$home/.local/share/kscreen" "$home/secure-linux-settings-backup-$stamp/kscreen"
      rp_run chown -R "$u": "$home/secure-linux-settings-backup-$stamp"
      echo "Log out and in again. To undo: move the folders back from $home/secure-linux-settings-backup-$stamp." ;;
    3)
      cat <<'EOF'

  Starting completely fresh ERASES the drive you choose, with everything on it.
  1. Rescue your files first (menu: Rescue my files), onto another drive.
  2. Restart from the Secure Linux USB stick (boot menu: F12 / Esc / F8) and choose
        "SET UP THIS COMPUTER - Complete Secure Linux".
     It asks which drive to use and shows what it will erase before it does anything.
  Nothing is erased by this menu item.
EOF
      ;;
    *) echo "Cancelled." ;;
  esac
  return 0
}

# ---------------------------------------------------------------- hardware check, wipe
act_health() {
  local m h
  echo; echo "=== Check the health of every part ==="
  echo "  1) Quick (under a minute)   2) Standard   3) Full (stress test, tests where you listen and look; about 5 minutes)"
  rp_ask m "Choose 1-3 [2]: " 2 || return 0
  h=$(command -v secure-linux-health 2>/dev/null || true); [ -n "$h" ] || h="${RP_BIN_DIR:-.}/secure-linux-health"
  case "$m" in 1) rp_run "$h" --quick ;; 3) rp_run "$h" --full ;; *) rp_run "$h" ;; esac
  return 0
}
act_wipe() {
  local s
  echo; echo "=== Wipe before selling ==="
  if [ "$(rp_env)" = installed ]; then
    echo "A running computer can't wipe the drive it is running from. Restart from the Secure Linux USB stick, choose SystemRescue,"
    echo "and run:  bash secure-linux-rescue.sh  then 'Wipe before selling'. Back up first: there is no undo."
    return 0
  fi
  s=$(rp_find_script wipe-before-selling.sh) || { echo "Could not find wipe-before-selling.sh (linux-setup/rescue on the stick)."; return 1; }
  echo "This will ERASE the internal drive for good. The script asks you to type the drive name to confirm."
  rp_step "Start the wipe tool" "Runs: bash $s (it asks for typed confirmation of the drive before anything is erased)." && rp_run bash "$s"
  return 0
}


# ====================================================================================================================
# U2: the automatic-fix framework and the remaining fixes. The names below are accepted by
#   secure-linux-repair --action NAME [--arg VALUE]...      (registration: see docs/notes/diagnose-guide.md, "Registering")
#   secure-linux-diagnose --apply-plan
# rp_fix_run NAME [ARGS...]  returns 0 = fixed / nothing to do, 1 = could not fix, 2 = refused or cancelled.
# Test hooks: SL_FIX_DISK_STATE=ok|bad|unknown (instead of asking the drive), RP_FIX_PREAPPROVED=1 (the whole plan was
# approved once by the person; set only by secure-linux-diagnose after the person said yes; never for risky fixes).
# ====================================================================================================================

RP_FIX_IDS="fix-efi-entry fix-efi-order fix-grub-cfg fix-grub-windows fix-fstab-nofail fix-initramfs fix-kernel-reinstall fix-mok-enroll fix-nomodeset-remove fix-plymouth-off fix-rtc-local fix-nvidia-rebuild fix-wait-online fix-old-kernels fix-backup-files fix-btrfs-scrub fix-btrfs-balance fix-trim fix-free-space fix-zram fix-snapshots-trim fix-rpmdb fix-pkg-repair fix-reset-failed fix-flatpak-repair fix-autoremove fix-repos-enable fix-time-sync fix-fwupd-update fix-update-system fix-firewall-on fix-ssh-stop fix-pwquality fix-faillock-reset fix-sudo-repair fix-home-perms fix-firmware-reinstall fix-drivers-install fix-gpu-userland fix-sane fix-wifi-country fix-dns-flush fix-mtu fix-ipv6-off fix-vpn-killswitch-off fix-bluetooth-start fix-nm-start fix-rfkill fix-unmute fix-audio-default fix-restart-audio fix-bt-a2dp fix-power-profile fix-charge-limit fix-keymap-sync fix-cups-start fix-thunderbolt-enroll fix-ha-token-perms fix-recovery-key"
rp_fix_ids() { printf '%s\n' $RP_FIX_IDS; }
rp_fix_label() { rp_fix_title "$1"; }
RFX_BDIR=""; RFX_N=0
declare -a RFX_IDX=()

rp_fix_engine() {   # loads the detectors (to know whether the problem is really there, and to check the result afterwards)
  if ! declare -F sd_collect >/dev/null; then
    local h=${HLIB:-}
    [ -r "$h/diagnose-lib.sh" ] || return 1
    . "$h/diagnose-lib.sh"; . "$h/diagnose-detect.sh"
  fi
  [ -n "${SD_TMP:-}" ] && [ -d "$SD_TMP" ] || SD_TMP=$(mktemp -d)
  [ -n "${SD_FIX:-}" ] || SD_ROOT=$(rp_t)
  [ "${#KB[@]}" -gt 0 ] || sd_kb_load "${SL_DIAG_KB:-$HLIB/kb}"
  SD_MODE=full; SD_HAVE_TARGET=1
  [ -n "$SD_FAMILY" ] || sd_init_env
  return 0
}
sd_reset_cache() { SD_DONE=(); SD_TXT=(); SD_DFC=(); SD_LIM=(); SD_LIMSEEN=(); H_STATE=none; H_N=0; SD_FAMILY=""; SD_ENVC=""; }
rp_fix_title() {   # a short plain-English name of a fix, from the knowledge base
  rp_fix_engine >/dev/null 2>&1 || { echo "$1"; return; }
  local i; local -a F=()
  for i in "${!KB[@]}"; do IFS=$US read -r -a F <<< "${KB[i]}"; [ "${F[12]}" = "$1" ] && { echo "${F[7]}"; return; }; done
  echo "$1"
}
rp_fix_detect() {   # rp_fix_detect ACTION -> I_* hold the problems that use this fix and are really present
  local i; local -a F=()
  I_N=0; I_ID=(); I_IDX=(); I_SEV=(); I_DET=(); I_ARGS=(); I_ASKQ=(); I_ASKD=(); I_ASKC=(); I_CONF=(); I_ALSO=(); I_DROP=(); I_IMP=()
  for i in "${!KB[@]}"; do
    IFS=$US read -r -a F <<< "${KB[i]}"
    [ "${F[12]}" = "$1" ] || continue
    sd_applies "${F[2]}" || continue
    sd_eval_entry "$i"
  done
}
fx_need_running() {   # fx_need_running "what" : some fixes only make sense on the running system
  [ "$(rp_t)" = / ] && return 0
  echo "Doing $1 only works on the running system. Start the computer normally and run this again."
  return 1
}
fx_user() {   # run a command as the main user, inside their desktop session (sound, power mode...)
  local u uid; u=$(sd_user); uid=$(id -u "$u" 2>/dev/null)
  [ -n "$uid" ] || { echo "I could not find the user's session."; return 1; }
  rp_run runuser -u "$u" -- env "XDG_RUNTIME_DIR=/run/user/$uid" "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" "$@"
}
fx_disk_of() {   # the physical disk under a device (through LUKS / partitions)
  lsblk -rnso NAME,TYPE "$1" 2>/dev/null | awk '$2=="disk"{print "/dev/" $1; exit}'
}
fxb() {   # fxb RELPATH... : keep a copy of files before they are changed
  local T p; T=$(rp_t); [ -n "$RFX_BDIR" ] || return 0
  for p in "$@"; do
    [ -e "$T/$p" ] || continue
    if [ "$RP_DRY" = 1 ]; then printf '  [dry run] would run: cp -a --parents %s %s\n' "$p" "$RFX_BDIR/"; continue; fi
    mkdir -p "$RFX_BDIR"; ( cd "$T" && cp -a --parents "$p" "$RFX_BDIR/" ) 2>/dev/null && printf 'cp -a %s/%s %s/%s\n' "$RFX_BDIR" "$p" "$T" "$p" >> "$RFX_BDIR/UNDO.txt"
  done
  return 0
}
fxb_text() {   # fxb_text NAME TEXT : keep some information (like the current start-up list)
  [ -n "$RFX_BDIR" ] || return 0
  if [ "$RP_DRY" = 1 ]; then printf '  [dry run] would save %s in %s\n' "$1" "$RFX_BDIR"; return 0; fi
  mkdir -p "$RFX_BDIR"; printf '%s\n' "$2" > "$RFX_BDIR/$1"
}
fxb_list() { fxb_text "list-$1.txt" "$(ls -la "$(rp_t)/$1" 2>/dev/null)"; }
fx_ac_ok() {   # no heavy change on a nearly empty battery
  local b c; for b in /sys/class/power_supply/BAT*; do [ -r "$b/capacity" ] || continue
    c=$(cat "$b/capacity"); grep -q Discharging "$b/status" 2>/dev/null && [ "$c" -lt 30 ] && { echo "The battery is at ${c}% and not charging: plug in the charger first."; return 1; }; done
  return 0
}
fx_pkg_idle() {
  pgrep -x 'dnf|dnf5|rpm|apt|apt-get|dpkg|packagekitd' >/dev/null 2>&1 && { echo "Another update or install is running. Try again when it has finished."; return 1; }
  [ -e /system-update ] && { echo "Updates are waiting to be installed at the next restart."; return 1; }
  return 0
}

rp_fix_run() {
  local id=${1:-}; shift || true
  local fn=fx_${id#fix-}; fn=${fn//-/_}
  declare -F "$fn" >/dev/null || { echo "I do not know the fix '$id'. Known fixes: $RP_FIX_IDS"; return 2; }
  rp_fix_engine || { echo "The diagnosis files are missing, so I cannot check this fix."; return 2; }
  local T; T=$(rp_t)
  sd_reset_cache; sd_init_env
  local k=0 title what fixsum bak undo tm safe reboot=0 manual
  local -a F=()
  if [ "$id" = fix-backup-files ]; then   # the backup is not "a problem to detect": it is what you do first
    I_N=1; I_ID=(backup-first); I_DET=(""); I_ARGS=("")
    F=("backup-first" disks any quick x info 100 "Copy your files to another drive" "Your files are copied to another drive first, in case a drive fails." "" safe yes fix-backup-files "-" "Copy your documents, photos and settings to another drive. Nothing is changed on the drive being rescued." "This IS the backup." "Nothing on the drive being rescued is changed, so there is nothing to undo." "~10 min" "" "Copy your files by hand to a USB drive or another disk." "-" "-")
    SD_DET=""; SD_ARGS=()
  else
    rp_fix_detect "$id"
    if [ "$I_N" -eq 0 ]; then echo "NOTHING TO DO: the problem this fix is for is not there (it may already be fixed)."; return 0; fi
    IFS=$US read -r -a F <<< "${KB[${I_IDX[0]}]}"
    SD_DET=${I_DET[0]}; SD_ARGS=(); [ -n "${I_ARGS[0]}" ] && IFS=$US read -r -a SD_ARGS <<< "${I_ARGS[0]}"
  fi
  title=$(sd_tpl "${F[7]}"); what=$(sd_tpl "${F[8]}"); fixsum=$(sd_tpl "${F[14]}"); bak=${F[15]}; undo=${F[16]}; tm=${F[17]}; safe=${F[10]}; manual=$(sd_tpl "${F[19]}")
  [[ ${F[20]} == *reboot* ]] && reboot=1
  local -a args=("$@")
  if [ ${#args[@]} -eq 0 ] && [ ${#SD_ARGS[@]} -gt 0 ]; then args=("${SD_ARGS[@]}"); fi
  if [ ${#args[@]} -eq 0 ] && [ "${F[13]}" != "-" ] && [ -n "${F[13]}" ]; then read -r -a args <<< "${F[13]}"; fi
  echo; echo "== $title =="
  echo "What I found:  $what"
  echo "What I will do: $fixsum"
  echo "Saved first:   $bak"
  echo "How to undo:   $undo"
  echo "Time:          $tm"
  # --- a failing drive: only the backup itself may run
  if [ "$id" != fix-backup-files ]; then
    local dev disk st=${SL_FIX_DISK_STATE:-}
    if [ -z "$st" ]; then dev=$(rp_dev_of_path "$T"); disk=$(fx_disk_of "$dev"); [ -n "$disk" ] && st=$(rp_smart_state "$disk"); fi
    if [ "$st" = bad ] && [ "${RP_FIX_BACKED_UP:-}" != 1 ]; then
      echo "!! The drive this system lives on says it is failing. Repairs write to it and could destroy files that can still be saved."
      echo "!! Back up your files first (fix-backup-files or 'Rescue my files')."
      if [ "$RP_DRY" = 1 ]; then echo "(dry run: you would have to confirm your files are backed up)"
      elif [ -n "${RP_FIX_PREAPPROVED:-}" ] || [ ! -t 0 ]; then echo "REFUSED: not done, because the drive is failing and your files are not backed up yet."; return 2
      else slh_typed "I HAVE BACKED UP" "Type the words below only if your files are already safe somewhere else." || { echo "REFUSED: not done."; return 2; }; fi
    fi
  fi
  # --- approval
  if [ "$RP_DRY" = 1 ]; then echo "(dry run: nothing will be changed)"
  else
    if [ "$safe" = risky ]; then rp_typed "YES" "This one is risky: $what" || { echo "CANCELLED: nothing was changed."; return 2; }
    elif [ -z "${RP_FIX_PREAPPROVED:-}" ]; then slh_confirm "Go ahead?" || { echo "CANCELLED: nothing was changed."; return 2; }
    fi
  fi
  RFX_BDIR="$T/var/lib/secure-linux/repair-backup/$id-$(date +%Y%m%d-%H%M%S)"
  local rc=0
  "$fn" ${args[@]+"${args[@]}"} || rc=$?
  if [ "$RP_DRY" = 1 ]; then echo "DRY RUN: that is what would be done. Nothing was changed."; return 0; fi
  # --- did it work?
  sd_reset_cache; sd_init_env
  local okv=1
  if declare -F "fxv_${fn#fx_}" >/dev/null; then "fxv_${fn#fx_}" || okv=0
  else
    local ids="${I_ID[*]}"; rp_fix_detect "$id"
    local still=0 x y
    for x in $ids; do for y in "${I_ID[@]:-}"; do [ "$x" = "$y" ] && still=1; done; done
    [ "$still" = 1 ] && okv=0
  fi
  if [ "$rc" = 0 ] && [ "$okv" = 1 ]; then
    if [ "$reboot" = 1 ]; then echo "FIXED: $title. Restart the computer to finish."; else echo "FIXED: $title."; fi
    [ -s "$RFX_BDIR/UNDO.txt" ] && echo "Your old files are kept in ${RFX_BDIR#"${T%/}"} (UNDO.txt lists how to put them back)."
    return 0
  fi
  if [ "$rc" = 0 ] && [ "$reboot" = 1 ]; then echo "FIXED: the change was made. It takes effect after you restart the computer."; return 0; fi
  echo "COULD NOT FIX: $title."
  echo "What to do next: ${manual:-Run the check again and ask for help with the report.}"
  return 1
}

# ---------------------------------------------------------------- software
fx_rpmdb() {
  fxb var/lib/rpm/rpmdb.sqlite usr/lib/sysimage/rpm/rpmdb.sqlite
  rp_run_t rpm --rebuilddb
}
fx_pkg_repair() {
  fx_pkg_idle || return 1
  online_ok || { echo "There is no internet connection, so I cannot download software. Connect, then run this again."; return 1; }
  fx_target_rw || return 1
  if [ "$(sd_family)" = debian ]; then rp_run_t dpkg --configure -a; rp_run_t apt-get -f -y install
  else rp_run_t dnf -y remove --duplicates; rp_run_t dnf -y --setopt=skip_if_unavailable=True distro-sync --refresh; fi
}
fx_reset_failed() {
  fx_need_running "restarting services" || return 1
  local u
  for u in $(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}'); do
    case "$u" in *.mount|*.swap|*.device) continue ;; esac
    rp_run systemctl reset-failed "$u"; rp_run systemctl restart "$u"
  done
  rp_run systemctl reset-failed
}
fx_flatpak_repair() { rp_run flatpak repair --system; rp_run flatpak uninstall --unused -y; }
fx_autoremove() {
  fx_pkg_idle || return 1
  if [ "$(sd_family)" = debian ]; then rp_run_t apt-get -y autoremove; else rp_run_t dnf -y autoremove; fi
}
fx_repos_enable() {
  local T d f; T=$(rp_t); d="$T/etc/yum.repos.d"
  for f in fedora.repo fedora-updates.repo; do
    [ -r "$d/$f" ] || continue
    fxb "etc/yum.repos.d/$f"
    if [ "$RP_DRY" = 1 ]; then echo "  [dry run] would set enabled=1 in the main section of $d/$f"; continue; fi
    awk '/^\[/{sec=$0} (sec=="[fedora]" || sec=="[updates]") && /^enabled *= *0/ {print "enabled=1"; next} {print}' "$d/$f" > "$d/$f.new" && cat "$d/$f.new" > "$d/$f"; rm -f "$d/$f.new"
  done
}
fx_time_sync() {
  fx_need_running "setting the clock" || return 1
  rp_run timedatectl set-ntp true
  if systemctl list-unit-files 2>/dev/null | grep -q '^chronyd'; then rp_run systemctl restart chronyd; have chronyc && rp_run chronyc makestep; else rp_run systemctl restart systemd-timesyncd; fi
}
fx_fwupd_update() {
  fx_need_running "updating firmware" || return 1
  fx_ac_ok || return 1
  fx_pkg_idle || return 1
  rp_run fwupdmgr refresh --force; rp_run fwupdmgr update -y --no-reboot-check
}
fx_update_system() {
  fx_pkg_idle || return 1
  fx_ac_ok || return 1
  online_ok || { echo "There is no internet connection, so I cannot download updates. Connect, then run this again."; return 1; }
  [ "$(rp_t)" = / ] && have snapper && snapper list-configs 2>/dev/null | grep -q root && rp_run snapper -c root create -d "before secure-linux fix-update-system"
  if [ "$(sd_family)" = debian ]; then rp_run_t apt-get update; rp_run_t apt-get -y upgrade
  else rp_run_t dnf -y --setopt=skip_if_unavailable=True upgrade --refresh; fi
}

# ---------------------------------------------------------------- security and accounts
fx_firewall_on() {
  fx_need_running "switching the firewall on" || return 1
  if have firewall-cmd || [ -e /usr/lib/systemd/system/firewalld.service ]; then rp_run systemctl enable --now firewalld; else rp_run ufw --force enable; fi
}
fx_ssh_stop() {
  fx_need_running "switching remote access off" || return 1
  local u; for u in sshd ssh; do systemctl list-unit-files 2>/dev/null | grep -q "^$u.service" && rp_run systemctl disable --now "$u"; done
  return 0
}
fx_pwquality() {
  local f; f="$(rp_t)/etc/security/pwquality.conf"
  fxb etc/security/pwquality.conf
  if [ "$RP_DRY" = 1 ]; then echo "  [dry run] would change the minlen line in $f to: minlen = 10"; return 0; fi
  sed -i 's/^ *minlen *= *[0-9]* *$/minlen = 10/' "$f"
}
fx_faillock_reset() {
  fx_need_running "clearing wrong-password counts" || return 1
  local u; for u in $(faillock 2>/dev/null | sed -n 's/^\([a-z_][a-z0-9_-]*\):$/\1/p'); do rp_run faillock --user "$u" --reset; done
  return 0
}
fx_sudo_repair() {
  local T u grp f; T=$(rp_t); u=${1:-$(sd_user)}; f="$T/etc/sudoers"
  [ -n "$u" ] || { echo "I could not tell which account to make an administrator."; return 1; }
  grp=wheel; grep -q '^sudo:' "$T/etc/group" 2>/dev/null && grp=sudo
  fxb etc/sudoers etc/group
  fx_target_rw || return 1
  rp_run_t usermod -aG "$grp" "$u"
  rp_run chmod 0440 "$f"
  if [ "$RP_DRY" != 1 ] && ! visudo -c -f "$f" >/dev/null 2>&1; then
    echo "The sudo settings file has an error. Putting in the standard one (your old file is kept in the repair backup)."
    printf 'root ALL=(ALL) ALL\n%%%s ALL=(ALL) ALL\n' "$grp" > "$f"; chmod 0440 "$f"
  fi
  return 0
}
fx_home_perms() {
  local T u; T=$(rp_t); u=${1:-$(sd_user)}
  [ -n "$u" ] && [ -d "$T/home/$u" ] || { echo "I could not find the home folder."; return 1; }
  fxb_text root-owned-files.txt "$(find "$T/home/$u" -user root -not -path '*/.snapshots/*' 2>/dev/null | head -n 500)"
  rp_run find "$T/home/$u" -user root -not -path '*/.snapshots/*' -exec chown "$u:$u" {} +
}
fx_recovery_key() {
  fx_need_running "making a recovery key" || return 1
  have secure-linux-recovery-key || { echo "secure-linux-recovery-key is not installed."; return 1; }
  rp_run secure-linux-recovery-key create
}
fx_ha_token_perms() {
  local f; f=$(sd_choice ha_token_file /etc/secure-linux/ha-token); f="$(rp_t)$f"
  [ -e "$f" ] || { echo "The key file was not found."; return 1; }
  rp_run chmod 600 "$f"
}

# ---------------------------------------------------------------- drivers and firmware
fx_firmware_reinstall() {
  online_ok || { echo "There is no internet connection, so I cannot download the firmware. Use a cable or tether a phone by USB, then run this again."; return 1; }
  fx_target_rw || return 1
  if [ "$(sd_family)" = debian ]; then rp_run_t apt-get install -y --reinstall firmware-linux firmware-sof-signed
  else rp_run_t dnf -y reinstall linux-firmware alsa-sof-firmware; fi
}
fx_drivers_install() {
  fx_need_running "installing drivers" || return 1
  online_ok || { echo "There is no internet connection, so I cannot download drivers. Use a cable or tether a phone by USB, then run this again."; return 1; }
  have secure-linux-drivers || { echo "secure-linux-drivers is not installed."; return 1; }
  rp_run secure-linux-drivers install
  have secure-linux-parts && rp_run secure-linux-parts --install --no-drivers
  return 0
}
fx_gpu_userland() { fx_drivers_install; }
fx_sane() {
  online_ok || { echo "There is no internet connection."; return 1; }
  if [ "$(sd_family)" = debian ]; then rp_run_t apt-get install -y sane-utils sane-airscan; else rp_run_t dnf -y install sane-backends sane-airscan simple-scan; fi
}

# ---------------------------------------------------------------- network, sound, power, input, devices (running system)
fx_wifi_country() {
  local cc=${1:-}
  [[ $cc =~ ^[A-Z]{2}$ ]] || { echo "I need a two-letter country code such as AU."; return 1; }
  fx_need_running "setting the Wi-Fi country" || return 1
  fxb etc/modprobe.d/secure-linux-wifi-country.conf
  rp_run iw reg set "$cc"
  if [ "$RP_DRY" = 1 ]; then echo "  [dry run] would write /etc/modprobe.d/secure-linux-wifi-country.conf: options cfg80211 ieee80211_regdom=$cc"
  else printf 'options cfg80211 ieee80211_regdom=%s\n' "$cc" > /etc/modprobe.d/secure-linux-wifi-country.conf; fi
}
fx_dns_flush() { fx_need_running "clearing the name-lookup memory" || return 1; rp_run resolvectl flush-caches; rp_run systemctl restart systemd-resolved; }
fx_active_con() { nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | grep -vE ':(loopback|bridge|tun)' | head -n1; }
fx_mtu() {
  fx_need_running "changing the connection" || return 1
  local mtu=${1:-1400} line con typ; line=$(fx_active_con); con=${line%%:*}; typ=${line##*:}
  [ -n "$con" ] || { echo "I could not find the active connection."; return 1; }
  case "$typ" in *wireless*) typ=802-11-wireless ;; *) typ=802-3-ethernet ;; esac
  rp_run nmcli connection modify "$con" "$typ.mtu" "$mtu"; rp_run nmcli connection up "$con"
}
fx_ipv6_off() {
  fx_need_running "changing the connection" || return 1
  local line con; line=$(fx_active_con); con=${line%%:*}
  [ -n "$con" ] || { echo "I could not find the active connection."; return 1; }
  rp_run nmcli connection modify "$con" ipv6.method disabled; rp_run nmcli connection up "$con"
}
fx_vpn_killswitch_off() { fx_need_running "turning the VPN off" || return 1; have secure-linux-vpn || { echo "secure-linux-vpn is not installed."; return 1; }; rp_run secure-linux-vpn off; }
fx_bluetooth_start() { rp_run_t systemctl enable --now bluetooth; }
fx_nm_start() { rp_run_t systemctl enable --now NetworkManager; }
fx_rfkill() { fx_need_running "switching the radios on" || return 1; rp_run rfkill unblock all; }
fx_unmute() {
  fx_need_running "changing the sound" || return 1
  case "${1:-speakers}" in
    mic) fx_user wpctl set-mute @DEFAULT_AUDIO_SOURCE@ 0 ;;
    *) fx_user wpctl set-mute @DEFAULT_AUDIO_SINK@ 0; fx_user wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.4 ;;
  esac
}
fx_audio_default() { fx_need_running "changing the sound" || return 1; [[ ${1:-} =~ ^[0-9]+$ ]] || { echo "I do not know which sound output to use."; return 1; }; fx_user wpctl set-default "$1"; }
fx_restart_audio() { fx_need_running "restarting the sound" || return 1; fx_user systemctl --user restart pipewire pipewire-pulse wireplumber; }
fx_bt_a2dp() { fx_need_running "changing the headphones' mode" || return 1; [ -n "${1:-}" ] || return 1; fx_user pactl set-card-profile "$1" a2dp-sink; }
fx_power_profile() { fx_need_running "changing the power mode" || return 1; fx_user powerprofilesctl set "${1:-balanced}"; }
fx_charge_limit() { fx_need_running "setting the charge limit" || return 1; have secure-linux-battery || { echo "secure-linux-battery is not installed."; return 1; }; rp_run secure-linux-battery limit "${1:-80}"; }
fx_keymap_sync() {
  local lay=${1:-}; [ -n "$lay" ] || { echo "I do not know the layout."; return 1; }
  fx_need_running "changing the keyboard layout" || return 1
  fxb etc/vconsole.conf
  rp_run localectl set-keymap "$lay" && { [ "$(sd_family)" = fedora ] && rp_run dracut --force; }
  return 0
}
fx_cups_start() { rp_run_t systemctl enable --now cups.socket; }
fx_thunderbolt_enroll() {
  fx_need_running "approving a Thunderbolt device" || return 1
  local uuid; uuid=$(boltctl list 2>/dev/null | awk '/uuid:/{u=$NF} /status:.*(authorizing|connected)/ {print u; exit}')
  [ -n "$uuid" ] || { echo "No Thunderbolt device is waiting."; return 1; }
  rp_run boltctl enroll "$uuid"
}
