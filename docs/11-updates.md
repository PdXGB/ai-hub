# 11 — Updates

Nothing on groot updates itself in a way that can break the GPU stack. Security patches install automatically; the kernel, the NVIDIA driver and every container image move only when you run the monthly routine, one step at a time, with a backup and a way back.

| Layer | How it updates | Automatic? |
|---|---|---|
| Ubuntu packages | unattended-upgrades | Yes, except `linux-*`, `nvidia-*`, `libnvidia-*` |
| Kernel + NVIDIA driver | `apt full-upgrade` + reboot | Monthly, by hand |
| Container images | [`scripts/update-image.sh`](../scripts/update-image.sh) | Monthly, by hand |
| Ollama models | `ollama pull` | Monthly, optional |
| Firmware | `fwupdmgr` (UEFI dbx, drives); BIOS via MSI M-Flash | Checked daily, installed by hand |

[`scripts/monthly-update.sh`](../scripts/monthly-update.sh) runs all of it in order. Both scripts live in `/srv/ai` on the server (`setup.sh` puts them there).

## 1. Kernel and NVIDIA: blacklist, don't hold

[`host/51unattended-nvidia`](../host/51unattended-nvidia) keeps `linux-`, `nvidia-` and `libnvidia-` out of unattended-upgrades. The driver's kernel modules are Ubuntu's prebuilt, signed packages that already move with the kernel; the risk is the userspace libraries changing in the background while the old module is loaded ("Driver/library version mismatch" until a reboot). The blacklist removes only that, and `apt-mark hold` isn't needed. Details: [docs/02](02-ubuntu-nvidia.md#7-updates-blacklist-kernel-and-nvidia-dont-hold-them).

## 2. Containers: `update-image.sh`

Every image is pinned (`tag@sha256:digest`, or a fixed version tag), so `docker compose pull` changes nothing ([docs/03](03-docker-stack.md#10-image-pinning)). `update-image.sh` moves one service at a time to the newest build of its tag and re-pins it.

```bash
cd /srv/ai
./update-image.sh --list                       # services and their pinned images
./update-image.sh --check                      # which have newer builds (pulls, changes nothing)
./update-image.sh --all                        # update them one by one, prompting before and after each
./update-image.sh open-webui                   # one service, newest build of its tag
./update-image.sh ollama ollama/ollama:0.41.2  # move a service to a new tag
./update-image.sh open-webui --rollback        # back to the image before its last update
```

For each service it:

1. pulls the newest build of the pinned tag and compares **image IDs** with what's running, so a version tag like `ollama:0.40.11` isn't "updated" just to add a digest (which would restart Ollama and unload the pinned model);
2. backs up `compose.yaml` and the service's data to `/srv/backup/pre-update/<timestamp>-<service>/` (mode 700; the newest 3 per service are kept): `webui.db` for Open WebUI, `pg_dumpall` for LiteLLM, n8n and both databases, the config for LiteLLM and SearXNG;
3. writes the new `tag@digest` into `compose.yaml` (keeping a `compose.yaml.bak-<timestamp>`), validates it with `docker compose config`, and restarts only that service;
4. health-checks it: LiteLLM `/health/liveliness`, Open WebUI `/api/version` (allow about 60 s for migrations), SearXNG a JSON search, Ollama and n8n `--version`, and for `ollama-ha` it reloads the HA model;
5. logs old and new images to `/srv/ai/update-log.txt`, which `--rollback` reads.

`--all` runs lowest risk first: `searxng`, `piper`, `whisper`, `cloudflared`, `litellm-db`, `n8n-db`, `ollama`, `ollama-ha`, `litellm`, `n8n`, `open-webui`. Before each: apply, skip or quit. After each: healthy, roll back or quit.

Guard rails:

- It refuses to change a **database's** Postgres tag. Major Postgres upgrades need a dump and restore.
- It doesn't prune old images, so a rollback is instant.
- Rolling back Open WebUI, LiteLLM or n8n restores the image, not the data. If the update ran database migrations, also restore the database backup from `/srv/backup/pre-update`.

## 3. The monthly routine

```bash
/srv/ai/monthly-update.sh
```

| Step | Does |
|---|---|
| 1. Containers | `./update-image.sh --all` |
| 2. Ollama models | Optional: re-pulls every model in `ai-ollama-1`; only changed layers download, but `gpt-oss:120b` can be large |
| 3. Ubuntu | `apt update`, lists upgradable packages, then `apt full-upgrade` on confirmation (kernel and NVIDIA included) |
| 4. Firmware | Report only: `fwupdmgr get-upgrades`. Install with `sudo fwupdmgr update` |
| 5. Reboot | Shows why a reboot is required, offers it |

After the reboot:

```bash
nvidia-smi && docker compose -f /srv/ai/compose.yaml ps && sudo /usr/local/bin/groot-mon --dry-run
```

`apt full-upgrade` rewrites files groot-mon watches (systemd units, for example), so expect a security alert. Check what changed, then acknowledge it ([docs/09](09-monitoring.md#2-security-tripwires)).

## 4. Firmware

- **UEFI Secure Boot revocation list (dbx)** and drive firmware: `fwupdmgr`. groot's dbx went from 20250902 to 20260707 this way, with a clean reboot and the driver intact.
- **BIOS:** MSI M-Flash, not fwupd. fwupd offers no BIOS or ME updates for this board.

## 5. Knowing when updates are waiting

`groot-mon --daily` (04:23 every day) runs `update-image.sh --check`, `apt list --upgradable` and `fwupdmgr get-upgrades`, and publishes the counts to Home Assistant: `APT updates`, `Container updates`, `Firmware updates`, with the lists as attributes. The **Check updates now** button runs the same check on demand. See [docs/09](09-monitoring.md).
