#!/bin/bash
# Prepare a Flipper Zero SD card for Secure Linux netboot (Linux and macOS).
# Run: bash prepare-flipper.sh
# Nothing is written to the card until you pick it by number AND confirm the plan.
set -euo pipefail

REPO_URL=https://github.com/MattyBoyMan/secure-linux-netboot
RELEASE_API=https://api.github.com/repos/MattyBoyMan/secure-linux-netboot/releases/tags/flipper-fap
IPXE_EFI_URL=https://boot.ipxe.org/x86_64-efi/ipxe.efi
IPXE_LKRN_URL=https://boot.ipxe.org/x86_64-pcbios/ipxe.lkrn
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PY=${PYTHON:-python3}
TEMP_FILE=

say()  { printf '%s\n' "$*"; }
step() { printf '\n=== %s ===\n' "$*"; }
confirm() {
  local answer
  while true; do
    printf '%s [y/N] ' "$1"
    IFS= read -r answer || { printf '\n'; return 1; }
    case "$answer" in
      y|Y|yes|YES) return 0 ;;
      ''|n|N|no|NO) return 1 ;;
      *) say 'Please type y for yes, or n for no.' ;;
    esac
  done
}
cleanup() { [ -z "$TEMP_FILE" ] || rm -f -- "$TEMP_FILE"; }
trap cleanup EXIT HUP INT TERM
manual_fap_steps() {
  printf '\n%s\n' 'The Boot2Flipper app is not in a release yet. One manual GitHub step is needed:'
  say '  1. Open https://github.com/MattyBoyMan/secure-linux-netboot and choose Add file -> Create new file.'
  say '  2. Name it .github/workflows/build-flipper-fap.yml. In another tab, open this repository'"'"'s'
  say '     flipper/build-flipper-fap.yml, copy ALL of its text, paste it into the new file, then Commit changes.'
  say '  3. Open Actions -> Build the Boot2Flipper app (Flipper Zero) -> Run workflow -> Run workflow.'
  say '  4. When it finishes, open the repository'"'"'s flipper-fap release; the app will be attached there.'
  say 'Then run prepare-flipper.sh again. It will find the app and copy it onto the card automatically.'
}
for command in curl "$PY" od; do
  command -v "$command" >/dev/null 2>&1 || { printf 'ERROR: %s is needed. Install it and run this script again.\n' "$command" >&2; exit 1; }
done

step 'Find the Flipper SD card'
say 'Mounted removable drives on this computer (your card is usually FAT32):'
IDS=(); MOUNTS=(); LABELS=(); SIZES=(); FILESYSTEMS=()
if [ "$(uname -s)" = Darwin ]; then
  LIST_KIND=macos
else
  LIST_KIND=linux
fi
while IFS=$'\t' read -r id mount label size filesystem; do
  [ -n "$id" ] || continue
  IDS+=("$id"); MOUNTS+=("$mount"); LABELS+=("$label"); SIZES+=("$size"); FILESYSTEMS+=("$filesystem")
done < <("$PY" - "$LIST_KIND" <<'PYEOF'
import glob, json, os, plistlib, subprocess, sys
kind = sys.argv[1]
def clean(value, fallback):
    text = str(value or fallback).replace("\t", " ").replace("\n", " ")
    return text
def emit(device, mount, label, size, filesystem):
    print("\t".join((clean(device, "unknown"), clean(mount, "unknown"), clean(label, "(no label)"),
                     clean(size, "unknown size"), clean(filesystem, "unknown format"))))
if kind == "linux":
    try:
        data = json.loads(subprocess.check_output(
            ["lsblk", "-J", "-p", "-o", "NAME,LABEL,SIZE,FSTYPE,RM,TRAN,MOUNTPOINT"], text=True))
    except (OSError, subprocess.CalledProcessError):
        raise SystemExit(0)
    def walk(node, removable=False):
        removable = removable or node.get("rm") is True or node.get("rm") == 1
        mount = node.get("mountpoint")
        if removable and mount:
            emit(node.get("name"), mount, node.get("label"), node.get("size"), node.get("fstype"))
        for child in node.get("children") or []:
            walk(child, removable)
    for disk in data.get("blockdevices", []):
        walk(disk)
else:
    for volume in sorted(glob.glob("/Volumes/*")):
        try:
            raw = subprocess.check_output(["diskutil", "info", "-plist", volume])
            info = plistlib.loads(raw)
        except (OSError, subprocess.CalledProcessError):
            continue
        removable = info.get("Removable") or info.get("Ejectable") or not info.get("Internal", True)
        if not removable:
            continue
        size_bytes = info.get("TotalSize")
        size = ("%.1f GB" % (size_bytes / 1000000000.0)) if size_bytes else "unknown size"
        emit(info.get("DeviceNode"), info.get("MountPoint") or volume,
             info.get("VolumeName") or os.path.basename(volume), size,
             info.get("FilesystemName") or info.get("FilesystemType"))
PYEOF
)
count=${#IDS[@]}
if [ "$count" -eq 0 ]; then
  say 'No mounted removable drive was found. Put the Flipper SD card in its reader, let it mount,'
  say 'then run this script again. No drive has been chosen and nothing was written.'
  exit 1
fi
for ((i = 0; i < count; i++)); do
  printf '  %d) %s mounted at %s\n     Label: %s | Size: %s | Format: %s\n' \
    "$((i + 1))" "${IDS[$i]}" "${MOUNTS[$i]}" "${LABELS[$i]}" "${SIZES[$i]}" "${FILESYSTEMS[$i]}"
done
suggested=0
fat_count=0
for ((i = 0; i < count; i++)); do
  case "${FILESYSTEMS[$i]}" in
    FAT32|fat32|*FAT32*|*fat32*) fat_count=$((fat_count + 1)); suggested=$((i + 1)) ;;
  esac
done
if [ "$fat_count" -eq 1 ]; then
  say "Suggested answer: $suggested (the only removable FAT32 drive). Check its label and size yourself."
else
  suggested=0
fi
selected=0
while [ "$selected" -eq 0 ]; do
  if [ "$suggested" -ne 0 ]; then
    printf 'Type the number of the Flipper SD card [%d] ' "$suggested"
  else
    printf 'Type the number of the Flipper SD card '
  fi
  IFS= read -r answer || { printf '\nNo drive chosen. Nothing was written.\n'; exit 1; }
  [ -n "$answer" ] || answer=$suggested
  case "$answer" in
    *[!0-9]*|'') selected=0 ;;
    *) if [ "$answer" -ge 1 ] && [ "$answer" -le "$count" ]; then selected=$answer; fi ;;
  esac
  [ "$selected" -ne 0 ] || say 'That is not one of the numbers above. No drive has been chosen.'
done
index=$((selected - 1))
card=${MOUNTS[$index]}
say "You chose ${IDS[$index]} at $card - ${LABELS[$index]}, ${SIZES[$index]}, ${FILESYSTEMS[$index]}."

step 'Confirm before anything is written'
say 'The script will now, on the CHOSEN CARD only:'
say "  - copy apps_data/boot2flipper and badusb into $card/"
say '  - download and verify ipxe.efi and ipxe.lkrn into apps_data/boot2flipper/ipxe/'
say '  - look for boot2flipper.fap in the latest public release and copy it to apps/USB/'
say 'Files with those same names are replaced. Your other files are not deleted. Downloads use temporary names first.'
if ! confirm "Write these Secure Linux files to ${IDS[$index]} at $card?"; then
  say 'Cancelled. Nothing was written to the card.'
  exit 0
fi

verify_download() {
  local file=$1 kind=$2 size signature
  size=$(wc -c < "$file" | tr -d ' ')
  if [ "$kind" = fap ]; then
    [ "$size" -ge 1024 ] && [ "$size" -le 16777216 ] && return 0
    say "ERROR: downloaded FAP size $size bytes is outside the safe sanity range." >&2
    return 1
  fi
  [ "$size" -ge 65536 ] && [ "$size" -le 16777216 ] || {
    say "ERROR: downloaded size $size bytes is outside the safe sanity range." >&2; return 1; }
  case "$kind" in
    efi)
      signature=$(od -An -N2 -tx1 "$file" | tr -d ' \n')
      [ "$signature" = 4d5a ] || { say 'ERROR: ipxe.efi does not start with the PE MZ signature.' >&2; return 1; }
      ;;
    lkrn)
      signature=$(od -An -j514 -N4 -tc "$file" | tr -d ' \n')
      [ "$signature" = HdrS ] || { say 'ERROR: ipxe.lkrn does not have the Linux kernel HdrS signature at byte 514.' >&2; return 1; }
      ;;
  esac
}
show_hash() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"
  else say 'SHA-256 tool not available; size and signature checks above did run.'
  fi
}
download_verified() {
  local url=$1 destination=$2 kind=$3 parent temporary
  parent=${destination%/*}
  mkdir -p -- "$parent"
  temporary="$parent/.${destination##*/}.download.$$.tmp"
  TEMP_FILE=$temporary
  say "Downloading $url"
  if ! curl -fL --retry 3 -o "$temporary" "$url"; then
    say "ERROR: could not download $url. The partial download was removed." >&2
    rm -f -- "$temporary"; TEMP_FILE=
    return 1
  fi
  if ! verify_download "$temporary" "$kind"; then
    say "ERROR: verification failed for $url. Nothing was moved into place." >&2
    rm -f -- "$temporary"; TEMP_FILE=
    return 1
  fi
  mv -f -- "$temporary" "$destination"
  TEMP_FILE=
  say "Verified and copied $destination"
  say 'SHA-256 for your records:'
  show_hash "$destination"
}

step 'Copy the Secure Linux SD-card pack'
for folder in apps_data badusb; do
  [ -d "$HERE/$folder" ] || { printf 'ERROR: the prep pack is incomplete: %s is missing\n' "$HERE/$folder" >&2; exit 1; }
  mkdir -p -- "$card/$folder"
  cp -a "$HERE/$folder/." "$card/$folder/"
  say "Copied $folder to $card/$folder"
done

step 'Download and verify the iPXE boot files'
say 'boot.ipxe.org does not publish SHA-256 checksums for these downloads. The checks below confirm'
say 'the expected size and file signature (PE MZ for EFI, Linux HdrS for LKRN); they are sanity checks,'
say 'not cryptographic proof that the files came from iPXE. HTTPS provides the transport protection.'
ipxe_dir=$card/apps_data/boot2flipper/ipxe
download_verified "$IPXE_EFI_URL" "$ipxe_dir/ipxe.efi" efi
download_verified "$IPXE_LKRN_URL" "$ipxe_dir/ipxe.lkrn" lkrn

step 'Get the Boot2Flipper app, if a release exists'
fap_copied=0
fap_destination=$card/apps/USB/boot2flipper.fap
api_json=$(mktemp)
asset_url=
if curl -fsSL -H 'Accept: application/vnd.github+json' -H 'User-Agent: Secure-Linux-Flipper-Prep' \
     -o "$api_json" "$RELEASE_API"; then
  asset_url=$("$PY" - "$api_json" <<'PYEOF'
import json, sys
try:
    release = json.load(open(sys.argv[1], encoding="utf-8"))
    for asset in release.get("assets") or []:
        if asset.get("name") == "boot2flipper.fap" and asset.get("browser_download_url"):
            print(asset["browser_download_url"])
            break
except (OSError, ValueError, TypeError):
    pass
PYEOF
)
else
  say 'No downloadable flipper-fap release was reported by GitHub.'
fi
rm -f -- "$api_json"
if [ -n "$asset_url" ]; then
  download_verified "$asset_url" "$fap_destination" fap
  fap_copied=1
else
  manual_fap_steps
fi

step 'Verification summary'
say "SD pack:      $card/apps_data/ and $card/badusb/"
for name in ipxe.efi ipxe.lkrn; do
  if [ -f "$ipxe_dir/$name" ]; then say "Present:       $ipxe_dir/$name"; else say "MISSING:       $ipxe_dir/$name"; fi
done
if [ "$fap_copied" -eq 1 ] && [ -f "$fap_destination" ]; then
  say "Present:       $fap_destination"
else
  say "Still missing: $fap_destination (follow the GitHub steps above, then re-run this script)"
fi
printf '\n%s\n' "You're ready - here's how to use it:"
say '  1. Put the SD card in the Flipper. Open USB -> Boot2Flipper, choose Load Config, then config.b2f.'
say '  2. Press Start in Boot2Flipper and plug the Flipper into the computer you want to set up.'
say '  3. Start that computer from its boot menu, pick FLIPPER Boot2Flipper, then press Enter on the install.'
say 'The install menu waits for you. Nothing starts or is erased automatically.'
