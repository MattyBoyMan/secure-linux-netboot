#!/bin/bash
# 35-storage.sh (owner: system) - disk health (B3): SMART monitoring, TRIM through LUKS, weekly fstrim.
#   full : plasma-disks (KDE tells you about a failing disk) + secure-linux-check reads SMART every 6 h.
#   lite : smartd watches the disks; problems run a hook that raises a desktop alert.
#   all  : monthly Btrfs scrub = secure-linux-btrfs-scrub.timer (files/system) running `secure-linux-check --scrub`,
#          which alerts on errors (alert id scrub-errors).
# Sourced by setup.sh: never `exit`.
[ "$SL_MODE" = early ] && return 0

_sys_profile=$(sl_profile)
sl_is_atomic && _sys_profile=atomic

sl_step "Disk health monitoring"
if [ "$_sys_profile" != atomic ]; then
  sl_dnf_install smartmontools
  if [ "$_sys_profile" = full ]; then
    sl_dnf_install plasma-disks
  else
    # smartd: check every disk; on trouble run our hook (which raises a desktop alert and logs to the journal).
    # -m <nomailer> + -M exec = run the hook instead of sending mail; -M daily = repeat while the problem lasts.
    sl_install_file "$SL_ROOT/files/system/smartd-alert.sh" /usr/local/libexec/secure-linux-smartd-alert 0755
    command -v restorecon >/dev/null 2>&1 && restorecon /usr/local/libexec/secure-linux-smartd-alert >/dev/null 2>&1
    sl_write_file /etc/smartmontools/smartd.conf <<'EOF'
# Secure Linux: watch all disks (health, errors, wear); short self-test every Sunday at noon.
# Problems run /usr/local/libexec/secure-linux-smartd-alert -> desktop notification.
DEVICESCAN -a -o on -S on -n standby,q -s S/../../7/12 -m <nomailer> -M daily -M exec /usr/local/libexec/secure-linux-smartd-alert
EOF
    sl_enable smartd.service
    try systemctl restart smartd.service
  fi
fi

sl_step "Keeping the SSD fast (TRIM)"
sl_enable fstrim.timer

# TRIM must pass through the disk encryption (dm-crypt "allow_discards"), otherwise fstrim does nothing.
# 1) `cryptsetup refresh --allow-discards --persistent NAME` changes the live mapping and stores the flag in the
#    LUKS2 header. VERIFY: for LUKS2 it normally needs the passphrase unless the volume key is in the kernel
#    keyring; we run it without a terminal, so it may fail - that's expected and not recorded as a failure.
# 2) Fallback that always works from the next start: add "discard" to /etc/crypttab and rebuild the initramfs.
_sys_crypttab_changed=""
if command -v dmsetup >/dev/null 2>&1; then
  while read -r _sys_name _sys_rest; do
    _sys_name=${_sys_name%:}
    [ -n "$_sys_name" ] || continue
    case " $_sys_rest " in *" allow_discards "*) echo "TRIM already on for $_sys_name"; continue ;; esac
    echo ">> cryptsetup refresh --allow-discards --persistent $_sys_name"
    if timeout 30 cryptsetup refresh --allow-discards --persistent "$_sys_name" </dev/null; then
      echo "TRIM switched on for $_sys_name"
      continue
    fi
    echo "cryptsetup refresh needs the passphrase; using /etc/crypttab instead (active after the next restart)"
    if [ -f /etc/crypttab ] && awk -v n="$_sys_name" '$1==n' /etc/crypttab | grep -q . \
       && ! awk -v n="$_sys_name" '$1==n {print $4}' /etc/crypttab | grep -qw discard; then
      cp -p /etc/crypttab /etc/crypttab.secure-linux-bak
      awk -v n="$_sys_name" 'BEGIN{OFS=" "}
        $1==n { if ($3=="") $3="none"; if ($4=="" ) $4="discard"; else $4=$4",discard" } { print }' \
        /etc/crypttab.secure-linux-bak > /etc/crypttab
      _sys_crypttab_changed=1
    fi
  done < <(dmsetup table --target crypt 2>/dev/null)
fi
if [ -n "$_sys_crypttab_changed" ]; then
  if [ "$_sys_profile" = atomic ]; then
    try rpm-ostree initramfs-etc --track=/etc/crypttab    # VERIFY: atomic copies /etc/crypttab into the initramfs
  else
    try dracut -f
  fi
fi

# ---------------------------------------------------------------- sleep / hibernate
sl_step "Sleep and hibernate"
# MT7922 Wi-Fi resume workaround hook (does nothing unless the hardware test set its flag file).
# systemd runs hooks from /usr/lib/systemd/system-sleep; atomic has a read-only /usr, so /etc (VERIFY: newer
# systemd also reads /etc/systemd/system-sleep).
if [ "$_sys_profile" = atomic ]; then _sys_hookdir=/etc/systemd/system-sleep; else _sys_hookdir=/usr/lib/systemd/system-sleep; fi
sl_install_file "$SL_ROOT/files/system/system-sleep/secure-linux-mt7921e" "$_sys_hookdir/secure-linux-mt7921e" 0755

# Hibernate when the lid closes. Rule (secure-linux-hibernate wanted): explicit choice hibernate, else
# secureboot_intent=off -> on-lid, =on -> no (lid sleeps, no alerts), unset -> on-lid on the full profile.
# Secure Boot still ON -> lid keeps sleeping and alert hibernate-needs-secureboot-off explains; once Secure Boot is
# off, this step (repair) or the health check switches it on by itself.
_sys_hib=no
[ -x "$SL_ROOT/bin/secure-linux-hibernate" ] && _sys_hib=$("$SL_ROOT/bin/secure-linux-hibernate" wanted)
if [ "$_sys_hib" != no ] && [ "$_sys_profile" != atomic ]; then
  sl_dnf_install policycoreutils-python-utils btrfs-progs
  if "$SL_ROOT/bin/secure-linux-hibernate" active >/dev/null 2>&1; then
    echo "Hibernate on lid close is already set up"
  else
    "$SL_ROOT/bin/secure-linux-hibernate" enable "$_sys_hib" --auto; _sys_rc=$?
    case $_sys_rc in
      0) ;;
      3) echo "Hibernate waits for Secure Boot to be switched off (alert raised)" ;;
      *) echo "FAILED ($_sys_rc): secure-linux-hibernate enable $_sys_hib" | tee -a "$SL_FAILS" >&2 ;;
    esac
  fi
fi

unset _sys_profile _sys_name _sys_rest _sys_crypttab_changed _sys_hookdir _sys_hib _sys_rc
return 0
