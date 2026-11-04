# fleet-pair.sh: shared pairing helpers for the home fleet (POSIX sh: keep dash-clean).
# Used by secure-linux-fleet (the "pair" command on the main computer), secure-linux-fleet-join
# (Fedora) and debian/setup/bin/secure-linux-fleet-join. Source it; don't run it.
# The Debian tree carries an identical copy at debian/setup/lib/fleet-pair.sh (tests check they match).
#
# Pairing in plain terms: the main computer shows an address and six everyday words. The joining PC
# downloads the main computer's public key over the home network (or reads it from a USB stick), works
# out the same six words from the key, and the person confirms the words match before anything is
# trusted. A key that doesn't match is never installed.

# 64 everyday words (index 0-63). Six words = six bytes of the key's SHA-256, each byte mapped here.
FP_WORDS="baker beach berry bike bird boat boots bread brick bridge brush bunny butter cabin candle \
carrot chair cheese cherry clock cloud clover coffee comet cookie copper cricket daisy dancer desert \
dinner dolphin donut dragon ember fence fiddle forest garden ginger gold guitar harbour honey koala \
lemon magnet marble meadow muffin orange paddle paper pepper picnic pocket potato rabbit rainbow \
river rocket sailor shadow silver spider sunset teapot tiger turtle waffle window winter wombat"

# fp_word_for_byte N   print word number N (0-63) from the list
fp_word_for_byte() {
  local n=$1
  printf '%s' "$FP_WORDS" | awk -v n="$n" '{print $(n+1)}'
}

# fp_words_for_pubkey FILE   print the six pairing words for a public key file (empty on failure)
fp_words_for_pubkey() {
  local hex i byte out=""
  hex=$(sha256sum "$1" 2>/dev/null | cut -c1-12) || return 1
  [ ${#hex} -eq 12 ] || return 1
  out=""
  i=1
  while [ $i -le 12 ]; do
    byte=$(printf '%d' "0x$(printf '%s' "$hex" | cut -c$i-$((i+1)))")
    out="$out $(fp_word_for_byte $((byte % 64)))"
    i=$((i+2))
  done
  printf '%s' "${out# }"
}

# fp_valid_pubkey FILE   true if FILE is exactly one ssh-ed25519 public key line
fp_valid_pubkey() {
  [ -f "$1" ] || return 1
  [ "$(wc -l < "$1" | tr -d ' ')" -le 1 ] || return 1
  grep -qE '^ssh-ed25519 [A-Za-z0-9+/=]{60,90}( [^ ].*)?$' "$1" || return 1
}

# fp_fingerprint FILE   human-checkable fingerprint of a public key (ssh-keygen if present, else sha256)
fp_fingerprint() {
  if command -v ssh-keygen >/dev/null 2>&1 && ssh-keygen -lf "$1" >/dev/null 2>&1; then
    ssh-keygen -lf "$1" | awk '{print $2}'
  else
    sha256sum "$1" | cut -c1-32
  fi
}

# fp_is_lan_addr HOST   true if HOST is a private/home-network address (or a .local name)
fp_is_lan_addr() {
  case $1 in
    *.local|localhost|127.*) return 0 ;;
    10.*|192.168.*|169.254.*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
    fc*|fd*|fe80:*) return 0 ;;
    *) return 1 ;;
  esac
}

# fp_pick_port   print a likely-free high port (no python needed)
fp_pick_port() {
  if command -v shuf >/dev/null 2>&1; then shuf -i 20000-59000 -n 1
  else awk 'BEGIN{srand(); print 20000+int(rand()*39000)}'; fi
}

# fp_tcp_open HOST PORT [SECONDS]   true if a TCP connection succeeds (uses python3, present everywhere here)
fp_tcp_open() {
  python3 - "$1" "$2" "${3:-3}" <<'PY' >/dev/null 2>&1
import socket, sys
s = socket.socket()
s.settimeout(float(sys.argv[3]))
try:
    s.connect((sys.argv[1], int(sys.argv[2])))
    s.close()
except OSError:
    sys.exit(1)
PY
}

# fp_fetch URL   download URL to stdout (short timeouts: this is the home network, answers come fast)
fp_fetch() {
  curl -fsS --max-time 15 "$1" 2>/dev/null
}

# fp_serve_once DIR PORT SECONDS   serve DIR over HTTP on the home network; stop as soon as
# id_ed25519.pub has been fetched once (or after SECONDS). Needs python3.
fp_serve_once() {
  local dir=$1 port=$2 secs=${3:-300} script
  script=$(mktemp) || return 1
  cat > "$script" <<'PY'
import http.server, socketserver, sys, time
d, port, secs = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=d, **k)
    def do_GET(self):
        super().do_GET()
        if self.path.rstrip("/").endswith("id_ed25519.pub"):
            self.server.got_key = True
    def log_message(self, *a):
        pass
srv = socketserver.TCPServer(("", port), H)
srv.got_key = False
srv.timeout = 2
end = time.time() + secs
while not srv.got_key and time.time() < end:
    srv.handle_request()
srv.server_close()
PY
  python3 "$script" "$dir" "$port" "$secs"
  local rc=$?
  rm -f "$script"
  return $rc
}
