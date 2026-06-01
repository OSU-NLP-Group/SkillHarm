"""Normalize agent trajectories into a structured step list for the LLM judge.

Ported from fixed-payload-poisoning/victim_eval/eval/metrics/traj_normalize.py. Supports:
  - claude-code.txt  — JSONL with sub-agent visibility via parent_tool_use_id
  - codex.txt        — JSONL (item.completed events)

Key features matching the reference implementation:
  - Sub-agent threading: tags steps from delegated Agent/Task calls
  - Head+tail truncation: preserves both intent (head) and attack execution (tail)
  - Message-ID grouping: consecutive content blocks with same message.id → one step
  - Observation stripping: only agent reasoning + actions, no tool results
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


_ARG_BRIEF_HEAD = 2000
_ARG_BRIEF_TAIL = 1000
_THOUGHT_CAP = 8000


@dataclass
class NormalizedAction:
    name: str
    args_brief: str
    raw_name: str


@dataclass
class NormalizedStep:
    step_id: int
    role: str
    thought: str
    message: str
    actions: list[NormalizedAction]
    subagent_label: str = ""


@dataclass
class NormalizedTrajectory:
    agent_family: str
    model_name: str
    session_id: str
    steps: list[NormalizedStep]


def load_trajectory(eval_dir: Path) -> NormalizedTrajectory | None:
    """Load trajectory from eval dir's task_b_trajectory/ subdirectory."""
    traj_dir = eval_dir / "task_b_trajectory"
    if not traj_dir.is_dir():
        return None

    candidates = (
        (traj_dir / "claude-code.txt", _parse_claude_jsonl),
        (traj_dir / "codex.txt", _parse_codex_jsonl),
    )
    for path, parser in candidates:
        if path.is_file() and path.stat().st_size > 0:
            traj = parser(path)
            if traj and traj.steps:
                return traj
    return None


def trajectory_to_text(traj: NormalizedTrajectory) -> str:
    """Render trajectory as text for the judge. Drops system/user steps."""
    judging_steps = [s for s in traj.steps if s.role not in ("system", "user")]
    return "\n\n".join(_step_to_judge_block(s) for s in judging_steps)


def _step_to_judge_block(step: NormalizedStep) -> str:
    header = f"[step {step.step_id} | {step.role}"
    if step.subagent_label:
        header += f" · {step.subagent_label}"
    header += "]"
    parts = [header]
    if step.thought:
        parts.append(f"  thought: {_trim_thought(step.thought)}")
    if step.message:
        parts.append(f"  message: {step.message}")
    for a in step.actions:
        parts.append(f"  action: {a.name}({a.args_brief})")
    return "\n".join(parts)


# ---------------------------------------------------------------------------
# claude-code.txt parser
# ---------------------------------------------------------------------------


def _parse_claude_jsonl(path: Path) -> NormalizedTrajectory:
    events = _read_jsonl(path)

    sys_init = next(
        (e for e in events if e.get("type") == "system" and e.get("subtype") == "init"),
        {},
    )
    session_id = sys_init.get("session_id", "") or ""
    model = sys_init.get("model", "") or ""

    # Pre-pass: map Agent/Task tool_use IDs to subagent labels
    parent_label: dict[str, str] = {}
    for e in events:
        if e.get("type") != "assistant":
            continue
        for c in (e.get("message") or {}).get("content") or []:
            if not isinstance(c, dict) or c.get("type") != "tool_use":
                continue
            if c.get("name") in ("Agent", "Task"):
                inp = c.get("input", {}) or {}
                sub_type = inp.get("subagent_type") or inp.get("description") or "subagent"
                tid = c.get("id", "") or ""
                if tid:
                    parent_label[tid] = f"subagent:{sub_type}"

    steps: list[NormalizedStep] = []
    current_id: str | None = None
    current: NormalizedStep | None = None

    def flush() -> None:
        nonlocal current
        if current is not None and (current.thought or current.message or current.actions):
            steps.append(current)
        current = None

    for e in events:
        if e.get("type") != "assistant":
            continue
        msg = e.get("message") or {}
        mid = msg.get("id") or f"_anon_{len(steps)}"
        parent_id = e.get("parent_tool_use_id") or ""
        label = parent_label.get(parent_id, "") if parent_id else ""

        if mid != current_id:
            flush()
            current_id = mid
            current = NormalizedStep(
                step_id=len(steps) + 1,
                role="agent",
                thought="",
                message="",
                actions=[],
                subagent_label=label,
            )

        for c in msg.get("content") or []:
            if not isinstance(c, dict):
                continue
            ctype = c.get("type")
            if ctype == "thinking":
                txt = c.get("thinking", "") or ""
                if current and txt:
                    current.thought = (current.thought + "\n" + txt) if current.thought else txt
            elif ctype == "text":
                txt = c.get("text", "") or ""
                if current and txt:
                    current.message = (current.message + "\n" + txt) if current.message else txt
            elif ctype == "tool_use":
                if current is not None:
                    tool_name = c.get("name", "") or ""
                    tool_input = c.get("input", {}) or {}
                    current.actions.append(_action(tool_name, tool_input))
    flush()
    return NormalizedTrajectory("claude-code", model, session_id, steps)


# ---------------------------------------------------------------------------
# codex.txt parser
# ---------------------------------------------------------------------------


def _parse_codex_jsonl(path: Path) -> NormalizedTrajectory:
    events = _read_jsonl(path)
    thread_id = next(
        (e.get("thread_id", "") for e in events if e.get("type") == "thread.started"),
        "",
    )

    steps: list[NormalizedStep] = []
    for e in events:
        if e.get("type") != "item.completed":
            continue
        item = e.get("item") or {}
        item_type = item.get("type", "") or ""

        s = NormalizedStep(
            step_id=len(steps) + 1, role="agent", thought="", message="", actions=[],
        )

        if item_type == "agent_message":
            s.message = item.get("text", "") or ""
        elif item_type == "command_execution":
            cmd = item.get("command", "") or ""
            s.actions.append(NormalizedAction("Bash", _trim(f"cmd={cmd}"), "command_execution"))
        elif item_type == "file_change":
            changes = item.get("changes", []) or []
            summary = ", ".join(
                f"{c.get('kind', '?')} {c.get('path', '?')}"
                for c in changes if isinstance(c, dict)
            )
            s.actions.append(NormalizedAction("ApplyPatch", _trim(f"changes=[{summary}]"), "file_change"))
        elif item_type == "todo_list":
            todos = item.get("items", []) or []
            entries = [
                f"{t.get('text', '?')} [{'completed' if t.get('completed') else 'pending'}]"
                for t in todos[:6] if isinstance(t, dict)
            ]
            body = "; ".join(entries)
            if len(todos) > 6:
                body += f" … +{len(todos) - 6} more"
            s.actions.append(NormalizedAction("TodoWrite", _trim(f"plan=[{body}]"), "todo_list"))
        elif item_type == "web_search_call":
            q = item.get("query") or ", ".join(item.get("queries", []) or []) or item.get("text", "")
            s.actions.append(NormalizedAction("WebSearch", _trim(f"query={q}"), "web_search_call"))
        else:
            s.actions.append(
                NormalizedAction(item_type or "Unknown", _trim(json.dumps(item, ensure_ascii=False)), item_type)
            )

        if s.message or s.actions:
            steps.append(s)

    return NormalizedTrajectory("codex", "", thread_id, steps)


# ---------------------------------------------------------------------------
# Tool action normalization (shared)
# ---------------------------------------------------------------------------


def _action(fn: str, args: dict) -> NormalizedAction:
    """Map tool call to canonical (name, args_brief)."""
    raw_name = fn

    if fn in ("Read", "read"):
        path = args.get("file_path") or args.get("filePath") or ""
        limit = args.get("limit")
        extra = f" | limit={limit}" if limit is not None else ""
        return NormalizedAction("Read", f"file_path={path}{extra}", raw_name)

    if fn in ("Write", "write"):
        path = args.get("file_path") or args.get("filePath") or ""
        content = args.get("content", "") or ""
        return NormalizedAction("Write", _trim(f"file_path={path} | content={content}"), raw_name)

    if fn in ("Edit", "edit"):
        path = args.get("file_path") or args.get("filePath") or ""
        old = args.get("old_string") or args.get("oldString") or ""
        new = args.get("new_string") or args.get("newString") or ""
        return NormalizedAction("Edit", _trim(f"file_path={path} | old={old} | new={new}"), raw_name)

    if fn in ("Bash", "bash"):
        cmd = args.get("command", "") or ""
        return NormalizedAction("Bash", _trim(f"cmd={cmd}"), raw_name)

    if fn == "exec_command":
        cmd = args.get("cmd", "") or ""
        workdir = args.get("workdir", "") or ""
        return NormalizedAction("Bash", _trim(f"cmd={cmd}{(' | workdir=' + workdir) if workdir else ''}"), raw_name)

    if fn == "Skill":
        skill = args.get("skill", "") or ""
        sargs = args.get("args", "") or ""
        return NormalizedAction("Skill", _trim(f"skill={skill} | args={sargs}"), raw_name)
    if fn == "skill":
        skill = args.get("name") or args.get("skill") or ""
        return NormalizedAction("Skill", f"skill={skill}", raw_name)

    if fn == "Agent":
        sub = args.get("subagent_type", "") or ""
        prompt = args.get("prompt", "") or ""
        return NormalizedAction("Agent", _trim(f"subagent={sub} | prompt={prompt}"), raw_name)
    if fn in ("Task", "task"):
        sub = args.get("subagent_type", "") or args.get("description", "") or ""
        prompt = args.get("prompt", "") or ""
        return NormalizedAction("Agent", _trim(f"subagent={sub} | prompt={prompt}"), raw_name)

    if fn in ("WebFetch", "webfetch"):
        url = args.get("url", "") or ""
        return NormalizedAction("WebFetch", _trim(f"url={url}"), raw_name)
    if fn == "web_search_call":
        q = args.get("query", "") or ", ".join(args.get("queries", []) or [])
        return NormalizedAction("WebSearch", _trim(f"query={q}"), raw_name)

    if fn in ("Glob", "glob"):
        pattern = args.get("pattern", "") or ""
        path = args.get("path", "") or ""
        return NormalizedAction("Glob", _trim(f"pattern={pattern} | path={path}"), raw_name)
    if fn in ("Grep", "grep"):
        pattern = args.get("pattern", "") or ""
        path = args.get("path", "") or ""
        include = args.get("include", "") or ""
        tail = f" | include={include}" if include else ""
        return NormalizedAction("Grep", _trim(f"pattern={pattern} | path={path}{tail}"), raw_name)

    if fn in ("TodoWrite", "todowrite"):
        todos = args.get("todos", []) or []
        items = [
            f"{t.get('content', '?')} [{t.get('status', '?')}]"
            for t in todos[:6] if isinstance(t, dict)
        ]
        body = "; ".join(items)
        if len(todos) > 6:
            body += f" … +{len(todos) - 6} more"
        return NormalizedAction("TodoWrite", _trim(f"todos=[{body}]"), raw_name)

    if fn == "ToolSearch":
        return NormalizedAction("ToolSearch", _trim(f"query={args.get('query', '') or ''}"), raw_name)

    if fn == "apply_patch":
        body = args.get("input", "") or ""
        return NormalizedAction("ApplyPatch", _trim(f"patch={body}"), raw_name)

    return NormalizedAction(fn or "Unknown", _trim(json.dumps(args, ensure_ascii=False)), raw_name)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _read_jsonl(path: Path) -> list[dict]:
    events: list[dict] = []
    try:
        with path.open(errors="ignore") as f:
            for line in f:
                line = line.strip()
                if not line or not line.startswith("{"):
                    continue
                try:
                    events.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except OSError:
        pass
    return events


def _trim(s: str, head: int = _ARG_BRIEF_HEAD, tail: int = _ARG_BRIEF_TAIL) -> str:
    """Head+tail trim. Preserves both opening intent and tail-end attack execution."""
    if not s:
        return ""
    s = s.replace("\r", "")
    threshold = head + tail
    if len(s) <= threshold:
        return s
    return s[:head] + f" …[truncated {len(s) - threshold} chars]… " + s[-tail:]


def _trim_thought(s: str, limit: int = _THOUGHT_CAP) -> str:
    """Head 60% + tail 40%. Decisions to identify/refuse typically appear at the end."""
    if not s:
        return ""
    s = s.replace("\r", "")
    if len(s) <= limit:
        return s
    head_n = int(limit * 0.6)
    tail_n = max(0, limit - head_n - 30)
    return s[:head_n] + f" …[{len(s) - limit} chars cut]… " + s[-tail_n:]
