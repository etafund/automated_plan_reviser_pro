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
