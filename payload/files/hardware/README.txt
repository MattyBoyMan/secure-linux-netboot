Files for the hardware area (owner: hardware). Installed by the generic installer in 00-early.sh unless noted.
  parts.map                            device -> software table read by secure-linux-parts (stays in $SL_ROOT/files/hardware/)
  udev/90-secure-linux-parts.rules     hot-plug rule; installed to /etc/udev/rules.d/ by steps/15-drivers.sh
  systemd/system/secure-linux-parts-hotplug.service   started by the udev rule (oneshot)
  systemd/system/secure-linux-health.{service,timer}  weekly quick hardware check (alerts for failing parts)
  enable-system.list                   enables secure-linux-health.timer
  applications/*.desktop               Hardware Health Check, Hardware Test (full), Repair This Computer
