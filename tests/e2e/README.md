# APR E2E Tests

## Oracle Remote Smoke

`oracle_remote_smoke.sh` is an opt-in live diagnostic for remote Oracle mode. It is not run by CI.

Required environment:

```bash
export ORACLE_REMOTE_HOST="host:port"
export ORACLE_REMOTE_TOKEN="..."
```

For pool testing:

```bash
export ORACLE_REMOTE_POOL="host1:port,host2:port"
export ORACLE_REMOTE_TOKEN="..."
```

Run:

```bash
tests/e2e/oracle_remote_smoke.sh
```

The script writes a timestamped bundle under `tests/logs/oracle_remote_smoke/` containing redacted env, network checks, `apr doctor`, `apr lint`, dry-run evidence, Oracle status snapshots, and the live `apr run` logs. It refuses the live run if APR dry-run output does not show `--remote-host` and `--remote-token`, which prevents accidentally falling back to local browser automation.
