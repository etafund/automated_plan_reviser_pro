#!/usr/bin/env bats
# test_busy_wait_metamorphic.bats
#
# Bead automated_plan_reviser_pro-9l01 — metamorphic/property layer for
# lib/busy_wait.sh.
#
# tests/unit/test_busy_wait.bats (17 tests) covers specific scenarios.
# This file adds INVARIANT pins on the backoff math and the busy-wait
# state machine so future jitter/policy changes can't drift away from
# the documented contract.
#
# All tests inject the same deterministic stubs the original suite uses:
#   - counter clock (no wall-time dependency)
#   - no-op sleep that optionally bumps the counter clock
#   - controllable probe (busy for N calls, then clear; or always busy)
#   - message sink array
#
# Invariants pinned:
#   I1  jitter=0 produces the documented geometric sleep schedule
#   I2  jitter=N% bounds every sleep within [max(1, expected−floor*N/100),
#       expected+floor*N/100]
#   I3  APR_BUSY_WAIT_COUNT == number of busy probe→sleep cycles
#   I4  probe-never-clears → LAST_REASON=timeout AND total_ms ≤ max_total*1000
#   I5  probe-clears-at-iter-K → COUNT == K AND LAST_REASON=cleared
#   I6  every sleep ≥ min_sleep (jitter=0)
#   I7  every sleep ≤ max_sleep regardless of iter count
#   I8  total_ms == sum of individual sleeps * 1000 (jitter=0)
#   I9  doubling max_total_wait while probe stays busy at least doubles
#       total_ms (monotone budget property)
#   I10 jitter=0 runs are deterministic: same config + same probe →
#       same (COUNT, TOTAL_MS, LAST_REASON)
#
# Per-test artifacts under tests/logs/unit/ per the ufc Logging contract.

load '../helpers/test_helper'

# ---------------------------------------------------------------------------
# Deterministic stubs (same pattern as test_busy_wait.bats)
# ---------------------------------------------------------------------------

_test_clock_counter=0
_test_clock_step=1
_test_clock() {
    _test_clock_counter=$(( _test_clock_counter + _test_clock_step ))
    printf '%s' "$_test_clock_counter"
}

# Record every sleep amount for I7/I8 inspection.
_test_sleep_log=()
_test_sleep_bumps=1
_test_sleep() {
    _test_sleep_log+=("${1:-0}")
    if [[ "$_test_sleep_bumps" == "1" ]]; then
        _test_clock_counter=$(( _test_clock_counter + ${1:-0} ))
    fi
}

_test_messages=()
_test_message() {
    _test_messages+=("$*")
}

# Probe: busy for $_test_busy_remaining calls then clears. -1 = always busy.
_test_busy_remaining=0
_test_probe() {
    if (( _test_busy_remaining > 0 )); then
        _test_busy_remaining=$(( _test_busy_remaining - 1 ))
        return 0
    fi
    if (( _test_busy_remaining < 0 )); then
        return 0
    fi
    return 1
}

reset_stubs() {
    _test_clock_counter=0
    _test_clock_step=1
    _test_sleep_log=()
    _test_sleep_bumps=1
    _test_messages=()
    _test_busy_remaining=0
    apr_lib_busy_wait_set_clock_fn   _test_clock
    apr_lib_busy_wait_set_sleep_fn   _test_sleep
    apr_lib_busy_wait_set_message_fn _test_message
    apr_lib_busy_wait_set_probe      _test_probe
}

# ---------------------------------------------------------------------------
# Setup / Teardown
# ---------------------------------------------------------------------------

setup() {
    setup_test_environment
    start_test_artifacts "unit" "${BATS_TEST_NAME}"

    # shellcheck disable=SC1091
    source "$BATS_TEST_DIRNAME/../../lib/busy_wait.sh"
    reset_stubs
    # Standard config; tests opt into changes.
    apr_lib_busy_wait_configure jitter=0 min_sleep=1 max_sleep=64 \
        multiplier=2 max_total_wait=100000 message_every=10000

    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# Sum the recorded sleeps (in seconds).
sleep_log_total_s() {
    local sum=0 s
    for s in "${_test_sleep_log[@]}"; do
        sum=$(( sum + s ))
    done
    printf '%s' "$sum"
}

# ===========================================================================
# I1 — jitter=0 produces the documented geometric sleep schedule
# ===========================================================================

@test "I1: jitter=0, multiplier=2, min=1, cap=64 → sleeps 1,2,4,8,16,32,64,64,64,…" {
    _test_busy_remaining=10
    apr_lib_busy_wait_configure jitter=0 min_sleep=1 max_sleep=64 \
        multiplier=2 max_total_wait=100000 message_every=10000

    apr_lib_busy_wait

    local expected=(1 2 4 8 16 32 64 64 64 64)
    [[ "${#_test_sleep_log[@]}" -eq 10 ]] || {
        echo "sleep count drift: got ${#_test_sleep_log[@]} want 10" >&2
        printf '  recorded: %s\n' "${_test_sleep_log[*]}" >&2
        return 1
    }
    local i
    for i in "${!expected[@]}"; do
        [[ "${_test_sleep_log[$i]}" == "${expected[$i]}" ]] || {
            echo "schedule drift at iter $i: got ${_test_sleep_log[$i]} want ${expected[$i]}" >&2
            return 1
        }
    done
}

@test "I1: jitter=0, multiplier=3, min=2, cap=20 → sleeps 2,6,18,20,20,…" {
    _test_busy_remaining=5
    apr_lib_busy_wait_configure jitter=0 min_sleep=2 max_sleep=20 \
        multiplier=3 max_total_wait=100000 message_every=10000

    apr_lib_busy_wait

    local expected=(2 6 18 20 20)
    local i
    for i in "${!expected[@]}"; do
        [[ "${_test_sleep_log[$i]}" == "${expected[$i]}" ]] || {
            echo "schedule drift at iter $i: got ${_test_sleep_log[$i]} want ${expected[$i]}" >&2
            return 1
        }
    done
}

# ===========================================================================
# I2 — jitter bounds each sleep within ±jitter%
# ===========================================================================

@test "I2: jitter=25 keeps every sleep within ±25% of the expected geometric value" {
    _test_busy_remaining=8
    apr_lib_busy_wait_configure jitter=25 min_sleep=4 max_sleep=128 \
        multiplier=2 max_total_wait=100000 message_every=10000

    apr_lib_busy_wait

    local expected=(4 8 16 32 64 128 128 128)
    local i actual exp delta_max
    for i in "${!expected[@]}"; do
        actual="${_test_sleep_log[$i]}"
        exp="${expected[$i]}"
        delta_max=$(( exp * 25 / 100 ))
        # Floor of jittered sleep is 1.
        local low=$(( exp - delta_max ))
        (( low < 1 )) && low=1
        local high=$(( exp + delta_max ))
        if (( actual < low || actual > high )); then
            echo "iter $i: sleep $actual outside [$low, $high] (expected ≈ $exp ± 25%)" >&2
            return 1
        fi
    done
}

# ===========================================================================
# I3 — COUNT == number of busy probe→sleep cycles
# ===========================================================================

@test "I3: COUNT matches the configured busy-for-K probe count, for K ∈ {0,1,3,7,15}" {
    local k
    for k in 0 1 3 7 15; do
        reset_stubs
        _test_busy_remaining="$k"
        apr_lib_busy_wait_configure jitter=0 min_sleep=1 max_sleep=64 \
            multiplier=2 max_total_wait=100000 message_every=10000
        apr_lib_busy_wait
        [[ "$APR_BUSY_WAIT_COUNT" -eq "$k" ]] || {
            echo "COUNT mismatch for k=$k: got $APR_BUSY_WAIT_COUNT want $k" >&2
            return 1
        }
    done
}

# ===========================================================================
# I4 — probe-never-clears → timeout AND total_ms ≤ max_total*1000
# ===========================================================================

@test "I4: always-busy probe hits timeout AND total_ms ≤ max_total * 1000" {
    _test_busy_remaining=-1
    apr_lib_busy_wait_configure jitter=0 min_sleep=1 max_sleep=8 \
        multiplier=2 max_total_wait=15 message_every=10000

    apr_lib_busy_wait && local rc=0 || rc=$?

    [[ "$rc" -eq 1 ]]
    [[ "$APR_BUSY_WAIT_LAST_REASON" == "timeout" ]]

    local total_ms="$APR_BUSY_WAIT_TOTAL_MS"
    local budget_ms=$(( 15 * 1000 ))
    [[ "$total_ms" -le "$budget_ms" ]] || {
        echo "total_ms=$total_ms exceeds budget=$budget_ms" >&2
        return 1
    }
}

# ===========================================================================
# I5 — probe-clears-at-iter-K → COUNT == K AND LAST_REASON=cleared
# ===========================================================================

@test "I5: probe-clears-at-iter-K agreement across several K values" {
    local k
    for k in 1 2 4 8; do
        reset_stubs
        _test_busy_remaining="$k"
        apr_lib_busy_wait_configure jitter=0 min_sleep=1 max_sleep=64 \
            multiplier=2 max_total_wait=100000 message_every=10000
        apr_lib_busy_wait

        [[ "$APR_BUSY_WAIT_COUNT" -eq "$k" ]] || {
            echo "K=$k: count drift" >&2; return 1
        }
        [[ "$APR_BUSY_WAIT_LAST_REASON" == "cleared" ]] || {
            echo "K=$k: reason drift '$APR_BUSY_WAIT_LAST_REASON'" >&2; return 1
        }
    done
}

# ===========================================================================
# I6 / I7 — sleep floor + ceiling regardless of iter
# ===========================================================================

@test "I6: every recorded sleep ≥ min_sleep when jitter=0" {
    _test_busy_remaining=10
    apr_lib_busy_wait_configure jitter=0 min_sleep=5 max_sleep=200 \
        multiplier=2 max_total_wait=100000 message_every=10000
    apr_lib_busy_wait

    local s
    for s in "${_test_sleep_log[@]}"; do
        (( s >= 5 )) || {
            echo "sleep $s below min_sleep=5" >&2
            printf '  log: %s\n' "${_test_sleep_log[*]}" >&2
            return 1
        }
    done
}

@test "I7: every recorded sleep ≤ max_sleep, regardless of iter count" {
    _test_busy_remaining=20
    apr_lib_busy_wait_configure jitter=0 min_sleep=1 max_sleep=10 \
        multiplier=3 max_total_wait=10000000 message_every=10000
    apr_lib_busy_wait

    local s
    for s in "${_test_sleep_log[@]}"; do
        (( s <= 10 )) || {
            echo "sleep $s exceeds max_sleep=10" >&2
            printf '  log: %s\n' "${_test_sleep_log[*]}" >&2
            return 1
        }
    done
}

# ===========================================================================
# I8 — TOTAL_MS == sum(sleeps) * 1000
# ===========================================================================

@test "I8: TOTAL_MS equals exact sum of recorded sleeps × 1000 (jitter=0)" {
    local k
    for k in 0 1 4 12; do
        reset_stubs
        _test_busy_remaining="$k"
        apr_lib_busy_wait_configure jitter=0 min_sleep=1 max_sleep=16 \
            multiplier=2 max_total_wait=1000000 message_every=10000
        apr_lib_busy_wait

        local sum
        sum=$(sleep_log_total_s)
        local expected_ms=$(( sum * 1000 ))
        [[ "$APR_BUSY_WAIT_TOTAL_MS" -eq "$expected_ms" ]] || {
            echo "k=$k: TOTAL_MS=$APR_BUSY_WAIT_TOTAL_MS expected=$expected_ms (sum_s=$sum)" >&2
            return 1
        }
    done
}

# ===========================================================================
# I9 — Monotone budget: doubling max_total_wait at least doubles total_ms
#       when probe stays busy throughout
# ===========================================================================

@test "I9: doubling max_total_wait while always busy at least doubles TOTAL_MS" {
    # First run with budget=20s.
    _test_busy_remaining=-1
    apr_lib_busy_wait_configure jitter=0 min_sleep=1 max_sleep=8 \
        multiplier=2 max_total_wait=20 message_every=10000
    apr_lib_busy_wait && true
    local small_ms="$APR_BUSY_WAIT_TOTAL_MS"

    # Second run with budget=40s; clear state.
    reset_stubs
    _test_busy_remaining=-1
    apr_lib_busy_wait_configure jitter=0 min_sleep=1 max_sleep=8 \
        multiplier=2 max_total_wait=40 message_every=10000
    apr_lib_busy_wait && true
    local big_ms="$APR_BUSY_WAIT_TOTAL_MS"

    # Doubling the budget should at least double the time spent (the
    # backoff is bounded by max_sleep so once we're at the cap the
    # extra budget is consumed linearly).
    [[ "$big_ms" -ge $(( small_ms * 2 )) ]] || {
        echo "monotone violation: small=$small_ms big=$big_ms (want big ≥ 2*small)" >&2
        return 1
    }
}

# ===========================================================================
# I10 — Determinism under jitter=0
# ===========================================================================

@test "I10: identical configs + probe sequences yield identical (COUNT, TOTAL_MS, REASON) — jitter=0" {
    local first_count first_ms first_reason
    local i

    for i in 1 2 3; do
        reset_stubs
        _test_busy_remaining=6
        apr_lib_busy_wait_configure jitter=0 min_sleep=1 max_sleep=16 \
            multiplier=2 max_total_wait=10000 message_every=10000
        apr_lib_busy_wait

        if [[ "$i" -eq 1 ]]; then
            first_count="$APR_BUSY_WAIT_COUNT"
            first_ms="$APR_BUSY_WAIT_TOTAL_MS"
            first_reason="$APR_BUSY_WAIT_LAST_REASON"
        else
            [[ "$APR_BUSY_WAIT_COUNT"  == "$first_count"  ]] || { echo "run $i: count drift"  >&2; return 1; }
            [[ "$APR_BUSY_WAIT_TOTAL_MS" == "$first_ms"     ]] || { echo "run $i: ms drift"     >&2; return 1; }
            [[ "$APR_BUSY_WAIT_LAST_REASON" == "$first_reason" ]] || { echo "run $i: reason drift" >&2; return 1; }
        fi
    done
}

# ===========================================================================
# Edge cases — unbounded budget AND zero-iteration paths
# ===========================================================================

@test "edge: max_total_wait=0 disables the budget (always-busy still respects probe)" {
    _test_busy_remaining=12
    apr_lib_busy_wait_configure jitter=0 min_sleep=1 max_sleep=8 \
        multiplier=2 max_total_wait=0 message_every=10000

    apr_lib_busy_wait

    [[ "$APR_BUSY_WAIT_COUNT" -eq 12 ]]
    [[ "$APR_BUSY_WAIT_LAST_REASON" == "cleared" ]]
}

@test "edge: probe clear at start → COUNT=0, TOTAL_MS=0, reason=cleared, NO sleep recorded" {
    _test_busy_remaining=0
    apr_lib_busy_wait

    [[ "$APR_BUSY_WAIT_COUNT" -eq 0 ]]
    [[ "$APR_BUSY_WAIT_TOTAL_MS" -eq 0 ]]
    [[ "$APR_BUSY_WAIT_LAST_REASON" == "cleared" ]]
    [[ "${#_test_sleep_log[@]}" -eq 0 ]]
}

# ===========================================================================
# Cross-property: every sleep in the recorded log satisfies BOTH bounds
# (composition of I6 + I7) AND counts up to COUNT
# ===========================================================================

@test "composition: sleep log length == COUNT, every entry within [min_sleep, max_sleep]" {
    _test_busy_remaining=10
    apr_lib_busy_wait_configure jitter=0 min_sleep=2 max_sleep=12 \
        multiplier=2 max_total_wait=100000 message_every=10000
    apr_lib_busy_wait

    [[ "${#_test_sleep_log[@]}" -eq "$APR_BUSY_WAIT_COUNT" ]] || {
        echo "sleep log length (${#_test_sleep_log[@]}) != COUNT ($APR_BUSY_WAIT_COUNT)" >&2
        return 1
    }
    local s
    for s in "${_test_sleep_log[@]}"; do
        (( s >= 2 && s <= 12 )) || {
            echo "sleep $s outside [2, 12]" >&2
            return 1
        }
    done
}
