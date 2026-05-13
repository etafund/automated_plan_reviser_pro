#!/usr/bin/env bats
# test_busy_backoff.bats - Tests for bd-2kd
#
# Validates run_oracle_with_retry's busy-classification + dedicated
# busy backoff:
#   - busy stderr is detected and routed to the busy-retry path
#   - non-busy errors take the existing generic-retry path
#   - busy budget exhaustion in robot mode emits structured busy JSON
#   - busy budget exhaustion in human mode exits EXIT_BUSY_ERROR (12)
#
# Tests stub ORACLE_CMD with a script that emits configurable stderr
# and exit codes, plus stub `sleep` to keep the suite fast.

load '../helpers/test_helper'

setup() {
    setup_test_environment
    export APR_LIB_DIR="$BATS_TEST_DIRNAME/../../lib"
    load_apr_functions
    # Stub sleep so backoff doesn't burn wall-clock.
    sleep() { :; }
    export -f sleep
    # Aggressive budgets so tests can hit exhaustion fast.
    export APR_BUSY_MAX_RETRIES=3
    export APR_BUSY_INITIAL_BACKOFF=1
    export APR_BUSY_MAX_SLEEP=2
    export APR_BUSY_MAX_WAIT=0   # disabled
    # Generic retry budget low so non-busy path also tests quickly.
    export APR_MAX_RETRIES=2
    export APR_INITIAL_BACKOFF=0
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# Stub helper: emit a fake oracle script that records calls and emits
# the given stderr + exit code.
#
# Usage: make_fake_oracle <stderr> <exit_code> [<exit_after_n_calls> <success_exit>]
make_fake_oracle() {
    local stderr="$1"
    local exit_code="$2"
    local switch_after="${3:-0}"   # 0 = always fail
    local success_exit="${4:-0}"
    local script="$TEST_DIR/fake_oracle.sh"
    local counter="$TEST_DIR/fake_oracle.count"
    : > "$counter"
    cat > "$script" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$counter" 2>/dev/null || echo 0) + 1 ))
echo \$n > "$counter"
printf '%s\n' "$stderr" >&2
if [[ "$switch_after" -gt 0 && \$n -ge "$switch_after" ]]; then
    exit "$success_exit"
fi
exit "$exit_code"
EOF
    chmod +x "$script"
    ORACLE_CMD=("$script")
}

# =============================================================================
# Busy detection & retry
# =============================================================================

@test "run_oracle_with_retry: busy on every attempt -> exit EXIT_BUSY_ERROR (12)" {
    # Force exhaustion.
    APR_BUSY_MAX_RETRIES=2
    make_fake_oracle "ERROR: busy" 1
    local rc=0
    run_oracle_with_retry --slug test >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 12 ]
}

@test "run_oracle_with_retry: busy then clears -> returns 0 after retries" {
    APR_BUSY_MAX_RETRIES=5
    # Stay busy for first 2 calls, then succeed on 3rd.
    make_fake_oracle "ERROR: busy" 1 3 0
    local rc=0
    run_oracle_with_retry --slug test >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ]
}

@test "run_oracle_with_retry: busy budget caps via APR_BUSY_MAX_WAIT" {
    APR_BUSY_MAX_RETRIES=999
    APR_BUSY_INITIAL_BACKOFF=10
    APR_BUSY_MAX_SLEEP=10
    APR_BUSY_MAX_WAIT=15   # tight budget -> ~2 attempts max
    make_fake_oracle "ERROR: busy" 1
    local rc=0
    run_oracle_with_retry --slug test >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 12 ]
}

@test "run_oracle_with_retry: non-busy error takes generic-retry path (not busy budget)" {
    APR_BUSY_MAX_RETRIES=99    # busy budget large
    APR_MAX_RETRIES=2          # generic budget small
    APR_INITIAL_BACKOFF=0
    make_fake_oracle "ERROR: network: connection refused" 1
    local rc=0
    run_oracle_with_retry --slug test >/dev/null 2>&1 || rc=$?
    # Non-busy error returns the underlying exit code (1), NOT EXIT_BUSY_ERROR.
    [ "$rc" -eq 1 ]
}

@test "run_oracle_with_retry: busy retry emits operator message with signature" {
    APR_BUSY_MAX_RETRIES=3
    make_fake_oracle "ERROR: busy" 1
    local err
    err=$(run_oracle_with_retry --slug test 2>&1 1>/dev/null || true)
    [[ "$err" == *"Oracle busy"* ]]
    [[ "$err" == *"error_busy_prefix"* ]]
}

# =============================================================================
# Robot mode: structured busy envelope on exhaustion
# =============================================================================

@test "run_oracle_with_retry: ROBOT_MODE=true emits structured busy JSON on exhaustion" {
    if ! command -v python3 >/dev/null 2>&1; then
        skip "python3 not available"
    fi
    ROBOT_MODE=true
    ROBOT_COMPACT=true
    APR_BUSY_MAX_RETRIES=2
    make_fake_oracle "ERROR: busy" 1
    # Robot-mode busy emit returns exit 12.
    local out rc=0
    out=$(run_oracle_with_retry --slug test 2>/dev/null) || rc=$?
    [ "$rc" -eq 12 ]
    # The stdout should contain the structured busy envelope.
    [[ "$out" == *'"code":"busy"'* ]]
    [[ "$out" == *'"busy":true'* ]]
    [[ "$out" == *'"signature":"error_busy_prefix"'* ]]
}

# =============================================================================
# Distinct from oracle_error code (exit code differs)
# =============================================================================

@test "run_oracle_with_retry: busy exhausted maps to exit code 12, not 1" {
    APR_BUSY_MAX_RETRIES=2
    make_fake_oracle "ERROR: busy" 5   # arbitrary non-zero from oracle
    local rc=0
    run_oracle_with_retry --slug test >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 12 ]   # busy taxonomy code, NOT oracle's exit 5
}
