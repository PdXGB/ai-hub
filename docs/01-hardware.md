# 01 — Hardware

## Platform

| Part | Spec | Notes |
|---|---|---|
| Motherboard | MSI Z490-A PRO (MS-7C75) | BIOS 2.G0 (2024-07-08) |
| CPU | Intel Core i7-10700KF | No iGPU, so a GPU must be installed to get video output |
| RAM | 128 GB DDR4 | Large models can spill to system RAM; slow, but they still run |
| NIC | Realtek RTL8125 2.5GbE (onboard) | |
| PSU | 1000 W 80+ Bronze | Full GPU load is ~325 W + ~170 W plus CPU; plan on 850 W or more |

## GPUs

| Card | Slot | Link | Power limit | VRAM | Role |
|---|---|---|---|---|---|
| RTX 3090 Founders Edition | Top x16 (CPU lanes) | Gen3 x16 | 325 W (stock 350 W) | 24 GB | Large LLMs, ComfyUI |
| RTX 2060 12GB | Lower x16 (chipset, x4 electrical) | Gen3 x4 | 170 W (stock 184 W) | 12 GB | Home Assistant: Whisper, small LLM, later Frigate |

Z490 runs PCIe Gen3 from the CPU. The x4 chipset link is fine for a card whose models stay resident in its own VRAM; it would be a bottleneck if a model were split across both cards. That's why nothing is split (see [04](04-multi-gpu.md)).

On this board the lower x16 slot shares no lanes with the M.2 or SATA ports.

### Why a 2060 12GB for the HA card

It was a spare card already on hand. 12 GB is enough for the Home Assistant workloads, which stay loaded all the time:

| Load | VRAM | Status |
|---|---|---|
| Whisper (`distil-large-v3`) | ~1.9 GB | Running |
| `qwen3:8b`, 16k context (`ollama-ha`) | ~6.3 GB | Running |
| Frigate object detection + decoding | ~1.5–2 GB | Planned |

That's about 8 GB in use now, with room for Frigate. Its Turing architecture has no BF16 or FlashAttention 2, so video models stay on the 3090 regardless.

## Storage

| Drive | Size | Mount | Use |
|---|---|---|---|
| Samsung 970 EVO (NVMe) | 500 GB | `/`, `/boot`, `/boot/efi` (LVM) | OS, Docker |
| WD SN750 (NVMe) | 500 GB | `/srv/models/ollama` | Ollama models (fast load) |
| Crucial BX500 (SATA) | 2 TB | `/srv/models/comfyui` | ComfyUI checkpoints, LoRAs, outputs |
| Crucial BX500 (SATA) | 1 TB | `/srv/backup` | Local backups |

### Why this layout

Each drive has one job, so the right speed goes where it matters and the OS install never touches the data.

- **OS NVMe (970 EVO):** the only drive the Ubuntu installer touches (default LVM layout). It holds the OS, Docker, the compose stack in `/srv/ai` and app data in `/srv/data` (Open WebUI, n8n, the Postgres databases). `ollama-ha`'s model store (`/srv/models/ollama-ha`, one 8B model) also lives here; it has no mount of its own.
- **Second NVMe (SN750) for Ollama:** LLMs get the fastest drive because they're the models that get switched between. Loading `local-deep` (gpt-oss 120B) evicts the 27B, and the 27B reloads afterwards, so load time is felt in every swap.
- **2 TB SATA for ComfyUI:** image and video models are large but load once per render. At SATA speed that costs a few seconds against a multi-minute job, so the cheaper, bigger drive goes here, along with render outputs.
- **1 TB SATA for backups:** the seven local nightly backups. The NAS holds the off-box copy ([Network storage](#network-storage-synology-nas)).

The three data drives are formatted with labels and mounted by label (`LABEL=ollama|comfyui|backup`), so device-name changes between boots don't matter ([docs/02](02-ubuntu-nvidia.md#2-disk-layout)). Models aren't backed up; they can be downloaded again.

The sizes are simply the drives that were on hand; the jobs were assigned to fit them.

## Network storage: Synology NAS

| Part | Spec |
|---|---|
| NAS | Synology DS1618+ (6-bay), on the last DSM release Synology supports for it |
| System drives | 2 × 2 TB SSD, mirrored |
| Other bays | 14 TB HDDs |
| Expansion | Synology DX517 expansion unit, every bay filled with 10 TB HDDs |
| Drive make | Seagate NAS drives |
| Role for the server | Off-box copy of the nightly backups (a shared folder over SMB 3) |

The server keeps seven nightly backups on its own 1 TB drive, then mirrors them to a shared folder on the NAS over SMB 3. The share is mounted at `/mnt/nas` by a systemd automount, and the server logs in with a dedicated NAS account used only for backups. If the NAS is down, the local backup still runs and aihub-mon raises a "Backups" alert once the NAS copy is more than 27 h old. Setup, fstab line and password rotation: [10-backups.md](10-backups.md).

Models are not copied to the NAS; they can be downloaded again.

## What stays off this box

Home Assistant itself and the NAS run on other hardware. The AI server gets rebooted and tinkered with, and the house shouldn't notice.
