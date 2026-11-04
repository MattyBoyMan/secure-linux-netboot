#!/bin/bash
# 00-early.sh (Debian) - GENERIC installer for every area, same rules as the Fedora 00-early.sh. Runs in ALL modes.
#   bin/secure-linux-*                 -> /usr/local/bin (0755)
#   files/<area>/applications/*        -> /usr/share/applications
#   files/<area>/autostart/*           -> /etc/xdg/autostart
#   files/<area>/systemd/system/**     -> /etc/systemd/system
#   files/<area>/systemd/user/**       -> /etc/systemd/user
#   files/<area>/enable-system.list    -> systemctl enable (+ --now outside the installer)
#   files/<area>/enable-user.list      -> systemctl --global enable
#   files/system/polkit/*.rules        -> /etc/polkit-1/rules.d
# SL_MODE=early (installer chroot from the preseed late_command): no daemon-reload, no --now, no network.
# Sourced by setup.sh: never `exit`.

sl_step "Installing Secure Linux helpers, timers and menu entries"
mkdir -p "$SL_STATE/alerts.d" "$SL_STATE/events.d" "$SL_ETC"
chmod 0755 "$SL_STATE" "$SL_STATE/alerts.d" "$SL_STATE/events.d" "$SL_LOGDIR" 2>/dev/null

_e_put() { sl_install_file "$1" "$R$2" "$3" || echo "FAILED: install $2" | tee -a "$SL_FAILS" >&2; }
_e_tree() {   # _e_tree SRCDIR DESTDIR   every file below SRCDIR, keeping sub-folders
  local src=$1 dest=$2 f
  [ -d "$src" ] || return 0
  while IFS= read -r f; do _e_put "$f" "$dest/${f#"$src"/}" 0644; done < <(find "$src" -type f | sort)
}

for _e_f in "$SL_ROOT"/bin/secure-linux-*; do
  [ -f "$_e_f" ] && _e_put "$_e_f" "/usr/local/bin/${_e_f##*/}" 0755
done
for _e_area in "$SL_ROOT"/files/*/; do
  [ -d "$_e_area" ] || continue
  _e_area=${_e_area%/}
  for _e_f in "$_e_area"/applications/*.desktop; do [ -f "$_e_f" ] && _e_put "$_e_f" "/usr/share/applications/${_e_f##*/}" 0644; done
  for _e_f in "$_e_area"/autostart/*.desktop; do [ -f "$_e_f" ] && _e_put "$_e_f" "/etc/xdg/autostart/${_e_f##*/}" 0644; done
  _e_tree "$_e_area/systemd/system" /etc/systemd/system
  _e_tree "$_e_area/systemd/user" /etc/systemd/user
done
for _e_f in "$SL_ROOT"/files/system/polkit/*.rules; do
  [ -f "$_e_f" ] && _e_put "$_e_f" "/etc/polkit-1/rules.d/${_e_f##*/}" 0644
done

[ "$SL_MODE" = early ] || try systemctl daemon-reload
_e_units() { sed -e 's/#.*//' -e 's/[[:space:]]//g' "$1" | grep -v '^$'; }
for _e_list in "$SL_ROOT"/files/*/enable-system.list; do
  [ -f "$_e_list" ] || continue
  while IFS= read -r _e_u; do
    # Flatpak timers only where Flatpak exists (not on 32-bit PCs)
    case "$_e_u" in *flatpak*) [ "$(sl_arch)" = amd64 ] || continue ;; esac
    sl_enable "$_e_u"
  done < <(_e_units "$_e_list")
done
for _e_list in "$SL_ROOT"/files/*/enable-user.list; do
  [ -f "$_e_list" ] || continue
  while IFS= read -r _e_u; do
    [ -e "$R/etc/systemd/user/timers.target.wants/$_e_u" ] || try systemctl --global enable "$_e_u"
  done < <(_e_units "$_e_list")
done

unset _e_f _e_area _e_list _e_u
return 0
