# shellcheck shell=bash
# 50-apps-full: apps for the main laptop ("full" profile). Sourced by setup.sh. Owned by: experience.
# On "atomic" only the Flatpak apps are installed (no dnf there). Not used on "lite".
# NordVPN, WARP, cloudflared and OpenSnitch are installed by the security step (20/25), not here.
[ "$SL_MODE" = early ] && return 0
case "$SL_PROFILE" in full|atomic) ;; *) return 0 ;; esac
. "$SL_ROOT/files/experience/exp-lib.sh"

# Flatpak apps. On Intel/AMD this is exactly sl_flatpak_install. On ARM (Apple Silicon) an app that Flathub has no
# ARM build of is SKIPPED with a note in skipped-apps (a deliberate skip is not a failure).
_exp50_fp() {
  if ! sl_is_arm; then sl_flatpak_install "$@"; return; fi
  local id rc=0
  for id in "$@"; do
    if flatpak info --system "$id" >/dev/null 2>&1; then sl_unskip_app "$id"; continue; fi
    if sl_flatpak_has_build "$id"; then
      if sl_flatpak_install "$id"; then sl_unskip_app "$id"; else rc=1; fi
    else
      sl_skip_app "$id" "Flathub has no version of this app for Apple Silicon (ARM) computers"
    fi
  done
  return $rc
}

# Steam on ARM: Flathub's Steam is x86-only. Fedora Asahi's own "steam" package (runs x86 games through FEX in a
# small VM) needs a lot of memory, so it is only installed with 16 GB of RAM or more.
_exp50_steam_arm() {
  sl_is_arm || return 0
  if sl_is_atomic; then sl_skip_app steam "Steam for Apple Silicon is a Fedora package and this system type can't install those"; return 0; fi
  if rpm -q steam >/dev/null 2>&1; then sl_unskip_app steam; return 0; fi
  if [ "$(sl_ram_gb)" -lt 16 ]; then
    sl_skip_app steam "Steam on Apple Silicon needs about 16 GB of memory and this computer has $(sl_ram_gb) GB. You can still try: sudo dnf install steam"
  elif ! dnf -q info steam >/dev/null 2>&1; then
    sl_skip_app steam "Fedora's package list for this computer doesn't offer Steam right now"
  elif sl_dnf_install steam; then sl_unskip_app steam
  fi
  return 0
}

# ArtCraft launcher (getartcraft.com, Apache-2.0) from GitHub, checked against the release's SHA256SUMS
# Intel/AMD: the x86_64 RPM. Apple Silicon: the aarch64/arm64 RPM if the makers publish one, else a clean skip.
_exp50_artcraft() {
  local marker="$SL_STATE/artcraft.package" name url sums dir file pat
  name=$(cat "$marker" 2>/dev/null)
  [ -n "$name" ] && rpm -q "$name" >/dev/null 2>&1 && return 0
  case "$(sl_arch)" in
    x86_64) pat='linux-x86_64\.rpm$' ;;
    aarch64) pat='linux-(aarch64|arm64)\.rpm$' ;;
    *) sl_skip_app ArtCraft "no version of ArtCraft exists for this type of computer ($(sl_arch))"; return 0 ;;
  esac
  sl_online || { echo "ArtCraft: offline, will retry on the next repair."; echo "FAILED: ArtCraft (offline)" >> "$SL_FAILS"; return 1; }
  url=$(exp_github_asset storytold/craft-launcher "$pat")
  if [ -z "$url" ] && [ "$(sl_arch)" = aarch64 ] && [ -n "$(exp_github_asset storytold/craft-launcher 'linux.*\.rpm$')" ]; then
    sl_skip_app ArtCraft "ArtCraft's makers don't offer a version for Apple Silicon (ARM) yet"; return 0
  fi
  sums=$(exp_github_asset storytold/craft-launcher 'SHA256SUMS(\.txt)?$')
  if [ -z "$url" ] || [ -z "$sums" ]; then echo "FAILED: ArtCraft release not found" | tee -a "$SL_FAILS"; return 1; fi
  dir=$(mktemp -d); file="$dir/$(basename "$url")"
  if curl -fsSL -o "$file" "$url" && curl -fsSL -o "$dir/SHA256SUMS" "$sums" \
     && exp_verify_sha256 "$file" "$dir/SHA256SUMS" "$(basename "$url")"; then
    echo "ArtCraft: checksum OK"
    rpm -qp --qf '%{NAME}' "$file" 2>/dev/null > "$marker.new" && mv "$marker.new" "$marker"
    try dnf -y install "$file" && sl_unskip_app ArtCraft
  else
    echo "FAILED: ArtCraft download or checksum did not match (not installed)" | tee -a "$SL_FAILS"
  fi
  rm -rf "$dir"
}

# immich-go: uploads big photo batches (Google Takeout) to Immich. Verified against checksums.txt (A9).
_exp50_immich_go() {
  local bin="$SL_R/usr/local/bin/immich-go" url sums dir pat
  [ -x "$bin" ] && return 0                         # never re-download in repair mode
  case "$(sl_arch)" in    # upstream names: immich-go_Linux_x86_64.tar.gz and immich-go_Linux_arm64.tar.gz
    x86_64) pat='immich-go_Linux_x86_64\.tar\.gz$' ;;
    aarch64) pat='immich-go_Linux_arm64\.tar\.gz$' ;;
    *) sl_skip_app immich-go "no version of immich-go exists for this type of computer ($(sl_arch))"; return 0 ;;
  esac
  sl_online || { echo "FAILED: immich-go (offline)" >> "$SL_FAILS"; return 1; }
  url=$(exp_github_asset simulot/immich-go "$pat")
  if [ -z "$url" ] && [ "$(sl_arch)" = aarch64 ] && [ -n "$(exp_github_asset simulot/immich-go 'immich-go_Linux_.*\.tar\.gz$')" ]; then
    sl_skip_app immich-go "immich-go's makers don't offer a version for Apple Silicon (ARM) yet"; return 0
  fi
  sums=$(exp_github_asset simulot/immich-go 'checksums\.txt$')
  if [ -z "$url" ] || [ -z "$sums" ]; then echo "FAILED: immich-go release not found" | tee -a "$SL_FAILS"; return 1; fi
  dir=$(mktemp -d)
  if curl -fsSL -o "$dir/$(basename "$url")" "$url" && curl -fsSL -o "$dir/checksums.txt" "$sums" \
     && exp_verify_sha256 "$dir/$(basename "$url")" "$dir/checksums.txt" "$(basename "$url")" \
     && tar -xzf "$dir/$(basename "$url")" -C "$dir" immich-go; then
    echo "immich-go: checksum OK"
    mkdir -p "$(dirname "$bin")"; install -m 0755 "$dir/immich-go" "$bin"; sl_unskip_app immich-go
  else
    echo "FAILED: immich-go download or checksum did not match (not installed)" | tee -a "$SL_FAILS"
  fi
  rm -rf "$dir"
}

_exp50_ollama() {
  # VERIFY on Fedora 44: `dnf info ollama` exists in the fedora repo and `rpm -ql ollama` lists
  # /usr/lib/systemd/system/ollama.service. If the unit is missing we provide one (below).
  sl_dnf_install ollama
  # The installer makes /usr/share/ollama a Btrfs subvolume (kept out of snapshots), so the package's
  # "useradd -m" doesn't own it: hand it to the ollama user (only when needed)
  local od="$SL_R/usr/share/ollama"
  if [ -d "$od" ] && getent passwd ollama >/dev/null 2>&1 && [ "$(stat -c %U "$od" 2>/dev/null)" != ollama ]; then
    try chown -R ollama:ollama "$od"
  fi
  if ! systemctl cat ollama.service >/dev/null 2>&1 && [ ! -f "$SL_R/etc/systemd/system/ollama.service" ]; then
    sl_write_file "$SL_R/etc/systemd/system/ollama.service" <<'EOF'
# Written by Secure Linux because the ollama package did not ship a unit. Local only (127.0.0.1:11434).
[Unit]
Description=Ollama local AI engine
After=network-online.target

[Service]
ExecStart=/usr/bin/ollama serve
DynamicUser=yes
StateDirectory=ollama
Environment=HOME=/var/lib/ollama
Environment=OLLAMA_MODELS=/var/lib/ollama/models
Environment=OLLAMA_HOST=127.0.0.1:11434
SupplementaryGroups=render video
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    try systemctl daemon-reload
  fi
  systemctl is-enabled --quiet ollama.service 2>/dev/null && systemctl is-active --quiet ollama.service 2>/dev/null || sl_enable ollama.service
  # Re-assert the Vulkan choice (drop-in) without benchmarking
  if [ "$(sl_choice_get ollama_vulkan no)" = yes ]; then "$SL_BIN/secure-linux-ai" vulkan on --quiet
  else [ -f "$SL_R/etc/systemd/system/ollama.service.d/50-secure-linux-vulkan.conf" ] && "$SL_BIN/secure-linux-ai" vulkan off --quiet; fi
  return 0
}

_exp50() {
  sl_step "Installing creative, gaming, coding and AI apps"

  exp_substep "Installing security, messaging, notes and backup apps"
  _exp50_fp io.ente.auth org.signal.Signal com.tutanota.Tutanota net.cozic.joplin_desktop \
    org.gnome.World.PikaBackup org.qbittorrent.qBittorrent

  # Email: the choice made in the welcome wizard ("Apps you used before"). Only a recorded, valid choice
  # installs anything, so plain installs and repair re-runs without the wizard stay untouched. Step 45
  # re-asserts the same choice too; both are idempotent.
  _exp50_email=$(sl_choice_get email_client)
  if [ -n "$_exp50_email" ]; then
    . "$SL_ROOT/files/comfort/comfort-lib.sh"     # for cf_key_allowed
    if cf_key_allowed email_client "$_exp50_email"; then
      exp_substep "Installing the email app you chose"
      case "$_exp50_email" in
        thunderbird)
          if sl_is_atomic; then _exp50_fp org.mozilla.Thunderbird
          elif ! flatpak info --system org.mozilla.Thunderbird >/dev/null 2>&1 && ! rpm -q thunderbird >/dev/null 2>&1; then
            _exp50_fp org.mozilla.Thunderbird || sl_dnf_install thunderbird
          fi ;;
        betterbird) _exp50_fp eu.betterbird.Betterbird ;;
      esac
    fi
  fi
  unset _exp50_email

  exp_substep "Installing art and video apps"
  _exp50_fp org.gimp.GIMP org.kde.krita org.inkscape.Inkscape org.darktable.Darktable \
    org.kde.kdenlive com.obsproject.Studio org.audacityteam.Audacity org.blender.Blender \
    org.upscayl.Upscayl fr.handbrake.ghb

  exp_substep "Installing games apps"
  _exp50_fp com.valvesoftware.Steam com.heroicgameslauncher.hgl net.davidotek.pupgui2
  _exp50_steam_arm

  exp_substep "Installing power tools"
  #   BoxBuddy (distrobox window), Bottles (Windows programs), Gear Lever (AppImages), Warehouse (Flatpaks),
  #   Impression (write ISOs), Czkawka (duplicates), Filelight (disk map), Parabolic (video download),
  #   Easy Effects (better speakers/mic), Ungoogled Chromium (Chrome-only sites, WebUSB)
  _exp50_fp io.github.dvlv.boxbuddyrs com.usebottles.bottles it.mijorus.gearlever \
    io.github.flattool.Warehouse io.gitlab.adhami3310.Impression com.github.qarmin.czkawka org.kde.filelight \
    org.nickvision.tubeconverter com.github.wwmm.easyeffects io.github.ungoogled_software.ungoogled_chromium

  exp_substep "Installing coding apps"
  _exp50_fp com.vscodium.codium com.jeffser.Alpaca

  _exp50_immich_go
  local immich; immich=$(sl_build_get IMMICH_URL)
  if [ -n "$immich" ]; then   # A15: Immich shortcut from build.conf
    sl_write_file "$SL_R/usr/share/applications/immich.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Immich
GenericName=Photos on your home server
Comment=Your private photo library ($immich)
Exec=flatpak run io.gitlab.librewolf-community --new-window $immich
Icon=image-x-generic
Categories=Graphics;Photography;
EOF
  fi

  if sl_is_atomic; then return 0; fi   # the rest needs dnf

  exp_substep "Installing developer tools"
  rpm -q gcc make >/dev/null 2>&1 || try dnf -y group install development-tools
  sl_dnf_install python3-pip pipx nodejs npm java-latest-openjdk-devel gh distrobox podman yt-dlp gamemode
  # qFlipper (Flipper Zero): Fedora package if available, otherwise the Flathub app
  if ! rpm -q qflipper >/dev/null 2>&1 && ! flatpak info --system one.flipperzero.qFlipper >/dev/null 2>&1; then
    if dnf -q info qflipper >/dev/null 2>&1; then sl_dnf_install qflipper; else _exp50_fp one.flipperzero.qFlipper; fi
  fi
  # Device permissions (#20): the RPM brings udev rules; with the Flathub app we add the same rules
  if ! rpm -q qflipper >/dev/null 2>&1 && flatpak info --system one.flipperzero.qFlipper >/dev/null 2>&1; then
    sl_install_file "$SL_EXP/42-flipperzero.rules" "$SL_R/etc/udev/rules.d/42-flipperzero.rules"
  fi

  exp_substep "Installing ArtCraft"
  _exp50_artcraft

  exp_substep "Installing the antivirus (ClamAV + ClamTk)"
  # The scan timer and alerts belong to the system step; we install and keep signatures fresh.
  sl_dnf_install clamav clamav-freshclam clamtk
  [ -f "$SL_R/etc/freshclam.conf" ] && grep -q '^Example' "$SL_R/etc/freshclam.conf" && sed -i 's/^Example/#Example/' "$SL_R/etc/freshclam.conf"
  systemctl is-enabled --quiet clamav-freshclam.service 2>/dev/null || sl_enable clamav-freshclam.service

  exp_substep "Setting up local AI (Ollama)"
  _exp50_ollama
  # Unfiltered model: the user chose it in the installer (ai_abliterated=yes). Import is local; a download
  # happens only if the installer could not copy the file, and never on metered connections.
  if [ "$(sl_choice_get ai_abliterated no)" = yes ]; then
    try "$SL_BIN/secure-linux-ai" import-unfiltered --quiet
  fi
  # Models are only downloaded after the user said yes in the welcome wizard (ai_models set explicitly).
  local models; models=$(sed -n 's/^ai_models=//p' "$SL_ETC/choices" 2>/dev/null | tail -1)
  if [ -n "$models" ] && [ "$models" != none ]; then
    try "$SL_BIN/secure-linux-ai" setup --quiet
  fi
  exp_substep "Setting up the AI coding helper in VSCodium"
  try exp_as_user bash "$SL_EXP/user-setup.sh" continue
  return 0
}
_exp50; unset -f _exp50 _exp50_fp _exp50_steam_arm _exp50_artcraft _exp50_immich_go _exp50_ollama
return 0
