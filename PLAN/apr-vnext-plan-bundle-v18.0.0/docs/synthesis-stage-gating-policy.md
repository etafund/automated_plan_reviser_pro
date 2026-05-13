# Synthesis Stage Gating Policy

> Bundle version: v18.0.0

## Problem fixed in v16

The previous route-readiness contract could be read as saying synthesis was blocked until `chatgpt_pro_synthesis` evidence already existed. That is circular: the synthesis evidence is produced by the synthesis call itself.

## Correct model

There are two distinct gates:

1. **Synthesis prompt submission gate** — before APR submits the synthesis prompt to ChatGPT Pro, APR must have the formal first plan, required independent reviewer evidence, normalized provider outputs, comparison results, and review quorum satisfaction or waiver.
2. **Final handoff gate** — after ChatGPT Pro synthesis completes, APR must have redacted evidence for the synthesis browser run before the plan can be handed off as implementation-ready.

## Required fields

Use `synthesis_prompt_blocked_until_evidence_for` for evidence needed before the synthesis prompt can be submitted. Use `final_handoff_blocked_until_evidence_for` for evidence needed before final handoff. Do not use a field that requires synthesis evidence before synthesis execution.

## Traceable handoff artifacts

The final plan cannot be handed off from prose alone. The plan artifact, traceability matrix, artifact index, and approval ledger must agree on plan item IDs, provider result IDs, evidence IDs, source baseline hash, test IDs, rollback point IDs, and human approval IDs. A final plan item is incomplete unless it points back to at least one source/provider/evidence reference or an explicit human decision.

## Normalization Gate

Synthesis consumes only `full_plan_ir` or `bead_export_ready` artifacts produced by the normalization ladder in `docs/plan-ir-normalization-ladder.md`. Raw provider output may be referenced by id and hash, but it must not be copied into the synthesis packet as executable planning instructions.

## Finalization Conformance Harness

`scripts/synthesis-finalization-check.sh` validates the finalization contract
before APR can label a synthesis output implementation-ready:

```bash
PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/synthesis-finalization-check.sh --json
```

The positive fixture is `fixtures/synthesis-finalization.json`; the negative
fixture is `fixtures/negative/synthesis-missing-traceability.invalid.json`.

Coverage accounting:

| Spec Section | MUST Clauses | SHOULD Clauses | Tested | Passing | Divergent | Score |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `synthesis_finalization.v1` | 10 | 1 | 11 | 11 | 0 | 1.00 |

Required checks:

- synthesis prompt submission is ready before the synthesis route is invoked;
- synthesis prompt evidence requirements are non-circular;
- review quorum is met or explicitly waived;
- synthesis provider result is successful, synthesis-eligible, effort-verified,
  and evidence-linked;
- final handoff gate requires the synthesis evidence produced after the call;
- final plan items retain source, provider, evidence, approval, test, and
  rollback traceability;
- traceability matrix covers requirements, final plan items, tests, and
  contradiction resolutions;
- every final artifact is present in the artifact index;
- handoff approval ids resolve to approved approval-ledger entries.

The checker emits the standard v18 JSON envelope with `conformance_checks`,
`conformance_coverage`, `blocked_reason`, `next_command`, and `fix_command`.
