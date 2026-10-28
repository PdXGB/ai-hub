#!/usr/bin/env python3
"""Convert ChatGPT or Open WebUI chat exports to the library's raw markdown format.

Usage:
  python3 other_exports_to_md.py chatgpt   <conversations.json>   <library_dir>
  python3 other_exports_to_md.py openwebui <chat-export.json>     <library_dir>

Writes _raw/<chatgpt|local>/chats/YYYY/YYYY-MM-DD_<slug>_<id8>.md and chats.csv.
Written against the documented export formats; check the first few files after running.
"""
import csv, datetime, json, os, re, sys


def slug(s, n=60):
    s = re.sub(r"[^a-z0-9]+", "-", (s or "untitled").lower()).strip("-")
    return s[:n].rstrip("-") or "untitled"


def ts(x):
    if x is None:
        return ""
    if isinstance(x, (int, float)):
        if x > 1e12:  # ms
            x /= 1000
        return datetime.datetime.fromtimestamp(x, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
    return str(x)[:19]


def chatgpt(data):
    for c in data:
        mapping = c.get("mapping") or {}
        node = c.get("current_node")
        chain = []
        while node and node in mapping:  # walk back from the active leaf = the branch you kept
            chain.append(mapping[node])
            node = mapping[node].get("parent")
        msgs = []
        for n in reversed(chain):
            m = n.get("message") or {}
            role = (m.get("author") or {}).get("role")
            if role not in ("user", "assistant"):
                continue
            parts = (m.get("content") or {}).get("parts") or []
            text = "\n".join(p if isinstance(p, str) else p.get("text", "") for p in parts if p)
            if text.strip():
                msgs.append((role, ts(m.get("create_time")), text))
        yield c.get("id") or c.get("conversation_id") or "", c.get("title"), ts(c.get("create_time")), msgs


def openwebui(data):
    for c in data:
        chat = c.get("chat") or {}
        msgs = []
        for m in chat.get("messages") or []:
            if m.get("role") in ("user", "assistant") and (m.get("content") or "").strip():
                msgs.append((m["role"], ts(m.get("timestamp")), m["content"]))
        yield c.get("id", ""), c.get("title") or chat.get("title"), ts(c.get("created_at")), msgs


ME = os.environ.get("LIBRARY_ME", "Me")      # speaker label for your own messages


def main():
    kind, src, lib = sys.argv[1:4]
    ai = {"chatgpt": "chatgpt", "openwebui": "local"}[kind]
    who = {"chatgpt": "ChatGPT", "local": "Local LLM"}[ai]
    out = os.path.join(lib, "_raw", ai)
    data = json.load(open(src, encoding="utf-8"))
    rows = []
    for cid, title, created, msgs in (chatgpt if kind == "chatgpt" else openwebui)(data):
        if not msgs:
            continue
        d = (created or msgs[0][1])[:10] or "0000-00-00"
        rel = f"chats/{d[:4]}/{d}_{slug(title)}_{str(cid)[:8]}.md"
        body = [f"---\nsource: {ai}\nid: {cid}\ntitle: \"{(title or 'Untitled').replace(chr(34), chr(39))}\"\n"
                f"created: {created}\nmessages: {len(msgs)}\n---\n# {title or 'Untitled'}\n\n## Transcript\n"]
        for role, t, text in msgs:
            body.append(f"### {ME if role == 'user' else who} · {t[:16].replace('T', ' ')}\n\n{text.rstrip()}\n")
        p = os.path.join(out, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w", encoding="utf-8", newline="\n").write("\n".join(body))
        rows.append([cid, d, title or "", len(msgs), rel])
    with open(os.path.join(out, "chats.csv"), "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["id", "date", "title", "messages", "file"])
        w.writerows(sorted(rows, key=lambda r: r[1]))
    print(f"{len(rows)} chats -> {out}")


if __name__ == "__main__":
    main()
