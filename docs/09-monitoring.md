# 09 — Monitoring: groot-mon

[`host/bin/groot-mon`](../host/bin/groot-mon) reports the server's health, AI status, pending updates and a set of security tripwires to Home Assistant over MQTT. groot shows up in HA as a device called **Groot** with sensors, binary sensors and two buttons; a dashboard card and six phone alerts sit on top.

Why MQTT discovery rather than HA's REST API or Glances: the entities persist and belong to a real device, `expire_after` gives offline detection for free, and it carries groot-specific data (loaded Ollama models, LiteLLM spend, compose container states, update checks). groot only **pushes**; no port is opened on it.

## 1. What it checks

| Area | Entities (`sensor.groot_*`, `binary_sensor.groot_*`) |
|---|---|
| System | CPU load and temperature, RAM, root disk, last boot, reboot required |
| GPUs | Main card: temperature, utilization, VRAM, power. HA card: the same as "HA GPU …". `GPU` is off if fewer cards answer than `lspci` sees ([docs/04](04-multi-gpu.md#6-monitoring-two-cards)) |
| Services | ComfyUI unit active, LiteLLM `/health/liveliness`, Ollama reachable, every container in the `ai` compose project (one sensor each, plus "All containers") |
| AI | Models loaded in Ollama (with % on GPU), cloud spend over 30 days per route and as % of the budget (from `LiteLLM_SpendLogs`) |
| Disks | Fullest of `/`, `/srv/models/ollama`, `/srv/models/comfyui`, `/srv/backup`; `Disks` off at 85% |
| Backups | Age of the newest local backup (max 26 h) and NAS copy (max 27 h); `Backups` off if either is missing or stale ([docs/10](10-backups.md)) |
| Updates | APT packages, container images with newer builds (`update-image.sh --check`), firmware (`fwupdmgr`) |
| Security | Tripwires, below |
| Online | Goes `unavailable` when groot stops publishing for 180 s |

## 2. Security tripwires

| Tripwire | Fires on |
|---|---|
| SSH login from outside `ALLOWED_NETS` | Any accepted login from an address not in your networks |
| SSH brute force | ≥ `SSH_FAIL_ALERT` (10) failed logins in 24 h |
| sudo | Any failed sudo attempt |
| Rogue containers | A running container outside the `ai` compose project |
| New listening ports | Any TCP listener not in the baseline |
| Critical file changes | SHA-256 change to passwd/shadow/group, sudoers, sshd config, `authorized_keys`, cron, systemd units, `ld.so.preload` |

The baseline (ports and file hashes) is in `/var/lib/groot-mon/baseline.json` (mode 600) and is taken on the first run. **Acknowledging** (button, or `sudo groot-mon --accept`) re-takes the baseline **and** moves the SSH/sudo look-back window to now; without that, a brute-force alert would stay on for 24 hours. Rogue-container alerts don't clear on acknowledgement; stop the container.

**Limits.** These are tripwires, not an intrusion detection system. Anyone with root can stop or edit groot-mon. What they can't hide is that it stopped: the "offline" alert still fires. Expect a file-change alert after `apt full-upgrade` (it rewrites units); check what changed, then acknowledge.

## 3. Install

**Home Assistant side**

1. Install the **Mosquitto broker** add-on and the **MQTT** integration (discovery on, the default).
2. Create a dedicated HA user for groot's MQTT login; the Mosquitto add-on authenticates against HA users.

Connect by HA's **LAN address**, port 1883. A Cloudflare tunnel carries HTTP(S) only, not MQTT.

**groot side.** [`setup.sh`](../scripts/setup.sh) asks for the broker address, user and password. It writes them to `/root/.config/mosquitto_pub` (mode 600, a `mosquitto_pub` options file), installs `groot-mon`, `/etc/groot-mon.env` and the units, and enables the timers. Without a broker it installs everything but leaves the timers off.

```bash
sudo apt install mosquitto-clients                      # setup.sh reminds you if it's missing
sudo HOME=/root mosquitto_pub -t groot/test -m hello    # broker login works?
sudo groot-mon --dry-run                                # print what would be published
```

The device appears under **Settings → Devices & services → MQTT → Groot** within a minute.

| File | Purpose |
|---|---|
| `/usr/local/bin/groot-mon` | The script |
| `/etc/groot-mon.env` (from [`host/groot-mon.env.example`](../host/groot-mon.env.example)) | Allowed networks, thresholds, budget, optional GPU UUIDs, backup paths |
| `/root/.config/mosquitto_pub` | Broker address and login |
| `/var/lib/groot-mon/` | Baseline and last update check |

| Unit | Runs |
|---|---|
| [`groot-mon.timer`](../systemd/groot-mon.timer) | `groot-mon` every 60 s |
| [`groot-mon-daily.timer`](../systemd/groot-mon-daily.timer) | `groot-mon --daily` at 04:23: apt, container and firmware checks |
| [`groot-mon-listen.service`](../systemd/groot-mon-listen.service) | `groot-mon --listen`: waits for the HA buttons |

`ALLOWED_NETS` must include every network you SSH from. Add your VPN range if you use one, or every remote login raises an alert.

## 4. Buttons

| Button | Sends | Does |
|---|---|---|
| Acknowledge alerts | `accept` on `groot/cmd` | Re-baselines and clears SSH/sudo alerts, then republishes |
| Check updates now | `check_updates` | Runs the daily update check immediately |

The listener accepts exactly those two words and logs anything else. Its last-will message (`groot/listener` = `offline`) greys the buttons out in HA if it isn't running.

Anyone with the broker credentials can press a button, so automation 5 notifies you on **every** acknowledgement. One you didn't make is itself a warning sign. The card's Acknowledge button asks for confirmation.

## 5. Dashboard card and alerts

[`home-assistant/groot-ha-card.yaml`](../home-assistant/groot-ha-card.yaml): built-in cards only, no HACS. **Dashboard → Edit → Add card → Manual**, paste. The gauges assume HA shows °F; the file's header gives the °C values.

[`home-assistant/automations/`](../home-assistant/automations/): **Settings → Automations → Create → Edit in YAML**, one each. Replace `notify.mobile_app_your_phone` with your phone's notify service.

| # | Alert | Trigger |
|---|---|---|
| 1 | Security | A new security alert, or the alert list changes |
| 2 | Offline | No data from groot for 5 min after it went unavailable |
| 3 | Container down | "All containers" off for 5 min; lists which |
| 4 | GPU problem | `GPU` off for 3 min (driver/library mismatch, a card off the bus) |
| 5 | Alerts acknowledged | Every acknowledgement |
| 6 | Service, disk or backup | ComfyUI, LiteLLM, Disks or Backups off for 10 min |
