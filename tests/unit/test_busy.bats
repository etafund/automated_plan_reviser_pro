#!/usr/bin/env bats
# test_busy.bats - Unit tests for lib/busy.sh (bd-3pu)
#
# Validates oracle busy detection against a fixture corpus split into
# positive (`tests/fixtures/busy/busy_*.txt`) and negative
# (`tests/fixtures/busy/not_busy_*.txt`) samples.

load '../helpers/test_helper'

setup() {
    setup_test_environment
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/busy.sh"
    FIXTURES="$BATS_TEST_DIRNAME/../fixtures/busy"
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# =============================================================================
# detect_text: positive signatures
# =============================================================================

@test "detect_text: 'ERROR: busy' line is detected" {
    run apr_lib_busy_detect_text "ERROR: busy"
    assert_success
}

@test "detect_text: 'ERROR: BUSY' uppercase is detected" {
    run apr_lib_busy_detect_text "ERROR: BUSY"
    assert_success
}

@test "detect_text: 'ERROR: busy' with trailing context is detected" {
    run apr_lib_busy_detect_text "ERROR: busy. The previous run is still in flight."
    assert_success
}

@test "detect_text: 'User error (browser-automation): busy' is detected" {
    run apr_lib_busy_detect_text "User error (browser-automation): busy"
    assert_success
}

@test "detect_text: 'User error (any-engine): busy' shape is detected" {
    run apr_lib_busy_detect_text "User error (oracle-cli): busy"
    assert_success
}

@test "detect_text: 'Oracle is busy' phrase is detected" {
    run apr_lib_busy_detect_text "Oracle is busy, retry later"
    assert_success
}

@test "detect_text: 'browser is busy' phrase is detected" {
    run apr_lib_busy_detect_text "the browser is busy with another session"
    assert_success
}

@test "detect_text: 'status: busy' key/value is detected" {
    run apr_lib_busy_detect_text "phase: invoke
status: busy
elapsed: 12s"
    assert_success
}

@test "detect_text: 'retry=busy' key/value is detected" {
    run apr_lib_busy_detect_text "retry=busy host=dev-mbp"
    assert_success
}

@test "detect_text: busy signal anywhere in noisy log is detected" {
    run apr_lib_busy_detect_text "[oracle] starting session
[oracle] heartbeat 1/30
ERROR: busy
[oracle] giving up"
    assert_success
}

# =============================================================================
# detect_text: negative cases (no false positives)
# =============================================================================

@test "detect_text: empty string is not busy" {
    run apr_lib_busy_detect_text ""
    [ "$status" -eq 1 ]
}

@test "detect_text: no input arg is not busy" {
    run apr_lib_busy_detect_text
    [ "$status" -eq 1 ]
}

@test "detect_text: 'busylight' substring is NOT busy" {
    run apr_lib_busy_detect_text "config: busylight=true
init busylight indicator"
    [ "$status" -eq 1 ]
}

@test "detect_text: 'busyness' substring is NOT busy" {
    run apr_lib_busy_detect_text "the busyness of the queue is high but oracle is fine"
    [ "$status" -eq 1 ]
}

@test "detect_text: 'busy_loop' identifier is NOT busy" {
    run apr_lib_busy_detect_text "stuck in a busy_loop refactor"
    [ "$status" -eq 1 ]
}

@test "detect_text: 'not_busy' identifier is NOT busy" {
    run apr_lib_busy_detect_text "retry=not_busy host=dev-mbp"
    [ "$status" -eq 1 ]
}

@test "detect_text: network error is NOT busy" {
    run apr_lib_busy_detect_text "ERROR: network: connection refused"
    [ "$status" -eq 1 ]
}

@test "detect_text: config error is NOT busy" {
    run apr_lib_busy_detect_text "ERROR: config: workflow not found"
    [ "$status" -eq 1 ]
}

@test "detect_text: generic browser-automation timeout is NOT busy" {
    run apr_lib_busy_detect_text "ERROR: browser-automation: failed to load chat page (timeout 60s)"
    [ "$status" -eq 1 ]
}

@test "detect_text: prose 'busy week' is NOT busy" {
    run apr_lib_busy_detect_text "APR has been a busy week of refactors."
    [ "$status" -eq 1 ]
}

# =============================================================================
# detect_file: fixture corpus
# =============================================================================

@test "detect_file: all busy_*.txt fixtures match" {
    local f
    for f in "$FIXTURES"/busy_*.txt; do
        run apr_lib_busy_detect_file "$f"
        if [[ "$status" -ne 0 ]]; then
            echo "FAIL: $f was not detected as busy" >&2
            return 1
        fi
    done
}

@test "detect_file: all not_busy_*.txt fixtures do NOT match" {
    local f
    for f in "$FIXTURES"/not_busy_*.txt; do
        run apr_lib_busy_detect_file "$f"
        if [[ "$status" -eq 0 ]]; then
            echo "FAIL: $f false-matched as busy" >&2
            return 1
        fi
    done
}

@test "detect_file: missing path returns 1" {
    run apr_lib_busy_detect_file "$BATS_TEST_TMPDIR/does-not-exist.txt"
    [ "$status" -eq 1 ]
}

@test "detect_file: empty arg returns 1" {
    run apr_lib_busy_detect_file ""
    [ "$status" -eq 1 ]
}

# =============================================================================
# describe_text: JSON output shape
# =============================================================================

@test "describe_text: non-busy emits {\"busy\":false}" {
    run apr_lib_busy_describe_text "ERROR: network: oops"
    assert_success
    assert_output '{"busy":false}'
}

@test "describe_text: empty input emits {\"busy\":false}" {
    run apr_lib_busy_describe_text ""
    assert_success
    assert_output '{"busy":false}'
}

@test "describe_text: busy emits busy=true with signature name" {
    run apr_lib_busy_describe_text "ERROR: busy"
    assert_success
    assert_output --partial '"busy":true'
    assert_output --partial '"signature":"error_busy_prefix"'
    assert_output --partial '"line":"ERROR: busy"'
}

@test "describe_text: parens shape matches user_error_parens_busy" {
    run apr_lib_busy_describe_text "User error (browser-automation): busy"
    assert_success
    assert_output --partial '"signature":"user_error_parens_busy"'
}

@test "describe_text: oracle-is-busy matches subject_is_busy" {
    run apr_lib_busy_describe_text "Oracle is busy, the previous run is in flight"
    assert_success
    assert_output --partial '"signature":"subject_is_busy"'
}

@test "describe_text: status=busy matches kv_busy" {
    run apr_lib_busy_describe_text "status: busy"
    assert_success
    assert_output --partial '"signature":"kv_busy"'
}

@test "describe_text: output is valid JSON" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local out
    out=$(apr_lib_busy_describe_text "ERROR: busy")
    python3 -c "import json,sys; d=json.loads('''$out'''); assert d['busy'] is True; assert 'signature' in d; assert 'line' in d"
}

@test "describe_text: matched line is JSON-escaped" {
    # Quote inside the matched line must come out as \" in JSON.
    local input='User error ("inner-quote"): busy'
    local out
    out=$(apr_lib_busy_describe_text "$input")
    [[ "$out" == *'\"inner-quote\"'* ]]
}

@test "describe_text: long matched line is truncated to 200 bytes" {
    # Build an input where the matching line is well over 200 bytes.
    local pad
    pad=$(printf 'x%.0s' {1..300})
    local input="ERROR: busy ${pad}"
    local out
    out=$(apr_lib_busy_describe_text "$input")
    # Pull the value of "line" out and check its length <= 200.
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    local len
    len=$(python3 -c "import json,sys; d=json.loads('''$out'''); print(len(d['line']))")
    [ "$len" -le 200 ]
}

# =============================================================================
# describe_file: smoke
# =============================================================================

@test "describe_file: busy fixture returns busy=true" {
    run apr_lib_busy_describe_file "$FIXTURES/busy_error_prefix.txt"
    assert_success
    assert_output --partial '"busy":true'
}

@test "describe_file: not-busy fixture returns busy=false" {
    run apr_lib_busy_describe_file "$FIXTURES/not_busy_busylight.txt"
    assert_success
    assert_output '{"busy":false}'
}

@test "describe_file: missing path returns busy=false" {
    run apr_lib_busy_describe_file "$BATS_TEST_TMPDIR/nope"
    assert_success
    assert_output '{"busy":false}'
}

# =============================================================================
# Public constant
# =============================================================================

@test "APR_LIB_BUSY_CODE constant is exported as 'busy'" {
    [ "$APR_LIB_BUSY_CODE" = "busy" ]
}
