# v18 Schema Corpus Conformance

Bundle version: `v18.0.0`

## Scope

`scripts/schema-corpus-conformance.py` validates the current v18 JSON contract corpus as a whole:

- Every `contracts/*.schema.json` file is valid Draft 2020-12 and declares a unique `schema_version`.
- Every schema-backed positive fixture under `fixtures/**` validates against the contract schema matching its `schema_version`.
- Every schema-backed negative fixture under `fixtures/**/negative/**` or named `*.invalid.json` is rejected by the matching contract schema.
- Intentional non-schema fixture artifacts are listed in `fixtures/conformance/schema-corpus-exemptions.json` and fail the harness if the exemption entry is incomplete.

Run:

```bash
python3 scripts/schema-corpus-conformance.py --json
```

The command emits a standard `json_envelope.v1` response with schema, fixture, exemption, and coverage details.

## Exemptions

The following fixtures are intentionally not matched to Draft 2020-12 contract schemas:

| Fixture | Schema version | Reason |
| --- | --- | --- |
| `fixtures/intake-capture-manifest.json` | `intake_capture_manifest.v1` | Implementation manifest artifact. |
| `fixtures/log-bundle.json` | `log_bundle.v1` | Test/logging artifact. |
| `fixtures/route-compiler.capabilities.json` | `route_compiler_capabilities.v1` | Route test input corpus. |
| `fixtures/synthesis-finalization.json` | `synthesis_finalization.v1` | Enforced by synthesis checker and traceability/artifact contracts. |
| `fixtures/negative/synthesis-missing-traceability.invalid.json` | `synthesis_finalization.v1` | Negative owned by synthesis-finalization checker. |

## Coverage Matrix

| Spec Section | MUST Clauses | SHOULD Clauses | Tested | Passing | Divergent | Score |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Contract schemas | 37 | 0 | 37 | 37 | 0 | 1.00 |
| Schema-backed fixtures | 72 | 0 | 72 | 72 | 0 | 1.00 |
| Documented non-schema fixture exemptions | 5 | 0 | 5 | 5 | 0 | 1.00 |
| Total | 114 | 0 | 114 | 114 | 0 | 1.00 |

## Non-Goals

This harness checks schema corpus coverage and fixture acceptance/rejection. It does not replace semantic conformance harnesses such as `schema-cross-invariant-conformance.py`, browser evidence linkage checks, provider mocks, or live cutover validation.
