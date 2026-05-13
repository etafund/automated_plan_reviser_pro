# Intake Capture Source Artifacts

> Bundle version: v18.0.0

APR treats intake as source context, not as route evidence. Interactive operator answers and Codex CLI drafts can improve prompt context, but they cannot satisfy the ChatGPT Pro first-plan requirement and they cannot become trusted runtime instructions without traceability.

## Contract boundary

- `fixtures/interactive-intake.json` records operator intake metadata.
- `fixtures/codex-intake.json` records Codex CLI intake or fast exploratory draft metadata.
- `fixtures/intake-capture-manifest.json` ties both captures to `source-baseline.json` and `source-trust.json`.
- `scripts/intake-capture-check.sh` validates source ids, hashes, trust labels, and Codex route restrictions.

## Trust rules

Interactive intake is user-originated source material, but it is still classified as `source_material_not_instruction` in prompt context. The planning brief and explicit current task remain the trusted directive surfaces.

Codex intake is a derived summary from a subscription CLI route. It must remain `derived_summary_data_only`, with `formal_first_plan=false`, `eligible_for_synthesis=false`, and `may_satisfy_formal_first_plan=false`.

## Local check

```bash
bash scripts/intake-capture-check.sh --json
```

To prove the negative Codex shortcut is rejected:

```bash
bash scripts/intake-capture-check.sh --codex fixtures/negative/codex-intake-formal-plan.invalid.json --json
```
