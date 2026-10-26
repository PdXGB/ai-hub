#!/usr/bin/env bash
# update-image.sh — update compose services to the newest build of their tag, pinned by digest.
#
#   ./update-image.sh --list                    show services and their pinned images
#   ./update-image.sh --check                   show which services have updates (pulls, changes nothing)
#   ./update-image.sh --all                     update every service that has an update, one at a time,
#                                               with a health check and a prompt between each
#   ./update-image.sh <service>                 update one service to the newest build of its tag
#   ./update-image.sh <service> <image:newtag>  switch one service to a new tag (e.g. ollama/ollama:0.41.2)
#   ./update-image.sh <service> --rollback      put a service back on the image before its last update
#
# Before each change it backs up compose.yaml and the service's database (where it has one)
# to /srv/backup/pre-update/<timestamp>-<service>/ (mode 700) and keeps the newest
# KEEP_BACKUPS (default 3) per service.
set -euo pipefail

STACK=/srv/ai
COMPOSE="$STACK/compose.yaml"
LOG="$STACK/update-log.txt"
BACKUP_ROOT=/srv/backup/pre-update     # backup drive; groot-backup mirrors it to the NAS
KEEP_BACKUPS=${KEEP_BACKUPS:-3}         # pre-update backups kept per service
# --all order: lowest risk first, Groot's core last. Services not listed run after these.
ORDER=(searxng piper whisper cloudflared litellm-db n8n-db ollama ollama-ha litellm n8n open-webui)
cd "$STACK"

die()  { echo "ERROR: $*" >&2; exit 1; }
ask()  { local a; read -rp "$1 " a </dev/tty; echo "${a,,}"; }
line() { printf '%.0s─' {1..70}; echo; }

# Read or write the image: line of one service block in compose.yaml (keeps comments/formatting).
img() {  # img get <svc> | img set <svc> <ref>
  python3 - "$COMPOSE" "$@" <<'PY'
import re, sys
path, op, svc = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().split("\n")
start = indent = None
try:
    svc_top = next(i for i, l in enumerate(lines) if re.match(r"^services:\s*(#.*)?$", l))
except StopIteration:
    sys.exit("no top-level services: key in compose.yaml")
for i in range(svc_top + 1, len(lines)):
    l = lines[i]
    if re.match(r"^\S", l) and not l.startswith("#"):
        break  # left the services: section (e.g. volumes:)
    m = re.match(r"^(\s+)" + re.escape(svc) + r":\s*(#.*)?$", l)
    if m:
        start, indent = i, len(m.group(1)); break
if start is None:
    sys.exit(f"service '{svc}' not found in compose.yaml")
for j in range(start + 1, len(lines)):
    l = lines[j]
    if l.strip() and not l.lstrip().startswith("#") and len(l) - len(l.lstrip()) <= indent:
        break  # reached the next service
    m = re.match(r"^(\s+image:\s*)(['\"]?)([^'\"\s#]+)\2(.*)$", l)
    if m:
        if op == "get":
            print(m.group(3))
        else:
            lines[j] = f"{m.group(1)}{m.group(2)}{sys.argv[4]}{m.group(2)}{m.group(4)}"
            open(path, "w").write("\n".join(lines))
        sys.exit(0)
sys.exit(f"no image: line found for service '{svc}'")
PY
}

services() { docker compose config --services; }

# True if the container is already running exactly this image (same image ID).
# Catches version tags like ollama:0.40.11 or postgres:17 where only the digest notation differs.
running_matches() {  # running_matches <svc> <ref>
  local cid running pulled
  cid=$(docker compose ps -q "$1" 2>/dev/null | head -1)
  [[ -n $cid ]] || return 1
  running=$(docker inspect --format '{{.Image}}' "$cid" 2>/dev/null) || return 1
  pulled=$(docker image inspect --format '{{.Id}}' "${2%@*}" 2>/dev/null) || return 1
  [[ $running == "$pulled" ]]
}

# Pull the newest build of a service's tag and print the new pinned ref (tag@digest).
latest_ref() {  # latest_ref <svc> [image:newtag]
  local svc=$1 arg=${2:-} old base name repo digest
  old=$(img get "$svc")
  base=${arg:-${old%%@*}}
  if [[ $svc == *-db && -n $arg && ${arg%%@*} != "${old%%@*}" ]]; then
    die "refusing to change a database's tag (major Postgres upgrades need a dump/restore)"
  fi
  name=${base##*/}; [[ $name == *:* ]] || base="$base:latest"
  repo=${base%:*}
  docker pull -q "$base" >/dev/null || die "pull failed for $base"
  digest=$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$base" \
           | grep -m1 "^$repo@" | cut -d@ -f2)
  [[ -n $digest ]] || die "couldn't read the pulled digest for $base"
  echo "$base@$digest"
}

backup() {  # backup <svc> <dir>  (dumps contain secrets: owner-only)
  local svc=$1 dir=$2
  ( umask 077
  mkdir -p "$dir"
  cp "$COMPOSE" "$dir/compose.yaml"
  case "$svc" in
    litellm)    cp litellm/config.yaml "$dir/" 2>/dev/null || true
                docker compose exec -T litellm-db sh -c 'pg_dumpall -U "$POSTGRES_USER"' > "$dir/litellm-db.sql" ;;
    n8n)        docker compose exec -T n8n-db sh -c 'pg_dumpall -U "$POSTGRES_USER"' > "$dir/n8n-db.sql" ;;
    open-webui) docker compose cp open-webui:/app/backend/data/webui.db "$dir/webui.db" ;;
    litellm-db|n8n-db)
                docker compose exec -T "$svc" sh -c 'pg_dumpall -U "$POSTGRES_USER"' > "$dir/$svc.sql" ;;
    searxng)    cp searxng/settings.yml "$dir/" 2>/dev/null || true ;;
  esac )
  chmod -R go-rwx "$dir"
  echo "Backup: $dir"
  prune_backups "$svc"
}

prune_backups() {  # prune_backups <svc>: keep the newest $KEEP_BACKUPS backups of one service
  local svc=$1 d n=0
  for d in $(ls -1d "$BACKUP_ROOT"/*-"$svc" 2>/dev/null | sort -r); do
    [[ ${d##*/} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}-${svc}$ ]] || continue
    n=$((n + 1))
    if (( n > KEEP_BACKUPS )); then rm -rf -- "$d" && echo "Pruned: $d"; fi
  done
}

health() {  # health <svc>
  local svc=$1
  echo "Waiting for $svc..."
  sleep 15
  docker compose ps "$svc" --format 'table {{.Name}}\t{{.Status}}'
  case "$svc" in
    litellm)    curl -sf localhost:4000/health/liveliness >/dev/null && echo "LiteLLM: OK" || echo "LiteLLM: NOT RESPONDING" ;;
    open-webui) curl -sf localhost:3000/api/version && echo || echo "Open WebUI: NOT RESPONDING (it can take ~60 s after an update to run migrations)" ;;
    ollama)     docker exec ai-ollama-1 ollama --version ;;
    ollama-ha)  docker exec ai-ollama-ha-1 ollama --version && curl -sf localhost:11435/api/generate -d "{\"model\":\"${HA_MODEL:-qwen3:8b}\",\"keep_alive\":-1}" >/dev/null && echo "HA model loaded" || echo "Ollama-HA: NOT RESPONDING" ;;
    n8n)        docker exec ai-n8n-1 n8n --version ;;
    searxng)    curl -sf 'localhost:8888/search?q=test&format=json' >/dev/null && echo "SearXNG: OK" || echo "SearXNG: NOT RESPONDING" ;;
  esac
}

apply() {  # apply <svc> <old> <new> — back up, write, restart, log, health-check
  local svc=$1 old=$2 new=$3 stamp
  stamp=$(date +%F_%H%M%S)
  backup "$svc" "$BACKUP_ROOT/$stamp-$svc"
  cp "$COMPOSE" "$COMPOSE.bak-$stamp"
  img set "$svc" "$new"
  docker compose config -q || { cp "$COMPOSE.bak-$stamp" "$COMPOSE"; die "compose invalid, restored"; }
  docker compose up -d "$svc"
  printf '%s\t%s\t%s\t%s\n' "$stamp" "$svc" "$old" "$new" >> "$LOG"
  health "$svc"
}

rollback() {  # rollback <svc> [noprompt]
  local svc=$1 cur prev stamp
  cur=$(img get "$svc")
  prev=$(awk -F'\t' -v s="$svc" '$2==s && $4 !~ /rollback/ {p=$3} END {print p}' "$LOG" 2>/dev/null || true)
  [[ -n $prev ]] || die "no previous image for '$svc' in $LOG"
  [[ $prev != "$cur" ]] || die "'$svc' is already on $prev"
  echo "Rolling back $svc"; echo "  from: $cur"; echo "  to:   $prev"
  case "$svc" in open-webui|litellm|n8n)
    echo "  NOTE: if the update ran database migrations, also restore its DB backup from $BACKUP_ROOT." ;;
  esac
  if [[ ${2:-} != noprompt ]]; then [[ $(ask "Proceed? [y/N]") == y ]] || return 1; fi
  stamp=$(date +%F_%H%M%S)
  cp "$COMPOSE" "$COMPOSE.bak-$stamp"
  img set "$svc" "$prev"
  docker compose config -q || { cp "$COMPOSE.bak-$stamp" "$COMPOSE"; die "compose invalid, restored"; }
  docker compose up -d "$svc"
  printf '%s\t%s\t%s\t%s\n' "$stamp" "$svc" "$cur" "$prev (rollback)" >> "$LOG"
  health "$svc"
}

ordered_services() {  # ORDER first, then anything else in compose
  local all; all=$(services)
  for s in "${ORDER[@]}"; do grep -qx "$s" <<<"$all" && echo "$s"; done
  for s in $all; do printf '%s\n' "${ORDER[@]}" | grep -qx "$s" || echo "$s"; done
}

find_updates() {  # prints "svc<TAB>old<TAB>new" for each service with a newer build
  local s old new
  for s in $(ordered_services); do
    old=$(img get "$s")
    printf '  checking %-12s\r' "$s" >&2
    new=$(latest_ref "$s")
    if [[ $new != "$old" ]] && ! running_matches "$s" "$new"; then printf '%s\t%s\t%s\n' "$s" "$old" "$new"; fi
  done
  printf '%-40s\r' "" >&2
  return 0
}

# ---------------------------------------------------------------------------
[[ $# -ge 1 ]] || die "usage: $0 --list | --check | --all | <service> [image:newtag | --rollback]"

case "$1" in
  --list)
    for s in $(ordered_services); do printf '%-12s %s\n' "$s" "$(img get "$s")"; done
    exit 0 ;;

  --check)
    echo "Pulling to check for updates (nothing is changed)..."
    UPD=$(find_updates)
    [[ -n $UPD ]] && { echo "Updates available:"; cut -f1 <<<"$UPD" | sed 's/^/  /'; } || echo "Everything is current."
    exit 0 ;;

  --all)
    echo "Pulling to check for updates..."
    UPD=$(find_updates)
    [[ -n $UPD ]] || { echo "Everything is current."; exit 0; }
    echo "Updates available, in the order they'll run:"
    cut -f1 <<<"$UPD" | sed 's/^/  /'
    [[ $(ask "Start? [y/N]") == y ]] || exit 0
    DONE=(); SKIPPED=(); ROLLED=()
    while IFS=$'\t' read -r -u 3 s old new; do
      line; echo "$s"; echo "  old: $old"; echo "  new: $new"
      case $(ask "Apply? [y]es / [s]kip / [q]uit") in
        y) apply "$s" "$old" "$new"
           case $(ask "Healthy? [y]es continue / [r]ollback / [q]uit") in
             r) rollback "$s" noprompt; ROLLED+=("$s") ;;
             q) DONE+=("$s"); break ;;
             *) DONE+=("$s") ;;
           esac ;;
        q) break ;;
        *) SKIPPED+=("$s") ;;
      esac
    done 3<<<"$UPD"
    line
    echo "Updated:     ${DONE[*]:-none}"
    echo "Skipped:     ${SKIPPED[*]:-none}"
    echo "Rolled back: ${ROLLED[*]:-none}"
    echo "Log: $LOG    Undo one later: $0 <service> --rollback"
    exit 0 ;;
esac

SVC=$1; ARG=${2:-}
services | grep -qx "$SVC" || die "no service named '$SVC'"

if [[ $ARG == --rollback ]]; then rollback "$SVC"; exit 0; fi

OLD=$(img get "$SVC")
echo "Pulling..."
NEW=$(latest_ref "$SVC" "$ARG")
if [[ $NEW == "$OLD" ]] || running_matches "$SVC" "$NEW"; then echo "$SVC is already current ($OLD)"; exit 0; fi
echo; echo "$SVC"; echo "  old: $OLD"; echo "  new: $NEW"
[[ $(ask "Back up and apply? [y/N]") == y ]] || exit 1
apply "$SVC" "$OLD" "$NEW"
echo; echo "If anything's wrong:  $0 $SVC --rollback"
