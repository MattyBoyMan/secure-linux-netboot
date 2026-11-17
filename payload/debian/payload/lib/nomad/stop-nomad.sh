#!/usr/bin/env bash
# stop-nomad.sh - stop Project NOMAD safely so the drive can be unplugged.
#   sudo bash stop-nomad.sh
# Stops NOMAD's containers, its private Podman service, drive mirror and home-network login gate (only the
# processes start-nomad.sh recorded), removes NOMAD's firewall table, and closes the data file on the drive.
# Your NOMAD data (library, notes, AI chats, maps) is kept.
set -u
RUN=${NOMAD_RUN_DIR:-/run/nomad}
say() { printf '%s\n' "$*"; }

if [ "${NOMAD_TEST:-}" != 1 ] && [ "$(id -u)" != 0 ]; then
  command -v sudo >/dev/null 2>&1 && exec sudo -- bash "${BASH_SOURCE[0]}" "$@"
  say "Please run me as the administrator:  sudo bash stop-nomad.sh"; exit 1
fi

ENGINE="" STORE=""
[ -f "$RUN/state" ] && read -r ENGINE STORE _ _ < "$RUN/state"
E=()
if [ -S "$RUN/podman.sock" ] || { [ "${NOMAD_TEST:-}" = 1 ] && [ -e "$RUN/podman.sock" ]; }; then
  E=(podman --remote --url "unix://$RUN/podman.sock")
elif [ "$ENGINE" = docker ] || { [ -z "$ENGINE" ] && command -v docker >/dev/null 2>&1; }; then E=(docker)
elif command -v podman >/dev/null 2>&1; then E=(podman)
fi

if [ ${#E[@]} -gt 0 ]; then
  names=$("${E[@]}" ps --filter "name=^nomad_" --format '{{.Names}}' 2>/dev/null)
  if [ -n "$names" ]; then
    say "Stopping NOMAD:"
    # apps first, then the Command Center, then database and cache
    for c in $names; do
      case "$c" in nomad_admin|nomad_mysql|nomad_redis|nomad_disk_collector) ;; *) say "  $c"; "${E[@]}" stop -t 20 "$c" >/dev/null 2>&1 ;; esac
    done
    for c in nomad_disk_collector nomad_admin nomad_mysql nomad_redis; do
      if printf '%s\n' $names | grep -qx "$c"; then say "  $c"; "${E[@]}" stop -t 30 "$c" >/dev/null 2>&1; fi
    done
  else
    say "NOMAD is not running."
  fi
fi

# only the exact processes start-nomad.sh started (recorded PIDs), never by name
for f in gate podman-service mirror; do
  if [ -f "$RUN/$f.pid" ]; then
    pid=$(cat "$RUN/$f.pid")
    case "$pid" in
      ''|*[!0-9]*) ;;
      *) # never signal a process that is not ours (PID reused): check its command line when we can
         if [ -r "/proc/$pid/cmdline" ] && ! tr '\000' ' ' < "/proc/$pid/cmdline" | grep -qE 'nomad_mirror[.]py|system service'; then
           say "  (process $pid is no longer NOMAD's; left alone)"
         else
           env kill "$pid" 2>/dev/null
           # wait (max 20 s) until it has really exited, so the data file is free to close
           for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
             [ -d "/proc/$pid" ] || break; sleep 1
           done
         fi ;;
    esac
    rm -f "$RUN/$f.pid"
  fi
done
rm -f "$RUN/podman.sock"

command -v nft >/dev/null 2>&1 && nft list table inet nomad_guard >/dev/null 2>&1 && nft delete table inet nomad_guard

if mountpoint -q "$RUN/data" 2>/dev/null; then
  sync
  if umount -R "$RUN/data" 2>/dev/null; then say "Closed NOMAD's data file on the drive."
  else say "NOTE: NOMAD's data file is still busy; wait a few seconds and run me again before unplugging."; exit 2; fi
fi
rm -f "$RUN/state" "$RUN/url" "$RUN/script-dir"
say "NOMAD is stopped. It is now safe to unplug the drive (use 'Eject' in the file manager)."
