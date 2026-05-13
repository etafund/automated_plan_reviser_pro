#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess  # nosec B404 - harness executes fixed local scripts with shell=False.
import sys
import tempfile
from pathlib import Path
from typing import Any


VERSION = "v18.0.0"
ROOT = Path(__file__).resolve().parents[1]
CASES_PATH = ROOT / "fixtures" / "conformance" / "provider-adapter-pipeline-cases.json"
JSON_ENVELOPE_SCHEMA = ROOT / "contracts" / "json-envelope.schema.json"
PROVIDER_RESULT_SCHEMA = ROOT / "contracts" / "provider-result.schema.json"
PLAN_ARTIFACT_SCHEMA = ROOT / "contracts" / "plan-artifact.schema.json"
WORKDIR = Path(
    os.environ.get(
        "APR_V18_CONFORMANCE_WORKDIR",
        str(Path(tempfile.gettempdir()) / "apr-v18-provider-adapter-pipeline-conformance"),
    )
)
FORBIDDEN_PROVIDER_KEYS = {"raw_hidden_reasoning", "chain_of_thought", "reasoning_content"}


def envelope(
    ok: bool,
    data: dict[str, Any],
    errors: list[dict[str, str]] | None = None,
    warnings: list[str] | None = None,
) -> dict[str, Any]:
    return {
        "ok": ok,
        "schema_version": "json_envelope.v1",
        "data": data,
        "meta": {
            "tool": "provider-adapter-pipeline-conformance",
            "bundle_version": VERSION,
        },
        "blocked_reason": None if ok else "provider_adapter_pipeline_conformance_failed",
        "next_command": None if ok else "python3 scripts/provider-adapter-pipeline-conformance.py --json",
        "fix_command": None if ok else "fix listed v18 provider adapter or plan pipeline contract failures",
        "retry_safe": True,
        "errors": errors or [],
        "warnings": warnings or [],
        "commands": {
            "next": "python3 scripts/provider-adapter-pipeline-conformance.py --json",
            "cases": "jq '.cases[].id' fixtures/conformance/provider-adapter-pipeline-cases.json",
        },
    }


def load_json(path: Path) -> Any:
    try:
        return json.JSONDecoder().decode(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise RuntimeError(f"failed to read {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"failed to parse JSON in {path}: {exc}") from exc


def require_jsonschema():
    try:
        import jsonschema
    except ImportError as exc:
        raise RuntimeError("python3-jsonschema is required for v18 conformance checks") from exc
    return jsonschema


def validate_schema(instance: Any, schema_path: Path) -> list[str]:
    jsonschema = require_jsonschema()
    try:
        jsonschema.validate(instance, load_json(schema_path))
    except jsonschema.ValidationError as exc:
        return [f"{schema_path.relative_to(ROOT)}: {exc.message}"]
    return []


def json_pointer(instance: Any, pointer: str) -> Any:
    current = instance
    for raw_part in pointer.strip("/").split("/"):
        if raw_part == "":
            continue
        part = raw_part.replace("~1", "/").replace("~0", "~")
        if isinstance(current, dict):
            current = current[part]
        elif isinstance(current, list):
            current = current[int(part)]
        else:
            raise KeyError(pointer)
    return current


def command_env() -> dict[str, str]:
    env = os.environ.copy()
    env.update(
        {
            "NO_COLOR": "1",
            "APR_NO_GUM": "1",
            "CI": "true",
        }
    )
    return env


def run_command_case(case: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    script = ROOT / case["script"]
    cmd = [sys.executable, str(script), *case.get("args", [])]
    WORKDIR.mkdir(parents=True, exist_ok=True)
    completed = subprocess.run(  # nosec B603 - command is built from fixed local corpus entries.
        cmd,
        cwd=WORKDIR,
        env=command_env(),
        text=True,
        capture_output=True,
        check=False,
        timeout=30,
    )

    errors: list[str] = []
    if completed.returncode != case["expect_exit"]:
        errors.append(f"exit {completed.returncode}, expected {case['expect_exit']}")
    if completed.stderr:
        errors.append("stderr must be empty for robot-json conformance cases")

    output: dict[str, Any] = {}
    try:
        output = json.JSONDecoder().decode(completed.stdout)
    except json.JSONDecodeError as exc:
        errors.append(f"stdout is not valid JSON: {exc}")

    if output:
        errors.extend(validate_schema(output, JSON_ENVELOPE_SCHEMA))
        if output.get("schema_version") != "json_envelope.v1":
            errors.append("output schema_version must be json_envelope.v1")
        if output.get("ok") is not case["expect_ok"]:
            errors.append(f"output ok={output.get('ok')!r}, expected {case['expect_ok']!r}")

    provider_result = None
    if output and case.get("provider_result_pointer"):
        try:
            provider_result = json_pointer(output, case["provider_result_pointer"])
        except (KeyError, IndexError, TypeError, ValueError) as exc:
            errors.append(f"missing provider_result at {case['provider_result_pointer']}: {exc}")
        if provider_result:
            errors.extend(validate_schema(provider_result, PROVIDER_RESULT_SCHEMA))
            errors.extend(provider_result_invariant_errors(case["id"], provider_result))

    errors.extend(command_specific_errors(case["id"], output))
    return {
        "id": case["id"],
        "kind": case["kind"],
        "command": " ".join(cmd),
        "exit_code": completed.returncode,
        "ok": output.get("ok") if output else None,
        "status": "pass" if not errors else "fail",
        "stderr_empty": completed.stderr == "",
        "stdout_json": bool(output),
        "provider_result_validated": provider_result is not None,
    }, errors


def provider_result_invariant_errors(case_id: str, result: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    present = sorted(key for key in FORBIDDEN_PROVIDER_KEYS if key in result)
    if present:
        errors.append(f"{case_id}: provider result persists forbidden raw reasoning keys: {', '.join(present)}")
    if bool(result.get("reasoning_content_stored")):
        errors.append(f"{case_id}: provider result must not store raw reasoning content")

    slot = result.get("provider_slot")
    if slot == "deepseek_v4_pro_reasoning_search":
        if result.get("reasoning_effort") != "max":
            errors.append(f"{case_id}: DeepSeek reasoning_effort must be max")
        if result.get("search_tool_name") != "apr_web_search":
            errors.append(f"{case_id}: DeepSeek must use apr_web_search")
        if result.get("search_enabled") is not True:
            errors.append(f"{case_id}: DeepSeek search_enabled must be true")
        if result.get("reasoning_content_policy") != "transient_tool_replay_hash_only_persisted":
            errors.append(f"{case_id}: DeepSeek must persist only reasoning content hash")
    if slot == "xai_grok_reasoning" and result.get("reasoning_effort") != "high":
        errors.append(f"{case_id}: xAI reasoning_effort must be high")
    return errors


def command_specific_errors(case_id: str, output: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    data = output.get("data", {}) if output else {}
    if case_id == "deepseek_success_provider_result":
        provider_result = data.get("provider_result", {})
        if not provider_result.get("citations"):
            errors.append("deepseek_success_provider_result: citations must be present")
    elif case_id == "deepseek_raw_reasoning_rejected":
        error_codes = [entry.get("error_code") for entry in output.get("errors", [])]
        if "raw_reasoning_leak" not in error_codes:
            errors.append("deepseek_raw_reasoning_rejected: raw_reasoning_leak error_code required")
        provider_result = data.get("provider_result", {})
        if provider_result.get("status") != "failed":
            errors.append("deepseek_raw_reasoning_rejected: provider_result.status must be failed")
    elif case_id == "provider_adapter_fixtures_validate":
        if data.get("negative_fixture_rejected") is not True:
            errors.append("provider_adapter_fixtures_validate: negative fixture must be rejected")
        if data.get("must_score") != 1.0:
            errors.append("provider_adapter_fixtures_validate: must_score must be 1.0")
    elif case_id == "codex_intake_robot_surface":
        if data.get("schema_version") != "codex_intake.v1":
            errors.append("codex_intake_robot_surface: data.schema_version must be codex_intake.v1")
        if data.get("eligible_for_synthesis") is not False:
            errors.append("codex_intake_robot_surface: eligible_for_synthesis must be false")
    elif case_id == "claude_missing_prompt_error_surface":
        if output.get("ok") is not False:
            errors.append("claude_missing_prompt_error_surface: ok must be false")
        if not any(entry.get("error_code") == "adapter_failed" for entry in output.get("errors", [])):
            errors.append("claude_missing_prompt_error_surface: adapter_failed error required")
    elif case_id.startswith("plan_pipeline_"):
        expected_stage = case_id.removeprefix("plan_pipeline_").removesuffix("_surface")
        if data.get("stage") != expected_stage:
            errors.append(f"{case_id}: data.stage must be {expected_stage}")
        if data.get("status") != "success":
            errors.append(f"{case_id}: data.status must be success")
    return errors


def run_fixture_schema_case(case: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    fixture_path = ROOT / case["fixture"]
    schema_path = ROOT / case["schema"]
    errors = validate_schema(load_json(fixture_path), schema_path)
    if case["schema"] == PLAN_ARTIFACT_SCHEMA.relative_to(ROOT).as_posix():
        fixture = load_json(fixture_path)
        if fixture.get("schema_version") != "plan_artifact.v1":
            errors.append("plan_artifact fixture schema_version must be plan_artifact.v1")
        if not fixture.get("sections"):
            errors.append("plan_artifact fixture must include sections")
    return {
        "id": case["id"],
        "kind": case["kind"],
        "fixture": case["fixture"],
        "schema": case["schema"],
        "status": "pass" if not errors else "fail",
    }, errors


def run_case(case: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    if case["kind"] == "command":
        return run_command_case(case)
    if case["kind"] == "fixture_schema":
        return run_fixture_schema_case(case)
    return {
        "id": case.get("id", "unknown"),
        "kind": case.get("kind", "unknown"),
        "status": "fail",
    }, [f"{case.get('id', 'unknown')}: unsupported case kind {case.get('kind')!r}"]


def main() -> int:
    parser = argparse.ArgumentParser(description="v18 provider adapter and plan pipeline conformance harness.")
    parser.add_argument("--json", action="store_true", help="Emit a v18 JSON envelope.")
    parser.add_argument("--cases", default=str(CASES_PATH), help="Case corpus JSON path.")
    args = parser.parse_args()

    case_doc = load_json(Path(args.cases))
    errors: list[dict[str, str]] = []
    results: list[dict[str, Any]] = []
    try:
        require_jsonschema()
    except RuntimeError as exc:
        errors.append({"error_code": "dependency_missing", "message": str(exc)})

    if case_doc.get("bundle_version") != VERSION:
        errors.append({"error_code": "case_corpus_invalid", "message": f"case corpus bundle_version must be {VERSION}"})

    for case in case_doc.get("cases", []):
        if errors and errors[0]["error_code"] == "dependency_missing":
            break
        result, case_errors = run_case(case)
        results.append(result)
        errors.extend({"error_code": "conformance_failed", "message": f"{case['id']}: {error}"} for error in case_errors)

    must_clauses = len(case_doc.get("cases", []))
    passing = sum(1 for result in results if result.get("status") == "pass")
    coverage = {
        "must_clauses": must_clauses,
        "tested": len(results),
        "passing": passing,
        "failing": len(results) - passing,
        "must_score": 1.0 if must_clauses and passing == must_clauses and not errors else 0.0,
        "command_cases": sum(1 for case in case_doc.get("cases", []) if case.get("kind") == "command"),
        "fixture_schema_cases": sum(1 for case in case_doc.get("cases", []) if case.get("kind") == "fixture_schema"),
    }
    data = {
        "bundle_version": VERSION,
        "cases_path": str(Path(args.cases).resolve()),
        "workdir": str(WORKDIR),
        "coverage": coverage,
        "cases": results,
    }
    out = envelope(ok=not errors and coverage["must_score"] == 1.0, data=data, errors=errors)
    if args.json:
        print(json.dumps(out, indent=2, sort_keys=True))
    elif out["ok"]:
        print("ok")
    else:
        for error in errors:
            print(error["message"], file=sys.stderr)
    return 0 if out["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
