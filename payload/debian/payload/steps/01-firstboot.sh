#!/bin/bash
# 01-firstboot.sh (Debian) - make sure the first-start setup service is switched on (never started from here:
# it is the service that runs setup.sh). Runs in every mode; in the installer it only creates the enable link.
# Sourced by setup.sh: never `exit`.
sl_step "First-start setup service"
if ! systemctl is-enabled -q secure-linux-firstboot.service 2>/dev/null; then
  [ -f "$R/etc/systemd/system/secure-linux-firstboot.service" ] && try systemctl enable secure-linux-firstboot.service
fi
return 0
