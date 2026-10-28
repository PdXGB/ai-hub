# Bulk import — getting each AI's history into the library

Same end result as the Claude import: raw transcripts in `_raw/<ai>/`, then entries sorted into `topics/`.

**Recommended path:** export → convert to markdown with `_tools/` → have one AI that can read the folder (Claude in Cowork with `L:\` connected, or the server's local model) do the sorting with the prompt below. Web chat UIs (ChatGPT, Gemini, Grok) can't read your library share, so for them the prompt works on an uploaded export instead, and you save what they give back.

## 1. Export from each platform

| AI | Where | What you get |
|---|---|---|
| Claude | Settings → Privacy → Export data | zip with `conversations.json` (done 2026-10-25) |
| ChatGPT | Settings → Data controls → Export data | emailed zip with `conversations.json` |
| Gemini | Google Takeout → select "My Activity" → filter to "Gemini Apps" | `MyActivity.html` / `.json` (prompts + responses, no threads) |
| Grok | grok.com → Settings → Data controls (look for download/export your data) | zip — format not checked yet |
| Local LLM (Open WebUI on the server) | Settings → Chats → Export all chats | `chat-export-*.json` |

Menu names change; if one isn't where the table says, search the platform's help for "export data".

Save each export to `L:\personal\_raw\<ai>\_export\` (chatgpt, gemini, grok, local). The sorting step copies work chats' transcripts to `work/_raw/`.

## 2. Convert to markdown

```bash
# ChatGPT and Open WebUI formats (written from the documented formats; not yet tested on real exports)
python3 _shared/_tools/other_exports_to_md.py chatgpt  personal/_raw/chatgpt/_export/conversations.json  personal
python3 _shared/_tools/other_exports_to_md.py openwebui personal/_raw/local/_export/chat-export.json      personal
```

Gemini and Grok: drop the export in `_raw/<ai>/_export/` and ask Claude to write a converter once the real format is visible.

## 3. Sorting prompt

Use with an AI that can read `_raw/<ai>/` (or upload the export to the AI itself — ChatGPT with file analysis can read its own `conversations.json`).

```text
I keep a markdown library of everything I work on with AI, sorted by topic. Read library/_shared/README.md (rules) and library/work/INDEX.md + library/personal/INDEX.md (existing topics) first — attached/pasted above.

Your job: sort my <PLATFORM> chat history into that library.

1. Go through every conversation. Skip empty ones. For each, list the distinct subjects it covers, in order. A chat that jumps from one subject to another (e.g. controller graphics, then lighting modules) gets split — each part goes to its own topic.

2. Map each subject to an existing topic path from INDEX.md. Only create a new topic if nothing fits; use a lowercase-hyphen name under work/topics/ or personal/topics/{home,homelab,personal}/ and tell me why.

3. For each topic, write log.md entries (oldest first) in this exact format:
   ## YYYY-MM-DD · <short title> · <platform>
   - **Did:** …
   - **Decided:** … (and why)
   - **Worked:** … (point to commands.md)
   - **Open:** …
   - **Source:** [raw](<relative path to _raw/<platform>/… file>)   or   <platform> chat "<title>", <date>
   Use only bullets that have content.

4. commands.md: final working commands/configs/code per topic, under "## <task>" headings with one comment line each. Skip dead ends.

5. open.md: unresolved items and anything not confirmed working, as "- [ ] <item> — added YYYY-MM-DD (<platform>)".

6. README.md Key facts: new facts (models, IPs, hostnames, part numbers, people) — list them; don't rewrite what's there.

7. Keep real IPs, hostnames, IDs. Passwords/API keys/tokens: replace with "see secrets.md" and list them at the very end under SECRETS (local only).

8. Facts only, no "the user asked" narration. Never invent outcomes.

Work in batches of ~25 conversations, oldest first. After each batch: output the file blocks (one fenced block per target file, headed with its path and "append"), then a table: conversation title | date | topics | notes. Wait for "next" before continuing.
```
