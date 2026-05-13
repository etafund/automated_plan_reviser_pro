#!/usr/bin/env python3
"""Corpus-level conformance checks for v18 JSON schemas and fixtures."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

VERSION = "v18.0.0"
ENVELOPE_VERSION = "json_envelope.v1"
EXEMPTIONS_PATH = "fixtures/conformance/schema-corpus-exemptions.json"
SKIPPED_FIXTURE_NAMES = {
    "browser-evidence-linkage-cases.json",
    "schema-corpus-exemptions.json",
    "schema-cross-invariant-cases.json",
}


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


def validation_error_message(exc: Exception) -> str:
    path = ".".join(str(part) for part in getattr(exc, "absolute_path", []))
    base = getattr(exc, "message", str(exc))
    return f"{path}: {base}" if path else base


def is_negative_fixture(root: Path, path: Path) -> bool:
    rel_parts = path.relative_to(root).parts
    return "negative" in rel_parts or path.name.endswith(".invalid.json")


def fixture_should_skip(path: Path) -> bool:
    return path.name in SKIPPED_FIXTURE_NAMES


def envelope(ok: bool, data: dict[str, Any], errors: list[dict[str, str]], warnings: list[str]) -> dict[str, Any]:
    return {
        "blocked_reason": None if ok else "schema_corpus_conformance_failed",
        "commands": {
            "next": "python3 scripts/schema-corpus-conformance.py --json",
        },
        "data": data,
        "errors": errors,
        "fix_command": None if ok else "fix listed schema, fixture, or exemption mismatch",
        "meta": {
            "bundle_version": VERSION,
            "tool": "schema-corpus-conformance",
        },
        "ok": ok,
        "retry_safe": True,
        "schema_version": ENVELOPE_VERSION,
        "warnings": warnings,
    }


def load_exemptions(root: Path) -> tuple[set[tuple[str, str]], list[dict[str, Any]], list[dict[str, str]]]:
    path = root / EXEMPTIONS_PATH
    errors: list[dict[str, str]] = []
    try:
        raw = load_json(path)
    except Exception as exc:
        return set(), [], [{"error_code": "exemptions_load_failed", "message": str(exc)}]

    exemptions: set[tuple[str, str]] = set()
    results: list[dict[str, Any]] = []
    for entry in raw.get("exemptions", []):
        fixture = entry.get("fixture")
        schema_version = entry.get("schema_version")
        reason = entry.get("reason")
        status = "pass" if fixture and schema_version and reason else "fail"
        result = {
            "fixture": fixture,
            "reason": reason,
            "schema_version": schema_version,
            "status": status,
        }
        if status == "pass":
            exemptions.add((fixture, schema_version))
        else:
            errors.append({
                "error_code": "invalid_exemption_entry",
                "message": f"{EXEMPTIONS_PATH}: exemption entries require fixture, schema_version, and reason",
            })
        results.append(result)
    return exemptions, results, errors


def collect_schema_cases(root: Path, validator_cls: Any) -> tuple[dict[str, Path], list[dict[str, Any]], list[dict[str, str]]]:
    schema_by_version: dict[str, Path] = {}
    results: list[dict[str, Any]] = []
    errors: list[dict[str, str]] = []

    for schema_path in sorted((root / "contracts").glob("*.schema.json")):
        rel = relative(root, schema_path)
        result: dict[str, Any] = {
            "schema": rel,
            "status": "unknown",
        }
        try:
            schema = load_json(schema_path)
            validator_cls.check_schema(schema)
        except Exception as exc:
            result["status"] = "fail"
            result["validation_error"] = validation_error_message(exc)
            errors.append({"error_code": "schema_invalid", "message": f"{rel}: {validation_error_message(exc)}"})
            results.append(result)
            continue

        schema_version = schema.get("properties", {}).get("schema_version", {}).get("const")
        result["schema_version"] = schema_version
        result["schema_sha256"] = sha256_text(schema_path.read_text(encoding="utf-8"))
        if not isinstance(schema_version, str):
            result["status"] = "fail"
            errors.append({"error_code": "schema_version_missing", "message": f"{rel}: missing properties.schema_version.const"})
        elif schema_version in schema_by_version:
            result["status"] = "fail"
            other = relative(root, schema_by_version[schema_version])
            errors.append({"error_code": "schema_version_duplicate", "message": f"{rel}: duplicates {schema_version} from {other}"})
        elif schema.get("x-bundle-version") != VERSION:
            result["status"] = "fail"
            errors.append({"error_code": "schema_bundle_version_mismatch", "message": f"{rel}: x-bundle-version must be {VERSION}"})
        else:
            result["status"] = "pass"
            schema_by_version[schema_version] = schema_path
        results.append(result)

    return schema_by_version, results, errors


def validate_fixture_case(
    root: Path,
    validator_cls: Any,
    fixture_path: Path,
    schema_by_version: dict[str, Path],
    exemptions: set[tuple[str, str]],
) -> tuple[dict[str, Any], dict[str, str] | None]:
    rel = relative(root, fixture_path)
    result: dict[str, Any] = {
        "expect_valid": not is_negative_fixture(root, fixture_path),
        "fixture": rel,
        "fixture_sha256": sha256_text(fixture_path.read_text(encoding="utf-8")),
        "status": "unknown",
    }
    try:
        fixture = load_json(fixture_path)
    except Exception as exc:
        result["status"] = "fail"
        return result, {"error_code": "fixture_json_invalid", "message": f"{rel}: {exc}"}

    schema_version = fixture.get("schema_version")
    result["schema_version"] = schema_version
    if not isinstance(schema_version, str):
        result["status"] = "fail"
        return result, {"error_code": "fixture_schema_version_missing", "message": f"{rel}: missing schema_version"}

    schema_path = schema_by_version.get(schema_version)
    if schema_path is None:
        if (rel, schema_version) in exemptions:
            result["status"] = "pass"
            result["exempted"] = True
            return result, None
        result["status"] = "fail"
        return result, {
            "error_code": "fixture_schema_unmapped",
            "message": f"{rel}: no contract schema maps schema_version {schema_version}",
        }

    result["schema"] = relative(root, schema_path)
    schema = load_json(schema_path)
    try:
        validator_cls(schema).validate(fixture)
        validation_error = None
    except Exception as exc:
        validation_error = validation_error_message(exc)
        result["validation_error"] = validation_error

    expect_valid = bool(result["expect_valid"])
    if expect_valid and validation_error is not None:
        result["status"] = "fail"
        return result, {
            "error_code": "positive_fixture_rejected",
            "message": f"{rel}: expected valid under {result['schema']}, got {validation_error}",
        }
    if not expect_valid and validation_error is None:
        result["status"] = "fail"
        return result, {
            "error_code": "negative_fixture_accepted",
            "message": f"{rel}: expected rejection under {result['schema']}",
        }

    result["status"] = "pass"
    result["negative_rejected"] = not expect_valid
    return result, None


def collect_fixture_cases(
    root: Path,
    validator_cls: Any,
    schema_by_version: dict[str, Path],
    exemptions: set[tuple[str, str]],
) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    results: list[dict[str, Any]] = []
    errors: list[dict[str, str]] = []
    for fixture_path in sorted((root / "fixtures").rglob("*.json")):
        if fixture_should_skip(fixture_path):
            continue
        result, error = validate_fixture_case(root, validator_cls, fixture_path, schema_by_version, exemptions)
        results.append(result)
        if error is not None:
            errors.append(error)
    return results, errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate the v18 schema corpus and all schema-backed fixtures.")
    parser.add_argument("--json", action="store_true", help="Emit standard robot JSON envelope.")
    parser.add_argument(
        "--root",
        default=str(Path(__file__).resolve().parents[1]),
        help="Bundle root directory. Defaults to the parent of this script directory.",
    )
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()
    warnings: list[str] = []
    errors: list[dict[str, str]] = []

    try:
        from jsonschema import Draft202012Validator
    except ImportError:
        output = envelope(
            False,
            {"checked_root": str(root), "coverage": {"score": 0}},
            [{"error_code": "jsonschema_unavailable", "message": "python jsonschema package is required"}],
            warnings,
        )
        print(json.dumps(output, indent=2, sort_keys=True) if args.json else output["errors"][0]["message"])
        return 1

    exemptions, exemption_cases, exemption_errors = load_exemptions(root)
    errors.extend(exemption_errors)
    schema_by_version, schema_cases, schema_errors = collect_schema_cases(root, Draft202012Validator)
    errors.extend(schema_errors)
    fixture_cases, fixture_errors = collect_fixture_cases(root, Draft202012Validator, schema_by_version, exemptions)
    errors.extend(fixture_errors)

    all_cases = schema_cases + fixture_cases + exemption_cases
    passing = sum(1 for case in all_cases if case.get("status") == "pass")
    coverage = {
        "divergent": 0,
        "exemption_cases": len(exemption_cases),
        "fixture_cases": len(fixture_cases),
        "must_clauses": len(all_cases),
        "passing": passing,
        "schema_cases": len(schema_cases),
        "score": passing / len(all_cases) if all_cases else 0,
        "should_clauses": 0,
        "tested": len(all_cases),
    }
    output = envelope(
        not errors,
        {
            "bundle_version": VERSION,
            "checked_root": str(root),
            "coverage": coverage,
            "exemption_cases": exemption_cases,
            "exemptions_path": EXEMPTIONS_PATH,
            "fixture_cases": fixture_cases,
            "schema_cases": schema_cases,
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
