# Troubleshooting

## GPU "fallen off the bus" after installing a second card

**Symptom:** after installing the RTX 2060 in the chipset slot, it was missing from `nvidia-smi` and `lspci`.

```bash
lspci -nn | grep -i nvidia
nvidia-smi -L
sudo journalctl -k -b | grep -iE '0000:03:00|AER|pcieport|link down'
sudo dmesg | grep -iE 'nvrm|nvidia|pcie.*(error|fail)' | tail -30
```

**What the kernel log showed, in order:**

1. The card enumerated, but "limited by 2.5 GT/s PCIe x4 link", Gen1 when it should be Gen3 (8 GT/s)
2. About 6 seconds later: "broken device, retraining non-functional downstream link at 2.5GT/s"
3. "not ready … 65535ms after resume; giving up", then "Card not present"
4. `NVRM: … fallen off the bus`, probe failed

The link died before the driver touched the card, which points to a physical or electrical problem (seating or PCIe power), not drivers.

**Fix:** two things, both needed on this board. No BIOS changes.

1. The 2060's **PCIe power connector** was the problem on the bench. The card's LEDs were lit, which looked like it had power, but lit LEDs don't prove the auxiliary 8-pin is delivering.
2. The kernel parameter **`pcie_aspm=off`** (turns off PCIe link power management). Removing it later brought the exact failure back at boot: two Gen1 retrains, "giving up", "fallen off the bus". Putting it back restored the card at Gen3 x4 with clean dmesg.

```bash
# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="pcie_aspm=off"
```

```bash
sudo update-grub && sudo reboot
grep -c pcie_aspm /proc/cmdline                         # 1
```

**Verified:**

```bash
nvidia-smi --query-gpu=name,memory.total,pcie.link.gen.max,pcie.link.width.current --format=csv
# RTX 2060, 12288 MiB, 3, 4
```

Then a 5-minute load test (`scripts/gpu-burn.py`) passed, with no retrain or bus errors in dmesg.

**Further fallbacks if that isn't enough** (not needed here):

- BIOS: set the chipset slot's link speed to Gen3 and turn off ASPM
- Kernel parameter: add `pcie_port_pm=off`
- Test the card alone in the top slot to rule out the card itself

## Power limit service fails with two GPUs

See [04-multi-gpu.md](04-multi-gpu.md#1-power-limit-target-one-card). `nvidia-smi -pl` without `-i` targets every card.

## Ollama splits a model across both GPUs

Its GPU anchor still uses `count: all`, or the image's `NVIDIA_VISIBLE_DEVICES=all` is in effect. Pin it with `device_ids`; see [04-multi-gpu.md](04-multi-gpu.md#2-containers-one-compose-anchor-per-card).

## Monitoring says the GPU is down after adding a second card

A script that runs `nvidia-smi --query-gpu=...` and expects one line gets two, fails to parse them, and reports the GPU as missing. aihub-mon did this and fired its "GPU problem" alert. Parse one line per GPU; see [04-multi-gpu.md](04-multi-gpu.md#6-monitoring-two-cards).

## Grok has no web access through LiteLLM

Via plain chat completions, Grok can't search: xAI deprecated Live Search (`search_parameters`) in favour of agent tools on a different API. It replies "I'll search…" and stalls, and doesn't know today's date. Send current-events questions to SearXNG (Open WebUI web search) instead, and inject the date into escalated prompts.

## A new Open WebUI tool doesn't show up in a chat

Open WebUI binds tools when a chat **starts**. Old chats keep the tool set they started with. Start a new chat after enabling or editing a tool.

## LiteLLM ignores a config change

LiteLLM reads `config.yaml` only at startup:

```bash
cd /srv/ai && docker compose restart litellm
```

## HA voice assistant can't see or control devices

The Extended OpenAI Conversation **prompt template must keep the Jinja `exposed_entities` block** (the CSV of entity IDs, names and states). Pasting a plain prompt over the whole template removes it, and the model no longer knows what exists. Edit around the block; don't replace it.

## MQTT from the server to Home Assistant doesn't connect

Point `mosquitto_pub` at Home Assistant's **LAN address** (port 1883), not its Cloudflare hostname. A Cloudflare tunnel carries HTTP(S) only, not raw MQTT.
