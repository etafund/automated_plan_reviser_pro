#!/usr/bin/env python3
"""Spec-derived negative/security regression harness for v18 fixtures."""

from __future__ import annotations

import argparse
import hashlib
import json
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any


VERSION = "v18.0.0"
ENVELOPE_VERSION = "json_envelope.v1"
BROWSER_ONLY_SLOTS = {
    "chatgpt_pro_first_plan",
    "chatgpt_pro_synthesis",
    "gemini_deep_think",
}
BROWSER_ACCESS_PATHS = {
    "oracle_browser_remote",
    "oracle_browser_local",
    "oracle_browser_remote_or_local",
}
RAW_REASONING_FIELDS = {
    "chain_of_thought",
    "raw_hidden_reasoning",
    "reasoning_content",
}
SECRET_OR_PRIVATE_FIELDS = RAW_REASONING_FIELDS | {
    "api_keys",
    "browser_cookies",
    "cookies",
    "oauth_tokens",
    "private_prompt_body",
    "unredacted_dom",
    "unredacted_screenshot",
}


def envelope(
    ok: bool,
    data: dict[str, Any],
    errors: list[dict[str, str]],
    warnings: list[str] | None = None,
) -> dict[str, Any]:
    return {
        "ok": ok,
        "schema_version": ENVELOPE_VERSION,
        "data": data,
        "meta": {"tool": "negative-security-regression", "bundle_version": VERSION},
        "warnings": warnings or [],
        "errors": errors,
        "commands": {
            "next": "python3 scripts/negative-security-regression.py --json",
            "single_scenario": "python3 scripts/negative-security-regression.py --json --scenario <scenario_id>",
        },
        "blocked_reason": None if ok else "negative_security_regression_failed",
        "next_command": None if ok else "python3 scripts/negative-security-regression.py --json",
        "fix_command": None if ok else "fix the scenario that did not fail closed",
        "retry_safe": True,
    }


def load_json(path: Path) -> dict[str, Any]:
    try:
        loaded = json.JSONDecoder().decode(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"{path}: failed to load JSON: {exc}") from exc
    if not isinstance(loaded, dict):
        raise RuntimeError(f"{path}: expected JSON object")
    return loaded


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return "sha256:" + digest.hexdigest()


def timestamp() -> str:
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())


def exact_true(value: object) -> bool:
    return isinstance(value, bool) and value


def exact_false(value: object) -> bool:
    return isinstance(value, bool) and not value


def find_field_paths(value: Any, forbidden: set[str], prefix: str = "$") -> list[str]:
    hits: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            path = f"{prefix}.{key}"
            if key in forbidden:
                hits.append(path)
            hits.extend(find_field_paths(child, forbidden, path))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            hits.extend(find_field_paths(child, forbidden, f"{prefix}[{index}]"))
    return hits


def verdict(error_code: str | None, message: str, redaction_findings: list[str] | None = None) -> dict[str, Any]:
    return {
        "decision": "rejected" if error_code else "accepted",
        "error_code": error_code,
        "message": message,
        "redaction_findings": redaction_findings or [],
    }


def check_api_substitution(obj: dict[str, Any]) -> dict[str, Any]:
    slot = obj.get("provider_slot")
    access_path = obj.get("access_path")
    if slot in BROWSER_ONLY_SLOTS and access_path not in BROWSER_ACCESS_PATHS:
        return verdict(
            "api_substitution_prohibited",
            f"{slot} must use browser-backed Oracle evidence, not {access_path}",
        )
    return verdict(None, "provider result did not violate browser-only access policy")


def check_codex_formal_plan(obj: dict[str, Any]) -> dict[str, Any]:
    if exact_true(obj.get("formal_first_plan")) or exact_true(obj.get("eligible_for_synthesis")):
        return verdict(
            "codex_formal_plan_misuse",
            "Codex intake cannot satisfy formal first-plan or synthesis eligibility gates",
        )
    return verdict(None, "Codex intake is not claiming formal plan status")


def check_browser_evidence(obj: dict[str, Any]) -> dict[str, Any]:
    failures = []
    field_hits = find_field_paths(obj, SECRET_OR_PRIVATE_FIELDS)
    if not exact_true(obj.get("mode_verified")):
        failures.append("mode_verified")
    if not exact_true(obj.get("verified_before_prompt_submit")):
        failures.append("verified_before_prompt_submit")
    if obj.get("capture_confidence") != "high":
        failures.append("capture_confidence")
    if not exact_true(obj.get("reasoning_effort_verified")):
        failures.append("reasoning_effort_verified")
    if field_hits:
        failures.append("forbidden_browser_material")
    if failures:
        return verdict(
            "browser_evidence_unverified",
            "Browser evidence is not eligible: " + ", ".join(failures),
            field_hits,
        )
    return verdict(None, "browser evidence is verified")


def check_deepseek_search(obj: dict[str, Any]) -> dict[str, Any]:
    if obj.get("provider_slot") == "deepseek_v4_pro_reasoning_search" and (
        not exact_true(obj.get("search_enabled")) or not obj.get("search_trace_sha256")
    ):
        return verdict(
            "deepseek_search_trace_missing",
            "DeepSeek V4 Pro reasoning-search requires enabled search and a persisted trace hash",
        )
    return verdict(None, "DeepSeek search trace is present")


def check_raw_reasoning(obj: dict[str, Any]) -> dict[str, Any]:
    raw_hits = find_field_paths(obj, RAW_REASONING_FIELDS)
    unsafe_policy = obj.get("reasoning_content_policy") != "transient_tool_replay_hash_only_persisted"
    raw_stored = exact_true(obj.get("reasoning_content_stored"))
    if raw_hits or unsafe_policy or raw_stored:
        findings = raw_hits[:]
        if unsafe_policy:
            findings.append("$.reasoning_content_policy")
        if raw_stored:
            findings.append("$.reasoning_content_stored")
        return verdict(
            "raw_reasoning_persisted",
            "Provider result persists raw hidden reasoning or uses an unsafe reasoning policy",
            findings,
        )
    return verdict(None, "raw reasoning is not persisted")


def check_artifact_redaction(obj: dict[str, Any]) -> dict[str, Any]:
    boundary = obj.get("redaction_boundary", {})
    field_hits = find_field_paths(obj, SECRET_OR_PRIVATE_FIELDS)
    boundary_failures = []
    for key in ["private_browser_material_persisted", "raw_hidden_reasoning_persisted", "secret_material_persisted"]:
        if exact_true(boundary.get(key)):
            boundary_failures.append(f"$.redaction_boundary.{key}")
    unsafe_artifacts = [
        f"$.artifacts[{index}]"
        for index, artifact in enumerate(obj.get("artifacts", []))
        if artifact.get("redaction_level") in {"none", "raw"} or exact_false(artifact.get("atomic_write", {}).get("via_temp_rename"))
    ]
    findings = field_hits + boundary_failures + unsafe_artifacts
    if findings:
        return verdict(
            "artifact_redaction_boundary_broken",
            "Artifact index permits persisted private, secret, raw reasoning, or non-atomic artifacts",
            findings,
        )
    return verdict(None, "artifact redaction boundary is strict")


def check_source_quarantine(obj: dict[str, Any]) -> dict[str, Any]:
    unsafe_sources = []
    quarantined = obj.get("quarantined_instructions", [])
    for source in obj.get("sources", []):
        injection_detected = exact_true(source.get("prompt_injection_detected")) or exact_true(source.get("may_contain_instructions"))
        trusted_directive = source.get("instruction_policy") == "trusted_directive"
        trusted_tier = source.get("trust_tier") in {"authoritative_user_input", "runtime_instruction"}
        if injection_detected and (trusted_directive or trusted_tier):
            unsafe_sources.append(str(source.get("id", "<missing-id>")))
    if unsafe_sources or not quarantined:
        return verdict(
            "prompt_injection_not_quarantined",
            "Provider/user text with embedded instructions must be quarantined as data-only context",
            unsafe_sources,
        )
    return verdict(None, "prompt-injection-bearing sources are quarantined")


def check_toon_authoritative(obj: dict[str, Any]) -> dict[str, Any]:
    failures = []
    if obj.get("canonical_format") == "toon":
        failures.append("$.canonical_format")
    if obj.get("default_mode") == "toon":
        failures.append("$.default_mode")
    if "canonical_contracts" in obj.get("eligible_artifact_types", []):
        failures.append("$.eligible_artifact_types")
    if "browser_evidence" in obj.get("eligible_artifact_types", []):
        failures.append("$.eligible_artifact_types")
    if not exact_true(obj.get("roundtrip_validation_required")):
        failures.append("$.roundtrip_validation_required")
    if "canonical_artifact_storage_as_toon" not in obj.get("anti_patterns", []):
        failures.append("$.anti_patterns")
    if failures:
        return verdict(
            "toon_tru_authoritative_state",
            "TOON/tru may be model-facing compression only, never canonical contract or evidence state",
            failures,
        )
    return verdict(None, "TOON/tru is non-authoritative and roundtrip-gated")


def check_circular_synthesis(obj: dict[str, Any]) -> dict[str, Any]:
    blocked = set(obj.get("synthesis_blocked_until_evidence_for", []))
    stage_blocked = set(obj.get("stage_readiness", {}).get("synthesis", {}).get("blocked_until", []))
    if "chatgpt_pro_synthesis" in blocked or "verified_chatgpt_pro_synthesis_evidence" in stage_blocked:
        return verdict(
            "circular_synthesis_readiness",
            "Synthesis prompt submission cannot require ChatGPT synthesis evidence before synthesis runs",
        )
    return verdict(None, "synthesis readiness is not circular")


def check_synthesis_finalization(obj: dict[str, Any]) -> dict[str, Any]:
    quorum = obj.get("review_quorum_state", {})
    conformance = obj.get("conformance_matrix", [])
    quorum_bad = (
        quorum.get("state") not in {"met", "waived"}
        or not exact_true(quorum.get("required_independent_reviewers_satisfied"))
        or int(quorum.get("optional_successes_observed", 0)) < int(quorum.get("optional_successes_required", 0))
    )
    trace_bad = any(row.get("status") == "fail" for row in conformance)
    if quorum_bad or trace_bad:
        findings = []
        if quorum_bad:
            findings.append("$.review_quorum_state")
        if trace_bad:
            findings.append("$.conformance_matrix")
        return verdict(
            "synthesis_without_quorum_or_traceability",
            "Synthesis finalization requires review quorum and passing traceability coverage",
            findings,
        )
    return verdict(None, "synthesis finalization gates are satisfied")


CaseCheck = Callable[[dict[str, Any]], dict[str, Any]]

CASES: list[dict[str, Any]] = [
    {
        "scenario_id": "api_substitution_provider_result",
        "requirement_id": "NEG-MUST-API-SUBSTITUTION",
        "fixture": "fixtures/negative/api-substitution-provider-result.invalid.json",
        "expected_error_code": "api_substitution_prohibited",
        "blocked_reason": "provider_access_prohibited",
        "check": check_api_substitution,
    },
    {
        "scenario_id": "codex_formal_first_plan",
        "requirement_id": "NEG-MUST-CODEX-FORMAL",
        "fixture": "fixtures/negative/codex-intake-formal-plan.invalid.json",
        "expected_error_code": "codex_formal_plan_misuse",
        "blocked_reason": "source_trust_gate_failed",
        "check": check_codex_formal_plan,
    },
    {
        "scenario_id": "unverified_browser_evidence",
        "requirement_id": "NEG-MUST-BROWSER-EVIDENCE",
        "fixture": "fixtures/negative/unverified-browser-evidence.invalid.json",
        "expected_error_code": "browser_evidence_unverified",
        "blocked_reason": "browser_evidence_ineligible",
        "check": check_browser_evidence,
    },
    {
        "scenario_id": "deepseek_search_disabled",
        "requirement_id": "NEG-MUST-DEEPSEEK-SEARCH",
        "fixture": "fixtures/negative/deepseek-search-disabled.invalid.json",
        "expected_error_code": "deepseek_search_trace_missing",
        "blocked_reason": "provider_result_ineligible",
        "check": check_deepseek_search,
    },
    {
        "scenario_id": "deepseek_raw_reasoning_leak",
        "requirement_id": "NEG-MUST-RAW-REASONING",
        "fixture": "fixtures/negative/provider-adapter-deepseek-raw-reasoning.invalid.json",
        "expected_error_code": "raw_reasoning_persisted",
        "blocked_reason": "redaction_boundary_failed",
        "check": check_raw_reasoning,
    },
    {
        "scenario_id": "artifact_secret_leak",
        "requirement_id": "NEG-MUST-ARTIFACT-REDACTION",
        "fixture": "fixtures/negative/artifact-index-secret-leak.invalid.json",
        "expected_error_code": "artifact_redaction_boundary_broken",
        "blocked_reason": "artifact_redaction_boundary_failed",
        "check": check_artifact_redaction,
    },
    {
        "scenario_id": "source_provider_instruction",
        "requirement_id": "NEG-MUST-PROMPT-QUARANTINE",
        "fixture": "fixtures/negative/source-provider-instruction.invalid.json",
        "expected_error_code": "prompt_injection_not_quarantined",
        "blocked_reason": "source_trust_quarantine_failed",
        "check": check_source_quarantine,
    },
    {
        "scenario_id": "toon_authoritative_contract",
        "requirement_id": "NEG-MUST-TOON-NONCANONICAL",
        "fixture": "fixtures/negative/toon-as-authoritative-contract.invalid.json",
        "expected_error_code": "toon_tru_authoritative_state",
        "blocked_reason": "context_serialization_policy_failed",
        "check": check_toon_authoritative,
    },
    {
        "scenario_id": "route_readiness_circular_synthesis",
        "requirement_id": "NEG-MUST-NONCIRCULAR-SYNTHESIS",
        "fixture": "fixtures/negative/route-readiness-circular-synthesis.invalid.json",
        "expected_error_code": "circular_synthesis_readiness",
        "blocked_reason": "stage_readiness_circular",
        "check": check_circular_synthesis,
    },
    {
        "scenario_id": "synthesis_missing_traceability",
        "requirement_id": "NEG-MUST-SYNTHESIS-GATES",
        "fixture": "fixtures/negative/synthesis-missing-traceability.invalid.json",
        "expected_error_code": "synthesis_without_quorum_or_traceability",
        "blocked_reason": "synthesis_finalization_gate_failed",
        "check": check_synthesis_finalization,
    },
]


def case_by_id(scenario_id: str) -> dict[str, Any] | None:
    for case in CASES:
        if case["scenario_id"] == scenario_id:
            return case
    return None


def run_case(root: Path, log_dir: Path, case: dict[str, Any]) -> dict[str, Any]:
    fixture_rel = case["fixture"]
    fixture_path = root / fixture_rel
    scenario_id = case["scenario_id"]
    base = {
        "scenario_id": scenario_id,
        "requirement_id": case["requirement_id"],
        "fixture": fixture_rel,
        "expected_decision": "rejected",
        "expected_error_code": case["expected_error_code"],
        "expected_blocked_reason": case["blocked_reason"],
        "rerun_command": f"python3 scripts/negative-security-regression.py --json --scenario {scenario_id}",
        "status": "fail",
        "actual_decision": "accepted",
        "actual_error_code": None,
        "blocked_reason": None,
        "human_message": "",
        "fix_command": "fix the unsafe shortcut so it is rejected with the expected error code",
        "artifact_paths": {"fixture": fixture_rel},
        "redaction_findings": [],
    }

    try:
        fixture = load_json(fixture_path)
        check: CaseCheck = case["check"]
        decision = check(fixture)
    except RuntimeError as exc:
        decision = verdict("fixture_load_failed", str(exc))

    actual_error = decision["error_code"]
    actual_decision = decision["decision"]
    status = "pass" if actual_decision == "rejected" and actual_error == case["expected_error_code"] else "fail"
    base.update({
        "fixture_sha256": sha256_file(fixture_path) if fixture_path.exists() else None,
        "status": status,
        "actual_decision": actual_decision,
        "actual_error_code": actual_error,
        "blocked_reason": case["blocked_reason"] if actual_decision == "rejected" else None,
        "human_message": decision["message"],
        "redaction_findings": decision["redaction_findings"],
    })
    case_log = log_dir / "cases" / f"{scenario_id}.json"
    base["artifact_paths"]["case_log"] = case_log.as_posix()
    case_log.parent.mkdir(parents=True, exist_ok=True)
    case_log.write_text(json.dumps(base, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return base


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v18 negative/security regression fixture checks.")
    parser.add_argument("--json", action="store_true", help="Emit v18 JSON envelope.")
    parser.add_argument("--bundle-root", default=str(Path(__file__).resolve().parents[1]), help="Path to v18 bundle root.")
    parser.add_argument("--log-root", default="tests/logs/v18/negative", help="Root directory for negative regression logs.")
    parser.add_argument("--scenario", default="", help="Optional single scenario id to run.")
    args = parser.parse_args()

    root = Path(args.bundle_root).resolve()
    selected_cases = CASES
    errors: list[dict[str, str]] = []
    warnings: list[str] = []
    if args.scenario:
        selected = case_by_id(args.scenario)
        if selected is None:
            errors.append({"error_code": "unknown_scenario", "message": f"unknown scenario: {args.scenario}"})
            selected_cases = []
        else:
            selected_cases = [selected]

    log_dir = Path(args.log_root).resolve() / f"negative-security-{timestamp()}"
    log_dir.mkdir(parents=True, exist_ok=True)
    results = [run_case(root, log_dir, case) for case in selected_cases]
    for result in results:
        if result["status"] != "pass":
            errors.append({
                "error_code": "negative_scenario_not_rejected",
                "message": (
                    f"{result['scenario_id']}: expected {result['expected_error_code']}, "
                    f"got {result['actual_error_code']}"
                ),
            })

    passing = sum(1 for result in results if result["status"] == "pass")
    coverage = {
        "spec_section": "v18 negative/security gates",
        "must_clauses": len(selected_cases),
        "should_clauses": 0,
        "tested": len(results),
        "passing": passing,
        "divergent": 0,
        "score": passing / len(results) if results else 0,
    }
    data = {
        "bundle_version": VERSION,
        "checked_root": root.as_posix(),
        "log_bundle": log_dir.as_posix(),
        "case_count": len(results),
        "negative_rejected": passing,
        "coverage": coverage,
        "cases": results,
    }
    (log_dir / "negative-security-report.json").write_text(
        json.dumps(data, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    output = envelope(not errors, data, errors, warnings)
    print(json.dumps(output, indent=2, sort_keys=True) if args.json else ("ok" if not errors else "\n".join(e["message"] for e in errors)))
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
