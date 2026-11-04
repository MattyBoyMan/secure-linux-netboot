# shellcheck shell=bash
# Wizard page (Debian): "Apps you used before" - what replaces the apps people know from Windows or a Mac.
# This page never asks a question (the welcome wizard stays silent on a computer where nothing needs the
# person); it shows the mapping once and points to the three optional extras. Each extra is a recorded
# choice (backup_gui, disk_usage, disk_utility): set it with secure-linux-choice and the next setup run
# (or "Repair setup") installs the app - nothing is ever installed without that choice.
# Email needs no question: Thunderbird is installed on this setup already.
page_title() { echo "Apps you used before"; }
page_run() {
  wz_is_done apps-used && return 0
  wz_info "Here is what replaces the apps you might have used before:

  Microsoft Office  ->  LibreOffice Writer and Calc (installed)
  Outlook  ->  Thunderbird (installed)
  Chrome  ->  Firefox ESR or LibreWolf (installed)
  iCloud / Apple Photos  ->  Syncthing: folders shared between your own devices, home network only
  OneDrive  ->  copy your files across once from the backup drive (the START-HERE guide shows how)

The heavy creative apps (Photoshop-style editing and so on) are not on this computer: it is an older machine and they would crawl.

Three little extras are ready if you ever want them:
  Backups (Deja Dup): automatic copies of your files to a USB drive or another computer at home. Never to a company.
  Baobab: a picture of what is filling the disk, biggest folders first.
  Disks: format or wipe USB sticks and check each drive's health, with buttons instead of commands.

The START-HERE guide shows the one short command that adds each of them. Every one asks before anything is installed, and a copy of your choice is kept so 'Repair setup' can finish the job later."
  wz_done apps-used
  return 0
}
