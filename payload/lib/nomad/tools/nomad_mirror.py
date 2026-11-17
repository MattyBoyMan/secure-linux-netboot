#!/usr/bin/env python3
"""nomad_mirror.py - tiny READ-ONLY container registry that serves the image archives on the drive.

Why: Project NOMAD's Command Center installs its apps itself and asks the container engine to
"pull" them.  With no internet that pull fails, unless the engine finds the image in a mirror.
start-nomad.sh points its private Podman service at this mirror (127.0.0.1 only), so app installs
work offline.  Images not on the drive get a 404 here and Podman falls back to the real registry
when the computer is online.

With the first argument "gate" it runs NOMAD's home-network login gate instead (nomad_gate.py, next to this
file; see there).  One program for both keeps stop-nomad.sh's "only our own processes" check simple.

Serves, from images/fetch-log.jsonl + the docker-archive .tar files:
  GET/HEAD /v2/                                   -> 200
  GET/HEAD /v2/<dockerio|ghcr>/<repo>/manifests/<tag or digest>
  GET/HEAD /v2/<dockerio|ghcr>/<repo>/blobs/<digest>   (config json or uncompressed layer tar)
The image config is the original one, so the image ID equals the pinned config digest.
Standard library only.  Listens on 127.0.0.1 only.
"""
import hashlib, http.server, json, os, socketserver, sys, tarfile

MT_MAN = "application/vnd.oci.image.manifest.v1+json"
MT_CFG = "application/vnd.oci.image.config.v1+json"
MT_LAYER = "application/vnd.oci.image.layer.v1.tar"
PREFIX = {"registry-1.docker.io": "dockerio", "docker.io": "dockerio", "ghcr.io": "ghcr"}


def load_entries(images_dir):
    last = {}
    with open(os.path.join(images_dir, "fetch-log.jsonl"), encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            e = json.loads(line)
            if e.get("kind") == "image":
                last[e["ref"]] = e
    return list(last.values())


class Store:
    def __init__(self, images_dir):
        self.manifests = {}  # (prefix, repo, ref) -> (bytes, digest)
        self.blobs = {}      # digest -> (tarpath, offset, size)
        for e in load_entries(images_dir):
            tp = os.path.join(images_dir, e["file"])
            if not os.path.exists(tp):
                continue
            members = {}
            with tarfile.open(tp, "r:") as t:
                for m in t.getmembers():
                    if m.isfile():
                        members[m.name] = (m.offset_data, m.size)
            cfg_hex = e["config_digest"].split(":")[1]
            off, size = members[cfg_hex + ".json"]
            self.blobs[e["config_digest"]] = (tp, off, size)
            layers = []
            for did in e["diff_ids"]:
                lo, ls = members[did.split(":")[1] + "/layer.tar"]
                self.blobs[did] = (tp, lo, ls)
                layers.append({"mediaType": MT_LAYER, "digest": did, "size": ls})
            man = json.dumps({"schemaVersion": 2, "mediaType": MT_MAN,
                              "config": {"mediaType": MT_CFG, "digest": e["config_digest"], "size": size},
                              "layers": layers}, separators=(",", ":")).encode()
            dg = "sha256:" + hashlib.sha256(man).hexdigest()
            pre = PREFIX.get(e["registry"], e["registry"])
            for ref in (e["tag"], dg):
                self.manifests[(pre, e["repo"], ref)] = (man, dg)


def make_handler(store):
    class H(http.server.BaseHTTPRequestHandler):
        server_version = "nomad-mirror/1.0"

        def log_message(self, fmt, *a):
            sys.stderr.write("mirror: " + (fmt % a) + "\n")

        def _send(self, code, body=b"", ctype="application/json", extra=None, head=False):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Docker-Distribution-API-Version", "registry/2.0")
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            if not head:
                self.wfile.write(body)

        def route(self, head):
            p = self.path.split("?", 1)[0]
            if p in ("/v2", "/v2/"):
                return self._send(200, b"{}", head=head)
            parts = p.split("/")
            # /v2/<prefix>/<repo...>/(manifests|blobs)/<ref>
            if len(parts) < 6 or parts[1] != "v2" or parts[-2] not in ("manifests", "blobs"):
                return self._send(404, b'{"errors":[{"code":"NAME_UNKNOWN"}]}', head=head)
            prefix, repo, kind, ref = parts[2], "/".join(parts[3:-2]), parts[-2], parts[-1]
            if prefix == "dockerio" and "/" not in repo:
                repo = "library/" + repo
            if kind == "manifests":
                hit = store.manifests.get((prefix, repo, ref))
                if not hit:
                    return self._send(404, b'{"errors":[{"code":"MANIFEST_UNKNOWN"}]}', head=head)
                man, dg = hit
                return self._send(200, man, MT_MAN, {"Docker-Content-Digest": dg}, head=head)
            hit = store.blobs.get(ref)
            if not hit:
                return self._send(404, b'{"errors":[{"code":"BLOB_UNKNOWN"}]}', head=head)
            tp, off, size = hit
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(size))
            self.send_header("Docker-Content-Digest", ref)
            self.end_headers()
            if head:
                return
            with open(tp, "rb") as f:
                f.seek(off)
                left = size
                while left:
                    b = f.read(min(left, 1 << 20))
                    if not b:
                        break
                    self.wfile.write(b)
                    left -= len(b)

        def do_GET(self):
            self.route(False)

        def do_HEAD(self):
            self.route(True)

    return H


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def run_gate(argv):
    # The gate is compiled from its own source text every time, never loaded from a __pycache__ .pyc: Python runs a
    # .pyc whose stored time and size match the source, and that file is not on the drive's fingerprint list. So any
    # compiled file there is refused (never read), named in a note, and nothing is written there either. (The drive
    # checks - verify_nomad_kit.py and the starters - refuse a __pycache__ folder on the drive as a whole.)
    import types
    sys.dont_write_bytecode = True
    here = os.path.dirname(os.path.abspath(__file__))
    cache = os.path.join(here, "__pycache__")
    if os.path.lexists(cache):
        sys.stderr.write("gate: note: %s holds compiled Python code that is not part of NOMAD; it is NOT used (the gate "
                         "always runs from its checked source). You can delete that folder.\n" % cache)
    path = os.path.join(here, "nomad_gate.py")
    with open(path, "rb") as f:
        code = compile(f.read(), path, "exec", dont_inherit=True)
    gate = types.ModuleType("nomad_gate")
    gate.__file__ = path
    sys.modules["nomad_gate"] = gate
    exec(code, gate.__dict__)
    return gate.main(argv)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "gate":
        sys.exit(run_gate(sys.argv[2:]))
    if len(sys.argv) < 2:
        sys.exit("usage: nomad_mirror.py IMAGES_DIR [PORT]")
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 5765
    store = Store(sys.argv[1])
    srv = Server(("127.0.0.1", port), make_handler(store))
    sys.stderr.write("mirror: serving %d image(s) on 127.0.0.1:%d\n" % (len(store.manifests) // 2, port))
    srv.serve_forever()


if __name__ == "__main__":
    main()
