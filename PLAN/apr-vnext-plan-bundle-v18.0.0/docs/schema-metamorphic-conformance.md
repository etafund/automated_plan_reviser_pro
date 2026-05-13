# v18 Schema Metamorphic Conformance

`scripts/schema-metamorphic-conformance.py` adds oracle-free checks on top of
the schema corpus and round-trip suites. It starts with every positive
schema-backed fixture, proves the original validates, then applies deterministic
mutations that must flip the fixture from valid to invalid.

## Metamorphic Relations

| Relation | Pattern | Fault sensitivity | Independence | Cost | Score |
| --- | --- | ---: | ---: | ---: | ---: |
| `MR-SV-CONST` | schema_version const perturbation | 5 | 5 | 1 | 25.0 |
| `MR-TOP-ENUM-CONST` | top-level enum/const domain perturbation | 4 | 4 | 1 | 16.0 |
| `MR-TOP-TYPE` | top-level JSON type-shape perturbation | 4 | 5 | 2 | 10.0 |

All implemented relations score above the 2.0 cutoff. They are deliberately
generic: new positive fixtures with `schema_version` mapped to
`contracts/*.schema.json` automatically enter the suite.

## Command

```bash
cd PLAN/apr-vnext-plan-bundle-v18.0.0
python3 scripts/schema-metamorphic-conformance.py --json
```

Success emits a `json_envelope.v1` object with:

- `data.original_fixture_cases`: every positive fixture and mapped schema.
- `data.metamorphic_cases`: every generated mutation and validation error.
- `data.coverage.relation_counts`: per-relation case counts.
- `data.relation_matrix`: the scored MR matrix above.

The BATS integration wrapper is:

```bash
tests/lib/bats-core/bin/bats tests/integration/test_v18_schema_metamorphic_conformance.bats
```

## Non-Goals

- This harness does not replace semantic cross-schema invariants. Those remain
  in `scripts/schema-cross-invariant-conformance.py`.
- This harness does not require `additionalProperties: false`; several v18
  contracts intentionally allow forward-compatible extension fields.
- This harness does not write generated negative fixtures. Mutations are
  ephemeral and reported in the JSON envelope.
