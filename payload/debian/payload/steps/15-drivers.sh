#!/bin/bash
# 15-drivers.sh (Debian) - drivers that need a decision: Broadcom Wi-Fi and NVIDIA graphics are only OFFERED here (an event in
# Secure Linux Status); nothing from Debian's "non-free" section is installed without the person saying yes
# (secure-linux-drivers). Microcode and the free firmware were already handled by 10-base.sh.
# Choices read: nvidia_driver (nvidia | nouveau), wifi_driver. Sourced by setup.sh: never `exit`.
[ "$SL_MODE" = early ] && return 0

sl_step "Extra drivers (offered, never installed without asking)"
if [ -x "$SL_ROOT/bin/secure-linux-drivers" ]; then
  "$SL_ROOT/bin/secure-linux-drivers" check --quiet || echo "Note: the driver check did not finish; it will run again at the next repair."
fi
return 0
