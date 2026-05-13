# v18 Schema Round-Trip Conformance

Bundle version: `v18.0.0`

## Scope

`scripts/schema-roundtrip-conformance.py` verifies three serialization contracts:

| Contract | Positive fixture | Negative fixture | MUST checks |
| --- | --- | --- | --- |
| `provider-result.schema.json` | `fixtures/conformance/provider-result.chatgpt.minimal.json` | `fixtures/conformance/negative/provider-result-raw-reasoning.invalid.json` | Valid provider result round-trips; hidden reasoning is rejected. |
| `browser-evidence.schema.json` | `fixtures/conformance/browser-evidence.chatgpt.minimal.json` | `fixtures/conformance/negative/browser-evidence-raw-dom.invalid.json` | Redacted evidence round-trips; raw browser artifacts are rejected. |
| `run-progress.schema.json` | `fixtures/conformance/run-progress.preflight.minimal.json` | `fixtures/conformance/negative/run-progress-missing-required.invalid.json` | Progress state round-trips; retry safety remains required. |

## Conformance Method

Each valid fixture is parsed as JSON, validated with the matching Draft 2020-12 schema, serialized into canonical JSON with sorted keys and stable separators, parsed again, and serialized a second time. The harness fails if semantic identity or canonical byte stability changes.

Each invalid fixture is parsed and must fail schema validation. Negative fixtures are not round-tripped because acceptance would be the defect.

## Coverage Matrix

| Spec Section | MUST Clauses | SHOULD Clauses | Tested | Passing | Divergent | Score |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Provider result serialization | 2 | 0 | 2 | 2 | 0 | 1.00 |
| Browser evidence serialization | 2 | 0 | 2 | 2 | 0 | 1.00 |
| Run progress serialization | 2 | 0 | 2 | 2 | 0 | 1.00 |

Run:

```bash
python3 scripts/schema-roundtrip-conformance.py --json
```

The command emits a standard `json_envelope.v1` robot response with per-fixture hashes, pass/fail verdicts, and remediation fields.
