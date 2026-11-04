#!/bin/bash
# guest-reset.sh (comfort): give the Guest account a brand-new, empty home folder.
# Called as root:
#   at boot, before the login screen (secure-linux-guest-reset.service)       guest-reset.sh boot
#   after the guest logs out (ExecStopPost of user@<guest uid>.service)       guest-reset.sh logout
# The home is a RAM disk (tmpfs): whatever the guest did is gone at logout or power-off, and nothing they
# saved ever touches the real disk. Safety: only ever touches /home/guest, only for the account "guest",
# and never while the guest still has a session.
set -u
G=guest
H=${SL_TEST_SYSROOT:-}/home/$G
entry=$(getent passwd "$G") || exit 0
uid=$(echo "$entry" | cut -d: -f3); gid=$(echo "$entry" | cut -d: -f4); home=$(echo "$entry" | cut -d: -f6)
[ "$home" = "/home/$G" ] || { echo "guest-reset: unexpected home '$home', not touching it" >&2; exit 1; }
[ "$uid" -ge 1000 ] 2>/dev/null || { echo "guest-reset: '$G' is not a normal account" >&2; exit 1; }

# Still logged in (e.g. a second session)? Then leave everything alone.
if command -v loginctl >/dev/null 2>&1; then
  case $(loginctl show-user "$G" -p State --value 2>/dev/null) in active|online) exit 0 ;; esac
fi
# Left-over background programs of the guest would keep files open
pkill -KILL -u "$uid" 2>/dev/null; sleep 1

if mountpoint -q "$H" 2>/dev/null; then umount "$H" 2>/dev/null || umount -l "$H"; fi
mkdir -p "$H"
mount -t tmpfs -o "size=25%,mode=0700,uid=$uid,gid=$gid,nosuid,nodev" secure-linux-guest "$H" || exit 1
cp -a /etc/skel/. "$H"/ 2>/dev/null
cat > "$H/README - Guest account.txt" <<'EOF'
Welcome! This is the Guest account.

Everything you save here is deleted when you log out or the computer restarts.
Save anything you want to keep to a USB stick, or email it to yourself.
EOF
chown -R "$uid:$gid" "$H"
command -v restorecon >/dev/null 2>&1 && restorecon -R "$H" >/dev/null 2>&1
# The guest's temporary files elsewhere
find "${SL_TEST_SYSROOT:-}/tmp" "${SL_TEST_SYSROOT:-}/var/tmp" -xdev -mindepth 1 -user "$uid" -delete 2>/dev/null
exit 0
