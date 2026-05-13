# APR vNext plan bundle v18.0.0

> Bundle version: v18.0.0

This is a standalone v18 plan bundle for one coding agent working independently. It does not require this conversation, the other subset specs, or the Agent Flywheel guide.

Primary purpose: Implement APR vNext route compiler, plan revision engine, provider adapters, Plan IR, synthesis, traceability, and robot surfaces.

Read these files first:

1. `spec.md`
2. `ROBOTS.md`
3. `robots.json`
4. `docs/answered-clarifications.md`
5. `docs/provider-access-policy.md`
6. `docs/browser-lease-and-evidence.md`
7. `contracts/`
8. `fixtures/`
9. `scripts/validate-subset.py`

Run:

```bash
python3 scripts/validate-subset.py --json
python3 scripts/contract-fixture-smoke.py --json
```

Historical v1-v10 patches are intentionally omitted. Active files are version-stamped `v18.0.0`.

## v18 correction highlights

- Codex CLI subscription intake is context only: not Oracle, not API, not a formal first plan.
- ChatGPT Pro first plan and synthesis remain Oracle-browser routes for `balanced` and `audit`.
- Gemini Deep Think remains an Oracle-browser route with same-session redacted evidence.
- Provider access policy, browser lease, evidence, and provider result contracts are now explicit fixtures.
- Validators check the v18 invariants rather than merely parsing JSON.


## v18.0.0 audit note

This bundle includes stricter v18 contract fixtures and smoke tests. Run `python3 scripts/validate-subset.py --json` before implementation. Remote browser is treated as the primary browser path for balanced/audit planning, while Codex CLI subscription intake remains context-only.


## v18 DeepSeek provider addition

Bundle version: v18.0.0

Adds `deepseek_v4_pro_reasoning_search` as a default optional independent comparison-review provider. This route uses the official DeepSeek API with `deepseek-v4-pro`, thinking enabled, `reasoning_effort=max`, and APR-provided web-search tool calls. It is an API-allowed exception like xAI/Grok; it does not weaken the ban on direct API substitution for ChatGPT, Gemini, or Claude.


## v18 highest-reasoning invariant

Every live model call in this workflow must request the highest provider-specific reasoning effort available. See `docs/highest-reasoning-policy.md` and `fixtures/model-reasoning-policy.json`. Missing, unknown, default, or downgraded effort is not synthesis-eligible for `balanced` or `audit` unless a waiver is recorded before the call.


## v18.0.0 review corrections

- Browser effort labels are not stable contracts. ChatGPT Pro browser routes now request `max_browser_available` and require Oracle evidence that the highest visible effort was selected before prompt submission.
- Gemini Deep Think browser routes now distinguish `browser_mode=Deep Think` from `requested_reasoning_effort=deep_think_highest_available`; if a separate thinking-level control is exposed, select `high`.
- Route readiness is stage-scoped: preflight readiness does not imply synthesis eligibility.
- Provider docs are captured in `fixtures/provider-docs-snapshot.json` and must be refreshed before audit runs or implementation if provider surfaces changed.
- Claude Code Opus uses `--effort max`/`CLAUDE_CODE_EFFORT_LEVEL=max`; `ultrathink` is an additional one-off request, not a replacement for effort configuration.


## v18 semantic audit updates

- Adds `review_quorum.v1` so balanced planning requires Gemini Deep Think plus at least one additional independent reviewer before synthesis, unless the user records an explicit waiver.
- Splits synthesis gating into `synthesis_prompt_blocked_until_evidence_for` and `final_handoff_blocked_until_evidence_for`, avoiding the circular mistake of requiring ChatGPT synthesis evidence before the synthesis call can run.
- Adds `provider-result.xai.json` so every default optional reviewer has a provider-result fixture.
- Tightens DeepSeek reasoning-content handling: raw `reasoning_content` may be retained only transiently for required tool-call replay and may be persisted only as hashes.
- Adds provider-doc snapshot expiration fields so live provider assumptions are refreshed before real provider calls.


## v18 premortem hardening

Bundle version: v18.0.0

v18 adds a pessimistic failure-mode ledger, a live cutover checklist, explicit fallback waiver semantics, and run-progress artifacts. These are included because the most likely failure mode is not a syntax error; it is a plausible mock/demo run that hides browser mode drift, live-provider flakiness, silent downgrade, or user-visible waiting.

Read:

- `docs/premortem-failure-mode-hardening.md`
- `docs/mock-to-live-cutover-policy.md`
- `docs/degradation-waiver-policy.md`
- `docs/user-experience-failure-policy.md`
- `fixtures/failure-mode-ledger.json`
- `fixtures/live-cutover-checklist.json`


## v18 TOON Rust Context Compression

This bundle includes an optional TOON context-compression policy. TOON may be used for prompt payload compaction after the license gate is approved, but canonical artifacts remain JSON/Markdown. See `docs/toon-rust-context-compression-policy.md`, `contracts/context-serialization-policy.schema.json`, and `fixtures/context-serialization-policy.json`.

## Operator quickstart

Use this sequence when you need to prove the bundle is usable before wiring real provider calls. It is intentionally local and mock-backed; it must not spend browser or API capacity.

```bash
python3 scripts/apr-mock.py capabilities --json
python3 scripts/apr-mock.py plan-routes --json
python3 scripts/apr-mock.py readiness --json
python3 scripts/apr-mock.py compile --json
python3 scripts/apr-mock.py fanout --json
python3 scripts/apr-mock.py report --json
```

Each command emits the v18 JSON envelope: `ok`, `schema_version`, `data`, `meta`, `warnings`, `errors`, and `commands`. Failed or blocked envelopes also carry `blocked_reason`, `next_command`, `fix_command`, and `retry_safe`.

### Planning profiles

`fast` is the cheap local rehearsal path. It uses Codex thinking as a draft source and is never synthesis-eligible for balanced or audit handoff.

`balanced` is the normal production planning path. It requires ChatGPT Pro through Oracle browser for the first plan, Gemini Deep Think through browser evidence for independent review, and ChatGPT Pro through Oracle browser for synthesis. Claude Code Opus, xAI Grok, and DeepSeek V4 Pro are independent comparison reviewers when available.

`audit` is the high-assurance path. It follows the balanced provider restrictions, adds stricter evidence and review expectations, and should be used before live cutover or when the output will drive irreversible implementation work.

### End-to-end mock journey

1. Inspect provider capability and route policy:

   ```bash
   python3 scripts/apr-mock.py capabilities --json
   python3 scripts/apr-mock.py plan-routes --json
   ```

2. Check readiness gates before compiling prompts:

   ```bash
   python3 scripts/apr-mock.py readiness --json
   ```

   `preflight_ready=true` only means provider execution may start. It does not mean synthesis is allowed. For balanced and audit, synthesis remains blocked until browser evidence and reviewer quorum artifacts are present.

3. Compile prompt context and review the serialization policy:

   ```bash
   python3 scripts/apr-mock.py compile --json
   python3 scripts/apr-mock.py serialization doctor --format toon --json
   ```

   JSON remains canonical. TOON/tru is an optional prompt compression path only after license approval and local tool detection.

4. Rehearse fanout, comparison, synthesis, and reporting:

   ```bash
   python3 scripts/apr-mock.py fanout --json
   python3 scripts/apr-mock.py synthesize --json
   python3 scripts/apr-mock.py report --json
   ```

5. Export implementation work to beads only after the final handoff gate is clear. The bead export contract is described in `docs/plan-export-beads.md`.

### Operator docs

- Provider setup: `docs/provider-setup-guide.md`
- Route readiness and blocked states: `docs/route-readiness-and-stage-gates.md`
- Troubleshooting: `docs/operator-troubleshooting.md`
- Mock-to-live cutover: `docs/live-cutover-operator-guide.md`
- Robot command rules: `ROBOTS.md`
- Agent handoff snippets: `AGENTS.md`
