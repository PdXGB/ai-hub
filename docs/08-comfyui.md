# 08 — ComfyUI: image and video

ComfyUI renders images and video on the 3090. It runs **natively** (its own Python venv, a systemd unit), not in Docker, and shares the card with Ollama, so it hands the VRAM back when idle.

Files: [`systemd/comfyui.service`](../systemd/comfyui.service), [`systemd/comfyui.service.d/gpu.conf`](../systemd/comfyui.service.d/gpu.conf), [`systemd/comfyui-idle-free.service`](../systemd/comfyui-idle-free.service) + [`.timer`](../systemd/comfyui-idle-free.timer), [`host/bin/comfyui-idle-free`](../host/bin/comfyui-idle-free).

## 1. Install

Ubuntu 26.04's system Python can be newer than PyTorch supports, so the venv gets its own Python through uv:

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
sudo git clone https://github.com/Comfy-Org/ComfyUI.git /srv/comfyui
sudo chown -R $USER: /srv/comfyui && cd /srv/comfyui
uv venv --python 3.13 .venv && source .venv/bin/activate     # groot: Python 3.13, torch 2.14.1+cu130
# PyTorch: paste the pip line from pytorch.org's selector (Linux, Pip, newest CUDA 13.x)
uv pip install -r requirements.txt

# models live on the 2 TB drive
cp -a models/. /srv/models/comfyui/ && rm -rf models && ln -s /srv/models/comfyui models

# GGUF loader
cd custom_nodes && git clone https://github.com/city96/ComfyUI-GGUF && cd ..
uv pip install -r custom_nodes/ComfyUI-GGUF/requirements.txt
```

## 2. Service

[`systemd/comfyui.service`](../systemd/comfyui.service):

```ini
[Service]
User=<user>
WorkingDirectory=/srv/comfyui
ExecStart=/srv/comfyui/.venv/bin/python main.py --listen 0.0.0.0 --port 8188 --enable-manager
Restart=on-failure
RestartSec=5
```

`setup.sh` installs it with your user filled in, plus the `gpu.conf` drop-in that pins ComfyUI to the main GPU ([docs/04](04-multi-gpu.md#3-native-services-systemd-drop-in)). It enables the service only if `/srv/comfyui/.venv` exists, so after installing ComfyUI:

```bash
sudo systemctl enable --now comfyui
journalctl -u comfyui -f
```

Open `http://groot:8188`. ComfyUI has **no authentication**: ufw limits 8188 to the LAN and the Docker bridge, and it is never routed through the tunnel ([docs/03](03-docker-stack.md#2-services-and-exposure)).

## 3. Video: Wan 2.2 image-to-video, turbo

Start from ComfyUI's built-in **Wan 2.2 14B image-to-video** template; it links the model files to download into `/srv/models/comfyui`.

Measured on groot: 640×640, 5 s clip, `fp8_scaled` checkpoints, 3090 at 325 W:

| Setting | Time per clip |
|---|---|
| Template defaults | 16 min 52 s |
| `enable_turbo_mode = true` on the template's **Image to Video (Wan2.2)** node | **118 s** |

Turbo mode uses the 4-step LoRA. To confirm it's active, check the log while the model loads:

```bash
journalctl -u comfyui -f | grep -i patches       # "400 patches attached" = LoRA on, "0 patches" = off
```

The fp8 checkpoints run fine on the 3090: Ampere has no FP8 hardware, so the weights are cast up and you get no FP8 speedup, but no GGUF swap was needed either.

**Stills:** Z-Image Turbo. Watch its VAE node, which can fall back to `pixel_space`.

Once a workflow looks right, save it with **Export (API)**. That JSON is what n8n or another client posts to ComfyUI's API.

## 4. Sharing the GPU: idle VRAM release

ComfyUI keeps models in VRAM indefinitely after a render. On a shared card that pushes Ollama partly onto the CPU (`ollama ps` showing `79%/21% CPU/GPU`), and chat crawls.

[`host/bin/comfyui-idle-free`](../host/bin/comfyui-idle-free) checks ComfyUI's queue and, if nothing is running or pending, calls its `/free` endpoint:

```bash
curl -s -X POST http://localhost:8188/free -H "Content-Type: application/json" \
  -d '{"unload_models": true, "free_memory": true}'
```

`comfyui-idle-free.timer` runs it 5 minutes after boot and every 5 minutes after that. A render is never interrupted; the VRAM comes back within 5 minutes of the queue emptying. Run the `curl` above by hand to free it immediately.

The other direction: a 27B LLM and a 14B video model don't fit in 24 GB together, so the n8n video workflow unloads Ollama's model before each render.

## 5. From other services

| Client | Setting |
|---|---|
| Open WebUI (stills in chat) | **Admin Panel → Settings → Images → ComfyUI**, base URL `http://host.docker.internal:8188` |
| n8n | HTTP Request nodes to `http://host.docker.internal:8188`, sending the exported API JSON |

Both containers have `extra_hosts: host.docker.internal:host-gateway` in compose, and ufw allows 8188 from `172.16.0.0/12` so the Docker bridge can reach the host.

**Known issue:** a photo-to-video n8n form works on the LAN, but uploads through the Cloudflare tunnel never reach n8n, and Cloudflare cuts requests off at 100 s anyway. The planned fix is a workflow that responds immediately and serves a "latest video" link.
