#!/usr/bin/env bats
# test_v18_plan_export.bats - Unit tests for apr plan export-beads command

load '../helpers/test_helper'

setup() {
    setup_test_environment
    log_test_start "${BATS_TEST_NAME}"
}

teardown() {
    log_test_end "${BATS_TEST_NAME}" "$([[ ${status:-0} -eq 0 ]] && echo pass || echo fail)"
    teardown_test_environment
}

@test "apr plan export-beads dry-run shows proposed beads" {
    local plan="${PROJECT_ROOT}/PLAN/apr-vnext-plan-bundle-v18.0.0/fixtures/plan-artifact.json"
    run "${PROJECT_ROOT}/apr" plan export-beads --plan "$plan" --dry-run --json
    assert_success
    assert_output --partial '"status": "proposed"'
    assert_output --partial '"title": "Route readiness and synthesis gate"'
}

@test "apr help shows plan command" {
    mkdir -p .apr
    run "${PROJECT_ROOT}/apr" help
    assert_success
    assert_output --partial "plan <cmd>"
    rm -rf .apr
}
