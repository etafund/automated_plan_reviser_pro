# Provider Result Comparison Contract

> Bundle version: v18.0.0

APR compares normalized provider results after the `full_plan_ir` stage and before synthesis. The comparison artifact is structured input for synthesis; it is not a prose transcript bundle.

## Inputs

Comparison consumes only normalized Plan IR artifacts and provider/evidence/source references. Raw provider prose may be addressed by provider result id and hash, but comparison records must cite structured plan items, source refs, evidence refs, or explicit warnings.

Each comparison run records:

- compared provider result ids;
- source baseline hash;
- normalized input artifact id;
- item counts for agreements, contradictions, missing coverage, stale assumptions, unsupported claims, and improvement opportunities;
- output comparison id and output hash.

## Required Records

The comparison artifact must represent disagreements and reviewer value as typed records:

- `agreements` for recommendations that multiple providers support;
- `contradiction_ids` for conflicts that synthesis must resolve explicitly;
- `reviewer_delta_ids` for improvements a reviewer adds beyond the first plan;
- `stale_assumption_ids` for claims tied to old docs, obsolete product state, or missing freshness evidence;
- `unsupported_claim_ids` for low-confidence claims that need human review or source support;
- `improvement_opportunity_ids` for actionable CLI, browser, security, test, contract, docs, or rollout improvements.

## Synthesis Boundary

Synthesis receives comparison records, normalized plan items, and traceability links. It must not receive an unannotated pile of provider summaries. Every contradiction, stale assumption, unsupported claim, and reviewer delta passed to synthesis must carry provider result ids and at least one traceability anchor.
