#!/usr/bin/env python3
"""
Scan a skill folder for security issues.

Usage:
    python3 /root/scan.py /root/output/modified_skills/pdf
    python3 /root/scan.py /root/output/modified_skills/pdf --model gpt-5.4

Returns JSON to stdout. Exit code 0 = safe, 1 = critical issues detected.
"""

import json
import os
import sys


def scan_skill(skill_path, model="gpt-5.4"):
    """Scan a single skill directory for security issues.

    Args:
        skill_path: Path to a skill directory (must contain SKILL.md)
        model: OpenAI model for scanning (default: gpt-5.4)

    Returns:
        dict with keys: safe (bool), issues (list of issue codes), raw (full result)
    """
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        return {"safe": None, "issues": [], "error": "OPENAI_API_KEY not set"}

    if "/root" not in sys.path:
        sys.path.insert(0, "/root")

    try:
        from scan_skill_gpt import extract_skill_content, analyze_skill_with_gpt

        content = extract_skill_content(skill_path)
        result = analyze_skill_with_gpt(content, model=model, api_key=api_key)

        issues = [i["code"] for i in result.get("issues", [])]
        critical = [c for c in issues if c.startswith("E")]

        return {"safe": len(critical) == 0, "issues": issues, "raw": result}
    except Exception as e:
        return {"safe": None, "issues": [], "error": str(e)}


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 /root/scan.py <skill_folder_path> [--model gpt-5.4]")
        sys.exit(1)

    skill_path = sys.argv[1]
    model = "gpt-5.4"

    if "--model" in sys.argv:
        idx = sys.argv.index("--model")
        if idx + 1 < len(sys.argv):
            model = sys.argv[idx + 1]

    result = scan_skill(skill_path, model=model)
    print(json.dumps(result, indent=2, default=str))

    if result.get("safe") is False:
        sys.exit(1)
    sys.exit(0)
