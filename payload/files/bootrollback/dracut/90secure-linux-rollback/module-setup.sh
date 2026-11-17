#!/bin/bash
# Secure Linux boot rollback: dracut module "secure-linux-rollback".
# Installed by `secure-linux-boot-rollback on` to /usr/lib/dracut/modules.d/90secure-linux-rollback/.
# It is ONLY used for the separate start-up file /boot/secure-linux-rollback/initramfs-<kernel>.img that the
# "Go back to an earlier day" boot menu entries load. check() returns 255, which dracut documents as
# "only include the dracut module if another module requires it or if explicitly specified in the config
# file or on the argument list" (man dracut.modules). So the normal start-up files never contain it.

check() {
    return 255
}

depends() {
    echo base
    return 0
}

installkernel() {
    hostonly='' instmods overlay
}

install() {
    inst_multiple mount umount mkdir
    inst_hook pre-pivot 50 "$moddir/secure-linux-rollback-overlay.sh"
}
