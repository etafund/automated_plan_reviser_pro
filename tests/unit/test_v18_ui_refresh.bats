#!/usr/bin/env bats
# test_v18_ui_refresh.bats - Unit tests for CLI UX Refresh (ulu.9)

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

@test "apr help supports compact mode" {
    run env APR_LAYOUT=compact APR_NO_GUM=1 NO_COLOR=1 "${PROJECT_ROOT}/apr" help
    assert_success
    assert_output --partial "SYNOPSIS"
    assert_output --partial "COMMANDS"
    assert_output --partial "apr help --detailed"
    # Ensure it's the compact version (no detailed descriptions)
    refute_output --partial "Iterative specification refinement"
}

@test "apr help compact output fits narrow terminals" {
    run env APR_LAYOUT=compact APR_NO_GUM=1 NO_COLOR=1 "${PROJECT_ROOT}/apr" help
    assert_success

    local max_width
    max_width=$(awk '{ if (length($0) > max) max = length($0) } END { print max + 0 }' <<<"$output")
    [[ "$max_width" -le 80 ]] || {
        echo "compact help max width $max_width exceeds 80" >&2
        return 1
    }
}

@test "apr help detailed mode bypasses compact summary" {
    run env APR_LAYOUT=compact APR_NO_GUM=1 NO_COLOR=1 "${PROJECT_ROOT}/apr" help --detailed
    assert_success
    assert_output --partial "DESCRIPTION"
    assert_output --partial "EXIT CODES"
    assert_output --partial "Fatal errors also emit: APR_ERROR_CODE=<code>"
    refute_output --partial "apr help --detailed"
}

@test "top-level --help honors --detailed lookahead" {
    run env APR_LAYOUT=compact APR_NO_GUM=1 NO_COLOR=1 "${PROJECT_ROOT}/apr" --help --detailed
    assert_success
    assert_output --partial "DESCRIPTION"
    assert_output --partial "EXIT CODES"
    refute_output --partial "apr help --detailed"
}

@test "usage errors are actionable and tagged" {
    run env APR_NO_GUM=1 NO_COLOR=1 "${PROJECT_ROOT}/apr" --layout sideways list
    [[ "$status" -eq 2 ]]
    assert_output --partial "[error] Invalid layout mode: sideways"
    assert_output --partial "[info] Use: auto, desktop, or compact"
    assert_output --partial "APR_ERROR_CODE=usage_error"
}

@test "apr_ui_banner supports compact mode" {
    # We need to source ui.sh
    # shellcheck disable=SC1091
    source "${PROJECT_ROOT}/lib/ui.sh"
    # shellcheck disable=SC1091
    source "${PROJECT_ROOT}/lib/errors.sh" # needed for print_*

    APR_LAYOUT=compact NO_COLOR=1 APR_NO_UNICODE=1 run apr_ui_banner "1.2.3"
    assert_success
    assert_output "APR v1.2.3"
}

@test "apr_ui_error uses standard formatting" {
    # shellcheck disable=SC1091
    source "${PROJECT_ROOT}/lib/ui.sh"
    # shellcheck disable=SC1091
    source "${PROJECT_ROOT}/lib/errors.sh"

    NO_COLOR=1 APR_NO_UNICODE=1 run apr_ui_error "test message" "test hint"
    assert_success
    assert_output --partial "[error] test message"
    assert_output --partial "  test hint"
}
