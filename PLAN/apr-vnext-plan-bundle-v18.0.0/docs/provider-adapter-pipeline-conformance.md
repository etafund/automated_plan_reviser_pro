# Provider Adapter + Plan Pipeline Conformance

This harness pins the v18 robot surfaces created for provider adapters and the plan pipeline:

- `scripts/xai-deepseek-adapters.py`
- `scripts/claude-codex-adapters.py`
- `scripts/plan-pipeline.py`
- `fixtures/plan-artifact.json`

Run:

```bash
python3 PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/provider-adapter-pipeline-conformance.py --json
```

The harness emits a `json_envelope.v1` object and fails unless every MUST case in `fixtures/conformance/provider-adapter-pipeline-cases.json` passes. It validates command outputs against `contracts/json-envelope.schema.json`, provider result payloads against `contracts/provider-result.schema.json`, and the plan artifact fixture against `contracts/plan-artifact.schema.json`.

The command subprocesses run from `/tmp/apr-v18-provider-adapter-pipeline-conformance` by default so the adapter and pipeline scripts can write their diagnostic logs without leaving generated files in the repository. Override with `APR_V18_CONFORMANCE_WORKDIR` when a different persistent log directory is needed.

Coverage currently includes:

- DeepSeek success provider result, including search/citation and transient reasoning-content invariants.
- xAI success provider result, including high reasoning effort.
- DeepSeek raw reasoning rejection, including the stable `raw_reasoning_leak` error code.
- Provider adapter fixture validation, including rejection of the negative raw-reasoning fixture.
- Codex intake robot surface.
- Claude missing-prompt error surface.
- Plan pipeline `fanout`, `normalize`, `compare`, and `synthesize` robot surfaces.
- Plan artifact fixture schema validation.
