#!/usr/bin/env python3
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


VERSION = "v18.0.0"


def sha256_path(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return "sha256:" + digest.hexdigest()


def load_json_path(path):
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.JSONDecoder().decode(handle.read())
    except OSError as exc:
        raise SystemExit("failed to read {path}: {error}".format(path=path, error=exc)) from exc
    except json.JSONDecodeError as exc:
        raise SystemExit("failed to parse JSON in {path}: {error}".format(path=path, error=exc)) from exc


def exact_bool(record, key, expected):
    value = record.get(key)
    return isinstance(value, bool) and value == expected


def slugify(value):
    slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return slug or "plan-item"


def json_envelope(ok, data, errors=None, warnings=None, blocked_reason=None):
    return {
        "ok": ok,
        "schema_version": "json_envelope.v1",
        "data": data,
        "meta": {
            "tool": "plan-export-beads",
            "bundle_version": VERSION,
        },
        "blocked_reason": blocked_reason,
        "next_command": None if ok else "fix bead export contract violations",
        "fix_command": None if ok else "PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/plan-export-beads.py --json",
        "retry_safe": True,
        "errors": errors or [],
        "warnings": warnings or [],
        "commands": {
            "generate": "PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/plan-export-beads.py --json",
            "validate": "PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/plan-export-beads.py --validate PLAN/apr-vnext-plan-bundle-v18.0.0/fixtures/bead-export.json --json",
        },
    }


def collect_by_id(records, key):
    return {record.get(key): record for record in records if record.get(key)}


def command_preview(parts):
    return " ".join("'" + p.replace("'", "'\\''") + "'" if re.search(r"\s", p) else p for p in parts)


def build_body(item, acceptance_records, tests, rollbacks):
    source_refs = item.get("source_refs", [])
    provider_refs = item.get("provider_result_refs", [])
    evidence_refs = item.get("evidence_refs", [])
    decisions = item.get("human_decision_ids", [])
    criteria = [record.get("statement", "") for record in acceptance_records if record.get("statement")]
    lines = [
        "## Objective",
        item.get("description", ""),
        "",
        "## Traceability",
        "- Plan item: " + item.get("item_id", ""),
        "- Source refs: " + ", ".join(source_refs),
        "- Provider result refs: " + ", ".join(provider_refs),
        "- Evidence refs: " + ", ".join(evidence_refs),
        "- Human decisions: " + ", ".join(decisions),
        "",
        "## Acceptance Criteria",
    ]
    lines.extend("- " + criterion for criterion in criteria)
    lines.extend(["", "## Test Obligations"])
    for test in tests:
        lines.append("- {test_id}: {command}".format(
            test_id=test.get("test_id", ""),
            command=test.get("command", ""),
        ))
    lines.extend(["", "## Rollback"])
    for rollback in rollbacks:
        lines.append("- {rollback_point_id}: {verification_command}".format(
            rollback_point_id=rollback.get("rollback_point_id", ""),
            verification_command=rollback.get("verification_command", ""),
        ))
    lines.append("")
    return "\n".join(lines)


def export_from_plan(plan_path):
    plan = load_json_path(plan_path)
    operations = []
    acceptance_by_id = collect_by_id(plan.get("acceptance_criteria_records", []), "criterion_id")
    tests_by_id = collect_by_id(plan.get("test_matrix", []), "test_id")
    rollback_by_id = collect_by_id(plan.get("rollback_points", []), "rollback_point_id")

    for item in plan.get("plan_items", []):
        item_id = item.get("item_id", "")
        acceptance_records = [
            acceptance_by_id[criterion_id]
            for criterion_id in item.get("acceptance_criteria_ids", [])
            if criterion_id in acceptance_by_id
        ]
        tests = [
            tests_by_id[test_id]
            for test_id in item.get("test_ids", [])
            if test_id in tests_by_id
        ]
        rollbacks = [
            rollback_by_id[rollback_id]
            for rollback_id in item.get("rollback_point_ids", [])
            if rollback_id in rollback_by_id
        ]
        title = item.get("title", item_id)
        priority = int(item.get("priority_suggestion", 2))
        create_command = [
            "br",
            "create",
            title,
            "--type",
            "task",
            "--priority",
            str(priority),
        ]
        operation_id = "create-" + slugify(item_id)
        operations.append({
            "operation_id": operation_id,
            "operation": "br_create",
            "command": create_command,
            "command_preview": command_preview(create_command),
            "depends_on_operation_ids": [],
            "plan_item_ids": [item_id],
            "source_traceability": {
                "acceptance_criteria_ids": item.get("acceptance_criteria_ids", []),
                "provider_result_refs": item.get("provider_result_refs", []),
                "source_refs": item.get("source_refs", []),
                "evidence_refs": item.get("evidence_refs", []),
                "human_decision_ids": item.get("human_decision_ids", []),
                "test_ids": item.get("test_ids", []),
                "rollback_point_ids": item.get("rollback_point_ids", []),
            },
            "bead": {
                "title": title,
                "type": "task",
                "priority": priority,
                "labels": ["v18", "exported-plan", item.get("kind", "plan_item")],
                "body_md": build_body(item, acceptance_records, tests, rollbacks),
                "acceptance_criteria": [record.get("statement", "") for record in acceptance_records],
                "test_obligations": [
                    {
                        "test_id": test.get("test_id", ""),
                        "command": test.get("command", ""),
                        "expected": test.get("expected", ""),
                    }
                    for test in tests
                ],
            },
        })

        for dep_id in item.get("depends_on_item_ids", []):
            dep_command = ["br", "dep", "add", slugify(item_id), slugify(dep_id)]
            operations.append({
                "operation_id": "dep-" + slugify(item_id) + "-after-" + slugify(dep_id),
                "operation": "br_dep_add",
                "command": dep_command,
                "command_preview": command_preview(dep_command),
                "depends_on_operation_ids": [operation_id],
                "plan_item_ids": [item_id, dep_id],
            })

    cycle_command = ["br", "dep", "cycles", "--json"]
    operations.append({
        "operation_id": "check-dependency-cycles",
        "operation": "br_dep_cycles",
        "command": cycle_command,
        "command_preview": command_preview(cycle_command),
        "plan_item_ids": [item.get("item_id", "") for item in plan.get("plan_items", []) if item.get("item_id")],
    })

    br_create_count = sum(1 for op in operations if op["operation"] == "br_create")
    br_dep_add_count = sum(1 for op in operations if op["operation"] == "br_dep_add")
    return {
        "schema_version": "bead_export.v1",
        "bundle_version": VERSION,
        "export_id": "bead-export-" + slugify(plan.get("plan_id", "plan")),
        "created_at": "2026-05-13T04:31:00Z",
        "dry_run": True,
        "plan_id": plan.get("plan_id", ""),
        "source_plan": {
            "path": "fixtures/" + plan_path.name,
            "sha256": sha256_path(plan_path),
            "stage": plan.get("stage", ""),
        },
        "summary": {
            "plan_item_count": len(plan.get("plan_items", [])),
            "operation_count": len(operations),
            "br_create_count": br_create_count,
            "br_dep_add_count": br_dep_add_count,
        },
        "apply_policy": {
            "apply_requires_explicit_flag": True,
            "direct_jsonl_edit_allowed": False,
            "uses_br_commands_only": True,
        },
        "safeguards": {
            "duplicate_detection": "title_slug_and_plan_item_id",
            "cycle_check_command": "br dep cycles --json",
            "mutation_mode": "dry_run",
        },
        "proposed_operations": operations,
    }


def validate_export(export):
    errors = []
    warnings = []
    checks = []

    def record(requirement_id, level, status, detail):
        checks.append({
            "requirement_id": requirement_id,
            "level": level,
            "status": status,
            "detail": detail,
        })

    def fail(requirement_id, detail):
        record(requirement_id, "MUST", "fail", detail)
        errors.append({"error_code": "bead_export_invalid", "message": detail})

    if export.get("schema_version") == "bead_export.v1" and export.get("bundle_version") == VERSION:
        record("BEXP-MUST-SCHEMA", "MUST", "pass", "schema and bundle version match v18")
    else:
        fail("BEXP-MUST-SCHEMA", "export must use bead_export.v1 and v18.0.0")

    if export.get("source_plan", {}).get("stage") == "bead_export_ready":
        record("BEXP-MUST-STAGE", "MUST", "pass", "source plan is bead_export_ready")
    else:
        fail("BEXP-MUST-STAGE", "source plan stage must be bead_export_ready")

    policy = export.get("apply_policy", {})
    if exact_bool(policy, "direct_jsonl_edit_allowed", False) and exact_bool(policy, "uses_br_commands_only", True):
        record("BEXP-MUST-BR-ONLY", "MUST", "pass", "apply policy forbids direct JSONL edits")
    else:
        fail("BEXP-MUST-BR-ONLY", "apply policy must forbid direct JSONL edits and require br commands")

    operations = export.get("proposed_operations", [])
    create_ops = [op for op in operations if op.get("operation") == "br_create"]
    if create_ops:
        record("BEXP-MUST-CREATE-OPS", "MUST", "pass", "export includes br_create operations")
    else:
        fail("BEXP-MUST-CREATE-OPS", "export must include at least one br_create operation")

    if any(op.get("operation") == "br_dep_cycles" for op in operations):
        record("BEXP-MUST-CYCLE-CHECK", "MUST", "pass", "export includes dependency cycle check")
    else:
        fail("BEXP-MUST-CYCLE-CHECK", "export must include br dep cycles check")

    for op in create_ops:
        bead = op.get("bead", {})
        trace = op.get("source_traceability", {})
        prefix = op.get("operation_id", "br_create")
        if not all(bead.get(key) for key in ("title", "body_md", "acceptance_criteria", "test_obligations")):
            fail("BEXP-MUST-BEAD-BODY", prefix + " must include title, body, acceptance criteria, and tests")
            break
    else:
        record("BEXP-MUST-BEAD-BODY", "MUST", "pass", "bead bodies include implementation detail and tests")

    for op in create_ops:
        trace = op.get("source_traceability", {})
        if not (trace.get("source_refs") and trace.get("provider_result_refs") and trace.get("test_ids") and trace.get("rollback_point_ids")):
            fail("BEXP-MUST-TRACE", op.get("operation_id", "br_create") + " is missing source/provider/test/rollback traceability")
            break
    else:
        record("BEXP-MUST-TRACE", "MUST", "pass", "create operations preserve source/provider/test/rollback traceability")

    for op in operations:
        command = op.get("command", [])
        if command and command[0] != "br":
            fail("BEXP-MUST-COMMAND-SAFETY", op.get("operation_id", "operation") + " uses non-br command")
            break
    else:
        record("BEXP-MUST-COMMAND-SAFETY", "MUST", "pass", "all proposed mutation/check commands use br")

    summary = export.get("summary", {})
    if summary.get("operation_count") == len(operations) and summary.get("br_create_count") == len(create_ops):
        record("BEXP-SHOULD-SUMMARY", "SHOULD", "pass", "summary counts match operations")
    else:
        warnings.append("summary counts should match proposed operations")
        record("BEXP-SHOULD-SUMMARY", "SHOULD", "fail", "summary counts drift from operations")

    must_count = sum(1 for check in checks if check["level"] == "MUST")
    must_pass = sum(1 for check in checks if check["level"] == "MUST" and check["status"] == "pass")
    should_count = sum(1 for check in checks if check["level"] == "SHOULD")
    return not errors, errors, warnings, {
        "conformance_checks": checks,
        "conformance_coverage": {
            "must_clauses": must_count,
            "should_clauses": should_count,
            "tested": len(checks),
            "passing": sum(1 for check in checks if check["status"] == "pass"),
            "divergent": 0,
            "must_score": (must_pass / must_count) if must_count else 1,
        },
    }


def main():
    parser = argparse.ArgumentParser(description="Generate or validate v18 bead export dry-run artifacts.")
    parser.add_argument("--plan", default="PLAN/apr-vnext-plan-bundle-v18.0.0/fixtures/plan-artifact.json")
    parser.add_argument("--validate", help="Validate an existing bead_export.v1 artifact instead of generating one.")
    parser.add_argument("--json", action="store_true", help="Emit v18 JSON envelope.")
    args = parser.parse_args()

    if args.validate:
        export_path = Path(args.validate)
        export = load_json_path(export_path)
    else:
        export = export_from_plan(Path(args.plan))

    ok, errors, warnings, validation = validate_export(export)
    data = {
        "export": export,
        **validation,
    }
    envelope = json_envelope(ok, data, errors, warnings, None if ok else "bead export contract violations")
    if args.json:
        print(json.dumps(envelope, indent=2, sort_keys=True))
    else:
        print(json.dumps(export, indent=2, sort_keys=True))

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
