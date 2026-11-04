#!/bin/bash
# 70-desktop.sh (Debian) - the person's default web browser for Xfce (Preferred Applications) and for every other program.
# Respects a browser the person picked themselves; only fills in what is not set. Welcome wizard autostart is installed by 00-early.
# Sourced by setup.sh: never `exit`.
[ "$SL_MODE" = early ] && return 0

sl_step "Default web browser for Xfce"
if [ -x "$SL_ROOT/bin/secure-linux-browser" ]; then
  try "$SL_ROOT/bin/secure-linux-browser" apply --user "$(sl_user)"
fi
return 0
