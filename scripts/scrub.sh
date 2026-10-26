#!/usr/bin/env bash
# scrub.sh - copy the server's live configs into a staging folder and replace
# secrets and site-specific values with placeholders, so they can be
# reviewed and committed to a public repo.
#
# Run ON THE SERVER:   sudo bash scrub.sh [output-dir]   (default ~/aihub-staging)
# Then review OUT/scrub-report.txt and the files before committing anything.
#
# Nothing personal is hardcoded here: secrets, IPs, domain, NAS, GPU UUIDs,
# hostname and usernames are discovered from the live system at run time. Anything it can't
# discover goes in ~/.scrub-literals (never commit it), one per line:
#   find=>replace          e.g.   My Real Name=>youruser
#
# Safety: the output dir must be new, empty, or a previous scrub output
# (marked by .aihub-scrub-output). Anything else is refused, never deleted.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo (needs to read root-only configs)."; exit 1; }
USER_NAME="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
OUT="$(realpath -m "${1:-$USER_HOME/aihub-staging}")"
AI=/srv/ai
MARK=.aihub-scrub-output

# ---------- guard the output dir ----------
case "$OUT" in
  /|/root|/home|/etc|/etc/*|/usr|/usr/*|/srv|/srv/ai|/srv/ai/*|/var|/boot|/boot/*|"$USER_HOME")
    echo "Refusing output dir $OUT"; exit 1 ;;
esac
if [ -e "$OUT" ]; then
  [ -d "$OUT" ] || { echo "$OUT exists and is not a directory."; exit 1; }
  if [ -n "$(ls -A "$OUT")" ]; then
    [ -f "$OUT/$MARK" ] || { echo "$OUT is not empty and is not a previous scrub output. Refusing."; exit 1; }
    find "$OUT" -mindepth 1 -delete
  fi
fi
mkdir -p "$OUT"/{compose/litellm,compose/searxng,systemd,scripts,host/bin}
touch "$OUT/$MARK"

cp_if() { if [ -e "$1" ]; then cp -a "$1" "$2" && echo "  + $1"; else echo "  - (missing) $1"; fi; }

echo "Copying live configs:"
cp_if "$AI/compose.yaml"              "$OUT/compose/compose.yaml"
cp_if "$AI/litellm/config.yaml"       "$OUT/compose/litellm/config.example.yaml"
cp_if "$AI/searxng/settings.yml"      "$OUT/compose/searxng/settings.example.yml"

for u in nvidia-power-limit.service comfyui.service \
         comfyui-idle-free.service comfyui-idle-free.timer \
         aihub-backup.service aihub-backup.timer \
         aihub-brief.service aihub-brief.timer \
         aihub-mon.service aihub-mon.timer \
         aihub-mon-daily.service aihub-mon-daily.timer \
         aihub-mon-listen.service; do
  [ -e "/etc/systemd/system/$u" ] && cp_if "/etc/systemd/system/$u" "$OUT/systemd/$u"
done
for d in comfyui.service.d nvidia-persistenced.service.d; do
  if [ -d "/etc/systemd/system/$d" ]; then
    mkdir -p "$OUT/systemd/$d"; cp -a /etc/systemd/system/$d/*.conf "$OUT/systemd/$d/" && echo "  + /etc/systemd/system/$d/"
  fi
done
for s in aihub-backup aihub-brief aihub-gpu-power aihub-mon comfyui-idle-free; do
  [ -e "/usr/local/bin/$s" ] && cp_if "/usr/local/bin/$s" "$OUT/host/bin/$s"
done
cp_if /etc/docker/daemon.json                 "$OUT/host/docker-daemon.json"
cp_if /etc/apt/apt.conf.d/51unattended-nvidia "$OUT/host/51unattended-nvidia"
cp_if /etc/aihub-mon.env                      "$OUT/host/aihub-mon.env.example"
cp_if "$USER_HOME/aihub-gpu-audit.sh"         "$OUT/scripts/aihub-gpu-audit.sh"
cp_if "$AI/update-image.sh"                   "$OUT/scripts/update-image.sh"
cp_if "$AI/monthly-update.sh"                 "$OUT/scripts/monthly-update.sh"
# Never collected: /root/.config/mosquitto_pub (broker login), .env values,
# SMB credential files. They are only READ below so their values get scrubbed.

# .env variable names only (compare against the documented compose/.env.example)
if [ -f "$AI/.env" ]; then
  sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)=.*/\1=/p' "$AI/.env" > "$OUT/compose/.env.names"
  echo "  + $AI/.env -> compose/.env.names (names only)"
fi

echo "Scrubbing:"
rc=0
python3 - "$OUT" "$USER_NAME" "$USER_HOME" "$MARK" <<'PY' || rc=$?
import os, re, sys, subprocess, pathlib, collections, ipaddress
out, user, home, mark = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]

def kv(path):
    d = {}
    try:
        for l in open(path):
            l = l.strip()
            if l and not l.startswith('#') and '=' in l:
                k, v = l.split('=', 1); d[k.strip()] = v.strip().strip('"\'')
    except (FileNotFoundError, PermissionError, IsADirectoryError):
        pass
    return d

def is_ip(s):
    try: ipaddress.ip_address(s); return True
    except ValueError: return False

literal = {}        # exact value -> placeholder (applied longest first)
leak_words = []     # (label, regex) that must not survive

# 1. ~/.scrub-literals (manual)
lit_file = pathlib.Path(home, '.scrub-literals')
if lit_file.exists():
    for l in lit_file.read_text().splitlines():
        if '=>' in l and not l.lstrip().startswith('#'):
            f, r = l.split('=>', 1)
            if f.strip():
                literal[f.strip()] = r.strip()
                leak_words.append(('scrub-literal', re.escape(f.strip())))

# 2. .env values
env = kv('/srv/ai/.env')
for k, v in env.items():
    if len(v) >= 8: literal[v] = '${%s}' % k

# 3. other secret-bearing config files (read only)
for path, tag in [('/etc/aihub-brief.conf', 'BRIEF')]:
    for k, v in kv(path).items():
        if len(v) >= 8 and not v.startswith('http'):
            literal[v] = '<REDACTED:%s_%s>' % (tag, k.upper())
ha_host = None
try:
    toks = open('/root/.config/mosquitto_pub').read().split()
    for i, t in enumerate(toks[:-1]):
        if t in ('-P', '--pw') and len(toks[i+1]) >= 4: literal[toks[i+1]] = '<REDACTED:MQTT_PASSWORD>'
        if t in ('-h', '--host'): ha_host = toks[i+1]
except (FileNotFoundError, PermissionError):
    pass

# 4. NAS mounts and SMB credentials, discovered from /etc/fstab
nas_names, nas_n = set(), 0
try:
    for l in open('/etc/fstab'):
        f = l.split()
        if len(f) < 3 or f[0].startswith('#') or f[2] not in ('cifs', 'smb3', 'nfs', 'nfs4'): continue
        src, mnt, opts = f[0], f[1], (f[3] if len(f) > 3 else '')
        nas_n += 1
        literal[mnt] = '/mnt/nas' if nas_n == 1 else '/mnt/nas%d' % nas_n
        nas_names.add(os.path.basename(mnt.rstrip('/')))
        m = re.match(r'^//([^/]+)/', src) or re.match(r'^([^:/]+):', src)
        if m:
            h = m.group(1)
            literal[h] = '${NAS_HOST}'
            if not is_ip(h): nas_names.add(h.split('.')[0])
        for o in opts.split(','):
            if o.startswith('credentials='):
                for k, v in kv(o.split('=', 1)[1]).items():
                    if 'pass' in k.lower() and len(v) >= 4: literal[v] = '<REDACTED:SMB_PASSWORD>'
except FileNotFoundError:
    pass
nas_names = {n for n in nas_names if len(n) >= 3 and n.lower() not in ('mnt', 'nas', 'backup', 'aihub')}

# 5. GPU UUIDs -> compose variables (biggest card = main, next = HA)
try:
    rows = subprocess.run(['nvidia-smi', '--query-gpu=memory.total,uuid', '--format=csv,noheader,nounits'],
                          capture_output=True, text=True, timeout=20).stdout.strip().splitlines()
    rows = sorted((int(m), u.strip()) for m, u in (r.split(',') for r in rows))
    for i, (_, uuid) in enumerate(reversed(rows)):
        literal[uuid] = '${GPU_MAIN_UUID}' if i == 0 else ('${GPU_HA_UUID}' if i == 1 else '${GPU_%d_UUID}' % i)
except Exception:
    pass

# 6. known site IPs
try: literal[subprocess.run(['hostname', '-I'], capture_output=True, text=True).stdout.split()[0]] = '${AIHUB_LAN_IP}'
except Exception: pass
m = re.search(r'https?://([\d.]+)', kv('/etc/aihub-brief.conf').get('HA_URL', ''))
if m: ha_host = ha_host or m.group(1)
if ha_host: literal[ha_host] = '${HA_HOST}'

# 7. public domain, from the hostnames in .env
domain = None
hosts = [env.get('N8N_HOSTNAME', ''), env.get('CHAT_HOSTNAME', '')]
comp = out / 'compose' / 'compose.yaml'
if comp.exists():
    ct = comp.read_text(errors='replace')
    hosts += re.findall(r'N8N_HOST:\s*["\']?([A-Za-z0-9.-]+\.[A-Za-z]{2,})', ct)
    hosts += re.findall(r'WEBHOOK_URL:\s*["\']?https?://([A-Za-z0-9.-]+\.[A-Za-z]{2,})', ct)
for v in hosts:
    if v.count('.') >= 2: domain = v.split('.', 1)[1]; break
    if v.count('.') == 1: domain = v; break

# emails first, so a scrubbed username inside an address can't leave its domain behind
rules = [(r'\b(?!you@example\.com)(?![\w.+-]+@users\.noreply\.github\.com)[\w.+-]+@[\w-]+\.[A-Za-z][\w.-]*', 'you@example.com'),]
rules += [(re.escape(v), r) for v, r in sorted(literal.items(), key=lambda x: -len(x[0]))]
if domain:
    rules.append((r'\bn8n\.' + re.escape(domain), '${N8N_HOSTNAME}'))
    rules.append((r'\bchat\.' + re.escape(domain), '${CHAT_HOSTNAME}'))
    rules.append((re.escape(domain), 'example.com'))
    leak_words.append(('domain', re.escape(domain)))
for n in nas_names:
    rules.append((r'(?i)\b' + re.escape(n) + r'\b', None))           # NAS / nas, keeps case style
    leak_words.append(('NAS name', r'(?i)\b' + re.escape(n) + r'\b'))
# the server's hostname (public files say "the server" or <hostname>)
import socket
host = socket.gethostname().split('.')[0]
if len(host) >= 3 and host.lower() not in ('localhost', 'ubuntu', 'server', 'aihub'):
    rules.append((r'(?i)\b' + re.escape(host) + r'\b', '<hostname>'))
    leak_words.append(('hostname', r'(?i)\b' + re.escape(host) + r'\b'))

# Remaining private addresses -> numbered placeholders
priv = collections.OrderedDict()
def priv_sub(mo):
    s = mo.group(0)
    if s == '172.16.0.0/12': return s                       # generic Docker range, not site-specific
    if s not in priv:
        priv[s] = '<PRIVATE_NET_%d>' % (sum('/' in k for k in priv) + 1) if '/' in s \
                  else '<PRIVATE_IP_%d>' % (sum('/' not in k for k in priv) + 1)
    return priv[s]
PRIV = r'\b(?:192\.168|10\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}(?:/\d{1,2})?\b'

rules += [
    (PRIV, priv_sub),
    (r'\bGPU-[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\b', '<GPU_UUID>'),
    (r'\bsk-ant-[A-Za-z0-9_-]{16,}', '<REDACTED_API_KEY>'),
    (r'\bsk-[A-Za-z0-9_-]{16,}', '<REDACTED_API_KEY>'),
    (r'\bxai-[A-Za-z0-9]{16,}', '<REDACTED_API_KEY>'),
    (r'\bAIza[0-9A-Za-z_-]{20,}', '<REDACTED_API_KEY>'),
    (r'\bgh[pousr]_[A-Za-z0-9]{20,}', '<REDACTED_TOKEN>'),
    (r'\beyJ[\w-]{10,}(\.[\w-]{10,}){0,2}', '<REDACTED_JWT>'),
    (r'(\b[a-z][a-z0-9+.-]*://[^/\s:@]+:)(?!\$\{)[^@\s/]+@', r'\1<REDACTED>@'),   # password in URL
    (r'(?<!sha256:)\b[0-9a-f]{32,}\b', '<REDACTED_HEX>'),                # keeps image digests
    (r'/home/' + re.escape(user) + r'\b', '/home/<user>'),
    (r'(?m)^(User|Group)=' + re.escape(user) + r'$', r'\1=<user>'),
]

report = collections.defaultdict(collections.Counter)
files = sorted(p for p in out.rglob('*') if p.is_file() and p.name != mark)
for f in files:
    text = f.read_text(errors='replace')
    for pat, rep in rules:
        if rep is None:
            fn = lambda mo: 'nas' if mo.group(0).islower() else 'NAS'
        elif callable(rep):
            fn = rep
        else:
            fn = (lambda mo, r=rep: mo.expand(r)) if '\\' in rep else (lambda mo, r=rep: r)
        text, n = re.subn(pat, fn, text)
        if n:
            label = 'NAS name' if rep is None else ('private IP/net' if callable(rep) else re.sub(r'\\\d', '', rep))
            report[str(f.relative_to(out))][label] += n
    f.write_text(text)

# Leak check: anything still site-specific fails the run (line numbers only, never the line)
leaks = [('private IP', r'\b(?:192\.168|10\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b'),
         ('GPU UUID', r'\bGPU-[0-9a-f]{8}-'),
         ('API key', r'\b(?:sk-[A-Za-z0-9_-]{12,}|xai-[A-Za-z0-9]{12,}|AIza[0-9A-Za-z_-]{12,}|gh[pousr]_[A-Za-z0-9]{12,})'),
         ('JWT/token', r'\beyJ[\w-]{20,}'),
         ('email', r'(?<![\w.+-])(?!you@example\.com)(?![\w.+-]+@users\.noreply\.github\.com)[\w.+-]*@[\w-]+\.[A-Za-z]{2,}'),
         ('password in URL', r'://[^/\s:@]+:(?!\$\{|<REDACTED>)[^@\s/]+@')] + leak_words
# any hostname with a common public TLD that isn't on the allowlist
ALLOW_HOSTS = r'(?:[\w-]+\.)*(?:example\.com|github\.com|githubusercontent\.com|docker\.com|docker\.io|ghcr\.io|lscr\.io|quay\.io|ollama\.com|nvidia\.com|ubuntu\.com|canonical\.com|anthropic\.com|googleapis\.com|google\.com|x\.ai|openai\.com|cloudflare\.com|cloudflareaccess\.com|searxng\.org|n8n\.io|home-assistant\.io|huggingface\.co|pytorch\.org|python\.org|pypi\.org|debian\.org|archive\.org|wikipedia\.org|duckduckgo\.com|bing\.com|brave\.com|startpage\.com|qwant\.com|mojeek\.com|litellm\.ai|berri\.ai|mosquitto\.org|eclipse\.org|fwupd\.org|lvfs\.org|microsoft\.com|docker\.internal)'
leaks.append(('public hostname', r'(?<![\w.@-])(?!' + ALLOW_HOSTS + r'\b)(?:[A-Za-z0-9-]+\.)+(?:com|net|org|io|tech|dev|app|ai|me|co|us|xyz|cloud|online|site|info|biz|duckdns\.org|ddns\.net)\b(?![\w-])'))
if len(user) >= 3 and user not in ('root', 'ubuntu'):
    leaks.append(('username', r'(?i)\b' + re.escape(user) + r'\b'))
found, suspicious = [], []
for f in files:
    for i, line in enumerate(f.read_text(errors='replace').splitlines(), 1):
        line = line.replace('172.16.0.0/12', '')            # generic Docker range is allowed
        for name, p in leaks:
            if re.search(p, line): found.append(f'{f.relative_to(out)}:{i}: {name}')
        for tok in re.findall(r'(?<!sha256:)(?<![\w/.-])[A-Za-z0-9+/_=-]{32,}', line):
            if re.search(r'\d', tok) and re.search(r'[a-z]', tok) and re.search(r'[A-Z]', tok) and '/' not in tok.strip('/'):
                suspicious.append(f'{f.relative_to(out)}:{i}'); break

with open(out / 'scrub-report.txt', 'w') as r:
    for f, c in report.items():
        r.write(f'{f}\n' + ''.join(f'    {n:3d} x {rep}\n' for rep, n in c.most_common()))
    r.write(f'\nPrivate IPs/nets replaced with numbered placeholders: {len(priv)}\n')
    r.write(f'NAS names scrubbed: {len(nas_names)}   domain found: {"yes" if domain else "no"}\n')
    if suspicious:
        r.write('\nREVIEW (long opaque strings; check by hand):\n' + '\n'.join(suspicious) + '\n')
    r.write('\nLEAK CHECK: ' + ('PASS\n' if not found else 'FAIL\n' + '\n'.join(found) + '\n'))
print(open(out / 'scrub-report.txt').read())
sys.exit(1 if found else 0)
PY
chown -R "$USER_NAME": "$OUT"
echo "Staging folder: $OUT"
exit $rc
