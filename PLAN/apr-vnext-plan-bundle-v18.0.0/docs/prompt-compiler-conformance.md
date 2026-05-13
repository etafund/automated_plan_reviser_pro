# v18 Prompt Compiler Conformance

Bundle version: `v18.0.0`

## Scope

`scripts/prompt-compiler-conformance.py` verifies that the prompt compiler remains bound to the v18 route and prompt-policy fixtures:

- Every route declared in `fixtures/provider-route.balanced.json` compiles successfully through `scripts/compile-prompt.py`.
- Every output is a `json_envelope.v1` envelope with `ok=true`.
- Every compiled prompt carries a stable `sha256:<64-hex>` prompt hash.
- `provider_rules` exactly match the route's policy family in `fixtures/prompting-policy.json`.
- The redacted preview includes the route role, provider rules, baseline hash marker, and manifest hash marker.
- Successful compilation stays stdout-only.

Run:

```bash
python3 scripts/prompt-compiler-conformance.py --json
```

## Coverage Matrix

| Spec Section | MUST Clauses | SHOULD Clauses | Tested | Passing | Divergent | Score |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Declared balanced provider routes | 6 | 0 | 6 | 6 | 0 | 1.00 |
| Total | 6 | 0 | 6 | 6 | 0 | 1.00 |

## Known Warning

The current `prompt-manifest.json` fixture does not expose a top-level `prompt_manifest_sha256`; `compile-prompt.py` therefore emits `Manifest Hash: unknown` while still preserving a manifest hash marker. The harness reports this as a warning rather than a failure because the contract currently only requires the marker to exist in the compiled preview.

## Non-Goals

This harness does not replace schema validation, cross-schema invariant checks, or route readiness gates. It pins the compiler's public prompt output against route and prompt-policy fixtures.
