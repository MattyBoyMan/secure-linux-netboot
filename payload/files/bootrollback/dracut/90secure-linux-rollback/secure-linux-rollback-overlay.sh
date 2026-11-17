#!/bin/sh
# Secure Linux boot rollback: dracut pre-pivot hook (runs inside the start-up file, before the system starts).
# Does nothing unless the kernel command line has rd.securelinux.rollback=<snapshot number>.
# Then the chosen read-only snapshot (already mounted at $NEWROOT by rootflags=subvol=...) is put UNDER a
# writable layer kept in memory (overlayfs, upper layer on /run). Nothing on the disk is changed by using the
# earlier version; every system change made during that session is lost at the next restart.
# The same pattern as dracut's own overlayfs module (bind the root aside, unmount, mount the overlay),
# written here because dracut 108 (Fedora 44) passes rootflags= into the overlay mount (fixed in dracut 109,
# commit deeb670), which breaks a btrfs subvol= start.
# Optional: rd.securelinux.rootsubvol=<name> and rd.securelinux.nested=<a,b> mount the CURRENT nested
# subvolumes (for example var/lib/flatpak, the app store apps) read-only, so those apps still open.

command -v getarg > /dev/null || . /lib/dracut-lib.sh

sl_snap=$(getarg rd.securelinux.rollback=)
[ -n "$sl_snap" ] || return 0 2> /dev/null || exit 0
case "$sl_snap" in *[!0-9]*)
    warn "secure-linux-rollback: bad snapshot number '$sl_snap'; starting without the memory layer"
    return 0 2> /dev/null || exit 0
    ;;
esac
[ -n "${NEWROOT:-}" ] || NEWROOT=/sysroot
SL_PROC_MOUNTS=${SL_PROC_MOUNTS:-/proc/mounts} # tests point these two at a fixture
SL_RUN=${SL_RUN:-/run}

sl_mounted() { # sl_mounted DIR   is DIR a mount point right now?
    while read -r _d _m _rest; do
        [ "$_m" = "$1" ] && return 0
    done < "$SL_PROC_MOUNTS"
    return 1
}

# The boot entry masks boot.mount and boot-efi.mount (so /boot is left alone during an earlier day). systemd's
# fstab-generator makes local-fs.target REQUIRE every fstab mount without "nofail", and a masked unit that is
# required stops the whole local-fs.target job (systemd src/core/transaction.c), so /home might not be mounted.
# So the session gets an fstab whose /boot lines say "noauto,nofail". Only the copy in memory changes, never the
# disk. Shell built-ins and mount only (nothing else needs to be in the start-up file).
sl_fstab_line() { # sl_fstab_line LINE   print LINE with noauto,nofail added if it mounts /boot or below; else fail
    _sl_ifs=$IFS
    IFS=' 	'
    set -f
    set -- $1
    set +f
    IFS=$_sl_ifs
    case "${1:-#}" in \#*) return 1 ;; esac
    [ $# -ge 4 ] || return 1
    case "$2" in /boot | /boot/*) ;; *) return 1 ;; esac
    printf '%s\t%s\t%s\t%s,noauto,nofail\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-0}" "${6:-0}"
}
sl_boot_fstab() { # sl_boot_fstab overlay|bind   overlay: write through the memory layer; bind: lay a memory copy over it
    _sl_f=$NEWROOT/etc/fstab
    [ -f "$_sl_f" ] || return 0
    mkdir -p "$SLR" && : > "$SLR/fstab" || return 0
    while IFS= read -r _sl_l || [ -n "$_sl_l" ]; do
        sl_fstab_line "$_sl_l" >> "$SLR/fstab" || printf '%s\n' "$_sl_l" >> "$SLR/fstab"
    done < "$_sl_f"
    if [ "$1" = overlay ]; then
        # write in place (keeps the file's security label); if that fails, the memory copy is laid over it below
        if { while IFS= read -r _sl_l || [ -n "$_sl_l" ]; do printf '%s\n' "$_sl_l"; done < "$SLR/fstab" > "$_sl_f"; } 2> /dev/null; then
            return 0
        fi
    fi
    mount --bind "$SLR/fstab" "$_sl_f" \
        || warn "secure-linux-rollback: could not set /boot to stay unmounted (not fatal)"
    return 0
}

sl_mounted "$NEWROOT" || {
    warn "secure-linux-rollback: $NEWROOT is not mounted; nothing done"
    return 0 2> /dev/null || exit 0
}
# Already done (the hook can be called twice): leave it.
sl_mounted "$SL_RUN/secure-linux-rollback/lower" && { return 0 2> /dev/null || exit 0; }

SLR=$SL_RUN/secure-linux-rollback
mkdir -p "$SLR/lower" "$SLR/upper" "$SLR/work"
if ! mount --bind "$NEWROOT" "$SLR/lower"; then
    warn "secure-linux-rollback: could not set the snapshot aside; starting it read-only"
    sl_boot_fstab bind
    return 0 2> /dev/null || exit 0
fi
mount -o remount,bind,ro "$SLR/lower" 2> /dev/null
if ! umount "$NEWROOT"; then
    umount "$SLR/lower" 2> /dev/null
    warn "secure-linux-rollback: could not swap the root; starting the snapshot read-only"
    sl_boot_fstab bind
    return 0 2> /dev/null || exit 0
fi
if ! mount -t overlay secure-linux-rollback -o "lowerdir=$SLR/lower,upperdir=$SLR/upper,workdir=$SLR/work" "$NEWROOT"; then
    warn "secure-linux-rollback: the memory layer failed; starting the snapshot read-only"
    mount --bind "$SLR/lower" "$NEWROOT"
    sl_boot_fstab bind
    return 0 2> /dev/null || exit 0
fi
echo "$sl_snap" > "$SL_RUN/secure-linux-rollback-session"
sl_boot_fstab overlay

# Current nested subvolumes (never part of a snapshot), read-only, so app store apps still start.
sl_rs=$(getarg rd.securelinux.rootsubvol=)
sl_nested=$(getarg rd.securelinux.nested=)
sl_dev=""
while read -r _d _m _rest; do
    [ "$_m" = "$SLR/lower" ] && sl_dev=$_d
done < "$SL_PROC_MOUNTS"
if [ -n "$sl_rs" ] && [ -n "$sl_nested" ] && [ -n "$sl_dev" ]; then
    _oldifs=$IFS
    IFS=,
    for _p in $sl_nested; do
        IFS=$_oldifs
        case "$_p" in "" | /* | *..* | *[!A-Za-z0-9._/-]*) continue ;; esac
        [ -d "$NEWROOT/$_p" ] || continue
        mount -o "ro,subvol=$sl_rs/$_p" "$sl_dev" "$NEWROOT/$_p" 2> /dev/null \
            || warn "secure-linux-rollback: could not show $_p (not fatal)"
        IFS=,
    done
    IFS=$_oldifs
fi
return 0 2> /dev/null || exit 0
