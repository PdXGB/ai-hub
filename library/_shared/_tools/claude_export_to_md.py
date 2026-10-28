#!/usr/bin/env python3
"""Convert an unzipped Claude data export into plain markdown.

Usage: python3 claude_export_to_md.py <unzipped_export_dir> <library_dir>

Writes into <library_dir>/_raw/claude/:
  chats/YYYY/YYYY-MM-DD_<slug>_<id8>.md   one file per conversation
  docs/<slug>.md                          Claude Docs pages / artifacts
  projects/<slug>.md                      project instructions + knowledge files
  design/<slug>.md                        design chats
  memories.md, routines.md
  chats.csv                               index: id, date, title, msgs, file
Re-running overwrites the same files (names are stable).
"""
import csv, glob, json, os, re, sys

SRC, LIB = sys.argv[1], sys.argv[2]
ME = os.environ.get("LIBRARY_ME", "Me")      # speaker label for your own messages
OUT = os.path.join(LIB, "_raw", "claude")


def slug(s, n=60):
    s = re.sub(r"[^a-z0-9]+", "-", (s or "untitled").lower()).strip("-")
    return (s[:n].rstrip("-")) or "untitled"


def w(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def fence(text, lang=""):
    t = text or ""
    ticks = "````" if "```" in t else "```"
    return f"{ticks}{lang}\n{t.rstrip()}\n{ticks}\n"


def short(v, n=300):
    s = v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)
    s = s.replace("\n", " ")
    return s if len(s) <= n else s[:n] + " …"


def render_msg(m):
    who = ME if (m.get("sender") or m.get("role")) in ("human", "user") else "Claude"
    out = [f"### {who} · {m.get('created_at','')[:16].replace('T',' ')}\n"]
    blocks = m.get("content") or []
    if isinstance(blocks, str):
        blocks = [{"type": "text", "text": blocks}]
    elif isinstance(blocks, dict):  # design chats: {"text":..., "attachments":[...]} (attachments = system specs, skipped)
        inner = blocks.get("content") if "content" in blocks else blocks.get("text")
        if not isinstance(inner, str):
            inner = json.dumps(inner, ensure_ascii=False) if inner else ""
        blocks = [{"type": "text", "text": inner}]
    blocks = [b if isinstance(b, dict) else {"type": "text", "text": str(b)} for b in blocks]
    if not blocks and m.get("text"):
        blocks = [{"type": "text", "text": m["text"]}]
    for b in blocks:
        t = b.get("type")
        if t == "text" and (b.get("text") or "").strip():
            out.append(b["text"].rstrip() + "\n")
        elif t == "tool_use":
            out.append(f"> 🔧 `{b.get('name','tool')}` {short(b.get('input',''))}\n")
        elif t == "tool_result":
            c = b.get("content")
            if isinstance(c, list):
                c = " ".join(x.get("text", "") for x in c if isinstance(x, dict))
            if c:
                out.append(f"> ↳ result: {short(c, 200)}\n")
        # thinking / token_budget / injected blocks are skipped
    for a in m.get("attachments") or []:
        out.append(f"\n**Attachment: {a.get('file_name','file')}**\n")
        if a.get("extracted_content"):
            out.append(fence(a["extracted_content"]))
    for f in m.get("files") or []:
        out.append(f"\n_File: {f.get('file_name', f.get('file_uuid','file'))}_\n")
    return "\n".join(out)


def conversations():
    data = json.load(open(os.path.join(SRC, "conversations-000", "conversations.json"), encoding="utf-8"))
    rows = []
    for c in sorted(data, key=lambda x: x["created_at"]):
        msgs = c.get("chat_messages") or []
        if not msgs:
            continue
        d = c["created_at"][:10]
        fn = f"{d}_{slug(c.get('name'))}_{c['uuid'][:8]}.md"
        rel = f"chats/{d[:4]}/{fn}"
        head = [
            "---",
            "source: claude",
            f"id: {c['uuid']}",
            f"title: \"{(c.get('name') or 'Untitled').replace(chr(34), chr(39))}\"",
            f"created: {c['created_at'][:19]}",
            f"updated: {c.get('updated_at','')[:19]}",
            f"messages: {len(msgs)}",
            "---",
            f"# {c.get('name') or 'Untitled'}\n",
        ]
        if c.get("summary"):
            head.append("## Summary (Claude export)\n\n" + c["summary"].strip() + "\n")
        head.append("## Transcript\n")
        body = "\n".join(render_msg(m) for m in msgs)
        w(os.path.join(OUT, rel), "\n".join(head) + "\n" + body)
        rows.append([c["uuid"], d, c.get("name") or "", len(msgs), rel])
    with open(os.path.join(OUT, "chats.csv"), "w", encoding="utf-8", newline="") as f:
        cw = csv.writer(f)
        cw.writerow(["id", "date", "title", "messages", "file"])
        cw.writerows(rows)
    return len(rows)


def docs():
    n = 0
    for a in glob.glob(os.path.join(SRC, "frames-000", "artifacts", "*")):
        meta = json.load(open(os.path.join(a, "artifact.json"), encoding="utf-8"))
        title = meta["versions"][-1].get("title", "untitled")
        page = os.path.join(a, "page.md")
        if os.path.exists(page):
            body = open(page, encoding="utf-8").read()
        else:  # HTML artifacts: keep the newest version's files as-is
            vers = sorted(glob.glob(os.path.join(a, "versions", "*")))
            files = [p for p in glob.glob(os.path.join(vers[-1], "**", "*"), recursive=True) if os.path.isfile(p)] if vers else []
            body = "\n".join(f"## {os.path.relpath(p, vers[-1])}\n\n" + fence(open(p, encoding='utf-8', errors='replace').read())
                             for p in files if p.endswith((".html", ".md", ".json", ".css", ".js")))
        w(os.path.join(OUT, "docs", slug(title) + ".md"),
          f"---\nsource: claude\nkind: {meta['kind']}\nid: {meta['id']}\nupdated: {meta.get('updated_at','')[:19]}\n---\n# {title}\n\n{body}")
        n += 1
    return n


def projects():
    for f in glob.glob(os.path.join(SRC, "projects-000", "projects", "*.json")):
        p = json.load(open(f, encoding="utf-8"))
        if p.get("is_starter_project"):
            continue
        out = [f"---\nsource: claude\nid: {p['uuid']}\n---\n# Project: {p['name']}\n",
               f"{p.get('description','')}\n", "## Instructions\n", (p.get("prompt_template") or "_none_") + "\n"]
        for d in p.get("docs") or []:
            out.append(f"## Knowledge file: {d.get('filename')}\n\n" + fence(d.get("content", ""), "markdown"))
        w(os.path.join(OUT, "projects", slug(p["name"]) + ".md"), "\n".join(out))


def design():
    for f in glob.glob(os.path.join(SRC, "design_chats-000", "design_chats", "*.json")):
        c = json.load(open(f, encoding="utf-8"))
        name = (c.get("project") or {}).get("name") or c.get("title")
        msgs = "\n".join(render_msg(m) for m in c.get("messages") or [])
        w(os.path.join(OUT, "design", slug(name) + ".md"),
          f"---\nsource: claude\nid: {c['uuid']}\ncreated: {c['created_at'][:19]}\n---\n# Design: {name}\n\n{msgs}")


def memories():
    m = json.load(open(glob.glob(os.path.join(SRC, "memories-000", "memories", "*.json"))[0], encoding="utf-8"))
    out = ["# Claude memory export\n", "## Conversation memory summary\n", (m.get("conversations_memory") or "") + "\n"]
    pm = m.get("project_memories") or {}
    for k, v in (pm.items() if isinstance(pm, dict) else []):
        out.append(f"## Project memory {k}\n\n{v}\n")
    for mf in m.get("memory_files") or []:
        if isinstance(mf, dict):
            out.append(f"## {mf.get('path', mf.get('name', 'file'))}\n\n" + fence(mf.get("content", ""), "markdown"))
    w(os.path.join(OUT, "memories.md"), "\n".join(out))


def routines():
    p = os.path.join(SRC, "claude_code_cloud-000", "claude_code_cloud", "routines.json")
    if not os.path.exists(p):
        return
    r = json.load(open(p, encoding="utf-8")).get("claude_code_cloud", [])
    out = ["# Scheduled tasks (Claude)\n"]
    for x in r:
        out.append(f"## {x.get('name')}\n\nSchedule: `{x.get('cron_expression') or x.get('schedule') or ''}`\n\n" + fence(x.get("prompt", "")))
    w(os.path.join(OUT, "routines.md"), "\n".join(out))


if __name__ == "__main__":
    n = conversations()
    k = docs()
    projects(); design(); memories(); routines()
    print(f"chats: {n}  docs: {k}  -> {OUT}")
