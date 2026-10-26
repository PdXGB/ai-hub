"""
title: Ask Model
description: Hand a self-contained task to another model behind LiteLLM (local-deep, claude, claude-opus, gemini, gemini-pro, grok).
author: PdXGB
version: 0.2.1
"""

import re
import time
from datetime import date

import aiohttp
from pydantic import BaseModel, Field


# Cheap guard against obvious secrets leaving the house. Not a substitute for judgment.
SECRET_PATTERNS = [
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
    r"\bsk-[A-Za-z0-9_\-]{20,}",  # OpenAI/Anthropic/LiteLLM-style keys
    r"\bAIza[0-9A-Za-z_\-]{30,}",  # Google API keys
    r"\bxai-[A-Za-z0-9]{20,}",  # xAI keys
    r"\bgh[pousr]_[A-Za-z0-9]{30,}",  # GitHub tokens
    r"\bAKIA[0-9A-Z]{16}\b",  # AWS access keys
    r"(?i)\b(password|passwd|pwd|secret|api[_-]?key|token)\s*[:=]\s*\S{6,}",
]


class Tools:
    class Valves(BaseModel):
        litellm_url: str = Field(
            default="http://litellm:4000",
            description="LiteLLM base URL as seen from the Open WebUI container",
        )
        litellm_key: str = Field(
            default="",
            description="LiteLLM virtual key (or master key) for Open WebUI",
        )
        allowed_models: str = Field(
            default="local-deep,claude,claude-opus,gemini,gemini-pro,grok",
            description="Comma-separated model names the tool may call",
        )
        local_models: str = Field(
            default="local-fast,local-deep,local-ha",
            description="Models that never leave groot (skip the secret check)",
        )
        block_secrets_to_cloud: bool = Field(
            default=True,
            description="Refuse cloud calls when the prompt looks like it contains credentials",
        )
        max_tokens: int = Field(default=4096, description="Max output tokens per call")
        timeout_local_s: int = Field(default=900, description="Timeout for local models (local-deep is slow)")
        timeout_cloud_s: int = Field(default=180, description="Timeout for cloud models")

    def __init__(self):
        self.valves = self.Valves()

    async def ask_model(
        self,
        model: str,
        prompt: str,
        system: str = "",
        __event_emitter__=None,
    ) -> str:
        """
        Send a self-contained task to another model and return its answer.
        Use when the task needs more reasoning, a longer context window, multimodal or real-time knowledge than you have.
        The other model cannot see this conversation, so include every fact, file excerpt and constraint it needs.
        :param model: One of: local-deep (private, slow, strong), claude (default cloud), claude-opus (hardest problems only, expensive), gemini (cheap, long context), gemini-pro (long context + deep reasoning), grok (second opinion; no web access through this API).
        :param prompt: The complete, self-contained task for the other model.
        :param system: Optional short instructions for the other model (role, output format).
        :return: The other model's answer, with model name and cost.
        """
        model = model.strip()
        allowed = [m.strip() for m in self.valves.allowed_models.split(",") if m.strip()]
        local = [m.strip() for m in self.valves.local_models.split(",") if m.strip()]

        if model not in allowed:
            return f"ask_model error: '{model}' is not allowed. Use one of: {', '.join(allowed)}."
        if not prompt.strip():
            return "ask_model error: empty prompt."

        is_local = model in local
        if not is_local and self.valves.block_secrets_to_cloud:
            text = f"{system}\n{prompt}"
            for pat in SECRET_PATTERNS:
                if re.search(pat, text):
                    return (
                        "ask_model blocked: the prompt looks like it contains a credential or key. "
                        "Redact it and retry, or use local-deep."
                    )

        async def status(msg: str, done: bool = False):
            if __event_emitter__:
                await __event_emitter__(
                    {"type": "status", "data": {"description": msg, "done": done}}
                )

        await status(f"Asking {model}…")

        base = (
            f"Today is {date.today():%A, %B %d, %Y}. "
            "You are being called through an API with no tools: no web search, browsing or file access. "
            "Answer fully in this single reply from your own knowledge. Never say you will search or look something up. "
            "If the answer may be out of date, say so in one line."
        )
        messages = [{"role": "system", "content": f"{base}\n\n{system}".strip()}]
        messages.append({"role": "user", "content": prompt})

        headers = {"Content-Type": "application/json"}
        if self.valves.litellm_key:
            headers["Authorization"] = f"Bearer {self.valves.litellm_key}"

        timeout = aiohttp.ClientTimeout(
            total=self.valves.timeout_local_s if is_local else self.valves.timeout_cloud_s
        )
        url = self.valves.litellm_url.rstrip("/") + "/v1/chat/completions"
        payload = {"model": model, "messages": messages, "max_tokens": self.valves.max_tokens}

        t0 = time.monotonic()
        try:
            async with aiohttp.ClientSession(timeout=timeout) as session:
                async with session.post(url, json=payload, headers=headers) as resp:
                    body = await resp.json(content_type=None)
                    cost = resp.headers.get("x-litellm-response-cost")
                    if resp.status != 200:
                        err = body.get("error", body) if isinstance(body, dict) else body
                        msg = err.get("message", str(err)) if isinstance(err, dict) else str(err)
                        if "budget" in msg.lower():
                            await status(f"{model}: budget exceeded", done=True)
                            return f"ask_model: {model} is over its budget. Finish locally. ({msg[:200]})"
                        await status(f"{model}: error {resp.status}", done=True)
                        return f"ask_model error from {model} (HTTP {resp.status}): {msg[:500]}"
        except aiohttp.ClientError as e:
            await status(f"{model}: connection failed", done=True)
            return f"ask_model error: could not reach LiteLLM at {url}: {e}"
        except TimeoutError:
            await status(f"{model}: timed out", done=True)
            return f"ask_model error: {model} timed out."

        try:
            answer = body["choices"][0]["message"]["content"] or ""
        except (KeyError, IndexError, TypeError):
            return f"ask_model error: unexpected response from {model}: {str(body)[:500]}"

        elapsed = time.monotonic() - t0
        cost_str = ""
        if cost:
            try:
                cost_str = f", ${float(cost):.4f}"
            except ValueError:
                pass

        await status(f"{model} answered in {elapsed:.0f}s{cost_str}", done=True)
        return f"[{model}{cost_str}]\n\n{answer}"
