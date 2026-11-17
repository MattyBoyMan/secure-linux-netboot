#!/bin/bash
# 32-boot-rollback.sh (owner: X2a boot rollback) - "Go back to an earlier day" in the boot menu.
# Runs after 30-updates.sh (which sets up Snapper on full/lite Btrfs). It switches the feature on ONLY when
# `secure-linux-boot-rollback check` positively recognises the layout (Fedora GRUB + BLS entries, Btrfs root
# subvolume, separate /boot, Snapper root config, GRUB's custom.cfg hook). Anything else: nothing is changed.
# The normal start entries and the default start are never changed by this step.
# Everything it needs is already on a Fedora KDE system (dracut, grub2-tools, btrfs-progs, snapper): it works
# offline. Sourced by setup.sh: never `exit`.
[ "$SL_MODE" = early ] && return 0
sl_is_atomic && return 0

_br_tool="$SL_ROOT/bin/secure-linux-boot-rollback"
if [ -f "$_br_tool" ]; then
  sl_step "Boot menu: go back to an earlier day (if an update breaks something)"
  if _br_why=$(bash "$_br_tool" check 2>&1); then
    try bash "$_br_tool" on
  else
    echo "Go back to an earlier day: not added on this computer (nothing changed)."
    printf '%s\n' "$_br_why"
  fi
fi
unset _br_tool _br_why
return 0
