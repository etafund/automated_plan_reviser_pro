# APR Core Contracts (Specification)

This document specifies the core contracts APR commits to across human
mode, robot mode, and the queue runner. Each section pins a stable
interface and points to the schemas/fixtures that codify it.

The aim is: **operators can adopt features intentionally, and
automation can branch on stable fields rather than scraping free-form
output.**

---

## Manifest

Every prompt assembled by APR includes a deterministic preamble
identifying the documents bundled with it.

### Format

```
[APR Manifest]
Included files:

  README.md
    path:   README.md
    size:   72847 bytes
    sha256: 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08
    reason: required

  SPECIFICATION.md
    path:   SPECIFICATION.md
    size:   41832 bytes
    sha256: 2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae
    reason: required

Skipped files:

  IMPLEMENTATION.md
    path:   docs/implementation.md
    reason: skipped (not-due-yet)
```

### Semantics

- Stable LC_ALL=C-sorted by path within each section.
- `reason` enum: `required` / `optional` / `impl_every_n` / `skipped`.
- Skipped entries always carry a `skipped_reason` (e.g. `not-due-yet`,
  `missing`, `not-included-this-round`).
- The same manifest is the input to the model AND the basis of the ACK
  / metrics trust signals.

### Disabling

Set `APR_NO_MANIFEST=1`. Output reverts to pre-vNext behavior
byte-for-byte. Not recommended for runs you'd ever want to audit.

### See also

- Renderer: `lib/manifest.sh` → `apr_lib_manifest_render_text`
- JSON form: `apr_lib_manifest_render_json` (consumed by ledger `files[]`)
- Wired by: `build_revision_prompt` in `apr` (bd-3i5)

---

## Run Ledger

`apr_run_ledger.v1` (JSON Schema:
`docs/schemas/run-ledger.schema.json`). One file per round at
`.apr/rounds/<workflow>/round_<N>.meta.json`.

### State machine

```
                 +-----------+
                 |  started  |
                 +-----+-----+
                       |
       ----------------+----------------
       |               |               |
       v               v               v
  +----------+   +----------+   +----------+
  | finished |   |  failed  |   | canceled |
  +----------+   +----------+   +----------+
```

### Required fields

- Identity: `workflow`, `round`, `slug`, `run_id`
- Timing: `started_at`, optionally `finished_at` and `duration_ms`
- State: `state` (enum above)
- Inputs: `files[]` (path, basename, bytes, sha256, inclusion_reason),
  `prompt_hash` (sha256 of final prompt text)
- Oracle: `oracle.{engine, model}` plus optional `thinking_time`,
  `remote_host` (slug only — NEVER credentials), `oracle_flags_used[]`
  (sanitized)
- Outcome: `outcome.{ok, code, exit_code, output_path}` where
  `code` matches the robot-mode error taxonomy (bd-3tj)
- Execution: `execution.{retries_count, busy_wait_count,
  busy_wait_total_ms}`

### Writer guarantees

- Atomic via `<path>.tmp.<pid>` + rename in the SAME directory.
- Secret patterns redacted before persistence (`lib/ledger.sh`).
- Crash mid-round leaves `state=started` with `outcome.code=running`
  so doctor / queue runner can detect stale runs.

### See also

- Schema: `docs/schemas/run-ledger.schema.json` + `run-ledger-schema.md`
- Fixtures: `tests/fixtures/ledger/{started,finished,failed}.json`
- Writer: `lib/ledger.sh` (bd-1xv)

---

## Error Taxonomy (bd-3tj)

A stable code is emitted on every fatal/non-fatal outcome surface so
automation can branch without scraping stderr.

| `code` | Exit | Meaning |
|---|---:|---|
| `ok` | 0 | Success |
| `usage_error` | 2 | Bad CLI args / missing required argument |
| `dependency_missing` | 3 | Oracle / npx / required binary not found |
| `not_configured` | 5 | `.apr/` not initialized |
| `config_error` | 4 | Workflow yaml / document path invalid |
| `validation_failed` | 4 | Lint gate failure (placeholder leak, prompt QC, etc.) |
| `prompt_qc_failed` | 4 | Specifically a residue / placeholder leak in the assembled prompt |
| `secret_detected` | 4 | bd-1eq scanner flagged a likely secret (in strict mode) |
| `template_engine_error` | 4 | Directive expansion failed (path, unknown TYPE, etc.) |
| `oracle_error` | 2 | Oracle exited non-zero for a non-busy reason |
| `network_error` | 10 | Remote/network operation failed |
| `update_error` | 11 | Self-update failed |
| `busy` | 12 | Oracle single-flight contention; APR waited but the budget exhausted |
| `attachment_mismatch` | 4 | files-report verification (bd-1tl) found drift |
| `not_implemented` | 9 | Feature stub |
| `internal_error` | 9 | Unexpected internal failure |

Robot envelopes:

```json
{
  "ok":   false,
  "code": "validation_failed",
  "data": { },
  "hint": "Remove {{...}} from the workflow template, or set APR_ALLOW_CURLY_PLACEHOLDERS=1 to bypass.",
  "meta": { "v": "1.2.2", "ts": "2026-05-12T19:14:00Z" }
}
```

Human stderr fatal frames also include the literal tag:

```
APR_ERROR_CODE=validation_failed
```

so log scrapers can pick up the same code without parsing JSON.

### See also

- Mapping: `apr_exit_code_for_code` in `apr`
- Robot envelope: `robot_json` / `robot_fail` in `apr`
- Tests: `tests/integration/test_error_contract.bats`

---

## Lint Gate

`apr lint` is the canonical pre-run validation gate. The same logic
runs automatically before every `apr run` / `apr robot run` unless
explicitly bypassed.

### Surface

- `apr lint [--workflow NAME] [--round N]` — human output on stderr,
  exit code from the taxonomy above.
- `apr robot lint [--round N]` — JSON envelope; `data.errors[]` and
  `data.warnings[]` carry `{code, message, hint, source, details}`.

### Bypass

- `--no-lint` — explicit, noisy bypass. Prints a warning on stderr.
  Recorded as an override in the ledger when ledger writes land.
- `--fail-on-warn` / `APR_FAIL_ON_WARN=1` — strict mode. Every warning
  is promoted to a blocking error via `apr_lib_validate_finalize_strict`.
- `APR_ALLOW_CURLY_PLACEHOLDERS=1` — narrow: disables mustache
  placeholder detection only. Other QC + secret + doc-size checks
  remain active.
- `APR_QC_RESPECT_CODE_FENCES=0` — narrow: forces checks INSIDE
  triple-backtick fenced regions. Strict mode auto-sets this.

### See also

- Library: `lib/validate.sh` (bd-30c)
- Gate: `run_lint_gate` (cmd_run) + `robot_lint_gate` (robot_run)
- Tests: `tests/unit/test_validate.bats`, `tests/unit/test_lint_gate.bats`

---

## Busy Handling

Oracle single-flight (`ERROR: busy`) is detected and routed through a
dedicated backoff path so concurrent rounds smooth over instead of
failing.

### Detection signatures

The bd-3pu signature catalog covers:
- `^ERROR:\s*busy` (line-anchored)
- `User error (<engine>): busy`
- `<oracle|browser|session|provider|chatgpt> is busy`
- `(retry|status|state|reason)\s*[:=]\s*busy` key-value shapes

False-positive guards: `busylight`, `busyness`, `busy_loop` are NOT
matched (boundary-aware).

### Backoff knobs

| Env var | Default | Meaning |
|---|---|---|
| `APR_BUSY_MAX_RETRIES` | 10 | Max busy retries per attempt |
| `APR_BUSY_INITIAL_BACKOFF` | 30s | First sleep |
| `APR_BUSY_MAX_SLEEP` | 600s | Per-iteration cap |
| `APR_BUSY_MAX_WAIT` | 1800s (0 = disabled) | Total budget |
| `APR_ROBOT_BUSY_POLICY` | `error` | `error` / `wait` / `enqueue` |

### Robot envelope on exhaustion

```json
{
  "ok":   false,
  "code": "busy",
  "data": {
    "busy": true,
    "signature": "error_busy_prefix",
    "line": "ERROR: busy",
    "policy": "error",
    "remote_host": "dev-mbp",
    "retry_after_ms": null,
    "queue_entry_id": null,
    "elapsed_ms": 95000
  },
  "hint": "Oracle is busy; retry, wait, or enqueue per APR_ROBOT_BUSY_POLICY"
}
```

### See also

- Detector: `lib/busy.sh` (bd-3pu)
- Wait loop: `lib/busy_wait.sh` (bd-3du)
- Apr wiring: `run_oracle_with_retry` (bd-2kd)
- Robot contract: `docs/schemas/robot-busy.md` (bd-18u)

---

## Queue

Persistent per-workflow queue for serializing many rounds against
single-flight Oracle.

### Storage

```
.apr/
├── queue/
│   └── <workflow>.events.jsonl    # append-only event log
└── .locks/
    └── queue.<workflow>.lock      # flock mutex
```

### Event schema

`apr_queue_event.v1` (see
`docs/schemas/queue-events.{schema.json,md}`).
Five event kinds: `enqueue` / `start` / `finish` / `fail` / `cancel`.
State for an entry is derived by folding events in append order.

### Commands

```bash
apr queue add <round>            # enqueue
apr queue add <round> -i         # with --include-impl
apr queue status                 # counts + recent activity
apr queue cancel <entry_id>      # non-destructive
apr queue run                    # process until empty
apr queue run --once             # process one entry
apr queue run --max N            # safety cap
```

Robot equivalents:

```bash
apr robot queue add <round>
apr robot queue status
apr robot queue cancel <entry_id>
apr robot queue run --once
```

### Crash semantics

- Partial trailing line is detected and ignored on read (recorded in
  derived state as `partial_trailing: true`).
- Stale `running` entries (runner died) are surfaced by the doctor
  command and can be re-queued or marked failed by the operator.
- All mutations take an exclusive flock (30s timeout); reads are
  lock-free and tolerate the partial-line case.

### See also

- Library: `lib/queue.sh` (bd-3fn data model + bd-12b runner)
- CLI wiring: bd-18g (commands)
- Tests: `tests/unit/test_queue.bats`

---

## Trust Signals & Metrics

Per-round metrics include a `trust` block surfacing whether the run is
auditable + correctly bound.

### Block shape (metrics.json v1.1.0)

```json
"trust": {
  "manifest_present":     true,
  "manifest_hash":        "<hex64>",
  "prompt_hash":          "<hex64>",
  "ack_present":          true,
  "ack_complete":         true,
  "ack_matches_manifest": true,
  "files_report_supported": true,
  "files_report_ok":        true,
  "files_report_mismatch":  null,
  "ledger_present":         true,
  "ledger_schema_version":  "apr_run_ledger.v1",
  "secret_detected_count":  0,
  "redaction_count":        0,
  "low_trust":              false
}
```

`low_trust` is the single field consumers should branch on for
"highlight this round as suspect." It's derived as:

```
low_trust = manifest_present == false
         OR ack_present == false
         OR ack_matches_manifest == false
         OR ledger_present == false
         OR (files_report_supported == true AND files_report_ok == false)
```

`null` values never trip `low_trust` — the renderer should display
"unknown" rather than "low trust" when the underlying detection didn't
run.

### See also

- Schema: `docs/schemas/metrics.schema.json` + `metrics-schema.md`
- Fixtures: `tests/fixtures/metrics/{clean,low-trust,legacy-1.0.0}.json`
- ACK lib: `lib/ack.sh` (bd-34z)
- Files-report lib: `lib/files_report.sh` (bd-1tl/bd-1oh)

---

## Strict Mode

`--fail-on-warn` / `APR_FAIL_ON_WARN=1` is a single knob that escalates
EVERY warning class to a blocking error before the run begins. Designed
for CI / robot orchestration where any low-trust signal should refuse
to spend Oracle budget.

What flips to fatal:
- Doc-size policy warnings (per-role bytes thresholds, bd-zd6)
- "Not filled" markers (`TODO:` / `<REPLACE_ME>` / `${VAR}`, bd-2lc + bd-64dh)
- Mustache placeholders inside code fences (normally ignored)
- APR directive residue inside code fences (normally ignored)
- Secret scan findings (bd-1eq)

Implemented via `apr_lib_validate_finalize_strict` which copies every
recorded warning into the errors bucket (preserving the audit trail).

---

## Versioning of contracts

| Contract | Version | File |
|---|---|---|
| Run ledger | `apr_run_ledger.v1` | `docs/schemas/run-ledger.schema.json` |
| Queue event | `apr_queue_event.v1` | `docs/schemas/queue-events.schema.json` |
| Metrics | `1.1.0` (was `1.0.0` pre-bd-2ic) | `docs/schemas/metrics.schema.json` |
| Template directive | `apr_template.v1` | `docs/schemas/template-directives.md` |
| Robot envelope | `1.x` (per-build) | exposed via `meta.v` |
| Robot busy data | `apr_robot_busy.v1` | `docs/schemas/robot-busy.md` |

Schema bumps follow `<artifact>.v<MAJOR>` tagging. Readers MUST reject
unknown majors. Writers MUST emit the current major.

---

## Privacy & Safety

- No prompt content is ever transmitted to a third party besides ChatGPT
  via Oracle.
- The ledger redacts known credential shapes (`Bearer …`, `sk-…`, `ghp_…`,
  `xox[bpars]-…`, `AKIA…`, `Authorization: …`, `--token …`, `--api-key …`,
  `password=…`, `secret=…`) before any commit.
- Optional `APR_REDACT=1` substitutes the same patterns IN THE PROMPT
  before Oracle is invoked. Substituted with typed sentinels
  (`<<REDACTED:OPENAI_KEY>>` etc.) for auditability.
- `apr_lib_validate_secret_scan` warns on the same patterns at lint
  time so operators see them before the run.
- Strict mode (`APR_FAIL_ON_WARN=1`) refuses runs on detected
  secrets.

See `lib/redact.sh` (bd-3ut), `lib/validate.sh:apr_lib_validate_secret_scan`
(bd-1eq), `lib/ledger.sh:apr_lib_ledger_redact` (bd-1xv).
