#!/usr/bin/env python3
"""Round-trip conformance checks for selected v18 JSON contracts."""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

VERSION = "v18.0.0"
ENVELOPE_VERSION = "json_envelope.v1"


@dataclass(frozen=True)
class Case:
    case_id: str
    schema_path: str
    fixture_path: str
    expect_valid: bool
    requirement: str


CASES = [
    Case(
        "provider-result-valid-roundtrip",
        "contracts/provider-result.schema.json",
        "fixtures/conformance/provider-result.chatgpt.minimal.json",
        True,
        "provider-result fixture validates and survives canonical JSON round-trip",
    ),
    Case(
        "browser-evidence-valid-roundtrip",
        "contracts/browser-evidence.schema.json",
        "fixtures/conformance/browser-evidence.chatgpt.minimal.json",
        True,
        "browser-evidence fixture validates and survives canonical JSON round-trip",
    ),
    Case(
        "run-progress-valid-roundtrip",
        "contracts/run-progress.schema.json",
        "fixtures/conformance/run-progress.preflight.minimal.json",
        True,
        "run-progress fixture validates and survives canonical JSON round-trip",
    ),
    Case(
        "provider-result-rejects-raw-reasoning",
        "contracts/provider-result.schema.json",
        "fixtures/conformance/negative/provider-result-raw-reasoning.invalid.json",
        False,
        "provider-result rejects persisted hidden reasoning fields",
    ),
    Case(
        "browser-evidence-rejects-raw-dom",
        "contracts/browser-evidence.schema.json",
        "fixtures/conformance/negative/browser-evidence-raw-dom.invalid.json",
        False,
        "browser-evidence rejects raw browser artifacts",
    ),
    Case(
        "run-progress-rejects-missing-required",
        "contracts/run-progress.schema.json",
        "fixtures/conformance/negative/run-progress-missing-required.invalid.json",
        False,
        "run-progress rejects missing required retry safety",
    ),
]


def sha256_text(value: str) -> str:
    return "sha256:" + hashlib.sha256(value.encode("utf-8")).hexdigest()


def load_json(path: Path) -> Any:
    text = path.read_text(encoding="utf-8")
    try:
        return json.JSONDecoder().decode(text)
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path}: invalid JSON: {exc}") from exc


def canonical_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def envelope(ok: bool, data: dict[str, Any], errors: list[dict[str, str]], warnings: list[str]) -> dict[str, Any]:
    return {
        "ok": ok,
        "schema_version": ENVELOPE_VERSION,
        "data": data,
        "meta": {
            "tool": "schema-roundtrip-conformance",
            "bundle_version": VERSION,
        },
        "warnings": warnings,
        "errors": errors,
        "commands": {
            "next": "python3 scripts/schema-roundtrip-conformance.py --json",
        },
        "blocked_reason": None if ok else "schema_roundtrip_conformance_failed",
        "fix_command": None if ok else "fix listed schema, fixture, or round-trip failure",
        "retry_safe": True,
    }


def validation_error_message(exc: Exception) -> str:
    path = ".".join(str(part) for part in getattr(exc, "absolute_path", []))
    base = getattr(exc, "message", str(exc))
    return f"{path}: {base}" if path else base


def run_case(root: Path, validator_cls: Any, case: Case) -> tuple[dict[str, Any], dict[str, str] | None]:
    schema_file = root / case.schema_path
    fixture_file = root / case.fixture_path
    result: dict[str, Any] = {
        "case_id": case.case_id,
        "schema": case.schema_path,
        "fixture": case.fixture_path,
        "expect_valid": case.expect_valid,
        "requirement": case.requirement,
        "status": "unknown",
    }

    try:
        schema = load_json(schema_file)
        fixture = load_json(fixture_file)
    except Exception as exc:
        result["status"] = "fail"
        return result, {"error_code": "json_load_failed", "message": f"{case.case_id}: {exc}"}

    raw_text = fixture_file.read_text(encoding="utf-8")
    result["fixture_sha256"] = sha256_text(raw_text)

    try:
        validator_cls.check_schema(schema)
    except Exception as exc:
        result["status"] = "fail"
        return result, {
            "error_code": "schema_invalid",
            "message": f"{case.case_id}: schema {case.schema_path} is invalid: {exc}",
        }

    try:
        validator = validator_cls(schema)
        validator.validate(fixture)
        validation_error = None
    except Exception as exc:
        validation_error = validation_error_message(exc)

    if validation_error is not None:
        result["validation_error"] = validation_error
        if case.expect_valid:
            result["status"] = "fail"
            return result, {
                "error_code": "fixture_validation_failed",
                "message": f"{case.case_id}: expected valid fixture, got {validation_error}",
            }
        result["status"] = "pass"
        result["negative_rejected"] = True
        return result, None

    if not case.expect_valid:
        result["status"] = "fail"
        return result, {
            "error_code": "negative_fixture_accepted",
            "message": f"{case.case_id}: expected schema rejection but fixture validated",
        }

    first = canonical_json(fixture)
    try:
        reparsed = json.JSONDecoder().decode(first)
    except json.JSONDecodeError as exc:
        result["status"] = "fail"
        return result, {
            "error_code": "canonical_json_parse_failed",
            "message": f"{case.case_id}: canonical JSON failed to parse: {exc}",
        }
    second = canonical_json(reparsed)
    result["canonical_sha256"] = sha256_text(first)
    result["roundtrip_sha256"] = sha256_text(second)
    result["semantic_identity"] = fixture == reparsed
    result["canonical_stable"] = first == second

    if fixture != reparsed or first != second:
        result["status"] = "fail"
        return result, {
            "error_code": "roundtrip_identity_failed",
            "message": f"{case.case_id}: canonical JSON round-trip changed semantic content",
        }

    result["status"] = "pass"
    return result, None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate selected v18 schemas and prove canonical JSON round-trip identity."
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
    results: list[dict[str, Any]] = []

    try:
        from jsonschema import Draft202012Validator
    except ImportError:
        output = envelope(
            False,
            {"checked_root": str(root), "case_count": len(CASES), "cases": []},
            [
                {
                    "error_code": "jsonschema_unavailable",
                    "message": "python jsonschema package is required for conformance validation",
                }
            ],
            warnings,
        )
        print(json.dumps(output, indent=2, sort_keys=True) if args.json else output["errors"][0]["message"])
        return 1

    for case in CASES:
        result, error = run_case(root, Draft202012Validator, case)
        results.append(result)
        if error is not None:
            errors.append(error)

    coverage = {
        "must_clauses": 6,
        "should_clauses": 0,
        "tested": len(CASES),
        "passing": sum(1 for result in results if result.get("status") == "pass"),
        "divergent": 0,
        "score": sum(1 for result in results if result.get("status") == "pass") / len(CASES),
    }
    data = {
        "checked_root": str(root),
        "bundle_version": VERSION,
        "case_count": len(CASES),
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
    raise SystemExit(main(sys.argv[1:]))
