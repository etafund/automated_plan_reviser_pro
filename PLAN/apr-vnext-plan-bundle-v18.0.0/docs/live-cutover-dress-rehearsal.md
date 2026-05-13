# Live Cutover Dress Rehearsal

`scripts/live-cutover-dress-rehearsal.py` is the v18 opt-in gate for real browser/API route validation. By default it only evaluates the checklist and writes a redacted report under `tests/logs/v18/live/`.

Live execution requires all of the following:

- `--approval-id <id>`
- `--execute-live`
- `APR_V18_LIVE_CUTOVER=1`
- remote Oracle environment such as `ORACLE_REMOTE_HOST` plus `ORACLE_REMOTE_TOKEN`

The output always carries `live_mock_discriminator`. Dry runs use `DRY_RUN_NOT_LIVE`; live attempts use `LIVE_EXECUTION_REQUESTED`. Token values are not persisted, only presence booleans.

Example dry run:

```bash
python3 PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/live-cutover-dress-rehearsal.py \
  --json \
  --approval-id APR-LIVE-001
```

Example live invocation:

```bash
APR_V18_LIVE_CUTOVER=1 \
ORACLE_REMOTE_HOST=host:port \
ORACLE_REMOTE_TOKEN=... \
python3 PLAN/apr-vnext-plan-bundle-v18.0.0/scripts/live-cutover-dress-rehearsal.py \
  --json \
  --approval-id APR-LIVE-001 \
  --execute-live
```

The live path delegates to `tests/e2e/oracle_remote_smoke.sh`, preserving that script's redacted log bundle while adding v18 route, approval, evidence, and artifact-index metadata.
