# Robot Busy Contract (`apr_robot_busy.v1`)

Specification for how APR's robot-mode commands (`apr robot run`,
`apr robot validate`, queue runner wrappers) report and respond to
Oracle's single-flight busy state. Implementation lives in
`lib/busy.sh` (detection — bd-3pu) and the `robot_emit_busy` helper in
`apr` (bd-18u).

## Why this contract exists

Robot mode is consumed by orchestrators. Two outcomes are unacceptable:

1. **Stringly-typed scraping.** Forcing automation to grep oracle's
   stderr for `"ERROR: busy"` is brittle — any oracle version bump can
   break every consumer.
2. **Non-deterministic policy.** "Sometimes APR waits, sometimes it
   fails" makes safe orchestration impossible.

This contract pins both: a stable JSON shape AND a documented default
policy with explicit opt-ins for the alternatives.

## Default policy (Option A)

By default, robot mode returns a **structured busy failure
immediately**. No automatic waiting, no automatic enqueue. The caller
chooses whether to retry, wait, or enqueue based on the structured
`policy` field returned.

Two alternatives are opt-in:

| Policy | Trigger | Behavior |
|---|---|---|
| `error` (default) | unset, or `APR_ROBOT_BUSY_POLICY=error` | Return busy JSON immediately, exit non-zero. |
| `wait` | `APR_ROBOT_BUSY_POLICY=wait` | Run the bd-3du wait/backoff loop (capped by `APR_ROBOT_BUSY_TIMEOUT`, default 1800s). On timeout, return busy JSON; on clear, proceed. |
| `enqueue` | `APR_ROBOT_BUSY_POLICY=enqueue` AND queue support compiled in | Append an `enqueue` event to the workflow's queue (bd-3fn) and return `{queue_entry_id, status: "queued"}`. |

The `error` default is deliberately conservative: a wait that's
silently capped at 30 minutes is worse than an immediate, predictable
failure for most orchestrators.

## JSON contract

A robot-mode busy response is a standard APR robot envelope with
`ok=false`, `code="busy"` (taxonomy stable per bd-3tj), and the
following data fields:

```json
{
  "ok": false,
  "code": "busy",
  "data": {
    "busy": true,
    "signature": "<bd-3pu signature name>",
    "line": "<matched stderr line, truncated to 200 bytes>",
    "policy": "error",
    "remote_host": "dev-mbp",
    "retry_after_ms": null,
    "queue_entry_id": null,
    "elapsed_ms": null
  },
  "hint": "Oracle is busy; retry, wait, or enqueue per APR_ROBOT_BUSY_POLICY",
  "meta": { "v": "1.x.x", "ts": "..." }
}
```

### Field semantics

| Field | Type | Meaning |
|---|---|---|
| `busy` | bool | Always `true` for this code. |
| `signature` | string | The bd-3pu signature name that matched (e.g. `error_busy_prefix`, `user_error_parens_busy`, `subject_is_busy`, `kv_busy`). Useful for stats. |
| `line` | string | The first matching stderr line, truncated to 200 bytes. JSON-escaped. Never contains secrets (redacted upstream). |
| `policy` | enum | `error` / `wait` / `enqueue` — the policy that was in effect for this call. |
| `remote_host` | string or null | Slug of the remote oracle host (no credentials), if applicable. |
| `retry_after_ms` | int or null | Best-effort suggested retry delay. `null` when oracle gave no hint. |
| `queue_entry_id` | string or null | When `policy == "enqueue"`, the entry_id of the queued work. Null otherwise. |
| `elapsed_ms` | int or null | When `policy == "wait"`, total time spent waiting before timeout. Null for the `error` path. |

### Exit code

The robot envelope's `code: "busy"` maps to APR exit code 12 (via
`apr_exit_code_for_code`), distinct from `oracle_error` (which would
also exit non-zero but with a different code). Consumers can branch on
exit code alone if they prefer not to parse JSON.

## Implementation surface

`lib/busy.sh` provides the detection (bd-3pu) and the data-block
builder:

```bash
# Echo just the .data object (compact JSON) for a busy envelope.
# Caller wraps it via robot_fail / robot_json with code="busy".
apr_lib_busy_robot_data <stderr_text> [<policy>=error] [<remote_host>] [<retry_after_ms>] [<queue_entry_id>] [<elapsed_ms>]
```

`apr` provides the wrapper:

```bash
# Convenience: run the detector on <stderr_text>; if busy, emit a
# robot_fail envelope with the structured data block; else return 1
# so the caller can fall through to its normal error handling.
robot_emit_busy <stderr_text> [<policy>] [<remote_host>] [<retry_after_ms>] [<queue_entry_id>] [<elapsed_ms>]
```

## Acceptance criteria (codified by tests)

- Given a stderr blob containing `"ERROR: busy"`, `robot_emit_busy`
  emits exit code 12 and a JSON envelope with `code="busy"` AND
  `data.busy=true` AND `data.signature="error_busy_prefix"`.
- Given a stderr blob with NO busy signature, `robot_emit_busy` returns
  1 without emitting anything (caller falls through).
- `policy` defaults to `error`; passing `wait` / `enqueue` is reflected
  in the JSON.
- `remote_host`, `retry_after_ms`, `queue_entry_id`, `elapsed_ms` are
  pass-through fields; the helper never invents values.
- `elapsed_ms`-with-`policy=error` is permitted but discouraged; tests
  pin "null when omitted" for both fields.

## Future work (not in v1)

- `retry_after_ms`: today there's no oracle-side hint we can extract.
  When oracle gains a `Retry-After`-style header equivalent, plumb it
  through the detector + this field.
- `wait` and `enqueue` policy implementations: bd-2kd / bd-12b will
  add these on top of the v1 `error` default.
