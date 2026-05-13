# v18 Plan Export To Beads

Bundle version: v18.0.0

The bead export contract turns a `bead_export_ready` Plan IR into a dry-run
operation list for `br`. It preserves enough context for each exported bead to
stand alone: objective text, traceability ids, acceptance criteria, tests, and
rollback points.

APR must not edit `.beads/*.jsonl` directly. Export output is either a handoff
artifact or, when an apply mode is explicitly implemented, a list of `br`
commands to run.

## Required Invariants

- Source Plan IR stage is `bead_export_ready`.
- Every `br_create` operation has a title, type, priority, labels, body,
  acceptance criteria, and test obligations.
- Every exported bead body includes traceability back to plan item ids,
  source refs, provider result refs, test ids, and rollback point ids.
- Apply policy sets `direct_jsonl_edit_allowed=false` and
  `uses_br_commands_only=true`.
- Dry-run output includes a dependency-cycle check operation.
- Duplicate detection is explicit and based on title slug plus plan item id.

## Fixtures

Positive fixture:

```bash
PLAN/apr-vnext-plan-bundle-v18.0.0/fixtures/bead-export.json
```

Negative fixture:

```bash
PLAN/apr-vnext-plan-bundle-v18.0.0/fixtures/negative/bead-export-missing-trace.invalid.json
```

The negative fixture is invalid because it allows direct JSONL mutation, omits
acceptance/test obligations, and loses source/provider/test traceability.

## Commands

Generate a dry-run export envelope:

```bash
PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/plan-export-beads.py --json
```

Validate an existing export artifact:

```bash
PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/plan-export-beads.py --validate PLAN/apr-vnext-plan-bundle-v18.0.0/fixtures/bead-export.json --json
```

## Conformance Matrix

| Spec Section | MUST Clauses | SHOULD Clauses | Tested | Passing | Divergent | Score |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `bead_export.v1` | 8 | 1 | 9 | 9 | 0 | 1.00 |
