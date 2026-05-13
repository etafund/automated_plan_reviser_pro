#!/usr/bin/env bats
# test_v18_capabilities_doctor.bats - Unit tests for apr capabilities and doctor commands

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
    mkdir -p .apr
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

@test "apr capabilities returns success" {
    run "${PROJECT_ROOT}/apr" capabilities --json
    assert_success
    assert_output --partial '"tool": "provider-capability-check"'
}

@test "apr doctor returns success" {
    run "${PROJECT_ROOT}/apr" doctor --json
    # Doctor runs two commands, usually we want at least one to succeed or at least not crash the script
    assert_success
    assert_output --partial '"tool": "premortem-check"'
}

@test "apr help shows capabilities and doctor" {
    run "${PROJECT_ROOT}/apr" help
    assert_success
    assert_output --partial "capabilities"
    assert_output --partial "doctor"
}
