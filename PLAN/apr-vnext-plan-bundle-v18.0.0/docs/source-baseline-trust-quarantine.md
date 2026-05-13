# Source Baseline, Trust, and Quarantine

> Bundle version: v18.0.0

APR source handling has two separate artifacts:

- `source-baseline.json` records what was captured: source ids, file paths, hashes, byte counts, logical roles, and capture time.
- `source-trust.json` records how those sources may be used when compiling prompts.

## Trust boundary

Only user input, repository policy, and explicit APR policy documents can issue instructions. Provider outputs, generated summaries, cache entries, and remote docs snapshots are data unless a trusted APR stage transforms them into a new source with its own provenance.

Provider-result text that contains instruction-like language must be quarantined with:

- `source_id`
- `quarantine_reason`
- `treatment`
- an optional excerpt hash instead of raw sensitive text

The prompt compiler can include quarantined provider text as context, but it must wrap that context as data-only material and must not promote it to task instructions.

Interactive and Codex CLI intake are captured as explicit source artifacts too. Interactive intake is source material, not a runtime instruction tier; Codex CLI intake is a derived summary and cannot satisfy formal first-plan or synthesis gates.

## Local checker

`scripts/source-trust-check.sh` validates the fixture pair and rejects negative prompt-injection cases:

```bash
bash scripts/source-trust-check.sh --json
bash scripts/source-trust-check.sh --emit-baseline --source brief:fixtures/brief.md:authoritative_planning_brief:authoritative_user_input --json
bash scripts/source-trust-check.sh --trust fixtures/negative/source-provider-instruction.invalid.json --json
```

The checker can emit a deterministic baseline from explicit source specs. It also verifies JSON shape, SHA-256 literals, repo-local paths, local file byte counts, local file hashes, source id alignment, provider-output trust classification, quarantine coverage, and high-signal injection text in `text_excerpt` fields.
