# ai-hub: status and remaining work

**Single source of truth for this repo.** Every chat or session working on
ai-hub reads this file first and updates it before finishing:
move items to Done, add new ones, note open questions. No secrets, IPs,
domains or UUIDs in this file; it's public.

Working rules
- Claude writes files in this folder; PdXGB reviews and commits/pushes from GitHub Desktop. Claude doesn't run git.
- Live configs come from the server via `scripts/scrub.sh`, never rewritten from memory.
- Raw notes and every file a chat produced go in `_handoffs/`: `chat-NN-<topic>.md` plus `_handoffs/files/`. That folder is its own **private** repo (`_handoffs`) and is gitignored by this public one.
- A chat may be closed only after it has a row in the Chat migration log below, marked complete.

_Last updated: 2026-10-26 (chat 09 complete). Public repo: PdXGB/ai-hub; private notes: PdXGB/_handoffs._

---

## Chat migration log

Each chat adds its row when it has: (1) saved its handoff and all files to `_handoffs/`, (2) updated this TODO.md, (3) told PdXGB it's safe to close. PdXGB commits and pushes both repos after each row.

| # | Chat / topic | Handoff file | Files saved | TODO updated | Safe to close |
|---|---|---|---|---|---|
| 01 | Main build: hardware, Ubuntu, driver, stack, HA, ComfyUI, tunnel, repo start | `chat-01-main-build.md` | `files/`: photo-to-video workflow, aihub-brief, HA prompt template, HA health automation, local-ha route. plus `the server-build-plan.md` (build doc export). Both repos pushed 2026-10-25 | Yes | **Yes** |
| 02 | Container planning; 2060 HA GPU install, "fallen off the bus" fix, UUID pinning, whisper moved to 2060 | `the server-2060-ha-gpu.md` (kept original name; no chat-02 rename) | `files/chat-02-2060-ha-gpu/`: aihub-gpu-audit.sh, burn.py, prep/pin script, diagnose + load test, whisper move, gpu_ha anchor, ollama-ha (proposed, never run), applied power-limit/ComfyUI snippets, repo-chat prompt, README index | Yes | **Yes** |
| 03 | Public repo + GitHub Desktop setup; README/docs scaffold, scrub.sh, gpu-burn.py | `chat-03-repo-setup.md` | `files/chat-03-repo-setup/`: README, docs 01-05 + troubleshooting, scrub.sh, gpu-burn.py | Yes | **Yes** |
| 04 | assistant system prompt + model routing (`ask_model` tool), HA voice prompt, local-deep + keep-alive, update workflow (update-image.sh, monthly-update.sh, dbx), aihub-mon HA monitoring/security | `chat-04-prompt-updates-monitoring.md` | `files/chat-04-prompt-updates-monitoring/`: open-webui/ (system prompt, ask_model.py), home-assistant/ (voice prompt template, card, 5 automations), updates/ (update-image.sh, monthly-update.sh), aihub-mon/ (aihub-mon.py, installer, update paste) | Yes | **Yes** |
| 05 | Repo hygiene (parallel to 03): GitHub Desktop/email guidance, `.gitattributes`, `.gitignore`, skeleton, cross-chat handoff prompt, review of the server-run scrub.sh | `chat-05-repo-hygiene-handoffs.md` | `files/chat-05-repo-hygiene/`: **recovered the server-run scrub.sh**, handoff prompt, .gitattributes/.gitignore snapshots, README index | Yes | **Yes** |
| 06 | External-AI handoff prompt (parallel session; claimed 06 before the audit chat, which became 07) | `chat-06-external-ai-prompt.md` (reconstructed by chat 08 from the files; no transcript) | `files/chat-06-audit-scrub/`: external-ai-handoff-prompt.md | Yes | **Yes** |
| 07 | Leak audit + fixes, scrub.sh rebuild (5 the server runs), key rotation, aihub-mon v2 (multi-GPU, absorbs the old health script), HA card v2 + automation 6, `ollama-ha` (qwen3:8b on the 2060, 8–10 s → 0.4 s), gpu.env on the server, aihub-backup coverage, docs 04/05/troubleshooting/README/LICENSE, `setup.sh` | `chat-07-scrub-aihub-mon.md` | `files/chat-07-scrub-aihub-mon/`: scrub.sh, setup.sh, aihub-mon, aihub-backup, HA card + automation 6 + template, docs-chat prompt, README index | Yes | **Yes** |
| 08 | Docs: 02 Ubuntu/NVIDIA, 03 Docker stack, 06–11 feature docs (routing, RAG, ComfyUI, monitoring, backups, updates), docs/05 §8 HA MCP; `open-webui/` (ask_model v0.2.1, genericized assistant prompt); README Quick start via setup.sh; TZ variable; monthly-update/scrub/docs fixes | `chat-08-docs.md` | `files/chat-08-docs/`: linkcheck.py, leak.sh | Yes | **Yes** |
| 09 | Review pass + fixes; update-image pre-update backups, setup.sh daemon.json merge + /srv/ai ownership; restore test (docs/10 §4); `pcie_aspm=off` proven required; repo re-created clean and published as `ai-hub`; full neutral rename to `aihub` (repo + server, via a tested migration script); docs/01 drive rationale | `chat-09-review-release.md` | `files/chat-09-review-release/`: migrate-to-aihub.sh, recreate-public-repo.ps1, ha-ready/, pre-rename/ snapshot, next-chat-prompt.md | Yes | **Yes** |

## Done

- [x] Public repo and private notes repo (`_handoffs`) published to GitHub, both private until review; commits use the GitHub noreply email
- [x] `.gitattributes` (LF everywhere) and `.gitignore` (.env, staging/, _handoffs/, models, logs) (chat 05)
- [x] Standard 11-section handoff prompt for all the server chats; `_handoffs/` workflow (chat 05)
- [x] `scripts/scrub.sh`: copies live configs, scrubs secrets/IPs/domain/UUIDs/user, runs a leak check. First run: PASS
- [x] Scrubbed configs promoted to the repo:
  - `compose/`: `compose.yaml`, `.env.example` (all variables documented), `litellm/config.example.yaml`, `searxng/settings.example.yml`
  - `systemd/`: power limit, ComfyUI plus its `gpu.conf` drop-in, idle-free, backup and health timers, persistenced override, `gpu.env.example`
  - `host/`: `docker-daemon.json`, `51unattended-nvidia`, `bin/` (aihub-backup, comfyui-idle-free; the old health script later retired in chat 07)
- [x] systemd GPU pinning reworked **in the repo** to `EnvironmentFile=/etc/aihub/gpu.env` (systemd won't expand `${VAR}` inside `Environment=`); power limit is a variable. applied on the server in chat 07
- [x] `the old health script` multi-GPU temperature bug fixed in the repo (checks the hottest GPU)
- [x] README with architecture diagram; docs 01, 04 and troubleshooting drafted; `scripts/gpu-burn.py`
- [x] GitHub Desktop installed; repo created in Desktop (README + MIT LICENSE) and published
- [x] docs 02, 03 and 05 outlined (headings + TODO notes)
- [x] Assistant general system prompt (Open WebUI custom model on `local-fast`, native function calling, web search on by default) and the `ask_model` Open WebUI tool (escalates to LiteLLM routes; allowlist, cloud secret blocker, cost/status display). Tested against every cloud route and `local-deep` (chat 04)
- [x] Routing rule: current info goes to SearXNG first. Grok via plain LiteLLM chat completions has no web access (xAI Live Search deprecated), so it's no longer the news route (chat 04)
- [x] **Ollama keep-alive resolved:** compose `OLLAMA_KEEP_ALIVE=5m` as the global default; LiteLLM per-route `keep_alive`: `local-fast` and `local-ha` = -1 (Qwen pinned), `local-deep` = 5m. Verified the pin passes through LiteLLM (chat 04)
- [x] HA voice: Extended OpenAI Conversation prompt template (keeps the `exposed_entities` block; confirms only locks/doors/gates/alarm/well pump) (chat 04)
- [x] Update strategy: kernel + NVIDIA blacklisted from unattended-upgrades (not `apt-mark hold`, so prebuilt signed modules and userspace stay in lockstep); UEFI dbx firmware updated; containers already pinned `tag@digest` (chat 04)
- [x] `update-image.sh` (per-service or `--all` updates with backup, digest pin, health check, rollback log) and `monthly-update.sh` (containers -> models -> apt incl. kernel/NVIDIA -> firmware report -> reboot) written and installed on the server (chat 04)
- [x] Second GPU (RTX 2060 12GB) installed in the chipset x4 slot. "Fallen off the bus" was fixed by its PCIe power connector plus `pcie_aspm=off` (the kernel parameter's role confirmed in chat 09). Passed a 5-minute load test at Gen3 x4 with clean dmesg (chat 02)
- [x] GPU pinning by UUID before the install: power-limit service, compose `x-gpu` anchor (`count: all` removed), ComfyUI drop-in. Later moved to `gpu.env` (chats 02/03)
- [x] `x-gpu-ha` compose anchor added; whisper moved to the 2060 and verified (the container sees only the 2060, ~1.9 GB VRAM) (chat 02)
- [x] `aihub-mon`: MQTT discovery device in HA (system/GPU/containers/Ollama/cloud spend/updates/security tripwires), dashboard card, 5 phone alerts, HA buttons (acknowledge alerts, check updates) via a listener service. Installed and tested end to end (chat 04)

## To do: repo files

- [x] Housekeeping (chat 07): removed `.gitkeep` files, stale `.git` lock files, `_handoffs/files/__pycache__`
- [x] Home Assistant files added (chat 07): `home-assistant/aihub-ha-card.yaml` (compact v2, per-GPU rows) and `home-assistant/automations/` 1–6 (`notify.mobile_app_your_phone` placeholder)
- [x] Leak fix (chat 07): NAS hostname removed from `host/bin/` (now `/mnt/nas`); personal name in this file replaced by `PdXGB`; `.gitignore` also ignores `scrub-report.txt`

- [x] `scripts/setup.sh` written (chat 07): config + host files; prompts with env-var overrides (secrets hidden); re-runs never overwrite (fills empty/missing `.env` values, reports files that differ from the repo). Writes /srv/ai (compose, `.env` with generated secrets, LiteLLM config with budgets, SearXNG key, update scripts), data dirs, `/etc/aihub/gpu.env`, host/bin, daemon.json, unattended blacklist, `/etc/aihub-mon.env`, MQTT login (optional); installs units and enables timers. `--root DIR` for testing. Tested in a sandbox (fresh, re-run, gap-fill, interactive); **not yet run on real hardware**
- [x] `setup.sh` run on the server (chat 07): detected both GPUs, LAN IP and subnet; filled the missing `.env` values (hostnames, LAN IP, GPU UUIDs, TZ); changed nothing else. Expected differences: live `compose.yaml` (hardcoded UUIDs/IP/TZ), `aihub-backup` (NAS path), `comfyui.service` (comment)
- [x] README Quick start: real setup.sh steps; "(coming)" dropped from docs/04 (chat 08)
- [x] `scripts/aihub-gpu-audit.sh` promoted from the server via scrub (chat 07)
- [x] `scripts/scrub.sh`: server-run (sudo/python) version promoted with fixes (chat 07): SMB credentials discovered from `credentials=` in `/etc/fstab`; output dir guarded by a marker file (no unguarded `rm -rf`); NAS mount/name scrubbed; leak check covers 10.x/172.16-31.x, emails, more token types, passwords in URLs, NAS name, username; `~/.scrub-literals` support; collects aihub-gpu-audit, update scripts and aihub-mon. First the server run (chat 07) caught a personal name in aihub-mon's HA device info, but missed the tunnel domain hardcoded in compose (`N8N_HOST`/`WEBHOOK_URL`); fixed: domain discovered from compose again, plus a generic public-hostname leak check; SMB username no longer scrubbed (it collided with a script name). Re-run on the server (runs 3–5 PASS) and promoted (chat 07; confirmed against `staging/run5` in chat 09)
- [x] README (chat 07): repo layout incl. `host/` and `home-assistant/`, `/srv/ai/.env`, licenses (MIT code, CC BY 4.0 `docs/` + `docs/LICENSE`), live vs planned HA voice path, aihub-mon. Remove the "work in progress" note once setup.sh exists
- [x] **Before going public:** re-create the GitHub repo from a clean folder as one initial commit (steps to be written) — **required**: two old blobs in the current history (pre-chat-07 `aihub-backup` and `the old health script`) still contain the NAS name and its mount path (re-checked chat 08). The working tree is clean.
- [x] `TZ` is now a variable (`${TZ}` in compose, documented in `.env.example`) (chat 08). `TZ` added to the server's `/srv/ai/.env` via setup.sh (chat 07). `setup.sh` prompts for it, defaulting to the server time zone (chat 07); re-running setup.sh on the server fills it
- [x] `scripts/monthly-update.sh`: post-reboot hint calls `aihub-mon --dry-run` instead of the retired old health script (chat 08). Applied on the server (chat 07)
- [x] `scripts/scrub.sh`: no longer collects the old health script units/script; its redaction rules for `/etc/the old health script.conf` and the webhook ID stay as a safety net (chat 08)
- [x] `update-image.sh` (chat 09): pre-update backups moved to `/srv/backup/pre-update/` (backup drive, mirrored to the NAS), mode 700, newest 3 kept per service (`KEEP_BACKUPS`). docs/10 §5 and docs/11 updated. Installed on the server (chat 09)
- [x] Promote chat 04 files (chat 07 promoted from the server via scrub: `scripts/update-image.sh`, `scripts/monthly-update.sh`, `scripts/aihub-gpu-audit.sh`, `host/bin/aihub-mon`, `host/aihub-mon.env.example`, aihub-mon units; remaining items below) (source: `_handoffs/files/chat-04-prompt-updates-monitoring/`; collect live copies via scrub where they exist on the server):
  - [x] `scripts/update-image.sh`, `scripts/monthly-update.sh` (chat 07)
  - [x] `aihub-mon`: binary, units, `host/aihub-mon.env.example` (chat 07). Installed by setup.sh (chat 07)
  - [x] Open WebUI: `open-webui/ask_model.py` (v0.2.1: author PdXGB, Grok described as no-web-access) and genericized `open-webui/assistant-system-prompt.md` (chat 08). Pasted on the server and verified (chat 09)
  - [x] Home Assistant: voice prompt template (genericized, cache-ordered), card and alert automations (chat 07)
  - [x] Extend `scrub.sh` to collect the above: N/A (chat 09). Every file-based item is already collected; the rest live in Open WebUI's database or in Home Assistant, not in files on the server

## To do: docs

- [x] `docs/02-ubuntu-nvidia.md` written (chat 08): BIOS, disk layout + fstab by LABEL, install, static IP, driver + matching utils, persistenced, Docker + toolkit, daemon.json, unattended blacklist vs hold, audit
- [x] `docs/03-docker-stack.md` written (chat 08): layout, services/ports/exposure, ufw + Docker bypass, anchors, Ollama env, LiteLLM routes/budgets/drop_params/keep_alive, virtual keys, Open WebUI, n8n, Cloudflare tunnel + Access, SearXNG, pinning, verify
- [x] `docs/05-home-assistant.md` written from the live setup (chat 07)
- [x] Feature docs written (chat 08): `06-model-routing`, `07-knowledge-base`, `08-comfyui`, `09-monitoring`, `10-backups`, `11-updates`; HA MCP as docs/05 §8; SearXNG in docs/03 §9; README docs list updated
- [x] `_TODO: confirm_` markers resolved (chat 08): docs/07 embedding key, docs/08 Python 3.13, docs/10 NAS fstab line. docs/10 §4 Restore and the hardware facts followed in chat 09; none remain
- [x] Test restore (chat 09): n8n dump into a scratch `postgres:17` (RESTORE OK, counts match live) and `srv/ai/compose.yaml` from `aihub-config.tar.gz`; docs/10 §4 written from it. Restoring over the live stack not tested
- [x] Backup archive now includes `srv/ai/.env`, `etc/aihub/gpu.env`, `etc/fstab`, `usr/local/bin/aihub-mon` (manual `aihub-backup` run after the migration, chat 09; 43 s, copied to the NAS)
- [x] `setup.sh` (chat 09): adds `log-driver`/`log-opts` to an existing `/etc/docker/daemon.json` when missing (original kept as `daemon.json.pre-setup`), never changes other keys, never restarts Docker (prints the restart step); chowns `/srv/ai` to the sudo user (matches the server); creates `/srv/backup/pre-update` (700, the user). Sandbox-tested (merge, already merged, invalid JSON). docs/02 updated. Nothing to apply on the server: its daemon.json already matches and setup.sh runs from the clone
- [x] Synology NAS added to the hardware stack (chat 08): docs/01 "Network storage", README hardware table + diagram, docs/10 links
- [x] Synology recorded in docs/01 (chat 08): DS1618+, last supported DSM, 2 × 2 TB SSD mirrored, 14 TB HDDs, expansion unit of 10 TB HDDs. All drives Seagate NAS-grade. Drives: "Seagate NAS drives"; expansion unit DX517 (chat 09)
- [x] Hardware facts (chat 09): PSU documented as "1000 W 80+ Bronze" (no brand or model, PdXGB's call); NAS expansion unit is a Synology DX517; drives documented as "Seagate NAS drives"
- [x] `docs/04-multi-gpu.md` rewritten (chat 07): gpu.env approach, `GPU_MAIN_POWER_LIMIT`, anchors, audit script, symptom table, two-GPU monitoring
- [x] `docs/troubleshooting.md`: 2060 fix recorded (PCIe power connector, no BIOS changes) (chat 07); corrected in chat 09: `pcie_aspm=off` is also required
- [x] docs/04 symptom table (Gen1 link, retraining, fallen off the bus) (chat 07)
- [x] `docs/troubleshooting.md`: chat 04 entries added (Grok no web search, tools bind at chat start, LiteLLM restart, HA template entities block, MQTT over LAN) plus the two-GPU monitoring bug (chat 07)

## Decisions (chat 09)

- [x] **Public repo renamed `ai-hub`** (PdXGB/ai-hub). The hostname shouldn't be the project's name; readers pick their own
- [x] **Full neutral rename, prefix `aihub`** (tools, paths, units, env vars, MQTT topics, HA entities). Repo and live server change together through one migration script with backup, dry run and rollback. Repo stays private until it lands
- [x] **Assistant persona:** public templates use a placeholder name; the live Open WebUI model and HA prompt keep their own name (they live in the UIs)
- [x] aihub-mon's HA manufacturer label becomes `ai-hub` (part of the rename)

- [x] `update-image.sh` backups: `/srv/backup/pre-update/`, keep 3 per service, owner-only
- [x] `setup.sh` daemon.json: merge missing log keys plus a restart note; no automatic Docker restart
- [x] `setup.sh` ownership: `/srv/ai` belongs to the sudo user (`.env` 600), as on the server; root jobs still read it
- [x] docs/01: the 2060 was a spare card already on hand; VRAM table shows what runs (measured) plus Frigate as planned
- [x] ~~`pcie_aspm=off` gets removed~~ Reversed: removing it made the 2060 fall off the bus at boot; restored and documented as required (troubleshooting, docs/04)
- [x] Verified on the server (chat 09): LiteLLM keys match docs/03 (`home-assistant`: local-fast, local-ha, claude, gemini, $10 / 30 d; `open-webui-ask-model`: no route list, no budget); GPU placement matches docs/04/05; ComfyUI Python/torch and the NAS fstab line match docs/08/10

## Decisions (chat 08)

- [x] Promote `ask_model.py` and a genericized assistant prompt before writing the model-routing doc
- [x] HA virtual key example uses LiteLLM's documented `/key/generate` fields (`key_alias`, `models`, `max_budget`, `budget_duration`)
- [x] HA MCP goes in `docs/05` as a section, not its own doc. SearXNG goes in `docs/03` (no separate doc)
- [x] Open WebUI web search: 10 results (live value)
- [x] Backups doc waits for the next scrub run (repo `aihub-backup` is older than the live one)
- [x] Fixed: `docs/05` LAN-exposure sentence (Open WebUI and n8n listen on all interfaces); broken troubleshooting anchor to docs/04

## Decisions (chat 07)

- [x] **HA voice LLM moves to the RTX 2060.** Deploy `ollama-ha` (7–9B tool-calling model, keep_alive -1) on the 2060 and point the LiteLLM `local-ha` route at it; no separate HA integration. Done in chat 07; confirmed in chat 09 (`ollama ps` on the 2060: qwen3:8b, 100% GPU, Forever).
- [x] **Consolidate health monitoring on aihub-mon.** Port the old health script's extra checks (ComfyUI service, LiteLLM liveness, all four mounts, local backup age, NAS copy age) into aihub-mon, then disable the old health script on the server and remove it from the repo.
- [x] **License:** code MIT; `docs/` CC BY 4.0.
- [x] **Morning brief:** possibly wanted, not installed. Moved to "Automations to review and install".
- [x] **scrub.sh:** publish the server-run (sudo/python) version, with fixes.
- [x] **History:** re-create the GitHub repo as a single clean commit before making it public (old commits contain a NAS hostname and a personal name).
- [x] **Name in public files:** use the GitHub handle `PdXGB`.
- [x] **Paths:** compose, `.env`, `litellm/`, `searxng/` live in `/srv/ai`; `setup.sh` copies `compose/` there and writes `/srv/ai/.env`.
- [x] **2060 fix:** no BIOS changes; the PCIe power connector plus `pcie_aspm=off` (corrected in chat 09; the connector alone wasn't enough).
- [x] **PSU:** documented as 1000 W 80+ Bronze, no brand or model (decided chat 09).

## Imports from other AIs

- [ ] Run the external-AI handoff prompt (private notes: `_handoffs/files/chat-06-audit-scrub/external-ai-handoff-prompt.md`) in each non-Claude chat that did the server work. Save output as `_handoffs/ext-<ai>-<topic>.md` plus `_handoffs/files/ext-<ai>-<topic>/`. A Claude chat imports each one (check against the repo, update this file) and adds an `ext-` row to the migration log

## Before going public: re-create the repo (clean history)

Old commits contain a NAS hostname and a personal name, so the public repo starts from one clean commit. All steps are in GitHub Desktop, Explorer and GitHub.com; no git commands.

- [x] 1. Commit and push both repos (public and `_handoffs`). Have a chat run the leak audit and link check one last time: PASS. (Chat 09: leak PASS, links PASS, extended audit clean, 58 files to commit.)
- [x] 2. The old repo was kept under its original name as the backup (not renamed); the new one was published as `ai-hub`.
- [x] 3. GitHub Desktop → select `ai-hub` → Repository → **Remove** (removes it from Desktop only; files stay).
- [x] 4. Explorer → `C:\Users\<you>\GitHub\ai-hub` → View → show hidden items → delete the top-level **`.git`** folder only. **Not** `_handoffs\.git` (the private notes repo).
- [x] 5. GitHub Desktop → File → Add local repository → choose that folder → click **create a repository** → name `ai-hub`, Git ignore and License **None** (the files already exist) → Create. Check File → Options → Git still shows the noreply email.
- [x] 6. GitHub Desktop may commit every file right away as "Initial commit"; if it shows them under Changes instead, commit as `ai-hub: initial public release`. Either way, **before publishing**, have the chat read the new `.git` (files only) and confirm: one commit, noreply author email, 58 files, no `_handoffs/`, `staging/` or `.env` (only `.env.example`).
- [x] 7. Publish repository → name `ai-hub`, **keep it private** → Publish. Check the files on GitHub.com, then Settings → Change visibility → **Public**.
- [x] 8. Once it looks right, delete the old repo (its original name, private; history has the NAS name) (Settings → Delete). The local folder now points at `ai-hub`, so nothing local changes; `_handoffs` stays private.

_Chat 09 verified the new `.git` before publishing: 1 commit ("Initial commit", no parent), noreply author, 58 files identical to the working tree, no forbidden paths, 73 objects scanned with no NAS name, domain, IP or GPU UUID._

## Neutral rename (chat 09)

- [x] Repo: tools/paths/units/env/MQTT/HA entities renamed to `aihub` (HA device "AIHub" → `sensor.aihub_*`); persona placeholder; hostname examples to `<hostname>`; README naming note; scrub.sh scrubs the hostname (chat 09)
- [x] Migration script written and sandbox-tested: dry run changes nothing, apply, refuses a second run, rollback restores every file (private notes, since it names the old files) (chat 09)
- [x] Migration applied on the server (chat 09): old units stopped, old HA device cleared (56 topics), paths/units/NAS folder renamed, new aihub-mon/aihub-backup/scripts installed, power limits 325/184 W, ComfyUI restarted idle, 4 timers active, baseline accepted. Backup + old files in `/root/aihub-migration-<stamp>/` on the server
- [x] Old HA device gone; AIHub device has 56 entities (chat 09)
- [x] Old "Groot - …" HA automations deleted (chat 09)
- [x] Home Assistant (chat 09, PdXGB): `aihub-1..6` automations pasted with the notify service, new card, Acknowledge alerts tested, leftover MQTT entities removed
- [x] Verified (chat 09): manual `aihub-backup` run (NAS copy; archive has `.env`, `gpu.env`, `fstab`, `aihub-mon`); scrub run on the server: LEAK CHECK PASS, every collected file identical to the repo except the three expected (searxng secret key, `comfyui.service` user line, `aihub-mon.env` live values vs the example)
- [x] Final leak/link audit (chat 09): leak PASS, links PASS, 58 files, hostname only in the README naming note; pushed commit verified (all 135 objects clean)
- [x] `PdXGB/ai-hub` public; old repo deleted; notes repo still private (checked from outside, chat 09)

## Automations to review and install

- [ ] **Morning brief** (`aihub-brief`): written in chat 01, never installed. Review, decide, install; scrub then collects it.
- [ ] **Photo-to-video n8n form:** works on the LAN; uploads through the Cloudflare tunnel never reach n8n. Rebuild to respond immediately plus a "latest video" link (Cloudflare's 100 s limit).

## To do: on the server (not repo work, tracked here so nothing gets lost)

- [x] the old health script retired (chat 07): timer disabled, files moved to `/root/retired-the old health script/` on the server, removed from the repo; old old health-alerts HA automation deleted (chat 09)
- [ ] memtest86+ overnight (RAM at 3600 MT/s, 4x32 GB)
- [ ] Monthly routine: run `/srv/ai/monthly-update.sh` (scripted in chat 04), then acknowledge the expected aihub-mon file-change alert
- [x] aihub-backup now also archives `/etc/aihub`, the ComfyUI drop-in, `/etc/fstab`, aihub-mon (binary, env, units, baseline) and the MQTT login file (chat 07; live on the server, backup `aihub-backup.pre-chat07`). promoted via scrub run 5
- [x] gpu.env applied on the server (chat 07): `/etc/aihub/gpu.env` created; repo `nvidia-power-limit.service` and `comfyui.service.d/gpu.conf` installed; verified 3090 325 W, 2060 184 W, ComfyUI on the 3090 only; aihub-mon file-change alert acknowledged. Backups: `nvidia-power-limit.service.pre-gpuenv`, `~/comfyui-gpu.conf.pre-gpuenv`
- [x] **`ollama-ha` on the 2060 (chat 07):** `qwen3:8b` (keep_alive -1, ctx 16384) in its own container on the 2060; LiteLLM `local-ha` points at it (think false). HA prompt template reordered for prefix caching (stable first, volatile states last, time at end). Measured: 5.8 s cold / 0.4 s cached vs 8–10 s before on the 3090. Added to `update-image.sh` ORDER + health check (reloads the HA model). Promoted via scrub run 4; docs/05 written; genericized template in `home-assistant/`. Rollback files on the server: `*.pre-ollama-ha` in /srv/ai
- [ ] Confirm HA voice accuracy on qwen3:8b over a few days (dimmer %, setpoints, state questions, confirm-before-unlock); if it misfires, try a larger quant or another model
- [x] aihub-mon multi-GPU fix installed and verified (chat 07): per-GPU parsing (3090 main, 2060 "HA GPU" entities, `gpu_ok` OFF if a card is missing) plus the old health script's checks (ComfyUI, LiteLLM, all mounts, local + NAS backup age). Live `/etc/aihub-mon.env` sets `NAS_BACKUP_DIR`; HA card v2 and automation 6 installed
- [x] Rotated the LiteLLM virtual key `open-webui-ask-model` (old value was exposed in a screenshot); new key in the Ask Model valve, tested via gemini (chat 07)
- [x] `update-image.sh`: `ollama-ha` in ORDER and health checks (chat 07); aihub-mon and the HA card pick up new containers automatically
- [x] assistant model's built-in tools trimmed (confirmed chat 09): 22 built-in functions in 6 groups (default 38), plus `ask_model` and 23 HA MCP tools = 46; docs/06 now lists them. (aihub-mon cloud-spend sensor and the daily update check confirmed working in chat 07)
- [ ] Re-run `~/aihub-gpu-audit.sh` with both GPUs installed (after-install record for docs/04) (chat 02)
- [x] `pcie_aspm=off` tested (chat 09): removed it, rebooted, and the 2060 fell off the bus; restored from `/etc/default/grub.pre-chat09`, rebooted, both GPUs back (2060 Gen3 x4, dmesg clean, full stack up). It stays
- [x] Chat 09 `update-image.sh` installed in `/srv/ai` (sha256 matches the repo); `/srv/backup/pre-update` created (700, the user); the one old `/srv/backups` entry moved there and `/srv/backups` removed. Backup of the old script: `update-image.sh.pre-chat09`
- [x] Old old health-alerts HA automation deleted (confirmed chat 09)
- [x] ask_model v0.2.1 pasted into Open WebUI; verified in webui.db (chat 09)
- [x] Removed the stray exited cloudflared test container `heuristic_jones` (chat 09)
- [ ] Later cleanup on the server: the migration backup folder in `/root` and the retired health-script folder (after a few weeks), old staging folders, the unpacked repo copy and tarball in the home folder
- [ ] Optional: power-cap the 2060 (stock 184 W, uncapped); would need a second line or variable in the power-limit service (chat 02)
- [ ] Optional: Ask Model `max_tokens` 4096 -> 8192 if Grok answers get cut off; add a VPN range to aihub-mon `ALLOWED_NETS` if SSHing in remotely
