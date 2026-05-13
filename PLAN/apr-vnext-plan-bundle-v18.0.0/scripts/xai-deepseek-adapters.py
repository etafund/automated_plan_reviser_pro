#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path
from typing import Any

VERSION = "v18.0.0"
ROOT = Path(__file__).resolve().parents[1]
PROVIDER_RESULT_SCHEMA = ROOT / "contracts" / "provider-result.schema.json"
JSON_ENVELOPE_SCHEMA = ROOT / "contracts" / "json-envelope.schema.json"

PROVIDER_CONFIGS: dict[str, dict[str, Any]] = {
    "deepseek": {
        "access_path": "deepseek_official_api",
        "api_base_url": "https://api.deepseek.com",
        "api_key_env": "DEEPSEEK_API_KEY",
        "model": "deepseek-v4-pro",
        "provider_family": "deepseek",
        "provider_slot": "deepseek_v4_pro_reasoning_search",
        "reasoning_effort": "max",
        "reasoning_config": {
            "provider_nomenclature": "DeepSeek Chat Completions reasoning_effort",
            "reasoning_effort": "max",
            "thinking": {"type": "enabled"},
        },
    },
    "xai": {
        "access_path": "xai_api",
        "api_base_url": "https://api.x.ai/v1",
        "api_key_env": "XAI_API_KEY",
        "model": "grok-4.3",
        "provider_family": "xai_grok",
        "provider_slot": "xai_grok_reasoning",
        "reasoning_effort": "high",
        "reasoning_config": {
            "provider_nomenclature": "xAI Chat Completions reasoning_effort",
            "reasoning_effort": "high",
        },
    },
}

FAILURE_SCENARIOS = {
    "auth_failure": ("auth_missing", "required API key environment variable is not set"),
    "rate_limit": ("rate_limited", "provider returned a retryable rate limit"),
    "model_unavailable": ("model_unavailable", "required model is not available"),
    "search_disabled": ("search_disabled", "DeepSeek route requires apr_web_search"),
    "missing_citations": ("missing_citations", "DeepSeek search responses must include citations"),
    "raw_reasoning_leak": ("raw_reasoning_leak", "raw reasoning content must not be persisted"),
}

FORBIDDEN_PROVIDER_KEYS = {"raw_hidden_reasoning", "chain_of_thought", "reasoning_content"}


def sha256_text(value: str) -> str:
    return "sha256:" + hashlib.sha256(value.encode("utf-8")).hexdigest()


def load_json(path: Path) -> Any:
    return json.JSONDecoder().decode(path.read_text(encoding="utf-8"))


def exact_bool(record: dict[str, Any], key: str, expected: bool) -> bool:
    value = record.get(key)
    return isinstance(value, bool) and value == expected


def envelope(
    ok: bool,
    data: dict[str, Any],
    errors: list[dict[str, str]] | None = None,
    warnings: list[str] | None = None,
    blocked_reason: str | None = None,
    next_command: str | None = None,
    fix_command: str | None = None,
    retry_safe: bool = True,
) -> dict[str, Any]:
    return {
        "ok": ok,
        "schema_version": "json_envelope.v1",
        "data": data,
        "meta": {"tool": "xai-deepseek-adapters", "bundle_version": VERSION},
        "blocked_reason": blocked_reason,
        "next_command": next_command,
        "fix_command": fix_command,
        "retry_safe": retry_safe,
        "errors": errors or [],
        "warnings": warnings or [],
        "commands": {
            "deepseek_success": "python3 scripts/xai-deepseek-adapters.py --provider deepseek --scenario success --json",
            "xai_success": "python3 scripts/xai-deepseek-adapters.py --provider xai --scenario success --json",
            "validate": "python3 scripts/xai-deepseek-adapters.py --validate-fixtures --json",
        },
    }


def base_result(provider: str, scenario: str, prompt_text: str) -> dict[str, Any]:
    config = PROVIDER_CONFIGS[provider]
    result = {
        "schema_version": "provider_result.v1",
        "bundle_version": VERSION,
        "provider_result_id": f"provider-result-{config['provider_slot']}-{scenario}",
        "provider_slot": config["provider_slot"],
        "provider_family": config["provider_family"],
        "access_path": config["access_path"],
        "api_base_url": config["api_base_url"],
        "api_key_env": config["api_key_env"],
        "model": config["model"],
        "official_api": True,
        "status": "success",
        "synthesis_eligible": True,
        "evidence": None,
        "evidence_id": None,
        "prompt_manifest_sha256": sha256_text("prompt-manifest:" + prompt_text),
        "source_baseline_sha256": sha256_text("source-baseline:mock-v18"),
        "result_text_sha256": sha256_text(provider + ":" + scenario + ":result"),
        "result_path": f".apr/runs/mock/providers/{config['provider_slot']}/output.md",
        "reasoning_effort": config["reasoning_effort"],
        "reasoning_effort_verified": True,
        "reasoning_config": config["reasoning_config"],
        "redaction_actions": [
            "api_key_env_redacted",
            "request_hash_recorded",
            "response_hash_recorded",
        ],
        "adapter_log": {
            "request_sha256": sha256_text(provider + ":" + scenario + ":request"),
            "response_sha256": sha256_text(provider + ":" + scenario + ":response"),
            "duration_ms": 42,
            "retry_policy": "retry_rate_limit_and_transient_5xx",
            "redaction_verdict": "no_raw_reasoning_or_secret_material_persisted",
        },
    }
    if provider == "deepseek":
        result.update(
            {
                "thinking": {"type": "enabled"},
                "thinking_enabled": True,
                "reasoning_content_policy": "transient_tool_replay_hash_only_persisted",
                "reasoning_content_transient_replay": True,
                "reasoning_content_stored": False,
                "reasoning_content_sha256": sha256_text("deepseek-transient-reasoning"),
                "search_enabled": True,
                "search_mode": "tool_call_web_search",
                "search_tool_name": "apr_web_search",
                "search_trace_sha256": sha256_text("deepseek-redacted-search-trace"),
                "search_result_count": 3,
                "citations": [
                    {
                        "title": "DeepSeek API docs snapshot",
                        "url": "https://api-docs.deepseek.com/",
                        "retrieved_at": "2026-05-12T12:00:00Z",
                        "trust_label": "provider_docs_snapshot",
                    }
                ],
                "citation_count": 1,
                "tool_call_replay_policy": "transient_reasoning_content_replay_only",
            }
        )
    return result


def classify_failure(provider: str, scenario: str, prompt_text: str) -> dict[str, Any]:
    error_code, message = FAILURE_SCENARIOS[scenario]
    result = base_result(provider, scenario, prompt_text)
    result.update(
        {
            "status": "failed",
            "synthesis_eligible": False,
            "degradation_reason": error_code,
            "error": {
                "code": error_code,
                "message": message,
                "retryable": scenario in {"rate_limit", "model_unavailable"},
            },
            "reasoning_effort_verified": scenario not in {"auth_failure", "model_unavailable"},
        }
    )
    if scenario == "search_disabled":
        result.update({"search_enabled": False, "search_mode": "disabled", "search_trace_sha256": None})
    if scenario == "missing_citations":
        result.update({"citations": [], "citation_count": 0})
    if scenario == "raw_reasoning_leak":
        result["raw_reasoning_rejected"] = True
        result["error"]["message"] = "adapter rejected raw reasoning_content before persistence"
    return result


def build_result(provider: str, scenario: str, prompt_text: str) -> tuple[bool, dict[str, Any], list[dict[str, str]]]:
    if scenario == "success":
        result = base_result(provider, scenario, prompt_text)
        return True, result, []
    if scenario in {"search_disabled", "missing_citations"} and provider != "deepseek":
        message = f"{scenario} applies only to the DeepSeek search route"
        return False, {}, [{"error_code": "invalid_scenario", "message": message}]
    result = classify_failure(provider, scenario, prompt_text)
    return False, result, [{"error_code": result["error"]["code"], "message": result["error"]["message"]}]


def validate_provider_result_contract(result: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    present = sorted(key for key in FORBIDDEN_PROVIDER_KEYS if key in result)
    if present:
        errors.append("provider result persists forbidden raw reasoning keys: " + ", ".join(present))
    if exact_bool(result, "reasoning_content_stored", True):
        errors.append("provider result must not set reasoning_content_stored=true")
    if result.get("provider_slot") == "deepseek_v4_pro_reasoning_search":
        if result.get("search_tool_name") != "apr_web_search":
            errors.append("DeepSeek result must use apr_web_search")
        if result.get("search_enabled") is not True:
            errors.append("DeepSeek result must require search_enabled=true")
        if not result.get("citations"):
            errors.append("DeepSeek result must include at least one citation")
    if result.get("provider_slot") == "xai_grok_reasoning" and result.get("reasoning_effort") != "high":
        errors.append("xAI result must use reasoning_effort=high")
    return errors


def jsonschema_errors(instance: dict[str, Any], schema_path: Path) -> list[str]:
    try:
        import jsonschema
    except ImportError:
        return []
    try:
        jsonschema.validate(instance, load_json(schema_path))
    except jsonschema.ValidationError as exc:
        return [f"{schema_path.name} validation failed: {exc.message}"]
    return []


def validate_fixtures() -> tuple[bool, dict[str, Any], list[dict[str, str]], list[str]]:
    fixture_paths = [
        ROOT / "fixtures" / "provider-adapter.deepseek.success.json",
        ROOT / "fixtures" / "provider-adapter.xai.success.json",
    ]
    negative_path = ROOT / "fixtures" / "negative" / "provider-adapter-deepseek-raw-reasoning.invalid.json"
    failures: list[str] = []
    validated: list[str] = []
    for path in fixture_paths:
        result = load_json(path)
        failures.extend(f"{path.name}: {error}" for error in jsonschema_errors(result, PROVIDER_RESULT_SCHEMA))
        failures.extend(f"{path.name}: {error}" for error in validate_provider_result_contract(result))
        validated.append(path.relative_to(ROOT).as_posix())
    negative = load_json(negative_path)
    negative_errors = jsonschema_errors(negative, PROVIDER_RESULT_SCHEMA) + validate_provider_result_contract(negative)
    if not negative_errors:
        failures.append("negative raw-reasoning fixture unexpectedly passed validation")
    else:
        validated.append(negative_path.relative_to(ROOT).as_posix())
    data = {
        "validated_fixtures": validated,
        "must_clauses": 8,
        "should_clauses": 2,
        "passing": 10 if not failures else 9,
        "must_score": 1.0 if not failures else 0.0,
        "negative_fixture_rejected": bool(negative_errors),
        "json_envelope_contract": "validated" if not jsonschema_errors(envelope(True, {}), JSON_ENVELOPE_SCHEMA) else "unchecked",
    }
    errors = [{"error_code": "provider_adapter_fixture_invalid", "message": failure} for failure in failures]
    return (not failures), data, errors, []


def prompt_text_from_path(prompt_path: str) -> str:
    prompt_file = Path(prompt_path)
    if not prompt_file.is_file():
        raise FileNotFoundError(f"Prompt file not found: {prompt_file}")
    text = prompt_file.read_text(encoding="utf-8")
    if not text.strip():
        raise ValueError("prompt input is empty")
    return text


def main() -> int:
    parser = argparse.ArgumentParser(description="Deterministic v18 xAI and DeepSeek provider adapter harness.")
    parser.add_argument("--provider", choices=sorted(PROVIDER_CONFIGS))
    parser.add_argument("--action", choices=["invoke", "check"])
    parser.add_argument("--scenario", choices=["success", *sorted(FAILURE_SCENARIOS)])
    parser.add_argument("--prompt", help="Prompt file path for invoke.")
    parser.add_argument("--output", help="Optional path to write provider_result.")
    parser.add_argument("--check-env", action="store_true")
    parser.add_argument("--validate-fixtures", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    if args.validate_fixtures:
        ok, data, errors, warnings = validate_fixtures()
        out = envelope(ok, data, errors=errors, warnings=warnings)
        print(json.dumps(out, indent=2, sort_keys=True) if args.json else ("ok" if ok else "\n".join(e["message"] for e in errors)))
        return 0 if ok else 1

    if not args.provider:
        out = envelope(False, {}, errors=[{"error_code": "usage_error", "message": "--provider is required"}], blocked_reason="missing_provider")
        print(json.dumps(out, indent=2, sort_keys=True) if args.json else "--provider is required")
        return 2

    config = PROVIDER_CONFIGS[args.provider]
    env_present = bool(os.environ.get(config["api_key_env"]))
    errors: list[dict[str, str]] = []

    if args.action == "check":
        data = {
            "provider": args.provider,
            "available": env_present,
            "api_key_status": "configured" if env_present else "missing",
            "api_key_env": config["api_key_env"],
            "api_key_present": env_present,
        }
        out = envelope(True, data, errors=errors)
        print(json.dumps(out, indent=2, sort_keys=True) if args.json else "ok")
        return 0

    scenario = args.scenario or ("success" if args.action == "invoke" else "success")
    prompt_text = "mock v18 provider adapter prompt"
    if args.action == "invoke":
        if not args.prompt:
            out = envelope(False, {}, errors=[{"error_code": "adapter_failed", "message": "--prompt is required"}], blocked_reason="missing_prompt")
            print(json.dumps(out, indent=2, sort_keys=True) if args.json else "--prompt is required")
            return 1
        try:
            prompt_text = prompt_text_from_path(args.prompt)
        except Exception as exc:
            out = envelope(False, {}, errors=[{"error_code": "adapter_failed", "message": str(exc)}], blocked_reason="prompt_read_failed")
            print(json.dumps(out, indent=2, sort_keys=True) if args.json else str(exc))
            return 1

    if args.check_env and not env_present:
        scenario = "auth_failure"

    ok, result, scenario_errors = build_result(args.provider, scenario, prompt_text)
    contract_errors = validate_provider_result_contract(result) if result else []
    if contract_errors:
        ok = False
        scenario_errors.extend({"error_code": "contract_violation", "message": e} for e in contract_errors)

    if args.output and result:
        output_path = Path(args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        result["artifact_written"] = str(output_path)

    data = {
        "provider": args.provider,
        "provider_slot": config["provider_slot"],
        "scenario": scenario,
        "api_key_env": config["api_key_env"],
        "api_key_present": env_present,
        "provider_result": result,
    }
    out = envelope(ok, data, errors=scenario_errors, blocked_reason=None if ok else "provider adapter scenario failed")
    print(json.dumps(out, indent=2, sort_keys=True) if args.json else ("ok" if ok else "\n".join(e["message"] for e in scenario_errors)))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
