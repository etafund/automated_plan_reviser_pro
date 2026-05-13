# Operator Troubleshooting

> Bundle version: v18.0.0

Use JSON envelopes first. Human text is secondary.

## Blocked

`blocked` means a required provider, artifact, or gate cannot proceed. Inspect:

- `.blocked_reason`
- `.next_command`
- `.fix_command`
- `.retry_safe`
- `.data.blocked[]`

Common fixes:

- Missing Oracle browser route: configure `ORACLE_REMOTE_HOST` or `ORACLE_REMOTE_POOL`, then rerun readiness.
- Missing browser evidence: complete the browser route and attach redacted evidence before synthesis.
- Stale provider docs: refresh `fixtures/provider-docs-snapshot.json`.
- Missing API key for optional reviewers: set `XAI_API_KEY` or `DEEPSEEK_API_KEY`, or accept a documented degraded path if policy allows it.

## Degraded

`degraded` means the route can continue only with reduced coverage or an approved waiver. Degradation must be visible in:

- route readiness output
- run progress artifacts
- human review packet
- final handoff notes

Balanced and audit cannot waive ChatGPT Pro first plan, Gemini Deep Think, or ChatGPT Pro synthesis.

## Manual import

`manual_import` means a human-supplied artifact can satisfy a stage only when approval metadata is present. Require:

- artifact path
- provider slot
- source transcript or captured output
- approver
- timestamp
- hash
- reason

Do not silently convert manual imports into live evidence.

## Fallback prompt pack

`fallback_prompt_pack` is a recovery path, not a normal success. Use it only when the route policy allows fallback and the final handoff surfaces the downgrade.

## Readiness confusion

`preflight_ready=true` is not enough for synthesis. The expected balanced shape before provider execution is:

- preflight ready
- synthesis prompt not ready
- final handoff not ready
- pending browser evidence listed

If a tool claims synthesis is ready before provider results and browser evidence exist, treat it as a contract violation.

## Retry policy

Retry automatically only when `.retry_safe == true`. If live provider calls were attempted, inspect the run progress and evidence artifacts before retrying.
