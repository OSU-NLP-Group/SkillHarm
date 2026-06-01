#!/usr/bin/env python3
"""Calculate cost for a Harbor job based on agent type and token usage.

Usage:
    python3 calculate_cost.py <job_dir> [--model MODEL]

Reads token usage from:
  - Codex/GPT agents: result.json -> agent_result.{n_input_tokens, n_cache_tokens, n_output_tokens}
  - Claude Code agents: agent/sessions/projects/-root/*.jsonl -> per-message usage fields
  - Gemini CLI agents: agent/gemini-cli.trajectory.json -> per-message tokens.{input, output, cached, thoughts, tool}

Outputs JSON to stdout with token counts and cost breakdown.
Also writes cost.json into the job directory.
"""

import argparse
import glob
import json
import os
import sys
from pathlib import Path

# Pricing per 1M tokens (as of 2026-04)
PRICING = {
    # Claude models (Anthropic API / Bedrock)
    "claude-opus-4-7":   {"input": 5.00, "cache_read": 0.50, "cache_write": 6.25, "output": 25.00},
    "claude-opus-4-6":   {"input": 5.00, "cache_read": 0.50, "cache_write": 6.25, "output": 25.00},
    "claude-sonnet-4-6": {"input": 3.00, "cache_read": 0.30, "cache_write": 3.75, "output": 15.00},
    "claude-haiku-4-5":  {"input": 1.00, "cache_read": 0.10, "cache_write": 1.25, "output": 5.00},
    # OpenAI GPT models
    "gpt-5.5":      {"input": 5.00, "cache_read": 0.50, "output": 30.00},
    "gpt-5.4":      {"input": 2.50, "cache_read": 0.25, "output": 15.00},
    "gpt-5.4-mini": {"input": 0.75, "cache_read": 0.075, "output": 4.50},
    "gpt-5.2":      {"input": 2.50, "cache_read": 0.25, "output": 15.00},
    "gpt-4o":        {"input": 2.50, "cache_read": 0.25, "output": 10.00},
    # Codex models (same pricing as GPT-5.4 for Codex agent)
    "codex-gpt-5.4": {"input": 2.50, "cache_read": 0.25, "output": 15.00},
    # Gemini models (Vertex AI / Google API). "thoughts" and "tool" tokens
    # are billed as text output per Google's pricing page.
    "gemini-3-flash-preview": {"input": 0.50, "cache_read": 0.05, "output": 3.00},
}

# Model ID aliases -> pricing key
MODEL_ALIASES = {
    "us.anthropic.claude-opus-4-7": "claude-opus-4-7",
    "us.anthropic.claude-opus-4-7-v1": "claude-opus-4-7",
    "us.anthropic.claude-opus-4-6-v1": "claude-opus-4-6",
    "anthropic.claude-opus-4-6-v1": "claude-opus-4-6",
    "anthropic/claude-opus-4-6": "claude-opus-4-6",
    "us.anthropic.claude-sonnet-4-6-v1": "claude-sonnet-4-6",
    "anthropic.claude-sonnet-4-6": "claude-sonnet-4-6",
    "anthropic/claude-sonnet-4-6": "claude-sonnet-4-6",
    "us.anthropic.claude-haiku-4-5-v1": "claude-haiku-4-5",
    "anthropic.claude-haiku-4-5": "claude-haiku-4-5",
    "openai/gpt-5.5": "gpt-5.5",
    "openai/gpt-5.4": "gpt-5.4",
    "openai/gpt-5.2": "gpt-5.2",
    "openai/gpt-4o": "gpt-4o",
    "google/gemini-3-flash-preview": "gemini-3-flash-preview",
}


def resolve_model(model_str):
    """Resolve a model string to a pricing key."""
    if model_str in PRICING:
        return model_str
    if model_str in MODEL_ALIASES:
        return MODEL_ALIASES[model_str]
    # Try partial match (longest key first to avoid e.g. "gpt-5.4" matching before "gpt-5.4-mini")
    lower = model_str.lower()
    for key in sorted(PRICING.keys(), key=len, reverse=True):
        if key in lower:
            return key
    return None


def extract_claude_usage(job_dir):
    """Extract token usage from Claude Code session JSONL."""
    session_pattern = os.path.join(job_dir, "agent/sessions/projects/-root/*.jsonl")
    jsonl_files = glob.glob(session_pattern)
    if not jsonl_files:
        return None

    total = {
        "input_tokens": 0,
        "cache_creation_input_tokens": 0,
        "cache_read_input_tokens": 0,
        "output_tokens": 0,
    }
    import subprocess

    for jsonl_file in jsonl_files:
        # Session files may be root-owned (from Docker); try direct, then sudo
        fh = None
        try:
            fh = open(jsonl_file)
            lines_iter = fh
        except PermissionError:
            try:
                raw = subprocess.check_output(["sudo", "cat", jsonl_file], timeout=10)
                lines_iter = raw.decode("utf-8", errors="ignore").splitlines()
            except Exception:
                continue

        try:
            for line in lines_iter:
                line = line.strip() if isinstance(line, str) else line
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                usage = obj.get("message", {}).get("usage")
                if usage:
                    total["input_tokens"] += usage.get("input_tokens") or 0
                    total["cache_creation_input_tokens"] += usage.get("cache_creation_input_tokens") or 0
                    total["cache_read_input_tokens"] += usage.get("cache_read_input_tokens") or 0
                    total["output_tokens"] += usage.get("output_tokens") or 0
        finally:
            if fh is not None:
                fh.close()

    if total["input_tokens"] == 0 and total["output_tokens"] == 0:
        return None
    return total


def extract_codex_usage(job_dir):
    """Extract token usage from Codex/GPT result.json."""
    # Find the trial result.json (not the top-level job result.json)
    for root, dirs, files in os.walk(job_dir):
        if "result.json" in files:
            result_path = os.path.join(root, "result.json")
            with open(result_path) as f:
                d = json.load(f)
            ar = d.get("agent_result", {})
            if ar and ar.get("n_input_tokens") is not None:
                return {
                    "input_tokens": ar.get("n_input_tokens", 0),
                    "cache_read_input_tokens": ar.get("n_cache_tokens", 0),
                    "output_tokens": ar.get("n_output_tokens", 0),
                }
    return None


def extract_gemini_usage(job_dir):
    """Extract token usage from gemini-cli.trajectory.json.

    The trajectory is the harbor-converted-from-JSONL form: a single JSON
    object with a `messages` array. Each gemini-type message has a `tokens`
    sub-object with input/output/cached/thoughts/tool counts. Per Google's
    pricing page, both "thoughts" (reasoning) and "tool" tokens are billed
    as text output, so we sum them into output_tokens before pricing.

    `cached` is reported as a sibling of `input` (not a subset), so we
    price it like Claude — see calculate_cost's input_excludes_cache flag.
    """
    trajectory_path = os.path.join(job_dir, "agent/gemini-cli.trajectory.json")
    if not os.path.exists(trajectory_path):
        return None
    try:
        with open(trajectory_path) as f:
            traj = json.load(f)
    except Exception:
        return None

    total = {
        "input_tokens": 0,
        "cache_read_input_tokens": 0,
        "output_tokens": 0,
    }
    for msg in traj.get("messages", []):
        if msg.get("type") != "gemini":
            continue
        tokens = msg.get("tokens") or {}
        total["input_tokens"]            += tokens.get("input", 0) or 0
        total["cache_read_input_tokens"] += tokens.get("cached", 0) or 0
        total["output_tokens"]           += (
            (tokens.get("output", 0) or 0)
            + (tokens.get("thoughts", 0) or 0)
            + (tokens.get("tool", 0) or 0)
        )

    if total["input_tokens"] == 0 and total["output_tokens"] == 0:
        return None
    return total


def detect_agent_type(job_dir):
    """Detect whether this is a Claude Code, Codex, or Gemini CLI job."""
    # Check for Claude Code session files
    session_pattern = os.path.join(job_dir, "agent/sessions/projects/-root/*.jsonl")
    if glob.glob(session_pattern):
        return "claude-code"
    # Check for codex.txt
    codex_pattern = os.path.join(job_dir, "agent/codex.txt")
    if os.path.exists(codex_pattern):
        return "codex"
    # Check for gemini-cli artifacts. Trajectory JSON is the source of truth
    # for token counts; the transcript alone lets us tag the agent type.
    if os.path.exists(os.path.join(job_dir, "agent/gemini-cli.trajectory.json")) \
            or os.path.exists(os.path.join(job_dir, "agent/gemini-cli.txt")):
        return "gemini-cli"
    return "unknown"


def detect_model(job_dir):
    """Try to detect the model from result.json."""
    for root, dirs, files in os.walk(job_dir):
        if "result.json" in files:
            with open(os.path.join(root, "result.json")) as f:
                d = json.load(f)
            agent_config = d.get("config", {}).get("agent", {})
            model = agent_config.get("model_name", "")
            if model:
                return model
    return None


def calculate_cost(usage, pricing_key):
    """Calculate cost from token usage and pricing."""
    prices = PRICING[pricing_key]
    M = 1_000_000

    input_tokens = usage.get("input_tokens") or 0
    cache_read = usage.get("cache_read_input_tokens") or 0
    cache_write = usage.get("cache_creation_input_tokens") or 0
    output_tokens = usage.get("output_tokens") or 0

    # For Claude AND Gemini: input_tokens is already the non-cached portion
    #   (cache_read is a separate sibling bucket).
    # For Codex/GPT: input_tokens is the total, cache_read is the cached
    #   subset, so non-cached = input_tokens - cache_read.
    input_excludes_cache = "claude" in pricing_key or "gemini" in pricing_key

    if input_excludes_cache:
        input_cost = (input_tokens / M) * prices["input"]
        cache_read_cost = (cache_read / M) * prices["cache_read"]
        cache_write_cost = (cache_write / M) * prices.get("cache_write", 0)
        output_cost = (output_tokens / M) * prices["output"]
    else:
        # GPT/Codex: non-cached input = total - cached
        non_cached = max(0, input_tokens - cache_read)
        input_cost = (non_cached / M) * prices["input"]
        cache_read_cost = (cache_read / M) * prices["cache_read"]
        cache_write_cost = 0
        output_cost = (output_tokens / M) * prices["output"]

    total_cost = input_cost + cache_read_cost + cache_write_cost + output_cost

    return {
        "input_cost": round(input_cost, 4),
        "cache_read_cost": round(cache_read_cost, 4),
        "cache_write_cost": round(cache_write_cost, 4),
        "output_cost": round(output_cost, 4),
        "total_cost": round(total_cost, 4),
    }


def process_job(job_dir, model_override=None):
    """Process a single job directory and return cost info."""
    job_dir = str(Path(job_dir).resolve())

    agent_type = detect_agent_type(job_dir)
    model_str = model_override or detect_model(job_dir) or ""
    pricing_key = resolve_model(model_str)

    # Extract usage
    if agent_type == "claude-code":
        usage = extract_claude_usage(job_dir)
    elif agent_type == "codex":
        usage = extract_codex_usage(job_dir)
    elif agent_type == "gemini-cli":
        usage = extract_gemini_usage(job_dir)
    else:
        # Try all three
        usage = (
            extract_claude_usage(job_dir)
            or extract_codex_usage(job_dir)
            or extract_gemini_usage(job_dir)
        )

    if not usage:
        return {"error": "No token usage data found", "job_dir": job_dir}

    if not pricing_key:
        return {
            "error": f"Unknown model: {model_str}",
            "job_dir": job_dir,
            "usage": usage,
        }

    cost = calculate_cost(usage, pricing_key)

    result = {
        "job_dir": job_dir,
        "agent_type": agent_type,
        "model": model_str,
        "pricing_key": pricing_key,
        "usage": usage,
        "cost": cost,
    }

    # Write cost.json to job dir
    cost_path = os.path.join(job_dir, "cost.json")
    try:
        with open(cost_path, "w") as f:
            json.dump(result, f, indent=2)
    except PermissionError:
        pass  # Docker-owned directories

    return result


def main():
    parser = argparse.ArgumentParser(description="Calculate cost for a Harbor job")
    parser.add_argument("job_dir", help="Path to the job trial directory")
    parser.add_argument("--model", help="Override model name for pricing lookup")
    args = parser.parse_args()

    result = process_job(args.job_dir, args.model)
    print(json.dumps(result, indent=2))

    if "error" not in result:
        cost = result["cost"]
        print(f"\n  Total cost: ${cost['total_cost']:.4f}", file=sys.stderr)


if __name__ == "__main__":
    main()
