# shellcheck shell=bash
# Shared helpers for the Home Assistant area: step 76, helpers secure-linux-ha, -ha-setup, -ha-secure, -ha-learn and
# the wizard page 80. Source AFTER lib/common.sh. Owned by: homeassistant (Job L).
#
# Test hooks (tests/homeassistant/run.sh only, never set on a real machine):
#   SL_TEST_SYSROOT   prefix for every absolute system path we write (/etc, /usr, /var)
#   HA_TEST_NOW       fixed "now" (epoch seconds) for the security score
[ -n "${SL_HA_LOADED:-}" ] && return 0
SL_HA_LOADED=1
declare -F sl_choice_get >/dev/null || . "${SL_ROOT:-/usr/local/lib/secure-linux}/lib/common.sh"   # wizard pages may be sourced without it

HA_R=${SL_TEST_SYSROOT:-}
if [ -n "$HA_R" ]; then
  SL_ETC=$HA_R/etc/secure-linux; SL_STATE=$HA_R/var/lib/secure-linux
  SL_LOGDIR=$HA_R/var/log/secure-linux; SL_FAILS=$SL_LOGDIR/failures.log
fi
HA_FILES=$SL_ROOT/files/homeassistant
HA_ENGINE=$HA_FILES/ha_secure.py
HA_URL_DEFAULT=http://homeassistant.local:8123
HA_TOKEN_FILE_DEFAULT=$SL_ETC/ha-token
HA_UCONF=${XDG_CONFIG_HOME:-${HOME:-/root}/.config}/secure-linux
HA_USTATE=${XDG_STATE_HOME:-${HOME:-/root}/.local/state}/secure-linux
HA_ATTEST=$HA_UCONF/ha-attest
HA_LOCAL_DIR=${XDG_DATA_HOME:-${HOME:-/root}/.local/share}/secure-linux/homeassistant
HA_LOCAL_UNIT=secure-linux-homeassistant
HA_CHROMIUM=io.github.ungoogled_software.ungoogled_chromium
HA_LIBREWOLF=io.gitlab.librewolf-community
HA_BUTLER=com.cassidyjames.butler

ha_say() { printf '%s\n' "$*"; }
ha_have() { command -v "$1" >/dev/null 2>&1; }
ha_url() { sl_choice_get ha_url "$HA_URL_DEFAULT"; }

# A web address we are willing to use: http(s)://host[:port][/path], nothing odd (no spaces, quotes, $ or ;)
ha_valid_url() {
  [[ $1 =~ ^https?://[A-Za-z0-9._-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/%-]*)?$ ]] || [[ $1 =~ ^https?://\[[0-9a-fA-F:]+\](:[0-9]{1,5})?(/[A-Za-z0-9._~/%-]*)?$ ]]
}
ha_valid_target() { [[ $1 =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._:-]+$ ]] || [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }

# ha_probe URL   0 = something answered like Home Assistant (200 on the login page, or 401 on the API)
ha_probe() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "${1%/}/api/" 2>/dev/null) || return 1
  [ "$code" = 401 ] || [ "$code" = 200 ]
}

# ha_discover   print the first address where Home Assistant answers by its usual name (avahi/mDNS)
ha_discover() {
  local h ip
  for h in homeassistant.local; do
    ip=""
    if ha_have avahi-resolve-host-name; then ip=$(avahi-resolve-host-name -4 "$h" 2>/dev/null | awk '{print $2}' | head -1); fi
    [ -z "$ip" ] && ip=$(getent hosts "$h" 2>/dev/null | awk '{print $1}' | head -1)
    if [ -n "$ip" ] && ha_probe "http://$ip:8123"; then echo "http://$h:8123"; return 0; fi
  done
  if ha_have avahi-browse; then
    ip=$(avahi-browse -rtp _home-assistant._tcp 2>/dev/null | awk -F';' '$1=="=" && $3=="IPv4" {print $8":"$9; exit}')
    [ -n "$ip" ] && { echo "http://$ip"; return 0; }
  fi
  return 1
}

# ha_browser_cmd URL   print a command line (one word per line) that opens URL as an app-style window, or fail
ha_open_url() {
  local url=$1
  if ha_have flatpak && flatpak info --system "$HA_CHROMIUM" >/dev/null 2>&1; then
    flatpak run "$HA_CHROMIUM" --app="$url" >/dev/null 2>&1 &
  elif ha_have chromium-browser || ha_have chromium; then
    "$(command -v chromium-browser || command -v chromium)" --app="$url" >/dev/null 2>&1 &
  elif ha_have flatpak && flatpak info --system "$HA_LIBREWOLF" >/dev/null 2>&1; then
    flatpak run "$HA_LIBREWOLF" --new-window "$url" >/dev/null 2>&1 &
  elif ha_have librewolf; then
    librewolf --new-window "$url" >/dev/null 2>&1 &
  elif ha_have xdg-open; then
    xdg-open "$url" >/dev/null 2>&1 &
  else
    echo "I couldn't find a web browser to open $url with."; return 1
  fi
  return 0
}

# ---- the config folder we work on by default (a copy/mount of the server's, or the local container's)
ha_config_dir() { sl_choice_get ha_config_dir "$HA_LOCAL_DIR/config"; }

# ---- Git safety net for a config folder ---------------------------------------------------------------------
ha_git() { git -C "$1" -c user.name="Secure Linux" -c user.email="secure-linux@localhost" "${@:2}"; }
ha_gitignore_lines() {
  printf '%s\n' "# Written by Secure Linux: keep secrets and big files out of Git" "secrets.yaml" ".storage/" "*.db" "*.db-shm" "*.db-wal" "*.log" "*.log.*" \
    ".cloud/" "deps/" "tts/" "backups/" "__pycache__/" "ip_bans.yaml" ".uuid"
}
ha_snapshot() {   # ha_snapshot DIR [message]   0 = committed (or nothing to commit)
  local d=$1 msg=${2:-"Snapshot $(date '+%F %H:%M')"}
  ha_have git || { echo "git isn't installed, so I can't make a restore point (sudo dnf install git)."; return 1; }
  [ -f "$d/configuration.yaml" ] || { echo "There is no configuration.yaml in $d."; return 1; }
  [ -d "$d/.git" ] || git -C "$d" init -q || return 1
  if [ ! -f "$d/.gitignore" ]; then ha_gitignore_lines > "$d/.gitignore"; fi
  git -C "$d" add -A >/dev/null 2>&1
  if git -C "$d" diff --cached --quiet 2>/dev/null && git -C "$d" rev-parse HEAD >/dev/null 2>&1; then echo "Nothing has changed since the last restore point."; return 0; fi
  ha_git "$d" commit -q -m "$msg" >/dev/null 2>&1 || return 1
  echo "Restore point saved: $msg"
}

# ---- YAML validator (beginner safety net) --------------------------------------------------------------------
# ha_validate DIR   prints plain English; returns 0 when nothing is wrong, 1 when something would break Home Assistant
ha_validate() {
  local d=${1:-$(ha_config_dir)} rc=0 out lintcfg
  [ -d "$d" ] || { echo "That folder doesn't exist: $d"; return 2; }
  [ -f "$d/configuration.yaml" ] || { echo "There is no configuration.yaml in $d. Is this the right folder?"; return 2; }
  echo "Checking $d ..."
  # 1. strict parse that understands !secret / !include, finds duplicate keys, missing includes
  if ! out=$(python3 "$HA_FILES/ha_validate.py" "$d" 2>&1); then rc=1; fi
  printf '%s\n' "$out"
  # 2. yamllint (style and indentation) with a gentle config
  if ha_have yamllint; then
    lintcfg="$HA_FILES/yamllint.yaml"
    if ! out=$(cd "$d" && yamllint -c "$lintcfg" -f parsable configuration.yaml packages dashboards automations.yaml scripts.yaml scenes.yaml 2>/dev/null); then
      echo "yamllint found things to tidy up (the first few):"; printf '%s\n' "$out" | grep -E ' \[error\]' | head -10 | sed 's/^/  /'
      printf '%s\n' "$out" | grep -qE ' \[error\]' && rc=1
    else echo "yamllint: layout looks fine."; fi
  else echo "(yamllint isn't installed, so the layout check was skipped: sudo dnf install yamllint)"; fi
  # 3. Home Assistant's own checker, when we can reach one (output goes to a private temp file)
  local chk; chk=$(mktemp) || chk=/dev/null
  if ha_have hass; then
    if hass --script check_config -c "$d" >"$chk" 2>&1 && ! grep -qiE 'fail|error' "$chk"; then echo "Home Assistant's own check: passed."
    else echo "Home Assistant's own check found problems:"; head -15 "$chk" | sed 's/^/  /'; rc=1; fi
  elif ha_have podman && podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$HA_LOCAL_UNIT"; then
    if podman exec "$HA_LOCAL_UNIT" python -m homeassistant --script check_config -c /config >"$chk" 2>&1 && ! grep -qi 'failed' "$chk"; then echo "Home Assistant's own check (in the container): passed."
    else echo "Home Assistant's own check found problems:"; head -15 "$chk" | sed 's/^/  /'; rc=1; fi
  else echo "(Home Assistant's own checker isn't available here. After you copy files to the server, use Developer tools > YAML > Check configuration.)"; fi
  [ "$chk" = /dev/null ] || rm -f "$chk"
  [ $rc = 0 ] && echo "RESULT: all good. Safe to restart Home Assistant." || echo "RESULT: please fix the problems above BEFORE restarting Home Assistant."
  return $rc
}

# ---- one place for the starter files -----------------------------------------------------------------------
ha_starter_dir() { echo "$HA_FILES/starter"; }
