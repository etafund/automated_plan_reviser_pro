# AGENTS.md - APR v18 Operator Snippets

> Bundle version: v18.0.0

This file is for coding agents implementing or operating this bundle. Use JSON modes, keep mock and live artifacts separate, and do not infer provider readiness from human prose.

## First local pass

Run these from `PLAN/apr-vnext-plan-bundle-v18.0.0`:

```bash
python3 scripts/apr-mock.py capabilities --json
python3 scripts/apr-mock.py plan-routes --json
python3 scripts/apr-mock.py readiness --json
python3 scripts/apr-mock.py compile --json
python3 scripts/apr-mock.py fanout --json
python3 scripts/apr-mock.py report --json
```

Treat every output as a JSON envelope. Branch on `.ok`, `.blocked_reason`, `.next_command`, `.fix_command`, and `.retry_safe`, not on human text.

## Provider rules

- ChatGPT Pro first plan and synthesis use Oracle browser automation. Do not replace them with a direct API route.
- Gemini Deep Think uses browser evidence. Do not mark it ready until same-session redacted evidence is present.
- Claude Code Opus is a subscription CLI reviewer. Use max effort plus the documented ultrathink prompt cue.
- Codex CLI subscription intake is context only. It is not a formal first plan and is not synthesis-eligible.
- xAI Grok and DeepSeek V4 Pro are API-allowed independent reviewers when their keys and highest-reasoning controls are verified.
- DeepSeek search must be APR-provided tool-call search. Raw `reasoning_content` is transient only and may be persisted only as hashes.

## Readiness rules

Readiness is stage-scoped:

- `preflight_ready=true` permits provider execution.
- `synthesis_prompt_ready=true` is required before ChatGPT Pro synthesis.
- `synthesis_ready=true` is required before final planning handoff.
- `blocked`, `degraded`, `manual_import`, and `fallback_prompt_pack` must surface in handoff artifacts.

## Live cutover guard

Never run live provider calls from a mock test or docs smoke. Live execution requires:

```bash
APR_V18_LIVE_CUTOVER=1 python3 scripts/live-cutover-dress-rehearsal.py --json --approval-id <approval-id> --execute-live
```

If `--execute-live` is absent, the dress rehearsal is a dry-run checklist only.
