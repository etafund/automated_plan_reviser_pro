# Provider Result Consistency Policy

> Bundle version: v18.0.0

Provider results, browser evidence, prompt manifests, source baselines, and artifact indexes must agree on IDs and hashes. APR may accept permissive extension fields, but eligibility decisions must be based only on core fields.

## Required consistency checks

- `provider_result.provider_result_id` must match the browser evidence `provider_result_id` for browser routes.
- `provider_result.evidence_id` must match the evidence object for critical browser routes.
- Browser evidence must verify mode and effort before prompt submission.
- Optional API reviewers need no browser evidence, but must provide provider-family-specific reasoning-effort verification.
- DeepSeek and xAI provider results must be present in fixtures because both are default optional reviewers.

## Hidden reasoning boundary

Provider results may store:

- final answer text hashes and paths,
- concise public reasoning summaries written by the model in normal answer text,
- citations and search trace hashes,
- redacted evidence references,
- hashes of transient hidden-reasoning payloads when an adapter needs them for provider-required tool-call replay.

Provider results must not store raw hidden reasoning, browser private prompts, chain-of-thought payloads, or unredacted tool replay buffers. DeepSeek is the only v18 route that may replay `reasoning_content` transiently for tool-call continuity, and even there the persisted result records only policy flags and hashes.

## Eligibility rule

`synthesis_eligible=true` is valid only when all of these are true:

- the access path matches `provider-access-policy.json`;
- required browser evidence is present and linked for browser slots;
- highest-effort policy is verified for the provider family;
- the source baseline and prompt manifest hashes match the run;
- hidden reasoning storage policy is compliant.
