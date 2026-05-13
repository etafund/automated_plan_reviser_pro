# Human Review Packet: run-demo

## Executive Summary

APR v18 has a traceable final plan for route readiness and synthesis gates. The packet keeps provider evidence, reviewer deltas, waiver visibility, tests, rollback, and approvals together for implementation handoff.

- Handoff eligible: yes
- Degradation label: waived
- Approval ledger: approval-ledger-demo
- Final plan artifact: plan-demo

## Implementation Sequence

1. Wire route readiness, provider evidence, and final handoff gate checks.
   - Plan item: PLAN-ROUTE-GATING
   - Tests: TEST-ROUTE-READINESS-CONTRACT, TEST-PROVIDER-COMPARISON-CONTRACT
   - Rollback: RB-ROUTE-GATING

## High-Risk Decisions

- DECISION-SPLIT-SYNTHESIS-HANDOFF-GATES: synthesis evidence is produced by the synthesis call, so it gates final handoff rather than synthesis prompt submission.
  - Approval: APR-DECISION-001
  - Evidence: evidence-demo-chatgpt_pro_first_plan, evidence-demo-gemini_deep_think

## Degradation / Waiver Visibility

- fallback-waiver-demo: waived
  - Fallback browser/manual-import conditions must remain visible in the handoff packet and cannot be treated as a clean run.
  - Approval: APR-DECISION-001

## Unresolved Questions

- QUESTION-LIVE-SELECTOR-FRESHNESS: Confirm the live Oracle selector manifest still exposes the required highest-visible reasoning controls before cutover.
  - Owner: implementation_agent
  - Required before: live_cutover

## Test Plan

- TEST-ROUTE-READINESS-CONTRACT: `python3 scripts/contract-fixture-smoke.py --json`
- TEST-PROVIDER-COMPARISON-CONTRACT: `python3 scripts/contract-fixture-smoke.py --json`

## Rollback Points

- RB-ROUTE-GATING: return to pre-synthesis route readiness if provider evidence, quorum, or waiver records diverge.
  - Verify with: `apr providers readiness --json`

## Bead Export Preview

- v18-route-readiness-gate: Implement route readiness and synthesis handoff gates
  - Depends on: v18-provider-evidence
  - Plan item: PLAN-ROUTE-GATING
