#!/usr/bin/env python3
"""Metamorphic conformance checks for v18 schema-backed fixtures."""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
from pathlib import Path
from typing import Any

VERSION = "v18.0.0"
ENVELOPE_VERSION = "json_envelope.v1"
SKIPPED_FIXTURE_NAMES = {
    "browser-evidence-linkage-cases.json",
    "schema-corpus-exemptions.json",
    "schema-cross-invariant-cases.json",
}

TYPE_CANDIDATES: tuple[tuple[str, Any], ...] = (
    ("object", {"__apr_metamorphic_type__": True}),
    ("array", ["__apr_metamorphic_type__"]),
    ("string", "__apr_metamorphic_type__"),
    ("number", 3.25),
    ("integer", 17),
    ("boolean", True),
    ("null", None),
)

RELATION_MATRIX = [
    {
        "cost": 1,
        "fault_sensitivity": 5,
        "id": "MR-SV-CONST",
        "independence": 5,
        "pattern": "equivalence-breaking const perturbation",
        "relation": "Changing schema_version away from the schema const MUST flip valid to invalid.",
        "score": 25.0,
    },
    {
        "cost": 1,
        "fault_sensitivity": 4,
        "id": "MR-TOP-ENUM-CONST",
        "independence": 4,
        "pattern": "exclusive domain perturbation",
        "relation": "Changing top-level enum/const fields outside their allowed domain MUST flip valid to invalid.",
        "score": 16.0,
    },
    {
        "cost": 2,
        "fault_sensitivity": 4,
        "id": "MR-TOP-TYPE",
        "independence": 5,
        "pattern": "type-shape perturbation",
        "relation": "Changing a typed top-level field to a value outside its JSON type set MUST flip valid to invalid.",
        "score": 10.0,
    },
]


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


def envelope(ok: bool, data: dict[str, Any], errors: list[dict[str, str]], warnings: list[str]) -> dict[str, Any]:
    return {
        "blocked_reason": None if ok else "schema_metamorphic_conformance_failed",
        "commands": {
            "next": "python3 scripts/schema-metamorphic-conformance.py --json",
        },
        "data": data,
        "errors": errors,
        "fix_command": None if ok else "fix listed schema constraint or fixture mutation acceptance",
        "meta": {
            "bundle_version": VERSION,
            "tool": "schema-metamorphic-conformance",
        },
        "ok": ok,
        "retry_safe": True,
        "schema_version": ENVELOPE_VERSION,
        "warnings": warnings,
    }


def fixture_should_skip(path: Path) -> bool:
    return path.name in SKIPPED_FIXTURE_NAMES


def is_negative_fixture(root: Path, path: Path) -> bool:
    rel_parts = path.relative_to(root).parts
    return "negative" in rel_parts or path.name.endswith(".invalid.json")


def schema_version(schema: dict[str, Any]) -> str | None:
    value = schema.get("properties", {}).get("schema_version", {}).get("const")
    return value if isinstance(value, str) else None


def collect_schemas(root: Path, validator_cls: Any) -> tuple[dict[str, tuple[Path, dict[str, Any]]], list[dict[str, str]]]:
    schemas: dict[str, tuple[Path, dict[str, Any]]] = {}
    errors: list[dict[str, str]] = []
    for schema_path in sorted((root / "contracts").glob("*.schema.json")):
        rel = relative(root, schema_path)
        try:
            schema = load_json(schema_path)
            validator_cls.check_schema(schema)
        except Exception as exc:
            errors.append({"error_code": "schema_invalid", "message": f"{rel}: {validation_error_message(exc)}"})
            continue
        version = schema_version(schema)
        if version is None:
            errors.append({"error_code": "schema_version_missing", "message": f"{rel}: missing schema_version const"})
            continue
        if version in schemas:
            other = relative(root, schemas[version][0])
            errors.append({"error_code": "schema_version_duplicate", "message": f"{rel}: duplicates {version} from {other}"})
            continue
        schemas[version] = (schema_path, schema)
    return schemas, errors


def collect_positive_fixtures(
    root: Path,
    schemas: dict[str, tuple[Path, dict[str, Any]]],
) -> tuple[list[tuple[Path, dict[str, Any], Path, dict[str, Any]]], list[dict[str, str]]]:
    fixtures: list[tuple[Path, dict[str, Any], Path, dict[str, Any]]] = []
    errors: list[dict[str, str]] = []
    for fixture_path in sorted((root / "fixtures").rglob("*.json")):
        if fixture_should_skip(fixture_path) or is_negative_fixture(root, fixture_path):
            continue
        rel = relative(root, fixture_path)
        try:
            fixture = load_json(fixture_path)
        except Exception as exc:
            errors.append({"error_code": "fixture_json_invalid", "message": f"{rel}: {exc}"})
            continue
        version = fixture.get("schema_version")
        if not isinstance(version, str):
            continue
        schema_entry = schemas.get(version)
        if schema_entry is None:
            continue
        schema_path, schema = schema_entry
        fixtures.append((fixture_path, fixture, schema_path, schema))
    return fixtures, errors


def json_type_names(value: Any) -> set[str]:
    if value is None:
        return {"null"}
    if isinstance(value, bool):
        return {"boolean"}
    if isinstance(value, int):
        return {"integer", "number"}
    if isinstance(value, float):
        return {"number"}
    if isinstance(value, str):
        return {"string"}
    if isinstance(value, list):
        return {"array"}
    if isinstance(value, dict):
        return {"object"}
    return set()


def allowed_type_set(type_value: Any) -> set[str]:
    if isinstance(type_value, str):
        return {type_value}
    if isinstance(type_value, list):
        return {item for item in type_value if isinstance(item, str)}
    return set()


def invalid_value_for_type(type_value: Any) -> tuple[str, Any] | None:
    allowed = allowed_type_set(type_value)
    if not allowed:
        return None
    for candidate_type, candidate_value in TYPE_CANDIDATES:
        if json_type_names(candidate_value).isdisjoint(allowed):
            return candidate_type, copy.deepcopy(candidate_value)
    return None


def invalid_enum_value(allowed_values: Any) -> Any:
    candidate = "__apr_invalid_enum__"
    if isinstance(allowed_values, list) and candidate in allowed_values:
        return "__apr_invalid_enum_2__"
    return candidate


def invalid_const_value(const_value: Any) -> Any:
    candidates: tuple[Any, ...] = (
        "__apr_invalid_const__",
        8675309,
        False,
        None,
        {"__apr_invalid_const__": True},
    )
    for candidate in candidates:
        if candidate != const_value:
            return copy.deepcopy(candidate)
    return "__apr_invalid_const_fallback__"


def validate_accepts(validator: Any, value: dict[str, Any]) -> tuple[bool, str | None]:
    try:
        validator.validate(value)
        return True, None
    except Exception as exc:
        return False, validation_error_message(exc)


def add_case(
    cases: list[dict[str, Any]],
    errors: list[dict[str, str]],
    validator: Any,
    fixture: dict[str, Any],
    fixture_rel: str,
    schema_rel: str,
    relation_id: str,
    mutation_id: str,
    mutated_path: str,
    mutated_value: Any,
) -> None:
    mutated = copy.deepcopy(fixture)
    mutated[mutated_path] = mutated_value
    accepted, validation_error = validate_accepts(validator, mutated)
    status = "fail" if accepted else "pass"
    case = {
        "fixture": fixture_rel,
        "mutation_id": mutation_id,
        "mutated_path": f"/{mutated_path}",
        "relation_id": relation_id,
        "schema": schema_rel,
        "status": status,
        "validation_error": validation_error,
    }
    cases.append(case)
    if accepted:
        errors.append({
            "error_code": "mutation_accepted",
            "message": f"{fixture_rel}: {relation_id} mutation {mutation_id} unexpectedly validated under {schema_rel}",
        })


def collect_metamorphic_cases(root: Path, validator_cls: Any) -> tuple[dict[str, Any], list[dict[str, str]], list[str]]:
    warnings: list[str] = []
    errors: list[dict[str, str]] = []
    schemas, schema_errors = collect_schemas(root, validator_cls)
    errors.extend(schema_errors)
    fixtures, fixture_errors = collect_positive_fixtures(root, schemas)
    errors.extend(fixture_errors)

    original_cases: list[dict[str, Any]] = []
    mutation_cases: list[dict[str, Any]] = []

    for fixture_path, fixture, schema_path, schema in fixtures:
        fixture_rel = relative(root, fixture_path)
        schema_rel = relative(root, schema_path)
        validator = validator_cls(schema)
        accepted, validation_error = validate_accepts(validator, fixture)
        original_status = "pass" if accepted else "fail"
        original_cases.append({
            "fixture": fixture_rel,
            "fixture_sha256": sha256_text(fixture_path.read_text(encoding="utf-8")),
            "schema": schema_rel,
            "schema_version": fixture.get("schema_version"),
            "status": original_status,
            "validation_error": validation_error,
        })
        if not accepted:
            errors.append({
                "error_code": "original_fixture_rejected",
                "message": f"{fixture_rel}: original positive fixture rejected by {schema_rel}: {validation_error}",
            })
            continue

        version = fixture.get("schema_version")
        add_case(
            mutation_cases,
            errors,
            validator,
            fixture,
            fixture_rel,
            schema_rel,
            "MR-SV-CONST",
            "schema_version_const_perturbation",
            "schema_version",
            f"{version}.__apr_metamorphic__",
        )

        for property_name, property_schema in sorted(schema.get("properties", {}).items()):
            if property_name == "schema_version" or property_name not in fixture or not isinstance(property_schema, dict):
                continue
            if "enum" in property_schema:
                add_case(
                    mutation_cases,
                    errors,
                    validator,
                    fixture,
                    fixture_rel,
                    schema_rel,
                    "MR-TOP-ENUM-CONST",
                    f"{property_name}_enum_perturbation",
                    property_name,
                    invalid_enum_value(property_schema.get("enum")),
                )
            if "const" in property_schema:
                add_case(
                    mutation_cases,
                    errors,
                    validator,
                    fixture,
                    fixture_rel,
                    schema_rel,
                    "MR-TOP-ENUM-CONST",
                    f"{property_name}_const_perturbation",
                    property_name,
                    invalid_const_value(property_schema.get("const")),
                )
            invalid_typed = invalid_value_for_type(property_schema.get("type"))
            if invalid_typed is not None:
                invalid_type, invalid_value = invalid_typed
                add_case(
                    mutation_cases,
                    errors,
                    validator,
                    fixture,
                    fixture_rel,
                    schema_rel,
                    "MR-TOP-TYPE",
                    f"{property_name}_type_perturbation_to_{invalid_type}",
                    property_name,
                    invalid_value,
                )

    relation_counts: dict[str, int] = {}
    for case in mutation_cases:
        relation_id = str(case["relation_id"])
        relation_counts[relation_id] = relation_counts.get(relation_id, 0) + 1

    all_cases = original_cases + mutation_cases
    passing = sum(1 for case in all_cases if case.get("status") == "pass")
    coverage = {
        "divergent": len(errors),
        "fixture_cases": len(original_cases),
        "must_clauses": len(all_cases),
        "mutation_cases": len(mutation_cases),
        "passing": passing,
        "relation_counts": relation_counts,
        "score": passing / len(all_cases) if all_cases else 0,
        "should_clauses": 0,
        "tested": len(all_cases),
    }
    data = {
        "bundle_version": VERSION,
        "checked_root": str(root),
        "coverage": coverage,
        "metamorphic_cases": mutation_cases,
        "original_fixture_cases": original_cases,
        "relation_matrix": RELATION_MATRIX,
    }
    return data, errors, warnings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run v18 schema metamorphic conformance checks.")
    parser.add_argument("--json", action="store_true", help="Emit standard robot JSON envelope.")
    parser.add_argument(
        "--root",
        default=str(Path(__file__).resolve().parents[1]),
        help="Bundle root directory. Defaults to the parent of this script directory.",
    )
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()

    try:
        from jsonschema import Draft202012Validator
    except ImportError:
        output = envelope(
            False,
            {"checked_root": str(root), "coverage": {"score": 0}},
            [{"error_code": "jsonschema_unavailable", "message": "python jsonschema package is required"}],
            [],
        )
        print(json.dumps(output, indent=2, sort_keys=True) if args.json else output["errors"][0]["message"])
        return 1

    data, errors, warnings = collect_metamorphic_cases(root, Draft202012Validator)
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
