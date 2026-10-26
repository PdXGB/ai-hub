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
| `/etc/groot-ai/gpu.env` (from [`systemd/gpu.env.example`](../systemd/gpu.env.example)) | systemd units | `GPU_MAIN_UUID`, `GPU_MAIN_POWER_LIMIT`, `CUDA_DEVICE_ORDER`, `CUDA_VISIBLE_DEVICES` |

[`scripts/setup.sh`](../scripts/setup.sh) detects the cards and writes both. By hand:

```bash
sudo install -d -m 755 /etc/groot-ai
sudo install -m 644 systemd/gpu.env.example /etc/groot-ai/gpu.env
sudoedit /etc/groot-ai/gpu.env          # paste the 3090's UUID into both UUID lines
```

With a single GPU, set `GPU_HA_UUID` to the same UUID as `GPU_MAIN_UUID`. Everything still works; the HA services just share the card.

## 1. Power limit: target one card

`nvidia-smi -pl` without `-i` applies to **every** GPU. Once a second card is in, a limit above that card's maximum (325 W vs the 2060's 184 W) makes the command fail, and the main card may not get its limit either.

[`systemd/nvidia-power-limit.service`](../systemd/nvidia-power-limit.service):

```ini
[Service]
Type=oneshot
EnvironmentFile=/etc/groot-ai/gpu.env
ExecStart=/usr/bin/nvidia-smi -i ${GPU_MAIN_UUID} -pl ${GPU_MAIN_POWER_LIMIT}
RemainAfterExit=yes
```

The UUID and wattage come from a file because **systemd doesn't expand `${VAR}` inside `Environment=` lines**, only from `EnvironmentFile=` (or literal values).

The 2060 runs at its stock 184 W. Capping it too would need a second `ExecStart=` line with its own UUID.

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
EnvironmentFile=/etc/groot-ai/gpu.env
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

Every process should be on the UUID you meant. On groot: Ollama (the 27B, ~19 GB) and ComfyUI on the 3090; Whisper (~1.9 GB) and `ollama-ha` (`qwen3:8b`, ~6.3 GB) on the 2060.

`scripts/groot-gpu-audit.sh` prints all of this, plus driver versions, PCIe link speed per card, the compose GPU sections and the systemd units, in one read-only pass. Run it before and after hardware changes and keep the output.

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
| `lspci` shows the card, link at **2.5 GT/s** (Gen1) instead of 8 GT/s | Link trained at the lowest speed: seating or power problem |
| "retraining non-functional downstream link" | The link is failing; the card will usually drop next |
| "not ready … giving up", "Card not present" | The card didn't come back from a low-power state |
| `NVRM: … fallen off the bus` | The driver lost the card. Not a driver problem: the link died first |

On groot, all four showed up in order after the 2060 went in. Two fixes, both needed: the card's PCIe power connector (lit LEDs on the card didn't prove it had auxiliary power) and the kernel parameter `pcie_aspm=off`. No BIOS changes. Details: [troubleshooting](troubleshooting.md#gpu-fallen-off-the-bus-after-installing-a-second-card).

## 6. Monitoring two cards

Anything that reads `nvidia-smi --query-gpu` must expect **one line per GPU**. Code written for one card (split the output once, take the first value) breaks silently or reports the GPU as down. groot's monitor, [`host/bin/groot-mon`](../host/bin/groot-mon), had exactly this bug.

It now:

- reports the main card (most VRAM, or `GPU_MAIN_UUID` from `/etc/groot-mon.env`) under the original "GPU …" entities, and the HA card under "HA GPU …";
- turns the "GPU" sensor off if fewer cards answer than `lspci` sees (or than `GPU_COUNT`), so a card dropping off the bus raises an alert.

## Backups when editing compose.yaml

Use named, one-time backups (`cp compose.yaml compose.yaml.pre-<change>`). `sed -i.bak` rewrites the `.bak` on every run, so running it twice destroys your original.
