#!/bin/bash
# 10-base.sh (owner: system) - base system tools, RPM Fusion + codecs, Flathub, dnf privacy.
# Apps are NOT installed here (the experience steps do that); only system tools.
# Sourced by setup.sh: never `exit`.
[ "$SL_MODE" = early ] && return 0

_sys_profile=$(sl_profile)

_sys_pkgs() {   # _sys_pkgs pkg...   install what's missing; one unknown package name doesn't block the rest
  local missing=() p
  for p in "$@"; do rpm -q "$p" >/dev/null 2>&1 || rpm -q --whatprovides "$p" >/dev/null 2>&1 || missing+=("$p"); done
  [ ${#missing[@]} -eq 0 ] && return 0
  echo ">> dnf -y install --skip-unavailable ${missing[*]}"
  dnf -y install --skip-unavailable "${missing[@]}"
  for p in "${missing[@]}"; do
    rpm -q "$p" >/dev/null 2>&1 || rpm -q --whatprovides "$p" >/dev/null 2>&1 \
      || echo "FAILED: package $p could not be installed" | tee -a "$SL_FAILS" >&2
  done
}

_sys_flathub() {
  sl_step "Flathub app store (full catalogue)"
  try flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  try flatpak remote-modify --system --no-filter --enable flathub
}

_sys_countme() {   # D6: don't send the anonymous "countme" counter with repository requests
  local off; off=$(sl_choice_get privacy_countme_off yes)
  if sl_is_atomic; then
    if [ "$off" = yes ]; then
      try systemctl disable --now rpm-ostree-countme.timer
      try systemctl mask rpm-ostree-countme.timer
    else
      systemctl is-enabled -q rpm-ostree-countme.timer 2>/dev/null || { try systemctl unmask rpm-ostree-countme.timer; try systemctl enable rpm-ostree-countme.timer; }
    fi
    return 0
  fi
  local conf=/etc/dnf/dnf.conf
  mkdir -p /etc/dnf; [ -f "$conf" ] || printf '[main]\n' > "$conf"
  grep -q '^\[main\]' "$conf" || sed -i '1i [main]' "$conf"
  if [ "$off" = yes ]; then
    if grep -q '^countme=' "$conf"; then sed -i 's/^countme=.*/countme=False/' "$conf"
    else sed -i '/^\[main\]/a countme=False' "$conf"; fi
  else
    sed -i '/^countme=False$/d' "$conf"
  fi
}

if sl_is_atomic; then
  # Atomic: no dnf. Only things that are safe on an image-based system.
  _sys_flathub
  _sys_countme
  return 0
fi

sl_step "Updating the system"
[ "$SL_MODE" = install ] && try dnf -y upgrade --refresh

sl_step "Base system tools"
_sys_base=(curl wget git unzip zip p7zip p7zip-plugins htop flatpak vlc syncthing solaar fwupd lynis
           btop fastfetch fzf ripgrep bat zoxide libnotify inxi smartmontools nvme-cli openssl python3 dnf5-plugins)
[ "$_sys_profile" = lite ] && _sys_base+=(zenity)    # the Status & Fixes window uses kdialog on KDE, zenity on Xfce
_sys_pkgs "${_sys_base[@]}"

sl_step "Video codecs (RPM Fusion)"
_sys_fv=$(rpm -E %fedora)
if ! rpm -q rpmfusion-free-release >/dev/null 2>&1 || ! rpm -q rpmfusion-nonfree-release >/dev/null 2>&1; then
  try dnf -y install \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$_sys_fv.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$_sys_fv.noarch.rpm"
fi
dnf repo list --enabled 2>/dev/null | grep -q '^fedora-cisco-openh264' \
  || try dnf config-manager setopt fedora-cisco-openh264.enabled=1
if rpm -q rpmfusion-free-release >/dev/null 2>&1; then
  rpm -q ffmpeg-free >/dev/null 2>&1 && ! rpm -q ffmpeg >/dev/null 2>&1 \
    && try dnf -y swap ffmpeg-free ffmpeg --allowerasing
  # AMD/Intel hardware video decoding with all codecs
  rpm -q mesa-va-drivers >/dev/null 2>&1 && ! rpm -q mesa-va-drivers-freeworld >/dev/null 2>&1 \
    && try dnf -y swap mesa-va-drivers mesa-va-drivers-freeworld
  rpm -q mesa-vdpau-drivers >/dev/null 2>&1 && ! rpm -q mesa-vdpau-drivers-freeworld >/dev/null 2>&1 \
    && try dnf -y swap mesa-vdpau-drivers mesa-vdpau-drivers-freeworld
  # GStreamer codecs (RPM Fusion how-to). VERIFY on F44: `dnf update @multimedia` form for dnf5.
  [ "$SL_MODE" = install ] && try dnf -y update @multimedia --setopt=install_weak_deps=False \
    --exclude=PackageKit-gstreamer-plugin
fi

_sys_flathub

sl_step "Privacy settings for software downloads"
_sys_countme

unset _sys_base _sys_fv _sys_profile
return 0
