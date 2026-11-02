"""
title: Remote Shell
description: Run commands and copy files on LAN hosts over SSH (through the aihub-ssh sidecar). Every command and transfer waits for your OK in a confirmation dialog.
author: PdXGB
version: 0.2.0
"""

import re

import aiohttp
from pydantic import BaseModel, Field

# Masked in output returned to cloud models (output only; the command itself is shown to you before it runs).
REDACT_PATTERNS = [
    (r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----", "[private key masked]"),
    (r"\bsk-[A-Za-z0-9_\-]{20,}", "[key masked]"),
    (r"\bAIza[0-9A-Za-z_\-]{30,}", "[key masked]"),
    (r"\bxai-[A-Za-z0-9]{20,}", "[key masked]"),
    (r"\bgh[pousr]_[A-Za-z0-9]{30,}", "[token masked]"),
    (r"\bAKIA[0-9A-Z]{16}\b", "[key masked]"),
    (r"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}", "[jwt masked]"),
    (r"(?i)\b(password|passwd|pwd|secret|api[_-]?key|token|psk|wpa_passphrase)(\s*[:=]\s*)(\S{4,})", r"\1\2[masked]"),
    (r"(?i)(://[^/\s:@]+:)[^@\s]+@", r"\1[masked]@"),
    (r"\$[0-9a-z]{1,2}\$[^\s:]{8,}", "[hash masked]"),  # /etc/shadow-style hashes
]


class Tools:
    class Valves(BaseModel):
        runner_url: str = Field(default="http://aihub-ssh:8022", description="aihub-ssh URL as seen from Open WebUI")
        runner_token: str = Field(default="", description="AIHUB_SSH_TOKEN from /srv/ai/.env")
        admin_only: bool = Field(default=True, description="Only Open WebUI admins may use this tool")
        local_models: str = Field(
            default="local-fast,local-deep,local-ha",
            description="Models that stay on the server. Any other model (or one this tool can't identify) is treated as cloud.",
        )
        redact_for_cloud: bool = Field(default=True, description="Mask secret-looking output before it goes to a cloud model")
        max_output_chars: int = Field(default=12000, description="Output returned to the model per call")
        default_timeout_s: int = Field(default=60, description="Default per-call timeout")
        auto_approve: bool = Field(
            default=False,
            description="Skip the confirm dialogs (commands and copies run straight away, still logged). Turn on for a job, OFF afterwards.",
        )

    def __init__(self):
        self.valves = self.Valves()

    # ---------- helpers ----------

    def _model_id(self, model) -> tuple[str, bool]:
        model = model or {}
        ids = {str(model.get("id", ""))}
        info = model.get("info") or {}
        ids.add(str(info.get("base_model_id") or ""))
        local = {m.strip() for m in self.valves.local_models.split(",") if m.strip()}
        is_local = bool(ids & local)
        return (model.get("id") or "unknown"), is_local

    def _allowed(self, user) -> str:
        if self.valves.admin_only and (user or {}).get("role") != "admin":
            return "Remote Shell is limited to Open WebUI admins."
        if not self.valves.runner_token:
            return "Remote Shell is not configured: set the runner_token valve (AIHUB_SSH_TOKEN)."
        return ""

    async def _call(self, method: str, path: str, body: dict | None = None, timeout: int = 60) -> dict:
        url = self.valves.runner_url.rstrip("/") + path
        headers = {"Authorization": f"Bearer {self.valves.runner_token}"}
        try:
            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=timeout + 30)) as s:
                async with s.request(method, url, json=body, headers=headers) as r:
                    data = await r.json(content_type=None)
                    if r.status != 200:
                        return {"error": (data or {}).get("error", f"HTTP {r.status}")}
                    return data
        except (aiohttp.ClientError, TimeoutError) as e:
            return {"error": f"could not reach aihub-ssh at {url}: {e!r}"}

    async def _confirm(self, event_call, title: str, message: str, emitter=None) -> bool:
        if self.valves.auto_approve:
            if emitter:  # leave a visible trace in the chat for every auto-approved action
                await emitter({"type": "message", "data": {"content": f"\n\n> ⚠ auto-approved: {title}\n\n{message}\n\n"}})
            return True
        if not event_call:
            return False  # no dialog available = no run
        try:
            return bool(await event_call({"type": "confirmation", "data": {"title": title, "message": message}}))
        except Exception:
            return False

    async def _status(self, emitter, msg: str, done: bool = False):
        if emitter:
            await emitter({"type": "status", "data": {"description": msg, "done": done}})

    def _format(self, res: dict, is_local: bool) -> str:
        if "error" in res:
            return f"Remote Shell error: {res['error']}"
        text = ""
        if res.get("stdout"):
            text += res["stdout"]
        if res.get("stderr"):
            text += ("\n" if text else "") + "[stderr]\n" + res["stderr"]
        if not is_local and self.valves.redact_for_cloud:
            for pat, rep in REDACT_PATTERNS:
                text = re.sub(pat, rep, text)
        if len(text) > self.valves.max_output_chars:
            text = text[: self.valves.max_output_chars] + f"\n…[cut at {self.valves.max_output_chars} chars]"
        head = f"exit {res.get('exit')} in {res.get('seconds')}s"
        if res.get("legacy_scp"):
            head += " (legacy scp)"
        if res.get("local_name"):
            head += f", saved as {res['local_name']}"
        return f"[{head}]\n{text}".rstrip()

    async def _host(self, host: str) -> tuple[dict | None, str]:
        res = await self._call("GET", "/hosts")
        if "error" in res:
            return None, f"Remote Shell error: {res['error']}"
        match = next((h for h in res["hosts"] if h["host"] == host), None)
        if not match:
            return None, f"Unknown host '{host}'. Known hosts: {', '.join(h['host'] for h in res['hosts']) or 'none'}."
        return match, ""

    def _timeout(self, timeout_s) -> int:
        try:
            return max(5, min(int(timeout_s or self.valves.default_timeout_s), 600))
        except (TypeError, ValueError):
            return self.valves.default_timeout_s

    # ---------- tools ----------

    async def list_remote_hosts(self, __user__: dict = None) -> str:
        """
        List the LAN hosts Remote Shell can reach (alias, login user, address). Call this before using a host you haven't used in this chat.
        :return: One line per host.
        """
        if err := self._allowed(__user__):
            return err
        res = await self._call("GET", "/hosts")
        if "error" in res:
            return f"Remote Shell error: {res['error']}"
        if not res["hosts"]:
            return "No hosts enrolled yet (aihub-enroll on the server adds them)."
        return "\n".join(f"{h['host']}: {h['user']}@{h['hostname']}:{h['port']}" for h in res["hosts"])

    async def run_remote_command(
        self, host: str, command: str, timeout_s: int = 0,
        __user__: dict = None, __model__: dict = None, __event_emitter__=None, __event_call__=None,
    ) -> str:
        """
        Run one shell command on a LAN host over SSH and return its output. The user must approve the exact command first.
        Prefer one clear command (pipes and && are fine). Use sudo only on hosts where the user said it is set up.
        :param host: Host alias from list_remote_hosts (e.g. nas, pfsense, ha).
        :param command: The exact shell command to run on that host.
        :param timeout_s: Optional timeout in seconds (default 60, max 600).
        :return: Exit code and output.
        """
        if err := self._allowed(__user__):
            return err
        h, err = await self._host(host)
        if err:
            return err
        model, is_local = self._model_id(__model__)
        t = self._timeout(timeout_s)
        where = "stays on the server" if is_local else "goes to a cloud provider" + (" (secrets masked)" if self.valves.redact_for_cloud else "")
        ok = await self._confirm(
            __event_call__,
            f"Run on {h['host']}?",
            f"**{h['user']}@{h['hostname']}**\n\n```\n{command}\n```\n\nRequested by {model}; output {where}. Timeout {t}s.",
            emitter=__event_emitter__,
        )
        if not ok:
            await self._status(__event_emitter__, f"Cancelled: {h['host']}", True)
            return "The user declined this command. Do not retry it unless they ask; ask what they want instead."
        await self._status(__event_emitter__, f"Running on {h['host']}…")
        caller = f"{(__user__ or {}).get('email', '?')} via {model}" + (" [auto-approved]" if self.valves.auto_approve else "")
        res = await self._call("POST", "/run", {"host": h["host"], "command": command, "timeout_s": t, "caller": caller}, t)
        await self._status(__event_emitter__, f"{h['host']}: exit {res.get('exit', 'error')}", True)
        return self._format(res, is_local)

    async def fetch_remote_file(
        self, host: str, remote_path: str, local_name: str = "", recursive: bool = False,
        __user__: dict = None, __model__: dict = None, __event_emitter__=None, __event_call__=None,
    ) -> str:
        """
        Copy a file (or folder, with recursive=true) FROM a LAN host into the server's transfer folder (scp). The user must approve first.
        To move a file between two hosts: fetch_remote_file from one, then send_file_to_remote to the other.
        :param host: Host alias from list_remote_hosts.
        :param remote_path: Path on that host.
        :param local_name: Optional name/subfolder in the transfer folder (defaults to the file's name).
        :param recursive: True to copy a whole folder.
        :return: Result and the saved name.
        """
        if err := self._allowed(__user__):
            return err
        h, err = await self._host(host)
        if err:
            return err
        model, is_local = self._model_id(__model__)
        dest = local_name or remote_path.rstrip("/").split("/")[-1]
        ok = await self._confirm(
            __event_call__,
            f"Copy from {h['host']}?",
            f"```\n{h['user']}@{h['hostname']}:{remote_path}{'  (whole folder)' if recursive else ''}\n→ transfer/{dest}\n```\n\nRequested by {model}.",
            emitter=__event_emitter__,
        )
        if not ok:
            return "The user declined this transfer. Do not retry it unless they ask."
        await self._status(__event_emitter__, f"Copying from {h['host']}…")
        caller = f"{(__user__ or {}).get('email', '?')} via {model}" + (" [auto-approved]" if self.valves.auto_approve else "")
        res = await self._call("POST", "/fetch", {"host": h["host"], "remote_path": remote_path, "local_name": local_name,
                                                   "recursive": recursive, "timeout_s": 600, "caller": caller}, 600)
        await self._status(__event_emitter__, f"{h['host']}: exit {res.get('exit', 'error')}", True)
        return self._format(res, is_local)

    async def send_file_to_remote(
        self, host: str, local_name: str, remote_path: str,
        __user__: dict = None, __model__: dict = None, __event_emitter__=None, __event_call__=None,
    ) -> str:
        """
        Copy a file or folder from the server's transfer folder TO a LAN host (scp). The user must approve first. Existing files at the destination are overwritten.
        :param host: Host alias from list_remote_hosts.
        :param local_name: Name in the transfer folder (see list_transfer_files).
        :param remote_path: Destination path on that host.
        :return: Result.
        """
        if err := self._allowed(__user__):
            return err
        h, err = await self._host(host)
        if err:
            return err
        model, is_local = self._model_id(__model__)
        ok = await self._confirm(
            __event_call__,
            f"Copy to {h['host']}?",
            f"```\ntransfer/{local_name}\n→ {h['user']}@{h['hostname']}:{remote_path}\n```\n\nOverwrites an existing file. Requested by {model}.",
            emitter=__event_emitter__,
        )
        if not ok:
            return "The user declined this transfer. Do not retry it unless they ask."
        await self._status(__event_emitter__, f"Copying to {h['host']}…")
        caller = f"{(__user__ or {}).get('email', '?')} via {model}" + (" [auto-approved]" if self.valves.auto_approve else "")
        res = await self._call("POST", "/send", {"host": h["host"], "local_name": local_name, "remote_path": remote_path,
                                                  "timeout_s": 600, "caller": caller}, 600)
        await self._status(__event_emitter__, f"{h['host']}: exit {res.get('exit', 'error')}", True)
        return self._format(res, is_local)

    async def list_transfer_files(self, __user__: dict = None) -> str:
        """
        List files in the server's transfer folder (what fetch_remote_file saved and send_file_to_remote can send).
        :return: One line per file with size and time.
        """
        if err := self._allowed(__user__):
            return err
        res = await self._call("GET", "/files")
        if "error" in res:
            return f"Remote Shell error: {res['error']}"
        if not res["files"]:
            return "The transfer folder is empty."
        lines = [f"{f['name']}  {f['bytes']} bytes  {f['modified']}" for f in res["files"]]
        if res["count"] > len(lines):
            lines.append(f"…and {res['count'] - len(lines)} more")
        return "\n".join(lines)
