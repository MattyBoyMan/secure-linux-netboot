# shellcheck shell=bash
# Optional Docker page. The first-boot setup has already run, so a new lite choice is applied by Repair setup.
page_title() { echo "Docker and home-server tools"; }
page_run() {
  . "$SL_ROOT/lib/docker-lib.sh"
  local profile=${SL_PROFILE:-$(sl_profile)} C=$SL_ROOT/bin/secure-linux-choice
  [ "$profile" = lite ] || return 0
  wz_is_done docker && return 0
  if ! sl_docker_check; then
    wz_root "$C" set docker no
    wz_info "Docker will not be installed on this computer.

$SL_DOCKER_REASON

$(sl_docker_report)

Nothing was downloaded or changed. The Home & Server Helper can still manage an existing server over SSH."
    wz_done docker
    return 0
  fi
  wz_info "Docker runs self-contained server apps such as Home Assistant Container and photo services.

$(sl_docker_report)

This is optional and uses Docker's official Debian repository.

For safety, you will NOT be added to the docker group: that group effectively gives unrestricted administrator/root access. The Home & Server Helper offers a separate rootless Docker context, while the server kit can continue to use sudo docker."
  if wz_yesno "Install Docker on this computer?"; then
    wz_root "$C" set docker yes
    wz_info "Docker is selected. Because the main setup has already finished, choose Repair setup to install it now or later. Repair setup checks the hardware again before changing anything."
  else
    wz_root "$C" set docker no
    wz_info "No problem. Docker was not selected and no repository or package was added."
  fi
  wz_done docker
  return 0
}
