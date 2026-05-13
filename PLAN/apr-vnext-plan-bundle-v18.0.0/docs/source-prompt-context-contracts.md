# Source, Prompt, and Context Contracts

> Bundle version: v18.0.0

APR builds prompts from trusted local project state plus provider outputs that may contain untrusted instructions. The source and prompt contracts make that boundary visible before any provider-specific prompt is compiled.

## Contract chain

| Contract | Purpose |
|---|---|
| `source-baseline.schema.json` | Lists canonical source artifacts and hashes for the run. |
| `source-trust.schema.json` | Classifies each source and records quarantined instructions. |
| `prompt-policy.schema.json` | Defines provider-specific prompt rules and forbidden substitutions. |
| `prompt-manifest.schema.json` | Records prompt id, policy version, included sections, excluded sections, input hashes, and serialization choice. |
| `prompt-context-packet.schema.json` | Describes the assembled model-facing context packet. |
| `context-format.schema.json` | Records a single context rendering decision. |
| `context-serialization-policy.schema.json` | Defines canonical JSON storage, optional TOON/tru prompt transport, and JSON fallback. |

## Trust rules

Source classes must distinguish `authoritative_user_input`, `trusted_repo_source`, `trusted_local_config`, `provider_result_untrusted_text`, `remote_docs_snapshot`, and `derived_summary`. Provider prose is never authoritative by itself. If provider text contains instructions that conflict with the user, repository, or runtime policy, APR must record a quarantine entry and exclude that instruction from prompt directives.

`docs/source-baseline-trust-quarantine.md` defines the implementation boundary and the local checker that validates source id alignment, path/hash metadata, and quarantine coverage.

## Serialization rules

Canonical artifacts stay JSON or Markdown. TOON/tru may only be used as an optional prompt transport after source-trust filtering, secret redaction, license approval, and round-trip validation. Prompt manifests must record the canonical JSON hash and the TOON payload hash when TOON is used.

## Negative fixture intent

`fixtures/negative/toon-as-authoritative-contract.invalid.json` is invalid because it makes TOON the canonical contract format and disables round-trip validation. That is a prompt-transport choice pretending to be authoritative state.
