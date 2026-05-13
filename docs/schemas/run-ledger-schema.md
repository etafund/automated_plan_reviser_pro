# APR Run Ledger Schema (`apr_run_ledger.v1`)

This document specifies the canonical per-round provenance record APR writes
for every review round. The corresponding JSON Schema is
[`run-ledger.schema.json`](./run-ledger.schema.json); concrete examples live in
[`tests/fixtures/ledger/`](../../tests/fixtures/ledger/).

The writer implementation lives behind bd-1xv; integration into run/robot/queue
paths is bd-1wd. This bead (bd-246) is the schema-only foundation that those
beads target.

## Where the ledger is written

```
.apr/rounds/<workflow>/round_<N>.meta.json
```

One file per round. Replaces any prior file atomically on terminal-state
update (`finished` / `failed` / `canceled`). While in-progress, the file
exists with `state=started` and `finished_at=null`.

## Versioning rules

The `schema_version` field uses an `<artifact>.v<MAJOR>` tag, not full semver.

| Change | Result |
|---|---|
| Add an optional field | Same major (still `apr_run_ledger.v1`). |
| Tighten an enum that was previously open | Same major. |
| Make an optional field required | Major bump. |
| Remove or rename a field | Major bump. |
| Change a field's type | Major bump. |
| Change semantics of an existing value | Major bump. |

Readers MUST:

1. Reject ledgers whose `schema_version` major is unknown to them.
2. Tolerate unknown optional keys at any depth (the JSON Schema sets
   `additionalProperties: false` at the top level for writer discipline, but
   readers should be lenient if they see future-major fields they don't yet
   understand — i.e., readers shouldn't lock to the schema alone).

Writers MUST emit `schema_version` first (purely a stylistic invariant for
diff readability) and MUST NOT omit any field marked required for the current
state.

## State machine

```
                 +-----------+
                 |  started  |    <-- in-flight
                 +-----+-----+
                       |
       ----------------+----------------
       |               |               |
       v               v               v
  +----------+   +----------+   +----------+
  | finished |   |  failed  |   | canceled |
  +----------+   +----------+   +----------+
```

| State | Meaning | `finished_at` | `duration_ms` | `outcome.code` |
|---|---|---|---|---|
| `started` | Oracle invocation kicked off, awaiting completion | `null` | `null` | `running` |
| `finished` | Oracle completed; output written | required | required | `ok` (or a "soft" code like `degraded` if defined later) |
| `failed` | Oracle terminated abnormally or refused to start | required | required | error code from bd-3tj taxonomy |
| `canceled` | Operator/owner canceled before completion | required | required | `canceled` |

The state machine is strictly forward-only. A round may not move from a
terminal state back to `started`. Retries of a failed round write a NEW
ledger with a new `run_id` (the round number may be reused; the run_id may
not).

## Required field semantics

### Identity

- `workflow`: matches the workflow name in `.apr/workflows/<name>.yaml`.
- `round`: 1-based monotonic round number for this workflow.
- `slug`: Oracle session slug. Same value passed to `oracle --slug`.
- `run_id`: opaque, stable, unique per attempt. ULID/UUID recommended. The
  combination `(workflow, round, run_id)` is globally unique within a project.

### Timestamps

- All timestamps are ISO-8601 UTC strings (e.g. `2026-05-12T19:14:00Z`).
- `started_at` is the wall-clock at which APR began the round (after lint, before
  oracle process spawn).
- `finished_at` is the wall-clock at terminal state.
- `duration_ms` is `finished_at - started_at` expressed in milliseconds. It
  MUST equal that difference; downstream tooling may rely on it as the source
  of truth and not recompute from timestamps.

### Inputs

`files[]` records every document considered for inclusion in the prompt
bundle. Entries are stable-sorted by `path`.

| Field | Meaning |
|---|---|
| `path` | Path as written in the workflow yaml (project-relative). |
| `basename` | Basename for display in the prompt manifest. |
| `bytes` | Exact byte size of file contents. |
| `sha256` | Lowercase hex sha256 of file bytes. |
| `inclusion_reason` | One of `required`, `optional`, `impl_every_n`, `skipped`. |
| `skipped_reason` | If `inclusion_reason=skipped`, a short human reason. |

A file that was configured but not on disk is recorded with
`inclusion_reason=skipped` and `bytes=0`, `sha256` set to the sha256 of the
empty byte string (`e3b0c442…b855`) so consumers can rely on the field being
present. The `skipped_reason` MUST be non-null in that case.

### Prompt provenance

- `prompt_hash` is the sha256 of the **final** prompt text — exactly what
  would be pasted to ChatGPT — including any manifest preamble (bd-phj) and
  expanded template directives (bd-1mf).
- `manifest_hash` is optional. When the manifest is generated from
  `files[]` alone, recomputing is cheap; this field is only useful when
  callers want to detect drift between the recorded manifest and the recorded
  files.

### Oracle invocation

`oracle.remote_host` records the *slug* of the remote host (typically a
config key like `dev-mbp` or `lan-server`). It MUST NOT contain
credentials — no tokens, no cookies, no SSH key paths. Writers that
accidentally capture sensitive data are expected to apply the redaction
policy described under `redaction` below.

`oracle.oracle_flags_used` is an optional record of the exact flag *names*
passed to oracle (e.g. `--engine`, `--browser-attachments`, `-m`). Values
follow each flag name in the array, matching argv order. Sensitive values
are redacted before this array is written.

### Outcome

`outcome.ok` is derived but stored explicitly so downstream tooling can
filter without parsing `code`:

```
ok == (state == "finished" && code == "ok")
```

`outcome.code` is a stable string drawn from the error/result code taxonomy
(bd-3tj). The same `code` value MUST appear on the matching robot-mode JSON
envelope's `.code`, so a CLI consumer can join ledger and robot output by
that field alone.

`outcome.output_path` is the path to the round output markdown
(`.apr/rounds/<workflow>/round_<N>.md`). It is `null` for failures that
occurred before any output was written.

### Execution

| Field | Meaning |
|---|---|
| `retries_count` | Full oracle-invocation retries within this run_id. |
| `busy_wait_count` | Number of times busy was detected and waited (bd-3pu). |
| `busy_wait_total_ms` | Cumulative time spent in busy backoff. |

These are zero, not omitted, for runs that didn't retry or wait.

## Optional fields

- `warnings[]`: non-fatal findings produced by the validator (bd-30c). Same
  shape as core validator warnings: `{code, message, hint?, source?}`.
- `overrides[]`: explicit safety bypasses used during this run (e.g.
  `{name: "allow_placeholders", value: true, reason: "intentional"}`).
- `trim`: present only when oversize-trim policy actually fired.
- `redaction`: present only when redaction actually fired. Records the
  redactor identity and a count — never the values themselves.

## Examples

Three concrete fixtures are provided:

| File | State |
|---|---|
| [`tests/fixtures/ledger/started.json`](../../tests/fixtures/ledger/started.json) | `started` (in-flight) |
| [`tests/fixtures/ledger/finished.json`](../../tests/fixtures/ledger/finished.json) | `finished` (happy path) |
| [`tests/fixtures/ledger/failed.json`](../../tests/fixtures/ledger/failed.json) | `failed` (oracle error after one retry and two busy waits) |

A `canceled` fixture is intentionally omitted; its shape is identical to
`failed` with `state=canceled` and a `code` of `canceled`.

## Validating writers

A round ledger is conformant iff:

1. It validates against `run-ledger.schema.json`.
2. Its state-dependent invariants hold:
   - `state=started` ⇒ `finished_at=null` AND `duration_ms=null` AND
     `outcome.code="running"`.
   - `state∈{finished,failed,canceled}` ⇒ `finished_at != null` AND
     `duration_ms != null`.
   - `outcome.ok == (state=="finished" && outcome.code=="ok")`.
3. `files[]` is stably sorted by `path`.

bd-1xv (the writer) is responsible for guaranteeing 2 and 3; the schema
covers 1.
