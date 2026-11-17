#!/usr/bin/env bash
# start-nomad.sh - start Project NOMAD (offline library, AI chat, maps) from the Secure Linux drive.
#
#   sudo bash start-nomad.sh                 start it (this computer only; works with no internet)
#   sudo bash start-nomad.sh --share home    also let devices on your HOME network open it (they type a code once)
#   sudo bash start-nomad.sh --check         only check whether this computer can run it
#   sudo bash start-nomad.sh --lite          just the offline library (for small or virtual computers)
#   sudo bash start-nomad.sh --store computer  keep NOMAD's data on this computer instead of the drive
#   more: --no-ai  --data-size GB  --online|--offline  --new-code  --kit FOLDER  --yes  --help
#
# Works on any Linux the drive offers (Fedora full/lite/live, Debian, Ubuntu): uses Podman or Docker,
# whichever is there. Loads the pinned app images from the drive, so no internet is needed.
# Kit: Project NOMAD v1.35.1 (Apache-2.0, Crosstalk Solutions). Nothing is sent anywhere.
set -u
# 022: NOMAD's apps run as different users (Kiwix runs as 'user'), so books/models/maps must be readable;
# only secrets.env is made private (600) below.
umask 022

KIT_VERSION="2026-11-17"
NOMAD_VERSION="v1.35.1"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# KIT: the NOMAD folder whose images/ and content/ are used (the drive's SecureLinux-NOMAD, or the small copy an
# installed Secure Linux keeps). The helper programs always come from next to this script, so a newer script can
# use an older drive copy's images and books.
KIT=${NOMAD_KIT_DIR:-$HERE}
TOOLS=$HERE/tools
RUN=${NOMAD_RUN_DIR:-/run/nomad}
MIRROR_PORT=${NOMAD_MIRROR_PORT:-5765}
NET=project-nomad_default
ADMIN_IMAGE=ghcr.io/crosstalk-solutions/project-nomad:v1.35.1
COLLECTOR_IMAGE=ghcr.io/crosstalk-solutions/project-nomad-disk-collector:v1.31.1
MYSQL_IMAGE=mysql:8.0
REDIS_IMAGE=redis:7-alpine
KIWIX_IMAGE=ghcr.io/kiwix/kiwix-serve:3.8.1
# Every port NOMAD or its apps publish (admin 8080, library 8090, data tools 8100, notes 8200,
# education 8310-8311, Supply Depot 8400-8599, vector db 6333-6334, AI 11434, log viewer 9999).
GUARD_PORTS="6333-6334, 8080, 8090, 8100, 8200, 8310-8311, 8400-8599, 9999, 11434"
# --share home: other devices reach NOMAD's web pages ONLY through the login gate (tools/nomad_gate.py). The privacy
# rule sends their connections for these ports to the gate (same port number + GATE_OFFSET, home-network addresses
# only); the gate asks each device once for the access code shown on this computer. The vector database (6333-6334),
# the AI engine (11434) and the log viewer (9999) are never reachable from other devices.
GATE_PORTS="8080, 8090, 8100, 8200, 8310-8311, 8400-8599"
GATE_OFFSET=10000
MIN_RAM_MB=3584      # upstream minimum 4 GB (a "4 GB" machine reports ~3.7-3.9 GB usable)
AI_RAM_MB=7168       # 8 GB class: the starter AI model (llama3.2 3B, ~2 GB) needs ~its size in memory plus NOMAD
HEADROOM_GB=5        # always leave this much free on the drive / disk

SHARE=computer STORE=auto MODE=full CHECK_ONLY=no AI=auto NET_MODE=auto YES=no DATA_SIZE_GB="" GUARD_OK=no NEW_CODE=no
SHARE_CODE="" GATE_ON=no
ORIG_ARGS=("$@")

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
warn() { printf 'NOTE: %s\n' "$*" >&2; }
die()  { printf '\nSTOPPED: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --share) SHARE=${2:-}; shift ;;
    --share=*) SHARE=${1#*=} ;;
    --store) STORE=${2:-}; shift ;;
    --store=*) STORE=${1#*=} ;;
    --lite|--content-only) MODE=lite ;;
    --check) CHECK_ONLY=yes ;;
    --no-ai) AI=no ;;
    --online) NET_MODE=online ;;
    --offline) NET_MODE=offline ;;
    --yes|-y) YES=yes ;;
    --new-code) NEW_CODE=yes ;;
    --kit) KIT=${2:-}; shift ;;
    --kit=*) KIT=${1#*=} ;;
    --data-size) DATA_SIZE_GB=${2:-}; shift ;;
    --data-size=*) DATA_SIZE_GB=${1#*=} ;;
    -h|--help) usage ;;
    *) die "I don't know the option '$1'. Try: bash start-nomad.sh --help" ;;
  esac
  shift
done
# PATH 1, the live system started from the drive (X5anywhere F9/F12): when the drive also carries the checked starter
# (START-NOMAD-LINUX.sh beside this folder), NOMAD starts through it, so the drive's files are fingerprint-checked
# first and NOMAD's saved data is locked with a passphrase. Not for --check, --lite, --store, --kit, --yes or
# --new-code, and never when the checked starter itself runs this script (it always gives --store computer).
# On any other Linux this script starts as before and names the checked starter.
nomad_live_system() {
  case "${NOMAD_FAKE_LIVE:-}" in 1) return 0 ;; 0) return 1 ;; esac
  [ -d /run/initramfs/live ] || grep -qw 'rd.live.image' /proc/cmdline 2>/dev/null
}
if [ -f "$HERE/../START-NOMAD-LINUX.sh" ] && [ -f "$HERE/../NOMAD-ANYWHERE/nomad-anywhere-common.sh" ] \
   && [ "$STORE" = auto ] && [ "$MODE" = full ] && [ "$CHECK_ONLY" = no ] && [ "$YES" = no ] && [ "$NEW_CODE" = no ] \
   && [ "$KIT" = "$HERE" ] && [ -z "${NOMAD_COMPUTER_DATA:-}" ]; then
  if nomad_live_system; then
    CHECKED_ARGS=()
    [ "$SHARE" = computer ] || CHECKED_ARGS+=(--share "$SHARE")
    [ "$AI" = no ] && CHECKED_ARGS+=(--no-ai)
    case "$NET_MODE" in online) CHECKED_ARGS+=(--online) ;; offline) CHECKED_ARGS+=(--offline) ;; esac
    [ -n "$DATA_SIZE_GB" ] && CHECKED_ARGS+=(--data-size "$DATA_SIZE_GB")
    say "Starting NOMAD through START-NOMAD-LINUX.sh: it checks this drive's files first and keeps NOMAD's saved data locked with a passphrase."
    exec bash "$HERE/../START-NOMAD-LINUX.sh" full ${CHECKED_ARGS[@]+"${CHECKED_ARGS[@]}"}
  fi
  warn "This drive also has the checked starter. To check the drive's files first and lock NOMAD's saved data, use (from the drive's top folder): sudo bash START-NOMAD-LINUX.sh full"
fi
case "$SHARE" in computer|home) ;; *) die "--share must be 'computer' (only this computer) or 'home' (your home network)." ;; esac
case "$STORE" in auto|drive|computer) ;; *) die "--store must be 'drive' or 'computer'." ;; esac
case "$DATA_SIZE_GB" in ''|*[!0-9]*) [ -z "$DATA_SIZE_GB" ] || die "--data-size needs a number of GB, e.g. --data-size 60" ;; esac
[ -n "$KIT" ] && [ -d "$KIT" ] && KIT=$(cd "$KIT" && pwd -P) || die "The NOMAD folder was not found: ${KIT:-(empty)}"
# Whose lists. With another folder's data (--kit: the installed Secure Linux with a plugged-in drive) every list comes
# from beside THIS script, never from that folder: the app-image list (images/fetch-log.jsonl) and the list of books,
# maps and AI model files (content-pins.txt). The other folder gives only bytes, each checked against these lists
# before it is used, and a saved-data file in it is opened only when this computer made it. A folder that starts
# itself (the drive's own copy) uses its own lists, as before.
if [ "$KIT" = "$HERE" ]; then TRUST=self LISTS=$KIT
elif [ -f "$HERE/images/fetch-log.jsonl" ]; then TRUST=anchored LISTS=$HERE
else TRUST=other LISTS=$KIT; warn "This start program has no lists of its own, so it uses the lists in $KIT."; fi
CONTENT_PINS=""
[ "$TRUST" = anchored ] && [ -f "$HERE/content-pins.txt" ] && CONTENT_PINS=$HERE/content-pins.txt
KNOWN_DATA=${NOMAD_STATE_DIR:-/var/lib/secure-linux}/nomad-known-data

# ------------------------------------------------------------------ hardware check
hw_arch()  { echo "${NOMAD_FAKE_ARCH:-$(uname -m)}"; }
hw_mem_mb() {
  if [ -n "${NOMAD_FAKE_MEM_KB:-}" ]; then echo $(( NOMAD_FAKE_MEM_KB / 1024 )); return; fi
  awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0
}
hw_virt() {
  if [ -n "${NOMAD_FAKE_VIRT:-}" ]; then echo "$NOMAD_FAKE_VIRT"; return; fi
  local v=""
  if command -v systemd-detect-virt >/dev/null 2>&1; then v=$(systemd-detect-virt --vm 2>/dev/null || true); fi
  if [ -z "$v" ] || [ "$v" = none ]; then
    if grep -qw hypervisor /proc/cpuinfo 2>/dev/null; then v=hypervisor; else v=none; fi
  fi
  echo "$v"
}

hardware_check() {
  local arch mem virt
  arch=$(hw_arch); mem=$(hw_mem_mb); virt=$(hw_virt)
  step "Checking this computer"
  say "Processor type: $arch | Memory: $(( mem / 1024 )) GB ($mem MB) | Virtual machine: $virt"
  case "$arch" in
    x86_64|amd64) ;;
    *) say ""
       say "This computer is not able to run NOMAD from this drive."
       say "Why: its processor is '$arch' (for example ARM, like a Raspberry Pi or an Apple M-chip)."
       say "     The NOMAD apps on this drive are built for normal PC processors (x86_64) only."
       say "Nothing was installed or changed."
       exit 3 ;;
  esac
  if [ "$virt" != none ] && [ "$MODE" = full ]; then
    say ""
    say "This computer is a virtual machine ($virt), so the full NOMAD is not started."
    say "Why: NOMAD (and its AI) needs real hardware; upstream does not support virtual machines."
    say "You can still use the offline library on its own:  sudo bash start-nomad.sh --lite"
    say "Nothing was installed or changed."
    exit 4
  fi
  if [ "$mem" -lt "$MIN_RAM_MB" ] && [ "$MODE" = full ]; then
    say ""
    say "This computer is not big enough for the full NOMAD."
    say "Why: it has $(( mem / 1024 )) GB of memory; NOMAD needs at least 4 GB."
    say "You can still use the offline library on its own:  sudo bash start-nomad.sh --lite"
    say "Nothing was installed or changed."
    exit 5
  fi
  if [ "$AI" = auto ]; then
    if [ "$mem" -ge "$AI_RAM_MB" ]; then AI=yes; else AI=no
      say "The AI assistant stays off: it needs about 8 GB of memory and this computer has $(( mem / 1024 )) GB."
    fi
  fi
  say "Result: OK for $( [ "$MODE" = lite ] && echo 'the offline library (lite)' || echo 'NOMAD' )$( [ "$MODE" = full ] && [ "$AI" = yes ] && echo ' with the AI assistant' )."
}

# ------------------------------------------------------------------ helpers
need_root() {
  [ "${NOMAD_TEST:-}" = 1 ] && return 0
  if [ "$(id -u)" != 0 ]; then
    if command -v sudo >/dev/null 2>&1; then exec sudo -- bash "${BASH_SOURCE[0]}" "$@"; fi
    die "Please run me as the administrator:  sudo bash start-nomad.sh"
  fi
}

is_online() {
  case "$NET_MODE" in online) return 0 ;; offline) return 1 ;; esac
  [ "${NOMAD_TEST:-}" = 1 ] && return 1
  command -v curl >/dev/null 2>&1 || return 1
  curl -s -m 6 -o /dev/null https://ghcr.io/v2/ 2>/dev/null
}

# Full image name: a Docker Hub name without a registry gets docker.io/ (and library/), so Podman never stops to
# ask "which registry?" (Fedora's short-name rule) and the tag matches the name a drive image gets when loaded.
full_name() {
  local n=$1
  case "$n" in
    */*) case "${n%%/*}" in *.*|*:*|localhost) printf '%s\n' "$n" ;; *) printf 'docker.io/%s\n' "$n" ;; esac ;;
    *) printf 'docker.io/library/%s\n' "$n" ;;
  esac
}

# Long-running helpers get their own session, so closing the terminal window does not stop them.
detach() { if command -v setsid >/dev/null 2>&1; then setsid "$@"; else "$@"; fi; }

sock_ready() { [ -S "$1" ] || { [ "${NOMAD_TEST:-}" = 1 ] && [ -e "$1" ]; }; }

free_gb() { df -Pk "$1" 2>/dev/null | awk 'NR==2{print int($4/1048576)}'; }

lock_entries() {  # prints: ref<TAB>repotag<TAB>file<TAB>config_digest<TAB>sha256-or-<TAB>pull_ref  (last entry per ref)
  python3 -I - "$LISTS/images/fetch-log.jsonl" <<'PY'
import json,sys
last={}
for l in open(sys.argv[1],encoding="utf-8"):
    l=l.strip()
    if not l: continue
    e=json.loads(l)
    if e.get("kind")=="image": last[e["ref"]]=e
for e in last.values():
    print("\t".join([e["ref"],e["repotag"],e["file"],e["config_digest"],e.get("sha256") or "-",e.get("pull_ref","")]))
PY
}

# ------------------------------------------------------------------ checks of a drive's files (see TRUST above)
file_sha() { sha256sum < "$1" 2>/dev/null | awk '{print $1}'; }
pin_of() {   # pin_of REL: the SHA-256 this computer's list has for REL (content/...); nothing when not listed
  [ -n "$CONTENT_PINS" ] || return 1
  awk -v r="$1" 'substr($0, 1, 1) != "#" && index($0, "  ") == 65 {
      rel = substr($0, 67); sub(/\t.*/, "", rel); if (rel == r) { print substr($0, 1, 64); exit } }' "$CONTENT_PINS"
}
checked_copy() {   # checked_copy FROM TO REL: copy; with another folder's data keep it only when it matches the list
  local want=""
  if [ "$TRUST" = anchored ]; then
    want=$(pin_of "$3")
    [ -n "$want" ] || { warn "skipped ${3##*/}: it is not on this computer's list of NOMAD files"; return 1; }
  fi
  cp -f "$1" "$2.part" || { rm -f "$2.part"; return 1; }
  if [ -n "$want" ] && [ "$(file_sha "$2.part")" != "$want" ]; then
    rm -f "$2.part"; warn "skipped ${3##*/}: it is not the file this computer expects (its SHA-256 differs)"; return 1
  fi
  mv -f "$2.part" "$2"
}
known_data() {   # known_data IMG: this computer made that data file (its file-system ID is on this computer's list)
  local id
  id=$(blkid -p -s UUID -o value "$1" 2>/dev/null | head -n 1)
  [ -n "$id" ] && grep -qxF -- "$id" "$KNOWN_DATA" 2>/dev/null
}
remember_data() {
  local id
  id=$(blkid -p -s UUID -o value "$1" 2>/dev/null | head -n 1)
  [ -n "$id" ] || return 0
  mkdir -p "${KNOWN_DATA%/*}" 2>/dev/null && ( umask 077; printf '%s\n' "$id" >> "$KNOWN_DATA" ) 2>/dev/null
  return 0
}
load_secrets() {   # NOMAD's own secrets file is READ (three KEY=letters-and-digits lines), never run as commands
  local k v
  APP_KEY="" DB_ROOT_PASSWORD="" DB_PASSWORD=""
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case "$k" in APP_KEY|DB_ROOT_PASSWORD|DB_PASSWORD) ;; *) continue ;; esac
    case "$v" in ''|*[!A-Za-z0-9]*) continue ;; esac
    printf -v "$k" '%s' "$v"
  done < "$DATA/secrets.env"
  [ -n "$APP_KEY" ] && [ -n "$DB_ROOT_PASSWORD" ] && [ -n "$DB_PASSWORD" ] \
    || die "NOMAD's private settings file is damaged ($DATA/secrets.env). NOMAD was not started."
}

# ------------------------------------------------------------------ container engine
ENGINE="" SOCK="" E=()
pick_engine() {
  step "Finding the container engine (Podman or Docker)"
  if [ -n "${NOMAD_FORCE_ENGINE:-}" ]; then ENGINE=$NOMAD_FORCE_ENGINE
  elif command -v podman >/dev/null 2>&1; then ENGINE=podman
  elif command -v docker >/dev/null 2>&1; then ENGINE=docker
  else
    say "Neither Podman nor Docker is on this Linux, and they cannot be added without internet."
    say "One-time fix while connected to the internet, then run me again:"
    if command -v dnf >/dev/null 2>&1; then say "    sudo dnf install -y podman"
    elif command -v apt-get >/dev/null 2>&1; then say "    sudo apt-get install -y podman"
    else say "    install the 'podman' package with your system's software tool"; fi
    say "(The Secure Linux full Fedora install already includes Podman.) Nothing was changed."
    exit 6
  fi
  command -v python3 >/dev/null 2>&1 || die "python3 is missing (it is part of every Fedora/Debian/Ubuntu desktop). Install it once: sudo dnf install python3  or  sudo apt-get install python3"
  say "Using: $ENGINE"
}

start_engine() {
  mkdir -p "$RUN"
  if [ "$ENGINE" = podman ]; then
    # A private Podman service just for NOMAD: its image/container store lives inside NOMAD's own
    # data area (on the drive in drive mode), it talks on its own socket, and it uses a registry
    # mirror served from the drive so app installs work with no internet.
    SOCK="$RUN/podman.sock"
    # temp space for image uploads lives in the data area too (the 5 GB AI image would not fit in RAM-backed /run)
    mkdir -p "$DATA/podman/root" "$DATA/podman/tmp" "$RUN/podman-run"
    cat > "$RUN/registries.conf" <<EOF
# NOMAD kit: pinned images come from the drive first (127.0.0.1 only), then the real registries.
unqualified-search-registries = ["docker.io"]
short-name-mode = "permissive"
[[registry]]
prefix = "docker.io"
location = "docker.io"
[[registry.mirror]]
location = "127.0.0.1:$MIRROR_PORT/dockerio"
insecure = true
[[registry]]
prefix = "ghcr.io"
location = "ghcr.io"
[[registry.mirror]]
location = "127.0.0.1:$MIRROR_PORT/ghcr"
insecure = true
EOF
    if ! sock_ready "$SOCK" || ! curl -s -m 3 --unix-socket "$SOCK" http://d/_ping >/dev/null 2>&1; then
      rm -f "$SOCK"
      detach python3 -I "$TOOLS/nomad_mirror.py" "$KIT/images" "$MIRROR_PORT" >"$RUN/mirror.log" 2>&1 &
      echo $! > "$RUN/mirror.pid"
      CONTAINERS_REGISTRIES_CONF="$RUN/registries.conf" TMPDIR="$DATA/podman/tmp" \
        detach podman --root "$DATA/podman/root" --runroot "$RUN/podman-run" system service --time=0 "unix://$SOCK" \
        >"$RUN/podman-service.log" 2>&1 &
      echo $! > "$RUN/podman-service.pid"
      local i; for i in $(seq 1 30); do sock_ready "$SOCK" && break; sleep 1; done
      sock_ready "$SOCK" || die "Podman did not start. Details: $RUN/podman-service.log"
    fi
    E=(podman --remote --url "unix://$SOCK")
  else
    SOCK=/var/run/docker.sock
    if ! docker info >/dev/null 2>&1; then
      command -v systemctl >/dev/null 2>&1 && systemctl start docker >/dev/null 2>&1
      docker info >/dev/null 2>&1 || die "Docker is installed but not running, and I could not start it (sudo systemctl start docker)."
    fi
    E=(docker)
  fi
}

load_images() {
  step "Loading the NOMAD app images from the drive (first time only)"
  local ref repotag file cfg want pull have n=0 missing=0 core core_missing=""
  # without these NOMAD cannot start at all (the other apps are optional)
  if [ "$MODE" = lite ]; then core="$KIWIX_IMAGE"; else core="$ADMIN_IMAGE $MYSQL_IMAGE $REDIS_IMAGE"; fi
  while IFS=$'\t' read -r ref repotag file cfg want pull; do
    [ -n "$ref" ] || continue
    if [ "$MODE" = lite ] && [ "$repotag" != "$KIWIX_IMAGE" ]; then continue; fi
    have=$("${E[@]}" image inspect --format='{{.Id}}' "$repotag" 2>/dev/null | head -n1)
    case "$have" in sha256:*) ;; ?*) have="sha256:$have" ;; esac
    if [ "$have" = "$cfg" ]; then n=$((n+1)); continue; fi
    if [ -f "$KIT/images/$file" ]; then
      # the file's SHA-256 is checked against the list BEFORE the container tool reads it
      if [ ${#want} = 64 ]; then
        say "  checking $file ..."
        [ "$(file_sha "$KIT/images/$file")" = "$want" ] || die "The app file $file is not the one this computer expects (its SHA-256 differs), so it was not loaded. If the drive was made with a newer Secure Linux, update Secure Linux on this computer first; otherwise use another NOMAD drive, or copy the SecureLinux-NOMAD folder again from a good drive."
      elif [ "$TRUST" != self ]; then
        die "This computer's list has no SHA-256 for $file, so it was not loaded."
      fi
      say "  loading $repotag ..."
      "${E[@]}" load -i "$KIT/images/$file" >/dev/null || die "Could not load $file. Run verify-nomad-kit.sh to check the drive."
    elif is_online && [ -n "$pull" ]; then
      say "  not on the drive; downloading pinned $pull ..."
      "${E[@]}" pull "$(full_name "$pull")" >/dev/null && "${E[@]}" tag "$(full_name "$pull")" "$(full_name "$repotag")" \
        || die "Download of $pull failed."
    else
      warn "$repotag is not on the drive and there is no internet; that app will not be available."
      case " $core " in *" $repotag "*) core_missing="$core_missing $repotag" ;; esac
      missing=$((missing+1)); continue
    fi
    have=$("${E[@]}" image inspect --format='{{.Id}}' "$repotag" 2>/dev/null | head -n1)
    case "$have" in sha256:*) ;; ?*) have="sha256:$have" ;; esac
    [ "$have" = "$cfg" ] || die "Image check failed for $repotag (expected $cfg, got ${have:-nothing}). The drive copy may be damaged: run verify-nomad-kit.sh"
    n=$((n+1))
  done < <(lock_entries)
  # a main part that the list does not even name (an incomplete or damaged copy) is missing too
  for ref in $core; do
    case " $core_missing " in *" $ref "*) continue ;; esac
    have=$("${E[@]}" image inspect --format='{{.Id}}' "$ref" 2>/dev/null | head -n1)
    [ -n "$have" ] || core_missing="$core_missing $ref"
  done
  if [ -n "$core_missing" ]; then
    say ""
    say "NOMAD's main parts are not on this computer yet:$core_missing"
    say "Plug in the Secure Linux drive that has the SecureLinux-NOMAD folder, or connect to the internet once,"
    say "then start NOMAD again. NOMAD was not started."
    say "Before unplugging the drive, run:  sudo bash stop-nomad.sh   (it closes anything that was already prepared)"
    exit 9
  fi
  say "Images ready: $n (missing: $missing). Each one matches its pinned SHA-256 image ID."
}

check_repotags() {
  # NOMAD skips its own download only if the engine lists the exact name it asks for.
  [ "$ENGINE" = podman ] || return 0
  local listing missing=""
  listing=$(curl -s -m 10 --unix-socket "$SOCK" http://d/images/json 2>/dev/null)
  local name
  for name in qdrant/qdrant:v1.16 ollama/ollama:0.33.3 dullage/flatnotes:v5.5.4 learningequality/kolibri:0.19.4 "$KIWIX_IMAGE" ghcr.io/gchq/cyberchef:10.24.0; do
    case "$listing" in *"\"$name\""*) ;; *) missing="$missing $name" ;; esac
  done
  if [ -n "$missing" ]; then
    say "  (Podman lists some images under their full docker.io name; the drive mirror on 127.0.0.1:$MIRROR_PORT answers NOMAD's requests for:$missing)"
  fi
}

# ------------------------------------------------------------------ data area
DATA="" STORE_DIR=""
setup_data() {
  step "Preparing NOMAD's data area"
  local asked=$STORE
  if [ "$STORE" = auto ]; then STORE=drive; fi
  # Another folder's saved-data file is opened only when this computer made it: a file from another computer could hold
  # anything (programs, settings, a container store), and opening it runs as the administrator.
  if [ "$STORE" = drive ] && [ "$TRUST" != self ] && [ -f "$KIT/data/nomad-data.img" ] && ! known_data "$KIT/data/nomad-data.img"; then
    if [ "$asked" = drive ]; then
      warn "You asked for the saved data on the drive although this computer did not make that file; it is used because you asked, and remembered as yours."
      remember_data "$KIT/data/nomad-data.img"
    else
      say "NOMAD's saved-data file on this drive was not made on this computer, so it is not opened here (a file from"
      say "another computer could hold anything). This time NOMAD keeps its data on this computer."
      say "If that file is yours, use it with:  secure-linux-nomad start --store drive"
      STORE=computer
    fi
  fi
  if [ "$STORE" = computer ]; then
    DATA=${NOMAD_COMPUTER_DATA:-/opt/project-nomad}
    mkdir -p "$DATA"
    say "Data stays on this computer in $DATA"
  else
    local img="$KIT/data/nomad-data.img" mnt="$RUN/data"
    mkdir -p "$KIT/data" 2>/dev/null
    if ! ( : > "$KIT/data/.write-test" ) 2>/dev/null; then
      say "The drive is read-only right now, so NOMAD cannot keep its data on it."
      say "If this is the Windows-formatted (NTFS) drive: Windows 'Fast Startup' locks it. In Windows choose"
      say "Restart (not Shut down) once, or use the STORAGE drive. Or keep the data on this computer:"
      say "    sudo bash start-nomad.sh --store computer"
      exit 7
    fi
    rm -f "$KIT/data/.write-test"
    mkdir -p "$mnt"
    if ! mountpoint -q "$mnt" 2>/dev/null; then
      if [ ! -f "$img" ]; then
        # smallest useful size: unpacked apps + starter content + 10 GB working room
        local min want free
        min=$(du -sk "$KIT/images" "$KIT/content" 2>/dev/null | awk '{s+=$1} END{print int(s/1048576)+10}')
        [ "${min:-0}" -ge 20 ] || min=20
        want=${DATA_SIZE_GB:-40}; [ "$want" -ge "$min" ] || want=$min
        free=$(free_gb "$KIT/data"); free=${free:-0}
        if [ $(( want + HEADROOM_GB )) -gt "$free" ]; then
          want=$(( free - HEADROOM_GB ))
          [ "$want" -ge "$min" ] || die "The drive has only ${free} GB free; NOMAD needs about $((min + HEADROOM_GB)) GB there. Free some space, or keep the data on this computer: --store computer"
          warn "Using ${want} GB for NOMAD's data so ${HEADROOM_GB} GB stays free on the drive."
        fi
        say "Creating NOMAD's ${want} GB data file on the drive (first time only, a few minutes) ..."
        fallocate -l "${want}G" "$img.part" 2>/dev/null || truncate -s "${want}G" "$img.part" || die "Could not create the data file on the drive."
        mkfs.ext4 -q -F -L NOMADDATA -m 0 "$img.part" || die "Could not format the data file (mkfs.ext4 missing?)."
        mv "$img.part" "$img"
        [ "$TRUST" = self ] || remember_data "$img"
      fi
      # nosuid,nodev: nothing inside the data file can act as a set-user program or a device on this computer
      mount -o loop,noatime -o nosuid,nodev "$img" "$mnt" || die "Could not open NOMAD's data file ($img)."
    fi
    DATA=$mnt
    say "Data stays on the drive (inside data/nomad-data.img); nothing is written to this computer's disk."
  fi
  STORE_DIR="$DATA/storage"
  # bind folders of the apps set up automatically (Docker creates missing ones; Podman may not)
  mkdir -p "$STORE_DIR/logs" "$STORE_DIR/zim" "$STORE_DIR/ollama" "$STORE_DIR/maps/pmtiles" "$STORE_DIR/qdrant" \
           "$STORE_DIR/flatnotes" "$STORE_DIR/kolibri-gen2" "$DATA/mysql" "$DATA/redis"
  : >> "$STORE_DIR/logs/admin.log"
  if [ ! -s "$DATA/secrets.env" ]; then
    # Random, created once, kept only inside NOMAD's own data area (never printed, never on the kit files).
    local k a b c
    k=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32); a=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32); b=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
    ( umask 077; printf 'APP_KEY=%s\nDB_ROOT_PASSWORD=%s\nDB_PASSWORD=%s\n' "$k" "$a" "$b" > "$DATA/secrets.env" )
    chmod 600 "$DATA/secrets.env"
  fi
  # SELinux (Fedora): the apps NOMAD creates mount these folders without relabel flags,
  # so give the whole storage tree the shared container label once per start.
  if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
    chcon -R -t container_file_t "$STORE_DIR" "$DATA/mysql" "$DATA/redis" 2>/dev/null || warn "Could not set SELinux labels; if apps fail to read files, run: sudo setenforce 0"
  fi
}

import_content() {
  step "Copying the starter content into NOMAD (first time only)"
  local f n=0 need free
  need=$(du -sk "$KIT/content" 2>/dev/null | awk '{print int($1/1048576)+1}')
  free=$(free_gb "$STORE_DIR"); free=${free:-0}
  if [ -n "$need" ] && [ "$free" -lt $(( need + HEADROOM_GB )) ] && [ ! -f "$STORE_DIR/.kit-content-imported" ]; then
    warn "Only ${free} GB free in NOMAD's data area; copying only what fits with ${HEADROOM_GB} GB to spare."
  fi
  [ "$TRUST" = anchored ] && say "Each file from the drive is checked against this computer's list before it is used."
  for f in "$KIT"/content/zim/*.zim; do
    [ -f "$f" ] || continue
    if [ -f "$STORE_DIR/zim/${f##*/}" ] && [ "$(stat -c %s "$f")" = "$(stat -c %s "$STORE_DIR/zim/${f##*/}")" ]; then continue; fi
    free=$(free_gb "$STORE_DIR"); free=${free:-0}
    if [ $(( $(stat -c %s "$f") / 1073741824 + HEADROOM_GB )) -gt "$free" ]; then warn "skipped ${f##*/} (not enough room)"; continue; fi
    checked_copy "$f" "$STORE_DIR/zim/${f##*/}" "content/zim/${f##*/}" && n=$((n+1))
  done
  if [ "$MODE" = full ] && [ -d "$KIT/content/ollama/models" ] && [ "$AI" = yes ]; then
    mkdir -p "$STORE_DIR/ollama/models"
    if [ "$TRUST" = anchored ]; then
      local rel
      while IFS= read -r rel; do
        rel=${rel#./}
        [ -f "$STORE_DIR/ollama/models/$rel" ] && continue
        mkdir -p "$(dirname "$STORE_DIR/ollama/models/$rel")"
        checked_copy "$KIT/content/ollama/models/$rel" "$STORE_DIR/ollama/models/$rel" "content/ollama/models/$rel" || true
      done < <(cd "$KIT/content/ollama/models" && find . -type f)
    else
      cp -rn "$KIT/content/ollama/models/." "$STORE_DIR/ollama/models/" 2>/dev/null || cp -r "$KIT/content/ollama/models/." "$STORE_DIR/ollama/models/"
    fi
  fi
  if [ -f "$KIT/content/maps/base-assets.tar.gz" ] && [ ! -d "$STORE_DIR/maps/basemaps-assets" ]; then
    # unpacked from a checked copy (with another folder's data), never straight from the drive
    if checked_copy "$KIT/content/maps/base-assets.tar.gz" "$STORE_DIR/maps/.base-assets.tar.gz" "content/maps/base-assets.tar.gz"; then
      tar -xzf "$STORE_DIR/maps/.base-assets.tar.gz" --strip-components=1 -C "$STORE_DIR/maps" || warn "map styles could not be unpacked"
      rm -f "$STORE_DIR/maps/.base-assets.tar.gz"
    fi
  fi
  for f in "$KIT"/content/maps/pmtiles/*.pmtiles; do
    [ -f "$f" ] || continue
    [ -f "$STORE_DIR/maps/pmtiles/${f##*/}" ] || checked_copy "$f" "$STORE_DIR/maps/pmtiles/${f##*/}" "content/maps/pmtiles/${f##*/}" || true
  done
  touch "$STORE_DIR/.kit-content-imported"
  say "Library books copied this time: $n (already there are kept)."
}

# ------------------------------------------------------------------ network guard
# --share home: the access code other devices type once (random, 8 digits, kept only in NOMAD's data area, mode 600).
share_code() {
  local f="$DATA/share-code"
  if [ "$NEW_CODE" = yes ] || [ "$(tr -cd '0-9' 2>/dev/null < "$f" | wc -c)" -lt 8 ]; then
    ( umask 077; tr -dc '0-9' < /dev/urandom | head -c 8 > "$f.new" && mv -f "$f.new" "$f" ) || die "Could not make the access code."
    ( umask 077; : > "$DATA/share-devices" )   # a new code forgets every device that used the old one
    [ "$NEW_CODE" = yes ] && say "Made a new access code; devices that used the old one must type the new one."
  fi
  [ -f "$DATA/share-devices" ] || ( umask 077; : > "$DATA/share-devices" )
  chmod 600 "$f" "$DATA/share-devices" 2>/dev/null
  SHARE_CODE=$(tr -cd '0-9' 2>/dev/null < "$f")
}

gate_rules() {   # nft lines: home-network connections to NOMAD's web ports go to the login gate instead
  local item lo hi p
  for item in ${GATE_PORTS//,/ }; do
    lo=${item%-*}; hi=${item#*-}
    for p in $(seq "$lo" "$hi"); do
      printf '    ip saddr @home4 tcp dport %s redirect to :%s\n' "$p" $((p + GATE_OFFSET))
      printf '    ip6 saddr @home6 tcp dport %s redirect to :%s\n' "$p" $((p + GATE_OFFSET))
    done
  done
}
gate_ports() {   # the gate's own ports, nft notation (18080, 18090, ..., 18400-18599)
  local item lo hi out=""
  for item in ${GATE_PORTS//,/ }; do
    lo=${item%-*}; hi=${item#*-}
    if [ "$lo" = "$hi" ]; then out="$out, $((lo + GATE_OFFSET))"; else out="$out, $((lo + GATE_OFFSET))-$((hi + GATE_OFFSET))"; fi
  done
  echo "${out#, }"
}

guard_network() {
  step "Keeping NOMAD private"
  local sets="" nat="" in_home=""
  if [ "$SHARE" = home ]; then
    # Home network: devices with a private address are sent to the login gate; nothing else of NOMAD is
    # reachable for them, and public (internet) addresses reach nothing at all, not even the gate.
    sets="  set gate_ports { type inet_service; flags interval; elements = { $(gate_ports) } }
  set home4 { type ipv4_addr; flags interval; elements = { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } }
  set home6 { type ipv6_addr; flags interval; elements = { fe80::/10, fc00::/7 } }"
    nat="  chain prerouting {
    type nat hook prerouting priority -110; policy accept;
    fib daddr type != local accept
    iifname \"lo\" accept
    iifname \"podman*\" accept
    iifname \"docker*\" accept
    iifname \"br-*\" accept
    iifname \"veth*\" accept
    iifname \"cni*\" accept
$(gate_rules)
  }"
    in_home="ip saddr @home4 tcp dport @gate_ports accept
    ip6 saddr @home6 tcp dport @gate_ports accept
    tcp dport @gate_ports drop"
  fi
  if command -v nft >/dev/null 2>&1; then
    # Own table, removed by stop-nomad.sh. Drops any connection to a NOMAD port that does not come
    # from this computer (with --share home: home-network devices go through the login gate instead).
    # Container-to-container traffic (bridge interfaces) is left alone so NOMAD can talk to its own apps.
    nft -f - <<EOF || warn "Could not set the privacy firewall rule."
table inet nomad_guard
delete table inet nomad_guard
table inet nomad_guard {
  set nomad_ports { type inet_service; flags interval; elements = { $GUARD_PORTS } }
$sets
$nat
  chain input {
    type filter hook input priority -5; policy accept;
    iifname "lo" accept
    iifname "podman*" accept
    iifname "docker*" accept
    iifname "br-*" accept
    iifname "veth*" accept
    iifname "cni*" accept
    $in_home
    ct direction original ct original proto-dst @nomad_ports drop
  }
  chain forward {
    type filter hook forward priority -5; policy accept;
    iifname "lo" accept
    iifname "podman*" accept
    iifname "docker*" accept
    iifname "br-*" accept
    iifname "veth*" accept
    iifname "cni*" accept
    ct direction original ct original proto-dst @nomad_ports drop
  }
}
EOF
  fi
  if command -v nft >/dev/null 2>&1 && nft list table inet nomad_guard >/dev/null 2>&1; then
    GUARD_OK=yes
  else
    say "I could not switch on NOMAD's privacy rule (the 'nft' firewall tool is missing or refused the rule)."
    say "Without it, other devices on the same network could open NOMAD's apps (there is no login)."
    [ "$SHARE" = home ] && share_refused
    if [ "$YES" != yes ]; then
      say "Nothing was started. If this is your own home network and you accept that, run:"
      say "    sudo bash start-nomad.sh --yes${SHARE:+ --share $SHARE}"
      exit 8
    fi
    warn "Continuing because you said --yes. Use NOMAD only on a network you trust."
  fi
  if [ "$SHARE" = home ] && [ "$GUARD_OK" = yes ] && command -v firewall-cmd >/dev/null 2>&1 \
     && firewall-cmd --state >/dev/null 2>&1; then
    # only the login gate's ports; NOMAD's own ports are never opened for other devices
    local p
    for p in $(gate_ports | tr -d ' ' | tr ',' ' '); do firewall-cmd -q --add-port="$p/tcp" >/dev/null 2>&1; done
    say "Opened NOMAD's login gate in this computer's firewall until the next restart (home network only)."
  fi
  if [ "$GUARD_OK" = yes ]; then
    if [ "$SHARE" = home ]; then say "Other devices on your home network can open NOMAD after typing the access code once. The internet cannot."
    else say "Only this computer can open NOMAD. (To share on your home network: --share home)"; fi
  fi
}

share_refused() {   # --share home without the privacy rule: never share (no rule = no login gate)
  say ""
  say "Sharing with your home network needs NOMAD's privacy rule: it is what sends other devices to the"
  say "access-code page. Without it they could open NOMAD with no code, so NOMAD was not shared or started."
  say "Start NOMAD for this computer only (without --share home), or add the free 'nftables' program first"
  say "(Fedora: sudo dnf install nftables   Debian: sudo apt install nftables) and try again."
  say "Before unplugging the drive, run:  sudo bash stop-nomad.sh   (it closes anything that was already prepared)"
  exit 8
}

stop_gate() {    # only the gate process start-nomad.sh recorded, never by name
  local pid
  [ -f "$RUN/gate.pid" ] || return 0
  pid=$(cat "$RUN/gate.pid" 2>/dev/null)
  case "$pid" in
    ''|*[!0-9]*) ;;
    *) # a reused PID that is not our gate is left alone (same rule as stop-nomad.sh)
       if [ -r "/proc/$pid/cmdline" ] && ! tr '\000' ' ' < "/proc/$pid/cmdline" | grep -q 'nomad_mirror[.]py gate'; then :
       else env kill "$pid" 2>/dev/null; fi ;;
  esac
  rm -f "$RUN/gate.pid"
}

start_gate() {
  stop_gate
  [ "$SHARE" = home ] || return 0
  [ "$GUARD_OK" = yes ] || share_refused
  mkdir -p "$RUN"
  detach python3 -I "$TOOLS/nomad_mirror.py" gate --state "$DATA" --ports "$GATE_PORTS" --offset "$GATE_OFFSET" \
    >"$RUN/gate.log" 2>&1 &
  echo $! > "$RUN/gate.pid"
  local i first=$(( ${GATE_PORTS%%,*} + GATE_OFFSET ))
  for i in $(seq 1 15); do curl -s -m 2 -o /dev/null "http://127.0.0.1:$first/" && break; sleep 1; done
  curl -s -m 2 -o /dev/null "http://127.0.0.1:$first/" \
    || die "The login gate for your home network did not start (details: $RUN/gate.log). Other devices cannot open NOMAD. To use it on this computer only: sudo bash stop-nomad.sh, then start NOMAD again without --share home."
  GATE_ON=yes
}

# ------------------------------------------------------------------ start
run_quiet() { "$@" >/dev/null 2>&1; }
lan_ip() {
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -n "$ip" ] || ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}')
  echo "$ip"
}

start_core() {
  step "Starting NOMAD"
  local ip url bind
  load_secrets
  if [ "$SHARE" = home ]; then
    ip=$(lan_ip); url="http://${ip:-localhost}:8080"; bind=""
  else
    url="http://localhost:8080"; bind="127.0.0.1:"
  fi
  run_quiet "${E[@]}" network inspect "$NET" || "${E[@]}" network create "$NET" >/dev/null || die "Could not create NOMAD's private container network."
  local c; for c in nomad_admin nomad_disk_collector nomad_mysql nomad_redis; do run_quiet "${E[@]}" rm -f "$c"; done
  local sel=(--security-opt label=disable)
  "${E[@]}" run -d --name nomad_redis --network "$NET" --network-alias redis \
      -v "$DATA/redis:/data" "$REDIS_IMAGE" >/dev/null || die "Could not start the cache (redis)."
  "${E[@]}" run -d --name nomad_mysql --network "$NET" --network-alias mysql \
      -e MYSQL_ROOT_PASSWORD="$DB_ROOT_PASSWORD" -e MYSQL_DATABASE=nomad -e MYSQL_USER=nomad_user -e MYSQL_PASSWORD="$DB_PASSWORD" \
      -v "$DATA/mysql:/var/lib/mysql" "$MYSQL_IMAGE" >/dev/null || die "Could not start the database (mysql)."
  local i; for i in $(seq 1 90); do
    "${E[@]}" exec nomad_mysql mysqladmin ping -h localhost --silent >/dev/null 2>&1 && break; sleep 2; done
  local gpu=()
  [ "$ENGINE" = docker ] && gpu+=(--add-host host.docker.internal:host-gateway)
  "${E[@]}" run -d --name nomad_admin --network "$NET" "${sel[@]}" "${gpu[@]}" -p "${bind}8080:8080" \
      -v "$STORE_DIR:/app/storage" -v "$SOCK:/var/run/docker.sock" \
      -e NODE_ENV=production -e NOMAD_STORAGE_PATH="$STORE_DIR" -e PORT=8080 -e LOG_LEVEL=info \
      -e APP_KEY="$APP_KEY" -e HOST=0.0.0.0 -e URL="$url" -e DB_HOST=mysql -e DB_PORT=3306 -e DB_DATABASE=nomad \
      -e DB_USER=nomad_user -e DB_PASSWORD="$DB_PASSWORD" -e DB_NAME=nomad -e DB_SSL=false -e REDIS_HOST=redis \
      -e REDIS_PORT=6379 -e DISABLE_COMPRESSION=false "$ADMIN_IMAGE" >/dev/null || die "Could not start the NOMAD Command Center."
  "${E[@]}" run -d --name nomad_disk_collector "${sel[@]}" -v /:/host:ro,rslave -v "$STORE_DIR:/storage" \
      "$COLLECTOR_IMAGE" >/dev/null || warn "The disk-space helper did not start (the storage bar may be empty)."
  say "Waiting for the Command Center to be ready (up to 5 minutes the first time) ..."
  for i in $(seq 1 150); do
    curl -s -m 3 -o /dev/null -f http://127.0.0.1:8080/api/health && break; sleep 2; done
  curl -s -m 3 -o /dev/null -f http://127.0.0.1:8080/api/health || die "The Command Center did not answer. Details: ${E[*]} logs nomad_admin"
  # apps NOMAD created earlier (library, AI, ...) - start them again
  local names; names=$("${E[@]}" ps -a --filter "name=^nomad_" --format '{{.Names}}' 2>/dev/null)
  for c in $names; do case "$c" in nomad_admin|nomad_mysql|nomad_redis|nomad_disk_collector) ;; *) run_quiet "${E[@]}" start "$c" ;; esac; done
  NOMAD_URL=$url
}

install_apps() {
  step "Setting up the starter apps"
  local apps=(nomad_kiwix_server nomad_flatnotes nomad_cyberchef nomad_kolibri_2)
  [ "$AI" = yes ] && apps+=(nomad_qdrant nomad_ollama)
  local a; for a in "${apps[@]}"; do
    curl -s -m 30 -o /dev/null -X POST -H 'Content-Type: application/json' \
      -d "{\"service_name\":\"$a\"}" http://127.0.0.1:8080/api/system/services/install || true
  done
  say "Asked NOMAD to set up: ${apps[*]} (it finishes in the background; see the Command Center)."
}

start_lite() {
  step "Starting the offline library (lite)"
  local bind="127.0.0.1:" ip=""
  [ "$SHARE" = home ] && bind=""
  run_quiet "${E[@]}" rm -f nomad_kiwix_lite
  # Reads the books straight from the drive, read-only. Nothing is written anywhere. With another folder's data only
  # the books on this computer's list with the right SHA-256 are offered (each one is read once to check it).
  local books=("*.zim") f want
  if [ "$TRUST" = anchored ]; then
    books=()
    say "Checking the books on the drive against this computer's list (this can take a few minutes) ..."
    for f in "$KIT"/content/zim/*.zim; do
      [ -f "$f" ] || continue
      want=$(pin_of "content/zim/${f##*/}")
      if [ -n "$want" ] && [ "$(file_sha "$f")" = "$want" ]; then books+=("${f##*/}")
      else warn "skipped ${f##*/}: it is not on this computer's list with the same SHA-256"; fi
    done
    [ ${#books[@]} -gt 0 ] || die "None of the books on the drive is on this computer's list, so the library was not started."
  fi
  "${E[@]}" run -d --name nomad_kiwix_lite --security-opt label=disable -p "${bind}8090:8080" \
     -v "$KIT/content/zim:/data:ro" "$KIWIX_IMAGE" "${books[@]}" >/dev/null || die "Could not start the library."
  NOMAD_URL="http://localhost:8090"
  [ "$SHARE" = home ] && { ip=$(lan_ip); NOMAD_URL="http://${ip:-localhost}:8090"; }
}

main() {
  say "Project NOMAD from the Secure Linux drive (kit $KIT_VERSION, NOMAD $NOMAD_VERSION)"
  hardware_check
  [ "$CHECK_ONLY" = yes ] && exit 0
  need_root ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
  [ -f "$KIT/images/fetch-log.jsonl" ] || die "This folder is not the NOMAD kit (images/fetch-log.jsonl missing): $KIT"
  pick_engine
  # no nft program at all: sharing is refused before anything starts (the full check is in guard_network)
  [ "$SHARE" = home ] && ! command -v nft >/dev/null 2>&1 && share_refused
  if [ "$MODE" = lite ]; then
    if ! ls "$KIT/content/zim/"*.zim >/dev/null 2>&1; then
      say "The library books are not here. They are in the SecureLinux-NOMAD folder on the Secure Linux drive"
      say "(content/zim). Plug in the drive and start NOMAD again. NOMAD was not started."
      exit 9
    fi
    DATA="$RUN/lite"; mkdir -p "$DATA"
    start_engine; load_images
    { [ "$SHARE" = home ] || [ "$NEW_CODE" = yes ]; } && share_code
    guard_network; start_gate; start_lite
  else
    setup_data; start_engine; load_images; check_repotags; import_content
    { [ "$SHARE" = home ] || [ "$NEW_CODE" = yes ]; } && share_code
    guard_network; start_gate; start_core; install_apps
  fi
  echo "$ENGINE $STORE $SHARE $MODE" > "$RUN/state"
  echo "$NOMAD_URL" > "$RUN/url"; chmod 644 "$RUN/url" 2>/dev/null
  echo "$HERE" > "$RUN/script-dir"
  say ""
  say "======================================================================"
  say " NOMAD is running.  Open this address in the web browser:"
  say "     $NOMAD_URL"
  [ "$GATE_ON" = yes ] && say " Other devices at home: open the address above and type this access code once:  ${SHARE_CODE:0:4}-${SHARE_CODE:4}"
  say " To stop it before unplugging the drive:  sudo bash stop-nomad.sh"
  say "======================================================================"
}

[ "${NOMAD_SOURCE_ONLY:-}" = 1 ] || main "$@"
