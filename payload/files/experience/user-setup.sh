#!/bin/bash
# Per-user settings, run AS THE USER (by 50/70 steps through runuser, and by the welcome wizard).
# Never needs root. Owned by: experience.
#   user-setup.sh browser [librewolf|firefox]    default web browser
#   user-setup.sh librewolf-prefs [yes|no]       seed librewolf.overrides.cfg (yes = keep logins/cookies)
#   user-setup.sh continue                       VSCodium + Continue extension pointed at local Ollama models
#   user-setup.sh syncthing-lan [yes|no]         yes = only sync inside the home network (no relays/discovery)
#   user-setup.sh syncthing-password LOGIN       password read from stdin; protects http://localhost:8384
#   user-setup.sh kdeconnect-name                generic KDE Connect device name ("Laptop"), not the hostname
#   user-setup.sh screenlock                     lock after 5 min idle and on wake from sleep
#   user-setup.sh applist                        ~/.config/secure-linux/apps.txt (list of installed apps)
set -u   # no pipefail: "cmd | grep -q" must not fail when grep stops reading early
SL_ROOT=${SL_ROOT:-/usr/local/lib/secure-linux}
. "$SL_ROOT/lib/common.sh"
. "$SL_ROOT/files/experience/exp-lib.sh"

LW=io.gitlab.librewolf-community
CODIUM=com.vscodium.codium
USTATE=$HOME/.local/state/secure-linux

# Write a file in the user's home from stdin, but never overwrite one the user edited since we wrote it
# (ours is then saved next to it as FILE.secure-linux-new). Same rule as sl_write_file, per user.
user_write() {
  local path=$1 tmp new old last sumf
  tmp=$(mktemp); cat > "$tmp"
  mkdir -p "$USTATE/written" "$(dirname "$path")"
  sumf="$USTATE/written/$(printf '%s' "$path" | md5sum | cut -d' ' -f1)"
  new=$(md5sum < "$tmp" | cut -d' ' -f1)
  if [ -f "$path" ]; then
    old=$(md5sum < "$path" | cut -d' ' -f1)
    [ "$old" = "$new" ] && { rm -f "$tmp"; echo "$new" > "$sumf"; return 0; }
    last=$(cat "$sumf" 2>/dev/null)
    if [ -z "$last" ] || [ "$old" != "$last" ]; then
      echo "Keeping your edited $path (our version: $path.secure-linux-new)"
      mv "$tmp" "$path.secure-linux-new"; return 0
    fi
  fi
  mv "$tmp" "$path"; chmod 0644 "$path"; echo "$new" > "$sumf"
}

do_browser() {
  local b=${1:-$(sl_choice_get default_browser librewolf)} desk
  if [ "$b" = librewolf ]; then
    desk=$LW.desktop
    flatpak info "$LW" >/dev/null 2>&1 || { echo "LibreWolf isn't installed yet; will retry."; return 1; }
  else
    desk=$(ls /usr/share/applications/org.mozilla.firefox.desktop /usr/share/applications/firefox.desktop 2>/dev/null | head -1)
    desk=$(basename "${desk:-firefox.desktop}")
  fi
  # VERIFY on Fedora 44 KDE: xdg-settings (xdg-utils) writes kdeglobals BrowserApplication + mimeapps.list on KDE
  xdg-settings set default-web-browser "$desk" 2>/dev/null || true
  local m
  for m in x-scheme-handler/http x-scheme-handler/https text/html application/xhtml+xml; do
    xdg-mime default "$desk" "$m" 2>/dev/null || true
  done
  if command -v kwriteconfig6 >/dev/null 2>&1; then
    kwriteconfig6 --file kdeglobals --group General --key BrowserApplication "$desk" || true
  fi
  if command -v xfconf-query >/dev/null 2>&1 || [ -d "$HOME/.config/xfce4" ]; then
    # Xfce "Preferred Applications" (exo) uses helpers.rc; the librewolf helper is defined below
    mkdir -p "$HOME/.local/share/xfce4/helpers" "$HOME/.config/xfce4"
    if [ "$b" = librewolf ]; then
      user_write "$HOME/.local/share/xfce4/helpers/librewolf.desktop" <<EOF
[Desktop Entry]
NoDisplay=true
Version=1.0
Encoding=UTF-8
Type=X-XFCE-Helper
X-XFCE-Category=WebBrowser
X-XFCE-CommandsWithParameter=flatpak run $LW "%s"
Icon=$LW
Name=LibreWolf
X-XFCE-Commands=flatpak run $LW
EOF
      touch "$HOME/.config/xfce4/helpers.rc"
      sed -i '/^WebBrowser=/d' "$HOME/.config/xfce4/helpers.rc"; echo "WebBrowser=librewolf" >> "$HOME/.config/xfce4/helpers.rc"
    fi
  fi
  echo "Default browser: $b"
}

do_librewolf_prefs() {
  local keep=${1:-$(sl_choice_get librewolf_keep_cookies no)} k1 note drm d1 dnote
  drm=$(sl_choice_get drm no)
  if [ "$drm" = yes ]; then d1=""; dnote="// (Streaming is ON. Put // in front of the three lines above to switch it off.)"
  else d1="//"; dnote="// (Streaming is off. To switch it on, answer yes in the welcome wizard, or remove the //s above.)"; fi
  if [ "$keep" = yes ]; then k1=""; note="// (Option B is ON. Put // in front of the two lines above to switch it off.)"
  else k1="//"; note="// (Option B is off. Remove the // in front of the two lines above to switch it on.)"; fi
  # VERIFY: flatpak profile root is ~/.var/app/io.gitlab.librewolf-community/.librewolf/ (LibreWolf docs)
  user_write "$HOME/.var/app/$LW/.librewolf/librewolf.overrides.cfg" <<EOF
// ============================================================================================
//  Your LibreWolf settings (The Complete Secure Linux Package)
//  LibreWolf reads this file every time it starts. Lines starting with // are switched off.
//  To change something: remove the // in front of a line (or add it back), save, restart LibreWolf.
//  You can always change your mind in the welcome wizard ("Welcome & setup choices" in the app menu).
// ============================================================================================

// ---- 1. Staying signed in ----------------------------------------------------------------------
// LibreWolf normally forgets cookies and logins every time you close it. That is very private,
// but it means signing in to your email, bank, etc. again each time.
//
// Option A (recommended): keep logins ONLY for sites you choose.
//   In LibreWolf: Settings > Privacy & Security > Cookies and Site Data > Manage Exceptions...
//   type the site (for example https://mail.tuta.com) and click "Allow". Everything else is
//   still wiped when you close LibreWolf. This works with the default settings below.
//
// Option B: keep ALL cookies and logins (what most browsers do). In the welcome wizard you
//   answered "Keep me signed in": ${keep}. These two lines do it:
${k1}defaultPref("privacy.clearOnShutdown.cookies", false);
${k1}defaultPref("privacy.clearOnShutdown_v2.cookiesAndStorage", false);
${note}

// ---- 2. Fingerprinting protection (on by default) ----------------------------------------------
// Websites can recognise you by the exact details of your computer (screen size, fonts, clock).
// LibreWolf hides these by making you look like every other LibreWolf user. Side effects:
//   - Websites see the time as UTC (London winter time), so some clocks on web pages look wrong.
//     Your computer's own clock is not affected.
//   - Light/dark mode of websites may not follow your desktop.
// If a site you need breaks, add an exception in Settings rather than switching this off.
//defaultPref("privacy.resistFingerprinting", false);

// ---- 3. Letterboxing (grey borders around pages) -------------------------------------------------
// Rounds the page size to common sizes so your exact window size can't identify you.
// The grey border looks odd but is harmless. To switch it ON, remove the // below.
//defaultPref("privacy.resistFingerprinting.letterboxing", true);

// ---- 4. Remember browsing history between sessions ----------------------------------------------
// LibreWolf forgets history when closed. To keep it, remove the // below.
//defaultPref("privacy.clearOnShutdown.history", false);
//defaultPref("privacy.clearOnShutdown_v2.historyFormDataAndDownloads", false);

// ---- 5. Protection from dangerous websites and downloads (switched ON for you) -----------------
// LibreWolf switches this off by default. We switch it back on because it stops phishing pages
// (fake bank / fake login pages) and malware downloads. How it stays private: LibreWolf downloads
// a list of scrambled fingerprints of bad sites and checks pages ON YOUR COMPUTER; only when a page
// matches does it ask for more detail, using a short partial fingerprint, never the address.
// Files you download are NOT sent anywhere (the "remote" check stays off).
defaultPref("browser.safebrowsing.malware.enabled", true);
defaultPref("browser.safebrowsing.phishing.enabled", true);
defaultPref("browser.safebrowsing.blockedURIs.enabled", true);
defaultPref("browser.safebrowsing.downloads.enabled", true);
defaultPref("browser.safebrowsing.downloads.remote.enabled", false);
// LibreWolf empties the list addresses; these are Firefox's own (VERIFY they work in LibreWolf builds):
defaultPref("browser.safebrowsing.provider.google4.updateURL", "https://safebrowsing.googleapis.com/v4/threatListUpdates:fetch?\$ct=application/x-protobuf&key=%GOOGLE_SAFEBROWSING_API_KEY%&\$httpMethod=POST");
defaultPref("browser.safebrowsing.provider.google4.gethashURL", "https://safebrowsing.googleapis.com/v4/fullHashes:find?\$ct=application/x-protobuf&key=%GOOGLE_SAFEBROWSING_API_KEY%&\$httpMethod=POST");
defaultPref("browser.safebrowsing.provider.google.updateURL", "https://safebrowsing.google.com/safebrowsing/downloads?client=SAFEBROWSING_ID&appver=%MAJOR_VERSION%&pver=2.2&key=%GOOGLE_SAFEBROWSING_API_KEY%");
defaultPref("browser.safebrowsing.provider.google.gethashURL", "https://safebrowsing.google.com/safebrowsing/gethash?client=SAFEBROWSING_ID&appver=%MAJOR_VERSION%&pver=2.2");
// ---- 5b. Hotel / cafe / airport Wi-Fi login pages ---------------------------------------------
// Those login pages only work over plain http://, which LibreWolf's HTTPS-Only mode blocks. On the
// warning page, click "Continue to HTTP Site": that site is then allowed (the "Hotel / Cafe Wi-Fi
// Login" app opens http://detectportal.firefox.com for exactly this, and that address is already
// allowed for you). To let LibreWolf itself notice
// login pages (it checks detectportal.firefox.com on every new network), remove the // below:
//defaultPref("network.captive-portal-service.enabled", true);

// uBlock Origin (built in) also blocks known malware and phishing addresses: see
// managed-storage/uBlock0@raymondhill.net.json next to this file.

// ---- 6. Video: smooth and battery-friendly on this laptop ---------------------------------------
// The graphics chip decodes video itself (less heat, longer battery). It can't decode AV1, so
// websites are asked for VP9/H.264 instead, which it can.
defaultPref("media.hardware-video-decoding.enabled", true);
defaultPref("media.ffmpeg.vaapi.enabled", true);
defaultPref("media.av1.enabled", false);

// ---- 7. Netflix, Disney+, Spotify and other paid streaming (DRM) ------------------------------
// These sites need a closed-source Google component (Widevine). Your answer: drm=${drm}.
${d1}defaultPref("media.eme.enabled", true);
${d1}defaultPref("media.gmp-widevinecdm.enabled", true);
${d1}defaultPref("media.gmp-widevinecdm.visible", true);
${dnote}
EOF
  do_ublock_lists
  do_https_only_exception
}

# HTTPS-Only exception for the captive-portal check page (hotel Wi-Fi helper opens it).
# Firefox stores these as permission "https-only-load-insecure" (value 1 = allow) in permissions.sqlite.
# VERIFY: type name and that LibreWolf keeps permissions across restarts (it does by default; it only
# clears cookies/history). Done with python's sqlite3 once the profile exists; never creates a profile.
do_https_only_exception() {
  local root="$HOME/.var/app/$LW/.librewolf" prof
  for prof in "$root"/*.default* ; do
    [ -f "$prof/permissions.sqlite" ] || continue
    python3 - "$prof/permissions.sqlite" <<'PY' 2>/dev/null || true
import sqlite3, sys, time
db = sqlite3.connect(sys.argv[1])
origin, typ = "http://detectportal.firefox.com", "https-only-load-insecure"
if not db.execute("select 1 from moz_perms where origin=? and type=?", (origin, typ)).fetchone():
    now = int(time.time() * 1000)
    db.execute("insert into moz_perms (origin,type,permission,expireType,expireTime,modificationTime) values (?,?,1,0,0,?)", (origin, typ, now))
    db.commit()
PY
  done
}

# KDE Connect shows this computer's name to every phone nearby: use a generic one (privacy)
# VERIFY: KDE Connect 24.x keeps the name in ~/.config/kdeconnect/config [General] name
do_kdeconnect_name() {
  command -v kwriteconfig6 >/dev/null 2>&1 || return 0
  local cur; cur=$(kreadconfig6 --file kdeconnect/config --group General --key name 2>/dev/null)
  [ -n "$cur" ] && [ "$cur" != "$(hostname 2>/dev/null)" ] && return 0     # the user picked a name: keep it
  kwriteconfig6 --file kdeconnect/config --group General --key name "Laptop"
}

# uBlock Origin's extra malware/phishing lists, through Firefox "managed storage" (no root needed).
# VERIFY: LibreWolf reads ~/.librewolf/managed-storage/ (flatpak: ~/.var/app/<id>/.librewolf/...) like
# Firefox reads ~/.mozilla/managed-storage/, and the uBO list ids below still exist in uBO's assets.json.
# toOverwrite.filterLists replaces uBO's list selection at start-up: the uBO defaults are repeated here.
do_ublock_lists() {
  user_write "$HOME/.var/app/$LW/.librewolf/managed-storage/uBlock0@raymondhill.net.json" <<'JSON'
{
  "name": "uBlock0@raymondhill.net",
  "description": "Secure Linux: uBlock Origin defaults + malware and phishing blocklists",
  "type": "storage",
  "data": {
    "toOverwrite": {
      "filterLists": [
        "user-filters", "ublock-filters", "ublock-badware", "ublock-privacy", "ublock-quick-fixes",
        "ublock-unbreak", "easylist", "easyprivacy", "plowe-0",
        "urlhaus-1", "curben-phishing"
      ]
    }
  }
}
JSON
}

# Lock the screen after 5 minutes without use, and whenever the laptop wakes from sleep (lid closed).
do_screenlock() {
  if command -v kwriteconfig6 >/dev/null 2>&1; then
    kwriteconfig6 --file kscreenlockerrc --group Daemon --key Autolock true
    kwriteconfig6 --file kscreenlockerrc --group Daemon --key Timeout 5
    kwriteconfig6 --file kscreenlockerrc --group Daemon --key LockOnResume true
  fi
  if command -v xfconf-query >/dev/null 2>&1 && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    # VERIFY property names on Fedora 44 Xfce (xfce4-screensaver 4.18+, xfce4-power-manager)
    local c=xfce4-screensaver
    xfconf-query -c $c -p /saver/enabled -n -t bool -s true
    xfconf-query -c $c -p /saver/idle-activation/enabled -n -t bool -s true
    xfconf-query -c $c -p /saver/idle-activation/delay -n -t int -s 5
    xfconf-query -c $c -p /lock/enabled -n -t bool -s true
    xfconf-query -c $c -p /lock/saver-activation/enabled -n -t bool -s true
    xfconf-query -c $c -p /lock/saver-activation/delay -n -t int -s 0
    xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/lock-screen-suspend-hibernate -n -t bool -s true
  fi
  return 0
}

# VERIFY: Continue config.yaml schema v1 (docs.continue.dev/reference). Roles: chat, edit, apply, autocomplete.
do_continue() {
  flatpak info "$CODIUM" >/dev/null 2>&1 || { echo "VSCodium isn't installed yet; will retry."; return 1; }
  local rc=0
  if ! flatpak run --command=codium "$CODIUM" --list-extensions 2>/dev/null | grep -qi '^continue\.continue$'; then
    # VSCodium's flatpak installs from Open VSX; the flatpak shares the host network, so localhost:11434 works
    flatpak run "$CODIUM" --install-extension Continue.continue || { echo "Continue extension: will retry when online."; rc=1; }
  fi
  local models
  models=$(sl_choice_get ai_models "qwen2.5-coder:7b,qwen2.5-coder:1.5b")
  [ "$models" = none ] && models="qwen2.5-coder:7b,qwen2.5-coder:1.5b"   # config still useful if models come later
  local chat auto
  chat=$(printf '%s' "$models" | tr ',' '\n' | grep -m1 ':7b' || true); chat=${chat:-qwen2.5-coder:7b}
  auto=$(printf '%s' "$models" | tr ',' '\n' | grep -m1 ':1.5b' || true); auto=${auto:-qwen2.5-coder:1.5b}
  {
    cat <<EOF
# Continue (AI coding helper inside VSCodium) - runs 100% on this laptop through Ollama.
# Nothing you type here leaves the computer. Change models with: secure-linux-ai status
name: Local AI (Secure Linux)
version: 1.0.0
schema: v1
models:
  - name: Qwen2.5-Coder 7B (local)
    provider: ollama
    model: $chat
    apiBase: http://localhost:11434
    roles:
      - chat
      - edit
      - apply
EOF
    if [ "$(sl_choice_get ai_abliterated no)" = yes ]; then
      cat <<'EOF'
  # Unfiltered ("abliterated") variant: answers without refusing. It can be confidently wrong or
  # produce harmful content; you are responsible for how you use what it writes.
  - name: Qwen2.5-Coder 7B UNFILTERED (local)
    provider: ollama
    model: qwen2.5-coder-unfiltered:7b
    apiBase: http://localhost:11434
    roles:
      - chat
      - edit
EOF
    fi
    cat <<EOF
  - name: Qwen2.5-Coder 1.5B autocomplete (local)
    provider: ollama
    model: $auto
    apiBase: http://localhost:11434
    roles:
      - autocomplete
EOF
  } | user_write "$HOME/.continue/config.yaml"
  # The flatpak sees ~/.continue only if allowed; VERIFY codium flatpak has --filesystem=home (it does by default)
  return $rc
}

st_conf() { ls "$HOME/.local/state/syncthing/config.xml" "$HOME/.config/syncthing/config.xml" 2>/dev/null | head -1; }
st_api() {        # st_api METHOD PATH [json-on-stdin]
  local c key addr tls proto
  c=$(st_conf); [ -n "$c" ] || { echo "Syncthing hasn't started yet."; return 1; }
  key=$(sed -n 's:.*<apikey>\(.*\)</apikey>.*:\1:p' "$c" | head -1)
  addr=$(sed -n '/<gui /,/<\/gui>/s:.*<address>\(.*\)</address>.*:\1:p' "$c" | head -1); addr=${addr:-127.0.0.1:8384}
  tls=$(grep -o '<gui [^>]*tls="true"' "$c" || true); proto=http; [ -n "$tls" ] && proto=https
  if [ "$1" = GET ]; then curl -fsS -k --max-time 10 -H "X-API-Key: $key" "$proto://$addr$2"
  else curl -fsS -k --max-time 10 -X "$1" -H "X-API-Key: $key" -H 'Content-Type: application/json' --data-binary @- "$proto://$addr$2"; fi
}
st_wait() { local i; for i in $(seq 1 "${1:-30}"); do st_api GET /rest/system/ping >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }

# VERIFY: REST PATCH /rest/config/options and /rest/config/gui (Syncthing >= 1.12, still in 2.x)
do_syncthing_lan() {
  local lan=${1:-$(sl_choice_get syncthing_lan_only yes)} on=false
  [ "$lan" = yes ] || on=true
  st_wait 30 || { echo "Syncthing isn't running yet; will retry."; return 1; }
  printf '{"globalAnnounceEnabled":%s,"relaysEnabled":%s,"natEnabled":%s}' "$on" "$on" "$on" \
    | st_api PATCH /rest/config/options >/dev/null && echo "Syncthing: home-network only = $lan"
}
do_syncthing_password() {
  local login=${1:-$USER} pw
  IFS= read -r pw || true
  [ -n "$pw" ] || { echo "No password given."; return 1; }
  st_wait 30 || { echo "Syncthing isn't running yet."; return 1; }
  # Syncthing stores a bcrypt hash of the password we send. JSON built by python so quotes are safe.
  printf '%s\n%s\n' "$login" "$pw" \
    | python3 -c 'import json,sys; u,p=sys.stdin.read().split("\n")[:2]; print(json.dumps({"user":u,"password":p}))' \
    | st_api PATCH /rest/config/gui >/dev/null && echo "Syncthing settings page now asks for a password."
}

do_applist() {
  mkdir -p "$HOME/.config/secure-linux"
  {
    echo "# Apps installed on $(hostname 2>/dev/null) - $(date '+%Y-%m-%d'). Backups include this list so"
    echo "# 'sudo /usr/local/lib/secure-linux/setup.sh --repair' can reinstall them on a new machine."
    flatpak list --app --columns=application 2>/dev/null
  } > "$HOME/.config/secure-linux/apps.txt.new" && mv "$HOME/.config/secure-linux/apps.txt.new" "$HOME/.config/secure-linux/apps.txt"
}

cmd=${1:-}; shift || true
case "$cmd" in
  browser) do_browser "$@" ;;
  librewolf-prefs) do_librewolf_prefs "$@" ;;
  continue) do_continue ;;
  syncthing-lan) do_syncthing_lan "$@" ;;
  syncthing-password) do_syncthing_password "$@" ;;
  screenlock) do_screenlock ;;
  kdeconnect-name) do_kdeconnect_name ;;
  applist) do_applist ;;
  *) sed -n '2,12p' "$0"; [ "$cmd" = --help ] || [ "$cmd" = -h ] ;;
esac
