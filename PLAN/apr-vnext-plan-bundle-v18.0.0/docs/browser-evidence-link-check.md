# Browser Evidence Link Check

Bundle version: `v18.0.0`

`scripts/browser-evidence-link-check.py` verifies cross-schema invariants for browser-backed v18 routes. The JSON schemas validate each artifact shape independently; this checker validates that a provider result is eligible only when its lease, browser session, evidence record, and provider result agree.

## MUST Coverage

| Spec Section | MUST Clauses | SHOULD Clauses | Tested | Passing | Divergent | Score |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Accepted ChatGPT browser result links to verified evidence | 1 | 0 | 1 | 1 | 0 | 1.00 |
| Accepted Gemini browser result links to verified evidence | 1 | 0 | 1 | 1 | 0 | 1.00 |
| Missing reasoning-effort verification is rejected | 1 | 0 | 1 | 1 | 0 | 1.00 |
| Low-confidence evidence is rejected | 1 | 0 | 1 | 1 | 0 | 1.00 |
| Stale selector manifests are rejected | 1 | 0 | 1 | 1 | 0 | 1.00 |
| Evidence not verified before prompt submission is rejected | 1 | 0 | 1 | 1 | 0 | 1.00 |

## Command

Run from the bundle root:

```bash
python3 scripts/browser-evidence-link-check.py --json
```

The command emits a `json_envelope.v1` response. Each case includes route id, lease id, session id, evidence id, selector manifest id, capture confidence, prompt hash, and redaction verdict in its logs.

## Non-Goals

This checker does not drive a browser or call Oracle. It is a deterministic contract harness for APR-side eligibility rules before live provider work is wired in.
