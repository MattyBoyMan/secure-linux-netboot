#!/bin/bash
# 30-updates.sh (Debian) - automatic updates with unattended-upgrades (the Debian way of dnf5-automatic on lite):
# security and stable updates install by themselves every day. A restart happens at 04:00 only if the choice
# lite_auto_reboot=yes; otherwise the health check reminds the person to restart (alert updates-waiting).
# Flatpak apps update daily (secure-linux-flatpak-update.timer, installed by 00-early.sh).
# Sourced by setup.sh: never `exit`.
[ "$SL_MODE" = early ] && return 0

sl_step "Automatic updates"
sl_pkg_install --no-recommends unattended-upgrades
if [ "$(sl_choice_get lite_auto_reboot no)" = yes ]; then _u_reboot=true; else _u_reboot=false; fi
sl_write_file "$R/etc/apt/apt.conf.d/20auto-upgrades" <<'EOF'
// Secure Linux: check for updates and install them every day
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
sl_write_file "$R/etc/apt/apt.conf.d/52secure-linux-unattended" <<EOF
// Secure Linux: what unattended-upgrades installs by itself, and when it restarts.
// Security fixes AND the normal "stable updates" (bug fixes) both install. Third-party sources are not touched.
// Automatic-Reboot: false = the health check reminds you to restart; true = restart at 04:00 when an update needs it
// (choice lite_auto_reboot).
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
  "origin=Debian,codename=\${distro_codename},label=Debian";
  "origin=Debian,codename=\${distro_codename},label=Debian-Security";
  "origin=Debian,codename=\${distro_codename}-security,label=Debian-Security";
  "origin=Debian,codename=\${distro_codename}-updates";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "$_u_reboot";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF
sl_enable apt-daily.timer apt-daily-upgrade.timer
unset _u_reboot
return 0
