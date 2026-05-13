#!/usr/bin/env python3
"""Cross-schema conformance checks for v18 route/source/prompt contracts."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

VERSION = "v18.0.0"
ENVELOPE_VERSION = "json_envelope.v1"
CASES_PATH = "fixtures/conformance/schema-cross-invariant-cases.json"

FIXTURES = {
    "context_serialization": "fixtures/context-serialization-policy.json",
    "model_reasoning": "fixtures/model-reasoning-policy.json",
    "prompt_context": "fixtures/prompt-context-packet.json",
    "prompt_manifest": "fixtures/prompt-manifest.json",
    "prompt_policy": "fixtures/prompting-policy.json",
    "provider_access": "fixtures/provider-access-policy.json",
    "provider_route": "fixtures/provider-route.balanced.json",
    "review_quorum": "fixtures/review-quorum.balanced.json",
    "route_readiness": "fixtures/route-readiness.balanced.json",
    "runtime_budget": "fixtures/runtime-budget.json",
    "source_baseline": "fixtures/source-baseline.json",
    "source_trust": "fixtures/source-trust.json",
}

BROWSER_SLOTS = {
    "chatgpt_pro_first_plan",
    "chatgpt_pro_synthesis",
    "gemini_deep_think",
}


def load_json(path: Path) -> Any:
    text = path.read_text(encoding="utf-8")
    try:
        return json.JSONDecoder().decode(text)
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path}: invalid JSON: {exc}") from exc


def sha256_text(value: str) -> str:
    return "sha256:" + hashlib.sha256(value.encode("utf-8")).hexdigest()


def strict_true(value: object) -> bool:
    return isinstance(value, bool) and value


def strict_false(value: object) -> bool:
    return isinstance(value, bool) and not value


def as_set(value: Any) -> set[str]:
    if not isinstance(value, list):
        return set()
    return {item for item in value if isinstance(item, str)}


def route_slots(provider_route: dict[str, Any]) -> set[str]:
    return {
        route["slot"]
        for route in provider_route.get("routes", [])
        if isinstance(route, dict) and isinstance(route.get("slot"), str)
    }


def route_by_slot(provider_route: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {
        route["slot"]: route
        for route in provider_route.get("routes", [])
        if isinstance(route, dict) and isinstance(route.get("slot"), str)
    }


def validation_error_message(exc: Exception) -> str:
    path = ".".join(str(part) for part in getattr(exc, "absolute_path", []))
    base = getattr(exc, "message", str(exc))
    return f"{path}: {base}" if path else base


def check(condition: bool, failures: list[str], message: str) -> None:
    if not condition:
        failures.append(message)


def invariant_route_slots_covered_by_policy(data: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    provider_route = data["provider_route"]
    provider_access = data["provider_access"]
    model_reasoning = data["model_reasoning"]

    slots = route_slots(provider_route)
    access_slots = set(provider_access.get("live_routes", {}).keys())
    reasoning_slots = set(model_reasoning.get("live_provider_effort_defaults", {}).keys())
    missing_access = sorted(slots - access_slots)
    missing_reasoning = sorted(slots - reasoning_slots)
    check(not missing_access, failures, f"route slots missing provider-access policy: {missing_access}")
    check(not missing_reasoning, failures, f"route slots missing model-reasoning policy: {missing_reasoning}")
    return failures


def invariant_stage_slot_sets_match_route_declarations(data: dict[str, Any]) -> list[str]:
    provider_route = data["provider_route"]
    failures: list[str] = []
    stage_required = set().union(*(as_set(value) for value in provider_route.get("stage_required_slots", {}).values()))
    stage_optional = set().union(*(as_set(value) for value in provider_route.get("stage_optional_slots", {}).values()))
    required_slots = as_set(provider_route.get("required_slots"))
    optional_slots = as_set(provider_route.get("optional_slots"))
    check(stage_required == required_slots, failures, f"stage required slots {sorted(stage_required)} != {sorted(required_slots)}")
    check(stage_optional == optional_slots, failures, f"stage optional slots {sorted(stage_optional)} != {sorted(optional_slots)}")
    check(required_slots.isdisjoint(optional_slots), failures, "required and optional slots overlap")
    return failures


def invariant_browser_slots_require_verified_evidence(data: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    provider_access = data["provider_access"]
    route_readiness = data["route_readiness"]
    live_routes = provider_access.get("live_routes", {})
    readiness_evidence = as_set(route_readiness.get("browser_evidence_required_for"))
    route_browser_slots = {
        slot for slot, route in live_routes.items() if str(route.get("access_path", "")).startswith("oracle_browser")
    }
    check(BROWSER_SLOTS <= route_browser_slots, failures, f"protected browser slots missing browser access: {sorted(BROWSER_SLOTS - route_browser_slots)}")
    check(BROWSER_SLOTS <= readiness_evidence, failures, f"readiness missing browser evidence requirements: {sorted(BROWSER_SLOTS - readiness_evidence)}")
    for slot in sorted(BROWSER_SLOTS):
        route = live_routes.get(slot, {})
        check(strict_false(route.get("api_allowed")), failures, f"{slot} must forbid api_allowed")
        check(strict_true(route.get("evidence_required")), failures, f"{slot} must require evidence")
    return failures


def invariant_quorum_policy_matches_route_and_readiness(data: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    provider_route = data["provider_route"]
    route_readiness = data["route_readiness"]
    review_quorum = data["review_quorum"]
    route_quorum = provider_route.get("review_quorum", {})
    readiness_quorum = route_readiness.get("review_quorum", {})

    required_reviewers = as_set(review_quorum.get("independent_review_required_slots"))
    optional_reviewers = as_set(review_quorum.get("independent_review_optional_slots"))
    check(required_reviewers == as_set(route_quorum.get("independent_review_required_slots")), failures, "route required reviewer slots diverge from quorum policy")
    check(optional_reviewers == as_set(route_quorum.get("independent_review_optional_slots")), failures, "route optional reviewer slots diverge from quorum policy")
    check(required_reviewers == as_set(readiness_quorum.get("required_independent_reviewers")), failures, "readiness required reviewer slots diverge from quorum policy")
    check(optional_reviewers == as_set(readiness_quorum.get("optional_candidates")), failures, "readiness optional reviewer slots diverge from quorum policy")
    check(review_quorum.get("optional_review_min_successes") == route_quorum.get("optional_review_min_successes"), failures, "route optional quorum minimum diverges")
    check(review_quorum.get("optional_review_min_successes") == readiness_quorum.get("optional_successes_required"), failures, "readiness optional quorum minimum diverges")
    check(strict_true(review_quorum.get("waiver_required_if_not_met")) == strict_true(readiness_quorum.get("waiver_required_if_not_met")), failures, "waiver requirement diverges")
    return failures


def invariant_synthesis_gates_avoid_circular_evidence_dependency(data: dict[str, Any]) -> list[str]:
    route_readiness = data["route_readiness"]
    failures: list[str] = []
    synthesis_blockers = as_set(route_readiness.get("synthesis_prompt_blocked_until_evidence_for"))
    final_blockers = as_set(route_readiness.get("final_handoff_blocked_until_evidence_for"))
    check("chatgpt_pro_synthesis" not in synthesis_blockers, failures, "synthesis prompt gate waits on its own future evidence")
    check("chatgpt_pro_synthesis" in final_blockers, failures, "final handoff gate must require synthesis evidence")
    check(BROWSER_SLOTS - {"chatgpt_pro_synthesis"} <= synthesis_blockers, failures, "synthesis prompt must wait for first-plan and Gemini evidence")
    check(strict_true(route_readiness.get("preflight_ready")), failures, "balanced readiness must be preflight-ready")
    check(strict_false(route_readiness.get("synthesis_ready")), failures, "balanced readiness must not mark synthesis ready pre-execution")
    return failures


def invariant_api_allowed_routes_have_runtime_budgets(data: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    provider_access = data["provider_access"]
    model_reasoning = data["model_reasoning"]
    runtime_budget = data["runtime_budget"]
    access_api_routes = as_set(provider_access.get("allowed_api_routes"))
    reasoning_api_routes = as_set(model_reasoning.get("api_allowed_routes"))
    budget_routes = set(runtime_budget.get("api_provider_budgets", {}).keys())
    search_budget_routes = set(runtime_budget.get("search_budget", {}).keys())
    check(access_api_routes == reasoning_api_routes, failures, f"API route lists diverge: access={sorted(access_api_routes)} reasoning={sorted(reasoning_api_routes)}")
    check(access_api_routes <= budget_routes, failures, f"API routes missing runtime budgets: {sorted(access_api_routes - budget_routes)}")
    check("deepseek_v4_pro_reasoning_search" in search_budget_routes, failures, "DeepSeek search route missing search budget")
    return failures


def invariant_protected_browser_slots_forbid_api_substitution(data: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    provider_access = data["provider_access"]
    model_reasoning = data["model_reasoning"]
    protected_slots = as_set(model_reasoning.get("protected_slots"))
    live_routes = provider_access.get("live_routes", {})
    check(BROWSER_SLOTS <= protected_slots, failures, f"model policy missing protected slots: {sorted(BROWSER_SLOTS - protected_slots)}")
    for slot in sorted(BROWSER_SLOTS):
        route = live_routes.get(slot, {})
        check(strict_false(route.get("api_allowed")), failures, f"{slot} unexpectedly allows API")
        check(strict_true(route.get("oracle_allowed")), failures, f"{slot} must allow Oracle/browser route")
        check(str(route.get("access_path", "")).startswith("oracle_browser"), failures, f"{slot} must use browser access path")
    return failures


def invariant_prompt_source_hashes_align(data: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    prompt_manifest = data["prompt_manifest"]
    prompt_context = data["prompt_context"]
    manifest_hashes = prompt_manifest.get("input_hashes", {})
    pairs = [
        ("source_baseline", "source_baseline_sha256"),
        ("source_trust", "source_trust_sha256"),
        ("prompt_policy", "prompt_policy_sha256"),
    ]
    for manifest_key, context_key in pairs:
        check(manifest_hashes.get(manifest_key) == prompt_context.get(context_key), failures, f"{manifest_key} hash diverges between prompt manifest and context packet")
    check(
        prompt_manifest.get("context_serialization_policy_sha256") == prompt_context.get("context_serialization_policy_sha256"),
        failures,
        "context serialization policy hash diverges between prompt manifest and context packet",
    )
    check(prompt_manifest.get("canonical_artifact_serialization") == "json", failures, "prompt manifest canonical artifact serialization must be json")
    check(prompt_context.get("canonical_artifact_serialization") == "json", failures, "prompt context canonical artifact serialization must be json")
    return failures


def invariant_source_trust_covers_baseline_sources(data: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    source_baseline = data["source_baseline"]
    source_trust = data["source_trust"]
    baseline_ids = {source.get("id") for source in source_baseline.get("sources", []) if isinstance(source.get("id"), str)}
    trust_ids = {source.get("id") for source in source_trust.get("sources", []) if isinstance(source.get("id"), str)}
    check(baseline_ids <= trust_ids, failures, f"source trust missing baseline ids: {sorted(baseline_ids - trust_ids)}")
    for entry in source_baseline.get("sources", []):
        if entry.get("source_class") == "provider_result_untrusted_text":
            trust_entry = next((source for source in source_trust.get("sources", []) if source.get("id") == entry.get("id")), {})
            check(trust_entry.get("trust_tier") == "untrusted_provider_text", failures, f"{entry.get('id')} must be untrusted provider text")
            check(trust_entry.get("instruction_policy") == "quarantine_provider_instructions", failures, f"{entry.get('id')} must quarantine provider instructions")
    return failures


def invariant_quarantine_propagates_to_prompt_context(data: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    source_trust = data["source_trust"]
    prompt_context = data["prompt_context"]
    quarantined_ids = {entry.get("source_id") for entry in source_trust.get("quarantined_instructions", []) if isinstance(entry.get("source_id"), str)}
    boundary = prompt_context.get("trusted_instruction_boundary", {})
    context_quarantined = as_set(boundary.get("quarantined_source_ids"))
    directive_sources = as_set(boundary.get("directive_sources"))
    check(quarantined_ids <= context_quarantined, failures, f"prompt context missing quarantined ids: {sorted(quarantined_ids - context_quarantined)}")
    check(strict_true(prompt_context.get("source_trust_quarantine_applied")), failures, "prompt context must mark source trust quarantine applied")
    check(strict_true(boundary.get("untrusted_provider_text_is_data_only")), failures, "prompt context must keep provider text data-only")
    check(not (directive_sources & quarantined_ids), failures, f"quarantined sources cannot be directive sources: {sorted(directive_sources & quarantined_ids)}")
    return failures


def invariant_json_canonical_storage_remains_pinned(data: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    context_serialization = data["context_serialization"]
    prompt_manifest = data["prompt_manifest"]
    prompt_context = data["prompt_context"]
    toon = context_serialization.get("toon_rust", {})
    check(context_serialization.get("canonical_storage_format") == "json", failures, "canonical storage format must be json")
    check(context_serialization.get("fallback_format") == "json", failures, "serialization fallback must be json")
    check(context_serialization.get("default_effective_format") == "json", failures, "default serialization format must be json")
    check(strict_true(context_serialization.get("legal_review_required")), failures, "serialization policy must require legal review")
    check(strict_false(toon.get("required")), failures, "TOON/tru must not be required")
    check(strict_false(toon.get("enabled_by_default")), failures, "TOON/tru must not be enabled by default")
    check(prompt_manifest.get("toon_payload_sha256_when_used") is None, failures, "TOON payload hash must be null when TOON is unused")
    check(prompt_context.get("context_serialization_fallback") == "json", failures, "prompt context fallback serialization must be json")
    check(strict_true(prompt_context.get("toon_rust_optional")), failures, "prompt context must mark TOON/tru optional")
    return failures


def invariant_deepseek_search_policy_matches_budget_and_prompting(data: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    provider_access = data["provider_access"]
    model_reasoning = data["model_reasoning"]
    runtime_budget = data["runtime_budget"]
    prompt_policy = data["prompt_policy"]
    route = provider_access.get("live_routes", {}).get("deepseek_v4_pro_reasoning_search", {})
    reasoning = model_reasoning.get("live_provider_effort_defaults", {}).get("deepseek_v4_pro_reasoning_search", {})
    budget = runtime_budget.get("api_provider_budgets", {}).get("deepseek_v4_pro_reasoning_search", {})
    prompt_rules = prompt_policy.get("policies", {}).get("deepseek_v4_pro_api", {})
    check(strict_true(route.get("official_api")), failures, "DeepSeek route must use official API")
    check(route.get("search_tool") == "apr_web_search", failures, "DeepSeek route must require APR web search tool")
    check(route.get("reasoning_effort") == "max", failures, "DeepSeek provider access must use max effort")
    check(reasoning.get("reasoning_effort") == "max", failures, "DeepSeek reasoning policy must use max effort")
    check(budget.get("max_reasoning_effort") == "max", failures, "DeepSeek budget must cap at max effort")
    check(route.get("reasoning_content_policy") == "transient_tool_replay_hash_only_persisted", failures, "DeepSeek route must persist only reasoning hash")
    forbidden = " ".join(prompt_rules.get("forbidden", []))
    check("Storing raw reasoning_content" in forbidden, failures, "DeepSeek prompt policy must forbid raw reasoning_content persistence")
    return failures


INVARIANTS = {
    "api_allowed_routes_have_runtime_budgets": invariant_api_allowed_routes_have_runtime_budgets,
    "browser_slots_require_verified_evidence": invariant_browser_slots_require_verified_evidence,
    "deepseek_search_policy_matches_budget_and_prompting": invariant_deepseek_search_policy_matches_budget_and_prompting,
    "json_canonical_storage_remains_pinned": invariant_json_canonical_storage_remains_pinned,
    "prompt_source_hashes_align": invariant_prompt_source_hashes_align,
    "protected_browser_slots_forbid_api_substitution": invariant_protected_browser_slots_forbid_api_substitution,
    "quarantine_propagates_to_prompt_context": invariant_quarantine_propagates_to_prompt_context,
    "quorum_policy_matches_route_and_readiness": invariant_quorum_policy_matches_route_and_readiness,
    "route_slots_covered_by_policy": invariant_route_slots_covered_by_policy,
    "source_trust_covers_baseline_sources": invariant_source_trust_covers_baseline_sources,
    "stage_slot_sets_match_route_declarations": invariant_stage_slot_sets_match_route_declarations,
    "synthesis_gates_avoid_circular_evidence_dependency": invariant_synthesis_gates_avoid_circular_evidence_dependency,
}


def validate_schema_case(root: Path, validator_cls: Any, case: dict[str, Any]) -> tuple[dict[str, Any], dict[str, str] | None]:
    schema_path = root / case["schema"]
    fixture_path = root / case["fixture"]
    result = {
        "case_id": case["case_id"],
        "fixture": case["fixture"],
        "requirement": case["requirement"],
        "schema": case["schema"],
        "status": "unknown",
    }
    try:
        schema = load_json(schema_path)
        fixture = load_json(fixture_path)
    except Exception as exc:
        result["status"] = "fail"
        return result, {"error_code": "json_load_failed", "message": f"{case['case_id']}: {exc}"}

    result["fixture_sha256"] = sha256_text(fixture_path.read_text(encoding="utf-8"))
    try:
        validator_cls.check_schema(schema)
        validator_cls(schema).validate(fixture)
    except Exception as exc:
        result["status"] = "fail"
        return result, {
            "error_code": "schema_validation_failed",
            "message": f"{case['case_id']}: {validation_error_message(exc)}",
        }

    result["status"] = "pass"
    return result, None


def load_fixture_set(root: Path) -> tuple[dict[str, Any], list[dict[str, str]]]:
    loaded: dict[str, Any] = {}
    errors: list[dict[str, str]] = []
    for key, rel_path in FIXTURES.items():
        try:
            loaded[key] = load_json(root / rel_path)
        except Exception as exc:
            errors.append({"error_code": "fixture_load_failed", "message": f"{rel_path}: {exc}"})
    return loaded, errors


def run_invariant_case(data: dict[str, Any], case: dict[str, Any]) -> tuple[dict[str, Any], dict[str, str] | None]:
    case_id = case["case_id"]
    result = {
        "area": case["area"],
        "case_id": case_id,
        "description": case["description"],
        "requirement_level": case["requirement_level"],
        "status": "unknown",
    }
    fn = INVARIANTS.get(case_id)
    if fn is None:
        result["status"] = "fail"
        return result, {"error_code": "unknown_invariant_case", "message": f"{case_id}: no invariant implementation"}
    failures = fn(data)
    if failures:
        result["status"] = "fail"
        result["failures"] = failures
        return result, {"error_code": "invariant_failed", "message": f"{case_id}: " + "; ".join(failures)}
    result["status"] = "pass"
    return result, None


def envelope(ok: bool, data: dict[str, Any], errors: list[dict[str, str]], warnings: list[str]) -> dict[str, Any]:
    return {
        "blocked_reason": None if ok else "schema_cross_invariant_conformance_failed",
        "commands": {
            "next": "python3 scripts/schema-cross-invariant-conformance.py --json",
        },
        "data": data,
        "errors": errors,
        "fix_command": None if ok else "fix listed schema fixture or cross-schema invariant",
        "meta": {
            "bundle_version": VERSION,
            "tool": "schema-cross-invariant-conformance",
        },
        "ok": ok,
        "retry_safe": True,
        "schema_version": ENVELOPE_VERSION,
        "warnings": warnings,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate v18 schemas and cross-schema route/source/prompt invariants."
    )
    parser.add_argument("--json", action="store_true", help="Emit standard robot JSON envelope.")
    parser.add_argument(
        "--root",
        default=str(Path(__file__).resolve().parents[1]),
        help="Bundle root directory. Defaults to the parent of this script directory.",
    )
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()
    errors: list[dict[str, str]] = []
    warnings: list[str] = []

    try:
        from jsonschema import Draft202012Validator
    except ImportError:
        output = envelope(
            False,
            {"checked_root": str(root), "cases": [], "coverage": {"score": 0}},
            [{"error_code": "jsonschema_unavailable", "message": "python jsonschema package is required"}],
            warnings,
        )
        print(json.dumps(output, indent=2, sort_keys=True) if args.json else output["errors"][0]["message"])
        return 1

    try:
        case_matrix = load_json(root / CASES_PATH)
    except Exception as exc:
        output = envelope(
            False,
            {"checked_root": str(root), "cases": [], "coverage": {"score": 0}},
            [{"error_code": "case_matrix_load_failed", "message": str(exc)}],
            warnings,
        )
        print(json.dumps(output, indent=2, sort_keys=True) if args.json else output["errors"][0]["message"])
        return 1

    data, load_errors = load_fixture_set(root)
    errors.extend(load_errors)

    schema_results: list[dict[str, Any]] = []
    for case in case_matrix.get("schema_cases", []):
        result, error = validate_schema_case(root, Draft202012Validator, case)
        schema_results.append(result)
        if error is not None:
            errors.append(error)

    invariant_results: list[dict[str, Any]] = []
    if not load_errors:
        for case in case_matrix.get("invariant_cases", []):
            result, error = run_invariant_case(data, case)
            invariant_results.append(result)
            if error is not None:
                errors.append(error)

    all_results = schema_results + invariant_results
    passing = sum(1 for result in all_results if result.get("status") == "pass")
    must_total = len(all_results)
    coverage = {
        "divergent": 0,
        "must_clauses": must_total,
        "passing": passing,
        "score": passing / must_total if must_total else 0,
        "should_clauses": 0,
        "tested": must_total,
    }
    output = envelope(
        not errors,
        {
            "bundle_version": VERSION,
            "case_matrix": CASES_PATH,
            "checked_root": str(root),
            "coverage": coverage,
            "invariant_cases": invariant_results,
            "schema_cases": schema_results,
        },
        errors,
        warnings,
    )
    if args.json:
        print(json.dumps(output, indent=2, sort_keys=True))
    elif errors:
        print("\n".join(error["message"] for error in errors))
    else:
        print("ok")
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
