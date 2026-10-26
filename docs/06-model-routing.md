# 06 — Model routing: Groot and `ask_model`

**Local first, cloud when it's worth it.** Chat starts on a local model. It escalates to a cloud model, or to the big local one, only when that clearly improves the answer. It never escalates private data without being told to, and it stays inside a hard monthly budget.

Three pieces:

| Piece | What it is | File |
|---|---|---|
| LiteLLM routes + budgets | The gateway, the route names, $25 per cloud route and $50 total per 30 days | [docs/03](03-docker-stack.md#5-litellm-routes-and-budgets) |
| "Groot" model | An Open WebUI custom model on `local-fast` with a system prompt that knows the routes and the rules | [`open-webui/groot-system-prompt.md`](../open-webui/groot-system-prompt.md) |
| `ask_model` tool | An Open WebUI tool that lets Groot hand a self-contained task to another route | [`open-webui/ask_model.py`](../open-webui/ask_model.py) |

## 1. Escalation rules

The system prompt carries the rules, so the model applies them per request:

1. Default to `local-fast`.
2. Cheapest model that will do the job: `gemini` → `claude` → `grok` / `gemini-pro` → `claude-opus`.
3. **Private stays local:** credentials, network and security configs, other people's data, personal, health and financial details. `local-deep` if it needs more power. Cloud only when the user says so, redacted first.
4. **Current information comes from web search (SearXNG), never from escalation.** None of the routes can search the web through LiteLLM; see the Grok note below.
5. Inputs longer than the 32k context go to `gemini` (or are chunked locally if private).
6. Announce an escalation in one line before making it.
7. At most **two** `ask_model` calls per request. If an answer stalls, report it instead of retrying.
8. On a budget error, say so and finish locally.

The budget is enforced by LiteLLM regardless of what the model decides. The prompt states it as well, so the model treats cloud calls as real money.

**Grok has no web access here.** xAI's Live Search (`search_parameters`) is deprecated in favour of agent tools on a different API, so through LiteLLM's chat completions Grok can't search. In testing it replied "I'll search…" and stalled, and didn't know the date. It's a second-opinion route, not a news route.

## 2. The `ask_model` tool

**Workspace → Tools → +**, paste [`open-webui/ask_model.py`](../open-webui/ask_model.py), save. Then set its **Valves** (gear icon):

| Valve | Default | Set to |
|---|---|---|
| `litellm_url` | `http://litellm:4000` | Leave (compose service name) |
| `litellm_key` | empty | A LiteLLM virtual key for this tool (`key_alias: open-webui-ask-model`, see [docs/03](03-docker-stack.md#virtual-keys)) |
| `allowed_models` | `local-deep,claude,claude-opus,gemini,gemini-pro,grok` | Routes the tool may call; anything else is rejected |
| `local_models` | `local-fast,local-deep,local-ha` | Routes that never leave the server (skip the secret check) |
| `block_secrets_to_cloud` | `true` | Leave on |
| `max_tokens` | `4096` | Raise to 8192 if Grok answers come back cut off (its reasoning tokens count against the limit) |
| `timeout_local_s` / `timeout_cloud_s` | `900` / `180` | `local-deep` is slow |

Use a dedicated key, not the master key: it can be revoked on its own, and its spend shows up separately.

What it does on every call:

- **Allowlist.** Unknown route names are rejected with the list of valid ones.
- **Secret blocker (cloud routes only).** Refuses the call if the prompt matches a private-key header, `sk-`, `AIza`, `xai-`, GitHub or AWS key patterns, or `password|secret|api_key|token = …`. It's a cheap guard, not a substitute for judgment.
- **Context the other model lacks.** It adds a system message with today's date and "you have no tools; answer in this single reply", so cloud models don't claim to search or guess the date.
- **Cost and status.** The chat shows "Asking claude…", then the time taken and the cost from LiteLLM's `x-litellm-response-cost` header. Budget errors come back as "over its budget, finish locally".

## 3. The Groot model

Create it as a **separate** custom model (**Workspace → Models → +**) on top of `local-fast`, rather than editing `local-fast` itself. `local-fast` stays clean for n8n, Home Assistant and testing.

| Setting | Value |
|---|---|
| Base model | `local-fast` |
| System prompt | [`open-webui/groot-system-prompt.md`](../open-webui/groot-system-prompt.md); fill in "Who you work for" |
| Tools | Ask Model |
| Function Calling (Advanced Params) | **Native**: Qwen handles native tool calls far better than the prompt-based default |
| Default features | Web Search on |

The prompt uses Open WebUI's `{{CURRENT_DATE}}` variable, so the model knows the date without a tool call.

**Trim the built-in tools.** Every tool's schema is sent with every request, which costs context in a 32k window and raises the chance of the wrong tool. Keep these groups and drop the rest (notes, tasks, automations, calendar, skills, timer, `delegate_task`):

| Group | Functions |
|---|---|
| Time | `get_current_timestamp`, `calculate_timestamp` |
| Web | `search_web`, `fetch_url` |
| Knowledge base and files | `list_knowledge_bases`, `search_knowledge_bases`, `query_knowledge_bases`, `grep_knowledge_files`, `search_knowledge_files`, `query_knowledge_files`, `view_knowledge_file` |
| Chat history | `search_chats`, `view_chat` |
| Memory | `search_memories`, `list_memories`, `list_memory_paths`, `read_memory_path`, `add_memory`, `update_memory`, `replace_memory_content`, `delete_memory` |
| Ask the user | `ask_user` |

On groot that's 22 built-in functions instead of the default 38. With `ask_model` and the Home Assistant MCP tools ([docs/05 §8](05-home-assistant.md#8-groot-controls-the-house-has-mcp-server)), Groot sees 46 tools. To check, ask Groot in a new chat to "list every tool you have, names only".

**Tools bind when a chat starts.** After adding or editing a tool, start a new chat; old chats keep the tool set they started with.

## 4. `local-deep`: when it's worth the wait

`gpt-oss:120b` doesn't fit in 24 GB. Ollama keeps attention on the 3090 and runs the MoE experts from system RAM:

| Measure (groot) | Value |
|---|---|
| `ollama ps` | 21 GB, 6% / 94% CPU / GPU |
| Container RAM | ~62 GB |
| Cold load | 73 s |
| Generation | 23.3 tok/s |
| Groot → `ask_model local-deep` round trip, page cache warm | 32 s |

Loading it evicts the 27B. After `local-deep`'s 5-minute `keep_alive` it unloads and `local-fast` reloads, pinned again. For a long session on private data, pick `local-deep` from the model dropdown instead; that avoids swapping back and forth.

## 5. Check it

```bash
# virtual key works and can reach a cloud route
curl -s localhost:4000/v1/chat/completions -H "Authorization: Bearer <ask_model key>" -H "Content-Type: application/json" \
  -d '{"model":"gemini","messages":[{"role":"user","content":"Say OK"}]}' | head -c 300
# Open WebUI can reach LiteLLM
docker exec ai-open-webui-1 python3 -c "import urllib.request;print(urllib.request.urlopen('http://litellm:4000/health/liveliness').read())"
```

In a new Groot chat, ask for something that should escalate ("ask claude to review this config…") and something that shouldn't. Then try a fake key in a cloud request to see the blocker refuse it.
