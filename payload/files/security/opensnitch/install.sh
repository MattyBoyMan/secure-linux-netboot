#!/bin/bash
# Install and set up OpenSnitch ("network protection": asks once about each NEW app, blocks known dangerous
# addresses) on the full profile, or just its quiet background part (no questions) on lite computers with
# 3 GB of memory or more. Run as root:
#   bash /usr/local/lib/secure-linux/files/security/opensnitch/install.sh
# Called by steps/25-security.sh (install and repair). Safe to run again: nothing already installed is downloaded
# again, and rules/lists/settings are only rewritten when they differ.
#
# Where the program comes from:
#   x86_64   the project's GitHub release (each file is checked against the SHA-256 GitHub publishes for it);
#            if that fails, Fedora's own "opensnitch" package.
#   other    (for example aarch64) Fedora's own "opensnitch" package if there is one; otherwise this is skipped
#            with a clear message. Never a failure of the whole setup step.
#   atomic   not offered.
# Environment for the test suite: SL_SEC_PREFIX (fake root), SL_OPENSNITCH_API, SL_SEC_MEMINFO, SL_SEC_ARCH.
set -u   # no pipefail: "cmd | grep -q" must not fail when grep stops reading early
SL_ROOT=${SL_ROOT:-/usr/local/lib/secure-linux}
. "$SL_ROOT/lib/common.sh"
. "$SL_ROOT/files/security/lib-security.sh"
HERE=$SL_ROOT/files/security/opensnitch
API=${SL_OPENSNITCH_API:-https://api.github.com/repos/evilsocket/opensnitch/releases/latest}
ETC=$SEC_PREFIX/etc/opensnitchd
RULES=$ETC/rules
LISTS=$ETC/secure-linux-lists
PROFILE=${SL_PROFILE:-$(sl_profile)}
PY=${SL_SEC_PYTHON:-python3}

case "${1:-}" in -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
[ "$(id -u)" -eq 0 ] || exec pkexec /bin/bash "$(readlink -f "$0")" "$@"
if sl_is_atomic; then echo "Network protection (OpenSnitch) isn't available on the atomic setup (skipped)."; exit 0; fi

skip() {   # skip "reason"  : a clear message, a one-off notice for the user, and NOT a failure
  echo "Network protection (OpenSnitch): skipped. $1"
  sl_event opensnitch-skipped "Network protection isn't switched on" "$1 Everything else (firewall, encrypted DNS, updates) protects this computer as normal."
  exit 0
}

# ---------------------------------------------------------------- lite: only with enough memory, and quietly
if [ "$PROFILE" = lite ]; then
  mem_kb=$(awk '/^MemTotal:/ {print $2}' "${SL_SEC_MEMINFO:-/proc/meminfo}" 2>/dev/null)
  # "3 GB" computers report about 2.9 million kB, so 2.7 million is the line
  if [ "${mem_kb:-0}" -lt 2700000 ]; then
    skip "This computer has less than 3 GB of memory, which the app firewall would use too much of."
  fi
fi
WANT_UI=0; [ "$PROFILE" = full ] && WANT_UI=1

# ---------------------------------------------------------------- the program
have_daemon() { rpm -q opensnitch >/dev/null 2>&1; }
have_ui()     { rpm -q opensnitch-ui >/dev/null 2>&1; }
need_pkgs()   { have_daemon && { [ "$WANT_UI" = 0 ] || have_ui; }; }

install_from_fedora() {   # install_from_fedora : 0 if the Fedora package(s) are installed afterwards
  local pk=(opensnitch); [ "$WANT_UI" = 1 ] && pk+=(opensnitch-ui)
  dnf -q list --available opensnitch >/dev/null 2>&1 || have_daemon || return 1
  try dnf -y install "${pk[@]}"
  need_pkgs
}
install_from_github() {   # 0 on success. Each file is checked against the digest GitHub publishes for it.
  local dir name url digest want got rpms=()
  dir=$(mktemp -d)
  curl -fsSL --max-time 60 -o "$dir/release.json" "$API" 2>/dev/null && [ -s "$dir/release.json" ] || { rm -rf "$dir"; return 1; }
  "$PY" - "$dir/release.json" "$WANT_UI" > "$dir/assets" <<'PY'
import json, re, sys
rel = json.load(open(sys.argv[1]))
want_ui = sys.argv[2] == "1"
for a in rel.get("assets", []):
    n = a.get("name", "")
    if re.fullmatch(r"opensnitch-[0-9][^/]*\.x86_64\.rpm", n) or (want_ui and re.fullmatch(r"opensnitch-ui-[0-9][^/]*\.noarch\.rpm", n)):
        print("%s|%s|%s" % (n, a.get("browser_download_url", ""), a.get("digest") or ""))
PY
  sed -i 's/\r$//' "$dir/assets"   # (Windows test machines print CR+LF)
  [ "$(wc -l < "$dir/assets")" -ge $((1 + WANT_UI)) ] || { rm -rf "$dir"; return 1; }
  while IFS='|' read -r name url digest; do
    case "$url" in https://github.com/*) ;; *) echo "Unexpected download address for $name; not used."; rm -rf "$dir"; return 1 ;; esac
    curl -fsSL --max-time 300 -o "$dir/$name" "$url" 2>/dev/null || { rm -rf "$dir"; return 1; }
    if [ -n "$digest" ]; then
      want=${digest#sha256:}; got=$(sha256sum "$dir/$name" | cut -d' ' -f1)
      [ "$want" = "$got" ] || { echo "$name: checksum does not match (download damaged or tampered with); not used."; rm -rf "$dir"; return 1; }
      echo "$name: checksum OK"
    else
      echo "Note: GitHub gave no checksum for $name (installing anyway, over HTTPS)."
    fi
    rpms+=("$dir/$name")
  done < "$dir/assets"
  try dnf -y install "${rpms[@]}"; local rc=$?
  rm -rf "$dir"
  return $rc
}

if ! need_pkgs; then
  arch=${SL_SEC_ARCH:-$(uname -m)}
  if [ "$arch" = x86_64 ]; then
    install_from_github || { echo "The project's own download didn't work; trying Fedora's package instead."; install_from_fedora; } \
      || { echo "FAILED: couldn't install OpenSnitch (no internet, or the download was damaged)" | tee -a "$SL_FAILS"; exit 1; }
  else
    install_from_fedora || skip "The app firewall isn't available for this type of computer ($arch) yet."
  fi
fi
need_pkgs || { echo "FAILED: OpenSnitch is not installed after the install attempt" | tee -a "$SL_FAILS"; exit 1; }

UNIT=opensnitch.service
for u in opensnitch.service opensnitchd.service; do systemctl cat "$u" >/dev/null 2>&1 && { UNIT=$u; break; }; done

# ---------------------------------------------------------------- the old quiet-first-week design (removed)
if [ -e "$SEC_PREFIX/etc/systemd/system/secure-linux-opensnitch-learning.timer" ] || [ -e "$SEC_PREFIX$SL_STATE/opensnitch-learning-until" ]; then
  systemctl disable --now secure-linux-opensnitch-learning.timer >/dev/null 2>&1
  rm -f "$SEC_PREFIX"/etc/systemd/system/secure-linux-opensnitch-learning.* "$SEC_PREFIX$SL_STATE/opensnitch-learning-until"
  systemctl daemon-reload >/dev/null 2>&1
fi
# rules of an earlier version of this kit under their old names
for n in chronyd cloudflared dnf flatpak freshclam fwupd networkmanager nordvpn ollama packagekitd rustdesk syncthing systemd-resolved warp-svc; do
  rm -f "$RULES/000-secure-linux-$n.json"
done

# ---------------------------------------------------------------- daemon settings
mkdir -p "$RULES" "$LISTS"/{threats,trackers,telemetry,lan}
monitor=proc; [ -e "$SEC_PREFIX/usr/lib/opensnitchd/ebpf/opensnitch.o" ] && monitor=ebpf
if [ -f "$ETC/default-config.json" ]; then
  try "$PY" "$HERE/configure.py" "$ETC/default-config.json" "$monitor"
else
  echo "Note: $ETC/default-config.json not found; OpenSnitch's own defaults are used."
fi
# The daemon restarts by itself if it ever stops (and the health check below raises an alert if it can't)
sl_write_file "$SEC_PREFIX/etc/systemd/system/$UNIT.d/10-secure-linux.conf" 0644 <<'EOF'
[Service]
Restart=always
RestartSec=5
EOF

# ---------------------------------------------------------------- lists (block lists and the local network)
for l in threats trackers; do   # an empty list, so the rule has something to read until the first download
  [ -e "$LISTS/$l/$l.txt" ] || printf '# Secure Linux block list %s: empty until the first update (secure-linux-netguard update-lists)\n' "$l" > "$LISTS/$l/$l.txt"
done
sl_install_file "$HERE/lists/telemetry/telemetry.txt" "$LISTS/telemetry/telemetry.txt" 0644
{
  cat "$HERE/lists/lan/private-networks.txt"
  sub=$(sl_build_get HOME_SUBNET)
  case "$sub" in *[!0-9./]*|"") ;; *) grep -qx "$sub" "$HERE/lists/lan/private-networks.txt" || echo "$sub" ;; esac
} | sl_write_file "$LISTS/lan/private-networks.txt" 0644

# ---------------------------------------------------------------- rules
# The 000-allow rules in rules/ cover the built-in programs so no question is ever asked for them
# (updates, DNS, VPN, Syncthing file sync, the RustDesk screen-help client used by the home fleet...).
for r in "$HERE"/rules/*.json; do
  b=$(basename "$r")
  # lite has no questions (everything not blocked is allowed), so only the block-list rules are needed there
  if [ "$PROFILE" = lite ]; then case "$b" in 100-*) ;; *) rm -f "$RULES/$b"; continue ;; esac; fi
  sl_install_file "$r" "$RULES/$b" 0644
done
if [ "$PROFILE" = full ]; then
  url=$(sl_choice_get immich_url); [ -n "$url" ] || url=$(sl_build_get IMMICH_URL)
  try "$PY" "$HERE/genrules.py" immich "$url" "$RULES"
  # Everything installed right now is pre-approved (once, at install; later installs are asked about once)
  if [ "$SL_MODE" = install ] || ! ls "$RULES"/050-secure-linux-installed-*.json >/dev/null 2>&1; then
    fl=$(mktemp); flatpak list --app --columns=application > "$fl" 2>/dev/null
    try "$PY" "$HERE/genrules.py" apps "$RULES" --flatpaks "$fl" --desktop "$SEC_PREFIX/usr/share/applications" \
      --path "$SEC_PREFIX/usr/bin" --path "$SEC_PREFIX/usr/local/bin" --path "$SEC_PREFIX/usr/sbin"
    rm -f "$fl"
  fi
fi

# ---------------------------------------------------------------- services and timers
systemctl daemon-reload
sl_enable "$UNIT"
sl_enable secure-linux-netguard-lists.timer secure-linux-netguard-check.timer secure-linux-netguard-summary.timer
if [ "$PROFILE" = full ]; then
  sl_enable secure-linux-netguard-watch.service
  try "$SEC_BIN/secure-linux-netguard" ui-settings
else
  systemctl disable --now secure-linux-netguard-watch.service >/dev/null 2>&1   # lite: no pop-ups of any kind
fi
# First download of the block lists (if offline, the weekly timer retries; until then nothing is blocked)
if [ ! -f "$SEC_PREFIX$SL_STATE/netguard/lists.updated" ]; then
  timeout 900 "$SEC_BIN/secure-linux-netguard" update-lists || echo "The block lists will download later (they update every week). Until then nothing is blocked by them and the internet works as normal."
fi
exit 0
