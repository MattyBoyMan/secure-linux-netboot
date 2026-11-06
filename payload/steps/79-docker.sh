# shellcheck shell=bash
# 79-docker: official Docker CE, automatic on full and opt-in on capable lite machines.
# The rootful service remains available to the existing sudo-based server kit. We deliberately do NOT add the
# user to the docker group: that group is effectively unrestricted administrator/root access. The helper offers
# a separate per-user rootless Docker context instead.
[ "$SL_MODE" = early ] && return 0
. "$SL_ROOT/lib/docker-lib.sh"
: "${SL_PROFILE:=$(sl_profile)}"

_docker79_fail_offline() {
  echo "FAILED: Docker is wanted but the computer is offline; the next Repair setup will try again." | tee -a "$SL_FAILS" >&2
}

_docker79() {
  local wanted=no choice repo=${SL_TEST_SYSROOT:-}/etc/yum.repos.d/docker-ce.repo
  case "$SL_PROFILE" in
    full) wanted=yes ;;
    lite) choice=$(sl_choice_get docker no); [ "$choice" = yes ] && wanted=yes ;;
    atomic) sl_skip_app docker "Atomic desktops do not use dnf; use the existing Podman tools instead"; return 0 ;;
    *) sl_skip_app docker "Docker is not installed by the $SL_PROFILE profile"; return 0 ;;
  esac
  [ "$wanted" = yes ] || return 0
  sl_is_atomic && { sl_skip_app docker "Atomic desktops do not use dnf; use the existing Podman tools instead"; return 0; }
  if ! sl_docker_check; then
    sl_skip_app docker "$SL_DOCKER_REASON"
    sl_docker_report
    return 0
  fi

  local packages=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
                  fuse-overlayfs slirp4netns uidmap dbus-user-session)
  local missing=no p
  for p in "${packages[@]}"; do rpm -q "$p" >/dev/null 2>&1 || { missing=yes; break; }; done
  if [ "$missing" = no ] && [ -f "$repo" ]; then
    sl_unskip_app docker
    sl_enable docker.service
    return 0
  fi
  sl_online || { _docker79_fail_offline; return 0; }

  sl_step "Installing Docker from Docker's official Fedora repository"
  if [ ! -f "$repo" ]; then
    try dnf -y config-manager addrepo --from-repofile https://download.docker.com/linux/fedora/docker-ce.repo || return 1
  fi
  sl_dnf_install "${packages[@]}" || return 1
  sl_unskip_app docker
  sl_enable docker.service
  echo "Docker is ready through sudo. No user was added to the docker group (membership is effectively root access)."
  echo "For safer everyday containers, open Home & Server Helper and choose the per-user rootless Docker setup."
  return 0
}
_docker79
unset -f _docker79 _docker79_fail_offline
return 0
