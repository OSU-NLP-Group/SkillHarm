"""Minimal Azure-OpenAI / OpenAI-compatible chat client with on-disk cache.

Mirrors the auth pattern used everywhere else in this repo: reads
`OPENAI_API_KEY` and `OPENAI_BASE_URL` from the environment (Azure's
`/openai/v1/` v1-compat endpoint works as-is). No `openai` package
dependency — the request is a plain `urllib.request` POST so this script
runs in any of the project's environments without extra setup.

Cache: every request keys on `sha256(model || prompt || schema)`. Cached
responses are stored at `fixed-payload-poisoning/victim_eval/eval/metrics/.cache/<sha>.json`.
Re-running compute_sample.py on the same inputs is free.
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
    parsed: dict           # JSON-decoded model output
    raw: str               # raw text returned (post-extraction; may equal json.dumps(parsed))
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
            raise RuntimeError("OPENAI_API_KEY is not set in env (or pass api_key=)")
        if not self.base_url:
            raise RuntimeError("OPENAI_BASE_URL is not set in env (or pass base_url=)")

    # -------------------------------------------------------------------
    # Public
    # -------------------------------------------------------------------

    def judge(
        self,
        system_prompt: str,
        user_prompt: str,
        schema_hint: str = "",
        temperature: float | None = None,
        json_schema: dict | None = None,
    ) -> JudgeResponse:
        # `temperature=None` (default) lets the model use its own default.
        # Required for gpt-5.x — those models reject any non-default value
        # ("Only the default (1) value is supported").
        #
        # `json_schema` (the Structured Outputs schema dict, w/ keys
        # {name, strict, schema}) makes Azure / OpenAI enforce the output
        # shape at decode time. We send it as response_format={type:
        # json_schema, json_schema: <dict>}. Failures here surface
        # directly — gpt-5.x on the v1-compat endpoint always supports
        # Structured Outputs, so any 4xx is a real problem the caller
        # should see.
        cache_key = self._cache_key(
            system_prompt, user_prompt, schema_hint, temperature, json_schema
        )
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
            body["response_format"] = {
                "type": "json_schema",
                "json_schema": json_schema,
            }
        else:
            body["response_format"] = {"type": "json_object"}
        if temperature is not None:
            body["temperature"] = temperature

        raw_text, prompt_tok, comp_tok = self._post_with_retry(body)
        # With strict json_schema the model literally cannot emit malformed
        # JSON, so json.loads is unconditional here. (json_object mode does
        # NOT guarantee strict JSON — but we don't use it.)
        parsed = json.loads(raw_text)

        self._write_cache(cache_key, {
            "parsed": parsed,
            "raw": raw_text,
            "model": self.model,
            "prompt_tokens": prompt_tok,
            "completion_tokens": comp_tok,
        })
        return JudgeResponse(
            parsed=parsed,
            raw=raw_text,
            cached=False,
            model=self.model,
            prompt_tokens=prompt_tok,
            completion_tokens=comp_tok,
        )

    # -------------------------------------------------------------------
    # Internals
    # -------------------------------------------------------------------

    def _cache_key(
        self,
        system_prompt: str,
        user_prompt: str,
        schema_hint: str,
        temperature: float | None,
        json_schema: dict | None,
    ) -> str:
        h = hashlib.sha256()
        h.update(self.model.encode("utf-8"))
        h.update(b"\0")
        h.update(system_prompt.encode("utf-8"))
        h.update(b"\0")
        h.update(user_prompt.encode("utf-8"))
        h.update(b"\0")
        h.update(schema_hint.encode("utf-8"))
        h.update(b"\0")
        h.update(str(temperature).encode("utf-8"))
        h.update(b"\0")
        # json_schema is structurally part of the request; sort keys so cache
        # hits are stable regardless of dict ordering at construction time.
        h.update(
            json.dumps(json_schema, sort_keys=True, separators=(",", ":")).encode("utf-8")
            if json_schema is not None else b"null"
        )
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
        p = self._cache_path(key)
        try:
            p.write_text(json.dumps(value, ensure_ascii=False, indent=2))
        except Exception:
            pass  # cache write failures must not block the metric

    def _post_with_retry(self, body: dict) -> tuple[str, int, int]:
        url = f"{self.base_url}/chat/completions"
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {self.api_key}",
            # Azure's v1-compat endpoint also accepts `api-key`; sending both
            # is harmless and lets this client work against either backend.
            "api-key": self.api_key,
        }
        last_err: Exception | None = None
        for attempt in range(1, self.max_retries + 1):
            try:
                req = urllib.request.Request(
                    url,
                    data=json.dumps(body).encode("utf-8"),
                    headers=headers,
                    method="POST",
                )
                with urllib.request.urlopen(req, timeout=self.timeout_sec) as resp:
                    raw = resp.read().decode("utf-8")
                doc = json.loads(raw)
                content = doc["choices"][0]["message"]["content"]
                usage = doc.get("usage") or {}
                return (
                    content,
                    int(usage.get("prompt_tokens", 0)),
                    int(usage.get("completion_tokens", 0)),
                )
            except urllib.error.HTTPError as e:
                # 429/5xx: backoff and retry. 4xx other: bail.
                last_err = e
                if e.code in (429, 500, 502, 503, 504) and attempt < self.max_retries:
                    time.sleep(2 ** attempt)
                    continue
                # Surface the response body so the caller can see why.
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
