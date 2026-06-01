#!/usr/bin/env python3
"""Drop-in replacement for `harbor` CLI that injects a defense system prompt
into the victim agent (claude-code or codex) before harbor launches it.

Targets harbor >= 0.6.0 (which has CliFlag-based agents). For claude-code,
0.6.3 already exposes `--ak append_system_prompt=<text>` natively, BUT
`build_cli_flags()` interpolates the value without shell-quoting, which
mangles multi-line / spaced defense text. To stay correct on both agents we
patch the unified command sink instead.

Mechanism: monkey-patch `BaseInstalledAgent.exec_as_agent`. Every command the
agent runs in the container goes through this method. We rewrite the command
string just before it's forwarded to the environment:

  - claude-code: splice `--append-system-prompt <shlex.quote(text)>` after the
    `claude --verbose` token (append, not replace, so harbor's other CLI flags
    and tool-use defaults survive). [VALIDATED]
  - codex: prepend `cat >"$CODEX_HOME/AGENTS.md" <<EOF ... EOF` to the same
    command bash will run for `codex exec`. Same shell session → $CODEX_HOME
    expansion is consistent with harbor's own setup commands. [VALIDATED]
  - gemini-cli: insert immediately before `gemini --yolo` a snippet that:
      1. dumps gemini-cli's *actual* default system prompt to a tmp file via
         a no-op `gemini` call with `GEMINI_WRITE_SYSTEM_MD=…` set;
      2. concatenates that with our defense text into a second tmp file; and
      3. exports `GEMINI_SYSTEM_MD=<combined>` so the real gemini --yolo
        invocation loads the augmented prompt as its `systemInstruction`.
    Earlier iteration injected `~/.gemini/GEMINI.md` instead, which loads as
    `userMemory` (appended after a 1500-token core prompt) — defense was
    reaching the model but had no measurable rescue effect on Gemini 3 Flash.
    Switching to GEMINI_SYSTEM_MD puts defense at the head of the actual
    systemInstruction while preserving gemini-cli's tool-use guidance / core
    mandates / skills list (because we keep the dumped default in front).
  - opencode: prepend `cat >~/.config/opencode/AGENTS.md` heredoc before
    `opencode --model=...`. AGENTS.md is the cross-CLI standard opencode
    follows. [NOT YET DUMMY-VALIDATED]

Setup commands (auth.json writes, install steps, etc.) pass through unchanged
because they don't contain any of the four markers.

Self-contained file; invoke directly with the harbor 0.6.x tool python:
    /home/ubuntu/.local/share/uv/tools/harbor/bin/python harbor_run.py run ...
"""

from __future__ import annotations

import os
import re
import shlex
import sys
from pathlib import Path


def _read_defense_text() -> str:
    path = os.environ.get("SKILLHARM_DEFENSE_PROMPT_FILE", "").strip()
    if not path:
        sys.stderr.write(
            "ERROR: SKILLHARM_DEFENSE_PROMPT_FILE must be set.\n"
            "       This launcher exists specifically for defense evals;\n"
            "       run baseline evals via `harbor` directly.\n"
        )
        sys.exit(2)
    p = Path(path)
    if not p.is_file():
        sys.stderr.write(f"ERROR: defense prompt file not found: {p}\n")
        sys.exit(2)
    text = p.read_text(encoding="utf-8").strip()
    if not text:
        sys.stderr.write(f"ERROR: defense prompt file is empty: {p}\n")
        sys.exit(2)
    return text


def _ensure_harbor_supported() -> None:
    """Refuse to run against pre-0.6 harbor where the patch surface differs."""
    from harbor.agents.installed import base as _base

    if not hasattr(_base, "CliFlag"):
        import harbor

        sys.stderr.write(
            f"ERROR: harbor at {harbor.__file__} is too old (no CliFlag); "
            "expected harbor >= 0.6. Run this launcher with the tool python "
            "at ~/.local/share/uv/tools/harbor/bin/python.\n"
        )
        sys.exit(2)


def _patch_exec_as_agent(defense_text: str) -> None:
    from harbor.agents.installed.base import BaseInstalledAgent

    original = BaseInstalledAgent.exec_as_agent

    # claude-code: harbor invokes the agent as `claude --verbose ...` in
    # claude_code.py; --append-system-prompt is a first-class CLI flag.
    claude_marker = "claude --verbose"
    claude_inject = f" --append-system-prompt {shlex.quote(defense_text)} "

    # codex: harbor invokes `codex exec ...` and sets $CODEX_HOME=/tmp/codex-home.
    # Prepend an AGENTS.md heredoc so codex reads it on the same shell line.
    codex_marker = "codex exec "
    codex_block = (
        'cat >"$CODEX_HOME/AGENTS.md" <<\'SKILLHARM_DEFENSE_EOF\'\n'
        f"{defense_text}\n"
        "SKILLHARM_DEFENSE_EOF\n"
    )

    # gemini-cli: harbor invokes `gemini --yolo --model=<m> --prompt=<p>`.
    # Earlier we wrote ~/.gemini/GEMINI.md so the defense loaded as global
    # hierarchical memory (rendered as a "User Memory" section appended to
    # gemini-cli's ~1500-token default core prompt). Verified via input-
    # token deltas that GEMINI.md *did* reach the model context, but Gemini
    # 3 Flash showed near-zero rescue (3 T→F over 56 samples on stratified
    # subset, vs 12-26% for other victims). Hypothesis: the defense being
    # buried at the end as "memory" vs at the head as system instruction
    # changes its effective priority.
    #
    # New approach: dump gemini-cli's actual default system prompt to a
    # tmp file (gemini-cli supports this via `GEMINI_WRITE_SYSTEM_MD=path`,
    # which writes the rendered default prompt during chat init), then
    # concatenate with our defense, and feed the combined file as
    # GEMINI_SYSTEM_MD for the real invocation. This puts the defense at
    # the head of `systemInstruction` while preserving the default core
    # prompt's tool-use guidance / skills list / mandates — replacing
    # blindly with just the defense would strip those and cripple the
    # agent for reasons unrelated to defense efficacy.
    #
    # The dump call costs an extra cheap API roundtrip per sample (the
    # dummy `--prompt='ack'` runs through chat init — which is when the
    # write fires — then exits). Mktemp guards against parallel-sample
    # collisions on /tmp.
    gemini_marker = "gemini --yolo "

    # opencode: harbor invokes `opencode --model=<m> run --format=json ...`.
    # opencode follows the cross-CLI AGENTS.md spec; the global path
    # `~/.config/opencode/AGENTS.md` is loaded on every run regardless of cwd.
    # NOT YET DUMMY-VALIDATED — same trial.log grep verification as gemini.
    opencode_marker = "opencode --model="
    opencode_block = (
        "mkdir -p ~/.config/opencode && cat >~/.config/opencode/AGENTS.md "
        "<<'SKILLHARM_DEFENSE_EOF'\n"
        f"{defense_text}\n"
        "SKILLHARM_DEFENSE_EOF\n"
    )

    def _build_gemini_inject(model_for_dump: str) -> str:
        """Build the dump+concat+export snippet that runs in-shell right
        before harbor's `gemini --yolo …` invocation.

        Steps performed inside the container:
          1. Dummy gemini call with GEMINI_WRITE_SYSTEM_MD set → writes the
             default core prompt (with the *real* skill list, sandbox info,
             yolo flag, model-class-specific snippets) to a tmp file.
          2. Concatenate that file + our defense text into a second tmp file.
          3. Export GEMINI_SYSTEM_MD pointing at the combined file so the
             actual `gemini --yolo` invocation loads the augmented prompt
             as `systemInstruction`.

        `model_for_dump` is grabbed from the actual gemini --yolo command
        line via regex below — passing the same model ensures the dumped
        prompt matches what the real call would have built (Gemini model
        class affects which prompt template — `supportsModernFeatures()`
        toggle in the bundle).
        """
        return (
            'DEFAULT_SYS_MD=$(mktemp /tmp/skillharm-default-sys.XXXXXX.md); '
            'COMBINED_SYS_MD=$(mktemp /tmp/skillharm-combined-sys.XXXXXX.md); '
            f'GEMINI_WRITE_SYSTEM_MD="$DEFAULT_SYS_MD" timeout 60 gemini --yolo --prompt=ack --model={shlex.quote(model_for_dump)} >/dev/null 2>&1 || true; '
            'test -s "$DEFAULT_SYS_MD" || { echo "ERROR: gemini default system prompt dump produced empty file" >&2; exit 1; }; '
            'cp "$DEFAULT_SYS_MD" "$COMBINED_SYS_MD"; '
            "printf '\\n\\n' >> \"$COMBINED_SYS_MD\"; "
            "cat >> \"$COMBINED_SYS_MD\" <<'SKILLHARM_DEFENSE_EOF'\n"
            f"{defense_text}\n"
            "SKILLHARM_DEFENSE_EOF\n"
            'export GEMINI_SYSTEM_MD="$COMBINED_SYS_MD"; '
        )

    async def patched(self, environment, command, env=None, cwd=None, timeout_sec=None):
        new_cmd = command
        if claude_marker in new_cmd:
            new_cmd = new_cmd.replace(claude_marker, claude_marker + claude_inject, 1)
        if codex_marker in new_cmd:
            new_cmd = codex_block + new_cmd
        if gemini_marker in new_cmd:
            # Match the model from the existing gemini --yolo line so the
            # dump uses the same model class. Fallback to flash-preview if
            # missing (shouldn't happen — eval_defense.sh always sets -m).
            m = re.search(r"--model=(\S+)", new_cmd)
            model_for_dump = m.group(1) if m else "gemini-3-flash-preview"
            gemini_inject = _build_gemini_inject(model_for_dump)
            # Insert the dump+combine block *immediately* before the
            # gemini --yolo invocation — i.e. after `. ~/.nvm/nvm.sh;` so
            # the dummy call has nvm/`gemini` on PATH, not before it.
            new_cmd = new_cmd.replace(gemini_marker, gemini_inject + gemini_marker, 1)
        if opencode_marker in new_cmd:
            new_cmd = opencode_block + new_cmd
        return await original(
            self, environment, new_cmd, env=env, cwd=cwd, timeout_sec=timeout_sec
        )

    BaseInstalledAgent.exec_as_agent = patched  # type: ignore[assignment]


def main() -> int:
    _ensure_harbor_supported()
    defense_text = _read_defense_text()
    _patch_exec_as_agent(defense_text)

    # Import after patching so any harbor-internal references pick up the
    # patched method.
    from harbor.cli.main import app

    return app()


if __name__ == "__main__":
    sys.exit(main())
