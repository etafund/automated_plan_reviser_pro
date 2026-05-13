# Live Cutover Operator Guide

> Bundle version: v18.0.0

Live cutover is opt-in. Mock validation proves contract shape only; it does not prove browser availability, provider mode correctness, or synthesis eligibility.

## Mock rehearsal

Run the local mock journey first:

```bash
python3 scripts/apr-mock.py capabilities --json
python3 scripts/apr-mock.py plan-routes --json
python3 scripts/apr-mock.py readiness --json
python3 scripts/apr-mock.py compile --json
python3 scripts/apr-mock.py fanout --json
python3 scripts/apr-mock.py report --json
```

The mock journey must remain clearly labeled as mock output. Do not attach mock provider results as live evidence.

## Dry-run cutover checklist

Run the live cutover rehearsal without provider execution:

```bash
python3 scripts/live-cutover-dress-rehearsal.py --json --approval-id dry-run-docs
```

The output should label `live_execution=false` and `live_mock_discriminator=DRY_RUN_NOT_LIVE`.

## Live execution guard

A real live smoke requires both an approval id and the live environment switch:

```bash
APR_V18_LIVE_CUTOVER=1 python3 scripts/live-cutover-dress-rehearsal.py --json --approval-id <approval-id> --execute-live
```

Before running it, verify:

- Oracle browser endpoint is reachable.
- Provider docs snapshot is fresh.
- Required browser slots can produce redacted evidence.
- API keys are present for optional API reviewers that will be used.
- The operator has accepted the cost and time of live provider calls.

## Release gate

The minimum release gate is `phase_5_balanced_live_dress_rehearsal` from `fixtures/live-cutover-checklist.json`. Do not mark balanced or audit ready for users before that gate passes.

## Failure handling

If the rehearsal fails, keep the generated log bundle and branch on the JSON envelope:

- `blocked_reason`
- `next_command`
- `fix_command`
- `retry_safe`
- `data.log_bundle`

Do not hide live cutover failures behind a successful mock run.
