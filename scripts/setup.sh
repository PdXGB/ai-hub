#!/usr/bin/env bash
# setup.sh - configure a ai-hub server from this repo.
#
# Run from the repo clone, after Ubuntu, the NVIDIA driver, Docker and the
# NVIDIA container toolkit are installed and the model/data/backup disks are
# mounted (docs/02):
#
#   sudo bash scripts/setup.sh
#
# What it does
#   /srv/ai               compose.yaml, .env (secrets generated, the rest asked),
#                         litellm/config.yaml (budgets), searxng/settings.yml (key),
#                         update-image.sh, monthly-update.sh
#                         (/srv/ai is owned by the sudo user; .env stays mode 600)
#   /srv/models, /srv/data, /srv/backup   data directories, /srv/backup/pre-update
#   /etc/aihub/gpu.env GPU UUIDs + power limit for the systemd units
#   /usr/local/bin        aihub-backup, aihub-mon, comfyui-idle-free
#   /etc/...              docker daemon.json (log rotation merged into an existing one),
#                         unattended-upgrades NVIDIA blacklist,
#                         aihub-mon.env, MQTT login for aihub-mon (optional)
#   systemd               units + drop-ins installed; timers enabled
# It does NOT start the stack or pull models; it prints those steps at the end.
#
# Re-runs are safe: existing files are never overwritten. Missing files are
# created, empty or missing .env variables are filled in, and anything that
# differs from the repo is listed for you to review. One exception: if
# /etc/docker/daemon.json lacks log-driver/log-opts, they are added (the
# original is kept as daemon.json.pre-setup).
#
# Every question can be answered ahead of time with an environment variable of
# the same name (e.g. ANTHROPIC_API_KEY=sk-ant-... sudo -E bash scripts/setup.sh).
# Without a terminal, defaults are used.
#
# Options
#   --root DIR   write everything under DIR instead of / (testing; no systemctl)
#   -h, --help   this text
set -euo pipefail

ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$(realpath -m "$2")"; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 1 ;;
  esac
done

REPO="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$REPO/compose/compose.yaml" ] || { echo "Run this from the ai-hub repo (compose/compose.yaml not found)." >&2; exit 1; }
if [ -z "$ROOT" ] && [ "$(id -u)" -ne 0 ]; then echo "Run with sudo." >&2; exit 1; fi
command -v python3 >/dev/null || { echo "python3 is required." >&2; exit 1; }

AI="$ROOT/srv/ai"
RUN_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
INTERACTIVE=0; [ -t 0 ] && INTERACTIVE=1
CREATED=(); KEPT=(); DIFFERS=(); NOTES=()

say()  { printf '%s\n' "$*"; }
hdr()  { printf '\n== %s\n' "$*"; }
gen()  { python3 -c "import secrets; print(secrets.token_hex(${1:-24}))"; }

# ask VAR "question" "default" [secret]  -> sets VAR (env var wins, then prompt, then default)
ask() {
  local var=$1 q=$2 def=${3:-} secret=${4:-} ans
  if [ -n "${!var+x}" ]; then return; fi
  if [ "$INTERACTIVE" = 1 ]; then
    if [ -n "$secret" ]; then
      read -r -s -p "  $q${def:+ [$def]}: " ans; echo
    else
      read -r -p "  $q${def:+ [$def]}: " ans
    fi
    printf -v "$var" '%s' "${ans:-$def}"
  else
    printf -v "$var" '%s' "$def"
  fi
}

# place SRC DEST [mode]: install if missing, otherwise keep and report differences
place() {
  local src=$1 dest=$2 mode=${3:-644}
  if [ -e "$dest" ]; then
    if cmp -s "$src" "$dest"; then KEPT+=("$dest"); else DIFFERS+=("$dest  (repo: ${src#$REPO/})"); fi
    return 1
  fi
  install -D -m "$mode" "$src" "$dest"; CREATED+=("$dest"); return 0
}

# place_text DEST mode < content : same, for generated content
place_text() {
  local dest=$1 mode=${2:-644} tmp; tmp=$(mktemp); cat > "$tmp"
  if [ -e "$dest" ]; then
    cmp -s "$tmp" "$dest" && KEPT+=("$dest") || DIFFERS+=("$dest  (generated)"); rm -f "$tmp"; return 1
  fi
  install -D -m "$mode" "$tmp" "$dest"; rm -f "$tmp"; CREATED+=("$dest"); return 0
}

envval() { [ -f "$2" ] && sed -n "s/^$1=//p" "$2" | tail -1 || true; }

# --------------------------------------------------------------------------- detect
hdr "Detecting hardware"
GPU_ROWS=""
if command -v nvidia-smi >/dev/null && GPU_ROWS=$(nvidia-smi --query-gpu=memory.total,uuid,name,power.default_limit --format=csv,noheader,nounits 2>/dev/null); then
  say "$GPU_ROWS" | sed 's/^/  GPU: /'
else
  say "  nvidia-smi not available: GPU UUIDs will be asked for."
  NOTES+=("nvidia-smi didn't run. Install the driver (docs/02) and check /etc/aihub/gpu.env and the GPU_* lines in /srv/ai/.env.")
fi
SORTED=$(printf '%s\n' "$GPU_ROWS" | grep -v '^$' | sort -t, -k1,1nr || true)
DET_MAIN=$(printf '%s\n' "$SORTED" | sed -n 1p | awk -F', ' '{print $2}' || true)
DET_HA=$(printf '%s\n' "$SORTED" | sed -n 2p | awk -F', ' '{print $2}' || true)
DET_HA=${DET_HA:-$DET_MAIN}
DET_PL=$(printf '%s\n' "$SORTED" | sed -n 1p | awk -F', ' 'NF>=4 {printf "%d", $4}' || true)
DET_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1 || true)
DET_NET=$(ip -o -4 addr show 2>/dev/null | awk -v ip="$DET_IP" '{split($4,a,"/"); if (a[1]==ip) print $4}' | head -1 || true)
[ -n "$DET_NET" ] && DET_NET=$(python3 -c "import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)" "$DET_NET")
say "  LAN IP: ${DET_IP:-unknown}  subnet: ${DET_NET:-unknown}  service user: $RUN_USER"

# --------------------------------------------------------------------------- questions
EXISTING_ENV="$AI/.env"
need() { [ -z "$(envval "$1" "$EXISTING_ENV")" ]; }   # true if .env lacks a value for $1

hdr "Questions (Enter keeps the default; blank skips optional items)"
need AIHUB_LAN_IP  && ask AIHUB_LAN_IP  "LAN IP for services Home Assistant uses (LiteLLM, Whisper, Piper)" "$DET_IP"
need GPU_MAIN_UUID && ask GPU_MAIN_UUID "Main GPU UUID (LLMs, ComfyUI)" "$DET_MAIN"
need GPU_HA_UUID   && ask GPU_HA_UUID   "HA GPU UUID (Whisper, ollama-ha; same as main if one GPU)" "${DET_HA:-${GPU_MAIN_UUID:-}}"
need N8N_HOSTNAME  && ask N8N_HOSTNAME  "Public hostname for n8n via Cloudflare (e.g. n8n.example.com)" ""
need CHAT_HOSTNAME && ask CHAT_HOSTNAME "Public hostname for Open WebUI (e.g. chat.example.com)" ""
need TZ            && ask TZ            "Time zone for the containers" "$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo UTC)"
need CLOUDFLARE_TUNNEL_TOKEN && ask CLOUDFLARE_TUNNEL_TOKEN "Cloudflare tunnel token (blank = set up later)" "" secret
need ANTHROPIC_API_KEY && ask ANTHROPIC_API_KEY "Anthropic API key (blank = skip Claude)" "" secret
need GEMINI_API_KEY    && ask GEMINI_API_KEY    "Gemini API key (blank = skip Gemini)" "" secret
need XAI_API_KEY       && ask XAI_API_KEY       "xAI API key (blank = skip Grok)" "" secret
[ -e "$AI/litellm/config.yaml" ] || { ask CLOUD_BUDGET "Monthly cloud budget, all providers, USD" "50"; ask ROUTE_BUDGET "Monthly budget per cloud route, USD" "25"; }
[ -e "$ROOT/etc/aihub/gpu.env" ] || ask GPU_MAIN_POWER_LIMIT "Main GPU power limit in watts (card default ${DET_PL:-unknown})" "${DET_PL:-}"
[ -e "$ROOT/etc/aihub-mon.env" ] || ask ALLOWED_NETS "Networks allowed to SSH in without an alert (space separated)" "${DET_NET:+$DET_NET }127.0.0.0/8 ::1/128 fe80::/10"
[ -e "$ROOT/etc/aihub-mon.env" ] || ask NAS_BACKUP_DIR "Off-box backup folder (NAS mount; blank = none)" "/mnt/nas/aihub"
if [ ! -e "$ROOT/root/.config/mosquitto_pub" ]; then
  ask MQTT_HOST "MQTT broker for aihub-mon (Home Assistant's LAN IP; blank = skip monitoring)" ""
  if [ -n "$MQTT_HOST" ]; then ask MQTT_USER "MQTT username" "aihub"; ask MQTT_PASSWORD "MQTT password" "" secret; fi
fi
CLOUD_BUDGET=${CLOUD_BUDGET:-50}

# --------------------------------------------------------------------------- /srv/ai
hdr "Writing /srv/ai"
install -d -m 755 "$AI" "$AI/litellm" "$AI/searxng"
place "$REPO/compose/compose.yaml" "$AI/compose.yaml" || true
place "$REPO/scripts/update-image.sh"  "$AI/update-image.sh" 755 || true
place "$REPO/scripts/monthly-update.sh" "$AI/monthly-update.sh" 755 || true

# .env: generated secrets + answers; fill gaps only
GEN_VARS="LITELLM_MASTER_KEY LITELLM_SALT_KEY LITELLM_DB_PASSWORD WEBUI_SECRET_KEY N8N_ENCRYPTION_KEY N8N_DB_PASSWORD"
for v in $GEN_VARS; do
  if need "$v" && [ -z "${!v:-}" ]; then
    case $v in LITELLM_MASTER_KEY|LITELLM_SALT_KEY) printf -v "$v" 'sk-%s' "$(gen 24)" ;; *) printf -v "$v" '%s' "$(gen 24)" ;; esac
  fi
done
export_vars=$(grep -oE '^[A-Z0-9_]+=' "$REPO/compose/.env.example" | tr -d '=')
for v in $export_vars; do export "$v=${!v:-}"; done
ENV_STATUS=$(python3 - "$REPO/compose/.env.example" "$EXISTING_ENV" $export_vars <<'PY'
import os, re, sys
tmpl, dest, names = sys.argv[1], sys.argv[2], sys.argv[3:]
if not os.path.exists(dest):
    out = []
    for line in open(tmpl):
        m = re.match(r'^([A-Z0-9_]+)=', line)
        out.append(f"{m.group(1)}={os.environ.get(m.group(1), '')}\n" if m else line)
    fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.write(fd, "".join(out).encode()); os.close(fd)
    print("created"); sys.exit()
lines = open(dest).read().splitlines(keepends=True)
have = {m.group(1): i for i, l in enumerate(lines) if (m := re.match(r'^([A-Z0-9_]+)=', l))}
filled, added = [], []
for n in names:
    val = os.environ.get(n, '')
    if n in have:
        i = have[n]
        if lines[i].strip() == f"{n}=" and val:
            lines[i] = f"{n}={val}\n"; filled.append(n)
    elif val:
        added.append(f"{n}={val}\n")
if added:
    if lines and not lines[-1].endswith("\n"): lines[-1] += "\n"
    lines += ["\n# added by setup.sh\n"] + added
if filled or added:
    open(dest, "w").writelines(lines)
print("filled: " + " ".join(filled + [a.split('=')[0] for a in added]) if filled or added else "kept")
PY
)
chmod 600 "$EXISTING_ENV"
case "$ENV_STATUS" in created) CREATED+=("$EXISTING_ENV") ;; kept) KEPT+=("$EXISTING_ENV") ;; *) CREATED+=("$EXISTING_ENV  ($ENV_STATUS)") ;; esac
for v in $export_vars; do unset "$v"; done
for v in AIHUB_LAN_IP GPU_MAIN_UUID GPU_HA_UUID; do
  [ -n "$(envval "$v" "$EXISTING_ENV")" ] || NOTES+=("$v is empty in /srv/ai/.env: set it before docker compose up (the stack won't start without it).")
done

# litellm config with budgets
if [ ! -e "$AI/litellm/config.yaml" ]; then
  place_text "$AI/litellm/config.yaml" 644 < <(python3 - "$REPO/compose/litellm/config.example.yaml" "$CLOUD_BUDGET" "${ROUTE_BUDGET:-25}" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
s = re.sub(r'(?m)^(\s{6}max_budget:) \d+', r'\g<1> ' + sys.argv[3], s)        # per route
s = re.sub(r'(?m)^(\s{2}max_budget:) \d+', r'\g<1> ' + sys.argv[2], s)        # global
sys.stdout.write(s)
PY
) || true
else KEPT+=("$AI/litellm/config.yaml"); fi

# searxng settings with a fresh secret
if [ ! -e "$AI/searxng/settings.yml" ]; then
  place_text "$AI/searxng/settings.yml" 644 < <(sed "s/GENERATED_BY_SETUP/$(gen 32)/" "$REPO/compose/searxng/settings.example.yml") || true
else KEPT+=("$AI/searxng/settings.yml"); fi

# /srv/ai belongs to the user who runs docker compose and the update scripts
if [ "$RUN_USER" != root ] && id -u "$RUN_USER" >/dev/null 2>&1; then
  chown -R "$RUN_USER": "$AI"; say "  /srv/ai owned by $RUN_USER"
fi

# --------------------------------------------------------------------------- data dirs
hdr "Data directories"
for d in srv/models/ollama srv/models/ollama-ha srv/models/comfyui srv/data/litellm-db srv/data/open-webui \
         srv/data/n8n-db srv/data/whisper srv/data/piper srv/backup; do
  [ -d "$ROOT/$d" ] || { install -d -m 755 "$ROOT/$d"; CREATED+=("$ROOT/$d/"); }
done
if [ ! -d "$ROOT/srv/data/n8n" ]; then
  install -d -m 700 -o 1000 -g 1000 "$ROOT/srv/data/n8n"; CREATED+=("$ROOT/srv/data/n8n/ (owner uid 1000 for n8n)")
fi
if [ ! -d "$ROOT/srv/backup/pre-update" ]; then   # update-image.sh backups; it runs as the user
  install -d -m 700 "$ROOT/srv/backup/pre-update"
  if [ "$RUN_USER" != root ] && id -u "$RUN_USER" >/dev/null 2>&1; then chown "$RUN_USER": "$ROOT/srv/backup/pre-update"; fi
  CREATED+=("$ROOT/srv/backup/pre-update/ (owner $RUN_USER, for update-image.sh)")
fi
for m in /srv/models/ollama /srv/models/comfyui /srv/backup; do
  [ -z "$ROOT" ] && ! mountpoint -q "$m" && NOTES+=("$m is not a separate mount. Fine on one disk; see docs/01 and docs/02 for the layout.")
done

# --------------------------------------------------------------------------- host files
hdr "Host files"
if [ ! -e "$ROOT/etc/aihub/gpu.env" ]; then
  [ -n "${GPU_MAIN_UUID:-}" ] || GPU_MAIN_UUID=$(envval GPU_MAIN_UUID "$EXISTING_ENV")
  place_text "$ROOT/etc/aihub/gpu.env" 644 < <(printf 'GPU_MAIN_UUID=%s\nGPU_MAIN_POWER_LIMIT=%s\nCUDA_DEVICE_ORDER=PCI_BUS_ID\nCUDA_VISIBLE_DEVICES=%s\n' \
    "$GPU_MAIN_UUID" "${GPU_MAIN_POWER_LIMIT:-}" "$GPU_MAIN_UUID") || true
  [ -n "${GPU_MAIN_POWER_LIMIT:-}" ] || NOTES+=("GPU_MAIN_POWER_LIMIT is empty in /etc/aihub/gpu.env; nvidia-power-limit.service will fail until you set it.")
else KEPT+=("$ROOT/etc/aihub/gpu.env"); fi

for b in aihub-backup aihub-mon comfyui-idle-free; do place "$REPO/host/bin/$b" "$ROOT/usr/local/bin/$b" 755 || true; done
# daemon.json: nvidia-ctk usually creates it first, so add the log keys to it if they're missing
DJ="$ROOT/etc/docker/daemon.json"
if [ ! -e "$DJ" ]; then
  place "$REPO/host/docker-daemon.json" "$DJ" || true
  NOTES+=("Installed /etc/docker/daemon.json: sudo systemctl restart docker, then cd /srv/ai && docker compose up -d --force-recreate")
else
  DJ_STATUS=$(python3 - "$REPO/host/docker-daemon.json" "$DJ" <<'PY'
import json, shutil, sys
repo, dest = sys.argv[1], sys.argv[2]
want = json.load(open(repo))
try:
    have = json.load(open(dest))
except ValueError:
    print("invalid"); sys.exit()
missing = [k for k in ("log-driver", "log-opts") if k not in have]
if not missing:
    print("same" if have == want else "differs"); sys.exit()
for k in missing:
    have[k] = want[k]
shutil.copy2(dest, dest + ".pre-setup")
open(dest, "w").write(json.dumps(have, indent=2) + "\n")
print("merged " + " ".join(missing))
PY
)
  case "$DJ_STATUS" in
    same) KEPT+=("$DJ") ;;
    differs) DIFFERS+=("$DJ  (repo: host/docker-daemon.json; log keys already set)") ;;
    invalid) NOTES+=("$DJ is not valid JSON; left alone. Fix it and re-run setup.sh.") ;;
    merged*) CREATED+=("$DJ  ($DJ_STATUS; original saved as daemon.json.pre-setup)")
             NOTES+=("Docker log rotation added to /etc/docker/daemon.json: sudo systemctl restart docker, then cd /srv/ai && docker compose up -d --force-recreate") ;;
  esac
fi
place "$REPO/host/51unattended-nvidia" "$ROOT/etc/apt/apt.conf.d/51unattended-nvidia" || true

if [ ! -e "$ROOT/etc/aihub-mon.env" ]; then
  place_text "$ROOT/etc/aihub-mon.env" 600 < <(ALLOWED_NETS="$ALLOWED_NETS" CLOUD_BUDGET="$CLOUD_BUDGET" NAS_BACKUP_DIR="${NAS_BACKUP_DIR:-}" \
    python3 - "$REPO/host/aihub-mon.env.example" <<'PY'

import os, re, sys
s = open(sys.argv[1]).read()
s = re.sub(r'(?m)^ALLOWED_NETS=.*$', 'ALLOWED_NETS="%s"' % os.environ["ALLOWED_NETS"], s)
s = re.sub(r'(?m)^CLOUD_BUDGET=.*$', 'CLOUD_BUDGET=%s' % os.environ["CLOUD_BUDGET"], s)
s = re.sub(r'(?m)^NAS_BACKUP_DIR=.*$', 'NAS_BACKUP_DIR=%s' % os.environ["NAS_BACKUP_DIR"], s)
sys.stdout.write(s)
PY
) || true
else KEPT+=("$ROOT/etc/aihub-mon.env"); fi

MQTT_OK=0
if [ -e "$ROOT/root/.config/mosquitto_pub" ]; then MQTT_OK=1; KEPT+=("$ROOT/root/.config/mosquitto_pub")
elif [ -n "${MQTT_HOST:-}" ]; then
  place_text "$ROOT/root/.config/mosquitto_pub" 600 < <(printf -- '-h %s\n-p 1883\n-u %s\n-P %s\n' "$MQTT_HOST" "${MQTT_USER:-aihub}" "${MQTT_PASSWORD:-}") && MQTT_OK=1
else NOTES+=("No MQTT broker given: aihub-mon is installed but its timers stay off. Re-run setup.sh with MQTT_HOST set to enable it.")
fi
command -v mosquitto_pub >/dev/null || NOTES+=("mosquitto_pub not found: sudo apt install mosquitto-clients (needed by aihub-mon).")

# --------------------------------------------------------------------------- systemd
hdr "systemd units"
SD="$ROOT/etc/systemd/system"; NEW_UNITS=()
for u in "$REPO"/systemd/*.service "$REPO"/systemd/*.timer; do
  n=$(basename "$u")
  if [ "$n" = comfyui.service ]; then
    place_text "$SD/$n" 644 < <(sed "s/^User=<user>$/User=$RUN_USER/" "$u") && NEW_UNITS+=("$n") || true
  else
    place "$u" "$SD/$n" && NEW_UNITS+=("$n") || true
  fi
done
for d in "$REPO"/systemd/*.d; do
  for f in "$d"/*.conf; do place "$f" "$SD/$(basename "$d")/$(basename "$f")" || true; done
done

if [ -z "$ROOT" ]; then
  systemctl daemon-reload
  for n in "${NEW_UNITS[@]}"; do
    case "$n" in
      nvidia-power-limit.service) [ -n "${GPU_MAIN_POWER_LIMIT-x}" ] && systemctl enable --now "$n" || true ;;   # skip if asked and left empty
      aihub-backup.timer|comfyui-idle-free.timer) systemctl enable --now "$n" ;;
      aihub-mon.timer|aihub-mon-daily.timer|aihub-mon-listen.service) [ "$MQTT_OK" = 1 ] && systemctl enable --now "$n" ;;
      comfyui.service)
        if [ -x /srv/comfyui/.venv/bin/python ]; then systemctl enable --now "$n"
        else NOTES+=("comfyui.service installed but not enabled: install ComfyUI into /srv/comfyui/.venv first, then: sudo systemctl enable --now comfyui"); fi ;;
    esac
  done
  [ " ${NEW_UNITS[*]} " = "  " ] || say "  enabled what applies; installed: ${NEW_UNITS[*]}"
else
  say "  (--root: systemctl skipped)"
fi

# --------------------------------------------------------------------------- summary
hdr "Summary"
[ ${#CREATED[@]} -eq 0 ] || { say "Created:"; printf '  + %s\n' "${CREATED[@]}"; }
[ ${#KEPT[@]} -eq 0 ]    || say "Unchanged (already present): ${#KEPT[@]} files"
[ ${#DIFFERS[@]} -eq 0 ] || { say "Kept as-is, but different from the repo (review with diff -u):"; printf '  ~ %s\n' "${DIFFERS[@]}"; }
[ ${#NOTES[@]} -eq 0 ]   || { say "Notes:"; printf '  ! %s\n' "${NOTES[@]}"; }
cat <<EOF

Next steps
  cd /srv/ai && docker compose up -d
  docker exec ai-ollama-1 ollama pull huihui_ai/Qwen3.8-abliterated:27b   # local-fast (or your choice)
  docker exec ai-ollama-1 ollama pull nomic-embed-text                    # embed
  docker exec ai-ollama-ha-1 ollama pull qwen3:8b                         # local-ha
  Then: LiteLLM virtual keys (docs/03), Home Assistant (docs/05), GPU checks (docs/04).
Secrets are in /srv/ai/.env (mode 600). Back it up; the n8n key can't be recovered.
EOF
