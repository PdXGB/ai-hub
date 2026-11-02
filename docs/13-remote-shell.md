# 13 — Remote Shell: SSH and file copy to LAN machines

The assistant can run commands and copy files on other machines on your LAN: the NAS, the firewall, the Home Assistant box, Raspberry Pis. There are two ways in:

- **Open WebUI tool** ("Remote Shell"). Ask in chat ("how full is the NAS?", "copy last night's HA backup to the NAS"). The model proposes the exact command, a dialog shows it, and **nothing runs until you click Confirm**. Local and cloud models can use it.
- **Terminal agent** (`aichat`). In an SSH session on the server, `aichat -e "…"` writes the shell command and asks Execute / Revise / Describe / Cancel.

Both only reach machines you **enrolled** with `aihub-enroll`. Each machine gets a dedicated `aihub` account with two keys, one line per key, so either can be revoked on its own.

```
Open WebUI ──(ssh network, token)──► aihub-ssh ──ssh/scp──► nas, pfsense, ha, pi-*
  tool shows a confirm dialog          key: /srv/ai/ssh/id_ed25519 (aihub-webui)
                                        inventory: /srv/ai/ssh/hosts.conf
                                        log: /srv/ai/ssh/audit.log
you ──ssh──► server: aichat -e ───────────────────ssh/scp──► same hosts
                                        key: ~/.ssh/aihub-terminal
```

## 1. Pieces

| Piece | Where | What it does |
|---|---|---|
| `aihub-ssh` container | `compose/compose.yaml`, [`ssh-runner/`](../ssh-runner/) | Small stdlib Python service with `openssh-client`. No published port. It sits on the internal `ssh` network, which it shares only with Open WebUI, plus its own egress network for reaching the LAN. It needs the bearer token `AIHUB_SSH_TOKEN`. Its root filesystem is read-only, it runs with no capabilities, and it runs as your UID. |
| Remote Shell tool | [`open-webui/remote_shell.py`](../open-webui/remote_shell.py) | `list_remote_hosts`, `run_remote_command`, `fetch_remote_file`, `send_file_to_remote`, `list_transfer_files`. It enforces the confirm dialog, admin-only use, and masking of secret-looking output for cloud models. |
| `aihub-enroll` | [`host/bin/aihub-enroll`](../host/bin/aihub-enroll) | Adds a machine: creates the `aihub` user and installs both keys, asks per host whether that user gets sudo, pins the host key, writes the inventory and tests both keys. |
| `/srv/ai/ssh/` | the server | `id_ed25519` (the sidecar's key), `hosts.conf` (inventory, also your ssh config), `known_hosts` (pinned, keyed by alias), `audit.log`. Backed up nightly with the rest of `/srv/ai`. |
| `/srv/transfer` | the server | Staging folder for copies. Host-to-host copies go fetch → `/srv/transfer` → send. Not backed up. |
| `aichat` | `~/.local/bin`, [`scripts/install-aichat.sh`](../scripts/install-aichat.sh) | The terminal agent. It talks to LiteLLM with its own virtual key. |

## 2. Install

`setup.sh` creates `/srv/ai/ssh` (key, empty inventory), `/srv/transfer`, `AIHUB_SSH_TOKEN`/`AIHUB_UID`/`AIHUB_GID` in `.env`, copies `ssh-runner/` and installs `aihub-enroll`. On an existing server, re-run it from the updated clone (it only adds what's missing), then:

```bash
cd /srv/ai
diff -u ~/ai-hub/compose/compose.yaml compose.yaml   # setup.sh never overwrites compose.yaml: merge the aihub-ssh service,
                                                     # the open-webui networks line and the networks: block by hand
docker compose build aihub-ssh
docker compose up -d aihub-ssh open-webui            # open-webui is recreated once (new network)
docker compose logs aihub-ssh | tail -3              # "aihub-ssh listening on :8022, 0 hosts"
sudo aihub-mon --accept                              # the new container is part of the compose project; accept the file changes
```

**Open WebUI**, as admin:

1. Workspace → Tools → **+** → paste `open-webui/remote_shell.py` → Save.
2. Open the tool's **Valves** and set `runner_token` to the `AIHUB_SSH_TOKEN` value (`grep AIHUB_SSH_TOKEN /srv/ai/.env`).
3. Leave the tool **private**: Access → only you. `admin_only` (default on) also blocks non-admin users.
4. Workspace → Models → your assistant → Tools → tick **Remote Shell**. Do the same for any cloud model you want to drive it. Native function calling must be on (the assistant already uses it).

## 3. Enroll machines

Run on the server as **your own user**. The alias is what you and the models call the machine.

**Linux boxes and Raspberry Pis** (any distro with `useradd` and `sudo`):

```bash
aihub-enroll pi-garage 192.168.x.y                  # logs in as you; asks your password/sudo password
aihub-enroll pi-barn pi-barn.lan --admin pi         # different login name on the target
```

**Proxmox host**: `aihub-enroll proxmox <IP> --admin root`. Proxmox has no sudo by default; answering yes to the sudo question offers to install it (`apt-get install -y sudo`). With sudo, the models can run `qm`/`pct` (e.g. `sudo qm snapshot <vmid> pre-change` before you touch a VM). A Home Assistant OS VM on it is enrolled separately, through its own SSH add-on (below).

**Hosts that only accept keys** (`Permission denied (publickey)` with no password prompt, common on Proxmox): open a root shell on the box (Proxmox web UI → node → Shell), create the user by hand (`useradd -m -s /bin/bash aihub; usermod -p '*' aihub`, both key lines into `/home/aihub/.ssh/authorized_keys` (700/600, owned by aihub), optionally `apt-get install -y sudo` + `/etc/sudoers.d/90-aihub`), print `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`, then `aihub-enroll <alias> <IP> --manual` and compare the fingerprint.

It creates `aihub` (no password, key login only) and adds both keys. It asks **"Give aihub passwordless sudo on <host>? [y/N]"**; answer per machine. It prints the target's own host-key fingerprint and refuses to continue if the fingerprint seen over the network differs. Then it tests both keys.

**Synology NAS** (DSM 7), then `--manual`:

1. Control Panel → Terminal & SNMP → **Enable SSH service**.
2. Control Panel → User & Group → create `aihub` (long random password), member of **administrators** (DSM allows SSH only for admins). Under User → Advanced, **Enable user home service**.
3. `aihub-enroll nas <NAS IP> --manual` prints two key lines. In another terminal: `ssh aihub@<NAS IP>` (password), then:
   ```bash
   mkdir -p ~/.ssh && chmod 700 ~/.ssh && nano ~/.ssh/authorized_keys   # paste both lines
   chmod 600 ~/.ssh/authorized_keys && chmod 755 ~                     # DSM homes are often too open for sshd
   ```
   Answer `y` in the enroll window and accept the host key.
4. Commands needing root (`sudo`) ask for the password and fail non-interactively. Read-only checks and copies to shared folders (`/volume1/<share>`) work. If scp complains, aihub-ssh retries with the legacy protocol automatically. Turning on SFTP (File Services → FTP → SFTP) avoids that retry.

**pfSense**, then `--manual`:

1. System → Advanced → Admin Access → Secure Shell: **Enable**, SSHd Key Only: **Public Key Only**.
2. System → User Manager → Add: username `aihub`, random password. Paste the two lines from `aihub-enroll pfsense <IP> --manual` into **Authorized SSH Keys**. Under Effective Privileges, add **User - System: Shell account access** → Save.
3. Answer `y`, then compare the fingerprint with Diagnostics → Command Prompt: `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`.
4. Status commands (`pfctl -s info`, `netstat -rn`, `cat /var/log/…`) work. Root-only commands need the **sudo** package (System → Package Manager) plus a rule for `aihub`. The firewall is the riskiest box here, so read every confirm dialog for it closely.

**Home Assistant host**:

- **Home Assistant OS**: install the **Advanced SSH & Web Terminal** add-on. Set `username: aihub`, paste both key lines under `authorized_keys`, set `password: ""` and `sftp: true`, then start it. Run `aihub-enroll ha <HA IP> --manual` (add `--port N` if you changed the add-on's port). The add-on shell has the `ha` CLI (`ha core info`, `ha backups list`) and `/backup`.
- **HA in Docker on a Linux box**: enroll it like any Linux box above.

`aihub-enroll --list` shows the inventory. After enrolling, `ssh <alias>` works from your own account on the server too, once `install-aichat.sh` has set up your ssh config (§5).

## 4. Using it in Open WebUI

Ask normally: "what's using space on the NAS", "show the last 50 lines of the HA log", "copy /backup/<newest>.tar from ha to nas:/volume1/backups/ha/". The model calls `list_remote_hosts` and then a run or copy. **Every command and copy opens a dialog** showing the host, login, exact command or paths, which model asked, and whether the output stays local or goes to a cloud provider. **Cancel** stops it, and the model is told not to retry.

- Output is capped at 12,000 characters for the model (the `max_output_chars` valve) and 64 KB per stream at the sidecar. Each call has a timeout of 60 s by default, up to 600 s; copies get 600 s.
- **Cloud models** (any model not listed in the `local_models` valve) get output with keys, tokens, `password=`-style values, private keys and password hashes masked. The command itself still goes to them. Use a local model for anything you'd rather not send out at all.
- **Auto-approve (valve `auto_approve`, off by default):** for a job you've already reviewed, turn it on, let the model work, then turn it **off**. Commands then run without dialogs; each one still shows in the chat as "⚠ auto-approved" with the exact command, and the audit log marks it `[auto-approved]`. Updating the tool code keeps your valve values.
- `/srv/transfer` keeps copies until you delete them: `ls -la /srv/transfer`.
- Audit trail: `tail -n 20 /srv/ai/ssh/audit.log` shows one JSON line per call (time, caller email + model, host, command or paths, exit code). Refused calls are logged too.

## 5. Terminal agent (aichat)

1. Create a LiteLLM virtual key for it (same API as [docs/03 §5](03-docker-stack.md)). Adjust routes and budget to taste:
   ```bash
   curl -s http://127.0.0.1:4000/key/generate -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
     -d '{"key_alias":"terminal","models":["local-fast","local-deep","claude","gemini"],"max_budget":5,"budget_duration":"30d"}'
   ```
2. As your own user: `AIHUB_TERMINAL_KEY=sk-… bash scripts/install-aichat.sh`. It downloads the aichat binary to `~/.local/bin` and writes `~/.config/aichat/config.yaml` (mode 600). It also prepends `Include /srv/ai/ssh/hosts.conf` to `~/.ssh/config` and adds your `~/.ssh/aihub-terminal` key and the pinned `known_hosts`.
3. Use it:
   ```bash
   aichat -e "how much free space is on nas and pi-garage"     # proposes a command; Execute / Revise / Describe / Cancel
   aichat -m litellm:claude -e "find which pi has the highest load"
   aichat "explain this pfSense rule: …"                       # plain chat, nothing runs
   ```
   Nothing runs without your choice at the prompt. `aichat -e` writes commands for your local shell, so it uses `ssh <alias> '…'` and `scp`. That's why the inventory is in your ssh config.

## 5a. Driving the server from Claude Desktop

A separate path lets a Claude Desktop session run commands on the server itself (not through Open WebUI):

```
Claude Desktop ──Windows-MCP PowerShell──► ssh.exe ──► server, user claude
                                           key: %USERPROFILE%\.ssh\aihub_claude
```

- **Server side:** a dedicated `claude` user with its own `authorized_keys` and `/etc/sudoers.d/90-claude`. Revoke it by deleting that key line or the user, then run `sudo aihub-mon --accept` (those files are tripwired).
- **Laptop side:** an ed25519 key used only for this. Claude Desktop has no SSH connector of its own; it uses the Windows-MCP PowerShell tool to call Windows OpenSSH (`C:\Windows\System32\OpenSSH\ssh.exe`, not on that tool's PATH). If Windows-MCP isn't connected, fall back to pasting commands yourself.
- **Pattern:** pipe a script in rather than quoting it inline, and strip the BOM and CRs PowerShell adds:
  ```powershell
  $cmd | & C:\Windows\System32\OpenSSH\ssh.exe -i "$env:USERPROFILE\.ssh\aihub_claude" -o BatchMode=yes -o IdentitiesOnly=yes claude@<server> "sed '1s/^\xef\xbb\xbf//' | tr -d '\r' | bash -s"
  ```
- **From the server onward:** Claude reaches enrolled hosts through the `aihub-ssh` container, using the same inventory and pinned host keys as the Open WebUI tool.
- **Rules:** read-only checks run without asking; changes only after your OK; no git.

## 6. Security model

- **Only enrolled hosts.** The sidecar accepts inventory aliases only: no raw IPs, no `-o` options, nothing that resolves outside private ranges (`ALLOW_PUBLIC_HOSTS=1` to override). Host keys are pinned (`StrictHostKeyChecking yes`). Forwarding, agent forwarding and local commands are forced off.
- **Confirm everything.** The dialog comes from the tool's code, not the prompt, so a model (or a web page it read) can't talk its way past it. Without a dialog channel (`__event_call__` missing, timeout, error) the call is **declined**.
- **Key separation.** The sidecar's key never enters Open WebUI, which faces the internet through the tunnel. Your terminal key is separate. Each target lists both keys by comment (`aihub-webui@…`, `aihub-terminal@…`).
- **Least privilege per host.** `aihub` gets sudo only where you said yes at enroll. Synology and pfSense accounts are non-root unless you change that.
- **Reach.** Only Open WebUI shares the sidecar's network. The token keeps out anything else that gets onto it. The tool is admin-only and private.
- **Logged.** Everything goes to `/srv/ai/ssh/audit.log`, which `aihub-backup` copies nightly with `/srv/ai`.

The backup archive includes `/srv/ai/ssh/id_ed25519`. Backups are already owner-only, and setting `BACKUP_AGE_RECIPIENT` (docs/10) encrypts the NAS copy.

## 7. Remove or revoke

- One machine: `aihub-enroll --remove <alias>` drops it from the inventory and known_hosts. On the machine: `sudo deluser --remove-home aihub; sudo rm -f /etc/sudoers.d/90-aihub` (Linux/Pi), or delete the user (DSM, pfSense) or the add-on's keys (HA OS).
- Revoke only the chat tool everywhere: replace the key (`ssh-keygen -t ed25519 -N '' -C aihub-webui@<server> -f /srv/ai/ssh/id_ed25519`, overwrite), restart `aihub-ssh` and remove the old `aihub-webui` line on each machine. Or just untick the tool in Open WebUI.
- Turn it all off: `docker compose stop aihub-ssh`. The tool then answers "could not reach aihub-ssh".

## 8. Troubleshooting

| Symptom | Fix |
|---|---|
| `Permission denied (publickey)` | The key line is missing or the permissions are wrong on the target: `~` not group-writable, `~/.ssh` 700, `authorized_keys` 600 (DSM: `chmod 755 ~`). |
| `Host key verification failed` | The machine was reinstalled or its address now points elsewhere. Check why, then `aihub-enroll --remove <alias>` and enroll again. |
| `… is not in the inventory` | The model guessed a name. It should call `list_remote_hosts`. Or enroll the machine. |
| `resolves to a non-LAN address` | The HostName resolves publicly (split DNS). Use the LAN IP in `hosts.conf`. |
| Dialog never appears / call declined | Open WebUI needs the chat open in a browser tab to show the dialog. On mobile, keep the app in the foreground. Update Open WebUI if confirmations aren't supported. |
| `could not reach aihub-ssh` | `docker compose ps aihub-ssh`. Open WebUI must be on the `ssh` network (compose `networks: [default, ssh]` + `up -d open-webui`). |
| `unauthorized` | The `runner_token` valve doesn't match `AIHUB_SSH_TOKEN`. Copy it again. If you changed `.env`, run `up -d aihub-ssh`. |
| aihub-ssh exits: key "bad permissions"/"owned by" | `AIHUB_UID`/`AIHUB_GID` in `.env` must be the owner of `/srv/ai/ssh`. `chmod 600 /srv/ai/ssh/id_ed25519`, then `docker compose build aihub-ssh && docker compose up -d aihub-ssh`. |
| scp fails with `subsystem request failed` | The automatic `-O` retry handles most cases. If not, enable SFTP on the target. |
| The server itself as a target times out | ufw blocks traffic from Docker networks to the host's own port 22. You're already on the server (use `aichat` there). If you really want it, allow the `ssh-egress` subnet to port 22 in ufw. |
| `update-image.sh aihub-ssh` refuses | Expected: the image is built locally. `docker compose build --pull aihub-ssh && docker compose up -d aihub-ssh`. `monthly-update.sh` does this for you. |
