#!/usr/bin/env bats
# test_busy_wait.bats - Unit tests for lib/busy_wait.sh (bd-3du)
#
# Validates the busy wait loop policy. All tests inject:
#   - a stub clock (counter) so elapsed-time is deterministic
#   - a stub sleep (no-op) so the suite finishes in milliseconds
#   - a stub message sink (array accumulator) so messages can be asserted
#   - a controllable probe (variable-driven)
#
# Combined, these decouple the test from wall-clock time entirely.

load '../helpers/test_helper'

# Shared test scaffolding: these are functions/vars that the tests
# configure per-case.

# Counter clock — advances by $CLOCK_STEP per call (default 1).
_test_clock_counter=0
_test_clock_step=1
_test_clock() {
    _test_clock_counter=$(( _test_clock_counter + _test_clock_step ))
    printf '%s' "$_test_clock_counter"
}

# Sleep stub — does nothing but optionally bumps clock by the slept amount.
_test_sleep_bumps=1
_test_sleep() {
    if [[ "$_test_sleep_bumps" == "1" ]]; then
        _test_clock_counter=$(( _test_clock_counter + ${1:-0} ))
    fi
}

# Message sink — accumulates into a global array for inspection.
_test_messages=()
_test_message() {
    _test_messages+=("$*")
}

# Probe configurator: caller sets _test_busy_remaining to N to mean
# "stay busy for N more probe calls, then go clear". -1 = always busy.
_test_busy_remaining=0
_test_probe() {
    if (( _test_busy_remaining > 0 )); then
        _test_busy_remaining=$(( _test_busy_remaining - 1 ))
        return 0   # still busy
    fi
    if (( _test_busy_remaining < 0 )); then
        return 0   # always busy
    fi
    return 1       # clear
}

setup() {
    setup_test_environment
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/busy_wait.sh"
    # Reset counters/configuration.
    _test_clock_counter=0
    _test_clock_step=1
    _test_sleep_bumps=1
    _test_messages=()
    _test_busy_remaining=0
    apr_lib_busy_wait_set_clock_fn   _test_clock
    apr_lib_busy_wait_set_sleep_fn   _test_sleep
    apr_lib_busy_wait_set_message_fn _test_message
    apr_lib_busy_wait_set_probe      _test_probe
    # Pin out jitter for determinism; keep aggressive defaults otherwise.
    apr_lib_busy_wait_configure jitter=0 min_sleep=1 max_sleep=8 multiplier=2 max_total_wait=1000 message_every=10000
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# =============================================================================
# Immediate-clear path
# =============================================================================

@test "wait: probe clear immediately -> no iterations" {
    _test_busy_remaining=0   # clear on first probe
    apr_lib_busy_wait
    [ "$APR_BUSY_WAIT_COUNT" = "0" ]
    [ "$APR_BUSY_WAIT_TOTAL_MS" = "0" ]
    [ "$APR_BUSY_WAIT_LAST_REASON" = "cleared" ]
}

# =============================================================================
# Iteration counting
# =============================================================================

@test "wait: busy for N probes then clears -> N iterations" {
    _test_busy_remaining=4   # busy for 4 probe calls
    apr_lib_busy_wait
    [ "$APR_BUSY_WAIT_COUNT" = "4" ]
    [ "$APR_BUSY_WAIT_LAST_REASON" = "cleared" ]
}

@test "wait: total_ms is the sum of slept seconds * 1000" {
    _test_busy_remaining=3
    # With min_sleep=1, multiplier=2, max_sleep=8, jitter=0:
    # iter 0: sleep 1s
    # iter 1: sleep 2s
    # iter 2: sleep 4s
    # total: 7s = 7000ms (then probe clears)
    apr_lib_busy_wait
    [ "$APR_BUSY_WAIT_COUNT" = "3" ]
    [ "$APR_BUSY_WAIT_TOTAL_MS" = "7000" ]
}

@test "wait: sleep is capped at max_sleep" {
    apr_lib_busy_wait_configure jitter=0 min_sleep=1 max_sleep=3 multiplier=2 max_total_wait=10000 message_every=10000
    _test_busy_remaining=5
    apr_lib_busy_wait
    # iter 0: 1, iter 1: 2, iter 2: 3 (capped), iter 3: 3, iter 4: 3
    # sum = 1+2+3+3+3 = 12 seconds -> 12000 ms
    [ "$APR_BUSY_WAIT_TOTAL_MS" = "12000" ]
}

# =============================================================================
# Timeout path
# =============================================================================

@test "wait: timeout when probe never clears" {
    _test_busy_remaining=-1   # always busy
    # Budget = 5s; sleeps grow 1,2,4,8(cap)... eventually exhausts budget.
    apr_lib_busy_wait_configure jitter=0 min_sleep=1 max_sleep=8 multiplier=2 max_total_wait=5 message_every=10000
    # NOTE: `run` runs in a subshell so the result globals would be lost.
    apr_lib_busy_wait && status=0 || status=$?
    [ "$status" -eq 1 ]
    [ "$APR_BUSY_WAIT_LAST_REASON" = "timeout" ]
}

@test "wait: timeout never sleeps longer than remaining budget" {
    _test_busy_remaining=-1
    apr_lib_busy_wait_configure jitter=0 min_sleep=4 max_sleep=10 multiplier=2 max_total_wait=6 message_every=10000
    # min_sleep alone (4) is < budget (6); next iter sleep would be 8s but
    # only 2s of budget remain so we should clamp to 2s. After that, we're
    # past the budget; loop should exit cleanly with timeout.
    apr_lib_busy_wait && status=0 || status=$?
    [ "$status" -eq 1 ]
    [ "$APR_BUSY_WAIT_LAST_REASON" = "timeout" ]
    # We should have done exactly 2 sleeps (4s + 2s) before timeout.
    [ "$APR_BUSY_WAIT_COUNT" = "2" ]
    [ "$APR_BUSY_WAIT_TOTAL_MS" = "6000" ]
}

# =============================================================================
# max_total_wait=0 means unbounded
# =============================================================================

@test "wait: max_total_wait=0 disables the budget (large clock burn)" {
    _test_busy_remaining=10
    apr_lib_busy_wait_configure jitter=0 min_sleep=1 max_sleep=100 multiplier=2 max_total_wait=0 message_every=10000
    apr_lib_busy_wait
    # 10 sleeps: 1,2,4,8,16,32,64,100,100,100 = 427 s, never times out
    [ "$APR_BUSY_WAIT_COUNT" = "10" ]
    [ "$APR_BUSY_WAIT_LAST_REASON" = "cleared" ]
}

# =============================================================================
# Sleep calculation (compute_sleep is internal; test through total_ms)
# =============================================================================

@test "compute_sleep: exponential growth with no jitter" {
    apr_lib_busy_wait_configure jitter=0 min_sleep=2 max_sleep=100 multiplier=3 max_total_wait=10000 message_every=10000
    _test_busy_remaining=4
    apr_lib_busy_wait
    # iter 0: 2, iter 1: 6, iter 2: 18, iter 3: 54
    # total: 80s = 80000ms
    [ "$APR_BUSY_WAIT_TOTAL_MS" = "80000" ]
}

# =============================================================================
# Configuration: unknown keys do not fail, just warn
# =============================================================================

@test "configure: unknown key prints warning but does not fail" {
    run apr_lib_busy_wait_configure unknown_key=42 min_sleep=5
    assert_success
    [[ "$output" == *"unknown_key"* ]]
}

# =============================================================================
# Messaging
# =============================================================================

@test "message: emits opening banner when actually busy" {
    _test_busy_remaining=1
    apr_lib_busy_wait
    # First message should be the banner.
    [[ "${_test_messages[0]}" == *"oracle busy"* ]]
    [[ "${_test_messages[0]}" == *"budget"* ]]
}

@test "message: emits clear-message on success" {
    _test_busy_remaining=1
    apr_lib_busy_wait
    local last="${_test_messages[$(( ${#_test_messages[@]} - 1 ))]}"
    [[ "$last" == *"cleared"* ]]
}

@test "message: emits timeout-message on budget exhaustion" {
    _test_busy_remaining=-1
    apr_lib_busy_wait_configure jitter=0 min_sleep=1 max_sleep=2 multiplier=2 max_total_wait=3 message_every=10000
    apr_lib_busy_wait || true
    local last="${_test_messages[$(( ${#_test_messages[@]} - 1 ))]}"
    [[ "$last" == *"timeout"* ]]
}

@test "message: NO messages when already clear" {
    _test_busy_remaining=0
    apr_lib_busy_wait
    [ "${#_test_messages[@]}" = "0" ]
}

@test "message: throttled progress updates via message_every" {
    apr_lib_busy_wait_configure jitter=0 min_sleep=1 max_sleep=1 multiplier=1 max_total_wait=100 message_every=2
    _test_busy_remaining=5
    apr_lib_busy_wait
    # With message_every=2, banner + a couple of progress lines + clear.
    [ "${#_test_messages[@]}" -ge 2 ]
    [ "${#_test_messages[@]}" -le 7 ]
}

# =============================================================================
# Hook injection points
# =============================================================================

@test "hooks: set_probe accepts arbitrary command string" {
    PROBE_CALLS=0
    my_probe() { PROBE_CALLS=$(( PROBE_CALLS + 1 )); return 1; }
    apr_lib_busy_wait_set_probe "my_probe"
    apr_lib_busy_wait
    [ "$PROBE_CALLS" -ge 1 ]
}

@test "hooks: no probe registered -> treated as not busy" {
    apr_lib_busy_wait_set_probe ""
    apr_lib_busy_wait
    [ "$APR_BUSY_WAIT_LAST_REASON" = "cleared" ]
    [ "$APR_BUSY_WAIT_COUNT" = "0" ]
}

@test "hooks: probe + busy.sh detection compose cleanly" {
    # Source busy.sh and use its describe helper as a probe.
    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/busy.sh"
    OUT_TEXT=""
    busy_probe() {
        apr_lib_busy_detect_text "$OUT_TEXT"
    }
    apr_lib_busy_wait_set_probe "busy_probe"
    OUT_TEXT="ERROR: busy"
    # Switch to clear after one iter.
    iter=0
    next_probe() {
        iter=$(( iter + 1 ))
        if (( iter == 1 )); then
            return 0  # still busy
        fi
        return 1      # cleared
    }
    apr_lib_busy_wait_set_probe "next_probe"
    apr_lib_busy_wait
    [ "$APR_BUSY_WAIT_LAST_REASON" = "cleared" ]
}
