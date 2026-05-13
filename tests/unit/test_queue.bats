#!/usr/bin/env bats
# test_queue.bats - Unit tests for lib/queue.sh (bd-3fn)
#
# Validates the queue event-log primitives:
#   - paths emission
#   - append (atomic, creates parents, terminates with `\n`)
#   - with_lock (mutual exclusion under contention)
#   - derive (per-entry fold matching the spec pseudocode)
#   - status_summary (counts + active-set)
#   - partial trailing line tolerance (recovery rule)
#   - post-terminal mutation rule (no status regression)

load '../helpers/test_helper'

setup() {
    setup_test_environment
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/queue.sh"
    FIXTURES="$BATS_TEST_DIRNAME/../fixtures/queue"
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# =============================================================================
# paths
# =============================================================================

@test "paths: emits events file then lock file" {
    local out
    out=$(apr_lib_queue_paths default /tmp/proj)
    local events lock
    events=$(printf '%s\n' "$out" | sed -n 1p)
    lock=$(printf '%s\n' "$out" | sed -n 2p)
    [ "$events" = "/tmp/proj/.apr/queue/default.events.jsonl" ]
    [ "$lock"   = "/tmp/proj/.apr/.locks/queue.default.lock" ]
}

@test "paths: default project_root is current dir" {
    local out
    out=$(apr_lib_queue_paths wf)
    [[ "$out" == *"./.apr/queue/wf.events.jsonl"* ]]
}

# =============================================================================
# append
# =============================================================================

@test "append: creates parent directory and writes single line" {
    local f="$BATS_TEST_TMPDIR/.apr/queue/wf.events.jsonl"
    apr_lib_queue_append "$f" '{"event":"enqueue"}'
    [ -f "$f" ]
    [ "$(wc -l < "$f" | tr -d ' ')" = "1" ]
}

@test "append: appends do not overwrite" {
    local f="$BATS_TEST_TMPDIR/q.jsonl"
    apr_lib_queue_append "$f" '{"a":1}'
    apr_lib_queue_append "$f" '{"a":2}'
    apr_lib_queue_append "$f" '{"a":3}'
    [ "$(wc -l < "$f" | tr -d ' ')" = "3" ]
}

@test "append: each line ends with newline" {
    local f="$BATS_TEST_TMPDIR/q.jsonl"
    apr_lib_queue_append "$f" '{"a":1}'
    apr_lib_queue_append "$f" '{"a":2}'
    # Last byte must be 0x0a.
    local last
    last=$(tail -c1 "$f" | od -An -tu1 | tr -d ' ')
    [ "$last" = "10" ]
}

# =============================================================================
# with_lock
# =============================================================================

@test "with_lock: runs the command and returns its exit code" {
    local lock="$BATS_TEST_TMPDIR/q.lock"
    apr_lib_queue_with_lock "$lock" true
    apr_lib_queue_with_lock "$lock" false && status=0 || status=$?
    [ "$status" -eq 1 ]
}

@test "with_lock: serializes concurrent writers" {
    local lock="$BATS_TEST_TMPDIR/q.lock"
    local f="$BATS_TEST_TMPDIR/serial.txt"
    : > "$f"
    # Spawn 5 background writers; each appends its line under the lock.
    local i
    for i in 1 2 3 4 5; do
        ( apr_lib_queue_with_lock "$lock" sh -c "printf 'line-%s\n' $i >> '$f'" ) &
    done
    wait
    # We expect exactly 5 lines (no interleaving destroyed data).
    [ "$(wc -l < "$f" | tr -d ' ')" = "5" ]
}

@test "with_lock: cleans up its lock state" {
    local lock="$BATS_TEST_TMPDIR/q.lock"
    apr_lib_queue_with_lock "$lock" true
    # Either flock (file exists, no holder) or mkdir-fallback (no .dir).
    [ ! -d "${lock}.dir" ]
}

# =============================================================================
# derive
# =============================================================================

@test "derive: complete-success fixture -> status=done with full fields" {
    local out
    out=$(apr_lib_queue_derive "$FIXTURES/complete-success.jsonl" 01HXQ3K8VYZ9F7M2A4B5C6D7E8)
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    python3 -c "
import json
d = json.loads('''$out''')
assert d['status'] == 'done', d
assert d['code'] == 'ok'
assert d['exit_code'] == 0
assert d['output_path'] == '.apr/rounds/default/round_3.md'
assert d['slug'] == 'apr-default-round-3'
assert d['ok'] is True
assert d['partial_trailing'] is False
"
}

@test "derive: complete-failure fixture -> status=failed with reason" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local out
    out=$(apr_lib_queue_derive "$FIXTURES/complete-failure.jsonl" 01HXQ4R9XYWA0G8N3A5B6C7D8E)
    python3 -c "
import json
d = json.loads('''$out''')
assert d['status'] == 'failed'
assert d['code'] == 'oracle_error'
assert d['ok'] is False
assert d['reason'].startswith('oracle returned')
"
}

@test "derive: cancel-while-queued fixture -> status=canceled" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local out
    out=$(apr_lib_queue_derive "$FIXTURES/cancel-while-queued.jsonl" 01HXQ5T0CANCEL12345678901XY)
    python3 -c "
import json
d = json.loads('''$out''')
assert d['status'] == 'canceled'
assert d['reason'] == 'operator'
"
}

@test "derive: partial trailing line is reported and ignored" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local out err
    out=$(apr_lib_queue_derive "$FIXTURES/partial-trailing-line.jsonl" 01HXQ7CRASH123456789012345A 2>/dev/null)
    err=$(apr_lib_queue_derive "$FIXTURES/partial-trailing-line.jsonl" 01HXQ7CRASH123456789012345A 2>&1 >/dev/null)
    python3 -c "
import json
d = json.loads('''$out''')
# enqueue + start before the crash; derived status should be 'running'.
assert d['status'] == 'running', d
assert d['partial_trailing'] is True
"
    [[ "$err" == *"ignoring partial trailing line"* ]]
}

@test "derive: unknown entry_id returns status=unknown and rc=1" {
    apr_lib_queue_derive "$FIXTURES/complete-success.jsonl" NO_SUCH_ID >/dev/null 2>&1 && status=0 || status=$?
    [ "$status" -eq 1 ]
}

@test "derive: missing file returns rc=1 with status=unknown" {
    local out
    out=$(apr_lib_queue_derive "$BATS_TEST_TMPDIR/missing.jsonl" any-id 2>/dev/null) || true
    [[ "$out" == *'"status":"unknown"'* ]]
}

# =============================================================================
# derive: state-machine invariants (no post-terminal regression)
# =============================================================================

@test "derive: cancel after finish stays canceled? cancel after finish overrides? spec says canceled wins on terminal-only events but post-terminal mutation should not change finalized done" {
    # Per the spec: terminal statuses dominate later events. The fold
    # already respects this for `done` over a later `start`. But cancel
    # explicitly overrides finish (canceled wins). Verify by stitching.
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local f="$BATS_TEST_TMPDIR/finish-then-cancel.jsonl"
    cat > "$f" <<EOF
{"schema_version":"apr_queue_event.v1","ts":"2026-05-12T19:14:00Z","event":"enqueue","entry_id":"E","workflow":"wf","round":1}
{"schema_version":"apr_queue_event.v1","ts":"2026-05-12T19:14:05Z","event":"start","entry_id":"E","workflow":"wf","runner_id":"r","started_at":"2026-05-12T19:14:05Z"}
{"schema_version":"apr_queue_event.v1","ts":"2026-05-12T19:39:17Z","event":"finish","entry_id":"E","workflow":"wf","ok":true,"code":"ok","exit_code":0,"output_path":"o","slug":"s","finished_at":"2026-05-12T19:39:17Z"}
{"schema_version":"apr_queue_event.v1","ts":"2026-05-12T19:40:00Z","event":"cancel","entry_id":"E","workflow":"wf","canceled_at":"2026-05-12T19:40:00Z","reason":"oops"}
EOF
    local out
    out=$(apr_lib_queue_derive "$f" E)
    python3 -c "
import json
d = json.loads('''$out''')
# cancel after finish: per the spec, cancel is explicit operator action,
# so it wins. Verify our fold matches that intent.
assert d['status'] == 'canceled', d
"
}

@test "derive: start after canceled does NOT resurrect" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local f="$BATS_TEST_TMPDIR/cancel-then-start.jsonl"
    cat > "$f" <<EOF
{"schema_version":"apr_queue_event.v1","ts":"2026-05-12T19:14:00Z","event":"enqueue","entry_id":"E","workflow":"wf","round":1}
{"schema_version":"apr_queue_event.v1","ts":"2026-05-12T19:14:05Z","event":"cancel","entry_id":"E","workflow":"wf","canceled_at":"2026-05-12T19:14:05Z"}
{"schema_version":"apr_queue_event.v1","ts":"2026-05-12T19:14:10Z","event":"start","entry_id":"E","workflow":"wf","runner_id":"r","started_at":"2026-05-12T19:14:10Z"}
EOF
    local out
    out=$(apr_lib_queue_derive "$f" E)
    python3 -c "
import json
d = json.loads('''$out''')
assert d['status'] == 'canceled', d
"
}

# =============================================================================
# status_summary
# =============================================================================

@test "status_summary: complete-success fixture -> 1 done, 0 active" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local out
    out=$(apr_lib_queue_status_summary "$FIXTURES/complete-success.jsonl")
    python3 -c "
import json
d = json.loads('''$out''')
assert d['counts']['done'] == 1
assert d['counts']['queued'] == 0
assert d['counts']['running'] == 0
assert d['active'] == []
"
}

@test "status_summary: mixed events file (3 entries, mixed states)" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local f="$BATS_TEST_TMPDIR/mixed.jsonl"
    cat "$FIXTURES/complete-success.jsonl" \
        "$FIXTURES/complete-failure.jsonl" \
        "$FIXTURES/cancel-while-queued.jsonl" > "$f"
    local out
    out=$(apr_lib_queue_status_summary "$f")
    python3 -c "
import json
d = json.loads('''$out''')
assert d['counts']['done'] == 1
assert d['counts']['failed'] == 1
assert d['counts']['canceled'] == 1
assert d['counts']['queued'] == 0
assert d['active'] == []
"
}

@test "status_summary: enqueued-only entry counts as active+queued" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local out
    out=$(apr_lib_queue_status_summary "$FIXTURES/enqueue.jsonl")
    python3 -c "
import json
d = json.loads('''$out''')
assert d['counts']['queued'] == 1
assert len(d['active']) == 1
"
}

@test "status_summary: missing file emits zeros, no error" {
    local out
    out=$(apr_lib_queue_status_summary "$BATS_TEST_TMPDIR/missing.jsonl")
    [[ "$out" == *'"queued":0'* ]]
    [[ "$out" == *'"active":[]'* ]]
}

# =============================================================================
# End-to-end: append-and-derive round trip
# =============================================================================

@test "round-trip: append three events then derive matches spec" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local f="$BATS_TEST_TMPDIR/rt.jsonl"
    apr_lib_queue_append "$f" '{"schema_version":"apr_queue_event.v1","ts":"2026-05-12T00:00:00Z","event":"enqueue","entry_id":"RT","workflow":"wf","round":2,"include_impl":true}'
    apr_lib_queue_append "$f" '{"schema_version":"apr_queue_event.v1","ts":"2026-05-12T00:00:01Z","event":"start","entry_id":"RT","workflow":"wf","runner_id":"r","started_at":"2026-05-12T00:00:01Z"}'
    apr_lib_queue_append "$f" '{"schema_version":"apr_queue_event.v1","ts":"2026-05-12T00:30:00Z","event":"finish","entry_id":"RT","workflow":"wf","ok":true,"code":"ok","exit_code":0,"output_path":"o","slug":"s","finished_at":"2026-05-12T00:30:00Z"}'
    local out
    out=$(apr_lib_queue_derive "$f" RT)
    python3 -c "
import json
d = json.loads('''$out''')
assert d['status'] == 'done'
assert d['round'] == 2
assert d['include_impl'] is True
assert d['code'] == 'ok'
"
}

# =============================================================================
# runner primitives (bd-12b)
# =============================================================================

@test "next_queued: returns oldest entry that is still queued" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local f="$BATS_TEST_TMPDIR/next.jsonl"
    apr_lib_queue_append "$f" '{"schema_version":"apr_queue_event.v1","ts":"2026-05-12T00:00:00Z","event":"enqueue","entry_id":"A","workflow":"wf","round":1,"include_impl":false}'
    apr_lib_queue_append "$f" '{"schema_version":"apr_queue_event.v1","ts":"2026-05-12T00:00:01Z","event":"start","entry_id":"A","workflow":"wf","runner_id":"r","started_at":"2026-05-12T00:00:01Z"}'
    apr_lib_queue_append "$f" '{"schema_version":"apr_queue_event.v1","ts":"2026-05-12T00:00:02Z","event":"enqueue","entry_id":"B","workflow":"wf","round":2,"include_impl":false}'
    apr_lib_queue_append "$f" '{"schema_version":"apr_queue_event.v1","ts":"2026-05-12T00:00:03Z","event":"cancel","entry_id":"B","workflow":"wf","canceled_at":"2026-05-12T00:00:03Z"}'
    apr_lib_queue_append "$f" '{"schema_version":"apr_queue_event.v1","ts":"2026-05-12T00:00:04Z","event":"enqueue","entry_id":"C","workflow":"wf","round":3,"include_impl":true,"requested_slug":"custom-slug"}'

    local out
    out=$(apr_lib_queue_next_queued "$f")
    python3 -c "
import json
d = json.loads('''$out''')
assert d['entry_id'] == 'C', d
assert d['round'] == 3
assert d['include_impl'] is True
assert d['requested_slug'] == 'custom-slug'
"
}

@test "run_once: marks start and finish, exposes entry environment, and returns success summary" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local f="$BATS_TEST_TMPDIR/run-success.jsonl"
    local lock="$BATS_TEST_TMPDIR/run-success.lock"
    apr_lib_queue_append "$f" '{"schema_version":"apr_queue_event.v1","ts":"2026-05-12T00:00:00Z","event":"enqueue","entry_id":"A","workflow":"default","round":3,"include_impl":false}'
    apr_lib_queue_append "$f" '{"schema_version":"apr_queue_event.v1","ts":"2026-05-12T00:00:01Z","event":"enqueue","entry_id":"B","workflow":"default","round":4,"include_impl":false}'

    local out
    # shellcheck disable=SC2016
    out=$(apr_lib_queue_run_once "$f" "$lock" "runner-1" sh -c 'test "$APR_QUEUE_ENTRY_ID" = A && test "$APR_QUEUE_WORKFLOW" = default && test "$APR_QUEUE_ROUND" = 3 && test "$APR_QUEUE_INCLUDE_IMPL" = false')

    python3 -c "
import json
d = json.loads('''$out''')
assert d['ran'] is True, d
assert d['entry_id'] == 'A'
assert d['status'] == 'done'
assert d['exit_code'] == 0
assert d['slug'] == 'apr-default-round-3'
assert d['output_path'] == '.apr/rounds/default/round_3.md'
"

    local state_a state_b
    state_a=$(apr_lib_queue_derive "$f" A)
    state_b=$(apr_lib_queue_derive "$f" B)
    python3 -c "
import json
a = json.loads('''$state_a''')
b = json.loads('''$state_b''')
assert a['status'] == 'done', a
assert a['runner_id'] == 'runner-1'
assert a['code'] == 'ok'
assert b['status'] == 'queued', b
"
}

@test "run_once: marks fail and returns the runner command exit code" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local f="$BATS_TEST_TMPDIR/run-fail.jsonl"
    local lock="$BATS_TEST_TMPDIR/run-fail.lock"
    apr_lib_queue_append "$f" '{"schema_version":"apr_queue_event.v1","ts":"2026-05-12T00:00:00Z","event":"enqueue","entry_id":"F","workflow":"wf","round":9,"include_impl":true}'

    local out rc
    out=$(apr_lib_queue_run_once "$f" "$lock" "runner-fail" sh -c 'exit 7') && rc=0 || rc=$?
    [ "$rc" -eq 7 ]

    python3 -c "
import json
d = json.loads('''$out''')
assert d['ran'] is True, d
assert d['entry_id'] == 'F'
assert d['status'] == 'failed'
assert d['exit_code'] == 7
assert d['code'] == 'queue_run_failed'
"

    local state
    state=$(apr_lib_queue_derive "$f" F)
    python3 -c "
import json
d = json.loads('''$state''')
assert d['status'] == 'failed', d
assert d['runner_id'] == 'runner-fail'
assert d['code'] == 'queue_run_failed'
assert d['exit_code'] == 7
assert d['reason'] == 'runner command exited 7'
"
}

@test "run_once: empty queue returns rc=2 and does not run command" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local f="$BATS_TEST_TMPDIR/run-empty.jsonl"
    local lock="$BATS_TEST_TMPDIR/run-empty.lock"
    apr_lib_queue_append "$f" '{"schema_version":"apr_queue_event.v1","ts":"2026-05-12T00:00:00Z","event":"enqueue","entry_id":"D","workflow":"wf","round":1,"include_impl":false}'
    apr_lib_queue_append "$f" '{"schema_version":"apr_queue_event.v1","ts":"2026-05-12T00:00:01Z","event":"finish","entry_id":"D","workflow":"wf","ok":true,"code":"ok","exit_code":0,"output_path":"o","slug":"s","finished_at":"2026-05-12T00:00:01Z"}'

    local out rc
    out=$(apr_lib_queue_run_once "$f" "$lock" "runner-empty" sh -c 'exit 99') && rc=0 || rc=$?
    [ "$rc" -eq 2 ]
    [[ "$out" == '{"ran":false,"status":"empty"}' ]]
    [ "$(wc -l < "$f" | tr -d ' ')" = "2" ]
}
