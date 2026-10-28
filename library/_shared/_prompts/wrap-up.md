# Wrap-up prompt — paste at the end of any chat, any AI

Use this before closing a chat with Claude, ChatGPT, Gemini, Grok or the local LLM. Attach or paste the library's `INDEX.md` first (`work/INDEX.md`, `personal/INDEX.md`, or both if the chat touched both) so the AI uses existing topic names.

AIs that can write files (Claude with `L:\` = `\\<server LAN IP>\library` connected) write straight into the library. Others output the blocks below; paste each block into the named file.

---

```text
Wrap this chat up for my AI library. I keep notes from every AI in one markdown library sorted by topic. The topic list (INDEX.md) is attached/pasted above.

1. List every distinct subject this chat covered, in order. Map each to an existing topic path from INDEX.md, with its library (e.g. work/topics/site-a/controller-graphics, personal/topics/home/pond). Only propose a new topic if nothing fits — give it a lowercase-hyphen name under work/topics/ or personal/topics/{home,homelab,personal}/.

2. For EACH topic, produce:

   a) A log.md entry, exactly this format, covering only that topic's part of the chat:
      ## YYYY-MM-DD · <short title> · <your platform: claude | chatgpt | gemini | grok | local>
      - **Did:** what we worked on
      - **Decided:** decisions and why
      - **Worked:** what was confirmed working (point to commands.md section)
      - **Open:** anything unresolved
      - **Source:** <platform> chat "<chat title>", <date>

   b) commands.md additions: final working commands/configs/code only, each under a "## <task>" heading with one comment line saying what it does. Skip anything that failed or was superseded.

   c) open.md items: "- [ ] <item> — added YYYY-MM-DD (<platform>)". Include anything you're not sure actually worked, marked "unconfirmed".

   d) README.md "Key facts" changes: new or changed facts (models, firmware, IPs, hostnames, part numbers, people, vendors). Say which existing lines they replace.

3. Keep real values (IPs, hostnames, IDs). Replace passwords, API keys and tokens with "see secrets.md" and list them separately at the very end under "SECRETS (local only)".

4. Facts only, no narration ("the user asked…"). Don't invent outcomes — if this chat doesn't show it worked, it goes in open.md as unconfirmed.

5. Output each block in its own fenced code block, headed with the target file path, e.g.:
   ### work/topics/site-a/controller-graphics/log.md (append)

6. Finish with one line per topic for INDEX.md: | topic path | status | YYYY-MM-DD | +N entries |
```
