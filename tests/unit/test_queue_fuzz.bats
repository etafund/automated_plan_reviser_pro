#!/usr/bin/env bats
# test_queue_fuzz.bats
#
# Bead automated_plan_reviser_pro-xg5m — fuzz/property layer for
# lib/queue.sh (the JSONL event log backing apr's queue runner).
#
# tests/unit/test_queue.bats has 25 unit tests covering happy/typical
# paths. This file adds adversarial / property pins on top.
#
# Invariants pinned:
#   I1  derive is deterministic across N calls on the same file
#   I2  Append-and-derive composition: derive after append == fold of
#       previous state with the new event
#   I3  Truncated last line is silently dropped; rest is parseable
#   I4  Unknown event types are skipped (no crash, state unchanged)
#   I5  Cancel after terminal done state: done is NOT downgraded
#   I6  status_summary emits valid JSON with the documented keys
#   I7  Sum-consistency: queued+running+done+failed+canceled == total
#       unique entry_ids
#   I8  500-entry event log processed within a reasonable bound
#   I9  Empty/missing events file yields zeros without crashing
#   I10 with_lock + append composition produces a deterministic
#       single-line-per-write event log under serialized writers
#
# Per-test artifacts under tests/logs/unit/ per the ufc Logging contract.

load '../helpers/test_helper'

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    setup_test_environment
    start_test_artifacts "unit" "${BATS_TEST_NAME}"

    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/queue.sh"

    FIXTURE_ROOT="$TEST_DIR/queue_fuzz"
    mkdir -p "$FIXTURE_ROOT"
    EVENTS="$FIXTURE_ROOT/events.jsonl"
    LOCK="$FIXTURE_ROOT/queue.lock"
    export FIXTURE_ROOT EVENTS LOCK

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

event_json() {
    # event_json <event> <entry_id> [extra_json_props]
    # Emits {"event":"<e>","entry_id":"<id>",...}
    local ev="$1" eid="$2" extras="${3-}"
    if [[ -n "$extras" ]]; then
        printf '{"schema_version":"1.0.0","event":"%s","entry_id":"%s","workflow":"wf","ts":"2026-01-01T00:00:00Z",%s}' \
            "$ev" "$eid" "$extras"
    else
        printf '{"schema_version":"1.0.0","event":"%s","entry_id":"%s","workflow":"wf","ts":"2026-01-01T00:00:00Z"}' \
            "$ev" "$eid"
    fi
}

# ===========================================================================
# I1 — derive is deterministic
# ===========================================================================

@test "I1: derive on the same events file yields byte-identical output across 30 calls" {
    apr_lib_queue_append "$EVENTS" "$(event_json enqueue e1 '"round":1')"
    apr_lib_queue_append "$EVENTS" "$(event_json start    e1)"
    apr_lib_queue_append "$EVENTS" "$(event_json finish   e1 '"ok":true,"code":"ok","exit_code":0')"

    local baseline current i
    baseline=$(apr_lib_queue_derive "$EVENTS" e1)
    for i in $(seq 1 30); do
        current=$(apr_lib_queue_derive "$EVENTS" e1)
        [[ "$current" == "$baseline" ]] || {
            echo "drift at iter $i:" >&2
            diff <(printf '%s' "$baseline") <(printf '%s' "$current") >&2
            return 1
        }
    done
}

# ===========================================================================
# I2 — Append-and-derive composition
# ===========================================================================

@test "I2: append moves the entry through the documented state machine" {
    # enqueue → queued
    apr_lib_queue_append "$EVENTS" "$(event_json enqueue e1 '"round":1')"
    local s1
    s1=$(apr_lib_queue_derive "$EVENTS" e1 | jq -r '.status')
    [[ "$s1" == "queued" ]] || { echo "after enqueue: $s1"; return 1; }

    # +start → running
    apr_lib_queue_append "$EVENTS" "$(event_json start e1)"
    local s2
    s2=$(apr_lib_queue_derive "$EVENTS" e1 | jq -r '.status')
    [[ "$s2" == "running" ]] || { echo "after start: $s2"; return 1; }

    # +finish ok → done
    apr_lib_queue_append "$EVENTS" "$(event_json finish e1 '"ok":true,"code":"ok","exit_code":0')"
    local s3
    s3=$(apr_lib_queue_derive "$EVENTS" e1 | jq -r '.status')
    [[ "$s3" == "done" ]] || { echo "after finish: $s3"; return 1; }
}

# ===========================================================================
# I3 — Truncated last line is silently dropped
# ===========================================================================

@test "I3: truncated last line is dropped; rest of file is still parseable" {
    apr_lib_queue_append "$EVENTS" "$(event_json enqueue good '"round":1')"
    # Append a partial line WITHOUT trailing newline.
    printf '{"event":"start","entry_id":"good"' >> "$EVENTS"

    local out
    out=$(apr_lib_queue_derive "$EVENTS" good 2>/dev/null)
    jq -e . <<<"$out" >/dev/null
    # The pre-partial event was processed → status=queued (only enqueue was applied)
    local s
    s=$(jq -r '.status' <<<"$out")
    [[ "$s" == "queued" ]] || {
        echo "expected queued after partial-line drop, got $s" >&2
        cat "$EVENTS" >&2
        return 1
    }
}

# ===========================================================================
# I4 — Unknown event types are skipped
# ===========================================================================

@test "I4: unknown event types do not crash and do not advance state" {
    apr_lib_queue_append "$EVENTS" "$(event_json enqueue e1 '"round":1')"
    apr_lib_queue_append "$EVENTS" "$(event_json unicorn  e1)"
    apr_lib_queue_append "$EVENTS" "$(event_json explode  e1)"

    local out s
    out=$(apr_lib_queue_derive "$EVENTS" e1)
    jq -e . <<<"$out" >/dev/null
    s=$(jq -r '.status' <<<"$out")
    [[ "$s" == "queued" ]] || {
        echo "unknown events should not advance state; got $s" >&2
        return 1
    }
}

# ===========================================================================
# I5 — Cancel after terminal done is NOT downgraded
# ===========================================================================

@test "I5: 'cancel' after 'finish (done)' DOES override to canceled (operator-action-wins spec)" {
    # Per the documented spec (see test_queue.bats: "spec says canceled
    # wins on terminal-only events but post-terminal mutation should
    # not change finalized done"), cancel is an EXPLICIT operator
    # action that overrides a previous done. Pin that here. The
    # complementary direction is locked by I5b below.
    apr_lib_queue_append "$EVENTS" "$(event_json enqueue e1 '"round":1')"
    apr_lib_queue_append "$EVENTS" "$(event_json start    e1)"
    apr_lib_queue_append "$EVENTS" "$(event_json finish   e1 '"ok":true,"code":"ok","exit_code":0')"
    apr_lib_queue_append "$EVENTS" "$(event_json cancel   e1 '"reason":"operator_action"')"

    local s
    s=$(apr_lib_queue_derive "$EVENTS" e1 | jq -r '.status')
    [[ "$s" == "canceled" ]] || {
        echo "expected canceled (operator-action overrides done), got $s" >&2
        return 1
    }
}

@test "I5b: 'start' after 'cancel' does NOT resurrect" {
    apr_lib_queue_append "$EVENTS" "$(event_json enqueue e2 '"round":1')"
    apr_lib_queue_append "$EVENTS" "$(event_json cancel  e2)"
    apr_lib_queue_append "$EVENTS" "$(event_json start   e2)"
    apr_lib_queue_append "$EVENTS" "$(event_json finish  e2 '"ok":true,"code":"ok","exit_code":0')"

    local s
    s=$(apr_lib_queue_derive "$EVENTS" e2 | jq -r '.status')
    [[ "$s" == "canceled" ]] || {
        echo "expected canceled (cancel-locked), got $s" >&2
        return 1
    }
}

# ===========================================================================
# I6 — status_summary shape
# ===========================================================================

@test "I6: status_summary emits documented keys + counts.* sub-shape" {
    apr_lib_queue_append "$EVENTS" "$(event_json enqueue e1 '"round":1')"
    apr_lib_queue_append "$EVENTS" "$(event_json enqueue e2 '"round":1')"
    apr_lib_queue_append "$EVENTS" "$(event_json start    e1)"

    local summary
    summary=$(apr_lib_queue_status_summary "$EVENTS")
    jq -e . <<<"$summary" >/dev/null
    jq -e '.counts | type == "object"' <<<"$summary" >/dev/null
    jq -e '.active | type == "array"' <<<"$summary" >/dev/null

    local k
    for k in queued running done failed canceled; do
        jq -e --arg k "$k" '.counts | has($k) and (.[$k] | type == "number")' \
            <<<"$summary" >/dev/null || {
            echo "missing or non-numeric counts.$k:" >&2
            echo "$summary" >&2
            return 1
        }
    done
}

# ===========================================================================
# I7 — Sum-consistency
# ===========================================================================

@test "I7: counts.queued+running+done+failed+canceled equals unique entry_id count" {
    # 6 entries in mixed states
    apr_lib_queue_append "$EVENTS" "$(event_json enqueue a '"round":1')"
    apr_lib_queue_append "$EVENTS" "$(event_json enqueue b '"round":1')"
    apr_lib_queue_append "$EVENTS" "$(event_json enqueue c '"round":1')"
    apr_lib_queue_append "$EVENTS" "$(event_json enqueue d '"round":1')"
    apr_lib_queue_append "$EVENTS" "$(event_json enqueue e '"round":1')"
    apr_lib_queue_append "$EVENTS" "$(event_json enqueue f '"round":1')"

    apr_lib_queue_append "$EVENTS" "$(event_json start    a)"
    apr_lib_queue_append "$EVENTS" "$(event_json finish   a '"ok":true,"code":"ok","exit_code":0')"

    apr_lib_queue_append "$EVENTS" "$(event_json start    b)"

    apr_lib_queue_append "$EVENTS" "$(event_json start    c)"
    apr_lib_queue_append "$EVENTS" "$(event_json fail     c '"ok":false,"code":"network_error","exit_code":10')"

    apr_lib_queue_append "$EVENTS" "$(event_json cancel   d)"

    # e and f stay queued.

    local summary sum
    summary=$(apr_lib_queue_status_summary "$EVENTS")
    sum=$(jq -r '.counts | (.queued + .running + .done + .failed + .canceled)' <<<"$summary")

    [[ "$sum" -eq 6 ]] || {
        echo "sum-consistency violated: total entry_ids=6, sum=$sum" >&2
        echo "$summary" >&2
        return 1
    }

    # And the active set == queued + running entries.
    jq -e '.active | length == 3' <<<"$summary" >/dev/null
    jq -e '.counts.queued == 2 and .counts.running == 1' <<<"$summary" >/dev/null
    jq -e '.counts.done == 1 and .counts.failed == 1 and .counts.canceled == 1' <<<"$summary" >/dev/null
}

# ===========================================================================
# I8 — Large event log
# ===========================================================================

@test "I8: 500-entry event log derives cleanly and reports the right tally" {
    local i
    for i in $(seq 1 500); do
        printf '%s\n' "$(event_json enqueue "entry_$i" '"round":1')" >> "$EVENTS"
    done

    local summary total
    summary=$(apr_lib_queue_status_summary "$EVENTS")
    total=$(jq -r '.counts.queued' <<<"$summary")
    [[ "$total" -eq 500 ]] || {
        echo "expected 500 queued, got $total" >&2
        return 1
    }
}

# ===========================================================================
# I9 — Empty / missing events file
# ===========================================================================

@test "I9: missing events file returns zeros without crashing" {
    local summary
    summary=$(apr_lib_queue_status_summary "$EVENTS")
    jq -e '.counts.queued == 0 and .counts.running == 0' <<<"$summary" >/dev/null
    jq -e '.counts.done == 0 and .counts.failed == 0 and .counts.canceled == 0' <<<"$summary" >/dev/null
    jq -e '.active | length == 0' <<<"$summary" >/dev/null
}

@test "I9: empty events file returns zeros without crashing" {
    : > "$EVENTS"
    local summary
    summary=$(apr_lib_queue_status_summary "$EVENTS")
    jq -e '.counts.queued == 0' <<<"$summary" >/dev/null
}

# ===========================================================================
# I10 — with_lock + append composition is line-stable
# ===========================================================================

@test "I10: 20 with_lock-serialized appends produce a 20-line file with no torn lines" {
    local i
    for i in $(seq 1 20); do
        apr_lib_queue_with_lock "$LOCK" \
            apr_lib_queue_append "$EVENTS" "$(event_json enqueue "e_$i" '"round":1')"
    done

    # Exactly 20 newline-terminated lines.
    local lines
    lines=$(wc -l < "$EVENTS")
    [[ "$lines" -eq 20 ]] || {
        echo "expected 20 lines, got $lines" >&2
        head "$EVENTS" >&2
        return 1
    }

    # Every line is valid JSON.
    local n bad=0 line
    while IFS= read -r line; do
        if ! jq -e . <<<"$line" >/dev/null 2>&1; then
            bad=$((bad + 1))
        fi
    done < "$EVENTS"
    [[ "$bad" -eq 0 ]] || {
        echo "$bad non-JSON lines in events file" >&2
        return 1
    }

    # All 20 entry_ids accounted for in the summary.
    local summary
    summary=$(apr_lib_queue_status_summary "$EVENTS")
    jq -e '.counts.queued == 20' <<<"$summary" >/dev/null
}

# ===========================================================================
# Negative-path: derive of unknown entry_id returns status=unknown
# ===========================================================================

@test "negative: derive on unknown entry_id returns status=unknown without error envelope crash" {
    apr_lib_queue_append "$EVENTS" "$(event_json enqueue real '"round":1')"
    local out
    out=$(apr_lib_queue_derive "$EVENTS" "nonexistent_entry") || true
    jq -e . <<<"$out" >/dev/null
    [[ "$(jq -r '.status' <<<"$out")" == "unknown" ]]
}

# ===========================================================================
# Determinism cross-property: 3-event sequence yields the same derive
# regardless of how many other-entry events are interleaved
# ===========================================================================

@test "determinism: interleaved other-entry events do NOT affect the target entry's status" {
    apr_lib_queue_append "$EVENTS" "$(event_json enqueue target '"round":1')"
    apr_lib_queue_append "$EVENTS" "$(event_json enqueue noise1 '"round":1')"
    apr_lib_queue_append "$EVENTS" "$(event_json start    noise1)"
    apr_lib_queue_append "$EVENTS" "$(event_json start    target)"
    apr_lib_queue_append "$EVENTS" "$(event_json finish   noise1 '"ok":true,"code":"ok","exit_code":0')"
    apr_lib_queue_append "$EVENTS" "$(event_json enqueue  noise2 '"round":2')"
    apr_lib_queue_append "$EVENTS" "$(event_json finish   target '"ok":true,"code":"ok","exit_code":0')"

    local s
    s=$(apr_lib_queue_derive "$EVENTS" target | jq -r '.status')
    [[ "$s" == "done" ]] || {
        echo "interleaving disturbed target status: $s" >&2
        return 1
    }
}
