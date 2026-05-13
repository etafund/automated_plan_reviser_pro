#!/usr/bin/env python3
"""Smoke-test v18 operator documentation examples.

This test executes only local mock/readiness examples. It does not run live
provider calls and does not invoke validate-subset.py because that tool may
clean generated Python caches as part of packaging validation.
"""

from __future__ import annotations

import json
import subprocess  # nosec B404 - docs smoke runs fixed local argv with shell=False.
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOG_DIR = ROOT / "tests" / "logs" / "docs-examples"

COMMANDS = [
    ["python3", "scripts/apr-mock.py", "capabilities", "--json"],
    ["python3", "scripts/apr-mock.py", "plan-routes", "--json"],
    ["python3", "scripts/apr-mock.py", "readiness", "--json"],
    ["python3", "scripts/apr-mock.py", "compile", "--json"],
    ["python3", "scripts/apr-mock.py", "fanout", "--json"],
    ["python3", "scripts/apr-mock.py", "synthesize", "--json"],
    ["python3", "scripts/apr-mock.py", "report", "--json"],
    ["python3", "scripts/apr-mock.py", "claude-code", "doctor", "--json"],
    ["python3", "scripts/apr-mock.py", "xai", "doctor", "--json"],
    ["python3", "scripts/apr-mock.py", "deepseek", "doctor", "--json"],
    ["python3", "scripts/apr-mock.py", "serialization", "doctor", "--format", "toon", "--json"],
]

DOC_COMMANDS = [
    "python3 scripts/apr-mock.py capabilities --json",
    "python3 scripts/apr-mock.py plan-routes --json",
    "python3 scripts/apr-mock.py readiness --json",
    "python3 scripts/apr-mock.py compile --json",
    "python3 scripts/apr-mock.py fanout --json",
    "python3 scripts/apr-mock.py report --json",
    "python3 scripts/apr-mock.py serialization doctor --format toon --json",
    "APR_V18_LIVE_CUTOVER=1 python3 scripts/live-cutover-dress-rehearsal.py --json --approval-id <approval-id> --execute-live",
]


def write_log(record: dict) -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    path = LOG_DIR / f"docs-examples-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}.jsonl"
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True) + "\n")


def assert_envelope(stdout: str, command: list[str]) -> None:
    try:
        payload = json.JSONDecoder().decode(stdout)
    except json.JSONDecodeError as exc:
        raise AssertionError(f"{' '.join(command)} did not emit JSON: {exc}") from exc
    for key in ("ok", "schema_version", "data", "meta", "warnings", "errors", "commands"):
        if key not in payload:
            raise AssertionError(f"{' '.join(command)} missing envelope key {key}")
    if payload["schema_version"] != "json_envelope.v1":
        raise AssertionError(f"{' '.join(command)} schema_version drifted")
    if payload["meta"].get("bundle_version") != "v18.0.0":
        raise AssertionError(f"{' '.join(command)} bundle_version drifted")
    if payload["ok"] is not True:
        raise AssertionError(f"{' '.join(command)} returned ok=false: {payload.get('errors')}")


def check_doc_snippets() -> None:
    docs = [
        ROOT / "README.md",
        ROOT / "ROBOTS.md",
        ROOT / "AGENTS.md",
        ROOT / "docs" / "provider-setup-guide.md",
        ROOT / "docs" / "live-cutover-operator-guide.md",
    ]
    corpus = "\n".join(path.read_text(encoding="utf-8") for path in docs)
    missing = [cmd for cmd in DOC_COMMANDS if cmd not in corpus]
    if missing:
        raise AssertionError("documented command snippets missing: " + "; ".join(missing))


def main() -> int:
    errors: list[str] = []
    fixture_project_path = str(ROOT)
    check_doc_snippets()
    for command in COMMANDS:
        completed = subprocess.run(  # nosec B603 - command argv is fixed in COMMANDS, shell=False.
            command,
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
            timeout=20,
        )
        record = {
            "command": " ".join(command),
            "expected_code": 0,
            "actual_code": completed.returncode,
            "fixture_project_path": fixture_project_path,
            "stdout_prefix": completed.stdout[:800],
            "stderr_prefix": completed.stderr[:800],
        }
        write_log(record)
        if completed.returncode != 0:
            errors.append(f"{record['command']} exited {completed.returncode}")
            continue
        try:
            assert_envelope(completed.stdout, command)
        except AssertionError as exc:
            errors.append(str(exc))
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print(json.dumps({"ok": True, "checked": len(COMMANDS), "log_dir": str(LOG_DIR)}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
