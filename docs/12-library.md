# 12 — AI library: every chat, sorted by topic

A plain-markdown library of everything worked on with any AI (Claude, ChatGPT, Gemini, Grok, the local models), sorted by **topic** rather than by which AI it came from. It lives on the server, stays on the LAN, and is backed up with everything else. Because it's just folders of markdown, any AI can read it: paste a topic's notes into a chat, or let an AI that can see the folder read and write it directly.

The rules, templates, prompts and converters are in [`library/_shared/`](../library/_shared/). Only that skeleton is in this repo. The library itself holds real IPs, hostnames, health notes and `secrets.md` files, so it **never** goes in a public repo.

## 1. Layout

```
/srv/library/                  owner: your user, folders 700, files 600
  _shared/                     rules (README.md), _template/topic/, _prompts/, _tools/
  work/                        your job, kept apart so it can be shared or synced on its own
    INDEX.md                   every topic: entries, last touched
    topics/<topic>/            README.md (current state, key facts), log.md (dated entries),
                               commands.md (what works), open.md (unresolved), files/, secrets.md
    _raw/<ai>/                 untouched transcripts, the source of truth
  personal/                    home, homelab, personal: same structure
```

The full rules (topic first, tag the source, keep real values but secrets only in `secrets.md`, facts over narration, never invent outcomes) and the log entry format are in [`library/_shared/README.md`](../library/_shared/README.md).

## 2. Install

[`setup.sh`](../scripts/setup.sh) asks for `LIBRARY_DIR` (default `/srv/library`, blank skips it) and creates the skeleton: `_shared/` from the repo, then `work/` and `personal/` with an empty `INDEX.md`, `README.md`, `topics/` and `_raw/`. Re-runs never overwrite your notes. The OS drive is fine: years of chats are a few MB. An external drive works too: mount it by label with `nofail` at `LIBRARY_DIR` ([docs/02](02-ubuntu-nvidia.md) shows the fstab pattern).

## 3. Sharing it on the LAN (Samba)

One Samba config, [`host/samba/smb.conf`](../host/samba/smb.conf), with two shares:

| Share | Path | For |
|---|---|---|
| `library` | `/srv/library` | You: everything |
| `library-work` | `/srv/library/work` | A work PC: work only |

Locked down: SMB3 only, encryption required, no guest, NetBIOS off, bound to the LAN interface and localhost, `hosts allow` = your LAN, no printers.

```bash
sudo apt install samba
sudo systemctl disable --now nmbd                       # NetBIOS name service: not needed
sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.dist
sudo install -m 644 host/samba/smb.conf /etc/samba/smb.conf
sudo nano /etc/samba/smb.conf                           # fill <LAN_IFACE>, <LAN_CIDR>, <user>
testparm -s && sudo systemctl restart smbd
sudo smbpasswd -a <user>                                # the share password (separate from the login)
sudo ufw allow from <LAN_CIDR> to any port 445 proto tcp comment 'Samba library from LAN'
sudo aihub-mon --dry-run </dev/null | tail -1            # expect: new ports :445, /etc/group (sambashare)
sudo aihub-mon --accept </dev/null
```

On Windows: `net use L: \\<server LAN IP>\library /user:<user> /persistent:yes`. Connect `L:\` as a folder in an AI desktop app (Claude Cowork, for example), and that AI can read topics and write wrap-ups straight into the library.

Installing Samba trips two aihub-mon tripwires once ([docs/09](09-monitoring.md#2-security-tripwires)): new listening ports (445) and `/etc/group` (the package adds a `sambashare` group). Check that's all the dry run lists, then acknowledge.

## 4. Backups

`aihub-backup` puts `/srv/library` in the nightly `aihub-config.tar.gz`, which is mirrored to the NAS ([docs/10](10-backups.md)). To pull one topic back out:

```bash
B=$(ls -1d /srv/backup/20* | tail -1)
sudo tar -tzf "$B/aihub-config.tar.gz" | grep '^srv/library/work/topics/<topic>/'
sudo tar -xzf "$B/aihub-config.tar.gz" -C ~/restore-test srv/library/work/topics/<topic>
```

## 5. Using it

| When | Prompt (in `_shared/_prompts/`) |
|---|---|
| Starting a chat on a topic | `session-start.md`: paste the topic's README + open.md (+ commands.md) |
| Ending any chat, any AI | `wrap-up.md`: the AI returns log/commands/open/README blocks per topic, or writes them itself if it can see the folder |
| Importing an AI's history | `bulk-import.md`: export, convert with `_tools/`, then sort into topics in batches |

Converters: `_tools/claude_export_to_md.py` (Claude data export) and `_tools/other_exports_to_md.py` (ChatGPT, Open WebUI). They write to `<library>/_raw/<ai>/`. Set `LIBRARY_ME` to label your own messages (default `Me`).

## 6. Next (not built yet)

- Open WebUI knowledge collections `library-work` and `library-personal` ([docs/07](07-knowledge-base.md)), re-indexed nightly, so the local models can search the notes without anything leaving the house.
- Wrap-ups from the local model written straight into the library.
- Optional version history: a local git repo per library on the server (nothing pushed anywhere).
