# Route Readiness and Stage Gates

> Bundle version: v18.0.0

## Problem fixed in v16

The v18 `route-readiness.balanced.json` said `ready=true` while also listing `blocked_on_missing_effort_verification_for`. That was logically confusing: preflight readiness happens before live browser evidence exists, while synthesis eligibility happens after provider execution.

## v18 rule

Readiness is stage-scoped.

- `preflight_ready=true` means the run can start provider execution.
- `pending_browser_evidence_for` lists browser slots that must produce evidence during execution.
- `synthesis_ready=false` before live provider results are normalized.
- `synthesis_blocked_until_evidence_for` lists slots that cannot contribute to synthesis until evidence is verified.

APR must not treat preflight readiness as synthesis eligibility.

## Stage order

1. `intake`
2. `first_plan`
3. `independent_review`
4. `compare`
5. `synthesis`
6. `human_review`
7. `handoff`

`chatgpt_pro_first_plan` is required for `first_plan`; `gemini_deep_think` is required for `independent_review` in balanced/audit; `chatgpt_pro_synthesis` is required for `synthesis`.


## v18 correction: synthesis prompt gate versus final handoff gate

Use `synthesis_prompt_blocked_until_evidence_for` for evidence that must exist before APR submits ChatGPT Pro synthesis. Use `final_handoff_blocked_until_evidence_for` for evidence that must exist before APR hands the final plan to `$planning-workflow`. Do not require `chatgpt_pro_synthesis` evidence before running the synthesis call itself.

## Stable readiness states

Route readiness records must make unavailable routes explicit instead of collapsing them into a generic error:

| State | Meaning |
|---|---|
| `ready` | The named scope can proceed. |
| `blocked` | A required route or gate cannot proceed without remediation. |
| `degraded` | A waiver or profile choice has intentionally lowered coverage. |
| `skipped_by_profile` | A slot is not part of the selected execution profile. |
| `manual_import` | A human-supplied artifact can satisfy the stage only with approval metadata. |
| `fallback_prompt_pack` | A fallback prompt can be used, but the handoff must surface the downgrade. |

Each blocked or degraded entry should include `stage`, `provider_slot`, `reason_code`, `message`, `next_command`, `fix_command`, `retry_safe`, and an optional `waiver_id`.

## Negative fixture intent

`fixtures/negative/route-readiness-circular-synthesis.invalid.json` is invalid because it requires `chatgpt_pro_synthesis` evidence before the synthesis prompt is submitted. Synthesis evidence is produced by that call, so it can block final handoff but not synthesis prompt submission.
