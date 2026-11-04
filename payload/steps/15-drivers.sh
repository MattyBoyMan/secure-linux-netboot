# shellcheck shell=bash
# 15-drivers.sh (owner: hardware) - drivers and firmware for THIS computer, decided by hw/detect.sh:
#   microcode + the linux-firmware parts for the chips present, Intel video decoding, switchable graphics,
#   NVIDIA (akmod-nvidia / akmod-nvidia-580xx; older cards stay on nouveau), Broadcom Wi-Fi (akmod-wl),
#   Secure Boot signing key for those drivers (one-time "Enroll MOK" at the next restart),
#   Intel Macs (PC-style function keys, mbpfan), T2 Macs (t2linux kernel + Apple Wi-Fi firmware).
# Apple Silicon (Fedora Asahi Remix, aarch64): everything x86-only is skipped; Asahi's own packages cover it.
# Sourced by setup.sh: never `exit`. Idempotent; repair mode only adds what is missing.
#
# Choice keys read (all optional):
#   nvidia_driver   [auto] auto | nvidia (force NVIDIA's driver) | nouveau (keep the open-source driver)
#   broadcom_wl     [auto] auto | no
#   mac_fnmode      [2]    hid_apple fnmode: 2 = F1..F12 first (like a PC), 1 = media keys first (like macOS)
#   t2_kernel       [auto] auto | no   (T2 Macs: add the t2linux kernel)
#   secureboot_intent (from the installer) off = the user will switch Secure Boot off: no key import
#
# Also (secure-linux-parts): the software to USE the other hardware - disc burning for a DVD drive, scanner and printer
# drivers, Bluetooth, fingerprint, drawing tablets, game controllers... - install mode runs it once with --install,
# repair mode only re-asserts what it installed before. The udev rule for hot-plugged devices is installed here too.
# Test hooks: SL_HW_FIXTURE (fake /sys+/proc for hw/detect.sh), SL_TEST_SYSROOT (prefix for files written).
[ "$SL_MODE" = early ] && return 0

_hw15_main() {
  local R=${SL_TEST_SYSROOT:-} prof sb intent
  HW_ROOT=${SL_HW_FIXTURE:-}
  # shellcheck source=../hw/detect.sh
  . "$SL_ROOT/hw/detect.sh"
  local -A H
  local k v
  while IFS='=' read -r k v; do [ -n "$k" ] && H[$k]=$v; done < <(hw_all)
  mkdir -p "$SL_STATE/hw"
  printf '%s\n' "$(hw_all)" > "$SL_STATE/hw/detected.txt" 2>/dev/null

  prof=$(sl_profile); sl_is_atomic && prof=atomic
  sb=${H[secure_boot]}
  intent=$(sl_choice_get secureboot_intent)

  sl_step "Drivers for this computer"
  echo "Detected: ${H[dmi_vendor]} ${H[dmi_product]} | cpu=${H[cpu_vendor]} ${H[cpu_arch]} v${H[cpu_x86_level]} | gpu nvidia=${H[nvidia_class]} amd=${H[gpu_amd]} intel=${H[gpu_intel]} hybrid=${H[hybrid]} | wifi=${H[wifi_vendor]}/${H[wifi_broadcom_driver]} | mac=${H[mac_kind]} | secure_boot=$sb intent=${intent:-unset}"

  # ------------------------------------------------------------ Apple Silicon (Fedora Asahi Remix)
  case "${H[cpu_arch]}" in
    aarch64|arm*)
      echo "Apple Silicon / ARM: drivers come with Fedora Asahi Remix's own kernel and packages. Nothing to add here."
      _hw15_clear_all
      return 0 ;;
  esac

  if [ "$prof" = atomic ]; then
    _hw15_atomic
    _hw15_parts
    return 0
  fi

  # ------------------------------------------------------------ microcode + firmware for the chips present
  local fw=()
  case "${H[cpu_vendor]}" in intel) fw+=(microcode_ctl) ;; amd) fw+=(amd-ucode-firmware) ;; esac
  [ "${H[gpu_amd]}" = yes ] && fw+=(amd-gpu-firmware)
  [ "${H[gpu_intel]}" = yes ] && fw+=(intel-gpu-firmware)
  [ "${H[gpu_nvidia]}" = yes ] && fw+=(nvidia-gpu-firmware)          # nouveau / nova (GSP) firmware
  case "${H[wifi_vendor]}" in
    intel)    fw+=(iwlwifi-mvm-firmware iwlwifi-dvm-firmware) ;;
    mediatek) fw+=(mt7xxx-firmware) ;;
    realtek)  fw+=(realtek-firmware) ;;
    atheros)  fw+=(atheros-firmware) ;;
    broadcom) [ "${H[wifi_broadcom_driver]}" = builtin ] && fw+=(brcmfmac-firmware) ;;
  esac
  [ "${H[eth_vendor]}" = realtek ] && fw+=(realtek-firmware)          # r8169 rtl_nic files (VERIFY subpackage)
  _hw15_pkgs_opt "${fw[@]}"

  # Hardware video decoding on Intel graphics (AMD's is handled by the base step's mesa-*-freeworld swap)
  [ "${H[gpu_intel]}" = yes ] && _hw15_pkgs_opt intel-media-driver libva-intel-driver

  # ------------------------------------------------------------ switchable graphics
  if [ "${H[hybrid]}" = yes ]; then
    sl_step "Switchable graphics"
    _hw15_pkgs switcheroo-control
    rpm -q switcheroo-control >/dev/null 2>&1 && { systemctl is-enabled -q switcheroo-control.service 2>/dev/null || sl_enable switcheroo-control.service; }
  fi

  _hw15_nvidia
  _hw15_broadcom
  _hw15_mac
  _hw15_mok
  _hw15_parts
  return 0
}

# ---------------------------------------------------------------- package helpers
_hw15_missing() { local p; for p in "$@"; do rpm -q "$p" >/dev/null 2>&1 || rpm -q --whatprovides "$p" >/dev/null 2>&1 || printf '%s\n' "$p"; done; }
_hw15_pkgs() {      # required: a missing package afterwards is recorded as a failure
  local m p; m=$(_hw15_missing "$@" | sort -u | tr '\n' ' '); [ -n "${m// /}" ] || return 0
  # shellcheck disable=SC2086
  try dnf -y install --skip-unavailable $m
  for p in $m; do rpm -q "$p" >/dev/null 2>&1 || rpm -q --whatprovides "$p" >/dev/null 2>&1 \
    || { echo "FAILED: package $p could not be installed" | tee -a "$SL_FAILS" >&2; }; done
  return 0
}
_hw15_pkgs_opt() {  # nice to have: names that don't exist on this Fedora release are skipped quietly
  local m; m=$(_hw15_missing "$@" | sort -u | tr '\n' ' '); [ -n "${m// /}" ] || return 0
  echo ">> dnf -y install --skip-unavailable $m"
  # shellcheck disable=SC2086
  dnf -y install --skip-unavailable $m || echo "note: some optional hardware packages were not available"
  return 0
}
_hw15_kernels() {   # the running kernel and the newest installed one (akmods builds for both)
  local run new
  run=$(uname -r)
  new=$(ls -1 "${SL_TEST_SYSROOT:-}/lib/modules" 2>/dev/null | sort -V | tail -n 1)
  printf '%s\n' "$run" ${new:+"$new"} | sort -u
}
_hw15_build() {     # _hw15_build MODULE   wait for/force the akmods build; 0 if the module exists for every kernel
  local mod=$1 k ok=0
  for k in $(_hw15_kernels); do
    if modinfo -k "$k" -F version "$mod" >/dev/null 2>&1; then echo "$mod module ready for $k: $(modinfo -k "$k" -F version "$mod" 2>/dev/null)"; continue; fi
    echo "Building the $mod driver for kernel $k (can take up to 5-10 minutes)..."
    try timeout 1800 akmods --force --kernels "$k"
    if modinfo -k "$k" -F version "$mod" >/dev/null 2>&1; then echo "$mod module built for $k"
    else echo "the $mod module is not available for $k yet (akmods retries at the next start)"; ok=1; fi
  done
  return $ok
}
_hw15_sb_ready() {  # Secure Boot will be on: the akmods key must exist before a module is built
  local sb intent
  sb=${H[secure_boot]:-}; intent=$(sl_choice_get secureboot_intent)
  [ "$sb" = on ] && [ "$intent" != off ] || return 0
  _hw15_pkgs kmodtool akmods mokutil openssl
  _hw15_keygen
}
HW15_KEY_DIR=/etc/pki/akmods/certs
_hw15_keygen() {    # RPM Fusion Secure Boot howto: kmodgenca -a (keys in /etc/pki/akmods); akmods signs with it
  local key="${SL_TEST_SYSROOT:-}$HW15_KEY_DIR/public_key.der"
  [ -s "$key" ] && return 0
  try kmodgenca -a
  [ -s "$key" ]
}

# ---------------------------------------------------------------- NVIDIA
_hw15_nvidia() {
  local cls=${H[nvidia_class]} want pkgs=() mod=nvidia
  [ "${H[gpu_nvidia]}" = yes ] || { sl_clear drivers-nvidia; return 0; }
  want=$(sl_choice_get nvidia_driver auto)
  sl_step "NVIDIA graphics driver"
  if [ "$want" = nouveau ] || { [ "$want" = auto ] && [ "$cls" = legacy ]; }; then
    echo "NVIDIA ${H[nvidia_family]} (${H[nvidia_id]}): keeping the open-source driver (nouveau, part of Fedora)."
    [ "$cls" = legacy ] && echo "NVIDIA's own driver no longer supports this card on current Fedora kernels (470xx/390xx/340xx are unmaintained)."
    sl_clear drivers-nvidia
    return 0
  fi
  [ "$want" = nvidia ] && [ "$cls" = legacy ] && cls=580xx    # forced: the newest branch that may still work
  rpm -q rpmfusion-nonfree-release >/dev/null 2>&1 || {
    echo "FAILED: RPM Fusion (nonfree) is not set up, so the NVIDIA driver can't be installed" | tee -a "$SL_FAILS" >&2
    sl_alert drivers-nvidia "NVIDIA driver not installed" "The NVIDIA driver comes from RPM Fusion, which isn't set up yet. Repair will try again." "Open Secure Linux Status and choose Repair"
    return 0; }
  case "$cls" in
    modern) pkgs=(akmod-nvidia xorg-x11-drv-nvidia); [ "$(sl_profile)" = full ] && pkgs+=(xorg-x11-drv-nvidia-cuda) ;;
    580xx)  pkgs=(akmod-nvidia-580xx xorg-x11-drv-nvidia-580xx); [ "$(sl_profile)" = full ] && pkgs+=(xorg-x11-drv-nvidia-580xx-cuda) ;;
  esac
  _hw15_sb_ready
  _hw15_pkgs "${pkgs[@]}"
  [ "$(sl_profile)" = full ] && [ "$cls" = modern ] && _hw15_pkgs_opt libva-nvidia-driver   # video decoding in browsers
  rpm -q "${pkgs[0]}" >/dev/null 2>&1 || return 0
  if _hw15_build "$mod"; then
    sl_clear drivers-nvidia
  else
    sl_alert drivers-nvidia "NVIDIA driver still being prepared" "The NVIDIA driver is built for your kernel at the next start. Until then the open-source driver is used." "Restart the computer"
  fi
  HW15_NEED_KEY=1
}

# ---------------------------------------------------------------- Broadcom Wi-Fi
_hw15_broadcom() {
  [ "${H[wifi_vendor]}" = broadcom ] || { sl_clear drivers-b43; return 0; }
  case "${H[wifi_broadcom_driver]}" in
    wl)
      [ "$(sl_choice_get broadcom_wl auto)" = no ] && { echo "Broadcom wl driver: switched off by choice"; return 0; }
      sl_step "Broadcom Wi-Fi driver"
      rpm -q rpmfusion-nonfree-release >/dev/null 2>&1 || { echo "FAILED: RPM Fusion (nonfree) missing: no Broadcom driver" | tee -a "$SL_FAILS" >&2; return 0; }
      _hw15_sb_ready
      _hw15_pkgs akmod-wl broadcom-wl
      rpm -q akmod-wl >/dev/null 2>&1 && { _hw15_build wl || true; HW15_NEED_KEY=1; }
      ;;
    b43)
      sl_alert drivers-b43 "Wi-Fi needs a one-time step" \
        "This older Broadcom Wi-Fi chip needs firmware that can't be included. With a cable connected, run in a terminal: sudo dnf install b43-fwcutter, then follow docs/COMPATIBILITY.md (b43 firmware)." \
        "Connect an Ethernet cable first" ;;
    builtin) echo "Broadcom Wi-Fi: Fedora's own brcmfmac/brcmsmac driver handles it" ;;
    *) echo "Broadcom Wi-Fi ${H[wifi_ids]}: unknown chip, nothing installed (see docs/COMPATIBILITY.md)" ;;
  esac
}

# ---------------------------------------------------------------- Intel Macs
_hw15_mac() {
  case "${H[mac_kind]}" in intel|intel-t2) ;; *) return 0 ;; esac
  local R=${SL_TEST_SYSROOT:-} fn
  sl_step "Mac keyboard, fans and hardware"
  fn=$(sl_choice_get mac_fnmode 2)
  case "$fn" in 0|1|2) ;; *) fn=2 ;; esac
  sl_write_file "$R/etc/modprobe.d/secure-linux-hid-apple.conf" <<EOF
# Secure Linux (hardware): Apple keyboards. fnmode=2: F1..F12 work like a PC's, hold Fn for brightness/volume.
# Change with: secure-linux-choice set mac_fnmode 1   (1 = media keys first, like macOS), then Repair.
options hid_apple fnmode=$fn
EOF
  [ -w /sys/module/hid_apple/parameters/fnmode ] && [ -z "$R" ] && echo "$fn" > /sys/module/hid_apple/parameters/fnmode
  if [ "${H[mac_kind]}" = intel ]; then
    case "${H[mac_model]}" in
      MacBook*)
        _hw15_pkgs mbpfan
        rpm -q mbpfan >/dev/null 2>&1 && { systemctl is-enabled -q mbpfan.service 2>/dev/null || sl_enable mbpfan.service; } ;;
    esac
    [ "${H[mac_facetimehd]}" = yes ] && echo "FaceTime HD camera: needs the out-of-tree facetimehd driver; not installed automatically (docs/COMPATIBILITY.md)."
    return 0
  fi
  _hw15_t2
}

# ---------------------------------------------------------------- T2 Macs: t2linux kernel + Apple firmware
HW15_T2_COPR=sharpenedblade/t2linux
_hw15_t2() {
  local R=${SL_TEST_SYSROOT:-}
  [ "$(sl_choice_get t2_kernel auto)" = no ] && { echo "t2linux kernel: switched off by choice"; return 0; }
  sl_step "T2 Mac: kernel for the built-in keyboard, trackpad, sound and Wi-Fi"
  if ! dnf -q copr list 2>/dev/null | grep -q "$HW15_T2_COPR"; then
    try dnf -y copr enable "$HW15_T2_COPR"
  fi
  if ! rpm -q --qf '%{RELEASE}\n' kernel-core kernel 2>/dev/null | grep -q t2; then
    # t2linux wiki (Fedora): swap Fedora's kernel for the t2linux build from the COPR
    try dnf -y swap --from-repo="copr:copr.fedorainfracloud.org:${HW15_T2_COPR/\//:}" kernel kernel
    sl_event drivers-t2-kernel "Mac kernel installed" "Restart once to use the built-in keyboard, trackpad and Touch Bar."
  fi
  # t2linux-release pulls t2linux-config (audio, module loading), t2linux-scripts, t2fanrd and tiny-dfr (VERIFY)
  _hw15_pkgs t2linux-release
  _hw15_pkgs_opt t2fanrd tiny-dfr
  systemctl cat t2fanrd.service >/dev/null 2>&1 && { systemctl is-enabled -q t2fanrd.service 2>/dev/null || sl_enable t2fanrd.service; }
  _hw15_t2_firmware
}
_hw15_t2_firmware() {
  local R=${SL_TEST_SYSROOT:-} raw dest work fwsh
  dest="$R/usr/lib/firmware/brcm"
  if ls "$dest"/brcmfmac*apple* >/dev/null 2>&1; then echo "Apple Wi-Fi/Bluetooth firmware already in place"; sl_clear drivers-t2-firmware; return 0; fi
  raw=$(ls -1 "$SL_STATE"/mac-firmware/*.tar.gz "$SL_STATE"/mac-firmware/*.tar 2>/dev/null | head -n 1)
  if [ -z "$raw" ]; then
    sl_alert drivers-t2-firmware "Wi-Fi needs Apple's firmware" \
      "No copy of this Mac's Wi-Fi firmware was saved from macOS. With a cable or phone tethering, run: sudo get-apple-firmware (t2linux) and choose the option that downloads it from Apple's recovery image." \
      "Connect a cable, then run: sudo get-apple-firmware"
    return 0
  fi
  # Rename Apple's files to the Linux names with t2linux's own script (rename_firmware, MIT, based on Asahi Linux's).
  work=$(mktemp -d)
  fwsh=$(command -v get-apple-firmware 2>/dev/null)
  if [ -z "$fwsh" ]; then
    try curl -fsSL --max-time 60 -o "$work/firmware.sh" https://wiki.t2linux.org/tools/firmware.sh && fwsh=$work/firmware.sh
    [ -n "$fwsh" ] && echo "t2linux firmware.sh sha256: $(sha256sum "$fwsh" | cut -d' ' -f1)"
  fi
  mkdir -p "$work/raw"
  if [ -n "$fwsh" ] && tar -xf "$raw" -C "$work/raw" 2>/dev/null; then
    awk '/^rename_firmware *\(\) *\{/ {on = 1} on {print} on && /^EOF$/ {eof = 1} on && eof && /^}$/ {exit}' "$fwsh" > "$work/rename.sh"
    if grep -q '^rename_firmware' "$work/rename.sh" && ( . "$work/rename.sh"; rename_firmware "$work/raw" "$work/renamed.tar" ) && [ -s "$work/renamed.tar" ]; then
      mkdir -p "$dest"
      try tar -xf "$work/renamed.tar" -C "$dest"
      local q; for q in brcmfmac4364b2-pcie.txt brcmfmac4364b2-pcie.txcap_blob; do [ -f "$work/raw/$q" ] && cp "$work/raw/$q" "$dest/"; done
      sl_clear drivers-t2-firmware
      echo "Apple Wi-Fi/Bluetooth firmware installed from $raw"
    else
      echo "FAILED: could not convert the saved Apple firmware ($raw)" | tee -a "$SL_FAILS" >&2
    fi
  fi
  rm -rf "$work"
}

# ---------------------------------------------------------------- Secure Boot: one-time key approval
# RPM Fusion howto: kmodgenca -a, then mokutil --import /etc/pki/akmods/certs/public_key.der with a one-time
# password, approved in the blue MOK Manager at the next start. Here the password is an 8-digit code made for
# the user (setup runs unattended); `secure-linux-drivers enroll-key` lets them pick their own instead.
_hw15_mok() {
  local key code hash boot pend=$SL_STATE/hw/mok-pending sb intent
  sb=${H[secure_boot]}; intent=$(sl_choice_get secureboot_intent)
  if [ "${HW15_NEED_KEY:-0}" != 1 ] || [ "$sb" != on ] || [ "$intent" = off ]; then
    sl_clear drivers-mok; rm -f "$pend"; return 0
  fi
  key="${SL_TEST_SYSROOT:-}$HW15_KEY_DIR/public_key.der"
  _hw15_keygen || { echo "FAILED: no akmods signing key" | tee -a "$SL_FAILS" >&2; return 0; }
  if mokutil --test-key "$key" 2>&1 | grep -qi 'already enrolled'; then
    echo "Driver signing key is approved (enrolled in Secure Boot)"
    sl_clear drivers-mok; rm -f "$pend"; return 0
  fi
  boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  if [ -f "$pend" ] && [ "$(sed -n 2p "$pend")" = "$boot" ]; then
    echo "Driver signing key: approval already requested; it happens at the next restart"
    return 0
  fi
  sl_step "Secure Boot: asking to approve the driver key"
  code=$(tr -dc '0-9' < /dev/urandom 2>/dev/null | head -c 8)
  [ ${#code} -eq 8 ] || code=$(printf '%08d' $(( (RANDOM * 32768 + RANDOM) % 100000000 )))
  hash=$(mktemp)
  if mokutil --generate-hash="$code" > "$hash" 2>/dev/null && [ -s "$hash" ] && try mokutil --import "$key" --hash-file "$hash"; then
    ( umask 077; printf '%s\n%s\n' "$code" "$boot" > "$pend" )
    sl_alert drivers-mok "Restart and approve the driver key (code $code)" \
      "Secure Boot needs your OK once for the graphics/Wi-Fi driver. At the next restart a blue screen appears: press a key, choose Enroll MOK > Continue > Yes, type $code (the keyboard is US layout there), then Reboot. If you miss it, Repair asks again." \
      "Restart now; code $code"
  else
    echo "FAILED: could not request Secure Boot approval for the driver key" | tee -a "$SL_FAILS" >&2
  fi
  rm -f "$hash"
}

# ---------------------------------------------------------------- Atomic (Kinoite): guide only
_hw15_atomic() {
  if [ "${H[gpu_nvidia]}" = yes ] && [ "${H[nvidia_class]}" != legacy ] && [ "$(sl_choice_get nvidia_driver auto)" != nouveau ]; then
    sl_alert drivers-nvidia "NVIDIA driver: manual step on this edition" \
      "The image-based edition doesn't add the NVIDIA driver by itself. RPM Fusion documents: rpm-ostree install akmod-nvidia xorg-x11-drv-nvidia (after adding RPM Fusion), plus kernel options to turn nouveau off. With Secure Boot on, extra key steps are needed. See docs/COMPATIBILITY.md." \
      "See docs/COMPATIBILITY.md (Atomic + NVIDIA)"
  fi
  echo "Atomic edition: drivers in the image are used; nothing layered automatically."
}

# ---------------------------------------------------------------- software for the other hardware
_hw15_parts() {
  local R=${SL_TEST_SYSROOT:-} parts="$SL_ROOT/bin/secure-linux-parts" rules="$SL_ROOT/files/hardware/udev/90-secure-linux-parts.rules" rc
  sl_step "Software for the rest of the hardware (discs, scanners, printers, Bluetooth, tablets...)"
  [ -f "$rules" ] && sl_install_file "$rules" "$R/etc/udev/rules.d/90-secure-linux-parts.rules"
  [ -z "$R" ] && command -v udevadm >/dev/null 2>&1 && udevadm control --reload >/dev/null 2>&1
  [ -f "$parts" ] || { echo "secure-linux-parts is not installed; skipping"; return 0; }
  if [ "$prof" = atomic ]; then
    SL_ROOT="$SL_ROOT" SL_STATE="$SL_STATE" SL_ETC="$SL_ETC" SL_PROFILE=atomic bash "$parts" --check --quiet
    return 0
  fi
  if [ "$SL_MODE" = install ]; then
    echo ">> secure-linux-parts --install --no-drivers"
    SL_ROOT="$SL_ROOT" SL_STATE="$SL_STATE" SL_ETC="$SL_ETC" SL_PROFILE="$prof" bash "$parts" --install --no-drivers --quiet; rc=$?
  else
    echo ">> secure-linux-parts --reassert"
    SL_ROOT="$SL_ROOT" SL_STATE="$SL_STATE" SL_ETC="$SL_ETC" SL_PROFILE="$prof" bash "$parts" --reassert --quiet; rc=$?
  fi
  case $rc in
    0) ;;
    4) echo "note: some hardware packages are not available on this Fedora release; skipped" ;;
    5) echo "FAILED: software for some hardware could not be downloaded (no internet); run secure-linux-parts --install later" | tee -a "$SL_FAILS" >&2 ;;
    *) echo "FAILED ($rc): secure-linux-parts" | tee -a "$SL_FAILS" >&2 ;;
  esac
  return 0
}

_hw15_clear_all() { local a; for a in drivers-nvidia drivers-mok drivers-b43 drivers-t2-firmware; do sl_clear "$a"; done; }

HW15_NEED_KEY=0
_hw15_main
unset -f _hw15_main _hw15_missing _hw15_pkgs _hw15_pkgs_opt _hw15_kernels _hw15_build _hw15_sb_ready _hw15_keygen \
  _hw15_nvidia _hw15_broadcom _hw15_mac _hw15_t2 _hw15_t2_firmware _hw15_mok _hw15_atomic _hw15_parts _hw15_clear_all
unset HW15_NEED_KEY HW15_KEY_DIR HW15_T2_COPR
return 0
