# Session start — give any AI the context for a topic

Paste the topic's `README.md` and `open.md` (and `commands.md` if it's hands-on work) at the start of a new chat, then:

```text
This is my current notes for <topic>. README = current state and key facts, open.md = what's unresolved, commands.md = what's known to work. Treat these as the starting point; don't re-suggest things marked as done or failed in the notes. Ask if something in the notes looks wrong or out of date. At the end I'll run my wrap-up prompt.
```

Claude with `L:\` (`\\<server LAN IP>\library`) connected can read the files itself: "Read library/<work|personal>/topics/<path>/ and pick up where we left off."
