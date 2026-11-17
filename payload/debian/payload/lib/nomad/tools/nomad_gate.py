#!/usr/bin/env python3
"""nomad_gate.py - the login gate for NOMAD on a home network (standard library only).

NOMAD itself has no login.  With "start-nomad.sh --share home" other devices on the home network reach NOMAD
only through this gate:
  - the privacy firewall (nft table inet nomad_guard) sends their connections for NOMAD's web ports
    (8080, 8090, ...) to the gate's ports (the same number + 10000; home-network addresses only, never the internet);
  - the gate shows a page asking for the access code that start-nomad.sh shows on the NOMAD computer;
  - a device that typed the right code gets a random device key (a cookie, kept 180 days) and from then on its
    connections are passed through unchanged to NOMAD on this computer (127.0.0.1).  Because a cookie is shared by
    every port of the same address, one code entry opens NOMAD and all of its apps on that device.
Only the SHA-256 of each device key is kept (file share-devices, mode 600).  The code and the keys are never logged.
"start-nomad.sh --new-code" makes a new code and forgets every device.

Run by start-nomad.sh through nomad_mirror.py:   python3 -I nomad_mirror.py gate --state DIR --ports LIST
"""
import argparse, hashlib, hmac, html, os, secrets, selectors, socket, sys, threading, time, urllib.parse

COOKIE = "nomad_gate"
LOGIN_PATH = "/nomad-gate-login"
MAX_HEAD = 65536
MAX_FORM = 4096
DEVICE_DAYS = 180
FAIL_LIMIT = 5          # wrong codes from one address before it has to wait
FAIL_WAIT = 60          # seconds that address waits
FAIL_GAP = 1.0          # seconds between any two wrong codes (all addresses together)
CODE_DIGITS = 8
DRAIN_MAX = 1 << 20     # after the gate's own answer: read at most this much of what the device still sends
DRAIN_SECONDS = 3       # ... for at most this long, then close

PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>NOMAD - type the access code</title>
<style>body{{font-family:sans-serif;max-width:32em;margin:3em auto;padding:0 1em;line-height:1.5}}
input{{font-size:1.4em;width:9em;letter-spacing:.1em}}button{{font-size:1.1em;padding:.4em 1em}}
.msg{{color:#9b1c1c;font-weight:bold}}</style></head><body>
<h1>NOMAD</h1>
<p>This NOMAD runs on a computer in your home. To open it on this device, type the <b>access code</b>
shown on that computer (in the window where NOMAD was started).</p>
<p>You only need to do this once on each device.</p>
{message}
<form method="post" action="{action}">
<input type="hidden" name="next" value="{next}">
<label>Access code<br><input name="code" inputmode="numeric" autocomplete="one-time-code" autofocus></label>
<p><button type="submit">Open NOMAD</button></p>
</form>
<p>No code? On the NOMAD computer type: <code>sudo secure-linux-nomad code</code></p>
</body></html>
"""


def parse_ports(text, offset):
    """'8080,8090,8400-8402' -> [(18080, 8080), (18090, 8090), (18400, 8400), ...]"""
    pairs = []
    for part in text.replace(" ", "").split(","):
        if not part:
            continue
        lo, _, hi = part.partition("-")
        a, b = int(lo), int(hi or lo)
        if not (1 <= a <= b <= 65535) or b + offset > 65535:
            raise ValueError("bad port range: " + part)
        pairs.extend((p + offset, p) for p in range(a, b + 1))
    return pairs


def safe_next(value):
    """Only a path on the same site may be the page shown after the code (no other site, no scheme)."""
    if not value or not value.startswith("/") or value.startswith("//") or "\\" in value or "\r" in value \
            or "\n" in value:
        return "/"
    return value


class Gate:
    def __init__(self, state_dir, upstream="127.0.0.1"):
        self.code_file = os.path.join(state_dir, "share-code")
        self.devices_file = os.path.join(state_dir, "share-devices")
        self.upstream = upstream
        self.lock = threading.Lock()
        self.fails = {}           # address -> (count, wait-until)
        self.last_fail = 0.0
        self.listeners = []       # (socket, target port)
        self.sel = selectors.DefaultSelector()
        self.stopping = False

    # ---------------------------------------------------------------- code and device keys
    def code(self):
        try:
            with open(self.code_file, encoding="ascii") as f:
                digits = "".join(c for c in f.read() if c.isdigit())
        except (OSError, UnicodeDecodeError):
            return None
        return digits if len(digits) >= CODE_DIGITS else None

    def known_device(self, key):
        if not key:
            return False
        want = hashlib.sha256(key.encode("utf-8", "replace")).hexdigest()
        oldest = time.time() - DEVICE_DAYS * 86400
        try:
            with open(self.devices_file, encoding="ascii") as f:
                lines = f.read().splitlines()
        except (OSError, UnicodeDecodeError):
            return False
        found = False
        for line in lines:
            digest, _, when = line.partition("\t")
            try:
                fresh = float(when) >= oldest
            except ValueError:
                fresh = False
            if fresh and hmac.compare_digest(digest, want):
                found = True
        return found

    def new_device(self):
        key = secrets.token_urlsafe(32)
        line = "%s\t%d\n" % (hashlib.sha256(key.encode("utf-8")).hexdigest(), int(time.time()))
        with self.lock:
            fd = os.open(self.devices_file, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            try:
                os.write(fd, line.encode("ascii"))
            finally:
                os.close(fd)
        return key

    def try_code(self, address, typed):
        """'ok', 'wrong' or 'wait'.  Wrong codes are slowed down so guessing 8 digits is hopeless."""
        now = time.time()
        with self.lock:
            count, until = self.fails.get(address, (0, 0.0))
            if until > now or now - self.last_fail < FAIL_GAP:
                return "wait"
            code = self.code()
            digits = "".join(c for c in (typed or "") if c.isdigit())
            if code is not None and hmac.compare_digest(digits.encode(), code.encode()):
                self.fails.pop(address, None)
                return "ok"
            self.last_fail = now
            count += 1
            self.fails[address] = (0, now + FAIL_WAIT) if count >= FAIL_LIMIT else (count, 0.0)
            return "wrong"

    # ---------------------------------------------------------------- HTTP answers made by the gate itself
    @staticmethod
    def send(conn, status, body, extra=()):
        head = ["HTTP/1.1 " + status, "Content-Type: text/html; charset=utf-8", "Content-Length: %d" % len(body),
                "Cache-Control: no-store", "X-Frame-Options: DENY", "Referrer-Policy: no-referrer",
                "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; form-action 'self'",
                "Connection: close"]
        head.extend(extra)
        conn.sendall(("\r\n".join(head) + "\r\n\r\n").encode("latin-1") + body)

    def page(self, conn, status, target, message=""):
        body = PAGE.format(action=LOGIN_PATH, next=html.escape(safe_next(target), quote=True),
                           message='<p class="msg">%s</p>' % html.escape(message) if message else "")
        self.send(conn, status, body.encode("utf-8"))

    # ---------------------------------------------------------------- one connection
    def handle(self, conn, address, target_port):
        try:
            conn.settimeout(30)
            buf = b""
            while b"\r\n\r\n" not in buf:
                chunk = conn.recv(8192)
                if not chunk:
                    return
                buf += chunk
                if len(buf) > MAX_HEAD:
                    self.send(conn, "431 Request Header Fields Too Large", b"Too large.")
                    return
            head, _, rest = buf.partition(b"\r\n\r\n")
            lines = head.decode("latin-1").split("\r\n")
            parts = lines[0].split(" ")
            if len(parts) != 3 or not parts[2].startswith("HTTP/"):
                self.send(conn, "400 Bad Request", b"Bad request.")
                return
            method, target = parts[0].upper(), parts[1]
            headers = {}
            for line in lines[1:]:
                name, _, value = line.partition(":")
                headers.setdefault(name.strip().lower(), []).append(value.strip())
            key = ""
            for cookie_line in headers.get("cookie", []):
                for item in cookie_line.split(";"):
                    name, _, value = item.strip().partition("=")
                    if name == COOKIE:
                        key = value
            if target.split("?", 1)[0] == LOGIN_PATH and method == "POST":
                return self.login(conn, address, headers, rest)
            if self.known_device(key):
                return self.relay(conn, buf, target_port)
            if method in ("GET", "HEAD"):
                self.page(conn, "401 Unauthorized", target)
            else:
                self.send(conn, "401 Unauthorized", b"Type the access code first.")
        except (OSError, ValueError):
            pass
        finally:
            self.close_gently(conn)

    @staticmethod
    def close_gently(conn):
        """Close after the device has read the gate's answer. Closing while the rest of its request (a form body
        sent a moment later) is still unread makes the computer reset the connection, and the device then shows a
        connection error instead of the gate's page. So: say "no more from me", read and drop what is still on its
        way (limited in size and time), then close."""
        try:
            conn.shutdown(socket.SHUT_WR)
            conn.settimeout(DRAIN_SECONDS)
            end, got = time.monotonic() + DRAIN_SECONDS, 0
            while got < DRAIN_MAX and time.monotonic() < end:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                got += len(chunk)
        except OSError:
            pass
        try:
            conn.close()
        except OSError:
            pass

    def login(self, conn, address, headers, rest):
        try:
            length = int((headers.get("content-length") or ["0"])[-1])
        except ValueError:
            length = -1
        if length < 0 or length > MAX_FORM:
            self.send(conn, "413 Payload Too Large", b"Too large.")
            return
        body = rest
        while len(body) < length:
            chunk = conn.recv(length - len(body))
            if not chunk:
                break
            body += chunk
        form = urllib.parse.parse_qs(body[:length].decode("utf-8", "replace"))
        target = safe_next((form.get("next") or ["/"])[0])
        result = self.try_code(address, (form.get("code") or [""])[0])
        if result == "ok":
            key = self.new_device()
            sys.stderr.write("gate: a device was approved (%s)\n" % address)
            self.send(conn, "303 See Other", b"", ["Location: " + target,
                      "Set-Cookie: %s=%s; Max-Age=%d; Path=/; HttpOnly; SameSite=Lax" % (COOKIE, key, DEVICE_DAYS * 86400)])
        elif result == "wait":
            self.page(conn, "429 Too Many Requests", target, "Too many wrong codes. Wait one minute and try again.")
        else:
            self.page(conn, "401 Unauthorized", target,
                      "That code is not right. Check the code on the NOMAD computer and try again.")

    def relay(self, conn, first, target_port):
        try:
            up = socket.create_connection((self.upstream, target_port), timeout=10)
        except OSError:
            self.send(conn, "502 Bad Gateway", "NOMAD is still starting. Try again in a minute.".encode())
            return
        conn.settimeout(None)
        up.settimeout(None)

        def pump(src, dst):
            try:
                while True:
                    data = src.recv(65536)
                    if not data:
                        break
                    dst.sendall(data)
            except OSError:
                pass
            for s, how in ((dst, socket.SHUT_WR), (src, socket.SHUT_RD)):
                try:
                    s.shutdown(how)
                except OSError:
                    pass

        try:
            up.sendall(first)
            back = threading.Thread(target=pump, args=(up, conn), daemon=True)
            back.start()
            pump(conn, up)
            back.join()
        finally:
            up.close()

    # ---------------------------------------------------------------- listening
    def listen(self, pairs, bind=None):
        """pairs: [(listen port, NOMAD port)].  Returns the real listen ports (0 picks a free one)."""
        ports = []
        for listen_port, target_port in pairs:
            s = None
            if bind is None:
                try:
                    s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
                    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
                    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    s.bind(("::", listen_port))
                except OSError:
                    if s is not None:
                        s.close()
                    s = None
            if s is None:
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                s.bind((bind or "0.0.0.0", listen_port))
            s.listen(64)
            s.setblocking(False)
            self.sel.register(s, selectors.EVENT_READ, target_port)
            self.listeners.append((s, target_port))
            ports.append(s.getsockname()[1])
        return ports

    def serve_forever(self):
        while not self.stopping:
            try:
                ready = self.sel.select(timeout=0.5)
            except OSError:
                if self.stopping:      # shutdown() closed the listeners while this was waiting
                    break
                raise
            for skey, _ in ready:
                try:
                    conn, addr = skey.fileobj.accept()
                except OSError:
                    continue
                conn.setblocking(True)
                threading.Thread(target=self.handle, args=(conn, addr[0], skey.data), daemon=True).start()

    def shutdown(self):
        self.stopping = True
        for s, _ in self.listeners:
            try:
                self.sel.unregister(s)
            except (KeyError, ValueError):
                pass
            s.close()


def main(argv=None):
    ap = argparse.ArgumentParser(prog="nomad_mirror.py gate", description="NOMAD's home-network login gate")
    ap.add_argument("--state", required=True, help="folder that holds share-code and share-devices")
    ap.add_argument("--ports", required=True, help="NOMAD's web ports, e.g. 8080,8090,8400-8599")
    ap.add_argument("--offset", type=int, default=10000, help="the gate listens on each port + this number")
    ap.add_argument("--bind", default=None, help="address to listen on (default: every address, IPv6 and IPv4)")
    ap.add_argument("--upstream", default="127.0.0.1")
    a = ap.parse_args(argv)
    gate = Gate(a.state, a.upstream)
    if gate.code() is None:
        sys.stderr.write("gate: no access code in %s; not starting\n" % gate.code_file)
        return 2
    try:
        ports = gate.listen(parse_ports(a.ports, a.offset), a.bind)
    except (OSError, ValueError) as e:
        sys.stderr.write("gate: could not listen: %s\n" % e)
        return 3
    sys.stderr.write("gate: listening on %d port(s), %d-%d\n" % (len(ports), min(ports), max(ports)))
    try:
        gate.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
