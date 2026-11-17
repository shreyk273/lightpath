#!/usr/bin/env python3
"""
lightpath-agent: the host side of Lightpath's Mac integration.

Listens on TCP 48900. The firewall only opens that port on the Tailscale interface, and every
request that changes something is additionally checked with `tailscale whois`: the caller must
be a device owned by the same Tailscale user as this PC. Tailscale's WireGuard keys are the
authentication, so no passwords or PINs have to be typed anywhere.

Endpoints
  GET  /status            host facts the Mac caches for waking and connecting
  POST /pair   pin=NNNN   approve the Moonlight pairing request coming from the caller's address
  POST /wake-intent       "I woke you to stream remotely": keep the projector off after resume
  GET  /speedtest?mb=N    N MiB of incompressible data for a bandwidth estimate (max 64)
"""
import base64
import http.server
import ipaddress
import json
import os
import re
import secrets
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path

PORT = int(os.environ.get("LIGHTPATH_AGENT_PORT", "48900"))
SUNSHINE_PORT = int(os.environ.get("LIGHTPATH_BASE_PORT", "48989"))
CRED_FILE = Path.home() / ".config/lightpath/sunshine-web.cred"
WAKE_RELAY_FILE = Path.home() / ".config/lightpath/wake-relay"  # e.g. https://ntfy.sh/<secret topic>
RUNTIME = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")) / "lightpath"
INTENT_FILE = RUNTIME / "remote-wake"
NOISE = secrets.token_bytes(1 << 20)  # 1 MiB of random bytes, reused for speed tests


def log(*args):
    print(*args, flush=True)


def run(*cmd, timeout=5):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


# --------------------------------------------------------------------------- identity
_self_user = None


def self_user_id():
    global _self_user
    if _self_user is None:
        try:
            _self_user = json.loads(run("tailscale", "status", "--json"))["Self"]["UserID"]
        except (ValueError, KeyError):
            return None
    return _self_user


def same_owner(ip):
    """True if `ip` is a Tailscale node owned by the same user as this machine (or localhost)."""
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    if addr.is_loopback:
        return True
    if hasattr(addr, "ipv4_mapped") and addr.ipv4_mapped:
        addr = addr.ipv4_mapped
    try:
        who = json.loads(run("tailscale", "whois", "--json", str(addr)))
    except ValueError:
        return False
    owner = self_user_id()
    return owner is not None and who.get("Node", {}).get("User") == owner


# --------------------------------------------------------------------------- host facts
def lan_info():
    """Primary LAN interface: name, IPv4, broadcast, MAC, global IPv6 addresses."""
    try:
        r = json.loads(run("ip", "-j", "route", "get", "1.1.1.1"))[0]
        dev, src = r["dev"], r.get("prefsrc")
    except (ValueError, IndexError, KeyError):
        return {}
    info = {"interface": dev, "ipv4": src, "wifi": Path(f"/sys/class/net/{dev}/wireless").exists()}
    try:
        info["mac"] = Path(f"/sys/class/net/{dev}/address").read_text().strip()
    except OSError:
        pass
    try:
        for a in json.loads(run("ip", "-j", "-4", "addr", "show", "dev", dev))[0]["addr_info"]:
            if a.get("local") == src:
                info["broadcast"] = str(ipaddress.ip_interface(f"{src}/{a['prefixlen']}").network.broadcast_address)
    except (ValueError, IndexError, KeyError):
        pass
    try:
        addrs = json.loads(run("ip", "-j", "-6", "addr", "show", "dev", dev, "scope", "global"))[0]["addr_info"]
        info["ipv6"] = [a["local"] for a in addrs if a.get("local") and not a.get("temporary") and not a.get("deprecated")]
    except (ValueError, IndexError, KeyError):
        info["ipv6"] = []
    return info


def tailscale_info():
    try:
        st = json.loads(run("tailscale", "status", "--json"))
        me = json.loads(run("tailscale", "whois", "--json", st["Self"]["TailscaleIPs"][0]))
        endpoints = me["Node"].get("Endpoints", [])
    except (ValueError, KeyError, IndexError):
        return {}
    public = [e for e in endpoints if not _is_private_endpoint(e)]
    return {"ips": st["Self"]["TailscaleIPs"], "dns": st["Self"]["DNSName"].rstrip("."), "public_endpoints": public}


def _is_private_endpoint(ep):
    host = ep.rsplit(":", 1)[0].strip("[]")
    try:
        a = ipaddress.ip_address(host)
    except ValueError:
        return True
    return a.is_private or a.is_link_local or a.is_loopback


def stream_active():
    """A Lightpath virtual display exists only while a client is streaming."""
    out = run("gdctl", "show")
    return bool(re.search(r"Monitor Meta-\d+", out))


def wake_relay():
    """URL of an always-on device's wake relay (see README: waking from anywhere), if set up."""
    try:
        url = WAKE_RELAY_FILE.read_text().strip()
    except OSError:
        return None
    return url if url.startswith("https://") else None


def status():
    return {
        "name": socket.gethostname(),
        "sunshine_port": SUNSHINE_PORT,
        "lan": lan_info(),
        "tailscale": tailscale_info(),
        "streaming": stream_active(),
        "wake_relay": wake_relay(),
        "time": int(time.time()),
    }


# --------------------------------------------------------------------------- Sunshine API
def sunshine_creds():
    vals = dict(line.split("=", 1) for line in CRED_FILE.read_text().splitlines() if "=" in line)
    return vals["username"], vals["password"]


def sunshine(method, path, body=None, timeout=20):
    user, pw = sunshine_creds()
    url = f"https://127.0.0.1:{SUNSHINE_PORT + 1}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Basic " + base64.b64encode(f"{user}:{pw}".encode()).decode())
    if data is not None:
        req.add_header("Content-Type", "application/json")
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE  # Sunshine's self-signed certificate on loopback
    with urllib.request.urlopen(req, context=ctx, timeout=timeout) as resp:
        return json.loads(resp.read() or b"{}")


def approve_pairing(client_ip, pin, name):
    """Wait for the Moonlight pairing request from client_ip and submit the PIN for it."""
    want = ipaddress.ip_address(client_ip)
    if hasattr(want, "ipv4_mapped") and want.ipv4_mapped:
        want = want.ipv4_mapped
    deadline = time.time() + 30
    while time.time() < deadline:
        for p in sunshine("GET", "/api/pin").get("pairings", []):
            try:
                addr = ipaddress.ip_address(p.get("address", ""))
            except ValueError:
                continue
            if hasattr(addr, "ipv4_mapped") and addr.ipv4_mapped:
                addr = addr.ipv4_mapped
            # Local callers (tests, scripts on this PC) may approve any pending request.
            if addr == want or want.is_loopback:
                res = sunshine("POST", "/api/pin", {"pairing_id": p["id"], "pin": pin, "name": name}, timeout=40)
                return bool(res.get("status"))
        time.sleep(0.4)
    return False


def _prune(obj):
    """Drop None values: the Mac reads this JSON with plutil, which has no null."""
    if isinstance(obj, dict):
        return {k: _prune(v) for k, v in obj.items() if v is not None}
    if isinstance(obj, list):
        return [_prune(v) for v in obj if v is not None]
    return obj


# --------------------------------------------------------------------------- HTTP
class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "lightpath-agent/1"

    def _json(self, code, obj):
        body = json.dumps(_prune(obj)).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _form(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(min(n, 4096)).decode(errors="replace")
        if self.headers.get("Content-Type", "").startswith("application/json"):
            try:
                return json.loads(raw or "{}")
            except ValueError:
                return {}
        return {k: v[0] for k, v in urllib.parse.parse_qs(raw).items()}

    def _authorized(self):
        if same_owner(self.client_address[0]):
            return True
        self._json(403, {"error": "caller is not a device on this Tailscale account"})
        return False

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        if url.path == "/status":
            if self._authorized():
                self._json(200, status())
        elif url.path == "/speedtest":
            if not self._authorized():
                return
            q = urllib.parse.parse_qs(url.query)
            mb = max(1, min(64, int(q.get("mb", ["8"])[0])))
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(mb << 20))
            self.end_headers()
            try:
                for _ in range(mb):
                    self.wfile.write(NOISE)
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        url = urllib.parse.urlparse(self.path)
        if not self._authorized():
            return
        form = self._form()
        if url.path == "/pair":
            pin = str(form.get("pin", ""))
            name = str(form.get("name", "Mac"))[:64] or "Mac"
            if not re.fullmatch(r"\d{4}", pin):
                self._json(400, {"error": "pin must be 4 digits"})
                return
            log(f"pairing request from {self.client_address[0]} ({name})")
            try:
                ok = approve_pairing(self.client_address[0], pin, name)
            except Exception as e:  # noqa: BLE001 - report any Sunshine API failure to the caller
                self._json(502, {"error": f"sunshine: {e}"})
                return
            self._json(200 if ok else 409, {"paired": ok})
        elif url.path == "/wake-intent":
            RUNTIME.mkdir(parents=True, exist_ok=True)
            INTENT_FILE.write_text(f"{int(time.time())} {self.client_address[0]}\n")
            log(f"remote wake intent from {self.client_address[0]}")
            self._json(200, {"ok": True})
        else:
            self._json(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        log(f"{self.client_address[0]} {fmt % args}")


class Server(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6
    daemon_threads = True

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


def main():
    RUNTIME.mkdir(parents=True, exist_ok=True)
    srv = Server(("::", PORT), Handler)
    log(f"lightpath-agent listening on port {PORT}")
    threading.Thread(target=self_user_id, daemon=True).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
