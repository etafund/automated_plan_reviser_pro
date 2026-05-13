# v18 Schema Cross-Invariant Conformance

Bundle version: `v18.0.0`

## Scope

`scripts/schema-cross-invariant-conformance.py` verifies that the route, source, prompt, provider-policy, readiness, quorum, and budget contracts agree after each fixture validates against its own Draft 2020-12 schema.

The harness is deterministic and does not invoke Oracle, browsers, provider CLIs, or live APIs.

Run:

```bash
python3 scripts/schema-cross-invariant-conformance.py --json
```

The command emits a standard `json_envelope.v1` response with per-case status, failure messages, and a MUST coverage score.

## Input Matrix

The test matrix lives in `fixtures/conformance/schema-cross-invariant-cases.json`.

Schema validation cases:

| Contract | Fixture |
| --- | --- |
| `source-baseline.schema.json` | `fixtures/source-baseline.json` |
| `source-trust.schema.json` | `fixtures/source-trust.json` |
| `prompt-policy.schema.json` | `fixtures/prompting-policy.json` |
| `prompt-manifest.schema.json` | `fixtures/prompt-manifest.json` |
| `prompt-context-packet.schema.json` | `fixtures/prompt-context-packet.json` |
| `context-serialization-policy.schema.json` | `fixtures/context-serialization-policy.json` |
| `provider-access-policy.schema.json` | `fixtures/provider-access-policy.json` |
| `model-reasoning-policy.schema.json` | `fixtures/model-reasoning-policy.json` |
| `provider-route.schema.json` | `fixtures/provider-route.balanced.json` |
| `route-readiness.schema.json` | `fixtures/route-readiness.balanced.json` |
| `review-quorum.schema.json` | `fixtures/review-quorum.balanced.json` |
| `runtime-budget.schema.json` | `fixtures/runtime-budget.json` |

Cross-schema invariant cases:

| Area | Case |
| --- | --- |
| Provider routing | Route slots are covered by provider-access and model-reasoning policy. |
| Provider routing | Stage required/optional slot sets match top-level route declarations. |
| Browser evidence | Critical browser slots require verified evidence. |
| Review quorum | Provider route, route readiness, and quorum policy agree. |
| Stage gating | Synthesis prompt gating avoids self-evidence deadlock; final handoff requires synthesis evidence. |
| Provider policy | API-allowed routes have matching runtime budgets. |
| Provider policy | Protected browser slots forbid direct API substitution. |
| Source and prompt | Prompt manifest and context packet hashes align for source/policy/serialization artifacts. |
| Source trust | Source trust covers every baseline source id. |
| Source trust | Quarantined provider instructions propagate into the prompt context boundary. |
| Serialization | Canonical storage remains JSON; TOON/tru remains optional and gated. |
| Provider policy | DeepSeek search policy matches budget and prompting constraints. |

## Coverage Matrix

| Spec Section | MUST Clauses | SHOULD Clauses | Tested | Passing | Divergent | Score |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Selected schema fixtures | 12 | 0 | 12 | 12 | 0 | 1.00 |
| Cross-schema invariants | 12 | 0 | 12 | 12 | 0 | 1.00 |
| Total | 24 | 0 | 24 | 24 | 0 | 1.00 |

## Non-Goals

This harness does not replace provider mocks or live cutover. It proves contract and fixture agreement only. Provider command execution, browser evidence capture, and live API behavior remain covered by the provider mock, negative/security, and live cutover beads.
