# 03 — Docker stack

One compose project (`ai`) in `/srv/ai` runs every service except ComfyUI. Every LLM client — Open WebUI, n8n, Home Assistant, scripts — goes through **LiteLLM**, which holds the cloud API keys, enforces budgets and logs every request.

Files: [`compose/compose.yaml`](../compose/compose.yaml), [`compose/.env.example`](../compose/.env.example), [`compose/litellm/config.example.yaml`](../compose/litellm/config.example.yaml), [`compose/searxng/settings.example.yml`](../compose/searxng/settings.example.yml).

## 1. Layout

| Path | Holds |
|---|---|
| `/srv/ai/compose.yaml` | The stack (project name `ai`, so containers are `ai-<service>-1`) |
| `/srv/ai/.env` | Every secret and host-specific value. Mode 600, never committed |
| `/srv/ai/litellm/config.yaml` | Routes and budgets |
| `/srv/ai/searxng/settings.yml` | SearXNG config |
| `/srv/data/<service>` | App data and Postgres data |
| `/srv/models/ollama`, `/srv/models/ollama-ha` | Model stores |

[`scripts/setup.sh`](../scripts/setup.sh) creates all of this: it copies the compose file and configs, generates the secrets, asks for the rest and fills the per-route and global budgets into the LiteLLM config. See the [README](../README.md#quick-start). By hand:

```bash
sudo mkdir -p /srv/ai/litellm /srv/ai/searxng /srv/data/{open-webui,litellm-db,n8n,n8n-db,whisper,piper} /srv/models/{ollama,ollama-ha}
sudo chown -R $USER: /srv/ai
sudo chown -R 1000:1000 /srv/data/n8n                   # n8n runs as uid 1000
cp compose/compose.yaml /srv/ai/
cp compose/litellm/config.example.yaml /srv/ai/litellm/config.yaml
cp compose/searxng/settings.example.yml /srv/ai/searxng/settings.yml   # replace GENERATED_BY_SETUP with a random string
cp compose/.env.example /srv/ai/.env && chmod 600 /srv/ai/.env          # fill in; secrets: openssl rand -hex 32
```

`.env.example` documents every variable. Back up `.env` separately: without `N8N_ENCRYPTION_KEY`, n8n's saved credentials can't be decrypted, and `LITELLM_SALT_KEY` must never change once keys exist in LiteLLM's database.

## 2. Services and exposure

| Service | Image | Port binding | Reachable from | GPU |
|---|---|---|---|---|
| `ollama` | `ollama/ollama:0.40.11` | `127.0.0.1:11434` | groot only | Main |
| `ollama-ha` | `ollama/ollama:0.40.11` | `127.0.0.1:11435` | groot only | HA |
| `litellm` | `ghcr.io/berriai/litellm:main-stable@sha256:…` | `127.0.0.1:4000`, `${GROOT_LAN_IP}:4000` | LAN (key required) | — |
| `litellm-db` | `postgres:17` | none | compose network | — |
| `open-webui` | `ghcr.io/open-webui/open-webui:main@sha256:…` | `3000:8080` (all interfaces) | LAN, and Cloudflare | — |
| `n8n` | `n8nio/n8n:stable@sha256:…` | `5678:5678` (all interfaces) | LAN, and Cloudflare | — |
| `n8n-db` | `postgres:17` | none | compose network | — |
| `cloudflared` | `cloudflare/cloudflared:latest@sha256:…` | none (outbound only) | — | — |
| `whisper` | `lscr.io/linuxserver/faster-whisper:gpu@sha256:…` | `${GROOT_LAN_IP}:10300` | LAN (Home Assistant) | HA |
| `piper` | `lscr.io/linuxserver/piper:latest@sha256:…` | `${GROOT_LAN_IP}:10200` | LAN (Home Assistant) | — |
| `searxng` | `searxng/searxng:latest@sha256:…` | `127.0.0.1:8888` | groot only | — |
| ComfyUI (native, `comfyui.service`) | — | `0.0.0.0:8188` | LAN via ufw | Main |

Containers reach each other by service name on the compose network (`http://litellm:4000`, `http://ollama:11434`, `http://searxng:8080`). The localhost bindings are for testing from groot itself.

**Firewall.** ufw denies inbound by default and allows:

| Port | From | Why |
|---|---|---|
| 22/tcp | your LAN | SSH |
| 8188/tcp | your LAN | ComfyUI web UI |
| 8188/tcp | `172.16.0.0/12` | Docker containers (Open WebUI, n8n) to ComfyUI on the host |

```bash
sudo ufw default deny incoming
sudo ufw allow from <your LAN CIDR> to any port 22 proto tcp
sudo ufw allow from <your LAN CIDR> to any port 8188 proto tcp
sudo ufw allow from 172.16.0.0/12 to any port 8188 proto tcp
sudo ufw enable
```

**Docker-published ports bypass ufw.** Docker writes its own iptables rules, so 3000, 5678, 4000, 10200 and 10300 are reachable whatever ufw says. That's why Ollama, `ollama-ha` and SearXNG bind to `127.0.0.1`, and LiteLLM, Whisper and Piper bind to the LAN address only. ComfyUI is a native service, so ufw does apply to it, and it has no authentication at all.

## 3. GPU anchors

Two YAML anchors pin containers to a card by UUID: `x-gpu` (`${GPU_MAIN_UUID}`, used by `ollama`) and `x-gpu-ha` (`${GPU_HA_UUID}`, used by `ollama-ha` and `whisper`). With one GPU, set both variables to the same UUID. Details: [04-multi-gpu.md](04-multi-gpu.md#2-containers-one-compose-anchor-per-card).

## 4. Ollama

```yaml
    environment:
      OLLAMA_KEEP_ALIVE: 5m
      OLLAMA_MAX_LOADED_MODELS: 2
      OLLAMA_FLASH_ATTENTION: 1
      OLLAMA_KV_CACHE_TYPE: q8_0
```

- `OLLAMA_KEEP_ALIVE: 5m` is only the **default**. The models that must stay loaded are pinned per route in LiteLLM (next section). A global `-1` pinned whatever loaded last, including the 120B.
- `MAX_LOADED_MODELS: 2`: the chat model plus the embedding model.
- `KV_CACHE_TYPE: q8_0` halves context memory, which keeps the 27B at 100% GPU.
- `ENABLE_OLLAMA_API: "false"` on Open WebUI: nothing talks to Ollama directly.

`ollama-ha` is a second instance on the HA card with one model loaded permanently; see [05-home-assistant.md](05-home-assistant.md#2-the-ha-model-ollama-ha-on-the-2060).

```bash
docker exec ai-ollama-1 ollama pull huihui_ai/Qwen3.8-abliterated:27b
docker exec ai-ollama-1 ollama pull gpt-oss:120b
docker exec ai-ollama-1 ollama pull nomic-embed-text
docker exec ai-ollama-ha-1 ollama pull qwen3:8b
```

## 5. LiteLLM: routes and budgets

Clients ask for a **route name**; LiteLLM maps it to a model.

| Route | Model | Runs on | `keep_alive` | Budget |
|---|---|---|---|---|
| `local-fast` | `ollama_chat/huihui_ai/Qwen3.8-abliterated:27b` | 3090 | `-1` (always loaded) | free |
| `local-deep` | `ollama_chat/gpt-oss:120b` | 3090 + system RAM | `5m` | free |
| `local-ha` | `ollama_chat/qwen3:8b`, `think: false` | 2060 (`ollama-ha`) | `-1` | free |
| `embed` | `ollama/nomic-embed-text` (`mode: embedding`) | 3090 | default | free |
| `claude` | `anthropic/claude-sonnet-5-5` | cloud | — | $25 / 30 d |
| `claude-opus` | `anthropic/claude-opus-5-5` | cloud | — | $25 / 30 d |
| `gemini` | `gemini/gemini-3.8-flash` | cloud | — | $25 / 30 d |
| `gemini-pro` | `gemini/gemini-3.1-pro-preview` | cloud | — | $25 / 30 d |
| `grok` | `xai/grok-4.7` | cloud | — | $25 / 30 d |

Cloud model IDs change every few months; copy the current ID from each provider when you set it up.

**Budgets.** Each cloud route has its own cap, and `litellm_settings` adds a ceiling across all of them:

```yaml
  - model_name: claude
    litellm_params:
      model: anthropic/claude-sonnet-5-5
      api_key: os.environ/ANTHROPIC_API_KEY
      max_budget: 25
      budget_duration: 30d

litellm_settings:
  drop_params: true      # silently drop params a provider rejects
  max_budget: 50          # hard ceiling, all cloud routes combined
  budget_duration: 30d
```

- **No wildcard routes** (`anthropic/*` and the like). They bypass the per-route budgets.
- **`drop_params: true`**: Claude 5.5 rejects any `temperature` other than 1. Instead of failing the request, LiteLLM drops parameters a provider doesn't accept.
- **`keep_alive` per route** is passed through to Ollama. After a LiteLLM restart, `ollama ps` shows the `local-fast` model at `100% GPU, Forever`; `local-deep` unloads 5 minutes after its last use, and the 27B reloads.
- Back the caps up with spend limits in the provider consoles. Google's billing budget only alerts.

**LiteLLM reads its config only at startup.** After any edit:

```bash
cd /srv/ai && docker compose restart litellm
```

### Virtual keys

Give each client its own key with only the routes it needs, instead of the master key. A key can be revoked on its own, and spend is logged per key.

```bash
MK=$(docker exec ai-litellm-1 printenv LITELLM_MASTER_KEY)

# Home Assistant: local routes plus two cloud routes, $10 / 30 days
curl -s localhost:4000/key/generate -H "Authorization: Bearer $MK" -H "Content-Type: application/json" \
  -d '{"key_alias":"home-assistant","models":["local-fast","local-ha","claude","gemini"],"max_budget":10,"budget_duration":"30d"}'

# Open WebUI's ask_model tool (docs/06)
curl -s localhost:4000/key/generate -H "Authorization: Bearer $MK" -H "Content-Type: application/json" \
  -d '{"key_alias":"open-webui-ask-model"}'
```

Change an existing key with `POST /key/update`; revoke one with `POST /key/delete` and `{"key_aliases":["<alias>"]}`. Treat key values like passwords.

Open WebUI itself is configured with the master key (`OPENAI_API_KEY: ${LITELLM_MASTER_KEY}` in compose).

## 6. Open WebUI

```yaml
    environment:
      OPENAI_API_BASE_URL: http://litellm:4000/v1
      OPENAI_API_KEY: ${LITELLM_MASTER_KEY}
      ENABLE_OLLAMA_API: "false"
      WEBUI_SECRET_KEY: ${WEBUI_SECRET_KEY}
```

After the first login (that account is the admin):

- **Admin Panel → Settings → General:** turn off **Enable New Sign Ups**.
- **Admin Panel → Settings → Models:** edit the base models (pencil icon), not Workspace → Create, which makes duplicates. Give each a description and a system prompt naming itself; without one, Open WebUI's built-in tool prompt makes cloud models vague about who they are.
- **Vision** is a checkbox under **Capabilities**. Added as a custom advanced parameter it sends an unknown `vision` field, which Anthropic rejects.
- Leave **Temperature** at Default on cloud models.
- Hide `embed` from the chat model list.

`extra_hosts: host.docker.internal:host-gateway` lets it reach ComfyUI on the host for image generation (docs/08). Model routing, the Groot model and the `ask_model` tool: [06-model-routing.md](06-model-routing.md). Knowledge base: [07-knowledge-base.md](07-knowledge-base.md).

## 7. n8n

```yaml
      N8N_HOST: ${N8N_HOSTNAME}
      N8N_PROTOCOL: https
      WEBHOOK_URL: https://${N8N_HOSTNAME}/
      N8N_PROXY_HOPS: 1
      N8N_RUNNERS_TASK_TIMEOUT: 1200
```

n8n generates its URLs and webhooks for the public hostname behind the tunnel (`n8n.example.com`), and `N8N_PROXY_HOPS: 1` makes it trust the one proxy in front of it. With `N8N_SECURE_COOKIE` left at its default, log in through the https hostname, even on the LAN. `extra_hosts` lets workflows call ComfyUI on the host.

## 8. Remote access: Cloudflare Tunnel + Access

Only Open WebUI and n8n leave the LAN, and both sit behind Cloudflare Access. Ollama, LiteLLM, ComfyUI and the speech services never do.

```yaml
  cloudflared:
    command: tunnel --no-autoupdate --protocol http2 run
    environment:
      TUNNEL_TOKEN: ${CLOUDFLARE_TUNNEL_TOKEN}
```

The tunnel only makes outbound connections; no port is opened on the router.

1. **Zero Trust → Networks → Tunnels:** create a dedicated tunnel. Copy the token from its Docker install command into `CLOUDFLARE_TUNNEL_TOKEN` in `.env`.
2. **Access → Applications:** create the Access apps **before** the routes, so a hostname is never public without a login in front of it:
   - `chat.example.com`, policy: everyone who uses the chat;
   - `n8n.example.com`, policy: admins only.

   Login by one-time PIN to an allowed email address.
3. **Tunnel → Published applications (routes):**

   | Hostname | Service |
   |---|---|
   | `${CHAT_HOSTNAME}` (`chat.example.com`) | `http://open-webui:8080` |
   | `${N8N_HOSTNAME}` (`n8n.example.com`) | `http://n8n:5678` |

The service URLs use compose service names and container ports, because `cloudflared` runs on the compose network.

- External webhooks into n8n will need an Access **Bypass** policy on the webhook paths.
- Cloudflare cuts requests off at 100 s. n8n form uploads through the tunnel currently don't reach n8n at all (they work on the LAN); a workflow that responds immediately and serves a "latest result" link is the planned fix.

## 9. SearXNG

Private metasearch for the LLMs. Internal only.

```yaml
use_default_settings: true
server:
  secret_key: "GENERATED_BY_SETUP"
  limiter: false
  image_proxy: false
search:
  safe_search: 0
  formats:
    - html
    - json
```

- `json` must be in `formats`; Open WebUI asks for JSON.
- `limiter: false`, `safe_search: 0`.
- `secret_key`: `setup.sh` generates it. By hand, any long random string.

Open WebUI: **Admin Panel → Settings → Web Search**: engine `searxng`, query URL `http://searxng:8080/search?q=<query>`, 10 results.

```bash
curl -sf 'localhost:8888/search?q=test&format=json' | head -c 300
```

## 10. Image pinning

| Image | Pinned by | Why |
|---|---|---|
| `litellm`, `open-webui`, `n8n`, `cloudflared`, `whisper`, `piper`, `searxng` | `tag@sha256:digest` | Moving tags (`main-stable`, `main`, `stable`, `latest`, `gpu`); the digest freezes the tested build |
| `ollama`, `ollama-ha` | version tag (`0.40.11`) | Already immutable |
| `litellm-db`, `n8n-db` | `postgres:17` | Major version fixed. Postgres 18 changed its data-directory layout, so 17 avoids that trap with these volume paths. Major upgrades need a dump and restore |

With digests in place, `docker compose pull` changes nothing, which is the point. Updates go through `update-image.sh`, one service at a time, with a backup, a health check and a rollback log: [11-updates.md](11-updates.md).

## 11. Bring it up and verify

```bash
cd /srv/ai
docker compose config -q && docker compose up -d
docker compose ps
docker compose logs -f litellm                          # Ctrl-C when it settles
```

- [ ] `docker compose ps`: every service running
- [ ] `curl -s localhost:4000/v1/models -H "Authorization: Bearer $MK"` lists every route
- [ ] `docker exec ai-ollama-1 ollama ps` shows the 27B at `100% GPU` after one `local-fast` request
- [ ] Open WebUI answers on `local-fast`, `local-deep` and each cloud route
- [ ] A web-search question returns cited results
- [ ] Cloudflare Access asks for a login before Open WebUI and n8n load from outside
