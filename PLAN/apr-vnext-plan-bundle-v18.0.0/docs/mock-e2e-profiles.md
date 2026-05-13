# Mock E2E Profiles

`scripts/mock-e2e-profiles.py` runs the deterministic v18 mock planning journey across `fast`, `balanced`, and `audit` profiles without live provider calls.

Each profile run creates:

- a fixture project with README, spec, implementation notes, and `.apr/` workflow config;
- command stdout/stderr logs for capabilities, route planning, readiness, prompt compile, fanout, normalize, compare, synthesize, bead export, status, and report;
- `.apr/runs/<run_id>/events.jsonl`;
- `profile-summary.json` and `command-transcript.json`;
- artifact summaries for source baseline, prompt context, provider results, browser evidence, Plan IR, comparison, synthesis, traceability, review packet, artifact index, and approvals.

Run all profiles:

```bash
python3 PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/mock-e2e-profiles.py --json
```

Run one profile:

```bash
python3 PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/mock-e2e-profiles.py --json --profile balanced
```

Logs are written under `tests/logs/v18/e2e/<profile>/<run-id>/` by default. The script emits `json_envelope.v1` on stdout and writes human-debuggable artifacts under the log bundle.
