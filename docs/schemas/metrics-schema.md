# APR Analytics Metrics Schema (`metrics.json`)

This document specifies the per-workflow analytics file APR maintains
at `.apr/analytics/<workflow>/metrics.json`. The corresponding JSON
Schema is [`metrics.schema.json`](./metrics.schema.json); examples live
in [`tests/fixtures/metrics/`](../../tests/fixtures/metrics/).

## Versions

| `schema_version` | Status | Notes |
|---|---|---|
| `1.0.0` | original (fzi.1) | Doc/output/diff metrics + convergence signals. |
| `1.1.0` | bd-2ic | Adds optional per-round `trust` object (manifest hash, ACK status, files-report, ledger presence, redaction/secret counts). |

The bump from 1.0.0 to 1.1.0 is **non-breaking** — every 1.1.0 reader
gracefully handles 1.0.0 files (no `trust` field), and every 1.0.0
reader ignores the new `trust` field. Writers stamp `1.1.0` when they
emit any trust signal.

## Where the file lives

```
<project>/
└── .apr/
    └── analytics/
        └── <workflow>/
            └── metrics.json
```

One file per workflow. Updated by run/robot/queue paths after each
round completes (writer side is bd-2ic's apr-follow-on).

## Top-level shape

```jsonc
{
  "schema_version": "1.1.0",
  "workflow": "default",
  "created_at": "2026-05-12T19:14:00Z",
  "updated_at": "2026-05-12T19:42:33Z",
  "rounds": [ { ... } ],
  "convergence": { ... }
}
```

`rounds[]` is append-only in normal operation. The `convergence` block
is recomputed on each update and may be replaced wholesale.

## Per-round shape

Every round entry MUST have `round` and `timestamp`. The other fields
are recommended but optional; backfill paths may omit data they can't
derive from existing artifacts.

```jsonc
{
  "round": 3,
  "timestamp": "2026-05-12T19:39:17Z",
  "documents": {
    "readme": { "path": "README.md", "char_count": 5420, ... },
    "spec":   { ... },
    "implementation": null
  },
  "output": {
    "path": ".apr/rounds/default/round_3.md",
    "char_count": 8500,
    "word_count": 1400,
    "line_count": 180
  },
  "changes_from_previous": { ... } or null,
  "trust": { ... }                                 // bd-2ic (1.1.0)
}
```

## Trust signals (bd-2ic, schema_version >= 1.1.0)

The `trust` object surfaces provenance and verification signals so
`apr stats` / `apr dashboard` / exports can flag low-trust rounds
without forcing the operator to open the raw round output.

| Field | Type | Source | Meaning |
|---|---|---|---|
| `manifest_present` | bool | bd-3i5 + run ledger | Run included the manifest preamble. |
| `manifest_hash` | hex64 \| null | run ledger | sha256 of the manifest section. |
| `prompt_hash` | hex64 \| null | run ledger | sha256 of the FINAL assembled prompt. |
| `ack_present` | bool | bd-34z `apr_lib_ack_validate` | Model emitted an ACK block. |
| `ack_complete` | bool | bd-34z | Every required doc appears in the block. |
| `ack_matches_manifest` | bool | bd-34z | ACK sha256/bytes match the recorded manifest. |
| `files_report_supported` | bool \| null | bd-1tl | Oracle exposes `--files-report`. |
| `files_report_ok` | bool \| null | bd-1tl | Oracle's report matches the expected attachment set. |
| `files_report_mismatch` | object \| null | bd-1tl | Per-class mismatch detail (missing/extra/size_mismatch). |
| `ledger_present` | bool | bd-246 + bd-1xv | Round's `meta.json` file exists. |
| `ledger_schema_version` | string \| null | bd-246 | The schema_version value from the round's ledger. |
| `secret_detected_count` | int \| null | bd-1eq | Number of `secret_detected` warnings produced for the run. |
| `redaction_count` | int \| null | bd-3ut | Number of redactions applied by lib/redact.sh. |
| `low_trust` | bool | derived | `true` iff ANY of: `manifest_present==false`, `ack_present==false`, `ack_matches_manifest==false`, `files_report_ok==false`, `ledger_present==false`. |

`low_trust` is the single field consumers should branch on for
"highlight this round as suspect." Renderers that want finer detail
inspect the underlying booleans.

## Derivation rules (`low_trust`)

`low_trust` is computed by the metrics writer at update time. Pseudocode:

```python
def low_trust(t):
    # Required signals must be present-and-true.
    for required_true in ("manifest_present", "ack_present",
                          "ack_matches_manifest", "ledger_present"):
        if t.get(required_true) is False:
            return True
    # files_report_ok is conditional on files_report_supported.
    if t.get("files_report_supported") is True and t.get("files_report_ok") is False:
        return True
    return False
```

Note that `null` signals never trip `low_trust` — the renderer should
display "unknown" rather than "low trust" when the underlying
detection didn't run.

## Examples

| File | Scenario |
|---|---|
| [`tests/fixtures/metrics/clean-round.json`](../../tests/fixtures/metrics/clean-round.json) | 1.1.0 with full trust (all booleans true, `low_trust=false`). |
| [`tests/fixtures/metrics/low-trust-round.json`](../../tests/fixtures/metrics/low-trust-round.json) | 1.1.0 where `ack_matches_manifest=false` and `files_report_mismatch` carries the diff. |
| [`tests/fixtures/metrics/legacy-1.0.0.json`](../../tests/fixtures/metrics/legacy-1.0.0.json) | 1.0.0 (pre-bd-2ic) with no `trust` block — readers MUST still parse cleanly. |

## Writer-side checklist (follow-on)

bd-2ic's apr-side wiring (separate work) needs to:

- Stamp `schema_version: "1.1.0"` once any trust signal is emitted.
- Populate `trust.manifest_present` + `manifest_hash` + `prompt_hash`
  from the run ledger (bd-246).
- Populate `trust.ack_*` from `apr_lib_ack_validate` output (bd-34z).
- Populate `trust.files_report_*` from the bd-1tl wrapper.
- Populate `trust.ledger_present` + `ledger_schema_version` by
  stat-ing the meta.json file.
- Populate `trust.secret_detected_count` from the lint pass count of
  `secret_detected` warnings (bd-1eq).
- Populate `trust.redaction_count` from `APR_REDACT_COUNT` set by
  `apr_lib_redact_prompt` (bd-3ut).
- Compute `trust.low_trust` per the derivation rule above.
- Update `apr stats` / `apr dashboard` rendering to show a `[LOW
  TRUST]` tag (with the failing signal name) when `low_trust=true`.

Backfill: for existing rounds without a ledger, the writer emits
`{ledger_present: false, manifest_present: false, ledger_schema_version: null}`
and infers other signals as `null`.

## Backwards compatibility

- 1.0.0 readers see 1.1.0 files unchanged — they ignore the `trust`
  field (because `additionalProperties: true` on the round shape).
- 1.1.0 readers see 1.0.0 files without crashing — `trust` is
  optional; missing means "no trust info" which renderers display as
  "unknown" rather than "low trust."
- Bumping `schema_version` past 1.1.0 requires a new bead and a
  written compatibility note.
