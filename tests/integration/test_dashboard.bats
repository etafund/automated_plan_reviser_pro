#!/usr/bin/env bats
# test_dashboard.bats - Integration tests for apr dashboard
#
# Tests: non-interactive behavior and helpful messaging

# Load test helpers
load '../helpers/test_helper'

# =============================================================================
# Setup and Teardown
# =============================================================================

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
    cd "$TEST_PROJECT" || return 1
    setup_test_workflow "default"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

# =============================================================================
# Non-interactive behavior
# =============================================================================

@test "apr dashboard: fails gracefully without TTY" {
    capture_streams "$APR_SCRIPT" dashboard

    log_test_actual "stderr" "$CAPTURED_STDERR"
    log_test_actual "exit code" "$CAPTURED_STATUS"

    [[ "$CAPTURED_STATUS" -ne 0 ]]
    [[ "$CAPTURED_STDERR" == *"Dashboard requires an interactive terminal"* ]] || \
        [[ "$CAPTURED_STDERR" == *"Use 'apr stats' for non-interactive output"* ]]
}
