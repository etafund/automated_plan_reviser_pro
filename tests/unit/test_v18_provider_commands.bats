#!/usr/bin/env bats
# test_v18_provider_commands.bats - Unit tests for apr providers CLI commands

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

@test "apr providers plan-routes returns success for balanced profile" {
    run "${PROJECT_ROOT}/apr" providers plan-routes --profile balanced --json
    assert_success
    assert_output --partial '"profile": "balanced"'
    assert_output --partial '"route_plan_id":'
}

@test "apr providers readiness evaluates preflight correctly" {
    local readiness="${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/fixtures/route-readiness.balanced.json"
    run "${PROJECT_ROOT}/apr" providers readiness --readiness "$readiness" --stage preflight --json
    assert_success
    assert_output --partial '"ready": true'
}

@test "apr providers readiness evaluates blocked stage correctly" {
    local readiness="${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/fixtures/route-readiness.balanced.json"
    run "${PROJECT_ROOT}/apr" providers readiness --readiness "$readiness" --stage synthesis --json
    assert_success
    assert_output --partial '"ready": false'
}

@test "apr help shows providers command" {
    run "${PROJECT_ROOT}/apr" help
    assert_success
    assert_output --partial "providers <cmd>"
}
