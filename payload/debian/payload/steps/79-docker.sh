# shellcheck shell=bash
# 79-docker (Debian): official Docker CE, automatic on a manually supplied full profile and opt-in on capable lite PCs.
# The normal Debian installer remains lite. The rootful service supports the existing sudo-based server kit.
# We deliberately do NOT add the user to the docker group: membership is effectively administrator/root access.
[ "$SL_MODE" = early ] && return 0
. "$SL_ROOT/lib/docker-lib.sh"
: "${SL_PROFILE:=$(sl_profile)}"

_docker79_codename() {
  local c
  c=$(sed -n 's/^VERSION_CODENAME=//p' "$R/etc/os-release" 2>/dev/null | tail -n1 | tr -d '"')
  case "$c" in ''|*[!a-z0-9-]*) return 1 ;; esac
  printf '%s' "$c"
}

_docker79() {
  local wanted=no choice arch=$(sl_arch) key=$R/etc/apt/keyrings/docker.asc sources=$R/etc/apt/sources.list.d/docker.sources
  case "$SL_PROFILE" in
    full) wanted=yes ;;
    lite) choice=$(sl_choice_get docker no); [ "$choice" = yes ] && wanted=yes ;;
    *) sl_skip_app docker "Docker is not installed by the $SL_PROFILE profile"; return 0 ;;
  esac
  [ "$wanted" = yes ] || return 0
  if ! sl_docker_check; then
    sl_skip_app docker "$SL_DOCKER_REASON"
    sl_docker_report
    return 0
  fi

  local packages=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
                  uidmap dbus-user-session slirp4netns fuse-overlayfs ca-certificates curl)
  local missing=no p codename tmp
  for p in "${packages[@]}"; do sl_pkg_installed "$p" || { missing=yes; break; }; done
  if [ "$missing" = no ] && [ -s "$key" ] && [ -f "$sources" ]; then
    sl_unskip_app docker
    sl_enable docker.service
    return 0
  fi
  sl_online || {
    echo "FAILED: Docker is wanted but the computer is offline; the next Repair setup will try again." | tee -a "$SL_FAILS" >&2
    return 0
  }
  codename=$(_docker79_codename) || {
    echo "FAILED: Docker needs a Debian VERSION_CODENAME in /etc/os-release; no repository was added." | tee -a "$SL_FAILS" >&2
    return 0
  }
  case "$arch" in amd64|arm64|s390x) ;; *) sl_skip_app docker "Docker has no official package architecture for $arch"; return 0 ;; esac

  sl_step "Installing Docker from Docker's official Debian repository"
  sl_pkg_install ca-certificates curl || return 1
  install -d -m 0755 "$R/etc/apt/keyrings"
  if [ ! -s "$key" ]; then
    tmp=$(mktemp "$R/etc/apt/keyrings/.docker.asc.XXXXXX") || return 1
    chmod 0600 "$tmp"
    if ! try curl -fsSL https://download.docker.com/linux/debian/gpg -o "$tmp"; then
      rm -f "$tmp"
      return 1
    fi
    [ -s "$tmp" ] || { rm -f "$tmp"; echo "FAILED: Docker's signing key download was empty." | tee -a "$SL_FAILS" >&2; return 0; }
    install -m 0644 "$tmp" "$key"
    rm -f "$tmp"
  fi
  sl_write_file "$sources" <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $codename
Components: stable
Architectures: $arch
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  SL_APT_UPDATED=""
  sl_pkg_install "${packages[@]}" || return 1
  sl_unskip_app docker
  sl_enable docker.service
  echo "Docker is ready through sudo. No user was added to the docker group (membership is effectively root access)."
  echo "For safer everyday containers, open Home & Server Helper and choose the per-user rootless Docker setup."
  return 0
}
_docker79
unset -f _docker79 _docker79_codename
return 0
