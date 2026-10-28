# AI library

One place for everything worked on with any AI — Claude, ChatGPT, Gemini, Grok, and the local LLMs on the server — sorted by **topic**, not by which AI it came from.

Location: on the server, `/srv/library/` (`LIBRARY_DIR`), shared on the LAN as `\\<server LAN IP>\library` (everything, e.g. mapped as `L:`) and `\\<server LAN IP>\library-work` (work only). Backed up nightly with the server's backups and mirrored to the NAS. Setup: the repo's [docs/12](https://github.com/PdXGB/ai-hub/blob/main/docs/12-library.md). Plain markdown: readable in any editor, Obsidian, or GitHub.

Two libraries, kept apart: **work** (your job) and **personal** (home, homelab, personal). Each has its own INDEX, topics and raw transcripts, so work can be shared or synced on its own.

## Layout

```
library/
  _shared/
    README.md        ← this file: the rules every AI follows
    _template/       ← blank topic files + entry format
    _prompts/        ← prompts to paste into each AI
    _tools/          ← converters (export → markdown)
  work/              ← your job  → can be its own git repo / share
    INDEX.md         ← every work topic: entries, last touched
    topics/          ← e.g. <site>/<topic>, management
    _raw/<ai>/       ← untouched transcripts for work topics
  personal/
    INDEX.md
    topics/
      home/          ← house, property, Home Assistant
      homelab/       ← the AI server, home network, self-hosting
      personal/      ← career, health, vehicles, fun, misc
      _unsorted/
    _raw/<ai>/       ← untouched transcripts per AI (never edited, source of truth)
```

## A topic folder

| File | What goes in it |
|---|---|
| `README.md` | What this is, current state, key facts (models, IPs, part numbers, people, logins). Rewritten as things change — always the *current* truth. |
| `log.md` | Dated entries, newest at the bottom. One entry per chat (or per chat segment when a chat changed subjects). Never rewritten, only appended. |
| `commands.md` | Commands, configs, code and searches that worked. Final versions only; dead ends stay in the raw transcript. |
| `open.md` | Unresolved items, questions, next steps. Remove items when done (note the fix in log.md). |
| `files/` | Scripts, configs, exports, images produced for this topic. |

## Rules (for every AI)

1. **Topic first.** File by subject, in the right library: Work goes in `work/`, everything else in `personal/`. A chat that covered both gets an entry on each side; its raw transcript is copied to both `_raw/` folders. If a chat covered two subjects (controller graphics, then lighting modules), write one entry in each topic's `log.md`, each covering only its part.
2. **Tag the source.** Every log entry header ends with the AI: `· claude`, `· chatgpt`, `· gemini`, `· grok`, `· local`.
3. **Link the raw transcript** when one exists in `_raw/`. If none exists, say `Source: <ai> chat "<title>", <date>`.
4. **Keep real values.** This library is local and private: keep IPs, hostnames, device IDs, part numbers as-is. Exception: passwords, API keys and tokens go in the topic's `secrets.md` (gitignored), and the notes say "see secrets.md".
5. **Facts over narration.** What was done, what was decided and why, what worked, what's still open. No "The user asked…" prose.
6. **Don't invent outcomes.** If a transcript doesn't show whether something worked, put it in `open.md` as "unconfirmed".
7. **New topic?** Copy `_shared/_template/topic/`, use a lowercase-hyphen name under the right library and domain, and add a row to that library's `INDEX.md`.
8. **Update the library's INDEX.md** last-touched date and entry count for every topic you change.

## Log entry format

```markdown
## 2026-10-23 · Lighting gateway API integration · claude
- **Did:** Reviewed the lighting gateway's REST API for reading/writing scenes from the building controller.
- **Decided:** Pilot one gateway on one floor before buying more — cost and mesh range unknown.
- **Worked:** `curl` call in commands.md → "Gateway scene list".
- **Open:** Does the gateway expose per-fixture status? (→ open.md)
- **Source:** [raw](../../../_raw/claude/chats/2026/2026-10-23_lighting-gateway-api-integration_xxxxxxxx.md)   ← relative to the topic folder, inside the same library
```

## Git (optional)

- `work/` can be its own private repo (or just the `library-work` share) so work notes reach the work PC. Commit from GitHub Desktop.
- Never commit `_raw/` or `secrets.md` (see `.gitignore`).
