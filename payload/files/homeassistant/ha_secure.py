#!/usr/bin/env python3
# Secure Linux - Home Assistant security checker.  Python 3 standard library + PyYAML only.
# Owned by: homeassistant (Job L).  Run through the wrapper:  secure-linux-ha-secure --check ...
#
# Three ways to gather facts, then ONE scoring step (so the score is the same whichever way you look):
#   config  read a Home Assistant config folder (a path on this computer, e.g. a synced or mounted copy)
#   ssh     run this same file on the home server over SSH (python3 on the server reads the folder and
#           the server's settings, and sends back only yes/no style FACTS, never passwords or tokens)
#   api     ask Home Assistant itself (REST + WebSocket) with a long-lived access token read from a file
#
# Safety rules this file follows:
#   * read-only: --check never changes anything.  Only apply_fixes() writes, and only after a preview + "yes".
#   * a token is read from a file (never from the command line or environment), kept in memory only,
#     never printed, never logged; every error message is scrubbed of it before it is shown.
#   * password hashes, TOTP secrets and access tokens found in .storage are never copied into the facts.
#   * scoring is deterministic: same facts + same "now" = same score (tests use fixed facts).
import base64, hashlib, ipaddress, json, os, re, socket, ssl, struct, subprocess, sys, tarfile, time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse

try:
    import yaml
except ImportError:                       # pragma: no cover - Fedora always has it; a bare server might not
    yaml = None

VERSION = "1.0"
MAX_INCLUDE_DEPTH = 8
SKIP_DIRS = {".git", ".storage", "deps", "custom_components", ".cloud", "tts", "www", "__pycache__", "node_modules", "backups"}
LOCAL_SOURCES = ("config", "ssh", "api")


class Problem(Exception):
    """A plain-English problem to show the user (not a crash)."""


# ============================================================================================================
# YAML loading that understands Home Assistant's special tags (!secret, !include..., !input, !env_var)
# ============================================================================================================
class Tagged:
    def __init__(self, tag, value):
        self.tag, self.value = tag, value

    def __repr__(self):
        return "%s %r" % (self.tag, self.value)


def _make_loader(path, root, issues, depth, resolve=True):
    if yaml is None:
        raise Problem("PyYAML is missing. Install it with: sudo dnf install python3-pyyaml (Fedora) or sudo apt install python3-yaml (Debian/Ubuntu)")

    class L(yaml.SafeLoader):
        pass

    base = Path(path).parent

    def safe_target(rel):
        target = (base / str(rel)).resolve()
        try:
            target.relative_to(Path(root).resolve())
        except ValueError:
            issues.append("an !include in %s points outside the config folder (%s) and was ignored" % (path, rel))
            return None
        return target

    def load_one(target):
        if depth >= MAX_INCLUDE_DEPTH:
            issues.append("includes nested too deeply at %s" % target)
            return None
        return load_yaml_file(target, root, issues, depth + 1)

    def listdir(rel):
        t = safe_target(rel)
        if t is None or not t.is_dir():
            if t is not None:
                issues.append("!include_dir folder not found: %s" % rel)
            return []
        out = []
        for p in sorted(t.rglob("*.yaml")):
            if not any(part.startswith(".") for part in p.relative_to(t).parts):
                out.append(p)
        return out

    def include_file(loader, node):
        t = safe_target(loader.construct_scalar(node))
        if t is not None and not t.is_file():
            issues.append("%s says !include %s but that file doesn't exist (Home Assistant would refuse to start)" % (Path(path).name, loader.construct_scalar(node)))
            return None
        return load_one(t) if t is not None else None

    def include_dir_list(loader, node):
        return [load_one(p) for p in listdir(loader.construct_scalar(node))]

    def include_dir_named(loader, node):
        return {p.stem: load_one(p) for p in listdir(loader.construct_scalar(node))}

    def include_dir_merge_list(loader, node):
        out = []
        for p in listdir(loader.construct_scalar(node)):
            d = load_one(p)
            out.extend(d if isinstance(d, list) else ([] if d is None else [d]))
        return out

    def include_dir_merge_named(loader, node):
        out = {}
        for p in listdir(loader.construct_scalar(node)):
            d = load_one(p)
            if isinstance(d, dict):
                out.update(d)
        return out

    def construct_mapping(loader, node, deep=False):
        seen = set()
        for k, _ in node.value:
            try:
                key = loader.construct_object(k, deep=True)
            except Exception:
                continue
            if isinstance(key, (str, int)):
                if key in seen:
                    issues.append("duplicate key '%s' in %s (line %d): the second one silently wins" % (key, path, k.start_mark.line + 1))
                seen.add(key)
        return yaml.SafeLoader.construct_mapping(loader, node, deep)

    def generic(loader, tag_suffix, node):
        tag = "!" + tag_suffix
        if isinstance(node, yaml.ScalarNode):
            return Tagged(tag, loader.construct_scalar(node))
        if isinstance(node, yaml.SequenceNode):
            return Tagged(tag, loader.construct_sequence(node, deep=True))
        return Tagged(tag, loader.construct_mapping(node, deep=True))

    if resolve:          # a syntax-only parse (documentation snippets, tests) keeps !include as a tagged value instead
        L.add_constructor("!include", include_file)
        L.add_constructor("!include_dir_list", include_dir_list)
        L.add_constructor("!include_dir_merge_list", include_dir_merge_list)
        L.add_constructor("!include_dir_named", include_dir_named)
        L.add_constructor("!include_dir_merge_named", include_dir_merge_named)
    L.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, construct_mapping)
    L.add_multi_constructor("!", generic)
    return L


def load_yaml_file(path, root, issues, depth=0):
    """Load one YAML file; includes are followed (inside `root` only). Problems go into `issues`."""
    path = Path(path)
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as e:
        issues.append("could not read %s (%s)" % (path, e.strerror))
        return None
    L = _make_loader(path, root, issues, depth)
    try:
        return yaml.load(text, Loader=L)
    except yaml.YAMLError as e:
        mark = getattr(e, "problem_mark", None)
        where = " (line %d)" % (mark.line + 1) if mark else ""
        issues.append("%s is not valid YAML%s: %s" % (path.name, where, getattr(e, "problem", str(e))))
        return None


def load_yaml_text(text, issues=None):
    """Load YAML text with HA tags kept as Tagged() (used by tests and the explainer)."""
    issues = [] if issues is None else issues
    L = _make_loader("<text>", ".", issues, 0, resolve=False)
    return yaml.load(text, Loader=L)


# ============================================================================================================
# Small helpers
# ============================================================================================================
def iso_to_epoch(s):
    if s is None:
        return None
    if isinstance(s, (int, float)):
        return float(s)
    try:
        s = str(s).replace("Z", "+00:00")
        d = datetime.fromisoformat(s)
        if d.tzinfo is None:
            d = d.replace(tzinfo=timezone.utc)
        return d.timestamp()
    except ValueError:
        return None


def as_list(v):
    if v is None:
        return []
    return v if isinstance(v, list) else [v]


HOME_NETWORKS = [ipaddress.ip_network(n) for n in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "169.254.0.0/16",
    "100.64.0.0/10",              # carrier-grade NAT range, also used by NordVPN Meshnet and Tailscale (your own VPN)
    "fc00::/7", "fe80::/10", "::1/128")]


def is_private_ip(s):
    """True for addresses that belong to a home network or your own VPN. Anything else counts as 'the internet'
    (on purpose a short, explicit list rather than Python's broader is_private)."""
    try:
        ip = ipaddress.ip_address(s)
    except ValueError:
        return True          # not an address: don't call it "external"
    return any(ip in n for n in HOME_NETWORKS if n.version == ip.version)


def resolve_cmd(cmd):
    """Test hook: SL_TEST_STUBDIR points at a folder of stand-in scripts (docker, ss, ufw, ssh ...). A command that has a
    stand-in there is run through bash, so tests behave the same on Linux and on Windows. Never set on a real machine."""
    stub = os.environ.get("SL_TEST_STUBDIR")
    if stub and os.path.isfile(os.path.join(stub, cmd[0])):
        return [os.environ.get("SL_TEST_BASH", "bash"), os.path.join(stub, cmd[0])] + list(cmd[1:])
    return list(cmd)


def run(cmd, timeout=15, stdin=None):
    """Run a command (list, never a shell string). Returns stdout text, or None if unavailable/failed."""
    try:
        r = subprocess.run(resolve_cmd(cmd), capture_output=True, text=True, timeout=timeout, input=stdin)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout if r.returncode == 0 else None


def scrub(text, *secrets):
    for s in secrets:
        if s and len(s) >= 6:
            text = text.replace(s, "[token hidden]")
    return text


def test_mode(path, root):
    """File mode; tests can pin modes with SL_TEST_MODES (a file of 'relative/path octal' lines) because
    Windows/Git Bash cannot hold real Unix permissions."""
    f = os.environ.get("SL_TEST_MODES")
    rel = os.path.relpath(path, root).replace(os.sep, "/")
    if f and os.path.isfile(f):
        for line in open(f, encoding="utf-8"):
            parts = line.split()
            if len(parts) == 2 and parts[0] == rel:
                return int(parts[1], 8)
    try:
        return os.stat(path).st_mode & 0o777
    except OSError:
        return None


# ============================================================================================================
# 1. Facts from a CONFIG FOLDER
# ============================================================================================================
SENSITIVE_KEYS = r"password|passwd|api_key|apikey|api_token|token|access_token|auth_token|client_secret|secret|private_key|psk|rtsp_password"
INLINE_RE = re.compile(r"^(\s*(?:-\s+)?)(%s)\s*:\s*(.+?)\s*$" % SENSITIVE_KEYS, re.I)
URL_CRED_RE = re.compile(r"[a-z][a-z0-9+.-]*://[^\s/:@'\"]+:[^\s/@'\"]+@", re.I)
DEFAULT_USERNAMES = {"admin", "administrator", "homeassistant", "home", "ha", "hass", "user", "test", "guest", "pi", "root", "demo", "family", "everyone", "shared"}
SHARED_NAMES = {"admin", "administrator", "family", "everyone", "shared", "guest", "household", "user", "home", "homeassistant"}
WEAK_PASSWORDS = ["homeassistant", "password", "password1", "123456", "12345678", "123456789", "qwerty", "admin", "admin123",
                  "letmein", "welcome", "home", "hass", "changeme", "iloveyou", "abc123", "111111", "000000", "test", "test1234"]
CLOUD_DOMAINS = {"cloud", "google_assistant", "alexa", "nest", "ring", "tuya", "smartthings", "myq", "ecobee", "wyzecam", "arlo", "blink",
                 "eufy_security", "ewelink", "sonoff_cloud", "xiaomi_home", "smartthinq_sensors", "meross", "tplink_cloud", "hue_cloud", "spotify",
                 "withings", "fitbit", "google_assistant_sdk", "google_generative_ai_conversation", "openai_conversation", "analytics"}
CAMERA_DOMAINS = {"generic", "onvif", "reolink", "amcrest", "foscam", "unifiprotect", "ring", "arlo", "blink", "eufy_security", "frigate", "rtsp_to_webrtc", "nest"}
COMMON_WEBHOOK_WORDS = ("test", "hook", "webhook", "door", "garage", "gate", "light", "doorbell", "alarm", "home", "demo", "my", "ha", "hass")
Z2M_DEFAULT_KEY = [1, 3, 5, 7, 9, 11, 13, 15, 0, 2, 4, 6, 8, 10, 12, 13]


def merge_packages(cfg):
    """Return configuration with packages merged in (as Home Assistant does): dicts merged key by key,
    lists extended; the main file wins on conflicts."""
    if not isinstance(cfg, dict):
        return {}
    out = dict(cfg)
    ha = cfg.get("homeassistant")
    pk = ha.get("packages") if isinstance(ha, dict) else None
    if not isinstance(pk, dict):
        return out
    for _, pkg in pk.items():
        if not isinstance(pkg, dict):
            continue
        for key, val in pkg.items():
            if key == "homeassistant":
                continue
            cur = out.get(key)
            if cur is None:
                out[key] = val
            elif isinstance(cur, dict) and isinstance(val, dict):
                merged = dict(val)
                merged.update(cur)
                out[key] = merged
            elif isinstance(cur, list) and isinstance(val, list):
                out[key] = cur + val
    return out


def _read_json(p):
    try:
        return json.loads(Path(p).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def _walk(obj):
    """Yield every (key, value) in nested dicts/lists/Tagged."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield k, v
            yield from _walk(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from _walk(v)
    elif isinstance(obj, Tagged):
        yield from _walk(obj.value)


def _yaml_files(root):
    root = Path(root)
    for dirpath, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
        for f in sorted(files):
            if f.endswith((".yaml", ".yml")) and f != "secrets.yaml":
                yield Path(dirpath) / f


def scan_inline_secrets(root):
    found = []
    for p in _yaml_files(root):
        try:
            lines = p.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        rel = str(p.relative_to(root)).replace(os.sep, "/")
        for n, line in enumerate(lines, 1):
            if line.lstrip().startswith("#"):
                continue
            m = INLINE_RE.match(line)
            if m:
                val = re.sub(r"\s+#.*$", "", m.group(3)).strip().strip("'\"").strip()
                if val and not val.startswith(("!secret", "!env_var", "!input", "{{", "{%", "|", ">", "&", "*")) \
                        and val.lower() not in ("null", "none", "~", "true", "false", "") and not val.startswith("["):
                    found.append({"file": rel, "line": n, "key": m.group(2).lower(), "kind": "key"})
                    continue
            if URL_CRED_RE.search(line):
                found.append({"file": rel, "line": n, "key": "url-with-password", "kind": "url"})
    # dashboards made in the browser live in .storage/lovelace*
    st = Path(root) / ".storage"
    if st.is_dir():
        for p in sorted(st.glob("lovelace*")):
            try:
                text = p.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            if re.search(r'"(%s)"\s*:\s*"[^"]{4,}"' % SENSITIVE_KEYS, text, re.I) or URL_CRED_RE.search(text):
                found.append({"file": ".storage/" + p.name, "line": 0, "key": "dashboard", "kind": "dashboard"})
    return found


def _git(root, *args):
    return run(["git", "-C", str(root)] + list(args), timeout=20)


def git_facts(root):
    root = Path(root)
    g = {"present": (root / ".git").exists(), "secrets_ignored": None, "storage_ignored": None, "tracked_secrets": None}
    gi = root / ".gitignore"
    lines = []
    if gi.is_file():
        lines = [l.strip() for l in gi.read_text(encoding="utf-8", errors="replace").splitlines() if l.strip() and not l.startswith("#")]

    def ignored(name):
        return any(l.rstrip("/").lstrip("/") in (name, name + "/*", "*" + name) or (l.endswith("*") and name.startswith(l.rstrip("*").lstrip("/"))) for l in lines)

    g["secrets_ignored"] = ignored("secrets.yaml")
    g["storage_ignored"] = ignored(".storage")
    if g["present"]:
        out = _git(root, "ls-files")
        if out is not None:
            tracked = out.splitlines()
            g["tracked_secrets"] = any(t == "secrets.yaml" or t.startswith(".storage/") for t in tracked)
    return g


def read_failed_logins(root):
    log = Path(root) / "home-assistant.log"
    res = {"known": False, "count": 0, "external": 0, "ips": []}
    if not log.is_file():
        return res
    try:
        with open(log, "rb") as fh:
            fh.seek(0, 2)
            size = fh.tell()
            fh.seek(max(0, size - 2_000_000))
            text = fh.read().decode("utf-8", errors="replace")
    except OSError:
        return res
    ips = re.findall(r"invalid authentication from ([0-9a-fA-F:.]+)", text)
    ips += re.findall(r"Login attempt or request with invalid authentication from ([^\s]+)", text)
    ips = sorted(set(ips + []))
    all_count = len(re.findall(r"invalid authentication from", text))
    res.update(known=True, count=all_count, ips=ips[:20], external=len([i for i in ips if not is_private_ip(i)]))
    return res


def read_backups(root):
    res = {"known": False, "count": 0, "newest": None, "all_protected": None}
    bdir = Path(root) / "backups"
    if not bdir.is_dir():
        return res
    res["known"] = True
    newest, prot = None, []
    for p in sorted(bdir.glob("*.tar")):
        ts, protected = None, None
        try:
            with tarfile.open(p) as t:
                try:
                    f = t.extractfile("backup.json")
                    meta = json.load(f) if f else {}
                    ts = iso_to_epoch(meta.get("date"))
                    protected = meta.get("protected")
                except (KeyError, ValueError):
                    pass
        except (tarfile.TarError, OSError):
            pass
        if ts is None:
            try:
                ts = p.stat().st_mtime
            except OSError:
                continue
        res["count"] += 1
        newest = ts if newest is None else max(newest, ts)
        prot.append(protected)
    res["newest"] = newest
    if prot:
        res["all_protected"] = None if any(x is None for x in prot) else all(bool(x) for x in prot)
    return res


def parse_mosquitto(path):
    r = {"found": True, "path": str(path), "allow_anonymous": False, "password_file": False, "acl_file": False, "listeners": [], "tls": False}
    cur = {"port": 1883, "bind": "", "tls": False, "anonymous": None, "protocol": "mqtt"}
    glob_anon = None
    listeners, have_listener = [], False
    try:
        lines = Path(path).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return {"found": False}
    for raw in lines:
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        k, v = parts[0].lower(), parts[1:]
        if k == "listener":
            if have_listener:
                listeners.append(cur)
            have_listener = True
            cur = {"port": int(v[0]) if v and v[0].isdigit() else 1883, "bind": v[1] if len(v) > 1 else "", "tls": False, "anonymous": None, "protocol": "mqtt"}
        elif k == "allow_anonymous" and v:
            val = v[0].lower() == "true"
            if have_listener:
                cur["anonymous"] = val
            else:
                glob_anon = val
        elif k == "password_file":
            r["password_file"] = True
        elif k == "acl_file":
            r["acl_file"] = True
        elif k in ("certfile", "keyfile", "cafile"):
            cur["tls"] = True
        elif k == "protocol" and v:
            cur["protocol"] = v[0]
    if have_listener:
        listeners.append(cur)
    if not listeners:
        listeners = [dict(cur, anonymous=None)]
    anon = False
    for l in listeners:
        eff = l["anonymous"] if l["anonymous"] is not None else (glob_anon if glob_anon is not None else False)
        l["effective_anonymous"] = eff
        anon = anon or eff
        r["tls"] = r["tls"] or l["tls"]
    r["allow_anonymous"] = anon
    r["listeners"] = [{k: v for k, v in l.items() if k in ("port", "bind", "tls", "effective_anonymous", "protocol")} for l in listeners]
    return r


def find_sibling(root, names):
    root = Path(root).resolve()
    # the server kit keeps every service in a folder of its own: <stack>/homeassistant/config, <stack>/mosquitto/config, ...
    for base in (root.parent.parent, root.parent, root):
        for n in names:
            p = base / n
            if p.is_file():
                return p
    return None


def parse_z2m(path):
    issues = []
    cfg = load_yaml_file(path, Path(path).parent, issues)
    if not isinstance(cfg, dict):
        return {"found": True, "network_key": "unknown", "permit_join": None}
    adv = cfg.get("advanced") if isinstance(cfg.get("advanced"), dict) else {}
    key = adv.get("network_key")
    if key is None:
        kind = "unknown"
    elif isinstance(key, str) and key.upper() == "GENERATE":
        kind = "generate"
    elif isinstance(key, list):
        kind = "default" if key == Z2M_DEFAULT_KEY else "custom"
    else:
        kind = "unknown"
    return {"found": True, "network_key": kind, "permit_join": bool(cfg.get("permit_join")) if "permit_join" in cfg else None}


def collect_config(cfgdir, opts=None):
    """Facts from a Home Assistant config folder. Read-only."""
    opts = opts or {}
    root = Path(cfgdir)
    if not root.is_dir():
        raise Problem("That folder doesn't exist: %s" % cfgdir)
    main = root / "configuration.yaml"
    if not main.is_file():
        raise Problem("There is no configuration.yaml in %s. Point me at the folder that holds it (often called 'config')." % cfgdir)
    issues = []
    cfg = load_yaml_file(main, root, issues)
    eff = merge_packages(cfg if isinstance(cfg, dict) else {})
    F = new_facts("config")
    F["config_dir"] = str(root)
    F["yaml_issues"] = issues
    F["yaml_ok"] = not issues
    # --- http / auth
    http = eff.get("http") if isinstance(eff.get("http"), dict) else None
    F["http"] = {"present": http is not None, "ip_ban_enabled": None, "login_attempts_threshold": None, "use_x_forwarded_for": None,
                 "trusted_proxies": [], "ssl": False, "cors": [], "server_host": None}
    if http is not None:
        F["http"].update(ip_ban_enabled=http.get("ip_ban_enabled"), login_attempts_threshold=http.get("login_attempts_threshold"),
                         use_x_forwarded_for=http.get("use_x_forwarded_for"), trusted_proxies=[str(x) for x in as_list(http.get("trusted_proxies"))],
                         ssl=bool(http.get("ssl_certificate")), cors=[str(x) for x in as_list(http.get("cors_allowed_origins"))],
                         server_host=http.get("server_host"))
    hacfg = eff.get("homeassistant") if isinstance(eff.get("homeassistant"), dict) else {}
    F["external_url"] = hacfg.get("external_url") if isinstance(hacfg.get("external_url"), str) else None
    F["internal_url"] = hacfg.get("internal_url") if isinstance(hacfg.get("internal_url"), str) else None
    provs = []
    for p in as_list(hacfg.get("auth_providers")):
        if isinstance(p, dict):
            provs.append({"type": p.get("type"), "allow_bypass_login": bool(p.get("allow_bypass_login")),
                          "networks": [str(x) for x in as_list(p.get("trusted_networks"))]})
    F["auth_providers"] = provs
    F["packages_enabled"] = isinstance(hacfg.get("packages"), dict) and bool(hacfg.get("packages"))
    F["yaml_integrations"] = sorted(k for k in eff.keys() if isinstance(k, str))
    lg = eff.get("logger") if isinstance(eff.get("logger"), dict) else {}
    levels = [str(lg.get("default", "")).lower()] + [str(v).lower() for v in (lg.get("logs") or {}).values()] if isinstance(lg.get("logs", {}), dict) else [str(lg.get("default", "")).lower()]
    F["debug_logging"] = any(l in ("debug", "notset") for l in levels)
    # --- version
    v = root / ".HA_VERSION"
    F["ha_version"] = v.read_text(encoding="utf-8", errors="replace").strip() if v.is_file() else None
    # --- users, tokens, mfa from .storage (hashes/secrets are never copied out)
    st = root / ".storage"
    auth = _read_json(st / "auth")
    if auth and isinstance(auth.get("data"), dict):
        d = auth["data"]
        creds = {}
        for c in d.get("credentials", []):
            if isinstance(c, dict) and c.get("auth_provider_type") == "homeassistant":
                creds[c.get("user_id")] = (c.get("data") or {}).get("username")
        totp = _read_json(st / "auth_module.totp")
        notify_mfa = _read_json(st / "auth_module.notify")
        mfa_ids = set()
        for src in (totp, notify_mfa):
            if src and isinstance(src.get("data"), dict):
                for u in src["data"].get("users", []):
                    if isinstance(u, dict) and u.get("user_id"):
                        mfa_ids.add(u["user_id"])
        users = []
        for u in d.get("users", []):
            if not isinstance(u, dict) or u.get("system_generated"):
                continue
            users.append({"id": u.get("id"), "name": u.get("name"), "username": creds.get(u.get("id")),
                          "owner": bool(u.get("is_owner")), "active": bool(u.get("is_active", True)),
                          "admin": "system-admin" in (u.get("group_ids") or []), "local_only": bool(u.get("local_only")),
                          "mfa": u.get("id") in mfa_ids})
        F["users"], F["users_known"], F["mfa_known"] = users, True, True
        toks = []
        for t in d.get("refresh_tokens", []):
            if isinstance(t, dict) and t.get("token_type") == "long_lived_access_token":
                toks.append({"name": t.get("client_name") or "(unnamed)", "created": iso_to_epoch(t.get("created_at")),
                             "last_used": iso_to_epoch(t.get("last_used_at"))})
        F["tokens"], F["tokens_known"] = toks, True
        pw = _read_json(st / "auth_provider.homeassistant")
        if pw and isinstance(pw.get("data"), dict):
            F["weak_passwords"] = check_weak_passwords(pw["data"].get("users", []), opts.get("checkpw"))
    # --- integrations
    ce = _read_json(st / "core.config_entries")
    if ce and isinstance(ce.get("data"), dict):
        doms = []
        for e in ce["data"].get("entries", []):
            if isinstance(e, dict) and e.get("domain"):
                doms.append({"domain": e["domain"], "disabled": bool(e.get("disabled_by"))})
        F["integrations"] = doms
        F["integrations_known"] = True
    cl = _read_json(st / "cloud")
    F["nabu_casa_logged_in"] = bool(cl and isinstance(cl.get("data"), dict) and cl["data"].get("refresh_token"))
    # --- files, git, secrets
    F["inline_secrets"] = scan_inline_secrets(root)
    sf = root / "secrets.yaml"
    F["secrets_file"] = {"exists": sf.is_file(), "mode": test_mode(sf, root) if sf.is_file() else None}
    F["git"] = git_facts(root)
    F["perms"] = {"config_dir": test_mode(root, root), "storage": test_mode(st, root) if st.is_dir() else None}
    F["failed_logins"] = read_failed_logins(root)
    bans = root / "ip_bans.yaml"
    F["ip_bans"] = len(load_yaml_file(bans, root, []) or {}) if bans.is_file() else 0
    F["backups"] = read_backups(root)
    # --- webhooks / cameras / watch package
    ids, cam_cred = [], 0
    for p in _yaml_files(root):
        if ".storage" in p.parts:
            continue
        d = load_yaml_file(p, root, [])
        for k, v in _walk(d):
            if k == "webhook_id" and isinstance(v, str):
                ids.append(v)
    F["webhook_ids_weak"] = sorted(set(w for w in ids if weak_webhook(w)))
    F["webhook_count"] = len(set(ids))
    F["login_alert_automation"] = detect_login_alert(root)
    # --- siblings: mosquitto and zigbee2mqtt
    mq = opts.get("mqtt_conf") or find_sibling(root, ["mosquitto/config/mosquitto.conf", "mosquitto/mosquitto.conf"])
    F["mqtt"] = parse_mosquitto(mq) if mq else {"found": False}
    z = opts.get("z2m_conf") or find_sibling(root, ["zigbee2mqtt/data/configuration.yaml", "zigbee2mqtt/configuration.yaml"])
    F["z2m"] = parse_z2m(z) if z else {"found": False}
    return F


def check_weak_passwords(users, checkpw=None):
    """Test stored password hashes against a short list of common passwords. Needs the `bcrypt` module (or an
    injected checkpw for tests). Returns {'known': bool, 'weak': [usernames]}. Hashes never leave this function."""
    if checkpw is None:
        try:
            import bcrypt
            checkpw = bcrypt.checkpw
        except ImportError:
            return {"known": False, "weak": []}
    weak = []
    for u in users:
        if not isinstance(u, dict) or not u.get("password"):
            continue
        try:
            h = base64.b64decode(u["password"])
        except (ValueError, TypeError):
            continue
        name = str(u.get("username", ""))
        for guess in WEAK_PASSWORDS + [name, name + "123", name.capitalize() + "1"]:
            if guess and len(guess) >= 1:
                try:
                    if checkpw(guess.encode(), h):
                        weak.append(name)
                        break
                except Exception:
                    break
    return {"known": True, "weak": sorted(set(weak))}


def weak_webhook(w):
    wl = w.lower()
    if len(w) < 24:
        return True
    return any(wl.strip("-_") == word for word in COMMON_WEBHOOK_WORDS)


def detect_login_alert(root):
    for p in _yaml_files(root):
        try:
            t = p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if "http-login" in t or "invalid authentication" in t.lower() or "sl_security_watch" in t or "sl_login_alert" in t:
            return True
    return False


# ============================================================================================================
# 2. Facts from the SERVER (runs on the server, over SSH)
# ============================================================================================================
def collect_server(opts):
    """Server-side facts. Every command is optional: not available = unknown (None), never an error."""
    S = {"containers": None, "listening": None, "firewall": {"known": False}, "host": {"auto_updates": None, "fail2ban": None, "os": None, "rootless": None}}
    engine = None
    for e in ("docker", "podman"):
        if run([e, "--version"]) is not None:
            engine = e
            break
    ha_dir = opts.get("ha_dir")
    if engine:
        names = (run([engine, "ps", "-q"]) or "").split()
        conts = []
        if names:
            raw = run([engine, "inspect"] + names)
            try:
                for c in json.loads(raw or "[]"):
                    hc, cfg = c.get("HostConfig") or {}, c.get("Config") or {}
                    mounts = c.get("Mounts") or []
                    ports = []
                    for cport, binds in (hc.get("PortBindings") or {}).items():
                        for b in (binds or []):
                            ports.append({"port": str(b.get("HostPort", "")), "ip": b.get("HostIp") or "0.0.0.0"})
                    name = (c.get("Name") or "").lstrip("/")
                    conts.append({"name": name, "image": cfg.get("Image", ""), "user": cfg.get("User") or "", "privileged": bool(hc.get("Privileged")),
                                  "read_only": bool(hc.get("ReadonlyRootfs")), "cap_drop": hc.get("CapDrop") or [], "network": hc.get("NetworkMode"),
                                  "docker_sock": any("docker.sock" in str(m.get("Source", "")) for m in mounts), "ports": ports})
                    if not ha_dir and ("home-assistant" in cfg.get("Image", "") or name in ("homeassistant", "home-assistant")):
                        for m in mounts:
                            if m.get("Destination") == "/config":
                                ha_dir = m.get("Source")
            except (ValueError, TypeError, AttributeError):
                conts = None
        S["containers"] = conts
        info = run([engine, "info", "--format", "{{.Host.Security.Rootless}}" if engine == "podman" else "{{.SecurityOptions}}"])
        if info is not None:
            S["host"]["rootless"] = ("true" in info.lower()) if engine == "podman" else ("rootless" in info.lower())
    ss = run(["ss", "-H", "-ltn"])
    if ss is not None:
        listening = []
        for line in ss.splitlines():
            cols = line.split()
            if len(cols) >= 4:
                addr = cols[3]
                host, _, port = addr.rpartition(":")
                if port.isdigit():
                    listening.append({"port": int(port), "bind": host.strip("[]") or "*"})
        S["listening"] = listening
    ufw = run(["ufw", "status"])
    if ufw is not None:
        S["firewall"] = {"known": True, "active": "Status: active" in ufw, "kind": "ufw"}
    else:
        fw = run(["firewall-cmd", "--state"])
        if fw is not None:
            S["firewall"] = {"known": True, "active": fw.strip() == "running", "kind": "firewalld"}
    for unit in ("dnf-automatic.timer", "dnf5-automatic.timer", "dnf-automatic-install.timer", "unattended-upgrades.service", "apt-daily-upgrade.timer"):
        r = run(["systemctl", "is-enabled", unit])
        if r is not None and r.strip() == "enabled":
            S["host"]["auto_updates"] = True
            break
    else:
        if run(["systemctl", "--version"]) is not None:
            S["host"]["auto_updates"] = False
    f2 = run(["systemctl", "is-active", "fail2ban"])
    S["host"]["fail2ban"] = (f2 is not None and f2.strip() == "active") if run(["systemctl", "--version"]) is not None else None
    try:
        for line in open("/etc/os-release", encoding="utf-8"):
            if line.startswith("PRETTY_NAME="):
                S["host"]["os"] = line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    S["ha_dir_guess"] = ha_dir
    return S


def collect_via_ssh_remote(opts):
    """Runs ON the server (called by `collect --json`). Returns the facts dictionary."""
    S = collect_server(opts)
    ha_dir = opts.get("ha_dir") or S.get("ha_dir_guess")
    if not ha_dir:
        for c in ("/opt/homeassistant-stack/homeassistant/config", "/opt/homeassistant/config", "/srv/homeassistant/config",
                  os.path.expanduser("~/homeassistant/config"), "/home/homeassistant/.homeassistant", "/config"):
            if os.path.isfile(os.path.join(c, "configuration.yaml")):
                ha_dir = c
                break
    if not ha_dir:
        raise Problem("I couldn't find Home Assistant's config folder on that server. Tell me where it is with --ha-dir /path/to/config")
    F = collect_config(ha_dir, opts)
    F["source"] = "ssh"
    F["server"] = S
    return F


def collect_ssh(target, opts, ssh_cmd="ssh"):
    """Run this file on the server and bring back the facts."""
    if not re.fullmatch(r"[A-Za-z0-9._@:\[\]-]+", target) or target.startswith("-"):
        raise Problem("That doesn't look like a valid server address (use name@address, for example matt@10.0.30.42).")
    me = Path(__file__).resolve()
    code = me.read_text(encoding="utf-8")
    args = ["python3", "-", "collect", "--json"]
    if opts.get("ha_dir"):
        if not re.fullmatch(r"[A-Za-z0-9._/~@:+-]+", opts["ha_dir"]):
            raise Problem("That folder name has unusual characters; please use a simple path.")
        args += ["--ha-dir", opts["ha_dir"]]
    cmd = [ssh_cmd, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--", target] + args
    try:
        r = subprocess.run(resolve_cmd(cmd), input=code, capture_output=True, text=True, timeout=120)
    except FileNotFoundError:
        raise Problem("ssh isn't installed on this computer.")
    except subprocess.TimeoutExpired:
        raise Problem("The server took too long to answer.")
    if r.returncode != 0:
        err = (r.stderr or "").strip().splitlines()
        hint = err[-1] if err else "unknown reason"
        if "Permission denied" in hint or "publickey" in hint:
            hint += "  (Tip: set up SSH keys first: ssh-keygen -t ed25519 && ssh-copy-id %s)" % target
        elif "Host key verification failed" in hint:
            hint += "  (Tip: connect once by hand, 'ssh %s', and accept the fingerprint after checking it.)" % target
        raise Problem("Couldn't read the server over SSH: %s" % hint)
    try:
        facts = json.loads(r.stdout)
    except ValueError:
        raise Problem("The server answered, but not in a way I understand. Is python3 installed there (and python3-yaml)? Details: %s" % ((r.stdout or r.stderr)[:200]))
    if isinstance(facts, dict) and facts.get("problem"):
        raise Problem(facts["problem"])
    facts["source"] = "ssh"
    return facts


# ============================================================================================================
# 3. Facts from Home Assistant's API (REST + WebSocket)
# ============================================================================================================
class WS:
    """Tiny WebSocket client (RFC 6455), standard library only."""

    def __init__(self, url, timeout=15, cafile=None):
        u = urlparse(url)
        self.tls = u.scheme in ("https", "wss")
        host, port = u.hostname, u.port or (443 if self.tls else 80)
        raw = socket.create_connection((host, port), timeout=timeout)
        if self.tls:
            ctx = ssl.create_default_context(cafile=cafile)
            raw = ctx.wrap_socket(raw, server_hostname=host)
        self.s = raw
        key = base64.b64encode(os.urandom(16)).decode()
        path = (u.path.rstrip("/") + "/api/websocket")
        self.s.sendall(("GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                        "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % (path, host, port, key)).encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            chunk = self.s.recv(4096)
            if not chunk:
                raise Problem("Home Assistant closed the connection while starting the WebSocket.")
            resp += chunk
        head, _, self.buf = resp.partition(b"\r\n\r\n")
        if b" 101 " not in head.split(b"\r\n")[0]:
            raise Problem("Home Assistant refused the WebSocket (%s)." % head.split(b"\r\n")[0].decode(errors="replace"))
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        if accept.encode() not in head:
            raise Problem("The WebSocket handshake didn't check out; not talking to Home Assistant?")

    def _need(self, n):
        while len(self.buf) < n:
            chunk = self.s.recv(65536)
            if not chunk:
                raise Problem("The connection to Home Assistant dropped.")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def send(self, obj):
        data = json.dumps(obj).encode()
        mask = os.urandom(4)
        n = len(data)
        head = b"\x81" + (bytes([0x80 | n]) if n < 126 else b"\xfe" + struct.pack(">H", n) if n < 65536 else b"\xff" + struct.pack(">Q", n))
        self.s.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def recv(self):
        payload = b""
        while True:
            b1, b2 = self._need(2)
            op, ln = b1 & 0x0F, b2 & 0x7F
            if ln == 126:
                ln = struct.unpack(">H", self._need(2))[0]
            elif ln == 127:
                ln = struct.unpack(">Q", self._need(8))[0]
            data = self._need(ln)
            if op == 0x9:      # ping -> pong
                self.s.sendall(b"\x8a\x80" + os.urandom(4))
                continue
            if op == 0x8:
                raise Problem("Home Assistant closed the connection.")
            payload += data
            if b1 & 0x80:
                return json.loads(payload.decode("utf-8"))

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


def read_token(path):
    """Read the token from a root-only file. Refuses a file other people can read."""
    p = Path(path)
    if not p.is_file():
        raise Problem("The token file %s doesn't exist yet. Create it with: secure-linux-ha token-set" % path)
    mode = test_mode(p, p.parent)
    if (os.name == "posix" or os.environ.get("SL_TEST_MODES")) and mode is not None and mode & 0o077:
        raise Problem("The token file %s can be read by other people (mode %o). Fix it with: sudo chmod 600 %s" % (path, mode, path))
    tok = p.read_text(encoding="utf-8").strip()
    if not tok:
        raise Problem("The token file %s is empty." % path)
    return tok


def collect_api(url, token_file, opts=None):
    opts = opts or {}
    token = read_token(token_file)
    cafile = opts.get("cafile")
    base = url.rstrip("/")
    F = new_facts("api")
    F["api_errors"] = []
    errs = F["api_errors"]
    try:
        import urllib.request, urllib.error
        ctx = ssl.create_default_context(cafile=cafile) if base.startswith("https") else None
        req = urllib.request.Request(base + "/api/config", headers={"Authorization": "Bearer " + token})
        with urllib.request.urlopen(req, timeout=15, context=ctx) as r:
            cfg = json.load(r)
    except urllib.error.HTTPError as e:
        raise Problem("Home Assistant said no (HTTP %d). The token may be wrong or deleted. Make a new one: Profile > Security > Long-lived access tokens." % e.code)
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise Problem(scrub("I couldn't reach Home Assistant at %s (%s)." % (base, getattr(e, "reason", e)), token))
    F["ha_version"] = cfg.get("version")
    F["external_url"], F["internal_url"] = cfg.get("external_url"), cfg.get("internal_url")
    F["yaml_integrations"] = sorted(c for c in cfg.get("components", []) if "." not in c)
    F["integrations_from_components"] = True
    F["config_dir"] = cfg.get("config_dir")
    try:
        ws = WS(base, cafile=cafile)
    except (Problem, OSError, ssl.SSLError) as e:
        errs.append(scrub("WebSocket: %s" % e, token))
        return F
    try:
        hello = ws.recv()
        if hello.get("type") != "auth_required":
            raise Problem("Unexpected greeting from Home Assistant.")
        ws.send({"type": "auth", "access_token": token})
        res = ws.recv()
        if res.get("type") != "auth_ok":
            raise Problem("Home Assistant did not accept the token.")
        counter = [0]

        def call(msg):
            counter[0] += 1
            msg = dict(msg, id=counter[0])
            ws.send(msg)
            while True:
                r = ws.recv()
                if r.get("id") == counter[0]:
                    return r

        r = call({"type": "auth/current_user"})
        me = r.get("result") if r.get("success") else None
        if me:
            F["api_user"] = {"name": me.get("name"), "admin": bool(me.get("is_admin")), "owner": bool(me.get("is_owner")),
                             "mfa": any(m.get("enabled") for m in me.get("mfa_modules", []))}
        r = call({"type": "config/auth/list"})
        if r.get("success"):
            users = []
            for u in r["result"]:
                if u.get("system_generated"):
                    continue
                users.append({"id": u.get("id"), "name": u.get("name"), "username": u.get("username"), "owner": bool(u.get("is_owner")),
                              "active": bool(u.get("is_active", True)), "admin": "system-admin" in (u.get("group_ids") or []),
                              "local_only": bool(u.get("local_only")), "mfa": None})
            if me:
                for u in users:
                    if me.get("id") == u["id"]:
                        u["mfa"] = any(m.get("enabled") for m in me.get("mfa_modules", []))
            F["users"], F["users_known"] = users, True
        else:
            errs.append("user list needs an administrator token")
        r = call({"type": "auth/refresh_tokens"})
        if r.get("success"):
            toks = [{"name": t.get("client_name") or "(unnamed)", "created": iso_to_epoch(t.get("created_at")), "last_used": iso_to_epoch(t.get("last_used_at"))}
                    for t in r["result"] if t.get("type") == "long_lived_access_token"]
            F["tokens"], F["tokens_known"] = toks, True
        r = call({"type": "config_entries/get"})
        if r.get("success"):
            F["integrations"] = [{"domain": e.get("domain"), "disabled": bool(e.get("disabled_by"))} for e in r["result"] if e.get("domain")]
            F["integrations_known"] = True
        r = call({"type": "backup/info"})
        if r.get("success"):
            res = r["result"]
            newest = iso_to_epoch(res.get("last_completed_automatic_backup"))
            prot = []
            for b in res.get("backups", []):
                t = iso_to_epoch(b.get("date"))
                newest = t if newest is None or (t is not None and t > newest) else newest
                prot.extend(a.get("protected") for a in (b.get("agents") or {}).values())
            F["backups"] = {"known": True, "count": len(res.get("backups", [])), "newest": newest,
                            "all_protected": (all(bool(x) for x in prot) if prot and None not in prot else None)}
        else:
            errs.append("backup information needs an administrator token")
        # update entity (REST) - best effort
        try:
            req = urllib.request.Request(base + "/api/states/update.home_assistant_core_update", headers={"Authorization": "Bearer " + token})
            with urllib.request.urlopen(req, timeout=15, context=ctx) as r2:
                st = json.load(r2)
            F["update"] = {"installed": st.get("attributes", {}).get("installed_version"), "latest": st.get("attributes", {}).get("latest_version")}
        except Exception:
            pass
    except Problem as e:
        errs.append(scrub(str(e), token))
    except (OSError, ValueError, KeyError) as e:
        errs.append(scrub("WebSocket: %s" % e, token))
    finally:
        ws.close()
    return F


# ============================================================================================================
# 4. Facts container + attestations (things only the person can tell us)
# ============================================================================================================
def new_facts(source):
    return {"source": source, "users": None, "users_known": False, "mfa_known": False, "tokens": None, "tokens_known": False,
            "integrations": None, "integrations_known": False, "inline_secrets": None, "http": None, "git": None,
            "backups": {"known": False}, "mqtt": {"found": False}, "z2m": {"found": False}, "failed_logins": {"known": False},
            "secrets_file": None, "perms": None, "webhook_ids_weak": None, "login_alert_automation": None, "server": None,
            "weak_passwords": {"known": False, "weak": []}, "ha_version": None, "update": None, "yaml_integrations": [], "auth_providers": [],
            "external_url": None, "internal_url": None, "nabu_casa_logged_in": None, "cert_days_left": None, "ip_bans": None}


ATTEST_QUESTIONS = [
    ("remote_mode", "How do you reach Home Assistant when you're away from home?", "none|meshnet|wireguard|tailscale|cloudflare|nabucasa|portforward|other",
     "none = I only use it at home; meshnet = NordVPN Meshnet; wireguard = my own VPN; tailscale; cloudflare = Cloudflare Tunnel with a login rule; nabucasa = Nabu Casa; portforward = my router forwards a port to it"),
    ("no_port_forward", "Have you checked your router has NO port-forward to Home Assistant (ports 8123, 443, 1883, 8080)?", "yes|no", "Open your router's admin page and look for 'Port forwarding', 'Virtual server' or 'NAT'."),
    ("iot_vlan", "Are smart-home gadgets on their own separate network (IoT VLAN or guest network)?", "yes|no|na", "It stops a hacked cheap gadget from reaching your computers."),
    ("iot_cloud_blocked", "Have you blocked the internet for gadgets that work locally (cameras, plugs)?", "yes|no|na", "Local-only gadgets can't phone home if the router blocks them."),
    ("wifi_isolation", "Is Wi-Fi 'client isolation' on for the IoT/guest Wi-Fi?", "yes|no|na", "Gadgets can't talk to each other, only to Home Assistant."),
    ("cameras_local", "Are your cameras local-only (no cloud, no P2P, no UPnP)?", "yes|no|na", "A camera that opens a port by itself (UPnP) is a classic way in."),
    ("ssh_addon", "Do you have an SSH/Terminal add-on, and how is it locked down?", "none|keys|password", "none = not installed; keys = key login only; password = password login"),
    ("host_autoupdates", "Does the computer running Home Assistant install security updates automatically?", "yes|no|na", "dnf-automatic (Fedora) or unattended-upgrades (Debian/Ubuntu)."),
    ("physical_secure", "Is the server somewhere visitors can't plug things into it?", "yes|no", "Anyone with a screen and keyboard on it can bypass everything."),
    ("offsite_backup", "Is there an encrypted backup copy OUTSIDE your house (cloud or a relative's place)?", "yes|no", "A fire or theft takes the server AND the backup next to it."),
    ("restore_tested", "When did you last test restoring a backup? (a date like 2026-05-01, or 'no')", "DATE|no", "A backup you've never restored is a hope, not a backup."),
    ("update_routine", "Do you read the release notes then update about once a month?", "yes|no", "Monthly updates keep security fixes coming without surprises."),
    ("log_review", "Do you look at Settings > System > Logs and your login history now and then?", "yes|no", "Spotting odd logins early matters."),
    ("zigbee_key", "Is your Zigbee network key changed from the default (or generated)?", "changed|default|na", "Zigbee2MQTT: use network_key: GENERATE. ZHA creates a random one for you."),
    ("strong_passwords", "Does every account use a long unique password from a password manager?", "yes|no", "Bitwarden is free and works well."),
    ("addons_reviewed", "Have you removed add-ons you don't use?", "yes|no|na", "Every add-on is extra software that can have bugs."),
    ("tokens_reviewed", "Have you reviewed your long-lived access tokens in the last 6 months?", "yes|no|na", "Profile > Security. Delete any you don't recognise."),
    ("mfa_all", "Does every person with a login have two-step login (an authenticator app) switched on?", "yes|no", "Profile > Security > Multi-factor Authentication Modules."),
    ("rootless_containers", "Do your containers run without full root (rootless Podman, or non-root users)?", "yes|no|na", "A break-out from a rootless container gets far less."),
    ("addons_count", "About how many add-ons are installed? (a number, or 'na' if you use Container / no add-ons)", "NUMBER|na", "Fewer is safer."),
]
ATTEST_KEYS = [q[0] for q in ATTEST_QUESTIONS]


def load_attest(path):
    d = {}
    if path and os.path.isfile(path):
        for line in open(path, encoding="utf-8", errors="replace"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                if k.strip() in ATTEST_KEYS:
                    d[k.strip()] = v.strip()
    return d


def save_attest(path, key, value):
    if key not in ATTEST_KEYS:
        raise Problem("Unknown answer name '%s'. Known: %s" % (key, ", ".join(ATTEST_KEYS)))
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,40}", value):
        raise Problem("Answers can only use letters, numbers, - _ and .")
    d = load_attest(path)
    d[key] = value
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    old = os.umask(0o077)
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.write("# Answers you gave to the Home Assistant security checklist (no secrets here).\n")
            for k in ATTEST_KEYS:
                if k in d:
                    f.write("%s=%s\n" % (k, d[k]))
    finally:
        os.umask(old)


# ============================================================================================================
# 5. THE CHECKS  (plain-English why / fix live in TEXT)
# ============================================================================================================
PASS, WARN, FAIL, MANUAL, NA = "PASS", "WARN", "FAIL", "MANUAL", "N/A"
POINTS = {PASS: 1.0, WARN: 0.5, FAIL: 0.0}
CHECKS = []          # (id, category, weight, critical, function)
TEXT = {}            # id -> (title, why, fix)


def check(cid, cat, weight, title, why, fix, critical=False):
    TEXT[cid] = (title, why, fix)

    def deco(fn):
        CHECKS.append((cid, cat, weight, critical, fn))
        return fn
    return deco


def _users(F):
    return [u for u in (F.get("users") or []) if u.get("active", True)]


@check("remote-exposure", "Remote access", 5, "Home Assistant is not forwarded to the internet",
       "A router port-forward (or a gadget using UPnP) puts the login page in front of the whole internet. Bots find these within hours and try passwords all day.",
       "Remove any port-forward to Home Assistant on your router (look under Port Forwarding / Virtual Server / NAT) and turn UPnP off. Use Meshnet, WireGuard, or a Cloudflare Tunnel instead.", critical=True)
def c_exposure(F, A):
    mode = A.get("remote_mode")
    ints = {i["domain"] for i in (F.get("integrations") or []) if not i.get("disabled")} | set(F.get("yaml_integrations") or [])
    if mode == "portforward" or A.get("no_port_forward") == "no":
        return FAIL, "You said your router forwards a port to Home Assistant."
    if "upnp" in ints:
        return WARN, "The UPnP integration is on; it can open router ports by itself. Remove it unless you need it."
    ext = F.get("external_url") or ""
    if ext.startswith("http://") and not is_private_host(ext):
        return FAIL, "external_url is a plain http address on the internet: %s" % ext
    if A.get("no_port_forward") == "yes" or mode in ("none", "meshnet", "wireguard", "tailscale", "cloudflare", "nabucasa"):
        return PASS, "No port-forward."
    return MANUAL, "Check your router for port-forwards and tell me (secure-linux-ha-secure --checklist)."


def is_private_host(url):
    try:
        h = urlparse(url).hostname or ""
    except ValueError:
        return True
    if h.endswith((".local", ".home", ".lan", ".internal", ".nord", ".ts.net")) or "." not in h:
        return True
    return is_private_ip(h) if re.fullmatch(r"[0-9.:a-fA-F]+", h) else False


@check("remote-method", "Remote access", 1, "Your way of reaching it from away is a good one",
       "Best to worst for you: 1) NordVPN Meshnet / WireGuard (nothing exposed at all), 2) Cloudflare Tunnel with a Zero Trust login rule (no open port, extra login in front), 3) Nabu Casa (paid, simple, funds Home Assistant). Port-forwarding is never okay.",
       "Set up Meshnet (see the guide chapter 'Reach it from anywhere') and then tell me: secure-linux-ha-secure --checklist.")
def c_remote(F, A):
    mode = A.get("remote_mode")
    if mode is None:
        return MANUAL, "Tell me how you connect from away (checklist)."
    if mode in ("none", "meshnet", "wireguard", "tailscale"):
        return PASS, "Remote access: %s." % mode
    if mode in ("cloudflare", "nabucasa"):
        return PASS, "Remote access: %s (good; add a Zero Trust login rule if Cloudflare)." % mode
    if mode == "portforward":
        return FAIL, "Port-forwarding is the riskiest option."
    return WARN, "Remote access method '%s' isn't one we can vouch for." % mode


@check("https", "Encryption", 3, "Web address uses HTTPS (padlock) wherever it leaves your lounge room",
       "Plain http sends your password in clear text. At home on a wired/trusted LAN that is a small risk; over any remote route it must be HTTPS (VPN, Cloudflare and Nabu Casa all add it).",
       "Put Caddy in front (server kit: server/homeassistant/add-caddy.sh) or use the VPN/Cloudflare/Nabu Casa route. Use https:// in secure-linux-ha's address.")
def c_https(F, A):
    h = F.get("http") or {}
    urls = [u for u in (F.get("external_url"), F.get("internal_url"), A.get("_url")) if u]
    https_any = h.get("ssl") or any(u.startswith("https://") for u in urls)
    mode = A.get("remote_mode")
    if h.get("ssl") or (F.get("http") is None and not urls):
        pass
    ext = F.get("external_url") or ""
    if ext.startswith("http://") and not is_private_host(ext):
        return FAIL, "external_url uses plain http on the internet."
    if https_any:
        return PASS, "HTTPS is set up."
    if mode in ("meshnet", "wireguard", "tailscale", "cloudflare", "nabucasa"):
        return PASS, "Remote route encrypts the traffic. Plain http stays on your home network only."
    if not urls and F.get("http") is None and F["source"] == "api":
        return MANUAL, "Can't tell; give me the address (ha_url)."
    return WARN, "Only plain http on the home network. Okay for LAN-only, but add HTTPS when you can."


@check("proxy-trust", "Encryption", 2, "Reverse-proxy settings are tight (trusted_proxies)",
       "If Caddy/Nginx sits in front, Home Assistant must be told exactly which address to trust, otherwise anyone could fake their address, and the ban list stops working.",
       "In configuration.yaml: http: use_x_forwarded_for: true and trusted_proxies: [127.0.0.1] (or just your proxy's address). Never 0.0.0.0/0.")
def c_proxy(F, A):
    h = F.get("http")
    if h is None:
        return (NA, "Not readable from here.") if F["source"] == "api" else (PASS, "No http: section (default settings).")
    tp = h.get("trusted_proxies") or []
    broad = [p for p in tp if p in ("0.0.0.0/0", "::/0", "0.0.0.0", "::") or re.fullmatch(r"(0|1|2)?\d?\d?\.\d+\.\d+\.\d+/([0-7])", p)]
    if broad:
        return FAIL, "trusted_proxies is too wide: %s" % ", ".join(broad)
    if h.get("use_x_forwarded_for") and not tp:
        return FAIL, "use_x_forwarded_for is on but trusted_proxies is empty (Home Assistant will refuse to start or trust everyone)."
    if tp and not h.get("use_x_forwarded_for"):
        return WARN, "trusted_proxies is set but use_x_forwarded_for is off."
    if h.get("use_x_forwarded_for") and tp:
        return PASS, "Behind a proxy with %d trusted address(es)." % len(tp)
    return PASS, "Not behind a proxy; nothing to trust."


@check("ip-ban", "Login protection", 3, "Too many wrong passwords bans the address",
       "Home Assistant can block an address after a few wrong passwords, but the automatic ban is OFF unless you set a number.",
       "Add to configuration.yaml: http: ip_ban_enabled: true and login_attempts_threshold: 5. (Auto-fix available.)")
def c_ipban(F, A):
    h = F.get("http")
    if h is None:
        return (MANUAL, "Not readable over the API; run a config-folder or SSH check.") if F["source"] == "api" else (FAIL, "No http: section, so the automatic ban is off.")
    if h.get("ip_ban_enabled") is False:
        return FAIL, "ip_ban_enabled is false."
    th = h.get("login_attempts_threshold")
    if not isinstance(th, int) or th <= 0:
        return FAIL, "login_attempts_threshold isn't set, so nobody is ever banned."
    if th > 10:
        return WARN, "login_attempts_threshold is %d; 3 to 5 is better." % th
    return PASS, "Bans after %d wrong passwords." % th


@check("mfa", "Accounts", 3, "Two-step login (authenticator app) on every account",
       "A stolen or guessed password alone can't get in when a 6-digit code from your phone is also needed.",
       "Profile (bottom-left) > Security > Multi-factor Authentication Modules > Enable. Each person does their own; use an authenticator app (Aegis, Ente Auth, 2FAS).")
def c_mfa(F, A):
    us = _users(F)
    if F.get("mfa_known") and us:
        miss = [u["name"] for u in us if not u.get("mfa")]
        if not miss:
            return PASS, "All %d accounts have two-step login." % len(us)
        return FAIL if len(miss) == len(us) else WARN, "No two-step login for: %s." % ", ".join(miss)
    if F["source"] == "api" and F.get("api_user") is not None:
        if not F["api_user"]["mfa"]:
            return WARN, "Your own account (the token's) has no two-step login; other accounts can't be seen from the API."
        if A.get("mfa_all") == "yes":
            return PASS, "You said everyone has it (your own is confirmed)."
        return MANUAL, "Your own account has it; others can't be seen from the API."
    if A.get("mfa_all") == "yes":
        return PASS, "You told us everyone has two-step login."
    if A.get("mfa_all") == "no":
        return FAIL, "You said not everyone has two-step login."
    return MANUAL, "Can't see accounts; answer in the checklist."


@check("admin-separation", "Accounts", 2, "Separate admin and everyday accounts, nobody shares a login",
       "If the family shares one 'admin' login, you can't tell who did what, can't remove one person, and a lost phone is a full break-in. Everyday use needs only a normal (non-admin) user.",
       "Settings > People > Users: make a personal account for each person. Keep ONE admin for you, and use a non-admin account daily.")
def c_admin(F, A):
    us = _users(F)
    if not F.get("users_known") or not us:
        return MANUAL, "Can't see the user list (needs a config folder or an administrator token)."
    admins = [u for u in us if u.get("admin") or u.get("owner")]
    shared = [u["name"] or u.get("username") for u in us if (str(u.get("name") or "").lower() in SHARED_NAMES or str(u.get("username") or "").lower() in SHARED_NAMES) and (u.get("admin") or u.get("owner"))]
    if shared:
        return FAIL, "Looks like a shared admin login: %s." % ", ".join(str(s) for s in shared)
    if len(us) > 1 and len(admins) == len(us):
        return WARN, "Everyone is an administrator (%d of %d). Make daily-use accounts non-admin." % (len(admins), len(us))
    if len(us) == 1:
        return WARN, "Only one account, and it's the admin. Create a second, non-admin account for everyday use."
    return PASS, "%d accounts, %d admin(s)." % (len(us), len(admins))


@check("default-accounts", "Accounts", 3, "No default or weak passwords, no default usernames",
       "'admin', 'homeassistant' or 'test' with a simple password is the first thing a bot tries.",
       "Settings > People > Users: change the username and set a long, unique password (use a password manager).", critical=True)
def c_default(F, A):
    wp = F.get("weak_passwords") or {}
    if wp.get("weak"):
        return FAIL, "A common password works for: %s. Change it now." % ", ".join(wp["weak"])
    us = _users(F)
    bad = [u.get("username") for u in us if str(u.get("username") or "").lower() in DEFAULT_USERNAMES]
    if bad:
        return WARN, "Default-style username(s): %s." % ", ".join(str(b) for b in bad)
    if wp.get("known"):
        return PASS, "No common passwords found and no default usernames."
    if A.get("strong_passwords") == "yes" and (us or not F.get("users_known")):
        return PASS, "You said every account has a long unique password."
    if A.get("strong_passwords") == "no":
        return FAIL, "You said passwords are not long and unique."
    if us:
        return MANUAL, "Usernames look fine, but password strength can't be tested here (python3-bcrypt would let me check against common passwords)."
    return MANUAL, "Can't see accounts."


@check("tokens", "Accounts", 2, "Long-lived access tokens are few, named, recent and used",
       "A long-lived token is a password that never expires and skips two-step login. Old or unused ones are doors left unlocked.",
       "Profile > Security > Long-lived access tokens: delete any you don't recognise or haven't used for 3 months; make new ones when needed (rotate yearly).")
def c_tokens(F, A):
    t = F.get("tokens")
    now = A["_now"]
    if not F.get("tokens_known"):
        if A.get("tokens_reviewed") == "yes":
            return PASS, "You said you reviewed them."
        return MANUAL, "Can't list tokens from here."
    if not t:
        return PASS, "No long-lived tokens."
    old = [x["name"] for x in t if x.get("created") and now - x["created"] > 365 * 86400]
    idle = [x["name"] for x in t if (not x.get("last_used")) or now - x["last_used"] > 90 * 86400]
    if len(t) > 6:
        return WARN, "%d long-lived tokens; that's a lot." % len(t)
    if old or idle:
        return WARN, "Older than a year: %s. Unused for 90+ days: %s." % (", ".join(old) or "none", ", ".join(idle) or "none")
    return PASS, "%d token(s), all recent and in use." % len(t)


@check("addons", "Software", 1, "Only the add-ons you need",
       "Every add-on is another program that can have a security hole, and some (SSH, File editor) are powerful.",
       "Settings > Add-ons: uninstall what you don't use.")
def c_addons(F, A):
    n = A.get("addons_count")
    if n in (None, ""):
        return MANUAL, "Tell me roughly how many add-ons you have (checklist)."
    if n == "na":
        return NA, "No add-ons (Container install)."
    if n.isdigit():
        n = int(n)
        return (PASS if n <= 8 else WARN if n <= 15 else FAIL), "%d add-ons." % n
    return MANUAL, "Unclear answer."


@check("ssh-addon", "Software", 2, "SSH / Terminal add-on is locked down",
       "The SSH add-on is a full command line into the heart of your house. With a password login it can be guessed.",
       "Use key-only login, never expose its port to the internet, and uninstall it when you're not using it.")
def c_ssh(F, A):
    v = A.get("ssh_addon")
    if v is None:
        return MANUAL, "Tell me (checklist)."
    return {"none": (PASS, "No SSH add-on."), "keys": (PASS, "Key-only login."), "password": (FAIL, "Password login for SSH is the risky kind.")}.get(v, (MANUAL, "Unclear answer."))


@check("mqtt-auth", "MQTT", 5, "MQTT broker needs a username and password",
       "An open MQTT broker lets anyone on your network (or the internet, if exposed) read your sensors and switch your devices.",
       "In mosquitto.conf: allow_anonymous false and password_file /mosquitto/config/passwd. The server kit's setup-mosquitto.sh does this.", critical=True)
def c_mqtt_auth(F, A):
    m = F.get("mqtt") or {}
    if not m.get("found"):
        return NA, "No Mosquitto config found."
    if m.get("allow_anonymous"):
        return FAIL, "allow_anonymous is true."
    if not m.get("password_file"):
        return FAIL, "No password_file is set, so nobody can log in (or the broker is open)."
    return PASS, "Anonymous login off, password file set."


@check("mqtt-tls", "MQTT", 2, "MQTT is encrypted (TLS) if it leaves the server",
       "Plain MQTT on port 1883 sends passwords in clear text across the network.",
       "Keep 1883 on localhost / the Docker network only, or add a TLS listener on 8883 with a certificate.")
def c_mqtt_tls(F, A):
    m = F.get("mqtt") or {}
    if not m.get("found"):
        return NA, "No Mosquitto config found."
    ls = m.get("listeners") or []
    plain_open = [l for l in ls if not l.get("tls") and l.get("bind") not in ("127.0.0.1", "localhost", "::1")]
    srv = F.get("server") or {}
    if m.get("tls") and not plain_open:
        return PASS, "TLS listener only."
    if not plain_open:
        return PASS, "Plain MQTT only on localhost."
    # in a container the broker listens on all of ITS addresses; what matters is where Docker publishes port 1883
    mq = [c for c in (srv.get("containers") or []) if "mosquitto" in c.get("name", "") or "mosquitto" in c.get("image", "")]
    pub = [p for c in mq for p in c.get("ports", []) if p.get("port") == "1883"]
    if mq and all(p.get("ip") in ("127.0.0.1", "::1") for p in pub):
        return PASS, "Plain MQTT is only reachable from the server itself (Docker publishes it on 127.0.0.1)."
    if m.get("tls"):
        return WARN, "A TLS listener exists but plain MQTT is also open on the network."
    return WARN, "Plain MQTT on port(s) %s is open to the network. Fine inside a private Docker network; otherwise add TLS." % ", ".join(str(l["port"]) for l in plain_open)


@check("mqtt-acl", "MQTT", 1, "MQTT users are limited to their own topics (ACLs)",
       "With an ACL file, a hacked gadget can only touch its own topics, not everything.",
       "Add acl_file /mosquitto/config/acl to mosquitto.conf (the kit writes a starter ACL).")
def c_mqtt_acl(F, A):
    m = F.get("mqtt") or {}
    if not m.get("found"):
        return NA, "No Mosquitto config found."
    return (PASS, "ACL file set.") if m.get("acl_file") else (WARN, "No acl_file.")


@check("secrets-yaml", "Secrets", 3, "No passwords or keys written directly in your YAML or dashboards",
       "Anything typed into YAML ends up in backups, screenshots, forum posts and Git. A secrets.yaml file keeps them in one place that is never shared.",
       "Put each secret in secrets.yaml and write 'password: !secret my_password' instead. (Auto-fix available.)")
def c_secrets(F, A):
    s = F.get("inline_secrets")
    if s is None:
        return MANUAL, "Can't read your files from here (use a config-folder or SSH check)."
    if not s:
        return PASS, "No inline secrets found."
    files = sorted({x["file"] for x in s})
    return FAIL, "%d secret(s) typed straight into: %s." % (len(s), ", ".join(files))


@check("secrets-git", "Secrets", 3, "Git (version history) never contains secrets",
       "If you keep your config in Git (a great idea), secrets.yaml and .storage must be ignored or your passwords are in the history forever.",
       "Add secrets.yaml, .storage/, *.db* and *.log* to .gitignore. (Auto-fix available.)")
def c_secrets_git(F, A):
    g = F.get("git")
    if g is None:
        return MANUAL, "Can't read your folder from here."
    if not g["present"]:
        return PASS, "Not using Git (nothing to leak). Using Git is recommended: see 'config-in-git'."
    if g.get("tracked_secrets"):
        return FAIL, "secrets.yaml or .storage is tracked by Git."
    if not g.get("secrets_ignored"):
        return FAIL, "secrets.yaml isn't in .gitignore."
    if not g.get("storage_ignored"):
        return WARN, ".storage isn't in .gitignore (it holds login data)."
    return PASS, "Ignored."


@check("config-in-git", "Safety net", 1, "Your config is tracked in Git so any change can be undone",
       "A history of every change means a mistake is a 10-second undo (secure-linux-ha rollback) instead of an evening lost.",
       "Run: secure-linux-ha snapshot (it sets this up). (Auto-fix available.)")
def c_git(F, A):
    g = F.get("git")
    if g is None:
        return MANUAL, "Can't read your folder from here."
    return (PASS, "Git history is on.") if g["present"] else (WARN, "No Git history yet.")


def _age_days(F, A):
    b = F.get("backups") or {}
    if not b.get("known") or b.get("newest") is None:
        return None
    return (A["_now"] - b["newest"]) / 86400.0


@check("backup-age", "Backups", 3, "A recent Home Assistant backup exists",
       "If the SD card or disk dies, a fresh backup is the difference between ten minutes and starting again.",
       "Settings > System > Backups: turn on automatic daily backups, keep 7+. Our 'backup-failed' alert package tells you if one fails.")
def c_backup_age(F, A):
    b = F.get("backups") or {}
    if not b.get("known"):
        return MANUAL, "Can't see backups from here."
    age = _age_days(F, A)
    if age is None:
        return FAIL, "No backups at all."
    if age <= 2:
        return PASS, "Newest backup is %.1f days old." % age
    return (WARN if age <= 7 else FAIL), "Newest backup is %.0f days old." % age


@check("backup-encrypted", "Backups", 2, "Backups are encrypted",
       "A backup holds your logins, location history and keys. Unencrypted, anyone who gets the file gets everything.",
       "Settings > System > Backups > Automatic backups: keep encryption on and save the emergency kit (key) in Bitwarden.")
def c_backup_enc(F, A):
    b = F.get("backups") or {}
    if not b.get("known") or b.get("count", 0) == 0:
        return MANUAL, "No backups to look at."
    p = b.get("all_protected")
    if p is None:
        return MANUAL, "Can't tell if the backups are encrypted."
    return (PASS, "All backups are encrypted.") if p else (FAIL, "Some backups are not encrypted.")


@check("backup-offsite", "Backups", 3, "An encrypted copy lives outside your house",
       "Fire, flood and burglars take the server and the backup next to it.",
       "Use the server kit's borgmatic hook with a cloud copy (rclone), or Nabu Casa cloud backup, or copy to a relative's NAS.")
def c_offsite(F, A):
    v = A.get("offsite_backup")
    if v is None:
        return MANUAL, "Tell me (checklist)."
    return (PASS, "Off-site copy exists.") if v == "yes" else (FAIL, "No off-site copy.")


@check("backup-restore-tested", "Backups", 2, "You have tested restoring a backup recently",
       "Many people find their backup is empty or the key is lost only on the day they need it.",
       "Restore into a spare copy (see guide: 'Safe testing in a copy'). Then: secure-linux-ha-secure attest restore_tested YYYY-MM-DD.")
def c_restore(F, A):
    v = A.get("restore_tested")
    if v is None:
        return MANUAL, "Tell me (checklist)."
    if v == "no":
        return FAIL, "Never tested."
    t = iso_to_epoch(v + "T00:00:00") if re.fullmatch(r"\d{4}-\d{2}-\d{2}", v) else None
    if t is None:
        return MANUAL, "Unclear date."
    days = (A["_now"] - t) / 86400.0
    return (PASS if days <= 183 else WARN if days <= 365 else FAIL), "Last test %.0f days ago." % days


def ver_tuple(v):
    m = re.match(r"(\d+)\.(\d+)(?:\.(\d+))?", str(v or ""))
    return tuple(int(x or 0) for x in m.groups()) if m else None


@check("updates", "Updates", 3, "Home Assistant is up to date",
       "Security fixes only help once you install them. Home Assistant ships a release monthly (CalVer: 2026.11).",
       "Run secure-linux-ha update-check, make a backup, read the release notes, then update (server/homeassistant/safe-update.sh does the backup first).")
def c_updates(F, A):
    inst = F.get("ha_version")
    up = F.get("update") or {}
    latest = up.get("latest") or A.get("_latest")
    inst = up.get("installed") or inst
    if not inst:
        return MANUAL, "Can't tell the version."
    a, b = ver_tuple(inst), ver_tuple(latest)
    if not b:
        return MANUAL, "Running %s; I can't tell the newest version without internet (secure-linux-ha update-check)." % inst
    months = (b[0] - a[0]) * 12 + (b[1] - a[1])
    if months <= 0:
        return PASS, ("%s is current." % inst) if a == b else "%s (a small patch update to %s is out; install it when convenient)." % (inst, latest)
    if months == 1:
        return PASS, "%s (one release behind; fine for a few weeks)." % inst
    return (WARN if months <= 3 else FAIL), "%s is %d releases behind %s." % (inst, months, latest)


@check("update-routine", "Updates", 1, "You have a monthly update habit",
       "A routine beats remembering: read the release notes, back up, update.",
       "Pick a day (say the first Sunday). Use the 'update digest' package to get a weekly note.")
def c_routine(F, A):
    v = A.get("update_routine")
    return (MANUAL, "Tell me (checklist).") if v is None else ((PASS, "You have a routine.") if v == "yes" else (WARN, "No routine yet."))


@check("integrations-cloud", "Privacy", 1, "Unneeded integrations and cloud links are off",
       "Each cloud link is a company that can be breached or switched off; each unused integration is more code running.",
       "Settings > Devices & Services: delete integrations you don't use; prefer local ones (Zigbee, Matter, ESPHome) over cloud ones.")
def c_cloud(F, A):
    if not F.get("integrations_known"):
        return MANUAL, "Can't list integrations from here."
    on = sorted({i["domain"] for i in F["integrations"] if not i.get("disabled")})
    cloud = [d for d in on if d in CLOUD_DOMAINS]
    if len(cloud) >= 5:
        return WARN, "%d cloud integrations: %s." % (len(cloud), ", ".join(cloud))
    if len(on) > 40:
        return WARN, "%d integrations active; prune the ones you don't use." % len(on)
    return PASS, "%d integrations, %d cloud." % (len(on), len(cloud))


@check("webhooks", "Privacy", 2, "Webhook addresses are long and random",
       "A webhook is a web address that triggers an automation with no login. If it's guessable, anyone can trigger it.",
       "Use a random id of 24+ characters (secure-linux-ha-learn explains how) and never publish it.")
def c_webhooks(F, A):
    w = F.get("webhook_ids_weak")
    if w is None:
        return MANUAL, "Can't read your automations from here."
    return (PASS, "No short or guessable webhook ids.") if not w else (FAIL, "Short or guessable webhook id(s): %s." % ", ".join(w[:5]))


@check("login-alerts", "Detection", 2, "You get a phone alert when someone fails to log in",
       "You want to hear about a password-guessing attempt in minutes, not months.",
       "Install the security-watch package: secure-linux-ha starter install sl_security_watch (and set your phone in helper 'Notify service'). (Auto-fix available.)")
def c_alerts(F, A):
    v = F.get("login_alert_automation")
    srv = F.get("server") or {}
    if v:
        return PASS, "A login-failure alert automation exists."
    if (srv.get("host") or {}).get("fail2ban"):
        return PASS, "fail2ban watches logins on the server."
    if v is None:
        return MANUAL, "Can't read your automations from here."
    return FAIL, "No alert for failed logins."


@check("failed-logins", "Detection", 2, "No recent failed logins from outside your home",
       "Failed logins from internet addresses mean something is exposed or someone is trying.",
       "Check where they came from (home-assistant.log). Block the route in; change passwords; turn two-step login on.")
def c_failed(F, A):
    f = F.get("failed_logins") or {}
    if not f.get("known"):
        return MANUAL, "No log to read."
    if f.get("external"):
        return FAIL, "%d failed login(s) from outside addresses (%s)." % (f["count"], ", ".join(i for i in f["ips"] if not is_private_ip(i))[:80])
    if f.get("count", 0) >= 10:
        return WARN, "%d failed logins from inside your network." % f["count"]
    return PASS, "%d failed logins in the log (none from outside)." % f.get("count", 0)


@check("iot-vlan", "Network", 2, "Smart-home gadgets are on their own network (VLAN)",
       "Cheap gadgets are rarely updated. On a separate network, a hacked one can't see your laptop, phone or photos.",
       "Use your router's guest/IoT network or a VLAN (guide: 'VLAN and IoT segmentation'), allow only Home Assistant to reach the IoT side.")
def c_vlan(F, A):
    v = A.get("iot_vlan")
    return (MANUAL, "Tell me (checklist).") if v is None else {"yes": (PASS, "Separate IoT network."), "no": (WARN, "Gadgets share your main network."), "na": (NA, "Not using any.")}.get(v, (MANUAL, "Unclear answer."))


@check("cloud-blocked", "Network", 1, "Local-only gadgets are blocked from the internet",
       "A plug or camera that works locally has no need to phone a server abroad.",
       "Router: block internet for the IoT VLAN except what needs it (NTP, firmware). Use a firewall rule per device.")
def c_cloudblock(F, A):
    v = A.get("iot_cloud_blocked")
    return (MANUAL, "Tell me (checklist).") if v is None else {"yes": (PASS, "Blocked."), "no": (WARN, "Not blocked."), "na": (NA, "N/A")}.get(v, (MANUAL, "Unclear answer."))


@check("wifi-isolation", "Network", 1, "IoT Wi-Fi has client isolation on",
       "Gadgets shouldn't talk to each other, only to Home Assistant.",
       "Router Wi-Fi settings: enable 'AP isolation' / 'client isolation' on the IoT SSID (note: mDNS discovery then needs a helper).")
def c_isolation(F, A):
    v = A.get("wifi_isolation")
    return (MANUAL, "Tell me (checklist).") if v is None else {"yes": (PASS, "On."), "no": (WARN, "Off."), "na": (NA, "N/A")}.get(v, (MANUAL, "Unclear answer."))


@check("cameras", "Network", 2, "Cameras are local-only and passwords aren't in URLs",
       "Cameras are the most-attacked smart-home gadget; cloud/P2P/UPnP cameras open doors without asking.",
       "Use a local RTSP stream, a strong camera password stored in secrets.yaml, no UPnP, no P2P, and block the camera from the internet.")
def c_cameras(F, A):
    inline = [x for x in (F.get("inline_secrets") or []) if x.get("kind") == "url"]
    if inline:
        return FAIL, "A camera/stream URL has a password inside it (%s)." % ", ".join(sorted({x['file'] for x in inline})[:3])
    v = A.get("cameras_local")
    if v == "na":
        return NA, "No cameras."
    if v == "yes":
        return PASS, "Local-only (you said)."
    if v == "no":
        return WARN, "Cameras use cloud/UPnP/P2P."
    return MANUAL, "Tell me (checklist)."


@check("zigbee-key", "Network", 2, "Zigbee network key is not the default",
       "Everyone's Zigbee gadgets share the same well-known default key unless you change it; with it, a nearby attacker can read and control the network.",
       "Zigbee2MQTT: advanced: network_key: GENERATE (do this BEFORE pairing; changing later means re-pairing). ZHA already uses a random key.")
def c_zigbee(F, A):
    z = F.get("z2m") or {}
    if z.get("found"):
        if z["network_key"] == "default":
            return FAIL, "Zigbee2MQTT is using the default network key."
        if z.get("permit_join"):
            return WARN, "permit_join is true (anyone can pair a device); turn it off."
        if z["network_key"] in ("generate", "custom"):
            return PASS, "Custom/generated Zigbee key."
    v = A.get("zigbee_key")
    if v == "na":
        return NA, "No Zigbee."
    if v == "changed":
        return PASS, "You said the key was changed."
    if v == "default":
        return FAIL, "Default Zigbee key."
    return MANUAL, "No Zigbee2MQTT config found; tell me if you use Zigbee (checklist)."


@check("host-patching", "Server", 2, "The server's operating system updates itself",
       "Home Assistant can be perfect and still lose to an old kernel, Docker or SSH bug.",
       "Fedora: sudo dnf install dnf-automatic && sudo systemctl enable --now dnf-automatic-install.timer. Debian/Ubuntu: sudo apt install unattended-upgrades.")
def c_patch(F, A):
    h = (F.get("server") or {}).get("host") or {}
    if h.get("auto_updates") is True:
        return PASS, "Automatic updates are on."
    if h.get("auto_updates") is False:      # what we SAW beats what you told us
        who = "You said yes, but I" if A.get("host_autoupdates") == "yes" else "I"
        return WARN, "No automatic security updates found on the server. %s looked for the dnf-automatic and unattended-upgrades timers." % who
    v = A.get("host_autoupdates")
    if v == "yes":
        return PASS, "You said automatic updates are on."
    if v == "na":
        return NA, "Home Assistant OS updates itself through its own Updates page."
    if h.get("auto_updates") is False or v == "no":
        return WARN, "No automatic security updates found."
    return MANUAL, "Run the SSH check or tell me (checklist)."


@check("containers", "Server", 2, "Containers are locked down (not privileged, no Docker socket, non-root where possible)",
       "A container with the Docker socket or --privileged is the same as root on the server; one bug and the whole server is gone.",
       "Remove 'privileged' unless Bluetooth needs it; never mount /var/run/docker.sock; use cap_drop: [ALL], read_only: true and a non-root user for Mosquitto, Zigbee2MQTT, Node-RED.")
def c_containers(F, A):
    cs = (F.get("server") or {}).get("containers")
    if cs is None:
        v = A.get("rootless_containers")
        if v == "yes":
            return PASS, "Rootless (you said)."
        if v == "no":
            return WARN, "Containers run as root."
        return MANUAL, "Run the SSH check to look at the containers."
    if not cs:
        return NA, "No containers running."
    sock = [c["name"] for c in cs if c.get("docker_sock")]
    if sock:
        return FAIL, "Docker socket is mounted into: %s." % ", ".join(sock)
    priv = [c["name"] for c in cs if c.get("privileged") and "home-assistant" not in c.get("image", "")]
    ha_priv = [c["name"] for c in cs if c.get("privileged") and "home-assistant" in c.get("image", "")]
    if priv:
        return WARN, "Privileged: %s." % ", ".join(priv)
    root = [c["name"] for c in cs if not c.get("user") and "home-assistant" not in c.get("image", "") and not c.get("read_only")]
    if ha_priv or root:
        return WARN, "%s%s" % (("Home Assistant runs privileged (only needed for Bluetooth). " if ha_priv else ""),
                               ("Helper containers running as root without read-only: %s." % ", ".join(root) if root else ""))
    return PASS, "%d containers, none privileged, no Docker socket." % len(cs)


@check("firewall", "Server", 2, "The server has a firewall switched on",
       "A firewall means a service you forgot about isn't automatically open to the whole network.",
       "Fedora: sudo systemctl enable --now firewalld, then allow only https and 8123 from your LAN (server/homeassistant/firewall-lan-only.sh).")
def c_firewall(F, A):
    fw = (F.get("server") or {}).get("firewall") or {}
    if not fw.get("known"):
        return MANUAL, "Run the SSH check."
    return (PASS, "Firewall (%s) is on." % fw["kind"]) if fw.get("active") else (FAIL, "No firewall running.")


SAFE_PORTS = {22, 443, 8123, 53, 5353, 80}


@check("open-ports", "Server", 2, "Only 443 / 8123 (and SSH) are reachable on the server",
       "MQTT, Node-RED, ESPHome, Zigbee2MQTT and Matter each have a web or network port. If they listen on every address, any device on your network can try them.",
       "Bind helper services to 127.0.0.1 (ports: '127.0.0.1:1880:1880') and reach them through Caddy with a login, or through SSH.")
def c_ports(F, A):
    ls = (F.get("server") or {}).get("listening")
    if ls is None:
        return MANUAL, "Run the SSH check."
    odd = sorted({p["port"] for p in ls if p["bind"] in ("*", "0.0.0.0", "::", "") and p["port"] not in SAFE_PORTS and p["port"] < 32768})
    if not odd:
        return PASS, "Nothing unexpected is listening."
    return WARN, "Open to the network: %s." % ", ".join(str(p) for p in odd)


@check("physical", "Server", 1, "The server is physically safe",
       "Anyone with a keyboard and screen on the server can read everything.",
       "Put it in a place visitors can't reach; encrypt its disk if you can; lock BIOS/UEFI settings.")
def c_physical(F, A):
    v = A.get("physical_secure")
    return (MANUAL, "Tell me (checklist).") if v is None else ((PASS, "Yes.") if v == "yes" else (WARN, "Easy for visitors to reach."))


@check("log-review", "Detection", 1, "You glance at the logs and login history now and then",
       "Spotting an odd login or a failing device early is far easier than untangling it months later.",
       "Once a month: Settings > System > Logs, and Profile > Security (refresh tokens). Ask secure-linux-ha-secure --report.")
def c_logreview(F, A):
    v = A.get("log_review")
    return (MANUAL, "Tell me (checklist).") if v is None else ((PASS, "Yes.") if v == "yes" else (WARN, "Not yet."))


@check("debug-logging", "Safety net", 1, "Debug logging isn't left switched on",
       "Debug logs can record tokens, addresses and message contents, fill the disk, and slow Home Assistant down.",
       "In configuration.yaml: logger: default: warning, and remove 'debug' lines when you finish troubleshooting.")
def c_debug(F, A):
    d = F.get("debug_logging")
    if d is None:
        return NA, "Not readable from here."
    return (WARN, "Debug logging is switched on in the logger settings.") if d else (PASS, "Logging is at a normal level.")


RISKY_YAML = ("shell_command", "python_script", "command_line", "pyscript")


@check("risky-integrations", "Software", 2, "Powerful 'run a command' features are only there if you need them",
       "shell_command, command_line and python_script let an automation run programs on the server. Fine if you wrote them; dangerous if a webhook or a message can feed them text.",
       "Remove them if unused. If you keep them, never put {{ trigger... }} or webhook data inside the command, and keep the webhook ids long and secret.")
def c_risky(F, A):
    if not F.get("yaml_integrations") and F["source"] == "api":
        return NA, "Not readable from here."
    on = sorted(set(F.get("yaml_integrations") or []) & set(RISKY_YAML))
    if not on:
        return PASS, "None of the run-a-command features are configured."
    return WARN, "Configured: %s." % ", ".join(on)


@check("cors", "Login protection", 3, "No wildcard (*) in cors_allowed_origins",
       "A wildcard lets any website your browser visits talk to Home Assistant as you.",
       "List only the exact origins you need (https://ha.home).", critical=True)
def c_cors(F, A):
    h = F.get("http")
    if h is None:
        return NA, "Not readable from here."
    return (FAIL, "cors_allowed_origins contains *.") if any(o.strip() in ("*", "'*'") for o in h.get("cors") or []) else (PASS, "No wildcard.")


@check("trusted-networks", "Login protection", 5, "No 'trusted networks' login bypass",
       "The trusted_networks login provider with allow_bypass_login lets any device on the listed network in with NO password.",
       "Remove the trusted_networks auth provider from configuration.yaml (homeassistant: auth_providers:).", critical=True)
def c_trusted(F, A):
    bad = [p for p in F.get("auth_providers") or [] if p.get("type") == "trusted_networks"]
    if not bad:
        return PASS, "No trusted-network bypass."
    wide = [n for p in bad for n in p["networks"] if n in ("0.0.0.0/0", "::/0") or re.fullmatch(r"\d+\.\d+\.\d+\.\d+/([0-9]|1[0-5])", n)]
    if wide or any(p["allow_bypass_login"] for p in bad):
        return FAIL, "trusted_networks lets devices in without a password."
    return WARN, "trusted_networks is set up (needs a login still, but remove it if you can)."


@check("file-permissions", "Server", 2, "Config files aren't readable by other users on the computer",
       "secrets.yaml and .storage hold keys and logins. On a shared computer, 'world-readable' means every account can read them.",
       "chmod 600 secrets.yaml; chmod -R o-rwx on the config folder. (Auto-fix available.)")
def c_perms(F, A):
    sf, pm = F.get("secrets_file"), F.get("perms")
    if sf is None or pm is None:
        return MANUAL, "Can't see file permissions from here."
    bad = []
    if sf.get("mode") is not None and sf["mode"] & 0o007:
        bad.append("secrets.yaml (mode %o)" % sf["mode"])
    if pm.get("storage") is not None and pm["storage"] & 0o007:
        bad.append(".storage (mode %o)" % pm["storage"])
    if pm.get("config_dir") is not None and pm["config_dir"] & 0o007:
        bad.append("the config folder (mode %o)" % pm["config_dir"])
    return (PASS, "Permissions are tight.") if not bad else (WARN, "Readable by everyone: %s." % ", ".join(bad))


@check("cert-expiry", "Encryption", 2, "HTTPS certificate isn't about to expire",
       "An expired certificate stops the phone app and browsers connecting, often at the worst time.",
       "Caddy renews its own. Add the 'Certificate Expiry' integration and use the cert-expiry alert package.")
def c_cert(F, A):
    d = F.get("cert_days_left")
    if d is None:
        return NA, "No certificate to check."
    return (PASS if d > 30 else WARN if d > 14 else FAIL), "%d days left." % d


@check("yaml-valid", "Safety net", 1, "Your YAML files have no mistakes that could stop Home Assistant starting",
       "One wrong indent can stop Home Assistant starting after the next restart.",
       "Run: secure-linux-ha validate  (checks the files before you restart).")
def c_yaml(F, A):
    if "yaml_ok" not in F:
        return NA, "Not checked from here."
    return (PASS, "No YAML problems.") if F["yaml_ok"] else (WARN, "; ".join(F["yaml_issues"][:3]))


# ============================================================================================================
# 6. SCORING (deterministic)
# ============================================================================================================
def evaluate(F, A, now):
    A = dict(A)
    A["_now"] = float(now)
    results = []
    for cid, cat, weight, critical, fn in CHECKS:
        try:
            status, detail = fn(F, A)
        except Exception as e:      # a bug in one check must never hide the others
            status, detail = MANUAL, "internal error (%s)" % type(e).__name__
        title, why, fix = TEXT[cid]
        results.append({"id": cid, "category": cat, "weight": weight, "critical": critical, "status": status,
                        "detail": detail, "title": title, "why": why, "fix": fix, "autofix": cid in AUTOFIX_IDS})
    return results


AUTOFIX_IDS = {"ip-ban", "file-permissions", "secrets-yaml", "secrets-git", "config-in-git", "login-alerts"}


def summarise(results):
    earned = possible = known_w = total_w = 0.0
    counts = {PASS: 0, WARN: 0, FAIL: 0, MANUAL: 0, NA: 0}
    crit_fail = []
    for r in results:
        counts[r["status"]] += 1
        if r["status"] != NA:
            total_w += r["weight"]
        if r["status"] in POINTS:
            earned += r["weight"] * POINTS[r["status"]]
            possible += r["weight"]
            known_w += r["weight"]
            if r["critical"] and r["status"] == FAIL:
                crit_fail.append(r["id"])
    score = round(100.0 * earned / possible) if possible else 0
    coverage = round(100.0 * known_w / total_w) if total_w else 0
    grade = "A" if score >= 90 else "B" if score >= 80 else "C" if score >= 65 else "D" if score >= 50 else "F"
    capped = False
    if crit_fail and grade in ("A", "B", "C"):
        grade, capped = "D", True
    if coverage < 35:
        grade = "?"
    return {"score": score, "grade": grade, "coverage": coverage, "counts": counts, "critical_fails": crit_fail, "capped": capped}


def render_text(results, summ, F, plain=True):
    out = []
    g = summ["grade"]
    out.append("Home Assistant security check (%s)" % {"config": "config folder", "ssh": "over SSH", "api": "through Home Assistant's API"}[F["source"]])
    out.append("=" * 62)
    if g == "?":
        out.append("Grade: ?   We could only check %d%% of the list, which isn't enough for a grade." % summ["coverage"])
        out.append("       Add --ssh user@server, --config /path, or --api, and answer --checklist.")
    else:
        out.append("Grade: %s   Score: %d/100   (checked %d%% of the list)" % (g, summ["score"], summ["coverage"]))
        if summ["capped"]:
            out.append("       The grade is held at D because of a serious problem: %s" % ", ".join(summ["critical_fails"]))
    c = summ["counts"]
    out.append("%d good, %d could be better, %d need fixing, %d need your answer, %d don't apply" % (c[PASS], c[WARN], c[FAIL], c[MANUAL], c[NA]))
    for label, st in (("NEEDS FIXING", FAIL), ("COULD BE BETTER", WARN), ("I NEED YOUR ANSWER", MANUAL), ("GOOD", PASS)):
        rows = [r for r in results if r["status"] == st]
        if not rows:
            continue
        out.append("")
        out.append("%s (%d)" % (label, len(rows)))
        out.append("-" * 62)
        for r in rows:
            out.append("[%s] %s%s" % (r["id"], r["title"], "  (auto-fix available)" if r["autofix"] and st in (FAIL, WARN) else ""))
            out.append("    Found: %s" % r["detail"])
            if st in (FAIL, WARN):
                out.append("    Why it matters: %s" % r["why"])
                out.append("    How to fix: %s" % r["fix"])
            elif st == MANUAL:
                out.append("    How to answer: secure-linux-ha-secure --checklist")
    out.append("")
    out.append("Nothing was changed. To fix the safe ones automatically: secure-linux-ha-secure --apply --config <folder>")
    return "\n".join(out)


def render_markdown(results, summ, F, when):
    out = ["# Home Assistant security report", "", "Date: %s  " % when, "Source: %s  " % F["source"],
           "Grade: **%s**, score %d/100, checked %d%% of the list" % (summ["grade"], summ["score"], summ["coverage"]), "",
           "No passwords or tokens are in this report.", ""]
    for label, st in (("Needs fixing", FAIL), ("Could be better", WARN), ("Needs your answer", MANUAL), ("Good", PASS), ("Does not apply", NA)):
        rows = [r for r in results if r["status"] == st]
        if rows:
            out.append("## %s (%d)" % (label, len(rows)))
            for r in rows:
                out.append("- **%s** (`%s`): %s" % (r["title"], r["id"], r["detail"]))
                if st in (FAIL, WARN):
                    out.append("  - Why: %s" % r["why"])
                    out.append("  - Fix: %s" % r["fix"])
            out.append("")
    return "\n".join(out)


# ============================================================================================================
# 7. SAFE AUTO-FIXES (preview, ask, snapshot, apply, validate, undo on failure)
# ============================================================================================================
GITIGNORE_LINES = ["secrets.yaml", ".storage/", "*.db", "*.db-shm", "*.db-wal", "*.log", "*.log.*", ".cloud/", "deps/", "tts/", "backups/", "__pycache__/", "ip_bans.yaml", ".uuid"]


def _unified(path, old, new):
    import difflib
    return "".join(difflib.unified_diff(old.splitlines(True), new.splitlines(True), "a/" + path, "b/" + path))


def set_block_keys(text, block, keys):
    """Text-level edit: make sure `block:` (top-level) contains key: value for each in keys, keeping comments and
    everything else untouched. Returns new text, or None if the block can't be edited safely."""
    lines = text.splitlines(True)
    hdr = None
    for i, l in enumerate(lines):
        if re.match(r"^%s:\s*(#.*)?$" % re.escape(block), l):
            hdr = i
            break
        if re.match(r"^%s:\s*\S" % re.escape(block), l):
            return None                      # flow style or !include: leave to the human
    if hdr is None:
        add = ("\n" if text and not text.endswith("\n") else "") + "\n# Added by Secure Linux (secure-linux-ha-secure --apply)\n%s:\n" % block
        add += "".join("  %s: %s\n" % (k, v) for k, v in keys.items())
        return text + add
    end = hdr + 1
    indent = None
    while end < len(lines) and (lines[end].strip() == "" or lines[end].startswith((" ", "\t"))):
        m = re.match(r"^(\s+)[^\s#]", lines[end])
        if m and indent is None:
            indent = len(m.group(1))          # the indent of the first real line below the header
        end += 1
    pad = " " * (indent or 2)
    body = lines[hdr + 1:end]
    for k, v in keys.items():
        pat = re.compile(r"^%s%s:\s*.*$" % (pad, re.escape(k)))
        for j, l in enumerate(body):
            if pat.match(l.rstrip("\n")):
                body[j] = "%s%s: %s\n" % (pad, k, v)
                break
        else:
            body.insert(0, "%s%s: %s\n" % (pad, k, v))
    return "".join(lines[:hdr + 1] + body + lines[end:])


def ensure_packages_text(text):
    """Make configuration.yaml load packages from the 'packages' folder (if it doesn't already)."""
    if re.search(r"^\s+packages:\s*", text, re.M):
        return text if re.search(r"^\s+packages:\s*!include_dir_(named|merge_named)\s+\S+", text, re.M) else None
    if re.search(r"^homeassistant:\s*(#.*)?$", text, re.M):
        return re.sub(r"^(homeassistant:\s*(#.*)?)$", r"\1\n  packages: !include_dir_named packages", text, count=1, flags=re.M)
    if re.search(r"^homeassistant:\s*\S", text, re.M):
        return None
    return text + ("\n" if text and not text.endswith("\n") else "") + "\n# Added by Secure Linux: lets you drop ready-made packages into the 'packages' folder\nhomeassistant:\n  packages: !include_dir_named packages\n"


def packages_dir(root, text):
    m = re.search(r"packages:\s*!include_dir_(?:named|merge_named)\s+(\S+)", text)
    return Path(root) / (m.group(1) if m else "packages")


def plan_fixes(root, results, starter_dir):
    """Return a list of fixes: {'id','what','changes':[('write'|'chmod'|'git', path, old, new)]}. Nothing is written."""
    root = Path(root)
    by = {r["id"]: r for r in results}
    plan = []
    cfg_path = root / "configuration.yaml"
    cfg_text = cfg_path.read_text(encoding="utf-8", errors="replace") if cfg_path.is_file() else ""

    # --- secrets.yaml hygiene: move inline secrets
    if by.get("secrets-yaml", {}).get("status") == FAIL:
        sf = root / "secrets.yaml"
        old_secrets = sf.read_text(encoding="utf-8", errors="replace") if sf.is_file() else ""
        existing = set(re.findall(r"^([A-Za-z0-9_]+):", old_secrets, re.M))
        new_secrets, changes = old_secrets, []
        for p in _yaml_files(root):
            try:
                old = p.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            out, touched = [], False
            for n, line in enumerate(old.splitlines(True), 1):
                m = INLINE_RE.match(line.rstrip("\n"))
                if m and not line.lstrip().startswith("#"):
                    raw = re.sub(r"\s+#.*$", "", m.group(3)).strip()
                    val = raw.strip("'\"")
                    if val and not val.startswith(("!", "{{", "{%", "|", ">", "&", "*", "[")) and val.lower() not in ("null", "none", "~", "true", "false"):
                        name = re.sub(r"[^a-z0-9_]", "_", ("%s_%s" % (p.stem, m.group(2))).lower())
                        base, i = name, 2
                        while name in existing:
                            name = "%s_%d" % (base, i)
                            i += 1
                        existing.add(name)
                        esc = val.replace("\\", "\\\\").replace('"', '\\"')
                        new_secrets += ("" if new_secrets.endswith("\n") or not new_secrets else "\n") + '%s: "%s"\n' % (name, esc)
                        out.append("%s%s: !secret %s\n" % (m.group(1), m.group(2), name))
                        touched = True
                        continue
                out.append(line)
            if touched:
                changes.append(("write", p, old, "".join(out)))
        if changes:
            changes.append(("write_secret", sf, old_secrets, new_secrets))
            plan.append({"id": "secrets-yaml", "what": "Move typed-in passwords/keys into secrets.yaml (replaced by !secret references)", "changes": changes})

    # --- http: ip ban
    if by.get("ip-ban", {}).get("status") == FAIL and cfg_text:
        target, text = cfg_path, cfg_text
        m = re.search(r"^http:\s*!include\s+(\S+)", cfg_text, re.M)
        if m:
            target = (root / m.group(1)).resolve()
            try:
                target.relative_to(root.resolve())
                text = target.read_text(encoding="utf-8", errors="replace")
                new = text if re.search(r"^ip_ban_enabled:", text, re.M) else text
                lines = text
                for k, v in (("ip_ban_enabled", "true"), ("login_attempts_threshold", "5")):
                    if re.search(r"^%s:" % k, lines, re.M):
                        lines = re.sub(r"^%s:.*$" % k, "%s: %s" % (k, v), lines, flags=re.M)
                    else:
                        lines += ("" if lines.endswith("\n") or not lines else "\n") + "%s: %s\n" % (k, v)
                new = lines
            except (ValueError, OSError):
                new = None
        else:
            new = set_block_keys(text, "http", {"ip_ban_enabled": "true", "login_attempts_threshold": "5"})
        if new is not None and new != text:
            plan.append({"id": "ip-ban", "what": "Turn on automatic banning after 5 wrong passwords (http: ip_ban_enabled, login_attempts_threshold)",
                         "changes": [("write", target, text, new)]})

    # --- login alerts package
    if by.get("login-alerts", {}).get("status") == FAIL and cfg_text:
        newcfg = ensure_packages_text(cfg_text)
        pk = packages_dir(root, newcfg if newcfg else cfg_text)
        ch = []
        if newcfg is not None and newcfg != cfg_text:
            ch.append(("write", cfg_path, cfg_text, newcfg))
        if newcfg is not None:
            for name in ("sl_helpers.yaml", "sl_security_watch.yaml"):
                src = Path(starter_dir) / "packages" / name
                dst = pk / name
                if src.is_file() and not dst.exists():
                    ch.append(("write", dst, "", src.read_text(encoding="utf-8")))
            if ch:
                plan.append({"id": "login-alerts", "what": "Install the 'security watch' package: a phone alert when someone fails to log in", "changes": ch})

    # --- permissions
    if by.get("file-permissions", {}).get("status") == WARN:
        ch = []
        sf = root / "secrets.yaml"
        if sf.is_file() and (test_mode(sf, root) or 0) & 0o007:
            ch.append(("chmod", sf, "%o" % (test_mode(sf, root) or 0), "600"))
        for d in (root, root / ".storage"):
            if d.is_dir() and (test_mode(d, root) or 0) & 0o007:
                ch.append(("chmod", d, "%o" % (test_mode(d, root) or 0), "%o" % ((test_mode(d, root) or 0) & ~0o007)))
        if ch:
            plan.append({"id": "file-permissions", "what": "Stop other users on this computer reading secrets.yaml and .storage (remove 'other' permissions)", "changes": ch})

    # --- .gitignore + git
    gi = root / ".gitignore"
    git_ids = [i for i in ("secrets-git", "config-in-git") if by.get(i, {}).get("status") in (FAIL, WARN)]
    if git_ids:
        old = gi.read_text(encoding="utf-8", errors="replace") if gi.is_file() else ""
        have = {l.strip() for l in old.splitlines()}
        add = [l for l in GITIGNORE_LINES if l not in have]
        ch = []
        if add:
            new = old + ("" if old.endswith("\n") or not old else "\n") + "# Added by Secure Linux: keep secrets and big files out of Git\n" + "\n".join(add) + "\n"
            ch.append(("write", gi, old, new))
        if by.get("config-in-git", {}).get("status") == WARN:
            ch.append(("git", root, "", "git init + first snapshot"))
        elif by.get("secrets-git", {}).get("status") == FAIL and (root / ".git").exists():
            ch.append(("git-untrack", root, "", "git rm --cached secrets.yaml .storage (files stay on disk)"))
        if ch:
            plan.append({"id": "secrets-git" if "secrets-git" in git_ids else "config-in-git",
                         "what": "Set up Git history and keep secrets out of it (.gitignore)", "changes": ch})
    return plan


def write_text(path, text):
    """Write a text file with plain Unix line endings on every system (so a restore is byte-for-byte)."""
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


def mask_secrets(text):
    """For previews: hide the value of any typed-in secret so it never lands on the screen or in a log."""
    out = []
    for l in text.splitlines(True):
        m = INLINE_RE.match(l.rstrip("\n"))
        if m and not m.group(3).strip().startswith(("!", "{{", "{%")):
            l = "%s%s: [hidden]\n" % (m.group(1), m.group(2))
        out.append(l)
    return "".join(out)


def git_snapshot(root, message):
    root = Path(root)
    if run(["git", "--version"]) is None:
        return False
    if not (root / ".git").exists():
        if run(["git", "-C", str(root), "init", "-q"]) is None:
            return False
    run(["git", "-C", str(root), "add", "-A"])
    r = subprocess.run(["git", "-C", str(root), "-c", "user.name=Secure Linux", "-c", "user.email=secure-linux@localhost", "commit", "-q", "-m", message,
                        "--allow-empty"], capture_output=True, text=True)
    return r.returncode == 0


def apply_fixes(root, plan, starter_dir, say, ask_yes, validate):
    """Preview each fix, ask, then apply with a Git snapshot before and file-level undo on any failure."""
    root = Path(root)
    if not plan:
        say("Nothing here can be fixed automatically and safely. The list above says what to do by hand.")
        return 0
    applied = 0
    for fx in plan:
        say("")
        say("FIX: " + fx["what"])
        for kind, path, old, new in fx["changes"]:
            rel = os.path.relpath(path, root) if os.path.isabs(str(path)) else str(path)
            if kind in ("write", "write_secret"):
                diff = _unified(rel, mask_secrets(old) if fx["id"] == "secrets-yaml" else old, new)
                if kind == "write_secret":
                    diff = "(secrets.yaml gets %d new line(s); values are not shown here)\n" % max(0, len(new.splitlines()) - len(old.splitlines()))
                say(diff.rstrip("\n") if diff else "(no change)")
            elif kind == "chmod":
                say("  chmod %s -> %s   %s" % (old, new, rel))
            else:
                say("  " + new)
        if not ask_yes("Apply this fix? (type yes to apply, anything else to skip) "):
            say("Skipped.")
            continue
        if fx["id"] == "secrets-yaml":
            # a restore point here would write the plain-text secrets into Git history; the in-memory undo below is enough
            say("(No Git snapshot for this one on purpose: it would copy your passwords into the history. If you committed them earlier, change those passwords.)")
        else:
            git_snapshot(root, "Before Secure Linux fix: %s" % fx["id"])
        undo = []
        try:
            for kind, path, old, new in fx["changes"]:
                if kind in ("write", "write_secret"):
                    path = Path(path)
                    existed = path.exists()
                    undo.append(("write", path, old if existed else None))
                    path.parent.mkdir(parents=True, exist_ok=True)
                    tmp = path.with_name(path.name + ".sl-tmp")
                    oldmask = os.umask(0o077 if kind == "write_secret" else 0o022)
                    try:
                        write_text(tmp, new)
                    finally:
                        os.umask(oldmask)
                    if kind == "write_secret" or path.name == "secrets.yaml":
                        os.chmod(tmp, 0o600)
                    os.replace(tmp, path)
                elif kind == "chmod":
                    undo.append(("chmod", Path(path), int(old, 8)))
                    os.chmod(path, int(new, 8))
                elif kind == "git":
                    git_snapshot(root, "Secure Linux: start tracking this config")
                elif kind == "git-untrack":
                    run(["git", "-C", str(root), "rm", "-r", "--cached", "-q", "--ignore-unmatch", "secrets.yaml", ".storage"])
            problems = validate(root)
            if problems:
                raise Problem("; ".join(problems[:3]))
        except (Problem, OSError) as e:
            for kind, path, old in reversed(undo):
                try:
                    if kind == "write":
                        if old is None:
                            path.unlink()
                        else:
                            write_text(path, old)
                    else:
                        os.chmod(path, old)
                except OSError:
                    pass
            say("That change didn't pass the safety check (%s), so it was UNDONE. Nothing is different." % e)
            continue
        git_snapshot(root, "Secure Linux fix: %s" % fx["id"])
        applied += 1
        say("Done. (Undo any time with: secure-linux-ha rollback)")
    return applied


def validate_after_fix(root):
    problems = []
    issues = []
    cfg = load_yaml_file(Path(root) / "configuration.yaml", root, issues)
    problems.extend(issues)
    if cfg is None and not issues:
        problems.append("configuration.yaml is empty")
    return problems


# ============================================================================================================
# 7b. Small API helpers (version, make a Home Assistant backup) and the starter-kit installer
# ============================================================================================================
def api_session(url, token_file, cafile=None):
    """Open a WebSocket to Home Assistant and log in. Returns (ws, call, token)."""
    token = read_token(token_file)
    ws = WS(url.rstrip("/"), cafile=cafile)
    try:
        hello = ws.recv()
        if hello.get("type") != "auth_required":
            raise Problem("Unexpected greeting from Home Assistant.")
        ws.send({"type": "auth", "access_token": token})
        res = ws.recv()
        if res.get("type") != "auth_ok":
            raise Problem("Home Assistant did not accept the token. Make a new one: Profile > Security > Long-lived access tokens.")
    except Problem:
        ws.close()
        raise
    counter = [0]

    def call(msg):
        counter[0] += 1
        ws.send(dict(msg, id=counter[0]))
        while True:
            r = ws.recv()
            if r.get("id") == counter[0]:
                return r
    return ws, call, token


def api_version(url, token_file, cafile=None):
    import urllib.request
    import urllib.error
    token = read_token(token_file)
    ctx = ssl.create_default_context(cafile=cafile) if url.startswith("https") else None
    req = urllib.request.Request(url.rstrip("/") + "/api/config", headers={"Authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(req, timeout=15, context=ctx) as r:
            return json.load(r).get("version")
    except urllib.error.HTTPError as e:
        raise Problem("Home Assistant said no (HTTP %d); the token may be wrong." % e.code)
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise Problem(scrub("couldn't reach Home Assistant (%s)" % getattr(e, "reason", e), token))


def api_backup_now(url, token_file, cafile=None):
    ws, call, token = api_session(url, token_file, cafile)
    try:
        r = call({"type": "backup/generate", "agent_ids": ["backup.local"], "name": "Secure Linux manual backup"})
        if not r.get("success"):
            err = (r.get("error") or {}).get("message", "unknown reason")
            raise Problem(scrub("Home Assistant would not make the backup: %s (the token must belong to an administrator)." % err, token))
        return r.get("result")
    finally:
        ws.close()


STARTER_PACKAGES = ["sl_helpers", "sl_battery_alerts", "sl_leak_smoke", "sl_door_left_open", "sl_offline_watchdog",
                    "sl_backup_alert", "sl_cert_expiry", "sl_update_digest", "sl_security_watch"]


def starter_summary(path):
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        m = re.match(r"#\s*WHAT IT DOES\s+(.*)", line)
        if m:
            return m.group(1).strip()
    return ""


def starter_list(sdir):
    sdir = Path(sdir)
    print("Packages (always-on; add with: secure-linux-ha starter install NAME  or  all)")
    for n in STARTER_PACKAGES:
        p = sdir / "packages" / (n + ".yaml")
        if p.is_file():
            print("  %-22s %s" % (n, starter_summary(p)[:90]))
    print("")
    print("Blueprints (recipes you finish in Home Assistant by choosing items from lists)")
    for p in sorted((sdir / "blueprints" / "automation" / "secure_linux").glob("*.yaml")):
        print("  %-22s" % p.stem)
    print("")
    print("Dashboard: sl_starter  (add with: secure-linux-ha starter dashboard)")


LOVELACE_BLOCK = ("\n# Added by Secure Linux: the starter dashboard\nlovelace:\n  dashboards:\n    sl-starter:\n"
                  "      mode: yaml\n      title: Home (starter)\n      icon: mdi:home-heart\n      show_in_sidebar: true\n"
                  "      filename: dashboards/sl_starter.yaml\n")


def starter_install(root, sdir, names, say=print):
    """Copy starter files into a config folder. Never overwrites a file you changed. Undoes everything if the
    result doesn't load. Returns the list of files added."""
    root, sdir = Path(root), Path(sdir)
    cfg_path = root / "configuration.yaml"
    cfg_old = cfg_path.read_text(encoding="utf-8", errors="replace")
    want = set(n.strip() for n in names if n.strip())
    all_ = "all" in want
    pk = [n for n in STARTER_PACKAGES if all_ or n in want]
    if pk and "sl_helpers" not in pk:
        pk.insert(0, "sl_helpers")          # every other package sends through script.sl_notify
    do_bp = all_ or "blueprints" in want
    do_dash = all_ or "dashboard" in want
    unknown = [n for n in want if n not in STARTER_PACKAGES and n not in ("all", "blueprints", "dashboard")]
    if unknown:
        raise Problem("I don't have a starter called: %s. See the list with: secure-linux-ha starter list" % ", ".join(unknown))
    added = []
    new_cfg = cfg_old
    try:
        if pk:
            fixed = ensure_packages_text(cfg_old)
            if fixed is None:
                raise Problem("Your configuration.yaml already has a 'homeassistant:' / 'packages:' setup I shouldn't edit automatically. "
                              "Add this under homeassistant:  packages: !include_dir_named packages   then run this again.")
            new_cfg = fixed
            pdir = packages_dir(root, new_cfg)
            for n in pk:
                dst = pdir / (n + ".yaml")
                src = sdir / "packages" / (n + ".yaml")
                if dst.exists():
                    if dst.read_bytes() != src.read_bytes():
                        say("  kept your edited %s (ours not added)" % dst.name)
                    continue
                dst.parent.mkdir(parents=True, exist_ok=True)
                dst.write_bytes(src.read_bytes())
                added.append(dst)
                say("  added packages/%s" % dst.name)
        if do_bp:
            for src in sorted((sdir / "blueprints" / "automation" / "secure_linux").glob("*.yaml")):
                dst = root / "blueprints" / "automation" / "secure_linux" / src.name
                if dst.exists():
                    continue
                dst.parent.mkdir(parents=True, exist_ok=True)
                dst.write_bytes(src.read_bytes())
                added.append(dst)
                say("  added blueprint %s" % src.name)
        if do_dash:
            dst = root / "dashboards" / "sl_starter.yaml"
            if not dst.exists():
                dst.parent.mkdir(parents=True, exist_ok=True)
                dst.write_bytes((sdir / "dashboards" / "sl_starter.yaml").read_bytes())
                added.append(dst)
                say("  added dashboards/sl_starter.yaml")
            if not re.search(r"^lovelace:", new_cfg, re.M):
                new_cfg += ("" if new_cfg.endswith("\n") else "\n") + LOVELACE_BLOCK
            else:
                say("  (you already have a lovelace: section; add the sl-starter dashboard to it by hand, see dashboards/sl_starter.yaml)")
        if new_cfg != cfg_old:
            write_text(cfg_path, new_cfg)
        problems = validate_after_fix(root)
        for f in added:
            if "blueprints" not in f.parts:
                i = []
                load_yaml_file(f, root, i)
                problems.extend(i)
        if problems:
            raise Problem("; ".join(problems[:3]))
    except (Problem, OSError):
        write_text(cfg_path, cfg_old)
        for f in added:
            try:
                f.unlink()
            except OSError:
                pass
        raise
    say("Added %d file(s)." % len(added))
    return added


# ============================================================================================================
# 8. Command line
# ============================================================================================================
def parse_args(argv):
    o = {"cmd": None, "config": None, "ssh": None, "api": False, "url": None, "token_file": None, "json": False, "attest": None, "yes": False,
         "ha_dir": None, "now": None, "latest": None, "out": None, "key": None, "value": None, "cafile": None, "starter": None, "mqtt_conf": None, "z2m_conf": None,
         "list": False, "explain": None, "names": None}
    a = list(argv)
    if a and not a[0].startswith("-"):
        o["cmd"] = a.pop(0)
    while a:
        x = a.pop(0)
        if x in ("--config", "--ssh", "--url", "--token-file", "--attest", "--ha-dir", "--now", "--latest", "--out", "--cafile", "--starter", "--mqtt-conf", "--z2m-conf", "--explain", "--names"):
            if not a:
                raise Problem("%s needs a value." % x)
            o[x[2:].replace("-", "_")] = a.pop(0)
        elif x == "--api":
            o["api"] = True
        elif x == "--json":
            o["json"] = True
        elif x == "--yes":
            o["yes"] = True
        elif x == "--list":
            o["list"] = True
        elif x in ("-h", "--help"):
            o["cmd"] = "help"
        elif o["cmd"] in ("attest", "explain") and o["key"] is None:
            o["key"] = x
        elif o["cmd"] == "attest" and o["value"] is None:
            o["value"] = x
        else:
            raise Problem("I don't understand '%s'. Try --help." % x)
    return o


def gather(o, quiet_say=None):
    opts = {"ha_dir": o["ha_dir"], "cafile": o["cafile"], "mqtt_conf": o["mqtt_conf"], "z2m_conf": o["z2m_conf"]}
    chosen = [bool(o["config"]), bool(o["ssh"]), bool(o["api"])]
    if sum(chosen) != 1:
        raise Problem("Pick exactly one way to look: --config /path/to/config, --ssh user@server, or --api (with --url and --token-file).")
    if o["config"]:
        return collect_config(o["config"], opts)
    if o["ssh"]:
        return collect_ssh(o["ssh"], opts)
    if not o["url"] or not o["token_file"]:
        raise Problem("--api needs --url http://homeassistant.local:8123 and --token-file /path/to/root-only-file")
    return collect_api(o["url"], o["token_file"], opts)


def main(argv):
    try:
        o = parse_args(argv)
        now = float(o["now"]) if o["now"] else time.time()
        if o["cmd"] in (None, "help"):
            print("ha_secure.py check|apply|report|collect|attest|list-checks|plan  (use the wrapper: secure-linux-ha-secure)")
            return 0
        if o["cmd"] == "list-checks":
            for cid, cat, w, crit, _ in CHECKS:
                print("%s|%s|%d|%s|%s" % (cid, cat, w, "critical" if crit else "", TEXT[cid][0]))
            return 0
        if o["cmd"] == "questions":
            for k, q, choices, helptext in ATTEST_QUESTIONS:
                print("%s\t%s\t%s\t%s" % (k, q, choices, helptext))
            return 0
        if o["cmd"] == "explain":
            cid = o["key"] or o["explain"]
            if cid not in TEXT:
                raise Problem("There's no check called '%s'. See them all with --list." % cid)
            t, why, fix = TEXT[cid]
            print("%s\n\nWhy it matters: %s\n\nHow to fix: %s" % (t, why, fix))
            return 0
        if o["cmd"] == "attest":
            if not o["attest"] or not o["key"] or o["value"] is None:
                raise Problem("Use: attest KEY VALUE --attest FILE")
            save_attest(o["attest"], o["key"], o["value"])
            print("Saved: %s = %s" % (o["key"], o["value"]))
            return 0
        if o["cmd"] == "collect":                      # runs on the server (over SSH)
            try:
                F = collect_via_ssh_remote({"ha_dir": o["ha_dir"], "mqtt_conf": o["mqtt_conf"], "z2m_conf": o["z2m_conf"]})
            except Problem as e:
                print(json.dumps({"problem": str(e)}))
                return 0
            print(json.dumps(F))
            return 0
        if o["cmd"] == "starter-list":
            starter_list(o["starter"] or os.path.join(os.path.dirname(os.path.abspath(__file__)), "starter"))
            return 0
        if o["cmd"] == "starter-install":
            if not o["config"]:
                raise Problem("starter-install needs --config FOLDER")
            starter_install(o["config"], o["starter"] or os.path.join(os.path.dirname(os.path.abspath(__file__)), "starter"), (o["names"] or "all").split(","))
            return 0
        if o["cmd"] == "version":
            if not o["url"] or not o["token_file"]:
                raise Problem("version needs --url and --token-file")
            print(api_version(o["url"], o["token_file"], o["cafile"]) or "unknown")
            return 0
        if o["cmd"] == "backup-now":
            if not o["url"] or not o["token_file"]:
                raise Problem("backup-now needs --url and --token-file")
            api_backup_now(o["url"], o["token_file"], o["cafile"])
            print("Home Assistant is making a backup now. Watch it finish in Settings > System > Backups.")
            return 0
        F = gather(o)
        A = load_attest(o["attest"])
        if o["url"]:
            A["_url"] = o["url"]
        if o["latest"]:
            A["_latest"] = o["latest"]
        if os.environ.get("SL_HA_REMOTE_MODE") and "remote_mode" not in A:
            A["remote_mode"] = os.environ["SL_HA_REMOTE_MODE"]
        results = evaluate(F, A, now)
        summ = summarise(results)
        when = datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%d")
        if o["cmd"] == "check":
            if o["json"]:
                print(json.dumps({"summary": summ, "results": results, "source": F["source"]}, indent=1))
            else:
                print(render_text(results, summ, F))
                for e in F.get("api_errors") or []:
                    print("(note: %s)" % e)
            return 0 if summ["grade"] in ("A", "B") else 1
        if o["cmd"] == "report":
            text = render_markdown(results, summ, F, when)
            if o["out"]:
                old = os.umask(0o077)
                try:
                    with open(o["out"], "w", encoding="utf-8") as fh:
                        fh.write(text + "\n")
                finally:
                    os.umask(old)
                print("Report saved to %s" % o["out"])
            else:
                print(text)
            return 0
        if o["cmd"] in ("plan", "apply"):
            if F["source"] != "config":
                raise Problem("Automatic fixes only work on a config folder (--config). For the server or the API, I show you the exact steps instead; use --check.")
            starter = o["starter"] or os.path.join(os.path.dirname(os.path.abspath(__file__)), "starter")
            plan = plan_fixes(o["config"], results, starter)
            if o["cmd"] == "plan":
                for fx in plan:
                    print("%s|%s" % (fx["id"], fx["what"]))
                return 0

            def ask_yes(q):
                if o["yes"]:
                    return True
                try:
                    return input(q).strip().lower() == "yes"
                except EOFError:
                    return False
            before = summ
            n = apply_fixes(o["config"], plan, starter, print, ask_yes, validate_after_fix)
            F2 = collect_config(o["config"], {"mqtt_conf": o["mqtt_conf"], "z2m_conf": o["z2m_conf"]})
            after = summarise(evaluate(F2, A, now))
            print("")
            print("Applied %d fix(es). Score %d -> %d, grade %s -> %s." % (n, before["score"], after["score"], before["grade"], after["grade"]))
            return 0
        raise Problem("Unknown command '%s'." % o["cmd"])
    except Problem as e:
        print("Problem: %s" % e, file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
