#!/usr/bin/env python3
"""Validate v18 browser evidence linkage across lease/session/result artifacts."""
from __future__ import annotations

import argparse
import hashlib
import json
from copy import deepcopy
from pathlib import Path
from typing import Any

VERSION = "v18.0.0"
ENVELOPE_VERSION = "json_envelope.v1"
FORBIDDEN_FIELDS = {
    "browser_auth",
    "browser_auth_material",
    "cookies",
    "private_prompt_body",
    "raw_dom",
    "screenshots",
}
EXPECTED_BY_SLOT = {
    "chatgpt_pro_first_plan": {
        "provider": "chatgpt",
        "provider_family": "chatgpt",
        "reasoning_effort": "max_browser_available",
        "selector_manifest_version": "chatgpt-pro-v1",
    },
    "chatgpt_pro_synthesis": {
        "provider": "chatgpt",
        "provider_family": "chatgpt",
        "reasoning_effort": "max_browser_available",
        "selector_manifest_version": "chatgpt-pro-v1",
    },
    "gemini_deep_think": {
        "provider": "gemini",
        "provider_family": "gemini",
        "reasoning_effort": "deep_think_highest_available",
        "selector_manifest_version": "gemini-deep-think-v1",
    },
}


def sha256_text(value: str) -> str:
    return "sha256:" + hashlib.sha256(value.encode("utf-8")).hexdigest()


def load_json(path: Path) -> Any:
    text = path.read_text(encoding="utf-8")
    try:
        return json.JSONDecoder().decode(text)
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path}: invalid JSON: {exc}") from exc


def find_forbidden_fields(value: Any, prefix: str = "$") -> list[str]:
    hits: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f"{prefix}.{key}"
            if key in FORBIDDEN_FIELDS:
                hits.append(child_path)
            hits.extend(find_forbidden_fields(child, child_path))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            hits.extend(find_forbidden_fields(child, f"{prefix}[{index}]"))
    return hits


def strict_true(value: object) -> bool:
    return isinstance(value, bool) and value


def validate_schema(validator_cls: Any, schema: dict[str, Any], value: Any, label: str) -> list[str]:
    try:
        validator_cls(schema).validate(value)
    except Exception as exc:
        path = ".".join(str(part) for part in getattr(exc, "absolute_path", []))
        message = getattr(exc, "message", str(exc))
        return [f"{label}: {path + ': ' if path else ''}{message}"]
    return []


def provider_lock_present(session: dict[str, Any], provider: str, lock_name: str) -> bool:
    for entry in session.get("provider_locks", []):
        if entry.get("provider") == provider and entry.get("lock") == lock_name:
            return True
    return False


def expand_cases(raw_cases: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    expanded: list[dict[str, Any]] = []
    by_id: dict[str, dict[str, Any]] = {}
    errors: list[dict[str, str]] = []
    for raw_case in raw_cases:
        case_id = raw_case.get("case_id", "<missing>")
        if "extends" in raw_case:
            base_id = raw_case["extends"]
            if base_id not in by_id:
                errors.append({
                    "error_code": "case_base_missing",
                    "message": f"{case_id}: base case not found: {base_id}",
                })
                continue
            case = deepcopy(by_id[base_id])
            case["case_id"] = case_id
            case["extends"] = base_id
            case["expected_decision"] = raw_case.get("expected_decision")
            case["expected_reason_code"] = raw_case.get("expected_reason_code")
            for artifact_name in ["lease", "session", "evidence", "provider_result"]:
                patch = raw_case.get(f"{artifact_name}_patch")
                if patch:
                    case[artifact_name].update(patch)
        else:
            case = deepcopy(raw_case)
        expanded.append(case)
        by_id[case_id] = case
    return expanded, errors


def decide(case: dict[str, Any]) -> tuple[str, str | None, list[str]]:
    slot = case.get("provider_slot")
    expected = EXPECTED_BY_SLOT.get(slot)
    logs: list[str] = []
    if expected is None:
        return "rejected", "unsupported_provider_slot", logs

    lease = case["lease"]
    session = case["session"]
    evidence = case["evidence"]
    result = case["provider_result"]
    logs.append(
        "route_id={route_id} lease_id={lease_id} session_id={session_id} "
        "evidence_id={evidence_id} selector_manifest={selector_manifest} "
        "confidence={confidence} prompt_hash={prompt_hash} redaction={redaction}".format(
            route_id=case.get("route_id"),
            lease_id=lease.get("lease_id"),
            session_id=session.get("session_id"),
            evidence_id=evidence.get("evidence_id"),
            selector_manifest=evidence.get("selector_manifest_version"),
            confidence=evidence.get("capture_confidence"),
            prompt_hash=evidence.get("prompt_sha256"),
            redaction=evidence.get("redaction_policy"),
        )
    )

    checks = [
        (lease.get("status") == "acquired", "browser_lease_not_acquired"),
        (session.get("status") == "ready", "browser_session_not_ready"),
        (
            provider_lock_present(session, expected["provider"], lease.get("lock_name", "")),
            "provider_lock_missing",
        ),
        (lease.get("provider") == expected["provider"], "lease_provider_mismatch"),
        (evidence.get("provider") == expected["provider"], "evidence_provider_mismatch"),
        (result.get("provider_family") == expected["provider_family"], "result_provider_mismatch"),
        (evidence.get("provider_slot") == slot, "evidence_slot_mismatch"),
        (result.get("provider_slot") == slot, "result_slot_mismatch"),
        (result.get("evidence_id") == evidence.get("evidence_id"), "evidence_id_mismatch"),
        (result.get("provider_result_id") == evidence.get("provider_result_id"), "provider_result_id_mismatch"),
        (strict_true(evidence.get("mode_verified")), "mode_not_verified"),
        (strict_true(evidence.get("verified_before_prompt_submit")), "not_verified_before_prompt_submit"),
        (strict_true(evidence.get("reasoning_effort_verified")), "reasoning_effort_not_verified"),
        (evidence.get("capture_confidence") == "high", "capture_confidence_not_high"),
        (evidence.get("selector_manifest_version") == expected["selector_manifest_version"], "selector_manifest_stale"),
        (evidence.get("requested_reasoning_effort") == expected["reasoning_effort"], "evidence_effort_mismatch"),
        (result.get("reasoning_effort") == expected["reasoning_effort"], "result_effort_mismatch"),
        (strict_true(evidence.get("selected_effort_is_highest_visible")), "highest_visible_not_selected"),
        (evidence.get("redaction_policy") == "redacted", "redaction_policy_not_redacted"),
        (strict_true(evidence.get("unsafe_artifacts_quarantined")), "unsafe_artifacts_not_quarantined"),
        (result.get("result_text_sha256") == evidence.get("output_text_sha256"), "output_hash_mismatch"),
        (
            result.get("access_path")
            in {"oracle_browser_remote", "oracle_browser_local", "oracle_browser_remote_or_local"},
            "result_not_browser_backed",
        ),
    ]
    for passed, reason in checks:
        if not passed:
            return "rejected", reason, logs

    forbidden_hits = find_forbidden_fields(case)
    if forbidden_hits:
        logs.append("forbidden_fields=" + ",".join(forbidden_hits))
        return "rejected", "forbidden_browser_material_persisted", logs

    return "accepted", None, logs


def envelope(ok: bool, data: dict[str, Any], errors: list[dict[str, str]], warnings: list[str]) -> dict[str, Any]:
    return {
        "ok": ok,
        "schema_version": ENVELOPE_VERSION,
        "data": data,
        "meta": {
            "tool": "browser-evidence-link-check",
            "bundle_version": VERSION,
        },
        "warnings": warnings,
        "errors": errors,
        "commands": {
            "next": "python3 scripts/browser-evidence-link-check.py --json",
        },
        "blocked_reason": None if ok else "browser_evidence_link_check_failed",
        "fix_command": None if ok else "fix listed browser evidence linkage failure",
        "retry_safe": True,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Check browser evidence linkage invariants.")
    parser.add_argument("--json", action="store_true", help="Emit standard robot JSON envelope.")
    parser.add_argument(
        "--root",
        default=str(Path(__file__).resolve().parents[1]),
        help="Bundle root. Defaults to the parent of this script directory.",
    )
    parser.add_argument(
        "--cases",
        default="fixtures/conformance/browser-evidence-linkage-cases.json",
        help="Case fixture path relative to the bundle root.",
    )
    args = parser.parse_args()

    root = Path(args.root).resolve()
    warnings: list[str] = []
    errors: list[dict[str, str]] = []
    results: list[dict[str, Any]] = []

    try:
        from jsonschema import Draft202012Validator
    except ImportError:
        errors.append({
            "error_code": "jsonschema_unavailable",
            "message": "python jsonschema package is required",
        })
        output = envelope(False, {"checked_root": str(root), "cases": []}, errors, warnings)
        print(json.dumps(output, indent=2, sort_keys=True) if args.json else errors[0]["message"])
        return 1

    fixture_path = root / args.cases
    try:
        fixture = load_json(fixture_path)
        schemas = {
            "lease": load_json(root / "contracts/browser-lease.schema.json"),
            "session": load_json(root / "contracts/browser-session.schema.json"),
            "evidence": load_json(root / "contracts/browser-evidence.schema.json"),
            "provider_result": load_json(root / "contracts/provider-result.schema.json"),
        }
    except Exception as exc:
        errors.append({"error_code": "json_load_failed", "message": str(exc)})
        output = envelope(False, {"checked_root": str(root), "cases": []}, errors, warnings)
        print(json.dumps(output, indent=2, sort_keys=True) if args.json else errors[0]["message"])
        return 1

    for schema_name, schema in schemas.items():
        try:
            Draft202012Validator.check_schema(schema)
        except Exception as exc:
            errors.append({
                "error_code": "schema_invalid",
                "message": f"{schema_name} schema is invalid: {exc}",
            })

    cases, expansion_errors = expand_cases(fixture.get("cases", []))
    errors.extend(expansion_errors)

    for case in cases:
        case_id = case.get("case_id", "<missing>")
        case_errors: list[str] = []
        for field, schema in schemas.items():
            case_errors.extend(validate_schema(Draft202012Validator, schema, case.get(field), f"{case_id}.{field}"))
        actual_decision, reason_code, logs = decide(case)
        expected_decision = case.get("expected_decision")
        expected_reason_code = case.get("expected_reason_code")
        status = "pass"
        if case_errors:
            status = "fail"
            errors.extend({"error_code": "schema_validation_failed", "message": item} for item in case_errors)
        elif actual_decision != expected_decision or reason_code != expected_reason_code:
            status = "fail"
            errors.append({
                "error_code": "decision_mismatch",
                "message": (
                    f"{case_id}: expected {expected_decision}/{expected_reason_code}, "
                    f"got {actual_decision}/{reason_code}"
                ),
            })
        results.append({
            "case_id": case_id,
            "provider_slot": case.get("provider_slot"),
            "expected_decision": expected_decision,
            "actual_decision": actual_decision,
            "expected_reason_code": expected_reason_code,
            "actual_reason_code": reason_code,
            "status": status,
            "logs": logs,
        })

    passing = sum(1 for result in results if result["status"] == "pass")
    coverage = {
        "must_clauses": 6,
        "should_clauses": 0,
        "tested": len(results),
        "passing": passing,
        "divergent": 0,
        "score": passing / len(results) if results else 0,
    }
    data = {
        "checked_root": str(root),
        "fixture": str(fixture_path),
        "fixture_sha256": sha256_text(fixture_path.read_text(encoding="utf-8")),
        "case_count": len(results),
        "coverage": coverage,
        "cases": results,
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
