# Fedora Kickstart: "The Complete Secure Linux Package" - NETBOOT build, rendered by netboot/render-netboot.sh
# on 2026-11-04 (netboot render) (Fedora 44) from templates/fedora.ks. This is a PUBLIC file: no names, no password
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
  umount /tmp/ventoy-ro 2>/dev/null
fi
WIFI_KIND=$(python3 /tmp/sl-wifi.py pick /tmp/wifi-records.txt "$SID" "$UID_" /tmp/sl-wifi-record 2>/dev/null)
umask 022

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
PICK=0
if [ ${#NAMES[@]} -gt 1 ]; then
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
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0gQ1BVCmh3X2NwdSgpIHsKICBsb2Nh
bCBhcmNoIGZsYWdzIHZlbmRvciBtb2RlbCBsZXZlbD0wIGxtPW5vIGNvcmVzCiAgYXJjaD0kKGh3
X2FyY2gpCiAgdmVuZG9yPSQoYXdrIC1GJzogKicgJy9edmVuZG9yX2lkL3twcmludCAkMjsgZXhp
dH0nICIkSFdfUk9PVC9wcm9jL2NwdWluZm8iIDI+L2Rldi9udWxsKQogIG1vZGVsPSQoYXdrIC1G
JzogKicgJy9ebW9kZWwgbmFtZS97cHJpbnQgJDI7IGV4aXR9JyAiJEhXX1JPT1QvcHJvYy9jcHVp
bmZvIiAyPi9kZXYvbnVsbCkKICBmbGFncz0iICQoYXdrIC1GJzogKicgJy9eZmxhZ3Mve3ByaW50
ICQyOyBleGl0fScgIiRIV19ST09UL3Byb2MvY3B1aW5mbyIgMj4vZGV2L251bGwpICIKICBjb3Jl
cz0kKGdyZXAgLWMgJ15wcm9jZXNzb3InICIkSFdfUk9PVC9wcm9jL2NwdWluZm8iIDI+L2Rldi9u
dWxsKQogIGNhc2UgIiR2ZW5kb3IiIGluCiAgICBHZW51aW5lSW50ZWwpIHZlbmRvcj1pbnRlbCA7
OyBBdXRoZW50aWNBTUR8SHlnb25HZW51aW5lKSB2ZW5kb3I9YW1kIDs7CiAgICAiIikgY2FzZSAi
JGFyY2giIGluIGFhcmNoNjR8YXJtKikgdmVuZG9yPWFybSA7OyAqKSB2ZW5kb3I9dW5rbm93biA7
OyBlc2FjIDs7CiAgICAqKSB2ZW5kb3I9b3RoZXIgOzsKICBlc2FjCiAgY2FzZSAiJGZsYWdzIiBp
biAqIiBsbSAiKikgIGxtPXllcyA7OyBlc2FjCiAgIyB4ODYtNjQgbWljcm9hcmNoaXRlY3R1cmUg
bGV2ZWxzIChwc0FCSSk6IHYxID0gbG0gY21vdiBjeDggZnB1IGZ4c3IgbW14IHN5c2NhbGwgc3Nl
MgogIF9od19oYXMoKSB7IGxvY2FsIGY7IGZvciBmIGluICIkQCI7IGRvIGNhc2UgIiRmbGFncyIg
aW4gKiIgJGYgIiopIDs7ICopIHJldHVybiAxIDs7IGVzYWM7IGRvbmU7IHJldHVybiAwOyB9CiAg
aWYgWyAiJGxtIiA9IHllcyBdOyB0aGVuCiAgICBsZXZlbD0xCiAgICBfaHdfaGFzIGN4MTYgbGFo
Zl9sbSBwb3BjbnQgc3NlNF8xIHNzZTRfMiBzc3NlMyAmJiBsZXZlbD0yCiAgICBbICRsZXZlbCA9
IDIgXSAmJiBfaHdfaGFzIGF2eCBhdngyIGJtaTEgYm1pMiBmMTZjIGZtYSBhYm0gbW92YmUgeHNh
dmUgJiYgbGV2ZWw9MwogICAgWyAkbGV2ZWwgPSAzIF0gJiYgX2h3X2hhcyBhdng1MTJmIGF2eDUx
MmJ3IGF2eDUxMmNkIGF2eDUxMmRxIGF2eDUxMnZsICYmIGxldmVsPTQKICBmaQogIHVuc2V0IC1m
IF9od19oYXMKICBbIC16ICIkbW9kZWwiIF0gJiYgbW9kZWw9JChhd2sgLUYnOiAqJyAnL14oSGFy
ZHdhcmV8Q1BVIHBhcnQpL3twcmludCAkMjsgZXhpdH0nICIkSFdfUk9PVC9wcm9jL2NwdWluZm8i
IDI+L2Rldi9udWxsKQogIGVjaG8gImNwdV9hcmNoPSRhcmNoIgogIGVjaG8gImNwdV92ZW5kb3I9
JHZlbmRvciIKICBlY2hvICJjcHVfbW9kZWw9JG1vZGVsIgogIGVjaG8gImNwdV9jb3Jlcz0ke2Nv
cmVzOi0wfSIKICBlY2hvICJjcHVfNjRiaXQ9JGxtIgogIGVjaG8gImNwdV94ODZfbGV2ZWw9JGxl
dmVsIgp9CgojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0gbWVtb3J5Cmh3X3JhbSgpIHsKICBs
b2NhbCBrYjsga2I9JChhd2sgJy9eTWVtVG90YWw6L3twcmludCAkMjsgZXhpdH0nICIkSFdfUk9P
VC9wcm9jL21lbWluZm8iIDI+L2Rldi9udWxsKQogIGtiPSR7a2I6LTB9CiAgZWNobyAicmFtX21i
PSQoKGtiIC8gMTAyNCkpIgogIGVjaG8gInJhbV9nYj0kKCggKGtiICsgNTI0Mjg4KSAvIDEwNDg1
NzYgKSkiICAgICAgIyByb3VuZGVkLCBhcyB0aGUgc2V0dXAgc2NyZWVuIHNob3dzIGl0Cn0KCiMg
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tIGZpcm13YXJlIC8gU2VjdXJlIEJvb3QKaHdf
ZmlybXdhcmUoKSB7CiAgbG9jYWwgZnc9YmlvcyBiaXRzPSIiIHNiPW9mZiBzbT0iIiBmIGIKICBp
ZiBbIC1kICIkSFdfUk9PVC9zeXMvZmlybXdhcmUvZWZpIiBdOyB0aGVuCiAgICBmdz11ZWZpCiAg
ICBiaXRzPSQoX2h3X3JlYWQgL3N5cy9maXJtd2FyZS9lZmkvZndfcGxhdGZvcm1fc2l6ZSkKICAg
IHNiPXVua25vd24KICAgICMgZWZpdmFyOiA0IGJ5dGVzIG9mIGF0dHJpYnV0ZXMsIHRoZW4gdGhl
IHZhbHVlIGJ5dGUgKDEgPSBTZWN1cmUgQm9vdCBlbmZvcmNpbmcpCiAgICBmb3IgZiBpbiAiJEhX
X1JPT1QiL3N5cy9maXJtd2FyZS9lZmkvZWZpdmFycy9TZWN1cmVCb290LThiZTRkZjYxLTkz
Y2EtMTFkMC1hYTBkLTAwZTA5ODAzMmI4YzsgZG8KICAgICAgWyAtciAiJGYiIF0gfHwgY29u
dGludWUKICAgICAgYj0kKF9od19lZmlieXRlICIkZiIpCiAgICAgIGNhc2UgIiRiIiBpbiAxKSBz
Yj1vbiA7OyAwKSBzYj1vZmYgOzsgZXNhYwogICAgZG9uZQogICAgZm9yIGYgaW4gIiRIV19ST09U
Ii9zeXMvZmlybXdhcmUvZWZpL2VmaXZhcnMvU2V0dXBNb2RlLThiZTRkZjYxLTkzY2EtMTFk
MC1hYTBkLTAwZTA5ODAzMmI4YzsgZG8KICAgICAgWyAtciAiJGYiIF0gfHwgY29udGludWUK
ICAgICAgYj0kKF9od19lZmlieXRlICIkZiIpCiAgICAgIGNhc2UgIiRiIiBpbiAxKSBzbT15ZXMg
OzsgMCkgc209bm8gOzsgZXNhYwogICAgZG9uZQogICAgIyBGYWxsIGJhY2sgdG8gbW9rdXRpbCBv
biBhIHJlYWwgc3lzdGVtIChub3QgaW4gZml4dHVyZXMpCiAgICBpZiBbICIkc2IiID0gdW5rbm93
biBdICYmIFsgLXogIiRIV19ST09UIiBdICYmIGNvbW1hbmQgLXYgbW9rdXRpbCA+L2Rldi9u
dWxsIDI+JjE7IHRoZW4KICAgICAgY2FzZSAiJChtb2t1dGlsIC0tc2Itc3RhdGUgMj4vZGV2
L251bGwpIiBpbiAqbmFibGVkKikgc2I9b24gOzsgKmlzYWJsZWQqKSBzYj1vZmYgOzsgZXNhYwog
ICAgZmkKICAgICMgKEludGVsIE1hY3MgaGF2ZSBubyBTZWN1cmVCb290IHZhcmlhYmxlIGF0IGFs
bDogQXBwbGUncyBvd24gc2NoZW1lOyBUMiBNYWNzIGVuZm9yY2UgaXQgaW4gdGhlIFQyIC0+IHVu
a25vd24pCiAgZmkKICBlY2hvICJmaXJtd2FyZT0kZnciCiAgZWNobyAiZWZpYml0cz0ke2JpdHM6
LX0iCiAgZWNobyAic2VjdXJlX2Jvb3Q9JHNiIgogIGVjaG8gInNldHVwX21vZGU9JHNtIgp9Cgoj
IC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tIERNSSAobWFrZXIgLyBtb2RlbCkKaHdfZG1p
KCkgewogIGxvY2FsIHZlbmRvciBwcm9kdWN0IGZhbWlseSB2ZXJzaW9uIGN0IGtpbmQKICB2ZW5k
b3I9JChfaHdfcmVhZCAvc3lzL2NsYXNzL2RtaS9pZC9zeXNfdmVuZG9yKQogIHByb2R1Y3Q9JChf
aHdfcmVhZCAvc3lzL2NsYXNzL2RtaS9pZC9wcm9kdWN0X25hbWUpCiAgZmFtaWx5PSQoX2h3X3Jl
YWQgL3N5cy9jbGFzcy9kbWkvaWQvcHJvZHVjdF9mYW1pbHkpCiAgdmVyc2lvbj0kKF9od19yZWFk
IC9zeXMvY2xhc3MvZG1pL2lkL3Byb2R1Y3RfdmVyc2lvbikKICBjdD0kKF9od19yZWFkIC9z
eXMvY2xhc3MvZG1pL2lkL2NoYXNzaXNfdHlwZSkKICBjYXNlICIkY3QiIGluCiAgICA4fDl8
MTB8MTF8MTR8MzB8MzF8MzIpIGtpbmQ9bGFwdG9wIDs7ICAgICAjIHBvcnRhYmxlLCBsYXB0b3As
IG5vdGVib29rLCBoYW5kIGhlbGQsIHN1YiBub3RlYm9vaywgdGFibGV0LCBjb252ZXJ0aWJs
ZSwgZGV0YWNoYWJsZQogICAgM3w0fDV8Nnw3fDEzfDE1fDE2fDM1fDM2KSBraW5kPWRlc2t0
b3AgOzsKICAgICIiKSBraW5kPXVua25vd24gOzsKICAgICopIGtpbmQ9b3RoZXIgOzsKICBl
c2FjCiAgbG9jYWwgc2hvcnQKICBjYXNlICIkKHByaW50ZiAnJXMnICIkdmVuZG9yIiB8IHRy
ICdhLXonICdBLVonKSIgaW4KICAgIEFQUExFKikgc2hvcnQ9YXBwbGUgOzsgREVMTCopIHNo
b3J0PWRlbGwgOzsgVE9TSElCQSp8RFlOQUJPT0sqKSBzaG9ydD10b3NoaWJhIDs7IExFTk9W
TyopIHNob3J0PWxlbm92byA7OwogICAgSFB8SEVXTEVUVCopIHNob3J0PWhwIDs7IEFTVVMq
KSBzaG9ydD1hc3VzIDs7IE1JQ1JPU09GVCopIHNob3J0PW1pY3Jvc29mdCA7OyBBQ0VSKikg
c2hvcnQ9YWNlciA7OwogICAgR09PR0xFKikgc2hvcnQ9Z29vZ2xlIDs7IE1TSSp8TUlDUk8t
U1RBUiopIHNob3J0PW1zaSA7OyBTQU1TVU5HKikgc2hvcnQ9c2Ftc3VuZyA7OyBGUkFNRVdP
UksqKSBzaG9ydD1mcmFtZXdvcmsgOzsKICAgICIiKSBzaG9ydD11bmtub3duIDs7ICopIHNo
b3J0PW90aGVyIDs7CiAgZXNhYwogIGVjaG8gImRtaV92ZW5kb3I9JHZlbmRvciIKICBlY2hv
ICJkbWlfbWFrZXI9JHNob3J0IgogIGVjaG8gImRtaV9wcm9kdWN0PSRwcm9kdWN0IgogIGVj
aG8gImRtaV9mYW1pbHk9JGZhbWlseSIKICBlY2hvICJkbWlfdmVyc2lvbj0kdmVyc2lvbiIK
ICBlY2hvICJkbWlfY2hhc3Npc190eXBlPSRjdCIKICBlY2hvICJkbWlfY2hhc3Npcz0ka2lu
ZCIKfQoKIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tIFBDSSBoZWxwZXJzCiMgX2h3X3Bj
aSBDTEFTU1BSRUZJWCAgLT4gICJzbG90IHZlbmRvciBkZXZpY2UgY2xhc3MgYm9vdF92Z2Ei
IHBlciBtYXRjaGluZyBkZXZpY2UgKGhleCwgbm8gMHgpCl9od19wY2koKSB7CiAgbG9jYWwg
ZCBjbHMgdiBkZXYgYnYKICBmb3IgZCBpbiAiJEhXX1JPT1QiL3N5cy9idXMvcGNpL2Rldmlj
ZXMvKjsgZG8KICAgIFsgLXIgIiRkL2NsYXNzIiBdIHx8IGNvbnRpbnVlCiAgICBjbHM9JCh0
ciAnQS1GJyAnYS1mJyA8ICIkZC9jbGFzcyIpOyBjbHM9JHtjbHMjMHh9OyBjbHM9JHtjbHMl
JVtbOnNwYWNlOl1dKn0KICAgIGNhc2UgIiRjbHMiIGluICIkMSIqKSA7OyAqKSBjb250aW51
ZSA7OyBlc2FjCiAgICB2PSQodHIgJ0EtRicgJ2EtZicgPCAiJGQvdmVuZG9yIiAyPi9kZXYv
bnVsbCk7IHY9JHt2IzB4fTsgdj0ke3YlJVtbOnNwYWNlOl1dKn0KICAgIGRldj0kKHRyICdB
LUYnICdhLWYnIDwgIiRkL2RldmljZSIgMj4vZGV2L251bGwpOyBkZXY9JHtkZXYjMHh9OyBk
ZXY9JHtkZXYlJVtbOnNwYWNlOl1dKn0KICAgIGJ2PSQoY2F0ICIkZC9ib290X3ZnYSIgMj4v
ZGV2L251bGwpOyBidj0ke2J2JSVbWzpzcGFjZTpdXSp9CiAgICBwcmludGYgJyVzICVzICVz
ICVzICVzXG4nICIke2QjIyovfSIgIiR2IiAiJGRldiIgIiRjbHMiICIke2J2Oi0wfSIKICBk
b25lCn0KX2h3X3BjaV9oYXMoKSB7ICAgIyBfaHdfcGNpX2hhcyBWRU5ET1IgREVWSUNFCiAgbG9j
YWwgZCB2IGRldgogIGZvciBkIGluICIkSFdfUk9PVCIvc3lzL2J1cy9wY2kvZGV2aWNlcy8q
OyBkbwogICAgWyAtciAiJGQvdmVuZG9yIiBdIHx8IGNvbnRpbnVlCiAgICB2PSQodHIgJ0Et
RicgJ2EtZicgPCAiJGQvdmVuZG9yIik7IHY9JHt2IzB4fTsgdj0ke3YlJVtbOnNwYWNlOl1d
Kn0KICAgIGRldj0kKHRyICdBLUYnICdhLWYnIDwgIiRkL2RldmljZSIpOyBkZXY9JHtkZXYj
MHh9OyBkZXY9JHtkZXYlJVtbOnNwYWNlOl1dKn0KICAgIFsgIiR2IiA9ICIkMSIgXSAmJiBb
ICIkZGV2IiA9ICIkMiIgXSAmJiByZXR1cm4gMAogIGRvbmUKICByZXR1cm4gMQp9CgojIC0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tIE1hY3MKIyBUMiA9IEFwcGxlIFBD
SSAxMDZiOjE4MDEgKFQyIGJyaWRnZSAvIEJDRSwgZHJpdmVuIGJ5IHRoZSBvdXQtb2YtdHJl
ZSBhcHBsZS1iY2UgZHJpdmVyKSBhbmQgMTA2YjoxODAyCiMgKFQyIFNlY3VyZSBFbmNs
YXZlKS4gVGhlIG1vZGVsIHRhYmxlIGJlbG93IGNhdGNoZXMgVDIgTWFjcyB3aG9zZSBCQ0Ug
aXMgaGlkZGVuLgpfaHdfdDJfbW9kZWwoKSB7CiAgY2FzZSAiJDEiIGluCiAgICBNYWNC
b29rUHJvMTUsKnxNYWNCb29rUHJvMTYsKnxNYWNCb29rQWlyOCwqfE1hY0Jvb2tBaXI5
LDF8TWFjbWluaTgsMXxpTWFjMjAsKnxpTWFjUHJvMSwxfE1hY1BybzcsMSkgcmV0dXJu
IDAgOzsKICBlc2FjCiAgcmV0dXJuIDEKfQpod19tYWMoKSB7CiAgbG9jYWwgdmVuZG9y
IHByb2R1Y3QgYXJjaCBjb21wYXQga2luZD1ub25lIHQyPW5vIGZ0aD1ubwogIHZlbmRv
cj0kKF9od19yZWFkIC9zeXMvY2xhc3MvZG1pL2lkL3N5c192ZW5kb3IpCiAgcHJvZHVj
dD0kKF9od19yZWFkIC9zeXMvY2xhc3MvZG1pL2lkL3Byb2R1Y3RfbmFtZSkKICBhcmNo
PSQoaHdfYXJjaCkKICBjb21wYXQ9IiI7IFsgLXIgIiRIV19ST09UL3Byb2MvZGV2aWNlLXRy
ZWUvY29tcGF0aWJsZSIgXSAmJiBjb21wYXQ9JCh0ciAnXDAnICcgJyA8ICIkSFdfUk9P
VC9wcm9jL2RldmljZS10cmVlL2NvbXBhdGlibGUiKQogIGNhc2UgIiRhcmNoOiRjb21w
YXQiIGluCiAgICBhYXJjaDY0OiphcHBsZSwqKSBraW5kPWFwcGxlLXNpbGljb247IHByb2R1
Y3Q9JChfaHdfcmVhZCAvcHJvYy9kZXZpY2UtdHJlZS9tb2RlbCkgOzsKICBlc2FjCiAg
aWYgWyAiJGtpbmQiID0gbm9uZSBdOyB0aGVuCiAgICBjYXNlICIkdmVuZG9yIiBpbgog
ICAgICBBcHBsZSopCiAgICAgICAgaWYgX2h3X3BjaV9oYXMgMTA2YiAxODAxIHx8IF9o
d19wY2lfaGFzIDEwNmIgMTgwMiB8fCBfaHdfdDJfbW9kZWwgIiRwcm9kdWN0IjsgdGhl
biBraW5kPWludGVsLXQyOyB0Mj15ZXMKICAgICAgICBlbHNlIGtpbmQ9aW50ZWw7IGZp
IDs7CiAgICBlc2FjCiAgZmkKICAjIEZhY2VUaW1lIEhEIChQQ0llLCBCcm9hZGNvbSAx
NGU0OjE1NzApOiBNYWNCb29rcyB+MjAxMy0yMDE3LiBOZWVkcyB0aGUgb3V0LW9mLXRy
ZWUgZmFjZXRpbWVoZCBkcml2ZXIuCiAgWyAiJGtpbmQiID0gaW50ZWwgXSAmJiBfaHdf
cGNpX2hhcyAxNGU0IDE1NzAgJiYgZnRoPXllcwogIGxvY2FsIGlzPW5vOyBbICIka2lu
ZCIgIT0gbm9uZSBdICYmIGlzPXllcwogIGVjaG8gImlzX21hYz0kaXMiCiAgZWNobyAi
bWFjX2tpbmQ9JGtpbmQiCiAgZWNobyAibWFjX21vZGVsPSQoIFsgIiRpcyIgPSB5ZXMg
XSAmJiBwcmludGYgJyVzJyAiJHByb2R1Y3QiKSIKICBlY2hvICJtYWNfdDI9JHQyIgog
IGVjaG8gIm1hY19mYWNldGltZWhkPSRmdGgiCn0KCiMgLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0gTlZJRElBIGdlbmVyYXRpb25zIChieSBQQ0kgZGV2aWNl
IGlkKQojIEJlc3QgZWZmb3J0LCBmcm9tIE5WSURJQSdzIGRldmljZS1pZCByYW5nZXMgKGVh
Y2ggY2hpcCBmYW1pbHkgZ290IGl0cyBvd24gYmxvY2sgb2YgaWRzKToKIyAgID49IDB4
MWUwMCAgICAgICAgICAgIFR1cmluZyAoR1RYIDE2IC8gUlRYIDIwKSBhbmQgbmV3ZXI6
IEFtcGVyZSwgQWRhLCBIb3BwZXIsIEJsYWNrd2VsbCAtPiBha21vZC1udmlkaWEKIyAg
IDB4MTM0MCAuLiAweDFkZmYgICAgIE1heHdlbGwgKEdUWCA3NTAvOTAwKSwgUGFzY2Fs
IChHVFggMTApLCBWb2x0YSAtPiBha21vZC1udmlkaWEtNTgweHggKGxhc3QgYnJhbmNo
IGZvciB0aGVtKQojICAgPCAgMHgxMzQwICAgICAgICAgICAgS2VwbGVyIChHVFggNjAw
LzcwMCksIEZlcm1pICg0MDAvNTAwKSwgVGVzbGEgKDgvOS8yMDAvMzAwKSBhbmQgb2xk
ZXIgLT4gbm91dmVhdQojIFRoZSBhdXRob3JpdGF0aXZlIGxpc3QgaXMgc3VwcG9y
dGVkLWdwdXMuanNvbiBpbiBOVklESUEncyBkcml2ZXIgUkVBRE1FOyBlZGdlIGNhc2Vz
IGFyZSBsaXN0ZWQgaW4gaHdfbnZpZGlhX2ZhbWlseS4KaHdfbnZpZGlhX2NsYXNzKCkg
eyAgICMgaHdfbnZpZGlhX2NsYXNzIERFVklDRUlEKGhleCkgLT4gbW9kZXJuIHwgNTgwe
gggfCBsZWdhY3kKICBsb2NhbCBkPSQoKDE2IyR7MTotMH0pKQogIGlmIFsgJGQgLWdl
ICQoKDE2IzFlMDApKSBdOyB0aGVuIGVjaG8gbW9kZXJuCiAgZWxpZiBbICRkIC1nZSAk
KCgxNiMxMzQwKSkgXTsgdGhlbiBlY2hvIDU4MHh4CiAgZWxzZSBlY2hvIGxlZ2FjeTsg
ZmkKfQpod19udmlkaWFfZmFtaWx5KCkgewogICMgaHdfbnZpZGlhX2ZhbWlseSBERVZJ
Q0VJRChoZXgpIC0+IGNoaXAgZmFtaWx5IG5hbWUgKGZvciBtZXNzYWdlcykKICBsb2Nh
bCBkPSQoKDE2IyR7MTotMH0pKQogIGlmICAgWyAkZCAtZ2UgJCgoMTYjMmI4MCkpIF0g
JiYgWyAkZCAtbGUgJCgoMTYjMmZmZikpIF07IHRoZW4gZWNobyBCbGFja3dlbGwKICBl
bGlmIFsgJGQgLWdlICQoKDE2IzI2ODApKSBdICYmIFsgJGQgLWxlICQoKDE2IzI4ZmYp
KSBdOyB0aGVuIGVjaG8gIkFkYSBMb3ZlbGFjZSIKICBlbGlmIFsgJGQgLWdlICQoKDE2
IzIzMDApKSBdICYmIFsgJGQgLWxlICQoKDE2IzIzM2YpKSBdOyB0aGVuIGVjaG8gSG9w
cGVyCiAgZWxpZiBbICRkIC1nZSAkKCgxNiMyMDgwKSkgXSAmJiBbICRkIC1sZSAkKCgx
NiMyNWZmKSkgXTsgdGhlbiBlY2hvIEFtcGVyZQogIGVsaWYgWyAkZCAtZ2UgJCgoMTYj
MWUwMCkpIF0gJiYgWyAkZCAtbGUgJCgoMTYjMjFmZikpIF07IHRoZW4gZWNobyBUdXJp
bmcKICBlbGlmIFsgJGQgLWdlICQoKDE2IzFlMDApKSBdOyB0aGVuIGVjaG8gIlR1cmlu
ZyBvciBuZXdlciIKICBlbGlmIFsgJGQgLWdlICQoKDE2IzFkODApKSBdOyB0aGVuIGVj
aG8gVm9sdGEKICBlbGlmIFsgJGQgLWdlICQoKDE2IzFiMDApKSBdfCB7IFsgJGQgLWdl
ICQoKDE2IzE1ZjApKSBdICYmIFsgJGQgLWxlICQoKDE2IzE1ZmYpKSBdOyB9IHRoZW4g
ZWNobyBQYXNjYWwKICBlbGlmIFsgJGQgLWdlICQoKDE2IzEzNDApKSBdOyB0aGVuIGVj
aG8gTWF4d2VsbAogIGVsaWYgeyBbICRkIC1nZSAkKCgxNiMwZmMwKSkgXSAmJiBbICRk
IC1sZSAkKCgxNiMxMDNmKSkgXTsgfSB8fCB7IFsgJGQgLWdlICQoKDE2IzExODApKSBd
ICYmIFsgJGQgLWxlICQoKDE2IzExZmYpKSBdOyB9IFwKICAgICAgIHx8IHsgWyAkZCAt
Z2UgJCgoMTYjMTI4MCkpIF0gJiYgWyAkZCAtbGUgJCgoMTYjMTJmZikpIF07IH07IHRo
ZW4gZWNobyBLZXBsZXIKICBlbGlmIFsgJGQgLWdlICQoKDE2IzExNDApKSBdICYmIFsg
JGQgLWxlICQoKDE2IzExN2YpKSBdOyB0aGVuIGVjaG8gIkZlcm1pL0tlcGxlciIKICBl
bGlmIHsgWyAkZCAtZ2UgJCgoMTYjMDZjMCkpIF0gJiYgWyAkZCAtbGUgJCgoMTYjMDZk
ZikpIF07IH0gfHwgeyBbICRkIC1nZSAkKCgxNiMwZGMwKSkgXSAmJiBbICRkIC1sZSAk
KCgxNiMwZGZmKSkgXTsgfSBcCiAgICAgICB8fCB7IFsgJGQgLWdlICQoKDE2IzBlMjAp
KSBdICYmIFsgJGQgLWxlICQoKDE2IzBlM2YpKSBdOyB9IHx8IHsgWyAkZCAtZ2UgJCgo
MTYjMGYwMCkpIF0gJiYgWyAkZCAtbGUgJCgoMTYjMGYzZikpIF07IH0gXAogICAgICAg
fHwgeyBbICRkIC1nZSAkKCgxNiMxMDQwKSkgXSAmJiBbICRkIC1sZSAkKCgxNiMxMGJm
KSkgXTsgfSB8fCB7IFsgJGQgLWdlICQoKDE2IzEyMDApKSBdICYmIFsgJGQgLWxlICQo
KDE2IzEyN2YpKSBdOyB9OyB0aGVuIGVjaG8gRmVybWkKICBlbHNlIGVjaG8gIlRlc2xh
IG9yIG9sZGVyIjsgZmkKfQoKIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tIGdyYXBoaWNzCmh3X2dwdXMoKSB7CiAgbG9jYWwgbj0wIG52PW5vIG52aWQ9IiIg
bnZjbGFzcz1ub25lIG52ZmFtPSIiIGFtZD1ubyBpbnRlbD1ubyBvdGhlcj1ubyBzbG90
IHYgZGV2IGNscyBidiBuYW1lcz0iIgogIHdoaWxlIHJlYWQgLXIgc2xvdCB2IGRldiBj
bHMgYnY7IGRvCiAgICBbIC1uICIkc2xvdCIgXSB8fCBjb250aW51ZQogICAgbj0kKChu
ICsgMSkpCiAgICBlY2hvICJncHVfJG49JHY6JGRldjokY2xzOiRzbG90OiRidiIKICAg
IGNhc2UgIiR2IiBpbgogICAgICAxMGRlKSBudj15ZXM7IFsgLXogIiRudmlkIiBdICYm
IG52aWQ9JGRldiA7OwogICAgICAxMDAyKSBhbWQ9eWVzIDs7CiAgICAgIDgwODYpIGlu
dGVsPXllcyA7OwogICAgICAqKSBvdGhlcj15ZXMgOzsKICAgIGVzYWMKICBkb25lIDwg
PChfaHdfcGNpIDAzKQogIGlmIFsgLW4gIiRudmlkIiBdOyB0aGVuIG52Y2xhc3M9JCho
d19udmlkaWFfY2xhc3MgIiRudmlkIik7IG52ZmFtPSQoaHdfbnZpZGlhX2ZhbWlseSAi
JG52aWQiKTsgZmkKICBsb2NhbCBoeWJyaWQ9bm8KICBbICRuIC1nZSAyIF0gJiYgaHli
cmlkPXllcwogIGVjaG8gImdwdV9jb3VudD0kbiIKICBlY2hvICJncHVfbnZpZGlhPSRu
diIKICBlY2hvICJncHVfYW1kPSRhbWQiCiAgZWNobyAiZ3B1X2ludGVsPSRpbnRlbCIK
ICBlY2hvICJncHVfb3RoZXI9JG90aGVyIgogIGVjaG8gIm52aWRpYV9pZD0kbnZpZCIK
ICBlY2hvICJudmlkaWFfY2xhc3M9JG52Y2xhc3MiCiAgZWNobyAibnZpZGlhX2ZhbWls
eT0kbnZmYW0iCiAgZWNobyAiZ3B1X211bHRpPSRoeWJyaWQiCn0KCiMgLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tIFdpLUZpCiMgQnJvYWRjb206
IHdoaWNoIGRyaXZlciBhIGNoaXAgbmVlZHMgKFZFUklGWSBsaXN0IGFnYWluc3QgdGhl
IEFyY2ggd2lraSAiQnJvYWRjb20gd2lyZWxlc3MiIHRhYmxlKS4KIyAgIGJ1aWx0
aW4gIGJyY21mbWFjL2JyY21zbWFjIGluIHRoZSBGZWRvcmEga2VybmVsICsgbGludXgt
ZmlybXdhcmU6IG5vdGhpbmcgdG8gaW5zdGFsbAojICAgd2wgICAgICAgQnJvYWRj
b20ncyBvd24gZHJpdmVyOiBha21vZC13bCAoUlBNIEZ1c2lvbiBub25mcmVlKQoj
ICAgYjQzICAgICAgb25seSB0aGUgb2xkIGI0MyBkcml2ZXIgd29ya3M6IGZpcm13
YXJlIG11c3QgYmUgY3V0IHdpdGggYjQzLWZ3Y3V0dGVyIChtYW51YWwpCmh3X2Jy
b2FkY29tX2RyaXZlcigpIHsKICBjYXNlICIkMSIgaW4KICAgIDQzYTN8NDNiYXw0
M2JifDQzYmN8NDNlY3w0M2RjfDQ0NjR8NDQ4OHw0NDI1fDQ0MzN8NDQxNXw0M2Vm
fDQzNTR8NDM1NSkgZWNobyBidWlsdGluIDs7ICAgIyBicmNtZm1hYwogICAgNDM1
N3w0NzI3fDQzNTMpIGVjaG8gYnVpbHRpbiA7OyAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgIyBicmNtc21hYyAoNDMyMjUsIDQzMTMsIDQzMjI0KQogICAgNDMx
MXw0MzEyfDQzMTV8NDMyOHw0MzI5fDQzMmF8NDMyYnw0MzJjfDQzMmR8NDMz
MXw0MzU4fDQzNTl8NDM2MHw0MzY1fDQzYTB8NDNiMXw0M2IyKSBlY2hvIHds
IDs7CiAgICA0MzAxfDQzMDZ8NDMwN3w0MzE4fDQzMTl8NDMyMHw0MzI0fDQz
MjUpIGVjaG8gYjQzIDs7CiAgICAqKSBlY2hvIHVua25vd24gOzsKICBlc2Fj
Cn0KaHdfd2lmaSgpIHsKICBsb2NhbCBuPTAgc2xvdCB2IGRldiBjbHMgYnYg
a2luZD0iIiBiZHJ2PW5vbmUgbmVlZHM9bm8gaWRzPSIiCiAgd2hpbGUgcmVh
ZCAtciBzbG90IHYgZGV2IGNscyBidjsgZG8KICAgIFsgLW4gIiRzbG90IiBd
IHx8IGNvbnRpbnVlCiAgICBuPSQobiagMSkpOyBpZHM9IiRpZHMgJHY6JGRl
 diIKICAgIGVjaG8gIndpZmlfJG49JHY6JGRldiIKICAgIGNhc2UgIiR2IiBp
bgogICAgICAxNGU0KSBraW5kPSR7a2luZDotYnJvYWRjb219OyBiZHJ2PSQo
aHdfYnJvYWRjb21fZHJpdmVyICIkZGV2Iik7IGNhc2UgIiRiZHJ2IiBpbiB3
bHxiNDN8dW5rbm93bikgbmVlZHM9eWVzIDs7IGVzYWMgOzsKICAgICAgODA4
Nikga2luZD0ke2tpbmQ6LWludGVsfSA7OwogICAgICAxNGMzKSBraW5kPSR7
a2luZDotbWVkaWF0ZWt9IDs7CiAgICAgIDEwZWMpIGtpbmQ9JHtraW5kOi1y
ZWFsdGVrfSA7OwogICAgICAxNjhjfDE3Y2IpIGtpbmQ9JHtraW5kOi1hdGhl
cm9zfSA7OwogICAgICAqKSBraW5kPSR7a2luZDotb3RoZXJ9IDs7CiAgICBl
c2FjCiAgZG9uZSA8IDwoX2h3X3BjaSAwMjgwKQogICMgV2ktRmkgdGhhdCBp
c24ndCBvbiBQQ0kgKFVTQiBhZGFwdGVycywgU0RJTyk6IG9ubHkgdmlzaWJs
ZSBvbmNlIGEgZHJpdmVyIGlzIGxvYWRlZAogIGxvY2FsIHcgbm9ucGNpPW5v
CiAgZm9yIHcgaW4gIiRIV19ST09UIi9zeXMvY2xhc3MvbmV0Lyovd2lyZWxl
c3M7IGRvIFsgLWQgIiR3IiBdICYmIG5vbnBjaT15ZXM7IGRvbmUKICBbICRu
IC1lcSAwIF0gJiYgWyAiJG5vbnBjaSIgPSB5ZXMgXSAmJiBraW5kPW90aGVy
CiAgZWNobyAid2lmaV9jb3VudD0kbiIKICBlY2hvICJ3aWZpX3ZlbmRvcj0k
JHtraW5kOi1ub25lfSIKICBlY2hvICJ3aWZpX2Jyb2FkY29tX2RyaXZlcj0k
YmRydiIKICBlY2hvICJ3aWZpX25lZWRzX2RyaXZlcj0kbmVlZHMiCiAgZWNo
byAid2lmaV9pZHM9JHtpZHMjIH0iCn0KCiMgLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLSB3aXJlZCBuZXR3b3Jr
Cmh3X2V0aGVybmV0KCkgewogIGxvY2FsIG49MCBzbG90IHYgZGV2IGNscyBi
diBraW5kPSIiCiAgd2hpbGUgcmVhZCAtciBzbG90IHYgZGV2IGNscyBidjsg
ZG8KICAgIFsgLW4gIiRzbG90IiBdIHx8IGNvbnRpbnVlCiAgICBuPSQobigg
MSkpCiAgICBjYXNlICIkdiIgaW4gMTBlYykga2luZD0ke2tpbmQ6LXJlYWx0
ZWt9IDs7IDgwODYpIGtpbmQ9JHtraW5kOi1pbnRlbH0gOzsKICAgICAgMTRl
NCkga2luZD0ke2tpbmQ6LWJyb2FkY29tfSA7OyAxOTY5KSBraW5kPSR7a2lu
ZDotYXRoZXJvc30gOzsKICAgICAgKikga2luZD0ke2tpbmQ6LW90aGVyfSA7
OwogICAgZXNhYwogIGRvbmUgPCA8KF9od19wY2kgMDIwMCkKICBlY2hvICJl
dGhfY291bnQ9JG4iCiAgZWNobyAiZXRoX3ZlbmRvcj0ke2tpbmQ6LW5vbmV9
Igp9CgojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLSBkcml2ZXJzCmh3X3N0b3JhZ2UoKSB7CiAgbG9jYWwgZCBuPTAgbmFt
ZSByb3Qga2luZCBzaXplIGdiIG52bWU9bm8gc3NkPW5vIGhkZD1ubwogIGZv
ciBkIGluICIkSFdfUk9PVCIvc3lzL2Jsb2NrLyo7IGRvCiAgICBbIC1kICIk
ZCIgXSB8fCBjb250aW51ZQogICAgbmFtZT0ke2QjIyovfQogICAgY2FzZSAi
JG5hbWUiIGluIGxvb3AqfHJhbSp8enJhbSp8c3IqfGZkKnxkbS0qfG1kKnwK
bmJkKnxtbWNibGsqYm9vdCp8bW1jYmxrKnJwbWIpIGNvbnRpbnVlIDs7IGVz
YWMKICAgIFsgIikoX2h3X3JlYWQgIi9zeXMvYmxvY2svJG5hbWUvcmVtb3Zh
YmxlIikpIiA9IDEgXSAmJiBjb250aW51ZQogICAgcmVhZGxpbmsgLWYgIiRk
L2RldmljZSIgMj4vZGV2L251bGwgfCBncmVwIC1xICcvdXNiJyAmJiBjb250
aW51ZQogICAgc2l6ZT0kKF9od19yZWFkICIvc3lzL2Jsb2NrLyRuYW1lL3Np
emUiKTsgc2l6ZT0ke3NpemU6LTB9CiAgICBnYj0kKChzaXplIC8gMjA5NzE1
MikpCiAgICBbICIkZ2IiIC1nZSAxIF0gfHwgY29udGludWUKICAgIHJvdD0k
KF9od19yZWFkICIvc3lzL2Jsb2NrLyRuYW1lL3F1ZXVlL3JvdGF0aW9uYWwi
KQogICAgY2FzZSAiJG5hbWUiIGluCiAgICAgIG52bWUqKSBraW5kPW52bWU7
IG52bWU9eWVzIDs7CiAgICAgIG1tY2JsayopIGtpbmQ9ZW1tYyA7OwogICAg
ICAqKSBpZiBbICIkcm90IiA9IDEgXTsgdGhlbiBraW5kPWhkZDsgaGRkPXll
czsgZWxzZSBraW5kPXNzZDsgc3NkPXllczsgZmkgOzsKICAgIGVzYWMKICAg
IG49JCgobiArIDEpKQogICAgZWNobyAiZGlza18kbj0kbmFtZToka2luZDok
Z2IiCiAgZG9uZQogIGVjaG8gImRpc2tfY291bnQ9JG4iCiAgZWNobyAiZGlz
a19udm1lPSRudm1lIgogIGVjaG8gImRpc2tfc3NkPSRzc2QiCiAgZWNobyAi
ZGlza19oZGQ9JGhkZCIKfQoKIyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLSBiYXR0ZXJ5Cmh3X2JhdHRlcnkoKSB7CiAg
bG9jYWwgcCBoYXM9bm8KICBmb3IgcCBpbiAiJEhXX1JPT1QiL3N5cy9jbGFz
cy9wb3dlcl9zdXBwbHkvKjsgZG8KICAgIFsgIikoX2h3X3JlYWQgIi9zeXMv
Y2xhc3MvcG93ZXJfc3VwcGx5LyR7cCMjKi99L3R5cGUiKSIgPSBCYXR0
ZXJ5IF0gfHwgY29udGludWUKICAgIFsgIikoX2h3X3JlYWQgIi9zeXMvY2xh
c3MvcG93ZXJfc3VwcGx5LyR7cCMjKi99L3Njb3BlIikpIiA9IERldmlj
ZSBdICYmIGNvbnRpbnVlICAgIyBtb3VzZSAvIGtleWJvYXJkIGJhdHRlcmll
cwogICAgaGFzPXllcwogIGRvbmUKICBlY2hvICJiYXR0ZXJ5PSRoYXMiCn0K
CiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0gZXZlcnl0aGluZwpod19hbGwoKSB7CiAgaHdfY3B1OyBod19yYW07IGh3
X2Zpcm13YXJlOyBod19kbWk7IGh3X21hYzsgaHdfZ3B1czsgaHdfd2lmaTsg
aHdfZXRoZXJuZXQ7IGh3X3N0b3JhZ2U7IGh3X2JhdHRlcnkKICAjIEEgbGFw
dG9wIChiYXR0ZXJ5IG9yIGxhcHRvcCBjaGFzc2lzKSB3aXRoIHR3byBncmFw
aGljcyBjaGlwcyA9IHN3aXRjaGFibGUgLyBoeWJyaWQgZ3JhcGhpY3MgKE9w
dGltdXMgZXRjLikKICBsb2NhbCBtdWx0aSBiYXQgY2gKICBtdWx0aT0kKGh3
X2dwdXMgfCBzZWQgLW4gJ3MvXmdwdV9tdWx0aT0vL3AnKTsgYmF0PSQoaHdf
YmF0dGVyeSB8IHNlZCAtbiAncy9eYmF0dGVyeT0vL3AnKTsgY2g9JChod19k
bWkgfCBzZWQgLW4gJ3MvXmRtaV9jaGFzc2lzPS8vcCcpCiAgaWYgWyAiJG11
bHRpIiA9IHllcyBdICYmIHsgWyAiJGJhdCIgPSB5ZXMgXSB8fCBbICIkY2gi
ID0gbGFwdG9wIF07IH07IHRoZW4gZWNobyAiaHlicmlkPXllcyI7IGVsc2Ug
ZWNobyAiaHlicmlkPW5vIjsgZmkKfQoKSFdfQ0FDSEU9IiIKaHdfZ2V0KCkg
eyAgICMgaHdfZ2V0IEtFWSAgIChydW5zIGh3X2FsbCBvbmNlIHBlciBzaGVs
bCkKICBbIC1uICIkSFdfQ0FDSEUiIF0gfHwgSFdfQ0FDSEU9JChod19hbGwp
CiAgcHJpbnRmICclc1xuJyAiJEhXX0NBQ0hFIiB8IHNlZCAtbiAicy9eJDE9
Ly9wIiB8IGhlYWQgLW4xCn0KCiMgUnVuIGRpcmVjdGx5OiBwcmludCBldmVy
eXRoaW5nCiMgKGNvbXBhdC1jaGVjay5zaCBjYXJyaWVzIGEgdmVyYmF0aW0g
Y29weSBvZiB0aGlzIGZpbGUgYW5kIHNldHMgSFdfRU1CRURERUQ9MSkKaWYg
WyAiJHtCQVNIX1NPVVJDRVswXX0iID0gIiQwIiBdICYmIFsgLXogIiR7SFdf
RU1CRURERUQ6LX0iIF07IHRoZW4KICB3aGlsZSBbICQjIC1ndCAwIF07IGRv
CiAgICBjYXNlICIkMSIgaW4KICAgICAgLS1maXh0dXJlKSBIV19ST09U
PSR7MiUvfTsgc2hpZnQgOzsKICAgICAgLWh8LS1oZWxwKSBzZWQgLW4gJzIs
MTVwJyAiJDAiOyBleGl0IDAgOzsKICAgIGVzYWMKICAgIHNoaWZ0CiAgZG9u
ZQogIGh3X2FsbApmaQojID09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09
PT09PT09PT09IEVORCBkZXRlY3Quc2gKCmRlY2xhcmUgLUEgSAp3aGlsZSBJ
RlM9Jz0nIHJlYWQgLXIgayB2OyBkbyBbIC1uICIkayIgXSAmJiBIWyRrXT0k
djsgZG9uZSA8IDwoaHdfYWxsKQpnKCkgeyBwcmludGYgJyVzJyAiJHtIWyQx
XTotfSI7IH0KCmlmIFsgJEFTQ0lJID0gMSBdOyB0aGVuIFNfT0s9J1sgT0sg
XSc7IFNfTk9URT0nW05PVEVdJzsgU19OTz0nWyBOTyBdJzsgU19JTkZPPSdb
SU5GT10nCmVsc2UgU19PSz0n4pyTJzsgU19OT1RFPSfimqAnOyBTX05PPSfi
nJcnOyBTX0lORk89J+KAoic7IGZpCgpMSU5FUz0oKSBOT1RFUz0wIEJMT0NL
RVJTPTAgQkxPQ0tFUl9URVhUPSIiIEFT Sz0wIFdJUkVEPTAgQVNBSEk9
MCBURVhUPTAgUFJPRklMRT1mdWxsIFdIWT0iIgpfYWRkKCkgeyAgICMgX2Fk
ZCBva3xub3RlfG5vfGluZm8gImZpcnN0IGxpbmUiIFsibW9yZSBsaW5l
cyIuLi5dCiAgbG9jYWwga2luZD0kMSBzeW0gbDsgc2hpZnQKICBjYXNl
ICIka2luZCIgaW4gb2spIHN5bT0kU19PSyA7OyBub3RlKSBzeW09JFNfTk9U
RTsgTk9URVM9JCgoTk9URVMgKyAxKSkgOzsgbm8pIHN5bT0kU19OTzsgQkxP
Q0tFUlM9JCgoQkxPQ0tFUlMgKyAxKSkgOzsgKikgc3ltPSRTX0lORk8gOzsg
ZXNhYwogIFsgIiRraW5kIiA9IG5vIF0gJiYgQkxPQ0tFUl9URVhUPSIke0JM
T0NLRVJfVEVYVDorJEJMT0NLRVJfVEVYVDsgfSQxIgogIGlmIFsgJEJSSUVG
ID0gMSBdICYmIHsgWyAiJGtpbmQiID0gb2sgXSB8fCBbICIka2luZCIgPSBp
bmZvIF07IH07IHRoZW4gcmV0dXJuIDA7IGZpCiAgTElORVMrPSgiICAkc3lt
ICQxIikKICBzaGlmdAogIGZvciBsIGluICIkQCI7IGRvIExJTkVTKz0oIiAg
ICAgICRsIik7IGRvbmUKfQoKQVJDSD0kKGcgY3B1X2FyY2gpIE1BQ0s9JChn
IG1hY19raW5kKSBTQj0kKGcgc2VjdXJlX2Jvb3QpIFJBTT0kKGcgcmFt
X21iKSBMRVZFTD0kKGcgY3B1X3g4Nl9sZXZlbCkKTUFLRVI9JChnIGRtaV9t
YWtlcikgUFJPRFVDVD0kKGcgZG1pX3Byb2R1Y3QpIEZBTUlMWT0kKGcg
ZG1pX2ZhbWlseSkKUkFNPSR7UkFNOi0wfTsgTEVWRUw9JHtMRVZFTDot
MH0KUkFNX0dCPSQoYXdrIC12IG09IiRSQU0iICdCRUdJTiB7IHByaW50
ZiAiJS4xZiIsIG0gLyAxMDI0IH0nKQpDUFVGTEFHUz0iICQoYXdrIC1G
JzogKicgJy9eZmxhZ3Mve3ByaW50ICQyOyBleGl0fScgIiRIV19ST09U
L3Byb2MvY3B1aW5mbyIgMj4vZGV2L251bGwpICIKTkVFRFNfS0VZPTAg
ICAjIGEgZHJpdmVyIGJ1aWx0IG9uIHRoaXMgY29tcHV0ZXIgKE5WSURJ
QSwgQnJvYWRjb20gd2wpICsgU2VjdXJlIEJvb3Qgb24gPSBhcHByb3Zl
IGEga2V5IG9uY2UKCiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLSB3aGljaCBMaW51eCAoSFdfRElTVFJPKQojIEZlZG9yYSA0
NC80NSB4ODZfNjQgcnVucyBvbiBhbnkgNjQtYml0IHg4NiBDUFUgKGJh
c2VsaW5lIHg4Ni02NC12MSkgd2l0aCAyIEdCKy4gQmVsb3cgdGhhdCwg
RGViaWFuLgojIE1lbW9yeSBiYW5kcyAoa2VybmVsLXZpc2libGUgTUIs
IHdpdGggbWFyZ2lucyBiZWNhdXNlIHNoYXJlZC1HUFUgbWFjaGluZXMg
dW5kZXItcmVwb3J0KToKIyB1bmRlciA0ODA6IHVuc3VwcG9ydGVkOyA0
ODAtMTY5OTogZGViaWFuLWxpdGU7IDE3MDAtMjk5OTogZmVkb3JhLW1p
biAoRmVkb3JhLCBsaWdodCBMWFF0IGRlc2t0b3ApOwojIDMwMDArOiBm
ZWRvcmEgKHRoZSBkZXNrdG9wIHRpZXIsIGZ1bGwgb3IgbGl0ZSwgaXMg
Y2hvc2VuIHNlcGFyYXRlbHkgYmVsb3cpLgojIERlYmlhbiAxMyBoYXMg
bm8gMzItYml0IFBDIChpMzg2KSBpbnN0YWxsZXIgb3Iga2VybmVsOyBE
ZWJpYW4gMTIgaTM4NiBoYXMgTFRTIHVudGlsIDMwIEp1bmUgMjAyOC4K
RElTVFJPPWZlZG9yYSBSRUFTT049IjY0LWJpdCBJbnRlbC9BTUQgUEMg
d2l0aCAke1JBTV9HQn0gR0IgbWVtb3J5OiBGZWRvcmEsIHRoZSBub3Jt
YWwgcGF0aCIKY2FzZSAiJEFSQ0giIGluCiAgYWFyY2g2NHxhcm02NHxh
cm0qKQogICAgaWYgWyAiJE1BQ0siID0gYXBwbGUtc2lsaWNvbiBdOyB0
aGVuIERJU1RSTz1hc2FoaTsgUkVBU09OPSJBcHBsZSBTaWxpY29uIE1h
YzogRmVkb3JhIEFzYWhpIFJlbWl4LCBpbnN0YWxsZWQgZnJvbSBtYUNP
UyIKICAgIGVsc2UgRElTVFJPPXVuc3VwcG9ydGVkOyBSRUFTT049IkFS
TSBjb21wdXRlciB0aGF0IGlzIG5vdCBhbiBBcHBsZSBTaWxpY29uIE1h
YyI7IGZpIDs7CiAgKikKICAgIGlmIFsgIiQoZyBjcHVfNjRiaXQpIiA9
IHllcyBdOyB0aGVuCiAgICAgIGlmIFsgIiRSQU0iIC1sdCA0ODAgXTsg
dGhlbiBESVNUUk89dW5zdXBwb3J0ZWQ7IFJFQVNPTj0ib25seSAke1JB
TV9HQn0gR0IgbWVtb3J5OiBiZWxvdyB3aGF0IGFueSBjdXJyZW50IGRl
c2t0b3AgTGludXggbmVlZHMgKDUxMiBNQikiCiAgICAgIGVsaWYgWyAi
JFJBTSIgLWx0IDE3MDAgXTsgdGhlbiBESVNUUk89ZGViaWFuLWxpdGU7
IFJFQVNPTj0iNjQtYml0IFBDIHdpdGggb25seSAke1JBTV9HQn0gR0Ig
bWVtb3J5OiBGZWRvcmEgbmVlZHMgMiBHQjsgRGViaWFuIDEzIHdpdGgg
YSBsaWdodCBkZXNrdG9wIGZpdHMiCiAgICAgIGVsaWYgWyAiJE1BQ0si
ID0gaW50ZWwtdDIgXTsgdGhlbiBESVNUUk89ZmVkb3JhLXQyOyBSRUFT
T049IkludGVsIE1hYyB3aXRoIFQyIGNoaXA6IEZlZG9yYSBwbHVzIHRo
ZSB0MmxpbnV4IGtlcm5lbCBmb3IgaXRzIGtleWJvYXJkLCB0cmFja3Bh
ZCwgV2ktRmkgYW5kIHNvdW5kIgogICAgICBlbGlmIFsgIiRSQU0iIC1s
dCAzMDAwIF07IHRoZW4gRElTVFJPPWZlZG9yYS1taW47IFJFQVNPTj0i
RmVkb3JhIHJ1bnMgaGVyZSwgYnV0IHRoZSBkZXNrdG9wIG5lZWRzIHRv
IGJlIHRoZSBsaWdodCBvbmUgKExYUXQpIHNvIHlvdXIgYXBwcyBoYXZl
IHJvb20gdG8gYnJlYXRoZS4gVGhlIGluc3RhbGxlciB3aWxsIHVzZSBz
aW1wbGUgdGV4dCBzY3JlZW5zLiIKICAgICAgZmkKICAgIGVsc2UKICAg
ICAgY2FzZSAiJENQVUZMQUdTIiBpbgogICAgICAgICoiIGNtb3YgIiop
CiAgICAgICAgICBpZiBbICIkUkFNIiAtbHQgNDgwIF07IHRoZW4gRElT
VFJPPXVuc3VwcG9ydGVkOyBSRUFTT049IjMyLWJpdCBQQyB3aXRoIG9u
bHkgJHtSQU1fR0J9IEdCIG1lbW9yeTogYmVsb3cgRGViaWFuJ3MgNTEy
IE1CIG1pbmltdW0iCiAgICAgICAgICBlbHNlIERJU1RSTz1kZWJpYW4t
aTM4NjsgUkVBU09OPSIzMi1iaXQtb25seSBwcm9jZXNzb3I6IEZlZG9y
YSBpcyA2NC1iaXQgb25seTsgRGViaWFuIDEyICgzMi1iaXQpIGlzIHN1
cHBvcnRlZCB1bnRpbCBKdW5lIDIwMjgiOyBmaSA7OwogICAgICAgICop
IERJU1RSTz11bnN1cHBvcnRlZDsgUkVBU09OPSJwcm9jZXNzb3Igb2xk
ZXIgdGhhbiBhIFBlbnRpdW0gUHJvL0lJIChpNjg2KTogbm8gY3VycmVu
dCBMaW51eCBkaXN0cmlidXRpb24gc3VwcG9ydHMgaXQiIDs7CiAgICAg
IGVzYWMKICAgIGZpIDs7CmVzYWMKCiMgLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLSBwcm9jZXNzb3IKY2FzZSAiJEFSQ0gi
IGluCiAgYWFyY2g2NHxhcm02NHxhcm0qKQogICAgaWYgWyAiJE1BQ0si
ID0gYXBwbGUtc2lsaWNvbiBdOyB0aGVuCiAgICAgIEFTQUhJPTEKICAg
ICAgX2FkZCBubyAiQXBwbGUgU2lsaWNvbiBNYWMgKCQoZyBtYWNfbW9k
ZWwpKTogdGhpcyBVU0Igc3RpY2sgY2FuJ3Qgc3RhcnQgaXQuIiBcCiAg
ICAgICAgIkl0IG9ubHkgc3RhcnRzIFBDcyB3aXRoIEludGVsIG9yIEFN
RCBwcm9jZXNzb3JzLiBJbnN0ZWFkLCBpbnN0YWxsIEZlZG9yYSBBc2Fo
aSBSZW1peCIgXAogICAgICAgICJmcm9tIG1hY09TIChUZXJtaW5hbDog
Y3VybCBodHRwczovL2FseC5zaCB8IHNoKSwgdGhlbiBydW4gdGhpcyBw
YWNrYWdlJ3Mgc2V0dXAgb24gaXQuIiBcCiAgICAgICAgIkd1aWRlOiBs
aW51eC1zZXR1cC9hc2FoaS9SRUFETUUubWQgb24gdGhpcyBzdGljay4i
CiAgICBlbHNlCiAgICAgIF9hZGQgbm8gIkFSTSBwcm9jZXNzb3IgKCRB
UkNIKTogdGhpcyBVU0Igc3RpY2sgb25seSBzdGFydHMgSW50ZWwvQU1E
ICh4ODYtNjQpIFBDcy4iCiAgICBmaSA7OwogICopCiAgICBpZiBbICIk
KGcgY3B1XzY0Yml0KSIgIT0geWVzIF07IHRoZW4KICAgICAgX2FkZCBu
byAiMzItYml0IHByb2Nlc3NvciAoJChnIGNwdV9tb2RlbCkpOiBGZWRv
cmEgbmVlZHMgYSA2NC1iaXQgKHg4Ni02NCkgcHJvY2Vzc29yLiIKICAg
IGVsc2UKICAgICAgX2FkZCBvayAiNjQtYml0IHByb2Nlc3NvcjogJChn
IGNwdV9tb2RlbCkgKHg4Ni02NC12JExFVkVMKSIKICAgICAgWyAiJExF
VkVMIiAtbGUgMSBdICYmIF9hZGQgaW5mbyAiVmVyeSBvbGQgcHJvY2Vz
c29yOiBpdCB3b3JrcywgYnV0IHNvbWUgYXBwcyB3aWxsIGJlIHNsb3cu
IExJVEUgc3VnZ2VzdGVkLiIKICAgIGZpIDs7CmVzYWMKCiMgLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLSBtZW1vcnkK
aWYgWyAiJFJBTSIgLWx0IDE3MDAgXTsgdGhlbgogIF9hZGQgbm8gIk1l
bW9yeTogJFJBTV9HQiBHQi4gRmVkb3JhIG5lZWRzIGF0IGxlYXN0IDIg
R0IgKDQgR0Igb3IgbW9yZSByZWNvbW1lbmRlZCkuIgogIFRFWFQ9MQpl
bGlmIFsgIiRSQU0iIC1sdCAzMDAwIF07IHRoZW4KICBfYWRkIG5vdGUg
Ik1lbW9yeTogJFJBTV9HQiBHQjogZW5vdWdoIGZvciB0aGUgbGlnaHRl
c3Qgc2V0dXAgKExYUXQgZGVza3RvcCkuIFRoZSBpbnN0YWxsZXIgcnVu
cyBpbiBpdHMgXAogICAgInNpbXBsZXIgdGV4dCBtb2RlICh1c2VzIGxl
c3MgbWVtb3J5KS4gV2ViIHBhZ2VzIHdpdGggbWFueSB0YWJzIHdpbGwg
YmUgc2xvdy4iCiAgVEVYVD0xCmVsaWYgWyAiJFJBTSIgLWx0IDQ2MDAg
XTsgdGhlbgogIF9hZGQgbm90ZSAiTWVtb3J5OiAkUkFNX0dCIEdCOiBM
SVRFIHNldHVwIHJlY29tbWVuZGVkOyB0aGUgaW5zdGFsbGVyIHJ1bnMg
aW4gdGV4dCBtb2RlIHRvIGJlIHNhZmUuIgogIFRFWFQ9MQplbGlmIFsg
IiRSQU0iIC1sdCA3MDAwIF07IHRoZW4KICBfYWRkIG9rICJNZW1vcnk6
ICRSQU1fR0IgR0IgKExJVEUgc3VnZ2VzdGVkOiBGVUxMIG5lZWRzIDgg
R0IpIgplbHNlCiAgX2FkZCBvayAiTWVtb3J5OiAkUkFNX0dCIEdCIgpm
aQppZiBbICIkUkFNIiAtbHQgNzAwMCBdOyB0aGVuIFBST0ZJTEU9bGl0
ZTsgV0hZPSIkUkFNX0dCIEdCIG1lbW9yeSI7IGZpCmlmIFsgIiRMRVZF
TCIgLWxlIDEgXSAmJiBbICIkQVJDSCIgPSB4ODZfNjQgXTsgdGhlbiBQ
Uk9GSUxFPWxpdGU7IFdIWT0iJHtXSFk6KyRXSFksIH12ZXJ5IG9sZCBw
cm9jZXNzb3IiOyBmaQpbICRBU0FISSA9IDEgXSAmJiB7IFBST0ZJTEU9
ZnVsbDsgV0hZPSJGZWRvcmEgQXNhaGkgUmVtaXggKElERSkiOyBURVhU
PTA7IH0KCiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tIHN0YXJ0LXVwIGZpcm13YXJlIC8gU2VjdXJlIEJvb3QKaWYgWyAk
QVNBSEkgPSAwIF07IHRoZW4KICBpZiBbICIkKGcgZmlybXdhcmUpIiA9
IHVlZmkgXTsgdGhlbgogICAgaWYgWyAiJChnIGVmaV9iaXRzKSIgPSAz
MiBdOyB0aGVuCiAgICAgIF9hZGQgbm90ZSAiMzItYml0IFVFRkkgZmly
bXdhcmUgd2l0aCBhIDY0LWJpdCBwcm9jZXNzb3I6IHRoaXMgc3RpY2sg
bWF5IG5vdCBzdGFydC4iIFwKICAgICAgICAiSWYgaXQgZG9lc24ndCwg
c3dpdGNoIHRoZSBmaXJtd2FyZSB0byBMZWdhY3kvQ1NNIGJvb3QgKGlm
IGl0IGhhcyB0aGF0IG9wdGlvbikuIgogICAgZWxzZQogICAgICBfYWRk
IG9rICJVRUZJIHN0YXJ0LXVwIGZpcm13YXJlIgogICAgZmkKICAgIGNh
c2UgIiRTQiIgaW4KICAgICAgb24pIF9hZGQgb2sgIlNlY3VyZSBCb290
IGlzIG9uOiBmaW5lLCBGZWRvcmEgaXMgc2lnbmVkIChrZWVwIGl0IG9u
KSIgOzsKICAgICAgb2ZmKSBfYWRkIG9rICJTZWN1cmUgQm9vdCBpcyBv
ZmY6IGZpbmUgKHlvdSBjYW4gc3dpdGNoIGl0IG9uIGFmdGVyIGluc3Rh
bGxpbmcpIiA7OwogICAgZXNhYwogIGVsc2UKICAgIF9hZGQgb2sgIkxl
Z2FjeSBCSU9TIHN0YXJ0LXVwIChubyBVRUZJKTogZmluZSwgRmVkb3Jh
IGluc3RhbGxzIHRoZSBjbGFzc2ljIHdheSIKICBmaQpmaQoKIyAtLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLSBNYWNzIGFu
ZCBtYWtlcnMKY2FzZSAiJE1BQ0siIGluCiAgaW50ZWwtdDIpCiAgICBB
U0s9MTsgV0lSRUQ9MQogICAgX2FkZCBub3RlICJNYWMgd2l0aCBBcHBs
ZSdzIFQyIGNoaXAgKCQoZyBtYWNfbW9kZWwpKTogRmVkb3JhIGluc3Rh
bGxzLCB0aGVuIHNldHVwIGFkZHMgdGhlIiBcCiAgICAgICJ0MmxpbnV4
IGtlcm5lbCBzbyB0aGUgYnVpbHQtaW4ga2V5Ym9hcmQsIHRyYWNrcGFk
LCBUb3VjaCBCYXIgYW5kIHNvdW5kIHdvcmsuIFVudGlsIHRoZW4iIFwK
ICAgICAgInVzZSBhIFVTQiBrZXlib2FyZCArIG1vdXNlIGFuZCBhIHdp
cmVkIGNvbm5lY3Rpb24gKFVTQiBFdGhlcm5ldCBvciBwaG9uZSBVU0Ig
dGV0aGVyaW5nKS4iIFwKICAgICAgIldpLUZpIG5lZWRzIEFwcGxlJ3Mg
ZmlybXdhcmU6IEJFRk9SRSBlcmFzaW5nIG1hY09TLCBydW4gZ2V0LWFw
cGxlLWZpcm13YXJlLnNoIGZyb20gdGhpcyIgXAogICAgICAic3RpY2sg
KGxpbnV4LXNldHVwL2xpbnV4L2h3L21hYykgaW4gbWFjT1MgVGVybWlu
YWwuIE5lZWRlZCBpbiBtYWNPUyBSZWNvdmVyeSA+IFN0YXJ0dXAgU2Vj
dXJpdHkiIFwKICAgICAgIlV0aWxpdHk6ICdObyBTZWN1cml0eScgKyAn
QWxsb3cgYm9vdGluZyBmcm9tIGV4dGVybmFsIG1lZGlhJy4gWW91IGNh
biBjYW5jZWwgYW5kIGtlZXAgbWFjT1MuIiA7OwogIGludGVsKQogICAg
X2FkZCBvayAiSW50ZWwgTWFjICgkKGcgbWFjX21vZGVsKSk6IHN1cHBv
cnRlZC4gRnVuY3Rpb24ga2V5cyBhcmUgc2V0IHRvIHdvcmsgbGlrZSBh
IFBDJ3MiIFwKICAgICAgIihwcmVzcyBGbiBmb3IgYnJpZ2h0bmVzcy92
b2x1bWUpIGFuZCBmYW4gY29udHJvbCAobWJwZmFuKSBpcyBhZGRlZCBm
b3IgTWFjQm9va3MuIgogICAgWyAiJChnIG1hY19mYWNldGltZWhkKSIg
PSB5ZXMgXSAmJiBfYWRkIG5vdGUgIlRoZSBidWlsdC1pbiBGYWNlVGlt
ZSBIRCBjYW1lcmEgbmVlZHMgYSBkcml2ZXIgRmVkb3JhIGRvZXNuJ3Qg
aW5jbHVkZSwiIFwKICAgICAgInNvIGl0IHdvbid0IHdvcmsgKGEgVVNC
IHdlYmNhbSB3aWxsKS4gZG9jcy9DT01QQVRJQklMSVRZLm1kIGhhcyB0
aGUgb3B0aW9uYWwgbWFudWFsIHN0ZXBzLiIKICAgIDs7CmVzYWMKY2Fz
ZSAiJE1BS0VSIiBpbgogIHRvc2hpYmEpIF9hZGQgaW5mbyAiVG9zaGli
YTogaG90a2V5cywgYmFja2xpZ2h0IGFuZCBCbHVldG9vdGggc3dpdGNo
IHVzZSBGZWRvcmEncyBidWlsdC1pbiB0b3NoaWJhX2FjcGkgZHJpdmVy
LiIgOzsKICBkZWxsKSAgICBfYWRkIGluZm8gIkRlbGw6IGtleWJvYXJk
IGxpZ2h0IGFuZCBob3RrZXlzIHVzZSBGZWRvcmEncyBidWlsdC1pbiBk
ZWxsLWxhcHRvcCBkcml2ZXIuIiA7OwogIGxlbm92bykgIF9hZGQgaW5m
byAiTGVub3ZvOiBUaGlua1BhZCBidXR0b25zLCBrZXlib2FyZCBsaWdo
dCBhbmQgYmF0dGVyeSBjaGFyZ2UgbGltaXRzIHdvcmsgb3V0IG9mIHRo
ZSBib3guIiA7OwogIG1pY3Jvc29mdCkKICAgIF9hZGQgbm90ZSAiTWlj
cm9zb2Z0IFN1cmZhY2U6IHRoZSB0b3VjaCBzY3JlZW4sIHBlbiwgY2Ft
ZXJhcyBhbmQgc29tZSBrZXlib2FyZCBjb3ZlcnMgbmVlZCB0aGUiIFwK
ICAgICAgImxpbnV4LXN1cmZhY2Uga2VybmVsIChub3QgaW5jbHVkZWQp
LiBVc2UgYSBVU0Iga2V5Ym9hcmQgaWYgdGhlIGNvdmVyIGRvZXNuJ3Qg
cmVzcG9uZC4iIDs7CiAgZ29vZ2xlKQogICAgX2FkZCBub3RlICJDaHJv
bWVib29rOiBvbmx5IHdvcmtzIHdpdGggY3VzdG9tIFVFRkkgZmlybXdh
cmUgKE1yQ2hyb21lYm94KS4gU3BlYWtlcnMgYW5kIiBcCiAgICAgICJt
aWNyb3Bob25lIG9mdGVuIGRvbid0IHdvcms7IGNoZWNrIHRoZSBtb2Rl
bCBvbiBkb2NzLm1yY2hyb21lYm94LnRlY2ggZmlyc3QuIiA7Owplc2Fj
CgojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLSBncmFwaGljcwpOVj0kKGcgbnZpZGlhX2NsYXNzKSBOVkY9JChn
IG52aWRpYV9mYW1pbHkpCmNhc2UgIiROViIgaW4KICBtb2Rlcm4pCiAg
ICBfYWRkIG5vdGUgIk5WSURJQSAkTlZGIGdyYXBoaWNzOiBOVklESUEncy
Bkcml2ZXIgaW5zdGFsbHMgYnkgaXRzZWxmIGR1cmluZyBzZXR1cCIgXAog
ICAgICAiKHVudGlsIHRoZW4gdGhlIG9wZW4tc291cmNlIGRyaXZlciBp
cyB1c2VkOiBpdCB3b3JrcywgYnV0IGdhbWVzIGFyZSBzbG93KS4iCiAg
ICBORUVEU19LRVk9MSA7OwogIDU4MHh4KQogICAgX2FkZCBub3RlICJO
VklESUEgJE5WRiBncmFwaGljczogTlZJRElBJ3MgNTgwIGRyaXZlciBz
ZXJpZXMgKHRoZSBsYXN0IG9uZSBmb3IgdGhpcyBjYXJkKSIgXAogICAg
ICAiaW5zdGFsbHMgYnkgaXRzZWxmIGR1cmluZyBzZXR1cC4iCiAgICBO
RUVEU19LRVk9MSA7OwogIGxlZ2FjeSkKICAgIF9hZGQgbm90ZSAiTlZJ
RElBICROVkYgZ3JhcGhpY3MgKG9sZGVyIGNhcmQpOiB1c2VzIHRoZSBi
dWlsdC1pbiBvcGVuLXNvdXJjZSBkcml2ZXIgKG5vdXZlYXUpLiIKICAg
ICAgIkRlc2t0b3AgYW5kIHZpZGVvIHdvcms7IDNEIGdhbWVzIGFyZSBz
bG93LiBOVklESUEncyBvd24gZHJpdmVyIGRvZXNuJ3Qgc3VwcG9ydCIg
XAogICAgICAidGhpcyBjYXJkIG9uIGN1cnJlbnQgRmVkb3JhLiIgOzsK
ZXNhYwpbICIkKGcgZ3B1X2FtZCkiID0geWVzIF0gJiYgX2FkZCBvayAi
QU1EIFJhZGVvbiBncmFwaGljczogd29ya3Mgb3V0IG9mIHRoZSBib3gi
ClsgIiQoZyBncHVfaW50ZWwpIiA9IHllcyBdICYmIF9hZGQgb2sgIklu
dGVsIGdyYXBoaWNzOiB3b3JrcyBvdXQgb2YgdGhlIGJveCIKWyAiJChn
IGh5YnJpZCkiID0geWVzIF0gJiYgX2FkZCBvayAiVHdvIGdyYXBoaWNz
IGNoaXBzIChzd2l0Y2hhYmxlKTogYXBwcyB1c2UgdGhlIHBvd2VyLXNh
dmluZyBvbmU7IGZvciBnYW1lcywiIFwKICAgInJpZ2h0LWNsaWNrIHRo
ZSBhcHAgPiAnTGF1bmNoIHVzaW5nIERlZGljYXRlZCBHcmFwaGljcyBD
YXJkJy4iCgojIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLSBuZXR3b3JrCldWPSQoZyB3aWZpX3ZlbmRvcikgQkRSVj0kKGcg
d2lmaV9icm9hZGNvbV9kcml2ZXIpIEVUSD0kKGcgZXRoX2NvdW50KQpp
ZiBbICIkTUFDSyIgIT0gaW50ZWwtdDIgXSAmJiBbICRBU0FISSA9IDAg
XTsgdGhlbgogIGNhc2UgIiRXVjokQkRSViIgaW4KICAgIGJyb2FkY29t
OndsKQogICAgICBfYWRkIG5vdGUgIkJyb2FkY29tIFdpLUZpICgkKGcg
d2lmaV9pZHMpKTogd29ya3MgYWZ0ZXIgc2V0dXAgaW5zdGFsbHMgQnJv
YWRjb20ncyBkcml2ZXIuIiBcCiAgICAgICAgIkR1cmluZyB0aGUgaW5z
dGFsbGF0aW9uIGl0c2VsZiB1c2UgRXRoZXJuZXQgb3IgcGhvbmUgVVNC
IHRldGhlcmluZy4iCiAgICAgIFdJUkVEPTE7IE5FRURTX0tFWT0xIDs7
CiAgICBicm9hZGNvbTpiNDMpCiAgICAgIF9hZGQgbm90ZSAiT2xkIEJy
b2FkY29tIFdpLUZpICgkKGcgd2lmaV9pZHMpKTogbmVlZHMgZmlybXdh
cmUgdGhhdCBjYW4ndCBiZSBpbmNsdWRlZC4iIFwKICAgICAgICAiVXNl
IEV0aGVybmV0OyBkb2NzL0NPTVBBVElCSUxJVFkubWQgc2hvd3MgdGhl
IG9uZS10aW1lIGI0My1md2N1dHRlciBzdGVwLiIKICAgICAgV0lSRUQ9
MSA7OwogICAgYnJvYWRjb206dW5rbm93bikKICAgICAgX2FkZCBub3Rl
ICJCcm9hZGNvbSBXaS1GaSBjaGlwIG5vdCBpbiBvdXIgbGlzdCAoJChn
IHdpZmlfaWRzKSk6IGl0IG1heSBuZWVkIGFuIGV4dHJhIGRyaXZlci4i
IFwKICAgICAgICAiVXNlIEV0aGVybmV0IG9yIHBob25lIFVTQiB0ZXRo
ZXJpbmcgZHVyaW5nIHRoZSBpbnN0YWxsYXRpb24uIgogICAgICBXSVJF
RD0xIDs7CiAgICBicm9hZGNvbTpidWlsdGluKSBfYWRkIG9rICJXaS1G
aTogQnJvYWRjb20gKGRyaXZlciBidWlsdCBpbnRvIEZlZG9yYSkiIDs7
CiAgICBpbnRlbDoqKSAgICBfYWRkIG9rICJXaS1GaTogSW50ZWwgKHdv
cmtzIG91dCBvZiB0aGUgYm94KSIgOzsKICAgIG1lZGlhdGVrOiopIF9h
ZGQgb2sgIldpLUZpOiBNZWRpYVRlayAod29ya3Mgb3V0IG9mIHRoZSBi
b3gpIiA7OwogICAgcmVhbHRlazoqKSAgX2FkZCBvayAiV2ktRmk6IFJl
YWx0ZWsgKHdvcmtzIG91dCBvZiB0aGUgYm94KSIgOzsKICAgIGF0aGVy
b3M6KikgIF9hZGQgb2sgIldpLUZpOiBRdWFsY29tbSBBdGhlcm9zICh3
b3JrcyBvdXQgb2YgdGhlIGJveCkiIDs7CiAgICBvdGhlcjoqKSAgICAg
X2FkZCBpbmZvICJXaS1GaTogcHJlc2VudCAodW5rbm93biBtYWtlOiBj
aGVjayBpdCBhZnRlciBpbnN0YWxsaW5nKSIgOzsKICAgIG5vbmU6Kikg
ICAgIF9hZGQgaW5mbyAiTm8gYnVpbHQtaW4gV2ktRmkgZm91bmQiIDs7
CiAgZXNhYwogIGlmIFsgIiR7RVRIOi0wfSIgLWd0IDAgXTsgdGhlbiBf
YWRkIG9rICJFdGhlcm5ldCBwb3J0OiAkKGcgZXRoX3ZlbmRvcikiCiAg
ZWxpZiBbICRXSVJFRCA9IDEgXTsgdGhlbgogICAgX2FkZCBpbmZvICJO
byBFdGhlcm5ldCBwb3J0OiBwbHVnIGluIHlvdXIgcGhvbmUgYnkgVVNC
IGFuZCB0dXJuIG9uICdVU0IgdGV0aGVyaW5nJywgb3IgdXNlIGEgVVNC
IEV0aGVybmV0IGFkYXB0ZXIuIgogIGZpCiAgaWYgWyAiJFdWIiA9IG5v
bmUgXSAmJiBbICIke0VUSDotMH0iID0gMCBdOyB0aGVuCiAgICBfYWRk
IG5vdGUgIk5vIFdpLUZpIG9yIEV0aGVybmV0IGZvdW5kOiBpbnN0YWxs
aW5nIG5lZWRzIGludGVybmV0IChwaG9uZSBVU0IgdGV0aGVyaW5nIHdv
cmtzKS4iCiAgICBXSVJFRD0xCiAgZmkKZmkKaWYgWyAkTkVFRFNfS0VZ
ID0gMSBdICYmIFsgIiRTQiIgPSBvbiBdOyB0aGVuCiAgX2FkZCBub3Rl
ICJTZWN1cmUgQm9vdCArIGEgZHJpdmVyIGJ1aWx0IG9uIHRoaXMgY29t
cHV0ZXI6IG9uY2UsIGFmdGVyIHNldHVwLCBhIGJsdWUgJ01PSyBtYW5h
Z2VtZW50JyIgXAogICAgInNjcmVlbiBhcHBlYXJzIGF0IHJlc3RhcnQu
IENob29zZSBFbnJvbGwgTU9LID4gQ29udGludWUgPiBZZXMsIHR5cGUg
dGhlIG9uZS10aW1lIGNvZGUiIFwKICAgICJTZWN1cmUgTGludXggc2hv
d3MgeW91LCB0aGVuIFJlYm9vdC4gKFNraXAgaXQgYW5kIHRoZSBkcml2
ZXIgc3RheXMgb2ZmOyBub3RoaW5nIGJyZWFrcy4iKQpmaQoKIyAtLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLSBkcml2ZXJz
CkRJU0tTPSQoZyBkaXNrX2NvdW50KSBCSUc9MApmb3IgKChpID0gMTsg
aSA8PSAke0RJU0tTOi0wfTsgaSsrKSk7IGRvCiAgSUZTPyByZWFkIC1y
IGRuIGRrIGRnIDw8PCAiJChnICJkaXNrXyRpIikiCiAgY2FzZSAiJGRr
IiBpbiBudm1lKSBrdD0iTlZNZSBTU0QiIDs7IHNzZCkga3Q9IlNTRCIg
OzsgaGRkKSBrdD0iaGFyZCBkaXNrIChzbG93ZXIgdGhhbiBhbiBTU0Qp
IiA7OyBlbW1jKSBrdD0iZU1NQyAoc2xvdykiIDs7ICopIGt0PSRkayA7
OyBlc2FjCiAgWyAiJHtEZzotMH0iIC1nZSAxNiBdICYmIEJJRz0kKChC
SUcgKyAxKSkKICBfYWRkIG9rICJEcml2ZTogJGRuLCAkZGcgR0IgJGt0
Igpkb25lCmlmIFsgJEFTQUhJID0gMCBdICYmIFsgJEJJRyAtZXEgMCBd
OyB0aGVuIF9hZGQgbm8gIk5vIGludGVybmFsIGRyaXZlIG9mIDE2IEdC
IG9yIG1vcmU6IHRoZXJlIGlzIG5vd2hlcmUgdG8gaW5zdGFsbC4iOyBE
SVNUUk89dW5zdXBwb3J0ZWQ7IFJFQVNPTj0ibm8gaW50ZXJuYWwgZHJp
dmUgb2YgMTYgR0Igb3IgbW9yZSI7IGZpClsgIiR7RElTS1M6LTB9
IiAtZ3QgMSBdICYmIF9hZGQgaW5mbyAiU2V2ZXJhbCBkcml2ZXM6IHRo
ZSBpbnN0YWxsZXIgYXNrcyB3aGljaCBPTkUgdG8gZXJhc2U7IHRoZSBv
dGhlcnMgYXJlIG5vdCB0b3VjaGVkLiIKCiMgLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLSBwb3dlcgppZiBbICIk
KGcgYmF0dGVyeSkiID0geWVzIF07IHRoZW4KICBpZiBbICIkU0IiID0g
b24gXTsgdGhlbgogICAgX2FkZCBpbmZvICJCYXR0ZXJ5OiBzbGVlcCAo
bGlkIGNsb3NlKSB3b3Jrcy4gSGliZXJuYXRlIGlzIG9wdGlvbmFsIGFu
ZCBuZWVkcyBTZWN1cmUgQm9vdCBvZmYiIFwKICAgICAgIihTZWN1cmUg
Qm9vdCBibG9ja3MgaXQpOyB0aGUgd2VsY29tZSBzY3JlZW4gZXhw
bGFpbnMgdGhlIGNob2ljZS4iCiAgZWxzZQogICAgX2FkZCBpbmZvICJC
YXR0ZXJ5OiBzbGVlcCAobGlkIGNsb3NlKSB3b3JrczsgaGliZXJu
YXRlIGNhbiBiZSBzd2l0Y2hlZCBvbiBmcm9tIHRoZSB3ZWxjb21lIHNj
cmVlbi4iCiAgZmkKZmkKCiMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t
LS0tLS0tLS0tLS0tLS0tLS0tIHZlcmRpY3QKaWYgWyAkQkxPQ0tF
UlMgLWd0IDAgXTsgdGhlbiBWRVJESUNUPXVuc3VwcG9ydGVkOyBWVEVY
VD0iTk9UIFNVUFBPUlRFRCBCWSBUSElTIFVTQiI7IFNUQVRVUz1VTlNV
UFBPUlRFRAplbGlmIFsgJE5PVEVTIC1ndCAwIF07IHRoZW4gVkVSRElD
VD1ub3RlczsgVlRFWFQ9IldPUktTIFdJVEggTk9URVMiOyBTVEFUVVM9
Tk9URVMKZWxzZSBWRVJESUNUPWdvb2Q7IFZURVhUPSJHT09EIjsgU1RB
VFVTPU9LOyBmaQpbIC1uICIkV0hZIiBdIHx8IFdIWT0iJFJBTV9HQiBH
QiBtZW1vcnkiCgpOQU1FPSIkKGcgZG1pX3ZlbmRvcikgJFBST0RVQ1Qi
CmlmIFsgLW4gIiRGQU1JTFkiIF0gJiYgWyAiJEZBTUlMWSIgIT0gIiRQ
Uk9EVUNUIiBdOyB0aGVuCiAgY2FzZSAiJEZBTUlMWSIgaW4gKiJUbyBi
ZSBmaWxsZWQiKnwqIkRlZmF1bHQgc3RyaW5nIip8Kl8qKSA7OyAqKSBO
QU1FPSIkTkFNRSAoJEZBTUlMWSkiIDs7IGVzYWMKZmkKWyAkQVNBSEkg
PSAxIF0gJiYgTkFNRT0kKGcgbWFjX21vZGVsKQoKY2FzZSAiJERJU1RS
TyIgaW4KICBmZWRvcmF8ZmVkb3JhLW1pbikgUEFSQT0iIiA7OwogIGZl
ZG9yYS10MikgUEFSQT0iVGhpcyBNYWMgZ2V0cyBGZWRvcmEgcGx1cyB0
aGUgY29tbXVuaXR5IHQybGludXgga2VybmVsIChhZGRlZCBhdXRvbWF0
aWNhbGx5IGR1cmluZyBzZXR1cCksIHNvIGl0cyBidWlsdC1pbiBrZXli
b2FyZCwgdHJhY2twYWQsIFRvdWNoIEJhciwgc291bmQgYW5kICh3aXRo
IHRoZSBmaXJtd2FyZSBzYXZlZCBmcm9tIG1hY09TKSBXaS1GaSB3b3Jr
LiBUaGUgYXBwcyBhbmQgc2V0dGluZ3MgYXJlIHRoZSBzYW1lIGFzIG9u
IGFueSBvdGhlciBjb21wdXRlci4iIDs7CiAgYXNhaGkpICAgICBQQVJB
PSJBcHBsZSBTaWxpY29uIE1hY3MgZ2V0IEZlZG9yYSBBc2FoaSBSZW1p
eCwgdGhlIG9mZmljaWFsIEZlZG9yYSBidWlsZCBmb3IgdGhlc2UgTWFj
cy4gSXQgaXMgaW5zdGFsbGVkIGZyb20gbWFjT1MgbmV4dCB0byBpdCAo
bm8gVVNCIHN0aWNrKSwgYW5kIHRoZW4gdGhpcyBwYWNrYWdlJ3Mgc2V0
dXAuc2ggZ2l2ZXMgaXQgdGhlIHNhbWUgYXBwcyBhbmQgc2V0dGluZ3Ms
IGV4Y2VwdCBhIGZldyB0aGF0IG9ubHkgZXhpc3QgZm9yIEludGVsL0FN
RCBQQ3MgKHNlZSBsaW51eC1zZXR1cC9hc2FoaS9SRUFETUUubWQpLiIg
OzsKICBkZWJpYW4tbGl0ZSkgUEFSQT0iVGhpcyBjb21wdXRlciBoYXMg
dG9vIGxpdHRsZSBtZW1vcnkgZm9yIEZlZG9yYS4gUmVzdGFydCwgYW5k
IGluIHRoZSBVU0IgbWVudSBjaG9vc2UgdGhlIERlYmlhbiBlbnRyeSBm
b3Igb2xkZXIgUENzOiBpdCBpbnN0YWxscyBEZWJpYW4gMTMgd2l0aCBh
IGxpZ2h0IGRlc2t0b3AgYW5kIHRoZSBzYW1lIHNlY3VyaXR5IHNldHRp
bmdzLCB3aXRoIGZld2VyIGFwcHMuIiA7OwogIGRlYmlhbi1pMzg2KSBQ
QVJBPSJUaGlzIGNvbXB1dGVyJ3MgcHJvY2Vzc29yIGlzIDMyLWJpdCBv
bmx5LCBhbmQgRmVkb3JhIGlzIDY0LWJpdCBvbmx5LiBSZXN0YXJ0LCBh
bmQgaW4gdGhlIFVTQiBtZW51IGNob29zZSB0aGUgRGViaWFuICgzMi1i
aXQpIGVudHJ5OiBpdCBpbnN0YWxscyBEZWJpYW4gMTIgZm9yIDMyLWJp
dCBQQ3MgKHNlY3VyaXR5IHVwZGF0ZXMgdW50aWwgSnVuZSAyMDI4KSB3
aXRoIGEgbGlnaHQgZGVza3RvcCBhbmQgdGhlIHNhbWUgc2VjdXJpdHkg
c2V0dGluZ3MsIHdpdGggZmV3ZXIgYXBwcy4iIDs7CiAgdW5zdXBwb3J0
ZWQpIFBBUkE9IlNvcnJ5OiB0aGlzIGNvbXB1dGVyIGlzIGJlbG93IHdo
YXQgY3VycmVudCBMaW51eCBkaXN0cmlidXRpb25zIHN1cHBvcnQgKCRS
RUFTT04pLiIgOzsKZXNhYwoKZWNobyAiICBDb21wYXRpYmlsaXR5IGNo
ZWNrOiAke05BTUUjIH0iCmVjaG8KcHJpbnRmICclc1xuJyAiJHtMSU5F
U1tAXX0iCmVjaG8KZWNobyAiICBWZXJkaWN0OiAkVlRFWFQiCmlmIFsg
IiRESVNUUk8iID0gZmVkb3JhLW1pbiBdOyB0aGVuIGVjaG8gIiAgUmVj
b21tZW5kZWQgc2V0dXA6IE1JTiAoTFhRdCwgZXNzZW50aWFsIGFwcHMp
ICBbJFdIWV0iCmVsaWYgWyAiJERJU1RSTyIgPSBmZWRvcmEgXSB8fCBb
ICIkRElTVFJPIiA9IGZlZG9yYS10MiBdIHx8IFsgIiRESVNUUk8iID0g
YXNhaGkgXTsgdGhlbgogIGlmIFsgIiRQUk9GSUxFIiA9IGZ1bGwgXTsg
dGhlbiBlY2hvICIgIFJlY29tbWVuZGVkIHNldHVwOiBGVUxMIChLREUg
UGxhc21hLCBldmVyeSBhcHApICBbJFdIWV0iCiAgZWxzZSBlY2hvICIg
IFJlY29tbWVuZGVkIHNldHVwOiBMSVRFIChYZmNlLCBlc3NlbnRpYWwg
YXBwcykgIFskV0hZXSI7IGZpCmZpCmlmIFsgLW4gIiRQQVJBIiBdOyB0
aGVuCiAgZWNobwogIHByaW50ZiAnJXNcbicgIiRQQVJBIiB8IGZvbGQg
LXMgLXcgNzYgfCBzZWQgJ3MvXi8gIC87IHMvICokLy8nCmZpCgppZiBb
ICRJTlNUQUxMRVIgPSAxIF07IHRoZW4KICBlY2hvICJIV19TVEFUVVM9
JFNUQVRVUyIKICBlY2hvICJIV19QUk9GSUxFPSRQUk9GSUxFIgogIGVj
aG8gIkhXX1RFWFRfSU5TVEFMTD0kVEVYVCIKICBlY2hvICJIV19ESVNU
Uk89JERJU1RSTyIKICBlY2hvICJIV19ESVNUUk9fUkVBU09OPSRSRUFT
T04iCmZpCgppZiBbIC1uICIkRVhQT1JUIiBdOyB0aGVuCiAgcSgpIHsg
cHJpbnRmICIlcz0lcVxuIiAiJDEiICIkMiI7IH0KICB7CiAgICBxIEhX
X1ZFUkRJQ1QgIiRWRVJESUNUIgogICAgcSBIV19TVEFUVVMgIiRTVEFU
VVMiCiAgICBxIEhXX1ZFUkRJQ1RfVEVYVCAiJGZURVhUIgogICAgcSBI
V19QUk9GSUxFX1NVR0dFU1QgIiRQUk9GSUxFIgogICAgcSBIV19QUk9G
SUxFX1dIWSAiJFdIWSIKICAgIHEgSFdfVEVYVF9JTlNUQUxMICIkVEVY
VCIKICAgIHEgSFdfRElTVFJPIciAkRElTVFJPIgogICAgcSBIV19ESVNU
Uk9fUkVBU09OICIkUkVBU09OIgogICAgcSBIV19CTE9DS0VSUyAiJEJM
T0NLRVJTIgogICAgcSBIV19CTE9DS0VSX1RFWFQgIiRCTE9DS0VSX1RF
WFQiCiAgICBxIEhXX05PVEVTICIkTk9URVMiCiAgICBxIEhXX0FTS19D
T05USU5VRSAiJEFTSyIKICAgIHEgSFdfTkVFRFNfV0lSRUQgIiRXSVJF
RCIKICAgIHEgSFdfQVNBSEkgIiRBU0FISSIKICAgIHEgSFdfVDIgIiQo
IFsgIiRNQUNLIiA9IGludGVsLXQyIF0gJiYgZWNobyAxIHx8IGVjaG8g
MCkiCiAgICBxIEhXX1NFQ1VSRV9CT09UICIkU0IiCiAgICBxIEhXX05F
RURTX01PSyAiJCggWyAkTkVFRFNfS0VZID0gMSBdICYmIFsgIiRTQiIg
PSBvbiBdICYmIGVjaG8gMSB8fCBlY2hvIDApIgogICAgcSBIV19OVklE
SUEgIiROViIKICAgIHEgSFdfRklSTVdBUkUgIiQoZyBmaXJtd2FyZSki
CiAgICBxIEhXX1JBTV9NQiAiJFJBTSIKICB9ID4gIiRFWFBPUlQiCmZp
CgpbICRJTlNUQUxMRVIgPSAxIF0gJiYgZXhpdCAwCmNhc2UgJFZFUkRJ
Q1QgaW4gZ29vZCkgZXhpdCAwIDs7IG5vdGVzKSBleGl0IDEgOzsgKikg
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
hw_check
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
if eth_up; then WIFI_STEP=0; else WIFI_STEP=1; fi
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
  while true; do
    answer "Add it? Type Y for yes or N for no:"
    case "$REPLY_TEXT" in
      [Yy]) echo "ai_abliterated=yes" >> /tmp/secure-linux-choices; break ;;
      [Nn]) echo "ai_abliterated=no" >> /tmp/secure-linux-choices; break ;;
    esac
  done
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
  while true; do
    answer "Type 1 or 2:"
    case "$REPLY_TEXT" in 1) SB_WANT=on; break ;; 2) SB_WANT=off; break ;; esac
  done
  echo "secureboot_intent=$SB_WANT" >> /tmp/secure-linux-choices
  if [ "$SB_WANT" = off ] && [ "$SB_NOW" = ON ]; then
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
  # awk, not grep -i -F: the lookup must work the same in every installer environment (some greps break on -i under LC_ALL=C)
  FOUND=$(ID=$id awk 'BEGIN { id = tolower(ENVIRON["ID"]) "|" } index(tolower($0), id) { last = $0 } END { if (last != "") print last }' /tmp/backups.txt)
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
  echo
  answer "Type C and press Enter to continue:"
elif [ "$PARTS" -eq 0 ]; then
  echo "   This drive is empty (new or blank), so there is nothing to back up."
  echo
  answer "Type C and press Enter to continue:"
else
  echo "   !! NO BACKUP has been recorded for this computer. !!"
  echo
  echo "   Everything on its drive will be deleted. To back it up first:"
  echo "     - Windows PC: start Windows, double-click BUILD-USB.cmd on this USB stick"
  echo "       (linux-setup\\kit) and answer y to the backup question."
  echo "     - Any PC: restart, and choose Clonezilla from this USB stick's menu to"
  echo "       save a full image of the drive to another drive."
  echo
  while true; do
    answer "Type B to stop and back up first, or C to continue WITHOUT a backup:"
    case "$REPLY_TEXT" in [Bb]) cancel ;; [Cc]) break ;; esac
  done
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
    if true; then   # B2: the condition was removed, not the body; the wrapper keeps this block's indentation
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
        echo "   Trying to fix it: Wi-Fi is switched on and the network service restarts..."
        rfkill unblock all >/dev/null 2>&1
        nmcli radio wifi on >/dev/null 2>&1
        systemctl restart NetworkManager >/dev/null 2>&1
        sleep 4
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
      wifi_scan || NO_SCAN=1
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
    printf '%%packages\n@^kde-desktop-environment\nflatpak\ncurl\ngit\nbtrfs-progs\nNetworkManager-wifi\n%s\n%%end\n' "$(echo $FIRMWARE | tr ' ' '\n')" > /tmp/packages.ks
    ;;
  lite)
    printf 'url --mirrorlist="https://mirrors.fedoraproject.org/mirrorlist?repo=fedora-$releasever&arch=$basearch"\nrepo --name=updates --mirrorlist="https://mirrors.fedoraproject.org/mirrorlist?repo=updates-released-f$releasever&arch=$basearch"\n' > /tmp/payload.ks
    printf 'network --hostname=%s\nfirewall --enabled --service=ssh\nservices --enabled=sshd\n' "$HOST" > /tmp/profile.ks
    printf '%%packages\n@^xfce-desktop-environment\nopenssh-server\nflatpak\ncurl\ngit\nbtrfs-progs\nNetworkManager-wifi\n%s\n%%end\n' "$(echo $FIRMWARE | tr ' ' '\n')" > /tmp/packages.ks
    ;;
  min)
    # fedora-min: the same Fedora from the same mirrors, but the lightest desktop (LXQt) for PCs with
    # 2-3 GB of memory. Everything else matches lite; the installed system is managed as "lite" (below),
    # so only the desktop group differs.
    printf 'url --mirrorlist="https://mirrors.fedoraproject.org/mirrorlist?repo=fedora-$releasever&arch=$basearch"\nrepo --name=updates --mirrorlist="https://mirrors.fedoraproject.org/mirrorlist?repo=updates-released-f$releasever&arch=$basearch"\n' > /tmp/payload.ks
    printf 'network --hostname=%s\nfirewall --enabled --service=ssh\nservices --enabled=sshd\n' "$HOST" > /tmp/profile.ks
    printf '%%packages\n@^lxqt-desktop-environment\nopenssh-server\nflatpak\ncurl\ngit\nbtrfs-progs\nNetworkManager-wifi\n%s\n%%end\n' "$(echo $FIRMWARE | tr ' ' '\n')" > /tmp/packages.ks
    ;;
  atomic)
    # Fedora Kinoite (KDE Plasma, image-based). No package list: the image is the system.
    printf 'ostreecontainer --url=quay.io/fedora/fedora-kinoite:44 --no-signature-verification\n' > /tmp/payload.ks
    printf 'network --hostname=%s\nfirewall --enabled\n' "$HOST" > /tmp/profile.ks
    echo '# atomic: no package list (the Fedora Kinoite image is the system)' > /tmp/packages.ks
    ;;
esac
# The installed system's profile is full/lite/atomic: a MIN install is managed as lite (same essential
# apps, same light settings) - only the desktop group differs, and anaconda already installed that above.
if [ "$PROFILE" = min ]; then echo lite > /tmp/secure-linux-profile; else echo "$PROFILE" > /tmp/secure-linux-profile; fi
# Installer screen: text mode on 2-4 GB machines (the graphical installer needs more memory)
if [ "$HW_TEXT_INSTALL" = 1 ]; then sed -i '1i text' /tmp/profile.ks; else sed -i '1i graphical' /tmp/profile.ks; fi

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
# (netboot: no Wi-Fi is saved anywhere - the Wi-Fi question above connects this computer itself)
# Without saved Wi-Fi (or a Wi-Fi chip the installer can't drive, e.g. old Broadcom) a cable is needed
has_link() { local c; for c in /sys/class/net/*/carrier; do [ "$(cat "$c" 2>/dev/null)" = 1 ] && [ "$(basename "$(dirname "$c")")" != lo ] && return 0; done; return 1; }
if [ ! -s /tmp/net.ks ] && ! has_link; then
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

# Optional unfiltered AI model: copy it from the USB stick if it is there; otherwise first boot downloads it.
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

# Offline fix-packs from the USB stick (best-effort, silent if the stick or the files are not there): the ClamAV
# virus list. Staged at /var/lib/secure-linux/offline/clamav, and copied into /var/lib/clamav when no database was
# ever downloaded, so a fresh install can scan before (or without ever) downloading one. The files stay root-owned
# here (the clamav user does not exist yet): the clamav package's own install fixes the folder's ownership, and
# freshclam replaces the files at its first online update.
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
umount "$OFF_MNT" 2>/dev/null
%end

%post --log=/root/ks-post.log
# Runs inside the new system.
systemctl set-default graphical.target
# Files written from outside this system (by the installer, above) get their proper SELinux labels
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
SL_PAYLOAD_SOURCE="https://codeload.github.com/MattyBoyMan/secure-linux-netboot/tar.gz/refs/heads/main"
SL=/usr/local/lib/secure-linux
SLREPO=/tmp/sl-repo
SLPAYLOAD="$SLREPO/secure-linux-netboot-main/payload"
rm -rf "$SL" "$SLREPO"
install -d -m 0755 "$SL" "$SLREPO"
if ! curl -fsSL --retry 3 -o /tmp/sl-repo.tar.gz "$SL_PAYLOAD_SOURCE"; then
  echo "ERROR: could not download the Secure Linux payload from $SL_PAYLOAD_SOURCE"
  touch /root/secure-linux-payload-missing
elif ! tar -xzf /tmp/sl-repo.tar.gz --no-same-owner -C "$SLREPO" || [ ! -f "$SLPAYLOAD/setup.sh" ] || [ ! -f "$SLPAYLOAD/build.conf" ]; then
  echo "ERROR: the downloaded repository has no usable payload/ source tree (setup.sh and build.conf are required)"
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

# ---- The beginner's guide (opened on first login, also in the app menu)
GUIDE_DIR=/usr/share/secure-linux
[ "$PROFILE" = atomic ] && GUIDE_DIR=/usr/local/share/secure-linux   # /usr is read-only on atomic
install -d -m 0755 "$GUIDE_DIR"
if [ -f /tmp/START-HERE.html ]; then
  mv /tmp/START-HERE.html "$GUIDE_DIR/START-HERE.html"
else
  echo "NOTE: the beginner's guide was not in the download; the computer still works, and the guide is online in the repository."
fi
chmod 0644 "$GUIDE_DIR/START-HERE.html"

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

# ---- First boot: wait for internet, run the full setup once (shutdown is blocked while it runs)
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
touch /var/lib/firstboot-setup.done
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

# ---- Helpers, welcome autostart, timers and menu entries in place before the first login
if [ -x "$SL/setup.sh" ]; then
  "$SL/setup.sh" --early || echo "setup.sh --early reported a problem (first boot repeats everything)"
fi
%end

%post --nochroot --log=/tmp/ks-post-scrub.log
# Belt and braces: make sure the encryption passphrase isn't left in any saved installer file
SYSROOT=${ANA_INSTALL_PATH:-/mnt/sysroot}
for f in "$SYSROOT"/root/*.cfg "$SYSROOT"/root/*.ks "$SYSROOT"/var/log/anaconda/*; do
  [ -f "$f" ] && sed -i -E 's/(--passphrase)(=| )("[^"]*"|[^ ]+)/\1=REMOVED/g' "$f"
done
rm -f /tmp/disk.ks
%end
