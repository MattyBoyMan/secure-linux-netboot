#!/bin/bash
# smartd hook (lite profile), installed as /usr/local/libexec/secure-linux-smartd-alert by 35-storage.sh.
# smartd runs it with SMARTD_DEVICE, SMARTD_FAILTYPE, SMARTD_MESSAGE set (see `man smartd.conf`, -M exec).
# 1) Always logs to the journal (tag secure-linux-smartd); secure-linux-check turns recent entries into an
#    alert, which works even if SELinux stops smartd (fsdaemon_t) from writing to /var/lib/secure-linux.
# 2) Tries to raise the alert directly too.
dev=${SMARTD_DEVICE:-disk}; type=${SMARTD_FAILTYPE:-problem}; msg=${SMARTD_MESSAGE:-}
logger -t secure-linux-smartd -- "$dev|$type|$msg" 2>/dev/null
SL_ROOT=${SL_ROOT:-/usr/local/lib/secure-linux}
if . "$SL_ROOT/lib/common.sh" 2>/dev/null; then
  id="disk-health-smartd"
  case "$type" in
    Temperature) title="A disk is getting very hot" ;;
    *) title="A disk may be failing" ;;
  esac
  sl_alert "$id" "$title" \
    "The disk ${dev##*/} reported a problem ($type). Back up your files soon, then choose 'Create a diagnostics file' and ask for help." \
    "Open 'Secure Linux Status & Fixes' and choose 'Create a diagnostics file'." 2>/dev/null
fi
exit 0
