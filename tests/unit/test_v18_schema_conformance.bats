#!/usr/bin/env bats
# test_v18_schema_conformance.bats - Conformance tests for v18 contract schemas

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

@test "v18 contract schemas MUST follow structural conformance rules" {
    # Run the conformance harness
    run python3 "${PROJECT_ROOT}/scripts/schema-conformance.py"
    
    # Assert successful execution
    assert_success
    assert_output --partial "Summary: 35 checked, 0 errors found."
}
