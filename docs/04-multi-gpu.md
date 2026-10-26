# 04 — Two GPUs, pinned by UUID

The RTX 3090 runs the big models and ComfyUI. The RTX 2060 runs Home Assistant's always-loaded workloads (Whisper and the `qwen3:8b` voice model in `ollama-ha`), so voice stays fast while the 3090 is busy.

## Rules

1. **One service, one card.** Never split a model across both GPUs. The 2060 sits on a chipset x4 link, so a split model runs at the speed of the slower card over that link.
2. **Pin by UUID, not index.** Index order can differ between boots and between tools (`nvidia-smi` orders by PCI bus, CUDA by speed unless `CUDA_DEVICE_ORDER=PCI_BUS_ID`).
3. **Pin every GPU consumer** before installing the second card: the power-limit service, every container, and native services like ComfyUI. Anything left on "all GPUs" grabs the new card the moment it appears.

## Where the UUIDs live

```bash
nvidia-smi --query-gpu=index,name,uuid,pci.bus_id,memory.total --format=csv
```

| File | Read by | Variables |
|---|---|---|
| `/srv/ai/.env` (from [`compose/.env.example`](../compose/.env.example)) | Docker Compose | `GPU_MAIN_UUID`, `GPU_HA_UUID` |
| `/etc/aihub/gpu.env` (from [`systemd/gpu.env.example`](../systemd/gpu.env.example)) | systemd units | `GPU_MAIN_UUID`, `GPU_MAIN_POWER_LIMIT`, `GPU_HA_UUID`, `GPU_HA_POWER_LIMIT`, `CUDA_DEVICE_ORDER`, `CUDA_VISIBLE_DEVICES` |

[`scripts/setup.sh`](../scripts/setup.sh) detects the cards and writes both. By hand:

```bash
sudo install -d -m 755 /etc/aihub
sudo install -m 644 systemd/gpu.env.example /etc/aihub/gpu.env
sudoedit /etc/aihub/gpu.env          # 3090's UUID: GPU_MAIN_UUID and CUDA_VISIBLE_DEVICES; 2060's: GPU_HA_UUID
```

With a single GPU, set `GPU_HA_UUID` to the same UUID as `GPU_MAIN_UUID` (in both files) and leave `GPU_HA_POWER_LIMIT` empty. Everything still works; the HA services just share the card.

## 1. Power limits: one per card

`nvidia-smi -pl` without `-i` applies to **every** GPU. Once a second card is in, a limit above that card's maximum (325 W vs the 2060's 202 W max) makes the command fail, and the main card may not get its limit either. So every card gets its own limit, by UUID, in `/etc/aihub/gpu.env`:

```bash
GPU_MAIN_UUID=GPU-...
GPU_MAIN_POWER_LIMIT=325
GPU_HA_UUID=GPU-...
GPU_HA_POWER_LIMIT=170
```

An empty limit leaves that card at its stock limit.

[`systemd/nvidia-power-limit.service`](../systemd/nvidia-power-limit.service) runs [`host/bin/aihub-gpu-power`](../host/bin/aihub-gpu-power) at boot:

```ini
[Service]
Type=oneshot
ExecStart=/usr/local/bin/aihub-gpu-power
RemainAfterExit=yes
```

The script runs `nvidia-smi -i <UUID> -pl <watts>` for each card that has a limit. It skips empty limits and a role that points at a card it already set (one GPU: HA is the main card). It tries every card even if one fails, then exits non-zero; `journalctl -u nvidia-power-limit` shows which card. It's a script rather than one `ExecStart=` per card because **systemd doesn't expand `${VAR}` inside `Environment=` lines**, only from `EnvironmentFile=`, and an empty `-pl ""` makes nvidia-smi fail.

**Choosing a value.** `setup.sh` asks once per card. It shows the stock limit and the allowed range (`nvidia-smi -q -d POWER`) and suggests 93% of stock, rounded to 5 W (325 W on a 350 W 3090). Enter takes the suggestion, `stock` leaves the card alone, and values outside the range are refused. Re-runs never change a limit that's already in `gpu.env`.

What the cap costs on the 2060 (`qwen3:8b` in `ollama-ha`, 300-token generation, 3 runs per step):

| Limit | Generation | Peak draw | Prompt processing (~5k tokens, best of 3) |
|---|---|---|---|
| 184 W (stock) | 52.6 tok/s | 188 W | 1286 tok/s |
| **170 W** (set) | 52.4 tok/s | 173 W | 1278 tok/s |
| 155 W | 52.0 tok/s | 157 W | 1248 tok/s |

Token generation is limited by memory bandwidth, so a modest cap costs almost nothing. Whisper wasn't measured.

Change a limit later:

```bash
sudoedit /etc/aihub/gpu.env
sudo systemctl restart nvidia-power-limit
nvidia-smi --query-gpu=name,power.limit,power.default_limit --format=csv
```

## 2. Containers: one compose anchor per card

`count: all` hands every GPU to the container. Replace it with `device_ids`, one anchor per card ([`compose/compose.yaml`](../compose/compose.yaml)):

```yaml
x-gpu: &gpu
  deploy:
    resources:
      reservations:
        devices:
          - driver: nvidia
            device_ids: ["${GPU_MAIN_UUID}"]
            capabilities: [gpu]

x-gpu-ha: &gpu_ha
  deploy:
    resources:
      reservations:
        devices:
          - driver: nvidia
            device_ids: ["${GPU_HA_UUID}"]
            capabilities: [gpu]

services:
  ollama:
    <<: *gpu        # 3090
  whisper:
    <<: *gpu_ha     # 2060
```

Check before starting anything, then confirm from inside the container:

```bash
cd /srv/ai
docker compose config | grep -B2 -A6 device_ids     # UUIDs filled in, no "all"
docker compose up -d
docker exec ai-whisper-1 nvidia-smi -L              # lists only the 2060 (same for ai-ollama-ha-1)
```

## 3. Native services: systemd drop-in

ComfyUI runs outside Docker, so compose can't pin it. A drop-in can ([`systemd/comfyui.service.d/gpu.conf`](../systemd/comfyui.service.d/gpu.conf)):

```ini
[Service]
EnvironmentFile=/etc/aihub/gpu.env
```

`gpu.env` sets `CUDA_DEVICE_ORDER=PCI_BUS_ID` and `CUDA_VISIBLE_DEVICES=<main UUID>`, so ComfyUI only ever sees the 3090.

```bash
sudo systemctl daemon-reload
sudo systemctl restart nvidia-power-limit comfyui
```

## 4. Verify

```bash
nvidia-smi --query-gpu=name,power.limit --format=csv
nvidia-smi --query-compute-apps=gpu_uuid,process_name,used_memory --format=csv
```

Every process should be on the UUID you meant. On this build: Ollama (the 27B, ~19 GB) and ComfyUI on the 3090; Whisper (~1.9 GB) and `ollama-ha` (`qwen3:8b`, ~6.3 GB) on the 2060.

`scripts/aihub-gpu-audit.sh` prints all of this, plus driver versions, PCIe link speed per card, the compose GPU sections and the systemd units, in one read-only pass. Run it before and after hardware changes and keep the output.

After-install record on this build (audit plus a short generation on each card):

| | RTX 3090 | RTX 2060 12 GB |
|---|---|---|
| Slot | CPU x16 | Chipset x4 |
| Link at idle (P8) | 2.5 GT/s x16 | 2.5 GT/s x4 |
| Link under load (P2) | 8 GT/s (Gen3) x16 | 8 GT/s (Gen3) x4 |
| Power limit (default) | 325 W (350 W) | 170 W (184 W) |
| Runs | Ollama 27B (~19 GB), ComfyUI (idle ~0.3 GB) | Whisper (~1.9 GB), `ollama-ha` `qwen3:8b` (~6 GB) |
| VRAM in use / total | ~19.4 / 24 GB | ~8 / 12 GB |

`lspci -vv` and `nvidia-smi` report both links as "2.5GT/s (downgraded)" at idle. That's the cards saving power, not a fault: the link goes back to Gen3 as soon as work starts. To check a link, read `pcie.link.gen.current` while the card is busy.

## 5. Burn in the new card

Before trusting a new or used card, load it alone for five minutes:

```bash
CUDA_VISIBLE_DEVICES=<GPU_HA_UUID> /srv/comfyui/.venv/bin/python scripts/gpu-burn.py
sudo dmesg | grep -iE 'nvrm|retrain|fallen' | tail
```

A pass prints `PASS`, and dmesg shows nothing new.

### What a bad install looks like

| Symptom | Meaning |
|---|---|
| Link stays at **2.5 GT/s** (Gen1) **under load** instead of 8 GT/s | Link trained at the lowest speed: seating or power problem. At idle, Gen1 is normal (see §4) |
| "retraining non-functional downstream link" | The link is failing; the card will usually drop next |
| "not ready … giving up", "Card not present" | The card didn't come back from a low-power state |
| `NVRM: … fallen off the bus` | The driver lost the card. Not a driver problem: the link died first |

On this build, all four showed up in order after the 2060 went in. Two fixes, both needed: the card's PCIe power connector (lit LEDs on the card didn't prove it had auxiliary power) and the kernel parameter `pcie_aspm=off`. No BIOS changes. Details: [troubleshooting](troubleshooting.md#gpu-fallen-off-the-bus-after-installing-a-second-card).

## 6. Monitoring two cards

Anything that reads `nvidia-smi --query-gpu` must expect **one line per GPU**. Code written for one card (split the output once, take the first value) breaks silently or reports the GPU as down. This build's monitor, [`host/bin/aihub-mon`](../host/bin/aihub-mon), had exactly this bug.

It now:

- reports the main card (most VRAM, or `GPU_MAIN_UUID` from `/etc/aihub-mon.env`) under the original "GPU …" entities, and the HA card under "HA GPU …";
- turns the "GPU" sensor off if fewer cards answer than `lspci` sees (or than `GPU_COUNT`), so a card dropping off the bus raises an alert.

## Backups when editing compose.yaml

Use named, one-time backups (`cp compose.yaml compose.yaml.pre-<change>`). `sed -i.bak` rewrites the `.bak` on every run, so running it twice destroys your original.
