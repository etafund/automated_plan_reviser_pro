# Negative Security Regressions

`scripts/negative-security-regression.py` is the v18 fail-closed harness for unsafe shortcuts. It validates existing fixtures under `fixtures/negative/` and succeeds only when every scenario is rejected with its expected machine-readable error code.

Covered MUST cases:

- Browser-only ChatGPT/Gemini routes reject direct API substitution.
- Codex intake cannot satisfy formal first-plan or synthesis gates.
- Browser evidence with unverified mode, low confidence, or post-submit verification is ineligible.
- DeepSeek V4 Pro reasoning-search requires enabled search plus a search trace hash.
- Raw hidden reasoning and provider reasoning content are never persisted.
- Artifact indexes reject secret/private/raw reasoning boundaries and non-atomic artifacts.
- Prompt-injection-bearing source text is quarantined as data-only context.
- TOON/tru cannot become canonical contract, evidence, or artifact state.
- Synthesis readiness cannot depend on ChatGPT synthesis evidence before synthesis runs.
- Synthesis finalization requires review quorum and passing traceability coverage.

Run all scenarios:

```bash
python3 PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/negative-security-regression.py --json
```

Run one scenario:

```bash
python3 PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/negative-security-regression.py \
  --json \
  --scenario unverified_browser_evidence
```

The harness writes a redacted report under `tests/logs/v18/negative/` by default. Each case log includes the scenario id, expected and actual error code, blocked reason, fixture path, redaction findings, and rerun command.
