#!/usr/bin/env python3
"""Conformance checks for the v18 prompt compiler route surface."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

VERSION = "v18.0.0"
ENVELOPE_VERSION = "json_envelope.v1"
HASH_RE = re.compile(r"^sha256:[0-9a-f]{64}$")


def load_json(path: Path) -> Any:
    text = path.read_text(encoding="utf-8")
    try:
        return json.JSONDecoder().decode(text)
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path}: invalid JSON: {exc}") from exc


def sha256_text(value: str) -> str:
    return "sha256:" + hashlib.sha256(value.encode("utf-8")).hexdigest()


def relative(root: Path, path: Path) -> str:
    return str(path.relative_to(root))


def envelope(ok: bool, data: dict[str, Any], errors: list[dict[str, str]], warnings: list[dict[str, str]]) -> dict[str, Any]:
    return {
        "blocked_reason": None if ok else "prompt_compiler_conformance_failed",
        "commands": {
            "next": "python3 scripts/prompt-compiler-conformance.py --json",
        },
        "data": data,
        "errors": errors,
        "fix_command": None if ok else "fix listed prompt compiler conformance failures",
        "meta": {
            "bundle_version": VERSION,
            "tool": "prompt-compiler-conformance",
        },
        "ok": ok,
        "retry_safe": True,
        "schema_version": ENVELOPE_VERSION,
        "warnings": warnings,
    }


def policy_key_for_slot(slot: str) -> str:
    if "chatgpt" in slot:
        return "chatgpt_pro_browser"
    if "claude" in slot:
        return "claude_code"
    if "deepseek" in slot:
        return "deepseek_v4_pro_api"
    if "gemini" in slot:
        return "gemini_deep_think_browser"
    if "xai" in slot:
        return "xai_grok_api"
    if "codex" in slot:
        return "codex_intake_policy"
    return ""


def expected_rules(policy: dict[str, Any], slot: str) -> list[str]:
    key = policy_key_for_slot(slot)
    if key == "codex_intake_policy":
        return [rule for rule in policy.get(key, {}).get("recommended", []) if isinstance(rule, str)]
    return [rule for rule in policy.get("policies", {}).get(key, {}).get("rules", []) if isinstance(rule, str)]


def declared_routes(provider_route: dict[str, Any]) -> list[dict[str, Any]]:
    routes = provider_route.get("routes")
    if not isinstance(routes, list):
        return []
    return [route for route in routes if isinstance(route, dict) and isinstance(route.get("slot"), str)]


def run_compile(root: Path, slot: str) -> subprocess.CompletedProcess[str]:
    script = root / "scripts" / "compile-prompt.py"
    return subprocess.run(
        [
            sys.executable,
            str(script),
            "--route",
            slot,
            "--baseline",
            str(root / "fixtures" / "source-baseline.json"),
            "--manifest",
            str(root / "fixtures" / "prompt-manifest.json"),
            "--policy",
            str(root / "fixtures" / "prompting-policy.json"),
            "--json",
        ],
        capture_output=True,
        text=True,
        check=False,
        cwd=str(root.parents[1]),
        timeout=30,
    )


def run_case(root: Path, route: dict[str, Any], policy: dict[str, Any]) -> tuple[dict[str, Any], list[str], list[dict[str, str]]]:
    slot = route["slot"]
    policy_key = policy_key_for_slot(slot)
    wanted_rules = expected_rules(policy, slot)
    result: dict[str, Any] = {
        "case_id": f"compile-{slot}",
        "requirement_level": "MUST",
        "route": slot,
        "policy_key": policy_key,
        "status": "unknown",
    }
    failures: list[str] = []
    warnings: list[dict[str, str]] = []

    if not policy_key:
        failures.append(f"{slot}: no policy key mapping")
    if not wanted_rules:
        failures.append(f"{slot}: no expected prompt policy rules")

    first = run_compile(root, slot)
    second = run_compile(root, slot)
    result["exit_code"] = first.returncode
    result["stderr_sha256"] = sha256_text(first.stderr)

    if first.returncode != 0:
        failures.append(f"{slot}: compile-prompt exited {first.returncode}")
    if first.stderr:
        failures.append(f"{slot}: compile-prompt wrote stderr on success path")
    if first.stdout != second.stdout:
        failures.append(f"{slot}: compile-prompt output is not deterministic")

    try:
        output = json.JSONDecoder().decode(first.stdout)
    except json.JSONDecodeError as exc:
        result["status"] = "fail"
        result["stdout_sha256"] = sha256_text(first.stdout)
        return result, failures + [f"{slot}: stdout is not JSON: {exc}"], warnings

    data = output.get("data", {})
    prompt_hash = data.get("prompt_hash")
    provider_rules = data.get("provider_rules")
    preview = data.get("redacted_preview")

    result.update(
        {
            "envelope_schema_version": output.get("schema_version"),
            "ok": output.get("ok"),
            "prompt_hash": prompt_hash,
            "stdout_sha256": sha256_text(first.stdout),
            "provider_rule_count": len(provider_rules) if isinstance(provider_rules, list) else 0,
        }
    )

    if output.get("schema_version") != ENVELOPE_VERSION:
        failures.append(f"{slot}: envelope schema_version drifted")
    if output.get("ok") is not True:
        failures.append(f"{slot}: envelope ok is not true")
    if data.get("route") != slot:
        failures.append(f"{slot}: data.route mismatch")
    if not isinstance(prompt_hash, str) or not HASH_RE.match(prompt_hash):
        failures.append(f"{slot}: prompt_hash is not sha256:<64-hex>")
    if provider_rules != wanted_rules:
        failures.append(f"{slot}: provider_rules diverge from prompting policy {policy_key}")
    if not isinstance(preview, str):
        failures.append(f"{slot}: redacted_preview missing")
    else:
        required_fragments = [
            f"Role: You are an expert acting in the {slot} capacity.",
            "Provider Rules:",
            "Baseline Hash:",
            "Manifest Hash:",
        ]
        missing = [fragment for fragment in required_fragments if fragment not in preview]
        if missing:
            failures.append(f"{slot}: redacted_preview missing fragments {missing}")
        if any(rule not in preview for rule in wanted_rules):
            failures.append(f"{slot}: redacted_preview omits one or more provider policy rules")
        if "Manifest Hash: unknown" in preview:
            warnings.append(
                {
                    "warning_code": "manifest_hash_not_exported",
                    "message": f"{slot}: prompt-manifest fixture has no prompt_manifest_sha256 field; compiler emits unknown",
                }
            )

    result["status"] = "pass" if not failures else "fail"
    return result, failures, warnings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate compile-prompt.py against v18 route and prompt policy fixtures.")
    parser.add_argument("--json", action="store_true", help="Emit standard robot JSON envelope.")
    parser.add_argument(
        "--root",
        default=str(Path(__file__).resolve().parents[1]),
        help="Bundle root directory. Defaults to the parent of this script directory.",
    )
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()

    errors: list[dict[str, str]] = []
    warnings: list[dict[str, str]] = []
    cases: list[dict[str, Any]] = []

    try:
        provider_route = load_json(root / "fixtures" / "provider-route.balanced.json")
        policy = load_json(root / "fixtures" / "prompting-policy.json")
    except Exception as exc:
        output = envelope(
            False,
            {"checked_root": str(root), "coverage": {"score": 0}},
            [{"error_code": "fixture_load_failed", "message": str(exc)}],
            warnings,
        )
        print(json.dumps(output, indent=2, sort_keys=True) if args.json else output["errors"][0]["message"])
        return 1

    routes = declared_routes(provider_route)
    if not routes:
        errors.append({"error_code": "route_fixture_empty", "message": "provider-route.balanced.json declares no routes"})

    for route in routes:
        case, failures, case_warnings = run_case(root, route, policy)
        cases.append(case)
        warnings.extend(case_warnings)
        for failure in failures:
            errors.append({"error_code": "prompt_compile_conformance_failed", "message": failure})

    passing = sum(1 for case in cases if case.get("status") == "pass")
    coverage = {
        "must_clauses": len(cases),
        "should_clauses": 0,
        "tested": len(cases),
        "passing": passing,
        "divergent": len(cases) - passing,
        "score": (passing / len(cases)) if cases else 0,
        "route_cases": len(cases),
    }
    data = {
        "bundle_version": VERSION,
        "checked_root": str(root),
        "coverage": coverage,
        "fixtures": {
            "provider_route": relative(root, root / "fixtures" / "provider-route.balanced.json"),
            "prompt_policy": relative(root, root / "fixtures" / "prompting-policy.json"),
            "source_baseline": relative(root, root / "fixtures" / "source-baseline.json"),
            "prompt_manifest": relative(root, root / "fixtures" / "prompt-manifest.json"),
        },
        "route_slots": [case["route"] for case in cases],
        "cases": cases,
    }
    output = envelope(not errors, data, errors, warnings)
    if args.json:
        print(json.dumps(output, indent=2, sort_keys=True))
    elif errors:
        print("\n".join(error["message"] for error in errors))
    else:
        print("ok")
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
