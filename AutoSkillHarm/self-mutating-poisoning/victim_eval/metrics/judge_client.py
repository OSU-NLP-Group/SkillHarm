"""Azure-OpenAI / OpenAI-compatible chat client with on-disk cache.

Reads OPENAI_API_KEY and OPENAI_BASE_URL from the environment. Azure's
/openai/v1/ compat endpoint works as-is. No openai package dependency.

Cache: sha256(model || prompt || schema) → .cache/<sha>.json
"""

from __future__ import annotations

import hashlib
import json
import os
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path


CACHE_DIR = Path(__file__).resolve().parent / ".cache"


@dataclass
class JudgeResponse:
    parsed: dict
    raw: str
    cached: bool
    model: str
    prompt_tokens: int
    completion_tokens: int


class JudgeClient:
    def __init__(
        self,
        model: str,
        api_key: str | None = None,
        base_url: str | None = None,
        cache_dir: Path | None = None,
        timeout_sec: int = 120,
        max_retries: int = 3,
    ):
        self.model = model
        self.api_key = api_key or os.environ.get("OPENAI_API_KEY", "")
        self.base_url = (base_url or os.environ.get("OPENAI_BASE_URL", "")).rstrip("/")
        self.cache_dir = cache_dir or CACHE_DIR
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self.timeout_sec = timeout_sec
        self.max_retries = max_retries

        if not self.api_key:
            raise RuntimeError("OPENAI_API_KEY is not set")
        if not self.base_url:
            raise RuntimeError("OPENAI_BASE_URL is not set")

    def judge(
        self,
        system_prompt: str,
        user_prompt: str,
        schema_hint: str = "",
        temperature: float | None = None,
        json_schema: dict | None = None,
    ) -> JudgeResponse:
        cache_key = self._cache_key(system_prompt, user_prompt, schema_hint, temperature, json_schema)
        cached = self._read_cache(cache_key)
        if cached is not None:
            return JudgeResponse(
                parsed=cached["parsed"],
                raw=cached["raw"],
                cached=True,
                model=cached.get("model", self.model),
                prompt_tokens=cached.get("prompt_tokens", 0),
                completion_tokens=cached.get("completion_tokens", 0),
            )

        body: dict = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
        }
        if json_schema is not None:
            body["response_format"] = {"type": "json_schema", "json_schema": json_schema}
        else:
            body["response_format"] = {"type": "json_object"}
        if temperature is not None:
            body["temperature"] = temperature

        raw_text, prompt_tok, comp_tok = self._post_with_retry(body)
        parsed = json.loads(raw_text)

        self._write_cache(cache_key, {
            "parsed": parsed,
            "raw": raw_text,
            "model": self.model,
            "prompt_tokens": prompt_tok,
            "completion_tokens": comp_tok,
        })
        return JudgeResponse(
            parsed=parsed, raw=raw_text, cached=False,
            model=self.model, prompt_tokens=prompt_tok, completion_tokens=comp_tok,
        )

    def _cache_key(self, system_prompt, user_prompt, schema_hint, temperature, json_schema):
        h = hashlib.sha256()
        h.update(self.model.encode())
        h.update(b"\0")
        h.update(system_prompt.encode())
        h.update(b"\0")
        h.update(user_prompt.encode())
        h.update(b"\0")
        h.update(schema_hint.encode())
        h.update(b"\0")
        h.update(str(temperature).encode())
        h.update(b"\0")
        h.update(json.dumps(json_schema, sort_keys=True, separators=(",", ":")).encode() if json_schema else b"null")
        return h.hexdigest()

    def _cache_path(self, key: str) -> Path:
        return self.cache_dir / f"{key}.json"

    def _read_cache(self, key: str) -> dict | None:
        p = self._cache_path(key)
        if not p.is_file():
            return None
        try:
            return json.loads(p.read_text())
        except Exception:
            return None

    def _write_cache(self, key: str, value: dict) -> None:
        try:
            self._cache_path(key).write_text(json.dumps(value, ensure_ascii=False, indent=2))
        except Exception:
            pass

    def _post_with_retry(self, body: dict) -> tuple[str, int, int]:
        url = f"{self.base_url}/chat/completions"
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {self.api_key}",
            "api-key": self.api_key,
        }
        last_err: Exception | None = None
        for attempt in range(1, self.max_retries + 1):
            try:
                req = urllib.request.Request(
                    url, data=json.dumps(body).encode(), headers=headers, method="POST",
                )
                with urllib.request.urlopen(req, timeout=self.timeout_sec) as resp:
                    raw = resp.read().decode()
                doc = json.loads(raw)
                content = doc["choices"][0]["message"]["content"]
                usage = doc.get("usage") or {}
                return content, int(usage.get("prompt_tokens", 0)), int(usage.get("completion_tokens", 0))
            except urllib.error.HTTPError as e:
                last_err = e
                if e.code in (429, 500, 502, 503, 504) and attempt < self.max_retries:
                    time.sleep(2 ** attempt)
                    continue
                try:
                    body_text = e.read().decode("utf-8", errors="replace")
                except Exception:
                    body_text = ""
                raise RuntimeError(f"judge HTTP {e.code}: {body_text[:500]}") from e
            except (urllib.error.URLError, TimeoutError) as e:
                last_err = e
                if attempt < self.max_retries:
                    time.sleep(2 ** attempt)
                    continue
                raise
        raise RuntimeError(f"judge POST failed after retries: {last_err!r}")
