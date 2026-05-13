#!/usr/bin/env bats
# test_v18_contracts.bats - Unit tests for v18 contract fixture smoke test

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

@test "v18 contract fixture smoke suite validates all schemas and fixtures" {
    # Run the Python test harness
    run python3 "${PROJECT_ROOT}/tests/v18_contract_smoke.py"
    
    # Assert successful execution
    assert_success
}
