# 07 — Knowledge base (RAG)

Open WebUI's **Knowledge** feature answers from your own documents: manuals, datasheets, standards, notes. Documents are split into chunks and embedded once; at question time the closest chunks go into the prompt, and the answer cites them.

Embeddings run locally. Documents never leave the server unless a cloud model is chosen for the chat itself.

## 1. The `embed` route

[`compose/litellm/config.example.yaml`](../compose/litellm/config.example.yaml):

```yaml
  - model_name: embed
    litellm_params:
      model: ollama/nomic-embed-text
      api_base: http://ollama:11434
    model_info:
      mode: embedding
```

```bash
docker exec ai-ollama-1 ollama pull nomic-embed-text
```

`OLLAMA_MAX_LOADED_MODELS: 2` in compose lets the embedding model sit beside the chat model on the 3090 instead of evicting it. The embedding model goes through LiteLLM like everything else, so Open WebUI never talks to Ollama directly (`ENABLE_OLLAMA_API: "false"`).

## 2. Open WebUI document settings

**Admin Panel → Settings → Documents:**

| Setting | Value |
|---|---|
| Embedding model engine | OpenAI |
| API base URL | `http://litellm:4000/v1` |
| API key | The LiteLLM master key (the same one Open WebUI uses for chat) |
| Embedding model | `embed` |

Then hide `embed` from the chat model list (**Admin Panel → Settings → Models**); it can't chat.

Changing the embedding model later means re-embedding every document, so pick it before loading a large library.

## 3. Load documents

**Workspace → Knowledge → +**: create a collection per subject (for example vendor manuals, standards, safety data sheets) and upload files into it.

Use a collection in a chat by typing `#` and picking it, or attach it to a custom model (such as the assistant model, [docs/06](06-model-routing.md)) so every chat with that model can search it.

## 4. Check it

- [ ] `curl -s localhost:4000/v1/models -H "Authorization: Bearer $MK"` lists `embed`
- [ ] Uploading a file into a collection finishes without an embedding error
- [ ] A question only that document can answer comes back with a citation to it
