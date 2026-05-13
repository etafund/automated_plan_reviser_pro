#!/usr/bin/env python3
"""v18_contract_roundtrip.py

Bead automated_plan_reviser_pro-srhk — round-trip + required-field-drop
conformance harness for the v18 schema corpus.

Two property layers on top of the existing v18_contract_smoke.py:

  Round-trip:
    For every positive fixture, parse → canonicalize (sort_keys=True,
    indent=2, ensure_ascii=False) → re-parse → re-validate against its
    schema. Assert the re-parsed object equals the original.

  Required-drop fuzzing:
    For every required property in the schema, if it appears at the
    fixture's top level, drop it and assert the result FAILS validation.
    Skips required keys that don't appear at the fixture top level
    (those are gated by allOf / oneOf / anyOf and aren't directly
    droppable without deeper schema walking).

Emits a JSON summary on stdout describing every check; exits 0 iff every
applicable check passes. Per-fixture log lines also go to
tests/logs/v18/contracts/roundtrip_<ts>.log.

Designed to be wrapped by tests/integration/test_v18_contract_roundtrip.bats.
"""

from __future__ import annotations

import copy
import json
import logging
import sys
import time
from pathlib import Path
from typing import Any, Dict, List

import jsonschema  # type: ignore


REPO_ROOT = Path(__file__).resolve().parent.parent
BUNDLE_ROOT = REPO_ROOT / "PLAN" / "apr-vnext-plan-bundle-v18.0.0"
CONTRACTS_DIR = BUNDLE_ROOT / "contracts"
FIXTURES_DIR = BUNDLE_ROOT / "fixtures"
LOG_DIR = REPO_ROOT / "tests" / "logs" / "v18" / "contracts"

# Fixtures whose schema is intentionally hand-mapped (the smoke harness
# does the same; we mirror it so behavior matches).
SCHEMA_NAME_OVERRIDES = {
    "traceability-matrix": "traceability",
}


def schema_path_for_fixture(fixture_path: Path) -> Path | None:
    try:
        data = json.loads(fixture_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return None
    version = data.get("schema_version")
    if not version:
        return None
    base = version.rsplit(".", 1)[0].replace("_", "-")
    base = SCHEMA_NAME_OVERRIDES.get(base, base)
    candidate = CONTRACTS_DIR / f"{base}.schema.json"
    return candidate if candidate.exists() else None


def canonicalize(obj: Any) -> str:
    """Stable JSON serialization for round-trip comparison."""
    return json.dumps(obj, sort_keys=True, indent=2, ensure_ascii=False)


def check_roundtrip(fixture_path: Path, schema_path: Path) -> Dict[str, Any]:
    fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
    schema = json.loads(schema_path.read_text(encoding="utf-8"))

    # Initial validation must pass (smoke does this too; we re-assert
    # for self-containment).
    try:
        jsonschema.validate(fixture, schema)
    except jsonschema.ValidationError as exc:
        return {
            "phase": "initial_validate",
            "passed": False,
            "error": exc.message,
        }

    canonical_text = canonicalize(fixture)
    try:
        reparsed = json.loads(canonical_text)
    except json.JSONDecodeError as exc:
        return {
            "phase": "canonical_reparse",
            "passed": False,
            "error": f"canonical JSON is unparseable: {exc.msg}",
        }

    # Re-validate the canonical form.
    try:
        jsonschema.validate(reparsed, schema)
    except jsonschema.ValidationError as exc:
        return {
            "phase": "canonical_validate",
            "passed": False,
            "error": exc.message,
        }

    # Logical equality is the load-bearing property: canonicalization
    # must not lose or invent information.
    if reparsed != fixture:
        # Compute a tiny structural diff for the log.
        a_keys = sorted(fixture.keys()) if isinstance(fixture, dict) else "(non-object)"
        b_keys = sorted(reparsed.keys()) if isinstance(reparsed, dict) else "(non-object)"
        return {
            "phase": "logical_equality",
            "passed": False,
            "error": "canonical re-parse differs from original",
            "details": {
                "original_keys": a_keys,
                "canonical_keys": b_keys,
            },
        }

    return {"phase": "roundtrip", "passed": True}


def check_required_drop(fixture_path: Path, schema_path: Path) -> Dict[str, Any]:
    fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
    schema = json.loads(schema_path.read_text(encoding="utf-8"))

    required: List[str] = list(schema.get("required") or [])
    if not required or not isinstance(fixture, dict):
        return {"checked": 0, "results": [], "skipped_reason": "no_required_at_top_level"}

    results: List[Dict[str, Any]] = []
    for key in required:
        if key not in fixture:
            results.append({"key": key, "applicable": False})
            continue
        mutated = copy.deepcopy(fixture)
        del mutated[key]
        try:
            jsonschema.validate(mutated, schema)
            results.append({
                "key": key,
                "applicable": True,
                "rejected": False,
                "error": (
                    f"dropping required '{key}' STILL passes validation — "
                    f"the schema does not actually enforce this required key"
                ),
            })
        except jsonschema.ValidationError:
            results.append({"key": key, "applicable": True, "rejected": True})
    return {"checked": len(results), "results": results}


def main() -> int:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    log_path = LOG_DIR / f"roundtrip_{timestamp}.log"

    logging.basicConfig(
        filename=str(log_path),
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )
    console = logging.StreamHandler()
    console.setLevel(logging.INFO)
    console.setFormatter(logging.Formatter("%(message)s"))
    logging.getLogger("").addHandler(console)

    if not BUNDLE_ROOT.exists():
        logging.error("v18 bundle not found at %s", BUNDLE_ROOT)
        return 2

    positives = sorted(p for p in FIXTURES_DIR.glob("*.json") if p.is_file())

    summary: Dict[str, Any] = {
        "timestamp": timestamp,
        "fixture_count": len(positives),
        "fixtures": [],
        "round_trip_failures": 0,
        "required_drop_failures": 0,
        "fixtures_without_schema": 0,
    }

    overall_ok = True

    for fixture in positives:
        rel = fixture.relative_to(BUNDLE_ROOT)
        schema = schema_path_for_fixture(fixture)
        entry: Dict[str, Any] = {"fixture": str(rel)}

        if schema is None:
            entry["schema"] = None
            entry["status"] = "skipped_no_schema"
            summary["fixtures"].append(entry)
            summary["fixtures_without_schema"] += 1
            logging.info("[SKIP] %s — no schema match", rel)
            continue

        entry["schema"] = str(schema.relative_to(BUNDLE_ROOT))

        rt = check_roundtrip(fixture, schema)
        entry["roundtrip"] = rt
        if not rt.get("passed"):
            summary["round_trip_failures"] += 1
            overall_ok = False
            logging.error(
                "[ROUNDTRIP FAIL] %s @%s: %s",
                rel,
                rt.get("phase"),
                rt.get("error"),
            )
        else:
            logging.info("[ROUNDTRIP OK] %s", rel)

        rd = check_required_drop(fixture, schema)
        entry["required_drop"] = rd
        for r in rd.get("results", []):
            if r.get("applicable") and not r.get("rejected"):
                summary["required_drop_failures"] += 1
                overall_ok = False
                logging.error(
                    "[REQUIRED-DROP FAIL] %s: %s",
                    rel,
                    r.get("error"),
                )
        # Per-fixture summary line for the log.
        rejected = sum(1 for r in rd.get("results", []) if r.get("applicable") and r.get("rejected"))
        total = sum(1 for r in rd.get("results", []) if r.get("applicable"))
        logging.info("[REQUIRED-DROP] %s: %d/%d required keys correctly rejected", rel, rejected, total)

        summary["fixtures"].append(entry)

    summary["passed"] = overall_ok
    # Emit JSON summary on stdout for the BATS wrapper.
    print(json.dumps(summary, sort_keys=True, indent=2))
    logging.info("OVERALL: %s", "PASS" if overall_ok else "FAIL")

    return 0 if overall_ok else 1


if __name__ == "__main__":
    sys.exit(main())
