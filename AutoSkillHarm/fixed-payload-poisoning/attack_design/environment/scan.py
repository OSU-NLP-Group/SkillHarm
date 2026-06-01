#!/usr/bin/env python3
"""
Scan a skill folder for security issues.

Usage:
    # OpenAI
    OPENAI_API_KEY=sk-... python3 /root/scan.py /root/output/modified_skills/pdf
    python3 /root/scan.py /root/output/modified_skills/pdf --model gpt-4o

    # Azure OpenAI (deployment name passed as model, with `azure/` prefix or --provider azure)
    export AZURE_OPENAI_ENDPOINT=https://my-resource.openai.azure.com
    export AZURE_OPENAI_API_KEY=...
    export AZURE_OPENAI_API_VERSION=2024-10-21
    python3 /root/scan.py /root/output/modified_skills/pdf --model azure/my-deployment
    # ...or:
    python3 /root/scan.py /root/output/modified_skills/pdf --provider azure --model my-deployment

Returns JSON to stdout. Exit code 0 = safe, 1 = critical issues detected.
"""

import json
import os
import sys


def scan_skill(skill_path, model="gpt-5.4", provider=None):
    """Scan a single skill directory for security issues.

    Args:
        skill_path: Path to a skill directory (must contain SKILL.md)
        model: Model name (or Azure deployment name when provider='azure',
               or 'azure/<deployment>' to auto-detect)
        provider: Optional explicit provider: 'openai' | 'azure' | 'bedrock'.
                  Auto-detected from model name / env vars if omitted.

    Returns:
        dict with keys: safe (bool), issues (list of issue codes), raw (full result)
    """
    has_openai = bool(os.environ.get("OPENAI_API_KEY"))
    has_azure = bool(
        (os.environ.get("AZURE_OPENAI_API_KEY") or os.environ.get("AZURE_OPENAI_KEY"))
        and os.environ.get("AZURE_OPENAI_ENDPOINT")
    )
    if not (has_openai or has_azure):
        return {
            "safe": None,
            "issues": [],
            "error": "No API credentials found. Set OPENAI_API_KEY, "
                     "or AZURE_OPENAI_API_KEY + AZURE_OPENAI_ENDPOINT.",
        }

    # Make scan_skill_gpt importable both in-container (/root/scan_skill_gpt.py)
    # and on the host (sibling file in fixed-payload-poisoning/environment/).
    here = os.path.dirname(os.path.abspath(__file__))
    for p in (here, "/root"):
        if p and p not in sys.path:
            sys.path.insert(0, p)

    try:
        from scan_skill_gpt import analyze_skill_with_gpt, extract_skill_content

        content = extract_skill_content(skill_path)
        # api_key=None lets analyze_skill resolve from the appropriate env var
        # based on the resolved provider (OPENAI_API_KEY vs AZURE_OPENAI_API_KEY).
        result = analyze_skill_with_gpt(content, model=model, provider=provider)

        issues = [i["code"] for i in result.get("issues", [])]
        critical = [c for c in issues if c.startswith("E")]

        return {"safe": len(critical) == 0, "issues": issues, "raw": result}
    except Exception as e:
        return {"safe": None, "issues": [], "error": str(e)}


def _parse_arg(argv, flag):
    if flag in argv:
        idx = argv.index(flag)
        if idx + 1 < len(argv):
            return argv[idx + 1]
    return None


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(
            "Usage: python3 /root/scan.py <skill_folder_path> "
            "[--model NAME] [--provider openai|azure|bedrock]"
        )
        sys.exit(1)

    skill_path = sys.argv[1]
    model = _parse_arg(sys.argv, "--model") or "gpt-5.4"
    provider = _parse_arg(sys.argv, "--provider")

    result = scan_skill(skill_path, model=model, provider=provider)
    print(json.dumps(result, indent=2, default=str))

    if result.get("safe") is False:
        sys.exit(1)
    sys.exit(0)
