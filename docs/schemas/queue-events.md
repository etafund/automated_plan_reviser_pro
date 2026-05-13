# APR Queue Event Log (`apr_queue_event.v1`)

This document specifies the **append-only event log** that backs APR's
per-workflow queue. The corresponding JSON Schema is
[`queue-events.schema.json`](./queue-events.schema.json); concrete examples
live in [`tests/fixtures/queue/`](../../tests/fixtures/queue/).

The runner behaviour (popping events, dispatching to oracle) is bd-12b;
the CLI surface (`apr queue …`) is bd-18g. This bead (bd-3fn) is the
data-model foundation those two depend on.

## Why an event log instead of a single state file

APR's queue must be:

- **durable** — survive crashes mid-update.
- **audit-friendly** — never silently delete history.
- **safe under concurrent access** — runner + status + cancel may all
  touch the queue simultaneously.

A canonical state file rewritten via `tmp + rename` would meet the
crash-safety bar but throws away the audit trail. We choose an
append-only events log so cancellation, restarts, and out-of-band
operator action are all reconstructible.

The fallback strategy (atomic-rewrite state file with separate audit
log) is documented in bd-3fn's bead description; it is **not** the
shipped design.

## File layout

```
<project>/
└── .apr/
    ├── queue/
    │   ├── <workflow>.events.jsonl
    │   └── <workflow>.derived.json    # optional; rebuilt from events
    └── .locks/
        └── queue.<workflow>.lock
```

- One events file per workflow, JSON Lines (one JSON object per `\n`-terminated line).
- The lock file gates ALL mutation. Reads may be lock-free.
- `derived.json` is an optional convenience cache that runners may
  maintain — but the events file is the source of truth, and any
  consumer MUST be able to recompute state by folding events alone.

## Event schema

Every line is a JSON object matching
[`queue-events.schema.json`](./queue-events.schema.json). The five
event kinds are:

| `event` | When emitted | Required fields (beyond the always-required `schema_version`, `ts`, `event`, `entry_id`, `workflow`) |
|---|---|---|
| `enqueue` | new entry created | `round` (plus optional `include_impl`, `requested_slug`) |
| `start` | runner picks up entry | `runner_id`, `started_at` |
| `finish` | round completed successfully | `ok=true`, `code="ok"`, `exit_code=0`, `output_path`, `slug`, `finished_at` |
| `fail` | round terminated abnormally | `ok=false`, `code=<taxonomy>`, `exit_code`, `slug?`, `finished_at`, `reason?` |
| `cancel` | operator (or runner) canceled | `canceled_at`, `reason?` |

All timestamps are ISO-8601 UTC strings. `entry_id` is opaque,
recommended to be a ULID or UUID. The combination `(workflow, entry_id)`
is globally unique within a project.

### Field rules

- `code` values MUST come from the bd-3tj taxonomy. The same code that
  appears on the matching robot envelope's `.code` MUST appear here.
- `stderr_digest` is the lowercase hex sha256 of the **last 32 KB** of
  stderr (tail, not head — the tail is where the actual failure usually
  lives). The full stderr is not stored.
- `reason` is free-form and human-readable; it MUST NOT contain
  credentials. The redaction policy in `lib/ledger.sh` applies.
- `slug` on `finish` and `fail` records the actual oracle slug used
  (which may differ from `requested_slug`).

## State derivation

Current state for an `entry_id` is computed by folding events in append
order. Pseudocode:

```python
def derive(entry_id, events):
    state = {"status": None, "events": []}
    for e in events:
        if e["entry_id"] != entry_id: continue
        state["events"].append(e)
        if e["event"] == "enqueue":
            state["status"] = "queued"
            state["round"]  = e["round"]
            state["include_impl"] = e.get("include_impl", False)
            state["requested_slug"] = e.get("requested_slug")
        elif e["event"] == "start":
            state["status"] = "running"
            state["runner_id"] = e["runner_id"]
            state["started_at"] = e["started_at"]
        elif e["event"] == "finish":
            state["status"] = "done"
            state["finished_at"] = e["finished_at"]
            state["ok"] = True
            state["code"] = e["code"]
            state["exit_code"] = e["exit_code"]
            state["output_path"] = e["output_path"]
            state["slug"] = e["slug"]
        elif e["event"] == "fail":
            state["status"] = "failed"
            state["finished_at"] = e["finished_at"]
            state["ok"] = False
            state["code"] = e["code"]
            state["exit_code"] = e["exit_code"]
            state["reason"] = e.get("reason")
        elif e["event"] == "cancel":
            state["status"] = "canceled"
            state["canceled_at"] = e["canceled_at"]
            state["reason"] = e.get("reason")
    return state
```

### Status precedence

Terminal statuses generally dominate later events: once an entry reaches
`done`, `failed`, or `canceled`, subsequent events for the same
`entry_id` are recorded (audit trail preserved) but generally MUST NOT
change the derived status. Two specific overrides apply:

1. **`cancel` always wins.** A `cancel` event recorded after `finish` or
   `fail` flips the derived status to `canceled`. This models operator
   action: "I want this entry expressly marked canceled regardless of
   how the runner classified it." The original `finish` / `fail` event
   stays in the log for audit.
2. **`start` after a terminal status is ignored.** A late `start` (for
   example, a confused runner re-claiming an entry) must NOT resurrect
   a `done` / `failed` / `canceled` entry to `running`. Lints SHOULD
   warn on this pattern.

Active vs terminal:

Active vs terminal:

| Status | Kind |
|---|---|
| `queued` | active |
| `running` | active |
| `done` | terminal |
| `failed` | terminal |
| `canceled` | terminal |

## Lock semantics

`.apr/.locks/queue.<workflow>.lock` is the per-workflow mutation lock.
Implementations:

- **Mutations** (`enqueue` / `start` / `finish` / `fail` / `cancel`):
  acquire an exclusive lock via `flock -x` (or `mkdir`-fallback on
  systems without `flock`), append the event, fsync the events file,
  release the lock.
- **Reads** (deriving state, listing queued entries) MAY skip the lock
  entirely. Readers MUST tolerate a truncated last line (see
  Corruption handling below).
- Lock acquisition MUST have a timeout (recommended: 30s) to prevent
  permanent stalls.
- The lock file itself is empty. Its presence on disk does not by
  itself indicate "queue in use" — only a held `flock` does.

## Corruption handling

The events file is append-only, but a crash mid-write can leave a
partial trailing line. Recovery rules:

1. When reading: if the last line is not terminated with `\n` OR fails
   JSON parse, treat it as a partial write. Ignore that line; emit a
   warning via the standard validator (`lib/validate.sh`) with
   `code=queue_partial_event`. Do NOT delete the line — the doctor
   command (separate bead) handles cleanup.
2. When writing: append the new line in a single `write(2)` of the
   complete `<json>\n` payload. `printf '%s\n' "$json" >> file`
   followed by `sync` is sufficient on Linux for sizes under the
   pipe-atomic write cap (4096 bytes on most systems). Lines longer
   than 4 KB MUST split across pipe boundaries and use the lock to
   serialize against readers.
3. Two distinct events written between fsyncs are both visible; this
   is intentional and matches the audit goal.

## Crash semantics

- If APR crashes between `enqueue` and `start`: the entry stays in
  `queued`; on next runner startup it is picked up normally.
- If APR crashes between `start` and `finish`/`fail`: the entry's
  derived state is `running`. The runner doctor (separate bead) detects
  stale runs via heartbeat timeouts and emits a synthetic `fail` event
  with `code=runner_lost`.
- If APR crashes mid-write: the partial line is ignored per the
  corruption rule above.

## Examples

See [`tests/fixtures/queue/`](../../tests/fixtures/queue/) for concrete
event-stream fixtures:

| File | Scenario |
|---|---|
| `enqueue.jsonl` | One entry enqueued, not yet started |
| `complete-success.jsonl` | enqueue → start → finish (happy path) |
| `complete-failure.jsonl` | enqueue → start → fail (oracle error) |
| `cancel-while-queued.jsonl` | enqueue → cancel |
| `partial-trailing-line.jsonl` | crash-mid-write trailing partial line |

## Acceptance criteria checklist

For implementers of bd-12b (runner) and bd-18g (CLI):

- [ ] All mutating commands take the per-workflow lock.
- [ ] Every state-changing operation appends a single event line.
- [ ] State derivation matches the pseudocode above byte-for-byte.
- [ ] Readers tolerate a partial trailing line without crashing.
- [ ] Post-terminal events do not alter the derived status.
- [ ] `code` values match the bd-3tj taxonomy and the matching robot
      envelope.
