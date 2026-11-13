# Fedora Kickstart: "The Complete Secure Linux Package" - NETBOOT build, rendered by netboot/render-netboot.sh
# on 2026-11-14 (netboot render) (Fedora 44) from templates/fedora.ks. This is a PUBLIC file: no names, no password
# hashes, no Wi-Fi passwords. The setup screen asks for the login name and password instead (see the marked
# netboot step in %pre). The Secure Linux payload and the guide are downloaded from the public repository
# at install time (SL_PAYLOAD_SOURCE below), not embedded and not read from a USB stick.
#
# %pre (below) runs a text-mode setup screen BEFORE anything is touched. It:
#   0. finds the internal drive (prefers SSDs; if there is more than one you type its number)
#   1. shows what computer this is and recommends the full, light or lightest setup (you choose)
#   2. (full only) asks whether to add the optional unfiltered offline AI coding model
#   3. checks whether the USB builder recorded a backup of this computer
#   4. offers the Wi-Fi networks saved from this computer's Windows (save-wifi.ps1), if any
#   5. shows exactly which drive will be erased and makes you type ERASE
#   6. sets the disk-encryption passphrase (typed twice, or generated and typed back once),
#      kept in memory only, never written to the USB
# If anything is cancelled or can't be read, the computer restarts and nothing is changed.
#
# Everything that runs on the installed machine lives in /usr/local/lib/secure-linux (packed from the
# kit's linux\ folder by make-usb.ps1). The installer runs "setup.sh --early" so helpers, the welcome
# screen and timers exist at the first login; firstboot-setup.service runs the full setup once online.

lang en_AU.UTF-8
keyboard us
# --ntpservers: a computer shelved for years can have a flat clock battery, and a years-wrong clock breaks HTTPS downloads
timezone Australia/Melbourne --utc --ntpservers=pool.ntp.org

# Where the system comes from: Fedora's package mirrors (full, lite) or the Fedora Kinoite image (atomic).
# profile.ks also holds 'graphical' or 'text' (text on 2-4 GB machines, from the hardware check).
%include /tmp/payload.ks
%include /tmp/profile.ks
%include /tmp/net.ks
%include /tmp/disk.ks

rootpw --lock
%include /tmp/user.ks   # netboot: the setup screen asks for the login name and password and writes this file
firstboot --disable
selinux --enforcing
# Turn off (not restart) when done, so the USB stick can be removed before first start
poweroff

%pre --log=/tmp/ks-pre.log
# Never print the encryption passphrase: this script's output on the log is kept by the installer.
exec < /dev/tty6 > /dev/tty6 2> /dev/tty6
chvt 6
# Big, readable letters on large screens (e.g. the 2.5K Zenbook); keeps the small font if not available
SCREEN_W=$(cut -d, -f1 /sys/class/graphics/fb0/virtual_size 2>/dev/null)
[ -n "$SCREEN_W" ] || SCREEN_W=$(head -n1 /sys/class/drm/card*-eDP-*/modes 2>/dev/null | head -n1 | cut -dx -f1)
if [ "${SCREEN_W:-0}" -ge 1900 ] 2>/dev/null; then
  for f in latarcyrheb-sun32 ter-v32b ter-v32n; do setfont -C /dev/tty6 "$f" 2>/dev/null && break; done
fi
printf '\033c'

cancel() {
  echo
  echo "  Cancelled. Nothing was changed."
  echo "  Remove the USB stick. This computer restarts in 15 seconds."
  sleep 15
  reboot -f
  exit 1
}
line() { echo "  ------------------------------------------------------------------------"; }
# Every choice needs an answer: Enter on its own just asks again
answer() { local a; while true; do printf '  %s ' "$1"; read -r a || cancel; [ -n "$a" ] && { REPLY_TEXT=$a; return; }; done; }
header() { printf '\033c'; line; echo "   THE COMPLETE SECURE LINUX PACKAGE  -  $1"; line; echo; }
junk_id() {   # firmware placeholders that are not real serial numbers / UUIDs
  local s; s=$(printf '%s' "$1" | tr -cd 'A-Za-z0-9' | tr 'A-Z' 'a-z')
  case "$s" in ""|defaultstring|tobefilledbyoem|systemserialnumber|none|notapplicable|na|0123456789|123456789|chassisserialnumber|notspecified) return 0 ;; esac
  [ -z "$(printf '%s' "$s" | tr -d "${s:0:1}")" ] && return 0   # all the same character (0000..., ffff...)
  return 1
}

# ---------------------------------------------------------------- this computer
VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)
MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
SERIAL=$(tr -d ' ' < /sys/class/dmi/id/product_serial 2>/dev/null)
UUID=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null)
CPU=$(awk -F: '/model name/{sub(/^ +/, "", $2); print $2; exit}' /proc/cpuinfo)
RAM_GB=$(( ($(awk '/MemTotal/{print $2}' /proc/meminfo) + 524288) / 1048576 ))
RAM_MB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))   # for the MIN/LITE boundary (2-3 GB), where rounded GB is too coarse
command -v iw >/dev/null 2>&1 && iw reg set 'AU' >/dev/null 2>&1
SID=$SERIAL; junk_id "$SID" && SID=""
UID_=$UUID; junk_id "$UID_" && UID_=""

# Saved Wi-Fi networks from Windows (save-wifi.ps1): the copy made when the stick was built, plus the
# stick's current file (SAVE-THIS-PC.cmd may have added this computer since). Newest record wins.
umask 077
cat > /tmp/sl-wifi.py <<'SLWIFI_PY_END'
#!/usr/bin/python3
# Secure Linux installer helper: Wi-Fi networks carried over from Windows (saved by save-wifi.ps1).
# Embedded in the Kickstart by make-usb.ps1 and run with the installer's own python3 (Anaconda is
# written in Python, so python3 is always there; the openssl command line tool may not be).
# Python standard library only.
#
#   sl-wifi.py pick RECORDS SERIAL UUID OUT    newest record for this machine -> OUT; prints plain|enc1
#   sl-wifi.py open OUT BUNDLE                 decode (PIN in $SL_WIFI_PIN for enc1) -> BUNDLE; prints count
#   sl-wifi.py list BUNDLE                     prints "N|name|security" per network
#   sl-wifi.py keyfiles SELECTED DIR [SKIP_SSID_B64]   writes NetworkManager keyfiles (0600)
#   sl-wifi.py encrypt PIN < plain > blob      (tests) same format as save-wifi.ps1
#
# Record line (one per machine, newest last):  serial|uuid|date|computer|plain|base64(bundle)
#                                         or:  serial|uuid|date|computer|enc1|base64(blob)
# Bundle: one network per line:  base64(ssid bytes)|wpa-psk, sae or none|base64(password)|hidden 0/1
# enc1 blob: "SLW1" salt(16) nonce(16) ciphertext tag(32). Keys: PBKDF2-HMAC-SHA256(PIN, salt, 200000) -> 64
# bytes = enc key + mac key. Cipher: HMAC-SHA256(enc key, nonce || counter) keystream XOR (CTR mode with a
# PRF). Tag: HMAC-SHA256(mac key, "SLW1" salt nonce ciphertext), checked before decrypting.
import base64
import hashlib
import hmac
import os
import re
import sys
import uuid

MAGIC = b"SLW1"
ITERATIONS = 200000


def _keys(pin, salt):
    k = hashlib.pbkdf2_hmac("sha256", pin.encode("utf-8"), salt, ITERATIONS, 64)
    return k[:32], k[32:]


def _stream(key, nonce, n):
    out = bytearray()
    i = 0
    while len(out) < n:
        out += hmac.new(key, nonce + i.to_bytes(8, "big"), hashlib.sha256).digest()
        i += 1
    return bytes(out[:n])


def encrypt(pin, plain, salt=None, nonce=None):
    salt = salt or os.urandom(16)
    nonce = nonce or os.urandom(16)
    kenc, kmac = _keys(pin, salt)
    ct = bytes(a ^ b for a, b in zip(plain, _stream(kenc, nonce, len(plain))))
    tag = hmac.new(kmac, MAGIC + salt + nonce + ct, hashlib.sha256).digest()
    return MAGIC + salt + nonce + ct + tag


def decrypt(pin, blob):
    if len(blob) < 4 + 16 + 16 + 32 or blob[:4] != MAGIC:
        raise ValueError("not a Secure Linux Wi-Fi bundle")
    salt, nonce, ct, tag = blob[4:20], blob[20:36], blob[36:-32], blob[-32:]
    kenc, kmac = _keys(pin, salt)
    if not hmac.compare_digest(tag, hmac.new(kmac, MAGIC + salt + nonce + ct, hashlib.sha256).digest()):
        raise PermissionError("wrong PIN")
    return bytes(a ^ b for a, b in zip(ct, _stream(kenc, nonce, len(ct))))


# ---------------------------------------------------------------- NetworkManager keyfile values
def kf_string(s):
    """A string value in a GLib key file: backslash doubled, control characters escaped, and
    leading/trailing spaces written as \\s (GLib would strip them otherwise)."""
    e = s.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r")
    m = re.match(r"^( *)(.*?)( *)$", e, re.S)
    return "\\s" * len(m.group(1)) + m.group(2) + "\\s" * len(m.group(3))


def kf_ssid(b):
    """The SSID as plain text when that is unambiguous, otherwise NetworkManager's byte list (84;101;...;)."""
    if all(0x20 <= c <= 0x7E for c in b) and b:
        s = b.decode("ascii")
        if ";" not in s and "\\" not in s and not s.startswith(" ") and not s.endswith(" ") and not re.fullmatch(r"[0-9;]+", s):
            return s
    return ";".join(str(c) for c in b) + ";"


def display_name(b):
    try:
        s = b.decode("utf-8")
        if all(ch.isprintable() for ch in s):
            return s
    except UnicodeDecodeError:
        pass
    # Non-printable names become "hex:...". Such a name never matches a scanned network's name in
    # the installer (nmcli shows the real bytes), so a saved network with a hex: name is never
    # offered as "saved - password known"; the network can still be picked from the scan list (B9).
    return "hex:" + b.hex()


def valid_psk(p, km):
    if km == "none":
        return True
    if re.fullmatch(r"[0-9A-Fa-f]{64}", p) and km == "wpa-psk":
        return True
    return 8 <= len(p) <= 63 and all(0x20 <= ord(c) <= 0x7E for c in p)


def parse_bundle(text):
    nets = []
    for line in text.splitlines():
        parts = line.strip().split("|")
        if len(parts) < 3 or parts[1] not in ("wpa-psk", "sae", "none"):
            continue
        ssid = base64.b64decode(parts[0])
        psk = base64.b64decode(parts[2]).decode("utf-8") if parts[2] else ""
        hidden = len(parts) > 3 and parts[3] == "1"
        if ssid:
            nets.append((ssid, parts[1], psk, hidden))
    return nets


def keyfile(ssid, km, psk, hidden):
    name = display_name(ssid)
    lines = ["[connection]", "id=" + kf_string(name), "uuid=" + str(uuid.uuid4()), "type=wifi",
             "autoconnect=true", "permissions=", "",
             "[wifi]", "mode=infrastructure", "ssid=" + kf_ssid(ssid)]
    if hidden:
        lines.append("hidden=true")
    lines.append("")
    if km != "none":
        lines += ["[wifi-security]", "key-mgmt=" + km, "psk=" + kf_string(psk), ""]
    lines += ["[ipv4]", "method=auto", "", "[ipv6]", "addr-gen-mode=default", "method=auto", ""]
    return "\n".join(lines)


def write_private(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
        f.write(data)
    if hasattr(os, "chown"):
        os.chmod(path, 0o600)
        try:
            os.chown(path, 0, 0)
        except PermissionError:
            pass


# ---------------------------------------------------------------- commands
def cmd_pick(records, serial, uid, out):
    serial, uid = serial.strip().lower(), uid.strip().lower()
    found = None
    try:
        lines = open(records, encoding="utf-8", errors="replace").read().splitlines()
    except FileNotFoundError:
        lines = []
    for line in lines:
        p = line.strip().split("|")
        if len(p) != 6 or p[4] not in ("plain", "enc1"):
            continue
        if (serial and p[0].strip().lower() == serial) or (uid and p[1].strip().lower() == uid):
            found = p
    if not found:
        return 1
    write_private(out, found[4] + "|" + found[5] + "\n")
    print(found[4])
    return 0


def cmd_open(rec, bundle):
    kind, payload = open(rec, encoding="utf-8").read().strip().split("|", 1)
    raw = base64.b64decode(payload)
    if kind == "enc1":
        try:
            raw = decrypt(os.environ.get("SL_WIFI_PIN", ""), raw)
        except PermissionError:
            return 2
    text = raw.decode("utf-8")
    write_private(bundle, text)
    print(len(parse_bundle(text)))
    return 0


def cmd_list(bundle):
    labels = {"wpa-psk": "WPA2", "sae": "WPA3", "none": "open (no password)"}
    for i, (ssid, km, _psk, _h) in enumerate(parse_bundle(open(bundle, encoding="utf-8").read()), 1):
        print("%d|%s|%s" % (i, display_name(ssid).replace("|", "/"), labels[km]))
    return 0


def cmd_keyfiles(selected, outdir, skip_b64=""):
    skip = base64.b64decode(skip_b64) if skip_b64 else b""
    os.makedirs(outdir, mode=0o700, exist_ok=True)
    n = 0
    for ssid, km, psk, hidden in parse_bundle(open(selected, encoding="utf-8").read()):
        if ssid == skip:
            print("skip %s (already set up as the home Wi-Fi)" % display_name(ssid))
            continue
        if not valid_psk(psk, km):
            print("skip %s (password not usable on Linux)" % display_name(ssid))
            continue
        n += 1
        safe = re.sub(r"[^A-Za-z0-9_-]", "_", display_name(ssid))[:40]
        write_private(os.path.join(outdir, "windows-%02d-%s.nmconnection" % (n, safe)), keyfile(ssid, km, psk, hidden))
        print("added %s" % display_name(ssid))
    return 0


def main(argv):
    try:  # network names can be in any language; never fail because the console can't show a character
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "pick" and len(argv) == 6:
        return cmd_pick(*argv[2:6])
    if cmd == "open" and len(argv) == 4:
        return cmd_open(argv[2], argv[3])
    if cmd == "list" and len(argv) == 3:
        return cmd_list(argv[2])
    if cmd == "keyfiles" and len(argv) in (4, 5):
        return cmd_keyfiles(*argv[2:])
    if cmd == "encrypt" and len(argv) == 3:
        sys.stdout.write(base64.b64encode(encrypt(argv[2], sys.stdin.buffer.read())).decode() + "\n")
        return 0
    sys.stderr.write("usage: see the top of this file\n")
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
SLWIFI_PY_END
cat > /tmp/wifi-records.txt <<'WIFI_RECORDS_END'

WIFI_RECORDS_END
mount_stick() {  # the Ventoy data partition, read-only (Ventoy 1.1.18+ exposes it as /dev/mapper/VentoyPart)
  mkdir -p /tmp/ventoy-ro
  mountpoint -q /tmp/ventoy-ro && return 0
  udevadm settle 2>/dev/null
  for dev in /dev/mapper/VentoyPart "$(blkid -L Ventoy 2>/dev/null)" /dev/disk/by-label/Ventoy; do
    [ -n "$dev" ] && [ -b "$dev" ] || continue
    mount -o ro "$dev" /tmp/ventoy-ro 2>/dev/null || mount -t exfat -o ro "$dev" /tmp/ventoy-ro 2>/dev/null || continue
    return 0
  done
  return 1
}
if mount_stick; then
  [ -f /tmp/ventoy-ro/linux-setup/wifi-networks.txt ] && cat /tmp/ventoy-ro/linux-setup/wifi-networks.txt >> /tmp/wifi-records.txt
  [ -f /tmp/ventoy-ro/linux-setup/setup.conf ] && cp /tmp/ventoy-ro/linux-setup/setup.conf /tmp/setup.conf
  # The builder already packages linux/. No template placeholder is needed here.
  for SL_PROGRESS_LIB in /tmp/ventoy-ro/linux-setup/linux/lib/sl-progress.sh /tmp/ventoy-ro/linux-setup/kit/linux/lib/sl-progress.sh; do
    [ -f "$SL_PROGRESS_LIB" ] && { cp "$SL_PROGRESS_LIB" /tmp/sl-progress.sh; break; }
  done
  umount /tmp/ventoy-ro 2>/dev/null
fi
if [ -f /tmp/sl-progress.sh ]; then
  . /tmp/sl-progress.sh
else
  sl_progress_spinner_start() { printf '%s\n' "$1"; }
  sl_progress_spinner_stop() { [ -z "${1:-}" ] || printf '%s\n' "$1"; }
fi
SL_PRE_STEP=0
sl_pre_begin() {
  SL_PRE_STEP=$((SL_PRE_STEP + 1))
  printf 'Preparation step %s: %s\n' "$SL_PRE_STEP" "$1"
  sl_progress_spinner_start "$1"
}
sl_pre_end() { sl_progress_spinner_stop "${1:-}"; }
WIFI_KIND=$(python3 /tmp/sl-wifi.py pick /tmp/wifi-records.txt "$SID" "$UID_" /tmp/sl-wifi-record 2>/dev/null)
umask 022

# Optional Setup-App hand-off. No file means the original interactive path below, byte for byte.
# Blank values always fall back to the normal question. TARGET_DISK and TARGET_DISK_ERASE are separate on purpose:
# a profile or Wi-Fi choice can never imply permission to erase a computer drive.
SETUP_AUTO=0
PROFILE=""; WIFI_MODE=ask; WIFI_SSID_B64=""; AI_MODEL=ask; SECURE_BOOT=ask; BACKUP_CONTINUE=ask
TARGET_DISK=""; TARGET_DISK_ERASE=""; SETUP_CONF_VERSION=""
STEP_SAVE_WIFI=no; STEP_SAVE_BROWSER_PASSWORDS=no; STEP_COLLECT_APPS=no
STEP_RESCUE_TOOLS=yes; STEP_DEBIAN=yes; STEP_OFFLINE_PACKS=yes
if [ -s /tmp/setup.conf ]; then
  # BEGIN STRICT SETUP.CONF PARSER
  # setup.conf is data, never shell code. Only the Setup app's single-quoted,
  # one-key-per-line schema is accepted. No command substitution, eval, source,
  # value echo, or partial application on a late malformed line is possible.
  CONF_OK=1
  declare -A CONF_VALUES=() CONF_SEEN=()
  for CONF_KEY in SETUP_CONF_VERSION PROFILE WIFI_SSID_B64 TARGET_DISK TARGET_DISK_ERASE; do
    CONF_VALUES[$CONF_KEY]=""
  done
  CONF_VALUES[WIFI_MODE]=ask
  CONF_VALUES[AI_MODEL]=ask
  CONF_VALUES[SECURE_BOOT]=ask
  CONF_VALUES[BACKUP_CONTINUE]=ask
  CONF_VALUES[STEP_SAVE_WIFI]=no
  CONF_VALUES[STEP_SAVE_BROWSER_PASSWORDS]=no
  CONF_VALUES[STEP_COLLECT_APPS]=no
  CONF_VALUES[STEP_RESCUE_TOOLS]=yes
  CONF_VALUES[STEP_DEBIAN]=yes
  CONF_VALUES[STEP_OFFLINE_PACKS]=yes
  CONF_LINE_N=0
  while IFS= read -r CONF_LINE || [ -n "$CONF_LINE" ]; do
    CONF_LINE_N=$((CONF_LINE_N + 1))
    [ "$CONF_LINE_N" -le 64 ] || { CONF_OK=0; break; }
    [[ "$CONF_LINE" =~ ^[[:space:]]*$ ]] && continue
    [[ "$CONF_LINE" == \#* ]] && continue
    CONF_ASSIGN_RE="^([A-Z_][A-Z0-9_]*)='([^']*)'$"
    if [[ "$CONF_LINE" =~ $CONF_ASSIGN_RE ]]; then
      CONF_KEY=${BASH_REMATCH[1]}
      CONF_VALUE=${BASH_REMATCH[2]}
    else
      CONF_OK=0; break
    fi
    case "$CONF_KEY" in
      SETUP_CONF_VERSION|PROFILE|WIFI_MODE|WIFI_SSID_B64|AI_MODEL|SECURE_BOOT|BACKUP_CONTINUE|TARGET_DISK|TARGET_DISK_ERASE|STEP_SAVE_WIFI|STEP_SAVE_BROWSER_PASSWORDS|STEP_COLLECT_APPS|STEP_RESCUE_TOOLS|STEP_DEBIAN|STEP_OFFLINE_PACKS) ;;
      *) CONF_OK=0; break ;;
    esac
    [ -z "${CONF_SEEN[$CONF_KEY]:-}" ] || { CONF_OK=0; break; }
    CONF_SEEN[$CONF_KEY]=1
    CONF_VALUES[$CONF_KEY]=$CONF_VALUE
  done < /tmp/setup.conf
  [ "${CONF_VALUES[SETUP_CONF_VERSION]}" = 1 ] || CONF_OK=0
  case "${CONF_VALUES[PROFILE]}" in ""|full|lite|min|atomic) ;; *) CONF_OK=0 ;; esac
  case "${CONF_VALUES[WIFI_MODE]}" in ask|saved|skip) ;; *) CONF_OK=0 ;; esac
  case "${CONF_VALUES[AI_MODEL]}" in ask|yes|no) ;; *) CONF_OK=0 ;; esac
  case "${CONF_VALUES[SECURE_BOOT]}" in ask|on|off) ;; *) CONF_OK=0 ;; esac
  case "${CONF_VALUES[BACKUP_CONTINUE]}" in ask|yes) ;; *) CONF_OK=0 ;; esac
  case "${CONF_VALUES[TARGET_DISK]}" in ""|*[!a-z0-9]*) [ -z "${CONF_VALUES[TARGET_DISK]}" ] || CONF_OK=0 ;; esac
  case "${CONF_VALUES[TARGET_DISK_ERASE]}" in ""|ERASE) ;; *) CONF_OK=0 ;; esac
  [[ "${CONF_VALUES[WIFI_SSID_B64]}" =~ ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$ ]] || CONF_OK=0
  for CONF_KEY in STEP_SAVE_WIFI STEP_SAVE_BROWSER_PASSWORDS STEP_COLLECT_APPS STEP_RESCUE_TOOLS STEP_DEBIAN STEP_OFFLINE_PACKS; do
    case "${CONF_VALUES[$CONF_KEY]}" in yes|no) ;; *) CONF_OK=0 ;; esac
  done
  [ "${CONF_VALUES[TARGET_DISK_ERASE]}" = ERASE ] && [ -z "${CONF_VALUES[TARGET_DISK]}" ] && CONF_OK=0
  if [ "$CONF_OK" = 1 ]; then
    for CONF_KEY in "${!CONF_VALUES[@]}"; do
      printf -v "$CONF_KEY" '%s' "${CONF_VALUES[$CONF_KEY]}"
    done
  fi
  unset CONF_ASSIGN_RE CONF_VALUE CONF_LINE CONF_LINE_N CONF_KEY CONF_SEEN CONF_VALUES
  # END STRICT SETUP.CONF PARSER
  if [ "$CONF_OK" = 1 ]; then
    SETUP_AUTO=1
    header "your choices from Windows"
    echo "   The Setup app on this USB stick saved these choices. Check them now:"
    echo
    [ -n "$PROFILE" ] && echo "     System: $PROFILE"
    echo "     Wi-Fi: $WIFI_MODE"
    [ -n "$WIFI_SSID_B64" ] && echo "     A home Wi-Fi network was selected (its name is not printed here)."
    [ "$AI_MODEL" != ask ] && echo "     Optional AI model: $AI_MODEL"
    [ "$SECURE_BOOT" != ask ] && echo "     Secure Boot intention: $SECURE_BOOT"
    [ -n "$TARGET_DISK" ] && echo "     Target drive: /dev/$TARGET_DISK (erase confirmation: ${TARGET_DISK_ERASE:-none})"
    echo
    echo "     Steps switched off in Windows stay off. Anything blank is asked normally."
    echo "     Nothing starts until you answer. There is no countdown and no automatic choice."
    echo "     Press Enter to START WITH THESE SETTINGS, or C to CHANGE ANYTHING."
    echo
    while true; do
      CHANGE=""
      if ! read -rsn1 CHANGE; then
        # End of input is not consent. Keep waiting instead of installing or erasing anything.
        sleep 3600
        continue
      fi
      case "$CHANGE" in
        "")
          rm -f /tmp/sl-copy-browser-passwords
          [ "$STEP_SAVE_BROWSER_PASSWORDS" = yes ] && : > /tmp/sl-copy-browser-passwords
          echo; break ;;
        [Cc])
          SETUP_AUTO=0; PROFILE=""; WIFI_MODE=ask; WIFI_SSID_B64=""; AI_MODEL=ask; SECURE_BOOT=ask; BACKUP_CONTINUE=ask
          STEP_SAVE_BROWSER_PASSWORDS=no; rm -f /tmp/sl-copy-browser-passwords
          TARGET_DISK=""; TARGET_DISK_ERASE=""
          echo; echo "   No problem. Every question will be asked, just as before."
          break
          ;;
        *) echo; echo "   Please press Enter to start with these settings, or C to change anything." ;;
      esac
    done
  else
    echo "   The setup.conf file is not valid, so it is ignored. Every question will be asked."
  fi
fi

# ---------------------------------------------------------------- 0. which drive
# Internal drives of 16 GB or more; never USB drives, SD cards, optical or virtual disks
NAMES=(); SIZES=(); SSD=(); MODELS=()
for d in /sys/block/*; do
  n=$(basename "$d")
  case "$n" in loop*|ram*|zram*|sr*|fd*|dm-*|md*|nbd*|mmcblk*boot*|mmcblk*rpmb) continue ;; esac
  [ "$(cat "$d/removable" 2>/dev/null)" = "0" ] || continue
  readlink -f "$d/device" | grep -q '/usb' && continue
  [ "$(cat "$d/device/type" 2>/dev/null)" = "SD" ] && continue
  size=$(cat "$d/size" 2>/dev/null || echo 0)
  [ "$size" -ge 33554432 ] || continue   # at least 16 GB (512-byte sectors)
  NAMES+=("$n"); SIZES+=("$size")
  if [ "$(cat "$d/queue/rotational" 2>/dev/null)" = "0" ]; then SSD+=(SSD); else SSD+=(HDD); fi
  MODELS+=("$(sed 's/ *$//' "$d/device/model" 2>/dev/null)")
done
contents() {  # what is on a drive now, in plain words
  local parts fs what=""
  parts=$(lsblk -nro NAME "/dev/$1" 2>/dev/null | tail -n +2 | wc -l)
  [ "$parts" -eq 0 ] && { echo "empty"; return; }
  fs=$(lsblk -nro FSTYPE "/dev/$1" 2>/dev/null | grep . | sort -u | tr '\n' ' ')
  case " $fs" in *" ntfs "*|*" BitLocker "*) what="Windows, " ;; esac
  case " $fs" in *" ext4 "*|*" btrfs "*|*" xfs "*|*" crypto_LUKS "*) what="${what}Linux, " ;; esac
  echo "${what}$parts partition(s): ${fs% }"
}

if [ ${#NAMES[@]} -eq 0 ]; then
  header "setup"
  echo "   This computer:  $VENDOR $MODEL"
  echo
  echo "   No internal drive of 16 GB or more was found, so nothing can be installed."
  cancel
fi
PICK=0; TARGET_PICKED=0
if [ "$SETUP_AUTO" = 1 ] && [ -n "$TARGET_DISK" ]; then
  for i in "${!NAMES[@]}"; do [ "${NAMES[$i]}" = "$TARGET_DISK" ] && { PICK=$i; TARGET_PICKED=1; break; }; done
  [ "$TARGET_PICKED" = 1 ] || echo "   The recorded target /dev/$TARGET_DISK is not present. The normal drive question will be asked."
fi
if [ ${#NAMES[@]} -gt 1 ] && [ "$TARGET_PICKED" = 0 ]; then
  # Suggest the biggest SSD (fast); otherwise the biggest drive. The person still has to type the number.
  BEST=-1; BESTSIZE=0
  for i in "${!NAMES[@]}"; do [ "${SSD[$i]}" = SSD ] && [ "${SIZES[$i]}" -gt "$BESTSIZE" ] && { BEST=$i; BESTSIZE=${SIZES[$i]}; }; done
  if [ "$BEST" -lt 0 ]; then
    for i in "${!NAMES[@]}"; do [ "${SIZES[$i]}" -gt "$BESTSIZE" ] && { BEST=$i; BESTSIZE=${SIZES[$i]}; }; done
  fi
  header "which drive?"
  echo "   This computer has more than one drive. Linux goes on ONE of them, and that"
  echo "   drive is erased. The others are not touched."
  echo
  for i in "${!NAMES[@]}"; do
    printf '   %d)  /dev/%-8s %-24.24s %5s GB  %s\n' $((i + 1)) "${NAMES[$i]}" "${MODELS[$i]:-unknown model}" $((SIZES[i] / 2097152)) "${SSD[$i]}"
    echo "        now contains: $(contents "${NAMES[$i]}")"
  done
  echo
  echo "   Suggested: $((BEST + 1)) (${SSD[$BEST]}: SSDs are much faster than HDDs)."
  echo
  while true; do
    answer "Type the number of the drive to install on (Q to cancel):"
    case "$REPLY_TEXT" in [Qq]) cancel ;; esac
    case "$REPLY_TEXT" in *[!0-9]*) continue ;; esac
    if [ "$REPLY_TEXT" -ge 1 ] && [ "$REPLY_TEXT" -le ${#NAMES[@]} ]; then PICK=$((REPLY_TEXT - 1)); break; fi
  done
fi
DISK=${NAMES[$PICK]}
DISK_GB=$((SIZES[PICK] / 2097152))
DISK_KIND=${SSD[$PICK]}
DISK_MODEL=${MODELS[$PICK]}

# ---------------------------------------------------------------- hardware compatibility check
# HOOK for the hardware engineer's linux/hw/compat-check.sh (embedded by make-usb.ps1 as base64; empty if the
# kit doesn't have it yet, then everything counts as supported). Contract: it prints a plain-text report;
# lines HW_STATUS=OK|NOTES|UNSUPPORTED, HW_PROFILE=full|lite, HW_TEXT_INSTALL=0|1, HW_DISTRO=<which Linux suits this
# computer> and HW_DISTRO_REASON=<one plain sentence> are read, not shown. UNSUPPORTED uses HW_DISTRO to tell the person
# which boot-menu entry to restart into (the names of the Debian entries are filled in by make-usb.ps1).
cat > /tmp/hw-compat.b64 <<'HWCHECK_END'
IyEvYmluL2Jhc2gKIyBody9jb21wYXQtY2hlY2suc2ggKG93bmVyOiBoYXJkd2FyZSkgLSAiV2ls
bCBUaGUgQ29tcGxldGUgU2VjdXJlIExpbnV4IFBhY2thZ2Ugd29yayBvbiB0aGlzIGNvbXB1dGVy
LAojIGFuZCB3aGljaCBMaW51eCBzaG91bGQgaXQgZ2V0PyIKIwojICAgYmFzaCBjb21wYXQtY2hl
Y2suc2ggWy0taW5zdGFsbGVyXSBbLS1maXh0dXJlIERJUl0gWy0tYXNjaWldIFstLWJyaWVmXSBb
LS1leHBvcnQgRklMRV0KIwojICAgLS1pbnN0YWxsZXIgICAgIGZvciB0aGUgRmVkb3JhIGluc3Rh
bGxlcidzICVwcmU6IHBsYWluIEFTQ0lJIHJlcG9ydCwgdGhlbiB0aGVzZSBtYWNoaW5lLXJlYWRh
YmxlIGxpbmVzCiMgICAgICAgICAgICAgICAgICAgKHRoZSBpbnN0YWxsZXIgaGlkZXMgdGhlbSk6
ICBIV19TVEFUVVM9T0t8Tk9URVN8VU5TVVBQT1JURUQgIEhXX1BST0ZJTEU9ZnVsbHxsaXRlCiMg
ICAgICAgICAgICAgICAgICAgSFdfVEVYVF9JTlNUQUxMPTB8MSAgSFdfRElTVFJPPTxzZWUgYmVs
b3c+ICBIV19ESVNUUk9fUkVBU09OPTxvbmUgbGluZT4uIEFsd2F5cyBleGl0cyAwLgojICAgLS1m
aXh0dXJlIERJUiAgIHJlYWQgYSBmYWtlIC9zeXMgKyAvcHJvYyB0cmVlICh0ZXN0cykgaW5zdGVh
ZCBvZiB0aGlzIGNvbXB1dGVyCiMgICAtLWFzY2lpICAgICAgICAgWyBPSyBdIFtOT1RFXSBbIE5P
IF0gaW5zdGVhZCBvZiB0aGUgY2hlY2stbWFyayBzeW1ib2xzIChMaW51eCB0ZXh0IGNvbnNvbGUg
Zm9udHMgbGFjayB0aGVtKQojICAgLS1icmllZiAgICAgICAgIG9ubHkgdGhlIG5vdGVzLCBwcm9i
bGVtcyBhbmQgdGhlIHZlcmRpY3QKIyAgIC0tZXhwb3J0IEZJTEUgICBhbHNvIHdyaXRlIHNoZWxs
IHZhcmlhYmxlcyAoSFdfVkVSRElDVCwgSFdfU1RBVFVTLCBIV19QUk9GSUxFX1NVR0dFU1QsIEhX
X1RFWFRfSU5TVEFMTCwKIyAgICAgICAgICAgICAgICAgICBIV19ESVNUUk8sIEhXX0JMT0NLRVJT
LCBIV19CTE9DS0VSX1RFWFQsIEhXX0FTS19DT05USU5VRSwgSFdfTkVFRFNfV0lSRUQsIC4uLikK
IwojIEhXX0RJU1RSTzogZmVkb3JhICh0aGlzIFVTQidzIG5vcm1hbCBwYXRoKSB8IGZlZG9yYS1t
aW4gKHRoaXMgVVNCJ3MgRmVkb3JhIHdpdGggdGhlIGxpZ2h0IExYUXQgZGVza3RvcDoKIyBhIDY0
LWJpdCBQQyB3aXRoIGFib3V0IDItMyBHQiBtZW1vcnkgc3RheXMgaW4gdGhlIEZlZG9yYSBmYW1p
bHkpIHwgZmVkb3JhLXQyIChGZWRvcmEgKyB0MmxpbnV4IGtlcm5lbCwKIyBUMiBNYWNzKSB8IGFz
YWhpIChBcHBsZSBTaWxpY29uOiBGZWRvcmEgQXNhaGkgUmVtaXgsIGluc3RhbGxlZCBmcm9tIG1h
Y09TKSB8IGRlYmlhbi1saXRlICg2NC1iaXQgUEMgdW5kZXIKIyB+MS43IEdCIG9mIHJlcG9ydGVk
IG1lbW9yeTogRGViaWFuIDEzIGFtZDY0LCBsaWdodCBkZXNrdG9wKSB8IGRlYmlhbi1pMzg2ICgz
Mi1iaXQtb25seSBQQzogRGViaWFuIDEyIGkzODYpCiMgfCB1bnN1cHBvcnRlZCAoYmVsb3cgRGVi
aWFuJ3MgbWluaW11bXMpLgojCiMgRXhpdCBjb2RlICh3aXRob3V0IC0taW5zdGFsbGVyKTogMCA9
IEdPT0QsIDEgPSBXT1JLUyBXSVRIIE5PVEVTLCAyID0gTk9UIFNVUFBPUlRFRCBCWSBUSElTIFVT
QigncyBGZWRvcmEpLCAzID0gZXJyb3IuCiMgU2VsZi1jb250YWluZWQgKHRoZSBpbnN0YWxsZXIg
ZW1iZWRzIG9ubHkgdGhpcyBmaWxlKTogQmFzaCA0KywgY29yZXV0aWxzLCBzZWQsIGF3aywgZ3Jl
cC4gTm8gb2QsIG5vIG1hcGZpbGUuCiMgVGhlIGJsb2NrIGJldHdlZW4gIkJFR0lOIGRldGVjdC5z
aCIgYW5kICJFTkQgZGV0ZWN0LnNoIiBpcyBhIHZlcmJhdGltIGNvcHkgb2YgaHcvZGV0ZWN0LnNo
CiMgKHRlc3RzL2hhcmR3YXJlL3N5bmMtY29tcGF0LnNoIHJlZnJlc2hlcyBpdDsgdGVzdHMvaGFy
ZHdhcmUvcnVuLnNoIGZhaWxzIGlmIHRoZXkgZGlmZmVyKS4KIyBGb3IgdGhlIERlYmlhbiBpbnN0
YWxsZXIgKGJ1c3lib3ggYXNoKSB1c2UgaHcvY29tcGF0LWNoZWNrLW1pbi5zaCBpbnN0ZWFkLgoK
QVNDSUk9MCBCUklFRj0wIEVYUE9SVD0iIiBGSVhUVVJFPSIiIElOU1RBTExFUj0wCndoaWxlIFsg
JCMgLWd0IDAgXTsgZG8KICBjYXNlICIkMSIgaW4KICAgIC0taW5zdGFsbGVyKSBJTlNUQUxMRVI9
MTsgQVNDSUk9MSA7OwogICAgLS1maXh0dXJlKSBGSVhUVVJFPSR7MiUvfTsgc2hpZnQgOzsKICAg
IC0tYXNjaWkpIEFTQ0lJPTEgOzsKICAgIC0tYnJpZWYpIEJSSUVGPTEgOzsKICAgIC0tZXhwb3J0
KSBFWFBPUlQ9JDI7IHNoaWZ0IDs7CiAgICAtaHwtLWhlbHApIHNlZCAtbiAnMiwyNnAnICIkMCIg
fCBzZWQgJ3MvXiMgXHswLDFcfS8vJzsgZXhpdCAwIDs7CiAgICAqKSBlY2hvICJVbmtub3duIG9w
dGlvbjogJDEiID4mMjsgZXhpdCAzIDs7CiAgZXNhYwogIHNoaWZ0CmRvbmUKSFdfUk9PVD0kRklY
VFVSRQpIV19FTUJFRERFRD0xCgojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09IEJFR0lOIGRldGVjdC5zaAojIS9i
aW4vYmFzaAojIGh3L2RldGVjdC5zaCAob3duZXI6IGhhcmR3YXJlKSAtIGhhcmR3YXJlIGRldGVj
dGlvbiBmb3IgVGhlIENvbXBsZXRlIFNlY3VyZSBMaW51eCBQYWNrYWdlLgojCiMgUHVyZSBiYXNo
ICsgY29yZXV0aWxzL3NlZC9hd2svZ3JlcCAobm8gb2QsIG5vIG1hcGZpbGUpLiBOTyBkZXBlbmRl
bmN5IG9uIGxpYi9jb21tb24uc2g6IGl0IGFsc28gcnVucyBpbnNpZGUgdGhlIEZlZG9yYQojIGlu
c3RhbGxlcidzICVwcmUsIG9uIGEgbGl2ZSBzeXN0ZW0sIGFuZCBvbiB0aGUgaW5zdGFsbGVkIG1h
Y2hpbmUuCiMKIyAgIC4gaHcvZGV0ZWN0LnNoICAgICAgICAgICAgdGhlbiBjYWxsIGh3X2NwdSwg
aHdfcmFtLCBod19maXJtd2FyZSwgaHdfZG1pLCBod19tYWMsIGh3X2dwdXMsIGh3X3dpZmksCiMg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgIGh3X2V0aGVybmV0LCBod19zdG9yYWdlLCBod19i
YXR0ZXJ5IChvciBod19hbGwpLiBFYWNoIHByaW50cyBrZXk9dmFsdWUgbGluZXMuCiMgICBiYXNo
IGh3L2RldGVjdC5zaCBbLS1maXh0dXJlIERJUl0gICAgIHByaW50cyBldmVyeXRoaW5nIChod19h
bGwpCiMgICBod19nZXQgS0VZICAgICAgICAgICAgICAgIHByaW50cyBvbmUgdmFsdWUgZnJvbSBo
d19hbGwgKGNhY2hlZCBwZXIgc2hlbGwpCiMKIyBIV19ST09UIChvciAtLWZpeHR1cmUgRElSKSBp
cyBwdXQgaW4gZnJvbnQgb2YgZXZlcnkgL3N5cyBhbmQgL3Byb2MgcGF0aCwgc28gdGVzdHMgY2Fu
IHVzZSBhIGZha2UgdHJlZS4KIyBJbiBhIGZpeHR1cmUsIHRoZSBtYWNoaW5lIHR5cGUgY29tZXMg
ZnJvbSBESVIvdW5hbWUtbSAoZGVmYXVsdCB4ODZfNjQpLgojIFZhbHVlcyBuZXZlciBjb250YWlu
IG5ld2xpbmVzOyB0aGV5IG1heSBjb250YWluIHNwYWNlcy4gUGFyc2Ugd2l0aDogIHdoaWxlIElG
Uz0nPScgcmVhZCAtciBrIHY7IGRvIC4uLjsgZG9uZQoKSFdfUk9PVD0ke0hXX1JPT1Q6LX0KCl9o
d19yZWFkKCkgeyBsb2NhbCB2PSIiOyBbIC1yICIkSFdfUk9PVCQxIiBdICYmIHY9JCh0ciAtZCAn
XDAnIDwgIiRIV19ST09UJDEiIDI+L2Rldi9udWxsIHwgaGVhZCAtbjEpOyB2PSR7diUiJHt2IyMq
WyFbOnNwYWNlOl1dfSJ9OyBwcmludGYgJyVzJyAiJHYiOyB9CiMgX2h3X2VmaWJ5dGUgRklMRTog
dGhlIHZhbHVlIGJ5dGUgb2YgYSBib29sZWFuIEVGSSB2YXJpYWJsZSAoNCBhdHRyaWJ1dGUgYnl0
ZXMsIHRoZW4gMCBvciAxKSAtPiAwIC8gMSAvICIiCiMgKG5vIG9kOiBvbmx5IGhlYWQvdGFpbC90
ciwgd2hpY2ggZXZlcnkgaW5zdGFsbGVyIGltYWdlIGhhcykKX2h3X2VmaWJ5dGUoKSB7IHRhaWwg
LWMgMSAiJDEiIDI+L2Rldi9udWxsIHwgdHIgJ1wwMDBcMDAxJyAnMDEnIHwgdHIgLWNkICcwMSc7
IH0KX2h3X2hleCgpICB7IGxvY2FsIHY7IHY9JChfaHdfcmVhZCAiJDEiKTsgdj0ke3YjMHh9OyBw
cmludGYgJyVzJyAiJHYiIHwgdHIgJ0EtRicgJ2EtZic7IH0KCmh3X2FyY2goKSB7ICAgIyBtYWNo
aW5lIHR5cGU6IHg4Nl82NCwgaTY4NiwgYWFyY2g2NCAuLi4KICBpZiBbIC1uICIkSFdfUk9PVCIg
XTsgdGhlbgogICAgbG9jYWwgYTsgYT0kKF9od19yZWFkIC91bmFtZS1tKTsgcHJpbnRmICclcycg
IiR7YToteDg2XzY0fSIKICBlbHNlCiAgICB1bmFtZSAtbSAyPi9kZXYvbnVsbCB8fCBlY2hvIHVu
a25vd24KICBmaQp9CgojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0gQ1BVCmh3X2NwdSgpIHsKICBsb2NhbCBhcmNoIGZsYWdz
IHZlbmRvciBtb2RlbCBsZXZlbD0wIGxtPW5vIGNvcmVzCiAgYXJjaD0kKGh3X2FyY2gpCiAgdmVu
ZG9yPSQoYXdrIC1GJzogKicgJy9edmVuZG9yX2lkL3twcmludCAkMjsgZXhpdH0nICIkSFdfUk9P
VC9wcm9jL2NwdWluZm8iIDI+L2Rldi9udWxsKQogIG1vZGVsPSQoYXdrIC1GJzogKicgJy9ebW9k
ZWwgbmFtZS97cHJpbnQgJDI7IGV4aXR9JyAiJEhXX1JPT1QvcHJvYy9jcHVpbmZvIiAyPi9kZXYv
bnVsbCkKICBmbGFncz0iICQoYXdrIC1GJzogKicgJy9eZmxhZ3Mve3ByaW50ICQyOyBleGl0fScg
IiRIV19ST09UL3Byb2MvY3B1aW5mbyIgMj4vZGV2L251bGwpICIKICBjb3Jlcz0kKGdyZXAgLWMg
J15wcm9jZXNzb3InICIkSFdfUk9PVC9wcm9jL2NwdWluZm8iIDI+L2Rldi9udWxsKQogIGNhc2Ug
IiR2ZW5kb3IiIGluCiAgICBHZW51aW5lSW50ZWwpIHZlbmRvcj1pbnRlbCA7OyBBdXRoZW50aWNB
TUR8SHlnb25HZW51aW5lKSB2ZW5kb3I9YW1kIDs7CiAgICAiIikgY2FzZSAiJGFyY2giIGluIGFh
cmNoNjR8YXJtKikgdmVuZG9yPWFybSA7OyAqKSB2ZW5kb3I9dW5rbm93biA7OyBlc2FjIDs7CiAg
ICAqKSB2ZW5kb3I9b3RoZXIgOzsKICBlc2FjCiAgY2FzZSAiJGZsYWdzIiBpbiAqIiBsbSAiKikg
bG09eWVzIDs7IGVzYWMKICAjIHg4Ni02NCBtaWNyb2FyY2hpdGVjdHVyZSBsZXZlbHMgKHBzQUJJ
KTogdjEgPSBsbSBjbW92IGN4OCBmcHUgZnhzciBtbXggc3lzY2FsbCBzc2UyCiAgX2h3X2hhcygp
IHsgbG9jYWwgZjsgZm9yIGYgaW4gIiRAIjsgZG8gY2FzZSAiJGZsYWdzIiBpbiAqIiAkZiAiKikg
OzsgKikgcmV0dXJuIDEgOzsgZXNhYzsgZG9uZTsgcmV0dXJuIDA7IH0KICBpZiBbICIkbG0iID0g
eWVzIF07IHRoZW4KICAgIGxldmVsPTEKICAgIF9od19oYXMgY3gxNiBsYWhmX2xtIHBvcGNudCBz
c2U0XzEgc3NlNF8yIHNzc2UzICYmIGxldmVsPTIKICAgIFsgJGxldmVsID0gMiBdICYmIF9od19o
YXMgYXZ4IGF2eDIgYm1pMSBibWkyIGYxNmMgZm1hIGFibSBtb3ZiZSB4c2F2ZSAmJiBsZXZlbD0z
CiAgICBbICRsZXZlbCA9IDMgXSAmJiBfaHdfaGFzIGF2eDUxMmYgYXZ4NTEyYncgYXZ4NTEyY2Qg
YXZ4NTEyZHEgYXZ4NTEydmwgJiYgbGV2ZWw9NAogIGZpCiAgdW5zZXQgLWYgX2h3X2hhcwogIFsg
LXogIiRtb2RlbCIgXSAmJiBtb2RlbD0kKGF3ayAtRic6IConICcvXihIYXJkd2FyZXxDUFUgcGFy
dCkve3ByaW50ICQyOyBleGl0fScgIiRIV19ST09UL3Byb2MvY3B1aW5mbyIgMj4vZGV2L251bGwp
CiAgZWNobyAiY3B1X2FyY2g9JGFyY2giCiAgZWNobyAiY3B1X3ZlbmRvcj0kdmVuZG9yIgogIGVj
aG8gImNwdV9tb2RlbD0kbW9kZWwiCiAgZWNobyAiY3B1X2NvcmVzPSR7Y29yZXM6LTB9IgogIGVj
aG8gImNwdV82NGJpdD0kbG0iCiAgZWNobyAiY3B1X3g4Nl9sZXZlbD0kbGV2ZWwiCn0KCiMgLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLSBtZW1vcnkKaHdfcmFtKCkgewogIGxvY2FsIGtiOyBrYj0kKGF3ayAnL15NZW1Ub3RhbDov
e3ByaW50ICQyOyBleGl0fScgIiRIV19ST09UL3Byb2MvbWVtaW5mbyIgMj4vZGV2L251bGwpCiAg
a2I9JHtrYjotMH0KICBlY2hvICJyYW1fbWI9JCgoa2IgLyAxMDI0KSkiCiAgZWNobyAicmFtX2di
PSQoKCAoa2IgKyA1MjQyODgpIC8gMTA0ODU3NiApKSIgICAgICMgcm91bmRlZCwgYXMgdGhlIHNl
dHVwIHNjcmVlbiBzaG93cyBpdAp9CgojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0gZmlybXdhcmUgLyBTZWN1cmUgQm9vdApo
d19maXJtd2FyZSgpIHsKICBsb2NhbCBmdz1iaW9zIGJpdHM9IiIgc2I9b2ZmIHNtPSIiIGYgYgog
IGlmIFsgLWQgIiRIV19ST09UL3N5cy9maXJtd2FyZS9lZmkiIF07IHRoZW4KICAgIGZ3PXVlZmkK
ICAgIGJpdHM9JChfaHdfcmVhZCAvc3lzL2Zpcm13YXJlL2VmaS9md19wbGF0Zm9ybV9zaXplKQog
ICAgc2I9dW5rbm93bgogICAgIyBlZml2YXI6IDQgYnl0ZXMgb2YgYXR0cmlidXRlcywgdGhlbiB0
aGUgdmFsdWUgYnl0ZSAoMSA9IFNlY3VyZSBCb290IGVuZm9yY2luZykKICAgIGZvciBmIGluICIk
SFdfUk9PVCIvc3lzL2Zpcm13YXJlL2VmaS9lZml2YXJzL1NlY3VyZUJvb3QtOGJlNGRmNjEtOTNj
YS0xMWQwLWFhMGQtMDBlMDk4MDMyYjhjOyBkbwogICAgICBbIC1yICIkZiIgXSB8fCBjb250aW51
ZQogICAgICBiPSQoX2h3X2VmaWJ5dGUgIiRmIikKICAgICAgY2FzZSAiJGIiIGluIDEpIHNiPW9u
IDs7IDApIHNiPW9mZiA7OyBlc2FjCiAgICBkb25lCiAgICBmb3IgZiBpbiAiJEhXX1JPT1QiL3N5
cy9maXJtd2FyZS9lZmkvZWZpdmFycy9TZXR1cE1vZGUtOGJlNGRmNjEtOTNjYS0xMWQwLWFhMGQt
MDBlMDk4MDMyYjhjOyBkbwogICAgICBbIC1yICIkZiIgXSB8fCBjb250aW51ZQogICAgICBiPSQo
X2h3X2VmaWJ5dGUgIiRmIikKICAgICAgY2FzZSAiJGIiIGluIDEpIHNtPXllcyA7OyAwKSBzbT1u
byA7OyBlc2FjCiAgICBkb25lCiAgICAjIEZhbGwgYmFjayB0byBtb2t1dGlsIG9uIGEgcmVhbCBz
eXN0ZW0gKG5vdCBpbiBmaXh0dXJlcykKICAgIGlmIFsgIiRzYiIgPSB1bmtub3duIF0gJiYgWyAt
eiAiJEhXX1JPT1QiIF0gJiYgY29tbWFuZCAtdiBtb2t1dGlsID4vZGV2L251bGwgMj4mMTsgdGhl
bgogICAgICBjYXNlICIkKG1va3V0aWwgLS1zYi1zdGF0ZSAyPi9kZXYvbnVsbCkiIGluICpuYWJs
ZWQqKSBzYj1vbiA7OyAqaXNhYmxlZCopIHNiPW9mZiA7OyBlc2FjCiAgICBmaQogICAgIyAoSW50
ZWwgTWFjcyBoYXZlIG5vIFNlY3VyZUJvb3QgdmFyaWFibGUgYXQgYWxsOiBBcHBsZSdzIG93biBz
Y2hlbWU7IFQyIE1hY3MgZW5mb3JjZSBpdCBpbiB0aGUgVDIgLT4gdW5rbm93bikKICBmaQogIGVj
aG8gImZpcm13YXJlPSRmdyIKICBlY2hvICJlZmlfYml0cz0ke2JpdHM6LX0iCiAgZWNobyAic2Vj
dXJlX2Jvb3Q9JHNiIgogIGVjaG8gInNldHVwX21vZGU9JHNtIgp9CgojIC0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0gRE1JICht
YWtlciAvIG1vZGVsKQpod19kbWkoKSB7CiAgbG9jYWwgdmVuZG9yIHByb2R1Y3QgZmFtaWx5IHZl
cnNpb24gY3Qga2luZAogIHZlbmRvcj0kKF9od19yZWFkIC9zeXMvY2xhc3MvZG1pL2lkL3N5c192
ZW5kb3IpCiAgcHJvZHVjdD0kKF9od19yZWFkIC9zeXMvY2xhc3MvZG1pL2lkL3Byb2R1Y3RfbmFt
ZSkKICBmYW1pbHk9JChfaHdfcmVhZCAvc3lzL2NsYXNzL2RtaS9pZC9wcm9kdWN0X2ZhbWlseSkK
ICB2ZXJzaW9uPSQoX2h3X3JlYWQgL3N5cy9jbGFzcy9kbWkvaWQvcHJvZHVjdF92ZXJzaW9uKQog
IGN0PSQoX2h3X3JlYWQgL3N5cy9jbGFzcy9kbWkvaWQvY2hhc3Npc190eXBlKQogIGNhc2UgIiRj
dCIgaW4KICAgIDh8OXwxMHwxMXwxNHwzMHwzMXwzMikga2luZD1sYXB0b3AgOzsgICAgICMgcG9y
dGFibGUsIGxhcHRvcCwgbm90ZWJvb2ssIGhhbmQgaGVsZCwgc3ViIG5vdGVib29rLCB0YWJsZXQs
IGNvbnZlcnRpYmxlLCBkZXRhY2hhYmxlCiAgICAzfDR8NXw2fDd8MTN8MTV8MTZ8MzV8MzYpIGtp
bmQ9ZGVza3RvcCA7OwogICAgIiIpIGtpbmQ9dW5rbm93biA7OwogICAgKikga2luZD1vdGhlciA7
OwogIGVzYWMKICBsb2NhbCBzaG9ydAogIGNhc2UgIiQocHJpbnRmICclcycgIiR2ZW5kb3IiIHwg
dHIgJ2EteicgJ0EtWicpIiBpbgogICAgQVBQTEUqKSBzaG9ydD1hcHBsZSA7OyBERUxMKikgc2hv
cnQ9ZGVsbCA7OyBUT1NISUJBKnxEWU5BQk9PSyopIHNob3J0PXRvc2hpYmEgOzsgTEVOT1ZPKikg
c2hvcnQ9bGVub3ZvIDs7CiAgICBIUHxIRVdMRVRUKikgc2hvcnQ9aHAgOzsgQVNVUyopIHNob3J0
PWFzdXMgOzsgTUlDUk9TT0ZUKikgc2hvcnQ9bWljcm9zb2Z0IDs7IEFDRVIqKSBzaG9ydD1hY2Vy
IDs7CiAgICBHT09HTEUqKSBzaG9ydD1nb29nbGUgOzsgTVNJKnxNSUNSTy1TVEFSKikgc2hvcnQ9
bXNpIDs7IFNBTVNVTkcqKSBzaG9ydD1zYW1zdW5nIDs7IEZSQU1FV09SSyopIHNob3J0PWZyYW1l
d29yayA7OwogICAgIiIpIHNob3J0PXVua25vd24gOzsgKikgc2hvcnQ9b3RoZXIgOzsKICBlc2Fj
CiAgZWNobyAiZG1pX3ZlbmRvcj0kdmVuZG9yIgogIGVjaG8gImRtaV9tYWtlcj0kc2hvcnQiCiAg
ZWNobyAiZG1pX3Byb2R1Y3Q9JHByb2R1Y3QiCiAgZWNobyAiZG1pX2ZhbWlseT0kZmFtaWx5Igog
IGVjaG8gImRtaV92ZXJzaW9uPSR2ZXJzaW9uIgogIGVjaG8gImRtaV9jaGFzc2lzX3R5cGU9JGN0
IgogIGVjaG8gImRtaV9jaGFzc2lzPSRraW5kIgp9CgojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0gUENJIGhlbHBlcnMKIyBf
aHdfcGNpIENMQVNTUFJFRklYICAtPiAgInNsb3QgdmVuZG9yIGRldmljZSBjbGFzcyBib290X3Zn
YSIgcGVyIG1hdGNoaW5nIGRldmljZSAoaGV4LCBubyAweCkKX2h3X3BjaSgpIHsKICBsb2NhbCBk
IGNscyB2IGRldiBidgogIGZvciBkIGluICIkSFdfUk9PVCIvc3lzL2J1cy9wY2kvZGV2aWNlcy8q
OyBkbwogICAgWyAtciAiJGQvY2xhc3MiIF0gfHwgY29udGludWUKICAgIGNscz0kKHRyICdBLUYn
ICdhLWYnIDwgIiRkL2NsYXNzIik7IGNscz0ke2NscyMweH07IGNscz0ke2NscyUlW1s6c3BhY2U6
XV0qfQogICAgY2FzZSAiJGNscyIgaW4gIiQxIiopIDs7ICopIGNvbnRpbnVlIDs7IGVzYWMKICAg
IHY9JCh0ciAnQS1GJyAnYS1mJyA8ICIkZC92ZW5kb3IiIDI+L2Rldi9udWxsKTsgdj0ke3YjMHh9
OyB2PSR7diUlW1s6c3BhY2U6XV0qfQogICAgZGV2PSQodHIgJ0EtRicgJ2EtZicgPCAiJGQvZGV2
aWNlIiAyPi9kZXYvbnVsbCk7IGRldj0ke2RldiMweH07IGRldj0ke2RldiUlW1s6c3BhY2U6XV0q
fQogICAgYnY9JChjYXQgIiRkL2Jvb3RfdmdhIiAyPi9kZXYvbnVsbCk7IGJ2PSR7YnYlJVtbOnNw
YWNlOl1dKn0KICAgIHByaW50ZiAnJXMgJXMgJXMgJXMgJXNcbicgIiR7ZCMjKi99IiAiJHYiICIk
ZGV2IiAiJGNscyIgIiR7YnY6LTB9IgogIGRvbmUKfQpfaHdfcGNpX2hhcygpIHsgICAjIF9od19w
Y2lfaGFzIFZFTkRPUiBERVZJQ0UKICBsb2NhbCBkIHYgZGV2CiAgZm9yIGQgaW4gIiRIV19ST09U
Ii9zeXMvYnVzL3BjaS9kZXZpY2VzLyo7IGRvCiAgICBbIC1yICIkZC92ZW5kb3IiIF0gfHwgY29u
dGludWUKICAgIHY9JCh0ciAnQS1GJyAnYS1mJyA8ICIkZC92ZW5kb3IiKTsgdj0ke3YjMHh9OyB2
PSR7diUlW1s6c3BhY2U6XV0qfQogICAgZGV2PSQodHIgJ0EtRicgJ2EtZicgPCAiJGQvZGV2aWNl
IiAyPi9kZXYvbnVsbCk7IGRldj0ke2RldiMweH07IGRldj0ke2RldiUlW1s6c3BhY2U6XV0qfQog
ICAgWyAiJHYiID0gIiQxIiBdICYmIFsgIiRkZXYiID0gIiQyIiBdICYmIHJldHVybiAwCiAgZG9u
ZQogIHJldHVybiAxCn0KCiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLSBNYWNzCiMgVDIgPSBBcHBsZSBQQ0kgMTA2YjoxODAx
IChUMiBicmlkZ2UgLyBCQ0UsIGRyaXZlbiBieSB0aGUgb3V0LW9mLXRyZWUgYXBwbGUtYmNlIGRy
aXZlcikgYW5kIDEwNmI6MTgwMgojIChUMiBTZWN1cmUgRW5jbGF2ZSkuIFRoZSBtb2RlbCB0YWJs
ZSBiZWxvdyBjYXRjaGVzIFQyIE1hY3Mgd2hvc2UgQkNFIGlzIGhpZGRlbi4KX2h3X3QyX21vZGVs
KCkgewogIGNhc2UgIiQxIiBpbgogICAgTWFjQm9va1BybzE1LCp8TWFjQm9va1BybzE2LCp8TWFj
Qm9va0FpcjgsKnxNYWNCb29rQWlyOSwxfE1hY21pbmk4LDF8aU1hYzIwLCp8aU1hY1BybzEsMXxN
YWNQcm83LDEpIHJldHVybiAwIDs7CiAgZXNhYwogIHJldHVybiAxCn0KaHdfbWFjKCkgewogIGxv
Y2FsIHZlbmRvciBwcm9kdWN0IGFyY2ggY29tcGF0IGtpbmQ9bm9uZSB0Mj1ubyBmdGg9bm8KICB2
ZW5kb3I9JChfaHdfcmVhZCAvc3lzL2NsYXNzL2RtaS9pZC9zeXNfdmVuZG9yKQogIHByb2R1Y3Q9
JChfaHdfcmVhZCAvc3lzL2NsYXNzL2RtaS9pZC9wcm9kdWN0X25hbWUpCiAgYXJjaD0kKGh3X2Fy
Y2gpCiAgY29tcGF0PSIiOyBbIC1yICIkSFdfUk9PVC9wcm9jL2RldmljZS10cmVlL2NvbXBhdGli
bGUiIF0gJiYgY29tcGF0PSQodHIgJ1wwJyAnICcgPCAiJEhXX1JPT1QvcHJvYy9kZXZpY2UtdHJl
ZS9jb21wYXRpYmxlIikKICBjYXNlICIkYXJjaDokY29tcGF0IiBpbgogICAgYWFyY2g2NDoqYXBw
bGUsKikga2luZD1hcHBsZS1zaWxpY29uOyBwcm9kdWN0PSQoX2h3X3JlYWQgL3Byb2MvZGV2aWNl
LXRyZWUvbW9kZWwpIDs7CiAgZXNhYwogIGlmIFsgIiRraW5kIiA9IG5vbmUgXTsgdGhlbgogICAg
Y2FzZSAiJHZlbmRvciIgaW4KICAgICAgQXBwbGUqKQogICAgICAgIGlmIF9od19wY2lfaGFzIDEw
NmIgMTgwMSB8fCBfaHdfcGNpX2hhcyAxMDZiIDE4MDIgfHwgX2h3X3QyX21vZGVsICIkcHJvZHVj
dCI7IHRoZW4ga2luZD1pbnRlbC10MjsgdDI9eWVzCiAgICAgICAgZWxzZSBraW5kPWludGVsOyBm
aSA7OwogICAgZXNhYwogIGZpCiAgIyBGYWNlVGltZSBIRCAoUENJZSwgQnJvYWRjb20gMTRlNDox
NTcwKTogTWFjQm9va3MgfjIwMTMtMjAxNy4gTmVlZHMgdGhlIG91dC1vZi10cmVlIGZhY2V0aW1l
aGQgZHJpdmVyLgogIFsgIiRraW5kIiA9IGludGVsIF0gJiYgX2h3X3BjaV9oYXMgMTRlNCAxNTcw
ICYmIGZ0aD15ZXMKICBsb2NhbCBpcz1ubzsgWyAiJGtpbmQiICE9IG5vbmUgXSAmJiBpcz15ZXMK
ICBlY2hvICJpc19tYWM9JGlzIgogIGVjaG8gIm1hY19raW5kPSRraW5kIgogIGVjaG8gIm1hY19t
b2RlbD0kKCBbICIkaXMiID0geWVzIF0gJiYgcHJpbnRmICclcycgIiRwcm9kdWN0IikiCiAgZWNo
byAibWFjX3QyPSR0MiIKICBlY2hvICJtYWNfZmFjZXRpbWVoZD0kZnRoIgp9CgojIC0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0g
TlZJRElBIGdlbmVyYXRpb25zIChieSBQQ0kgZGV2aWNlIGlkKQojIEJlc3QgZWZmb3J0LCBmcm9t
IE5WSURJQSdzIGRldmljZS1pZCByYW5nZXMgKGVhY2ggY2hpcCBmYW1pbHkgZ290IGl0cyBvd24g
YmxvY2sgb2YgaWRzKToKIyAgID49IDB4MWUwMCAgICAgICAgICAgIFR1cmluZyAoR1RYIDE2IC8g
UlRYIDIwKSBhbmQgbmV3ZXI6IEFtcGVyZSwgQWRhLCBIb3BwZXIsIEJsYWNrd2VsbCAtPiBha21v
ZC1udmlkaWEKIyAgIDB4MTM0MCAuLiAweDFkZmYgICAgIE1heHdlbGwgKEdUWCA3NTAvOTAwKSwg
UGFzY2FsIChHVFggMTApLCBWb2x0YSAtPiBha21vZC1udmlkaWEtNTgweHggKGxhc3QgYnJhbmNo
IGZvciB0aGVtKQojICAgPCAgMHgxMzQwICAgICAgICAgICAgS2VwbGVyIChHVFggNjAwLzcwMCks
IEZlcm1pICg0MDAvNTAwKSwgVGVzbGEgKDgvOS8yMDAvMzAwKSBhbmQgb2xkZXIgLT4gbm91dmVh
dQojIFRoZSBhdXRob3JpdGF0aXZlIGxpc3QgaXMgc3VwcG9ydGVkLWdwdXMuanNvbiBpbiBOVklE
SUEncyBkcml2ZXIgUkVBRE1FOyBlZGdlIGNhc2VzIGFyZSBsaXN0ZWQgaW4gaHdfbnZpZGlhX2Zh
bWlseS4KaHdfbnZpZGlhX2NsYXNzKCkgeyAgICMgaHdfbnZpZGlhX2NsYXNzIERFVklDRUlEKGhl
eCkgLT4gbW9kZXJuIHwgNTgweHggfCBsZWdhY3kKICBsb2NhbCBkPSQoKDE2IyR7MTotMH0pKQog
IGlmIFsgJGQgLWdlICQoKDE2IzFlMDApKSBdOyB0aGVuIGVjaG8gbW9kZXJuCiAgZWxpZiBbICRk
IC1nZSAkKCgxNiMxMzQwKSkgXTsgdGhlbiBlY2hvIDU4MHh4CiAgZWxzZSBlY2hvIGxlZ2FjeTsg
ZmkKfQpod19udmlkaWFfZmFtaWx5KCkgeyAgIyBod19udmlkaWFfZmFtaWx5IERFVklDRUlEKGhl
eCkgLT4gY2hpcCBmYW1pbHkgbmFtZSAoZm9yIG1lc3NhZ2VzKQogIGxvY2FsIGQ9JCgoMTYjJHsx
Oi0wfSkpCiAgaWYgICBbICRkIC1nZSAkKCgxNiMyYjgwKSkgXSAmJiBbICRkIC1sZSAkKCgxNiMy
ZmZmKSkgXTsgdGhlbiBlY2hvIEJsYWNrd2VsbAogIGVsaWYgWyAkZCAtZ2UgJCgoMTYjMjY4MCkp
IF0gJiYgWyAkZCAtbGUgJCgoMTYjMjhmZikpIF07IHRoZW4gZWNobyAiQWRhIExvdmVsYWNlIgog
IGVsaWYgWyAkZCAtZ2UgJCgoMTYjMjMwMCkpIF0gJiYgWyAkZCAtbGUgJCgoMTYjMjMzZikpIF07
IHRoZW4gZWNobyBIb3BwZXIKICBlbGlmIFsgJGQgLWdlICQoKDE2IzIwODApKSBdICYmIFsgJGQg
LWxlICQoKDE2IzI1ZmYpKSBdOyB0aGVuIGVjaG8gQW1wZXJlCiAgZWxpZiBbICRkIC1nZSAkKCgx
NiMxZTAwKSkgXSAmJiBbICRkIC1sZSAkKCgxNiMyMWZmKSkgXTsgdGhlbiBlY2hvIFR1cmluZwog
IGVsaWYgWyAkZCAtZ2UgJCgoMTYjMWUwMCkpIF07IHRoZW4gZWNobyAiVHVyaW5nIG9yIG5ld2Vy
IgogIGVsaWYgWyAkZCAtZ2UgJCgoMTYjMWQ4MCkpIF07IHRoZW4gZWNobyBWb2x0YQogIGVsaWYg
WyAkZCAtZ2UgJCgoMTYjMWIwMCkpIF0gfHwgeyBbICRkIC1nZSAkKCgxNiMxNWYwKSkgXSAmJiBb
ICRkIC1sZSAkKCgxNiMxNWZmKSkgXTsgfTsgdGhlbiBlY2hvIFBhc2NhbAogIGVsaWYgWyAkZCAt
Z2UgJCgoMTYjMTM0MCkpIF07IHRoZW4gZWNobyBNYXh3ZWxsCiAgZWxpZiB7IFsgJGQgLWdlICQo
KDE2IzBmYzApKSBdICYmIFsgJGQgLWxlICQoKDE2IzEwM2YpKSBdOyB9IHx8IHsgWyAkZCAtZ2Ug
JCgoMTYjMTE4MCkpIF0gJiYgWyAkZCAtbGUgJCgoMTYjMTFmZikpIF07IH0gXAogICAgICAgfHwg
eyBbICRkIC1nZSAkKCgxNiMxMjgwKSkgXSAmJiBbICRkIC1sZSAkKCgxNiMxMmZmKSkgXTsgfTsg
dGhlbiBlY2hvIEtlcGxlcgogIGVsaWYgWyAkZCAtZ2UgJCgoMTYjMTE0MCkpIF0gJiYgWyAkZCAt
bGUgJCgoMTYjMTE3ZikpIF07IHRoZW4gZWNobyAiRmVybWkvS2VwbGVyIgogIGVsaWYgeyBbICRk
IC1nZSAkKCgxNiMwNmMwKSkgXSAmJiBbICRkIC1sZSAkKCgxNiMwNmRmKSkgXTsgfSB8fCB7IFsg
JGQgLWdlICQoKDE2IzBkYzApKSBdICYmIFsgJGQgLWxlICQoKDE2IzBkZmYpKSBdOyB9IFwKICAg
ICAgIHx8IHsgWyAkZCAtZ2UgJCgoMTYjMGUyMCkpIF0gJiYgWyAkZCAtbGUgJCgoMTYjMGUzZikp
IF07IH0gfHwgeyBbICRkIC1nZSAkKCgxNiMwZjAwKSkgXSAmJiBbICRkIC1sZSAkKCgxNiMwZjNm
KSkgXTsgfSBcCiAgICAgICB8fCB7IFsgJGQgLWdlICQoKDE2IzEwNDApKSBdICYmIFsgJGQgLWxl
ICQoKDE2IzEwYmYpKSBdOyB9IHx8IHsgWyAkZCAtZ2UgJCgoMTYjMTIwMCkpIF0gJiYgWyAkZCAt
bGUgJCgoMTYjMTI3ZikpIF07IH07IHRoZW4gZWNobyBGZXJtaQogIGVsc2UgZWNobyAiVGVzbGEg
b3Igb2xkZXIiOyBmaQp9CgojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0gZ3JhcGhpY3MKaHdfZ3B1cygpIHsKICBsb2NhbCBu
PTAgbnY9bm8gbnZpZD0iIiBudmNsYXNzPW5vbmUgbnZmYW09IiIgYW1kPW5vIGludGVsPW5vIG90
aGVyPW5vIHNsb3QgdiBkZXYgY2xzIGJ2IG5hbWVzPSIiCiAgd2hpbGUgcmVhZCAtciBzbG90IHYg
ZGV2IGNscyBidjsgZG8KICAgIFsgLW4gIiRzbG90IiBdIHx8IGNvbnRpbnVlCiAgICBuPSQoKG4g
KyAxKSkKICAgIGVjaG8gImdwdV8kbj0kdjokZGV2OiRjbHM6JHNsb3Q6JGJ2IgogICAgY2FzZSAi
JHYiIGluCiAgICAgIDEwZGUpIG52PXllczsgWyAteiAiJG52aWQiIF0gJiYgbnZpZD0kZGV2IDs7
CiAgICAgIDEwMDIpIGFtZD15ZXMgOzsKICAgICAgODA4NikgaW50ZWw9eWVzIDs7CiAgICAgICop
IG90aGVyPXllcyA7OwogICAgZXNhYwogIGRvbmUgPCA8KF9od19wY2kgMDMpCiAgaWYgWyAtbiAi
JG52aWQiIF07IHRoZW4gbnZjbGFzcz0kKGh3X252aWRpYV9jbGFzcyAiJG52aWQiKTsgbnZmYW09
JChod19udmlkaWFfZmFtaWx5ICIkbnZpZCIpOyBmaQogIGxvY2FsIGh5YnJpZD1ubwogIFsgJG4g
LWdlIDIgXSAmJiBoeWJyaWQ9eWVzCiAgZWNobyAiZ3B1X2NvdW50PSRuIgogIGVjaG8gImdwdV9u
dmlkaWE9JG52IgogIGVjaG8gImdwdV9hbWQ9JGFtZCIKICBlY2hvICJncHVfaW50ZWw9JGludGVs
IgogIGVjaG8gImdwdV9vdGhlcj0kb3RoZXIiCiAgZWNobyAibnZpZGlhX2lkPSRudmlkIgogIGVj
aG8gIm52aWRpYV9jbGFzcz0kbnZjbGFzcyIKICBlY2hvICJudmlkaWFfZmFtaWx5PSRudmZhbSIK
ICBlY2hvICJncHVfbXVsdGk9JGh5YnJpZCIKfQoKIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tIFdpLUZpCiMgQnJvYWRjb206
IHdoaWNoIGRyaXZlciBhIGNoaXAgbmVlZHMgKFZFUklGWSBsaXN0IGFnYWluc3QgdGhlIEFyY2gg
d2lraSAiQnJvYWRjb20gd2lyZWxlc3MiIHRhYmxlKS4KIyAgIGJ1aWx0aW4gIGJyY21mbWFjL2Jy
Y21zbWFjIGluIHRoZSBGZWRvcmEga2VybmVsICsgbGludXgtZmlybXdhcmU6IG5vdGhpbmcgdG8g
aW5zdGFsbAojICAgd2wgICAgICAgQnJvYWRjb20ncyBvd24gZHJpdmVyOiBha21vZC13bCAoUlBN
IEZ1c2lvbiBub25mcmVlKQojICAgYjQzICAgICAgb25seSB0aGUgb2xkIGI0MyBkcml2ZXIgd29y
a3M6IGZpcm13YXJlIG11c3QgYmUgY3V0IHdpdGggYjQzLWZ3Y3V0dGVyIChtYW51YWwpCmh3X2Jy
b2FkY29tX2RyaXZlcigpIHsKICBjYXNlICIkMSIgaW4KICAgIDQzYTN8NDNiYXw0M2JifDQzYmN8
NDNlY3w0M2RjfDQ0NjR8NDQ4OHw0NDI1fDQ0MzN8NDQxNXw0M2VmfDQzNTR8NDM1NSkgZWNobyBi
dWlsdGluIDs7ICAgIyBicmNtZm1hYwogICAgNDM1N3w0NzI3fDQzNTMpIGVjaG8gYnVpbHRpbiA7
OyAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgIyBicmNtc21hYyAoNDMyMjUsIDQzMTMsIDQzMjI0KQogICAgNDMxMXw0MzEyfDQzMTV8NDMy
OHw0MzI5fDQzMmF8NDMyYnw0MzJjfDQzMmR8NDMzMXw0MzU4fDQzNTl8NDM2MHw0MzY1fDQzYTB8
NDNiMXw0M2IyKSBlY2hvIHdsIDs7CiAgICA0MzAxfDQzMDZ8NDMwN3w0MzE4fDQzMTl8NDMyMHw0
MzI0fDQzMjUpIGVjaG8gYjQzIDs7CiAgICAqKSBlY2hvIHVua25vd24gOzsKICBlc2FjCn0KaHdf
d2lmaSgpIHsKICBsb2NhbCBuPTAgc2xvdCB2IGRldiBjbHMgYnYga2luZD0iIiBiZHJ2PW5vbmUg
bmVlZHM9bm8gaWRzPSIiCiAgd2hpbGUgcmVhZCAtciBzbG90IHYgZGV2IGNscyBidjsgZG8KICAg
IFsgLW4gIiRzbG90IiBdIHx8IGNvbnRpbnVlCiAgICBuPSQoKG4gKyAxKSk7IGlkcz0iJGlkcyAk
djokZGV2IgogICAgZWNobyAid2lmaV8kbj0kdjokZGV2IgogICAgY2FzZSAiJHYiIGluCiAgICAg
IDE0ZTQpIGtpbmQ9JHtraW5kOi1icm9hZGNvbX07IGJkcnY9JChod19icm9hZGNvbV9kcml2ZXIg
IiRkZXYiKTsgY2FzZSAiJGJkcnYiIGluIHdsfGI0M3x1bmtub3duKSBuZWVkcz15ZXMgOzsgZXNh
YyA7OwogICAgICA4MDg2KSBraW5kPSR7a2luZDotaW50ZWx9IDs7CiAgICAgIDE0YzMpIGtpbmQ9
JHtraW5kOi1tZWRpYXRla30gOzsKICAgICAgMTBlYykga2luZD0ke2tpbmQ6LXJlYWx0ZWt9IDs7
CiAgICAgIDE2OGN8MTdjYikga2luZD0ke2tpbmQ6LWF0aGVyb3N9IDs7CiAgICAgICopIGtpbmQ9
JHtraW5kOi1vdGhlcn0gOzsKICAgIGVzYWMKICBkb25lIDwgPChfaHdfcGNpIDAyODApCiAgIyBX
aS1GaSB0aGF0IGlzbid0IG9uIFBDSSAoVVNCIGFkYXB0ZXJzLCBTRElPKTogb25seSB2aXNpYmxl
IG9uY2UgYSBkcml2ZXIgaXMgbG9hZGVkCiAgbG9jYWwgdyBub25wY2k9bm8KICBmb3IgdyBpbiAi
JEhXX1JPT1QiL3N5cy9jbGFzcy9uZXQvKi93aXJlbGVzczsgZG8gWyAtZCAiJHciIF0gJiYgbm9u
cGNpPXllczsgZG9uZQogIFsgJG4gLWVxIDAgXSAmJiBbICIkbm9ucGNpIiA9IHllcyBdICYmIGtp
bmQ9b3RoZXIKICBlY2hvICJ3aWZpX2NvdW50PSRuIgogIGVjaG8gIndpZmlfdmVuZG9yPSR7a2lu
ZDotbm9uZX0iCiAgZWNobyAid2lmaV9icm9hZGNvbV9kcml2ZXI9JGJkcnYiCiAgZWNobyAid2lm
aV9uZWVkc19kcml2ZXI9JG5lZWRzIgogIGVjaG8gIndpZmlfaWRzPSR7aWRzIyB9Igp9CgojIC0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0gd2lyZWQgbmV0d29yawpod19ldGhlcm5ldCgpIHsKICBsb2NhbCBuPTAgc2xvdCB2IGRl
diBjbHMgYnYga2luZD0iIgogIHdoaWxlIHJlYWQgLXIgc2xvdCB2IGRldiBjbHMgYnY7IGRvCiAg
ICBbIC1uICIkc2xvdCIgXSB8fCBjb250aW51ZQogICAgbj0kKChuICsgMSkpCiAgICBjYXNlICIk
diIgaW4gMTBlYykga2luZD0ke2tpbmQ6LXJlYWx0ZWt9IDs7IDgwODYpIGtpbmQ9JHtraW5kOi1p
bnRlbH0gOzsgMTRlNCkga2luZD0ke2tpbmQ6LWJyb2FkY29tfSA7OyAxOTY5KSBraW5kPSR7a2lu
ZDotYXRoZXJvc30gOzsgKikga2luZD0ke2tpbmQ6LW90aGVyfSA7OyBlc2FjCiAgZG9uZSA8IDwo
X2h3X3BjaSAwMjAwKQogIGVjaG8gImV0aF9jb3VudD0kbiIKICBlY2hvICJldGhfdmVuZG9yPSR7
a2luZDotbm9uZX0iCn0KCiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLSBkcml2ZXMKaHdfc3RvcmFnZSgpIHsKICBsb2NhbCBk
IG49MCBuYW1lIHJvdCBraW5kIHNpemUgZ2IgbnZtZT1ubyBzc2Q9bm8gaGRkPW5vCiAgZm9yIGQg
aW4gIiRIV19ST09UIi9zeXMvYmxvY2svKjsgZG8KICAgIFsgLWQgIiRkIiBdIHx8IGNvbnRpbnVl
CiAgICBuYW1lPSR7ZCMjKi99CiAgICBjYXNlICIkbmFtZSIgaW4gbG9vcCp8cmFtKnx6cmFtKnxz
cip8ZmQqfGRtLSp8bWQqfG5iZCp8bW1jYmxrKmJvb3QqfG1tY2JsaypycG1iKSBjb250aW51ZSA7
OyBlc2FjCiAgICBbICIkKF9od19yZWFkICIvc3lzL2Jsb2NrLyRuYW1lL3JlbW92YWJsZSIpIiA9
IDEgXSAmJiBjb250aW51ZQogICAgcmVhZGxpbmsgLWYgIiRkL2RldmljZSIgMj4vZGV2L251bGwg
fCBncmVwIC1xICcvdXNiJyAmJiBjb250aW51ZQogICAgc2l6ZT0kKF9od19yZWFkICIvc3lzL2Js
b2NrLyRuYW1lL3NpemUiKTsgc2l6ZT0ke3NpemU6LTB9CiAgICBnYj0kKChzaXplIC8gMjA5NzE1
MikpCiAgICBbICIkZ2IiIC1nZSAxIF0gfHwgY29udGludWUKICAgIHJvdD0kKF9od19yZWFkICIv
c3lzL2Jsb2NrLyRuYW1lL3F1ZXVlL3JvdGF0aW9uYWwiKQogICAgY2FzZSAiJG5hbWUiIGluCiAg
ICAgIG52bWUqKSBraW5kPW52bWU7IG52bWU9eWVzIDs7CiAgICAgIG1tY2JsayopIGtpbmQ9ZW1t
YyA7OwogICAgICAqKSBpZiBbICIkcm90IiA9IDEgXTsgdGhlbiBraW5kPWhkZDsgaGRkPXllczsg
ZWxzZSBraW5kPXNzZDsgc3NkPXllczsgZmkgOzsKICAgIGVzYWMKICAgIG49JCgobiArIDEpKQog
ICAgZWNobyAiZGlza18kbj0kbmFtZToka2luZDokZ2IiCiAgZG9uZQogIGVjaG8gImRpc2tfY291
bnQ9JG4iCiAgZWNobyAiZGlza19udm1lPSRudm1lIgogIGVjaG8gImRpc2tfc3NkPSRzc2QiCiAg
ZWNobyAiZGlza19oZGQ9JGhkZCIKfQoKIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tIGJhdHRlcnkKaHdfYmF0dGVyeSgpIHsK
ICBsb2NhbCBwIGhhcz1ubwogIGZvciBwIGluICIkSFdfUk9PVCIvc3lzL2NsYXNzL3Bvd2VyX3N1
cHBseS8qOyBkbwogICAgWyAiJChfaHdfcmVhZCAiL3N5cy9jbGFzcy9wb3dlcl9zdXBwbHkvJHtw
IyMqL30vdHlwZSIpIiA9IEJhdHRlcnkgXSB8fCBjb250aW51ZQogICAgWyAiJChfaHdfcmVhZCAi
L3N5cy9jbGFzcy9wb3dlcl9zdXBwbHkvJHtwIyMqL30vc2NvcGUiKSIgPSBEZXZpY2UgXSAmJiBj
b250aW51ZSAgICMgbW91c2UgLyBrZXlib2FyZCBiYXR0ZXJpZXMKICAgIGhhcz15ZXMKICBkb25l
CiAgZWNobyAiYmF0dGVyeT0kaGFzIgp9CgojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0gZXZlcnl0aGluZwpod19hbGwoKSB7
CiAgaHdfY3B1OyBod19yYW07IGh3X2Zpcm13YXJlOyBod19kbWk7IGh3X21hYzsgaHdfZ3B1czsg
aHdfd2lmaTsgaHdfZXRoZXJuZXQ7IGh3X3N0b3JhZ2U7IGh3X2JhdHRlcnkKICAjIEEgbGFwdG9w
IChiYXR0ZXJ5IG9yIGxhcHRvcCBjaGFzc2lzKSB3aXRoIHR3byBncmFwaGljcyBjaGlwcyA9IHN3
aXRjaGFibGUgLyBoeWJyaWQgZ3JhcGhpY3MgKE9wdGltdXMgZXRjLikKICBsb2NhbCBtdWx0aSBi
YXQgY2gKICBtdWx0aT0kKGh3X2dwdXMgfCBzZWQgLW4gJ3MvXmdwdV9tdWx0aT0vL3AnKTsgYmF0
PSQoaHdfYmF0dGVyeSB8IHNlZCAtbiAncy9eYmF0dGVyeT0vL3AnKTsgY2g9JChod19kbWkgfCBz
ZWQgLW4gJ3MvXmRtaV9jaGFzc2lzPS8vcCcpCiAgaWYgWyAiJG11bHRpIiA9IHllcyBdICYmIHsg
WyAiJGJhdCIgPSB5ZXMgXSB8fCBbICIkY2giID0gbGFwdG9wIF07IH07IHRoZW4gZWNobyAiaHli
cmlkPXllcyI7IGVsc2UgZWNobyAiaHlicmlkPW5vIjsgZmkKfQoKSFdfQ0FDSEU9IiIKaHdfZ2V0
KCkgeyAgICMgaHdfZ2V0IEtFWSAgIChydW5zIGh3X2FsbCBvbmNlIHBlciBzaGVsbCkKICBbIC1u
ICIkSFdfQ0FDSEUiIF0gfHwgSFdfQ0FDSEU9JChod19hbGwpCiAgcHJpbnRmICclc1xuJyAiJEhX
X0NBQ0hFIiB8IHNlZCAtbiAicy9eJDE9Ly9wIiB8IGhlYWQgLW4xCn0KCiMgUnVuIGRpcmVjdGx5
OiBwcmludCBldmVyeXRoaW5nCiMgKGNvbXBhdC1jaGVjay5zaCBjYXJyaWVzIGEgdmVyYmF0aW0g
Y29weSBvZiB0aGlzIGZpbGUgYW5kIHNldHMgSFdfRU1CRURERUQ9MSkKaWYgWyAiJHtCQVNIX1NP
VVJDRVswXX0iID0gIiQwIiBdICYmIFsgLXogIiR7SFdfRU1CRURERUQ6LX0iIF07IHRoZW4KICB3
aGlsZSBbICQjIC1ndCAwIF07IGRvCiAgICBjYXNlICIkMSIgaW4KICAgICAgLS1maXh0dXJlKSBI
V19ST09UPSR7MiUvfTsgc2hpZnQgOzsKICAgICAgLWh8LS1oZWxwKSBzZWQgLW4gJzIsMTVwJyAi
JDAiOyBleGl0IDAgOzsKICAgIGVzYWMKICAgIHNoaWZ0CiAgZG9uZQogIGh3X2FsbApmaQojID09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09IEVORCBkZXRlY3Quc2gKCmRlY2xhcmUgLUEgSAp3aGlsZSBJRlM9Jz0nIHJl
YWQgLXIgayB2OyBkbyBbIC1uICIkayIgXSAmJiBIWyRrXT0kdjsgZG9uZSA8IDwoaHdfYWxsKQpn
KCkgeyBwcmludGYgJyVzJyAiJHtIWyQxXTotfSI7IH0KCmlmIFsgJEFTQ0lJID0gMSBdOyB0aGVu
IFNfT0s9J1sgT0sgXSc7IFNfTk9URT0nW05PVEVdJzsgU19OTz0nWyBOTyBdJzsgU19JTkZPPSdb
SU5GT10nCmVsc2UgU19PSz0n4pyTJzsgU19OT1RFPSfimqAnOyBTX05PPSfinJcnOyBTX0lORk89
J+KAoic7IGZpCgpMSU5FUz0oKSBOT1RFUz0wIEJMT0NLRVJTPTAgQkxPQ0tFUl9URVhUPSIiIEFT
Sz0wIFdJUkVEPTAgQVNBSEk9MCBURVhUPTAgUFJPRklMRT1mdWxsIFdIWT0iIgpfYWRkKCkgeyAg
ICMgX2FkZCBva3xub3RlfG5vfGluZm8gImZpcnN0IGxpbmUiIFsibW9yZSBsaW5lcyIuLi5dCiAg
bG9jYWwga2luZD0kMSBzeW0gbDsgc2hpZnQKICBjYXNlICIka2luZCIgaW4gb2spIHN5bT0kU19P
SyA7OyBub3RlKSBzeW09JFNfTk9URTsgTk9URVM9JCgoTk9URVMgKyAxKSkgOzsgbm8pIHN5bT0k
U19OTzsgQkxPQ0tFUlM9JCgoQkxPQ0tFUlMgKyAxKSkgOzsgKikgc3ltPSRTX0lORk8gOzsgZXNh
YwogIFsgIiRraW5kIiA9IG5vIF0gJiYgQkxPQ0tFUl9URVhUPSIke0JMT0NLRVJfVEVYVDorJEJM
T0NLRVJfVEVYVDsgfSQxIgogIGlmIFsgJEJSSUVGID0gMSBdICYmIHsgWyAiJGtpbmQiID0gb2sg
XSB8fCBbICIka2luZCIgPSBpbmZvIF07IH07IHRoZW4gcmV0dXJuIDA7IGZpCiAgTElORVMrPSgi
ICAkc3ltICQxIikKICBzaGlmdAogIGZvciBsIGluICIkQCI7IGRvIExJTkVTKz0oIiAgICAgICRs
Iik7IGRvbmUKfQoKQVJDSD0kKGcgY3B1X2FyY2gpIE1BQ0s9JChnIG1hY19raW5kKSBTQj0kKGcg
c2VjdXJlX2Jvb3QpIFJBTT0kKGcgcmFtX21iKSBMRVZFTD0kKGcgY3B1X3g4Nl9sZXZlbCkKTUFL
RVI9JChnIGRtaV9tYWtlcikgUFJPRFVDVD0kKGcgZG1pX3Byb2R1Y3QpIEZBTUlMWT0kKGcgZG1p
X2ZhbWlseSkKUkFNPSR7UkFNOi0wfTsgTEVWRUw9JHtMRVZFTDotMH0KUkFNX0dCPSQoYXdrIC12
IG09IiRSQU0iICdCRUdJTiB7IHByaW50ZiAiJS4xZiIsIG0gLyAxMDI0IH0nKQpDUFVGTEFHUz0i
ICQoYXdrIC1GJzogKicgJy9eZmxhZ3Mve3ByaW50ICQyOyBleGl0fScgIiRIV19ST09UL3Byb2Mv
Y3B1aW5mbyIgMj4vZGV2L251bGwpICIKTkVFRFNfS0VZPTAgICAjIGEgZHJpdmVyIGJ1aWx0IG9u
IHRoaXMgY29tcHV0ZXIgKE5WSURJQSwgQnJvYWRjb20gd2wpICsgU2VjdXJlIEJvb3Qgb24gPSBh
cHByb3ZlIGEga2V5IG9uY2UKCiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLSB3aGljaCBMaW51eCAoSFdfRElTVFJPKQojIEZl
ZG9yYSA0NC80NSB4ODZfNjQgcnVucyBvbiBhbnkgNjQtYml0IHg4NiBDUFUgKGJhc2VsaW5lIHg4
Ni02NC12MSkgd2l0aCAyIEdCKy4gQmVsb3cgdGhhdCwgRGViaWFuLgojIE1lbW9yeSBiYW5kcyAo
a2VybmVsLXZpc2libGUgTUIsIHdpdGggbWFyZ2lucyBiZWNhdXNlIHNoYXJlZC1HUFUgbWFjaGlu
ZXMgdW5kZXItcmVwb3J0KToKIyB1bmRlciA0ODA6IHVuc3VwcG9ydGVkOyA0ODAtMTY5OTogZGVi
aWFuLWxpdGU7IDE3MDAtMjk5OTogZmVkb3JhLW1pbiAoRmVkb3JhLCBsaWdodCBMWFF0IGRlc2t0
b3ApOwojIDMwMDArOiBmZWRvcmEgKHRoZSBkZXNrdG9wIHRpZXIsIGZ1bGwgb3IgbGl0ZSwgaXMg
Y2hvc2VuIHNlcGFyYXRlbHkgYmVsb3cpLgojIERlYmlhbiAxMyBoYXMgbm8gMzItYml0IFBDIChp
Mzg2KSBpbnN0YWxsZXIgb3Iga2VybmVsOyBEZWJpYW4gMTIgaTM4NiBoYXMgTFRTIHVudGlsIDMw
IEp1bmUgMjAyOC4KRElTVFJPPWZlZG9yYSBSRUFTT049IjY0LWJpdCBJbnRlbC9BTUQgUEMgd2l0
aCAke1JBTV9HQn0gR0IgbWVtb3J5OiBGZWRvcmEsIHRoZSBub3JtYWwgcGF0aCIKY2FzZSAiJEFS
Q0giIGluCiAgYWFyY2g2NHxhcm02NHxhcm0qKQogICAgaWYgWyAiJE1BQ0siID0gYXBwbGUtc2ls
aWNvbiBdOyB0aGVuIERJU1RSTz1hc2FoaTsgUkVBU09OPSJBcHBsZSBTaWxpY29uIE1hYzogRmVk
b3JhIEFzYWhpIFJlbWl4LCBpbnN0YWxsZWQgZnJvbSBtYWNPUyIKICAgIGVsc2UgRElTVFJPPXVu
c3VwcG9ydGVkOyBSRUFTT049IkFSTSBjb21wdXRlciB0aGF0IGlzIG5vdCBhbiBBcHBsZSBTaWxp
Y29uIE1hYyI7IGZpIDs7CiAgKikKICAgIGlmIFsgIiQoZyBjcHVfNjRiaXQpIiA9IHllcyBdOyB0
aGVuCiAgICAgIGlmIFsgIiRSQU0iIC1sdCA0ODAgXTsgdGhlbiBESVNUUk89dW5zdXBwb3J0ZWQ7
IFJFQVNPTj0ib25seSAke1JBTV9HQn0gR0IgbWVtb3J5OiBiZWxvdyB3aGF0IGFueSBjdXJyZW50
IGRlc2t0b3AgTGludXggbmVlZHMgKDUxMiBNQikiCiAgICAgIGVsaWYgWyAiJFJBTSIgLWx0IDE3
MDAgXTsgdGhlbiBESVNUUk89ZGViaWFuLWxpdGU7IFJFQVNPTj0iNjQtYml0IFBDIHdpdGggb25s
eSAke1JBTV9HQn0gR0IgbWVtb3J5OiBGZWRvcmEgbmVlZHMgMiBHQjsgRGViaWFuIDEzIHdpdGgg
YSBsaWdodCBkZXNrdG9wIGZpdHMiCiAgICAgIGVsaWYgWyAiJE1BQ0siID0gaW50ZWwtdDIgXTsg
dGhlbiBESVNUUk89ZmVkb3JhLXQyOyBSRUFTT049IkludGVsIE1hYyB3aXRoIFQyIGNoaXA6IEZl
ZG9yYSBwbHVzIHRoZSB0MmxpbnV4IGtlcm5lbCBmb3IgaXRzIGtleWJvYXJkLCB0cmFja3BhZCwg
V2ktRmkgYW5kIHNvdW5kIgogICAgICBlbGlmIFsgIiRSQU0iIC1sdCAzMDAwIF07IHRoZW4gRElT
VFJPPWZlZG9yYS1taW47IFJFQVNPTj0iRmVkb3JhIHJ1bnMgaGVyZSwgYnV0IHRoZSBkZXNrdG9w
IG5lZWRzIHRvIGJlIHRoZSBsaWdodCBvbmUgKExYUXQpIHNvIHlvdXIgYXBwcyBoYXZlIHJvb20g
dG8gYnJlYXRoZS4gVGhlIGluc3RhbGxlciB3aWxsIHVzZSBzaW1wbGUgdGV4dCBzY3JlZW5zLiIK
ICAgICAgZmkKICAgIGVsc2UKICAgICAgY2FzZSAiJENQVUZMQUdTIiBpbgogICAgICAgICoiIGNt
b3YgIiopCiAgICAgICAgICBpZiBbICIkUkFNIiAtbHQgNDgwIF07IHRoZW4gRElTVFJPPXVuc3Vw
cG9ydGVkOyBSRUFTT049IjMyLWJpdCBQQyB3aXRoIG9ubHkgJHtSQU1fR0J9IEdCIG1lbW9yeTog
YmVsb3cgRGViaWFuJ3MgNTEyIE1CIG1pbmltdW0iCiAgICAgICAgICBlbHNlIERJU1RSTz1kZWJp
YW4taTM4NjsgUkVBU09OPSIzMi1iaXQtb25seSBwcm9jZXNzb3I6IEZlZG9yYSBpcyA2NC1iaXQg
b25seTsgRGViaWFuIDEyICgzMi1iaXQpIGlzIHN1cHBvcnRlZCB1bnRpbCBKdW5lIDIwMjgiOyBm
aSA7OwogICAgICAgICopIERJU1RSTz11bnN1cHBvcnRlZDsgUkVBU09OPSJwcm9jZXNzb3Igb2xk
ZXIgdGhhbiBhIFBlbnRpdW0gUHJvL0lJIChpNjg2KTogbm8gY3VycmVudCBMaW51eCBkaXN0cmli
dXRpb24gc3VwcG9ydHMgaXQiIDs7CiAgICAgIGVzYWMKICAgIGZpIDs7CmVzYWMKCiMgLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LSBwcm9jZXNzb3IKY2FzZSAiJEFSQ0giIGluCiAgYWFyY2g2NHxhcm02NHxhcm0qKQogICAgaWYg
WyAiJE1BQ0siID0gYXBwbGUtc2lsaWNvbiBdOyB0aGVuCiAgICAgIEFTQUhJPTEKICAgICAgX2Fk
ZCBubyAiQXBwbGUgU2lsaWNvbiBNYWMgKCQoZyBtYWNfbW9kZWwpKTogdGhpcyBVU0Igc3RpY2sg
Y2FuJ3Qgc3RhcnQgaXQuIiBcCiAgICAgICAgIkl0IG9ubHkgc3RhcnRzIFBDcyB3aXRoIEludGVs
IG9yIEFNRCBwcm9jZXNzb3JzLiBJbnN0ZWFkLCBpbnN0YWxsIEZlZG9yYSBBc2FoaSBSZW1peCIg
XAogICAgICAgICJmcm9tIG1hY09TIChUZXJtaW5hbDogY3VybCBodHRwczovL2FseC5zaCB8IHNo
KSwgdGhlbiBydW4gdGhpcyBwYWNrYWdlJ3Mgc2V0dXAgb24gaXQuIiBcCiAgICAgICAgIkd1aWRl
OiBsaW51eC1zZXR1cC9hc2FoaS9SRUFETUUubWQgb24gdGhpcyBzdGljay4iCiAgICBlbHNlCiAg
ICAgIF9hZGQgbm8gIkFSTSBwcm9jZXNzb3IgKCRBUkNIKTogdGhpcyBVU0Igc3RpY2sgb25seSBz
dGFydHMgSW50ZWwvQU1EICh4ODYtNjQpIFBDcy4iCiAgICBmaSA7OwogICopCiAgICBpZiBbICIk
KGcgY3B1XzY0Yml0KSIgIT0geWVzIF07IHRoZW4KICAgICAgX2FkZCBubyAiMzItYml0IHByb2Nl
c3NvciAoJChnIGNwdV9tb2RlbCkpOiBGZWRvcmEgbmVlZHMgYSA2NC1iaXQgKHg4Ni02NCkgcHJv
Y2Vzc29yLiIKICAgIGVsc2UKICAgICAgX2FkZCBvayAiNjQtYml0IHByb2Nlc3NvcjogJChnIGNw
dV9tb2RlbCkgKHg4Ni02NC12JExFVkVMKSIKICAgICAgWyAiJExFVkVMIiAtbGUgMSBdICYmIF9h
ZGQgaW5mbyAiVmVyeSBvbGQgcHJvY2Vzc29yOiBpdCB3b3JrcywgYnV0IHNvbWUgYXBwcyB3aWxs
IGJlIHNsb3cuIExJVEUgc3VnZ2VzdGVkLiIKICAgIGZpIDs7CmVzYWMKCiMgLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLSBtZW1v
cnkKaWYgWyAiJFJBTSIgLWx0IDE3MDAgXTsgdGhlbgogIF9hZGQgbm8gIk1lbW9yeTogJFJBTV9H
QiBHQi4gRmVkb3JhIG5lZWRzIGF0IGxlYXN0IDIgR0IgKDQgR0Igb3IgbW9yZSByZWNvbW1lbmRl
ZCkuIgogIFRFWFQ9MQplbGlmIFsgIiRSQU0iIC1sdCAzMDAwIF07IHRoZW4KICBfYWRkIG5vdGUg
Ik1lbW9yeTogJFJBTV9HQiBHQjogZW5vdWdoIGZvciB0aGUgbGlnaHRlc3Qgc2V0dXAgKExYUXQg
ZGVza3RvcCkuIFRoZSBpbnN0YWxsZXIgcnVucyBpbiBpdHMiIFwKICAgICJzaW1wbGVyIHRleHQg
bW9kZSAodXNlcyBsZXNzIG1lbW9yeSkuIFdlYiBwYWdlcyB3aXRoIG1hbnkgdGFicyB3aWxsIGJl
IHNsb3cuIgogIFRFWFQ9MQplbGlmIFsgIiRSQU0iIC1sdCA0NjAwIF07IHRoZW4KICBfYWRkIG5v
dGUgIk1lbW9yeTogJFJBTV9HQiBHQjogTElURSBzZXR1cCByZWNvbW1lbmRlZDsgdGhlIGluc3Rh
bGxlciBydW5zIGluIHRleHQgbW9kZSB0byBiZSBzYWZlLiIKICBURVhUPTEKZWxpZiBbICIkUkFN
IiAtbHQgNzAwMCBdOyB0aGVuCiAgX2FkZCBvayAiTWVtb3J5OiAkUkFNX0dCIEdCIChMSVRFIHN1
Z2dlc3RlZDogRlVMTCBuZWVkcyA4IEdCKSIKZWxzZQogIF9hZGQgb2sgIk1lbW9yeTogJFJBTV9H
QiBHQiIKZmkKaWYgWyAiJFJBTSIgLWx0IDcwMDAgXTsgdGhlbiBQUk9GSUxFPWxpdGU7IFdIWT0i
JFJBTV9HQiBHQiBtZW1vcnkiOyBmaQppZiBbICIkTEVWRUwiIC1sZSAxIF0gJiYgWyAiJEFSQ0gi
ID0geDg2XzY0IF07IHRoZW4gUFJPRklMRT1saXRlOyBXSFk9IiR7V0hZOiskV0hZLCB9dmVyeSBv
bGQgcHJvY2Vzc29yIjsgZmkKWyAkQVNBSEkgPSAxIF0gJiYgeyBQUk9GSUxFPWZ1bGw7IFdIWT0i
RmVkb3JhIEFzYWhpIFJlbWl4IChLREUpIjsgVEVYVD0wOyB9CgojIC0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0gc3RhcnQtdXAg
ZmlybXdhcmUgLyBTZWN1cmUgQm9vdAppZiBbICRBU0FISSA9IDAgXTsgdGhlbgogIGlmIFsgIiQo
ZyBmaXJtd2FyZSkiID0gdWVmaSBdOyB0aGVuCiAgICBpZiBbICIkKGcgZWZpX2JpdHMpIiA9IDMy
IF07IHRoZW4KICAgICAgX2FkZCBub3RlICIzMi1iaXQgVUVGSSBmaXJtd2FyZSB3aXRoIGEgNjQt
Yml0IHByb2Nlc3NvcjogdGhpcyBzdGljayBtYXkgbm90IHN0YXJ0LiIgXAogICAgICAgICJJZiBp
dCBkb2Vzbid0LCBzd2l0Y2ggdGhlIGZpcm13YXJlIHRvIExlZ2FjeS9DU00gYm9vdCAoaWYgaXQg
aGFzIHRoYXQgb3B0aW9uKS4iCiAgICBlbHNlCiAgICAgIF9hZGQgb2sgIlVFRkkgc3RhcnQtdXAg
ZmlybXdhcmUiCiAgICBmaQogICAgY2FzZSAiJFNCIiBpbgogICAgICBvbikgIF9hZGQgb2sgIlNl
Y3VyZSBCb290IGlzIG9uOiBmaW5lLCBGZWRvcmEgaXMgc2lnbmVkIChrZWVwIGl0IG9uKSIgOzsK
ICAgICAgb2ZmKSBfYWRkIG9rICJTZWN1cmUgQm9vdCBpcyBvZmY6IGZpbmUgKHlvdSBjYW4gc3dp
dGNoIGl0IG9uIGFmdGVyIGluc3RhbGxpbmcpIiA7OwogICAgZXNhYwogIGVsc2UKICAgIF9hZGQg
b2sgIkxlZ2FjeSBCSU9TIHN0YXJ0LXVwIChubyBVRUZJKTogZmluZSwgRmVkb3JhIGluc3RhbGxz
IHRoZSBjbGFzc2ljIHdheSIKICBmaQpmaQoKIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tIE1hY3MgYW5kIG1ha2VycwpjYXNl
ICIkTUFDSyIgaW4KICBpbnRlbC10MikKICAgIEFTSz0xOyBXSVJFRD0xCiAgICBfYWRkIG5vdGUg
Ik1hYyB3aXRoIEFwcGxlJ3MgVDIgY2hpcCAoJChnIG1hY19tb2RlbCkpOiBGZWRvcmEgaW5zdGFs
bHMsIHRoZW4gc2V0dXAgYWRkcyB0aGUiIFwKICAgICAgInQybGludXgga2VybmVsIHNvIHRoZSBi
dWlsdC1pbiBrZXlib2FyZCwgdHJhY2twYWQsIFRvdWNoIEJhciBhbmQgc291bmQgd29yay4gVW50
aWwgdGhlbiIgXAogICAgICAidXNlIGEgVVNCIGtleWJvYXJkICsgbW91c2UgYW5kIGEgd2lyZWQg
Y29ubmVjdGlvbiAoVVNCIEV0aGVybmV0IG9yIHBob25lIFVTQiB0ZXRoZXJpbmcpLiIgXAogICAg
ICAiV2ktRmkgbmVlZHMgQXBwbGUncyBmaXJtd2FyZTogQkVGT1JFIGVyYXNpbmcgbWFjT1MsIHJ1
biBnZXQtYXBwbGUtZmlybXdhcmUuc2ggZnJvbSB0aGlzIiBcCiAgICAgICJzdGljayAobGludXgt
c2V0dXAvbGludXgvaHcvbWFjKSBpbiBtYWNPUyBUZXJtaW5hbC4gTmVlZGVkIGluIG1hY09TIFJl
Y292ZXJ5ID4gU3RhcnR1cCBTZWN1cml0eSIgXAogICAgICAiVXRpbGl0eTogJ05vIFNlY3VyaXR5
JyArICdBbGxvdyBib290aW5nIGZyb20gZXh0ZXJuYWwgbWVkaWEnLiBZb3UgY2FuIGNhbmNlbCBh
bmQga2VlcCBtYWNPUy4iIDs7CiAgaW50ZWwpCiAgICBfYWRkIG9rICJJbnRlbCBNYWMgKCQoZyBt
YWNfbW9kZWwpKTogc3VwcG9ydGVkLiBGdW5jdGlvbiBrZXlzIGFyZSBzZXQgdG8gd29yayBsaWtl
IGEgUEMncyIgXAogICAgICAiKHByZXNzIEZuIGZvciBicmlnaHRuZXNzL3ZvbHVtZSkgYW5kIGZh
biBjb250cm9sIChtYnBmYW4pIGlzIGFkZGVkIGZvciBNYWNCb29rcy4iCiAgICBbICIkKGcgbWFj
X2ZhY2V0aW1laGQpIiA9IHllcyBdICYmIF9hZGQgbm90ZSAiVGhlIGJ1aWx0LWluIEZhY2VUaW1l
IEhEIGNhbWVyYSBuZWVkcyBhIGRyaXZlciBGZWRvcmEgZG9lc24ndCBpbmNsdWRlLCIgXAogICAg
ICAic28gaXQgd29uJ3Qgd29yayAoYSBVU0Igd2ViY2FtIHdpbGwpLiBkb2NzL0NPTVBBVElCSUxJ
VFkubWQgaGFzIHRoZSBvcHRpb25hbCBtYW51YWwgc3RlcHMuIgogICAgOzsKZXNhYwpjYXNlICIk
TUFLRVIiIGluCiAgdG9zaGliYSkgX2FkZCBpbmZvICJUb3NoaWJhOiBob3RrZXlzLCBiYWNrbGln
aHQgYW5kIEJsdWV0b290aCBzd2l0Y2ggdXNlIEZlZG9yYSdzIGJ1aWx0LWluIHRvc2hpYmFfYWNw
aSBkcml2ZXIuIiA7OwogIGRlbGwpICAgIF9hZGQgaW5mbyAiRGVsbDoga2V5Ym9hcmQgbGlnaHQg
YW5kIGhvdGtleXMgdXNlIEZlZG9yYSdzIGJ1aWx0LWluIGRlbGwtbGFwdG9wIGRyaXZlci4iIDs7
CiAgbGVub3ZvKSAgX2FkZCBpbmZvICJMZW5vdm86IFRoaW5rUGFkIGJ1dHRvbnMsIGtleWJvYXJk
IGxpZ2h0IGFuZCBiYXR0ZXJ5IGNoYXJnZSBsaW1pdHMgd29yayBvdXQgb2YgdGhlIGJveC4iIDs7
CiAgbWljcm9zb2Z0KQogICAgX2FkZCBub3RlICJNaWNyb3NvZnQgU3VyZmFjZTogdGhlIHRvdWNo
IHNjcmVlbiwgcGVuLCBjYW1lcmFzIGFuZCBzb21lIGtleWJvYXJkIGNvdmVycyBuZWVkIHRoZSIg
XAogICAgICAibGludXgtc3VyZmFjZSBrZXJuZWwgKG5vdCBpbmNsdWRlZCkuIFVzZSBhIFVTQiBr
ZXlib2FyZCBpZiB0aGUgY292ZXIgZG9lc24ndCByZXNwb25kLiIgOzsKICBnb29nbGUpCiAgICBf
YWRkIG5vdGUgIkNocm9tZWJvb2s6IG9ubHkgd29ya3Mgd2l0aCBjdXN0b20gVUVGSSBmaXJtd2Fy
ZSAoTXJDaHJvbWVib3gpLiBTcGVha2VycyBhbmQiIFwKICAgICAgIm1pY3JvcGhvbmUgb2Z0ZW4g
ZG9uJ3Qgd29yazsgY2hlY2sgdGhlIG1vZGVsIG9uIGRvY3MubXJjaHJvbWVib3gudGVjaCBmaXJz
dC4iIDs7CmVzYWMKCiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLSBncmFwaGljcwpOVj0kKGcgbnZpZGlhX2NsYXNzKSBOVkY9
JChnIG52aWRpYV9mYW1pbHkpCmNhc2UgIiROViIgaW4KICBtb2Rlcm4pCiAgICBfYWRkIG5vdGUg
Ik5WSURJQSAkTlZGIGdyYXBoaWNzOiBOVklESUEncyBkcml2ZXIgaW5zdGFsbHMgYnkgaXRzZWxm
IGR1cmluZyBzZXR1cCIgXAogICAgICAiKHVudGlsIHRoZW4gdGhlIG9wZW4tc291cmNlIGRyaXZl
ciBpcyB1c2VkOiBpdCB3b3JrcywgYnV0IGdhbWVzIGFyZSBzbG93KS4iCiAgICBORUVEU19LRVk9
MSA7OwogIDU4MHh4KQogICAgX2FkZCBub3RlICJOVklESUEgJE5WRiBncmFwaGljczogTlZJRElB
J3MgNTgwIGRyaXZlciBzZXJpZXMgKHRoZSBsYXN0IG9uZSBmb3IgdGhpcyBjYXJkKSIgXAogICAg
ICAiaW5zdGFsbHMgYnkgaXRzZWxmIGR1cmluZyBzZXR1cC4iCiAgICBORUVEU19LRVk9MSA7Owog
IGxlZ2FjeSkKICAgIF9hZGQgbm90ZSAiTlZJRElBICROVkYgZ3JhcGhpY3MgKG9sZGVyIGNhcmQp
OiB1c2VzIHRoZSBidWlsdC1pbiBvcGVuLXNvdXJjZSBkcml2ZXIgKG5vdXZlYXUpLiIgXAogICAg
ICAiRGVza3RvcCBhbmQgdmlkZW8gd29yazsgM0QgZ2FtZXMgYXJlIHNsb3cuIE5WSURJQSdzIG93
biBkcml2ZXIgZG9lc24ndCBzdXBwb3J0IiBcCiAgICAgICJ0aGlzIGNhcmQgb24gY3VycmVudCBG
ZWRvcmEuIiA7Owplc2FjClsgIiQoZyBncHVfYW1kKSIgPSB5ZXMgXSAmJiBfYWRkIG9rICJBTUQg
UmFkZW9uIGdyYXBoaWNzOiB3b3JrcyBvdXQgb2YgdGhlIGJveCIKWyAiJChnIGdwdV9pbnRlbCki
ID0geWVzIF0gJiYgX2FkZCBvayAiSW50ZWwgZ3JhcGhpY3M6IHdvcmtzIG91dCBvZiB0aGUgYm94
IgpbICIkKGcgaHlicmlkKSIgPSB5ZXMgXSAmJiBfYWRkIG9rICJUd28gZ3JhcGhpY3MgY2hpcHMg
KHN3aXRjaGFibGUpOiBhcHBzIHVzZSB0aGUgcG93ZXItc2F2aW5nIG9uZTsgZm9yIGdhbWVzLCIg
XAogICJyaWdodC1jbGljayB0aGUgYXBwID4gJ0xhdW5jaCB1c2luZyBEZWRpY2F0ZWQgR3JhcGhp
Y3MgQ2FyZCcuIgoKIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tIG5ldHdvcmsKV1Y9JChnIHdpZmlfdmVuZG9yKSBCRFJWPSQo
ZyB3aWZpX2Jyb2FkY29tX2RyaXZlcikgRVRIPSQoZyBldGhfY291bnQpCmlmIFsgIiRNQUNLIiAh
PSBpbnRlbC10MiBdICYmIFsgJEFTQUhJID0gMCBdOyB0aGVuCiAgY2FzZSAiJFdWOiRCRFJWIiBp
bgogICAgYnJvYWRjb206d2wpCiAgICAgIF9hZGQgbm90ZSAiQnJvYWRjb20gV2ktRmkgKCQoZyB3
aWZpX2lkcykpOiB3b3JrcyBhZnRlciBzZXR1cCBpbnN0YWxscyBCcm9hZGNvbSdzIGRyaXZlci4i
IFwKICAgICAgICAiRHVyaW5nIHRoZSBpbnN0YWxsYXRpb24gaXRzZWxmIHVzZSBFdGhlcm5ldCBv
ciBwaG9uZSBVU0IgdGV0aGVyaW5nLiIKICAgICAgV0lSRUQ9MTsgTkVFRFNfS0VZPTEgOzsKICAg
IGJyb2FkY29tOmI0MykKICAgICAgX2FkZCBub3RlICJPbGQgQnJvYWRjb20gV2ktRmkgKCQoZyB3
aWZpX2lkcykpOiBuZWVkcyBmaXJtd2FyZSB0aGF0IGNhbid0IGJlIGluY2x1ZGVkLiIgXAogICAg
ICAgICJVc2UgRXRoZXJuZXQ7IGRvY3MvQ09NUEFUSUJJTElUWS5tZCBzaG93cyB0aGUgb25lLXRp
bWUgYjQzLWZ3Y3V0dGVyIHN0ZXAuIgogICAgICBXSVJFRD0xIDs7CiAgICBicm9hZGNvbTp1bmtu
b3duKQogICAgICBfYWRkIG5vdGUgIkJyb2FkY29tIFdpLUZpIGNoaXAgbm90IGluIG91ciBsaXN0
ICgkKGcgd2lmaV9pZHMpKTogaXQgbWF5IG5lZWQgYW4gZXh0cmEgZHJpdmVyLiIgXAogICAgICAg
ICJVc2UgRXRoZXJuZXQgb3IgcGhvbmUgVVNCIHRldGhlcmluZyBkdXJpbmcgdGhlIGluc3RhbGxh
dGlvbi4iCiAgICAgIFdJUkVEPTEgOzsKICAgIGJyb2FkY29tOmJ1aWx0aW4pIF9hZGQgb2sgIldp
LUZpOiBCcm9hZGNvbSAoZHJpdmVyIGJ1aWx0IGludG8gRmVkb3JhKSIgOzsKICAgIGludGVsOiop
ICAgIF9hZGQgb2sgIldpLUZpOiBJbnRlbCAod29ya3Mgb3V0IG9mIHRoZSBib3gpIiA7OwogICAg
bWVkaWF0ZWs6KikgX2FkZCBvayAiV2ktRmk6IE1lZGlhVGVrICh3b3JrcyBvdXQgb2YgdGhlIGJv
eCkiIDs7CiAgICByZWFsdGVrOiopICBfYWRkIG9rICJXaS1GaTogUmVhbHRlayAod29ya3Mgb3V0
IG9mIHRoZSBib3gpIiA7OwogICAgYXRoZXJvczoqKSAgX2FkZCBvayAiV2ktRmk6IFF1YWxjb21t
IEF0aGVyb3MgKHdvcmtzIG91dCBvZiB0aGUgYm94KSIgOzsKICAgIG90aGVyOiopICAgIF9hZGQg
aW5mbyAiV2ktRmk6IHByZXNlbnQgKHVua25vd24gbWFrZTogY2hlY2sgaXQgYWZ0ZXIgaW5zdGFs
bGluZykiIDs7CiAgICBub25lOiopICAgICBfYWRkIGluZm8gIk5vIGJ1aWx0LWluIFdpLUZpIGZv
dW5kIiA7OwogIGVzYWMKICBpZiBbICIke0VUSDotMH0iIC1ndCAwIF07IHRoZW4gX2FkZCBvayAi
RXRoZXJuZXQgcG9ydDogJChnIGV0aF92ZW5kb3IpIgogIGVsaWYgWyAkV0lSRUQgPSAxIF07IHRo
ZW4KICAgIF9hZGQgaW5mbyAiTm8gRXRoZXJuZXQgcG9ydDogcGx1ZyBpbiB5b3VyIHBob25lIGJ5
IFVTQiBhbmQgdHVybiBvbiAnVVNCIHRldGhlcmluZycsIG9yIHVzZSBhIFVTQiBFdGhlcm5ldCBh
ZGFwdGVyLiIKICBmaQogIGlmIFsgIiRXViIgPSBub25lIF0gJiYgWyAiJHtFVEg6LTB9IiA9IDAg
XTsgdGhlbgogICAgX2FkZCBub3RlICJObyBXaS1GaSBvciBFdGhlcm5ldCBmb3VuZDogaW5zdGFs
bGluZyBuZWVkcyBpbnRlcm5ldCAocGhvbmUgVVNCIHRldGhlcmluZyB3b3JrcykuIgogICAgV0lS
RUQ9MQogIGZpCmZpCmlmIFsgJE5FRURTX0tFWSA9IDEgXSAmJiBbICIkU0IiID0gb24gXTsgdGhl
bgogIF9hZGQgbm90ZSAiU2VjdXJlIEJvb3QgKyBhIGRyaXZlciBidWlsdCBvbiB0aGlzIGNvbXB1
dGVyOiBvbmNlLCBhZnRlciBzZXR1cCwgYSBibHVlICdNT0sgbWFuYWdlbWVudCciIFwKICAgICJz
Y3JlZW4gYXBwZWFycyBhdCByZXN0YXJ0LiBDaG9vc2UgRW5yb2xsIE1PSyA+IENvbnRpbnVlID4g
WWVzLCB0eXBlIHRoZSBvbmUtdGltZSBjb2RlIiBcCiAgICAiU2VjdXJlIExpbnV4IHNob3dzIHlv
dSwgdGhlbiBSZWJvb3QuIChTa2lwIGl0IGFuZCB0aGUgZHJpdmVyIHN0YXlzIG9mZjsgbm90aGlu
ZyBicmVha3MuKSIKZmkKCiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLSBkcml2ZXMKRElTS1M9JChnIGRpc2tfY291bnQpIEJJ
Rz0wCmZvciAoKGkgPSAxOyBpIDw9ICR7RElTS1M6LTB9OyBpKyspKTsgZG8KICBJRlM9OiByZWFk
IC1yIGRuIGRrIGRnIDw8PCAiJChnICJkaXNrXyRpIikiCiAgY2FzZSAiJGRrIiBpbiBudm1lKSBr
dD0iTlZNZSBTU0QiIDs7IHNzZCkga3Q9IlNTRCIgOzsgaGRkKSBrdD0iaGFyZCBkaXNrIChzbG93
ZXIgdGhhbiBhbiBTU0QpIiA7OyBlbW1jKSBrdD0iZU1NQyAoc2xvdykiIDs7ICopIGt0PSRkayA7
OyBlc2FjCiAgWyAiJHtkZzotMH0iIC1nZSAxNiBdICYmIEJJRz0kKChCSUcgKyAxKSkKICBfYWRk
IG9rICJEcml2ZTogJGRuLCAkZGcgR0IgJGt0Igpkb25lCmlmIFsgJEFTQUhJID0gMCBdICYmIFsg
IiRCSUciIC1lcSAwIF07IHRoZW4gX2FkZCBubyAiTm8gaW50ZXJuYWwgZHJpdmUgb2YgMTYgR0Ig
b3IgbW9yZTogdGhlcmUgaXMgbm93aGVyZSB0byBpbnN0YWxsLiI7IERJU1RSTz11bnN1cHBvcnRl
ZDsgUkVBU09OPSJubyBpbnRlcm5hbCBkcml2ZSBvZiAxNiBHQiBvciBtb3JlIjsgZmkKWyAiJHtE
SVNLUzotMH0iIC1ndCAxIF0gJiYgX2FkZCBpbmZvICJTZXZlcmFsIGRyaXZlczogdGhlIGluc3Rh
bGxlciBhc2tzIHdoaWNoIE9ORSB0byBlcmFzZTsgdGhlIG90aGVycyBhcmUgbm90IHRvdWNoZWQu
IgoKIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tIHBvd2VyCmlmIFsgIiQoZyBiYXR0ZXJ5KSIgPSB5ZXMgXTsgdGhlbgogIGlm
IFsgIiRTQiIgPSBvbiBdOyB0aGVuCiAgICBfYWRkIGluZm8gIkJhdHRlcnk6IHNsZWVwIChsaWQg
Y2xvc2UpIHdvcmtzLiBIaWJlcm5hdGUgaXMgb3B0aW9uYWwgYW5kIG5lZWRzIFNlY3VyZSBCb290
IG9mZiIgXAogICAgICAiKFNlY3VyZSBCb290IGJsb2NrcyBpdCk7IHRoZSB3ZWxjb21lIHNjcmVl
biBleHBsYWlucyB0aGUgY2hvaWNlLiIKICBlbHNlCiAgICBfYWRkIGluZm8gIkJhdHRlcnk6IHNs
ZWVwIChsaWQgY2xvc2UpIHdvcmtzOyBoaWJlcm5hdGUgY2FuIGJlIHN3aXRjaGVkIG9uIGZyb20g
dGhlIHdlbGNvbWUgc2NyZWVuLiIKICBmaQpmaQoKIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tIHZlcmRpY3QKaWYgWyAkQkxP
Q0tFUlMgLWd0IDAgXTsgdGhlbiBWRVJESUNUPXVuc3VwcG9ydGVkOyBWVEVYVD0iTk9UIFNVUFBP
UlRFRCBCWSBUSElTIFVTQiI7IFNUQVRVUz1VTlNVUFBPUlRFRAplbGlmIFsgJE5PVEVTIC1ndCAw
IF07IHRoZW4gVkVSRElDVD1ub3RlczsgVlRFWFQ9IldPUktTIFdJVEggTk9URVMiOyBTVEFUVVM9
Tk9URVMKZWxzZSBWRVJESUNUPWdvb2Q7IFZURVhUPSJHT09EIjsgU1RBVFVTPU9LOyBmaQpbIC1u
ICIkV0hZIiBdIHx8IFdIWT0iJFJBTV9HQiBHQiBtZW1vcnkiCgpOQU1FPSIkKGcgZG1pX3ZlbmRv
cikgJFBST0RVQ1QiCmlmIFsgLW4gIiRGQU1JTFkiIF0gJiYgWyAiJEZBTUlMWSIgIT0gIiRQUk9E
VUNUIiBdOyB0aGVuCiAgY2FzZSAiJEZBTUlMWSIgaW4gKiJUbyBiZSBmaWxsZWQiKnwqIkRlZmF1
bHQgc3RyaW5nIip8Kl8qKSA7OyAqKSBOQU1FPSIkTkFNRSAoJEZBTUlMWSkiIDs7IGVzYWMKZmkK
WyAkQVNBSEkgPSAxIF0gJiYgTkFNRT0kKGcgbWFjX21vZGVsKQoKY2FzZSAiJERJU1RSTyIgaW4K
ICBmZWRvcmF8ZmVkb3JhLW1pbikgUEFSQT0iIiA7OwogIGZlZG9yYS10MikgUEFSQT0iVGhpcyBN
YWMgZ2V0cyBGZWRvcmEgcGx1cyB0aGUgY29tbXVuaXR5IHQybGludXgga2VybmVsIChhZGRlZCBh
dXRvbWF0aWNhbGx5IGR1cmluZyBzZXR1cCksIHNvIGl0cyBidWlsdC1pbiBrZXlib2FyZCwgdHJh
Y2twYWQsIFRvdWNoIEJhciwgc291bmQgYW5kICh3aXRoIHRoZSBmaXJtd2FyZSBzYXZlZCBmcm9t
IG1hY09TKSBXaS1GaSB3b3JrLiBUaGUgYXBwcyBhbmQgc2V0dGluZ3MgYXJlIHRoZSBzYW1lIGFz
IG9uIGFueSBvdGhlciBjb21wdXRlci4iIDs7CiAgYXNhaGkpICAgICBQQVJBPSJBcHBsZSBTaWxp
Y29uIE1hY3MgZ2V0IEZlZG9yYSBBc2FoaSBSZW1peCwgdGhlIG9mZmljaWFsIEZlZG9yYSBidWls
ZCBmb3IgdGhlc2UgTWFjcy4gSXQgaXMgaW5zdGFsbGVkIGZyb20gbWFjT1MgbmV4dCB0byBpdCAo
bm8gVVNCIHN0aWNrKSwgYW5kIHRoZW4gdGhpcyBwYWNrYWdlJ3Mgc2V0dXAuc2ggZ2l2ZXMgaXQg
dGhlIHNhbWUgYXBwcyBhbmQgc2V0dGluZ3MsIGV4Y2VwdCBhIGZldyB0aGF0IG9ubHkgZXhpc3Qg
Zm9yIEludGVsL0FNRCBQQ3MgKHNlZSBsaW51eC1zZXR1cC9hc2FoaS9SRUFETUUubWQpLiIgOzsK
ICBkZWJpYW4tbGl0ZSkgUEFSQT0iVGhpcyBjb21wdXRlciBoYXMgdG9vIGxpdHRsZSBtZW1vcnkg
Zm9yIEZlZG9yYS4gUmVzdGFydCwgYW5kIGluIHRoZSBVU0IgbWVudSBjaG9vc2UgdGhlIERlYmlh
biBlbnRyeSBmb3Igb2xkZXIgUENzOiBpdCBpbnN0YWxscyBEZWJpYW4gMTMgd2l0aCBhIGxpZ2h0
IGRlc2t0b3AgYW5kIHRoZSBzYW1lIHNlY3VyaXR5IHNldHRpbmdzLCB3aXRoIGZld2VyIGFwcHMu
IiA7OwogIGRlYmlhbi1pMzg2KSBQQVJBPSJUaGlzIGNvbXB1dGVyJ3MgcHJvY2Vzc29yIGlzIDMy
LWJpdCBvbmx5LCBhbmQgRmVkb3JhIGlzIDY0LWJpdCBvbmx5LiBSZXN0YXJ0LCBhbmQgaW4gdGhl
IFVTQiBtZW51IGNob29zZSB0aGUgRGViaWFuICgzMi1iaXQpIGVudHJ5OiBpdCBpbnN0YWxscyBE
ZWJpYW4gMTIgZm9yIDMyLWJpdCBQQ3MgKHNlY3VyaXR5IHVwZGF0ZXMgdW50aWwgSnVuZSAyMDI4
KSB3aXRoIGEgbGlnaHQgZGVza3RvcCBhbmQgdGhlIHNhbWUgc2VjdXJpdHkgc2V0dGluZ3MsIHdp
dGggZmV3ZXIgYXBwcy4iIDs7CiAgdW5zdXBwb3J0ZWQpIFBBUkE9IlNvcnJ5OiB0aGlzIGNvbXB1
dGVyIGlzIGJlbG93IHdoYXQgY3VycmVudCBMaW51eCBkaXN0cmlidXRpb25zIHN1cHBvcnQgKCRS
RUFTT04pLiIgOzsKZXNhYwoKZWNobyAiICBDb21wYXRpYmlsaXR5IGNoZWNrOiAke05BTUUjIH0i
CmVjaG8KcHJpbnRmICclc1xuJyAiJHtMSU5FU1tAXX0iCmVjaG8KZWNobyAiICBWZXJkaWN0OiAk
VlRFWFQiCmlmIFsgIiRESVNUUk8iID0gZmVkb3JhLW1pbiBdOyB0aGVuIGVjaG8gIiAgUmVjb21t
ZW5kZWQgc2V0dXA6IE1JTiAoTFhRdCwgZXNzZW50aWFsIGFwcHMpICBbJFdIWV0iCmVsaWYgWyAi
JERJU1RSTyIgPSBmZWRvcmEgXSB8fCBbICIkRElTVFJPIiA9IGZlZG9yYS10MiBdIHx8IFsgIiRE
SVNUUk8iID0gYXNhaGkgXTsgdGhlbgogIGlmIFsgIiRQUk9GSUxFIiA9IGZ1bGwgXTsgdGhlbiBl
Y2hvICIgIFJlY29tbWVuZGVkIHNldHVwOiBGVUxMIChLREUgUGxhc21hLCBldmVyeSBhcHApICBb
JFdIWV0iCiAgZWxzZSBlY2hvICIgIFJlY29tbWVuZGVkIHNldHVwOiBMSVRFIChYZmNlLCBlc3Nl
bnRpYWwgYXBwcykgIFskV0hZXSI7IGZpCmZpCmlmIFsgLW4gIiRQQVJBIiBdOyB0aGVuCiAgZWNo
bwogIHByaW50ZiAnJXNcbicgIiRQQVJBIiB8IGZvbGQgLXMgLXcgNzYgfCBzZWQgJ3MvXi8gIC87
IHMvICokLy8nCmZpCgppZiBbICRJTlNUQUxMRVIgPSAxIF07IHRoZW4KICBlY2hvICJIV19TVEFU
VVM9JFNUQVRVUyIKICBlY2hvICJIV19QUk9GSUxFPSRQUk9GSUxFIgogIGVjaG8gIkhXX1RFWFRf
SU5TVEFMTD0kVEVYVCIKICBlY2hvICJIV19ESVNUUk89JERJU1RSTyIKICBlY2hvICJIV19ESVNU
Uk9fUkVBU09OPSRSRUFTT04iCmZpCgppZiBbIC1uICIkRVhQT1JUIiBdOyB0aGVuCiAgcSgpIHsg
cHJpbnRmICIlcz0lcVxuIiAiJDEiICIkMiI7IH0KICB7CiAgICBxIEhXX1ZFUkRJQ1QgIiRWRVJE
SUNUIgogICAgcSBIV19TVEFUVVMgIiRTVEFUVVMiCiAgICBxIEhXX1ZFUkRJQ1RfVEVYVCAiJFZU
RVhUIgogICAgcSBIV19QUk9GSUxFX1NVR0dFU1QgIiRQUk9GSUxFIgogICAgcSBIV19QUk9GSUxF
X1dIWSAiJFdIWSIKICAgIHEgSFdfVEVYVF9JTlNUQUxMICIkVEVYVCIKICAgIHEgSFdfRElTVFJP
ICIkRElTVFJPIgogICAgcSBIV19ESVNUUk9fUkVBU09OICIkUkVBU09OIgogICAgcSBIV19CTE9D
S0VSUyAiJEJMT0NLRVJTIgogICAgcSBIV19CTE9DS0VSX1RFWFQgIiRCTE9DS0VSX1RFWFQiCiAg
ICBxIEhXX05PVEVTICIkTk9URVMiCiAgICBxIEhXX0FTS19DT05USU5VRSAiJEFTSyIKICAgIHEg
SFdfTkVFRFNfV0lSRUQgIiRXSVJFRCIKICAgIHEgSFdfQVNBSEkgIiRBU0FISSIKICAgIHEgSFdf
VDIgIiQoIFsgIiRNQUNLIiA9IGludGVsLXQyIF0gJiYgZWNobyAxIHx8IGVjaG8gMCkiCiAgICBx
IEhXX1NFQ1VSRV9CT09UICIkU0IiCiAgICBxIEhXX05FRURTX01PSyAiJCggWyAkTkVFRFNfS0VZ
ID0gMSBdICYmIFsgIiRTQiIgPSBvbiBdICYmIGVjaG8gMSB8fCBlY2hvIDApIgogICAgcSBIV19O
VklESUEgIiROViIKICAgIHEgSFdfRklSTVdBUkUgIiQoZyBmaXJtd2FyZSkiCiAgICBxIEhXX1JB
TV9NQiAiJFJBTSIKICB9ID4gIiRFWFBPUlQiCmZpCgpbICRJTlNUQUxMRVIgPSAxIF0gJiYgZXhp
dCAwCmNhc2UgJFZFUkRJQ1QgaW4gZ29vZCkgZXhpdCAwIDs7IG5vdGVzKSBleGl0IDEgOzsgKikg
ZXhpdCAyIDs7IGVzYWMK
HWCHECK_END
DEB_LITE_MENU='the netboot menu entry: "Lighter Debian - for old or small PCs (under 2 GB memory)"'
DEB_I386_MENU='the netboot menu entry: "Very old 32-bit PCs - Debian 12 (32-bit)"'
hw_check() {
  HW_STATUS=OK; HW_PROFILE=""; HW_TEXT_INSTALL=0; HW_DISTRO=""; HW_DISTRO_REASON=""
  : > /tmp/hw-report.txt
  base64 -d /tmp/hw-compat.b64 > /tmp/compat-check.sh 2>/dev/null
  [ -s /tmp/compat-check.sh ] || return 0
  bash /tmp/compat-check.sh --installer > /tmp/hw-report.raw 2>&1
  v=$(sed -n 's/^HW_STATUS=//p' /tmp/hw-report.raw | tail -1);       case "$v" in OK|NOTES|UNSUPPORTED) HW_STATUS=$v ;; esac
  v=$(sed -n 's/^HW_PROFILE=//p' /tmp/hw-report.raw | tail -1);      case "$v" in full|lite) HW_PROFILE=$v ;; esac
  v=$(sed -n 's/^HW_TEXT_INSTALL=//p' /tmp/hw-report.raw | tail -1); case "$v" in 1) HW_TEXT_INSTALL=1 ;; esac
  v=$(sed -n 's/^HW_DISTRO=//p' /tmp/hw-report.raw | tail -1);       case "$v" in fedora|fedora-min|fedora-t2|asahi|debian-lite|debian-i386|unsupported) HW_DISTRO=$v ;; esac
  HW_DISTRO_REASON=$(sed -n 's/^HW_DISTRO_REASON=//p' /tmp/hw-report.raw | tail -1 | tr -cd ' -~' | cut -c1-200)
  grep -v '^HW_[A-Z_]*=' /tmp/hw-report.raw > /tmp/hw-report.txt
}
sl_pre_begin 'Checking this computer. No percentage is available for the hardware check.'
hw_check
sl_pre_end 'Hardware check finished.'
if [ "$HW_STATUS" = UNSUPPORTED ]; then
  header "this computer"
  cat /tmp/hw-report.txt
  echo
  echo "   Sorry: this computer can't run the Complete Secure Linux Package (see above)."
  [ -n "$HW_DISTRO_REASON" ] && echo "   Why: $HW_DISTRO_REASON"
  echo
  echo "   Nothing has been changed. What to do next:"
  echo
  case "$HW_DISTRO" in
    debian-lite)
      echo "   This computer has less memory than Fedora needs, but Debian 13 with a light"
      echo "   desktop suits it. Restart, and in the blue USB menu choose:"
      echo
      if [ -n "$DEB_LITE_MENU" ]; then echo "     $DEB_LITE_MENU"
      else echo "     (the Debian 13 entry: it is not on this USB stick, so rebuild the stick without"
           echo "      the -NoDebian option, or use another computer to build one)"; fi ;;
    debian-i386)
      echo "   This computer has a 32-bit-only processor. Fedora can't run on it, but Debian 12"
      echo "   (32-bit) can, until June 2028. Restart, and in the blue USB menu choose:"
      echo
      if [ -n "$DEB_I386_MENU" ]; then echo "     $DEB_I386_MENU"
      else echo "     (the Debian 12 32-bit entry: it is not on this USB stick, so rebuild the stick"
           echo "      without the -NoDebian option, or use another computer to build one)"; fi
      echo
      echo "   Its screen explains the limits first (web browsers are dropping 32-bit support)." ;;
    fedora-t2)
      echo "   This is an Intel Mac with the T2 security chip. Fedora does work on it, but the Mac"
      echo "   needs a few things set up first. Restart, then on this USB stick open the folder"
      echo "     FOR-MACS / T2-Macs  and read  READ-ME-FIRST-T2-Mac.txt"
      echo "   (USB keyboard and mouse, a network cable, and Startup Security Utility set to"
      echo "    \"No Security\" and \"Allow booting from external media\")." ;;
    asahi)
      echo "   This is an Apple Silicon Mac (M1 or newer). It can't start from a USB stick."
      echo "   Start it normally (macOS), plug this stick in, and on the stick open the folder"
      echo "     FOR-MACS / Apple-Silicon-Macs  and read  README.md"
      echo "   It installs Fedora Asahi Remix from macOS, then runs this package's setup."
      echo "   (On the stick the script is  install-secure-linux-on-asahi.sh.)" ;;
    fedora|"")
      echo "   The reason is shown above. If it can be fixed (for example by a setting in the BIOS or"
      echo "   a network cable), the report says how. Your files on this computer have not been touched." ;;
    *)
      echo "   Nothing on this USB stick can install Linux on this computer. A newer computer, or"
      echo "   one with at least 2 GB of memory and a 64-bit processor, will work. Your files on"
      echo "   this computer have not been touched." ;;
  esac
  echo
  echo "   R = restart now (take the USB stick out if you want to start this computer normally)"
  echo "   P = power off"
  echo
  while true; do
    answer "Type R to restart or P to power off:"
    case "$REPLY_TEXT" in
      [Rr]) echo "   Restarting..."; reboot -f; exit 1 ;;
      [Pp]) echo "   Powering off..."; poweroff -f; exit 1 ;;
    esac
  done
elif [ "$HW_STATUS" = NOTES ]; then
  header "this computer"
  cat /tmp/hw-report.txt
  echo
  while true; do
    answer "Type C to continue (Q to cancel):"
    case "$REPLY_TEXT" in [Cc]) break ;; [Qq]) cancel ;; esac
  done
fi

# ---------------------------------------------------------------- 1. full, lite or min
header "setup"
echo "   This computer:  $VENDOR $MODEL"
echo "   Processor:      $CPU"
echo "   Memory:         $RAM_GB GB"
echo "   Drive:          /dev/$DISK  $DISK_MODEL  ($DISK_GB GB $DISK_KIND)"
echo
if [ "$RAM_MB" -lt 3000 ]; then
  SUGGEST=M; WHY="it has $RAM_GB GB memory: the lightest desktop leaves the most room for your apps"
elif [ "$RAM_GB" -ge 8 ] && [ "$DISK_GB" -ge 120 ]; then
  SUGGEST=F; WHY="it has $RAM_GB GB memory and a $DISK_GB GB drive"
else
  SUGGEST=L; WHY="it has $RAM_GB GB memory and a $DISK_GB GB drive (full needs 8 GB+ and 120 GB+)"
fi
case "$HW_PROFILE" in   # the hardware check knows more (graphics, Wi-Fi chip, age)
  full) [ "$SUGGEST" = F ] || WHY="the hardware check says it can (memory $RAM_GB GB, drive $DISK_GB GB)"; SUGGEST=F ;;
  lite) [ "$SUGGEST" = L ] || WHY="the hardware check recommends it for this computer's parts"; SUGGEST=L ;;
esac
case "$HW_DISTRO" in   # a 2-3 GB machine: the hardware check steers it to the lightest desktop
  fedora-min) [ "$SUGGEST" = M ] || WHY="the hardware check recommends the lightest desktop (LXQt) for its memory"; SUGGEST=M ;;
esac
echo "   STEP 1: which setup?"
echo
echo "     F = FULL  KDE Plasma desktop, every app: privacy, art, gaming, AI, coding."
echo "     L = LITE  Light Xfce desktop, essential apps only. Best for old or slow PCs."
echo "     M = MIN   Lightest LXQt desktop, essential apps only. For PCs with 2-3 GB"
echo "               of memory: leaves the most room for your apps."
echo
echo "     (A = ATOMIC, experimental. Only if someone set this up for you and asked"
echo "      for it: a locked-down family PC that updates itself as a whole and can go"
echo "      back to the previous version from the start-up menu.)"
echo
case "$SUGGEST" in
  F) echo "   Recommended for this computer: FULL, because $WHY." ;;
  M) echo "   Recommended for this computer: MIN, because $WHY." ;;
  *) echo "   Recommended for this computer: LITE, because $WHY." ;;
esac
echo
if [ "$SETUP_AUTO" = 1 ] && [ -n "$PROFILE" ]; then
  echo "   Using the system you already confirmed in the Setup app: $PROFILE."
else
  while true; do
    answer "Type F, L or M and press Enter (Q to cancel):"
    case "$REPLY_TEXT" in
      [Ff]) PROFILE=full; break ;;
      [Ll]) PROFILE=lite; break ;;
      [Mm]) PROFILE=min; break ;;
      [Aa]) PROFILE=atomic; break ;;
      [Qq]) cancel ;;
    esac
  done
fi
# MIN is for PCs with little memory: the graphical installer would run out of memory there
# (it needs about 4.5 GB), so the installer always uses its simple text screens.
[ "$PROFILE" = min ] && HW_TEXT_INSTALL=1
# A network cable (or phone USB tethering) beats Wi-Fi: when one has carrier, no Wi-Fi questions at all
eth_up() {  # carrier on a non-wireless interface (loopback ignored)
  local i
  for i in /sys/class/net/*; do
    [ "$(basename "$i")" = lo ] && continue
    [ -e "$i/wireless" ] && continue
    [ "$(cat "$i/carrier" 2>/dev/null)" = 1 ] && return 0
  done
  return 1
}
if [ "$SETUP_AUTO" = 1 ] && [ "$WIFI_MODE" = skip ]; then WIFI_STEP=0
elif eth_up; then WIFI_STEP=0
else WIFI_STEP=1
fi
TOTAL=4
[ "$PROFILE" = full ] && TOTAL=$((TOTAL + 1))
[ -d /sys/firmware/efi ] && TOTAL=$((TOTAL + 1))
[ "$WIFI_STEP" = 1 ] && TOTAL=$((TOTAL + 1))
TOTAL=$((TOTAL + 1))   # netboot: the account step (the login name and password are asked, never baked in)
N=1
: > /tmp/secure-linux-choices

# ---------------------------------------------------------------- 2. (full only) optional unfiltered AI model
if [ "$PROFILE" = full ]; then
  N=$((N + 1))
  header "optional AI coding helper"
  echo "   STEP $N of $TOTAL: add the UNFILTERED offline AI coding helper?"
  echo
  echo "   An open-source AI that helps with code (Qwen2.5-Coder 7B, \"abliterated\""
  echo "   = its safety refusals were removed). It runs entirely on this laptop."
  echo "   Size: about 4.7 GB of disk space."
  echo
  echo "   - Good at: writing and explaining short scripts (bash, Python), fixing error"
  echo "     messages, small functions, config files, learning to code."
  echo "   - Not good at: big multi-file projects, long careful reasoning, recent facts."
  echo "     It makes confident mistakes, so test what it writes."
  echo "   - Speed here: runs on the processor (this laptop's graphics aren't supported"
  echo "     for AI): replies at about reading speed after a few seconds; uses 5-6 GB"
  echo "     of memory while running."
  echo "   - Works fully offline and privately: nothing leaves the laptop."
  echo "   - \"Unfiltered\" means it won't refuse. It is not smarter than the normal"
  echo "     version, and it may suggest destructive commands without warning:"
  echo "     never run its commands with sudo (as admin) without reading them first."
  echo
  if [ "$SETUP_AUTO" = 1 ] && [ "$AI_MODEL" != ask ]; then
    echo "ai_abliterated=$AI_MODEL" >> /tmp/secure-linux-choices
    echo "   Using your confirmed choice: $AI_MODEL."
  else
    while true; do
      answer "Add it? Type Y for yes or N for no:"
      case "$REPLY_TEXT" in
        [Yy]) echo "ai_abliterated=yes" >> /tmp/secure-linux-choices; break ;;
        [Nn]) echo "ai_abliterated=no" >> /tmp/secure-linux-choices; break ;;
      esac
    done
  fi
fi

# ---------------------------------------------------------------- Secure Boot (UEFI machines)
SB_NOTE=""
if [ -d /sys/firmware/efi ]; then
  N=$((N + 1))
  SB_NOW=OFF
  SBV=$(od -An -t u1 -j4 -N1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c 2>/dev/null | tr -d ' ')
  [ "$SBV" = 1 ] && SB_NOW=ON
  header "Secure Boot"
  echo "   STEP $N of $TOTAL: Secure Boot (it is $SB_NOW on this computer now)"
  echo
  echo "   1) KEEP SECURE BOOT ON"
  echo "    + Checks at every power-on that nobody tampered with the start-up software"
  echo "      (stops someone with hands-on access planting a fake password screen)."
  echo "    + Later options: unlock with a short PIN using the security chip; remove"
  echo "      the USB stick's boot key."
  echo "    - Closing the lid SLEEPS (uses roughly 1-2% battery an hour) instead of"
  echo "      hibernating: Fedora doesn't allow hibernation with Secure Boot on."
  echo "    - Some drivers (e.g. NVIDIA) need a one-time key approval on a blue screen."
  echo
  echo "   2) TURN SECURE BOOT OFF (you do it once in the BIOS)"
  echo "    + Closing the lid HIBERNATES: zero battery drain, everything comes back as"
  echo "      you left it (you type your encryption passphrase when it wakes)."
  echo "    + Simpler: no blue key-approval screens for the USB stick or drivers."
  echo "    - Start-up software isn't checked: someone with hands-on access could tamper"
  echo "      with it (rare, targeted). Your files stay encrypted either way."
  echo "    - The security-chip PIN unlock isn't available."
  echo
  if [ "$SETUP_AUTO" = 1 ] && [ "$SECURE_BOOT" != ask ]; then
    SB_WANT=$SECURE_BOOT
    echo "   Using your confirmed Secure Boot intention: $SB_WANT."
  else
    while true; do
      answer "Type 1 or 2:"
      case "$REPLY_TEXT" in 1) SB_WANT=on; break ;; 2) SB_WANT=off; break ;; esac
    done
  fi
  echo "secureboot_intent=$SB_WANT" >> /tmp/secure-linux-choices
  if [ "$SETUP_AUTO" = 1 ] && [ "$SECURE_BOOT" != ask ]; then
    : # The intention was reviewed already; the explanatory text below is still shown when relevant.
  elif [ "$SB_WANT" = off ] && [ "$SB_NOW" = ON ]; then
    echo
    echo "   Nothing changes now. After setup, turn it off in the BIOS (ASUS: F2 > Security >"
    echo "   Secure Boot > Disabled; Dell: F2 > Secure Boot). Hibernate turns on by itself then."
    answer "Type C to continue:"
  elif [ "$SB_WANT" = on ] && [ "$SB_NOW" = OFF ]; then
    echo
    echo "   After setup, turn it on in the BIOS (ASUS: F2 > Security > Secure Boot > Enabled;"
    echo "   Dell: F2 > Secure Boot). If you start this USB stick again later, approve its key."
    answer "Type C to continue:"
  fi
else
  SB_NOTE="   (This computer starts in the older BIOS mode, so Secure Boot doesn't apply.)"
fi

# ---------------------------------------------------------------- backup check
N=$((N + 1))
header "backup check"
echo "   STEP $N of $TOTAL: backup check"
echo
cat > /tmp/backups.txt <<'BACKUPS_END'

BACKUPS_END
FOUND=""
for id in "$SID" "$UID_"; do
  [ -n "$id" ] || continue
  # Match only the complete first pipe-delimited field, never a substring of another machine ID.
  FOUND=$(ID=$id awk -F '|' 'BEGIN { id = tolower(ENVIRON["ID"]) } tolower($1) == id { last = $0 } END { if (last != "") print last }' /tmp/backups.txt)
  [ -n "$FOUND" ] && break
done
PARTS=$(lsblk -nro NAME "/dev/$DISK" 2>/dev/null | tail -n +2 | wc -l)
[ -n "$SB_NOTE" ] && { echo "$SB_NOTE"; echo; }
if [ -z "$WIFI_KIND" ]; then
  echo "   (No Wi-Fi networks were saved from this computer's Windows. Next time, run"
  echo "    SAVE-THIS-PC.cmd from the USB stick in Windows first to bring them along.)"
  echo
fi
if [ -n "$FOUND" ]; then
  if [ "$(echo "$FOUND" | cut -d'|' -f5)" = preflight ]; then
    echo "   Backup + pre-flight checks done on $(echo "$FOUND" | cut -d'|' -f3)"
  else
    echo "   A backup of this computer was made on $(echo "$FOUND" | cut -d'|' -f3)"
  fi
  echo "   to $(echo "$FOUND" | cut -d'|' -f4)."
  echo "   This record is metadata only: it does NOT prove that the backup is readable or restorable."
  echo
  [ "$SETUP_AUTO" = 1 ] && [ "$BACKUP_CONTINUE" = yes ] || answer "Type C and press Enter to continue:"
elif [ "$PARTS" -eq 0 ]; then
  echo "   This drive is empty (new or blank), so there is nothing to back up."
  echo
  [ "$SETUP_AUTO" = 1 ] && [ "$BACKUP_CONTINUE" = yes ] || answer "Type C and press Enter to continue:"
else
  echo "   !! NO BACKUP has been recorded for this computer. !!"
  echo
  echo "   Everything on its drive will be deleted. To back it up first:"
  echo "     - Windows PC: start Windows, double-click BUILD-USB.cmd on this USB stick"
  echo "       (linux-setup\\kit) and answer y to the backup question."
  echo "     - Any PC: restart, and choose Clonezilla from this USB stick's menu to"
  echo "       save a full image of the drive to another drive."
  echo
  if [ "$SETUP_AUTO" = 1 ] && [ "$BACKUP_CONTINUE" = yes ]; then
    echo "   You explicitly approved continuing without a new backup in the Setup app."
  else
    while true; do
      answer "Type B to stop and back up first, or C to continue WITHOUT a backup:"
      case "$REPLY_TEXT" in [Bb]) cancel ;; [Cc]) break ;; esac
    done
  fi
fi

# ---------------------------------------------------------------- internet for the install: cable first, then Wi-Fi
umask 077   # before ANY file is written in this step: /tmp/secure-linux-wifi will hold Wi-Fi passwords (B5)
: > /tmp/secure-linux-wifi
if [ "$WIFI_STEP" = 1 ]; then
  N=$((N + 1))
  header "internet for the install"
  echo "   STEP $N of $TOTAL: internet for the install"
  echo
  if eth_up; then
    echo "   A network cable is connected - using it. No Wi-Fi questions needed."
    echo
    sleep 2
  else
    echo "   No network cable is connected, so this computer uses Wi-Fi for the install."
    echo "   (A cable or phone USB tethering works too: type C at the network list.)"
    echo
    # The networks saved from this computer's Windows, if any (the PIN flow is unchanged)
    OPENED=""
    if [ "$WIFI_KIND" = enc1 ]; then
      echo "   This computer's saved Wi-Fi networks were locked with a PIN / password"
      echo "   (chosen when they were saved in Windows)."
      echo
      for try in 1 2 3; do
        printf '   PIN / password: '; read -rs SL_WIFI_PIN || cancel; echo
        if SL_WIFI_PIN=$SL_WIFI_PIN python3 /tmp/sl-wifi.py open /tmp/sl-wifi-record /tmp/sl-wifi-bundle >/tmp/sl-wifi-count 2>/dev/null; then OPENED=1; break; fi
        echo "   That's not it."
      done
      SL_WIFI_PIN=""
    elif [ -n "$WIFI_KIND" ]; then
      python3 /tmp/sl-wifi.py open /tmp/sl-wifi-record /tmp/sl-wifi-bundle >/tmp/sl-wifi-count 2>/dev/null && OPENED=1
    fi
    if [ -z "$OPENED" ] && [ -n "$WIFI_KIND" ]; then
      # The saved networks can't be opened (for example 3 wrong PINs): say so, then fall THROUGH to
      # the normal scan-and-pick flow below. (B2, 2026-11-04: this used to be a dead-end question,
      # "Type C to continue without them", that only wasted a question before the same flow.)
      echo
      echo "   The Wi-Fi networks can't be opened, so they are skipped. You can connect"
      echo "   to Wi-Fi after the install by clicking the Wi-Fi icon."
      echo
    fi
    # Setup-App can pre-answer a saved home network, but only from the existing save-wifi record.
    # A protected record still asks for its PIN. No match, no password or no record falls through to every normal question.
    AUTO_WIFI_DONE=""
    if [ "$SETUP_AUTO" = 1 ] && [ "$WIFI_MODE" = saved ] && [ -n "$OPENED" ] && [ -n "$WIFI_SSID_B64" ]; then
      AUTO_WIFI_NAME=$(printf '%s' "$WIFI_SSID_B64" | base64 -d 2>/dev/null)
      AUTO_WIFI_IDX=$(python3 /tmp/sl-wifi.py list /tmp/sl-wifi-bundle | awk -F'|' -v s="$AUTO_WIFI_NAME" '$2 == s { print $1; exit }')
      if [ -n "$AUTO_WIFI_IDX" ]; then
        sed -n "${AUTO_WIFI_IDX}p" /tmp/sl-wifi-bundle > /tmp/secure-linux-wifi
        AUTO_WIFI_DONE=1
        echo "   Using the home Wi-Fi network you selected in Windows: $AUTO_WIFI_NAME"
        echo "   Its existing saved record is carried over to the installed Linux too."
      else
        echo "   The selected home network is not in this computer's saved record; the normal list follows."
      fi
    fi
    if [ -z "$AUTO_WIFI_DONE" ]; then   # no setup.conf: exactly the original interactive body
      wifi_scan() {  # visible networks -> /tmp/sl-scan (name|signal|security, strongest first); 1 = cannot scan here
        : > /tmp/sl-scan
        command -v nmcli >/dev/null 2>&1 || return 1
        nmcli dev wifi rescan >/dev/null 2>&1
        # nmcli -t escapes a ':' inside a name as '\:': take the security and signal fields from the right
        nmcli -t -f SSID,SIGNAL,SECURITY dev wifi list 2>/dev/null | while IFS= read -r l; do
          [ -n "$l" ] || continue
          sec=${l##*:}; rest=${l%:*}
          sig=${rest##*:}; ssid=${rest%:*}
          ssid=${ssid//\\:/:}
          case "$sig" in ''|*[!0-9]*) continue ;; esac
          [ -n "$ssid" ] && printf '%s|%s|%s\n' "$ssid" "$sig" "$sec"
        done | sort -t'|' -k2,2nr | awk -F'|' '!seen[$1]++' > /tmp/sl-scan
        return 0
      }
      wifi_fix() {  # the usual culprits: Wi-Fi switched off in the firmware, or a stuck network service
        sl_pre_begin 'Switching on Wi-Fi and restarting the network service. No percentage is available.'
        rfkill unblock all >/dev/null 2>&1
        nmcli radio wifi on >/dev/null 2>&1
        systemctl restart NetworkManager >/dev/null 2>&1
        sleep 4
        sl_pre_end 'Wi-Fi restart finished.'
      }
      eth_cable() {  # wait for a network cable (or phone USB tethering) instead of Wi-Fi
        echo
        echo "   Plug in a network cable (or connect the phone by USB and turn on 'USB tethering')."
        while true; do
          answer "   Type C when it is connected (B to go back to the Wi-Fi list):"
          case "$REPLY_TEXT" in
            [Cc]) if eth_up; then echo "   The cable is connected - using it."; return 0; fi
                  echo "   Still no cable found. Check it clicks in at both ends." ;;
            [Bb]) return 1 ;;
          esac
        done
      }
      connect_ok() {  # nmcli's general state starts with "connected" once anything is online
        case "$(nmcli -t -f STATE general 2>/dev/null)" in connected*) return 0 ;; esac
        return 1
      }
      connect_saved() {  # $1 = line number in the saved bundle, $2 = network name as shown
        local bl sec pw
        bl=$(sed -n "$1p" /tmp/sl-wifi-bundle)
        sec=$(printf '%s' "$bl" | cut -d'|' -f2)
        pw=$(printf '%s' "$bl" | cut -d'|' -f3 | base64 -d 2>/dev/null)
        echo "   Connecting to $2 ..."
        if [ "$sec" = none ]; then nmcli dev wifi connect "$2" >/dev/null 2>&1
        else nmcli dev wifi connect "$2" password "$pw" >/dev/null 2>&1; fi
        sleep 2
        if connect_ok; then
          sed -n "$1p" /tmp/sl-wifi-bundle >> /tmp/secure-linux-wifi
          echo "   Connected to $2. It is carried over to the installed Linux too."
          return 0
        fi
        return 1
      }
      connect_new() {  # $1 = name, $2 = security from the scan ("" for a typed name), $3 = password, $4 = hidden 0/1
        local km=none extra=""
        case "$2" in *WPA3*) km=sae ;; *WPA*|*wpa*) km=wpa-psk ;; esac
        [ -n "$3" ] && [ "$km" = none ] && km=wpa-psk   # a typed name with a password: WPA2 is the usual case
        [ "$4" = 1 ] && extra="hidden yes"
        echo "   Connecting to $1 ..."
        if [ -z "$3" ]; then nmcli dev wifi connect "$1" $extra >/dev/null 2>&1
        else nmcli dev wifi connect "$1" password "$3" $extra >/dev/null 2>&1; fi
        sleep 2
        if connect_ok; then
          printf '%s|%s|%s|%s\n' "$(printf '%s' "$1" | base64 -w0)" "$km" "$(printf '%s' "$3" | base64 -w0)" "$4" >> /tmp/secure-linux-wifi
          echo "   Connected to $1. It is carried over to the installed Linux too."
          return 0
        fi
        return 1
      }
      NO_SCAN=""
      sl_pre_begin 'Looking for Wi-Fi networks. No percentage is available for a scan.'
      wifi_scan || NO_SCAN=1
      sl_pre_end 'Wi-Fi scan finished.'
      WIFI_DONE=""; FIXTRIED=""; ASKED_SAVED=""
      while [ -z "$NO_SCAN" ] && [ -z "$WIFI_DONE" ]; do
        if [ ! -s /tmp/sl-scan ]; then
          if [ -n "$FIXTRIED" ]; then NO_SCAN=1; break; fi   # still nothing after the fix: the no-scan path below
          echo "   The Wi-Fi card can't see any networks right now."
          while true; do
            answer "   Type F to try to fix it, or C to plug in a network cable instead:"
            case "$REPLY_TEXT" in
              [Ff]) FIXTRIED=1; wifi_fix; wifi_scan; break ;;
              [Cc]) if eth_cable; then WIFI_DONE=cable; break; fi ;;
            esac
          done
          continue
        fi
        # The saved networks that are in range right now (never mentioned when none are).
        # Names are matched literally against the scan; a saved network whose name is not printable
        # text is shown as "hex:..." (see sl-wifi.py display_name) and can never match a scanned
        # name, so it is simply not offered as "saved" - it can still be picked from the list (B9).
        : > /tmp/sl-saved-in-range
        if [ -n "$OPENED" ]; then
          python3 /tmp/sl-wifi.py list /tmp/sl-wifi-bundle | while IFS='|' read -r bi bname bsec; do
            if awk -F'|' -v s="$bname" '$1 == s { f=1 } END { exit !f }' /tmp/sl-scan; then
              printf '%s|%s\n' "$bi" "$bname" >> /tmp/sl-saved-in-range
            fi
          done
        fi
        SAVED_N=$(grep -c . /tmp/sl-saved-in-range 2>/dev/null || true)
        # Exactly one saved network in range: one-tap connect; N falls through to the list
        if [ "$SAVED_N" = 1 ] && [ -z "$ASKED_SAVED" ]; then
          ASKED_SAVED=1
          S_IDX=$(cut -d'|' -f1 /tmp/sl-saved-in-range)
          S_ONE=$(cut -d'|' -f2 /tmp/sl-saved-in-range)
          echo "   $S_ONE is available. Do you want to connect to that network automatically? (Y/N/Q)"
          while true; do
            answer "   Type 'N' to connect to a different network, or 'Q' to skip Wi-Fi for now:"
            case "$REPLY_TEXT" in
              [Yy])
                if connect_saved "$S_IDX" "$S_ONE"; then WIFI_DONE=wifi; break; fi
                echo "   That didn't work. Pick one from the list instead."
                break ;;
              [Nn]) break ;;
              [Qq]) WIFI_DONE=skip; break ;;   # B6: an always-available way out of the Wi-Fi step
            esac
          done
          [ -n "$WIFI_DONE" ] && break
        fi
        # The list: saved-and-in-range first (password known), then the rest, strongest signal first
        echo "   Networks the Wi-Fi card can see:"
        echo
        : > /tmp/sl-menu
        MN=0
        if [ "$SAVED_N" -ge 1 ]; then
          while IFS='|' read -r bi bname; do
            MN=$((MN + 1))
            printf '%s|saved|%s|%s\n' "$MN" "$bi" "$bname" >> /tmp/sl-menu
            printf '     %2d)  %-32.32s saved - password known\n' "$MN" "$bname"
          done < /tmp/sl-saved-in-range
        fi
        while IFS='|' read -r ssid sig sec; do
          dup=""
          if [ "$SAVED_N" -ge 1 ]; then
            while IFS='|' read -r bi bname; do [ "$bname" = "$ssid" ] && { dup=1; break; }; done < /tmp/sl-saved-in-range
          fi
          [ -n "$dup" ] && continue
          MN=$((MN + 1))
          printf '%s|scan|%s|%s\n' "$MN" "$ssid" "$sec" >> /tmp/sl-menu
          case "$sec" in ''|'--') slbl='open (no password)' ;; *) slbl=$sec ;; esac
          printf '     %2d)  %-32.32s %3s%%  %s\n' "$MN" "$ssid" "$sig" "$slbl"
        done < /tmp/sl-scan
        echo
        echo "      C)  I'll plug in a network cable instead"
        echo "      O)  other network (a hidden one - type its name)"
        echo "      Q)  skip Wi-Fi for now (set it up after the install)"
        echo
        while true; do
          answer "   Type a number, C, O or Q:"
          case "$REPLY_TEXT" in
            [Qq]) WIFI_DONE=skip; break ;;   # B6: an always-available way out of the Wi-Fi step
            [Cc]) if eth_cable; then WIFI_DONE=cable; fi; break ;;
            [Oo])
              answer "   Network name, exactly as it is written:"
              H_SSID=$REPLY_TEXT
              printf '   Password (just press Enter for an open network): '; read -rs H_PW || cancel; echo
              if connect_new "$H_SSID" "" "$H_PW" 1; then WIFI_DONE=wifi
              else
                echo "   Couldn't connect to '$H_SSID'."
                while true; do
                  answer "   Type R to pick another network, F to try to fix it, or C for a cable:"
                  case "$REPLY_TEXT" in
                    [Rr]) break ;;
                    [Ff]) wifi_fix; wifi_scan; break ;;   # B7: re-scan so a revived card's networks show up
                    [Cc]) if eth_cable; then WIFI_DONE=cable; fi; break ;;
                  esac
                done
              fi
              break ;;
            *[!0-9]*) ;;   # not a number: ask again
            *)
              m=$(awk -F'|' -v n="$REPLY_TEXT" '$1 == n' /tmp/sl-menu)
              if [ -z "$m" ]; then continue; fi
              kind=$(printf '%s' "$m" | cut -d'|' -f2)
              if [ "$kind" = saved ]; then
                S_IDX=$(printf '%s' "$m" | cut -d'|' -f3); S_ONE=$(printf '%s' "$m" | cut -d'|' -f4)
                if connect_saved "$S_IDX" "$S_ONE"; then WIFI_DONE=wifi; break; fi
                echo "   That didn't work - the saved password may be out of date. Pick another, or C for a cable."
                break
              fi
              ssid=$(printf '%s' "$m" | cut -d'|' -f3); sec=$(printf '%s' "$m" | cut -d'|' -f4)
              case "$sec" in *WEP*)
                echo "   '$ssid' uses the old, unsafe WEP security, which isn't supported. Pick another."
                continue ;;
              esac
              PW=""
              case "$sec" in ''|'--') ;; *)
                printf '   Password for %s: ' "$ssid"; read -rs PW || cancel; echo ;;
              esac
              if connect_new "$ssid" "$sec" "$PW" 0; then WIFI_DONE=wifi; break; fi
              echo "   Couldn't connect to '$ssid' (wrong password?)."
              while true; do
                answer "   Type R to pick another network, F to try to fix it, or C for a cable:"
                case "$REPLY_TEXT" in
                  [Rr]) break ;;
                  [Ff]) wifi_fix; wifi_scan; break ;;   # B7: re-scan so a revived card's networks show up
                  [Cc]) if eth_cable; then WIFI_DONE=cable; fi; break ;;
                esac
              done
              break ;;
          esac
        done
      done
      if [ -n "$NO_SCAN" ]; then
        # Scanning is impossible here (the installer has no driver for this Wi-Fi chip, or no networks
        # were left after the fix): the original saved-networks behaviour - all, one by one, or none.
        if [ -n "$OPENED" ]; then
          WIFI_N=$(cat /tmp/sl-wifi-count)
          echo "   $WIFI_N Wi-Fi network(s) from this computer's Windows are on the stick:"
          echo
          python3 /tmp/sl-wifi.py list /tmp/sl-wifi-bundle | while IFS='|' read -r i name sec; do printf '     %2s)  %-32.32s %s\n' "$i" "$name" "$sec"; done
          echo
          while true; do
            answer "Add them to Linux? A = all, C = choose one by one, N = none:"
            case "$REPLY_TEXT" in
              [Aa]) cp /tmp/sl-wifi-bundle /tmp/secure-linux-wifi; break ;;
              [Nn]) break ;;
              [Cc])
                i=0
                python3 /tmp/sl-wifi.py list /tmp/sl-wifi-bundle > /tmp/sl-wifi-names
                while IFS='|' read -r i name sec <&3; do
                  while true; do
                    answer "Add '$name' ($sec)? Y or N:"
                    case "$REPLY_TEXT" in [Yy]) sed -n "${i}p" /tmp/sl-wifi-bundle >> /tmp/secure-linux-wifi; break ;; [Nn]) break ;; esac
                  done
                done 3< /tmp/sl-wifi-names
                break ;;
            esac
          done
        else
          echo "   Wi-Fi can't be scanned during the install on this computer."
          echo "   A network cable or phone USB tethering always works; the next screen offers that."
        fi
      fi
      if [ -s /tmp/secure-linux-wifi ]; then
        echo
        echo "   $(grep -c . /tmp/secure-linux-wifi) Wi-Fi network(s) will be added to the installed Linux."
        sleep 2
      fi
    fi
    rm -f /tmp/sl-wifi-bundle /tmp/sl-wifi-record /tmp/sl-wifi-names /tmp/sl-scan /tmp/sl-menu /tmp/sl-saved-in-range
    umask 022
  fi
fi

# ---------------------------------------------------------------- erase confirmation
N=$((N + 1))
header "erase the drive"
echo "   STEP $N of $TOTAL: erase this computer's drive"
echo
echo "   This drive will be COMPLETELY ERASED:"
echo "     /dev/$DISK  $DISK_MODEL  ($DISK_GB GB $DISK_KIND). It contains now:"
lsblk -no NAME,SIZE,FSTYPE,LABEL "/dev/$DISK" 2>/dev/null | sed 's/^/       /'
echo
PDISP=$PROFILE; [ "$PROFILE" = min ] && PDISP="min (light LXQt desktop)"
echo "   Then the Complete Secure Linux Package ($PDISP) is installed,"
echo "   with full-disk encryption, and all apps install by themselves."
echo
# The Setup app may preselect a drive, but it can never pre-authorize this final destructive step.
# BACKUP_CONTINUE and TARGET_DISK_ERASE deliberately have no effect here.
answer "Type ERASE (in capitals) to continue, or anything else to cancel:"
[ "$REPLY_TEXT" = "ERASE" ] || cancel

# ---------------------------------------------------------------- encryption passphrase
# The EFF short word list 1 (1296 words), (c) Electronic Frontier Foundation, CC BY 3.0 US,
# https://www.eff.org/dice . 5 words = about 52 bits, enough with LUKS2's slow Argon2id unlock.
cat > /tmp/sl-words.txt <<'WORDS_END'
acid
acorn
acre
acts
afar
affix
aged
agent
agile
aging
agony
ahead
aide
aids
aim
ajar
alarm
alias
alibi
alien
alike
alive
aloe
aloft
aloha
alone
amend
amino
ample
amuse
angel
anger
angle
ankle
apple
april
apron
aqua
area
arena
argue
arise
armed
armor
army
aroma
array
arson
art
ashen
ashes
atlas
atom
attic
audio
avert
avoid
awake
award
awoke
axis
bacon
badge
bagel
baggy
baked
baker
balmy
banjo
barge
barn
bash
basil
bask
batch
bath
baton
bats
blade
blank
blast
blaze
bleak
blend
bless
blimp
blink
bloat
blob
blog
blot
blunt
blurt
blush
boast
boat
body
boil
bok
bolt
boned
boney
bonus
bony
book
booth
boots
boss
botch
both
boxer
breed
bribe
brick
bride
brim
bring
brink
brisk
broad
broil
broke
brook
broom
brush
buck
bud
buggy
bulge
bulk
bully
bunch
bunny
bunt
bush
bust
busy
buzz
cable
cache
cadet
cage
cake
calm
cameo
canal
candy
cane
canon
cape
card
cargo
carol
carry
carve
case
cash
cause
cedar
chain
chair
chant
chaos
charm
chase
cheek
cheer
chef
chess
chest
chew
chief
chili
chill
chip
chomp
chop
chow
chuck
chump
chunk
churn
chute
cider
cinch
city
civic
civil
clad
claim
clamp
clap
clash
clasp
class
claw
clay
clean
clear
cleat
cleft
clerk
click
cling
clink
clip
cloak
clock
clone
cloth
cloud
clump
coach
coast
coat
cod
coil
coke
cola
cold
colt
coma
come
comic
comma
cone
cope
copy
coral
cork
cost
cot
couch
cough
cover
cozy
craft
cramp
crane
crank
crate
crave
crawl
crazy
creme
crepe
crept
crib
cried
crisp
crook
crop
cross
crowd
crown
crumb
crush
crust
cub
cult
cupid
cure
curl
curry
curse
curve
curvy
cushy
cut
cycle
dab
dad
daily
dairy
daisy
dance
dandy
darn
dart
dash
data
date
dawn
deaf
deal
dean
debit
debt
debug
decaf
decal
decay
deck
decor
decoy
deed
delay
denim
dense
dent
depth
derby
desk
dial
diary
dice
dig
dill
dime
dimly
diner
dingy
disco
dish
disk
ditch
ditzy
dizzy
dock
dodge
doing
doll
dome
donor
donut
dose
dot
dove
down
dowry
doze
drab
drama
drank
draw
dress
dried
drift
drill
drive
drone
droop
drove
drown
drum
dry
duck
duct
dude
dug
duke
duo
dusk
dust
duty
dwarf
dwell
eagle
early
earth
easel
east
eaten
eats
ebay
ebony
ebook
echo
edge
eel
eject
elbow
elder
elf
elk
elm
elope
elude
elves
email
emit
empty
emu
enter
entry
envoy
equal
erase
error
erupt
essay
etch
evade
even
evict
evil
evoke
exact
exit
fable
faced
fact
fade
fall
false
fancy
fang
fax
feast
feed
femur
fence
fend
ferry
fetal
fetch
fever
fiber
fifth
fifty
film
filth
final
finch
fit
five
flag
flaky
flame
flap
flask
fled
flick
fling
flint
flip
flirt
float
flock
flop
floss
flyer
foam
foe
fog
foil
folic
folk
food
fool
found
fox
foyer
frail
frame
fray
fresh
fried
frill
frisk
from
front
frost
froth
frown
froze
fruit
gag
gains
gala
game
gap
gas
gave
gear
gecko
geek
gem
genre
gift
gig
gills
given
giver
glad
glass
glide
gloss
glove
glow
glue
goal
going
golf
gong
good
gooey
goofy
gore
gown
grab
grain
grant
grape
graph
grasp
grass
grave
gravy
gray
green
greet
grew
grid
grief
grill
grip
grit
groom
grope
growl
grub
grunt
guide
gulf
gulp
gummy
guru
gush
gut
guy
habit
half
halo
halt
happy
harm
hash
hasty
hatch
hate
haven
hazel
hazy
heap
heat
heave
hedge
hefty
help
herbs
hers
hub
hug
hula
hull
human
humid
hump
hung
hunk
hunt
hurry
hurt
hush
hut
ice
icing
icon
icy
igloo
image
ion
iron
islam
issue
item
ivory
ivy
jab
jam
jaws
jazz
jeep
jelly
jet
jiffy
job
jog
jolly
jolt
jot
joy
judge
juice
juicy
july
jumbo
jump
junky
juror
jury
keep
keg
kept
kick
kilt
king
kite
kitty
kiwi
knee
knelt
koala
kung
ladle
lady
lair
lake
lance
land
lapel
large
lash
lasso
last
latch
late
lazy
left
legal
lemon
lend
lens
lent
level
lever
lid
life
lift
lilac
lily
limb
limes
line
lint
lion
lip
list
lived
liver
lunar
lunch
lung
lurch
lure
lurk
lying
lyric
mace
maker
malt
mama
mango
manor
many
map
march
mardi
marry
mash
match
mate
math
moan
mocha
moist
mold
mom
moody
mop
morse
most
motor
motto
mount
mouse
mousy
mouth
move
movie
mower
mud
mug
mulch
mule
mull
mumbo
mummy
mural
muse
music
musky
mute
nacho
nag
nail
name
nanny
nap
navy
near
neat
neon
nerd
nest
net
next
niece
ninth
nutty
oak
oasis
oat
ocean
oil
old
olive
omen
onion
only
ooze
opal
open
opera
opt
otter
ouch
ounce
outer
oval
oven
owl
ozone
pace
pagan
pager
palm
panda
panic
pants
panty
paper
park
party
pasta
patch
path
patio
payer
pecan
penny
pep
perch
perky
perm
pest
petal
petri
petty
photo
plank
plant
plaza
plead
plot
plow
pluck
plug
plus
poach
pod
poem
poet
pogo
point
poise
poker
polar
polio
polka
polo
pond
pony
poppy
pork
poser
pouch
pound
pout
power
prank
press
print
prior
prism
prize
probe
prong
proof
props
prude
prune
pry
pug
pull
pulp
pulse
puma
punch
punk
pupil
puppy
purr
purse
push
putt
quack
quake
query
quiet
quill
quilt
quit
quota
quote
rabid
race
rack
radar
radio
raft
rage
raid
rail
rake
rally
ramp
ranch
range
rank
rant
rash
raven
reach
react
ream
rebel
recap
relax
relay
relic
remix
repay
repel
reply
rerun
reset
rhyme
rice
rich
ride
rigid
rigor
rinse
riot
ripen
rise
risk
ritzy
rival
river
roast
robe
robin
rock
rogue
roman
romp
rope
rover
royal
ruby
rug
ruin
rule
runny
rush
rust
rut
sadly
sage
said
saint
salad
salon
salsa
salt
same
sandy
santa
satin
sauna
saved
savor
sax
say
scale
scam
scan
scare
scarf
scary
scoff
scold
scoop
scoot
scope
score
scorn
scout
scowl
scrap
scrub
scuba
scuff
sect
sedan
self
send
sepia
serve
set
seven
shack
shade
shady
shaft
shaky
sham
shape
share
sharp
shed
sheep
sheet
shelf
shell
shine
shiny
ship
shirt
shock
shop
shore
shout
shove
shown
showy
shred
shrug
shun
shush
shut
shy
sift
silk
silly
silo
sip
siren
sixth
size
skate
skew
skid
skier
skies
skip
skirt
skit
sky
slab
slack
slain
slam
slang
slash
slate
slaw
sled
sleek
sleep
sleet
slept
slice
slick
slimy
sling
slip
slit
slob
slot
slug
slum
slurp
slush
small
smash
smell
smile
smirk
smog
snack
snap
snare
snarl
sneak
sneer
sniff
snore
snort
snout
snowy
snub
snuff
speak
speed
spend
spent
spew
spied
spill
spiny
spoil
spoke
spoof
spool
spoon
sport
spot
spout
spray
spree
spur
squad
squat
squid
stack
staff
stage
stain
stall
stamp
stand
stank
stark
start
stash
state
stays
steam
steep
stem
step
stew
stick
sting
stir
stock
stole
stomp
stony
stood
stool
stoop
stop
storm
stout
stove
straw
stray
strut
stuck
stud
stuff
stump
stung
stunt
suds
sugar
sulk
surf
sushi
swab
swan
swarm
sway
swear
sweat
sweep
swell
swept
swim
swing
swipe
swirl
swoop
swore
syrup
tacky
taco
tag
take
tall
talon
tamer
tank
taper
taps
tarot
tart
task
taste
tasty
taunt
thank
thaw
theft
theme
thigh
thing
think
thong
thorn
those
throb
thud
thumb
thump
thus
tiara
tidal
tidy
tiger
tile
tilt
tint
tiny
trace
track
trade
train
trait
trap
trash
tray
treat
tree
trek
trend
trial
tribe
trick
trio
trout
truce
truck
trump
trunk
try
tug
tulip
tummy
turf
tusk
tutor
tutu
tux
tweak
tweet
twice
twine
twins
twirl
twist
uncle
uncut
undo
unify
union
unit
untie
upon
upper
urban
used
user
usher
utter
value
vapor
vegan
venue
verse
vest
veto
vice
video
view
viral
virus
visa
visor
vixen
vocal
voice
void
volt
voter
vowel
wad
wafer
wager
wages
wagon
wake
walk
wand
wasp
watch
water
wavy
wheat
whiff
whole
whoop
wick
widen
widow
width
wife
wifi
wilt
wimp
wind
wing
wink
wipe
wired
wiry
wise
wish
wispy
wok
wolf
womb
wool
woozy
word
work
worry
wound
woven
wrath
wreck
wrist
xerox
yahoo
yam
yard
year
yeast
yelp
yield
yo-yo
yodel
yoga
yoyo
yummy
zebra
zero
zesty
zippy
zone
zoom
WORDS_END
gen_passphrase() {   # 5 random words from /dev/urandom (unbiased: values >= 64800 are re-drawn)
  local i v
  mapfile -t WL < /tmp/sl-words.txt
  [ ${#WL[@]} -eq 1296 ] || return 1
  PP=""
  for i in 1 2 3 4 5; do
    while true; do
      v=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
      [ -n "$v" ] && [ "$v" -lt 64800 ] && break
    done
    PP="${PP:+$PP }${WL[$((v % 1296))]}"
  done
  WL=()
}
N=$((N + 1))
PW1=""
while [ -z "$PW1" ]; do
  header "encryption passphrase"
  echo "   STEP $N of $TOTAL: disk-encryption passphrase"
  echo
  echo "   Everything on this computer is encrypted. You type this passphrase EVERY"
  echo "   time the computer turns on. If it is lost or stolen, nobody can read your"
  echo "   files without it. If YOU lose it, your files are gone forever: no reset."
  echo
  echo "   Write it on paper kept safe at home (never with the computer) AND save it"
  echo "   in Bitwarden. It's separate from your login password."
  echo
  echo "     G = make one for me: 5 random words, e.g. 'tulip orbit canvas mango zebra'"
  echo "         (recommended: strong and easy to type)"
  echo "     O = I'll type my own (12 or more characters)"
  echo
  while true; do
    answer "Type G or O (Q to cancel):"
    case "$REPLY_TEXT" in [Gg]) MODE=gen; break ;; [Oo]) MODE=own; break ;; [Qq]) cancel ;; esac
  done
  if [ "$MODE" = gen ]; then
    if ! gen_passphrase; then echo "   Couldn't make one here. Please type your own."; MODE=own; sleep 3
    else
      while true; do
        header "encryption passphrase"
        echo "   Your passphrase (5 words, small letters, one space between words):"
        echo
        echo "   +----------------------------------------------------------------+"
        echo "   |                                                                |"
        printf '   |     %-58s |\n' "$PP"
        echo "   |                                                                |"
        echo "   +----------------------------------------------------------------+"
        echo
        echo "   Write it down now, exactly. Then type it below to show it's right."
        echo "   (N = give me different words)"
        echo
        printf '   Type it: '; read -r T || cancel
        if [ "$T" = "$PP" ]; then PW1=$PP; break; fi
        case "$T" in [Nn]) gen_passphrase; continue ;; esac
        echo "   That's not the same. Check your paper and try again."; sleep 3
      done
      PP=""; T=""
      printf '\033c'
    fi
  fi
  if [ "$MODE" = own ]; then
    echo
    echo "   Use only plain letters, numbers, spaces and symbols from an English (US)"
    echo "   keyboard: no accents or emoji. The power-on screen may use a different"
    echo "   keyboard layout from the one you are used to, so special letters could"
    echo "   become impossible to type."
    echo
    while true; do
      printf '   Encryption passphrase: '; read -rs P1 || cancel; echo
      printf '   Type it again:         '; read -rs P2 || cancel; echo
      if [ "$P1" != "$P2" ]; then echo "   They don't match. Try again."; echo; continue; fi
      if [ ${#P1} -lt 12 ]; then echo "   Too short: use at least 12 characters (4 words is easiest)."; echo; continue; fi
      if (LC_ALL=C; case "$P1" in *[!\ -~]*) exit 0 ;; *) exit 1 ;; esac); then
        echo "   Only plain English-keyboard characters, please (no accents or emoji)."; echo; continue
      fi
      break
    done
    PW1=$P1; P1=""; P2=""
  fi
done

# ---------------------------------------------------------------- netboot: your login account
# (This block exists only in the netboot build.) The USB build bakes the login name and a password
# hash into the installer when the stick is made; a public file on the internet can hold neither,
# so the netboot installer asks here instead. The password is turned into a one-way SHA-512 crypt
# hash right away, with the kit's own pure-Python hasher (tests/sha512crypt.py - the installer's
# Python 3.13 has no crypt module, and openssl may not be in the installer image). Only the hash is
# written down (/tmp/user.ks); the typed password lives in shell variables that are cleared below,
# is never logged and never sent anywhere.
N=$((N + 1))
header "your login"
echo "   STEP $N of $TOTAL: your login"
echo
echo "   Make the login for this computer. The name appears on the login screen; the"
echo "   password is what you type to sign in (and for admin tasks with sudo)."
echo
while true; do
  answer "Your name (shown on the login screen):"
  NB_FULL=$REPLY_TEXT
  case "$NB_FULL" in *:*|*'"'*|*\\*) echo "   Please no colons, quotes or backslashes." ;; *) break ;; esac
done
while true; do
  answer "Login name (small letters, e.g. alex):"
  NB_USER=$(printf '%s' "$REPLY_TEXT" | tr 'A-Z' 'a-z')
  case "$NB_USER" in ''|*[!a-z0-9_-]*) echo "   Small letters, digits, '-' and '_' only."; continue ;; esac
  case "$NB_USER" in [a-z_]*) ;; *) echo "   The first character must be a small letter or '_'."; continue ;; esac
  [ ${#NB_USER} -le 32 ] || { echo "   32 characters at most."; continue; }
  break
done
echo
echo "   The password: 8 or more characters, plain English-keyboard letters, numbers"
echo "   and symbols only (no accents or emoji - some screens use a different keyboard"
echo "   layout, so special letters could become impossible to type)."
echo
while true; do
  printf '   Login password: '; read -rs NB_P1 || cancel; echo
  printf '   Type it again:  '; read -rs NB_P2 || cancel; echo
  if [ "$NB_P1" != "$NB_P2" ]; then echo "   They don't match. Try again."; NB_P1=""; NB_P2=""; continue; fi
  if [ ${#NB_P1} -lt 8 ]; then echo "   Too short: use at least 8 characters."; NB_P1=""; NB_P2=""; continue; fi
  if (LC_ALL=C; case "$NB_P1" in *[!\ -~]*) exit 0 ;; *) exit 1 ;; esac); then
    echo "   Only plain English-keyboard characters, please (no accents or emoji)."; NB_P1=""; NB_P2=""; continue
  fi
  break
done
cat > /tmp/sl_sha512crypt.py <<'SHA512CRYPT_END'
"""Pure-Python SHA-512 crypt ($6$), written from Ulrich Drepper's specification
(https://www.akkadia.org/drepper/SHA-crypt.txt). Used only to cross-check the
openssl hash that make-usb.ps1 produces. Python 3.13 removed the crypt module.

    python sha512crypt.py PASSWORD SALT [ROUNDS]
"""
import hashlib
import sys

B64 = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"


def _b64_from_24bit(b2, b1, b0, n):
    w = (b2 << 16) | (b1 << 8) | b0
    out = ""
    for _ in range(n):
        out += B64[w & 0x3F]
        w >>= 6
    return out


def sha512_crypt(password: bytes, salt: bytes, rounds: int = 5000) -> str:
    custom_rounds = rounds != 5000
    rounds = max(1000, min(rounds, 999999999))
    salt = salt[:16]
    pl, sl = len(password), len(salt)

    b = hashlib.sha512(password + salt + password).digest()
    a = hashlib.sha512(password + salt)
    n = pl
    while n > 64:
        a.update(b)
        n -= 64
    a.update(b[:n])
    n = pl
    while n > 0:
        a.update(b if n & 1 else password)
        n >>= 1
    a = a.digest()

    dp = hashlib.sha512(password * pl).digest()
    p = (dp * (pl // 64 + 1))[:pl]
    ds = hashlib.sha512(salt * (16 + a[0])).digest()
    s = (ds * (sl // 64 + 1))[:sl]

    c = a
    for i in range(rounds):
        h = hashlib.sha512()
        h.update(p if i & 1 else c)
        if i % 3:
            h.update(s)
        if i % 7:
            h.update(p)
        h.update(c if i & 1 else p)
        c = h.digest()

    order = [(0, 21, 42), (22, 43, 1), (44, 2, 23), (3, 24, 45), (25, 46, 4), (47, 5, 26),
             (6, 27, 48), (28, 49, 7), (50, 8, 29), (9, 30, 51), (31, 52, 10), (53, 11, 32),
             (12, 33, 54), (34, 55, 13), (56, 14, 35), (15, 36, 57), (37, 58, 16), (59, 17, 38),
             (18, 39, 60), (40, 61, 19), (62, 20, 41)]
    enc = "".join(_b64_from_24bit(c[x], c[y], c[z], 4) for x, y, z in order)
    enc += _b64_from_24bit(0, 0, c[63], 2)
    prefix = "$6$" + (f"rounds={rounds}$" if custom_rounds else "")
    return prefix + salt.decode("ascii") + "$" + enc


def _selftest():
    # Test vectors from the specification
    vectors = [
        (b"Hello world!", b"saltstring", 5000,
         "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1"),
        (b"Hello world!", b"saltstringsaltstring", 10000,
         "$6$rounds=10000$saltstringsaltst$OW1/O6BYHV6BcXZu8QVeXbDWra3Oeqh0sbHbbMCVNSnCM/UrjmM0Dp8vOuZeHBy/YTBmSK6H9qs/y3RnOaw5v."),
    ]
    for pw, salt, rounds, want in vectors:
        got = sha512_crypt(pw, salt, rounds)
        assert got == want, (got, want)


if __name__ == "__main__":
    _selftest()
    r = int(sys.argv[3]) if len(sys.argv) > 3 else 5000
    print(sha512_crypt(sys.argv[1].encode("utf-8"), sys.argv[2].encode("ascii"), r))
SHA512CRYPT_END
NB_SALT=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n' | cut -c1-16)
NB_HASH=$(NB_PW=$NB_P1 NB_SALT=$NB_SALT python3 -c 'import os,sys; sys.path.insert(0,"/tmp"); from sl_sha512crypt import sha512_crypt; sys.stdout.write(sha512_crypt(os.environ["NB_PW"].encode(), os.environ["NB_SALT"].encode()))')
NB_P1=""; NB_P2=""; rm -f /tmp/sl_sha512crypt.py
case "$NB_HASH" in \$6\$????????????????\$*) ;; *) echo "   Could not hash the password (the installer is missing python3)."; cancel ;; esac
umask 077
QFN=${NB_FULL//\\/\\\\}; QFN=${QFN//\"/\\\"}
printf 'user --name=%s --gecos="%s" --groups=wheel --iscrypted --password=%s\n' "$NB_USER" "$QFN" "$NB_HASH" > /tmp/user.ks
printf 'sl_username=%s\n' "$NB_USER" >> /tmp/secure-linux-choices
umask 022
NB_HASH=""; NB_SALT=""; NB_FULL=""

# ---------------------------------------------------------------- write the install plan (in memory only)
HOST=$(echo "$MODEL" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//' | cut -c1-24 | sed 's/-$//')
junk_id "$MODEL" && HOST=""
[ -n "$HOST" ] || HOST=secure-linux
# Last 4 characters of the serial number, so identical PCs get different names
TAG=""
for id in "$SERIAL" "$UUID"; do
  junk_id "$id" && continue
  TAG=$(printf '%s' "$id" | tr -cd 'A-Za-z0-9' | tr 'A-Z' 'a-z'); TAG=${TAG: -4}
  [ ${#TAG} -eq 4 ] && break
  TAG=""
done
[ -n "$TAG" ] || TAG=$(od -An -N2 -tx2 /dev/urandom | tr -d ' ')
HOST="$HOST-$TAG"

FIRMWARE='$FirmwarePkgs = @(linux-firmware mt7xxx-firmware amd-gpu-firmware amd-ucode-firmware intel-gpu-firmware iwlwifi-mvm-firmware iwlwifi-dvm-firmware realtek-firmware atheros-firmware brcmfmac-firmware)'
case "$PROFILE" in
  full)
    printf 'url --mirrorlist="https://mirrors.fedoraproject.org/mirrorlist?repo=fedora-$releasever&arch=$basearch"\nrepo --name=updates --mirrorlist="https://mirrors.fedoraproject.org/mirrorlist?repo=updates-released-f$releasever&arch=$basearch"\n' > /tmp/payload.ks
    printf 'network --hostname=%s\nfirewall --enabled\n' "$HOST" > /tmp/profile.ks
    printf '%%packages\n@^kde-desktop-environment\nflatpak\npython3\ncurl\ngit\nbtrfs-progs\nNetworkManager-wifi\n%s\n%%end\n' "$(echo $FIRMWARE | tr ' ' '\n')" > /tmp/packages.ks
    ;;
  lite)
    printf 'url --mirrorlist="https://mirrors.fedoraproject.org/mirrorlist?repo=fedora-$releasever&arch=$basearch"\nrepo --name=updates --mirrorlist="https://mirrors.fedoraproject.org/mirrorlist?repo=updates-released-f$releasever&arch=$basearch"\n' > /tmp/payload.ks
    printf 'network --hostname=%s\nfirewall --enabled --service=ssh\nservices --enabled=sshd\n' "$HOST" > /tmp/profile.ks
    printf '%%packages\n@^xfce-desktop-environment\nopenssh-server\nflatpak\npython3\ncurl\ngit\nbtrfs-progs\nNetworkManager-wifi\n%s\n%%end\n' "$(echo $FIRMWARE | tr ' ' '\n')" > /tmp/packages.ks
    ;;
  min)
    # fedora-min: the same Fedora from the same mirrors, but the lightest desktop (LXQt) for PCs with
    # 2-3 GB of memory. Everything else matches lite; the installed system is managed as "lite" (below),
    # so only the desktop group differs.
    printf 'url --mirrorlist="https://mirrors.fedoraproject.org/mirrorlist?repo=fedora-$releasever&arch=$basearch"\nrepo --name=updates --mirrorlist="https://mirrors.fedoraproject.org/mirrorlist?repo=updates-released-f$releasever&arch=$basearch"\n' > /tmp/payload.ks
    printf 'network --hostname=%s\nfirewall --enabled --service=ssh\nservices --enabled=sshd\n' "$HOST" > /tmp/profile.ks
    printf '%%packages\n@^lxqt-desktop-environment\nopenssh-server\nflatpak\npython3\ncurl\ngit\nbtrfs-progs\nNetworkManager-wifi\n%s\n%%end\n' "$(echo $FIRMWARE | tr ' ' '\n')" > /tmp/packages.ks
    ;;
  atomic)
    # Fedora Kinoite (KDE Plasma, image-based). No package list: the image is the system.
    printf 'ostreecontainer --url=quay.io/fedora/fedora-kinoite:44\n' > /tmp/payload.ks
    printf 'network --hostname=%s\nfirewall --enabled\n' "$HOST" > /tmp/profile.ks
    echo '# atomic: no package list (the Fedora Kinoite image is the system)' > /tmp/packages.ks
    ;;
esac
# The installed system's profile is full/lite/atomic: a MIN install is managed as lite (same essential
# apps, same light settings) - only the desktop group differs, and anaconda already installed that above.
if [ "$PROFILE" = min ]; then echo lite > /tmp/secure-linux-profile; else echo "$PROFILE" > /tmp/secure-linux-profile; fi
# Installer screen: text mode on 2-4 GB machines (the graphical installer needs more memory)
if [ "$HW_TEXT_INSTALL" = 1 ]; then sed -i '1i text' /tmp/profile.ks; else sed -i '1i graphical' /tmp/profile.ks; fi

# Revalidate the selected hardware immediately before emitting Anaconda's destructive disk plan.
CURRENT_SIZE=$(cat "/sys/block/$DISK/size" 2>/dev/null) || CURRENT_SIZE=""
CURRENT_MODEL=$(sed 's/ *$//' "/sys/block/$DISK/device/model" 2>/dev/null)
if [ "$CURRENT_SIZE" != "${SIZES[$PICK]}" ] || [ "$CURRENT_MODEL" != "$DISK_MODEL" ]; then
  echo "   The selected drive's model or exact sector capacity changed. Nothing was installed."
  cancel
fi
umask 077
Q=${PW1//\\/\\\\}; Q=${Q//\"/\\\"}
cat > /tmp/disk.ks <<EOF
ignoredisk --only-use=$DISK
zerombr
clearpart --all --initlabel --drives=$DISK
autopart --type=btrfs --encrypted --luks-version=luks2 --passphrase="$Q"
EOF
PW1=""; Q=""
umask 022

# Network during install: saved Wi-Fi if this machine has a Wi-Fi card, otherwise wired
: > /tmp/net.ks
if ! { [ "$SETUP_AUTO" = 1 ] && [ "$WIFI_MODE" = skip ]; }; then
# (netboot: no Wi-Fi is saved anywhere - the Wi-Fi question above connects this computer itself)
: # netboot intentionally writes no saved Wi-Fi configuration
fi
# Without saved Wi-Fi (or a Wi-Fi chip the installer can't drive, e.g. old Broadcom) a cable is needed
has_link() { local c; for c in /sys/class/net/*/carrier; do [ "$(cat "$c" 2>/dev/null)" = 1 ] && [ "$(basename "$(dirname "$c")")" != lo ] && return 0; done; return 1; }
if [ ! -s /tmp/net.ks ] && ! has_link && ! { [ "$SETUP_AUTO" = 1 ] && [ "$WIFI_MODE" = skip ]; }; then
  header "internet for the install"
  echo "   The installer downloads Linux, so it needs the internet, but it can't use"
  echo "   Wi-Fi on this computer (no Wi-Fi saved on the stick, or no driver for its"
  echo "   Wi-Fi chip during the install)."
  echo
  echo "   Use Ethernet (plug in a network cable) or phone USB tethering (connect your"
  echo "   phone by USB cable, then turn on 'USB tethering' in its hotspot settings)."
  echo
  while true; do
    answer "Type C when connected, S to start anyway, Q to cancel:"
    case "$REPLY_TEXT" in
      [Cc]) has_link && break; echo "   Still no connection found. Check the cable / tethering." ;;
      [Ss]) break ;;
      [Qq]) cancel ;;
    esac
  done
fi

header "installing"
echo "   All set. Installing now: about 20-40 minutes, no more questions."
echo "   This computer will be called: $HOST"
echo
echo "   When it finishes the computer TURNS OFF. Remove the USB stick, then turn it on,"
echo "   type your encryption passphrase, and log in. Apps keep installing in the"
echo "   background and a guide called START-HERE opens to show you around."
line
sleep 8
chvt 1
%end

%include /tmp/packages.ks

%post --nochroot --log=/tmp/ks-post-nochroot.log
# Runs in the installer, with the new system mounted at $SYSROOT: hands over the choices made above.
SYSROOT=${ANA_INSTALL_PATH:-/mnt/sysroot}
if [ -f /tmp/sl-progress.sh ]; then
  . /tmp/sl-progress.sh
else
  sl_progress_start() { printf '%s\n' "$2"; }
  sl_progress_update() { printf 'Secure Linux stage progress: %s of 100 points finished.\n' "$1"; }
  sl_progress_spinner_start() { printf '%s\n' "$1"; }
  sl_progress_spinner_stop() { [ -z "${1:-}" ] || printf '%s\n' "$1"; }
fi
sl_stage_finish() { sl_progress_spinner_stop "$2"; sl_progress_update "$1"; }
sl_progress_start 100 'Secure Linux final setup. Percentages advance when real stages finish.'
sl_progress_spinner_start 'Saving your choices. No percentage is available within this short stage.'
[ -f /tmp/sl-progress.sh ] && install -m 0644 /tmp/sl-progress.sh "$SYSROOT/tmp/sl-progress.sh"
install -d -m 0755 "$SYSROOT/etc/secure-linux"
install -m 0644 /tmp/secure-linux-profile "$SYSROOT/etc/secure-linux/profile"
touch "$SYSROOT/etc/secure-linux/choices"
while IFS='=' read -r k v; do
  [ -n "$k" ] || continue
  sed -i "/^$k=/d" "$SYSROOT/etc/secure-linux/choices"
  printf '%s=%s\n' "$k" "$v" >> "$SYSROOT/etc/secure-linux/choices"
done < /tmp/secure-linux-choices

# Wi-Fi networks chosen on the setup screen -> NetworkManager profiles for all users (0600, root)
if [ -s /tmp/secure-linux-wifi ]; then
  python3 /tmp/sl-wifi.py keyfiles /tmp/secure-linux-wifi "$SYSROOT/etc/NetworkManager/system-connections" ''
fi
rm -f /tmp/secure-linux-wifi
sl_stage_finish 5 'Choices and saved Wi-Fi settings handed over.'

# Optional unfiltered AI model: copy it from the USB stick if it is there; otherwise first boot downloads it.
sl_progress_spinner_start 'Handling the optional AI model. No percentage is available during its copy.'
MODEL_FILE='Qwen2.5-Coder-7B-Instruct-abliterated-Q4_K_M.gguf'
MODEL_SHA256='fdf02c16fb654ff60b2c30f1e91573ebc603a7084df3449df89120dca2b18170'
if grep -qx 'ai_abliterated=yes' /tmp/secure-linux-choices && [ -n "$MODEL_FILE" ]; then
  MNT=/tmp/ventoy-ro
  mkdir -p "$MNT"
  udevadm settle 2>/dev/null
  # Ventoy keeps its data partition available as /dev/mapper/VentoyPart (Ventoy 1.1.18+, tested on Fedora 44/45)
  for dev in /dev/mapper/VentoyPart "$(blkid -L Ventoy 2>/dev/null)" /dev/disk/by-label/Ventoy; do
    [ -n "$dev" ] && [ -b "$dev" ] || continue
    mount -o ro "$dev" "$MNT" 2>/dev/null || mount -t exfat -o ro "$dev" "$MNT" 2>/dev/null || continue
    break
  done
  if mountpoint -q "$MNT"; then
    SRC="$MNT/linux-setup/models/$MODEL_FILE"
    DEST="$SYSROOT/var/lib/secure-linux/models"
    FREE=$(df --output=avail -B1 "$SYSROOT/var" 2>/dev/null | tail -1)
    if [ -f "$SRC" ] && [ "${FREE:-0}" -gt $(( $(stat -c %s "$SRC") + 10737418240 )) ]; then
      install -d -m 0755 "$DEST"
      echo "Copying $MODEL_FILE from the USB stick..."
      if cp "$SRC" "$DEST/$MODEL_FILE.part" && [ "$(sha256sum "$DEST/$MODEL_FILE.part" | cut -d' ' -f1)" = "$MODEL_SHA256" ]; then
        mv "$DEST/$MODEL_FILE.part" "$DEST/$MODEL_FILE"; chmod 0644 "$DEST/$MODEL_FILE"
        echo "AI model copied and verified."
      else
        rm -f "$DEST/$MODEL_FILE.part"; echo "AI model copy failed or checksum mismatch: first boot will download it."
      fi
    else
      echo "AI model not on the stick (or not enough space): first boot will download it."
    fi
    umount "$MNT" 2>/dev/null
  else
    echo "Couldn't open the USB stick's data partition: first boot will download the AI model."
  fi
fi
sl_stage_finish 20 'Optional AI model stage finished.'

# Offline fix-packs from the USB stick (best-effort, silent if the stick or the files are not there): the ClamAV
# virus list. Staged at /var/lib/secure-linux/offline/clamav, and copied into /var/lib/clamav when no database was
# ever downloaded, so a fresh install can scan before (or without ever) downloading one. The files stay root-owned
# here (the clamav user does not exist yet): the clamav package's own install fixes the folder's ownership, and
# freshclam replaces the files at its first online update.
sl_progress_spinner_start 'Copying offline fix-packs. No percentage is available during this copy.'
OFF_MNT=/tmp/ventoy-offline
mkdir -p "$OFF_MNT"
if ! mountpoint -q "$OFF_MNT"; then
  udevadm settle 2>/dev/null
  for dev in /dev/mapper/VentoyPart "$(blkid -L Ventoy 2>/dev/null)" /dev/disk/by-label/Ventoy; do
    [ -n "$dev" ] && [ -b "$dev" ] || continue
    mount -o ro "$dev" "$OFF_MNT" 2>/dev/null || mount -t exfat -o ro "$dev" "$OFF_MNT" 2>/dev/null || continue
    break
  done
fi
if mountpoint -q "$OFF_MNT" && [ -f "$OFF_MNT/linux-setup/offline/clamav/main.cvd" ]; then
  install -d -m 0755 "$SYSROOT/var/lib/secure-linux/offline/clamav"
  cp "$OFF_MNT"/linux-setup/offline/clamav/*.cvd "$SYSROOT/var/lib/secure-linux/offline/clamav/" 2>/dev/null
  if [ ! -e "$SYSROOT/var/lib/clamav/main.cvd" ] && [ ! -e "$SYSROOT/var/lib/clamav/main.cld" ]; then
    install -d -m 0755 "$SYSROOT/var/lib/clamav"
    cp "$OFF_MNT"/linux-setup/offline/clamav/*.cvd "$SYSROOT/var/lib/clamav/" 2>/dev/null
    echo "Virus list copied from the USB stick: the scan works before the first online update."
  fi
fi
sl_stage_finish 30 'Offline fix-pack stage finished.'
# Browser passwords: copy only after the person explicitly reviewed STEP_SAVE_BROWSER_PASSWORDS=yes in %pre.
# The marker contains no secret. Without it, do not even enumerate CSV names (which can themselves be sensitive).
sl_progress_spinner_start 'Browser-password export stage. No percentage is available.'
if [ -f /tmp/sl-copy-browser-passwords ] && mountpoint -q "$OFF_MNT" && [ -d "$OFF_MNT/linux-setup/scan" ]; then
  SL_INSTALL_USER=$(sed -n 's/^sl_username=//p' "$SYSROOT/etc/secure-linux/choices" | head -n 1)
  [ -n "$SL_INSTALL_USER" ] || SL_INSTALL_USER=owner
  PASS_DEST="$SYSROOT/home/$SL_INSTALL_USER/Documents/Import-These-Passwords"
  find "$OFF_MNT/linux-setup/scan" -type f -name '*.csv' | while IFS= read -r csv; do
    IFS= read -r csv_header < "$csv" || continue
    case "$csv_header" in *password*username*|*username*password*|*password*login*|*login*password*) ;; *) continue ;; esac
    install -d -m 0700 "$PASS_DEST"
    cp "$csv" "$PASS_DEST/$(basename "$csv")"
  done
  if [ -d "$PASS_DEST" ]; then
    chmod 0600 "$PASS_DEST"/*.csv 2>/dev/null
    cat > "$PASS_DEST/READ-ME-FIRST.txt" <<'PASS_GUIDE'
These are the password CSV files you explicitly exported from your browser.
Open Bitwarden, choose Tools > Import Data, select the matching browser/CSV format and import each file.
Check the imported passwords, then securely delete every CSV and this folder: anyone who reads a CSV can use the passwords.
PASS_GUIDE
    chmod 0600 "$PASS_DEST/READ-ME-FIRST.txt"
    echo "Your exported browser-password CSV files are in Documents/Import-These-Passwords."
  fi
fi
# ---- Master copy: keep the stick's own files on this computer, so it can make new sticks later without the
# original. Files only (installer, tools, setup apps, install images: several GB), each one hashed while copied
# and read back. Left out: the offline app collection (large; it can be added later from a plugged-in stick) and
# anything personal (PC scan, exported browser passwords, recovery notes). Skipped quietly when the computer has
# little free space, the stick's tool is older than this feature, or anything fails: the install carries on.
MASTER_TOOL="$OFF_MNT/linux-setup/linux/bin/secure-linux-usb-creator"
MASTER_REL="$OFF_MNT/linux-setup/linux/release.json"
MASTER_STORE="$SYSROOT/var/lib/secure-linux/usb-master"
if mountpoint -q "$OFF_MNT" && [ -f "$MASTER_REL" ] && command -v python3 >/dev/null 2>&1 \
   && grep -q -- '--files-only' "$MASTER_TOOL" 2>/dev/null; then
  MASTER_FREE_KB=$(df -Pk "$SYSROOT/var" 2>/dev/null | awk 'NR==2 {print $4}')
  if [ "${MASTER_FREE_KB:-0}" -ge 41943040 ]; then
    sl_progress_spinner_start 'Saving a master copy of this stick on the computer. No percentage is available during this copy.'
    install -d -m 0700 "$MASTER_STORE"
    if timeout 5400 env PYTHONDONTWRITEBYTECODE=1 SL_USBC_PROGRESS_INTERVAL=30 python3 "$MASTER_TOOL" create --files-only \
         --variant online-only --store "$MASTER_STORE" --source-root "$OFF_MNT" --source-release "$MASTER_REL" \
         --current-release "$MASTER_REL" --non-interactive > /tmp/sl-master-save.log 2>&1; then
      echo "Master copy saved: this computer can make new Secure Linux sticks without the original."
    else
      echo "The master copy was not saved (the install is not affected). Last lines of its log:"
      tail -n 3 /tmp/sl-master-save.log 2>/dev/null
      chmod -R u+rwX "$MASTER_STORE" 2>/dev/null; rm -rf "$MASTER_STORE"
    fi
  else
    echo "Master copy not saved: under 40 GB free on this computer. It can be saved later from the stick."
  fi
fi
umount "$OFF_MNT" 2>/dev/null
sl_stage_finish 35 'Browser export stage finished.'
%end

%post --log=/root/ks-post.log
# Runs inside the new system.
if [ -f /tmp/sl-progress.sh ]; then
  . /tmp/sl-progress.sh
else
  sl_progress_start() { printf '%s\n' "$2"; }
  sl_progress_update() { printf 'Secure Linux stage progress: %s of 100 points finished.\n' "$1"; }
  sl_progress_spinner_start() { printf '%s\n' "$1"; }
  sl_progress_spinner_stop() { [ -z "${1:-}" ] || printf '%s\n' "$1"; }
fi
sl_stage_finish() { sl_progress_spinner_stop "$2"; sl_progress_update "$1"; }
sl_progress_start 100 'Secure Linux final setup continues in the new system.' >/dev/null
sl_progress_update 35
sl_progress_spinner_start 'Unpacking Secure Linux. No percentage is available during the unpack.'
systemctl set-default graphical.target
# Files written from outside this system (by the installer, above) get their proper SELinux labels
SL_INSTALL_USER=$(sed -n 's/^sl_username=//p' /etc/secure-linux/choices | head -n 1)
[ -n "$SL_INSTALL_USER" ] || SL_INSTALL_USER=owner
if [ -d "/home/$SL_INSTALL_USER/Documents/Import-These-Passwords" ]; then
  chown -R "$SL_INSTALL_USER:$SL_INSTALL_USER" "/home/$SL_INSTALL_USER/Documents/Import-These-Passwords"
  restorecon -R "/home/$SL_INSTALL_USER/Documents/Import-These-Passwords" 2>/dev/null
fi
restorecon -R /etc/secure-linux /etc/NetworkManager/system-connections /var/lib/secure-linux /var/lib/clamav 2>/dev/null
PROFILE=$(cat /etc/secure-linux/profile 2>/dev/null)
case "$PROFILE" in full|lite|atomic) ;; *) PROFILE=full; echo full > /etc/secure-linux/profile ;; esac
# netboot: the login name was asked on the setup screen and carried over in the choices file
sed -n 's/^sl_username=//p' /etc/secure-linux/choices | head -n 1 > /etc/secure-linux/user
[ -s /etc/secure-linux/user ] || echo owner > /etc/secure-linux/user
chmod 0644 /etc/secure-linux/profile /etc/secure-linux/user /etc/secure-linux/choices

# On atomic, /usr is read-only and /usr/local points into /var: make sure the target exists
[ -L /usr/local ] && mkdir -p "$(readlink -f /usr/local)"

# ---- Secure Linux: the public repository IS the payload (plain text files, no uploaded archive).
# The whole-repository download is only the transport at install time. Its payload/ subtree has the
# same root as the old USB archive (setup.sh, bin/...), and holds no names, hashes or Wi-Fi secrets.
# Validate every archive member before extraction: even a transport archive must never write outside
# its staging root or introduce links/special files. The release record prevents old/new payload drift.
SL_PAYLOAD_SOURCE="https://codeload.github.com/MattyBoyMan/secure-linux-netboot/tar.gz/refs/heads/main"
SL_EXPECTED_RELEASE="secure-linux-2026.11.13-dd55a464400fead2"
SL=/usr/local/lib/secure-linux
SLREPO=/tmp/sl-repo
SLPAYLOAD="$SLREPO/secure-linux-netboot-main/payload"
sl_unpack_repo() {
  python3 - "$1" "$2" "$3" <<'SL_PAYLOAD_EXTRACT'
import os
from pathlib import Path, PurePosixPath
import sys
import tarfile

archive, destination, expected_root = sys.argv[1:4]
root = Path(destination).resolve()
with tarfile.open(archive, "r:gz") as tar:
    members = tar.getmembers()
    seen = set()
    for member in members:
        pure = PurePosixPath(member.name)
        relative = pure.as_posix()
        if (not relative or pure.is_absolute() or "\\" in member.name
                or any(part in {"", ".", ".."} for part in pure.parts)
                or pure.parts[0] != expected_root
                or member.name.rstrip("/") != relative):
            raise SystemExit("unsafe or non-normalized path in payload archive: " + member.name)
        if relative in seen:
            raise SystemExit("duplicate path in payload archive: " + relative)
        seen.add(relative)
        if not (member.isfile() or member.isdir()):
            raise SystemExit("links and special files are not allowed in payload archive")
    for member in members:
        relative = PurePosixPath(member.name).as_posix()
        target = root.joinpath(*PurePosixPath(relative).parts)
        target.resolve(strict=False).relative_to(root)
        if member.isdir():
            if target.exists() and not target.is_dir():
                raise SystemExit("payload directory collides with a file")
            target.mkdir(parents=True, exist_ok=True)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            raise SystemExit("payload file collides with another archive entry")
        source = tar.extractfile(member)
        if source is None:
            raise SystemExit("could not read payload archive member")
        with source, target.open("xb") as output:
            while True:
                block = source.read(1024 * 1024)
                if not block:
                    break
                output.write(block)
        target.chmod(member.mode & 0o777)
SL_PAYLOAD_EXTRACT
}
sl_release_matches() {
  python3 - "$1" "$2" <<'SL_RELEASE_CHECK'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as release_file:
        actual = json.load(release_file)["release_id"]
except (OSError, ValueError, KeyError, TypeError):
    raise SystemExit(1)
if actual != sys.argv[2]:
    raise SystemExit(1)
SL_RELEASE_CHECK
}
rm -rf "$SL" "$SLREPO"
install -d -m 0755 "$SL" "$SLREPO"
if ! curl -fsSL --retry 3 -o /tmp/sl-repo.tar.gz "$SL_PAYLOAD_SOURCE"; then
  echo "ERROR: could not download the Secure Linux payload from $SL_PAYLOAD_SOURCE"
  touch /root/secure-linux-payload-missing
elif ! sl_unpack_repo /tmp/sl-repo.tar.gz "$SLREPO" "secure-linux-netboot-main" || [ ! -f "$SLPAYLOAD/setup.sh" ] || [ ! -f "$SLPAYLOAD/build.conf" ] || ! sl_release_matches "$SLPAYLOAD/release.json" "$SL_EXPECTED_RELEASE"; then
  echo "ERROR: the downloaded payload is unsafe, incomplete, or from a different Secure Linux release"
  touch /root/secure-linux-payload-missing
elif ! cp -a "$SLPAYLOAD/." "$SL/"; then
  echo "ERROR: could not copy the Secure Linux payload into place"
  touch /root/secure-linux-payload-missing
  rm -rf "$SL"; install -d -m 0755 "$SL"       # no half-installed payload: the plain Fedora path continues
else
  rm -rf "$SL/debian"                          # the Debian injection tree is not part of Fedora's payload
  [ -f "$SL/START-HERE.html" ] && mv "$SL/START-HERE.html" /tmp/START-HERE.html
fi
rm -rf "$SLREPO" /tmp/sl-repo.tar.gz
chmod -R u+rwX,go+rX,go-w "$SL"
chmod 0755 "$SL/setup.sh" 2>/dev/null
chmod 0755 "$SL"/bin/* 2>/dev/null
# A tar written on Windows stores every file as 0666: every shell script in the kit must be runnable, not just the two above
find "$SL" -type f -name '*.sh' -exec chmod 0755 {} + 2>/dev/null
# ---- Is a newer Secure Linux release published? The files just unpacked from the stick are always
# enough on their own. With internet, one tiny file is compared; only files whose SHA-256 differs are
# fetched, each one verified before anything is replaced. No internet, an older or half-published
# release, or any failed check: the stick's copy is used unchanged. This step can never stop the install.
if [ -f "$SL/bin/secure-linux-kit-update" ] && command -v python3 >/dev/null 2>&1; then
  timeout 300 python3 "$SL/bin/secure-linux-kit-update" apply --tree "$SL" 2>&1 | tail -n 2 \
    || echo "KIT UPDATE: the check did not finish; using the stick's copy."
  chmod 0755 "$SL/setup.sh" "$SL"/bin/* 2>/dev/null
  find "$SL" -type f -name '*.sh' -exec chmod 0755 {} + 2>/dev/null
fi
sl_stage_finish 55 'Secure Linux files unpacked.'

# ---- The beginner's guide (opened on first login, also in the app menu)
sl_progress_spinner_start 'Writing the beginner guide. No percentage is available within this short stage.'
GUIDE_DIR=/usr/share/secure-linux
[ "$PROFILE" = atomic ] && GUIDE_DIR=/usr/local/share/secure-linux   # /usr is read-only on atomic
install -d -m 0755 "$GUIDE_DIR"
if [ -f /tmp/START-HERE.html ]; then
  mv /tmp/START-HERE.html "$GUIDE_DIR/START-HERE.html"
else
  echo "NOTE: the beginner's guide was not in the download; the computer still works, and the guide is online in the repository."
fi
chmod 0644 "$GUIDE_DIR/START-HERE.html"
sl_stage_finish 60 'Beginner guide written.'

sl_progress_spinner_start 'Saving Wi-Fi settings and preparing storage. No percentage is available within this stage.'
# (netboot: no Wi-Fi is pre-configured - the first start asks)

# ---- Separate Btrfs subvolumes (full/lite) so system snapshots don't keep old copies of
#      Flatpak runtimes or AI models (GBs that change often). A nested subvolume is left out of
#      snapshots of its parent automatically; no fstab line is needed.
make_subvol() {
  local p=$1 mode owner
  [ -d "$p" ] && [ "$(stat -c %i "$p")" = 256 ] && return 0   # already a subvolume (inode 256)
  install -d -m 0755 "$(dirname "$p")"
  mode=0755; owner=root:root
  if [ -e "$p" ]; then mode=$(stat -c %a "$p"); owner=$(stat -c %u:%g "$p"); mv "$p" "$p.sl-move"; fi
  if ! btrfs subvolume create "$p"; then
    [ -e "$p.sl-move" ] && mv "$p.sl-move" "$p"
    return 1
  fi
  chmod "$mode" "$p"; chown "$owner" "$p"
  if [ -e "$p.sl-move" ]; then
    { cp -a --reflink=auto "$p.sl-move/." "$p/" && rm -rf "$p.sl-move"; } || echo "WARNING: left $p.sl-move behind"
  fi
  restorecon -R "$p" 2>/dev/null
  return 0
}
if [ "$PROFILE" != atomic ] && [ "$(stat -f -c %T /)" = btrfs ] && command -v btrfs >/dev/null; then
  make_subvol /var/lib/flatpak
  make_subvol /usr/share/ollama
fi
sl_stage_finish 70 'Wi-Fi and storage preparation finished.'

# ---- First boot: wait for internet, run the full setup once (shutdown is blocked while it runs)
sl_progress_spinner_start 'Creating the first-start service. No percentage is available within this short stage.'
install -d -m 0755 /usr/local/sbin
cat > /usr/local/sbin/secure-linux-firstboot <<'EOF'
#!/bin/bash
# Started by firstboot-setup.service: waits for the internet, then runs the Secure Linux setup once.
mkdir -p /var/lib/secure-linux
until curl -fsS --max-time 10 -o /dev/null https://dl.flathub.org; do
  printf '0|?|Waiting for the internet (connect to Wi-Fi)\n' > /var/lib/secure-linux/progress
  sleep 15
done
systemd-inhibit --what=shutdown:sleep:idle --who="Secure Linux" --why="Setting up apps" --mode=block \
  /usr/local/lib/secure-linux/setup.sh
rc=$?
if [ "$rc" -eq 0 ] && [ ! -s /var/log/secure-linux/failures.log ]; then
  touch /var/lib/firstboot-setup.done
else
  rm -f /var/lib/firstboot-setup.done
  printf 'failed|?|Setup incomplete; run setup.sh and explicitly choose Resume or Fresh start\n' > /var/lib/secure-linux/progress
fi
exit $rc
EOF
chmod 0755 /usr/local/sbin/secure-linux-firstboot
# Type=exec: the unit counts as started as soon as the script runs, so multi-user.target (and the
# login screen) never waits for the hour-long setup; the internet wait happens inside the script.
cat > /etc/systemd/system/firstboot-setup.service <<'EOF'
[Unit]
Description=Secure Linux: first-boot app setup
DefaultDependencies=no
Wants=network-online.target
After=network-online.target basic.target
Conflicts=shutdown.target
Before=shutdown.target
ConditionPathExists=!/var/lib/firstboot-setup.done

[Service]
Type=exec
TimeoutStartSec=infinity
ExecStart=/usr/local/sbin/secure-linux-firstboot

[Install]
WantedBy=multi-user.target
EOF
systemctl enable firstboot-setup.service
sl_stage_finish 80 'First-start service created.'

# ---- Helpers, welcome autostart, timers and menu entries in place before the first login
sl_progress_spinner_start 'Preparing helpers and menus. No percentage is available within this stage.'
if [ -x "$SL/setup.sh" ]; then
  "$SL/setup.sh" --early || echo "setup.sh --early reported a problem (first boot repeats everything)"
fi
sl_stage_finish 95 'Early setup finished.'
%end

%post --nochroot --log=/tmp/ks-post-scrub.log
# Belt and braces: make sure the encryption passphrase isn't left in any saved installer file
SYSROOT=${ANA_INSTALL_PATH:-/mnt/sysroot}
if [ -f /tmp/sl-progress.sh ]; then
  . /tmp/sl-progress.sh
else
  sl_progress_start() { printf '%s\n' "$2"; }
  sl_progress_update() { printf 'Secure Linux stage progress: %s of 100 points finished.\n' "$1"; }
  sl_progress_done() { printf 'Secure Linux final setup: 100%% complete.\n'; }
  sl_progress_spinner_start() { printf '%s\n' "$1"; }
  sl_progress_spinner_stop() { [ -z "${1:-}" ] || printf '%s\n' "$1"; }
fi
sl_progress_start 100 'Secure Linux final safety check.' >/dev/null
sl_progress_update 95
sl_progress_spinner_start 'Removing saved installer secrets. No percentage is available within this short stage.'
for f in "$SYSROOT"/root/*.cfg "$SYSROOT"/root/*.ks "$SYSROOT"/var/log/anaconda/*; do
  [ -f "$f" ] && sed -i -E 's/(--passphrase)(=| )("[^"]*"|[^ ]+)/\1=REMOVED/g' "$f"
done
rm -f /tmp/disk.ks
sl_progress_spinner_stop 'Final safety check finished.'
sl_progress_done
%end
