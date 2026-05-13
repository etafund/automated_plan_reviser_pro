# v18 Human Review Packet

Bundle version: v18.0.0

The human review packet is the deterministic handoff surface for a completed
planning run. It condenses the final plan, traceability, provider deltas,
waivers, approval ledger entries, tests, rollback points, and bead export
preview into a repo-local packet that a future implementation agent can use
without reading raw provider outputs.

## Required Packet Inputs

The packet references durable artifacts by id:

- final plan artifact (`plan_artifact.v1`)
- traceability matrix (`traceability_matrix.v1`)
- artifact index (`artifact_index.v1`)
- approval ledger (`approval_ledger.v1`)
- provider result ids
- fallback waiver ids
- failure-mode ledger id

Raw hidden reasoning, browser-private material, provider secrets, and unredacted
DOM/screenshot captures are never copied into the review packet. The packet uses
artifact ids, evidence ids, hashes, approval ids, and concise rationales.

## Required Sections

The packet must include:

- executive summary and implementation handoff eligibility
- ordered implementation sequence
- high-risk decisions and approval ids
- explicit waiver/degradation labels
- unresolved questions
- test plan
- rollback points
- bead export preview

Waivers must be visible. If `source_artifact_ids.waiver_ids` is non-empty,
`waivers_and_degradations` must also be non-empty and every entry must set
`must_surface_in_handoff=true`.

## Golden Packet

The positive fixture is:

```bash
PLAN/apr-vnext-plan-bundle-v18.0.0/fixtures/human-review-packet.json
```

It points to the rendered golden Markdown packet:

```bash
PLAN/apr-vnext-plan-bundle-v18.0.0/fixtures/human-review-packet.md
```

The negative fixture
`fixtures/negative/human-review-packet-hidden-waiver.invalid.json` is invalid
because it references a waiver id while hiding the waiver/degradation section.

## Conformance Matrix

| Spec Section | MUST Clauses | SHOULD Clauses | Tested | Passing | Divergent | Score |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `human_review_packet.v1` | 12 | 1 | 13 | 13 | 0 | 1.00 |

The checker emits the standard v18 JSON envelope:

```bash
PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/human-review-packet-check.sh --json
```

It validates schema shape, traceability references, approval ids, waiver
visibility, unresolved question counts, test and rollback coverage, golden
Markdown section visibility, and bead export readiness.
