# 10 — Backups

Nightly, two copies: one on the server's own backup drive, one on a NAS. Models are left out; they can be downloaded again.

Files: [`host/bin/aihub-backup`](../host/bin/aihub-backup), [`systemd/aihub-backup.service`](../systemd/aihub-backup.service), [`systemd/aihub-backup.timer`](../systemd/aihub-backup.timer). `setup.sh` installs all three and enables the timer.

## 1. What's backed up

Each night `aihub-backup` writes a dated folder, `/srv/backup/YYYY-MM-DD/`:

| File | Contents |
|---|---|
| `litellm-db.sql.gz` | `pg_dump` of LiteLLM's database (keys, spend logs), taken through `docker compose exec`, so it's consistent while running |
| `n8n-db.sql.gz` | `pg_dump` of n8n's database (workflows, encrypted credentials) |
| `aihub-config.tar.gz` | Configs, secrets and app data (list below) |

The tar archive holds:

- `/srv/ai`: compose, **`.env`**, LiteLLM and SearXNG configs, update scripts
- `/srv/data/open-webui`, `/srv/data/n8n`: app data (Open WebUI's chats, users, knowledge; n8n's files)
- `/srv/comfyui/user`, `/srv/comfyui/custom_nodes`: ComfyUI workflows and settings, custom nodes
- `/etc/docker/daemon.json`, `/etc/netplan`, `/etc/fstab`, `/etc/apt/apt.conf.d/51unattended-nvidia`
- `/etc/aihub` (`gpu.env`), the systemd units and drop-ins (ComfyUI, power limit, idle-free, persistenced, `aihub-*`)
- `/usr/local/bin/comfyui-idle-free`, `aihub-backup`, `aihub-gpu-power`, `aihub-mon`; `/etc/aihub-mon.env`, `/var/lib/aihub-mon`, and aihub-mon's MQTT login (`/root/.config/mosquitto_pub`)

Skipped: the raw Postgres data folders (the dumps replace them) and everything under `/srv/models`.

**The backups contain every secret on the box** (`.env`, the MQTT login). The script runs `chmod -R go-rwx` on each folder; treat the NAS share the same way.

## 2. Schedule and retention

[`aihub-backup.timer`](../systemd/aihub-backup.timer): daily at 02:30, `Persistent=true` (a run missed while the server was off happens at next boot).

- **Local:** keeps 7 days; older dated folders are deleted.
- **NAS:** `rsync -rt --delete` mirrors `/srv/backup/` to `/mnt/nas/aihub/`, so the NAS also holds the last 7 days. If the share isn't reachable, the run still succeeds locally and logs a warning.

```bash
sudo systemctl start aihub-backup && journalctl -u aihub-backup -n 5    # "Backup OK: /srv/backup/… (size)" and "Copied to NAS"
systemctl list-timers aihub-backup.timer
```

aihub-mon watches both copies: the `Backups` sensor goes off if the newest local folder is older than 26 h or the NAS copy older than 27 h, and alert 6 fires ([docs/09](09-monitoring.md)). Paths and limits are in `/etc/aihub-mon.env` (`BACKUP_DIR`, `NAS_BACKUP_DIR`, `BACKUP_MAX_AGE_H`, `NAS_MAX_AGE_H`).

## 3. The NAS mount

The share is a shared folder on a Synology NAS ([docs/01](01-hardware.md#network-storage-synology-nas)), mounted over SMB at `/mnt/nas` on first access by a systemd automount. The `/etc/fstab` line:

```
//<NAS>/<share>  /mnt/nas  cifs  credentials=<credentials file>,vers=3.0,uid=0,gid=0,file_mode=0600,dir_mode=0700,_netdev,nofail,x-systemd.automount  0 0
```

| Option | Why |
|---|---|
| `credentials=` | The NAS login lives in a root-only file (`chmod 600`, e.g. under `/root`), not in fstab |
| `uid=0,gid=0,file_mode=0600,dir_mode=0700` | Only root can read the copies; they contain every secret on the box |
| `_netdev,nofail` | Wait for the network, and don't block boot if the NAS is down |
| `x-systemd.automount` | systemd mounts it on first access |

The server logs in with a dedicated NAS account used only for backups.

```bash
sudo mkdir -p /mnt/nas
sudo systemctl daemon-reload && sudo systemctl restart mnt-nas.automount
ls /mnt/nas && sudo mkdir -p /mnt/nas/aihub
```

**Rotating the NAS password:** change it in DSM, rewrite the credentials file, then restart the mount through systemd. A plain `mount` fails with "busy" because the automount holds the path:

```bash
sudo systemctl stop mnt-nas.mount && sudo systemctl restart mnt-nas.automount
ls /mnt/nas/aihub                                       # triggers the mount
```

(The unit names come from the mount path: `/mnt/nas` → `mnt-nas.*`.)

## 4. Restore

Tested on this build: the n8n database dump restored into a scratch container, and a single file pulled out of the config archive. Neither touches anything live. Restoring over the running stack hasn't been tested.

Each night's folder holds root-only files, so run these as root (or with `sudo`). Pick a backup:

```bash
B=$(ls -1d /srv/backup/20* | tail -1); sudo ls -la "$B"      # newest; or /mnt/nas/aihub/<date>
```

### Database dump into a scratch Postgres

Same major version as the live database (`postgres:17`), no ports, no volume:

```bash
docker run -d --name restore-test -e POSTGRES_USER=n8n -e POSTGRES_PASSWORD=restoretest -e POSTGRES_DB=n8n postgres:17
until docker logs restore-test 2>&1 | grep -q 'init process complete'; do sleep 1; done
until docker exec restore-test pg_isready -U n8n -q; do sleep 1; done

sudo gunzip -c "$B/n8n-db.sql.gz" | docker exec -i restore-test psql -q -U n8n -d n8n -v ON_ERROR_STOP=1 && echo "RESTORE OK"

# compare with live: workflows, credentials
docker exec restore-test psql -U n8n -d n8n -tA -c 'SELECT count(*) FROM workflow_entity' -c 'SELECT count(*) FROM credentials_entity'
docker exec ai-n8n-db-1  psql -U n8n -d n8n -tA -c 'SELECT count(*) FROM workflow_entity' -c 'SELECT count(*) FROM credentials_entity'

docker rm -f restore-test
```

- Wait for `init process complete` (the image creates the database on first start) and `pg_isready` before restoring.
- `ON_ERROR_STOP=1` makes a bad dump fail loudly instead of half-loading.
- `litellm-db.sql.gz` should restore the same way with `litellm` as user and database; only the n8n dump has been tested.
- While the container runs, aihub-mon raises a **rogue container** alert ([docs/09](09-monitoring.md#2-security-tripwires)); it clears when the container is removed.

### One file from `aihub-config.tar.gz`

Paths are stored without the leading `/`. Extract into a scratch folder, never over `/`:

```bash
mkdir -p ~/restore-test
sudo tar -tzf "$B/aihub-config.tar.gz" | grep compose            # find the member name
sudo tar -xzf "$B/aihub-config.tar.gz" -C ~/restore-test srv/ai/compose.yaml
sudo diff ~/restore-test/srv/ai/compose.yaml /srv/ai/compose.yaml
sudo rm -rf ~/restore-test                                        # the archive holds .env and other secrets
```

A difference just means the file changed after that night's backup. On this build the archive is about 850 MB and 330 entries.

## 5. Separate: pre-update backups

`update-image.sh` makes its own backup before each container update (compose file, plus the service's database or data) under `/srv/backup/pre-update/<timestamp>-<service>/`, owner-only (mode 700). It keeps the newest 3 per service (`KEEP_BACKUPS`). The folder doesn't start with `20`, so the nightly retention and aihub-mon's age check ignore it; the NAS mirror includes it. See [docs/11](11-updates.md).
