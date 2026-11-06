#!/bin/bash
# 00-early.sh (owner: system) - GENERIC installer for every area. Runs in ALL modes.
#   bin/secure-linux-*                 -> /usr/local/bin (0755)
#   files/<area>/applications/*        -> /usr/share/applications (atomic: /usr/local/share/applications)
#   files/<area>/autostart/*           -> /etc/xdg/autostart
#   files/<area>/systemd/system/**     -> /etc/systemd/system   (sub-folders such as foo.service.d/ kept)
#   files/<area>/systemd/user/**       -> /etc/systemd/user
#   files/<area>/enable-system.list    -> systemctl enable (+ --now outside the installer)
#   files/<area>/enable-user.list      -> systemctl --global enable
#   files/system/polkit/*.rules        -> /etc/polkit-1/rules.d (lets "Check again" run without a password)
#   files/system/polkit/*.policy       -> /usr/share/polkit-1/actions (clear password prompts for the pkexec helpers)
# SL_MODE=early (installer chroot): no daemon-reload, no --now, no network.
# SL_TEST_SYSROOT (optional, for tests only): prefix put in front of every install path.
# Sourced by setup.sh: never `exit`.

_sys_d=${SL_TEST_SYSROOT:-}
# atomic: /usr is read-only, so menu entries go to /usr/local/share/applications
if sl_is_atomic; then _sys_apps=/usr/local/share/applications; else _sys_apps=/usr/share/applications; fi

sl_step "Installing Secure Linux helpers, timers and menu entries"

# Shared state folders (other areas write alerts/events here too)
mkdir -p "$SL_STATE/alerts.d" "$SL_STATE/events.d" "$SL_LOGDIR/clamscan" "$SL_ETC"
chmod 0755 "$SL_STATE" "$SL_STATE/alerts.d" "$SL_STATE/events.d" "$SL_LOGDIR" "$SL_LOGDIR/clamscan" 2>/dev/null

_sys_put() {   # _sys_put SRC DEST MODE   (sl_install_file: keeps a user-edited copy in repair mode)
  sl_install_file "$1" "$_sys_d$2" "$3" || echo "FAILED: install $2" | tee -a "$SL_FAILS" >&2
}
_sys_put_tree() {   # _sys_put_tree SRCDIR DESTDIR   copy every file below SRCDIR, keeping sub-folders
  local src=$1 dest=$2 f
  [ -d "$src" ] || return 0
  while IFS= read -r f; do
    _sys_put "$f" "$dest/${f#"$src"/}" 0644
  done < <(find "$src" -type f | sort)
}

# --- helper commands
for _sys_f in "$SL_ROOT"/bin/secure-linux-*; do
  [ -f "$_sys_f" ] || continue
  _sys_put "$_sys_f" "/usr/local/bin/${_sys_f##*/}" 0755
done

# Flipper Zero Backup & Files: the executable resolves its modules beside /usr/local/bin.
# Install the complete standard-library-only app now, before networking or package installation.
_sys_put "$SL_ROOT/lib/release_manifest.py" /usr/local/lib/release_manifest.py 0644
while IFS= read -r _sys_f; do
  _sys_put "$_sys_f" "/usr/local/lib/flipper-companion/${_sys_f#"$SL_ROOT/lib/flipper-companion"/}" 0644
done < <(find "$SL_ROOT/lib/flipper-companion" -type f ! -path '*/__pycache__/*' ! -name '*.pyc' ! -name '*.pyo' | sort)

# --- per-area files
for _sys_area in "$SL_ROOT"/files/*/; do
  [ -d "$_sys_area" ] || continue
  _sys_area=${_sys_area%/}
  for _sys_f in "$_sys_area"/applications/*.desktop; do
    [ -f "$_sys_f" ] && _sys_put "$_sys_f" "$_sys_apps/${_sys_f##*/}" 0644
  done
  for _sys_f in "$_sys_area"/autostart/*.desktop; do
    [ -f "$_sys_f" ] && _sys_put "$_sys_f" "/etc/xdg/autostart/${_sys_f##*/}" 0644
  done
  _sys_put_tree "$_sys_area/systemd/system" /etc/systemd/system
  _sys_put_tree "$_sys_area/systemd/user" /etc/systemd/user
done
for _sys_f in "$SL_ROOT"/files/system/polkit/*.rules; do
  [ -f "$_sys_f" ] && _sys_put "$_sys_f" "/etc/polkit-1/rules.d/${_sys_f##*/}" 0644
done
# password prompts with a clear message for every helper that re-runs itself with pkexec (org.securelinux.system.policy)
for _sys_f in "$SL_ROOT"/files/system/polkit/*.policy; do
  [ -f "$_sys_f" ] && _sys_put "$_sys_f" "/usr/share/polkit-1/actions/${_sys_f##*/}" 0644
done

# SELinux labels for the new files (harmless if SELinux is off)
if [ -z "$_sys_d" ] && command -v restorecon >/dev/null 2>&1; then
  restorecon -R /usr/local/bin /usr/local/lib/flipper-companion /usr/local/lib/release_manifest.py \
    /etc/systemd/system /etc/systemd/user "$_sys_apps" /etc/xdg/autostart \
    /etc/polkit-1/rules.d /usr/share/polkit-1/actions "$SL_STATE" "$SL_LOGDIR" >/dev/null 2>&1
fi

# --- enable units
[ "$SL_MODE" = early ] || try systemctl daemon-reload
_sys_units() {   # print the unit names in a list file (comments and blank lines ignored)
  sed -e 's/#.*//' -e 's/[[:space:]]//g' "$1" | grep -v '^$'
}
for _sys_list in "$SL_ROOT"/files/*/enable-system.list; do
  [ -f "$_sys_list" ] || continue
  while IFS= read -r _sys_u; do sl_enable "$_sys_u"; done < <(_sys_units "$_sys_list")
done
for _sys_list in "$SL_ROOT"/files/*/enable-user.list; do
  [ -f "$_sys_list" ] || continue
  while IFS= read -r _sys_u; do try systemctl --global enable "$_sys_u"; done < <(_sys_units "$_sys_list")
done

unset _sys_f _sys_area _sys_list _sys_u _sys_apps
return 0
