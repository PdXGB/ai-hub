#!/usr/bin/env python3
"""aihub-ssh: runs ssh/scp to LAN hosts on behalf of the Open WebUI "Remote Shell" tool.

Stdlib only. Listens on the internal `ssh` Docker network (no published port) and needs a bearer token.
Only hosts in the inventory (/ssh/hosts.conf, written by aihub-enroll) can be reached; every call is
logged to /ssh/audit.log. Confirmation happens in the Open WebUI tool before it calls this service.

Usage:
  app.py serve            run the HTTP service (default)
  app.py hosts            print the inventory
  app.py test ALIAS       run `true` on ALIAS with this container's key (enrollment check)
"""

import hmac
import ipaddress
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SSH_DIR = Path(os.environ.get("SSH_DIR", "/ssh"))
HOSTS = SSH_DIR / "hosts.conf"   # the inventory, also used directly as the ssh config file
AUDIT = SSH_DIR / "audit.log"
TRANSFER = Path(os.environ.get("TRANSFER_DIR", "/transfer")).resolve()
TOKEN = os.environ.get("AIHUB_SSH_TOKEN", "")
PORT = int(os.environ.get("PORT", "8022"))
MAX_OUTPUT = int(os.environ.get("MAX_OUTPUT_BYTES", "65536"))
MAX_TIMEOUT = int(os.environ.get("MAX_TIMEOUT_S", "600"))
ALLOW_PUBLIC = os.environ.get("ALLOW_PUBLIC_HOSTS", "0") == "1"

ALIAS_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")
# Forced on every call; command-line -o wins over anything in the config files.
SSH_OPTS = [
    "-F", str(HOSTS),
    "-o", "BatchMode=yes",
    "-o", "StrictHostKeyChecking=yes",
    "-o", f"UserKnownHostsFile={SSH_DIR / 'known_hosts'}",
    "-o", "GlobalKnownHostsFile=/dev/null",
    "-o", "IdentitiesOnly=yes",
    "-o", f"IdentityFile={SSH_DIR / 'id_ed25519'}",
    "-o", "ConnectTimeout=10",
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=3",
    "-o", "ClearAllForwardings=yes",
    "-o", "PermitLocalCommand=no",
    "-o", "ForwardAgent=no",
    "-o", "ControlMaster=no",
]
_audit_lock = threading.Lock()


class Refused(Exception):
    pass


def inventory():
    """Host aliases from hosts.conf (wildcards skipped), with ssh's effective user/hostname/port."""
    names = []
    if HOSTS.exists():
        for line in HOSTS.read_text().splitlines():
            parts = line.split("#", 1)[0].split()
            if len(parts) >= 2 and parts[0].lower() == "host":
                names += [p for p in parts[1:] if ALIAS_RE.match(p)]
    hosts = []
    for name in dict.fromkeys(names):
        eff = effective(name)
        hosts.append({"host": name, "user": eff.get("user", ""), "hostname": eff.get("hostname", ""),
                      "port": eff.get("port", "22")})
    return hosts


def effective(alias):
    out = subprocess.run(["ssh", *SSH_OPTS, "-G", alias], capture_output=True, text=True, timeout=10).stdout
    eff = {}
    for line in out.splitlines():
        k, _, v = line.partition(" ")
        eff.setdefault(k, v)
    return eff


def check_host(alias):
    if not isinstance(alias, str) or not ALIAS_RE.match(alias):
        raise Refused("host must be an inventory alias")
    match = next((h for h in inventory() if h["host"] == alias), None)
    if not match:
        raise Refused(f"'{alias}' is not in the inventory; known hosts: "
                      + ", ".join(h["host"] for h in inventory()))
    if not ALLOW_PUBLIC:
        try:
            addrs = {ai[4][0] for ai in socket.getaddrinfo(match["hostname"], None)}
        except socket.gaierror:
            raise Refused(f"cannot resolve {match['hostname']}")
        public = [a for a in addrs if not ipaddress.ip_address(a.split("%")[0]).is_private]
        if public:
            raise Refused(f"{alias} resolves to a non-LAN address ({', '.join(public)}); refused")
    return match


def local_path(name, must_exist):
    if not isinstance(name, str) or not name.strip() or name.startswith("-"):
        raise Refused("local name must be a relative path inside the transfer folder")
    p = (TRANSFER / name.strip().lstrip("/")).resolve()
    if p != TRANSFER and TRANSFER not in p.parents:
        raise Refused("local path escapes the transfer folder")
    if must_exist and not p.exists():
        raise Refused(f"'{name}' not found in the transfer folder")
    return p


def remote_path(path):
    if not isinstance(path, str) or not path.strip():
        raise Refused("remote path is empty")
    if path.startswith("-") or "\n" in path or "\r" in path:
        raise Refused("remote path may not start with '-' or contain newlines")
    return path.strip()


def clip(b):
    s = b.decode("utf-8", "replace")
    if len(b) > MAX_OUTPUT:
        return s[:MAX_OUTPUT] + f"\n…[cut: {len(b)} bytes total]", True
    return s, False


def execute(argv, timeout):
    t0 = time.monotonic()
    try:
        p = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout)
        code, out, err = p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired as e:
        code, out, err = 124, e.stdout or b"", (e.stderr or b"") + f"\n[timed out after {timeout}s]".encode()
    so, t1 = clip(out)
    se, t2 = clip(err)
    return {"exit": code, "stdout": so, "stderr": se, "truncated": t1 or t2,
            "seconds": round(time.monotonic() - t0, 1)}


def timeout_of(req):
    try:
        return max(5, min(int(req.get("timeout_s", 60)), MAX_TIMEOUT))
    except (TypeError, ValueError):
        return 60


def do_run(req):
    check_host(req.get("host"))
    cmd = req.get("command")
    if not isinstance(cmd, str) or not cmd.strip():
        raise Refused("command is empty")
    return execute(["ssh", *SSH_OPTS, "-T", req["host"], "--", cmd], timeout_of(req))


def scp(src, dst, recursive, timeout):
    base = ["scp", *SSH_OPTS, "-p"] + (["-r"] if recursive else [])
    res = execute(base + ["--", src, dst], timeout)
    # Hosts without an SFTP subsystem (Synology with SFTP off, some appliances): retry the legacy protocol.
    if res["exit"] != 0 and re.search(r"subsystem|sftp|Connection closed", res["stderr"], re.I):
        res = execute(base[:1] + ["-O"] + base[1:] + ["--", src, dst], timeout)
        res["legacy_scp"] = True
    return res


def do_fetch(req):
    host = check_host(req.get("host"))["host"]
    rp = remote_path(req.get("remote_path"))
    name = req.get("local_name") or os.path.basename(rp.rstrip("/")) or "download"
    lp = local_path(name, must_exist=False)
    lp.parent.mkdir(parents=True, exist_ok=True)
    res = scp(f"{host}:{rp}", str(lp), bool(req.get("recursive")), timeout_of(req))
    res["local_name"] = str(lp.relative_to(TRANSFER))
    return res


def do_send(req):
    host = check_host(req.get("host"))["host"]
    lp = local_path(req.get("local_name"), must_exist=True)
    rp = remote_path(req.get("remote_path"))
    return scp(str(lp), f"{host}:{rp}", bool(req.get("recursive")) or lp.is_dir(), timeout_of(req))


def do_files(_req):
    files = []
    for p in sorted(TRANSFER.rglob("*")):
        if p.is_file():
            st = p.stat()
            files.append({"name": str(p.relative_to(TRANSFER)), "bytes": st.st_size,
                          "modified": time.strftime("%Y-%m-%d %H:%M", time.localtime(st.st_mtime))})
    return {"files": files[:500], "count": len(files)}


ROUTES = {
    ("GET", "/hosts"): lambda _r: {"hosts": inventory()},
    ("GET", "/files"): do_files,
    ("POST", "/run"): do_run,
    ("POST", "/fetch"): do_fetch,
    ("POST", "/send"): do_send,
}


def audit(entry):
    with _audit_lock, open(AUDIT, "a") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


class Handler(BaseHTTPRequestHandler):
    server_version = "aihub-ssh"

    def log_message(self, fmt, *args):  # audit.log is the record; keep docker logs short
        sys.stderr.write("%s %s\n" % (self.command, self.path))

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_any(self):
        if self.path == "/health":
            return self.reply(200, {"ok": True})
        auth = self.headers.get("Authorization", "")
        if not TOKEN or not hmac.compare_digest(auth, f"Bearer {TOKEN}"):
            return self.reply(401, {"error": "unauthorized"})
        route = ROUTES.get((self.command, self.path))
        if not route:
            return self.reply(404, {"error": "not found"})
        req = {}
        if self.command == "POST":
            try:
                n = int(self.headers.get("Content-Length", "0"))
                req = json.loads(self.rfile.read(min(n, 65536)) or b"{}")
                if not isinstance(req, dict):
                    raise ValueError
            except ValueError:
                return self.reply(400, {"error": "body must be a JSON object"})
        entry = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "action": self.path.strip("/"),
                 "caller": str(req.get("caller", ""))[:200],
                 **{k: req[k] for k in ("host", "command", "remote_path", "local_name") if k in req}}
        try:
            res = route(req)
        except Refused as e:
            if self.command == "POST":
                audit({**entry, "refused": str(e)})
            return self.reply(400, {"error": str(e)})
        except Exception as e:  # noqa: BLE001 - report, don't crash the server
            audit({**entry, "error": repr(e)})
            return self.reply(500, {"error": repr(e)})
        if self.command == "POST":
            audit({**entry, "exit": res.get("exit"), "seconds": res.get("seconds")})
        return self.reply(200, res)

    do_GET = do_POST = handle_any


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "serve"
    if mode == "hosts":
        for h in inventory():
            print(f"{h['host']:20} {h['user']}@{h['hostname']}:{h['port']}")
        return
    if mode == "test" and len(sys.argv) == 3:
        try:
            check_host(sys.argv[2])
        except Refused as e:
            sys.exit(f"refused: {e}")
        res = execute(["ssh", *SSH_OPTS, "-T", sys.argv[2], "--", "echo aihub-ssh ok: $(id -un)@$(hostname)"], 20)
        print(res["stdout"].strip() or res["stderr"].strip())
        sys.exit(res["exit"])
    if mode != "serve":
        sys.exit(__doc__)
    if not TOKEN:
        sys.exit("AIHUB_SSH_TOKEN is not set")
    TRANSFER.mkdir(parents=True, exist_ok=True)
    print(f"aihub-ssh listening on :{PORT}, {len(inventory())} hosts", file=sys.stderr, flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
