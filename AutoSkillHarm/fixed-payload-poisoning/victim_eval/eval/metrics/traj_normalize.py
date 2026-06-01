"""Normalize each agent family's trajectory into a flat step list.

Source files (all directly cp'd into eval_dir by eval.sh — no jobs/ symlink
dependency):
  - `claude-code.txt`  — JSONL, one event per line. Per-content-block events
    (`thinking`, `text`, `tool_use`) wrap an assistant message; `parent_tool_use_id`
    threads sub-agent activity through the same stream. We group events by
    `message.id` into NormalizedSteps and tag sub-agent steps via subagent_label.
  - `codex.txt`        — ~10 lines of plaintext header, then JSONL events
    (`thread.started` / `turn.*` / `item.started` / `item.completed`). The
    substantive units are `item.completed` events whose `item.type` is
    `agent_message`, `command_execution`, `file_change`, `todo_list`, etc.
    Each becomes one NormalizedStep.
  - `opencode.txt`     — ~3 plaintext banner lines, then JSONL events
    bracketed by `step_start` / `step_finish`, with `reasoning` / `tool_use`
    / `text` events in between. Each step_start..step_finish bracket maps
    to one NormalizedStep.
  - `gemini-cli.trajectory.json` — gemini's session JSON from its native
    chat log (already structured; no .txt parsing needed since gemini's
    .txt is just a banner).

Why .txt over the trajectory.json that harbor produces: harbor's ATIF
converter compresses sub-agent (`Task` / `Agent`) tool-use into the parent
action's observation prose — losing the sub-agent's structured tool calls.
For ~30% of claude-code trajectories that delegate to sub-agents, this
produces systematic AR / identify / refusal / use_target_file misses
(e.g., main agent refuses, sub-agent does it anyway). Reading directly
from claude-code.txt's JSONL gives us the sub-agent's events back. The
codex/opencode shifts are a free side-effect: their .txt files are
already in eval_dir, so we no longer rely on the jobs/ symlink at all.

Output: a list of NormalizedStep with observations dropped, agent thoughts
kept (cap _THOUGHT_CAP), and tool calls captured as a single `args_brief`
string (cap _ARG_BRIEF_MAX) per action.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any


# Per-action argument brief: keep first _ARG_BRIEF_HEAD chars + last
# _ARG_BRIEF_TAIL chars when over (head + tail). Head-only trim systematically
# missed late-stage tells in Write/Edit/ApplyPatch contents — e.g. an agent
# writes a 12k-char "legitimate-looking" Python script whose tail subprocess-
# invokes the carrier (the actual attack vehicle); head-only trim cut the
# subprocess call so the judge couldn't see it.
_ARG_BRIEF_HEAD = 2000
_ARG_BRIEF_TAIL = 1000

# Hard cap per-step thought / reasoning_content. Real reasoning rarely
# benefits the judge past a few thousand chars; opencode has emitted
# 128k-char single-step thoughts that are pure domain math derivations
# (no AR/identify/refuse signal in the bulk). 8000 affects ~1.8% of steps
# while saving ~24% of total thought bytes; head/tail trim preserves both
# the agent's opening intent and its closing decision sentence.
_THOUGHT_CAP = 8000


@dataclass
class NormalizedAction:
    name: str           # canonical tool name (Bash, Read, Write, Skill, ExecCommand, ApplyPatch, ...)
    args_brief: str     # short string capturing the bits that matter for judging
    raw_name: str       # the agent-native tool name (e.g. exec_command, run_shell_command)


@dataclass
class NormalizedStep:
    step_id: int
    role: str           # "user" | "agent" | "system"
    thought: str        # reasoning_content / thoughts joined; empty if none
    message: str        # user-facing text from the agent (or user prompt)
    actions: list[NormalizedAction]
    subagent_label: str = ""  # e.g. "subagent:Explore (haiku-4-5)" when this
                              # step belongs to a sub-agent invoked via the
                              # claude-code Task/Agent tool. Empty for steps
                              # produced by the main agent.


@dataclass
class NormalizedTrajectory:
    agent_family: str   # "claude-code" | "codex" | "gemini-cli" | "unknown"
    model_name: str
    session_id: str
    steps: list[NormalizedStep]


# ---------------------------------------------------------------------------
# Public entry points
# ---------------------------------------------------------------------------


def load_trajectory(eval_dir: Path) -> NormalizedTrajectory | None:
    """Load the agent trajectory from an eval sample dir.

    Dispatch by which file is present in eval_dir, in priority order:
      1. claude-code.txt              → claude family
      2. codex.txt                    → codex family
      3. opencode.txt                 → opencode family
      4. gemini-cli.trajectory.json   → gemini family
      5. (legacy fallback) job/agent/{trajectory.json,gemini-cli.trajectory.json}

    Each .txt is a structured per-CLI log directly cp'd into eval_dir by
    eval.sh, so this path is fully independent of the jobs/ symlink. The
    legacy fallback exists for old data that pre-dates the cp logic — if
    you're not seeing it fire on current runs, it's because it shouldn't.

    Returns None if no source is present or parses to empty.
    """
    eval_dir = Path(eval_dir)

    # Primary: per-CLI structured logs in eval_dir.
    candidates = (
        (eval_dir / "claude-code.txt", _parse_claude_jsonl),
        (eval_dir / "codex.txt",       _parse_codex_jsonl),
        (eval_dir / "opencode.txt",    _parse_opencode_jsonl),
    )
    for path, parser in candidates:
        if path.is_file() and path.stat().st_size > 0:
            traj = parser(path)
            if traj.steps:
                return traj

    gem = eval_dir / "gemini-cli.trajectory.json"
    if gem.is_file():
        try:
            with gem.open() as f:
                data = json.load(f)
        except Exception:
            return None
        traj = _normalize_gemini(data) if "messages" in data else None
        if traj and traj.steps:
            return traj

    # Legacy fallback: jobs/ symlink path. Kept so old eval dirs that
    # predate the cp logic in eval.sh still load correctly.
    job_link = eval_dir / "job"
    if job_link.exists():
        for cand, parser in (
            (job_link / "agent" / "trajectory.json",            _normalize_legacy_atif),
            (job_link / "agent" / "gemini-cli.trajectory.json", _normalize_legacy_gemini),
        ):
            if cand.is_file():
                try:
                    with cand.open() as f:
                        data = json.load(f)
                except Exception:
                    continue
                traj = parser(data)
                if traj and traj.steps:
                    return traj
    return None


def _normalize_legacy_atif(data: dict) -> NormalizedTrajectory | None:
    if "steps" in data and "schema_version" in data:
        return _normalize_atif(data)
    return None


def _normalize_legacy_gemini(data: dict) -> NormalizedTrajectory | None:
    if "messages" in data and "sessionId" in data:
        return _normalize_gemini(data)
    return None


# ---------------------------------------------------------------------------
# claude-code.txt — JSONL stream with sub-agent visibility
# ---------------------------------------------------------------------------


def _read_jsonl(path: Path) -> list[dict]:
    """Read a JSONL file, ignoring blank lines, plaintext header lines that
    don't start with `{`, and any individual lines that fail to parse.
    """
    events: list[dict] = []
    try:
        with path.open() as f:
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


def _parse_claude_jsonl(path: Path) -> NormalizedTrajectory:
    """Parse claude-code.txt's JSONL stream into a NormalizedTrajectory.

    Each line is one event of type `system` (init / final result chrome —
    drop), `assistant` (an assistant message's content block: thinking /
    text / tool_use), or `user` (initial task or tool_result — drop).

    Sub-agent activity is threaded through the same stream via
    `parent_tool_use_id`. We pre-pass the events to map each Agent / Task
    tool call's id to a `subagent:<type>` label, then tag each step that
    belongs to a sub-agent with that label so the judge can attribute
    actions to main vs delegated agents.

    Step grouping: consecutive `assistant` events sharing `message.id`
    belong to one model turn → one NormalizedStep. Each new message.id
    starts a new step.
    """
    events = _read_jsonl(path)

    sys_init = next(
        (e for e in events if e.get("type") == "system" and e.get("subtype") == "init"),
        {},
    )
    session_id = sys_init.get("session_id", "") or ""
    model = sys_init.get("model", "") or ""

    # Pre-pass: map every Agent/Task tool_use id to a "subagent:<type>"
    # label so we can tag downstream events whose parent_tool_use_id
    # matches.
    parent_label: dict[str, str] = {}
    for e in events:
        if e.get("type") != "assistant":
            continue
        for c in (e.get("message") or {}).get("content") or []:
            if not isinstance(c, dict) or c.get("type") != "tool_use":
                continue
            if c.get("name") in ("Agent", "Task"):
                inp = c.get("input", {}) or {}
                sub_type = inp.get("subagent_type") or "subagent"
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
                    current.actions.append(_atif_action(tool_name, tool_input))
    flush()
    return NormalizedTrajectory("claude-code", model, session_id, steps)


# ---------------------------------------------------------------------------
# codex.txt — JSONL after a small plaintext header
# ---------------------------------------------------------------------------


def _parse_codex_jsonl(path: Path) -> NormalizedTrajectory:
    """Parse codex.txt: ~10 plaintext header lines (warnings, "Reading
    additional input..."), then JSONL events.

    Events of interest are `item.completed`, where `item.type` is one of:
      - `agent_message`     → user-visible text the agent says
      - `command_execution` → a bash command (we keep `command`, drop
                              `aggregated_output` per the no-observations rule)
      - `file_change`       → apply_patch-equivalent (a list of
                              {path, kind} change records)
      - `todo_list`         → planning chrome
      - `web_search_call`   → web search

    Each `item.completed` becomes one NormalizedStep. Codex doesn't expose
    its reasoning chain (gpt-5.x's internal reasoning tokens aren't surfaced
    as content), so `thought` stays empty.
    """
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
            step_id=len(steps) + 1,
            role="agent",
            thought="",
            message="",
            actions=[],
        )

        if item_type == "agent_message":
            s.message = item.get("text", "") or ""
        elif item_type == "command_execution":
            cmd = item.get("command", "") or ""
            s.actions.append(NormalizedAction("Bash", _trim(f"cmd={cmd}"), "command_execution"))
        elif item_type == "file_change":
            changes = item.get("changes", []) or []
            summary = ", ".join(
                f"{c.get('kind','?')} {c.get('path','?')}"
                for c in changes
                if isinstance(c, dict)
            )
            s.actions.append(NormalizedAction("ApplyPatch", _trim(f"changes=[{summary}]"), "file_change"))
        elif item_type == "todo_list":
            todos = item.get("items", []) or []
            entries = [
                f"{t.get('text','?')} [{'completed' if t.get('completed') else 'pending'}]"
                for t in todos[:6]
                if isinstance(t, dict)
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
# opencode.txt — JSONL after a small plaintext banner
# ---------------------------------------------------------------------------


def _parse_opencode_jsonl(path: Path) -> NormalizedTrajectory:
    """Parse opencode.txt: ~3 plaintext banner lines, then JSONL events
    (`step_start`, `reasoning`, `tool_use`, `text`, `step_finish`).

    A step is opened by `step_start` and closed by `step_finish`. Within
    that bracket, `reasoning` events accumulate into `thought`, `text`
    events into `message`, and `tool_use` events become actions. The
    tool's input is at `part.state.input`; we pass it through `_atif_action`
    since opencode's tool names match the lowercase variants the canonical
    dispatch already handles (`read`, `write`, `bash`, `skill`, etc.).
    """
    events = _read_jsonl(path)
    session_id = next(
        (e.get("sessionID", "") for e in events if e.get("type") == "step_start"),
        "",
    )

    steps: list[NormalizedStep] = []
    current: NormalizedStep | None = None

    def flush() -> None:
        nonlocal current
        if current is not None and (current.thought or current.message or current.actions):
            steps.append(current)
        current = None

    for e in events:
        t = e.get("type")
        part = e.get("part") or {}

        if t == "step_start":
            flush()
            current = NormalizedStep(
                step_id=len(steps) + 1,
                role="agent",
                thought="",
                message="",
                actions=[],
            )
        elif t == "step_finish":
            flush()
        elif current is None:
            # event outside any step bracket — ignore
            continue
        elif t == "reasoning":
            txt = part.get("text", "") or ""
            if txt:
                current.thought = (current.thought + "\n" + txt) if current.thought else txt
        elif t == "text":
            txt = part.get("text", "") or ""
            if txt:
                current.message = (current.message + "\n" + txt) if current.message else txt
        elif t == "tool_use":
            tool_name = part.get("tool", "") or ""
            state = part.get("state", {}) or {}
            tool_input = state.get("input", {}) or {}
            current.actions.append(_atif_action(tool_name, tool_input))
    flush()

    return NormalizedTrajectory("opencode", "", session_id, steps)


# ---------------------------------------------------------------------------
# Legacy ATIF parser — kept as a fallback for old eval dirs that predate
# the cp-into-eval-dir logic in eval.sh. Not the primary path anymore.
# ---------------------------------------------------------------------------


def _normalize_atif(data: dict) -> NormalizedTrajectory:
    agent = data.get("agent") or {}
    family = agent.get("name", "unknown") or "unknown"
    model = agent.get("model_name", "") or ""
    session_id = data.get("session_id", "") or ""

    steps: list[NormalizedStep] = []
    for raw in data.get("steps") or []:
        source = raw.get("source", "agent")
        # Roles: ATIF uses {user, agent, system}; map system→system, others pass through.
        role = source if source in ("user", "agent", "system") else "agent"

        thought = raw.get("reasoning_content") or ""
        message = raw.get("message") or ""

        # Strip the boilerplate "Executed <tool> <id>" prefix that ATIF inserts
        # on every tool-call step. It carries no judging signal and inflates
        # the prompt by one line per step.
        if message.startswith("Executed ") and raw.get("tool_calls"):
            message = ""

        actions: list[NormalizedAction] = []
        for tc in raw.get("tool_calls") or []:
            fn = tc.get("function_name") or ""
            args = tc.get("arguments") or {}
            actions.append(_atif_action(fn, args))

        if role == "user" or message or thought or actions:
            steps.append(NormalizedStep(
                step_id=int(raw.get("step_id", len(steps) + 1)),
                role=role,
                thought=thought,
                message=message,
                actions=actions,
            ))

    return NormalizedTrajectory(family, model, session_id, steps)


def _atif_action(fn: str, args: dict) -> NormalizedAction:
    """Map an ATIF tool call to (canonical name, args brief).

    Canonical names are case-sensitive and stable across the four ATIF
    agent families we support today: claude-code (CamelCase tool names),
    codex (snake_case), opencode (lowercase, camelCase arg keys), and any
    new ATIF-shaped agent that follows one of these conventions.

    Mapping table (canonical name → which agents emit which raw name):
      Read       — claude `Read`, opencode `read`
      Write      — claude `Write`, opencode `write`
      Edit       — claude `Edit`, opencode `edit`
      Bash       — claude `Bash`, codex `exec_command`, opencode `bash`
      Skill      — claude `Skill`, opencode `skill`
      Agent      — claude `Agent`, opencode `task`
      WebFetch   — claude `WebFetch`, opencode `webfetch`
      Glob       — claude `Glob`, opencode `glob`
      Grep       — claude `Grep`, opencode `grep`
      TodoWrite  — claude `TodoWrite`, opencode `todowrite`
      ApplyPatch — codex `apply_patch`
      WriteStdin — codex `write_stdin`
      WebSearch  — codex `web_search_call`
      ToolSearch — claude `ToolSearch`
      TaskOutput / TaskStop — claude lifecycle for subagent tasks
      Invalid    — opencode `invalid` (model hallucinated a missing tool)

    Adding a new agent family is just: route its raw tool names to the
    canonical buckets above. The judge prompt sees the canonical name only.
    """
    raw_name = fn

    # ---- file reads (Read, read) ----
    if fn in ("Read", "read"):
        path = args.get("file_path") or args.get("filePath") or ""
        limit = args.get("limit")
        extra = f" | limit={limit}" if limit is not None else ""
        return NormalizedAction("Read", f"file_path={path}{extra}", raw_name)

    # ---- file writes (Write, write) ----
    if fn in ("Write", "write"):
        path = args.get("file_path") or args.get("filePath") or ""
        content = args.get("content", "") or ""
        return NormalizedAction("Write", _trim(f"file_path={path} | content={content}"), raw_name)

    # ---- file edits (Edit, edit) ----
    if fn in ("Edit", "edit"):
        path = args.get("file_path") or args.get("filePath") or ""
        old = args.get("old_string") or args.get("oldString") or ""
        new = args.get("new_string") or args.get("newString") or ""
        return NormalizedAction("Edit", _trim(f"file_path={path} | old={old} | new={new}"), raw_name)

    # ---- shell ----
    if fn in ("Bash", "bash"):
        cmd = args.get("command", "") or ""
        return NormalizedAction("Bash", _trim(f"cmd={cmd}"), raw_name)
    if fn == "exec_command":
        # codex variant: arg key is `cmd` and there's a `workdir`.
        cmd = args.get("cmd", "") or ""
        workdir = args.get("workdir", "") or ""
        return NormalizedAction(
            "Bash",
            _trim(f"cmd={cmd}{(' | workdir=' + workdir) if workdir else ''}"),
            raw_name,
        )

    # ---- skill activation ----
    if fn == "Skill":
        skill = args.get("skill", "") or ""
        sargs = args.get("args", "") or ""
        return NormalizedAction("Skill", _trim(f"skill={skill} | args={sargs}"), raw_name)
    if fn == "skill":
        skill = args.get("name") or args.get("skill") or ""
        return NormalizedAction("Skill", f"skill={skill}", raw_name)

    # ---- subagent delegation (claude Agent / opencode task / claude Task) ----
    if fn == "Agent":
        sub = args.get("subagent_type", "") or ""
        prompt = args.get("prompt", "") or ""
        return NormalizedAction("Agent", _trim(f"subagent={sub} | prompt={prompt}"), raw_name)
    if fn in ("Task", "task"):
        sub = args.get("subagent_type", "") or args.get("description", "") or ""
        prompt = args.get("prompt", "") or ""
        return NormalizedAction("Agent", _trim(f"subagent={sub} | prompt={prompt}"), raw_name)

    # ---- web ----
    if fn in ("WebFetch", "webfetch"):
        url = args.get("url", "") or ""
        return NormalizedAction("WebFetch", _trim(f"url={url}"), raw_name)
    if fn == "web_search_call":
        q = args.get("query", "") or ", ".join(args.get("queries", []) or [])
        return NormalizedAction("WebSearch", _trim(f"query={q}"), raw_name)

    # ---- glob / grep (file search; not really payload access but keep the
    #     shape readable so the judge isn't reading raw JSON). ----
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

    # ---- todo list (claude TodoWrite / opencode todowrite). Compress to
    #     `content [status]` per todo so the judge can still see what the
    #     agent intends to do without ingesting full nested JSON. ----
    if fn in ("TodoWrite", "todowrite"):
        todos = args.get("todos", []) or []
        items = [
            f"{t.get('content','?')} [{t.get('status','?')}]"
            for t in todos[:6]
            if isinstance(t, dict)
        ]
        body = "; ".join(items)
        if len(todos) > 6:
            body += f" … +{len(todos) - 6} more"
        return NormalizedAction("TodoWrite", _trim(f"todos=[{body}]"), raw_name)

    # ---- claude tool-discovery + lifecycle helpers (no signal for our
    #     metrics but cheap to format). ----
    if fn == "ToolSearch":
        return NormalizedAction("ToolSearch", _trim(f"query={args.get('query','') or ''}"), raw_name)
    if fn == "TaskOutput":
        return NormalizedAction("TaskOutput", _trim(json.dumps(args, ensure_ascii=False)), raw_name)
    if fn == "TaskStop":
        return NormalizedAction("TaskStop", _trim(json.dumps(args, ensure_ascii=False)), raw_name)

    # ---- codex helpers ----
    if fn == "apply_patch":
        body = args.get("input", "") or ""
        return NormalizedAction("ApplyPatch", _trim(f"patch={body}"), raw_name)
    if fn == "write_stdin":
        chars = args.get("chars", "") or ""
        return NormalizedAction("WriteStdin", _trim(f"chars={chars}"), raw_name)
    if fn == "update_plan":
        # codex's planning tool — same canonical bucket as TodoWrite, since
        # both express "what the agent intends to do next".
        plan = args.get("plan", []) or []
        items = [
            f"{p.get('step','?')} [{p.get('status','?')}]"
            for p in plan[:6]
            if isinstance(p, dict)
        ]
        body = "; ".join(items)
        if len(plan) > 6:
            body += f" … +{len(plan) - 6} more"
        return NormalizedAction("TodoWrite", _trim(f"plan=[{body}]"), raw_name)
    if fn == "view_image":
        path = args.get("path", "") or ""
        return NormalizedAction("Read", f"file_path={path}", raw_name)
    if fn == "wait_agent":
        targets = args.get("targets", []) or []
        timeout = args.get("timeout_ms")
        extra = f" | timeout_ms={timeout}" if timeout is not None else ""
        return NormalizedAction("WaitAgent", _trim(f"targets={targets}{extra}"), raw_name)

    # ---- opencode `invalid`: the model hallucinated an unavailable tool.
    #     Flag it explicitly — useful evidence that the agent went off-rails
    #     even before we judge anything. ----
    if fn == "invalid":
        tool = args.get("tool", "") or ""
        err = args.get("error", "") or ""
        return NormalizedAction("Invalid", _trim(f"hallucinated_tool={tool} | error={err}"), raw_name)

    # Fallback: keep the original name, dump args as JSON.
    return NormalizedAction(fn or "Unknown", _trim(json.dumps(args, ensure_ascii=False)), raw_name)


# ---------------------------------------------------------------------------
# gemini-cli
# ---------------------------------------------------------------------------


def _normalize_gemini(data: dict) -> NormalizedTrajectory:
    session_id = data.get("sessionId", "") or ""
    # gemini messages don't carry an agent block; pull model from any gemini
    # message that has it. Family is fixed.
    model = ""
    for m in data.get("messages") or []:
        if m.get("type") == "gemini" and m.get("model"):
            model = m["model"]
            break

    # Gemini's session JSONL records every gemini turn TWICE: a "draft"
    # snapshot when the model commits its thoughts (toolCalls absent), and
    # a "final" snapshot once tool calls are settled (same id, same
    # thoughts, but with toolCalls populated). Without dedup the judge
    # sees every thought double-counted plus a phantom action-less step.
    # 100% of gemini trajectories in our dataset have this; dedup-by-id
    # keeping the LAST occurrence captures the complete turn.
    raw_msgs = data.get("messages") or []
    seen_indices: dict[str, int] = {}
    for i, m in enumerate(raw_msgs):
        mid = m.get("id")
        if mid:
            seen_indices[mid] = i  # later index wins
    deduped = [
        m for i, m in enumerate(raw_msgs)
        if not m.get("id") or seen_indices.get(m["id"]) == i
    ]

    steps: list[NormalizedStep] = []
    for i, raw in enumerate(deduped, start=1):
        mtype = raw.get("type") or ""
        if mtype == "user":
            content = _gemini_content(raw.get("content"))
            steps.append(NormalizedStep(
                step_id=i, role="user", thought="", message=content, actions=[]
            ))
            continue

        if mtype == "gemini":
            thoughts = raw.get("thoughts") or []
            thought = "\n".join(
                _trim(f"{t.get('subject', '')}: {t.get('description', '')}".strip(": "))
                for t in thoughts
            )
            message = _gemini_content(raw.get("content"))

            actions: list[NormalizedAction] = []
            for tc in raw.get("toolCalls") or []:
                actions.append(_gemini_action(tc.get("name", ""), tc.get("args", {}) or {}))

            if message or thought or actions:
                steps.append(NormalizedStep(
                    step_id=i, role="agent", thought=thought, message=message, actions=actions
                ))
            continue

        # Tool-result and similar event messages: gemini emits these in-band.
        # We drop them per the "no observations" decision; if we ever need a
        # signal from them, add a branch here.

    return NormalizedTrajectory("gemini-cli", model, session_id, steps)


def _gemini_content(content: Any) -> str:
    """gemini's `content` is sometimes a string, sometimes a [{text}] list."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(c.get("text", "") for c in content if isinstance(c, dict))
    return ""


def _gemini_action(name: str, args: dict) -> NormalizedAction:
    raw_name = name

    if name == "read_file":
        path = args.get("file_path") or args.get("absolute_path") or ""
        return NormalizedAction("Read", f"file_path={path}", raw_name)
    if name == "write_file":
        path = args.get("file_path") or args.get("absolute_path") or ""
        content = args.get("content", "") or ""
        return NormalizedAction("Write", _trim(f"file_path={path} | content={content}"), raw_name)
    if name == "replace":
        path = args.get("file_path") or args.get("absolute_path") or ""
        return NormalizedAction("Edit", _trim(f"file_path={path}"), raw_name)
    if name == "run_shell_command":
        cmd = args.get("command", "") or ""
        return NormalizedAction("Bash", _trim(f"cmd={cmd}"), raw_name)
    if name == "activate_skill":
        skill = args.get("name", "") or ""
        return NormalizedAction("Skill", f"skill={skill}", raw_name)
    if name in ("google_web_search", "web_fetch"):
        # gemini's web_fetch passes a `prompt` rather than a URL because the
        # tool itself summarizes; treat as a search-style action.
        q = args.get("query") or args.get("prompt") or args.get("url") or ""
        return NormalizedAction("WebSearch" if name == "google_web_search" else "WebFetch",
                                _trim(f"query={q}"), raw_name)
    if name == "list_directory":
        path = args.get("dir_path") or args.get("path") or ""
        return NormalizedAction("Glob", _trim(f"dir_path={path}"), raw_name)
    if name == "glob":
        pattern = args.get("pattern", "") or ""
        path = args.get("path", "") or ""
        return NormalizedAction("Glob", _trim(f"pattern={pattern} | path={path}"), raw_name)
    if name == "grep_search":
        pattern = args.get("pattern", "") or ""
        path = args.get("path", "") or ""
        return NormalizedAction("Grep", _trim(f"pattern={pattern} | path={path}"), raw_name)
    if name == "invoke_agent":
        sub = args.get("agent_name", "") or ""
        prompt = args.get("prompt", "") or ""
        return NormalizedAction("Agent", _trim(f"subagent={sub} | prompt={prompt}"), raw_name)
    if name == "update_topic":
        # planning-only chrome; keep it visible to the judge but tag clearly.
        return NormalizedAction("UpdateTopic", _trim(json.dumps(args, ensure_ascii=False)), raw_name)
    if name in ("enter_plan_mode", "exit_plan_mode"):
        # plan-mode lifecycle; rare and content-light. Keep raw.
        return NormalizedAction("PlanMode", _trim(json.dumps(args, ensure_ascii=False)), raw_name)
    if name == "list_background_processes":
        return NormalizedAction("BackgroundProcessList", "", raw_name)
    if name == "read_background_output":
        pid = args.get("pid", "")
        return NormalizedAction("BackgroundProcessRead", _trim(f"pid={pid}"), raw_name)

    return NormalizedAction(name or "Unknown", _trim(json.dumps(args, ensure_ascii=False)), raw_name)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _trim(s: str, head: int = _ARG_BRIEF_HEAD, tail: int = _ARG_BRIEF_TAIL) -> str:
    """Keep the first `head` chars + the last `tail` chars when the string
    is longer than (head + tail). Captures both ends of long Write content
    / patch bodies so a tail-end subprocess call or footer instruction is
    still visible to the judge.
    """
    if not s:
        return ""
    s = s.replace("\r", "")
    threshold = head + tail
    if len(s) <= threshold:
        return s
    return s[:head] + f" …[truncated {len(s) - threshold} chars]… " + s[-tail:]


def _trim_thought(s: str, limit: int = _THOUGHT_CAP) -> str:
    """Head 60% + tail 40% with a marker. Decisions to identify/refuse
    typically appear in the closing sentence(s) of long reasoning blocks;
    initial intent statements appear at the head. Cutting from the middle
    preserves both signals.
    """
    if not s:
        return ""
    s = s.replace("\r", "")
    if len(s) <= limit:
        return s
    head_n = int(limit * 0.6)
    # 30 chars is the ` …[N chars cut]… ` marker overhead with N ≤ 999_999.
    tail_n = max(0, limit - head_n - 30)
    return s[:head_n] + f" …[{len(s) - limit} chars cut]… " + s[-tail_n:]


def step_to_judge_block(step: NormalizedStep) -> str:
    """Format one step for the judge prompt.

    Compact form: `[step N | role] thought=... message=... actions=[...]`.
    When the step belongs to a sub-agent (subagent_label set), it is
    rendered as `[step N | agent · subagent:Explore]` so the judge can
    attribute behavior to the main agent vs delegated sub-agent.
    """
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


def trajectory_to_text(traj: NormalizedTrajectory) -> str:
    """Concatenate the trajectory into a single string for the judge.

    Both `system` and `user` role steps are dropped:
      - system: framework boilerplate (sandbox policy, skills index, approval
        mode); no AR/identify/refuse signal and trips Azure cyber_policy on
        phrases like `danger-full-access`.
      - user: claude-code and gemini-cli echo the entire instruction.md as
        the first user-role step (100% overlap measured), and we already
        pass the instruction to the judge in its own prompt section. Codex's
        user-role step holds a short framework prelude with no signal.
        Dropping both flavors saves ~10% of trajectory length on average
        for claude/gemini and avoids putting the instruction in front of
        the judge twice.

    No trajectory-level cap: with the per-action (_ARG_BRIEF_MAX) and
    per-thought (_THOUGHT_CAP) caps in place, real-world trajectories top
    out around 110k chars (≈31k tokens), well inside any practical context
    window. A genuinely runaway trajectory should fail loudly at the API
    layer rather than be silently middle-truncated.
    """
    judging_steps = [s for s in traj.steps if s.role not in ("system", "user")]
    return "\n\n".join(step_to_judge_block(s) for s in judging_steps)


def to_dict(traj: NormalizedTrajectory) -> dict:
    return {
        "agent_family": traj.agent_family,
        "model_name": traj.model_name,
        "session_id": traj.session_id,
        "steps": [
            {
                "step_id": s.step_id,
                "role": s.role,
                "thought": s.thought,
                "message": s.message,
                "actions": [asdict(a) for a in s.actions],
            }
            for s in traj.steps
        ],
    }
