# Plan IR Normalization Ladder

> Bundle version: v18.0.0

APR never sends raw provider prose directly to synthesis or bead export. Provider output must move through a recorded ladder where each stage has a typed artifact, an input hash, an output hash, and explicit warnings for anything dropped or downgraded.

## Stages

1. `raw_provider_output` records the provider result id, provider slot, source baseline hash, result text hash, and evidence ids.
2. `minimal_plan_ir` extracts candidate plan items with source/provider/evidence references but does not invent missing acceptance criteria.
3. `full_plan_ir` enriches items with assumptions, risks, acceptance criteria, tests, rollback points, contradiction candidates, and unresolved questions.
4. `bead_export_ready` verifies every task-like item has title, type, priority suggestion, body, dependencies, acceptance criteria, tests, rollback points, and traceability.

## Required Preservation

Every normalized item must keep at least one of:

- `provider_result_refs`
- `source_refs`
- `evidence_refs`
- `human_decision_ids`

Warnings are mandatory when provider prose cannot be mapped into structured fields. Dropped prose must be represented as a warning with a provider result id and a reason; it must not silently disappear.

## Bead Export Readiness

An item is bead-export-ready only when it has:

- a stable `item_id`;
- a human-readable `title`;
- a `kind` and `priority_suggestion`;
- an implementation `description`;
- acceptance criteria ids;
- test ids with commands or verification notes;
- rollback point ids;
- provider/source/evidence or human decision traceability.

The corresponding fixture is `fixtures/plan-artifact.json`. The traceability cross-check is `fixtures/traceability.json`.
