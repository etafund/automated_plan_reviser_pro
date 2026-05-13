#!/usr/bin/env bats
# test_robot_busy.bats - Tests for bd-18u: structured robot busy contract
#
# Covers:
#   - apr_lib_busy_robot_data (lib/busy.sh): data-block builder.
#   - robot_emit_busy (apr): full envelope wrapper.
#
# Verifies the JSON contract specified in docs/schemas/robot-busy.md:
#   busy / signature / line / policy / remote_host / retry_after_ms /
#   queue_entry_id / elapsed_ms.

load '../helpers/test_helper'

setup() {
    setup_test_environment
    export APR_LIB_DIR="$BATS_TEST_DIRNAME/../../lib"
    load_apr_functions
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# =============================================================================
# apr_lib_busy_robot_data: data-block builder
# =============================================================================

@test "busy_robot_data: ERROR: busy -> JSON with signature + line" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    apr_lib_busy_robot_data "ERROR: busy" > "$BATS_TEST_TMPDIR/out.json"
    python3 -c "
import json
d = json.load(open('$BATS_TEST_TMPDIR/out.json'))
assert d['busy'] is True
assert d['signature'] == 'error_busy_prefix'
assert d['line'] == 'ERROR: busy'
assert d['policy'] == 'error'      # default
assert d['remote_host'] is None
assert d['retry_after_ms'] is None
assert d['queue_entry_id'] is None
assert d['elapsed_ms'] is None
"
}

@test "busy_robot_data: non-busy text returns rc=1 with NO output" {
    local out rc=0
    out=$(apr_lib_busy_robot_data "network error: connection refused") || rc=$?
    [ "$rc" -eq 1 ]
    [ -z "$out" ]
}

@test "busy_robot_data: empty input returns rc=1" {
    local rc=0
    apr_lib_busy_robot_data "" >/dev/null || rc=$?
    [ "$rc" -eq 1 ]
}

@test "busy_robot_data: 'User error (browser-automation): busy' matches user_error_parens_busy" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    apr_lib_busy_robot_data "User error (browser-automation): busy" > "$BATS_TEST_TMPDIR/out.json"
    python3 -c "
import json
d = json.load(open('$BATS_TEST_TMPDIR/out.json'))
assert d['signature'] == 'user_error_parens_busy'
"
}

@test "busy_robot_data: policy + remote_host pass-through" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    apr_lib_busy_robot_data "ERROR: busy" "wait" "dev-mbp" > "$BATS_TEST_TMPDIR/out.json"
    python3 -c "
import json
d = json.load(open('$BATS_TEST_TMPDIR/out.json'))
assert d['policy'] == 'wait'
assert d['remote_host'] == 'dev-mbp'
"
}

@test "busy_robot_data: full param set serializes correctly" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    apr_lib_busy_robot_data "ERROR: busy" "enqueue" "lan-server" 30000 "01HQUEUE12345" 95000 \
        > "$BATS_TEST_TMPDIR/out.json"
    python3 -c "
import json
d = json.load(open('$BATS_TEST_TMPDIR/out.json'))
assert d['policy'] == 'enqueue'
assert d['remote_host'] == 'lan-server'
assert d['retry_after_ms'] == 30000
assert d['queue_entry_id'] == '01HQUEUE12345'
assert d['elapsed_ms'] == 95000
"
}

@test "busy_robot_data: invalid policy normalizes to 'error'" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    apr_lib_busy_robot_data "ERROR: busy" "invalid-policy" > "$BATS_TEST_TMPDIR/out.json"
    python3 -c "
import json
d = json.load(open('$BATS_TEST_TMPDIR/out.json'))
assert d['policy'] == 'error'
"
}

@test "busy_robot_data: non-numeric retry_after_ms / elapsed_ms -> null" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    apr_lib_busy_robot_data "ERROR: busy" "error" "" "not-a-number" "" "also-bad" \
        > "$BATS_TEST_TMPDIR/out.json"
    python3 -c "
import json
d = json.load(open('$BATS_TEST_TMPDIR/out.json'))
assert d['retry_after_ms'] is None
assert d['elapsed_ms'] is None
"
}

@test "busy_robot_data: 'status: busy' k/v matches kv_busy signature" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    apr_lib_busy_robot_data "phase: invoke
status: busy
elapsed: 12s" > "$BATS_TEST_TMPDIR/out.json"
    python3 -c "
import json
d = json.load(open('$BATS_TEST_TMPDIR/out.json'))
assert d['signature'] == 'kv_busy'
"
}

# =============================================================================
# robot_emit_busy: full envelope wrapper
# =============================================================================

@test "robot_emit_busy: busy input emits ok:false envelope with code=busy" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    ROBOT_COMPACT=true
    robot_emit_busy "ERROR: busy" 2>/dev/null > "$BATS_TEST_TMPDIR/env.json" || true
    python3 -c "
import json
d = json.load(open('$BATS_TEST_TMPDIR/env.json'))
assert d['ok'] is False
assert d['code'] == 'busy'
data = d['data']
assert data['busy'] is True
assert data['signature'] == 'error_busy_prefix'
assert data['policy'] == 'error'
"
}

@test "robot_emit_busy: non-busy input returns rc=1 with no output" {
    ROBOT_COMPACT=true
    local out rc=0
    out=$(robot_emit_busy "config error: missing field" 2>/dev/null) || rc=$?
    [ "$rc" -eq 1 ]
    [ -z "$out" ]
}

@test "robot_emit_busy: APR_ROBOT_BUSY_POLICY=wait is reflected in JSON" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    ROBOT_COMPACT=true
    APR_ROBOT_BUSY_POLICY=wait robot_emit_busy "ERROR: busy" 2>/dev/null > "$BATS_TEST_TMPDIR/env.json" || true
    python3 -c "
import json
d = json.load(open('$BATS_TEST_TMPDIR/env.json'))
assert d['data']['policy'] == 'wait'
"
}

@test "robot_emit_busy: explicit policy arg overrides env" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    ROBOT_COMPACT=true
    APR_ROBOT_BUSY_POLICY=wait robot_emit_busy "ERROR: busy" "enqueue" "lan-server" 2>/dev/null \
        > "$BATS_TEST_TMPDIR/env.json" || true
    python3 -c "
import json
d = json.load(open('$BATS_TEST_TMPDIR/env.json'))
assert d['data']['policy'] == 'enqueue'
assert d['data']['remote_host'] == 'lan-server'
"
}

@test "robot_emit_busy: hint mentions retry/wait/enqueue policy options" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    ROBOT_COMPACT=true
    robot_emit_busy "ERROR: busy" 2>/dev/null > "$BATS_TEST_TMPDIR/env.json" || true
    python3 -c "
import json
d = json.load(open('$BATS_TEST_TMPDIR/env.json'))
hint = d.get('hint', '')
assert 'busy' in hint.lower()
assert 'APR_ROBOT_BUSY_POLICY' in hint
"
}

# =============================================================================
# Exit code mapping (busy -> 12)
# =============================================================================

@test "robot_emit_busy: returns exit code 12 on busy match" {
    ROBOT_COMPACT=true
    local rc=0
    robot_emit_busy "ERROR: busy" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 12 ]
}
