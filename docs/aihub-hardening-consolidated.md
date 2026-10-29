# AIHub Hardening Package — Consolidated Review & Final Recommendations

This document collects the original hardening proposal, two independent reviews of it, and a consolidated set of non-breaking changes suitable for the existing `PdXGB/ai-hub` stack (RTX 3090 + RTX 2060 12GB, dual Ollama, LiteLLM, Open WebUI, Home Assistant voice pipeline).

Goal: improve observability, voice safety, and backup security without introducing outages or low-value complexity.

---

## 1. Original Proposal (Summary)

The original package suggested:

- Network segmentation (`frontend_net`, `inference_net`, `searxng_net`)
- Redis service + LiteLLM exact-match caching
- DCGM exporter
- LiteLLM `model_group_alias`, global `timeout: 20`, virtual keys
- VRAM free-GB pressure alert (`vram_pressure: high`)
- SearXNG health probe (hardcoded port 8888)
- Age-encrypted backups
- Stricter voice prompt domain guardrails
- HA card additions and automations for VRAM, backup age, and GPU temperature (180 threshold)
- ha-mcp for editing automations and dashboards

---

## 2. First Review — “Nothing Goes In That Breaks the Stack”

| Item | Verdict |
|------|---------|
| Network split | **Skip** — breaks Open WebUI ↔ LiteLLM and Open WebUI ↔ SearXNG |
| dcgm-exporter | **Skip** — nothing consumes it; many fields empty on GeForce |
| Redis + LiteLLM caching | **Skip** — near-zero exact hits on dynamic voice prompts; risk of stale answers |
| Virtual keys | **Defer** — requires Postgres |
| Global `timeout: 20` | **Skip** — cuts off long responses |
| `model_group_alias` / simple-shuffle | **Skip** — unnecessary |
| VRAM pressure alert | **Replace** with free-VRAM info + CPU-spill alert |
| SearXNG probe | **Keep** |
| age encryption | **Keep, with fix** (do not delete plaintext on failure) |
| Voice prompt | **Keep**, plus restrict Assist exposure |
| HA card & automations | **Keep, revised** (modern syntax, `for:` delays) |
| ha-mcp | **Keep**, pin version |
| Hardware notes | **Keep** |

Key alternative proposed: alert on models spilling to CPU (`size_vram < size` from Ollama `/api/ps`) instead of free-VRAM threshold.

---

## 3. Second Review — “Non-Breaking Fixes”

Identified real risks:

- Original network split isolates Open WebUI from LiteLLM → total outage.
- GPU temperature threshold of 180 assumes Fahrenheit; NVIDIA sensors report Celsius → alert never fires.
- SearXNG probe hardcodes port 8888; actual mapping may differ.
- Docker bridge isolation does **not** block RFC1918 egress (SSRF mitigation is incomplete).

Suggested mitigations included multi-homing LiteLLM, making the SearXNG port configurable, and lowering the temperature threshold to ~80 °C. However, this review still retained Redis, DCGM, global timeout, and the sticky VRAM-pressure sensor.

**Correction:** the Celsius point is incomplete. Home Assistant converts `temperature` device-class sensors to the configured unit system, so on an imperial HA install the sensor most likely reads °F. A threshold of 80 on a °F sensor would fire on normal warm-up. Verify the unit in HA before setting the number (§5.7).

---

## 4. Consolidated Recommendation

| Item | Final Decision | Reason |
|------|----------------|--------|
| Network split | **Skip** | Lowest risk; multi-homing still adds complexity with limited SSRF benefit |
| Redis + LiteLLM caching | **Skip** | Dynamic prompts → low hit rate; stale-answer risk |
| DCGM exporter | **Skip** | Nothing scrapes it; limited value on GeForce |
| Global timeout / model aliases | **Skip** | Unnecessary risk and complexity |
| Virtual keys | **Defer** | Needs Postgres |
| VRAM pressure binary | **Replace** | Use free-GB (info) + Ollama CPU-spill check |
| SearXNG probe | **Keep** | Port configurable, no default — probe skipped until set (avoids false "ON") |
| GPU temperature alert | **Keep, fix unit** | Verify unit in HA; 180 if °F (likely, imperial HA), 82 if °C |
| age encryption | **Keep, safer version** | Only delete plaintext after success |
| Voice prompt + Assist exposure | **Keep** | Prompt is soft; real control is HA exposure settings |
| HA card & automations | **Keep, revised** | Free VRAM glance + spill sensors; modern syntax + `for:` |
| ha-mcp | **Keep** | Pin version; start read-only |
| Hardware notes | **Keep** | 3090 for 27–32B Q4/Q5 fully resident; 2060 for always-on voice model |

---

## 5. Recommended Changes (Ready to Apply)

### 5.1 aihub-mon: free VRAM (info) + CPU spill

Placement:
- `import json` goes at the top of the file with the other imports.
- The free-VRAM block goes **inside `gpus()`**, after the existing VRAM calculations (that's where `main` and `ha` exist).
- The spill check is its own function, called alongside `health()`, merging into the same publish dict.

```python
# --- inside gpus(), after existing VRAM calculations ---
# Free VRAM (informational only, no alert)
for prefix, c in (("", main), ("ha_", ha)):
    if c and c.get("mem_total"):
        free_gb = (c["mem_total"] - (c.get("mem_used") or 0)) / 1024.0
        d[f"vram_{prefix}free_gb"] = round(free_gb, 1)
```

```python
# --- new function, called alongside health() ---
OLLAMA_ENDPOINTS = {
    "": CFG.get("OLLAMA_URL", "http://127.0.0.1:11434"),
    "ha_": CFG.get("OLLAMA_HA_URL", ""),
}

def ollama_spill():
    d = {}
    for prefix, url in OLLAMA_ENDPOINTS.items():
        if not url:
            continue
        try:
            with urllib.request.urlopen(f"{url}/api/ps", timeout=5) as r:
                models = json.load(r).get("models", [])
        except Exception:
            # Unreachable: publish nothing for this key so "Ollama down"
            # never reads as "no spill". Reachability belongs to the
            # existing Ollama health checks.
            continue
        spill = any(m.get("size_vram", 0) < m.get("size", 0) for m in models)
        d[f"ollama_{prefix}spill"] = "ON" if spill else "OFF"
    return d
```

### 5.2 SearXNG probe (configurable port, no default)

No default port: if `SEARXNG_PORT` is empty, the probe is skipped. This avoids a false "ON" from some other service answering on a guessed port.

```python
SEARXNG_PORT = CFG.get("SEARXNG_PORT", "")
if SEARXNG_PORT:
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{SEARXNG_PORT}", timeout=5)
        d["searxng_ok"] = "ON"
    except Exception:
        d["searxng_ok"] = "OFF"
```

### 5.3 Environment variables (`/etc/aihub-mon.env` and `.env.example`)

```bash
# Ollama endpoints for spill check (host ports actually published)
OLLAMA_URL=http://127.0.0.1:11434
OLLAMA_HA_URL=

# SearXNG host port (confirm from compose.yaml); empty = probe skipped
SEARXNG_PORT=

# Encrypted backups (age recipient); empty = disabled
BACKUP_AGE_RECIPIENT=
```

### 5.4 Safer age encryption (`host/bin/aihub-backup`)

```bash
if [ -n "${BACKUP_AGE_RECIPIENT:-}" ]; then
  if command -v age >/dev/null 2>&1; then
    if age -r "$BACKUP_AGE_RECIPIENT" -o "$DEST/aihub-config.tar.gz.age" "$DEST/aihub-config.tar.gz"; then
      rm -f "$DEST/aihub-config.tar.gz"
    else
      echo "aihub-backup: age encryption failed, keeping plaintext" >&2
    fi
  else
    echo "aihub-backup: age not installed, keeping plaintext" >&2
  fi
fi
```

**Notes:**
- Confirm what file `sensor.aihub_backup_age` watches before enabling.
- Store the age private key off the host (password manager).

### 5.5 Voice prompt (soft layer)

```text
Control:
- Normal domains (act immediately): light, switch, climate, media_player, input_boolean, scene, script, fan.
- Sensitive domains (require explicit confirmation): lock, cover, alarm_control_panel, shell_command, vacuum.
  For these, first ask "Are you sure? Say yes to confirm" and only call execute_services after a clear yes.
- Never invent entity_ids. Only use entities from the list below.
- Voice input can be misheard. If a command does not match a clear entity, ask again.
```

**Stronger control:** Do not expose locks, covers, alarm panels, or `shell_command` to Assist (Settings → Voice assistants → Expose).

### 5.6 HA card additions (revised)

```yaml
  - type: glance
    columns: 2
    entities:
      - entity: sensor.aihub_vram_free_gb
        name: Main VRAM free
        icon: mdi:memory
      - entity: sensor.aihub_vram_ha_free_gb
        name: HA VRAM free
        icon: mdi:memory

  - type: glance
    show_state: false
    state_color: true
    columns: 3
    entities:
      - entity: binary_sensor.aihub_ollama_spill
        name: Main spill
        icon: mdi:alert
      - entity: binary_sensor.aihub_ollama_ha_spill
        name: HA spill
        icon: mdi:alert
      - entity: binary_sensor.aihub_searxng
        name: Search
        icon: mdi:magnify
```

(Entity IDs depend on aihub-mon MQTT discovery naming — adjust as needed.)

### 5.7 Automations (revised, modern syntax, with delays)

```yaml
alias: AIHub - Model spilling to CPU
triggers:
  - trigger: state
    entity_id:
      - binary_sensor.aihub_ollama_spill
      - binary_sensor.aihub_ollama_ha_spill
    to: "on"
    for: "00:02:00"
actions:
  - action: notify.mobile_app_your_device
    data:
      title: "AIHub model offloading to CPU"
      message: "{{ trigger.to_state.name }} — model doesn't fit in VRAM."
mode: single
```

```yaml
alias: AIHub - Backup Stale
triggers:
  - trigger: numeric_state
    entity_id: sensor.aihub_backup_age
    above: 26
actions:
  - action: notify.mobile_app_your_device
    data:
      title: "AIHub backup is old"
      message: "Local backup is {{ states('sensor.aihub_backup_age') }} hours old."
mode: single
```

```yaml
alias: AIHub - GPU Hot
triggers:
  - trigger: numeric_state
    entity_id:
      - sensor.aihub_gpu_temperature
      - sensor.aihub_ha_gpu_temperature
    above: 180   # °F (imperial HA converts). Check the sensor in HA first; use 82 if it shows °C.
    for: "00:02:00"
actions:
  - action: notify.mobile_app_your_device
    data:
      title: "AIHub GPU hot"
      message: "{{ trigger.to_state.name }} is {{ trigger.to_state.state }}."
mode: single
```

### 5.8 ha-mcp

- Recommended for creating/editing automations, scripts, and Lovelace dashboards.
- Install via HACS custom component or local stdio.
- Pin a specific version instead of `@latest`.
- Start with read-only queries (“list automations”, “show AIHub card”) before any edits.
- Docs: https://homeassistant-ai.github.io/ha-mcp

---

## 6. Pre-Install Checklist

- [ ] Confirm SearXNG host port mapping and set `SEARXNG_PORT` (probe stays off until set)
- [ ] Confirm Ollama host ports for both instances (`OLLAMA_URL`, `OLLAMA_HA_URL`)
- [ ] Confirm existing aihub-mon health checks cover Ollama reachability (spill check stays silent when unreachable)
- [ ] Verify GPU temperature sensor unit in Home Assistant; keep 180 for °F, change to 82 for °C
- [ ] Check which file `sensor.aihub_backup_age` currently watches
- [ ] Install `age`, generate key, store private key off the host
- [ ] Un-expose locks, covers, alarm panels, and shell_command from Assist
- [ ] Pin ha-mcp version and test read-only first
- [ ] Measure free VRAM with current models loaded (informational only)

---

## 7. Hardware Utilization Notes (Unchanged)

- **RTX 3090**: Prefer fully resident Q4_K_M / Q5_K_M of 27B–32B class models. Avoid simultaneous heavy ComfyUI + large LLM loads. 325 W power limit is reasonable.
- **RTX 2060 12 GB**: Keep a small voice model (e.g. qwen3:8b) permanently loaded with `keep_alive: -1`. 170 W limit is fine.
- Pure VRAM residency is the responsiveness goal. 128 GB system RAM is good for the host and occasional offload, but not the preferred path for interactive use.

---

*Consolidated from original proposal + two independent reviews. Prioritizes non-breaking, high-signal changes for the existing dual-GPU homestead stack.*
