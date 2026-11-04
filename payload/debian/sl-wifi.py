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
